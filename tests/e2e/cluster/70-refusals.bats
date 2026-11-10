#!/usr/bin/env bats
# A config from an existing Secret that the sidecar must refuse. The chart
# cannot see a Secret's contents; the sidecar must refuse it at runtime and
# Transmission must never start. A release of its own (twg-bad), removed
# again in teardown.

# shellcheck source=tests/e2e/cluster/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

teardown() {
  dump_on_failure
  helm uninstall twg-bad -n "$NS" --wait >/dev/null 2>&1 || true
  kubectl -n "$NS" delete secret wg-hook --ignore-not-found >/dev/null
}
bad_log() { kubectl -n "$NS" logs -l app.kubernetes.io/instance=twg-bad -c wireguard --tail=-1 2>/dev/null || true; }
bad_refused() { bad_log | grep -q 'FATAL.*hooks'; }
# Transmission's state, now and in any earlier run: empty if it never ran.
tx_ran() {
  kubectl -n "$NS" get pod -l app.kubernetes.io/instance=twg-bad -o jsonpath='{range .items[*].status.containerStatuses[?(@.name=="transmission")]}{.state.running}{.state.terminated}{.lastState.running}{.lastState.terminated}{end}'
}

@test "a Secret with a PostUp hook is refused and Transmission never starts" {
  kubectl -n "$NS" create secret generic wg-hook --from-file=wg0.conf=/dev/stdin >/dev/null <<EOF
[Interface]
PrivateKey = $CLIENT_KEY
Address = $TUN_CLIENT/32
PostUp = iptables -P OUTPUT ACCEPT

[Peer]
PublicKey = $SERVER_PUB
AllowedIPs = 0.0.0.0/0
Endpoint = $SERVER_IP:51820
EOF
  helm install twg-bad "$ROOT" -n "$NS" --set wireguard.existingSecret=wg-hook \
    --set "wireguard.endpoints[0].ip=$SERVER_IP" --set persistence.enabled=false \
    --set networkPolicy.enabled=false --set transmission.rpcAuth.allowAnonymous=true >/dev/null
  wait_until 90 bad_refused || fail "the sidecar did not refuse a Secret with a PostUp hook: $(bad_log | tail -n 3)"
  local first
  first=$(tx_ran)
  sleep 20 # the window: the sidecar keeps restarting; Transmission must stay waiting
  [[ -z $first && -z $(tx_ran) ]] || fail "Transmission started although the sidecar refused its config"
  pass "a Secret with a PostUp hook is refused and Transmission never starts"
}
