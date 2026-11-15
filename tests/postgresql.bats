#!/usr/bin/env bats
# Proves features/postgresql.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq and jq on PATH (the versions pinned for the repository). The
# operator's chart is pulled once per run from its public registry; building and rendering are
# offline. flux build rewrites the kustomization.yaml of what it builds while it runs, so every
# build reads a copy of kubernetes/, never this checkout, and the applications that take a cluster
# from the component are written into that copy only.

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
  APP=cloudnative-pg
  NAMESPACE=cnpg-system
  APP_DIR="kubernetes/apps/base/$NAMESPACE/$APP"
  COMPONENT=kubernetes/components/cnpg-cluster
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# built NAMESPACE APP: the application as Flux applies it: its app/ built from the copy with its
# ks.yaml, substituting strictly the variables of the cluster's example key lists and the
# application's own postBuild.substitute over them, as scripts/kubernetes-check does. Writes
# $BATS_TEST_TMPDIR/APP-built.yaml and sets BUILT; a build that fails prints Flux's error and
# returns non-zero.
built() {
  local ns=$1 app=$2 vars="$BATS_TEST_TMPDIR/example-vars.yaml" ks="$BATS_TEST_TMPDIR/$2-ks.yaml"
  local error="$BATS_TEST_TMPDIR/$2-error.txt"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$vars"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' \
    "$vars" "$TREE/kubernetes/apps/base/$ns/$app/ks.yaml" >"$ks"
  BUILT="$BATS_TEST_TMPDIR/$app-built.yaml"
  # Built from the tree's parent, with paths from there, as scripts/kubernetes-check builds.
  (cd "$TREE" && flux build kustomization "$app" --path "./kubernetes/apps/base/$ns/$app/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute) >"$BUILT" 2>"$error" ||
    { cat "$error"; return 1; }
}

# render: renders the chart that the operator's HelmRelease installs, built as built() builds it,
# from the URL and tag of its OCIRepository, with the values helm-controller gives the chart: those
# of the ConfigMap the HelmRelease reads, then the HelmRelease's own over them. The PodMonitor,
# ServiceMonitor and Grafana dashboard APIs count as present, as group versions and as kinds, so
# that only the values keep such objects out. Leaves the application built in BUILT, writes
# $BATS_TEST_TMPDIR/rendered.yaml and sets RENDERED, CHART, VALUES and INLINE.
render() {
  local url tag name release namespace pulled
  built "$NAMESPACE" "$APP"
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  VALUES="$BATS_TEST_TMPDIR/values.yaml"
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\") | .data[\"values.yaml\"]" "$BUILT" >"$VALUES"
  [ -s "$VALUES" ] || { echo "no values in the ConfigMap $name the HelmRelease reads"; return 1; }
  INLINE="$BATS_TEST_TMPDIR/inline.yaml"
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$BUILT" >"$INLINE"
  pulled="$BATS_FILE_TMPDIR/charts/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  RENDERED="$BATS_TEST_TMPDIR/rendered.yaml"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" --include-crds \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/PodMonitor \
    --api-versions monitoring.coreos.com/v1/ServiceMonitor --api-versions grafana.integreatly.org/v1beta1 \
    --api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
    --values "$VALUES" --values "$INLINE" >"$RENDERED"
}

# database APP [NAME]: writes the application APP as database_app() does, then builds it as built()
# does, setting BUILT, and returns the build's status, printing Flux's error when it fails.
database() {
  database_app "$@"
  built demo "$1"
}

# database_app APP [NAME]: writes into the copy an application APP in the demo namespace that has no
# manifests of its own and takes a cluster from the component, with the ks.yaml docs/kubernetes.md
# gives for it, its cluster named NAME, or without a name when NAME is not given.
database_app() {
  local app=$1 name=${2:-} dir="$TREE/kubernetes/apps/base/demo/$1"
  mkdir -p "$dir/app"
  printf '%s\n' '---' 'apiVersion: kustomize.config.k8s.io/v1beta1' 'kind: Kustomization' 'resources: []' \
    >"$dir/app/kustomization.yaml"
  # shellcheck disable=SC2016 # $app is a yq variable.
  APP_NAME="$app" yq -n 'strenv(APP_NAME) as $app | {"apiVersion": "kustomize.toolkit.fluxcd.io/v1",
    "kind": "Kustomization", "metadata": {"name": $app, "namespace": "flux-system"},
    "spec": {"path": "./apps/base/demo/" + $app + "/app", "targetNamespace": "demo",
      "dependsOn": [{"name": "cloudnative-pg"}, {"name": "prometheus-operator-crds"}],
      "components": ["../../../../../components/cnpg-cluster"],
      "sourceRef": {"kind": "ExternalArtifact", "name": $app}}}' >"$dir/ks.yaml"
  if [ -n "$name" ]; then
    NAME="$name" yq -i '.spec.postBuild.substitute.CNPG_CLUSTER_NAME = strenv(NAME)' "$dir/ks.yaml"
  fi
}

