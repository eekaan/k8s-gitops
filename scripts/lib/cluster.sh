# shellcheck shell=bash
# Shared by scripts/cluster-env, the cluster-* scripts, the install scripts, the adoption check and
# the secrets bundle check: the Talos age key's location, talos/.sops.yaml's recipient, the check
# that a secrets bundle is encrypted, a cluster's nodes and the wait for their Talos API, the line
# that names the step a recipe failed in, the talman run that keeps its output out of a CI log, the
# Flux age key and the other objects Flux needs before it starts, the release an application's
# HelmRelease makes, and the install of an application before Flux. Builds on scripts/lib/infra.sh,
# which reads the environment. Nothing here prints a secret or a deployment value, or passes one as
# an argument: sops and talman get the Talos age key's location from their environment, and the Flux
# age key and the values of the objects applied before Flux reach age-keygen, jq and kubectl on
# standard input.

# shellcheck source=scripts/lib/infra.sh
. "$(dirname "${BASH_SOURCE[0]}")/infra.sh"

sops_config=$infra_root/talos/.sops.yaml
# The rule for the SOPS files under kubernetes/, which Flux decrypts with the Flux age key.
flux_sops_config=$infra_root/.sops.yaml

# report_failed_step: from here on, a recipe that fails ends with a line naming the step it was in,
# which it keeps in step.
report_failed_step() {
  step="checking the environment"
  trap 'failed_step $?' EXIT
}

failed_step() {
  if (($1 != 0)); then
    infra_error "failed while $step"
  fi
}

