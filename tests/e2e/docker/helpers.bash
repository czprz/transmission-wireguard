# shellcheck shell=bash
# Shared by setup_suite.bash and every test file: the pod's layout, the
# probes and the packet sensors. See setup_suite.bash for what is built.
#
# Knobs:
#   SIDECAR=privileged|unprivileged  how the sidecar runs (default privileged)
#   FIREWALL_SH=<path>               replaces files/firewall.sh (mutation-test.sh)
#   WG_IMAGE, TX_IMAGE, CANARY_IMAGE, TRACKER_IMAGE
#   TWG_E2E_PREFIX                   Docker resource names (default twg-e2e)
#   TWG_E2E_NET_ID                   the network's 172.31.<id>.0/24 (derived
#                                    from the prefix, so two runs coexist)
#   KEEP=1                           leave the containers running
# shellcheck disable=SC2034 # used by the files that load this one

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# The chart's default image for $1 (wireguard, transmission), so the test
# follows Renovate's bumps of _helpers.tpl.
chart_image() {
  local tpl=$ROOT/templates/_helpers.tpl repo tag digest
  repo=$(sed -n "s/.*\.Values\.images\.$1 \"repo\" \"\([^\"]*\)\".*/\1/p" "$tpl")
  tag=$(sed -n "s/.*default \"\([^\"]*\)\" \.Values\.images\.$1\.tag.*/\1/p" "$tpl")
  digest=$(sed -n "s/.*default \"\([^\"]*\)\" \.Values\.images\.$1\.digest.*/\1/p" "$tpl")
  [[ -n $repo && -n $tag && -n $digest ]] || { echo "cannot read the $1 image from $tpl" >&2; return 1; }
  echo "$repo:$tag@$digest"
}
# Resolved once in setup_suite and exported, so every file runs the same.
WG_IMAGE="${WG_IMAGE:-$(chart_image wireguard)}"
TX_IMAGE="${TX_IMAGE:-$(chart_image transmission)}"
CANARY_IMAGE="${CANARY_IMAGE:-traefik/whoami:v1.10.3@sha256:43a68d10b9dfcfc3ffbfe4dd42100dc9aeaf29b3a5636c856337a5940f1b4f1c}"
TRACKER_IMAGE="${TRACKER_IMAGE:-busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec}"
# FIREWALL_SH replaces the chart's firewall.sh (tests/e2e/mutation-test.sh).
FIREWALL_SH=${FIREWALL_SH:-$ROOT/files/firewall.sh}

P=${TWG_E2E_PREFIX:-twg-e2e}
# privileged (the chart's default) or unprivileged: the sidecar with only
# NET_ADMIN + NET_RAW and src_valid_mark set for the pod, as the README
# documents for kubelets that allow that sysctl.
SIDECAR=${SIDECAR:-privileged}
case $SIDECAR in
  privileged) SIDECAR_SECURITY=(--privileged) ;;
  unprivileged) SIDECAR_SECURITY=(--cap-add NET_ADMIN --cap-add NET_RAW) ;;
  *) SIDECAR_SECURITY=() ;; # setup_suite refuses it
esac
# Another prefix gets another subnet: Docker refuses overlapping networks.
if [[ $P == twg-e2e ]]; then NET_ID=${TWG_E2E_NET_ID:-250}; else NET_ID=${TWG_E2E_NET_ID:-$(($(cksum <<<"$P" | cut -d' ' -f1) % 100 + 150))}; fi
NET=$P-net
SUBNET_PREFIX=172.31.$NET_ID
GW=$SUBNET_PREFIX.1
CANARY_IP=$SUBNET_PREFIX.10
DNS_CANARY_IP=$SUBNET_PREFIX.11
TRACKER_IP=$SUBNET_PREFIX.12
SERVER_IP=$SUBNET_PREFIX.20
SERVER2_IP=$SUBNET_PREFIX.21
# Another server of the same VPN account (its own key), for failover.
FAILOVER_IP=$SUBNET_PREFIX.22
POD_IP=$SUBNET_PREFIX.30
CLIENT_IP=$SUBNET_PREFIX.40
SUBNET6_PREFIX=fd31:$NET_ID:
GW6=$SUBNET6_PREFIX:1
CANARY_IP6=$SUBNET6_PREFIX:10
DNS_CANARY_IP6=$SUBNET6_PREFIX:11
TRACKER_IP6=$SUBNET6_PREFIX:12
SERVER_IP6=$SUBNET6_PREFIX:20
FAILOVER_IP6=$SUBNET6_PREFIX:22
POD_IP6=$SUBNET6_PREFIX:30
CLIENT_IP6=$SUBNET6_PREFIX:40
TUN_SERVER=10.99.0.1
TUN_CLIENT=10.99.0.2
TUN_SERVER6=fd99::1
TUN_CLIENT6=fd99::2
# A test-only key pair: the failover server's.
FAILOVER_KEY=kEcjsuwvTe+shMpTw1JzQXLXQ8HFsKLsJ+dyvN3fYlQ=
FAILOVER_PUB=8FXIJVRVW8zPb1gsAdwNGtpEvVCwK3mw8X1D75+7ilg=
WEB_PORT=9091
PEER_PORT=51413
# Built by setup_suite, read by the tests: wg0.conf, settings.json, tunnel.env.
# The canary's link-local address, exported by setup_suite.
CANARY_LL=${CANARY_LL:-}
STAGE=${BATS_SUITE_TMPDIR:-/nonexistent}/stage
WG_CONF=$STAGE/wg/config/wg_confs/wg0.conf

