#!/usr/bin/env bats
# Proves features/status-badges.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq, jq, git and awk on PATH (the versions pinned for the repository).
# The app-template chart is pulled once per run from its public registry, kromgo's configuration
# schema is read once per run from its public repository at the image's tag, and the cluster's render
# pulls every chart the overlay names; building, rendering and checking are offline, with the
# placeholders of the cluster's example key lists.

# flux build rewrites the kustomization.yaml of what it builds and puts it back afterwards, and the
# chart is pulled once: so the tests run one at a time.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

# The badges kromgo serves, by id, sorted: the closed list docs/kubernetes.md (Status badges)
# describes. A badge is added here on purpose, with its row in that list.
BADGES="cluster_age_days cluster_cpu_usage cluster_memory_usage cluster_node_count cluster_pod_count firing_alerts kubernetes_version talos_version"

# What a query may keep of the labels of what it selects, and what it may select by. A result's
# labels are what the JSON form of a badge returns, so the only ones a query may keep are the
# versions it shows; a matcher may name the target's job or service, a state, or the kind of thing,
# never a node, a pod, a namespace or an address.
KEPT_LABELS="version_id git_version"
MATCHED_LABELS="job service phase condition name alertname alertstate"

# tree_without, a copy of the tree whose overlay leaves applications and namespaces out.
load fixtures/tree-without

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
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLUSTER="$REPO/kubernetes/clusters/lab-sto2"
  KUBE="$(yq -e '.kubernetes' "$REPO/versions.yaml")"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  EXAMPLE="$BATS_TEST_TMPDIR/example-vars.yaml"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$EXAMPLE"
  OVERLAY_DIR="$REPO/kubernetes/apps/overlays/lab-sto2"
}

# overlay: the lab-sto2 overlay as Flux reads it, its namespaces and the Kustomization of each
# enabled application. Writes $OVERLAY.
overlay() {
  OVERLAY="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "$OVERLAY_DIR" >"$OVERLAY"
}

# built: kromgo as Flux applies it on lab-sto2: the overlay's Kustomization of it, with the example
# key lists, or those of the file VARS names, and its own substitutions over them, strictly. Writes
# $BATS_TEST_TMPDIR/kromgo-built.yaml and sets BUILT and KS, the Kustomization as built.
built() {
  local path
  overlay
  KS="$BATS_TEST_TMPDIR/kromgo-ks.yaml"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars
    | select(fileIndex == 1 and .kind == "Kustomization" and .metadata.name == "kromgo")
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "${VARS:-$EXAMPLE}" "$OVERLAY" >"$KS"
  [ -s "$KS" ] || { echo "the lab-sto2 overlay does not enable kromgo"; return 1; }
  path="$(yq '.spec.path' "$KS")"
  BUILT="$BATS_TEST_TMPDIR/kromgo-built.yaml"
  (cd "$REPO" && flux build kustomization kromgo --path "./kubernetes/${path#./}" \
    --kustomization-file "$KS" --dry-run --strict-substitute) >"$BUILT"
}

# other_vars: writes a copy of the example values with another domain and sets OTHER to it, so a
# test can build again and see that what it read came from the variable, not from a literal that
# happens to equal the example.
other_vars() {
  OTHER="$BATS_TEST_TMPDIR/other-vars.yaml"
  CLUSTER_DOMAIN=other.example.org yq '.CLUSTER_DOMAIN = strenv(CLUSTER_DOMAIN)' "$EXAMPLE" >"$OTHER"
}

