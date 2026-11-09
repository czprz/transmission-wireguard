#!/bin/sh
# Liveness probe of the Transmission container: whenever the tunnel's IPv4
# address exists, Transmission must be listening for peers on it.
#
# Transmission binds its peer sockets once, at start, and never retries. If
# it started while the tunnel was down (the sidecar restarting), it would
# never accept a peer again; restarting it then fixes that. While the
# address is missing it passes: a restart could not bind any better, and
# the kill switch keeps everything in until the sidecar is back.
set -eu

# Written by the init container next to settings.json, without the
# credentials.
TUNNEL_ENV="${TWG_TUNNEL_ENV:-/twg/run/tunnel.env}"
TWG_BIND4="" TWG_PEER_PORT=51413
# shellcheck disable=SC1090
. "$TUNNEL_ENV"
addr=$TWG_BIND4
port=$TWG_PEER_PORT
case $addr in "" | 127.*) exit 0 ;; esac

# The namespace's own addresses are the "/32 host LOCAL" entries.
awk -v a="$addr" '$1 == "|--" { ip = $2 } /\/32 host LOCAL/ && ip == a { found = 1 } END { exit !found }' \
  /proc/net/fib_trie || exit 0

# /proc/net/tcp shows the address as a little-endian word (amd64, arm64).
want=$(echo "$addr $port" | awk '{ split($1, o, "."); printf "%02X%02X%02X%02X:%04X", o[4], o[3], o[2], o[1], $2 }')
if ! awk -v w="$want" '$2 == w && $4 == "0A" { found = 1 } END { exit !found }' /proc/net/tcp; then
  echo "Transmission is not listening on ${addr}:${port}: it started while the tunnel was down and never bound its peer port" >&2
  exit 1
fi
