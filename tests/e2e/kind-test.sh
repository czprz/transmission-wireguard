#!/usr/bin/env bash
# End-to-end leak test on a kind cluster (Kubernetes >= 1.29, kindnet with
# NetworkPolicy support, i.e. kind >= v0.24).
#
# A WireGuard server and an HTTP canary run as containers on kind's Docker
# network, outside the cluster. Traffic that leaks out of the pod reaches the
# canary from the node's IP; traffic through the VPN arrives from the server.
#
# Covers what the Docker test cannot: native sidecar start ordering, kubelet
# probes through the kill switch, pod DNS, the Service, and the NetworkPolicy
# blocking egress even when the in-pod firewall is flushed.
#
# The leak checks first run with the NetworkPolicy disabled, so they test the
# in-pod kill switch alone; the policy is then enabled for the last scenario.
# The chart's `helm test` runs against the healthy and a tampered pod.
#
# Usage: tests/e2e/kind-cluster.sh kindnet && IPV6=1 tests/e2e/kind-test.sh
# (IPV6=1 needs a dual-stack cluster and adds the IPv6 leak checks.)
#
# UPGRADE_FROM=<chart dir> first installs that chart (an earlier release,
# with its defaults and a PVC) and upgrades it to this one, so every check
# runs on an upgraded release. UPGRADE_FLAGS are added to that upgrade, as a
# user following the README's upgrade notes would.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# The chart's default image for $1, so the test follows Renovate's bumps.
chart_image() {
  local tpl=$ROOT/templates/_helpers.tpl repo tag digest
  repo=$(sed -n "s/.*\.Values\.images\.$1 \"repo\" \"\([^\"]*\)\".*/\1/p" "$tpl")
  tag=$(sed -n "s/.*default \"\([^\"]*\)\" \.Values\.images\.$1\.tag.*/\1/p" "$tpl")
  digest=$(sed -n "s/.*default \"\([^\"]*\)\" \.Values\.images\.$1\.digest.*/\1/p" "$tpl")
  [[ -n $repo && -n $tag && -n $digest ]] || { echo "cannot read the $1 image from $tpl" >&2; return 1; }
  echo "$repo:$tag@$digest"
}
WG_IMAGE="${WG_IMAGE:-$(chart_image wireguard)}"
CANARY_IMAGE="${CANARY_IMAGE:-busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec}"
KIND_NET="${KIND_NET:-kind}"
NS="${NS:-twg-e2e}"
RELEASE=twg
P=twg-kind
TUN_SERVER=10.99.0.1
TUN_CLIENT=10.99.0.2
TUN_SERVER6=fd99::1
TUN_CLIENT6=fd99::2
IPV6=${IPV6:-0}
UPGRADE_FROM=${UPGRADE_FROM:-}
read -ra UPGRADE_FLAGS <<<"${UPGRADE_FLAGS:-}"

FAILED=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILED=$((FAILED + 1)); }
step() { echo; echo "== $*"; }

# $1=wait: block until the namespace is gone, so a rerun can recreate it.
# The termination step holds the release pod with a finalizer; release it,
# or the namespace never goes.
HOLD=twg.e2e/hold
cleanup() {
  docker rm -f $P-server $P-canary $P-udp >/dev/null 2>&1 || true
  kubectl -n "$NS" get pods -o name 2>/dev/null | xargs -r kubectl -n "$NS" patch --type=merge \
    -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  kubectl delete namespace "$NS" --ignore-not-found --wait="${1:-false}" --timeout=3m >/dev/null 2>&1 || true
}
cleanup true
# On any failure (including an aborted run) show the pod and tunnel state.
on_exit() {
  local rc=$?
  if ((rc != 0)); then
    kubectl -n "$NS" get pods -o wide || true
    [[ -z ${POD:-} ]] || kubectl -n "$NS" describe pod "$POD" | tail -30 || true
    [[ -z ${POD:-} ]] || kubectl -n "$NS" logs "$POD" -c wireguard --tail 40 || true
    docker logs --tail 20 $P-server 2>&1 | sed 's/^/  server | /' || true
  fi
  [[ -n ${KEEP:-} ]] || cleanup
}
trap on_exit EXIT

