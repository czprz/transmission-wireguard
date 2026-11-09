# Makefile for transmission-wireguard

.PHONY: lint validate test e2e e2e-docker e2e-kind install help

lint:
	helm lint . --strict -f ci/default-values.yaml
	docker run --rm -v "$(PWD):/apps" helmunittest/helm-unittest:3.11.1-0.3.0@sha256:97f1d07dad520c9af52e090198469515b7b194622b5085302e40b11a8a930613 .
	tests/schema-test.sh
	tests/metadata-test.sh
	tests/package-test.sh

validate:
	docker run --rm -v "$(PWD):/repo" -w /repo \
	  -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
	  quay.io/helmpack/chart-testing:v3.14.0@sha256:425ff3058dfc192fffb94e471e732b9bc995c375df963eba417ff01aea594e83 \
	  ct lint --charts . --validate-maintainers=false

install:
	helm install transmission ./transmission-wireguard -f values.yaml

test: lint validate

# Leak tests. Need Docker with kernel WireGuard; e2e-kind also needs kind,
# kubectl and helm. CNI=kindnet (dual-stack), calico or cilium.
CNI ?= kindnet
SIDECAR ?= privileged

# SIDECAR=unprivileged runs it with NET_ADMIN + NET_RAW instead of privileged.
e2e-docker:
	SIDECAR=$(SIDECAR) tests/e2e/netns-leak-test.sh

KIND ?= kind

# Starts from a fresh cluster, so a rerun works.
e2e-kind:
	$(KIND) delete cluster
	KIND=$(KIND) tests/e2e/kind-cluster.sh $(CNI)
	IPV6=$(if $(filter kindnet,$(CNI)),1,0) tests/e2e/kind-test.sh

e2e: e2e-docker e2e-kind

help:
	@echo "Available targets:"
	@echo "  lint     - Lint the chart and run unit tests"
	@echo "  validate - Run chart-testing lint"
	@echo "  install  - Install the chart with Helm"
	@echo "  test     - Run lint and validate"
	@echo "  e2e      - Run the kill switch leak tests (Docker, then kind; CNI=kindnet|calico|cilium)"
