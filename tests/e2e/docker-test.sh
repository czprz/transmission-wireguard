#!/usr/bin/env bash
# Leak test for the kill switch, using plain Docker: runs the bats suite in
# tests/e2e/docker (see its setup_suite.bash for what it builds).
#
#   tests/e2e/docker-test.sh                      every test
#   tests/e2e/docker-test.sh --filter 'wg0'       the tests whose name matches
#   SIDECAR=unprivileged tests/e2e/docker-test.sh the sidecar without privileged
#   JUNIT_DIR=out tests/e2e/docker-test.sh        also a JUnit report in out/
#
# Other knobs (FIREWALL_SH, WG_IMAGE, TWG_E2E_PREFIX, KEEP, ...) are listed in
# tests/e2e/docker/helpers.bash. Installs nothing: bats comes from
# `npm ci --prefix tests/e2e`.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
BATS=${BATS:-$HERE/node_modules/.bin/bats}
[[ -x $BATS ]] || { echo "bats not found at $BATS: run npm ci --prefix tests/e2e" >&2; exit 2; }
case ${SIDECAR:-privileged} in
  privileged | unprivileged) ;;
  *) echo "SIDECAR must be privileged or unprivileged" >&2; exit 2 ;;
esac

args=(--print-output-on-failure --timing)
if [[ -n ${JUNIT_DIR:-} ]]; then
  mkdir -p "$JUNIT_DIR"
  args+=(--report-formatter junit --output "$JUNIT_DIR")
fi
# bats exits non-zero when any test (or the suite's setup) fails.
# The whole suite, unless files or directories of it are named.
paths=("$HERE/docker")
for a in "$@"; do [[ $a == *.bats || -d $a ]] && paths=(); done
exec "$BATS" "${args[@]}" "$@" "${paths[@]}"
