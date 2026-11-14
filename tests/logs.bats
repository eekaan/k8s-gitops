#!/usr/bin/env bats
# Proves features/logs.feature, except the scenario vector-check proves; each test carries its
# scenario's title. Needs helm, flux, kustomize, just, yq, jq and awk on PATH (the versions pinned for
# the repository). Each chart is pulled once per run from its public registry; building and
# rendering are offline. The applications are built in memory, so no build rewrites a file of this
# checkout.

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
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLUSTER="$REPO/kubernetes/clusters/lab-sto2"
  KUBE="$(yq -e '.kubernetes' "$REPO/versions.yaml")"
  NAMESPACE=monitoring
  STORE=victoria-logs
  COLLECTOR=vector
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# built APP: the application APP of the monitoring namespace as Flux applies it: its app/ built in
# memory with its ks.yaml, substituting strictly the variables of the cluster's example key lists.
# Writes $BATS_TEST_TMPDIR/APP-built.yaml and sets BUILT.
built() {
  local app=$1 vars="$BATS_TEST_TMPDIR/vars.yaml" ks="$BATS_TEST_TMPDIR/$1-ks.yaml"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$vars"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = $vars' "$vars" "$REPO/kubernetes/apps/base/$NAMESPACE/$app/ks.yaml" >"$ks"
  BUILT="$BATS_TEST_TMPDIR/$app-built.yaml"
  # flux build reads only paths below the working directory.
  (cd "$REPO" && flux build kustomization "$app" --path "./kubernetes/apps/base/$NAMESPACE/$app/app" \
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

# render APP: renders the chart APP's HelmRelease installs, built as built() builds it, from the URL
# and tag of its OCIRepository, with the values helm-controller gives the chart: those of the
# ConfigMap the HelmRelease reads, then the HelmRelease's own over them. The monitoring, Gateway API
# and Grafana dashboard APIs count as present, by group and version and by kind, as charts test for
# either, so that only the values keep such objects out. Writes $BATS_TEST_TMPDIR/APP.yaml and sets
# RENDERED, CHART, VALUES and INLINE.
render() {
  local app=$1 url tag name release namespace
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
  pull "$url" "$tag"
  RENDERED="$BATS_TEST_TMPDIR/$app.yaml"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" --include-crds \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor \
    --api-versions monitoring.coreos.com/v1/PodMonitor \
    --api-versions gateway.networking.k8s.io/v1 --api-versions gateway.networking.k8s.io/v1/HTTPRoute \
    --api-versions grafana.integreatly.org/v1beta1 --api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
    --values "$VALUES" --values "$INLINE" >"$RENDERED"
}

# overlay: the cluster's overlay as the root Kustomization builds it. Sets OVERLAY.
overlay() {
  OVERLAY="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "$REPO/kubernetes/apps/overlays/lab-sto2" >"$OVERLAY"
}

# collector_config: the configuration the rendered collector runs with, as JSON: the ConfigMap its
# DaemonSet mounts as config. Needs render vector first. Writes $BATS_TEST_TMPDIR/vector.json and
# sets CONFIG.
collector_config() {
  local map
  map="$(yq -N 'select(.kind == "DaemonSet") | .spec.template.spec.volumes[] | select(.name == "config")
    | [.configMap.name // "", (.projected.sources // [] | .[] | .configMap.name // "")] | .[]' "$RENDERED" | grep . || true)"
  [ "$(grep -c . <<<"$map")" -eq 1 ] || { echo "the collector mounts as config: ${map:-nothing}"; return 1; }
  CONFIG="$BATS_TEST_TMPDIR/vector.json"
  yq -N -o json "select(.kind == \"ConfigMap\" and .metadata.name == \"$map\") | .data[\"vector.yaml\"] | from_yaml" \
    "$RENDERED" >"$CONFIG"
  [ "$(jq -r 'type' "$CONFIG")" = object ] || { echo "no vector.yaml in the ConfigMap $map"; return 1; }
}

# store_service: "name namespace port" of the rendered store's Service and the one port it serves,
# whose target is the port the store listens on. Needs render victoria-logs first.
store_service() {
  local listen
  listen="$(yq -N 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].args[]
    | select(test("^--httpListenAddr=")) | sub(".*:"; "")' "$RENDERED")"
  # shellcheck disable=SC2016 # $ports, $service and $listen are jq variables.
  yq -N -o json -I0 'select(.kind == "Service" or .kind == "StatefulSet")' "$RENDERED" | jq -rs --arg listen "$listen" '
    (.[] | select(.kind == "StatefulSet") | .spec.template.spec.containers[0].ports // []) as $ports
    | .[] | select(.kind == "Service") | . as $service | .spec.ports[] | . as $port
    | select(($port.targetPort | tostring) == $listen
        or any($ports[]; .name == ($port.targetPort | tostring) and (.containerPort | tostring) == $listen))
    | "\($service.metadata.name) \($service.metadata.namespace) \($port.port)"'
}

# scaled NUMBER FACTOR: NUMBER, which may have a fraction, times FACTOR, in whole bytes.
scaled() {
  awk -v number="$1" -v factor="$2" 'BEGIN { printf "%.0f\n", number * factor }'
}

# vl_bytes SIZE: SIZE in bytes as VictoriaLogs reads a size flag (lib/flagutil/bytes.go, which
# VictoriaLogs vendors): a number, which may have a fraction, with one of the suffixes KB, MB, GB,
# TB (powers of 1000) or KiB, MiB, GiB, TiB (powers of 1024) in any case, or none. Fails on
# anything else, such as the Kubernetes suffix Gi, which VictoriaLogs refuses at start.
vl_bytes() {
  local size=${1^^}
  size=${size//I/i}
  [[ $size =~ ^([0-9]+(\.[0-9]*)?|\.[0-9]+)(KB|MB|GB|TB|KiB|MiB|GiB|TiB)?$ ]] ||
    { echo "$1 is not a size VictoriaLogs reads" >&2; return 1; }
  case ${BASH_REMATCH[3]} in
    "") scaled "${BASH_REMATCH[1]}" 1 ;;
    KB) scaled "${BASH_REMATCH[1]}" 1e3 ;;
    MB) scaled "${BASH_REMATCH[1]}" 1e6 ;;
    GB) scaled "${BASH_REMATCH[1]}" 1e9 ;;
    TB) scaled "${BASH_REMATCH[1]}" 1e12 ;;
    KiB) scaled "${BASH_REMATCH[1]}" 1024 ;;
    MiB) scaled "${BASH_REMATCH[1]}" 1048576 ;;
    GiB) scaled "${BASH_REMATCH[1]}" 1073741824 ;;
    TiB) scaled "${BASH_REMATCH[1]}" 1099511627776 ;;
  esac
}

