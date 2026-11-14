#!/usr/bin/env bats
# Proves features/cluster-recipes.feature; each test carries its scenario's title.
# The recipes run from a copy of the repository. Creating an age key, generating a secrets bundle
# and encrypting it are local and offline, so those tests run the pinned age-keygen, talman,
# talosctl and sops, recorded on their way, with every key inside the test's temporary directory.
# Everything that would reach a node or a cluster runs against recording fakes: talman, talosctl,
# kubectl, install-cilium, cluster-config, install-app, and timeout, which carries the probe of the
# Talos API port. tests/cluster-flux.bats runs the real cluster-config and install-app.

setup_file() {
  # The Talos check's fixture cluster: talos/talman.yaml.tftpl rendered from tests/fixtures/talos,
  # as talos/<cluster>/talman.yaml is rendered from the cluster stack.
  local encoded
  encoded=$(tofu -chdir="$BATS_TEST_DIRNAME/fixtures/talos" console -no-color <<< 'base64encode(local.talman_yaml)')
  base64 -d <<< "${encoded//\"/}" > "$BATS_FILE_TMPDIR/talman.yaml"
}

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  JUST=$(command -v just)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$BIN" "$RECORD" "$STATE" "$BATS_TEST_TMPDIR/repo/talos/lab-sto2" "$BATS_TEST_TMPDIR/keys"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  CLUSTER="$REPO/talos/lab-sto2"
  BUNDLE="$CLUSTER/secrets.sops.yaml"
  # The scripts, the Talos tree and what cluster-bootstrap checks for cluster-config, so no run
  # touches this checkout.
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp -R "$ROOT/talos/patches" "$REPO/talos/patches"
  cp "$ROOT/talos/schematic.yaml" "$ROOT/talos/.sops.yaml" "$REPO/talos/"
  cp -R "$ROOT/kubernetes" "$REPO/kubernetes"
  cp "$ROOT/.sops.yaml" "$REPO/.sops.yaml"
  cp "$ROOT/.gitignore" "$REPO/.gitignore"
  cp "$BATS_FILE_TMPDIR/talman.yaml" "$CLUSTER/talman.yaml"
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise < /dev/null
  KEY="$BATS_TEST_TMPDIR/keys/talos.agekey"
  FLUX_KEY="$BATS_TEST_TMPDIR/keys/flux.agekey"
  KUBE_API_ADDRESS=203.0.113.80
  # TMPDIR keeps the plaintext bundle talman stages before encrypting it inside the test's directory.
  BASE_ENVIRONMENT=(
    SOPS_AGE_KEY_FILE="$KEY"
    KUBE_API_ADDRESS="$KUBE_API_ADDRESS"
    FLUX_AGE_KEY_FILE="$FLUX_KEY"
    CLUSTER_DOMAIN=example.com
    TMPDIR="$BATS_TEST_TMPDIR"
  )
  reset_environment
}

# fake NAME: a binary first on the recipe's PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# record NAME...: puts each NAME's arguments in the record, then runs the real NAME.
record() {
  local tool real
  for tool; do
    real=$(command -v "$tool")
    fake "$tool" <<EOF
printf '%s\n' "$tool \$*" >> "$RECORD/argv"
exec "$real" "\$@"
EOF
  done
}

reset_environment() {
  ENVIRONMENT=("${BASE_ENVIRONMENT[@]}")
}

# without NAME: drops NAME from the environment the recipes get.
without() {
  local kept=() entry
  for entry in "${ENVIRONMENT[@]}"; do
    [[ $entry == "$1="* ]] || kept+=("$entry")
  done
  ENVIRONMENT=("${kept[@]}")
}

# with ENTRY...: adds the NAME=VALUE ENTRY... to the environment the recipes get.
with() {
  ENVIRONMENT+=("$@")
}

# recipe NAME [ARG...]: runs the repository's recipe against the copy, with only ENVIRONMENT set.
# A recipe that blocks fails after two minutes instead of hanging the tests.
recipe() {
  run timeout 120 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$@"
}

# absent TEXT FILE...: fails when any FILE, or any file under a directory FILE, holds TEXT.
absent() {
  local text=$1
  shift
  if grep -rqF -- "$text" "$@"; then
    echo "found $text in $*" >&2
    return 1
  fi
}

# bundle_values FILE: every value of a plaintext secrets bundle, one per line.
bundle_values() {
  yq 'del(.sops) | .. | select(kind == "scalar")' "$1"
}

# A talman that writes the secrets bundle in plaintext, as with --plaintext, whatever it is asked.
plaintext_talman() {
  local real
  real=$(command -v talman)
  fake talman <<EOF
printf '%s\n' "talman \$*" >> "$RECORD/argv"
if [[ \$* == "secrets generate" ]]; then
  exec "$real" secrets generate --plaintext
fi
exec "$real" "\$@"
EOF
}

# git_repository: makes the copy a git repository, so the secrets bundle check sees what git would
# commit.
git_repository() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q "$REPO"
}

# fake_tool NAME: like fake, with RECORD and STATE set in the fake for its body to use.
fake_tool() {
  { printf 'RECORD=%q STATE=%q\n' "$RECORD" "$STATE"; cat; } | fake "$1"
}

