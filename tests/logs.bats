#!/usr/bin/env bats
# Proves features/logs.feature, except the scenarios tagged @by:vector-check, which Vector's unit
# tests in tests/vector prove; each test carries its scenario's title. Needs helm, flux, kustomize,
# just, yq, jq, awk and git on PATH (the versions pinned for the repository). Each chart is pulled
# once per run from its public registry; building and rendering are offline. The applications are
# built in memory, so no build rewrites a file of this checkout.
#
# One test also runs Renovate's image, the one the justfile pins, with docker: the proof of
# Renovate's own lookup of the VictoriaLogs plugin. It skips, saying why, where no docker daemon
# answers, as in the CI containers; with one, a pull or a run that fails is a failure. Its container
# has no network, no capability and a read-only root, and mounts only a directory of the test's own.

# The tests run one at a time even where bats runs a file's tests side by side: a test that starts
# while another pulls a chart finds the chart's directory before the chart is in it.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

# tree_without, a copy of the tree whose overlay leaves applications out.
load fixtures/tree-without

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
  ROUTE_APP=victoria-logs-route
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  EXAMPLE="$BATS_TEST_TMPDIR/example-vars.yaml"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$EXAMPLE"
}

teardown() {
  local pid
  # A port-forward a failing recipe left behind is stopped here, and so is a recipe a failing test
  # left running in the background, so no test leaves one running.
  if [ -n "${JUST_PID-}" ]; then kill "$JUST_PID" 2>/dev/null || true; fi
  if [ -s "$BATS_TEST_TMPDIR/state/recipe" ]; then kill "$(cat "$BATS_TEST_TMPDIR/state/recipe")" 2>/dev/null || true; fi
  if [ -f "$BATS_TEST_TMPDIR/state/forwards" ]; then
    while read -r pid; do
      kill "$pid" 2>/dev/null || true
    done <"$BATS_TEST_TMPDIR/state/forwards"
  fi
}

# other_vars: writes a copy of the example values with another domain and sets OTHER to it, so a
# test can build again and see that what it read came from the variable, not from a literal that
# happens to equal the example.
other_vars() {
  OTHER="$BATS_TEST_TMPDIR/other-vars.yaml"
  CLUSTER_DOMAIN=other.example.org yq '.CLUSTER_DOMAIN = strenv(CLUSTER_DOMAIN)' "$EXAMPLE" >"$OTHER"
}

