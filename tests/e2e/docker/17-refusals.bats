#!/usr/bin/env bats
# Unsafe configs are refused, and the rules stay installed: each test runs
# the sidecar's apply in a throwaway container of its own (no network), so
# none of them touches the pod.

load helpers

teardown() { docker rm -f "$P-pre" >/dev/null 2>&1 || true; }

# Runs apply in a throwaway namespace with wg0.conf edited by the sed script
# $1; $2 (optional) is written as a second config, wg1.conf; $3 (optional) is
# the tunnel.env the init container wrote (bound addresses). APPLY_ENV holds
# extra docker options; TWG_TEST_PRE in it sets up the namespace's network.
APPLY_ENV=()
run_apply() {
  local dir=$BATS_TEST_TMPDIR/pre
  rm -rf "$dir"
  mkdir -p "$dir/config/wg_confs"
  stage_scripts "$dir"
  sed "$1" "$WG_CONF" >"$dir/config/wg_confs/wg0.conf"
  [[ -z ${2:-} ]] || echo "$2" >"$dir/config/wg_confs/wg1.conf"
  if [[ -n ${3:-} ]]; then
    mkdir -p "$dir/twg/run"
    echo "$3" >"$dir/twg/run/tunnel.env"
  fi
  docker rm -f "$P-pre" >/dev/null 2>&1 || true
  # shellcheck disable=SC2154 # firewall_env: helpers.bash
  docker create --name "$P-pre" --privileged --network none "${firewall_env[@]}" "${APPLY_ENV[@]}" --entrypoint /bin/bash "$WG_IMAGE" \
    -c 'eval "${TWG_TEST_PRE:-}"; /twg/scripts/firewall.sh apply; rc=$?; /twg/scripts/firewall.sh check && echo RULES_OK; echo "RC=$rc"
      for c in INPUT FORWARD OUTPUT; do iptables -S $c | head -n1; ip6tables -S $c | head -n1; done | sed "s/^/POLICY /"' >/dev/null
  docker cp "$dir/." "$P-pre:/" >/dev/null
  # Not start -a: attaching can miss the output of a container this short-lived.
  docker start "$P-pre" >/dev/null
  docker wait "$P-pre" >/dev/null
  docker logs "$P-pre" 2>&1 || true
  docker rm -f "$P-pre" >/dev/null
}
# Refused (FATAL, a non-zero exit) with the full rule set installed.
expect_refused() {
  local out
  out=$(run_apply "$@")
  { grep -q FATAL <<<"$out" && grep -q RULES_OK <<<"$out" && ! grep -q 'RC=0' <<<"$out"; } ||
    fail "not refused: ${BATS_TEST_DESCRIPTION#refused: }"$'\n'"$out"
}
# A setting the rules cannot be built from ($1, a docker -e): refused before
# any rule is built, but with all six policies (INPUT, FORWARD, OUTPUT for
# both families) already DROP.
expect_locked_down() {
  local out
  APPLY_ENV=(-e "$1")
  out=$(run_apply '')
  { grep -q FATAL <<<"$out" && [[ $(grep -c '^POLICY -P [A-Z]* DROP$' <<<"$out") == 6 ]] && ! grep -q 'RC=0' <<<"$out"; } ||
    fail "not refused or not locked down: ${BATS_TEST_DESCRIPTION#refused, everything dropped: }"$'\n'"$out"
}
expect_accepted() {
  local out
  out=$(run_apply "$@")
  { grep -q 'RC=0' <<<"$out" && grep -q RULES_OK <<<"$out"; } ||
    fail "wrongly refused: ${BATS_TEST_DESCRIPTION#accepted: }"$'\n'"$out"
}

@test "refused: PreDown that flushes the firewall" {
  expect_refused '/^\[Interface\]/a PreDown = iptables -P OUTPUT ACCEPT; iptables -F OUTPUT'
}

@test "refused: hook that runs a script" {
  expect_refused '/^\[Interface\]/a PostUp = /config/up.sh'
}

@test "refused: hostname endpoint" {
  expect_refused "s/^Endpoint = .*/Endpoint = vpn.example.com:51820/"
}

@test "refused: endpoint without a port" {
  expect_refused "s/^Endpoint = .*/Endpoint = $SERVER_IP/"
}

@test "refused: split tunnel" {
  expect_refused "s|^AllowedIPs = .*|AllowedIPs = 10.0.0.0/8|"
}