# k8s_bytes QUANTITY: QUANTITY in bytes as Kubernetes reads a quantity: a number, which may have a
# fraction, with one of the case-sensitive suffixes Ki, Mi, Gi, Ti, Pi, Ei (powers of 1024) or k, M,
# G, T, P, E (powers of 1000), or none, or a whole number with a decimal exponent such as 2e10.
# Fails on anything else, such as the VictoriaLogs suffix GiB, which Kubernetes refuses.
k8s_bytes() {
  if [[ $1 =~ ^([0-9]+)[eE]([0-9]+)$ ]]; then
    scaled "${BASH_REMATCH[1]}" "1e${BASH_REMATCH[2]}"
    return
  fi
  [[ $1 =~ ^([0-9]+(\.[0-9]*)?|\.[0-9]+)(Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$ ]] ||
    { echo "$1 is not a quantity Kubernetes reads" >&2; return 1; }
  case ${BASH_REMATCH[3]} in
    "") scaled "${BASH_REMATCH[1]}" 1 ;;
    k) scaled "${BASH_REMATCH[1]}" 1e3 ;;
    M) scaled "${BASH_REMATCH[1]}" 1e6 ;;
    G) scaled "${BASH_REMATCH[1]}" 1e9 ;;
    T) scaled "${BASH_REMATCH[1]}" 1e12 ;;
    P) scaled "${BASH_REMATCH[1]}" 1e15 ;;
    E) scaled "${BASH_REMATCH[1]}" 1e18 ;;
    Ki) scaled "${BASH_REMATCH[1]}" 1024 ;;
    Mi) scaled "${BASH_REMATCH[1]}" 1048576 ;;
    Gi) scaled "${BASH_REMATCH[1]}" 1073741824 ;;
    Ti) scaled "${BASH_REMATCH[1]}" 1099511627776 ;;
    Pi) scaled "${BASH_REMATCH[1]}" 1125899906842624 ;;
    Ei) scaled "${BASH_REMATCH[1]}" 1152921504606846976 ;;
  esac
}

