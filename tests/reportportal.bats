#!/usr/bin/env bats
# Proves features/reportportal.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq, jq and kyverno on PATH (the versions pinned for the repository).
# The chart is pulled once per run from its publisher's Helm repository; building, rendering and the
# evaluations are offline, with the placeholders of the cluster's example key lists.

# The chart is pulled once, by whichever test renders first: so the tests run one at a time.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

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
  NAMESPACE=reportportal
  BASE="$REPO/kubernetes/apps/base/reportportal"
  APP="$BASE/reportportal/app"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  VARS="$BATS_TEST_TMPDIR/example-vars.yaml"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$VARS"
  OVERLAY_DIR="$REPO/kubernetes/apps/overlays/lab-sto2"
}

# overlay [DIR]: the lab-sto2 overlay as Flux reads it. Writes $OVERLAY.
overlay() {
  OVERLAY="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "${1:-$OVERLAY_DIR}" >"$OVERLAY"
}

# with_vars NAME FILE: the Flux Kustomization NAME of FILE, with the example key lists under its own
# substitutions.
with_vars() {
  # shellcheck disable=SC2016 # $vars is a yq variable.
  NAME="$1" yq ea 'select(fileIndex == 0) as $vars
    | select(fileIndex == 1 and .kind == "Kustomization" and .metadata.name == strenv(NAME))
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "$VARS" "$2"
}

# flux_build NAME KS [ROOT]: what the Flux Kustomization in the file KS applies, built from its
# spec.path in the tree ROOT, the checkout's by default, with strict substitution, in memory.
flux_build() {
  local path
  path="$(yq '.spec.path' "$2")"
  (cd "${3:-$REPO}" && flux build kustomization "$1" --path "./kubernetes/${path#./}" \
    --kustomization-file "$2" --dry-run --strict-substitute --in-memory-build)
}

# built NAME: the application NAME as Flux applies it on lab-sto2: the overlay's Kustomization of it
# as the cluster's root patches it, the release defaults among them, built with the example key
# lists under its own substitutions. Writes $BATS_TEST_TMPDIR/NAME-built.yaml, which BUILT names, and
# the Kustomization to KS.
built() {
  local root="$CLUSTER/ks.yaml" path
  ROOT="$BATS_TEST_TMPDIR/root.yaml"
  if [ ! -s "$ROOT" ]; then
    path="$(yq '.spec.path' "$root")"
    (cd "$REPO" && flux build kustomization "$(yq '.metadata.name' "$root")" \
      --path "./kubernetes/${path#./}" --kustomization-file "$root" --dry-run --in-memory-build) >"$ROOT"
  fi
  KS="$BATS_TEST_TMPDIR/$1-ks.yaml"
  with_vars "$1" "$ROOT" >"$KS"
  [ -s "$KS" ] || { echo "the lab-sto2 overlay does not enable $1"; return 1; }
  BUILT="$BATS_TEST_TMPDIR/$1-built.yaml"
  flux_build "$1" "$KS" >"$BUILT"
}

# render: the chart the HelmRelease installs, from the URL of its HelmRepository at the version its
# chart.spec pins, with the values helm-controller gives it (each ConfigMap of valuesFrom in order,
# then spec.values), rendered the way helm-controller renders a release: through Helm's post-render
# step, which takes the hooks with the rest as helm-controller's default strategy hands them to it,
# with a plugin that runs each kustomize post-renderer of the HelmRelease in turn, then the labels
# that name the HelmRelease. Helm merges what the chart renders into one stream with its own reader
# before the post-renderer sees it, and reads the result again, so a document either reader refuses
# fails here as it fails the release. Builds reportportal and sets APP_BUILT, CHART, VALUES (the
# values files in order), RAW (the chart without the post-renderers) and RENDERED.
render() {
  local url chart version release namespace pulled post count i name
  built reportportal
  APP_BUILT="$BUILT"
  url="$(yq -N 'select(.kind == "HelmRepository") | .spec.url' "$APP_BUILT")"
  chart="$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.chart' "$APP_BUILT")"
  version="$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.version' "$APP_BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$APP_BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$APP_BUILT")"
  [ "$release" = reportportal ] && [ "$namespace" = "$NAMESPACE" ] ||
    { echo "the release is $release in $namespace, not reportportal in $NAMESPACE"; return 1; }
  VALUES=()
  count="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom // [] | length' "$APP_BUILT")"
  for ((i = 0; i < count; i++)); do
    name="$(I=$i yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[env(I)].name' "$APP_BUILT")"
    [ "$(I=$i yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[env(I)].kind' "$APP_BUILT")" = ConfigMap ] ||
      { echo "valuesFrom $name is not a ConfigMap"; return 1; }
    VALUES+=("$BATS_TEST_TMPDIR/values-$i.yaml")
    NAME="$name" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .data["values.yaml"]' \
      "$APP_BUILT" >"${VALUES[i]}"
    [ -s "${VALUES[i]}" ] || { echo "no values in the ConfigMap $name the HelmRelease reads"; return 1; }
  done
  VALUES+=("$BATS_TEST_TMPDIR/values-inline.yaml")
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$APP_BUILT" >"$BATS_TEST_TMPDIR/values-inline.yaml"
  pulled="$BATS_FILE_TMPDIR/charts/$chart-$version"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$chart" --repo "$url" --version "$version" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  RAW="$BATS_TEST_TMPDIR/raw.yaml"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" "${VALUES[@]/#/--values=}" >"$RAW"
  post="$BATS_TEST_TMPDIR/post-render"
  rm -rf "$post"
  mkdir -p "$post/steps" "$post/plugins/release"
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.postRenderers // [] | map(select((keys | join(",")) != "kustomize")) | length' "$APP_BUILT")" -eq 0 ] ||
    { echo "the HelmRelease has a post-renderer that is not kustomize"; return 1; }
  count="$(yq -N 'select(.kind == "HelmRelease") | .spec.postRenderers // [] | length' "$APP_BUILT")"
  for ((i = 0; i < count; i++)); do
    I="$i" yq -N -o json 'select(.kind == "HelmRelease") | {"apiVersion": "kustomize.config.k8s.io/v1beta1",
      "kind": "Kustomization", "resources": ["helm-output.yaml"]} + .spec.postRenderers[env(I)].kustomize' "$APP_BUILT" \
      >"$post/steps/$(printf '%03d' "$i").json"
  done
  NAME="$(yq -N 'select(.kind == "HelmRelease") | .metadata.name' "$APP_BUILT")" \
    NS="$(yq -N 'select(.kind == "HelmRelease") | .metadata.namespace' "$APP_BUILT")" \
    yq -n -o json '{"apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization", "resources": ["helm-output.yaml"],
      "labels": [{"pairs": {"helm.toolkit.fluxcd.io/name": strenv(NAME), "helm.toolkit.fluxcd.io/namespace": strenv(NS)}}]}' \
    >"$post/steps/999.json"
  cat >"$post/plugins/release/plugin.yaml" <<'PLUGIN'
name: release
version: 0.0.0
type: postrenderer/v1
apiVersion: v1
runtime: subprocess
runtimeConfig:
  platformCommand:
    - command: ${HELM_PLUGIN_DIR}/run.sh
PLUGIN
  cat >"$post/plugins/release/run.sh" <<'RUN'
#!/usr/bin/env bash
# Helm hands the merged manifests on standard input and reads the result from standard output.
set -euo pipefail
cat >"$POST_RENDER/manifests.yaml"
for step in "$POST_RENDER"/steps/*.json; do
  dir="$POST_RENDER/work/$(basename "$step" .json)"
  mkdir -p "$dir"
  cp "$POST_RENDER/manifests.yaml" "$dir/helm-output.yaml"
  cp "$step" "$dir/kustomization.yaml"
  kustomize build "$dir" >"$POST_RENDER/manifests.yaml"
done
cat "$POST_RENDER/manifests.yaml"
RUN
  chmod +x "$post/plugins/release/run.sh"
  RENDERED="$BATS_TEST_TMPDIR/rendered.yaml"
  POST_RENDER="$post" HELM_PLUGINS="$post/plugins" helm template "$release" "$CHART" --namespace "$namespace" \
    --kube-version "$KUBE" "${VALUES[@]/#/--values=}" --post-renderer release >"$RENDERED"
}

# object FILE KIND NAME: the one object of that kind and name in FILE.
object() {
  KIND="$2" NAME="$3" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$1"
}

# pod_spec FILE KIND NAME: the pod spec of the workload KIND/NAME in FILE, as JSON.
pod_spec() {
  object "$1" "$2" "$3" | yq -o json -I0 'if .kind == "Pod" then .spec else .spec.template.spec end'
}

# workloads FILE: every workload of FILE, as KIND/NAME, sorted.
workloads() {
  yq -N 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob" or .kind == "Pod") | .kind + "/" + .metadata.name' "$1" | LC_ALL=C sort
}

# above FILE TEXT: the line above the first line of FILE that holds TEXT, without its indentation.
above() {
  grep -B1 -F -- "$2" "$1" | head -1 | sed 's/^ *//'
}

