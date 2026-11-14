#!/usr/bin/env bats
# Transmission's liveness probe. Every outage of the tests before (sidecar
# restarts, the deleted tunnel) left Transmission listening on the tunnel
# address, so its probe must never have restarted it. On its own (bats
# --filter) this covers only what setup_suite put the pod through.

# shellcheck source=tests/e2e/cluster/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

teardown() { dump_on_failure; }

@test "Transmission was never restarted, through every sidecar restart and tunnel outage" {
  local tx_restarts
  tx_restarts=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[?(@.name=="transmission")].restartCount}')
  [[ $tx_restarts == 0 ]] ||
    fail "Transmission was restarted ${tx_restarts:-?} times: $(kubectl -n "$NS" get events --field-selector "involvedObject.name=$POD" -o jsonpath='{range .items[?(@.reason=="Unhealthy")]}{.message}{"; "}{end}' | cut -c1-300)"
  pass "Transmission was never restarted, through every sidecar restart and tunnel outage"
}