# cluster_talman ARG...: talman with ARG... on the cluster scripts/cluster-env set up. talman's output,
# talosctl's within it, names the nodes by address and shows configuration diffs, and CI logs are
# public, so with CI set it goes to talman_log, in the cluster's clusterconfig/, which git ignores,
# and only whether talman succeeded and where its output is are printed. The file holds what this
# run's talman calls printed. With --detailed-exit-code, talman's 2 reports changes, not a failure.
# Returns talman's status.
cluster_talman() {
  local status=0 log
  if [[ -z ${CI:-} ]]; then
    talman "$@"
    return
  fi
  if [[ -z ${talman_log_started-} ]]; then
    # shellcheck disable=SC2154 # scripts/cluster-env sets talman_log
    (umask 077 && mkdir -p "${talman_log%/*}" && : > "$talman_log")
    talman_log_started=1
  fi
  talman "$@" >> "$talman_log" 2>&1 || status=$?
  log=${talman_log#"$infra_root"/}
  if ((status == 0)) || { ((status == 2)) && [[ " $* " == *" --detailed-exit-code "* ]]; }; then
    printf '%s: talman %s succeeded; its output is in %s\n' "${0##*/}" "$1" "$log"
  else
    infra_error "talman $1 failed; its output is in $log"
  fi
  return "$status"
}

# inside_repository PATH: whether PATH, with symlinks resolved, lies in the repository.
inside_repository() {
  local resolved root
  resolved=$(realpath -m -- "$1")
  root=$(realpath -m -- "$infra_root")
  [[ $resolved == "$root" || $resolved == "$root"/* ]]
}

# require_age_key: the Talos age key's location is set, as SOPS_AGE_KEY holding the key (CI) or
# SOPS_AGE_KEY_FILE naming a file outside the repository. sops reads either itself.
require_age_key() {
  if [[ -n ${SOPS_AGE_KEY_FILE:-} ]] && inside_repository "$SOPS_AGE_KEY_FILE"; then
    infra_error "SOPS_AGE_KEY_FILE names a path inside the repository; the Talos age key is kept outside it"
    return 1
  fi
  if [[ -n ${SOPS_AGE_KEY:-} ]]; then
    return 0
  fi
  if [[ -z ${SOPS_AGE_KEY_FILE:-} ]]; then
    infra_error "neither SOPS_AGE_KEY_FILE nor SOPS_AGE_KEY is set; set SOPS_AGE_KEY_FILE in .env or the environment"
    return 1
  fi
  if [[ ! -f $SOPS_AGE_KEY_FILE ]]; then
    infra_error "SOPS_AGE_KEY_FILE names no file; just cluster-age-key creates the key there"
    return 1
  fi
}

# sops_recipient: the age recipient talos/.sops.yaml encrypts secrets bundles to.
sops_recipient() {
  yq '.creation_rules[0].age // ""' "$sops_config"
}

# bundle_encrypted FILE: whether FILE is SOPS-encrypted: it carries SOPS metadata, which is what
# sops filestatus reads, and every value in it is sops ciphertext. Nothing of FILE is printed.
bundle_encrypted() {
  local status counts values plaintext
  status=$(sops filestatus "$1" 2> /dev/null) || return 1
  jq -e '.encrypted == true' <<< "$status" > /dev/null || return 1
  # How many values there are, and how many of them are not ciphertext.
  counts=$(yq 'del(.sops) | [.. | select(kind == "scalar")]
    | [length, (map(select(tag != "!!str" or (test("^ENC\\[") | not))) | length)] | join(" ")' "$1" 2> /dev/null) || return 1
  read -r values plaintext <<< "$counts"
  [[ $values =~ ^[0-9]+$ && $plaintext == 0 ]] && ((values > 0))
}

# talman_nodes TALMAN_FILE: each node in TALMAN_FILE as its hostname and the address talman reaches
# it on, one node per line, in the file's order. Fails, naming the file, when a node lacks either or
# the file lists none.
talman_nodes() {
  local nodes line
  nodes=$(yq '.nodes[] | (.hostname // "") + " " + (.ipAddress // "")' "$1") || return 1
  if [[ -z $nodes ]]; then
    infra_error "${1#"$infra_root"/} lists no nodes"
    return 1
  fi
  while IFS= read -r line; do
    if [[ ! $line =~ ^[a-z0-9][a-z0-9.-]*\ [A-Za-z0-9.:-]+$ ]]; then
      infra_error "${1#"$infra_root"/} has a node without a hostname or an address"
      return 1
    fi
  done <<< "$nodes"
  printf '%s\n' "$nodes"
}

# talos_api_answers ADDRESS: whether ADDRESS accepts a connection on the Talos API port, 50000,
# within three seconds. A node in maintenance mode answers on the same port.
talos_api_answers() {
  # shellcheck disable=SC2016 # the inner bash expands $1, its own argument, so no address is code
  timeout 3 bash -c ': < "/dev/tcp/$1/50000"' talos-api "$1" 2> /dev/null
}

# wait_for_talos_api TALMAN_FILE: waits until every node in TALMAN_FILE answers on the Talos API
# port, trying those still silent every ten seconds, for up to TALOS_WAIT seconds (600 when unset).
# Fails naming the nodes that never answered, by hostname only, as their addresses belong to the
# deployment. A node that never answers is the operator's to reboot; nothing here reboots it.
wait_for_talos_api() {
  local wait=${TALOS_WAIT:-600} nodes node address deadline names
  local -a waiting silent
  nodes=$(talman_nodes "$1") || return 1
  mapfile -t waiting <<< "$nodes"
  deadline=$((SECONDS + 10#$wait))
  while :; do
    silent=()
    for node in "${waiting[@]}"; do
      address=${node#* }
      talos_api_answers "$address" || silent+=("$node")
    done
    ((${#silent[@]} > 0)) || return 0
    names=$(printf '%s\n' "${silent[@]%% *}" | paste -sd, - | sed 's/,/, /g')
    if ((SECONDS >= deadline)); then
      infra_error "no answer on the Talos API port after ${wait}s from $names; reboot a node that does not answer, and run this again"
      return 1
    fi
    echo "waiting for the Talos API to answer on $names"
    waiting=("${silent[@]}")
    sleep 10
  done
}

# require_kubeconfig: the cluster's kubeconfig, which KUBECONFIG names, exists.
require_kubeconfig() {
  if [[ ! -f $KUBECONFIG ]]; then
    infra_error "${KUBECONFIG#"$infra_root"/} does not exist; just cluster-kubeconfig fetches it"
    return 1
  fi
}

# flux_recipient: the age recipient .sops.yaml encrypts the SOPS files under kubernetes/ to.
flux_recipient() {
  yq '.creation_rules[0].age // ""' "$flux_sops_config"
}

# flux_age_key: the Flux age key, from FLUX_AGE_KEY (CI) or the file FLUX_AGE_KEY_FILE names, for a
# pipe only.
flux_age_key() {
  if [[ -n ${FLUX_AGE_KEY:-} ]]; then
    printf '%s\n' "$FLUX_AGE_KEY"
  else
    cat < "$FLUX_AGE_KEY_FILE"
  fi
}

# require_flux_age_key: .sops.yaml names a recipient, and the Flux age key is set, as FLUX_AGE_KEY
# holding the key (CI) or FLUX_AGE_KEY_FILE naming a file outside the repository, is the key of that
# recipient and is not the Talos age key, which a key held in the cluster must never be. age-keygen
# derives the recipient from the key on its standard input.
require_flux_age_key() {
  local written recipient complete=1
  written=$(flux_recipient)
  if is_placeholder "$written"; then
    infra_error ".sops.yaml holds no Flux age recipient yet; just cluster-flux-age-key writes it"
    complete=0
  fi
  if [[ -n ${FLUX_AGE_KEY_FILE:-} ]] && inside_repository "$FLUX_AGE_KEY_FILE"; then
    infra_error "FLUX_AGE_KEY_FILE names a path inside the repository; the Flux age key is kept outside it"
    return 1
  fi
  if [[ -z ${FLUX_AGE_KEY:-} ]]; then
    if [[ -z ${FLUX_AGE_KEY_FILE:-} ]]; then
      infra_error "neither FLUX_AGE_KEY_FILE nor FLUX_AGE_KEY is set; set FLUX_AGE_KEY_FILE in .env or the environment"
      return 1
    fi
    if [[ ! -f $FLUX_AGE_KEY_FILE ]]; then
      infra_error "FLUX_AGE_KEY_FILE names no file; just cluster-flux-age-key creates the key there"
      return 1
    fi
  fi
  ((complete)) || return 1
  recipient=$(flux_age_key | age-keygen -y 2> /dev/null) || recipient=
  if [[ ! $recipient =~ ^age1[0-9a-z]+$ ]]; then
    infra_error "the Flux age key is not exactly one age key"
    return 1
  fi
  if [[ $recipient == "$(sops_recipient)" ]]; then
    infra_error "the Flux age key is the Talos age key; Flux gets a key of its own, so the key the cluster holds does not open the Talos secrets bundles"
    return 1
  fi
  if [[ $recipient != "$written" ]]; then
    infra_error "the Flux age key is not the key .sops.yaml encrypts to; point FLUX_AGE_KEY_FILE at that key"
    return 1
  fi
}

# flux_sops ARG...: sops with the Flux age key as its only age key, whichever key the environment
# gives sops for the Talos secrets bundles. The key reaches sops in its environment.
flux_sops() {
  if [[ -n ${FLUX_AGE_KEY:-} ]]; then
    SOPS_AGE_KEY=$FLUX_AGE_KEY env -u SOPS_AGE_KEY_FILE -u SOPS_AGE_KEY_CMD sops "$@"
  else
    SOPS_AGE_KEY_FILE=$FLUX_AGE_KEY_FILE env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_CMD sops "$@"
  fi
}

# node_name_regex: from the node names on standard input, one per line, a regular expression (Go RE2
# syntax) that each name matches in full. A name that ends in a number stands for every number: a
# node OpenTofu adds is numbered after the others, and matches without cluster-config changing.
node_name_regex() {
  local name pattern
  local -a patterns=()
  local -A seen=()
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    pattern=$name
    if [[ $name =~ ^(.*[^0-9])[0-9]+$ ]]; then
      pattern="${BASH_REMATCH[1]}[0-9]+"
    fi
    # A hostname holds letters, digits, - and ., of which only . means something in a pattern.
    pattern=${pattern//./\\.}
    if [[ -z ${seen[$pattern]-} ]]; then
      seen[$pattern]=1
      patterns+=("$pattern")
    fi
  done
  ((${#patterns[@]} > 0)) || return 1
  local IFS='|'
  printf '%s\n' "${patterns[*]}"
}

# read_keys FILE EXPRESSION: the keys yq's EXPRESSION yields from FILE, one per line. Fails naming
# FILE when yq cannot read it, as keys read as none would pass every check.
read_keys() {
  if ! yq "$2" "$1" 2> /dev/null; then
    infra_error "cannot read the keys of ${1#"$infra_root"/}"
    return 1
  fi
}

# The values of the ConfigMap cluster-config, by key, once fill_cluster_config has run.
declare -A cluster_config=()

# fill_cluster_config CLUSTER TALMAN_FILE: fills cluster_config, and fails naming each key of the
# cluster's cluster-config.example.yaml it cannot fill and each key it fills that the example does not
# list. Every value depends on the deployment, so none is committed or printed:
#   CLUSTER_DOMAIN   the domain the cluster's applications are published under, from the environment
#   NODE_CIDR        the node subnet, values.nodeSubnet in the cluster's talman.yaml, which the
#                    cluster stack renders and the kubelets take their node addresses from
#   NODE_NAME_REGEX  a pattern of the hostnames in that talman.yaml (node_name_regex)
# A missing talman.yaml leaves its two keys to the caller's require_cluster, which names the file.
fill_cluster_config() {
  local cluster=$1 talman=$2 example value keys key complete=1
  local dns_name='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
  local -a listed=()
  local -A sources=([CLUSTER_DOMAIN]=1 [NODE_CIDR]=1 [NODE_NAME_REGEX]=1) wanted=()
  example=$infra_root/kubernetes/clusters/$cluster/cluster-config.example.yaml
  cluster_config=()
  if [[ ! -f $example ]]; then
    infra_error "${example#"$infra_root"/} does not exist; it lists the keys of cluster-config"
    return 1
  fi

  if require_env CLUSTER_DOMAIN; then
    if [[ $CLUSTER_DOMAIN =~ $dns_name ]]; then
      cluster_config[CLUSTER_DOMAIN]=$CLUSTER_DOMAIN
    else
      infra_error "cannot fill CLUSTER_DOMAIN of cluster-config: CLUSTER_DOMAIN is not a lower-case DNS name"
      complete=0
    fi
  else
    complete=0
  fi
  if [[ -f $talman ]]; then
    value=$(yq '.values.nodeSubnet // ""' "$talman" 2> /dev/null) || value=
    if [[ $value =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
      cluster_config[NODE_CIDR]=$value
    else
      infra_error "cannot fill NODE_CIDR of cluster-config: ${talman#"$infra_root"/} gives no IPv4 network in values.nodeSubnet"
      complete=0
    fi
    if value=$(talman_nodes "$talman" | cut -d' ' -f1 | node_name_regex); then
      cluster_config[NODE_NAME_REGEX]=$value
    else
      infra_error "cannot fill NODE_NAME_REGEX of cluster-config: ${talman#"$infra_root"/} gives no node hostnames"
      complete=0
    fi
  fi

  keys=$(read_keys "$example" 'keys | .[]') || return 1
  mapfile -t listed < <(printf '%s' "$keys")
  for key in "${listed[@]}"; do
    wanted[$key]=1
    if [[ -z ${sources[$key]-} ]]; then
      infra_error "cannot fill $key of cluster-config: nothing in scripts/lib/cluster.sh gives it a value"
      complete=0
    fi
  done
  for key in "${!sources[@]}"; do
    if [[ -z ${wanted[$key]-} ]]; then
      infra_error "cluster-config would set $key, which ${example#"$infra_root"/} does not list"
      complete=0
    fi
  done
  ((complete))
}

# cluster_config_manifest: the ConfigMap cluster-config in flux-system, as JSON, from cluster_config.
# The values reach jq on its standard input.
cluster_config_manifest() {
  local key
  for key in "${!cluster_config[@]}"; do
    printf '%s\0%s\0' "$key" "${cluster_config[$key]}"
  done | jq -Rs '
    split("\u0000") | .[:-1] | [range(0; length; 2) as $i | {key: .[$i], value: .[$i + 1]}]
    | {apiVersion: "v1", kind: "ConfigMap", metadata: {name: "cluster-config", namespace: "flux-system"},
       data: from_entries}'
}

# cluster_secrets_file CLUSTER: where the cluster's SOPS-encrypted cluster-secrets is committed.
cluster_secrets_file() {
  printf '%s\n' "$infra_root/kubernetes/clusters/$1/secrets/cluster-secrets.sops.yaml"
}

# check_cluster_secrets CLUSTER: the cluster's secrets/cluster-secrets.sops.yaml, when it exists, is
# the Secret cluster-secrets for flux-system, SOPS-encrypted, and holds exactly the keys
# cluster-secrets.example.yaml lists; without it, the example lists none. sops encrypts values only,
# so the keys are read without decrypting anything.
check_cluster_secrets() {
  local file example keys key name complete=1
  local -a listed=() held=()
  local -A in_example=() in_file=()
  file=$(cluster_secrets_file "$1")
  name=${file#"$infra_root"/}
  example=$infra_root/kubernetes/clusters/$1/cluster-secrets.example.yaml
  if [[ -f $file ]]; then
    if ! sops filestatus "$file" 2> /dev/null | jq -e '.encrypted == true' > /dev/null; then
      infra_error "$name is not SOPS-encrypted; encrypt it, or remove it without committing it"
      return 1
    fi
    if ! yq -e '.kind == "Secret" and .metadata.name == "cluster-secrets"
      and (.metadata.namespace // "flux-system") == "flux-system"' "$file" > /dev/null 2>&1; then
      infra_error "$name is not the Secret cluster-secrets for flux-system"
      return 1
    fi
    keys=$(read_keys "$file" '(.data // {}) * (.stringData // {}) | keys | .[]') || return 1
    mapfile -t held < <(printf '%s' "$keys")
  fi
  keys=$(read_keys "$example" 'keys | .[]') || return 1
  mapfile -t listed < <(printf '%s' "$keys")
  for key in "${held[@]}"; do
    in_file[$key]=1
  done
  for key in "${listed[@]}"; do
    in_example[$key]=1
    if [[ -z ${in_file[$key]-} ]]; then
      if [[ -f $file ]]; then
        infra_error "cannot fill $key of cluster-secrets: $name does not hold it"
      else
        infra_error "cannot fill $key of cluster-secrets: $name does not exist"
      fi
      complete=0
    fi
  done
  for key in "${held[@]}"; do
    if [[ -z ${in_example[$key]-} ]]; then
      infra_error "cluster-secrets would set $key, which ${example#"$infra_root"/} does not list"
      complete=0
    fi
  done
  ((complete))
}

# require_pre_flux CLUSTER TALMAN_FILE: every object Flux needs before it starts can be made, checked
# offline and before anything else runs, naming each problem: the Flux age key, cluster-config and
# cluster-secrets. Fills cluster_config.
require_pre_flux() {
  local complete=1
  require_flux_age_key || complete=0
  fill_cluster_config "$1" "$2" || complete=0
  check_cluster_secrets "$1" || complete=0
  ((complete))
}

# apply_in_flux_system: applies the object on standard input in flux-system, server-side, so a second
# run with the same object changes nothing and no copy of it is kept in an annotation.
apply_in_flux_system() {
  kubectl apply --server-side --namespace flux-system -f -
}

# require_install_tools: KUBECONFIG names the cluster's kubeconfig, and what installing an
# application runs is on PATH. The kubeconfig reaches kubectl and helm through the environment.
require_install_tools() {
  local kubeconfig tool
  local -a kubeconfigs=()
  if [[ -z ${KUBECONFIG:-} ]]; then
    infra_error "KUBECONFIG is not set: export the path of the cluster's kubeconfig"
    return 1
  fi
  IFS=: read -ra kubeconfigs <<< "$KUBECONFIG"
  for kubeconfig in "${kubeconfigs[@]}"; do
    if [[ -n $kubeconfig && ! -f $kubeconfig ]]; then
      infra_error "KUBECONFIG names $kubeconfig, which is not a file"
      return 1
    fi
  done
  for tool in yq helm kubectl; do
    if ! command -v "$tool" > /dev/null; then
      infra_error "$tool not found on PATH"
      return 1
    fi
  done
}

# substitute FILE: FILE as Flux's post-build substitution makes it, with the data of the ConfigMap
# in JSON on standard input as the only variables, strictly, so a variable with neither a value nor
# a default fails, named. flux envsubst is Flux's own substitution; the values reach it in its
# environment, which holds nothing else, and leave it on standard output.
substitute() {
  local file=$1 flux name value i
  local -a names=() values=()
  flux=$(command -v flux) || {
    infra_error "flux not found on PATH"
    return 1
  }
  # Flux takes only names a shell variable could have; any other would not be exported.
  while IFS= read -r -d '' name && IFS= read -r -d '' value; do
    names+=("$name")
    values+=("$value")
  done < <(jq -j '.data // {} | to_entries[] | select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$"))
    | .key, "\u0000", .value, "\u0000"')
  (
    while IFS= read -r name; do
      export -n "${name?}"
    done < <(compgen -e)
    for i in "${!names[@]}"; do
      export "${names[i]}=${values[i]}"
    done
    exec "$flux" envsubst --strict < "$file"
  )
}

# helmrelease_values FILE: the values the HelmRelease in FILE sets itself, which helm-controller
# merges over those of its valuesFrom, as YAML, {} when it sets none. Where it uses a variable they
# are what Flux makes of them: substituted from the ConfigMap cluster-config on the cluster, as the
# root gives every application, read with kubectl and handed on through pipes only.
helmrelease_values() {
  local file=$1 config
  # shellcheck disable=SC2016 # a literal ${, with which every Flux variable starts
  if ! grep -qF '${' "$file"; then
    yq '.spec.values // {}' "$file"
    return
  fi
  config=$(kubectl get configmap cluster-config --namespace flux-system --ignore-not-found --output json) || return 1
  if [[ -z $config ]]; then
    infra_error "flux-system holds no ConfigMap cluster-config, which ${file#"$infra_root"/} takes variables from; just cluster-config applies it"
    return 1
  fi
  printf '%s' "$config" | substitute "$file" | yq '.spec.values // {}'
}

# managed_by_flux RELEASE NAMESPACE [REVISION]: whether Flux's helm-controller installed or upgraded
# the release last, or, given REVISION, made that revision. Its post-renderer labels every object it
# renders with helm.toolkit.fluxcd.io/name and helm.toolkit.fluxcd.io/namespace, the HelmRelease's
# (helm-controller v1.7.1, which the pinned Flux runs: internal/postrender/build.go and
# common_renderer.go), and helm keeps the rendered objects in the manifest of each revision. Returns
# 1 when they lack the label, and 2 when helm has no manifest: without a release there is none, and
# nothing manages it. Nothing of the manifest is printed.
managed_by_flux() {
  local manifest
  local -a revision=()
  [[ -z ${3-} ]] || revision=(--revision "$3")
  manifest=$(helm get manifest "$1" --namespace "$2" "${revision[@]}" 2> /dev/null) || return 2
  yq ea -e '[select(.metadata.labels["helm.toolkit.fluxcd.io/name"] != null)] | length > 0' <<< "$manifest" > /dev/null 2>&1
}

# app_field FILE PATH: the value at PATH in FILE, which must be set.
app_field() {
  if ! yq -e "$2" "$1" 2> /dev/null; then
    infra_error "cannot read $2 from $1"
    return 1
  fi
}

# app_release DIR: the Helm release that the HelmRelease of the application in DIR, a directory of
# kubernetes/ with the application's ks.yaml beside its app/, makes, as helm-controller makes it
# (GetReleaseName, GetReleaseNamespace and GetStorageNamespace in its api/v2): the HelmRelease's
# releaseName, targetNamespace and storageNamespace where it sets them, and otherwise its name, after
# its targetNamespace and a dash when it has one, and its own namespace, which Flux takes from
# ks.yaml's targetNamespace. Prints, on one line, the release, the namespace it is installed into and
# keeps its history in, the HelmRelease's name and the HelmRelease's namespace. Fails, naming the
# file, when the release has no namespace or would keep its history in another one.
app_release() {
  local dir=$1 app name namespace release target storage
  if [[ ! -f $dir/ks.yaml || ! -f $dir/app/helmrelease.yaml ]]; then
    infra_error "$dir is not an application directory: it has no ks.yaml beside app/helmrelease.yaml"
    return 1
  fi
  app=$(cd "$dir/app" && pwd)
  name=$(app_field "$app/helmrelease.yaml" .metadata.name) || return 1
  namespace=$(yq '.spec.targetNamespace // ""' "$dir/ks.yaml")
  [[ -n $namespace ]] || namespace=$(yq '.metadata.namespace // ""' "$app/helmrelease.yaml")
  if [[ -z $namespace ]]; then
    infra_error "$dir/ks.yaml sets no targetNamespace, and app/helmrelease.yaml no namespace: the release has none"
    return 1
  fi
  release=$(yq '.spec.releaseName // ""' "$app/helmrelease.yaml")
  target=$(yq '.spec.targetNamespace // ""' "$app/helmrelease.yaml")
  storage=$(yq '.spec.storageNamespace // ""' "$app/helmrelease.yaml")
  [[ -n $release ]] || release=${target:+$target-}$name
  storage=${storage:-$namespace}
  # helm keeps a release's history in the namespace it installs into; Flux finds the release
  # installed there only if the HelmRelease looks for it there.
  if [[ $storage != "${target:-$namespace}" ]]; then
    infra_error "helmrelease.yaml installs into ${target:-$namespace} but keeps the history in $storage; helm uses one namespace for both"
    return 1
  fi
  printf '%s %s %s %s\n' "$release" "${target:-$namespace}" "$name" "$namespace"
}

# install_app DIR [YES]: installs the application in DIR, a directory of kubernetes/ with the
# application's ks.yaml beside its app/, on the cluster KUBECONFIG names, as the Helm release its
# HelmRelease adopts once Flux runs (app_release). The chart location and version come from
# app/ocirepository.yaml; the values from app/values.yaml as it is, then the HelmRelease's own values
# as Flux substitutes them (helmrelease_values), on helm's standard input. Waits for the API server
# first. A release that runs that chart version with those values already is left alone, so a second
# run changes nothing. A release Flux manages (managed_by_flux) is refused, as Flux owns it from then
# on, unless YES is 1.
install_app() {
  local dir=$1 yes=${2:-0} app fields namespace url version release values overrides wanted chart installed attempts
  step="reading the application"
  fields=$(app_release "$dir") || return 1
  read -r release namespace _ <<< "$fields"
  app=$(cd "$dir/app" && pwd)
  url=$(app_field "$app/ocirepository.yaml" .spec.url) || return 1
  version=$(app_field "$app/ocirepository.yaml" .spec.ref.tag) || return 1
  values=$app/values.yaml
  if ! yq -e 'tag == "!!map"' "$values" > /dev/null 2>&1; then
    infra_error "$values is not a YAML map of values"
    return 1
  fi
  # helm names an OCI chart after the last element of its location.
  chart=${url##*/}

  step="waiting for the API server"
  printf '%s: waiting for the API server\n' "${0##*/}"
  # Ten minutes, as the control plane may still be starting.
  attempts=0
  until kubectl get --raw /readyz --request-timeout=10s > /dev/null 2>&1; do
    attempts=$((attempts + 1))
    if ((attempts >= 120)); then
      infra_error "no answer on /readyz after $attempts attempts, 5 seconds apart"
      return 1
    fi
    sleep 5
  done

  step="reading the HelmRelease's values"
  overrides=$(helmrelease_values "$app/helmrelease.yaml") || return 1
  # helm merges its values files in order, as helm-controller merges the HelmRelease's own values
  # over those of its valuesFrom.
  # shellcheck disable=SC2016 # $file is a yq variable.
  wanted=$(printf '%s\n' "$overrides" |
    yq ea -o json -I0 '. as $file ireduce ({}; . * $file) | sort_keys(..)' "$values" -) || return 1

  step="checking the installed release"
  installed=$(helm list --namespace "$namespace" --filter "^$release\$" --deployed --output json |
    yq -p json '.[0].chart // ""') || return 1
  if [[ $installed == "$chart-$version" ]] &&
    [[ "$(helm get values "$release" --namespace "$namespace" --output json | yq -p json -o json -I0 'sort_keys(..)')" == "$wanted" ]]; then
    printf '%s: release %s already runs %s %s with these values; nothing to install\n' "${0##*/}" "$release" "$chart" "$version"
    return 0
  fi
  if ((!yes)) && managed_by_flux "$release" "$namespace"; then
    infra_error "release $release in $namespace is managed by Flux's helm-controller, whose label helm.toolkit.fluxcd.io/name its objects carry; installing over it changes what Flux manages, and Flux undoes it. --yes installs anyway"
    return 1
  fi

  step="installing the chart"
  printf '%s: installing %s %s from %s as release %s in %s\n' "${0##*/}" "$chart" "$version" "$url" "$release" "$namespace"
  # Helm's default of five minutes is short for a first install that pulls the images on every node.
  if [[ $overrides == '{}' ]]; then
    helm upgrade --install "$release" "$url" --version "$version" --namespace "$namespace" \
      --values "$values" --wait --timeout 15m || return 1
  else
    printf '%s\n' "$overrides" |
      helm upgrade --install "$release" "$url" --version "$version" --namespace "$namespace" \
        --values "$values" --values - --wait --timeout 15m || return 1
  fi
  printf '%s: %s %s runs as release %s in %s\n' "${0##*/}" "$chart" "$version" "$release" "$namespace"
}
