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

FAILED=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILED=$((FAILED + 1)); }
step() { echo; echo "== $*"; }

# $1=wait: block until the namespace is gone, so a rerun can recreate it.
cleanup() {
  docker rm -f $P-server $P-canary $P-udp >/dev/null 2>&1 || true
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
  local tag=$1 fam=${2:-4} ip=$UDP_IP port=6881
  [[ $fam == 4 ]] || { ip=$UDP_IP6 port=6882; }
  kx transmission sh -c "for i in 1 2 3 4 5; do echo $tag | nc -$fam -u -w1 $ip $port; done" >/dev/null 2>&1 || true
  sleep 1
  docker logs $P-udp 2>&1 | grep -B1 -x "$tag" | sed -n 's/^Connection received on \(::ffff:\)\{0,1\}\([^ ]*\) .*/\2/p' | tail -n1 || true
}
# Records probe results while traffic must not leak; result_summary then
# reports leaks and probes that could not run.
LEAKED="" BROKEN=""
record() {
  local r
  for r in "$@"; do
    case $r in
      leak*) LEAKED="$LEAKED ${r#leak }" ;;
      broken*) BROKEN="$BROKEN ${r#broken }" ;;
      vpn | blocked | "") ;;
      *) LEAKED="$LEAKED $r" ;; # a UDP source address
    esac
  done
}
result_summary() {
  if [[ -n $LEAKED ]]; then
    fail "LEAK $1 (canary saw$LEAKED)"
  elif [[ -n $BROKEN ]]; then
    fail "probes $1 could not run (curl exit$BROKEN), so they prove nothing"
  else
    pass "no direct egress $1"
  fi
  LEAKED="" BROKEN=""
}
# TCP connect check: telnet:// never ends on its own, so curl always times
# out; time_connect is non-zero once the connection was established.
tcp_open() { [[ $("$@" -s -o /dev/null -m 2 -w '%{time_connect}' 2>/dev/null </dev/null) =~ [1-9] ]]; }
# The same from the Transmission container bound to eth0: "open", "blocked"
# (refused or timed out without connecting) or "broken".
tcp_eth0() {
  local out tc rc
  # shellcheck disable=SC2016 # expanded by the pod's shell
  out=$(kx transmission sh -c 'curl -s -o /dev/null -m 2 --interface eth0 -w "%{time_connect}" "$1" </dev/null; echo " rc=$?"' sh "$1" 2>/dev/null || true)
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
# any other failure (exec failed, no eth0) proves nothing.
check_eth0() {
  local what=$1 rc; shift
  rc=$(kx transmission sh -c 'curl -sk -m 4 -o /dev/null --interface eth0 "$@" 2>/dev/null; echo "rc=$?"' sh "$@" |
    sed -n 's/^rc=//p' || true)
  case $rc in
    7 | 28) pass "a socket bound to eth0 cannot reach $what" ;;
    0) fail "LEAK: a socket bound to eth0 reached $what" ;;
    *) fail "eth0 check for $what proves nothing (curl exit ${rc:-none})" ;;
  esac
}
# The same request from an ordinary pod in the namespace.
ordinary_pod() {
  kubectl -n "$NS" run "probe-$RANDOM" --rm -i --restart=Never --quiet --image=curlimages/curl:8.11.1@sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69 --command -- "$@" 2>/dev/null
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
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    exec sleep infinity" >/dev/null
CANARY_IP=$(container_ip $P-canary)
SERVER_IP=$(container_ip $P-server)
UDP_IP=$(container_ip $P-udp)
echo "  node $NODE_IP, VPN server $SERVER_IP, canary $CANARY_IP"
if ((IPV6)); then
  CANARY_IP6=$(container_ip6 $P-canary)
  SERVER_IP6=$(container_ip6 $P-server)
  UDP_IP6=$(container_ip6 $P-udp)
  [[ -n $CANARY_IP6 && -n $SERVER_IP6 ]] || { echo "IPV6=1 but the $KIND_NET network has no IPv6" >&2; exit 1; }
  echo "  VPN server $SERVER_IP6, canary $CANARY_IP6"
fi

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
  --set wireguard.handshakeMaxAgeSeconds=60
  --set persistence.enabled=false
  --set transmission.rpcAuth.username=admin
  --set transmission.rpcAuth.password=kind-test-password
  --set tests.enabled=true
  --set "tests.ipEchoUrl=http://$CANARY_IP/cgi-bin/ip"
)
helm install $RELEASE "$ROOT" -n "$NS" --wait --timeout 5m "${helm_args[@]}" --set networkPolicy.enabled=false
POD=$(kubectl -n "$NS" get pod -l app.kubernetes.io/instance=$RELEASE -o jsonpath='{.items[0].metadata.name}')
wait_for "first handshake" 15 via_vpn || true

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
wg_log=$(kubectl -n "$NS" logs "$POD" -c wireguard)
fw_line=$(grep -n -m1 'kill switch installed' <<<"$wg_log" | cut -d: -f1 || true)
up_line=$(grep -n -m1 'ip link add dev wg0' <<<"$wg_log" | cut -d: -f1 || true)
if [[ -n $fw_line && -n $up_line ]] && ((fw_line < up_line)); then
  pass "kill switch installed before wg-quick ran (log lines $fw_line < $up_line)"
else
  fail "kill switch not logged before wg-quick (installed=${fw_line:-missing}, wg0 up=${up_line:-missing})"
fi

step "egress (in-pod kill switch only, NetworkPolicy off)"
baseline=$(ordinary_pod curl -sS -m 5 "http://$CANARY_IP/cgi-bin/ip" | remote_addr || true)
if [[ -n $baseline && $baseline != "$SERVER_IP" ]]; then
  pass "baseline: an ordinary pod reaches the canary directly (as $baseline)"
