#!/usr/bin/env bash
# End-to-end leak test on a Kubernetes cluster (Kubernetes >= 1.29, a CNI
# that enforces NetworkPolicy): the bats suite in tests/e2e/cluster.
#
# Covers what the Docker test cannot: native sidecar start ordering, kubelet
# probes through the kill switch, pod DNS, the Service, and the NetworkPolicy
# blocking egress even when the in-pod firewall is flushed. The leak checks
# first run with the NetworkPolicy disabled, so they test the in-pod kill
# switch alone; the policy is then enabled for the scenarios after it. The
# chart's `helm test` runs against the healthy and a tampered pod.
#
#   tests/e2e/kind-cluster.sh kindnet && IPV6=1 tests/e2e/cluster-test.sh
#   tests/e2e/k3d-cluster.sh && CLUSTER=k3d tests/e2e/cluster-test.sh
#
# Knobs (see tests/e2e/cluster/helpers.bash):
#   CLUSTER=kind|k3d  where the cluster runs (default kind); CLUSTER_NET
#                     (or KIND_NET) and NODE_CONTAINER override its Docker
#                     network and node container, K3D_CLUSTER and
#                     K3D_KUBECONFIG the k3d cluster's name and kubeconfig
#   IPV6=1            a dual-stack cluster: adds the IPv6 leak checks
#   UPGRADE_FROM=<chart dir>  installs that chart (an earlier release, with
#                     its defaults and a PVC) and upgrades it to this one, so
#                     every check runs on an upgraded release; UPGRADE_FLAGS
#                     are added to that upgrade, as a user following the
#                     README's upgrade notes would
#   NS                the namespace (default twg-e2e); KEEP=1 leaves it and
#                     the containers in place after the run
#   JUNIT_DIR         also writes a JUnit report there
#
# Extra arguments go to bats, e.g. one check after a fresh setup:
#   tests/e2e/cluster-test.sh --filter 'UDP leaves through the VPN'
set -euo pipefail

E2E=$(cd "$(dirname "$0")" && pwd)
BATS=${BATS:-$E2E/node_modules/.bin/bats}
[[ -x $BATS ]] || { echo "bats not found at $BATS: run npm ci --prefix tests/e2e" >&2; exit 1; }
args=(--print-output-on-failure --timing)
if [[ -n ${JUNIT_DIR:-} ]]; then
  mkdir -p "$JUNIT_DIR"
  args+=(--report-formatter junit --output "$JUNIT_DIR")
fi
# The whole suite, unless files or directories of it are named.
paths=("$E2E/cluster")
for a in "$@"; do [[ $a == *.bats || -d $a ]] && paths=(); done
exec "$BATS" "${args[@]}" "$@" "${paths[@]}"
