#!/usr/bin/env bats
# Pod DNS, the cluster's own services (DNS, the Kubernetes API) out of reach
# via eth0 although an ordinary pod reaches them, and the web UI through the
# Service. NetworkPolicy off, as for the egress checks.

# shellcheck source=tests/e2e/cluster/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup_file() { set_netpol off; }
teardown() { dump_on_failure; }

@test "pod DNS uses the configured nameservers only" {
  local nameservers
  nameservers=$(kx transmission sed -n 's/^nameserver[[:space:]]*//p' /etc/resolv.conf | sort | tr '\n' ' ' || true)
  [[ $nameservers == "1.0.0.1 1.1.1.1 " ]] ||
    fail "pod nameservers are '${nameservers:-none}', want the configured 1.1.1.1 and 1.0.0.1"
  pass "pod DNS uses the configured nameservers only"
}

@test "cluster DNS unreachable from the pod via eth0 (reachable from an ordinary pod)" {
  local dns_ip r
  dns_ip=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')
  tcp_open ordinary_pod curl "telnet://$dns_ip:53" ||
    fail "baseline: cluster DNS not reachable from an ordinary pod (test broken)"
  # Bound to eth0, so a pass means the kill switch blocked it, not that the
  # query went into the tunnel and got lost there.
  r=$(tcp_eth0 "telnet://$dns_ip:53")
  case $r in
    blocked) pass "cluster DNS ($dns_ip) unreachable from the pod via eth0 (reachable from an ordinary pod)" ;;
    open) fail "LEAK: cluster DNS ($dns_ip) reachable from the pod via eth0" ;;
    *) fail "cluster DNS check via eth0 proves nothing ($r)" ;;
  esac
}

@test "a socket bound to eth0 cannot reach the Kubernetes API (reachable from an ordinary pod)" {
  local api_ip
  api_ip=$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
  ordinary_pod curl -sk -m 4 -o /dev/null "https://$api_ip/version" ||
    fail "baseline: the Kubernetes API is not reachable from an ordinary pod (test broken)"
  check_eth0 "the Kubernetes API (reachable from an ordinary pod)" "https://$api_ip/version"
}

@test "web UI reachable through the Service" {
  local code
  code=$(ordinary_pod curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://$RELEASE-transmission-wireguard:9091/transmission/web/" || true)
  # kubectl run -i can print the output twice (attach, then the logs).
  code=${code:0:3}
  [[ $code =~ ^(200|301|401|409)$ ]] || fail "web UI not reachable through the Service (HTTP '${code}')"
  pass "web UI reachable through the Service (HTTP $code)"
}
