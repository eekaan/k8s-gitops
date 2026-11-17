#!/usr/bin/env bats
# Proves features/falco.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq and jq on PATH (the versions pinned for the repository). The Falco
# chart and, for the collector's configuration, the Vector chart are pulled once per run from their
# public registries; building and rendering are offline, with the placeholders of the cluster's
# example key lists.
#
# Three tests also run the image the render names, with docker: the proofs of two scenarios, which
# run Falco itself, and the search of the image's files for what would read a service account
# token. Each skips, saying why, where no docker daemon answers, as in the CI containers; with one,
# a pull or a run that fails is a failure. The containers have no network, no capability and a
# read-only root, run as a user that is not root, load no probe and leave nothing behind.

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

# build TREE NAME: the application NAME as Flux applies it on lab-sto2 from TREE, the repository or a
# copy of it: the overlay's Kustomization of it, with the example key lists and its own
# substitutions over them, strictly. Writes $BATS_TEST_TMPDIR/NAME-built.yaml and sets BUILD and
# BUILD_KS, the Kustomization as built.
build() {
  local tree="$1" name="$2" path
  overlay "$tree/kubernetes/apps/overlays/lab-sto2"
  BUILD_KS="$BATS_TEST_TMPDIR/$name-ks.yaml"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  NAME="$name" yq ea 'select(fileIndex == 0) as $vars
    | select(fileIndex == 1 and .kind == "Kustomization" and .metadata.name == strenv(NAME))
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "$EXAMPLE" "$OVERLAY" >"$BUILD_KS"
  [ -s "$BUILD_KS" ] || { echo "the lab-sto2 overlay does not enable $name"; return 1; }
  path="$(yq '.spec.path' "$BUILD_KS")"
  BUILD="$BATS_TEST_TMPDIR/$name-built.yaml"
  (cd "$tree" && flux build kustomization "$name" --path "./kubernetes/${path#./}" \
    --kustomization-file "$BUILD_KS" --dry-run --strict-substitute) >"$BUILD"
}

