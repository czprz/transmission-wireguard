#!/bin/sh
# Compose the read-only settings.json Transmission runs with: chart settings,
# RPC credentials from a Secret, and peer sockets bound to the tunnel address
# so Transmission cannot fall back to another interface even if routing does.
set -eu

SRC="${TWG_SETTINGS_SRC:-/twg/settings/settings.json}"
DST="${TWG_SETTINGS_DST:-/twg/run/settings.json}"
CONF="${TWG_WG_CONF:-/twg/wg/wg0.conf}"
BIND_TO_TUNNEL="${TWG_BIND_TO_TUNNEL:-true}"

v4=""
v6=""
# Unbound peer sockets could learn the pod's own (possibly global) IPv6
# address and announce it, so binding is not optional.
[ "$BIND_TO_TUNNEL" = "true" ] || { echo "[twg-settings] FATAL: transmission.bindToTunnel must be true" >&2; exit 1; }
[ -r "$CONF" ] || { echo "[twg-settings] FATAL: ${CONF} not readable" >&2; exit 1; }
for addr in $(tr -d '\r' <"$CONF" | sed -nE 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*([^#]*).*/\1/Ip' | tr ',' ' '); do
  addr=${addr%%/*}
  if printf '%s' "$addr" | grep -Eqx '([0-9]{1,3}\.){3}[0-9]{1,3}'; then
    [ -n "$v4" ] || v4=$addr
  elif printf '%s' "$addr" | grep -Eqx '[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*'; then
    [ -n "$v6" ] || v6=$addr
  else
    echo "[twg-settings] FATAL: Address ${addr} in ${CONF} is not an IP address" >&2
    exit 1
  fi
done
# Without a tunnel address for a family, bind it to loopback so that
# family cannot reach the network at all.
v4=${v4:-127.0.0.1}
v6=${v6:-::1}

umask 077
jq \
  --arg v4 "$v4" --arg v6 "$v6" \
  --arg user "${RPC_USERNAME:-}" --arg pass "${RPC_PASSWORD:-}" '
  .["bind-address-ipv4"] = $v4
  | .["bind-address-ipv6"] = $v6
  | (if $user != "" and $pass != "" then
       .["rpc-authentication-required"] = true | .["rpc-username"] = $user | .["rpc-password"] = $pass
     else . end)
' "$SRC" >"$DST"
chown "${PUID:-1000}:${PGID:-1000}" "$DST"

echo "[twg-settings] wrote ${DST} (bind-address-ipv4=$(jq -r '.["bind-address-ipv4"] // "unset"' "$DST"), rpc-auth=$(jq -r '.["rpc-authentication-required"] // false' "$DST"))"
