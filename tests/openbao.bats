#!/usr/bin/env bats
# Proves the scenarios of features/openbao.feature that read manifests; each test carries its
# scenario's title. tests/openbao-recipes.bats proves the recipes'.
# Needs helm, kustomize, flux, yq and jq on PATH (the versions pinned for the repository). The chart
# is pulled once per run from its public registry; building and rendering are offline. flux build
# rewrites the kustomization.yaml of what it builds while it runs, so every build reads a copy of
# kubernetes/, never this checkout.

# The tests run one at a time even where bats runs a file's tests side by side: a test that starts
# while another pulls the chart finds the chart's directory before the chart is in it.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

setup_file() {
  # Helm's cache and registry settings stay in the run's own directory, and so does the Docker
  # configuration helm falls back to for credentials, so no login is read.
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG" "$BATS_FILE_TMPDIR/tree"
  cp -R "$BATS_TEST_DIRNAME/../kubernetes" "$BATS_FILE_TMPDIR/tree/kubernetes"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TREE="$BATS_FILE_TMPDIR/tree"
  CLUSTER="$TREE/kubernetes/clusters/lab-sto2"
  KUBE="$(yq -e '.kubernetes' "$REPO/versions.yaml")"
  CONTROL_PLANE='node-role.kubernetes.io/control-plane'
  # bao_valid_path, the rule bao-put applies to a key-value path; sourcing it runs nothing.
  # shellcheck source=scripts/lib/openbao.sh
  . "$REPO/scripts/lib/openbao.sh"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# built NAMESPACE APP: the application as Flux applies it: its app/ built from the copy with its
# ks.yaml, substituting strictly the variables of the cluster's example key lists. Writes
# $BATS_TEST_TMPDIR/APP-built.yaml and sets BUILT.
built() {
  local ns=$1 app=$2 vars="$BATS_TEST_TMPDIR/example-vars.yaml" ks="$BATS_TEST_TMPDIR/$2-ks.yaml"
  # shellcheck disable=SC2016 # $list and $vars are yq variables.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$vars"
  # shellcheck disable=SC2016
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = $vars' "$vars" "$TREE/kubernetes/apps/base/$ns/$app/ks.yaml" >"$ks"
  BUILT="$BATS_TEST_TMPDIR/$app-built.yaml"
  # Built from the tree's parent, with paths from there, as scripts/kubernetes-check builds.
  (cd "$TREE" && flux build kustomization "$app" --path "./kubernetes/apps/base/$ns/$app/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute) >"$BUILT"
}

# render: the chart the openbao application's HelmRelease installs, rendered from the URL and tag of
# its OCIRepository with the values helm-controller gives it: those of the ConfigMap the HelmRelease
# reads, then the HelmRelease's own over them, and the chart's test pod with it. The monitoring APIs
# count as present. Writes $BATS_TEST_TMPDIR/rendered.yaml and the server configuration, and sets
# RENDERED, CONFIG, CHART, VALUES, INLINE and OPENBAO, the built application.
render() {
  local url tag name release namespace pulled
  built openbao openbao
  OPENBAO=$BUILT
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$OPENBAO")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$OPENBAO")"
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$OPENBAO")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$OPENBAO")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$OPENBAO")"
  VALUES="$BATS_TEST_TMPDIR/values.yaml"
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\") | .data[\"values.yaml\"]" "$OPENBAO" >"$VALUES"
  [ -s "$VALUES" ] || { echo "no values in the ConfigMap $name the HelmRelease reads"; return 1; }
  INLINE="$BATS_TEST_TMPDIR/inline.yaml"
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$OPENBAO" >"$INLINE"
  pulled="$BATS_FILE_TMPDIR/charts/openbao/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  RENDERED="$BATS_TEST_TMPDIR/rendered.yaml"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor \
    --api-versions monitoring.coreos.com/v1/PodMonitor --api-versions monitoring.coreos.com/v1/PrometheusRule \
    --values "$VALUES" --values "$INLINE" >"$RENDERED"
  CONFIG="$BATS_TEST_TMPDIR/server.hcl"
  yq -N 'select(.kind == "ConfigMap" and .metadata.name == "openbao-config") | .data["extraconfig-from-values.hcl"]' \
    "$RENDERED" >"$CONFIG"
  [ -s "$CONFIG" ] || { echo "the chart renders no server configuration"; return 1; }
}

# render_external_secrets: the External Secrets chart, rendered from its application as Flux applies
# it, with the repository's values. Sets ESO_RENDERED.
render_external_secrets() {
  local built url tag name values pulled
  built external-secrets external-secrets
  built=$BUILT
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$built")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$built")"
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$built")"
  values="$BATS_TEST_TMPDIR/eso-values.yaml"
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\") | .data[\"values.yaml\"]" "$built" >"$values"
  pulled="$BATS_FILE_TMPDIR/charts/external-secrets/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  ESO_RENDERED="$BATS_TEST_TMPDIR/eso-rendered.yaml"
  helm template external-secrets "$(echo "$pulled"/*.tgz)" --namespace external-secrets --kube-version "$KUBE" \
    --values "$values" >"$ESO_RENDERED"
}

# statefulset: the rendered StatefulSet, as JSON in $BATS_TEST_TMPDIR/statefulset.json; sets STS.
statefulset() {
  STS="$BATS_TEST_TMPDIR/statefulset.json"
  yq -N -o json 'select(.kind == "StatefulSet")' "$RENDERED" >"$STS"
  [ -s "$STS" ] || { echo "the chart renders no StatefulSet"; return 1; }
}

# block TYPE [LABEL]: the top-level block TYPE "LABEL" { ... } of the server configuration, its
# lines up to the closing brace at the start of a line.
block() {
  local start="^$1 "
  [ -z "${2-}" ] || start+="\"$2\" "
  awk -v start="$start" '$0 ~ start "\\{" {inside = 1} inside {print} inside && /^}/ {inside = 0}' "$CONFIG"
}

# setting NAME [TEXT]: the quoted or bare value of the first "NAME = value" line in TEXT, or in the
# server configuration.
setting() {
  local text=${2-}
  [ -n "$text" ] || text="$(cat "$CONFIG")"
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\\1/p" <<<"$text" | head -n 1
}

