# syntax=docker/dockerfile:1
# The chart's minimal Transmission image (images.transmission.flavor:
# minimal): transmission-daemon and the web UI, run as an ordinary user
# with a read-only root filesystem. No init system, no package manager and
# no root at run time. Besides the daemon it keeps busybox (the chart's
# scripts and probes), jq (the init container composes settings.json), and
# curl and OpenBSD netcat (nc -4/-6 -u; busybox's lacks -4/-6), as in the
# linuxserver image: the leak tests (helm test, tests/e2e) probe TCP and UDP
# from this container. The kill switch, not missing tools, keeps
# traffic in the tunnel.
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

# Transmission 4.1.x from Alpine: the weekly rebuild takes its fixes, but
# never a new minor version without a change here.
ARG TRANSMISSION_MINOR=4.1
RUN apk add --no-cache \
      "transmission-daemon~${TRANSMISSION_MINOR}" \
      jq \
      curl \
      netcat-openbsd \
    && rm -rf /sbin/apk /etc/apk /lib/apk /usr/share/apk /var/cache/apk \
    && for a in nc wget telnet ftpget ftpput tftp whois nslookup traceroute traceroute6 ping ping6 udhcpc udhcpc6 ntpd; do \
         for d in /bin /sbin /usr/bin /usr/sbin; do [ ! -L "$d/$a" ] || rm "$d/$a"; done; \
       done \
    && addgroup -g 1000 twg \
    && adduser -D -H -u 1000 -G twg -h /config -s /sbin/nologin twg

# The chart runs it as transmission.env PUID/PGID (default 1000:1000); the
# init container makes /config and /data theirs.
USER 1000:1000
ENV HOME=/config
EXPOSE 9091 51413/tcp 51413/udp
# SIGTERM stops it cleanly: it saves resume data and sends the "stopped"
# announces before it exits.
ENTRYPOINT ["transmission-daemon", "--foreground", "--config-dir", "/config"]
