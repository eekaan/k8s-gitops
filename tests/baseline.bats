#!/usr/bin/env bats
# Proves features/cluster-baseline.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq, jq and git on PATH (the versions pinned for the repository). Each
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
  CHARTS=(prometheus-operator-crds kubelet-csr-approver metrics-server spegel reloader descheduler cert-manager envoy-gateway)
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

# app_dir APP: sets APP_DIR to the directory of the application APP, in whichever namespace
# directory it is, relative to the repository.
app_dir() {
  local -a dirs=("$REPO"/kubernetes/apps/base/*/"$1")
  [ -f "${dirs[0]}/ks.yaml" ] || { echo "$1: no application directory with a ks.yaml"; return 1; }
  APP_DIR="${dirs[0]#"$REPO"/}"
}

# built APP [VARS]: the application APP as Flux applies it: its app/ built with its ks.yaml,
# substituting strictly the variables of the cluster's example key lists, or those of the YAML map
# in the file VARS instead. Writes $BATS_TEST_TMPDIR/APP-built.yaml and sets BUILT and APP_DIR.
built() {
  local app=$1 vars=${2:-} ks="$BATS_TEST_TMPDIR/$1-ks.yaml"
  app_dir "$app"
  if [ -z "$vars" ]; then
    vars="$BATS_TEST_TMPDIR/example-vars.yaml"
    example_vars "$vars"
  fi
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = $vars' "$vars" "$REPO/$APP_DIR/ks.yaml" >"$ks"
  BUILT="$BATS_TEST_TMPDIR/$app-built.yaml"
  # flux build reads only paths below the working directory.
  (cd "$REPO" && flux build kustomization "$app" --path "./$APP_DIR/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute) >"$BUILT"
}

# render APP [VARS]: renders the chart that APP's HelmRelease installs, built as built() builds
# it, from the URL and tag of its OCIRepository, with the values helm-controller gives the chart:
# those of the ConfigMap the HelmRelease reads, then the HelmRelease's own over them. The
# ServiceMonitor, PodMonitor and Grafana dashboard APIs count as present, by group and version and
# by kind, as charts test for either, so that only the values keep such objects out. Writes
# $BATS_TEST_TMPDIR/APP.yaml and sets RENDERED, CHART, VALUES and INLINE.
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
    --api-versions monitoring.coreos.com/v1/ServiceMonitor --api-versions monitoring.coreos.com/v1/PodMonitor \
    --api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
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

# stable_served FILE: "Kind version" for each version that a Gateway API definition in FILE serves
# and that is not an alpha version, sorted. The standard channel serves no alpha version.
stable_served() {
  # shellcheck disable=SC2016 # $kind is a yq variable.
  yq -N 'select(.kind == "CustomResourceDefinition" and .spec.group == "gateway.networking.k8s.io")
    | .spec.names.kind as $kind | .spec.versions[] | select(.served and (.name | test("alpha") | not))
    | $kind + " " + .name' "$1" | sort -u
}

# selects SELECTOR LABELS: succeeds when the label map SELECTOR is not empty and every label in it
# is in the label map LABELS with the same value, so it selects pods with those labels.
selects() {
  local selector=$1 labels=$2 key
  [ "$(yq 'length' <<<"$selector")" -gt 0 ] || return 1
  while IFS= read -r key; do
    [ "$(KEY="$key" yq '.[strenv(KEY)]' <<<"$selector")" = "$(KEY="$key" yq '.[strenv(KEY)]' <<<"$labels")" ] || return 1
  done < <(yq 'keys | .[]' <<<"$selector")
}

# envoy_gateway_config: the configuration the rendered Envoy Gateway chart gives its controller.
envoy_gateway_config() {
  yq -N 'select(.kind == "ConfigMap" and .metadata.name == "envoy-gateway-config") | .data["envoy-gateway.yaml"]' "$RENDERED"
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
  local app dashboards
  for app in "${CHARTS[@]}"; do
    render "$app"
    echo "$app: $(yq -N 'select(. != null) | .kind' "$RENDERED" | sort | uniq -c | xargs)"
    dashboards="$(yq -N 'select(. != null) | select(.kind == "GrafanaDashboard"
      or (.kind == "ConfigMap" and (.metadata.labels // {} | has("grafana_dashboard"))))
      | .kind + "/" + .metadata.name' "$RENDERED")"
    [ -z "$dashboards" ] || { echo "$app renders $dashboards"; return 1; }
  done
}

@test "Every baseline application that serves metrics has its monitor on" {
  local app kind targets depends
  local -A wanted=([kubelet-csr-approver]=ServiceMonitor [metrics-server]=ServiceMonitor
    [descheduler]=ServiceMonitor [spegel]=ServiceMonitor [reloader]=PodMonitor)
  for app in "${!wanted[@]}"; do
    kind=${wanted[$app]}
    render "$app"
    targets="$(monitor_targets)"
    echo "$app: ${targets:-no monitor}"
    # Exactly one monitor, of the kind the chart scrapes the application with, so nothing is
    # scraped twice.
    [ "$(grep -c . <<<"$targets")" -eq 1 ]
    [[ $targets == "$kind/"* ]]
    [[ $targets != *' -> none' ]]
    # The monitor's kind exists only once the definitions are installed.
    depends="$(yq '.spec.dependsOn // [] | .[].name' "$REPO/kubernetes/apps/base/kube-system/$app/ks.yaml")"
    echo "$app depends on: ${depends:-nothing}"
    grep -qx prometheus-operator-crds <<<"$depends"
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
  # No such application applies a definition itself, so pruning what it applies deletes none.
  for app in prometheus-operator-crds gateway-api-crds envoy-gateway-crds; do
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
  # Removing the Gateway API application, or Envoy Gateway's, deletes its inner Kustomization, which
  # then leaves what it applied in place, and never prunes a definition a newer release drops.
  for app in gateway-api-crds envoy-gateway-crds; do
    built "$app"
    inner="$(yq -N 'select(.kind == "Kustomization") | (.spec.prune | tostring) + " " + (.spec.deletionPolicy // "MirrorPrune")' "$BUILT")"
    echo "$app: inner Kustomization prune and deletion policy: $inner"
    [[ $inner =~ ^false\ (MirrorPrune|Orphan)$ ]]
  done
}

@test "Each container runtime the image adds has a RuntimeClass with its handler" {
  local enabled objects
  # The cluster runs the application: its overlay applies the application's Kustomization.
  enabled="$(kustomize build --load-restrictor LoadRestrictionsNone "$REPO/kubernetes/apps/overlays/lab-sto2" |
    yq -N 'select(.kind == "Kustomization" and .metadata.name == "runtime-classes") | .spec.path')"
  echo "runtime-classes in the overlay: ${enabled:-none}"
  [ "$enabled" = ./apps/base/kube-system/runtime-classes/app ]
  # The handlers are those the extensions' READMEs give: runsc for gVisor, kata for Kata
  # Containers' Cloud Hypervisor. A RuntimeClass is cluster-scoped, so it carries no namespace,
  # whatever the application's targetNamespace.
  built runtime-classes
  objects="$(yq -N 'select(. != null) | .apiVersion + " " + .kind + "/" + .metadata.name
    + " handler=" + (.handler // "none") + " namespace=" + (.metadata.namespace // "none")' "$BUILT" | sort)"
  echo "$objects"
  [ "$objects" = "$(printf '%s\n' 'node.k8s.io/v1 RuntimeClass/gvisor handler=runsc namespace=none' \
    'node.k8s.io/v1 RuntimeClass/kata handler=kata namespace=none')" ]
}

@test "Spegel runs in the cluster and configures containerd where Talos reads its mirrors" {
  local enabled daemonset paths mounted
  # The cluster runs the application: its overlay applies the application's Kustomization. Spegel
  # serves image layers only because every node's machine configuration keeps them
  # (tests/talos-check.bats).
  enabled="$(kustomize build --load-restrictor LoadRestrictionsNone "$REPO/kubernetes/apps/overlays/lab-sto2" |
    yq -N 'select(.kind == "Kustomization" and .metadata.name == "spegel") | .spec.path')"
  echo "spegel in the overlay: ${enabled:-none}"
  [ "$enabled" = ./apps/base/kube-system/spegel/app ]
  # Talos's containerd reads registry mirror configuration from /etc/cri/conf.d/hosts, not from
  # containerd's default /etc/containerd/certs.d.
  render spegel
  daemonset='select(.kind == "DaemonSet" and .metadata.name == "spegel") | .spec.template.spec'
  paths="$(yq -N "$daemonset"' | (.containers + .initContainers)[]
    | .name + " " + (.args[] | select(test("^--containerd-registry-config-path=")))' "$RENDERED" | sort)"
  echo "$paths"
  [ "$paths" = "$(printf '%s\n' 'configuration --containerd-registry-config-path=/etc/cri/conf.d/hosts' \
    'registry --containerd-registry-config-path=/etc/cri/conf.d/hosts')" ]
  # The container that writes it mounts the host's directory there.
  # shellcheck disable=SC2016 # $pod and $volume are yq variables.
  mounted="$(yq -N "$daemonset"' | . as $pod | .initContainers[] | select(.name == "configuration")
    | .volumeMounts[] | select(.mountPath == "/etc/cri/conf.d/hosts") | .name as $volume
    | $pod.volumes[] | select(.name == $volume) | .hostPath.path // "none"' "$RENDERED")"
  echo "the configuration container's /etc/cri/conf.d/hosts is the host's: ${mounted:-none}"
  [ "$mounted" = /etc/cri/conf.d/hosts ]
}

@test "Spegel serves no debug page" {
  local flags
  # The page, on the metrics port every pod reaches, lists the node's images and peers and pulls
  # an image on request. Spegel serves it when the flag is absent.
  render spegel
  flags="$(yq -N 'select(.kind == "DaemonSet" and .metadata.name == "spegel") | .spec.template.spec.containers[]
    | select(.name == "registry") | .args[] | select(test("^--debug-web-enabled"))' "$RENDERED")"
  echo "registry: ${flags:-no debug flag}"
  [ "$flags" = --debug-web-enabled=false ]
}

@test "The certificate controller runs in its own namespace with its resource definitions" {
  local overlay enabled namespace deployments elsewhere crds group
  # The cluster runs the application and its namespace directory: its overlay applies both.
  overlay="$(kustomize build --load-restrictor LoadRestrictionsNone "$REPO/kubernetes/apps/overlays/lab-sto2")"
  enabled="$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "cert-manager") | .spec.targetNamespace' <<<"$overlay")"
  namespace="$(yq -N 'select(.kind == "Namespace" and .metadata.name == "cert-manager") | .metadata.name' <<<"$overlay")"
  echo "cert-manager in the overlay: targetNamespace ${enabled:-none}; namespace ${namespace:-none}"
  [ "$enabled" = cert-manager ]
  [ "$namespace" = cert-manager ]

  render cert-manager
  deployments="$(yq -N 'select(.kind == "Deployment") | .metadata.namespace + "/" + .metadata.name' "$RENDERED" | sort)"
  echo "deployments: $deployments"
  [ "$deployments" = "$(printf '%s\n' cert-manager/cert-manager cert-manager/cert-manager-cainjector \
    cert-manager/cert-manager-webhook)" ]
  # Nothing in kube-system or any other namespace, not even the leader election lease's Role.
  elsewhere="$(yq -N 'select(. != null and .metadata.namespace != null and .metadata.namespace != "cert-manager")
    | .kind + "/" + .metadata.name + " in " + .metadata.namespace' "$RENDERED")"
  echo "in another namespace: ${elsewhere:-none}"
  [ -z "$elsewhere" ]

  # Deleting a definition deletes every certificate and issuer of its kind, so Helm keeps each one
  # when the release is uninstalled, as it is when the application leaves the tree.
  crds="$(yq -N 'select(.kind == "CustomResourceDefinition") | .spec.group + " " + .metadata.name + " "
    + (.metadata.annotations["helm.sh/resource-policy"] // "none")' "$RENDERED")"
  echo "$crds"
  for group in cert-manager.io acme.cert-manager.io; do
    grep -q "^$group " <<<"$crds" || { echo "no definition of $group"; return 1; }
  done
  grep -qx 'cert-manager.io certificates.cert-manager.io keep' <<<"$crds"
  grep -qx 'cert-manager.io clusterissuers.cert-manager.io keep' <<<"$crds"
  [ "$(grep -vc ' keep$' <<<"$crds")" -eq 0 ]
}

@test "The certificate controller handles Gateway API resources" {
  local depends wait config args
  # It starts only once the Gateway API definitions are established: it waits for their
  # application, which is Ready only then. cert-manager checks for them once, when it starts.
  app_dir cert-manager
  depends="$(yq '.spec.dependsOn // [] | .[].name' "$REPO/$APP_DIR/ks.yaml")"
  wait="$(yq '.spec.wait' "$REPO/kubernetes/apps/base/kube-system/gateway-api-crds/ks.yaml")"
  echo "cert-manager depends on: ${depends:-nothing}; gateway-api-crds waits: $wait"
  grep -qx gateway-api-crds <<<"$depends"
  [ "$wait" = true ]

  render cert-manager
  config="$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "cert-manager") | .data["config.yaml"]' "$RENDERED")"
  echo "controller configuration: ${config:-none}"
  [ "$(yq '.apiVersion + " " + .kind' <<<"$config")" = 'controller.config.cert-manager.io/v1alpha1 ControllerConfiguration' ]
  [ "$(yq '.gatewayAPI.enabled' <<<"$config")" = true ]
  # The controller reads that configuration.
  args="$(yq -N 'select(.kind == "Deployment" and .metadata.name == "cert-manager") | .spec.template.spec
    | ((.volumes[] | select(.configMap.name == "cert-manager") | "volume " + .name),
      (.containers[0].args[] | select(test("^--config="))))' "$RENDERED")"
  echo "controller: $args"
  grep -qx -- '--config=/var/cert-manager/config/config.yaml' <<<"$args"
  grep -q '^volume ' <<<"$args"
}

@test "The certificate controller keeps running while a node is drained" {
  local component deployment labels replicas spread budget min max failed=""
  render cert-manager
  for component in controller webhook cainjector; do
    deployment="$BATS_TEST_TMPDIR/$component.yaml"
    COMPONENT="$component" yq -N 'select(.kind == "Deployment"
      and .spec.template.metadata.labels["app.kubernetes.io/component"] == strenv(COMPONENT))' "$RENDERED" >"$deployment"
    if [ ! -s "$deployment" ]; then
      failed+=" $component:missing"
      continue
    fi
    labels="$(yq -o json -I0 '.spec.template.metadata.labels // {}' "$deployment")"
    replicas="$(yq '.spec.replicas // 1' "$deployment")"
    # A spread over the nodes that counts this component's pods only.
    # shellcheck disable=SC2016 # $labels is a yq variable.
    spread="$(LABELS="$labels" yq -N '(strenv(LABELS) | from_yaml) as $labels
      | .spec.template.spec.topologySpreadConstraints // [] | .[]
      | select(.topologyKey == "kubernetes.io/hostname" and .maxSkew == 1
        and (.labelSelector.matchLabels // {} | length) > 0
        and (.labelSelector.matchLabels | to_entries | all_c(.value == $labels[.key])))
      | .whenUnsatisfiable' "$deployment")"
    # A budget whose selector picks this component's pods.
    # shellcheck disable=SC2016 # $labels is a yq variable.
    budget="$(LABELS="$labels" yq -N '(strenv(LABELS) | from_yaml) as $labels | select(.kind == "PodDisruptionBudget"
      and (.spec.selector.matchLabels // {} | length) > 0
      and (.spec.selector.matchLabels | to_entries | all_c(.value == $labels[.key])))
      | (.spec.minAvailable // "none" | tostring) + " " + (.spec.maxUnavailable // "none" | tostring)' "$RENDERED")"
    read -r min max <<<"${budget:-none none}"
    echo "$component: replicas $replicas, spread over nodes: ${spread:-none}, budget minAvailable $min maxUnavailable $max"
    if ((replicas < 2)); then failed+=" $component:replicas"; fi
    [ -n "$spread" ] || failed+=" $component:spread"
    # The budget keeps one pod available and lets a drain evict another.
    if [[ $min =~ ^[0-9]+$ && $max == none ]]; then
      ((min >= 1 && min < replicas)) || failed+=" $component:budget"
    elif [[ $max =~ ^[0-9]+$ && $min == none ]]; then
      ((max >= 1 && max < replicas)) || failed+=" $component:budget"
    else
      failed+=" $component:budget"
    fi
  done
  echo "failed:${failed:- none}"
  [ -z "$failed" ]
}

@test "Envoy Gateway's chart installs no resource definitions" {
  local objects
  # render includes the definitions of the chart's crds/ directories, its enabled subcharts' too,
  # which helm-controller installs with the release.
  render envoy-gateway
  objects="$(yq -N 'select(. != null) | .kind + "/" + .metadata.name' "$RENDERED")"
  echo "$objects"
  grep -qx 'Deployment/envoy-gateway' <<<"$objects"
  [ "$(grep -cE '^(CustomResourceDefinition|ValidatingAdmissionPolicy|ValidatingAdmissionPolicyBinding)/' <<<"$objects")" -eq 0 ]
}

@test "Envoy Gateway's resource definitions come from its chart at the controller's version" {
  local controller source layer reference src inner name namespace path applied objects shipped
  render envoy-gateway
  controller="$(yq -N 'select(.kind == "OCIRepository") | .spec.url + ":" + .spec.ref.tag' "$BUILT")"
  built envoy-gateway-crds
  source="$(yq -N 'select(.kind == "OCIRepository") | .spec.url + ":" + .spec.ref.tag' "$BUILT")"
  echo "the controller's chart: $controller; the definitions' chart: $source"
  [ -n "$controller" ]
  [ "$source" = "$controller" ]
  # source-controller unpacks the chart's packaged layer, and the inner Kustomization applies a
  # directory of it.
  layer="$(yq -N 'select(.kind == "OCIRepository") | .spec.layerSelector.mediaType + " " + .spec.layerSelector.operation' "$BUILT")"
  echo "layer: $layer"
  [ "$layer" = "application/vnd.cncf.helm.chart.content.v1.tar+gzip extract" ]
  reference="$(yq -N 'select(.kind == "Kustomization") | .spec.sourceRef.kind + "/" + .spec.sourceRef.name' "$BUILT")"
  echo "inner Kustomization source: $reference"
  [ "$reference" = "OCIRepository/$(yq -N 'select(.kind == "OCIRepository") | .metadata.name' "$BUILT")" ]
  # The same chart at the same tag is the one render pulled for the controller.
  src="$BATS_TEST_TMPDIR/unpacked"
  mkdir -p "$src"
  tar -xzf "$CHART" -C "$src"
  inner="$BATS_TEST_TMPDIR/inner.yaml"
  yq -N 'select(.kind == "Kustomization")' "$BUILT" >"$inner"
  name="$(yq '.metadata.name' "$inner")"
  namespace="$(yq '.metadata.namespace' "$inner")"
  path="$(yq '.spec.path' "$inner")"
  applied="$BATS_TEST_TMPDIR/envoy-gateway-definitions.yaml"
  (cd "$src" && flux build kustomization "$name" --namespace "$namespace" --path "$path" \
    --kustomization-file "$inner" --dry-run --in-memory-build) >"$applied"
  objects="$(yq -N 'select(. != null) | .kind + " " + (.spec.group // "none") + " " + .metadata.name' "$applied" | sort)"
  echo "$objects"
  # Exactly the definitions of Envoy Gateway's own group that the chart ships, not the Gateway
  # API's copy beside them.
  shipped="$(helm show crds "$CHART" | yq -N 'select(.spec.group == "gateway.envoyproxy.io")
    | .kind + " " + .spec.group + " " + .metadata.name' | sort)"
  [ -n "$shipped" ]
  [ "$objects" = "$shipped" ]
}

@test "The Gateway API definitions are a release Envoy Gateway supports" {
  local copy bundled installed missing
  render envoy-gateway
  # The chart's own copy of the Gateway API, which it installs only with its definitions on, is of
  # the release Envoy Gateway is built against.
  copy="$BATS_TEST_TMPDIR/chart-gateway-api.yaml"
  # Without -N, so the definitions stay separate documents.
  helm show crds "$CHART" | yq 'select(.kind == "CustomResourceDefinition" and .spec.group == "gateway.networking.k8s.io")' >"$copy"
  bundled="$(yq -N '.metadata.annotations["gateway.networking.k8s.io/bundle-version"]' "$copy" | sort -u)"
  gateway_api
  installed="$(yq -N 'select(. != null) | .metadata.annotations["gateway.networking.k8s.io/bundle-version"]' "$GATEWAY_API" | sort -u)"
  echo "the chart is built against $bundled; the repository installs $installed"
  [[ $bundled =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
  [[ $installed =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
  [ "${bundled%%.*}" = "${installed%%.*}" ]
  [ "$(printf '%s\n' "$bundled" "$installed" | sort -V | head -n 1)" = "$bundled" ]
  # A newer release still serves every stable version of the kinds Envoy Gateway reads.
  missing="$(comm -23 <(stable_served "$copy") <(stable_served "$GATEWAY_API"))"
  echo "stable kinds and versions of the chart's copy that the repository's do not serve: ${missing:-none}"
  [ -n "$(stable_served "$copy")" ]
  [ -z "$missing" ]
}

@test "Envoy Gateway's controller keeps running through a node drain" {
  local deployment replicas labels spread budget minimum config
  render envoy-gateway
  deployment='select(.kind == "Deployment" and .metadata.name == "envoy-gateway")'
  replicas="$(yq -N "$deployment | .spec.replicas" "$RENDERED")"
  labels="$(yq -N -o json -I0 "$deployment | .spec.template.metadata.labels" "$RENDERED")"
  echo "replicas: $replicas; pod labels: $labels"
  [ "$replicas" -ge 2 ]
  # Never two of the controller's pods on one node.
  spread="$(yq -N -o json -I0 "$deployment | .spec.template.spec.topologySpreadConstraints // [] | .[]
    | select(.topologyKey == \"kubernetes.io/hostname\" and .whenUnsatisfiable == \"DoNotSchedule\" and .maxSkew == 1)
    | .labelSelector.matchLabels" "$RENDERED")"
  echo "spread over nodes by: ${spread:-nothing}"
  [ -n "$spread" ]
  selects "$spread" "$labels"
  # A drain evicts the controller's pods only while another keeps running.
  budget="$(yq -N -o json -I0 'select(.kind == "PodDisruptionBudget") | .spec' "$RENDERED")"
  echo "disruption budget: ${budget:-none}"
  [ -n "$budget" ]
  selects "$(yq -o json -I0 '.selector.matchLabels' <<<"$budget")" "$labels"
  minimum="$(yq '.minAvailable' <<<"$budget")"
  [ "$minimum" -ge 1 ]
  [ "$minimum" -lt "$replicas" ]
  # Leader election, on unless the configuration turns it off, lets one replica act at a time.
  config="$(envoy_gateway_config)"
  [ -n "$config" ]
  [ "$(yq '.provider.kubernetes.leaderElection.disable // false' <<<"$config")" = false ]
}

@test "Everything Envoy Gateway runs meets its namespace's Pod Security level" {
  local level workloads violations
  app_dir envoy-gateway
  level="$(yq '.metadata.labels["pod-security.kubernetes.io/enforce"]' "$REPO/${APP_DIR%/*}/namespace.yaml")"
  echo "enforced level: $level"
  [ "$level" = restricted ]
  render envoy-gateway
  workloads='select(.kind == "Deployment" or .kind == "DaemonSet" or .kind == "StatefulSet" or .kind == "Job")'
  echo "pod templates: $(yq -N "$workloads | .kind + \"/\" + .metadata.name" "$RENDERED" | paste -sd' ' -)"
  [ -n "$(yq -N "$workloads | .metadata.name" "$RENDERED")" ]
  # The restricted level's rules, for each pod template and each of its containers: the pod's
  # securityContext supplies runAsNonRoot, runAsUser and the seccomp profile where a container
  # sets none. Each rule is a {bad, why} pair, as yq yields an expression without a path even
  # after a select that matched nothing.
  # shellcheck disable=SC2016 # $workload, $pod, $c, $where and $profile are yq variables.
  violations="$(yq -N "$workloads"' | (.kind + "/" + .metadata.name) as $workload | .spec.template.spec as $pod
    | [
        {"bad": (($pod | .hostNetwork) == true or ($pod | .hostPID) == true or ($pod | .hostIPC) == true),
         "why": $workload + " shares a host namespace"},
        {"bad": (($pod | .volumes // []) | any_c(has("hostPath"))), "why": $workload + " mounts a host path"}
      ] + [
        (($pod | .containers // []) + ($pod | .initContainers // [])) | .[]
          | (.securityContext // {}) as $c | ($workload + " container " + .name) as $where
          | (($c | .seccompProfile.type) // ($pod | .securityContext.seccompProfile.type) // "none") as $profile
          | (
              {"bad": (($c | .privileged) == true), "why": $where + " is privileged"},
              {"bad": (($c | .allowPrivilegeEscalation) != false), "why": $where + " allows privilege escalation"},
              {"bad": (($c | .capabilities.drop // []) | any_c(. == "ALL") | not), "why": $where + " keeps its capabilities"},
              {"bad": (($c | .capabilities.add // []) - ["NET_BIND_SERVICE"] | length > 0), "why": $where + " adds capabilities"},
              {"bad": (($c | .runAsNonRoot) == false or (($c | .runAsNonRoot) // ($pod | .securityContext.runAsNonRoot)) != true),
               "why": $where + " may run as root"},
              {"bad": ((($c | .runAsUser) // ($pod | .securityContext.runAsUser)) == 0), "why": $where + " runs as user 0"},
              {"bad": ($profile != "RuntimeDefault" and $profile != "Localhost"), "why": $where + " has no seccomp profile"}
            )
      ]
    | .[] | select(.bad) | .why' "$RENDERED")"
  echo "violations: ${violations:-none}"
  [ -z "$violations" ]
}

@test "Envoy Gateway has a GatewayClass and no Gateway" {
  local app overlay enabled dependencies controller classes
  # Both applications run in the cluster: its overlay applies their Kustomizations.
  overlay="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "$REPO/kubernetes/apps/overlays/lab-sto2" >"$overlay"
  for app in envoy-gateway-crds envoy-gateway; do
    enabled="$(yq -N "select(.kind == \"Kustomization\" and .metadata.name == \"$app\") | .spec.path" "$overlay")"
    echo "$app in the overlay: ${enabled:-none}"
    app_dir "$app"
    [ "$enabled" = "./${APP_DIR#kubernetes/}/app" ]
  done
  # The controller starts, and the GatewayClass is applied, once both sets of definitions are
  # established.
  dependencies="$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "envoy-gateway") | .spec.dependsOn // [] | .[].name' "$overlay" | sort | paste -sd' ' -)"
  echo "envoy-gateway depends on: ${dependencies:-nothing}"
  [[ " $dependencies " == *" envoy-gateway-crds "* ]]
  [[ " $dependencies " == *" gateway-api-crds "* ]]
  render envoy-gateway
  controller="$(envoy_gateway_config | yq '.gateway.controllerName')"
  classes="$(yq -N 'select(.kind == "GatewayClass") | .metadata.name + " " + .spec.controllerName' "$BUILT" "$RENDERED")"
  echo "the controller's name: $controller; GatewayClasses: ${classes:-none}"
  [[ $controller =~ ^[a-z0-9.-]+/[A-Za-z0-9._/-]+$ ]]
  [ -n "$classes" ]
  [ "$(wc -l <<<"$classes")" -eq 1 ]
  [ "${classes#* }" = "$controller" ]
  # No Gateway yet: each needs a load balancer and a certificate.
  [ -z "$(yq -N 'select(.kind == "Gateway") | .metadata.name' "$BUILT" "$RENDERED")" ]
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

@test "every values key of cert-manager is one its pinned chart defines" {
  defined_keys cert-manager
}

@test "every values key of envoy-gateway is one its pinned chart defines" {
  defined_keys envoy-gateway
}