# cluster_files: the age key and the secrets bundle the fakes are run with, each holding a secret
# that must never be seen.
cluster_files() {
  echo 'AGE-SECRET-KEY-MARKER-AGE-KEY-FILE' > "$KEY"
  printf 'cluster:\n  secret: marker-bundle-secret\n' > "$BUNDLE"
}

# fake_cluster: a cluster whose nodes wait in maintenance mode and answer on the Talos API port,
# behind recording fakes of talman, talosctl, kubectl, install-cilium, timeout and sleep. What a
# fake does is set by files in STATE:
#   bootstrapped       etcd runs, so talman refuses to bootstrap again
#   answers-on.ADDRESS the node at ADDRESS answers the probe at that try (the first by default)
#   silent.ADDRESS     the node at ADDRESS never answers
#   changes            applying the configuration would change cp-1
#   new-nodes          the hostnames of nodes in maintenance mode, which talman apply refuses to
#                      configure, and which a dry run does not count as a change, unless onboarding
#   unreachable        talman apply's dry run cannot reach cp-2 and fails
#   talos-behind       the hostnames of nodes whose Talos is behind their configured version
#   k8s-behind         the kubelets run a Kubernetes behind kubernetesVersion
#   api-down           the Kubernetes API does not answer /readyz
# talosctl's own drain and upgrade-k8s reach the API at the cluster endpoint, the load balancer's
# address on the node network, so the fake talman fails them unless told otherwise.
fake_cluster() {
  cluster_files
  fake_tool talman <<'EOF'
printf '%s\n' "talman $*" >> "$RECORD/argv"
dir=$TALMAN_CONFIG
given() {
  [[ " ${args[*]} " == *" $1 "* ]]
}
args=("$@")
case "$1" in
  apply)
    if given --bootstrap; then
      if [[ -e $STATE/bootstrapped ]]; then
        echo "error: cp-1 runs etcd: a cluster is here already, and bootstrapping it again would split it" >&2
        exit 1
      fi
      : > "$STATE/bootstrapped"
      echo "== bootstrapping etcd on cp-1"
      exit 0
    fi
    new=$(cat "$STATE/new-nodes" 2> /dev/null || true)
    if given --dry-run; then
      if [[ -e $STATE/unreachable ]]; then
        echo "error: cp-2 answers neither the Talos API nor the maintenance service" >&2
        exit 1
      fi
      changed=0
      if [[ -e $STATE/changes ]]; then
        echo "== cp-1"
        echo "     Config diff:"
        if given --redact-secrets=false; then
          echo "     +    token: marker-machine-token"
        else
          echo "     +    token: [redacted]"
        fi
        changed=1
      fi
      for node in $new; do
        echo "== $node · new, in maintenance mode"
        if given --onboard-new-nodes; then
          changed=1
        else
          echo "     a real run would need --onboard-new-nodes"
        fi
      done
      if given --detailed-exit-code && ((changed)); then
        exit 2
      fi
      exit 0
    fi
    if [[ -n $new ]] && ! given --onboard-new-nodes; then
      echo "error: new node(s), in maintenance mode: $new" >&2
      exit 1
    fi
    if given --onboard-new-nodes; then
      : > "$STATE/new-nodes"
    fi
    rm -f "$STATE/changes"
    echo "     Applied configuration without a reboot"
    ;;
  kubeconfig)
    mkdir -p "$dir/clusterconfig"
    cat > "$dir/clusterconfig/kubeconfig" <<'KUBECONFIG'
apiVersion: v1
kind: Config
clusters:
  - name: example
    cluster:
      server: https://192.0.2.10:6443
      certificate-authority-data: marker-certificate-authority-data
users:
  - name: admin@example
    user:
      client-certificate-data: marker-client-certificate-data
      client-key-data: marker-client-key-data
contexts:
  - name: admin@example
    context:
      cluster: example
      user: admin@example
current-context: admin@example
KUBECONFIG
    chmod 644 "$dir/clusterconfig/kubeconfig"
    echo "wrote clusterconfig/kubeconfig"
    ;;
  upgrade)
    node=
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ ${args[i]} == -n ]]; then
        node=${args[i + 1]-}
      fi
    done
    behind=$(cat "$STATE/talos-behind" 2> /dev/null || true)
    if given --dry-run; then
      changed=0
      for each in $behind; do
        if [[ -z $node || $each == "$node" ]]; then
          echo "== $each: v1.14.5 -> v1.14.6"
          changed=1
        fi
      done
      if given --detailed-exit-code && ((changed)); then
        exit 2
      fi
      exit 0
    fi
    if ! given --extra-flags=--drain=false; then
      echo "error: draining $node: dial tcp 192.0.2.5:6443: i/o timeout" >&2
      exit 1
    fi
    grep -vx -- "$node" "$STATE/talos-behind" > "$STATE/talos-behind.next" || true
    mv "$STATE/talos-behind.next" "$STATE/talos-behind"
    echo "== $node: upgraded to v1.14.6"
    ;;
  upgrade-k8s)
    if given --dry-run; then
      if [[ -e $STATE/k8s-behind ]]; then
        echo "== cp-1 runs Kubernetes v1.37.0 -> v1.37.1"
        if given --detailed-exit-code; then
          exit 2
        fi
      else
        echo "nothing to upgrade: every node already runs Kubernetes v1.37.1"
      fi
      exit 0
    fi
    if [[ " ${args[*]} " != *" --extra-flags=--endpoint=https://"* ]]; then
      echo "error: dial tcp 192.0.2.5:6443: i/o timeout" >&2
      exit 1
    fi
    rm -f "$STATE/k8s-behind"
    echo "== upgraded Kubernetes to v1.37.1"
    ;;
  etcd)
    echo "wrote clusterconfig/etcd-example-20261114T000000Z.db"
    ;;
