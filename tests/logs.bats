#!/usr/bin/env bats
# Proves features/logs.feature, except the scenarios tagged @by:vector-check, which Vector's unit
# tests in tests/vector prove; each test carries its scenario's title. Needs helm, flux, kustomize,
# just, yq, jq and awk on PATH (the versions pinned for the repository). Each chart is pulled once
# per run from its public registry; building and rendering are offline. The applications are built
# in memory, so no build rewrites a file of this checkout.

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
  # Built from the tree's parent, with paths from there, as scripts/kubernetes-check builds.
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

# config_paths: every path from a source to a sink in the collector's configuration, one per line as
# source>transform>…>sink; a name that is not a transform starts one. Needs collector_config first.
config_paths() {
  # shellcheck disable=SC2016 # $c, $n and $sink are jq variables.
  jq -r 'def route($c): . as $n
      | if $c.transforms[$n] == null then [$n] else ($c.transforms[$n].inputs // [])[] | route($c) + [$n] end;
    . as $c | .sinks | to_entries[] | .key as $sink | .value.inputs[] | route($c) + [$sink] | join(">")' "$CONFIG"
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
# user's choosing, and so does a security context map for the fields of Kubernetes' security
# context types (fixtures/security-context-fields).
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
    # A security context map is Kubernetes' type, which the chart passes through to the pod or
    # container: a field of that type is a key of the user's choosing, a misspelt one is not.
    if [[ $key =~ (^|\.)(securityContext|podSecurityContext|containerSecurityContext)\.(.+)$ ]] &&
      grep -qxF -- "${BASH_REMATCH[3]}" "$BATS_TEST_DIRNAME/fixtures/security-context-fields"; then
      continue
    fi
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

@test "The collector ships every pod's logs and every Talos service's log but the audit log to the store" {
  local service name namespace port domain pods restricted files include sinks upstream source talos first last tests found
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
  # Which of Talos's lines go on is decided on the one path from its source to the store, whose
  # transforms Vector's unit tests run, as just vector-check does in just ci. For each service whose
  # format the collector reads, as its transform names them, and udevd, whose lines have none, a test
  # sends a line of its file in at the path's first transform and finds it, with its service's name,
  # at the last; a test sends only the audit log's lines in there and finds none at the last. A line
  # of the test's program counts, not a comment.
  talos="$(config_paths | grep "^$files>")"
  echo "the Talos path: ${talos:-none}"
  [ "$(grep -c . <<<"$talos")" -eq 1 ]
  first="${talos#*>}"
  first="${first%%>*}"
  last="${talos%>*}"
  last="${last##*>}"
  tests="$(yq -o json '.tests' "$REPO/tests/vector/talos-lines.yaml")"
  for service in kernel machined apid trustd etcd containerd cri kubelet udevd; do
    # shellcheck disable=SC2016 # $first, $last and $service are jq variables.
    found="$(jq --arg first "$first" --arg last "$last" --arg service "$service" 'def lines: split("\n")[] | gsub("^\\s+|\\s+$"; "");
      [.[] | select([.inputs[].insert_at] | unique == [$first])
        | select(any(.inputs[].source | lines; . == ".file = \"/var/log/\($service).log\"" or . == ".file = \"/var/log/\($service).log.1\""))
        | select(any((.outputs // [])[] | select(.extract_from == $last) | .conditions[].source | lines;
            . == "assert_eq!(.talos_service, \"\($service)\")"))] | length' <<<"$tests")"
    echo "$service: $found unit tests find its line at $last"
    [ "$found" -ge 1 ]
  done
  # shellcheck disable=SC2016 # $first and $last are jq variables.
  found="$(jq --arg first "$first" --arg last "$last" 'def lines: split("\n")[] | gsub("^\\s+|\\s+$"; "");
    [.[] | select([.inputs[].insert_at] | unique == [$first])
      | select(all(.inputs[]; any(.source | lines; . == ".file = \"/var/log/auditd.log\"" or . == ".file = \"/var/log/auditd.log.1\"")))
      | select(any((.no_outputs_from // [])[]; . == $last))] | length' <<<"$tests")"
  echo "auditd: $found unit tests find none of its lines at $last"
  [ "$found" -ge 1 ]
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

# logs_copy: a copy of the repository's scripts, with a kubeconfig for the cluster lab-sto2, for just
# logs to run in through the repository's justfile, against recording fakes: a mise with nothing
# installed, which keeps the justfile from putting real tools in front of the fakes, and a kubectl
# that records its arguments, the kubeconfig it was given and the names of its environment, then
# acts as the file $STATE/mode says, each time after a warning naming the API server's address on
# its error output. As kubectl v1.37 does: ok answers with the file $STATE/answer; refuse and
# refuse-long fail as when the proxied store answers 400 with a plain-text body, which is what
# VictoriaLogs sends for a query it refuses, a short one and one of over 3000 bytes: the error output
# says only "the server rejected our request for an unknown reason", and the body is only in the log
# of a verbose run, whose lines from -v=6 on name the API server's address: from -v=4 on as the
# message of the cause of the Status kubectl made of the answer, cut at 2048 bytes, and from -v=8 on
# also as the response body, cut at 1024; fail500, fail503, fail403 and fail404 fail as for those
# answers, the first two naming the store's address in kubectl's message; notready as when the
# store's Service has no ready endpoint; noreason as for a Status without a reason, naming the
# store's address; fail401 as when the API server refuses the kubeconfig's credentials; down fails
# as when the API server does not answer, naming its address; big answers with 4000 records of
# about 250 bytes, in neither time order. Sets COPY, BIN, RECORD, STATE and KUBECONFIG_FILE.
logs_copy() {
  COPY="$BATS_TEST_TMPDIR/copy" BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record" STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$COPY/talos/lab-sto2/clusterconfig" "$BIN" "$RECORD" "$STATE"
  cp -R "$REPO/scripts" "$COPY/scripts"
  KUBECONFIG_FILE="$COPY/talos/lab-sto2/clusterconfig/kubeconfig"
  echo 'not a real kubeconfig' >"$KUBECONFIG_FILE"
  echo ok >"$STATE/mode"
  printf '#!/usr/bin/env bash\n' >"$BIN/mise"
  { printf '#!/usr/bin/env bash\nRECORD=%q STATE=%q\n' "$RECORD" "$STATE"; cat <<'EOF'; } >"$BIN/kubectl"
printf '%s\n' "$*" >>"$RECORD/argv"
printf '%s\n' "${KUBECONFIG-unset}" >>"$RECORD/kubeconfig"
env | cut -d= -f1 >>"$RECORD/names"
level=0
for arg; do [[ $arg =~ ^-v=([0-9]+)$ ]] && level=${BASH_REMATCH[1]}; done
# refused BODY: the store answered 400 with the plain-text body BODY.
refused() {
  local body=$1
  if ((level >= 6)); then
    cat >&2 <<'LOG'
I1114 12:00:00.777460 3565636 loader.go:408] Config loaded from file:  /home/operator/kubeconfig
I1114 12:00:00.785877 3565636 round_trippers.go:527] "Request" verb="GET" url="https://192.0.2.10:6443/api/v1/namespaces/monitoring/services/victoria-logs:9428/proxy/select/logsql/query?query=x" headers=<
	Accept: application/json, */*
	User-Agent: kubectl/v1.37.1 (linux/amd64) kubernetes/f78e722
 >
I1114 12:00:00.786392 3565636 round_trippers.go:632] "Response" status="400 Bad Request" headers=<
	Content-Type: text/plain
 > milliseconds=0
LOG
  fi
  if ((level >= 8)); then
    if ((${#body} <= 1024)); then
      printf 'I1114 12:00:00.786485 3565636 get.go:174] "Response Body" body=<\n%s\n >\n' "$(sed 's/^/\t/' <<<"$body")" >&2
    else
      printf 'I1114 12:00:00.786485 3565636 get.go:174] "Response Body" body=%s\n' \
        "$(jq -n --arg b "${body:0:1024} [truncated $((${#body} - 1024)) chars]" '$b')" >&2
    fi
  fi
  if ((level >= 4)); then
    jq -n --arg m "${body:0:2048}" '{metadata: {}, status: "Failure",
        message: "the server rejected our request for an unknown reason", reason: "BadRequest",
        details: {causes: [{reason: "UnexpectedServerResponse", message: ($m | sub("^\\s+|\\s+$"; ""; "g"))}]}, code: 400}' |
      sed '1s/^/I1114 12:00:00.786612 3565636 helpers.go:247] server response object: /' >&2
  fi
  echo 'Error from server (BadRequest): the server rejected our request for an unknown reason' >&2
  exit 1
}
echo 'W1114 12:00:00 request to https://192.0.2.10:6443 was slow' >&2
case $(cat "$STATE/mode") in
  ok)
    cat "$STATE/answer"
    ;;
  refuse)
    refused "cannot parse query \"kubernetes.pod_name:(\": unexpected end of query"$'\n'
    ;;
  refuse-long)
    refused "cannot parse query \"_time:5m at 192.0"$'\xc2\x9b'".2.77:9428 $(printf 'x%.0s' {1..3000})\": unexpected end of query"$'\n'
    ;;
  fail500)
    echo 'Error from server (InternalError): an error on the server ("cannot read the block at 192.0.2.77:9428: store exploded") has prevented the request from succeeding' >&2
    exit 1
    ;;
  fail503)
    echo 'Error from server (ServiceUnavailable): error trying to reach service: dial tcp 192.0.2.77:9428: connect: connection refused' >&2
    exit 1
    ;;
  fail403)
    echo 'Error from server (Forbidden): services "victoria-logs:9428" is forbidden: User "operator" cannot get resource "services/proxy" in API group "" in the namespace "monitoring"' >&2
    exit 1
    ;;
  fail404)
    echo 'Error from server (NotFound): the server could not find the requested resource' >&2
    exit 1
    ;;
  notready)
    echo 'Error from server (ServiceUnavailable): no endpoints available for service "victoria-logs:9428"' >&2
    exit 1
    ;;
  noreason)
    echo 'Error from server: proxy error from 192.0.2.77:9428 while dialing: dial tcp 192.0.2.77:9428: i/o timeout' >&2
    exit 1
    ;;
  fail401)
    echo 'error: You must be logged in to the server (Unauthorized)' >&2
    exit 1
    ;;
  down)
    echo 'Unable to connect to the server: dial tcp 192.0.2.10:6443: connect: connection refused' >&2
    exit 1
    ;;
  big)
    # Record i of 4000 is i seconds after 12:00; multiplying by 1237 modulo the prime 4001 orders
    # 1 to 4000 neither oldest nor newest first.
    awk 'BEGIN { pad = sprintf("%200s", ""); gsub(/ /, "x", pad)
      for (k = 1; k <= 4000; k++) { i = (k * 1237) % 4001
        printf "{\"_time\":\"2026-11-14T%02d:%02d:%02dZ\",\"_msg\":\"record %d %s\",\"node\":\"node-1\"}\n", 12 + int(i / 3600), int(i / 60) % 60, i % 60, i, pad } }'
    ;;
esac
EOF
  chmod +x "$BIN/mise" "$BIN/kubectl"
}

# answer_records: the answer VictoriaLogs gives, newest first as it does for a query that keeps the
# time order, except the oldest record, as a query whose pipes reorder records is answered, with
# _time as it writes it: RFC 3339 with the fraction's trailing zeros dropped, so a whole second has
# none and .12 and .123 differ in length. Four records fall in one second, a whole second, .12, .123
# and .5, which sorted as strings come out as .123, .12, .5 and the whole second last; then a pod's
# record with a message of several lines and C0 and C1 control characters and a Talos service's
# record.
answer_records() {
  cat >"$STATE/answer" <<'EOF'
{"_msg":"sixth: the kubelet restarted","_stream":"{node=\"node-2\",talos_service=\"kubelet\"}","_time":"2026-11-14T12:00:03Z","node":"node-2","talos_service":"kubelet"}
{"_msg":"fifth\nline two \u001b[31mred\u001b[0m \u009b2Jclear\u0085next\u0080","_stream":"{}","_time":"2026-11-14T12:00:02.25Z","kubernetes.pod_name":"grafana-deployment-5d4f","kubernetes.pod_namespace":"monitoring","node":"node-1"}
{"_msg":"first: scrape done","_stream":"{}","_time":"2026-11-14T12:00:01Z","kubernetes.pod_name":"vector-x1y2z","kubernetes.pod_namespace":"monitoring","node":"node-1"}
{"_msg":"fourth: half past","_stream":"{}","_time":"2026-11-14T12:00:01.5Z","kubernetes.pod_name":"vector-x1y2z","kubernetes.pod_namespace":"monitoring","node":"node-1"}
{"_msg":"third: millisecond precision","_stream":"{}","_time":"2026-11-14T12:00:01.123Z","kubernetes.pod_name":"vector-x1y2z","kubernetes.pod_namespace":"monitoring","node":"node-1"}
{"_msg":"second: centisecond precision","_stream":"{}","_time":"2026-11-14T12:00:01.12Z","kubernetes.pod_name":"vector-x1y2z","kubernetes.pod_namespace":"monitoring","node":"node-1"}
EOF
}

# The secret variables the recipes read, which just logs must not pass on to kubectl.
LOGS_SECRETS=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CLUSTER_S3_ACCESS_KEY_ID CLUSTER_S3_SECRET_ACCESS_KEY
  OS_CLOUD OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET TF_STATE_PASSPHRASE
  TF_ENCRYPTION SOPS_AGE_KEY SOPS_AGE_KEY_FILE FLUX_AGE_KEY FLUX_AGE_KEY_FILE GH_TOKEN OPERATOR_CIDRS)

# logs_recipe ARG...: runs just logs ARG... in the copy with only TMPDIR, HOME and a marker for each
# of the secrets set, failing after a minute rather than hanging.
logs_recipe() {
  local markers=() name
  for name in "${LOGS_SECRETS[@]}"; do markers+=("$name=marker-$name"); done
  run timeout 60 env -i HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${markers[@]}" \
    "$(command -v just)" --justfile "$REPO/justfile" --working-directory "$COPY" logs "$@"
}

# last_request: the one request kubectl last recorded, as "path" and the decoded parameters, in
# REQUEST_PATH, QUERY, START and LIMIT.
last_request() {
  local argv params
  argv="$(tail -n 1 "$RECORD/argv")"
  [[ $argv == "get --raw "* ]] || { echo "kubectl ran: $argv"; return 1; }
  REQUEST_PATH="${argv#get --raw }"
  params="${REQUEST_PATH#*\?}"
  REQUEST_PATH="${REQUEST_PATH%%\?*}"
  QUERY="$(jq -rn --arg p "$params" '$p | split("&") | map(select(startswith("query="))) | .[0] | .[6:] | @urid')"
  START="$(jq -rn --arg p "$params" '$p | split("&") | map(select(startswith("start="))) | .[0] // "" | .[6:] | @urid')"
  LIMIT="$(jq -rn --arg p "$params" '$p | split("&") | map(select(startswith("limit="))) | .[0] // "" | .[6:]')"
}

# window_seconds: how many seconds before now START, the request's start, lies.
window_seconds() {
  echo $(($(date -u +%s) - $(date -u -d "$START" +%s)))
}

@test "An operator's query prints the matching records, oldest first, without an address" {
  local seconds name
  logs_copy
  answer_records

  logs_recipe '_time:5m error'
  echo "status $status; $output"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    '2026-11-14T12:00:01Z monitoring/vector-x1y2z first: scrape done' \
    '2026-11-14T12:00:01.12Z monitoring/vector-x1y2z second: centisecond precision' \
    '2026-11-14T12:00:01.123Z monitoring/vector-x1y2z third: millisecond precision' \
    '2026-11-14T12:00:01.5Z monitoring/vector-x1y2z fourth: half past' \
    '2026-11-14T12:00:02.25Z monitoring/grafana-deployment-5d4f fifth line two [31mred[0m 2Jclearnext' \
    '2026-11-14T12:00:03Z node-2 sixth: the kubelet restarted')" ]
  # No address, from the API server's warnings on kubectl's error output or from anywhere else.
  [[ $output != *192.0.2.* && $output != *https://* ]]
  # The query goes through the API's service proxy to the store's Service and port, with the
  # query as given, the last 15 minutes and 200 records unless told otherwise, through the
  # cluster's kubeconfig.
  last_request
  echo "request: $REQUEST_PATH; query: $QUERY; start: $START; limit: $LIMIT"
  [ "$REQUEST_PATH" = /api/v1/namespaces/monitoring/services/victoria-logs:9428/proxy/select/logsql/query ]
  [ "$QUERY" = '_time:5m error' ]
  [ "$LIMIT" = 200 ]
  seconds="$(window_seconds)"
  echo "the window starts $seconds seconds ago"
  ((seconds >= 899 && seconds <= 910))
  [ "$(sort -u "$RECORD/kubeconfig")" = "$KUBECONFIG_FILE" ]
  # kubectl is run with the kubeconfig and none of the secrets the recipes read.
  [ -s "$RECORD/names" ]
  grep -qx KUBECONFIG "$RECORD/names"
  for name in "${LOGS_SECRETS[@]}"; do
    echo "$name"
    if grep -qx "$name" "$RECORD/names"; then return 1; fi
  done

  logs_recipe 'kubernetes.pod_namespace:monitoring' --since 2h --limit 5 lab-sto2
  echo "status $status; $output"
  [ "$status" -eq 0 ]
  last_request
  echo "query: $QUERY; start: $START; limit: $LIMIT"
  [ "$QUERY" = 'kubernetes.pod_namespace:monitoring' ]
  [ "$LIMIT" = 5 ]
  seconds="$(window_seconds)"
  echo "the window starts $seconds seconds ago"
  ((seconds >= 7199 && seconds <= 7210))

  logs_recipe '*' --limit 7 --since 90s
  [ "$status" -eq 0 ]
  last_request
  [ "$LIMIT" = 7 ]
  seconds="$(window_seconds)"
  ((seconds >= 89 && seconds <= 100))
}

@test "A query VictoriaLogs refuses, and an API that does not answer, each fail and say why" {
  logs_copy
  answer_records

  echo refuse >"$STATE/mode"
  logs_recipe 'kubernetes.pod_name:('
  echo "refused: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'cannot parse query "kubernetes.pod_name:(": unexpected end of query'* ]]
  [[ $output != *192.0.2.* && $output != *6443* && $output != *https://* ]]

  # A message longer than kubectl keeps: its first 2048 bytes, without a control character or the
  # address it names, even with one inside the other, and said to be cut.
  echo refuse-long >"$STATE/mode"
  logs_recipe '_time:5m'
  echo "refused at length: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'cannot parse query "_time:5m at <address> '"$(printf 'x%.0s' {1..1900})"* ]]
  [[ $output == *"x [kubectl keeps only the first 2048 bytes of the store's answer]"* ]]
  [[ $output != *'unexpected end of query'* ]]
  [[ $output != *192.0.2.* && $output != *6443* && $output != *https://* ]]
  [[ $output != *$'\xc2\x9b'* ]]

  # Any other answer the API server or the store gives is shown as kubectl words it, without the
  # address it may name.
  echo fail500 >"$STATE/mode"
  logs_recipe '*'
  echo "store failed: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'an error on the server ("cannot read the block at <address>: store exploded")'* ]]
  [[ $output != *192.0.2.* && $output != *https://* ]]
  echo fail503 >"$STATE/mode"
  logs_recipe '*'
  echo "store away: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'error trying to reach service: dial tcp <address>: connect: connection refused'* ]]
  [[ $output != *192.0.2.* && $output != *https://* ]]
  echo fail403 >"$STATE/mode"
  logs_recipe '*'
  echo "forbidden: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'cannot get resource "services/proxy"'* ]]
  [[ $output != *192.0.2.* && $output != *https://* ]]
  echo fail404 >"$STATE/mode"
  logs_recipe '*'
  echo "not found: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'the server could not find the requested resource'* ]]
  [[ $output != *192.0.2.* && $output != *https://* ]]
  echo notready >"$STATE/mode"
  logs_recipe '*'
  echo "store not ready: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'no endpoints available for service "victoria-logs:9428"'* ]]
  [[ $output != *"did not answer"* ]]
  echo noreason >"$STATE/mode"
  logs_recipe '*'
  echo "no reason: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'proxy error from <address> while dialing: dial tcp <address>: i/o timeout'* ]]
  [[ $output != *192.0.2.* && $output != *https://* && $output != *"did not answer"* ]]
  echo fail401 >"$STATE/mode"
  logs_recipe '*'
  echo "credentials refused: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'You must be logged in to the server (Unauthorized)'*'just cluster-kubeconfig'* ]]
  [[ $output != *"did not answer"* ]]

  echo down >"$STATE/mode"
  logs_recipe '*'
  echo "down: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"did not answer"* ]]
  [[ $output != *192.0.2.10* ]]
  [[ $output != *6443* ]]

  # An answer that is not what VictoriaLogs sends is no success either.
  echo ok >"$STATE/mode"
  echo '<html>bad gateway</html>' >"$STATE/answer"
  logs_recipe '*'
  echo "not records: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"not JSON lines"* ]]

  # Refused before kubectl runs.
  rm -f "$RECORD/argv"
  logs_recipe
  echo "no query: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *usage* ]]
  logs_recipe '*' --since soon
  [ "$status" -ne 0 ]
  [[ $output == *"--since is not a duration"* ]]
  logs_recipe '*' --limit 0
  [ "$status" -ne 0 ]
  [[ $output == *"--limit is not a whole number"* ]]
  rm "$KUBECONFIG_FILE"
  logs_recipe '*'
  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/clusterconfig/kubeconfig does not exist; just cluster-kubeconfig fetches it"* ]]
  [ ! -e "$RECORD/argv" ]
}

@test "An answer larger than a pipe's buffer is printed whole" {
  logs_copy
  echo big >"$STATE/mode"
  logs_recipe '*' --limit 5000
  echo "status $status; lines $(wc -l <<<"$output")"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<<"$output")" -eq 4000 ]
  # The oldest first: record 1 is the oldest by time, record 4000 the newest.
  [[ $(head -n 1 <<<"$output") == *" record 1 x"* ]]
  [[ $(tail -n 1 <<<"$output") == *" record 4000 x"* ]]

  # A reader that stops early, such as head, is no failure of the recipe: it says nothing on its
  # error output and the writer's status is zero.
  env -i HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" \
    "$(command -v just)" --justfile "$REPO/justfile" --working-directory "$COPY" logs '*' --limit 5000 \
    2>"$BATS_TEST_TMPDIR/stderr" | head -n 1 >"$BATS_TEST_TMPDIR/stdout" || true
  echo "stderr: $(cat "$BATS_TEST_TMPDIR/stderr")"
  [[ $(cat "$BATS_TEST_TMPDIR/stdout") == *" record 1 x"* ]]
  [ ! -s "$BATS_TEST_TMPDIR/stderr" ]
  env -i HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" \
    "$(command -v just)" --justfile "$REPO/justfile" --working-directory "$COPY" logs '*' --limit 5000 \
    2>/dev/null | head -n 1 >/dev/null
  [ "${PIPESTATUS[0]}" -eq 0 ]
}

@test "Grafana reads logs from VictoriaLogs through a datasource the tree declares" {
  local grafana labels sources name namespace port url type uid plugins version board map key json ours
  built grafana
  ours="$BUILT"
  grafana="$(yq -N -o json -I0 'select(.kind == "Grafana")' "$ours")"
  labels="$(jq -c '.metadata.labels // {}' <<<"$grafana")"
  sources="$(yq -N -o json -I0 'select(.kind == "GrafanaDatasource") | select(.spec.datasource.type == "victoriametrics-logs-datasource")' "$ours")"
  echo "VictoriaLogs datasources: ${sources:-none}"
  [ "$(grep -c . <<<"$sources")" -eq 1 ]
  jq -e --argjson labels "$labels" '(.spec.instanceSelector.matchLabels // {}) as $selector
    | ($selector | length > 0) and ($selector | to_entries | all($labels[.key] == .value))' <<<"$sources"
  type="$(jq -r '.spec.datasource.type' <<<"$sources")"
  uid="$(jq -r '.spec.uid // ""' <<<"$sources")"
  [ -n "$uid" ]
  # Grafana's server queries the store, through its Service, so a browser needs no way to it.
  [ "$(jq -r '.spec.datasource.access' <<<"$sources")" = proxy ]
  # Prometheus stays the default datasource.
  [ "$(jq -r '.spec.datasource.isDefault // false' <<<"$sources")" = false ]
  url="$(jq -r '.spec.datasource.url // ""' <<<"$sources")"
  render "$STORE"
  read -r name namespace port <<<"$(store_service)"
  echo "datasource URL: $url; the store's Service: $name $namespace $port"
  [[ $url =~ ^http://([a-z0-9-]+)\.([a-z0-9-]+)\.svc(\.cluster\.local)?:([0-9]+)/?$ ]]
  [ "${BASH_REMATCH[1]}" = "$name" ]
  [ "${BASH_REMATCH[2]}" = "$namespace" ]
  [ "${BASH_REMATCH[4]}" = "$port" ]
  # The plugin is asked for by the type's name, at an exact version, and nothing else is.
  plugins="$(jq -c '.spec.plugins // []' <<<"$sources")"
  echo "plugins: $plugins"
  [ "$(jq -r 'length' <<<"$plugins")" -eq 1 ]
  [ "$(jq -r '.[0].name' <<<"$plugins")" = "$type" ]
  version="$(jq -r '.[0].version' <<<"$plugins")"
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  # The operator only hands the plugin to Grafana's container as GF_INSTALL_PLUGINS, and the image's
  # entrypoint installs from it only with GF_INSTALL_PLUGINS_FORCE=true; Grafana's own server skips
  # it while plugins.preinstall_disabled is on, which the tree keeps on so that Grafana fetches
  # nothing else. So the container sets the force variable, and does not set the plugin list itself.
  [ "$(jq -r '.spec.config.plugins.preinstall_disabled' <<<"$grafana")" = true ]
  echo "grafana container env: $(jq -c '[.spec.deployment.spec.template.spec.containers // [] | .[] | select(.name == "grafana") | .env // [] | .[] | [.name, .value]]' <<<"$grafana")"
  [ "$(jq -r '[.spec.deployment.spec.template.spec.containers // [] | .[] | select(.name == "grafana") | .env // [] | .[]
    | select(.name == "GF_INSTALL_PLUGINS_FORCE" and .value == "true")] | length' <<<"$grafana")" -eq 1 ]
  [ "$(jq -r '[.spec.deployment.spec.template.spec.containers // [] | .[] | .env // [] | .[]
    | select(.name == "GF_INSTALL_PLUGINS" or .name == "GF_PLUGINS_PREINSTALL" or .name == "GF_PLUGINS_PREINSTALL_SYNC")] | length' <<<"$grafana")" -eq 0 ]
  # Renovate's regex manager reads the version on the line under such a comment.
  [ "$(grep -B1 -E "^[[:blank:]]+version: [\"']?${version//./\\.}[\"']?\$" "$REPO/kubernetes/apps/base/$NAMESPACE/grafana/app/grafanadatasource-victoria-logs.yaml" | head -1 | sed 's/^[[:blank:]]*//')" \
    = '# renovate: datasource=github-releases depName=VictoriaMetrics/victorialogs-datasource' ]

  # The dashboard: loaded into the Grafana from a ConfigMap of the application, and reading this
  # datasource, with volume by namespace and by node and a logs panel filtered by two variables.
  board="$(yq -N -o json -I0 'select(.kind == "GrafanaDashboard" and .spec.configMapRef != null)' "$ours")"
  echo "dashboards of the application: $(jq -r '.metadata.name' <<<"$board" | paste -sd' ' -)"
  [ "$(grep -c . <<<"$board")" -eq 1 ]
  jq -e --argjson labels "$labels" '(.spec.instanceSelector.matchLabels // {}) as $selector
    | ($selector | length > 0) and ($selector | to_entries | all($labels[.key] == .value))' <<<"$board"
  map="$(jq -r '.spec.configMapRef.name' <<<"$board")" key="$(jq -r '.spec.configMapRef.key' <<<"$board")"
  json="$(yq -N -o json "select(.kind == \"ConfigMap\" and .metadata.name == \"$map\") | .data[\"$key\"]" "$ours")"
  [ -n "$json" ]
  json="$(jq -r '.' <<<"$json")"
  echo "variables: $(jq -r '[.templating.list[].name] | join(" ")' <<<"$json")"
  [ "$(jq -r '[.templating.list[].name] | sort | join(" ")' <<<"$json")" = "namespace pod" ]
  # Each variable lists the values of the field its name says, the pod's only within the namespaces
  # chosen.
  [ "$(jq -r '.templating.list[] | select(.name == "namespace") | .query.field' <<<"$json")" = kubernetes.pod_namespace ]
  [ "$(jq -r '.templating.list[] | select(.name == "pod") | .query.field' <<<"$json")" = kubernetes.pod_name ]
  # shellcheck disable=SC2016 # $namespace is the dashboard's variable.
  [[ $(jq -r '.templating.list[] | select(.name == "pod") | .query.query' <<<"$json") == *'"kubernetes.pod_namespace":$namespace'* ]]
  # Every query of every panel and variable goes to the datasource declared above.
  [ "$(jq -r --arg uid "$uid" --arg type "$type" '[.panels[].targets[].datasource, .templating.list[].datasource]
    | all(.uid == $uid and .type == $type)' <<<"$json")" = true ]
  # Volume by namespace and by node, as stats over time grouped by the field.
  jq -e '[.panels[] | select(.type == "timeseries") | .targets[] | select(.queryType == "statsRange") | .expr]
    | (any(test("by \\(\"kubernetes.pod_namespace\"\\)"))) and (any(test("by \\(node\\)")))' <<<"$json"
  # The logs panel is filtered by both variables.
  jq -e '[.panels[] | select(.type == "logs") | .targets[].expr]
    | length > 0 and all(test("kubernetes.pod_namespace\":\\$namespace") and test("kubernetes.pod_name\":\\$pod"))' <<<"$json"
}

# Vector's unit tests run the collector's transforms and cannot see a source or a sink, so what
# reaches the store is what leaves the transforms its sink reads, given what the sources hand them.
# Each source's events reach a sink along one path only: Talos's lines through talos_files,
# drop_audit and drop_auditd_log, the pods' records through pod_fields, and Vector's own metrics to
# its exporter. Each scenario's unit test starts at the first transform of its path and watches the
# last, so what it proves is what the store gets. The sources keep the field names they have by
# default, the ones the unit tests' records carry: a pod's labels in kubernetes.pod_labels, its
# node's in kubernetes.node_labels, and a Talos line's file in file and the reader's host in host.
@test "every Vector unit test the scenarios name is in tests/vector and runs a whole path to the store" {
  local tests="$REPO/tests/vector/talos-lines.yaml" title paths talos last
  for title in "Kernel audit records are dropped and counted" \
    "The audit log's records of a permissive denial do not reach the store, and are counted" \
    "No record of the audit log reaches the store, and a line of another service does" \
    "A pod's record carries the named labels and no field per other label"; do
    echo "$title"
    [ "$(title="$title" yq -N '[.tests[] | select(.name == strenv(title))] | length' "$tests")" -eq 1 ]
  done
  # A filter transform is what Vector counts as discarded events, in component_discarded_events_total.
  render "$COLLECTOR"
  collector_config
  [ "$(jq -r '.transforms.drop_audit.type' "$CONFIG")" = filter ]
  [ "$(jq -r '.transforms.drop_auditd_log.type' "$CONFIG")" = filter ]
  echo "settings that rename the sources' fields: $(jq -c '[.sources[] | to_entries[]
    | select((.key | test("annotation_fields$")) or .key == "file_key" or .key == "host_key")]' "$CONFIG")"
  [ "$(jq '[.sources[] | to_entries[]
    | select((.key | test("annotation_fields$")) or .key == "file_key" or .key == "host_key")] | length' "$CONFIG")" -eq 0 ]
  paths="$(config_paths | sort)"
  echo "paths to the sinks: $(paste -sd' ' - <<<"$paths")"
  [ "$paths" = "$(printf '%s\n' 'pods>pod_fields>victoria_logs' 'talos>talos_files>drop_audit>drop_auditd_log>victoria_logs' \
    'vector_metrics>prometheus' | sort)" ]
  echo "sinks: $(jq -r '.sinks | to_entries[] | "\(.key) \(.value.type)"' "$CONFIG" | paste -sd, -)"
  [ "$(jq -r '.sinks | to_entries[] | "\(.key) \(.value.type)"' "$CONFIG" | sort)" \
    = "$(printf '%s\n' 'prometheus prometheus_exporter' 'victoria_logs elasticsearch' | sort)" ]
  # The Talos scenarios start at its first transform and watch its last, whichever that is: the
  # path's last transform is the one before the sink.
  talos="$(grep '^talos>' <<<"$paths")"
  [ "$(grep -c . <<<"$talos")" -eq 1 ]
  last="${talos%>*}"
  last="${last##*>}"
  echo "the Talos path's last transform: $last"
  for title in "Kernel audit records are dropped and counted" \
    "The audit log's records of a permissive denial do not reach the store, and are counted" \
    "No record of the audit log reaches the store, and a line of another service does"; do
    [ "$(title="$title" yq -N '.tests[] | select(.name == strenv(title))
      | ([.inputs[].insert_at] | unique) + [(.outputs // [])[].extract_from] + (.no_outputs_from // []) | join(" ")' "$tests")" \
      = "talos_files $last" ]
  done
  title="A pod's record carries the named labels and no field per other label"
  [ "$(title="$title" yq -N '.tests[] | select(.name == strenv(title))
    | [.inputs[].insert_at] + [.outputs[].extract_from] | join(" ")' "$tests")" = "pod_fields pod_fields" ]
}

@test "The store's own writes cannot add records to the store" {
  local paths
  render "$COLLECTOR"
  collector_config
  # The audit log is a file of the Talos source, so what it carries leaves that source through
  # talos_files only. Every route from it to a sink is listed, and there is one, which ends in the
  # filter whose discards Vector counts. That the audit log's lines are the ones it discards, and
  # that they pass drop_audit to reach it, Vector's unit tests show.
  paths="$(config_paths | grep '^talos>')"
  echo "paths from the Talos source to a sink: $(paste -sd' ' - <<<"$paths")"
  [ "$paths" = "talos>talos_files>drop_audit>drop_auditd_log>victoria_logs" ]
  echo "drop_auditd_log: $(jq -c '.transforms.drop_auditd_log | {type, inputs, condition}' "$CONFIG")"
  [ "$(jq -r '.transforms.drop_auditd_log | .type + " " + (.inputs | join(","))' "$CONFIG")" = "filter drop_audit" ]
}

@test "every values key of victoria-logs is one its pinned chart defines" {
  defined_keys "$STORE"
}

@test "every values key of vector is one its pinned chart defines" {
  defined_keys "$COLLECTOR"
}
