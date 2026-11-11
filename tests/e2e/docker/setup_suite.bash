# shellcheck shell=bash
# The shared environment for the Docker leak test, built once per run.
#
# Builds a "pod" (containers sharing one network namespace, routed like a CNI
# does: a default route via a gateway, no on-link subnet route) with the chart's
# real images and scripts, a WireGuard server that NATs to an HTTP canary, and
# then the tests try to make traffic escape outside the tunnel.
#
# Needs Docker with kernel WireGuard support. No bind mounts are used (they
# are unreliable with docker-outside-of-docker); files go in with docker cp,
# and every probe is a fresh container joined to the pod's network namespace.
#
# The network is dual-stack, so every leak check also runs over IPv6.
# The baseline (positive controls for every path and sensor) runs here,
# before the kill switch exists: if it fails, the harness is broken and no
# "blocked" below would mean anything, so the whole run fails.

# shellcheck source=tests/e2e/docker/helpers.bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.bash"

# A WireGuard server ($1, at $2 and $3, private key $4) for the pod's key,
# NATing tunnel traffic to the "internet" (the canary).
vpn_server() {
  docker run -d --name "$1" --network "$NET" --ip "$2" --ip6 "$3" --privileged \
    --entrypoint bash "$WG_IMAGE" -c "
      set -e
      echo '$4' > /tmp/k
      ip link add wg0 type wireguard
      wg set wg0 listen-port 51820 private-key /tmp/k peer '$CLIENT_PUB' allowed-ips $TUN_CLIENT/32,$TUN_CLIENT6/128
      ip addr add $TUN_SERVER/24 dev wg0
      ip addr add $TUN_SERVER6/64 dev wg0
      ip link set wg0 up
      sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1
      # Only tunnel traffic is forwarded and NATed, like a real VPN server: a
      # plaintext packet routed via the server must not come out as its own.
      for ipt in iptables ip6tables; do
        \$ipt -P FORWARD DROP
        \$ipt -A FORWARD -i wg0 -o eth0 -j ACCEPT
        \$ipt -A FORWARD -i eth0 -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      done
      iptables -t nat -A POSTROUTING -s 10.99.0.0/24 -o eth0 -j MASQUERADE
      ip6tables -t nat -A POSTROUTING -s fd99::/64 -o eth0 -j MASQUERADE
      exec sleep infinity" >/dev/null
}

cleanup() {
  docker rm -f -v "${CONTAINERS[@]}" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker volume rm "$P-torrent" "$P-forward" >/dev/null 2>&1 || true
}

