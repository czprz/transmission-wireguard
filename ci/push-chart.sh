#!/usr/bin/env bash
# Packages the chart and pushes it to oci://REGISTRY/<repository owner>.
# The release job pushes to ghcr.io; tests/release-test.sh runs the same
# script against a local registry on every pull request.
#   GITHUB_REPOSITORY_OWNER=czprz ci/push-chart.sh REGISTRY [helm push flags]
set -euo pipefail
cd "$(dirname "$0")/.."

registry=${1:?usage: $0 REGISTRY [helm push flags]}
shift
owner=${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER must be set}
rm -rf dist
helm package . --destination dist >/dev/null
helm push dist/*.tgz "oci://$registry/${owner,,}" "$@"