# built: the falco application as Flux applies it on lab-sto2. Writes
# $BATS_TEST_TMPDIR/falco-built.yaml and sets BUILT.
built() {
  build "$REPO" falco
  BUILT="$BUILD"
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

# local_rules: writes the files of the render's ConfigMap falco-rules, the local rules, to the
# directory $RULES_D, laid out as the kubelet lays out a ConfigMap volume: each file's name a link
# into ..data, itself a link to the directory that holds the files. Sets EXCEPTIONS, the one file
# the tree holds.
local_rules() {
  local rules="$BATS_TEST_TMPDIR/falco-rules.yaml" held=..2026_01_01_00_00_00.0000000001 name
  object "$RENDERED" ConfigMap falco-rules >"$rules"
  [ -s "$rules" ] || { echo "the render has no ConfigMap falco-rules"; return 1; }
  RULES_D="$BATS_TEST_TMPDIR/rules.d"
  rm -rf "$RULES_D"
  mkdir -p "$RULES_D/$held"
  ln -s "$held" "$RULES_D/..data"
  while read -r name; do
    NAME="$name" yq '.data[strenv(NAME)]' "$rules" >"$RULES_D/$held/$name"
    ln -s "..data/$name" "$RULES_D/$name"
  done < <(yq '.data | keys | .[]' "$rules")
  EXCEPTIONS="$RULES_D/exceptions.yaml"
  [ -s "$EXCEPTIONS" ] || { echo "the local rules hold no file exceptions.yaml"; return 1; }
}

# repository IMAGE: IMAGE without its digest and its tag.
repository() {
  local name="${1%%@*}"
  if [[ ${name##*/} == *:* ]]; then name="${name%:*}"; fi
  printf '%s' "$name"
}

# normalized IMAGE: the repository of IMAGE as the runtime reports it, its short forms written out:
# a name without a registry is on docker.io, and one there without a namespace is in library.
normalized() {
  local name first
  name="$(repository "$1")"
  first="${name%%/*}"
  if [[ $name != */* || ($first != *.* && $first != *:* && $first != localhost) ]]; then name="docker.io/$name"; fi
  if [[ $name == docker.io/* && ${name#docker.io/} != */* ]]; then name="docker.io/library/${name#docker.io/}"; fi
  printf '%s' "$name"
}

# workload TREE: the hello application, the demo's web server, as Flux applies it on lab-sto2 from
# TREE. Sets W_NAMESPACE, the namespace its Kustomization targets, W_DEPLOYMENT, its Deployment's
# name, W_CONTAINER, the name of its one container, W_REPOSITORY, that container's image without
# tag or digest, W_TAG, the image's tag, W_PROCESS, the first word of its command, and
# W_DIRECTORY, where it mounts its pages. Fails when an exception cannot name the Deployment: none
# or several, more than one container, no command, or an image written otherwise than the runtime
# reports it, which is the form Falco compares: its registry first and, on docker.io, its
# namespace.
workload() {
  local deployment="$BATS_TEST_TMPDIR/hello-deployment.yaml" image registry command
  build "$1" hello || return 1
  [ "$(yq -N 'select(.kind == "Deployment") | .metadata.name' "$BUILD" | grep -c .)" -eq 1 ] ||
    { echo "hello does not build one Deployment"; return 1; }
  yq -N 'select(.kind == "Deployment")' "$BUILD" >"$deployment"
  [ "$(yq '.spec.template.spec.containers | length' "$deployment")" -eq 1 ] ||
    { echo "hello's pod has more than one container"; return 1; }
  W_NAMESPACE="$(yq '.spec.targetNamespace' "$BUILD_KS")"
  [ "$(yq '.metadata.namespace' "$deployment")" = "$W_NAMESPACE" ] ||
    { echo "hello's Deployment is not in the namespace its Kustomization targets"; return 1; }
  W_DEPLOYMENT="$(yq '.metadata.name' "$deployment")"
  W_CONTAINER="$(yq '.spec.template.spec.containers[0].name' "$deployment")"
  image="$(yq '.spec.template.spec.containers[0].image' "$deployment")"
  W_REPOSITORY="$(repository "$image")"
  W_TAG="${image%%@*}"
  W_TAG="${W_TAG#"$W_REPOSITORY"}"
  W_TAG="${W_TAG#:}"
  registry="${W_REPOSITORY%%/*}"
  if [[ $W_REPOSITORY != */* || $registry != *.* || ($registry == docker.io && $W_REPOSITORY != */*/*) ]]; then
    echo "hello's image $image is not written as the runtime reports it: its registry first and, on docker.io, its namespace"
    return 1
  fi
  command="$(yq '.spec.template.spec.containers[0].command[0] // ""' "$deployment")"
  [ -n "$command" ] || { echo "hello's container has no command to take its process from"; return 1; }
  W_PROCESS="${command##*/}"
  W_DIRECTORY="$(yq '.spec.template.spec.containers[0].volumeMounts[0].mountPath' "$deployment")"
}

# exception_for: the condition that excepts the workload the last call of workload read, and
# nothing else: its namespace, container, image repository and process, each compared for equality,
# joined by and, in parentheses.
exception_for() {
  printf '(k8s.ns.name = "%s" and container.name = "%s" and container.image.repository = "%s" and proc.name = "%s")' \
    "$W_NAMESPACE" "$W_CONTAINER" "$W_REPOSITORY" "$W_PROCESS"
}

# excepts TREE: succeeds when $CONDITION, the condition of the rendered exception, is exactly the
# one that names the hello of TREE; otherwise says what each names and fails.
excepts() {
  workload "$1" || return 1
  [ "$CONDITION" = "$(exception_for)" ] || {
    echo "the exception does not name hello and hello alone: its condition is $CONDITION, and hello is $(exception_for)"
    return 1
  }
}

# docker_or_skip: skips the test, saying why, where no docker daemon answers. Past it, whatever
# docker fails at fails the test, a pull of the image included.
docker_or_skip() {
  type -P docker >/dev/null || skip "no docker daemon answers: docker is not on PATH"
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1 ||
    skip "no docker daemon answers: docker version reaches none"
}

# The pod's mounts under /etc/falco: an empty directory over config.d, which hides the image's own
# snippets there, the render's falco.yaml, and the local rules at rules.d. Everything else Falco
# reads there is the image's.
ETC_FALCO_LAYOUT="$(printf '%s\n' '/etc/falco/config.d emptyDir' '/etc/falco/falco.yaml configMap/falco:falco.yaml' '/etc/falco/rules.d configMap/falco-rules')"

# etc_falco_layout: what the container falco of $DAEMONSET mounts under /etc/falco, one mount a
# line, sorted, as its path and its volume's kind, with the ConfigMap's name and key for one.
etc_falco_layout() {
  yq -o json '.spec.template.spec' "$DAEMONSET" | jq -r '
    (.volumes // [] | map({key: .name, value: .}) | from_entries) as $volumes
    | .containers[] | select(.name == "falco") | .volumeMounts[] | select(.mountPath | startswith("/etc/falco"))
    | $volumes[.name] as $volume
    | .mountPath + " " + (if $volume.emptyDir then "emptyDir"
        elif $volume.configMap then "configMap/" + $volume.configMap.name + (if .subPath then ":" + .subPath else "" end)
        else "other" end)' | LC_ALL=C sort
}

# falco_image ARG...: runs ARG... in the image the render names, which docker takes by its digest,
# with what the pod mounts under /etc/falco, which it reads from the render first: an empty
# directory over config.d, the render's falco.yaml, and the local rules of $RULES_D, or of
# $FALCO_RULES_D when it is set, at rules.d. The container has no network and no capability, a
# read-only root and a user that is not root, so it can load no probe and read no event of the
# machine. docker runs with none of the secrets the environment may hold, as the recipes run it
# (scripts/lib/tools.sh).
falco_image() {
  local image layout
  image="$(yq '.image' "$CONTAINER")"
  # On standard error, which the callers print when the run fails, as its output goes to a file.
  [[ $image == *@sha256:* ]] || { echo "the render names the image $image without a digest" >&2; return 1; }
  layout="$(etc_falco_layout)"
  [ "$layout" = "$ETC_FALCO_LAYOUT" ] ||
    { echo "the pod mounts under /etc/falco otherwise than the run does: $layout" >&2; return 1; }
  (
    # shellcheck source=scripts/lib/tools.sh
    . "$REPO/scripts/lib/tools.sh"
    docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges \
      --user 65534:65534 --read-only --tmpfs /etc/falco/config.d:ro \
      --volume "$CONFIG:/etc/falco/falco.yaml:ro" \
      --volume "${FALCO_RULES_D:-$RULES_D}:/etc/falco/rules.d:ro" \
      "$image" "$@"
  )
}

# runtime_detection_docs: sets DOCS to the text of the docs' section Runtime detection, each line
# break and run of spaces one space, so a sentence is found whole wherever its lines break.
runtime_detection_docs() {
  DOCS="$(sed -n '/^## Runtime detection$/,/^## /p' "$REPO/docs/kubernetes.md" | sed '$d' | tr '\n' ' ' | tr -s ' ')"
  [ -n "$DOCS" ] || { echo "the docs have no section Runtime detection"; return 1; }
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
  # What the chart renders is Falco's own objects, its configuration and the tree's local rules a
  # ConfigMap each: no Falcosidekick, no Talon, no metadata collector, no exporter, which are the
  # objects of the charts it can bring in.
  [ "$(yq -N '.kind' "$RENDERED" | LC_ALL=C sort | paste -sd' ' -)" = "ConfigMap ConfigMap DaemonSet Service ServiceAccount ServiceMonitor" ]
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
  local item mounts reason layout
  render
  daemonset
  falco_config
  # One key of the values, customRules, a map of rule files by name: it holds one file.
  [ "$(yq '.customRules | type' "$VALUES")" = '!!map' ]
  [ "$(yq '.customRules | keys | join(" ")' "$VALUES")" = exceptions.yaml ]
  # The file is one item, which replaces the condition of one macro of the image's rules: no rule
  # of the tree's own, no list, nothing appended to a rule and no rule turned off.
  local_rules
  [ "$(yq 'type' "$EXCEPTIONS")" = '!!seq' ]
  [ "$(yq 'length' "$EXCEPTIONS")" -eq 1 ]
  item="$(yq -o json '.[0]' "$EXCEPTIONS")"
  [ "$(jq -r 'keys | join(" ")' <<<"$item")" = "condition macro override" ]
  [ "$(jq -r '.macro' <<<"$item")" = user_known_stand_streams_redirect_activities ]
  [ "$(jq -c '.override' <<<"$item")" = '{"condition":"replace"}' ]
  # Its reason is a comment above it, and nothing but comments stands above it. It says what httpd
  # does that the rule matches, and that a shell in that container still matches.
  [ "$(sed '/^- /,$d' "$EXCEPTIONS" | grep -c '^# Reason: ')" -eq 1 ]
  [ "$(sed '/^- /,$d' "$EXCEPTIONS" | grep -vc '^#' || true)" -eq 0 ]
  reason="$(sed '/^- /,$d; s/^# *//' "$EXCEPTIONS" | tr '\n' ' ')"
  [[ $reason == *httpd*dup2* && $reason == *"a shell"*"in that container still matches"* ]]
  # The chart makes the ConfigMap falco-rules of the key, holding that file as the values hold it.
  [ "$(object "$RENDERED" ConfigMap falco-rules | yq '.data | keys | join(" ")')" = exceptions.yaml ]
  [ "$(object "$RENDERED" ConfigMap falco-rules | yq '.data["exceptions.yaml"]')" = "$(yq '.customRules["exceptions.yaml"]' "$VALUES")" ]
  # The pod mounts that ConfigMap whole at the directory the configuration lists after the image's
  # rules, so the file is read last and overrides them.
  mounts="$(yq -o json '.spec.template.spec' "$DAEMONSET" | jq -r '
    [.volumes[] | select(.configMap.name == "falco-rules") | .name] as $volumes
    | .containers[] | .volumeMounts[] | select(.name as $name | $volumes | index($name))
    | .mountPath + " " + (.subPath // "whole")')"
  echo "$mounts"
  [ "$mounts" = "/etc/falco/rules.d whole" ]
  [ "$(yq '.rules_files | join(" ")' "$CONFIG")" = "/etc/falco/falco_rules.yaml /etc/falco/falco_rules.local.yaml /etc/falco/rules.d" ]
  # There is no second place. Under /etc/falco the pod mounts its configuration file, an empty
  # config.d and that directory, and nothing over the image's rules; and config.d, empty, is the one
  # place Falco reads further configuration from, where a file could turn a rule off.
  layout="$(etc_falco_layout)"
  [ "$layout" = "$ETC_FALCO_LAYOUT" ] || { echo "the pod mounts under /etc/falco: $layout"; return 1; }
  [ "$(yq -o json -I0 '.config_files' "$CONFIG")" = '["/etc/falco/config.d"]' ]
  # Falco watches the rules files it loaded, so a pod that runs loads a changed file once the
  # kubelet brings it to that mount, which a mount of one file by its path would never show.
  [ "$(yq '.watch_config_files' "$CONFIG")" = true ]
  # The docs say where the key is and show the item as the values hold it.
  runtime_detection_docs
  [[ $DOCS == *customRules* ]]
  [[ $DOCS == *"$(jq -r '.condition' <<<"$item")"* ]]
}

@test "The redirect rule excepts the demo's web server by namespace, container, image and process, and nothing wider" {
  local hello other app owner image named=""
  render
  local_rules
  CONDITION="$(yq '.[0].condition' "$EXCEPTIONS")"
  echo "$CONDITION"
  # The condition is, to the letter, the one made of the hello that Flux applies: the namespace its
  # Kustomization targets, the name of its one container, its image without tag or digest and the
  # first word of its command, each compared for equality, joined by and, in parentheses. So it
  # holds no or, no not and no other field or operator, and names what runs.
  excepts "$REPO"
  # A hello whose container has another name, whose image has moved or which runs another command
  # is no longer what the exception names, which then names nothing that runs: the comparison
  # fails, saying what hello is now.
  hello=kubernetes/apps/base/demo/hello/app/deployment.yaml
  tree_without
  yq -i '.spec.template.spec.containers[0].name = "web"' "$TREE/$hello"
  run excepts "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"the exception does not name hello and hello alone"*'and hello is '*'container.name = "web"'* ]]
  tree_without
  yq -i '.spec.template.spec.containers[0].image = "registry.example.com/library/busybox:1.38.0"' "$TREE/$hello"
  run excepts "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"the exception does not name hello and hello alone"*'and hello is '*'container.image.repository = "registry.example.com/library/busybox"'* ]]
  tree_without
  yq -i '.spec.template.spec.containers[0].command[0] = "/bin/busybox"' "$TREE/$hello"
  run excepts "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"the exception does not name hello and hello alone"*'and hello is '*'proc.name = "busybox"'* ]]
  # Why the container's name is one of the four: volsync-demo runs the same image in the same
  # namespace, under another container's name, which the condition does not except.
  other=kubernetes/apps/base/demo/volsync-demo
  [ "$(yq '.spec.targetNamespace' "$REPO/$other/ks.yaml")" = "$W_NAMESPACE" ]
  [ "$(repository "$(yq '.spec.template.spec.containers[0].image' "$REPO/$other/app/deployment.yaml")")" = "$W_REPOSITORY" ]
  [ "$(yq '.spec.template.spec.containers[0].name' "$REPO/$other/app/deployment.yaml")" != "$W_CONTAINER" ]
  # Nor does any other container there have hello's name and image, so no httpd but hello's is
  # excepted: of every container and init container of every workload the overlay builds into the
  # namespace, only hello's has both.
  overlay
  for app in $(NS="$W_NAMESPACE" yq -N 'select(.kind == "Kustomization" and .spec.targetNamespace == strenv(NS)) | .metadata.name' "$OVERLAY"); do
    build "$REPO" "$app"
    while read -r owner image; do
      [ "$(normalized "$image")" != "$W_REPOSITORY" ] || named+=" $app:$owner"
    done < <(yq -o json -I0 '.' "$BUILD" | CONTAINER_NAME="$W_CONTAINER" jq -r '. as $object
      | (.spec.template.spec // .spec.jobTemplate.spec.template.spec // (if .kind == "Pod" then .spec else null end)) // empty
      | (.containers // []) + (.initContainers // []) | .[] | select(.name == env.CONTAINER_NAME)
      | "\($object.kind)/\($object.metadata.name)/\(.name) \(.image)"')
  done
  echo "containers $W_CONTAINER of $W_REPOSITORY in $W_NAMESPACE:$named"
  [ "$named" = " hello:Deployment/$W_DEPLOYMENT/$W_CONTAINER" ]
  # Why the rule matches hello at all is read from the source of the version it runs, which the
  # docs name: another version's httpd is read again before the exception is taken to hold for it.
  runtime_detection_docs
  [ -n "$W_TAG" ]
  [[ $DOCS == *"busybox $W_TAG, the version \`hello\` runs"* ]] || {
    echo "hello runs busybox $W_TAG, and the docs give the reason from another version's httpd: read networking/httpd.c of busybox $W_TAG for how its server puts a connection on its standard streams, then make Tuning in docs/kubernetes.md and the exception's reason say what it does"
    return 1
  }
}

@test "Falco loads the local rules at the pinned version and compiles the redirect rule with the one exception under a single negation" {
  local out="$BATS_TEST_TMPDIR/falco" rule="Redirect STDOUT/STDIN to Network Connection in Container"
  local file loaded=() validate=() conjunction compiled plain negates
  render
  daemonset
  falco_config
  local_rules
  workload "$REPO"
  docker_or_skip
  mkdir -p "$out/no-rules"
  # A dry run on what the pod holds exits 0. A condition with a field Falco does not know makes it
  # exit 1 here, which on a node is a pod that crash-loops.
  falco_image falco --dry-run >"$out/dry-run.out" 2>"$out/dry-run.err" || { cat "$out/dry-run.err"; return 1; }
  # It loads the image's rules and then the local file, each once, in this order.
  mapfile -t loaded < <(sed -n '/Loading rules from:/,$ s/^.*: *\(\/[^ ]*\) | schema validation: .*$/\1/p' "$out/dry-run.err")
  printf 'loaded: %s\n' "${loaded[@]}"
  [ "${loaded[*]}" = "/etc/falco/falco_rules.yaml /etc/falco/falco_rules.local.yaml /etc/falco/rules.d/exceptions.yaml" ]
  # Validated in that order, every file loads without an error and without a warning. An override
  # of a macro the image does not define loads with the warning LOAD_UNUSED_MACRO and exit 0: an
  # exception that silently excepts nothing.
  for file in "${loaded[@]}"; do validate+=(-V "$file"); done
  falco_image falco "${validate[@]}" >"$out/validate.json" 2>"$out/validate.err" || { cat "$out/validate.err"; return 1; }
  jq -c '.falco_load_results[] | {name, successful, errors: [.errors[].code], warnings: [.warnings[].code]}' "$out/validate.json"
  [ "$(jq -r '[.falco_load_results[].name] | join(" ")' "$out/validate.json")" = "${loaded[*]}" ]
  [ "$(jq -c '[.falco_load_results[] | select(.successful != true or .errors != [] or .warnings != []) | .name]' "$out/validate.json")" = '[]' ]
  # The rule is enabled, at priority Notice, and compiles to the image's condition with one
  # negation, of the conjunction of hello's four values, which Falco prints without quotes.
  falco_image falco -l "$rule" >"$out/rule.json" 2>"$out/rule.err" || { cat "$out/rule.err"; return 1; }
  [ "$(jq -r '.rules | map(.info.name) | join(",")' "$out/rule.json")" = "$rule" ]
  [ "$(jq -r '.rules[0].info.enabled' "$out/rule.json")" = true ]
  [ "$(jq -r '.rules[0].info.priority' "$out/rule.json")" = Notice ]
  conjunction="(k8s.ns.name = $W_NAMESPACE and container.name = $W_CONTAINER and container.image.repository = $W_REPOSITORY and proc.name = $W_PROCESS)"
  negates="(evt.type in (dup, dup2, dup3) and container.id != host and evt.rawres in (0, 1, 2) and fd.type in (ipv4, ipv6) and not"
  compiled="$(jq -r '.rules[0].details.condition_compiled' "$out/rule.json")"
  echo "compiled: $compiled"
  [ "$compiled" = "$negates $conjunction)" ]
  # Without the local file the same rule negates the image's placeholder, which is never true: the
  # exception is all that the local rules change in it.
  FALCO_RULES_D="$out/no-rules" falco_image falco -L >"$out/image.json" 2>"$out/image.err" || { cat "$out/image.err"; return 1; }
  plain="$(RULE="$rule" jq -r '.rules[] | select(.info.name == env.RULE) | .details.condition_compiled' "$out/image.json")"
  echo "the image's: $plain"
  [ "$plain" = "$negates evt.num = 0)" ]
  # With the local file Falco lists as many rules enabled as the image has without it, the same
  # ones, and nothing but that rule and its macro differs: no other rule, macro or list.
  falco_image falco -L >"$out/local.json" 2>"$out/local.err" || { cat "$out/local.err"; return 1; }
  enabled() { jq -r '[.rules[] | select(.info.enabled) | .info.name] | sort | .[]' "$1"; }
  echo "enabled rules: $(enabled "$out/image.json" | grep -c .) of the image, $(enabled "$out/local.json" | grep -c .) with the local file"
  [ -n "$(enabled "$out/image.json")" ]
  [ "$(enabled "$out/local.json")" = "$(enabled "$out/image.json")" ]
  differing() {
    jq -rn --arg kind "$1" --slurpfile image "$out/image.json" --slurpfile local "$out/local.json" '
      def named: map({key: .info.name, value: walk(if type == "array" then sort else . end)}) | from_entries;
      ($image[0][$kind] | named) as $a | ($local[0][$kind] | named) as $b
      | [$a + $b | keys[] | select($a[.] != $b[.])] | join(",")'
  }
  [ "$(differing rules)" = "$rule" ]
  [ "$(differing macros)" = user_known_stand_streams_redirect_activities ]
  [ -z "$(differing lists)" ]
}

@test "Falco's memory request and limit follow from its buffers, and an out-of-memory kill restarts it in its pod" {
  local request limit preset cpus falco pair largest measured="Falco itself,[^:]*: about ([0-9]+) MiB resident"
  render
  daemonset
  falco_config
  # What the container asks of a node: the chart's CPU figures, and the memory the docs derive.
  [ "$(yq '.resources.requests.cpu' "$CONTAINER")" = 100m ]
  [ "$(yq '.resources.limits.cpu' "$CONTAINER")" = 1000m ]
  request="$(yq '.resources.requests.memory' "$CONTAINER")"
  limit="$(yq '.resources.limits.memory' "$CONTAINER")"
  [ "$request" = 192Mi ]
  [ "$limit" = 512Mi ]
  # The buffers the request is derived from are written in the values, not left to the chart's
  # defaults, and are what Falco's configuration holds: preset 4, 8 MiB a ring buffer, and one for
  # every two CPUs.
  preset="$(yq '.driver.modernEbpf.bufSizePreset' "$VALUES")"
  cpus="$(yq '.driver.modernEbpf.cpusForEachBuffer' "$VALUES")"
  [ "$preset" = 4 ]
  [ "$cpus" = 2 ]
  [ "$(yq '.engine.modern_ebpf.buf_size_preset' "$CONFIG")" = "$preset" ]
  [ "$(yq '.engine.modern_ebpf.cpus_for_each_buffer' "$CONFIG")" = "$cpus" ]
  # The docs derive the request from them, for a node of 8 CPUs: its ring buffers, a power of two
  # MiB each by the preset, one for each group of CPUs.
  runtime_detection_docs
  [[ $DOCS == *"\`$request\`"* && $DOCS == *"\`$limit\`"* ]]
  [[ $DOCS == *"$(((1 << (preset - 1)) * ((8 + cpus - 1) / cpus))) MiB of ring buffers"* ]]
  # The rest of the arithmetic follows from those two, 256 KiB of auxiliary maps for each CPU and
  # the figure the docs measured for Falco itself: the fixed part for 8 CPUs, the request as twice
  # that, what each further pair of CPUs adds, the largest node the request holds, and the fixed
  # part on a node of 32.
  [[ $DOCS =~ $measured ]] || { echo "the docs give no figure for Falco itself"; return 1; }
  falco="${BASH_REMATCH[1]}"
  fixed_kib() { echo $(((1 << (preset - 1)) * (($1 + cpus - 1) / cpus) * 1024 + $1 * 256 + falco * 1024)); }
  about() { echo $((($1 + 512) / 1024)); }
  exactly() { awk -v kib="$1" 'BEGIN { printf "%g", kib / 1024 }'; }
  [[ $DOCS == *"the fixed part is $(((1 << (preset - 1)) * ((8 + cpus - 1) / cpus))) MiB of ring buffers, $(exactly $((8 * 256))) MiB of auxiliary maps and Falco's $falco MiB, about $(about "$(fixed_kib 8)") MiB"* ]]
  [[ $DOCS == *"as much again for the state, about $(about $((2 * $(fixed_kib 8)))) MiB, taken up to \`$request\`"* ]]
  ((2 * $(fixed_kib 8) <= ${request%Mi} * 1024))
  pair=$(($(fixed_kib 10) - $(fixed_kib 8)))
  [[ $DOCS == *"Each further pair of CPUs adds $(exactly "$pair") MiB to the fixed part"*"and so $(exactly $((2 * pair))) MiB to the request"* ]]
  largest=8
  while ((2 * $(fixed_kib $((largest + 1))) <= ${request%Mi} * 1024)); do largest=$((largest + 1)); done
  [[ $DOCS == *"\`$request\` holds up to a node of $largest CPUs"* ]]
  [[ $DOCS == *"on a node of 32 the fixed part alone is about $(about "$(fixed_kib 32)") MiB"* ]]
  [[ $DOCS == *container_memory_working_set_bytes* ]]
  # A container over its memory limit is killed, and the pod, a DaemonSet's, restarts its
  # containers always: Falco starts again in the same pod, under the same name and labels, with
  # its counters at nothing. The docs say where such a kill shows.
  [ "$(yq '.kind' "$DAEMONSET")" = DaemonSet ]
  [ "$(yq '.spec.template.spec.restartPolicy // "Always"' "$DAEMONSET")" = Always ]
  [[ $DOCS == *OOMKilled* ]]
}

@test "Falco's pod mounts no service account token" {
  local chart values templates
  render
  daemonset
  # The pod template opts out of the token, no volume projects one and no container mounts the
  # directory one would be in.
  [ "$(yq '.spec.template.spec.automountServiceAccountToken' "$DAEMONSET")" = false ]
  [ "$(yq '[.spec.template.spec.volumes[] | select(.projected != null) | .projected.sources[] | select(has("serviceAccountToken"))] | length' "$DAEMONSET")" -eq 0 ]
  [ "$(yq '[.spec.template.spec | (.containers + (.initContainers // []))[] | .volumeMounts[] | select(.mountPath | test("secrets/kubernetes[.]io"))] | length' "$DAEMONSET")" -eq 0 ]
  # The service account does not say otherwise, and nothing is bound to it: the render holds no
  # Role and no binding, so the pod has no right to call the API with.
  [ "$(object "$RENDERED" ServiceAccount falco | yq 'has("automountServiceAccountToken")')" = false ]
  [ "$(yq -N '.kind' "$RENDERED" | grep -cE '^(Cluster)?Role(Binding)?$' || true)" -eq 0 ]
  # The chart at the pin has no value for the field, on the pod or on the ServiceAccount: neither
  # its values nor its templates name it, and what it renders sets it nowhere. So the release's
  # post-renderer sets it; a chart that gains a value fails here, and the value takes its place.
  chart="$(helm show chart "$CHART" | yq '.name')"
  values="$(helm show values "$CHART")"
  templates="$(tar -xzOf "$CHART" "$chart/templates")"
  # Each read holds what the field would sit beside, so a search that finds nothing read something.
  [[ $values == *serviceAccount:* && $templates == *serviceAccountName:* ]]
  if grep -qi automount <<<"$values" || grep -qi automount <<<"$templates"; then
    echo "the chart now has a value for it"
    return 1
  fi
  [ "$(grep -ci automount "$BATS_TEST_TMPDIR/post-render/chart.yaml" || true)" -eq 0 ]
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.postRenderers[].kustomize.patches[] | select(.target.kind == "DaemonSet") | .patch' "$BUILT" | yq '.spec.template.spec.automountServiceAccountToken')" = false ]
  # The docs say that the pod mounts none, and why it needs none.
  runtime_detection_docs
  [[ $DOCS == *"automountServiceAccountToken: false"* ]]
}

@test "the Falco binary and the container plugin of the pinned image hold neither the API server's variable nor the token's path" {
  local falco plugin found
  render
  daemonset
  falco_config
  docker_or_skip
  # The two files of the image that could call the API: the binary the container runs and the one
  # plugin its configuration loads. A client that finds the API server from inside a pod reads the
  # variable KUBERNETES_SERVICE_HOST and the token under /var/run/secrets/kubernetes.io, and
  # neither file holds either string; each holds HOST_ROOT, which both read, so a count of 0 is a
  # search that read the file. Falco itself is not started, so no rules are mounted.
  falco="$(yq '.args[0]' "$CONTAINER")"
  plugin="/usr/share/falco/plugins/$(yq '.plugins[] | select(.name == "container") | .library_path' "$CONFIG")"
  mkdir -p "$BATS_TEST_TMPDIR/no-rules"
  # shellcheck disable=SC2016 # The loop is the container's shell's.
  found="$(FALCO_RULES_D="$BATS_TEST_TMPDIR/no-rules" falco_image sh -c 'for file in "$@"; do for string in KUBERNETES_SERVICE_HOST secrets/kubernetes.io HOST_ROOT; do
    echo "$file $string $(grep -c -a -F -e "$string" "$file")"; done; done' sh "$falco" "$plugin")"
  echo "$found"
  [ "$(grep -c . <<<"$found")" -eq 6 ]
  [ "$(awk '$2 != "HOST_ROOT" && $3 != 0' <<<"$found" | grep -c . || true)" -eq 0 ]
  [ "$(awk '$2 == "HOST_ROOT" && $3 > 0' <<<"$found" | grep -c .)" -eq 2 ]
}

@test "A command without a terminal raises a named rule of the image, and a query finds its event" {
  local out="$BATS_TEST_TMPDIR/falco" rule="Search Private Keys or Passwords" command query priority compiled
  render
  daemonset
  falco_config
  workload "$REPO"
  runtime_detection_docs
  # The docs' smoke test: a find for a private key's name, run in hello's container by kubectl
  # exec, which opens no terminal, the rule the docs say it raises, and the query for that rule's
  # events in the store.
  command="kubectl --namespace $W_NAMESPACE exec deployment/$W_DEPLOYMENT --container $W_CONTAINER -- find $W_DIRECTORY -name id_rsa"
  query="just logs 'kubernetes.pod_namespace:security-system kubernetes.container_name:falco | unpack_json | filter rule:\"$rule\"'"
  echo "$command"
  [[ $DOCS == *"\`$command\` raises \`$rule\`"* ]]
  [[ $DOCS == *"\`$query\`"* ]]
  # Falco, on the rules the pod holds, has the rule, enabled, at the priority the docs give it.
  local_rules
  docker_or_skip
  mkdir -p "$out"
  falco_image falco -l "$rule" >"$out/smoke.json" 2>"$out/smoke.err" || { cat "$out/smoke.err"; return 1; }
  [ "$(jq -r '.rules | map(.info.name) | join(",")' "$out/smoke.json")" = "$rule" ]
  [ "$(jq -r '.rules[0].info.enabled' "$out/smoke.json")" = true ]
  priority="$(jq -r '.rules[0].info.priority' "$out/smoke.json")"
  [ "$priority" = Warning ]
  [[ $DOCS == *"\`$command\` raises \`$rule\`, at priority $priority"* ]]
  # As compiled, it matches the start of any process named find whose arguments contain id_rsa,
  # and reads nothing else of the process: no terminal and no container, so the command above
  # matches it from kubectl exec, in a pod.
  compiled="$(jq -r '.rules[0].details.condition_compiled' "$out/smoke.json")"
  echo "compiled: $compiled"
  [[ $compiled == "(evt.type in (execve, execveat) and ("*" or (proc.name = find and (proc.args contains id_rsa or "*"))))" ]]
  [ "$(jq -r '.rules[0].details.condition_fields | sort | join(" ")' "$out/smoke.json")" = "evt.num evt.type proc.args proc.name" ]
  [ "$(jq -r '.rules[0].details.condition_fields | map(select(. == "proc.tty" or . == "container.id")) | length' "$out/smoke.json")" -eq 0 ]
  # Its event carries the three fields the docs name: the command, the pod and the namespace.
  [ "$(jq -r '.rules[0].details.output_fields | map(select(. == "proc.cmdline" or . == "k8s.pod.name" or . == "k8s.ns.name")) | sort | join(" ")' "$out/smoke.json")" = "k8s.ns.name k8s.pod.name proc.cmdline" ]
  [[ $DOCS == *"the command in \`proc.cmdline\`, the pod and namespace in \`k8s.pod.name\` and \`k8s.ns.name\`, under \`output_fields\`"* ]]
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
