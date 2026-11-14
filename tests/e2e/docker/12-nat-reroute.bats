#!/usr/bin/env bats
# A nat rule re-routes a packet out eth0 after filter OUTPUT accepted it as
# going to wg0. Only the POSTROUTING decision can stop it. Each family has a
# positive control (the same request with the decision bypassed gets out),
# so the check after it is the decision's doing.
#
# A re-routed request leaves from the tunnel address it was routed for, so
# curl gets no answer either way: only the sensors can tell a leak.

load helpers

nat_url() { if [[ $1 == 4 ]]; then echo http://198.51.100.7/; else echo 'http://[2001:db8::7]/'; fi; }
ipt_for() { if [[ $1 == 4 ]]; then echo iptables; else echo ip6tables; fi; }
# Removes the bypass a positive control adds, if it is still there.
del_bypass() {
  local ipt
  ipt=$(ipt_for "$1")
  as_root sh -c "[ \"\$($ipt -t mangle -S TWG-POSTROUTING | sed -n 2p)\" != '-A TWG-POSTROUTING -j RETURN' ] || $ipt -t mangle -D TWG-POSTROUTING 1"
}
# Without the POSTROUTING decision the request must get out eth0.
positive_control() {
  local f=$1 ipt leaked was
  ipt=$(ipt_for "$f")
  hits_mark "$BATS_TEST_TMPDIR/hits"
  as_root "$ipt" -t mangle -I TWG-POSTROUTING 1 -j RETURN
  egress -g "$(nat_url "$f")" >/dev/null
  del_bypass "$f"
  was=$(cat "$BATS_TEST_TMPDIR/hits")
  leaked=$(pod_hits)
  { [[ $was != unreadable && $leaked != unreadable ]] && ((leaked > was)); } ||
    fail "the IPv$f nat re-route did not get out even without the POSTROUTING decision, so the check after it proves nothing"
}
no_nat_leak() {
  hits_mark "$BATS_TEST_TMPDIR/hits"
  expect_blocked egress -g "$(nat_url "$1")"
  hits_check "with an IPv$1 nat rule re-routing out eth0" "$BATS_TEST_TMPDIR/hits"
}

setup_file() {
  ensure_healthy
  as_root sh -c "ip route add $CANARY_IP/32 via $GW dev eth0 &&
    iptables -t nat -A OUTPUT -p tcp -d 198.51.100.7 --dport 80 -j DNAT --to-destination $CANARY_IP &&
    ip -6 route add $CANARY_IP6/128 via $GW6 dev eth0 &&
    ip6tables -t nat -A OUTPUT -p tcp -d 2001:db8::7 --dport 80 -j DNAT --to-destination $CANARY_IP6"
}
teardown() {
  dump_logs_if_failed
  del_bypass 4
  del_bypass 6
}
teardown_file() {
  as_root sh -c "iptables -t nat -D OUTPUT -p tcp -d 198.51.100.7 --dport 80 -j DNAT --to-destination $CANARY_IP;
    ip route del $CANARY_IP/32 via $GW dev eth0
    ip6tables -t nat -D OUTPUT -p tcp -d 2001:db8::7 --dport 80 -j DNAT --to-destination $CANARY_IP6;
    ip -6 route del $CANARY_IP6/128 via $GW6 dev eth0" || true
  ensure_healthy
}

@test "positive control: without the POSTROUTING decision the IPv4 nat re-route gets out eth0" {
  positive_control 4
}

@test "an IPv4 nat rule re-routing out eth0 does not leak" {
  no_nat_leak 4
}

@test "positive control: without the POSTROUTING decision the IPv6 nat re-route gets out eth0" {
  positive_control 6
}

@test "an IPv6 nat rule re-routing out eth0 does not leak" {
  no_nat_leak 6
}
