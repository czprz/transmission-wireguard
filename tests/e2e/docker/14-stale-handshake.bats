#!/usr/bin/env bats
# The liveness branch for handshakeMaxAgeSeconds. In the sidecar, like the
# probe: it reads PersistentKeepalive from wg0.conf, which as_root cannot see.

load helpers

setup_file() { ensure_healthy; }
teardown() { dump_logs_if_failed; }

# The probe with a 1 s limit; its output is kept for the verdict.
live_1s() {
  docker exec -e TWG_HANDSHAKE_MAX_AGE=1 "$P-wg" /twg/scripts/firewall.sh live >"$BATS_TEST_TMPDIR/live" 2>&1
}
live_1s_fails() { ! live_1s; }

@test "liveness fails when the newest handshake is older than the limit" {
  # Until the last handshake is over a second old (keepalives do not
  # handshake, so that is soon); then it must fail for that reason.
  local rc=0
  wait_until 20 live_1s_fails || rc=$?
  { ((rc == 0)) && grep -q 'no handshake within 1s' "$BATS_TEST_TMPDIR/live"; } ||
    fail "liveness did not notice a stale handshake: $(cat "$BATS_TEST_TMPDIR/live")"
}

# Without PersistentKeepalive an idle tunnel stops handshaking, so the age
# is not checked (the restarts would never end).
@test "the handshake age is not checked without PersistentKeepalive" {
  docker exec "$P-wg" sh -c 'sed /PersistentKeepalive/d /config/wg_confs/wg0.conf >/tmp/nk.conf &&
      TWG_WG_CONF=/tmp/nk.conf TWG_HANDSHAKE_MAX_AGE=1 /twg/scripts/firewall.sh live' 2>/dev/null ||
    fail "liveness checks the handshake age of a tunnel without PersistentKeepalive"
}
