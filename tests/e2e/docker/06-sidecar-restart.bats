#!/usr/bin/env bats
# A sidecar restart with the tunnel up: s6 runs wg-quick down, and the kill
# switch must stay while the tunnel is gone. setup_file restarts it while
# probing; the tests judge what the probes and sensors saw.

load helpers

setup_file() {
  ensure_healthy
  hits_mark
  local pid probes=$BATS_FILE_TMPDIR/probes
  docker restart -t 10 "$P-wg" >/dev/null &
  pid=$!
  # Probe until the restart is over and at least one probe hit the outage.
  for _ in $(seq 40); do
    record "$probes" "$(egress4)" "$(egress6)"
    if ! kill -0 $pid 2>/dev/null && grep -qx blocked "$probes"; then break; fi
  done
  wait $pid
}
teardown() { dump_logs_if_failed; }
teardown_file() { ensure_healthy; }

@test "no direct egress during the restart" {
  result_summary "$BATS_FILE_TMPDIR/probes" "during the restart" need-blocked
}

@test "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic during the restart" {
  hits_check "during the restart"
}

@test "tunnel recovers after restart" {
  { wait_until 90 as_root wg show wg0 && wait_until 60 via_vpn; } || fail "tunnel did not recover after restart"
}