wg_tool() { docker run --rm -i --entrypoint wg "$WG_IMAGE" "$@"; }
container_ip() { docker inspect -f "{{(index .NetworkSettings.Networks \"$KIND_NET\").IPAddress}}" "$1"; }
container_ip6() { docker inspect -f "{{(index .NetworkSettings.Networks \"$KIND_NET\").GlobalIPv6Address}}" "$1"; }
kx() { kubectl -n "$NS" exec "$POD" -c "$1" -- "${@:2}"; }
# The canary answers with the client's address (empty if unreachable): for
# checks that traffic does arrive. Leak checks use egress below.
remote_addr() { head -n1 | tr -d '[:space:]'; }
canary_seen() {
  kx transmission curl -sS -m 3 "http://$CANARY_IP/cgi-bin/ip" 2>/dev/null | remote_addr || true
}
canary_seen6() {
  kx transmission curl -6 -sS -m 3 "http://[$CANARY_IP6]/cgi-bin/ip" 2>/dev/null | remote_addr || true
}
# Where a request from the Transmission container went: "vpn", "blocked"
# (refused, timed out or cut off), "leak <address>", or "broken <curl exit>"
# ("broken exec" when kubectl exec failed), which proves nothing.
egress() {
  local out rc seen
  # shellcheck disable=SC2016 # expanded by the pod's shell
  out=$(kx transmission sh -c 'curl -sS -m 3 "$@" 2>/dev/null; rc=$?; echo; echo "rc=$rc"' sh "$@" 2>/dev/null || true)
  rc=$(sed -n 's/^rc=//p' <<<"$out")
  seen=$(grep -v '^rc=' <<<"$out" | remote_addr || true)
  case $rc in
    0) if [[ -z $seen ]]; then echo "broken empty-answer"; return; fi
      if [[ $seen == "$SERVER_IP" || $seen == "${SERVER_IP6:-none}" ]]; then echo vpn; else echo "leak ${seen:-unknown}"; fi ;;
    7 | 28 | 52 | 56) echo blocked ;;
    *) echo "broken ${rc:-exec}" ;;
  esac
}
egress4() { egress "$@" "http://$CANARY_IP/cgi-bin/ip"; }
egress6() { egress -6 "$@" "http://[$CANARY_IP6]/cgi-bin/ip"; }
# UDP datagrams tagged $1 to the UDP canary over IPv${2:-4}; prints the
# source the canary saw (empty if none arrived). IPv6 uses its own port so
# the two listeners do not race for one dual-stack socket.
udp_seen() {
  local tag=$1 fam=${2:-4} ip=$UDP_IP port=6881 out
  [[ $fam == 4 ]] || { ip=$UDP_IP6 port=6882; }
  out=$(kx transmission sh -c "for i in 1 2 3 4 5; do echo $tag | nc -$fam -u -w1 $ip $port; done; echo SENT" 2>/dev/null || true)
  [[ $out == *SENT* ]] || { echo "broken udp-exec"; return; }
  sleep 1
  # Every source that sent the tag, not just the last.
  docker logs $P-udp 2>&1 | grep -B1 -x "$tag" | sed -n 's/^Connection received on \(::ffff:\)\{0,1\}\([^ ]*\) .*/\2/p' |
    sort -u | paste -sd' ' - || true
}
# Records probe results while traffic must not leak; result_summary then
# reports leaks, probes that could not run, too few probes, and (with
# need-blocked as $2) probes that never overlapped the outage.
LEAKED="" BROKEN="" PROBES=0 BLOCKED=0
record() {
  local r
  for r in "$@"; do
    PROBES=$((PROBES + 1))
    case $r in
      leak*) LEAKED="$LEAKED ${r#leak }" ;;
      broken*) BROKEN="$BROKEN ${r#broken }" ;;
      blocked | "") BLOCKED=$((BLOCKED + 1)) ;; # "": no UDP datagram arrived
      vpn | "$SERVER_IP" | "${SERVER_IP6:-none}") ;; # UDP from the server is the tunnel
      *) LEAKED="$LEAKED $r" ;; # UDP source addresses
    esac
  done
}
result_summary() {
  if [[ -n $LEAKED ]]; then
    fail "LEAK $1 (canary saw$LEAKED)"
  elif [[ -n $BROKEN ]]; then
    fail "probes $1 could not run ($BROKEN), so they prove nothing"
  elif ((PROBES < 2)); then
    fail "only $PROBES probe(s) ran $1, which proves nothing"
  elif [[ ${2:-} == need-blocked ]] && ((BLOCKED == 0)); then
    fail "none of the $PROBES probes $1 hit the outage, so they prove nothing"
  else
    pass "no direct egress $1 ($PROBES probes, $BLOCKED blocked)"
  fi
  LEAKED="" BROKEN="" PROBES=0 BLOCKED=0
}
# Sensors that count leaked packets, however the client saw them. Only read
# around windows in which no ordinary pod or helm test talks to them.
# - The canaries count every packet that does not come from the VPN server
#   (IPv6: TCP, UDP and echo only, not neighbour discovery).
# - The VPN server counts new plaintext connections (anything but WireGuard).
# - The release pod counts every new flow leaving eth0 other than WireGuard's
#   own, whatever its destination (a rule after the kill switch's jump in
#   mangle POSTROUTING sees only what it let through).
count_rules() {
  docker run --rm --network "container:$1" --cap-add NET_ADMIN --entrypoint "" "$WG_IMAGE" sh -c "
    set -e
    iptables -w -I INPUT ! -s $SERVER_IP -m comment --comment twg-count
    if [ -n '${SERVER_IP6:-}' ]; then
      for m in '-p tcp' '-p udp' '-p ipv6-icmp --icmpv6-type echo-request'; do
        ip6tables -w -I INPUT ! -s '${SERVER_IP6:-}' \$m -m comment --comment twg-count
      done
    fi"
}
count_plaintext() {
  docker run --rm --network "container:$P-server" --cap-add NET_ADMIN --entrypoint "" "$WG_IMAGE" sh -c "
    set -e
    for m in '-p tcp' '-p udp ! --dport 51820' '-p icmp --icmp-type echo-request'; do
      iptables -w -t mangle -I PREROUTING -i eth0 -m conntrack --ctstate NEW \$m -m comment --comment twg-count
    done
    for m in '-p tcp' '-p udp ! --dport 51820' '-p ipv6-icmp --icmpv6-type echo-request'; do
      ip6tables -w -t mangle -I PREROUTING -i eth0 -m conntrack --ctstate NEW \$m -m comment --comment twg-count
    done"
}
count_escapes() {
  # shellcheck disable=SC2016 # expanded by the pod's shell
  kx wireguard sh -c 'set -e
    for f in 4 6; do
      ipt=iptables server=$1
      [ $f = 4 ] || ipt=ip6tables server=${2:-::1}
      $ipt -w -t mangle -N TWGTEST-ESCAPE
      $ipt -w -t mangle -A TWGTEST-ESCAPE -p udp -d "$server" --dport 51820 -j RETURN
      $ipt -w -t mangle -A TWGTEST-ESCAPE -m comment --comment twg-count -j RETURN
      $ipt -w -t mangle -A POSTROUTING -o eth0 -m conntrack --ctstate NEW -j TWGTEST-ESCAPE
    done' sh "$SERVER_IP" "${SERVER_IP6:-}"
}
# Packets counted by comment twg-count in iptables-save -c output on stdin,
# as "<family> <packets>" lines.
count_lines() {
  awk '/^V6$/ { fam = 6 } !fam { fam = 4 }
    / --comment "?twg-count"?( |$)/ && match($0, /^\[[0-9]+:/) { n[fam] += substr($0, 2, RLENGTH - 2) }
    END { print 4, n[4] + 0; print 6, n[6] + 0 }'
}
# "<sensor> <family> <packets>" for every sensor; "nopod" as $1 leaves out
# the release pod (once it is gone).
sensor_counts() {
  local c out
  for c in $P-canary $P-udp $P-server; do
    out=""
    for _ in 1 2 3; do
      out=$(docker run --rm --network "container:$c" --cap-add NET_ADMIN --entrypoint "" "$WG_IMAGE" \
        sh -c 'iptables-save -c && echo V6 && ip6tables-save -c && echo END' 2>/dev/null || true)
      [[ $out == *END* ]] && break
    done
    [[ $out == *END* ]] || { echo unreadable; return; }
    count_lines <<<"$out" | sed "s/^/$c /"
  done
  [[ ${1:-} != nopod ]] || return 0
  # The sidecar may be restarting: retry for a while.
  for _ in $(seq 15); do
    out=$(kx wireguard sh -c 'iptables-save -c -t mangle && echo V6 && ip6tables-save -c -t mangle && echo END' 2>/dev/null || true)
    [[ $out == *END* ]] && break
    sleep 2
  done
  [[ $out == *END* ]] || { echo unreadable; return; }
  count_lines <<<"$out" | sed "s/^/pod /"
}
canary_hits() {
  local out
  out=$(sensor_counts "$@")
  if [[ $out == *unreadable* ]]; then echo unreadable; else awk '{ t += $3 } END { print t + 0 }' <<<"$out"; fi
}
HITS=unreadable
hits_mark() { HITS=$(canary_hits "$@"); }
hits_check() {
  local now
  now=$(canary_hits "${@:2}")
  if [[ $HITS == unreadable || $now == unreadable ]]; then
    fail "could not read the packet counters $1"
  elif ((now > HITS)); then
    fail "LEAK: $((now - HITS)) packet(s) outside the tunnel reached the canaries, the server or left eth0 $1"
  else
    pass "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic $1"
  fi
  HITS=$now
}
# TCP connect check: telnet:// never ends on its own, so curl always times
# out; time_connect is non-zero once the connection was established.
tcp_open() { [[ $("$@" -s -o /dev/null -m 2 -w '%{time_connect}' 2>/dev/null </dev/null) =~ [1-9] ]]; }
# The same from the Transmission container bound to eth0: "open", "blocked"
# (refused or timed out without connecting) or "broken".
tcp_eth0() {
  local out tc rc
  # shellcheck disable=SC2016 # expanded by the pod's shell
  out=$(kx transmission sh -c 'curl -s -o /dev/null -m 2 --interface "if!eth0" -w "%{time_connect}" "$1" </dev/null; echo " rc=$?"' sh "$1" 2>/dev/null || true)
  tc=${out%% *} rc=${out##*rc=}
  if [[ $tc =~ [1-9] ]]; then
    echo open
  elif [[ $out == *rc=* && $rc =~ ^(7|28)$ ]]; then
    echo blocked
  else
    echo "broken ${out:-exec}"
  fi
}
# A request bound to eth0 must be refused (curl exit 7) or time out (28);
# any other failure (exec failed, no eth0) proves nothing. "if!" makes curl
# fail rather than fall back to binding eth0's address (into the tunnel).
ETH0=(--interface 'if!eth0')
check_eth0() {
  local what=$1 rc; shift
  rc=$(kx transmission sh -c 'curl -sk -m 4 -o /dev/null --interface "if!eth0" "$@" 2>/dev/null; echo "rc=$?"' sh "$@" |
    sed -n 's/^rc=//p' || true)
  case $rc in
    7 | 28) pass "a socket bound to eth0 cannot reach $what" ;;
    0) fail "LEAK: a socket bound to eth0 reached $what" ;;
    *) fail "eth0 check for $what proves nothing (curl exit ${rc:-none})" ;;
  esac
}
# The same request from an ordinary pod in the namespace: its output and
# exit code. Not `kubectl run -i --rm`, which loses the output of a command
# that ends before kubectl attaches.
ordinary_pod() {
  local name="probe-$RANDOM$RANDOM" phase="" rc
  kubectl -n "$NS" run "$name" --restart=Never --quiet --image=curlimages/curl:8.11.1@sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69 --command -- "$@" >/dev/null 2>&1 || return 1
  for _ in $(seq 120); do
    phase=$(kubectl -n "$NS" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [[ $phase == Succeeded || $phase == Failed ]] && break
    sleep 0.5
  done
  kubectl -n "$NS" logs "$name" 2>/dev/null || true
  rc=$(kubectl -n "$NS" get pod "$name" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)
  kubectl -n "$NS" delete pod "$name" --wait=false >/dev/null 2>&1 || true
  [[ $rc =~ ^[0-9]+$ ]] || rc=1
  return "$rc"
}
via_vpn() { [[ $(canary_seen) == "$SERVER_IP" ]]; }
wait_for() {
  local desc=$1 tries=$2; shift 2
  for _ in $(seq "$tries"); do "$@" >/dev/null 2>&1 && return 0; sleep 2; done
  echo "        timed out waiting for: $desc" >&2
  return 1
}
sidecar_restarts() {
  kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.initContainerStatuses[?(@.name=="wireguard")].restartCount}'
}
# Re-reads the count on every call, so it can be polled with wait_for.
restarted_since() { (($(sidecar_restarts) > $1)); }
# Runs the chart's helm test; its output is kept in HELM_TEST_OUT.
helm_test() {
  local rc=0
  HELM_TEST_OUT=$(helm test $RELEASE -n "$NS" --logs --timeout 3m 2>&1) || rc=$?
  # helm can print the pod's log more than once.
  sed -n 's/^\(PASS\|FAIL\)  /        test pod: &/p' <<<"$HELM_TEST_OUT" | awk '!seen[$0]++'
  return $rc
}

