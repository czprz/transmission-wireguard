# shellcheck shell=bash
# shellcheck disable=SC2034 # much of it is used by setup_suite.bash and the tests only
# Configuration and helpers of the cluster suite, loaded by setup_suite.bash
# and by every test file. Only definitions: the shared environment itself
# (containers, namespace, release) is made by setup_suite, which exports
# what the tests need (the addresses, the keys, the pod).

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# The chart's default image for $1, so the test follows Renovate's bumps.
chart_image() {
  local tpl=$ROOT/templates/_helpers.tpl repo tag digest
  repo=$(sed -n "s/.*\.Values\.images\.$1 \"repo\" \"\([^\"]*\)\".*/\1/p" "$tpl")
  tag=$(sed -n "s/.*default \"\([^\"]*\)\" \.Values\.images\.$1\.tag.*/\1/p" "$tpl")
  digest=$(sed -n "s/.*default \"\([^\"]*\)\" \.Values\.images\.$1\.digest.*/\1/p" "$tpl")
  [[ -n $repo && -n $tag && -n $digest ]] || { echo "cannot read the $1 image from $tpl" >&2; return 1; }
  echo "$repo:$tag@$digest"
}
WG_IMAGE="${WG_IMAGE:-$(chart_image wireguard)}"
CANARY_IMAGE="${CANARY_IMAGE:-busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec}"
CURL_IMAGE=curlimages/curl:8.11.1@sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69

# Where the cluster runs. The canaries and the VPN server join the cluster's
# Docker network; the node container gives the node's address and, when a
# shutdown is slow, the kubelet's log.
# - kind: network kind, node kind-control-plane, kubelet in the node's journal
# - k3d:  network k3d-<cluster>, node k3d-<cluster>-server-0, kubelet in the
#   node container's own log (k3s runs it in-process); the kubeconfig is
#   k3d-cluster.sh's file, never the user's default one
CLUSTER=${CLUSTER:-kind}
case $CLUSTER in
  kind)
    CLUSTER_NET=${CLUSTER_NET:-${KIND_NET:-kind}}
    NODE_CONTAINER=${NODE_CONTAINER:-kind-control-plane}
    ;;
  k3d)
    K3D_CLUSTER=${K3D_CLUSTER:-twg-k3d}
    CLUSTER_NET=${CLUSTER_NET:-k3d-$K3D_CLUSTER}
    NODE_CONTAINER=${NODE_CONTAINER:-k3d-$K3D_CLUSTER-server-0}
    export KUBECONFIG=${K3D_KUBECONFIG:-$ROOT/tests/e2e/.k3d/$K3D_CLUSTER.kubeconfig}
    ;;
esac  # any other CLUSTER fails setup_suite
NS="${NS:-twg-e2e}"
RELEASE=twg
P=twg-kind
TUN_SERVER=10.99.0.1
TUN_CLIENT=10.99.0.2
TUN_SERVER6=fd99::1
TUN_CLIENT6=fd99::2
IPV6=${IPV6:-0}
UPGRADE_FROM=${UPGRADE_FROM:-}
# Not into UPGRADE_FLAGS itself: that is exported, and an exported array
# reaches the test files as its first word only.
read -ra UPGRADE_ARGS <<<"${UPGRADE_FLAGS:-}"
# The termination test holds the release pod with a finalizer.
HOLD=twg.e2e/hold

# A pass is reported as a TAP comment, so its details (addresses, counts)
# show in the run's log; a failure ends the test with its message.
pass() { { echo "#   PASS  $*" >&3; } 2>/dev/null || echo "  PASS  $*"; }
fail() { echo "  FAIL  $*" >&2; return 1; }
info() { { echo "#   $*" >&3; } 2>/dev/null || echo "  $*"; }
# Skips the IPv6 variant of a check unless the cluster is dual-stack.
need_ipv6() { ((IPV6)) || skip "IPv6 checks need IPV6=1 (a dual-stack cluster)"; }

