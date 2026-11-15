#!/usr/bin/env bats
# Proves features/silences.feature; each test carries its scenario's title.
# Needs helm, flux, kustomize, yq and jq on PATH (the versions pinned for the repository). Each
# chart is pulled once per run from its public registry, the charts of the whole tree included, which
# the silence rules read through scripts/render; building and rendering are offline.

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
  # scripts/render pulls each chart of the tree once for the file, here, and every render of a copy
  # of the tree reads it from there.
  export RENDER_CHART_CACHE="$BATS_FILE_TMPDIR/render-charts"
  mkdir -p "$RENDER_CHART_CACHE"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLUSTER="$REPO/kubernetes/clusters/lab-sto2"
  KUBE="$(yq -e '.kubernetes' "$REPO/versions.yaml")"
  NAMESPACE=monitoring
  APP=silence-operator
  OVERLAY_ENTRY="monitoring/$APP/ks.yaml"
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
  # Built from the tree's root, with paths from there, as scripts/kubernetes-check builds.
  (cd "$REPO" && flux build kustomization "$app" --path "./kubernetes/apps/base/$NAMESPACE/$app/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute --in-memory-build) >"$BUILT"
}

# render APP: renders the chart that APP's HelmRelease installs, built as built() builds it, from
# the URL and tag of its OCIRepository, with the values helm-controller gives the chart: those of
# the ConfigMap the HelmRelease reads, then the HelmRelease's own over them. The chart's resource
# definitions are included, and the monitoring API counts as present, as prometheus-operator-crds
# installs it before these applications start. Writes $BATS_TEST_TMPDIR/APP.yaml and sets RENDERED,
# CHART, RELEASE, VALUES and INLINE, besides what built() sets.
render() {
  local app=$1 url tag name namespace pulled
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
    --values "$VALUES" --values "$INLINE" >"$RENDERED"
}

# overlay_build: the cluster's overlay as kustomize builds it, which holds each application's Flux
# Kustomization as the cluster applies it.
overlay_build() {
  kustomize build --load-restrictor LoadRestrictionsNone "$REPO/kubernetes/apps/overlays/lab-sto2"
}

# depends BUILD APP: the names APP's Kustomization lists in dependsOn in the overlay build BUILD, one
# per line.
depends() {
  APP_NAME=$2 yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(APP_NAME)) | .spec.dependsOn // [] | .[].name' <<<"$1"
}

# deployment: the one Deployment of $RENDERED, as JSON on one line; fails unless there is one.
deployment() {
  local found
  found="$(yq -N -o json -I0 'select(.kind == "Deployment")' "$RENDERED")"
  [ "$(grep -c . <<<"$found")" -eq 1 ] || { echo "Deployments rendered: $(grep -c . <<<"$found")" >&2; return 1; }
  echo "$found"
}

