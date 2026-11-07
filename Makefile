# Makefile for transmission-wireguard

.PHONY: lint validate test e2e e2e-docker e2e-kind install

lint:
	helm lint . --strict -f ci/default-values.yaml
	docker run --rm -v "$(PWD):/apps" helmunittest/helm-unittest:3.11.1-0.3.0 .

validate:
	ct lint --charts . --validate-maintainers=false

install:
	helm install transmission ./transmission-wireguard -f values.yaml

test: lint validate

# Leak tests. Need Docker with kernel WireGuard; e2e-kind also needs a kind
# cluster (kind create cluster) and kubectl/helm.
e2e-docker:
	tests/e2e/netns-leak-test.sh

e2e-kind:
	tests/e2e/kind-test.sh

e2e: e2e-docker e2e-kind

help:
	@echo "Available targets:"
	@echo "  lint     - Lint the chart and run unit tests"
	@echo "  validate - Run chart-testing lint"
	@echo "  install  - Install the chart with Helm"
	@echo "  test     - Run lint and validate"
	@echo "  e2e      - Run the kill switch leak tests (Docker, then kind)"
