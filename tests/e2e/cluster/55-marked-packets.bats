#!/usr/bin/env bats
# Packets marked by a stray mangle rule (NetworkPolicy off): marked packets
# are re-routed out eth0 after filter OUTPUT; the POSTROUTING decision must
# still drop them. The rule is in place once, in setup_file; each test
# judges one result of that window.

# shellcheck disable=SC2119 # helpers whose arguments are optional
# shellcheck source=tests/e2e/cluster/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup_file() {
  set_netpol off
  restore_release
  hits_mark
  kx wireguard sh -c 'iptables -t mangle -A OUTPUT -j MARK --set-mark 51820 && ip6tables -t mangle -A OUTPUT -j MARK --set-mark 51820'
  for _ in 1 2; do
    record "$(egress4)" "$(egress4 "${ETH0[@]}")" "$(udp_seen MARKED$RANDOM)"
    if ((IPV6)); then record "$(egress6)" "$(egress6 "${ETH0[@]}")" "$(udp_seen MARKED6$RANDOM 6)"; fi
  done
  kx wireguard sh -c 'iptables -t mangle -D OUTPUT -j MARK --set-mark 51820; ip6tables -t mangle -D OUTPUT -j MARK --set-mark 51820' || true
  outcome probes result_summary "with every packet marked"
  outcome hits hits_check "with every packet marked"
}
# Takes the mark rules out if setup_file did not get to it.
teardown_file() { restore_release; }
teardown() { dump_on_failure; }

@test "no direct egress with every packet marked" {
  verdict probes
}

@test "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic with every packet marked" {
  verdict hits
}
