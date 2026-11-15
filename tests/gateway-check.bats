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
# tofu's own error, when STATE/tofu-fails names the command, names the backend's bucket and an
# address, as one from an unreachable backend or expired credentials does.
if [[ \${2-} == "\$(cat "$STATE/tofu-fails" 2> /dev/null)" ]]; then
  echo "Error: Failed to get existing workspaces: bucket marker-state-bucket-name at https://198.51.100.77:443: connection refused" >&2
  exit 1
fi
case \${2-} in
  init) ;;
  output)
    if [[ -e "$STATE/no-edge-outputs" ]]; then echo '{}'
    elif [[ -e "$STATE/edge-outputs-garbage" ]]; then echo 'Warning: not JSON at all'
    else cat "$BATS_TEST_TMPDIR/outputs.json"; fi
    ;;
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
    certificate 'certificate lifetime' 'cluster CA' routes 'http listener')
  EDGE_LINES=(http TLS 'certificate names' hello 'unrouted host')
  LINES=("${CLUSTER_LINES[@]}")
  for edge in lab-edge-1 lab-edge-2; do
    for line in "${EDGE_LINES[@]}"; do
      LINES+=("$edge $line")
    done
  done
  # The name's lines, which follow the edges': its records, and a request by the name alone.
  DNS_LINES=('DNS hello' 'name hello')
  LINES+=("${DNS_LINES[@]}")
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

