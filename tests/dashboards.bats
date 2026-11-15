#!/usr/bin/env bats
# Proves features/dashboards.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq, jq and sha256sum on PATH (the versions pinned for the
# repository). Each chart is pulled once per run from its public registry; building and rendering
# are offline, and no dashboard is fetched: every upstream file a dashboard comes from is committed
# in the tree and recorded, so a check never reads one from the network.

# The tests run one at a time even where bats runs a file's tests side by side: a test that starts
# while another pulls a chart finds the chart's directory before the chart is in it.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

# Every application that delivers a dashboard, each a directory of apps/base with a
# grafanadashboard*.yaml in its app/. A new one is added here on purpose, with its place in
# docs/kubernetes.md (Dashboards).
DASHBOARD_APPS="grafana openbao-dashboard victoria-logs"

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

# app_dir APP: sets APP_DIR to the directory of the application APP, in whichever namespace
# directory it is, relative to the repository.
app_dir() {
  local -a dirs=("$TREE"/kubernetes/apps/base/*/"$1")
  [ -f "${dirs[0]}/ks.yaml" ] || { echo "$1: no application directory with a ks.yaml"; return 1; }
  APP_DIR="${dirs[0]#"$TREE"/}"
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

# chart APP: pulls the chart the application APP's OCIRepository names, at its pinned tag, once per
# run. Sets CHART_TAG, the tag, and CHART_APP_VERSION, the appVersion the chart declares, besides
# what built() sets.
chart() {
  local url pulled
  built "$1"
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  CHART_TAG="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
  pulled="$BATS_FILE_TMPDIR/charts/${url##*/}/$CHART_TAG"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$CHART_TAG" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  # The chart's own Chart.yaml, not that of a chart it carries.
  CHART_APP_VERSION="$(tar -xzOf "$CHART" "$(tar -tzf "$CHART" | grep -m1 -E '^[^/]+/Chart\.yaml$')" | yq '.appVersion')"
}

# render APP: the chart that APP's HelmRelease installs, rendered as helm-controller renders it with
# the values of the ConfigMap it reads and its own over them, as grafana.bats renders it. Writes
# $BATS_TEST_TMPDIR/APP.yaml and sets RENDERED, besides what chart() sets.
render() {
  local app=$1 name release namespace values inline
  chart "$app"
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  values="$BATS_TEST_TMPDIR/$app-values.yaml"
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\") | .data[\"values.yaml\"]" "$BUILT" >"$values"
  [ -s "$values" ] || { echo "$app: no values in the ConfigMap $name its HelmRelease reads"; return 1; }
  inline="$BATS_TEST_TMPDIR/$app-inline.yaml"
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$BUILT" >"$inline"
  RENDERED="$BATS_TEST_TMPDIR/$app.yaml"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" --include-crds \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1alpha1 \
    --api-versions monitoring.coreos.com/v1/ServiceMonitor --api-versions monitoring.coreos.com/v1/PodMonitor \
    --api-versions grafana.integreatly.org/v1beta1 --api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
    --api-versions grafana.integreatly.org/v1beta1/GrafanaDatasource \
    --values "$values" --values "$inline" >"$RENDERED"
}

# cluster_render: what the cluster's overlay renders, with every chart expanded, by scripts/render,
# once per run. Sets CLUSTER_RENDER to the cluster's directory in it.
cluster_render() {
  local out="$BATS_FILE_TMPDIR/cluster-render"
  if [ ! -d "$out/lab-sto2" ]; then
    rm -rf "$out"
    "$REPO/scripts/render" "$out" "$REPO" >"$BATS_FILE_TMPDIR/cluster-render.log" 2>&1 ||
      { cat "$BATS_FILE_TMPDIR/cluster-render.log"; return 1; }
  fi
  CLUSTER_RENDER="$out/lab-sto2"
}

# grafana_labels: the labels of the one Grafana in $BUILT, as a JSON object on one line.
grafana_labels() {
  yq -N -o json -I0 'select(.kind == "Grafana") | .metadata.labels // {}' "$BUILT"
}

