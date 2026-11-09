#!/usr/bin/env bash
# The release job's push, against a throwaway local registry: the chart
# must come back from oci://<registry>/<owner>/<name> at its version, and
# the README must name that location on ghcr.io.
#   GITHUB_REPOSITORY_OWNER=czprz tests/release-test.sh
# REGISTRY=host:port uses a running registry instead of starting one.
set -euo pipefail
cd "$(dirname "$0")/.."

owner=${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER must be set}
REGISTRY_IMAGE=registry:3.0.0@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e
TMP=$(mktemp -d)
if [[ -z ${REGISTRY:-} ]]; then
  REGISTRY=127.0.0.1:5000
  docker run -d --rm --name twg-release-test -p "$REGISTRY:5000" "$REGISTRY_IMAGE" >/dev/null
  trap 'docker rm -f twg-release-test >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
else
  trap 'rm -rf "$TMP"' EXIT
fi
for _ in $(seq 30); do curl -fsS "http://$REGISTRY/v2/" >/dev/null 2>&1 && break; sleep 1; done

failed=0
name=$(helm show chart . | sed -n 's/^name: //p')
version=$(helm show chart . | sed -n 's/^version: //p')
ref="oci://$REGISTRY/${owner,,}/$name"

ci/push-chart.sh "$REGISTRY" --plain-http
if helm pull "$ref" --version "$version" --plain-http -d "$TMP" >/dev/null 2>&1 &&
  [[ $(helm show chart "$TMP/$name-$version.tgz" | sed -n 's/^version: //p') == "$version" ]]; then
  echo "PASS  the release push lands at $ref, version $version"
else
  echo "FAIL  the chart did not come back from $ref at version $version"
  failed=1
fi
# Nothing but the chart: a stray wg0.conf or values file next to it would
# publish a private key.
extra=$(tar -tzf dist/*.tgz | sed "s|^$name/||" |
  grep -vxE 'Chart\.yaml|values\.yaml|values\.schema\.json|(README|ARCHITECTURE|CHANGELOG)\.md|icon\.svg|templates/.+|files/.+' || true)
if [[ -z $extra ]]; then
  echo "PASS  the package holds only the chart"
else
  echo "FAIL  the package holds files that are not part of the chart (see .helmignore):"
  while read -r f; do echo "        $f"; done <<<"$extra"
  failed=1
fi
rm -rf dist

published="oci://ghcr.io/${owner,,}/$name"
if grep -qF "$published\`" README.md; then
  echo "PASS  the README names the published location ($published)"
else
  echo "FAIL  the README does not name $published"
  failed=1
fi
exit "$failed"