# Every canary counts packets that do not come from the VPN server (only
# the pod talks to them; IPv6: TCP, UDP and echo, not neighbour discovery).
count_from_pod() {
  docker run --rm --network "container:$1" --cap-add NET_ADMIN --entrypoint "" "$WG_IMAGE" sh -c "
    iptables -w -I INPUT ! -s $SERVER_IP -m comment --comment twg-count &&
    for m in '-p tcp' '-p udp' '-p ipv6-icmp --icmpv6-type echo-request'; do
      ip6tables -w -I INPUT ! -s $SERVER_IP6 \$m -m comment --comment twg-count || exit 1
    done"
}
# On the VPN server: anything from the pod's own addresses but WireGuard.
count_plaintext() {
  docker run --rm --network "container:$P-server" --cap-add NET_ADMIN --entrypoint "" "$WG_IMAGE" sh -c "
    set -e
    for m in '-p tcp' '-p udp ! --dport 51820' '-p icmp --icmp-type echo-request'; do
      iptables -w -t raw -I PREROUTING -s $POD_IP \$m -m comment --comment twg-count
    done
    for m in '-p tcp' '-p udp ! --dport 51820' '-p ipv6-icmp --icmpv6-type echo-request'; do
      ip6tables -w -t raw -I PREROUTING -s $POD_IP6 \$m -m comment --comment twg-count
    done"
}
# In the pod: every new flow out eth0 but WireGuard's own (a rule after the
# kill switch's jump in mangle POSTROUTING sees only what it let through),
# whatever its destination: the gateway, multicast, the internet. And
# (twg-attempt) every connection attempt to the tracker, wherever it is routed.
count_escapes() {
  docker run --rm --network "container:$P-pod" --cap-add NET_ADMIN --entrypoint "" "$WG_IMAGE" sh -c "
    set -e
    for f in 4 6; do
      ipt=iptables server=$SERVER_IP tracker=$TRACKER_IP
      [ \$f = 4 ] || ipt=ip6tables server=$SERVER_IP6 tracker=$TRACKER_IP6
      \$ipt -w -t mangle -N TWGTEST-ESCAPE
      \$ipt -w -t mangle -A TWGTEST-ESCAPE -p udp -d \$server --dport 51820 -j RETURN
      \$ipt -w -t mangle -A TWGTEST-ESCAPE -m comment --comment twg-count -j RETURN
      \$ipt -w -t mangle -A POSTROUTING -o eth0 -m conntrack --ctstate NEW -j TWGTEST-ESCAPE
      \$ipt -w -t raw -I OUTPUT -d \$tracker -p tcp --dport 80 --syn -m comment --comment twg-attempt
    done"
}
# The pod's entrypoint has routed it like a CNI and written resolv.conf.
pod_ready() {
  docker run --rm --network "container:$P-pod" --entrypoint "" "$WG_IMAGE" sh -c "ip route show default | grep -q 'via $GW' && ip -6 route show default | grep -q 'via $GW6' &&
    ! ip route show | grep -q '^$SUBNET_PREFIX.0/24' && grep -q '^nameserver $TUN_SERVER' /etc/resolv.conf"
}

# A link-local address on eth0 of container $1, past duplicate address detection.
ll_ready() {
  docker run --rm --network "container:$1" --entrypoint "" "$WG_IMAGE" ip -6 -o addr show dev eth0 scope link |
    grep ' fe80::' | grep -qv tentative
}

# Each path is tried twice (the docker client can lose a probe's output);
# a failure names the path, so a broken harness says where.
baseline_ok() {
  case $1 in
    tcp4) [[ $(canary_seen) == "$POD_IP" ]] ;;
    tcp6) [[ $(canary_seen6) == "$POD_IP6" ]] ;;
    eth0-tcp4) [[ $(canary_seen "${ETH0[@]}") == "$POD_IP" ]] ;;
    eth0-tcp6) [[ $(canary_seen6 "${ETH0[@]}") == "$POD_IP6" ]] ;;
    link-local) [[ -n $CANARY_LL && $(canary_ll_seen) == fe80:* ]] ;;
    udp53) [[ $(dns_seen "BASELINE$2") == "$POD_IP" ]] ;;
    udp53-6) [[ $(dns_seen "BASELINE6$2" 6) == "$POD_IP6" ]] ;;
    udp6881) [[ $(dns_seen "BASELINEDHT$2" 4 6881) == "$POD_IP" ]] ;;
    icmp-eth0) as_raw ping -c1 -W2 -I eth0 "$CANARY_IP" >/dev/null 2>&1 ;;
  esac
}
# Before any firewall the pod reaches every canary directly, and every
# sensor counts it. The results go to $STAGE/baseline-*, which 01-setup.bats
# reports by name; a broken baseline also fails setup_suite.
baseline() {
  local path broken="" before_counts after_counts dead escapes_before escapes_after u
  before_counts=$(sensor_counts)
  # The eth0-bound requests are the positive control for the eth0 checks.
  for path in tcp4 tcp6 eth0-tcp4 eth0-tcp6 link-local udp53 udp53-6 udp6881 icmp-eth0; do
    baseline_ok $path A || baseline_ok $path B || broken="$broken $path"
  done
  if [[ -z $broken ]]; then
    echo ok >"$STAGE/baseline-reach"
  else
    echo "baseline: without the kill switch the pod cannot reach the canaries over:$broken (harness broken)" | tee "$STAGE/baseline-reach" >&2
    return 1
  fi
  # Plaintext to the tracker and the server (nothing listens on its port 80;
  # the refused SYN still counts), and multicast like UPnP's discovery.
  for u in "http://$TRACKER_IP/" "http://[$TRACKER_IP6]/" "http://$SERVER_IP/" "http://[$SERVER_IP6]/"; do
    as_app curl -sS -m 3 -o /dev/null "$u" >/dev/null 2>&1 || true
  done
  escapes_before=$(pod_hits twg-count "$P-pod")
  as_app sh -c 'echo M-SEARCH | nc -u -w1 239.255.255.250 1900' >/dev/null 2>&1 || true
  escapes_after=$(pod_hits twg-count "$P-pod")
  after_counts=$(sensor_counts)
  dead=$(join -j1 <(awk '{ print $1 "/" $2, $3 }' <<<"$before_counts" | sort) <(awk '{ print $1 "/" $2, $3 }' <<<"$after_counts" | sort) |
    awk '$3 <= $2 { printf " %s", $1 }')
  if [[ $before_counts == *unreadable* || $after_counts == *unreadable* ]]; then
    echo "baseline: the packet counters cannot be read (harness broken)" | tee "$STAGE/baseline-sensors" >&2
  elif [[ -n $dead ]]; then
    echo "baseline: these sensors did not count the pod's direct packets:$dead (harness broken)" | tee "$STAGE/baseline-sensors" >&2
  elif [[ $escapes_before == unreadable || $escapes_after == unreadable ]] || ((escapes_after <= escapes_before)); then
    echo "baseline: the pod's eth0 sensor did not count a multicast datagram (harness broken)" | tee "$STAGE/baseline-sensors" >&2
  else
    echo ok >"$STAGE/baseline-sensors"
    return 0
  fi
  return 1
}