step "setup"
# Pull up front with retries: registries rate-limit bursts of pulls.
for image in "$WG_IMAGE" "$CANARY_IMAGE"; do
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
NODE_IP=$(container_ip kind-control-plane)

# Plain-text "what is my IP": busybox httpd hands IPv4 clients over as
# [::ffff:a.b.c.d].
docker run -d --name $P-canary --network "$KIND_NET" "$CANARY_IMAGE" sh -c '
    mkdir -p /www/cgi-bin
    cat > /www/cgi-bin/ip <<"CGI"
#!/bin/sh
a=${REMOTE_ADDR#[}; a=${a%]}; a=${a#::ffff:}
printf "Content-Type: text/plain\r\n\r\n%s\n" "$a"
CGI
    chmod +x /www/cgi-bin/ip
    exec httpd -f -p 80 -h /www' >/dev/null
# UDP canary (a DHT-style port), logging the source of every datagram.
docker run -d --name $P-udp --network "$KIND_NET" --entrypoint "" "$WG_IMAGE" \
  sh -c 'while true; do nc -4 -luvn -w 1 6881; done & while true; do nc -6 -luvn -w 1 6882; done' >/dev/null
docker run -d --name $P-server --network "$KIND_NET" --privileged \
  --entrypoint bash "$WG_IMAGE" -c "
    set -e
    echo '$SERVER_KEY' > /tmp/k
    ip link add wg0 type wireguard
    wg set wg0 listen-port 51820 private-key /tmp/k peer '$CLIENT_PUB' allowed-ips $TUN_CLIENT/32,$TUN_CLIENT6/128
    ip addr add $TUN_SERVER/24 dev wg0
    ip addr add $TUN_SERVER6/64 dev wg0
    ip link set wg0 up
    sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1
    # Only tunnel traffic is forwarded and NATed, like a real VPN server: a
    # plaintext packet routed via the server must not come out as its own.
    for ipt in iptables ip6tables; do
      \$ipt -P FORWARD DROP
      \$ipt -A FORWARD -i wg0 -o eth0 -j ACCEPT
      \$ipt -A FORWARD -i eth0 -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    done
    iptables -t nat -A POSTROUTING -s 10.99.0.0/24 -o eth0 -j MASQUERADE
    ip6tables -t nat -A POSTROUTING -s fd99::/64 -o eth0 -j MASQUERADE
    exec sleep infinity" >/dev/null
CANARY_IP=$(container_ip $P-canary)
SERVER_IP=$(container_ip $P-server)
UDP_IP=$(container_ip $P-udp)
SERVER_IP6=""
echo "  node $NODE_IP, VPN server $SERVER_IP, canary $CANARY_IP"
if ((IPV6)); then
  CANARY_IP6=$(container_ip6 $P-canary)
  SERVER_IP6=$(container_ip6 $P-server)
  UDP_IP6=$(container_ip6 $P-udp)
  [[ -n $CANARY_IP6 && -n $SERVER_IP6 ]] || { echo "IPV6=1 but the $KIND_NET network has no IPv6" >&2; exit 1; }
  echo "  VPN server $SERVER_IP6, canary $CANARY_IP6"
fi
count_rules $P-canary
count_rules $P-udp
count_plaintext

kubectl create namespace "$NS" >/dev/null
kubectl -n "$NS" create secret generic wg-client --from-file=wg0.conf=/dev/stdin >/dev/null <<EOF
[Interface]
PrivateKey = $CLIENT_KEY
Address = $TUN_CLIENT/32, $TUN_CLIENT6/128

[Peer]
PublicKey = $SERVER_PUB
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $SERVER_IP:51820
PersistentKeepalive = 5
EOF
helm_args=(
  --set wireguard.existingSecret=wg-client
  --set "wireguard.endpoints[0].ip=$SERVER_IP"
  --set "wireguard.endpoints[0].port=51820"
  --set wireguard.handshakeMaxAgeSeconds=180
  --set transmission.rpcAuth.username=admin
  --set transmission.rpcAuth.password=kind-test-password
  --set tests.enabled=true
  --set "tests.ipEchoUrl=http://$CANARY_IP/cgi-bin/ip"
)
if [[ -z $UPGRADE_FROM ]]; then
  # A fresh install, with /config on an emptyDir and the downloads on a PVC of their own.
  helm_args+=(--set persistence.enabled=false --set persistence.downloads.enabled=true)
  helm install $RELEASE "$ROOT" -n "$NS" --wait --timeout 5m "${helm_args[@]}" --set networkPolicy.enabled=false
else
  step "upgrade from $(helm show chart "$UPGRADE_FROM" | sed -n 's/^version: //p')"
  # The earlier release as its users run it: its defaults, its PVC. Its pod
  # need not become ready here; the upgrade is what is tested.
  helm install $RELEASE "$UPGRADE_FROM" -n "$NS" --set wireguard.existingSecret=wg-client >/dev/null
  kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Bound "pvc/$RELEASE-transmission-wireguard" --timeout 3m >/dev/null 2>&1 ||
    kubectl -n "$NS" get pvc "$RELEASE-transmission-wireguard" >/dev/null
  old_pvc=$(kubectl -n "$NS" get pvc "$RELEASE-transmission-wireguard" -o jsonpath='{.metadata.uid}')
  if helm upgrade $RELEASE "$ROOT" -n "$NS" --wait --timeout 5m "${UPGRADE_FLAGS[@]}" "${helm_args[@]}" --set networkPolicy.enabled=false; then
    pass "helm upgrade from the earlier release succeeds${UPGRADE_FLAGS[*]:+ (with ${UPGRADE_FLAGS[*]})}"
  else
    fail "helm upgrade from the earlier release fails"
    exit 1
  fi
  if [[ $(kubectl -n "$NS" get pvc "$RELEASE-transmission-wireguard" -o jsonpath='{.metadata.uid}') == "$old_pvc" ]]; then
    pass "the upgrade keeps the release's PVC, and the downloads on it"
  else
    fail "the upgrade replaced the release's PVC"
  fi
fi
POD=$(kubectl -n "$NS" get pod -l app.kubernetes.io/instance=$RELEASE -o jsonpath='{.items[0].metadata.name}')
POD_UID=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}')
wait_for "first handshake" 15 via_vpn || true
count_escapes || fail "could not install the pod's eth0 sensor"