# wait_until <seconds> <cmd…>: runs cmd (in this shell, so it can set
# variables) until it succeeds; fails, saying what it waited for, once
# <seconds> have passed.
wait_until() {
  local timeout=$1 end
  shift
  end=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS >= end)); then
      echo "        timed out after ${timeout}s waiting for: $*" >&2
      return 1
    fi
    sleep 1
  done
}

# $1=wait: block until the namespace is gone, so a rerun can recreate it.
# Releases the termination test's finalizer, or the namespace never goes.
cleanup() {
  docker rm -f $P-server $P-canary $P-udp >/dev/null 2>&1 || true
  kubectl -n "$NS" get pods -o name 2>/dev/null | xargs -r kubectl -n "$NS" patch --type=merge \
    -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  kubectl delete namespace "$NS" --ignore-not-found --wait="${1:-false}" --timeout=3m >/dev/null 2>&1 || true
}
# The pod and tunnel state, for a failed test.
dump_state() {
  kubectl -n "$NS" get pods -o wide || true
  [[ -z ${POD:-} ]] || kubectl -n "$NS" describe pod "$POD" | tail -30 || true
  [[ -z ${POD:-} ]] || kubectl -n "$NS" logs "$POD" -c wireguard --tail 40 || true
  docker logs --tail 20 $P-server 2>&1 | sed 's/^/  server | /' || true
}
# For a test file's teardown: the state above, if the test failed.
dump_on_failure() {
  [[ -n ${BATS_TEST_COMPLETED:-} || -n ${BATS_TEST_SKIPPED+x} ]] || dump_state
}
# The kubelet's log of the last $1 seconds.
kubelet_log() {
  case $CLUSTER in
    kind) docker exec "$NODE_CONTAINER" journalctl -u kubelet --no-pager --since "-${1}s" ;;
    k3d) docker logs --since "${1}s" "$NODE_CONTAINER" 2>&1 ;;
  esac
}

wg_tool() { docker run --rm -i --entrypoint wg "$WG_IMAGE" "$@"; }
container_ip() { docker inspect -f "{{(index .NetworkSettings.Networks \"$CLUSTER_NET\").IPAddress}}" "$1"; }
container_ip6() { docker inspect -f "{{(index .NetworkSettings.Networks \"$CLUSTER_NET\").GlobalIPv6Address}}" "$1"; }
kx() { kubectl -n "$NS" exec "$POD" -c "$1" -- "${@:2}"; }
# The release's values. The persistence choice only on a fresh install: an
# upgraded release keeps its earlier defaults and PVC.
chart_args() {
  CHART_ARGS=(
    --set wireguard.existingSecret=wg-client
    --set "wireguard.endpoints[0].ip=$SERVER_IP"
    --set "wireguard.endpoints[0].port=51820"
    --set wireguard.handshakeMaxAgeSeconds=180
    --set transmission.rpcAuth.username=admin
    --set transmission.rpcAuth.password=kind-test-password
    --set tests.enabled=true
    --set "tests.ipEchoUrl=http://$CANARY_IP/cgi-bin/ip"
  )
  if [[ -z $UPGRADE_FROM ]]; then
    # /config on an emptyDir and the downloads on a PVC of their own.
    CHART_ARGS+=(--set persistence.enabled=false --set persistence.downloads.enabled=true)
  fi
}

