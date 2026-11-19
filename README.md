# transmission-wireguard

[![CI](https://github.com/czprz/transmission-wireguard/actions/workflows/helm-main.yml/badge.svg)](https://github.com/czprz/transmission-wireguard/actions/workflows/helm-main.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/czprz/transmission-wireguard/blob/main/LICENSE)

A Helm chart that runs [Transmission](https://transmissionbt.com/) behind a WireGuard client sidecar in the same Pod, with a kill switch: Transmission's traffic can only leave through the VPN, and if the tunnel goes down, it is blocked, not leaked. Keep your WireGuard config in a Kubernetes Secret, not in Git.

## How it works

- The chart's own minimal WireGuard image ([`ghcr.io/czprz/twg-wireguard`](#images)) runs as a native sidecar next to Transmission.
- It installs a kill switch in the Pod's network namespace **before** the tunnel starts. Traffic can only leave through WireGuard, and a crashed or restarting tunnel fails closed.
- Transmission starts only once the kill switch and the tunnel are up.
- An egress NetworkPolicy lets the Pod reach only the VPN server, even if the in-pod firewall were removed.
- DNS goes through the tunnel. Transmission's peer sockets are bound to the tunnel address, and the web UI is unreachable from the VPN side.
- Transmission's `settings.json` is written from your values.

| Layer | What it does |
|---|---|
| Kill switch ([`files/firewall.sh`](https://github.com/czprz/transmission-wireguard/blob/main/files/firewall.sh)) | Runs in the WireGuard sidecar before `wg-quick`. IPv4 and IPv6 default to DROP; only `wg0`, WireGuard's own encrypted packets (by fwmark, and only as UDP to the `Endpoint` addresses) and the web UI's replies to `firewall.webAllowedCIDRs` may leave. The final decision is made in mangle `POSTROUTING`, on the interface a packet really leaves by, so nat rules, marks or nft chains that re-route a packet can't get it out `eth0`. Inbound: peers on `peer-port` via `wg0`, the web UI from `firewall.webAllowedCIDRs` outside the tunnel. Nothing in the tunnel lifecycle removes these rules. |
| Start order | WireGuard is a native sidecar with a startup probe; Transmission is not started until the kill switch and `wg0` are up. |
| Probes | Sidecar liveness fails if the rules are altered, `wg0` is gone or a packet socket is open in the pod, and a restart re-applies the rules. Optional handshake-age check (`wireguard.handshakeMaxAgeSeconds`). Transmission's liveness fails when the tunnel address exists but Transmission isn't listening for peers on it. |
| NetworkPolicy | Egress only to `wireguard.endpoints` on UDP. Enforced by the CNI outside the pod. |
| DNS | `dnsPolicy: None` with `wireguard.dns.nameservers`, reached through the tunnel. Cluster DNS would forward your lookups upstream from the node. |
| Transmission | Peer sockets always bound to the tunnel address (loopback for a family the tunnel lacks), Local Peer Discovery and UPnP/NAT-PMP off, peer ports not on the Service, no network capabilities. |

The threats each part covers, and the tests that prove it, are in [ARCHITECTURE.md](https://github.com/czprz/transmission-wireguard/blob/main/ARCHITECTURE.md).

## Requirements

- Kubernetes 1.29+ (native sidecar containers)
- Helm 3.14+ or Helm 4
- Linux 5.6+ on the nodes (kernel WireGuard)
- A CNI that enforces NetworkPolicy (Calico, Cilium, ...) for the second layer of protection
- A namespace at the `privileged` Pod Security level: the sidecar is privileged, or adds `NET_ADMIN`, and both are outside `baseline`. In a `baseline` or `restricted` namespace the pod is never created, and the reason only shows in the ReplicaSet's events.
- cert-manager, only if you let the chart create an issuer

[docs/testing.md](https://github.com/czprz/transmission-wireguard/blob/main/docs/testing.md) lists the Kubernetes, Helm and CNI combinations CI tests.

## Quick start

1. **A namespace** where privileged pods may run:

   ```bash
   kubectl create namespace transmission
   kubectl label namespace transmission pod-security.kubernetes.io/enforce=privileged
   ```

2. **The WireGuard config**, from your VPN provider (see [Preparing wg0.conf](#preparing-wg0conf)), as a Secret with a single `wg0.conf` key:

   ```bash
   kubectl -n transmission create secret generic wg-client --from-file=wg0.conf=/path/to/wg0.conf
   ```

3. **The web UI's credentials** (required unless you set `transmission.rpcAuth.allowAnonymous: true`):

   ```bash
   kubectl -n transmission create secret generic transmission-rpc \
     --from-literal=username=admin \
     --from-literal=password="$(openssl rand -base64 24)"
   ```

4. **A values file**, `my-values.yaml`:

   ```yaml
   wireguard:
     existingSecret: wg-client
     # The Endpoint line of wg0.conf, for the egress NetworkPolicy.
     endpoints:
       - ip: 203.0.113.10
         port: 51820
     dns:
       nameservers:
         - 10.2.0.1   # your VPN provider's resolver (see Provider notes)

   transmission:
     rpcAuth:
       existingSecret: transmission-rpc   # keys: username, password

   persistence:
     size: 50Gi
   ```

5. **Install** a released version (see [Releases](https://github.com/czprz/transmission-wireguard/releases)):

   ```bash
   VERSION=1.1.0
   helm install transmission oci://ghcr.io/czprz/transmission-wireguard --version "$VERSION" \
     -n transmission -f my-values.yaml
   ```

   > [!WARNING]
   > Always pass `--version`, so you install, and later upgrade to, exactly the version you read the notes for. Versions before 1.0 are still in the registry, and they have no kill switch.

6. **Open the web UI.** It isn't exposed outside the cluster until you [set that up](#exposing-the-web-ui); until then:

   ```bash
   kubectl -n transmission port-forward svc/transmission-transmission-wireguard 9091
   ```

   and open <http://localhost:9091/transmission/web/>.

7. **Check for leaks** with the chart's test, from inside the cluster:

   ```bash
   helm upgrade transmission oci://ghcr.io/czprz/transmission-wireguard --version "$VERSION" \
     -n transmission --reset-then-reuse-values --set tests.enabled=true
   helm test transmission -n transmission --logs
   ```

   It checks that the kill switch is intact and the tunnel is up, that `eth0` is closed, that Transmission holds no network capabilities and that DNS uses only your nameservers. See [Verifying the egress path](#verifying-the-egress-path).

From a clone of this repository, install the working tree instead: put your values in `values.local.yaml` (it's gitignored) and run `make install`, or `helm install transmission . -n transmission -f values.local.yaml`.

## Preparing wg0.conf

Download a WireGuard config from your VPN provider. The sidecar refuses to start unless:

- `Endpoint` is an IP address with a port, not a hostname: DNS is blocked until the tunnel is up.
- `AllowedIPs` includes `0.0.0.0/0` (add `::/0` for IPv6). Only a full tunnel works: `0.0.0.0/1, 128.0.0.0/1` doesn't count, because `wg-quick` only sets up its fwmark routing for `/0`.
- With an IPv6 range in `AllowedIPs`, `Address` has an IPv6 address too. Otherwise IPv6 would enter the tunnel with the pod's own address. Without IPv6 ranges, IPv6 is blocked.
- There is no `Table =` line, and `FwMark`, if set, equals `firewall.wgFwmark` (51820).
- There are **no** `PreUp`/`PostUp`/`PreDown`/`PostDown` hooks: the chart owns the kill switch, and hooks run as root with `NET_ADMIN`. (`firewall.allowConfHooks: true` allows them, if you really need one that never touches the firewall or routing.)
- On networks with jumbo frames (AWS VPC CNI's 9001, for example), there is an `MTU = 1420` line.

`PersistentKeepalive = 25` is recommended, and the handshake check needs it. A `DNS =` line is optional: the pod uses `wireguard.dns.nameservers`, so put your provider's resolver there. The default, Cloudflare's `1.1.1.1`, works through the tunnel but means Cloudflare sees your lookups.

```ini
[Interface]
PrivateKey = <PRIVATE_KEY>
Address = 10.2.0.2/32, fd00::2/128   # IPv4-only config? Then drop ::/0 below.
DNS = 10.2.0.1

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.10:51820
PersistentKeepalive = 25
```

**A Secret, or inline?** With `wireguard.existingSecret` (above) the chart never sees the config: set `wireguard.endpoints` by hand, and only the sidecar checks the rules. With `wireguard.wg0Conf` in a private, gitignored values file, the chart parses the endpoints itself, checks the config when it renders, and rolls the pod when it changes. After editing an `existingSecret`, restart the pod yourself: `kubectl -n transmission rollout restart deploy/transmission-transmission-wireguard`.

### Provider notes

Checked in late 2026; providers change these, so confirm with yours.

| Provider | `wireguard.dns.nameservers` | Port forwarding | Notes |
|---|---|---|---|
| Proton VPN | `10.2.0.1` | NAT-PMP: `wireguard.portForwarding.natpmpGateway: 10.2.0.1`, on a P2P server, with NAT-PMP enabled when you create the config | |
| Mullvad | `10.64.0.1` | None (removed in 2023) | Its configs have an IPv4 and an IPv6 `Address` |
| AirVPN | `10.128.0.1` | A fixed port from the client area: set `transmission.settings.peer-port` to it | Its configs have a `PresharedKey`, which rules out `wireguard.failover`; pick an IP endpoint, not a hostname |
| IVPN | `172.16.0.1` | None (removed in 2023) | Pick an IP endpoint in the config generator |

### Port forwarding

Without an inbound port, peers can't connect to you, and seeding suffers.

**NAT-PMP** (Proton VPN, among others):

```yaml
wireguard:
  portForwarding:
    natpmpGateway: 10.2.0.1   # the gateway inside the tunnel
```

The sidecar's liveness probe renews the mapping every 30 seconds, opens just that port on `wg0`, and sets it as Transmission's peer port over RPC on loopback, so announces carry it. A gateway that doesn't answer is logged and retried; downloads still work without a forwarded port. A gateway that offers the web UI's port is refused. NAT-PMP is IPv4 only and needs the chart's sidecar image (the default).

**A fixed port** from your provider (AirVPN, for example): set `transmission.settings.peer-port` to it. The kill switch accepts peers on that port through `wg0` only.

### Failover to other servers

A VPN account's key usually works on all of its provider's servers. List others, and the sidecar switches to the next when the current one stops answering:

```yaml
wireguard:
  failover:
    afterSeconds: 180   # at least 180, less than handshakeMaxAgeSeconds
    peers:
      - publicKey: "<ANOTHER_SERVER_PUBLIC_KEY>"
        ip: 198.51.100.20
        port: 51820
```

Once the current server's last handshake is `afterSeconds` old, the liveness probe replaces the peer with the next in the list, and after the last with `wg0.conf`'s again. Only `PublicKey` and `Endpoint` change, so Transmission keeps its bindings. The kill switch and the NetworkPolicy let WireGuard reach every listed server and nothing else. It needs `PersistentKeepalive` and a single `[Peer]` without `PresharedKey`; a failover takes 3 to 4 minutes.

## Exposing the web UI

The web UI is at `/transmission/web/` on the Service's port 9091. Anything that reaches it from outside the tunnel must come from `firewall.webAllowedCIDRs` (the private ranges by default, which cover ingress controllers and Gateways in the cluster).

### Ingress, with cert-manager

```yaml
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: transmission.example.com   # all paths by default
  tls:
    - hosts:
        - transmission.example.com
      secretName: transmission-ingress-tls

# Optional: let the chart create a Let's Encrypt issuer for it.
issuer:
  enabled: true
  kind: Issuer   # or ClusterIssuer
  email: you@example.com
```

With an issuer of your own, leave `issuer.enabled` off and reference it in `ingress.annotations` (`cert-manager.io/cluster-issuer: <name>`). See the [cert-manager docs](https://cert-manager.io/docs/installation/).

### Gateway API

With a Gateway API implementation (Envoy Gateway, Cilium, Istio, NGINX Gateway Fabric, ...) attach an `HTTPRoute` to your Gateway:

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: public
      namespace: gateway-system
      sectionName: https
  hostnames:
    - transmission.example.com
```

TLS is configured on the Gateway's listener. `httpRoute.matches` (default: every path) and `httpRoute.filters` shape the route's one rule. With `issuer.enabled` and no Ingress, the issuer solves HTTP-01 challenges with a route on the same Gateways; that needs cert-manager's Gateway API support turned on, and the `cert-manager.io/issuer` annotation on the Gateway.

### LoadBalancer or NodePort

```yaml
service:
  type: LoadBalancer
  loadBalancerSourceRanges: [192.168.1.0/24]   # who may reach it
  externalTrafficPolicy: Local                 # keeps the clients' own addresses...
firewall:
  webAllowedCIDRs: [192.168.1.0/24, 10.0.0.0/8]  # ...so allow them here too
```

The ingress hosts and HTTPRoute hostnames are added to Transmission's `rpc-host-whitelist`. Under any other name (an external proxy, a Tailscale name), with RPC auth off, add it to `transmission.settings.rpc-host-whitelist`, or you get HTTP 421.

## Storage

By default the chart creates a 10Gi `ReadWriteOnce` PVC with the cluster's default storage class. It holds `/config` and `/data`, so size it for your downloads. Set `persistence.storageClassName`, `existingClaim`, or `type: hostPath` with `hostPath.path` to change that. `persistence.annotations` and `labels` go on the chart's PVCs, for a backup tool's opt-in, for example.

For a new install, give the downloads a PVC of their own, so a full download disk can't stop Transmission from saving its config and resume files:

```yaml
persistence:
  downloads:
    enabled: true
    size: 500Gi
    # storageClassName: bulk
    # existingClaim: media
```

It's off by default because on an existing install it would hide the downloads already on the main volume: copy them over first.

To keep downloads on an NFS or SMB share, add it under `extraVolumes` and mount it with `transmission.extraVolumeMounts`:

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

`persistence.mounts.data.mountPath` moves the data volume (default `/data`); the download, incomplete and watch directories move with it. A directory on no volume is refused, since its files would be lost on restart.

## Transmission settings

`transmission.settings` becomes Transmission's `settings.json` (see Transmission's [configuration files](https://github.com/transmission/transmission/blob/main/docs/Editing-Configuration-Files.md)). Add only the keys you want to change. Don't paste a whole exported `settings.json`, since the chart owns some keys:

- `bind-address-ipv4` and `bind-address-ipv6` are refused: they are always the tunnel address.
- `rpc-port` must equal `service.webPort`, and `peer-port-random-on-start` must be `false` (the kill switch only accepts peers on the fixed `peer-port`).
- The web UI's credentials belong in `transmission.rpcAuth`; the chart sets `rpc-username`, `rpc-password` and `rpc-authentication-required` from it.

**Changes made in the web UI (Edit > Preferences) or with `transmission-remote` are lost when the pod restarts.** Transmission runs with a read-only `settings.json` that the init container writes at every start. Put such changes in `transmission.settings`. Per-torrent state (the torrent list, priorities, progress) is in `/config` on the volume and survives restarts.

## Images

- **Sidecar:** `ghcr.io/czprz/twg-wireguard` (from [`image/wireguard`](https://github.com/czprz/transmission-wireguard/tree/main/image/wireguard)): `wg-quick`, iptables/nftables, iproute2, `resolvconf` and `natpmpc`, no init system, package manager or busybox network clients.
- **Transmission:** `lscr.io/linuxserver/transmission` by default. With `images.transmission.flavor: minimal`, the chart's own non-root image (`ghcr.io/czprz/twg-transmission`, from [`image/transmission`](https://github.com/czprz/transmission-wireguard/tree/main/image/transmission)) runs Transmission with no capabilities and a read-only root filesystem; until the chart pins a published digest, set its `tag` or `digest`.

Default images are pinned by digest; overriding `repository` or `tag` drops the default digest, so set `digest` too. Both of the chart's images are scanned on every change, rebuilt weekly for Alpine's fixes, signed with cosign and have a build provenance attestation. [docs/images.md](https://github.com/czprz/transmission-wireguard/blob/main/docs/images.md) has the details: keeping the linuxserver sidecar, the minimal image's ownership handling, and verification commands.

### Verifying the chart

Releases from 1.0.0 on are signed with Sigstore (keyless, with the identity of the release workflow on main) and carry a build provenance attestation; the package is also attached to its [GitHub release](https://github.com/czprz/transmission-wireguard/releases), whose notes give its digest. With cosign 2.6 or later (older versions can't read the signature's format and report "no signatures found"):

```bash
VERSION=1.1.0
cosign verify ghcr.io/czprz/transmission-wireguard:$VERSION \
  --certificate-identity-regexp '^https://github\.com/czprz/transmission-wireguard/\.github/workflows/helm-release\.yml@refs/heads/main$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
gh attestation verify oci://ghcr.io/czprz/transmission-wireguard:$VERSION --repo czprz/transmission-wireguard
```

## Verifying the egress path

`helm test` checks a running release from inside the cluster (enable it with `tests.enabled: true`, as in the Quick start). It runs on the release pod's node and checks:

- the kill switch rules are intact and the tunnel is up, in every running pod of the release (read-only: it runs the sidecar's `firewall.sh status`);
- the Transmission container holds no `NET_RAW`, `NET_ADMIN` or `SYS_ADMIN` capability at runtime, whatever a webhook added;
- a socket bound to `eth0` can't reach the Kubernetes API, though the test pod can;
- the pod uses only `wireguard.dns.nameservers`;
- optionally, that the public address the pod gets from `tests.ipEchoUrl` differs from the cluster's own, and is one of `tests.vpnEgressIPs`. Only point `tests.ipEchoUrl` at an echo endpoint you run yourself: it sees your VPN address and your real address side by side.

While the test runs, a temporary Role lets the test pod exec into pods in the namespace; Helm deletes it afterwards. The test is off by default because tools that deploy with `helm template` (kustomize `helmCharts`, some GitOps setups) ignore hook annotations and would create that Role permanently; leave it off there, or render with `--skip-tests`.

By hand: a request bound to `eth0` must fail with curl exit 7 (refused) or 28 (timed out); exit 0 would be a leak.

```bash
kubectl -n transmission exec deploy/transmission-transmission-wireguard -c transmission -- sh -c \
  'h=$KUBERNETES_SERVICE_HOST; case $h in *:*) h="[$h]" ;; esac
   curl -sk -m 5 -o /dev/null --interface "if!eth0" "https://$h:$KUBERNETES_SERVICE_PORT/version"; echo "curl exit $?"'
```

## Monitoring

With the Prometheus Operator, kube-state-metrics and the kubelet's volume stats scraped (kube-prometheus-stack does all three), `monitoring.prometheusRule.enabled: true` adds alerts:

| Alert | When |
|---|---|
| `TransmissionWireguardTunnelDown` | The sidecar has not been ready for `tunnelDownFor` (5m): the kill switch, `wg0` or wg-quick's policy routing is not in place. Nothing leaks then; Transmission's traffic just stops. |
| `TransmissionWireguardUnavailable` | No pod has been available for `unavailableFor` (10m). |
| `TransmissionWireguardRestarting` | Containers restarted more than `restartsPer30m` (2) times in 30 minutes, which is also how a VPN server that stopped answering shows. |
| `TransmissionWireguardVolumeFilling` | One of the release's PVCs has less than `volumeFreeRatio` (10%) free. |

Set `monitoring.prometheusRule.labels` to what your Prometheus selects rules by (`release: kube-prometheus-stack`, for example). Nothing in the pod serves metrics: an exporter would need a port through the kill switch.

## Security model

- `replicaCount` must be 1: replicas would share one WireGuard key.
- The web UI requires RPC credentials (`transmission.rpcAuth`) unless `allowAnonymous` is set. They stay in a Secret and reach Transmission only through its read-only `settings.json`.
- The WireGuard sidecar is privileged by default, because `wg-quick` sets `net.ipv4.conf.all.src_valid_mark`. `wireguard.unprivileged.enabled` runs it with only `NET_ADMIN` and `NET_RAW` (every other capability dropped, RuntimeDefault seccomp). Its sysctls are set either in the pod's `securityContext` (`sysctls: pod`; the kubelet must allow them with `--allowed-unsafe-sysctls`), or by a short privileged init container (`sysctls: initContainer`; no kubelet change). On IPv6 pod networks add `blockRouterAdvertisements: true`, so router advertisements can't add IPv6 routes past the tunnel.
- `wireguard.env` may only set `TZ`, `PUID` and `PGID`: the sidecar's shell would run code from others (`BASH_ENV`, ...).
- Transmission runs without network capabilities. The chart refuses a `transmission.securityContext` that is missing, privileged, doesn't drop `ALL`, or adds anything beyond file and user capabilities. Root in that container could otherwise bypass the kill switch: `NET_RAW` alone allows `SO_MARK` and raw sockets on `eth0`. With `images.transmission.flavor: minimal` it has no capabilities at all and never runs as root.
- Anyone who can `kubectl exec` into the sidecar is root with `NET_ADMIN` there and can open the kill switch. So can anyone who can add an ephemeral container, which shares the pod's network namespace, with any profile that keeps the runtime's default `NET_RAW` (a packet socket on `eth0` skips netfilter). The kill switch's check fails while any packet socket is open in the pod, so the sidecar turns unready and the tunnel-down alert fires, but it can't stop one. Limit `pods/exec` and `pods/ephemeralcontainers` in the namespace.
- `tests.enabled` adds a Role that lets the test pod exec into any pod in the namespace while `helm test` runs. An interrupted test can leave it behind: `kubectl delete role,rolebinding,serviceaccount -l app.kubernetes.io/instance=<release>`.

Report security problems as [SECURITY.md](https://github.com/czprz/transmission-wireguard/blob/main/SECURITY.md) describes.

## FAQ

**How do Sonarr, Radarr and other \*arr apps connect?** Point them at host `transmission-transmission-wireguard.transmission.svc` (`<release>-transmission-wireguard.<namespace>.svc`), port 9091, URL base `/transmission/`, with the RPC credentials. The Service's names are already in `rpc-host-whitelist`. They need the downloads on the same volume (an `existingClaim` that both mount, `ReadWriteMany` if on different nodes) or a remote path mapping.

**Why are my preferences gone after a restart?** Settings live in `transmission.settings`; changes in the web UI are lost on restart (see [Transmission settings](#transmission-settings)).

**Can I use another web UI (Flood for Transmission, Transmissionic, ...)?** Mount its files with `extraVolumes` and `transmission.extraVolumeMounts`, and point Transmission at them with `transmission.extraEnv: [{name: TRANSMISSION_WEB_HOME, value: <mount path>}]`.

**How do I run a second instance?** Install another release, with its own WireGuard config (or key) and storage. Replicas aren't supported.

**Does it work in a service mesh?** The chart opts the pod out of Istio (sidecar and ambient) and Linkerd: a mesh proxy can't reach its control plane through the kill switch.

**What are the resources called?** `<release>-transmission-wireguard`; `fullnameOverride` replaces that. `nameOverride` replaces the second part, and the `app.kubernetes.io/name` label in the Deployment's immutable selector, so set it at install only.

## Uninstall

```bash
helm uninstall transmission -n transmission
```

The PVCs are kept, so your downloads survive (`persistence.keepOnUninstall`). Delete them when you're done with the data: `kubectl -n transmission delete pvc -l app.kubernetes.io/instance=transmission`. A finished `helm test` pod (`<release>-transmission-wireguard-test`) is also left behind; delete it with `kubectl delete pod`.

## More

- [Upgrading](https://github.com/czprz/transmission-wireguard/blob/main/docs/upgrading.md): what changed in each release, and what to do before upgrading.
- [Troubleshooting](https://github.com/czprz/transmission-wireguard/blob/main/docs/troubleshooting.md): a pod stuck in `Init`, a sidecar restarting, an unreachable web UI, ...
- [Configuration](https://github.com/czprz/transmission-wireguard/blob/main/values.yaml): every option, documented in `values.yaml`; `values.schema.json` refuses unknown keys and bad values.
- [Contributing](https://github.com/czprz/transmission-wireguard/blob/main/CONTRIBUTING.md) and [testing](https://github.com/czprz/transmission-wireguard/blob/main/docs/testing.md).

## License

[MIT](https://github.com/czprz/transmission-wireguard/blob/main/LICENSE)