step "pod start"
if kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=10s >/dev/null; then
  pass "pod is Ready (kubelet probes work through the kill switch)"
else
  fail "pod not Ready"
fi
wg_started=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.initContainerStatuses[?(@.name=="wireguard")].state.running.startedAt}')
tx_started=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[?(@.name=="transmission")].state.running.startedAt}')
if [[ -n $wg_started && -n $tx_started && ! $tx_started < $wg_started ]]; then
  pass "Transmission started after the WireGuard sidecar ($wg_started <= $tx_started)"
else
  fail "start order wrong (wireguard=$wg_started transmission=$tx_started)"
fi
if ! kx transmission grep -q ' /data ' /proc/mounts; then
  fail "nothing is mounted at /data"
elif [[ -z $UPGRADE_FROM ]]; then
  pass "the downloads PVC is mounted at /data ($(kubectl -n "$NS" get pvc "$RELEASE-transmission-wireguard-downloads" -o jsonpath='{.status.phase}'))"
else
  pass "the release's PVC is mounted at /data"
fi
wg_log=$(kubectl -n "$NS" logs "$POD" -c wireguard)
fw_line=$(grep -n -m1 'kill switch installed' <<<"$wg_log" | cut -d: -f1 || true)
up_line=$(grep -n -m1 'ip link add dev wg0' <<<"$wg_log" | cut -d: -f1 || true)
if [[ -n $fw_line && -n $up_line ]] && ((fw_line < up_line)); then
  pass "kill switch installed before wg-quick ran (log lines $fw_line < $up_line)"
