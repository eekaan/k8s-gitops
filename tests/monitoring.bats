#!/usr/bin/env bats
# Proves features/monitoring.feature; each test carries its scenario's title.
# Needs helm, flux, kustomize, yq and jq on PATH (the versions pinned for the repository). Each
# chart is pulled once per run from its public registry; building and rendering are offline. The
# application is built in memory, so no build rewrites a file of this checkout.

# The tests run one at a time even where bats runs a file's tests side by side: a test that starts
# while another pulls a chart finds the chart's directory before the chart is in it.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

# selected, which matches a monitor with what it selects, and the operator-made targets of the storage
# layer.
load fixtures/monitors

setup_file() {
  # Helm's cache and registry settings stay in the run's own directory, and so does the Docker
  # configuration helm falls back to for credentials, so no login is read.
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLUSTER="$REPO/kubernetes/clusters/lab-sto2"
  KUBE="$(yq -e '.kubernetes' "$REPO/versions.yaml")"
  APP=kube-prometheus-stack
  NAMESPACE=monitoring
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# built: the application as Flux applies it: its app/ built in memory with its ks.yaml, substituting
# strictly the variables of the cluster's example key lists. Writes $BATS_TEST_TMPDIR/built.yaml and
# sets BUILT.
built() {
  local vars="$BATS_TEST_TMPDIR/vars.yaml" ks="$BATS_TEST_TMPDIR/ks.yaml"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$vars"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = $vars' "$vars" "$REPO/kubernetes/apps/base/$NAMESPACE/$APP/ks.yaml" >"$ks"
  BUILT="$BATS_TEST_TMPDIR/built.yaml"
  # Built from the tree's parent, with paths from there, as scripts/kubernetes-check builds.
  (cd "$REPO" && flux build kustomization "$APP" --path "./kubernetes/apps/base/$NAMESPACE/$APP/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute --in-memory-build) >"$BUILT"
}

# pull URL TAG: pulls the chart at URL and TAG once per run, and sets CHART to its archive.
pull() {
  local pulled="$BATS_FILE_TMPDIR/charts/${1##*/}/$2"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$1" --version "$2" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
}

# render: renders the chart the application's HelmRelease installs, built as built() builds it,
# from the URL and tag of its OCIRepository, with the values helm-controller gives the chart: those
# of the ConfigMap the HelmRelease reads, then the HelmRelease's own over them. The chart's resource
# definitions are included, and the monitoring APIs count as present, as prometheus-operator-crds
# installs them before the application starts. Writes $BATS_TEST_TMPDIR/rendered.yaml and sets
# RENDERED, CHART, VALUES and INLINE.
render() {
  local url tag name release namespace
  built
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
  pull "$url" "$tag"
  RENDERED="$BATS_TEST_TMPDIR/rendered.yaml"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" --include-crds \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1alpha1 \
    --values "$VALUES" --values "$INLINE" >"$RENDERED"
}

# one KIND NAME: the rendered object of KIND whose name is NAME, or ends in -NAME, as JSON on one
# line; fails unless there is exactly one.
one() {
  local found
  found="$(yq -N -o json -I0 "select(.kind == \"$1\" and (.metadata.name == \"$2\" or (.metadata.name | test(\"-$2\$\"))))" "$RENDERED")"
  [ "$(grep -c . <<<"$found")" -eq 1 ] || { echo "$1 $2: $(grep -c . <<<"$found") rendered" >&2; return 1; }
  echo "$found"
}

# bytes SIZE: SIZE in bytes, for a Kubernetes quantity such as 20Gi or 20G, or a Prometheus size
# such as 16GB, whose units are powers of 1024.
bytes() {
  local number=${1%%[!0-9]*} unit=${1##*[0-9]}
  case $unit in
    "" | B) echo "$number" ;;
    Ki | KB) echo $((number << 10)) ;;
    Mi | MB) echo $((number << 20)) ;;
    Gi | GB) echo $((number << 30)) ;;
    Ti | TB) echo $((number << 40)) ;;
    k) echo $((number * 1000)) ;;
    M) echo $((number * 1000 ** 2)) ;;
    G) echo $((number * 1000 ** 3)) ;;
    T) echo $((number * 1000 ** 4)) ;;
    *) echo "unknown unit in $1" >&2 && return 1 ;;
  esac
}

