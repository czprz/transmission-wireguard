#!/usr/bin/env bats
# filter OUTPUT flushed and opened: the mangle POSTROUTING decision must
# still keep everything off eth0, the liveness probe must notice, and a
# sidecar restart must put the kill switch back.

load helpers

setup_file() {
  ensure_healthy
  hits_mark
  as_root sh -c 'iptables -F OUTPUT; iptables -P OUTPUT ACCEPT; ip6tables -F OUTPUT; ip6tables -P OUTPUT ACCEPT'
}
teardown() { dump_logs_if_failed; }
teardown_file() { ensure_healthy; }

@test "with filter OUTPUT flushed, POSTROUTING still blocks eth0" {
  expect_blocked egress4 "${ETH0[@]}"
}

@test "with IPv6 filter OUTPUT flushed, POSTROUTING still blocks eth0" {
  expect_blocked egress6 "${ETH0[@]}"
}

@test "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic with the filter OUTPUT flushed" {
  hits_check "with the filter OUTPUT flushed"
}

@test "liveness probe fails on a flushed firewall" {
  probe_fails as_root /twg/scripts/firewall.sh live || fail "liveness probe did not notice the flushed firewall"
}

@test "restart re-applies the kill switch" {
  docker restart -t 10 "$P-wg" >/dev/null
  wait_until 45 as_root /twg/scripts/firewall.sh check || fail "kill switch not restored by restart"
}
