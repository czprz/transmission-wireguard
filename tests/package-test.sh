#!/usr/bin/env bash
# The package users install: it must hold only the chart (a wg0.conf or
# values file left next to it would publish a private key), and all of it,
# so no template or script the chart reads was left out.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
helm package . --destination "$TMP" >/dev/null
pkg=$(echo "$TMP"/*.tgz)
name=$(helm show chart "$pkg" | sed -n 's/^name: //p')

failed=0
extra=$(tar -tzf "$pkg" | sed "s|^$name/||" |
  grep -vxE 'Chart\.yaml|values\.yaml|values\.schema\.json|(README|ARCHITECTURE|CHANGELOG)\.md|icon\.svg|templates/.+|files/.+' || true)
if [[ -z $extra ]]; then
  echo "PASS  the package holds only the chart"
else
  echo "FAIL  the package holds files that are not part of the chart (see .helmignore):"
  while read -r f; do echo "        $f"; done <<<"$extra"
  failed=1
fi

# Helm applies .helmignore to the source directory too, so compare with git.
missing=$(comm -23 <(git ls-files Chart.yaml values.yaml values.schema.json templates files | sort) \
  <(tar -tzf "$pkg" | sed "s|^$name/||" | sort))
if [[ -z $missing ]]; then
  echo "PASS  the package holds every template and script"
else
  echo "FAIL  the package leaves out (see .helmignore):"
  while read -r f; do echo "        $f"; done <<<"$missing"
  failed=1
fi
exit "$failed"