@test "The monitoring stack builds with Flux and runs in its own namespace" {
  local overlay enabled depends level objects host
  # The cluster runs the application: its overlay applies the namespace directory and the
  # application's Kustomization.
  overlay="$(kustomize build --load-restrictor LoadRestrictionsNone "$REPO/kubernetes/apps/overlays/lab-sto2")"
  enabled="$(yq -N "select(.kind == \"Kustomization\" and .metadata.name == \"$APP\") | .spec.path" <<<"$overlay")"
  echo "$APP in the overlay: ${enabled:-none}"
  [ "$enabled" = "./apps/base/$NAMESPACE/$APP/app" ]
  # The chart creates objects of the monitoring kinds, which exist once prometheus-operator-crds is
  # Ready.
  depends="$(yq -N "select(.kind == \"Kustomization\" and .metadata.name == \"$APP\") | .spec.dependsOn // [] | .[].name" <<<"$overlay")"
  echo "$APP depends on: ${depends:-nothing}"
  grep -qx prometheus-operator-crds <<<"$depends"
  level="$(yq -N "select(.kind == \"Namespace\" and .metadata.name == \"$NAMESPACE\") | .metadata.labels[\"pod-security.kubernetes.io/enforce\"]" <<<"$overlay")"
  echo "$NAMESPACE's Pod Security level: ${level:-none}"

  render
  objects="$(yq -N 'select(.kind == "Prometheus" or .kind == "Alertmanager"
    or (.kind == "Deployment" and (.spec.template.spec.containers[].image | test("/prometheus-operator/prometheus-operator:"))))
    | .kind + " " + .metadata.namespace + " " + ((.spec.replicas // 1) | tostring)' "$RENDERED" | sort)"
  echo "$objects"
  [ "$objects" = "$(printf '%s\n' "Alertmanager $NAMESPACE 1" "Deployment $NAMESPACE 1" "Prometheus $NAMESPACE 1")" ]
  # node-exporter reads the node through the host's network and process namespaces and its
  # filesystems through host paths, which only the privileged level admits.
  host="$(yq -N "select(.kind == \"DaemonSet\" and .metadata.namespace == \"$NAMESPACE\")
    | select([.spec.template.spec.containers[].image] | any_c(test(\"/node-exporter:\")))
    | .spec.template.spec | (.hostNetwork | tostring) + \" \" + (.hostPID | tostring) + \" \"
      + ((.volumes // []) | any_c(has(\"hostPath\")) | tostring)" "$RENDERED")"
  echo "node-exporter's host network, process namespace and host paths: ${host:-no node-exporter}"
  [ "$host" = "true true true" ]
  [ "$level" = privileged ]
}

@test "The monitoring chart installs no resource definitions" {
  local definitions ours theirs image source
  render
  definitions="$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$RENDERED")"
  echo "definitions in the render: ${definitions:-none}"
  [ -z "$definitions" ]
  # The operator the chart runs is the one whose definitions prometheus-operator-crds installs, so
  # the two charts move together.
  ours="$(helm show chart "$CHART" | yq '.appVersion')"
  image="$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[].image
    | select(test("/prometheus-operator/prometheus-operator:"))' "$RENDERED")"
  source="$REPO/kubernetes/apps/base/kube-system/prometheus-operator-crds/app/ocirepository.yaml"
  pull "$(yq -e '.spec.url' "$source")" "$(yq -e '.spec.ref.tag' "$source")"
  theirs="$(helm show chart "$CHART" | yq '.appVersion')"
  echo "operator image: $image; chart's operator: $ours; definitions' operator: $theirs"
  [ -n "$ours" ]
  [ "$ours" = "$theirs" ]
  [[ $image == *":$ours" ]]
}

@test "The monitoring chart installs no Grafana" {
  local grafana
  render
  grafana="$(yq -N 'select(. != null) | select(
      ((.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet")
        and (.spec.template.spec.containers[].image | test("grafana")))
      or (.kind | test("^Grafana"))
      or ((.kind == "ConfigMap" or .kind == "Secret")
        and (.metadata.labels // {} | (has("grafana_dashboard") or has("grafana_datasource")))))
    | .kind + "/" + .metadata.name' "$RENDERED")"
  echo "Grafana objects: ${grafana:-none}"
  [ -z "$grafana" ]
}

@test "Targets Talos cannot serve are switched off" {
  local alerts proxy
  render
  # The chart's default rules are on, kube-proxy's left out.
  alerts="$(yq -N 'select(.kind == "PrometheusRule") | .spec.groups[].rules[] | select(has("alert")) | .alert' "$RENDERED")"
  echo "$(grep -c . <<<"$alerts") alert rules"
  grep -qx Watchdog <<<"$alerts"
  grep -qx KubeSchedulerDown <<<"$alerts"
  grep -qx KubeControllerManagerDown <<<"$alerts"
  grep -qx etcdMembersDown <<<"$alerts"
  proxy="$(yq -N 'select(. != null) | select(((.kind == "Service" or .kind == "ServiceMonitor") and (.metadata.name | test("kube-proxy")))
      or (.kind == "PrometheusRule" and ([.spec.groups[].rules[] | (.alert // "") + " " + (.expr // "")] | any_c(test("(?i)kube-?proxy")))))
    | .kind + "/" + .metadata.name' "$RENDERED")"
  echo "kube-proxy objects: ${proxy:-none}"
  [ -z "$proxy" ]
}

@test "The control plane is scraped where Talos serves it" {
  local component service monitor endpoint
  render
  # Talos labels the controller manager's and the scheduler's pods as upstream does, and serves
  # both on their secure ports once talos/patches/controlplane/metrics.yaml binds them beyond
  # localhost.
  for component in kube-controller-manager:10257 kube-scheduler:10259; do
    service="$(one Service "${component%:*}")"
    monitor="$(one ServiceMonitor "${component%:*}")"
    echo "${component%:*}: selector $(yq -p json -o json -I0 '.spec.selector' <<<"$service"), ports $(yq -p json -o json -I0 '[.spec.ports[] | [.port, .targetPort]]' <<<"$service"), scheme $(yq -p json '.spec.endpoints[0].scheme // "http"' <<<"$monitor")"
    [ "$(yq -p json -o json -I0 '.spec.selector' <<<"$service")" = "{\"component\":\"${component%:*}\"}" ]
    [ "$(yq -p json -o json -I0 '[.spec.ports[] | [.port, .targetPort]]' <<<"$service")" = "[[${component#*:},${component#*:}]]" ]
    [ "$(yq -p json '.spec.endpoints[0].scheme' <<<"$monitor")" = https ]
  done
  # Talos runs etcd on the host, outside Kubernetes. The API server runs on every control plane on
  # the host's network, so its pods' addresses are the control planes' own.
  service="$(one Service kube-etcd)"
  monitor="$(one ServiceMonitor kube-etcd)"
  endpoint="$(yq -p json -o json -I0 '.spec.endpoints[0]' <<<"$monitor")"
  echo "etcd: selector $(yq -p json -o json -I0 '.spec.selector' <<<"$service"), ports $(yq -p json -o json -I0 '[.spec.ports[] | [.port, .targetPort]]' <<<"$service"), endpoint $endpoint"
  [ "$(yq -p json -o json -I0 '.spec.selector' <<<"$service")" = '{"component":"kube-apiserver"}' ]
  [ "$(yq -p json -o json -I0 '[.spec.ports[] | [.port, .targetPort]]' <<<"$service")" = '[[2381,2381]]' ]
  [ "$(yq -p json '.scheme // "http"' <<<"$endpoint")" = http ]
  # Over plain HTTP a credential would cross the network readable, and etcd's metrics need none.
  [ "$(yq -p json '[.authorization, .bearerTokenFile, .bearerTokenSecret, .basicAuth, .oauth2] | map(select(. != null)) | length' <<<"$endpoint")" -eq 0 ]
}

@test "Prometheus and Alertmanager keep their data on claims from the default storage class" {
  local kind claim size retention cap
  render
  for kind in Prometheus Alertmanager; do
    claim="$(yq -N -o json -I0 "select(.kind == \"$kind\") | .spec.storage.volumeClaimTemplate.spec // {}" "$RENDERED")"
    echo "$kind claims: $claim"
    size="$(yq -p json '.resources.requests.storage // ""' <<<"$claim")"
    [ -n "$size" ]
    [ "$(yq -p json 'has("storageClassName")' <<<"$claim")" = false ]
    [ "$(yq -p json '.accessModes | join(",")' <<<"$claim")" = ReadWriteOnce ]
  done
  retention="$(yq -N 'select(.kind == "Prometheus") | .spec.retention // ""' "$RENDERED")"
  cap="$(yq -N 'select(.kind == "Prometheus") | .spec.retentionSize // ""' "$RENDERED")"
  size="$(yq -N 'select(.kind == "Prometheus") | .spec.storage.volumeClaimTemplate.spec.resources.requests.storage' "$RENDERED")"
  echo "Prometheus keeps $retention, at most $cap, on $size"
  [[ $retention =~ ^[0-9]+[dw]$ ]]
  [ -n "$cap" ]
  # At most 85% of the volume, as Prometheus's storage documentation recommends, leaving room for
  # compaction, which keeps old and new blocks on disk together for a while.
  (($(bytes "$cap") * 100 <= $(bytes "$size") * 85))
}

@test "the jobs and the Service cluster-check reads are the ones the chart's monitors and Prometheus give" {
  local jobs job service port
  render
  # A monitor's job is the value of the label its jobLabel names on the Service it selects, or on
  # the selector itself where it names it, as the API server's and the kubelets' do.
  jobs="$(yq -N -o json -I0 'select(.kind == "Service" or .kind == "ServiceMonitor")' "$RENDERED" | jq -rs '
    [.[] | select(.kind == "Service")] as $services
    | .[] | select(.kind == "ServiceMonitor" and .spec.jobLabel != null)
    | .spec.jobLabel as $label | .spec.selector.matchLabels as $match
    | ($match[$label] // ([$services[] | select(.metadata.labels as $labels | $match | to_entries | all(.value == $labels[.key]))
        | .metadata.labels[$label]] | first)) | select(. != null)' | sort)"
  echo "jobs the chart's monitors give: $(paste -sd' ' <<<"$jobs")"
  for job in $(bash -c ". '$REPO/scripts/lib/cluster.sh'; printf '%s\n' \"\${scrape_jobs[@]}\""); do
    echo "cluster-check reads $job"
    grep -qx -- "$job" <<<"$jobs"
  done
  service="$(bash -c ". '$REPO/scripts/lib/cluster.sh'; echo \$prometheus_service")"
  port="$(bash -c ". '$REPO/scripts/lib/cluster.sh'; echo \$prometheus_port")"
  echo "cluster-check asks the Service $service on port $port in $NAMESPACE"
  [ "$(yq -N "select(.kind == \"Service\" and .metadata.name == \"$service\" and .metadata.namespace == \"$NAMESPACE\")
    | .spec.ports[] | select(.port == $port) | .port" "$RENDERED")" = "$port" ]
}

@test "Prometheus picks up every monitor and rule in the cluster" {
  local selectors
  render
  # An empty selector selects everything; a missing one selects nothing, or for a namespace
  # selector only Prometheus's own namespace.
  # shellcheck disable=SC2016 # $spec is a yq variable.
  selectors="$(yq -N 'select(.kind == "Prometheus") | .spec as $spec
    | ["serviceMonitor", "podMonitor", "probe", "scrapeConfig", "rule"][]
    | . as $kind | [$kind + "Selector", $kind + "NamespaceSelector"][]
    | . + " " + ($spec[.] | to_json(0))' "$RENDERED")"
  echo "$selectors"
  [ "$(grep -c . <<<"$selectors")" -eq 10 ]
  [ "$(grep -vc ' {}$' <<<"$selectors")" -eq 0 ]
}

@test "every values key of kube-prometheus-stack is one its pinned chart or a subchart defines" {
  local dir chart keys unknown="" key prefix found dependency
  local paths='[.. | select(path | length > 0) | path | select(all_c(tag == "!!str")) | join(".")] | .[]'
  render
  dir="$BATS_TEST_TMPDIR/chart"
  mkdir -p "$dir"
  tar -xzf "$CHART" -C "$dir"
  chart="$(echo "$dir"/*/)"
  chart=${chart%/}
  # The chart's values, with each dependency's own under its name, as helm reads them.
  cp "$chart/values.yaml" "$BATS_TEST_TMPDIR/defaults.yaml"
  while read -r dependency; do
    NAME=$dependency yq '{strenv(NAME): .}' "$chart/charts/$dependency/values.yaml" >"$BATS_TEST_TMPDIR/dependency.yaml"
    # shellcheck disable=SC2016 # $item is a yq variable.
    yq ea -i '. as $item ireduce ({}; . *n $item)' "$BATS_TEST_TMPDIR/defaults.yaml" "$BATS_TEST_TMPDIR/dependency.yaml"
  done < <(yq '.dependencies[].name' "$chart/Chart.yaml")
  keys="$BATS_TEST_TMPDIR/keys"
  mkdir -p "$keys"
  yq -N "$paths" "$VALUES" "$INLINE" | sort -u >"$keys/ours"
  yq -N "$paths" "$BATS_TEST_TMPDIR/defaults.yaml" | sort -u >"$keys/chart"
  # A map the chart leaves empty, such as a resources map, takes keys of the user's choosing.
  yq -N '[.. | select(tag == "!!map" and length == 0) | path | join(".")] | .[]' "$BATS_TEST_TMPDIR/defaults.yaml" >"$keys/open"
  while read -r key; do
    found=0
    while read -r prefix; do
      if [[ $key == "$prefix".* ]]; then found=1; fi
    done <"$keys/open"
    # A map the chart's values file leaves out, mentioning it only in a comment, but its templates
    # read whole, such as a Service's selector, takes keys of the user's choosing too. Only a key
    # below the deepest one the values file defines counts.
    prefix=$key
    while ((!found)) && ! grep -qxF -- "$prefix" "$keys/chart"; do
      if grep -rqE -- "\\.Values\\.${prefix//./\\.}([^A-Za-z0-9_.]|\$)" "$chart/templates"; then found=1; fi
      [[ $prefix == *.* ]] || break
      prefix=${prefix%.*}
    done
    ((found)) || unknown+=" $key"
  done < <(comm -23 "$keys/ours" "$keys/chart")
  echo "keys the chart does not define:${unknown:- none}"
  [ -z "$unknown" ]
}

# built_app NAMESPACE APP: the application NAMESPACE/APP as Flux applies it, built as built() builds
# the monitoring stack. Writes $BATS_TEST_TMPDIR/APP-built.yaml and sets BUILT.
built_app() {
  local NAMESPACE=$1 APP=$2
  built
  BUILT="$BATS_TEST_TMPDIR/$2-built.yaml"
  cp "$BATS_TEST_TMPDIR/built.yaml" "$BUILT"
}

# overlay_ks NAME: the cluster overlay's Kustomization NAME as JSON on one line; fails unless there is
# exactly one.
overlay_ks() {
  local found
  found="$(kustomize build --load-restrictor LoadRestrictionsNone "$REPO/kubernetes/apps/overlays/lab-sto2" |
    yq -N -o json -I0 "select(.kind == \"Kustomization\" and .metadata.name == \"$1\")")"
  [ "$(grep -c . <<<"$found")" -eq 1 ] || { echo "the overlay holds $(grep -c . <<<"$found") Kustomizations named $1" >&2; return 1; }
  echo "$found"
}

# depends_on KS_JSON: the names KS_JSON waits for, one per line.
depends_on() {
  yq -p json '.spec.dependsOn // [] | .[].name' <<<"$1"
}

# monitor KIND NAME: the monitor of the built application, as JSON on one line, in the namespace the
# application applies to.
monitor() {
  local found
  found="$(yq -N -o json -I0 "select(.kind == \"$1\" and .metadata.name == \"$2\")" "$BUILT")"
  [ "$(grep -c . <<<"$found")" -eq 1 ] || { echo "$1 $2: $(grep -c . <<<"$found") built" >&2; return 1; }
  echo "$found"
}

# interval_seconds DURATION: a Prometheus duration of seconds or minutes, in seconds.
interval_seconds() {
  case $1 in
    *s) echo "${1%s}" ;;
    *m) echo $((${1%m} * 60)) ;;
    *) echo "unknown duration $1" >&2 && return 1 ;;
  esac
}

# flux_controllers: the Deployments of the pinned Flux Operator's manifests, for the newest Flux 2.x
# they hold, as candidates in the namespace flux-system: the controllers of the instance's
# components, with the label the operator's default profile adds to every pod template
# (internal/builder/profiles.go of the operator). The artifact is the instance's own,
# oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests at the tag its chart is given, pulled
# once per run. Writes $BATS_TEST_TMPDIR/policies.yaml, the artifact's network policies, and sets
# CONTROLLERS.
flux_controllers() {
  local artifact="$BATS_FILE_TMPDIR/flux-manifests" tag dir component
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' <(kustomize build "$CLUSTER/flux-system/flux-operator/app"))"
  [ -n "$tag" ]
  if [ ! -d "$artifact/$tag" ]; then
    mkdir -p "$artifact/$tag"
    flux pull artifact "oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests:v$tag" --output "$artifact/$tag" >/dev/null
  fi
  dir="$(printf '%s\n' "$artifact/$tag"/flux/v2.* | sort -V | tail -1)"
  echo "Flux manifests: ${dir#"$artifact"/}"
  cp "$dir/policies.yaml" "$BATS_TEST_TMPDIR/policies.yaml"
  CONTROLLERS="$(for component in source-controller kustomize-controller helm-controller notification-controller source-watcher; do
    yq -N -o json -I0 'select(.kind == "Deployment") | {"name": ("Deployment/" + .metadata.name), "ns": "flux-system",
      "labels": ((.spec.template.metadata.labels // {}) + {"app.kubernetes.io/part-of": "flux"}),
      "ports": [.spec.template.spec.containers[].ports[]?.name]}' "$dir/$component.yaml"
  done | jq -s 'map(select(.name != null))')"
}

@test "Flux's controllers and the state of its resources are scraped" {
  local ks operator values service interval reporting scraped candidates
  # The application is enabled in the overlay and waits for the monitoring definitions, so a
  # from-nothing bootstrap, which installs Flux first, never meets a ServiceMonitor before its kind.
  ks="$(overlay_ks flux-monitoring)"
  [ "$(yq -p json '.spec.path' <<<"$ks")" = ./apps/base/monitoring/flux-monitoring/app ]
  echo "flux-monitoring depends on: $(depends_on "$ks" | xargs)"
  depends_on "$ks" | grep -qx prometheus-operator-crds
  built_app monitoring flux-monitoring

  # The operator's metrics Service, as the chart the cluster directory installs renders it.
  operator="$CLUSTER/flux-system/flux-operator/app"
  kustomize build "$operator" >"$BATS_TEST_TMPDIR/operator-app.yaml"
  values="$BATS_TEST_TMPDIR/operator-values.yaml"
  yq -N 'select(.kind == "ConfigMap" and (.metadata.name | test("^flux-operator-values"))) | .data["values.yaml"]' \
    "$BATS_TEST_TMPDIR/operator-app.yaml" >"$values"
  pull "$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BATS_TEST_TMPDIR/operator-app.yaml")" \
    "$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BATS_TEST_TMPDIR/operator-app.yaml")"
  helm template flux-operator "$CHART" --namespace flux-system --kube-version "$KUBE" --values "$values" >"$BATS_TEST_TMPDIR/operator.yaml"
  candidates="$(yq -N -o json -I0 'select(.kind == "Service") | {"name": ("Service/" + .metadata.name), "ns": .metadata.namespace,
    "labels": .metadata.labels, "ports": [.spec.ports[].name]}' "$BATS_TEST_TMPDIR/operator.yaml" | jq -s 'map(select(.name != null))')"
  echo "the operator's Services: $(jq -c '[.[] | [.name, .ns, .ports]]' <<<"$candidates")"
  service="$(monitor ServiceMonitor flux-operator)"
  scraped="$(selected "$service" "$candidates")"
  echo "ServiceMonitor flux-operator scrapes: ${scraped:-nothing}"
  [ "$scraped" = Service/flux-operator ]
  [ "$(yq -p json '.spec.endpoints[0].path' <<<"$service")" = /metrics ]
  # The job is the Service's name, which the alerts select on.
  [ "$(yq -p json '.spec.jobLabel // ""' <<<"$service")" = "" ]
  # The state of every resource is refreshed with the operator's report, every five minutes unless
  # told otherwise: the alerts count in minutes, so the report and the scrape are at most a minute.
  reporting="$(yq '.reporting.interval' "$values")"
  interval="$(yq -p json '.spec.endpoints[0].interval' <<<"$service")"
  echo "the operator reports every $reporting, Prometheus scrapes every $interval"
  [ "$(interval_seconds "$reporting")" -le 60 ]
  [ "$(interval_seconds "$interval")" -le 60 ]

  # The controllers, as the operator's manifests for the instance's components have them.
  flux_controllers
  echo "the instance's Deployments: $(jq -c '[.[] | [.name, .ports]]' <<<"$CONTROLLERS")"
  scraped="$(selected "$(monitor PodMonitor flux-controllers)" "$CONTROLLERS" | sort | xargs)"
  echo "PodMonitor flux-controllers scrapes: ${scraped:-nothing}"
  [ "$scraped" = "Deployment/helm-controller Deployment/kustomize-controller Deployment/notification-controller Deployment/source-controller Deployment/source-watcher" ]
  # Flux's network policies, which the instance turns on, admit every namespace to the metrics port
  # of every pod in flux-system, the operator's included.
  [ "$(yq -N 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-scraping") | .spec.ingress[0].ports[0].port' "$BATS_TEST_TMPDIR/policies.yaml")" = 8080 ]
  [ "$(yq -N 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-scraping") | .spec.ingress[0].from[0] | to_json(0)' "$BATS_TEST_TMPDIR/policies.yaml")" = '{"namespaceSelector":{}}' ]
  [ "$(yq -N 'select(.kind == "NetworkPolicy" and .metadata.name == "allow-scraping") | .spec.podSelector | to_json(0)' "$BATS_TEST_TMPDIR/policies.yaml")" = '{}' ]
}

@test "The workers' BGP sessions are scraped without changing how Cilium is first installed" {
  local ks app url tag render candidates scraped pod listener
  app="$REPO/kubernetes/apps/base/kube-system/cilium/app"
  # The application waits for Cilium, whose agents it scrapes, and for the monitoring definitions.
  ks="$(overlay_ks cilium-monitoring)"
  [ "$(yq -p json '.spec.path' <<<"$ks")" = ./apps/base/kube-system/cilium-monitoring/app ]
  echo "cilium-monitoring depends on: $(depends_on "$ks" | xargs)"
  depends_on "$ks" | grep -qx cilium
  depends_on "$ks" | grep -qx prometheus-operator-crds
  # Cilium is installed before the definitions exist and the objects that follow it are no later for
  # a monitor: neither names the monitoring definitions in dependsOn.
  [ "$(depends_on "$(overlay_ks cilium)" | grep -c prometheus || true)" -eq 0 ]
  [ "$(depends_on "$(overlay_ks cilium-bgp)" | grep -c prometheus || true)" -eq 0 ]
  built_app kube-system cilium-monitoring

  # The chart as scripts/install-cilium installs it, from the values file it passes as it is, with
  # the monitoring APIs present so that only the values keep a monitor out.
  url="$(yq -e '.spec.url' "$app/ocirepository.yaml")"
  tag="$(yq -e '.spec.ref.tag' "$app/ocirepository.yaml")"
  pull "$url" "$tag"
  render="$BATS_TEST_TMPDIR/cilium.yaml"
  helm template cilium "$CHART" --namespace kube-system --kube-version "$KUBE" \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor \
    --api-versions monitoring.coreos.com/v1/PodMonitor --values "$app/values.yaml" >"$render"
  [ -z "$(yq -N 'select(. != null) | select(.apiVersion | test("^monitoring.coreos.com/")) | .kind + "/" + .metadata.name' "$render")" ]
  # The agents serve their metrics, on the port the chart names prometheus, 9962 on every address of
  # the node, as the agents run on the host's network.
  [ "$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "cilium-config") | .data["prometheus-serve-addr"]' "$render")" = ':9962' ]
  [ "$(yq -N 'select(.kind == "DaemonSet" and .metadata.name == "cilium") | .spec.template.spec.hostNetwork' "$render")" = true ]
  candidates="$(yq -N -o json -I0 'select(.kind == "DaemonSet" and .metadata.name == "cilium") | {"name": ("DaemonSet/" + .metadata.name),
    "ns": .metadata.namespace, "labels": .spec.template.metadata.labels,
    "ports": [.spec.template.spec.containers[].ports[]? | .name]}' "$render" | jq -s 'map(select(.name != null))')"
  echo "the agents' pod template: $(jq -c '[.[] | [.name, .ns, .labels, .ports]]' <<<"$candidates")"
  [ "$(jq -r '[.[].name] | join(" ")' <<<"$candidates")" = DaemonSet/cilium ]
  pod="$(yq -N 'select(.kind == "DaemonSet" and .metadata.name == "cilium") | .spec.template.spec.containers[].ports[] | select(.name == "prometheus") | .containerPort' "$render")"
  [ "$pod" = 9962 ]
  scraped="$(selected "$(monitor PodMonitor cilium-agent)" "$candidates")"
  echo "PodMonitor cilium-agent scrapes: ${scraped:-nothing}"
  [ "$scraped" = DaemonSet/cilium ]
  # The job is named by the monitor, so the alerts do not depend on how Prometheus names one, and
  # the node is the label that names a worker.
  [ "$(monitor PodMonitor cilium-agent | yq -p json '.spec.podMetricsEndpoints[0].relabelings[] | select(.targetLabel == "job") | .replacement')" = cilium-agent ]
  [ "$(monitor PodMonitor cilium-agent | yq -p json '.spec.podMetricsEndpoints[0].relabelings[] | select(.targetLabel == "node") | .sourceLabels[0]')" = __meta_kubernetes_pod_node_name ]
  # The nodes' firewall admits the port from the nodes, which a pod on another node reaches a node
  # from, and from the pods, and on every node, as it does node-exporter's.
  listener="$(yq -o json -I0 '.listeners[] | select(.ports | contains([9962]))' "$REPO/talos/firewall.yaml")"
  echo "the firewall's listener on 9962: ${listener:-none}"
  [ "$(yq -p json '.protocol' <<<"$listener")" = tcp ]
  [ "$(yq -p json '.nodes' <<<"$listener")" = all ]
  [ "$(yq -p json '.from | join(" ")' <<<"$listener")" = "members pods" ]
}

@test "The storage layer is scraped" {
  local ks dir recorded operator candidates scraped service
  dir="$REPO/kubernetes/apps/base/piraeus-datastore/linstor-monitoring"
  ks="$(overlay_ks linstor-monitoring)"
  [ "$(yq -p json '.spec.path' <<<"$ks")" = ./apps/base/piraeus-datastore/linstor-monitoring/app ]
  echo "linstor-monitoring depends on: $(depends_on "$ks" | xargs)"
  depends_on "$ks" | grep -qx prometheus-operator-crds
  built_app piraeus-datastore linstor-monitoring

  # The operator makes the controller's Service and the satellites' pods at run time, so they are
  # not in the render: the monitors' selectors and ports are read from the operator's templates
  # (pkg/resources/cluster/controller/controller-service.yaml and
  # pkg/resources/satellite/satellite/daemonset.yaml) at the version the monitors record, which must
  # be the version the cluster runs, or the templates are read again.
  recorded="$(sed -n 's/^# piraeus-operator-templates: *\(v[0-9][0-9.]*\) *$/\1/p' "$dir/app/monitors.yaml")"
  operator="v$(yq -e '.spec.ref.tag' "$REPO/kubernetes/apps/base/piraeus-datastore/piraeus-operator/app/ocirepository.yaml")"
  echo "the monitors were read at the operator's templates of $recorded; the cluster runs $operator"
  [ -n "$recorded" ]
  [ "$recorded" = "$operator" ]
  candidates="$(linstor_targets)"
  # The controller's REST port serves LINSTOR's own metrics at /metrics over plain HTTP: the
  # LinstorCluster configures no TLS for it.
  service="$(monitor ServiceMonitor linstor-controller)"
  scraped="$(selected "$service" "$(jq -c '[.[] | select(.name | startswith("Service/"))]' <<<"$candidates")")"
  echo "ServiceMonitor linstor-controller scrapes: ${scraped:-nothing}"
  [ "$scraped" = Service/linstor-controller ]
  [ "$(yq -p json '.spec.endpoints[0].path' <<<"$service")" = /metrics ]
  [ "$(yq -p json '.spec.endpoints[0].scheme // "http"' <<<"$service")" = http ]
  [ "$(yq '.spec.apiTLS // "none"' "$REPO/kubernetes/apps/base/piraeus-datastore/linstor-cluster/app/linstorcluster.yaml")" = none ]
  # The satellites' DRBD reactor serves the state of each DRBD resource on its own port, in the
  # satellite's pod, which no configuration of the tree puts on the node's network, so no node
  # firewall rule is involved; the monitor names the node a satellite runs on, as that is a worker.
  scraped="$(selected "$(monitor PodMonitor linstor-satellite)" "$(jq -c '[.[] | select(.name | startswith("Pod/"))]' <<<"$candidates")")"
  echo "PodMonitor linstor-satellite scrapes: ${scraped:-nothing}"
  [ "$scraped" = Pod/linstor-satellite ]
  [ "$(monitor PodMonitor linstor-satellite | yq -p json '.spec.podMetricsEndpoints[0].relabelings[] | select(.targetLabel == "job") | .replacement')" = linstor-satellite ]
  [ "$(monitor PodMonitor linstor-satellite | yq -p json '.spec.podMetricsEndpoints[0].relabelings[] | select(.targetLabel == "node") | .sourceLabels[0]')" = __meta_kubernetes_pod_node_name ]
  [ -z "$(yq -N 'select(.kind == "LinstorSatelliteConfiguration") | .spec.podTemplate.spec.hostNetwork | select(. == true)' \
    "$REPO/kubernetes/apps/base/piraeus-datastore/linstor-cluster/app/talos.yaml" "$REPO/kubernetes/apps/base/piraeus-datastore/linstor-cluster/app/storage-pool.yaml")" ]
}
