#!/usr/bin/env bats
# With the tunnel up: traffic leaves through the VPN, and nothing that names
# eth0 (a bound socket, a link-local address, a more specific route) does.
# 04-transmission.bats checks the sensors over this file and 03.

load helpers

setup_file() { ensure_healthy; }
teardown() {
  dump_logs_if_failed
  [[ $BATS_TEST_DESCRIPTION != *"more specific route"* ]] || del_specific_routes
}

# Routes more specific than the tunnel's /0 (CNI host routes, a gateway
# route, an RA's on-link prefix), so the main table sends the canary out eth0.
add_specific_routes() {
  as_root sh -c "ip route add $CANARY_IP/32 via $GW dev eth0 && ip -6 route add $CANARY_IP6/128 via $GW6 dev eth0"
}
del_specific_routes() {
  as_root sh -c "ip route del $CANARY_IP/32 via $GW dev eth0; ip -6 route del $CANARY_IP6/128 via $GW6 dev eth0" 2>/dev/null || true
  [[ -z $(as_root sh -c "ip route show $CANARY_IP/32; ip -6 route show $CANARY_IP6/128") ]] ||
    fail "the test routes to the canary could not be removed"
}

@test "egress exits through the VPN" {
  local seen
  seen=$(canary_seen)
  [[ $seen == "$SERVER_IP" ]] || fail "egress did not go through the VPN (canary saw '${seen:-nothing}', want $SERVER_IP)"
}

@test "IPv6 egress exits through the VPN" {
  local seen
  seen=$(canary_seen6)
  [[ $seen == "$SERVER_IP6" ]] || fail "IPv6 egress did not go through the VPN (canary saw '${seen:-nothing}', want $SERVER_IP6)"
}

@test "a socket bound to eth0 cannot reach the canary" {
  check_eth0 "http://$CANARY_IP/"
}

@test "a socket bound to eth0 cannot reach the canary over IPv6" {
  check_eth0 -6 "http://[$CANARY_IP6]/"
}

@test "ICMP leaves through the VPN (IPv4 and IPv6)" {
  [[ $(icmp "$CANARY_IP") == reached && $(icmp -6 "$CANARY_IP6") == reached ]] || fail "ICMP does not get through the VPN"
}

@test "ICMP bound to eth0 is blocked" {
  expect_icmp_blocked -I eth0 "$CANARY_IP"
}

@test "IPv6 ICMP bound to eth0 is blocked" {
  expect_icmp_blocked -6 -I eth0 "$CANARY_IP6"
}

# Unbound traffic the main table routes out eth0 itself.
@test "no egress to a link-local address on eth0" {
  expect_blocked egress -g "http://[$CANARY_LL%25eth0]/"
}

@test "no egress over a more specific route via eth0" {
  add_specific_routes
  expect_blocked egress4
}

@test "no IPv6 egress over a more specific route via eth0" {
  add_specific_routes
  expect_blocked egress6
}
