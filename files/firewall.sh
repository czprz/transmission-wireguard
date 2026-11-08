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
#        firewall.sh live    tunnel + latest handshake is recent (if configured)
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

IN=TWG-INPUT
OUT=TWG-OUTPUT
PRE=TWG-PREROUTING
MOUT=TWG-MANGLE-OUTPUT
POST=TWG-POSTROUTING

log() { echo "[twg-firewall] $*" >&2; }
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
[[ $PEER_PORT != "$WEB_PORT" ]] || refuse_setting "${1:-}" "the peer port ${PEER_PORT} must differ from the web port"

# IPv6 must be filtered whenever the namespace has it; only skip ip6tables
# when there is no IPv6 at all.
detect_families() {
  FAMILIES=(4)
  if ip6tables -w -S >/dev/null 2>&1; then
    FAMILIES+=(6)
  elif [[ -s /proc/net/if_inet6 ]] && grep -qv ' lo$' /proc/net/if_inet6; then
    die "IPv6 is configured in the pod but ip6tables is unusable; refusing to run unfiltered"
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
  local fam=$1 ipt cidr host port
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
  while read -r cidr; do
    [[ -n $cidr ]] || continue
    "$ipt" -w -A "$IN" ! -i "$WG_IFACE" -s "$cidr" -p tcp --dport "$WEB_PORT" -j ACCEPT
  done < <(cidrs_for "$fam")
  seal_chain "$ipt" filter "$IN" -j DROP

  # Outbound: only the tunnel, WireGuard's own encrypted packets (identified
  # by the fwmark wg-quick sets on its socket; unprivileged processes cannot
  # set marks) and replies on connections that arrived from the cluster.
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
  "$ipt" -w -A "$OUT" -m connmark --mark "$LOCAL_MARK/$LOCAL_MARK" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
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
  "$ipt" -w -t mangle -A "$POST" -m connmark --mark "$LOCAL_MARK/$LOCAL_MARK" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  seal_chain "$ipt" mangle "$POST" -j DROP
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

# "host port" of every usable Endpoint of IP family $1.
endpoints() {
  local ep
  [[ -r $CONF ]] || return 0
  while read -r ep; do
    split_endpoint "$ep" >/dev/null || continue
    if [[ $1 == 4 && $EP_HOST != *:* ]] || [[ $1 == 6 && $EP_HOST == *:* ]]; then
      echo "$EP_HOST $EP_PORT"
    fi
  done < <(conf_value Endpoint)
}

# Reject configs that would weaken or bypass the kill switch.
preflight() {
  local ep fwmark table f allowed addrs err
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

  # Captured first: grep -q exiting on the first match would SIGPIPE tr and,
  # with pipefail, randomly refuse a valid config.
  allowed=$(conf_value AllowedIPs | tr -s ',[:blank:]' '\n')
  # IPv6 into the tunnel (any IPv6 range, however written) without a tunnel
  # IPv6 address would carry the pod's own IPv6 address to the VPN.
  addrs=$(conf_value Address)
  if [[ $allowed == *:* && $addrs != *:* ]]; then
    die "AllowedIPs has IPv6 ranges but Address has no IPv6 address; add one (or drop the IPv6 ranges so IPv6 is blocked)"
  fi
  grep -qx '0\.0\.0\.0/0' <<<"$allowed" || die "AllowedIPs must include 0.0.0.0/0 (full tunnel). Halves such as 0.0.0.0/1 + 128.0.0.0/1 do not work, because wg-quick only sets up the fwmark routing the kill switch relies on for /0"

  table=$(conf_value Table | tail -n1)
  if [[ -n $table && ${table,,} != auto ]]; then
    die "Table = ${table} turns off wg-quick's fwmark policy routing; remove it (all traffic would be rejected)"
  fi

  fwmark=$(conf_value FwMark | tail -n1)
  if [[ -n $fwmark ]]; then
    if ! [[ $fwmark =~ ^(0[xX][0-9a-fA-F]+|[1-9][0-9]*)$ ]] || ((fwmark != WG_FWMARK)); then
      die "FwMark ${fwmark} in ${CONF} differs from firewall.wgFwmark (${WG_FWMARK})"
    fi
  fi
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
  [[ $'\n'$rules$'\n' == *$'\n'"-A PREROUTING -j $PRE"$'\n'* ]] || { log "IPv$fam mangle PREROUTING does not jump to $PRE"; return 1; }

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
  local fam ruleset
  for fam in "${FAMILIES[@]}"; do check_family "$fam"; done
  # Duplicating statements (nft dup/fwd, iptables TEE) send copies of a
  # packet past every later chain, POSTROUTING included.
  if command -v nft >/dev/null 2>&1; then
    ruleset=$(nft list ruleset 2>/dev/null || true)
    if grep -Eqw 'dup|fwd|TEE' <<<"$ruleset"; then
      log "a rule duplicates or forwards packets (nft dup/fwd or TEE)"
      return 1
    fi
  fi
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

live() {
  local now hs newest=0
  tunnel
  ((HANDSHAKE_MAX_AGE > 0)) || return 0
  now=$(date +%s)
  while read -r _ hs; do ((hs > newest)) && newest=$hs; done < <(wg show "$WG_IFACE" latest-handshakes)
  ((newest > 0 && now - newest < HANDSHAKE_MAX_AGE)) || { log "no handshake within ${HANDSHAKE_MAX_AGE}s"; return 1; }
}

detect_families
case "${1:-}" in
  apply)
    for fam in "${FAMILIES[@]}"; do apply_family "$fam"; done
    reset_netns
    log "kill switch installed (web ${WEB_PORT}/tcp from: ${WEB_CIDRS:-none}; peers ${PEER_PORT} via ${WG_IFACE})"
    preflight
    ;;
  check) check ;;
  tunnel) tunnel ;;
  live) live ;;
  *) die "usage: $0 apply|check|tunnel|live" ;;
esac