else
  fail "kill switch not logged before wg-quick (installed=${fw_line:-missing}, wg0 up=${up_line:-missing})"
fi

step "egress (in-pod kill switch only, NetworkPolicy off)"
before_counts=$(sensor_counts)
baseline=$(ordinary_pod curl -sS -m 5 "http://$CANARY_IP/cgi-bin/ip" | remote_addr || true)
if [[ -n $baseline && $baseline != "$SERVER_IP" ]]; then
  pass "baseline: an ordinary pod reaches the canary directly (as $baseline)"
else
  fail "baseline: an ordinary pod cannot reach the canary directly (harness broken)"
fi
if ((IPV6)); then
  baseline6=$(ordinary_pod curl -6 -sS -m 5 "http://[$CANARY_IP6]/cgi-bin/ip" | remote_addr || true)
  if [[ -n $baseline6 && $baseline6 != "$SERVER_IP6" ]]; then
    pass "baseline: an ordinary pod reaches the canary directly over IPv6 (as $baseline6)"
  else
    fail "baseline: an ordinary pod cannot reach the canary over IPv6 (harness broken)"
  fi
fi
# Each sensor and family must count: UDP from outside the cluster, plaintext
# to the server, and a flow the release pod sends out eth0 with the kill
# switch bypassed for a moment (an ACCEPT and a RETURN at the top of its chains).
for f in 4 6; do
  ((f == 4 || IPV6)) || continue
  ip=$UDP_IP port=6881 server=$SERVER_IP
  ((f == 4)) || ip=$UDP_IP6 port=6882 server=$SERVER_IP6
  docker run --rm --network "$KIND_NET" --entrypoint "" "$WG_IMAGE" sh -c \
    "echo BASELINE | nc -$f -u -w1 $ip $port; nc -$f -z -w2 $server 80" >/dev/null 2>&1 || true
done
# shellcheck disable=SC2016 # expanded by the pod's shell
bypass='$1 -I TWG-OUTPUT 1 -j ACCEPT && $1 -t mangle -I TWG-POSTROUTING 1 -j RETURN'
# shellcheck disable=SC2016
restore='$1 -D TWG-OUTPUT -j ACCEPT; $1 -t mangle -D TWG-POSTROUTING -j RETURN'
kx wireguard sh -c "$bypass" sh iptables >/dev/null
r=$(egress4 "${ETH0[@]}")
kx wireguard sh -c "$restore" sh iptables >/dev/null
if ((IPV6)); then
  kx wireguard sh -c "$bypass" sh ip6tables >/dev/null
  r6=$(egress6 "${ETH0[@]}")
  kx wireguard sh -c "$restore" sh ip6tables >/dev/null
fi
after_counts=$(sensor_counts)
dead=$(join -j1 <(awk '{ print $1 "/" $2, $3 }' <<<"$before_counts" | sort) <(awk '{ print $1 "/" $2, $3 }' <<<"$after_counts" | sort) |
  awk -v v6="$IPV6" '$3 <= $2 && (v6 == 1 || $1 !~ /\/6$/) { printf " %s", $1 }')
if [[ $before_counts == *unreadable* || $after_counts == *unreadable* ]]; then
  fail "baseline: the packet counters cannot be read (harness broken)"
elif [[ -n $dead ]]; then
  fail "baseline: these sensors did not count direct packets:$dead (harness broken)"
elif [[ $r != leak* ]] || { ((IPV6)) && [[ ${r6:-} != leak* ]]; }; then
  fail "baseline: with the kill switch bypassed the pod did not leak via eth0 ($r ${r6:-}), so the eth0 checks prove nothing"
else
  pass "baseline: every sensor counts direct packets per family, and the pod leaks via eth0 once the kill switch is bypassed"
