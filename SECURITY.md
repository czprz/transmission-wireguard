# Security policy

This chart's purpose is that Transmission's traffic leaves only through the WireGuard tunnel. Anything that lets a packet out another way is a security bug, as is anything that exposes the WireGuard key or the web UI's credentials.

## Reporting a vulnerability

Report it privately through [GitHub's vulnerability reporting](https://github.com/czprz/transmission-wireguard/security/advisories/new), not in a public issue. Include the chart version, the values you used (without keys or passwords), the CNI and Kubernetes version, and how you saw the traffic (a packet capture, a canary, the leak tests).

You can expect a first answer within a week. A confirmed leak is fixed in a patch release, with a leak test that fails without the fix, and the advisory is published once that release is out.

## Supported versions

Only the latest release gets fixes. Upgrade to it before reporting, if you can.

## In scope

- Traffic from the pod outside the tunnel: while it starts, runs, restarts or stops, when the tunnel or its rules are gone, or for any protocol or address family.
- Ways for Transmission's container to change the pod's networking or the kill switch.
- The WireGuard private key or the RPC credentials ending up anywhere but their Secrets and the pod.

## Out of scope

These are documented limits, not bugs (see [Security notes](README.md#security-notes)):

- Anyone who can `kubectl exec` into the WireGuard sidecar, or add an ephemeral container to the pod, can open the kill switch.
- The node, its kernel and the container runtime are trusted.
- What the VPN provider sees.
- Vulnerabilities in the Transmission or WireGuard images themselves: report those upstream. The chart pins them by digest and updates them as fixes appear.
