#!/usr/bin/env bats
# The VPN server stops answering: the liveness probe (run in the sidecar, as
# the kubelet does) switches to the failover server, another server of the
# account with its own key. Traffic keeps going through the tunnel, and
# nothing but WireGuard to the endpoints leaves eth0 meanwhile.

load helpers

escapes() { pod_hits twg-count "$P-pod"; }
endpoint() { as_root wg show wg0 endpoints | awk '{ print $2 }'; }
probe() { docker exec "$P-wg" /twg/scripts/firewall.sh live; }
# One probe, then: is the failover server the peer now?
switched() { probe >/dev/null 2>&1 || true; [[ $(endpoint) == "$FAILOVER_IP:51820" ]]; }
via_failover() { [[ $(canary_seen) == "$FAILOVER_IP" && $(canary_seen6) == "$FAILOVER_IP6" ]]; }

setup_file() {
  ensure_healthy
  # WireGuard to the failover server may leave eth0 now: not an escape.
  as_root iptables -w -t mangle -I TWGTEST-ESCAPE -p udp -d "$FAILOVER_IP" --dport 51820 -j RETURN
  escapes >"$BATS_FILE_TMPDIR/escapes"
  # A fresh tunnel (wg-quick handshakes as it comes up), watched from now.
  docker restart -t 10 "$P-wg" >/dev/null
  wait_until 90 via_vpn
  probe >/dev/null 2>&1 || true
}
teardown() { dump_logs_if_failed; }
teardown_file() {
  docker unpause "$P-server" >/dev/null 2>&1 || true
  as_root iptables -w -t mangle -D TWGTEST-ESCAPE -p udp -d "$FAILOVER_IP" --dport 51820 -j RETURN || true
  # The sidecar is still on the failover server: ensure_healthy restarts it,
  # which brings back wg0.conf's peer.
  ensure_healthy
}

@test "while the server answers, the liveness probe stays with it" {
  local _
  for _ in 1 2 3 4 5; do
    probe >/dev/null 2>&1 || true
    [[ $(endpoint) == "$SERVER_IP:51820" ]] || fail "switched to $(endpoint) although the server answers"
    sleep 3
  done
}

@test "with the server not answering, the liveness probe switches to the failover peer" {
  docker pause "$P-server" >/dev/null
  wait_until 120 switched || fail "still on $(endpoint) after 2 minutes without an answer from it"
}

@test "traffic goes through the tunnel to the failover server" {
  wait_until 30 via_failover || fail "the canary saw $(canary_seen) and $(canary_seen6), not the failover server"
}

@test "the liveness probe passes with the failover peer" {
  probe || fail "the probe fails on the failover peer, so the kubelet would restart the sidecar"
}

@test "nothing but WireGuard to the endpoints left eth0 while failing over" {
  local was now
  was=$(cat "$BATS_FILE_TMPDIR/escapes")
  now=$(escapes)
  [[ $was != unreadable && $now != unreadable ]] || fail "could not read the pod's eth0 sensor"
  ((now == was)) || fail "LEAK: $((now - was)) flow(s) left eth0 outside the tunnel while failing over"
}
