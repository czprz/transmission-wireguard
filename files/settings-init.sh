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
if [ "$BIND_TO_TUNNEL" = "true" ]; then
  [ -r "$CONF" ] || { echo "[twg-settings] FATAL: ${CONF} not readable" >&2; exit 1; }
  for addr in $(sed -nE 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*([^#]*).*/\1/Ip' "$CONF" | tr ',' ' '); do
    addr=${addr%%/*}
    case "$addr" in
      *:*) [ -n "$v6" ] || v6=$addr ;;
      *.*) [ -n "$v4" ] || v4=$addr ;;
    esac
  done
  # Without a tunnel address for a family, bind it to loopback so that
  # family cannot reach the network at all.
  v4=${v4:-127.0.0.1}
  v6=${v6:-::1}
fi

umask 077
jq \
  --arg v4 "$v4" --arg v6 "$v6" \
  --arg user "${RPC_USERNAME:-}" --arg pass "${RPC_PASSWORD:-}" '
  (if $v4 != "" and (has("bind-address-ipv4") | not) then .["bind-address-ipv4"] = $v4 else . end)
  | (if $v6 != "" and (has("bind-address-ipv6") | not) then .["bind-address-ipv6"] = $v6 else . end)
  | (if $user != "" and $pass != "" then
       .["rpc-authentication-required"] = true | .["rpc-username"] = $user | .["rpc-password"] = $pass
     else . end)
' "$SRC" >"$DST"
chown "${PUID:-1000}:${PGID:-1000}" "$DST"

echo "[twg-settings] wrote ${DST} (bind-address-ipv4=$(jq -r '.["bind-address-ipv4"] // "unset"' "$DST"), rpc-auth=$(jq -r '.["rpc-authentication-required"] // false' "$DST"))"
