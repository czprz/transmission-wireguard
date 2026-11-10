#!/usr/bin/env bats
# The sidecar SIGKILLed: wg0, its routes and rules are left behind with
# nobody running them. Nothing may leak while it is dead, and a start must
# recover from the stale state.

load helpers

setup_file() {
  ensure_healthy
  docker kill "$P-wg" >/dev/null || fail "could not SIGKILL the sidecar"
  hits_mark
}
teardown() { dump_logs_if_failed; }
teardown_file() { ensure_healthy; }

# Once per file: the image deletes the default route when wg-quick fails;
# recovery must bring both families back, so start with neither.
start_after_kill() {
  [[ ! -e $BATS_FILE_TMPDIR/started ]] || return 0
  touch "$BATS_FILE_TMPDIR/started"
  as_root sh -c 'ip route del default; ip -6 route del default'
  docker start "$P-wg" >/dev/null
}

@test "SIGKILL leaves wg0 and wg-quick's policy rules behind (the state recovery must handle)" {
  { as_root ip link show wg0 >/dev/null 2>&1 && as_root ip -4 rule show | grep -q 'lookup 51820'; } ||
    fail "SIGKILL did not leave the stale tunnel state this file tests"
}

@test "no direct egress while the sidecar is dead" {
  local probes=$BATS_TEST_TMPDIR/probes
  for _ in 1 2 3; do
    record "$probes" "$(egress4)" "$(egress6)" "$(egress4 "${ETH0[@]}")" "$(egress6 "${ETH0[@]}")"
  done
  result_summary "$probes" "while the sidecar is dead"
}

@test "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic while the sidecar is dead" {
  hits_check "while the sidecar is dead"
}

@test "recovers: stale wg0 and policy rules removed, default routes restored" {
  start_after_kill
  { wait_until 90 as_root /twg/scripts/firewall.sh tunnel && wait_until 60 via_vpn; } || fail "did not recover after SIGKILL"
}

@test "no duplicate wg-quick policy rules after the restart" {
  start_after_kill
  poll 90 as_root /twg/scripts/firewall.sh tunnel || true
  [[ $(as_root ip -4 rule show | grep -c 'lookup 51820') == 1 ]] ||
    fail "stale wg-quick policy rules left behind: $(as_root ip -4 rule show | tr '\n' ';')"
}