esac
EOF
  fake_tool talosctl <<'EOF'
printf '%s\n' "talosctl $*" >> "$RECORD/argv"
EOF
  fake_tool kubectl <<'EOF'
printf '%s\n' "kubectl $*" >> "$RECORD/argv"
printf '%s\n' "${KUBECONFIG-}" > "$RECORD/kubeconfig"
if [[ $* == *" /readyz"* && -e $STATE/api-down ]]; then
  echo "The connection to the server was refused" >&2
  exit 1
fi
EOF
  # The nodes answer a connection to the Talos API port only.
  fake_tool timeout <<'EOF'
printf '%s\n' "timeout $*" >> "$RECORD/argv"
[[ $* == *"/dev/tcp/"*50000* ]] || exit 1
address=${*: -1}
tries=$(($(cat "$STATE/tries.$address" 2> /dev/null || echo 0) + 1))
echo "$tries" > "$STATE/tries.$address"
[[ ! -e $STATE/silent.$address ]] && ((tries >= $(cat "$STATE/answers-on.$address" 2> /dev/null || echo 1)))
EOF
  fake sleep < /dev/null
  fake_tool install-cilium <<'EOF'
printf '%s\n' "install-cilium KUBECONFIG=${KUBECONFIG-}" >> "$RECORD/argv"
EOF
  mv "$BIN/install-cilium" "$REPO/scripts/install-cilium"
  fake_tool cluster-config <<'EOF'
printf '%s\n' "cluster-config $*" >> "$RECORD/argv"
EOF
  mv "$BIN/cluster-config" "$REPO/scripts/cluster-config"
  fake_tool install-app <<'EOF'
printf '%s\n' "install-app $* KUBECONFIG=${KUBECONFIG-}" >> "$RECORD/argv"
EOF
  mv "$BIN/install-app" "$REPO/scripts/install-app"
  # The Flux age key, with its recipient in .sops.yaml, which cluster-bootstrap checks first.
  age-keygen -o "$FLUX_KEY" 2> /dev/null
  RECIPIENT=$(age-keygen -y "$FLUX_KEY") yq -i '.creation_rules[].age = strenv(RECIPIENT)' "$REPO/.sops.yaml"
}

# node_address HOSTNAME: the address talman reaches HOSTNAME on, from the cluster's talman.yaml.
node_address() {
  yq ".nodes[] | select(.hostname == \"$1\") | .ipAddress" "$CLUSTER/talman.yaml"
}

# call_line PATTERN: the line number in the record of the first call matching the extended regex.
call_line() {
  grep -n -m1 -E -- "$1" "$RECORD/argv" | cut -d: -f1
}

# calls PATTERN: the recorded calls matching the extended regex, one per line.
calls() {
  grep -E -- "$1" "$RECORD/argv" || true
}

# applies: the recorded talman apply calls that are not dry runs, one per line.
applies() {
  calls '^talman apply( |$)' | grep -v -- ' --dry-run' || true
}

@test "The age key is created once and never printed" {
  record age-keygen yq

  recipe cluster-age-key

  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$KEY")" = 600 ]
  recipient=$(age-keygen -y "$KEY")
  [ "$output" = "$recipient" ]
  [ "$(yq '.creation_rules[].age' "$REPO/talos/.sops.yaml")" = "$recipient" ]
  cp "$KEY" "$BATS_TEST_TMPDIR/key.before"
  cp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"

  recipe cluster-age-key

  [ "$status" -eq 0 ]
  [ "$output" = "$recipient" ]
  cmp "$KEY" "$BATS_TEST_TMPDIR/key.before"
  cmp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"
  secret=$(grep '^AGE-SECRET-KEY-' "$KEY")
  absent "$secret" "$RECORD/argv" "$REPO"
}

@test "cluster-age-key refuses a key file inside the repository" {
  without SOPS_AGE_KEY_FILE
  with SOPS_AGE_KEY_FILE="$REPO/talos/talos.agekey"

  recipe cluster-age-key

  [ "$status" -ne 0 ]
  [[ $output == *"SOPS_AGE_KEY_FILE names a path inside the repository"* ]]
  [ ! -e "$REPO/talos/talos.agekey" ]
  cmp "$REPO/talos/.sops.yaml" "$ROOT/talos/.sops.yaml"
}

@test "cluster-age-key leaves a talos/.sops.yaml naming another recipient alone" {
  age-keygen -o "$BATS_TEST_TMPDIR/keys/other.agekey" 2> /dev/null
  other=$(age-keygen -y "$BATS_TEST_TMPDIR/keys/other.agekey")
  RECIPIENT=$other yq -i '.creation_rules[].age = strenv(RECIPIENT)' "$REPO/talos/.sops.yaml"
  cp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"

  recipe cluster-age-key

  [ "$status" -ne 0 ]
  [[ $output == *"talos/.sops.yaml names another recipient"* ]]
  cmp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"
  [ ! -e "$KEY" ]

  # A key of its own at SOPS_AGE_KEY_FILE does not replace the recipient either.
  age-keygen -o "$KEY" 2> /dev/null
  cp "$KEY" "$BATS_TEST_TMPDIR/key.before"

  recipe cluster-age-key

  [ "$status" -ne 0 ]
  [[ $output == *"talos/.sops.yaml names another recipient"* ]]
  cmp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"
  cmp "$KEY" "$BATS_TEST_TMPDIR/key.before"
}

