#!/usr/bin/env bats
# What a failing liveness probe leaves behind (issue #13): the reason, the
# peers' counters and what they point to, in the container's log (kubectl
# logs --previous) and in the termination message (kubectl describe pod),
# never the private key. In the sidecar, like the probe.

load helpers

setup_file() { ensure_healthy; }
teardown() { dump_logs_if_failed; }
teardown_file() {
  # The server knows the pod's key again, and the sidecar handshakes anew.
  docker exec "$P-server" wg set wg0 peer "$CLIENT_PUB" allowed-ips "$TUN_CLIENT/32,$TUN_CLIENT6/128" || true
  docker restart -t 10 "$P-wg" >/dev/null
  ensure_healthy
}

TERM_LOG=/tmp/termination-log

# The probe with a 1 s limit and a termination message file, as kubelet
# provides one; its output is kept for the verdict.
live_1s() {
  docker exec -e TWG_HANDSHAKE_MAX_AGE=1 -e TWG_TERMINATION_LOG=$TERM_LOG "$@" "$P-wg" \
    /twg/scripts/firewall.sh live >"$BATS_TEST_TMPDIR/live" 2>&1
}
live_1s_fails() { ! live_1s; }
# The container's log after its first $1 lines (--since has whole seconds).
log_lines() { docker logs "$P-wg" 2>&1 | wc -l; }
logs_since() { docker logs "$P-wg" 2>&1 | tail -n +"$(($1 + 1))"; }
# The container's log reaches docker logs a moment after it is written.
logged_since() { logs_since "$1" | grep -qE "$2"; }
termination_message() { docker exec "$P-wg" cat $TERM_LOG; }
private_key() { sed -n 's/^PrivateKey *= *//p' "$WG_CONF"; }
tunnel_check() { docker exec "$P-wg" /twg/scripts/firewall.sh tunnel; }
# The pod's peer has sent handshakes but never had one answered.
unanswered() {
  docker exec "$P-wg" wg show wg0 dump | awk -F'\t' 'NR > 1 { exit !($5 == 0 && $7 > 0) }'
}

@test "a failing liveness probe says why in the container's log and termination message" {
  local since
  since=$(log_lines)
  docker exec "$P-wg" sh -c ": >$TERM_LOG"
  wait_until 20 live_1s_fails || fail "liveness did not fail with a 1 s limit: $(cat "$BATS_TEST_TMPDIR/live")"
  wait_until 10 logged_since "$since" 'no handshake within 1s' ||
    fail "the container's log does not say why: $(logs_since "$since" | tail -n 5)"
  wait_until 10 logged_since "$since" "peer .* at $SERVER_IP:51820: last handshake [0-9]+s ago, received [1-9][0-9]* bytes" ||
    fail "the container's log has no peer counters: $(logs_since "$since" | tail -n 5)"
  termination_message | grep -q 'no handshake within 1s' ||
    fail "the termination message does not say why: $(termination_message)"
  termination_message | grep -q 'answered before and stopped' ||
    fail "the termination message does not say what the counters point to: $(termination_message)"
  ! { logs_since "$since"; termination_message; } | grep -qF "$(private_key)" ||
    fail "the private key was logged"
}

@test "a passing liveness probe clears the termination message" {
  docker exec "$P-wg" sh -c "echo stale >$TERM_LOG"
  docker exec -e TWG_TERMINATION_LOG=$TERM_LOG "$P-wg" /twg/scripts/firewall.sh live ||
    fail "liveness fails on a healthy tunnel"
  [[ -z $(termination_message) ]] || fail "an old reason stayed: $(termination_message)"
}

@test "liveness logs the peers' state when it passes too" {
  local since
  since=$(log_lines)
  docker exec -e TWG_STATUS_STATE=/tmp/status-never "$P-wg" /twg/scripts/firewall.sh live ||
    fail "liveness fails on a healthy tunnel"
  wait_until 10 logged_since "$since" "peer .* at $SERVER_IP:51820: last handshake [0-9]+s ago" ||
    fail "no state in the container's log: $(logs_since "$since" | tail -n 5)"
  # Not again before STATUS_EVERY.
  since=$(log_lines)
  docker exec -e TWG_STATUS_STATE=/tmp/status-never "$P-wg" /twg/scripts/firewall.sh live
  # A line after it: once that is in docker logs, so is anything before.
  docker exec "$P-wg" sh -c 'echo twg-test-marker >/proc/1/fd/1'
  wait_until 10 logged_since "$since" twg-test-marker || fail "the container's log is not readable"
  ! logged_since "$since" 'peer .* last handshake' || fail "the state is logged on every probe"
}

@test "a server that ignores the pod's key is named as the cause" {
  # A key the provider rotated or revoked: the server drops its handshakes.
  docker exec "$P-server" wg set wg0 peer "$CLIENT_PUB" remove
  docker restart -t 10 "$P-wg" >/dev/null
  wait_until 60 tunnel_check || fail "the restarted sidecar never passed its own check: $(tunnel_check 2>&1 | tail -n1)"
  wait_until 60 unanswered || fail "the sidecar never sent a handshake: $(docker exec "$P-wg" wg show wg0 2>&1)"
  docker exec "$P-wg" sh -c ": >$TERM_LOG"
  # Without failover peers: docker restart keeps /run, where an earlier
  # failover's state would switch servers at once (a pod's restart does not).
  live_1s -e TWG_FAILOVER_PEERS= && fail "liveness passes without a handshake: $(cat "$BATS_TEST_TMPDIR/live")"
  termination_message | grep -qE "peer .* at $SERVER_IP:51820: no handshake yet, received 0 bytes, sent [1-9][0-9]* bytes" ||
    fail "the termination message has no counters: $(termination_message)"
  termination_message | grep -q 'never answered: the server ignores this key' ||
    fail "the termination message does not point at the key: $(termination_message)"
}
