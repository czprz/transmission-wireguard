#!/usr/bin/env bats
# Pod termination; last, because it deletes the pod. Transmission stops
# before its sidecar, and the rules live as long as the pod's network
# namespace: nothing may leak while the pod shuts down. A loop inside the
# Transmission container probes until the container is gone; the canaries'
# counters see whatever it sent. The sidecar outlives Transmission, so a
# second loop in it covers its own shutdown (s6 runs wg-quick down) too.
# Runs with the NetworkPolicy off, so the kill switch alone has to hold
# through the shutdown (the policy would hide a failure). The shutdown
# happens once, in setup_file; each test judges one result of it.

# shellcheck source=tests/e2e/cluster/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

setup_file() {
  set_netpol off
  restore_release
  local term_probe c grace deleted took tx_exit line
  local -A term_log term_pid started
  term_probe="while :; do curl -sS -m 2 http://$CANARY_IP/cgi-bin/ip 2>/dev/null || echo blocked;"
  if ((IPV6)); then term_probe+=" curl -6 -sS -m 2 http://[$CANARY_IP6]/cgi-bin/ip 2>/dev/null || echo blocked;"; fi
  term_probe+=" sleep 0.5; done"
  for c in transmission wireguard; do
    term_log[$c]=$BATS_FILE_TMPDIR/probe-$c.log
    # Only stdout: kubectl reports the container's end on stderr. Not on
    # bats' fd 3, or bats waits for the loop.
    kx $c sh -c "$term_probe" >"${term_log[$c]}" 2>/dev/null 3>&- &
    term_pid[$c]=$!
    echo "$!" >>"$BATS_FILE_TMPDIR/probe.pids"
  done
  wait_until 30 probing "${term_log[transmission]}" "${term_log[wireguard]}" ||
    fail "the probe loops in the pod did not start"
  hits_mark nopod
  for c in transmission wireguard; do started[$c]=$(wc -l <"${term_log[$c]}"); done
  # A finalizer keeps the pod object after its containers end, so their exit
  # codes can be read; otherwise it is often gone before the kubelet's last
  # status update is seen.
  grace=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.terminationGracePeriodSeconds}')
  kubectl -n "$NS" patch pod "$POD" --type=merge -p "{\"metadata\":{\"finalizers\":[\"$HOLD\"]}}" >/dev/null
  deleted=$(date +%s)
  kubectl -n "$NS" delete pod "$POD" --wait=false >/dev/null
  STATES="" STOPPED=0
  if wait_until $((grace + 45)) stopped; then STOPPED=1; fi
  took=$(($(date +%s) - deleted))
  info "containers stopped after ${took}s (grace ${grace}s):$STATES"
  tx_exit=$(exit_code transmission)
  outcome stop stop_check "$tx_exit" "$took" "$grace"
  if ((took > grace / 2)); then
    kubelet_log $((grace + 120)) 2>/dev/null | grep -F "$POD" | grep -iE 'kill|grace|terminat|stop' | tail -n 15 |
      cut -c1-400 | sed 's/^/        kubelet: /' >&3 || true
  fi
  kubectl -n "$NS" patch pod "$POD" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null
  outcome deleted pod_deleted
  for c in transmission wireguard; do
    kill "${term_pid[$c]}" 2>/dev/null || true
    while read -r line; do
      line=$(tr -d '[:space:]' <<<"$line")
      case $line in
        blocked) record blocked ;;
        "$SERVER_IP" | "${SERVER_IP6:-none}") record vpn ;;
        *[0-9].*[0-9] | *:*) record "leak $line" ;; # an address
        *) ;; # a line cut off when the container was killed
      esac
    done < <(tail -n +$((started[$c] + 1)) "${term_log[$c]}")
  done
  outcome probes result_summary "while the pod terminates"
  outcome hits hits_check "while the pod terminates" nopod
}
# Both probe loops have written their first answer.
probing() { [[ -s $1 && -s $2 ]]; }
# Each container's exit code, once it has one, from STATES.
TERM_STATES='{range .status.containerStatuses[*]} {.name}={.state.terminated.exitCode}@{.state.terminated.finishedAt}{end}{range .status.initContainerStatuses[*]} {.name}={.state.terminated.exitCode}@{.state.terminated.finishedAt}{end}'
exit_code() { grep -o " $1=[0-9]*@" <<<"$STATES" | tr -dc '0-9' || true; }
stopped() {
  STATES=$(kubectl -n "$NS" get pod "$POD" -o jsonpath="$TERM_STATES" 2>/dev/null || true)
  [[ -n $(exit_code transmission) && -n $(exit_code wireguard) ]]
}
# The image stops Transmission through its RPC with the chart's
# credentials; if that fails, Transmission is killed when the grace period
# ends (exit 137) without saving its state.
stop_check() {
  local tx_exit=$1 took=$2 grace=$3
  if ((!STOPPED)); then
    fail "the containers did not stop within the pod's grace period plus 45 s, so its shutdown was not observed to the end"
  elif [[ $tx_exit == 0 ]] && ((took < grace)); then
    pass "Transmission stops on SIGTERM (exit 0), and both containers end in ${took}s, within the ${grace}s grace period"
  else
    fail "Transmission did not stop cleanly (exit ${tx_exit:-none}, containers stopped after ${took}s of a ${grace}s grace period)"
  fi
}
pod_deleted() {
  if kubectl -n "$NS" wait --for=delete "pod/$POD" --timeout=60s >/dev/null; then
    pass "the pod is deleted once released"
  else
    fail "the pod was not deleted once released"
  fi
}
# If setup_file stopped early: release the pod and end the probe loops.
teardown_file() {
  kubectl -n "$NS" patch pod "$POD" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
  xargs -r kill <"$BATS_FILE_TMPDIR/probe.pids" 2>/dev/null || true
}
teardown() { dump_on_failure; }

@test "Transmission stops on SIGTERM (exit 0), and both containers end within the grace period" {
  verdict stop
}

@test "the pod is deleted once released" {
  verdict deleted
}

@test "no direct egress while the pod terminates" {
  verdict probes
}

@test "no packet left eth0 outside the tunnel, and the canaries got only VPN traffic while the pod terminates" {
  verdict hits
}