CONTAINERS=("$P-tx" "$P-l4" "$P-l6" "$P-wg" "$P-pod" "$P-server" "$P-server2" "$P-failover" "$P-canary" "$P-dns" "$P-tracker" "$P-pre")

firewall_env=(
  -e "TWG_WEB_PORT=$WEB_PORT"
  -e "TWG_PEER_PORT=$PEER_PORT"
  -e "TWG_WEB_ALLOWED_CIDRS=$SUBNET_PREFIX.0/24 fc00::/7"
  -e TWG_HANDSHAKE_MAX_AGE=180
  # 30 s, the least firewall.sh allows (the chart: 180), so 19-failover is quick.
  -e "TWG_FAILOVER_PEERS=$FAILOVER_PUB@$FAILOVER_IP:51820"
  -e TWG_FAILOVER_AFTER=30
)

# A failed check: the message goes with the test's output.
fail() {
  printf '%s\n' "$*" >&2
  return 1
}

# Runs $2... until it succeeds or $1 seconds have passed, quietly.
poll() {
  local end=$((SECONDS + $1)); shift
  until "$@" >/dev/null 2>&1; do
    ((SECONDS < end)) || return 1
    sleep 1
  done
}
# The same, but says what it gave up on.
wait_until() {
  poll "$@" || { echo "timed out after ${1}s waiting for: ${*:2}" >&2; return 1; }
}

