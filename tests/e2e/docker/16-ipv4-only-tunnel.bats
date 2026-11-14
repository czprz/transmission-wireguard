#!/usr/bin/env bats
# An IPv4-only tunnel in a dual-stack pod, the most common provider config:
# IPv6 has no tunnel and must be blocked, and Transmission binds IPv6 to
# loopback. setup_file switches the sidecar to it, teardown_file back.

load helpers

V4_CONF=$BATS_FILE_TMPDIR/v4only.conf

setup_file() {
  ensure_healthy
  sed -e "s|^Address = .*|Address = $TUN_CLIENT/32|" -e "s|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/0|" "$WG_CONF" >"$V4_CONF"
  docker cp "$V4_CONF" "$P-wg:/config/wg_confs/wg0.conf" >/dev/null
  docker restart -t 10 "$P-wg" >/dev/null
  # The first test reports a tunnel that does not come up.
  { poll 90 as_root /twg/scripts/firewall.sh tunnel && poll 60 via_vpn4; } || true
  hits_mark
}
teardown() { dump_logs_if_failed; }
# ensure_healthy puts the dual-stack wg0.conf back.
teardown_file() { ensure_healthy; }

@test "IPv4-only tunnel: peer sockets bound to the tunnel IPv4 address and ::1" {
  run_settings_init "$V4_CONF" "$BATS_TEST_TMPDIR/v4" >/dev/null
  jq -e --arg ip "$TUN_CLIENT" '.["bind-address-ipv4"] == $ip and .["bind-address-ipv6"] == "::1"' "$BATS_TEST_TMPDIR/v4/settings.json" >/dev/null ||
    fail "IPv4-only tunnel: bind addresses wrong: $(jq -c '{a4:.["bind-address-ipv4"],a6:.["bind-address-ipv6"]}' "$BATS_TEST_TMPDIR/v4/settings.json")"
}

@test "IPv4-only tunnel: IPv4 leaves through the VPN" {
  { wait_until 90 as_root /twg/scripts/firewall.sh tunnel && wait_until 60 via_vpn4; } || fail "IPv4-only tunnel did not come up"
}

@test "no direct egress over IPv6 without an IPv6 tunnel" {
  local probes=$BATS_TEST_TMPDIR/probes
  for _ in 1 2; do record "$probes" "$(egress6)" "$(egress6 "${ETH0[@]}")"; done
  result_summary "$probes" "over IPv6 without an IPv6 tunnel" need-blocked
}

@test "no IPv6 UDP without an IPv6 tunnel" {
  expect_no_udp V4ONLY6 6
}

@test "no IPv6 ICMP without an IPv6 tunnel" {
  expect_icmp_blocked -6 "$CANARY_IP6"
}

@test "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic with an IPv4-only tunnel" {
  hits_check "with an IPv4-only tunnel"
}