# render: renders the chart kromgo's HelmRelease installs, from the URL and tag of its OCIRepository,
# with the values helm-controller gives it: those of each ConfigMap the HelmRelease reads, then the
# HelmRelease's own over them, as scripts/render does. Builds kromgo, writes
# $BATS_TEST_TMPDIR/rendered.yaml and sets BUILT, RENDERED and INLINE.
render() {
  local url tag release namespace pulled name i values=() count
  built
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  count="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom | length' "$BUILT")"
  for ((i = 0; i < count; i++)); do
    name="$(I=$i yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[env(I)].name' "$BUILT")"
    [ "$(I=$i yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[env(I)].kind' "$BUILT")" = ConfigMap ] ||
      { echo "valuesFrom $name is not a ConfigMap"; return 1; }
    values[i]="$BATS_TEST_TMPDIR/values-$i.yaml"
    NAME="$name" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .data["values.yaml"]' \
      "$BUILT" >"${values[i]}"
    [ -s "${values[i]}" ] || { echo "no values in the ConfigMap $name the HelmRelease reads"; return 1; }
  done
  INLINE="$BATS_TEST_TMPDIR/inline.yaml"
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$BUILT" >"$INLINE"
  pulled="$BATS_FILE_TMPDIR/charts/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  RENDERED="$BATS_TEST_TMPDIR/rendered.yaml"
  helm template "$release" "$pulled"/*.tgz --namespace "$namespace" --kube-version "$KUBE" \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor \
    "${values[@]/#/--values=}" --values "$INLINE" >"$RENDERED"
}

# only FILE KIND: the name of the one object of that kind in FILE; fails, saying so, unless there is
# exactly one.
only() {
  local names
  names="$(KIND="$2" yq -N 'select(.kind == strenv(KIND)) | .metadata.name' "$1")"
  [ -n "$names" ] && [ "$(wc -l <<<"$names")" -eq 1 ] || { echo "$1 holds $(wc -l <<<"$names") $2 objects: ${names:-none}"; return 1; }
  echo "$names"
}

# object FILE KIND NAME: the one object of that kind and name in FILE.
object() {
  KIND="$2" NAME="$3" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$1"
}

# config: writes kromgo's configuration, the file its HelmRelease mounts from the ConfigMap it names
# in its values, to $CONFIG, after built.
config() {
  local name
  built
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.values.persistence.config.name' "$BUILT")"
  [ -n "$name" ] && [ "$name" != null ] || { echo "the HelmRelease mounts no configuration ConfigMap"; return 1; }
  CONFIG="$BATS_TEST_TMPDIR/config.yaml"
  NAME="$name" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .data["config.yaml"]' "$BUILT" >"$CONFIG"
  [ -s "$CONFIG" ] || { echo "no config.yaml in the ConfigMap $name"; return 1; }
}

# config_chart TAG: a chart that holds nothing but kromgo's configuration schema at the release tag
# TAG, from its public repository, fetched once per run with only the objects that file needs, as
# its values schema: helm checks the values it is given against that, so `helm template` of it with
# a configuration as values checks the configuration against the schema, offline. Sets CONFIG_CHART.
config_chart() {
  local src="$BATS_FILE_TMPDIR/kromgo-source/$1"
  CONFIG_CHART="$BATS_FILE_TMPDIR/kromgo-config-chart/$1"
  if [ ! -s "$CONFIG_CHART/values.schema.json" ]; then
    rm -rf "$src" "$CONFIG_CHART"
    mkdir -p "$CONFIG_CHART"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$1" --filter=tree:0 --no-checkout \
      https://github.com/home-operations/kromgo.git "$src"
    git -C "$src" show HEAD:config.schema.json >"$CONFIG_CHART/values.schema.json"
    printf '%s\n' 'apiVersion: v2' 'name: kromgo-config' 'version: 0.0.0' >"$CONFIG_CHART/Chart.yaml"
  fi
}

# queries: every badge's id and query of $CONFIG, tab separated, one per line.
queries() {
  yq -N '.badges[] | .id + "\t" + .query' "$CONFIG"
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

# metrics: the metric names the PromQL expressions on its input select, one per line. It takes
# string literals, label matchers, ranges, and the label lists of by, without, on, ignoring,
# group_left and group_right out of an expression, and reads as a metric every identifier left that
# is no function (one followed by an opening parenthesis), keyword or number. A selector by
# __name__ names no metric to it, so an expression with one is refused. It does not parse PromQL: a
# metric it reads is one the text names, and what a query does with it is for leaks to say.
metrics() {
  jq -R -r '
    if test("__name__") then error("an expression selects by __name__: \(.)") else . end
    | gsub("\"[^\"]*\""; "\"\"")
    | gsub("\\{[^}]*\\}"; "") | gsub("\\[[^\\]]*\\]"; "")
    | gsub("\\b(by|without|on|ignoring|group_left|group_right)\\s*\\([^)]*\\)"; " ")
    | [scan("(?<![A-Za-z0-9_:.])[A-Za-z_:][A-Za-z0-9_:]*(?![A-Za-z0-9_:]|\\s*\\()")] | .[]
    | select(. as $word | ["bool", "offset", "and", "or", "unless", "inf", "nan", "Inf", "NaN"] | index($word) | not)'
}

# leaks QUERY: what a query of $CONFIG lets through of the labels of what it selects, one problem per
# line, none when it lets nothing through. Read as text, which is what it can see:
#   - a matcher names only a label of MATCHED_LABELS, its name bare or quoted, and there is no
#     selector without a metric;
#   - every metric sits inside an aggregation (count, sum, avg, min, max) that keeps no label but
#     those of KEPT_LABELS, written before its operand, so no series reaches the result with its
#     labels;
#   - nothing relabels, joins or picks series (label_replace, label_join, group_left, group_right,
#     topk, bottomk, limitk, limit_ratio, count_values) and nothing aggregates without.
# It cannot see what a label holds, so an allowed label that held an address would pass.
leaks() {
  local query=$1 stripped label
  # A matcher's label name, bare or, as Prometheus 3 allows, quoted in any of PromQL's quotes.
  # shellcheck disable=SC2016 # The backticks are a PromQL quote, not a command.
  local matcher='[{,][[:space:]]*([A-Za-z_][A-Za-z0-9_]*|"[^"]*"|'\''[^'\'']*'\''|`[^`]*`)[[:space:]]*(=~|!~|!=|=)'
  if [[ $query == *__name__* ]]; then
    echo "selects by __name__"
    return 0
  fi
  if grep -Eq '(^|[^A-Za-z0-9_:])\{' <<<"$query"; then
    echo "a selector without a metric name"
  fi
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    [[ " $MATCHED_LABELS " == *" $label "* ]] || echo "a matcher on the label $label"
  done < <(grep -Eo "$matcher" <<<"$query" | sed -E 's/^[{,[:space:]]*//; s/[[:space:]]*(=~|!~|!=|=)$//; s/^["'\''`](.*)["'\''`]$/\1/')
  stripped="$(sed -E 's/"[^"]*"/""/g; s/\{[^}]*\}//g; s/\[[^]]*\]//g' <<<"$query")"
  awk -v kept="$KEPT_LABELS" '
    function problem(text) { print text }
    function only_kept(list,   n, names, i, j, found) {
      n = split(list, names, /[ \t,]+/)
      for (i = 1; i <= n; i++) {
        if (names[i] == "") continue
        found = 0
        for (j = 1; j <= nkept; j++) if (names[i] == allowed[j]) found = 1
        if (!found) return 0
      }
      return 1
    }
    BEGIN { nkept = split(kept, allowed, " ") }
    {
      s = $0; depth = 0; covered = 0; pending = ""; keeps = 1; prev = ""
      while (s != "") {
        if (match(s, /^[ \t]+/)) { s = substr(s, RLENGTH + 1); continue }
        if (match(s, /^[0-9][0-9A-Za-z_.]*/)) { s = substr(s, RLENGTH + 1); prev = "number"; continue }
        if (match(s, /^[A-Za-z_:][A-Za-z0-9_:]*/)) {
          word = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
          rest = s; sub(/^[ \t]+/, "", rest); next_char = substr(rest, 1, 1)
          if (word ~ /^(by|without|on|ignoring|group_left|group_right)$/ && next_char == "(") {
            close_at = index(rest, ")"); list = substr(rest, 2, close_at - 2); s = substr(rest, close_at + 1)
            if (word == "by" && pending != "" && prev == "aggregation") {
              if (!only_kept(list)) { problem("an aggregation keeps the label(s) " list); keeps = 0 }
            } else if (word == "on" || word == "ignoring") {
              # Matching labels only choose which series pair up; every series is still inside an aggregation.
            } else problem("`" word "` after its operand, or without or group_*: the labels it keeps are not known")
            continue
          }
          if (word ~ /^(bool|offset|and|or|unless|inf|nan|Inf|NaN)$/) { prev = "keyword"; continue }
          if (word ~ /^(label_replace|label_join|topk|bottomk|limitk|limit_ratio|count_values)$/) problem("`" word "` relabels, joins or picks series")
          if (word ~ /^(count|sum|avg|min|max)$/ && (next_char == "(" || rest ~ /^(by|without)[^A-Za-z0-9_:]/)) { pending = word; keeps = 1; prev = "aggregation"; continue }
          if (next_char == "(") { prev = "function"; continue }
          if (covered == 0) problem("`" word "` is selected outside an aggregation that drops its labels")
          prev = "metric"; continue
        }
        c = substr(s, 1, 1); s = substr(s, 2)
        if (c == "(") {
          depth++
          if (pending != "") { frame[depth] = keeps ? "drops" : "keeps"; if (keeps) covered++; pending = "" }
          else frame[depth] = "other"
          prev = "open"
        } else if (c == ")") {
          if (depth == 0) { problem("unbalanced parentheses"); continue }
          if (frame[depth] == "drops") covered--
          depth--; prev = "close"
        } else prev = "operator"
      }
      if (depth != 0) problem("unbalanced parentheses")
    }' <<<"$stripped"
}

