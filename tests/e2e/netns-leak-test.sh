#!/usr/bin/env bash
# Leak test for the kill switch, using plain Docker.
#
# Builds a "pod" (containers sharing one network namespace, routed like a CNI
# does: a default route via a gateway, no on-link subnet route) with the chart's
# real images and scripts, a WireGuard server that NATs to an HTTP canary, and
# then tries to make traffic escape outside the tunnel.
#
# Needs Docker with kernel WireGuard support. No bind mounts and no docker exec
# are used (both are unreliable with docker-outside-of-docker); every probe is
# a fresh container joined to the pod's network namespace.
#
# The network is dual-stack, so every leak check also runs over IPv6.
#
# KEEP=1 leaves the containers running for debugging.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# The chart's default image for $1 (wireguard, transmission), so the test
# follows Renovate's bumps of _helpers.tpl.
chart_image() {
  local tpl=$ROOT/templates/_helpers.tpl repo tag digest
  repo=$(sed -n "s/.*\.Values\.images\.$1 \"repo\" \"\([^\"]*\)\".*/\1/p" "$tpl")
  tag=$(sed -n "s/.*default \"\([^\"]*\)\" \.Values\.images\.$1\.tag.*/\1/p" "$tpl")
  digest=$(sed -n "s/.*default \"\([^\"]*\)\" \.Values\.images\.$1\.digest.*/\1/p" "$tpl")
  [[ -n $repo && -n $tag && -n $digest ]] || { echo "cannot read the $1 image from $tpl" >&2; return 1; }
  echo "$repo:$tag@$digest"
}
WG_IMAGE="${WG_IMAGE:-$(chart_image wireguard)}"
TX_IMAGE="${TX_IMAGE:-$(chart_image transmission)}"
CANARY_IMAGE="${CANARY_IMAGE:-traefik/whoami:v1.10.3@sha256:43a68d10b9dfcfc3ffbfe4dd42100dc9aeaf29b3a5636c856337a5940f1b4f1c}"
TRACKER_IMAGE="${TRACKER_IMAGE:-busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec}"

P=twg-e2e
NET=$P-net
SUBNET_PREFIX=172.31.250
GW=$SUBNET_PREFIX.1
CANARY_IP=$SUBNET_PREFIX.10
DNS_CANARY_IP=$SUBNET_PREFIX.11
TRACKER_IP=$SUBNET_PREFIX.12
SERVER_IP=$SUBNET_PREFIX.20
POD_IP=$SUBNET_PREFIX.30
CLIENT_IP=$SUBNET_PREFIX.40
SUBNET6_PREFIX=fd31:250:
GW6=$SUBNET6_PREFIX:1
CANARY_IP6=$SUBNET6_PREFIX:10
DNS_CANARY_IP6=$SUBNET6_PREFIX:11
TRACKER_IP6=$SUBNET6_PREFIX:12
SERVER_IP6=$SUBNET6_PREFIX:20
POD_IP6=$SUBNET6_PREFIX:30
CLIENT_IP6=$SUBNET6_PREFIX:40
TUN_SERVER=10.99.0.1
TUN_CLIENT=10.99.0.2
TUN_SERVER6=fd99::1
TUN_CLIENT6=fd99::2
WEB_PORT=9091
PEER_PORT=51413

FAILED=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILED=$((FAILED + 1)); }
step() { echo; echo "== $*"; }

cleanup() {
  docker rm -f -v $P-tx $P-l4 $P-l6 $P-wg $P-pod $P-server $P-canary $P-dns $P-tracker $P-pre >/dev/null 2>&1 || true
  docker network rm $NET >/dev/null 2>&1 || true
  docker volume rm $P-torrent >/dev/null 2>&1 || true
}
cleanup
STAGE=$(mktemp -d)
# On any failure (including an aborted run) show what the containers said.
dump_logs() {
  local c
  for c in $P-server $P-wg $P-tx; do
    docker inspect "$c" >/dev/null 2>&1 || continue
    echo "  --- $c ($(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' "$c"))"
    docker logs --tail 40 "$c" 2>&1 | sed "s/^/  $c | /"
  done
}
on_exit() {
  local rc=$?
  ((rc == 0)) || dump_logs
  [[ -n ${KEEP:-} ]] || cleanup
  rm -rf "$STAGE"
}
trap on_exit EXIT

firewall_env=(
  -e "TWG_WEB_PORT=$WEB_PORT"
  -e "TWG_PEER_PORT=$PEER_PORT"
  -e "TWG_WEB_ALLOWED_CIDRS=$SUBNET_PREFIX.0/24 fc00::/7"
  -e TWG_HANDSHAKE_MAX_AGE=180
)

# An unprivileged process in the pod, like Transmission: no capabilities, so
# it cannot set socket marks or touch the firewall.
as_app() { docker run --rm --network container:$P-pod --cap-drop ALL --user 1000:1000 --entrypoint "" "$WG_IMAGE" "$@"; }
# Root with NET_ADMIN in the pod and the sidecar's files, like a probe.
as_root() { docker run --rm --network container:$P-pod --privileged --volumes-from $P-wg "${firewall_env[@]}" --entrypoint "" "$WG_IMAGE" "$@"; }
on_server() { docker run --rm --network container:$P-server --entrypoint "" "$WG_IMAGE" "$@"; }
from_cluster() { docker run --rm --network $NET --ip $CLIENT_IP --ip6 $CLIENT_IP6 --entrypoint "" "$WG_IMAGE" "$@"; }
wg_tool() { docker run --rm -i --entrypoint wg "$WG_IMAGE" "$@"; }
# transmission-remote against the daemon's RPC.
tx_remote() { docker run --rm --network container:$P-pod --cap-drop ALL --entrypoint transmission-remote "$TX_IMAGE" 127.0.0.1:$WEB_PORT "$@"; }
# Like as_app, but with a raw socket for ICMP: iptables still filters it.
as_raw() { docker run --rm --network container:$P-pod --cap-drop ALL --cap-add NET_RAW --entrypoint "" "$WG_IMAGE" "$@"; }