# The canary answers with the client's address (empty if unreachable): for
# checks that traffic does arrive. Leak checks use egress below.
remote_addr() { head -n1 | tr -d '[:space:]'; }
canary_seen() {
  kx transmission curl -sS -m 3 "http://$CANARY_IP/cgi-bin/ip" 2>/dev/null | remote_addr || true
}
canary_seen6() {
  kx transmission curl -6 -sS -m 3 "http://[$CANARY_IP6]/cgi-bin/ip" 2>/dev/null | remote_addr || true
}
# Where a request from the Transmission container went: "vpn", "blocked"
# (refused, timed out or cut off), "leak <address>", or "broken <curl exit>"
# ("broken exec" when kubectl exec failed), which proves nothing.
egress() {
  local out rc seen
  # shellcheck disable=SC2016 # expanded by the pod's shell
  out=$(kx transmission sh -c 'curl -sS -m 3 "$@" 2>/dev/null; rc=$?; echo; echo "rc=$rc"' sh "$@" 2>/dev/null || true)
  rc=$(sed -n 's/^rc=//p' <<<"$out")
  seen=$(grep -v '^rc=' <<<"$out" | remote_addr || true)
  case $rc in
    0) if [[ -z $seen ]]; then echo "broken empty-answer"; return; fi
      if [[ $seen == "$SERVER_IP" || $seen == "${SERVER_IP6:-none}" ]]; then echo vpn; else echo "leak ${seen:-unknown}"; fi ;;
    7 | 28 | 52 | 56) echo blocked ;;
    *) echo "broken ${rc:-exec}" ;;
  esac
}
egress4() { egress "$@" "http://$CANARY_IP/cgi-bin/ip"; }
egress6() { egress -6 "$@" "http://[$CANARY_IP6]/cgi-bin/ip"; }
# UDP datagrams tagged $1 to the UDP canary over IPv${2:-4}; prints the
# source the canary saw (empty if none arrived). IPv6 uses its own port so
# the two listeners do not race for one dual-stack socket.
udp_seen() {
  local tag=$1 fam=${2:-4} ip=$UDP_IP port=6881 out
  [[ $fam == 4 ]] || { ip=$UDP_IP6 port=6882; }
  out=$(kx transmission sh -c "for i in 1 2 3 4 5; do echo $tag | nc -$fam -u -w1 $ip $port; done; echo SENT" 2>/dev/null || true)
  [[ $out == *SENT* ]] || { echo "broken udp-exec"; return; }
  # Time for the canary to log the last datagram: one that never arrives
  # cannot be waited for, so this window is what "none arrived" means.
  sleep 1
  # Every source that sent the tag, not just the last.
  docker logs $P-udp 2>&1 | grep -B1 -x "$tag" | sed -n 's/^Connection received on \(::ffff:\)\{0,1\}\([^ ]*\) .*/\2/p' |
    sort -u | paste -sd' ' - || true
}
# Records probe results while traffic must not leak; result_summary then
# reports leaks, probes that could not run, too few probes, and (with
# need-blocked as $2) probes that never overlapped the outage.
LEAKED="" BROKEN="" PROBES=0 BLOCKED=0
record() {
  local r
  for r in "$@"; do
    PROBES=$((PROBES + 1))
    case $r in
      leak*) LEAKED="$LEAKED ${r#leak }" ;;
      broken*) BROKEN="$BROKEN ${r#broken }" ;;
      blocked | "") BLOCKED=$((BLOCKED + 1)) ;; # "": no UDP datagram arrived
      vpn | "$SERVER_IP" | "${SERVER_IP6:-none}") ;; # UDP from the server is the tunnel
      *) LEAKED="$LEAKED $r" ;; # UDP source addresses
    esac
  done
}
result_summary() {
  local leaked=$LEAKED broken=$BROKEN probes=$PROBES blocked=$BLOCKED
  LEAKED="" BROKEN="" PROBES=0 BLOCKED=0
  if [[ -n $leaked ]]; then
    fail "LEAK $1 (canary saw$leaked)"
  elif [[ -n $broken ]]; then
    fail "probes $1 could not run ($broken), so they prove nothing"
  elif ((probes < 2)); then
    fail "only $probes probe(s) ran $1, which proves nothing"
  elif [[ ${2:-} == need-blocked ]] && ((blocked == 0)); then
    fail "none of the $probes probes $1 hit the outage, so they prove nothing"
  else
    pass "no direct egress $1 ($probes probes, $blocked blocked)"
  fi
}
# Sensors that count leaked packets, however the client saw them. Only read
# around windows in which no ordinary pod or helm test talks to them.
# - The canaries count every packet that does not come from the VPN server
#   (IPv6: TCP, UDP and echo only, not neighbour discovery).
# - The VPN server counts new plaintext connections (anything but WireGuard).
# - The release pod counts every new flow leaving eth0 other than WireGuard's
#   own, whatever its destination (a rule after the kill switch's jump in
#   mangle POSTROUTING sees only what it let through).
count_rules() {
  docker run --rm --network "container:$1" --cap-add NET_ADMIN --entrypoint "" "$WG_IMAGE" sh -c "
    set -e
    iptables -w -I INPUT ! -s $SERVER_IP -m comment --comment twg-count
    if [ -n '${SERVER_IP6:-}' ]; then
      for m in '-p tcp' '-p udp' '-p ipv6-icmp --icmpv6-type echo-request'; do
        ip6tables -w -I INPUT ! -s '${SERVER_IP6:-}' \$m -m comment --comment twg-count
      done
    fi"
}
count_plaintext() {
  docker run --rm --network "container:$P-server" --cap-add NET_ADMIN --entrypoint "" "$WG_IMAGE" sh -c "
    set -e
    for m in '-p tcp' '-p udp ! --dport 51820' '-p icmp --icmp-type echo-request'; do
      iptables -w -t mangle -I PREROUTING -i eth0 -m conntrack --ctstate NEW \$m -m comment --comment twg-count
    done
    for m in '-p tcp' '-p udp ! --dport 51820' '-p ipv6-icmp --icmpv6-type echo-request'; do
      ip6tables -w -t mangle -I PREROUTING -i eth0 -m conntrack --ctstate NEW \$m -m comment --comment twg-count
    done"
}
# Installs the pod's eth0 sensor, or puts back its jump: flushing mangle
# POSTROUTING (the NetworkPolicy test) removes the jump, not the chain.
count_escapes() {
  # shellcheck disable=SC2016 # expanded by the pod's shell
  kx wireguard sh -c 'set -e
    for f in 4 6; do
      ipt=iptables server=$1
      [ $f = 4 ] || ipt=ip6tables server=${2:-::1}
      if ! $ipt -w -t mangle -S TWGTEST-ESCAPE >/dev/null 2>&1; then
        $ipt -w -t mangle -N TWGTEST-ESCAPE
        $ipt -w -t mangle -A TWGTEST-ESCAPE -p udp -d "$server" --dport 51820 -j RETURN
        $ipt -w -t mangle -A TWGTEST-ESCAPE -m comment --comment twg-count -j RETURN
      fi
      $ipt -w -t mangle -C POSTROUTING -o eth0 -m conntrack --ctstate NEW -j TWGTEST-ESCAPE 2>/dev/null ||
        $ipt -w -t mangle -A POSTROUTING -o eth0 -m conntrack --ctstate NEW -j TWGTEST-ESCAPE
    done' sh "$SERVER_IP" "${SERVER_IP6:-}"
}
# Packets counted by comment twg-count in iptables-save -c output on stdin,
# as "<family> <packets>" lines.
count_lines() {
  awk '/^V6$/ { fam = 6 } !fam { fam = 4 }
    / --comment "?twg-count"?( |$)/ && match($0, /^\[[0-9]+:/) { n[fam] += substr($0, 2, RLENGTH - 2) }
    END { print 4, n[4] + 0; print 6, n[6] + 0 }'
}
# The release pod's mangle tables, into POD_MANGLE; fails while unreadable.
read_pod_mangle() {
  POD_MANGLE=$(kx wireguard sh -c 'iptables-save -c -t mangle && echo V6 && ip6tables-save -c -t mangle && echo END' 2>/dev/null || true)
  [[ $POD_MANGLE == *END* ]]
}
# "<sensor> <family> <packets>" for every sensor; "nopod" as $1 leaves out
# the release pod (once it is gone).
sensor_counts() {
  local c out
  for c in $P-canary $P-udp $P-server; do
    out=""
    for _ in 1 2 3; do
      out=$(docker run --rm --network "container:$c" --cap-add NET_ADMIN --entrypoint "" "$WG_IMAGE" \
        sh -c 'iptables-save -c && echo V6 && ip6tables-save -c && echo END' 2>/dev/null || true)
      [[ $out == *END* ]] && break
    done
    [[ $out == *END* ]] || { echo unreadable; return; }
    count_lines <<<"$out" | sed "s/^/$c /"
  done
  [[ ${1:-} != nopod ]] || return 0
  # The sidecar may be restarting: retry for a while.
  wait_until 30 read_pod_mangle || { echo unreadable; return; }
  count_lines <<<"$POD_MANGLE" | sed "s/^/pod /"
}
canary_hits() {
  local out
  out=$(sensor_counts "$@")
  if [[ $out == *unreadable* ]]; then echo unreadable; else awk '{ t += $3 } END { print t + 0 }' <<<"$out"; fi
}
HITS=unreadable
hits_mark() { HITS=$(canary_hits "$@"); }
hits_check() {
  local now was=$HITS
  now=$(canary_hits "${@:2}")
  HITS=$now
  if [[ $was == unreadable || $now == unreadable ]]; then
    fail "could not read the packet counters $1"
  elif ((now > was)); then
    fail "LEAK: $((now - was)) packet(s) outside the tunnel reached the canaries, the server or left eth0 $1"
  else
    pass "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic $1"
  fi
}
# TCP connect check: telnet:// never ends on its own, so curl always times
# out; time_connect is non-zero once the connection was established.
tcp_open() { [[ $("$@" -s -o /dev/null -m 2 -w '%{time_connect}' 2>/dev/null </dev/null) =~ [1-9] ]]; }
# The same from the Transmission container bound to eth0: "open", "blocked"
# (refused or timed out without connecting) or "broken".
tcp_eth0() {
  local out tc rc
  # shellcheck disable=SC2016 # expanded by the pod's shell
  out=$(kx transmission sh -c 'curl -s -o /dev/null -m 2 --interface "if!eth0" -w "%{time_connect}" "$1" </dev/null; echo " rc=$?"' sh "$1" 2>/dev/null || true)
  tc=${out%% *} rc=${out##*rc=}
  if [[ $tc =~ [1-9] ]]; then
    echo open
  elif [[ $out == *rc=* && $rc =~ ^(7|28)$ ]]; then
    echo blocked
  else
    echo "broken ${out:-exec}"
  fi
}
# A request bound to eth0 must be refused (curl exit 7) or time out (28);
# any other failure (exec failed, no eth0) proves nothing. "if!" makes curl
# fail rather than fall back to binding eth0's address (into the tunnel).
ETH0=(--interface 'if!eth0')
check_eth0() {
  local what=$1 rc
  shift
  # shellcheck disable=SC2016 # expanded by the pod's shell
  rc=$(kx transmission sh -c 'curl -sk -m 4 -o /dev/null --interface "if!eth0" "$@" 2>/dev/null; echo "rc=$?"' sh "$@" |
    sed -n 's/^rc=//p' || true)
  case $rc in
    7 | 28) pass "a socket bound to eth0 cannot reach $what" ;;
    0) fail "LEAK: a socket bound to eth0 reached $what" ;;
    *) fail "eth0 check for $what proves nothing (curl exit ${rc:-none})" ;;
  esac
}
# The same request from an ordinary pod in the namespace: its output and
# exit code. Not `kubectl run -i --rm`, which loses the output of a command
# that ends before kubectl attaches.
pod_finished() {
  [[ $(kubectl -n "$NS" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null) =~ ^(Succeeded|Failed)$ ]]
}
ordinary_pod() {
  local name="probe-$RANDOM$RANDOM" rc
  kubectl -n "$NS" run "$name" --restart=Never --quiet --image="$CURL_IMAGE" --command -- "$@" >/dev/null 2>&1 || return 1
  wait_until 60 pod_finished "$name" || true
  kubectl -n "$NS" logs "$name" 2>/dev/null || true
  rc=$(kubectl -n "$NS" get pod "$name" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)
  kubectl -n "$NS" delete pod "$name" --wait=false >/dev/null 2>&1 || true
  [[ $rc =~ ^[0-9]+$ ]] || rc=1
  return "$rc"
}
via_vpn() { [[ $(canary_seen) == "$SERVER_IP" ]]; }
firewall_ok() { kx wireguard /twg/scripts/firewall.sh check; }
sidecar_restarts() {
  kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.initContainerStatuses[?(@.name=="wireguard")].restartCount}'
}
# Re-reads the count on every call, so it can be polled with wait_until.
restarted_since() {
  local n
  n=$(sidecar_restarts 2>/dev/null || true)
  [[ $n =~ ^[0-9]+$ ]] && ((n > $1))
}
# Runs the chart's helm test; its output is kept in HELM_TEST_OUT.
helm_test() {
  local rc=0
  HELM_TEST_OUT=$(helm test $RELEASE -n "$NS" --logs --timeout 3m 2>&1) || rc=$?
  # helm can print the pod's log more than once.
  sed -n 's/^\(PASS\|FAIL\)  /        test pod: &/p' <<<"$HELM_TEST_OUT" | awk '!seen[$0]++'
  return $rc
}

