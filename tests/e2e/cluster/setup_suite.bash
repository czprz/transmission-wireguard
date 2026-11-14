# shellcheck shell=bash
# The one environment every test of the run shares: a WireGuard server and
# HTTP and UDP canaries as containers on the cluster's Docker network,
# outside the cluster, the namespace with the client's Secret, and the
# release, installed (or, with UPGRADE_FROM, upgraded from an earlier one).
# Traffic that leaks out of the pod reaches a canary from the node's IP;
# traffic through the VPN arrives from the server.

# shellcheck source=tests/e2e/cluster/helpers.bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.bash"

setup_suite() {
  [[ $CLUSTER == kind || $CLUSTER == k3d ]] || fail "unknown CLUSTER: $CLUSTER (kind or k3d)"
  # The cluster in KUBECONFIG must be the one whose Docker network the
  # canaries join; its node is named like its container on kind and k3d.
  kubectl get node "$NODE_CONTAINER" >/dev/null ||
    fail "the cluster in ${KUBECONFIG:-~/.kube/config} has no node $NODE_CONTAINER (CLUSTER=$CLUSTER)"
  # Only from here on is the cluster ours to clean up: teardown_suite runs
  # even when the check above fails.
  touch "$BATS_SUITE_TMPDIR/our-cluster"
  cleanup true
  # Pull up front with retries: registries rate-limit bursts of pulls.
  local image attempt
  for image in "$WG_IMAGE" "$CANARY_IMAGE"; do
    for attempt in 1 2 3 4 5; do
      docker pull -q "$image" >/dev/null && break
      ((attempt < 5)) || fail "cannot pull $image"
      sleep $((attempt * 5)) # back off before the registry's next try
    done
  done
  local server_key client_pub
  server_key=$(wg_tool genkey)
  CLIENT_KEY=$(wg_tool genkey)
  SERVER_PUB=$(echo "$server_key" | wg_tool pubkey)
  client_pub=$(echo "$CLIENT_KEY" | wg_tool pubkey)
  NODE_IP=$(container_ip "$NODE_CONTAINER")

  # Plain-text "what is my IP": busybox httpd hands IPv4 clients over as
  # [::ffff:a.b.c.d].
  docker run -d --name "$P-canary" --network "$CLUSTER_NET" "$CANARY_IMAGE" sh -c '
    mkdir -p /www/cgi-bin
    cat > /www/cgi-bin/ip <<"CGI"
#!/bin/sh
a=${REMOTE_ADDR#[}; a=${a%]}; a=${a#::ffff:}
printf "Content-Type: text/plain\r\n\r\n%s\n" "$a"
CGI
    chmod +x /www/cgi-bin/ip
    exec httpd -f -p 80 -h /www' >/dev/null
  # UDP canary (a DHT-style port), logging the source of every datagram.
  docker run -d --name "$P-udp" --network "$CLUSTER_NET" --entrypoint "" "$WG_IMAGE" \
    sh -c 'while true; do nc -4 -luvn -w 1 6881; done & while true; do nc -6 -luvn -w 1 6882; done' >/dev/null
  docker run -d --name "$P-server" --network "$CLUSTER_NET" --privileged \
    --entrypoint bash "$WG_IMAGE" -c "
    set -e
    echo '$server_key' > /tmp/k
    ip link add wg0 type wireguard
    wg set wg0 listen-port 51820 private-key /tmp/k peer '$client_pub' allowed-ips $TUN_CLIENT/32,$TUN_CLIENT6/128
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
  CANARY_IP=$(container_ip "$P-canary")
  SERVER_IP=$(container_ip "$P-server")
  UDP_IP=$(container_ip "$P-udp")
  SERVER_IP6="" CANARY_IP6="" UDP_IP6=""
  info "node $NODE_IP, VPN server $SERVER_IP, canary $CANARY_IP"
  if ((IPV6)); then
    CANARY_IP6=$(container_ip6 "$P-canary")
    SERVER_IP6=$(container_ip6 "$P-server")
    UDP_IP6=$(container_ip6 "$P-udp")
    [[ -n $CANARY_IP6 && -n $SERVER_IP6 ]] || fail "IPV6=1 but the $CLUSTER_NET network has no IPv6"
    info "VPN server $SERVER_IP6, canary $CANARY_IP6"
  fi
  count_rules "$P-canary"
  count_rules "$P-udp"
  count_plaintext

  kubectl create namespace "$NS" >/dev/null
  kubectl -n "$NS" create secret generic wg-client --from-file=wg0.conf=/dev/stdin >/dev/null <<EOF
[Interface]
PrivateKey = $CLIENT_KEY
Address = $TUN_CLIENT/32, $TUN_CLIENT6/128

[Peer]
PublicKey = $SERVER_PUB
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $SERVER_IP:51820
PersistentKeepalive = 5
EOF
  chart_args
  OLD_PVC_UID="" UPGRADE_MARKER=""
  if [[ -z $UPGRADE_FROM ]]; then
    helm install $RELEASE "$ROOT" -n "$NS" --wait --timeout 5m "${CHART_ARGS[@]}" --set networkPolicy.enabled=false >/dev/null
  else
    UPGRADED_FROM=$(helm show chart "$UPGRADE_FROM" | sed -n 's/^version: //p')
    info "upgrade from $UPGRADED_FROM"
    # The earlier release as its users run it: its defaults, its PVC, and
    # what 1.0 refuses to install without (RPC auth; the NetworkPolicy's
    # endpoints, here with the NetworkPolicy off as for the upgrade). Its pod
    # need not become ready here; the upgrade is what is tested.
    helm install $RELEASE "$UPGRADE_FROM" -n "$NS" --set wireguard.existingSecret=wg-client \
      --set networkPolicy.enabled=false --set transmission.rpcAuth.username=admin \
      --set transmission.rpcAuth.password=kind-test-password >/dev/null
    kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Bound "pvc/$RELEASE-transmission-wireguard" --timeout 3m >/dev/null 2>&1 ||
      kubectl -n "$NS" get pvc "$RELEASE-transmission-wireguard" >/dev/null
    OLD_PVC_UID=$(kubectl -n "$NS" get pvc "$RELEASE-transmission-wireguard" -o jsonpath='{.metadata.uid}')
    # A download of the earlier release's, at the root of its PVC (its /data):
    # the upgraded pod must still have it.
    UPGRADE_MARKER="twg-upgrade-$(date +%s)-$RANDOM"
    write_on_pvc "$RELEASE-transmission-wireguard" .twg-upgrade-marker "$UPGRADE_MARKER" ||
      fail "could not write a file onto the earlier release's PVC"
    # A failed upgrade leaves nothing to test: every test fails with this.
    helm upgrade $RELEASE "$ROOT" -n "$NS" --wait --timeout 5m "${UPGRADE_ARGS[@]}" "${CHART_ARGS[@]}" \
      --set networkPolicy.enabled=false >/dev/null || fail "helm upgrade from the earlier release fails"
  fi
  POD=$(kubectl -n "$NS" get pod -l app.kubernetes.io/instance=$RELEASE -o jsonpath='{.items[0].metadata.name}')
  POD_UID=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}')
  wait_until 75 via_vpn || true # the first handshake; the tests say if it never came
  count_escapes >/dev/null || fail "could not install the pod's eth0 sensor"
  export CLUSTER KUBECONFIG CLIENT_KEY SERVER_PUB NODE_IP SERVER_IP SERVER_IP6 CANARY_IP CANARY_IP6 \
    UDP_IP UDP_IP6 OLD_PVC_UID UPGRADE_MARKER UPGRADED_FROM POD POD_UID
}

teardown_suite() {
  # A failed setup_suite fails every test; show why.
  [[ -e $BATS_SUITE_TMPDIR/our-cluster ]] || return 0
  [[ -n ${BATS_SETUP_SUITE_COMPLETED:-} ]] || dump_state
  [[ ${KEEP:-0} == 1 ]] || cleanup
}