@test "Cluster secrets are written encrypted and never regenerated" {
  record talman talosctl sops age-keygen
  recipe cluster-age-key
  [ "$status" -eq 0 ]
  recipient=$output

  recipe cluster-secrets

  [ "$status" -eq 0 ]
  [ "$(sops filestatus "$BUNDLE")" = '{"encrypted":true}' ]
  [ "$(yq '.sops.age[].recipient' "$BUNDLE")" = "$recipient" ]
  [ "$(yq 'del(.sops) | [.. | select(kind == "scalar")] | length' "$BUNDLE")" -gt 0 ]
  [ "$(yq 'del(.sops) | [.. | select(kind == "scalar") | select(test("^ENC\\[") | not)] | length' "$BUNDLE")" -eq 0 ]
  SOPS_AGE_KEY_FILE="$KEY" sops decrypt "$BUNDLE" > /dev/null
  cp "$BUNDLE" "$BATS_TEST_TMPDIR/bundle.before"
  : > "$RECORD/argv"

  recipe cluster-secrets

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/secrets.sops.yaml exists"* ]]
  cmp "$BUNDLE" "$BATS_TEST_TMPDIR/bundle.before"
  run grep -c '^talman ' "$RECORD/argv"
  [ "$output" -eq 0 ]
}

@test "cluster-secrets names what it needs before it calls talman" {
  record talman
  rm "$CLUSTER/talman.yaml"

  recipe cluster-secrets

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/talman.yaml does not exist"* ]]
  [[ $output == *"talos/.sops.yaml holds no age recipient yet"* ]]
  [ ! -e "$RECORD/argv" ]
  [ ! -e "$BUNDLE" ]
}

@test "Secrets written in plaintext fail the recipe and are kept" {
  recipe cluster-age-key
  [ "$status" -eq 0 ]
  plaintext_talman

  recipe cluster-secrets

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/secrets.sops.yaml is not encrypted"* ]]
  [ -s "$BUNDLE" ]
  [ "$(sops filestatus "$BUNDLE")" = '{"encrypted":false}' ]
  while IFS= read -r value; do
    [[ $output != *"$value"* ]]
  done < <(bundle_values "$BUNDLE")
}

@test "A plaintext secrets bundle fails the check" {
  git_repository
  mkdir -p "$REPO/talos/other"
  talman -c "$CLUSTER" secrets generate --plaintext > /dev/null
  cp "$BUNDLE" "$REPO/talos/other/secrets.sops.yaml"
  git -C "$REPO" add talos/other/secrets.sops.yaml

  recipe cluster-secrets-check

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/secrets.sops.yaml is not SOPS-encrypted"* ]]
  [[ $output == *"talos/other/secrets.sops.yaml is not SOPS-encrypted"* ]]
  while IFS= read -r value; do
    [[ $output != *"$value"* ]]
  done < <(bundle_values "$BUNDLE")

  # The same bundle encrypted passes.
  git -C "$REPO" rm -q --cached talos/other/secrets.sops.yaml
  rm -r "$REPO/talos/other" "$BUNDLE"
  recipe cluster-age-key
  [ "$status" -eq 0 ]
  recipe cluster-secrets
  [ "$status" -eq 0 ]

  recipe cluster-secrets-check

  [ "$status" -eq 0 ]
}

@test "the secrets bundle check fails on a bundle with a plaintext value or without SOPS metadata" {
  git_repository
  recipe cluster-age-key
  recipe cluster-secrets
  [ "$status" -eq 0 ]
  cp "$BUNDLE" "$BATS_TEST_TMPDIR/encrypted.yaml"
  yq -i '.cluster.id = "marker-plaintext-value"' "$BUNDLE"

  recipe cluster-secrets-check

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/secrets.sops.yaml is not SOPS-encrypted"* ]]
  [[ $output != *marker-plaintext-value* ]]

  yq 'del(.sops)' "$BATS_TEST_TMPDIR/encrypted.yaml" > "$BUNDLE"

  recipe cluster-secrets-check

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/secrets.sops.yaml is not SOPS-encrypted"* ]]
}

@test "the cluster recipes refuse Go's HTTP/2 debug log" {
  fake_cluster
  rm "$KEY"
  record age-keygen
  with GODEBUG=x509sha1=1,http2debug=2

  for name in cluster-age-key cluster-secrets cluster-bootstrap cluster-kubeconfig cluster-talos \
    cluster-upgrade cluster-upgrade-k8s; do
    recipe "$name"

    [ "$status" -ne 0 ]
    [[ $output == *"GODEBUG sets http2debug"* ]]
  done
  [ ! -e "$RECORD/argv" ]
  [ ! -e "$KEY" ]
}

@test "the secrets bundle is committable and the cluster's generated files are not" {
  cd "$ROOT"

  run git check-ignore --no-index -q talos/lab-sto2/secrets.sops.yaml
  [ "$status" -eq 1 ]
  for path in talos/lab-sto2/talman.yaml talos/lab-sto2/clusterconfig/kubeconfig talos/lab-sto2/clusterconfig/talosconfig; do
    git check-ignore --no-index -q "$path"
  done
}

@test "Bootstrap refuses without its preconditions" {
  fake_cluster
  # Each case takes one precondition away, or all of them, and collects the messages it expects.
  for case in talman secrets age-key api-address all wait; do
    echo "$case"
    reset_environment
    cluster_files
    cp "$BATS_FILE_TMPDIR/talman.yaml" "$CLUSTER/talman.yaml"
    rm -f "$RECORD/argv"
    messages=()
    if [[ $case == talman || $case == all ]]; then
      rm "$CLUSTER/talman.yaml"
      messages+=("talos/lab-sto2/talman.yaml does not exist")
    fi
    if [[ $case == secrets || $case == all ]]; then
      rm "$BUNDLE"
      messages+=("talos/lab-sto2/secrets.sops.yaml does not exist")
    fi
    if [[ $case == age-key || $case == all ]]; then
      without SOPS_AGE_KEY_FILE
      messages+=("neither SOPS_AGE_KEY_FILE nor SOPS_AGE_KEY is set")
    fi
    if [[ $case == api-address || $case == all ]]; then
      without KUBE_API_ADDRESS
      if [[ -f $CLUSTER/talman.yaml ]]; then
        yq -i 'del(.values.apiAddress)' "$CLUSTER/talman.yaml"
      fi
      messages+=("KUBE_API_ADDRESS is not set, and talos/lab-sto2/talman.yaml gives no values.apiAddress")
    fi
    if [[ $case == wait ]]; then
      with TALOS_WAIT=soon
      messages+=("TALOS_WAIT is not a whole number of seconds")
    fi

    recipe cluster-bootstrap

    [ "$status" -ne 0 ]
    for message in "${messages[@]}"; do
      [[ $output == *"$message"* ]]
    done
    [ ! -e "$RECORD/argv" ]
  done
}

@test "Bootstrap waits for every node and names the ones that do not answer" {
  fake_cluster
  slow=$(node_address cp-2)
  echo 3 > "$STATE/answers-on.$slow"

  recipe cluster-bootstrap

  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/tries.$slow")" -eq 3 ]
  for hostname in $(yq '.nodes[].hostname' "$CLUSTER/talman.yaml"); do
    [ -e "$STATE/tries.$(node_address "$hostname")" ]
  done
  answered=$(grep -n "^timeout .*/dev/tcp/.* $slow\$" "$RECORD/argv" | tail -1 | cut -d: -f1)
  [ "$answered" -lt "$(call_line '^talman ')" ]

  rm -f "$STATE"/* "$RECORD/argv"
  : > "$STATE/silent.$(node_address cp-3)"
  : > "$STATE/silent.$(node_address worker-2)"
  with TALOS_WAIT=0

  recipe cluster-bootstrap

  [ "$status" -ne 0 ]
  silent=$(grep 'no answer on the Talos API port' <<< "$output")
  [[ $silent == *cp-3* && $silent == *worker-2* ]]
  for hostname in cp-1 cp-2 worker-1 worker-3; do
    [[ $silent != *"$hostname"* ]]
  done
  for hostname in $(yq '.nodes[].hostname' "$CLUSTER/talman.yaml"); do
    [[ $output != *"$(node_address "$hostname")"* ]]
  done
  [ -z "$(call_line '^talman ')" ]
}

@test "Bootstrap applies, fetches the kubeconfig and installs Cilium in that order" {
  fake_cluster

  recipe cluster-bootstrap

  [ "$status" -eq 0 ]
  probed=$(grep -n '^timeout .*/dev/tcp/' "$RECORD/argv" | tail -1 | cut -d: -f1)
  applied=$(call_line '^talman apply ')
  fetched=$(call_line '^talman kubeconfig')
  installed=$(call_line '^install-cilium ')
  ready=$(call_line '^kubectl wait ')
  for call in "$probed" "$applied" "$fetched" "$installed" "$ready"; do
    [ -n "$call" ]
  done
  [ "$probed" -lt "$applied" ]
  [ "$applied" -lt "$fetched" ]
  [ "$fetched" -lt "$installed" ]
  [ "$installed" -lt "$ready" ]
  apply=$(calls '^talman apply( |$)')
  [ "$(wc -l <<< "$apply")" -eq 1 ]
  [[ " $apply " == *" --bootstrap "* && " $apply " == *" --onboard-new-nodes "* ]]
  [ "$(grep -c health "$RECORD/argv")" -eq 0 ]
  [ "$(grep -c '^talosctl ' "$RECORD/argv")" -eq 0 ]
  [ "$(grep '^install-cilium ' "$RECORD/argv")" = "install-cilium KUBECONFIG=$CLUSTER/clusterconfig/kubeconfig" ]
  wait=$(grep '^kubectl wait ' "$RECORD/argv")
  [[ " $wait " == *" --for=condition=Ready "* ]]
  for hostname in $(yq '.nodes[].hostname' "$CLUSTER/talman.yaml"); do
    [[ " $wait " == *" node/$hostname "* ]]
  done
  [[ $output != *"not implemented"* ]]

  : > "$RECORD/argv"

  recipe cluster-bootstrap

  [ "$status" -ne 0 ]
  [[ $output == *"failed while bootstrapping"* ]]
  [ -n "$(call_line '^talman apply .*--bootstrap')" ]
  [ -z "$(call_line '^(talman kubeconfig|install-cilium|cluster-config|install-app|kubectl)')" ]
}

