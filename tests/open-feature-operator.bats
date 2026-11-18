#!/usr/bin/env bats
# Proves features/open-feature-operator.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq, jq and kyverno on PATH (the versions pinned for the repository).
# The operator's chart is pulled once per run from its public registry; building, rendering and the
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
  NAMESPACE="open-feature-operator"
  APP="$REPO/kubernetes/apps/base/open-feature-operator/open-feature-operator"
  EXAMPLE_APP="$REPO/kubernetes/apps/base/demo/hello-flags"
  OPERATOR="$NAMESPACE/Deployment/open-feature-operator-controller-manager"
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

# flux_build NAME KS: what the Flux Kustomization in the file KS applies, built from its spec.path
# with strict substitution. In memory: flux build otherwise rewrites the kustomization.yaml of what
# it builds, in the checkout, and puts it back afterwards.
flux_build() {
  local path
  path="$(yq '.spec.path' "$2")"
  (cd "$REPO" && flux build kustomization "$1" --path "./kubernetes/${path#./}" \
    --kustomization-file "$2" --dry-run --strict-substitute --in-memory-build)
}

# built: the operator's application as Flux applies it on lab-sto2. The cluster's root is built as
# Flux builds it, so the overlay's Kustomization of the application carries what the root patches
# into every child, the release defaults among them; that Kustomization is then built with the
# example key lists under its own substitutions. Writes the root's build to $ROOT and the
# application's to $BUILT, and sets KS, the Kustomization as the root builds it.
built() {
  local root="$CLUSTER/ks.yaml" path
  path="$(yq '.spec.path' "$root")"
  ROOT="$BATS_TEST_TMPDIR/root.yaml"
  (cd "$REPO" && flux build kustomization "$(yq '.metadata.name' "$root")" \
    --path "./kubernetes/${path#./}" --kustomization-file "$root" --dry-run --in-memory-build) >"$ROOT"
  KS="$BATS_TEST_TMPDIR/operator-ks.yaml"
  with_vars open-feature-operator "$ROOT" >"$KS"
  [ -s "$KS" ] || { echo "the lab-sto2 overlay does not enable open-feature-operator"; return 1; }
  BUILT="$BATS_TEST_TMPDIR/operator-built.yaml"
  flux_build open-feature-operator "$KS" >"$BUILT"
}

# render: the chart the HelmRelease installs, from the URL and tag of its OCIRepository, with the
# values of the ConfigMap the HelmRelease reads, rendered the way helm-controller renders a release.
# helm-controller hands Helm a post-renderer for every release, its own labels at the least, and
# Helm then merges what the chart renders into one stream with its own reader before the
# post-renderer sees it, and reads the result again: a document either reader refuses fails the
# release. So the chart is rendered through Helm's post-render step, with a plugin that runs what
# helm-controller chains: each kustomize post-renderer of the HelmRelease in turn, then the labels
# that name the HelmRelease on every object. Builds the application, writes
# $BATS_TEST_TMPDIR/operator.yaml and sets BUILT, RENDERED, VALUES, CHART and DEFAULTS, the chart's
# own values.
render() {
  local url tag name release namespace pulled post count i
  built
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  [ "$release" = open-feature-operator ] && [ "$namespace" = "$NAMESPACE" ] ||
    { echo "the release is $release in $namespace, not open-feature-operator in $NAMESPACE"; return 1; }
  VALUES="$BATS_TEST_TMPDIR/values.yaml"
  NAME="$name" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .data["values.yaml"]' "$BUILT" >"$VALUES"
  [ -s "$VALUES" ] || { echo "no values in the ConfigMap $name the HelmRelease reads"; return 1; }
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.values // {} | length' "$BUILT")" -eq 0 ] ||
    { echo "the HelmRelease has values of its own beside its ConfigMap"; return 1; }
  pulled="$BATS_FILE_TMPDIR/charts/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  DEFAULTS="$BATS_TEST_TMPDIR/chart-values.yaml"
  helm show values "$CHART" >"$DEFAULTS"
  # The steps of the post-render, one kustomization each. Only kustomize post-renderers are known
  # here, so any other kind fails instead of being skipped.
  post="$BATS_TEST_TMPDIR/post-render"
  rm -rf "$post"
  mkdir -p "$post/steps" "$post/plugins/release"
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.postRenderers // [] | map(select((keys | join(",")) != "kustomize")) | length' "$BUILT")" -eq 0 ] ||
    { echo "the HelmRelease has a post-renderer that is not kustomize"; return 1; }
  count="$(yq -N 'select(.kind == "HelmRelease") | .spec.postRenderers // [] | length' "$BUILT")"
  for ((i = 0; i < count; i++)); do
    I="$i" yq -N -o json 'select(.kind == "HelmRelease") | {"apiVersion": "kustomize.config.k8s.io/v1beta1",
      "kind": "Kustomization", "resources": ["helm-output.yaml"]} + .spec.postRenderers[env(I)].kustomize' "$BUILT" \
      >"$post/steps/$(printf '%03d' "$i").json"
  done
  # helm-controller's own step: the labels that name the HelmRelease, on each object's metadata.
  NAME="$(yq -N 'select(.kind == "HelmRelease") | .metadata.name' "$BUILT")" \
    NS="$(yq -N 'select(.kind == "HelmRelease") | .metadata.namespace' "$BUILT")" \
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
    --kube-version "$KUBE" --values "$VALUES" --post-renderer release >"$RENDERED"
}

# object FILE KIND NAME: the one object of that kind and name in FILE.
object() {
  KIND="$2" NAME="$3" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$1"
}

# deployment: writes the operator's Deployment of the render to $DEPLOYMENT and its container
# manager to $CONTAINER.
deployment() {
  DEPLOYMENT="$BATS_TEST_TMPDIR/deployment.yaml"
  CONTAINER="$BATS_TEST_TMPDIR/container.yaml"
  object "$RENDERED" Deployment open-feature-operator-controller-manager >"$DEPLOYMENT"
  [ -s "$DEPLOYMENT" ] || { echo "the render has no Deployment open-feature-operator-controller-manager"; return 1; }
  yq '.spec.template.spec.containers[] | select(.name == "manager")' "$DEPLOYMENT" >"$CONTAINER"
  [ -s "$CONTAINER" ] || { echo "the pod has no container manager"; return 1; }
}

# env_value NAME: the value the operator's container gets for the environment variable NAME.
env_value() {
  NAME="$1" yq '.env[] | select(.name == strenv(NAME)) | .value' "$CONTAINER"
}

