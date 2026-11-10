#!/usr/bin/env bats
# What setup_suite built: the baseline it measured before the kill switch
# existed, the sidecar's start-up, and the settings the init container wrote.

load helpers

setup_file() { ensure_healthy; }
teardown() { dump_logs_if_failed; }

@test "baseline: without the kill switch the pod reaches the canaries directly" {
  # setup_suite fails on a broken baseline; this reports it by name.
  [[ $(cat "$STAGE/baseline-reach") == ok ]] || fail "$(cat "$STAGE/baseline-reach")"
}

@test "baseline: every sensor counts the pod's direct packets, per family (canaries, server, eth0 incl. multicast)" {
  [[ $(cat "$STAGE/baseline-sensors") == ok ]] || fail "$(cat "$STAGE/baseline-sensors")"
}

# Router advertisements may not add routes past the tunnel. A privileged
# sidecar restricts them itself; an unprivileged one cannot and must say so.
@test "router advertisements cannot add on-link prefixes on eth0" {
  [[ $SIDECAR == privileged ]] || skip "the $SIDECAR sidecar cannot restrict them (checked below)"
  local ra
  ra=$(as_root cat /proc/sys/net/ipv6/conf/eth0/accept_ra_pinfo 2>/dev/null || echo unreadable)
  [[ $ra == 0 ]] || fail "router advertisements on eth0 not restricted (accept_ra_pinfo=$ra, $SIDECAR sidecar)"
}

@test "the unprivileged sidecar warns that it cannot restrict router advertisements" {
  [[ $SIDECAR == unprivileged ]] || skip "only the unprivileged sidecar cannot restrict them"
  local wg_log
  # Captured first: grep -q exiting early would SIGPIPE docker logs.
  wg_log=$(docker logs "$P-wg" 2>&1)
  [[ $wg_log == *'WARNING: /proc/sys is read-only'* ]] ||
    fail "router advertisements on eth0 not restricted and not warned about ($SIDECAR sidecar)"
}

# In the sidecar itself, as the kubelet runs them: it sees wg0.conf, so the
# handshake-age check runs too.
@test "startup/readiness/liveness probes pass" {
  docker exec "$P-wg" /twg/scripts/firewall.sh live || fail "probes fail with the tunnel up"
}

@test "peer sockets bound to tunnel addresses" {
  jq -e --arg ip "$TUN_CLIENT" --arg ip6 "$TUN_CLIENT6" '.["bind-address-ipv4"] == $ip and .["bind-address-ipv6"] == $ip6' "$STAGE/settings.json" >/dev/null ||
    fail "bind addresses wrong: $(jq -c '{a4:.["bind-address-ipv4"],a6:.["bind-address-ipv6"]}' "$STAGE/settings.json")"
}

@test "tunnel.env holds the bound addresses and peer port, and no credentials" {
  { [[ $(cat "$STAGE/tunnel.env") == "TWG_BIND4=$TUN_CLIENT"$'\n'"TWG_BIND6=$TUN_CLIENT6"$'\n'"TWG_PEER_PORT=$PEER_PORT" ]] &&
    ! grep -q s3cret "$STAGE/tunnel.env"; } || fail "tunnel.env is wrong: $(tr '\n' ' ' <"$STAGE/tunnel.env")"
}

@test "RPC credentials from the Secret are applied" {
  jq -e '.["rpc-authentication-required"] == true and .["rpc-username"] == "admin" and .["rpc-password"] == "s3cret"' "$STAGE/settings.json" >/dev/null ||
    fail "RPC credentials not applied"
}
