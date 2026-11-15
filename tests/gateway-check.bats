#!/usr/bin/env bats
# Proves the scenarios of features/gateway.feature about just gateway-check; each test carries its
# scenario's title. The recipe runs from a copy of the repository with an environment of its own, so
# no run reads this checkout's .env, keys or kubeconfig. What would reach the cluster, the edges or
# the cloud is a recording fake: kubectl and curl are tests/fixtures/gateway-check/kubectl and curl,
# which answer from files in STATE; tofu answers the edge stack's outputs; openstack and ssh fail
# when called. Every answer holds addresses from the documentation ranges, which the recipe must
# never print.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  JUST=$(command -v just)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  # The recipe's TMPDIR, which must hold nothing once it has ended.
  WORK="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$BIN" "$RECORD" "$STATE" "$WORK" "$BATS_TEST_TMPDIR/keys" "$BATS_TEST_TMPDIR/repo/talos/lab-sto2/clusterconfig"
  : > "$RECORD/argv"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  # The scripts, the backend file and the edge stack's configuration.
  cp -R "$ROOT/scripts" "$REPO/scripts"
  mkdir -p "$REPO/infra/openstack/stacks/sto2/edge"
  cp "$ROOT/infra/openstack/backend.hcl" "$REPO/infra/openstack/backend.hcl"
  cp "$ROOT"/infra/openstack/stacks/sto2/edge/*.tf "$REPO/infra/openstack/stacks/sto2/edge/"
  cp -R "$BATS_TEST_DIRNAME/fixtures/gateway-check" "$BATS_TEST_TMPDIR/fixtures"
  cat > "$REPO/talos/lab-sto2/clusterconfig/kubeconfig" << 'EOF'
apiVersion: v1
kind: Config
clusters:
  - name: lab-sto2
    cluster:
      server: https://203.0.113.80:6443
EOF
  KEY="$BATS_TEST_TMPDIR/keys/edge"
  echo 'fixture private key, never read' > "$KEY"
  echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureEdgePublicKeyFixtureFixtureFix fixture' > "$KEY.pub"
  cat > "$BATS_TEST_TMPDIR/outputs.json" << 'EOF'
{"addresses": {"sensitive": true, "value": ["203.0.113.51", "203.0.113.52"]},
 "names": {"sensitive": false, "value": ["lab-edge-1", "lab-edge-2"]}}
EOF

  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise < /dev/null
  cp "$BATS_TEST_DIRNAME/fixtures/gateway-check/kubectl" "$BATS_TEST_DIRNAME/fixtures/gateway-check/curl" "$BIN/"
  fake tofu << EOF
printf '%s\n' "tofu \$*" >> "$RECORD/argv"
case \${2-} in
  init) ;;
  output) if [[ -e "$STATE/no-edge-outputs" ]]; then echo '{}'; else cat "$BATS_TEST_TMPDIR/outputs.json"; fi ;;
  *) echo "unexpected call: tofu \$*" >&2; exit 1 ;;
esac
EOF
  for tool in openstack ssh ssh-keyscan scp; do
    fake "$tool" << EOF
printf '%s\n' "$tool \$*" >> "$RECORD/argv"
echo "unexpected call: $tool \$*" >&2
exit 1
EOF
  done
  ENVIRONMENT=(
    TF_STATE_BUCKET=fixture-state-bucket
    AWS_ACCESS_KEY_ID=marker-access-key-id
    AWS_SECRET_ACCESS_KEY=marker-secret-access-key
    TF_STATE_PASSPHRASE=marker-state-passphrase
    OS_AUTH_URL=https://identity.example.invalid/v3
    'OPERATOR_CIDRS=["198.51.100.0/24"]'
    EDGE_IMAGE=fixture-image
    EDGE_SSH_KEY_FILE="$KEY"
    TMPDIR="$WORK"
  )
  CLUSTER_LINES=(cluster-config Gateway 'Gateway address' 'proxy Service' 'proxy Service address' proxies
    certificate 'cluster CA' routes 'http listener')
  EDGE_LINES=(http TLS 'certificate names' hello 'unrouted host')
  LINES=("${CLUSTER_LINES[@]}")
  for edge in lab-edge-1 lab-edge-2; do
    for line in "${EDGE_LINES[@]}"; do
      LINES+=("$edge $line")
    done
  done
}

# fake NAME: a binary first on the recipe's PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# recipe: just gateway-check against the copy, with only ENVIRONMENT set, and sets status and output
# as bats' run does; a recipe that blocks fails after two minutes.
recipe() {
  run timeout 120 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" gateway-check
}

# line_of CHECK: the recipe's line for CHECK.
line_of() {
  grep -F -- "  $1: " <<< "$output" || true
}

# verdict CHECK: pass, FAIL or skip, from the recipe's line for CHECK.
verdict() {
  line_of "$1" | cut -d' ' -f1
}

# nothing_secret: the output holds no address, no host name under the cluster's domain, nothing of
# the CA's Secret and nothing of a tool's own errors.
nothing_secret() {
  if grep -nE '[0-9]{1,3}(\.[0-9]{1,3}){3}' <<< "$output"; then
    echo "an address is printed" >&2
    return 1
  fi
  if grep -nE 'example\.(com|org)|MARKER|PRIVATE|BEGIN CERTIFICATE|fixture message|curl: \(|Unable to connect' <<< "$output"; then
    echo "a host name, the CA's Secret or a tool's error is printed" >&2
    return 1
  fi
}

# calls PATTERN: the recorded calls matching the extended regex, one per line.
calls() {
  grep -E -- "$1" "$RECORD/argv" || true
}

@test "A healthy public Gateway passes every line of gateway-check, which reads only and prints no address" {
  recipe

  echo "$output"
  [ "$status" -eq 0 ]
  for check in "${LINES[@]}"; do
    [ "$(verdict "$check")" = pass ] || { echo "not passed: $check"; return 1; }
  done
  [ "$(grep -cE '^(pass|FAIL|skip)  ' <<< "$output")" -eq "${#LINES[@]}" ]
  [[ ${output##*$'\n'} == "gateway-check: every check of the public Gateway of lab-sto2 passes" ]]
  nothing_secret

  # Reading only, and never waiting longer than its bound.
  [ -n "$(calls '^kubectl ')" ]
  [ "$(calls '^kubectl ' | grep -vc '^kubectl get ')" -eq 0 ]
  [ "$(calls '^kubectl ' | grep -vc -- ' --request-timeout=10s')" -eq 0 ]
  # The CA's public certificate only: the one key's path, never the Secret whole or its private key.
  [ "$(calls '^kubectl get secret ')" = 'kubectl get secret cluster-ca --namespace=cert-manager --output=jsonpath={.data.tls\.crt} --request-timeout=10s' ]
  # Every request through an edge's address, with no configuration file, proxy or redirect followed,
  # bounded in time; every HTTPS one verifies against the CA's certificate.
  [ "$(calls '^curl ' | wc -l)" -eq 6 ]
  [ "$(calls '^curl ' | grep -vcE '^curl --disable .* --connect-timeout [0-9]+ --max-time [0-9]+ ')" -eq 0 ]
  [ "$(calls '^curl ' | grep -cE -- ' (-k|--insecure|-L|--location)( |$)')" -eq 0 ]
  [ "$(calls '^curl .*https://' | grep -vc -- ' --cacert ')" -eq 0 ]
  for edge in 203.0.113.51 203.0.113.52; do
    [ "$(calls "^curl .* --resolve hello\.example\.com:80:$edge .* http://hello\.example\.com/gateway-check$" | wc -l)" -eq 1 ]
    [ "$(calls "^curl .* --resolve hello\.example\.com:443:$edge .* https://hello\.example\.com/$" | wc -l)" -eq 1 ]
    [ "$(calls "^curl .* --resolve [a-z0-9-]+\.example\.com:443:$edge .* https://[a-z0-9-]+\.example\.com/$" | grep -vc 'hello\.')" -eq 1 ]
  done
  # The edge stack is read, never planned or applied, and no edge is reached over SSH.
  [ "$(calls '^(tofu|ssh|openstack|scp)' | grep -vcE '^tofu -chdir=[^ ]+ (init|output) ')" -eq 0 ]
  # The CA's certificate and the page it fetched are gone with the run.
  [ -z "$(find "$WORK" -mindepth 1)" ]
}

@test "Each unhealthy condition of the public Gateway fails its own line of gateway-check" {
  local condition file content expected check
  # Each: the state file and its content, and the lines it fails.
  local -a conditions=(
    'not-programmed||Gateway'
    'other-address||Gateway address'
    'service-cluster-ip||proxy Service'
    'service-unlabelled||proxy Service'
    'service-pending||proxy Service address'
    'one-proxy||proxies'
    'proxies-one-node||proxies'
    'certificate-not-ready||certificate'
    'no-ca||cluster CA'
    'unlabelled-route-accepted||routes'
    'http-routes|2|http listener'
    'redirect-status|302|lab-edge-1 http,lab-edge-2 http'
    'redirect-status|308|lab-edge-1 http,lab-edge-2 http'
    'redirect-location|https://elsewhere.example.net/gateway-check|lab-edge-1 http,lab-edge-2 http'
    'redirect-location|http://hello.example.com/gateway-check|lab-edge-1 http,lab-edge-2 http'
    'redirect-location|https://hello.example.com/|lab-edge-1 http,lab-edge-2 http'
    'untrusted||lab-edge-1 TLS,lab-edge-2 TLS'
    'wrong-names||lab-edge-1 TLS,lab-edge-1 certificate names,lab-edge-2 TLS,lab-edge-2 certificate names'
    'hello-status|503|lab-edge-1 hello,lab-edge-2 hello'
    'hello-page|other page|lab-edge-1 hello,lab-edge-2 hello'
    'unrouted-status|200|lab-edge-1 unrouted host,lab-edge-2 unrouted host'
    'edge-down.203.0.113.52||lab-edge-2 http,lab-edge-2 TLS'
  )
  for condition in "${conditions[@]}"; do
    IFS='|' read -r file content expected <<< "$condition"
    echo "condition: $file $content"
    find "$STATE" -mindepth 1 -delete
    printf '%s\n' "$content" > "$STATE/$file"

    recipe

    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
    nothing_secret || { echo "$output"; return 1; }
    for check in "${LINES[@]}"; do
      if [[ ",$expected," == *",$check,"* ]]; then
        [ "$(verdict "$check")" = FAIL ] || { echo "$output"; echo "not failed: $check"; return 1; }
      else
        [ "$(verdict "$check")" != FAIL ] || { echo "$output"; echo "failed as well: $check"; return 1; }
      fi
    done
    [[ $output == *"gateway-check: $(tr ',' '\n' <<< "$expected" | wc -l) of ${#LINES[@]} checks failed"* ]] || { echo "$output"; return 1; }
  done
}

@test "Without the edge stack's outputs gateway-check skips the edge lines and says why" {
  : > "$STATE/no-edge-outputs"

  recipe

  echo "$output"
  [ "$status" -eq 0 ]
  for check in "${CLUSTER_LINES[@]}"; do
    [ "$(verdict "$check")" = pass ]
  done
  [[ $(line_of edges) == "skip  edges: the edge stack sto2/edge has no outputs: it is not applied, so no edge is checked" ]]
  [ "$(grep -cE '^(pass|FAIL|skip)  ' <<< "$output")" -eq $((${#CLUSTER_LINES[@]} + 1)) ]
  [ -z "$(calls '^curl ')" ]
  [[ ${output##*$'\n'} == "gateway-check: every check of the public Gateway of lab-sto2 passes; skipped: edges" ]]
  nothing_secret
}

@test "gateway-check fails the edge line, naming why, when the edge stack's outputs cannot be read" {
  local -a kept=()
  for entry in "${ENVIRONMENT[@]}"; do
    [[ $entry == TF_STATE_BUCKET=* ]] || kept+=("$entry")
  done
  ENVIRONMENT=("${kept[@]}")

  recipe

  echo "$output"
  [ "$status" -ne 0 ]
  [[ $(line_of edges) == "FAIL  edges: the edge stack's outputs could not be read"* ]]
  [[ $output == *TF_STATE_BUCKET* ]]
  [ -z "$(calls '^curl ')" ]
  nothing_secret
}

@test "gateway-check fails every line it cannot read when the API does not answer, and prints none of kubectl's errors" {
  : > "$STATE/api-down"

  recipe

  echo "$output"
  [ "$status" -ne 0 ]
  [ "$(verdict cluster-config)" = FAIL ]
  [ "$(verdict Gateway)" = FAIL ]
  [ "$(verdict 'proxy Service')" = FAIL ]
  [ "$(verdict proxies)" = FAIL ]
  [ "$(verdict certificate)" = FAIL ]
  [ "$(verdict routes)" = FAIL ]
  nothing_secret
}
