#!/usr/bin/env bats
# Rules added next to the kill switch's: its check (the probes) must notice
# them. Each test removes what it added and shows the check passes again.

load helpers

setup_file() { ensure_healthy; }
teardown() {
  dump_logs_if_failed
  # shellcheck disable=SC2016 # expanded in the pod
  as_root sh -c '[ "$(ip6tables -S TWG-OUTPUT | sed -n 2p)" != "-A TWG-OUTPUT -j ACCEPT" ] || ip6tables -D TWG-OUTPUT 1
    nft delete table ip twgtest 2>/dev/null || true'
  as_root /twg/scripts/firewall.sh check || fail "the kill switch does not pass its check after the test removed its rules"
}

@test "probe notices a rule inserted inside the kill switch chain" {
  as_root ip6tables -I TWG-OUTPUT 1 -j ACCEPT
  ! as_root /twg/scripts/firewall.sh check 2>/dev/null || fail "probe did not notice an ACCEPT inserted into TWG-OUTPUT"
}

@test "probe passes again once the rule is removed" {
  as_root ip6tables -I TWG-OUTPUT 1 -j ACCEPT
  as_root ip6tables -D TWG-OUTPUT 1
  as_root /twg/scripts/firewall.sh check || fail "probe still fails after removing the inserted rule"
}

# Duplicated packets skip every later chain, so check must refuse them.
@test "probe notices an nft rule duplicating packets" {
  as_root nft add table ip twgtest 2>/dev/null &&
    as_root nft add chain ip twgtest out '{ type filter hook output priority 0; }' &&
    as_root nft add rule ip twgtest out ip daddr 198.51.100.8 dup to "$GW" device eth0 2>/dev/null ||
    fail "could not add an nft dup rule (kernel without nf_dup?), so the dup check is untested"
  ! as_root /twg/scripts/firewall.sh check 2>/dev/null || fail "probe did not notice an nft rule duplicating packets"
}