@test "The kubeconfig is private and points at the API address from the environment" {
  fake_cluster
  record yq
  kubeconfig="$CLUSTER/clusterconfig/kubeconfig"

  recipe cluster-kubeconfig

  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "$kubeconfig" ]
  [ "$(stat -c %a "$kubeconfig")" = 600 ]
  [ "$(yq '[.clusters[].cluster.server] | unique | join(" ")' "$kubeconfig")" = "https://$KUBE_API_ADDRESS:6443" ]
  [ "$(yq '.users[0].user["client-key-data"]' "$kubeconfig")" = marker-client-key-data ]
  [[ $output != *marker-* ]]
  [[ $output != *"$KUBE_API_ADDRESS"* ]]
  absent "$KUBE_API_ADDRESS" "$RECORD/argv"

  # A second run fetches it again, with the same result.
  recipe cluster-kubeconfig

  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$kubeconfig")" = 600 ]
  [ "$(yq '.clusters[0].cluster.server' "$kubeconfig")" = "https://$KUBE_API_ADDRESS:6443" ]
}

@test "Without KUBE_API_ADDRESS the recipes reach the API at the address in talman.yaml" {
  fake_cluster
  record yq
  kubeconfig="$CLUSTER/clusterconfig/kubeconfig"
  address=$(yq '.values.apiAddress' "$CLUSTER/talman.yaml")
  [[ $address =~ ^[0-9]+(\.[0-9]+){3}$ ]]
  [ "$address" != "$KUBE_API_ADDRESS" ]
  without KUBE_API_ADDRESS

  recipe cluster-kubeconfig

  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "$kubeconfig" ]
  [ "$(yq '[.clusters[].cluster.server] | unique | join(" ")' "$kubeconfig")" = "https://$address:6443" ]
  [[ $output != *"$address"* ]]
  absent "$address" "$RECORD/argv"

  # KUBE_API_ADDRESS in the environment wins over talman.yaml.
  reset_environment

  recipe cluster-kubeconfig

  [ "$status" -eq 0 ]
  [ "$(yq '[.clusters[].cluster.server] | unique | join(" ")' "$kubeconfig")" = "https://$KUBE_API_ADDRESS:6443" ]
  [[ $output != *"$KUBE_API_ADDRESS"* ]]
}