# level_failures FILE NAMESPACE LEVEL: what the Pod Security level LEVEL refuses in the pod of the
# workload or pod in FILE in NAMESPACE, by Kyverno's podSecurity rule as pod-security-check runs it:
# writes the failed controls, one per line, to $CONTROLS.
level_failures() {
  local dir
  dir="$BATS_TEST_TMPDIR/level-$3-$(basename "$1" .yaml)"
  rm -rf "$dir"
  mkdir -p "$dir"
  # As JSON: Kyverno reads YAML 1.1, where some unquoted values read as booleans.
  NS="$2" yq -o json 'if .kind == "Pod" then (.metadata.namespace = strenv(NS))
    else {"apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": .metadata.name, "namespace": strenv(NS)} * ((.spec.jobTemplate.spec.template // .spec.template).metadata | pick(["labels"])),
      "spec": (.spec.jobTemplate.spec.template // .spec.template).spec} end' "$1" >"$dir/pod.yaml"
  LEVEL="$3" yq -n '{"apiVersion": "kyverno.io/v1", "kind": "ClusterPolicy", "metadata": {"name": "level"},
    "spec": {"validationFailureAction": "Enforce", "rules": [{"name": "level", "match": {"any": [{"resources": {"kinds": ["Pod"]}}]},
      "validate": {"podSecurity": {"level": strenv(LEVEL), "version": "latest"}}}]}}' >"$dir/policy.yaml"
  # Exit 1 is a failed pod, which is the verdict; the report is the one line that starts with a brace.
  kyverno apply "$dir/policy.yaml" --resource "$dir/pod.yaml" -p --output-format json >"$dir/out" 2>"$dir/err" || [ $? -eq 1 ]
  grep '^{' "$dir/out" >"$dir/report.json"
  jq -e '.results | length == 1 and (.[0].result == "pass" or .[0].result == "fail")' "$dir/report.json" >/dev/null ||
    { echo "Kyverno gave no verdict on the pod: $(cat "$dir/out" "$dir/err")"; return 1; }
  CONTROLS="$dir/controls"
  jq -r '.results[0] | select(.result == "fail") | .properties.controls // "" | split(",") | .[] | select(. != "")' "$dir/report.json" | LC_ALL=C sort >"$CONTROLS"
}

# tree_without PATTERN...: a copy of the tree in $TREE whose overlay lists no resource that matches
# any PATTERN, an extended regular expression.
tree_without() {
  local pattern
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  mkdir -p "$TREE"
  cp -r "$REPO/kubernetes" "$TREE/kubernetes"
  for pattern in "$@"; do
    PATTERN="$pattern" yq -i '.resources |= map(select(test(strenv(PATTERN)) | not))' \
      "$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  done
}

# of_namespace FILE: what an overlay built into FILE holds of ReportPortal and of its namespace,
# sorted, as kind, namespace and name: the namespace itself, any object in it, and any Kustomization
# that deploys into it or from its directory.
of_namespace() {
  yq -N 'select((.kind == "Namespace" and .metadata.name == "reportportal") or .metadata.namespace == "reportportal"
      or .spec.targetNamespace == "reportportal" or ((.spec.path // "") | test("/apps/base/reportportal/")))
    | .kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$1" | LC_ALL=C sort | paste -sd, -
}

# ks_field FILE NAME EXPRESSION: EXPRESSION of the Kustomization NAME in FILE; ks_json the same as
# compact JSON with its keys sorted.
ks_field() {
  NAME="$2" yq -N "select(.kind == \"Kustomization\" and .metadata.name == strenv(NAME)) | $3" "$1"
}
ks_json() {
  NAME="$2" yq -N -o json -I0 "select(.kind == \"Kustomization\" and .metadata.name == strenv(NAME)) | $3" "$1" | jq -cS .
}

# flows DIR FILE...: a directory DIR the flow evaluation reads, holding the objects of each FILE.
flows() {
  local dir=$1 file
  shift
  rm -rf "$dir"
  mkdir -p "$dir"
  for file in "$@"; do
    cp "$file" "$dir/$(basename "$file")"
  done
}

# allowed and denied RENDER FROM TO PORT: assert what the policies of RENDER answer for the flow.
allowed() {
  run "$REPO/scripts/network-policy-check" --reach "$@"
  [ "$status" -eq 0 ] || { echo "expected $* to be allowed: $output"; return 1; }
}
denied() {
  run "$REPO/scripts/network-policy-check" --reach "$@"
  [ "$status" -eq 1 ] || { echo "expected $* to be denied: $output"; return 1; }
}

# admitted and refused RENDER FROM TO PORT: what the ingress of TO answers for the flow alone, for a
# source whose own namespace's default deny would refuse it anyway.
admitted() {
  run "$REPO/scripts/network-policy-check" --reach-ingress "$@"
  [ "$status" -eq 0 ] || { echo "expected $* to be admitted: $output"; return 1; }
}
refused() {
  run "$REPO/scripts/network-policy-check" --reach-ingress "$@"
  [ "$status" -eq 1 ] || { echo "expected $* to be refused: $output"; return 1; }
}

# rule_peers FILE POLICY DIRECTION: each rule of that direction of the CiliumNetworkPolicy POLICY in
# FILE, one per line: its peers, sorted, then its ports, sorted. A peer is an entity as @NAME or the
# labels of a selector as K=V; a field of a rule that is neither a peer of these two forms nor a
# port is printed as it is, so that it never compares equal to what a test expects.
rule_peers() {
  # shellcheck disable=SC2016 # $side and $rule are jq variables.
  object "$1" CiliumNetworkPolicy "$2" | yq -o json -I0 '.' | jq -r --arg side "$3" '
    (if $side == "ingress" then ["fromEntities", "fromEndpoints"] else ["toEntities", "toEndpoints"] end) as $peers
    | (.spec[$side] // [])[] | . as $rule
    | ([($rule[$peers[0]] // [])[] | "@" + .]
       + [($rule[$peers[1]] // [])[] | if (keys - ["matchLabels"] | length) == 0
            then (.matchLabels | to_entries | map(.key + "=" + .value) | sort | join(","))
            else tojson end]
       + [($rule | keys - $peers - ["toPorts"])[] | . + ":" + ($rule[.] | tojson)] | sort | join(" "))
      + " -> "
      + ([($rule.toPorts // [])[] | if (keys - ["ports"] | length) == 0
            then (.ports[] | if (keys - ["port", "protocol"] | length) == 0 then .port + "/" + (.protocol // "ANY") else tojson end)
            else tojson end] | sort | join(" "))'
}

# selector FILE POLICY: the endpoint selector of the CiliumNetworkPolicy POLICY in FILE, as K=V
# sorted and joined by commas, or its JSON when it is not matchLabels alone.
selector() {
  object "$1" CiliumNetworkPolicy "$2" | yq -o json -I0 '.spec.endpointSelector' | jq -r \
    'if (keys - ["matchLabels"] | length) == 0 then (.matchLabels | to_entries | map(.key + "=" + .value) | sort | join(",")) else tojson end'
}

# docs TEXT: whether docs/kubernetes.md holds TEXT, whatever its line breaks.
docs() {
  tr -s "\n " "  " <"$REPO/docs/kubernetes.md" | grep -qF -- "$1" || { echo "docs/kubernetes.md does not say: $1"; return 1; }
}

@test "ReportPortal is selected by overlay entries and builds nothing when it is not" {
  local dependency name
  local -A entry=([cloudnative-pg]='/cnpg-system/cloudnative-pg/ks.yaml$' [plugin-barman-cloud]='/cnpg-system/plugin-barman-cloud/ks.yaml$'
    [prometheus-operator-crds]='/kube-system/prometheus-operator-crds/ks.yaml$' [external-secrets]='/external-secrets/external-secrets/ks.yaml$'
    [openbao-store]='/external-secrets/openbao-store/ks.yaml$' [volsync]='/volsync-system/volsync/ks.yaml$'
    [linstor-cluster]='/piraeus-datastore/linstor-cluster/ks.yaml$' [cilium]='/kube-system/cilium/ks.yaml$'
    [gateway-public]='/envoy-gateway-system/gateway-public/ks.yaml$' [oauth2-proxy]='/sso-system/oauth2-proxy/ks.yaml$'
    [blackbox-exporter]='/monitoring/blackbox-exporter/ks.yaml$' [reportportal]='/reportportal/reportportal/ks.yaml$')
  # Who names each dependency: the route the four of its own, the movers and the application cilium,
  # and the application the rest.
  local -A dependents=([cilium]="reportportal reportportal-volsync-movers" [gateway-public]=reportportal-route
    [oauth2-proxy]=reportportal-route [blackbox-exporter]=reportportal-route [reportportal]=reportportal-route)
  # The overlay selects it with four entries, appended: the namespace directory and the three ks.yaml.
  [ "$(yq '.resources[] | select(test("/reportportal(/|$)"))' "$OVERLAY_DIR/kustomization.yaml" | paste -sd' ' -)" \
    = "../../base/reportportal ../../base/reportportal/reportportal/ks.yaml ../../base/reportportal/reportportal-route/ks.yaml ../../base/reportportal/reportportal-volsync-movers/ks.yaml" ]
  overlay
  [ "$(of_namespace "$OVERLAY")" = ConfigMap/reportportal/app-template-defaults,Kustomization/flux-system/reportportal,Kustomization/flux-system/reportportal-route,Kustomization/flux-system/reportportal-volsync-movers,Namespace/-/reportportal,NetworkPolicy/reportportal/default-deny ]
  # The application: the database and the volume from their components, the long timeout, waits, and
  # names what its objects' kinds and its volume need first.
  [ "$(ks_field "$OVERLAY" reportportal '.spec.components | join(" ")')" = "../../../../../components/cnpg-cluster ../../../../../components/volsync" ]
  [ "$(ks_json "$OVERLAY" reportportal '.spec.postBuild.substitute')" \
    = '{"APP":"reportportal","CNPG_CLUSTER_NAME":"reportportal-db","CNPG_NAMESPACE":"reportportal","CNPG_STORAGE_SIZE":"5Gi","VOLSYNC_CAPACITY":"5Gi","VOLSYNC_CLAIM":"reportportal-shared-volume-claim","VOLSYNC_SCHEDULE":"53 3 * * *"}' ]
  [ "$(ks_field "$OVERLAY" reportportal '.metadata.labels["k8s-gitops/timeout"]')" = long ]
  [ "$(ks_field "$OVERLAY" reportportal '.spec.wait')" = true ]
  [ "$(ks_field "$OVERLAY" reportportal '.spec.targetNamespace')" = "$NAMESPACE" ]
  [ "$(ks_field "$OVERLAY" reportportal '.spec.dependsOn | map(.name) | join(" ")')" \
    = "cloudnative-pg plugin-barman-cloud prometheus-operator-crds external-secrets openbao-store volsync linstor-cluster cilium" ]
  # The route: the sign-in component for the route reportportal at reportportal, waits, and is applied
  # once the application, the Gateway, the sign-in and the prober are Ready.
  [ "$(ks_field "$OVERLAY" reportportal-route '.spec.components | join(" ")')" = "../../../../../components/sso" ]
  [ "$(ks_json "$OVERLAY" reportportal-route '.spec.postBuild.substitute')" = '{"SSO_HOSTNAME":"reportportal","SSO_ROUTE":"reportportal"}' ]
  [ "$(ks_field "$OVERLAY" reportportal-route '.spec.wait')" = true ]
  [ "$(ks_field "$OVERLAY" reportportal-route '.spec.targetNamespace')" = "$NAMESPACE" ]
  [ "$(ks_field "$OVERLAY" reportportal-route '.spec.dependsOn | map(.name) | join(" ")')" = "reportportal gateway-public oauth2-proxy blackbox-exporter" ]
  # The movers' policies, for the policies' kind.
  [ "$(ks_field "$OVERLAY" reportportal-volsync-movers '.spec.dependsOn | map(.name) | join(" ")')" = cilium ]
  [ "$(ks_field "$OVERLAY" reportportal-volsync-movers '.spec.wait')" = true ]
  [ "$(ks_field "$OVERLAY" reportportal-volsync-movers '.spec.targetNamespace')" = "$NAMESPACE" ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # With only the namespace directory's entry, the cluster builds the namespace, its defaults and
  # its default deny, and nothing of ReportPortal.
  tree_without '/reportportal/reportportal(-route|-volsync-movers)?/ks.yaml$'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ "$(of_namespace "$OVERLAY")" = ConfigMap/reportportal/app-template-defaults,Namespace/-/reportportal,NetworkPolicy/reportportal/default-deny ]
  # With none, nothing of the namespace.
  tree_without '/reportportal(/|$)'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ -z "$(of_namespace "$OVERLAY")" ]
  # Selecting it without one of the applications it waits for is refused, naming the Kustomization
  # and the missing application.
  for dependency in "${!entry[@]}"; do
    tree_without "${entry[$dependency]}"
    run "$REPO/scripts/kubernetes-check" "$TREE"
    echo "without $dependency: $output"
    [ "$status" -ne 0 ]
    for name in ${dependents[$dependency]:-reportportal}; do
      [[ $output == *"kubernetes/apps/base/reportportal/$name/ks.yaml: Kustomization $name names $dependency"*"does not enable"* ]] ||
        { echo "not refused naming $name and $dependency"; return 1; }
    done
  done
}

@test "ReportPortal's chart and every image it runs are pinned by version and digest and move together" {
  local version chart_tag dep images tag file rows line switch rule key service row
  render
  # The chart: reportportal 26.11.18 from ReportPortal's classic Helm repository, whose index
  # Renovate's flux manager reads the version by.
  [ "$(yq -N 'select(.kind == "HelmRepository") | .metadata.name + " " + .spec.url' "$APP_BUILT")" = "reportportal https://k8s.reportportal.io" ]
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec | .chart + " " + .version + " " + .sourceRef.kind + "/" + .sourceRef.name' "$APP_BUILT")" \
    = "reportportal 26.11.18 HelmRepository/reportportal" ]
  version="$(tar -xzOf "$CHART" reportportal/Chart.yaml | yq '.version')"
  [ "$version" = 26.11.18 ]
  # The source's row is unsigned, with the reason the other classic repositories have.
  row="$(yq -o json -I0 '.sources[] | select(.source == "https://k8s.reportportal.io")' "$REPO/signatures.yaml")"
  [ "$(jq -r '.signed' <<<"$row")" = unsigned ]
  [ "$(jq -r '.reason' <<<"$row")" = "$(yq '.sources[] | select(.source == "https://ctrliq.github.io/ascender-operator") | .reason' "$REPO/signatures.yaml")" ]
  # Every image of every pod the chart renders, the hook's included, by tag and digest from docker.io,
  # and pulled only when absent: the four ReportPortal images, the ui's copy of its own, k8s-wait-for
  # in the api's and the jobs pod, kubectl in the hook, RabbitMQ, and the busybox of RabbitMQ's chart.
  images="$(yq -N 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "Job" or .kind == "Pod")
    | (.spec.template.spec // .spec) | (.initContainers // []) + .containers | .[] | .image' "$RENDERED" | LC_ALL=C sort -u)"
  echo "images: $images"
  [ "$(grep -c . <<<"$images")" -eq 8 ]
  [ "$(grep -cvE '^docker\.io/[a-z0-9._/-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$' <<<"$images" || true)" -eq 0 ]
  [ "$(sed -E 's/:[^:@]+@sha256:[0-9a-f]{64}$//' <<<"$images" | paste -sd' ' -)" \
    = "docker.io/busybox docker.io/rabbitmq docker.io/rancher/kubectl docker.io/reportportal/k8s-wait-for docker.io/reportportal/migrations docker.io/reportportal/service-api docker.io/reportportal/service-jobs docker.io/reportportal/service-ui" ]
  [ -z "$(yq -N 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "Job" or .kind == "Pod")
    | (.spec.template.spec // .spec) | (.initContainers // []) + .containers | .[] | select((.imagePullPolicy // "IfNotPresent") != "IfNotPresent") | .name' "$RENDERED")" ]
  # The four ReportPortal images at one version, the one the chart's own values name, each under its
  # comment; the ui's copy is the ui's image.
  file="$APP/values.yaml"
  for service in serviceui serviceapi servicejobs migrations; do
    chart_tag="$(tar -xzOf "$CHART" reportportal/values.yaml | KEY="$service" yq '.[strenv(KEY)].image.tag')"
    tag="$(KEY="$service" yq '.[strenv(KEY)].image.tag' "$file")"
    echo "$service: $tag, the chart's $chart_tag"
    [[ $tag =~ ^([0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$ ]]
    [ "${BASH_REMATCH[1]}" = "$chart_tag" ]
    [ "$chart_tag" = "$(tar -xzOf "$CHART" reportportal/values.yaml | yq '.serviceapi.image.tag')" ]
    dep="docker.io/$(tar -xzOf "$CHART" reportportal/values.yaml | KEY="$service" yq '.[strenv(KEY)].image.repository')"
    [ "$(above "$file" "tag: $tag")" = "# renovate: datasource=docker depName=$dep" ]
    # The values name the tag alone: the repository is the chart's, after the global registry.
    [ "$(KEY="$service" yq '.[strenv(KEY)].image | keys | join(" ")' "$file")" = tag ]
  done
  [ "$(yq '.global.imageRegistry' "$file")" = docker.io ]
  [ "$(yq '.serviceui.extraInitContainers[0].image' "$file")" = "docker.io/reportportal/service-ui:$(yq '.serviceui.image.tag' "$file")" ]
  for key in k8sWaitFor:docker.io/reportportal/k8s-wait-for kubectl:docker.io/rancher/kubectl rabbitmq:docker.io/rabbitmq; do
    tag="$(KEY="${key%%:*}" yq '.[strenv(KEY)].image.tag' "$file")"
    [[ $tag =~ ^[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]]
    [ "$(above "$file" "tag: $tag")" = "# renovate: datasource=docker depName=${key#*:}" ]
  done
  [ "$(yq '.k8sWaitFor.image.tag | sub("@.*"; "")' "$file")" = 2.1.7 ]
  [ "$(yq '.kubectl.image.tag | sub("@.*"; "")' "$file")" = "$(tar -xzOf "$CHART" reportportal/values.yaml | yq '.kubectl.image.tag')" ]
  # Each pin extracted by Renovate exactly once: the tags by the custom manager, as the maps name no
  # repository for the helm-values manager to read, the ui's copy, an image: line, by the helm-values
  # manager alone, and the chart by the flux manager.
  rows="$(awk -F'\t' -v f=kubernetes/apps/base/reportportal/reportportal/app/values.yaml '$1 == f { print $2 " " $3 " " $4 }' "$REPO/.renovate/extracted.tsv" | LC_ALL=C sort | paste -sd, -)"
  echo "extracted from values.yaml: $rows"
  [ "$rows" = "helm-values docker.io/reportportal/service-ui -,regex docker.io/rabbitmq tag,regex docker.io/rancher/kubectl tag,regex docker.io/reportportal/k8s-wait-for tag,regex docker.io/reportportal/migrations tag,regex docker.io/reportportal/service-api tag,regex docker.io/reportportal/service-jobs tag,regex docker.io/reportportal/service-ui tag" ]
  [ "$(grep -c '@sha256:' "$file")" -eq 8 ]
  rows="$(awk -F'\t' -v f=kubernetes/apps/base/reportportal/reportportal/app/helmrelease.yaml '$1 == f { print $2 " " $3 " " $4 }' "$REPO/.renovate/extracted.tsv" | paste -sd, -)"
  [ "$rows" = "flux reportportal -" ]
  # One group moves the chart and the four ReportPortal images together; k8s-wait-for, kubectl and
  # RabbitMQ move on their own.
  line="$(grep -n -F '"reportportal", "docker.io/reportportal/service-ui", "docker.io/reportportal/service-api", "docker.io/reportportal/service-jobs", "docker.io/reportportal/migrations"' "$REPO/.renovate/groups.json5" | cut -d: -f1)"
  [ -n "$line" ]
  sed -n "$((line + 1))p" "$REPO/.renovate/groups.json5" | grep -q 'groupName: "ReportPortal"'
  # Nothing of the application merges itself: a rule for every file of it, after the auto-merge
  # switch, so that it wins over the switch.
  switch="$(grep -n -F 'description: "The auto-merge switch' "$REPO/.renovate/automerge.json5" | cut -d: -f1)"
  rule="$(grep -n -F 'matchFileNames: ["kubernetes/apps/base/reportportal/**"]' "$REPO/.renovate/automerge.json5" | cut -d: -f1)"
  [ -n "$switch" ] && [ -n "$rule" ] && [ "$rule" -gt "$switch" ]
  sed -n "$((rule + 1))p" "$REPO/.renovate/automerge.json5" | grep -q 'automerge: false'
  # The tag forms of the seven custom-manager pins, from each registry's listing.
  for dep in docker.io/reportportal/service-ui docker.io/reportportal/service-api docker.io/reportportal/service-jobs docker.io/reportportal/migrations docker.io/reportportal/k8s-wait-for docker.io/rancher/kubectl docker.io/rabbitmq; do
    [ "$(awk -F'\t' -v d="$dep" '$1 == "docker" && $2 == d' "$REPO/.renovate/tag-forms.tsv" | grep -c .)" -eq 1 ] ||
      { echo "no one tag form for $dep"; return 1; }
  done
}

@test "ReportPortal runs the ui, the API, the jobs service and RabbitMQ, and nothing of the analyzer, the search engine, the bundled stores or the paid tier" {
  local file deployment affinity images
  render
  # What runs: three Deployments of one replica each, RabbitMQ, the migrations Job and the hook that
  # deletes it before an upgrade.
  [ "$(workloads "$RENDERED" | paste -sd' ' -)" = "Deployment/reportportal-api Deployment/reportportal-jobs Deployment/reportportal-ui Job/reportportal-migrations Job/reportportal-pre-upgrade-cleanup StatefulSet/reportportal-rabbitmq" ]
  for deployment in reportportal-api reportportal-jobs reportportal-ui; do
    [ "$(object "$RENDERED" Deployment "$deployment" | yq '.spec.replicas')" -eq 1 ]
  done
  [ "$(object "$RENDERED" StatefulSet reportportal-rabbitmq | yq '.spec.replicas')" -eq 1 ]
  [ "$(object "$RENDERED" Job reportportal-pre-upgrade-cleanup | yq '.metadata.annotations["helm.sh/hook"]')" = pre-upgrade ]
  [ "$(object "$RENDERED" Job reportportal-pre-upgrade-cleanup | yq '.spec.template.spec.containers[0].args | join(" ")')" = "delete job reportportal-migrations --ignore-not-found=true" ]
  [ "$(object "$RENDERED" Job reportportal-migrations | yq '.metadata.annotations["helm.sh/hook"] // "none"')" = none ]
  # Helm deletes the hook's Job before it makes it again, not only once it succeeds, so a run that
  # failed or ran over leaves no Job that stops the next upgrade. The chart has the second alone.
  [ "$(object "$RENDERED" Job reportportal-pre-upgrade-cleanup | yq '.metadata.annotations["helm.sh/hook-delete-policy"]')" = before-hook-creation,hook-succeeded ]
  [ "$(object "$RAW" Job reportportal-pre-upgrade-cleanup | yq '.metadata.annotations["helm.sh/hook-delete-policy"]')" = hook-succeeded ]
  # An upgrade, the hook, the migrations and the rollouts after them, has the ten minutes the install
  # has, where helm-controller would give it five.
  [ "$(object "$APP_BUILT" HelmRelease reportportal | yq '[.spec.timeout // "unset", .spec.install.timeout // "unset", .spec.upgrade.timeout // "unset"] | join(" ")')" = "10m 10m unset" ]
  # Every object of the render, by kind and name: no analyzer, OpenSearch, SeaweedFS, MinIO,
  # PostgreSQL, MCP server or paid component, no claim of the chart's, no disruption budget, Ingress,
  # Gateway, HTTPRoute or quota, and no test hook.
  [ "$(yq -N '.kind + "/" + .metadata.name' "$RENDERED" | LC_ALL=C sort | paste -sd' ' -)" \
    = "ConfigMap/reportportal-rabbitmq-config Deployment/reportportal-api Deployment/reportportal-jobs Deployment/reportportal-ui Job/reportportal-migrations Job/reportportal-pre-upgrade-cleanup Role/reportportal-service-manager RoleBinding/reportportal-user-binding Service/reportportal-api Service/reportportal-jobs Service/reportportal-rabbitmq Service/reportportal-rabbitmq-headless Service/reportportal-ui ServiceAccount/reportportal ServiceAccount/reportportal-rabbitmq StatefulSet/reportportal-rabbitmq" ]
  images="$(yq -N '.. | select(tag == "!!map" and has("image")) | .image' "$RENDERED")"
  [ "$(grep -c . <<<"$images")" -ge 8 ]
  [ -z "$(grep -iE 'analyzer|opensearch|seaweedfs|minio|postgres|mcp-server|curl' <<<"$images" || true)" ]
  [ -z "$(yq -N 'select(.metadata.annotations["helm.sh/hook"] == "test" or .metadata.annotations["helm.sh/hook"] == "test-success") | .metadata.name' "$RENDERED")" ]
  # Every object names the release's namespace, as Helm installs it: the chart leaves most of them
  # without one, and the post-renderer writes it, so that the tree's render, which its checks of the
  # routes and the network policies read, holds them where the cluster does. The chart alone names none.
  [ "$(yq -N 'select(.kind != null) | .metadata.namespace // "none"' "$RENDERED" | LC_ALL=C sort -u | paste -sd' ' -)" = reportportal ]
  [ "$(object "$RAW" Deployment reportportal-api | yq '.metadata.namespace // "none"')" = none ]
  [ -z "$(yq -N 'select(.kind == "PersistentVolumeClaim" or .kind == "PodDisruptionBudget" or .kind == "Ingress" or .kind == "HTTPRoute" or .kind == "Gateway" or .kind == "ResourceQuota") | .kind' "$RENDERED")" ]
  # The values that turn each off, and the two that keep the hook and its role on.
  file="$APP/values.yaml"
  [ "$(yq -o json -I0 '[.ingress.enable, .gatewayAPI.enable, .mcp.enabled, .premium.testExecutions.enabled, .premium.scim.enabled, .postgresql.install, .opensearch.install, .seaweedfs.install, .global.pdb.create, .hooks.test.enabled, .hooks.preUpgrade.enabled, .rbac.create]' "$file")" \
    = '[false,false,false,false,false,false,false,false,false,false,true,true]' ]
  # The analyzer, which has no switch, and the chart's claim, which the component's replaces, are
  # deleted by the release's post-renderer; the chart renders them without it.
  [ -n "$(object "$RAW" StatefulSet reportportal-analyzer)" ]
  [ -n "$(object "$RAW" Service reportportal-analyzer)" ]
  [ -n "$(object "$RAW" PersistentVolumeClaim reportportal-shared-volume-claim)" ]
  # shellcheck disable=SC2016 # $patch is kustomize's directive, matched as written.
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.postRenderers[].kustomize.patches[].patch | select(test("\$patch: delete")) | from_yaml | .kind + "/" + .metadata.name' "$APP_BUILT" | LC_ALL=C sort | paste -sd' ' -)" \
    = "PersistentVolumeClaim/reportportal-shared-volume-claim Service/reportportal-analyzer StatefulSet/reportportal-analyzer" ]
  # Files on the filesystem: the api and the jobs service mount the component's claim at /data/storage.
  for deployment in reportportal-api reportportal-jobs; do
    [ "$(pod_spec "$RENDERED" Deployment "$deployment" | jq -c '[.volumes[] | select(.name == "shared-volume") | .persistentVolumeClaim.claimName]')" = '["reportportal-shared-volume-claim"]' ]
    [ "$(pod_spec "$RENDERED" Deployment "$deployment" | jq -r '.containers[0].volumeMounts[] | select(.name == "shared-volume") | .mountPath')" = /data/storage ]
    [ "$(pod_spec "$RENDERED" Deployment "$deployment" | jq -r '.containers[0].env[] | select(.name == "DATASTORE_TYPE" or .name == "DATASTORE_PATH") | .name + "=" + .value' | paste -sd' ' -)" = "DATASTORE_TYPE=filesystem DATASTORE_PATH=/data/storage" ]
    [ "$(object "$RENDERED" Deployment "$deployment" | yq -o json -I0 '.spec.strategy')" = '{"type":"Recreate"}' ]
  done
  # One node for both, as the claim is ReadWriteOnce: the jobs pod requires the api's node, and the
  # api prefers the jobs pod's.
  affinity="$(pod_spec "$RENDERED" Deployment reportportal-jobs | jq -cS '.affinity')"
  [ "$affinity" = '{"podAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"labelSelector":{"matchLabels":{"component":"reportportal-api"}},"topologyKey":"kubernetes.io/hostname"}]}}' ]
  affinity="$(pod_spec "$RENDERED" Deployment reportportal-api | jq -cS '.affinity')"
  [ "$affinity" = '{"podAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[{"podAffinityTerm":{"labelSelector":{"matchLabels":{"component":"reportportal-jobs"}},"topologyKey":"kubernetes.io/hostname"},"weight":100}]}}' ]
  # Requests: the chart's for each of its containers, unchanged; RabbitMQ's set here, with a memory
  # limit; and its volume of 1Gi on the default class.
  [ "$(pod_spec "$RENDERED" Deployment reportportal-api | jq -cS '.containers[0].resources')" = "$(tar -xzOf "$CHART" reportportal/values.yaml | yq -o json -I0 '.serviceapi.resources' | jq -cS .)" ]
  [ "$(pod_spec "$RENDERED" Deployment reportportal-jobs | jq -cS '.containers[0].resources')" = "$(tar -xzOf "$CHART" reportportal/values.yaml | yq -o json -I0 '.servicejobs.resources' | jq -cS .)" ]
  [ "$(pod_spec "$RENDERED" Deployment reportportal-ui | jq -cS '.containers[] | select(.name == "ui") | .resources')" = "$(tar -xzOf "$CHART" reportportal/values.yaml | yq -o json -I0 '.serviceui.resources' | jq -cS .)" ]
  [ "$(pod_spec "$RENDERED" Job reportportal-migrations | jq -cS '.containers[0].resources')" = "$(tar -xzOf "$CHART" reportportal/values.yaml | yq -o json -I0 '.migrations.resources' | jq -cS .)" ]
  [ "$(pod_spec "$RENDERED" StatefulSet reportportal-rabbitmq | jq -cS '.containers[0].resources')" = '{"limits":{"memory":"512Mi"},"requests":{"cpu":"100m","memory":"256Mi"}}' ]
  [ "$(object "$RENDERED" StatefulSet reportportal-rabbitmq | yq -o json -I0 '.spec.volumeClaimTemplates[0].spec' | jq -cS .)" = '{"accessModes":["ReadWriteOnce"],"resources":{"requests":{"storage":"1Gi"}}}' ]
  docs "they are the publisher's and are not measured here"
}

@test "Every pod of ReportPortal runs at the restricted level as a non-root user with a read-only root" {
  local ns workload spec want container
  render
  overlay
  # The namespace enforces restricted, and no exception names it.
  ns="$(KIND=Namespace NAME="$NAMESPACE" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$OVERLAY")"
  [ "$(yq -o json -I0 '.metadata.labels | with_entries(select(.key | test("^pod-security")))' <<<"$ns" | jq -cS .)" = '{"pod-security.kubernetes.io/enforce":"restricted"}' ]
  [ "$(yq '.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"]' <<<"$ns")" = disabled ]
  [ "$(NS="$NAMESPACE" yq '[.exceptions[] | select(.namespace == strenv(NS))] | length' "$REPO/pod-security-exceptions.yaml")" -eq 0 ]
  # Every pod of the render passes restricted, the hook included.
  for workload in $(workloads "$RENDERED"); do
    object "$RENDERED" "${workload%%/*}" "${workload#*/}" >"$BATS_TEST_TMPDIR/workload.yaml"
    level_failures "$BATS_TEST_TMPDIR/workload.yaml" "$NAMESPACE" restricted
    echo "$workload: $(paste -sd' ' "$CONTROLS")"
    [ ! -s "$CONTROLS" ]
  done
  # Each pod's own context: the api and the jobs service as 1000, the ui as nginx's 101, the
  # migrations as the image's nonroot, 65532, and the hook as kubectl's 1000.
  want='{"fsGroup":1000,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":1000,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}'
  [ "$(pod_spec "$RENDERED" Deployment reportportal-api | jq -cS '.securityContext')" = "$want" ]
  [ "$(pod_spec "$RENDERED" Deployment reportportal-jobs | jq -cS '.securityContext')" = "$want" ]
  [ "$(pod_spec "$RENDERED" Deployment reportportal-ui | jq -cS '.securityContext')" = "${want//1000/101}" ]
  [ "$(pod_spec "$RENDERED" Job reportportal-migrations | jq -cS '.securityContext')" = '{"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}' ]
  [ "$(pod_spec "$RENDERED" Job reportportal-pre-upgrade-cleanup | jq -cS '.securityContext')" = '{"runAsGroup":1000,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}' ]
  # Every container and init container of ReportPortal's pods: no privilege escalation, no
  # capability, a read-only root. RabbitMQ's are its chart's, which set the same.
  for workload in Deployment/reportportal-api Deployment/reportportal-jobs Deployment/reportportal-ui Job/reportportal-migrations Job/reportportal-pre-upgrade-cleanup StatefulSet/reportportal-rabbitmq; do
    spec="$(pod_spec "$RENDERED" "${workload%%/*}" "${workload#*/}")"
    while read -r container; do
      echo "$workload $container"
      [ "$(jq -cS --arg c "$container" '(.initContainers // []) + .containers | .[] | select(.name == $c) | .securityContext | {allowPrivilegeEscalation, capabilities, readOnlyRootFilesystem}' <<<"$spec")" \
        = '{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}' ]
    done < <(jq -r '(.initContainers // []) + .containers | .[].name' <<<"$spec")
  done
  # What each writes is an emptyDir: the api /tmp and the audit log's directory; the jobs service
  # /tmp; the ui /tmp, nginx's cache and its html directory.
  [ "$(pod_spec "$RENDERED" Deployment reportportal-api | jq -r '[.volumes[] | select(.emptyDir) | .name] as $e | .containers[0].volumeMounts[] | select(.name as $n | $e | index($n)) | .mountPath' | LC_ALL=C sort | paste -sd' ' -)" = "/tmp /var/log/reportportal" ]
  [ "$(pod_spec "$RENDERED" Deployment reportportal-jobs | jq -r '[.volumes[] | select(.emptyDir) | .name] as $e | .containers[0].volumeMounts[] | select(.name as $n | $e | index($n)) | .mountPath' | LC_ALL=C sort | paste -sd' ' -)" = /tmp ]
  [ "$(pod_spec "$RENDERED" Deployment reportportal-ui | jq -r '[.volumes[] | select(.emptyDir) | .name] as $e | .containers[] | select(.name == "ui") | .volumeMounts[] | select(.name as $n | $e | index($n)) | .mountPath' | LC_ALL=C sort | paste -sd' ' -)" = "/tmp /usr/share/nginx/html /var/cache/nginx" ]
  # The html directory, which the image's entrypoint writes config.json into, is filled before nginx
  # starts by an init container of the ui's own image, as the ui's user.
  spec="$(pod_spec "$RENDERED" Deployment reportportal-ui)"
  [ "$(jq -r '.initContainers | map(.name) | join(" ")' <<<"$spec")" = copy-html ]
  [ "$(jq -r '.initContainers[0].image' <<<"$spec")" = "$(jq -r '.containers[] | select(.name == "ui") | .image' <<<"$spec")" ]
  [ "$(jq -c '.initContainers[0].command' <<<"$spec")" = '["cp","-R","/usr/share/nginx/html/.","/html-copy/"]' ]
  [ "$(jq -r '.initContainers[0].volumeMounts[] | .name + " " + .mountPath' <<<"$spec")" = "html /html-copy" ]
  [ "$(jq -r '.containers[] | select(.name == "ui") | .volumeMounts[] | select(.mountPath == "/usr/share/nginx/html") | .name' <<<"$spec")" = html ]
  # The ui and the migrations call no API: no token in their pods. The api and the jobs service keep
  # theirs for k8s-wait-for, the hook for kubectl.
  [ "$(pod_spec "$RENDERED" Deployment reportportal-ui | jq -c '.automountServiceAccountToken')" = false ]
  [ "$(pod_spec "$RENDERED" Job reportportal-migrations | jq -c '.automountServiceAccountToken')" = false ]
  for workload in Deployment/reportportal-api Deployment/reportportal-jobs Job/reportportal-pre-upgrade-cleanup; do
    [ "$(pod_spec "$RENDERED" "${workload%%/*}" "${workload#*/}" | jq -c '.automountServiceAccountToken // "unset"')" = '"unset"' ]
  done
  docs "/var/log/reportportal"
}

@test "ReportPortal's namespace denies traffic by default and lets through only the flows its policies declare" {
  local deny view movers policy reasonless
  local proxy='envoy-gateway-system:app.kubernetes.io/name=envoy,app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,gateway.envoyproxy.io/owning-gateway-name=public,gateway.envoyproxy.io/owning-gateway-namespace=envoy-gateway-system'
  local prometheus='monitoring:app.kubernetes.io/name=prometheus' other='other:app.kubernetes.io/name=app' dns='kube-system:k8s-app=kube-dns'
  local robot='robot:app.kubernetes.io/name=robot,app.kubernetes.io/component=runner' cnpg='cnpg-system:app.kubernetes.io/name=cloudnative-pg'
  local ui=reportportal/Deployment/reportportal-ui api=reportportal/Deployment/reportportal-api jobs=reportportal/Deployment/reportportal-jobs
  local migrations=reportportal/Job/reportportal-migrations hook=reportportal/Job/reportportal-pre-upgrade-cleanup rabbitmq=reportportal/StatefulSet/reportportal-rabbitmq
  local db='reportportal:cnpg.io/cluster=reportportal-db,cnpg.io/instanceName=reportportal-db-1,cnpg.io/podRole=instance,app.kubernetes.io/name=postgresql'
  local pgdump=reportportal/CronJob/reportportal-db-pgdump mover='reportportal:app.kubernetes.io/created-by=volsync'
  local proxy_labels='app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,app.kubernetes.io/name=envoy,gateway.envoyproxy.io/owning-gateway-name=public,gateway.envoyproxy.io/owning-gateway-namespace=envoy-gateway-system,k8s:io.kubernetes.pod.namespace=envoy-gateway-system'
  local dns_rule='k8s:io.kubernetes.pod.namespace=kube-system,k8s:k8s-app=kube-dns -> 53/TCP 53/UDP'
  local instances='{"matchExpressions":[{"key":"cnpg.io/cluster","operator":"Exists"}],"matchLabels":{"cnpg.io/podRole":"instance"}} -> 5432/TCP'
  local rabbitmq_labels='app.kubernetes.io/instance=reportportal,app.kubernetes.io/name=rabbitmq'
  render
  overlay
  built reportportal-volsync-movers
  movers="$BUILT"
  built envoy-gateway
  # The namespace holds the default deny, every pod and both directions with no rule, and is not
  # listed among the namespaces without one.
  deny="$(yq -N -o json -I0 'select(.kind == "NetworkPolicy" and .metadata.namespace == "reportportal")' "$OVERLAY")"
  [ "$(jq -cS '[.metadata.name, .spec]' <<<"$deny")" = '["default-deny",{"podSelector":{},"policyTypes":["Ingress","Egress"]}]' ]
  [ "$(NS="$NAMESPACE" yq '[.exceptions[] | select(.namespace == strenv(NS))] | length' "$REPO/network-policy-exceptions.yaml")" -eq 0 ]
  # The policies: one for each of ReportPortal's pods, by the chart's component label, RabbitMQ's by
  # its chart's selector labels, the database's as Backstage's, and the movers'.
  [ "$(yq -N 'select(.kind == "CiliumNetworkPolicy" or .kind == "NetworkPolicy" or .kind == "CiliumClusterwideNetworkPolicy") | .kind + "/" + .metadata.name' "$APP_BUILT" "$RENDERED" "$movers" | LC_ALL=C sort | paste -sd' ' -)" \
    = "CiliumNetworkPolicy/reportportal-api CiliumNetworkPolicy/reportportal-db CiliumNetworkPolicy/reportportal-db-full-recovery-world CiliumNetworkPolicy/reportportal-db-instances CiliumNetworkPolicy/reportportal-db-instances-world CiliumNetworkPolicy/reportportal-db-pgdump CiliumNetworkPolicy/reportportal-db-pgdump-world CiliumNetworkPolicy/reportportal-jobs CiliumNetworkPolicy/reportportal-migrations CiliumNetworkPolicy/reportportal-pre-upgrade-cleanup CiliumNetworkPolicy/reportportal-rabbitmq CiliumNetworkPolicy/reportportal-ui CiliumNetworkPolicy/volsync-movers CiliumNetworkPolicy/volsync-movers-object-storage" ]
  for policy in $(yq -N 'select(.kind == "CiliumNetworkPolicy") | .metadata.name' "$APP_BUILT" "$movers"); do
    [ "$(yq -N -o json -I0 "select(.kind == \"CiliumNetworkPolicy\" and .metadata.name == \"$policy\") | .spec.enableDefaultDeny" "$APP_BUILT" "$movers" | jq -cS .)" = '{"egress":false,"ingress":false}' ]
  done
  for policy in ui api jobs migrations pre-upgrade-cleanup; do
    [ "$(selector "$APP_BUILT" "reportportal-$policy")" = "component=reportportal-$policy" ]
    [ "$(selector "$APP_BUILT" "reportportal-$policy")" = "$(yq -N -o json -I0 "select(.metadata.name == \"reportportal-$policy\" and (.kind == \"Deployment\" or .kind == \"Job\")) | .spec.template.metadata.labels" "$RENDERED" | jq -r 'to_entries | map(.key + "=" + .value) | sort | join(",")')" ]
  done
  [ "$(selector "$APP_BUILT" reportportal-rabbitmq)" = "$rabbitmq_labels" ]
  [ "$(selector "$APP_BUILT" reportportal-rabbitmq)" = "$(object "$RENDERED" StatefulSet reportportal-rabbitmq | yq -o json -I0 '.spec.selector.matchLabels' | jq -r 'to_entries | map(.key + "=" + .value) | sort | join(",")')" ]
  # Each rule, by policy. The ui takes the proxies and the kubelet's probes on 8080 and sends nothing.
  [ "$(pod_spec "$RENDERED" Deployment reportportal-ui | jq -r '[.containers[] | select(.name == "ui") | (.startupProbe, .readinessProbe, .livenessProbe) | .httpGet.port] | unique | join(" ")')" = 8080 ]
  [ "$(rule_peers "$APP_BUILT" reportportal-ui ingress | LC_ALL=C sort)" = "$(printf '%s\n' "@host -> 8080/TCP" "$proxy_labels -> 8080/TCP" | LC_ALL=C sort)" ]
  [ -z "$(rule_peers "$APP_BUILT" reportportal-ui egress)" ]
  # The api takes the proxies and the kubelet's probes on 8585, and reaches the resolver, the
  # database's instances, RabbitMQ's AMQP and management ports, the jobs service and the API server,
  # for its k8s-wait-for.
  [ "$(pod_spec "$RENDERED" Deployment reportportal-api | jq -r '[.containers[0] | (.startupProbe, .readinessProbe, .livenessProbe) | .httpGet.port] | unique | join(" ")')" = 8585 ]
  [ "$(rule_peers "$APP_BUILT" reportportal-api ingress | LC_ALL=C sort)" = "$(printf '%s\n' "@host -> 8585/TCP" "$proxy_labels -> 8585/TCP" | LC_ALL=C sort)" ]
  [ "$(rule_peers "$APP_BUILT" reportportal-api egress | LC_ALL=C sort)" = "$(printf '%s\n' "$dns_rule" "$instances" "$rabbitmq_labels -> 15672/TCP 5672/TCP" \
    "component=reportportal-jobs -> 8686/TCP" "@kube-apiserver -> 443/TCP 6443/TCP" | LC_ALL=C sort)" ]
  # The next story admits Robot's run pods by one rule appended to the api's ingress: the api's
  # policy is the file's last document and its ingress the policy's last key.
  [ "$(yq -N '.metadata.name' "$APP/ciliumnetworkpolicy.yaml" | tail -1)" = reportportal-api ]
  [ "$(yq -N 'select(.metadata.name == "reportportal-api") | .spec | keys | .[-1]' "$APP/ciliumnetworkpolicy.yaml")" = ingress ]
  # The jobs service takes the api and the kubelet's probes on 8686, and reaches the resolver, the
  # database, RabbitMQ and the API server.
  [ "$(pod_spec "$RENDERED" Deployment reportportal-jobs | jq -r '.containers[0].ports[] | select(.name == "jobscore") | .containerPort')" = 8686 ]
  [ "$(rule_peers "$APP_BUILT" reportportal-jobs ingress | LC_ALL=C sort)" = "$(printf '%s\n' "@host -> 8686/TCP" "component=reportportal-api -> 8686/TCP" | LC_ALL=C sort)" ]
  [ "$(rule_peers "$APP_BUILT" reportportal-jobs egress | LC_ALL=C sort)" = "$(printf '%s\n' "$dns_rule" "$instances" "$rabbitmq_labels -> 15672/TCP 5672/TCP" \
    "@kube-apiserver -> 443/TCP 6443/TCP" | LC_ALL=C sort)" ]
  # The migrations reach the resolver and the database; the hook the API server alone.
  [ "$(rule_peers "$APP_BUILT" reportportal-migrations egress | LC_ALL=C sort)" = "$(printf '%s\n' "$dns_rule" "$instances" | LC_ALL=C sort)" ]
  [ -z "$(rule_peers "$APP_BUILT" reportportal-migrations ingress)" ]
  [ "$(rule_peers "$APP_BUILT" reportportal-pre-upgrade-cleanup egress)" = "@kube-apiserver -> 443/TCP 6443/TCP" ]
  [ -z "$(rule_peers "$APP_BUILT" reportportal-pre-upgrade-cleanup ingress)" ]
  # RabbitMQ takes the api and the jobs service on its two ports and sends nothing.
  [ "$(rule_peers "$APP_BUILT" reportportal-rabbitmq ingress)" = "component=reportportal-api component=reportportal-jobs -> 15672/TCP 5672/TCP" ]
  [ -z "$(rule_peers "$APP_BUILT" reportportal-rabbitmq egress)" ]
  # The database's instances take the api, the jobs service, the migrations and the dump job on 5432,
  # Prometheus on the exporter's port and the kubelet on the status port, as Backstage's do.
  [ "$(rule_peers "$APP_BUILT" reportportal-db-instances ingress | LC_ALL=C sort)" = "$(printf '%s\n' \
    "app.kubernetes.io/instance=reportportal-db,app.kubernetes.io/name=pgdump component=reportportal-api component=reportportal-jobs component=reportportal-migrations -> 5432/TCP" \
    "app.kubernetes.io/name=prometheus,k8s:io.kubernetes.pod.namespace=monitoring -> 9187/TCP" \
    "@host -> 8000/TCP" | LC_ALL=C sort)" ]
  # Each world rule is the one rule of its policy, with its reason; no other policy has a reason.
  reasonless="$(yq -N 'select(.kind == "CiliumNetworkPolicy" and .metadata.annotations["k8s-gitops/network-policy-reason"] == null) | .metadata.name' "$APP_BUILT" "$movers" | LC_ALL=C sort | paste -sd' ' -)"
  [ "$reasonless" = "reportportal-api reportportal-db reportportal-db-instances reportportal-db-pgdump reportportal-jobs reportportal-migrations reportportal-pre-upgrade-cleanup reportportal-rabbitmq reportportal-ui volsync-movers" ]
  # The proxies' egress names the ui on 8080 and the api on 8585 in reportportal, by the namespace's
  # Gateway label.
  [ "$(rule_peers "$BUILT" public-proxy egress | grep -F 'k8s:io.kubernetes.pod.namespace=reportportal' | LC_ALL=C sort)" = "$(printf '%s\n' \
    "component=reportportal-api,k8s:io.cilium.k8s.namespace.labels.k8s-gitops/gateway=public,k8s:io.kubernetes.pod.namespace=reportportal -> 8585/TCP" \
    "component=reportportal-ui,k8s:io.cilium.k8s.namespace.labels.k8s-gitops/gateway=public,k8s:io.kubernetes.pod.namespace=reportportal -> 8080/TCP" | LC_ALL=C sort)" ]
  # The flows, evaluated on the namespace's default deny, the policies, the render and the proxies'.
  view="$BATS_TEST_TMPDIR/flows"
  flows "$view" "$OVERLAY" "$APP_BUILT" "$RENDERED" "$movers" "$BUILT"
  # The ui.
  allowed "$view" "$proxy" "$ui" 8080/tcp
  allowed "$view" @host "$ui" 8080/tcp
  denied "$view" "$ui" "$dns" 53/udp
  denied "$view" "$ui" "$api" 8585/tcp
  denied "$view" "$ui" @world 443/tcp
  denied "$view" "$ui" @kube-apiserver 443/tcp
  denied "$view" "$proxy" "$ui" 8585/tcp
  denied "$view" @world "$ui" 8080/tcp
  denied "$view" "$other" "$ui" 8080/tcp
  # The api.
  allowed "$view" "$proxy" "$api" 8585/tcp
  allowed "$view" @host "$api" 8585/tcp
  allowed "$view" "$api" "$dns" 53/udp
  allowed "$view" "$api" "$dns" 53/tcp
  allowed "$view" "$api" "$db" 5432/tcp
  allowed "$view" "$api" "$rabbitmq" 5672/tcp
  allowed "$view" "$api" "$rabbitmq" 15672/tcp
  allowed "$view" "$api" "$jobs" 8686/tcp
  allowed "$view" "$api" @kube-apiserver 443/tcp
  allowed "$view" "$api" @kube-apiserver 6443/tcp
  denied "$view" "$api" @world 443/tcp
  denied "$view" "$api" @world 80/tcp
  denied "$view" "$api" "$ui" 8080/tcp
  denied "$view" "$api" "$rabbitmq" 25672/tcp
  refused "$view" "$robot" "$api" 8585/tcp
  denied "$view" "$other" "$api" 8585/tcp
  denied "$view" @world "$api" 8585/tcp
  denied "$view" "$proxy" "$api" 8080/tcp
  # The jobs service.
  allowed "$view" @host "$jobs" 8686/tcp
  allowed "$view" "$jobs" "$dns" 53/udp
  allowed "$view" "$jobs" "$db" 5432/tcp
  allowed "$view" "$jobs" "$rabbitmq" 5672/tcp
  allowed "$view" "$jobs" "$rabbitmq" 15672/tcp
  allowed "$view" "$jobs" @kube-apiserver 443/tcp
  denied "$view" "$proxy" "$jobs" 8686/tcp
  denied "$view" "$ui" "$jobs" 8686/tcp
  denied "$view" "$jobs" @world 443/tcp
  denied "$view" "$jobs" "$api" 8585/tcp
  refused "$view" "$robot" "$jobs" 8686/tcp
  # The migrations and the hook.
  allowed "$view" "$migrations" "$dns" 53/udp
  allowed "$view" "$migrations" "$db" 5432/tcp
  denied "$view" "$migrations" @kube-apiserver 443/tcp
  denied "$view" "$migrations" @world 443/tcp
  denied "$view" "$migrations" "$rabbitmq" 5672/tcp
  allowed "$view" "$hook" @kube-apiserver 443/tcp
  allowed "$view" "$hook" @kube-apiserver 6443/tcp
  denied "$view" "$hook" "$dns" 53/udp
  denied "$view" "$hook" @world 443/tcp
  denied "$view" "$hook" "$db" 5432/tcp
  # RabbitMQ.
  denied "$view" "$proxy" "$rabbitmq" 5672/tcp
  denied "$view" "$proxy" "$rabbitmq" 15672/tcp
  denied "$view" "$ui" "$rabbitmq" 5672/tcp
  denied "$view" "$migrations" "$rabbitmq" 15672/tcp
  denied "$view" "$other" "$rabbitmq" 5672/tcp
  denied "$view" "$rabbitmq" "$dns" 53/udp
  denied "$view" "$rabbitmq" @world 443/tcp
  # The database: ReportPortal's pods, the dump job, the operator and Prometheus reach it; the
  # proxies, the ui, RabbitMQ and other applications do not.
  allowed "$view" "$pgdump" "$db" 5432/tcp
  allowed "$view" "$prometheus" "$db" 9187/tcp
  allowed "$view" "$cnpg" "$db" 8000/tcp
  allowed "$view" "$db" @world 443/tcp
  allowed "$view" "$pgdump" @world 443/tcp
  denied "$view" "$proxy" "$db" 5432/tcp
  denied "$view" "$ui" "$db" 5432/tcp
  denied "$view" "$rabbitmq" "$db" 5432/tcp
  denied "$view" "$other" "$db" 5432/tcp
  denied "$view" "$db" @world 22/tcp
  # The movers resolve names and reach the object storage on 443 alone.
  allowed "$view" "$mover" "$dns" 53/udp
  allowed "$view" "$mover" @world 443/tcp
  denied "$view" "$mover" @world 80/tcp
  denied "$view" "$mover" "$db" 5432/tcp
  # What the api and the jobs service would call outside on their own is off in their environment,
  # as the cluster audits these policies rather than enforcing them: the api loads no plugin from
  # its publisher's repository at start, and the jobs service sends no usage statistics to Google,
  # which it does only with both ids of its measurement set.
  [ "$(pod_spec "$RENDERED" Deployment reportportal-api | jq -c '[.containers[0].env[] | select(.name == "RP_PLUGINS_DEFAULT_LOAD")]')" = '[{"name":"RP_PLUGINS_DEFAULT_LOAD","value":"false"}]' ]
  [ "$(pod_spec "$RENDERED" Deployment reportportal-jobs | jq -c '[.containers[0].env[] | select(.name | test("^RP_ENVIRONMENT_VARIABLE_GA_"))] | sort_by(.name)')" \
    = '[{"name":"RP_ENVIRONMENT_VARIABLE_GA_ID","value":""},{"name":"RP_ENVIRONMENT_VARIABLE_GA_MID","value":""}]' ]
  # No monitor scrapes anything of ReportPortal but the database: the component's PodMonitor.
  [ "$(yq -N 'select(.kind == "ServiceMonitor" or .kind == "PodMonitor") | .kind + "/" + .metadata.name' "$APP_BUILT" "$RENDERED" | paste -sd' ' -)" = PodMonitor/reportportal-db ]
  # Without the namespace's default deny the same policies deny nothing.
  yq 'select((.kind == "NetworkPolicy" and .metadata.namespace == "reportportal") | not)' "$OVERLAY" >"$view/$(basename "$OVERLAY")"
  admitted "$view" "$robot" "$api" 8585/tcp
  allowed "$view" "$ui" @world 443/tcp
  docs "http://reportportal-api.reportportal.svc.cluster.local:8585"
}

@test "ReportPortal answers at its own hostname only behind the cluster's sign-in, by the chart's own paths, and its probe expects the redirect to sign-in" {
  local ns domain route chart_rules ours probe hello other policy signin record version routes exposed
  render
  overlay
  built reportportal-route
  domain="$(yq '.CLUSTER_DOMAIN' "$VARS")"
  # The namespace carries the label the public Gateway admits routes by.
  ns="$(KIND=Namespace NAME="$NAMESPACE" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$OVERLAY")"
  [ "$(yq '.metadata.labels["k8s-gitops/gateway"]' <<<"$ns")" = public ]
  # The route: reportportal under the cluster's domain on the https listener of public, /api to the
  # api's Service on 8585, everything else to the ui's on 8080, no filter.
  route="$(object "$BUILT" HTTPRoute reportportal | yq -o json -I0 '.spec' | jq -cS .)"
  echo "route: $route"
  [ "$route" = "{\"hostnames\":[\"reportportal.$domain\"],\"parentRefs\":[{\"name\":\"public\",\"namespace\":\"envoy-gateway-system\",\"sectionName\":\"https\"}],\"rules\":[{\"backendRefs\":[{\"name\":\"reportportal-api\",\"port\":8585}],\"matches\":[{\"path\":{\"type\":\"PathPrefix\",\"value\":\"/api\"}}]},{\"backendRefs\":[{\"name\":\"reportportal-ui\",\"port\":8080}],\"matches\":[{\"path\":{\"type\":\"PathPrefix\",\"value\":\"/\"}}]}]}" ]
  # The same paths and backends as the chart's own route at the pinned version, rendered with its
  # Gateway API switch on.
  helm template reportportal "$CHART" --namespace "$NAMESPACE" --kube-version "$KUBE" --set gatewayAPI.enable=true \
    --set gatewayAPI.hostnames=reportportal.example.net >"$BATS_TEST_TMPDIR/chart-route.yaml"
  chart_rules="$(yq -N -o json -I0 'select(.kind == "HTTPRoute") | .spec.rules' "$BATS_TEST_TMPDIR/chart-route.yaml" | jq -cS '[.[] | {matches, backendRefs: [.backendRefs[] | {name, port}]}]')"
  ours="$(jq -cS '[.rules[] | {matches, backendRefs: [.backendRefs[] | {name, port}]}]' <<<"$route")"
  echo "the chart's rules: $chart_rules"
  [ "$ours" = "$chart_rules" ]
  # The record of the chart's version the paths were read from is the one the release pins, and a pin
  # listed as moved by hand.
  version="$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.version' "$APP_BUILT")"
  record="$(sed -n 's/^# reportportal-paths: *\([0-9][0-9.]*\) *$/\1/p' "$BASE/reportportal-route/app/httproute.yaml")"
  [ "$record" = "$version" ]
  grep -qF "# Source: https://github.com/reportportal/kubernetes/blob/reportportal-$version/reportportal/templates/ingress/gateway-http-route.yaml" "$BASE/reportportal-route/app/httproute.yaml"
  [ "$(awk -F'\t' '$1 == "kubernetes/apps/base/reportportal/reportportal-route/app/httproute.yaml" && $2 == "reportportal-paths"' "$REPO/.renovate/by-hand.tsv" | grep -c .)" -eq 1 ]
  # The sign-in component's two objects: the policy that asks oauth2-proxy about every request of the
  # route, returning to its own host, and the route of the sign-in paths.
  policy="$(object "$BUILT" SecurityPolicy reportportal | yq -o json -I0 '.spec' | jq -cS .)"
  [ "$(jq -c '.targetRefs' <<<"$policy")" = '[{"group":"gateway.networking.k8s.io","kind":"HTTPRoute","name":"reportportal"}]' ]
  [ "$(jq -r '.extAuth.http.pathOverride' <<<"$policy")" = "/?rd=https://reportportal.$domain/" ]
  [ "$(jq -c '.extAuth.http.backendRefs' <<<"$policy")" = '[{"name":"oauth2-proxy","namespace":"sso-system","port":80}]' ]
  signin="$(object "$BUILT" HTTPRoute reportportal-oauth2 | yq -o json -I0 '.spec' | jq -cS .)"
  [ "$(jq -c '[.hostnames, .rules[0].matches[0].path.value, .rules[0].backendRefs[0].name]' <<<"$signin")" = "[[\"reportportal.$domain\"],\"/oauth2/\",\"oauth2-proxy\"]" ]
  [ "$(yq -N 'select(.kind != null) | .kind + "/" + .metadata.name' "$BUILT" | LC_ALL=C sort | paste -sd' ' -)" = "HTTPRoute/reportportal HTTPRoute/reportportal-oauth2 Probe/reportportal SecurityPolicy/reportportal" ]
  # oauth2-proxy's grant names reportportal for both.
  [ "$(yq -o json -I0 '[.spec.from[] | select(.namespace == "reportportal") | .kind] | sort' "$REPO/kubernetes/apps/base/sso-system/oauth2-proxy/app/referencegrant.yaml")" = '["HTTPRoute","SecurityPolicy"]' ]
  # No other route reaches ReportPortal: the namespace, its three applications and the release hold
  # no route but these two, and no ReferenceGrant, which a route of another namespace would need to
  # name its Services; and no other file of the tree that holds a route names it.
  routes="$BUILT"
  built reportportal-volsync-movers
  [ "$(yq -N 'select(((.kind // "") | test("Route$")) and (.metadata.namespace // "reportportal") == "reportportal") | .kind + "/" + .metadata.name' \
    "$OVERLAY" "$APP_BUILT" "$RENDERED" "$BUILT" "$routes" | LC_ALL=C sort | paste -sd' ' -)" = "HTTPRoute/reportportal HTTPRoute/reportportal-oauth2" ]
  [ -z "$(yq -N 'select(.kind == "ReferenceGrant" and (.metadata.namespace // "reportportal") == "reportportal") | .metadata.name' "$OVERLAY" "$APP_BUILT" "$RENDERED" "$BUILT" "$routes")" ]
  [ "$(cd "$REPO" && grep -rlE '^kind: *(HTTP|GRPC|TLS|TCP|UDP)Route *$' kubernetes | xargs grep -l reportportal | LC_ALL=C sort | paste -sd' ' -)" \
    = kubernetes/apps/base/reportportal/reportportal-route/app/httproute.yaml ]
  BUILT="$routes"
  # Nor is there a way around the Gateway: no Service of the release or of its applications is a
  # LoadBalancer or a NodePort, and no pod takes the node's network or a port of it.
  exposed="$(yq -N 'select(.kind == "Service" and (.spec.type == "LoadBalancer" or .spec.type == "NodePort")) | .kind + "/" + .metadata.name' \
    "$RENDERED" "$APP_BUILT" "$BUILT")"
  # shellcheck disable=SC2016 # $pod is a yq variable.
  exposed+="$(yq -N 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob" or .kind == "Pod")
      | (.spec.jobTemplate.spec.template.spec // .spec.template.spec // .spec) as $pod
      | select($pod.hostNetwork == true
        or ([($pod.containers // []) + ($pod.initContainers // []) | .[] | .ports // [] | .[] | select(.hostPort != null)] | length > 0))
      | .kind + "/" + .metadata.name' "$RENDERED" "$APP_BUILT" "$BUILT")"
  echo "exposed past the Gateway: ${exposed:-nothing}"
  [ -z "$exposed" ]
  # No firewall in front.
  [ "$(ks_field "$OVERLAY" reportportal-route '.spec.components | map(select(test("/components/waf$"))) | length')" -eq 0 ]
  # The Probe is hello-sso's, at the root, which the ui answers 200 to anyone once the policy is lost,
  # and so expects the redirect to sign-in.
  probe="$(object "$BUILT" Probe reportportal | yq -o json -I0 '.spec' | jq -cS .)"
  hello="$(yq -o json -I0 '.spec' "$REPO/kubernetes/apps/base/demo/hello-sso/app/probe.yaml" | jq -cS --arg domain "$domain" '.targets.staticConfig.labels.hostname = "reportportal." + $domain')"
  echo "probe: $probe"
  [ "$probe" = "$hello" ]
  [ "$(jq -r '.module' <<<"$probe")" = public_https_signin ]
  [[ $(jq -r '.targets.staticConfig.static[0]' <<<"$probe") == */ ]]
  # Built for another domain, the route's hostname, the policy's return address and the Probe's all
  # name it.
  other=other.example.net
  OTHER="$other" yq -i '.CLUSTER_DOMAIN = strenv(OTHER)' "$VARS"
  built reportportal-route
  [ "$(object "$BUILT" HTTPRoute reportportal | yq -o json -I0 '.spec.hostnames' | jq -c .)" = "[\"reportportal.$other\"]" ]
  [ "$(object "$BUILT" SecurityPolicy reportportal | yq '.spec.extAuth.http.pathOverride')" = "/?rd=https://reportportal.$other/" ]
  [ "$(object "$BUILT" Probe reportportal | yq '.spec.targets.staticConfig.labels.hostname')" = "reportportal.$other" ]
  docs "There are two sign-ins: the cluster's, then ReportPortal's own login"
}

@test "ReportPortal's database comes from the PostgreSQL component, its files are on a backed-up volume, and no secret is in the tree" {
  local cluster env workload generator es claim source
  render
  # The component's Cluster, by the name the Kustomization gives it: three instances, 5Gi each.
  cluster="$(object "$APP_BUILT" Cluster reportportal-db | yq -o json -I0 '.')"
  [ "$(jq -c '[.metadata.name, .spec.instances, .spec.storage.size]' <<<"$cluster")" = '["reportportal-db",3,"5Gi"]' ]
  [[ $(jq -r '.spec.imageName' <<<"$cluster") == ghcr.io/cloudnative-pg/postgresql:18.* ]]
  [ "$(jq -c '.spec.bootstrap // "unset"' <<<"$cluster")" = '"unset"' ]
  [ "$(jq -c '.spec.postgresql.parameters.max_connections // "unset"' <<<"$cluster")" = '"unset"' ]
  # The dump job's pods carry the labels its policies select.
  [ "$(yq -N -o json -I0 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.metadata.labels' "$APP_BUILT" | jq -cS .)" \
    = '{"app.kubernetes.io/instance":"reportportal-db","app.kubernetes.io/name":"pgdump"}' ]
  # The api, the jobs service and the migrations read the database's address, user and name from the
  # values and its password from the operator's Secret; the migrations ask for TLS.
  for workload in Deployment/reportportal-api Deployment/reportportal-jobs; do
    env="$(pod_spec "$RENDERED" "${workload%%/*}" "${workload#*/}" | jq -c '[.containers[0].env[] | select(.name | test("^RP_DB_"))] | sort_by(.name)')"
    [ "$env" = '[{"name":"RP_DB_HOST","value":"reportportal-db-rw.reportportal.svc.cluster.local"},{"name":"RP_DB_NAME","value":"app"},{"name":"RP_DB_PASS","valueFrom":{"secretKeyRef":{"key":"password","name":"reportportal-db-app"}}},{"name":"RP_DB_PORT","value":"5432"},{"name":"RP_DB_USER","value":"app"}]' ]
  done
  env="$(pod_spec "$RENDERED" Job reportportal-migrations | jq -c '[.containers[0].env[] | select(.name | test("^POSTGRES_"))] | sort_by(.name)')"
  [ "$env" = '[{"name":"POSTGRES_DB","value":"app"},{"name":"POSTGRES_PASSWORD","valueFrom":{"secretKeyRef":{"key":"password","name":"reportportal-db-app"}}},{"name":"POSTGRES_PORT","value":"5432"},{"name":"POSTGRES_SERVER","value":"reportportal-db-rw.reportportal.svc.cluster.local"},{"name":"POSTGRES_SSLMODE","value":"require"},{"name":"POSTGRES_USER","value":"app"}]' ]
  # The files' claim is the volume component's, 5Gi on the default class, and its backup the
  # component's: daily at 03:53, keeping 7 daily, 4 weekly and 3 monthly.
  claim="$(object "$APP_BUILT" PersistentVolumeClaim reportportal-shared-volume-claim | yq -o json -I0 '.spec' | jq -cS .)"
  [ "$claim" = '{"accessModes":["ReadWriteOnce"],"dataSourceRef":{"apiGroup":"volsync.backube","kind":"ReplicationDestination","name":"reportportal-restore"},"resources":{"requests":{"storage":"5Gi"}}}' ]
  source="$(object "$APP_BUILT" ReplicationSource reportportal | yq -o json -I0 '.spec' | jq -cS .)"
  [ "$(jq -c '[.sourcePVC, .trigger.schedule, .restic.retain, .restic.moverSecurityContext.runAsUser]' <<<"$source")" = '["reportportal-shared-volume-claim","53 3 * * *",{"daily":7,"monthly":3,"weekly":4},1000]' ]
  # The superadmin's password and RabbitMQ's credentials, generated once each in hex; the superadmin's
  # 32 characters, under the 36 the login form takes.
  generator="$(yq -N -o json -I0 'select(.kind == "Password") | [.metadata.name, .spec]' "$APP_BUILT" | jq -cS 'select(length > 0)' | LC_ALL=C sort | paste -sd' ' -)"
  echo "generators: $generator"
  [ "$generator" = '["reportportal-rabbitmq",{"allowRepeat":true,"encoding":"hex","length":32,"noUpper":false,"secretKeys":["password","erlangCookie"]}] ["reportportal-superadmin",{"allowRepeat":true,"encoding":"hex","length":16,"noUpper":false,"secretKeys":["password"]}]' ]
  es="$(object "$APP_BUILT" ExternalSecret reportportal-superadmin | yq -o json -I0 '.spec' | jq -cS .)"
  [ "$es" = '{"dataFrom":[{"sourceRef":{"generatorRef":{"apiVersion":"generators.external-secrets.io/v1alpha1","kind":"Password","name":"reportportal-superadmin"}}}],"refreshPolicy":"CreatedOnce","target":{"creationPolicy":"Owner","name":"reportportal-superadmin"}}' ]
  es="$(object "$APP_BUILT" ExternalSecret reportportal-rabbitmq | yq -o json -I0 '.spec' | jq -cS .)"
  [ "$es" = '{"dataFrom":[{"sourceRef":{"generatorRef":{"apiVersion":"generators.external-secrets.io/v1alpha1","kind":"Password","name":"reportportal-rabbitmq"}}}],"refreshPolicy":"CreatedOnce","target":{"creationPolicy":"Owner","name":"reportportal-rabbitmq","template":{"data":{"erlang-cookie":"{{ .erlangCookie }}","password":"{{ .password }}","rabbitmq-password":"{{ .password }}"},"engineVersion":"v2","mergePolicy":"Replace"}}}' ]
  # The release names them: the superadmin's first password, RabbitMQ's own Secret, and the broker's
  # password for the api and the jobs service.
  [ "$(pod_spec "$RENDERED" Deployment reportportal-api | jq -c '.containers[0].env[] | select(.name == "RP_INITIAL_ADMIN_PASSWORD") | .valueFrom')" = '{"secretKeyRef":{"key":"password","name":"reportportal-superadmin"}}' ]
  for workload in Deployment/reportportal-api Deployment/reportportal-jobs; do
    [ "$(pod_spec "$RENDERED" "${workload%%/*}" "${workload#*/}" | jq -c '.containers[0].env[] | select(.name == "RP_AMQP_PASS") | .valueFrom')" = '{"secretKeyRef":{"key":"rabbitmq-password","name":"reportportal-rabbitmq"}}' ]
  done
  [ "$(pod_spec "$RENDERED" StatefulSet reportportal-rabbitmq | jq -c '[.containers[0].env[] | select(.valueFrom.secretKeyRef) | .name + "=" + .valueFrom.secretKeyRef.name + "/" + .valueFrom.secretKeyRef.key] | sort')" \
    = '["RABBITMQ_DEFAULT_PASS=reportportal-rabbitmq/password","RABBITMQ_ERLANG_COOKIE=reportportal-rabbitmq/erlang-cookie"]' ]
  [ "$(pod_spec "$RENDERED" StatefulSet reportportal-rabbitmq | jq -c '.initContainers[0].env[] | .valueFrom.secretKeyRef')" = '{"key":"erlang-cookie","name":"reportportal-rabbitmq"}' ]
  # Nothing secret: no Secret built or rendered, the chart's own password Secret and RabbitMQ's among
  # them, no literal value for a password, secret key or access key in the values or in any
  # container's environment, and nothing secret in a values key the chart reads.
  [ -z "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$APP_BUILT" "$RENDERED")" ]
  [ -z "$(object "$RENDERED" Secret reportportal-api-init-password)" ]
  [ -z "$(object "$RENDERED" Secret reportportal-rabbitmq)" ]
  [ -z "$(yq -N '.. | select(tag == "!!str" and (key | tostring | test("(?i)(password|secretkey|accesskey|erlangcookie)$")) and . != "") | path | join(".")' "$APP/values.yaml")" ]
  [ -z "$(yq -N 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "Job") | .spec.template.spec | (.initContainers // []) + .containers | .[] | .env // [] | .[]
    | select((.name | test("(?i)(pass|password|secret|accesskey|cookie)")) and has("value")) | .name' "$RENDERED")" ]
  [ -z "$(grep -iE 'rppassword|rabbitmqpassword|rpuser' "$RENDERED" "$APP/values.yaml" || true)" ]
  docs "kubectl --namespace reportportal get secret reportportal-superadmin --output jsonpath='{.data.password}' | base64 -d; echo"
  docs "default@reportportal.internal"
}
