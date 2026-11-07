#!/usr/bin/env bash
# Installs the chart tooling used in CI (.github/workflows/helm-chart.yaml).
# Keep versions in sync with the workflows.
set -euo pipefail

CT_VERSION=3.14.0
KUBECONFORM_VERSION=0.6.7
YQ_VERSION=4.45.1
HELM_UNITTEST_VERSION=0.3.0

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# chart-testing (ct) and its Python dependencies
pip install --user --no-cache-dir yamllint yamale
curl -sSL "https://github.com/helm/chart-testing/releases/download/v${CT_VERSION}/chart-testing_${CT_VERSION}_linux_${ARCH}.tar.gz" \
  | tar -xz -C "${tmp}"
sudo install -m 0755 "${tmp}/ct" /usr/local/bin/ct
sudo mkdir -p /etc/ct
sudo cp "${tmp}/etc/chart_schema.yaml" "${tmp}/etc/lintconf.yaml" /etc/ct/

# kubeconform
curl -sSL "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-${ARCH}.tar.gz" \
  | tar -xz -C "${tmp}" kubeconform
sudo install -m 0755 "${tmp}/kubeconform" /usr/local/bin/kubeconform

# yq
sudo curl -sSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ARCH}" \
  -o /usr/local/bin/yq
sudo chmod +x /usr/local/bin/yq

# helm-unittest plugin, so `helm unittest .` works without Docker
helm plugin install https://github.com/helm-unittest/helm-unittest --version "v${HELM_UNITTEST_VERSION}" >/dev/null || true

echo
echo "Tooling installed:"
helm version --short
ct version | head -n 1
kubeconform -v
yq --version
