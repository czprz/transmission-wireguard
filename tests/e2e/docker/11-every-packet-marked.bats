#!/usr/bin/env bats
# A rule after the kill switch's jump that gives every packet WireGuard's
# mark: marked packets must still only reach the VPN endpoint, as WireGuard.
# setup_file adds the rules for the whole file, teardown_file removes them.

load helpers

mark_all() { as_root sh -c "iptables -t mangle $1 OUTPUT -j MARK --set-mark 51820; ip6tables -t mangle $1 OUTPUT -j MARK --set-mark 51820"; }

setup_file() {
  ensure_healthy
  hits_mark
  mark_all -A
}
teardown() { dump_logs_if_failed; }
teardown_file() {
  # -D until none is left, in case a test added one more.
  local _
  for _ in 1 2 3; do mark_all -D 2>/dev/null || true; done
  as_root /twg/scripts/firewall.sh check || fail "the kill switch does not pass its check with the marking rules removed"
  ensure_healthy
}

@test "marking every packet does not open eth0" {
  expect_blocked egress4
}

@test "marking every IPv6 packet does not open eth0" {
  expect_blocked egress6
}

# Marked, so routed out eth0 to the endpoint's own address, but not
# WireGuard: TCP and other UDP to the server must not pass.
@test "marked TCP to the VPN server's address does not pass" {
  expect_blocked egress "http://$SERVER_IP/"
}

@test "marked IPv6 TCP to the VPN server's address does not pass" {
  expect_blocked egress -6 "http://[$SERVER_IP6]/"
}

@test "probe notices a rule appended to mangle OUTPUT" {
  ! as_root /twg/scripts/firewall.sh check 2>/dev/null || fail "probe did not notice a rule appended to mangle OUTPUT"
}

# Other marked UDP to the server has no answer to look at: only the server's
# plaintext sensor can tell, so it is sent right before the sensors are read.
@test "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic with every packet marked" {
  as_app sh -c "for i in 1 2 3; do echo x | nc -u -w1 $SERVER_IP 5353; echo x | nc -6 -u -w1 $SERVER_IP6 5353; done" >/dev/null 2>&1 || true
  hits_check "with every packet marked"
}