# Source address the canary saw for a request from the pod (empty if blocked).
# Arguments go to curl, before the canary's URL.
fetch_seen() {
  as_app curl -sS -m 3 "$@" 2>/dev/null |
    sed -n 's/^RemoteAddr: \[\{0,1\}\([^]]*\)\]\{0,1\}:[0-9]*\r\{0,1\}$/\1/p' || true
}
canary_seen() { fetch_seen "$@" "http://$CANARY_IP/"; }
canary_seen6() { fetch_seen -6 "$@" "http://[$CANARY_IP6]/"; }
# Where a request to the canary went: "vpn", "blocked" (refused, timed out,
# or cut off mid-way), "leak <address>", or "broken <curl exit>" when the
# probe itself failed and so proves nothing. Arguments go to curl.
egress() {
  local rc out seen
  # An answer must name an address; an empty one (the docker client can
  # lose a container's output) is retried, then counts as broken.
  for _ in 1 2; do
    rc=0
    out=$(as_app curl -sS -m 3 "$@" 2>/dev/null) || rc=$?
    [[ $rc != 0 || -n $out ]] && break
  done
  [[ $rc != 0 || -n $out ]] || { echo "broken empty-answer"; return; }
  seen=$(sed -n 's/^RemoteAddr: \[\{0,1\}\([^]]*\)\]\{0,1\}:[0-9]*\r\{0,1\}$/\1/p' <<<"$out")
  case $rc in
    0) if [[ $seen == "$SERVER_IP" || $seen == "$SERVER_IP6" ]]; then echo vpn; else echo "leak ${seen:-unknown}"; fi ;;
    7 | 28 | 52 | 56) echo blocked ;;
    *) echo "broken $rc" ;;
  esac
}
egress4() { egress "$@" "http://$CANARY_IP/"; }
egress6() { egress -6 "$@" "http://[$CANARY_IP6]/"; }
# Records probe results ($@) while traffic must not leak; result_summary
# then reports leaks, probes that could not run, too few probes, and (with
# need-blocked as $2) probes that never overlapped the outage.
LEAKED="" BROKEN="" PROBES=0 BLOCKED=0
record() {
  local r
  for r in "$@"; do
    PROBES=$((PROBES + 1))
    case $r in
      leak*) LEAKED="$LEAKED ${r#leak }" ;;
      broken*) BROKEN="$BROKEN ${r#broken }" ;;
      blocked) BLOCKED=$((BLOCKED + 1)) ;;
    esac
  done
}
result_summary() {
  if [[ -n $LEAKED ]]; then
    fail "LEAK $1 (canary saw$LEAKED)"
  elif [[ -n $BROKEN ]]; then
    fail "probes $1 could not run (curl exit$BROKEN), so they prove nothing"
  elif ((PROBES < 2)); then
    fail "only $PROBES probe(s) ran $1, which proves nothing"
  elif [[ ${2:-} == need-blocked ]] && ((BLOCKED == 0)); then
    fail "none of the $PROBES probes $1 hit the outage, so they prove nothing"
  else
    pass "no direct egress $1 ($PROBES probes, $BLOCKED blocked)"
  fi
  LEAKED="" BROKEN="" PROBES=0 BLOCKED=0
}
# ping's verdict: "reached", "blocked" (no reply) or "broken <exit>".
icmp() {
  local rc=0
  as_raw ping -c1 -W2 "$@" >/dev/null 2>&1 || rc=$?
  case $rc in
    0) echo reached ;;
    1) echo blocked ;;
    *) echo "broken $rc" ;;
  esac
}
expect_icmp_blocked() {
  local what=$1 r; shift
  r=$(icmp "$@")
  case $r in
    blocked) pass "$what" ;;
    reached) fail "LEAK: $what is not true (got a reply)" ;;
    *) fail "$what: ping result '$r' proves nothing" ;;
  esac
}
# nc -z's verdict: "open", "closed" or "broken <exit>" (docker failed).
nc_result() {
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  case $rc in
    0) echo open ;;
    1) echo closed ;;
    *) echo "broken $rc" ;;
  esac
}
# Every canary counts the packets that do not come from the VPN server: that
# is a leak however the client saw it (a timeout after the SYN got out, or a
# packet sent out eth0 from the tunnel address that the canary cannot answer).
# Only the pod talks to the canaries. (IPv6: TCP, UDP and echo, not neighbour
# discovery.) hits_mark takes a reading, hits_check fails if it grew since.
COUNTED=("$P-canary" "$P-dns" "$P-tracker")
count_from_pod() {
  docker run --rm --network "container:$1" --cap-add NET_ADMIN --entrypoint "" "$WG_IMAGE" sh -c "
    iptables -w -I INPUT ! -s $SERVER_IP -m comment --comment twg-count &&
    for m in '-p tcp' '-p udp' '-p ipv6-icmp --icmpv6-type echo-request'; do
      ip6tables -w -I INPUT ! -s $SERVER_IP6 \$m -m comment --comment twg-count || exit 1
    done"
}
pod_hits() {
  local c n out total=0
  for c in "${COUNTED[@]}"; do
    out=""
    # The docker client can lose a container's output; END proves it did not.
    for _ in 1 2 3; do
      out=$(docker run --rm --network "container:$c" --cap-add NET_ADMIN --entrypoint "" "$WG_IMAGE" \
        sh -c 'iptables-save -c -t filter && ip6tables-save -c -t filter && echo END' 2>/dev/null || true)
      [[ $out == *END* ]] && break
    done
    [[ $out == *END* ]] || { echo unreadable; return; }
    while read -r n; do
      total=$((total + n))
    done < <(sed -n 's/^\[\([0-9]*\):[0-9]*\] .*twg-count.*/\1/p' <<<"$out")
  done
  echo "$total"
}
HITS=unreadable
hits_mark() { HITS=$(pod_hits); }
hits_check() {
  local now
  now=$(pod_hits)
  if [[ $HITS == unreadable || $now == unreadable ]]; then
    fail "could not read the canaries' packet counters $1"
  elif ((now > HITS)); then
    fail "LEAK: $((now - HITS)) packet(s) not from the VPN server reached the canaries $1"
  else
    pass "the canaries received nothing but VPN traffic $1"
  fi
  HITS=$now
}
expect_blocked() {
  local what=$1 r; shift
  r=$("$@")
  case $r in
    blocked) pass "$what" ;;
    leak*) fail "LEAK: $what is not true (canary saw ${r#leak })" ;;
    *) fail "$what: probe result '$r' proves nothing" ;;
  esac
}
# A request bound to eth0 must be refused (curl exit 7) or time out (28);
# any other failure proves nothing.
check_eth0() {
  local what=$1 rc=0; shift
  as_app curl -sS -m 3 -o /dev/null --interface eth0 "$@" >/dev/null 2>&1 || rc=$?
  case $rc in
    7 | 28) pass "a socket bound to eth0 cannot reach $what" ;;
    0) fail "LEAK: a socket bound to eth0 reached $what" ;;
    *) fail "eth0 check for $what proves nothing (curl exit $rc)" ;;
  esac
}
# Send DNS-port datagrams tagged $1 over IPv${2:-4} and print the source the
# canary saw. Five, a second apart: the listener restarts after each sender.
# (Each listener binds its own address, so IPv4 and IPv6 do not race for
# one dual-stack socket.)
# A port other than 53 ($3) stands in for DHT and other UDP traffic.
dns_seen() {
  local tag=$1 fam=${2:-4} port=${3:-53} ip=$DNS_CANARY_IP rc=0
  [[ $fam == 4 ]] || ip=$DNS_CANARY_IP6
  as_app sh -c "for i in 1 2 3 4 5; do echo $tag | nc -$fam -u -w1 $ip $port; done" >/dev/null 2>&1 || rc=$?
  # 125-127: docker or the shell failed, so nothing was sent.
  ((rc < 125)) || { echo "probe-broken"; return; }
  sleep 1
  # Every source that sent the tag, not just the last: one leaked datagram
  # among tunnelled ones must not pass.
  docker logs $P-dns 2>&1 | grep -B1 -x "$tag" | sed -n 's/^Connection received on \(::ffff:\)\{0,1\}\([^ ]*\) .*/\2/p' |
    sort -u | paste -sd' ' - || true
}
via_vpn() { [[ $(canary_seen) == "$SERVER_IP" && $(canary_seen6) == "$SERVER_IP6" ]]; }

