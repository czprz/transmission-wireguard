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
- A namespace at the `privileged` Pod Security level: the sidecar is privileged, or adds `NET_ADMIN`, and both are outside `baseline`. In a `baseline` or `restricted` namespace the pod is never created, and the reason only shows in the ReplicaSet's events. Label the namespace: `kubectl label namespace <ns> pod-security.kubernetes.io/enforce=privileged`
- cert-manager (optional, only if you enable the issuer template)

## Install

1) Create the WireGuard secret (recommended)

```bash
kubectl create secret generic wg-client \
  --from-file=wg0.conf=/path/to/wg0.conf
```

The Secret should hold only `wg0.conf`; other keys are not mounted.

2) Create the web UI credentials (required unless you set `transmission.rpcAuth.allowAnonymous: true`)

```bash
kubectl create secret generic transmission-rpc \
  --from-literal=username=admin \
  --from-literal=password="$(openssl rand -base64 24)"
```

3) Create a values override file

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

4) Install

```bash
helm install transmission ./transmission-wireguard -f values.yaml
```

## WireGuard config notes

The sidecar refuses to start unless the following hold. The chart checks the same rules when it renders an inline `wg0Conf`; with `existingSecret` it can't see the config, so only the sidecar checks it.

- `Endpoint` is an IP address with a port. DNS is blocked until the tunnel is up.
- `AllowedIPs` includes `0.0.0.0/0` (add `::/0` for IPv6): full tunnel only. Splitting it into `0.0.0.0/1, 128.0.0.0/1` doesn't count, because `wg-quick` only sets up its fwmark routing for `/0`.
- With any IPv6 range in `AllowedIPs`, `Address` includes an IPv6 address. Otherwise IPv6 would enter the tunnel with the pod's own address as its source. Without IPv6 ranges, IPv6 is blocked.
- There is no `Table =` line, and `FwMark`, if set, equals `firewall.wgFwmark` (51820). The kill switch relies on `wg-quick`'s fwmark routing.
- Where the pod's network has jumbo frames (AWS VPC CNI's 9001, for example), there is an `MTU` line (`MTU = 1420`). Without one, `wg-quick` sizes the tunnel from the route to the endpoint, so the encrypted packets would be fragmented on the internet's 1500-byte paths, and many paths drop fragments. The sidecar refuses a missing `MTU` when that route's MTU is above 1500.
- There are **no** `PreUp`/`PostUp`/`PreDown`/`PostDown` hooks. The chart owns the kill switch. Hooks run as root with `NET_ADMIN`, so any of them, directly or through a script, could open it. The old recommended `PreDown = iptables -P OUTPUT ACCEPT; iptables -F OUTPUT` opened the firewall on every tunnel restart while Transmission kept running. If you really need a hook, set `firewall.allowConfHooks: true` and make sure it never touches the firewall or routing.

The kill switch lets WireGuard's own packets out only as UDP to the `Endpoint` addresses in `wg0.conf`. If the server moves to another address mid-session ("roaming", which VPN providers practically never do), the tunnel stops instead of following it. The sidecar's handshake check (`wireguard.handshakeMaxAgeSeconds`, 300 by default) then restarts it, which goes back to the `Endpoint`.

`PersistentKeepalive = 25` is recommended, and the handshake check only runs with it: without keepalives an idle tunnel stops handshaking. A `DNS =` line is optional; the pod uses `wireguard.dns.nameservers`, so copy your provider's resolver there. The default (Cloudflare `1.1.1.1`) is reached through the tunnel but means Cloudflare sees your lookups.

