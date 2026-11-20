#!/usr/bin/env bats
# Proves features/kguardian.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, kyverno, yq, jq and just on PATH (the versions pinned for the
# repository). The kguardian chart is pulled once per run from its public registry; building and
# rendering are offline, with the placeholders of the cluster's example key lists. just kguardian
# runs from a copy of the scripts against a recording kubectl, which reaches no cluster.

# flux build rewrites the kustomization.yaml of what it builds and puts it back afterwards, and the
# chart is pulled once: so the tests run one at a time.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

# Names sort and compare byte for byte.
export LC_ALL=C

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
  APP="$REPO/kubernetes/apps/base/kguardian/kguardian"
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
  kustomize build --load-restrictor LoadRestrictionsNone "${1:-$OVERLAY_DIR}" >"$OVERLAY"
}

# built: the kguardian application as Flux applies it on lab-sto2: the overlay's Kustomization of
# it, with the example key lists and its own substitutions over them, strictly. Writes
# $BATS_TEST_TMPDIR/kguardian-built.yaml and sets BUILT and KS, the Kustomization as built.
built() {
  local path
  overlay
  KS="$BATS_TEST_TMPDIR/kguardian-ks.yaml"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars
    | select(fileIndex == 1 and .kind == "Kustomization" and .metadata.name == "kguardian")
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "$EXAMPLE" "$OVERLAY" >"$KS"
  [ -s "$KS" ] || { echo "the lab-sto2 overlay does not enable kguardian"; return 1; }
  path="$(yq '.spec.path' "$KS")"
  BUILT="$BATS_TEST_TMPDIR/kguardian-built.yaml"
  (cd "$REPO" && flux build kustomization kguardian --path "./kubernetes/${path#./}" \
    --kustomization-file "$KS" --dry-run --strict-substitute) >"$BUILT"
}

# render: renders the chart that the HelmRelease of kguardian installs, from the URL and tag of its
# OCIRepository, its resource definitions included, with the values helm-controller gives it: those
# of the ConfigMap the HelmRelease reads, as it has none of its own. Builds kguardian, writes the
# chart's output to $RAW and the same through the release's post-renderers to $RENDERED, and sets
# BUILT, KS, VALUES, CHART and DEFAULTS, the chart's own values.
render() {
  local url tag name release namespace pulled post
  built
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  [ "$release" = kguardian ] && [ "$namespace" = kguardian ] || { echo "the release is $release in $namespace"; return 1; }
  VALUES="$BATS_TEST_TMPDIR/values.yaml"
  NAME="$name" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .data["values.yaml"]' "$BUILT" >"$VALUES"
  [ -s "$VALUES" ] || { echo "no values in the ConfigMap $name the HelmRelease reads"; return 1; }
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom | length' "$BUILT")" -eq 1 ] ||
    { echo "the HelmRelease reads values from more than its one ConfigMap"; return 1; }
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.values // {} | length' "$BUILT")" -eq 0 ] ||
    { echo "the HelmRelease has values of its own beside its ConfigMap"; return 1; }
  pulled="$BATS_FILE_TMPDIR/charts/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  DEFAULTS="$BATS_TEST_TMPDIR/defaults.yaml"
  helm show values "$CHART" >"$DEFAULTS"
  RAW="$BATS_TEST_TMPDIR/kguardian-chart.yaml"
  RENDERED="$BATS_TEST_TMPDIR/kguardian.yaml"
  post="$BATS_TEST_TMPDIR/post-render"
  mkdir -p "$post"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" --include-crds --values "$VALUES" >"$RAW"
  cp "$RAW" "$post/chart.yaml"
  # helm-controller then passes the manifests through the release's post-renderers; only kustomize
  # patches are known here, so any other kind fails instead of being skipped.
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.postRenderers // [] | map(select((keys - ["kustomize"] | length) > 0 or ((.kustomize | keys) - ["patches"] | length) > 0)) | length' "$BUILT")" -eq 0 ] ||
    { echo "the HelmRelease has a post-renderer that is not kustomize patches"; return 1; }
  yq -N 'select(.kind == "HelmRelease") | {"resources": ["chart.yaml"], "patches": (.spec.postRenderers // [] | map(.kustomize.patches // []) | flatten)}' "$BUILT" >"$post/kustomization.yaml"
  kustomize build "$post" >"$RENDERED"
}

# object FILE KIND NAME: the one object of that kind and name in FILE.
object() {
  KIND="$2" NAME="$3" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$1"
}

# only FILE KIND: the name of the one object of that kind in FILE; fails, saying so, unless there is
# exactly one.
only() {
  local names
  names="$(KIND="$2" yq -N 'select(.kind == strenv(KIND)) | .metadata.name' "$1")"
  [ -n "$names" ] && [ "$(wc -l <<<"$names")" -eq 1 ] || { echo "$1 holds $(grep -c . <<<"$names") $2 objects: ${names:-none}"; return 1; }
  echo "$names"
}

# workloads: writes the three workloads of the render and the one container of each: the observer's
# DaemonSet to $DAEMONSET and its container to $OBSERVER, the broker's Deployment to $BROKER_POD and
# its container to $BROKER, the interface's Deployment to $INTERFACE_POD and its container to
# $INTERFACE. Each pod has exactly the one container.
workloads() {
  DAEMONSET="$BATS_TEST_TMPDIR/daemonset.yaml" OBSERVER="$BATS_TEST_TMPDIR/observer.yaml"
  BROKER_POD="$BATS_TEST_TMPDIR/broker-pod.yaml" BROKER="$BATS_TEST_TMPDIR/broker.yaml"
  INTERFACE_POD="$BATS_TEST_TMPDIR/interface-pod.yaml" INTERFACE="$BATS_TEST_TMPDIR/interface.yaml"
  object "$RENDERED" DaemonSet kguardian-controller >"$DAEMONSET"
  object "$RENDERED" Deployment kguardian-broker >"$BROKER_POD"
  object "$RENDERED" Deployment kguardian-frontend >"$INTERFACE_POD"
  [ -s "$DAEMONSET" ] && [ -s "$BROKER_POD" ] && [ -s "$INTERFACE_POD" ] || { echo "the render lacks one of the three workloads"; return 1; }
  [ "$(yq '.spec.template.spec.containers | map(.name) | join(",")' "$DAEMONSET")" = controller ]
  [ "$(yq '.spec.template.spec.containers | map(.name) | join(",")' "$BROKER_POD")" = broker ]
  [ "$(yq '.spec.template.spec.containers | map(.name) | join(",")' "$INTERFACE_POD")" = frontend ]
  yq '.spec.template.spec.containers[0]' "$DAEMONSET" >"$OBSERVER"
  yq '.spec.template.spec.containers[0]' "$BROKER_POD" >"$BROKER"
  yq '.spec.template.spec.containers[0]' "$INTERFACE_POD" >"$INTERFACE"
}

# env_of CONTAINER NAME: the entry called NAME of the environment of the container in the file
# CONTAINER, as compact JSON with its keys sorted; empty when it has none.
env_of() {
  NAME="$2" yq -o json -I0 '.env[] | select(.name == strenv(NAME))' "$1" | jq -cS .
}

# env_value CONTAINER NAME: the literal value of the variable NAME; fails when it has none.
env_value() {
  NAME="$2" yq -e '.env[] | select(.name == strenv(NAME)) | .value' "$1"
}

# secret_key CONTAINER NAME SECRET KEY: succeeds when the variable NAME of the container is read
# from the key KEY of the Secret SECRET, and the pod does not start without it.
secret_key() {
  [ "$(env_of "$1" "$2")" = "$(SECRET="$3" KEY="$4" NAME="$2" yq -o json -I0 -n \
    '{"name": strenv(NAME), "valueFrom": {"secretKeyRef": {"name": strenv(SECRET), "key": strenv(KEY)}}}' | jq -cS .)" ]
}

# pod_of WORKLOAD NAME: the pod the workload in the file WORKLOAD makes, as a Pod called NAME in the
# namespace kguardian.
pod_of() {
  NAME="$2" yq '{"apiVersion": "v1", "kind": "Pod",
    "metadata": {"name": strenv(NAME), "namespace": "kguardian"} * (.spec.template.metadata | pick(["labels", "annotations"])),
    "spec": .spec.template.spec}' "$1"
}

# level_failures LEVEL WORKLOAD NAME: what the Pod Security level LEVEL refuses in the pod of the
# workload in the file WORKLOAD, by Kyverno's podSecurity rule as pod-security-check runs it: writes
# the failed controls, one per line, to $CONTROLS and the whole message to $FORBIDDEN.
level_failures() {
  local dir="$BATS_TEST_TMPDIR/level-$1-$3"
  mkdir -p "$dir"
  pod_of "$2" "$3" >"$dir/pod.yaml"
  cat >"$dir/policy.yaml" <<POLICY
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: $1
spec:
  validationFailureAction: Enforce
  rules:
    - name: $1
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        podSecurity:
          level: $1
          version: latest
POLICY
  # Exit 1 is a failed pod, which is the verdict; the report is the one line that starts with a brace.
  kyverno apply "$dir/policy.yaml" --resource "$dir/pod.yaml" -p --output-format json >"$dir/out" 2>"$dir/err" || [ $? -eq 1 ]
  grep '^{' "$dir/out" >"$dir/report.json"
  # A report with no result for the pod is no verdict.
  [ "$(jq '.results | length' "$dir/report.json")" -eq 1 ] || { echo "no verdict on $3 at $1: $(cat "$dir/out" "$dir/err")"; return 1; }
  CONTROLS="$dir/controls"
  FORBIDDEN="$dir/forbidden"
  jq -r '.results[0].properties.controls // "" | split(",") | .[] | select(. != "")' "$dir/report.json" | LC_ALL=C sort >"$CONTROLS"
  jq -r '.results[0].message // ""' "$dir/report.json" >"$FORBIDDEN"
}

