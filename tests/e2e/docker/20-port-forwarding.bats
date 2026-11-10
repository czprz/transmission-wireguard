#!/usr/bin/env bats
# VPN port forwarding over NAT-PMP. The VPN server answers NAT-PMP inside the
# tunnel, like Proton VPN's gateway, and forwards FORWARDED_PORT from its
# public address to the pod's tunnel address. The sidecar's liveness probe
# must get the port, open only it on wg0 and make it Transmission's peer
# port; a peer on the internet then reaches Transmission through it.

load helpers

# NAT-PMP (RFC 6886), the two requests natpmpc sends: the public address
# (op 0) and a mapping (op 1 UDP, op 2 TCP), always answered with
# FORWARDED_PORT. natpmpc refuses private, shared and documentation
# addresses as the public one, so the answer names 1.1.1.1: only a value in
# the reply, never contacted.
responder() {
  cat <<PY
import socket, struct, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("$TUN_SERVER", 5351))
start = time.time()
while True:
    d, a = s.recvfrom(64)
    if len(d) < 2 or d[0] != 0:
        continue
    epoch = int(time.time() - start)
    if d[1] == 0:
        r = struct.pack("!BBHI4s", 0, 128, 0, epoch, socket.inet_aton("1.1.1.1"))
    elif d[1] in (1, 2) and len(d) >= 12:
        _, op, _, private, _, life = struct.unpack("!BBHHHI", d[:12])
        r = struct.pack("!BBHIHHI", 0, 128 + op, 0, epoch, private, $FORWARDED_PORT, life)
    else:
        continue
    s.sendto(r, a)
PY
}

probe() { docker exec "$P-wg" /twg/scripts/firewall.sh live; }
forwarded_rules() { as_root iptables -w -S TWG-FORWARDED | sed 1d; }
forwarded() {
  probe >/dev/null 2>&1 || true
  [[ $(forwarded_rules) == *"--dport $FORWARDED_PORT -j ACCEPT"* ]]
}
# Transmission listening for peers on the tunnel address and the port.
tx_on_port() {
  local want
  want=$(echo "$TUN_CLIENT $1" | awk '{ split($1, o, "."); printf "%02X%02X%02X%02X:%04X", o[4], o[3], o[2], o[1], $2 }')
  as_root awk -v w="$want" '$2 == w && $4 == "0A" { found = 1 } END { exit !found }' /proc/net/tcp
}

setup_file() {
  ((NATPMP)) || skip "the sidecar image has no natpmpc (set SIDECAR_IMAGE to the chart's own image)"
  ensure_healthy
  docker rm -f "$P-natpmp" >/dev/null 2>&1 || true
  docker run -d --name "$P-natpmp" --network "container:$P-server" --entrypoint python3 "$NATPMP_IMAGE" -c "$(responder)" >/dev/null
  # The forward itself, as the VPN server does it.
  docker run --rm --network "container:$P-server" --cap-add NET_ADMIN --entrypoint "" "$WG_IMAGE" sh -c "
    set -e
    for p in tcp udp; do
      iptables -w -t nat -A PREROUTING -i eth0 -p \$p --dport $FORWARDED_PORT -j DNAT --to-destination $TUN_CLIENT
      iptables -w -A FORWARD -i eth0 -o wg0 -p \$p -d $TUN_CLIENT --dport $FORWARDED_PORT -j ACCEPT
    done"
  hits_mark
}
teardown() { dump_logs_if_failed; }
teardown_file() {
  docker rm -f "$P-natpmp" >/dev/null 2>&1 || true
  ((NATPMP)) || return 0
  docker run --rm --network "container:$P-server" --cap-add NET_ADMIN --entrypoint "" "$WG_IMAGE" sh -c "
    for p in tcp udp; do
      iptables -w -t nat -D PREROUTING -i eth0 -p \$p --dport $FORWARDED_PORT -j DNAT --to-destination $TUN_CLIENT
      iptables -w -D FORWARD -i eth0 -o wg0 -p \$p -d $TUN_CLIENT --dport $FORWARDED_PORT -j ACCEPT
    done" || true
  # Back to the configured peer port, for whatever runs next.
  as_root iptables -w -F TWG-FORWARDED || true
  docker exec "$P-wg" rm -f /twg/forward/port || true
  tx_remote -p "$PEER_PORT" >/dev/null 2>&1 || true
  ensure_healthy
}

@test "the liveness probe gets the forwarded port and opens only it, only on wg0" {
  wait_until 60 forwarded || fail "no forwarded port after a minute of probes: $(forwarded_rules | tr '\n' ';')"
  [[ $(forwarded_rules) == "-A TWG-FORWARDED -i wg0 -p tcp -m tcp --dport $FORWARDED_PORT -j ACCEPT"$'\n'"-A TWG-FORWARDED -i wg0 -p udp -m udp --dport $FORWARDED_PORT -j ACCEPT" ]] ||
    fail "TWG-FORWARDED holds: $(forwarded_rules | tr '\n' ';')"
}

@test "Transmission listens for peers on the forwarded port" {
  wait_until 30 tx_on_port "$FORWARDED_PORT" || fail "Transmission is not listening on $TUN_CLIENT:$FORWARDED_PORT"
}

@test "a peer on the internet reaches Transmission through the forwarded port" {
  docker run --rm --network "$NET" --entrypoint nc "$WG_IMAGE" -z -w 3 "$SERVER_IP" "$FORWARDED_PORT" ||
    fail "no connection to $SERVER_IP:$FORWARDED_PORT, the VPN server's forwarded port"
}

@test "the forwarded port stays closed outside the tunnel" {
  ! from_cluster nc -z -w 3 "$POD_IP" "$FORWARDED_PORT" || fail "the forwarded port is open on eth0"
}

@test "Transmission's liveness probe passes on the forwarded port" {
  docker exec "$P-tx" /bin/sh /twg/scripts/transmission-live.sh || fail "Transmission's probe fails although it listens on the forwarded port"
}

@test "the kill switch passes its check with the port forwarded, and fails it with anything more in TWG-FORWARDED" {
  as_root /twg/scripts/firewall.sh check || fail "the check fails with only the forwarded port open"
  as_root iptables -w -A TWG-FORWARDED -i wg0 -p tcp --dport "$WEB_PORT" -j ACCEPT
  local rc=0
  as_root /twg/scripts/firewall.sh check 2>/dev/null || rc=$?
  as_root iptables -w -D TWG-FORWARDED -i wg0 -p tcp --dport "$WEB_PORT" -j ACCEPT
  ((rc == 1)) || fail "the check did not notice the web port opened on wg0 (exit $rc)"
}

@test "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic with the port forwarded" {
  hits_check "with the port forwarded"
}
