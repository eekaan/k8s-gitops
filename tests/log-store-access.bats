#!/usr/bin/env bats
# Proves features/log-store-access.feature; each test carries its scenario's title. Needs helm, flux,
# kustomize, yq, jq, base64 and od on PATH (the versions pinned for the repository). Each chart is
# pulled once per run from its public registry; building and rendering are offline. The
# applications are built in memory, so no build rewrites a file of this checkout.
#
# One test also needs docker: the proof of "The pinned vmauth in front of the pinned VictoriaLogs
# serves each client its own paths and refuses everything else", which runs the store from the image
# its chart's render names and vmauth from the image the build names, each by its reference. It
# skips, saying why, where no docker daemon answers, as in the CI containers; with one, a pull or a
# run that fails is a failure. Its containers have no network, no capability, no privilege
# escalation and a read-only root, run as a user that is not root, mount only directories of the
# test's own, read-only, and are removed with what they made. The credentials are fresh random
# values the test makes; nothing is read from a cluster or this machine's environment.

# The tests run one at a time even where bats runs a file's tests side by side: a test that starts
# while another pulls a chart finds the chart's directory before the chart is in it.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

setup_file() {
  # Helm's cache and registry settings stay in the run's own directory, and so does the Docker
  # configuration helm and docker fall back to for credentials, so no login is read.
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG"
}

setup() {
  # Sorts compare bytes, whatever the machine's locale.
  export LC_ALL=C
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLUSTER="$REPO/kubernetes/clusters/lab-sto2"
  KUBE="$(yq -e '.kubernetes' "$REPO/versions.yaml")"
  NAMESPACE=monitoring
  VMAUTH=vmauth
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
  CONTAINERS=()
}

teardown() {
  local name
  # A container a test started does not outlive it, nor does what it made.
  for name in "${CONTAINERS[@]}"; do
    in_docker rm -f -v "$name" >/dev/null 2>&1 || true
  done
}

# The users of vmauth, each with the placeholder its password is and the Secret and key the
# placeholder's variable is read from; and the store's credential, which vmauth sends on.
USERS="vector grafana logs-route operator"
READERS="grafana logs-route operator"
# Global: bats reads this file inside a function.
declare -gA PLACEHOLDER=([vector]=VECTOR_PASSWORD [grafana]=GRAFANA_PASSWORD [logs-route]=LOGS_ROUTE_PASSWORD [operator]=OPERATOR_PASSWORD)
declare -gA SECRET=([vector]=vmauth-vector [grafana]=vmauth-grafana [logs-route]=vmauth-logs-route [operator]=vmauth-operator)
STORE_SECRET=victoria-logs-auth
# The collector's one path, the bulk API its sink sends to, and the readers' paths: the interface
# and its files, the query handlers, the build information and the tenants, as the route sends them
# on and the Grafana plugin and just logs ask them.
COLLECTOR_PATHS='["/insert/elasticsearch/_bulk"]'
READER_PATHS='["/select/vmui","/select/vmui/.*","/select/logsql/[a-z_]+","/select/buildinfo","/select/tenant_ids"]'
# The templates the ExternalSecrets form the Basic values with, from the generated password.
ROUTE_TEMPLATE='Basic {{ printf "logs-route:%s" .password | b64enc }}'
OPERATOR_TEMPLATE='Basic {{ printf "operator:%s" .password | b64enc }}'
STORE_TEMPLATE='Basic {{ printf "victoria-logs:%s" .password | b64enc }}'

# in_docker ARG...: docker ARG..., run with none of the secrets the environment may hold, as the
# recipes run it (scripts/lib/tools.sh).
in_docker() {
  (
    # shellcheck source=scripts/lib/tools.sh
    . "$REPO/scripts/lib/tools.sh"
    docker "$@"
  )
}

# docker_or_skip: skips the test, saying why, where no docker daemon answers. Past it, whatever
# docker fails at fails the test, a pull of an image included.
docker_or_skip() {
  type -P docker >/dev/null || skip "no docker daemon answers: docker is not on PATH"
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1 ||
    skip "no docker daemon answers: docker version reaches none"
}

