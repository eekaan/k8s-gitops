#!/usr/bin/env bats
# Proves features/cluster-flux.feature; each test carries its scenario's title.
# The recipes run from a copy of the repository. Making the Flux age key, encrypting and decrypting
# with it, and rendering are local and offline, so those run the pinned age-keygen, sops, yq and
# jq, recorded on their way, with every key inside the test's temporary directory. kubectl and
# helm, which would reach the cluster, are recording fakes that keep what is applied and installed
# in the test's directory and answer from it.

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
  YQ=$(command -v yq)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$BIN" "$RECORD" "$STATE/applied" "$STATE/objects" "$STATE/helm" "$BATS_TEST_TMPDIR/keys" \
    "$BATS_TEST_TMPDIR/repo/talos/lab-sto2/clusterconfig"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  CLUSTER="$REPO/kubernetes/clusters/lab-sto2"
  TALMAN="$REPO/talos/lab-sto2/talman.yaml"
  # The scripts, the kubernetes/ tree and both SOPS rules the recipes read, so no run touches this
  # checkout; a kubeconfig the fakes never read.
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp -R "$ROOT/kubernetes" "$REPO/kubernetes"
  cp "$ROOT/.sops.yaml" "$REPO/.sops.yaml"
  cp "$ROOT/talos/.sops.yaml" "$REPO/talos/.sops.yaml"
  cp "$BATS_FILE_TMPDIR/talman.yaml" "$TALMAN"
  : > "$REPO/talos/lab-sto2/clusterconfig/kubeconfig"
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise < /dev/null
  FLUX_KEY="$BATS_TEST_TMPDIR/keys/flux.agekey"
  DOMAIN='marker-domain.example.com'
  BASE_ENVIRONMENT=(
    FLUX_AGE_KEY_FILE="$FLUX_KEY"
    CLUSTER_DOMAIN="$DOMAIN"
    TMPDIR="$BATS_TEST_TMPDIR"
  )
  reset_environment
  fake_cluster
  record age-keygen sops yq jq
}

# fake NAME: a binary first on the recipe's PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# fake_tool NAME: like fake, with RECORD, STATE and the real yq set in the fake for its body to use.
fake_tool() {
  { printf 'RECORD=%q STATE=%q YQ=%q\n' "$RECORD" "$STATE" "$YQ"; cat; } | fake "$1"
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

# fake_cluster: kubectl and helm against a cluster kept in STATE, which starts with nodes and
# Cilium and without Flux.
#   applied/NNN.yaml        what each kubectl apply read on standard input, in order
#   objects/KIND.NS.NAME.json each applied object as last applied
#   helm/RELEASE/args       the arguments of helm's last upgrade of RELEASE, one per line
#   helm/RELEASE/values.N.yaml the Nth values file it got, standard input included
#   RELEASE                 helm installed RELEASE; flux-operator brings the FluxInstance kind, and
#                           flux-instance the FluxInstance flux
#   apply-fails.NAME        kubectl apply fails on the object NAME
#   instance-not-ready      the FluxInstance never becomes Ready
fake_cluster() {
  fake_tool kubectl <<'EOF'
printf '%s\n' "kubectl $*" >> "$RECORD/argv"
args=" $* "
case $1 in
  apply)
    file=$STATE/applied/$(printf '%03d' $(($(find "$STATE/applied" -type f | wc -l) + 1))).yaml
    cat > "$file"
    if [[ $("$YQ" ea '[.] | length' "$file") != 1 ]]; then
      echo "fake kubectl: expected one object on standard input" >&2
      exit 1
    fi
    kind=$("$YQ" '.kind' "$file") name=$("$YQ" '.metadata.name' "$file")
    if [[ -e $STATE/apply-fails.$name ]]; then
      echo "Error from server: stand-in for a failed apply of $name" >&2
      exit 1
    fi
    "$YQ" -o json '.' "$file" > "$STATE/objects/$kind.$("$YQ" '.metadata.namespace // ""' "$file").$name.json"
    echo "${kind,,}/$name serverside-applied"
    ;;
  get)
    if [[ $args == *" /readyz "* ]]; then
      echo ok
    elif [[ $args == *customresourcedefinition* || $args == *" crd "* ]]; then
      if [[ -e $STATE/flux-operator ]]; then
        echo customresourcedefinition.apiextensions.k8s.io/fluxinstances.fluxcd.controlplane.io
      fi
    elif [[ $args == *fluxinstance* ]]; then
      if [[ ! -e $STATE/flux-operator ]]; then
        echo 'error: the server does not have a resource type "fluxinstances"' >&2
        exit 1
      fi
      if [[ -e $STATE/flux-instance ]]; then
        echo fluxinstance.fluxcd.controlplane.io/flux
      fi
    elif [[ $args == *" cluster-config "* ]]; then
      object=$STATE/objects/ConfigMap.flux-system.cluster-config.json
      if [[ -e $object ]]; then
        cat "$object"
      elif [[ $args != *" --ignore-not-found "* ]]; then
        echo 'Error from server (NotFound): configmaps "cluster-config" not found' >&2
        exit 1
      fi
    else
      echo "fake kubectl: nothing to get for: $*" >&2
      exit 1
    fi
    ;;
  wait)
    if [[ $args == *fluxinstance* && -e $STATE/instance-not-ready ]]; then
      echo "error: timed out waiting for the condition on fluxinstances/flux" >&2
      exit 1
    fi
    ;;