# hostnames FILE: each place of a kromgo configuration FILE that holds a dotted name, as a hostname
# is, one per line, none when none does. A dotted name is a dot between a letter, a digit, `_` or
# `-` and a letter. It reads every string value whole, but for a query and the CEL expressions, whose
# own text has dots that are no name (a member access such as `.orValue`), of which it reads the
# string literals, in any of their quotes. A number such as 0.1 or a version such as 1.2.3 is no
# dotted name; a name without a dot, or a CEL member access written outside a string, is not seen.
hostnames() {
  # shellcheck disable=SC2016 # $p and $v are jq variables, and the backticks are a PromQL quote.
  yq -o json '.' "$1" | jq -r '
    paths(type == "string") as $p | getpath($p) as $v
    | (if ($p[-1] | tostring | IN("query", "valueExpr", "colorExpr"))
        then $v | [scan("\"(?:[^\"\\\\]|\\\\.)*\"|'\''(?:[^'\''\\\\]|\\\\.)*'\''|`[^`]*`")] | .[]
        else $v end)
    | select(test("[A-Za-z0-9_-]\\.[A-Za-z]"))
    | "\($p | map(tostring) | join(".")): \(.)"'
}

# of_kromgo FILE: what an overlay built into FILE holds of kromgo, sorted, as kind, namespace and
# name: the namespace itself, any object in it, and any Kustomization that deploys into it or from
# its directory.
of_kromgo() {
  yq -N 'select((.kind == "Namespace" and .metadata.name == "kromgo") or .metadata.namespace == "kromgo"
      or .spec.targetNamespace == "kromgo" or ((.spec.path // "") | test("/apps/base/kromgo/")))
    | .kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$1" | LC_ALL=C sort | paste -sd, -
}

@test "A cluster that does not select kromgo builds none of it, and one that selects it without what it depends on is refused" {
  local dependency dependencies=(prometheus-operator-crds gateway-public cilium blackbox-exporter)
  # The overlay selects it with two entries, its namespace directory and its ks.yaml, and builds
  # the namespace with its default deny, the defaults every namespace directory holds, and the
  # Kustomization.
  [ "$(yq '.resources[] | select(test("/kromgo(/|$)"))' "$OVERLAY_DIR/kustomization.yaml" | paste -sd, -)" = ../../base/kromgo,../../base/kromgo/kromgo/ks.yaml ]
  overlay
  [ "$(of_kromgo "$OVERLAY")" = ConfigMap/kromgo/app-template-defaults,Kustomization/flux-system/kromgo,Namespace/-/kromgo,NetworkPolicy/kromgo/default-deny ]
  # Its Kustomization names what it needs, no more and no less.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "kromgo") | .spec.dependsOn | map(.name) | sort | join(" ")' "$OVERLAY")" \
    = "$(printf '%s\n' "${dependencies[@]}" | sort | paste -sd' ' -)" ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # With only the namespace directory's entry, the cluster builds the namespace, its default deny
  # and its defaults, and nothing else of kromgo.
  tree_without ks:kromgo
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2" >"$BATS_TEST_TMPDIR/namespace-only.yaml"
  [ "$(of_kromgo "$BATS_TEST_TMPDIR/namespace-only.yaml")" = ConfigMap/kromgo/app-template-defaults,Namespace/-/kromgo,NetworkPolicy/kromgo/default-deny ]
  # With neither, nothing of kromgo.
  tree_without ks:kromgo ns:kromgo
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2" >"$BATS_TEST_TMPDIR/neither.yaml"
  [ -z "$(of_kromgo "$BATS_TEST_TMPDIR/neither.yaml")" ]
  # Selecting it without one of the applications it needs is refused, naming both.
  for dependency in "${dependencies[@]}"; do
    tree_without "ks:$dependency"
    run "$REPO/scripts/kubernetes-check" "$TREE"
    echo "without $dependency: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"kubernetes/apps/base/kromgo/kromgo/ks.yaml: Kustomization kromgo names $dependency"* ]]
    [[ $output == *"does not enable"* ]]
  done
}

@test "kromgo answers only the named queries, and each reads metrics the cluster scrapes" {
  local ids tag prometheus metric source regex target monitors records alerts known="" unscraped="" id query
  config
  # The closed list: these ids and no other, as badges, with no graph, which would serve a range of
  # its query, and no gallery page; the Prometheus is the stack's, named once, in the environment.
  ids="$(yq -N '.badges[].id' "$CONFIG" | LC_ALL=C sort | paste -sd' ' -)"
  echo "badges: $ids"
  [ "$ids" = "$BADGES" ]
  [ "$(yq '.badges | length' "$CONFIG")" -eq "$(wc -w <<<"$BADGES")" ]
  [ "$(yq 'has("graphs")' "$CONFIG")" = false ]
  [ "$(yq '.gallery.enabled' "$CONFIG")" = false ]
  [ "$(yq 'has("prometheus")' "$CONFIG")" = false ]
  # No badge asks for a range: each is the value of one instant query.
  [ "$(yq '[.badges[] | select(has("type") and .type != "instant")] | length' "$CONFIG")" -eq 0 ]
  # Prometheus is reached by the Service the monitoring stack's chart puts in front of it.
  render
  prometheus="$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "KROMGO_PROMETHEUS_URL") | .value' "$RENDERED")"
  echo "Prometheus: $prometheus"
  [ "$prometheus" = http://kube-prometheus-stack-prometheus.monitoring.svc:9090 ]
  # The pinned source was read at the version the image is: a new version is read again before this
  # test passes, for the one thing the tree cannot assert, that no request names a query
  # (docs/kubernetes.md, Status badges).
  tag="$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$RENDERED" | sed -E 's/^[^:]*:([^@]*)@.*$/\1/')"
  grep -qF "kromgo $tag" "$REPO/docs/kubernetes.md"

  cluster_render
  [ "$(yq -N 'select(.kind == "Service" and .metadata.namespace == "monitoring" and .metadata.name == "kube-prometheus-stack-prometheus") | .spec.ports[] | select(.port == 9090) | .port' "$CLUSTER_RENDER"/*/*.yaml)" = 9090 ]
  monitors="$(yq -N 'select(. != null) | select(.kind == "ServiceMonitor" or .kind == "PodMonitor") | .kind + "/" + .metadata.name' "$CLUSTER_RENDER"/*/*.yaml | sort -u)"
  records="$(yq -N 'select(. != null) | select(.kind == "PrometheusRule") | .spec.groups[].rules[] | select(.record) | .record' "$CLUSTER_RENDER"/*/*.yaml | sort -u)"
  alerts="$(yq -N 'select(. != null) | select(.kind == "PrometheusRule") | .spec.groups[].rules[] | select(.alert) | .alert' "$CLUSTER_RENDER"/*/*.yaml | sort -u)"
  echo "monitors in the render: $(grep -c . <<<"$monitors"); recording rules: $(grep -c . <<<"$records"); alerting rules: $(grep -c . <<<"$alerts")"
  [ -n "$monitors" ]
  # Where each metric comes from, in tests/fixtures/kromgo/metric-sources.tsv: a monitor of the render
  # that scrapes the target that serves it, or an alerting rule for the series Prometheus writes for
  # each alert. A series a recording rule of the render writes needs no row. The check is by name:
  # it cannot see that a target serves a metric, which the fixture states, nor a matcher's labels.
  while IFS=$'\t' read -r id query; do
    while IFS= read -r metric; do
      [ -n "$metric" ] || continue
      if grep -qxF "$metric" <<<"$records"; then
        known+="$id: $metric: recorded by a rule"$'\n'
        continue
      fi
      source=""
      while IFS=$'\t' read -r regex target; do
        [[ $regex =~ ^# ]] && continue
        [ -n "$regex" ] || continue
        if [[ $metric =~ ^($regex)$ ]]; then source="$target"; break; fi
      done <"$BATS_TEST_DIRNAME/fixtures/kromgo/metric-sources.tsv"
      case "$source" in
        "") unscraped+="$id: $metric: no monitor or rule of the cluster is known to serve it"$'\n' ;;
        alerting-rule) if [ -n "$alerts" ]; then known+="$id: $metric: written for each alerting rule"$'\n'; else unscraped+="$id: $metric: the render has no alerting rule"$'\n'; fi ;;
        *) if grep -qxF "$source" <<<"$monitors"; then known+="$id: $metric: scraped by $source"$'\n'; else unscraped+="$id: $metric: $source is not in the render"$'\n'; fi ;;
      esac
    done < <(metrics <<<"$query")
  done < <(queries)
  echo "${known:-no metric}"
  echo "unscraped: ${unscraped:-none}"
  [ -n "$known" ]
  [ -z "$unscraped" ]
  # The alert the firing-alerts badge leaves out because it always fires is one the render has.
  grep -qxF Watchdog <<<"$alerts"
}

@test "kromgo's numbers name no node, address or hostname" {
  local id query problems="" found
  config
  while IFS=$'\t' read -r id query; do
    found="$(leaks "$query")"
    echo "$id: ${found:-keeps no label but a version}"
    problems+="$found"
  done < <(queries)
  [ -z "$problems" ]
  # The configuration is not run through Flux's substitution, so it holds nothing of the cluster's
  # domain or any other variable, and names no hostname.
  [ "$(NAME="$(yq -N 'select(.kind == "HelmRelease") | .spec.values.persistence.config.name' "$BUILT")" \
    yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .metadata.annotations["kustomize.toolkit.fluxcd.io/substitute"]' "$BUILT")" = disabled ]
  # shellcheck disable=SC2016 # `${` is the text of a variable, not one to expand.
  [ -z "$(grep -F '${' "$CONFIG" || true)" ]
  [ -z "$(yq -o json '.' "$CONFIG" | grep -Ei 'CLUSTER_DOMAIN|example\.(org|com)|https?://' || true)" ]
  found="$(hostnames "$CONFIG")"
  echo "dotted names: ${found:-none}"
  [ -z "$found" ]
  # A dotted name is found in a title, in a string of a query or an expression, and in any other
  # value; the configuration's own dots, in a number and a member access, are not one.
  cat >"$BATS_TEST_TMPDIR/dotted.yaml" <<'EOF'
badges:
  - id: a
    title: nodes.lab.example.net
    query: count(up)
  - id: b
    query: count(up{job="api.example.net"})
  - id: c
    query: count(up)
    valueExpr: '"x" + "kromgo.cluster.example.net"'
  - id: d
    query: count(up)
    colorExpr: "result == 0.0 ? 'api-1.example.net' : 'red'"
  - id: e
    query: count(up)
    icon: nodes.example.net
EOF
  found="$(hostnames "$BATS_TEST_TMPDIR/dotted.yaml")"
  echo "$found"
  [ "$(cut -d: -f1 <<<"$found" | paste -sd' ' -)" = "badges.0.title badges.1.query badges.2.valueExpr badges.3.colorExpr badges.4.icon" ]
  cat >"$BATS_TEST_TMPDIR/undotted.yaml" <<'EOF'
badges:
  - id: a
    title: v1.2.3
    query: round(avg(up) * 100, 0.1)
    valueExpr: labels[?"git_version"].orValue("unknown")
EOF
  [ -z "$(hostnames "$BATS_TEST_TMPDIR/undotted.yaml")" ]
  # The checks above would let these through, so they are here as the checks' own proof: a result
  # that carries a node, a pod or an address label is found, as is one that selects by them.
  [ -n "$(leaks 'kube_node_info')" ]
  [ -n "$(leaks 'max by (node) (kube_node_info)')" ]
  [ -n "$(leaks 'max by (instance, git_version) (kubernetes_build_info)')" ]
  [ -n "$(leaks 'count(kube_node_info) or kube_node_info')" ]
  [ -n "$(leaks 'count(kube_node_info{node="a"})')" ]
  # A label name may be quoted, as Prometheus 3 allows, in any of PromQL's quotes.
  [ -n "$(leaks 'count(kube_node_info{"node"="a"})')" ]
  [ -n "$(leaks 'count(kube_node_info{job="a", '\''node'\''="a"})')" ]
  # shellcheck disable=SC2016 # The backticks are a PromQL quote, not a command.
  [ -n "$(leaks 'count(kube_node_info{`node`=~"a"})')" ]
  [ -n "$(leaks 'count(kube_node_info) by (node)')" ]
  [ -n "$(leaks 'sum without (pod) (kube_pod_status_phase)')" ]
  # shellcheck disable=SC2016 # `$1` is PromQL's, not a variable to expand.
  [ -n "$(leaks 'count(label_replace(kube_node_info, "x", "$1", "node", "(.*)"))')" ]
  [ -z "$(leaks 'max by (git_version) (kubernetes_build_info{job="apiserver"})')" ]
  [ -z "$(leaks 'max by (git_version) (kubernetes_build_info{"job"="apiserver"})')" ]
  [ -z "$(leaks 'round((time() - min(kube_node_created)) / 86400)')" ]
}

@test "kromgo is reached by its hostname on the public Gateway and holds no credential" {
  local domain route service port kind
  domain="$(yq -e '.CLUSTER_DOMAIN' "$EXAMPLE")"
  render
  route="$(only "$BUILT" HTTPRoute)"
  object "$BUILT" HTTPRoute "$route" >"$BATS_TEST_TMPDIR/route.yaml"
  echo "route $route: $(yq -o json -I0 '.spec' "$BATS_TEST_TMPDIR/route.yaml")"
  # Under the cluster's domain, on the https listener of the public Gateway alone, for the badge
  # paths alone, backed by the main port of kromgo's Service.
  [ "$(yq '.spec.hostnames | join(",")' "$BATS_TEST_TMPDIR/route.yaml")" = "kromgo.$domain" ]
  [ "$(yq -o json -I0 '.spec.parentRefs' "$BATS_TEST_TMPDIR/route.yaml")" = '[{"name":"public","namespace":"envoy-gateway-system","sectionName":"https"}]' ]
  [ "$(yq -o json -I0 '.spec.rules[].matches' "$BATS_TEST_TMPDIR/route.yaml")" = '[{"path":{"type":"PathPrefix","value":"/badges/"}}]' ]
  [ "$(yq '.spec.rules | length' "$BATS_TEST_TMPDIR/route.yaml")" -eq 1 ]
  [ "$(yq '.spec.rules[0].backendRefs | length' "$BATS_TEST_TMPDIR/route.yaml")" -eq 1 ]
  # The rule passes a request on as it came: it has no filter, nor has its backend, so no rewrite
  # puts kromgo's index page or health endpoints under /badges/ and no redirect or header is added.
  [ "$(yq -o json -I0 '.spec.rules[0] | keys | sort' "$BATS_TEST_TMPDIR/route.yaml")" = '["backendRefs","matches"]' ]
  [ "$(yq -o json -I0 '.spec.rules[0].backendRefs[0] | keys | sort' "$BATS_TEST_TMPDIR/route.yaml")" = '["name","port"]' ]
  service="$(yq '.spec.rules[0].backendRefs[0].name' "$BATS_TEST_TMPDIR/route.yaml")"
  port="$(yq '.spec.rules[0].backendRefs[0].port' "$BATS_TEST_TMPDIR/route.yaml")"
  object "$RENDERED" Service "$service" >"$BATS_TEST_TMPDIR/service.yaml"
  [ "$(yq '.spec.ports[] | select(.port == '"$port"') | .name' "$BATS_TEST_TMPDIR/service.yaml")" = http ]
  # The port is the one the container serves its badges on, and its metrics are on another.
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "KROMGO_SERVER_PORT") | .value' "$RENDERED")" = "$port" ]
  [ "$(yq '.spec.ports[] | select(.port == '"$port"') | .targetPort' "$BATS_TEST_TMPDIR/service.yaml")" = "$port" ]
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "KROMGO_METRICS_PORT") | .value' "$RENDERED")" != "$port" ]
  # The hostname comes from the variable: built with another domain it follows it.
  other_vars
  VARS="$OTHER" built
  [ "$(object "$BUILT" HTTPRoute "$route" | yq '.spec.hostnames | join(",")')" = "kromgo.$(yq -e '.CLUSTER_DOMAIN' "$OTHER")" ]
  built
  # The route is in a namespace that carries the label the Gateway's https listener selects, and
  # that is a namespace of kromgo's own.
  overlay
  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "kromgo") | .metadata.labels["k8s-gitops/gateway"]' "$OVERLAY")" = public ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "kromgo") | .spec.targetNamespace' "$OVERLAY")" = kromgo ]
  # The Gateway that application makes is the one the route names.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "kromgo") | .spec.dependsOn[].name' "$OVERLAY" | grep -cx gateway-public)" -eq 1 ]
  # No credential: nothing it builds or renders is a Secret or an ExternalSecret, no variable is
  # given by a reference to one or is named for one, Prometheus's URL has no user, and the pod
  # mounts no token of the service account.
  while IFS= read -r kind; do
    echo "kind: $kind"
    [[ $kind != Secret && $kind != ExternalSecret && $kind != ClusterExternalSecret && $kind != SecretStore && $kind != ClusterSecretStore && $kind != PushSecret ]]
  done < <(yq -N '.kind' "$BUILT" "$RENDERED" | sort -u)
  [ -z "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[].env[] | select(has("valueFrom")) | .name' "$RENDERED")" ]
  [ -z "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[].env[].name' "$RENDERED" | grep -Ei 'pass|token|secret|key|credential|auth' || true)" ]
  [ -z "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[].envFrom // []' "$RENDERED" | grep -v '^\[\]$' | grep . || true)" ]
  [[ $(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "KROMGO_PROMETHEUS_URL") | .value' "$RENDERED") != *@* ]]
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.automountServiceAccountToken' "$RENDERED")" = false ]
  [ -z "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(has("secret") or has("projected")) | .name' "$RENDERED")" ]
  [ -z "$(find "$REPO/kubernetes/apps/base/kromgo" \( -name '*.enc.*' -o -name '*.sops.*' -o -name '*.age*' \))" ]
}

@test "kromgo runs restricted from a pinned image and is scraped" {
  local pod container labels monitor service tag
  render
  overlay
  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "kromgo") | .metadata.labels["pod-security.kubernetes.io/enforce"]' "$OVERLAY")" = restricted ]
  pod="$BATS_TEST_TMPDIR/pod.yaml"
  container="$BATS_TEST_TMPDIR/container.yaml"
  object "$RENDERED" Deployment "$(only "$RENDERED" Deployment)" | yq '.spec.template.spec' >"$pod"
  yq '.containers | length' "$pod" | grep -qx 1
  yq '.containers[0]' "$pod" >"$container"
  # Two pods that a drain or a node's loss cannot take together: spread over the hostnames, and a
  # budget that keeps one running.
  [ "$(object "$RENDERED" Deployment "$(only "$RENDERED" Deployment)" | yq '.spec.replicas')" -eq 2 ]
  [ "$(yq '.topologySpreadConstraints | map(select(.topologyKey == "kubernetes.io/hostname" and .whenUnsatisfiable == "DoNotSchedule" and .maxSkew == 1)) | length' "$pod")" -eq 1 ]
  labels="$(object "$RENDERED" Deployment "$(only "$RENDERED" Deployment)" | yq -o json -I0 '.spec.template.metadata.labels')"
  jq -e --argjson labels "$labels" 'to_entries | length > 0 and all(. as $e | $labels[$e.key] == $e.value)' \
    <<<"$(yq -o json -I0 '.topologySpreadConstraints[0].labelSelector.matchLabels' "$pod")"
  [ "$(yq -N 'select(.kind == "PodDisruptionBudget") | .spec.minAvailable' "$RENDERED")" -eq 1 ]
  jq -e --argjson labels "$labels" 'to_entries | length > 0 and all(. as $e | $labels[$e.key] == $e.value)' \
    <<<"$(yq -N -o json -I0 'select(.kind == "PodDisruptionBudget") | .spec.selector.matchLabels' "$RENDERED")"
  # The image is the publisher's, by tag and digest, so Renovate moves both.
  [[ $(yq '.image' "$container") =~ ^ghcr\.io/home-operations/kromgo:([0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$ ]]
  tag="${BASH_REMATCH[1]}"
  # That version takes the configuration: kromgo decodes it with unknown fields refused and needs an
  # id and a query of each badge (Load in internal/config/config.go), which the schema it publishes
  # at the tag says, and an id of the form validID there. The file names that schema, so an editor
  # checks it against the same one. kromgo also compiles each CEL expression at start (New in
  # internal/kromgo/handler.go), which no schema says: a pod that refuses one never becomes ready,
  # and the application waits for its pods, so it is not Ready either.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "kromgo") | .spec.wait' "$OVERLAY")" = true ]
  config
  config_chart "$tag"
  grep -qF "kromgo/$tag/config.schema.json" "$REPO/kubernetes/apps/base/kromgo/kromgo/app/config.yaml"
  run helm template config "$CONFIG_CHART" --values "$CONFIG"
  echo "the configuration against kromgo $tag's schema: $output"
  [ "$status" -eq 0 ]
  [ -z "$(yq -N '.badges[].id' "$CONFIG" | grep -Ev '^[A-Za-z0-9._-]+$' || true)" ]
  # The check's own proof: a field kromgo does not know, and a badge without its query, are refused.
  yq '.badges[0].labelColour = "red"' "$CONFIG" >"$BATS_TEST_TMPDIR/unknown-field.yaml"
  run helm template config "$CONFIG_CHART" --values "$BATS_TEST_TMPDIR/unknown-field.yaml"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"additional properties 'labelColour' not allowed"* ]]
  yq 'del(.badges[0].query)' "$CONFIG" >"$BATS_TEST_TMPDIR/no-query.yaml"
  run helm template config "$CONFIG_CHART" --values "$BATS_TEST_TMPDIR/no-query.yaml"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"missing property 'query'"* ]]
  # What the restricted level asks of the pod and the container, a root filesystem nothing can
  # write to, and what the scheduler and the kernel need to hold it to its size.
  [ "$(yq '.securityContext.runAsNonRoot' "$pod")" = true ]
  [ "$(yq '.securityContext.runAsUser // 0' "$pod")" -ne 0 ]
  [ "$(yq '.securityContext.seccompProfile.type' "$pod")" = RuntimeDefault ]
  [ "$(yq '.securityContext.runAsUser' "$pod")" -eq "$(yq '.securityContext.runAsGroup' "$pod")" ]
  [ "$(yq '.securityContext.allowPrivilegeEscalation' "$container")" = false ]
  [ "$(yq '.securityContext.readOnlyRootFilesystem' "$container")" = true ]
  [ "$(yq '.securityContext.capabilities.drop | join(",")' "$container")" = ALL ]
  [ "$(yq '.securityContext.privileged // false' "$container")" = false ]
  [ -n "$(yq '.resources.requests.cpu // ""' "$container")" ]
  [ -n "$(yq '.resources.requests.memory // ""' "$container")" ]
  [ -n "$(yq '.resources.limits.memory // ""' "$container")" ]
  # Its health check is its own endpoint, on the port it serves badges on, and nothing writes to
  # the container: its one volume is the configuration, read only.
  [ "$(yq '.livenessProbe.httpGet.path' "$container")" = /healthz ]
  [ "$(yq '.readinessProbe.httpGet.path' "$container")" = /readyz ]
  [ "$(yq '.livenessProbe.httpGet.port' "$container")" = "$(yq '.env[] | select(.name == "KROMGO_SERVER_PORT") | .value' "$container")" ]
  [ "$(yq '.readinessProbe.httpGet.port' "$container")" = "$(yq '.livenessProbe.httpGet.port' "$container")" ]
  [ "$(yq '.volumeMounts | length' "$container")" -eq 1 ]
  [ "$(yq '.volumeMounts[0].mountPath' "$container")" = /config ]
  [ "$(yq '.volumeMounts[0].readOnly' "$container")" = true ]
  [ "$(yq '.volumes | length' "$pod")" -eq 1 ]
  [ "$(yq '.volumes[0] | has("configMap")' "$pod")" = true ]
  # It serves its metrics on a port of its own, which the one monitor scrapes through the Service
  # that holds it, and which no route names.
  monitor="$(only "$RENDERED" ServiceMonitor)"
  service="$(only "$RENDERED" Service)"
  object "$RENDERED" ServiceMonitor "$monitor" >"$BATS_TEST_TMPDIR/monitor.yaml"
  [ "$(yq '.spec.endpoints | length' "$BATS_TEST_TMPDIR/monitor.yaml")" -eq 1 ]
  [ "$(yq '.spec.endpoints[0].port' "$BATS_TEST_TMPDIR/monitor.yaml")" = metrics ]
  [ "$(yq '.spec.endpoints[0].path' "$BATS_TEST_TMPDIR/monitor.yaml")" = /metrics ]
  [ -n "$(S="$service" yq -N 'select(.kind == "Service" and .metadata.name == strenv(S)) | .spec.ports[] | select(.name == "metrics") | .port' "$RENDERED")" ]
  jq -e --argjson labels "$(object "$RENDERED" Service "$service" | yq -o json -I0 '.metadata.labels')" \
    'to_entries | length > 0 and all(. as $e | $labels[$e.key] == $e.value)' \
    <<<"$(yq -o json -I0 '.spec.selector.matchLabels' "$BATS_TEST_TMPDIR/monitor.yaml")"
}
