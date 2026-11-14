#!/usr/bin/env bats
# Proves features/cluster-baseline.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq and git on PATH (the versions pinned for the repository). Each
# chart is pulled once per run from its public registry, and the Gateway API repository is cloned
# once, at the pinned tag and with only the directories its GitRepository checks out; building and
# rendering are offline.

# The tests run one at a time even where bats runs a file's tests side by side: flux build rewrites
# the kustomization.yaml of the application it builds in this checkout and puts it back afterwards,
# so two builds of one application at once can leave the rewritten file behind; and a test that
# starts while another pulls a chart finds the chart's directory before the chart is in it.
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
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLUSTER="$REPO/kubernetes/clusters/lab-sto2"
  KUBE="$(yq -e '.kubernetes' "$REPO/versions.yaml")"
  # The applications whose charts make up the baseline, the resource definitions' included.
  CHARTS=(prometheus-operator-crds kubelet-csr-approver metrics-server spegel reloader descheduler)
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# example_vars FILE: writes the variables of the cluster's example key lists to FILE as one map.
example_vars() {
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$1"
}

# built APP [VARS]: the kube-system application APP as Flux applies it: its app/ built with its
# ks.yaml, substituting strictly the variables of the cluster's example key lists, or those of the
# YAML map in the file VARS instead. Writes $BATS_TEST_TMPDIR/APP-built.yaml and sets BUILT.
built() {
  local app=$1 vars=${2:-} ks="$BATS_TEST_TMPDIR/$1-ks.yaml"
  if [ -z "$vars" ]; then
    vars="$BATS_TEST_TMPDIR/example-vars.yaml"
    example_vars "$vars"
  fi
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = $vars' "$vars" "$REPO/kubernetes/apps/base/kube-system/$app/ks.yaml" >"$ks"
  BUILT="$BATS_TEST_TMPDIR/$app-built.yaml"
  # flux build reads only paths below the working directory.
  (cd "$REPO" && flux build kustomization "$app" --path "./kubernetes/apps/base/kube-system/$app/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute) >"$BUILT"
}

# render APP [VARS]: renders the chart that APP's HelmRelease installs, built as built() builds
# it, from the URL and tag of its OCIRepository, with the values helm-controller gives the chart:
# those of the ConfigMap the HelmRelease reads, then the HelmRelease's own over them. The
# ServiceMonitor and Grafana dashboard APIs count as present, so that only the values keep such
# objects out. Writes $BATS_TEST_TMPDIR/APP.yaml and sets RENDERED, CHART, VALUES and INLINE.
render() {
  local app=$1 url tag name release namespace pulled
  built "$@"
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
  pulled="$BATS_FILE_TMPDIR/charts/$app/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  RENDERED="$BATS_TEST_TMPDIR/$app.yaml"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" --include-crds \
    --api-versions monitoring.coreos.com/v1 --api-versions grafana.integreatly.org/v1beta1 \
    --values "$VALUES" --values "$INLINE" >"$RENDERED"
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

# deployment_env NAME: the value the rendered Deployment gives its container's environment variable
# NAME; nothing when it gives none.
deployment_env() {
  yq -N "select(.kind == \"Deployment\") | .spec.template.spec.containers[0].env // [] | .[]
    | select(.name == \"$1\") | .value" "$RENDERED"
}

# gateway_api: the Gateway API definitions as the application's inner Kustomization applies them:
# the repository its GitRepository names, cloned at the pinned tag with only the directories the
# GitRepository checks out, and built at the Kustomization's path with its patches. Writes
# $BATS_TEST_TMPDIR/gateway-api.yaml and sets GATEWAY_API and TAG.
gateway_api() {
  local repository reference url src inner name namespace path
  local -a dirs
  built gateway-api-crds
  repository="$(yq -N 'select(.kind == "GitRepository") | .metadata.name' "$BUILT")"
  reference="$(yq -N 'select(.kind == "Kustomization") | .spec.sourceRef.kind + "/" + .spec.sourceRef.name' "$BUILT")"
  echo "inner Kustomization source: $reference; GitRepository: $repository"
  [ "$reference" = "GitRepository/$repository" ]
  url="$(yq -N 'select(.kind == "GitRepository") | .spec.url' "$BUILT")"
  TAG="$(yq -N 'select(.kind == "GitRepository") | .spec.ref.tag' "$BUILT")"
  mapfile -t dirs < <(yq -N 'select(.kind == "GitRepository") | .spec.sparseCheckout // [] | .[]' "$BUILT")
  src="$BATS_FILE_TMPDIR/gateway-api/$TAG"
  if [ ! -d "$src" ]; then
    if ((${#dirs[@]} > 0)); then
      git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" --filter=blob:none --sparse "$url" "$src"
      git -C "$src" sparse-checkout set "${dirs[@]}"
    else
      git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" "$url" "$src"
    fi
  fi
  inner="$BATS_TEST_TMPDIR/inner.yaml"
  yq -N 'select(.kind == "Kustomization")' "$BUILT" >"$inner"
  name="$(yq '.metadata.name' "$inner")"
  namespace="$(yq '.metadata.namespace' "$inner")"
  path="$(yq '.spec.path' "$inner")"
  GATEWAY_API="$BATS_TEST_TMPDIR/gateway-api.yaml"
  (cd "$src" && flux build kustomization "$name" --namespace "$namespace" --path "$path" \
    --kustomization-file "$inner" --dry-run) >"$GATEWAY_API"
}

@test "The monitoring resource definitions are installed without a controller" {
  local objects
  render prometheus-operator-crds
  objects="$(yq -N 'select(. != null) | .kind + "/" + .metadata.name' "$RENDERED")"
  echo "$objects"
  [ -n "$objects" ]
  [ "$(grep -vc '^CustomResourceDefinition/' <<<"$objects")" -eq 0 ]
  grep -qx 'CustomResourceDefinition/servicemonitors.monitoring.coreos.com' <<<"$objects"
  grep -qx 'CustomResourceDefinition/podmonitors.monitoring.coreos.com' <<<"$objects"
}

@test "The Gateway API resource definitions are installed from the standard channel" {
  local objects versions
  gateway_api
  objects="$(yq -N 'select(. != null) | .kind + " " + (.spec.group // "none") + " "
    + (.metadata.annotations["gateway.networking.k8s.io/channel"] // "none") + " " + .metadata.name' "$GATEWAY_API")"
  echo "$objects"
  [ -n "$objects" ]
  [ "$(grep -vc '^CustomResourceDefinition gateway\.networking\.k8s\.io standard ' <<<"$objects")" -eq 0 ]
  grep -q ' gateways\.gateway\.networking\.k8s\.io$' <<<"$objects"
  grep -q ' httproutes\.gateway\.networking\.k8s\.io$' <<<"$objects"
  # Every definition is from the pinned release.
  versions="$(yq -N 'select(. != null) | .metadata.annotations["gateway.networking.k8s.io/bundle-version"] // "none"' "$GATEWAY_API" | sort -u)"
  echo "bundle versions: $versions; pinned tag: $TAG"
  [ "$versions" = "$TAG" ]
}

@test "Every baseline chart renders with the repository's values" {
  local app monitors
  for app in "${CHARTS[@]}"; do
    render "$app"
    echo "$app: $(yq -N 'select(. != null) | .kind' "$RENDERED" | sort | uniq -c | xargs)"
    monitors="$(yq -N 'select(. != null) | select(.kind == "ServiceMonitor" or .kind == "PodMonitor"
      or .kind == "GrafanaDashboard" or (.kind == "ConfigMap" and (.metadata.labels // {} | has("grafana_dashboard"))))
      | .kind + "/" + .metadata.name' "$RENDERED")"
    [ -z "$monitors" ] || { echo "$app renders $monitors"; return 1; }
  done
}

@test "Serving certificates are approved only for this cluster's nodes" {
  local app=kubelet-csr-approver raw declared var vars regex prefixes name prefix
  local -a names ranges list
  # The values file sets neither the name pattern nor the address ranges. The HelmRelease's own
  # values, which Flux substitutes, take both from variables the example cluster-config declares.
  [ "$(yq '[.providerRegex, .providerIpPrefixes] | map(select(. != null)) | length' \
    "$REPO/kubernetes/apps/base/kube-system/$app/app/values.yaml")" -eq 0 ]
  raw="$(kustomize build "$REPO/kubernetes/apps/base/kube-system/$app/app" | yq -N 'select(.kind == "HelmRelease") | .spec.values')"
  echo "HelmRelease values: $raw"
  mapfile -t names < <(yq '.providerRegex // ""' <<<"$raw" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*' | cut -c3-)
  mapfile -t ranges < <(yq '.providerIpPrefixes // [] | .[]' <<<"$raw" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*' | cut -c3-)
  echo "name pattern from: ${names[*]}; address ranges from: ${ranges[*]}"
  [ "${#names[@]}" -gt 0 ]
  [ "${#ranges[@]}" -gt 0 ]
  # shellcheck disable=SC2016 # ${ is what the yq expression looks for.
  [ "$(yq '.providerIpPrefixes | map(select(contains("${") | not)) | length' <<<"$raw")" -eq 0 ]
  declared="$(yq 'keys | .[]' "$CLUSTER/cluster-config.example.yaml")"
  for var in "${names[@]}" "${ranges[@]}"; do
    grep -qxF -- "$var" <<<"$declared" || { echo "$var is not in cluster-config.example.yaml"; return 1; }
  done

  # Set, the variables reach the approver as a pattern a node name must match in full, and as
  # its address ranges.
  vars="$BATS_TEST_TMPDIR/node-vars.yaml"
  example_vars "$vars"
  for var in "${names[@]}"; do VAR="$var" yq -i '.[strenv(VAR)] = "node-[0-9]+"' "$vars"; done
  for var in "${ranges[@]}"; do VAR="$var" yq -i '.[strenv(VAR)] = "192.0.2.0/24"' "$vars"; done
  render "$app" "$vars"
  regex="$(deployment_env PROVIDER_REGEX)"
  prefixes="$(deployment_env PROVIDER_IP_PREFIXES)"
  echo "set: PROVIDER_REGEX=$regex PROVIDER_IP_PREFIXES=$prefixes"
  [ "$prefixes" = 192.0.2.0/24 ]
  for name in node-1 node-23; do
    [[ $name =~ $regex ]] || { echo "the pattern does not match $name"; return 1; }
  done
  for name in node-1.example.com other-node-1 node-x ""; do
    if [[ $name =~ $regex ]]; then echo "the pattern also matches '$name'"; return 1; fi
  done

  # Missing or empty, as Flux substitutes a key cluster-config lacks, they leave the approver
  # approving nothing. Its pattern applies only to the names in a request, and matches none. Its
  # address ranges must hold no prefix: the approver reads an empty value as every address, and
  # stops at a value it cannot parse.
  vars="$BATS_TEST_TMPDIR/empty-vars.yaml"
  example_vars "$vars"
  yq -i '.[] = ""' "$vars"
  render "$app" "$vars"
  regex="$(deployment_env PROVIDER_REGEX)"
  prefixes="$(deployment_env PROVIDER_IP_PREFIXES)"
  echo "missing: PROVIDER_REGEX=$regex PROVIDER_IP_PREFIXES=$prefixes"
  [ -n "$regex" ]
  for name in node-1 example-cp-1 a; do
    if [[ $name =~ $regex ]]; then echo "the pattern matches '$name'"; return 1; fi
  done
  [ -n "$prefixes" ]
  IFS=, read -ra list <<<"$prefixes"
  for prefix in "${list[@]}"; do
    if [[ $prefix =~ ^[0-9A-Fa-f.:]+/[0-9]+$ ]]; then echo "$prefix is an address prefix"; return 1; fi
  done
}

@test "Metrics are scraped over verified kubelet certificates" {
  local args
  render metrics-server
  args="$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[]
    | select(.name == "metrics-server") | (.command // []) + (.args // []) | .[]' "$RENDERED")"
  echo "$args"
  # The kubelets are reached on an address their serving certificates name.
  grep -qx -- '--kubelet-preferred-address-types=InternalIP.*' <<<"$args"
  [ "$(grep -cE -- '^--(kubelet-insecure-tls|deprecated-kubelet-completely-insecure)(=|$)' <<<"$args")" -eq 0 ]
}

@test "Resource definitions are never pruned" {
  local app kept inner
  # Neither application applies a definition itself, so pruning what it applies deletes none.
  for app in prometheus-operator-crds gateway-api-crds; do
    built "$app"
    echo "$app applies: $(yq -N 'select(. != null) | .kind' "$BUILT" | sort | paste -sd' ' -)"
    [ -z "$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$BUILT")" ]
  done
  # Removing the monitoring application uninstalls its release, and Helm keeps every object of a
  # release that is marked keep.
  render prometheus-operator-crds
  kept="$(yq -N 'select(. != null) | .metadata.name + " " + (.metadata.annotations["helm.sh/resource-policy"] // "none")' "$RENDERED")"
  echo "$kept"
  [ -n "$kept" ]
  [ "$(grep -vc ' keep$' <<<"$kept")" -eq 0 ]
  # Removing the Gateway API application deletes its inner Kustomization, which then leaves what it
  # applied in place, and never prunes a definition a newer release drops.
  built gateway-api-crds
  inner="$(yq -N 'select(.kind == "Kustomization") | (.spec.prune | tostring) + " " + (.spec.deletionPolicy // "MirrorPrune")' "$BUILT")"
  echo "inner Kustomization prune and deletion policy: $inner"
  [[ $inner =~ ^false\ (MirrorPrune|Orphan)$ ]]
}

@test "every values key of prometheus-operator-crds is one its pinned chart defines" {
  defined_keys prometheus-operator-crds
}

@test "every values key of kubelet-csr-approver is one its pinned chart defines" {
  defined_keys kubelet-csr-approver
}

@test "every values key of metrics-server is one its pinned chart defines" {
  defined_keys metrics-server
}

@test "every values key of spegel is one its pinned chart defines" {
  defined_keys spegel
}

@test "every values key of reloader is one its pinned chart defines" {
  defined_keys reloader
}

@test "every values key of descheduler is one its pinned chart defines" {
  defined_keys descheduler
}
