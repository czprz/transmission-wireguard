#!/usr/bin/env bash
# Installs the chart tooling used in CI (.github/workflows/helm-chart.yaml).
# Keep versions in sync with the workflows.
set -euo pipefail

# Renovate bumps these (the comments say from where); each download is
# checked against the checksums its release publishes.
# renovate: datasource=github-releases depName=helm/chart-testing extractVersion=^v(?<version>.+)$
CT_VERSION=3.14.0
# renovate: datasource=github-releases depName=yannh/kubeconform extractVersion=^v(?<version>.+)$
KUBECONFORM_VERSION=0.6.7
# renovate: datasource=github-releases depName=mikefarah/yq extractVersion=^v(?<version>.+)$
YQ_VERSION=4.45.1
# renovate: datasource=github-releases depName=helm-unittest/helm-unittest extractVersion=^v(?<version>.+)$
HELM_UNITTEST_VERSION=0.3.0

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# fetch URL FILE: download into ${tmp}/FILE.
fetch() { curl -fsSL --retry 2 -o "${tmp}/$2" "$1"; }
# verify FILE SHA256: fail unless FILE has that checksum.
verify() { echo "$2  ${tmp}/$1" | sha256sum -c --quiet - || { echo "checksum mismatch for $1" >&2; exit 1; }; }

# chart-testing (ct) and its Python dependencies
pip install --user --no-cache-dir yamllint yamale
ct_base="https://github.com/helm/chart-testing/releases/download/v${CT_VERSION}"
ct_tgz="chart-testing_${CT_VERSION}_linux_${ARCH}.tar.gz"
fetch "${ct_base}/${ct_tgz}" "${ct_tgz}"
fetch "${ct_base}/chart-testing_${CT_VERSION}_checksums.txt" ct.sums 2>/dev/null || fetch "${ct_base}/checksums.txt" ct.sums
verify "${ct_tgz}" "$(awk -v f="${ct_tgz}" '$2 == f { print $1 }' "${tmp}/ct.sums")"
tar -xzf "${tmp}/${ct_tgz}" -C "${tmp}"
sudo install -m 0755 "${tmp}/ct" /usr/local/bin/ct
sudo mkdir -p /etc/ct
sudo cp "${tmp}/etc/chart_schema.yaml" "${tmp}/etc/lintconf.yaml" /etc/ct/

# kubeconform
kc_base="https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}"
kc_tgz="kubeconform-linux-${ARCH}.tar.gz"
fetch "${kc_base}/${kc_tgz}" "${kc_tgz}"
fetch "${kc_base}/CHECKSUMS" kc.sums
verify "${kc_tgz}" "$(awk -v f="${kc_tgz}" '$2 == f { print $1 }' "${tmp}/kc.sums")"
tar -xzf "${tmp}/${kc_tgz}" -C "${tmp}" kubeconform
sudo install -m 0755 "${tmp}/kubeconform" /usr/local/bin/kubeconform

# yq
# yq's checksums file has one column per hash, in checksums_hashes_order.
yq_base="https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}"
fetch "${yq_base}/yq_linux_${ARCH}" yq
fetch "${yq_base}/checksums" yq.sums
fetch "${yq_base}/checksums_hashes_order" yq.order
yq_col=$(($(grep -nx 'SHA-256' "${tmp}/yq.order" | cut -d: -f1) + 1))
verify yq "$(awk -v f="yq_linux_${ARCH}" -v c="${yq_col}" '$1 == f { print $c }' "${tmp}/yq.sums")"
sudo install -m 0755 "${tmp}/yq" /usr/local/bin/yq

# helm-unittest plugin, so `helm unittest .` works without Docker
helm plugin install https://github.com/helm-unittest/helm-unittest --version "v${HELM_UNITTEST_VERSION}" >/dev/null || true

# Credential dirs are shared named volumes (see devcontainer.json). A fresh
# volume is root-owned, so hand it to the container user.
for dir in ~/.config/gh ~/.copilot ~/.claude ~/.codex; do
  sudo mkdir -p "${dir}"
  sudo chown -R "$(id -u):$(id -g)" "${dir}"
done

# Claude Code and Copilot CLI come with the base image; add Codex.
sudo npm install -g --no-fund --no-audit @openai/codex

echo
echo "Tooling installed:"
helm version --short
ct version | head -n 1
kubeconform -v
yq --version
echo "claude $(claude --version)"
codex --version
echo "copilot $(copilot --version | head -n 1)"