# resize APP TARGET: adds to the kustomization.yaml of APP's app/ a patch, with the target TARGET (a
# YAML map), that gives each instance 1Gi of memory, requested and as its limit.
resize() {
  TARGET="$2" yq -i '.patches = [{"target": (strenv(TARGET) | from_yaml), "patch": "- op: replace
  path: /spec/resources/requests/memory
  value: 1Gi
- op: replace
  path: /spec/resources/limits/memory
  value: 1Gi
"}]' "$TREE/kubernetes/apps/base/demo/$1/app/kustomization.yaml"
}

# pin FILE KEY: the comment line above the first line of FILE whose key is KEY, then that line's
# value, each on a line of its own.
pin() {
  awk -v key="$2:" '$1 == key { print prev; print $2; exit } { prev = $0 }' "$1"
}

@test "The PostgreSQL operator is installed with its resource definitions" {
  local overlay enabled namespace deployments elsewhere crds definition
  # The cluster runs it: its overlay applies the namespace directory and the application's
  # Kustomization.
  overlay="$(kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2")"
  enabled="$(yq -N "select(.kind == \"Kustomization\" and .metadata.name == \"$APP\") | .spec.path" <<<"$overlay")"
  namespace="$(yq -N "select(.kind == \"Namespace\" and .metadata.name == \"$NAMESPACE\") | .metadata.name" <<<"$overlay")"
  echo "$APP in the overlay: ${enabled:-none}; namespace: ${namespace:-none}"
  [ "$enabled" = "./apps/base/$NAMESPACE/$APP/app" ]
  [ "$namespace" = "$NAMESPACE" ]
  render
  echo "renders: $(yq -N 'select(. != null) | .kind' "$RENDERED" | sort | uniq -c | xargs)"
  deployments="$(yq -N 'select(.kind == "Deployment") | .metadata.namespace + "/" + .metadata.name' "$RENDERED")"
  echo "deployments: $deployments"
  [ "$deployments" = "$NAMESPACE/$APP" ]
  elsewhere="$(yq -N "select(. != null and .metadata.namespace != null and .metadata.namespace != \"$NAMESPACE\")
    | .kind + \"/\" + .metadata.name + \" in \" + .metadata.namespace" "$RENDERED")"
  echo "in another namespace: ${elsewhere:-none}"
  [ -z "$elsewhere" ]
  # Deleting a definition deletes every object of its kind, and with each Cluster its volumes, so
  # Helm keeps each one when the release is uninstalled, as it is when the application leaves the
  # tree; the application applies none itself, so pruning what it applies deletes none either.
  crds="$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name + " "
    + (.metadata.annotations["helm.sh/resource-policy"] // "none")' "$RENDERED")"
  echo "$crds"
  for definition in clusters databases poolers backups scheduledbackups; do
    grep -qx "$definition.postgresql.cnpg.io keep" <<<"$crds" || { echo "no kept definition $definition.postgresql.cnpg.io"; return 1; }
  done
  [ "$(grep -vc ' keep$' <<<"$crds")" -eq 0 ]
  echo "the application applies: $(yq -N 'select(. != null) | .kind' "$BUILT" | sort | paste -sd' ' -)"
  [ -z "$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$BUILT")" ]
}

