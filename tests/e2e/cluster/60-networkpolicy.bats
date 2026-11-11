#!/usr/bin/env bats
# The in-pod firewall flushed and the tunnel deleted: the NetworkPolicy must
# hold. A positive control first shows that the flushed pod does leak while
# there is no policy, so "blocked" afterwards is the policy's doing; then the
# policy goes on (the same pod keeps running) and the probes and sensors must
# see nothing; the liveness probe then restarts the sidecar, which restores
# the kill switch. The scenario runs once, in setup_file; each test judges
# one result of it. The policy stays on for the rest of the run.

# shellcheck disable=SC2119 # helpers whose arguments are optional
# shellcheck source=tests/e2e/cluster/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup_file() {
  set_netpol off
  restore_release
  local before r
  before=$(sidecar_restarts)
  # shellcheck disable=SC2016 # expanded by the pod's shell
  kx wireguard sh -c 'set -e; for t in iptables ip6tables; do $t -P OUTPUT ACCEPT; $t -F OUTPUT; $t -t mangle -F POSTROUTING; done; ip link del wg0' ||
    fail "flushing the in-pod kill switch failed"
  r=$(egress4)
  outcome control positive_control "$r"
  # Only adds the NetworkPolicy; the pod spec is unchanged, so no rollout.
  chart_args
  helm upgrade $RELEASE "$ROOT" -n "$NS" --wait --timeout 5m "${UPGRADE_ARGS[@]}" "${CHART_ARGS[@]}" --set networkPolicy.enabled=true >/dev/null
  outcome enabled policy_created
  outcome same-pod same_pod
  # The CNI programs the policy some time after the API has it: wait until
  # it blocks, so the window below measures the policy, not its rollout.
  wait_until 30 policy_blocks || true
  outcome flushed flushed_check
  hits_mark nopod
  record "$(egress4)" "$(egress4 "${ETH0[@]}")" "$(udp_seen NOFIREWALL)"
  if ((IPV6)); then record "$(egress6)" "$(udp_seen NOFIREWALL6 6)"; fi
  outcome holds result_summary "with the in-pod kill switch gone (NetworkPolicy holds)"
  outcome hits hits_check "with the in-pod kill switch gone (outside sensors)" nopod
  outcome liveness liveness_restart "$before"
  outcome restored restored
}
positive_control() {
  if [[ $1 == leak* ]]; then
    pass "positive control: with the kill switch flushed and no NetworkPolicy the pod leaks (${1#leak })"
  else
    fail "the flushed pod did not leak without the NetworkPolicy ($1), so the policy check proves nothing"
  fi
}
policy_created() {
  if kubectl -n "$NS" get networkpolicy "$RELEASE-transmission-wireguard" >/dev/null 2>&1; then
    pass "NetworkPolicy enabled"
  else
    fail "NetworkPolicy not created"
  fi
}
same_pod() {
  if [[ $(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}' 2>/dev/null) == "$POD_UID" ]]; then
    pass "the upgrade kept the same pod"
  else
    fail "the upgrade replaced the pod, so the probes below would test a fresh kill switch"
  fi
}
policy_blocks() { [[ $(egress4) == blocked ]]; }
# Proves the in-pod kill switch is really gone, so only the NetworkPolicy
# can be what blocks the probes.
flushed() {
  local t
  kx wireguard /twg/scripts/firewall.sh check 2>/dev/null && return 1
  for t in iptables ip6tables; do
    [[ $(kx wireguard $t -S OUTPUT | head -n1) == "-P OUTPUT ACCEPT" &&
      -z $(kx wireguard $t -t mangle -S POSTROUTING | sed 1d) ]] || return 1
  done
}
flushed_check() {
  if flushed; then
    pass "in-pod kill switch flushed (IPv4 and IPv6 filter OUTPUT open, no POSTROUTING decision)"
  else
    fail "the in-pod kill switch is still in place, so the NetworkPolicy check proves nothing"
  fi
}
liveness_restart() {
  # Liveness needs 3 failures 30s apart, plus the restart itself.
  if wait_until 180 restarted_since "$1"; then
    pass "liveness probe restarted the sidecar"
  else
    fail "liveness probe did not restart the sidecar"
  fi
}
restored() {
  if wait_until 60 firewall_ok && wait_until 90 via_vpn; then
    pass "kill switch and tunnel restored"
  else
    fail "kill switch or tunnel not restored"
  fi
}
teardown_file() { restore_release; }
teardown() { dump_on_failure; }

@test "positive control: with the kill switch flushed and no NetworkPolicy the pod leaks" {
  verdict control
}

@test "NetworkPolicy enabled" {
  verdict enabled
}

@test "the upgrade kept the same pod" {
  verdict same-pod
}

@test "in-pod kill switch flushed (IPv4 and IPv6 filter OUTPUT open, no POSTROUTING decision)" {
  verdict flushed
}

@test "no direct egress with the in-pod kill switch gone (NetworkPolicy holds)" {
  verdict holds
}

@test "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic with the in-pod kill switch gone (outside sensors)" {
  verdict hits
}

@test "liveness probe restarted the sidecar" {
  verdict liveness
}

@test "kill switch and tunnel restored" {
  verdict restored
}

@test "helm test passes after recovery, with the NetworkPolicy on" {
  set_netpol on
  restore_release
  if helm_test; then
    pass "helm test passes after recovery, with the NetworkPolicy on"
  else
    echo "$HELM_TEST_OUT" | tail -20
    fail "helm test fails after recovery"
  fi
}
