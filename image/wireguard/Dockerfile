# syntax=docker/dockerfile:1
# The chart's WireGuard sidecar: wg-quick and the tools the kill switch
# (files/firewall.sh, mounted by the chart) runs, nothing else. No init
# system, no package manager and no busybox network clients at run time.
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

# iptables on nf_tables, as wg-quick's own rules (nft) are: one backend.
# openresolv: wg-quick needs resolvconf for a DNS line in wg0.conf.
# libnatpmp: natpmpc, for VPN port forwarding.
RUN apk add --no-cache \
      bash \
      iproute2 \
      iptables \
      nftables \
      wireguard-tools-wg \
      wireguard-tools-wg-quick \
      openresolv \
      libnatpmp \
    && rm -rf /sbin/apk /etc/apk /lib/apk /usr/share/apk /var/cache/apk \
    && for a in nc wget telnet ftpget ftpput tftp whois nslookup traceroute traceroute6 ping ping6 udhcpc udhcpc6 ntpd; do \
         for d in /bin /sbin /usr/bin /usr/sbin; do [ ! -L "$d/$a" ] || rm "$d/$a"; done; \
       done

COPY --chmod=0755 init /init

# The chart runs "firewall.sh apply && exec /init" as the command.
ENTRYPOINT ["/init"]