fi
wait_for "kill switch intact" 15 kx wireguard /twg/scripts/firewall.sh check || fail "the kill switch did not pass check after the baseline"
hits_mark
seen=$(canary_seen)
if [[ $seen == "$SERVER_IP" ]]; then
  pass "egress exits through the VPN (canary saw $seen, node is $NODE_IP)"
else
  fail "egress did not go through the VPN (canary saw '${seen:-nothing}')"
fi
check_eth0 "the canary" "http://$CANARY_IP/cgi-bin/ip"
if ((IPV6)); then
  seen=$(canary_seen6)
  if [[ $seen == "$SERVER_IP6" ]]; then
    pass "IPv6 egress exits through the VPN (canary saw $seen)"
  else
    fail "IPv6 egress did not go through the VPN (canary saw '${seen:-nothing}')"
  fi
  check_eth0 "the canary over IPv6" -6 "http://[$CANARY_IP6]/cgi-bin/ip"
fi
seen=$(udp_seen TUNNELED)
if [[ $seen == "$SERVER_IP" ]]; then
  pass "UDP leaves through the VPN (canary saw $seen)"
else
  fail "UDP did not go through the VPN (canary saw '${seen:-nothing}')"
fi
if ((IPV6)); then
  seen=$(udp_seen TUNNELED6 6)
  if [[ $seen == "$SERVER_IP6" ]]; then
    pass "IPv6 UDP leaves through the VPN (canary saw $seen)"
  else
    fail "IPv6 UDP did not go through the VPN (canary saw '${seen:-nothing}')"
  fi
fi
hits_check "from the release pod"
nameservers=$(kx transmission sed -n 's/^nameserver[[:space:]]*//p' /etc/resolv.conf | sort | tr '\n' ' ' || true)
if [[ $nameservers == "1.0.0.1 1.1.1.1 " ]]; then
  pass "pod DNS uses the configured nameservers only"
else
  fail "pod nameservers are '${nameservers:-none}', want the configured 1.1.1.1 and 1.0.0.1"
fi
dns_ip=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')
# Bound to eth0, so a pass means the kill switch blocked it, not that the
# query went into the tunnel and got lost there.
if tcp_open ordinary_pod curl "telnet://$dns_ip:53"; then
  r=$(tcp_eth0 "telnet://$dns_ip:53")
  case $r in
    blocked) pass "cluster DNS ($dns_ip) unreachable from the pod via eth0 (reachable from an ordinary pod)" ;;
    open) fail "LEAK: cluster DNS ($dns_ip) reachable from the pod via eth0" ;;
    *) fail "cluster DNS check via eth0 proves nothing ($r)" ;;
  esac
else
  fail "baseline: cluster DNS not reachable from an ordinary pod (test broken)"
fi
api_ip=$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}')
if ordinary_pod curl -sk -m 4 -o /dev/null "https://$api_ip/version"; then
  check_eth0 "the Kubernetes API (reachable from an ordinary pod)" "https://$api_ip/version"
else
  fail "baseline: the Kubernetes API is not reachable from an ordinary pod (test broken)"
fi

