#!/usr/bin/env bash
# Creates the kind cluster for kind-test.sh with the given CNI, so the leak
# test runs against each NetworkPolicy implementation.
#
#   kindnet  kind's default CNI, dual-stack (run kind-test.sh with IPV6=1)
#   calico   Calico (iptables dataplane), IPv4
#   cilium   Cilium (eBPF dataplane), IPv4
#
# Downloads are pinned by checksum. Usage: tests/e2e/kind-cluster.sh calico
set -euo pipefail

CNI=${1:?usage: $0 kindnet|calico|cilium}
KIND=${KIND:-kind}
# The node image is the digest published in the kind v0.27.0 release notes.
NODE_IMAGE=${NODE_IMAGE:-kindest/node:v1.32.2@sha256:f226345927d7e348497136874b6d207e0b32cc52154ad8323129352923a3142f}
CALICO_VERSION=v3.30.3
CALICO_SHA256=9382d2b27a76f40c170454b408653e6d71e2205ef0aef069e942bb690e7381d0
CILIUM_VERSION=1.19.9
CILIUM_SHA256=b54b1bae91bd87bcf9f19672e7f23304156697596332e6c64a53b62143b2b251

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

case $CNI in
  kindnet) networking='  ipFamily: dual' ;;
  # Calico's manifest defaults its IP pool to 192.168.0.0/16.
  calico) networking=$'  disableDefaultCNI: true\n  podSubnet: 192.168.0.0/16' ;;
  cilium) networking='  disableDefaultCNI: true' ;;
  *) echo "unknown CNI: $CNI" >&2; exit 1 ;;
esac
cat >"$TMP/kind.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
$networking
EOF

"$KIND" create cluster --image "$NODE_IMAGE" --config "$TMP/kind.yaml" --wait 0s

case $CNI in
  calico)
    curl -fsSL -o "$TMP/calico.yaml" \
      "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml"
    echo "$CALICO_SHA256  $TMP/calico.yaml" | sha256sum -c -
    kubectl apply -f "$TMP/calico.yaml" >/dev/null
    ;;
  cilium)
    curl -fsSL -o "$TMP/cilium.tgz" "https://helm.cilium.io/cilium-$CILIUM_VERSION.tgz"
    echo "$CILIUM_SHA256  $TMP/cilium.tgz" | sha256sum -c -
    helm install cilium "$TMP/cilium.tgz" -n kube-system \
      --set image.pullPolicy=IfNotPresent --set ipam.mode=kubernetes >/dev/null
    ;;
esac

kubectl wait --for=condition=Ready nodes --all --timeout=5m
kubectl -n kube-system rollout status deploy/coredns --timeout=5m