# docs_section: writes the section "## kguardian" of docs/kubernetes.md, up to the next heading of
# its level, to $SECTION.
docs_section() {
  SECTION="$BATS_TEST_TMPDIR/section.md"
  awk '/^## / { on = ($0 == "## kguardian") } on' "$REPO/docs/kubernetes.md" >"$SECTION"
  [ -s "$SECTION" ] || { echo "docs/kubernetes.md has no section ## kguardian"; return 1; }
}

# tree_copy: copies kubernetes/ to $TREE; tree_without_ks APP...: takes each application's ks.yaml
# out of the copy's overlay.
tree_copy() {
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  mkdir -p "$TREE"
  cp -r "$REPO/kubernetes" "$TREE/kubernetes"
}

tree_without_ks() {
  local app
  tree_copy
  for app in "$@"; do
    APP_NAME="$app" yq -i '.resources |= map(select(test("/" + strenv(APP_NAME) + "/ks.yaml$") | not))' \
      "$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  done
}

# of_kguardian FILE: what an overlay built into FILE holds of kguardian, sorted, as kind, namespace
# and name: the namespace itself, any object in it, and any Kustomization that deploys into it or
# from its directory.
of_kguardian() {
  yq -N 'select((.kind == "Namespace" and .metadata.name == "kguardian") or .metadata.namespace == "kguardian"
      or .spec.targetNamespace == "kguardian" or ((.spec.path // "") | test("/apps/base/kguardian/")))
    | .kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$1" | LC_ALL=C sort | paste -sd, -
}

@test "kguardian is selected by overlay entries and builds nothing when it is not" {
  local dependency dependencies=(cloudnative-pg plugin-barman-cloud prometheus-operator-crds external-secrets openbao-store linstor-cluster cilium)
  # The overlay selects it with two entries, its namespace directory and its ks.yaml, and builds the
  # namespace, the defaults every namespace directory holds, the namespace's default deny, and the
  # Kustomization.
  [ "$(yq '.resources[] | select(test("/kguardian(/|$)"))' "$OVERLAY_DIR/kustomization.yaml" | paste -sd, -)" = ../../base/kguardian,../../base/kguardian/kguardian/ks.yaml ]
  overlay
  [ "$(of_kguardian "$OVERLAY")" = ConfigMap/kguardian/app-template-defaults,Kustomization/flux-system/kguardian,Namespace/-/kguardian,NetworkPolicy/kguardian/default-deny ]
  # Its Kustomization names what brings the kinds it applies and what they need, no more and no
  # less: the operator for the Cluster, the Barman Cloud plugin for its ObjectStore and archive, the
  # monitoring definitions for the PodMonitor and the chart's ServiceMonitor, External Secrets for
  # the generator and the ExternalSecrets, the secret store the backups' ExternalSecrets read,
  # LINSTOR's cluster for the instances' StorageClass, Cilium for the policies. It is Ready once the
  # release is, and waits for it with the long timeout, as the database's three instances start one
  # after another.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "kguardian") | .spec.dependsOn | map(.name) | sort | join(" ")' "$OVERLAY")" \
    = "$(printf '%s\n' "${dependencies[@]}" | sort | paste -sd' ' -)" ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "kguardian") | .spec.wait' "$OVERLAY")" = true ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "kguardian") | .metadata.labels["k8s-gitops/timeout"]' "$OVERLAY")" = long ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # With only the namespace directory's entry, the cluster builds the namespace, its defaults and its
  # default deny, and nothing else of kguardian.
  tree_without_ks kguardian
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ "$(of_kguardian "$OVERLAY")" = ConfigMap/kguardian/app-template-defaults,Namespace/-/kguardian,NetworkPolicy/kguardian/default-deny ]
  # With neither, nothing of kguardian.
  tree_without_ks kguardian
  NS=kguardian yq -i '.resources |= map(select(. != "../../base/" + strenv(NS)))' "$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ -z "$(of_kguardian "$OVERLAY")" ]
  # Selecting it without one of the applications it needs is refused, naming both.
  for dependency in "${dependencies[@]}"; do
    tree_without_ks "$dependency"
    run "$REPO/scripts/kubernetes-check" "$TREE"
    echo "without $dependency: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"kubernetes/apps/base/kguardian/kguardian/ks.yaml: Kustomization kguardian names $dependency"* ]]
    [[ $output == *"does not enable"* ]]
  done
}