running() { [[ $(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }

# An unprivileged process in the pod, like Transmission: no capabilities, so
# it cannot set socket marks or touch the firewall.
as_app() { docker run --rm --network "container:$P-pod" --cap-drop ALL --user 1000:1000 --entrypoint "" "$WG_IMAGE" "$@"; }
# Root with NET_ADMIN in the pod and the sidecar's files, like a probe.
as_root() { docker run --rm --network "container:$P-pod" --privileged --volumes-from "$P-wg" "${firewall_env[@]}" --entrypoint "" "$WG_IMAGE" "$@"; }
on_server() { docker run --rm --network "container:$P-server" --entrypoint "" "$WG_IMAGE" "$@"; }
from_cluster() { docker run --rm --network "$NET" --ip "$CLIENT_IP" --ip6 "$CLIENT_IP6" --entrypoint "" "$WG_IMAGE" "$@"; }
wg_tool() { docker run --rm -i --entrypoint wg "$WG_IMAGE" "$@"; }
# transmission-remote against the daemon's RPC.
tx_remote() { docker run --rm --network "container:$P-pod" --cap-drop ALL --entrypoint transmission-remote "$TX_IMAGE" "127.0.0.1:$WEB_PORT" "$@"; }
# Like as_app, but with a raw socket for ICMP: iptables still filters it.
as_raw() { docker run --rm --network "container:$P-pod" --cap-drop ALL --cap-add NET_RAW --entrypoint "" "$WG_IMAGE" "$@"; }
# The chart's liveness probe of the Transmission container.
tx_live() { docker exec "$P-tx" /bin/sh /twg/scripts/transmission-live.sh; }
# True only if probe $@ says no (exit 1): one that could not run (docker's
# 125-127, a stopped container) proves nothing either way.
probe_fails() {
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  ((rc == 1)) && return 0
  ((rc == 0)) || echo "the probe could not run (exit $rc): $*" >&2
  return 1
}
tx_listening() { as_app nc -z 127.0.0.1 "$WEB_PORT"; }

# Source address the canary saw for a request from the pod (empty if blocked).
# Arguments go to curl, before the canary's URL.
fetch_seen() {
  as_app curl -sS -m 3 "$@" 2>/dev/null |
    sed -n 's/^RemoteAddr: \[\{0,1\}\([^]]*\)\]\{0,1\}:[0-9]*\r\{0,1\}$/\1/p' || true
}
# shellcheck disable=SC2120 # setup_suite's baseline passes curl options
canary_seen() { fetch_seen "$@" "http://$CANARY_IP/"; }
# shellcheck disable=SC2120
canary_seen6() { fetch_seen -6 "$@" "http://[$CANARY_IP6]/"; }
canary_ll_seen() { fetch_seen -g "http://[$CANARY_LL%25eth0]/"; }
via_vpn() { [[ $(canary_seen) == "$SERVER_IP" && $(canary_seen6) == "$SERVER_IP6" ]]; }
via_vpn4() { [[ $(canary_seen) == "$SERVER_IP" ]]; }
# Where a request to the canary went: "vpn", "blocked" (refused, timed out,
# or cut off mid-way), "leak <address>", or "broken <curl exit>" when the
# probe itself failed and so proves nothing. Arguments go to curl.
egress() {
  local rc out seen
  # An answer must name an address; an empty one (the docker client can
  # lose a container's output) is retried, then counts as broken.
  for _ in 1 2; do
    rc=0
    out=$(as_app curl -sS -m 3 "$@" 2>/dev/null) || rc=$?
    [[ $rc != 0 || -n $out ]] && break
  done
  [[ $rc != 0 || -n $out ]] || { echo "broken empty-answer"; return; }
  seen=$(sed -n 's/^RemoteAddr: \[\{0,1\}\([^]]*\)\]\{0,1\}:[0-9]*\r\{0,1\}$/\1/p' <<<"$out")
  case $rc in
    0) if [[ $seen == "$SERVER_IP" || $seen == "$SERVER_IP6" ]]; then echo vpn; else echo "leak ${seen:-unknown}"; fi ;;
    7 | 28 | 52 | 56) echo blocked ;;
    *) echo "broken $rc" ;;
  esac
}
egress4() { egress "$@" "http://$CANARY_IP/"; }
egress6() { egress -6 "$@" "http://[$CANARY_IP6]/"; }
# A request bound to eth0 must be refused (curl exit 7) or time out (28).
# "if!" makes curl fail instead of falling back to binding eth0's address
# (which would send the request into the tunnel and prove nothing).
ETH0=(--interface 'if!eth0')

# Probe results ($2...) recorded in file $1 while traffic must not leak;
# result_summary then fails on leaks, probes that could not run, too few
# probes, and (with need-blocked as $3) probes that never hit the outage.
record() {
  local file=$1; shift
  printf '%s\n' "$@" >>"$file"
}
result_summary() {
  local file=$1 what=$2 leaked broken probes blocked
  [[ -f $file ]] || : >"$file"
  leaked=$(sed -n 's/^leak //p' "$file" 2>/dev/null | tr '\n' ' ')
  broken=$(sed -n 's/^broken //p' "$file" 2>/dev/null | tr '\n' ' ')
  probes=$(grep -c . "$file" 2>/dev/null || true)
  blocked=$(grep -cx blocked "$file" 2>/dev/null || true)
  if [[ -n $leaked ]]; then
    fail "LEAK $what (canary saw $leaked)"
  elif [[ -n $broken ]]; then
    fail "probes $what could not run (curl exit $broken), so they prove nothing"
  elif ((probes < 2)); then
    fail "only $probes probe(s) ran $what, which proves nothing"
  elif [[ ${3:-} == need-blocked ]] && ((blocked == 0)); then
    fail "none of the $probes probes $what hit the outage, so they prove nothing"
  fi
  echo "$probes probes, $blocked blocked"
}

