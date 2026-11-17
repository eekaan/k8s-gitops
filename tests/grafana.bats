#!/usr/bin/env bats
# Proves features/grafana.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq, jq, git and just on PATH (the versions pinned for the
# repository). Each chart is pulled once per run from its public registry, and Grafana's
# defaults.ini once from its public repository at the release tag the Grafana pins; building and
# rendering are offline. just grafana runs from a copy of the scripts against a recording kubectl,
# which reaches no cluster.

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
  # Nor does git read the user's or the system's configuration, credential helpers included.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
  # flux build rewrites the kustomization.yaml of what it builds and puts it back afterwards, so it
  # builds a copy of the applications, never this checkout. The cluster directories stay behind.
  export TREE="$BATS_FILE_TMPDIR/tree"
  mkdir -p "$TREE/kubernetes"
  cp -R "$BATS_TEST_DIRNAME/../kubernetes/apps" "$BATS_TEST_DIRNAME/../kubernetes/components" "$TREE/kubernetes/"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLUSTER="$REPO/kubernetes/clusters/lab-sto2"
  KUBE="$(yq -e '.kubernetes' "$REPO/versions.yaml")"
  NAMESPACE=monitoring
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# overlay: what the cluster's overlay applies, built as Flux builds it. Sets OVERLAY.
overlay() {
  OVERLAY="$(kustomize build --load-restrictor LoadRestrictionsNone "$REPO/kubernetes/apps/overlays/lab-sto2")"
}

# app_dir APP: sets APP_DIR to the directory of the application APP, in whichever namespace
# directory it is, relative to the repository.
app_dir() {
  local -a dirs=("$TREE"/kubernetes/apps/base/*/"$1")
  [ -f "${dirs[0]}/ks.yaml" ] || { echo "$1: no application directory with a ks.yaml"; return 1; }
  APP_DIR="${dirs[0]#"$TREE"/}"
}

# depends APP: the names APP's Kustomization lists in dependsOn, one per line.
depends() {
  app_dir "$1"
  yq '.spec.dependsOn // [] | .[].name' "$REPO/$APP_DIR/ks.yaml"
}

# built APP: the application APP as Flux applies it: its app/ built with its ks.yaml, substituting
# strictly the variables of the cluster's example key lists. Writes $BATS_TEST_TMPDIR/APP-built.yaml
# and sets BUILT and APP_DIR.
built() {
  local app=$1 vars="$BATS_TEST_TMPDIR/example-vars.yaml" ks="$BATS_TEST_TMPDIR/$1-ks.yaml"
  app_dir "$app"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$vars"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = $vars' "$vars" "$TREE/$APP_DIR/ks.yaml" >"$ks"
  BUILT="$BATS_TEST_TMPDIR/$app-built.yaml"
  # Built from the tree's parent, with paths from there, as scripts/kubernetes-check builds.
  (cd "$TREE" && flux build kustomization "$app" --path "./$APP_DIR/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute) >"$BUILT"
}

# render APP [VALUES...]: renders the chart that APP's HelmRelease installs, built as built() builds
# it, from the URL and tag of its OCIRepository, with the values helm-controller gives the chart:
# those of the ConfigMap the HelmRelease reads, then the HelmRelease's own over them, then each
# file VALUES over those. The chart's resource definitions are included, and the monitoring and
# Grafana operator APIs count as present, by group and version and by kind, as charts test for
# either and both exist before these applications start. Writes $BATS_TEST_TMPDIR/APP.yaml and sets
# RENDERED, CHART, RELEASE, VALUES and INLINE, besides what built() sets.
render() {
  local app=$1 url tag name namespace pulled file
  local -a extra=()
  shift
  for file in "$@"; do extra+=(--values "$file"); done
  built "$app"
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$BUILT")"
  RELEASE="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  VALUES="$BATS_TEST_TMPDIR/$app-values.yaml"
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\") | .data[\"values.yaml\"]" "$BUILT" >"$VALUES"
  [ -s "$VALUES" ] || { echo "$app: no values in the ConfigMap $name its HelmRelease reads"; return 1; }
  INLINE="$BATS_TEST_TMPDIR/$app-inline.yaml"
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$BUILT" >"$INLINE"
  pulled="$BATS_FILE_TMPDIR/charts/${url##*/}/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  RENDERED="$BATS_TEST_TMPDIR/$app.yaml"
  helm template "$RELEASE" "$CHART" --namespace "$namespace" --kube-version "$KUBE" --include-crds \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1alpha1 \
    --api-versions monitoring.coreos.com/v1/ServiceMonitor --api-versions monitoring.coreos.com/v1/PodMonitor \
    --api-versions grafana.integreatly.org/v1beta1 --api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
    --api-versions grafana.integreatly.org/v1beta1/GrafanaDatasource \
    --values "$VALUES" --values "$INLINE" "${extra[@]}" >"$RENDERED"
}

# defined_keys APP: fails, naming them, on keys of APP's values file or of its HelmRelease's own
# values that the pinned chart's values do not define. Keys of maps only: list items are the
# chart's input, not keys. A map the chart leaves empty, such as an annotations map, takes keys of
# the user's choosing.
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