# mounted FILE [CONTAINER]: "KIND/NAME KEY" of the volume CONTAINER, openbao when not given, an init
# container or not, mounts at FILE's directory, the ConfigMap or Secret that holds FILE; nothing when
# no mount holds it.
mounted() {
  local dir=${1%/*} key=${1##*/}
  jq -r --arg dir "$dir" --arg key "$key" --arg container "${2:-openbao}" '.spec.template.spec as $pod
    | (($pod.initContainers // []) + $pod.containers | .[] | select(.name == $container)
      | .volumeMounts[] | select(.mountPath == $dir) | .name) as $volume
    | $pod.volumes[] | select(.name == $volume)
    | if .secret then "Secret/" + .secret.secretName + " " + $key
      elif .configMap then "ConfigMap/" + .configMap.name + " " + $key else empty end' "$STS"
}

# volume_at DIR CONTAINER: "NAME KIND READONLY" of the volume CONTAINER mounts at DIR: KIND is the
# volume's source, or claim for one of the StatefulSet's claim templates.
volume_at() {
  jq -r --arg dir "$1" --arg container "$2" '.spec as $set | .spec.template.spec as $pod
    | (($pod.initContainers // []) + $pod.containers | .[] | select(.name == $container)
      | .volumeMounts[] | select(.mountPath == $dir)) as $mount
    | ([$pod.volumes[] | select(.name == $mount.name) | del(.name) | keys[0]]
      + [$set.volumeClaimTemplates // [] | .[] | select(.metadata.name == $mount.name) | "claim"]) as $kinds
    | $mount.name + " " + ($kinds[0] // "none") + " " + ($mount.readOnly // false | tostring)' "$STS"
}

# initialize: OpenBao's initial configuration, the initialize stanzas the first member reads, from
# the built application's ConfigMap openbao-initialize. Writes INIT, the configuration, and
# REQUESTS, one JSON object per request, in order: its block, name, operation, path, data and
# token.
initialize() {
  INIT="$BATS_TEST_TMPDIR/initialize.json"
  yq -N 'select(.kind == "ConfigMap" and .metadata.name == "openbao-initialize") | .data["initialize.json"]' \
    "$OPENBAO" >"$INIT"
  [ -s "$INIT" ] || { echo "no initialize.json in the ConfigMap openbao-initialize"; return 1; }
  REQUESTS="$BATS_TEST_TMPDIR/requests.jsonl"
  jq -c '.initialize[] | to_entries[] | .key as $block | .value.request[] | to_entries[]
    | {block: $block, name: .key} + .value' "$INIT" >"$REQUESTS"
}

# request PATH: the data of the request to PATH in the initial configuration, as JSON.
request() {
  jq -c --arg path "$1" 'select(.path == $path) | .data // {}' "$REQUESTS"
}

# policy NAME: the ACL policy NAME the initial configuration writes, as JSON: its text inline or
# read from a file of the ConfigMap openbao-initialize, by the file source of OpenBao's profiles.
policy() {
  local data source key
  data="$(request "sys/policies/acl/$1")"
  [ -n "$data" ] || { echo "the initial configuration writes no policy $1" >&2; return 1; }
  if [ "$(jq -r '.policy | type' <<<"$data")" = string ]; then
    jq -r '.policy' <<<"$data"
    return
  fi
  [ "$(jq -r '.policy.eval_source' <<<"$data")" = file ] || { echo "policy $1 comes from no file" >&2; return 1; }
  source="$(jq -r '.policy.path' <<<"$data")"
  read -r _ key <<<"$(mounted "$source")"
  [ -n "${key-}" ] || { echo "no volume holds $source" >&2; return 1; }
  KEY="$key" yq -N 'select(.kind == "ConfigMap" and .metadata.name == "openbao-initialize") | .data[strenv(KEY)]' "$OPENBAO"
}

# covers NAME PATTERN...: whether one of the certificate names PATTERN, a DNS name that may start
# with a one-label wildcard or an address, is NAME.
covers() {
  local name=$1 pattern
  shift
  for pattern; do
    [ "$pattern" = "$name" ] && return 0
    if [[ $pattern == '*.'* && $name == *.* && ${name#*.} == "${pattern#\*.}" ]]; then return 0; fi
  done
  return 1
}

@test "OpenBao is enabled after what it needs, and the store and the demo after it" {
  local overlay enabled app depends wanted expr
  overlay="$(kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2")"
  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "openbao") | .metadata.name' <<<"$overlay")" = openbao ]
  enabled="$(yq -N 'select(.kind == "Kustomization") | .metadata.name + " " + .spec.path' <<<"$overlay")"
  echo "$enabled"
  grep -qx 'openbao ./apps/base/openbao/openbao/app' <<<"$enabled"
  grep -qx 'openbao-store ./apps/base/external-secrets/openbao-store/app' <<<"$enabled"
  grep -qx 'hello-secret ./apps/base/demo/hello-secret/app' <<<"$enabled"
  # Each builds as Flux applies it.
  built openbao openbao
  built external-secrets openbao-store
  built demo hello-secret

  for app in openbao openbao-store hello-secret; do
    depends="$(yq -N "select(.kind == \"Kustomization\" and .metadata.name == \"$app\") | .spec.dependsOn // [] | .[].name" <<<"$overlay" | sort | paste -sd' ' -)"
    echo "$app depends on: ${depends:-nothing}"
    case $app in
      openbao) wanted='cert-manager external-secrets linstor-cluster prometheus-operator-crds' ;;
      openbao-store) wanted='external-secrets openbao' ;;
      hello-secret) wanted='openbao-store' ;;
    esac
    for name in $wanted; do
      [[ " $depends " == *" $name "* ]] || { echo "$app does not wait for $name"; return 1; }
    done
  done
  # OpenBao and the store are Ready only once what they apply is: the release, and the store once
  # it reports Ready, which kstatus does not read from a ClusterSecretStore by itself.
  for app in openbao openbao-store; do
    [ "$(yq -N "select(.kind == \"Kustomization\" and .metadata.name == \"$app\") | .spec.wait" <<<"$overlay")" = true ] ||
      { echo "$app does not wait"; return 1; }
  done
  expr="$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "openbao-store") | .spec.healthCheckExprs // [] | .[]
    | select(.apiVersion == "external-secrets.io/v1" and .kind == "ClusterSecretStore") | .current' <<<"$overlay")"
  echo "store health: ${expr:-none}"
  [[ $expr == *"'Ready'"*"'True'"* ]]
}

@test "OpenBao runs three raft members, one per worker, with a budget that keeps quorum" {
  local replicas labels anti node joins wanted budget claims
  render
  statefulset
  replicas="$(jq -r '.spec.replicas' "$STS")"
  echo "replicas: $replicas"
  [ "$replicas" -eq 3 ]
  # Raft storage, which every member joins through every other.
  block storage raft | grep -q '^storage "raft" {'
  joins="$(block storage raft | sed -nE 's/^[[:space:]]*leader_api_addr[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' | sort | paste -sd' ' -)"
  wanted="$(for i in 0 1 2; do echo "https://openbao-$i.openbao-internal:8200"; done | paste -sd' ' -)"
  echo "retry_join: $joins"
  [ "$joins" = "$wanted" ]
  # No two members on one node: a required anti-affinity over the members' own labels.
  labels="$(jq -c '.spec.template.metadata.labels' "$STS")"
  anti="$(jq -r --argjson labels "$labels" '.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution // []
    | .[] | select(.topologyKey == "kubernetes.io/hostname"
      and (.labelSelector.matchLabels // {} | length) > 0
      and (.labelSelector.matchLabels | to_entries | all(.value == $labels[.key]))) | .topologyKey' "$STS")"
  echo "anti-affinity: ${anti:-none}"
  [ -n "$anti" ]
  # None on a control plane: only nodes without the role label Talos gives every control plane.
  node="$(jq -r --arg key "$CONTROL_PLANE" '.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms // []
    | map(.matchExpressions // [] | any(.key == $key and .operator == "DoesNotExist")) | if length > 0 and all then "workers" else "any node" end' "$STS")"
  echo "nodes: $node"
  [ "$node" = workers ]
  # One of three may be unavailable, which leaves two, a majority.
  # shellcheck disable=SC2016 # $labels is a yq variable.
  budget="$(LABELS="$labels" yq -N '(strenv(LABELS) | from_json) as $labels | select(.kind == "PodDisruptionBudget"
    and (.spec.selector.matchLabels | to_entries | all_c(.value == $labels[.key])))
    | (.spec.maxUnavailable // "none" | tostring) + " " + (.spec.minAvailable // "none" | tostring)' "$RENDERED")"
  echo "budget maxUnavailable minAvailable: ${budget:-none}"
  [ "$budget" = "1 none" ]
  # One data claim per member, of the default StorageClass, which it does not name, with a size.
  claims="$(jq -r '.spec.volumeClaimTemplates[] | .metadata.name + " class=" + (.spec.storageClassName // "default")
    + " size=" + (.spec.resources.requests.storage // "none")' "$STS")"
  echo "claims: $claims"
  [ "$(grep -c . <<<"$claims")" -eq 1 ]
  [[ $claims =~ ^data\ class=default\ size=[0-9]+[GM]i$ ]]
}

@test "OpenBao keeps quorum through a node drain by its settings" {
  local max probe retention strategy policy members autopilot seal
  render
  statefulset
  initialize
  # A drain evicts one member at a time: the budget lets one of three go.
  max="$(yq -N 'select(.kind == "PodDisruptionBudget") | .spec.maxUnavailable' "$RENDERED")"
  echo "maxUnavailable: $max"
  [ "$max" = 1 ]
  # A member counts as available only while it is unsealed: bao status exits 0 only then.
  probe="$(jq -r '.spec.template.spec.containers[] | select(.name == "openbao") | .readinessProbe.exec.command // [] | join(" ")' "$STS")"
  echo "readiness: $probe"
  [[ $probe == *'bao status'* ]]
  # Its claim outlives the pod, and every member's address is in retry_join, so an evicted member
  # comes back with its data and joins whichever member leads.
  retention="$(jq -r '.spec.persistentVolumeClaimRetentionPolicy.whenDeleted // "Retain"' "$STS")"
  echo "claim retention: $retention"
  [ "$retention" = Retain ]
  members="$(block storage raft | grep -c 'leader_api_addr')"
  [ "$members" -eq "$(jq -r '.spec.replicas' "$STS")" ]
  # It unseals itself: an auto-unseal seal, never Shamir's.
  seal="$(block seal static | head -n 1)"
  echo "seal: ${seal:-none}"
  [ "$seal" = 'seal "static" {' ]
  # Autopilot never removes a member for being away.
  autopilot="$(request sys/storage/raft/autopilot/configuration)"
  echo "autopilot: ${autopilot:-not configured}"
  [ "$(jq -r '.cleanup_dead_servers' <<<"$autopilot")" = false ]
  # A new release replaces one member at a time, each once the one before is Ready.
  strategy="$(jq -r '.spec.updateStrategy.type' "$STS")"
  policy="$(jq -r '.spec.podManagementPolicy' "$STS")"
  echo "update strategy: $strategy; pod management: $policy"
  [ "$strategy" = RollingUpdate ]
  [ "$policy" = OrderedReady ]
}

@test "The seal key comes from a Secret that nothing in the repository holds and nothing regenerates" {
  local seal key id previous file secret test_mounts external generator length encoding found read path
  render
  statefulset
  seal="$(block seal static)"
  echo "$seal"
  key="$(setting current_key "$seal")"
  id="$(setting current_key_id "$seal")"
  echo "current_key: $key; current_key_id: $id"
  [ -n "$id" ]
  # Read from a file, never written into the configuration; so is the previous key while one is
  # rotated out.
  [[ $key == file:///* ]]
  previous="$(setting previous_key "$seal")"
  [ -z "$previous" ] || [[ $previous == file:///* ]]
  file="${key#file://}"
  read -r secret _ <<<"$(mounted "$file")"
  echo "$file is in: ${secret:-no volume}"
  [[ $secret == Secret/* ]]
  secret="${secret#Secret/}"
  # Only the servers mount it, not the chart's test pod.
  test_mounts="$(yq -N 'select(.kind == "Pod") | .spec.volumes // [] | .[] | select(.secret != null) | .secret.secretName' "$RENDERED")"
  echo "test pod mounts: ${test_mounts:-nothing}"
  [ "$(grep -c -x "$secret" <<<"$test_mounts")" -eq 0 ]

  # An ExternalSecret makes it from a generator once: never refreshed, never owned, so deleting
  # the ExternalSecret leaves it, and immutable, so nothing changes its key.
  external="$(SECRET="$secret" yq -N -o json -I0 'select(.kind == "ExternalSecret" and .spec.target.name == strenv(SECRET))' "$OPENBAO")"
  echo "ExternalSecret: ${external:-none}"
  [ -n "$external" ]
  [ "$(jq -r '.spec.refreshPolicy' <<<"$external")" = CreatedOnce ]
  [ "$(jq -r '.spec.target.creationPolicy' <<<"$external")" = Orphan ]
  [ "$(jq -r '.spec.target.immutable' <<<"$external")" = true ]
  [ "$(jq -r '.spec.target.deletionPolicy // "Retain"' <<<"$external")" = Retain ]
  [ "$(jq -r '.spec.data // [] | length' <<<"$external")" -eq 0 ]
  generator="$(jq -r '.spec.dataFrom[0].sourceRef.generatorRef | .kind + "/" + .name' <<<"$external")"
  echo "generator: $generator"
  [[ $generator == Password/* ]]
  # 32 characters, hex-encoded: the 64 hexadecimal digits the static seal reads as its 32-byte key.
  length="$(NAME="${generator#Password/}" yq -N 'select(.kind == "Password" and .metadata.name == strenv(NAME)) | .spec.length' "$OPENBAO")"
  encoding="$(NAME="${generator#Password/}" yq -N 'select(.kind == "Password" and .metadata.name == strenv(NAME)) | .spec.encoding' "$OPENBAO")"
  echo "password: length $length, encoding $encoding"
  [ "$length" = 32 ]
  [ "$encoding" = hex ]
  [ "$(NAME="${generator#Password/}" yq -N 'select(.kind == "Password" and .metadata.name == strenv(NAME)) | .spec.secretKeys | join(",")' "$OPENBAO")" = "${file##*/}" ]
  # Its characters: upper and lower case letters, digits and symbols in the generator's own default
  # shares (a quarter digits, a quarter symbols) from its own symbol set, repeats allowed, which gives
  # 32 characters about 190 bits.
  [ "$(NAME="${generator#Password/}" yq ea -N -o json -I0 '[select(.kind == "Password" and .metadata.name == strenv(NAME))] | .[0].spec
    | [.allowRepeat, .noUpper, .digits // "default", .symbols // "default", .symbolCharacters // "default"]' "$OPENBAO")" = \
    '[true,false,"default","default","default"]' ]

  # Nothing git would commit holds a Secret of that name, encrypted or not. Each file is read on
  # its own, so one that yq cannot read does not hide the others.
  found="" read=0
  while IFS= read -r -d '' path; do
    read=$((read + 1))
    if SECRET="$secret" yq ea -e 'select(.kind == "Secret" and .metadata.name == strenv(SECRET))' "$REPO/$path" >/dev/null 2>&1; then
      found+=" $path"
    fi
  done < <(cd "$REPO" && git ls-files -z --cached --others --exclude-standard -- '*.yaml' '*.yml' '*.json')
  echo "files read: $read; Secrets named $secret:${found:- none}"
  [ "$read" -gt 0 ]
  [ -z "$found" ]
}

@test "No root token and no recovery material is stored by anything the build renders" {
  local kinds paths tokens sources level roles sudo grants audit
  render
  statefulset
  initialize
  # No Secret, Job or CronJob in what Flux applies or what the chart renders.
  kinds="$(yq -N 'select(. != null) | select(.kind == "Secret" or .kind == "Job" or .kind == "CronJob") | .kind + "/" + .metadata.name' "$OPENBAO" "$RENDERED")"
  echo "Secrets and jobs: ${kinds:-none}"
  [ -z "$kinds" ]
  # The initial configuration runs with the root token OpenBao makes and revokes itself: no
  # request names a token, reads one from a response, generates recovery keys or a root token, or
  # makes a token another way.
  tokens="$(jq -r 'select(has("token")) | .name' "$REQUESTS")"
  echo "requests with their own token: ${tokens:-none}"
  [ -z "$tokens" ]
  sources="$(jq -r '[.. | objects | select(has("eval_source")) | .eval_source] | .[]' "$REQUESTS" | sort -u | paste -sd' ' -)"
  echo "data sources: ${sources:-none}"
  [[ " $sources " != *' response '* && " $sources " != *' request '* && " $sources " != *' env '* ]]
  paths="$(jq -r '.path' "$REQUESTS")"
  echo "requests: $(paste -sd' ' - <<<"$paths")"
  [ "$(grep -c -E '^/?sys/(init|generate-root|generate-recovery-token|rekey|rekey-recovery-key|rotate/(root|recovery))(/|$)|^/?auth/token/create' <<<"$paths")" -eq 0 ]
  # No role or policy is root's.
  roles="$(jq -r 'select(.path | test("^auth/[^/]+/role/")) | .data.token_policies // [] | .[]' "$REQUESTS")"
  echo "role policies: $(paste -sd' ' - <<<"$roles")"
  [ -n "$roles" ]
  [ "$(grep -c -x root <<<"$roles")" -eq 0 ]
  sudo="$(for name in $(jq -r 'select(.path | startswith("sys/policies/acl/")) | .path | sub("^sys/policies/acl/"; "")' "$REQUESTS"); do
    policy "$name" | jq -r --arg name "$name" '.path | to_entries[] | select(.value.capabilities | index("sudo")) | $name + ": " + .key'
  done)"
  echo "sudo grants: ${sudo:-none}"
  [ -z "$sudo" ]
  # A root token comes back only through OpenBao's authenticated root token generation, which takes
  # a threshold of the recovery keys, and only the operator role may start it; no policy makes a
  # token another way.
  grants="$(for name in $(jq -r 'select(.path | startswith("sys/policies/acl/")) | .path | sub("^sys/policies/acl/"; "")' "$REQUESTS"); do
    policy "$name" | jq -r --arg name "$name" '.path | to_entries[]
      | select(.key | test("^(sys/generate-root|sys/generate-recovery-token|sys/rotate/root|auth/token/create)"))
      | $name + " " + .key + " " + (.value.capabilities | join(","))'
  done | sort)"
  echo "root token grants: ${grants:-none}"
  [ "$grants" = "$(printf '%s\n' 'operator sys/generate-root-token/attempt read,update,delete' \
    'operator sys/generate-root-token/update update')" ]
  [ "$(jq -r 'select(.path | test("^auth/[^/]+/role/")) | select(.data.token_policies | index("operator")) | .path' "$REQUESTS")" = \
    auth/kubernetes/role/operator ]
  # Self-initialisation logs its requests and responses, the root token among them, at trace level,
  # and debug logging goes further than the default too: no level is set below info anywhere a
  # server reads one, its configuration, its arguments or its environment.
  level="$( {
    setting log_level
    jq -r '.spec.template.spec.containers[] | select(.name == "openbao")
      | (.env[] | select(.name | test("^(BAO|VAULT)_LOG_LEVEL$")) | .value), (.args[] | scan("-log-level[= ]+[A-Za-z]+"))' "$STS"
  } | paste -sd' ' -)"
  echo "log levels set: ${level:-none}"
  [[ ! ${level,,} =~ (trace|debug) ]]
  # Every audit device hashes what it writes: none sets log_raw or turns off hmac_accessor.
  audit="$(awk '/^audit /,/^}/' "$CONFIG")"
  echo "audit devices: ${audit:-none}"
  [ -n "$audit" ]
  [ "$(grep -cE '^[[:space:]]*(log_raw|hmac_accessor|elide_list_responses)[[:space:]]*=' <<<"$audit")" -eq 0 ]
  [ -z "$(jq -r 'select(.path | test("^/?sys/(audit|config/auditing)")) | .path' "$REQUESTS")" ]
}

@test "OpenBao runs without its injector, its CSI provider or an exposed UI" {
  local objects services ui
  render
  objects="$(yq -N 'select(. != null) | .kind + "/" + .metadata.name' "$RENDERED")"
  echo "$objects"
  [ "$(grep -c -E '^(Deployment|DaemonSet|MutatingWebhookConfiguration|ValidatingWebhookConfiguration|Ingress|HTTPRoute|TLSRoute|Route)/' <<<"$objects")" -eq 0 ]
  [ "$(grep -c -E -- '-(agent-injector|csi-provider|ui)' <<<"$objects")" -eq 0 ]
  services="$(yq -N 'select(.kind == "Service") | .metadata.name + " " + (.spec.type // "ClusterIP")' "$RENDERED")"
  echo "$services"
  [ -n "$services" ]
  [ "$(grep -vc ' ClusterIP$' <<<"$services")" -eq 0 ]
  ui="$(setting ui)"
  echo "ui: ${ui:-unset}"
  [ "$ui" = false ]
}

@test "OpenBao serves TLS from a CA of its own, which the store and the monitor verify" {
  local cert ca_issuer ca_secret selfsigned name hosts cafile tls store monitor test_addr listener
  local -a patterns
  render
  statefulset
  # The chain: a self-signed Issuer signs the CA, a CA Issuer with the CA's Secret signs the
  # listener's certificate; all in the openbao namespace.
  selfsigned="$(yq -N 'select(.kind == "Issuer" and .spec.selfSigned != null) | .metadata.name' "$OPENBAO")"
  ca_secret="$(SS="$selfsigned" yq -N 'select(.kind == "Certificate" and .spec.isCA == true and .spec.issuerRef.name == strenv(SS) and .spec.issuerRef.kind == "Issuer") | .spec.secretName' "$OPENBAO")"
  ca_issuer="$(CA="$ca_secret" yq -N 'select(.kind == "Issuer" and .spec.ca.secretName == strenv(CA)) | .metadata.name' "$OPENBAO")"
  echo "self-signed issuer: ${selfsigned:-none}; CA Secret: ${ca_secret:-none}; CA issuer: ${ca_issuer:-none}"
  [ -n "$selfsigned" ]
  [ -n "$ca_secret" ]
  [ -n "$ca_issuer" ]
  [ "$(yq -N 'select(.kind == "Issuer" or .kind == "Certificate") | .metadata.namespace' "$OPENBAO" | sort -u)" = openbao ]
  cert="$(CA="$ca_issuer" yq -N -o json -I0 'select(.kind == "Certificate" and .spec.issuerRef.kind == "Issuer" and .spec.issuerRef.name == strenv(CA))' "$OPENBAO")"
  [ -n "$cert" ]
  tls="$(jq -r '.spec.secretName' <<<"$cert")"
  # The listener serves that certificate, reloads it when cert-manager renews it, and keeps TLS on.
  listener="$(block listener tcp)"
  echo "$listener"
  [ "$(mounted "$(setting tls_cert_file "$listener")")" = "Secret/$tls tls.crt" ]
  [ "$(mounted "$(setting tls_key_file "$listener")")" = "Secret/$tls tls.key" ]
  [ "$(setting tls_auto_reload "$listener")" = true ]
  [ -z "$(setting tls_disable "$listener")" ] || [ "$(setting tls_disable "$listener")" = false ]
  # Every name a client reaches it by is on the certificate: the store's server, every member as
  # retry_join reaches it, the address the servers' own CLI and probes use, the chart's test pod's
  # and the monitor's server name.
  mapfile -t patterns < <(jq -r '(.spec.dnsNames // []) + (.spec.ipAddresses // []) | .[]' <<<"$cert")
  built external-secrets openbao-store
  store="$(yq -N -o json -I0 'select(.kind == "ClusterSecretStore") | .spec.provider.vault' "$BUILT")"
  monitor="$(yq -N -o json -I0 'select(.kind == "ServiceMonitor") | .spec.endpoints[0].tlsConfig' "$RENDERED")"
  test_addr="$(yq -N 'select(.kind == "Pod") | .spec.containers[0].env[] | select(.name == "VAULT_ADDR" or .name == "BAO_ADDR") | .value' "$RENDERED")"
  hosts="$( {
    jq -r '.server' <<<"$store"
    block storage raft | sed -nE 's/^[[:space:]]*leader_api_addr[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p'
    jq -r '.spec.template.spec.containers[] | select(.name == "openbao") | .env[] | select(.name == "BAO_ADDR") | .value' "$STS"
    echo "$test_addr"
  } | sed -E 's#^https://##; s#[:/].*$##')"
  hosts+=$'\n'"$(jq -r '.serverName' <<<"$monitor")"
  echo "names: $(paste -sd' ' - <<<"$hosts"); certificate: ${patterns[*]}"
  while read -r name; do
    covers "$name" "${patterns[@]}" || { echo "the certificate does not cover $name"; return 1; }
  done <<<"$hosts"
  # Each client checks it against the CA: the store through its CA provider, the members and their
  # CLI through the CA file, the monitor through the CA's Secret, none skipping verification.
  [ "$(jq -r '.caProvider | .type + "/" + .namespace + "/" + .name + " " + .key' <<<"$store")" = "Secret/openbao/$ca_secret ca.crt" ]
  [[ $(jq -r '.server' <<<"$store") == https://* ]]
  cafile="$(jq -r '.spec.template.spec.containers[] | select(.name == "openbao") | .env[] | select(.name == "BAO_CACERT") | .value' "$STS")"
  [ "$(mounted "$cafile")" = "Secret/$tls ca.crt" ]
  [ "$(block storage raft | sed -nE 's/^[[:space:]]*leader_ca_cert_file[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' | sort -u)" = "$cafile" ]
  [ "$(jq -r '.ca.secret.name + " " + .ca.secret.key' <<<"$monitor")" = "$ca_secret ca.crt" ]
  [ "$(jq -r '.insecureSkipVerify // false' <<<"$monitor")" = false ]
}

@test "OpenBao is scraped through the chart's ServiceMonitor" {
  local monitors endpoint service port listener depends
  render
  monitors="$(yq -N 'select(.kind == "ServiceMonitor" or .kind == "PodMonitor") | .kind + "/" + .metadata.name' "$RENDERED")"
  echo "monitors: ${monitors:-none}"
  [ "$(grep -c . <<<"$monitors")" -eq 1 ]
  [[ $monitors == ServiceMonitor/* ]]
  # It scrapes the active member's Service, by a port that Service names, without a credential.
  endpoint="$(yq -N -o json -I0 'select(.kind == "ServiceMonitor") | .spec.endpoints[0]' "$RENDERED")"
  echo "endpoint: $endpoint"
  # shellcheck disable=SC2016 # $selector and $labels are yq variables.
  service="$(SELECTOR="$(yq -N -o json -I0 'select(.kind == "ServiceMonitor") | .spec.selector.matchLabels' "$RENDERED")" \
    yq -N '(strenv(SELECTOR) | from_json) as $selector | select(.kind == "Service")
      | select((.metadata.labels // {}) as $labels | $selector | to_entries | all_c($labels[.key] == .value))
      | .metadata.name' "$RENDERED")"
  echo "selects: ${service:-nothing}"
  [ "$service" = openbao-active ]
  port="$(jq -r '.port' <<<"$endpoint")"
  [ -n "$(PORT="$port" yq -N 'select(.kind == "Service" and .metadata.name == "openbao-active") | .spec.ports[] | select(.name == strenv(PORT)) | .name' "$RENDERED")" ]
  [ "$(jq -r '.path' <<<"$endpoint")" = /v1/sys/metrics ]
  [ "$(jq -r '.authorization // .bearerTokenFile // .basicAuth // "none"' <<<"$endpoint")" = none ]
  # The listener serves the metrics path without a token.
  listener="$(block listener tcp)"
  [ "$(setting unauthenticated_metrics_access "$listener")" = true ]
  [ -n "$(block telemetry)" ]
  depends="$(yq '.spec.dependsOn // [] | .[].name' "$TREE/kubernetes/apps/base/openbao/openbao/ks.yaml")"
  grep -qx prometheus-operator-crds <<<"$depends"
}

@test "The ClusterSecretStore reads one key-value mount and nothing else" {
  local store mount sa ns audiences role data policies policy name kv auth others
  built external-secrets openbao-store
  store="$(yq -N -o json -I0 'select(.kind == "ClusterSecretStore") | .spec.provider.vault' "$BUILT")"
  echo "store: $store"
  mount="$(jq -r '.path' <<<"$store")"
  [ "$(jq -r '.version' <<<"$store")" = v2 ]
  sa="$(jq -r '.auth.kubernetes.serviceAccountRef.name' <<<"$store")"
  ns="$(jq -r '.auth.kubernetes.serviceAccountRef.namespace' <<<"$store")"
  audiences="$(jq -r '.auth.kubernetes.serviceAccountRef.audiences // [] | join(",")' <<<"$store")"
  role="$(jq -r '.auth.kubernetes.role' <<<"$store")"
  # A service account of its own, which the application makes, not the operator's.
  [ "$(SA="$sa" yq -N 'select(.kind == "ServiceAccount" and .metadata.name == strenv(SA)) | .metadata.namespace' "$BUILT")" = "$ns" ]
  [ "$sa" != external-secrets ]
  [ "$audiences" = openbao ]

  render
  statefulset
  initialize
  auth="$(request "sys/auth/$(jq -r '.auth.kubernetes.mountPath' <<<"$store")")"
  [ "$(jq -r '.type' <<<"$auth")" = kubernetes ]
  kv="$(request "sys/mounts/$mount")"
  echo "mount $mount: $kv"
  [ "$(jq -r '.type + " " + (.options.version // "1")' <<<"$kv")" = "kv 2" ]
  data="$(request "auth/kubernetes/role/$role")"
  echo "role $role: $data"
  [ "$(jq -r '.bound_service_account_names | join(",")' <<<"$data")" = "$sa" ]
  [ "$(jq -r '.bound_service_account_namespaces | join(",")' <<<"$data")" = "$ns" ]
  [ "$(jq -r '.audience' <<<"$data")" = "$audiences" ]
  policies="$(jq -r '.token_policies | join(" ")' <<<"$data")"
  [ "$(wc -w <<<"$policies")" -eq 1 ]
  # Without OpenBao's default policy, the role's policy is all its token may do.
  [ "$(jq -r '.token_no_default_policy' <<<"$data")" = true ]
  policy="$(policy "$policies")"
  echo "policy $policies: $policy"
  # Every path the policy names is in the mount, and every capability reads; beyond the mount only
  # the two requests External Secrets' Vault provider makes about its own token, looking it up before
  # reusing it and revoking it (providers/v1/vault/auth.go in External Secrets v2.15.0).
  others="$(jq -r --arg mount "$mount/" '.path | to_entries[]
    | select(.key != "auth/token/lookup-self" and .key != "auth/token/revoke-self")
    | select((.key | startswith($mount) | not) or (.value.capabilities - ["read", "list"] | length) > 0) | .key' <<<"$policy")"
  echo "beyond reading $mount: ${others:-nothing}"
  [ -z "$others" ]
  [ "$(jq -cS '.path["auth/token/lookup-self"], .path["auth/token/revoke-self"]' <<<"$policy" | paste -sd' ' -)" = \
    '{"capabilities":["read"]} {"capabilities":["update"]}' ]
  [ "$(jq -r --arg path "$mount/data/*" '.path[$path].capabilities | index("read") != null' <<<"$policy")" = true ]
  # Nothing widens that: no request writes OpenBao's default or root policy, and no other role takes
  # the store's account.
  [ -z "$(jq -r 'select(.path | test("^/?sys/(policies/acl|policy)/(default|root)$")) | .path' "$REQUESTS")" ]
  [ "$(jq -r --arg sa "$sa" 'select(.path | test("^auth/[^/]+/role/")) | select(.data.bound_service_account_names // [] | index($sa)) | .path' "$REQUESTS")" = \
    "auth/kubernetes/role/$role" ]
  # The store has no other way to log in.
  [ "$(jq -r '.auth | keys | join(",")' <<<"$store")" = kubernetes ]
}

@test "Each OpenBao role binds one account to one policy, without OpenBao's default policy" {
  local roles policies accounts
  render
  statefulset
  initialize
  built openbao openbao
  # Role, account, audience, policies, default policy, token lifetime.
  roles="$(jq -r 'select(.path | test("^auth/kubernetes/role/")) | (.path | sub("^auth/kubernetes/role/"; "")) + " "
    + (.data.bound_service_account_namespaces | join(",")) + "/" + (.data.bound_service_account_names | join(","))
    + " " + .data.audience + " " + (.data.token_policies | join(",")) + " default=" + ((.data.token_no_default_policy // false) | not | tostring)
    + " ttl=" + .data.token_ttl + "/" + .data.token_max_ttl' "$REQUESTS" | sort)"
  echo "$roles"
  [ "$roles" = "$(printf '%s\n' 'external-secrets external-secrets/openbao-store openbao external-secrets default=false ttl=10m/1h' \
    'operator openbao/openbao-operator openbao operator default=false ttl=10m/10m' \
    'snapshot openbao/openbao-snapshot openbao snapshot default=false ttl=10m/10m')" ]
  # The snapshot role's policy takes a snapshot of the raft storage and nothing else.
  [ "$(policy snapshot | jq -cS '.path')" = '{"sys/storage/raft/snapshot":{"capabilities":["read"]}}' ]
  # The accounts in openbao are the application's own, and no pod mounts their tokens.
  accounts="$(yq -N 'select(.kind == "ServiceAccount") | .metadata.namespace + "/" + .metadata.name + " " + (.automountServiceAccountToken | tostring)' "$BUILT" | sort)"
  echo "accounts: $accounts"
  [ "$accounts" = "$(printf '%s\n' 'openbao/openbao-operator false' 'openbao/openbao-snapshot false')" ]
  # Every policy the roles name is written, and nothing else is.
  policies="$(jq -r 'select(.path | startswith("sys/policies/acl/")) | .path | sub("^sys/policies/acl/"; "")' "$REQUESTS" | sort | paste -sd' ' -)"
  [ "$policies" = "external-secrets operator snapshot" ]
}

@test "The operator role allows every request its recipes and runbook make, and nothing more" {
  local wanted granted others
  local scripts=(scripts/bao-put scripts/bao-recovery scripts/bao-root scripts/bao-seal-restore scripts/bao-seed-volsync
    scripts/bao-volsync-password scripts/lib/openbao.sh)
  render
  statefulset
  initialize
  # A request sent with another token than the operator's names it before bao_request. The only such
  # are bao-root's with the root token, which looks the root token up for its accessor and mints the
  # command's token; the operator may do neither.
  # shellcheck disable=SC2016 # the dollars are the scripts' variable names.
  others="$( (cd "$REPO" && grep -hoE '[a-z_]+=[^ ]+ bao_request (GET|POST|PUT|PATCH|DELETE) "?[^ ;]+' "${scripts[@]}") || true)"
  echo "with another token: ${others:-none}"
  # shellcheck disable=SC2016
  [ "$others" = "$(printf '%s\n' 'bao_token=$root_token bao_request GET auth/token/lookup-self' \
    'bao_token=$root_token bao_request POST auth/token/create-orphan')" ]
  # The requests the recipes send with the operator's token, read from the scripts themselves: the
  # scripts name the mount as $bao_mount, and bao-put's path as $path and the volume backups' key as
  # $volsync_key.
  # shellcheck disable=SC2016
  wanted="$( (cd "$REPO" && grep -hE 'bao_request (GET|POST|PUT|PATCH|DELETE) ' "${scripts[@]}") |
    grep -vE '[a-z_]+=[^ ]+ bao_request ' | grep -oE 'bao_request (GET|POST|PUT|PATCH|DELETE) "?[^ ]+' |
    sed -E 's/^bao_request //; s/["]//g; s/[)]+$//; s#\$bao_mount#secrets#; s#\$path#demo/hello#; s#\$volsync_key#volsync#' |
    grep -vE ' (auth/kubernetes/login|sys/seal-status|sys/decode-token)$')"
  # And those the runbook's CLI steps send, as OpenBao v2.7.2's api/sys_rotate.go and
  # api/sys_generate_root.go make them: rotating the recovery keys with verification, and making a
  # root token from them.
  wanted+=$'\n'"$(printf '%s\n' 'GET sys/rotate/recovery/init' 'POST sys/rotate/recovery/init' 'PUT sys/rotate/recovery/update' \
    'GET sys/rotate/recovery/verify' 'PUT sys/rotate/recovery/verify' 'DELETE sys/rotate/recovery/verify' \
    'DELETE sys/rotate/recovery/init' 'GET sys/generate-root-token/attempt' 'PUT sys/generate-root-token/attempt' \
    'PUT sys/generate-root-token/update' 'DELETE sys/generate-root-token/attempt' 'POST auth/token/revoke-self')"
  wanted="$(sort -u <<<"$wanted")"
  echo "requests: $(paste -sd';' - <<<"$wanted")"
  # Each as the capability OpenBao checks: GET read, POST and PUT update, or create for a write to a
  # key-value path that does not exist yet, PATCH patch, DELETE delete.
  granted="$(while read -r method path; do
    case $method in
      GET) echo "$path read" ;;
      PATCH) echo "$path patch" ;;
      DELETE) echo "$path delete" ;;
      *) if [[ $path == secrets/data/* ]]; then echo "$path create"; else echo "$path update"; fi ;;
    esac
  done <<<"$wanted" | sort -u)"
  # The policy allows each, and grants nothing none of them needs.
  # shellcheck disable=SC2016 # $grant is a jq variable.
  [ "$(policy operator | jq -r '.path | to_entries[] | .key as $path | .value.capabilities[] | $path + " " + .' | sort)" = \
    "$(sed -E 's#^secrets/data/(demo/hello|volsync) #secrets/data/* #' <<<"$granted" | sort -u)" ]
}

@test "External Secrets mints tokens for the store's account and no other" {
  local chart controller ref sa ns grants
  render_external_secrets
  # Nothing the chart renders lets any subject create a service account's token. jq, not yq, as yq
  # reads a * in a compared string as a wildcard.
  # shellcheck disable=SC2016 # $role is a jq variable.
  chart="$(yq -N -o json -I0 'select(.kind == "ClusterRole" or .kind == "Role")' "$ESO_RENDERED" | jq -r '. as $role
    | .rules // [] | .[] | select((.resources // []) - ["serviceaccounts/token", "serviceaccounts/*", "*"] != (.resources // []))
    | select((.verbs // []) - ["create", "*"] != (.verbs // [])) | $role.kind + "/" + $role.metadata.name')"
  echo "token grants in the chart: ${chart:-none}"
  [ -z "$chart" ]
  controller="$(yq -N 'select(.kind == "Deployment" and .metadata.name == "external-secrets") | .spec.template.spec.serviceAccountName' "$ESO_RENDERED")"
  [ -n "$controller" ]
  # The store's application lets the controller create tokens for the store's account alone, in the
  # namespace External Secrets requests a ClusterSecretStore's token in: the serviceAccountRef's.
  built external-secrets openbao-store
  ref="$(yq -N -o json -I0 'select(.kind == "ClusterSecretStore") | .spec.provider.vault.auth.kubernetes.serviceAccountRef' "$BUILT")"
  sa="$(jq -r '.name' <<<"$ref")"
  ns="$(jq -r '.namespace' <<<"$ref")"
  # shellcheck disable=SC2016 # $role and $bindings are jq variables.
  grants="$(yq -N -o json -I0 'select(. != null)' "$BUILT" | jq -rs '[.[] | select(.kind == "RoleBinding")] as $bindings
    | .[] | select(.kind == "Role" or .kind == "ClusterRole") | . as $role | .rules // [] | .[]
    | select((.resources // []) - ["serviceaccounts/token", "serviceaccounts/*", "*"] != (.resources // []))
    | select((.verbs // []) - ["create", "*"] != (.verbs // []))
    | $role.kind + "/" + ($role.metadata.namespace // "") + "/" + $role.metadata.name + " " + (.resourceNames // [] | join(","))
      + " to " + ([$bindings[] | select(.roleRef.kind == $role.kind and .roleRef.name == $role.metadata.name
          and .metadata.namespace == $role.metadata.namespace) | .subjects[]
        | .kind + "/" + .namespace + "/" + .name] | join(","))')"
  echo "token grants in the store's application: ${grants:-none}"
  [ "$grants" = "Role/$ns/openbao-store-token $sa to ServiceAccount/external-secrets/$controller" ]
}

@test "The demo ExternalSecret resolves through the store in the build" {
  local external store_name store mount role policy key ns readable writable
  built external-secrets openbao-store
  store_name="$(yq -N 'select(.kind == "ClusterSecretStore") | .metadata.name' "$BUILT")"
  store="$(yq -N -o json -I0 'select(.kind == "ClusterSecretStore") | .spec.provider.vault' "$BUILT")"
  mount="$(jq -r '.path' <<<"$store")"
  role="$(jq -r '.auth.kubernetes.role' <<<"$store")"
  built demo hello-secret
  external="$(yq -N -o json -I0 'select(.kind == "ExternalSecret")' "$BUILT")"
  echo "ExternalSecret: $external"
  [ "$(grep -c . <<<"$external")" -eq 1 ]
  ns="$(jq -r '.metadata.namespace' <<<"$external")"
  [ "$ns" = demo ]
  [ "$(jq -r '.spec.secretStoreRef.kind + "/" + .spec.secretStoreRef.name' <<<"$external")" = "ClusterSecretStore/$store_name" ]
  render
  statefulset
  initialize
  policy="$(policy "$(request "auth/kubernetes/role/$role" | jq -r '.token_policies[0]')")"
  for key in $(jq -r '[.spec.data[]?.remoteRef.key, .spec.dataFrom[]?.extract.key] | map(select(. != null)) | .[]' <<<"$external"); do
    # A key bao-put accepts, which the store reads at <mount>/data/<key>.
    bao_valid_path "$key" || { echo "bao-put refuses the key $key"; return 1; }
    # A policy path ending in * matches every path that starts with what comes before it.
    # shellcheck disable=SC2053 # the policy's path is the pattern.
    readable="$(jq -r '.path | to_entries[] | select(.value.capabilities | index("read")) | .key' <<<"$policy" |
      while read -r pattern; do if [[ "$mount/data/$key" == $pattern ]]; then echo yes; fi; done)"
    echo "$key readable by the store: ${readable:-no}"
    [ -n "$readable" ]
    # And the operator's role, which bao-put logs in with, may write it.
    # shellcheck disable=SC2053 # the policy's path is the pattern.
    writable="$(policy operator | jq -r '.path | to_entries[] | select(.value.capabilities | (index("create") and index("patch"))) | .key' |
      while read -r pattern; do if [[ "$mount/data/$key" == $pattern ]]; then echo yes; fi; done)"
    echo "$key writable by bao-put: ${writable:-no}"
    [ -n "$writable" ]
  done
}

@test "Every OpenBao pod meets the restricted Pod Security level its namespace enforces" {
  local level pods containers line
  level="$(yq -N 'select(.kind == "Namespace") | .metadata.labels["pod-security.kubernetes.io/enforce"] // "none"' \
    "$TREE/kubernetes/apps/base/openbao/namespace.yaml")"
  echo "the namespace enforces: $level"
  [ "$level" = restricted ]
  render
  # The StatefulSet's pod template and the chart's test pod.
  yq -N -o json 'select(.kind == "StatefulSet" or .kind == "Pod") | {"name": .kind + "/" + .metadata.name,
    "spec": (.spec.template.spec // .spec)}' "$RENDERED" | jq -s . >"$BATS_TEST_TMPDIR/pods.json"
  # shellcheck disable=SC2016 # $p is a jq variable.
  pods="$(jq -r '.[] | .spec as $p
    | .name + " hostNamespaces=" + ([$p.hostNetwork, $p.hostPID, $p.hostIPC] | map(select(. == true)) | length | tostring)
      + " volumes=" + ([$p.volumes // [] | .[] | keys | .[] | select(. != "name")] | unique | join(","))' "$BATS_TEST_TMPDIR/pods.json")"
  echo "$pods"
  [ "$(grep -c . <<<"$pods")" -eq 2 ]
  while read -r line; do
    [[ $line =~ \ hostNamespaces=0\ volumes=((configMap|csi|downwardAPI|emptyDir|ephemeral|persistentVolumeClaim|projected|secret)(,|$))*$ ]] ||
      { echo "not restricted: $line"; return 1; }
  done <<<"$pods"
  # shellcheck disable=SC2016 # $d, $p and $c are jq variables.
  containers="$(jq -r '.[] | .name as $d | .spec as $p | (($p.initContainers // []) + $p.containers)[] as $c
    | $d + "/" + $c.name
      + " privileged=" + ($c.securityContext.privileged // false | tostring)
      + " allowPrivilegeEscalation=" + ($c.securityContext.allowPrivilegeEscalation | tostring)
      + " runAsNonRoot=" + ($c.securityContext.runAsNonRoot // $p.securityContext.runAsNonRoot // false | tostring)
      + " runAsUser=" + ($c.securityContext.runAsUser // $p.securityContext.runAsUser // "unset" | tostring)
      + " seccomp=" + ($c.securityContext.seccompProfile.type // $p.securityContext.seccompProfile.type // "unset")
      + " drop=" + ($c.securityContext.capabilities.drop // [] | join(","))
      + " add=" + ($c.securityContext.capabilities.add // [] | map(select(. != "NET_BIND_SERVICE")) | join(","))
      + " hostPorts=" + ([$c.ports // [] | .[] | select((.hostPort // 0) != 0)] | length | tostring)' "$BATS_TEST_TMPDIR/pods.json")"
  echo "$containers"
  [ -n "$containers" ]
  while read -r line; do
    [[ $line =~ \ privileged=false\ allowPrivilegeEscalation=false\ runAsNonRoot=true\ runAsUser=([1-9][0-9]*|unset)\ seccomp=(RuntimeDefault|Localhost)\ drop=([^ ]*,)?ALL(,[^ ]*)?\ add=\ hostPorts=0$ ]] ||
      { echo "not restricted: $line"; return 1; }
  done <<<"$containers"
}

@test "Only the first member initialises OpenBao, and only on a first install" {
  local command guard data decision args script raft claims role account names member mode flag status overrides word name
  local work="$BATS_TEST_TMPDIR/guard"
  render
  statefulset
  initialize
  # The init container initialize-guard runs the guard from the ConfigMap, with the member's own data
  # directory, read-only, and a decision file in a directory it shares with the server.
  command="$(jq -c '[.spec.template.spec.initContainers // [] | .[] | select(.name == "initialize-guard") | .command] | .[0]' "$STS")"
  echo "guard: $command"
  [ "$(jq -r '.[0]' <<<"$command")" = /bin/sh ]
  guard="$(jq -r '.[1]' <<<"$command")"
  data="$(jq -r '.[2]' <<<"$command")"
  decision="$(jq -r '.[3]' <<<"$command")"
  [ "$(mounted "$guard" initialize-guard)" = "ConfigMap/openbao-initialize ${guard##*/}" ]
  raft="$(block storage raft | sed -nE 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p')"
  [ "$data" = "$raft" ]
  [ "$(volume_at "$data" initialize-guard)" = "data claim true" ]
  [ "$(volume_at "$data" openbao | cut -d' ' -f1-2)" = "data claim" ]
  [ "$(volume_at "${decision%/*}" initialize-guard | cut -d' ' -f2-)" = "emptyDir false" ]
  [ "$(volume_at "${decision%/*}" openbao | cut -d' ' -f1)" = "$(volume_at "${decision%/*}" initialize-guard | cut -d' ' -f1)" ]
  # The server's arguments take the decision through initialize-args.sh.
  args="$(jq -r '.spec.template.spec.containers[] | select(.name == "openbao") | .args | join("\n")' "$STS")"
  script="$(grep -oE '\$\(sh [^)]+\)' <<<"$args" | sed -E 's/^\$\(sh //; s/\)$//')"
  echo "argument script: ${script:-none}"
  [ "${script#* }" = "$decision" ]
  script="${script%% *}"
  [ "$(mounted "$script")" = "ConfigMap/openbao-initialize ${script##*/}" ]

  # The guard may read the other members' claims and nothing else, as the servers' own account.
  account="$(jq -r '.spec.template.spec.serviceAccountName' "$STS")"
  names="$(jq -r '.metadata.name as $set | .spec.volumeClaimTemplates[0].metadata.name as $claim
    | [range(1; .spec.replicas) | "\($claim)-\($set)-\(.)"] | join(" ")' "$STS")"
  # shellcheck disable=SC2016 # $role is a yq variable.
  role="$(ACCOUNT="$account" yq ea -N -o json -I0 '[select(.kind == "RoleBinding" and .roleRef.kind == "Role"
      and (.subjects | any_c(.kind == "ServiceAccount" and .name == strenv(ACCOUNT))))] as $bindings
    | select(.kind == "Role") | select(.metadata.name as $role | $bindings | any_c(.roleRef.name == $role)) | .rules' "$OPENBAO")"
  echo "the guard's rules: $role; the other members' claims: $names"
  [ "$(jq -cS '.' <<<"$role")" = "$(jq -ncS --arg names "$names" '[{apiGroups: [""], resources: ["persistentvolumeclaims"],
    verbs: ["get"], resourceNames: ($names | split(" "))}]')" ]

  # The guard's behaviour, from its own script, with a fake kubectl that answers as $MODE says.
  mkdir -p "$work/bin"
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"openbao-initialize\") | .data[\"${guard##*/}\"]" "$OPENBAO" >"$work/guard.sh"
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"openbao-initialize\") | .data[\"${script##*/}\"]" "$OPENBAO" >"$work/args.sh"
  cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_RECORD"
case $MODE in
  timeout) echo "Unable to connect to the server: dial tcp: i/o timeout" >&2; exit 1 ;;
  refused) echo "The connection to the server was refused" >&2; exit 1 ;;
  forbidden) echo 'Error from server (Forbidden): persistentvolumeclaims "data-openbao-1" is forbidden' >&2; exit 1 ;;
  one) present=data-openbao-1 ;;
  two) present=data-openbao-2 ;;
  both) present="data-openbao-1 data-openbao-2" ;;
  none) present="" ;;
esac
# As the API answers a get with --ignore-not-found: each claim asked for that exists, by name.
for arg; do
  for claim in $present; do
    if [ "$arg" = "$claim" ]; then echo "persistentvolumeclaim/$claim"; fi
  done
done
EOF
  chmod +x "$work/bin/kubectl"
  # An ls that fails when $LS_FAILS is set, as for a directory it may not read, and otherwise lists.
  real_ls="$(command -v ls)"
  cat >"$work/bin/ls" <<EOF
#!/usr/bin/env bash
if [[ -n \${LS_FAILS:-} ]]; then echo "ls: cannot open directory: Permission denied" >&2; exit 2; fi
exec "$real_ls" "\$@"
EOF
  chmod +x "$work/bin/ls"
  # A timeout as BusyBox's in the guard's image: it runs PROG in its own place and sends it SIG, TERM
  # unless -s names another, once SECS have passed. With $TIMEOUT_EXPIRES set they have passed before
  # PROG answers.
  cat >"$work/bin/timeout" <<'EOF'
#!/usr/bin/env bash
signal=TERM
while [[ $1 == -* ]]; do
  case $1 in
    -s) signal=$2 && shift 2 ;;
    -k) shift 2 ;;
    *) echo "timeout: unknown option $1" >&2 && exit 1 ;;
  esac