wait_for() {
  local desc=$1 tries=$2; shift 2
  for _ in $(seq "$tries"); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  echo "        timed out waiting for: $desc" >&2
  return 1
}

stage_scripts() {
  mkdir -p "$1/twg/scripts"
  cp "$ROOT/files/firewall.sh" "$ROOT/files/settings-init.sh" "$1/twg/scripts/"
  chmod 0555 "$1"/twg/scripts/*
}

step "setup"
# Pull up front with retries: registries rate-limit bursts of pulls.
for image in "$WG_IMAGE" "$TX_IMAGE" "$CANARY_IMAGE" "$TRACKER_IMAGE"; do
  for attempt in 1 2 3 4 5; do
    docker pull -q "$image" >/dev/null && break
    ((attempt < 5)) || { echo "cannot pull $image" >&2; exit 1; }
    sleep $((attempt * 5))
  done
done
SERVER_KEY=$(wg_tool genkey)
CLIENT_KEY=$(wg_tool genkey)
SERVER_PUB=$(echo "$SERVER_KEY" | wg_tool pubkey)
CLIENT_PUB=$(echo "$CLIENT_KEY" | wg_tool pubkey)

docker network create --subnet $SUBNET_PREFIX.0/24 --gateway $GW \
  --ipv6 --subnet $SUBNET6_PREFIX:/64 --gateway $GW6 $NET >/dev/null
docker run -d --name $P-canary --network $NET --ip $CANARY_IP --ip6 $CANARY_IP6 "$CANARY_IMAGE" >/dev/null
# UDP/53 canary standing in for any DNS server outside the pod (cluster DNS,
# NodeLocal DNSCache, the ISP); logs the source of every datagram.
docker run -d --name $P-dns --network $NET --ip $DNS_CANARY_IP --ip6 $DNS_CANARY_IP6 --entrypoint "" "$WG_IMAGE" \
  sh -c "while true; do nc -4 -luvn -w 1 $DNS_CANARY_IP 53; done & while true; do nc -6 -luvn -w 1 $DNS_CANARY_IP6 53; done &
    while true; do nc -4 -luvn -w 1 $DNS_CANARY_IP 6881; done" >/dev/null
# HTTP tracker canary for Transmission's own announces: logs the source of
# each one and asks for the next announce in 10 seconds.
docker run -d --name $P-tracker --network $NET --ip $TRACKER_IP --ip6 "$TRACKER_IP6" "$TRACKER_IMAGE" sh -c '
    mkdir -p /www/cgi-bin
    cat > /www/cgi-bin/announce <<"CGI"
#!/bin/sh
a=${REMOTE_ADDR#[}; a=${a%]}; a=${a#::ffff:}
echo "ANNOUNCE $a" >/proc/1/fd/2
printf "Content-Type: text/plain\r\n\r\nd8:intervali10e12:min intervali5e5:peers0:e"
CGI
    chmod +x /www/cgi-bin/announce
    exec httpd -f -p 80 -h /www' >/dev/null
announces() { docker logs $P-tracker 2>&1 | sed -n 's/^ANNOUNCE //p'; }
# More announces than $1 so far, and every one through the VPN.
announced_since() { (($(announces | wc -l) > $1)) && announces_via_vpn; }
# Transmission backs off after failed announces, so ask for one.
reannounced_since() {
  tx_remote -t all --reannounce >/dev/null 2>&1 || true
  sleep 4
  announced_since "$1"
}
announces_via_vpn() {
  local a
  for a in $(announces | sort -u); do
    [[ $a == "$SERVER_IP" || $a == "$SERVER_IP6" ]] || return 1
  done
}
for c in "${COUNTED[@]}"; do count_from_pod "$c"; done

# VPN server: terminates the tunnel and NATs to the "internet" (the canary).
docker run -d --name $P-server --network $NET --ip $SERVER_IP --ip6 $SERVER_IP6 --privileged \
  --entrypoint bash "$WG_IMAGE" -c "
    set -e
    echo '$SERVER_KEY' > /tmp/k
    ip link add wg0 type wireguard
    wg set wg0 listen-port 51820 private-key /tmp/k peer '$CLIENT_PUB' allowed-ips $TUN_CLIENT/32,$TUN_CLIENT6/128
    ip addr add $TUN_SERVER/24 dev wg0
    ip addr add $TUN_SERVER6/64 dev wg0
    ip link set wg0 up
    sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    exec sleep infinity" >/dev/null

# Pod sandbox, routed like a CNI: only a host route to the gateway.
docker run -d --name $P-pod --network $NET --ip $POD_IP --ip6 $POD_IP6 --privileged \
  --entrypoint bash "$WG_IMAGE" -c "
    ip route del $SUBNET_PREFIX.0/24 dev eth0
    ip route add $GW/32 dev eth0 scope link
    ip route replace default via $GW dev eth0
    ip -6 route del $SUBNET6_PREFIX:/64 dev eth0
    ip -6 route add $GW6/128 dev eth0
    ip -6 route replace default via $GW6 dev eth0
    exec sleep infinity" >/dev/null
sleep 2

mkdir -p "$STAGE/wg/config/wg_confs"
stage_scripts "$STAGE/wg"
cat >"$STAGE/wg/config/wg_confs/wg0.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_KEY
Address = $TUN_CLIENT/32, $TUN_CLIENT6/128

[Peer]
PublicKey = $SERVER_PUB
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $SERVER_IP:51820
PersistentKeepalive = 5
EOF
chmod 0600 "$STAGE/wg/config/wg_confs/wg0.conf"

# Baseline: before any firewall, the pod reaches the canary directly. If this
# fails the harness is broken and later "blocked" results would mean nothing.
# The eth0-bound requests are the positive control for the eth0 checks below.
hits_mark
if [[ $(canary_seen) == "$POD_IP" && $(canary_seen6) == "$POD_IP6" &&
  $(canary_seen --interface eth0) == "$POD_IP" && $(canary_seen6 --interface eth0) == "$POD_IP6" &&
  $(dns_seen BASELINE) == "$POD_IP" && $(dns_seen BASELINE6 6) == "$POD_IP6" &&
  $(dns_seen BASELINEDHT 4 6881) == "$POD_IP" ]] &&
  as_raw ping -c1 -W2 -I eth0 $CANARY_IP >/dev/null 2>&1; then
  pass "baseline: without the kill switch the pod reaches the canaries directly (as $POD_IP and $POD_IP6)"
else
  fail "baseline: pod cannot reach the canary even without the kill switch (harness broken)"
  exit 1
fi
baseline_hits=$(pod_hits)
if [[ $HITS != unreadable && $baseline_hits != unreadable ]] && ((baseline_hits > HITS)); then
  pass "baseline: the canaries count the pod's direct packets ($((baseline_hits - HITS)) so far)"
else
  fail "baseline: the canaries' packet counters do not work (harness broken)"
  exit 1
fi

# The sidecar exactly as the chart runs it.
docker create --name $P-wg --network container:$P-pod --privileged -v /twg "${firewall_env[@]}" \
  --entrypoint /bin/bash "$WG_IMAGE" -c '/twg/scripts/firewall.sh apply && exec /init' >/dev/null
docker cp "$STAGE/wg/." $P-wg:/ >/dev/null
docker start $P-wg >/dev/null
wait_for "wg0 up" 60 as_root wg show wg0 || true
if ! wait_for "first handshake" 30 via_vpn; then
  fail "the tunnel never came up; nothing below would mean anything"
  exit 1
fi

# settings-init runs in the Transmission image like the chart's init container.
mkdir -p "$STAGE/settings/twg/settings" "$STAGE/settings/twg/wg" "$STAGE/settings/twg/run"
stage_scripts "$STAGE/settings"
echo '{"rpc-port": 9091, "rpc-whitelist-enabled": false, "peer-port": 51413, "rpc-authentication-required": false}' \
  >"$STAGE/settings/twg/settings/settings.json"
cp "$STAGE/wg/config/wg_confs/wg0.conf" "$STAGE/settings/twg/wg/wg0.conf"
docker create --name $P-pre --network none -e RPC_USERNAME=admin -e RPC_PASSWORD=s3cret \
  --entrypoint /bin/sh "$TX_IMAGE" /twg/scripts/settings-init.sh >/dev/null
docker cp "$STAGE/settings/." $P-pre:/ >/dev/null
docker start -a $P-pre
docker cp $P-pre:/twg/run/settings.json "$STAGE/settings.json"
docker rm -f $P-pre >/dev/null

# Transmission with the composed settings, but without credentials so the
# web UI answers plainly for the reachability checks below.
jq 'del(.["rpc-username"], .["rpc-password"]) | .["rpc-authentication-required"] = false' \
  "$STAGE/settings.json" >"$STAGE/tx-settings.json"
mkdir -p "$STAGE/tx/config"
cp "$STAGE/tx-settings.json" "$STAGE/tx/config/settings.json"
# Capabilities as the chart allows them: everything dropped but these.
docker create --name $P-tx --network container:$P-pod --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID \
  -e PUID=1000 -e PGID=1000 "$TX_IMAGE" >/dev/null
docker cp "$STAGE/tx/." $P-tx:/ >/dev/null
docker start $P-tx >/dev/null
wait_for "transmission listening" 90 as_app nc -z 127.0.0.1 $WEB_PORT
# Transmission's RPC listens on IPv4 only here; an unprivileged IPv6 listener
# on the web port stands in for it.
docker run -d --name $P-l6 --network container:$P-pod --cap-drop ALL --user 1000:1000 --entrypoint "" "$WG_IMAGE" \
  nc -6 -lk $POD_IP6 $WEB_PORT >/dev/null

step "settings.json"
if jq -e --arg ip $TUN_CLIENT --arg ip6 $TUN_CLIENT6 '.["bind-address-ipv4"] == $ip and .["bind-address-ipv6"] == $ip6' "$STAGE/settings.json" >/dev/null; then
  pass "peer sockets bound to tunnel addresses $TUN_CLIENT and $TUN_CLIENT6"
else
  fail "bind addresses wrong: $(jq -c '{a4:.["bind-address-ipv4"],a6:.["bind-address-ipv6"]}' "$STAGE/settings.json")"
fi
if jq -e '.["rpc-authentication-required"] == true and .["rpc-username"] == "admin" and .["rpc-password"] == "s3cret"' "$STAGE/settings.json" >/dev/null; then
  pass "RPC credentials from the Secret are applied"
else
  fail "RPC credentials not applied"
fi

step "tunnel up"
hits_mark
if as_root /twg/scripts/firewall.sh live; then pass "startup/readiness/liveness probes pass"; else fail "probes fail with the tunnel up"; fi
seen=$(canary_seen)
if [[ $seen == "$SERVER_IP" ]]; then
  pass "egress exits through the VPN (canary saw $seen)"
else
  fail "egress did not go through the VPN (canary saw '${seen:-nothing}', want $SERVER_IP)"
fi
seen=$(canary_seen6)
if [[ $seen == "$SERVER_IP6" ]]; then
  pass "IPv6 egress exits through the VPN (canary saw $seen)"
else
  fail "IPv6 egress did not go through the VPN (canary saw '${seen:-nothing}', want $SERVER_IP6)"
fi
check_eth0 "the canary" "http://$CANARY_IP/"
check_eth0 "the canary over IPv6" -6 "http://[$CANARY_IP6]/"
seen=$(dns_seen TUNNELED)
if [[ $seen == "$SERVER_IP" ]]; then
  pass "DNS-port traffic leaves through the VPN (canary saw $seen)"
else
  fail "DNS-port traffic did not go through the VPN (canary saw '${seen:-nothing}')"
fi
seen=$(dns_seen TUNNELED6 6)
if [[ $seen == "$SERVER_IP6" ]]; then
  pass "IPv6 DNS-port traffic leaves through the VPN (canary saw $seen)"
else
  fail "IPv6 DNS-port traffic did not go through the VPN (canary saw '${seen:-nothing}')"
fi
seen=$(dns_seen TUNNELEDDHT 4 6881)
if [[ $seen == "$SERVER_IP" ]]; then
  pass "UDP to another port leaves through the VPN (canary saw $seen)"
else
  fail "UDP to another port did not go through the VPN (canary saw '${seen:-nothing}')"
fi
if [[ $(icmp $CANARY_IP) == reached && $(icmp -6 $CANARY_IP6) == reached ]]; then
  pass "ICMP leaves through the VPN (IPv4 and IPv6)"
else
  fail "ICMP does not get through the VPN"
fi
expect_icmp_blocked "ICMP bound to eth0 is blocked" -I eth0 $CANARY_IP
expect_icmp_blocked "IPv6 ICMP bound to eth0 is blocked" -6 -I eth0 $CANARY_IP6
# Transmission's own traffic: a torrent whose tracker is the canary. Its
# announces must come from the VPN server, never from the pod.
docker run --rm --network none --entrypoint sh -v $P-torrent:/t "$TX_IMAGE" -c \
  "echo leak-test >/t/payload && transmission-create -o /t/test.torrent -t http://$TRACKER_IP/cgi-bin/announce \
    -t http://[$TRACKER_IP6]/cgi-bin/announce /t/payload" >/dev/null 2>&1
docker run --rm --network container:$P-pod --cap-drop ALL -v $P-torrent:/t --entrypoint transmission-remote "$TX_IMAGE" \
  127.0.0.1:$WEB_PORT -a /t/test.torrent >/dev/null
# At least two, so the re-announce every 10 seconds is shown to work.
if wait_for "two announces" 60 sh -c "[ \$(docker logs $P-tracker 2>&1 | grep -c '^ANNOUNCE ') -ge 2 ]"; then
  sources=$(announces | sort -u | tr '\n' ' ')
  if announces_via_vpn; then
    pass "Transmission announces to its tracker through the VPN, every 10 s (tracker saw $sources)"
  else
    fail "LEAK: Transmission's announces came from ${sources}(want only $SERVER_IP / $SERVER_IP6)"
  fi
else
  fail "Transmission did not announce to the tracker canary twice (test broken)"
fi
code=$(from_cluster curl -sS -m 4 -o /dev/null -w '%{http_code}' "http://$POD_IP:$WEB_PORT/transmission/web/" 2>/dev/null || true)
if [[ $code =~ ^(200|301|401|409)$ ]]; then
  pass "web UI reachable from the cluster network (HTTP $code, reply routed back out eth0)"
else
  fail "web UI not reachable from the cluster network (HTTP '${code}')"
fi
# Flush the neighbour cache so the reply needs neighbour discovery through
# the kill switch, not a cached entry.
as_root ip -6 neigh flush dev eth0 >/dev/null 2>&1 || true
if from_cluster nc -6 -z -w 3 $POD_IP6 $WEB_PORT 2>/dev/null; then
  pass "web port reachable from the cluster over IPv6 (neighbour discovery and reply routing work)"
else
  fail "web port not reachable from the cluster over IPv6"
fi
# Transmission binds the peer port to the tunnel address, so probing POD_IP
# would prove nothing. An unprivileged listener on POD_IP stands in for it
# (bindToTunnel off); it answers locally, so a closed port from the cluster
# means the kill switch.
docker run -d --name $P-l4 --network container:$P-pod --cap-drop ALL --user 1000:1000 --entrypoint "" "$WG_IMAGE" \
  nc -lk $POD_IP $PEER_PORT >/dev/null
if ! wait_for "peer port stand-in listening" 10 as_app nc -z -w 2 $POD_IP $PEER_PORT; then
  fail "the peer port stand-in on $POD_IP does not answer locally (test broken)"
else
  case $(nc_result from_cluster nc -z -w 3 $POD_IP $PEER_PORT) in
    closed) pass "peer port not reachable outside the tunnel (a listener on the pod address answers only locally)" ;;
    open) fail "peer port reachable outside the tunnel" ;;
    *) fail "the peer port probe from the cluster could not run" ;;
  esac
fi
docker rm -f $P-l4 >/dev/null
if on_server nc -z -w 3 $TUN_CLIENT $PEER_PORT; then
  pass "peer port reachable through the tunnel"
else
  fail "peer port not reachable through the tunnel"
fi
case $(nc_result on_server nc -z -w 3 $TUN_CLIENT $WEB_PORT) in
  closed) pass "web UI/RPC not reachable from the VPN side" ;;
  open) fail "web UI/RPC reachable from the VPN side" ;;
  *) fail "the web UI probe from the VPN side could not run" ;;
esac
hits_check "while the tunnel is up"

step "tunnel up but its policy routing removed (unmarked traffic would route out eth0)"
# wg0 and its address stay, so Transmission's tracker sockets still bind and
# try; only the kill switch can stop them leaving by eth0.
hits_mark
before=$(announces | wc -l)
as_root sh -c 'ip -4 rule del not fwmark 51820 table 51820 && ip -6 rule del not fwmark 51820 table 51820'
expect_blocked "no TCP egress with the policy rule gone" egress4
expect_blocked "no IPv6 egress with the policy rule gone" egress6
expect_icmp_blocked "no ICMP egress with the policy rule gone" $CANARY_IP
seen=$(dns_seen NORULE)
if [[ -z $seen ]]; then pass "no UDP egress with the policy rule gone"; else fail "LEAK: UDP canary reached with the policy rule gone (saw $seen)"; fi
sleep 20 # two of Transmission's re-announce intervals
after=$(announces | wc -l)
if ((after == before)); then
  pass "Transmission's announces do not get out with the policy rule gone"
else
  fail "LEAK: Transmission announced with the policy rule gone (tracker saw $(announces | tail -n +$((before + 1)) | sort -u | tr '\n' ' '))"
fi
hits_check "with the policy rule gone"
as_root sh -c 'ip -4 rule add not fwmark 51820 table 51820 pref 32765 && ip -6 rule add not fwmark 51820 table 51820 pref 32765'
if wait_for "an announce through the VPN" 20 reannounced_since "$after"; then
  pass "Transmission announces through the VPN again once routing is back (it was trying all along)"
else
  fail "Transmission did not announce again after routing came back, so the check above proves nothing"
fi

step "sidecar restart with the tunnel up (s6 runs wg-quick down; kill switch must stay)"
hits_mark
docker restart -t 10 $P-wg >/dev/null &
restart_pid=$!
# Probe until the restart is over and at least one probe hit the outage.
for _ in $(seq 40); do
  record "$(egress4)" "$(egress6)"
  if ! kill -0 $restart_pid 2>/dev/null && ((BLOCKED > 0)); then break; fi
done
wait $restart_pid
result_summary "during the restart" need-blocked
hits_check "during the restart"
if wait_for "wg0 back" 60 as_root wg show wg0 && wait_for "traffic via VPN" 30 via_vpn; then
  pass "tunnel recovers after restart"
else
  fail "tunnel did not recover after restart"
fi

step "tunnel interface deleted"
hits_mark
as_root ip link del wg0
expect_blocked "no TCP egress without wg0" egress4
expect_blocked "no IPv6 egress without wg0" egress6
seen=$(dns_seen NOTUNNEL)
if [[ -z $seen ]]; then pass "no DNS/UDP egress without wg0"; else fail "LEAK: DNS canary reached without wg0 (saw $seen)"; fi
seen=$(dns_seen NOTUNNEL6 6)
if [[ -z $seen ]]; then pass "no IPv6 DNS/UDP egress without wg0"; else fail "LEAK: DNS canary reached over IPv6 without wg0 (saw $seen)"; fi
seen=$(dns_seen NOTUNNELDHT 4 6881)
if [[ -z $seen ]]; then pass "no UDP egress to another port without wg0"; else fail "LEAK: UDP canary reached without wg0 (saw $seen)"; fi
expect_icmp_blocked "no ICMP egress without wg0" $CANARY_IP
expect_icmp_blocked "no IPv6 ICMP egress without wg0" -6 $CANARY_IP6
hits_check "without wg0"
if as_root /twg/scripts/firewall.sh tunnel 2>/dev/null; then
  fail "probe did not notice the missing tunnel"
else
  pass "readiness/liveness probe fails while the tunnel is down"
fi

step "sidecar SIGKILL (wg0, its routes and rules left behind)"
docker restart -t 10 $P-wg >/dev/null
wait_for "tunnel back" 60 as_root /twg/scripts/firewall.sh tunnel || true
docker kill $P-wg >/dev/null 2>&1 || true
hits_mark
for _ in 1 2 3; do
  record "$(egress4)" "$(egress6)" "$(egress4 --interface eth0)" "$(egress6 --interface eth0)"
done
result_summary "while the sidecar is dead"
hits_check "while the sidecar is dead"
# The image deletes the default route when wg-quick fails; recovery must
# bring both families back.
as_root sh -c 'ip route del default; ip -6 route del default'
docker start $P-wg >/dev/null
if wait_for "tunnel back" 60 as_root /twg/scripts/firewall.sh tunnel && wait_for "traffic via VPN" 30 via_vpn; then
  pass "recovers: stale wg0 and policy rules removed, default routes restored"
else
  fail "did not recover after SIGKILL"
fi
if [[ $(as_root ip -4 rule show | grep -c 'lookup 51820') == 1 ]]; then
  pass "no duplicate wg-quick policy rules after the restart"
else
  fail "stale wg-quick policy rules left behind: $(as_root ip -4 rule show | tr '\n' ';')"
fi

step "firewall tampering"
hits_mark
as_root ip6tables -I TWG-OUTPUT 1 -j ACCEPT
if as_root /twg/scripts/firewall.sh check 2>/dev/null; then
  fail "probe did not notice an ACCEPT inserted into TWG-OUTPUT"
else
  pass "probe notices a rule inserted inside the kill switch chain"
fi
as_root ip6tables -D TWG-OUTPUT 1
if as_root /twg/scripts/firewall.sh check; then
  pass "probe passes again once the rule is removed"
else
  fail "probe still fails after removing the inserted rule"
fi
# A rule after the kill switch's jump that gives every packet WireGuard's
# mark: marked packets must still only reach the VPN endpoint.
as_root sh -c 'iptables -t mangle -A OUTPUT -j MARK --set-mark 51820; ip6tables -t mangle -A OUTPUT -j MARK --set-mark 51820'
expect_blocked "marking every packet does not open eth0" egress4
expect_blocked "marking every IPv6 packet does not open eth0" egress6
if as_root /twg/scripts/firewall.sh check 2>/dev/null; then
  fail "probe did not notice a rule appended to mangle OUTPUT"
else
  pass "probe notices a rule appended to mangle OUTPUT"
fi
as_root sh -c 'iptables -t mangle -D OUTPUT -j MARK --set-mark 51820; ip6tables -t mangle -D OUTPUT -j MARK --set-mark 51820'
# A nat rule re-routes a packet out eth0 after filter OUTPUT accepted it as
# going to wg0. Only the POSTROUTING decision can stop it.
hits_check "with every packet marked"
as_root sh -c "ip route add $CANARY_IP/32 via $GW dev eth0 &&
  iptables -t nat -A OUTPUT -p tcp -d 198.51.100.7 --dport 80 -j DNAT --to-destination $CANARY_IP"
# Positive control: with the POSTROUTING decision bypassed, the same request
# must reach the canary (from the tunnel address it was routed for, so curl
# itself gets no answer), so the check below is the decision's doing.
hits_mark
as_root iptables -t mangle -I TWG-POSTROUTING 1 -j RETURN
egress http://198.51.100.7/ >/dev/null
as_root iptables -t mangle -D TWG-POSTROUTING -j RETURN
leaked=$(pod_hits)
if [[ $HITS != unreadable && $leaked != unreadable ]] && ((leaked > HITS)); then
  pass "positive control: without the POSTROUTING decision the nat re-route reaches the canary out eth0"
else
  fail "the nat re-route did not reach the canary even without the POSTROUTING decision, so the check below proves nothing"
fi
hits_mark
expect_blocked "a nat rule re-routing out eth0 does not leak" egress http://198.51.100.7/
as_root sh -c "iptables -t nat -D OUTPUT -p tcp -d 198.51.100.7 --dport 80 -j DNAT --to-destination $CANARY_IP;
  ip route del $CANARY_IP/32 via $GW dev eth0"
# Duplicated packets skip every later chain, so check must refuse them.
if as_root nft add table ip twgtest 2>/dev/null &&
  as_root nft add chain ip twgtest out '{ type filter hook output priority 0; }' &&
  as_root nft add rule ip twgtest out ip daddr 198.51.100.8 dup to $GW device eth0 2>/dev/null; then
  if as_root /twg/scripts/firewall.sh check 2>/dev/null; then
    fail "probe did not notice an nft rule duplicating packets"
  else
    pass "probe notices an nft rule duplicating packets"
  fi
else
  fail "could not add an nft dup rule (kernel without nf_dup?), so the dup check is untested"
fi
as_root nft delete table ip twgtest 2>/dev/null || true
as_root sh -c 'iptables -F OUTPUT; iptables -P OUTPUT ACCEPT'
expect_blocked "with filter OUTPUT flushed, POSTROUTING still blocks eth0" egress4 --interface eth0
hits_check "with the nat re-route and the flushed filter OUTPUT"
if as_root /twg/scripts/firewall.sh live 2>/dev/null; then
  fail "liveness probe did not notice the flushed firewall"
else
  pass "liveness probe fails on a flushed firewall"
fi
docker restart -t 10 $P-wg >/dev/null
if wait_for "kill switch restored" 30 as_root /twg/scripts/firewall.sh check; then
  pass "restart re-applies the kill switch"
else
  fail "kill switch not restored by restart"
fi

step "unsafe configs are refused (rules stay installed)"
# Runs apply in a throwaway namespace with wg0.conf edited by the sed script
# $1; $2 (optional) is written as a second config, wg1.conf.
run_apply() {
  rm -rf "$STAGE/pre"
  mkdir -p "$STAGE/pre/config/wg_confs"
  stage_scripts "$STAGE/pre"
  sed "$1" "$STAGE/wg/config/wg_confs/wg0.conf" >"$STAGE/pre/config/wg_confs/wg0.conf"
  [[ -z ${2:-} ]] || echo "$2" >"$STAGE/pre/config/wg_confs/wg1.conf"
  docker create --name $P-pre --privileged --network none "${firewall_env[@]}" "${APPLY_ENV[@]}" --entrypoint /bin/bash "$WG_IMAGE" \
    -c '/twg/scripts/firewall.sh apply; rc=$?; /twg/scripts/firewall.sh check && echo RULES_OK; echo "RC=$rc"
      echo "POLICY=$(iptables -S OUTPUT | head -n1) / $(ip6tables -S OUTPUT | head -n1)"' >/dev/null
  docker cp "$STAGE/pre/." $P-pre:/ >/dev/null
  # Not start -a: attaching can miss the output of a container this short-lived.
  docker start $P-pre >/dev/null
  docker wait $P-pre >/dev/null
  docker logs $P-pre 2>&1 || true
  docker rm -f $P-pre >/dev/null
}
expect_refused() {
  local desc=$1 out
  out=$(run_apply "${@:2}")
  if grep -q FATAL <<<"$out" && grep -q RULES_OK <<<"$out" && ! grep -q 'RC=0' <<<"$out"; then
    pass "refused: $desc"
  else
    fail "not refused: $desc"
    echo "${out//$'\n'/$'\n        '}"
  fi
}
# A setting the rules cannot be built from: refused before any rule is
# built, but with every policy already DROP.
APPLY_ENV=()
expect_locked_down() {
  local desc=$1 out
  APPLY_ENV=(-e "$2")
  out=$(run_apply '')
  APPLY_ENV=()
  if grep -q FATAL <<<"$out" && grep -q 'POLICY=-P OUTPUT DROP / -P OUTPUT DROP' <<<"$out" && ! grep -q 'RC=0' <<<"$out"; then
    pass "refused, everything dropped: $desc"
  else
    fail "not refused or not locked down: $desc"
    echo "${out//$'\n'/$'\n        '}"
  fi
}
expect_accepted() {
  local desc=$1 out
  out=$(run_apply "${@:2}")
  if grep -q 'RC=0' <<<"$out" && grep -q RULES_OK <<<"$out"; then
    pass "accepted: $desc"
  else
    fail "wrongly refused: $desc"
    echo "${out//$'\n'/$'\n        '}"
  fi
}
expect_refused "PreDown that flushes the firewall" '/^\[Interface\]/a PreDown = iptables -P OUTPUT ACCEPT; iptables -F OUTPUT'
expect_refused "hook that runs a script" '/^\[Interface\]/a PostUp = /config/up.sh'
expect_refused "hostname endpoint" "s/^Endpoint = .*/Endpoint = vpn.example.com:51820/"
expect_refused "endpoint without a port" "s/^Endpoint = .*/Endpoint = $SERVER_IP/"
expect_refused "split tunnel" "s|^AllowedIPs = .*|AllowedIPs = 10.0.0.0/8|"
expect_refused "full tunnel split in halves" "s|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/1, 128.0.0.0/1|"
expect_refused "IPv6-only tunnel" "s|^AllowedIPs = .*|AllowedIPs = ::/0|"
expect_refused "IPv6 ranges (written 0::/0) without a tunnel IPv6 address" \
  "s|^Address = .*|Address = $TUN_CLIENT/32|; s|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/0, 0::/0|"
expect_locked_down "a zero connection mark" TWG_LOCAL_MARK=0
expect_locked_down "a connection mark sharing bits with the fwmark" TWG_LOCAL_MARK=0xca6c
expect_locked_down "the peer port equal to the web port" TWG_PEER_PORT=$WEB_PORT
expect_refused "Table = off" '/^\[Interface\]/a Table = off'
expect_refused "Table = 1234" '/^\[Interface\]/a Table = 1234'
expect_refused "a second tunnel config next to wg0.conf" '' $'[Interface]\nPostUp = iptables -P OUTPUT ACCEPT'
expect_accepted "FwMark written in hex (0xca6c = 51820)" '/^\[Interface\]/a FwMark = 0xca6c'
expect_accepted "CRLF line endings" 's/$/\r/'

echo
if ((FAILED)); then
  echo "$FAILED check(s) FAILED"
  exit 1
fi
echo "all leak checks passed"
