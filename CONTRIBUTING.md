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
- Run tests: `docker run --rm -v "${PWD}:/apps" helmunittest/helm-unittest:3.11.1-0.3.0@sha256:97f1d07dad520c9af52e090198469515b7b194622b5085302e40b11a8a930613 .` `tests/schema-test.sh`, `tests/metadata-test.sh` (`appVersion` must be the default Transmission version) and `tests/package-test.sh`
- Package: `tests/package-test.sh` checks the package against an allowlist and against git; a new top-level file must be listed in `.helmignore` or in that allowlist
- Validate manifests: `make validate` runs `ct lint --charts . --validate-maintainers=false` from the chart-testing image (the chart sits at the repo root, where `--all` finds nothing to lint)
- Leak tests: bats suites, installed with `npm ci --prefix tests/e2e` (the Makefile does it). `make e2e-docker` (Docker with kernel WireGuard; `SIDECAR=unprivileged` runs the sidecar with only `NET_ADMIN` and `NET_RAW`), `make e2e-kind CNI=kindnet|calico|cilium` (deletes and recreates the kind cluster), or `make e2e-k3d` where kind is missing (a throwaway k3d cluster, IPv4). `FILTER='<test name>'` runs only the matching checks after a fresh setup. On Ubuntu hosts whose AppArmor profiles cover `wg`/`wg-quick`, run `sudo aa-teardown` first.
- Writing a check: one `@test` per check, named for what it proves; restore anything you break in the test's own teardown, so the next test starts healthy; wait on the condition (`wait_until`), not a fixed sleep; give every sensor a positive control. Add the threat to the table in ARCHITECTURE.md.
- Upgrades and mutants: `make e2e-upgrade [CLUSTER=k3d]` (the last release tag, upgraded to your chart) and `make mutation` (each firewall rule turned off must fail the Docker suite; slow, `LINES=` picks some). A new rule in `files/firewall.sh` needs a check that fails without it, or a line in `tests/e2e/mutation-baseline.txt` saying which rule already covers it.
- Images: Renovate proposes new image builds once they are 14 days old; the Transmission image and `appVersion` come in one PR.
- CI: the `ci-passed` job passes only when every test job passed; make it the required check (a skipped job counts as passed).

## Code of Conduct
Be respectful and constructive. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) if present.

## Issues
If you find a bug or have a feature request, please open an issue with details and steps to reproduce.

---

Happy contributing!
