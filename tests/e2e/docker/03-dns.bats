#!/usr/bin/env bats
# With the tunnel up: name resolution and other UDP go through the VPN, not
# to a resolver next to the pod.

load helpers

setup_file() { ensure_healthy; }
teardown() { dump_logs_if_failed; }

@test "the pod resolves only through the configured nameserver, like dnsPolicy None" {
  local resolvers
  resolvers=$(as_app sed -n 's/^nameserver[[:space:]]*//p' /etc/resolv.conf | tr '\n' ' ')
  [[ $resolvers == "$TUN_SERVER " ]] || fail "the pod's resolv.conf is '$resolvers', not the configured nameserver (test broken)"
}

@test "DNS-port traffic leaves through the VPN" {
  local seen
  seen=$(dns_seen_retry TUNNELED TUNNELED2)
  [[ $seen == "$SERVER_IP" ]] || fail "DNS-port traffic did not go through the VPN (canary saw '${seen:-nothing}')"
}

@test "IPv6 DNS-port traffic leaves through the VPN" {
  local seen
  seen=$(dns_seen_retry TUNNELED6 TUNNELED62 6)
  [[ $seen == "$SERVER_IP6" ]] || fail "IPv6 DNS-port traffic did not go through the VPN (canary saw '${seen:-nothing}')"
}

@test "UDP to another port leaves through the VPN" {
  local seen
  seen=$(dns_seen_retry TUNNELEDDHT TUNNELEDDHT2 4 6881)
  [[ $seen == "$SERVER_IP" ]] || fail "UDP to another port did not go through the VPN (canary saw '${seen:-nothing}')"
}