# tag_comment KEY: the line above the first tag under the top-level key KEY of the values file,
# without its indentation: the comment Renovate reads that pin by.
tag_comment() {
  awk -v key="$1:" '$0 == key { inside = 1; next }
    inside && /^[^ #]/ { exit }
    inside && /^ +tag: / { sub(/^ +/, "", previous); print previous; exit }
    { previous = $0 }' "$APP/app/values.yaml"
}

# restricted_failures FILE NAMESPACE: what the Pod Security restricted level refuses in the pod the
# workload in FILE makes in NAMESPACE, by Kyverno's podSecurity rule as pod-security-check runs it:
# writes the failed controls, one per line, to $CONTROLS and the whole message to $FORBIDDEN.
restricted_failures() {
  local dir="$BATS_TEST_TMPDIR/restricted-$2"
  rm -rf "$dir"
  mkdir -p "$dir"
  # As JSON: Kyverno reads YAML 1.1, where an unquoted true is a boolean, and the label a pod asks
  # by has the string "true" for its value.
  NS="$2" yq -o json '{"apiVersion": "v1", "kind": "Pod",
    "metadata": {"name": .metadata.name, "namespace": strenv(NS)} * (.spec.template.metadata | pick(["labels", "annotations"])),
    "spec": .spec.template.spec}' "$1" >"$dir/pod.yaml"
  cat >"$dir/policy.yaml" <<'POLICY'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restricted
spec:
  validationFailureAction: Enforce
  rules:
    - name: restricted
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        podSecurity:
          level: restricted
          version: latest
POLICY
  # Exit 1 is a failed pod, which is the verdict; the report is the one line that starts with a brace.
  kyverno apply "$dir/policy.yaml" --resource "$dir/pod.yaml" -p --output-format json >"$dir/out" 2>"$dir/err" || [ $? -eq 1 ]
  grep '^{' "$dir/out" >"$dir/report.json"
  # A pod Kyverno gave no verdict on has not passed.
  jq -e '.results | length == 1 and (.[0].result == "pass" or .[0].result == "fail")' "$dir/report.json" >/dev/null ||
    { echo "Kyverno gave no verdict on the pod: $(cat "$dir/out" "$dir/err")"; return 1; }
  CONTROLS="$dir/controls"
  FORBIDDEN="$dir/forbidden"
  jq -r '.results[0] | select(.result == "fail") | .properties.controls // "" | split(",") | .[] | select(. != "")' "$dir/report.json" | LC_ALL=C sort >"$CONTROLS"
  jq -r '.results[0] | select(.result == "fail") | .message // ""' "$dir/report.json" >"$FORBIDDEN"
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

# of_namespace FILE: what an overlay built into FILE holds of the operator and of its namespace,
# sorted, as kind, namespace and name: the namespace itself, any object in it, and any Kustomization
# that deploys into it or from its directory.
of_namespace() {
  yq -N 'select((.kind == "Namespace" and .metadata.name == "open-feature-operator") or .metadata.namespace == "open-feature-operator"
      or .spec.targetNamespace == "open-feature-operator" or ((.spec.path // "") | test("/apps/base/open-feature-operator/")))
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

@test "The OpenFeature Operator is selected by overlay entries and builds nothing when it is not" {
  local dependency
  local -A entry=([cluster-ca]='/cert-manager/cluster-ca/ks.yaml$' [prometheus-operator-crds]='/kube-system/prometheus-operator-crds/ks.yaml$'
    [cilium]='/kube-system/cilium/ks.yaml$')
  # The overlay selects it with two entries, the namespace directory and the application's ks.yaml.
  [ "$(yq '.resources[] | select(test("/open-feature-operator(/|$)"))' "$OVERLAY_DIR/kustomization.yaml" | LC_ALL=C sort | paste -sd' ' -)" \
    = "../../base/open-feature-operator ../../base/open-feature-operator/open-feature-operator/ks.yaml" ]
  overlay
  [ "$(of_namespace "$OVERLAY")" = ConfigMap/open-feature-operator/app-template-defaults,Kustomization/flux-system/open-feature-operator,Namespace/-/open-feature-operator,NetworkPolicy/open-feature-operator/default-deny ]
  # It waits for what its objects need to exist first: the issuer its Certificates name, the
  # definition of its monitor's kind and the definition of its policies' kind; and it is Ready only
  # once its release is.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "open-feature-operator") | .spec.dependsOn | map(.name) | join(" ")' "$OVERLAY")" = "cluster-ca prometheus-operator-crds cilium" ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "open-feature-operator") | .spec.wait' "$OVERLAY")" = true ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "open-feature-operator") | .spec.targetNamespace' "$OVERLAY")" = "$NAMESPACE" ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # With only the namespace directory's entry, the cluster builds the namespace, its defaults and
  # its default deny, and nothing of the operator.
  tree_without '/open-feature-operator/open-feature-operator/ks.yaml$'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ "$(of_namespace "$OVERLAY")" = ConfigMap/open-feature-operator/app-template-defaults,Namespace/-/open-feature-operator,NetworkPolicy/open-feature-operator/default-deny ]
  # With neither, nothing of the namespace.
  tree_without '/open-feature-operator(/|$)'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ -z "$(of_namespace "$OVERLAY")" ]
  # Selecting it without one of the applications it waits for is refused, naming both.
  for dependency in cluster-ca prometheus-operator-crds cilium; do
    tree_without "${entry[$dependency]}"
    run "$REPO/scripts/kubernetes-check" "$TREE"
    echo "without $dependency: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"kubernetes/apps/base/open-feature-operator/open-feature-operator/ks.yaml: Kustomization open-feature-operator names $dependency"* ]]
    [[ $output == *"does not enable"* ]]
  done
  # The namespace is the tree's: the chart is told to make none, and the release renders none, nor
  # anything outside its namespace that is not cluster-scoped.
  render
  [ "$(yq '.namespace.create' "$VALUES")" = false ]
  [ -z "$(yq -N 'select(.kind == "Namespace") | .metadata.name' "$RENDERED")" ]
  [ "$(yq -N 'select(.metadata.namespace != null) | .metadata.namespace' "$RENDERED" | LC_ALL=C sort -u)" = "$NAMESPACE" ]
  # Helm's own reader drops the template that renders only comments: each source of the render is
  # one object with a kind and a name, and the chart's namespace template is not among them.
  [ "$(grep -c '^# Source: ' "$RENDERED")" -eq "$(yq -N 'select(. != null) | .kind' "$RENDERED" | grep -c .)" ]
  [ "$(yq -N 'select(. != null) | (.kind // "") == "" or (.metadata.name // "") == ""' "$RENDERED" | LC_ALL=C sort -u)" = false ]
  [ "$(grep -c '^# Source: .*/templates/namespace\.yaml$' "$RENDERED" || true)" -eq 0 ]
}

@test "The operator's webhooks see only a pod that asks, skip the system namespaces and fail open" {
  local webhooks mutating validating grants service bindings roles
  render
  deployment
  # The release registers exactly two webhook configurations, one webhook each, and no other object
  # of the admission registration API.
  webhooks="$(yq -N 'select(.apiVersion == "admissionregistration.k8s.io/*")
    | .kind + "/" + .metadata.name + " " + ((.webhooks // []) | map(.name) | join(","))' "$RENDERED" | LC_ALL=C sort)"
  echo "$webhooks"
  [ "$webhooks" = "$(printf '%s\n' \
    'MutatingWebhookConfiguration/open-feature-operator-mutating-webhook-configuration mutate.openfeature.dev' \
    'ValidatingWebhookConfiguration/open-feature-operator-validating-webhook-configuration vfeatureflag.kb.io')" ]
  mutating="$(object "$RENDERED" MutatingWebhookConfiguration open-feature-operator-mutating-webhook-configuration | yq -o json -I0 '.webhooks[0]')"
  validating="$(object "$RENDERED" ValidatingWebhookConfiguration open-feature-operator-validating-webhook-configuration | yq -o json -I0 '.webhooks[0]')"
  # The mutating webhook: the API server sends it only a pod that carries the label, so a pod that
  # did not ask is never held up by it; a selector with nothing in it would match every pod.
  [ "$(jq -cS '.objectSelector' <<<"$mutating")" = '{"matchLabels":{"openfeature.dev/enabled":"true"}}' ]
  [ "$(yq '.mutatingWebhook.objectSelector.matchLabels["openfeature.dev/enabled"] | tag' "$VALUES")" = '!!str' ]
  # It skips the control plane's, Flux's and its own namespace by the name every namespace carries,
  # and the selector holds that one requirement alone, so no label opts a namespace back in.
  [ "$(jq -cS '.namespaceSelector | .matchExpressions[0].values |= sort' <<<"$mutating")" \
    = '{"matchExpressions":[{"key":"kubernetes.io/metadata.name","operator":"NotIn","values":["flux-system","kube-system","open-feature-operator"]}]}' ]
  # Pods, on creation and update, and nothing else: no subresource, no other kind, no wildcard.
  [ "$(jq -cS '.rules' <<<"$mutating")" = '[{"apiGroups":[""],"apiVersions":["v1"],"operations":["CREATE","UPDATE"],"resources":["pods"]}]' ]
  # The validating webhook: FeatureFlags, on creation and update, and nothing else.
  [ "$(jq -cS '.rules' <<<"$validating")" = '[{"apiGroups":["core.openfeature.dev"],"apiVersions":["v1beta1"],"operations":["CREATE","UPDATE"],"resources":["featureflags"]}]' ]
  # Both fail open, the mutating webhook by the chart's value and the validating one by the
  # post-renderer, and both wait 10 seconds at most, written out rather than left to the API
  # server's default.
  [ "$(jq -r '.failurePolicy' <<<"$mutating")" = Ignore ]
  [ "$(yq '.mutatingWebhook.failurePolicy' "$VALUES")" = Ignore ]
  [ "$(jq -r '.failurePolicy' <<<"$validating")" = Ignore ]
  [ "$(jq -r '.timeoutSeconds' <<<"$mutating")" = 10 ]
  [ "$(jq -r '.timeoutSeconds' <<<"$validating")" = 10 ]
  # Neither is called again after another plugin changes the object, and neither narrows or widens
  # what it matches by a condition this test does not read.
  [ "$(jq -c '[.reinvocationPolicy // "Never", (.matchConditions // [] | length), .matchPolicy // "Equivalent"]' <<<"$mutating")" = '["Never",0,"Equivalent"]' ]
  [ "$(jq -c '[(.matchConditions // [] | length), .matchPolicy // "Equivalent", (.namespaceSelector // {} | length), (.objectSelector // {} | length)]' <<<"$validating")" = '[0,"Equivalent",0,0]' ]
  # Both call the operator's own Service in its namespace, by name and never by a URL, and that
  # Service selects the operator's pods and reaches the port the manager serves the webhooks on.
  [ "$(jq -cS '.clientConfig | del(.caBundle)' <<<"$mutating")" \
    = '{"service":{"name":"open-feature-operator-webhook-service","namespace":"open-feature-operator","path":"/mutate-v1-pod"}}' ]
  [ "$(jq -cS '.clientConfig | del(.caBundle)' <<<"$validating")" \
    = '{"service":{"name":"open-feature-operator-webhook-service","namespace":"open-feature-operator","path":"/validate-core-openfeature-dev-v1beta1-featureflag"}}' ]
  service="$(object "$RENDERED" Service open-feature-operator-webhook-service | yq -o json -I0 '.')"
  [ "$(jq -r '.metadata.namespace' <<<"$service")" = "$NAMESPACE" ]
  [ "$(jq -cS '.spec.selector' <<<"$service")" = "$(yq -o json -I0 '.spec.selector.matchLabels' "$DEPLOYMENT" | jq -cS .)" ]
  [ "$(jq -c '[.spec.ports[] | [.port, .targetPort]]' <<<"$service")" = "[[443,$(yq '.ports[] | select(.name == "webhook-server") | .containerPort' "$CONTAINER")]]" ]
  # Of the rights Kubernetes' documentation names as ways to escalate privilege ("Role Based Access
  # Control Good Practices"), no role of the release grants any but the creation of workloads: no
  # verb on the API group of the webhook configurations, by name or by a wildcard, so the
  # operator's own code cannot change what its webhooks match; nothing on Secrets, service account
  # tokens, persistent volumes, the nodes' proxy, namespaces or certificate approval; no wildcard,
  # bind, escalate or impersonate; and on roles and bindings only the read and update of the one
  # binding the operator adds flag readers to. Beside those, no exec or attach into a running pod
  # and no write to a node or its status. That bounds what the operator's code does, not what
  # its account reaches: it may create pods in every namespace, so it can act as any service
  # account there (docs/kubernetes.md, OpenFeature Operator). Every binding of the release is to a role the
  # release renders, so none reaches further than these.
  grants="$(yq -N -o json -I0 'select(.kind == "ClusterRole" or .kind == "Role")' "$RENDERED" | jq -r '
    (.kind + "/" + .metadata.name) as $role | (.rules // [])[]
    | select(((.apiGroups // []) | any(. == "admissionregistration.k8s.io" or . == "*"))
        or ((.resources // []) | any(IN("*", "secrets", "serviceaccounts/token", "persistentvolumes", "nodes/proxy", "namespaces",
          "certificatesigningrequests/approval", "signers", "pods/exec", "pods/attach")))
        or (((.resources // []) | any(IN("nodes", "nodes/status")))
          and ((.verbs // []) | any(IN("create", "update", "patch", "delete", "deletecollection"))))
        or ((.verbs // []) | any(IN("*", "bind", "escalate", "impersonate", "approve"))))
    | $role + " " + tojson')"
  echo "rules that grant a right that escalates: ${grants:-none}"
  [ -z "$grants" ]
  # A role with an aggregation rule is filled at run time with the rules of every role its selector
  # matches, admin's among them, so what the render lists of its rules is not what it grants.
  grants="$(yq -N 'select((.kind == "ClusterRole" or .kind == "Role") and .aggregationRule != null) | .kind + "/" + .metadata.name' "$RENDERED")"
  echo "roles that aggregate others: ${grants:-none}"
  [ -z "$grants" ]
  grants="$(yq -N -o json -I0 'select(.kind == "ClusterRole" or .kind == "Role")' "$RENDERED" | jq -r '
    (.kind + "/" + .metadata.name) as $role | (.rules // [])[] | select((.apiGroups // []) | index("rbac.authorization.k8s.io"))
    | [$role, (.resources | sort | join(",")), ((.resourceNames // []) | sort | join(",")), (.verbs | sort | join(","))] | join(" ")')"
  echo "rules on roles and bindings: $grants"
  [ "$grants" = "ClusterRole/open-feature-operator-manager-role clusterrolebindings open-feature-operator-flagd-kubernetes-sync get,update" ]
  roles="$(yq -N 'select(.kind == "ClusterRole" or .kind == "Role") | .kind + "/" + .metadata.name' "$RENDERED" | LC_ALL=C sort)"
  bindings="$(yq -N 'select(.kind == "ClusterRoleBinding" or .kind == "RoleBinding") | .roleRef.kind + "/" + .roleRef.name' "$RENDERED" | LC_ALL=C sort -u)"
  [ -n "$bindings" ]
  echo "bound roles the release does not render: $(comm -23 <(echo "$bindings") <(echo "$roles") | paste -sd' ' -)"
  [ -z "$(comm -23 <(echo "$bindings") <(echo "$roles"))" ]
}

@test "The images the operator injects are pinned by tag and digest in its values" {
  local prefix key repository tag image line switch rule
  # Each image the operator puts into other pods reaches it as two environment variables, and the
  # key of the values that sets them.
  local -A values_key=([SIDECAR]=sidecarConfiguration [FLAGD]=flagdConfiguration [FLAGD_PROXY]=flagdProxyConfiguration)
  render
  deployment
  for prefix in SIDECAR FLAGD FLAGD_PROXY; do
    key="${values_key[$prefix]}"
    repository="$(env_value "${prefix}_IMAGE")"
    tag="$(env_value "${prefix}_TAG")"
    echo "$prefix: $repository:$tag, where the pinned chart defaults to $(KEY="$key" yq '.[strenv(KEY)].image.tag' "$DEFAULTS")"
    # A release of the plain build and a digest: the operator joins repository and tag with a
    # colon, so this is the reference it injects. No tag without a digest, no variant, and never
    # latest.
    [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]
    # At the version the pinned chart defaults to: the operator builds what it injects for that
    # flagd, so a chart whose default moves fails here until the pin moves with it, and a pin that
    # moves alone fails too.
    [ "${tag%@*}" = "$(KEY="$key" yq '.[strenv(KEY)].image.tag' "$DEFAULTS")" ]
    # The tag is the one the values file holds, under the comment Renovate reads it by, which names
    # the repository the chart defaults to and the variable carries.
    [ "$tag" = "$(KEY="$key" yq '.[strenv(KEY)].image.tag' "$VALUES")" ]
    [ "$repository" = "$(KEY="$key" yq '.[strenv(KEY)].image.repository' "$DEFAULTS")" ]
    [ "$(tag_comment "$key")" = "# renovate: datasource=docker depName=$repository" ]
  done
  # The sidecar and the flagd of a Flagd object are one image at one version.
  [ "$(env_value SIDECAR_IMAGE):$(env_value SIDECAR_TAG)" = "$(env_value FLAGD_IMAGE):$(env_value FLAGD_TAG)" ]
  # A pod pinned by digest needs no question to the registry at each start: the sidecar and flagd
  # are pulled only when the node lacks them, and flagd-proxy never always.
  [ "$(env_value SIDECAR_IMAGE_PULL_POLICY)" = IfNotPresent ]
  [ "$(env_value FLAGD_IMAGE_PULL_POLICY)" = IfNotPresent ]
  [ "$(env_value FLAGD_PROXY_IMAGE_PULL_POLICY)" != Always ]
  # The operator's own image, pinned the same way, at the version the chart's own values default
  # to: the chart's appVersion is not the image the chart runs.
  image="$(yq '.image' "$CONTAINER")"
  echo "$image, where the chart's values default to $(yq '.controllerManager.manager.image.tag' "$DEFAULTS") and its appVersion is $(helm show chart "$CHART" | yq '.appVersion')"
  [[ $image =~ ^ghcr\.io/open-feature/open-feature-operator:(v[0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$ ]]
  [ "${BASH_REMATCH[1]}" = "$(yq '.controllerManager.manager.image.tag' "$DEFAULTS")" ]
  [ "$(yq '.controllerManager.manager.image.repository' "$DEFAULTS")" = ghcr.io/open-feature/open-feature-operator ]
  [ "$(tag_comment controllerManager)" = "# renovate: datasource=docker depName=ghcr.io/open-feature/open-feature-operator" ]
  [ "$(yq '.controllerManager.manager.image.pullPolicy' "$DEFAULTS")" = IfNotPresent ]
  [ "$(yq '.imagePullPolicy' "$CONTAINER")" = IfNotPresent ]
  # The chart's tag is a pin Renovate reads too, and it moves the chart and the operator's image in
  # one pull request, as the versions above are held together.
  [ "$(grep -B1 -E '^    tag: ' "$APP/app/ocirepository.yaml" | head -1)" = "    # renovate: datasource=docker depName=ghcr.io/open-feature/charts/open-feature-operator" ]
  line="$(grep -n -F '"ghcr.io/open-feature/charts/open-feature-operator", "ghcr.io/open-feature/open-feature-operator"' "$REPO/.renovate/groups.json5" | cut -d: -f1)"
  [ -n "$line" ]
  sed -n "$((line + 1))p" "$REPO/.renovate/groups.json5" | grep -q 'groupName: "OpenFeature Operator"'
  # Nothing of the application merges itself: a rule for every file of it, after the auto-merge
  # switch, so that it wins over the switch.
  switch="$(grep -n -F 'description: "The auto-merge switch' "$REPO/.renovate/automerge.json5" | cut -d: -f1)"
  rule="$(grep -n -F 'matchFileNames: ["kubernetes/apps/base/open-feature-operator/**"]' "$REPO/.renovate/automerge.json5" | cut -d: -f1)"
  [ -n "$switch" ] && [ -n "$rule" ] && [ "$rule" -gt "$switch" ]
  sed -n "$((rule + 1))p" "$REPO/.renovate/automerge.json5" | grep -q 'automerge: false'
}

@test "The operator's certificates come from the cluster's own CA" {
  local certificates name inject serving secret mount
  render
  deployment
  # Two Certificates, the webhook's serving certificate and the metrics certificate, each signed by
  # the cluster's own authority: the ClusterIssuer the cluster-ca application applies.
  certificates="$(yq -N 'select(.kind == "Certificate") | .metadata.name' "$RENDERED" | LC_ALL=C sort | paste -sd' ' -)"
  [ "$certificates" = "open-feature-operator-metrics-certs open-feature-operator-serving-cert" ]
  for name in $certificates; do
    echo "$name: $(object "$RENDERED" Certificate "$name" | yq -o json -I0 '.spec.issuerRef')"
    [ "$(object "$RENDERED" Certificate "$name" | yq -o json -I0 '.spec.issuerRef' | jq -cS .)" = '{"group":"cert-manager.io","kind":"ClusterIssuer","name":"cluster-ca"}' ]
  done
  [ "$(yq '.kind + "/" + .metadata.name + " " + (.spec | keys | join(","))' "$REPO/kubernetes/apps/base/cert-manager/cluster-ca/app/clusterissuer.yaml")" = "ClusterIssuer/cluster-ca ca" ]
  # The chart's self-signed Issuer is gone, the release and the application make no issuer of their
  # own and hold no Secret, and no object anywhere in either names another issuer, an ACME one
  # among them.
  [ -z "$(yq -N 'select(.kind == "Issuer" or .kind == "ClusterIssuer" or .kind == "Secret") | .kind + "/" + .metadata.name' "$RENDERED" "$BUILT")" ]
  [ "$(yq -N -o json -I0 'select(. != null)' "$RENDERED" "$BUILT" | jq -r '.. | objects | .issuerRef? | objects | .kind + "/" + .name' | LC_ALL=C sort -u)" = ClusterIssuer/cluster-ca ]
  [ "$(grep -ciE 'letsencrypt|acme' "$RENDERED" "$BUILT" "$APP/ks.yaml" | paste -sd' ' -)" = "$RENDERED:0 $BUILT:0 $APP/ks.yaml:0" ]
  # Both webhook configurations ask the CA injector for the authority that signed the serving
  # certificate, which is a Certificate of the release in the operator's namespace.
  inject="$(yq -N 'select(.apiVersion == "admissionregistration.k8s.io/*") | .metadata.annotations["cert-manager.io/inject-ca-from"]' "$RENDERED" | paste -sd' ' -)"
  [ "$inject" = "open-feature-operator/open-feature-operator-serving-cert open-feature-operator/open-feature-operator-serving-cert" ]
  serving="$(object "$RENDERED" Certificate open-feature-operator-serving-cert | yq -o json -I0 '.')"
  [ "$(jq -r '.metadata.namespace' <<<"$serving")" = "$NAMESPACE" ]
  # It is issued for the name the API server calls the webhook's Service by.
  jq -e '.spec.dnsNames | index("open-feature-operator-webhook-service.open-feature-operator.svc") != null' <<<"$serving" >/dev/null
  # The pod mounts its Secret where the webhook server reads its certificate, and the metrics
  # certificate's Secret beside it: the pod does not start until cert-manager has made both.
  secret="$(jq -r '.spec.secretName' <<<"$serving")"
  mount="$(yq -o json '.spec.template.spec' "$DEPLOYMENT" | jq -r --arg secret "$secret" '
    (.volumes[] | select(.secret.secretName == $secret) | .name) as $volume
    | .containers[0].volumeMounts[] | select(.name == $volume) | .mountPath')"
  [ "$mount" = /tmp/k8s-webhook-server/serving-certs ]
  [ "$(yq '[.spec.template.spec.volumes[] | .secret.secretName] | sort | join(" ")' "$DEPLOYMENT")" \
    = "$(yq -N 'select(.kind == "Certificate") | .spec.secretName' "$RENDERED" | LC_ALL=C sort | paste -sd' ' -)" ]
  [ "$(yq '[.spec.template.spec.volumes[] | select(.secret.optional == true)] | length' "$DEPLOYMENT")" -eq 0 ]
}

@test "The operator's pod meets the restricted level with a read-only root and only its certificate mounts" {
  local ns mounts orphans key
  render
  deployment
  overlay
  # The namespace, as the overlay builds it, enforces restricted, and no workload of it is excepted.
  ns="$(object "$OVERLAY" Namespace "$NAMESPACE")"
  [ "$(yq '.metadata.labels["pod-security.kubernetes.io/enforce"]' <<<"$ns")" = restricted ]
  [ "$(yq '.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"]' <<<"$ns")" = disabled ]
  [ "$(NS="$NAMESPACE" yq '[.exceptions[] | select(.namespace == strenv(NS))] | length' "$REPO/pod-security-exceptions.yaml")" -eq 0 ]
  # The pod passes the restricted level, by the evaluator pod-security-check runs.
  restricted_failures "$DEPLOYMENT" "$NAMESPACE"
  echo "failed controls: $(paste -sd' ' "$CONTROLS") $(cat "$FORBIDDEN")"
  [ ! -s "$CONTROLS" ]
  # What the chart sets and what the post-renderer adds to it: a non-root user and the runtime's
  # seccomp profile for the pod, and for its one container no privilege escalation, no capability
  # and a root filesystem it cannot write.
  [ "$(yq -o json -I0 '.spec.template.spec.securityContext' "$DEPLOYMENT" | jq -cS .)" = '{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}}' ]
  [ "$(yq -o json -I0 '.securityContext' "$CONTAINER" | jq -cS .)" \
    = '{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsNonRoot":true}' ]
  [ "$(yq '.spec.template.spec.containers | map(.name) | join(" ")' "$DEPLOYMENT")" = manager ]
  [ "$(yq '.spec.template.spec.initContainers // [] | length' "$DEPLOYMENT")" -eq 0 ]
  [ "$(yq '.spec.template.spec | (.hostNetwork // false) or (.hostPID // false) or (.hostIPC // false)' "$DEPLOYMENT")" = false ]
  # The mounts, as a set: the two certificate Secrets, each read-only. Nothing the container can
  # write to is mounted, and the pod has no volume that is not one of the two.
  mounts="$(yq -o json '.spec.template.spec' "$DEPLOYMENT" | jq -r '. as $pod | (.containers + (.initContainers // []))[] | (.volumeMounts // [])[] | . as $m
    | ([$pod.volumes[] | select(.name == $m.name)][0] // {}) as $v
    | [$m.mountPath, ($v | del(.name) | keys | join("+")), ($v.secret.secretName // "-"), (if $m.readOnly == true then "read-only" else "writable" end)] | join(" ")' | LC_ALL=C sort)"
  echo "$mounts"
  [ "$mounts" = "$(printf '%s\n' '/tmp/k8s-metrics-server/metrics-certs secret metrics-server-cert read-only' \
    '/tmp/k8s-webhook-server/serving-certs secret webhook-server-cert read-only')" ]
  [ "$(yq '[.spec.template.spec.volumes[] | .name + "=" + (del(.name) | keys | join("+"))] | sort | join(" ")' "$DEPLOYMENT")" = "metrics-certs=secret webhook-certs=secret" ]
  orphans="$(yq -o json '.spec.template.spec' "$DEPLOYMENT" | jq -r '[.volumes // [] | .[].name] as $volumes
    | (.containers + (.initContainers // []))[] | .name as $c | (.volumeMounts // [])[]
    | select(.name as $n | $volumes | index($n) | not) | "\($c): \(.mountPath) names no volume \(.name)"')"
  [ -z "$orphans" ] || { echo "$orphans"; return 1; }
  # One replica, an integer: the chart writes the value after a literal 0, and what the release's
  # post-renderer hands on is the number 1.
  [ "$(yq '.controllerManager.replicas' "$VALUES")" = 1 ]
  [ "$(yq '.spec.replicas | tag' "$DEPLOYMENT")" = '!!int' ]
  [ "$(yq '.spec.replicas' "$DEPLOYMENT")" = 1 ]
  # Requests and limits are the chart's own, written out in the values, and they reach the pod.
  for key in requests.cpu requests.memory limits.cpu limits.memory; do
    echo "$key: $(yq ".controllerManager.manager.resources.$key" "$VALUES")"
    [ "$(yq ".controllerManager.manager.resources.$key" "$VALUES")" != null ]
    [ "$(yq ".controllerManager.manager.resources.$key" "$VALUES")" = "$(yq ".controllerManager.manager.resources.$key" "$DEFAULTS")" ]
    [ "$(yq ".resources.$key" "$CONTAINER")" = "$(yq ".controllerManager.manager.resources.$key" "$VALUES")" ]
  done
  # No pull secret, as the images are public: the chart's empty list reaches the pod as one.
  [ "$(yq '.spec.template.spec.imagePullSecrets | tag' "$DEPLOYMENT")" = '!!seq' ]
  [ "$(yq '.spec.template.spec.imagePullSecrets | length' "$DEPLOYMENT")" -eq 0 ]
  # The docs say that the requests and limits are not measured here.
  tr -s "\n " "  " <"$REPO/docs/kubernetes.md" | grep -qF "are the chart's own and are not measured here"
}

@test "The operator's namespace denies traffic by default and its policies name only the webhook's callers, the kubelet, Prometheus and the API server" {
  local deny selector health metrics webhook view policy args monitor target
  local prometheus='monitoring:app.kubernetes.io/name=prometheus' other='other:app.kubernetes.io/name=app'
  local store='openbao:app.kubernetes.io/name=openbao' dns='kube-system:k8s-app=kube-dns' hello='demo:app.kubernetes.io/name=hello'
  render
  deployment
  overlay
  # The namespace holds the default deny, every pod and both directions with no rule, and is not
  # listed among the namespaces without one.
  deny="$(yq -N -o json -I0 'select(.kind == "NetworkPolicy" and .metadata.namespace == "open-feature-operator")' "$OVERLAY")"
  [ "$(jq -cS '[.metadata.name, .spec]' <<<"$deny")" = '["default-deny",{"podSelector":{},"policyTypes":["Ingress","Egress"]}]' ]
  [ "$(NS="$NAMESPACE" yq '[.exceptions[] | select(.namespace == strenv(NS))] | length' "$REPO/network-policy-exceptions.yaml")" -eq 0 ]
  # The application's policies are two, both of the operator's pods by the labels of the
  # Deployment's selector, and both leave the deny to the namespace.
  [ "$(yq -N 'select(.kind == "CiliumNetworkPolicy" or .kind == "NetworkPolicy" or .kind == "CiliumClusterwideNetworkPolicy") | .kind + "/" + .metadata.name' "$BUILT" "$RENDERED" | LC_ALL=C sort | paste -sd' ' -)" \
    = "CiliumNetworkPolicy/open-feature-operator CiliumNetworkPolicy/open-feature-operator-webhook" ]
  selector="$(yq -o json -I0 '.spec.selector.matchLabels' "$DEPLOYMENT" | jq -cS .)"
  [ "$selector" = '{"app.kubernetes.io/name":"open-feature-operator","control-plane":"controller-manager"}' ]
  for policy in open-feature-operator open-feature-operator-webhook; do
    [ "$(object "$BUILT" CiliumNetworkPolicy "$policy" | yq -o json -I0 '.spec.endpointSelector' | jq -cS .)" = "{\"matchLabels\":$selector}" ]
    [ "$(object "$BUILT" CiliumNetworkPolicy "$policy" | yq -o json -I0 '.spec.enableDefaultDeny' | jq -cS .)" = '{"egress":false,"ingress":false}' ]
    [ "$(object "$BUILT" CiliumNetworkPolicy "$policy" | yq '.metadata.namespace')" = "$NAMESPACE" ]
  done
  # The ports, read from the rendered pod: the one its probes ask, the one named for metrics and
  # the one named for the webhooks.
  health="$(yq '[.livenessProbe.httpGet.port, .readinessProbe.httpGet.port] | unique | join(" ")' "$CONTAINER")"
  metrics="$(yq '.ports[] | select(.name == "metrics-server") | .containerPort' "$CONTAINER")"
  webhook="$(yq '.ports[] | select(.name == "webhook-server") | .containerPort' "$CONTAINER")"
  echo "health $health, metrics $metrics, webhook $webhook"
  [[ $health =~ ^[0-9]+$ && $metrics =~ ^[0-9]+$ && $webhook =~ ^[0-9]+$ ]]
  [ "$(yq '[.livenessProbe, .readinessProbe, .startupProbe] | map(select(. != null)) | length' "$CONTAINER")" -eq 2 ]
  # What the first policy names, rule by rule: the kubelet's probes, Prometheus' scrape and the API
  # server, and nothing else, so no resolver and nothing outside the cluster.
  [ "$(rule_peers "$BUILT" open-feature-operator ingress | LC_ALL=C sort)" = "$(printf '%s\n' \
    "@host -> $health/TCP" \
    "app.kubernetes.io/name=prometheus,k8s:io.kubernetes.pod.namespace=monitoring -> $metrics/TCP" | LC_ALL=C sort)" ]
  [ "$(rule_peers "$BUILT" open-feature-operator egress)" = "@kube-apiserver -> 443/TCP 6443/TCP" ]
  # The second is the webhook's alone, with its reason: the API server's calls, which arrive as the
  # API server, as the local host or as another node's host, on the webhook's port.
  [ "$(rule_peers "$BUILT" open-feature-operator-webhook ingress)" = "@host @kube-apiserver @remote-node -> $webhook/TCP" ]
  [ -z "$(rule_peers "$BUILT" open-feature-operator-webhook egress)" ]
  [ -n "$(object "$BUILT" CiliumNetworkPolicy open-feature-operator-webhook | yq '.metadata.annotations["k8s-gitops/network-policy-reason"] // ""')" ]
  [ "$(object "$BUILT" CiliumNetworkPolicy open-feature-operator | yq '.metadata.annotations["k8s-gitops/network-policy-reason"] // ""')" = "" ]
  # The flows, evaluated on the namespace's default deny, the policies and the rendered pod.
  view="$BATS_TEST_TMPDIR/flows"
  flows "$view" "$OVERLAY" "$BUILT" "$RENDERED"
  allowed "$view" @host "$OPERATOR" "$health/tcp"
  allowed "$view" "$prometheus" "$OPERATOR" "$metrics/tcp"
  allowed "$view" @kube-apiserver "$OPERATOR" "$webhook/tcp"
  allowed "$view" @host "$OPERATOR" "$webhook/tcp"
  allowed "$view" @remote-node "$OPERATOR" "$webhook/tcp"
  allowed "$view" "$OPERATOR" @kube-apiserver 443/tcp
  allowed "$view" "$OPERATOR" @kube-apiserver 6443/tcp
  # The webhook's port takes nothing but the API server's calls, the metrics port nothing but
  # Prometheus, and no other port takes anything.
  denied "$view" @world "$OPERATOR" "$webhook/tcp"
  denied "$view" "$other" "$OPERATOR" "$webhook/tcp"
  denied "$view" "$prometheus" "$OPERATOR" "$webhook/tcp"
  denied "$view" "$hello" "$OPERATOR" "$webhook/tcp"
  denied "$view" @kube-apiserver "$OPERATOR" "$metrics/tcp"
  denied "$view" @remote-node "$OPERATOR" "$metrics/tcp"
  denied "$view" @world "$OPERATOR" "$metrics/tcp"
  denied "$view" "$other" "$OPERATOR" "$metrics/tcp"
  denied "$view" @remote-node "$OPERATOR" "$health/tcp"
  denied "$view" "$prometheus" "$OPERATOR" "$health/tcp"
  denied "$view" @world "$OPERATOR" 22/tcp
  # The operator reaches the API server and nothing else: it looks no name up, and calls nothing
  # outside the cluster, the secret store or another application.
  denied "$view" "$OPERATOR" "$dns" 53/udp
  denied "$view" "$OPERATOR" "$dns" 53/tcp
  denied "$view" "$OPERATOR" @world 443/tcp
  denied "$view" "$OPERATOR" @world 80/tcp
  denied "$view" "$OPERATOR" "$store" 8200/tcp
  denied "$view" "$OPERATOR" "$other" 8080/tcp
  denied "$view" "$OPERATOR" "$prometheus" 9090/tcp
  denied "$view" "$OPERATOR" @host 10250/tcp
  denied "$view" "$OPERATOR" @remote-node 10250/tcp
  # Without the namespace's default deny the same policies deny nothing.
  yq 'select((.kind == "NetworkPolicy" and .metadata.namespace == "open-feature-operator") | not)' "$OVERLAY" >"$view/$(basename "$OVERLAY")"
  [ "$(yq -N 'select(.kind == "NetworkPolicy") | .metadata.namespace' "$view/$(basename "$OVERLAY")" | grep -c .)" \
    -eq "$(($(yq -N 'select(.kind == "NetworkPolicy") | .metadata.namespace' "$OVERLAY" | grep -c .) - 1))" ]
  allowed "$view" @world "$OPERATOR" "$webhook/tcp"
  allowed "$view" "$OPERATOR" @world 443/tcp
  # Prometheus scrapes that metrics port through the application's PodMonitor, which selects the
  # operator's pod and names the port by the name the container gives it.
  monitor="$(yq -N -o json -I0 'select(.kind == "PodMonitor")' "$BUILT")"
  [ "$(jq -r '.metadata.name' <<<"$monitor")" = open-feature-operator ]
  [ "$(jq -cS '.spec.selector' <<<"$monitor")" = "{\"matchLabels\":$selector}" ]
  [ "$(jq -cS '.spec.podMetricsEndpoints' <<<"$monitor")" = '[{"port":"metrics-server"}]' ]
  [ "$(yq -o json -I0 '.spec.template.metadata.labels' "$DEPLOYMENT" | jq -c --argjson selector "$selector" '. as $labels | $selector | to_entries | all($labels[.key] == .value)')" = true ]
  [ -z "$(yq -N 'select(.kind == "ServiceMonitor" or .kind == "PodMonitor") | .metadata.name' "$RENDERED")" ]
  # The manager serves its metrics in plain HTTP with no authentication on that port: it is given
  # the bind address alone, none of the flags that name a certificate or turn the secure server
  # off or on, and the chart's metrics Service names a port no container has, so it reaches no pod.
  # A chart that starts to serve them over HTTPS changes one of these, and the monitor with it.
  args="$(yq '.args[]' "$CONTAINER")"
  grep -qx -- "--metrics-bind-address=:$metrics" <<<"$args"
  [ -z "$(grep -E -- '^--metrics-(secure|cert-path|cert-name|cert-key)' <<<"$args" || true)" ]
  target="$(object "$RENDERED" Service open-feature-operator-controller-manager-metrics-service | yq '.spec.ports | map(.targetPort | tostring) | join(" ")')"
  [ "$target" = https ]
  [ "$(TARGET="$target" yq '[.ports[] | select(.name == strenv(TARGET))] | length' "$CONTAINER")" -eq 0 ]
  [ "$(yq '[.volumeMounts[] | select(.mountPath == "/tmp/k8s-metrics-server/metrics-certs")] | length' "$CONTAINER")" -eq 1 ]
}

@test "The operator's definitions stay when its release leaves, and what is written at run time is not undone as drift" {
  local definitions binding release
  render
  # The four definitions of the operator's API group, each kept when Helm uninstalls the release.
  definitions="$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name + " " + (.metadata.annotations["helm.sh/resource-policy"] // "none")' "$RENDERED" | LC_ALL=C sort)"
  echo "$definitions"
  [ "$definitions" = "$(printf '%s\n' 'featureflags.core.openfeature.dev keep' 'featureflagsources.core.openfeature.dev keep' \
    'flagds.core.openfeature.dev keep' 'inprocessconfigurations.core.openfeature.dev keep')" ]
  [ "$(yq -N 'select(.kind == "CustomResourceDefinition") | .spec.group' "$RENDERED" | LC_ALL=C sort -u)" = core.openfeature.dev ]
  # They are templates of the release, which leave with it unless kept, not files of the chart's
  # crds directory, which Helm installs once and never removes.
  [ -z "$(helm show crds "$CHART")" ]
  # The render holds them, so the validation has a schema for each of the group's kinds and neither
  # list names the group.
  [ "$(yq '[.exceptions[] | select(.group == "core.openfeature.dev")] | length' "$REPO/schema-exceptions.yaml")" -eq 0 ]
  [ "$(yq '[.definitions[] | select(.group == "core.openfeature.dev")] | length' "$REPO/operator-definitions.yaml")" -eq 0 ]
  # Drift detection, which the root turns on for every release, undoes what differs from the
  # release's own objects. The operator adds the service account of each pod it injects to the
  # subjects of one ClusterRoleBinding, which the release renders with its own two and the
  # operator's role lets it update by name: the HelmRelease, as the root builds it, ignores them.
  release="$(yq -N -o json -I0 'select(.kind == "HelmRelease")' "$BUILT")"
  [ "$(jq -r '.spec.driftDetection.mode' <<<"$release")" = enabled ]
  [ "$(jq -cS '.spec.driftDetection.ignore' <<<"$release")" \
    = '[{"paths":["/subjects"],"target":{"kind":"ClusterRoleBinding","name":"open-feature-operator-flagd-kubernetes-sync"}}]' ]
  binding="$(object "$RENDERED" ClusterRoleBinding open-feature-operator-flagd-kubernetes-sync | yq -o json -I0 '.')"
  [ "$(jq -r '[.subjects[] | .kind + "/" + .namespace + "/" + .name] | sort | join(" ")' <<<"$binding")" \
    = "ServiceAccount/open-feature-operator/open-feature-operator-controller-manager ServiceAccount/open-feature-operator/open-feature-operator-flagd-proxy" ]
  [ "$(yq -N -o json -I0 'select(.kind == "ClusterRole" and .metadata.name == "open-feature-operator-manager-role")' "$RENDERED" | jq -c '
    [.rules[] | select((.resources // []) | index("clusterrolebindings")) | [.apiGroups, .resourceNames, (.verbs | sort)]]')" \
    = '[[["rbac.authorization.k8s.io"],["open-feature-operator-flagd-kubernetes-sync"],["get","update"]]]' ]
  # The CA injector writes each webhook's CA bundle, a field the release's objects do not hold, so
  # it is none of the release's to compare and needs no entry. A chart that renders the field does.
  [ "$(yq -N -o json -I0 'select(.apiVersion == "admissionregistration.k8s.io/*")' "$RENDERED" | jq -c '.webhooks[].clientConfig | has("caBundle")' | LC_ALL=C sort -u)" = false ]
}

@test "No workload opts in, and the worked example builds without being applied" {
  local name ks others example example_ks workload served used flag source account port management command view
  render
  deployment
  overlay
  # Every application the overlay selects but the operator's own, each built as Flux applies it
  # from the overlay's Kustomization, with the overlay's own objects.
  others="$BATS_TEST_TMPDIR/others.yaml"
  cp "$OVERLAY" "$others"
  for name in $(yq -N 'select(.kind == "Kustomization") | .metadata.name' "$OVERLAY"); do
    [ "$name" != open-feature-operator ] || continue
    ks="$BATS_TEST_TMPDIR/other-ks.yaml"
    with_vars "$name" "$OVERLAY" >"$ks"
    echo --- >>"$others"
    flux_build "$name" "$ks" >>"$others"
  done
  # None of them names the operator's labels, annotations or API group anywhere, the values a chart
  # takes from a ConfigMap included: no flag source is shipped and no pod asks for a sidecar.
  echo "lines of the other applications that name openfeature.dev: $(grep -c 'openfeature\.dev' "$others" || true)"
  [ "$(grep -c 'openfeature\.dev' "$others" || true)" -eq 0 ]
  # The operator's own application and what its chart renders hold no object of the API group, and
  # no label or annotation of the operator's on any object or pod template.
  [ -z "$(yq -N 'select(.apiVersion == "core.openfeature.dev/*") | .kind + "/" + .metadata.name' "$BUILT" "$RENDERED")" ]
  [ -z "$(yq -N -o json -I0 'select(. != null)' "$BUILT" "$RENDERED" | jq -r '.. | objects | (.labels?, .annotations?) | objects | keys[] | select(startswith("openfeature.dev/"))')" ]
  # The worked example is listed in the overlay commented out with its reason, and nothing the
  # overlay builds is of it.
  [ "$(grep -cE '^  # - \.\./\.\./base/demo/hello-flags/ks\.yaml  # Disabled: .+' "$OVERLAY_DIR/kustomization.yaml")" -eq 1 ]
  [ -z "$(yq '.resources[] | select(test("hello-flags"))' "$OVERLAY_DIR/kustomization.yaml")" ]
  [ -z "$(yq -N 'select(.metadata.name == "hello-flags") | .kind' "$others")" ]
  [ ! -e "$REPO/kubernetes/apps/base/backstage/backstage/app/catalogue/hello-flags.yaml" ]
  # Nor does any file of the catalogue hold an entity of its name.
  [ -z "$(yq -N 'select(.metadata.name == "hello-flags") | filename + ": " + .kind' "$REPO"/kubernetes/apps/base/backstage/backstage/app/catalogue/*.yaml)" ]
  # It builds as Flux would apply it, from its own ks.yaml, which waits for the operator, whose
  # release defines its kinds and serves the webhook, and for the definition of its policy's kind.
  [ "$(yq '[.metadata.name, .spec.targetNamespace, .spec.path, (.spec.dependsOn | map(.name) | join(" "))] | join(" ")' "$EXAMPLE_APP/ks.yaml")" \
    = "hello-flags demo ./apps/base/demo/hello-flags/app open-feature-operator cilium" ]
  example_ks="$BATS_TEST_TMPDIR/example-ks.yaml"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "$VARS" "$EXAMPLE_APP/ks.yaml" >"$example_ks"
  example="$BATS_TEST_TMPDIR/example.yaml"
  flux_build hello-flags "$example_ks" >"$example"
  [ "$(yq -N 'select(. != null) | .kind + "/" + .metadata.namespace + "/" + .metadata.name' "$example" | LC_ALL=C sort | paste -sd' ' -)" \
    = "CiliumNetworkPolicy/demo/hello-flags Deployment/demo/hello-flags FeatureFlag/demo/hello-flags FeatureFlagSource/demo/hello-flags ServiceAccount/demo/hello-flags" ]
  # Its kinds and versions are ones the pinned chart's definitions serve.
  served="$(yq -N -o json -I0 'select(.kind == "CustomResourceDefinition")' "$RENDERED" | jq -r '.spec as $spec | $spec.versions[] | select(.served) | $spec.group + "/" + .name + " " + $spec.names.kind' | LC_ALL=C sort)"
  used="$(yq -N 'select(.apiVersion == "core.openfeature.dev/*") | .apiVersion + " " + .kind' "$example" | LC_ALL=C sort)"
  [ "$used" = "$(printf '%s\n' 'core.openfeature.dev/v1beta1 FeatureFlag' 'core.openfeature.dev/v1beta1 FeatureFlagSource')" ]
  [ -z "$(comm -23 <(echo "$used") <(echo "$served"))" ]
  # One flag set with one flag, and one source whose one source is that flag set, read from the
  # API server by the kubernetes provider, in the pod's own namespace.
  [ "$(object "$example" FeatureFlag hello-flags | yq '.spec.flagSpec.flags | keys | length')" -eq 1 ]
  flag="$(object "$example" FeatureFlag hello-flags | yq '.spec.flagSpec.flags | keys | .[0]')"
  # shellcheck disable=SC2016 # $default is a jq variable.
  [ "$(object "$example" FeatureFlag hello-flags | yq -o json -I0 '.' | jq -c '.spec.flagSpec.flags[] | [.state, (.defaultVariant as $default | .variants | has($default))]')" = '["ENABLED",true]' ]
  [ "$(object "$example" FeatureFlagSource hello-flags | yq -o json -I0 '.spec.sources' | jq -cS .)" = '[{"provider":"kubernetes","source":"hello-flags"}]' ]
  # The pod asks: the label lets the API server send it to the webhook, the first annotation makes
  # the operator act on it, and the second names the source, which the build holds.
  workload="$BATS_TEST_TMPDIR/example-deployment.yaml"
  object "$example" Deployment hello-flags >"$workload"
  [ "$(yq '.spec.template.metadata.labels["openfeature.dev/enabled"]' "$workload")" = "true" ]
  [ "$(yq '.spec.template.metadata.labels["openfeature.dev/enabled"] | tag' "$workload")" = '!!str' ]
  [ "$(yq -o json -I0 '.spec.template.metadata.annotations' "$workload" | jq -cS .)" = '{"openfeature.dev/enabled":"true","openfeature.dev/featureflagsource":"hello-flags"}' ]
  source="$(yq '.spec.template.metadata.annotations["openfeature.dev/featureflagsource"]' "$workload")"
  [ -n "$(object "$example" FeatureFlagSource "$source")" ]
  # That source's one source names, in the pod's own namespace, the flag set the build holds.
  [ -n "$(object "$example" FeatureFlag "$(object "$example" FeatureFlagSource "$source" | yq '.spec.sources[0].source')")" ]
  # A service account of its own, which the operator binds to the read of every flag set: not the
  # namespace's default one, which every other pod of the namespace would share.
  account="$(yq '.spec.template.spec.serviceAccountName' "$workload")"
  [ "$account" = hello-flags ]
  [ -n "$(object "$example" ServiceAccount "$account")" ]
  # The sidecar reads the API server with that account's token, which the pod therefore mounts.
  [ "$(yq '.spec.template.spec.automountServiceAccountToken' "$workload")" != false ]
  [ "$(object "$example" ServiceAccount "$account" | yq '.automountServiceAccountToken')" != false ]
  # Before injection the pod template passes the restricted level its namespace enforces.
  [ "$(object "$OVERLAY" Namespace demo | yq '.metadata.labels["pod-security.kubernetes.io/enforce"]')" = restricted ]
  restricted_failures "$workload" demo
  echo "failed controls: $(paste -sd' ' "$CONTROLS") $(cat "$FORBIDDEN")"
  [ ! -s "$CONTROLS" ]
  [ "$(yq '.spec.template.spec.containers | length' "$workload")" -eq 1 ]
  [ "$(yq '.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem' "$workload")" = true ]
  # Its container asks the sidecar for the flag over the pod's loopback, on the port the source's
  # definition defaults the OFREP endpoint to, as the source sets none.
  port="$(object "$RENDERED" CustomResourceDefinition featureflagsources.core.openfeature.dev |
    yq '.spec.versions[] | select(.name == "v1beta1") | .schema.openAPIV3Schema.properties.spec.properties.ofrepPort.default')"
  [[ $port =~ ^[0-9]+$ ]]
  [ "$(object "$example" FeatureFlagSource hello-flags | yq '.spec | has("ofrepPort")')" = false ]
  command="$(yq '.spec.template.spec.containers[0].command | join(" ")' "$workload")"
  echo "$command"
  [[ $command == *"http://127.0.0.1:$port/ofrep/v1/evaluate/flags/$flag"* ]]
  # Under the namespace's default deny an opted-in pod needs two flows, which its policy declares
  # and no others: the kubelet's probes of the sidecar on its management port, the definition's
  # default, which is also what the operator is given, and the sidecar to the API server.
  management="$(object "$RENDERED" CustomResourceDefinition featureflagsources.core.openfeature.dev |
    yq '.spec.versions[] | select(.name == "v1beta1") | .schema.openAPIV3Schema.properties.spec.properties.managementPort.default')"
  [[ $management =~ ^[0-9]+$ ]]
  [ "$(env_value SIDECAR_MANAGEMENT_PORT)" = "$management" ]
  [ "$(object "$example" FeatureFlagSource hello-flags | yq '.spec | has("managementPort")')" = false ]
  [ "$(object "$example" CiliumNetworkPolicy hello-flags | yq -o json -I0 '.spec.endpointSelector' | jq -cS .)" \
    = "{\"matchLabels\":$(yq -o json -I0 '.spec.selector.matchLabels' "$workload" | jq -cS .)}" ]
  [ "$(object "$example" CiliumNetworkPolicy hello-flags | yq -o json -I0 '.spec.enableDefaultDeny' | jq -cS .)" = '{"egress":false,"ingress":false}' ]
  [ "$(rule_peers "$example" hello-flags ingress)" = "@host -> $management/TCP" ]
  [ "$(rule_peers "$example" hello-flags egress)" = "@kube-apiserver -> 443/TCP 6443/TCP" ]
  view="$BATS_TEST_TMPDIR/example-flows"
  flows "$view" "$OVERLAY" "$example"
  allowed "$view" @host demo/Deployment/hello-flags "$management/tcp"
  allowed "$view" demo/Deployment/hello-flags @kube-apiserver 443/tcp
  allowed "$view" demo/Deployment/hello-flags @kube-apiserver 6443/tcp
  denied "$view" @host demo/Deployment/hello-flags "$port/tcp"
  denied "$view" demo:app.kubernetes.io/name=hello demo/Deployment/hello-flags "$port/tcp"
  denied "$view" @world demo/Deployment/hello-flags "$port/tcp"
  denied "$view" demo/Deployment/hello-flags @world 443/tcp
  denied "$view" demo/Deployment/hello-flags kube-system:k8s-app=kube-dns 53/udp
  denied "$view" demo/Deployment/hello-flags demo:app.kubernetes.io/name=hello 8080/tcp
}

# A map the chart leaves empty, such as the labels it puts on every pod, takes keys of the user's
# choosing, and so does a security context map for the fields of Kubernetes' security context types
# (fixtures/security-context-fields). Keys of maps only: list items are the chart's input.
@test "every values key of open-feature-operator is one its pinned chart defines" {
  local keys="$BATS_TEST_TMPDIR/keys" unknown="" key map open
  local paths='[.. | select(path | length > 0) | path | select(all_c(tag == "!!str")) | join(".")] | .[]'
  render
  mkdir -p "$keys"
  yq -N "$paths" "$VALUES" | sort -u >"$keys/ours"
  yq -N "$paths" "$DEFAULTS" | sort -u >"$keys/chart"
  [ -s "$keys/ours" ]
  open="$(yq -N '[.. | select(tag == "!!map" and length == 0) | path | join(".")] | .[]' "$DEFAULTS")"
  while read -r key; do
    for map in $open; do
      if [[ $key == "$map".* ]]; then continue 2; fi
    done
    if [[ $key =~ (^|\.)(securityContext|podSecurityContext|containerSecurityContext)\.(.+)$ ]] &&
      grep -qxF -- "${BASH_REMATCH[3]}" "$BATS_TEST_DIRNAME/fixtures/security-context-fields"; then
      continue
    fi
    unknown+=" $key"
  done < <(comm -23 "$keys/ours" "$keys/chart")
  echo "keys the chart does not define:${unknown:- none}"
  [ -z "$unknown" ]
}
