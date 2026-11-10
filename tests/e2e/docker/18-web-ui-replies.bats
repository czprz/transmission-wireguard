#!/usr/bin/env bats
# The web UI's replies to the cluster. Like a pod on most CNIs, the pod has
# no route for its own subnet: the cluster is behind its default route,
# which wg-quick's rules skip for everything unmarked. Only the marks the
# kill switch puts on the web UI's connections keep their packets on eth0,
# for the reverse-path check on the way in and the route on the way out.

load helpers

# Packets from the pod's own address into wg0 (a sensor outside the kill
# switch's chains, so it does not change what the firewall checks).
into_tunnel() {
  as_root nft list chain ip twgreply out 2>/dev/null | sed -nE 's/.*counter packets ([0-9]+).*/\1/p'
}
# Connection requests to the web UI that arrived on eth0, before any rule.
web_ui_syns() {
  as_root nft list chain ip twgreply in 2>/dev/null | sed -nE 's/.*counter packets ([0-9]+).*/\1/p'
}
web_ui() {
  from_cluster curl -sS -m 4 -o /dev/null -w '%{http_code}' "http://$POD_IP:$WEB_PORT/transmission/web/" 2>/dev/null || true
}
# The same through the gateway, as a Kubernetes client arrives (from the
# node, not as a neighbour on the pod's link). A neighbour's ARP request
# carries no mark, so strict reverse-path filtering would drop it whatever
# the kill switch does.
web_ui_via_gateway() {
  docker run --rm --network "$NET" --ip "$CLIENT_IP" --cap-add NET_ADMIN --entrypoint "" "$WG_IMAGE" sh -c \
    "ip route replace $POD_IP via $GW dev eth0 && curl -sS -m 4 -o /dev/null -w '%{http_code}' http://$POD_IP:$WEB_PORT/transmission/web/" \
    2>/dev/null || true
}

setup_file() {
  ensure_healthy
  as_root sh -c "nft add table ip twgreply && nft add chain ip twgreply out '{ type filter hook postrouting priority 400; }' &&
    nft add rule ip twgreply out oifname wg0 ip saddr $POD_IP counter &&
    nft add chain ip twgreply in '{ type filter hook prerouting priority -400; }' &&
    nft add rule ip twgreply in iifname eth0 ip daddr $POD_IP tcp dport $WEB_PORT 'tcp flags & (syn | ack) == syn' counter"
  as_root sh -c 'echo "$(sysctl -n net.ipv4.conf.all.rp_filter) $(sysctl -n net.ipv4.conf.eth0.rp_filter)"' >"$BATS_FILE_TMPDIR/rp_filter"
}
teardown() {
  local all eth0
  read -r all eth0 <"$BATS_FILE_TMPDIR/rp_filter"
  as_root sysctl -qw "net.ipv4.conf.all.rp_filter=$all" "net.ipv4.conf.eth0.rp_filter=$eth0" || true
  dump_logs_if_failed
}
teardown_file() {
  as_root nft delete table ip twgreply 2>/dev/null || true
  ensure_healthy
}

@test "the tunnel sensor counts packets from the pod address into wg0 (positive control)" {
  local before after
  before=$(into_tunnel)
  # Sent from the pod's own address, as a reply that went the wrong way
  # would be; any address takes the tunnel.
  as_app curl -sS -m 3 --interface "$POD_IP" -o /dev/null http://198.51.100.7/ 2>/dev/null || true
  after=$(into_tunnel)
  [[ -n $before && -n $after ]] || fail "could not read the tunnel sensor"
  ((after > before)) || fail "the tunnel sensor counted nothing (test broken)"
}

@test "web UI reachable from the cluster with strict reverse-path filtering" {
  # The incoming packets carry the mark too, so the reverse-path check
  # finds the cluster in the main table (eth0), not in the tunnel's.
  as_root sysctl -qw net.ipv4.conf.all.rp_filter=1 net.ipv4.conf.eth0.rp_filter=1
  local code
  code=$(web_ui_via_gateway)
  [[ $code =~ ^(200|301|401|409)$ ]] || fail "web UI not reachable from the cluster with rp_filter=1 (HTTP '$code')"
}

@test "with the web UI's reply marks missing, its replies are rejected, not sent into the tunnel" {
  # A flushed mangle OUTPUT chain is the moment while the kill switch
  # re-applies its mangle rules: replies are unmarked and would follow
  # wg-quick's rules into the tunnel.
  # (ensure_healthy restores the chain: the kill switch's check sees it.)
  local before after syns_before syns_after code
  before=$(into_tunnel)
  syns_before=$(web_ui_syns)
  as_root iptables -t mangle -F TWG-MANGLE-OUTPUT
  code=$(web_ui)
  after=$(into_tunnel)
  syns_after=$(web_ui_syns)
  [[ -n $before && -n $after && -n $syns_before && -n $syns_after ]] || fail "could not read the sensors"
  ((syns_after > syns_before)) || fail "the web UI's request never reached the pod (client: '$code'), so this proves nothing"
  ((after == before)) || fail "LEAK: $((after - before)) web UI reply packet(s) went into the tunnel"
  [[ $code == 000 ]] || fail "the web UI answered without its reply marks (HTTP '$code'), so the window was not reproduced"
}
