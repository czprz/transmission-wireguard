#!/usr/bin/env bats
# The web UI's replies to the cluster. Like a pod on most CNIs, the pod has
# no route for its own subnet: the cluster is behind its default route,
# which wg-quick's rules skip for everything unmarked. Only the marks the
# kill switch puts on the web UI's connections keep their packets on eth0,
# for the reverse-path check on the way in and the route on the way out.

load helpers

# Packets from the pod's own address into wg0 (a sensor outside the kill
# switch's chains, so it does not change what the firewall checks); with
# 6 as $1, for IPv6.
into_tunnel() { counter "ip${1:-}" out; }
# Connection requests to the web UI that arrived on eth0, before any rule.
web_ui_syns() { counter "ip${1:-}" in; }
# Counter of chain $2 in nft table family $1. The docker client can lose a
# container's output, so an empty read is tried again.
counter() {
  local n _
  for _ in 1 2 3; do
    n=$(as_root nft list chain "$1" twgreply "$2" 2>/dev/null | sed -nE 's/.*counter packets ([0-9]+).*/\1/p')
    [[ -z $n ]] || break
  done
  echo "$n"
}
# The IPv6 listener on the web port does not speak HTTP: a completed
# connection is the answer.
web_ui6() { from_cluster nc -6 -z -w 3 "$POD_IP6" "$WEB_PORT" >/dev/null 2>&1; }
# curl always prints a code (000: no answer); nothing at all means the
# client never ran (its address still held by the last test's client, or
# the docker client lost the output), so it runs again.
web_ui() {
  local code _
  for _ in 1 2 3; do
    code=$(from_cluster curl -sS -m 4 -o /dev/null -w '%{http_code}' "http://$POD_IP:$WEB_PORT/transmission/web/" 2>/dev/null || true)
    [[ -z $code ]] || break
    sleep 1
  done
  echo "$code"
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
    nft add rule ip twgreply in iifname eth0 ip daddr $POD_IP tcp dport $WEB_PORT 'tcp flags & (syn | ack) == syn' counter &&
    nft add table ip6 twgreply && nft add chain ip6 twgreply out '{ type filter hook postrouting priority 400; }' &&
    nft add rule ip6 twgreply out oifname wg0 ip6 saddr $POD_IP6 counter &&
    nft add chain ip6 twgreply in '{ type filter hook prerouting priority -400; }' &&
    nft add rule ip6 twgreply in iifname eth0 ip6 daddr $POD_IP6 tcp dport $WEB_PORT 'tcp flags & (syn | ack) == syn' counter"
  local rp _
  for _ in 1 2 3; do
    rp=$(as_root sh -c 'echo "$(sysctl -n net.ipv4.conf.all.rp_filter) $(sysctl -n net.ipv4.conf.eth0.rp_filter)"')
    [[ $rp =~ ^[0-2]\ [0-2]$ ]] && break
  done
  [[ $rp =~ ^[0-2]\ [0-2]$ ]] || fail "could not read rp_filter"
  echo "$rp" >"$BATS_FILE_TMPDIR/rp_filter"
}
teardown() {
  local all eth0
  read -r all eth0 <"$BATS_FILE_TMPDIR/rp_filter"
  as_root sysctl -qw "net.ipv4.conf.all.rp_filter=$all" "net.ipv4.conf.eth0.rp_filter=$eth0" || true
  dump_logs_if_failed
}
teardown_file() {
  as_root nft delete table ip twgreply 2>/dev/null || true
  as_root nft delete table ip6 twgreply 2>/dev/null || true
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

@test "the IPv6 tunnel sensor counts packets from the pod address into wg0 (positive control)" {
  local before after
  before=$(into_tunnel 6)
  as_app curl -sS -6 -m 3 --interface "$POD_IP6" -o /dev/null "http://[2001:db8::7]/" 2>/dev/null || true
  after=$(into_tunnel 6)
  [[ -n $before && -n $after ]] || fail "could not read the IPv6 tunnel sensor"
  ((after > before)) || fail "the IPv6 tunnel sensor counted nothing (test broken)"
}

@test "the IPv6 web port is reachable from the cluster, its replies not in the tunnel" {
  local before after
  before=$(into_tunnel 6)
  web_ui6 || fail "no IPv6 connection from the cluster to the web port"
  after=$(into_tunnel 6)
  ((after == before)) || fail "LEAK: $((after - before)) IPv6 web reply packet(s) went into the tunnel"
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

@test "with the IPv6 web replies' marks missing, they are rejected, not sent into the tunnel" {
  local before after syns_before syns_after rc=0
  before=$(into_tunnel 6)
  syns_before=$(web_ui_syns 6)
  as_root ip6tables -t mangle -F TWG-MANGLE-OUTPUT
  web_ui6 || rc=$?
  after=$(into_tunnel 6)
  syns_after=$(web_ui_syns 6)
  [[ -n $before && -n $after && -n $syns_before && -n $syns_after ]] || fail "could not read the IPv6 sensors"
  ((syns_after > syns_before)) || fail "the IPv6 connection request never reached the pod, so this proves nothing"
  ((after == before)) || fail "LEAK: $((after - before)) IPv6 web reply packet(s) went into the tunnel"
  ((rc != 0)) || fail "the IPv6 connection completed without the reply marks, so the window was not reproduced"
}