else
  fail "baseline: an ordinary pod cannot reach the canary directly (harness broken)"
fi
seen=$(canary_seen)
if [[ $seen == "$SERVER_IP" ]]; then
  pass "egress exits through the VPN (canary saw $seen, node is $NODE_IP)"
else
  fail "egress did not go through the VPN (canary saw '${seen:-nothing}')"
fi
check_eth0 "the canary" "http://$CANARY_IP/cgi-bin/ip"
if ((IPV6)); then
  baseline6=$(ordinary_pod curl -6 -sS -m 5 "http://[$CANARY_IP6]/cgi-bin/ip" | remote_addr || true)
  if [[ -n $baseline6 && $baseline6 != "$SERVER_IP6" ]]; then
    pass "baseline: an ordinary pod reaches the canary directly over IPv6 (as $baseline6)"
  else
    fail "baseline: an ordinary pod cannot reach the canary over IPv6 (harness broken)"
  fi
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
kx wireguard sh -c 'iptables -I TWG-OUTPUT 1 -j ACCEPT && iptables -t mangle -I TWG-POSTROUTING 1 -j RETURN'
if helm_test; then
  fail "helm test passes with the kill switch opened"
elif grep -q 'FAIL  kill switch' <<<"$HELM_TEST_OUT" && grep -q 'LEAK: a socket bound to eth0' <<<"$HELM_TEST_OUT"; then
  pass "helm test catches an opened kill switch and the eth0 leak"
else
  fail "helm test failed for another reason with the kill switch opened"
  echo "$HELM_TEST_OUT" | tail -20
fi
kx wireguard sh -c 'iptables -D TWG-OUTPUT -j ACCEPT; iptables -t mangle -D TWG-POSTROUTING -j RETURN' 2>/dev/null || true
wait_for "kill switch intact" 15 kx wireguard /twg/scripts/firewall.sh check || true

step "sidecar restart with the tunnel up"
before=$(sidecar_restarts)
kx wireguard sh -c 'kill 1' || true
for _ in $(seq 10); do
  record "$(egress4)" "$(egress4 --interface eth0)"
  if ((IPV6)); then record "$(egress6)" "$(egress6 --interface eth0)"; fi
  sleep 1
done
result_summary "during the restart"
if wait_for "sidecar restarted" 30 restarted_since "$before" && wait_for "traffic via VPN" 45 via_vpn; then
  pass "tunnel recovers after restart"
else
  fail "tunnel did not recover after restart"
fi

step "in-pod firewall flushed and tunnel deleted (NetworkPolicy must hold)"
# Only adds the NetworkPolicy; the pod spec is unchanged, so no rollout.
helm upgrade $RELEASE "$ROOT" -n "$NS" --wait --timeout 5m "${helm_args[@]}" --set networkPolicy.enabled=true
if kubectl -n "$NS" get networkpolicy "$RELEASE-transmission-wireguard" >/dev/null 2>&1; then
  pass "NetworkPolicy enabled"
else
  fail "NetworkPolicy not created"
fi
sleep 5
before=$(sidecar_restarts)
# shellcheck disable=SC2016 # expanded by the pod's shell
kx wireguard sh -c 'set -e; for t in iptables ip6tables; do $t -P OUTPUT ACCEPT; $t -F OUTPUT; $t -t mangle -F POSTROUTING; done; ip link del wg0' ||
  fail "flushing the in-pod kill switch failed"
# Prove the in-pod kill switch is really gone, so only the NetworkPolicy
# can be what blocks the probes below.
if ! kx wireguard /twg/scripts/firewall.sh check 2>/dev/null &&
  [[ $(kx wireguard iptables -S OUTPUT | head -n1) == "-P OUTPUT ACCEPT" &&
  -z $(kx wireguard iptables -t mangle -S POSTROUTING | sed 1d) ]]; then
  pass "in-pod kill switch flushed (filter OUTPUT open, no POSTROUTING decision)"
else
  fail "the in-pod kill switch is still in place, so the NetworkPolicy check proves nothing"
fi
record "$(egress4)" "$(egress4 --interface eth0)" "$(udp_seen NOFIREWALL)"
if ((IPV6)); then record "$(egress6)" "$(udp_seen NOFIREWALL6 6)"; fi
result_summary "with the in-pod kill switch gone (NetworkPolicy holds)"
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
if wait_for "the hook to be refused" 45 bad_refused; then
  started=$(kubectl -n "$NS" get pod -l app.kubernetes.io/instance=twg-bad \
    -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="transmission")].state.running}')
  if [[ -z $started ]]; then
    pass "a Secret with a PostUp hook is refused and Transmission never starts"
  else
    fail "Transmission started although the sidecar refused its config"
  fi
else
  fail "the sidecar did not refuse a Secret with a PostUp hook: $(bad_log | tail -n 3)"
fi
helm uninstall twg-bad -n "$NS" >/dev/null

step "pod termination"
# Transmission stops before its sidecar, and the rules live as long as the
# pod's network namespace: nothing may leak while the pod shuts down.
kubectl -n "$NS" delete pod "$POD" --wait=false >/dev/null
for _ in $(seq 15); do
  r=$(egress4)
  [[ $r == "broken exec" ]] && break # the Transmission container is gone
  record "$r" "$(egress4 --interface eth0)"
done
result_summary "while the pod terminates"

echo
if ((FAILED)); then
  echo "$FAILED check(s) FAILED"
  exit 1
fi
echo "all kind leak checks passed"
