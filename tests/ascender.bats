#!/usr/bin/env bats
# Proves features/ascender.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq, jq and kyverno on PATH (the versions pinned for the repository).
# The operator's chart is pulled once per run from its publisher's Helm repository; building,
# rendering and the evaluations are offline, with the placeholders of the cluster's example key lists.

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
  NAMESPACE=ascender
  BASE="$REPO/kubernetes/apps/base/ascender"
  OPERATOR_APP="$BASE/ascender-operator"
  OPERATOR="$NAMESPACE/Deployment/awx-operator-controller-manager"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  VARS="$BATS_TEST_TMPDIR/example-vars.yaml"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$VARS"
  OVERLAY_DIR="$REPO/kubernetes/apps/overlays/lab-sto2"
}

# overlay [DIR]: the lab-sto2 overlay as Flux reads it, its namespaces and the Kustomization of each
# enabled application. Writes $OVERLAY.
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
# spec.path in the tree ROOT, the checkout's by default, with strict substitution. In memory: flux
# build otherwise rewrites the kustomization.yaml of what it builds, in the checkout, and puts it
# back afterwards.
flux_build() {
  local path
  path="$(yq '.spec.path' "$2")"
  (cd "${3:-$REPO}" && flux build kustomization "$1" --path "./kubernetes/${path#./}" \
    --kustomization-file "$2" --dry-run --strict-substitute --in-memory-build)
}

# built NAME: the application NAME as Flux applies it on lab-sto2. The cluster's root is built as
# Flux builds it, once a test, so the overlay's Kustomization of the application carries what the
# root patches into every child, the release defaults among them; that Kustomization is then built
# with the example key lists under its own substitutions. Writes the application's objects to
# $BATS_TEST_TMPDIR/NAME-built.yaml, which BUILT names, and its Kustomization to KS.
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

# both: the two applications built, in OPERATOR_BUILT and APP_BUILT, and the AWX of the second, in
# AWX, as JSON.
both() {
  built ascender-operator
  OPERATOR_BUILT="$BUILT"
  built ascender
  APP_BUILT="$BUILT"
  AWX="$BATS_TEST_TMPDIR/awx.json"
  yq -N -o json 'select(.kind == "AWX")' "$APP_BUILT" >"$AWX"
  [ "$(jq -r '.apiVersion + " " + .metadata.name' "$AWX")" = "awx.ansible.com/v1beta1 ascender" ] ||
    { echo "the application ascender builds no one AWX ascender"; return 1; }
}

# render: the chart the HelmRelease installs, from the URL of its HelmRepository at the version its
# chart.spec pins, rendered the way helm-controller renders a release: through Helm's post-render
# step, with a plugin that runs what helm-controller chains, each kustomize post-renderer of the
# HelmRelease in turn, then the labels that name the HelmRelease on every object. Helm merges what
# the chart renders into one stream with its own reader before the post-renderer sees it, and reads
# the result again, so a document either reader refuses fails here as it fails the release. Builds
# both applications and sets CHART, RAW (the chart rendered without the post-renderers) and
# RENDERED.
render() {
  local url chart version release namespace pulled post count i
  both
  url="$(yq -N 'select(.kind == "HelmRepository") | .spec.url' "$OPERATOR_BUILT")"
  chart="$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.chart' "$OPERATOR_BUILT")"
  version="$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.version' "$OPERATOR_BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$OPERATOR_BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$OPERATOR_BUILT")"
  [ "$release" = ascender-operator ] && [ "$namespace" = "$NAMESPACE" ] ||
    { echo "the release is $release in $namespace, not ascender-operator in $NAMESPACE"; return 1; }
  # The chart's defaults are what the release installs: it has no values of its own.
  [ "$(yq -N 'select(.kind == "HelmRelease") | (.spec.values // {} | length) + (.spec.valuesFrom // [] | length)' "$OPERATOR_BUILT")" -eq 0 ] ||
    { echo "the HelmRelease has values"; return 1; }
  pulled="$BATS_FILE_TMPDIR/charts/$chart-$version"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$chart" --repo "$url" --version "$version" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  RAW="$BATS_TEST_TMPDIR/operator-raw.yaml"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" >"$RAW"
  post="$BATS_TEST_TMPDIR/post-render"
  rm -rf "$post"
  mkdir -p "$post/steps" "$post/plugins/release"
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.postRenderers // [] | map(select((keys | join(",")) != "kustomize")) | length' "$OPERATOR_BUILT")" -eq 0 ] ||
    { echo "the HelmRelease has a post-renderer that is not kustomize"; return 1; }
  count="$(yq -N 'select(.kind == "HelmRelease") | .spec.postRenderers // [] | length' "$OPERATOR_BUILT")"
  for ((i = 0; i < count; i++)); do
    I="$i" yq -N -o json 'select(.kind == "HelmRelease") | {"apiVersion": "kustomize.config.k8s.io/v1beta1",
      "kind": "Kustomization", "resources": ["helm-output.yaml"]} + .spec.postRenderers[env(I)].kustomize' "$OPERATOR_BUILT" \
      >"$post/steps/$(printf '%03d' "$i").json"
  done
  NAME="$(yq -N 'select(.kind == "HelmRelease") | .metadata.name' "$OPERATOR_BUILT")" \
    NS="$(yq -N 'select(.kind == "HelmRelease") | .metadata.namespace' "$OPERATOR_BUILT")" \
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
  RENDERED="$BATS_TEST_TMPDIR/operator.yaml"
  POST_RENDER="$post" HELM_PLUGINS="$post/plugins" helm template "$release" "$CHART" --namespace "$namespace" \
    --kube-version "$KUBE" --post-renderer release >"$RENDERED"
}

# object FILE KIND NAME: the one object of that kind and name in FILE.
object() {
  KIND="$2" NAME="$3" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$1"
}