# silence_problems: reads Silence objects as JSON, one per line, on standard input and prints a line
# for each rule one of them breaks, "namespace/name: what is wrong"; prints nothing when all hold.
#
# The rules: the namespaced API (a cluster-scoped Silence belongs to no application); a reason; an
# end date, or an issue that tracks it, so no silence stays for good unnoticed; at least one matcher
# that names an alert by `alertname` with `=` and a value, and no alertname matcher of another kind,
# so the alert is named in a matcher that is not wider than one alert, and a silence never matches
# everything; and no matcher for the Watchdog, which is meant to fire.
silence_problems() {
  jq -r '
    select(.kind == "Silence")
    | ((.metadata.namespace // "cluster") + "/" + .metadata.name) as $id
    | (.metadata.annotations // {}) as $notes
    | [(.spec.matchers // [])[] | select(.name == "alertname")] as $alertname
    | [$alertname[] | select((.matchType // "=") == "=")] as $exact
    | [
        (if .apiVersion != "observability.giantswarm.io/v1alpha2"
          then "is not an observability.giantswarm.io/v1alpha2 Silence, the namespaced API" else empty end),
        (if ($notes["k8s-gitops/reason"] // "" | test("\\S") | not)
          then "has no reason in the annotation k8s-gitops/reason" else empty end),
        (if ((.spec.endsAt // "") == "")
            and (($notes["k8s-gitops/issue"] // "") | test("^[A-Z][A-Z0-9]*-[0-9]+$") | not)
          then "has neither spec.endsAt nor an issue key in the annotation k8s-gitops/issue" else empty end),
        (if ($exact | length) == 0
          then "has no alertname matcher with =" else empty end),
        (if ($alertname | any((.matchType // "=") != "="))
          then "has an alertname matcher other than =, which can match more than one alert" else empty end),
        (if ($exact | any((.value // "") == ""))
          then "has an alertname matcher with an empty value" else empty end),
        (if ($exact | any(.value == "Watchdog"))
          then "silences the Watchdog, which is meant to fire" else empty end)
      ]
    | .[] | $id + ": " + .
  ' 2>&1
}

# fixture_problems EXPRESSION: silence_problems of the fixture valid.yaml with the yq EXPRESSION
# applied to it.
fixture_problems() {
  yq -N -o json -I0 "$1" "$BATS_TEST_DIRNAME/fixtures/silences/valid.yaml" | silence_problems
}

# tree_problems ROOT: reads the Silence objects of the render of the tree ROOT (its kubernetes/ and
# versions.yaml) and of the app/ of each application under its apps/base, and sets PROBLEMS to what
# is wrong with them and with the render, one line each, APPS to the number of application
# directories built, APPLIED to the number of applications rendered and SILENCES to the number of
# Silence objects read.
#
# The render is what scripts/render writes, the render pod-security-check and kubernetes-validate
# read: the root, Flux's own applications and each Kustomization they apply whose source is the
# cluster's artifact, each built by flux build with the components it adds, and every object each
# HelmRelease of those builds renders from its chart, with the values of the ConfigMaps Flux builds
# for its own application. A Kustomization whose source is a GitRepository, a Bucket or an
# OCIRepository other than the cluster's flux-system is not followed, and no object a controller
# makes from another at run time is in the render. Each Silence read is held to the rules, and one
# of the render is refused unless it is a resource of the app/ of the application under apps/base
# that applies it: one that a chart renders, that a component adds, or that the cluster directory,
# the overlay, a namespace's directory or an application outside apps/base applies, is not. The app/
# of every application under apps/base is built with kustomize, whether the overlay enables it or
# not, so a Silence there meets the rules before an overlay applies it.
#
# Three constructions the render does not expand as the cluster would are refused outright, so that
# no Silence goes unread in them: a List with items, whose items Flux applies as objects of their
# own; a valuesFrom entry of a HelmRelease that is optional or names no object Flux builds for its
# application, whose values the render leaves out; and a Flux Kustomization, HelmRelease or source
# that a chart renders, which the render does not follow. This catches a Silence added by mistake or
# carelessly; a change that hides one on purpose is for the pull request's review to catch.
tree_problems() {
  local root=$1 dir built silences render where object line
  local own="$BATS_TEST_TMPDIR/own.json" objects="$BATS_TEST_TMPDIR/rendered.json"
  : >"$own"
  APPS=0 SILENCES=0 PROBLEMS=""
  for dir in "$root"/kubernetes/apps/base/*/*/app; do
    built="$(kustomize build --load-restrictor LoadRestrictionsNone "$dir")" || { echo "$dir does not build"; return 1; }
    silences="$(yq -N -o json -I0 'select(.kind == "Silence")' <<<"$built")"
    APPS=$((APPS + 1))
    [ -n "$silences" ] || continue
    SILENCES=$((SILENCES + $(grep -c . <<<"$silences")))
    while IFS= read -r line; do
      PROBLEMS+="${dir#"$root"/}: $line"$'\n'
    done < <(silence_problems <<<"$silences")
    jq -c --arg path "./${dir#"$root"/kubernetes/}" \
      '{path: $path, apiVersion, name: .metadata.name, namespace: (.metadata.namespace // "")}' <<<"$silences" >>"$own"
  done

  render="$(mktemp -d "$BATS_TEST_TMPDIR/render.XXXXXX")"
  "$REPO/scripts/render" "$render" "$root" >"$render.log" 2>&1 || { cat "$render.log"; return 1; }
  APPLIED="$(find "$render" -mindepth 2 -maxdepth 2 -type d | grep -c .)" || true
  # Every object of the render, by the kind the object has, whatever its file is called, with the
  # file, which is OUT/<cluster>/<application>/<object>.yaml: whole for a Silence, a kind that ends
  # in List and a Flux Kustomization, HelmRelease or source, and by its API version, kind, name,
  # namespace and labels otherwise.
  find "$render" -mindepth 3 -maxdepth 3 -type f -name '*.yaml' -print0 | sort -z |
    xargs -0 yq -N -o json -I0 '{"file": filename, "object": (
      if .kind == "Silence" or ((.kind // "") | test("List$"))
        or ((.apiVersion // "") | test("^(kustomize|helm|source)\.toolkit\.fluxcd\.io/|^source\.extensions\.fluxcd\.io/"))
      then . else {"apiVersion": .apiVersion, "kind": .kind,
        "metadata": {"name": .metadata.name, "namespace": .metadata.namespace, "labels": .metadata.labels}} end)}' >"$objects" ||
    { echo "the render in $render cannot be read"; return 1; }
  # jq runs once over every object, so an error stops the test.
  silences="$(jq -rn --arg render "$render/" 'inputs | select(.object.kind == "Silence")
    | (.file | ltrimstr($render) | split("/") | .[0] + "/" + .[1]) + "\t" + (.object | tojson)' "$objects")"
  while IFS=$'\t' read -r where object; do
    [ -n "$where" ] || continue
    SILENCES=$((SILENCES + 1))
    while IFS= read -r line; do
      PROBLEMS+="$where: $line"$'\n'
    done < <(silence_problems <<<"$object")
  done <<<"$silences"
  # Where each Silence of the render comes from: the application that applies it is the Flux
  # Kustomization of that name in the cluster, whose spec.path is the directory built.
  PROBLEMS+="$(jq -r -n --arg render "$render/" --slurpfile own "$own" '
    [inputs | .at = (.file | ltrimstr($render) | split("/"))] as $all
    | [$all[] | select(.object.kind == "Kustomization" and ((.object.apiVersion // "") | startswith("kustomize.toolkit.fluxcd.io/")))] as $ks
    | $all[] | select(.object.kind == "Silence") | .object as $s | .at as $at
    | (first($ks[] | select(.at[0] == $at[0] and .object.metadata.name == $at[1]) | .object.spec) // {}) as $app
    | ($app.path // "" | sub("/$"; "")) as $path
    | ($s.metadata.labels // {}) as $labels
    | "\($at[0])/\($at[1]): \($s.metadata.namespace // "")/\($s.metadata.name): is not a resource of an application\u0027s app/" as $refused
    | if $labels["helm.toolkit.fluxcd.io/name"] != null
      then "\($refused): the chart of HelmRelease \($labels["helm.toolkit.fluxcd.io/namespace"])/\($labels["helm.toolkit.fluxcd.io/name"]) renders it"
      elif ($path | test("^\\./apps/base/[^/]+/[^/]+/app$") | not)
      then "\($refused): \($at[0])/\($at[1]) applies it from \(if $path == "" then "the cluster directory" else $path end)"
      elif any($own[]; .path == $path and .apiVersion == $s.apiVersion and .name == $s.metadata.name
        and ($app.targetNamespace // .namespace) == ($s.metadata.namespace // ""))
      then empty
      else "\($refused): kustomize builds no such Silence from \($path)" end' "$objects")"
  # What the render does not expand as the cluster would. A List with items: kustomize, through
  # which Flux builds each Kustomization and helm-controller labels each chart's objects, reads each
  # item as an object of its own. A valuesFrom entry: scripts/render reads values only from a
  # ConfigMap that Flux builds for the HelmRelease's own application, and leaves out an optional one
  # it does not find there. A Flux object that a chart renders, which carries the render's
  # helm.toolkit.fluxcd.io/name label: scripts/render follows Kustomizations and HelmReleases only
  # from Flux's builds.
  PROBLEMS+=$'\n'"$(jq -r -n --arg render "$render/" '
    def id: "\(.metadata.namespace // "")/\(.metadata.name // "")";
    [inputs | .at = (.file | ltrimstr($render) | split("/") | .[0] + "/" + .[1])] as $all
    | $all[] | .at as $at | .object as $o
    | (if ($o.kind // "" | endswith("List")) and ($o | has("items"))
        then "\($at): \($o | id): is a \($o.kind) with items, which Flux applies as objects of their own and the render holds as one"
        else empty end),
      (if ($o.metadata.labels // {} | has("helm.toolkit.fluxcd.io/name"))
          and ($o.apiVersion // "" | test("^(kustomize|helm|source)\\.toolkit\\.fluxcd\\.io/|^source\\.extensions\\.fluxcd\\.io/"))
        then "\($at): \($o | id): is a \($o.kind) the chart of HelmRelease \($o.metadata.labels["helm.toolkit.fluxcd.io/namespace"])/\($o.metadata.labels["helm.toolkit.fluxcd.io/name"]) renders, which the render does not follow"
        else empty end),
      (select($o.kind == "HelmRelease" and ($o.apiVersion // "" | startswith("helm.toolkit.fluxcd.io/")))
        | ($o.metadata.namespace // "default") as $ns
        | ($o.spec.valuesFrom // [])[] as $from
        | "\($at): \($ns)/\($from.name // ""): " as $named
        | (if $from.optional == true
            then "\($named)is optional in the valuesFrom of HelmRelease \($o | id), which the render leaves out when the application does not hold it"
            else empty end),
          (if any($all[]; .at == $at and .object.kind == $from.kind and .object.metadata.name == $from.name
              and (.object.metadata.namespace // "default") == $ns and .object.metadata.labels["helm.toolkit.fluxcd.io/name"] == null)
            then empty
            else "\($named)is in the valuesFrom of HelmRelease \($o | id) and not a \($from.kind // "kind") that Flux builds for its application, the only place the render reads values from" end))' "$objects")"
  PROBLEMS="$(grep . <<<"$PROBLEMS" || true)"
}

# located_problems: reads lines NAME#FILE#EXPECTED on standard input and runs tree_problems, which
# sets PROBLEMS, on one copy of the tree in which each FILE holds a Silence named NAME: one that
# breaks every rule it can, or, where EXPECTED is empty, the fixture that meets them all. It is a
# file that the kustomization beside it lists, whatever its extension, or, for a chart's
# values.yaml, an entry of the chart's extraManifests, which kube-prometheus-stack renders as
# objects of its release. A FILE that starts with one of these forms carries the Silence otherwise:
#   list:VALUES       in a List named NAME, an entry of the chart's extraManifests;
#   values-from:FILE  in the extraManifests of the values that a ConfigMap named NAME holds, the
#                     file FILE that the kustomization beside it lists, which kube-prometheus-stack's
#                     HelmRelease reads in its valuesFrom, optional;
#   flux:FILE         in FILE, which no kustomization lists, whose directory a Flux Kustomization
#                     named NAME applies from the cluster's artifact, an entry of
#                     kube-prometheus-stack's extraManifests.
located_problems() {
  local tree="$BATS_TEST_TMPDIR/located" name file expected object breaks
  local chart=kubernetes/apps/base/monitoring/kube-prometheus-stack/app
  rm -rf "$tree"
  mkdir -p "$tree"
  cp -R "$REPO/kubernetes" "$REPO/versions.yaml" "$tree/"
  while IFS='#' read -r name file expected; do
    breaks='del(.metadata.annotations) | del(.spec.endsAt) | .spec.matchers[0].matchType = "=~" | .spec.matchers[0].value = ".*"'
    [ -n "$expected" ] || breaks='.'
    object="$(NAME=$name yq -N -o json -I0 ".metadata.name = strenv(NAME) | $breaks" \
      "$BATS_TEST_DIRNAME/fixtures/silences/valid.yaml")"
    case $file in
      list:*)
        SILENCE="$object" NAME=$name yq -i '.extraManifests += [{"apiVersion": "v1", "kind": "List",
          "metadata": {"name": strenv(NAME)}, "items": [env(SILENCE)]}]' "$tree/${file#list:}"
        ;;
      values-from:*)
        file=${file#values-from:}
        SILENCE="$object" NAME=$name yq -n '{"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": strenv(NAME)},
          "data": {"values.yaml": ({"extraManifests": [env(SILENCE)]} | to_yaml)}}' >"$tree/$file"
        FILE="${file##*/}" yq -i '.resources += [strenv(FILE)]' "$(dirname "$tree/$file")/kustomization.yaml"
        NAME=$name yq -i '.spec.valuesFrom += [{"kind": "ConfigMap", "name": strenv(NAME), "optional": true}]' \
          "$tree/$chart/helmrelease.yaml"
        ;;
      flux:*)
        file=${file#flux:}
        mkdir -p "$(dirname "$tree/$file")"
        yq -N -p json -o yaml '.' <<<"$object" >"$tree/$file"
        NAME=$name DIR="./$(dirname "${file#kubernetes/}")" yq -i '.extraManifests += [{
          "apiVersion": "kustomize.toolkit.fluxcd.io/v1", "kind": "Kustomization",
          "metadata": {"name": strenv(NAME), "namespace": "flux-system"},
          "spec": {"interval": "1h", "path": strenv(DIR), "prune": true,
            "sourceRef": {"kind": "OCIRepository", "name": "flux-system"}}}]' "$tree/$chart/values.yaml"
        ;;
      */values.yaml)
        SILENCE="$object" yq -i '.extraManifests += [env(SILENCE)]' "$tree/$file"
        ;;
      *)
        yq -N -p json -o yaml '.' <<<"$object" >"$tree/$file"
        FILE="${file##*/}" yq -i '.resources += [strenv(FILE)]' "$(dirname "$tree/$file")/kustomization.yaml"
        ;;
    esac
  done
  tree_problems "$tree"
}

# args_problems: reads the operator's Deployment as JSON on standard input and prints what is wrong
# with the arguments that say where Alertmanager is and whether the operator authenticates to it.
# The operator reads its arguments with Go's flag package, which takes one dash or two, a bare
# boolean as true, any spelling of a boolean and the last of a flag given twice, so the chart's
# arguments for both must be the only ones that name Alertmanager at all: an extra one, in any
# spelling, is refused rather than interpreted.
args_problems() {
  jq -r '
    def flag: if startswith("-") then sub("^--?"; "") | split("=")[0] | ascii_downcase else empty end;
    .spec.template.spec.containers[0].args as $args
    | [$args[] | select(flag == "alertmanager-address")] as $address
    | [$args[] | select(flag == "alertmanager-authentication")] as $auth
    | [$args[] | select(flag | contains("alertmanager"))
        | select(flag != "alertmanager-address" and flag != "alertmanager-authentication")] as $other
    | "http://([a-z0-9]([-a-z0-9]*[a-z0-9])?)\\.([a-z0-9]([-a-z0-9]*[a-z0-9])?)\\.svc\\.cluster\\.local:[0-9]+" as $service
    | (if ($address | length) != 1 then "gives the Alertmanager address in \($address | length) arguments, not one"
        elif ($address[0] | test("^--alertmanager-address=" + $service + "$") | not)
        then "gives an Alertmanager address that is not the name of a Service inside the cluster: \($address[0])"
        else empty end),
      (if $auth != ["--alertmanager-authentication=false"]
        then "does not turn authentication to Alertmanager off with exactly one --alertmanager-authentication=false" else empty end),
      (if ($other | length) > 0 then "has an argument that names Alertmanager besides its address and authentication: \($other[0])" else empty end)'
}

# address_problems ADDRESS: prints what is wrong with ADDRESS as the address of the cluster's
# Alertmanager, read against the monitoring chart's render in $RENDERED: it must be
# http://<service>.<namespace>.svc.cluster.local:<port>, with no address literal that a rebuilt
# cluster would give to something else, of one Service the chart renders by that name and namespace,
# whose selector picks the pods of an Alertmanager the chart renders in that namespace and names it,
# and whose port by that number leads to that Alertmanager's web port. prometheus-operator gives
# those pods the Alertmanager's spec.podMetadata.labels and, over them, app.kubernetes.io/name:
# alertmanager, app.kubernetes.io/managed-by: prometheus-operator, and app.kubernetes.io/instance
# and alertmanager, each the Alertmanager's name (pkg/alertmanager/operator.go, makeSelectorLabels):
# a selector that is empty or names a label those pods do not carry picks other pods, or none of
# them, and one that names no Alertmanager, by alertmanager or by app.kubernetes.io/name and
# app.kubernetes.io/instance, picks as well the pods of any other that carry its labels, such as
# Prometheus' with app.kubernetes.io/managed-by alone. Alertmanager serves its interface and API on
# 9093, a port of its pod named after spec.portName, web by default; the Service's other ports lead
# to other containers.
address_problems() {
  local address=$1
  if [[ ! $address =~ ^http://([a-z0-9]([-a-z0-9]*[a-z0-9])?)\.([a-z0-9]([-a-z0-9]*[a-z0-9])?)\.svc\.cluster\.local:([0-9]+)$ ]]; then
    echo "$address is not the name of a Service inside the cluster"
    return
  fi
  yq -N -o json -I0 'select(.kind == "Service" or .kind == "Alertmanager")' "$RENDERED" |
    NAME=${BASH_REMATCH[1]} NAMESPACE=${BASH_REMATCH[3]} PORT=${BASH_REMATCH[5]} jq -rs '
      [.[] | select(.kind == "Service" and .metadata.name == env.NAME and (.metadata.namespace // "") == env.NAMESPACE)] as $services
      | if ($services | length) != 1 then "the monitoring chart renders \($services | length) Services \(env.NAMESPACE)/\(env.NAME), not one"
        else [$services[0].spec.ports[]? | select((.port | tostring) == env.PORT)] as $ports
          | ($services[0].spec.selector // {}) as $selector
          | [.[] | select(.kind == "Alertmanager" and (.metadata.namespace // "") == env.NAMESPACE)
              | {name: .metadata.name, web: (.spec.portName // "web"),
                 labels: ((.spec.podMetadata.labels // {}) + {"app.kubernetes.io/name": "alertmanager",
                   "app.kubernetes.io/managed-by": "prometheus-operator",
                   "app.kubernetes.io/instance": .metadata.name, "alertmanager": .metadata.name})}
              | select(.labels as $labels | ($selector | length) > 0 and ($selector | to_entries | all($labels[.key] == .value)))] as $picked
          | [$picked[] | select($selector.alertmanager == .name
              or ($selector["app.kubernetes.io/name"] == "alertmanager" and $selector["app.kubernetes.io/instance"] == .name))] as $named
          | if ($ports | length) == 0 then "the Service \(env.NAMESPACE)/\(env.NAME) has no port \(env.PORT)"
            elif ($picked | length) == 0
            then "the Service \(env.NAMESPACE)/\(env.NAME) selects no Alertmanager\u0027s pods: \($selector | tojson)"
            elif ($named | length) == 0
            then "the Service \(env.NAMESPACE)/\(env.NAME) names no Alertmanager in its selector, by alertmanager or by app.kubernetes.io/name alertmanager and app.kubernetes.io/instance: \($selector | tojson)"
            elif any($ports[]; (.targetPort // .port) as $target | any($named[]; $target == 9093 or $target == .web)) | not
            then "the Service \(env.NAMESPACE)/\(env.NAME) sends port \(env.PORT) to \($ports[0].targetPort // $ports[0].port), not to Alertmanager\u0027s web port, 9093 or \($named[0].web)"
            else empty end
        end'
}

# rights_problems: reads the operator's roles and bindings as JSON, one object per line, on standard
# input and prints what is wrong with them: each right and binding of the release, with its API
# groups, resources, resource names, non-resource URLs and verbs, and each role's aggregation, must
# be one of these and each of these must be there. A field a rule leaves out is an empty list, and
# input jq cannot read is a problem of its own, so no right goes unread: jq runs once over every
# object, as it exits with the status of its last input alone. The chart gives every verb on
# Silence objects and on Leases, in every namespace, through one ClusterRole bound to its own
# service account.
rights_problems() {
  local seen expected line
  expected="$(rights_expected)"
  seen="$(jq -rn '
    def names: map(if . == "" then "core" else . end) | join(",");
    inputs | select(.kind == "ClusterRole" or .kind == "Role" or .kind == "ClusterRoleBinding" or .kind == "RoleBinding")
    | if (.kind | endswith("Binding"))
      then "\(.kind) \(.metadata.name): \(.roleRef.kind)/\(.roleRef.name) -> \([(.subjects // [])[] | "\(.kind)/\(.namespace // "")/\(.name)"] | sort | join(" "))"
      else . as $role
        | ((.rules // [])[] | "\($role.kind) \($role.metadata.name): groups=\(.apiGroups // [] | names) resources=\(.resources // [] | names) names=\(.resourceNames // [] | join(",")) urls=\(.nonResourceURLs // [] | join(",")) verbs=\(.verbs // [] | names)"),
          (if .aggregationRule != null then "\($role.kind) \($role.metadata.name): aggregates \(.aggregationRule | tojson)" else empty end)
      end' 2>&1)" || {
    echo "the roles cannot be read: $seen"
    return
  }
  while read -r line; do
    grep -qxF -- "$line" <<<"$seen" || echo "missing: $line"
  done <<<"$expected"
  while read -r line; do
    [ -z "$line" ] || grep -qxF -- "$line" <<<"$expected" || echo "unexpected: $line"
  done <<<"$seen"
}

# rights_expected: the lines rights_problems accepts.
rights_expected() {
  cat <<EXPECTED
ClusterRole $APP: groups=coordination.k8s.io resources=leases names= urls= verbs=*
ClusterRole $APP: groups=monitoring.giantswarm.io,observability.giantswarm.io resources=silences names= urls= verbs=*
ClusterRole $APP: groups=core resources=events names= urls= verbs=create
ClusterRoleBinding $APP: ClusterRole/$APP -> ServiceAccount/$NAMESPACE/$APP
EXPECTED
}

# monitor_targets: one line per PodMonitor in $RENDERED, "PodMonitor/name -> Kind/name" naming each
# rendered workload whose pod template carries the labels its selector matches and names every port
# it scrapes. A monitor that scrapes none of them ends in "-> none".
monitor_targets() {
  yq -N -o json -I0 'select(. != null)' "$RENDERED" | jq -rs '. as $all | .[]
    | select(.kind == "PodMonitor") | . as $monitor
    | ($monitor.spec.selector.matchLabels // {}) as $selector
    | [$monitor.spec.podMetricsEndpoints[].port] as $ports
    | [$all[] | select(.kind == "Deployment" or .kind == "DaemonSet" or .kind == "StatefulSet")
      | {name: (.kind + "/" + .metadata.name), labels: (.spec.template.metadata.labels // {}),
         ports: [.spec.template.spec.containers[].ports[]?.name]}
      | select(.labels as $labels | ($selector | length > 0)
          and ($selector | to_entries | all($labels[.key] == .value)))
      | select(.ports as $named | ($ports | length > 0) and ($ports | all(. as $port | any($named[]; . == $port))))
      | .name] as $targets
    | "PodMonitor/\($monitor.metadata.name) -> \(if ($targets | length) > 0 then $targets | join(" ") else "none" end)"'
}

@test "The silence operator is selected by one overlay entry and builds nothing when it is not" {
  local overlay="$REPO/kubernetes/apps/overlays/lab-sto2/kustomization.yaml" tree="$BATS_TEST_TMPDIR/tree"
  local with without entries path wait
  entries="$(grep -c "^  - ../../base/$OVERLAY_ENTRY\$" "$overlay")" || true
  echo "overlay lines naming $OVERLAY_ENTRY: $entries"
  [ "$entries" -eq 1 ]
  with="$(kustomize build --load-restrictor LoadRestrictionsNone "$(dirname "$overlay")")"
  path="$(yq -N "select(.kind == \"Kustomization\" and .metadata.name == \"$APP\") | .spec.path" <<<"$with")"
  wait="$(yq -N "select(.kind == \"Kustomization\" and .metadata.name == \"$APP\") | .spec.wait" <<<"$with")"
  echo "$APP in the overlay: ${path:-none}; waits: $wait"
  [ "$path" = "./apps/base/$NAMESPACE/$APP/app" ]
  # Ready only once its release is, so what applies a Silence after it finds the definitions.
  [ "$wait" = true ]
  # Its PodMonitor's kind exists once prometheus-operator-crds is Ready.
  depends "$with" "$APP" | grep -qx prometheus-operator-crds

  # The same overlay without the entry, in a copy of the tree: nothing of the application is built.
  mkdir -p "$tree/kubernetes"
  cp -R "$REPO/kubernetes/apps" "$REPO/kubernetes/components" "$tree/kubernetes/"
  grep -v "^  - ../../base/$OVERLAY_ENTRY\$" "$overlay" >"$tree/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  without="$(kustomize build --load-restrictor LoadRestrictionsNone "$tree/kubernetes/apps/overlays/lab-sto2")"
  echo "objects of the build without the entry: $(yq -N '.kind' <<<"$without" | grep -c .)"
  [ -n "$without" ]
  if grep -q "$APP" <<<"$without"; then
    echo "the build without the entry still names $APP"
    return 1
  fi
}

@test "The silence operator keeps its resource definitions when the release goes" {
  local crds templated
  render "$APP"
  crds="$(yq -N 'select(.kind == "CustomResourceDefinition") | .spec.group + " " + .metadata.name + " "
    + (.metadata.annotations["helm.sh/resource-policy"] // "none")' "$RENDERED" | sort)"
  echo "$crds"
  # Deleting a definition deletes every Silence, and with them the silences in Alertmanager.
  [ "$(grep -c . <<<"$crds")" -eq 2 ]
  grep -qx 'monitoring.giantswarm.io silences.monitoring.giantswarm.io keep' <<<"$crds"
  grep -qx 'observability.giantswarm.io silences.observability.giantswarm.io keep' <<<"$crds"
  # Templates of the release, not of a crds/ directory, which Helm installs once and never upgrades.
  templated="$(helm template "$RELEASE" "$CHART" --namespace "$NAMESPACE" --kube-version "$KUBE" \
    --values "$VALUES" --values "$INLINE" | yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' | sort)"
  [ "$templated" = "$(cut -d' ' -f2 <<<"$crds")" ]
}

@test "The silence operator runs hardened with requests and limits" {
  local pod replicas image
  render "$APP"
  pod="$(deployment)"
  replicas="$(jq -r '.spec.replicas' <<<"$pod")"
  image="$(jq -r '.spec.template.spec.containers[0].image' <<<"$pod")"
  echo "replicas: $replicas; image: $image"
  [ "$replicas" = 1 ]
  [ "$(jq '.spec.template.spec.containers | length' <<<"$pod")" -eq 1 ]
  # A tag other than latest, or a digest, which the image check also requires.
  [[ $image =~ :[0-9]+\.[0-9]+\.[0-9]+(@sha256:[0-9a-f]{64})?$ || $image =~ @sha256:[0-9a-f]{64}$ ]]
  jq -e '.spec.template.spec as $pod | $pod.containers[0] as $c
    | ($pod.securityContext.runAsNonRoot == true or $c.securityContext.runAsNonRoot == true)
    and ($c.securityContext.readOnlyRootFilesystem == true)
    and ($c.securityContext.allowPrivilegeEscalation == false)
    and ($c.securityContext.capabilities.drop == ["ALL"])
    and (($c.securityContext.seccompProfile.type // $pod.securityContext.seccompProfile.type) == "RuntimeDefault")
    and ($c.securityContext.privileged != true)
    and ($pod.hostNetwork != true and $pod.hostPID != true and $pod.hostIPC != true)' <<<"$pod"
  jq -e '.spec.template.spec.containers[0].resources
    | (.requests.cpu != null) and (.requests.memory != null) and (.limits.memory != null)' <<<"$pod"
}

@test "The silence operator reaches Alertmanager by its Service inside the cluster and holds no credential" {
  local pod address roles problems description port expression expected mutants survivors=""
  render "$APP"
  pod="$(deployment)"
  address="$(jq -r '.spec.template.spec.containers[0].args[] | select(startswith("--alertmanager-address="))
    | sub("^--alertmanager-address="; "")' <<<"$pod")"
  echo "Alertmanager address: ${address:-none}"
  # A Service name inside the cluster: scheme, name, namespace, svc.cluster.local and a port, with
  # no address literal that a rebuilt cluster would give to something else.
  [[ $address =~ ^http://([a-z0-9]([-a-z0-9]*[a-z0-9])?)\.([a-z0-9]([-a-z0-9]*[a-z0-9])?)\.svc\.cluster\.local:([0-9]+)$ ]]
  render kube-prometheus-stack
  problems="$(address_problems "$address")"
  echo "the address in the monitoring chart's render: ${problems:-no problems}"
  [ -z "$problems" ]
  # Another Service of the chart, on its own port, is not Alertmanager's.
  problems="$(address_problems http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090)"
  echo "the Prometheus Service: ${problems:-accepted}"
  [ -n "$problems" ]
  # Nor is a port of Alertmanager's Service that leads elsewhere, or a selector that names no
  # Alertmanager, in a copy of the chart's render changed that way.
  mutants=0
  while IFS='#' read -r description port expression expected; do
    yq "$expression" "$RENDERED" >"$BATS_TEST_TMPDIR/mutated.yaml"
    problems="$(RENDERED="$BATS_TEST_TMPDIR/mutated.yaml" address_problems "${address%:*}:$port")"
    echo "$description: ${problems:-accepted}"
    grep -qxF -- "$expected" <<<"$problems" || survivors+=" $description;"
    mutants=$((mutants + 1))
  done <<'ADDRESS'
the port of Alertmanager's config reloader#8080#.#the Service monitoring/kube-prometheus-stack-alertmanager sends port 8080 to reloader-web, not to Alertmanager's web port, 9093 or http-web
a selector of every pod prometheus-operator makes#9093#(select(.kind == "Service" and .metadata.name == "kube-prometheus-stack-alertmanager") | .spec.selector) = {"app.kubernetes.io/managed-by": "prometheus-operator"}#the Service monitoring/kube-prometheus-stack-alertmanager names no Alertmanager in its selector, by alertmanager or by app.kubernetes.io/name alertmanager and app.kubernetes.io/instance: {"app.kubernetes.io/managed-by":"prometheus-operator"}
ADDRESS
  echo "survivors:${survivors:- none}"
  [ -z "$survivors" ]
  [ "$mutants" -eq 2 ]

  render "$APP"
  pod="$(deployment)"
  # The operator reads its Silence objects with the service account's token, which the pod gets
  # from Kubernetes. Alertmanager gets none: with authentication on, the operator sends the token
  # as a bearer credential, which this Alertmanager does not ask for.
  problems="$(args_problems <<<"$pod")"
  echo "the operator's arguments: ${problems:-no problems}"
  [ -z "$problems" ]
  # Nothing else carries a credential in: no environment, no volume, no Secret in the release.
  jq -e '(.spec.template.spec.containers[0].env // []) == []
    and (.spec.template.spec.containers[0].envFrom // []) == []
    and (.spec.template.spec.volumes // []) == []
    and (.spec.template.spec.containers[0].volumeMounts // []) == []' <<<"$pod"
  [ -z "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$RENDERED")" ]
  # Its rights.
  roles="$(yq -N -o json -I0 'select(.kind == "ClusterRole" or .kind == "Role" or .kind == "ClusterRoleBinding" or .kind == "RoleBinding")' "$RENDERED")"
  problems="$(rights_problems <<<"$roles")"
  echo "the operator's rights: ${problems:-no problems}"
  [ -z "$problems" ]
  # The proofs are not empty ones: each change to what the operator is given, as an extra argument
  # of the chart (Go's flag package reads one dash or two, a bare boolean as true, and the last
  # occurrence of a flag over the earlier) or as a right, is refused.
  mutants=0
  while IFS='#' read -r description expression expected; do
    problems="$(args_problems < <(jq -c "$expression" <<<"$pod"))"
    echo "$description: ${problems:-accepted}"
    [ -n "$problems" ]
    mutants=$((mutants + 1))
  done <<'ARGS'
an address of its own after the chart's#.spec.template.spec.containers[0].args += ["-alertmanager-address=http://192.0.2.10:9093"]#
a bare authentication flag#.spec.template.spec.containers[0].args += ["--alertmanager-authentication"]#
authentication on by 1#.spec.template.spec.containers[0].args += ["--alertmanager-authentication=1"]#
authentication on by one dash#.spec.template.spec.containers[0].args += ["-alertmanager-authentication=true"]#
authentication on by T#.spec.template.spec.containers[0].args += ["--alertmanager-authentication=T"]#
an address in two arguments#.spec.template.spec.containers[0].args += ["-alertmanager-address", "http://192.0.2.10:9093"]#
an address as a literal#.spec.template.spec.containers[0].args |= map(if startswith("--alertmanager-address=") then "--alertmanager-address=http://192.0.2.10:9093" else . end)#
no authentication setting#.spec.template.spec.containers[0].args |= map(select(startswith("--alertmanager-authentication=") | not))#
ARGS
  [ "$mutants" -eq 8 ]
  mutants=0
  while IFS='#' read -r description expression; do
    problems="$(rights_problems < <(jq -c "$expression" <<<"$roles"))"
    echo "$description: ${problems:-accepted}"
    [ -n "$problems" ]
    mutants=$((mutants + 1))
  done <<'RIGHTS'
a right on Secrets#if .kind == "ClusterRole" then .rules += [{apiGroups: [""], resources: ["secrets"], verbs: ["get"]}] else . end
every verb on events#if .kind == "ClusterRole" then .rules |= map(if .resources == ["events"] then .verbs = ["*"] else . end) else . end
every verb on Silence status and finalizers#if .kind == "ClusterRole" then .rules += [{apiGroups: ["observability.giantswarm.io"], resources: ["silences/status"], verbs: ["*"]}] else . end
every API group#if .kind == "ClusterRole" then .rules |= map(if .resources == ["leases"] then .apiGroups = ["*"] else . end) else . end
a second binding#if .kind == "ClusterRoleBinding" then .subjects += [{kind: "Group", name: "system:authenticated"}] else . end
a binding to another role#if .kind == "ClusterRoleBinding" then .roleRef.name = "cluster-admin" else . end
every non-resource URL#if .kind == "ClusterRole" then .rules += [{nonResourceURLs: ["*"], verbs: ["*"]}] else . end
an extra rule jq cannot read#if .kind == "ClusterRole" then .rules += [{apiGroups: "", resources: ["secrets"], verbs: ["get"]}] else . end
RIGHTS
  [ "$mutants" -eq 8 ]
  # The HelmRelease reads no Secret for its values.
  [ -z "$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[]? | select(.kind == "Secret") | .name' "$BUILT")" ]
}

@test "The silence operator's metrics are scraped" {
  local targets
  render "$APP"
  targets="$(monitor_targets)"
  echo "$APP: ${targets:-no monitor}"
  # Exactly one monitor, so nothing is scraped twice, and it scrapes the pod the chart makes.
  [ "$(grep -c . <<<"$targets")" -eq 1 ]
  [[ $targets == PodMonitor/* ]]
  [[ $targets != *' -> none' ]]
  # The operator serves its metrics over plain HTTP on the port the monitor names.
  jq -e '.spec.template.spec.containers[0].args | index("--metrics-bind-address=:8080") != null' <<<"$(deployment)"
  [ "$(yq -N 'select(.kind == "PodMonitor") | .spec.podMetricsEndpoints[0].scheme // "http"' "$RENDERED")" = http ]
  echo "$APP depends on: $(depends "$(overlay_build)" "$APP" | xargs)"
  depends "$(overlay_build)" "$APP" | grep -qx prometheus-operator-crds
}

@test "A silence in the tree says why, names its alert and has an end or an issue" {
  local problems mutants description expression expected where name found locations survivors=""
  # A failing kustomize build in a pipe fails the step, not only the filter after it.
  set -o pipefail
  tree_problems "$REPO"
  echo "applications built: $APPS; applications rendered: $APPLIED; Silence objects: $SILENCES"
  echo "problems in the tree: ${PROBLEMS:-none}"
  [ "$APPS" -gt 0 ]
  [ "$APPLIED" -gt 0 ]
  [ -z "$PROBLEMS" ]

  # The rules are not empty ones: the fixture, which meets them all, passes, and a copy of it
  # that breaks one rule is refused for that rule.
  problems="$(fixture_problems '.')"
  echo "the fixture: ${problems:-no problems}"
  [ -z "$problems" ]
  mutants=0
  while IFS='#' read -r description expression expected; do
    problems="$(fixture_problems "$expression")"
    echo "$description: ${problems:-accepted}"
    grep -qxF -- "monitoring/example: $expected" <<<"$problems"
    mutants=$((mutants + 1))
  done <<'MUTANTS'
no reason#del(.metadata.annotations["k8s-gitops/reason"])#has no reason in the annotation k8s-gitops/reason
a blank reason#.metadata.annotations["k8s-gitops/reason"] = "  "#has no reason in the annotation k8s-gitops/reason
no end and no issue#del(.spec.endsAt) | del(.metadata.annotations["k8s-gitops/issue"])#has neither spec.endsAt nor an issue key in the annotation k8s-gitops/issue
an issue that is no key#del(.spec.endsAt) | .metadata.annotations["k8s-gitops/issue"] = "later"#has neither spec.endsAt nor an issue key in the annotation k8s-gitops/issue
no matchers#.spec.matchers = []#has no alertname matcher with =
no alertname#.spec.matchers[0].name = "severity"#has no alertname matcher with =
a negated alertname#.spec.matchers[0].matchType = "!="#has no alertname matcher with =
an empty alertname#.spec.matchers[0].value = ""#has an alertname matcher with an empty value
every alert#.spec.matchers[0].matchType = "=~" | .spec.matchers[0].value = ".*"#has an alertname matcher other than =, which can match more than one alert
a prefix of alert names#.spec.matchers[0].matchType = "=~" | .spec.matchers[0].value = "Kube.*"#has an alertname matcher other than =, which can match more than one alert
every name not starting with W#.spec.matchers[0].matchType = "=~" | .spec.matchers[0].value = "[^W].+"#has an alertname matcher other than =, which can match more than one alert
every name starting with a letter but W#.spec.matchers[0].matchType = "=~" | .spec.matchers[0].value = "[A-VX-Z].*"#has an alertname matcher other than =, which can match more than one alert
the Watchdog#.spec.matchers[0].value = "Watchdog"#silences the Watchdog, which is meant to fire
the Watchdog by pattern#.spec.matchers[0].matchType = "=~" | .spec.matchers[0].value = "Watch.*"#has an alertname matcher other than =, which can match more than one alert
a pattern that is not one#.spec.matchers[0].matchType = "=~" | .spec.matchers[0].value = "("#has an alertname matcher other than =, which can match more than one alert
the cluster-scoped API#.apiVersion = "monitoring.giantswarm.io/v1alpha1"#is not an observability.giantswarm.io/v1alpha2 Silence, the namespaced API
MUTANTS
  [ "$mutants" -eq 16 ]

  # A Silence is read in the whole render, not only in an application's app/, and one in a
  # construction the render does not expand is refused by that construction: in one copy of the
  # tree, each place below holds a Silence named after it, with no reason, no end, no issue and a
  # pattern for every alert, and each is refused there, as one render of the copy reads them all.
  # The fixture, which meets every rule, is accepted in an application's app/.
  locations="$(cat <<'LOCATIONS'
valid#kubernetes/apps/base/demo/hello/app/valid.yaml#
at-namespace#kubernetes/apps/base/monitoring/at-namespace.yaml#lab-sto2/cluster: monitoring/at-namespace: is not a resource of an application's app/: lab-sto2/cluster applies it from ./apps/overlays/lab-sto2
at-app#kubernetes/apps/base/demo/hello/app/at-app.yaml#lab-sto2/hello: demo/at-app: has no reason in the annotation k8s-gitops/reason
at-component#kubernetes/components/volsync/at-component.yaml#lab-sto2/volsync-demo: demo/at-component: is not a resource of an application's app/: kustomize builds no such Silence from ./apps/base/demo/volsync-demo/app
at-cluster#kubernetes/clusters/lab-sto2/at-cluster.yaml#lab-sto2/flux-system: monitoring/at-cluster: is not a resource of an application's app/: lab-sto2/flux-system applies it from the cluster directory
at-overlay#kubernetes/apps/overlays/lab-sto2/at-overlay.yaml#lab-sto2/cluster: monitoring/at-overlay: is not a resource of an application's app/: lab-sto2/cluster applies it from ./apps/overlays/lab-sto2
at-chart-values#kubernetes/apps/base/monitoring/kube-prometheus-stack/app/values.yaml#lab-sto2/kube-prometheus-stack: monitoring/at-chart-values: is not a resource of an application's app/: the chart of HelmRelease monitoring/kube-prometheus-stack renders it
at-component-txt#kubernetes/components/volsync/at-component-txt.txt#lab-sto2/volsync-demo: demo/at-component-txt: is not a resource of an application's app/: kustomize builds no such Silence from ./apps/base/demo/volsync-demo/app
at-list#list:kubernetes/apps/base/monitoring/kube-prometheus-stack/app/values.yaml#lab-sto2/kube-prometheus-stack: /at-list: is a List with items, which Flux applies as objects of their own and the render holds as one
at-values-from#values-from:kubernetes/apps/base/monitoring/grafana/app/at-values-from.yaml#lab-sto2/kube-prometheus-stack: monitoring/at-values-from: is optional in the valuesFrom of HelmRelease monitoring/kube-prometheus-stack, which the render leaves out when the application does not hold it
at-flux#flux:kubernetes/apps/base/demo/hello/app/extra/at-flux.yaml#lab-sto2/kube-prometheus-stack: flux-system/at-flux: is a Kustomization the chart of HelmRelease monitoring/kube-prometheus-stack renders, which the render does not follow
LOCATIONS
)"
  located_problems <<<"$locations"
  echo "applications rendered from the copy: $APPLIED; Silence objects read: $SILENCES"
  mutants=0
  while IFS='#' read -r name where expected; do
    found="$(grep -F "/$name: " <<<"$PROBLEMS" || true)"
    echo "$where: ${found:-accepted}"
    if [ -z "$expected" ]; then
      [ -z "$found" ]
      continue
    fi
    grep -qxF -- "$expected" <<<"$PROBLEMS" || survivors+=" $where"
    mutants=$((mutants + 1))
  done <<<"$locations"
  echo "survivors:${survivors:- none}"
  [ -z "$survivors" ]
  [ "$mutants" -eq 10 ]
}

@test "every values key of silence-operator is one its pinned chart defines" {
  local keys="$BATS_TEST_TMPDIR/keys" unknown="" key map open
  local paths='[.. | select(path | length > 0) | path | select(all_c(tag == "!!str")) | join(".")] | .[]'
  render "$APP"
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
  echo "$APP: keys the chart does not define:${unknown:- none}"
  [ -z "$unknown" ]
}
