# transmission-wireguard

Run Transmission through a WireGuard client sidecar in the same Pod. This chart is designed for public repos: keep private WireGuard configs in a Kubernetes Secret, not in Git.

## What this chart does

- Runs `linuxserver/wireguard` and `linuxserver/transmission` in one Pod
- Mounts a WireGuard client config as `wg0.conf`
- Optionally sets a DNS override so DNS queries go through the tunnel
- Creates a Transmission `settings.json` from values

## Requirements

- Kubernetes 1.19+
- Helm 3
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

- Use an IPv4 endpoint in `wg0.conf` (IPv6 endpoints can silently fail with wg-quick).
- Add a DNS line inside `wg0.conf` to avoid DNS leaks if your cluster DNS is blocked by a kill switch.
- If you change the nameservers in values, update the `DNS = ...` line in `wg0.conf` to match.
- Keep the `PostUp` and `PreDown` lines if you rely on the kill switch; removing them disables it.

Example `wg0.conf` (redact your private key before sharing):

```ini
[Interface]
PrivateKey = <REDACTED>
Address = 10.0.0.2/32
DNS = 1.1.1.1

# Optional kill switch example
PostUp = iptables -w -P OUTPUT DROP; iptables -w -A OUTPUT -o lo -j ACCEPT; iptables -w -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT; iptables -w -A OUTPUT -p udp -d <ENDPOINT_IP> --dport 51820 -j ACCEPT; iptables -w -A OUTPUT -o %i -j ACCEPT
PreDown = iptables -w -P OUTPUT ACCEPT; iptables -w -F OUTPUT

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
AllowedIPs = 0.0.0.0/0,::/0
Endpoint = <ENDPOINT_IP>:51820
```

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

## Verify egress IP

```bash
kubectl exec -it deploy/<release>-transmission-wireguard -c transmission -- \
  sh -c 'wget -qO- https://ifconfig.io || true'
```

## Values overview

See `values.yaml` for the full list of configuration options.
