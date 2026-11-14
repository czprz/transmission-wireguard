# Contributing to transmission-wireguard

Thank you for considering contributing! Here are some guidelines to help you get started:

## How to Contribute
- Fork the repository and create your branch from `main`.
- Make your changes with clear, descriptive commit messages.
- If adding a feature, update documentation and add tests if possible.
- Run `make lint` and `make test` (or see below for manual steps) before submitting a PR.
- Open a pull request and describe your changes.

## Development
- A dev container (`.devcontainer/`) ships Helm, ct, kubeconform, yq, helm-unittest and Docker at the versions CI uses, plus the Claude Code, Codex and GitHub Copilot CLIs (logins persist across rebuilds). Open the repo in VS Code and choose "Reopen in Container", or use GitHub Codespaces.
- Lint the chart: `helm lint . --strict`
- Run tests: `docker run --rm -v "${PWD}:/apps" helmunittest/helm-unittest:3.11.1-0.3.0 .`
- Validate manifests: `ct lint --all --chart-dirs .`

## Code of Conduct
Be respectful and constructive. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) if present.

## Issues
If you find a bug or have a feature request, please open an issue with details and steps to reproduce.

---

Happy contributing!
