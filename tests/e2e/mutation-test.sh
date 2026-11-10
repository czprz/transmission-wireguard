#!/usr/bin/env bash
# Mutation test for the kill switch: turns off one firewall rule at a time
# and runs the Docker leak test against that firewall.sh, which must fail.
# A rule whose removal fails no check is redundant or untested.
#
#   tests/e2e/mutation-test.sh --list [--changed BASE]
#       the mutants (line numbers in files/firewall.sh); with --changed only
#       those on lines changed since git revision BASE
#   tests/e2e/mutation-test.sh [LINE...]
#       run them (default: all)
#
# A mutant is killed when a named leak check fails, or when the suite cannot
# set up (the tunnel never comes up, the firewall refuses to start: the pod
# fails closed). A run stopped by the test infrastructure (an image pull, the
# Docker daemon) is an error, not a kill: it proves nothing. The unmutated
# suite runs on every pull request, so a broken setup shows up there.
# tests/e2e/mutation-baseline.txt lists the rules no check can tell from
# their absence, each with the reason; they may survive. Each run takes as
# long as the Docker test; CI runs the mutants in a few parallel batches.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FW=$ROOT/files/firewall.sh
BASELINE=$ROOT/tests/e2e/mutation-baseline.txt

# Every line that adds a rule, sets a policy or hooks a chain in, and the
# router-advertisement sysctl write.
# shellcheck disable=SC2016 # firewall.sh's text, not expansions
list() {
  {
    grep -nE '"\$ipt" -w (-t [^ ]+ )?-[AIP] ' "$FW"
    grep -nF 'echo 0 2>/dev/null >"$f"' "$FW"
  } | cut -d: -f1 | sort -n
}

# Line numbers of firewall.sh that are new or changed since revision $1.
changed_since() {
  git -C "$ROOT" diff -U0 "$1" -- files/firewall.sh |
    sed -nE 's/^@@ -[0-9,]+ \+([0-9]+)(,([0-9]+))? @@.*/\1 \3/p' |
    while read -r start count; do
      for ((i = 0; i < ${count:-1}; i++)); do echo $((start + i)); done
    done
}

# The text of line $1, which the baseline matches (line numbers move).
code_at() { sed -n "${1}p" "$FW" | sed -E 's/^ +//; s/ +$//'; }

# The baseline's reason for the rule on line $1, if it is listed.
baseline_reason() {
  local code
  code=$(code_at "$1")
  awk -F '\t' -v c="$code" '!/^#/ && $1 == c { print $2; found = 1 } END { exit !found }' "$BASELINE"
}

# The firewall.sh with line $1 turned into a no-op (the command becomes an
# argument to `true`, so a rule continued on the next line stays valid).
mutate() {
  local n=$1 out=$2
  sed -e "${n}s/\"\\\$ipt\" -w/true &/" -e "${n}s/echo 0 2>\\/dev\\/null >\"\\\$f\"/true/" "$FW" >"$out"
  ! cmp -s "$FW" "$out" && bash -n "$out"
}

if [[ ${1:-} == --list ]]; then
  if [[ ${2:-} == --changed ]]; then
    comm -12 <(list | sort) <(changed_since "${3:?--changed needs a git revision}" | sort) | sort -n
  else
    list
  fi
  exit 0
fi
lines=("$@")
((${#lines[@]})) || mapfile -t lines < <(list)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
survived=0 errors=0 stale=0
for n in "${lines[@]}"; do
  echo "== mutant: firewall.sh:$n  $(code_at "$n" | cut -c1-110)"
  mutate "$n" "$TMP/firewall.sh" || { echo "   cannot mutate line $n" >&2; exit 2; }
  chmod 0755 "$TMP/firewall.sh"
  reason=$(baseline_reason "$n" || true)
  rc=0
  FIREWALL_SH=$TMP/firewall.sh "$ROOT/tests/e2e/docker-test.sh" --formatter tap >"$TMP/log" 2>&1 || rc=$?
  failed=$(grep -m1 -E '^not ok [0-9]+ ' "$TMP/log" | sed -E 's/^not ok [0-9]+ //' || true)
  if ((rc == 0)); then
    if [[ -n $reason ]]; then
      echo "   survived  (baseline: $reason)"
    else
      echo "   SURVIVED  no check fails without this line"
      survived=$((survived + 1))
    fi
  elif [[ -n $failed && $failed != setup_suite ]]; then
    # A file's setup that fails: name the file (the unmutated suite passes
    # on every pull request, so the mutant broke it).
    [[ $failed != "setup_file failed" ]] ||
      failed="the setup of $(grep -m1 -oE "in test file [^,]+" "$TMP/log" | sed 's/in test file //; s|.*/||')"
    echo "   killed    by: $failed"
    [[ -z $reason ]] || { echo "   STALE     the baseline lists this rule, but a check now catches it: remove it from $BASELINE"; stale=$((stale + 1)); }
  elif [[ $failed == setup_suite ]] && ! grep -qiE 'cannot pull|error response from daemon|toomanyrequests|no space left' "$TMP/log"; then
    echo "   killed    at setup: $(grep -m1 -E '^#   FAIL|^# .*(never|refus|FATAL)' "$TMP/log" | sed 's/^# *//' | cut -c1-160)"
  else
    echo "   ERROR     stopped by the test infrastructure, not by a check; this proves nothing:"
    grep . "$TMP/log" | tail -n 15 | sed 's/^/             /'
    errors=$((errors + 1))
  fi
done
echo
echo "${#lines[@]} mutant(s): $survived survived, $errors error(s), $stale stale baseline entr$( ((stale == 1)) && echo y || echo ies)"
((survived + errors + stale == 0))
