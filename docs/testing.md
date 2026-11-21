# Testing

CI tests every change, and every week, on these combinations (`.github/workflows/helm-chart.yaml`):

| Kubernetes | Helm | CNI | Also |
|---|---|---|---|
| 1.29 | 3.14 | kindnet | the oldest supported versions |
| 1.32 | 3.22 | Calico | |
| 1.34 | 4.3 | Cilium | |
| 1.37 | 3.22 | kindnet | upgrade from the last release |
| 1.37 | 4.3 | kindnet | fresh install, upgrade from the last release, the privileged sidecar, sysctls set for the pod, and on arm64 |

The kill switch itself is also tested on Docker: on amd64 with a privileged and an unprivileged sidecar, and on arm64. The minimal Transmission image runs the cluster suite on amd64 and arm64.

## Running the tests

- `make lint`: `helm lint`, the helm-unittest suites in `tests/`, `tests/schema-test.sh` (the schema refuses typos and bad addresses) `tests/metadata-test.sh` (`appVersion` is the default Transmission version) and `tests/package-test.sh` (the package holds the whole chart and nothing else, never a local `wg0.conf` or values file).
- `make e2e-docker`: a bats suite (`tests/e2e/docker/`) that builds a dual-stack Pod-like network namespace in Docker with the chart's images and scripts, a WireGuard server and a canary, then tries to leak over IPv4 and IPv6: sockets bound to `eth0`, UDP (DNS and another port), ICMP, Transmission's own tracker announces, a deleted `wg0`, sidecar restarts and SIGKILL, tampered and flushed rules, packets marked by a stray mangle rule or re-routed by a nat rule, duplicating nft rules, unsafe configs. Every leak probe must be refused or time out, and every canary counts the packets that arrive from the pod's own address, so a leak fails the test however the client saw it; a probe that can't run fails the test too. Needs Docker with kernel WireGuard.
- `make e2e-kind CNI=kindnet|calico|cilium`: creates a kind cluster with that CNI (kindnet dual-stack, with IPv6 checks) and runs the cluster suite (`tests/e2e/cluster/`) there. It adds start order, kubelet probes, pod DNS, UDP, the Service, `helm test` against a healthy and a tampered pod, the NetworkPolicy holding with the in-pod kill switch verifiably flushed, a refused `existingSecret` keeping Transmission from starting, a downloads PVC, and pod termination (Transmission must exit 0 within the grace period). CI also validates the rendered chart against the cluster's API server. The leak checks run first without the NetworkPolicy, so they test the in-pod kill switch alone. It installs the chart's defaults; `SIDECAR=privileged` installs the privileged sidecar (`wireguard.unprivileged.enabled=false`), and `SIDECAR=unprivileged` sets its sysctls for the pod (`sysctls: pod`; the cluster scripts allow them on the kubelet). Delete the cluster afterwards with `kind delete cluster`.
- `make e2e-k3d`: the cluster suite on a throwaway k3d cluster (k3s's own CNI and NetworkPolicy controller, IPv4 only), for a local run without kind. It leaves your other k3d clusters and `~/.kube/config` alone.
- `make e2e-upgrade [CLUSTER=k3d]`: installs the last release, upgrades it to this chart and runs the cluster suite on the upgraded release.
- `make mutation`: turns off each firewall rule in turn and runs the Docker suite, which must fail every time. The few rules in `tests/e2e/mutation-baseline.txt` are exempt, each with its reason: another rule already covers every packet they match.

Each check is one named bats test. In CI a skipped check fails the job unless its reason is expected for that run (`tests/e2e/junit-check.sh`): no upgrade, no IPv6 on an IPv4-only cluster, the other sidecar mode's router advertisement check, or Transmission sending no shutdown announce, a path a later check forces. A suite builds its environment once; every test leaves it healthy, so one failure does not hide the next. `FILTER='<name>'` runs only the matching checks, after a fresh setup, for example `make e2e-docker FILTER='UDP leaves'`. CI shows each failed check by name in the run's summary and keeps the JUnit report. [ARCHITECTURE.md](../ARCHITECTURE.md#threats-and-the-tests-that-cover-them) maps each threat to the tests that cover it.

CI runs on every pull request, on pushes to `dev` and `main`, and weekly:
- **The Docker suite:** on amd64 and arm64, and once with the sidecar unprivileged (`make e2e-docker SIDECAR=unprivileged`).
- **The cluster suite, on kind:**
  - on Kubernetes 1.29 (the oldest the chart supports) up to 1.37;
  - on kindnet, Calico and Cilium;
  - with Helm 3 and Helm 4;
  - with the default sidecar (sysctls from an init container), and once each with the privileged sidecar and with sysctls set for the pod (dual-stack);
  - as an upgrade from the last release, with Helm 3 and with Helm 4.
- **The mutation test:** weekly with every mutant; on pull requests only the mutants on lines they change in `files/firewall.sh`, or all of them if the Docker suite changes.
