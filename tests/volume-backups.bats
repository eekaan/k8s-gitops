#!/usr/bin/env bats
# Proves features/volume-backups.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq and jq on PATH (the versions pinned for the repository). The
# VolSync, External Secrets and LINSTOR applications' charts are pulled once per run from their
# public registries; building and rendering are offline.

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

# built APP [NAME=VALUE...]: the application APP as Flux applies it: its app/ built with its ks.yaml,
# its components included, substituting strictly the variables of the cluster's example key lists
# and the application's own postBuild.substitute over them, then each NAME=VALUE over both. Writes
# $BATS_TEST_TMPDIR/APP-built.yaml and sets BUILT, APP_DIR and VARS, the file of the variables.
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
    NAME="${pair%%=*}" VALUE="${pair#*=}" yq -i '.[strenv(NAME)] = strenv(VALUE)' "$VARS"
  done
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = $vars' "$VARS" "$TREE/$APP_DIR/ks.yaml" >"$ks"
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
    claim="$(object PersistentVolumeClaim)"
    source="$(object ReplicationSource)"
    destination="$(object ReplicationDestination)"
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
  local level privileged object context
  app_dir "$DEMO"
  level="$(yq '.metadata.labels["pod-security.kubernetes.io/enforce"]' "$TREE/${APP_DIR%/*}/namespace.yaml")"
  privileged="$(yq '.metadata.annotations["volsync.backube/privileged-movers"] // "false"' "$TREE/${APP_DIR%/*}/namespace.yaml")"
  echo "namespace ${APP_DIR%/*}: enforces $level, privileged movers: $privileged"
  [ "$level" = restricted ]
  [ "$privileged" = false ]
  built "$DEMO"
  for object in ReplicationSource ReplicationDestination; do
    context="$(object "$object" | jq -c '.spec.restic.moverSecurityContext // {}')"
    echo "$object mover: $context"
    [ "$(jq -r '.runAsNonRoot' <<<"$context")" = true ]
    [ "$(jq -r '.runAsUser // 0' <<<"$context")" -gt 0 ]
    [ "$(jq -r '.runAsGroup // 0' <<<"$context")" -gt 0 ]
    [ "$(jq -r '.fsGroup // 0' <<<"$context")" -gt 0 ]
    [ "$(jq -r '.seccompProfile.type' <<<"$context")" = RuntimeDefault ]
  done
  # The user and group come from the application.
  built "$DEMO" VOLSYNC_UID=2345 VOLSYNC_GID=3456
  context="$(object ReplicationSource | jq -c '.spec.restic.moverSecurityContext')"
  echo "with VOLSYNC_UID and VOLSYNC_GID set: $context"
  [ "$(jq -r '[.runAsUser, .runAsGroup, .fsGroup] | map(tostring) | join(" ")' <<<"$context")" = "2345 3456 3456" ]
}

@test "Every object the component makes is one the cluster's definitions accept" {
  local definitions app objects unknown="" line
  # The definitions the cluster's charts install: VolSync's and External Secrets'.
  definitions="$BATS_TEST_TMPDIR/definitions.yaml"
  for app in volsync external-secrets; do
    render "$app"
    yq 'select(.kind == "CustomResourceDefinition")' "$RENDERED" >>"$definitions"
    echo "---" >>"$definitions"
  done
  built "$DEMO"
  objects="$(yq -N -o json -I0 'select(.apiVersion | test("^(volsync\.backube|external-secrets\.io)/"))' "$BUILT")"
  echo "objects: $(jq -r '.kind' <<<"$objects" | paste -sd' ' -)"
  [ "$(jq -r '.kind' <<<"$objects" | sort | paste -sd' ' -)" = "ExternalSecret ReplicationDestination ReplicationSource" ]
  while IFS= read -r line; do
    unknown+="$(unknown_fields "$line" "$definitions")"$'\n'
  done <<<"$objects"
  echo "not accepted:${unknown//$'\n'/ }"
  [ -z "${unknown//$'\n'/}" ]
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
  # That recipe's own write is to the key, and no script but bao-put, whose key is its argument,
  # writes to the mount's data path otherwise: a script that wrote the key through variables would
  # show here.
  grep -qE "^volsync_key=$key\$" "$REPO/scripts/bao-seed-volsync"
  # shellcheck disable=SC2016 # the pattern names shell variables.
  grep -qE 'bao_request POST "\$bao_mount/data/\$volsync_key"' "$REPO/scripts/bao-seed-volsync"
  writers="$(grep -rlE 'bao_request (POST|PUT|PATCH) "[^"]*/data/' "$REPO/scripts" | sed "s#^$REPO/##" | sort | paste -sd' ' -)"
  echo "scripts that write under the mount's data path: ${writers:-none}"
  [ "$writers" = "scripts/bao-put scripts/bao-seed-volsync" ]
}

@test "The demo volume's backup and restore objects are in what Flux applies for the cluster" {
  local overlay enabled namespace opted dependencies name kinds
  overlay="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2" >"$overlay"
  enabled="$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "volsync") | .spec.path' "$overlay")"
  namespace="$(yq -N 'select(.kind == "Namespace" and .metadata.name == "volsync-system") | .metadata.name' "$overlay")"
  opted="$(yq -N 'select(.kind == "Kustomization" and (.spec.components // [] | any_c(test("components/volsync$"))))
    | .metadata.name' "$overlay")"
  echo "volsync: ${enabled:-not applied}; namespace: ${namespace:-none}; applications with the component: ${opted:-none}"
  [ "$enabled" = ./apps/base/volsync-system/volsync/app ]
  [ "$namespace" = volsync-system ]
  # The test application and n8n, which keeps its data on a volume of the component's, are the
  # applications that take it.
  [ "$(paste -sd' ' - <<<"$opted")" = "n8n $DEMO" ]
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
