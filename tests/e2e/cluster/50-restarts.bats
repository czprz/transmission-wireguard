#!/usr/bin/env bats
# The sidecar restarts with the tunnel up (NetworkPolicy off): nothing may
# leak while it is down, and the tunnel comes back. The restart happens once,
# in setup_file; each test judges one result of it.

# shellcheck disable=SC2119 # helpers whose arguments are optional
# shellcheck source=tests/e2e/cluster/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup_file() {
  set_netpol off
  restore_release
  local before
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
    sleep 1 # the probes' pace through the outage, not a wait for it
  done
  outcome probes result_summary "during the restart" need-blocked
  outcome hits hits_check "during the restart"
  outcome recovers recovers "$before"
}
recovers() {
  if wait_until 60 restarted_since "$1" && wait_until 90 via_vpn; then
    pass "tunnel recovers after restart"
  else
    fail "tunnel did not recover after restart"
  fi
}
teardown_file() { restore_release; }
teardown() { dump_on_failure; }

@test "no direct egress during the restart" {
  verdict probes
}

@test "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic during the restart" {
  verdict hits
}

@test "tunnel recovers after restart" {
  verdict recovers
}