# built APP: the application APP of the monitoring namespace as Flux applies it: its app/ built in
# memory with its ks.yaml, substituting strictly the variables of the cluster's example key lists,
# with the ks.yaml's own substitutions over them. Writes $BATS_TEST_TMPDIR/APP-built.yaml and sets
# BUILT.
built() {
  local app=$1 ks="$BATS_TEST_TMPDIR/$1-ks.yaml"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "$EXAMPLE" \
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

# render APP [VALUES]: renders the chart APP's HelmRelease installs, built as built() builds it, with
# the values helm-controller gives the chart: those of the ConfigMap the HelmRelease reads, or of
# the file VALUES in their place, then the HelmRelease's own over them. The monitoring API counts as
# present. Writes $BATS_TEST_TMPDIR/APP.yaml and sets RENDERED, CHART and VALUES.
render() {
  local app=$1 url tag name release namespace inline
  built "$app"
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  VALUES="$BATS_TEST_TMPDIR/$app-values.yaml"
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\") | .data[\"values.yaml\"]" "$BUILT" >"$VALUES"
  [ -s "$VALUES" ] || { echo "$app: no values in the ConfigMap $name its HelmRelease reads"; return 1; }
  inline="$BATS_TEST_TMPDIR/$app-inline.yaml"
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$BUILT" >"$inline"
  pull "$url" "$tag"
  RENDERED="$BATS_TEST_TMPDIR/$app${2:+-other}.yaml"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" --include-crds \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor \
    --api-versions monitoring.coreos.com/v1/PodMonitor \
    --values "${2:-$VALUES}" --values "$inline" >"$RENDERED"
}

# overlay: the cluster's overlay as the root Kustomization builds it. Sets OVERLAY.
overlay() {
  OVERLAY="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "$REPO/kubernetes/apps/overlays/lab-sto2" >"$OVERLAY"
}

# vmauth_built: vmauth as Flux applies it, in VMAUTH_BUILT; its Deployment's pod spec as JSON in
# POD; and its configuration, the auth.yml of the ConfigMap the pod mounts at the directory its
# -auth.config names, parsed, as JSON in AUTH. Fails when the pod mounts none or more than one.
vmauth_built() {
  local file dir map
  built "$VMAUTH"
  VMAUTH_BUILT="$BUILT"
  POD="$BATS_TEST_TMPDIR/vmauth-pod.json"
  yq -N -o json 'select(.kind == "Deployment" and .metadata.name == "vmauth") | .spec.template.spec' "$VMAUTH_BUILT" >"$POD"
  [ "$(jq -r '.containers | length' "$POD")" -eq 1 ] || { echo "the vmauth pod has $(jq -r '.containers | length' "$POD") containers, not one"; return 1; }
  file="$(jq -r '.containers[0].args[] | select(startswith("-auth.config=")) | sub("^-auth.config="; "")' "$POD")"
  [[ $file == /*/auth.yml ]] || { echo "-auth.config names $file, not an auth.yml of a mounted directory"; return 1; }
  dir="${file%/*}"
  # shellcheck disable=SC2016 # $dir and $volumes are jq variables.
  map="$(jq -r --arg dir "$dir" '.volumes as $volumes | .containers[0].volumeMounts[] | select(.mountPath == $dir)
    | .name as $name | $volumes[] | select(.name == $name) | .configMap.name // empty' "$POD")"
  [ "$(grep -c . <<<"$map")" -eq 1 ] || { echo "the pod mounts at $dir: ${map:-no ConfigMap}"; return 1; }
  AUTH_YML="$BATS_TEST_TMPDIR/auth.yml"
  MAP="$map" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(MAP)) | .data["auth.yml"]' "$VMAUTH_BUILT" >"$AUTH_YML"
  AUTH="$BATS_TEST_TMPDIR/auth.json"
  yq -o json '.' "$AUTH_YML" >"$AUTH"
  [ "$(jq -r 'type' "$AUTH")" = object ] || { echo "no auth.yml in the ConfigMap $map"; return 1; }
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

# vmauth_service: "name namespace port" of vmauth's Service and the one port it serves, whose
# target is the container port vmauth proxies on, the one -httpListenAddr names. Needs vmauth_built.
vmauth_service() {
  local listen
  listen="$(jq -r '.containers[0].args[] | select(startswith("-httpListenAddr=")) | sub(".*:"; "")' "$POD")"
  # shellcheck disable=SC2016 # $pod, $service and $listen are jq variables.
  yq -N -o json -I0 'select(.kind == "Service")' "$VMAUTH_BUILT" | jq -rs --slurpfile pod "$POD" --arg listen "$listen" '
    ($pod[0].containers[0].ports // []) as $ports
    | .[] | . as $service | .spec.ports[] | . as $port
    | select(($port.targetPort | tostring) == $listen
        or any($ports[]; .name == ($port.targetPort | tostring) and (.containerPort | tostring) == $listen))
    | "\($service.metadata.name) \($service.metadata.namespace) \($port.port)"'
}

# env_ref NAME: "secret key" that the vmauth container's variable NAME is read from, "value" when it
# has a value, "optional" when the reference may be missing, and nothing when there is no such
# variable. Needs vmauth_built.
env_ref() {
  NAME=$1 jq -r '.containers[0].env // [] | .[] | select(.name == env.NAME)
    | if has("value") then "value"
      elif .valueFrom.secretKeyRef.optional != null then "optional"
      else "\(.valueFrom.secretKeyRef.name // "-") \(.valueFrom.secretKeyRef.key // "-")" end' "$POD"
}

# matching PATTERNS PATH: the patterns of the JSON list PATTERNS that match PATH whole, as vmauth
# matches src_paths, each anchored as ^(?:PATTERN)$ (app/vmauth/auth_config.go, Regex.UnmarshalYAML,
# in VictoriaMetrics v1.156.0). vmauth matches the request's path after path.Clean, with the root
# made empty (normalizeURL in app/vmauth/target_url.go), so the paths given here are clean.
matching() {
  jq -nr --argjson patterns "$1" --arg path "$2" '$patterns[] | select(. as $p | $path | test("^(?:" + $p + ")$"))'
}

@test "Each client of the log store addresses vmauth with a credential of its own from a Secret" {
  local name namespace port store_name store_namespace store_port url client found collector env
  local datasource route filter user depends wait
  vmauth_built
  read -r name namespace port <<<"$(vmauth_service)"
  echo "vmauth's Service: $name $namespace $port"
  [ "$name" = vmauth ] && [ "$namespace" = "$NAMESPACE" ] && [ "$port" = 8427 ]
  render "$STORE"
  read -r store_name store_namespace store_port <<<"$(store_service)"
  echo "the store's Service: $store_name $store_namespace $store_port"
  [ "$store_name" = victoria-logs ] && [ "$store_namespace" = "$NAMESPACE" ] && [ "$store_port" = 9428 ]
  # vmauth sends every user's every path to the store's Service, by the cluster's DNS domain.
  # shellcheck disable=SC2016 # $u is a jq variable.
  [ "$(jq -r '[.users[] | .url_map[] | .url_prefix] | unique | join(" ")' "$AUTH")" \
    = "http://$store_name.$store_namespace.svc.cluster.local:$store_port" ]
  # The store's monitor scrapes the store's Service; it is the store's own, not a client's address.
  # shellcheck disable=SC2016 # $selector and $labels are jq variables.
  [ "$(yq -N -o json -I0 'select(.kind == "ServiceMonitor" or .kind == "Service")' "$RENDERED" | jq -rs --arg name "$store_name" '
    (.[] | select(.kind == "ServiceMonitor") | .spec.selector.matchLabels) as $selector
    | (.[] | select(.kind == "Service" and .metadata.name == $name) | .metadata.labels) as $labels
    | ($selector | length > 0) and ($selector | to_entries | all(.[]; $labels[.key] == .value))')" = true ]

  # The collector: its one sink to the store sends to vmauth's Service and port, by the cluster's DNS
  # domain, as the user vector with a password Vector reads from its environment, which the
  # DaemonSet fills from vmauth-vector, the Secret vmauth reads vector's password from.
  render "$COLLECTOR"
  collector="$RENDERED"
  collector_config
  echo "the store's sink: $(jq -c '.sinks[] | select(.type == "elasticsearch") | {endpoints, auth}' "$CONFIG")"
  [ "$(jq -r '[.sinks[] | select(.type == "elasticsearch")] | length' "$CONFIG")" -eq 1 ]
  url="$(jq -r '.sinks[] | select(.type == "elasticsearch") | .endpoints | if length == 1 then .[0] else error("endpoints: \(.)") end' "$CONFIG")"
  [[ $url =~ ^http://([a-z0-9-]+)\.([a-z0-9-]+)\.svc\.cluster\.local:([0-9]+)/insert/elasticsearch/?$ ]] ||
    { echo "the sink sends to $url"; return 1; }
  [ "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}" = "$name $namespace $port" ]
  # shellcheck disable=SC2016 # ${VMAUTH_PASSWORD} is Vector's placeholder.
  [ "$(jq -cS '.sinks[] | select(.type == "elasticsearch") | .auth' "$CONFIG")" \
    = '{"password":"${VMAUTH_PASSWORD}","strategy":"basic","user":"vector"}' ]
  env="$(yq -N -o json -I0 'select(.kind == "DaemonSet") | .spec.template.spec.containers[] | select(.name == "vector") | .env' "$collector")"
  echo "the collector's environment: $(jq -c '[.[] | select(.name | test("VMAUTH|INTERPOLATION"))]' <<<"$env")"
  [ "$(jq -cS '[.[] | select(.name == "VMAUTH_PASSWORD")]' <<<"$env")" \
    = "$(jq -cnS --arg secret "${SECRET[vector]}" '[{name: "VMAUTH_PASSWORD", valueFrom: {secretKeyRef: {name: $secret, key: "password"}}}]')" ]
  # Vector reads ${VMAUTH_PASSWORD} from its environment only with interpolation allowed, which it
  # is not by default; without it the password would be the placeholder itself (src/cli.rs and
  # src/config/loading/mod.rs, prepare_input, in Vector v0.61.0).
  [ "$(jq -cS '[.[] | select(.name == "VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION")]' <<<"$env")" \
    = '[{"name":"VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION","value":"true"}]' ]
  [ "$(env_ref "${PLACEHOLDER[vector]}")" = "${SECRET[vector]} password" ]
  [ "$(jq -r '.users[] | select(.username == "vector") | .password' "$AUTH")" = "%{${PLACEHOLDER[vector]}}" ]

  # Grafana: the datasource of VictoriaLogs' type sends to vmauth's Service and port as the user
  # grafana, with the password the operator puts in place of ${password} from vmauth-grafana, the
  # Secret vmauth reads grafana's password from. Flux's substitution left the placeholder.
  built grafana
  datasource="$(yq -N -o json -I0 'select(.kind == "GrafanaDatasource" and .spec.datasource.type == "victoriametrics-logs-datasource")' "$BUILT")"
  [ "$(grep -c . <<<"$datasource")" -eq 1 ]
  url="$(jq -r '.spec.datasource.url' <<<"$datasource")"
  [[ $url =~ ^http://([a-z0-9-]+)\.([a-z0-9-]+)\.svc(\.cluster\.local)?:([0-9]+)/?$ ]] || { echo "the datasource sends to $url"; return 1; }
  [ "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[4]}" = "$name $namespace $port" ]
  echo "the datasource: $(jq -cS '.spec | {datasource: (.datasource | {url, basicAuth, basicAuthUser, secureJsonData}), valuesFrom}' <<<"$datasource")"
  [ "$(jq -r '.spec.datasource.basicAuth' <<<"$datasource")" = true ]
  [ "$(jq -r '.spec.datasource.basicAuthUser' <<<"$datasource")" = grafana ]
  # shellcheck disable=SC2016 # ${password} is the operator's placeholder.
  [ "$(jq -cS '.spec.datasource.secureJsonData' <<<"$datasource")" = '{"basicAuthPassword":"${password}"}' ]
  [ "$(jq -cS '.spec.valuesFrom' <<<"$datasource")" = "$(jq -cnS --arg secret "${SECRET[grafana]}" \
    '[{targetPath: "secureJsonData.basicAuthPassword", valueFrom: {secretKeyRef: {name: $secret, key: "password"}}}]')" ]
  [ "$(jq -r '.metadata.annotations["kustomize.toolkit.fluxcd.io/substitute"]' <<<"$datasource")" = disabled ]
  [ "$(env_ref "${PLACEHOLDER[grafana]}")" = "${SECRET[grafana]} password" ]
  [ "$(jq -r '.users[] | select(.username == "grafana") | .password' "$AUTH")" = "%{${PLACEHOLDER[grafana]}}" ]

  # The route: its rule with a backend sends to vmauth's Service and port, through a filter of the
  # route's own that puts the value of vmauth-logs-route's key credential in Authorization, in
  # place of whatever the client sent; vmauth reads the route's password from the same Secret,
  # whose credential is the Basic value of the user logs-route.
  built "$ROUTE_APP"
  route="$(yq -N -o json -I0 'select(.kind == "HTTPRoute" and .metadata.name == "logs")' "$BUILT")"
  echo "the route's rules with a backend: $(jq -c '[.spec.rules[] | select(.backendRefs) | {backendRefs, filters}]' <<<"$route")"
  [ "$(jq -cS '[.spec.rules[] | select(.backendRefs) | .backendRefs[] | {name, port}]' <<<"$route")" \
    = "$(jq -cnS --arg name "$name" --argjson port "$port" '[{name: $name, port: $port}]')" ]
  [ "$(jq -cS '[.spec.rules[] | select(.backendRefs) | .filters // [] | .[]]' <<<"$route")" \
    = '[{"extensionRef":{"group":"gateway.envoyproxy.io","kind":"HTTPRouteFilter","name":"logs"},"type":"ExtensionRef"}]' ]
  filter="$(yq -N -o json -I0 'select(.kind == "HTTPRouteFilter" and .metadata.name == "logs")' "$BUILT")"
  [ "$(jq -r '.metadata.namespace' <<<"$filter")" = "$NAMESPACE" ]
  [ "$(jq -cS '.spec' <<<"$filter")" = "$(jq -cnS --arg secret "${SECRET[logs-route]}" \
    '{credentialInjection: {overwrite: true, credential: {valueRef: {name: $secret}}}}')" ]
  [ "$(env_ref "${PLACEHOLDER[logs-route]}")" = "${SECRET[logs-route]} password" ]
  [ "$(jq -r '.users[] | select(.username == "logs-route") | .password' "$AUTH")" = "%{${PLACEHOLDER[logs-route]}}" ]
  [ "$(NAME="${SECRET[logs-route]}" yq -N 'select(.kind == "ExternalSecret" and .metadata.name == strenv(NAME)) | .spec.target.template.data.credential' "$VMAUTH_BUILT")" \
    = "$ROUTE_TEMPLATE" ]
  # The operator's recipes read the Basic value of the user operator, which vmauth checks against
  # the password of vmauth-operator.
  [ "$(env_ref "${PLACEHOLDER[operator]}")" = "${SECRET[operator]} password" ]
  [ "$(NAME="${SECRET[operator]}" yq -N 'select(.kind == "ExternalSecret" and .metadata.name == strenv(NAME)) | .spec.target.template.data.authorization' "$VMAUTH_BUILT")" \
    = "$OPERATOR_TEMPLATE" ]
  # Four users, four Secrets.
  [ "$(for user in $USERS; do echo "${SECRET[$user]}"; done | sort -u | grep -c .)" -eq 4 ]

  # No client addresses the store's Service: neither the collector's configuration and pods,
  # Grafana's objects nor the route's name it, by its name, its address or its port.
  for client in "$collector" "$CONFIG" "$BUILT" "$BATS_TEST_TMPDIR/grafana-built.yaml"; do
    found="$(yq -N -o json -I0 'select(. != null) | .. | select(tag == "!!str")' "$client" |
      grep -E "victoria-logs\.$store_namespace|//${store_name}[:./]|:$store_port([^0-9]|\$)" || true)"
    [ -z "$found" ] || { echo "$client addresses the store: $found"; return 1; }
  done
  [ -z "$(yq -N '.. | select(tag == "!!map" and has("backendRefs")) | .backendRefs[] | select(.name == "victoria-logs") | .name' "$BUILT")" ]

  # The collector and the route are applied once vmauth is Ready, which is once its pods are
  # available with every Secret in place, after the store, which waits for its own credential.
  overlay
  for client in "$COLLECTOR" "$ROUTE_APP"; do
    depends="$(NAME="$client" yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(NAME)) | .spec.dependsOn // [] | .[].name' "$OVERLAY")"
    echo "$client depends on: $(paste -sd' ' - <<<"$depends")"
    grep -qx "$VMAUTH" <<<"$depends"
  done
  [ -z "$(NAME="$ROUTE_APP" yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(NAME)) | .spec.dependsOn[] | select(.name == "victoria-logs") | .name' "$OVERLAY")" ]
  for client in "$VMAUTH" "$STORE"; do
    wait="$(NAME="$client" yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(NAME)) | .spec.wait' "$OVERLAY")"
    echo "$client waits: $wait"
    [ "$wait" = true ]
  done
  NAME="$VMAUTH" yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(NAME)) | .spec.dependsOn[].name' "$OVERLAY" | grep -qx "$STORE"
  NAME="$STORE" yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(NAME)) | .spec.dependsOn[].name' "$OVERLAY" | grep -qx external-secrets
}

@test "vmauth gives the collector only the insert path and each reader only the query paths" {
  local user keys entry path paths matched
  vmauth_built
  echo "auth.yml: $(jq -c . "$AUTH")"
  # users and nothing else at the top level: no unauthorized_user, no ip_filters, no global setting.
  [ "$(jq -c 'keys' "$AUTH")" = '["users"]' ]
  [ "$(jq -r '[.users[].username] | sort | join(" ")' "$AUTH")" = "grafana logs-route operator vector" ]
  [ "$(jq -r '.users | length' "$AUTH")" -eq 4 ]
  for user in $USERS; do
    # A username, a password that is the placeholder of its own variable, and a url_map, nothing
    # else: no user-level url_prefix or default_url, no request dump, no access log, no IP filter,
    # no JWT, bearer or auth token.
    keys="$(USER_NAME="$user" jq -c '.users[] | select(.username == env.USER_NAME) | keys' "$AUTH")"
    echo "$user: $keys"
    [ "$keys" = '["password","url_map","username"]' ]
    [ "$(USER_NAME="$user" jq -r '.users[] | select(.username == env.USER_NAME) | .password' "$AUTH")" = "%{${PLACEHOLDER[$user]}}" ]
    # Every entry sends to the store's Service and sets the store's credential in place of the
    # client's and the default tenant in place of any the client names (docs/victoriametrics/vmauth.md,
    # Security, in VictoriaMetrics v1.156.0).
    while IFS= read -r entry; do
      [ "$(jq -c 'keys' <<<"$entry")" = '["headers","src_paths","url_prefix"]' ] || { echo "$user's entry $entry"; return 1; }
      [ "$(jq -r '.url_prefix' <<<"$entry")" = http://victoria-logs.monitoring.svc.cluster.local:9428 ]
      [ "$(jq -c '.headers' <<<"$entry")" = '["Authorization: %{STORE_AUTHORIZATION}","AccountID: 0","ProjectID: 0"]' ]
    done < <(USER_NAME="$user" jq -c '.users[] | select(.username == env.USER_NAME) | .url_map[]' "$AUTH")
    paths="$(USER_NAME="$user" jq -c '[.users[] | select(.username == env.USER_NAME) | .url_map[].src_paths[]]' "$AUTH")"
    if [ "$user" = vector ]; then
      [ "$paths" = "$COLLECTOR_PATHS" ]
    else
      [ "$paths" = "$READER_PATHS" ]
    fi
    # Every pattern is literals, ., *, +, a bracket class and a group, which jq's regular
    # expressions read as RE2, vmauth's, does.
    while IFS= read -r path; do
      [[ $path =~ ^([A-Za-z0-9/_-]|\.|\*|\+|\[[a-z_-]+\]|\(|\)|\|)+$ ]] || { echo "$user's path $path uses more than this test evaluates"; return 1; }
    done < <(jq -r '.[]' <<<"$paths")
  done

  # What each user's paths match, anchored as vmauth matches them.
  local collector_admits=(/insert/elasticsearch/_bulk)
  local reader_admits=(/select/vmui /select/vmui/ /select/vmui/index.html /select/vmui/assets/index-DNKuoEMC.js
    /select/vmui/config.json /select/logsql/query /select/logsql/hits /select/logsql/facets /select/logsql/field_names
    /select/logsql/field_values /select/logsql/stats_query /select/logsql/stats_query_range /select/logsql/stream_field_names
    /select/logsql/stream_field_values /select/logsql/stream_ids /select/logsql/streams /select/logsql/query_time_range
    /select/logsql/tail /select/buildinfo /select/tenant_ids)
  # The writers, every insert API of the store and the bulk API's neighbours.
  local writers=(/insert/elasticsearch/_bulk /insert/elasticsearch/ /insert/elasticsearch /insert/elasticsearch/_bulk/x
    /insert/jsonline /insert/loki/api/v1/push /insert/opentelemetry/v1/logs /insert/journald/upload
    /insert/datadog/api/v2/logs /insert/native /insert/ready)
  # The reads, which the collector never needs.
  local reads=(/select/logsql/query /select/logsql/tail /select/logsql/hits /select/vmui /select/vmui/
    /select/vmui/index.html /select/buildinfo /select/tenant_ids /select/vmalert/api/v1/rules)
  # What no user reaches: the root, empty once vmauth has cleaned it, deletion, storage
  # administration and the cluster's internal paths, the store's and vmauth's own endpoints, the
  # vmalert proxy, the other writers' APIs, and the readers' paths changed by a suffix or a slash.
  local nobody=('' / /delete/run_task /delete/stop_task /delete/active_tasks /internal/insert /internal/select/query
    /internal/select/tenant_ids /internal/delete/run_task /internal/force_merge /internal/force_flush
    /internal/log_new_streams /internal/partition/list /internal/partition/detach /internal/partition/attach
    /internal/partition/snapshot/create /metrics /flags /debug/pprof/ /debug/pprof/cmdline /debug/pprof/heap /health
    /ping /-/healthy /-/ready /-/reload /robots.txt /favicon.ico /select/vmalert/api/v1/rules /api/v2/logs
    /api/v1/validate /services/collector/event /services/collector/health /select /select/ /select/vmuix
    /select/logsql /select/logsql/ /select/logsqlx/query /select/logsql/query/x /select/buildinfo/ /select/tenant_ids/x
    /SELECT/vmui/ /_vmauth/sso/start)
  for path in "${collector_admits[@]}"; do
    matched="$(matching "$(jq -c '[.users[] | select(.username == "vector") | .url_map[].src_paths[]]' "$AUTH")" "$path")"
    [ -n "$matched" ] || { echo "the collector's paths do not match $path"; return 1; }
  done
  for user in $READERS; do
    paths="$(USER_NAME="$user" jq -c '[.users[] | select(.username == env.USER_NAME) | .url_map[].src_paths[]]' "$AUTH")"
    for path in "${reader_admits[@]}"; do
      [ -n "$(matching "$paths" "$path")" ] || { echo "$user's paths do not match $path"; return 1; }
    done
    for path in "${writers[@]}"; do
      matched="$(matching "$paths" "$path")"
      [ -z "$matched" ] || { echo "$user's path $matched matches the writer $path"; return 1; }
    done
  done
  paths="$(jq -c '[.users[] | select(.username == "vector") | .url_map[].src_paths[]]' "$AUTH")"
  for path in "${reads[@]}"; do
    matched="$(matching "$paths" "$path")"
    [ -z "$matched" ] || { echo "the collector's path $matched matches the read $path"; return 1; }
  done
  for user in $USERS; do
    paths="$(USER_NAME="$user" jq -c '[.users[] | select(.username == env.USER_NAME) | .url_map[].src_paths[]]' "$AUTH")"
    for path in "${nobody[@]}"; do
      matched="$(matching "$paths" "$path")"
      [ -z "$matched" ] || { echo "$user's path $matched matches '$path'"; return 1; }
    done
  done
}

@test "Every credential of the log store is generated in the cluster and appears in no manifest, argument or log setting" {
  local name placeholders envs generator external keys template app file found args
  vmauth_built
  # Each placeholder of the configuration is a variable of the container, from a Secret's key by
  # reference, never optional and never a value: a variable that is missing leaves vmauth the
  # literal %{NAME} as the password (lib/envtemplate/envtemplate.go in VictoriaMetrics v1.156.0),
  # and the pod does not start while the Secret or its key is missing.
  # vmauth puts each %{NAME} in place in the file's text before it parses it, comments included.
  placeholders="$(grep -oE '%\{[^}]*\}' "$AUTH_YML" | sort -u | tr -d '%{}')"
  echo "placeholders: $(paste -sd' ' - <<<"$placeholders")"
  [ "$placeholders" = "$(printf '%s\n' GRAFANA_PASSWORD LOGS_ROUTE_PASSWORD OPERATOR_PASSWORD STORE_AUTHORIZATION VECTOR_PASSWORD)" ]
  envs="$(jq -r '.containers[0].env // [] | .[].name' "$POD" | sort)"
  [ "$envs" = "$placeholders" ] || { echo "the container's variables: $(paste -sd' ' - <<<"$envs")"; return 1; }
  [ "$(jq -r '[.containers[0].env[] | select(has("value") or ((.valueFrom // {}) | keys) != ["secretKeyRef"]
    or ((.valueFrom.secretKeyRef // {}) | keys | sort) != ["key", "name"])] | length' "$POD")" -eq 0 ]
  [ "$(jq -r '.containers[0].envFrom // [] | length' "$POD")" -eq 0 ]
  [ "$(env_ref VECTOR_PASSWORD)" = "vmauth-vector password" ]
  [ "$(env_ref GRAFANA_PASSWORD)" = "vmauth-grafana password" ]
  [ "$(env_ref LOGS_ROUTE_PASSWORD)" = "vmauth-logs-route password" ]
  [ "$(env_ref OPERATOR_PASSWORD)" = "vmauth-operator password" ]
  [ "$(env_ref STORE_AUTHORIZATION)" = "$STORE_SECRET authorization" ]

  # Each of vmauth's Secrets is written once by an ExternalSecret of its name from a Password
  # generator of its name: 32 characters hex-encoded, 64 hexadecimal digits, so no value holds a
  # character a placeholder, YAML or a header could read.
  local -A template=([vmauth-vector]='' [vmauth-grafana]='' [vmauth-logs-route]="{\"credential\":$(jq -n --arg t "$ROUTE_TEMPLATE" '$t')}"
    [vmauth-operator]="{\"authorization\":$(jq -n --arg t "$OPERATOR_TEMPLATE" '$t')}" [vmauth-keys]='')
  local -A secret_keys=([vmauth-vector]='["password"]' [vmauth-grafana]='["password"]' [vmauth-logs-route]='["password"]'
    [vmauth-operator]='["password"]' [vmauth-keys]='["flags","pprof","reload"]')
  [ "$(yq -N 'select(.kind == "Password") | .metadata.name' "$VMAUTH_BUILT" | sort | paste -sd' ' -)" \
    = "vmauth-grafana vmauth-keys vmauth-logs-route vmauth-operator vmauth-vector" ]
  [ "$(yq -N 'select(.kind == "ExternalSecret") | .metadata.name' "$VMAUTH_BUILT" | sort | paste -sd' ' -)" \
    = "vmauth-grafana vmauth-keys vmauth-logs-route vmauth-operator vmauth-vector" ]
  for name in "${!secret_keys[@]}"; do
    generator="$(NAME="$name" yq -N -o json -I0 'select(.kind == "Password" and .metadata.name == strenv(NAME))' "$VMAUTH_BUILT")"
    echo "$name: $(jq -cS '.spec' <<<"$generator")"
    [ "$(jq -r '.apiVersion' <<<"$generator")" = generators.external-secrets.io/v1alpha1 ]
    [ "$(jq -cS '.spec' <<<"$generator")" = "$(jq -cnS --argjson keys "${secret_keys[$name]}" \
      '{length: 32, allowRepeat: true, noUpper: false, encoding: "hex", secretKeys: $keys}')" ]
    external="$(NAME="$name" yq -N -o json -I0 'select(.kind == "ExternalSecret" and .metadata.name == strenv(NAME))' "$VMAUTH_BUILT")"
    echo "$name: $(jq -cS '.spec' <<<"$external")"
    [ "$(jq -r '.apiVersion' <<<"$external")" = external-secrets.io/v1 ]
    if [ -n "${template[$name]}" ]; then
      # The generated key is kept beside the template's: the template's merge policy is Merge, as
      # Replace, the default, keeps only what the template makes (docs/guides/templating.md,
      # MergePolicy, in External Secrets v2.15.0).
      [ "$(jq -cS '.spec' <<<"$external")" = "$(jq -cnS --arg name "$name" --argjson data "${template[$name]}" '{
        refreshPolicy: "CreatedOnce",
        target: {name: $name, creationPolicy: "Owner", template: {engineVersion: "v2", mergePolicy: "Merge", data: $data}},
        dataFrom: [{sourceRef: {generatorRef: {apiVersion: "generators.external-secrets.io/v1alpha1", kind: "Password", name: $name}}}]}')" ]
    else
      [ "$(jq -cS '.spec' <<<"$external")" = "$(jq -cnS --arg name "$name" '{
        refreshPolicy: "CreatedOnce", target: {name: $name, creationPolicy: "Owner"},
        dataFrom: [{sourceRef: {generatorRef: {apiVersion: "generators.external-secrets.io/v1alpha1", kind: "Password", name: $name}}}]}')" ]
    fi
  done
  # The store's credential, in the store's own application: its username and its Basic value beside
  # the generated password.
  render "$STORE"
  generator="$(yq -N -o json -I0 'select(.kind == "Password")' "$BUILT")"
  external="$(yq -N -o json -I0 'select(.kind == "ExternalSecret")' "$BUILT")"
  echo "the store's credential: $(jq -cS '.spec' <<<"$external")"
  [ "$(jq -r '.metadata.name' <<<"$generator") $(jq -r '.metadata.name' <<<"$external")" = "$STORE_SECRET $STORE_SECRET" ]
  [ "$(jq -cS '.spec' <<<"$generator")" = '{"allowRepeat":true,"encoding":"hex","length":32,"noUpper":false,"secretKeys":["password"]}' ]
  [ "$(jq -cS '.spec' <<<"$external")" = "$(jq -cnS --arg name "$STORE_SECRET" --arg template "$STORE_TEMPLATE" '{
    refreshPolicy: "CreatedOnce",
    target: {name: $name, creationPolicy: "Owner",
      template: {engineVersion: "v2", mergePolicy: "Merge", data: {username: "victoria-logs", authorization: $template}}},
    dataFrom: [{sourceRef: {generatorRef: {apiVersion: "generators.external-secrets.io/v1alpha1", kind: "Password", name: $name}}}]}')" ]
  cp "$RENDERED" "$BATS_TEST_TMPDIR/store-rendered.yaml"

  # Nothing of the five applications, built or rendered, is a Secret, and every password, credential,
  # authorization and header value, wherever it is, is a placeholder or an ExternalSecret's template.
  render "$COLLECTOR"
  cp "$RENDERED" "$BATS_TEST_TMPDIR/collector-rendered.yaml"
  collector_config
  for app in grafana "$ROUTE_APP"; do built "$app"; done
  local files=("$VMAUTH_BUILT" "$BATS_TEST_TMPDIR/$STORE-built.yaml" "$BATS_TEST_TMPDIR/store-rendered.yaml"
    "$BATS_TEST_TMPDIR/$COLLECTOR-built.yaml" "$BATS_TEST_TMPDIR/collector-rendered.yaml"
    "$BATS_TEST_TMPDIR/grafana-built.yaml" "$BATS_TEST_TMPDIR/$ROUTE_APP-built.yaml")
  found="$(yq -N 'select(.kind == "Secret") | .kind + "/" + .metadata.name' "${files[@]}")"
  [ -z "$found" ] || { echo "Secrets in the builds and renders: $found"; return 1; }
  # The embedded configurations count as objects too: vmauth's and the collector's.
  local allowed
  allowed="$(jq -cn --arg route "$ROUTE_TEMPLATE" --arg operator "$OPERATOR_TEMPLATE" --arg store "$STORE_TEMPLATE" \
    '["%{VECTOR_PASSWORD}", "%{GRAFANA_PASSWORD}", "%{LOGS_ROUTE_PASSWORD}", "%{OPERATOR_PASSWORD}",
      "Authorization: %{STORE_AUTHORIZATION}", "${VMAUTH_PASSWORD}", "${password}", $route, $operator, $store]')"
  # shellcheck disable=SC2016 # $allowed is a jq variable.
  found="$({ yq -N -o json -I0 'select(. != null)' "${files[@]}"; jq -c . "$AUTH" "$CONFIG"; } | jq -r --argjson allowed "$allowed" '
    paths(type == "string") as $p | getpath($p) as $v | ($p[-1] | tostring) as $key
    | select(($key | test("^(password|basicauthpassword|credential|authorization|token|bearer_token|auth_token|api_key|apikey)$"; "i"))
        or ($p | map(tostring) | any(. == "secureJsonData"))
        or ($v | test("^(authorization:|basic |bearer )"; "i")))
    | select(($allowed | index($v)) == null)
    | "\($p | map(tostring) | join(".")): \($v)"')"
  [ -z "$found" ] || { echo "values that are no placeholder or template: $found"; return 1; }
  # The Grafana operator's datasource carries the placeholder past Flux, which substitutes ${...}
  # in every child's objects but those that opt out.
  # shellcheck disable=SC2016 # ${password} is the operator's placeholder.
  [ "$(yq -N 'select(.kind == "GrafanaDatasource" and .metadata.name == "victoria-logs") | .spec.datasource.secureJsonData.basicAuthPassword' \
    "$BATS_TEST_TMPDIR/grafana-built.yaml")" = '${password}' ]
  # shellcheck disable=SC2016 # ${VMAUTH_PASSWORD} is Vector's placeholder.
  [ "$(jq -r '[.sinks[] | .. | objects | select(has("password")) | .password] | join(" ")' "$CONFIG")" = '${VMAUTH_PASSWORD}' ]

  # Every container argument is free of a credential: vmauth's keys are files it reads, and nothing
  # sets a password, a key or Basic Auth on a command line.
  args="$(yq -N '.. | select(tag == "!!map" and has("containers")) | (.containers + (.initContainers // []))[] | (.command // []) + (.args // []) | .[]' "${files[@]}")"
  found="$(grep -iE '(authkey|password|passwd|token|secret|credential|httpauth)' <<<"$args" | grep -vE '^-(flags|pprof|reload)AuthKey=file:///' || true)"
  [ -z "$found" ] || { echo "arguments that carry a credential: $found"; return 1; }
  [ "$(jq -r '.containers[0].args[] | select(test("AuthKey="))' "$POD" | sort | paste -sd' ' -)" \
    = "$(jq -r '.containers[0].args[] | select(test("^-(flags|pprof|reload)AuthKey=file:///[^ ]+$"))' "$POD" | sort | paste -sd' ' -)" ]
  [ "$(jq -r '.containers[0].args[] | select(test("AuthKey="))' "$POD" | grep -c .)" -eq 3 ]
  # vmauth neither logs the tokens it refuses nor reads its flags from its environment nor checks a
  # Basic Auth of its own, and its configuration dumps no request and logs no access.
  [ "$(jq -r '.containers[0].args[] | select(test("^-(logInvalidAuthTokens|envflag\\.|httpAuth\\.)"))' "$POD")" = "" ]
  [ "$(jq -r '[.. | objects | select(has("dump_request_on_errors") or has("access_log"))] | length' "$AUTH")" -eq 0 ]
  # The Grafana operator logs the value it puts in place of ${password} at verbosity 1
  # (controllers/datasource_controller.go in grafana-operator v5.25.0): it runs at info.
  render grafana-operator
  args="$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "grafana-operator") | .args[]' "$RENDERED")"
  echo "the Grafana operator's arguments: $(paste -sd' ' - <<<"$args")"
  [ "$(grep -E '^--zap-(log-level|devel)' <<<"$args")" = "--zap-log-level=info" ]
}

@test "vmauth runs pinned and restricted, two replicas apart, with its own endpoints on a port it does not proxy" {
  local deployment ks image pin depends file mounts budget monitor service args
  local deployment_file="$REPO/kubernetes/apps/base/$NAMESPACE/$VMAUTH/app/deployment.yaml"
  # An application of monitoring, listed once in the overlay, that waits, after External Secrets
  # for its Secrets' kinds, the store, which it sends to with the store's credential, and the
  # monitoring definitions for its PodMonitor.
  ks="$REPO/kubernetes/apps/base/$NAMESPACE/$VMAUTH/ks.yaml"
  [ "$(grep -c "/$NAMESPACE/$VMAUTH/ks.yaml\$" "$REPO/kubernetes/apps/overlays/lab-sto2/kustomization.yaml")" -eq 1 ]
  [ "$(yq '.metadata.name + " " + .metadata.namespace + " " + .spec.path + " " + .spec.targetNamespace' "$ks")" \
    = "vmauth flux-system ./apps/base/$NAMESPACE/$VMAUTH/app $NAMESPACE" ]
  [ "$(yq '.spec.wait' "$ks")" = true ]
  depends="$(yq '.spec.dependsOn | map(.name) | sort | join(" ")' "$ks")"
  echo "vmauth depends on: $depends"
  [ "$depends" = "external-secrets prometheus-operator-crds victoria-logs" ]
  [ "$(yq -o json -I0 '.spec.sourceRef' "$ks")" = '{"kind":"ExternalArtifact","name":"vmauth"}' ]
  vmauth_built
  [ "$(yq -N 'select(.kind != null) | .kind + "/" + .metadata.namespace + "/" + .metadata.name' "$VMAUTH_BUILT" | sed 's#^\(ConfigMap/monitoring/vmauth-config\)-[a-z0-9]*$#\1#' | sort | paste -sd' ' -)" \
    = "ConfigMap/monitoring/vmauth-config Deployment/monitoring/vmauth ExternalSecret/monitoring/vmauth-grafana ExternalSecret/monitoring/vmauth-keys ExternalSecret/monitoring/vmauth-logs-route ExternalSecret/monitoring/vmauth-operator ExternalSecret/monitoring/vmauth-vector Password/monitoring/vmauth-grafana Password/monitoring/vmauth-keys Password/monitoring/vmauth-logs-route Password/monitoring/vmauth-operator Password/monitoring/vmauth-vector PodDisruptionBudget/monitoring/vmauth PodMonitor/monitoring/vmauth Service/monitoring/vmauth" ]
  deployment="$(yq -N -o json -I0 'select(.kind == "Deployment")' "$VMAUTH_BUILT")"

  # The image by tag and digest, the index's, under the comment Renovate reads, with the form of its
  # tags and the record of what Renovate extracts.
  image="$(jq -r '.containers[0].image' "$POD")"
  echo "image: $image"
  [ "$image" = docker.io/victoriametrics/vmauth:v1.156.0@sha256:e4b739ed468de88906550911c03fee2b0da89785679343a006639b8f471df051 ]
  pin="$(grep -B1 -E '^[[:blank:]]+image: ' "$deployment_file" | head -n 1 | sed 's/^[[:blank:]]*//')"
  [ "$pin" = "# renovate: datasource=docker depName=docker.io/victoriametrics/vmauth" ]
  [ "$(awk -F'\t' '$1 == "docker" && $2 == "docker.io/victoriametrics/vmauth" { print $3 }' "$REPO/.renovate/tag-forms.tsv")" = '^v[0-9]+\.[0-9]+\.[0-9]+$' ]
  [ "$(awk -F'\t' -v file="kubernetes/apps/base/$NAMESPACE/$VMAUTH/app/deployment.yaml" '$1 == file { print $2 " " $3 " " $4 }' "$REPO/.renovate/extracted.tsv" | sort | paste -sd'|' -)" \
    = "kubernetes docker.io/victoriametrics/vmauth -|regex docker.io/victoriametrics/vmauth image" ]

  # Two replicas, on different nodes, replaced one at a time with neither down, and a budget that
  # keeps one while a drain evicts the other.
  [ "$(jq -r '.spec.replicas' <<<"$deployment")" -eq 2 ]
  [ "$(jq -cS '.spec.strategy' <<<"$deployment")" = '{"rollingUpdate":{"maxUnavailable":0},"type":"RollingUpdate"}' ]
  [ "$(jq -cS '.spec.selector.matchLabels' <<<"$deployment")" = '{"app.kubernetes.io/name":"vmauth"}' ]
  [ "$(jq -cS '.topologySpreadConstraints' "$POD")" = '[{"labelSelector":{"matchLabels":{"app.kubernetes.io/name":"vmauth"}},"maxSkew":1,"nodeTaintsPolicy":"Honor","topologyKey":"kubernetes.io/hostname","whenUnsatisfiable":"DoNotSchedule"}]' ]
  budget="$(yq -N -o json -I0 'select(.kind == "PodDisruptionBudget")' "$VMAUTH_BUILT")"
  [ "$(jq -cS '.spec' <<<"$budget")" = '{"minAvailable":1,"selector":{"matchLabels":{"app.kubernetes.io/name":"vmauth"}}}' ]

  # Restricted: not root, user and group 65534, the runtime's seccomp profile, no capability, no
  # escalation, a read-only root, no token for the API server, requests and a memory limit.
  [ "$(jq -cS '.securityContext' "$POD")" = '{"runAsGroup":65534,"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}}' ]
  [ "$(jq -cS '.containers[0].securityContext' "$POD")" = '{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}' ]
  [ "$(jq -r '.automountServiceAccountToken' "$POD")" = false ]
  [ "$(jq -r '[.hostNetwork, .hostPID, .hostIPC] | map(. // false) | any' "$POD")" = false ]
  [ "$(jq -r '.containers[0].resources | [.requests.cpu, .requests.memory, .limits.memory] | map(. // "") | all(. != "")' "$POD")" = true ]
  [ "$(jq -r '.initContainers // [] | length' "$POD")" -eq 0 ]

  # Its arguments: the configuration, the proxy's port, its own endpoints on another, each key a
  # file of the keys' Secret, a shutdown delay, JSON logs, and nothing else.
  args="$(jq -r '.containers[0].args[]' "$POD")"
  echo "arguments: $(paste -sd' ' - <<<"$args")"
  [ "$(sed -E 's#^(-(flags|pprof|reload)AuthKey=file://)/[^ ]*/(flags|pprof|reload)$#\1<keys>/\3#; s#^-auth.config=/.*/auth.yml$#-auth.config=<config>/auth.yml#' <<<"$args" | sort | paste -sd' ' -)" \
    = "-auth.config=<config>/auth.yml -flagsAuthKey=file://<keys>/flags -http.shutdownDelay=5s -httpInternalListenAddr=:8426 -httpListenAddr=:8427 -loggerFormat=json -pprofAuthKey=file://<keys>/pprof -reloadAuthKey=file://<keys>/reload" ]
  # The configuration from the generated ConfigMap and the keys from their Secret, each mounted
  # read-only where the arguments read them.
  mounts="$(jq -r '.volumes as $volumes | .containers[0].volumeMounts[] | . as $m | $volumes[] | select(.name == $m.name)
    | "\($m.mountPath) \(if .configMap then "configMap/" + .configMap.name elif .secret then "secret/" + .secret.secretName else "other" end) \($m.readOnly // false) \(.secret.optional // .configMap.optional // false)"' "$POD" | sort)"
  echo "mounts: $(paste -sd, - <<<"$mounts")"
  [ "$(grep -c . <<<"$mounts")" -eq 2 ]
  file="$(jq -r '.containers[0].args[] | select(startswith("-auth.config=")) | sub("^-auth.config="; "")' "$POD")"
  grep -qE "^${file%/*} configMap/vmauth-config-[a-z0-9]+ true false\$" <<<"$mounts"
  file="$(jq -r '.containers[0].args[] | select(startswith("-flagsAuthKey=")) | sub("^-flagsAuthKey=file://"; "")' "$POD")"
  grep -qx "${file%/*} secret/vmauth-keys true false" <<<"$mounts"
  [ "$(yq -N 'select(.kind == "ConfigMap") | .metadata.annotations["kustomize.toolkit.fluxcd.io/substitute"]' "$VMAUTH_BUILT")" = disabled ]

  # It proxies on http, 8427, which the Service serves alone, and serves its health, metrics and
  # keyed endpoints on internal, 8426, where both probes and the PodMonitor reach it.
  [ "$(jq -cS '.containers[0].ports' "$POD")" = '[{"containerPort":8427,"name":"http"},{"containerPort":8426,"name":"internal"}]' ]
  [ "$(jq -cS '.containers[0].readinessProbe.httpGet' "$POD")" = '{"path":"/health","port":"internal"}' ]
  [ "$(jq -cS '.containers[0].livenessProbe.httpGet' "$POD")" = '{"path":"/health","port":"internal"}' ]
  service="$(yq -N -o json -I0 'select(.kind == "Service")' "$VMAUTH_BUILT")"
  [ "$(jq -cS '.spec' <<<"$service")" = '{"ports":[{"name":"http","port":8427,"targetPort":"http"}],"selector":{"app.kubernetes.io/name":"vmauth"}}' ]
  monitor="$(yq -N -o json -I0 'select(.kind == "PodMonitor")' "$VMAUTH_BUILT")"
  [ "$(jq -cS '.spec' <<<"$monitor")" = '{"podMetricsEndpoints":[{"path":"/metrics","port":"internal"}],"selector":{"matchLabels":{"app.kubernetes.io/name":"vmauth"}}}' ]
  [ "$(jq -cS '.spec.template.metadata.labels' <<<"$deployment")" = '{"app.kubernetes.io/name":"vmauth"}' ]
}

@test "The store's scrape presents the store's credential and the store's pod is unchanged" {
  local monitor bare ks statefulset other
  ks="$REPO/kubernetes/apps/base/$NAMESPACE/$STORE/ks.yaml"
  # The store's application waits, and comes after External Secrets, whose kinds its credential is.
  [ "$(yq '.spec.wait' "$ks")" = true ]
  yq '.spec.dependsOn[].name' "$ks" | grep -qx external-secrets
  render "$STORE"
  monitor="$(yq -N -o json -I0 'select(.kind == "ServiceMonitor")' "$RENDERED")"
  echo "the store's monitor: $(jq -cS '.spec.endpoints' <<<"$monitor")"
  [ "$(jq -r '.spec.endpoints | length' <<<"$monitor")" -eq 1 ]
  [ "$(jq -cS '.spec.endpoints[0].basicAuth' <<<"$monitor")" = "$(jq -cnS --arg name "$STORE_SECRET" \
    '{username: {name: $name, key: "username"}, password: {name: $name, key: "password"}}')" ]
  # Its Secret is the one the application's ExternalSecret writes, with those keys.
  [ "$(yq -N 'select(.kind == "ExternalSecret") | .spec.target.name' "$BUILT")" = "$STORE_SECRET" ]
  [ "$(yq -N 'select(.kind == "ExternalSecret") | .spec.target.template.data | keys | .[]' "$BUILT" | sort | paste -sd' ' -)" = "authorization username" ]
  [ "$(yq -N 'select(.kind == "Password") | .spec.secretKeys[]' "$BUILT")" = password ]
  # The StatefulSet is byte for byte the one the chart renders from the same values less the scrape's
  # credential, so the credential reaches the monitor alone and the store's pod does not change with
  # it; its probes are the chart's, /health for readiness, which the store answers without a
  # credential, and a TCP connection for liveness.
  statefulset="$(yq -N 'select(.kind == "StatefulSet")' "$RENDERED")"
  [ -n "$statefulset" ]
  bare="$BATS_TEST_TMPDIR/store-values-bare.yaml"
  yq 'del(.server.serviceMonitor.basicAuth)' "$VALUES" >"$bare"
  if cmp -s "$VALUES" "$bare"; then echo "the values set no credential for the scrape"; return 1; fi
  render "$STORE" "$bare"
  other="$(yq -N 'select(.kind == "StatefulSet")' "$RENDERED")"
  diff <(echo "$other") <(echo "$statefulset")
  [ -z "$(yq -N 'select(.kind == "ServiceMonitor") | .spec.endpoints[0].basicAuth // ""' "$RENDERED")" ]
  [ "$(yq -o json -I0 '.spec.template.spec.containers[0].readinessProbe.httpGet | pick(["path", "port"])' <<<"$statefulset")" = '{"path":"/health","port":"http"}' ]
  [ "$(yq -o json -I0 '.spec.template.spec.containers[0].livenessProbe.tcpSocket' <<<"$statefulset")" = '{"port":"http"}' ]
}

# hex: 32 random bytes as 64 hexadecimal digits, the form the Password generators make.
hex() {
  od -An -tx1 -N32 /dev/urandom | tr -d ' \n'
}

@test "The pinned vmauth in front of the pinned VictoriaLogs serves each client its own paths and refuses everything else" {
  local store_image vmauth_image user group config_dir keys_dir host prefix listen work name store vmauth client
  local -a store_args vmauth_args
  local -A password
  # The route's user, by a name shellcheck reads as a key rather than arithmetic.
  local route_user=logs-route
  docker_or_skip
  # The images by the references the render and the build give, never a literal.
  render "$STORE"
  store_image="$(yq -N 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].image' "$RENDERED")"
  mapfile -t store_args < <(yq -N 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].args[]' "$RENDERED")
  listen="$(printf '%s\n' "${store_args[@]}" | sed -n 's/^--httpListenAddr=.*://p')"
  vmauth_built
  vmauth_image="$(jq -r '.containers[0].image' "$POD")"
  mapfile -t vmauth_args < <(jq -r '.containers[0].args[]' "$POD")
  user="$(jq -r '.securityContext.runAsUser' "$POD")"
  group="$(jq -r '.securityContext.runAsGroup' "$POD")"
  echo "the store: $store_image ${store_args[*]}; vmauth: $vmauth_image ${vmauth_args[*]}; as $user:$group"
  [[ $user =~ ^[1-9][0-9]*$ && $group =~ ^[1-9][0-9]*$ ]]
  # The store's Service, as vmauth's url_prefix names it, resolves to the loopback the store shares
  # with vmauth.
  prefix="$(jq -r '[.users[].url_map[].url_prefix] | unique | .[]' "$AUTH")"
  [[ $prefix =~ ^http://([a-z0-9.-]+):([0-9]+)$ ]] || { echo "url_prefix: $prefix"; return 1; }
  host="${BASH_REMATCH[1]}"
  [ "${BASH_REMATCH[2]}" = "$listen" ]
  config_dir="$(jq -r '.containers[0].args[] | select(startswith("-auth.config=")) | sub("^-auth.config="; "") | sub("/[^/]*$"; "")' "$POD")"
  keys_dir="$(jq -r '.containers[0].args[] | select(startswith("-flagsAuthKey=file://")) | sub("^-flagsAuthKey=file://"; "") | sub("/[^/]*$"; "")' "$POD")"

  # Fresh credentials: each user's password, the keys, and the store's password, from which the
  # store's and the route's Basic values are formed as the ExternalSecrets' templates form them.
  work="$BATS_TEST_TMPDIR/live"
  mkdir -p "$work/store-auth" "$work/config" "$work/keys" "$work/client"
  for name in $USERS store flags pprof reload; do password[$name]="$(hex)"; done
  printf '%s' "${password[store]}" >"$work/store-auth/password"
  for name in flags pprof reload; do printf '%s' "${password[$name]}" >"$work/keys/$name"; done
  basic() { printf 'Basic %s' "$(printf '%s:%s' "$1" "$2" | base64 -w0)"; }
  {
    echo "VECTOR_PASSWORD=${password[vector]}"
    echo "GRAFANA_PASSWORD=${password[grafana]}"
    echo "LOGS_ROUTE_PASSWORD=${password[$route_user]}"
    echo "OPERATOR_PASSWORD=${password[operator]}"
    echo "STORE_AUTHORIZATION=$(basic victoria-logs "${password[store]}")"
  } >"$work/env"
  # Every variable the Deployment sets is here, and nothing else.
  [ "$(cut -d= -f1 "$work/env" | sort | paste -sd' ' -)" = "$(jq -r '.containers[0].env[].name' "$POD" | sort | paste -sd' ' -)" ]
  MAP="$(jq -r '.volumes[] | select(.configMap) | .configMap.name' "$POD")" \
    yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(MAP)) | .data["auth.yml"]' "$VMAUTH_BUILT" >"$work/config/auth.yml"
  chmod 0755 "$work" "$work"/*/
  chmod 0644 "$work"/*/*

  in_docker pull --quiet "$store_image" >/dev/null
  in_docker pull --quiet "$vmauth_image" >/dev/null
  store="log-store-access-store-$$-$RANDOM"
  vmauth="log-store-access-vmauth-$$-$RANDOM"
  client="log-store-access-client-$$-$RANDOM"
  CONTAINERS=("$client" "$vmauth" "$store")
  # The store, started with flags that require the store's credential, from a file written above,
  # its data on a tmpfs.
  in_docker run --detach --name "$store" --network none --read-only --tmpfs /storage:mode=0777 --cap-drop ALL \
    --security-opt no-new-privileges --user "$user:$group" --add-host "$host:127.0.0.1" -v "$work/store-auth:/run/store-auth:ro" \
    "$store_image" "${store_args[@]}" -httpAuth.username=victoria-logs -httpAuth.password=file:///run/store-auth/password >/dev/null
  # vmauth as the Deployment runs it, in the store's network namespace.
  in_docker run --detach --name "$vmauth" --network "container:$store" --read-only --cap-drop ALL \
    --security-opt no-new-privileges --user "$user:$group" --env-file "$work/env" \
    -v "$work/config:$config_dir:ro" -v "$work/keys:$keys_dir:ro" "$vmauth_image" "${vmauth_args[@]}" >/dev/null
  # The client: busybox's wget of vmauth's image, in the same namespace.
  in_docker run --detach --name "$client" --network "container:$store" --read-only --cap-drop ALL \
    --security-opt no-new-privileges --user "$user:$group" --tmpfs /out:mode=0777 -v "$work/client:/client:ro" \
    --entrypoint sleep "$vmauth_image" 600 >/dev/null

  # status OUT ARG...: the status of the first answer wget -S prints for wget ARG..., run in the
  # client with its body in /out/OUT; none when there was no answer.
  status() {
    local out=$1
    shift
    # shellcheck disable=SC2016 # $0 and $@ are the inner shell's.
    in_docker exec "$client" sh -c 'wget -S -T 10 -O "/out/$0" "$@" 2>&1 | sed -n "s#^  HTTP/1\.[01] \([0-9]*\).*#\1#p" | head -n 1' "$out" "$@"
  }
  body() { in_docker exec "$client" cat "/out/$1"; }
  local i ready=""
  for ((i = 0; i < 60; i++)); do
    if [ "$(status ready-store "http://127.0.0.1:$listen/health")" = 200 ] && [ "$(status ready-vmauth http://127.0.0.1:8426/health)" = 200 ]; then
      ready=1
      break
    fi
    sleep 0.5
  done
  [ -n "$ready" ] || { in_docker logs "$store" 2>&1 | tail -n 20; in_docker logs "$vmauth" 2>&1 | tail -n 20; echo "the store or vmauth did not answer its health check"; return 1; }

  # The store so started refuses a request without its credential, so what it serves below came
  # through vmauth with the store's credential.
  [ "$(status store-bare "http://127.0.0.1:$listen/select/logsql/query?query=*&limit=1")" = 401 ]

  local auth_vector auth_grafana auth_route auth_operator auth_store marker now got
  auth_vector="Authorization: $(basic vector "${password[vector]}")"
  auth_grafana="Authorization: $(basic grafana "${password[grafana]}")"
  # The route's value is the Secret's key credential, which Envoy Gateway puts in Authorization.
  auth_route="Authorization: $(basic logs-route "${password[$route_user]}")"
  auth_operator="Authorization: $(basic operator "${password[operator]}")"
  auth_store="Authorization: $(basic victoria-logs "${password[store]}")"
  local -A header=([vector]="$auth_vector" [grafana]="$auth_grafana" [logs-route]="$auth_route" [operator]="$auth_operator")

  # No credential, and a wrong one.
  [ "$(status no-credential 'http://127.0.0.1:8427/select/logsql/query?query=*')" = 401 ]
  [ "$(status wrong-password --header "Authorization: $(basic vector "$(hex)")" --post-data x http://127.0.0.1:8427/insert/elasticsearch/_bulk)" = 401 ]

  # The collector inserts a line as its sink does, naming a tenant of its own; vmauth puts it in the
  # default tenant, where the operator finds it.
  # One word of letters and digits, which LogsQL reads as a word to find.
  marker="logstoreaccess$(hex)"
  now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  printf '%s\n%s\n' '{"index":{"_index":"vector"}}' \
    "$(jq -cn --arg m "$marker" --arg t "$now" '{message: $m, timestamp: $t, "kubernetes.pod_namespace": "monitoring", "kubernetes.pod_name": "log-store-access", "kubernetes.container_name": "test", node: "node-1"}')" \
    >"$work/client/bulk.ndjson"
  chmod 0644 "$work/client/bulk.ndjson"
  [ "$(status insert --header "$auth_vector" --header 'AccountID: 5' --header 'ProjectID: 7' --header 'Content-Type: application/x-ndjson' \
    --post-file /client/bulk.ndjson "http://127.0.0.1:8427/insert/elasticsearch/_bulk?$(cat "$BATS_TEST_DIRNAME/fixtures/network-audit/bulk.args")")" = 200 ]
  [ "$(status flush --header "$auth_store" --post-data '' "http://127.0.0.1:$listen/internal/force_flush")" = 200 ]
  [ "$(status found --header "$auth_operator" "http://127.0.0.1:8427/select/logsql/query?query=$marker&limit=10")" = 200 ]
  got="$(body found)"
  echo "the operator's query: $got"
  [[ $got == *"\"_msg\":\"$marker\""* ]]
  # The tenant the collector named holds nothing.
  [ "$(status tenant --header "$auth_store" --header 'AccountID: 5' --header 'ProjectID: 7' "http://127.0.0.1:$listen/select/logsql/query?query=$marker&limit=10")" = 200 ]
  [ -z "$(body tenant)" ]

  # Refused, each counted by vmauth as a missing route: the collector's read, every reader's
  # insert, and every user's request for the root, deletion, storage administration and the
  # store's and vmauth's own endpoints, also by dot segments and a doubled slash.
  local refused=0 path code
  [ "$(status vector-read --header "$auth_vector" 'http://127.0.0.1:8427/select/logsql/query?query=*')" = 400 ]
  refused=$((refused + 1))
  for name in $READERS; do
    code="$(status "$name-insert" --header "${header[$name]}" --post-data x http://127.0.0.1:8427/insert/elasticsearch/_bulk)"
    [ "$code" = 400 ] || { echo "$name's insert: $code"; return 1; }
    refused=$((refused + 1))
  done
  for name in $USERS; do
    for path in /delete/run_task /internal/force_merge /internal/force_flush /internal/log_new_streams /internal/partition/list \
      /internal/insert /internal/select/query /metrics /flags /debug/pprof/cmdline /-/reload /health / \
      /select/logsql/../../internal/force_merge //internal/force_merge; do
      code="$(status "$name-refused" --header "${header[$name]}" "http://127.0.0.1:8427$path")"
      [ "$code" = 400 ] || { echo "$name on $path: $code"; return 1; }
      refused=$((refused + 1))
    done
  done

  # Served to each reader: the interface, the build information and a query. The tenants' list is
  # forwarded too, and the store refuses it, 403, as it does for any request that names a tenant
  # (app/vlselect/logsql/logsql.go, ProcessTenantIDsRequest, in VictoriaLogs v1.54.0), which every
  # request vmauth forwards does: the refusal is the store's, not vmauth's, which counts no route
  # missing for it.
  for name in $READERS; do
    for path in /select/vmui/ /select/buildinfo '/select/logsql/query?query=*&limit=1'; do
      code="$(status "$name-read" --header "${header[$name]}" "http://127.0.0.1:8427$path")"
      [ "$code" = 200 ] || { echo "$name on $path: $code"; return 1; }
    done
    code="$(status "$name-tenants" --header "${header[$name]}" http://127.0.0.1:8427/select/tenant_ids)"
    [ "$code" = 403 ] || { echo "$name on /select/tenant_ids: $code"; return 1; }
  done
  # Asked here directly, with the store's credential and no tenant, the store lists the tenants, the
  # default one that holds the line inserted above among them: the refusal above is its answer to
  # the tenant vmauth names.
  [ "$(status tenants-bare --header "$auth_store" "http://127.0.0.1:$listen/select/tenant_ids")" = 200 ]
  [[ $(body tenants-bare) == *'"account_id":0'* ]]

  # Its own endpoints, on 8426: health and metrics without a credential, the rest only with a key.
  [ "$(status health http://127.0.0.1:8426/health)" = 200 ]
  [ "$(status metrics http://127.0.0.1:8426/metrics)" = 200 ]
  for path in /flags /debug/pprof/cmdline /-/reload; do
    code="$(status own "http://127.0.0.1:8426$path")"
    [ "$code" = 401 ] || { echo "8426$path without its key: $code"; return 1; }
  done
  [ "$(status flags-keyed "http://127.0.0.1:8426/flags?authKey=${password[flags]}")" = 200 ]
  # What vmauth counted: every refusal above with a credential as a missing route, and the one
  # wrong password as an invalid token.
  body metrics >"$work/metrics"
  echo "vmauth's errors: $(grep '^vmauth_http_request_errors_total' "$work/metrics" | paste -sd' ' -)"
  grep -qx "vmauth_http_request_errors_total{reason=\"missing_route\"} $refused" "$work/metrics"
  grep -qx 'vmauth_http_request_errors_total{reason="invalid_auth_token"} 1' "$work/metrics"
}