@test "The PostgreSQL operator keeps reconciling and admitting while a node is drained" {
  local deployment labels replicas args spread objects budgets count min max
  render
  deployment="$BATS_TEST_TMPDIR/deployment.yaml"
  yq -N 'select(.kind == "Deployment")' "$RENDERED" >"$deployment"
  labels="$(yq -o json -I0 '.spec.template.metadata.labels // {}' "$deployment")"
  replicas="$(yq '.spec.replicas // 1' "$deployment")"
  args="$(yq '.spec.template.spec.containers[] | select(.name == "manager") | .args // [] | .[]' "$deployment")"
  # Constraints that put no two of the operator's pods on one node.
  # shellcheck disable=SC2016 # $labels is a yq variable.
  spread="$(LABELS="$labels" yq -N '(strenv(LABELS) | from_yaml) as $labels
    | [.spec.template.spec.topologySpreadConstraints // [] | .[]
      | select(.topologyKey == "kubernetes.io/hostname" and .whenUnsatisfiable == "DoNotSchedule" and .maxSkew == 1
        and (.labelSelector.matchLabels // {} | length) > 0
        and (.labelSelector.matchLabels | to_entries | all_c(.value == $labels[.key])))] | length' "$deployment")"
  echo "replicas $replicas; spread constraints $spread; arguments: $(paste -sd' ' - <<<"$args")"
  [ "$replicas" -eq 2 ]
  [ "$spread" -ge 1 ]
  # Of the two, only the leader reconciles.
  grep -qx -- '--leader-elect' <<<"$args"
  # The disruption budgets that select the operator's pods, from the chart or from the
  # application's own objects.
  objects="$BATS_TEST_TMPDIR/objects.yaml"
  { cat "$RENDERED"; echo ---; cat "$BUILT"; } >"$objects"
  # shellcheck disable=SC2016 # $labels is a yq variable.
  budgets="$(LABELS="$labels" yq -N '(strenv(LABELS) | from_yaml) as $labels | select(.kind == "PodDisruptionBudget"
    and (.spec.selector.matchLabels // {} | length) > 0
    and (.spec.selector.matchLabels | to_entries | all_c(.value == $labels[.key])))
    | (.spec.minAvailable // "unset" | tostring) + " " + (.spec.maxUnavailable // "unset" | tostring)' "$objects")"
  echo "budgets (minAvailable maxUnavailable): ${budgets:-none}"
  count="$(grep -c . <<<"$budgets" || true)"
  [ "$count" -eq 1 ]
  read -r min max <<<"$budgets"
  # One pod stays running and one may be evicted; a budget in percent is not read here.
  if [[ $min =~ ^[0-9]+$ ]]; then
    ((min >= 1 && min < replicas))
  elif [[ $max =~ ^[0-9]+$ ]]; then
    ((max >= 1 && max < replicas))
  else
    echo "the budget sets neither minAvailable nor maxUnavailable as a number"
    return 1
  fi
}

@test "The PostgreSQL operator is scraped through its PodMonitor" {
  local depends wait targets dashboards
  # The PodMonitor kind exists once prometheus-operator-crds is Ready; an application that takes a
  # cluster from the component waits for this one, which is Ready only once the operator runs.
  depends="$(yq '.spec.dependsOn // [] | .[].name' "$TREE/$APP_DIR/ks.yaml")"
  wait="$(yq '.spec.wait' "$TREE/$APP_DIR/ks.yaml")"
  echo "depends on: ${depends:-nothing}; wait: $wait"
  grep -qx prometheus-operator-crds <<<"$depends"
  [ "$wait" = true ]
  render
  # Each PodMonitor with the workloads whose pod labels its selector matches and whose containers
  # name every port it scrapes.
  targets="$(yq -N -o json -I0 'select(. != null)' "$RENDERED" | jq -rs '. as $all | .[]
    | select(.kind == "ServiceMonitor" or .kind == "PodMonitor") | . as $monitor
    | ($monitor.spec.selector.matchLabels // {}) as $selector
    | [($monitor.spec.podMetricsEndpoints // $monitor.spec.endpoints // [])[].port] as $ports
    | [$all[] | select($monitor.kind == "PodMonitor" and .kind == "Deployment")
      | select(.spec.template.metadata.labels as $labels | ($selector | length > 0)
          and ($selector | to_entries | all($labels[.key] == .value)))
      | select([.spec.template.spec.containers[].ports[]?.name] as $named
          | ($ports | length > 0) and ($ports | all(. as $port | any($named[]; . == $port))))
      | .kind + "/" + .metadata.name] as $workloads
    | "\($monitor.kind)/\($monitor.metadata.name) -> \(if ($workloads | length) > 0 then $workloads | join(" ") else "none" end)"')"
  echo "monitors: ${targets:-none}"
  [ "$targets" = "PodMonitor/$APP -> Deployment/$APP" ]
  dashboards="$(yq -N 'select(. != null) | select(.kind == "GrafanaDashboard"
    or (.kind == "ConfigMap" and (.metadata.labels // {} | has("grafana_dashboard"))))
    | .kind + "/" + .metadata.name' "$RENDERED")"
  echo "dashboards: ${dashboards:-none}"
  [ -z "$dashboards" ]
}

@test "The PostgreSQL operator meets the restricted Pod Security level its namespace enforces" {
  local level pods containers line
  level="$(yq -N 'select(.kind == "Namespace") | .metadata.labels["pod-security.kubernetes.io/enforce"] // "none"' \
    "$TREE/kubernetes/apps/base/$NAMESPACE/namespace.yaml")"
  echo "the namespace enforces: $level"
  [ "$level" = restricted ]
  render
  # The checks of the restricted level that a pod template can show. A pod template that sets no
  # user leaves the image's, which must not be root; runAsNonRoot makes the kubelet refuse root.
  # shellcheck disable=SC2016 # $p is a yq variable.
  pods="$(yq -N 'select(.kind == "Deployment") | .spec.template.spec as $p
    | .metadata.name + " hostNamespaces=" + ([$p.hostNetwork, $p.hostPID, $p.hostIPC] | map(select(. == true)) | length | tostring)
      + " volumes=" + ([$p.volumes // [] | .[] | keys | .[] | select(. != "name")] | unique | join(","))' "$RENDERED")"
  echo "$pods"
  [ -n "$pods" ]
  while read -r line; do
    [[ $line =~ \ hostNamespaces=0\ volumes=((configMap|csi|downwardAPI|emptyDir|ephemeral|persistentVolumeClaim|projected|secret)(,|$))*$ ]] ||
      { echo "not restricted: $line"; return 1; }
  done <<<"$pods"
  # shellcheck disable=SC2016 # $d, $p and $c are yq variables.
  containers="$(yq -N 'select(.kind == "Deployment") | .metadata.name as $d | .spec.template.spec as $p
    | (($p.initContainers // []) + $p.containers)[] as $c
    | $d + "/" + $c.name
      + " privileged=" + ($c.securityContext.privileged // false | tostring)
      + " allowPrivilegeEscalation=" + ($c.securityContext.allowPrivilegeEscalation | tostring)
      + " runAsNonRoot=" + ($c.securityContext.runAsNonRoot // $p.securityContext.runAsNonRoot // false | tostring)
      + " runAsUser=" + ($c.securityContext.runAsUser // $p.securityContext.runAsUser // "unset" | tostring)
      + " seccomp=" + ($c.securityContext.seccompProfile.type // $p.securityContext.seccompProfile.type // "unset")
      + " drop=" + ($c.securityContext.capabilities.drop // [] | join(","))
      + " add=" + ($c.securityContext.capabilities.add // [] | map(select(. != "NET_BIND_SERVICE")) | join(","))
      + " hostPorts=" + ([$c.ports // [] | .[] | select((.hostPort // 0) != 0)] | length | tostring)' "$RENDERED")"
  echo "$containers"
  [ -n "$containers" ]
  while read -r line; do
    [[ $line =~ \ privileged=false\ allowPrivilegeEscalation=false\ runAsNonRoot=true\ runAsUser=([1-9][0-9]*|unset)\ seccomp=(RuntimeDefault|Localhost)\ drop=([^ ]*,)?ALL(,[^ ]*)?\ add=\ hostPorts=0$ ]] ||
      { echo "not restricted: $line"; return 1; }
  done <<<"$containers"
}

@test "The operator chart and the PostgreSQL image are pinned where Renovate updates them" {
  local -a chart image
  local url repository
  # The repository's custom manager reads the version on the line under a
  # '# renovate: datasource=… depName=…' comment, in any YAML file under kubernetes/.
  mapfile -t chart < <(pin "$TREE/$APP_DIR/app/ocirepository.yaml" tag)
  url="$(yq '.spec.url' "$TREE/$APP_DIR/app/ocirepository.yaml")"
  echo "chart: $url, ${chart[1]:-no tag} under '${chart[0]:-nothing}'"
  [[ ${chart[0]:-} =~ ^\ *#\ renovate:\ datasource=docker\ depName=([^ ]+)$ ]]
  [ "${BASH_REMATCH[1]}" = "${url#oci://}" ]
  [[ ${chart[1]:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  mapfile -t image < <(pin "$TREE/$COMPONENT/cluster.yaml" imageName)
  repository="${image[1]%:*}"
  echo "image: ${image[1]:-none} under '${image[0]:-nothing}'"
  [[ ${image[0]:-} =~ ^\ *#\ renovate:\ datasource=docker\ depName=([^ ]+)$ ]]
  [ "${BASH_REMATCH[1]}" = "$repository" ]
  # A tag that names the PostgreSQL minor version, so the next minor arrives only by a change here.
  # The publisher rebuilds the image under the same tag, so it is not an exact image.
  [[ ${image[1]#"$repository":} =~ ^[0-9]+\.[0-9]+(-[a-z0-9]+)*$ ]]
}

@test "An application gets a three-instance PostgreSQL cluster from the component" {
  local clusters spec monitors selector ports backups
  database orders orders-db
  echo "builds: $(yq -N 'select(. != null) | .kind + "/" + .metadata.name' "$BUILT" | paste -sd' ' -)"
  clusters="$(yq -N 'select(.kind == "Cluster" and .apiVersion == "postgresql.cnpg.io/v1")
    | .metadata.namespace + "/" + .metadata.name' "$BUILT")"
  echo "clusters: ${clusters:-none}"
  [ "$clusters" = demo/orders-db ]
  # The operator's defaults where the Cluster leaves a field out: anti-affinity on, by node name, and
  # disruption budgets on. The image comes from the Cluster, with a tag that names the minor version.
  spec="$(yq -N 'select(.kind == "Cluster") | .spec | "instances=" + (.instances | tostring)
    + " antiAffinity=" + (.affinity.enablePodAntiAffinity // true | tostring)
    + " type=" + (.affinity.podAntiAffinityType // "preferred")
    + " topologyKey=" + (.affinity.topologyKey // "kubernetes.io/hostname")
    + " pdb=" + (.enablePDB // true | tostring)
    + " catalog=" + (.imageCatalogRef != null | tostring)
    + " image=" + (.imageName // "none")' "$BUILT")"
  echo "$spec"
  [[ $spec =~ ^instances=3\ antiAffinity=true\ type=required\ topologyKey=kubernetes\.io/hostname\ pdb=true\ catalog=false\ image=[^:]+:[0-9]+\.[0-9]+(-[a-z0-9]+)*$ ]]
  # None of the operator's own backup objects: the component's dump job copies the database out instead
  # (tests/postgres-dumps.bats), as the operator's plugin offers server-side encryption only.
  backups="$(yq -N 'select(. != null) | select(.kind == "Backup" or .kind == "ScheduledBackup" or .kind == "ObjectStore"
      or (.kind == "Cluster" and (.spec.backup != null or (.spec.plugins // [] | length) > 0)))
    | .kind + "/" + .metadata.name' "$BUILT")"
  echo "backup configuration: ${backups:-none}"
  [ -z "$backups" ]
  # The operator labels an instance's pods with its Cluster's name and their role, and names the
  # port its exporter serves on metrics.
  monitors="$(yq -N 'select(.kind == "PodMonitor") | .metadata.namespace + "/" + .metadata.name' "$BUILT")"
  selector="$(yq -N -o json -I0 'select(.kind == "PodMonitor") | .spec.selector.matchLabels // {}' "$BUILT")"
  ports="$(yq -N 'select(.kind == "PodMonitor") | .spec.podMetricsEndpoints // [] | map(.port) | join(",")' "$BUILT")"
  echo "monitors: ${monitors:-none}; selector: $selector; ports: $ports"
  [ "$(grep -c . <<<"$monitors")" -eq 1 ]
  [[ $monitors == demo/* ]]
  [[ $selector == '{"cnpg.io/cluster":"orders-db"}' || $selector == '{"cnpg.io/cluster":"orders-db","cnpg.io/podRole":"instance"}' ]]
  [ "$ports" = metrics ]
}

@test "Each PostgreSQL instance keeps its data once, on its own node" {
  local class wal classes
  database orders orders-db
  class="$(yq -N 'select(.kind == "Cluster") | .spec.storage.storageClass // "default"' "$BUILT")"
  wal="$(yq -N 'select(.kind == "Cluster") | .spec.walStorage.storageClass // "none"' "$BUILT")"
  echo "data on: $class; WAL on its own volume: $wal"
  [ "$wal" = none ] || [ "$wal" = "$class" ]
  built piraeus-datastore linstor-cluster
  classes="$(yq -N 'select(.kind == "StorageClass") | .metadata.name + " default=" + (.metadata.annotations["storageclass.kubernetes.io/is-default-class"] // "false")
    + " provisioner=" + .provisioner + " binding=" + (.volumeBindingMode // "Immediate")
    + " placementCount=" + (.parameters["linstor.csi.linbit.com/placementCount"] // "unset")
    + " layers=" + (.parameters["linstor.csi.linbit.com/layerList"] // "unset")
    + " remoteAccess=" + (.parameters["linstor.csi.linbit.com/allowRemoteVolumeAccess"] // "unset")' "$BUILT")"
  echo "$classes"
  grep -qx "$class default=false provisioner=linstor.csi.linbit.com binding=WaitForFirstConsumer placementCount=1 layers=storage remoteAccess=false" <<<"$classes"
}

@test "Every field of the component's Cluster is one the pinned operator defines" {
  local schema cluster problems
  render
  schema="$BATS_TEST_TMPDIR/cluster-schema.json"
  yq -N -o json 'select(.kind == "CustomResourceDefinition" and .metadata.name == "clusters.postgresql.cnpg.io")
    | .spec.versions[] | select(.name == "v1") | .schema.openAPIV3Schema' "$RENDERED" >"$schema"
  [ -s "$schema" ]
  database orders orders-db
  cluster="$BATS_TEST_TMPDIR/cluster.json"
  yq -N -o json 'select(.kind == "Cluster")' "$BUILT" >"$cluster"
  [ -s "$cluster" ]
  # Each value's place in the schema: a property, an array's items, a map's additionalProperties,
  # or anything at all below a field that keeps unknown fields. Metadata is the API server's. Every
  # path counts, those of maps and lists and of false and null values included: paths(scalars)
  # would drop the last two, and an empty map or list has no path below it.
  problems="$(jq -r --slurpfile schema "$schema" '
    def node($s; $p): reduce $p[] as $k ($s;
      if . == null or .["x-any"] then .
      elif ($k | type) == "number" then .items
      elif ((.properties // {}) | has($k)) then .properties[$k]
      elif (.additionalProperties | type) == "object" then .additionalProperties
      elif .["x-kubernetes-preserve-unknown-fields"] then {"x-any": true}
      else null end);
    def types($n): if $n["x-kubernetes-int-or-string"] then ["integer", "string"]
      elif $n.type then [$n.type] else [($n.anyOf // [])[].type | select(. != null)] end;
    def kind: if type == "number" then (if . == floor then "integer" else "number" end) else type end;
    def shown: if type == "object" then "a map" elif type == "array" then "a list" else tojson end;
    . as $doc | $schema[0] as $s
    | paths as $p | select($p[0] != "apiVersion" and $p[0] != "kind" and $p[0] != "metadata")
    | ($doc | getpath($p)) as $v | node($s; $p) as $n | ($p | map(tostring) | join(".")) as $at
    | if $n == null then "\($at): not in the definition"
      elif $n["x-any"] then empty
      elif (types($n) | length) > 0 and (any(types($n)[]; . == ($v | kind) or (. == "number" and ($v | kind) == "integer")) | not)
        then "\($at): \($v | shown) is not of type \(types($n) | join(" or "))"
      elif ($v | type) != "object" and ($v | type) != "array" and $n.enum != null and (any($n.enum[]; . == $v) | not)
        then "\($at): \($v | tojson) is not one of \($n.enum | tojson)"
      else empty end' "$cluster")"
  echo "fields: $(jq -r '[paths | select(.[0] == "spec") | map(tostring) | join(".")] | join(" ")' "$cluster")"
  echo "problems: ${problems:-none}"
  [ -z "$problems" ]
}

@test "An application changes its cluster with a patch that targets the Cluster by kind" {
  local by_kind by_name
  local fields='.metadata.name + " instances=" + (.spec.instances | tostring)
    + " class=" + .spec.storage.storageClass + " requests=" + .spec.resources.requests.memory
    + " limits=" + .spec.resources.limits.memory'
  # The application's own patches apply after the component, to the Cluster the component made.
  database_app resized resized-db
  resize resized '{kind: Cluster}'
  built demo resized
  by_kind="$(yq -N "select(.kind == \"Cluster\") | $fields" "$BUILT")"
  # Flux substitutes after the build, so when the patches apply the Cluster is still named
  # ${CNPG_CLUSTER_NAME}; a target by the name the application gives it matches nothing, and
  # kustomize skips the patch without an error.
  database_app misnamed misnamed-db
  resize misnamed '{kind: Cluster, name: misnamed-db}'
  built demo misnamed
  by_name="$(yq -N "select(.kind == \"Cluster\") | $fields" "$BUILT")"
  echo "patched by kind: $by_kind"
  echo "patched by name: $by_name"
  [ "$by_kind" = "resized-db instances=3 class=linstor-node-local requests=1Gi limits=1Gi" ]
  [ "$by_name" = "misnamed-db instances=3 class=linstor-node-local requests=512Mi limits=512Mi" ]
}

@test "An application must name the cluster it takes from the component" {
  run database unnamed
  echo "$output"
  [ "$status" -ne 0 ]
  grep -q 'variable not set (strict mode): "CNPG_CLUSTER_NAME"' <<<"$output"
}

@test "every values key of cloudnative-pg is one its pinned chart defines" {
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
