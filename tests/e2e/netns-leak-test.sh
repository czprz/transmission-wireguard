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
WG_IMAGE="${WG_IMAGE:-ghcr.io/linuxserver/wireguard:1.0.20250521-r1-ls102}"
TX_IMAGE="${TX_IMAGE:-ghcr.io/linuxserver/transmission:4.1.1-r1-ls343}"
CANARY_IMAGE="${CANARY_IMAGE:-traefik/whoami:v1.10.3}"

P=twg-e2e
NET=$P-net
SUBNET_PREFIX=172.31.250
GW=$SUBNET_PREFIX.1
CANARY_IP=$SUBNET_PREFIX.10
DNS_CANARY_IP=$SUBNET_PREFIX.11
SERVER_IP=$SUBNET_PREFIX.20
POD_IP=$SUBNET_PREFIX.30
CLIENT_IP=$SUBNET_PREFIX.40
SUBNET6_PREFIX=fd31:250:
GW6=$SUBNET6_PREFIX:1
CANARY_IP6=$SUBNET6_PREFIX:10
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
  docker rm -f -v $P-tx $P-l6 $P-wg $P-pod $P-server $P-canary $P-dns $P-pre >/dev/null 2>&1 || true
  docker network rm $NET >/dev/null 2>&1 || true
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

# Source address the canary saw for a request from the pod (empty if blocked).
# Extra arguments go to curl.
canary_seen() {
  as_app curl -sS -m 3 "${@:-http://$CANARY_IP/}" 2>/dev/null |
    sed -n 's/^RemoteAddr: \[\{0,1\}\([^]]*\)\]\{0,1\}:[0-9]*\r\{0,1\}$/\1/p' || true
}
canary_seen6() { canary_seen -6 "$@" "http://[$CANARY_IP6]/"; }
# Send a DNS-port datagram tagged $1 and print the source the canary saw.
dns_seen() {
  as_app sh -c "echo $1 | nc -u -w1 $DNS_CANARY_IP 53" >/dev/null 2>&1 || true
  sleep 2
  docker logs $P-dns 2>&1 | grep -C1 -x "$1" | sed -n 's/^Connection received on \([^ ]*\) .*/\1/p' | tail -n1 || true
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
for image in "$WG_IMAGE" "$TX_IMAGE" "$CANARY_IMAGE"; do
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
docker run -d --name $P-dns --network $NET --ip $DNS_CANARY_IP --entrypoint "" "$WG_IMAGE" \
  sh -c 'while true; do nc -luvn -w 1 53; done' >/dev/null

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
if [[ $(canary_seen) == "$POD_IP" && $(canary_seen6) == "$POD_IP6" && $(dns_seen BASELINE) == "$POD_IP" ]]; then
  pass "baseline: without the kill switch the pod reaches the canaries directly (as $POD_IP and $POD_IP6)"
else
  fail "baseline: pod cannot reach the canary even without the kill switch (harness broken)"
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
docker create --name $P-tx --network container:$P-pod -e PUID=1000 -e PGID=1000 "$TX_IMAGE" >/dev/null
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
if as_app curl -sS -m 3 --interface eth0 "http://$CANARY_IP/" >/dev/null 2>&1; then
  fail "LEAK: a socket bound to eth0 reached the canary directly"
else
  pass "a socket bound to eth0 is rejected"
fi
if as_app curl -6 -sS -m 3 --interface eth0 "http://[$CANARY_IP6]/" >/dev/null 2>&1; then
  fail "LEAK: an IPv6 socket bound to eth0 reached the canary directly"
else
  pass "an IPv6 socket bound to eth0 is rejected"
fi
seen=$(dns_seen TUNNELED)
if [[ $seen == "$SERVER_IP" ]]; then
  pass "DNS-port traffic leaves through the VPN (canary saw $seen)"
else
  fail "DNS-port traffic did not go through the VPN (canary saw '${seen:-nothing}')"
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
if from_cluster nc -z -w 3 $POD_IP $PEER_PORT 2>/dev/null; then
  fail "peer port reachable outside the tunnel"
else
  pass "peer port not reachable outside the tunnel"
fi
if on_server nc -z -w 3 $TUN_CLIENT $PEER_PORT; then
  pass "peer port reachable through the tunnel"
else
  fail "peer port not reachable through the tunnel"
fi
if on_server nc -z -w 3 $TUN_CLIENT $WEB_PORT 2>/dev/null; then
  fail "web UI/RPC reachable from the VPN side"
else
  pass "web UI/RPC not reachable from the VPN side"
fi

step "sidecar restart with the tunnel up (s6 runs wg-quick down; kill switch must stay)"
docker restart -t 10 $P-wg >/dev/null &
restart_pid=$!
leaked=""
for _ in $(seq 10); do
  seen=$(canary_seen)
  [[ -n $seen && $seen != "$SERVER_IP" ]] && leaked=$seen
  seen=$(canary_seen6)
  [[ -n $seen && $seen != "$SERVER_IP6" ]] && leaked=$seen
done
wait $restart_pid
if [[ -z $leaked ]]; then pass "no direct egress during the restart"; else fail "LEAK during restart (canary saw $leaked)"; fi
if wait_for "wg0 back" 60 as_root wg show wg0 && wait_for "traffic via VPN" 30 via_vpn; then
  pass "tunnel recovers after restart"
else
  fail "tunnel did not recover after restart"
fi

step "tunnel interface deleted"
as_root ip link del wg0
seen=$(canary_seen)
if [[ -z $seen ]]; then pass "no TCP egress without wg0"; else fail "LEAK: canary reached without wg0 (saw $seen)"; fi
seen=$(canary_seen6)
if [[ -z $seen ]]; then pass "no IPv6 egress without wg0"; else fail "LEAK: canary reached over IPv6 without wg0 (saw $seen)"; fi
seen=$(dns_seen NOTUNNEL)
if [[ -z $seen ]]; then pass "no DNS/UDP egress without wg0"; else fail "LEAK: DNS canary reached without wg0 (saw $seen)"; fi
if as_root /twg/scripts/firewall.sh tunnel 2>/dev/null; then
  fail "probe did not notice the missing tunnel"
else
  pass "readiness/liveness probe fails while the tunnel is down"
fi

step "sidecar SIGKILL (wg0, its routes and rules left behind)"
docker restart -t 10 $P-wg >/dev/null
wait_for "tunnel back" 60 as_root /twg/scripts/firewall.sh tunnel || true
docker kill $P-wg >/dev/null 2>&1 || true
leaked=""
for _ in 1 2 3; do
  for seen in "$(canary_seen)" "$(canary_seen6)" "$(canary_seen --interface eth0)" "$(canary_seen6 --interface eth0)"; do
    [[ -z $seen || $seen == "$SERVER_IP" || $seen == "$SERVER_IP6" ]] || leaked=$seen
  done
done
if [[ -z $leaked ]]; then pass "no direct egress while the sidecar is dead"; else fail "LEAK while the sidecar is dead (canary saw $leaked)"; fi
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
as_root sh -c 'iptables -F OUTPUT; iptables -P OUTPUT ACCEPT'
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
  docker create --name $P-pre --privileged --network none "${firewall_env[@]}" --entrypoint /bin/bash "$WG_IMAGE" \
    -c '/twg/scripts/firewall.sh apply; rc=$?; /twg/scripts/firewall.sh check && echo RULES_OK; echo "RC=$rc"' >/dev/null
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
expect_refused "IPv6-only tunnel" "s|^AllowedIPs = .*|AllowedIPs = ::/0|"
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
