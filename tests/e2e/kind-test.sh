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
# Usage: kind create cluster && tests/e2e/kind-test.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WG_IMAGE="${WG_IMAGE:-ghcr.io/linuxserver/wireguard:1.0.20250521-r1-ls102}"
CANARY_IMAGE="${CANARY_IMAGE:-traefik/whoami:v1.10.3}"
KIND_NET="${KIND_NET:-kind}"
NS="${NS:-twg-e2e}"
RELEASE=twg
P=twg-kind
TUN_SERVER=10.99.0.1
TUN_CLIENT=10.99.0.2

FAILED=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILED=$((FAILED + 1)); }
step() { echo; echo "== $*"; }

cleanup() {
  docker rm -f $P-server $P-canary >/dev/null 2>&1 || true
  kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
}
cleanup
trap '[[ -n ${KEEP:-} ]] || cleanup' EXIT

wg_tool() { docker run --rm -i --entrypoint wg "$WG_IMAGE" "$@"; }
container_ip() { docker inspect -f "{{(index .NetworkSettings.Networks \"$KIND_NET\").IPAddress}}" "$1"; }
kx() { kubectl -n "$NS" exec "$POD" -c "$1" -- "${@:2}"; }
canary_seen() {
  kx transmission curl -sS -m 3 "http://$CANARY_IP/" 2>/dev/null | sed -n 's/^RemoteAddr: \(.*\):[0-9]*\r\{0,1\}$/\1/p' || true
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

step "setup"
SERVER_KEY=$(wg_tool genkey)
CLIENT_KEY=$(wg_tool genkey)
SERVER_PUB=$(echo "$SERVER_KEY" | wg_tool pubkey)
CLIENT_PUB=$(echo "$CLIENT_KEY" | wg_tool pubkey)
NODE_IP=$(container_ip kind-control-plane)

docker run -d --name $P-canary --network "$KIND_NET" "$CANARY_IMAGE" >/dev/null
docker run -d --name $P-server --network "$KIND_NET" --privileged \
  --entrypoint bash "$WG_IMAGE" -c "
    set -e
    echo '$SERVER_KEY' > /tmp/k
    ip link add wg0 type wireguard
    wg set wg0 listen-port 51820 private-key /tmp/k peer '$CLIENT_PUB' allowed-ips $TUN_CLIENT/32
    ip addr add $TUN_SERVER/24 dev wg0
    ip link set wg0 up
    sysctl -qw net.ipv4.ip_forward=1
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    exec sleep infinity" >/dev/null
CANARY_IP=$(container_ip $P-canary)
SERVER_IP=$(container_ip $P-server)
echo "  node $NODE_IP, VPN server $SERVER_IP, canary $CANARY_IP"

kubectl create namespace "$NS" >/dev/null
kubectl -n "$NS" create secret generic wg-client --from-file=wg0.conf=/dev/stdin >/dev/null <<EOF
[Interface]
PrivateKey = $CLIENT_KEY
Address = $TUN_CLIENT/32

[Peer]
PublicKey = $SERVER_PUB
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $SERVER_IP:51820
PersistentKeepalive = 5
EOF
helm install $RELEASE "$ROOT" -n "$NS" --wait --timeout 5m \
  --set wireguard.existingSecret=wg-client \
  --set "wireguard.endpoints[0].ip=$SERVER_IP" \
  --set wireguard.endpoints[0].port=51820 \
  --set wireguard.handshakeMaxAgeSeconds=60 \
  --set persistence.enabled=false
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
if kubectl -n "$NS" logs "$POD" -c wireguard | grep -q 'kill switch installed'; then
  pass "kill switch installed before wg-quick ran"
else
  fail "kill switch log line missing"
fi

step "egress"
seen=$(canary_seen)
if [[ $seen == "$SERVER_IP" ]]; then
  pass "egress exits through the VPN (canary saw $seen, node is $NODE_IP)"
else
  fail "egress did not go through the VPN (canary saw '${seen:-nothing}')"
fi
if kx transmission sh -c 'grep "^nameserver" /etc/resolv.conf' | grep -qvx 'nameserver 1\.[01]\.[01]\.1'; then
  fail "pod resolv.conf has nameservers other than the configured ones"
else
  pass "pod DNS uses the configured nameservers only"
fi
dns_ip=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')
if kubectl -n "$NS" run dns-baseline --rm -i --restart=Never --quiet --image="$WG_IMAGE" --command -- \
  nc -z -w 3 "$dns_ip" 53 >/dev/null 2>&1; then
  if kx transmission nc -z -w 3 "$dns_ip" 53 >/dev/null 2>&1; then
    fail "LEAK: cluster DNS ($dns_ip) reachable from the pod"
  else
    pass "cluster DNS ($dns_ip) unreachable from the pod (reachable from an ordinary pod)"
  fi
else
  fail "baseline: cluster DNS not reachable from an ordinary pod (test broken)"
fi
if kx transmission curl -sS -m 4 -k "https://kubernetes.default.svc/version" >/dev/null 2>&1; then
  fail "the Kubernetes API is reachable from the pod"
else
  pass "the Kubernetes API is unreachable from the pod"
fi

step "web UI"
code=$(kubectl -n "$NS" run curl-probe --rm -i --restart=Never --quiet --image=curlimages/curl:8.11.1 -- \
  curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://$RELEASE-transmission-wireguard:9091/transmission/web/" 2>/dev/null || true)
if [[ $code =~ ^(200|301|401|409)$ ]]; then
  pass "web UI reachable through the Service (HTTP $code)"
else
  fail "web UI not reachable through the Service (HTTP '${code}')"
fi

step "sidecar restart with the tunnel up"
before=$(sidecar_restarts)
kx wireguard sh -c 'kill 1' || true
leaked=""
for _ in $(seq 10); do
  seen=$(canary_seen)
  [[ -n $seen && $seen != "$SERVER_IP" ]] && leaked=$seen
  sleep 1
done
if [[ -z $leaked ]]; then pass "no direct egress during the restart"; else fail "LEAK during restart (canary saw $leaked)"; fi
if wait_for "sidecar restarted" 30 test "$(sidecar_restarts)" -gt "$before" && wait_for "traffic via VPN" 45 via_vpn; then
  pass "tunnel recovers after restart"
else
  fail "tunnel did not recover after restart"
fi

step "in-pod firewall flushed and tunnel deleted (NetworkPolicy must hold)"
before=$(sidecar_restarts)
kx wireguard sh -c 'iptables -P OUTPUT ACCEPT; iptables -F OUTPUT; ip link del wg0'
seen=$(canary_seen)
if [[ -z $seen ]]; then
  pass "NetworkPolicy blocks direct egress with the kill switch gone"
else
  fail "LEAK: canary reached with the in-pod kill switch gone (saw $seen)"
fi
if wait_for "liveness restart" 60 test "$(sidecar_restarts)" -gt "$before"; then
  pass "liveness probe restarted the sidecar"
else
  fail "liveness probe did not restart the sidecar"
fi
if wait_for "kill switch restored" 30 kx wireguard /twg/scripts/firewall.sh check && wait_for "traffic via VPN" 45 via_vpn; then
  pass "kill switch and tunnel restored"
else
  fail "kill switch or tunnel not restored"
fi

echo
if ((FAILED)); then
  echo "$FAILED check(s) FAILED"
  kubectl -n "$NS" describe pod "$POD" | tail -30
  kubectl -n "$NS" logs "$POD" -c wireguard --tail 30 || true
  exit 1
fi
echo "all kind leak checks passed"
