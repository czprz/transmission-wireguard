#!/usr/bin/env bats
# wg0 deleted under a running sidecar: nothing may leave, by any protocol,
# and the probes must notice. teardown_file restarts the sidecar.

load helpers

setup_file() {
  ensure_healthy
  hits_mark
  as_root ip link del wg0
}
teardown() { dump_logs_if_failed; }
teardown_file() { ensure_healthy; }

@test "no TCP egress without wg0" {
  expect_blocked egress4
}

@test "no IPv6 egress without wg0" {
  expect_blocked egress6
}

@test "no DNS/UDP egress without wg0" {
  expect_no_udp NOTUNNEL
}

@test "no IPv6 DNS/UDP egress without wg0" {
  expect_no_udp NOTUNNEL6 6
}

@test "no UDP egress to another port without wg0" {
  expect_no_udp NOTUNNELDHT 4 6881
}

@test "no ICMP egress without wg0" {
  expect_icmp_blocked "$CANARY_IP"
}

@test "no IPv6 ICMP egress without wg0" {
  expect_icmp_blocked -6 "$CANARY_IP6"
}

@test "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic without wg0" {
  hits_check "without wg0"
}

@test "readiness/liveness probe fails while the tunnel is down" {
  ! as_root /twg/scripts/firewall.sh tunnel 2>/dev/null || fail "probe did not notice the missing tunnel"
}