# container FILE NAME: the container NAME of the Deployment awx-operator-controller-manager in FILE.
container() {
  object "$1" Deployment awx-operator-controller-manager | NAME="$2" yq '.spec.template.spec.containers[] | select(.name == strenv(NAME))'
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

# operator_pods AWXFILE DIR: the web and task pods the pinned operator writes from the AWX in
# AWXFILE, as far as Pod Security reads them, in DIR/web.yaml and DIR/task.yaml: the pod's security
# context and each container's, with the images and capabilities the resource sets. They are those
# of roles/installer/templates/deployments/web.yaml.j2 (the pod context at lines 54-58 and 416-419,
# valkey's container at 165-178, web's at 193-199, rsyslog's at 334-340) and task.yaml.j2 (the init
# containers at 104-151, valkey's at 221-234, task's at 266-275, the execution environment's at
# 395-401, rsyslog's at 463-469, the pod at 557-569) of the operator's tag ascender-operator-templates
# records, where the restricted mode is the pod context {runAsNonRoot, the RuntimeDefault seccomp
# profile, runAsUser 1000, fsGroup 1000} combined, key by key, with security_context_settings, and
# without it security_context_settings alone.
operator_pods() {
  jq -c '.spec as $s
    | ($s.restricted_security_context == true) as $r
    | ($s.security_context_settings // {}) as $settings
    | (if $r then {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}} else null end) as $hardened
    | (if $r then {"runAsNonRoot": true, "seccompProfile": {"type": "RuntimeDefault"}, "runAsUser": 1000, "fsGroup": 1000} + $settings
       elif ($settings | length) > 0 then $settings else null end) as $pod
    | (if $r or (($s.redis_capabilities // []) | length) > 0 then
         {"capabilities": ((if $r then {"drop": ["ALL"]} else {} end) + (if (($s.redis_capabilities // []) | length) > 0 then {"add": $s.redis_capabilities} else {} end))}
         + (if $r then {"allowPrivilegeEscalation": false} else {} end)
       else null end) as $redis
    | def c($name; $image; $context): {"name": $name, "image": $image} + (if $context == null then {} else {"securityContext": $context} end);
    def pod($name; $init; $containers): {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": $name},
      "spec": ({"initContainers": $init, "containers": $containers} + (if $pod == null then {} else {"securityContext": $pod} end))};
    pod("web"; []; [c("redis"; $s.redis_image; $redis), c("ascender-web"; $s.image; $hardened), c("ascender-rsyslog"; $s.image; $hardened)]),
    pod("task";
      [c("init-database"; $s.image; $hardened), c("init-receptor"; $s.init_container_image; $hardened)];
      [c("redis"; $s.redis_image; $redis),
       c("ascender-task"; $s.image; (if $s.task_privileged == true then {"privileged": true} else $hardened end)),
       c("ascender-ee"; $s.control_plane_ee_image; $hardened), c("ascender-rsyslog"; $s.image; $hardened)])' "$1" |
    while IFS= read -r pod; do
      jq '.' <<<"$pod" >"$2/$(jq -r '.metadata.name' <<<"$pod").yaml"
    done
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

# of_namespace FILE: what an overlay built into FILE holds of Ascender and of its namespace, sorted,
# as kind, namespace and name: the namespace itself, any object in it, and any Kustomization that
# deploys into it or from its directory.
of_namespace() {
  yq -N 'select((.kind == "Namespace" and .metadata.name == "ascender") or .metadata.namespace == "ascender"
      or .spec.targetNamespace == "ascender" or ((.spec.path // "") | test("/apps/base/ascender/")))
    | .kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$1" | LC_ALL=C sort | paste -sd, -
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

# runbook_cluster OLD FILE: the Cluster that docs/runbooks/postgres-restore.md adds beside a
# database to restore it to a point in time, its one fenced YAML block that is a Cluster, as
# tests/postgresql.bats reads it, for the database OLD in place of the runbook's example and with the
# component's image in place of the placeholder; written to FILE.
runbook_cluster() {
  local blocks="$BATS_TEST_TMPDIR/runbook-blocks" block example
  rm -rf "$blocks"
  mkdir -p "$blocks"
  awk -v dir="$blocks" '/^ *```yaml$/ { inside = 1; block++; match($0, /^ */); indent = RLENGTH; next }
    /^ *```$/ { inside = 0; next } inside { print substr($0, indent + 1) > (dir "/block-" block ".yaml") }' \
    "$REPO/docs/runbooks/postgres-restore.md"
  block="$(grep -lx 'kind: Cluster' "$blocks"/block-*.yaml || true)"
  [ -n "$block" ] && [ "$(grep -c . <<<"$block")" -eq 1 ] || { echo "the restore runbook has no one Cluster"; return 1; }
  # The example's old cluster is the one whose archive the recovery reads.
  # shellcheck disable=SC2016 # $source is a yq variable.
  example="$(yq '.spec.bootstrap.recovery.source as $source | .spec.externalClusters[] | select(.name == $source) | .plugin.parameters.serverName' "$block")"
  [ -n "$example" ] || { echo "the runbook's Cluster reads no old cluster's archive"; return 1; }
  OLD="$1" EXAMPLE="$example" IMAGE="$(yq '.spec.imageName' "$REPO/kubernetes/components/cnpg-cluster/cluster.yaml")" \
    yq '(.. | select(tag == "!!str")) |= sub("^" + strenv(EXAMPLE); strenv(OLD)) | .spec.imageName = strenv(IMAGE)' "$block" >"$2"
}

# docs TEXT: whether docs/kubernetes.md holds TEXT, whatever its line breaks.
docs() {
  tr -s "\n " "  " <"$REPO/docs/kubernetes.md" | grep -qF -- "$1"
}

@test "Ascender is selected by overlay entries and builds nothing when it is not" {
  local dependency name
  local -A entry=([ascender-operator]='/ascender/ascender-operator/ks.yaml$' [cloudnative-pg]='/cnpg-system/cloudnative-pg/ks.yaml$'
    [plugin-barman-cloud]='/cnpg-system/plugin-barman-cloud/ks.yaml$' [prometheus-operator-crds]='/kube-system/prometheus-operator-crds/ks.yaml$'
    [external-secrets]='/external-secrets/external-secrets/ks.yaml$' [openbao-store]='/external-secrets/openbao-store/ks.yaml$'
    [gateway-public]='/envoy-gateway-system/gateway-public/ks.yaml$' [cilium]='/kube-system/cilium/ks.yaml$'
    [blackbox-exporter]='/monitoring/blackbox-exporter/ks.yaml$')
  # Who names each dependency: ascender all of them, and ascender-operator cilium and
  # external-secrets.
  local -A dependents=([cilium]="ascender-operator ascender" [external-secrets]="ascender-operator ascender")
  # The overlay selects it with three entries: the namespace directory and the two ks.yaml.
  [ "$(yq '.resources[] | select(test("/ascender(/|$)"))' "$OVERLAY_DIR/kustomization.yaml" | LC_ALL=C sort | paste -sd' ' -)" \
    = "../../base/ascender ../../base/ascender/ascender-operator/ks.yaml ../../base/ascender/ascender/ks.yaml" ]
  overlay
  [ "$(of_namespace "$OVERLAY")" = ConfigMap/ascender/app-template-defaults,Kustomization/flux-system/ascender,Kustomization/flux-system/ascender-operator,Namespace/-/ascender,NetworkPolicy/ascender/default-deny ]
  # The operator's application waits for its release and names what its objects need first: the
  # policies' kind, and External Secrets', whose kinds make the database's Secret.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "ascender-operator") | .spec.dependsOn | map(.name) | join(" ")' "$OVERLAY")" = "cilium external-secrets" ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "ascender-operator") | .spec.wait' "$OVERLAY")" = true ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "ascender-operator") | .spec.targetNamespace' "$OVERLAY")" = "$NAMESPACE" ]
  # Ascender's names the operator, whose chart defines the kind AWX, and what its database, route,
  # probe, policies and secrets need; it takes the long timeout and is Ready once the operator's run
  # for the AWX has ended without a failure.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "ascender") | .spec.dependsOn | map(.name) | join(" ")' "$OVERLAY")" \
    = "ascender-operator cloudnative-pg plugin-barman-cloud prometheus-operator-crds external-secrets openbao-store gateway-public cilium blackbox-exporter" ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "ascender") | .metadata.labels["k8s-gitops/timeout"]' "$OVERLAY")" = long ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "ascender") | .spec.wait' "$OVERLAY")" = true ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "ascender") | .spec.targetNamespace' "$OVERLAY")" = "$NAMESPACE" ]
  # One health check, for the AWX: current is the Successful condition being True. No failed
  # expression, as a Failure condition stays True into the next run, and no inProgress.
  [ "$(yq -N -o json -I0 'select(.kind == "Kustomization" and .metadata.name == "ascender") | .spec.healthCheckExprs' "$OVERLAY" | jq -cS .)" \
    = '[{"apiVersion":"awx.ansible.com/v1beta1","current":"has(status.conditions) && status.conditions.exists(c, c.type == '"'"'Successful'"'"' && c.status == '"'"'True'"'"')","kind":"AWX"}]' ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # With only the namespace directory's entry, the cluster builds the namespace, its defaults and
  # its default deny, and nothing of Ascender.
  tree_without '/ascender/ascender-operator/ks.yaml$' '/ascender/ascender/ks.yaml$'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ "$(of_namespace "$OVERLAY")" = ConfigMap/ascender/app-template-defaults,Namespace/-/ascender,NetworkPolicy/ascender/default-deny ]
  # With none, nothing of the namespace.
  tree_without '/ascender(/|$)'
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
    for name in ${dependents[$dependency]:-ascender}; do
      [[ $output == *"kubernetes/apps/base/ascender/$name/ks.yaml: Kustomization $name names $dependency"*"does not enable"* ]] ||
        { echo "not refused naming $name and $dependency"; return 1; }
    done
  done
  # The namespace is the tree's: the release renders none, and nothing in another namespace. Its
  # namespaced objects name none, so they are the release's, ascender's; three are cluster-wide,
  # and the binding's subject is the operator's account in the release's namespace.
  render
  [ -z "$(yq -N 'select(.kind == "Namespace") | .metadata.name' "$RENDERED")" ]
  [ -z "$(yq -N 'select(.metadata.namespace != null) | .metadata.namespace' "$RENDERED")" ]
  [ "$(yq -N 'select(.kind | test("^Cluster")) | .kind + "/" + .metadata.name' "$RENDERED" | LC_ALL=C sort | paste -sd' ' -)" \
    = "ClusterRole/awx-operator-metrics-reader-ascender-operator ClusterRole/awx-operator-proxy-role-ascender-operator ClusterRoleBinding/awx-operator-proxy-rolebinding-ascender-operator" ]
  [ "$(object "$RENDERED" ClusterRoleBinding awx-operator-proxy-rolebinding-ascender-operator | yq -o json -I0 '.subjects' | jq -c .)" \
    = "[{\"kind\":\"ServiceAccount\",\"name\":\"awx-operator-controller-manager\",\"namespace\":\"$NAMESPACE\"}]" ]
}

@test "Ascender's operator, its images and the images it starts are pinned by version and digest and move together" {
  local version app_version image tag file dep record awx_file rows line switch rule rules
  render
  # The chart: ascender-operator at 25.6.3, from Ctrl IQ's classic Helm repository, whose index
  # Renovate's flux manager reads the version by.
  [ "$(yq -N 'select(.kind == "HelmRepository") | .metadata.name + " " + .spec.url' "$OPERATOR_BUILT")" = "ascender-operator https://ctrliq.github.io/ascender-operator" ]
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec | .chart + " " + .version + " " + .sourceRef.kind + "/" + .sourceRef.name' "$OPERATOR_BUILT")" \
    = "ascender-operator 25.6.3 HelmRepository/ascender-operator" ]
  version="$(tar -xzOf "$CHART" ascender-operator/Chart.yaml | yq '.version')"
  app_version="$(tar -xzOf "$CHART" ascender-operator/Chart.yaml | yq '.appVersion')"
  [ "$version" = 25.6.3 ]
  # The two images of the operator's pod, each at the tag the chart gives it and pinned by digest by
  # the post-renderer: the operator's at the chart's appVersion, the proxy's at the chart's own tag.
  image="$(container "$RENDERED" awx-manager | yq '.image')"
  echo "operator: $image; the chart's: $(container "$RAW" awx-manager | yq '.image')"
  [[ $image =~ ^ghcr\.io/ctrliq/ascender-operator:([^@]+)@sha256:[0-9a-f]{64}$ ]]
  [ "${BASH_REMATCH[1]}" = "$app_version" ]
  [ "$(container "$RAW" awx-manager | yq '.image')" = "ghcr.io/ctrliq/ascender-operator:$app_version" ]
  image="$(container "$RENDERED" kube-rbac-proxy | yq '.image')"
  tag="$(container "$RAW" kube-rbac-proxy | yq '.image | sub("^quay\.io/brancz/kube-rbac-proxy:"; "")')"
  echo "proxy: $image; the chart's tag: $tag"
  [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
  [[ $image =~ ^quay\.io/brancz/kube-rbac-proxy:([^@]+)@sha256:[0-9a-f]{64}$ ]]
  [ "${BASH_REMATCH[1]}" = "$tag" ]
  # Every image of the render is pinned. The pod's pull secret stays the chart's, one nothing makes,
  # which the kubelet does without for public images, and the docs say so.
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec | (.containers + (.initContainers // []))[] | .image' "$RENDERED" | grep -cvE '@sha256:[0-9a-f]{64}$' || true)" -eq 0 ]
  [ "$(object "$RENDERED" Deployment awx-operator-controller-manager | yq -o json -I0 '.spec.template.spec.imagePullSecrets')" = '[{"name":"redhat-operators-pull-secret"}]' ]
  docs "names the pull secret \`redhat-operators-pull-secret\`, which nothing makes"
  # The post-renderer's two images, each under the comment Renovate's custom manager reads.
  file="$OPERATOR_APP/app/helmrelease.yaml"
  for dep in ghcr.io/ctrliq/ascender-operator quay.io/brancz/kube-rbac-proxy; do
    [ "$(DEP="$dep" yq '.spec.postRenderers[].kustomize.images[]? | select(.name == strenv(DEP)) | .newTag | sub("@.*"; "")' "$file")" != "" ]
    [ "$(above "$file" "newTag: $(DEP="$dep" yq '.spec.postRenderers[].kustomize.images[]? | select(.name == strenv(DEP)) | .newTag' "$file")")" \
      = "# renovate: datasource=docker depName=$dep" ]
  done
  # The images the operator runs for Ascender, from the AWX: it joins each repository and version
  # with a colon (roles/installer/tasks/resources_configuration.yml and set_images.yml), so these are
  # the references it writes, every one at the chart's version with a digest, and the init
  # container's set in full, as its defaults would split a reference with a digest.
  [ "$(jq -r '.spec.image + ":" + .spec.image_version' "$AWX")" = "ghcr.io/ctrliq/ascender:$(jq -r '.spec.image_version' "$AWX")" ]
  [[ $(jq -r '.spec.image + ":" + .spec.image_version' "$AWX") =~ ^ghcr\.io/ctrliq/ascender:([^@]+)@sha256:[0-9a-f]{64}$ ]]
  [ "${BASH_REMATCH[1]}" = "$version" ]
  [[ $(jq -r '.spec.init_container_image + ":" + .spec.init_container_image_version' "$AWX") =~ ^ghcr\.io/ctrliq/ascender-ee:([^@]+)@sha256:[0-9a-f]{64}$ ]]
  [ "${BASH_REMATCH[1]}" = "$version" ]
  [[ $(jq -r '.spec.control_plane_ee_image' "$AWX") =~ ^ghcr\.io/ctrliq/ascender-ee:([^@]+)@sha256:[0-9a-f]{64}$ ]]
  [ "${BASH_REMATCH[1]}" = "$version" ]
  [ "$(jq -r '.spec.init_container_image + ":" + .spec.init_container_image_version' "$AWX")" = "$(jq -r '.spec.control_plane_ee_image' "$AWX")" ]
  # One execution environment for jobs, the same image, named without a version, so that a new
  # version moves the registered one in place (register_default_execution_environments.py).
  [ "$(jq -cS '.spec.ee_images' "$AWX")" = "[{\"image\":\"$(jq -r '.spec.control_plane_ee_image' "$AWX")\",\"name\":\"Ascender EE\"}]" ]
  [[ $(jq -r '.spec.redis_image + ":" + .spec.redis_image_version' "$AWX") =~ ^ghcr\.io/valkey-io/valkey:9\.[0-9]+\.[0-9]+-alpine@sha256:[0-9a-f]{64}$ ]]
  # Each pin under its comment, and each extracted by Renovate exactly once in the AWX's file: the
  # versions by the custom manager, and the execution environment's image by the kubernetes manager,
  # which reads every image: key and so is the one manager of that line. It reads spec.image too,
  # the repository alone, as a dependency with neither version nor digest, which its lookup skips
  # as an invalid value and never moves (workers/repository/process/lookup/index.js of the pinned
  # Renovate).
  awx_file=kubernetes/apps/base/ascender/ascender/app/awx.yaml
  [ "$(above "$REPO/$awx_file" "image_version: $(jq -r '.spec.image_version' "$AWX")")" = "# renovate: datasource=docker depName=ghcr.io/ctrliq/ascender" ]
  [ "$(above "$REPO/$awx_file" "init_container_image_version: ")" = "# renovate: datasource=docker depName=ghcr.io/ctrliq/ascender-ee" ]
  [ "$(above "$REPO/$awx_file" "control_plane_ee_image: ")" = "# renovate: datasource=docker depName=ghcr.io/ctrliq/ascender-ee" ]
  [ "$(above "$REPO/$awx_file" "redis_image_version: ")" = "# renovate: datasource=docker depName=ghcr.io/valkey-io/valkey" ]
  rows="$(awk -F'\t' -v f="$awx_file" '$1 == f { print $2 " " $3 " " $4 }' "$REPO/.renovate/extracted.tsv" | LC_ALL=C sort | paste -sd, -)"
  echo "extracted from $awx_file: $rows"
  [ "$rows" = "kubernetes ghcr.io/ctrliq/ascender -,kubernetes ghcr.io/ctrliq/ascender-ee -,regex ghcr.io/ctrliq/ascender image_version,regex ghcr.io/ctrliq/ascender-ee control_plane_ee_image,regex ghcr.io/ctrliq/ascender-ee init_container_image_version,regex ghcr.io/valkey-io/valkey redis_image_version" ]
  [ "$(grep -c "@sha256:" "$REPO/$awx_file")" -eq 5 ]
  [ "$(above "$REPO/$awx_file" "      image: ghcr.io/ctrliq/ascender-ee:")" = "- name: Ascender EE" ]
  [ "$(grep -c -E '^ *(- )?image: ' "$REPO/$awx_file")" -eq 2 ]
  rows="$(awk -F'\t' -v f=kubernetes/apps/base/ascender/ascender-operator/app/helmrelease.yaml '$1 == f { print $2 " " $3 " " $4 }' "$REPO/.renovate/extracted.tsv" | LC_ALL=C sort | paste -sd, -)"
  echo "extracted from the HelmRelease: $rows"
  [ "$rows" = "flux ascender-operator -,regex ghcr.io/ctrliq/ascender-operator newTag,regex quay.io/brancz/kube-rbac-proxy newTag" ]
  # spec.image is read with no tag by the image check, and is the one line of the allowlist for the
  # application.
  [ "$(awk '$1 == "ascender" { print $2 }' "$REPO/.image-allowlist")" = "$(jq -r '.spec.image' "$AWX")" ]
  # The record of the release the copied pod labels were read from, in each file that copies them,
  # is the chart's version, and each is a pin listed as moved by hand.
  for file in ascender/app/service.yaml ascender/app/ciliumnetworkpolicy.yaml ascender-operator/app/ciliumnetworkpolicy.yaml; do
    record="$(sed -n 's/^# ascender-operator-templates: *\([0-9][0-9.]*\) *$/\1/p' "$BASE/$file")"
    echo "$file records $record"
    [ "$record" = "$version" ]
    [ "$(awk -F'\t' -v f="kubernetes/apps/base/ascender/$file" '$1 == f && $2 == "ascender-operator-templates"' "$REPO/.renovate/by-hand.tsv" | grep -c .)" -eq 1 ]
  done
  # One group moves the chart, the operator's image and Ascender's two images together, as Ctrl IQ's
  # installer runs them at one version.
  line="$(grep -n -F '"ascender-operator", "ghcr.io/ctrliq/ascender-operator", "ghcr.io/ctrliq/ascender", "ghcr.io/ctrliq/ascender-ee"' "$REPO/.renovate/groups.json5" | cut -d: -f1)"
  [ -n "$line" ]
  sed -n "$((line + 1))p" "$REPO/.renovate/groups.json5" | grep -q 'groupName: "Ascender"'
  # Each of these two packages has one rule of the managers, held whole besides its description: a
  # key added to a rule narrows what it matches, and one that no pin matches turns it off.
  rules="$(grep -v '^[[:space:]]*//' "$REPO/.renovate/managers.json5" | yq -o json -I0 '.packageRules')"
  # valkey stays on the major the operator defaults to.
  jq -e 'map(select((.matchPackageNames // []) | index("ghcr.io/valkey-io/valkey") != null))
    | length == 1 and (.[0] | del(.description)) == {matchPackageNames: ["ghcr.io/valkey-io/valkey"],
      allowedVersions: "/^9\\.[0-9]+\\.[0-9]+-alpine$/"}' <<<"$rules"
  # The proxy's tag is the chart's, which the check above holds it to, so in the HelmRelease
  # Renovate proposes no other tag of it, only new digests: the tag moves with the chart.
  jq -e 'map(select((.matchPackageNames // []) | index("quay.io/brancz/kube-rbac-proxy") != null))
    | length == 1 and (.[0] | del(.description)) == {
      matchFileNames: ["kubernetes/apps/base/ascender/ascender-operator/app/helmrelease.yaml"],
      matchPackageNames: ["quay.io/brancz/kube-rbac-proxy"], matchUpdateTypes: ["major", "minor", "patch"],
      enabled: false}' <<<"$rules"
  # Nothing of the two applications merges itself: a rule for every file of them, after the
  # auto-merge switch, so that it wins over the switch.
  switch="$(grep -n -F 'description: "The auto-merge switch' "$REPO/.renovate/automerge.json5" | cut -d: -f1)"
  rule="$(grep -n -F 'matchFileNames: ["kubernetes/apps/base/ascender/**"]' "$REPO/.renovate/automerge.json5" | cut -d: -f1)"
  [ -n "$switch" ] && [ -n "$rule" ] && [ "$rule" -gt "$switch" ]
  sed -n "$((rule + 1))p" "$REPO/.renovate/automerge.json5" | grep -q 'automerge: false'
}

@test "Every pod the operator makes asks for the restricted level, and only Ascender's job pods are let down to baseline" {
  local ns minor dir key settings pod mutated
  render
  overlay
  minor="$(sed -E 's/^(v[0-9]+\.[0-9]+).*/\1/' <<<"$KUBE")"
  # The namespace enforces baseline, for the job pods, and audits and warns at restricted at the
  # cluster's minor, which records and reports every pod there that fails restricted.
  ns="$(object "$OVERLAY" Namespace "$NAMESPACE")"
  [ "$(yq -o json -I0 '.metadata.labels | with_entries(select(.key | test("^pod-security")))' <<<"$ns" | jq -cS .)" \
    = "{\"pod-security.kubernetes.io/audit\":\"restricted\",\"pod-security.kubernetes.io/audit-version\":\"$minor\",\"pod-security.kubernetes.io/enforce\":\"baseline\",\"pod-security.kubernetes.io/warn\":\"restricted\",\"pod-security.kubernetes.io/warn-version\":\"$minor\"}" ]
  [ "$(yq '.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"]' <<<"$ns")" = disabled ]
  # One exception: the pods Ascender starts for jobs, created by the AWX, at baseline.
  [ "$(NS="$NAMESPACE" yq -o json -I0 '[.exceptions[] | select(.namespace == strenv(NS)) | del(.reason)]' "$REPO/pod-security-exceptions.yaml" | jq -c .)" \
    = '[{"namespace":"ascender","workload":"Pod/automation-job","created-by":"AWX/ascender","level":"baseline"}]' ]
  [ -n "$(NS="$NAMESPACE" yq '.exceptions[] | select(.namespace == strenv(NS)) | .reason' "$REPO/pod-security-exceptions.yaml")" ]
  # The AWX asks for the operator's restricted mode and writes the pod context out, so that the
  # tree can check it: the user the mode writes, the group the image's files are writable by (the
  # image holds what its launch scripts write as root's, group-writable for gid 0 alone, and the
  # restricted level puts no rule on groups), the file system group the mode writes and the
  # runtime's seccomp profile. Nothing that raises a pod above restricted.
  [ "$(jq -c '.spec.restricted_security_context' "$AWX")" = true ]
  settings="$(jq -cS '.spec.security_context_settings' "$AWX")"
  [ "$settings" = '{"fsGroup":1000,"runAsGroup":0,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}' ]
  for key in task_privileged redis_capabilities development_mode projects_persistence host_aliases; do
    [ "$(KEY="$key" jq -c '.spec[env.KEY] // "unset"' "$AWX")" = '"unset"' ] || { echo "the AWX sets $key"; return 1; }
  done
  # The AWX sets these fields and no other: each is modelled in the pods evaluated below (the
  # images, the restricted mode and its pod context) or adds nothing Pod Security reads (settings,
  # probes, requests, the database's Secret and the instance's shape). Any other field, such as
  # extra_volumes, a *_extra_volume_mounts or init_container_extra_commands, which add volumes,
  # mounts and commands to the operator's pods, is refused until those pods model it.
  echo "the AWX sets: $(jq -r '.spec | keys | join(" ")' "$AWX")"
  [ "$(jq -r '.spec | keys | join(" ")' "$AWX")" = "admin_user control_plane_ee_image create_preload_data csrf_cookie_secure ee_images ee_resource_requirements extra_settings garbage_collect_secrets image image_version ingress_type init_container_image init_container_image_version init_container_resource_requirements postgres_configuration_secret redis_image redis_image_version redis_resource_requirements replicas restricted_security_context rsyslog_resource_requirements security_context_settings service_type session_cookie_secure task_liveness_initial_delay task_liveness_period task_resource_requirements web_liveness_initial_delay web_liveness_period web_readiness_period web_resource_requirements" ]
  docs "group-writable for gid 0"
  # The pods the operator writes from it, web and task, pass restricted; without the restricted
  # mode, with an added capability or with a privileged task container, they do not.
  dir="$BATS_TEST_TMPDIR/pods"
  mkdir -p "$dir"
  operator_pods "$AWX" "$dir"
  for pod in web task; do
    level_failures "$dir/$pod.yaml" "$NAMESPACE" restricted
    echo "$pod: $(paste -sd' ' "$CONTROLS")"
    [ ! -s "$CONTROLS" ]
  done
  [ "$(jq -cS '.spec.securityContext' "$dir/web.yaml")" = "$settings" ]
  for mutated in '.spec.restricted_security_context = false' '.spec.redis_capabilities = ["CHOWN", "SETUID", "SETGID"]' '.spec.task_privileged = true'; do
    jq "$mutated" "$AWX" >"$BATS_TEST_TMPDIR/mutated.json"
    rm -rf "$dir" && mkdir -p "$dir"
    operator_pods "$BATS_TEST_TMPDIR/mutated.json" "$dir"
    level_failures "$dir/$([[ $mutated == *task_privileged* ]] && echo task || echo web).yaml" "$NAMESPACE" restricted
    echo "with $mutated: $(paste -sd' ' "$CONTROLS")"
    [ -s "$CONTROLS" ]
  done
  # The operator's own pod passes restricted as the chart renders it.
  object "$RENDERED" Deployment awx-operator-controller-manager >"$BATS_TEST_TMPDIR/operator-deployment.yaml"
  level_failures "$BATS_TEST_TMPDIR/operator-deployment.yaml" "$NAMESPACE" restricted
  echo "the operator: $(paste -sd' ' "$CONTROLS")"
  [ ! -s "$CONTROLS" ]
  # The default job pod, as the pinned Ascender writes it (awx/main/utils/execution_environments.py,
  # get_default_pod_spec): the job label, the namespace's default account without its token, and one
  # container from the execution environment with no security context. It passes baseline and fails
  # restricted, which is why the namespace enforces baseline.
  jq -n --arg image "$(jq -r '.spec.ee_images[0].image' "$AWX")" '{"apiVersion": "v1", "kind": "Pod",
    "metadata": {"name": "automation-job-1-abcde", "labels": {"ansible_job": ""}},
    "spec": {"serviceAccountName": "default", "automountServiceAccountToken": false,
      "containers": [{"image": $image, "name": "worker", "args": ["ansible-runner", "worker", "--private-data-dir=/runner"],
        "resources": {"requests": {"cpu": "250m", "memory": "100Mi"}}}]}}' >"$BATS_TEST_TMPDIR/job.yaml"
  level_failures "$BATS_TEST_TMPDIR/job.yaml" "$NAMESPACE" baseline
  [ ! -s "$CONTROLS" ]
  level_failures "$BATS_TEST_TMPDIR/job.yaml" "$NAMESPACE" restricted
  echo "the job pod fails restricted on: $(paste -sd' ' "$CONTROLS")"
  [ -s "$CONTROLS" ]
  # One web and one task replica, no demonstration data, and the operator's requests written out
  # for every container, with a memory limit on the task container alone.
  [ "$(jq -c '[.spec.replicas, .spec.create_preload_data, (.spec.auto_upgrade // "unset"), (.spec.metrics_utility_enabled // "unset"),
    (.spec.web_replicas // "unset"), (.spec.task_replicas // "unset")]' "$AWX")" = '[1,false,"unset","unset","unset","unset"]' ]
  [ "$(jq -cS '[.spec | to_entries[] | select(.key | endswith("_resource_requirements"))] | from_entries' "$AWX")" \
    = '{"ee_resource_requirements":{"requests":{"cpu":"100m","memory":"64Mi"}},"init_container_resource_requirements":{"requests":{"cpu":"100m","memory":"128Mi"}},"redis_resource_requirements":{"requests":{"cpu":"50m","memory":"64Mi"}},"rsyslog_resource_requirements":{"requests":{"cpu":"100m","memory":"128Mi"}},"task_resource_requirements":{"limits":{"memory":"2Gi"},"requests":{"cpu":"100m","memory":"128Mi"}},"web_resource_requirements":{"requests":{"cpu":"100m","memory":"128Mi"}}}' ]
  docs "they are the operator's defaults and are not measured here"
}

@test "Ascender's namespace denies traffic by default and lets through only the flows its policies declare, and job pods reach the resolver and the world on 22 and 443 alone" {
  local deny view version web task migration job db db_replica pgdump policy
  local proxy='envoy-gateway-system:app.kubernetes.io/name=envoy,app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,gateway.envoyproxy.io/owning-gateway-name=public,gateway.envoyproxy.io/owning-gateway-namespace=envoy-gateway-system'
  local prometheus='monitoring:app.kubernetes.io/name=prometheus' other='other:app.kubernetes.io/name=app' dns='kube-system:k8s-app=kube-dns'
  local cnpg='cnpg-system:app.kubernetes.io/name=cloudnative-pg' store='openbao:app.kubernetes.io/name=openbao' hello='demo:app.kubernetes.io/name=hello'
  local web_labels='app.kubernetes.io/component=awx,app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/name=ascender-web'
  local task_labels='app.kubernetes.io/component=awx,app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/name=ascender-task'
  local instance_labels='app.kubernetes.io/component=awx,app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/part-of=ascender'
  render
  overlay
  built envoy-gateway
  # The namespace holds the default deny, every pod and both directions with no rule, and is not
  # listed among the namespaces without one.
  deny="$(yq -N -o json -I0 'select(.kind == "NetworkPolicy" and .metadata.namespace == "ascender")' "$OVERLAY")"
  [ "$(jq -cS '[.metadata.name, .spec]' <<<"$deny")" = '["default-deny",{"podSelector":{},"policyTypes":["Ingress","Egress"]}]' ]
  [ "$(NS="$NAMESPACE" yq '[.exceptions[] | select(.namespace == strenv(NS))] | length' "$REPO/network-policy-exceptions.yaml")" -eq 0 ]
  # The policies, and what each selects: the operator by the chart's labels, Ascender's pods by the
  # labels the operator's templates give them, the job pods by their label, the database as
  # Backstage's is.
  [ "$(yq -N 'select(.kind == "CiliumNetworkPolicy" or .kind == "NetworkPolicy" or .kind == "CiliumClusterwideNetworkPolicy") | .kind + "/" + .metadata.name' "$OPERATOR_BUILT" "$APP_BUILT" "$RENDERED" | LC_ALL=C sort | paste -sd' ' -)" \
    = "CiliumNetworkPolicy/ascender-db CiliumNetworkPolicy/ascender-db-instances CiliumNetworkPolicy/ascender-db-instances-world CiliumNetworkPolicy/ascender-db-pgdump CiliumNetworkPolicy/ascender-db-pgdump-world CiliumNetworkPolicy/ascender-instance CiliumNetworkPolicy/ascender-jobs CiliumNetworkPolicy/ascender-jobs-world-https CiliumNetworkPolicy/ascender-jobs-world-ssh CiliumNetworkPolicy/ascender-operator CiliumNetworkPolicy/ascender-task CiliumNetworkPolicy/ascender-task-world-https CiliumNetworkPolicy/ascender-task-world-ssh CiliumNetworkPolicy/ascender-web" ]
  for policy in $(yq -N 'select(.kind == "CiliumNetworkPolicy") | .metadata.name' "$OPERATOR_BUILT" "$APP_BUILT"); do
    [ "$(yq -N -o json -I0 "select(.kind == \"CiliumNetworkPolicy\" and .metadata.name == \"$policy\") | .spec.enableDefaultDeny" "$OPERATOR_BUILT" "$APP_BUILT" | jq -cS .)" = '{"egress":false,"ingress":false}' ]
  done
  [ "$(selector "$OPERATOR_BUILT" ascender-operator)" = "$(object "$RENDERED" Deployment awx-operator-controller-manager | yq -o json -I0 '.spec.selector.matchLabels' | jq -r 'to_entries | map(.key + "=" + .value) | sort | join(",")')" ]
  [ "$(selector "$OPERATOR_BUILT" ascender-operator)" = "control-plane=controller-manager,helm.sh/chart=ascender-operator" ]
  [ "$(selector "$APP_BUILT" ascender-web)" = "$web_labels" ]
  for policy in ascender-task ascender-task-world-https ascender-task-world-ssh; do
    [ "$(selector "$APP_BUILT" "$policy")" = "$task_labels" ]
  done
  [ "$(selector "$APP_BUILT" ascender-instance)" = "$instance_labels" ]
  for policy in ascender-jobs ascender-jobs-world-https ascender-jobs-world-ssh; do
    [ "$(selector "$APP_BUILT" "$policy")" = "ansible_job=" ]
  done
  # Each rule, by policy: the operator takes the kubelet on its health port and reaches the API
  # server alone, as it looks no name up.
  [ "$(container "$RENDERED" awx-manager | yq '[.livenessProbe.httpGet.port, .readinessProbe.httpGet.port] | unique | join(" ")')" = 6789 ]
  [ "$(rule_peers "$OPERATOR_BUILT" ascender-operator ingress)" = "@host -> 6789/TCP" ]
  [ "$(rule_peers "$OPERATOR_BUILT" ascender-operator egress)" = "@kube-apiserver -> 443/TCP 6443/TCP" ]
  # The web pods take the proxies, the kubelet's readiness probe and the task pods' relay on 8052.
  [ "$(rule_peers "$APP_BUILT" ascender-web ingress | LC_ALL=C sort)" = "$(printf '%s\n' \
    "@host -> 8052/TCP" \
    "$task_labels -> 8052/TCP" \
    "app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,app.kubernetes.io/name=envoy,gateway.envoyproxy.io/owning-gateway-name=public,gateway.envoyproxy.io/owning-gateway-namespace=envoy-gateway-system,k8s:io.kubernetes.pod.namespace=envoy-gateway-system -> 8052/TCP" | LC_ALL=C sort)" ]
  [ -z "$(rule_peers "$APP_BUILT" ascender-web egress)" ]
  # The task pods reach the web pods and the API server, and the world on 443 and on 22, each world
  # port by a policy of its own with its reason.
  [ "$(rule_peers "$APP_BUILT" ascender-task egress | LC_ALL=C sort)" = "$(printf '%s\n' "$web_labels -> 8052/TCP" "@kube-apiserver -> 443/TCP 6443/TCP" | LC_ALL=C sort)" ]
  [ -z "$(rule_peers "$APP_BUILT" ascender-task ingress)" ]
  [ "$(rule_peers "$APP_BUILT" ascender-task-world-https egress)" = "@world -> 443/TCP" ]
  [ "$(rule_peers "$APP_BUILT" ascender-task-world-ssh egress)" = "@world -> 22/TCP" ]
  # Every pod of the instance, the migration job's included, reaches the resolver and the database.
  [ "$(rule_peers "$APP_BUILT" ascender-instance egress | LC_ALL=C sort)" = "$(printf '%s\n' \
    "k8s:io.kubernetes.pod.namespace=kube-system,k8s:k8s-app=kube-dns -> 53/TCP 53/UDP" \
    "cnpg.io/cluster=ascender-db,cnpg.io/podRole=instance -> 5432/TCP" | LC_ALL=C sort)" ]
  [ -z "$(rule_peers "$APP_BUILT" ascender-instance ingress)" ]
  # The job pods reach the resolver, and the world on 443 and 22 by a policy each, and take nothing.
  [ "$(rule_peers "$APP_BUILT" ascender-jobs egress)" = "k8s:io.kubernetes.pod.namespace=kube-system,k8s:k8s-app=kube-dns -> 53/TCP 53/UDP" ]
  [ "$(rule_peers "$APP_BUILT" ascender-jobs-world-https egress)" = "@world -> 443/TCP" ]
  [ "$(rule_peers "$APP_BUILT" ascender-jobs-world-ssh egress)" = "@world -> 22/TCP" ]
  for policy in ascender-jobs ascender-jobs-world-https ascender-jobs-world-ssh; do
    [ -z "$(rule_peers "$APP_BUILT" "$policy" ingress)" ]
  done
  # Each world rule is the one rule of its policy, with its reason; no other policy has a reason.
  for policy in ascender-task-world-https ascender-task-world-ssh ascender-jobs-world-https ascender-jobs-world-ssh ascender-db-instances-world ascender-db-pgdump-world; do
    [ -n "$(object "$APP_BUILT" CiliumNetworkPolicy "$policy" | yq '.metadata.annotations["k8s-gitops/network-policy-reason"] // ""')" ]
  done
  [ "$(yq -N 'select(.kind == "CiliumNetworkPolicy" and .metadata.annotations["k8s-gitops/network-policy-reason"] == null) | .metadata.name' "$APP_BUILT" "$OPERATOR_BUILT" | LC_ALL=C sort | paste -sd' ' -)" \
    = "ascender-db ascender-db-instances ascender-db-pgdump ascender-instance ascender-jobs ascender-operator ascender-task ascender-web" ]
  # The database's instances take every pod of the instance and the dump job on 5432, Prometheus on
  # the exporter's port and the kubelet on the status port, as Backstage's do.
  [ "$(rule_peers "$APP_BUILT" ascender-db-instances ingress | LC_ALL=C sort)" = "$(printf '%s\n' \
    "$instance_labels app.kubernetes.io/instance=ascender-db,app.kubernetes.io/name=pgdump -> 5432/TCP" \
    "app.kubernetes.io/name=prometheus,k8s:io.kubernetes.pod.namespace=monitoring -> 9187/TCP" \
    "@host -> 8000/TCP" | LC_ALL=C sort)" ]
  # The proxies' egress names the web pods of ascender on 8052, by the namespace's Gateway label.
  [[ $'\n'"$(rule_peers "$BUILT" public-proxy egress)"$'\n' == *$'\n'"$web_labels,k8s:io.cilium.k8s.namespace.labels.k8s-gitops/gateway=public,k8s:io.kubernetes.pod.namespace=ascender -> 8052/TCP"$'\n'* ]]
  # The flows, evaluated on the namespace's default deny, the policies and the rendered operator.
  # Ascender's pods are the operator's, which no render holds, by the labels its templates give them
  # at the recorded release, the version label from the image's digest; the job pods by Ascender's.
  version="$(jq -r '.spec.image_version | split(":")[-1] | .[0:63]' "$AWX")"
  web="ascender:app.kubernetes.io/name=ascender-web,app.kubernetes.io/part-of=ascender,app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/component=awx,app.kubernetes.io/operator-version=25.6.3,app.kubernetes.io/version=$version"
  task="ascender:app.kubernetes.io/name=ascender-task,app.kubernetes.io/part-of=ascender,app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/component=awx,app.kubernetes.io/operator-version=25.6.3,app.kubernetes.io/version=$version"
  migration="ascender:app.kubernetes.io/part-of=ascender,app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/component=awx,app.kubernetes.io/operator-version=25.6.3,app.kubernetes.io/version=$version"
  job='ascender:ansible_job=,ansible-awx=00000000-0000-0000-0000-000000000000,ansible-awx-job-id=1'
  db='ascender:cnpg.io/cluster=ascender-db,cnpg.io/instanceName=ascender-db-1,cnpg.io/podRole=instance,app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=ascender-db,app.kubernetes.io/component=database,app.kubernetes.io/managed-by=cloudnative-pg'
  db_replica='ascender:cnpg.io/cluster=ascender-db,cnpg.io/instanceName=ascender-db-2,cnpg.io/podRole=instance,app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=ascender-db,app.kubernetes.io/component=database,app.kubernetes.io/managed-by=cloudnative-pg'
  pgdump=ascender/CronJob/ascender-db-pgdump
  # The release's namespaced objects name no namespace, and Helm installs them into the release's.
  yq 'select(.kind | test("^Cluster") | not) |= (.metadata.namespace = "ascender")' "$RENDERED" >"$BATS_TEST_TMPDIR/operator-placed.yaml"
  view="$BATS_TEST_TMPDIR/flows"
  flows "$view" "$OVERLAY" "$OPERATOR_BUILT" "$APP_BUILT" "$BATS_TEST_TMPDIR/operator-placed.yaml" "$BUILT"
  # The operator.
  allowed "$view" @host "$OPERATOR" 6789/tcp
  allowed "$view" "$OPERATOR" @kube-apiserver 443/tcp
  allowed "$view" "$OPERATOR" @kube-apiserver 6443/tcp
  denied "$view" "$OPERATOR" "$dns" 53/udp
  denied "$view" "$OPERATOR" @world 443/tcp
  denied "$view" "$OPERATOR" "$web" 8052/tcp
  denied "$view" "$OPERATOR" "$db" 5432/tcp
  denied "$view" "$prometheus" "$OPERATOR" 8443/tcp
  denied "$view" "$proxy" "$OPERATOR" 8443/tcp
  denied "$view" "$proxy" "$OPERATOR" 6789/tcp
  denied "$view" @world "$OPERATOR" 6789/tcp
  denied "$view" "$job" "$OPERATOR" 6789/tcp
  # The web pods.
  allowed "$view" "$proxy" "$web" 8052/tcp
  allowed "$view" @host "$web" 8052/tcp
  allowed "$view" "$task" "$web" 8052/tcp
  allowed "$view" "$web" "$dns" 53/udp
  allowed "$view" "$web" "$dns" 53/tcp
  allowed "$view" "$web" "$db" 5432/tcp
  allowed "$view" "$web" "$db_replica" 5432/tcp
  denied "$view" "$proxy" "$web" 8050/tcp
  denied "$view" "$proxy" "$web" 22/tcp
  denied "$view" @world "$web" 8052/tcp
  denied "$view" @remote-node "$web" 8052/tcp
  denied "$view" "$other" "$web" 8052/tcp
  denied "$view" "$job" "$web" 8052/tcp
  denied "$view" "$prometheus" "$web" 8052/tcp
  denied "$view" envoy-gateway-system:app=certgen "$web" 8052/tcp
  denied "$view" envoy-gateway-system:app.kubernetes.io/name=envoy "$web" 8052/tcp
  denied "$view" "$web" @world 443/tcp
  denied "$view" "$web" @world 80/tcp
  denied "$view" "$web" @kube-apiserver 443/tcp
  denied "$view" "$web" "$task" 8052/tcp
  # The task pods.
  allowed "$view" "$task" @kube-apiserver 443/tcp
  allowed "$view" "$task" @kube-apiserver 6443/tcp
  allowed "$view" "$task" @world 443/tcp
  allowed "$view" "$task" @world 22/tcp
  allowed "$view" "$task" "$dns" 53/udp
  allowed "$view" "$task" "$db" 5432/tcp
  denied "$view" "$task" @world 80/tcp
  denied "$view" "$task" @world 5432/tcp
  denied "$view" "$task" "$job" 22/tcp
  denied "$view" "$task" "$store" 8200/tcp
  denied "$view" "$proxy" "$task" 8052/tcp
  denied "$view" @world "$task" 22/tcp
  denied "$view" "$web" "$task" 27199/tcp
  # The migration job, as every pod of the instance.
  allowed "$view" "$migration" "$dns" 53/udp
  allowed "$view" "$migration" "$db" 5432/tcp
  denied "$view" "$migration" @world 443/tcp
  denied "$view" "$migration" @kube-apiserver 443/tcp
  # The job pods.
  allowed "$view" "$job" "$dns" 53/udp
  allowed "$view" "$job" "$dns" 53/tcp
  allowed "$view" "$job" @world 443/tcp
  allowed "$view" "$job" @world 22/tcp
  denied "$view" "$job" @world 80/tcp
  denied "$view" "$job" @world 5432/tcp
  denied "$view" "$job" @world 8080/tcp
  denied "$view" "$job" "$db" 5432/tcp
  denied "$view" "$job" "$db_replica" 5432/tcp
  denied "$view" "$job" "$web" 8052/tcp
  denied "$view" "$job" "$task" 8052/tcp
  denied "$view" "$job" @kube-apiserver 443/tcp
  denied "$view" "$job" @kube-apiserver 6443/tcp
  denied "$view" "$job" @host 10250/tcp
  denied "$view" "$job" @remote-node 10250/tcp
  denied "$view" "$job" "$other" 8080/tcp
  denied "$view" "$job" "$hello" 8080/tcp
  denied "$view" "$job" "$store" 8200/tcp
  denied "$view" "$job" "$prometheus" 9090/tcp
  denied "$view" "$job" "$OPERATOR" 6789/tcp
  denied "$view" @world "$job" 22/tcp
  denied "$view" "$proxy" "$job" 8052/tcp
  denied "$view" "$task" "$job" 2222/tcp
  # The database: Ascender's pods and the dump job reach it, the proxies, the job pods and other
  # applications do not.
  allowed "$view" "$pgdump" "$db" 5432/tcp
  allowed "$view" "$prometheus" "$db" 9187/tcp
  allowed "$view" "$cnpg" "$db" 8000/tcp
  allowed "$view" "$db" @world 443/tcp
  allowed "$view" "$pgdump" @world 443/tcp
  denied "$view" "$proxy" "$db" 5432/tcp
  denied "$view" "$other" "$db" 5432/tcp
  denied "$view" @world "$db" 5432/tcp
  denied "$view" "$db" @world 22/tcp
  denied "$view" "$pgdump" @world 22/tcp
  # No monitor scrapes anything of Ascender but the database: the component's PodMonitor of its
  # instances. Ascender's metrics need a session or a token, and the operator's are behind its
  # proxy.
  [ "$(yq -N 'select(.kind == "ServiceMonitor" or .kind == "PodMonitor") | .kind + "/" + .metadata.name' "$OPERATOR_BUILT" "$APP_BUILT" "$RENDERED" | paste -sd' ' -)" = PodMonitor/ascender-db ]
  # Without the namespace's default deny the same policies deny nothing.
  yq 'select((.kind == "NetworkPolicy" and .metadata.namespace == "ascender") | not)' "$OVERLAY" >"$view/$(basename "$OVERLAY")"
  allowed "$view" "$job" "$db" 5432/tcp
  allowed "$view" @world "$web" 8052/tcp
}

@test "Ascender is reached by its own hostname on the public Gateway with no sign-in in front, and its probe asks an endpoint that answers without a session" {
  local ns domain service route probe hello other
  both
  overlay
  domain="$(yq '.CLUSTER_DOMAIN' "$VARS")"
  # The namespace carries the label the public Gateway admits routes by.
  ns="$(object "$OVERLAY" Namespace "$NAMESPACE")"
  [ "$(yq '.metadata.labels["k8s-gitops/gateway"]' <<<"$ns")" = public ]
  # The tree's own Service of the web pods, as the operator's is made at run time: the web pods'
  # three labels, port 80 to the numbered container port 8052.
  service="$(object "$APP_BUILT" Service ascender-web | yq -o json -I0 '.spec' | jq -cS .)"
  [ "$service" = '{"ports":[{"name":"http","port":80,"protocol":"TCP","targetPort":8052}],"selector":{"app.kubernetes.io/component":"awx","app.kubernetes.io/managed-by":"awx-operator","app.kubernetes.io/name":"ascender-web"},"type":"ClusterIP"}' ]
  # The route: the hostname under the cluster's domain, the https listener of public, one rule, every
  # method and path, no filter.
  route="$(object "$APP_BUILT" HTTPRoute ascender | yq -o json -I0 '.spec' | jq -cS .)"
  [ "$route" = "{\"hostnames\":[\"ascender.$domain\"],\"parentRefs\":[{\"name\":\"public\",\"namespace\":\"envoy-gateway-system\",\"sectionName\":\"https\"}],\"rules\":[{\"backendRefs\":[{\"name\":\"ascender-web\",\"port\":80}]}]}" ]
  # Nothing in front: no policy of Envoy Gateway's on the route, no sign-in and no firewall.
  [ -z "$(yq -N 'select(.apiVersion | test("gateway.envoyproxy.io")) | .kind + "/" + .metadata.name' "$APP_BUILT")" ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "ascender") | .spec.components | map(select(test("/components/(sso|waf)$"))) | length' "$OVERLAY")" -eq 0 ]
  # The Probe has hello-route's shape, at Ascender's ping endpoint with the trailing slash Django
  # would otherwise redirect to, and the route's hostname.
  probe="$(object "$APP_BUILT" Probe ascender | yq -o json -I0 '.spec' | jq -cS .)"
  hello="$(yq -o json -I0 '.spec' "$REPO/kubernetes/apps/base/demo/hello-route/app/probe.yaml" | jq -cS --arg domain "$domain" '
    .targets.staticConfig.static |= map(. + "api/v2/ping/") | .targets.staticConfig.labels.hostname = "ascender." + $domain')"
  echo "probe: $probe"
  [ "$probe" = "$hello" ]
  [[ $probe == *'/api/v2/ping/"]'* ]]
  # The web settings: the route's https origin trusted for CSRF, from the same substitution as the
  # hostname, cookies marked secure, no Ingress and a ClusterIP Service of the operator's, and the
  # probes on.
  [ "$(jq -c '.spec.extra_settings' "$AWX")" = "[{\"setting\":\"CSRF_TRUSTED_ORIGINS\",\"value\":\"[\\\"https://ascender.$domain\\\"]\"}]" ]
  [ "$(jq -c '[.spec.csrf_cookie_secure, .spec.session_cookie_secure, .spec.service_type, .spec.ingress_type]' "$AWX")" = '["true","true","ClusterIP","none"]' ]
  [ "$(jq -c '[.spec.web_readiness_period, .spec.web_liveness_period, .spec.task_liveness_period]' "$AWX")" = '[15,15,15]' ]
  # The liveness probes ask the supervisor whether every program is RUNNING, which each is only 30
  # seconds after it starts (startsecs in the image's supervisord files): they begin after that.
  [ "$(jq -c '[.spec.web_liveness_initial_delay, .spec.task_liveness_initial_delay]' "$AWX")" = '[60,60]' ]
  docs "publishes the version, the pod names and the installation's identifier"
  # The route's hostname, the Probe's and the trusted origin are each the cluster's domain's: built
  # for another domain, all three name it.
  other=other.example.net
  OTHER="$other" yq -i '.CLUSTER_DOMAIN = strenv(OTHER)' "$VARS"
  built ascender
  echo "for $other: $(object "$BUILT" HTTPRoute ascender | yq -o json -I0 '.spec.hostnames'), $(object "$BUILT" Probe ascender | yq '.spec.targets.staticConfig.labels.hostname'), $(yq -N -o json -I0 'select(.kind == "AWX") | .spec.extra_settings' "$BUILT")"
  [ "$(object "$BUILT" HTTPRoute ascender | yq -o json -I0 '.spec.hostnames' | jq -c .)" = "[\"ascender.$other\"]" ]
  [ "$(object "$BUILT" Probe ascender | yq '.spec.targets.staticConfig.labels.hostname')" = "ascender.$other" ]
  [ "$(yq -N -o json -I0 'select(.kind == "AWX") | .spec.extra_settings' "$BUILT" | jq -c .)" \
    = "[{\"setting\":\"CSRF_TRUSTED_ORIGINS\",\"value\":\"[\\\"https://ascender.$other\\\"]\"}]" ]
}

@test "Ascender's database comes from the PostgreSQL component, and no secret is in the tree" {
  local ks cluster generator es keys restore
  both
  ks="$(yq -o json -I0 '.' "$BATS_TEST_TMPDIR/ascender-ks.yaml")"
  # The component, for the cluster ascender-db in the namespace ascender, 5Gi for each instance, as
  # job events grow until the weekly cleanup removes those older than 120 days.
  [ "$(jq -c '.spec.components' <<<"$ks")" = '["../../../../../components/cnpg-cluster"]' ]
  [ "$(jq -c '.spec.postBuild.substitute | {CNPG_CLUSTER_NAME, CNPG_NAMESPACE, CNPG_STORAGE_SIZE}' <<<"$ks")" = '{"CNPG_CLUSTER_NAME":"ascender-db","CNPG_NAMESPACE":"ascender","CNPG_STORAGE_SIZE":"5Gi"}' ]
  cluster="$(yq -N -o json -I0 'select(.kind == "Cluster")' "$APP_BUILT")"
  [ "$(jq -c '[.metadata.name, .spec.instances, .spec.storage.size]' <<<"$cluster")" = '["ascender-db",3,"5Gi"]' ]
  [ "$(jq -cS '.spec.bootstrap' <<<"$cluster")" = '{"initdb":{"database":"app","owner":"app","secret":{"name":"ascender-db-app"}}}' ]
  # A restore to a point in time adds a Cluster of its own beside the component's in app/, as the
  # restore runbook says. Built so, the patch reaches the component's Cluster alone: the restore
  # keeps the runbook's recovery from the archive of ascender-db, and the component's its initdb.
  restore="$BATS_TEST_TMPDIR/ascender-db-restored.yaml"
  runbook_cluster ascender-db "$restore"
  [ "$(yq '.metadata.name + " " + (.spec.bootstrap | keys | join(","))' "$restore")" = "ascender-db-restored recovery" ]
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  mkdir -p "$TREE"
  cp -r "$REPO/kubernetes" "$TREE/kubernetes"
  cp "$restore" "$TREE/kubernetes/apps/base/ascender/ascender/app/"
  yq -i '.resources += ["ascender-db-restored.yaml"]' "$TREE/kubernetes/apps/base/ascender/ascender/app/kustomization.yaml"
  flux_build ascender "$BATS_TEST_TMPDIR/ascender-ks.yaml" "$TREE" >"$BATS_TEST_TMPDIR/restore-built.yaml"
  echo "the restore's bootstrap: $(object "$BATS_TEST_TMPDIR/restore-built.yaml" Cluster ascender-db-restored | yq -o json -I0 '.spec.bootstrap')"
  [ "$(object "$BATS_TEST_TMPDIR/restore-built.yaml" Cluster ascender-db-restored | yq -o json -I0 '.spec.bootstrap' | jq -cS .)" \
    = "$(yq -o json -I0 '.spec.bootstrap' "$restore" | jq -cS .)" ]
  [ "$(object "$BATS_TEST_TMPDIR/restore-built.yaml" Cluster ascender-db | yq -o json -I0 '.spec.bootstrap' | jq -cS .)" \
    = '{"initdb":{"database":"app","owner":"app","secret":{"name":"ascender-db-app"}}}' ]
  # PostgreSQL 18, the component's, which Ascender accepts, and its default number of connections.
  [[ $(jq -r '.spec.imageName' <<<"$cluster") == ghcr.io/cloudnative-pg/postgresql:18.* ]]
  [ "$(jq -c '.spec.postgresql.parameters.max_connections // "unset"' <<<"$cluster")" = '"unset"' ]
  # The dump job's pods carry the labels its policies select.
  [ "$(yq -N -o json -I0 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.metadata.labels' "$APP_BUILT" | jq -cS .)" \
    = '{"app.kubernetes.io/instance":"ascender-db","app.kubernetes.io/name":"pgdump"}' ]
  # The Secret ascender-db-app, made once by External Secrets from a generated password in the
  # operator's application, so that it exists before ascender applies the AWX: the operator reads it
  # once at the start of its run and makes a PostgreSQL of its own without it.
  generator="$(yq -N -o json -I0 'select(.kind == "Password")' "$OPERATOR_BUILT")"
  [ "$(jq -cS '[.apiVersion, .metadata.name, .spec]' <<<"$generator")" = '["generators.external-secrets.io/v1alpha1","ascender-db-app",{"allowRepeat":true,"encoding":"hex","length":32,"noUpper":false,"secretKeys":["password"]}]' ]
  es="$(yq -N -o json -I0 'select(.kind == "ExternalSecret")' "$OPERATOR_BUILT")"
  [ "$(jq -c '[.metadata.name, .spec.refreshPolicy, .spec.target.name, .spec.target.creationPolicy, .spec.target.template.type, .spec.target.template.engineVersion, .spec.target.template.mergePolicy]' <<<"$es")" \
    = '["ascender-db-app","CreatedOnce","ascender-db-app","Owner","kubernetes.io/basic-auth","v2","Replace"]' ]
  [ "$(jq -cS '.spec.dataFrom' <<<"$es")" = '[{"sourceRef":{"generatorRef":{"apiVersion":"generators.external-secrets.io/v1alpha1","kind":"Password","name":"ascender-db-app"}}}]' ]
  keys="$(jq -cS '.spec.target.template.data' <<<"$es")"
  [ "$keys" = '{"database":"app","dbname":"app","host":"ascender-db-rw","password":"{{ .password }}","port":"5432","sslmode":"require","type":"unmanaged","username":"app"}' ]
  [ -z "$(yq -N 'select(.kind == "ExternalSecret" or .kind == "Password") | .metadata.name' "$APP_BUILT" | grep -vE '^ascender-db-(backup|dump-s3)$' || true)" ]
  # The AWX names it as its database, and leaves the admin password and the secret key to the
  # operator, which keeps the Secrets it makes after the AWX.
  [ "$(jq -c '[.spec.postgres_configuration_secret, .spec.admin_user, .spec.garbage_collect_secrets, (.spec.admin_password_secret // "unset"), (.spec.secret_key_secret // "unset"), (.spec.broadcast_websocket_secret // "unset")]' "$AWX")" \
    = '["ascender-db-app","admin",false,"unset","unset","unset"]' ]
  # The task container's memory limit, which the operator writes as SYSTEM_TASK_ABS_MEM
  # (roles/installer/templates/configmaps/config.yaml.j2 of its tag), the memory the dispatcher
  # sizes its pool of workers by. The sum of connections that follows, under PostgreSQL's default of
  # 100, is worked out in the docs from the image's source, not here (docs/kubernetes.md, Ascender).
  [ "$(jq -r '.spec.task_resource_requirements.limits.memory' "$AWX")" = 2Gi ]
  docs "50 connections at most"
  # Nothing secret is built: no Secret object in either application, and no password in a manifest.
  [ -z "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$OPERATOR_BUILT" "$APP_BUILT")" ]
  [ -z "$(grep -rniE '(password|secret_key)[^:]*: *[A-Za-z0-9+/]{16,}' "$BASE" || true)" ]
  docs "kubectl --namespace ascender get secret ascender-admin-password --output jsonpath='{.data.password}' | base64 -d; echo"
}