esac
EOF
  fake_tool helm <<'EOF'
printf '%s\n' "helm $*" >> "$RECORD/argv"
case $1 in
  list) echo '[]' ;;
  get)
    echo "Error: release: not found" >&2
    exit 1
    ;;
  upgrade)
    args=("$@") operands=() values=()
    for ((i = 1; i < ${#args[@]}; i++)); do
      case ${args[i]} in
        -f | --values)
          i=$((i + 1))
          values+=("${args[i]}")
          ;;
        --values=*) values+=("${args[i]#*=}") ;;
        -n | --namespace | --version | --timeout | --kube-context | --set | --set-string | --set-file) i=$((i + 1)) ;;
        -*) ;;
        *) operands+=("${args[i]}") ;;
      esac
    done
    release=${operands[0]}
    dir=$STATE/helm/$release
    rm -rf "$dir"
    mkdir -p "$dir"
    printf '%s\n' "${args[@]}" > "$dir/args"
    for ((i = 0; i < ${#values[@]}; i++)); do
      if [[ ${values[i]} == - ]]; then
        cat > "$dir/values.$((i + 1)).yaml"
      else
        cp -- "${values[i]}" "$dir/values.$((i + 1)).yaml"
      fi
    done
    : > "$STATE/$release"
    echo "Release \"$release\" has been upgraded. Happy Helming!"
    ;;
esac
EOF
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

# calls PATTERN: the recorded calls matching the extended regex, one per line.
calls() {
  grep -E -- "$1" "$RECORD/argv" 2> /dev/null || true
}

# call_line PATTERN: the line number in the record of the first call matching the extended regex.
call_line() {
  grep -n -m1 -E -- "$1" "$RECORD/argv" | cut -d: -f1
}

# applied: each object kubectl was asked to apply, in order, as KIND/NAMESPACE/NAME.
applied() {
  local file
  for file in "$STATE"/applied/*.yaml; do
    [[ -e $file ]] || continue
    yq '.kind + "/" + (.metadata.namespace // "") + "/" + .metadata.name' "$file"
  done
}

# object KIND NAMESPACE NAME: the object as last applied, in JSON.
object() {
  cat "$STATE/objects/$1.$2.$3.json"
}

# The four objects the recipes apply before Flux, sorted.
PRE_FLUX='ConfigMap/flux-system/cluster-config
Namespace//flux-system
Secret/flux-system/cluster-secrets
Secret/flux-system/sops-age'

# flux_key: a Flux age key at FLUX_KEY, made in the test's directory, with its recipient in the
# copy's .sops.yaml as cluster-flux-age-key writes it.
flux_key() {
  age-keygen -o "$FLUX_KEY" 2> /dev/null
  RECIPIENT=$(age-keygen -y "$FLUX_KEY") yq -i '.creation_rules[].age = strenv(RECIPIENT)' "$REPO/.sops.yaml"
}

# encrypted_secrets NAME=VALUE...: the cluster's secrets/cluster-secrets.sops.yaml holding those
# keys, encrypted by the copy's .sops.yaml, and cluster-secrets.example.yaml listing them.
encrypted_secrets() {
  local file=kubernetes/clusters/lab-sto2/secrets/cluster-secrets.sops.yaml pair
  mkdir -p "$CLUSTER/secrets"
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: cluster-secrets\n  namespace: flux-system\nstringData:\n' > "$REPO/$file"
  echo '---' > "$CLUSTER/cluster-secrets.example.yaml"
  for pair; do
    printf '  %s: %s\n' "${pair%%=*}" "${pair#*=}" >> "$REPO/$file"
    printf '%s: example\n' "${pair%%=*}" >> "$CLUSTER/cluster-secrets.example.yaml"
  done
  (cd "$REPO" && sops encrypt --in-place "$file")
}

# helm_operands RELEASE: the release and the chart helm's upgrade of RELEASE got, one per line.
helm_operands() {
  local args i
  mapfile -t args < "$STATE/helm/$1/args"
  for ((i = 1; i < ${#args[@]}; i++)); do
    case ${args[i]} in
      -n | --namespace | --version | -f | --values | --timeout | --kube-context | --set | --set-string | --set-file) i=$((i + 1)) ;;
      -*) ;;
      *) echo "${args[i]}" ;;
    esac
  done
}

# helm_flag RELEASE FLAG...: the value helm's upgrade of RELEASE got for the first of FLAG... it
# was given, as "FLAG VALUE" or "FLAG=VALUE".
helm_flag() {
  local release=$1 args i flag
  shift
  mapfile -t args < "$STATE/helm/$release/args"
  for ((i = 0; i < ${#args[@]}; i++)); do
    for flag in "$@"; do
      if [[ ${args[i]} == "$flag" ]]; then
        echo "${args[i + 1]}"
        return 0
      elif [[ ${args[i]} == "$flag="* ]]; then
        echo "${args[i]#*=}"
        return 0
      fi
    done
  done
  return 1
}

@test "The pre-Flux objects are applied before the operator" {
  flux_key

  recipe cluster-flux

  [ "$status" -eq 0 ]
  [ "$(applied | sort)" = "$PRE_FLUX" ]
  [ "$(applied | head -1)" = Namespace//flux-system ]
  # Every object reached kubectl on standard input.
  [ "$(calls '^kubectl apply ' | wc -l)" -eq 4 ]
  [ "$(calls '^kubectl apply ' | grep -cvE -- ' (-f -|--filename[= ]-)( |$)')" -eq 0 ]
  operator=$(call_line '^helm upgrade .*/flux-operator( |$)')
  applied_last=$(grep -n '^kubectl apply ' "$RECORD/argv" | tail -1 | cut -d: -f1)
  [ -n "$operator" ] && [ -n "$applied_last" ]
  [ "$applied_last" -lt "$operator" ]
}

@test "cluster-config holds exactly the keys the repository declares" {
  flux_key

  recipe cluster-config

  [ "$status" -eq 0 ]
  config=$(object ConfigMap flux-system cluster-config)
  [ "$(jq -r '.data | keys | join(" ")' <<< "$config")" = "$(yq 'keys | sort | join(" ")' "$CLUSTER/cluster-config.example.yaml")" ]
  [ "$(jq -r '.data.CLUSTER_DOMAIN' <<< "$config")" = "$DOMAIN" ]
  [ "$(jq -r '.data.NODE_CIDR' <<< "$config")" = "$(yq '.values.nodeSubnet' "$TALMAN")" ]
  regex=$(jq -r '.data.NODE_NAME_REGEX' <<< "$config")
  for name in $(yq '.nodes[].hostname' "$TALMAN"); do
    [[ $name =~ ^($regex)$ ]]
  done
  # A node OpenTofu adds later is numbered after the others and matches too; no other name does.
  [[ worker-4 =~ ^($regex)$ ]]
  for name in other-1 worker- worker-1-x xworker-1 worker-1.example.com; do
    [[ ! $name =~ ^($regex)$ ]]
  done
}

@test "cluster-config applies the same objects when it runs again" {
  flux_key
  recipe cluster-config
  [ "$status" -eq 0 ]
  cp -R "$STATE/objects" "$BATS_TEST_TMPDIR/objects.before"

  recipe cluster-config

  [ "$status" -eq 0 ]
  [ "$(applied | sort | uniq -c | awk '{print $1}' | sort -u)" = 2 ]
  diff -r "$STATE/objects" "$BATS_TEST_TMPDIR/objects.before"
}

@test "A key that cannot be filled fails the recipe by name" {
  flux_key
  example="$CLUSTER/cluster-config.example.yaml"

  # A key the example lists that cluster-config has no source for.
  printf 'EXTRA_SETTING: example\n' >> "$example"
  recipe cluster-config
  [ "$status" -ne 0 ]
  [[ $output == *"EXTRA_SETTING"* ]]
  [ -z "$(calls '^kubectl ')" ]

  # A key cluster-config fills that the example does not list.
  cp "$ROOT/kubernetes/clusters/lab-sto2/cluster-config.example.yaml" "$example"
  yq -i 'del(.NODE_NAME_REGEX)' "$example"
  recipe cluster-config
  [ "$status" -ne 0 ]
  [[ $output == *"NODE_NAME_REGEX"* ]]
  [ -z "$(calls '^kubectl ')" ]

  # A source that gives no value.
  cp "$ROOT/kubernetes/clusters/lab-sto2/cluster-config.example.yaml" "$example"
  yq -i 'del(.values.nodeSubnet)' "$TALMAN"
  recipe cluster-config
  [ "$status" -ne 0 ]
  [[ $output == *"NODE_CIDR"* ]]
  [ -z "$(calls '^kubectl ')" ]

  cp "$BATS_FILE_TMPDIR/talman.yaml" "$TALMAN"
  without CLUSTER_DOMAIN
  recipe cluster-config
  [ "$status" -ne 0 ]
  [[ $output == *"CLUSTER_DOMAIN is not set"* ]]
  [ -z "$(calls '^kubectl ')" ]
}

@test "The cluster age key reaches the cluster under a key Flux reads and is never shown" {
  printed=()

  recipe cluster-flux-age-key

  [ "$status" -eq 0 ]
  printed+=("$output")
  [ "$(stat -c %a "$FLUX_KEY")" = 600 ]
  recipient=$(age-keygen -y "$FLUX_KEY")
  [ "$output" = "$recipient" ]
  [ "$(yq '.creation_rules[].age' "$REPO/.sops.yaml")" = "$recipient" ]
  cp "$FLUX_KEY" "$BATS_TEST_TMPDIR/key.before"
  cp "$REPO/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"

  recipe cluster-flux-age-key

  [ "$status" -eq 0 ]
  printed+=("$output")
  [ "$output" = "$recipient" ]
  cmp "$FLUX_KEY" "$BATS_TEST_TMPDIR/key.before"
  cmp "$REPO/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"

  recipe cluster-config

  [ "$status" -eq 0 ]
  printed+=("$output")
  secret=$(object Secret flux-system sops-age)
  keys=$(jq -r '(.data // {}) + (.stringData // {}) | keys[]' <<< "$secret")
  [ "$(wc -l <<< "$keys")" -eq 1 ]
  [[ $keys == *.agekey ]]
  jq -r --arg key "$keys" '.data[$key]' <<< "$secret" | base64 -d | cmp - "$FLUX_KEY"
  # kustomize-controller reads it from its own namespace.
  [ "$(jq -r '.metadata.namespace' <<< "$secret")" = flux-system ]
  line=$(grep '^AGE-SECRET-KEY-' "$FLUX_KEY")
  absent "$line" "$RECORD/argv" "$REPO"
  [[ ${printed[*]} != *"$line"* ]]
}

@test "cluster-flux-age-key refuses a key file inside the repository" {
  without FLUX_AGE_KEY_FILE
  with FLUX_AGE_KEY_FILE="$REPO/kubernetes/flux.agekey"

  recipe cluster-flux-age-key

  [ "$status" -ne 0 ]
  [[ $output == *"FLUX_AGE_KEY_FILE names a path inside the repository"* ]]
  [ ! -e "$REPO/kubernetes/flux.agekey" ]
  cmp "$REPO/.sops.yaml" "$ROOT/.sops.yaml"
}

@test "cluster-flux-age-key leaves a .sops.yaml naming another recipient alone" {
  age-keygen -o "$BATS_TEST_TMPDIR/keys/other.agekey" 2> /dev/null
  other=$(age-keygen -y "$BATS_TEST_TMPDIR/keys/other.agekey")
  RECIPIENT=$other yq -i '.creation_rules[].age = strenv(RECIPIENT)' "$REPO/.sops.yaml"
  cp "$REPO/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"

  recipe cluster-flux-age-key

  [ "$status" -ne 0 ]
  [[ $output == *".sops.yaml names another recipient"* ]]
  cmp "$REPO/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"
  [ ! -e "$FLUX_KEY" ]
}

@test "the Talos age key is refused as the Flux age key" {
  flux_key
  RECIPIENT=$(age-keygen -y "$FLUX_KEY") yq -i '.creation_rules[].age = strenv(RECIPIENT)' "$REPO/talos/.sops.yaml"

  for name in cluster-flux-age-key cluster-config cluster-flux; do
    recipe "$name"

    [ "$status" -ne 0 ]
    [[ $output == *"the Talos age key"* ]]
  done
  [ -z "$(calls '^(kubectl|helm|sops) ')" ]
}

@test "Without an encrypted secrets file an empty cluster-secrets is applied" {
  flux_key
  [ ! -e "$CLUSTER/secrets/cluster-secrets.sops.yaml" ]
  [ "$(yq 'length' "$CLUSTER/cluster-secrets.example.yaml")" -eq 0 ]

  recipe cluster-config

  [ "$status" -eq 0 ]
  secret=$(object Secret flux-system cluster-secrets)
  [ "$(jq '(.data // {}) + (.stringData // {}) | length' <<< "$secret")" -eq 0 ]
  [ -z "$(calls '^sops ')" ]

  # An example that lists a key with nothing to fill it fails, naming the key.
  printf -- '---\nAPI_TOKEN: example\n' > "$CLUSTER/cluster-secrets.example.yaml"
  : > "$RECORD/argv"

  recipe cluster-config

  [ "$status" -ne 0 ]
  [[ $output == *API_TOKEN* ]]
  [ -z "$(calls '^kubectl ')" ]
}

@test "an encrypted secrets file reaches the cluster decrypted, through a pipe only" {
  flux_key
  encrypted_secrets API_TOKEN=marker-api-token
  [ "$(sops filestatus "$CLUSTER/secrets/cluster-secrets.sops.yaml")" = '{"encrypted":true}' ]

  recipe cluster-config

  [ "$status" -eq 0 ]
  secret=$(object Secret flux-system cluster-secrets)
  [ "$(jq -r '(.data // {} | map_values(@base64d)) + (.stringData // {}) | .API_TOKEN' <<< "$secret")" = marker-api-token ]
  [ -n "$(calls '^sops decrypt ')" ]
  absent marker-api-token "$RECORD/argv" "$REPO"
  [[ $output != *marker-api-token* ]]

  # Its keys must be the ones the example lists.
  printf -- '---\nOTHER_TOKEN: example\n' > "$CLUSTER/cluster-secrets.example.yaml"
  : > "$RECORD/argv"

  recipe cluster-config

  [ "$status" -ne 0 ]
  [[ $output == *API_TOKEN* && $output == *OTHER_TOKEN* ]]
  [ -z "$(calls '^kubectl ')" ]
}

@test "an example key list yq cannot read stops cluster-config" {
  flux_key
  # The example holds {}, after which a second map is no YAML at all.
  printf 'API_TOKEN: example\n' >> "$CLUSTER/cluster-secrets.example.yaml"

  recipe cluster-config

  [ "$status" -ne 0 ]
  [[ $output == *"cannot read the keys of kubernetes/clusters/lab-sto2/cluster-secrets.example.yaml"* ]]
  [ -z "$(calls '^kubectl ')" ]
}

@test "the cluster directory lists nothing under secrets/" {
  run yq '.resources[]' "$ROOT/kubernetes/clusters/lab-sto2/kustomization.yaml"

  [ "$status" -eq 0 ]
  [[ $output != *secrets/* ]]
}

@test "The operator and instance are installed from their application directories" {
  flux_key

  recipe cluster-flux

  [ "$status" -eq 0 ]
  for release in flux-operator flux-instance; do
    app="$CLUSTER/flux-system/$release/app"
    url=$(yq -e '.spec.url' "$app/ocirepository.yaml")
    [ "$(helm_operands "$release")" = "$release"$'\n'"$url" ]
    grep -qxE -- '--install|-i' "$STATE/helm/$release/args"
    [ "$(helm_flag "$release" --version)" = "$(yq -e '.spec.ref.tag' "$app/ocirepository.yaml")" ]
    [ "$(helm_flag "$release" -n --namespace)" = flux-system ]
    # values.yaml as it is, and nothing else.
    [ "$(find "$STATE/helm/$release" -name 'values.*' | wc -l)" -eq 1 ]
    cmp "$STATE/helm/$release/values.1.yaml" "$app/values.yaml"
    [ "$(grep -cE -- '^--(set|set-[a-z]+|reuse-values|reset-then-reuse-values)(=|$)' "$STATE/helm/$release/args")" -eq 0 ]
  done
  operator=$(call_line '^helm upgrade .*/flux-operator( |$)')
  instance=$(call_line '^helm upgrade .*/flux-instance( |$)')
  ready=$(call_line '^kubectl wait .*fluxinstance')
  [ -n "$operator" ] && [ -n "$instance" ] && [ -n "$ready" ]
  [ "$operator" -lt "$instance" ]
  [ "$instance" -lt "$ready" ]
  wait=$(calls '^kubectl wait .*fluxinstance')
  [[ " $wait " == *"/flux "* && " $wait " == *" --for=condition=Ready "* ]]
  [[ " $wait " == *" --namespace flux-system "* || " $wait " == *" -n flux-system "* ]]
  [[ ${lines[-1]} == *"next:"* ]]
}

@test "a FluxInstance that never becomes Ready fails cluster-flux, naming the step" {
  flux_key
  : > "$STATE/instance-not-ready"

  recipe cluster-flux

  [ "$status" -ne 0 ]
  [[ $output == *"cluster-flux: failed while waiting for the FluxInstance to be Ready"* ]]
}

@test "a failed apply names the object it failed on" {
  flux_key
  : > "$STATE/apply-fails.sops-age"

  recipe cluster-flux

  [ "$status" -ne 0 ]
  [[ $output == *"cluster-config: failed while applying the Secret sops-age"* ]]
  [[ $output == *"cluster-flux: failed while applying the objects Flux needs before it starts"* ]]
  [ -z "$(calls '^helm ')" ]
}

@test "An installed FluxInstance is not reinstalled" {
  flux_key
  : > "$STATE/flux-operator"
  : > "$STATE/flux-instance"

  recipe cluster-flux

  [ "$status" -ne 0 ]
  [[ $output == *"--reapply"* ]]
  [ -z "$(calls '^(kubectl apply|helm upgrade) ')" ]

  : > "$RECORD/argv"
  recipe cluster-flux --reapply

  [ "$status" -eq 0 ]
  [ "$(applied | sort)" = "$PRE_FLUX" ]
  [ -z "$(calls '^helm ')" ]
  [ -z "$(calls '^kubectl wait ')" ]
}

@test "cluster-flux refuses an argument it does not know before it runs anything" {
  flux_key

  recipe cluster-flux --force

  [ "$status" -eq 2 ]
  [[ $output == *"usage: cluster-flux [cluster] [--reapply]"* ]]
  [ -z "$(calls '^(kubectl|helm) ')" ]
}

@test "the Flux recipes name what they need before they call anything" {
  rm "$REPO/talos/lab-sto2/clusterconfig/kubeconfig"
  without FLUX_AGE_KEY_FILE
  without CLUSTER_DOMAIN

  for name in cluster-config cluster-flux; do
    recipe "$name"

    [ "$status" -ne 0 ]
    [[ $output == *"neither FLUX_AGE_KEY_FILE nor FLUX_AGE_KEY is set"* ]]
    [[ $output == *"CLUSTER_DOMAIN is not set"* ]]
    [[ $output == *".sops.yaml holds no Flux age recipient yet"* ]]
    [[ $output == *"talos/lab-sto2/clusterconfig/kubeconfig does not exist"* ]]
  done
  recipe cluster-flux-age-key
  [ "$status" -ne 0 ]
  [[ $output == *"FLUX_AGE_KEY_FILE is not set"* ]]
  [ -z "$(calls '^(kubectl|helm|sops|age-keygen) ')" ]

  # A key file that is not there, and one that holds another key than .sops.yaml names.
  reset_environment
  touch "$REPO/talos/lab-sto2/clusterconfig/kubeconfig"
  flux_key
  mv "$FLUX_KEY" "$BATS_TEST_TMPDIR/keys/moved.agekey"
  recipe cluster-config
  [ "$status" -ne 0 ]
  [[ $output == *"FLUX_AGE_KEY_FILE names no file"* ]]
  age-keygen -o "$FLUX_KEY" 2> /dev/null
  recipe cluster-config
  [ "$status" -ne 0 ]
  [[ $output == *"not the key .sops.yaml encrypts to"* ]]
  [ -z "$(calls '^(kubectl|helm|sops) ')" ]
}

@test "the Flux recipes refuse Go's HTTP/2 debug log" {
  flux_key
  with GODEBUG=http2debug=2

  for name in cluster-flux-age-key cluster-config cluster-flux; do
    recipe "$name"

    [ "$status" -ne 0 ]
    [[ $output == *"GODEBUG sets http2debug"* ]]
  done
  [ -z "$(calls '^(kubectl|helm|sops) ')" ]
}

@test "No deployment value or secret reaches a command line or the output" {
  flux_key
  encrypted_secrets API_TOKEN=marker-api-token
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

  run_and_keep ok cluster-flux-age-key
  run_and_keep ok cluster-config
  run_and_keep ok cluster-config
  : > "$STATE/apply-fails.cluster-config"
  run_and_keep failed cluster-config
  rm "$STATE/apply-fails.cluster-config"
  : > "$STATE/instance-not-ready"
  run_and_keep failed cluster-flux
  rm "$STATE/instance-not-ready"
  run_and_keep failed cluster-flux
  run_and_keep ok cluster-flux --reapply
  rm "$STATE/flux-operator" "$STATE/flux-instance"
  run_and_keep ok cluster-flux
  # The key itself in the environment, as in CI.
  without FLUX_AGE_KEY_FILE
  with FLUX_AGE_KEY="$(cat "$FLUX_KEY")"
  run_and_keep ok cluster-flux --reapply
  reset_environment
  printf 'EXTRA_SETTING: example\n' >> "$CLUSTER/cluster-config.example.yaml"
  run_and_keep failed cluster-config
  run_and_keep failed cluster-flux --reapply
  cp "$ROOT/kubernetes/clusters/lab-sto2/cluster-config.example.yaml" "$CLUSTER/"

  config=$(object ConfigMap flux-system cluster-config)
  markers=(
    "$(grep '^AGE-SECRET-KEY-' "$FLUX_KEY")"
    marker-api-token
    "$DOMAIN"
    "$(jq -r '.data.NODE_CIDR' <<< "$config")"
    "$(jq -r '.data.NODE_NAME_REGEX' <<< "$config")"
  )
  grep -q '^sops decrypt ' "$RECORD/argv"
  grep -q '^kubectl apply ' "$RECORD/argv"
  grep -q '^helm upgrade ' "$RECORD/argv"
  # talman.yaml holds the node subnet and the node names; nothing else may.
  rm "$TALMAN"
  for marker in "${markers[@]}"; do
    [ -n "$marker" ]
    absent "$marker" "$RECORD/argv"
    [[ ${printed[*]} != *"$marker"* ]]
    absent "$marker" "$REPO"
  done
}