@test "refused: full tunnel split in halves" {
  expect_refused "s|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/1, 128.0.0.0/1|"
}

@test "refused: IPv6-only tunnel" {
  expect_refused "s|^AllowedIPs = .*|AllowedIPs = ::/0|"
}

@test "refused: IPv6 ranges (written 0::/0) without a tunnel IPv6 address" {
  expect_refused "s|^Address = .*|Address = $TUN_CLIENT/32|; s|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/0, 0::/0|"
}

@test "refused, everything dropped: a zero connection mark" {
  expect_locked_down TWG_LOCAL_MARK=0
}

@test "refused, everything dropped: a connection mark sharing bits with the fwmark" {
  expect_locked_down TWG_LOCAL_MARK=0xca6c
}

@test "refused, everything dropped: the peer port equal to the web port" {
  expect_locked_down TWG_PEER_PORT="$WEB_PORT"
}

@test "refused, everything dropped: a zero fwmark" {
  expect_locked_down TWG_WG_FWMARK=0
}

@test "refused, everything dropped: a fwmark that is the main routing table" {
  expect_locked_down TWG_WG_FWMARK=254
}

# IPv6 in the namespace with ip6tables broken (a shim that always fails):
# refused rather than run with IPv6 unfiltered; IPv4 is locked down.
@test "refused, IPv4 locked down: IPv6 in the pod with ip6tables unusable" {
  local out
  APPLY_ENV=(-e "TWG_TEST_PRE=ip link add d6 type dummy && ip link set d6 up && ip -6 addr add fd00::5/64 dev d6 && mkdir -p /tmp/shim &&
    printf '#!/bin/sh\nexit 1\n' >/tmp/shim/ip6tables && chmod +x /tmp/shim/ip6tables && export PATH=/tmp/shim:\$PATH")
  out=$(run_apply '')
  { grep -q 'FATAL: IPv6 is configured in the pod but ip6tables is unusable' <<<"$out" &&
    [[ $(grep -c '^POLICY -P [A-Z]* DROP$' <<<"$out") == 3 ]] && ! grep -q 'RC=0' <<<"$out"; } ||
    fail "not refused: IPv6 in the pod with ip6tables unusable"$'\n'"$out"
}

@test "refused: a FwMark that differs from firewall.wgFwmark" {
  expect_refused '/^\[Interface\]/a FwMark = 1234'
}

@test "refused: a custom fwmark without a FwMark line" {
  APPLY_ENV=(-e TWG_WG_FWMARK=4660)
  expect_refused ''
}

@test "refused: a tunnel without an IPv4 address" {
  expect_refused "s|^Address = .*|Address = $TUN_CLIENT6/128|"
}

@test "refused: Table = off" {
  expect_refused '/^\[Interface\]/a Table = off'
}

@test "refused: Table = 1234" {
  expect_refused '/^\[Interface\]/a Table = 1234'
}

@test "refused: a second tunnel config next to wg0.conf" {
  expect_refused '' $'[Interface]\nPostUp = iptables -P OUTPUT ACCEPT'
}

@test "accepted: FwMark written in hex (0xca6c = 51820)" {
  expect_accepted '/^\[Interface\]/a FwMark = 0xca6c'
}

# A route to the endpoint with jumbo frames, like AWS VPC CNI's eth0.
JUMBO=(-e "TWG_TEST_PRE=ip link add j0 mtu 9001 type dummy && ip link set j0 up && ip route add default dev j0")

@test "refused: no MTU line where the endpoint's route has MTU 9001" {
  APPLY_ENV=("${JUMBO[@]}")
  expect_refused ''
}

@test "accepted: MTU = 1420 where the endpoint's route has MTU 9001" {
  APPLY_ENV=("${JUMBO[@]}")
  expect_accepted '/^\[Interface\]/a MTU = 1420'
}

@test "refused: an Address changed since Transmission was bound" {
  expect_refused '' '' $'TWG_BIND4=10.99.0.77\nTWG_BIND6='"$TUN_CLIENT6"$'\nTWG_PEER_PORT=51413'
}

@test "accepted: the Address Transmission was bound to" {
  expect_accepted '' '' "$(cat "$STAGE/tunnel.env")"
}

@test "accepted: CRLF line endings" {
  expect_accepted 's/$/\r/'
}
