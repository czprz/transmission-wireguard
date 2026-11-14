#!/usr/bin/env bats
# Egress with the in-pod kill switch alone (NetworkPolicy off): the
# harness's own baselines first (an ordinary pod does reach the canaries,
# every sensor counts, the pod leaks once the kill switch is bypassed), then
# TCP and UDP from the release pod go through the VPN and nowhere else.

# shellcheck disable=SC2119 # helpers whose arguments are optional
# shellcheck source=tests/e2e/cluster/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup_file() { set_netpol off; }
teardown() {
  dump_on_failure
  restore_release
}

@test "baseline: an ordinary pod reaches the canary directly" {
  local baseline
  baseline=$(ordinary_pod curl -sS -m 5 "http://$CANARY_IP/cgi-bin/ip" | remote_addr || true)
  [[ -n $baseline && $baseline != "$SERVER_IP" ]] ||
    fail "baseline: an ordinary pod cannot reach the canary directly (harness broken)"
  pass "baseline: an ordinary pod reaches the canary directly (as $baseline)"
}

@test "baseline: an ordinary pod reaches the canary directly over IPv6" {
  need_ipv6
  local baseline6
  baseline6=$(ordinary_pod curl -6 -sS -m 5 "http://[$CANARY_IP6]/cgi-bin/ip" | remote_addr || true)
  [[ -n $baseline6 && $baseline6 != "$SERVER_IP6" ]] ||
    fail "baseline: an ordinary pod cannot reach the canary over IPv6 (harness broken)"
  pass "baseline: an ordinary pod reaches the canary directly over IPv6 (as $baseline6)"
}

@test "baseline: every sensor counts direct packets per family, and the pod leaks via eth0 once the kill switch is bypassed" {
  local before_counts after_counts dead f ip port server bypass restore r r6=""
  before_counts=$(sensor_counts)
  # Each sensor and family must count: UDP from outside the cluster, plaintext
  # to the server, and a flow the release pod sends out eth0 with the kill
  # switch bypassed for a moment (an ACCEPT and a RETURN at the top of its
  # chains; teardown takes them out again if this test does not).
  for f in 4 6; do
    ((f == 4 || IPV6)) || continue
    ip=$UDP_IP port=6881 server=$SERVER_IP
    ((f == 4)) || ip=$UDP_IP6 port=6882 server=$SERVER_IP6
    docker run --rm --network "$CLUSTER_NET" --entrypoint "" "$WG_IMAGE" sh -c \
      "echo BASELINE | nc -$f -u -w1 $ip $port; nc -$f -z -w2 $server 80" >/dev/null 2>&1 || true
  done
  # shellcheck disable=SC2016 # expanded by the pod's shell
  bypass='$1 -I TWG-OUTPUT 1 -j ACCEPT && $1 -t mangle -I TWG-POSTROUTING 1 -j RETURN'
  # shellcheck disable=SC2016
  restore='$1 -D TWG-OUTPUT -j ACCEPT; $1 -t mangle -D TWG-POSTROUTING -j RETURN'
  kx wireguard sh -c "$bypass" sh iptables >/dev/null
  r=$(egress4 "${ETH0[@]}")
  kx wireguard sh -c "$restore" sh iptables >/dev/null
  if ((IPV6)); then
    kx wireguard sh -c "$bypass" sh ip6tables >/dev/null
    r6=$(egress6 "${ETH0[@]}")
    kx wireguard sh -c "$restore" sh ip6tables >/dev/null
  fi
  after_counts=$(sensor_counts)
  dead=$(join -j1 <(awk '{ print $1 "/" $2, $3 }' <<<"$before_counts" | sort) <(awk '{ print $1 "/" $2, $3 }' <<<"$after_counts" | sort) |
    awk -v v6="$IPV6" '$3 <= $2 && (v6 == 1 || $1 !~ /\/6$/) { printf " %s", $1 }')
  if [[ $before_counts == *unreadable* || $after_counts == *unreadable* ]]; then
    fail "baseline: the packet counters cannot be read (harness broken)"
  elif [[ -n $dead ]]; then
    fail "baseline: these sensors did not count direct packets:$dead (harness broken)"
  elif [[ $r != leak* ]] || { ((IPV6)) && [[ $r6 != leak* ]]; }; then
    fail "baseline: with the kill switch bypassed the pod did not leak via eth0 ($r $r6), so the eth0 checks prove nothing"
  fi
  pass "baseline: every sensor counts direct packets per family, and the pod leaks via eth0 once the kill switch is bypassed"
}

@test "egress exits through the VPN" {
  local seen
  seen=$(canary_seen)
  [[ $seen == "$SERVER_IP" ]] || fail "egress did not go through the VPN (canary saw '${seen:-nothing}')"
  pass "egress exits through the VPN (canary saw $seen, node is $NODE_IP)"
}

@test "a socket bound to eth0 cannot reach the canary" {
  check_eth0 "the canary" "http://$CANARY_IP/cgi-bin/ip"
}

@test "IPv6 egress exits through the VPN" {
  need_ipv6
  local seen
  seen=$(canary_seen6)
  [[ $seen == "$SERVER_IP6" ]] || fail "IPv6 egress did not go through the VPN (canary saw '${seen:-nothing}')"
  pass "IPv6 egress exits through the VPN (canary saw $seen)"
}

@test "a socket bound to eth0 cannot reach the canary over IPv6" {
  need_ipv6
  check_eth0 "the canary over IPv6" -6 "http://[$CANARY_IP6]/cgi-bin/ip"
}

@test "UDP leaves through the VPN" {
  local seen
  seen=$(udp_seen TUNNELED)
  [[ $seen == "$SERVER_IP" ]] || fail "UDP did not go through the VPN (canary saw '${seen:-nothing}')"
  pass "UDP leaves through the VPN (canary saw $seen)"
}

@test "IPv6 UDP leaves through the VPN" {
  need_ipv6
  local seen
  seen=$(udp_seen TUNNELED6 6)
  [[ $seen == "$SERVER_IP6" ]] || fail "IPv6 UDP did not go through the VPN (canary saw '${seen:-nothing}')"
  pass "IPv6 UDP leaves through the VPN (canary saw $seen)"
}

@test "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic from the release pod" {
  hits_mark
  # The release pod's traffic of the checks above, in one window: TCP and
  # UDP through the tunnel, and TCP bound to eth0.
  via_vpn || fail "the pod's traffic does not go through the VPN, so this proves nothing"
  check_eth0 "the canary" "http://$CANARY_IP/cgi-bin/ip"
  udp_seen TUNNELED$RANDOM >/dev/null
  if ((IPV6)); then
    [[ $(canary_seen6) == "$SERVER_IP6" ]] || fail "the pod's IPv6 traffic does not go through the VPN, so this proves nothing"
    check_eth0 "the canary over IPv6" -6 "http://[$CANARY_IP6]/cgi-bin/ip"
    udp_seen TUNNELED6$RANDOM 6 >/dev/null
  fi
  hits_check "from the release pod"
}