# grafana_labels: the labels of the one Grafana in $BUILT, as a JSON object on one line.
grafana_labels() {
  yq -N -o json -I0 'select(.kind == "Grafana") | .metadata.labels // {}' "$BUILT"
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

# dashboards FILE: one line per dashboard in the ConfigMaps of FILE, its key and the SHA-256 of its
# JSON, sorted.
dashboards() {
  yq -N -o json -I0 'select(.kind == "ConfigMap") | .data // {} | to_entries | .[] | select(.key | test("\.json$"))' "$1" |
    while IFS= read -r entry; do
      printf '%s %s\n' "$(jq -r .key <<<"$entry")" "$(jq -r .value <<<"$entry" | sha256sum | cut -d' ' -f1)"
    done | sort
}

# grafana_defaults VERSION: Grafana's own conf/defaults.ini at the release tag vVERSION, from its
# public repository, fetched once per run with only the objects that file needs. Sets DEFAULTS.
grafana_defaults() {
  local src="$BATS_FILE_TMPDIR/grafana-source/$1"
  DEFAULTS="$BATS_FILE_TMPDIR/grafana-defaults-$1.ini"
  if [ ! -s "$DEFAULTS" ]; then
    rm -rf "$src"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v$1" --filter=tree:0 --no-checkout \
      https://github.com/grafana/grafana.git "$src"
    git -C "$src" show HEAD:conf/defaults.ini >"$DEFAULTS"
  fi
}

# ini_value FILE SECTION KEY: the value FILE gives KEY in [SECTION]; nothing when it gives none.
ini_value() {
  awk -v section="[$2]" -v key="$3" '
    /^\[/ { inside = ($0 == section); next }
    inside && $1 == key && $2 == "=" { sub(/^[^=]*=[ \t]*/, ""); print; exit }' "$1"
}

# recipe_copy: a copy of the repository's scripts, with a kubeconfig for the cluster lab-sto2, for
# just grafana to run in through the repository's justfile, against recording fakes: a mise with
# nothing installed, which keeps the justfile from putting real tools in front of the fakes, and a
# kubectl that records its arguments and the kubeconfig it was given, then acts as the file
# $STATE/mode says: forward reports a forward and runs until SIGTERM ends it, as kubectl does;
# silent runs without reporting one; fail stops at once with an error naming an address; drop
# reports a forward and stops a moment later. Sets COPY, BIN, RECORD, STATE, KUBECONFIG_FILE, JUST
# and ENVIRONMENT, the only variables the recipe gets.
recipe_copy() {
  COPY="$BATS_TEST_TMPDIR/copy" BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record" STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$COPY/talos/lab-sto2/clusterconfig" "$BIN" "$RECORD" "$STATE"
  cp -R "$REPO/scripts" "$COPY/scripts"
  KUBECONFIG_FILE="$COPY/talos/lab-sto2/clusterconfig/kubeconfig"
  echo 'not a real kubeconfig' >"$KUBECONFIG_FILE"
  echo forward >"$STATE/mode"
  JUST=$(command -v just)
  only
  printf '#!/usr/bin/env bash\n' >"$BIN/mise"
  { printf '#!/usr/bin/env bash\nRECORD=%q STATE=%q\n' "$RECORD" "$STATE"; cat <<'EOF'; } >"$BIN/kubectl"
printf '%s\n' "$*" >>"$RECORD/argv"
printf '%s\n' "${KUBECONFIG-unset}" >>"$RECORD/kubeconfig"
env | cut -d= -f1 >>"$RECORD/names"
echo "$$ $PPID" >"$STATE/pids"
last=${!#}
case $(cat "$STATE/mode") in
  fail)
    echo 'error: dial tcp 192.0.2.10:6443: connect: connection refused' >&2
    exit 1
    ;;
  forward | drop) echo "Forwarding from 127.0.0.1:${last%%:*} -> ${last##*:}" ;;
esac
trap 'echo SIGTERM >>"$RECORD/ended"; exit 0' TERM
if [[ $(cat "$STATE/mode") == drop ]]; then
  sleep 1
  echo 'error: lost connection to pod' >&2
  exit 1
fi
while :; do sleep 0.1; done
EOF
  chmod +x "$BIN/mise" "$BIN/kubectl"
}

# with ENTRY...: adds the NAME=VALUE ENTRY... to the environment just grafana gets.
with() {
  ENVIRONMENT+=("$@")
}

# only ENTRY...: the environment just grafana gets is TMPDIR and the NAME=VALUE ENTRY... alone.
only() {
  ENVIRONMENT=(TMPDIR="$BATS_TEST_TMPDIR" "$@")
}

# grafana_recipe: runs just grafana in the copy with only ENVIRONMENT set, failing after a minute
# rather than hanging.
grafana_recipe() {
  run timeout 60 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$REPO/justfile" --working-directory "$COPY" grafana
}

# grafana_start: starts just grafana as grafana_recipe runs it, in the background, with its output
# in $BATS_TEST_TMPDIR/out. Sets OUT and JUST_PID.
grafana_start() {
  OUT="$BATS_TEST_TMPDIR/out"
  env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$REPO/justfile" --working-directory "$COPY" grafana >"$OUT" 2>&1 3>&- &
  JUST_PID=$!
}

# printed TEXT: waits up to 20 seconds for TEXT in OUT.
printed() {
  local tick
  for ((tick = 0; tick < 200; tick++)); do
    if grep -qF -- "$1" "$OUT"; then return 0; fi
    sleep 0.1
  done
  echo "no '$1' after 20 seconds in:"
  cat "$OUT"
  return 1
}

# finished: waits up to 20 seconds for just, started by grafana_start, to end, and sets STATUS to
# its exit status.
finished() {
  local tick
  for ((tick = 0; tick < 200; tick++)); do
    if ! kill -0 "$JUST_PID" 2>/dev/null; then
      STATUS=0
      wait "$JUST_PID" || STATUS=$?
      return 0
    fi
    sleep 0.1
  done
  echo "just grafana still runs after 20 seconds"
  return 1
}

# kubectl_gone: fails while the last kubectl the fake recorded still runs.
kubectl_gone() {
  local kubectl_pid
  read -r kubectl_pid _ <"$STATE/pids"
  if kill -0 "$kubectl_pid" 2>/dev/null; then
    echo "kubectl $kubectl_pid still runs"
    return 1
  fi
}

# seconds DURATION: DURATION, such as 30s, 1m or 2h, in seconds; fails on any other form.
seconds() {
  [[ $1 =~ ^([0-9]+)(s|m|h)$ ]] || { echo "not a duration: '$1'" >&2; return 1; }
  case ${BASH_REMATCH[2]} in
    s) echo "${BASH_REMATCH[1]}" ;;
    m) echo $((BASH_REMATCH[1] * 60)) ;;
    h) echo $((BASH_REMATCH[1] * 3600)) ;;
  esac
}

