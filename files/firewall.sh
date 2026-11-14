#!/usr/bin/env bash
# Chart-managed kill switch for the pod network namespace.
#
# The rules live in the pod's network namespace, which outlives every
# container restart. They are installed before wg-quick runs and nothing in
# the tunnel lifecycle removes them, so a crashed, restarting or misconfigured
# tunnel fails closed instead of falling back to eth0.
#
# Usage: firewall.sh apply   install rules, then validate the tunnel config
#        firewall.sh check   exit non-zero if the rules are missing or altered
#        firewall.sh tunnel  check + the WireGuard interface is up
#        firewall.sh live    tunnel + latest handshake is recent (if configured);
#                            with failover peers, switches to the next one
#                            when the current one stopped answering
#                            with a NAT-PMP gateway, renews the forwarded port;
#                            logs the peers' state every 5 minutes, and why
#                            when it fails
set -euo pipefail

WG_IFACE="${TWG_WG_IFACE:-wg0}"
WG_FWMARK="${TWG_WG_FWMARK:-51820}"
LOCAL_MARK="${TWG_LOCAL_MARK:-0x10000000}"
WEB_PORT="${TWG_WEB_PORT:-9091}"
PEER_PORT="${TWG_PEER_PORT:-51413}"
WEB_CIDRS="${TWG_WEB_ALLOWED_CIDRS:-}"
SAVED_ROUTE_TABLE="${TWG_SAVED_ROUTE_TABLE:-1000}"
HANDSHAKE_MAX_AGE="${TWG_HANDSHAKE_MAX_AGE:-0}"
ALLOW_CONF_HOOKS="${TWG_ALLOW_CONF_HOOKS:-false}"
CONF="${TWG_WG_CONF:-/config/wg_confs/${WG_IFACE}.conf}"
# The addresses Transmission is bound to, written by the init container.
TUNNEL_ENV="${TWG_TUNNEL_ENV:-/twg/run/tunnel.env}"
# Other servers of the same VPN account, as "publickey@ip:port" words: when
# the current peer has not answered for FAILOVER_AFTER seconds, live()
# switches to the next. The firewall lets UDP through to all of them.
FAILOVER_PEERS="${TWG_FAILOVER_PEERS:-}"
FAILOVER_AFTER="${TWG_FAILOVER_AFTER:-0}"
# "publickey since switched": the current peer, since when it is watched,
# and 1 if fail_over set it. In the container (exec probes run there), so a
# restart, which re-reads wg0.conf, starts over.
FAILOVER_STATE="${TWG_FAILOVER_STATE:-/run/twg-failover}"
# VPN port forwarding: the NAT-PMP gateway inside the tunnel (empty: off).
# live() renews the mapping, opens only that port on wg0 (in FWD, which
# check() lets hold nothing else), writes it to FORWARD_DIR/port and sets
# it as Transmission's peer port over RPC, with the credentials in RPC_DIR
# if the web UI needs them.
NATPMP_GATEWAY="${TWG_NATPMP_GATEWAY:-}"
FORWARD_DIR="${TWG_FORWARD_DIR:-/twg/forward}"
RPC_DIR="${TWG_RPC_DIR:-/twg/rpc}"
# A probe's output reaches kubectl only as an event, and only when it fails.
# live also writes to the container's log (PID 1's stdout), so kubectl logs
# --previous has it after a restart, and the reason it failed to the
# termination message, which kubectl describe pod shows under Last State.
MODE="${1:-}"
CONTAINER_LOG="${TWG_CONTAINER_LOG:-/proc/1/fd/1}"
TERMINATION_LOG="${TWG_TERMINATION_LOG:-/dev/termination-log}"
# When live last logged the peers' state, and how often it does.
STATUS_STATE="${TWG_STATUS_STATE:-/run/twg-status}"
STATUS_EVERY="${TWG_STATUS_EVERY:-300}"
LIVE_LOG=()

IN=TWG-INPUT
OUT=TWG-OUTPUT
PRE=TWG-PREROUTING
MOUT=TWG-MANGLE-OUTPUT
POST=TWG-POSTROUTING
FWD=TWG-FORWARDED

log() {
  echo "[twg-firewall] $*" >&2
  if [[ $MODE == live ]]; then
    LIVE_LOG+=("[twg-firewall] $*")
    echo "[twg-firewall] $*" >>"$CONTAINER_LOG" 2>/dev/null || true
  fi
}
die() { log "FATAL: $*"; exit 1; }

# Settings the rules cannot be built safely from. apply first closes every
# family (policies DROP), so the pod still fails closed.
refuse_setting() {
  local ipt c
  if [[ ${1:-} == apply ]]; then
    for ipt in iptables ip6tables; do
      for c in INPUT FORWARD OUTPUT; do "$ipt" -w -P "$c" DROP 2>/dev/null || true; done
    done
  fi
  die "$2"
}
# Mark 0 would match every unmarked packet and table 0 every routing rule.
if ! [[ $WG_FWMARK =~ ^(0[xX][0-9a-fA-F]{1,8}|[1-9][0-9]{0,9})$ ]] || ((WG_FWMARK > 0xffffffff)); then
  refuse_setting "${1:-}" "firewall.wgFwmark ${WG_FWMARK} must be between 1 and 4294967295"
fi
# A zero mask would match every connection; shared bits would confuse the two.
if ! [[ $LOCAL_MARK =~ ^(0[xX][0-9a-fA-F]{1,8}|[1-9][0-9]{0,9})$ ]] || ((LOCAL_MARK > 0xffffffff || (LOCAL_MARK & WG_FWMARK) != 0)); then
  refuse_setting "${1:-}" "TWG_LOCAL_MARK ${LOCAL_MARK} must be a non-zero 32-bit mark sharing no bits with ${WG_FWMARK}"
