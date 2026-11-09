#!/usr/bin/env bash
# Mutation test for the kill switch: turns off one firewall rule at a time
# and runs the Docker leak test against that firewall.sh, which must fail.
# A rule whose removal fails no check is redundant or untested.
#
#   tests/e2e/mutation-test.sh --list   the mutants (line numbers in firewall.sh)
#   tests/e2e/mutation-test.sh [LINE...] run them (default: all)
#
# Each run takes as long as the Docker test; CI runs one job per mutant.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FW=$ROOT/files/firewall.sh

# Every line that adds a rule, sets a policy or hooks a chain in, and the
# router-advertisement sysctl write.
# shellcheck disable=SC2016 # firewall.sh's text, not expansions
list() {
  {
    grep -nE '"\$ipt" -w (-t [^ ]+ )?-[AIP] ' "$FW"
    grep -nF 'echo 0 2>/dev/null >"$f"' "$FW"
  } | cut -d: -f1 | sort -n
}

# The firewall.sh with line $1 turned into a no-op (the command becomes an
# argument to `true`, so a rule continued on the next line stays valid).
mutate() {
  local n=$1 out=$2
  sed -e "${n}s/\"\\\$ipt\" -w/true &/" -e "${n}s/echo 0 2>\\/dev\\/null >\"\\\$f\"/true/" "$FW" >"$out"
  ! cmp -s "$FW" "$out" && bash -n "$out"
}

if [[ ${1:-} == --list ]]; then
  list
  exit 0
fi
lines=("$@")
((${#lines[@]})) || mapfile -t lines < <(list)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
survived=0
for n in "${lines[@]}"; do
  code=$(sed -n "${n}p" "$FW" | sed 's/^ *//' | cut -c1-110)
  echo "== mutant: firewall.sh:$n  $code"
  mutate "$n" "$TMP/firewall.sh" || { echo "   cannot mutate line $n" >&2; exit 2; }
  chmod 0755 "$TMP/firewall.sh"
  if FIREWALL_SH=$TMP/firewall.sh "$ROOT/tests/e2e/netns-leak-test.sh" >"$TMP/log" 2>&1; then
    echo "   SURVIVED  the leak test passes without this line"
    survived=$((survived + 1))
  elif reason=$(grep -m1 '^ *FAIL ' "$TMP/log"); then
    echo "   killed    ${reason#"${reason%%FAIL*}"}"
  else
    # No check failed: the test stopped (often the sidecar refused to start).
    echo "   killed    the test stopped: $(grep . "$TMP/log" | tail -n1 | cut -c1-160)"
  fi
done
echo
if ((survived)); then
  echo "$survived of ${#lines[@]} mutant(s) SURVIVED"
  exit 1
fi
echo "all ${#lines[@]} mutant(s) killed"
