#!/usr/bin/env bats
# Proves features/volume-backups.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq and jq on PATH (the versions pinned for the repository). The
# VolSync, External Secrets and LINSTOR applications' charts are pulled once per run from their
# public registries; building and rendering are offline. The restore drill's check script and the
# demo canary's command run as their containers run them, under this machine's sh, with the
# stand-ins of tests/fixtures/volsync-drill for the check's clock and the canary's sleep, mv and
# date.

bats_require_minimum_version 1.5.0
# The tests run one at a time even where bats runs a file's tests side by side: a test that starts
# while another pulls a chart finds the chart's directory before the chart is in it.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

setup_file() {
  # Helm's cache and registry settings stay in the run's own directory, and so does the Docker
  # configuration helm falls back to for credentials, so no login is read.
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG"
  # flux build rewrites the kustomization.yaml of what it builds and puts it back afterwards, so it
  # builds a copy of the applications and components, never this checkout.
  export TREE="$BATS_FILE_TMPDIR/tree"
  mkdir -p "$TREE/kubernetes"
  cp -R "$BATS_TEST_DIRNAME/../kubernetes/apps" "$BATS_TEST_DIRNAME/../kubernetes/components" "$TREE/kubernetes/"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLUSTER="$REPO/kubernetes/clusters/lab-sto2"
  KUBE="$(yq -e '.kubernetes' "$REPO/versions.yaml")"
  # The test application that opts into the component.
  DEMO=volsync-demo
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# example_vars FILE: writes the variables of the cluster's example key lists to FILE as one map.
example_vars() {
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$1"
}

# app_dir APP: sets APP_DIR to the directory of the application APP, in whichever namespace
# directory it is, relative to the copy.
app_dir() {
  local -a dirs=("$TREE"/kubernetes/apps/base/*/"$1")
  [ -f "${dirs[0]}/ks.yaml" ] || { echo "$1: no application directory with a ks.yaml"; return 1; }
  APP_DIR="${dirs[0]#"$TREE"/}"
}

# built APP [NAME=VALUE|-NAME...]: the application APP as Flux applies it: its app/ built with its
# ks.yaml, its components included, substituting strictly the variables of the cluster's example key
# lists and the application's own postBuild.substitute over them, then each NAME=VALUE over both,
# and each -NAME taken out of them. With WITHOUT_COMPONENT set, that entry of the ks.yaml's
# components is left out. Writes $BATS_TEST_TMPDIR/APP-built.yaml and sets BUILT, APP_DIR and VARS,
# the file of the variables.
built() {
  local app=$1 ks="$BATS_TEST_TMPDIR/$1-ks.yaml" pair
  shift
  app_dir "$app"
  VARS="$BATS_TEST_TMPDIR/$app-vars.yaml"
  example_vars "$BATS_TEST_TMPDIR/example-vars.yaml"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | $vars * (.spec.postBuild.substitute // {})' "$BATS_TEST_TMPDIR/example-vars.yaml" "$TREE/$APP_DIR/ks.yaml" >"$VARS"
  for pair in "$@"; do
    if [[ $pair == -* ]]; then
      NAME="${pair#-}" yq -i 'del(.[strenv(NAME)])' "$VARS"
    else
      NAME="${pair%%=*}" VALUE="${pair#*=}" yq -i '.[strenv(NAME)] = strenv(VALUE)' "$VARS"
    fi
  done
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = $vars' "$VARS" "$TREE/$APP_DIR/ks.yaml" >"$ks"
  if [ -n "${WITHOUT_COMPONENT:-}" ]; then
    yq -i '.spec.components -= [strenv(WITHOUT_COMPONENT)]' "$ks"
  fi
  BUILT="$BATS_TEST_TMPDIR/$app-built.yaml"
  # Built from the tree's parent, with paths from there, as scripts/kubernetes-check builds.
  (cd "$TREE" && flux build kustomization "$app" --path "./$APP_DIR/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute) >"$BUILT"
}

# var NAME: the value built gave the variable NAME.
var() {
  NAME="$1" yq '.[strenv(NAME)] // ""' "$VARS"
}

# render APP: renders the chart that APP's HelmRelease installs, built as built() builds it, from the
# URL and tag of its OCIRepository, with the values helm-controller gives the chart: those of the
# ConfigMap the HelmRelease reads, then the HelmRelease's own over them. The ServiceMonitor,
# PodMonitor and Grafana dashboard APIs count as present, as group versions and as kinds, so that
# only the values keep such objects out. Writes $BATS_TEST_TMPDIR/APP.yaml and sets RENDERED, CHART,
# VALUES and INLINE.
render() {
  local app=$1 url tag name release namespace pulled
  built "$app"
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  VALUES="$BATS_TEST_TMPDIR/$app-values.yaml"
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\") | .data[\"values.yaml\"]" "$BUILT" >"$VALUES"
  [ -s "$VALUES" ] || { echo "$app: no values in the ConfigMap $name its HelmRelease reads"; return 1; }
  INLINE="$BATS_TEST_TMPDIR/$app-inline.yaml"
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$BUILT" >"$INLINE"
  pulled="$BATS_FILE_TMPDIR/charts/$app/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  RENDERED="$BATS_TEST_TMPDIR/$app.yaml"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" --include-crds \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor \
    --api-versions monitoring.coreos.com/v1/PodMonitor --api-versions grafana.integreatly.org/v1beta1 \
    --api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
    --values "$VALUES" --values "$INLINE" >"$RENDERED"
}

# secret_data MASTER: the data of the Secret the ExternalSecret that built yielded writes, as a YAML
# map, when the store's key holds MASTER as RESTIC_MASTER_PASSWORD and a marker S3 key. External
# Secrets' v2 engine runs each value as a Go template with the sprig functions; helm's tpl runs it
# the same way, with the same sha256sum and printf, so the template is executed offline as written.
secret_data() {
  local chart="$BATS_TEST_TMPDIR/secret-data" values="$BATS_TEST_TMPDIR/secret-data-values.yaml"
  mkdir -p "$chart/templates"
  printf 'apiVersion: v2\nname: secret-data\nversion: 0.0.0\n' >"$chart/Chart.yaml"
  cat >"$chart/templates/data.yaml" <<'EOF'
{{- range $key, $text := .Values.templates }}
{{ $key }}: {{ tpl $text $.Values.store | toJson }}
{{- end }}
EOF
  # shellcheck disable=SC2016 # $templates is a yq variable.
  MASTER="$1" yq -N 'select(.kind == "ExternalSecret") | .spec.target.template.data as $templates
    | {"store": {"RESTIC_MASTER_PASSWORD": strenv(MASTER), "AWS_ACCESS_KEY_ID": "marker-access-key-id",
       "AWS_SECRET_ACCESS_KEY": "marker-secret-access-key"}, "templates": $templates}' "$BUILT" >"$values"
  helm template secret-data "$chart" --values "$values" | yq 'select(. != null)'
}

# object KIND: the one object of KIND that built yielded, as JSON on one line; fails unless there is
# exactly one.
object() {
  local found
  found="$(KIND="$1" yq -N -o json -I0 'select(.kind == strenv(KIND))' "$BUILT")"
  [ "$(grep -c . <<<"$found")" -eq 1 ] || { echo "$1: found $(grep -c . <<<"$found") objects, wanted one"; return 1; }
  echo "$found"
}

# named KIND NAME: the object of KIND named NAME that built yielded, as JSON on one line; fails
# unless there is exactly one.
named() {
  local found
  found="$(KIND="$1" NAME="$2" yq -N -o json -I0 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$BUILT")"
  [ "$(grep -c . <<<"$found")" -eq 1 ] || { echo "$1/$2: found $(grep -c . <<<"$found") objects, wanted one"; return 1; }
  echo "$found"
}

# stand_in NAME TOOL...: installs the stand-ins TOOL of tests/fixtures/volsync-drill, each a path in
# that directory, as $BATS_TEST_TMPDIR/NAME/bin/<the path's last part>, with an empty
# $BATS_TEST_TMPDIR/NAME/record beside it for what they read and record, and sets BIN to that bin
# and RECORD to that record.
stand_in() {
  local name=$1 tool
  shift
  BIN="$BATS_TEST_TMPDIR/$name/bin"
  RECORD="$BATS_TEST_TMPDIR/$name/record"
  rm -rf "${BATS_TEST_TMPDIR:?}/${name:?}"
  mkdir -p "$BIN" "$RECORD"
  for tool in "$@"; do
    cp "$REPO/tests/fixtures/volsync-drill/$tool" "$BIN/${tool##*/}"
  done
}

# container_argv KIND NAME CONTAINER: sets ARGV to the command and arguments of the container
# CONTAINER of the workload KIND/NAME that built yielded, and ENVIRONMENT to its environment as
# NAME=VALUE, each as the manifest gives it; fails on a variable whose value is not written there,
# and on a value or argument that is not text, which the API server refuses.
container_argv() {
  local object pod container
  object="$(named "$1" "$2")"
  pod="$(jq -c 'if .kind == "CronJob" then .spec.jobTemplate.spec.template.spec else .spec.template.spec end' <<<"$object")"
  container="$(NAME="$3" jq -c '[.containers[] | select(.name == env.NAME)] | if length == 1 then .[0] else error("not one container of that name") end' <<<"$pod")"
  [ "$(jq -r '[(.env // [])[] | select(.value == null)] | length' <<<"$container")" -eq 0 ] ||
    { echo "$1/$2 container $3: a variable whose value the manifest does not hold"; return 1; }
  [ "$(jq -r '[(.env // [])[].value, ((.command // []) + (.args // []))[] | select(type != "string")] | length' <<<"$container")" -eq 0 ] ||
    { echo "$1/$2 container $3: a variable's value or an argument that is not text: $(jq -c '.env' <<<"$container")"; return 1; }
  mapfile -d '' -t ARGV < <(jq -j '((.command // []) + (.args // []))[] | . + "\u0000"' <<<"$container")
  mapfile -d '' -t ENVIRONMENT < <(jq -j '(.env // [])[] | .name + "=" + .value + "\u0000"' <<<"$container")
  [ "${#ARGV[@]}" -gt 0 ] || { echo "$1/$2 container $3: no command"; return 1; }
}

# drill_check DIR [NAME=VALUE|-NAME...]: the restore drill's check on DIR, run as the container of
# the CronJob that built yielded runs it: its command, with the script the built ConfigMap holds in
# place of the one the pod mounts from it, and the environment the CronJob gives the container,
# with DRILL_DIR naming DIR, each NAME=VALUE over it and each -NAME taken out, and the stand-ins of
# BIN first on PATH. Sets status, output, which is its standard output, and stderr.
drill_check() {
  local dir=$1 app scripts mount pair name i
  local -a environment=()
  shift
  app="$(var APP)"
  container_argv CronJob "$app-drill-check" check
  # The path the command names is the script of the ConfigMap, where the pod mounts it.
  scripts="$BATS_TEST_TMPDIR/drill-scripts"
  mkdir -p "$scripts"
  named ConfigMap "$app-drill-scripts" | jq -j '.data["check.sh"]' >"$scripts/check.sh"
  mount="$(named CronJob "$app-drill-check" | NAME="$app-drill-scripts" jq -r '.spec.jobTemplate.spec.template.spec
    | (.volumes[] | select(.configMap.name == env.NAME) | .name) as $volume
    | .containers[] | select(.name == "check") | .volumeMounts[] | select(.name == $volume) | .mountPath')"
  [ -n "$mount" ] || { echo "the check container mounts no volume of the ConfigMap $app-drill-scripts"; return 1; }
  [ "${ARGV[*]}" = "/bin/sh $mount/check.sh" ] || { echo "the check container runs [${ARGV[*]}], not /bin/sh on the script the ConfigMap is mounted with at $mount"; return 1; }
  ARGV[1]="$scripts/check.sh"
  for pair in "${ENVIRONMENT[@]}" "DRILL_DIR=$dir" "$@"; do
    name="${pair%%=*}"
    [[ $pair != -* ]] || name="${pair#-}"
    for i in "${!environment[@]}"; do
      [[ ${environment[$i]} != "$name="* ]] || unset "environment[$i]"
    done
    [[ $pair == -* ]] || environment+=("$pair")
  done
  run --separate-stderr env -i PATH="$BIN:$PATH" "${environment[@]}" "${ARGV[@]}"
}

# seconds_of_day SCHEDULE: the second of the day at which a schedule that runs once a day, at one
# minute of one hour, starts; fails on any other schedule.
seconds_of_day() {
  [[ $1 =~ ^([0-9]|[1-5][0-9])\ ([0-9]|1[0-9]|2[0-3])\ \*\ \*\ \*$ ]] ||
    { echo "not a schedule of once a day at one minute of one hour: [$1]" >&2; return 1; }
  echo $((10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[1]} * 60))
}

