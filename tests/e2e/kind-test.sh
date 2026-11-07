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
WG_IMAGE="${WG_IMAGE:-ghcr.io/linuxserver/wireguard:1.0.20250521-r1-ls102}"
CANARY_IMAGE="${CANARY_IMAGE:-busybox:1.37.0}"
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

cleanup() {
  docker rm -f $P-server $P-canary >/dev/null 2>&1 || true
  kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
}
cleanup
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
# The canary answers with the client's address (empty if blocked). Extra
# arguments go to curl.
remote_addr() { head -n1 | tr -d '[:space:]'; }
canary_seen() {
  kx transmission curl -sS -m 3 "$@" "http://$CANARY_IP/cgi-bin/ip" 2>/dev/null | remote_addr || true
}
canary_seen6() {
  kx transmission curl -6 -sS -m 3 "$@" "http://[$CANARY_IP6]/cgi-bin/ip" 2>/dev/null | remote_addr || true
}
# TCP connect check: telnet:// never ends on its own, so curl always times
# out; time_connect says whether the connection was established.
tcp_open() { [[ $("$@" -s -o /dev/null -m 2 -w '%{time_connect}' 2>/dev/null </dev/null) =~ ^0*[.,]0*[1-9] ]]; }
# The same request from an ordinary pod in the namespace.
ordinary_pod() {
  kubectl -n "$NS" run "probe-$RANDOM" --rm -i --restart=Never --quiet --image=curlimages/curl:8.11.1 --command -- "$@" 2>/dev/null
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
  sed -n 's/^\(PASS\|FAIL\)  /        test pod: &/p' <<<"$HELM_TEST_OUT"
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
echo "  node $NODE_IP, VPN server $SERVER_IP, canary $CANARY_IP"
if ((IPV6)); then
  CANARY_IP6=$(container_ip6 $P-canary)
  SERVER_IP6=$(container_ip6 $P-server)
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
seen=$(canary_seen --interface eth0)
if [[ -z $seen ]]; then
  pass "a socket bound to eth0 is rejected"
else
  fail "LEAK: a socket bound to eth0 reached the canary (saw $seen)"
fi
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
  seen=$(canary_seen6 --interface eth0)
  if [[ -z $seen ]]; then
    pass "an IPv6 socket bound to eth0 is rejected"
  else
    fail "LEAK: an IPv6 socket bound to eth0 reached the canary (saw $seen)"
  fi
fi
if kx transmission sh -c 'grep "^nameserver" /etc/resolv.conf' | grep -qvx 'nameserver 1\.[01]\.[01]\.1'; then
  fail "pod resolv.conf has nameservers other than the configured ones"
else
  pass "pod DNS uses the configured nameservers only"
fi
dns_ip=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')
# Bound to eth0, so a pass means the kill switch blocked it, not that the
# query went into the tunnel and got lost there.
if tcp_open ordinary_pod curl "telnet://$dns_ip:53"; then
  if tcp_open kx transmission curl --interface eth0 "telnet://$dns_ip:53"; then
    fail "LEAK: cluster DNS ($dns_ip) reachable from the pod via eth0"
  else
    pass "cluster DNS ($dns_ip) unreachable from the pod via eth0 (reachable from an ordinary pod)"
  fi
else
  fail "baseline: cluster DNS not reachable from an ordinary pod (test broken)"
fi
api_ip=$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}')
if kx transmission curl -sS -m 4 -k --interface eth0 "https://$api_ip/version" >/dev/null 2>&1; then
  fail "the Kubernetes API is reachable from the pod via eth0"
else
  pass "the Kubernetes API is unreachable from the pod via eth0"
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
if helm_test; then
  pass "helm test passes on the healthy release"
else
  fail "helm test fails on the healthy release"
  echo "$HELM_TEST_OUT" | tail -20
fi
# An ACCEPT at the top of the kill switch: the test must catch the altered
# rules and the resulting eth0 leak. (-D by spec: if liveness restarts the
# sidecar meanwhile, rule 1 is a real rule again.)
kx wireguard iptables -I TWG-OUTPUT 1 -j ACCEPT
if helm_test; then
  fail "helm test passes with the kill switch opened"
elif grep -q 'FAIL  kill switch' <<<"$HELM_TEST_OUT" && grep -q 'LEAK: a socket bound to eth0' <<<"$HELM_TEST_OUT"; then
  pass "helm test catches an opened kill switch and the eth0 leak"
else
  fail "helm test failed for another reason with the kill switch opened"
  echo "$HELM_TEST_OUT" | tail -20
fi
kx wireguard iptables -D TWG-OUTPUT -j ACCEPT 2>/dev/null || true
wait_for "kill switch intact" 15 kx wireguard /twg/scripts/firewall.sh check || true

step "sidecar restart with the tunnel up"
before=$(sidecar_restarts)
kx wireguard sh -c 'kill 1' || true
leaked=""
for _ in $(seq 10); do
  probes6=()
  ((IPV6)) && probes6=("$(canary_seen6)" "$(canary_seen6 --interface eth0)")
  for seen in "$(canary_seen)" "$(canary_seen --interface eth0)" "${probes6[@]}"; do
    [[ -z $seen || $seen == "$SERVER_IP" || $seen == "${SERVER_IP6:-}" ]] || leaked=$seen
  done
  sleep 1
done
if [[ -z $leaked ]]; then pass "no direct egress during the restart"; else fail "LEAK during restart (canary saw $leaked)"; fi
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
kx wireguard sh -c 'for t in iptables ip6tables; do $t -P OUTPUT ACCEPT; $t -F OUTPUT; done; ip link del wg0'
seen=$(canary_seen)
seen_eth0=$(canary_seen --interface eth0)
seen=${seen:-$seen_eth0}
if ((IPV6)); then
  seen6=$(canary_seen6)
  seen=${seen:-$seen6}
fi
if [[ -z $seen ]]; then
  pass "NetworkPolicy blocks direct egress with the kill switch gone"
else
  fail "LEAK: canary reached with the in-pod kill switch gone (saw $seen)"
fi
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

echo
if ((FAILED)); then
  echo "$FAILED check(s) FAILED"
  exit 1
fi
echo "all kind leak checks passed"
