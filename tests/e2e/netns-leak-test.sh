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
TUN_SERVER=10.99.0.1
TUN_CLIENT=10.99.0.2
WEB_PORT=9091
PEER_PORT=51413

FAILED=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILED=$((FAILED + 1)); }
step() { echo; echo "== $*"; }

cleanup() {
  docker rm -f -v $P-tx $P-wg $P-pod $P-server $P-canary $P-dns $P-pre >/dev/null 2>&1 || true
  docker network rm $NET >/dev/null 2>&1 || true
}
cleanup
STAGE=$(mktemp -d)
trap '[[ -n ${KEEP:-} ]] || cleanup; rm -rf "$STAGE"' EXIT

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
from_cluster() { docker run --rm --network $NET --ip $CLIENT_IP --entrypoint "" "$WG_IMAGE" "$@"; }
wg_tool() { docker run --rm -i --entrypoint wg "$WG_IMAGE" "$@"; }

# Source address the canary saw for a request from the pod (empty if blocked).
canary_seen() {
  as_app curl -sS -m 3 "http://$CANARY_IP/" 2>/dev/null | sed -n 's/^RemoteAddr: \(.*\):[0-9]*\r\{0,1\}$/\1/p' || true
}
# Send a DNS-port datagram tagged $1 and print the source the canary saw.
dns_seen() {
  as_app sh -c "echo $1 | nc -u -w1 $DNS_CANARY_IP 53" >/dev/null 2>&1 || true
  sleep 2
  docker logs $P-dns 2>&1 | grep -C1 -x "$1" | sed -n 's/^Connection received on \([^ ]*\) .*/\1/p' | tail -n1 || true
}
via_vpn() { [[ $(canary_seen) == "$SERVER_IP" ]]; }

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
SERVER_KEY=$(wg_tool genkey)
CLIENT_KEY=$(wg_tool genkey)
SERVER_PUB=$(echo "$SERVER_KEY" | wg_tool pubkey)
CLIENT_PUB=$(echo "$CLIENT_KEY" | wg_tool pubkey)

docker network create --subnet $SUBNET_PREFIX.0/24 --gateway $GW $NET >/dev/null
docker run -d --name $P-canary --network $NET --ip $CANARY_IP "$CANARY_IMAGE" >/dev/null
# UDP/53 canary standing in for any DNS server outside the pod (cluster DNS,
# NodeLocal DNSCache, the ISP); logs the source of every datagram.
docker run -d --name $P-dns --network $NET --ip $DNS_CANARY_IP --entrypoint "" "$WG_IMAGE" \
  sh -c 'while true; do nc -luvn -w 1 53; done' >/dev/null

# VPN server: terminates the tunnel and NATs to the "internet" (the canary).
docker run -d --name $P-server --network $NET --ip $SERVER_IP --privileged \
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

# Pod sandbox, routed like a CNI: only a host route to the gateway.
docker run -d --name $P-pod --network $NET --ip $POD_IP --privileged \
  --entrypoint bash "$WG_IMAGE" -c "
    ip route del $SUBNET_PREFIX.0/24 dev eth0
    ip route add $GW/32 dev eth0 scope link
    ip route replace default via $GW dev eth0
    exec sleep infinity" >/dev/null
sleep 2

mkdir -p "$STAGE/wg/config/wg_confs"
stage_scripts "$STAGE/wg"
cat >"$STAGE/wg/config/wg_confs/wg0.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_KEY
Address = $TUN_CLIENT/32

[Peer]
PublicKey = $SERVER_PUB
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $SERVER_IP:51820
PersistentKeepalive = 5
EOF
chmod 0600 "$STAGE/wg/config/wg_confs/wg0.conf"

# Baseline: before any firewall, the pod reaches the canary directly. If this
# fails the harness is broken and later "blocked" results would mean nothing.
if [[ $(canary_seen) == "$POD_IP" && $(dns_seen BASELINE) == "$POD_IP" ]]; then
  pass "baseline: without the kill switch the pod reaches the canaries directly (as $POD_IP)"
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
wait_for "first handshake" 30 via_vpn || true

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