# duration_seconds DURATION: a Prometheus duration of hours, minutes and seconds, such as 1h or
# 45m30s, in seconds; fails on any other form.
duration_seconds() {
  [[ -n $1 && $1 =~ ^(([0-9]+)h)?(([0-9]+)m)?(([0-9]+)s)?$ ]] || { echo "not a duration of h, m and s: $1" >&2; return 1; }
  echo $((10#${BASH_REMATCH[2]:-0} * 3600 + 10#${BASH_REMATCH[4]:-0} * 60 + 10#${BASH_REMATCH[6]:-0}))
}

# selects SELECTOR LABELS: succeeds when the label map SELECTOR is not empty and every label in it
# is in the label map LABELS with the same value, so it selects pods with those labels.
selects() {
  local selector=$1 labels=$2 key
  [ "$(yq 'length' <<<"$selector")" -gt 0 ] || return 1
  while IFS= read -r key; do
    [ "$(KEY="$key" yq '.[strenv(KEY)]' <<<"$selector")" = "$(KEY="$key" yq '.[strenv(KEY)]' <<<"$labels")" ] || return 1
  done < <(yq 'keys | .[]' <<<"$selector")
}

# unknown_fields OBJECT DEFINITIONS: for the object in the JSON OBJECT, one line per field of its
# spec that the version of its kind in the CustomResourceDefinitions of the YAML file DEFINITIONS
# does not define, or whose value is not of the type or among the values its schema allows; one line
# naming the kind and version when no definition serves them.
unknown_fields() {
  yq -N -o json -I0 'select(.kind == "CustomResourceDefinition")' "$2" | jq -rs --argjson obj "$1" '
    def check($schema; $value; $path):
      ($path | join(".")) as $where
      | if ($schema.enum // null) != null and ([$schema.enum[] | . == $value] | any | not) then
          "\($where): \($value | tojson) is not one of \($schema.enum | tojson)"
        elif $schema.type == "integer" and ($value | type) != "number" then "\($where): not an integer"
        elif $schema.type == "string" and ($value | type) != "string" then "\($where): not a string"
        elif $schema.type == "boolean" and ($value | type) != "boolean" then "\($where): not a boolean"
        elif ($schema.pattern // null) != null and ($value | type) == "string" and ($value | test($schema.pattern) | not) then
          "\($where): \($value | tojson) does not match \($schema.pattern)"
        elif ($value | type) == "object" then
          if $schema["x-kubernetes-preserve-unknown-fields"] == true and ($schema.properties // null) == null then empty
          elif ($schema.properties // null) == null and ($schema.additionalProperties // null) != null then
            $value | to_entries[] | . as $e | check($schema.additionalProperties; $e.value; $path + [$e.key])
          else
            $value | to_entries[] | . as $e
            | if ($schema.properties // {} | has($e.key)) then check($schema.properties[$e.key]; $e.value; $path + [$e.key])
              else "\($where).\($e.key): not in the schema" end
          end
        elif ($value | type) == "array" then
          $value[] | check($schema.items // {}; .; $path + ["[]"])
        else empty end;
    ($obj.apiVersion | split("/")) as [$group, $version]
    | [.[] | select(.spec.group == $group and .spec.names.kind == $obj.kind)
        | .spec.versions[] | select(.name == $version and .served)] as $served
    | if ($served | length) == 0 then "\($obj.kind) \($obj.apiVersion): no definition serves it"
      else check($served[0].schema.openAPIV3Schema.properties.spec; $obj.spec; ["spec"]) end'
}

@test "The VolSync operator runs in its own namespace with its resource definitions" {
  local overlay enabled namespace deployments elsewhere crds
  # The cluster runs the application and its namespace directory: its overlay applies both.
  overlay="$(kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2")"
  enabled="$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "volsync") | .spec.targetNamespace' <<<"$overlay")"
  namespace="$(yq -N 'select(.kind == "Namespace" and .metadata.name == "volsync-system") | .metadata.name' <<<"$overlay")"
  echo "volsync in the overlay: targetNamespace ${enabled:-none}; namespace ${namespace:-none}"
  [ "$enabled" = volsync-system ]
  [ "$namespace" = volsync-system ]

  render volsync
  echo "renders: $(yq -N 'select(. != null) | .kind' "$RENDERED" | sort | uniq -c | xargs)"
  deployments="$(yq -N 'select(.kind == "Deployment") | .metadata.name' "$RENDERED")"
  echo "deployments: ${deployments:-none}; release namespace: $(yq -N 'select(.kind == "HelmRelease") | .metadata.namespace' "$BUILT")"
  [ "$deployments" = volsync ]
  [ "$(yq -N 'select(.kind == "HelmRelease") | .metadata.namespace' "$BUILT")" = volsync-system ]
  elsewhere="$(yq -N 'select(. != null and .metadata.namespace != null and .metadata.namespace != "volsync-system")
    | .kind + "/" + .metadata.name + " in " + .metadata.namespace' "$RENDERED")"
  echo "in another namespace: ${elsewhere:-none}"
  [ -z "$elsewhere" ]

  # Deleting a definition deletes every ReplicationSource and ReplicationDestination, so Helm keeps
  # each one when the release is uninstalled, as it is when the application leaves the tree.
  crds="$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name + " "
    + (.metadata.annotations["helm.sh/resource-policy"] // "none")' "$RENDERED" | sort)"
  echo "$crds"
  [ "$crds" = "$(printf '%s\n' 'replicationdestinations.volsync.backube keep' 'replicationsources.volsync.backube keep')" ]
  [ -z "$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$BUILT")" ]
}

@test "VolSync starts once the definitions it needs exist and is Ready only once it runs" {
  local depends wait
  app_dir volsync
  depends="$(yq '.spec.dependsOn // [] | .[].name' "$TREE/$APP_DIR/ks.yaml" | sort | paste -sd' ' -)"
  wait="$(yq '.spec.wait' "$TREE/$APP_DIR/ks.yaml")"
  echo "volsync depends on: ${depends:-nothing}; waits: $wait"
  # The controller watches VolumeSnapshots, which the snapshot controller's definitions serve, and
  # the chart makes its ServiceMonitor only once that kind exists.
  [[ " $depends " == *" snapshot-controller "* ]]
  [[ " $depends " == *" prometheus-operator-crds "* ]]
  # An application that names volsync in dependsOn finds its definitions established.
  [ "$wait" = true ]
}

@test "The VolSync controller meets the restricted Pod Security level its namespace enforces" {
  local level workloads violations
  level="$(yq '.metadata.labels["pod-security.kubernetes.io/enforce"]' "$TREE/kubernetes/apps/base/volsync-system/namespace.yaml")"
  echo "enforced level: $level"
  [ "$level" = restricted ]
  render volsync
  workloads='select(.kind == "Deployment" or .kind == "DaemonSet" or .kind == "StatefulSet" or .kind == "Job")'
  echo "pod templates: $(yq -N "$workloads | .kind + \"/\" + .metadata.name" "$RENDERED" | paste -sd' ' -)"
  [ -n "$(yq -N "$workloads | .metadata.name" "$RENDERED")" ]
  # The restricted level's rules, for each pod template and each of its containers: the pod's
  # securityContext supplies runAsNonRoot, runAsUser and the seccomp profile where a container
  # sets none.
  # shellcheck disable=SC2016 # $workload, $pod, $c, $where and $profile are yq variables.
  violations="$(yq -N "$workloads"' | (.kind + "/" + .metadata.name) as $workload | .spec.template.spec as $pod
    | [
        {"bad": (($pod | .hostNetwork) == true or ($pod | .hostPID) == true or ($pod | .hostIPC) == true),
         "why": $workload + " shares a host namespace"},
        {"bad": (($pod | .volumes // []) | any_c(has("hostPath"))), "why": $workload + " mounts a host path"}
      ] + [
        (($pod | .containers // []) + ($pod | .initContainers // [])) | .[]
          | (.securityContext // {}) as $c | ($workload + " container " + .name) as $where
          | (($c | .seccompProfile.type) // ($pod | .securityContext.seccompProfile.type) // "none") as $profile
          | (
              {"bad": (($c | .privileged) == true), "why": $where + " is privileged"},
              {"bad": (($c | .allowPrivilegeEscalation) != false), "why": $where + " allows privilege escalation"},
              {"bad": (($c | .capabilities.drop // []) | any_c(. == "ALL") | not), "why": $where + " keeps its capabilities"},
              {"bad": (($c | .capabilities.add // []) - ["NET_BIND_SERVICE"] | length > 0), "why": $where + " adds capabilities"},
              {"bad": (($c | .runAsNonRoot) == false or (($c | .runAsNonRoot) // ($pod | .securityContext.runAsNonRoot)) != true),
               "why": $where + " may run as root"},
              {"bad": ((($c | .runAsUser) // ($pod | .securityContext.runAsUser)) == 0), "why": $where + " runs as user 0"},
              {"bad": ($profile != "RuntimeDefault" and $profile != "Localhost"), "why": $where + " has no seccomp profile"}
            )
      ]
    | .[] | select(.bad) | .why' "$RENDERED")"
  echo "violations: ${violations:-none}"
  [ -z "$violations" ]
}

@test "The VolSync controller keeps running while a node is drained" {
  local deployment replicas labels args apart budget minimum
  render volsync
  deployment='select(.kind == "Deployment" and .metadata.name == "volsync")'
  replicas="$(yq -N "$deployment | .spec.replicas" "$RENDERED")"
  labels="$(yq -N -o json -I0 "$deployment | .spec.template.metadata.labels" "$RENDERED")"
  args="$(yq -N "$deployment | .spec.template.spec.containers[] | select(.name == \"manager\") | .args[]" "$RENDERED")"
  echo "replicas: $replicas; pod labels: $labels"
  [ "$replicas" -ge 2 ]
  # One replica acts at a time.
  grep -qx -- '--leader-elect' <<<"$args"
  # Never two of the controller's pods on one node.
  apart="$(yq -N -o json -I0 "$deployment | .spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution // [] | .[]
    | select(.topologyKey == \"kubernetes.io/hostname\") | .labelSelector.matchLabels" "$RENDERED")"
  echo "kept apart on nodes by: ${apart:-nothing}"
  [ -n "$apart" ]
  selects "$apart" "$labels"
  # The chart makes no disruption budget; the application applies one beside the release, in the
  # release's namespace.
  built volsync
  budget="$(yq -N -o json -I0 'select(.kind == "PodDisruptionBudget") | .spec' "$BUILT")"
  echo "disruption budget: ${budget:-none} in $(yq -N 'select(.kind == "PodDisruptionBudget") | .metadata.namespace' "$BUILT")"
  [ -n "$budget" ]
  [ "$(yq -N 'select(.kind == "PodDisruptionBudget") | .metadata.namespace' "$BUILT")" = volsync-system ]
  selects "$(yq -o json -I0 '.selector.matchLabels' <<<"$budget")" "$labels"
  minimum="$(yq '.minAvailable' <<<"$budget")"
  [ "$minimum" -ge 1 ]
  [ "$minimum" -lt "$replicas" ]
}

@test "VolSync's metrics are scraped without a credential" {
  local monitors service targets credentials args
  render volsync
  monitors="$(yq -N 'select(.kind == "ServiceMonitor" or .kind == "PodMonitor") | .kind + "/" + .metadata.name' "$RENDERED")"
  echo "monitors: ${monitors:-none}"
  [ "$(grep -c . <<<"$monitors")" -eq 1 ]
  [[ $monitors == ServiceMonitor/* ]]
  # The monitor's selector picks the metrics Service, which has the port it scrapes.
  # shellcheck disable=SC2016 # $monitor and $ports are yq variables.
  targets="$(yq -N -o json -I0 'select(. != null)' "$RENDERED" | jq -rs '. as $all | .[] | select(.kind == "ServiceMonitor") | . as $monitor
    | [$monitor.spec.endpoints[].port] as $ports
    | [$all[] | select(.kind == "Service")
        | select(.metadata.labels as $labels | ($monitor.spec.selector.matchLabels | length > 0)
            and ($monitor.spec.selector.matchLabels | to_entries | all($labels[.key] == .value)))
        | select([.spec.ports[].name] as $named | $ports | all(. as $port | any($named[]; . == $port)))
        | .metadata.name] | join(" ")')"
  echo "the monitor scrapes: ${targets:-nothing}"
  [ -n "$targets" ]
  service="$(yq -N 'select(.kind == "Service") | .metadata.name' "$RENDERED")"
  [ "$targets" = "$service" ]
  # It sends no token or other credential, so the controller must not ask for one.
  credentials="$(yq -N 'select(.kind == "ServiceMonitor") | .spec.endpoints[]
    | (.authorization != null or .bearerTokenFile != null or .bearerTokenSecret != null or .basicAuth != null
      or .oauth2 != null or .tlsConfig.cert != null or .tlsConfig.keySecret != null)' "$RENDERED")"
  echo "the monitor sends a credential: $credentials"
  [ "$credentials" = false ]
  args="$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "manager") | .args[]' "$RENDERED")"
  echo "$args"
  grep -qx -- '--metrics-require-rbac=false' <<<"$args"
}

@test "An application's volume is backed up on its schedule and restored when it is created" {
  local claim source destination secret classes snapshot_classes default_snapshot_class
  local vars name capacity schedule
  # The application opts in by naming the component in its Kustomization.
  app_dir "$DEMO"
  echo "components: $(yq '.spec.components // [] | join(" ")' "$TREE/$APP_DIR/ks.yaml")"
  [ "$(yq '.spec.components // [] | map(select(. == "../../../../../components/volsync")) | length' "$TREE/$APP_DIR/ks.yaml")" -eq 1 ]
  [ -f "$TREE/kubernetes/components/volsync/kustomization.yaml" ]
  [ "$(yq '.kind' "$TREE/kubernetes/components/volsync/kustomization.yaml")" = Component ]

  # The cluster's default StorageClass and default VolumeSnapshotClass belong to one driver.
  built linstor-cluster
  classes="$(yq -N 'select(.kind == "StorageClass" and .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")
    | .metadata.name + " " + .provisioner' "$BUILT")"
  snapshot_classes="$(yq -N 'select(.kind == "VolumeSnapshotClass" and .metadata.annotations["snapshot.storage.kubernetes.io/is-default-class"] == "true")
    | .metadata.name + " " + .driver' "$BUILT")"
  echo "default StorageClass: $classes; default VolumeSnapshotClass: $snapshot_classes"
  [ "$(grep -c . <<<"$classes")" -eq 1 ]
  [ "$(grep -c . <<<"$snapshot_classes")" -eq 1 ]
  [ "${classes#* }" = "${snapshot_classes#* }" ]
  default_snapshot_class="${snapshot_classes%% *}"

  for vars in "" "VOLSYNC_CLAIM=marker-claim VOLSYNC_CAPACITY=7Gi VOLSYNC_SCHEDULE=41 */6 * * *"; do
    if [ -z "$vars" ]; then
      built "$DEMO"
    else
      built "$DEMO" VOLSYNC_CLAIM=marker-claim VOLSYNC_CAPACITY=7Gi "VOLSYNC_SCHEDULE=41 */6 * * *"
    fi
    name="$(var VOLSYNC_CLAIM)"
    [ -n "$name" ] || name="$(var APP)"
    capacity="$(var VOLSYNC_CAPACITY)"
    schedule="$(var VOLSYNC_SCHEDULE)"
    echo "built with ${vars:-the values of the application}: claim $name, capacity $capacity, schedule [$schedule]"
    [ -n "$capacity" ] && [ -n "$schedule" ]
    # The application's claim and the ReplicationDestination that fills it, each by its name: the
    # restore drill, which the test application also takes, builds a second of each.
    claim="$(named PersistentVolumeClaim "$name")"
    source="$(object ReplicationSource)"
    destination="$(named ReplicationDestination "$(var APP)-restore")"
    secret="$(object ExternalSecret | jq -r '.spec.target.name')"
    echo "claim: $claim"
    echo "source: $source"
    echo "destination: $destination"

    # The claim, on the default StorageClass, is filled on creation from the ReplicationDestination.
    [ "$(jq -r '.metadata.name' <<<"$claim")" = "$name" ]
    [ "$(jq -r '.spec.resources.requests.storage' <<<"$claim")" = "$capacity" ]
    [ "$(jq -r '.spec.storageClassName // "default"' <<<"$claim")" = default ]
    [ "$(jq -c '.spec.accessModes' <<<"$claim")" = '["ReadWriteOnce"]' ]
    [ "$(jq -r '.spec.dataSourceRef | .apiGroup + " " + .kind' <<<"$claim")" = "volsync.backube ReplicationDestination" ]
    [ "$(jq -r '.spec.dataSourceRef.name' <<<"$claim")" = "$(jq -r '.metadata.name' <<<"$destination")" ]

    # The ReplicationDestination restores the latest backup once, with restic, into a volume of the
    # claim's size, and keeps it as a snapshot, which is what the claim is made from.
    [ "$(jq -r '.spec.trigger | (.manual // "") + "|" + (.schedule // "")' <<<"$destination" | grep -cE '^[^|]+\|$')" -eq 1 ]
    [ "$(jq -r '.spec.restic.copyMethod' <<<"$destination")" = Snapshot ]
    [ "$(jq -r '.spec.restic.capacity' <<<"$destination")" = "$capacity" ]
    [ "$(jq -r '.spec.restic.repository' <<<"$destination")" = "$secret" ]
    [ "$(jq -r '(.spec.restic.previous // 0 | tostring) + " " + (.spec.restic.restoreAsOf // "latest")' <<<"$destination")" = "0 latest" ]

    # The ReplicationSource backs the claim up on the schedule, from a snapshot of it taken through
    # the default VolumeSnapshotClass, with restic into the same repository.
    [ "$(jq -r '.spec.sourcePVC' <<<"$source")" = "$name" ]
    [ "$(jq -r '.spec.trigger.schedule' <<<"$source")" = "$schedule" ]
    [ "$(jq -r '.spec.restic.copyMethod' <<<"$source")" = Snapshot ]
    [ "$(jq -r --arg default "$default_snapshot_class" '.spec.restic.volumeSnapshotClassName // $default' <<<"$source")" = "$default_snapshot_class" ]
    [ "$(jq -r '.spec.restic.storageClassName // "default"' <<<"$source")" = default ]
    [ "$(jq -r '.spec.restic.repository' <<<"$source")" = "$secret" ]
    # Old backups are forgotten by a stated rule, not VolSync's default of the last one only.
    [ "$(jq -r '.spec.restic.retain | length' <<<"$source")" -gt 0 ]
  done
}

@test "The repository and its credentials come from cluster-config and the secret store" {
  local declared var external source keys repository
  # The bucket's prefix, the endpoint and the region are cluster-config's, which the example
  # declares.
  declared="$(yq 'keys | .[]' "$CLUSTER/cluster-config.example.yaml")"
  for var in BACKUP_BUCKET_PREFIX S3_ENDPOINT S3_REGION; do
    grep -qxF -- "$var" <<<"$declared" || { echo "$var is not in cluster-config.example.yaml"; return 1; }
  done
  built "$DEMO" BACKUP_BUCKET_PREFIX=marker-prefix S3_ENDPOINT=https://s3.marker.example S3_REGION=marker-region
  external="$(object ExternalSecret)"
  source="$(object ReplicationSource)"
  echo "$external"
  # One key of the ClusterSecretStore, into the Secret the movers read.
  [ "$(jq -r '.apiVersion' <<<"$external")" = external-secrets.io/v1 ]
  [ "$(jq -r '.spec.secretStoreRef | .kind + "/" + .name' <<<"$external")" = ClusterSecretStore/openbao ]
  [ "$(jq -r '.spec.target.name' <<<"$external")" = "$(jq -r '.spec.restic.repository' <<<"$source")" ]
  [ "$(jq -r '[.spec.dataFrom[]?.extract.key] | length' <<<"$external")" -eq 1 ]
  [ "$(jq -r '.spec.data // [] | length' <<<"$external")" -eq 0 ]
  # The Secret holds what the template renders and nothing else of the store's key, and exactly
  # what the restic mover reads for an S3 repository.
  [ "$(jq -r '.spec.target.template | .engineVersion + " " + .mergePolicy' <<<"$external")" = "v2 Replace" ]
  keys="$(jq -r '.spec.target.template.data | keys | join(" ")' <<<"$external")"
  echo "the Secret's keys: $keys"
  [ "$keys" = "AWS_ACCESS_KEY_ID AWS_DEFAULT_REGION AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD RESTIC_REPOSITORY" ]
  for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    [ "$(VAR="$var" jq -r '.spec.target.template.data[env.VAR]' <<<"$external")" = "{{ .$var }}" ]
  done
  # The application's own path in the VolSync bucket, at the endpoint, in the region, all from
  # cluster-config.
  repository="$(jq -r '.spec.target.template.data.RESTIC_REPOSITORY' <<<"$external")"
  echo "repository: $repository"
  [ "$repository" = "s3:https://s3.marker.example/marker-prefix-volsync/$(var APP)" ]
  [ "$(var APP)" = "$DEMO" ]
  [ "$(jq -r '.spec.target.template.data.AWS_DEFAULT_REGION' <<<"$external")" = marker-region ]
  # Nothing in the component is a Secret.
  [ -z "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$BUILT")" ]
  [ -z "$(grep -rlE '^kind: Secret$' "$TREE/kubernetes/components/volsync" || true)" ]
}

@test "Each repository has a password of its own, and the master password never leaves the store" {
  local master=marker-master-password other=other-application first second third fourth digest
  built "$DEMO"
  secret_data "$master" >"$BATS_TEST_TMPDIR/first.yaml"
  first="$(yq '.RESTIC_PASSWORD' "$BATS_TEST_TMPDIR/first.yaml")"
  secret_data "$master" >"$BATS_TEST_TMPDIR/second.yaml"
  second="$(yq '.RESTIC_PASSWORD' "$BATS_TEST_TMPDIR/second.yaml")"
  echo "the Secret, rendered: $(yq -o json -I0 '.' "$BATS_TEST_TMPDIR/first.yaml")"
  # No value of the Secret holds the master.
  [ -z "$(grep -F -- "$master" "$BATS_TEST_TMPDIR/first.yaml" || true)" ]
  # The password is the SHA-256 digest of the master, a slash and the application's name, as hex,
  # the same each time the template runs.
  digest="$(printf '%s/%s' "$master" "$(var APP)" | sha256sum | cut -d' ' -f1)"
  echo "password: $first; again: $second; digest of the master and $(var APP): $digest"
  [[ $first =~ ^[0-9a-f]{64}$ ]]
  [ "$first" = "$digest" ]
  [ "$second" = "$first" ]
  # Another application's differs, and so does the password from another master.
  built "$DEMO" "APP=$other"
  third="$(secret_data "$master" | yq '.RESTIC_PASSWORD')"
  fourth="$(secret_data other-master | yq '.RESTIC_PASSWORD')"
  echo "$other's password: $third; with another master: $fourth"
  [ "$third" = "$(printf '%s/%s' "$master" "$other" | sha256sum | cut -d' ' -f1)" ]
  [ "$third" != "$first" ]
  [ "$fourth" != "$third" ]
}

@test "The movers meet the restricted Pod Security level of the application's namespace" {
  local level privileged object name context movers
  app_dir "$DEMO"
  level="$(yq '.metadata.labels["pod-security.kubernetes.io/enforce"]' "$TREE/${APP_DIR%/*}/namespace.yaml")"
  privileged="$(yq '.metadata.annotations["volsync.backube/privileged-movers"] // "false"' "$TREE/${APP_DIR%/*}/namespace.yaml")"
  echo "namespace ${APP_DIR%/*}: enforces $level, privileged movers: $privileged"
  [ "$level" = restricted ]
  [ "$privileged" = false ]
  built "$DEMO"
  # Every object that makes VolSync run a mover: the backup, the restore of the claim and the
  # restore drill's.
  movers="$(yq -N 'select(.kind == "ReplicationSource" or .kind == "ReplicationDestination") | .kind + " " + .metadata.name' "$BUILT" | sort)"
  echo "movers of: ${movers//$'\n'/, }"
  [ "$movers" = "$(printf '%s\n' "ReplicationDestination $DEMO-drill" "ReplicationDestination $DEMO-restore" "ReplicationSource $DEMO")" ]
  while read -r object name; do
    context="$(named "$object" "$name" | jq -c '.spec.restic.moverSecurityContext // {}')"
    echo "$object $name mover: $context"
    [ "$(jq -r '.runAsNonRoot' <<<"$context")" = true ]
    [ "$(jq -r '.runAsUser // 0' <<<"$context")" -gt 0 ]
    [ "$(jq -r '.runAsGroup // 0' <<<"$context")" -gt 0 ]
    [ "$(jq -r '.fsGroup // 0' <<<"$context")" -gt 0 ]
    [ "$(jq -r '.seccompProfile.type' <<<"$context")" = RuntimeDefault ]
  done <<<"$movers"
  # The user and group come from the application.
  built "$DEMO" VOLSYNC_UID=2345 VOLSYNC_GID=3456
  context="$(object ReplicationSource | jq -c '.spec.restic.moverSecurityContext')"
  echo "with VOLSYNC_UID and VOLSYNC_GID set: $context"
  [ "$(jq -r '[.runAsUser, .runAsGroup, .fsGroup] | map(tostring) | join(" ")' <<<"$context")" = "2345 3456 3456" ]
}

@test "Every object the component makes is one the cluster's definitions accept" {
  local definitions app objects unknown="" line drill refused
  # The definitions the cluster's charts install: VolSync's and External Secrets'.
  definitions="$BATS_TEST_TMPDIR/definitions.yaml"
  for app in volsync external-secrets; do
    render "$app"
    yq 'select(.kind == "CustomResourceDefinition")' "$RENDERED" >>"$definitions"
    echo "---" >>"$definitions"
  done
  built "$DEMO"
  objects="$(yq -N -o json -I0 'select(.apiVersion | test("^(volsync\.backube|external-secrets\.io)/"))' "$BUILT")"
  echo "objects: $(jq -r '.kind + "/" + .metadata.name' <<<"$objects" | paste -sd' ' -)"
  # Both components' objects of these kinds, the restore drill's ReplicationDestination among them.
  [ "$(jq -r '.kind + "/" + .metadata.name' <<<"$objects" | sort | paste -sd' ' -)" = "ExternalSecret/$DEMO-volsync ReplicationDestination/$DEMO-drill ReplicationDestination/$DEMO-restore ReplicationSource/$DEMO" ]
  while IFS= read -r line; do
    unknown+="$(unknown_fields "$line" "$definitions")"$'\n'
  done <<<"$objects"
  echo "not accepted:${unknown//$'\n'/ }"
  [ -z "${unknown//$'\n'/}" ]
  # The comparison refuses what the definition does not allow, on the restore drill's own object:
  # a field under another spelling, a copy method the definition does not list, a schedule its
  # pattern does not match, and a text where it wants true or false.
  drill="$(DEMO="$DEMO" jq -c 'select(.kind == "ReplicationDestination" and .metadata.name == env.DEMO + "-drill")' <<<"$objects")"
  refused="$(unknown_fields "$(jq -c '.spec.restic.destinationPvc = .spec.restic.destinationPVC' <<<"$drill")" "$definitions")"
  echo "another spelling: $refused"
  [ "$refused" = "spec.restic.destinationPvc: not in the schema" ]
  refused="$(unknown_fields "$(jq -c '.spec.restic.copyMethod = "Straight"' <<<"$drill")" "$definitions")"
  echo "another copy method: $refused"
  [[ $refused == 'spec.restic.copyMethod: "Straight" is not one of '* ]]
  refused="$(unknown_fields "$(jq -c '.spec.trigger.schedule = "every night"' <<<"$drill")" "$definitions")"
  echo "another schedule: $refused"
  [[ $refused == 'spec.trigger.schedule: "every night" does not match '* ]]
  refused="$(unknown_fields "$(jq -c '.spec.restic.enableFileDeletion = "true"' <<<"$drill")" "$definitions")"
  echo "a text for a boolean: $refused"
  [ "$refused" = "spec.restic.enableFileDeletion: not a boolean" ]
}

@test "Only the seeding recipe writes the repository's credentials into the secret store" {
  local stores repositories target store files file mount key under writers
  local initial="$TREE/kubernetes/apps/base/openbao/openbao/app/initialize/initialize.json"
  # What the tree holds is checked here; what VolSync does without the Secret is its own code's:
  # the restic mover's Synchronize, in internal/controller/mover/restic/mover.go at v0.17.0,
  # returns before it creates the mover's Job while validateRepository finds no Secret named in
  # spec.restic.repository with RESTIC_REPOSITORY and RESTIC_PASSWORD.
  #
  # The movers read one Secret, which only the component's ExternalSecret makes: nothing it builds
  # is a Secret, and the ReplicationSource and ReplicationDestination name the ExternalSecret's
  # target.
  built "$DEMO"
  repositories="$(yq -N 'select(.kind == "ReplicationSource" or .kind == "ReplicationDestination") | .spec.restic.repository' "$BUILT" | sort -u)"
  target="$(yq -N 'select(.kind == "ExternalSecret") | .spec.target.name' "$BUILT")"
  echo "the movers read: $repositories; the ExternalSecret writes: $target"
  [ -n "$target" ]
  [ "$repositories" = "$target" ]
  [ -z "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$BUILT")" ]
  # The one secret store the tree defines is the one the ExternalSecret reads from.
  store="$(yq -N 'select(.kind == "ExternalSecret") | .spec.secretStoreRef.kind + "/" + .spec.secretStoreRef.name' "$BUILT")"
  files="$(grep -rlE '^kind: (Cluster)?SecretStore$' "$REPO/kubernetes" || true)"
  stores="$(for file in $files; do
    yq -N 'select(.kind == "SecretStore" or .kind == "ClusterSecretStore") | .kind + "/" + .metadata.name' "$file"
  done)"
  echo "the ExternalSecret reads: ${store:-nothing}; secret stores defined: ${stores:-none}"
  [ -n "$store" ]
  [ "$stores" = "$store" ]
  # Nothing in the tree writes the key it reads into that store but the seeding recipe. OpenBao
  # starts with the store's mount empty, as its initial configuration makes no request under the
  # mount; nothing pushes a Secret into a store; and no other manifest, script or recipe names the
  # key's path or hands it to bao-put, so its values reach the store only from an operator running
  # that recipe.
  mount="$(yq -N 'select(.kind == "ClusterSecretStore") | .spec.provider.vault.path' "$files")"
  key="$(yq -N 'select(.kind == "ExternalSecret") | [.spec.dataFrom[].extract.key, .spec.data[].remoteRef.key] | unique | .[]' "$BUILT")"
  echo "the store's mount: ${mount:-none}; the key it reads: ${key:-none}"
  [ -n "$mount" ]
  [ "$(grep -c . <<<"$key")" -eq 1 ]
  [ -s "$initial" ]
  under="$(jq -r --arg mount "$mount" '[.. | objects | select(has("path")) | .path | strings
    | select(startswith($mount + "/"))] | .[]' "$initial")"
  echo "requests of the initial configuration under the mount: ${under:-none}"
  [ -z "$under" ]
  writers="$(grep -rlE "^kind: PushSecret$|(^|[^[:alnum:]_-])$mount/(data/)?$key([^[:alnum:]_/-]|$)|bao[-_]put[[:blank:]]+$key([^[:alnum:]_/-]|$)" \
    "$REPO/kubernetes" "$REPO/scripts" "$REPO/just" "$REPO/justfile" || true)"
  echo "files that write the key: ${writers:-none}"
  [ "${writers#"$REPO"/}" = scripts/bao-seed-volsync ]
  # That recipe's own write is to the key, and no script but bao-put, whose key is its argument, and
  # bao-seed-postgres, which writes its own key,
  # writes to the mount's data path otherwise: a script that wrote the key through variables would
  # show here.
  grep -qE "^volsync_key=$key\$" "$REPO/scripts/bao-seed-volsync"
  # shellcheck disable=SC2016 # the pattern names shell variables.
  grep -qE 'bao_request POST "\$bao_mount/data/\$volsync_key"' "$REPO/scripts/bao-seed-volsync"
  grep -qE '^postgres_key=postgres-backups$' "$REPO/scripts/bao-seed-postgres"
  # shellcheck disable=SC2016 # the pattern names shell variables.
  grep -qE 'bao_request POST "\$bao_mount/data/\$postgres_key"' "$REPO/scripts/bao-seed-postgres"
  writers="$(grep -rlE 'bao_request (POST|PUT|PATCH) "[^"]*/data/' "$REPO/scripts" | sed "s#^$REPO/##" | sort | paste -sd' ' -)"
  echo "scripts that write under the mount's data path: ${writers:-none}"
  [ "$writers" = "scripts/bao-put scripts/bao-seed-postgres scripts/bao-seed-volsync" ]
}

@test "The demo volume's backup and restore objects are in what Flux applies for the cluster" {
  local overlay enabled namespace opted drills dependencies name kinds found
  overlay="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2" >"$overlay"
  enabled="$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "volsync") | .spec.path' "$overlay")"
  namespace="$(yq -N 'select(.kind == "Namespace" and .metadata.name == "volsync-system") | .metadata.name' "$overlay")"
  opted="$(yq -N 'select(.kind == "Kustomization" and (.spec.components // [] | any_c(test("components/volsync$"))))
    | .metadata.name' "$overlay")"
  echo "volsync: ${enabled:-not applied}; namespace: ${namespace:-none}; applications with the component: ${opted:-none}"
  [ "$enabled" = ./apps/base/volsync-system/volsync/app ]
  [ "$namespace" = volsync-system ]
  # The test application, n8n and Open WebUI, which keep their data on a volume of the component's,
  # are the applications that take it.
  [ "$(paste -sd' ' - <<<"$opted")" = "n8n open-webui $DEMO" ]
  # The restore drill is the test application's alone, as it writes the canary the drill checks, and
  # an application takes it only beside components/volsync, whose repository it restores.
  drills="$(yq -N 'select(.kind == "Kustomization" and (.spec.components // [] | any_c(test("components/volsync-drill$"))))
    | .metadata.name' "$overlay")"
  echo "applications with the restore drill: ${drills:-none}"
  [ "$(paste -sd' ' - <<<"$drills")" = "$DEMO" ]
  for name in $drills; do
    grep -qxF -- "$name" <<<"$opted" || { echo "$name takes the restore drill without components/volsync"; return 1; }
  done
  # n8n and Open WebUI build nothing of the drill.
  for name in n8n open-webui; do
    built "$name"
    found="$(yq -N 'select(.metadata.name | test("-drill(-check|-scripts)?$")) | .kind + "/" + .metadata.name' "$BUILT")"
    echo "$name builds of the drill: ${found:-nothing}"
    [ -z "$found" ]
  done
  # It waits for the operator, External Secrets, LINSTOR's classes and the store's application, each
  # of which the overlay applies.
  dependencies="$(DEMO="$DEMO" yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(DEMO)) | .spec.dependsOn[].name' "$overlay" | sort | paste -sd' ' -)"
  echo "dependsOn: $dependencies"
  [ "$dependencies" = "external-secrets linstor-cluster openbao-store volsync" ]
  for name in $dependencies; do
    [ "$(NAME="$name" yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(NAME)) | .metadata.name' "$overlay")" = "$name" ]
  done
  # What it builds: the claim, what restores it and what backs it up.
  built "$DEMO"
  kinds="$(yq -N '.kind' "$BUILT" | sort | paste -sd' ' -)"
  echo "built: $kinds"
  [[ $kinds == *PersistentVolumeClaim* && $kinds == *ReplicationDestination* && $kinds == *ReplicationSource* ]]
}

# env_value NAME: the value of NAME in ENVIRONMENT, which container_argv set; fails unless it is
# there once.
env_value() {
  [ "$(printf '%s\n' "${ENVIRONMENT[@]}" | grep -c "^$1=")" -eq 1 ] ||
    { echo "the container's environment holds $1 not once" >&2; return 1; }
  printf '%s\n' "${ENVIRONMENT[@]}" | sed -n "s/^$1=//p"
}

@test "An application that takes the drill restores its newest backup into a scratch claim every night" {
  local drill="$TREE/kubernetes/components/volsync-drill" ks app claim destination restore cronjob secret
  local without with extra vars used var
  # The application opts in by naming the component beside components/volsync in its Kustomization.
  app_dir "$DEMO"
  ks="$TREE/$APP_DIR/ks.yaml"
  echo "components: $(yq '.spec.components // [] | join(" ")' "$ks")"
  [ "$(yq '.spec.components // [] | map(select(. == "../../../../../components/volsync-drill")) | length' "$ks")" -eq 1 ]
  [ "$(yq '.spec.components // [] | map(select(. == "../../../../../components/volsync")) | length' "$ks")" -eq 1 ]
  [ "$(yq '.kind' "$drill/kustomization.yaml")" = Component ]
  # The application's Kustomization waits for nothing it applies, so the scratch claim, which stays
  # Pending until the first restore's mover is scheduled, holds nothing up.
  echo "wait: $(yq '.spec.wait // false' "$ks"); health checks: $(yq '(.spec.healthChecks // []) + (.spec.healthCheckExprs // []) | length' "$ks")"
  [ "$(yq '.spec.wait // false' "$ks")" = false ]
  [ "$(yq '(.spec.healthChecks // []) + (.spec.healthCheckExprs // []) | length' "$ks")" -eq 0 ]

  for vars in "" "APP=marker-app VOLSYNC_CLAIM=marker-claim VOLSYNC_CAPACITY=7Gi VOLSYNC_DRILL_RESTORE_SCHEDULE=41 */6 * * * VOLSYNC_DRILL_CHECK_SCHEDULE=43 */6 * * * VOLSYNC_DRILL_MAX_AGE=\"1234\""; do
    local -a pairs=()
    if [ -n "$vars" ]; then
      pairs=(APP=marker-app VOLSYNC_CLAIM=marker-claim VOLSYNC_CAPACITY=7Gi "VOLSYNC_DRILL_RESTORE_SCHEDULE=41 */6 * * *"
        "VOLSYNC_DRILL_CHECK_SCHEDULE=43 */6 * * *" 'VOLSYNC_DRILL_MAX_AGE="1234"')
    fi
    # What components/volsync alone makes, then both components: the drill adds its four objects and
    # changes nothing of the rest.
    WITHOUT_COMPONENT=../../../../../components/volsync-drill built "$DEMO" "${pairs[@]}"
    without="$(yq -N -o json -I0 '.' "$BUILT" | sort)"
    built "$DEMO" "${pairs[@]}"
    with="$(yq -N -o json -I0 '.' "$BUILT" | sort)"
    app="$(var APP)"
    echo "built with ${vars:-the values of the application}: APP $app"
    [ -n "$without" ]
    [ -z "$(comm -23 <(echo "$without") <(echo "$with"))" ]
    extra="$(comm -13 <(echo "$without") <(echo "$with") | jq -r '.kind + "/" + .metadata.name' | sort | paste -sd' ' -)"
    echo "the drill adds: $extra"
    [ "$extra" = "ConfigMap/$app-drill-scripts CronJob/$app-drill-check PersistentVolumeClaim/$app-drill ReplicationDestination/$app-drill" ]
    claim="$(named PersistentVolumeClaim "$app-drill")"
    destination="$(named ReplicationDestination "$app-drill")"
    restore="$(named ReplicationDestination "$app-restore")"
    cronjob="$(named CronJob "$app-drill-check")"
    secret="$(object ExternalSecret | jq -r '.spec.target.name')"
    echo "claim: $claim"
    echo "destination: $destination"

    # The scratch claim: the volume's size on the default StorageClass, made empty.
    [ "$(jq -r '.spec.resources.requests.storage' <<<"$claim")" = "$(var VOLSYNC_CAPACITY)" ]
    [ "$(jq -c '.spec.accessModes' <<<"$claim")" = '["ReadWriteOnce"]' ]
    [ "$(jq -c '.spec | del(.accessModes, .resources) ' <<<"$claim")" = '{}' ]
    [ "$(jq -c '.spec.resources | keys' <<<"$claim")" = '["requests"]' ]

    # The ReplicationDestination: on the restore schedule alone, the newest backup (no previous, no
    # restoreAsOf) of the application's repository straight into the scratch claim, no snapshot,
    # the files the backup does not hold deleted, restic's cache, at VolSync's default size, deleted
    # after each restore, and the movers' security context of components/volsync, field for field.
    [ "$(jq -c '.spec | keys' <<<"$destination")" = '["restic","trigger"]' ]
    [ "$(jq -c '.spec.trigger' <<<"$destination")" = "$(SCHEDULE="$(var VOLSYNC_DRILL_RESTORE_SCHEDULE)" jq -nc '{schedule: env.SCHEDULE}')" ]
    [ "$(jq -c '.spec.restic | keys' <<<"$destination")" = '["cleanupCachePVC","copyMethod","destinationPVC","enableFileDeletion","moverSecurityContext","repository"]' ]
    [ "$(jq -r '.spec.restic | [.repository, .destinationPVC, .copyMethod, .enableFileDeletion, .cleanupCachePVC] | map(tostring) | join(" ")' <<<"$destination")" = "$secret $app-drill Direct true true" ]
    [ "$(jq -cS '.spec.restic.moverSecurityContext' <<<"$destination")" = "$(jq -cS '.spec.restic.moverSecurityContext' <<<"$restore")" ]

    # The check: on the check schedule, given the largest age, its one script from the ConfigMap,
    # byte for byte the component's, under a name without a hash.
    [ "$(jq -r '.spec.schedule' <<<"$cronjob")" = "$(var VOLSYNC_DRILL_CHECK_SCHEDULE)" ]
    container_argv CronJob "$app-drill-check" check
    [[ $(var VOLSYNC_DRILL_MAX_AGE) =~ ^\"([0-9]+)\"$ ]]
    [ "$(env_value DRILL_MAX_AGE_SECONDS)" = "${BASH_REMATCH[1]}" ]
    [ "$(named ConfigMap "$app-drill-scripts" | jq -c '.data | keys')" = '["check.sh"]' ]
    cmp <(named ConfigMap "$app-drill-scripts" | jq -j '.data["check.sh"]') "$REPO/kubernetes/components/volsync-drill/scripts/check.sh"
  done

  # The component reads four of components/volsync's variables and adds three, which nothing defaults.
  used="$(grep -rhoE '\$\{[A-Za-z_][A-Za-z0-9_]*' "$drill" | sed 's/^\${//' | sort -u | paste -sd' ' -)"
  echo "variables the component reads: $used"
  [ "$used" = "APP VOLSYNC_CAPACITY VOLSYNC_DRILL_CHECK_SCHEDULE VOLSYNC_DRILL_MAX_AGE VOLSYNC_DRILL_RESTORE_SCHEDULE VOLSYNC_GID VOLSYNC_UID" ]
  for var in VOLSYNC_DRILL_RESTORE_SCHEDULE VOLSYNC_DRILL_CHECK_SCHEDULE VOLSYNC_DRILL_MAX_AGE; do
    run built "$DEMO" "-$var"
    echo "built without $var: status $status: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"$var"* ]]
  done
  # The largest age carries its quotes: Flux substitutes after kustomize has dropped the manifest's,
  # so a bare number reaches the check's variable as a number, which the API server refuses.
  built "$DEMO" VOLSYNC_DRILL_MAX_AGE=95400
  echo "with a bare number: $(named CronJob "$DEMO-drill-check" | jq -c '.spec.jobTemplate.spec.template.spec.containers[0].env')"
  [ "$(named CronJob "$DEMO-drill-check" | jq -r '.spec.jobTemplate.spec.template.spec.containers[0].env[]
    | select(.name == "DRILL_MAX_AGE_SECONDS") | .value | type')" = number ]
}

@test "The scratch claim is never backed up and the drill gives no key a new holder" {
  local scratch target repositories named_by pod
  built "$DEMO"
  scratch="$(var APP)-drill"
  # One ExternalSecret and no Secret; the drill's component holds neither, nor anything that writes a
  # secret.
  echo "ExternalSecrets: $(yq -N 'select(.kind == "ExternalSecret") | .metadata.name' "$BUILT" | paste -sd' ' -)"
  [ "$(yq -N 'select(.kind == "ExternalSecret") | .metadata.name' "$BUILT" | grep -c .)" -eq 1 ]
  [ -z "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$BUILT")" ]
  [ -z "$(grep -rlE '^kind: (Secret|ExternalSecret|PushSecret|SecretStore|ClusterSecretStore)$' "$TREE/kubernetes/components/volsync-drill" || true)" ]
  # Both ReplicationDestinations and the ReplicationSource read the one Secret the ExternalSecret
  # writes.
  target="$(object ExternalSecret | jq -r '.spec.target.name')"
  repositories="$(yq -N 'select(.kind == "ReplicationSource" or .kind == "ReplicationDestination")
    | .kind + "/" + .metadata.name + " " + .spec.restic.repository' "$BUILT" | sort)"
  echo "repositories: ${repositories//$'\n'/, }"
  [ "$repositories" = "$(printf '%s\n' "ReplicationDestination/$DEMO-drill $target" "ReplicationDestination/$DEMO-restore $target" "ReplicationSource/$DEMO $target")" ]
  # The only ReplicationSource backs the application's own claim up.
  [ "$(object ReplicationSource | jq -r '.spec.sourcePVC')" = "$DEMO" ]
  # The scratch claim is named by its ReplicationDestination, which copies into it directly, and by
  # the check job, and by nothing else: no ReplicationSource, snapshot or clone takes it.
  named_by="$(yq -N -o json -I0 '.' "$BUILT" | SCRATCH="$scratch" jq -r '. as $o | paths(type == "string") as $p
    | select(($o | getpath($p)) == env.SCRATCH)
    | $o.kind + "/" + $o.metadata.name + " " + ($p | map(if type == "number" then "[]" else . end) | join("."))' | sort)"
  echo "what names $scratch: ${named_by//$'\n'/, }"
  [ "$named_by" = "$(printf '%s\n' "CronJob/$DEMO-drill-check spec.jobTemplate.spec.template.spec.volumes.[].persistentVolumeClaim.claimName" \
    "PersistentVolumeClaim/$scratch metadata.name" "ReplicationDestination/$DEMO-drill metadata.name" \
    "ReplicationDestination/$DEMO-drill spec.restic.destinationPVC")" ]
  [ "$(named ReplicationDestination "$DEMO-drill" | jq -r '.spec.restic.copyMethod')" = Direct ]
  # The check job reads no Secret and mounts no token.
  pod="$(named CronJob "$DEMO-drill-check" | jq -c '.spec.jobTemplate.spec.template.spec')"
  [ "$(jq -r '.automountServiceAccountToken' <<<"$pod")" = false ]
  [ "$(jq '[.. | objects | select(has("secretKeyRef") or has("secretRef") or has("secret") or has("projected") or has("csi"))] | length' <<<"$pod")" -eq 0 ]
}

@test "The drill's check fails on an empty volume, a missing heartbeat and a stale one, and passes on a fresh one" {
  local cases="$BATS_TEST_TMPDIR/cases" work="$BATS_TEST_TMPDIR/work" now=2000000000 max before after name value
  built "$DEMO"
  stand_in check date
  echo "$now" >"$RECORD/now"
  container_argv CronJob "$DEMO-drill-check" check
  max="$(env_value DRILL_MAX_AGE_SECONDS)"
  echo "the check runs [${ARGV[*]}] with the largest age $max"
  [[ $max =~ ^[1-9][0-9]*$ ]]
  # heartbeat CASE LINE: a directory CASE with the file created and a heartbeat holding LINE.
  heartbeat() {
    mkdir -p "$cases/$1"
    printf 'marker\n' >"$cases/$1/created"
    printf '%s\n' "$2" >"$cases/$1/heartbeat"
  }
  mkdir -p "$cases/empty" "$cases/lost-found/lost+found" "$cases/no-heartbeat" "$cases/hidden-only" "$cases/empty-heartbeat" "$work"
  printf 'marker\n' >"$cases/no-heartbeat/created"
  # Files the restore brought back, though a listing without hidden files shows none.
  printf 'marker\n' >"$cases/hidden-only/.heartbeat.tmp"
  : >"$cases/empty-heartbeat/heartbeat"
  heartbeat fresh "$((now - 7200)) $(date -u -d "@$((now - 7200))" +%Y-%m-%dT%H:%M:%SZ)"
  heartbeat at-bound "$((now - max)) $(date -u -d "@$((now - max))" +%Y-%m-%dT%H:%M:%SZ)"
  heartbeat stale "$((now - max - 1)) $(date -u -d "@$((now - max - 1))" +%Y-%m-%dT%H:%M:%SZ)"
  heartbeat future "$((now + 1)) $(date -u -d "@$((now + 1))" +%Y-%m-%dT%H:%M:%SZ)"
  heartbeat date-only "$(date -u -d "@$((now - 60))" +%Y-%m-%dT%H:%M:%SZ)"
  heartbeat fraction "$((now - 60)).5 marker"
  heartbeat negative "-60 marker"
  heartbeat leading-zero "0$((now - 60)) marker"
  heartbeat blank-line ""
  before="$(cd "$cases" && find . -printf '%p %y %s %m %T@\n' | sort)"
  # Run from an empty directory, which stays empty, as do the cases.
  cd "$work"

  # Fresh, and exactly as old as the largest age: one line with the age and the bound.
  drill_check "$cases/fresh"
  echo "fresh: $status [$output] [$stderr]"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "${#lines[@]}" -eq 1 ]
  [[ $output == *" 7200 seconds old"* && $output == *" $max seconds"* ]]
  drill_check "$cases/at-bound"
  echo "at the bound: $status [$output] [$stderr]"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "${#lines[@]}" -eq 1 ]
  [[ $output == *" $max seconds old"* ]]

  # Every other case fails with its reason on standard error and nothing on standard output.
  for name in empty lost-found; do
    drill_check "$cases/$name"
    echo "$name: $status [$output] [$stderr]"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ $stderr == *"brought nothing back"* ]]
    [[ $stderr == *"a repository path that holds no backup restores nothing without an error"* ]]
  done
  for name in no-heartbeat hidden-only; do
    drill_check "$cases/$name"
    echo "$name: $status [$output] [$stderr]"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ $stderr == *"holds no heartbeat"* ]]
  done
  for name in empty-heartbeat date-only fraction negative leading-zero blank-line; do
    drill_check "$cases/$name"
    echo "$name: $status [$output] [$stderr]"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ $stderr == *"not a whole number of seconds"* ]]
  done
  drill_check "$cases/future"
  echo "future: $status [$output] [$stderr]"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ $stderr == *"lies in the future"* ]]
  drill_check "$cases/stale"
  echo "stale: $status [$output] [$stderr]"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ $stderr == *" $((max + 1)) seconds old"* && $stderr == *" $max seconds"* ]]

  # The largest age unset, empty or not a positive whole number, and a directory that is none.
  for value in -DRILL_MAX_AGE_SECONDS DRILL_MAX_AGE_SECONDS= DRILL_MAX_AGE_SECONDS=marker DRILL_MAX_AGE_SECONDS=0 \
    DRILL_MAX_AGE_SECONDS=-5 DRILL_MAX_AGE_SECONDS=95400s DRILL_MAX_AGE_SECONDS=095400; do
    drill_check "$cases/fresh" "$value"
    echo "$value: $status [$output] [$stderr]"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ $stderr == *DRILL_MAX_AGE_SECONDS* ]]
  done
  for value in -DRILL_DIR DRILL_DIR= "DRILL_DIR=$cases/fresh/heartbeat" "DRILL_DIR=$cases/missing"; do
    drill_check "$cases/fresh" "$value"
    echo "$value: $status [$output] [$stderr]"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ $stderr == *DRILL_DIR* ]]
  done

  # It writes nothing.
  after="$(cd "$cases" && find . -printf '%p %y %s %m %T@\n' | sort)"
  [ "$after" = "$before" ]
  [ -z "$(ls -A "$work")" ]
  # It asks the clock for the seconds alone, which the stand-in refuses otherwise, and holds no
  # ${...}, which Flux would substitute.
  # shellcheck disable=SC2016 # the pattern is the characters themselves.
  run ! grep -F '${' "$BATS_TEST_TMPDIR/drill-scripts/check.sh" "$REPO/kubernetes/components/volsync-drill/scripts/check.sh"
}

@test "The demo's canary writes a heartbeat the drill's check accepts" {
  local dir="$BATS_TEST_TMPDIR/canary-volume" interval mount before after line stamp created pod container i
  local -a canary environment inodes heartbeats renames synced order
  built "$DEMO"
  container_argv Deployment "$DEMO" canary
  canary=("${ARGV[@]}")
  interval="$(env_value HEARTBEAT_SECONDS)"
  # The directory it writes is the volume's mount.
  mount="$(named Deployment "$DEMO" | jq -r '.spec.template.spec | (.volumes[] | select(.persistentVolumeClaim.claimName == "'"$DEMO"'") | .name) as $volume
    | .containers[] | select(.name == "canary") | .volumeMounts[] | select(.name == $volume) | .mountPath')"
  echo "the canary runs [${canary[*]}], every $interval seconds, in $(env_value CANARY_DIR), the mount of the volume at $mount"
  [ "$interval" = 300 ]
  [ "$(env_value CANARY_DIR)" = "$mount" ]
  mapfile -t environment < <(printf '%s\n' "${ENVIRONMENT[@]}" | grep -v '^CANARY_DIR=')
  environment+=("CANARY_DIR=$dir")
  mkdir -p "$dir"

  # One round, then the kubelet's TERM: it ends with status 0.
  stand_in canary sleep mv fsync canary/date
  echo "$dir" >"$RECORD/dir"
  before="$(date +%s)"
  run env -i PATH="$BIN:$PATH" "${environment[@]}" "${canary[@]}"
  after="$(date +%s)"
  echo "status $status: $output"
  [ "$status" -eq 0 ]
  # It sleeps the interval between rounds; at each, the directory holds created and the heartbeat and
  # nothing else, the heartbeat a new file renamed over the last, of one line: the Unix time in
  # seconds and the same moment as a UTC date and time.
  echo "slept: $(paste -sd' ' "$RECORD/sleep"); entries: $(paste -sd'|' "$RECORD/entries"); inodes: $(paste -sd' ' "$RECORD/inodes")"
  [ "$(cat "$RECORD/sleep")" = "$(printf '%s\n' "$interval" "$interval")" ]
  [ "$(cat "$RECORD/entries")" = "$(printf '%s\n' "created heartbeat" "created heartbeat")" ]
  mapfile -t inodes <"$RECORD/inodes"
  [ "${#inodes[@]}" -eq 2 ]
  [ "${inodes[0]}" != "${inodes[1]}" ]
  # Each round's file is renamed over the heartbeat from the same directory.
  echo "renamed: $(paste -sd'|' "$RECORD/mv")"
  [ "$(grep -c '' "$RECORD/mv")" -eq 2 ]
  while read -r from to; do
    [ "$(dirname "$from")" = "$dir" ]
    [ "$from" != "$dir/heartbeat" ]
    [ "$to" = "$dir/heartbeat" ]
  done <"$RECORD/mv"
  mapfile -t heartbeats <"$RECORD/heartbeats"
  echo "heartbeats: ${heartbeats[*]}"
  [ "${#heartbeats[@]}" -eq 2 ]
  for line in "${heartbeats[@]}"; do
    [[ $line =~ ^([0-9]+)\ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$ ]]
    stamp="${BASH_REMATCH[1]}"
    [ "${BASH_REMATCH[2]}" = "$(date -u -d "@$stamp" +%Y-%m-%dT%H:%M:%SZ)" ]
    [ "$stamp" -ge "$before" ]
    [ "$stamp" -le "$after" ]
  done
  [ "$(grep -c '' "$dir/heartbeat")" -eq 1 ]
  [ "$(cat "$dir/heartbeat")" = "${heartbeats[1]}" ]
  # Each round's file is written, synced whole to disk and only then renamed. A snapshot holds what
  # is on disk at its moment, and the kernel writes a file's data to disk later than its name, so a
  # snapshot can hold a file renamed before it was synced as an empty one; synced first, the
  # heartbeat in a snapshot is the last one or the new one, whole.
  mapfile -t renames <"$RECORD/mv"
  for i in "${!renames[@]}"; do
    order+=("fsync ${renames[$i]%% *}" "mv ${renames[$i]}")
  done
  echo "in order: $(paste -sd'|' "$RECORD/order")"
  [ "$(cat "$RECORD/order")" = "$(printf '%s\n' "${order[@]}")" ]
  mapfile -t synced <"$RECORD/fsync"
  echo "synced: $(paste -sd'|' "$RECORD/fsync")"
  [ "${#synced[@]}" -eq 2 ]
  for i in 0 1; do
    [ "${synced[$i]}" = "${renames[$i]%% *} ${heartbeats[$i]}" ]
  done
  # Each line is one date call's, so its two fields are one moment even across a tick of the clock:
  # three calls, for created and for the two rounds' heartbeats.
  echo "dated: $(paste -sd'|' "$RECORD/date")"
  [ "$(grep -c '' "$RECORD/date")" -eq 3 ]
  # created is written once: a run on a volume that holds one, as a restored volume does, keeps it,
  # content, inode and time alike.
  [[ $(cat "$dir/created") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  printf '2001-02-03T04:05:06Z\n' >"$dir/created"
  touch -d @981173106 "$dir/created"
  created="$(stat -c '%i %Y' "$dir/created") $(cat "$dir/created")"
  stand_in canary sleep fsync
  echo "$dir" >"$RECORD/dir"
  run env -i PATH="$BIN:$PATH" "${environment[@]}" "${canary[@]}"
  [ "$status" -eq 0 ]
  echo "created before the second run: $created; after: $(stat -c '%i %Y' "$dir/created") $(cat "$dir/created")"
  [ "$(stat -c '%i %Y' "$dir/created") $(cat "$dir/created")" = "$created" ]

  # The drill's check, run as its container runs it, passes on what it wrote.
  stand_in check
  drill_check "$dir"
  echo "the check: $status [$output] [$stderr]"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "${#lines[@]}" -eq 1 ]

  # The pod as before: the movers' user and group, the runtime's seccomp profile, no privilege
  # escalation, no capability, a read-only root, replaced by Recreate, and its requests.
  pod="$(named Deployment "$DEMO" | jq -c '.spec.template.spec')"
  container="$(jq -c '.containers[] | select(.name == "canary")' <<<"$pod")"
  [ "$(jq -r '.securityContext | [.runAsNonRoot, .runAsUser, .runAsGroup, .seccompProfile.type] | map(tostring) | join(" ")' <<<"$pod")" = \
    "true $(object ReplicationSource | jq -r '.spec.restic.moverSecurityContext | [.runAsUser, .runAsGroup] | map(tostring) | join(" ")') RuntimeDefault" ]
  [ "$(jq -c '.securityContext | [.allowPrivilegeEscalation, .readOnlyRootFilesystem, .capabilities]' <<<"$container")" = '[false,true,{"drop":["ALL"]}]' ]
  [ "$(named Deployment "$DEMO" | jq -r '.spec.strategy.type')" = Recreate ]
  [ "$(jq -c '.resources' <<<"$container")" = '{"requests":{"cpu":"1m","memory":"8Mi"}}' ]
}

@test "The drill's check job meets the restricted level, holds no token and only reads the scratch claim" {
  local cronjob job pod container tag image claim mount scripts policies selector labels ks app takers
  built "$DEMO"
  cronjob="$(named CronJob "$DEMO-drill-check")"
  job="$(jq -c '.spec.jobTemplate.spec' <<<"$cronjob")"
  pod="$(jq -c '.template.spec' <<<"$job")"
  echo "the CronJob: $cronjob"
  # Never two checks at once; one starts within 600 seconds of its time and ends within 600 more, is
  # tried once more after a failure, and its last success and last three failures are kept. No time
  # zone, as the tree's other CronJobs, and not suspended.
  [ "$(jq -r '.spec | [.concurrencyPolicy, .startingDeadlineSeconds, .successfulJobsHistoryLimit, .failedJobsHistoryLimit, (.timeZone // "none"), (.suspend // false)]
    | map(tostring) | join(" ")' <<<"$cronjob")" = "Forbid 600 1 3 none false" ]
  [ "$(jq -r '[.activeDeadlineSeconds, .backoffLimit, .template.spec.restartPolicy] | map(tostring) | join(" ")' <<<"$job")" = "600 1 Never" ]
  # No token, no service links, no toleration.
  [ "$(jq -r '[.automountServiceAccountToken, .enableServiceLinks, (.tolerations // [] | length)] | map(tostring) | join(" ")' <<<"$pod")" = "false false 0" ]
  # One container: the busybox the demo's Deployments pin, by that tag and a digest.
  [ "$(jq -r '(.initContainers // []) + .containers | length' <<<"$pod")" -eq 1 ]
  container="$(jq -c '.containers[0]' <<<"$pod")"
  tag="$(named Deployment "$DEMO" | jq -r '.spec.template.spec.containers[] | select(.name == "canary") | .image')"
  image="$(jq -r '.image' <<<"$container")"
  echo "the check's image: $image; the demo's: $tag and $(yq '.spec.template.spec.containers[0].image' "$TREE/kubernetes/apps/base/demo/hello/app/deployment.yaml")"
  [ "$tag" = "$(yq '.spec.template.spec.containers[0].image' "$TREE/kubernetes/apps/base/demo/hello/app/deployment.yaml")" ]
  [[ $tag == docker.io/library/busybox:* ]]
  [[ $image =~ ^"$tag"@sha256:[0-9a-f]{64}$ ]]
  # Non-root as the movers' user and group, with no fsGroup: the check changes nothing on the volume,
  # ownership included.
  [ "$(jq -cS '.securityContext' <<<"$pod")" = "$(object ReplicationSource | jq -cS '.spec.restic.moverSecurityContext
    | {runAsNonRoot, runAsUser, runAsGroup, seccompProfile}')" ]
  [ "$(jq -cS '.securityContext.seccompProfile' <<<"$pod")" = '{"type":"RuntimeDefault"}' ]
  [ "$(jq -cS '.securityContext | [.allowPrivilegeEscalation, .readOnlyRootFilesystem, .runAsNonRoot, .capabilities, (.privileged // false)]' <<<"$container")" = '[false,true,true,{"drop":["ALL"]},false]' ]
  [ -n "$(jq -r '.resources.requests.cpu // empty' <<<"$container")" ]
  [ -n "$(jq -r '.resources.requests.memory // empty' <<<"$container")" ]
  [ -n "$(jq -r '.resources.limits.memory // empty' <<<"$container")" ]
  # Its only volumes: the scratch claim, read-only at the container's mount and not at the pod's
  # volume, and the ConfigMap of its script, which its command names. It reads no Secret.
  [ "$(jq -c '[.volumes[] | del(.name) | keys[0]] | sort' <<<"$pod")" = '["configMap","persistentVolumeClaim"]' ]
  claim="$(jq -r '.volumes[] | select(.persistentVolumeClaim) | .name' <<<"$pod")"
  scripts="$(jq -r '.volumes[] | select(.configMap) | .name' <<<"$pod")"
  [ "$(jq -cS --arg v "$claim" '.volumes[] | select(.name == $v) | .persistentVolumeClaim' <<<"$pod")" = "{\"claimName\":\"$DEMO-drill\"}" ]
  [ "$(jq -r --arg v "$scripts" '.volumes[] | select(.name == $v) | .configMap.name' <<<"$pod")" = "$DEMO-drill-scripts" ]
  [ "$(jq -c '[.volumeMounts[].name] | sort' <<<"$container")" = "$(jq -nc --arg a "$claim" --arg b "$scripts" '[$a, $b] | sort')" ]
  [ "$(jq -r --arg v "$claim" '.volumeMounts[] | select(.name == $v) | .readOnly' <<<"$container")" = true ]
  [ "$(jq -r --arg v "$scripts" '.volumeMounts[] | select(.name == $v) | .readOnly' <<<"$container")" = true ]
  mount="$(jq -r --arg v "$claim" '.volumeMounts[] | select(.name == $v) | .mountPath' <<<"$container")"
  container_argv CronJob "$DEMO-drill-check" check
  [ "$(env_value DRILL_DIR)" = "$mount" ]
  [ "${ARGV[*]}" = "/bin/sh $(jq -r --arg v "$scripts" '.volumeMounts[] | select(.name == $v) | .mountPath' <<<"$container")/check.sh" ]
  [ "$(jq '[.. | objects | select(has("secretKeyRef") or has("secretRef") or has("secret") or has("projected"))] | length' <<<"$pod")" -eq 0 ]
  # Its pod template carries labels of its own, and none that a policy of the namespace's movers
  # selects, so it has none of the movers' flows.
  labels="$(jq -c '.template.metadata.labels // {}' <<<"$job")"
  echo "the check's pod labels: $labels"
  [ "$(jq 'length' <<<"$labels")" -gt 0 ]
  built demo-volsync-movers
  policies="$(yq -N -o json -I0 'select(.kind == "CiliumNetworkPolicy") | .spec.endpointSelector.matchLabels' "$BUILT")"
  [ -n "$policies" ]
  while IFS= read -r selector; do
    echo "a movers' policy selects: $selector"
    if selects "$selector" "$labels"; then
      echo "a policy of the namespace's movers selects the check's pod"
      return 1
    fi
  done <<<"$policies"
  # The user and group follow the application's.
  built "$DEMO" VOLSYNC_UID=2345 VOLSYNC_GID=3456
  [ "$(named CronJob "$DEMO-drill-check" | jq -c '.spec.jobTemplate.spec.template.spec.securityContext | [.runAsUser, .runAsGroup, .fsGroup]')" = '[2345,3456,null]' ]
  # A CronJob's name is at most 52 characters, so no application that takes the drill has an APP
  # longer than 40.
  takers=""
  while IFS= read -r ks; do
    if [ "$(yq '.spec.components // [] | map(select(test("/components/volsync-drill$"))) | length' "$ks")" -gt 0 ]; then
      app="$(yq '.spec.postBuild.substitute.APP // ""' "$ks")"
      takers+=" $app"
      [ -n "$app" ]
      [ "${#app}" -le 40 ]
    fi
  done < <(find "$TREE/kubernetes" -name ks.yaml)
  echo "APP of the applications that take the drill:$takers"
  [ -n "$takers" ]
}

@test "The drill's schedules follow the backup's and its largest age follows from them" {
  local backup restore check max interval starting active margin b r c failing ks var value app taken=""
  built "$DEMO"
  backup="$(object ReplicationSource | jq -r '.spec.trigger.schedule')"
  restore="$(named ReplicationDestination "$DEMO-drill" | jq -r '.spec.trigger.schedule')"
  check="$(named CronJob "$DEMO-drill-check" | jq -r '.spec.schedule')"
  starting="$(named CronJob "$DEMO-drill-check" | jq -r '.spec.startingDeadlineSeconds')"
  active="$(named CronJob "$DEMO-drill-check" | jq -r '.spec.jobTemplate.spec.activeDeadlineSeconds')"
  container_argv CronJob "$DEMO-drill-check" check
  max="$(env_value DRILL_MAX_AGE_SECONDS)"
  container_argv Deployment "$DEMO" canary
  interval="$(env_value HEARTBEAT_SECONDS)"
  echo "backup [$backup], restore [$restore], check [$check], largest age $max; heartbeat $interval, deadlines $starting and $active"
  [ "$backup" = "17 3 * * *" ]
  # Each runs once a day, the restore an hour after the backup and the check an hour after that.
  b="$(seconds_of_day "$backup")"
  r="$(seconds_of_day "$restore")"
  c="$(seconds_of_day "$check")"
  [ $(((r - b + 86400) % 86400)) -eq 3600 ]
  [ $(((c - r + 86400) % 86400)) -eq 3600 ]
  # Neither is at a minute of the day at which another application backs up or drills.
  while IFS= read -r ks; do
    app="$(yq '.metadata.name' "$ks")"
    [ "$app" != "$DEMO" ] || continue
    for var in VOLSYNC_SCHEDULE VOLSYNC_DRILL_RESTORE_SCHEDULE VOLSYNC_DRILL_CHECK_SCHEDULE; do
      value="$(VAR="$var" yq '.spec.postBuild.substitute[strenv(VAR)] // ""' "$ks")"
      [ -n "$value" ] || continue
      taken+=" $(seconds_of_day "$value")"
    done
  done < <(find "$TREE/kubernetes" -name ks.yaml)
  echo "other applications' backup and drill seconds of the day:$taken"
  [ -n "$taken" ]
  [[ " $taken " != *" $r "* && " $taken " != *" $c "* ]]
  # The largest age is the day between two backups, the time from the backup's schedule to the
  # check's, and a margin: the heartbeat's interval, as a snapshot's heartbeat is up to that much
  # older than the snapshot, the check's two deadlines, as a check can read the volume that late, and
  # 300 seconds for clocks, a slow write and a rename not yet on disk when the snapshot is taken.
  margin=$((interval + starting + active + 300))
  echo "margin $margin; 86400 + $(((c - b + 86400) % 86400)) + $margin = $((86400 + (c - b + 86400) % 86400 + margin))"
  [ "$max" -eq $((86400 + (c - b + 86400) % 86400 + margin)) ]
  # Which is the figure docs/kubernetes.md, The restore drill, works out.
  [ "$max" -eq 95400 ]
  # RestoreDrillJobFailing waits longer than a check can take from its schedule to its end.
  failing="$(yq '.spec.groups[].rules[] | select(.alert == "RestoreDrillJobFailing") | .for' \
    "$TREE/kubernetes/apps/base/volsync-system/volsync/app/prometheusrule.yaml")"
  echo "RestoreDrillJobFailing waits ${failing:-nothing}"
  [ "$(duration_seconds "$failing")" -gt $((starting + active)) ]
}

@test "every values key of volsync is one its pinned chart defines" {
  local keys="$BATS_TEST_TMPDIR/keys" unknown="" key map open
  local paths='[.. | select(path | length > 0) | path | select(all_c(tag == "!!str")) | join(".")] | .[]'
  render volsync
  mkdir -p "$keys"
  yq -N "$paths" "$VALUES" "$INLINE" | sort -u >"$keys/ours"
  helm show values "$CHART" >"$keys/defaults"
  yq -N "$paths" "$keys/defaults" | sort -u >"$keys/chart"
  # A map the chart leaves empty, such as affinity, takes keys of the user's choosing.
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