step "web UI"
code=$(ordinary_pod curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://$RELEASE-transmission-wireguard:9091/transmission/web/" || true)
# kubectl run -i can print the output twice (attach, then the logs).
code=${code:0:3}
if [[ $code =~ ^(200|301|401|409)$ ]]; then
  pass "web UI reachable through the Service (HTTP $code)"
else
  fail "web UI not reachable through the Service (HTTP '${code}')"
fi

step "helm test"
if helm_test && grep -q 'PASS  the Transmission container holds no network capabilities' <<<"$HELM_TEST_OUT"; then
  pass "helm test passes on the healthy release (capabilities checked)"
else
  fail "helm test fails on the healthy release"
  echo "$HELM_TEST_OUT" | tail -20
fi
# An ACCEPT at the top of both kill switch chains: the test must catch the
# altered rules and the resulting eth0 leak. (-D by spec: if liveness
# restarts the sidecar meanwhile, rule 1 is a real rule again.)
# shellcheck disable=SC2016 # expanded by the pod's shell
kx wireguard sh -c 'for t in iptables ip6tables; do $t -I TWG-OUTPUT 1 -j ACCEPT && $t -t mangle -I TWG-POSTROUTING 1 -j RETURN || exit 1; done'
if helm_test; then
  fail "helm test passes with the kill switch opened"
elif grep -q 'FAIL  kill switch' <<<"$HELM_TEST_OUT" && grep -q 'LEAK: a socket bound to eth0' <<<"$HELM_TEST_OUT"; then
  pass "helm test catches an opened kill switch and the eth0 leak"
else
  fail "helm test failed for another reason with the kill switch opened"
  echo "$HELM_TEST_OUT" | tail -20
fi
# shellcheck disable=SC2016
kx wireguard sh -c 'for t in iptables ip6tables; do $t -D TWG-OUTPUT -j ACCEPT; $t -t mangle -D TWG-POSTROUTING -j RETURN; done' 2>/dev/null || true
wait_for "kill switch intact" 15 kx wireguard /twg/scripts/firewall.sh check || true

step "sidecar restart with the tunnel up"
before=$(sidecar_restarts)
hits_mark
kx wireguard sh -c 'kill 1' || fail "could not stop the sidecar"
# Probe until the sidecar has restarted and at least one probe hit the
# outage. Unbound probes only: an eth0-bound one is blocked every time, so
# it would satisfy "hit the outage" without proving anything.
for _ in $(seq 30); do
  record "$(egress4)"
  if ((IPV6)); then record "$(egress6)"; fi
  if restarted_since "$before" && ((BLOCKED > 0)); then break; fi
  sleep 1
done
result_summary "during the restart" need-blocked
hits_check "during the restart"
if wait_for "sidecar restarted" 30 restarted_since "$before" && wait_for "traffic via VPN" 45 via_vpn; then
  pass "tunnel recovers after restart"
else
  fail "tunnel did not recover after restart"
fi

step "packets marked by a stray mangle rule"
# Marked packets are re-routed out eth0 after filter OUTPUT; the POSTROUTING
# decision must still drop them.
wait_for "kill switch intact" 30 kx wireguard /twg/scripts/firewall.sh check || true
hits_mark
kx wireguard sh -c 'iptables -t mangle -A OUTPUT -j MARK --set-mark 51820 && ip6tables -t mangle -A OUTPUT -j MARK --set-mark 51820'
for _ in 1 2; do
  record "$(egress4)" "$(egress4 "${ETH0[@]}")" "$(udp_seen MARKED$RANDOM)"
  if ((IPV6)); then record "$(egress6)" "$(egress6 "${ETH0[@]}")" "$(udp_seen MARKED6$RANDOM 6)"; fi
done
kx wireguard sh -c 'iptables -t mangle -D OUTPUT -j MARK --set-mark 51820; ip6tables -t mangle -D OUTPUT -j MARK --set-mark 51820' || true
result_summary "with every packet marked"
hits_check "with every packet marked"
wait_for "traffic via VPN" 45 via_vpn || true

step "in-pod firewall flushed and tunnel deleted (NetworkPolicy must hold)"
before=$(sidecar_restarts)
# shellcheck disable=SC2016 # expanded by the pod's shell
kx wireguard sh -c 'set -e; for t in iptables ip6tables; do $t -P OUTPUT ACCEPT; $t -F OUTPUT; $t -t mangle -F POSTROUTING; done; ip link del wg0' ||
  fail "flushing the in-pod kill switch failed"
# Positive control: without the kill switch and before the policy, the pod
# does leak, so "blocked" below is the policy's doing.
r=$(egress4)
if [[ $r == leak* ]]; then
  pass "positive control: with the kill switch flushed and no NetworkPolicy the pod leaks (${r#leak })"
else
  fail "the flushed pod did not leak without the NetworkPolicy ($r), so the policy check proves nothing"
fi
# Only adds the NetworkPolicy; the pod spec is unchanged, so no rollout.
helm upgrade $RELEASE "$ROOT" -n "$NS" --wait --timeout 5m "${helm_args[@]}" --set networkPolicy.enabled=true
if kubectl -n "$NS" get networkpolicy "$RELEASE-transmission-wireguard" >/dev/null 2>&1; then
  pass "NetworkPolicy enabled"
else
  fail "NetworkPolicy not created"
fi
if [[ $(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}' 2>/dev/null) == "$POD_UID" ]]; then
  pass "the upgrade kept the same pod"
else
  fail "the upgrade replaced the pod, so the probes below would test a fresh kill switch"
fi
sleep 5
# Prove the in-pod kill switch is really gone, so only the NetworkPolicy
# can be what blocks the probes below.
flushed() {
  local t
  kx wireguard /twg/scripts/firewall.sh check 2>/dev/null && return 1
  for t in iptables ip6tables; do
    [[ $(kx wireguard $t -S OUTPUT | head -n1) == "-P OUTPUT ACCEPT" &&
      -z $(kx wireguard $t -t mangle -S POSTROUTING | sed 1d) ]] || return 1
  done
}
if flushed; then
  pass "in-pod kill switch flushed (IPv4 and IPv6 filter OUTPUT open, no POSTROUTING decision)"
else
  fail "the in-pod kill switch is still in place, so the NetworkPolicy check proves nothing"
fi
hits_mark nopod
record "$(egress4)" "$(egress4 "${ETH0[@]}")" "$(udp_seen NOFIREWALL)"
if ((IPV6)); then record "$(egress6)" "$(udp_seen NOFIREWALL6 6)"; fi
result_summary "with the in-pod kill switch gone (NetworkPolicy holds)"
hits_check "with the in-pod kill switch gone (outside sensors)" nopod
# Liveness needs 3 failures 30s apart, plus the restart itself.
if wait_for "liveness restart" 90 restarted_since "$before"; then
  pass "liveness probe restarted the sidecar"
else
  fail "liveness probe did not restart the sidecar"
fi
if wait_for "kill switch restored" 30 kx wireguard /twg/scripts/firewall.sh check && wait_for "traffic via VPN" 45 via_vpn; then
  pass "kill switch and tunnel restored"
else
  fail "kill switch or tunnel not restored"
fi

if helm_test; then
  pass "helm test passes after recovery, with the NetworkPolicy on"
else
  fail "helm test fails after recovery"
  echo "$HELM_TEST_OUT" | tail -20
fi

step "refused config from an existing Secret"
# The chart cannot see a Secret's contents; the sidecar must refuse it at
# runtime and Transmission must never start.
kubectl -n "$NS" create secret generic wg-hook --from-file=wg0.conf=/dev/stdin >/dev/null <<EOF
[Interface]
PrivateKey = $CLIENT_KEY
Address = $TUN_CLIENT/32
PostUp = iptables -P OUTPUT ACCEPT

[Peer]
PublicKey = $SERVER_PUB
AllowedIPs = 0.0.0.0/0
Endpoint = $SERVER_IP:51820
EOF
helm install twg-bad "$ROOT" -n "$NS" --set wireguard.existingSecret=wg-hook \
  --set "wireguard.endpoints[0].ip=$SERVER_IP" --set persistence.enabled=false \
  --set networkPolicy.enabled=false --set transmission.rpcAuth.allowAnonymous=true >/dev/null
bad_log() { kubectl -n "$NS" logs -l app.kubernetes.io/instance=twg-bad -c wireguard --tail=-1 2>/dev/null || true; }
bad_refused() { bad_log | grep -q 'FATAL.*hooks'; }
# Transmission's state, now and in any earlier run: empty if it never ran.
tx_ran() {
  kubectl -n "$NS" get pod -l app.kubernetes.io/instance=twg-bad -o jsonpath='{range .items[*].status.containerStatuses[?(@.name=="transmission")]}{.state.running}{.state.terminated}{.lastState.running}{.lastState.terminated}{end}'
}
if wait_for "the hook to be refused" 45 bad_refused; then
  first=$(tx_ran)
  sleep 20 # the sidecar keeps restarting; Transmission must stay waiting
  if [[ -z $first && -z $(tx_ran) ]]; then
    pass "a Secret with a PostUp hook is refused and Transmission never starts"
  else
    fail "Transmission started although the sidecar refused its config"
  fi
else
  fail "the sidecar did not refuse a Secret with a PostUp hook: $(bad_log | tail -n 3)"
fi
helm uninstall twg-bad -n "$NS" >/dev/null

step "Transmission's liveness probe"
# Every outage above (sidecar restarts, the deleted tunnel) left
# Transmission listening on the tunnel address, so its probe must never
# have restarted it.
tx_restarts=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[?(@.name=="transmission")].restartCount}')
if [[ $tx_restarts == 0 ]]; then
  pass "Transmission was never restarted, through every sidecar restart and tunnel outage"
else
  fail "Transmission was restarted ${tx_restarts:-?} times: $(kubectl -n "$NS" get events --field-selector "involvedObject.name=$POD" -o jsonpath='{range .items[?(@.reason=="Unhealthy")]}{.message}{"; "}{end}' | cut -c1-300)"
fi

step "pod termination"
# Transmission stops before its sidecar, and the rules live as long as the
# pod's network namespace: nothing may leak while the pod shuts down.
# A loop inside the Transmission container probes until the container is
# gone; the canaries' counters see whatever it sent.
# The sidecar outlives Transmission, so a second loop in it covers its own
# shutdown (s6 runs wg-quick down) too.
term_probe="while :; do curl -sS -m 2 http://$CANARY_IP/cgi-bin/ip 2>/dev/null || echo blocked;"
((IPV6)) && term_probe+=" curl -6 -sS -m 2 http://[$CANARY_IP6]/cgi-bin/ip 2>/dev/null || echo blocked;"
term_probe+=" sleep 0.5; done"
declare -A term_log term_pid started
for c in transmission wireguard; do
  term_log[$c]=$(mktemp)
  # Only stdout: kubectl reports the container's end on stderr.
  kx $c sh -c "$term_probe" >"${term_log[$c]}" 2>/dev/null &
  term_pid[$c]=$!
done
sleep 3
hits_mark nopod
for c in transmission wireguard; do started[$c]=$(wc -l <"${term_log[$c]}"); done
# A finalizer keeps the pod object after its containers end, so their exit
# codes can be read; otherwise it is often gone before the kubelet's last
# status update is seen.
grace=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.terminationGracePeriodSeconds}')
kubectl -n "$NS" patch pod "$POD" --type=merge -p "{\"metadata\":{\"finalizers\":[\"$HOLD\"]}}" >/dev/null
term_states='{range .status.containerStatuses[*]} {.name}={.state.terminated.exitCode}@{.state.terminated.finishedAt}{end}{range .status.initContainerStatuses[*]} {.name}={.state.terminated.exitCode}@{.state.terminated.finishedAt}{end}'
# Each container's exit code, once it has one.
exit_code() { grep -o " $1=[0-9]*@" <<<"$states" | tr -dc '0-9' || true; }
deleted=$(date +%s)
kubectl -n "$NS" delete pod "$POD" --wait=false >/dev/null
stopped=0 states=""
for _ in $(seq $((grace + 45))); do
  states=$(kubectl -n "$NS" get pod "$POD" -o jsonpath="$term_states" 2>/dev/null || true)
  if [[ -n $(exit_code transmission) && -n $(exit_code wireguard) ]]; then stopped=1; break; fi
  sleep 1
done
took=$(($(date +%s) - deleted))
echo "  INFO  containers stopped after ${took}s (grace ${grace}s):$states"
# The image stops Transmission through its RPC with the chart's
# credentials; if that fails, Transmission is killed when the grace period
# ends (exit 137) without saving its state.
tx_exit=$(exit_code transmission)
if ((!stopped)); then
  fail "the containers did not stop within the pod's grace period plus 45 s, so its shutdown was not observed to the end"
elif [[ $tx_exit == 0 ]] && ((took < grace)); then
  pass "Transmission stops on SIGTERM (exit 0), and both containers end in ${took}s, within the ${grace}s grace period"
else
  fail "Transmission did not stop cleanly (exit ${tx_exit:-none}, containers stopped after ${took}s of a ${grace}s grace period)"
fi
if ((took > grace / 2)); then
  docker exec kind-control-plane journalctl -u kubelet --no-pager --since "-$((grace + 120))s" 2>/dev/null |
    grep -F "$POD" | grep -iE 'kill|grace|terminat|stop' | tail -n 15 | cut -c1-400 | sed 's/^/        kubelet: /' || true
fi
kubectl -n "$NS" patch pod "$POD" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null
kubectl -n "$NS" wait --for=delete "pod/$POD" --timeout=60s >/dev/null || fail "the pod was not deleted once released"
for c in transmission wireguard; do
  kill "${term_pid[$c]}" 2>/dev/null || true
  while read -r line; do
    line=$(tr -d '[:space:]' <<<"$line")
    case $line in
      blocked) record blocked ;;
      "$SERVER_IP" | "${SERVER_IP6:-none}") record vpn ;;
      *[0-9].*[0-9] | *:*) record "leak $line" ;; # an address
      *) ;; # a line cut off when the container was killed
    esac
  done < <(tail -n +$((started[$c] + 1)) "${term_log[$c]}")
  rm -f "${term_log[$c]}"
done
result_summary "while the pod terminates"
hits_check "while the pod terminates" nopod

echo
if ((FAILED)); then
  echo "$FAILED check(s) FAILED"
  exit 1
fi
echo "all kind leak checks passed"