Changes to an inline `wg0Conf` or `rpcAuth.username`/`password` roll the pod on `helm upgrade`. With `existingSecret`, restart it yourself after editing the Secret: `kubectl rollout restart deploy/<release>-transmission-wireguard`. Kubernetes updates the mounted Secret in the running pod, and a sidecar restart reads it. If its `Address` changed, the sidecar refuses to start until the pod restarts, because Transmission is still bound to the old addresses.

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
| Kill switch (`files/firewall.sh`) | Runs in the WireGuard sidecar before `wg-quick`. IPv4 and IPv6 default to DROP; only `wg0`, WireGuard's own encrypted packets (by fwmark, and only as UDP to the `Endpoint` addresses) and the web UI's replies to `firewall.webAllowedCIDRs` may leave. The final decision is made in mangle `POSTROUTING`, on the interface a packet really leaves by, so nat rules, marks or nft chains that re-route a packet can't get it out `eth0`. Inbound: peers on `peer-port` via `wg0`, the web UI from `firewall.webAllowedCIDRs` outside the tunnel. Nothing in the tunnel lifecycle removes these rules. |
| Start order | WireGuard is a native sidecar with a startup probe; Transmission is not started until the kill switch and `wg0` are up. |
| Probes | Sidecar liveness fails if the rules are altered or `wg0` is gone, and a restart re-applies the rules. Optional handshake-age check (`wireguard.handshakeMaxAgeSeconds`: 0, or at least 180, since WireGuard re-handshakes only every 2 minutes). Transmission's liveness fails when the tunnel address exists but Transmission isn't listening for peers on it: it binds once at start, so after starting while the tunnel was down it would never accept a peer again. |
| NetworkPolicy | Egress only to `wireguard.endpoints` on UDP. Enforced by the CNI outside the pod. |
| DNS | `dnsPolicy: None` with `wireguard.dns.nameservers`, reached through the tunnel. Cluster DNS would forward your lookups upstream from the node. |
| Transmission | Peer sockets always bound to the tunnel address (loopback for a family the tunnel lacks), Local Peer Discovery and UPnP/NAT-PMP off, peer ports not on the Service, no network capabilities. |

## Upgrading to 1.0

1.0 turns the kill switch on unconditionally and changes several defaults. Upgrade with `--reset-then-reuse-values` (Helm 3.14+) or your values file. `--reuse-values` keeps only your old values and drops the new defaults, so the upgrade fails with a nil pointer error. Before upgrading:

- **Kubernetes 1.29+** is required (native sidecars).
- **Remove hooks from `wg0.conf`.** `PreUp`/`PostUp`/`PreDown`/`PostDown` lines (earlier versions of this README recommended `iptables` ones) are refused. `firewall.allowConfFirewallHooks` is now `firewall.allowConfHooks`.
- **Set `wireguard.endpoints`** when using `existingSecret`. The egress NetworkPolicy needs the VPN server's IP and port. If your CNI doesn't enforce NetworkPolicy, set `networkPolicy.enabled: false` instead.
- **DNS** now goes through the tunnel to `wireguard.dns.nameservers`. Set your VPN provider's resolver. `dns.override: false` is refused: cluster DNS can't be reached through the tunnel.
- **`transmission.securityContext` must drop `ALL` capabilities.** Only harmless ones may be added back (the default `SETUID`, `SETGID`, `CHOWN` are fine). A `null` securityContext is refused, since the runtime's defaults include `NET_RAW`.
- **`firewall.wgFwmark`** must be between 1 and 4294967295. It is also wg-quick's routing table, so 253-255 and 1000 are refused, and any value other than 51820 needs the same `FwMark` line in `wg0.conf`.
- **`wg0.conf` needs an IPv4 `Address`** (with `0.0.0.0/0`, traffic would otherwise carry the pod's own IPv4 address into the tunnel).
- **`wireguard.wg0Conf` and `wireguard.existingSecret` can't both be set**, nor `rpcAuth.existingSecret` with `rpcAuth.username`/`password`.
- **RPC auth in `transmission.settings` needs `rpc-authentication-required: true`** as a boolean; the string `"false"` (or `"true"`) no longer counts.
- **Capabilities are dropped with `ALL`.** `CAP_ALL` drops nothing at runtime and is refused; `DAC_READ_SEARCH` can no longer be added back.
- **RPC auth** is required, also for a ClusterIP-only UI: without it any pod in the cluster can add torrents (with trackers it controls, linking them to your VPN address) or set a script to run. Move `rpc-username`/`rpc-password` from `transmission.settings` to `transmission.rpcAuth` (settings still work), or set `rpcAuth.allowAnonymous: true`.
- **Unknown values are refused.** The schema rejects keys it doesn't know (a typo such as `wireguard.dns.nameserver` used to be ignored silently), nameservers that aren't IPs and `webAllowedCIDRs` that aren't CIDRs.
- **Peer sockets are always bound to the tunnel.** `bindToTunnel: false` and `bind-address-ipv4`/`-ipv6` in `transmission.settings` are refused; `peer-port` must differ from `service.webPort`.
- **IPv6 in the tunnel needs a tunnel IPv6 address.** Any IPv6 range in `AllowedIPs` (`::/0`, `0::/0`, `2000::/3`, ...) without an IPv6 `Address` is refused (the pod's own IPv6 address would reach the VPN); drop the IPv6 ranges to block IPv6 instead.
- **`replicaCount` must be 1**, `firewall.wgFwmark` must not set bit `0x10000000`, and the old `service.peerPortTcp`/`peerPortUdp` are refused.
- **An RPC Secret with an empty username or password** stops the pod instead of leaving the web UI open.
- **`TWG_*` variables and the image's server mode** (`PEERS`, `SERVERURL`, ...) are refused in `wireguard.env` / `transmission.env`.
- **The Deployment uses `strategy: Recreate`**, so an upgrade never runs two pods on one WireGuard key; expect a short gap.
- **`rpc-host-whitelist-enabled` is now `true`.** The Service name and ingress hosts are allowed automatically. If you reach the UI under another name (Gateway API, an external proxy, a Tailscale name), add it to `transmission.settings.rpc-host-whitelist` or you get HTTP 421.
- **`transmission.settings.rpc-port` must equal `service.webPort`**, and `peer-port-random-on-start` must be `false`.
- **Peer ports are off the Service.** `service.exposePeerPorts`, `peerPortTcp` and `peerPortUdp` are gone; peers connect through the VPN (forward a port at your provider and set `peer-port`).
- **Host mounts are off**: `wireguard.kernelMode.mountLibModules` and `mountTun` default to `false` (kernel WireGuard is built into Linux 5.6+).
- **`wireguard.handshakeMaxAgeSeconds` defaults to 300**: a tunnel without a handshake for 5 minutes is restarted (only with `PersistentKeepalive` in `wg0.conf`). Set 0 to turn it off.
- **A missing `MTU` is refused on jumbo-frame networks** (the route to the endpoint has an MTU above 1500). Add `MTU = 1420` to `wg0.conf`.
- **The web UI listens on `::`** (IPv4 and IPv6), falling back to `0.0.0.0` in pods without IPv6. Set `transmission.settings.rpc-bind-address` to keep the old behaviour.
- **The PVC is kept on `helm uninstall`** (`persistence.keepOnUninstall: true`), so downloads survive it; delete the PVC yourself, or set it to `false`.
- **The pod opts out of Istio and Linkerd** (injection annotations, and the ambient label `istio.io/dataplane-mode: none`): a mesh proxy can't reach its control plane through the kill switch. Override them in `podAnnotations`/`podLabels` if you must.
- **`terminationGracePeriodSeconds` is 60** (was Kubernetes' 30), so Transmission can save resume data and send its "stopped" announces.
- **The chart is published at `oci://ghcr.io/czprz/transmission-wireguard`** (the repository moved from `dever-labs`).

## Transmission settings

Transmission settings are rendered into `settings.json` on startup. A good way to build a baseline is:

1) Run Transmission once.
2) Export its generated `settings.json`.
3) Paste the fields you want into `values.yaml` under `transmission.settings`.

