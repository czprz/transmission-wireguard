#!/usr/bin/env bats
# With the tunnel up: Transmission's own traffic (its tracker announces), and
# who can reach the web UI and the peer port from where. Ends with the
# sensors over everything 02-04 did.

load helpers

setup_file() { ensure_healthy; }
teardown() {
  dump_logs_if_failed
  docker rm -f "$P-l4" >/dev/null 2>&1 || true
}

@test "Transmission announces to its tracker through the VPN, every 10 s" {
  local first sources
  # setup_suite added a torrent whose tracker is the canary. A first
  # announce, then a forced one: re-announcing is shown to work.
  if ! wait_until 90 announced_since 0 || ! first=$(announce_count) || ! reannounced_since "$first" 60; then
    tx_remote -t all -it 2>&1 | head -20 >&2 || true
    fail "Transmission did not announce to the tracker canary twice (test broken; tracker saw: $(announces | tr '\n' ' '))"
  fi
  sources=$(announces | sort -u | tr '\n' ' ')
  announces_via_vpn || fail "LEAK: Transmission's announces came from ${sources}(want only $SERVER_IP / $SERVER_IP6)"
  echo "tracker saw $sources"
}

@test "web UI reachable from the cluster network, reply routed back out eth0" {
  local code
  code=$(from_cluster curl -sS -m 4 -o /dev/null -w '%{http_code}' "http://$POD_IP:$WEB_PORT/transmission/web/" 2>/dev/null || true)
  [[ $code =~ ^(200|301|401|409)$ ]] || fail "web UI not reachable from the cluster network (HTTP '${code}')"
}

@test "web port reachable from the cluster over IPv6 (neighbour discovery and reply routing work)" {
  # Flush the neighbour cache so the reply needs neighbour discovery through
  # the kill switch, not a cached entry.
  as_root ip -6 neigh flush dev eth0 >/dev/null 2>&1 || true
  from_cluster nc -6 -z -w 3 "$POD_IP6" "$WEB_PORT" 2>/dev/null || fail "web port not reachable from the cluster over IPv6"
}

# Transmission binds the peer port to the tunnel address, so probing POD_IP
# would prove nothing. An unprivileged listener on POD_IP stands in for it
# (bindToTunnel off); it answers locally, so a closed port from the cluster
# means the kill switch.
@test "peer port not reachable outside the tunnel (a listener on the pod address answers only locally)" {
  docker run -d --name "$P-l4" --network "container:$P-pod" --cap-drop ALL --user 1000:1000 --entrypoint "" "$WG_IMAGE" \
    nc -lk "$POD_IP" "$PEER_PORT" >/dev/null
  wait_until 15 as_app nc -z -w 2 "$POD_IP" "$PEER_PORT" || fail "the peer port stand-in on $POD_IP does not answer locally (test broken)"
  case $(nc_result from_cluster nc -z -w 3 "$POD_IP" "$PEER_PORT") in
    closed) ;;
    open) fail "peer port reachable outside the tunnel" ;;
    *) fail "the peer port probe from the cluster could not run" ;;
  esac
}

@test "peer port reachable through the tunnel" {
  on_server nc -z -w 3 "$TUN_CLIENT" "$PEER_PORT" || fail "peer port not reachable through the tunnel"
}

# uTP and DHT peers come over UDP. A DHT ping (BEP 5) to the peer port,
# sent from the VPN side as a peer would, must get Transmission's answer.
dht_pong() {
  on_server sh -c "printf 'd1:ad2:id20:abcdefghij0123456789e1:q4:ping1:t2:aa1:y1:qe' | nc -u -w 2 $TUN_CLIENT $PEER_PORT" 2>/dev/null |
    grep -q '1:y1:r'
}
@test "UDP peers reach Transmission through the tunnel (its DHT answers a ping)" {
  wait_until 20 dht_pong || fail "no DHT answer on the peer port through the tunnel"
}

@test "web UI/RPC not reachable from the VPN side" {
  case $(nc_result on_server nc -z -w 3 "$TUN_CLIENT" "$WEB_PORT") in
    closed) ;;
    open) fail "web UI/RPC reachable from the VPN side" ;;
    *) fail "the web UI probe from the VPN side could not run" ;;
  esac
}

# Since setup_suite finished: every check in 02, 03 and this file.
@test "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic while the tunnel is up" {
  hits_check "while the tunnel is up" "$STAGE/hits-tunnel-up"
}