setup_suite() {
  [[ ${#SIDECAR_SECURITY[@]} -gt 0 ]] || { echo "SIDECAR must be privileged or unprivileged" >&2; return 1; }
  export WG_IMAGE SIDECAR_IMAGE TX_IMAGE CANARY_IMAGE TRACKER_IMAGE NATPMP_IMAGE NATPMP FIREWALL_SH
  cleanup
  mkdir -p "$STAGE"

  # Pull up front with retries: registries rate-limit bursts of pulls, so
  # back off between attempts.
  local image attempt
  local images=("$WG_IMAGE" "$SIDECAR_IMAGE" "$TX_IMAGE" "$CANARY_IMAGE" "$TRACKER_IMAGE")
  ((NATPMP)) && images+=("$NATPMP_IMAGE")
  for image in "${images[@]}"; do
    # A sidecar image built here (image/wireguard) is not pulled.
    [[ $image != "$SIDECAR_IMAGE" || $image == "$WG_IMAGE" ]] || ! docker image inspect "$image" >/dev/null 2>&1 || continue
    for attempt in 1 2 3 4 5; do
      docker pull -q "$image" >/dev/null && break
      ((attempt < 5)) || { echo "cannot pull $image" >&2; return 1; }
      sleep $((attempt * 5))
    done
  done
  local client_key server_pub
  SERVER_KEY=$(wg_tool genkey)
  client_key=$(wg_tool genkey)
  server_pub=$(echo "$SERVER_KEY" | wg_tool pubkey)
  CLIENT_PUB=$(echo "$client_key" | wg_tool pubkey)
  # For the roaming server (another VPN server with the same key).
  export SERVER_KEY CLIENT_PUB

  docker network create --subnet "$SUBNET_PREFIX.0/24" --gateway "$GW" \
    --ipv6 --subnet "$SUBNET6_PREFIX:/64" --gateway "$GW6" "$NET" >/dev/null
  docker run -d --name "$P-canary" --network "$NET" --ip "$CANARY_IP" --ip6 "$CANARY_IP6" "$CANARY_IMAGE" >/dev/null
  # UDP/53 canary standing in for any DNS server outside the pod (cluster DNS,
  # NodeLocal DNSCache, the ISP); logs the source of every datagram.
  docker run -d --name "$P-dns" --network "$NET" --ip "$DNS_CANARY_IP" --ip6 "$DNS_CANARY_IP6" --entrypoint "" "$WG_IMAGE" \
    sh -c "while true; do nc -4 -luvn -w 1 $DNS_CANARY_IP 53; done & while true; do nc -6 -luvn -w 1 $DNS_CANARY_IP6 53; done &
      while true; do nc -4 -luvn -w 1 $DNS_CANARY_IP 6881; done" >/dev/null
  # HTTP tracker canary for Transmission's own announces: httpd logs the source
  # of each request and the CGI asks for the next announce in 10 seconds.
  docker run -d --name "$P-tracker" --network "$NET" --ip "$TRACKER_IP" --ip6 "$TRACKER_IP6" "$TRACKER_IMAGE" sh -c '
      mkdir -p /www/cgi-bin
      cat > /www/cgi-bin/announce <<"CGI"
#!/bin/sh
printf "Content-Type: text/plain\r\n\r\nd8:intervali10e12:min intervali5e5:peers0:e"
CGI
      chmod +x /www/cgi-bin/announce
      exec httpd -f -vv -p 80 -h /www' >/dev/null
  local c
  for c in "$P-canary" "$P-dns" "$P-tracker"; do count_from_pod "$c"; done

  # VPN server: terminates the tunnel and NATs to the "internet" (the canary).
  vpn_server "$P-server" "$SERVER_IP" "$SERVER_IP6" "$SERVER_KEY"
  # The failover server: the same, with its own key. Idle until 19-failover
  # stops the first one.
  vpn_server "$P-failover" "$FAILOVER_IP" "$FAILOVER_IP6" "$FAILOVER_KEY"
  count_plaintext

  # Pod sandbox, routed like a CNI: only a host route to the gateway.
  docker run -d --name "$P-pod" --network "$NET" --ip "$POD_IP" --ip6 "$POD_IP6" --privileged \
    --entrypoint bash "$WG_IMAGE" -c "
      ip route del $SUBNET_PREFIX.0/24 dev eth0
      ip route add $GW/32 dev eth0 scope link
      ip route replace default via $GW dev eth0
      ip -6 route del $SUBNET6_PREFIX:/64 dev eth0
      ip -6 route add $GW6/128 dev eth0
      ip -6 route replace default via $GW6 dev eth0
      # dnsPolicy: None with the VPN's resolver (its tunnel address), not
      # Docker's 127.0.0.11, which dockerd answers from outside the namespace.
      echo 'nameserver $TUN_SERVER' >/etc/resolv.conf
      # podSecurityContext.sysctls: what an unprivileged sidecar cannot set.
      [[ $SIDECAR == privileged ]] || sysctl -qw net.ipv4.conf.all.src_valid_mark=1
      exec sleep infinity" >/dev/null
  wait_until 30 pod_ready
  count_escapes

  mkdir -p "$STAGE/wg/config/wg_confs"
  stage_scripts "$STAGE/wg"
  cat >"$WG_CONF" <<EOF
[Interface]
PrivateKey = $client_key
Address = $TUN_CLIENT/32, $TUN_CLIENT6/128

[Peer]
PublicKey = $server_pub
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $SERVER_IP:51820
PersistentKeepalive = 5
EOF
  chmod 0600 "$WG_CONF"

  # The canary's link-local address: on-link via eth0 in the main table, so
  # the policy routing does not send it into the tunnel. Both ends must have
  # finished duplicate address detection, or the baseline probe races it.
  if ! wait_until 30 ll_ready "$P-canary" || ! wait_until 30 ll_ready "$P-pod"; then
    echo "no usable link-local address on eth0 of the canary or the pod" >&2
    return 1
  fi
  CANARY_LL=$(docker run --rm --network "container:$P-canary" --entrypoint "" "$WG_IMAGE" ip -6 -o addr show dev eth0 scope link |
    sed -n 's|.* inet6 \(fe80::[0-9a-f:]*\)/.*|\1|p' | head -n1)
  export CANARY_LL
  baseline

  # The sidecar exactly as the chart runs it.
  # The forwarded port, written by the sidecar and read by Transmission.
  local forward=() forward_ro=()
  if ((NATPMP)); then forward=(-v "$P-forward:/twg/forward"); forward_ro=(-v "$P-forward:/twg/forward:ro"); fi
  docker create --name "$P-wg" --network "container:$P-pod" "${SIDECAR_SECURITY[@]}" -v /twg "${forward[@]}" "${firewall_env[@]}" \
    --entrypoint /bin/bash "$SIDECAR_IMAGE" -c '/twg/scripts/firewall.sh apply && exec /init' >/dev/null
  docker cp "$STAGE/wg/." "$P-wg:/" >/dev/null
  docker start "$P-wg" >/dev/null
  wait_until 90 via_vpn || { echo "the tunnel never came up; nothing would mean anything" >&2; return 1; }
  # A firewall.sh failing its own check (a mutant): reported by 01-setup, but
  # every leak check still runs against it.
  note_if_check_broken
  # From here on nothing may leak, Transmission's start-up and its first
  # torrent (discovery, DHT, port mapping) included: 04 checks it.
  hits_mark "$STAGE/hits-tunnel-up"

  # settings-init with RPC credentials from the Secret.
  run_settings_init "$WG_CONF" "$STAGE" -e RPC_USERNAME=admin -e RPC_PASSWORD=s3cret
  # Transmission with the composed settings, but without credentials so the
  # web UI answers plainly for the reachability checks.
  mkdir -p "$STAGE/tx/config" "$STAGE/tx/twg/run"
  jq 'del(.["rpc-username"], .["rpc-password"]) | .["rpc-authentication-required"] = false' \
    "$STAGE/settings.json" >"$STAGE/tx/config/settings.json"
  # 0600 like the chart's (the image then chowns it to its user), so root in
  # the container, without CAP_DAC_OVERRIDE, cannot read it: as for the
  # liveness probe in Kubernetes.
  chmod 0600 "$STAGE/tx/config/settings.json"
  cp "$STAGE/tunnel.env" "$STAGE/tx/twg/run/tunnel.env"
  chmod 0644 "$STAGE/tx/twg/run/tunnel.env"
  stage_scripts "$STAGE/tx"
  # Capabilities as the chart allows them: everything dropped but these.
  docker create --name "$P-tx" --network "container:$P-pod" --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID \
    "${forward_ro[@]}" -e PUID=1000 -e PGID=1000 "$TX_IMAGE" >/dev/null
  docker cp "$STAGE/tx/." "$P-tx:/" >/dev/null
  docker start "$P-tx" >/dev/null
  wait_until 120 tx_listening
  # Transmission's RPC listens on IPv4 only here; an unprivileged IPv6 listener
  # on the web port stands in for it.
  docker run -d --name "$P-l6" --network "container:$P-pod" --cap-drop ALL --user 1000:1000 --entrypoint "" "$WG_IMAGE" \
    nc -6 -lk "$POD_IP6" "$WEB_PORT" >/dev/null

  # Transmission's own traffic: a torrent whose tracker is the canary. Its
  # announces must come from the VPN server, never from the pod.
  docker run --rm --network none --entrypoint sh -v "$P-torrent:/t" "$TX_IMAGE" -c \
    "echo leak-test >/t/payload && transmission-create -o /t/test.torrent -t http://$TRACKER_IP/cgi-bin/announce \
      -t http://[$TRACKER_IP6]/cgi-bin/announce /t/payload" >/dev/null 2>&1
  docker run --rm --network container:"$P-pod" --cap-drop ALL -v "$P-torrent:/t" --entrypoint transmission-remote "$TX_IMAGE" \
    "127.0.0.1:$WEB_PORT" -a /t/test.torrent >/dev/null || { echo "could not add the test torrent" >&2; return 1; }
  wait_until 60 tx_live
}

teardown_suite() {
  # setup_suite's output is shown when it fails: add what the containers said.
  [[ -n ${BATS_SETUP_SUITE_COMPLETED:-} ]] || dump_logs
  [[ ${KEEP:-0} == 1 ]] || cleanup
}
