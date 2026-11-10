# Makefile for transmission-wireguard

.PHONY: lint validate test e2e e2e-docker e2e-kind e2e-k3d e2e-upgrade mutation install help

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

# Leak tests (bats suites; `npm ci --prefix tests/e2e` installs bats). Need
# Docker with kernel WireGuard; the cluster suite also needs kubectl and
# helm, and kind or k3d. CNI=kindnet (dual-stack), calico or cilium.
# FILTER= runs only the checks whose names match, after a fresh setup.
CNI ?= kindnet
SIDECAR ?= privileged
FILTER ?=
# From the environment, so any quote in it reaches bats as it is.
export FILTER
BATS_ARGS = $(if $(FILTER),--filter "$$FILTER")
BATS = tests/e2e/node_modules/.bin/bats

# touch: npm leaves the lockfile newer than bats, so it would reinstall every run.
$(BATS): tests/e2e/package-lock.json
	npm ci --prefix tests/e2e --no-audit --no-fund
	touch $@

# SIDECAR=unprivileged runs it with NET_ADMIN + NET_RAW instead of privileged.
e2e-docker: $(BATS)
	SIDECAR=$(SIDECAR) tests/e2e/docker-test.sh $(BATS_ARGS)

KIND ?= kind

# Starts from a fresh cluster, so a rerun works.
e2e-kind: $(BATS)
	$(KIND) delete cluster
	KIND=$(KIND) tests/e2e/kind-cluster.sh $(CNI)
	IPV6=$(if $(filter kindnet,$(CNI)),1,0) tests/e2e/cluster-test.sh $(BATS_ARGS)

# The same suite on a throwaway k3d cluster (twg-k3d; k3s's own CNI and
# NetworkPolicy controller, IPv4), for a local run where kind is missing.
# Leaves your other k3d clusters and ~/.kube/config alone.
K3D_KUBECONFIG = $(CURDIR)/tests/e2e/.k3d/twg-k3d.kubeconfig
e2e-k3d: $(BATS)
	-tests/e2e/k3d-cluster.sh delete
	tests/e2e/k3d-cluster.sh
	KUBECONFIG=$(K3D_KUBECONFIG) CLUSTER=k3d tests/e2e/cluster-test.sh $(BATS_ARGS)

# Installs the last release tag, upgrades it to this chart, then runs the
# cluster suite on it (CLUSTER=k3d for the k3d cluster above).
# UPGRADE_FLAGS=--server-side=false for a release Helm 4 installed.
CLUSTER ?= kind
e2e-upgrade: $(BATS)
	rm -rf .previous && mkdir .previous
	git archive "$$(git tag --list 'v*' --sort=-v:refname --merged HEAD | head -n1)" | tar -x -C .previous
	$(if $(filter k3d,$(CLUSTER)),tests/e2e/k3d-cluster.sh delete; tests/e2e/k3d-cluster.sh,$(KIND) delete cluster; KIND=$(KIND) tests/e2e/kind-cluster.sh kindnet)
	$(if $(filter k3d,$(CLUSTER)),KUBECONFIG=$(K3D_KUBECONFIG) CLUSTER=k3d IPV6=0,IPV6=1) UPGRADE_FROM=$(CURDIR)/.previous \
	  tests/e2e/cluster-test.sh $(BATS_ARGS); rc=$$?; rm -rf .previous; exit $$rc

# Turns off each firewall rule in turn; the Docker suite must fail every
# time, except for the rules in tests/e2e/mutation-baseline.txt. Hours when
# run serially (CI runs batches in parallel); LINES= picks some
# (tests/e2e/mutation-test.sh --list).
mutation: $(BATS)
	tests/e2e/mutation-test.sh $(LINES)

e2e: e2e-docker e2e-kind

help:
	@echo "Available targets:"
	@echo "  lint     - Lint the chart and run unit tests"
	@echo "  validate - Run chart-testing lint"
	@echo "  install  - Install the chart with Helm"
	@echo "  test     - Run lint and validate"
	@echo "  e2e      - Run the kill switch leak tests (Docker, then kind; CNI=kindnet|calico|cilium)"
	@echo "  e2e-k3d  - Run the cluster suite on a throwaway k3d cluster (no kind needed)"
	@echo "  e2e-upgrade - Upgrade the last release to this chart, then run the cluster suite (CLUSTER=kind|k3d)"
	@echo "  mutation - Check that the leak test fails with each firewall rule turned off"