# recipe_start OUT: just gateway-check as recipe runs it, in the background, its output to OUT. Sets
# JUST_PID.
recipe_start() {
  env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" gateway-check > "$1" 2>&1 3>&- &
  JUST_PID=$!
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
  if grep -nE 'example\.(com|org)|MARKER|PRIVATE|BEGIN CERTIFICATE|fixture message|curl: \(|jq: |Unable to connect' <<< "$output"; then
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
  [ "$(calls '^kubectl get .* secret ')" = 'kubectl get --output=jsonpath={.data.tls\.crt} --request-timeout=10s secret --namespace=cert-manager -- cluster-ca' ]
  # Every name reaches kubectl after --, where it cannot be taken for a flag.
  [ "$(calls '^kubectl get ' | grep -vE ' (services|pods|certificates\.cert-manager\.io|namespaces|httproutes\.gateway\.networking\.k8s\.io) ' | grep -vc ' -- [a-z]')" -eq 0 ]
  # Every request through an edge's address, with no configuration file, proxy or redirect followed,
  # bounded in time; every HTTPS one verifies against the CA's certificate.
  # Six of them through an edge's address, one to the public resolver for the name's records and
  # one by the name alone.
  [ "$(calls '^curl ' | wc -l)" -eq 8 ]
  [ "$(calls '^curl .* --resolve ' | wc -l)" -eq 6 ]
  [ "$(calls '^curl ' | grep -vcE '^curl --disable .* --connect-timeout [0-9]+ --max-time [0-9]+ ')" -eq 0 ]
  [ "$(calls '^curl ' | grep -vcF -- ' --noproxy * ')" -eq 0 ]
  [ "$(calls '^curl ' | grep -cE -- ' (-k|--insecure|-L|--location)( |$)')" -eq 0 ]
  # Every HTTPS request to the cluster verifies against the CA's certificate alone; the public
  # resolver's is verified against the system's authorities, as any public site's is.
  [ "$(calls '^curl .*https://' | grep -v 'https://dns\.google/' | grep -vcE -- ' --cacert [^ ]+ --capath [^ ]+ ')" -eq 0 ]
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
  local condition file content printed expected check
  # Each: the state file and its content, the lines the run prints, all of them or the cluster's
  # with the one line that skips the edges, and the lines it fails, and no other.
  local -a conditions=(
    'no-config||cluster|cluster-config'
    'not-accepted||all|Gateway'
    'not-programmed||all|Gateway'
    'other-address||all|Gateway address'
    'service-cluster-ip||all|proxy Service'
    'service-unlabelled||all|proxy Service'
    'service-pending||all|proxy Service address'
    'two-services||all|proxy Service,proxy Service address'
    'one-proxy||all|proxies'
    'proxies-one-node||all|proxies'
    'certificate-not-ready||all|certificate'
    'no-ca||all|cluster CA'
    'unlabelled-route-accepted||all|routes'
    'http-routes|2|all|http listener'
    'redirect-status|302|all|lab-edge-1 http,lab-edge-2 http'
    'redirect-status|308|all|lab-edge-1 http,lab-edge-2 http'
    'redirect-location|https://elsewhere.example.net/gateway-check|all|lab-edge-1 http,lab-edge-2 http'
    'redirect-location|http://hello.example.com/gateway-check|all|lab-edge-1 http,lab-edge-2 http'
    'redirect-location|https://hello.example.com/|all|lab-edge-1 http,lab-edge-2 http'
    'untrusted||all|lab-edge-1 TLS,lab-edge-2 TLS'
    'wrong-names||all|lab-edge-1 TLS,lab-edge-1 certificate names,lab-edge-2 TLS,lab-edge-2 certificate names'
    'hello-status|503|all|lab-edge-1 hello,lab-edge-2 hello'
    'hello-page|other page|all|lab-edge-1 hello,lab-edge-2 hello'
    'no-page||all|lab-edge-1 hello,lab-edge-2 hello'
    'unrouted-status|200|all|lab-edge-1 unrouted host,lab-edge-2 unrouted host'
    'edge-down.203.0.113.52||all|lab-edge-2 http,lab-edge-2 TLS'
  )
  for condition in "${conditions[@]}"; do
    IFS='|' read -r file content printed expected <<< "$condition"
    echo "condition: $file $content"
    find "$STATE" -mindepth 1 -delete
    printf '%s\n' "$content" > "$STATE/$file"
    # Not lines, which bats' run sets to the output's.
    local -a wanted=("${LINES[@]}")
    if [[ $printed == cluster ]]; then
      wanted=("${CLUSTER_LINES[@]}" edges)
    fi

    recipe

    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
    nothing_secret || { echo "$output"; return 1; }
    # Exactly these lines, each once: none left out, none added.
    [ "$(sed -nE 's/^(pass|FAIL|skip)  ([^:]+): .*/\2/p' <<< "$output" | sort)" = "$(printf '%s\n' "${wanted[@]}" | sort)" ] ||
      { echo "$output"; echo "not the lines expected"; return 1; }
    # Exactly these fail.
    [ "$(sed -nE 's/^FAIL  ([^:]+): .*/\1/p' <<< "$output" | sort)" = "$(tr ',' '\n' <<< "$expected" | sort)" ] ||
      { echo "$output"; echo "not the failures expected"; return 1; }
    [[ $output == *"gateway-check: $(tr ',' '\n' <<< "$expected" | wc -l) of ${#wanted[@]} checks failed"* ]] ||
      { echo "$output"; return 1; }
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

@test "gateway-check fails the edge line, naming why, when the edge stack's outputs cannot be read, and prints none of tofu's errors" {
  local -a kept=()
  local failing
  # tofu cannot reach the backend, at its init or at its output: its errors, which name the bucket
  # and an address, go to the stack's errors file, which the line names.
  for failing in init output; do
    echo "$failing" > "$STATE/tofu-fails"

    recipe

    echo "$output"
    [ "$status" -ne 0 ]
    [ "$(line_of edges)" = "FAIL  edges: the edge stack's outputs could not be read: tofu $failing failed, and its errors are in infra/openstack/stacks/sto2/edge/.terraform/tofu-errors.log; just infra-plan sto2/edge shows them" ]
    [[ $output != *marker-state-bucket-name* && $output != *Error:* ]]
    grep -q marker-state-bucket-name "$REPO/infra/openstack/stacks/sto2/edge/.terraform/tofu-errors.log"
    [ -z "$(calls '^curl ')" ]
    nothing_secret
  done

  # Outputs that are not JSON cannot be read either, whatever tofu said of them.
  rm "$STATE/tofu-fails"
  : > "$STATE/edge-outputs-garbage"

  recipe

  echo "$output"
  [ "$status" -ne 0 ]
  [ "$(line_of edges)" = "FAIL  edges: the edge stack's outputs could not be read: they are not JSON" ]
  [ -z "$(calls '^curl ')" ]
  nothing_secret

  # Without what the stack needs, stack-env says what is missing, in the repository's words.
  rm "$STATE/edge-outputs-garbage"
  for entry in "${ENVIRONMENT[@]}"; do
    [[ $entry == TF_STATE_BUCKET=* ]] || kept+=("$entry")
  done
  # shellcheck disable=SC2030 # Each test starts from the setup's ENVIRONMENT.
  ENVIRONMENT=("${kept[@]}")

  recipe

  echo "$output"
  [ "$status" -ne 0 ]
  [ "$(line_of edges)" = "FAIL  edges: the edge stack's outputs could not be read: its environment or its lock is not ready, as said above" ]
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

@test "gateway-check neither prints a name from the cluster that is not a valid name nor hands it to kubectl" {
  local file name
  # A name that would break the line or forge another, drive the terminal, or become kubectl's flag.
  local -a names=($'cluster-ca\nFAIL  injected: every line passes' $'\e]0;forged title\a\e[31mred' '-o=yaml'
    '--kubeconfig=/tmp/elsewhere' $'cluster-ca\n')
  for file in issuer-name ca-secret-name; do
    for name in "${names[@]}"; do
      find "$STATE" -mindepth 1 -delete
      : > "$RECORD/argv"
      jq -n --arg name "$name" '$name' > "$STATE/$file"

      recipe

      echo "$output"
      [ "$status" -ne 0 ]
      [[ $(line_of 'cluster CA') == "FAIL  cluster CA: "*"is not a valid name" ]]
      nothing_secret
      [[ $output != *injected* && $output != *forged* && $output != *-o=yaml* && $output != *elsewhere* ]]
      [ "$(LC_ALL=C grep -c $'[\x01-\x08\x0b-\x1f\x7f]' <<< "$output")" -eq 0 ]
      [ "$(grep -c '^FAIL  injected' <<< "$output")" -eq 0 ]
      if [[ $file == issuer-name ]]; then
        [ -z "$(calls 'clusterissuers')" ]
      fi
      [ -z "$(calls ' secret ')" ]
      [ -z "$(calls 'injected|forged|yaml|elsewhere')" ]
    done
  done
}

@test "gateway-check fails a name from the cluster that holds a NUL, without a warning" {
  local condition file check never
  # Each: the state file that names the object, the line its name fails, and the call that must not
  # be made with it.
  local -a conditions=('issuer-name|cluster CA|clusterissuers' 'ca-secret-name|cluster CA| secret '
    'service-name|proxy Service|' 'tls-secret-name|certificate|')
  for condition in "${conditions[@]}"; do
    IFS='|' read -r file check never <<< "$condition"
    find "$STATE" -mindepth 1 -delete
    : > "$RECORD/argv"
    echo '"cluster\u0000-ca"' > "$STATE/$file"

    recipe

    echo "$output"
    [ "$status" -ne 0 ]
    [[ $(line_of "$check") == "FAIL  $check: "*"is not a valid name" ]]
    [[ $output != *warning* && $output != *"null byte"* ]]
    [ "$(grep -cvE '^(pass|FAIL|skip)  |^gateway-check: |^error: recipe ' <<< "$output")" -eq 0 ]
    [ -z "$never" ] || [ -z "$(calls "$never")" ]
    nothing_secret
  done
}

@test "gateway-check compares the demo's page byte for byte, a NUL among them, without a warning" {
  printf 'hel\0lo\n' > "$STATE/hello-page"

  recipe

  echo "$output"
  [ "$status" -ne 0 ]
  [ "$(verdict 'lab-edge-1 hello')" = FAIL ]
  [ "$(verdict 'lab-edge-2 hello')" = FAIL ]
  [[ $output != *warning* && $output != *"null byte"* ]]
  [ "$(grep -cvE '^(pass|FAIL|skip)  |^gateway-check: |^error: recipe ' <<< "$output")" -eq 0 ]
}

@test "gateway-check names the step it failed in when an answer cannot be read, and leaves nothing behind" {
  : > "$STATE/gateway-garbage"

  recipe

  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"gateway-check: failed while checking the Gateway"* ]]
  [ -z "$(find "$WORK" -mindepth 1)" ]
  nothing_secret
}

