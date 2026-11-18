# Images

Default images are pinned by digest. Overriding `images.*.repository` or `tag` drops the default digest; set `images.*.digest` to keep pulls immutable. Verify signatures with cosign 2.6 or later.

## The WireGuard sidecar image

`image/wireguard` builds the sidecar's image: Alpine with `wg-quick`, iptables and nftables, iproute2, `resolvconf` and `natpmpc`, and nothing else. It has no init system, no package manager and no busybox network clients. Its `/init` brings `wg0` up and takes it down on stop; the kill switch, installed before that, stays either way.

Every change runs the Docker and cluster leak tests against it and scans it with Trivy (fixable HIGH and CRITICAL fail the build). Merges to main and a weekly rebuild, for Alpine's fixes, publish it to `ghcr.io/czprz/twg-wireguard` for amd64 and arm64. Each published image is signed with cosign and has a build provenance attestation:

```bash
cosign verify ghcr.io/czprz/twg-wireguard@sha256:<digest> \
  --certificate-identity-regexp '^https://github\.com/czprz/transmission-wireguard/\.github/workflows/sidecar-image\.yml@refs/heads/main$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

### Keeping the linuxserver sidecar

It is the chart's default sidecar image, pinned by digest, and Renovate proposes each rebuild. To keep the linuxserver image instead (it works with the kill switch, but has no `natpmpc` and brings s6, a package manager and busybox's network clients into the privileged container):

```yaml
images:
  wireguard:
    repository: ghcr.io/linuxserver/wireguard
    tag: 1.0.20260223-r0-ls126
    digest: sha256:6bcf5d2f5a265c7e9835eaadd989938e681aabe8bf8bcd4556b61d463da6555c
```

## The minimal Transmission image

The default Transmission image is `lscr.io/linuxserver/transmission`. Its s6 init runs as root and then drops to `PUID`/`PGID`, so the container needs `SETUID`, `SETGID` and `CHOWN`. `image/transmission` builds a minimal alternative: Alpine's `transmission-daemon` (4.1.x) with the web UI, `jq`, and `curl` and OpenBSD `nc` for the leak tests, but no init system, package manager or other network clients. It runs as `PUID`/`PGID` from the start, with no capabilities, `runAsNonRoot` and a read-only root filesystem (`/tmp` is an `emptyDir`), and stops on `SIGTERM` by itself:

```yaml
images:
  transmission:
    flavor: minimal
    digest: sha256:<a published digest>   # or tag
```

The chart's init container still runs as root, with only `CHOWN`. It writes `settings.json` and gives `PUID`/`PGID` the `/config` and `/data` mount points, plus the download, incomplete and watch directories `settings.json` names under them. It never changes ownership recursively, but it does change those directories' owner, including on a `hostPath` volume, so point `hostPath` at a tree meant for `PUID`/`PGID`. Volumes from `extraVolumeMounts` (an NFS share, say) are left alone: they must already be writable by `PUID`/`PGID`, since Transmission can't fix their ownership as a non-root user. Without persistence, `/data` is an `emptyDir`, because the root filesystem is read-only. Moving an existing install from the linuxserver image works if your files already belong to `PUID`/`PGID` (the linuxserver image keeps them that way). The minimal image follows Alpine's Transmission package, so its version can trail the linuxserver image's, which sets `appVersion`.

Every change scans it with Trivy and runs the cluster leak test with it as the Transmission container. Merges to main and a weekly rebuild publish it to `ghcr.io/czprz/twg-transmission` for amd64 and arm64, signed with cosign and with a build provenance attestation (verify it like the sidecar image, with `transmission-image.yml` in the identity regex). The chart doesn't pin it yet, so set its tag or digest.
