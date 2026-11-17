#!/usr/bin/env bats
# Proves features/falco.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq and jq on PATH (the versions pinned for the repository). The Falco
# chart and, for the collector's configuration, the Vector chart are pulled once per run from their
# public registries; building and rendering are offline, with the placeholders of the cluster's
# example key lists.

# flux build rewrites the kustomization.yaml of what it builds and puts it back afterwards, and the
# charts are pulled once: so the tests run one at a time.
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
  APP="$REPO/kubernetes/apps/base/security-system/falco"
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

# built: the falco application as Flux applies it on lab-sto2: the overlay's Kustomization of it,
# with the example key lists and its own substitutions over them, strictly. Writes
# $BATS_TEST_TMPDIR/falco-built.yaml and sets BUILT and KS, the Kustomization as built.
built() {
  local path
  overlay
  KS="$BATS_TEST_TMPDIR/falco-ks.yaml"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars
    | select(fileIndex == 1 and .kind == "Kustomization" and .metadata.name == "falco")
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "$EXAMPLE" "$OVERLAY" >"$KS"
  [ -s "$KS" ] || { echo "the lab-sto2 overlay does not enable falco"; return 1; }
  path="$(yq '.spec.path' "$KS")"
  BUILT="$BATS_TEST_TMPDIR/falco-built.yaml"
  (cd "$REPO" && flux build kustomization falco --path "./kubernetes/${path#./}" \
    --kustomization-file "$KS" --dry-run --strict-substitute) >"$BUILT"
}

# render: renders the chart that the HelmRelease of falco installs, from the URL and tag of its
# OCIRepository, with the values helm-controller gives it: those of the ConfigMap the HelmRelease
# reads, then the HelmRelease's own over them, and its post-renderers over the result. Builds falco, writes $BATS_TEST_TMPDIR/falco.yaml and
# sets BUILT, RENDERED, VALUES, CHART and APP_VERSION, the chart's appVersion.
render() {
  local url tag name release namespace pulled post
  built
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
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
  APP_VERSION="$(helm show chart "$CHART" | yq '.appVersion')"
  RENDERED="$BATS_TEST_TMPDIR/falco.yaml"
  post="$BATS_TEST_TMPDIR/post-render"
  mkdir -p "$post"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" --values "$VALUES" >"$post/chart.yaml"
  # helm-controller then passes the manifests through the release's post-renderers; only kustomize
  # patches are known here, so any other kind fails instead of being skipped.
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.postRenderers // [] | map(select(has("kustomize") | not)) | length' "$BUILT")" -eq 0 ] ||
    { echo "the HelmRelease has a post-renderer that is not kustomize"; return 1; }
  yq -N 'select(.kind == "HelmRelease") | {"resources": ["chart.yaml"], "patches": (.spec.postRenderers // [] | map(.kustomize.patches // []) | flatten)}' "$BUILT" >"$post/kustomization.yaml"
  kustomize build "$post" >"$RENDERED"
}

# object FILE KIND NAME: the one object of that kind and name in FILE.
object() {
  KIND="$2" NAME="$3" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$1"
}

# daemonset: writes the DaemonSet falco of the render to $DAEMONSET and its container falco to
# $CONTAINER.
daemonset() {
  DAEMONSET="$BATS_TEST_TMPDIR/daemonset.yaml"
  CONTAINER="$BATS_TEST_TMPDIR/container.yaml"
  object "$RENDERED" DaemonSet falco >"$DAEMONSET"
  [ -s "$DAEMONSET" ] || { echo "the render has no DaemonSet falco"; return 1; }
  yq '.spec.template.spec.containers[] | select(.name == "falco")' "$DAEMONSET" >"$CONTAINER"
  [ -s "$CONTAINER" ] || { echo "the pod has no container falco"; return 1; }
}