# monitor_targets: one line per ServiceMonitor or PodMonitor in $RENDERED, "Kind/name -> Kind/name"
# naming each rendered object it scrapes: for a ServiceMonitor, a Service whose labels its selector
# matches and that names every port it scrapes; for a PodMonitor, a workload whose pod template
# does so. A monitor that scrapes none of them ends in "-> none".
monitor_targets() {
  yq -N -o json -I0 'select(. != null)' "$RENDERED" | jq -rs '. as $all | .[]
    | select(.kind == "ServiceMonitor" or .kind == "PodMonitor") | . as $monitor
    | ($monitor.spec.selector.matchLabels // {}) as $selector
    | [($monitor.spec.endpoints // $monitor.spec.podMetricsEndpoints // [])[].port] as $ports
    | [$all[] | if $monitor.kind == "ServiceMonitor" then
          select(.kind == "Service")
          | {name: ("Service/" + .metadata.name), labels: (.metadata.labels // {}), ports: [.spec.ports[]?.name]}
        else
          select(.kind == "Deployment" or .kind == "DaemonSet" or .kind == "StatefulSet")
          | {name: (.kind + "/" + .metadata.name), labels: (.spec.template.metadata.labels // {}),
             ports: [.spec.template.spec.containers[].ports[]?.name]}
        end
      | select(.labels as $labels | ($selector | length > 0)
          and ($selector | to_entries | all($labels[.key] == .value)))
      | select(.ports as $named | ($ports | length > 0) and ($ports | all(. as $port | any($named[]; . == $port))))
      | .name] as $targets
    | "\($monitor.kind)/\($monitor.metadata.name) -> \(if ($targets | length) > 0 then $targets | join(" ") else "none" end)"'
}

# defined_keys APP: fails, naming them, on keys of APP's values file or of its HelmRelease's own
# values that the pinned chart's values do not define. Keys of maps only: list items are the
# chart's input, not keys. A map the chart leaves empty, such as a resources map, takes keys of the
# user's choosing.
defined_keys() {
  local app=$1 keys="$BATS_TEST_TMPDIR/keys" unknown="" key map open
  local paths='[.. | select(path | length > 0) | path | select(all_c(tag == "!!str")) | join(".")] | .[]'
  render "$app"
  mkdir -p "$keys"
  yq -N "$paths" "$VALUES" "$INLINE" | sort -u >"$keys/$app.ours"
  helm show values "$CHART" >"$keys/$app.defaults"
  yq -N "$paths" "$keys/$app.defaults" | sort -u >"$keys/$app.chart"
  open="$(yq -N '[.. | select(tag == "!!map" and length == 0) | path | join(".")] | .[]' "$keys/$app.defaults")"
  while read -r key; do
    for map in $open; do
      if [[ $key == "$map".* ]]; then continue 2; fi
    done
    unknown+=" $key"
  done < <(comm -23 "$keys/$app.ours" "$keys/$app.chart")
  echo "$app: keys the chart does not define:${unknown:- none}"
  [ -z "$unknown" ]
}

@test "The log store builds with Flux and runs once in the monitoring namespace" {
  local enabled namespace workloads budgets dashboards
  # The cluster runs the application and its namespace directory: its overlay applies both.
  overlay
  enabled="$(yq -N "select(.kind == \"Kustomization\" and .metadata.name == \"$STORE\") | .spec.path" "$OVERLAY")"
  namespace="$(yq -N "select(.kind == \"Namespace\" and .metadata.name == \"$NAMESPACE\") | .metadata.name" "$OVERLAY")"
  echo "$STORE in the overlay: ${enabled:-none}; namespace ${namespace:-none}"
  [ "$enabled" = "./apps/base/$NAMESPACE/$STORE/app" ]
  [ "$namespace" = "$NAMESPACE" ]

  render "$STORE"
  workloads="$(yq -N 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet")
    | .kind + " " + .metadata.namespace + " " + ((.spec.replicas // 1) | tostring) + " "
      + ([.spec.template.spec.containers[].image | select(test("/victoria-logs:"))] | length | tostring)' "$RENDERED")"
  echo "workloads (kind, namespace, replicas, VictoriaLogs containers): ${workloads:-none}"
  [ "$workloads" = "StatefulSet $NAMESPACE 1 1" ]
  # A budget that keeps the one replica available would stop every drain of its node.
  budgets="$(yq -N 'select(.kind == "PodDisruptionBudget") | .metadata.name' "$RENDERED")"
  echo "disruption budgets: ${budgets:-none}"
  [ -z "$budgets" ]
  dashboards="$(yq -N 'select(. != null) | select(.kind == "GrafanaDashboard"
    or (.kind == "ConfigMap" and (.metadata.labels // {} | has("grafana_dashboard"))))
    | .kind + "/" + .metadata.name' "$RENDERED")"
  echo "dashboards: ${dashboards:-none}"
  [ -z "$dashboards" ]
}

@test "The log store keeps two weeks of logs on a claim from the default storage class" {
  local args retention cap path claims claim size mounted capped claimed
  render "$STORE"
  args="$(yq -N 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].args[]' "$RENDERED")"
  retention="$(grep -E '^--retentionPeriod=' <<<"$args" | cut -d= -f2-)" || true
  cap="$(grep -E '^--retention\.maxDiskSpaceUsageBytes=' <<<"$args" | cut -d= -f2-)" || true
  path="$(grep -E '^--storageDataPath=' <<<"$args" | cut -d= -f2-)" || true
  claims="$(yq -N -o json -I0 'select(.kind == "StatefulSet") | .spec.volumeClaimTemplates // [] | .[]' "$RENDERED")"
  echo "retention: ${retention:-none}; size cap: ${cap:-none}; data in: ${path:-none}; claims: ${claims:-none}"
  [ "$retention" = 14d ]
  [ -n "$cap" ]
  [ "$(grep -c . <<<"$claims")" -eq 1 ]
  claim=$claims
  size="$(yq -p json '.spec.resources.requests.storage // ""' <<<"$claim")"
  [ -n "$size" ]
  [ "$(yq -p json '.spec | has("storageClassName")' <<<"$claim")" = false ]
  [ "$(yq -p json '.spec.accessModes | join(",")' <<<"$claim")" = ReadWriteOnce ]
  # The data directory is on the claim.
  mounted="$(yq -N "select(.kind == \"StatefulSet\") | .spec.template.spec.containers[0].volumeMounts[]
    | select(.name == \"$(yq -p json '.metadata.name' <<<"$claim")\") | .mountPath" "$RENDERED")"
  echo "the claim is mounted at: ${mounted:-nowhere}"
  [ -n "$path" ]
  [ "$mounted" = "$path" ]
  # VictoriaLogs checks its disk use only now and then, and stops taking logs when the volume is
  # full, so its documentation asks for a fifth of the volume to stay free. Each size is read the way
  # its reader reads it: the cap by VictoriaLogs, which refuses a size it cannot read, and the claim
  # by Kubernetes.
  capped="$(vl_bytes "$cap")"
  claimed="$(k8s_bytes "$size")"
  echo "cap: $capped bytes; claim: $claimed bytes"
  ((capped * 100 <= claimed * 80))
}

@test "A collector runs on every node, control planes included" {
  local enabled daemonsets others tolerations placement
  overlay
  enabled="$(yq -N "select(.kind == \"Kustomization\" and .metadata.name == \"$COLLECTOR\") | .spec.path" "$OVERLAY")"
  echo "$COLLECTOR in the overlay: ${enabled:-none}"
  [ "$enabled" = "./apps/base/$NAMESPACE/$COLLECTOR/app" ]

  render "$COLLECTOR"
  daemonsets="$(yq -N 'select(.kind == "DaemonSet") | .metadata.namespace + "/" + .metadata.name' "$RENDERED")"
  others="$(yq -N 'select(.kind == "Deployment" or .kind == "StatefulSet") | .kind + "/" + .metadata.name' "$RENDERED")"
  echo "DaemonSets: ${daemonsets:-none}; other workloads: ${others:-none}"
  [ "$(grep -c . <<<"$daemonsets")" -eq 1 ]
  [ "${daemonsets%%/*}" = "$NAMESPACE" ]
  [ -z "$others" ]
  tolerations="$(yq -N -o json -I0 'select(.kind == "DaemonSet") | .spec.template.spec.tolerations // []' "$RENDERED")"
  echo "tolerations: $tolerations"
  # A toleration without a key that only needs the key to exist matches every taint, of every effect.
  [ "$(jq '[.[] | select((.key // "") == "" and .operator == "Exists" and (.effect // "") == "")] | length' <<<"$tolerations")" -ge 1 ]
  # The taint Talos gives every control plane, in particular.
  [ "$(jq '[.[] | select(((.key // "") == "" and .operator == "Exists")
      or (.key == "node-role.kubernetes.io/control-plane" and .operator == "Exists"))
    | select((.effect // "") == "" or .effect == "NoSchedule")] | length' <<<"$tolerations")" -ge 1 ]
  placement="$(yq -N -o json -I0 'select(.kind == "DaemonSet") | .spec.template.spec
    | {"nodeSelector": (.nodeSelector // {}), "affinity": (.affinity.nodeAffinity // {}), "nodeName": (.nodeName // "")}' "$RENDERED")"
  echo "placement: $placement"
  [ "$placement" = '{"nodeSelector":{},"affinity":{},"nodeName":""}' ]
}

@test "The collector ships every pod's logs and every Talos service's log to the store" {
  local service name namespace port domain pods restricted files include sinks upstream source
  render "$STORE"
  service="$(store_service)"
  echo "the store's Service: ${service:-none}"
  [ "$(grep -c . <<<"$service")" -eq 1 ]
  read -r name namespace port <<<"$service"
  domain="$(yq -N 'select(.kind == "KubeNetworkConfig") | .dnsDomain' "$REPO/talos/patches/all/cluster-network.yaml")"
  [ -n "$domain" ]

  render "$COLLECTOR"
  collector_config
  # Every pod's log files: one kubernetes_logs source, which nothing narrows to some pods.
  pods="$(jq -r '.sources | to_entries[] | select(.value.type == "kubernetes_logs") | .key' "$CONFIG")"
  restricted="$(jq -r '.sources[] | select(.type == "kubernetes_logs") | keys[]
    | select(test("selector|exclude|include|namespace"))' "$CONFIG")"
  echo "pod log sources: ${pods:-none}; narrowed by: ${restricted:-nothing}"
  [ "$(grep -c . <<<"$pods")" -eq 1 ]
  [ -z "$restricted" ]
  # Talos writes each service's log, the kernel's included, to /var/log/<service>.log and renames it
  # to <service>.log.1 at 5 MiB: one file source reads both, and nothing below /var/log, where the
  # pods' and the API server's audit logs are.
  files="$(jq -r '.sources | to_entries[] | select(.value.type == "file") | .key' "$CONFIG")"
  include="$(jq -r '.sources[] | select(.type == "file") | .include // [] | sort | join(" ")' "$CONFIG")"
  echo "file sources: ${files:-none}; reading: ${include:-nothing}"
  [ "$(grep -c . <<<"$files")" -eq 1 ]
  [ "$include" = "/var/log/*.log /var/log/*.log.1" ]
  # One sink for the store, at its Service's name in the cluster's DNS domain, and both sources reach
  # it, directly or through transforms.
  sinks="$(jq -r '.sinks[] | select(.type == "elasticsearch") | .endpoints // [] | join(" ")' "$CONFIG")"
  echo "store sinks: ${sinks:-none}"
  [ "$sinks" = "http://$name.$namespace.svc.$domain:$port/insert/elasticsearch/" ]
  # shellcheck disable=SC2016 # $c and $n are jq variables.
  upstream="$(jq -r 'def up($c): . as $n | if $c.sources[$n] != null then [$n]
      else [($c.transforms[$n].inputs // [])[] | up($c)[]] end;
    . as $c | .sinks[] | select(.type == "elasticsearch") | [.inputs[] | up($c)[]] | unique | .[]' "$CONFIG")"
  echo "sources the store sink receives: $(paste -sd' ' - <<<"$upstream")"
  for source in "$pods" "$files"; do
    grep -qx -- "$source" <<<"$upstream" || { echo "$source does not reach the store"; return 1; }
  done
}

@test "The collector ships nothing from the API server's audit log directory" {
  local root pattern listed expected exclude pods
  render "$COLLECTOR"
  collector_config
  # /var/log as Talos lays it out: its services' logs and their rotated files at the top, the pods'
  # under pods/ with links under containers/, and the API server's audit logs under audit/kube on a
  # control plane (constants.KubernetesAuditLogDir), the current one and one rotated with its time.
  root="$BATS_TEST_TMPDIR/var/log"
  mkdir -p "$root/audit/kube" "$root/pods/monitoring_vector-x1y2z_0a1b/vector" "$root/containers"
  touch "$root/kernel.log" "$root/kernel.log.1" "$root/kubelet.log" "$root/auditd.log" \
    "$root/audit/kube/kube-apiserver.log" "$root/audit/kube/kube-apiserver-2026-11-14T12-00-00.000.log" \
    "$root/pods/monitoring_vector-x1y2z_0a1b/vector/0.log" "$root/containers/vector-x1y2z_monitoring_vector-0a1b.log"
  exclude="$(jq -r '[.sources[] | select(.type == "file") | .exclude // [] | .[]] | length' "$CONFIG")"
  [ "$exclude" -eq 0 ]
  # Vector walks a pattern one path component at a time, as bash does, so a * stays in its directory.
  listed="$(
    shopt -s globstar nullglob
    while IFS= read -r pattern; do
      [[ $pattern == /var/log/* ]] || { echo "outside /var/log: $pattern"; continue; }
      # shellcheck disable=SC2086 # The pattern is expanded as a glob.
      printf '%s\n' "$root"${pattern#/var/log}
    done < <(jq -r '.sources[] | select(.type == "file") | .include // [] | .[]' "$CONFIG") | sed "s#^$root#/var/log#" | sort -u
  )"
  echo "the file source reads: $(paste -sd' ' - <<<"$listed")"
  expected="$(printf '%s\n' /var/log/auditd.log /var/log/kernel.log /var/log/kernel.log.1 /var/log/kubelet.log | sort)"
  [ "$listed" = "$expected" ]
  # The pod-log source reads /var/log/pods, and nothing in its configuration points it elsewhere.
  pods="$(jq -r '.sources[] | select(.type == "kubernetes_logs") | keys[] | select(test("path|glob|include|exclude"))' "$CONFIG")"
  echo "pod-log source path settings: ${pods:-none}"
  [ -z "$pods" ]
}

@test "The collector's configuration is checked with the image the collector runs" {
  local runs checked pin
  render "$COLLECTOR"
  runs="$(yq -N 'select(.kind == "DaemonSet") | .spec.template.spec.containers[] | select(.name == "vector") | .image' "$RENDERED")"
  echo "the collector runs: ${runs:-nothing}"
  [ -n "$runs" ]
  # What each recipe would run, with the justfile's variables filled in.
  run just --justfile "$REPO/justfile" --dry-run vector-check
  [ "$status" -eq 0 ]
  checked="$(grep -oE "[a-z0-9.-]+/timberio/vector[^[:space:]'\"]*" <<<"$output" | sort -u)"
  echo "vector-check runs: ${checked:-nothing}"
  [ "$(grep -c . <<<"$checked")" -eq 1 ]
  # The same repository, version and variant, pinned to one image by its digest.
  [[ $checked =~ ^(.+)@sha256:[0-9a-f]{64}$ ]]
  if [ "${BASH_REMATCH[1]}" != "$runs" ]; then
    echo "set vector_image in the justfile to \"$runs@sha256:<digest>\", where <digest> is that tag's image index digest," \
      "as Renovate sets it with the chart in one pull request"
    return 1
  fi
  # Renovate's custom manager for the justfile moves the tag and the digest of the line under this comment.
  pin="$(grep -B1 -E '^vector_image[[:blank:]]*:=' "$REPO/justfile" | head -n 1)"
  echo "above vector_image: $pin"
  [ "$pin" = "# renovate: datasource=docker depName=${runs%:*}" ]
  run just --justfile "$REPO/justfile" --dry-run ci
  [ "$status" -eq 0 ]
  [[ $output == *"$checked"* ]]
  # The module checks with the image the recipe hands it, so it names none of its own.
  run grep -rl 'timberio/vector' "$REPO/.dagger"
  [ "$status" -eq 1 ]
}

@test "The collector's configuration is rendered with flux and helm given none of the secrets" {
  local bin="$BATS_TEST_TMPDIR/bin" tool real name
  mkdir -p "$bin"
  # Each tool is recorded, by the names of its environment, and then runs as itself.
  for tool in flux helm; do
    real=$(command -v "$tool")
    printf '#!/usr/bin/env bash\nenv | cut -d= -f1 >> %q\nexec %q "$@"\n' \
      "$BATS_TEST_TMPDIR/names.$tool" "$real" > "$bin/$tool"
    chmod +x "$bin/$tool"
  done
  local names=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CLUSTER_S3_ACCESS_KEY_ID CLUSTER_S3_SECRET_ACCESS_KEY
    OS_CLOUD OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET TF_STATE_PASSPHRASE
    TF_ENCRYPTION SOPS_AGE_KEY SOPS_AGE_KEY_FILE FLUX_AGE_KEY FLUX_AGE_KEY_FILE OPERATOR_CIDRS)
  local settings=()
  for name in "${names[@]}"; do settings+=("$name=marker-$name"); done

  run env PATH="$bin:$PATH" "${settings[@]}" "$REPO/scripts/vector-config" "$BATS_TEST_TMPDIR/vector-out"

  [ "$status" -eq 0 ]
  for tool in flux helm; do
    echo "$tool"
    [ -s "$BATS_TEST_TMPDIR/names.$tool" ]
    grep -qx HELM_CACHE_HOME "$BATS_TEST_TMPDIR/names.$tool"
    for name in "${names[@]}"; do
      if grep -qx "$name" "$BATS_TEST_TMPDIR/names.$tool"; then
        echo "$tool got $name"
        return 1
      fi
    done
  done
}

@test "The collector has the host access it needs and no more" {
  local pod data mounts hostpaths user level escalations
  render "$COLLECTOR"
  collector_config
  pod="$BATS_TEST_TMPDIR/collector-pod.json"
  yq -N -o json 'select(.kind == "DaemonSet") | .spec.template.spec' "$RENDERED" >"$pod"
  # Talos writes its log files, and the container runtime the pods', as root with mode 0640, so
  # only root reads them without a capability; the user is set, not left to the image.
  # A container's own user overrides the pod's.
  user="$(jq -r '(.securityContext.runAsUser // "unset") as $pod
    | .containers[] | select(.name == "vector") | .securityContext.runAsUser // $pod' "$pod")"
  echo "runs as user: $user"
  [ "$user" = 0 ]
  # /var/log read-only, which holds the pods' log files under pods/ and Talos's beside them, and the
  # state directory, where Vector keeps its place in each file and its buffer, writable.
  data="$(jq -r '.data_dir' "$CONFIG")"
  # shellcheck disable=SC2016 # $volumes is a jq variable.
  mounts="$(jq -r '(.volumes // []) as $volumes | (.containers + (.initContainers // []))[] | .volumeMounts // [] | .[]
    | . as $mount | $volumes[] | select(.name == $mount.name and .hostPath != null)
    | "\(.hostPath.path | sub("/$"; "")) \($mount.mountPath | sub("/$"; "")) \($mount.readOnly // false)"' "$pod" | sort)"
  hostpaths="$(jq -r '.volumes // [] | .[] | select(.hostPath != null) | .hostPath.path | sub("/$"; "")' "$pod" | sort)"
  echo "host paths mounted (host, container, read-only): $(paste -sd, - <<<"$mounts"); state directory: $data"
  [ "$mounts" = "$(printf '%s\n' "/var/lib/vector $data false" "/var/log /var/log true" | sort)" ]
  [ "$hostpaths" = "$(printf '%s\n' /var/lib/vector /var/log)" ]
  # shellcheck disable=SC2016 # $c is a jq variable.
  escalations="$(jq -r '[(if .hostNetwork == true then "hostNetwork" else empty end),
    (if .hostPID == true then "hostPID" else empty end), (if .hostIPC == true then "hostIPC" else empty end),
    ((.containers + (.initContainers // []))[] | (.securityContext // {}) as $c | .name as $name
      | (if $c.privileged == true then "\($name) is privileged" else empty end),
        (if $c.allowPrivilegeEscalation != false then "\($name) allows privilege escalation" else empty end),
        (if ($c.capabilities.drop // []) | index("ALL") | not then "\($name) keeps its capabilities" else empty end),
        (if ($c.capabilities.add // []) | length > 0 then "\($name) adds capabilities" else empty end))] | .[]' "$pod")"
  echo "beyond what it needs: ${escalations:-nothing}"
  [ -z "$escalations" ]
  # Host paths are what only the privileged level admits, on the namespace as the cluster gets it.
  overlay
  level="$(yq -N "select(.kind == \"Namespace\" and .metadata.name == \"$NAMESPACE\")
    | .metadata.labels[\"pod-security.kubernetes.io/enforce\"]" "$OVERLAY")"
  echo "$NAMESPACE's Pod Security level: ${level:-none}"
  [ "$level" = privileged ]
}

@test "Nothing in the log pipeline listens beyond what it serves" {
  local app exposed listeners exporter ports
  for app in "$STORE" "$COLLECTOR"; do
    render "$app"
    exposed="$(yq -N 'select(. != null) | select(.kind == "Ingress" or .kind == "Gateway" or (.kind | test("Route$"))
        or (.kind == "Service" and (.spec.type == "LoadBalancer" or .spec.type == "NodePort"))
        or ((.kind == "StatefulSet" or .kind == "Deployment" or .kind == "DaemonSet") and .spec.template.spec.hostNetwork == true)
        or ((.kind == "StatefulSet" or .kind == "Deployment" or .kind == "DaemonSet")
          and ([.spec.template.spec.containers[].ports // [] | .[] | select(.hostPort != null)] | length > 0)))
      | .kind + "/" + .metadata.name' "$RENDERED")"
    echo "$app exposes: ${exposed:-nothing}"
    [ -z "$exposed" ]
  done
  # Of the collector's sources, sinks and API, only the metrics exporter takes connections, and its
  # DaemonSet declares that port and no other.
  collector_config
  listeners="$(jq -r '[(.sources // {} | to_entries[]), (.sinks // {} | to_entries[])
      | select(.value.address != null or .value.type == "prometheus_exporter")
      | "\(.value.type) \(.value.address // "0.0.0.0:9598")"]
    + (if .api.enabled == true then ["api \(.api.address // "127.0.0.1:8686")"] else [] end) | .[]' "$CONFIG")"
  echo "the collector listens on: $(paste -sd, - <<<"$listeners")"
  [ "$(grep -c . <<<"$listeners")" -eq 1 ]
  [[ $listeners == "prometheus_exporter "* ]]
  exporter="${listeners##*:}"
  ports="$(yq -N 'select(.kind == "DaemonSet") | .spec.template.spec | (.containers + (.initContainers // []))[]
    | .ports // [] | .[] | (.containerPort | tostring) + "/" + (.protocol // "TCP")' "$RENDERED")"
  echo "the DaemonSet's ports: ${ports:-none}"
  [ "$ports" = "$exporter/TCP" ]
}

@test "The log store and the collector have their monitors on" {
  local app targets depends exporter port
  render "$STORE"
  targets="$(monitor_targets)"
  echo "$STORE: ${targets:-no monitor}"
  [ "$(grep -c . <<<"$targets")" -eq 1 ]
  [[ $targets == ServiceMonitor/* ]]
  [[ $targets != *' -> none' ]]

  render "$COLLECTOR"
  targets="$(monitor_targets)"
  echo "$COLLECTOR: ${targets:-no monitor}"
  [ "$(grep -c . <<<"$targets")" -eq 1 ]
  [[ $targets == PodMonitor/*' -> DaemonSet/'* ]]
  # The port it scrapes is the one the metrics exporter listens on.
  collector_config
  exporter="$(jq -r '.sinks[] | select(.type == "prometheus_exporter") | .address // "0.0.0.0:9598" | sub(".*:"; "")' "$CONFIG")"
  port="$(yq -N 'select(.kind == "PodMonitor") | .spec.podMetricsEndpoints[0].port' "$RENDERED")"
  port="$(yq -N "select(.kind == \"DaemonSet\") | .spec.template.spec.containers[].ports[] | select(.name == \"$port\") | .containerPort" "$RENDERED")"
  echo "metrics exporter on $exporter; PodMonitor scrapes container port ${port:-none}"
  [ -n "$exporter" ]
  [ "$port" = "$exporter" ]
  # The monitor kinds exist once the definitions are installed.
  for app in "$STORE" "$COLLECTOR"; do
    depends="$(yq '.spec.dependsOn // [] | .[].name' "$REPO/kubernetes/apps/base/$NAMESPACE/$app/ks.yaml")"
    echo "$app depends on: ${depends:-nothing}"
    grep -qx prometheus-operator-crds <<<"$depends"
  done
}

@test "every values key of victoria-logs is one its pinned chart defines" {
  defined_keys "$STORE"
}

@test "every values key of vector is one its pinned chart defines" {
  defined_keys "$COLLECTOR"
}