@test "cluster-kubeconfig refuses an API address it cannot put in a URL, without printing it" {
  fake_cluster
  without KUBE_API_ADDRESS
  with 'KUBE_API_ADDRESS=https://marker-not-an-address:6443'

  recipe cluster-kubeconfig

  [ "$status" -ne 0 ]
  [[ $output == *"KUBE_API_ADDRESS is not an IPv4 address"* ]]
  [[ $output != *marker-not-an-address* ]]
  [ ! -e "$RECORD/argv" ]
}

@test "A configuration rollout shows the change and asks before applying" {
  fake_cluster
  : > "$STATE/changes"

  recipe cluster-talos <<< "no"

  [ "$status" -ne 0 ]
  [[ $output == *"Config diff:"* && $output == *"[redacted]"* ]]
  [[ $output != *marker-machine-token* ]]
  [[ $output == *"lab-sto2 was not confirmed"* ]]
  [ "$(calls '^talman apply( |$)' | wc -l)" -eq 1 ]
  [ -n "$(call_line '^talman apply .*--dry-run')" ]
  [ -e "$STATE/changes" ]
  probed=$(grep -n '^timeout .*/dev/tcp/' "$RECORD/argv" | tail -1 | cut -d: -f1)
  [ -n "$probed" ]
  [ "$probed" -lt "$(call_line '^talman ')" ]

  : > "$RECORD/argv"
  recipe cluster-talos lab-sto2 <<< "lab-sto2"

  [ "$status" -eq 0 ]
  [ "$(applies | wc -l)" -eq 1 ]
  [[ " $(applies) " != *" --health "* ]]
  [ "$(call_line '^talman apply .*--dry-run')" -lt "$(call_line "^$(applies)\$")" ]
  [ ! -e "$STATE/changes" ]

  : > "$STATE/changes"
  : > "$RECORD/argv"
  recipe cluster-talos --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output != *"Type lab-sto2"* ]]
  [ "$(applies | wc -l)" -eq 1 ]

  # Nothing changes: nothing is asked or applied.
  : > "$RECORD/argv"
  recipe cluster-talos < /dev/null

  [ "$status" -eq 0 ]
  [[ $output != *"Type lab-sto2"* ]]
  [ "$(applies | wc -l)" -eq 0 ]
}

@test "New nodes are onboarded only when asked" {
  fake_cluster
  echo worker-3 > "$STATE/new-nodes"
  : > "$STATE/changes"

  recipe cluster-talos --yes < /dev/null

  [ "$status" -ne 0 ]
  [ "$(grep -c -- '--onboard-new-nodes' "$RECORD/argv")" -eq 0 ]
  [ "$(cat "$STATE/new-nodes")" = worker-3 ]

  : > "$RECORD/argv"
  recipe cluster-talos --onboard --yes < /dev/null

  [ "$status" -eq 0 ]
  [ "$(calls '^talman apply( |$)' | wc -l)" -eq 2 ]
  [ "$(calls '^talman apply( |$)' | grep -vc -- ' --onboard-new-nodes')" -eq 0 ]
  [ ! -s "$STATE/new-nodes" ]
}

