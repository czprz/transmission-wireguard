# transmission-wireguard

Run Transmission through a WireGuard client sidecar in the same Pod. This chart is designed for public repos: keep private WireGuard configs in a Kubernetes Secret, not in Git.

## What this chart does

- Runs `linuxserver/wireguard` as a native sidecar and `linuxserver/transmission` in one Pod
- Installs a kill switch in the Pod's network namespace **before** the tunnel starts: traffic can only leave through WireGuard, and a crashed or restarting tunnel fails closed
- Starts Transmission only after the kill switch and tunnel are up
- Adds an egress NetworkPolicy so the CNI only lets the Pod reach the VPN server, even if the in-pod firewall were removed
- Resolves DNS through the tunnel, binds Transmission's peer sockets to the tunnel address, and keeps the web UI unreachable from the VPN side
- Creates a Transmission `settings.json` from values

## Requirements

- Kubernetes 1.29+ (native sidecar containers)
- Helm 3
- Linux 5.6+ on the nodes (kernel WireGuard)
- A CNI that enforces NetworkPolicy (Calico, Cilium, ...) for the second layer of protection
- cert-manager (optional, only if you enable the issuer template)

## Install

1) Create the WireGuard secret (recommended)

```bash
kubectl create secret generic wg-client \
  --from-file=wg0.conf=/path/to/wg0.conf
```

2) Create a values override file

```yaml
wireguard:
  existingSecret: wg-client
  # The Endpoint from wg0.conf, for the egress NetworkPolicy.
  endpoints:
    - ip: 203.0.113.10
      port: 51820
  dns:
    nameservers:
      - 10.64.0.1   # your VPN provider's resolver

transmission:
  rpcAuth:
    existingSecret: transmission-rpc   # keys: username, password

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: transmission.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - hosts:
        - transmission.example.com
      secretName: transmission-ingress-tls
```

3) Install

```bash
helm install transmission ./transmission-wireguard -f values.yaml
```

## WireGuard config notes

The sidecar refuses to start (and the chart refuses to render an inline `wg0Conf`) unless:

- `Endpoint` is an IP address. DNS is blocked until the tunnel is up.
- `AllowedIPs` includes `0.0.0.0/0` (and `::/0` for IPv6): full tunnel only.
- There are **no** `iptables`/`nft` commands in `PreUp`/`PostUp`/`PreDown`/`PostDown`. The chart owns the kill switch. The old recommended `PreDown = iptables -P OUTPUT ACCEPT; iptables -F OUTPUT` opened the firewall on every tunnel restart while Transmission kept running.

`PersistentKeepalive = 25` is recommended. A `DNS =` line is optional; the pod uses `wireguard.dns.nameservers`.

Example `wg0.conf` (redact your private key before sharing):

```ini
[Interface]
PrivateKey = <REDACTED>
Address = 10.64.0.2/32

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.10:51820
PersistentKeepalive = 25
```

## How traffic is kept in the tunnel

| Layer | What it does |
|---|---|
| Kill switch (`files/firewall.sh`) | Runs in the WireGuard sidecar before `wg-quick`. IPv4 and IPv6 default to DROP; only `wg0`, WireGuard's own encrypted packets (by fwmark) and replies to connections that arrived from the cluster may leave. Inbound: peers on `peer-port` via `wg0`, the web UI from `firewall.webAllowedCIDRs` outside the tunnel. Nothing in the tunnel lifecycle removes these rules. |
| Start order | WireGuard is a native sidecar with a startup probe; Transmission is not started until the kill switch and `wg0` are up. |
| Probes | Sidecar liveness fails if the rules are altered or `wg0` is gone, and a restart re-applies the rules. Optional handshake-age check (`wireguard.handshakeMaxAgeSeconds`). Transmission's liveness fails if `wg0` disappears. |
| NetworkPolicy | Egress only to `wireguard.endpoints` on UDP. Enforced by the CNI outside the pod. |
| DNS | `dnsPolicy: None` with `wireguard.dns.nameservers`, reached through the tunnel. Cluster DNS would forward your lookups upstream from the node. |
| Transmission | Peer sockets bound to the tunnel address (`bindToTunnel`), Local Peer Discovery and UPnP/NAT-PMP off, peer ports not on the Service. |

## Transmission settings

Transmission settings are rendered into `settings.json` on startup. A good way to build a baseline is:

1) Run Transmission once.
2) Export its generated `settings.json`.
3) Paste the fields you want into `values.yaml` under `transmission.settings`.

Official docs:
- https://github.com/transmission/transmission/blob/main/docs/Editing-Configuration-Files.md
- https://github.com/transmission/transmission/blob/main/docs/Configuration-Files.md

## Persistence

The chart supports PVC or hostPath. For public repos, the defaults are commented out in `values.yaml`. Uncomment and configure what fits your cluster.

## Ingress and cert-manager issuer