# The canary must not answer: the probe ($@, an egress call) is blocked.
expect_blocked() {
  local r
  r=$("$@")
  case $r in
    blocked) ;;
    leak*) fail "LEAK: $BATS_TEST_DESCRIPTION is not true (canary saw ${r#leak })" ;;
    *) fail "$BATS_TEST_DESCRIPTION: probe result '$r' proves nothing" ;;
  esac
}
# ping's verdict: "reached", "blocked" (no reply) or "broken <exit>".
icmp() {
  local rc=0
  as_raw ping -c1 -W2 "$@" >/dev/null 2>&1 || rc=$?
  case $rc in
    0) echo reached ;;
    1) echo blocked ;;
    *) echo "broken $rc" ;;
  esac
}
expect_icmp_blocked() {
  local r
  r=$(icmp "$@")
  case $r in
    blocked) ;;
    reached) fail "LEAK: $BATS_TEST_DESCRIPTION is not true (got a reply)" ;;
    *) fail "$BATS_TEST_DESCRIPTION: ping result '$r' proves nothing" ;;
  esac
}
# nc -z's verdict: "open", "closed" or "broken <exit>" (docker failed).
nc_result() {
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  case $rc in
    0) echo open ;;
    1) echo closed ;;
    *) echo "broken $rc" ;;
  esac
}
# Any failure but refused (7) or timed out (28) proves nothing.
check_eth0() {
  local rc=0
  as_app curl -sS -m 3 -o /dev/null "${ETH0[@]}" "$@" >/dev/null 2>&1 || rc=$?
  case $rc in
    7 | 28) ;;
    0) fail "LEAK: a socket bound to eth0 reached $*" ;;
    *) fail "eth0 check for $* proves nothing (curl exit $rc)" ;;
  esac
}

# Send DNS-port datagrams tagged $1 over IPv${2:-4} and print the source the
# canary saw. Five, a second apart: the listener restarts after each sender.
# (Each listener binds its own address, so IPv4 and IPv6 do not race for
# one dual-stack socket.)
# A port other than 53 ($3) stands in for DHT and other UDP traffic.
dns_seen() {
  local tag=$1 fam=${2:-4} port=${3:-53} ip=$DNS_CANARY_IP rc=0
  [[ $fam == 4 ]] || ip=$DNS_CANARY_IP6
  as_app sh -c "for i in 1 2 3 4 5; do echo $tag | nc -$fam -u -w1 $ip $port; done" >/dev/null 2>&1 || rc=$?
  # 125-127: docker or the shell failed, so nothing was sent.
  ((rc < 125)) || { echo "probe-broken"; return; }
  # Not a wait for a condition: the last datagram, leaked or not, must have
  # time to reach the canary's log before it is read.
  sleep 1
  # Every source that sent the tag, not just the last: one leaked datagram
  # among tunnelled ones must not pass.
  docker logs "$P-dns" 2>&1 | grep -B1 -x "$tag" | sed -n 's/^Connection received on \(::ffff:\)\{0,1\}\([^ ]*\) .*/\2/p' |
    sort -u | paste -sd' ' - || true
}
# Positive checks get one retry (the listener restarts between senders). A
# leak would show up as another source, which no retry hides.
dns_seen_retry() {
  local seen
  seen=$(dns_seen "$1" "${@:3}")
  [[ -n $seen ]] || seen=$(dns_seen "$2" "${@:3}")
  echo "$seen"
}
# UDP to the DNS canary ($@ as for dns_seen) must not arrive at all.
expect_no_udp() {
  local seen
  seen=$(dns_seen "$@")
  case $seen in
    "") ;;
    probe-broken) fail "$BATS_TEST_DESCRIPTION: the UDP probe could not run, so it proves nothing" ;;
    *) fail "LEAK: $BATS_TEST_DESCRIPTION is not true (canary saw $seen)" ;;
  esac
}