@test "a rollout whose dry run fails applies nothing and names the step" {
  fake_cluster
  : > "$STATE/changes"
  : > "$STATE/unreachable"

  recipe cluster-talos --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"cluster-talos: failed while asking each node what the configuration would change"* ]]
  [ "$(applies | wc -l)" -eq 0 ]
}

@test "cluster-talos refuses an argument it does not know before it runs anything" {
  fake_cluster

  recipe cluster-talos --force < /dev/null

  [ "$status" -eq 2 ]
  [[ $output == *"usage: cluster-talos [cluster] [--onboard] [--yes]"* ]]
  [ ! -e "$RECORD/argv" ]
}

@test "A Talos upgrade drains through the Kubernetes API one node at a time" {
  fake_cluster
  printf '%s\n' cp-2 worker-1 > "$STATE/talos-behind"
  # upgrades: the recorded talman upgrade calls that are not dry runs.
  upgrades() {
    calls '^talman upgrade( |$)' | grep -v -- ' --dry-run' || true
  }

  recipe cluster-upgrade <<< "no"

  [ "$status" -ne 0 ]
  [[ $output == *"cp-2: v1.14.5 -> v1.14.6"* && $output == *"worker-1: v1.14.5 -> v1.14.6"* ]]
  [[ $output == *"lab-sto2 was not confirmed"* ]]
  [ -z "$(upgrades)" ]
  [ -z "$(calls '^(kubectl drain|talman etcd)')" ]

  : > "$RECORD/argv"
  recipe cluster-upgrade <<< "lab-sto2"

  [ "$status" -eq 0 ]
  [ ! -s "$STATE/talos-behind" ]
  [ "$(calls '^kubectl drain ' | wc -l)" -eq 2 ]
  [ "$(upgrades | wc -l)" -eq 2 ]
  previous=$(call_line '^talman etcd snapshot')
  [ -n "$previous" ]
  for node in cp-2 worker-1; do
    readyz=$(grep -n '^kubectl get --raw /readyz' "$RECORD/argv" | cut -d: -f1 |
      awk -v after="$previous" '$1 > after' | head -1)
    drained=$(call_line "^kubectl drain $node( |\$)")
    upgraded=$(grep -nE "^talman upgrade -n $node( |\$)" "$RECORD/argv" | grep -v -- ' --dry-run' | head -1 | cut -d: -f1)
    ready=$(call_line "^kubectl wait .*node/$node( |\$)")
    uncordoned=$(call_line "^kubectl uncordon $node( |\$)")
    for call in "$readyz" "$drained" "$upgraded" "$ready" "$uncordoned"; do
      [ -n "$call" ]
    done
    [ "$previous" -lt "$readyz" ]
    [ "$readyz" -lt "$drained" ]
    [ "$drained" -lt "$upgraded" ]
    [ "$upgraded" -lt "$ready" ]
    [ "$ready" -lt "$uncordoned" ]
    [[ " $(upgrades | grep -E "^talman upgrade -n $node( |\$)") " == *" --extra-flags=--drain=false "* ]]
    previous=$uncordoned
  done
  checked=$(grep -n '^talman upgrade --dry-run' "$RECORD/argv" | tail -1 | cut -d: -f1)
  [ "$checked" -gt "$previous" ]
  [ "$(cat "$RECORD/kubeconfig")" = "$CLUSTER/clusterconfig/kubeconfig" ]
  [ "$(yq '.clusters[0].cluster.server' "$CLUSTER/clusterconfig/kubeconfig")" = "https://$KUBE_API_ADDRESS:6443" ]
  [ -z "$(calls '^talman .*( --to| --force)')" ]
  [ -z "$(calls '^talosctl |health')" ]

  # The API does not answer: no node is drained.
  printf '%s\n' cp-2 worker-1 > "$STATE/talos-behind"
  : > "$STATE/api-down"
  : > "$RECORD/argv"
  recipe cluster-upgrade --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"the Kubernetes API does not answer"* ]]
  [ -z "$(calls '^kubectl drain ')" ]
  [ -z "$(upgrades)" ]

  # Every node on its version: nothing is asked, drained or upgraded.
  rm "$STATE/api-down"
  : > "$STATE/talos-behind"
  : > "$RECORD/argv"
  recipe cluster-upgrade < /dev/null

  [ "$status" -eq 0 ]
  [[ $output != *"Type lab-sto2"* ]]
  [ -z "$(calls '^(kubectl drain|talman etcd)')" ]
  [ -z "$(upgrades)" ]
}