Use ingress only if you plan to expose the Transmission web UI outside the cluster.
If ingress is disabled, there is no need for cert-manager or an issuer.

cert-manager setup guide: https://cert-manager.io/docs/installation/

You can let the chart create an Issuer/ClusterIssuer for cert-manager:

```yaml
ingress:
  enabled: true
  className: nginx

issuer:
  enabled: true
  kind: Issuer # or ClusterIssuer
  email: you@example.com
```

If you already have an issuer, leave `issuer.enabled` false and reference your issuer in `ingress.annotations`.

## Security notes

- `replicaCount` should remain 1 unless each replica has unique storage and WireGuard config.
- Keep `wg0.conf` in a Secret, not in Git.
- The web UI requires RPC credentials (`transmission.rpcAuth`) when exposed through an ingress or a non-ClusterIP Service. They are read from a Secret into a read-only `settings.json`, never stored in the ConfigMap.
- The WireGuard sidecar is privileged by default because `wg-quick` sets `net.ipv4.conf.all.src_valid_mark`. If your kubelet allows that sysctl, set it in `podSecurityContext.sysctls` and use `wireguard.securityContext: {privileged: false, capabilities: {add: [NET_ADMIN, NET_RAW]}}`.
- Default images are pinned by digest.

## Verify egress IP

```bash
kubectl exec -it deploy/<release>-transmission-wireguard -c transmission -- \
  sh -c 'wget -qO- https://ifconfig.io || true'
```

To check that the kill switch holds, delete the tunnel interface. The request must time out instead of returning your real IP; the sidecar's liveness probe then restarts it:

```bash
kubectl exec deploy/<release>-transmission-wireguard -c wireguard -- ip link del wg0
kubectl exec deploy/<release>-transmission-wireguard -c transmission -- \
  sh -c 'wget -T 5 -qO- https://ifconfig.io || echo blocked'
```

## Testing

- `make lint`: `helm lint` and the helm-unittest suites in `tests/`.
- `make e2e-docker`: builds a Pod-like network namespace in Docker with the chart's images and scripts, a WireGuard server and a canary, then tries to leak: sockets bound to `eth0`, DNS-port traffic, a deleted `wg0`, sidecar restarts and SIGKILL, a flushed firewall, unsafe configs. Needs Docker with kernel WireGuard.
- `make e2e-kind`: the same idea on a kind cluster (`kind create cluster` first), plus start order, kubelet probes, pod DNS, the Service, and the NetworkPolicy holding with the in-pod kill switch flushed.

CI runs both on every pull request.

## Values overview

See `values.yaml` for the full list of configuration options.

[![CI](https://github.com/dever-labs/transmission-wireguard/actions/workflows/helm-main.yml/badge.svg)](https://github.com/dever-labs/transmission-wireguard/actions/workflows/helm-main.yml)

---

> **Quickstart**
>
> 1. Create your WireGuard secret:
>    ```bash
>    kubectl create secret generic wg-client --from-file=wg0.conf=/path/to/wg0.conf
>    ```
> 2. Copy and edit `values.yaml` for your needs.
> 3. Install:
>    ```bash
>    helm install transmission ./transmission-wireguard -f values.yaml
>    ```
> 4. [Verify egress IP](#verify-egress-ip) to confirm VPN routing.

---

# User & Contributor Guide

- See [ARCHITECTURE.md](ARCHITECTURE.md) for a diagram and explanation of how the chart works.
- See [CONTRIBUTING.md](CONTRIBUTING.md) if you want to help improve this chart.
- For troubleshooting and advanced usage, see below.

# Troubleshooting

- **Pod stuck in `Init` / sidecar crash-looping?**
  - `kubectl logs <pod> -c wireguard` shows `[twg-firewall] FATAL: ...` when `wg0.conf` is refused (hostname endpoint, split tunnel, firewall hooks).
  - Without a handshake, check that `wireguard.endpoints` matches the `Endpoint` line (the NetworkPolicy only allows that address).
- **Web UI unreachable?**
  - The source (ingress controller, kubelet) must be in `firewall.webAllowedCIDRs`, and in `networkPolicy.ingressFrom` if you set it.
- **DNS failures?**
  - Lookups go to `wireguard.dns.nameservers` through the tunnel. Use a resolver your VPN allows (usually the provider's).
  - Cluster-internal names do not resolve from this pod, by design.
- **Multiple replicas?**
  - Not recommended unless each replica has unique storage and config.
- **PVC/hostPath issues?**
  - Check your storage class and access modes.

# Advanced Usage

- **Custom environment variables:**
  - You can add extra environment variables for both containers under `transmission.env` and `wireguard.env` in `values.yaml`.
- **Resource limits and scheduling:**
  - Set `resources`, `nodeSelector`, `affinity`, and `tolerations` in `values.yaml` for advanced scheduling.
- **Customizing settings.json:**
  - See the Transmission docs linked above for all available settings.
