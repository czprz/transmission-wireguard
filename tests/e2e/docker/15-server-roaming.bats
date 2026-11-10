#!/usr/bin/env bats
# The VPN server roams to another address: a second server with the same key
# initiates handshakes with the pod, as a roaming server would. The pod must
# not follow it (the kill switch only lets WireGuard reach the configured
# endpoint, so following would fail closed anyway).

load helpers

setup_file() {
  ensure_healthy
  local endpoint
  endpoint=$(docker run --rm --network "container:$P-server" --privileged --entrypoint "" "$WG_IMAGE" wg show wg0 endpoints | awk '{ print $2 }')
  docker rm -f "$P-server2" >/dev/null 2>&1 || true
  docker run -d --name "$P-server2" --network "$NET" --ip "$SERVER2_IP" --privileged --entrypoint bash "$WG_IMAGE" -c "
      set -e
      echo '$SERVER_KEY' > /tmp/k
      ip link add wg0 type wireguard
      wg set wg0 listen-port 51820 private-key /tmp/k peer '$CLIENT_PUB' allowed-ips $TUN_CLIENT/32 endpoint $endpoint persistent-keepalive 1
      ip link set wg0 up
      exec sleep infinity" >/dev/null
  as_root iptables -w -t raw -I PREROUTING -s "$SERVER2_IP" -p udp --sport 51820 -m comment --comment twg-roam
  hits_mark
}
teardown() { dump_logs_if_failed; }
teardown_file() {
  docker rm -f "$P-server2" >/dev/null 2>&1 || true
  as_root iptables -w -t raw -D PREROUTING -s "$SERVER2_IP" -p udp --sport 51820 -m comment --comment twg-roam || true
  ensure_healthy
}

roamed() { pod_hits twg-roam "$P-pod"; }
roam_seen() { local n; n=$(roamed); [[ $n != unreadable ]] && ((n > 0)); }

@test "the pod ignores a server that roams to another address" {
  local n pod_endpoint
  wait_until 30 roam_seen || fail "the roaming server's packets never reached the pod, so this proves nothing"
  # A window, not a wait: WireGuard retries a handshake after 5 s, and the
  # pod must not follow that one either.
  sleep 6
  n=$(roamed)
  pod_endpoint=$(as_root wg show wg0 endpoints | awk '{ print $2 }')
  { [[ $pod_endpoint == "$SERVER_IP:51820" ]] && via_vpn; } || fail "the pod followed the roaming server (endpoint $pod_endpoint)"
  echo "$n packets dropped; endpoint still $pod_endpoint"
}

@test "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic while the server roams" {
  hits_check "while the server roams"
}