@test "kguardian runs an observer, a broker and an interface, and nothing that calls outside the cluster or a language model" {
  local key name names referenced crds
  render
  workloads
  # What the release installs, as kind and name, and nothing else: the three workloads, the two
  # Services, the three service accounts, the observer's ClusterRole and its binding, the broker's
  # monitor, and the two definitions of the chart's crds directory, which Helm installs whatever the
  # values say.
  names="$(yq -N '.kind + "/" + .metadata.name' "$RENDERED" | LC_ALL=C sort | paste -sd, -)"
  echo "the render holds: $names"
  [ "$names" = "ClusterRole/kguardian-viewer,ClusterRoleBinding/kguardian,CustomResourceDefinition/auditclusternetworkpolicies.kguardian.dev,CustomResourceDefinition/auditnetworkpolicies.kguardian.dev,DaemonSet/kguardian-controller,Deployment/kguardian-broker,Deployment/kguardian-frontend,Service/kguardian-broker,Service/kguardian-frontend,ServiceAccount/broker,ServiceAccount/controller,ServiceAccount/frontend,ServiceMonitor/kguardian-broker" ]
  crds="$BATS_TEST_TMPDIR/chart-crds"
  mkdir -p "$crds"
  tar -xzf "$CHART" -C "$crds" --wildcards 'kguardian/crds/*'
  [ "$(yq -N '.metadata.name' "$crds"/kguardian/crds/*.yaml | LC_ALL=C sort | paste -sd, -)" \
    = "$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$RENDERED" | LC_ALL=C sort | paste -sd, -)" ]
  # Off, each by a value the repository sets, not by the chart's default.
  for key in evaluator.enabled database.enabled broker.helmTest.enabled broker.leaderElection.enabled \
    seccomp.installCRDs evaluator.imageTrust.installCRDs evaluator.applicationSecurityProfiles.installCRD \
    compute.enabled compute.contention.enabled seccomp.denials.enabled nodeCatalog.enabled seccomp.distribute \
    telemetry.enabled ai.enabled ai.mcp.enabled llmBridge.enabled llmBridge.secrets.openai.enabled \
    llmBridge.secrets.anthropic.enabled llmBridge.secrets.gemini.enabled llmBridge.secrets.copilot.enabled \
    supplychain.enabled; do
    [ "$(yq ".$key" "$VALUES")" = false ] || { echo "the values do not set $key to false: $(yq ".$key" "$VALUES")"; return 1; }
  done
  [ "$(yq '.controller.runtimeInventory.mode' "$VALUES")" = off ]
  [ "$(yq '.controller.runtimeInventory.capabilities' "$VALUES")" = false ]
  [ "$(yq '.ai | has("baseUrl")' "$VALUES")" = true ] && [ "$(yq '.ai.baseUrl | length' "$VALUES")" -eq 0 ]
  # The observer's pod holds its one container and the init container that waits for the broker: no
  # cataloguing sidecar, and none of the programs, host paths or rights the features that are off
  # would add.
  [ "$(yq '.spec.template.spec.initContainers | map(.name) | join(",")' "$DAEMONSET")" = wait-for-api ]
  [ "$(env_value "$OBSERVER" COMPUTE_ENABLED)" = false ]
  [ "$(env_value "$OBSERVER" SECCOMP_DENIAL_CAPTURE)" = false ]
  [ "$(env_value "$OBSERVER" RUNTIME_INVENTORY)" = off ]
  [ "$(env_value "$OBSERVER" RUNTIME_INVENTORY_CAPABILITIES)" = false ]
  for name in COMPUTE_CONTENTION_ENABLED SECCOMP_DISTRIBUTE SECCOMP_ROOT SECCOMP_DENIAL_INTERVAL_SECONDS NODE_CATALOG; do
    [ -z "$(env_of "$OBSERVER" "$name")" ] || { echo "the observer is given $name"; return 1; }
  done
  # The broker elects no leader: its one replica runs every background job, it holds no service
  # account token and mounts nothing, and no Role is made for it. It is given no evaluator.
  [ "$(yq '.spec.replicas' "$BROKER_POD")" -eq 1 ]
  [ "$(env_value "$BROKER" LEADER_ELECTION_ENABLED)" = false ]
  [ -z "$(env_of "$BROKER" LEADER_ELECTION_LEASE_NAME)" ]
  [ -z "$(env_of "$BROKER" EVALUATOR_URL)" ]
  [ "$(yq '.spec.template.spec.automountServiceAccountToken' "$BROKER_POD")" = false ]
  [ "$(yq '.spec.template.spec.volumes // [] | length' "$BROKER_POD")" -eq 0 ]
  [ "$(yq '.volumeMounts // [] | length' "$BROKER")" -eq 0 ]
  [ "$(object "$RENDERED" ServiceAccount broker | yq '.automountServiceAccountToken')" = false ]
  [ "$(yq '.spec.template.spec.initContainers | map(.name) | join(",")' "$BROKER_POD")" = wait-for-db ]
  # Nothing calls outside the cluster. The broker's daily version check-in is off, and it is told of
  # no optional feature and of no signature discovery.
  [ "$(env_value "$BROKER" TELEMETRY_ENABLED)" = false ]
  [ "$(env_value "$BROKER" SIGNATURE_DISCOVERY_ENABLED)" = false ]
  [ "$(env_of "$BROKER" FEATURES)" = '{"name":"FEATURES","value":""}' ]
  # No assistant: no llm-bridge workload, Service or account, the interface is given no bridge to
  # proxy to, and no variable of any container names a model provider's key, address or model, or the
  # MCP endpoint.
  [ -z "$(yq -N 'select(.metadata.name | test("llm|bridge|mcp|supplychain|evaluator|grype")) | .kind + "/" + .metadata.name' "$RENDERED")" ]
  [ -z "$(env_of "$INTERFACE" VITE_LLM_BRIDGE_URL)" ]
  [ -z "$(yq -N '.spec.template.spec | (.containers + (.initContainers // []))[] | .env[]?.name
    | select(test("^(OPENAI|ANTHROPIC|GOOGLE|GEMINI|COPILOT|GITHUB|MCP)_|_API_KEY$|_BASE_URL$|_MODEL$"))' "$RENDERED")" ]
  # The only Secrets anything of the render names are the tokens' and the database's: no provider's.
  referenced="$(yq -o json -I0 '.' "$RENDERED" | jq -r '.. | objects
    | (.secretKeyRef?.name, .secretRef?.name, .secret?.secretName, (.imagePullSecrets? // [])[]?.name) | select(. != null)' | LC_ALL=C sort -u | paste -sd, -)"
  echo "Secrets the render names: $referenced"
  [ "$referenced" = kguardian-broker-auth,kguardian-db-app ]
  [ "$(grep -ciE 'kguardian-(openai|anthropic|gemini|copilot)|llm-bridge' "$RENDERED" || true)" -eq 0 ]
  # The interface proxies to the broker of this namespace alone.
  [ "$(env_value "$INTERFACE" VITE_API_URL)" = http://kguardian-broker.kguardian.svc.cluster.local:9090 ]
  [ "$(env_value "$OBSERVER" API_ENDPOINT)" = http://kguardian-broker.kguardian.svc.cluster.local:9090 ]
  # The docs hold the table of what could call outside, with each switch.
  docs_section
  for key in telemetry.enabled ai.enabled llmBridge.enabled ai.mcp.enabled ai.baseUrl supplychain.enabled; do
    grep -qF "\`$key\`" "$SECTION" || { echo "the docs' section does not name $key"; return 1; }
  done
}

@test "kguardian's observer runs on every node with only the privileges it names" {
  local mounts orphans unmounted ns reason cap path minor listed
  render
  workloads
  # One pod on every node: a DaemonSet that tolerates every taint, the control planes' among them,
  # and picks its nodes by their operating system alone, at the priority Kubernetes gives node
  # agents, so the scheduler makes room for it on a node whose requests are full.
  [ "$(yq -o json -I0 '.spec.template.spec.tolerations' "$DAEMONSET")" = '[{"operator":"Exists"}]' ]
  [ "$(yq -o json -I0 '.spec.template.spec.nodeSelector' "$DAEMONSET")" = '{"kubernetes.io/os":"linux"}' ]
  [ "$(yq '.spec.template.spec.affinity // "" | length' "$DAEMONSET")" -eq 0 ]
  [ "$(yq '.spec.template.spec.priorityClassName' "$DAEMONSET")" = system-node-critical ]
  # It is in the host's network namespace, which the chart sets with no value for it, and in no other
  # namespace of the host: the processes it reads come from the /proc mount below. It names its
  # resolver as the cluster's, and opens no host port.
  [ "$(yq '.spec.template.spec.hostNetwork' "$DAEMONSET")" = true ]
  [ "$(yq '.spec.template.spec | (.hostPID // false) or (.hostIPC // false)' "$DAEMONSET")" = false ]
  [ "$(yq '.spec.template.spec.dnsPolicy' "$DAEMONSET")" = ClusterFirstWithHostNet ]
  [ "$(yq '[.spec.template.spec | (.containers + .initContainers)[] | .ports // [] | .[]] | length' "$DAEMONSET")" -eq 0 ]
  # The container's whole security context: not privileged, no escalation, a root filesystem it
  # cannot write, and exactly four capabilities added to an empty set. BPF loads the programs and
  # their maps, PERFMON admits the tracing program types and opens the perf events the kprobes and
  # the tracepoint attach through, SYS_PTRACE follows the network namespace of other processes under
  # /proc, and DAC_READ_SEARCH opens the directory of those namespaces for a process of another user.
  echo "security context: $(yq -o json -I0 '.securityContext' "$OBSERVER")"
  [ "$(yq -o json -I0 '.securityContext' "$OBSERVER" | jq -cS '.capabilities.add |= sort')" \
    = '{"allowPrivilegeEscalation":false,"capabilities":{"add":["BPF","DAC_READ_SEARCH","PERFMON","SYS_PTRACE"],"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true}' ]
  # The pod's own security context only names the runtime's seccomp profile, and no annotation
  # relaxes a profile.
  [ "$(yq -o json -I0 '.spec.template.spec.securityContext' "$DAEMONSET")" = '{"seccompProfile":{"type":"RuntimeDefault"}}' ]
  [ "$(yq '.spec.template.metadata.annotations // {} | keys | map(select(test("apparmor|seccomp|selinux"))) | length' "$DAEMONSET")" -eq 0 ]
  # The init container, which only asks the broker's health endpoint, is unprivileged and has no
  # capability, and mounts nothing.
  [ "$(yq -o json -I0 '.spec.template.spec.initContainers[0].securityContext' "$DAEMONSET" | jq -cS .)" \
    = '{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsNonRoot":true,"runAsUser":65534}' ]
  [ "$(yq '.spec.template.spec.initContainers[0].volumeMounts // [] | length' "$DAEMONSET")" -eq 0 ]
  # The host paths it mounts, each read-only: the node's /proc over its own, for the processes'
  # network namespaces and the kernel's symbol names; the kernel's tracing files, for the identifier
  # of the tracepoint; and the container runtime's socket, which it asks for each container's
  # process. The directories the chart also mounts and nothing reads are gone: the kernel's debug
  # files, the BPF filesystem and the runtime's bundle directory.
  mounts="$(yq -o json '.spec.template.spec.volumes // []' "$DAEMONSET" | jq -r --slurpfile c <(yq -o json '.volumeMounts' "$OBSERVER") '
    . as $volumes | $c[0][] | . as $m | first($volumes[] | select(.name == $m.name and .hostPath != null)) // empty
    | [$m.mountPath, .hostPath.path] + (if $m.readOnly then ["read-only"] else [] end) | join(" ")' | LC_ALL=C sort)"
  echo "$mounts"
  [ "$mounts" = "$(printf '%s\n' '/proc /proc read-only' '/run/containerd/containerd.sock /run/containerd/containerd.sock read-only' '/sys/kernel/tracing /sys/kernel/tracing read-only')" ]
  [ "$(yq '[.spec.template.spec.volumes[] | select(.hostPath != null) | .hostPath.path] | sort | join(" ")' "$DAEMONSET")" = "/proc /run/containerd/containerd.sock /sys/kernel/tracing" ]
  # The pod has no other volume, every volume is mounted, and every mount of every container names a
  # volume of the pod: a mount left behind by a volume the post-renderer removed is a pod the API
  # server refuses.
  [ "$(yq '[.spec.template.spec.volumes[] | select(.hostPath == null)] | length' "$DAEMONSET")" -eq 0 ]
  [ "$(yq '.volumeMounts | length' "$OBSERVER")" -eq 3 ]
  orphans="$(yq -o json '.spec.template.spec' "$DAEMONSET" | jq -r '[.volumes // [] | .[].name] as $volumes
    | (.containers + (.initContainers // []))[] | .name as $c | (.volumeMounts // [])[]
    | select(.name as $n | $volumes | index($n) | not) | "\($c): \(.mountPath) names no volume \(.name)"')"
  [ -z "$orphans" ] || { echo "$orphans"; return 1; }
  unmounted="$(yq -o json '.spec.template.spec' "$DAEMONSET" | jq -r '[(.containers + (.initContainers // []))[] | (.volumeMounts // [])[].name] as $mounted
    | (.volumes // [])[] | select(.name as $n | $mounted | index($n) | not) | .name')"
  [ -z "$unmounted" ] || { echo "volumes nothing mounts: $unmounted"; return 1; }
  # What it costs per node is the chart's own guidance.
  [ "$(yq -o json -I0 '.resources' "$OBSERVER" | jq -cS .)" = "$(yq -o json -I0 '.controller.resources' "$DEFAULTS" | jq -cS .)" ]
  [ "$(yq '.resources.requests.memory' "$OBSERVER")" != null ] && [ "$(yq '.resources.limits.memory' "$OBSERVER")" != null ]
  # The namespace, as the overlay builds it, enforces privileged, which the host's network namespace,
  # host paths and added capabilities need, and audits and warns at restricted at the cluster's minor.
  minor="${KUBE%.*}"
  ns="$(object "$OVERLAY" Namespace kguardian)"
  [ "$(yq '.metadata.labels["pod-security.kubernetes.io/enforce"]' <<<"$ns")" = privileged ]
  [ "$(yq '.metadata.labels["pod-security.kubernetes.io/audit"]' <<<"$ns")" = restricted ]
  [ "$(yq '.metadata.labels["pod-security.kubernetes.io/warn"]' <<<"$ns")" = restricted ]
  [ "$(yq '.metadata.labels["pod-security.kubernetes.io/audit-version"]' <<<"$ns")" = "$minor" ]
  [ "$(yq '.metadata.labels["pod-security.kubernetes.io/warn-version"]' <<<"$ns")" = "$minor" ]
  # The exceptions list holds the DaemonSet, alone for the namespace, at the level it needs.
  [ "$(yq '[.exceptions[] | select(.namespace == "kguardian")] | map(.workload + " " + .level) | join(",")' "$REPO/pod-security-exceptions.yaml")" = "DaemonSet/kguardian-controller privileged" ]
  # Its reason says what the baseline level refuses in the pod: the controls it fails, the host's
  # network namespace, each capability and each host path, and nothing the pod does not have.
  reason="$(yq '.exceptions[] | select(.namespace == "kguardian") | .reason' "$REPO/pod-security-exceptions.yaml")"
  level_failures baseline "$DAEMONSET" kguardian-controller
  echo "failed controls: $(paste -sd' ' "$CONTROLS")"
  [ "$(paste -sd' ' "$CONTROLS")" = "capabilities_baseline hostNamespaces hostPathVolumes" ]
  [[ $reason == *"host's network namespace"* ]] || { echo "the reason does not name the host's network namespace"; return 1; }
  # Each capability and each host path is an entry of the reason's own list of them, which other prose
  # of the reason cannot stand in for: the capabilities listed after "the added capabilities", up to
  # ", with which", and the paths listed after "mounts the host paths", up to the first ";", are
  # exactly the container's added capabilities and the pod's host paths.
  listed="$(sed -nE 's/.*the added capabilities ([^;]*), with which .*/\1/p' <<<"$reason" | grep -oE '[A-Z][A-Z_]+' | LC_ALL=C sort | paste -sd' ' -)"
  echo "the reason's capabilities: $listed"
  [ "$listed" = "$(yq '.securityContext.capabilities.add[]' "$OBSERVER" | LC_ALL=C sort | paste -sd' ' -)" ] ||
    { echo "the reason's list of capabilities is not the container's"; return 1; }
  listed="$(sed -nE 's/.*mounts the host paths ([^;]*);.*/\1/p' <<<"$reason" | grep -oE '(^| )/[^ ,;]+' | tr -d ' ' | LC_ALL=C sort | paste -sd' ' -)"
  echo "the reason's host paths: $listed"
  [ "$listed" = "$(yq '.spec.template.spec.volumes[] | select(.hostPath != null) | .hostPath.path' "$DAEMONSET" | LC_ALL=C sort | paste -sd' ' -)" ] ||
    { echo "the reason's list of host paths is not the pod's"; return 1; }
  for path in /sys/kernel/debug /sys/fs/bpf /sys/fs/cgroup io.containerd.runtime.v2.task /var/lib/kubelet; do
    if [[ $reason == *"$path"* ]]; then echo "the reason names $path, which the pod does not mount"; return 1; fi
  done
  for cap in SYS_ADMIN SYS_RESOURCE NET_ADMIN DAC_OVERRIDE; do
    if [[ $reason == *"$cap"* ]]; then echo "the reason names $cap, which the container does not have"; return 1; fi
  done
  [[ $reason == *capabilit* && $reason == *"host path"* && $reason == *read-only* ]]
  [[ $reason != *"host's process"* && $reason != *"privileged container"* && $reason != *[Aa]pp[Aa]rmor* ]]
  # Every other pod of the render passes the restricted level.
  level_failures restricted "$BROKER_POD" kguardian-broker
  [ ! -s "$CONTROLS" ] || { echo "the broker's pod fails restricted: $(cat "$FORBIDDEN")"; return 1; }
  level_failures restricted "$INTERFACE_POD" kguardian-frontend
  [ ! -s "$CONTROLS" ] || { echo "the interface's pod fails restricted: $(cat "$FORBIDDEN")"; return 1; }
  # The docs give the same capabilities and host paths.
  docs_section
  for cap in $(yq '.securityContext.capabilities.add[]' "$OBSERVER"); do
    grep -qF "\`$cap\`" "$SECTION" || { echo "the docs' section does not name the capability $cap"; return 1; }
  done
  for path in $(yq '.spec.template.spec.volumes[] | select(.hostPath != null) | .hostPath.path' "$DAEMONSET"); do
    grep -qF "\`$path\`" "$SECTION" || { echo "the docs' section does not name the host path $path"; return 1; }
  done
}

@test "kguardian records every namespace but its own and keeps what it records for the days the docs give" {
  local window key variable days
  render
  workloads
  # Every namespace but its own: the chart's default also leaves out kube-system, one of the
  # namespaces the record is for.
  [ "$(yq -o json -I0 '.controller.excludedNamespaces' "$VALUES")" = '["kguardian"]' ]
  [ "$(env_value "$OBSERVER" EXCLUDED_NAMESPACES)" = kguardian ]
  # DaemonSets on the pod network are recorded as any other pod, and their peers' flows with them.
  [ "$(yq '.controller.ignoreDaemonSet' "$VALUES")" = false ]
  [ "$(env_value "$OBSERVER" IGNORE_DAEMONSET_TRAFFIC)" = false ]
  # Every system call, the only level a complete seccomp profile comes from.
  [ "$(yq '.syscalls.captureLevel' "$VALUES")" = full ]
  [ "$(env_value "$OBSERVER" SYSCALL_CAPTURE_LEVEL)" = full ]
  [ -z "$(env_of "$OBSERVER" SYSCALL_CUSTOM_LIST)" ]
  # The retention the broker runs with is written in the values, not left to the chart, and is what
  # its environment holds: 14 days for the flows of a pod that is gone, 30 for the pod itself, and
  # each other window as the chart has it.
  for window in broker.traffic.retention.days:POD_TRAFFIC_RETENTION_DAYS:14 \
    broker.podInventory.retention.deadPodDays:DEAD_POD_RETENTION_DAYS:30 \
    broker.audit.retention.days:AUDIT_VERDICTS_RETENTION_DAYS:30 \
    broker.imageInventory.retention.days:IMAGE_INVENTORY_RETENTION_DAYS:30 \
    broker.seccomp.denials.retention.days:SECCOMP_DENIALS_RETENTION_DAYS:30 \
    broker.runtimeInventory.retentionDays:RUNTIME_INVENTORY_RETENTION_DAYS:30 \
    broker.supplychain.retention.days:SUPPLYCHAIN_RETENTION_DAYS:30 \
    broker.supplychain.retention.attestationDays:IMAGE_ATTESTATION_RETENTION_DAYS:7 \
    compute.history.retentionDays:COMPUTE_HISTORY_RETENTION_DAYS:7; do
    IFS=: read -r key variable days <<<"$window"
    [ "$(yq ".$key" "$VALUES")" = "$days" ] || { echo "the values do not set $key to $days: $(yq ".$key" "$VALUES")"; return 1; }
    [ "$(env_value "$BROKER" "$variable")" = "$days" ] || { echo "the broker's $variable is not $days"; return 1; }
    # As the chart has it, but for the window of a pod that is gone, which the chart leaves to the
    # audit window and the values write out.
    if [ "$key" = broker.podInventory.retention.deadPodDays ]; then
      [ "$(yq ".$key" "$DEFAULTS")" -eq 0 ] && [ "$days" = "$(yq '.broker.audit.retention.days' "$DEFAULTS")" ]
    else
      [ "$(yq ".$key" "$DEFAULTS")" = "$days" ] || { echo "the chart's $key is $(yq ".$key" "$DEFAULTS"), the values' $days"; return 1; }
    fi
  done
  # No cap deletes a running pod's flows whatever their age.
  [ "$(env_value "$BROKER" POD_TRAFFIC_MAX_ROWS_PER_POD)" = 0 ]
  # The docs give those days.
  docs_section
  grep -q '14 days' "$SECTION"
  grep -q '30 days' "$SECTION"
  # What the observer may read of the cluster: pods, namespaces and Services, the workloads that own
  # pods, and the get of any Job and any Node, which it uses for a pod's owner and its own Node, and
  # nothing else; it changes nothing.
  echo "rules: $(object "$RENDERED" ClusterRole kguardian-viewer | yq -o json -I0 '.rules')"
  [ "$(object "$RENDERED" ClusterRole kguardian-viewer | yq -o json -I0 '.rules' | jq -cS 'map(.resources |= sort | .verbs |= sort) | sort_by(.apiGroups[0], .resources[0])')" \
    = '[{"apiGroups":[""],"resources":["namespaces","pods","services"],"verbs":["get","list","watch"]},{"apiGroups":[""],"resources":["nodes"],"verbs":["get"]},{"apiGroups":["apps"],"resources":["daemonsets","deployments","replicasets","statefulsets"],"verbs":["get","list","watch"]},{"apiGroups":["batch"],"resources":["jobs"],"verbs":["get"]}]' ]
  [ "$(object "$RENDERED" ClusterRoleBinding kguardian | yq -o json -I0 '[.roleRef.kind, .roleRef.name, (.subjects | map(.kind + "/" + .namespace + "/" + .name) | join(","))]')" \
    = '["ClusterRole","kguardian-viewer","ServiceAccount/kguardian/controller"]' ]
  [ "$(yq '.spec.template.spec.serviceAccountName' "$DAEMONSET")" = controller ]
  [ -z "$(yq -N 'select(.kind == "Role" or .kind == "RoleBinding") | .metadata.name' "$RENDERED")" ]
}

@test "kguardian's record is kept in a PostgreSQL cluster of the component, with the component's backups" {
  local cluster pool replicas dir made kind name ours theirs retention keep
  local -a vars=()
  render
  workloads
  # The database is the component's: the Kustomization takes it for the cluster kguardian-db in its
  # own namespace, with the size of each instance's volume, and names the plugin that archives it
  # and the secret store its backups' keys are read from.
  [ "$(yq '.spec.components | map(select(test("/components/cnpg-cluster$"))) | length' "$KS")" -eq 1 ]
  [ "$(yq '.spec.postBuild.substitute.CNPG_CLUSTER_NAME' "$KS")" = kguardian-db ]
  [ "$(yq '.spec.postBuild.substitute.CNPG_NAMESPACE' "$KS")" = "$(yq '.spec.targetNamespace' "$KS")" ]
  [ "$(yq '.spec.targetNamespace' "$KS")" = kguardian ]
  [ "$(yq '.spec.postBuild.substitute.CNPG_STORAGE_SIZE' "$KS")" = 5Gi ]
  for name in plugin-barman-cloud openbao-store; do
    [ "$(NAME="$name" yq '.spec.dependsOn | map(select(.name == strenv(NAME))) | length' "$KS")" -eq 1 ] ||
      { echo "the Kustomization does not name $name"; return 1; }
  done
  cluster="$(only "$BUILT" Cluster)"
  [ "$cluster" = kguardian-db ]
  [ "$(object "$BUILT" Cluster "$cluster" | yq '.metadata.namespace')" = kguardian ]
  [ "$(object "$BUILT" Cluster "$cluster" | yq '.spec.instances')" -eq 3 ]
  [ "$(object "$BUILT" Cluster "$cluster" | yq '.spec.storage.size')" = 5Gi ]
  # Whole: every object the component makes, built from the component alone with the same
  # variables, is in the build with the same content, the WAL archive, the base backups and the dump
  # job among them. The one change is the labels the application gives the dump job's pods, which
  # its policies select it by.
  dir="$BATS_TEST_TMPDIR/component"
  mkdir -p "$dir"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\ncomponents:\n  - %s\n' \
    "$(realpath --relative-to="$dir" "$REPO/kubernetes/components/cnpg-cluster")" >"$dir/kustomization.yaml"
  mapfile -t vars < <(yq -o json '.spec.postBuild.substitute' "$KS" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
  kustomize build --load-restrictor LoadRestrictionsNone "$dir" | env -i PATH="$PATH" "${vars[@]}" flux envsubst --strict >"$dir/made.yaml"
  made="$(yq -N '.kind + "/" + .metadata.name' "$dir/made.yaml" | LC_ALL=C sort)"
  echo "the component makes: $(paste -sd, - <<<"$made")"
  [ "$(paste -sd, - <<<"$made")" = Cluster/kguardian-db,ConfigMap/kguardian-db-dump-scripts,CronJob/kguardian-db-pgdump,ExternalSecret/kguardian-db-backup,ExternalSecret/kguardian-db-dump-s3,ObjectStore/kguardian-db,PodMonitor/kguardian-db,ScheduledBackup/kguardian-db ]
  while IFS=/ read -r kind name; do
    ours="$(object "$BUILT" "$kind" "$name" | yq -o json -I0 '(.spec // .data) | del(.jobTemplate.spec.template.metadata)' | jq -cS .)"
    theirs="$(object "$dir/made.yaml" "$kind" "$name" | yq -o json -I0 '.spec // .data' | jq -cS .)"
    [ "$ours" = "$theirs" ] || { echo "$kind/$name is not the component's: $(diff <(jq . <<<"$theirs") <(jq . <<<"$ours"))"; return 1; }
  done <<<"$made"
  [ "$(object "$BUILT" CronJob kguardian-db-pgdump | yq -o json -I0 '.spec.jobTemplate.spec.template.metadata' | jq -cS .)" \
    = '{"labels":{"app.kubernetes.io/instance":"kguardian-db","app.kubernetes.io/name":"pgdump"}}' ]
  # So the operator archives the WAL through the plugin to the ObjectStore and takes the daily base
  # backup, and the job dumps the database once a day (tests/postgresql.bats reads what the backups
  # do for every database of the overlay, and tests/postgres-dumps.bats what the component's dump
  # job does).
  [ "$(object "$BUILT" Cluster "$cluster" | yq -o json -I0 '.spec.plugins | map([.name, .isWALArchiver, .parameters.barmanObjectName])')" \
    = '[["barman-cloud.cloudnative-pg.io",true,"kguardian-db"]]' ]
  [ "$(object "$BUILT" ScheduledBackup "$cluster" | yq '.spec.method + " " + .spec.cluster.name')" = "plugin kguardian-db" ]
  # The docs say the record is in those backups too, in the object storage, for as long as the
  # component keeps them: the ObjectStore's recovery window and the newest dumps the job keeps.
  retention="$(object "$BUILT" ObjectStore "$cluster" | yq '.spec.retentionPolicy')"
  keep="$(object "$BUILT" CronJob kguardian-db-pgdump | yq '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "upload") | .env[] | select(.name == "KEEP_DUMPS") | .value')"
  echo "retention: $retention; dumps kept: $keep"
  [[ $retention =~ ^[0-9]+d$ ]] && [[ $keep =~ ^[0-9]+$ ]]
  docs_section
  grep -qF "recovery window of ${retention%d} days" "$SECTION" || { echo "the docs' section does not give the archive's ${retention%d} days"; return 1; }
  grep -qF "newest $keep dumps" "$SECTION" || { echo "the docs' section does not give the $keep dumps the job keeps"; return 1; }
  # Nothing else of the application copies the record anywhere: it has no volume of its own, no
  # volume backup and no secret store of its own.
  [ -z "$(yq -N 'select(.kind == "ClusterSecretStore" or .kind == "SecretStore" or .kind == "ReplicationSource" or .kind == "PersistentVolumeClaim") | .kind' "$BUILT" "$RENDERED")" ]
  [ -z "$(yq -N 'select(.kind == "CronJob" or .kind == "Job") | .metadata.name' "$RENDERED")" ]
  # The chart's own database, with its Secret, its claim and its dump hook, is off: the set of what
  # the render holds, in the test above, has none of them.
  [ "$(yq '.database.enabled' "$VALUES")" = false ]
  [ -z "$(yq -N 'select(.metadata.name | test("kguardian-db")) | .kind + "/" + .metadata.name' "$RENDERED")" ]
  # The broker connects as the user that owns the database app, to the Service of the cluster's
  # primary, over TLS, with the password of the Secret the operator makes for that user.
  [ "$(yq '.database.user' "$VALUES")" = app ] && [ "$(yq '.database.databaseName' "$VALUES")" = app ]
  [ "$(yq '.database.existingSecret' "$VALUES")" = "$cluster-app" ]
  [ "$(yq '.database.passwordSecretKey' "$VALUES")" = password ]
  [ "$(yq '.database.external.host' "$VALUES")" = "$cluster-rw" ]
  [ "$(yq '.database.external.sslMode' "$VALUES")" = require ]
  secret_key "$BROKER" DB_PASSWORD "$cluster-app" password
  # shellcheck disable=SC2016 # the kubelet expands $(DB_PASSWORD), not the shell.
  [ "$(env_value "$BROKER" DATABASE_URL)" = 'postgres://app:$(DB_PASSWORD)@kguardian-db-rw:5432/app?sslmode=require' ]
  [ "$(yq -o json -I0 '.spec.template.spec.initContainers[0].command' "$BROKER_POD")" \
    = '["sh","-c","until nc -z kguardian-db-rw 5432; do echo '"'"'waiting for db'"'"'; sleep 2; done"]' ]
  # The connections the broker can hold, by the chart's formula, every pod of a rolling update with a
  # full pool and 13 for everything else, fit the Cluster, which sets no max_connections and so has
  # PostgreSQL's 100.
  [ "$(object "$BUILT" Cluster "$cluster" | yq '.spec.postgresql.parameters.max_connections // "unset"')" = unset ]
  pool="$(env_value "$BROKER" DB_POOL_MAX_SIZE)"
  replicas="$(yq '.spec.replicas' "$BROKER_POD")"
  echo "connections: ($replicas + 1) x $pool + 13 = $(((replicas + 1) * pool + 13))"
  [ $(((replicas + 1) * pool + 13)) -le 100 ]
  # No credential in the tree: nothing built or rendered is a Secret, and no variable whose name
  # says it holds one has a value of its own.
  [ -z "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$BUILT" "$RENDERED")" ]
  [ -z "$(yq -N '.spec.template.spec | (.containers + (.initContainers // []))[] | .env[]? | select(.name | test("PASSWORD|KEY|SECRET|TOKEN|CREDENTIAL")) | select(has("value")) | .name' "$RENDERED")" ]
  [ -z "$(find "$REPO/kubernetes/apps/base/kguardian" \( -name '*.enc.*' -o -name '*.sops.*' -o -name '*.age*' \))" ]
}

@test "kguardian's broker admits only callers that hold a token made in the cluster" {
  local es="$BATS_TEST_TMPDIR/es.yaml" generator="$BATS_TEST_TMPDIR/generator.yaml"
  render
  workloads
  # Authentication is on, with a token for each scope, read from one Secret.
  [ "$(yq '.broker.auth.enabled' "$VALUES")" = true ]
  [ "$(yq '.broker.auth.mode' "$VALUES")" = scoped ]
  [ "$(yq '.broker.auth.existingSecret' "$VALUES")" = kguardian-broker-auth ]
  # The broker reads both tokens and does not start without either; the two scopes nothing here uses
  # are read only if the Secret holds them, which it does not.
  secret_key "$BROKER" BROKER_TOKEN_READ kguardian-broker-auth read
  secret_key "$BROKER" BROKER_TOKEN_INGEST kguardian-broker-auth ingest
  [ "$(env_of "$BROKER" BROKER_TOKEN_SUPPLYCHAIN | jq -c '.valueFrom.secretKeyRef | [.key, .optional]')" = '["supplychain",true]' ]
  [ "$(env_of "$BROKER" BROKER_TOKEN_ADMIN | jq -c '.valueFrom.secretKeyRef | [.key, .optional]')" = '["admin",true]' ]
  [ -z "$(env_of "$BROKER" BROKER_AUTH_TOKEN)" ]
  # The observer presents the token that may write, the interface the one that may only read.
  secret_key "$OBSERVER" BROKER_AUTH_TOKEN kguardian-broker-auth ingest
  secret_key "$INTERFACE" BROKER_AUTH_TOKEN kguardian-broker-auth read
  # The Secret is made in the cluster, once: an ExternalSecret that is never refreshed, from one
  # Password generator, which gives each of its two keys a value of its own, in hexadecimal. Nothing
  # copies one value under both keys: no template, no rewrite, no second source, and no store to
  # read a seeded value from.
  [ "$(yq -N 'select(.apiVersion | test("^generators\.external-secrets\.io/")) | .kind + "/" + .metadata.name' "$BUILT")" = Password/kguardian-broker-auth ]
  object "$BUILT" ExternalSecret kguardian-broker-auth >"$es"
  object "$BUILT" Password kguardian-broker-auth >"$generator"
  [ "$(yq '.metadata.namespace' "$es")" = kguardian ] && [ "$(yq '.metadata.namespace' "$generator")" = kguardian ]
  [ "$(yq '.spec.refreshPolicy' "$es")" = CreatedOnce ]
  [ "$(yq '.spec.target.name' "$es")" = kguardian-broker-auth ]
  [ "$(yq '.spec.target.creationPolicy' "$es")" = Owner ]
  [ "$(yq '.spec.target | has("template")' "$es")" = false ]
  [ "$(yq '.spec | has("data") or has("secretStoreRef")' "$es")" = false ]
  [ "$(yq -o json -I0 '.spec.dataFrom' "$es")" \
    = '[{"sourceRef":{"generatorRef":{"apiVersion":"generators.external-secrets.io/v1alpha1","kind":"Password","name":"kguardian-broker-auth"}}}]' ]
  [ "$(yq '.spec.secretKeys | sort | join(",")' "$generator")" = ingest,read ]
  [ "$(yq '.spec.encoding' "$generator")" = hex ]
  [ "$(yq '.spec.length' "$generator")" -ge 32 ]
  [ "$(yq '.spec | has("prefix") or has("suffix")' "$generator")" = false ]
  # The generator and the ExternalSecret are kinds External Secrets brings.
  [ "$(yq '.spec.dependsOn | map(select(.name == "external-secrets")) | length' "$KS")" -eq 1 ]
  # No token is in the tree.
  [ -z "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$BUILT" "$RENDERED")" ]
}

@test "kguardian's broker is scraped by a monitor that selects its Service" {
  local service="$BATS_TEST_TMPDIR/service.yaml" monitor="$BATS_TEST_TMPDIR/monitor.yaml" selected port target
  render
  workloads
  [ "$(yq '.broker.metrics.serviceMonitor.enabled' "$VALUES")" = true ]
  object "$RENDERED" Service kguardian-broker >"$service"
  object "$RENDERED" ServiceMonitor "$(only "$RENDERED" ServiceMonitor)" >"$monitor"
  # The monitor looks in the release's namespace, for Services that carry its selector's labels.
  [ "$(yq '.metadata.name' "$monitor")" = kguardian-broker ]
  [ "$(yq -o json -I0 '.spec.namespaceSelector' "$monitor")" = '{"matchNames":["kguardian"]}' ]
  [ "$(yq '.spec.selector.matchLabels | length' "$monitor")" -gt 0 ]
  [ "$(yq '.spec.selector | keys | join(",")' "$monitor")" = matchLabels ]
  # As the chart renders it, the broker's Service carries none of them, so the monitor would select
  # nothing: the release's post-renderer gives the Service the label.
  [ "$(object "$RAW" Service kguardian-broker | yq '.metadata.labels | has("app.kubernetes.io/name")')" = false ]
  selected="$(yq -o json -I0 'select(.kind == "Service")' "$RENDERED" | jq -r --slurpfile m <(yq -o json -I0 '.spec.selector.matchLabels' "$monitor") '
    select((.metadata.labels // {}) as $l | $m[0] | to_entries | all(.[]; $l[.key] == .value)) | .metadata.name')"
  echo "Services the monitor selects: ${selected:-none}"
  [ "$selected" = kguardian-broker ]
  # It scrapes the port of that Service it names, over plain HTTP at /metrics, and that port sends to
  # the broker's container port.
  [ "$(yq '.spec.endpoints | length' "$monitor")" -eq 1 ]
  port="$(yq '.spec.endpoints[0].port' "$monitor")"
  [ "$(yq '.spec.endpoints[0].path' "$monitor")" = /metrics ]
  [ "$(yq '.spec.endpoints[0] | has("scheme") or has("tlsConfig") or has("bearerTokenSecret") or has("authorization")' "$monitor")" = false ]
  target="$(P="$port" yq '.spec.ports[] | select(.name == strenv(P)) | .targetPort' "$service")"
  [ -n "$target" ] || { echo "the Service has no port named $port"; return 1; }
  [ "$(P="$target" yq '.ports[] | select(.name == strenv(P)) | .containerPort' "$BROKER")" -eq 9090 ]
  # The Service selects the broker's pods, and no other pod of the render.
  [ "$(yq -o json -I0 '.spec.selector' "$service")" = '{"app.kubernetes.io/name":"kguardian-broker"}' ]
  [ "$(yq '.spec.template.metadata.labels["app.kubernetes.io/name"]' "$BROKER_POD")" = kguardian-broker ]
  [ "$(yq '.spec.template.metadata.labels["app.kubernetes.io/name"]' "$INTERFACE_POD")" != kguardian-broker ]
  [ "$(yq '.spec.template.metadata.labels["app.kubernetes.io/name"]' "$DAEMONSET")" != kguardian-broker ]
  # The monitor is a kind the Prometheus Operator's definitions bring.
  [ "$(yq '.spec.dependsOn | map(select(.name == "prometheus-operator-crds")) | length' "$KS")" -eq 1 ]
}

@test "kguardian's interface has no route and answers no host name but its Service's" {
  local routed
  render
  workloads
  # Nothing the application builds or its chart renders routes to it from outside the cluster: no
  # route, no Ingress, no Gateway, and no object of the Gateway API's or Envoy Gateway's groups.
  routed="$(yq -N 'select(.kind == "HTTPRoute" or .kind == "GRPCRoute" or .kind == "TCPRoute" or .kind == "TLSRoute" or .kind == "Ingress"
      or .kind == "Gateway" or .kind == "SecurityPolicy"
      or ((.apiVersion // "") | test("^gateway[.](networking[.]k8s|envoyproxy)[.]io/")))
    | .kind + "/" + .metadata.name' "$BUILT" "$RENDERED")"
  echo "routing objects: ${routed:-none}"
  [ -z "$routed" ]
  # The namespace does not let routes attach to the public Gateway.
  [ "$(object "$OVERLAY" Namespace kguardian | yq '.metadata.labels | has("k8s-gitops/gateway")')" = false ]
  # Its Service, and the broker's, are reachable from inside the cluster alone.
  [ "$(yq -N 'select(.kind == "Service") | .metadata.name + ":" + .spec.type' "$RENDERED" | LC_ALL=C sort | paste -sd, -)" = kguardian-broker:ClusterIP,kguardian-frontend:ClusterIP ]
  [ -z "$(yq -N 'select(.kind == "Service") | select(has("externalIPs") or .spec.externalIPs != null or .spec.loadBalancerIP != null) | .metadata.name' "$RENDERED")" ]
  # The Service's port 5173, which just kguardian forwards to, sends to the interface's container
  # port 5173.
  [ "$(object "$RENDERED" Service kguardian-frontend | yq -o json -I0 '.spec.ports' | jq -cS .)" = '[{"name":"http","port":5173,"protocol":"TCP","targetPort":"http"}]' ]
  [ "$(yq '.ports[] | select(.name == "http") | .containerPort' "$INTERFACE")" -eq 5173 ]
  # The interface answers its Service's own names and no other host name: with a list, the chart
  # adds the Service's names to it; without one, the server answers any host name.
  [ "$(yq -o json -I0 '.frontend.allowedHosts' "$VALUES")" = '["kguardian-frontend"]' ]
  [ "$(env_value "$INTERFACE" ALLOWED_HOSTS)" = kguardian-frontend,kguardian-frontend.kguardian,kguardian-frontend.kguardian.svc,kguardian-frontend.kguardian.svc.cluster.local ]
}

# recipe_copy: a copy of the repository's scripts, with a kubeconfig for the cluster lab-sto2, for
# just kguardian to run in through the repository's justfile, against recording fakes: a mise with
# nothing installed, which keeps the justfile from putting real tools in front of the fakes, and a
# kubectl that records its arguments and the kubeconfig it was given, then acts as the file
# $STATE/mode says: forward reports a forward and runs until SIGTERM ends it, as kubectl does;
# silent runs without reporting one; fail stops at once with an error naming an address; drop
# reports a forward and stops a moment later. Sets COPY, BIN, RECORD, STATE, KUBECONFIG_FILE, JUST
# and ENVIRONMENT, the only variables the recipe gets.
recipe_copy() {
  COPY="$BATS_TEST_TMPDIR/copy" BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record" STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$COPY/talos/lab-sto2/clusterconfig" "$BIN" "$RECORD" "$STATE"
  cp -R "$REPO/scripts" "$COPY/scripts"
  KUBECONFIG_FILE="$COPY/talos/lab-sto2/clusterconfig/kubeconfig"
  echo 'not a real kubeconfig' >"$KUBECONFIG_FILE"
  echo forward >"$STATE/mode"
  JUST=$(command -v just)
  only_env
  printf '#!/usr/bin/env bash\n' >"$BIN/mise"
  { printf '#!/usr/bin/env bash\nRECORD=%q STATE=%q\n' "$RECORD" "$STATE"; cat <<'EOF'; } >"$BIN/kubectl"
printf '%s\n' "$*" >>"$RECORD/argv"
printf '%s\n' "${KUBECONFIG-unset}" >>"$RECORD/kubeconfig"
env | cut -d= -f1 >>"$RECORD/names"
echo "$$ $PPID" >"$STATE/pids"
last=${!#}
case $(cat "$STATE/mode") in
  fail)
    echo 'error: dial tcp 192.0.2.10:6443: connect: connection refused' >&2
    exit 1
    ;;
  forward | drop) echo "Forwarding from 127.0.0.1:${last%%:*} -> ${last##*:}" ;;
esac
trap 'echo SIGTERM >>"$RECORD/ended"; exit 0' TERM
if [[ $(cat "$STATE/mode") == drop ]]; then
  sleep 1
  echo 'error: lost connection to pod' >&2
  exit 1
fi
while :; do sleep 0.1; done
EOF
  chmod +x "$BIN/mise" "$BIN/kubectl"
}

# with_env ENTRY...: adds the NAME=VALUE ENTRY... to the environment just kguardian gets.
with_env() {
  ENVIRONMENT+=("$@")
}

# only_env ENTRY...: the environment just kguardian gets is TMPDIR and the NAME=VALUE ENTRY... alone.
only_env() {
  ENVIRONMENT=(TMPDIR="$BATS_TEST_TMPDIR" "$@")
}

# kguardian_recipe: runs just kguardian in the copy with only ENVIRONMENT set, failing after a
# minute rather than hanging.
kguardian_recipe() {
  run timeout 60 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$REPO/justfile" --working-directory "$COPY" kguardian
}

# kguardian_start: starts just kguardian as kguardian_recipe runs it, in the background, with its
# output in $BATS_TEST_TMPDIR/out. Sets OUT and JUST_PID.
kguardian_start() {
  OUT="$BATS_TEST_TMPDIR/out"
  env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$REPO/justfile" --working-directory "$COPY" kguardian >"$OUT" 2>&1 3>&- &
  JUST_PID=$!
}

# printed TEXT: waits up to 20 seconds for TEXT in OUT.
printed() {
  local tick
  for ((tick = 0; tick < 200; tick++)); do
    if grep -qF -- "$1" "$OUT"; then return 0; fi
    sleep 0.1
  done
  echo "no '$1' after 20 seconds in:"
  cat "$OUT"
  return 1
}

# finished: waits up to 20 seconds for just, started by kguardian_start, to end, and sets STATUS to
# its exit status.
finished() {
  local tick
  for ((tick = 0; tick < 200; tick++)); do
    if ! kill -0 "$JUST_PID" 2>/dev/null; then
      STATUS=0
      wait "$JUST_PID" || STATUS=$?
      return 0
    fi
    sleep 0.1
  done
  echo "just kguardian still runs after 20 seconds"
  return 1
}

# kubectl_gone: fails while the last kubectl the fake recorded still runs.
kubectl_gone() {
  local kubectl_pid
  read -r kubectl_pid _ <"$STATE/pids"
  if kill -0 "$kubectl_pid" 2>/dev/null; then
    echo "kubectl $kubectl_pid still runs"
    return 1
  fi
}

@test "just kguardian forwards a local port to kguardian's interface and ends the forward on every way out" {
  local script_pid port
  recipe_copy
  # The local port is KGUARDIAN_PORT, or 5173: kubectl forwards it, on 127.0.0.1 only, to port 5173
  # of the Service kguardian-frontend in kguardian, through the cluster's kubeconfig. Ctrl-C ends
  # each: the terminal signals the recipe, while kubectl, run in the background, ignores it.
  for port in default 6173; do
    if [[ $port == default ]]; then port=5173; else with_env KGUARDIAN_PORT="$port"; fi
    rm -f "$RECORD/ended"
    kguardian_start
    printed "http://127.0.0.1:$port"
    cat "$OUT"
    # Only once kubectl reports the forward.
    [ -s "$STATE/pids" ]
    read -r _ script_pid <"$STATE/pids"
    kill -INT "$script_pid" "$JUST_PID"
    finished
    echo "after Ctrl-C: status $STATUS; $(cat "$OUT")"
    [ "$STATUS" -ne 0 ]
    kubectl_gone
    [ "$(cat "$RECORD/ended")" = SIGTERM ]
  done
  echo "kubectl ran: $(cat "$RECORD/argv")"
  [ "$(cat "$RECORD/argv")" = "$(printf '%s\n' \
    'port-forward --address 127.0.0.1 --namespace kguardian service/kguardian-frontend 5173:5173' \
    'port-forward --address 127.0.0.1 --namespace kguardian service/kguardian-frontend 6173:5173')" ]
  [ "$(sort -u "$RECORD/kubeconfig")" = "$KUBECONFIG_FILE" ]
  # It says that the interface has no sign-in, so that whoever reaches the local port reads the
  # record, and to read it with no other site open in the browser and end the forward once done, and
  # shows none of kubectl's own output.
  grep -qF 'no sign-in' "$OUT"
  grep -qF 'whoever reaches' "$OUT"
  grep -qxF 'Read it with no other site open in the browser, and end the forward once done.' "$OUT"
  if grep -qF 'Forwarding from' "$OUT"; then echo "kubectl's own output was printed"; return 1; fi

  # SIGTERM, which just passes on to the recipe.
  only_env
  rm "$RECORD/ended"
  kguardian_start
  printed "http://127.0.0.1:5173"
  kill -TERM "$JUST_PID"
  finished
  echo "after SIGTERM: status $STATUS"
  [ "$STATUS" -ne 0 ]
  kubectl_gone
  [ "$(cat "$RECORD/ended")" = SIGTERM ]

  # kubectl never reports the forward.
  rm "$RECORD/ended"
  echo silent >"$STATE/mode"
  with_env KGUARDIAN_WAIT=1
  kguardian_recipe
  echo "kubectl silent: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"did not report the forward within 1 seconds"* ]]
  [[ $output != *"http://"* ]]
  kubectl_gone
  [ "$(cat "$RECORD/ended")" = SIGTERM ]

  # kubectl stops before it forwards, with an error that names the API server's address.
  echo fail >"$STATE/mode"
  kguardian_recipe
  echo "kubectl failing: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"stopped with status 1 before it forwarded"* ]]
  [[ $output != *192.0.2.10* ]]
  kubectl_gone

  # kubectl stops while it forwards.
  echo drop >"$STATE/mode"
  kguardian_recipe
  echo "kubectl dropping: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"http://127.0.0.1:5173"* ]]
  [[ $output == *"stopped with status 1"* ]]
  [[ $output != *"lost connection"* ]]
  kubectl_gone
}

@test "just kguardian needs the cluster's kubeconfig and a port, and runs kubectl with none of the secrets" {
  local port wait name
  recipe_copy
  rm "$KUBECONFIG_FILE"
  with_env KGUARDIAN_PORT=65536 KGUARDIAN_WAIT=soon
  kguardian_recipe
  echo "status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/clusterconfig/kubeconfig does not exist; just cluster-kubeconfig fetches it"* ]]
  [[ $output == *"KGUARDIAN_PORT is not a port number"* ]]
  [[ $output == *"KGUARDIAN_WAIT is not a whole number of seconds"* ]]
  # With the kubeconfig in place, each bad port and each bad wait alone is refused.
  echo 'not a real kubeconfig' >"$KUBECONFIG_FILE"
  for port in 0 080 abc 5173x 65536; do
    only_env KGUARDIAN_PORT="$port"
    kguardian_recipe
    echo "KGUARDIAN_PORT='$port': status $status; $output"
    [ "$status" -ne 0 ]
    [[ $output == *"KGUARDIAN_PORT is not a port number"* ]]
  done
  for wait in 0 -1 1.5 10000; do
    only_env KGUARDIAN_WAIT="$wait"
    kguardian_recipe
    echo "KGUARDIAN_WAIT='$wait': status $status; $output"
    [ "$status" -ne 0 ]
    [[ $output == *"KGUARDIAN_WAIT is not a whole number of seconds"* ]]
  done
  # A second argument, or an option, is refused as well.
  run timeout 60 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" TMPDIR="$BATS_TEST_TMPDIR" "$COPY/scripts/kguardian" lab-sto2 extra
  [ "$status" -eq 2 ] && [[ $output == *"usage: kguardian [cluster]"* ]]
  run timeout 60 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" TMPDIR="$BATS_TEST_TMPDIR" "$COPY/scripts/kguardian" --help
  [ "$status" -eq 2 ] && [[ $output == *"usage: kguardian [cluster]"* ]]
  # None of these ran kubectl.
  [ ! -e "$RECORD/argv" ]

  # Every secret variable the recipes read, as a marker, besides the settings the recipe reads:
  # kubectl gets the kubeconfig and the settings, and none of the secrets.
  only_env
  names=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CLUSTER_S3_ACCESS_KEY_ID CLUSTER_S3_SECRET_ACCESS_KEY
    OS_CLOUD OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET TF_STATE_PASSPHRASE
    TF_ENCRYPTION SOPS_AGE_KEY SOPS_AGE_KEY_FILE FLUX_AGE_KEY FLUX_AGE_KEY_FILE OPERATOR_CIDRS)
  for name in "${names[@]}"; do with_env "$name=marker-$name"; done
  with_env KGUARDIAN_PORT=6173 KGUARDIAN_WAIT=5
  echo fail >"$STATE/mode"
  kguardian_recipe
  echo "status $status; $output"
  [ -s "$RECORD/names" ]
  grep -qx KUBECONFIG "$RECORD/names"
  grep -qx KGUARDIAN_PORT "$RECORD/names"
  grep -qx KGUARDIAN_WAIT "$RECORD/names"
  for name in "${names[@]}"; do
    echo "$name"
    if grep -qx "$name" "$RECORD/names"; then return 1; fi
  done
  # The two settings are named, with what each is when unset, where the recipes' variables are.
  grep -qE '^# KGUARDIAN_PORT=5173$' "$REPO/.env.example"
  grep -qE '^# KGUARDIAN_WAIT=20$' "$REPO/.env.example"
  grep -qF "\`KGUARDIAN_PORT\` and \`KGUARDIAN_WAIT\`" "$REPO/docs/cluster.md"
}

# A map the chart leaves empty takes keys of the user's choosing, and so does a security context map
# for the fields of Kubernetes' security context types (fixtures/security-context-fields). Keys of
# maps only: list items are the chart's input.
@test "every values key of kguardian is one its pinned chart defines" {
  local keys="$BATS_TEST_TMPDIR/keys" unknown="" key map open
  local paths='[.. | select(path | length > 0) | path | select(all_c(tag == "!!str")) | join(".")] | .[]'
  render
  mkdir -p "$keys"
  yq -N "$paths" "$VALUES" | sort -u >"$keys/ours"
  yq -N "$paths" "$DEFAULTS" | sort -u >"$keys/chart"
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

@test "kguardian's images are pinned by digest at the versions its pinned chart expects" {
  local component image repository tag busybox images comments
  render
  workloads
  # Each of the three images is the chart's own repository at the version the pinned chart's values
  # default to, written as the registry tags its releases, with a v, and held by its digest. The
  # chart renders the tag as written when it does not start with a number, so the tag stays in the
  # reference; its sha keys would drop it.
  for component in controller:"$OBSERVER" broker:"$BROKER" frontend:"$INTERFACE"; do
    image="$(yq '.image' "${component#*:}")"
    repository="$(yq ".${component%%:*}.image.repository" "$DEFAULTS")"
    tag="$(yq ".${component%%:*}.image.tag" "$DEFAULTS")"
    echo "${component%%:*}: $image, the chart expects $repository at $tag"
    [[ $tag =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
    [[ $image =~ ^([^:@]+):v([0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$ ]]
    [ "${BASH_REMATCH[1]}" = "$repository" ]
    [ "${BASH_REMATCH[2]}" = "$tag" ]
  done
  [ "$(yq '[.. | select(tag == "!!map" and has("sha"))] | length' "$VALUES")" -eq 0 ]
  # The two init containers run one busybox, from Docker Hub by its full name, at the tag the chart
  # defaults to and by its digest.
  busybox="$(yq '.spec.template.spec.initContainers[0].image' "$DAEMONSET")"
  echo "busybox: $busybox"
  [[ $busybox =~ ^docker\.io/library/busybox:([0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$ ]]
  [ "${BASH_REMATCH[1]}" = "$(yq '.controller.initContainer.image.tag' "$DEFAULTS")" ]
  [ "${BASH_REMATCH[1]}" = "$(yq '.broker.initContainer.image.tag' "$DEFAULTS")" ]
  [ "$(yq '.spec.template.spec.initContainers[0].image' "$BROKER_POD")" = "$busybox" ]
  # Those four are every image of the render.
  images="$(yq -N '.spec.template.spec | select(. != null) | (.containers + (.initContainers // []))[] | .image' "$RENDERED" | LC_ALL=C sort -u)"
  [ "$(wc -l <<<"$images")" -eq 4 ]
  [ -z "$(grep -vE '@sha256:[0-9a-f]{64}$' <<<"$images" || true)" ]
  # Renovate reads each pin under its comment: the chart's tag, and each image's tag and digest.
  [ "$(grep -B1 -E '^    tag: ' "$APP/app/ocirepository.yaml" | head -1)" = "    # renovate: datasource=docker depName=ghcr.io/kguardian-dev/charts/kguardian" ]
  [[ $(yq '.spec.ref.tag' "$APP/app/ocirepository.yaml") =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  comments="$(grep -B1 -E '^ +tag: ' "$APP/app/values.yaml" | grep -oE '# renovate: datasource=docker depName=[^ ]+$' | LC_ALL=C sort | uniq -c | sed -E 's/^ +//')"
  echo "$comments"
  [ "$comments" = "$(printf '%s\n' \
    '2 # renovate: datasource=docker depName=docker.io/library/busybox' \
    '1 # renovate: datasource=docker depName=ghcr.io/kguardian-dev/kguardian/broker' \
    '1 # renovate: datasource=docker depName=ghcr.io/kguardian-dev/kguardian/controller' \
    '1 # renovate: datasource=docker depName=ghcr.io/kguardian-dev/kguardian/frontend')" ]
  [ "$(grep -cE '^ +tag: ' "$APP/app/values.yaml")" -eq 5 ]
}