Official docs:
- https://github.com/transmission/transmission/blob/main/docs/Editing-Configuration-Files.md
- https://github.com/transmission/transmission/blob/main/docs/Configuration-Files.md

## Persistence

The chart supports PVC or hostPath. By default it creates a 10Gi `ReadWriteOnce` PVC with the cluster's default storage class; set `persistence.storageClassName`, `existingClaim`, or `type: hostPath` with `hostPath.path` to change that. It holds both `/config` and `/data`, so size it for your downloads. `helm uninstall` keeps the chart's PVC (`persistence.keepOnUninstall`); delete it yourself when you're done with the data.

To keep downloads on another volume (an NFS or SMB share, a second PVC), add it under `extraVolumes` and mount it in the Transmission container with `transmission.extraVolumeMounts`:

```yaml
extraVolumes:
  - name: media
    nfs:
      server: nas.example.internal
      path: /media
transmission:
  extraVolumeMounts:
    - name: media
      mountPath: /data/complete
```

`podAnnotations`, `podLabels`, `imagePullSecrets`, `priorityClassName` and `terminationGracePeriodSeconds` apply to the pod as usual.

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

- `replicaCount` must be 1: replicas would share one WireGuard key.
- Keep `wg0.conf` in a Secret, not in Git.
- The web UI requires RPC credentials (`transmission.rpcAuth`) unless `allowAnonymous` is set. They are read from a Secret into a read-only `settings.json`, never stored in the ConfigMap.
- The WireGuard sidecar is privileged by default because `wg-quick` sets `net.ipv4.conf.all.src_valid_mark`. If your kubelet allows that sysctl (`--allowed-unsafe-sysctls`), set it in `podSecurityContext.sysctls` and use `wireguard.securityContext: {privileged: false, capabilities: {add: [NET_ADMIN, NET_RAW]}}` (CI runs the Docker leak test this way too). An unprivileged sidecar can't write `/proc/sys`, so it can't stop IPv6 router advertisements from adding routes past the tunnel. Nothing leaks then, but IPv6 can stop working; the sidecar logs a warning. Allow and set `net.ipv6.conf.eth0.accept_ra_pinfo` and `net.ipv6.conf.eth0.accept_ra_rt_info_max_plen` to `0` as well to close that.
- Transmission runs without network capabilities. The chart refuses a `transmission.securityContext` that is missing, privileged, doesn't drop `ALL`, or adds anything beyond file and user capabilities (`CHOWN`, `SETUID`, `SETGID`, `DAC_OVERRIDE`, `FOWNER`, ...). Root in that container (the image's init, `kubectl exec`) could otherwise bypass the kill switch: `NET_RAW` alone allows `SO_MARK` and raw sockets on `eth0`.
- Anyone who can `kubectl exec` into the WireGuard sidecar is root with `NET_ADMIN` there and can open the kill switch. So can anyone who can add an ephemeral container (`kubectl debug --profile=netadmin` or `sysadmin`), which shares the pod's network namespace. Limit `pods/exec` and `pods/ephemeralcontainers` in the namespace.
- Default images are pinned by digest. Overriding `images.*.repository` or `tag` drops the default digest; set `images.*.digest` to keep pulls immutable.
- Inline `rpcAuth` credentials are hashed into a pod annotation (so changes roll the pod). Use a strong password, or `rpcAuth.existingSecret`.