done
shift
if [[ -n ${TIMEOUT_EXPIRES:-} ]]; then
  kill -s "$signal" $$
  sleep 5
fi
exec "$@"
EOF
  chmod +x "$work/bin/timeout"
  # guard_run MEMBER MODE CONTENT: runs the guard as MEMBER, its data directory holding CONTENT (a
  # file name, or nothing), against the fake API; sets status, flag (the decision) and claims (the
  # fake's record).
  guard_run() {
    rm -rf "$work/data" "$work/decision" "$work/record"
    mkdir -p "$work/data"
    [ -z "$3" ] || : >"$work/data/$3"
    : >"$work/record"
    status=0
    POD_NAME=$1 POD_NAMESPACE=openbao MODE=$2 KUBECTL_RECORD="$work/record" PATH="$work/bin:$PATH" \
      sh "$work/guard.sh" "$work/data" "$work/decision" 2>/dev/null || status=$?
    flag="$(cat "$work/decision" 2>/dev/null || true)"
    claims="$(cat "$work/record")"
    echo "$1 ($2, data: ${3:-empty}): status $status, decision ${flag:-none}, asked: ${claims:-nothing}"
  }
  # Only on a first install: openbao-0, with no data of its own, and neither other claim.
  guard_run openbao-0 none ''
  [ "$status" -eq 0 ]
  [ "$(mounted "${flag#-config=}")" = "ConfigMap/openbao-initialize initialize.json" ]
  [ "$flag" = "-config=${flag#-config=}" ]
  [[ " $claims " == *" get persistentvolumeclaim $names "* && $claims == *" --ignore-not-found"* && $claims == *"--namespace openbao"* ]]
  # kubectl reaches the API through the pod's in-cluster configuration, which client-go takes only
  # while the configuration its flags and kubeconfig files make is the default one
  # (tools/clientcmd/merged_client_builder.go:111-124 and loader.go:385-394 in Kubernetes v1.36.1).
  # Every flag kubectl binds to that configuration (cli-runtime's genericclioptions/config_flags.go:
  # 42-61, and --kubeconfig at 369) can make it another: --request-timeout sets its Timeout
  # (client_config.go:208-214), and kubectl then asks http://localhost:8080. Only --namespace leaves
  # it as it is (client_config.go:399-406). A fake API cannot show this, so the rule itself is held:
  # the guard's call carries none of those flags, and nothing gives the guard a kubeconfig.
  overrides=" cluster user context server s tls-server-name insecure-skip-tls-verify client-certificate client-key
    certificate-authority token as as-uid as-group as-user-extra username password request-timeout disable-compression
    kubeconfig "
  overrides="$(tr -s ' \n' '  ' <<<"$overrides")"
  for word in $claims; do
    [[ $word == -* ]] || continue
    name="${word%%=*}"
    name="${name#-}"
    name="${name#-}"
    [[ $overrides != *" $name "* ]] || { echo "the guard's kubectl call overrides its configuration with $word"; return 1; }
  done
  [ -z "$(jq -r '.spec.template.spec.initContainers[] | select(.name == "initialize-guard") | .env // [] | .[].name
    | select(. == "KUBECONFIG")' "$STS")" ]
  [ "$(grep -c 'KUBECONFIG' "$work/guard.sh")" -eq 0 ]
  # A directory holding only what a new file system makes counts as empty.
  guard_run openbao-0 none lost+found
  [ "$status" -eq 0 ]
  [ -n "$flag" ]
  # Every other member, and openbao-0 with data of its own, adds nothing and asks nothing.
  for member in openbao-1 openbao-2; do
    guard_run "$member" none ''
    [ "$status" -eq 0 ]
    [ -z "$flag" ]
    [ -z "$claims" ]
  done
  guard_run openbao-0 none raft.db
  [ "$status" -eq 0 ]
  [ -z "$flag" ]
  [ -z "$claims" ]
  # Either other member's claim, or both, means the store exists: openbao-0 joins it.
  for mode in one two both; do
    guard_run openbao-0 "$mode" ''
    [ "$status" -eq 0 ]
    [ -z "$flag" ]
  done
  # A data directory it cannot list is no evidence either: the guard fails and decides nothing.
  LS_FAILS=1 guard_run openbao-0 none ''
  [ "$status" -ne 0 ]
  [ -z "$flag" ]
  # No answer from the API, whatever the reason, is no evidence: the guard fails, so the pod does
  # not start, and decides nothing.
  for mode in timeout refused forbidden; do
    guard_run openbao-0 "$mode" ''
    [ "$status" -ne 0 ]
    [ -z "$flag" ]
  done
  # Nor is a call that does not end in time: its timeout stops it, and the guard fails.
  TIMEOUT_EXPIRES=1 guard_run openbao-0 none ''
  [ "$status" -ne 0 ]
  [ -z "$flag" ]

  # The server takes the flag only as the guard writes it, and nothing from a missing or other file.
  guard_run openbao-0 none ''
  [ "$(sh "$work/args.sh" "$work/decision")" = "$flag" ]
  [ -z "$(sh "$work/args.sh" "$work/missing")" ]
  echo "-config=/etc/elsewhere.json" >"$work/decision"
  [ -z "$(sh "$work/args.sh" "$work/decision")" ]
  : >"$work/decision"
  [ -z "$(sh "$work/args.sh" "$work/decision")" ]
}

@test "the guard runs the Flux CLI of the repository's pin, by a digest Renovate updates" {
  local -a pin
  local image repository tag flux
  render
  statefulset
  image="$(jq -r '.spec.template.spec.initContainers[] | select(.name == "initialize-guard") | .image' "$STS")"
  # The repository's custom manager reads the tag, and the digest after it, on the line under a
  # '# renovate: datasource=… depName=…' comment of the file it reads.
  mapfile -t pin < <(awk -v image="$image" '$1 == "image:" && $2 == image { print prev; print $2; exit } { prev = $0 }' \
    "$TREE/kubernetes/apps/base/openbao/openbao/app/values.yaml")
  echo "the guard's image: ${image:-none} under '${pin[0]:-nothing}'"
  [ "${pin[1]:-}" = "$image" ]
  [[ ${pin[0]} =~ ^\ *#\ renovate:\ datasource=docker\ depName=([^ ]+)$ ]]
  repository="${BASH_REMATCH[1]}"
  [ "$repository" = ghcr.io/fluxcd/flux-cli ]
  [[ $image =~ ^"$repository":(v[^@]+)@sha256:[0-9a-f]{64}$ ]]
  tag="${BASH_REMATCH[1]}"
  flux="$(sed -nE 's/^flux2 = "([^"]+)"$/\1/p' "$REPO/mise.toml")"
  echo "its tag: $tag; the repository's flux2 pin: ${flux:-none}"
  [ "$tag" = "v$flux" ]
}

@test "every values key of openbao is one its pinned chart defines" {
  local keys="$BATS_TEST_TMPDIR/keys" unknown="" key map open
  local paths='[.. | select(path | length > 0) | path | select(all_c(tag == "!!str")) | join(".")] | .[]'
  render
  mkdir -p "$keys"
  yq -N "$paths" "$VALUES" "$INLINE" | sort -u >"$keys/ours"
  helm show values "$CHART" >"$keys/defaults"
  yq -N "$paths" "$keys/defaults" | sort -u >"$keys/chart"
  # A map the chart leaves empty, such as an annotations map, takes keys of the user's choosing.
  open="$(yq -N '[.. | select(tag == "!!map" and length == 0) | path | join(".")] | .[]' "$keys/defaults")"
  while read -r key; do
    for map in $open; do
      if [[ $key == "$map".* ]]; then continue 2; fi
    done
    unknown+=" $key"
  done < <(comm -23 "$keys/ours" "$keys/chart")
  echo "keys the chart does not define:${unknown:- none}"
  [ -z "$unknown" ]
}