fi
# The mark is also wg-quick's routing table, which reset_netns flushes.
case $((WG_FWMARK)) in
  253 | 254 | 255 | $((SAVED_ROUTE_TABLE)))
    refuse_setting "${1:-}" "firewall.wgFwmark ${WG_FWMARK} is also wg-quick's routing table and must not be 253-255 (system tables) or ${SAVED_ROUTE_TABLE} (the saved route)" ;;
esac
[[ $PEER_PORT != "$WEB_PORT" ]] || refuse_setting "${1:-}" "the peer port ${PEER_PORT} must differ from the web port"
# Without nft, wg-quick falls back to iptables rules check cannot tell from
# tampering, and dup/fwd statements could not be seen.
command -v nft >/dev/null 2>&1 || refuse_setting "${1:-}" "nft is missing from the WireGuard image"

# IPv6 must be filtered whenever the namespace has it; only skip ip6tables
# when there is no IPv6 at all.
detect_families() {
  FAMILIES=(4)
  if ip6tables -w -S >/dev/null 2>&1; then
    FAMILIES+=(6)
  elif grep -qv ' lo$' /proc/net/if_inet6 2>/dev/null; then
    refuse_setting "$1" "IPv6 is configured in the pod but ip6tables is unusable; refusing to run unfiltered"
  fi
}

ipt_for() { if [[ $1 == 4 ]]; then echo iptables; else echo ip6tables; fi; }