## Verify egress IP

`helm test` checks a running release from inside the cluster. It is off by default, so enable it first:

```bash
helm upgrade <release> <chart> -n <namespace> --reset-then-reuse-values --set tests.enabled=true
helm test <release> -n <namespace> --logs
```

It runs on the release pod's node (egress addresses can differ per node) and checks:

- the kill switch rules are intact and the tunnel is up (in every running pod of the release);
- the Transmission container holds no `NET_RAW`, `NET_ADMIN` or `SYS_ADMIN` capability at runtime (raw sockets would bypass iptables), whatever a webhook added;
- a socket bound to `eth0` can't reach the Kubernetes API, though the test pod can (and, where the node has an IPv6 address, the kubelet over IPv6);
- the pod uses only `wireguard.dns.nameservers`;
- optionally, that the public address the pod gets from `tests.ipEchoUrl` differs from the cluster's own, the pod's and its node's addresses (IPv4, and IPv6 where the cluster has it), and that `eth0` can't reach it. Set `tests.vpnEgressIPs` to your VPN's exit addresses (IPv4, IPv6 or both) to require one of them per family; without it the test pod must land on the release pod's node.

While the test runs, a temporary Role lets the test pod exec into pods in the namespace. Helm deletes it after the run, pass or fail. The finished test pod stays until the next run so `--logs` can read it; `helm uninstall` leaves it behind, so delete it afterwards with `kubectl delete pod <release>-transmission-wireguard-test`. The test is off by default because tools that deploy with `helm template` (kustomize `helmCharts`, some GitOps setups) ignore hook annotations and would create that Role permanently. Leave it off there, or render with `--skip-tests`. By default the test contacts nothing outside the cluster. `tests.ipEchoUrl` is off by default because the echo endpoint sees your VPN address and your real address side by side; only set it to one you run yourself (any endpoint that answers with the caller's IP as plain text). Set `tests.enabled: false` to drop the test. A default-deny NetworkPolicy in the namespace must let the test pod reach the API server (and the echo endpoint, if set).

By hand, check that `eth0` is closed: a request bound to it must fail with curl exit 7 (refused) or 28 (timed out). The Kubernetes API answers any ordinary pod, so exit 0 would be a leak. Nothing outside the cluster is contacted:

```bash
kubectl exec deploy/<release>-transmission-wireguard -c transmission -- sh -c \
  'h=$KUBERNETES_SERVICE_HOST; case $h in *:*) h="[$h]" ;; esac
   curl -sk -m 5 -o /dev/null --interface "if!eth0" "https://$h:$KUBERNETES_SERVICE_PORT/version"; echo "curl exit $?"'
```

Comparing the pod's public address with the cluster's needs an IP echo endpoint; use `tests.ipEchoUrl` with one you run yourself, since a public one sees both addresses.

## Testing

- `make lint`: `helm lint`, the helm-unittest suites in `tests/`, `tests/schema-test.sh` (the schema refuses typos and bad addresses) and `tests/metadata-test.sh` (`appVersion` and Chart.yaml's image list match the default images).
- `make e2e-docker`: builds a dual-stack Pod-like network namespace in Docker with the chart's images and scripts, a WireGuard server and a canary, then tries to leak over IPv4 and IPv6: sockets bound to `eth0`, UDP (DNS and another port), ICMP, Transmission's own tracker announces, a deleted `wg0`, sidecar restarts and SIGKILL, tampered and flushed rules, packets marked by a stray mangle rule or re-routed by a nat rule, duplicating nft rules, unsafe configs. Every leak probe must be refused or time out, and every canary counts the packets that arrive from the pod's own address, so a leak fails the test however the client saw it; a probe that can't run fails the test too. Needs Docker with kernel WireGuard.
- `make e2e-kind CNI=kindnet|calico|cilium`: creates a kind cluster with that CNI (kindnet dual-stack, with IPv6 checks) and runs the same idea there. It adds start order, kubelet probes, pod DNS, UDP, the Service, `helm test` against a healthy and a tampered pod, the NetworkPolicy holding with the in-pod kill switch verifiably flushed, a refused `existingSecret` keeping Transmission from starting, and pod termination. The leak checks run first without the NetworkPolicy, so they test the in-pod kill switch alone. Delete the cluster afterwards with `kind delete cluster`.

CI runs the Docker test on amd64 and arm64 (and once with the sidecar unprivileged, `make e2e-docker SIDECAR=unprivileged`) and the kind test with each CNI, on every pull request and on pushes to `dev` and `main`.

## Values overview

See `values.yaml` for the full list of configuration options.

[![CI](https://github.com/czprz/transmission-wireguard/actions/workflows/helm-main.yml/badge.svg)](https://github.com/czprz/transmission-wireguard/actions/workflows/helm-main.yml)

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
  - `kubectl logs <pod> -c wireguard` shows `[twg-firewall] FATAL: ...` when `wg0.conf` is refused (hostname endpoint, split tunnel, PreUp/PostUp/PreDown/PostDown hooks).
  - Without a handshake, check that `wireguard.endpoints` matches the `Endpoint` line (the NetworkPolicy only allows that address).
  - `FATAL: the route to the endpoint ... has MTU 9001`: add `MTU = 1420` to `[Interface]`.
  - `FATAL: Address in ... changed since the pod started`: restart the pod (`kubectl rollout restart`).
- **Pod never created?**
  - `kubectl describe rs` shows `violates PodSecurity`: the namespace needs the `privileged` Pod Security level (see Requirements).
  - `exceeded quota` or `must specify limits`: set the `resources` (and `transmission.initResources`) your ResourceQuota requires.
- **Pod never Ready in a service mesh?**
  - The chart opts the pod out of Istio (sidecar and ambient) and Linkerd. A mesh whose injection ignores those annotations and labels can't work through the kill switch.
- **Web UI unreachable?**
  - The source (ingress controller, kubelet) must be in `firewall.webAllowedCIDRs`, and in `networkPolicy.ingressFrom` if you set it.
  - A LoadBalancer or NodePort that keeps the client's source address (some cloud load balancers do; the chart doesn't set `externalTrafficPolicy`) shows public client IPs, which the default private ranges don't cover. Add your clients' ranges, or use an ingress. The same applies to global (non-ULA) IPv6 pod CIDRs.
  - HTTP 421 means the hostname isn't in `rpc-host-whitelist`.
- **DNS failures?**
  - Lookups go to `wireguard.dns.nameservers` through the tunnel. Use a resolver your VPN allows (usually the provider's).
  - Cluster-internal names do not resolve from this pod, by design.
- **Multiple replicas?**
  - Not supported: `replicaCount` must be 1. Install another release, with its own storage and WireGuard config, for a second instance.
- **`Permission denied` from `wg`, `wg-quick` or `readlink` in the sidecar log?**
  - Recent Ubuntu hosts ship AppArmor profiles that attach to those binaries by path, and they apply inside containers too, privileged or not. Check with `sudo aa-status` on the node; disable the offending profile (`sudo aa-disable <profile>`) or use a node image without it.
- **PVC/hostPath issues?**
  - Check your storage class and access modes.

# Advanced Usage

- **Custom environment variables:**
  - You can add extra environment variables for both containers under `transmission.env` and `wireguard.env` in `values.yaml`.
- **Resource limits and scheduling:**
  - Set `resources`, `nodeSelector`, `affinity`, and `tolerations` in `values.yaml` for advanced scheduling.
- **Customizing settings.json:**
  - See the Transmission docs linked above for all available settings.