@test "gateway-check stops at Ctrl-C or SIGTERM and names the step it stopped in" {
  local signal script_pid tick out="$BATS_TEST_TMPDIR/signalled.out"
  for signal in INT TERM; do
    find "$STATE" "$WORK" -mindepth 1 -delete
    rm -f "$RECORD/script-pid"
    : > "$STATE/hang-pods"
    recipe_start "$out"
    for ((tick = 0; tick < 200; tick++)); do
      [ ! -s "$RECORD/script-pid" ] || break
      sleep 0.1
    done
    script_pid=$(cat "$RECORD/script-pid")
    [ -n "$script_pid" ]
    if [[ $signal == INT ]]; then
      # Ctrl-C: the terminal signals the recipe and just alike.
      kill -INT "$script_pid" "$JUST_PID"
    else
      # SIGTERM, which just passes on to the recipe.
      kill -TERM "$JUST_PID"
    fi
    : > "$STATE/release"
    status=0
    wait "$JUST_PID" || status=$?
    output=$(cat "$out")
    echo "after SIG$signal: status $status; $output"
    [ "$status" -ne 0 ]
    [[ $output == *"gateway-check: failed while checking the Gateway"* ]]
    # It stopped there: nothing after the proxies was checked.
    [ -z "$(line_of certificate)" ]
    [ -z "$(line_of routes)" ]
    [ -z "$(calls '^curl ')" ]
    [ -z "$(find "$WORK" -mindepth 1)" ]
    nothing_secret
  done
}

