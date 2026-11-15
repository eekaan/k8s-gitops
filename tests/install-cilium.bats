#!/usr/bin/env bats
# Proves features/cilium.feature; each test carries its scenario's title.
# The chart tests pull the pinned chart from its public registry with the pinned helm. The install
# script runs against recording fakes of helm, kubectl and sleep put first on its PATH, so nothing
# reaches a cluster. The BGP tests work on a copy of the tree: they render talman.yaml from the Talos
# fixture as the cluster stack does, fill cluster-config from it with the copy's own
# scripts/lib/cluster.sh, build every application as Flux applies it, and render the nodes' machine
# configurations offline with scripts/talos-check.

# The tests run one at a time even where bats runs a file's tests side by side: flux build rewrites
# the application's kustomization.yaml in this checkout and puts it back afterwards, so two builds
# at once can leave the rewritten file behind.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO/scripts/install-cilium"
  APP="$REPO/kubernetes/apps/base/kube-system/cilium/app"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  # The fakes record every call in $CALLS and keep what they need between calls in $STATE.
  export CALLS="$BATS_TEST_TMPDIR/calls" STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STATE"
  : >"$CALLS"
  # A kubeconfig the fakes never read, and no in-cluster address for anything else to find.
  export KUBECONFIG="$BATS_TEST_TMPDIR/kubeconfig"
  : >"$KUBECONFIG"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# fake NAME: a binary first on the script's PATH that records its call as one line, the name and
# its arguments, in $CALLS, then runs the body read from stdin.
fake() {
  {
    echo '#!/usr/bin/env bash'
    # shellcheck disable=SC2016 # Expanded when the fake runs.
    echo 'echo "${0##*/} $*" >>"$CALLS"'
    cat
  } >"$BIN/$1"
  chmod +x "$BIN/$1"
}

# recording_tools [N]: a cluster whose API server answers on the Nth attempt (the first by
# default), with no Cilium release yet, whose nodes all become Ready; sleep returns at once.
recording_tools() {
  echo "${1:-1}" >"$STATE/readyz-answers-on"
  fake sleep </dev/null
  fake kubectl <<'EOF'
if [[ $* == */readyz* ]]; then
  n=$(($(cat "$STATE/readyz-calls" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$STATE/readyz-calls"
  if ((n < $(cat "$STATE/readyz-answers-on"))); then
    echo "The connection to the server was refused" >&2
    exit 1
  fi
  echo ok
fi
EOF
  fake helm <<'EOF'
case $1 in
  list) echo '[]' ;;
  get | status | history)
    echo "Error: release: not found" >&2
    exit 1
    ;;
  upgrade)
    printf '%s\n' "$@" >"$STATE/helm-upgrade-args"
    # The values file as helm would read it, wherever the script put it.
    while (($#)); do
      case $1 in
        -f | --values) cp -- "$2" "$STATE/helm-values.yaml" ;;
        --values=*) cp -- "${1#*=}" "$STATE/helm-values.yaml" ;;
      esac
      shift
    done
    ;;
esac
EOF
}

# deployed_helm VALUES [MANIFEST]: helm as it answers once the release runs the pinned chart version
# with the values in VALUES, printed the way helm prints them: as JSON or as YAML without comments;
# and with the objects in MANIFEST, or one object without labels, as the release's manifest.
deployed_helm() {
  cp -- "$1" "$STATE/deployed-values.yaml"
  if [[ -n ${2-} ]]; then
    cp -- "$2" "$STATE/deployed-manifest.yaml"
  else
    printf -- '---\napiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: cilium\n  namespace: kube-system\n' \
      >"$STATE/deployed-manifest.yaml"
  fi
  yq '.spec.ref.tag' "$APP/ocirepository.yaml" >"$STATE/deployed-version"
  fake helm <<'EOF'
version=$(cat "$STATE/deployed-version")
case $1 in
  list) echo "[{\"name\":\"cilium\",\"namespace\":\"kube-system\",\"revision\":\"1\",\"status\":\"deployed\",\"chart\":\"cilium-$version\",\"app_version\":\"$version\"}]" ;;
  get)
    if [[ $2 == manifest ]]; then
      cat "$STATE/deployed-manifest.yaml"
      exit
    fi
    if [[ $* == *json* ]]; then
      yq -o json '.' "$STATE/deployed-values.yaml"
    else
      yq -P 'sort_keys(..) | ... comments = ""' "$STATE/deployed-values.yaml"
    fi
    ;;
  upgrade) ;;
