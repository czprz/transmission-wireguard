# Contributing to transmission-wireguard

Thank you for considering contributing! Here are some guidelines to help you get started:

## How to Contribute
- Fork the repository and create your branch from `main`.
- Make your changes with clear, descriptive commit messages.
- If adding a feature, update documentation and add tests if possible.
- Run `make lint` and `make test` (or see below for manual steps) before submitting a PR.
- Open a pull request and describe your changes.

## Development
- Lint the chart: `helm lint . --strict -f ci/default-values.yaml` (the chart needs a WireGuard config to render)
- Run tests: `docker run --rm -v "${PWD}:/apps" helmunittest/helm-unittest:3.11.1-0.3.0@sha256:97f1d07dad520c9af52e090198469515b7b194622b5085302e40b11a8a930613 .` and `tests/schema-test.sh`
- Validate manifests: `ct lint --charts . --validate-maintainers=false` (the chart sits at the repo root, where `--all` finds nothing to lint)
- Leak tests: `make e2e-docker` (Docker with kernel WireGuard) and `make e2e-kind CNI=kindnet|calico|cilium` (deletes and recreates the kind cluster). On Ubuntu hosts whose AppArmor profiles cover `wg`/`wg-quick`, run `sudo aa-teardown` first.
- CI: the `all-tests` job passes only when every test job passed; make it the required check (a skipped job counts as passed).

## Code of Conduct
Be respectful and constructive. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) if present.

## Issues
If you find a bug or have a feature request, please open an issue with details and steps to reproduce.

---

Happy contributing!
