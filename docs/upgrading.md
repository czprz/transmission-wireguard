# Upgrading

Upgrade with your values file, or with `--reset-then-reuse-values` (Helm 3.14+). `--reuse-values` keeps only your old values and drops new defaults, which makes upgrades fail. Always pass `--version`.

Installs older than 1.0 should read [Upgrading to 1.0](#upgrading-to-10) first: 1.0 turned the kill switch on unconditionally and refuses several old settings.

## Upgrading to 1.1

- **The sidecar image is now the chart's own `ghcr.io/czprz/twg-wireguard`** (see [docs/images.md](images.md)) instead of `linuxserver/wireguard`. Nothing to do unless you override `images.wireguard`. To keep the linuxserver image (or a mirror of it), set `repository`, `tag` and `digest` together, as [docs/images.md](images.md#keeping-the-linuxserver-sidecar) shows. A `repository` without a `tag`, or a linuxserver `tag` without a `repository`, is refused, since the chart's default tag only exists for its own image. A `digest` alone (say the linuxserver one) is looked up in `ghcr.io/czprz/twg-wireguard` and won't be found: remove it, or set the repository and tag with it. `wireguard.env` (`TZ`, `PUID`, `PGID`) is only read by the linuxserver image.
- **`wireguard.env` may only set `TZ`, `PUID` and `PGID`.** The sidecar runs as root with `NET_ADMIN` and its command and probes are bash, which runs code from variables such as `BASH_ENV`: any other key is refused.
- **`wireguard.unprivileged` is stricter**: besides `NET_ADMIN` and `NET_RAW` the sidecar drops every capability, can't escalate privileges and uses the runtime's seccomp profile. `wireguard.unprivileged.sysctls: initContainer` sets its sysctls from a short privileged init container instead of the pod's `securityContext`, so the kubelet needn't allow them.
- **RPC credentials set in `transmission.settings`** (`rpc-username`/`rpc-password`, the pre-1.0 way) now go into the chart's RPC Secret instead of the ConfigMap and the pod spec. `transmission.rpcAuth` is still the place for them.
- **The pod rolls on an `rpcAuth` change only with an inline `wireguard.wg0Conf`.** The RPC Secret's checksum is now hashed with the WireGuard Secret, so it can't be used to guess the password offline; with `wireguard.existingSecret` there is nothing secret to hash it with, so it's left out: restart the pod (`kubectl rollout restart`) after changing `rpcAuth`.
- **A `tunnel-address` init container** (the sidecar image) now copies only the `Address` lines of `wg0.conf` for the Transmission image's init container, which no longer gets the private key.
- **New options**: `nameOverride`/`fullnameOverride`, `commonLabels`, Service `nodePort`, `externalTrafficPolicy`, `loadBalancerClass`, `loadBalancerSourceRanges` and IP families, `serviceAccountName`, `transmission.extraEnv`, `probes.liveness`/`probes.startup`, `persistence.annotations`/`labels`, `httpRoute` (Gateway API) and `images.transmission.flavor: minimal`. Resource names and selectors are unchanged.
- **Values that used to render the wrong thing are refused**: `persistence.type` other than `pvc`/`hostPath`, an Ingress without hosts, an issuer with neither an Ingress nor an HTTPRoute, and a download, incomplete or watch directory on no volume. An Ingress host without `paths` now routes the whole host.
- **A ClusterIssuer's default name** now has the namespace in it (`<namespace>-<release>-transmission-wireguard-issuer`). Helm replaces the old one on upgrade: certificates it issued stay valid, and renewals use the new one. Set `issuer.name` to the old name to keep it.

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
  **If Helm 4 installed the release**, add `--server-side=false` to this one upgrade: `helm upgrade <release> <chart> --server-side=false ...`. Without it the upgrade fails with `spec.strategy.rollingUpdate: Forbidden`, because Helm 4's server-side apply leaves the old strategy's settings in place. Releases installed with Helm 3 upgrade as usual, with Helm 3 or 4. CI runs both upgrades.
- **`rpc-host-whitelist-enabled` is now `true`.** The Service name and ingress hosts are allowed automatically. If you reach the UI under another name (Gateway API, an external proxy, a Tailscale name), add it to `transmission.settings.rpc-host-whitelist` or you get HTTP 421.
- **`transmission.settings.rpc-port` must equal `service.webPort`**, and `peer-port-random-on-start` must be `false`.
- **Peer ports are off the Service.** `service.exposePeerPorts`, `peerPortTcp` and `peerPortUdp` are gone; peers connect through the VPN (forward a port at your provider and set `peer-port`).
- **Host mounts are off**: `wireguard.kernelMode.mountLibModules` and `mountTun` default to `false` (kernel WireGuard is built into Linux 5.6+).
- **`wireguard.handshakeMaxAgeSeconds` defaults to 300**: a tunnel without a handshake for 5 minutes is restarted (only with `PersistentKeepalive` in `wg0.conf`). Set 0 to turn it off.
- **A missing `MTU` is refused on jumbo-frame networks** (the route to the endpoint has an MTU above 1500). Add `MTU = 1420` to `wg0.conf`.
- **The web UI listens on `::`** (IPv4 and IPv6), falling back to `0.0.0.0` in pods without IPv6. Set `transmission.settings.rpc-bind-address` to keep the old behaviour.
- **The PVC is kept on `helm uninstall`** (`persistence.keepOnUninstall: true`), so downloads survive it; delete the PVC yourself, or set it to `false`.
- **The pod opts out of Istio and Linkerd** (injection annotations, and the ambient label `istio.io/dataplane-mode: none`): a mesh proxy can't reach its control plane through the kill switch. Override them in `podAnnotations`/`podLabels` if you must.
- **Transmission now stops cleanly.** The image stops it through its RPC with `USER`/`PASS`, which the chart never set, so with RPC auth every shutdown waited out the grace period and ended in a kill (exit 137) without Transmission saving its state. The chart now sets them from `transmission.rpcAuth` (so they can't be set in `transmission.env`), and `terminationGracePeriodSeconds` is 60 (was Kubernetes' 30) for a slow shutdown with many torrents.
- **The chart is published at `oci://ghcr.io/czprz/transmission-wireguard`** (the repository moved from `dever-labs`).
- **`persistence.downloads`** puts `/data` on a PVC of its own. It's off by default; see [Storage](../README.md#storage) before turning it on for an existing install.
