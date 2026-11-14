#!/usr/bin/env bats
# The chart's own `helm test`, on the healthy release and on a pod whose
# kill switch was opened. (After the NetworkPolicy scenario it runs once
# more, in 60-networkpolicy.bats.)

# shellcheck source=tests/e2e/cluster/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup_file() { set_netpol off; }
teardown() {
  dump_on_failure
  restore_release
}

@test "helm test passes on the healthy release (capabilities checked)" {
  if helm_test && grep -q 'PASS  the Transmission container holds no network capabilities' <<<"$HELM_TEST_OUT"; then
    pass "helm test passes on the healthy release (capabilities checked)"
  else
    echo "$HELM_TEST_OUT" | tail -20
    fail "helm test fails on the healthy release"
  fi
}

@test "helm test catches an opened kill switch and the eth0 leak" {
  # An ACCEPT at the top of both kill switch chains: the test must catch the
  # altered rules and the resulting eth0 leak. teardown takes them out.
  # shellcheck disable=SC2016 # expanded by the pod's shell
  kx wireguard sh -c 'for t in iptables ip6tables; do $t -I TWG-OUTPUT 1 -j ACCEPT && $t -t mangle -I TWG-POSTROUTING 1 -j RETURN || exit 1; done'
  if helm_test; then
    fail "helm test passes with the kill switch opened"
  elif grep -q 'FAIL  kill switch' <<<"$HELM_TEST_OUT" && grep -q 'LEAK: a socket bound to eth0' <<<"$HELM_TEST_OUT"; then
    pass "helm test catches an opened kill switch and the eth0 leak"
  else
    echo "$HELM_TEST_OUT" | tail -20
    fail "helm test failed for another reason with the kill switch opened"
  fi
}
