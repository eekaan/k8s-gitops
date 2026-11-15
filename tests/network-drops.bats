#!/usr/bin/env bats
# Proves scripts/network-drops (just network-drops), which docs/kubernetes.md, Network policy, gives
# as the way to see the flows the policies drop or would drop; none of the tests names a scenario.
# The script runs from a copy of the scripts with a kubeconfig of its own and a fake kubectl, so
# nothing reads this checkout's .env or reaches a cluster. Every answer holds addresses from the
# documentation ranges, which the script must never print.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  REPO="$BATS_TEST_TMPDIR/repo"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$REPO/talos/lab-sto2/clusterconfig" "$BIN"
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cat > "$REPO/talos/lab-sto2/clusterconfig/kubeconfig" << 'EOF'
apiVersion: v1
kind: Config
clusters:
  - name: lab-sto2
    cluster:
      server: https://203.0.113.80:6443
EOF
  cat > "$BIN/kubectl" << 'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$RECORD"
if [[ $1 == get ]]; then
  printf 'pod/cilium-aaaaa\npod/cilium-bbbbb\n'
elif [[ $1 == exec ]]; then
  if [[ $* == *cilium-bbbbb* && -n ${SECOND_FAILS:-} ]]; then
    echo "error: connection to 203.0.113.80 refused" >&2
    exit 1
  fi
  # An agent that never answers.
  if [[ $* == *cilium-bbbbb* && -n ${SECOND_HANGS:-} ]]; then
    exec sleep 60
  fi
  cat "$FLOWS"
fi
EOF
  chmod +x "$BIN/kubectl"
  FLOWS="$BATS_TEST_TMPDIR/flows"
  RECORD="$BATS_TEST_TMPDIR/record"
  : > "$RECORD"
  cat > "$FLOWS" << 'EOF'
{"flow":{"verdict":"AUDIT","IP":{"source":"192.0.2.10","destination":"192.0.2.20"},"l4":{"TCP":{"source_port":41000,"destination_port":8080}},"source":{"namespace":"envoy-gateway-system","pod_name":"envoy-a","labels":["k8s:app=envoy"]},"destination":{"namespace":"demo","pod_name":"hello-1","labels":["k8s:app=hello"]}}}
{"flow":{"verdict":"AUDIT","IP":{"source":"192.0.2.10","destination":"192.0.2.20"},"l4":{"TCP":{"source_port":41001,"destination_port":8080}},"source":{"namespace":"envoy-gateway-system","pod_name":"envoy-a","labels":["k8s:app=envoy"]},"destination":{"namespace":"demo","pod_name":"hello-1","labels":["k8s:app=hello"]}}}
{"flow":{"verdict":"DROPPED","IP":{"source":"198.51.100.7","destination":"192.0.2.20"},"l4":{"UDP":{"source_port":5353,"destination_port":53}},"source":{"labels":["reserved:world"]},"destination":{"namespace":"demo","pod_name":"hello-1","labels":["k8s:app=hello"]}}}
{"node_status":{"state_change":"NODE_CONNECTED"}}
EOF
  export PATH="$BIN:$PATH" RECORD FLOWS
  unset KUBECONFIG
}

run_drops() {
  # The scripts find the cluster's directory from their own place.
  run bash -c 'cd "$1" && scripts/network-drops lab-sto2' _ "$REPO"
}

@test "network-drops lists the flows by pod and port, counted, with no address" {
  run_drops
  [ "$status" -eq 0 ]
  [[ $output == *"4 AUDIT envoy-gateway-system/envoy-a demo/hello-1 8080/tcp"* ]]
  [[ $output == *"2 DROPPED @world demo/hello-1 53/udp"* ]]
  [[ $output != *203.0.113* && $output != *192.0.2* && $output != *198.51.100* ]]
  # Each agent is asked for a bounded number of the two verdicts and nothing else.
  [ "$(grep -c '^kubectl exec' "$RECORD")" -eq 2 ]
  grep -q -- '--timeout 30s --last 500 --verdict DROPPED --verdict AUDIT' "$RECORD"
}

@test "network-drops names an agent that does not answer, lists the rest and fails, with no address" {
  SECOND_FAILS=1 run_drops
  [ "$status" -eq 1 ]
  [[ $output == *"cilium-bbbbb did not answer"* ]]
  [[ $output == *"2 AUDIT envoy-gateway-system/envoy-a demo/hello-1 8080/tcp"* ]]
  [[ $output != *203.0.113* ]]
}

@test "network-drops refuses a bound that is not a number of flows" {
  NETWORK_DROPS_LAST=lots run_drops
  [ "$status" -eq 2 ]
  [[ $output == *NETWORK_DROPS_LAST* ]]
  [ "$(wc -c < "$RECORD")" -eq 0 ]
}

@test "network-drops gives up on an agent that does not answer within its bound, lists the rest and fails" {
  local start=$SECONDS
  SECOND_HANGS=1 NETWORK_DROPS_TIMEOUT=2 run_drops
  [ "$status" -eq 1 ]
  [ $((SECONDS - start)) -lt 20 ]
  [[ $output == *"cilium-bbbbb did not answer"* ]]
  [[ $output == *"2 AUDIT envoy-gateway-system/envoy-a demo/hello-1 8080/tcp"* ]]
  [[ $output != *203.0.113* ]]
}

@test "network-drops refuses a time bound that is not a number of seconds" {
  NETWORK_DROPS_TIMEOUT=soon run_drops
  [ "$status" -eq 2 ]
  [[ $output == *NETWORK_DROPS_TIMEOUT* ]]
  [ "$(wc -c < "$RECORD")" -eq 0 ]
}
