#!/usr/bin/env bats
# The tunnel up but its policy routing removed: unmarked traffic would route
# out eth0. wg0 and its address stay, so Transmission's tracker sockets still
# bind and try; only the kill switch can stop them leaving by eth0.
#
# setup_file removes the rule for the whole file, the last test puts it back
# (and shows Transmission announces again), teardown_file makes sure.

load helpers

policy_rule_del() { as_root sh -c 'ip -4 rule del not fwmark 51820 table 51820 && ip -6 rule del not fwmark 51820 table 51820'; }
policy_rule_restore() {
  as_root sh -c 'ip -4 rule show | grep -q "not from all fwmark 0xca6c lookup 51820" || ip -4 rule add not fwmark 51820 table 51820 pref 32765
    ip -6 rule show | grep -q "not from all fwmark 0xca6c lookup 51820" || ip -6 rule add not fwmark 51820 table 51820 pref 32765'
}
# Announces the tracker had when the window opened: any later one leaked.
before() { cat "$BATS_FILE_TMPDIR/announces"; }

setup_file() {
  ensure_healthy
  # A fresh announce through the VPN right before: Transmission sends its
  # "stopped" announces at shutdown only while the last announce succeeded.
  reannounced_since "$(announce_count)" 60 || fail "Transmission did not announce through the VPN before the window"
  hits_mark
  policy_rule_del
  announce_count >"$BATS_FILE_TMPDIR/announces"
}
teardown() {
  dump_logs_if_failed
  # The Transmission tests stop and restart it.
  running "$P-tx" || docker start "$P-tx" >/dev/null
  wait_until 120 tx_listening || fail "Transmission did not start again"
}
teardown_file() {
  policy_rule_restore
  ensure_healthy
}

# Transmission shutting down while routing is broken: its "stopped"
# announces must not get out. First thing in the window, before any
# announce fails. Transmission does not always send them, so a shutdown
# without an attempt is skipped, not failed; the sensors still apply.
@test "Transmission's shutdown announces do not get out with the policy rule gone" {
  local tries tries_now
  tries=$(tracker_attempts)
  docker stop -t 20 "$P-tx" >/dev/null
  tries_now=$(tracker_attempts)
  if [[ $tries == unreadable || $tries_now == unreadable ]] || ((tries_now <= tries)); then
    skip "Transmission made no announce attempt while shutting down this time"
  fi
  (($(announce_count) == $(before))) || fail "LEAK: Transmission's shutdown announce reached the tracker with the policy rule gone"
  echo "$((tries_now - tries)) attempts blocked"
}

@test "no TCP egress with the policy rule gone" {
  expect_blocked egress4
}

@test "no IPv6 egress with the policy rule gone" {
  expect_blocked egress6
}

@test "no ICMP egress with the policy rule gone" {
  expect_icmp_blocked "$CANARY_IP"
}

@test "no IPv6 ICMP egress with the policy rule gone" {
  expect_icmp_blocked -6 "$CANARY_IP6"
}

@test "no UDP egress with the policy rule gone" {
  expect_no_udp NORULE
}

@test "no IPv6 UDP egress with the policy rule gone" {
  expect_no_udp NORULE6 6
}

# Force announces inside the window and count Transmission's attempts, so
# "nothing arrived" cannot just mean it did not try.
@test "Transmission's announces do not get out with the policy rule gone" {
  local tries tries_now after
  tries=$(tracker_attempts)
  reannounce
  sleep 20 # a window, not a wait: two of Transmission's re-announce intervals
  after=$(announce_count)
  tries_now=$(tracker_attempts)
  if [[ $tries == unreadable || $tries_now == unreadable ]] || ((tries_now <= tries)); then
    fail "Transmission made no announce attempt with the policy rule gone, so this window proves nothing"
  fi
  ((after == $(before))) ||
    fail "LEAK: Transmission announced with the policy rule gone (tracker saw $(announces | tail -n +$(($(before) + 1)) | sort -u | tr '\n' ' '))"
  echo "$((tries_now - tries)) attempts blocked"
}

# And starting while routing is broken: its first announces, DHT bootstrap
# and port mapping all happen now. (With wg0 deleted it cannot even bind its
# announce sockets to the tunnel address, so this window shows more.)
@test "Transmission starting with the policy rule gone gets nothing out" {
  local tries tries_now
  tries=$(tracker_attempts)
  docker restart -t 20 "$P-tx" >/dev/null
  wait_until 120 tx_listening || fail "Transmission did not come back after a restart with the policy rule gone"
  tx_remote -t all --start >/dev/null 2>&1 || true
  sleep 15 # a window, not a wait: whatever it sends at start must not get out
  tries_now=$(tracker_attempts)
  if [[ $tries == unreadable || $tries_now == unreadable ]] || ((tries_now <= tries)); then
    fail "Transmission made no announce attempt after starting with the policy rule gone, so this proves nothing"
  fi
  (($(announce_count) == $(before))) || fail "LEAK: Transmission announced after starting with the policy rule gone"
  echo "$((tries_now - tries)) announce attempts blocked"
}

@test "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic with the policy rule gone" {
  hits_check "with the policy rule gone"
}

@test "Transmission announces through the VPN again once routing is back" {
  policy_rule_restore
  reannounced_since "$(announce_count)" 60 ||
    fail "Transmission did not announce again after routing came back, so the checks above prove nothing"
}
