#!/usr/bin/env bash
# Creates a throwaway k3d cluster for cluster-test.sh, for a local run of the
# cluster suite without kind. k3s's own NetworkPolicy controller (kube-router)
# stays on: the NetworkPolicy checks need it. IPv4 only (run with IPV6=0).
#
# The kubeconfig goes to its own file, never to ~/.kube/config:
#
#   tests/e2e/k3d-cluster.sh && CLUSTER=k3d tests/e2e/cluster-test.sh
#   tests/e2e/k3d-cluster.sh delete
#
# cluster-test.sh with CLUSTER=k3d finds the cluster and its kubeconfig by
# the same K3D_CLUSTER and K3D_KUBECONFIG defaults.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
K3D=${K3D:-k3d}
K3D_CLUSTER=${K3D_CLUSTER:-twg-k3d}
K3D_KUBECONFIG=${K3D_KUBECONFIG:-$ROOT/tests/e2e/.k3d/$K3D_CLUSTER.kubeconfig}
# k3d v5.8.3's default k3s, pinned by digest.
K3S_IMAGE=${K3S_IMAGE:-rancher/k3s:v1.31.5-k3s1@sha256:53cf744fe2fabf140cee240d2db70d13a4f2d98f1a13c98f58f457f423096917}

if [[ ${1:-create} == delete ]]; then
  "$K3D" cluster delete "$K3D_CLUSTER"
  rm -f "$K3D_KUBECONFIG"
  exit 0
fi

# Never reuse a cluster: the suite expects a fresh one.
if "$K3D" cluster get "$K3D_CLUSTER" >/dev/null 2>&1; then
  echo "k3d cluster $K3D_CLUSTER exists; delete it first: $0 delete" >&2
  exit 1
fi
mkdir -p "$(dirname "$K3D_KUBECONFIG")"
# No traefik or servicelb: the suite reaches the Service from inside the
# cluster only, and neither may answer for the canaries' ports.
"$K3D" cluster create "$K3D_CLUSTER" --image "$K3S_IMAGE" --servers 1 --agents 0 \
  --k3s-arg '--disable=traefik@server:0' --k3s-arg '--disable=servicelb@server:0' \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false --wait --timeout 5m
"$K3D" kubeconfig get "$K3D_CLUSTER" >"$K3D_KUBECONFIG"
chmod 0600 "$K3D_KUBECONFIG"
export KUBECONFIG=$K3D_KUBECONFIG

kubectl wait --for=condition=Ready nodes --all --timeout=5m
# k3s deploys its add-ons after the API comes up: wait for them to exist.
for _ in $(seq 60); do
  kubectl -n kube-system get deploy/coredns deploy/local-path-provisioner >/dev/null 2>&1 && break
  sleep 2
done
kubectl -n kube-system rollout status deploy/coredns --timeout=5m
kubectl -n kube-system rollout status deploy/local-path-provisioner --timeout=5m
echo "k3d cluster $K3D_CLUSTER is ready; KUBECONFIG=$K3D_KUBECONFIG"