@test "A Kubernetes upgrade shows the change and asks before applying" {
  fake_cluster
  : > "$STATE/k8s-behind"
  # upgrades: the recorded talman upgrade-k8s calls that are not dry runs.
  upgrades() {
    calls '^talman upgrade-k8s( |$)' | grep -v -- ' --dry-run' || true
  }

  recipe cluster-upgrade-k8s <<< "no"

  [ "$status" -ne 0 ]
  [[ $output == *"v1.37.0 -> v1.37.1"* ]]
  [[ $output == *"lab-sto2 was not confirmed"* ]]
  [ -z "$(upgrades)" ]
  [ -e "$STATE/k8s-behind" ]

  : > "$RECORD/argv"
  recipe cluster-upgrade-k8s <<< "lab-sto2"

  [ "$status" -eq 0 ]
  [ ! -e "$STATE/k8s-behind" ]
  [ "$(upgrades | wc -l)" -eq 1 ]
  [[ " $(upgrades) " == *" --snapshot "* ]]
  [[ " $(upgrades) " == *" --extra-flags=--endpoint=https://$KUBE_API_ADDRESS:6443 "* ]]
  [[ " $(upgrades) " != *" --to"* && " $(upgrades) " != *" --force "* ]]
  upgraded=$(call_line "^$(upgrades)\$")
  [ "$(call_line '^talman upgrade-k8s .*--dry-run')" -lt "$upgraded" ]
  checked=$(grep -n '^talman upgrade-k8s .*--dry-run' "$RECORD/argv" | tail -1 | cut -d: -f1)
  [ "$checked" -gt "$upgraded" ]
  [[ $output != *"$KUBE_API_ADDRESS"* ]]

  : > "$RECORD/argv"
  recipe cluster-upgrade-k8s < /dev/null

  [ "$status" -eq 0 ]
  [[ $output != *"Type lab-sto2"* ]]
  [ -z "$(upgrades)" ]
}

@test "No cluster secret reaches a command line or the output" {
  git_repository
  record talman talosctl sops age-keygen yq jq git
  printed=()
  # run_and_keep STATUS RECIPE...: runs the recipe, expects STATUS (ok or failed), keeps its output.
  run_and_keep() {
    local expected=$1
    shift
    recipe "$@"
    if [[ $expected == ok ]]; then
      [ "$status" -eq 0 ]
    else
      [ "$status" -ne 0 ]
    fi
    printed+=("$output")
  }

  run_and_keep ok cluster-age-key
  run_and_keep ok cluster-age-key
  run_and_keep ok cluster-secrets
  run_and_keep failed cluster-secrets
  run_and_keep ok cluster-secrets-check
  mv "$BUNDLE" "$BATS_TEST_TMPDIR/encrypted.yaml"
  plaintext_talman
  run_and_keep failed cluster-secrets
  run_and_keep failed cluster-secrets-check

  # The secrets so far: the age key, and every value of both bundles.
  markers=("$(grep '^AGE-SECRET-KEY-' "$KEY")")
  mapfile -t -O 1 markers < <(bundle_values "$BUNDLE"; SOPS_AGE_KEY_FILE="$KEY" sops decrypt "$BATS_TEST_TMPDIR/encrypted.yaml" | bundle_values /dev/stdin)
  [ "${#markers[@]}" -gt 20 ]
  grep -q '^talman secrets generate' "$RECORD/argv"
  grep -q '^sops ' "$RECORD/argv"
  grep -q '^talosctl ' "$RECORD/argv"

  # The recipes that reach the cluster, against the fakes, with a key and a bundle of markers.
  fake_cluster
  run_and_keep ok cluster-bootstrap
  run_and_keep failed cluster-bootstrap
  run_and_keep ok cluster-kubeconfig
  without SOPS_AGE_KEY_FILE
  with SOPS_AGE_KEY=marker-sops-age-key
  run_and_keep ok cluster-kubeconfig
  reset_environment
  rm "$STATE/bootstrapped"
  : > "$STATE/silent.$(node_address worker-3)"
  with TALOS_WAIT=0
  run_and_keep failed cluster-bootstrap
  run_and_keep failed cluster-talos --yes < /dev/null
  reset_environment
  rm "$STATE/silent.$(node_address worker-3)"
  : > "$STATE/changes"
  echo worker-3 > "$STATE/new-nodes"
  run_and_keep failed cluster-talos <<< no
  run_and_keep failed cluster-talos --yes < /dev/null
  run_and_keep ok cluster-talos --onboard --yes < /dev/null
  run_and_keep ok cluster-talos < /dev/null
  printf '%s\n' cp-2 worker-1 > "$STATE/talos-behind"
  : > "$STATE/k8s-behind"
  run_and_keep failed cluster-upgrade <<< no
  run_and_keep failed cluster-upgrade-k8s <<< no
  : > "$STATE/api-down"
  run_and_keep failed cluster-upgrade --yes < /dev/null
  rm "$STATE/api-down"
  run_and_keep ok cluster-upgrade --yes < /dev/null
  run_and_keep ok cluster-upgrade-k8s --yes < /dev/null
  run_and_keep ok cluster-upgrade < /dev/null
  run_and_keep ok cluster-upgrade-k8s < /dev/null

  markers+=(
    AGE-SECRET-KEY-MARKER-AGE-KEY-FILE
    marker-bundle-secret
    marker-sops-age-key
    marker-certificate-authority-data
    marker-client-certificate-data
    marker-client-key-data
  )
  grep -q '^talman apply ' "$RECORD/argv"
  grep -q '^kubectl ' "$RECORD/argv"
  grep -q '^yq ' "$RECORD/argv"
  [[ ${printed[*]} == *"no answer on the Talos API port"* ]]
  [[ ${printed[*]} != *"$KUBE_API_ADDRESS"* ]]
  # The kubeconfig and the bundle hold their own secrets; nothing else may.
  rm -r "$BUNDLE" "$CLUSTER/clusterconfig"
  for marker in "${markers[@]}"; do
    absent "$marker" "$RECORD/argv"
    [[ ${printed[*]} != *"$marker"* ]]
    absent "$marker" "$REPO"
  done
}
