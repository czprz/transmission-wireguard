# shellcheck shell=bash
# The leak tests' tools image, for the WireGuard server, the canaries and the
# probes, shared by the Docker and cluster suites. They need wg, iptables,
# bash and OpenBSD nc, so it is the full linuxserver image, not the chart's
# minimal sidecar (that one is tested as the sidecar). Renovate bumps it.
# shellcheck disable=SC2034 # used by the files that source this one
TOOLS_IMAGE=ghcr.io/linuxserver/wireguard:1.0.20260223-r0-ls126@sha256:6bcf5d2f5a265c7e9835eaadd989938e681aabe8bf8bcd4556b61d463da6555c