# built APP: the application APP of the monitoring namespace as Flux applies it: its app/ built in
# memory with its ks.yaml, substituting strictly the variables of the cluster's example key lists,
# or those of the file VARS names, with the ks.yaml's own substitutions over them. Writes
# $BATS_TEST_TMPDIR/APP-built.yaml and sets BUILT.
built() {
  local app=$1 ks="$BATS_TEST_TMPDIR/$1-ks.yaml"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "${VARS:-$EXAMPLE}" \
    "$REPO/kubernetes/apps/base/$NAMESPACE/$app/ks.yaml" >"$ks"
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

# overlay [DIR]: the cluster's overlay as the root Kustomization builds it, or the overlay in DIR.
# Sets OVERLAY.
overlay() {
  OVERLAY="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "${1:-$REPO/kubernetes/apps/overlays/lab-sto2}" >"$OVERLAY"
}

# everything: the overlay's build and every application it enables, each built as Flux applies it
# from the overlay's Kustomization, with the example key lists and its own substitutions over them,
# strictly, all in one file. Writes $EVERYTHING.
everything() {
  local name ks path
  overlay
  EVERYTHING="$BATS_TEST_TMPDIR/everything.yaml"
  cp "$OVERLAY" "$EVERYTHING"
  for name in $(yq -N 'select(.kind == "Kustomization") | .metadata.name' "$OVERLAY"); do
    ks="$BATS_TEST_TMPDIR/overlay-$name-ks.yaml"
    # shellcheck disable=SC2016 # $vars is a yq variable.
    NAME="$name" yq ea 'select(fileIndex == 0) as $vars
      | select(fileIndex == 1 and .kind == "Kustomization" and .metadata.name == strenv(NAME))
      | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "$EXAMPLE" "$OVERLAY" >"$ks"
    path="$(yq '.spec.path' "$ks")"
    echo --- >>"$EVERYTHING"
    (cd "$REPO" && flux build kustomization "$name" --path "./kubernetes/${path#./}" \
      --kustomization-file "$ks" --dry-run --strict-substitute --in-memory-build) >>"$EVERYTHING"
  done
}

# cluster_render: the render of the tree as scripts/render makes it, every chart expanded, once per
# file of tests. Sets CLUSTER_RENDER to lab-sto2's directory of it, one file per object.
cluster_render() {
  local out="$BATS_FILE_TMPDIR/cluster-render"
  if [ ! -d "$out/lab-sto2" ]; then
    rm -rf "$out"
    "$REPO/scripts/render" "$out" "$REPO" >"$BATS_FILE_TMPDIR/cluster-render.log" 2>&1 ||
      { cat "$BATS_FILE_TMPDIR/cluster-render.log"; return 1; }
  fi
  CLUSTER_RENDER="$out/lab-sto2"
}

# route_admits METHOD TARGET: succeeds when the route in $BATS_TEST_TMPDIR/route.yaml sends the
# request to a backend, as Gateway API matches an HTTPRoute (gateway-api apis/v1/httproute_types.go):
# a rule without matches matches every request, and a match without a path is a prefix of "/"; a
# method matches exactly; an Exact path is the request's path, without its query, byte for byte; a
# PathPrefix matches the path whole or up to a "/", a trailing "/" of the prefix aside. Of the
# matches the request meets, an Exact path wins, then the longest prefix, then one with a method,
# then the earlier rule; the request is sent on when that match's rule has a backend. Exits 0 when it
# is sent on and 1 when not; a match of any other type or field exits otherwise, as one this test
# cannot evaluate.
route_admits() {
  yq -o json '.' "$BATS_TEST_TMPDIR/route.yaml" | jq -e --arg method "$1" --arg target "$2" '
    ($target | split("?")[0]) as $path
    | def path_of: .path // {"type": "PathPrefix", "value": "/"};
      def path_matches:
        path_of as $p
        | if $p.type == "Exact" then $path == $p.value
          elif $p.type == "PathPrefix" then ($p.value | sub("/+$"; "")) as $v | $v == "" or $path == $v or ($path | startswith($v + "/"))
          else error("a path match of type \($p.type), which this test does not evaluate") end;
      def request_matches:
        if (keys - ["method", "path"] | length) > 0 then error("a match by \(keys - ["method", "path"] | join(", ")), which this test does not evaluate")
        else ((.method // $method) == $method) and path_matches end;
    [ .spec.rules | to_entries[] | .key as $rule | ((.value.backendRefs // []) | length > 0) as $backend
      | (.value.matches // [{}])[] | select(request_matches)
      | {exact: (if path_of.type == "Exact" then 1 else 0 end), length: (path_of.value | length),
         method: (if .method then 1 else 0 end), rule: (0 - $rule), $backend} ]
    | if length == 0 then false else (sort_by(.exact, .length, .method, .rule) | last | .backend) end' >/dev/null
}

# store_reach FILE...: one line for each way, in the objects of the files, that the log store is
# reached from the public Gateway other than through the sign-in, naming what does it: a route other
# than logs of monitoring whose rules send to the Service victoria-logs or vmauth of monitoring, as a
# backend, a backend's mirror or a rule's mirror, whatever namespace the reference names or leaves
# out; a route of monitoring on the public Gateway that no SecurityPolicy of monitoring asking
# oauth2-proxy of sso-system, without failing open, targets by name and that is not such a route's
# sign-in route <name>-oauth2 sending to oauth2-proxy of sso-system alone; a Grafana of monitoring
# that has its operator make an HTTPRoute there, which no render holds and so no policy can be seen
# to target; an object other than that policy that targets logs, by reference or by selector; a
# route other than logs and logs-oauth2 of monitoring that lists logs's host; an HTTPRouteFilter
# other than logs of monitoring that injects the route's credential, the Secret vmauth-logs-route,
# whatever namespace it is in; and a ReferenceGrant of monitoring that lets another namespace refer
# to its Services or Secrets, as a route there could then reach the store's or vmauth's pods through
# any Service of monitoring that selects them, or a filter there inject the route's credential.
# Prints nothing when none does.
store_reach() {
  # shellcheck disable=SC2016 # $all, $own, $r, $p, $policy, $protected, $hosts and $ref are jq variables.
  yq -N -o json -I0 'select(. != null)' "$@" | jq -rs '
    [.[] | objects] as $all
    | def on_public: .metadata.namespace as $own | any(.spec.parentRefs[]?; .name == "public"
        and (.kind // "Gateway") == "Gateway" and (.namespace // $own) == "envoy-gateway-system");
      def refs: .metadata.namespace as $own
        | (.spec.rules[]? | (.backendRefs[]? | ., (.filters[]?.requestMirror.backendRef // empty)),
            (.filters[]?.requestMirror.backendRef // empty))
        | select((.kind // "Service") == "Service" and (.group // "") == "") | {name, namespace: (.namespace // $own), port};
      def asks_sign_in: .kind == "SecurityPolicy" and .spec.extAuth != null
        and (.spec.extAuth.failOpen // false) == false
        and ([.spec.extAuth.http.backendRefs[]? | [(.kind // "Service"), .name, .namespace]] == [["Service", "oauth2-proxy", "sso-system"]]);
    [$all[] | select(.metadata.namespace == "monitoring" and asks_sign_in) | .spec.targetRefs[]?
      | select((.group // "") == "gateway.networking.k8s.io" and .kind == "HTTPRoute") | .name] as $protected
    | ([$all[] | select(.kind == "HTTPRoute" and .metadata.namespace == "monitoring" and .metadata.name == "logs")
        | .spec.hostnames[]?]) as $hosts
    | ($all[] | select(.kind | tostring | endswith("Route")) | . as $r
        | select($r.kind != "HTTPRoute" or $r.metadata.namespace != "monitoring" or $r.metadata.name != "logs")
        | [refs | select((.name == "victoria-logs" or .name == "vmauth") and .namespace == "monitoring") | .name] | unique[]
        | "\($r.kind)/\($r.metadata.namespace)/\($r.metadata.name) sends to the Service \(.) of monitoring"),
      ($all[] | select(.kind | tostring | endswith("Route")) | select(.metadata.namespace == "monitoring" and on_public) | . as $r
        | select(($protected | index($r.metadata.name)) == null)
        | select(($r.metadata.name | endswith("-oauth2")) and ($protected | index($r.metadata.name | sub("-oauth2$"; ""))) != null
            and ([$r | refs | [.name, .namespace]] | unique == [["oauth2-proxy", "sso-system"]]) | not)
        | "\($r.kind)/monitoring/\($r.metadata.name) is on the public Gateway and no policy that asks oauth2-proxy targets it"),
      ($all[] | select(.kind == "Grafana" and .metadata.namespace == "monitoring" and .spec.httpRoute? != null)
        | "Grafana/monitoring/\(.metadata.name) has its operator make an HTTPRoute that no policy can be seen to target"),
      ($all[] | . as $p | ($p.metadata.namespace // "") as $own | select(($p.spec | type) == "object")
        | select(any(([$p.spec.targetRef // empty] + ($p.spec.targetRefs // []))[];
              (.kind // "") == "HTTPRoute" and .name == "logs" and $own == "monitoring")
            or ($own == "monitoring" and any($p.spec.targetSelectors[]?; (.kind // "") == "HTTPRoute")))
        | select(($p.kind == "SecurityPolicy" and $p.metadata.name == "logs" and ($p | asks_sign_in)) | not)
        | "\($p.kind)/\($own)/\($p.metadata.name) targets the route logs"),
      ($all[] | select(.kind | tostring | endswith("Route")) | . as $r
        | select(any(.spec.hostnames[]?; . as $h | $hosts | index($h) != null))
        | select(($r.metadata.namespace == "monitoring" and ($r.metadata.name == "logs" or $r.metadata.name == "logs-oauth2")) | not)
        | "\($r.kind)/\($r.metadata.namespace)/\($r.metadata.name) lists the host of the route logs"),
      ($all[] | select(.kind == "HTTPRouteFilter") | . as $f
        | select(($f.metadata.namespace == "monitoring" and $f.metadata.name == "logs") | not)
        | select(($f.spec.credentialInjection.credential.valueRef.name // "") == "vmauth-logs-route")
        | "HTTPRouteFilter/\($f.metadata.namespace)/\($f.metadata.name) injects the credential of vmauth-logs-route"),
      ($all[] | select(.kind == "ReferenceGrant" and .metadata.namespace == "monitoring") | . as $g
        | [.spec.to[]? | select((.group // "") == "" and (.kind == "Service" or .kind == "Secret")) | .kind] | unique[]
        | "ReferenceGrant/monitoring/\($g.metadata.name) lets another namespace refer to the \(.)s of monitoring")'
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

# monitor_targets [FILE]: one line per ServiceMonitor or PodMonitor in FILE, or else in $RENDERED,
# "Kind/name -> Kind/name" naming each object there it scrapes: for a ServiceMonitor, a Service whose
# labels its selector matches and that names every port it scrapes; for a PodMonitor, a workload
# whose pod template does so. A monitor that scrapes none of them ends in "-> none".
monitor_targets() {
  yq -N -o json -I0 'select(. != null)' "${1:-$RENDERED}" | jq -rs '. as $all | .[]
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
  local service name namespace port domain pods restricted files include sinks auth upstream source talos first last tests found
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
  # One sink for the store, at vmauth's Service's name in the cluster's DNS domain, as the user vector,
  # whose bulk path vmauth sends on to the store's Service in that domain on the store's port, and
  # both sources reach it, directly or through transforms.
  sinks="$(jq -r '.sinks[] | select(.type == "elasticsearch") | .endpoints // [] | join(" ")' "$CONFIG")"
  echo "store sinks: ${sinks:-none}"
  built vmauth
  [ "$sinks" = "http://$(yq -N 'select(.kind == "Service") | .metadata.name + "." + .metadata.namespace + ".svc"' "$BUILT").$domain:$(yq -N 'select(.kind == "Service") | .spec.ports[] | select(.name == "http") | .port' "$BUILT")/insert/elasticsearch/" ]
  [ "$(jq -r '.sinks[] | select(.type == "elasticsearch") | .auth.user' "$CONFIG")" = vector ]
  auth="$(yq -N 'select(.kind == "ConfigMap") | .data["auth.yml"]' "$BUILT" | yq -o json -I0 '.users[] | select(.username == "vector") | .url_map')"
  echo "vmauth sends the user vector: $auth"
  [ "$(jq -r '[.[].url_prefix] | unique | join(" ")' <<<"$auth")" = "http://$name.$namespace.svc.$domain:$port" ]
  [ "$(jq -r '[.[].src_paths[]] | join(" ")' <<<"$auth")" = /insert/elasticsearch/_bulk ]
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
  local bin="$BATS_TEST_TMPDIR/bin" tool real name named
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

  # The variable the collector reads its credential from is set too: neither flux nor helm puts it
  # in place of the placeholder, which Vector fills from the pod's environment.
  run env PATH="$bin:$PATH" "${settings[@]}" VMAUTH_PASSWORD=marker-VMAUTH_PASSWORD "$REPO/scripts/vector-config" "$BATS_TEST_TMPDIR/vector-out"

  [ "$status" -eq 0 ]
  # shellcheck disable=SC2016 # ${VMAUTH_PASSWORD} is Vector's placeholder.
  [ "$(yq -N '.sinks.victoria_logs.auth.password' "$BATS_TEST_TMPDIR/vector-out/vector.yaml")" = '${VMAUTH_PASSWORD}' ]
  # With interpolation allowed, Vector fills each $NAME and ${NAME} of every string of the
  # configuration from its environment, a VRL program's included, and reads $$ as a dollar sign
  # (ENVIRONMENT_VARIABLE_INTERPOLATION_REGEX in src/config/loading/interpolation.rs of Vector
  # v0.61.0): the configuration names no variable but the credential's, so that none the pod
  # happens to have, such as HOSTNAME, is put in place of text.
  # shellcheck disable=SC2016 # The $ are Vector's and jq's.
  named="$(yq -N -o json '.' "$BATS_TEST_TMPDIR/vector-out/vector.yaml" |
    jq -r '[.. | strings | scan("\\$\\$|\\$[[:word:].]+|\\$\\{[[:word:].]+(?:(?::?-|:?\\?)[^}]*)?\\}")]
      | map(select(. != "$$")) | unique | join(" ")')"
  echo "variables the configuration names: ${named:-none}"
  # shellcheck disable=SC2016 # ${VMAUTH_PASSWORD} is Vector's placeholder.
  [ "$named" = '${VMAUTH_PASSWORD}' ]
  if grep -q marker- "$BATS_TEST_TMPDIR/vector-out/vector.yaml"; then
    echo "the configuration holds a value of the environment"
    return 1
  fi
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

  # vmauth's PodMonitor scrapes /metrics on the port of its internal listener, which serves its own
  # endpoints and none of what it proxies, and which its Service does not serve.
  built vmauth
  targets="$(monitor_targets "$BUILT")"
  echo "vmauth: ${targets:-no monitor}"
  [ "$targets" = "PodMonitor/vmauth -> Deployment/vmauth" ]
  port="$(yq -N 'select(.kind == "PodMonitor") | .spec.podMetricsEndpoints[0].port' "$BUILT")"
  [ "$(yq -N 'select(.kind == "PodMonitor") | .spec.podMetricsEndpoints[0].path' "$BUILT")" = /metrics ]
  port="$(yq -N "select(.kind == \"Deployment\") | .spec.template.spec.containers[].ports[] | select(.name == \"$port\") | .containerPort" "$BUILT")"
  echo "the PodMonitor scrapes container port ${port:-none}"
  [ "$port" = "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[].args[] | select(test("^-httpInternalListenAddr=")) | sub(".*:"; "")' "$BUILT")" ]
  [ -z "$(yq -N "select(.kind == \"Service\") | .spec.ports[] | select(.targetPort == $port or .port == $port or .targetPort == \"internal\") | .name" "$BUILT")" ]
  # The monitor kinds exist once the definitions are installed.
  for app in "$STORE" "$COLLECTOR" vmauth; do
    depends="$(yq '.spec.dependsOn // [] | .[].name' "$REPO/kubernetes/apps/base/$NAMESPACE/$app/ks.yaml")"
    echo "$app depends on: ${depends:-nothing}"
    grep -qx prometheus-operator-crds <<<"$depends"
  done
}

# store_retry_problem [FILE]: what is wrong with how long the collector's sink to the store waits
# before it tries again an endpoint it has stopped sending to, nothing when it is right. Vector
# stops sending to an endpoint once five requests in a row fail at the connection, refused or with
# a name that does not resolve, or with a 5xx, and tries it again after a delay that doubles from a
# second up to the sink's distribution.retry_max_duration_secs, an hour when unset
# (src/sinks/util/service/health.rs at Vector's v0.61.0). LogCollectorSendFailing reads the
# requests the sink sends, which must move in every 5 minutes of an outage, and must not stand
# still for the 300 seconds after which Vector stops exporting a counter. Reads the configuration
# as collector_config writes it, from FILE or else from $CONFIG.
store_retry_problem() {
  local sinks name wait
  sinks="$(jq -r '.sinks | to_entries[] | select(.value.type == "elasticsearch")
    | "\(.key) \(.value.distribution.retry_max_duration_secs // "unset")"' "${1:-$CONFIG}")"
  if [ "$(grep -c . <<<"$sinks")" -ne 1 ]; then
    echo "the collector has $(grep -c . <<<"$sinks") sinks to the store, not one"
    return 0
  fi
  read -r name wait <<<"$sinks"
  if [ "$wait" = unset ]; then
    echo "the sink $name leaves the wait before it tries the store again to Vector's default, up to an hour:" \
      "set distribution.retry_max_duration_secs to 30, as LogCollectorSendFailing depends on its requests moving at least every 30 seconds"
  elif ! [[ $wait =~ ^[0-9]+$ ]] || ((wait < 1 || wait > 30)); then
    echo "the sink $name waits up to $wait seconds before it tries the store again:" \
      "set distribution.retry_max_duration_secs to 30, as LogCollectorSendFailing depends on its requests moving at least every 30 seconds"
  fi
  return 0
}

@test "The collector tries a store that has failed it again at least every 30 seconds" {
  local broken problem filter expected case
  render "$COLLECTOR"
  collector_config
  echo "the store's sink: $(jq -c '.sinks[] | select(.type == "elasticsearch") | {distribution}' "$CONFIG")"
  problem="$(store_retry_problem)"
  echo "${problem:-the tree waits at most 30 seconds}"
  [ -z "$problem" ]
  # Left to the default, set longer, or set to no wait at all, the check fails, naming the alert.
  broken="$BATS_TEST_TMPDIR/broken.json"
  for case in "del(.distribution)|leaves the wait before it tries the store again to Vector's default, up to an hour" \
    ".distribution.retry_max_duration_secs = 31|waits up to 31 seconds before it tries the store again" \
    ".distribution.retry_max_duration_secs = 3600|waits up to 3600 seconds before it tries the store again" \
    ".distribution.retry_max_duration_secs = 0|waits up to 0 seconds before it tries the store again"; do
    IFS='|' read -r filter expected <<<"$case"
    jq "(.sinks[] | select(.type == \"elasticsearch\")) |= ($filter)" "$CONFIG" >"$broken"
    problem="$(store_retry_problem "$broken")"
    echo "$filter: ${problem:-nothing}"
    [ "$problem" = "the sink victoria_logs $expected: set distribution.retry_max_duration_secs to 30, as LogCollectorSendFailing depends on its requests moving at least every 30 seconds" ]
  done
  jq '.sinks.second = (.sinks[] | select(.type == "elasticsearch"))' "$CONFIG" >"$broken"
  problem="$(store_retry_problem "$broken")"
  echo "a second sink to the store: $problem"
  [ "$problem" = "the collector has 2 sinks to the store, not one" ]
}

# logs_copy: a copy of the repository's scripts, with a kubeconfig for the cluster lab-sto2, for just
# logs to run in through the repository's justfile, against recording fakes: a mise with nothing
# installed, which keeps the justfile from putting real tools in front of the fakes; a kubectl that
# records its arguments, the kubeconfig it was given and the names of its environment and writes a
# warning naming the API server's address on its error output, then answers as kubectl v1.37 does:
# get secret with the base64 of $STATE/authorization, the Secret's key, and port-forward with the
# line that names the local port it forwards from, 41234, after which it runs until it is stopped,
# its process id in $STATE/forwards and its parent's, the recipe's, in $STATE/recipe; and a curl
# that records its arguments, the names of its environment and each request, its URL and the
# headers it read from a file or file descriptor, records in $RECORD/header-files each header file
# that is not a pipe and in $RECORD/credential-files each file under the test's directory, but the
# fakes' own state and record, that holds the Secret's value while it runs, and answers as vmauth
# does in front of the store, through the forward alone: a request to any other address, or with no
# forward running, fails to connect. What they do is set by $STATE/mode:
#   ok            curl answers 200 with the file $STATE/answer
#   big           curl answers 200 with 4000 records of about 250 bytes, in neither time order
#   refuse        curl answers 400 with the plain-text body VictoriaLogs gives a query it refuses,
#   refuse-long   ... and one of over 3000 bytes with a control character and an address in it
#   fail401       curl answers 401, as vmauth does a credential it does not know
#   fail502       curl answers 502, as vmauth does when the store does not answer
#   fail503       curl answers 503 with vmauth's error, which names the store's URL and address
#   vmauth-down   curl's connection through the forward is closed with no answer
#   no-forward    kubectl port-forward fails before it forwards, as for a Service that is missing
#   slow-forward  kubectl port-forward runs without reporting the port it forwards from
#   secret-forbidden, secret-missing
#                 kubectl get secret fails as when the kubeconfig may not read the Secret, or it
#                 does not exist
#   secret-empty  the Secret holds no such key, for which kubectl prints nothing
#   api-401       kubectl fails as when the API server refuses the kubeconfig's credentials
#   down          kubectl fails as when the API server does not answer, naming its address
# Sets COPY, BIN, RECORD, STATE and KUBECONFIG_FILE, and AUTHORIZATION, the Secret's value.
logs_copy() {
  COPY="$BATS_TEST_TMPDIR/copy" BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record" STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$COPY/talos/lab-sto2/clusterconfig" "$BIN" "$RECORD" "$STATE"
  cp -R "$REPO/scripts" "$COPY/scripts"
  KUBECONFIG_FILE="$COPY/talos/lab-sto2/clusterconfig/kubeconfig"
  echo 'not a real kubeconfig' >"$KUBECONFIG_FILE"
  echo ok >"$STATE/mode"
  : >"$STATE/forwards"
  # The Basic value of the user operator, as vmauth-operator's ExternalSecret forms it.
  AUTHORIZATION="Basic $(printf 'operator:%s' marker-operator-password | base64 -w0)"
  printf '%s' "$AUTHORIZATION" >"$STATE/authorization"
  printf '#!/usr/bin/env bash\n' >"$BIN/mise"
  { printf '#!/usr/bin/env bash\nRECORD=%q STATE=%q\n' "$RECORD" "$STATE"; cat <<'EOF'; } >"$BIN/kubectl"
printf '%s\n' "$*" >>"$RECORD/argv"
printf '%s\n' "${KUBECONFIG-unset}" >>"$RECORD/kubeconfig"
env | cut -d= -f1 >>"$RECORD/names"
echo 'W1114 12:00:00 request to https://192.0.2.10:6443 was slow' >&2
mode=$(cat "$STATE/mode")
case $mode in
  down)
    echo 'Unable to connect to the server: dial tcp 192.0.2.10:6443: connect: connection refused' >&2
    exit 1
    ;;
  api-401)
    echo 'error: You must be logged in to the server (Unauthorized)' >&2
    exit 1
    ;;
esac
case " $* " in
  *" get secret vmauth-operator "*)
    case $mode in
      secret-forbidden)
        echo 'Error from server (Forbidden): secrets "vmauth-operator" is forbidden: User "operator" cannot get resource "secrets" in API group "" in the namespace "monitoring"' >&2
        exit 1
        ;;
      secret-missing)
        echo 'Error from server (NotFound): secrets "vmauth-operator" not found' >&2
        exit 1
        ;;
      secret-empty) ;;
      *) base64 -w0 <"$STATE/authorization" ;;
    esac
    ;;
  *" port-forward "*)
    if [[ $mode == no-forward ]]; then
      echo 'Error from server (NotFound): services "vmauth" not found at https://192.0.2.10:6443' >&2
      exit 1
    fi
    echo "$$" >>"$STATE/forwards"
    echo "$PPID" >"$STATE/recipe"
    if [[ $mode != slow-forward ]]; then echo "Forwarding from 127.0.0.1:41234 -> 8427"; fi
    exec sleep 600
    ;;
  *)
    echo "the recording kubectl does not know: $*" >&2
    exit 64
    ;;
esac
EOF
  { printf '#!/usr/bin/env bash\nRECORD=%q STATE=%q\n' "$RECORD" "$STATE"; cat <<'EOF'; } >"$BIN/curl"
printf '%s\n' "$*" >>"$RECORD/curl-argv"
env | cut -d= -f1 >>"$RECORD/curl-names"
url="" output=/dev/stdout write_out="" headers=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    --header | -H)
      header=${args[++i]}
      if [[ $header == @* ]]; then
        [[ -p ${header#@} ]] || printf '%s\n' "${header#@}" >>"$RECORD/header-files"
        headers+=$(cat "${header#@}")$'\n'
      else
        headers+=$header$'\n'
      fi
      ;;
    --output | -o) output=${args[++i]} ;;
    --write-out | -w) write_out=${args[++i]} ;;
    --max-time | -m | --connect-timeout) ((i++)) ;;
    http://* | https://*) url=${args[i]} ;;
  esac
done
value=$(cat "$STATE/authorization")
grep -rlF --exclude-dir=state --exclude-dir=record -e "${value#Basic }" -e "$(printf '%s' "$value" | base64 -w0)" \
  "${STATE%/*}" >>"$RECORD/credential-files" 2>/dev/null || true
running=0
while read -r pid; do
  if kill -0 "$pid" 2>/dev/null; then running=1; fi
done <"$STATE/forwards"
if [[ $url != http://127.0.0.1:41234/* ]] || ((!running)); then
  echo "curl: (7) Failed to connect to ${url#http://} after 0 ms: Could not connect to server" >&2
  exit 7
fi
jq -nc --arg url "$url" --arg headers "$headers" '{url: $url, headers: ($headers | split("\n") | map(select(. != "")))}' >>"$RECORD/requests"
# respond STATUS: the body on standard input to the output, and the status as --write-out has it.
respond() {
  cat >"$output"
  if [[ -n $write_out ]]; then printf '%s' "$1"; fi
  exit 0
}
case $(cat "$STATE/mode") in
  ok) respond 200 <"$STATE/answer" ;;
  big)
    # Record i of 4000 is i seconds after 12:00; multiplying by 1237 modulo the prime 4001 orders
    # 1 to 4000 neither oldest nor newest first.
    awk 'BEGIN { pad = sprintf("%200s", ""); gsub(/ /, "x", pad)
      for (k = 1; k <= 4000; k++) { i = (k * 1237) % 4001
        printf "{\"_time\":\"2026-11-14T%02d:%02d:%02dZ\",\"_msg\":\"record %d %s\",\"node\":\"node-1\"}\n", 12 + int(i / 3600), int(i / 60) % 60, i % 60, i, pad } }' | respond 200
    ;;
  refuse) printf '%s\n' 'cannot parse query "kubernetes.pod_name:(": unexpected end of query' | respond 400 ;;
  refuse-long)
    printf '%s\n' "cannot parse query \"_time:5m at 192.0"$'\xc2\x9b'".2.77:9428 $(printf 'x%.0s' {1..3000})\": unexpected end of query" | respond 400
    ;;
  fail401) printf '%s\n' 'Unauthorized' | respond 401 ;;
  fail502)
    printf '%s\n' 'all the 1 backends for the user "operator" are unavailable for proxying the request - check previous WARN logs to see the exact error for each failed backend' | respond 502
    ;;
  fail503)
    printf '%s\n' 'cannot proxy the request to http://victoria-logs.monitoring.svc.cluster.local:9428/select/logsql/query?query=x: dial tcp 192.0.2.77:9428: connect: connection refused' | respond 503
    ;;
  vmauth-down)
    echo 'curl: (52) Empty reply from server' >&2
    exit 52
    ;;
esac
EOF
  # Every file the recipe deletes is read before it goes, so a credential written to a file and
  # removed again, before curl looks or when the recipe ends, is found as one curl sees is.
  { printf '#!/usr/bin/env bash\nRECORD=%q STATE=%q RM=%q\n' "$RECORD" "$STATE" "$(command -v rm)"; cat <<'EOF'; } >"$BIN/rm"
value=$(cat "$STATE/authorization")
paths=()
for arg; do
  case $arg in -*) ;; *) paths+=("$arg") ;; esac
done
if ((${#paths[@]})); then
  grep -rlF -e "${value#Basic }" -e "$(printf '%s' "$value" | base64 -w0)" -- "${paths[@]}" >>"$RECORD/credential-files" 2>/dev/null || true
fi
exec "$RM" "$@"
EOF
  chmod +x "$BIN/mise" "$BIN/kubectl" "$BIN/curl" "$BIN/rm"
}

# forwards_closed: every port-forward the recipe started has stopped.
forwards_closed() {
  local pid left=""
  while read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then left+=" $pid"; fi
  done <"$STATE/forwards"
  echo "port-forwards still running:${left:- none}"
  [ -z "$left" ]
}

# no_credential OUTPUT: no recorded argument of kubectl or curl holds the Secret's value, its base64,
# or the password inside it, and OUTPUT, what the recipe printed, holds none of them; curl read each
# header file from a pipe, and no file the recipe made held the value while curl ran or when the
# recipe deleted it.
no_credential() {
  local value
  if [ -s "$RECORD/header-files" ] || [ -s "$RECORD/credential-files" ]; then
    echo "header files that are no pipe: $(cat "$RECORD/header-files" 2>/dev/null)"
    echo "files that held the credential: $(cat "$RECORD/credential-files" 2>/dev/null)"
    return 1
  fi
  for value in "$AUTHORIZATION" "$(base64 -w0 <"$STATE/authorization")" marker-operator-password "${AUTHORIZATION#Basic }"; do
    if grep -qF -- "$value" "$RECORD/argv" "$RECORD/curl-argv" 2>/dev/null; then
      echo "a recorded argument holds $value"
      return 1
    fi
    if [[ $1 == *"$value"* ]]; then
      echo "the recipe printed $value"
      return 1
    fi
  done
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

# The secret variables the recipes read, which just logs must not pass on to kubectl or curl.
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

# logs_start ARG...: starts just logs ARG... as logs_recipe runs it, in the background, with its
# output in $BATS_TEST_TMPDIR/out. Sets OUT and JUST_PID.
logs_start() {
  local markers=() name
  for name in "${LOGS_SECRETS[@]}"; do markers+=("$name=marker-$name"); done
  OUT="$BATS_TEST_TMPDIR/out"
  env -i HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${markers[@]}" \
    "$(command -v just)" --justfile "$REPO/justfile" --working-directory "$COPY" logs "$@" >"$OUT" 2>&1 3>&- &
  JUST_PID=$!
}

# forward_started: waits up to 10 seconds for the recording kubectl's port-forward to start.
forward_started() {
  local tick
  for ((tick = 0; tick < 100; tick++)); do
    if [ -s "$STATE/recipe" ]; then return 0; fi
    sleep 0.1
  done
  echo "no port-forward after 10 seconds: $(cat "$OUT")"
  return 1
}

# logs_finished SECONDS: waits up to SECONDS for just, started by logs_start, to end, and sets STATUS
# to its exit status.
logs_finished() {
  local tick
  for ((tick = 0; tick < $1 * 10; tick++)); do
    if ! kill -0 "$JUST_PID" 2>/dev/null; then
      STATUS=0
      wait "$JUST_PID" || STATUS=$?
      return 0
    fi
    sleep 0.1
  done
  echo "just logs still runs after $1 seconds: $(cat "$OUT")"
  return 1
}

# last_request: the one request curl last recorded, as its address and path and the decoded
# parameters, in REQUEST_ADDRESS, REQUEST_PATH, QUERY, START and LIMIT, and the value of the header
# Authorization it sent in REQUEST_AUTHORIZATION.
last_request() {
  local request url params
  request="$(tail -n 1 "$RECORD/requests")"
  url="$(jq -r '.url' <<<"$request")"
  REQUEST_ADDRESS="${url#http://}"
  REQUEST_ADDRESS="${REQUEST_ADDRESS%%/*}"
  REQUEST_PATH="/${url#http://*/}"
  params="${REQUEST_PATH#*\?}"
  REQUEST_PATH="${REQUEST_PATH%%\?*}"
  QUERY="$(jq -rn --arg p "$params" '$p | split("&") | map(select(startswith("query="))) | .[0] | .[6:] | @urid')"
  START="$(jq -rn --arg p "$params" '$p | split("&") | map(select(startswith("start="))) | .[0] // "" | .[6:] | @urid')"
  LIMIT="$(jq -rn --arg p "$params" '$p | split("&") | map(select(startswith("limit="))) | .[0] // "" | .[6:]')"
  REQUEST_AUTHORIZATION="$(jq -r '[.headers[] | select(test("^authorization:"; "i")) | sub("^[^:]*: *"; "")] | if length == 1 then .[0] else "\(length) Authorization headers" end' <<<"$request")"
}

# window_seconds: how many seconds before now START, the request's start, lies.
window_seconds() {
  echo $(($(date -u +%s) - $(date -u -d "$START" +%s)))
}

@test "An operator's query prints the matching records, oldest first, without an address" {
  local seconds name signal recipe_pid
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
  # The recipe reads the operator's credential from the Secret vmauth-operator of monitoring, once,
  # and forwards a port that kubectl chooses on the loopback to vmauth's Service and port, the one
  # vmauth proxies on; nothing else is asked of kubectl.
  echo "kubectl ran: $(paste -sd'|' "$RECORD/argv")"
  [ "$(cat "$RECORD/argv")" = "$(printf '%s\n' \
    'get secret vmauth-operator --namespace monitoring --output jsonpath={.data.authorization} --request-timeout=30s' \
    'port-forward --namespace monitoring service/vmauth :8427 --address 127.0.0.1')" ]
  # The query goes through the forward to vmauth's query endpoint, with the Secret's value as the
  # header Authorization, the query as given, the last 15 minutes and 200 records unless told
  # otherwise.
  [ "$(grep -c . "$RECORD/requests")" -eq 1 ]
  last_request
  echo "request: $REQUEST_ADDRESS $REQUEST_PATH; query: $QUERY; start: $START; limit: $LIMIT"
  [ "$REQUEST_ADDRESS" = 127.0.0.1:41234 ]
  [ "$REQUEST_PATH" = /select/logsql/query ]
  [ "$REQUEST_AUTHORIZATION" = "$AUTHORIZATION" ]
  [ "$QUERY" = '_time:5m error' ]
  [ "$LIMIT" = 200 ]
  seconds="$(window_seconds)"
  echo "the window starts $seconds seconds ago"
  ((seconds >= 899 && seconds <= 910))
  # The credential is never an argument of kubectl or curl, and never printed; the forward is
  # stopped once the recipe ends.
  no_credential "$output"
  forwards_closed
  [ "$(sort -u "$RECORD/kubeconfig")" = "$KUBECONFIG_FILE" ]
  # kubectl and curl are run with none of the secrets the recipes read, kubectl with the kubeconfig.
  [ -s "$RECORD/names" ] && [ -s "$RECORD/curl-names" ]
  grep -qx KUBECONFIG "$RECORD/names"
  for name in "${LOGS_SECRETS[@]}"; do
    echo "$name"
    if grep -qx "$name" "$RECORD/names" "$RECORD/curl-names"; then return 1; fi
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
  forwards_closed

  # Interrupted while it waits for the forward, by Ctrl-C, which the terminal sends to just and the
  # recipe alike, by SIGTERM, which just passes on to the recipe, and by SIGHUP, which a closed
  # terminal sends to both: each ends the recipe at once, well before its 15 seconds' wait for the
  # forward would, with the signal's status and the step it ended in, and stops the forward.
  echo slow-forward >"$STATE/mode"
  for signal in INT TERM HUP; do
    rm -f "$STATE/recipe"
    logs_start '*'
    forward_started
    read -r recipe_pid <"$STATE/recipe"
    if [ "$signal" = TERM ]; then kill -TERM "$JUST_PID"; else kill "-$signal" "$recipe_pid" "$JUST_PID"; fi
    logs_finished 5
    echo "after SIG$signal: status $STATUS; $(cat "$OUT")"
    [ "$STATUS" -eq $((128 + $(kill -l "$signal"))) ]
    grep -qF 'failed while opening a port-forward to service/vmauth in monitoring' "$OUT"
    forwards_closed
  done
}

@test "A query VictoriaLogs refuses, and an API that does not answer, each fail and say why" {
  logs_copy
  answer_records

  # A query the store refuses fails with the store's own message, which vmauth relays in its
  # answer's body, without an address or a control character, however long.
  echo refuse >"$STATE/mode"
  logs_recipe 'kubernetes.pod_name:('
  echo "refused: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'refused the query: cannot parse query "kubernetes.pod_name:(": unexpected end of query'* ]]
  [[ $output != *192.0.2.* && $output != *6443* && $output != *https://* ]]
  no_credential "$output"
  forwards_closed
  echo refuse-long >"$STATE/mode"
  logs_recipe '_time:5m'
  echo "refused at length: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'cannot parse query "_time:5m at <address> '"$(printf 'x%.0s' {1..3000})"'": unexpected end of query'* ]]
  [[ $output != *192.0.2.* && $output != *6443* && $output != *https://* ]]
  [[ $output != *$'\xc2\x9b'* ]]

  # vmauth refusing the credential says so and names the Secret.
  echo fail401 >"$STATE/mode"
  logs_recipe '*'
  echo "credential refused: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'vmauth refused the credential of the Secret vmauth-operator in monitoring'* ]]
  no_credential "$output"
  forwards_closed
  # Any other answer is shown with its status and vmauth's words, without the address or URL they
  # may name.
  echo fail502 >"$STATE/mode"
  logs_recipe '*'
  echo "store away: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'vmauth answered 502: all the 1 backends for the user "operator" are unavailable for proxying the request'* ]]
  echo fail503 >"$STATE/mode"
  logs_recipe '*'
  echo "store refused the connection: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'vmauth answered 503: cannot proxy the request to <url> dial tcp <address>: connect: connection refused'* ]]
  [[ $output != *192.0.2.* && $output != *http://* && $output != *svc.cluster.local* ]]
  # vmauth that does not answer through the forward.
  echo vmauth-down >"$STATE/mode"
  logs_recipe '*'
  echo "vmauth down: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'vmauth did not answer through the port-forward to service/vmauth in monitoring'* ]]
  forwards_closed

  # A port-forward that does not start, with kubectl's reason and no address.
  echo no-forward >"$STATE/mode"
  logs_recipe '*'
  echo "no forward: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'kubectl port-forward to service/vmauth in monitoring stopped before it forwarded a port: services "vmauth" not found'* ]]
  [[ $output != *192.0.2.* && $output != *https://* ]]

  # A Secret the kubeconfig may not read, one that is missing and one without the key, each before
  # any port is forwarded, saying what the kubeconfig must be able to do.
  for mode in secret-forbidden secret-missing; do
    echo "$mode" >"$STATE/mode"
    rm -f "$RECORD/argv"
    logs_recipe '*'
    echo "$mode: status $status; $output"
    [ "$status" -ne 0 ]
    [[ $output == *'cannot read the Secret vmauth-operator in monitoring: '*'; the kubeconfig must be able to read it and forward a port in monitoring'* ]]
    [ "$(grep -c 'port-forward' "$RECORD/argv" || true)" -eq 0 ]
  done
  [[ $output == *'secrets "vmauth-operator" not found'* ]]
  echo secret-empty >"$STATE/mode"
  logs_recipe '*'
  echo "no key: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'the Secret vmauth-operator in monitoring holds no authorization'* ]]

  # Credentials the API server refuses point to just cluster-kubeconfig, and an API that does not
  # answer is said to be one, with no address.
  echo api-401 >"$STATE/mode"
  logs_recipe '*'
  echo "credentials refused: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *'You must be logged in to the server (Unauthorized)'*'just cluster-kubeconfig'* ]]
  [[ $output != *"did not answer"* ]]
  echo down >"$STATE/mode"
  logs_recipe '*'
  echo "down: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"the Kubernetes API did not answer"* ]]
  [[ $output != *192.0.2.10* ]]
  [[ $output != *6443* ]]

  # An answer that is not what VictoriaLogs sends is no success either.
  echo ok >"$STATE/mode"
  echo '<html>bad gateway</html>' >"$STATE/answer"
  logs_recipe '*'
  echo "not records: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"not JSON lines"* ]]
  forwards_closed

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
  # Grafana's server queries the store through vmauth's Service, so a browser needs no way to it.
  [ "$(jq -r '.spec.datasource.access' <<<"$sources")" = proxy ]
  # Prometheus stays the default datasource.
  [ "$(jq -r '.spec.datasource.isDefault // false' <<<"$sources")" = false ]
  url="$(jq -r '.spec.datasource.url // ""' <<<"$sources")"
  built vmauth
  read -r name namespace port <<<"$(yq -N 'select(.kind == "Service") | .metadata.name + " " + .metadata.namespace + " " + (.spec.ports[] | select(.name == "http") | .port | tostring)' "$BUILT")"
  echo "datasource URL: $url; vmauth's Service: $name $namespace $port"
  [ "$name $namespace $port" = "vmauth $NAMESPACE 8427" ]
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
  # Renovate's regex manager reads the version on the line under such a comment, by the plugin's
  # name, from the catalogue Grafana installs it from.
  [ "$(grep -B1 -E "^[[:blank:]]+version: [\"']?${version//./\\.}[\"']?\$" "$REPO/kubernetes/apps/base/$NAMESPACE/grafana/app/grafanadatasource-victoria-logs.yaml" | head -1 | sed 's/^[[:blank:]]*//')" \
    = "# renovate: datasource=custom.grafana-plugins depName=$type" ]

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

# The plugin repository Grafana's CLI installs from while neither --repo, GF_PLUGIN_REPO nor --config
# names another, and the image's entrypoint passes none: the default of the CLI's repo flag
# (pkg/cmd/grafana-cli/commands/cli.go:46-49 in Grafana v13.1.3). The install asks
# <repository>/<plugin>/versions for the plugin's versions (pkg/plugins/repo/service.go:109-118).
GRAFANA_PLUGIN_REPO=https://grafana.com/api/plugins

# The one transform of the custom datasource grafana-plugins: every item of the listing a release,
# by its version and dated by the catalogue's createdAt for it, from the publisher's repository.
PLUGIN_TRANSFORM="{'sourceUrl': items[0].url, 'releases': [items.{'version': version, 'releaseTimestamp': createdAt}]}"

# docker_or_skip: skips the test, saying why, where no docker daemon answers. Past it, whatever
# docker fails at fails the test, a pull of the image included.
docker_or_skip() {
  type -P docker >/dev/null || skip "no docker daemon answers: docker is not on PATH"
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1 ||
    skip "no docker daemon answers: docker version reaches none"
}

# renovate_json FILE: a Renovate configuration file as JSON (the files are JSON5 with comments,
# which YAML reads once they are dropped).
renovate_json() {
  grep -v '^[[:space:]]*//' "$1" | yq -o json -I0 '.'
}

# renovate_config: renovate.json5 and each preset of this repository it extends, one line each:
# {"file": its path in the tree, "config": the file as JSON}.
renovate_config() {
  local file presets
  mapfile -t presets < <(renovate_json "$REPO/renovate.json5" | jq -r '.extends[] | select(startswith("local>")) | sub(".*//"; "")')
  for file in renovate.json5 "${presets[@]}"; do
    renovate_json "$REPO/$file" | jq -c --arg file "$file" '{file: $file, config: .}'
  done
}

# victoria_logs_plugin: the plugin the VictoriaLogs datasource of $BUILT asks for. Sets
# PLUGIN_NAME and PLUGIN_VERSION.
victoria_logs_plugin() {
  local plugin
  plugin="$(yq -N -o json -I0 'select(.kind == "GrafanaDatasource" and .spec.datasource.type == "victoriametrics-logs-datasource")
    | .spec.plugins[0]' "$BUILT")"
  echo "the datasource's plugin: $plugin"
  PLUGIN_NAME="$(jq -r '.name // ""' <<<"$plugin")"
  PLUGIN_VERSION="$(jq -r '.version // ""' <<<"$plugin")"
  [ -n "$PLUGIN_NAME" ]
  [ -n "$PLUGIN_VERSION" ]
}

@test "Renovate reads the VictoriaLogs plugin's versions from the catalogue Grafana installs it from" {
  local file="kubernetes/apps/base/$NAMESPACE/grafana/app/grafanadatasource-victoria-logs.yaml"
  local managers manager pins pin datasource custom entry url configs rules grafana row
  local github=github-releases publisher=VictoriaMetrics/victorialogs-datasource
  built grafana
  victoria_logs_plugin
  # The custom managers whose file patterns take the datasource's file: one, which takes all it
  # reads of the pin from the comment and its line, as it has no template.
  managers="$(renovate_json "$REPO/.renovate/managers.json5")"
  manager="$(jq -c --arg file "$file" '[.customManagers[]
    | select(any(.managerFilePatterns[]; . as $p | $file | test($p | ltrimstr("/") | rtrimstr("/"))))]' <<<"$managers")"
  echo "custom managers of $file: $(jq -r 'map(.description) | join("; ")' <<<"$manager")"
  [ "$(jq 'length' <<<"$manager")" -eq 1 ]
  manager="$(jq -c '.[0]' <<<"$manager")"
  [ "$(jq -r '.customType' <<<"$manager")" = regex ]
  echo "templates of that manager: $(jq -c '[keys[] | select(endswith("Template"))]' <<<"$manager")"
  [ "$(jq -c '[keys[] | select(endswith("Template"))]' <<<"$manager")" = '[]' ]
  # What its own patterns read from the file: the plugin's pin, under the custom datasource, by the
  # plugin's name, the one the operator hands to GF_INSTALL_PLUGINS and the install asks the
  # catalogue for, at the datasource's version.
  pins="$(jq -Rs -c --argjson m "$manager" '. as $text | [$m.matchStrings[] as $re | $text | capture($re; "g")]' "$REPO/$file")"
  echo "what the manager reads there: $pins"
  [ "$(jq 'length' <<<"$pins")" -eq 1 ]
  pin="$(jq -c '.[0]' <<<"$pins")"
  datasource="$(jq -r '.datasource' <<<"$pin")"
  [ "$datasource" = custom.grafana-plugins ]
  [ "$(jq -r '.depName' <<<"$pin")" = "$PLUGIN_NAME" ]
  [ "$(jq -r '.currentValue' <<<"$pin")" = "$PLUGIN_VERSION" ]
  # The datasource is the one custom datasource, by the name Renovate takes from custom.<name>, and
  # reads JSON from the listing the install reads, through the one transform.
  custom="$(jq -c '.customDatasources // {}' <<<"$managers")"
  echo "custom datasources: $custom"
  [ "$(jq -c 'keys' <<<"$custom")" = "$(jq -cn --arg name "${datasource#custom.}" '[$name]')" ]
  entry="$(jq -c --arg name "${datasource#custom.}" '.[$name]' <<<"$custom")"
  [ "$(jq -c 'keys' <<<"$entry")" = '["defaultRegistryUrlTemplate","format","transformTemplates"]' ]
  url="$(jq -r '.defaultRegistryUrlTemplate' <<<"$entry")"
  echo "the listing Renovate reads for $PLUGIN_NAME: ${url//'{{packageName}}'/$PLUGIN_NAME}"
  [ "${url//'{{packageName}}'/$PLUGIN_NAME}" = "$GRAFANA_PLUGIN_REPO/$PLUGIN_NAME/versions" ]
  [ "$(jq -r '.format' <<<"$entry")" = json ]
  [ "$(jq -c '.transformTemplates' <<<"$entry")" = "$(jq -cn --arg transform "$PLUGIN_TRANSFORM" '[$transform]')" ]
  # Renovate deep-merges customDatasources from every preset, with renovate.json5's own over them; a
  # registry URL that the configuration or a rule gives the dependency replaces the datasource's URL
  # template (datasource/custom/utils.js in Renovate 44.227.4), and a rule's overrideDatasource or
  # overridePackageName replaces what it looks up. So of the configuration's files only
  # managers.json5 sets customDatasources, none sets registryUrls at its top, and no rule sets one
  # of the three unless a list of plain names it matches by leaves the plugin out.
  configs="$(renovate_config)"
  echo "files of the configuration that set customDatasources: $(jq -r 'select(.config | has("customDatasources")) | .file' <<<"$configs" | paste -sd' ' -)"
  [ "$(jq -r 'select(.config | has("customDatasources")) | .file' <<<"$configs")" = .renovate/managers.json5 ]
  rules="$(jq -c --arg datasource "$datasource" --arg name "$PLUGIN_NAME" '
    def leaves_out($own): type == "array" and length > 0
      and all(.[]; test("^[^!/][^*?{}\\[\\]]*$") and ascii_downcase != $own);
    .file as $file | .config
    | (select(has("registryUrls")) | {file: $file, registryUrls}),
      (.packageRules // [] | .[]
        | select(has("registryUrls") or has("overrideDatasource") or has("overridePackageName"))
        | select((.matchDatasources | leaves_out($datasource)) or (.matchDepNames | leaves_out($name))
          or (.matchPackageNames | leaves_out($name)) | not)
        | {file: $file, rule: .})' <<<"$configs")"
  echo "what could give the plugin another registry or name: $rules"
  [ -z "$rules" ]
  # The CLI takes another repository from GF_PLUGIN_REPO, and an archive from GF_PLUGIN_URL in
  # place of the catalogue's (cli.go:45-56), and the image's entrypoint sets each from the file that
  # the same name with __FILE appended names, before the install (packaging/docker/run.sh:50-62).
  # The Grafana's containers set none of the four, and take no variables from a ConfigMap or a
  # Secret, which could.
  grafana="$(yq -N -o json -I0 'select(.kind == "Grafana")' "$BUILT")"
  [ "$(jq '[.spec.deployment.spec.template.spec // {} | (.containers // []) + (.initContainers // []) | .[]
    | (.env // [] | .[] | select(.name | IN("GF_PLUGIN_REPO", "GF_PLUGIN_URL", "GF_PLUGIN_REPO__FILE", "GF_PLUGIN_URL__FILE"))),
      (.envFrom // [] | .[])]
    | length' <<<"$grafana")" -eq 0 ]
  # The records name the pin by the datasource and the plugin's name: the form of the listing's
  # versions, and what Renovate extracts from the file.
  row="$(awk -F'\t' -v datasource="$datasource" -v name="$PLUGIN_NAME" '$1 == datasource && $2 == name' "$REPO/.renovate/tag-forms.tsv")"
  echo "tag form: $row"
  [ "$(grep -c . <<<"$row")" -eq 1 ]
  [ "$(cut -f3 <<<"$row")" = '^[0-9]+\.[0-9]+\.[0-9]+$' ]
  [[ $(cut -f4 <<<"$row") == *"$GRAFANA_PLUGIN_REPO/$PLUGIN_NAME/versions"* ]]
  echo "extracted from $file: $(awk -F'\t' -v file="$file" '$1 == file' "$REPO/.renovate/extracted.tsv")"
  [ "$(awk -F'\t' -v file="$file" '$1 == file' "$REPO/.renovate/extracted.tsv")" = "$file"$'\tregex\t'"$PLUGIN_NAME"$'\tversion' ]
  # Nothing reads the version from the publisher's GitHub releases, which the catalogue lists
  # later than GitHub, and some never.
  [ -z "$(awk -F'\t' -v datasource="$github" -v name="$publisher" '$1 == datasource && $2 == name' "$REPO/.renovate/tag-forms.tsv")" ]
  # git grep answers 1 for no match, and fails otherwise, as outside a work tree.
  run git -C "$REPO" grep --untracked -l -F "datasource=$github depName=$publisher"
  echo "files naming the GitHub releases as the datasource: status $status; $output"
  [ "$status" -eq 1 ]
}

@test "Renovate's own lookup of the VictoriaLogs plugin finds exactly the catalogue's versions, with the times the catalogue published them" {
  local dir="$BATS_TEST_TMPDIR/lookup" fixture="$REPO/tests/fixtures/grafana-plugin-versions.json"
  local image out result copy
  built grafana
  victoria_logs_plugin
  # Only this directory is mounted, never the checkout: the presets as JSON, the copies of the
  # listing and the script. The fixture is the catalogue's listing as
  # https://grafana.com/api/plugins/victoriametrics-logs-datasource/versions answered a request
  # without headers on 2026-11-19, trimmed with jq '.items |= .[:3]' and every field of those items
  # kept. The publisher's GitHub release v0.33.0 is not in that listing; the copy added.json lists
  # it, as the catalogue would.
  mkdir -p "$dir"
  grep -v '^[[:space:]]*//' "$REPO/.renovate/managers.json5" | yq -o json '.' >"$dir/managers.json"
  cp "$fixture" "$dir/listing.json"
  jq '.items += [.items[0] | .version = "0.33.0" | .createdAt = "2026-10-15T09:00:00.000Z"]' "$fixture" >"$dir/added.json"
  jq '.items = []' "$fixture" >"$dir/empty.json"
  # Renovate's own code from the image: the custom datasource's configuration as a lookup compiles
  # it, and the lookup itself, over a file:// registry, which replaces the URL template and is read
  # within the local directory only.
  cat >"$dir/lookup.mjs" <<'EOF'
import { readFileSync } from 'node:fs';
import { GlobalConfig } from '/usr/local/renovate/dist/config/global.js';
import { massageCustomDatasourceConfig } from '/usr/local/renovate/dist/modules/datasource/custom/utils.js';
import { CustomDatasource } from '/usr/local/renovate/dist/modules/datasource/custom/index.js';

const [datasource, packageName, currentValue] = process.argv.slice(2);
const { customDatasources } = JSON.parse(readFileSync('/w/managers.json', 'utf8'));
GlobalConfig.set({ localDir: '/w' });
const config = { datasource, packageName, currentValue, customDatasources };
const compiled = massageCustomDatasourceConfig(datasource.replace(/^custom\./, ''), config);
const result = { url: compiled?.defaultRegistryUrlTemplate ?? null };
for (const copy of ['listing', 'added', 'empty']) {
  result[copy] = await new CustomDatasource().getReleases({ ...config, registryUrl: `file:///w/${copy}.json` });
}
console.log(`lookup: ${JSON.stringify(result)}`);
EOF
  # The image runs as a user of its own, which must be able to read the directory.
  chmod -R a+rX "$dir"
  docker_or_skip
  image="$("$(command -v just)" --justfile "$REPO/justfile" --evaluate renovate_image)"
  echo "image: $image"
  [[ $image == *@sha256:* ]]
  out="$(
    # shellcheck source=scripts/lib/tools.sh
    . "$REPO/scripts/lib/tools.sh"
    docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
      --volume "$dir:/w:ro" --entrypoint node "$image" /w/lookup.mjs custom.grafana-plugins "$PLUGIN_NAME" "$PLUGIN_VERSION" 2>&1
  )" || { echo "$out"; return 1; }
  result="$(sed -n 's/^lookup: //p' <<<"$out")"
  [ -n "$result" ] || { echo "$out"; return 1; }
  # The URL Renovate asks for the plugin is the one Grafana's install asks.
  echo "compiled URL: $(jq -r '.url' <<<"$result")"
  [ "$(jq -r '.url' <<<"$result")" = https://grafana.com/api/plugins/victoriametrics-logs-datasource/versions ]
  # Each copy's releases are its items, in its order, each dated by its createdAt.
  for copy in listing added empty; do
    echo "$copy: $(jq -c --arg copy "$copy" '.[$copy]' <<<"$result")"
    [ "$(jq -c --arg copy "$copy" '[.[$copy].releases // [] | .[] | {version, releaseTimestamp}]' <<<"$result")" \
      = "$(jq -c '[.items[] | {version, releaseTimestamp: .createdAt}]' "$dir/$copy.json")" ]
  done
  [ "$(jq -r '[.listing.releases[].version] | join(" ")' <<<"$result")" = "0.34.0 0.33.1 0.32.0" ]
  [ "$(jq -r '.listing.sourceUrl' <<<"$result")" = "$(jq -r '.items[0].url' "$fixture")" ]
  [ "$(jq -r '.listing.sourceUrl' <<<"$result")" = https://github.com/VictoriaMetrics/victorialogs-datasource ]
  # A GitHub release the listing lacks is no release, until the listing holds it; an empty listing
  # gives none.
  [ "$(jq '[.listing.releases[] | select(.version == "0.33.0")] | length' <<<"$result")" -eq 0 ]
  [ "$(jq -r '.added.releases[] | select(.version == "0.33.0") | .releaseTimestamp' <<<"$result")" = 2026-10-15T09:00:00.000Z ]
  [ "$(jq '.empty.releases // [] | length' <<<"$result")" -eq 0 ]
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

# The file of the store's route, relative to the repository.
ROUTE_FILE=kubernetes/apps/base/monitoring/victoria-logs-route/app/httproute.yaml

# paths_record FILE VERSION: fails, saying what to read again and what to set, unless the header of
# the route in FILE records, once, that its paths were read from the VictoriaLogs release VERSION,
# beside one Source line that names app/vlselect/main.go at that release's tag.
paths_record() {
  local file=$1 version=$2 record source
  record="$(grep -E '^#[[:blank:]]*victoria-logs-paths:' "$file" || true)"
  source="$(grep -E '^#[[:blank:]]*Source:[[:blank:]]*https://' "$file" | sed -E 's/^#[[:blank:]]*Source:[[:blank:]]*//' || true)"
  echo "record: ${record:-none}; source: ${source:-none}; the pinned chart deploys VictoriaLogs $version"
  [ "$(grep -c . <<<"$record")" -eq 1 ] && [ "$(grep -c . <<<"$source")" -eq 1 ] ||
    { echo "$file needs one '# victoria-logs-paths: <release>' line and one '# Source:' line"; return 1; }
  record="$(sed -E 's/^#[[:blank:]]*victoria-logs-paths:[[:blank:]]*//; s/[[:blank:]]*$//' <<<"$record")"
  if [ "$record" != "$version" ] ||
    [ "$source" != "https://github.com/VictoriaMetrics/VictoriaLogs/blob/$version/app/vlselect/main.go" ]; then
    echo "the route's paths were read from VictoriaLogs $record, and the pinned chart deploys $version:" \
      "read app/victoria-logs/main.go, app/vlselect/main.go, app/vlinsert/main.go, app/vlstorage/main.go and the" \
      "interface's bundle in app/vlselect/vmui/ at $version again, change the route's rules and the lists of" \
      "tests/logs.bats to what they serve, and set the record to $version and the Source line to" \
      "https://github.com/VictoriaMetrics/VictoriaLogs/blob/$version/app/vlselect/main.go"
    return 1
  fi
}

@test "The log store's interface is reached at logs under the cluster's domain on the public Gateway, behind the cluster's sign-in" {
  local ks domain objects policy route signin grant
  domain="$(yq -e '.CLUSTER_DOMAIN' "$EXAMPLE")"
  # The application beside the store, in its namespace, as the overlay applies it: shaped as
  # demo/hello-sso, with the component, the route's and the host's names, waiting, after the Gateway,
  # vmauth, which it sends to, the sign-in and the exporter that answers its Probe. No patch of the
  # overlay changes it.
  ks="$REPO/kubernetes/apps/base/$NAMESPACE/$ROUTE_APP/ks.yaml"
  overlay
  [ "$(yq -o json -I0 '.spec | sort_keys(..)' "$ks")" \
    = "$(NAME="$ROUTE_APP" yq -N -o json -I0 'select(.kind == "Kustomization" and .metadata.name == strenv(NAME)) | .spec | sort_keys(..)' "$OVERLAY")" ]
  echo "the Kustomization: $(yq -o json -I0 '.spec' "$ks")"
  [ "$(yq '.metadata.namespace' "$ks")" = flux-system ]
  [ "$(yq '.spec.path' "$ks")" = "./apps/base/$NAMESPACE/$ROUTE_APP/app" ]
  [ "$(yq '.spec.targetNamespace' "$ks")" = "$NAMESPACE" ]
  [ "$(yq -o json -I0 '.spec.components' "$ks")" = '["../../../../../components/sso"]' ]
  [ "$(yq -o json -I0 '.spec.postBuild.substitute | sort_keys(.)' "$ks")" = '{"SSO_HOSTNAME":"logs","SSO_ROUTE":"logs"}' ]
  [ "$(yq '.spec.dependsOn | map(.name) | sort | join(" ")' "$ks")" = "blackbox-exporter gateway-public oauth2-proxy vmauth" ]
  [ "$(yq '.spec.wait' "$ks")" = true ]
  [ "$(yq -o json -I0 '.spec.sourceRef' "$ks")" = "{\"kind\":\"ExternalArtifact\",\"name\":\"$ROUTE_APP\"}" ]
  # vmauth's application waits, so the route is applied once vmauth's pods are available with the
  # route's credential in place.
  [ "$(NAME=vmauth yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(NAME)) | .spec.wait' "$OVERLAY")" = true ]
  # The namespace's routes may attach to the public Gateway's https listener.
  [ "$(yq -N "select(.kind == \"Namespace\" and .metadata.name == \"$NAMESPACE\") | .metadata.labels[\"k8s-gitops/gateway\"]" "$OVERLAY")" = public ]
  # app/ holds the one HTTPRoute, the filter that gives it its credential to vmauth and its Probe
  # (tests/probes.bats); the component adds the policy and the sign-in route, all in monitoring.
  # shellcheck disable=SC2016 # The file holds a ${NAME} reference, not for the shell to expand.
  [ "$(yq -N 'select(.kind != "Kustomization") | .kind + "/" + .metadata.name' "$REPO/kubernetes/apps/base/$NAMESPACE/$ROUTE_APP"/app/*.yaml | LC_ALL=C sort | paste -sd' ' -)" \
    = 'HTTPRoute/${SSO_ROUTE} HTTPRouteFilter/${SSO_ROUTE} Probe/${SSO_ROUTE}' ]
  [ "$(yq -o json -I0 '.resources' "$REPO/kubernetes/apps/base/$NAMESPACE/$ROUTE_APP/app/kustomization.yaml")" = '["httproute.yaml","httproutefilter.yaml","probe.yaml"]' ]
  built "$ROUTE_APP"
  objects="$(yq -N 'select(.kind != null) | .kind + "/" + .metadata.namespace + "/" + .metadata.name' "$BUILT" | LC_ALL=C sort | paste -sd' ' -)"
  echo "built: $objects"
  [ "$objects" = "HTTPRoute/monitoring/logs HTTPRoute/monitoring/logs-oauth2 HTTPRouteFilter/monitoring/logs Probe/monitoring/logs SecurityPolicy/monitoring/logs" ]
  # The route: on the public Gateway's https listener, for logs under the cluster's domain.
  route="$(yq -N -o json -I0 'select(.kind == "HTTPRoute" and .metadata.name == "logs")' "$BUILT")"
  [ "$(jq -cS '.spec.parentRefs' <<<"$route")" = '[{"name":"public","namespace":"envoy-gateway-system","sectionName":"https"}]' ]
  [ "$(jq -cS '.spec.hostnames' <<<"$route")" = "[\"logs.$domain\"]" ]
  # Its one policy targets it alone, asks oauth2-proxy's Service at the root with the route's host
  # to return to, sends it the cookie and nothing else of the request's headers, and does not fail
  # open.
  policy="$(yq -N -o json -I0 'select(.kind == "SecurityPolicy")' "$BUILT")"
  echo "the policy: $(jq -cS '.spec' <<<"$policy")"
  [ "$(jq -cS '.spec.targetRefs' <<<"$policy")" = '[{"group":"gateway.networking.k8s.io","kind":"HTTPRoute","name":"logs"}]' ]
  [ "$(jq -cS '.spec.extAuth.http.backendRefs' <<<"$policy")" = '[{"name":"oauth2-proxy","namespace":"sso-system","port":80}]' ]
  [ "$(jq -r '.spec.extAuth.http.pathOverride' <<<"$policy")" = "/?rd=https://logs.$domain/" ]
  [ "$(jq -cS '.spec.extAuth.headersToExtAuth' <<<"$policy")" = '["cookie"]' ]
  [ "$(jq -r '.spec.extAuth.failOpen // false' <<<"$policy")" = false ]
  [ "$(jq -r '.spec.extAuth | has("grpc")' <<<"$policy")" = false ]
  # And nothing else: the whole spec, so that no field added to it, such as a CORS answer that lets
  # another origin read with credentials or a path appended to the question, goes unseen.
  [ "$(jq -cS '.spec' <<<"$policy")" = "$(jq -cnS --arg domain "$domain" '{
    targetRefs: [{group: "gateway.networking.k8s.io", kind: "HTTPRoute", name: "logs"}],
    extAuth: {headersToExtAuth: ["cookie"],
      http: {backendRefs: [{name: "oauth2-proxy", namespace: "sso-system", port: 80}],
        pathOverride: "/?rd=https://logs.\($domain)/", headersToBackend: ["x-auth-request-user", "x-auth-request-email"]}}}')" ]
  # The sign-in route: /oauth2/ on the same host, to oauth2-proxy.
  signin="$(yq -N -o json -I0 'select(.kind == "HTTPRoute" and .metadata.name == "logs-oauth2")' "$BUILT")"
  [ "$(jq -cS '.spec.parentRefs' <<<"$signin")" = '[{"name":"public","namespace":"envoy-gateway-system","sectionName":"https"}]' ]
  [ "$(jq -cS '.spec.hostnames' <<<"$signin")" = "[\"logs.$domain\"]" ]
  [ "$(jq -cS '.spec.rules' <<<"$signin")" = "$(jq -cnS '[{matches: [{path: {type: "PathPrefix", value: "/oauth2/"}}],
    backendRefs: [{name: "oauth2-proxy", namespace: "sso-system", port: 80}]}]')" ]
  # oauth2-proxy's grant, as its application applies it in sso-system, lets monitoring's policy and
  # sign-in route refer to the Service.
  NAMESPACE=sso-system built oauth2-proxy
  grant="$(yq -N -o json -I0 'select(.kind == "ReferenceGrant" and .metadata.name == "oauth2-proxy")' "$BUILT")"
  [ "$(jq -r '.metadata.namespace' <<<"$grant")" = sso-system ]
  [ "$(jq -cS '.spec.to' <<<"$grant")" = '[{"group":"","kind":"Service","name":"oauth2-proxy"}]' ]
  [ "$(jq -r '[.spec.from[] | select(.namespace == "monitoring") | .group + "/" + .kind] | sort | join(",")' <<<"$grant")" \
    = "gateway.envoyproxy.io/SecurityPolicy,gateway.networking.k8s.io/HTTPRoute" ]
  # The host, the return address and the sign-in route's host follow the domain.
  other_vars
  VARS="$OTHER" built "$ROUTE_APP"
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .metadata.name + " " + (.spec.hostnames | join(","))' "$BUILT" | sort | paste -sd, -)" \
    = "logs logs.other.example.org,logs-oauth2 logs.other.example.org" ]
  [ "$(yq -N 'select(.kind == "SecurityPolicy") | .spec.extAuth.http.pathOverride' "$BUILT")" = "/?rd=https://logs.other.example.org/" ]
}

@test "Only the interface and its queries are routed to the log store, and the root is redirected to the interface" {
  local name namespace port rules wide request method target
  built vmauth
  read -r name namespace port <<<"$(yq -N 'select(.kind == "Service") | .metadata.name + " " + .metadata.namespace + " " + (.spec.ports[] | select(.name == "http") | .port | tostring)' "$BUILT")"
  echo "vmauth's Service: $name $namespace $port"
  [ "$name" = vmauth ] && [ "$namespace" = "$NAMESPACE" ] && [ "$port" = 8427 ]
  built "$ROUTE_APP"
  yq -N 'select(.kind == "HTTPRoute" and .metadata.name == "logs")' "$BUILT" >"$BATS_TEST_TMPDIR/route.yaml"
  [ "$(yq '.metadata.namespace' "$BATS_TEST_TMPDIR/route.yaml")" = "$namespace" ]
  rules="$(yq -o json -I0 '.spec.rules' "$BATS_TEST_TMPDIR/route.yaml")"
  echo "rules: $rules"
  # No rule matches everything, nor every path of the store's reads: a rule without matches, or a
  # prefix of / or /select.
  [ "$(jq '[.[] | select((.matches // []) | length == 0)] | length' <<<"$rules")" -eq 0 ] ||
    { echo "a rule without matches, which matches every request"; return 1; }
  wide="$(jq -r '.[].matches[]? | select((.path.type // "PathPrefix") == "PathPrefix"
    and ((.path.value // "/") | test("^/(select/?)?$"))) | .path.value // "/"' <<<"$rules")"
  [ -z "$wide" ] || { echo "a prefix match of $wide"; return 1; }
  # Both rules in full, matches, filters and backends: the root's redirect to the interface, which
  # has no backend, and the reads, by path alone, to vmauth's Service on its port, through the
  # route's one filter, which puts the route's credential in Authorization.
  [ "$(yq '.spec.rules | length' "$BATS_TEST_TMPDIR/route.yaml")" -eq 2 ]
  [ "$(yq -o json -I0 '.spec.rules[0]' "$BATS_TEST_TMPDIR/route.yaml" | jq -cS .)" = "$(jq -cnS '{
    matches: [{path: {type: "Exact", value: "/"}}],
    filters: [{type: "RequestRedirect", requestRedirect: {path: {type: "ReplaceFullPath", replaceFullPath: "/select/vmui/"}, statusCode: 302}}]}')" ]
  [ "$(yq -o json -I0 '.spec.rules[1]' "$BATS_TEST_TMPDIR/route.yaml" | jq -cS .)" = "$(jq -cnS --arg name "$name" --argjson port "$port" '{
    matches: [{path: {type: "PathPrefix", value: "/select/vmui"}}, {path: {type: "PathPrefix", value: "/select/logsql"}},
      {path: {type: "Exact", value: "/select/buildinfo"}}, {path: {type: "Exact", value: "/select/tenant_ids"}}],
    filters: [{type: "ExtensionRef", extensionRef: {group: "gateway.envoyproxy.io", kind: "HTTPRouteFilter", name: "logs"}}],
    backendRefs: [{name: $name, port: $port}]}')" ]
  # What reaches the store, by Gateway API's matching of the rules: its interface's files, among
  # them the script the v1.54.0 interface loads, every handler of /select/logsql/, which the
  # interface asks with POST, and the build information and the tenants it reads.
  local admitted=(
    "GET /select/vmui"
    "GET /select/vmui/"
    "GET /select/vmui/index.html"
    "GET /select/vmui/assets/index-DNKuoEMC.js"
    "GET /select/vmui/config.json"
    "GET /select/vmui/manifest.json"
    "POST /select/logsql/query"
    "POST /select/logsql/hits"
    "POST /select/logsql/facets"
    "POST /select/logsql/field_names"
    "POST /select/logsql/field_values"
    "POST /select/logsql/stats_query"
    "POST /select/logsql/stats_query_range"
    "POST /select/logsql/stream_field_names"
    "POST /select/logsql/stream_field_values"
    "POST /select/logsql/stream_ids"
    "POST /select/logsql/streams"
    "POST /select/logsql/query_time_range"
    "POST /select/logsql/tail"
    "GET /select/logsql/query?query=*"
    "GET /select/buildinfo"
    "GET /select/tenant_ids"
  )
  # What does not: the root, which redirects and has no backend; the routed paths changed by a
  # letter's case, a suffix or a trailing slash; the vmalert proxy; every writer; the delete, internal
  # and storage paths; and the paths of the store's HTTP server, its metrics, flags, profiles and
  # health among them.
  local refused=(
    "GET /"
    "GET /select"
    "GET /select/"
    "GET /select/logsqlx"
    "GET /select/vmuix"
    "GET /SELECT/vmui/"
    "GET /select/buildinfo/"
    "GET /select/tenant_ids/x"
    "GET /select/vmalert/api/v1/rules"
    "POST /insert/jsonline"
    "POST /insert/elasticsearch/_bulk"
    "POST /insert/loki/api/v1/push"
    "POST /insert/opentelemetry/v1/logs"
    "POST /insert/journald/upload"
    "POST /insert/datadog/api/v2/logs"
    "POST /insert/native"
    "GET /insert/ready"
    "POST /internal/insert"
    "POST /api/v2/logs"
    "POST /api/v1/validate"
    "POST /services/collector/event"
    "POST /delete/run_task"
    "POST /delete/stop_task"
    "GET /delete/active_tasks"
    "POST /internal/delete/run_task"
    "POST /internal/select/query"
    "POST /internal/force_merge"
    "POST /internal/force_flush"
    "POST /internal/log_new_streams"
    "POST /internal/partition/detach"
    "POST /internal/partition/snapshot/create"
    "GET /metrics"
    "GET /flags"
    "GET /debug/pprof/heap"
    "GET /health"
    "GET /ping"
    "GET /-/healthy"
    "GET /-/ready"
    "GET /robots.txt"
    "GET /favicon.ico"
  )
  for request in "${admitted[@]}"; do
    read -r method target <<<"$request"
    run route_admits "$method" "$target"
    [ "$status" -eq 0 ] || { echo "the route does not send $request to the store: $output"; return 1; }
  done
  for request in "${refused[@]}"; do
    read -r method target <<<"$request"
    run route_admits "$method" "$target"
    [ "$status" -eq 1 ] || { echo "the route sends $request to the store: $output"; return 1; }
  done
}

@test "No route of the tree reaches the log store without the cluster's sign-in" {
  local found
  everything
  # The route, its sign-in route and its policy are there, and nothing else reaches the store from
  # the Gateway.
  for found in HTTPRoute/logs HTTPRoute/logs-oauth2 SecurityPolicy/logs; do
    yq -N 'select(.metadata.namespace == "monitoring") | .kind + "/" + .metadata.name' "$EVERYTHING" | grep -qx "$found" ||
      { echo "no $found in monitoring"; return 1; }
  done
  found="$(store_reach "$EVERYTHING")"
  echo "ways to the store past the sign-in: ${found:-none}"
  [ -z "$found" ]
  # A second route to the store, in another namespace without the component and naming the store's
  # namespace, and a route in monitoring with no policy, are each named.
  cp "$EVERYTHING" "$BATS_TEST_TMPDIR/second.yaml"
  cat >>"$BATS_TEST_TMPDIR/second.yaml" <<'YAML'
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: logs-open
  namespace: demo
spec:
  parentRefs:
    - name: public
      namespace: envoy-gateway-system
      sectionName: https
  hostnames:
    - logs-open.example.org
  rules:
    - backendRefs:
        - name: victoria-logs
          namespace: monitoring
          port: 9428
YAML
  found="$(store_reach "$BATS_TEST_TMPDIR/second.yaml")"
  echo "with a second route: $found"
  [ "$found" = "HTTPRoute/demo/logs-open sends to the Service victoria-logs of monitoring" ]
  # So is a second route to vmauth, in monitoring without the sign-in's policy, and a filter of
  # another route that injects the route's credential.
  cp "$EVERYTHING" "$BATS_TEST_TMPDIR/vmauth.yaml"
  cat >>"$BATS_TEST_TMPDIR/vmauth.yaml" <<'YAML'
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: logs-direct
  namespace: monitoring
spec:
  rules:
    - backendRefs:
        - name: vmauth
          port: 8427
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: HTTPRouteFilter
metadata:
  name: borrowed
  namespace: demo
spec:
  credentialInjection:
    overwrite: true
    credential:
      valueRef:
        name: vmauth-logs-route
        namespace: monitoring
YAML
  found="$(store_reach "$BATS_TEST_TMPDIR/vmauth.yaml")"
  echo "with a second route to vmauth and a borrowed credential: $found"
  [ "$(LC_ALL=C sort <<<"$found" | paste -sd'|' -)" = "HTTPRoute/monitoring/logs-direct sends to the Service vmauth of monitoring|HTTPRouteFilter/demo/borrowed injects the credential of vmauth-logs-route" ]
  cp "$EVERYTHING" "$BATS_TEST_TMPDIR/unprotected.yaml"
  cat >>"$BATS_TEST_TMPDIR/unprotected.yaml" <<'YAML'
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
  namespace: monitoring
spec:
  parentRefs:
    - name: public
      namespace: envoy-gateway-system
      sectionName: https
  hostnames:
    - grafana.example.org
  rules:
    - backendRefs:
        - name: grafana-service
          port: 3000
YAML
  found="$(store_reach "$BATS_TEST_TMPDIR/unprotected.yaml")"
  echo "with a route without a policy: $found"
  [ "$found" = "HTTPRoute/monitoring/grafana is on the public Gateway and no policy that asks oauth2-proxy targets it" ]
  # A second Service in front of the store's pods, which a route of another namespace names through
  # a grant in monitoring, reaches the store without naming its Service: the grant is named.
  cp "$EVERYTHING" "$BATS_TEST_TMPDIR/granted.yaml"
  cat >>"$BATS_TEST_TMPDIR/granted.yaml" <<'YAML'
---
apiVersion: v1
kind: Service
metadata:
  name: logs-open
  namespace: monitoring
spec:
  clusterIP: None
  selector:
    app: server
    app.kubernetes.io/instance: victoria-logs
    app.kubernetes.io/name: victoria-logs-single
  ports:
    - port: 9428
      targetPort: 9428
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: logs-open
  namespace: monitoring
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: demo
  to:
    - group: ""
      kind: Service
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: logs-open
  namespace: demo
spec:
  parentRefs:
    - name: public
      namespace: envoy-gateway-system
      sectionName: https
  hostnames:
    - logs-open.example.org
  rules:
    - backendRefs:
        - name: logs-open
          namespace: monitoring
          port: 9428
YAML
  found="$(store_reach "$BATS_TEST_TMPDIR/granted.yaml")"
  echo "with a second Service behind a grant: $found"
  [ "$found" = "ReferenceGrant/monitoring/logs-open lets another namespace refer to the Services of monitoring" ]
  # A grant to the Secrets of monitoring is named too: a filter of another namespace could then
  # inject the route's credential.
  yq '(select(.kind == "ReferenceGrant" and .metadata.name == "logs-open") | .spec.to[0].kind) = "Secret"' \
    "$BATS_TEST_TMPDIR/granted.yaml" >"$BATS_TEST_TMPDIR/secrets.yaml"
  found="$(store_reach "$BATS_TEST_TMPDIR/secrets.yaml")"
  echo "with a grant to the Secrets: $found"
  [ "$found" = "ReferenceGrant/monitoring/logs-open lets another namespace refer to the Secrets of monitoring" ]
  # So is the store's own route with its policy failing open, a second object on it, and another
  # route on its host.
  yq '(select(.kind == "SecurityPolicy" and .metadata.namespace == "monitoring") | .spec.extAuth.failOpen) = true' \
    "$EVERYTHING" >"$BATS_TEST_TMPDIR/open.yaml"
  found="$(store_reach "$BATS_TEST_TMPDIR/open.yaml")"
  echo "with the policy failing open: $found"
  [ "$(sort <<<"$found" | paste -sd'|' -)" = "HTTPRoute/monitoring/logs is on the public Gateway and no policy that asks oauth2-proxy targets it|HTTPRoute/monitoring/logs-oauth2 is on the public Gateway and no policy that asks oauth2-proxy targets it|SecurityPolicy/monitoring/logs targets the route logs" ]
  cp "$EVERYTHING" "$BATS_TEST_TMPDIR/host.yaml"
  cat >>"$BATS_TEST_TMPDIR/host.yaml" <<YAML
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hello-logs
  namespace: demo
spec:
  parentRefs:
    - name: public
      namespace: envoy-gateway-system
      sectionName: https
  hostnames:
    - logs.$(yq -e '.CLUSTER_DOMAIN' "$EXAMPLE")
  rules:
    - backendRefs:
        - name: hello
          port: 80
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: logs
  namespace: monitoring
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: logs
YAML
  found="$(store_reach "$BATS_TEST_TMPDIR/host.yaml")"
  echo "with another route on the host and a second object on the route: $found"
  [ "$(sort <<<"$found" | paste -sd'|' -)" = "BackendTrafficPolicy/monitoring/logs targets the route logs|HTTPRoute/demo/hello-logs lists the host of the route logs" ]
  # The same holds of the routes the charts render, and of the Grafana, whose operator would make
  # a route of its own for a spec.httpRoute.
  cluster_render
  found="$(store_reach "$CLUSTER_RENDER"/*/*.yaml)"
  echo "ways to the store past the sign-in in the render: ${found:-none}"
  [ -z "$found" ]
  [ -f "$CLUSTER_RENDER/$ROUTE_APP/HTTPRoute.gateway.networking.k8s.io_monitoring_logs.yaml" ]
  yq '.spec.httpRoute = {"spec": {"parentRefs": [{"name": "public", "namespace": "envoy-gateway-system", "sectionName": "https"}]}}' \
    "$CLUSTER_RENDER"/grafana/Grafana.grafana.integreatly.org_monitoring_grafana.yaml >"$BATS_TEST_TMPDIR/grafana-route.yaml"
  found="$(store_reach "$EVERYTHING" "$BATS_TEST_TMPDIR/grafana-route.yaml")"
  echo "with the Grafana asking for a route: $found"
  [ "$found" = "Grafana/monitoring/grafana has its operator make an HTTPRoute that no policy can be seen to target" ]
}

@test "The log store's route is selected by an overlay entry, builds nothing when it is not, and is refused without vmauth, the Gateway or the sign-in" {
  local entries dependency with without
  # One entry of the overlay, which builds the Kustomization.
  entries="$(grep -c "/$NAMESPACE/$ROUTE_APP/ks.yaml\$" "$REPO/kubernetes/apps/overlays/lab-sto2/kustomization.yaml")"
  [ "$entries" -eq 1 ]
  overlay
  [ "$(NAME="$ROUTE_APP" yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(NAME)) | .spec.path' "$OVERLAY")" \
    = "./apps/base/$NAMESPACE/$ROUTE_APP/app" ]
  with="$(yq -N '.kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$OVERLAY" | sort)"
  # Without it, the overlay builds what it built but that Kustomization, and the tree passes.
  tree_without "$ROUTE_APP"
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  without="$(yq -N '.kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$OVERLAY" | sort)"
  echo "only with the entry: $(comm -23 <(echo "$with") <(echo "$without") | paste -sd' ' -); only without: $(comm -13 <(echo "$with") <(echo "$without") | paste -sd' ' -)"
  [ "$(comm -23 <(echo "$with") <(echo "$without"))" = "Kustomization/flux-system/$ROUTE_APP" ]
  [ -z "$(comm -13 <(echo "$with") <(echo "$without"))" ]
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  # Each application it names, left out, is refused, naming both.
  for dependency in vmauth gateway-public oauth2-proxy blackbox-exporter; do
    tree_without "$dependency"
    run "$REPO/scripts/kubernetes-check" "$TREE"
    echo "without $dependency: status $status"
    [ "$status" -ne 0 ]
    [[ $output == *"kubernetes/apps/base/$NAMESPACE/$ROUTE_APP/ks.yaml: Kustomization $ROUTE_APP names $dependency in dependsOn"* ]] ||
      { echo "$output"; return 1; }
  done
}

@test "The routed paths were read from the VictoriaLogs release the pinned chart deploys" {
  local version pin
  render "$STORE"
  version="$(helm show chart "$CHART" | yq -e '.appVersion')"
  echo "the store's chart $(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT") deploys VictoriaLogs $version"
  [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
  paths_record "$REPO/$ROUTE_FILE" "$version"
  # Renovate moves none of it: the pin check holds the record as moved by hand.
  pin="$(awk -F'\t' -v file="$ROUTE_FILE" '$1 == file && $2 == "victoria-logs-paths"' "$REPO/.renovate/by-hand.tsv")"
  [ -n "$pin" ] || { echo "no row of .renovate/by-hand.tsv for victoria-logs-paths in $ROUTE_FILE"; return 1; }
  # A record of another release than the chart's fails, saying what to read and what to set.
  sed -E 's/^(#[[:blank:]]*victoria-logs-paths:[[:blank:]]*).*/\1v1.0.0/' "$REPO/$ROUTE_FILE" >"$BATS_TEST_TMPDIR/moved.yaml"
  run paths_record "$BATS_TEST_TMPDIR/moved.yaml" "$version"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"read app/victoria-logs/main.go, app/vlselect/main.go, app/vlinsert/main.go, app/vlstorage/main.go"*"at $version again"* ]]
  [[ $output == *"set the record to $version and the Source line to https://github.com/VictoriaMetrics/VictoriaLogs/blob/$version/app/vlselect/main.go"* ]]
}