cidrs_for() {
  local fam=$1 cidr
  for cidr in ${WEB_CIDRS//,/ }; do
    if [[ $fam == 4 && $cidr != *:* ]] || [[ $fam == 6 && $cidr == *:* ]]; then
      echo "$cidr"
    fi
  done
}

reset_chain() {
  local ipt=$1 table=$2 chain=$3 parent=$4
  "$ipt" -w -t "$table" -N "$chain" 2>/dev/null || "$ipt" -w -t "$table" -F "$chain"
  while "$ipt" -w -t "$table" -D "$parent" -j "$chain" 2>/dev/null; do :; done
  "$ipt" -w -t "$table" -I "$parent" 1 -j "$chain"
}

# Hash of a chain's rules, excluding its final (sealing) rule when asked.
chain_hash() {
  local ipt=$1 table=$2 chain=$3 drop_last=$4 dump
  dump=$("$ipt" -w -t "$table" -S "$chain" | sed 1d)
  [[ $drop_last == true ]] && dump=$(sed '$d' <<<"$dump")
  sha256sum <<<"$dump" | cut -c1-16
}

# The last rule of each chain carries a hash of the rules before it, so the
# probes notice any rule added, removed or changed inside the chain.
seal_chain() {
  local ipt=$1 table=$2 chain=$3; shift 3
  "$ipt" -w -t "$table" -A "$chain" -m comment --comment "twg:$(chain_hash "$ipt" "$table" "$chain" false)" "$@"
}

apply_family() {
  local fam=$1 ipt cidr host port f
  ipt=$(ipt_for "$fam")

  "$ipt" -w -P INPUT DROP
  "$ipt" -w -P FORWARD DROP
  "$ipt" -w -P OUTPUT DROP
  reset_chain "$ipt" filter "$IN" INPUT
  reset_chain "$ipt" filter "$OUT" OUTPUT

  # Inbound: replies, BitTorrent peers via the tunnel, and the web UI from
  # cluster-local sources only. RPC is never reachable through the tunnel.
  # IPv6 neighbour discovery comes before the INVALID drop because some
  # kernels classify it as INVALID. Hop limit 255 means it came from the link.
  local t
  "$ipt" -w -A "$IN" -i lo -j ACCEPT
  if [[ $fam == 6 ]]; then
    for t in router-advertisement neighbour-solicitation neighbour-advertisement; do
      "$ipt" -w -A "$IN" ! -i "$WG_IFACE" -p ipv6-icmp --icmpv6-type "$t" -m hl --hl-eq 255 -j ACCEPT
    done
  fi
  "$ipt" -w -A "$IN" -m conntrack --ctstate INVALID -j DROP
  "$ipt" -w -A "$IN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  "$ipt" -w -A "$IN" -i "$WG_IFACE" -p tcp --dport "$PEER_PORT" -j ACCEPT
  "$ipt" -w -A "$IN" -i "$WG_IFACE" -p udp --dport "$PEER_PORT" -j ACCEPT
  # The port the VPN forwards (NAT-PMP is IPv4 only), from the tunnel only.
  if [[ $fam == 4 && -n $NATPMP_GATEWAY ]]; then
    "$ipt" -w -N "$FWD" 2>/dev/null || "$ipt" -w -F "$FWD"
    "$ipt" -w -A "$IN" -i "$WG_IFACE" -j "$FWD"
  fi
  while read -r cidr; do
    [[ -n $cidr ]] || continue
    # The connmark (set in mangle PREROUTING) routes the replies back out
    # eth0; without it they would follow the tunnel table into wg0.
    "$ipt" -w -A "$IN" ! -i "$WG_IFACE" -s "$cidr" -p tcp --dport "$WEB_PORT" -m connmark --mark "$LOCAL_MARK/$LOCAL_MARK" -j ACCEPT
  done < <(cidrs_for "$fam")
  seal_chain "$ipt" filter "$IN" -j DROP

  # Outbound: only the tunnel, WireGuard's own encrypted packets (identified
  # by the fwmark wg-quick sets on its socket; unprivileged processes cannot
  # set marks) and the web UI's replies to the sources allowed above.
  # The mark alone is not enough: anything that marks packets (a stray mangle
  # rule, CAP_NET_RAW's SO_MARK) could then reach any host via eth0. So marked
  # packets only pass as UDP to the configured endpoints, and a server that
  # roams to another address fails closed.
  "$ipt" -w -A "$OUT" -o lo -j ACCEPT
  if [[ $fam == 6 ]]; then
    for t in router-solicitation neighbour-solicitation neighbour-advertisement; do
      "$ipt" -w -A "$OUT" ! -o "$WG_IFACE" -p ipv6-icmp --icmpv6-type "$t" -m hl --hl-eq 255 -j ACCEPT
    done
  fi
  "$ipt" -w -A "$OUT" -m conntrack --ctstate INVALID -j DROP
  # Replies to cluster callers must carry WireGuard's fwmark, which routes
  # them out eth0. Without it (for a moment while the mangle rules below are
  # re-applied) they would be routed into the tunnel, so reject them. This
  # cannot use -o: in OUTPUT it names the interface chosen before the mangle
  # mark re-routed the packet.
  "$ipt" -w -A "$OUT" -m connmark --mark "$LOCAL_MARK/$LOCAL_MARK" -m mark ! --mark "$WG_FWMARK" -j REJECT
  # -o is again the pre-mangle choice, so a packet a mangle rule marked
  # (and re-routed out eth0) still shows wg0 here. Only unmarked packets
  # really take the tunnel.
  "$ipt" -w -A "$OUT" -o "$WG_IFACE" -m mark --mark 0 -j ACCEPT
  while read -r host port; do
    "$ipt" -w -A "$OUT" -m mark --mark "$WG_FWMARK" -p udp -d "$host" --dport "$port" -j ACCEPT
  done < <(endpoints "$fam")
  local_replies "$ipt" filter "$OUT" ACCEPT "$fam"
  seal_chain "$ipt" filter "$OUT" -j REJECT

  # Connections that arrive outside the tunnel (kubelet probes, ingress) get
  # a connmark, and their packets carry WireGuard's fwmark. wg-quick's policy
  # rules exempt that mark from the tunnel table, so replies route back out
  # eth0 instead of into wg0. The filter rules above still decide what is
  # allowed; the mark is never set on connections opened from inside the pod.
  reset_chain "$ipt" mangle "$PRE" PREROUTING
  reset_chain "$ipt" mangle "$MOUT" OUTPUT
  "$ipt" -w -t mangle -A "$PRE" -i lo -j RETURN
  "$ipt" -w -t mangle -A "$PRE" -i "$WG_IFACE" -j RETURN
  "$ipt" -w -t mangle -A "$PRE" -m conntrack --ctstate NEW -j CONNMARK --set-xmark "$LOCAL_MARK/$LOCAL_MARK"
  "$ipt" -w -t mangle -A "$PRE" -m connmark --mark "$LOCAL_MARK/$LOCAL_MARK" -j MARK --set-mark "$WG_FWMARK"
  "$ipt" -w -t mangle -A "$MOUT" -m connmark --mark "$LOCAL_MARK/$LOCAL_MARK" -j MARK --set-mark "$WG_FWMARK"
  seal_chain "$ipt" mangle "$PRE" -j RETURN
  seal_chain "$ipt" mangle "$MOUT" -j RETURN

  # The final say. Filter OUTPUT sees the route chosen before mangle marks
  # or nat rewrites re-route a packet; POSTROUTING sees the interface it
  # really leaves on. Same allowances as filter OUTPUT, everything else is
  # dropped, whatever other tables or nft chains did to it.
  reset_chain "$ipt" mangle "$POST" POSTROUTING
  "$ipt" -w -t mangle -A "$POST" -o lo -j RETURN
  if [[ $fam == 6 ]]; then
    for t in router-solicitation neighbour-solicitation neighbour-advertisement; do
      "$ipt" -w -t mangle -A "$POST" ! -o "$WG_IFACE" -p ipv6-icmp --icmpv6-type "$t" -m hl --hl-eq 255 -j RETURN
    done
  fi
  "$ipt" -w -t mangle -A "$POST" -o "$WG_IFACE" -m mark --mark 0 -j RETURN
  while read -r host port; do
    "$ipt" -w -t mangle -A "$POST" -m mark --mark "$WG_FWMARK" -p udp -d "$host" --dport "$port" -j RETURN
  done < <(endpoints "$fam")
  local_replies "$ipt" mangle "$POST" RETURN "$fam"
  seal_chain "$ipt" mangle "$POST" -j DROP

  # Router advertisements may set the default route, but not add on-link
  # prefixes or routes: those beat the tunnel's /0 and would take IPv6 down.
  # Without privileged, /proc/sys is read-only: say so, as nothing else would.
  if [[ $fam == 6 ]]; then
    local ra_failed=0
    for f in /proc/sys/net/ipv6/conf/*/accept_ra_pinfo /proc/sys/net/ipv6/conf/*/accept_ra_rt_info_max_plen; do
      [[ $f == */"$WG_IFACE"/* ]] || echo 0 2>/dev/null >"$f" || ra_failed=1
    done
    ((ra_failed == 0)) || log "WARNING: /proc/sys is read-only, so router advertisements can still add IPv6 routes past the tunnel (nothing leaks, but IPv6 stops working). Set net.ipv6.conf.eth0.accept_ra_pinfo=0 and net.ipv6.conf.eth0.accept_ra_rt_info_max_plen=0 in podSecurityContext.sysctls."
  fi
}

# Replies on connections that arrived from the cluster and were let in by the
# web UI rule. The connmark alone is not enough: anything that sets it on
# another connection (a stray CONNMARK rule, conntrack -U) would then let that
# connection out eth0. Only the reply direction, from the web port, to the
# allowed sources may pass. (No ICMP errors: the pod is an endpoint, not a
# router, so it sends none about these connections.)
local_replies() {
  local ipt=$1 table=$2 chain=$3 target=$4 fam=$5 cidr
  while read -r cidr; do
    [[ -n $cidr ]] || continue
    "$ipt" -w -t "$table" -A "$chain" -d "$cidr" -p tcp --sport "$WEB_PORT" -m connmark --mark "$LOCAL_MARK/$LOCAL_MARK" \
      -m conntrack --ctstate ESTABLISHED --ctdir REPLY -j "$target"
  done < <(cidrs_for "$fam")
}

# "via X dev Y [onlink] [mtu N]" from `ip route show default` on stdin. The
# raw line cannot be replayed: RA-learned IPv6 routes carry "expires", and
# multipath routes put the gateway on nexthop lines.
default_route_args() {
  local tok prev="" via="" dev="" onlink="" mtu=""
  # shellcheck disable=SC2013
  for tok in $(cat); do
    case $prev in
      via) [[ -n $via ]] || via=$tok ;;
      dev) [[ -n $dev ]] || dev=$tok ;;
      mtu) [[ $tok == lock ]] || mtu=$tok ;;
    esac
    [[ $tok == onlink ]] && onlink=onlink
    prev=$tok
  done
  [[ -n $dev ]] || return 0
  echo "${via:+via $via }dev $dev${onlink:+ onlink}${mtu:+ mtu $mtu}"
}

# Recover the namespace from a previous container run. A SIGKILLed tunnel
# leaves wg0, wg-quick's policy rules and its nft table behind (wg-quick up
# then fails or picks another table and fwmark), and the image deletes the
# default route when wg-quick fails, which would leave WireGuard unable to
# reach its endpoint forever. The route is kept in a spare table, which lives
# in the namespace like everything else.
reset_netns() {
  local fam route f table=$((WG_FWMARK))
  ip link del "$WG_IFACE" 2>/dev/null || true
  if command -v nft >/dev/null 2>&1; then
    for f in ip ip6; do nft delete table "$f" "wg-quick-$WG_IFACE" 2>/dev/null || true; done
  fi
  for fam in "${FAMILIES[@]}"; do
    while ip -"$fam" rule del table "$table" 2>/dev/null; do :; done
    while ip -"$fam" rule del table main suppress_prefixlength 0 2>/dev/null; do :; done
    ip -"$fam" route flush table "$table" 2>/dev/null || true

    route=$(ip -"$fam" route show default 2>/dev/null | default_route_args || true)
    if [[ -n $route ]]; then
      # shellcheck disable=SC2086
      ip -"$fam" route replace default $route table "$SAVED_ROUTE_TABLE"
    else
      route=$(ip -"$fam" route show default table "$SAVED_ROUTE_TABLE" 2>/dev/null | default_route_args || true)
      if [[ -n $route ]]; then
        log "restoring IPv$fam default route: $route"
        # shellcheck disable=SC2086
        ip -"$fam" route add default $route
      fi
    fi
  done
}

is_ip() {
  [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [[ $1 == *:* && $1 =~ ^[0-9A-Fa-f:.]+$ ]]
}

conf_value() {
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^#]*[^#[:space:]]).*/\\1/Ip" "$CONF"
}

# Splits an Endpoint value into EP_HOST and EP_PORT, or prints why it is unusable.
split_endpoint() {
  local ep=$1
  EP_PORT=0
  [[ $ep =~ :([0-9]{1,5})$ ]] && EP_PORT=$((10#${BASH_REMATCH[1]}))
  ((EP_PORT >= 1 && EP_PORT <= 65535)) || { echo "Endpoint ${ep} needs a port between 1 and 65535"; return 1; }
  if [[ $ep == \[* ]]; then EP_HOST=${ep#[}; EP_HOST=${EP_HOST%%]*}; else EP_HOST=${ep%:*}; fi
  is_ip "$EP_HOST" || { echo "Endpoint ${ep} is not an IP address. DNS is blocked until the tunnel is up, so the endpoint must be a literal IP."; return 1; }
}

# "host port" of every usable Endpoint of IP family $1, failover peers'
# included.
endpoints() {
  local ep
  [[ -r $CONF ]] || return 0
  while read -r ep; do
    split_endpoint "$ep" >/dev/null || continue
    if [[ $1 == 4 && $EP_HOST != *:* ]] || [[ $1 == 6 && $EP_HOST == *:* ]]; then
      echo "$EP_HOST $EP_PORT"
    fi
  done < <(conf_value Endpoint; failover_peers | sed 's/^[^@]*@//')
}

# The failover peers, one "publickey@endpoint" per line.
failover_peers() {
  local p
  for p in $FAILOVER_PEERS; do echo "$p"; done
}

# Reject configs that would weaken or bypass the kill switch.
preflight() {
  local ep fwmark table f allowed addrs err host route mtu
  [[ -r $CONF ]] || die "WireGuard config ${CONF} not found"

  # The image brings up every *.conf it finds; only wg0 is validated.
  for f in "$(dirname "$CONF")"/*.conf; do
    [[ ! -e $f || $f == "$CONF" ]] || die "unexpected WireGuard config ${f}: only ${CONF} is allowed (the Secret must hold just wg0.conf)"
  done

  # Hooks run as root with NET_ADMIN. Any of them (directly or through a
  # script) can open the kill switch, e.g. by marking packets so they leave
  # via eth0, so none run unless explicitly allowed.
  if [[ $ALLOW_CONF_HOOKS != true ]] &&
    grep -Eiq '^[[:space:]]*(PreUp|PostUp|PreDown|PostDown)[[:space:]]*=' "$CONF"; then
    die "${CONF} has PreUp/PostUp/PreDown/PostDown hooks. The chart manages the kill switch; remove them or set firewall.allowConfHooks (a PreDown that flushes OUTPUT would open the firewall on every tunnel restart)."
  fi

  while read -r ep; do
    [[ -n $ep ]] || continue
    err=$(split_endpoint "$ep") || die "$err"
  done < <(conf_value Endpoint)

  if [[ -n $FAILOVER_PEERS ]]; then
    if ! [[ $FAILOVER_AFTER =~ ^[0-9]+$ ]] || ((FAILOVER_AFTER < 30)); then
      die "wireguard.failover.afterSeconds ${FAILOVER_AFTER} must be at least 30"
    fi
    (($(grep -ciE '^[[:space:]]*\[Peer\]' "$CONF") == 1)) || die "wireguard.failover needs exactly one [Peer] in ${CONF}: it replaces that peer with the next one"
    ! grep -qiE '^[[:space:]]*PresharedKey[[:space:]]*=' "$CONF" || die "wireguard.failover cannot be used with a PresharedKey: the failover peers would need their own"
    keepalive_on || die "wireguard.failover needs PersistentKeepalive in ${CONF}: without it an idle tunnel stops handshaking and would look dead"
    while read -r ep; do
      [[ ${ep%%@*} =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$ ]] || die "wireguard.failover peer ${ep%%@*} is not a WireGuard public key"
      err=$(split_endpoint "${ep#*@}") || die "wireguard.failover: $err"
    done < <(failover_peers)
  fi
  if [[ -n $NATPMP_GATEWAY ]]; then
    [[ $NATPMP_GATEWAY =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "wireguard.portForwarding.natpmpGateway ${NATPMP_GATEWAY} must be an IPv4 address"
    for f in natpmpc curl timeout iptables-restore; do
      command -v "$f" >/dev/null || die "port forwarding needs ${f}, which this image lacks: use the chart's sidecar image (ghcr.io/czprz/twg-wireguard)"
    done
    [[ -d $FORWARD_DIR && -w $FORWARD_DIR ]] || die "port forwarding needs ${FORWARD_DIR} writable"
  fi

  # Captured first: grep -q exiting on the first match would SIGPIPE tr and,
  # with pipefail, randomly refuse a valid config.
  allowed=$(conf_value AllowedIPs | tr -s ',[:blank:]' '\n')
  # IPv6 into the tunnel (any IPv6 range, however written) without a tunnel
  # IPv6 address would carry the pod's own IPv6 address to the VPN.
  addrs=$(conf_value Address)
  if [[ $allowed == *:* && $addrs != *:* ]]; then
    die "AllowedIPs has IPv6 ranges but Address has no IPv6 address; add one (or drop the IPv6 ranges so IPv6 is blocked)"
  fi
  [[ $addrs =~ [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]] || die "Address has no IPv4 address; traffic into the tunnel would carry the pod's own IPv4 address to the VPN"
  grep -qx '0\.0\.0\.0/0' <<<"$allowed" || die "AllowedIPs must include 0.0.0.0/0 (full tunnel). Halves such as 0.0.0.0/1 + 128.0.0.0/1 do not work, because wg-quick only sets up the fwmark routing the kill switch relies on for /0"

  table=$(conf_value Table | tail -n1)
  if [[ -n $table && ${table,,} != auto ]]; then
    die "Table = ${table} turns off wg-quick's fwmark policy routing; remove it (all traffic would be rejected)"
  fi

  fwmark=$(conf_value FwMark | tail -n1)
  if [[ -z $fwmark ]] && ((WG_FWMARK != 51820)); then
    die "firewall.wgFwmark is ${WG_FWMARK} but ${CONF} has no FwMark line, so wg-quick would use 51820; add FwMark = ${WG_FWMARK}"
  fi
  if [[ -n $fwmark ]]; then
    if ! [[ $fwmark =~ ^(0[xX][0-9a-fA-F]+|[1-9][0-9]*)$ ]] || ((fwmark != WG_FWMARK)); then
      die "FwMark ${fwmark} in ${CONF} differs from firewall.wgFwmark (${WG_FWMARK})"
    fi
  fi

  # Without an MTU line wg-quick sizes the tunnel from the route to the
  # endpoint, less 80. On jumbo-frame networks (AWS VPC CNI: 9001) that is
  # far above the internet's 1500: the encrypted packets get fragmented on
  # the way, and many paths drop fragments. (Runs after reset_netns, so the
  # default route is back.)
  if [[ -z $(conf_value MTU) ]]; then
    while read -r host _; do
      route=$(ip route get "$host" 2>/dev/null) || continue
      if [[ $route =~ \ mtu\ ([0-9]+) ]]; then
        mtu=${BASH_REMATCH[1]}
      elif [[ $route =~ \ dev\ ([^ ]+) ]] && [[ -r /sys/class/net/${BASH_REMATCH[1]}/mtu ]]; then
        mtu=$(<"/sys/class/net/${BASH_REMATCH[1]}/mtu")
      else
        continue
      fi
      ((mtu <= 1500)) || die "the route to the endpoint ${host} has MTU ${mtu}, so wg-quick would give the tunnel $((mtu - 80)), more than the internet carries unfragmented. Add MTU = 1420 to [Interface] in ${CONF}"
    done < <(endpoints 4; endpoints 6)
  fi

  # Transmission's peer sockets were bound to the tunnel addresses when the
  # pod started. The Secret can change under a running pod and this
  # container reads it again when it restarts: a new Address would leave
  # Transmission bound to addresses that no longer exist.
  if [[ -r $TUNNEL_ENV ]]; then
    local a want4="" want6="" bound4 bound6
    for a in ${addrs//,/ }; do
      a=${a%%/*}
      if [[ $a =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        [[ -n $want4 ]] || want4=$a
      elif [[ $a == *:* ]]; then
        [[ -n $want6 ]] || want6=$a
      fi
    done
    bound4=$(sed -n 's/^TWG_BIND4=//p' "$TUNNEL_ENV")
    bound6=$(sed -n 's/^TWG_BIND6=//p' "$TUNNEL_ENV")
    if [[ $bound4 != "${want4:-127.0.0.1}" || $bound6 != "${want6:-::1}" ]]; then
      die "Address in ${CONF} changed since the pod started (Transmission is bound to ${bound4:-?} and ${bound6:-?}). Restart the pod: kubectl rollout restart deployment/<release>-transmission-wireguard"
    fi
  fi

  if ((HANDSHAKE_MAX_AGE > 0)) && ! keepalive_on; then
    log "handshake age check off: ${CONF} has no PersistentKeepalive, so an idle tunnel would stop handshaking"
  fi
}

# An idle tunnel only handshakes when PersistentKeepalive sends something.
keepalive_on() {
  local k
  k=$(conf_value PersistentKeepalive | tail -n1)
  [[ $k =~ ^[0-9]+$ ]] && ((10#$k > 0))
}

# Rule dumps are captured before matching: grep -q exiting early would SIGPIPE
# iptables and, with pipefail, turn a match into a failure.
check_family() {
  local fam=$1 ipt chain dump rules want spec table target
  ipt=$(ipt_for "$fam")
  for chain in INPUT FORWARD OUTPUT; do
    dump=$("$ipt" -w -S "$chain")
    [[ $'\n'$dump$'\n' == *$'\n'"-P $chain DROP"$'\n'* ]] || { log "IPv$fam $chain policy is not DROP"; return 1; }
    if [[ $chain != FORWARD ]]; then
      want="$IN"; [[ $chain == OUTPUT ]] && want="$OUT"
      [[ $(sed -n 2p <<<"$dump") == "-A $chain -j $want" ]] || { log "IPv$fam $chain does not jump to $want first"; return 1; }
    fi
  done
  # Nothing else may mark outgoing packets: a rule after the jump still runs.
  rules=$("$ipt" -w -t mangle -S OUTPUT)
  [[ $(sed 1d <<<"$rules") == "-A OUTPUT -j $MOUT" ]] || { log "IPv$fam mangle OUTPUT has rules besides the jump to $MOUT"; return 1; }
  rules=$("$ipt" -w -t mangle -S POSTROUTING)
  [[ $(sed -n 2p <<<"$rules") == "-A POSTROUTING -j $POST" ]] || { log "IPv$fam mangle POSTROUTING does not jump to $POST first"; return 1; }
  rules=$("$ipt" -w -t mangle -S PREROUTING)
  [[ $(sed -n 2p <<<"$rules") == "-A PREROUTING -j $PRE" ]] || { log "IPv$fam mangle PREROUTING does not jump to $PRE first"; return 1; }

  # The forwarded port's chain: empty, or that one port from the tunnel.
  if [[ $fam == 4 && -n $NATPMP_GATEWAY ]]; then
    rules=$("$ipt" -w -S "$FWD" 2>/dev/null) || { log "IPv4 $FWD is missing"; return 1; }
    rules=$(sed 1d <<<"$rules")
    if [[ -n $rules ]]; then
      local tcp="^-A $FWD -i $WG_IFACE -p tcp -m tcp --dport ([0-9]+) -j ACCEPT"$'\n'
      local udp="-A $FWD -i $WG_IFACE -p udp -m udp --dport ([0-9]+) -j ACCEPT$"
      if ! [[ $rules =~ $tcp$udp && ${BASH_REMATCH[1]} == "${BASH_REMATCH[2]}" ]]; then
        log "IPv4 $FWD holds more than the forwarded port"
        return 1
      fi
    fi
  fi

  for spec in "filter $IN DROP" "filter $OUT REJECT" "mangle $PRE RETURN" "mangle $MOUT RETURN" "mangle $POST DROP"; do
    read -r table chain target <<<"$spec"
    rules=$("$ipt" -w -t "$table" -S "$chain")
    [[ $(tail -n1 <<<"$rules") =~ ^-A\ $chain\ -m\ comment\ --comment\ \"?twg:([0-9a-f]{16})\"?\ -j\ $target( |$) ]] ||
      { log "IPv$fam $chain does not end in its sealed $target rule"; return 1; }
    [[ ${BASH_REMATCH[1]} == "$(chain_hash "$ipt" "$table" "$chain" true)" ]] ||
      { log "IPv$fam $chain rules were changed"; return 1; }
  done
}

check() {
  local fam ruleset f
  for fam in "${FAMILIES[@]}"; do check_family "$fam"; done
  # Duplicating statements (nft dup/fwd, iptables TEE) send copies of a
  # packet past every later chain, POSTROUTING included.
  ruleset=$(nft list ruleset 2>/dev/null) || { log "cannot list the nft ruleset"; return 1; }
  if grep -Eqw 'dup|fwd|TEE' <<<"$ruleset"; then
    log "a rule duplicates or forwards packets (nft dup/fwd or TEE)"
    return 1
  fi
  # tc filters (mirred redirect, BPF) act after POSTROUTING, so none may
  # exist on any interface of the namespace.
  for f in /sys/class/net/*; do
    f=${f##*/}
    ruleset=$(tc filter show dev "$f" 2>/dev/null; tc filter show dev "$f" ingress 2>/dev/null; tc filter show dev "$f" egress 2>/dev/null) || true
    [[ -z $ruleset ]] || { log "tc filters on $f can redirect packets past the kill switch"; return 1; }
  done
}

# Up means wg-quick has finished: the interface has its address and the
# fwmark policy rule is in place, so Transmission can bind to the address.
tunnel() {
  local rules
  check
  wg show "$WG_IFACE" >/dev/null 2>&1 || { log "$WG_IFACE is not up"; return 1; }
  [[ -n $(ip -o addr show dev "$WG_IFACE" 2>/dev/null) ]] || { log "$WG_IFACE has no address yet"; return 1; }
  rules=$(ip -4 rule show 2>/dev/null)
  [[ $rules == *"not from all fwmark $(printf '0x%x' "$WG_FWMARK") lookup"* ]] || { log "wg-quick policy routing is not in place"; return 1; }
}

# With failover peers: once the current peer has not handshaked for
# FAILOVER_AFTER seconds since it was set, replace it with the next one
# (wg0.conf's peer first, then the failover peers, round). Only the peer
# changes: the address, the routing and the firewall stay as they are.
fail_over() {
  local now cur hs key since _ ring next i allowed ka
  [[ -n $FAILOVER_PEERS ]] || return 0
  now=$(date +%s)
  cur=$(wg show "$WG_IFACE" peers | head -n1)
  [[ -n $cur ]] || return 0
  read -r key since _ 2>/dev/null <"$FAILOVER_STATE" || true
  # A peer this container has not seen yet (wg-quick just came up): from now.
  if [[ ${key:-} != "$cur" ]]; then
    echo "$cur $now 0" >"$FAILOVER_STATE"
    return 0
  fi
  hs=$(wg show "$WG_IFACE" latest-handshakes | awk -v p="$cur" '$1 == p { print $2 }')
  ((${hs:-0} > since)) && since=$hs
  ((now - since >= FAILOVER_AFTER)) || return 0

  mapfile -t ring < <(echo "$(conf_value PublicKey | tail -n1)@$(conf_value Endpoint | tail -n1)"; failover_peers)
  next=${ring[0]}
  for i in "${!ring[@]}"; do
    [[ ${ring[i]%%@*} == "$cur" ]] && next=${ring[(i + 1) % ${#ring[@]}]}
  done
  allowed=$(wg show "$WG_IFACE" allowed-ips | awk -v p="$cur" '$1 == p { $1 = ""; sub(/^ /, ""); gsub(/ /, ","); print }')
  ka=$(wg show "$WG_IFACE" persistent-keepalive | awk -v p="$cur" '$1 == p { print $2 }')
  [[ $ka =~ ^[0-9]+$ ]] || ka=""
  wg set "$WG_IFACE" peer "$cur" remove peer "${next%%@*}" endpoint "${next#*@}" allowed-ips "$allowed" ${ka:+persistent-keepalive "$ka"}
  echo "${next%%@*} $now 1" >"$FAILOVER_STATE"
  log "no handshake with peer ${cur} for ${FAILOVER_AFTER}s: switched to ${next#*@}"
}

# Transmission's RPC on loopback (the firewall allows lo).
tx_rpc() {
  local url="http://127.0.0.1:${WEB_PORT}/transmission/rpc" cfg sid user=""
  if [[ -r $RPC_DIR/username && -r $RPC_DIR/password ]]; then
    user="$(cat "$RPC_DIR/username"):$(cat "$RPC_DIR/password")"
    user=${user//\\/\\\\}
    user=${user//\"/\\\"}
  fi
  # The credentials go in a config on a pipe, not on the command line.
  cfg=${user:+user = \"$user\"}
  sid=$(curl -s -m 3 -K - -o /dev/null -D - "$url" <<<"$cfg" | sed -n 's/^X-Transmission-Session-Id: *\([^[:space:]]*\).*/\1/Ip')
  curl -sf -m 3 -K - -H "X-Transmission-Session-Id: $sid" -d "$1" "$url" <<<"$cfg"
}

# Renews the NAT-PMP mapping (it lasts 60 s; live runs every 30 s), opens
# the port on wg0 and makes it Transmission's peer port. A gateway that does
# not answer is logged, not a failure: without a forwarded port Transmission
# still downloads.
port_forward() {
  local out port rules now
  [[ -n $NATPMP_GATEWAY ]] || return 0
  if ! out=$(timeout 4 natpmpc -g "$NATPMP_GATEWAY" -a 1 0 udp 60 2>&1 && timeout 4 natpmpc -g "$NATPMP_GATEWAY" -a 1 0 tcp 60 2>&1); then
    log "NAT-PMP: no mapping from ${NATPMP_GATEWAY}: $(tail -n1 <<<"$out")"
    return 0
  fi
  port=$(sed -n 's/^Mapped public port \([0-9]*\) protocol TCP.*/\1/p' <<<"$out" | tail -n1)
  if ! [[ $port =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
    log "NAT-PMP: ${NATPMP_GATEWAY} gave no usable port: $(tail -n1 <<<"$out")"
    return 0
  fi
  rules=$(iptables -w -S "$FWD" | sed 1d)
  if [[ $rules != *"--dport $port -j ACCEPT"* || $(cat "$FORWARD_DIR/port" 2>/dev/null) != "$port" ]]; then
    # One transaction, so check() never sees half of it.
    iptables-restore -w --noflush <<EOF
*filter
-F $FWD
-A $FWD -i $WG_IFACE -p tcp -m tcp --dport $port -j ACCEPT
-A $FWD -i $WG_IFACE -p udp -m udp --dport $port -j ACCEPT
COMMIT
EOF
    echo "$port" >"$FORWARD_DIR/port.new"
    mv "$FORWARD_DIR/port.new" "$FORWARD_DIR/port"
    log "NAT-PMP: ${NATPMP_GATEWAY} forwards port ${port}"
  fi
  now=$(tx_rpc '{"method":"session-get","arguments":{"fields":["peer-port"]}}' 2>/dev/null |
    sed -n 's/.*"peer-port": *\([0-9]*\).*/\1/p') || true
  if [[ $now != "$port" ]]; then
    if tx_rpc "{\"method\":\"session-set\",\"arguments\":{\"peer-port\":$port}}" >/dev/null 2>&1; then
      log "Transmission's peer port: ${port}"
    else
      log "could not set Transmission's peer port to ${port} yet (is it starting?)"
    fi
  fi
}

# One line per peer from wg's counters, and with "why" what they point to.
# The dump's first line, the interface with its private key, is skipped.
peer_report() {
  local now pub ep hs rx tx
  now=$(date +%s)
  while IFS=$'\t' read -r pub _ ep _ hs rx tx _; do
    if ((hs == 0)); then
      log "peer ${pub} at ${ep}: no handshake yet, received ${rx} bytes, sent ${tx} bytes"
    else
      log "peer ${pub} at ${ep}: last handshake $((now - hs))s ago, received ${rx} bytes, sent ${tx} bytes"
    fi
    [[ ${1:-} == why ]] || continue
    if ((hs == 0 && tx == 0)); then
      log "  nothing was sent to ${ep}: the endpoint is not reachable from the pod (address, port, or the kill switch's endpoint list)"
    elif ((hs == 0)); then
      log "  ${ep} never answered: the server ignores this key's handshakes. Check the provider still has wg0.conf's key (rotated or revoked keys look like this), that the account is active, and that UDP to ${ep} is not blocked on the way"
    else
      log "  ${ep} answered before and stopped: the server is down, the key was revoked since, or UDP to it is blocked now"
    fi
  done < <(wg show "$WG_IFACE" dump 2>/dev/null | tail -n +2)
}

# Every STATUS_EVERY seconds, the peers' state in the container's log: a
# history to compare with when the probe fails.
status_note() {
  local now last=0
  now=$(date +%s)
  read -r last 2>/dev/null <"$STATUS_STATE" || true
  ((now - ${last:-0} >= STATUS_EVERY)) || return 0
  echo "$now" >"$STATUS_STATE" 2>/dev/null || true
  peer_report
}

# The termination message (up to 4 KiB): this probe's lines if it failed, so
# a restart says why; cleared once a probe passes, so an unrelated exit
# does not show an old reason.
live_exit() {
  [[ -f $TERMINATION_LOG ]] || return 0
  if (($1)); then
    printf '%s\n' "${LIVE_LOG[@]}" | tail -c 4000 >"$TERMINATION_LOG" 2>/dev/null || true
  elif [[ -s $TERMINATION_LOG ]]; then
    : >"$TERMINATION_LOG" 2>/dev/null || true
  fi
}

live() {
  local now hs newest=0 key since switched
  tunnel
  fail_over
  port_forward
  status_note
  ((HANDSHAKE_MAX_AGE > 0)) && keepalive_on || return 0
  now=$(date +%s)
  while read -r _ hs; do ((hs > newest)) && newest=$hs; done < <(wg show "$WG_IFACE" latest-handshakes)
  # A peer fail_over set gets the whole window to answer.
  if [[ -n $FAILOVER_PEERS ]] && read -r key since switched 2>/dev/null <"$FAILOVER_STATE" &&
    [[ $switched == 1 && $key == $(wg show "$WG_IFACE" peers | head -n1) ]]; then
    ((since > newest)) && newest=$since
  fi
  if ! ((newest > 0 && now - newest < HANDSHAKE_MAX_AGE)); then
    log "no handshake within ${HANDSHAKE_MAX_AGE}s"
    peer_report why
    return 1
  fi
}

detect_families "${1:-}"
case "${1:-}" in
  apply)
    for fam in "${FAMILIES[@]}"; do apply_family "$fam"; done
    reset_netns
    log "kill switch installed (web ${WEB_PORT}/tcp from: ${WEB_CIDRS:-none}; peers ${PEER_PORT} via ${WG_IFACE})"
    preflight
    ;;
  check) check ;;
  tunnel) tunnel ;;
  live)
    trap 'live_exit $?' EXIT
    live
    ;;
  *) die "usage: $0 apply|check|tunnel|live" ;;
esac