esac
EOF
}

# install: runs the install script with the fakes first on its PATH.
install() {
  run env PATH="$BIN:$PATH" "$SCRIPT"
  echo "$output"
}

# upgrade_flag FLAG...: the value the recorded helm upgrade got for the first of FLAG... it was
# given, as "FLAG VALUE" or "FLAG=VALUE".
upgrade_flag() {
  local args i flag
  mapfile -t args <"$STATE/helm-upgrade-args"
  for ((i = 0; i < ${#args[@]}; i++)); do
    for flag in "$@"; do
      if [[ ${args[i]} == "$flag" ]]; then
        echo "${args[i + 1]}"
        return 0
      elif [[ ${args[i]} == "$flag="* ]]; then
        echo "${args[i]#*=}"
        return 0
      fi
    done
  done
  return 1
}

# upgrade_operands: the release and the chart the recorded helm upgrade got, one per line.
upgrade_operands() {
  local args i
  mapfile -t args <"$STATE/helm-upgrade-args"
  for ((i = 1; i < ${#args[@]}; i++)); do
    case ${args[i]} in
      -n | --namespace | --version | -f | --values | --timeout | --kube-context | --set | --set-string | --set-file) i=$((i + 1)) ;;
      -*) ;;
      *) echo "${args[i]}" ;;
    esac
  done
}

# call_line PATTERN: the line number in $CALLS of the first call matching the extended regex.
call_line() {
  grep -n -m1 -E -- "$1" "$CALLS" | cut -d: -f1
}

# chart_ref: sets url and tag to the chart location and version in ocirepository.yaml.
chart_ref() {
  url="$(yq -e '.spec.url' "$APP/ocirepository.yaml")"
  tag="$(yq -e '.spec.ref.tag' "$APP/ocirepository.yaml")"
}

@test "The chart renders with the repository's values" {
  chart_ref
  kube="$(yq -e '.kubernetes' "$REPO/versions.yaml")"
  render="$BATS_TEST_TMPDIR/render.yaml"

  # With the ServiceMonitor API present, so that only the values can keep the monitors out.
  helm template cilium "$url" --version "$tag" --namespace kube-system --kube-version "$kube" \
    --api-versions monitoring.coreos.com/v1 --values "$APP/values.yaml" >"$render"

  # Cilium serves Services itself, and every container told where the API server is reaches it
  # through KubePrism on its own node rather than through the kubernetes Service.
  [ "$(yq 'select(.kind == "ConfigMap" and .metadata.name == "cilium-config") | .data["kube-proxy-replacement"]' "$render")" = true ]
  # shellcheck disable=SC2016 # $workload is a yq variable.
  endpoints="$(yq -N 'select(.kind == "DaemonSet" or .kind == "Deployment") | (.kind + "/" + .metadata.name) as $workload
    | .spec.template.spec | (.initContainers // []) + .containers | .[]
    | select((.env // []) | any_c(.name == "KUBERNETES_SERVICE_HOST"))
    | $workload + " " + .name + " " + (.env[] | select(.name == "KUBERNETES_SERVICE_HOST") | .value)
      + ":" + (.env[] | select(.name == "KUBERNETES_SERVICE_PORT") | .value)' "$render")"
  echo "$endpoints"
  grep -qxF 'DaemonSet/cilium cilium-agent localhost:7445' <<<"$endpoints"
  grep -qxF 'Deployment/cilium-operator cilium-operator localhost:7445' <<<"$endpoints"
  [ "$(grep -vc ' localhost:7445$' <<<"$endpoints")" -eq 0 ]
  [ -z "$(yq 'select(.kind == "ServiceMonitor") | .metadata.name' "$render")" ]
}

@test "every key in values.yaml is one the pinned chart defines" {
  chart_ref
  # The dotted path of every key, without descending into lists.
  # shellcheck disable=SC2016 # $p is a yq variable.
  keys='.. | select(tag == "!!map") | path as $p | keys | .[] | $p + [.] | join(".")'

  helm show values "$url" --version "$tag" >"$BATS_TEST_TMPDIR/chart-values.yaml"

  unknown="$(comm -23 <(yq "$keys" "$APP/values.yaml" | sort -u) \
    <(yq "$keys" "$BATS_TEST_TMPDIR/chart-values.yaml" | sort -u))"
  echo "keys the chart does not define: ${unknown:-none}"
  [ -z "$unknown" ]
}

@test "The install script uses the chart and values Flux uses" {
  recording_tools

  install

  [ "$status" -eq 0 ]
  chart_ref
  grep -qxE -- '--install|-i' "$STATE/helm-upgrade-args"
  [ "$(upgrade_operands)" = "cilium"$'\n'"$url" ]
  [ "$(upgrade_flag --version)" = "$tag" ]
  [ "$(upgrade_flag -n --namespace)" = kube-system ]
  cmp "$STATE/helm-values.yaml" "$APP/values.yaml"
  # Those values only: no second file, no value set on the command line, none kept from before.
  [ "$(grep -cE -- '^(-f|--values)(=|$)' "$STATE/helm-upgrade-args")" -eq 1 ]
  [ "$(grep -cE -- '^--(set|set-[a-z]+|reuse-values|reset-then-reuse-values)(=|$)' "$STATE/helm-upgrade-args")" -eq 0 ]
}

@test "The install script waits for the API server and the nodes" {
  recording_tools 3

  install

  [ "$status" -eq 0 ]
  [ "$(grep -c '^kubectl .*/readyz' "$CALLS")" -eq 3 ]
  answered="$(grep -n '^kubectl .*/readyz' "$CALLS" | tail -1 | cut -d: -f1)"
  installed="$(call_line '^helm upgrade ')"
  nodes="$(grep -n '^kubectl wait ' "$CALLS" | grep -E ' nodes?( |$)' | grep -F -e ' --all' |
    grep -F 'condition=Ready' | head -1 | cut -d: -f1)"
  [ -n "$installed" ] && [ -n "$nodes" ]
  [ "$answered" -lt "$installed" ]
  [ "$installed" -lt "$nodes" ]
}

@test "A failing install names the step" {
  recording_tools
  fake helm <<'EOF'
case $1 in
  list) echo '[]' ;;
  upgrade)
    echo "Error: stand-in for a failed install" >&2
    exit 1
    ;;
esac
EOF

  install

  [ "$status" -ne 0 ]
  [[ $output == *"stand-in for a failed install"* ]]
  [ "${lines[-1]}" = "install-cilium: failed while installing the chart" ]
  [ "$(grep -c '^kubectl wait ' "$CALLS")" -eq 0 ]
}

@test "Flux adopts the installed release" {
  recording_tools
  built="$BATS_TEST_TMPDIR/built.yaml"
  # The HelmRelease as Flux applies it: built from the application's Kustomization, which gives
  # it its namespace. flux build reads only paths below the working directory.
  cd "$REPO"
  flux build kustomization cilium --path ./kubernetes/apps/base/kube-system/cilium/app \
    --kustomization-file ./kubernetes/apps/base/kube-system/cilium/ks.yaml --dry-run >"$built"
  release="$(yq -e 'select(.kind == "HelmRelease") | .spec.releaseName' "$built")"
  # Flux's defaults for the other two are the HelmRelease's own namespace.
  target="$(yq -e 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$built")"
  storage="$(yq -e 'select(.kind == "HelmRelease") | .spec.storageNamespace // .metadata.namespace' "$built")"

  install

  [ "$status" -eq 0 ]
  # helm keeps a release's history in the namespace it installs into.
  [ "$(upgrade_operands | head -1)" = "$release" ]
  [ "$(upgrade_flag -n --namespace)" = "$target" ]
  [ "$(upgrade_flag -n --namespace)" = "$storage" ]
}

@test "Flux installs the chart and values the install script installs" {
  built="$BATS_TEST_TMPDIR/built.yaml"
  # The application as Flux applies it, built from its Kustomization. flux build reads only paths
  # below the working directory.
  cd "$REPO"
  flux build kustomization cilium --path ./kubernetes/apps/base/kube-system/cilium/app \
    --kustomization-file ./kubernetes/apps/base/kube-system/cilium/ks.yaml --dry-run >"$built"
  chart_ref

  # One chart source and one values ConfigMap: no second copy of either.
  [ "$(yq -N 'select(.kind == "OCIRepository") | .metadata.name' "$built" | wc -l)" -eq 1 ]
  [ "$(yq -N 'select(.kind == "ConfigMap") | .metadata.name' "$built" | wc -l)" -eq 1 ]
  # The chart comes from that source, in the HelmRelease's namespace when chartRef names none, at
  # the location and version install-cilium reads.
  source="$(yq -N 'select(.kind == "OCIRepository") | .metadata.namespace + "/" + .metadata.name' "$built")"
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.chartRef.kind' "$built")" = OCIRepository ]
  [ "$(yq -N 'select(.kind == "HelmRelease") | (.spec.chartRef.namespace // .metadata.namespace) + "/" + .spec.chartRef.name' "$built")" = "$source" ]
  [ "$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$built")" = "$url" ]
  [ "$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$built")" = "$tag" ]
  # The values are the generated ConfigMap's whole values.yaml key, helm-controller's default key,
  # and nothing else: no other source, no target path, no values of the HelmRelease's own.
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom | length' "$built")" -eq 1 ]
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0] | .kind + " " + (.valuesKey // "values.yaml") + " " + (.targetPath // "none")' "$built")" = "ConfigMap values.yaml none" ]
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.values // "none"' "$built")" = none ]
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$built")"
  [ "$name" = "$(yq -N 'select(.kind == "ConfigMap") | .metadata.name' "$built")" ]
  # The ConfigMap holds values.yaml byte for byte, the file install-cilium gives helm.
  yq -o json "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\")" "$built" |
    jq -j '.data["values.yaml"]' | cmp - "$APP/values.yaml"
}

@test "a second run against the release it installed changes nothing" {
  recording_tools
  deployed_helm "$APP/values.yaml"

  install

  [ "$status" -eq 0 ]
  [ "$(grep -c '^helm upgrade ' "$CALLS")" -eq 0 ]
  [ -n "$(call_line '^kubectl wait ')" ]
}

@test "a release running other values is upgraded" {
  recording_tools
  printf -- '---\nkubeProxyReplacement: false\n' >"$BATS_TEST_TMPDIR/other-values.yaml"
  deployed_helm "$BATS_TEST_TMPDIR/other-values.yaml"

  install

  [ "$status" -eq 0 ]
  [ "$(grep -c '^helm upgrade ' "$CALLS")" -eq 1 ]
}

@test "An install over a release Flux manages is refused unless asked" {
  recording_tools
  printf -- '---\nkubeProxyReplacement: false\n' >"$BATS_TEST_TMPDIR/other-values.yaml"
  # Objects as helm-controller's post-renderer leaves them, labelled with the HelmRelease.
  cat >"$BATS_TEST_TMPDIR/flux-manifest.yaml" <<'EOF'
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cilium
  namespace: kube-system
  labels:
    helm.toolkit.fluxcd.io/name: cilium
    helm.toolkit.fluxcd.io/namespace: kube-system
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cilium
  namespace: kube-system
  labels:
    app.kubernetes.io/managed-by: Helm
    helm.toolkit.fluxcd.io/name: cilium
    helm.toolkit.fluxcd.io/namespace: kube-system
EOF
  deployed_helm "$BATS_TEST_TMPDIR/other-values.yaml" "$BATS_TEST_TMPDIR/flux-manifest.yaml"

  install

  [ "$status" -ne 0 ]
  [[ $output == *"release cilium in kube-system is managed by Flux's helm-controller"* ]]
  [[ $output == *"--yes"* ]]
  [ "$(grep -c '^helm upgrade ' "$CALLS")" -eq 0 ]
  [ "$(grep -c '^kubectl wait ' "$CALLS")" -eq 0 ]

  run env PATH="$BIN:$PATH" "$SCRIPT" --yes

  [ "$status" -eq 0 ]
  [ "$(grep -c '^helm upgrade ' "$CALLS")" -eq 1 ]
}

@test "install-cilium refuses an argument it does not know before it calls anything" {
  recording_tools

  run env PATH="$BIN:$PATH" "$SCRIPT" --force

  [ "$status" -eq 2 ]
  [[ $output == *"usage: install-cilium [--yes]"* ]]
  [ ! -s "$CALLS" ]
}

@test "an API server that never answers stops the script, naming the step" {
  recording_tools 1000000

  install

  [ "$status" -ne 0 ]
  [ "${lines[-1]}" = "install-cilium: failed while waiting for the API server" ]
  [ "$(grep -c '^helm ' "$CALLS")" -eq 0 ]
}

@test "without KUBECONFIG the script stops before it calls anything" {
  recording_tools
  unset KUBECONFIG

  install

  [ "$status" -ne 0 ]
  [[ $output == *KUBECONFIG* ]]
  [ ! -s "$CALLS" ]
}

# The label a Service opts in with, to an address from the pool and to its advertisement.
OPT_IN='{"k8s-gitops/announce": "bgp"}'

# A jq definition: SELECTOR | selects(LABELS), whether the Kubernetes label selector, absent or
# empty for every object, selects an object with the labels LABELS.
# shellcheck disable=SC2016 # $labels and the rest are jq variables.
SELECTS='def selects($labels): (. // {}) as $s
  | (($s.matchLabels // {}) | to_entries | all(.key as $k | .value as $v | $labels[$k] == $v))
  and (($s.matchExpressions // []) | all(.key as $k | (.values // []) as $vs
    | ($labels | has($k)) as $has | ($has and any($vs[]; . == $labels[$k])) as $in
    | if .operator == "In" then $in
      elif .operator == "NotIn" then ($in | not)
      elif .operator == "Exists" then $has
      elif .operator == "DoesNotExist" then ($has | not)
      else error("unknown operator \(.operator)") end));'

# bgp_tree: a copy, in COPY, of the files git would commit that the BGP checks read: flux build
# rewrites a kustomization.yaml it builds while it runs, and the copy's scripts read nothing of this
# checkout but the copy.
bgp_tree() {
  COPY="$BATS_TEST_TMPDIR/repository"
  local path
  while IFS= read -r -d '' path; do
    if [[ -f $REPO/$path ]]; then
      mkdir -p "$COPY/$(dirname "$path")"
      cp "$REPO/$path" "$COPY/$path"
    fi
  done < <(git -C "$REPO" ls-files -z --cached --others --exclude-standard -- kubernetes scripts talos versions.yaml tests/fixtures/talos infra/openstack/backend.hcl)
}

# bgp_inputs: in the copy, TALMAN, talos/talman.yaml.tftpl rendered from tests/fixtures/talos as the
# cluster stack renders a cluster's talman.yaml, and CONFIG, the data of the ConfigMap
# cluster-config that just cluster-config makes of it, as JSON, made by the copy's own
# scripts/lib/cluster.sh in an environment of its own.
bgp_inputs() {
  local encoded
  bgp_tree
  TALMAN="$BATS_TEST_TMPDIR/talman.yaml"
  encoded=$(tofu -chdir="$COPY/tests/fixtures/talos" console -no-color <<< 'base64encode(local.talman_yaml)')
  base64 -d <<< "${encoded//\"/}" > "$TALMAN"
  CONFIG="$BATS_TEST_TMPDIR/cluster-config.json"
  # shellcheck disable=SC2016 # $1 and $2 are the inner shell's.
  env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" CLUSTER_DOMAIN=example.com BACKUP_BUCKET_PREFIX=marker-backups bash -c \
    '. "$1/scripts/lib/cluster.sh" && fill_cluster_config lab-sto2 "$2" && cluster_config_manifest' _ "$COPY" "$TALMAN" |
    jq '.data' > "$CONFIG"
  [ "$(jq length "$CONFIG")" -gt 0 ]
}

# apps: the copy's applications, as namespace/name, one per line.
apps() {
  (cd "$COPY/kubernetes/apps/base" && find . -mindepth 3 -maxdepth 3 -name ks.yaml) | sed 's|^\./||; s|/ks\.yaml$||' | sort
}

# built APP: the application APP, as namespace/name, as Flux applies it: built in the copy from its
# ks.yaml, substituted strictly from CONFIG and its own postBuild.substitute, one JSON object a line.
built() {
  local ks="$BATS_TEST_TMPDIR/ks-${1//\//-}.yaml" name=${1#*/}
  # shellcheck disable=SC2016 # $config is a yq variable.
  CONFIG=$CONFIG yq '(load(strenv(CONFIG)) | with_entries(.value |= tostring)) as $config
    | .spec.postBuild.substitute = ($config * (.spec.postBuild.substitute // {}))' \
    "$COPY/kubernetes/apps/base/$1/ks.yaml" > "$ks"
  (cd "$COPY/kubernetes" && flux build kustomization "$name" --path "./apps/base/$1/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute --in-memory-build) |
    yq -o json -I0 'select(. != null)'
}

# tree_objects: every object of every application as Flux applies it, one JSON object a line, each
# as {"app": namespace/name, "object": ...}.
tree_objects() {
  local app
  while IFS= read -r app; do
    built "$app" | jq -c --arg app "$app" '{app: $app, object: .}'
  done < <(apps)
}

# chart_config KEY: KEY of the ConfigMap cilium-config the pinned chart renders with values.yaml,
# rendered once per test into RENDER.
chart_config() {
  RENDER="$BATS_TEST_TMPDIR/render.yaml"
  if [[ ! -s $RENDER ]]; then
    chart_ref
    helm template cilium "$url" --version "$tag" --namespace kube-system \
      --kube-version "$(yq -e '.kubernetes' "$REPO/versions.yaml")" --values "$APP/values.yaml" > "$RENDER"
  fi
  yq "select(.kind == \"ConfigMap\" and .metadata.name == \"cilium-config\") | .data[\"$1\"] // \"\"" "$RENDER"
}

@test "Cilium assigns LoadBalancer addresses from exactly the service range" {
  bgp_inputs
  range=$(yq -e '.values.serviceRange' "$TALMAN")
  [ "$(jq -r '.SERVICE_RANGE' "$CONFIG")" = "$range" ]
  [ "$(chart_config enable-lb-ipam)" = true ]
  [ "$(chart_config default-lb-service-ipam)" = lbipam ]
  tree_objects > "$BATS_TEST_TMPDIR/tree.jsonl"

  # One pool in the whole tree, whose one block is the service range, enabled.
  pools=$(jq -c 'select(.object.kind == "CiliumLoadBalancerIPPool") | .object' "$BATS_TEST_TMPDIR/tree.jsonl")
  echo "$pools"
  [ "$(grep -c . <<< "$pools")" -eq 1 ]
  [ "$(jq -c '.spec.blocks' <<< "$pools")" = "[{\"cidr\":\"$range\"}]" ]
  [ "$(jq '.spec.disabled // false' <<< "$pools")" = false ]
  # Only to Services that opt in.
  [ "$(jq --argjson labels "$OPT_IN" "$SELECTS .spec.serviceSelector | selects(\$labels)" <<< "$pools")" = true ]
  for labels in '{}' '{"k8s-gitops/announce": "yes"}' '{"app": "web"}'; do
    [ "$(jq --argjson labels "$labels" "$SELECTS .spec.serviceSelector | selects(\$labels)" <<< "$pools")" = false ]
  done
}

@test "Only workers speak BGP, and they peer with exactly the two edge routers, as the cluster's AS to the edge AS" {
  bgp_inputs
  [ "$(chart_config enable-bgp-control-plane)" = true ]
  # The recipes that take a worker out of BGP read its sessions from the status the agent reports.
  [ "$(chart_config enable-bgp-control-plane-status-report)" = true ]
  tree_objects > "$BATS_TEST_TMPDIR/tree.jsonl"
  configs=$(jq -c 'select(.object.kind == "CiliumBGPClusterConfig") | .object' "$BATS_TEST_TMPDIR/tree.jsonl")
  echo "$configs"
  [ "$(grep -c . <<< "$configs")" -eq 1 ]
  [ -z "$(jq -r 'select(.object.kind == "CiliumBGPNodeConfigOverride" or .object.kind == "CiliumBGPPeeringPolicy") | .object.kind' "$BATS_TEST_TMPDIR/tree.jsonl")" ]

  # The node selector, against the labels each node's machine configuration gives it.
  run "$COPY/scripts/talos-check" "$BATS_TEST_TMPDIR/rendered"
  [ "$status" -eq 0 ]
  selected=() workers=()
  while IFS=' ' read -r node role; do
    labels=$(yq -o json -I0 'select(.kind == "KubeNodeConfig") | .labels // {}' "$BATS_TEST_TMPDIR/rendered/$node.yaml")
    labels=$(jq -c --arg node "$node" '. + {"kubernetes.io/hostname": $node, "kubernetes.io/os": "linux"}' <<< "$labels")
    if [[ $(jq --argjson labels "$labels" "$SELECTS .spec.nodeSelector | selects(\$labels)" <<< "$configs") == true ]]; then
      selected+=("$node")
    fi
    [[ $role != worker ]] || workers+=("$node")
  done < <(yq '.nodes[] | .hostname + " " + .role' "$TALMAN")
  echo "selected: ${selected[*]}; workers: ${workers[*]}"
  [ "${#workers[@]}" -eq 3 ]
  [ "${selected[*]}" = "${workers[*]}" ]

  # One instance, as the cluster's AS, peering with both edge addresses, each in the edge AS.
  cluster_asn=$(yq -e '.values.bgp.clusterASN' "$TALMAN")
  edge_asn=$(yq -e '.values.bgp.edgeASN' "$TALMAN")
  [ "$cluster_asn" != "$edge_asn" ]
  [ "$(jq '.spec.bgpInstances | length' <<< "$configs")" -eq 1 ]
  [ "$(jq '.spec.bgpInstances[0].localASN' <<< "$configs")" = "$cluster_asn" ]
  # No listening port: each worker opens its sessions and accepts none.
  [ "$(jq '.spec.bgpInstances[0].localPort // "none"' <<< "$configs")" = '"none"' ]
  peers=$(jq -r '.spec.bgpInstances[0].peers[] | "\(.peerAddress) \(.peerASN)"' <<< "$configs" | sort)
  [ "$peers" = "$(yq '.values.bgp.edgeAddresses[] | . + " '"$edge_asn"'"' "$TALMAN" | sort)" ]
  [ "$(grep -c . <<< "$peers")" -eq 2 ]
  # Both edge addresses lie on the node subnet, one hop from every worker.
  while read -r address _; do
    jq -en --arg address "$address" --arg subnet "$(yq -e '.values.nodeSubnet' "$TALMAN")" '
      def ip4: split(".") | map(tonumber) | .[0] * 16777216 + .[1] * 65536 + .[2] * 256 + .[3];
      ($subnet | split("/")) as $net | pow(2; 32 - ($net[1] | tonumber)) as $size
      | (($address | ip4) / $size | floor) == (($net[0] | ip4) / $size | floor)'
  done <<< "$peers"

  # Every peer takes the one peer configuration: explicit timers, graceful restart, eBGP's single
  # hop, IPv4 unicast only.
  [ "$(jq -r '[.spec.bgpInstances[0].peers[].peerConfigRef.name] | unique | .[]' <<< "$configs")" = edge ]
  peer_config=$(jq -c 'select(.object.kind == "CiliumBGPPeerConfig" and .object.metadata.name == "edge") | .object' "$BATS_TEST_TMPDIR/tree.jsonl")
  [ -n "$peer_config" ]
  jq -e '.spec.timers | .holdTimeSeconds and .keepAliveTimeSeconds and .connectRetryTimeSeconds' <<< "$peer_config"
  jq -e '.spec.gracefulRestart.enabled == true and .spec.gracefulRestart.restartTimeSeconds > 0' <<< "$peer_config"
  jq -e '(.spec.ebgpMultihop // 1) == 1' <<< "$peer_config"
  [ "$(jq -c '[.spec.families[] | {afi, safi}]' <<< "$peer_config")" = '[{"afi":"ipv4","safi":"unicast"}]' ]
}

@test "A worker carrying the opt-out label is not selected for BGP, and its kubelet cannot remove the label" {
  bgp_inputs
  tree_objects > "$BATS_TEST_TMPDIR/tree.jsonl"
  configs=$(jq -c 'select(.object.kind == "CiliumBGPClusterConfig") | .object' "$BATS_TEST_TMPDIR/tree.jsonl")
  [ "$(grep -c . <<< "$configs")" -eq 1 ]
  # The key the recipes set is the one the selector excludes.
  # shellcheck disable=SC2016 # $1 and $bgp_out_label are the inner shell's.
  key=$(env -i PATH="$PATH" bash -c '. "$1/scripts/lib/cluster.sh" && echo "$bgp_out_label"' _ "$COPY")
  [ -n "$key" ]
  # The NodeRestriction admission plugin stops a kubelet from setting, changing or removing a label
  # under this prefix on its own Node
  # (https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction).
  [[ $key == node-restriction.kubernetes.io/* ]]

  worker='{"kubernetes.io/hostname": "worker-1", "kubernetes.io/os": "linux"}'
  control_plane='{"kubernetes.io/hostname": "cp-1", "kubernetes.io/os": "linux", "node-role.kubernetes.io/control-plane": ""}'
  # selected LABELS: whether the cluster config's node selector selects a node with LABELS.
  selected() {
    jq --argjson labels "$1" "$SELECTS .spec.nodeSelector | selects(\$labels)" <<< "$configs"
  }
  [ "$(selected "$worker")" = true ]
  [ "$(selected "$control_plane")" = false ]
  [ "$(selected "$(jq -c --arg key "$key" '. + {($key): "true"}' <<< "$worker")")" = false ]
  [ "$(selected "$(jq -c --arg key "$key" '. + {($key): ""}' <<< "$worker")")" = false ]
}

@test "Only the addresses of Services that opt in are advertised; pod and ClusterIP ranges never are" {
  bgp_inputs
  tree_objects > "$BATS_TEST_TMPDIR/tree.jsonl"
  # The advertisements the peer configurations select, by their labels.
  # shellcheck disable=SC2016 # $tree and the rest are jq variables.
  advertised=$(jq -nc --slurpfile tree "$BATS_TEST_TMPDIR/tree.jsonl" "$SELECTS"'
    [$tree[] | .object | select(.kind == "CiliumBGPPeerConfig") | .spec.families[].advertisements] as $selectors
    | [$tree[] | .object | select(.kind == "CiliumBGPAdvertisement")
      | . as $ad | select(any($selectors[]; selects($ad.metadata.labels // {})))]')
  echo "$advertised"
  [ "$(jq length <<< "$advertised")" -ge 1 ]
  # Each advertises LoadBalancer addresses of Services, and nothing else.
  [ "$(jq -c '[.[].spec.advertisements[] | {advertisementType, addresses: .service.addresses}] | unique' <<< "$advertised")" = \
    '[{"advertisementType":"Service","addresses":["LoadBalancerIP"]}]' ]
  # Of Services that opt in only.
  # shellcheck disable=SC2016 # $labels is a jq variable.
  [ "$(jq --argjson labels "$OPT_IN" "$SELECTS"' [.[].spec.advertisements[].selector | selects($labels)] | all' <<< "$advertised")" = true ]
  for labels in '{}' '{"k8s-gitops/announce": "yes"}' '{"app": "web"}'; do
    # shellcheck disable=SC2016 # $labels is a jq variable.
    [ "$(jq --argjson labels "$labels" "$SELECTS"' [.[].spec.advertisements[].selector | selects($labels)] | any' <<< "$advertised")" = false ]
  done
  # No advertisement anywhere in the tree is of pods, pod pools, interfaces or other Service addresses.
  [ -z "$(jq -r 'select(.object.kind == "CiliumBGPAdvertisement") | .object.spec.advertisements[]
    | select(.advertisementType != "Service" or (.service.addresses // [] | any(. != "LoadBalancerIP"))) | .advertisementType' \
    "$BATS_TEST_TMPDIR/tree.jsonl")" ]
}

@test "Layer 2 announcements stay off" {
  bgp_inputs
  [ "$(chart_config enable-l2-announcements)" != true ]
  [ "$(chart_config enable-l2-pod-announcements)" != true ]
  [ "$(yq '.l2announcements.enabled' "$APP/values.yaml")" = false ]
  tree_objects > "$BATS_TEST_TMPDIR/tree.jsonl"
  [ -z "$(jq -r 'select(.object.kind == "CiliumL2AnnouncementPolicy") | .app' "$BATS_TEST_TMPDIR/tree.jsonl")" ]
}

@test "A fresh bootstrap still installs Cilium before its own resource definitions exist" {
  recording_tools

  install

  # The script installs the chart and applies nothing besides.
  [ "$status" -eq 0 ]
  [ "$(grep -c '^helm upgrade ' "$CALLS")" -eq 1 ]
  [ "$(grep -cE '^kubectl (apply|create|replace|patch) ' "$CALLS")" -eq 0 ]
  cmp "$STATE/helm-values.yaml" "$APP/values.yaml"

  # The Cilium application holds nothing of Cilium's own kinds, which only its operator defines.
  bgp_inputs
  tree_objects > "$BATS_TEST_TMPDIR/tree.jsonl"
  [ -z "$(jq -r 'select(.app == "kube-system/cilium" and (.object.apiVersion | startswith("cilium.io/"))) | .object.kind' "$BATS_TEST_TMPDIR/tree.jsonl")" ]
  # Every application that does names cilium in dependsOn and is enabled.
  owners=$(jq -r 'select(.object.apiVersion | startswith("cilium.io/")) | .app' "$BATS_TEST_TMPDIR/tree.jsonl" | sort -u)
  echo "applications with Cilium objects: $owners"
  [ -n "$owners" ]
  while IFS= read -r app; do
    [ "$(yq '[.spec.dependsOn[].name] | contains(["cilium"])' "$COPY/kubernetes/apps/base/$app/ks.yaml")" = true ]
    grep -qxF "  - ../../base/$app/ks.yaml" "$COPY/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  done <<< "$owners"
  # The dependency orders them only if the Cilium application is Ready no sooner than its release:
  # it waits, for as long as the release may take, which is longer than the root's default.
  ks="$COPY/kubernetes/apps/base/kube-system/cilium/ks.yaml"
  [ "$(yq '.spec.wait' "$ks")" = true ]
  [ "$(yq '.metadata.labels["k8s-gitops/timeout"]' "$ks")" = long ]
  [ "$(yq '.spec.timeout' "$APP/helmrelease.yaml")" = 10m ]
}
