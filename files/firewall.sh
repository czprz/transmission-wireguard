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
SAVED_ROUTE_TABLE="${TWG_SAVED_ROUTE_TABLE:-51821}"
HANDSHAKE_MAX_AGE="${TWG_HANDSHAKE_MAX_AGE:-0}"
ALLOW_CONF_HOOKS="${TWG_ALLOW_CONF_FIREWALL_HOOKS:-false}"
CONF="${TWG_WG_CONF:-/config/wg_confs/${WG_IFACE}.conf}"

IN=TWG-INPUT
OUT=TWG-OUTPUT
PRE=TWG-PREROUTING
MOUT=TWG-MANGLE-OUTPUT

log() { echo "[twg-firewall] $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

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

apply_family() {
  local fam=$1 ipt cidr
  ipt=$(ipt_for "$fam")

  "$ipt" -w -P INPUT DROP
  "$ipt" -w -P FORWARD DROP
  "$ipt" -w -P OUTPUT DROP
  reset_chain "$ipt" filter "$IN" INPUT
  reset_chain "$ipt" filter "$OUT" OUTPUT

  # Inbound: replies, BitTorrent peers via the tunnel, and the web UI from
  # cluster-local sources only. RPC is never reachable through the tunnel.
  "$ipt" -w -A "$IN" -i lo -j ACCEPT
  "$ipt" -w -A "$IN" -m conntrack --ctstate INVALID -j DROP
  "$ipt" -w -A "$IN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  "$ipt" -w -A "$IN" -i "$WG_IFACE" -p tcp --dport "$PEER_PORT" -j ACCEPT
  "$ipt" -w -A "$IN" -i "$WG_IFACE" -p udp --dport "$PEER_PORT" -j ACCEPT
  if [[ $fam == 6 ]]; then
    local t
    for t in router-advertisement neighbour-solicitation neighbour-advertisement; do
      "$ipt" -w -A "$IN" ! -i "$WG_IFACE" -p ipv6-icmp --icmpv6-type "$t" -j ACCEPT
    done
  fi
  while read -r cidr; do
    [[ -n $cidr ]] || continue
    "$ipt" -w -A "$IN" ! -i "$WG_IFACE" -s "$cidr" -p tcp --dport "$WEB_PORT" -j ACCEPT
  done < <(cidrs_for "$fam")
  "$ipt" -w -A "$IN" -j DROP

  # Outbound: only the tunnel, WireGuard's own encrypted packets (identified
  # by the fwmark wg-quick sets on its socket; unprivileged processes cannot
  # set marks) and replies on connections that arrived from the cluster.
  "$ipt" -w -A "$OUT" -o lo -j ACCEPT
  "$ipt" -w -A "$OUT" -m conntrack --ctstate INVALID -j DROP
  "$ipt" -w -A "$OUT" -o "$WG_IFACE" -j ACCEPT
  "$ipt" -w -A "$OUT" -m mark --mark "$WG_FWMARK" -j ACCEPT
  "$ipt" -w -A "$OUT" -m connmark --mark "$LOCAL_MARK/$LOCAL_MARK" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  if [[ $fam == 6 ]]; then
    for t in router-solicitation neighbour-solicitation neighbour-advertisement; do
      "$ipt" -w -A "$OUT" ! -o "$WG_IFACE" -p ipv6-icmp --icmpv6-type "$t" -j ACCEPT
    done
  fi
  "$ipt" -w -A "$OUT" -j REJECT

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
}

# Recover the namespace from a previous container run: a SIGKILLed tunnel
# leaves wg0 behind (wg-quick up then fails), and the image deletes the
# default route when wg-quick fails, which would leave WireGuard unable to
# reach its endpoint forever. The route is kept in a spare table, which lives
# in the namespace like everything else.
reset_netns() {
  local fam route
  ip link del "$WG_IFACE" 2>/dev/null || true
  for fam in "${FAMILIES[@]}"; do
    route=$(ip -"$fam" route show default 2>/dev/null | head -n1 || true)
    if [[ -n $route ]]; then
      # shellcheck disable=SC2086
      ip -"$fam" route replace $route table "$SAVED_ROUTE_TABLE"
    else
      route=$(ip -"$fam" route show default table "$SAVED_ROUTE_TABLE" 2>/dev/null | head -n1 || true)
      if [[ -n $route ]]; then
        log "restoring IPv$fam default route: $route"
        # shellcheck disable=SC2086
        ip -"$fam" route add $route
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

# Reject configs that would weaken or bypass the kill switch.
preflight() {
  local ep host fwmark
  [[ -r $CONF ]] || die "WireGuard config ${CONF} not found"

  if [[ $ALLOW_CONF_HOOKS != true ]] &&
    grep -Eiq '^[[:space:]]*(PreUp|PostUp|PreDown|PostDown)[[:space:]]*=.*(iptables|ip6tables|nft)' "$CONF"; then
    die "${CONF} has firewall commands in PreUp/PostUp/PreDown/PostDown. The chart manages the kill switch; remove them (a PreDown that flushes OUTPUT would open the firewall on every tunnel restart)."
  fi

  while read -r ep; do
    [[ -n $ep ]] || continue
    if [[ $ep == \[* ]]; then host=${ep#[}; host=${host%%]*}; else host=${ep%:*}; fi
    is_ip "$host" || die "Endpoint ${ep} is not an IP address. DNS is blocked until the tunnel is up, so the endpoint must be a literal IP."
  done < <(conf_value Endpoint)

  conf_value AllowedIPs | grep -Eq '(^|[ ,])(0\.0\.0\.0/0|::/0)([ ,]|$)' ||
    die "AllowedIPs must include 0.0.0.0/0 (full tunnel)"
  if conf_value Table | grep -Eiq '^off$'; then
    die "Table = off disables wg-quick's routing; all traffic would be rejected"
  fi

  fwmark=$(conf_value FwMark | tail -n1)
  if [[ -n $fwmark && $fwmark != "$WG_FWMARK" ]]; then
    die "FwMark ${fwmark} in ${CONF} differs from firewall.wgFwmark (${WG_FWMARK})"
  fi
}

# Rule dumps are captured before matching: grep -q exiting early would SIGPIPE
# iptables and, with pipefail, turn a match into a failure.
check_family() {
  local fam=$1 ipt chain dump rules
  ipt=$(ipt_for "$fam")
  for chain in INPUT FORWARD OUTPUT; do
    dump=$("$ipt" -w -S "$chain")
    [[ $'\n'$dump$'\n' == *$'\n'"-P $chain DROP"$'\n'* ]] || { log "IPv$fam $chain policy is not DROP"; return 1; }
    if [[ $chain != FORWARD ]]; then
      local want="$IN"; [[ $chain == OUTPUT ]] && want="$OUT"
      [[ $(sed -n 2p <<<"$dump") == "-A $chain -j $want" ]] || { log "IPv$fam $chain does not jump to $want first"; return 1; }
    fi
  done
  rules=$("$ipt" -w -S "$IN")
  [[ $(tail -n1 <<<"$rules") == "-A $IN -j DROP" ]] || { log "IPv$fam $IN does not end in DROP"; return 1; }
  rules=$("$ipt" -w -S "$OUT")
  [[ $(tail -n1 <<<"$rules") == "-A $OUT -j REJECT"* ]] || { log "IPv$fam $OUT does not end in REJECT"; return 1; }
  rules=$("$ipt" -w -t mangle -S OUTPUT)
  [[ $(sed -n 2p <<<"$rules") == "-A OUTPUT -j $MOUT" ]] || { log "IPv$fam mangle OUTPUT does not jump to $MOUT first"; return 1; }
}

check() {
  local fam
  for fam in "${FAMILIES[@]}"; do check_family "$fam"; done
}

tunnel() {
  check
  wg show "$WG_IFACE" >/dev/null 2>&1 || { log "$WG_IFACE is not up"; return 1; }
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