# baseline_failures: what the Pod Security baseline level refuses in the pod the DaemonSet makes,
# by Kyverno's podSecurity rule as pod-security-check runs it: writes the failed controls, one per
# line, to $CONTROLS and the whole message to $FORBIDDEN.
baseline_failures() {
  local dir="$BATS_TEST_TMPDIR/baseline"
  mkdir -p "$dir"
  yq '{"apiVersion": "v1", "kind": "Pod",
    "metadata": {"name": "falco", "namespace": "security-system"} * (.spec.template.metadata | pick(["labels", "annotations"])),
    "spec": .spec.template.spec}' "$DAEMONSET" >"$dir/pod.yaml"
  cat >"$dir/policy.yaml" <<'POLICY'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: baseline
spec:
  validationFailureAction: Enforce
  rules:
    - name: baseline
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        podSecurity:
          level: baseline
          version: latest
POLICY
  # Exit 1 is a failed pod, which is the verdict; the report is the one line that starts with a brace.
  kyverno apply "$dir/policy.yaml" --resource "$dir/pod.yaml" -p --output-format json >"$dir/out" 2>"$dir/err" || [ $? -eq 1 ]
  grep '^{' "$dir/out" >"$dir/report.json"
  CONTROLS="$dir/controls"
  FORBIDDEN="$dir/forbidden"
  jq -r '.results[0].properties.controls // "" | split(",") | .[] | select(. != "")' "$dir/report.json" | LC_ALL=C sort >"$CONTROLS"
  jq -r '.results[0].message // ""' "$dir/report.json" >"$FORBIDDEN"
}

# falco_config: writes Falco's configuration file from the render's ConfigMap to $CONFIG.
falco_config() {
  CONFIG="$BATS_TEST_TMPDIR/falco-config.yaml"
  object "$RENDERED" ConfigMap falco | yq '.data["falco.yaml"]' >"$CONFIG"
  [ -s "$CONFIG" ] || { echo "the render has no configuration file"; return 1; }
}

# tree_without PATTERN...: a copy of the tree in $TREE whose overlay lists no resource that matches
# any PATTERN, an extended regular expression. Unlike the shared tree_without of
# tests/fixtures/tree-without.bash, which takes names, it matches a pattern against whole entries,
# so one pattern takes out a namespace directory and every ks.yaml under it.
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

# of_security_system FILE: what an overlay built into FILE holds of Falco and of its namespace,
# sorted, as kind, namespace and name: the namespace itself, any object in it, and any Kustomization
# that deploys into it or from the directory of Falco.
of_security_system() {
  yq -N 'select((.kind == "Namespace" and .metadata.name == "security-system") or .metadata.namespace == "security-system"
      or .spec.targetNamespace == "security-system" or ((.spec.path // "") | test("/apps/base/security-system/falco/")))
    | .kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$1" | LC_ALL=C sort | paste -sd, -
}

@test "Falco is selected by overlay entries and builds nothing when it is not" {
  # The overlay selects it with two entries, the namespace directory and the ks.yaml of Falco.
  [ "$(yq '.resources[] | select(test("/security-system(/|$)"))' "$OVERLAY_DIR/kustomization.yaml" | grep -c -x -e '../../base/security-system' -e '../../base/security-system/falco/ks.yaml')" -eq 2 ]
  overlay
  [ "$(of_security_system "$OVERLAY")" = ConfigMap/security-system/app-template-defaults,Kustomization/flux-system/falco,Namespace/-/security-system,NetworkPolicy/security-system/default-deny ]
  # It waits for the definitions of the monitors it makes and of its network policy, and is Ready
  # once its release is.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "falco") | .spec.dependsOn | map(.name) | join(" ")' "$OVERLAY")" = "prometheus-operator-crds cilium" ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "falco") | .spec.wait' "$OVERLAY")" = true ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # With only the namespace directory's entry, the cluster builds the namespace, its defaults and
  # its default deny, and nothing of Falco.
  tree_without '/security-system/falco/ks.yaml$'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ "$(of_security_system "$OVERLAY")" = ConfigMap/security-system/app-template-defaults,Namespace/-/security-system,NetworkPolicy/security-system/default-deny ]
  # With neither, nothing of security-system.
  tree_without '/security-system(/|$)'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ -z "$(of_security_system "$OVERLAY")" ]
  # Selecting it without the definitions of its monitors is refused, naming both.
  tree_without '/kube-system/prometheus-operator-crds/ks.yaml$'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "without prometheus-operator-crds: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"kubernetes/apps/base/security-system/falco/ks.yaml: Kustomization falco names prometheus-operator-crds"* ]]
  [[ $output == *"does not enable"* ]]
}

