#!/usr/bin/env bats
# Proves features/cilium.feature; each test carries its scenario's title.
# The chart tests pull the pinned chart from its public registry with the pinned helm. The install
# script runs against recording fakes of helm, kubectl and sleep put first on its PATH, so nothing
# reaches a cluster.

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

# deployed_helm VALUES: helm as it answers once the release runs the pinned chart version with the
# values in VALUES, printed the way helm prints them: as JSON or as YAML without comments.
deployed_helm() {
  cp -- "$1" "$STATE/deployed-values.yaml"
  yq '.spec.ref.tag' "$APP/ocirepository.yaml" >"$STATE/deployed-version"
  fake helm <<'EOF'
version=$(cat "$STATE/deployed-version")
case $1 in
  list) echo "[{\"name\":\"cilium\",\"namespace\":\"kube-system\",\"revision\":\"1\",\"status\":\"deployed\",\"chart\":\"cilium-$version\",\"app_version\":\"$version\"}]" ;;
  get)
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
