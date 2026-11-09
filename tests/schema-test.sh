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
expect_schema_error "a fwmark that is the main routing table" --set firewall.wgFwmark=254
expect_schema_error "a fwmark that is the saved route table, in hex" --set-string firewall.wgFwmark=0x3e8
expect_schema_error "duplicate nameservers" --set 'wireguard.dns.nameservers={1.1.1.1,1.1.1.1}'
expect_schema_error "a handshake age too large to render" --set wireguard.handshakeMaxAgeSeconds=1000000
expect_schema_error "an ingress pathType Kubernetes does not know" --set ingress.enabled=true --set 'ingress.hosts[0].host=tx.example.com' --set 'ingress.hosts[0].paths[0].path=/' --set 'ingress.hosts[0].paths[0].pathType=prefix'
expect_schema_error "an image pull secret without a name" --set 'imagePullSecrets[0].nam=regcred'
expect_schema_error "a typo in persistence (keepOnUninstal)" --set persistence.keepOnUninstal=false

if helm template t "$ROOT" -f "$ROOT/ci/default-values.yaml" >/dev/null; then
  echo "PASS  the CI values render"
else
  echo "FAIL  the CI values do not render"; FAILED=$((FAILED + 1))
fi
((FAILED == 0)) || { echo "$FAILED check(s) failed"; exit 1; }
