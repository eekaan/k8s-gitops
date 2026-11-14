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
  # flux build reads only paths below the working directory.
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
  pulled="$BATS_FILE_TMPDIR/charts/$tag"
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

# mounted FILE: "KIND/NAME KEY" of the volume the openbao container mounts at FILE's directory, the
# ConfigMap or Secret that holds FILE; nothing when no mount holds it.
mounted() {
  local dir=${1%/*} key=${1##*/}
  jq -r --arg dir "$dir" --arg key "$key" '.spec.template.spec as $pod
    | ($pod.containers[] | select(.name == "openbao") | .volumeMounts[] | select(.mountPath == $dir) | .name) as $volume
    | $pod.volumes[] | select(.name == $volume)
    | if .secret then "Secret/" + .secret.secretName + " " + $key
      elif .configMap then "ConfigMap/" + .configMap.name + " " + $key else empty end' "$STS"
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
  local kinds paths tokens sources level roles sudo grants
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
  # Self-initialisation logs its requests and responses, the root token among them, at trace level.
  level="$(jq -r '.spec.template.spec.containers[] | select(.name == "openbao") | .env[] | select(.name == "BAO_LOG_LEVEL") | .value' "$STS")"
  echo "log level: ${level:-default}"
  [[ ${level,,} != trace ]]
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
  [ -n "$selfsigned" ] && [ -n "$ca_secret" ] && [ -n "$ca_issuer" ]
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
  policy="$(policy "$policies")"
  echo "policy $policies: $policy"
  # Every path the policy names is in the mount, and every capability reads.
  others="$(jq -r --arg mount "$mount/" '.path | to_entries[]
    | select((.key | startswith($mount) | not) or (.value.capabilities - ["read", "list"] | length) > 0) | .key' <<<"$policy")"
  echo "beyond reading $mount: ${others:-nothing}"
  [ -z "$others" ]
  [ "$(jq -r --arg path "$mount/data/*" '.path[$path].capabilities | index("read") != null' <<<"$policy")" = true ]
  # The store has no other way to log in.
  [ "$(jq -r '.auth | keys | join(",")' <<<"$store")" = kubernetes ]
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

@test "Only the first member initialises OpenBao, and only while no other member answers" {
  local args script flag hostname answering out
  render
  statefulset
  initialize
  # The server's arguments come from the script, which reads the ConfigMap's copy.
  args="$(jq -r '.spec.template.spec.containers[] | select(.name == "openbao") | .args | join("\n")' "$STS")"
  script="$(grep -oE '\$\(sh [^)]+\)' <<<"$args" | sed -E 's/^\$\(sh //; s/\)$//')"
  echo "argument script: ${script:-none}"
  [ -n "$script" ]
  [ "$(mounted "$script")" = "ConfigMap/openbao-initialize ${script##*/}" ]
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"openbao-initialize\") | .data[\"${script##*/}\"]" \
    "$OPENBAO" >"$BATS_TEST_TMPDIR/args.sh"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # A bao whose status exits as OpenBao's does: 0 unsealed, 2 sealed, 1 when nothing answers. A
  # member answers when its address is listed in $ANSWERING, with its exit status.
  cat >"$BATS_TEST_TMPDIR/bin/bao" <<'EOF'
#!/usr/bin/env bash
for arg; do
  [[ $arg == -address=* ]] && address=${arg#-address=}
done
for entry in $ANSWERING; do
  [[ $address == *"//${entry%=*}."* ]] && exit "${entry#*=}"
done
exit 1
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/bao"
  # run_args HOSTNAME ANSWERING: what the script adds to the server's arguments.
  run_args() {
    HOSTNAME=$1 ANSWERING=$2 PATH="$BATS_TEST_TMPDIR/bin:$PATH" sh "$BATS_TEST_TMPDIR/args.sh"
  }
  out="$(run_args openbao-0 '')"
  echo "openbao-0 alone: ${out:-nothing}"
  flag="${out#-config=}"
  [ "$out" = "-config=$flag" ]
  [ "$(mounted "$flag")" = "ConfigMap/openbao-initialize initialize.json" ]
  for hostname in openbao-1 openbao-2; do
    out="$(run_args "$hostname" '')"
    echo "$hostname alone: ${out:-nothing}"
    [ -z "$out" ]
  done
  for answering in openbao-1=0 openbao-1=2 openbao-2=0 openbao-2=2; do
    out="$(run_args openbao-0 "$answering")"
    echo "openbao-0 while $answering answers: ${out:-nothing}"
    [ -z "$out" ]
  done
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
