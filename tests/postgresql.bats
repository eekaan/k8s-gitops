#!/usr/bin/env bats
# Proves features/postgresql.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq and jq on PATH (the versions pinned for the repository), and the
# system's openssl, which makes the certificates of the plugin's handshake and runs it. The
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
  # KEY=VALUE pairs that built() puts over the example's cluster-config.
  SET=()
}

# built NAMESPACE APP: the application as Flux applies it: its app/ built from the copy with its
# ks.yaml, substituting strictly the variables of the cluster's example key lists and the
# application's own postBuild.substitute over them, as scripts/kubernetes-check does. Writes
# $BATS_TEST_TMPDIR/APP-built.yaml and sets BUILT; a build that fails prints Flux's error and
# returns non-zero. The pairs of SET go over the cluster-config values first.
built() {
  local ns=$1 app=$2 vars="$BATS_TEST_TMPDIR/example-vars.yaml" ks="$BATS_TEST_TMPDIR/$2-ks.yaml" pair
  local error="$BATS_TEST_TMPDIR/$2-error.txt"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$vars"
  for pair in "${SET[@]}"; do
    # shellcheck disable=SC2016 # $key is a yq variable.
    KEY="${pair%%=*}" VALUE="${pair#*=}" yq -i '.[strenv(KEY)] = strenv(VALUE)' "$vars"
  done
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
  pulled="$BATS_FILE_TMPDIR/charts/${url##*/}-$tag"
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

# database APP [NAME [NAMESPACE]]: writes the application APP as database_app() does, then builds it
# as built() does, setting BUILT, and returns the build's status, printing Flux's error when it fails.
database() {
  database_app "$@"
  built demo "$1"
}

# database_app APP [NAME [NAMESPACE]]: writes into the copy an application APP that has no manifests
# of its own and takes a cluster from the component, with the ks.yaml docs/kubernetes.md gives for
# it, its cluster named NAME, or without a name when NAME is not given, in the namespace NAMESPACE,
# demo when it is not given. The application's files are always under demo/, which is only where
# the copy keeps them.
database_app() {
  local app=$1 name=${2:-} namespace=${3:-demo} dir="$TREE/kubernetes/apps/base/demo/$1"
  mkdir -p "$dir/app"
  printf '%s\n' '---' 'apiVersion: kustomize.config.k8s.io/v1beta1' 'kind: Kustomization' 'resources: []' \
    >"$dir/app/kustomization.yaml"
  # shellcheck disable=SC2016 # $app and $namespace are yq variables.
  APP_NAME="$app" NAMESPACE_NAME="$namespace" yq -n 'strenv(APP_NAME) as $app | strenv(NAMESPACE_NAME) as $namespace
    | {"apiVersion": "kustomize.toolkit.fluxcd.io/v1",
    "kind": "Kustomization", "metadata": {"name": $app, "namespace": "flux-system"},
    "spec": {"path": "./apps/base/demo/" + $app + "/app", "targetNamespace": $namespace,
      "dependsOn": [{"name": "cloudnative-pg"}, {"name": "plugin-barman-cloud"}, {"name": "prometheus-operator-crds"},
        {"name": "external-secrets"}, {"name": "openbao-store"}],
      "components": ["../../../../../components/cnpg-cluster"],
      "postBuild": {"substitute": {"CNPG_NAMESPACE": $namespace}},
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

# schema_problems SCHEMA DOCUMENT: what is wrong with the JSON DOCUMENT against the JSON schema file
# SCHEMA, one line each: a field the schema does not define, a value of another type than its field's
# or outside its enum. Each value's place in the schema: a property, an array's items, a map's
# additionalProperties, or anything at all below a field that keeps unknown fields. Metadata is the
# API server's. Every path counts, those of maps and lists and of false and null values included:
# paths(scalars) would drop the last two, and an empty map or list has no path below it.
schema_problems() {
  jq -r --slurpfile schema "$1" '
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
      else empty end' "$2"
}

# assert_restricted: every Deployment of $RENDERED meets the checks of the restricted Pod Security
# level that a pod template can show, and fails with the line of the first that does not.
assert_restricted() {
  local pods containers line
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

# assert_values_keys: every key the repository's values for the chart of $APP set is one that chart
# defines, so a key the chart renamed or dropped fails here and is not ignored by Helm.
assert_values_keys() {
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
  local level
  level="$(yq -N 'select(.kind == "Namespace") | .metadata.labels["pod-security.kubernetes.io/enforce"] // "none"' \
    "$TREE/kubernetes/apps/base/$NAMESPACE/namespace.yaml")"
  echo "the namespace enforces: $level"
  [ "$level" = restricted ]
  render
  assert_restricted
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
  local clusters spec monitors selector ports labels
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
  # The operator labels an instance's pods with its Cluster's name and their role, and names the
  # port its exporter serves on metrics.
  monitors="$(yq -N 'select(.kind == "PodMonitor") | .metadata.namespace + "/" + .metadata.name' "$BUILT")"
  selector="$(yq -N -o json -I0 'select(.kind == "PodMonitor") | .spec.selector.matchLabels // {}' "$BUILT")"
  ports="$(yq -N 'select(.kind == "PodMonitor") | .spec.podMetricsEndpoints // [] | map(.port) | join(",")' "$BUILT")"
  # Its series carry the Cluster's name as the label cnpg_io_cluster, which the alerts group by.
  labels="$(yq -N 'select(.kind == "PodMonitor") | .spec.podTargetLabels // [] | join(",")' "$BUILT")"
  echo "monitors: ${monitors:-none}; selector: $selector; ports: $ports; labels: $labels"
  [ "$labels" = cnpg.io/cluster ]
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
  problems="$(schema_problems "$schema" "$cluster")"
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
  assert_values_keys
}

@test "every values key of plugin-barman-cloud is one its pinned chart defines" {
  APP="plugin-barman-cloud"
  assert_values_keys
}

# The applications of the lab-sto2 overlay that take a cluster from the component, each as its
# namespace directory and its name, which is also where its ks.yaml is: the tests that read the
# overlay's own databases read these, and one of them holds the list to the overlay.
DATABASE_APPS=(ai-system/n8n backstage/backstage)

# archive_path FILE: where the Cluster in the built objects FILE archives to: the destinationPath of
# the ObjectStore its archiver plugin entry names, and under it the server name that entry gives,
# which is the directory the plugin keeps the archive in.
archive_path() {
  local store server
  store="$(yq -N 'select(.kind == "Cluster") | .spec.plugins[] | select(.isWALArchiver == true) | .parameters.barmanObjectName' "$1")"
  server="$(yq -N 'select(.kind == "Cluster") | .spec.plugins[] | select(.isWALArchiver == true) | .parameters.serverName' "$1")"
  echo "$(STORE="$store" yq -N 'select(.kind == "ObjectStore" and .metadata.name == strenv(STORE)) | .spec.configuration.destinationPath' "$1")/$server"
}

@test "A PostgreSQL cluster from the component archives its WAL and takes a daily base backup to a path of its own in the object store" {
  local plugins stores backups schedule minute hour taken retention compression endpoint vars dump_schedule dump_start
  local dump_end deadline app
  vars="$BATS_TEST_TMPDIR/example-vars.yaml"
  database orders orders-db
  # The Cluster archives its WAL through the plugin, to the ObjectStore of its own name, in a
  # directory of its own name, and the operator's deprecated in-tree object store is not used.
  plugins="$(yq -N 'select(.kind == "Cluster") | .spec.plugins // [] | map(.name + " archiver=" + (.isWALArchiver | tostring)
    + " store=" + .parameters.barmanObjectName + " server=" + .parameters.serverName) | join(",")' "$BUILT")"
  echo "plugins: ${plugins:-none}"
  [ "$plugins" = "barman-cloud.cloudnative-pg.io archiver=true store=orders-db server=orders-db" ]
  [ "$(yq -N 'select(.kind == "Cluster") | .spec.backup.barmanObjectStore // "none"' "$BUILT")" = none ]
  stores="$(yq -N 'select(.kind == "ObjectStore") | .apiVersion + " " + .metadata.namespace + "/" + .metadata.name' "$BUILT")"
  echo "object stores: ${stores:-none}"
  [ "$stores" = "barmancloud.cnpg.io/v1 demo/orders-db" ]
  # One base backup a day, taken through the plugin, the first as soon as the schedule exists.
  backups="$(yq -N 'select(.kind == "ScheduledBackup") | .metadata.namespace + "/" + .metadata.name + " cluster=" + .spec.cluster.name
    + " method=" + .spec.method + " plugin=" + .spec.pluginConfiguration.name + " immediate=" + (.spec.immediate | tostring)
    + " owner=" + .spec.backupOwnerReference' "$BUILT")"
  echo "scheduled backups: ${backups:-none}"
  [ "$backups" = "demo/orders-db cluster=orders-db method=plugin plugin=barman-cloud.cloudnative-pg.io immediate=true owner=self" ]
  [ "$(yq -N 'select(.kind == "ScheduledBackup") | .spec.suspend // false' "$BUILT")" = false ]
  schedule="$(yq -N 'select(.kind == "ScheduledBackup") | .spec.schedule' "$BUILT")"
  echo "schedule: $schedule"
  # Six fields, seconds first: second 0 of one minute of one hour, every day.
  [[ $schedule =~ ^0\ ([0-9]|[1-5][0-9])\ ([0-9]|1[0-9]|2[0-3])\ \*\ \*\ \*$ ]]
  minute=${BASH_REMATCH[1]}
  hour=${BASH_REMATCH[2]}
  # Not on a minute that people and cron jobs favour, nor one that another backup of the cluster's
  # applications or of the component starts at, so the copies do not all read the same disks and
  # write to the same bucket together.
  taken="$(grep -rhE '^[[:space:]]*(VOLSYNC_SCHEDULE: |schedule: )"?[0-9*/,]+ [0-9*/,]+' "$REPO/kubernetes/apps" "$REPO/kubernetes/components" \
    --exclude=scheduledbackup.yaml | sed -E 's/^[^"0-9*]*"?([0-9*/,]+) ([0-9*/,]+).*/\1:\2/' | sort -u | paste -sd' ' -)"
  echo "other schedules (minute:hour): $taken; this one's minute: $minute"
  [[ $minute != 0 && $minute != 15 && $minute != 30 && $minute != 45 ]]
  [[ " $taken " != *" $minute:"* ]]
  # Nor inside the window of the database's own dump job, from its schedule to the end of its run's
  # deadline, which holds the wait of its stagger, so the dump's reads and the base backup's do not
  # meet on the instances.
  dump_schedule="$(yq -N 'select(.kind == "CronJob" and .metadata.name == "orders-db-pgdump") | .spec.schedule' "$BUILT")"
  deadline="$(yq -N 'select(.kind == "CronJob" and .metadata.name == "orders-db-pgdump") | .spec.jobTemplate.spec.activeDeadlineSeconds' "$BUILT")"
  [[ $dump_schedule =~ ^([0-9]|[1-5][0-9])\ ([0-9]|1[0-9]|2[0-3])\ \*\ \*\ \*$ ]]
  dump_start=$((BASH_REMATCH[2] * 60 + BASH_REMATCH[1]))
  [[ $deadline =~ ^[1-9][0-9]*$ ]]
  dump_end=$((dump_start + (deadline + 59) / 60))
  echo "dump window: minute $dump_start to $dump_end of the day; base backup at minute $((hour * 60 + minute))"
  ((hour * 60 + minute < dump_start || hour * 60 + minute > dump_end))
  # What the ObjectStore keeps and how: a recovery window for base backups and WAL, both compressed.
  retention="$(yq -N 'select(.kind == "ObjectStore") | .spec.retentionPolicy // "none"' "$BUILT")"
  compression="$(yq -N 'select(.kind == "ObjectStore") | (.spec.configuration.data.compression // "none") + " " + (.spec.configuration.wal.compression // "none")' "$BUILT")"
  echo "retention: $retention; compression of base backups and WAL: $compression"
  [[ $retention =~ ^[1-9][0-9]*[dwm]$ ]]
  [[ $compression =~ ^(bzip2|gzip|lz4|snappy|zstd)\ (bzip2|gzip|lz4|snappy|xz|zstd)$ ]]
  # The cluster's object storage: its endpoint from cluster-config, the postgres bucket, and under
  # it the Kubernetes cluster, the namespace and the database.
  endpoint="$(yq -N 'select(.kind == "ObjectStore") | .spec.configuration.endpointURL' "$BUILT")"
  [ "$endpoint" = "$(yq '.S3_ENDPOINT' "$vars")" ]
  echo "archive: $(archive_path "$BUILT")"
  [ "$(archive_path "$BUILT")" = "s3://$(yq '.BACKUP_BUCKET_PREFIX' "$vars")-postgres/$(yq '.CLUSTER_NAME' "$vars")/demo/orders-db" ]
  # The endpoint is cluster-config's and no other: moved there, it moves here.
  SET=(S3_ENDPOINT=https://s3.marker.invalid)
  database orders orders-db
  endpoint="$(yq -N 'select(.kind == "ObjectStore") | .spec.configuration.endpointURL' "$BUILT")"
  echo "endpoint for another cluster-config: $endpoint"
  [ "$endpoint" = https://s3.marker.invalid ]
  # The same for each database the cluster's overlay builds, as its application builds it, patches
  # of the component's objects included: the base backup starts on that minute and outside the run
  # of the database's own dump job.
  SET=()
  for app in "${DATABASE_APPS[@]}"; do
    built "${app%%/*}" "${app##*/}"
    schedule="$(yq -N 'select(.kind == "ScheduledBackup") | .spec.schedule' "$BUILT")"
    dump_schedule="$(yq -N 'select(.kind == "CronJob" and (.metadata.name | test("-pgdump$"))) | .spec.schedule' "$BUILT")"
    deadline="$(yq -N 'select(.kind == "CronJob" and (.metadata.name | test("-pgdump$"))) | .spec.jobTemplate.spec.activeDeadlineSeconds' "$BUILT")"
    echo "$app: base backup '$schedule'; dump job '$dump_schedule', deadline $deadline seconds"
    [[ $schedule =~ ^0\ ([0-9]|[1-5][0-9])\ ([0-9]|1[0-9]|2[0-3])\ \*\ \*\ \*$ ]]
    minute=${BASH_REMATCH[1]}
    hour=${BASH_REMATCH[2]}
    [[ " $taken " != *" $minute:"* ]]
    [[ $dump_schedule =~ ^([0-9]|[1-5][0-9])\ ([0-9]|1[0-9]|2[0-3])\ \*\ \*\ \*$ ]]
    dump_start=$((BASH_REMATCH[2] * 60 + BASH_REMATCH[1]))
    [[ $deadline =~ ^[1-9][0-9]*$ ]]
    dump_end=$((dump_start + (deadline + 59) / 60))
    ((hour * 60 + minute < dump_start || hour * 60 + minute > dump_end))
  done
}

@test "Every object a database archives is encrypted at the provider with a customer key the provider does not keep" {
  local app name selectors
  for app in orders billing; do
    database "$app" "$app-db"
    # The customer key is a key of a Secret, named in s3Credentials, beside the other credentials,
    # and the plugin refuses an ObjectStore that sets it and the bucket-managed encryption too.
    selectors="$(yq -N 'select(.kind == "ObjectStore") | .spec.configuration.s3Credentials.sseCustomerKey | .name + "/" + .key' "$BUILT")"
    name="$(yq -N 'select(.kind == "ObjectStore") | .spec.configuration.s3Credentials.accessKeyId.name' "$BUILT")"
    echo "$app: customer key from $selectors; the other credentials from $name"
    [[ $selectors == "$name/"?* ]]
    [ "$(yq -N 'select(.kind == "ObjectStore") | .spec.configuration.data.encryption // "unset"' "$BUILT")" = unset ]
    [ "$(yq -N 'select(.kind == "ObjectStore") | .spec.configuration.wal.encryption // "unset"' "$BUILT")" = unset ]
    [ "$(yq -N 'select(.kind == "ObjectStore") | .spec.configuration.serverName // "unset"' "$BUILT")" = unset ]
  done
}

@test "The object store's key reaches the database's namespace from the secret store and is nowhere in the tree" {
  local secret keys refs credential literal source template read_from es
  database orders orders-db
  # Two ExternalSecrets in the application's namespace: the one that writes the Secret the
  # ObjectStore names, read here, and the dump job's (tests/postgres-dumps.bats). The ObjectStore's
  # is made from the cluster's S3 key in the key volsync, its two key fields and not the restic
  # master beside them, and from the customer key's own key.
  [ "$(yq -N 'select(.kind == "ExternalSecret") | .metadata.namespace + "/" + .metadata.name' "$BUILT" | sort | paste -sd,)" = demo/orders-db-backup,demo/orders-db-dump-s3 ]
  secret="$(yq -N 'select(.kind == "ObjectStore") | .spec.configuration.s3Credentials.accessKeyId.name' "$BUILT")"
  es="select(.kind == \"ExternalSecret\" and .spec.target.name == \"$secret\")"
  [ "$(yq -N "$es | .metadata.namespace + \"/\" + .metadata.name" "$BUILT")" = demo/orders-db-backup ]
  [ "$(yq -N "$es | .spec.secretStoreRef.kind + \"/\" + .spec.secretStoreRef.name" "$BUILT")" = ClusterSecretStore/openbao ]
  refs="$(yq -N "$es | .spec.data | map(.remoteRef.key + \"/\" + .remoteRef.property) | sort | join(\",\")" "$BUILT")"
  echo "reads: $refs"
  [ "$refs" = "postgres-backups/SSE_C_KEY,volsync/AWS_ACCESS_KEY_ID,volsync/AWS_SECRET_ACCESS_KEY" ]
  [ "$(yq -N "$es | .spec.dataFrom // \"none\"" "$BUILT")" = none ]
  # The Secret it makes is the one every credential of the ObjectStore names, by keys it holds.
  keys="$(yq -N "$es | .spec.target.template.data | keys | .[]" "$BUILT")"
  for credential in accessKeyId secretAccessKey region sseCustomerKey; do
    echo "$credential: $(CRED="$credential" yq -N 'select(.kind == "ObjectStore") | .spec.configuration.s3Credentials[strenv(CRED)] | .name + "/" + .key' "$BUILT")"
    [ "$(CRED="$credential" yq -N 'select(.kind == "ObjectStore") | .spec.configuration.s3Credentials[strenv(CRED)].name' "$BUILT")" = "$secret" ]
    grep -qxF "$(CRED="$credential" yq -N 'select(.kind == "ObjectStore") | .spec.configuration.s3Credentials[strenv(CRED)].key' "$BUILT")" <<<"$keys"
  done
  # Which value of the store ends up under which key: each credential's key holds a template of one
  # store value, and the value is read from the entry and property the credential is made from. A
  # key that held the other credential's value, or a literal, would still be a key the Secret has.
  for credential in accessKeyId:volsync/AWS_ACCESS_KEY_ID secretAccessKey:volsync/AWS_SECRET_ACCESS_KEY \
    sseCustomerKey:postgres-backups/SSE_C_KEY; do
    source="$(CRED="${credential%%:*}" yq -N 'select(.kind == "ObjectStore") | .spec.configuration.s3Credentials[strenv(CRED)].key' "$BUILT")"
    template="$(KEY="$source" yq -N "$es | .spec.target.template.data[strenv(KEY)]" "$BUILT")"
    [[ $template =~ ^\{\{\ \.([A-Za-z]+)\ \}\}$ ]]
    read_from="$(NAME="${BASH_REMATCH[1]}" yq -N "$es | .spec.data[] | select(.secretKey == strenv(NAME))
      | .remoteRef.key + \"/\" + .remoteRef.property" "$BUILT")"
    echo "${credential%%:*}: $source = $template, read from $read_from"
    [ "$read_from" = "${credential#*:}" ]
  done
  # The region is not secret and is the cluster's own, from cluster-config, written as a value.
  [ "$(yq -N "$es | .spec.target.template.data.REGION" "$BUILT")" = "$(yq '.S3_REGION' "$BATS_TEST_TMPDIR/example-vars.yaml")" ]
  # And no other: moved there, it moves here.
  SET=(S3_REGION=marker-region)
  database orders orders-db
  echo "region for another cluster-config: $(yq -N "$es | .spec.target.template.data.REGION" "$BUILT")"
  [ "$(yq -N "$es | .spec.target.template.data.REGION" "$BUILT")" = marker-region ]
  # Nothing built is a Secret, and the credentials of the ObjectStore are references only.
  [ -z "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$BUILT")" ]
  [ "$(yq -N 'select(.kind == "ObjectStore") | .spec.configuration.s3Credentials | to_entries | map(.value | keys | join("+")) | unique | join(",")' "$BUILT")" = key+name ]
  # No key in the tree: no encrypted file stands in for one, and no base64 of 32 bytes, the form of
  # the customer key, is written in a manifest of the component or of an application.
  [ -z "$(find "$REPO/kubernetes" \( -name '*.enc.*' -o -name '*.sops.*' -o -name '*.age*' \))" ]
  literal="$(grep -rnE '(^|[^A-Za-z0-9+/])[A-Za-z0-9+/]{43}=([^A-Za-z0-9+/=]|$)' "$REPO/kubernetes/components/cnpg-cluster" "$REPO/kubernetes/apps/base/cnpg-system" \
    "$REPO/kubernetes/apps/base/ai-system" "$REPO/kubernetes/apps/base/backstage" || true)"
  echo "a base64 key in a manifest: ${literal:-none}"
  [ -z "$literal" ]
}

@test "Two databases never share a backup path" {
  local -a paths=()
  database orders orders-db
  paths+=("$(archive_path "$BUILT")")
  database billing billing-db
  paths+=("$(archive_path "$BUILT")")
  # The same database name in another namespace.
  database_app orders-other orders-db other
  built demo orders-other
  paths+=("$(archive_path "$BUILT")")
  database_app billing-other billing-db other
  built demo billing-other
  paths+=("$(archive_path "$BUILT")")
  printf 'path: %s\n' "${paths[@]}"
  [ "$(printf '%s\n' "${paths[@]}" | sort -u | wc -l)" -eq 4 ]
  # Each part moves the path alone: the Kubernetes cluster's name, which keeps two clusters that
  # share a bucket apart, and the bucket's prefix.
  SET=(CLUSTER_NAME=other-cluster)
  database orders orders-db
  echo "another cluster: $(archive_path "$BUILT")"
  [ "$(archive_path "$BUILT")" = "${paths[0]/\/example-cluster\//\/other-cluster\/}" ]
  SET=(BACKUP_BUCKET_PREFIX=marker-prefix)
  database orders orders-db
  echo "another prefix: $(archive_path "$BUILT")"
  [ "$(archive_path "$BUILT")" = "${paths[0]/\/\/example-backups-postgres\//\/\/marker-prefix-postgres\/}" ]
  # A path never ends where another's begins: the database's name is its own last element.
  [[ ${paths[0]} == */demo/orders-db ]]
}

@test "Two databases never share a backup path, whatever namespace an application names" {
  local dir="$BATS_TEST_TMPDIR/wrong-namespace"
  # The path takes its namespace from CNPG_NAMESPACE, which the component cannot read from the
  # Kustomization's targetNamespace, so scripts/kubernetes-check holds the two equal for every
  # Kustomization that takes the component: one that names another namespace shares the path of
  # the database of that namespace.
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  mkdir -p "$dir"
  cp -R "$REPO/kubernetes" "$dir/kubernetes"
  yq -i '.spec.postBuild.substitute.CNPG_NAMESPACE = "other"' "$dir/kubernetes/apps/base/ai-system/n8n/ks.yaml"
  run "$REPO/scripts/kubernetes-check" "$dir"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"kubernetes/apps/base/ai-system/n8n/ks.yaml: Kustomization n8n sets CNPG_NAMESPACE to other"* ]]
  [[ $output == *"targetNamespace is ai-system"* ]]
  # Left out, the build fails strictly, so no database is archived under an empty namespace, and the
  # check names the variable.
  yq -i 'del(.spec.postBuild.substitute.CNPG_NAMESPACE)' "$dir/kubernetes/apps/base/ai-system/n8n/ks.yaml"
  run "$REPO/scripts/kubernetes-check" "$dir"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *CNPG_NAMESPACE* ]]
}

@test "A cluster that does not select the backup plugin builds no database that needs it, and one that selects a database without it is refused" {
  local overlay plugin=plugin-barman-cloud dir app users
  # The applications of the overlay that take a cluster from the component, each with its ks.yaml:
  # the component names the plugin's application in dependsOn of every user, as it names the
  # operator's.
  local -A files=()
  for app in "${DATABASE_APPS[@]}"; do
    files[${app##*/}]="kubernetes/apps/base/$app/ks.yaml"
  done
  overlay="$(kustomize build --load-restrictor LoadRestrictionsNone "$REPO/kubernetes/apps/overlays/lab-sto2")"
  users="$(yq -N 'select(.kind == "Kustomization" and ((.spec.components // []) | map(select(test("/components/cnpg-cluster$"))) | length) > 0)
    | .metadata.name' <<<"$overlay" | sort | paste -sd' ' -)"
  echo "applications that take the component: ${users:-none}"
  [ "$users" = "$(printf '%s\n' "${!files[@]}" | sort | paste -sd' ' -)" ]
  for app in "${!files[@]}"; do
    [ "$(APP_NAME="$app" yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(APP_NAME)) | .spec.dependsOn | map(.name) | map(select(. == "'$plugin'")) | join(",")' <<<"$overlay")" = "$plugin" ] ||
      { echo "$app does not name $plugin in dependsOn"; return 1; }
  done
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "'$plugin'") | .spec.path + " wait=" + (.spec.wait | tostring)' <<<"$overlay")" \
    = "./apps/base/cnpg-system/$plugin/app wait=true" ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # An overlay that lists them without the plugin's application is refused, naming each and it.
  dir="$BATS_TEST_TMPDIR/without-plugin"
  mkdir -p "$dir"
  cp -R "$REPO/kubernetes" "$dir/kubernetes"
  PLUGIN="$plugin" yq -i '.resources |= map(select(test("/" + strenv(PLUGIN) + "/ks.yaml$") | not))' \
    "$dir/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  run "$REPO/scripts/kubernetes-check" "$dir"
  echo "$output"
  [ "$status" -ne 0 ]
  for app in "${!files[@]}"; do
    [[ $output == *"${files[$app]}: Kustomization $app names $plugin"* ]]
  done
  [[ $output == *"does not enable"* ]]
  # A Kustomization that takes the component and does not name the plugin's application is refused
  # although the overlay enables it, so a database cannot start before the plugin's webhooks exist.
  for app in "${!files[@]}"; do
    dir="$BATS_TEST_TMPDIR/without-dependency-$app"
    mkdir -p "$dir"
    cp -R "$REPO/kubernetes" "$dir/kubernetes"
    PLUGIN="$plugin" yq -i '.spec.dependsOn |= map(select(.name != strenv(PLUGIN)))' "$dir/${files[$app]}"
    run "$REPO/scripts/kubernetes-check" "$dir"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ $output == *"${files[$app]}: Kustomization $app takes the cnpg-cluster component but does not name $plugin in dependsOn"* ]]
  done
  # One that lists neither the plugin's application nor any that takes the component builds none
  # of them.
  dir="$BATS_TEST_TMPDIR/without-plugin"
  for app in "${!files[@]}"; do
    FILE="${files[$app]#kubernetes/apps/base/}" yq -i '.resources |= map(select(. != "../../base/" + strenv(FILE)))' \
      "$dir/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  done
  run "$REPO/scripts/kubernetes-check" "$dir"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay="$(kustomize build --load-restrictor LoadRestrictionsNone "$dir/kubernetes/apps/overlays/lab-sto2")"
  for app in "${!files[@]}" "$plugin"; do
    [ -z "$(APP_NAME="$app" yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(APP_NAME)) | .metadata.name' <<<"$overlay")" ] ||
      { echo "the overlay still builds $app"; return 1; }
  done
}

@test "The Barman Cloud plugin runs beside the operator it is made for and meets the restricted Pod Security level" {
  local required=1.30 operator overlay image sidecar version deployment labels replicas spread budgets
  # The plugin's release requires CloudNativePG 1.30 or newer, which is the operator's version the
  # chart the repository pins installs, read from the chart. The floor is this constant, from the
  # installation documentation of the plugin's release, and nothing reads it from a release: a plugin
  # release whose documentation raises it needs it raised here by hand, in the same pull request.
  render
  operator="$(tar -xzOf "$CHART" cloudnative-pg/Chart.yaml | yq '.appVersion')"
  echo "operator $operator; the plugin requires $required or newer"
  [ "$(printf '%s\n' "$required" "$operator" | sort -V | head -n 1)" = "$required" ]
  APP="plugin-barman-cloud"
  # Enabled in the cluster's overlay, after the operator and cert-manager, whose kinds its issuer and
  # certificates are.
  overlay="$(kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2")"
  [ "$(yq -N "select(.kind == \"Kustomization\" and .metadata.name == \"$APP\") | .spec.path + \" wait=\" + (.spec.wait | tostring)" <<<"$overlay")" \
    = "./apps/base/$NAMESPACE/$APP/app wait=true" ]
  [ "$(yq -N "select(.kind == \"Kustomization\" and .metadata.name == \"$APP\") | .spec.dependsOn | map(.name) | sort | join(\" \")" <<<"$overlay")" \
    = "cert-manager cloudnative-pg" ]
  render
  version="$(tar -xzOf "$CHART" plugin-barman-cloud/Chart.yaml | yq '.appVersion')"
  echo "plugin $version"
  # Everything it renders is in the operator's namespace, which the plugin must share.
  [ -z "$(yq -N "select(. != null and .metadata.namespace != null and .metadata.namespace != \"$NAMESPACE\") | .kind" "$RENDERED")" ]
  # Its images are the release its chart is made for, pinned by digest, the operator's and the
  # sidecar the operator injects into every database pod.
  image="$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$RENDERED")"
  sidecar="$(yq -N 'select(.kind == "ConfigMap") | .data.SIDECAR_IMAGE' "$RENDERED")"
  echo "images: $image $sidecar"
  [[ $image == "ghcr.io/cloudnative-pg/plugin-barman-cloud:$version@sha256:"* ]]
  [[ $sidecar == "ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:$version@sha256:"* ]]
  [[ ${image#*@} =~ ^sha256:[0-9a-f]{64}$ && ${sidecar#*@} =~ ^sha256:[0-9a-f]{64}$ ]]
  # More than one replica, on different nodes, with a budget that keeps one running while a node is
  # drained: while no replica answers, the operator cannot make a database's pod.
  deployment="$BATS_TEST_TMPDIR/deployment.yaml"
  yq -N 'select(.kind == "Deployment")' "$RENDERED" >"$deployment"
  labels="$(yq -o json -I0 '.spec.template.metadata.labels // {}' "$deployment")"
  replicas="$(yq '.spec.replicas // 1' "$deployment")"
  # shellcheck disable=SC2016 # $labels is a yq variable.
  spread="$(LABELS="$labels" yq -N '(strenv(LABELS) | from_yaml) as $labels
    | [.spec.template.spec.topologySpreadConstraints // [] | .[]
      | select(.topologyKey == "kubernetes.io/hostname" and .whenUnsatisfiable == "DoNotSchedule" and .maxSkew == 1
        and (.labelSelector.matchLabels // {} | length) > 0
        and (.labelSelector.matchLabels | to_entries | all_c(.value == $labels[.key])))] | length' "$deployment")"
  # shellcheck disable=SC2016 # $labels is a yq variable.
  budgets="$(LABELS="$labels" yq -N '(strenv(LABELS) | from_yaml) as $labels | select(.kind == "PodDisruptionBudget"
    and (.spec.selector.matchLabels // {} | length) > 0
    and (.spec.selector.matchLabels | to_entries | all_c(.value == $labels[.key])))
    | (.spec.minAvailable // "unset" | tostring)' "$BUILT")"
  echo "replicas $replicas; spread constraints $spread; budgets (minAvailable): ${budgets:-none}"
  [ "$replicas" -ge 2 ]
  [ "$spread" -ge 1 ]
  [[ $budgets =~ ^[0-9]+$ ]]
  ((budgets >= 1 && budgets < replicas))
  # The chart makes neither certificates nor an issuer: the two certificates and their issuer are the
  # application's own, which the next test reads.
  [ -z "$(yq -N 'select(.kind == "Certificate" or .kind == "Issuer" or .kind == "ClusterIssuer") | .kind' "$RENDERED")" ]
  # The namespace it shares with the operator enforces the restricted level, and the pods meet it.
  [ "$(yq -N 'select(.kind == "Namespace") | .metadata.labels["pod-security.kubernetes.io/enforce"]' "$TREE/kubernetes/apps/base/$NAMESPACE/namespace.yaml")" = restricted ]
  assert_restricted
}

# The plugin's server and the operator, as the pinned releases make them, each trust exactly the
# other's certificate. The server (cnpg-i-machinery v0.4.2, pkg/pluginhelper/http/server.go,
# getConfigForClient) requires a client certificate and verifies it against a pool read from the file
# --client-cert names, and Go's server names that pool's subjects to the client as the authorities it
# accepts (crypto/tls, handshake_server_tls13.go, at go1.26.6, the version the plugin's go.mod
# names). The operator (CloudNativePG v1.30.1, internal/controller/plugin_controller.go) presents
# tls.crt and tls.key of the Secret the Service names in cnpg.io/pluginClientSecret, and trusts tls.crt
# of the one in cnpg.io/pluginServerSecret for the server's certificate. Go's client sends a
# certificate only if one in its chain is issued by an authority the server names, and none otherwise
# (crypto/tls, handshake_client.go, getClientCertificate, and common.go, SupportsCertificate, at
# go1.27.1, the toolchain the operator's go.mod names), and the server then ends the handshake with
# the alert certificate required (handshake_server.go, processCertsFromClient, at go1.26.6); Go's
# x509 accepts a certificate that is itself among the roots (crypto/x509, verify.go, Verify).
#
# handshake() runs those rules with OpenSSL. Its client picks a certificate by the authorities the
# server names only in strict mode, which in TLS 1.3 also refuses an RSA or ECDSA key for want of
# certificate types that TLS 1.3 no longer sends (ssl/t1_lib.c, tls1_check_chain, at openssl-3.5.7,
# the tools image's), so the certificates made here have Ed25519 keys; a key's type changes neither
# its certificate's issuer nor the names the server sends.

# plugin_arg NAME: the value of the argument --NAME of the plugin's container in $RENDERED.
plugin_arg() {
  NAME="$1" yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "barman-cloud")
    | .args[] | select(test("^--" + strenv(NAME) + "=")) | sub("^--" + strenv(NAME) + "="; "")' "$RENDERED"
}

# mounted FILE: the Secret and key, as SECRET/KEY, that the plugin's container reads the file FILE
# from: the Secret volume mounted at FILE's directory in $RENDERED.
mounted() {
  # shellcheck disable=SC2016 # $p and $volume are yq variables.
  FILE="$1" yq -N 'select(.kind == "Deployment") | .spec.template.spec as $p | $p.containers[] | select(.name == "barman-cloud")
    | .volumeMounts[] | select((strenv(FILE) | sub("/[^/]*$"; "")) == .mountPath) | .name as $volume
    | $p.volumes[] | select(.name == $volume) | .secret.secretName + "/" + (strenv(FILE) | sub("^.*/"; ""))' "$RENDERED"
}

# authority DIR NAME: DIR/NAME.crt and DIR/NAME.key, a CA whose common name is NAME, made as the
# cluster's own CA is: an ECDSA P-384 key and a certificate it signs itself, which may sign others.
authority() {
  [ ! -f "$1/$2.crt" ] || return 0
  printf '%s\n' '[req]' 'distinguished_name = dn' 'prompt = no' '[dn]' "CN = $2" '[ca]' \
    'basicConstraints = critical, CA:TRUE' 'keyUsage = critical, keyCertSign, digitalSignature, keyEncipherment' >"$1/$2.cnf"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$1/$2.key"
  openssl req -new -x509 -config "$1/$2.cnf" -extensions ca -key "$1/$2.key" -days 3650 -out "$1/$2.crt"
}

# issue DIR NAME [CA]: DIR/NAME.crt and DIR/NAME.key for the Certificate NAME of $BUILT, with its common
# name, DNS names and usages, made as the issuer it names would make it: signed by its own key, so
# that its issuer is its own subject, when the build holds that issuer and it is selfSigned, as
# cert-manager's selfSigned issuer signs (pkg/controller/certificaterequests/selfsigned/selfsigned.go
# at v1.21.3); otherwise signed by a CA named after the issuer, or CA when it is given, and tls.crt
# holds the certificate alone, as cert-manager's CA issuer writes it when its CA signed itself
# (pkg/util/pki/parse_certificate_chain.go, toBundleAndCA).
issue() {
  local dir=$1 name=$2 ca=${3:-} certificate kind issuer usage dns
  local -a usages=()
  certificate="select(.kind == \"Certificate\" and .metadata.name == \"$name\")"
  kind="$(yq -N "$certificate | .spec.issuerRef.kind" "$BUILT")"
  issuer="$(yq -N "$certificate | .spec.issuerRef.name" "$BUILT")"
  if [ -z "$ca" ] &&
    [ "$(yq -N "select(.kind == \"$kind\" and .metadata.name == \"$issuer\") | .spec | has(\"selfSigned\")" "$BUILT")" != true ]; then
    ca=$issuer
  fi
  while read -r usage; do
    case $usage in
      "client auth") usages+=(clientAuth) ;;
      "server auth") usages+=(serverAuth) ;;
      *) echo "issue: no extended key usage for '$usage'"; return 1 ;;
    esac
  done < <(yq -N "$certificate | .spec.usages // [] | .[]" "$BUILT")
  dns="$(yq -N "$certificate | .spec.dnsNames // [] | map(\"DNS:\" + .) | join(\",\")" "$BUILT")"
  {
    printf '%s\n' '[req]' 'distinguished_name = dn' 'prompt = no' '[dn]' "CN = $(yq -N "$certificate | .spec.commonName" "$BUILT")" \
      '[leaf]' 'basicConstraints = critical, CA:FALSE' 'subjectKeyIdentifier = none' 'authorityKeyIdentifier = none'
    if [ "${#usages[@]}" -gt 0 ]; then echo "extendedKeyUsage = $(IFS=,; echo "${usages[*]}")"; fi
    if [ -n "$dns" ]; then echo "subjectAltName = $dns"; fi
  } >"$dir/$name.cnf"
  openssl genpkey -algorithm ED25519 -out "$dir/$name.key"
  if [ -z "$ca" ]; then
    openssl req -new -x509 -config "$dir/$name.cnf" -extensions leaf -key "$dir/$name.key" -days 90 -out "$dir/$name.crt"
  else
    authority "$dir" "$ca"
    openssl req -new -config "$dir/$name.cnf" -key "$dir/$name.key" -out "$dir/$name.csr"
    openssl x509 -req -in "$dir/$name.csr" -CA "$dir/$ca.crt" -CAkey "$dir/$ca.key" -extfile "$dir/$name.cnf" \
      -extensions leaf -days 90 -out "$dir/$name.crt"
  fi
}

# made DIR SECRET/KEY: the file issue() made in DIR for the key KEY, tls.crt or tls.key, of the Secret
# SECRET: that of the Certificate of $BUILT that writes SECRET.
made() {
  local name
  name="$(SECRET="${2%/*}" yq -N 'select(.kind == "Certificate" and .spec.secretName == strenv(SECRET)) | .metadata.name' "$BUILT")"
  case ${2##*/} in
    tls.crt) [ -n "$name" ] && echo "$1/$name.crt" ;;
    tls.key) [ -n "$name" ] && echo "$1/$name.key" ;;
    *) return 1 ;;
  esac
}

# handshake DIR SERVER_CERT SERVER_KEY CLIENT_CAS CLIENT_CERT CLIENT_KEY TRUST NAME: one TLS 1.3
# handshake on the loopback interface between a server that serves SERVER_CERT, requires a client
# certificate and accepts one that is, or is issued by, a certificate of CLIENT_CAS, whose subjects it
# names, and a client that offers CLIENT_CERT only if it is issued by an authority the server names,
# and accepts the server's certificate for NAME if it is, or is issued by, a certificate of TRUST. The
# server answers with a page that describes the client certificate it verified. Writes DIR/server.out
# and DIR/client.out and returns the client's status.
handshake() {
  local dir=$1 pid port="" status=0 _
  printf 'GET / HTTP/1.0\r\n\r\n' >"$dir/request"
  openssl s_server -accept 127.0.0.1:0 -naccept 1 -www -tls1_3 -cert "$2" -key "$3" -CAfile "$4" \
    -Verify 1 -verify_return_error -partial_chain </dev/null >"$dir/server.out" 2>&1 3>&- &
  pid=$!
  for _ in $(seq 100); do
    port="$(sed -n 's/^ACCEPT 127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' "$dir/server.out")"
    [ -z "$port" ] || break
    sleep 0.1
  done
  if [ -n "$port" ]; then
    openssl s_client -connect "127.0.0.1:$port" -tls1_3 -strict -cert "$5" -key "$6" -CAfile "$7" -partial_chain \
      -verify_return_error -verify_hostname "$8" -servername "$8" -ign_eof <"$dir/request" >"$dir/client.out" 2>&1 || status=$?
  else
    echo "the server did not start" >"$dir/client.out"
    status=1
  fi
  for _ in $(seq 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" || true
  return "$status"
}

# accepted DIR: the client's view of the last handshake in DIR: the authorities the server named, one
# per line, then the line client= and the subject of the client certificate the server verified, or
# none.
accepted() {
  awk '/^Acceptable client certificate CA names$/ { names = 1; next } names && /^[A-Za-z]+=/ { print; next } { names = 0 }
    /^Client certificate$/ { page = 1 } page && /^ *Subject: / { sub(/^ *Subject: /, ""); client = $0; page = 0 }
    END { print "client=" (client == "" ? "none" : client) }' "$1/client.out"
}

@test "The backup plugin and the operator each trust exactly the other's certificate" {
  local dir="$BATS_TEST_TMPDIR/tls" certificates server_cert server_key client_cas client_secret server_secret name
  local subject each certificate issuer
  APP="plugin-barman-cloud"
  render
  # render() reads the chart as helm template writes it, and helm-controller passes the release through
  # its post-renderers before it applies it, so the files the pods read are those read below only
  # while the release has none.
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.postRenderers // [] | length' "$BUILT")" -eq 0 ] ||
    { echo "the HelmRelease has post-renderers, which change the pods after the render read here"; return 1; }
  mkdir -p "$dir/built" "$dir/cluster-ca"
  # No configuration of the machine's OpenSSL applies.
  : >"$dir/openssl.cnf"
  export OPENSSL_CONF="$dir/openssl.cnf"
  # The two Certificates have the names, Secrets, usages and DNS names of the plugin's own manifest,
  # and neither is a CA, as there.
  certificates="$(yq -N 'select(.kind == "Certificate") | .metadata.namespace + "/" + .metadata.name + " cn=" + .spec.commonName
    + " secret=" + .spec.secretName + " usages=" + (.spec.usages // [] | join(",")) + " dns=" + (.spec.dnsNames // [] | join(","))
    + " ca=" + (.spec.isCA // false | tostring)' "$BUILT" | sort)"
  echo "$certificates"
  [ "$certificates" = "$(printf '%s\n' \
    "$NAMESPACE/barman-cloud-client cn=barman-cloud-client secret=barman-cloud-client-tls usages=client auth dns= ca=false" \
    "$NAMESPACE/barman-cloud-server cn=barman-cloud secret=barman-cloud-server-tls usages=server auth dns=barman-cloud ca=false")" ]
  # What each side reads: the plugin's server its certificate, its key and its client authorities from
  # the Secrets mounted in its pod, the operator the Secrets the Service names.
  server_cert="$(mounted "$(plugin_arg server-cert)")"
  server_key="$(mounted "$(plugin_arg server-key)")"
  client_cas="$(mounted "$(plugin_arg client-cert)")"
  client_secret="$(yq -N 'select(.kind == "Service") | .metadata.annotations["cnpg.io/pluginClientSecret"]' "$RENDERED")"
  server_secret="$(yq -N 'select(.kind == "Service") | .metadata.annotations["cnpg.io/pluginServerSecret"]' "$RENDERED")"
  name="$(yq -N 'select(.kind == "Service") | .metadata.annotations["cnpg.io/pluginServerName"] // .metadata.name' "$RENDERED")"
  echo "the plugin serves $server_cert and $server_key and takes $client_cas as its client authorities;" \
    "the operator presents $client_secret and trusts $server_secret/tls.crt for $name"
  [ "$client_cas" = "$(yq -N 'select(.kind == "Certificate" and .metadata.name == "barman-cloud-client") | .spec.secretName' "$BUILT")/tls.crt" ]
  [ "$client_secret" = "${client_cas%/tls.crt}" ]
  [ "$server_cert" = "$(yq -N 'select(.kind == "Certificate" and .metadata.name == "barman-cloud-server") | .spec.secretName' "$BUILT")/tls.crt" ]
  [ "$server_key" = "${server_cert%/tls.crt}/tls.key" ]
  [ "$server_secret" = "${server_cert%/tls.crt}" ]
  # The server's certificate is valid for the name the operator checks it for, the Service's.
  [ "$(yq -N 'select(.kind == "Certificate" and .metadata.name == "barman-cloud-server") | .spec.dnsNames | join(",")' "$BUILT")" = "$name" ]
  # The handshake tells the two kinds of issuer apart: certificates the cluster's CA issues end it with
  # certificate required, as the server names the client certificate's own subject and the CA issued
  # that certificate, and it completes once the server names the CA instead.
  issue "$dir/cluster-ca" barman-cloud-client cluster-ca
  issue "$dir/cluster-ca" barman-cloud-server cluster-ca
  run handshake "$dir/cluster-ca" "$(made "$dir/cluster-ca" "$server_cert")" "$(made "$dir/cluster-ca" "$server_key")" \
    "$(made "$dir/cluster-ca" "$client_cas")" "$(made "$dir/cluster-ca" "$client_secret/tls.crt")" \
    "$(made "$dir/cluster-ca" "$client_secret/tls.key")" "$(made "$dir/cluster-ca" "$server_secret/tls.crt")" "$name"
  echo "issued by the cluster's CA: status $status; $(accepted "$dir/cluster-ca" | paste -sd' ' -)"
  [ "$status" -ne 0 ]
  [ "$(accepted "$dir/cluster-ca")" = "$(printf '%s\n' CN=barman-cloud-client client=none)" ]
  grep -q 'alert certificate required' "$dir/cluster-ca/client.out"
  run handshake "$dir/cluster-ca" "$dir/cluster-ca/barman-cloud-server.crt" "$dir/cluster-ca/barman-cloud-server.key" \
    "$dir/cluster-ca/cluster-ca.crt" "$dir/cluster-ca/barman-cloud-client.crt" "$dir/cluster-ca/barman-cloud-client.key" \
    "$dir/cluster-ca/barman-cloud-server.crt" "$name"
  echo "the same, with the server naming the CA: status $status; $(accepted "$dir/cluster-ca" | paste -sd' ' -)"
  [ "$status" -eq 0 ]
  [ "$(accepted "$dir/cluster-ca")" = "$(printf '%s\n' CN=cluster-ca client=CN=barman-cloud-client)" ]
  # With the certificates the tree's issuers make, each side presents its own and trusts the other's:
  # the server names the client certificate's subject alone, and verifies the certificate the client
  # presents, and the client verifies the server's.
  issue "$dir/built" barman-cloud-client
  issue "$dir/built" barman-cloud-server
  run handshake "$dir/built" "$(made "$dir/built" "$server_cert")" "$(made "$dir/built" "$server_key")" \
    "$(made "$dir/built" "$client_cas")" "$(made "$dir/built" "$client_secret/tls.crt")" \
    "$(made "$dir/built" "$client_secret/tls.key")" "$(made "$dir/built" "$server_secret/tls.crt")" "$name"
  echo "issued as the tree's issuers issue: status $status; $(accepted "$dir/built" | paste -sd' ' -)"
  cat "$dir/built/server.out"
  subject="$(openssl x509 -in "$(made "$dir/built" "$client_secret/tls.crt")" -noout -subject)"
  [ "$status" -eq 0 ]
  [ "$(accepted "$dir/built")" = "$(printf '%s\n' "${subject#subject=}" "client=${subject#subject=}")" ]
  grep -qx 'Verify return code: 0 (ok)' "$dir/built/client.out"
  # Both are self-signed: each Certificate names an Issuer, of cert-manager's group, that the build
  # holds in the plugin's namespace, of kind selfSigned and nothing else; the build holds no
  # ClusterIssuer.
  for each in barman-cloud-client barman-cloud-server; do
    certificate="select(.kind == \"Certificate\" and .metadata.name == \"$each\")"
    echo "$each: issuer $(yq -N "$certificate | .spec.issuerRef | (.group // \"\") + \"/\" + .kind + \"/\" + .name" "$BUILT")"
    [ "$(yq -N "$certificate | (.spec.issuerRef.group // \"\") + \" \" + .spec.issuerRef.kind" "$BUILT")" = "cert-manager.io Issuer" ]
    issuer="$(yq -N "$certificate | .spec.issuerRef.name" "$BUILT")"
    [ "$(yq -N "select(.kind == \"Issuer\" and .metadata.name == \"$issuer\") | .metadata.namespace + \" \" + (.spec | keys | join(\",\"))" "$BUILT")" \
      = "$NAMESPACE selfSigned" ]
  done
  [ -z "$(yq -N 'select(.kind == "ClusterIssuer") | .metadata.name' "$BUILT")" ]
}

@test "The plugin's chart and images are pinned where Renovate updates them" {
  local -a chart
  local dir=kubernetes/apps/base/cnpg-system/plugin-barman-cloud/app url image repository line
  mapfile -t chart < <(pin "$TREE/$dir/ocirepository.yaml" tag)
  url="$(yq '.spec.url' "$TREE/$dir/ocirepository.yaml")"
  echo "chart: $url, ${chart[1]:-no tag} under '${chart[0]:-nothing}'"
  [[ ${chart[0]:-} =~ ^\ *#\ renovate:\ datasource=docker\ depName=([^ ]+)$ ]]
  [ "${BASH_REMATCH[1]}" = "${url#oci://}" ]
  [[ ${chart[1]:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  # Each image under the chart's values: the operator's and the sidecar's, by tag and digest, which
  # Renovate moves together.
  for image in plugin-barman-cloud plugin-barman-cloud-sidecar; do
    repository="ghcr.io/cloudnative-pg/$image"
    line="$(awk -v want="# renovate: datasource=docker depName=$repository" '
      { sub(/^[ \t]+/, "") } prev == want { print $0; exit } { prev = $0 }' "$TREE/$dir/values.yaml")"
    echo "$image: ${line:-nothing}"
    [[ $line =~ ^tag:\ \"?v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}\"?$ ]]
  done
}

@test "Every field of the component's ObjectStore and ScheduledBackup is one the pinned plugin and operator define" {
  local operator_schema plugin_schema problems
  operator_schema="$BATS_TEST_TMPDIR/scheduledbackup-schema.json"
  plugin_schema="$BATS_TEST_TMPDIR/objectstore-schema.json"
  render
  yq -N -o json 'select(.kind == "CustomResourceDefinition" and .metadata.name == "scheduledbackups.postgresql.cnpg.io")
    | .spec.versions[] | select(.name == "v1") | .schema.openAPIV3Schema' "$RENDERED" >"$operator_schema"
  [ -s "$operator_schema" ]
  APP="plugin-barman-cloud"
  render
  yq -N -o json 'select(.kind == "CustomResourceDefinition" and .metadata.name == "objectstores.barmancloud.cnpg.io")
    | .spec.versions[] | select(.name == "v1") | .schema.openAPIV3Schema' "$RENDERED" >"$plugin_schema"
  [ -s "$plugin_schema" ]
  database orders orders-db
  yq -N -o json 'select(.kind == "ObjectStore")' "$BUILT" >"$BATS_TEST_TMPDIR/objectstore.json"
  yq -N -o json 'select(.kind == "ScheduledBackup")' "$BUILT" >"$BATS_TEST_TMPDIR/scheduledbackup.json"
  [ -s "$BATS_TEST_TMPDIR/objectstore.json" ]
  [ -s "$BATS_TEST_TMPDIR/scheduledbackup.json" ]
  problems="$(schema_problems "$plugin_schema" "$BATS_TEST_TMPDIR/objectstore.json"; schema_problems "$operator_schema" "$BATS_TEST_TMPDIR/scheduledbackup.json")"
  echo "problems: ${problems:-none}"
  [ -z "$problems" ]
}

@test "The restore runbook's manifest is one the pinned operator defines and reads the archive of the cluster it replaces" {
  local schema runbook="$REPO/docs/runbooks/postgres-restore.md" manifest="$BATS_TEST_TMPDIR/restore.yaml" problems source old new
  render
  schema="$BATS_TEST_TMPDIR/cluster-schema.json"
  yq -N -o json 'select(.kind == "CustomResourceDefinition" and .metadata.name == "clusters.postgresql.cnpg.io")
    | .spec.versions[] | select(.name == "v1") | .schema.openAPIV3Schema' "$RENDERED" >"$schema"
  [ -s "$schema" ]
  [ -f "$runbook" ]
  # The one fenced YAML block of the runbook that is a Cluster, whatever list item it is indented in.
  awk -v dir="$BATS_TEST_TMPDIR" '/^ *```yaml$/ { inside = 1; block++; match($0, /^ */); indent = RLENGTH; next }
    /^ *```$/ { inside = 0; next } inside { print substr($0, indent + 1) > (dir "/block-" block ".yaml") }' "$runbook"
  grep -lx 'kind: Cluster' "$BATS_TEST_TMPDIR"/block-*.yaml >"$BATS_TEST_TMPDIR/cluster-blocks"
  [ "$(grep -c . "$BATS_TEST_TMPDIR/cluster-blocks")" -eq 1 ]
  cp "$(cat "$BATS_TEST_TMPDIR/cluster-blocks")" "$manifest"
  yq -o json '.' "$manifest" >"$BATS_TEST_TMPDIR/restore.json"
  problems="$(schema_problems "$schema" "$BATS_TEST_TMPDIR/restore.json")"
  echo "problems: ${problems:-none}"
  [ -z "$problems" ]
  # It recovers from the plugin's archive of the old cluster, by the old cluster's name, and writes
  # its own archive under its own name, so that the two never write to one path.
  source="$(yq '.spec.bootstrap.recovery.source' "$manifest")"
  old="$(SOURCE="$source" yq '.spec.externalClusters[] | select(.name == strenv(SOURCE)) | .plugin.parameters.serverName' "$manifest")"
  new="$(yq '.spec.plugins[] | select(.isWALArchiver == true) | .parameters.serverName // ""' "$manifest")"
  echo "reads the archive of $old, writes its own under ${new:-no name}; named $(yq '.metadata.name' "$manifest")"
  [ "$(SOURCE="$source" yq '.spec.externalClusters[] | select(.name == strenv(SOURCE)) | .plugin.name' "$manifest")" = barman-cloud.cloudnative-pg.io ]
  [ -n "$old" ] && [ -n "$new" ] && [ "$old" != "$new" ]
  [ "$new" = "$(yq '.metadata.name' "$manifest")" ]
}
