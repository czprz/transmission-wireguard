# Makefile for transmission-wireguard

.PHONY: lint test install

lint:
	helm lint . --strict
	docker run --rm -v "$(PWD):/apps" helmunittest/helm-unittest:3.11.1-0.3.0 .

validate:
	ct lint --all --chart-dirs .

install:
	helm install transmission ./transmission-wireguard -f values.yaml

test: lint validate

help:
	@echo "Available targets:"
	@echo "  lint     - Lint the chart and run unit tests"
	@echo "  validate - Run chart-testing lint"
	@echo "  install  - Install the chart with Helm"
	@echo "  test     - Run lint and validate"