# Sensors that count leaked packets (installed by setup_suite): the
# canaries, the VPN server and the pod's eth0. sensor_counts prints
# "<sensor> <family> <packets>" lines for comment $1 (default twg-count),
# from the containers named after it (default: every sensor).
COUNTED=("$P-canary" "$P-dns" "$P-tracker" "$P-server" "$P-pod")
sensor_counts() {
  local c out tag=${1:-twg-count} list=("${@:2}")
  ((${#list[@]})) || list=("${COUNTED[@]}")
  for c in "${list[@]}"; do
    out=""
    # The docker client can lose a container's output; END proves it did not.
    for _ in 1 2 3; do
      out=$(docker run --rm --network "container:$c" --cap-add NET_ADMIN --entrypoint "" "$WG_IMAGE" \
        sh -c 'iptables-save -c && echo V6 && ip6tables-save -c && echo END' 2>/dev/null || true)
      [[ $out == *END* ]] && break
    done
    [[ $out == *END* ]] || { echo unreadable; return; }
    awk -v c="$c" -v tag="$tag" '/^V6$/ { fam = 6 } !fam { fam = 4 }
      $0 ~ ("--comment \"?" tag "\"?( |$)") && match($0, /^\[[0-9]+:/) { n[fam] += substr($0, 2, RLENGTH - 2) }
      END { print c, 4, n[4] + 0; print c, 6, n[6] + 0 }' <<<"$out"
  done
}
pod_hits() {
  local out
  out=$(sensor_counts "$@")
  if [[ $out == *unreadable* ]]; then echo unreadable; else awk '{ t += $3 } END { print t + 0 }' <<<"$out"; fi
}
# Connection attempts to the tracker so far.
tracker_attempts() { pod_hits twg-attempt "$P-pod"; }
# hits_mark takes a reading into file $1 (default: this test file's);
# hits_check fails if the sensors counted anything since.
hits_mark() { pod_hits >"${1:-$BATS_FILE_TMPDIR/hits}"; }
hits_check() {
  local what=$1 file=${2:-$BATS_FILE_TMPDIR/hits} was now
  was=$(cat "$file" 2>/dev/null || echo unreadable)
  now=$(pod_hits)
  if [[ $was == unreadable || $now == unreadable ]]; then
    fail "could not read the canaries' packet counters $what"
  elif ((now > was)); then
    fail "LEAK: $((now - was)) packet(s) outside the tunnel reached the canaries, the server or left eth0 $what"
  fi
}

# "[::ffff:a.b.c.d]:port: url:/cgi-bin/announce..." -> a.b.c.d
announces() {
  docker logs "$P-tracker" 2>&1 | sed -n 's|^\[\(::ffff:\)\{0,1\}\([^]]*\)\]:[0-9]*: url:/cgi-bin/announce.*|\2|p'
}
announce_count() { announces | wc -l; }
announces_via_vpn() {
  local a
  for a in $(announces | sort -u); do
    [[ $a == "$SERVER_IP" || $a == "$SERVER_IP6" ]] || return 1
  done
}
# More announces than $1 so far, and every one through the VPN.
announced_since() { (($(announce_count) > $1)) && announces_via_vpn; }
# Transmission backs off after failed announces (and may ignore a manual
# re-announce), but starting a torrent always announces.
reannounce() {
  tx_remote -t all --stop >/dev/null 2>&1 || true
  tx_remote -t all --start >/dev/null 2>&1 || true
}
# A new announce through the VPN (more than $1) within $2 seconds,
# restarting the torrent until one comes.
reannounced_since() {
  local end=$((SECONDS + $2))
  while ((SECONDS < end)); do
    reannounce
    poll 8 announced_since "$1" && return 0
  done
  echo "timed out after ${2}s waiting for an announce through the VPN" >&2
  return 1
}

stage_scripts() {
  mkdir -p "$1/twg/scripts"
  cp "$ROOT/files/settings-init.sh" "$ROOT/files/transmission-live.sh" "$1/twg/scripts/"
  cp "$FIREWALL_SH" "$1/twg/scripts/firewall.sh"
  chmod 0555 "$1"/twg/scripts/*
}
# settings-init in the Transmission image, like the chart's init container,
# for wg0.conf $1; writes settings.json and tunnel.env into $2. $3...: docker
# options (the RPC credentials).
run_settings_init() {
  local conf=$1 out=$2 dir
  dir=$(mktemp -d "$STAGE/settings.XXXXXX")
  mkdir -p "$dir/twg/settings" "$dir/twg/wg" "$dir/twg/run" "$out"
  stage_scripts "$dir"
  # Every discovery feature on (the chart turns UPnP/NAT-PMP and LPD off), so
  # Transmission tries as many paths as it can: the eth0 sensor sees them all.
  echo '{"rpc-port": 9091, "rpc-whitelist-enabled": false, "peer-port": 51413, "rpc-authentication-required": false,
    "port-forwarding-enabled": true, "lpd-enabled": true, "dht-enabled": true, "pex-enabled": true, "utp-enabled": true}' \
    >"$dir/twg/settings/settings.json"
  cp "$conf" "$dir/twg/wg/wg0.conf"
  docker rm -f "$P-pre" >/dev/null 2>&1 || true
  docker create --name "$P-pre" --network none "${@:3}" --entrypoint /bin/sh "$TX_IMAGE" /twg/scripts/settings-init.sh >/dev/null
  docker cp "$dir/." "$P-pre:/" >/dev/null
  docker start -a "$P-pre"
  docker cp "$P-pre:/twg/run/settings.json" "$out/settings.json"
  docker cp "$P-pre:/twg/run/tunnel.env" "$out/tunnel.env"
  docker rm -f "$P-pre" >/dev/null
}

# What the containers said, for a failure.
dump_logs() {
  local c
  for c in "$P-server" "$P-wg" "$P-tx"; do
    docker inspect "$c" >/dev/null 2>&1 || continue
    echo "  --- $c ($(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' "$c"))"
    docker logs --tail 40 "$c" 2>&1 | sed "s/^/  $c | /"
  done
}
# In a teardown: the logs go with a failed test's output.
dump_logs_if_failed() {
  [[ -n ${BATS_TEST_COMPLETED:-} || -n ${BATS_TEST_SKIPPED:-} ]] || dump_logs
}

# The state every test starts from: the tunnel up with the dual-stack
# wg0.conf, the kill switch intact, Transmission listening (and for peers on
# the tunnel), the IPv6 listener running.
tunnel_up() {
  as_root sh -c 'wg show wg0 >/dev/null && ip -o addr show dev wg0 | grep -q . &&
    ip -4 rule show | grep -q "not from all fwmark 0xca6c lookup"'
}
# A firewall.sh that fails its own check even freshly applied (a mutant) is
# what "startup/readiness/liveness probes pass" reports; restarting cannot
# fix it. For it the rules as freshly applied stand in for the check: any
# rule a test changed since still counts as broken, and is restored.
CHECK_BROKEN=$STAGE/check-broken
# Every iptables and ip6tables rule and chain policy, without counters.
all_rules() {
  as_root sh -c 'iptables-save; ip6tables-save' | grep -E '^[-:*]' | sed -E 's/ \[[0-9]+:[0-9]+\]$//'
}
kill_switch_intact() {
  if [[ -e $CHECK_BROKEN ]]; then
    diff -q "$CHECK_BROKEN" <(all_rules) >/dev/null
  else
    as_root /twg/scripts/firewall.sh check
  fi
}
# Called with the kill switch freshly applied: a check that fails twice is
# the firewall.sh's, not a moment's.
note_if_check_broken() {
  as_root /twg/scripts/firewall.sh check >/dev/null 2>&1 && return 0
  sleep 2
  as_root /twg/scripts/firewall.sh check >/dev/null 2>&1 && return 0
  all_rules >"$CHECK_BROKEN"
}
healthy_but_check() {
  running "$P-wg" && running "$P-tx" && running "$P-l6" && tunnel_up && via_vpn && tx_listening && tx_live
}
healthy() { healthy_but_check && kill_switch_intact; }
# Brings a test's leftovers back to healthy (a restart re-applies the kill
# switch and the tunnel), and fails if it cannot. Tests clean up their own
# rules and routes; this is the net under them, so one failure does not
# cascade into the next file.
ensure_healthy() {
  healthy >/dev/null 2>&1 && return 0
  echo "# restoring the healthy environment" >&2
  running "$P-l6" || docker start "$P-l6" >/dev/null
  running "$P-tx" || docker start "$P-tx" >/dev/null
  # The image deletes the default routes when wg-quick fails.
  as_root sh -c "ip -4 route show default | grep -q . || ip route add default via $GW dev eth0
    ip -6 route show default | grep -q . || ip -6 route add default via $GW6 dev eth0"
  if ! { running "$P-wg" && tunnel_up >/dev/null 2>&1 && kill_switch_intact >/dev/null 2>&1 && via_vpn; }; then
    docker cp "$WG_CONF" "$P-wg:/config/wg_confs/wg0.conf" >/dev/null
    docker restart -t 10 "$P-wg" >/dev/null
    { poll 90 tunnel_up && poll 60 via_vpn; } || true
  fi
  if ! poll 120 tx_listening || ! tx_live >/dev/null 2>&1; then
    docker restart -t 20 "$P-tx" >/dev/null
    poll 120 tx_live || true
  fi
  healthy >/dev/null 2>&1 && return 0
  if healthy_but_check >/dev/null 2>&1; then
    # Not a failure here: "startup/readiness/liveness probes pass" and the
    # tests' own teardowns report it.
    echo "# the kill switch fails its own check even freshly applied ($(as_root /twg/scripts/firewall.sh check 2>&1 | tail -n1));" \
      "its rules as applied stand in for the check from now on" >&2
    note_if_check_broken
    return 0
  fi
  dump_logs >&2
  fail "could not restore a healthy environment (sidecar: $(as_root /twg/scripts/firewall.sh tunnel 2>&1 | tail -n1))"
}
