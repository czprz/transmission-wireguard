#!/usr/bin/env bats
# The release as it starts: the upgrade from an earlier release (with
# UPGRADE_FROM), native sidecar start ordering, kubelet probes through the
# kill switch, and the kill switch in place before the tunnel comes up.

# shellcheck source=tests/e2e/cluster/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"
teardown() { dump_on_failure; }

@test "helm upgrade from the earlier release succeeds" {
  [[ -n $UPGRADE_FROM ]] || skip "not an upgrade run (UPGRADE_FROM is unset)"
  # setup_suite ran the upgrade (and fails every test if it failed); this
  # checks its result: this chart, deployed over the earlier release.
  local want history first last
  want=$(helm show chart "$ROOT" | sed -n 's/^version: //p')
  history=$(helm history $RELEASE -n "$NS")
  first=$(sed -n 2p <<<"$history" | grep -o 'transmission-wireguard-[0-9][^[:space:]]*' || true)
  last=$(tail -n1 <<<"$history")
  # shellcheck disable=SC2153 # UPGRADED_FROM: the earlier version, from setup_suite
  [[ $first == "transmission-wireguard-$UPGRADED_FROM" && $last =~ deployed[[:space:]]+"transmission-wireguard-$want"[[:space:]] ]] ||
    fail "the release is not this chart ($want) deployed over $UPGRADED_FROM: $history"
  pass "helm upgrade from $UPGRADED_FROM succeeds${UPGRADE_FLAGS:+ (with $UPGRADE_FLAGS)}"
}

@test "the upgrade keeps the release's PVC, and the downloads on it" {
  [[ -n $UPGRADE_FROM ]] || skip "not an upgrade run (UPGRADE_FROM is unset)"
  [[ $(kubectl -n "$NS" get pvc "$RELEASE-transmission-wireguard" -o jsonpath='{.metadata.uid}') == "$OLD_PVC_UID" ]] ||
    fail "the upgrade replaced the release's PVC"
  [[ $(kx transmission cat /data/.twg-upgrade-marker 2>/dev/null) == "$UPGRADE_MARKER" ]] ||
    fail "the earlier release's file on its PVC is not at /data after the upgrade"
  pass "the upgrade keeps the release's PVC, and the downloads on it"
}

@test "pod is Ready (kubelet probes work through the kill switch)" {
  kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=10s >/dev/null || fail "pod not Ready"
  pass "pod is Ready (kubelet probes work through the kill switch)"
}

@test "Transmission started after the WireGuard sidecar" {
  local wg_started tx_started
  wg_started=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.initContainerStatuses[?(@.name=="wireguard")].state.running.startedAt}')
  tx_started=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[?(@.name=="transmission")].state.running.startedAt}')
  [[ -n $wg_started && -n $tx_started && ! $tx_started < $wg_started ]] ||
    fail "start order wrong (wireguard=$wg_started transmission=$tx_started)"
  pass "Transmission started after the WireGuard sidecar ($wg_started <= $tx_started)"
}

@test "the downloads PVC (upgraded: the release's PVC) is mounted at /data" {
  kx transmission grep -q ' /data ' /proc/mounts || fail "nothing is mounted at /data"
  if [[ -z $UPGRADE_FROM ]]; then
    pass "the downloads PVC is mounted at /data ($(kubectl -n "$NS" get pvc "$RELEASE-transmission-wireguard-downloads" -o jsonpath='{.status.phase}'))"
  else
    pass "the release's PVC is mounted at /data"
  fi
}

@test "kill switch installed before wg-quick ran" {
  local wg_log fw_line up_line
  wg_log=$(kubectl -n "$NS" logs "$POD" -c wireguard)
  fw_line=$(grep -n -m1 'kill switch installed' <<<"$wg_log" | cut -d: -f1 || true)
  up_line=$(grep -n -m1 'ip link add dev wg0' <<<"$wg_log" | cut -d: -f1 || true)
  [[ -n $fw_line && -n $up_line ]] && ((fw_line < up_line)) ||
    fail "kill switch not logged before wg-quick (installed=${fw_line:-missing}, wg0 up=${up_line:-missing})"
  pass "kill switch installed before wg-quick ran (log lines $fw_line < $up_line)"
}