@test "Falco runs on every node with the modern eBPF probe and only the privileges it names" {
  local mounts ns reason cap path
  render
  daemonset
  falco_config
  # One pod on every node: a DaemonSet that tolerates every taint and picks no node.
  [ "$(yq '.spec.template.spec.tolerations | length' "$DAEMONSET")" -eq 1 ]
  [ "$(yq '.spec.template.spec.tolerations[0] | keys | join(" ")' "$DAEMONSET")" = operator ]
  [ "$(yq '.spec.template.spec.tolerations[0].operator' "$DAEMONSET")" = Exists ]
  [ "$(yq '.spec.template.spec.nodeSelector // "" | length' "$DAEMONSET")" -eq 0 ]
  [ "$(yq '.spec.template.spec.affinity // "" | length' "$DAEMONSET")" -eq 0 ]
  # The modern eBPF probe: no kernel module, and nothing in the pod that builds or loads a driver.
  [ "$(yq '.engine.kind' "$CONFIG")" = modern_ebpf ]
  [ "$(yq '.engine | has("kmod")' "$CONFIG")" = false ]
  [ "$(yq '.spec.template.spec.initContainers // [] | length' "$DAEMONSET")" -eq 0 ]
  [ "$(yq '.spec.template.spec.containers | map(.name) | join(" ")' "$DAEMONSET")" = falco ]
  [ "$(yq -o json '.args' "$CONTAINER" | jq -c .)" = '["/usr/bin/falco"]' ]
  # No privileged container, no host namespace of the node's, and exactly four capabilities added to
  # an empty set: BPF to load the probe's programs and maps, PERFMON to attach them to tracepoints
  # and open the perf events, SYS_RESOURCE to raise the memory lock limit the maps are counted
  # against, and SYS_PTRACE to read the processes' state under /proc.
  [ "$(yq '[.spec.template.spec.containers[].securityContext.privileged // false] | any' "$DAEMONSET")" = false ]
  [ "$(yq '.spec.template.spec | ((.hostNetwork // false) or (.hostPID // false) or (.hostIPC // false))' "$DAEMONSET")" = false ]
  [ "$(yq '.securityContext | keys | join(" ")' "$CONTAINER")" = "allowPrivilegeEscalation capabilities seccompProfile" ]
  [ "$(yq '.securityContext.allowPrivilegeEscalation' "$CONTAINER")" = false ]
  [ "$(yq '.securityContext.capabilities.drop | join(" ")' "$CONTAINER")" = ALL ]
  [ "$(yq '.securityContext.capabilities.add | sort | join(" ")' "$CONTAINER")" = "BPF PERFMON SYS_PTRACE SYS_RESOURCE" ]
  [ "$(yq '.securityContext.seccompProfile.type' "$CONTAINER")" = RuntimeDefault ]
  # The host paths it mounts: the node's /etc and /proc for the node's name, release and processes,
  # /sys/kernel for the kernel's BTF and tracing files, and the directory of the container
  # runtime's socket, which its container plugin asks for the pods' names, all read-only but the
  # last, which the chart mounts read-write. None of the directories a kernel module is built
  # from or loaded out of, /boot, /lib/modules, /usr and /dev, is mounted, and the pod declares no
  # host path volume that nothing mounts.
  mounts="$(yq -o json '.spec.template.spec.volumes // []' "$DAEMONSET" | jq -r --slurpfile c <(yq -o json '.volumeMounts' "$CONTAINER") '
    . as $volumes | $c[0][] | . as $m | first($volumes[] | select(.name == $m.name and .hostPath != null)) // empty
    | [$m.mountPath, .hostPath.path] + (if $m.readOnly then ["read-only"] else [] end) | join(" ")' | LC_ALL=C sort)"
  echo "$mounts"
  [ "$mounts" = "$(printf '%s\n' '/host/etc /etc read-only' '/host/proc /proc read-only' '/host/run/containerd /run/containerd' '/sys/kernel /sys/kernel read-only')" ]
  [ "$(yq '[.spec.template.spec.volumes[] | select(.hostPath != null) | .hostPath.path] | sort | join(" ")' "$DAEMONSET")" = "/etc /proc /run/containerd /sys/kernel" ]
  # Every mount of every container names a volume of the pod: the chart mounts /boot, /lib/modules
  # and /usr in Falco's container when driver.loader.enabled is false, and with those volumes
  # removed by the post-renderer such a pod is one the API server refuses.
  local orphans
  orphans="$(yq -o json '.spec.template.spec' "$DAEMONSET" | jq -r '[.volumes // [] | .[].name] as $volumes
    | (.containers + (.initContainers // []))[] | .name as $c | (.volumeMounts // [])[]
    | select(.name as $n | $volumes | index($n) | not) | "\($c): \(.mountPath) names no volume \(.name)"')"
  [ -z "$orphans" ] || { echo "$orphans"; return 1; }
  # The pod's own security context is empty and no annotation relaxes a profile: what the pod may do
  # is the container's security context above and nothing else.
  [ "$(yq '.spec.template.spec.securityContext // {} | length' "$DAEMONSET")" -eq 0 ]
  [ "$(yq '.spec.template.metadata.annotations // {} | keys | map(select(test("apparmor|seccomp|selinux"))) | length' "$DAEMONSET")" -eq 0 ]
  # The container plugin asks the runtime that Talos runs for the cluster's pods, and no other.
  [ "$(yq '.plugins[] | select(.name == "container") | .init_config.engines | to_entries | map(select(.value.enabled)) | map(.key) | join(" ")' "$CONFIG")" = cri ]
  [ "$(yq '.plugins[] | select(.name == "container") | .init_config.engines.cri.sockets | join(" ")' "$CONFIG")" = /run/containerd/containerd.sock ]
  # What it costs per node, from the chart's guidance.
  [ "$(yq '.resources.requests.cpu' "$CONTAINER")" = 100m ]
  [ "$(yq '.resources.requests.memory' "$CONTAINER")" = 512Mi ]
  [ "$(yq '.resources.limits.cpu' "$CONTAINER")" = 1000m ]
  [ "$(yq '.resources.limits.memory' "$CONTAINER")" = 1024Mi ]
  # The namespace, as the overlay builds it, enforces privileged, which host paths and added
  # capabilities need, and audits and warns at restricted at the cluster's minor.
  ns="$(object "$OVERLAY" Namespace security-system)"
  [ "$(yq '.metadata.labels["pod-security.kubernetes.io/enforce"]' <<<"$ns")" = privileged ]
  [ "$(yq '.metadata.labels["pod-security.kubernetes.io/audit"]' <<<"$ns")" = restricted ]
  [ "$(yq '.metadata.labels["pod-security.kubernetes.io/warn"]' <<<"$ns")" = restricted ]
  # The exceptions list holds the DaemonSet, at the level it needs.
  [ "$(yq '[.exceptions[] | select(.namespace == "security-system")] | map(.workload + " " + .level) | join(",")' "$REPO/pod-security-exceptions.yaml")" = "DaemonSet/falco privileged" ]
  # Its reason says what the baseline level refuses in the pod: the controls it fails, each
  # capability and host path of them, and says nothing of one it passes.
  reason="$(yq '.exceptions[] | select(.namespace == "security-system") | .reason' "$REPO/pod-security-exceptions.yaml")"
  baseline_failures
  echo "failed controls: $(paste -sd' ' "$CONTROLS")"
  [ "$(paste -sd' ' "$CONTROLS")" = "capabilities_baseline hostPathVolumes" ]
  for cap in $(yq '.securityContext.capabilities.add[]' "$CONTAINER"); do
    [[ $reason == *"$cap"* ]] || { echo "the reason does not name the capability $cap"; return 1; }
  done
  for path in $(yq '.spec.template.spec.volumes[] | select(.hostPath != null) | .hostPath.path' "$DAEMONSET"); do
    [[ $reason == *"$path"* ]] || { echo "the reason does not name the host path $path"; return 1; }
  done
  for path in /boot /lib/modules /usr /dev; do
    if [[ $reason =~ ${path}([^a-z/]|$) ]]; then echo "the reason names $path, which the pod does not mount"; return 1; fi
  done
  [[ $reason == *capabilit* && $reason == *"host path"* ]]
  [[ $reason != *[Aa]pp[Aa]rmor* ]]
  # The runtime's socket directory is the one mount that is not read-only, and the reason says so.
  [[ $reason == *"/run/containerd"*"read-write"* ]]
  [[ $reason != *"reads "* ]]
}

@test "Falco fetches no rule, plugin or driver at run time that the tree did not pin" {
  local image
  render
  daemonset
  falco_config
  # falcoctl, the tool that downloads rules and plugins when the pod starts and on a schedule after,
  # neither installs nor follows, and is in no container, no ConfigMap and no value.
  [ "$(yq '.falcoctl.artifact.install.enabled' "$VALUES")" = false ]
  [ "$(yq '.falcoctl.artifact.follow.enabled' "$VALUES")" = false ]
  [ "$(grep -ci falcoctl "$RENDERED" || true)" -eq 0 ]
  [ "$(yq '.spec.template.spec.containers | map(.name) | join(" ")' "$DAEMONSET")" = falco ]
  [ "$(yq '.spec.template.spec.initContainers // [] | length' "$DAEMONSET")" -eq 0 ]
  # What the chart renders is Falco's own objects: no Falcosidekick, no Talon, no metadata
  # collector, no exporter, which are the objects of the charts it can bring in.
  [ "$(yq -N '.kind' "$RENDERED" | LC_ALL=C sort | paste -sd' ' -)" = "ConfigMap DaemonSet Service ServiceAccount ServiceMonitor" ]
  # The rules and the container plugin are the image's: the three rules files are the image's two
  # and the directory for local rules, the one plugin is a library of the image, and nothing is
  # sent to an address or run as a program.
  [ "$(yq '.rules_files | join(" ")' "$CONFIG")" = "/etc/falco/falco_rules.yaml /etc/falco/falco_rules.local.yaml /etc/falco/rules.d" ]
  [ "$(yq '.load_plugins | join(" ")' "$CONFIG")" = container ]
  [ "$(yq '.plugins | length' "$CONFIG")" -eq 1 ]
  [ "$(yq '.plugins[0].library_path' "$CONFIG")" = libcontainer.so ]
  [ "$(yq '.http_output.enabled // false' "$CONFIG")" = false ]
  [ "$(yq '.program_output.enabled // false' "$CONFIG")" = false ]
  [ "$(yq '.file_output.enabled // false' "$CONFIG")" = false ]
  [ "$(yq '.grpc_output.enabled // false' "$CONFIG")" = false ]
  [ "$(yq '.falcosidekick // "" | length' "$CONFIG")" -eq 0 ]
  # Nothing in the pod mounts a volume the rules or plugins could arrive in.
  [ "$(yq '[.spec.template.spec.volumes[] | select(.name == "rulesfiles-install-dir" or .name == "plugins-install-dir" or .name == "artifact-state-dir")] | length' "$DAEMONSET")" -eq 0 ]
  # The image is named by its version and its digest, the version is the chart's, and Renovate reads
  # the pin under its comment.
  image="$(yq '.image' "$CONTAINER")"
  echo "$image"
  [[ $image =~ ^docker\.io/falcosecurity/falco:([0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$ ]]
  [ "${BASH_REMATCH[1]}" = "$APP_VERSION" ]
  [ "$(grep -B1 -E '^  tag: ' "$APP/app/values.yaml" | head -1)" = "  # renovate: datasource=docker depName=docker.io/falcosecurity/falco" ]
  [ "$(grep -B1 -E '^    tag: ' "$APP/app/ocirepository.yaml" | head -1)" = "    # renovate: datasource=docker depName=ghcr.io/falcosecurity/charts/falco" ]
}

@test "Falco's events are JSON lines on standard output that the log collector ships" {
  local out="$BATS_TEST_TMPDIR/collector"
  render
  daemonset
  falco_config
  # One JSON line for each event, with its rule, priority, output and fields, on standard output
  # and nowhere else, written as it happens.
  [ "$(yq '.json_output' "$CONFIG")" = true ]
  [ "$(yq '.json_include_output_property' "$CONFIG")" = true ]
  [ "$(yq '.json_include_output_fields_property' "$CONFIG")" = true ]
  [ "$(yq '.json_include_tags_property' "$CONFIG")" = true ]
  [ "$(yq '.stdout_output.enabled' "$CONFIG")" = true ]
  [ "$(yq '.syslog_output.enabled' "$CONFIG")" = false ]
  [ "$(yq '.file_output.enabled' "$CONFIG")" = false ]
  [ "$(yq '.http_output.enabled' "$CONFIG")" = false ]
  [ "$(yq '.program_output.enabled' "$CONFIG")" = false ]
  [ "$(yq '.buffered_outputs' "$CONFIG")" = false ]
  # The collector reads every pod's lines whatever its namespace, keeps each whole and sends it to the
  # store, and the pod of Falco is not one it leaves out.
  mkdir -p "$out"
  "$REPO/scripts/vector-config" "$out"
  [ "$(yq '.sources.pods.type' "$out/vector.yaml")" = kubernetes_logs ]
  [ "$(yq '.sources.pods | keys | join(" ")' "$out/vector.yaml")" = type ]
  [ "$(yq '.transforms.pod_fields.inputs | join(" ")' "$out/vector.yaml")" = pods ]
  [ "$(yq '.transforms.pod_fields.source' "$out/vector.yaml" | grep -cE '\.message|abort|drop' || true)" -eq 0 ]
  [ "$(yq '.sinks.victoria_logs.inputs | join(" ")' "$out/vector.yaml")" = "pod_fields drop_auditd_log" ]
  [ "$(yq '.sinks.victoria_logs.query._msg_field' "$out/vector.yaml")" = message ]
  [ "$(yq '.spec.template.metadata.labels | has("vector.dev/exclude")' "$DAEMONSET")" = false ]
  # The docs say how the events are found.
  grep -q 'kubernetes.pod_namespace:security-system kubernetes.container_name:falco' "$REPO/docs/kubernetes.md"
}

@test "Falco's own metrics are scraped by a monitor of the render" {
  local service monitor
  render
  daemonset
  falco_config
  # Falco serves them itself, on its web server's port, and counts the matches of each rule.
  [ "$(yq '.metrics.enabled' "$CONFIG")" = true ]
  [ "$(yq '.metrics.rules_counters_enabled' "$CONFIG")" = true ]
  [ "$(yq '.webserver.enabled' "$CONFIG")" = true ]
  [ "$(yq '.webserver.prometheus_metrics_enabled' "$CONFIG")" = true ]
  [ "$(yq '.webserver.ssl_enabled' "$CONFIG")" = false ]
  [ "$(yq '.webserver.listen_port' "$CONFIG")" -eq 8765 ]
  [ "$(yq '.spec.template.spec.containers[0].ports[] | select(.name == "web") | .containerPort' "$DAEMONSET")" -eq 8765 ]
  # A Service exposes the port, and a ServiceMonitor selects that Service by its labels, scrapes it
  # over plain HTTP at /metrics and labels each series with the node of the pod.
  service="$BATS_TEST_TMPDIR/service.yaml"
  monitor="$BATS_TEST_TMPDIR/monitor.yaml"
  object "$RENDERED" Service falco-metrics >"$service"
  object "$RENDERED" ServiceMonitor falco >"$monitor"
  [ -s "$service" ] && [ -s "$monitor" ]
  [ "$(yq '.spec.ports | map(.name + ":" + (.port | tostring) + ":" + (.targetPort | tostring)) | join(" ")' "$service")" = metrics:8765:8765 ]
  [ "$(yq '.spec.type' "$service")" = ClusterIP ]
  [ "$(yq '.spec.endpoints[0].port' "$monitor")" = metrics ]
  [ "$(yq '.spec.endpoints[0].path' "$monitor")" = /metrics ]
  [ "$(yq '.spec.endpoints[0].scheme' "$monitor")" = http ]
  [ "$(yq '.spec.namespaceSelector.matchNames | join(" ")' "$monitor")" = security-system ]
  [ "$(yq -o json '.spec.selector.matchLabels' "$monitor" | jq -c .)" = "$(yq -o json '{"app.kubernetes.io/instance": .metadata.labels["app.kubernetes.io/instance"], "app.kubernetes.io/name": .metadata.labels["app.kubernetes.io/name"], "type": .metadata.labels.type}' "$service" | jq -c .)" ]
  [ "$(yq -o json '.spec.endpoints[0].relabelings' "$monitor" | jq -c .)" = '[{"sourceLabels":["__meta_kubernetes_pod_node_name"],"targetLabel":"node"}]' ]
  # The Service selects the pods of the DaemonSet.
  [ "$(yq -o json '.spec.selector' "$service" | jq -c .)" = "$(yq -o json '.spec.selector.matchLabels' "$DAEMONSET" | jq -c .)" ]
  # The separate exporter, which reads Falco's gRPC output, is not installed: no application of it
  # and no gRPC output.
  [ -z "$(find "$REPO/kubernetes/apps" -type d -name 'falco-exporter*')" ]
  [ "$(yq '.grpc_output.enabled // false' "$CONFIG")" = false ]
  [ "$(yq '.grpc.enabled // false' "$CONFIG")" = false ]
}

@test "Falco's local rules have one place, which holds only what is true today" {
  render
  # One key of the values, customRules, a map of rule files by name that the chart mounts as the
  # directory its configuration lists after the image's rules; here it is empty, so the chart makes
  # no ConfigMap of local rules and the pod mounts none.
  [ "$(yq 'has("customRules")' "$VALUES")" = true ]
  [ "$(yq '.customRules | type' "$VALUES")" = '!!map' ]
  [ "$(yq '.customRules | length' "$VALUES")" -eq 0 ]
  [ -z "$(object "$RENDERED" ConfigMap falco-rules)" ]
  [ "$(yq '.spec.template.spec.containers[0].volumeMounts | map(select(.mountPath == "/etc/falco/rules.d")) | length' <(object "$RENDERED" DaemonSet falco))" -eq 0 ]
  # The docs say where the key is and what an exception looks like.
  grep -q 'customRules' "$REPO/docs/kubernetes.md"
}

# A map the chart leaves empty, such as customRules, takes keys of the user's choosing, and so does
# a security context map for the fields of Kubernetes' security context types
# (fixtures/security-context-fields). Keys of maps only: list items are the chart's input.
@test "every values key of falco is one its pinned chart defines" {
  local keys="$BATS_TEST_TMPDIR/keys" unknown="" key map open
  local paths='[.. | select(path | length > 0) | path | select(all_c(tag == "!!str")) | join(".")] | .[]'
  render
  mkdir -p "$keys"
  yq -N "$paths" "$VALUES" | sort -u >"$keys/ours"
  helm show values "$CHART" >"$keys/defaults"
  yq -N "$paths" "$keys/defaults" | sort -u >"$keys/chart"
  open="$(yq -N '[.. | select(tag == "!!map" and length == 0) | path | join(".")] | .[]' "$keys/defaults")"
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