step "settings.json"
if jq -e --arg ip $TUN_CLIENT '.["bind-address-ipv4"] == $ip and .["bind-address-ipv6"] == "::1"' "$STAGE/settings.json" >/dev/null; then
  pass "peer sockets bound to tunnel address $TUN_CLIENT (IPv6 pinned to ::1, tunnel has no IPv6)"
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
if as_app curl -sS -m 3 --interface eth0 "http://$CANARY_IP/" >/dev/null 2>&1; then
  fail "LEAK: a socket bound to eth0 reached the canary directly"
else
  pass "a socket bound to eth0 is rejected"
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
if as_root ip6tables -S OUTPUT | grep -x -- '-A OUTPUT -j TWG-OUTPUT' >/dev/null; then
  pass "IPv6 kill switch installed"
else
  fail "IPv6 kill switch missing"
fi

step "sidecar restart with the tunnel up (s6 runs wg-quick down; kill switch must stay)"
docker restart -t 10 $P-wg >/dev/null &
restart_pid=$!
leaked=""
for _ in $(seq 10); do
  seen=$(canary_seen)
  [[ -n $seen && $seen != "$SERVER_IP" ]] && leaked=$seen
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
seen=$(dns_seen NOTUNNEL)
if [[ -z $seen ]]; then pass "no DNS/UDP egress without wg0"; else fail "LEAK: DNS canary reached without wg0 (saw $seen)"; fi
if as_root /twg/scripts/firewall.sh tunnel 2>/dev/null; then
  fail "probe did not notice the missing tunnel"
else
  pass "readiness/liveness probe fails while the tunnel is down"
fi

step "sidecar SIGKILL (wg0 left behind) plus default route deleted"
docker kill $P-wg >/dev/null
as_root ip route del default
seen=$(canary_seen)
if [[ -z $seen || $seen == "$SERVER_IP" ]]; then pass "no direct egress while the sidecar is dead"; else fail "LEAK while sidecar dead ($seen)"; fi
docker start $P-wg >/dev/null
if wait_for "wg0 back" 60 as_root wg show wg0 && wait_for "traffic via VPN" 30 via_vpn; then
  pass "recovers: stale wg0 removed and default route restored"
else
  fail "did not recover after SIGKILL"
fi

step "firewall tampering"
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
expect_refused() {
  local desc=$1 out
  rm -rf "$STAGE/pre"
  mkdir -p "$STAGE/pre/config/wg_confs"
  stage_scripts "$STAGE/pre"
  sed "$2" "$STAGE/wg/config/wg_confs/wg0.conf" >"$STAGE/pre/config/wg_confs/wg0.conf"
  docker create --name $P-pre --privileged --network none "${firewall_env[@]}" --entrypoint /bin/bash "$WG_IMAGE" \
    -c '/twg/scripts/firewall.sh apply; rc=$?; /twg/scripts/firewall.sh check && echo RULES_OK; exit $rc' >/dev/null
  docker cp "$STAGE/pre/." $P-pre:/ >/dev/null
  out=$(docker start -a $P-pre 2>&1 || true)
  docker rm -f $P-pre >/dev/null
  if grep -q FATAL <<<"$out" && grep -q RULES_OK <<<"$out"; then
    pass "refused: $desc"
  else
    fail "not refused: $desc"
    echo "${out//$'\n'/$'\n        '}"
  fi
}
expect_refused "PreDown that flushes the firewall" '/^\[Interface\]/a PreDown = iptables -P OUTPUT ACCEPT; iptables -F OUTPUT'
expect_refused "hostname endpoint" "s/^Endpoint = .*/Endpoint = vpn.example.com:51820/"
expect_refused "split tunnel" "s|^AllowedIPs = .*|AllowedIPs = 10.0.0.0/8|"
expect_refused "Table = off" '/^\[Interface\]/a Table = off'

echo
if ((FAILED)); then
  echo "$FAILED check(s) FAILED"
  docker logs --tail 40 $P-wg 2>&1 | sed 's/^/  wg | /'
  exit 1
fi
echo "all leak checks passed"