@test "gateway-check cuts a condition's reason at 120 characters" {
  : > "$STATE/long-reason"

  recipe

  echo "$output"
  [ "$status" -ne 0 ]
  [ "$(line_of Gateway)" = "FAIL  Gateway: Accepted, not Programmed: $(printf 'A%.0s' {1..120})..." ]
}

@test "The Gateway check proves a routed hostname resolves to the edges" {
  local condition file content check why lookup
  # Healthy: the name resolves, through the public resolver, to exactly the two edges' addresses,
  # and a request by the name alone, with no --resolve, reaches the demo.
  recipe

  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(verdict 'DNS hello')" = pass ]
  [ "$(verdict 'name hello')" = pass ]
  nothing_secret
  # The one name asked for is the demo's, validated under the domain: the route that was refused and
  # the one from a namespace that did not opt in are not looked up.
  [ "$(calls '^curl ' | grep -c 'dns\.google/')" -eq 1 ]
  [ "$(calls '^curl ' | grep -c 'https://dns\.google/resolve?name=hello\.example\.com&type=A$')" -eq 1 ]
  [ "$(calls '^curl ' | grep -vc -- '--resolve ')" -eq 2 ]
  [ "$(calls '^curl .* https://hello\.example\.com/$' | grep -v -- '--resolve ' | grep -c -- ' --cacert [^ ]* --capath [^ ]* ')" -eq 1 ]
  [ "$(calls '^kubectl get .*kustomizations')" = 'kubectl get --output=json --request-timeout=10s --ignore-not-found kustomizations.kustomize.toolkit.fluxcd.io --namespace=flux-system -- external-dns' ]

  # Each way the name can fail to resolve to the edges fails its own line, without an address, and
  # the request by the name alone is not made: the state file, its content, the failing line and
  # what its reason says.
  local -a conditions=(
    $'dns-answer|203.0.113.51|DNS hello|not both'
    $'dns-answer|203.0.113.52|DNS hello|not both'
    $'dns-answer|203.0.113.99|DNS hello|not exactly'
    'dns-answer|203.0.113.51,203.0.113.99|DNS hello|not exactly'
    'dns-answer|203.0.113.51,203.0.113.52,203.0.113.99|DNS hello|not exactly'
    $'dns-nxdomain||DNS hello|no address record'
    $'dns-garbage||DNS hello|not readable'
    $'doh-down||DNS hello|could not be asked'
  )
  for condition in "${conditions[@]}"; do
    IFS='|' read -r file content check why <<< "$condition"
    echo "condition: $file $content"
    find "$STATE" -mindepth 1 -delete
    : > "$RECORD/argv"
    # The addresses the resolver gives are comma-separated here, one per line in the file.
    printf '%s\n' "${content//,/$'\n'}" > "$STATE/$file"

    recipe

    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
    nothing_secret || { echo "$output"; return 1; }
    [ "$(sed -nE 's/^(pass|FAIL|skip)  ([^:]+): .*/\2/p' <<< "$output" | sort)" = "$(printf '%s\n' "${LINES[@]}" | sort)" ] ||
      { echo "$output"; echo "not the lines expected"; return 1; }
    [ "$(sed -nE 's/^FAIL  ([^:]+): .*/\1/p' <<< "$output")" = "$check" ] || { echo "$output"; echo "not the failure expected"; return 1; }
    [[ $(line_of "$check") == *"$why"* ]] || { echo "$output"; echo "not the reason expected"; return 1; }
    [ "$(verdict 'name hello')" = skip ] || { echo "$output"; return 1; }
    [ "$(calls '^curl .* https://hello\.example\.com/$' | grep -vc -- '--resolve ')" -eq 0 ]
  done

  # The resolver's answer counts only as one JSON document with the status NOERROR whose records are
  # all A records of the name itself, each one address: a CNAME to a name whose A records are the
  # edges', the edges' addresses as records of another name, an error status with them attached, two
  # documents, and one record that holds both addresses each fail, though both edges' addresses are
  # in every one. Each: the resolver's body, and what the reason says.
  local body
  local -a bodies=(
    '{"Status": 0, "Answer": [{"name": "hello.example.com.", "type": 5, "TTL": 300, "data": "edge.example.net."}, {"name": "edge.example.net.", "type": 1, "TTL": 300, "data": "203.0.113.51"}, {"name": "edge.example.net.", "type": 1, "TTL": 300, "data": "203.0.113.52"}]}|not an A record of the name itself'
    '{"Status": 0, "Answer": [{"name": "other.example.com.", "type": 1, "TTL": 300, "data": "203.0.113.51"}, {"name": "other.example.com.", "type": 1, "TTL": 300, "data": "203.0.113.52"}]}|not an A record of the name itself'
    '{"Status": 2, "Answer": [{"name": "hello.example.com.", "type": 1, "TTL": 300, "data": "203.0.113.51"}, {"name": "hello.example.com.", "type": 1, "TTL": 300, "data": "203.0.113.52"}]}|status 2, not NOERROR'
    '{"Status": 0, "Answer": [{"name": "hello.example.com.", "type": 1, "TTL": 300, "data": "203.0.113.51"}]} {"Status": 0, "Answer": [{"name": "hello.example.com.", "type": 1, "TTL": 300, "data": "203.0.113.52"}]}|not readable'
    '{"Status": 0, "Answer": [{"name": "hello.example.com.", "type": 1, "TTL": 300, "data": "203.0.113.51\n203.0.113.52"}]}|not readable'
  )
  for body in "${bodies[@]}"; do
    echo "the resolver's body: ${body%|*}"
    find "$STATE" -mindepth 1 -delete
    : > "$RECORD/argv"
    printf '%s\n' "${body%|*}" > "$STATE/dns-json"

    recipe

    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
    nothing_secret || { echo "$output"; return 1; }
    [ "$(sed -nE 's/^FAIL  ([^:]+): .*/\1/p' <<< "$output")" = 'DNS hello' ] || { echo "$output"; echo "not the failure expected"; return 1; }
    [[ $(line_of 'DNS hello') == *"${body##*|}"* ]] || { echo "$output"; echo "not the reason expected"; return 1; }
    [ "$(verdict 'name hello')" = skip ] || { echo "$output"; return 1; }
  done
  # The same answer as one document, with the status NOERROR and the two A records of the name, passes.
  find "$STATE" -mindepth 1 -delete
  printf '%s\n' '{"Status": 0, "Answer": [{"name": "hello.example.com.", "type": 1, "TTL": 300, "data": "203.0.113.52"}, {"name": "hello.example.com.", "type": 1, "TTL": 300, "data": "203.0.113.51"}]}' > "$STATE/dns-json"
  recipe
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(verdict 'DNS hello')" = pass ]

  # A request by the name alone that gets nowhere fails its own line, and the records' stays.
  find "$STATE" -mindepth 1 -delete
  : > "$STATE/by-name-down"
  recipe
  echo "$output"
  [ "$status" -ne 0 ]
  [ "$(verdict 'DNS hello')" = pass ]
  [ "$(sed -nE 's/^FAIL  ([^:]+): .*/\1/p' <<< "$output")" = 'name hello' ]
  nothing_secret

  # Where the cluster does not select DNS records there is nothing to look up: one line says so,
  # the resolver is never asked and the run passes.
  find "$STATE" -mindepth 1 -delete
  : > "$RECORD/argv"
  : > "$STATE/no-dns-app"
  recipe
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $(line_of 'DNS records') == "skip  DNS records: "*"external-dns"*"not selected"* ]]
  [ -z "$(line_of 'DNS hello')" ]
  [ -z "$(calls 'dns\.google/')" ]
  [ "$(calls '^curl ' | wc -l)" -eq 6 ]
  [[ ${output##*$'\n'} == "gateway-check: every check of the public Gateway of lab-sto2 passes; skipped: DNS records" ]]
  nothing_secret

  # The lookup trusts the system's public trust store as curl has it: the variables that would make
  # curl trust a bundle or directory of the caller's choosing do not reach it, whatever the
  # environment holds. Each curl records its arguments and, on the same line of its own record, the
  # variables it saw.
  find "$STATE" -mindepth 1 -delete
  : > "$RECORD/argv"
  : > "$RECORD/curl-env"
  # shellcheck disable=SC2030,SC2031 # Each test starts from the setup's ENVIRONMENT.
  ENVIRONMENT+=(CURL_CA_BUNDLE=/nonexistent/bundle.pem SSL_CERT_FILE=/nonexistent/file.pem SSL_CERT_DIR=/nonexistent/dir)
  recipe
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(verdict 'DNS hello')" = pass ]
  lookup=$(paste -d '|' <(grep '^curl ' "$RECORD/argv") "$RECORD/curl-env" | grep -F 'https://dns.google/resolve?')
  echo "the lookup: $lookup"
  [ "$(grep -c . <<< "$lookup")" -eq 1 ]
  [ -z "$(tr -d ' ' <<< "${lookup##*|}")" ]
}

# acme KIND: the Gateway's certificate is issued by the ACME issuer KIND, production or staging, and
# the edges serve a certificate that issuer's chain signed; STATE and the record of calls are emptied.
acme() {
  find "$STATE" -mindepth 1 -delete
  : > "$RECORD/argv"
  printf '"letsencrypt-%s"\n' "$1" > "$STATE/issuer-name"
  echo "$1" > "$STATE/served-by"
  # The lines of an ACME issuer: the one about trust has another name.
  ACME_LINES=("${LINES[@]/#cluster CA/issuer trust}")
}

# https_calls: the HTTPS requests the recipe made through the edges: by each edge's address, and by
# the demo's name alone, which this machine's resolver sends to an edge; not the lookups at the
# public resolver.
https_calls() {
  calls '^curl .*https://' | grep -vF 'https://dns.google/'
}

@test "The Gateway check verifies the certificate against the trust its issuer implies, and says which" {
  local check served edge kind directory

  # The cluster's own CA, which is what the Gateway's certificate names unless the cluster chose.
  recipe
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(line_of 'cluster CA')" = "pass  cluster CA: read the public certificate of cert-manager/cluster-ca, which cluster-ca signs with" ]
  [ "$(line_of 'lab-edge-1 TLS')" = "pass  lab-edge-1 TLS: HTTPS for hello verifies against the cluster's CA" ]

  # The ACME production issuer: the system's public trust store, and nothing added or set aside.
  acme production
  recipe
  echo "$output"
  [ "$status" -eq 0 ]
  for check in "${ACME_LINES[@]}"; do
    [ "$(verdict "$check")" = pass ] || { echo "not passed: $check"; return 1; }
  done
  [ "$(grep -cE '^(pass|FAIL|skip)  ' <<< "$output")" -eq "${#ACME_LINES[@]}" ]
  [ "$(line_of 'issuer trust')" = "pass  issuer trust: letsencrypt-production is the ACME production issuer, so each edge's certificate is verified against the system's public trust store" ]
  for edge in lab-edge-1 lab-edge-2; do
    [ "$(line_of "$edge TLS")" = "pass  $edge TLS: HTTPS for hello verifies against the system's public trust store" ]
  done
  # No Secret is read, and curl is given no authority of its own and is never told to skip the check:
  # two requests through each edge and the one by the demo's name alone.
  [ -z "$(calls ' secret ')" ]
  [ "$(https_calls | wc -l)" -eq 5 ]
  [ "$(https_calls | grep -cE -- ' (--cacert|--capath|-k|--insecure)( |$)')" -eq 0 ]
  nothing_secret

  # The ACME staging issuer: no public store holds its chain, so the issuing certificates of the
  # Secret the Gateway's Certificate makes are what is trusted, and the line says so.
  acme staging
  recipe
  echo "$output"
  [ "$status" -eq 0 ]
  for check in "${ACME_LINES[@]}"; do
    [ "$(verdict "$check")" = pass ] || { echo "not passed: $check"; return 1; }
  done
  [ "$(grep -cE '^(pass|FAIL|skip)  ' <<< "$output")" -eq "${#ACME_LINES[@]}" ]
  [ "$(line_of 'issuer trust')" = "pass  issuer trust: letsencrypt-staging is the ACME staging issuer, whose chain no public store trusts, so each edge's certificate is verified against the issuing chain of envoy-gateway-system/public-wildcard-tls: its signature, names and validity, not public trust" ]
  for edge in lab-edge-1 lab-edge-2; do
    [ "$(line_of "$edge TLS")" = "pass  $edge TLS: HTTPS for hello verifies against the staging issuing chain, which no public store trusts" ]
  done
  # Only the certificate's public part is read, and only that key, and the leaf is never a trust
  # anchor: curl is given the chain after it.
  [ "$(calls ' secret ')" = 'kubectl get --output=jsonpath={.data.tls\.crt} --request-timeout=10s secret --namespace=envoy-gateway-system -- public-wildcard-tls' ]
  [ "$(https_calls | grep -vcE -- ' --cacert [^ ]+ --capath [^ ]+ ')" -eq 0 ]
  [ "$(https_calls | grep -cE -- ' (-k|--insecure)( |$)')" -eq 0 ]
  nothing_secret
  [ -z "$(find "$WORK" -mindepth 1)" ]

  # An answer is verified against the trust its issuer implies and no other: a chain of another
  # authority than the one the Certificate's issuer implies fails TLS at both edges, and only that.
  for served in 'production|staging' 'staging|production' 'production|cluster-ca' 'staging|cluster-ca'; do
    acme "${served%|*}"
    echo "${served#*|}" > "$STATE/served-by"
    recipe
    echo "$served: $output"
    [ "$status" -ne 0 ]
    [ "$(sed -nE 's/^FAIL  ([^:]+): .*/\1/p' <<< "$output" | sort | tr '\n' ,)" = "lab-edge-1 TLS,lab-edge-2 TLS," ] ||
      { echo "not the failures expected"; return 1; }
    nothing_secret
  done

  # And the cluster's own CA does not vouch for a chain of a public authority either.
  find "$STATE" -mindepth 1 -delete
  echo production > "$STATE/served-by"
  recipe
  echo "$output"
  [ "$status" -ne 0 ]
  [ "$(sed -nE 's/^FAIL  ([^:]+): .*/\1/p' <<< "$output" | sort | tr '\n' ,)" = "lab-edge-1 TLS,lab-edge-2 TLS," ]

  # A directory that is none of Let's Encrypt's is not one whose trust the check knows, whatever
  # the issuer or the directory is called.
  for kind in production staging; do
    for directory in '' https://acme-staging.example.net/directory https://acme-v02.api.letsencrypt.org.example.net/directory; do
      acme "$kind"
      printf '%s\n' "$directory" > "$STATE/non-acme-issuer"
      recipe
      echo "$kind $directory: $output"
      [ "$status" -ne 0 ]
      [[ $(line_of 'issuer trust') == "FAIL  issuer trust: "* ]]
      [ "$(verdict 'lab-edge-1 TLS')" = skip ]
      nothing_secret
    done
  done

  # Production's trust is curl's own store alone: the variables that make curl trust another
  # bundle or directory do not reach it, whatever the operator's environment holds.
  acme production
  # shellcheck disable=SC2031 # Each test starts from the setup's ENVIRONMENT.
  ENVIRONMENT+=(CURL_CA_BUNDLE=/nonexistent/bundle.pem SSL_CERT_FILE=/nonexistent/file.pem SSL_CERT_DIR=/nonexistent/dir)
  recipe
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$RECORD/curl-env")" -gt 0 ]
  [ "$(tr -d ' \n' < "$RECORD/curl-env")" = "" ]

  # The staging chain that cannot be read leaves nothing to verify with.
  acme staging
  : > "$STATE/no-tls-secret"
  recipe
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $(line_of 'issuer trust') == "FAIL  issuer trust: kubectl could not read the certificate chain of envoy-gateway-system/public-wildcard-tls" ]]
  [ "$(verdict 'lab-edge-1 TLS')" = skip ]
  nothing_secret
}

@test "A certificate that is not issued, or is close to expiry, fails the Gateway check with the reason" {
  local case hours remaining expected kind
  # Not Ready, as with a token cert-manager's challenge is refused with: its reason, and nothing else
  # fails, as the Gateway keeps serving the Secret it has.
  for kind in staging production; do
    acme "$kind"
    echo Issuing > "$STATE/certificate-reason"
    : > "$STATE/certificate-not-ready"
    recipe
    echo "$output"
    [ "$status" -ne 0 ]
    [ "$(line_of certificate)" = "FAIL  certificate: public-wildcard is not Ready: Issuing" ]
    [ "$(sed -nE 's/^FAIL  ([^:]+): .*/\1/p' <<< "$output")" = certificate ]
    nothing_secret
  done

  # A reason that is not a word, or is long, is cut and made printable as every reason is.
  acme staging
  printf '%s\n' $'Failed\nFAIL  injected: every line passes' > "$STATE/certificate-reason"
  : > "$STATE/certificate-not-ready"
  recipe
  echo "$output"
  [ "$(line_of certificate)" = "FAIL  certificate: public-wildcard is not Ready: a reason that is not a word" ]
  [[ $output != *injected* ]]

  # Never issued: no validity to read, so the lifetime is skipped, and the certificate line fails.
  acme staging
  echo Issuing > "$STATE/certificate-reason"
  : > "$STATE/certificate-not-ready"
  : > "$STATE/no-validity"
  recipe
  echo "$output"
  [ "$status" -ne 0 ]
  [ "$(verdict 'certificate lifetime')" = skip ]
  [ "$(sed -nE 's/^FAIL  ([^:]+): .*/\1/p' <<< "$output")" = certificate ]

  # Close to expiry: under a third of the lifetime left, which cert-manager, renewing at a share of
  # it, should have renewed by now. Each: hours since notBefore and until notAfter, and the verdict.
  for case in '1800 360 FAIL' '1441 719 FAIL' '1439 721 pass' '100 20 FAIL' '100 60 pass' '2200 -40 FAIL'; do
    read -r hours remaining expected <<< "$case"
    for kind in staging production; do
      acme "$kind"
      echo "$hours $remaining" > "$STATE/validity"
      recipe
      echo "$kind $case: $output"
      [ "$(verdict 'certificate lifetime')" = "$expected" ]
      if [[ $expected == FAIL ]]; then
        [ "$status" -ne 0 ]
        [ "$(sed -nE 's/^FAIL  ([^:]+): .*/\1/p' <<< "$output")" = 'certificate lifetime' ]
      else
        [ "$status" -eq 0 ]
      fi
      nothing_secret
    done
  done
  # The line says how much is left of how much, in hours, and why that fails.
  acme staging
  echo '1800 360' > "$STATE/validity"
  recipe
  [ "$(line_of 'certificate lifetime')" = "FAIL  certificate lifetime: 360 of 2160 hours remain, under a third, which cert-manager should have renewed by now" ]
  echo '2200 -40' > "$STATE/validity"
  recipe
  [ "$(line_of 'certificate lifetime')" = "FAIL  certificate lifetime: it ended 40 hours ago" ]
  echo '1000 1160' > "$STATE/validity"
  recipe
  [ "$(line_of 'certificate lifetime')" = "pass  certificate lifetime: 1160 of 2160 hours remain" ]
}