netpol_on() { kubectl -n "$NS" get networkpolicy "$RELEASE-transmission-wireguard" >/dev/null 2>&1; }
# Turns the release's NetworkPolicy on or off, if it is not already. Only
# the policy changes, not the pod spec, so the same pod keeps running.
set_netpol() {
  local want=$1
  if [[ $want == on ]] && netpol_on; then return 0; fi
  if [[ $want == off ]] && ! netpol_on; then return 0; fi
  chart_args
  helm upgrade $RELEASE "$ROOT" -n "$NS" --wait --timeout 5m "${CHART_ARGS[@]}" \
    --set "networkPolicy.enabled=$([[ $want == on ]] && echo true || echo false)" >/dev/null
  [[ $(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}' 2>/dev/null) == "$POD_UID" ]] ||
    fail "switching the NetworkPolicy $want replaced the pod"
}
# Puts the release back as the next test expects it, and fails if it does
# not recover: the rules tests add removed (by spec: if the sidecar
# restarted meanwhile, rule 1 is a real rule again), the kill switch intact
# (a sidecar whose kill switch is gone is restarted), the eth0 sensor in
# place, and traffic through the VPN.
restore_release() {
  # shellcheck disable=SC2016 # expanded by the pod's shell
  kx wireguard sh -c 'for t in iptables ip6tables; do
      $t -w -D TWG-OUTPUT -j ACCEPT; $t -w -t mangle -D TWG-POSTROUTING -j RETURN
      $t -w -t mangle -D OUTPUT -j MARK --set-mark 51820
    done' >/dev/null 2>&1 || true
  if ! wait_until 30 firewall_ok; then
    info "restarting the sidecar to restore its kill switch"
    kx wireguard sh -c 'kill 1' >/dev/null 2>&1 || true
    wait_until 90 firewall_ok || fail "the kill switch did not pass check, even after a sidecar restart"
  fi
  wait_until 90 via_vpn || fail "traffic does not go through the VPN"
  count_escapes >/dev/null || fail "could not put back the pod's eth0 sensor"
}

# For a test file whose scenario runs once in setup_file and whose tests
# each judge one result of it: outcome <name> <check…> runs the check (in
# this shell) and keeps its verdict; verdict <name> replays it in a test.
outcome() {
  local name=$1 rc=0
  shift
  "$@" >"$BATS_FILE_TMPDIR/$name" 2>&1 3>&1 || rc=$?
  echo "$rc" >"$BATS_FILE_TMPDIR/$name.rc"
}
verdict() {
  local f=$BATS_FILE_TMPDIR/$1
  [[ -f $f.rc ]] || fail "the scenario in setup_file did not get as far as this check"
  if [[ $(cat "$f.rc") == 0 ]]; then
    { cat "$f" >&3; } 2>/dev/null || cat "$f"
  else
    cat "$f" >&2
    return 1
  fi
}