# dashboard_apps: the applications of the tree that hold a GrafanaDashboard of their own, sorted,
# on one line.
dashboard_apps() {
  local file
  for file in "$TREE"/kubernetes/apps/base/*/*/app/grafanadashboard*.yaml; do
    basename "$(dirname "$(dirname "$file")")"
  done | sort -u | paste -sd' ' -
}

# boards FILE...: one JSON object per line for each GrafanaDashboard in the files: its name, the
# datasources it maps, and its dashboard's JSON as a string, from the ConfigMap it names or from its
# spec.json. A dashboard that loads from anywhere else has null for json.
boards() {
  yq -N -o json -I0 'select(. != null)' "$@" | jq -c -s '. as $all | .[] | select(.kind == "GrafanaDashboard") | . as $board
    | {name: .metadata.name, datasources: (.spec.datasources // []),
       json: (if .spec.json then .spec.json
         elif .spec.configMapRef then ([$all[] | select(.kind == "ConfigMap" and .metadata.name == $board.spec.configMapRef.name)
           | .data[$board.spec.configMapRef.key]] | first)
         else null end)}'
}

# unaccounted_dashboards RENDER...: the names of the GrafanaDashboards in the rendered files that
# neither DASHBOARD_APPS' builds nor the monitoring chart's release deliver, sorted. A dashboard in
# an application that no name of DASHBOARD_APPS reaches is checked by nothing else.
unaccounted_dashboards() {
  local app files="" known="$BATS_TEST_TMPDIR/known-dashboards.txt"
  for app in $DASHBOARD_APPS; do
    built "$app"
    cp "$BUILT" "$BATS_TEST_TMPDIR/known-$app.yaml"
    files+=" $BATS_TEST_TMPDIR/known-$app.yaml"
  done
  # The pull's messages go to the test's output, not into the names the caller captures.
  render grafana >&2
  # shellcheck disable=SC2086 # The names hold no space.
  boards $files "$RENDERED" | jq -r .name | sort -u >"$known"
  yq -N 'select(. != null) | select(.kind == "GrafanaDashboard") | .metadata.name' "$@" | sort -u | comm -23 - "$known"
}

# configmap_value FILE NAME KEY: the value of KEY in the ConfigMap NAME of FILE, as bytes, with
# nothing added.
configmap_value() {
  MAP=$2 KEY=$3 yq -N -o json -I0 'select(.kind == "ConfigMap" and .metadata.name == strenv(MAP)) | .data[strenv(KEY)]' "$1" | jq -j .
}

# overlay_names OVERLAY_KUSTOMIZATION_DIR: the names of the Kustomizations the overlay in the
# directory builds, sorted, on one line.
overlay_names() {
  kustomize build --load-restrictor LoadRestrictionsNone "$1" |
    yq -N 'select(.kind == "Kustomization") | .metadata.name' | sort | paste -sd' ' -
}

# without DIR NAME...: a copy of the kubernetes/ directory of this repository in DIR, whose overlay
# no longer lists the ks.yaml of the applications NAME... Sets WITHOUT to the overlay's directory.
without() {
  local dir=$1 name
  shift
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R "$REPO/kubernetes" "$dir/"
  WITHOUT="$dir/kubernetes/apps/overlays/lab-sto2"
  for name in "$@"; do
    # The line of the application's ks.yaml, in whichever namespace directory it is.
    sed -i -E "\#^[[:blank:]]*-[[:blank:]]+\.\./\.\./base/[^/]+/$name/ks\.yaml#d" "$WITHOUT/kustomization.yaml"
  done
}

# The ceiling of what a ConfigMap holds: the sum of its data and binaryData values, as the API
# server counts, is at most 1 MiB. A GrafanaDashboard that carries its JSON is held to the same.
CONFIGMAP_LIMIT=1048576

# oversized FILE...: names, one per line, each ConfigMap in the files whose data holds more than a
# ConfigMap can, and each GrafanaDashboard whose JSON is more than that; the status is non-zero when
# there is one.
oversized() {
  local found
  found="$(yq -N -o json -I0 'select(. != null)' "$@" | jq -r --argjson limit "$CONFIGMAP_LIMIT" '
    select(.kind == "ConfigMap" or .kind == "GrafanaDashboard")
    | (if .kind == "ConfigMap" then [(.data // {} | .[] | utf8bytelength), (.binaryData // {} | .[] | length)]
       else [(.spec.json // "" | utf8bytelength)] end | add // 0) as $size
    | select($size > $limit) | "\(.kind)/\(.metadata.name) holds \($size) bytes, over the \($limit) a ConfigMap holds"')"
  if [ -n "$found" ]; then
    echo "$found"
    return 1
  fi
}

# metrics: the metric names the PromQL expressions on its input select, one per line. It takes
# string literals, label matchers, ranges and subquery steps, dashboard variables, and the label
# lists of by, without, on, ignoring, group_left and group_right out of an expression, and reads as
# a metric every identifier left that is no function (one followed by an opening parenthesis), keyword
# or number. A selector by __name__ names no metric to it, so an expression with one is refused.
metrics() {
  jq -R -r '
    if test("__name__") then error("an expression selects by __name__: \(.)") else . end
    | gsub("\"[^\"]*\""; "\"\"") | gsub("`[^`]*`"; "")
    | gsub("\\{[^}]*\\}"; "") | gsub("\\[[^\\]]*\\]"; "")
    | gsub("\\$\\{?[A-Za-z_][A-Za-z0-9_]*(:[a-z]+)?\\}?"; " ")
    | gsub("\\b(by|without|on|ignoring|group_left|group_right)\\s*\\([^)]*\\)"; " ")
    | [scan("(?<![A-Za-z0-9_:.])[A-Za-z_:][A-Za-z0-9_:]*(?![A-Za-z0-9_:]|\\s*\\()")] | .[]
    | select(. as $word | ["bool", "offset", "and", "or", "unless", "inf", "nan", "Inf", "NaN"] | index($word) | not)'
}

@test "An application's dashboard is delivered with it and leaves with it" {
  local apps app labels watched board boards namespace described dependencies names remaining key map
  built grafana
  labels="$(grafana_labels)"
  watched="$(yq -N 'select(.kind == "Grafana") | .metadata.namespace' "$BUILT")"
  # The Grafana application keeps the instance's own dashboards and no other application's: one that
  # describes an application must go with that application, so it is not kept here.
  [ "$(yq -N 'select(.kind == "GrafanaDashboard") | .metadata.name' "$BUILT" | sort | paste -sd' ' -)" = "cluster-home logs" ]
  # The operator watches its own namespace, which is the Grafana's, and no other: a dashboard
  # anywhere else would never be applied.
  built grafana-operator
  [ "$(yq -N 'select(.kind == "HelmRelease") | .metadata.namespace' "$BUILT")" = "$watched" ]
  [ "$(yq '.namespaceScope' "$REPO/kubernetes/apps/base/$NAMESPACE/grafana-operator/app/values.yaml")" = true ]
  [ "$(yq '.watchNamespaces // ""' "$REPO/kubernetes/apps/base/$NAMESPACE/grafana-operator/app/values.yaml")" = "" ]

  apps="$(dashboard_apps)"
  echo "applications that deliver a dashboard: $apps"
  [ "$apps" = "$DASHBOARD_APPS" ]
  for app in $apps; do
    built "$app"
    boards="$(yq -N -o json -I0 'select(.kind == "GrafanaDashboard")' "$BUILT")"
    echo "$app: GrafanaDashboards: $(jq -r '.metadata.name' <<<"$boards" | paste -sd' ' -)"
    [ -n "$boards" ]
    while IFS= read -r board; do
      namespace="$(jq -r '.metadata.namespace // ""' <<<"$board")"
      echo "$app: $(jq -r '.metadata.name' <<<"$board") in ${namespace:-no namespace}"
      [ "$namespace" = "$watched" ]
      # The Grafana is selected by labels it has.
      jq -e --argjson labels "$labels" '(.spec.instanceSelector.matchLabels // {}) as $selector
        | ($selector | length > 0) and ($selector | to_entries | all($labels[.key] == .value))' <<<"$board"
      # Its JSON is in the tree: a key of a ConfigMap of its own application, or the dashboard itself.
      map="$(jq -r '.spec.configMapRef.name // ""' <<<"$board")"
      key="$(jq -r '.spec.configMapRef.key // ""' <<<"$board")"
      if [ -n "$map" ]; then
        [ "$(MAP="$map" KEY="$key" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(MAP)) | .data | has(strenv(KEY))' "$BUILT")" = true ]
      else
        [ "$(jq -r '.spec.json // "" | length' <<<"$board")" -gt 0 ]
      fi
    done <<<"$boards"
  done

  # What each application's dashboard describes, and what happens to the dashboard without it. The
  # Grafana's own are the instance's: they go with the Grafana.
  names="$(overlay_names "$REPO/kubernetes/apps/overlays/lab-sto2")"
  for app in $apps; do
    [ "$app" = grafana ] && continue
    described="${app%-dashboard}"
    app_dir "$app"
    dependencies="$(yq '.spec.dependsOn // [] | .[].name' "$REPO/$APP_DIR/ks.yaml" | paste -sd' ' -)"
    echo "$app describes $described and waits for: $dependencies"
    # The kind exists once the operator's release is Ready.
    [[ " $dependencies " == *" grafana-operator "* ]]
    if [ "$described" != "$app" ]; then
      # A dashboard of its own application, in the namespace the operator watches, waits for what it
      # describes, and kubernetes-check refuses a cluster that enables it without that.
      [[ " $dependencies " == *" $described "* ]]
    fi
    [[ " $names " == *" $described "* ]]
    [[ " $names " == *" $app "* ]]
    without "$BATS_TEST_TMPDIR/without" "$described" "$app"
    remaining="$(overlay_names "$WITHOUT")"
    echo "the overlay without $described and $app has $(wc -w <<<"$remaining") Kustomizations, from $(wc -w <<<"$names")"
    [[ " $remaining " != *" $app "* ]]
    [[ " $remaining " != *" $described "* ]]
    if [ "$described" != "$app" ]; then
      without "$BATS_TEST_TMPDIR/without-only" "$described"
      run "$REPO/scripts/kubernetes-check" "$BATS_TEST_TMPDIR/without-only"
      echo "$output"
      [ "$status" -ne 0 ]
      [[ $output == *"Kustomization $app names $described in dependsOn"* ]]
    fi
  done
}

@test "A dashboard is pinned to an upstream revision the tree records, and nothing is fetched that the tree did not pin" {
  local app described board map key name file record version source licence sha pin fetched inline unaccounted count=0
  for app in $DASHBOARD_APPS; do
    built "$app"
    # No dashboard loads from the network at run time, nor asks Grafana to install a plugin. jq reads
    # the condition: yq binds or looser than a pipe, and reads .spec | has(a) or has(b) as
    # (.spec | has(a)) or has(b), b of the whole object.
    fetched="$(yq -N -o json -I0 'select(.kind == "GrafanaDashboard")' "$BUILT" | jq -r 'select(.spec // {}
      | has("url") or has("urlAuthorization") or has("grafanaCom") or has("oci") or has("jsonnet") or has("jsonnetLib")
        or (.plugins // [] | length > 0)) | .metadata.name')"
    echo "$app: fetched at run time: ${fetched:-none}"
    [ -z "$fetched" ]
    # The Grafana's own dashboards are written in this repository; every other application's is an
    # upstream file in a ConfigMap, which its GrafanaDashboard records.
    [ "$app" = grafana ] && continue
    inline="$(yq -N 'select(.kind == "GrafanaDashboard" and .spec.configMapRef == null) | .metadata.name' "$BUILT")"
    echo "$app: dashboards not from a ConfigMap: ${inline:-none}"
    [ -z "$inline" ]
    while IFS=$'\t' read -r board map key; do
      [ -n "$board" ] || continue
      count=$((count + 1))
      name="dashboard-${key%.json}"
      file="$(grep -l '^kind: GrafanaDashboard' "$TREE/$APP_DIR"/app/grafanadashboard*.yaml | head -1)"
      file="${file#"$TREE"/}"
      echo "$board ($key): recorded as $name in $file"
      record="$(grep -E "^[[:blank:]]*#[[:blank:]]*$name:[[:blank:]]*v?[0-9]+(\.[0-9]+)+[[:blank:]]*\$" "$REPO/$file")"
      [ "$(grep -c . <<<"$record")" -eq 1 ]
      version="$(sed -E 's/^[[:blank:]]*#[[:blank:]]*[a-z0-9-]+:[[:blank:]]*//; s/[[:blank:]]*$//' <<<"$record")"
      source="$(grep -E '^[[:blank:]]*#[[:blank:]]*Source:[[:blank:]]*https://' "$REPO/$file" | sed -E 's/^[^:]*:[[:blank:]]*//')"
      licence="$(grep -E '^[[:blank:]]*#[[:blank:]]*Licence:[[:blank:]]*[A-Za-z0-9.-]+[[:blank:]]*$' "$REPO/$file" | sed -E 's/^[^:]*:[[:blank:]]*//')"
      sha="$(grep -E '^[[:blank:]]*#[[:blank:]]*SHA-256:[[:blank:]]*[0-9a-f]{64}[[:blank:]]*$' "$REPO/$file" | sed -E 's/^[^:]*:[[:blank:]]*//')"
      echo "  revision $version, source ${source:-none}, licence ${licence:-none}, SHA-256 ${sha:-none}"
      [ "$(grep -c . <<<"$source")" -eq 1 ]
      [ "$(grep -c . <<<"$licence")" -eq 1 ]
      [ "$(grep -c . <<<"$sha")" -eq 1 ]
      # The source is a file of a public repository at the tag of the revision recorded.
      [[ $source == */blob/*"${version#v}"/* && $source != */blob/main/* && $source != */blob/master/* ]]
      # The file is the upstream's, unchanged: its bytes are what the record says.
      [ "$(configmap_value "$BUILT" "$map" "$key" | sha256sum | cut -d' ' -f1)" = "$sha" ]
      # The revision is the one the application it describes is released at: the pinned chart's tag
      # or the version of the application the chart declares, so a new chart brings this record to
      # the front of the pull request.
      described="${app%-dashboard}"
      chart "$described"
      echo "  $described's chart: $CHART_TAG, application $CHART_APP_VERSION"
      [ "$version" = "$CHART_TAG" ] || [ "$version" = "$CHART_APP_VERSION" ]
      # What it describes is scraped: the cluster's render holds a monitor of that application.
      cluster_render </dev/null
      compgen -G "$CLUSTER_RENDER/$described/*Monitor.monitoring.coreos.com_*.yaml" ||
        { echo "$described: no monitor in the render"; return 1; }
      # Renovate moves none of it: the pin check holds the record as one moved by hand.
      pin="$(awk -F'\t' -v file="$file" -v name="$name" '$1 == file && $2 == name' "$REPO/.renovate/by-hand.tsv")"
      [ -n "$pin" ] || { echo "no row of .renovate/by-hand.tsv for $name in $file"; return 1; }
    done < <(yq -N -o json -I0 'select(.kind == "GrafanaDashboard" and .spec.configMapRef != null)' "$BUILT" |
      jq -r '[.metadata.name, .spec.configMapRef.name, .spec.configMapRef.key] | @tsv')
    built "$app"
  done
  echo "dashboards from an upstream file: $count"
  [ "$count" -ge 2 ]
  # Every dashboard the cluster renders is one of those checked above, wherever its file is named.
  cluster_render
  unaccounted="$(unaccounted_dashboards "$CLUSTER_RENDER"/*/*.yaml)"
  echo "dashboards of the cluster no check built: ${unaccounted:-none}"
  [ -z "$unaccounted" ]
  # One that is not, a dashboard fetched from a URL, is named.
  cat >"$BATS_TEST_TMPDIR/fetched.yaml" <<'YAML'
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: fetched-dashboard
spec:
  url: https://example.com/dashboard.json
YAML
  [ "$(unaccounted_dashboards "$CLUSTER_RENDER"/*/*.yaml "$BATS_TEST_TMPDIR/fetched.yaml")" = fetched-dashboard ]
}

@test "Every dashboard has a unique identity and reads only datasources the tree defines" {
  local app files="" file all="$BATS_TEST_TMPDIR/boards.jsonl" datasources board json problems uids total unaccounted
  built grafana
  datasources="$(yq -N -o json -I0 'select(.kind == "GrafanaDatasource")' "$BUILT" |
    jq -s -c '[.[] | {name: .spec.datasource.name, type: .spec.datasource.type, uid: (.spec.uid // "")}]')"
  echo "datasources of the tree: $datasources"
  [ "$(jq 'length' <<<"$datasources")" -ge 2 ]
  for app in $DASHBOARD_APPS; do
    built "$app"
    cp "$BUILT" "$BATS_TEST_TMPDIR/own-$app.yaml"
    files+=" $BATS_TEST_TMPDIR/own-$app.yaml"
  done
  # shellcheck disable=SC2086 # The names hold no space.
  boards $files >"$all"
  # The monitoring chart's own dashboards, which the release of the grafana application renders.
  render grafana
  boards "$RENDERED" >>"$all"
  total="$(grep -c . "$all")"
  echo "dashboards: $total"
  [ "$total" -gt 25 ]
  # No dashboard of the cluster is outside those read.
  cluster_render
  unaccounted="$(unaccounted_dashboards "$CLUSTER_RENDER"/*/*.yaml)"
  echo "dashboards of the cluster no check built: ${unaccounted:-none}"
  [ -z "$unaccounted" ]

  problems=""
  uids=""
  while IFS= read -r board; do
    json="$(jq -r '.json // ""' <<<"$board")"
    if [ -z "$json" ]; then
      problems+=$'\n'"$(jq -r .name <<<"$board"): its JSON is nowhere in the tree"
      continue
    fi
    # Each input the GrafanaDashboard maps is one its JSON names as ${input}, and the datasource it
    # maps it to is one of the tree's, by the name the operator writes in its place.
    problems+=$'\n'"$(jq -r --argjson datasources "$datasources" '.name as $name | .json as $json
      | .datasources[] | . as $map
      | if (.inputName // "") == "" or (.datasourceName // "") == ""
        then "\($name): maps no input or no datasource: \(tojson)"
        elif any($datasources[]; .name == $map.datasourceName) | not
        then "\($name): maps \(.inputName) to \(.datasourceName), a datasource the tree does not define"
        elif $json | contains("${\($map.inputName)}") | not
        then "\($name): maps \(.inputName), which its JSON never names"
        else empty end' <<<"$board")"$'\n'
    # The JSON as Grafana gets it: the operator replaces every ${input} of spec.datasources with its
    # datasourceName, byte for byte, before it parses the JSON (resolveDatasources in its
    # controllers/content/resolver.go), and leaves a reference without the braces as it is.
    json="$(jq -r 'reduce (.datasources[] | select(.inputName and .datasourceName)) as $map
      (.json; split("${\($map.inputName)}") | join($map.datasourceName))' <<<"$board")"
    if ! jq -e . >/dev/null 2>&1 <<<"$json"; then
      problems+=$'\n'"$(jq -r .name <<<"$board"): its JSON does not parse"
      continue
    fi
    if [ -z "$(jq -r '.uid // ""' <<<"$json")" ]; then
      problems+=$'\n'"$(jq -r .name <<<"$board"): no uid"
      continue
    fi
    uids+="$(jq -r '.uid' <<<"$json")"$'\t'"$(jq -r .name <<<"$board")"$'\n'
    problems+="$(jq -r --argjson datasources "$datasources" --argjson board "$(jq -c '{name}' <<<"$board")" '
      def title: .title // "";
      # The name a reference to a variable names: $name, ${name} or ${name:format}.
      def variable: if type == "string" then (capture("^\\$\\{?(?<name>[A-Za-z0-9_]+)(:[a-z]+)?\\}?$") | .name) // null else null end;
      def types: [$datasources[].type];
      def own: ["datasource", "grafana", "prometheus-builtin"];
      . as $dashboard
      | (.templating.list // []) as $variables
      | ($variables | map(select(.type == "datasource") | {key: .name, value: (.query | tostring)}) | from_entries) as $listed
      # Whether a reference, after the operator replaced the mapped ones, resolves: a variable that
      # lists the type of a datasource of the tree, or its uid or name, or one of Grafana itself.
      | def resolves($ref):
          if $ref == null then true
          elif ($ref | type) == "string" then
            ($ref | test("^-- .* --$")) or ($ref | IN(own[]))
            or any($datasources[]; .name == $ref or (.uid != "" and .uid == $ref))
            or (($ref | variable) as $name | $name != null and (($listed[$name] // "") | IN(types[])))
          else
            ($ref.type // null) as $type | ($ref.uid // null) as $uid
            | (($type == null) or ($type | IN(types[])) or ($type | IN(own[])))
              and ($uid == null or resolves($uid))
          end;
      ([.. | objects | select(has("datasource")) | .datasource] | unique) as $references
      | (if title == "" then ["\($board.name): no title"] else [] end)
        + [$references[] | select(resolves(.) | not) | "\($board.name): reads a datasource the tree does not define: \(tojson)"]
      | .[]' <<<"$json")"$'\n'
  done <"$all"
  # An identity no other dashboard has: the uid, which Grafana keys a dashboard by.
  problems+="$(cut -f1 <<<"$uids" | grep -v '^$' | sort | uniq -d | while read -r uid; do
    echo "the uid $uid is that of: $(grep -F "$uid"$'\t' <<<"$uids" | cut -f2 | paste -sd' ' -)"
  done)"
  problems="$(grep -v '^$' <<<"$problems" || true)"
  echo "problems: ${problems:-none}"
  [ -z "$problems" ]
  [ "$(cut -f1 <<<"$uids" | grep -c -v '^$')" -eq "$total" ]
  # The ones this tree adds are among those read.
  grep -q $'^cluster-home\t' <<<"$uids"
  grep -q $'^openbao\t' <<<"$uids"
}

@test "The home dashboard queries only metrics the cluster scrapes" {
  local uid board json exprs metric source regex target monitors records alerts known="" unscraped="" expr
  built grafana
  uid="$(yq -N 'select(.kind == "Grafana") | .spec.preferences.homeDashboardUid // ""' "$BUILT")"
  echo "the Grafana's home dashboard: ${uid:-none}"
  [ -n "$uid" ]
  # The home dashboard is one of the instance's own, carried in its GrafanaDashboard.
  json=""
  while IFS= read -r board; do
    [ "$(jq -r '.json // "{}" | fromjson | .uid // ""' <<<"$board")" = "$uid" ] || continue
    json="$(jq -r '.json' <<<"$board")"
  done < <(boards "$BUILT")
  [ -n "$json" ]
  # It is in the folder docs/kubernetes.md (Dashboards) names for it, not the namespace's.
  [ "$(yq -N 'select(.kind == "GrafanaDashboard" and .metadata.name == "cluster-home") | .spec.folder' "$BUILT")" = General ]
  exprs="$(jq -r '[.. | objects | select(has("expr")) | .expr] | .[]' <<<"$json")"
  echo "queries: $(grep -c . <<<"$exprs")"
  [ "$(grep -c . <<<"$exprs")" -ge 6 ]

  cluster_render
  monitors="$(yq -N 'select(. != null) | select(.kind == "ServiceMonitor" or .kind == "PodMonitor") | .kind + "/" + .metadata.name' "$CLUSTER_RENDER"/*/*.yaml | sort -u)"
  records="$(yq -N 'select(. != null) | select(.kind == "PrometheusRule") | .spec.groups[].rules[] | select(.record) | .record' "$CLUSTER_RENDER"/*/*.yaml | sort -u)"
  alerts="$(yq -N 'select(. != null) | select(.kind == "PrometheusRule") | .spec.groups[].rules[] | select(.alert) | .alert' "$CLUSTER_RENDER"/*/*.yaml | sort -u)"
  echo "monitors in the render: $(grep -c . <<<"$monitors"); recording rules: $(grep -c . <<<"$records"); alerting rules: $(grep -c . <<<"$alerts")"
  [ -n "$monitors" ]

  # Where each metric comes from, in tests/fixtures/dashboards/metric-sources.tsv: a monitor of the
  # render that scrapes the target that serves it, a monitor of any kind for up, or an alerting rule
  # for the series Prometheus writes for each alert. A series a recording rule of the render writes
  # needs no row.
  while IFS= read -r expr; do
    while IFS= read -r metric; do
      [ -n "$metric" ] || continue
      if grep -qxF "$metric" <<<"$records"; then
        known+="$metric: recorded by a rule"$'\n'
        continue
      fi
      source=""
      while IFS=$'\t' read -r regex target; do
        [[ $regex =~ ^# ]] && continue
        [ -n "$regex" ] || continue
        if [[ $metric =~ ^($regex)$ ]]; then source="$target"; break; fi
      done <"$BATS_TEST_DIRNAME/fixtures/dashboards/metric-sources.tsv"
      case "$source" in
        "") unscraped+="$metric: no monitor or rule of the cluster is known to serve it"$'\n' ;;
        any-monitor) [ -n "$monitors" ] && known+="$metric: any monitor"$'\n' ;;
        alerting-rule) if [ -n "$alerts" ]; then known+="$metric: written for each alerting rule"$'\n'; else unscraped+="$metric: the render has no alerting rule"$'\n'; fi ;;
        *) if grep -qxF "$source" <<<"$monitors"; then known+="$metric: scraped by $source"$'\n'; else unscraped+="$metric: $source is not in the render"$'\n'; fi ;;
      esac
    done < <(metrics <<<"$expr")
  done <<<"$exprs"
  echo "${known:-no metric}"
  echo "unscraped: ${unscraped:-none}"
  [ -n "$known" ]
  [ -z "$unscraped" ]
}

@test "A dashboard too large for its delivery fails the checks" {
  local app files="" padded="$BATS_TEST_TMPDIR/padded.json" largest
  for app in $DASHBOARD_APPS; do
    built "$app"
    cp "$BUILT" "$BATS_TEST_TMPDIR/own-$app.yaml"
    files+=" $BATS_TEST_TMPDIR/own-$app.yaml"
  done
  render grafana
  # Every dashboard of the tree, the monitoring chart's included, fits its delivery.
  # shellcheck disable=SC2086 # The names hold no space.
  oversized $files "$RENDERED"
  # And no dashboard of the cluster is outside those.
  cluster_render
  [ -z "$(unaccounted_dashboards "$CLUSTER_RENDER"/*/*.yaml)" ]
  # The largest of the tree's own is a real dashboard, and has room left.
  # shellcheck disable=SC2086
  largest="$(yq -N -o json -I0 'select(.kind == "ConfigMap") | .data // {} | .[]' $files | jq -r 'utf8bytelength' | sort -n | tail -1)"
  echo "the largest dashboard of the tree's own: $largest bytes of $CONFIGMAP_LIMIT"
  [ "$largest" -gt 10000 ]
  [ "$largest" -lt "$CONFIGMAP_LIMIT" ]
  # A dashboard padded past the ceiling is refused, with its ConfigMap named.
  jq -n --argjson limit "$CONFIGMAP_LIMIT" '{apiVersion: "v1", kind: "ConfigMap", metadata: {name: "padded-dashboard"},
    data: {"padded.json": ("{\"panels\": [], \"description\": \"" + (" " * ($limit + 1)) + "\"}")}}' >"$padded"
  run oversized "$padded"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"ConfigMap/padded-dashboard"* ]]
  # And a GrafanaDashboard that carries more than that in its own JSON.
  jq -n --argjson limit "$CONFIGMAP_LIMIT" '{apiVersion: "grafana.integreatly.org/v1beta1", kind: "GrafanaDashboard",
    metadata: {name: "padded-inline"}, spec: {json: ("{\"description\": \"" + (" " * ($limit + 1)) + "\"}")}}' >"$padded"
  run oversized "$padded"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"GrafanaDashboard/padded-inline"* ]]
}
