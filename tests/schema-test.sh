#!/usr/bin/env bash
# The schema refuses values that would otherwise be ignored or weaken the
# chart without a word (helm-unittest cannot assert schema errors).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAILED=0

expect_schema_error() {
  local what=$1 out; shift
  if out=$(helm template t "$ROOT" -f "$ROOT/ci/default-values.yaml" "$@" 2>&1); then
    echo "FAIL  accepted: $what"; FAILED=$((FAILED + 1))
  elif grep -q "don't meet the specifications of the schema" <<<"$out"; then
    echo "PASS  refused: $what"
  else
    echo "FAIL  $what refused for another reason:"; echo "$out" | head -3; FAILED=$((FAILED + 1))
  fi
}

expect_schema_error "a typo in wireguard.dns (nameserver)" --set 'wireguard.dns.nameserver={10.64.0.1}'
expect_schema_error "a typo in wireguard (handshakeMaxAge)" --set wireguard.handshakeMaxAge=120
expect_schema_error "an unknown top-level key" --set killSwitch=false
expect_schema_error "a nameserver that is not an IP" --set 'wireguard.dns.nameservers={dns.example.com}'
expect_schema_error "a web CIDR without a prefix length" --set 'firewall.webAllowedCIDRs={10.0.0.1}'
expect_schema_error "transmission.bindToTunnel=false" --set transmission.bindToTunnel=false
expect_schema_error "firewall.wgFwmark=0" --set firewall.wgFwmark=0
expect_schema_error "replicaCount=2 (one WireGuard key)" --set replicaCount=2
expect_schema_error "a handshake age WireGuard cannot meet" --set wireguard.handshakeMaxAgeSeconds=60
expect_schema_error "a nameserver that is just a colon" --set 'wireguard.dns.nameservers={:}'

if helm template t "$ROOT" -f "$ROOT/ci/default-values.yaml" >/dev/null; then
  echo "PASS  the CI values render"
else
  echo "FAIL  the CI values do not render"; FAILED=$((FAILED + 1))
fi
((FAILED == 0)) || { echo "$FAILED check(s) failed"; exit 1; }