@test "The Grafana operator installs and upgrades its resource definitions" {
  local enabled namespace wait deployments crds templated
  # The cluster runs the application and its namespace directory: its overlay applies both.
  overlay
  enabled="$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "grafana-operator") | .spec.path' <<<"$OVERLAY")"
  namespace="$(yq -N "select(.kind == \"Namespace\" and .metadata.name == \"$NAMESPACE\") | .metadata.name" <<<"$OVERLAY")"
  echo "grafana-operator in the overlay: ${enabled:-none}; namespace ${namespace:-none}"
  [ "$enabled" = "./apps/base/$NAMESPACE/grafana-operator/app" ]
  [ "$namespace" = "$NAMESPACE" ]
  # Ready only once the release is installed, so the grafana application finds the definitions.
  wait="$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "grafana-operator") | .spec.wait' <<<"$OVERLAY")"
  echo "grafana-operator waits for its release: $wait"
  [ "$wait" = true ]

  render grafana-operator
  deployments="$(yq -N 'select(.kind == "Deployment") | .metadata.namespace + "/" + .metadata.name + " "
    + .spec.template.spec.containers[0].image' "$RENDERED")"
  echo "deployments: $deployments"
  [ "$(grep -c . <<<"$deployments")" -eq 1 ]
  [[ $deployments == "$NAMESPACE/"*" ghcr.io/grafana/grafana-operator:"* ]]
  # Deleting a definition deletes every object of its kind, so Helm keeps each one when the release
  # is uninstalled, as it is when the application leaves the tree.
  crds="$(yq -N 'select(.kind == "CustomResourceDefinition") | .spec.group + " " + .metadata.name + " "
    + (.metadata.annotations["helm.sh/resource-policy"] // "none")' "$RENDERED" | sort)"
  echo "$crds"
  [ -n "$crds" ]
  [ "$(grep -vc '^grafana\.integreatly\.org .* keep$' <<<"$crds")" -eq 0 ]
  for kind in grafanas grafanadashboards grafanadatasources; do
    grep -q " $kind\.grafana\.integreatly\.org keep$" <<<"$crds" || { echo "no definition of $kind"; return 1; }
  done
  # They are templates of the release, not of a chart's crds/ directory, which Helm installs once
  # and never upgrades: they render without those directories too.
  templated="$(helm template "$RELEASE" "$CHART" --namespace "$NAMESPACE" --kube-version "$KUBE" \
    --values "$VALUES" --values "$INLINE" | yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' | sort)"
  echo "definitions among the release's templates: $(grep -c . <<<"$templated")"
  [ "$templated" = "$(cut -d' ' -f2 <<<"$crds")" ]
}

@test "The Grafana operator has its monitor on" {
  local targets
  render grafana-operator
  targets="$(monitor_targets)"
  echo "grafana-operator: ${targets:-no monitor}"
  # Exactly one monitor, so nothing is scraped twice, and it scrapes a Service the chart makes.
  [ "$(grep -c . <<<"$targets")" -eq 1 ]
  [[ $targets == ServiceMonitor/* ]]
  [[ $targets != *' -> none' ]]
  # The monitor's kind exists only once the definitions are installed.
  echo "grafana-operator depends on: $(depends grafana-operator | xargs)"
  depends grafana-operator | grep -qx prometheus-operator-crds
}

@test "The Grafana operator acts only in the namespace monitoring" {
  local account watch bindings roles
  render grafana-operator
  account="$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.serviceAccountName' "$RENDERED")"
  watch="$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[]
    | select(.name == "WATCH_NAMESPACE") | .value' "$RENDERED")"
  echo "service account: ${account:-none}; namespaces watched: ${watch:-all}"
  [ -n "$account" ]
  [ "$watch" = "$NAMESPACE" ]
  # A ClusterRoleBinding, or a RoleBinding elsewhere, would let the operator read and change
  # Secrets, ConfigMaps and the rest outside its own namespace.
  bindings="$(ACCOUNT=$account yq -N 'select((.kind == "RoleBinding" or .kind == "ClusterRoleBinding")
      and ([.subjects[] | select(.kind == "ServiceAccount" and .name == strenv(ACCOUNT))] | length) > 0)
    | .kind + " " + (.metadata.namespace // "cluster-wide") + " " + .roleRef.kind + "/" + .roleRef.name' "$RENDERED" | sort)"
  roles="$(yq -N 'select(.kind == "ClusterRole") | .metadata.name' "$RENDERED")"
  echo "bindings: $bindings"
  echo "ClusterRoles: ${roles:-none}"
  [ -n "$bindings" ]
  [ "$(grep -vc "^RoleBinding $NAMESPACE Role/" <<<"$bindings")" -eq 0 ]
  [ -z "$roles" ]
}

@test "One Grafana runs from the operator at a pinned version" {
  local enabled grafanas version pin replicas budgets wait
  overlay
  enabled="$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "grafana") | .spec.path' <<<"$OVERLAY")"
  echo "grafana in the overlay: ${enabled:-none}"
  [ "$enabled" = "./apps/base/$NAMESPACE/grafana/app" ]

  built grafana
  grafanas="$(yq -N 'select(.kind == "Grafana") | .apiVersion + " " + .metadata.namespace + "/" + .metadata.name' "$BUILT")"
  echo "Grafana objects: ${grafanas:-none}"
  [ "$(grep -c . <<<"$grafanas")" -eq 1 ]
  [[ $grafanas == "grafana.integreatly.org/"*" $NAMESPACE/"* ]]
  # The operator writes its own default into a Grafana that names no version, where it stays; a
  # version set here moves only with a change to this file.
  version="$(yq -N 'select(.kind == "Grafana") | .spec.version // ""' "$BUILT")"
  pin="$(grep -B1 -E "^[[:blank:]]+version: [\"']?${version//./\\.}[\"']?\$" "$REPO/$APP_DIR/app/grafana.yaml" | head -1 | sed 's/^[[:blank:]]*//')"
  echo "version: ${version:-none}; the line above it: ${pin:-none}"
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  # Renovate's regex manager reads the version on the line under such a comment.
  [ "$pin" = "# renovate: datasource=docker depName=docker.io/grafana/grafana" ]
  # Each replica would keep a database of its own, and the operator writes to whichever one its
  # Service picks; with one replica, a disruption budget would only block every drain.
  replicas="$(yq -N 'select(.kind == "Grafana") | .spec.deployment.spec.replicas // "unset"' "$BUILT")"
  budgets="$(yq -N 'select(.kind == "PodDisruptionBudget") | .metadata.name' "$BUILT")"
  echo "replicas: $replicas; disruption budgets: ${budgets:-none}"
  [ "$replicas" = 1 ]
  [ -z "$budgets" ]
  # The operator's definitions exist once grafana-operator is Ready, which waits for its release.
  wait="$(yq '.spec.wait' "$REPO/kubernetes/apps/base/$NAMESPACE/grafana-operator/ks.yaml")"
  echo "grafana depends on: $(depends grafana | xargs); grafana-operator waits: $wait"
  depends grafana | grep -qx grafana-operator
  [ "$wait" = true ]
}

@test "Grafana keeps nothing that Git does not hold" {
  local claims volumes resync name period
  built grafana
  # The operator gives Grafana's data directory a claim only when the Grafana asks for one, and an
  # emptyDir otherwise.
  claims="$(yq -N 'select(.kind == "Grafana") | .spec | (has("persistentVolumeClaim") | tostring) + " "
    + ([.deployment.spec.template.spec.volumes // [] | .[] | select(has("persistentVolumeClaim") or has("ephemeral"))] | length | tostring)' "$BUILT")"
  echo "the Grafana asks for a claim, and claimed volumes in its pod: $claims"
  [ "$claims" = "false 0" ]
  render grafana
  volumes="$(yq -N 'select(.kind == "PersistentVolumeClaim" or (.spec.volumeClaimTemplates // [] | length) > 0)
    | .kind + "/" + .metadata.name' "$BUILT" "$RENDERED")"
  echo "objects that claim a volume: ${volumes:-none}"
  [ -z "$volumes" ]
  # A restarted Grafana starts empty; each object is applied to it again at its resync.
  resync="$(yq -N 'select(.kind == "GrafanaDatasource" or .kind == "GrafanaDashboard")
    | .kind + "/" + .metadata.name + " " + (.spec.resyncPeriod // "unset")' "$BUILT" "$RENDERED")"
  echo "$resync"
  grep -q '^GrafanaDatasource/' <<<"$resync"
  grep -q '^GrafanaDashboard/' <<<"$resync"
  while read -r name period; do
    (($(seconds "$period") <= 60)) || { echo "$name resyncs every $period"; return 1; }
  done <<<"$resync"
}

@test "Grafana reads the cluster's Prometheus" {
  local labels datasources url service namespace port found
  built grafana
  labels="$(grafana_labels)"
  datasources="$(yq -N -o json -I0 'select(.kind == "GrafanaDatasource" and .spec.datasource.type == "prometheus")' "$BUILT")"
  echo "Grafana labels: $labels"
  echo "datasources: ${datasources:-none}"
  [ "$(grep -c . <<<"$datasources")" -eq 1 ]
  jq -e --argjson labels "$labels" '(.spec.instanceSelector.matchLabels // {}) as $selector
    | ($selector | length > 0) and ($selector | to_entries | all($labels[.key] == .value))' <<<"$datasources"
  [ "$(jq -r '.spec.datasource.type' <<<"$datasources")" = prometheus ]
  [ "$(jq -r '.spec.datasource.isDefault' <<<"$datasources")" = true ]
  url="$(jq -r '.spec.datasource.url // ""' <<<"$datasources")"
  [[ $url =~ ^http://([a-z0-9-]+)\.([a-z0-9-]+)\.svc(\.cluster\.local)?:([0-9]+)/?$ ]]
  service=${BASH_REMATCH[1]} namespace=${BASH_REMATCH[2]} port=${BASH_REMATCH[4]}
  # The Service is the monitoring chart's, in front of its Prometheus.
  render kube-prometheus-stack
  found="$(yq -N "select(.kind == \"Service\" and .metadata.name == \"$service\" and .metadata.namespace == \"$namespace\")
    | (.spec.selector[\"app.kubernetes.io/name\"] // \"none\") + \" \" + ([.spec.ports[].port | tostring] | join(\",\"))" "$RENDERED")"
  echo "datasource URL: $url; that Service in the monitoring chart: ${found:-none}"
  [[ $found =~ ^prometheus\ (.*,)?$port(,.*)?$ ]]
}

@test "Grafana shows the monitoring chart's dashboards for what the cluster runs" {
  local theirs ours pins labels kinds unloaded forced release
  built kube-prometheus-stack
  theirs="$(yq -N 'select(.kind == "OCIRepository") | .spec.url + ":" + .spec.ref.tag' "$BUILT")"
  render grafana
  release="$RENDERED"
  ours="$(yq -N 'select(.kind == "OCIRepository") | .spec.url + ":" + .spec.ref.tag' "$BUILT")"
  echo "dashboards chart: ${ours:-none}; monitoring chart: ${theirs:-none}"
  [ -n "$ours" ]
  [ "$ours" = "$theirs" ]
  # Renovate knows both pins as one package, so one pull request moves them together.
  pins="$(grep -h '# renovate:' "$REPO/$APP_DIR/app/ocirepository.yaml" \
    "$REPO/kubernetes/apps/base/$NAMESPACE/kube-prometheus-stack/app/ocirepository.yaml" | sed 's/^[[:blank:]]*//' | sort -u)"
  echo "Renovate comments: $pins"
  [ "$(grep -c . <<<"$pins")" -eq 1 ]

  labels="$(grafana_labels)"
  kinds="$(yq -N 'select(. != null) | .kind' "$release" | sort -u | paste -sd' ' -)"
  echo "the dashboards release renders: $kinds"
  [ "$kinds" = "ConfigMap GrafanaDashboard" ]
  # One GrafanaDashboard per ConfigMap, each loading a key its ConfigMap has into the Grafana.
  unloaded="$(yq -N -o json -I0 'select(. != null)' "$release" | jq -rs --argjson labels "$labels" '
    [.[] | select(.kind == "ConfigMap")] as $maps
    | [.[] | select(.kind == "GrafanaDashboard")] as $boards
    | ($maps[] | .metadata.name as $name
        | select([$boards[] | select(.spec.configMapRef.name == $name)] | length != 1)
        | "ConfigMap/\($name) is not loaded by exactly one GrafanaDashboard"),
      ($boards[] | select(((.spec.instanceSelector.matchLabels // {}) as $selector
          | ($selector | length > 0) and ($selector | to_entries | all($labels[.key] == .value))) | not)
        | "GrafanaDashboard/\(.metadata.name) does not select the Grafana"),
      ($boards[] | .spec.configMapRef as $ref
        | select([$maps[] | select(.metadata.name == $ref.name and (.data // {} | has($ref.key)))] | length != 1)
        | "GrafanaDashboard/\(.metadata.name) names no key of a ConfigMap of the release")')"
  echo "${unloaded:-every ConfigMap is loaded into the Grafana}"
  [ -z "$unloaded" ]

  # The monitoring chart's own dashboards for the monitoring application's values, forced on as the
  # application runs no Grafana. Talos nodes run Linux, so the nodes dashboards of AIX and Darwin
  # are left out.
  dashboards "$release" >"$BATS_TEST_TMPDIR/ours"
  forced="$BATS_TEST_TMPDIR/forced.yaml"
  printf 'grafana:\n  forceDeployDashboards: true\n' >"$forced"
  render kube-prometheus-stack "$forced"
  dashboards "$RENDERED" | grep -vE '^nodes-(aix|darwin)\.json ' >"$BATS_TEST_TMPDIR/theirs"
  echo "dashboards: $(cut -d' ' -f1 "$BATS_TEST_TMPDIR/ours" | xargs)"
  grep -q '^k8s-resources-cluster\.json ' "$BATS_TEST_TMPDIR/ours"
  diff "$BATS_TEST_TMPDIR/theirs" "$BATS_TEST_TMPDIR/ours"
}

@test "No dashboard is fetched from the network at run time" {
  local loaded fetched
  built grafana
  render grafana
  loaded="$(yq -N 'select(.kind == "GrafanaDashboard") | .metadata.name' "$BUILT" "$RENDERED")"
  echo "GrafanaDashboards: $(grep -c . <<<"$loaded")"
  [ -n "$loaded" ]
  # yq binds or looser than a pipe: .spec | has(a) or has(b) would ask the whole object for b.
  fetched="$(yq -N 'select(.kind == "GrafanaDashboard" or .kind == "GrafanaDatasource")
    | select((.spec | (has("url") or has("urlAuthorization") or has("grafanaCom") or has("oci") or has("jsonnet")
        or has("jsonnetLib"))) or (.spec.plugins // [] | length) > 0)
    # The one exception, documented in docs/kubernetes.md: the datasource for VictoriaLogs asks for
    # its own plugin, once; tests/logs.bats checks that it is pinned to an exact version.
    | select((.kind == "GrafanaDatasource" and .metadata.name == "victoria-logs"
        and .spec.datasource.type == "victoriametrics-logs-datasource"
        and (.spec.plugins // [] | length) == 1 and .spec.plugins[0].name == "victoriametrics-logs-datasource"
        and (.spec | (has("url") or has("urlAuthorization") or has("grafanaCom") or has("oci") or has("jsonnet")
          or has("jsonnetLib")) | not)) | not)
    | .kind + "/" + .metadata.name' "$BUILT" "$RENDERED")"
  echo "fetched at run time: ${fetched:-none}"
  [ -z "$fetched" ]
}

@test "Grafana's admin credential is generated in the cluster" {
  local secrets grafana
  built grafana
  render grafana
  secrets="$(yq -N 'select(.kind == "Secret" or .kind == "ExternalSecret" or .kind == "SealedSecret") | .kind + "/" + .metadata.name' "$BUILT" "$RENDERED")"
  echo "secrets: ${secrets:-none}"
  [ -z "$secrets" ]
  grafana="$(yq -N -o json -I0 'select(.kind == "Grafana")' "$BUILT")"
  [ -n "$grafana" ]
  # The operator writes a random password into the Secret <name>-admin-credentials unless the
  # Grafana turns that off or names the user or password itself.
  echo "operator's admin Secret disabled: $(jq -r '.spec.disableDefaultAdminSecret // false' <<<"$grafana")"
  [ "$(jq -r '.spec.disableDefaultAdminSecret // false' <<<"$grafana")" = false ]
  [ "$(jq -r '.spec.config.security // {} | has("admin_user") or has("admin_password")' <<<"$grafana")" = false ]
  [ "$(jq -r '[.spec.deployment.spec.template.spec.containers // [] | .[] | (.env // [] | .[].name | select(startswith("GF_SECURITY_ADMIN_"))),
    (.envFrom // [] | .[] | "envFrom")] | length' <<<"$grafana")" -eq 0 ]
}

@test "Grafana is reachable only from inside the cluster, with anonymous access off" {
  local routes grafana
  built grafana
  render grafana
  routes="$(yq -N 'select(.kind == "Ingress" or .kind == "Route" or .kind == "Gateway" or .kind == "HTTPRoute"
      or .kind == "GRPCRoute" or .kind == "TLSRoute" or .kind == "TCPRoute" or .kind == "UDPRoute"
      or (.kind == "Service" and (.spec.type // "ClusterIP") != "ClusterIP"))
    | .kind + "/" + .metadata.name' "$BUILT" "$RENDERED")"
  echo "routes from outside: ${routes:-none}"
  [ -z "$routes" ]
  grafana="$(yq -N -o json -I0 'select(.kind == "Grafana")' "$BUILT")"
  [ -n "$grafana" ]
  echo "the Grafana's ingress, route, HTTP route and Service type: $(jq -c '[.spec.ingress, .spec.route, .spec.httpRoute, (.spec.service.spec.type // "ClusterIP")]' <<<"$grafana")"
  [ "$(jq -c '[.spec.ingress, .spec.route, .spec.httpRoute, (.spec.service.spec.type // "ClusterIP")]' <<<"$grafana")" = '[null,null,null,"ClusterIP"]' ]
  # Grafana's own default is off too; set here, it is part of what Git holds.
  echo "anonymous access: $(jq -r '.spec.config["auth.anonymous"].enabled // "unset"' <<<"$grafana"); login form disabled: $(jq -r '.spec.config.auth.disable_login_form // "unset"' <<<"$grafana")"
  [ "$(jq -r '.spec.config["auth.anonymous"].enabled // "unset"' <<<"$grafana")" = false ]
  [ "$(jq -r '.spec.config.auth.disable_login_form // "false"' <<<"$grafana")" = false ]
}

@test "Grafana makes no call to the internet on its own" {
  local grafana version key wanted section name ours default failed=""
  built grafana
  grafana="$(yq -N -o json -I0 'select(.kind == "Grafana")' "$BUILT")"
  version="$(jq -r '.spec.version // ""' <<<"$grafana")"
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  grafana_defaults "$version"
  # Each setting of grafana.ini that reaches the internet unless it is set to the value given here.
  # A key Grafana does not know is ignored without a word, so each must be one the pinned release's
  # defaults define, with the value that calls out.
  while read -r key wanted; do
    [[ -n $key && $key != \#* ]] || continue
    section=${key%.*} name=${key##*.}
    ours="$(SECTION="$section" NAME="$name" jq -r '.spec.config[env.SECTION][env.NAME] // "unset"' <<<"$grafana")"
    default="$(ini_value "$DEFAULTS" "$section" "$name")"
    echo "$key: $ours here; Grafana $version's default ${default:-none}"
    if [[ -z $default || $default == "$wanted" ]]; then failed+=" $key(default)"; fi
    if [[ $ours != "$wanted" ]]; then failed+=" $key"; fi
  done <<'EOF'
# Usage counters sent to stats.grafana.org every day.
analytics.reporting_enabled false
# A request to grafana.com for the newest Grafana release.
analytics.check_for_updates false
# Requests to grafana.com for the newest plugin releases.
analytics.check_for_plugin_updates false
# The news feed, read from grafana.com.
news.news_feed_enabled false
# The plugin catalogue, which installs and updates plugins from grafana.com.
plugins.plugin_admin_enabled false
# The plugins Grafana installs from grafana.com at every start, unpinned and updated, into a data
# directory that starts empty each time.
plugins.preinstall_disabled true
# The public key for plugin signatures, fetched from grafana.com.
plugins.public_key_retrieval_disabled true
# Profile pictures, which browsers load from gravatar.com.
security.disable_gravatar true
# Publishing a dashboard snapshot to snapshots.raintank.io.
snapshots.external_enabled false
EOF
  echo "failed:${failed:- none}"
  [ -z "$failed" ]
}

@test "just grafana forwards a local port to Grafana" {
  local script_pid port
  recipe_copy
  for port in default 3456; do
    if [[ $port == default ]]; then port=3000; else with GRAFANA_PORT="$port"; fi
    grafana_start
    printed "http://127.0.0.1:$port"
    cat "$OUT"
    # Only once kubectl reports the forward.
    [ -s "$STATE/pids" ]
    read -r _ script_pid <"$STATE/pids"
    kill -INT "$script_pid" "$JUST_PID"
    finished
  done
  echo "kubectl ran: $(cat "$RECORD/argv")"
  [ "$(cat "$RECORD/argv")" = "$(printf '%s\n' \
    'port-forward --address 127.0.0.1 --namespace monitoring service/grafana-service 3000:3000' \
    'port-forward --address 127.0.0.1 --namespace monitoring service/grafana-service 3456:3000')" ]
  [ "$(sort -u "$RECORD/kubeconfig")" = "$KUBECONFIG_FILE" ]
  grep -qF 'GF_SECURITY_ADMIN_PASSWORD' "$OUT"
  grep -qF 'grafana-admin-credentials' "$OUT"
  if grep -qF 'Forwarding from' "$OUT"; then echo "kubectl's own output was printed"; return 1; fi
}

@test "just grafana ends the forward on every way out" {
  local script_pid
  recipe_copy
  # Ctrl-C: the terminal signals the recipe, while kubectl, run in the background, ignores it.
  grafana_start
  printed "http://127.0.0.1:3000"
  read -r _ script_pid <"$STATE/pids"
  kill -INT "$script_pid" "$JUST_PID"
  finished
  echo "after Ctrl-C: status $STATUS; $(cat "$OUT")"
  [ "$STATUS" -ne 0 ]
  kubectl_gone
  [ "$(cat "$RECORD/ended")" = SIGTERM ]

  # SIGTERM, which just passes on to the recipe.
  rm "$RECORD/ended"
  grafana_start
  printed "http://127.0.0.1:3000"
  kill -TERM "$JUST_PID"
  finished
  echo "after SIGTERM: status $STATUS"
  [ "$STATUS" -ne 0 ]
  kubectl_gone
  [ "$(cat "$RECORD/ended")" = SIGTERM ]

  # kubectl never reports the forward.
  rm "$RECORD/ended"
  echo silent >"$STATE/mode"
  with GRAFANA_WAIT=1
  grafana_recipe
  echo "kubectl silent: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"did not report the forward within 1 seconds"* ]]
  [[ $output != *"http://"* ]]
  kubectl_gone
  [ "$(cat "$RECORD/ended")" = SIGTERM ]

  # kubectl stops before it forwards, with an error that names the API server's address.
  echo fail >"$STATE/mode"
  grafana_recipe
  echo "kubectl failing: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"stopped with status 1 before it forwarded"* ]]
  [[ $output != *192.0.2.10* ]]
  kubectl_gone

  # kubectl stops while it forwards.
  echo drop >"$STATE/mode"
  grafana_recipe
  echo "kubectl dropping: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"http://127.0.0.1:3000"* ]]
  [[ $output == *"stopped with status 1"* ]]
  kubectl_gone
}

@test "just grafana runs kubectl with none of the secrets" {
  recipe_copy
  # Every secret variable the recipes read, as a marker, besides the settings the recipe reads.
  names=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CLUSTER_S3_ACCESS_KEY_ID CLUSTER_S3_SECRET_ACCESS_KEY
    OS_CLOUD OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET TF_STATE_PASSPHRASE
    TF_ENCRYPTION SOPS_AGE_KEY SOPS_AGE_KEY_FILE FLUX_AGE_KEY FLUX_AGE_KEY_FILE OPERATOR_CIDRS)
  for name in "${names[@]}"; do with "$name=marker-$name"; done
  with GRAFANA_PORT=3456
  echo fail >"$STATE/mode"

  grafana_recipe

  [ -s "$RECORD/names" ]
  # What is no secret reaches kubectl, and the kubeconfig it is run with.
  grep -qx KUBECONFIG "$RECORD/names"
  grep -qx GRAFANA_PORT "$RECORD/names"
  for name in "${names[@]}"; do
    echo "$name"
    if grep -qx "$name" "$RECORD/names"; then return 1; fi
  done
}

@test "just grafana needs the cluster's kubeconfig and a port" {
  local port
  recipe_copy
  rm "$KUBECONFIG_FILE"
  with GRAFANA_PORT=65536 GRAFANA_WAIT=soon
  grafana_recipe
  echo "status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/clusterconfig/kubeconfig does not exist; just cluster-kubeconfig fetches it"* ]]
  [[ $output == *"GRAFANA_PORT is not a port number"* ]]
  [[ $output == *"GRAFANA_WAIT is not a whole number of seconds"* ]]
  # With the kubeconfig in place, each port alone is refused.
  echo 'not a real kubeconfig' >"$KUBECONFIG_FILE"
  for port in 0 080 abc 3000x; do
    only GRAFANA_PORT="$port"
    grafana_recipe
    echo "GRAFANA_PORT='$port': status $status; $output"
    [ "$status" -ne 0 ]
    [[ $output == *"GRAFANA_PORT is not a port number"* ]]
  done
  [ ! -e "$RECORD/argv" ]
}

@test "Grafana has its monitor on" {
  local labels monitors
  built grafana
  # The operator gives the Service it makes for the Grafana the Grafana's own labels and those set
  # under its spec.service.
  labels="$(yq -N -o json -I0 'select(.kind == "Grafana") | (.metadata.labels // {}) * (.spec.service.metadata.labels // {})' "$BUILT")"
  monitors="$(yq -N -o json -I0 'select(.kind == "ServiceMonitor" or .kind == "PodMonitor")' "$BUILT")"
  echo "Service labels: ${labels:-none}"
  echo "monitors: ${monitors:-none}"
  [ "$(grep -c . <<<"$monitors")" -eq 1 ]
  [ "$(jq -r .kind <<<"$monitors")" = ServiceMonitor ]
  # In its own namespace, the Grafana's, as it names no other.
  [ "$(jq -r '.spec.namespaceSelector // "none"' <<<"$monitors")" = none ]
  jq -e --argjson labels "$labels" '(.spec.selector.matchLabels // {}) as $selector
    | ($selector | length > 0) and ($selector | to_entries | all($labels[.key] == .value))' <<<"$monitors"
  # The operator names the Service's HTTP port grafana; Grafana serves /metrics there.
  [ "$(jq -r '[.spec.endpoints[].port] | join(" ")' <<<"$monitors")" = grafana ]
  echo "grafana depends on: $(depends grafana | xargs)"
  depends grafana | grep -qx prometheus-operator-crds
}

@test "every values key of grafana-operator is one its pinned chart defines" {
  defined_keys grafana-operator
}

@test "every values key of the Grafana dashboards release is one its pinned chart defines" {
  defined_keys grafana
}
