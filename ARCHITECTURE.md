# transmission-wireguard Architecture

```mermaid
graph TD
  subgraph Pod["Pod (one network namespace)"]
    INIT[transmission-settings init] --> WG
    WG["WireGuard native sidecar<br/>1. firewall.sh apply<br/>2. wg-quick up"] -- startupProbe passes --> TX[Transmission]
  end
  Secret[wg0.conf Secret] --> WG
  Secret --> INIT
  RPC[RPC credentials Secret] --> INIT
  ConfigMap[settings ConfigMap] --> INIT
  INIT -- read-only settings.json --> TX
  TX -- persistent data --> PVC[PersistentVolumeClaim]
  Ingress[Ingress / Service] -- web UI 9091 --> TX
  WG -- UDP to VPN endpoint only --> NP{{NetworkPolicy}} --> VPN[(VPN server)]
```

- Both containers share one network namespace, so the kill switch and the tunnel apply to Transmission.
- `files/firewall.sh` installs default-deny iptables/ip6tables rules in that namespace before `wg-quick` runs. The namespace outlives container restarts, so the rules do too; `wg-quick down` never touches them.
- Replies to connections that arrived from the cluster (kubelet probes, ingress) carry WireGuard's fwmark so `wg-quick`'s policy routing sends them out `eth0`; everything else is routed into `wg0` or rejected.
- The WireGuard container is a native sidecar (`initContainers` with `restartPolicy: Always`), so Transmission starts only after its startup probe confirms the kill switch and tunnel.
- `files/settings-init.sh` composes `settings.json` (chart settings, RPC credentials, bind address from `wg0.conf`) into a memory-backed volume mounted read-only.
- The NetworkPolicy is a second, independent layer enforced by the CNI outside the pod.
- Tests: `tests/*.yaml` (helm-unittest), `tests/e2e/netns-leak-test.sh` (Docker), `tests/e2e/kind-test.sh` (kind).
