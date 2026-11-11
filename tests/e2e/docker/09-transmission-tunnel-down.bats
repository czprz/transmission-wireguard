#!/usr/bin/env bats
# Transmission started while the tunnel was down: it binds its peer port
# once, so it never accepts a peer again. Its liveness probe must pass while
# the tunnel is down (a restart could not bind any better) and fail once the
# tunnel is back, so the kubelet restarts it.
#
# The tests build on each other (tunnel down, Transmission restarted, tunnel
# back); each sets up what it needs, once per file, so it also runs alone.

load helpers

setup_file() {
  ensure_healthy
  hits_mark
}
teardown() { dump_logs_if_failed; }
teardown_file() { ensure_healthy; }

tunnel_down() {
  docker stop -t 10 "$P-wg" >/dev/null
  as_root ip link del wg0 2>/dev/null || true
}
# A crash (or an old-style probe) restarts Transmission while the tunnel is
# down: it cannot bind its peer port to the missing address, and never
# tries again. Then the tunnel comes back.
restart_while_down() {
  [[ ! -e $BATS_FILE_TMPDIR/restarted ]] || return 0
  touch "$BATS_FILE_TMPDIR/restarted"
  running "$P-wg" && tunnel_down
  docker restart -t 20 "$P-tx" >/dev/null
  wait_until 120 tx_listening || fail "Transmission did not start again"
  docker start "$P-wg" >/dev/null
  { wait_until 90 as_root /twg/scripts/firewall.sh tunnel && wait_until 60 via_vpn; } ||
    fail "the tunnel did not come back after the sidecar stopped"
}

@test "Transmission's liveness probe passes with the tunnel up" {
  wait_until 60 tx_live || fail "Transmission's liveness probe fails with the tunnel up: $(tx_live 2>&1)"
}

@test "the probe passes while the tunnel address is gone (a restart could not bind any better)" {
  tunnel_down
  tx_live >/dev/null 2>&1 || fail "the probe would restart Transmission while the tunnel is down"
}

@test "the probe fails once the tunnel is back and Transmission has no peer port (the kubelet restarts it)" {
  restart_while_down
  probe_fails tx_live || fail "the probe missed that Transmission never bound its peer port"
}

@test "restarted, Transmission listens for peers on the tunnel address again" {
  restart_while_down
  docker restart -t 20 "$P-tx" >/dev/null
  wait_until 120 tx_live || fail "Transmission did not bind its peer port after a restart: $(tx_live 2>&1)"
}

@test "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic with Transmission starting while the tunnel was down" {
  hits_check "with Transmission starting while the tunnel was down"
}
