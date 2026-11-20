#!/usr/bin/env bats
# Proves features/falco.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq and jq on PATH (the versions pinned for the repository). The Falco
# chart, the Cilium chart, which the exception for Cilium's sysctl fix is read from, and, for the
# collector's configuration, the Vector chart are pulled once per run from their public registries;
# building and rendering are offline, with the placeholders of the cluster's example key lists.
#
# Four tests also run the image the render names, with docker: the proofs of three scenarios, which
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

# built [NAME [TREE]]: the application NAME, falco by default, as Flux applies it on lab-sto2 from
# TREE, the repository by default. Writes $BATS_TEST_TMPDIR/NAME-built.yaml and sets BUILT.
built() {
  build "${2:-$REPO}" "${1:-falco}"
  BUILT="$BUILD"
}

# render [NAME [TREE]]: renders the chart that the HelmRelease of the application NAME, falco by
# default, installs from TREE, the repository by default: from the URL and tag of its
# OCIRepository, or the chart and version it pins of its HelmRepository, with the values
# helm-controller gives it: those of the ConfigMap the HelmRelease reads, or the chart's defaults
# where it reads none, then the HelmRelease's own over them, and its post-renderers over the
# result. A chart is pulled once a run for each URL and tag. Builds NAME, writes
# $BATS_TEST_TMPDIR/NAME.yaml and sets BUILT, RENDERED, VALUES, CHART and APP_VERSION, the chart's
# appVersion.
render() {
  local app="${1:-falco}" tree="${2:-$REPO}" url tag chart="" name release namespace pulled post
  built "$app" "$tree"
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
  if [ -z "$url" ]; then
    url="$(yq -N 'select(.kind == "HelmRepository") | .spec.url' "$BUILT")"
    chart="$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.chart // ""' "$BUILT")"
    tag="$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.version // ""' "$BUILT")"
    [ -n "$url" ] && [ -n "$chart" ] && [ -n "$tag" ] ||
      { echo "$app: neither an OCIRepository nor a chart and version of a HelmRepository"; return 1; }
  fi
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name // ""' "$BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  VALUES="$BATS_TEST_TMPDIR/$app-values.yaml"
  if [ -n "$name" ]; then
    NAME="$name" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .data["values.yaml"]' "$BUILT" >"$VALUES"
    [ -s "$VALUES" ] || { echo "$app: no values in the ConfigMap $name the HelmRelease reads"; return 1; }
  else
    : >"$VALUES"
  fi
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.values // {} | length' "$BUILT")" -eq 0 ] ||
    { echo "$app: the HelmRelease has values of its own beside its ConfigMap"; return 1; }
  pulled="$BATS_FILE_TMPDIR/charts/${url#*://}${chart:+/$chart}/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    # A pull that fails leaves no directory, so the next render pulls again and fails with the
    # pull's own error, not with a cache that holds no chart. What the pull prints goes to standard
    # error, so a caller that reads a render's result from standard output reads that alone.
    if [ -n "$chart" ]; then
      helm pull "$chart" --repo "$url" --version "$tag" --destination "$pulled" >&2 || { rm -rf "$pulled"; return 1; }
    else
      helm pull "$url" --version "$tag" --destination "$pulled" >&2 || { rm -rf "$pulled"; return 1; }
    fi
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  APP_VERSION="$(helm show chart "$CHART" | yq '.appVersion')"
  RENDERED="$BATS_TEST_TMPDIR/$app.yaml"
  post="$BATS_TEST_TMPDIR/$app-post-render"
  mkdir -p "$post"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" --values "$VALUES" >"$post/chart.yaml"
  # helm-controller then passes the manifests through the release's post-renderers; only kustomize
  # patches and images are known here, so any other kind or key fails instead of being skipped.
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.postRenderers // [] | map(select(has("kustomize") | not)) | length' "$BUILT")" -eq 0 ] ||
    { echo "$app: the HelmRelease has a post-renderer that is not kustomize"; return 1; }
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.postRenderers // [] | map(.kustomize | keys) | flatten | map(select(. != "patches" and . != "images")) | length' "$BUILT")" -eq 0 ] ||
    { echo "$app: the HelmRelease has a kustomize post-renderer with more than patches and images"; return 1; }
  yq -N 'select(.kind == "HelmRelease") | {"resources": ["chart.yaml"], "patches": (.spec.postRenderers // [] | map(.kustomize.patches // []) | flatten),
    "images": (.spec.postRenderers // [] | map(.kustomize.images // []) | flatten)}' "$BUILT" >"$post/kustomization.yaml"
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

# sysctl_fix TREE: Cilium's sysctl fix, the one container of the cilium application's render that
# runs cilium-sysctlfix, as Flux installs it on lab-sto2 from TREE. Sets C_NAMESPACE, the namespace
# of the DaemonSet cilium, C_CONTAINER, that container's name, C_REPOSITORY, its image without tag
# or digest, and C_PATH, the path it runs the binary at, ${BIN_PATH}/cilium-sysctlfix with BIN_PATH
# from its environment. Fails, saying what Cilium is now, when no container of the render runs the
# binary, which leaves the exception for it naming nothing, or more than one does; when that is not
# a container of the DaemonSet cilium, the DaemonSet is not in the namespace its Kustomization
# targets, or another container of the render has its name; when its image is not written as the
# runtime reports it, registry first; and when its command is not the chart's, a copy of the binary
# into the mount of the host path BIN_PATH, run there by nsenter in the mount namespace of the node's
# PID 1, through the mount of the host path /proc, which is what makes that path the node's.
sysctl_fix() {
  local daemonset="$BATS_TEST_TMPDIR/cilium-daemonset.yaml" container="$BATS_TEST_TMPDIR/sysctl-fix.yaml"
  local runs named image registry bin hostbin hostproc command script
  render cilium "$1" || return 1
  runs="$(yq -o json -I0 '.' "$RENDERED" | jq -r '. as $object
    | (.spec.template.spec // .spec.jobTemplate.spec.template.spec // (if .kind == "Pod" then .spec else null end)) // empty
    | (.containers // []) + (.initContainers // []) | .[] | select((.command // []) + (.args // []) | any(contains("cilium-sysctlfix")))
    | "\($object.kind)/\($object.metadata.name)/\(.name)"')"
  if [ -z "$runs" ]; then
    echo "no container of Cilium's render runs cilium-sysctlfix, so the exception for it in exceptions.yaml names nothing that runs: remove it, its reason and its proofs (docs/kubernetes.md, Tuning)"
    return 1
  fi
  [ "$(grep -c . <<<"$runs")" -eq 1 ] || { echo "more than one container of Cilium's render runs cilium-sysctlfix: $(paste -sd' ' <<<"$runs")"; return 1; }
  [[ $runs == DaemonSet/cilium/* ]] || { echo "the container of Cilium's render that runs cilium-sysctlfix is $runs, not one of the DaemonSet cilium"; return 1; }
  C_CONTAINER="${runs#DaemonSet/cilium/}"
  named="$(yq -o json -I0 '.' "$RENDERED" | CONTAINER_NAME="$C_CONTAINER" jq -r '. as $object
    | (.spec.template.spec // .spec.jobTemplate.spec.template.spec // (if .kind == "Pod" then .spec else null end)) // empty
    | (.containers // []) + (.initContainers // []) | .[] | select(.name == env.CONTAINER_NAME)
    | "\($object.kind)/\($object.metadata.name)/\(.name)"')"
  [ "$named" = "$runs" ] || { echo "more containers of Cilium's render than the sysctl fix are named $C_CONTAINER: $(paste -sd' ' <<<"$named")"; return 1; }
  object "$RENDERED" DaemonSet cilium >"$daemonset"
  C_NAMESPACE="$(yq '.metadata.namespace' "$daemonset")"
  [ "$C_NAMESPACE" = "$(yq '.spec.targetNamespace' "$BUILD_KS")" ] ||
    { echo "Cilium's DaemonSet cilium renders in the namespace $C_NAMESPACE, and its Kustomization targets $(yq '.spec.targetNamespace' "$BUILD_KS")"; return 1; }
  CONTAINER_NAME="$C_CONTAINER" yq '.spec.template.spec | (.containers // []) + (.initContainers // []) | .[] | select(.name == strenv(CONTAINER_NAME))' "$daemonset" >"$container"
  image="$(yq '.image' "$container")"
  C_REPOSITORY="$(repository "$image")"
  registry="${C_REPOSITORY%%/*}"
  if [[ $C_REPOSITORY != */* || $registry != *.* || ($registry == docker.io && $C_REPOSITORY != */*/*) ]]; then
    echo "the sysctl fix's image $image is not written as the runtime reports it: its registry first and, on docker.io, its namespace"
    return 1
  fi
  bin="$(yq '[.env // [] | .[] | select(.name == "BIN_PATH") | .value] | .[0] // ""' "$container")"
  [[ $bin == /* ]] || { echo "the sysctl fix $C_CONTAINER has no absolute BIN_PATH in its environment: $bin"; return 1; }
  C_PATH="$bin/cilium-sysctlfix"
  # The directory where the container mounts the host path at PATH, one mount of one volume.
  mounted() {
    yq -o json '.spec.template.spec.volumes // []' "$daemonset" | HOST_PATH="$1" jq -r --slurpfile mounts <(yq -o json '.volumeMounts // []' "$container") '
      [.[] | select(.hostPath.path == env.HOST_PATH) | .name] as $volumes
      | [$mounts[0][] | select(.name as $name | $volumes | index($name)) | .mountPath]
      | if length == 1 then .[0] else "" end'
  }
  hostbin="$(mounted "$bin")"
  hostproc="$(mounted /proc)"
  command="$(yq -o json '{"command": .command, "args": .args}' "$container" | jq -c .)"
  # shellcheck disable=SC2016 # ${BIN_PATH} is the container's shell's.
  script="$(printf 'cp /usr/bin/cilium-sysctlfix %s/cilium-sysctlfix;\nnsenter --mount=%s/1/ns/mnt "${BIN_PATH}/cilium-sysctlfix";\nrm %s/cilium-sysctlfix\n' "$hostbin" "$hostproc" "$hostbin")"
  if [ -z "$hostbin" ] || [ -z "$hostproc" ] ||
    [ "$command" != "$(jq -cn --arg script "$script"$'\n' '{"command": ["bash", "-ec", $script], "args": null}')" ]; then
    echo "the sysctl fix $C_CONTAINER does not run what the exception's reason says, a copy of cilium-sysctlfix into the mount of the host path $bin, run by nsenter in the mount namespace of the node's PID 1 through the mount of the host path /proc: read the chart's init container that runs cilium-sysctlfix again, in templates/cilium-agent/daemonset.yaml, for what it now runs. It mounts the host path $bin at ${hostbin:-no one place} and /proc at ${hostproc:-no one place}, and runs $command"
    return 1
  fi
}

# sysctl_fix_exception: the condition that excepts the sysctl fix the last call of sysctl_fix read,
# and nothing else: its namespace, container, image repository and the path it runs, each compared
# for equality, joined by and, in parentheses.
sysctl_fix_exception() {
  printf '(k8s.ns.name = "%s" and container.name = "%s" and container.image.repository = "%s" and proc.exepath = "%s")' \
    "$C_NAMESPACE" "$C_CONTAINER" "$C_REPOSITORY" "$C_PATH"
}

# excepts_sysctl_fix TREE: succeeds when $CONDITION, the condition of the rendered exception, is
# exactly the one that names the sysctl fix of the Cilium of TREE; otherwise says what each names
# and fails.
excepts_sysctl_fix() {
  sysctl_fix "$1" || return 1
  [ "$CONDITION" = "$(sysctl_fix_exception)" ] || {
    echo "the exception does not name Cilium's sysctl fix and it alone: its condition is $CONDITION, and the sysctl fix is $(sysctl_fix_exception)"
    return 1
  }
}

# The containers the operators make at run time, which no render holds, named as their sources at
# the versions the tree pins name them: the HA controller's DaemonSet in
# pkg/resources/cluster/ha-controller/daemonset.yaml of piraeus-operator v2.12.1; PostgreSQL's
# container of each instance's pod, PostgresContainerName in pkg/specs/pods.go of cloudnative-pg
# v1.30.1, and the one container of the Jobs that create an instance and join it to the cluster,
# named after the Job's role, jobRoleInitDB and jobRoleJoin in pkg/specs/jobs.go; and the sidecar
# the Barman Cloud plugin injects into each instance's pod and into a restore's full-recovery or
# snapshot-recovery Job, in internal/cnpgi/operator/lifecycle.go of plugin-barman-cloud v0.16.0.
HA_CONTAINER="ha-controller"
PG_CONTAINER="postgres"
PG_JOB_CONTAINERS="initdb join"
PG_SIDECAR_CONTAINER="plugin-barman-cloud"

# executable WORKLOAD: the executable the excepted container of WORKLOAD runs, where the tree does
# not state the container's command, read from the source beside each.
executable() {
  case "$1" in
    # supervisord runs the task container's programs, awx-manage run_dispatcher among them, by that
    # name (/etc/supervisord_task.conf of the image ghcr.io/ctrliq/ascender 25.6.3); the dispatcher's
    # workers are forks (multiprocessing's Process in awx/main/dispatch/pool.py), which keep it.
    ascender-task) echo awx-manage ;;
    # The image's entrypoint, /tini -- /usr/local/bin/ansible-operator run ..., of
    # ghcr.io/ctrliq/ascender-operator 25.6.3, whose binary is a Go executable.
    ascender-operator) echo /usr/local/bin/ansible-operator ;;
    # The image's entrypoint, /usr/bin/vector, of docker.io/timberio/vector 0.61.0-distroless-libc.
    vector) echo /usr/bin/vector ;;
    # The images' entrypoints, /ko-app/kyverno and /ko-app/reports-controller, of
    # reg.kyverno.io/kyverno/kyverno and reg.kyverno.io/kyverno/reports-controller v1.20.0.
    kyverno-admission-controller) echo /ko-app/kyverno ;;
    kyverno-reports-controller) echo /ko-app/reports-controller ;;
    # The DaemonSet's container runs /agent, its first argument, with no command
    # (pkg/resources/cluster/ha-controller/daemonset.yaml of piraeus-operator v2.12.1), as does the
    # image, ENTRYPOINT none and CMD /agent -v=2, of quay.io/piraeusdatastore/piraeus-ha-controller
    # v1.3.4.
    ha-controller) echo /agent ;;
    # The command of PostgreSQL's container, /controller/manager instance run (pkg/specs/pods.go of
    # cloudnative-pg v1.30.1), and of each Job's, /controller/manager instance init or join
    # (pkg/specs/jobs.go).
    instance-manager) echo /controller/manager ;;
    # The image's entrypoint, /manager, of ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar
    # v0.16.0, which the plugin runs with the argument instance in an instance's pod and restore in
    # a restore's Job (internal/cnpgi/operator/lifecycle.go).
    barman-cloud-sidecar) echo /manager ;;
    # PostgreSQL's server, which the instance manager starts by that name
    # (GetPostgresExecutableName in pkg/management/postgres/instance.go of cloudnative-pg v1.30.1),
    # and whose archiver is a fork of it, under the same name.
    postgres) echo postgres ;;
    *)
      echo "no executable is recorded for $1" >&2
      return 1
      ;;
  esac
}

# comm EXECUTABLE: the name the kernel gives a process that runs EXECUTABLE, which Falco reports in
# proc.name (TYPE_NAME, get_comm, in userspace/libsinsp/sinsp_filtercheck_thread.cpp of libs
# 0.26.1, from the comm the probe reads from the task at each execve): the executable's base name,
# cut to 15 characters, as task->comm holds TASK_COMM_LEN, 16, bytes with its terminating NUL
# (include/linux/sched.h) and __set_task_comm copies at most 15 of them (fs/exec.c of Linux 6.18).
comm() {
  local name="${1##*/}"
  printf '%s' "${name:0:15}"
}

# term FIELD VALUE...: FIELD compared with VALUE for equality, or, given several values, with their
# set, sorted and without repeats, by in; each value quoted, as the local rules quote it.
term() {
  local field="$1"
  shift
  if [ "$#" -eq 1 ]; then
    printf '%s = "%s"' "$field" "$1"
  else
    printf '%s in (%s)' "$field" "$(printf '%s\n' "$@" | LC_ALL=C sort -u | sed 's/.*/"&"/' | paste -sd, - | sed 's/,/, /g')"
  fi
}

# conjunction NAMESPACES CONTAINERS REPOSITORY PROCESS: the condition that excepts the process
# PROCESS in a container named one of CONTAINERS, of the image repository REPOSITORY, in one of the
# namespaces NAMESPACES, and nothing else: four terms joined by and, in parentheses. NAMESPACES and
# CONTAINERS are words, a set where they are several.
conjunction() {
  local namespaces containers
  read -ra namespaces <<<"$1"
  read -ra containers <<<"$2"
  printf '(%s and %s and %s and %s)' "$(term k8s.ns.name "${namespaces[@]}")" "$(term container.name "${containers[@]}")" \
    "$(term container.image.repository "$3")" "$(term proc.name "$4")"
}

# registry_first IMAGE WHAT: the repository of IMAGE, WHAT's image, as the runtime reports it, which
# is the form Falco compares. Fails, saying so, when IMAGE is not written that way: its registry
# first and, on docker.io, its namespace.
registry_first() {
  local repository registry
  repository="$(repository "$1")"
  registry="${repository%%/*}"
  if [[ $repository != */* || $registry != *.* || ($registry == docker.io && $repository != */*/*) ]]; then
    echo "$2's image $1 is not written as the runtime reports it: its registry first and, on docker.io, its namespace"
    return 1
  fi
  normalized "$1"
}

# item INDEX: sets CONDITION to the condition of the item INDEX, from 0, of the rendered local rules
# in $EXCEPTIONS, and MACRO and OVERRIDE to the macro it overrides and how.
item() {
  CONDITION="$(INDEX="$1" yq '.[env(INDEX)].condition' "$EXCEPTIONS")"
  MACRO="$(INDEX="$1" yq '.[env(INDEX)].macro' "$EXCEPTIONS")"
  OVERRIDE="$(INDEX="$1" yq '.[env(INDEX)].override.condition' "$EXCEPTIONS")"
}

# names CONJUNCTION WHAT: succeeds when $CONDITION, the condition of the item item read last, is
# CONJUNCTION, the one that names WHAT and it alone, as the item writes it: alone where it replaces
# the placeholder, after or where it appends to it. Otherwise says what each names and fails.
names() {
  local expected="$1"
  [ "$OVERRIDE" = append ] && expected="or $expected"
  [ "$CONDITION" = "$expected" ] || {
    echo "the exception does not name $2 and it alone: its condition is $CONDITION, and $2 is $expected"
    return 1
  }
}

# robot_reports TREE: Robot's report server as Flux applies it on lab-sto2 from TREE, the one
# container of the Deployment robot-reports of the application robot. Sets RR_NAMESPACE, the
# namespace its Kustomization targets, RR_DEPLOYMENT, RR_CONTAINER, the container's name,
# RR_REPOSITORY, its image as the runtime reports it, and RR_PROCESS, the process the first word of
# its command starts, as the kernel names it. Fails, saying what the server is now, when there is no
# such Deployment, it has more than one container or no command, or is in another namespace, or its
# image is not written as the runtime reports it.
robot_reports() {
  local deployment="$BATS_TEST_TMPDIR/robot-reports.yaml" image command
  build "$1" robot || return 1
  RR_DEPLOYMENT="robot-reports"
  object "$BUILD" Deployment "$RR_DEPLOYMENT" >"$deployment"
  [ -s "$deployment" ] ||
    { echo "robot builds no Deployment $RR_DEPLOYMENT, so the exception for its report server names nothing that runs: remove it, its reason and its proofs (docs/kubernetes.md, Tuning)"; return 1; }
  [ "$(yq '.spec.template.spec.containers | length' "$deployment")" -eq 1 ] || { echo "the report server's pod has more than one container"; return 1; }
  RR_NAMESPACE="$(yq '.spec.targetNamespace' "$BUILD_KS")"
  [ "$(yq '.metadata.namespace' "$deployment")" = "$RR_NAMESPACE" ] ||
    { echo "the report server's Deployment is not in the namespace its Kustomization targets"; return 1; }
  RR_CONTAINER="$(yq '.spec.template.spec.containers[0].name' "$deployment")"
  image="$(yq '.spec.template.spec.containers[0].image' "$deployment")"
  RR_REPOSITORY="$(registry_first "$image" "the report server")" || { echo "$RR_REPOSITORY"; return 1; }
  command="$(yq '.spec.template.spec.containers[0].command[0] // ""' "$deployment")"
  [ -n "$command" ] || { echo "the report server's container has no command to take its process from"; return 1; }
  RR_PROCESS="$(comm "$command")"
}

# ha_controller TREE: Piraeus' HA controller as the Piraeus operator makes it on lab-sto2 from TREE:
# the DaemonSet's container HA_CONTAINER, which the operator makes in its own namespace, on the image
# its configuration gives the placeholder ha-controller. Sets HA_NAMESPACE, the namespace of the
# operator's release, which its Kustomization targets, and HA_REPOSITORY, that image as the runtime
# reports it: the base and image of the last document of the operator's rendered image
# configuration, in their names' order, that configures the placeholder, the LinstorCluster's
# repository in place of that base where it names one (GetVersions in
# pkg/imageversions/versions.go, its call in internal/controller/linstorcluster_controller.go).
# Fails, saying what the HA controller is now, when the LinstorCluster turns it off, patches it or
# what the operator makes, or names a container image in its pod template, when the operator's
# environment overrides the image (RELATED_IMAGE_ha-controller), and when no document configures
# the placeholder.
ha_controller() {
  local operator="$BATS_TEST_TMPDIR/piraeus-operator-deployment.yaml" cluster="$BATS_TEST_TMPDIR/linstorcluster.yaml"
  local config key base="" image="" repository
  render piraeus-operator "$1" || return 1
  HA_NAMESPACE="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  [ "$HA_NAMESPACE" = "$(yq '.spec.targetNamespace' "$BUILD_KS")" ] ||
    { echo "the Piraeus operator's release installs into $HA_NAMESPACE, and its Kustomization targets $(yq '.spec.targetNamespace' "$BUILD_KS")"; return 1; }
  object "$RENDERED" Deployment piraeus-operator-controller-manager >"$operator"
  [ -s "$operator" ] || { echo "the Piraeus operator's chart renders no Deployment piraeus-operator-controller-manager"; return 1; }
  [ "$(yq '[.spec.template.spec.containers[].env[]? | select(.name | test("^RELATED_IMAGE_ha-controller"))] | length' "$operator")" -eq 0 ] ||
    { echo "the Piraeus operator's environment overrides the HA controller's image"; return 1; }
  config="$(yq '.spec.template.spec.containers[].env[]? | select(.name == "IMAGE_CONFIG_MAP_NAME") | .value' "$operator")"
  [ -n "$config" ] || { echo "the Piraeus operator names no image configuration"; return 1; }
  while read -r key; do
    if [ "$(object "$RENDERED" ConfigMap "$config" | KEY="$key" yq '.data[strenv(KEY)]' | yq '.components | has("ha-controller")')" = true ]; then
      base="$(object "$RENDERED" ConfigMap "$config" | KEY="$key" yq '.data[strenv(KEY)]' | yq '.base // ""')"
      image="$(object "$RENDERED" ConfigMap "$config" | KEY="$key" yq '.data[strenv(KEY)]' | yq '.components["ha-controller"].image // ""')"
    fi
  done < <(object "$RENDERED" ConfigMap "$config" | yq '.data | keys | .[]' | LC_ALL=C sort)
  [ -n "$base" ] && [ -n "$image" ] || { echo "no document of the image configuration $config configures the HA controller's image"; return 1; }
  build "$1" linstor-cluster || return 1
  yq -N 'select(.kind == "LinstorCluster")' "$BUILD" >"$cluster"
  [ "$(yq -N '.metadata.name' "$cluster" | grep -c .)" -eq 1 ] || { echo "linstor-cluster builds no one LinstorCluster"; return 1; }
  [ "$(yq '.spec.highAvailabilityController.enabled' "$cluster")" != false ] ||
    { echo "the LinstorCluster turns the HA controller off, so the exception for it names nothing that runs: remove it, its reason and its proofs (docs/kubernetes.md, Tuning)"; return 1; }
  [ "$(NAME="$HA_CONTAINER" yq '[.spec.highAvailabilityController.podTemplate.spec.containers[]? | select(.name != strenv(NAME) or has("image"))] | length' "$cluster")" -eq 0 ] ||
    { echo "the LinstorCluster's pod template of the HA controller names another container or an image"; return 1; }
  [ "$(yq '.spec.patches // [] | length' "$cluster")" -eq 0 ] ||
    { echo "the LinstorCluster patches what the operator makes, which can rename the HA controller's container or move its image: read its patches and the exception again"; return 1; }
  base="$(BASE="$base" yq '.spec.repository // strenv(BASE)' "$cluster")"
  repository="$(registry_first "$base/$image" "the HA controller")" || { echo "$repository"; return 1; }
  HA_REPOSITORY="$repository"
}

# chart_container TREE APP KIND NAME: the container of the workload KIND/NAME of APP's chart, rendered
# as Flux installs it on lab-sto2 from TREE, that the workload runs: the one the annotation
# kubectl.kubernetes.io/default-container names, or else its one container. Sets CC_NAMESPACE, the
# namespace the release installs into, which its Kustomization targets, CC_CONTAINER, the
# container's name, and CC_REPOSITORY, its image as the runtime reports it. Fails, saying what APP
# is now, when the render has no such workload or it is in another namespace, when the container
# cannot be told, and when its image is not written as the runtime reports it.
chart_container() {
  local workload="$BATS_TEST_TMPDIR/$2-$4.yaml" image namespace repository
  render "$2" "$1" || return 1
  CC_NAMESPACE="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  [ "$CC_NAMESPACE" = "$(yq '.spec.targetNamespace' "$BUILD_KS")" ] ||
    { echo "$2's release installs into $CC_NAMESPACE, and its Kustomization targets $(yq '.spec.targetNamespace' "$BUILD_KS")"; return 1; }
  object "$RENDERED" "$3" "$4" >"$workload"
  [ -s "$workload" ] || { echo "$2's chart renders no $3 $4"; return 1; }
  namespace="$(yq '.metadata.namespace // ""' "$workload")"
  [ -z "$namespace" ] || [ "$namespace" = "$CC_NAMESPACE" ] ||
    { echo "$2's $3 $4 renders in the namespace $namespace, and its release installs into $CC_NAMESPACE"; return 1; }
  CC_CONTAINER="$(yq '.spec.template.metadata.annotations["kubectl.kubernetes.io/default-container"] // ""' "$workload")"
  if [ -z "$CC_CONTAINER" ]; then
    [ "$(yq '.spec.template.spec.containers | length' "$workload")" -eq 1 ] ||
      { echo "$2's $3 $4 has more than one container and names none its default"; return 1; }
    CC_CONTAINER="$(yq '.spec.template.spec.containers[0].name' "$workload")"
  fi
  image="$(NAME="$CC_CONTAINER" yq '.spec.template.spec.containers[] | select(.name == strenv(NAME)) | .image' "$workload")"
  [ -n "$image" ] || { echo "$2's $3 $4 has no container $CC_CONTAINER"; return 1; }
  repository="$(registry_first "$image" "$2's container $CC_CONTAINER")" || { echo "$repository"; return 1; }
  CC_REPOSITORY="$repository"
}

# cnpg_databases TREE: the databases the component cnpg-cluster makes on lab-sto2 from TREE. Sets
# PG_NAMESPACES, the target namespaces of every Kustomization of the overlay whose components name
# components/cnpg-cluster, sorted, as words; PG_IMAGE, the component Cluster's imageName, and
# PG_REPOSITORY, that image as the runtime reports it; and PG_SIDECAR, the repository of the sidecar
# image the Barman Cloud plugin injects into each instance's pod and a restore's Job, SIDECAR_IMAGE
# of its chart rendered as Flux installs it. Fails, saying what the databases are now, when no application takes the
# component or one takes it without a target namespace, when a Cluster those applications build
# runs another image than the component's or names a sidecar image of its own (sidecarImage,
# internal/cnpgi/operator/config/config.go of plugin-barman-cloud v0.16.0), and when an image is not
# written as the runtime reports it.
cnpg_databases() {
  local app apps plugin="$BATS_TEST_TMPDIR/plugin-barman-cloud-deployment.yaml" sidecar from repository
  overlay "$1/kubernetes/apps/overlays/lab-sto2"
  apps="$(yq -N 'select(.kind == "Kustomization" and ((.spec.components // []) | any_c(test("(^|/)components/cnpg-cluster/?$")))) | .metadata.name' "$OVERLAY")"
  [ -n "$apps" ] ||
    { echo "no application of the lab-sto2 overlay takes the component cnpg-cluster, so the exceptions for its databases name nothing that runs: remove them, their reasons and their proofs (docs/kubernetes.md, Tuning)"; return 1; }
  [ "$(yq -N 'select(.kind == "Kustomization" and ((.spec.components // []) | any_c(test("(^|/)components/cnpg-cluster/?$"))) and (.spec.targetNamespace // "") == "") | .metadata.name' "$OVERLAY")" = "" ] ||
    { echo "an application takes the component cnpg-cluster without a target namespace"; return 1; }
  PG_NAMESPACES="$(yq -N 'select(.kind == "Kustomization" and ((.spec.components // []) | any_c(test("(^|/)components/cnpg-cluster/?$")))) | .spec.targetNamespace' "$OVERLAY" | LC_ALL=C sort -u | paste -sd' ' -)"
  PG_IMAGE="$(yq '.spec.imageName // ""' "$1/kubernetes/components/cnpg-cluster/cluster.yaml")"
  repository="$(registry_first "$PG_IMAGE" "the component cnpg-cluster's Cluster")" || { echo "$repository"; return 1; }
  PG_REPOSITORY="$repository"
  for app in $apps; do
    build "$1" "$app" || return 1
    [ "$(IMAGE="$PG_IMAGE" yq -N 'select(.kind == "Cluster" and .apiVersion == "postgresql.cnpg.io/v1" and .spec.imageName != strenv(IMAGE)) | .metadata.name' "$BUILD")" = "" ] ||
      { echo "a Cluster of $app runs another image than the component's $PG_IMAGE"; return 1; }
    [ "$(yq -N 'select(.kind == "Cluster" and .apiVersion == "postgresql.cnpg.io/v1") | .spec.plugins[]? | select(.parameters | has("sidecarImage")) | .name' "$BUILD")" = "" ] ||
      { echo "a Cluster of $app names a sidecar image of its own for the Barman Cloud plugin"; return 1; }
  done
  render plugin-barman-cloud "$1" || return 1
  object "$RENDERED" Deployment plugin-barman-cloud >"$plugin"
  [ -s "$plugin" ] || { echo "the Barman Cloud plugin's chart renders no Deployment plugin-barman-cloud"; return 1; }
  from="$(yq -o json -I0 '[.spec.template.spec.containers[].env[]? | select(.name == "SIDECAR_IMAGE")] | .[0] // {}' "$plugin")"
  sidecar="$(jq -r '.value // ""' <<<"$from")"
  if [ -z "$sidecar" ]; then
    sidecar="$(object "$RENDERED" ConfigMap "$(jq -r '.valueFrom.configMapKeyRef.name // ""' <<<"$from")" |
      KEY="$(jq -r '.valueFrom.configMapKeyRef.key // ""' <<<"$from")" yq '.data[strenv(KEY)] // ""')"
  fi
  [ -n "$sidecar" ] || { echo "the Barman Cloud plugin's Deployment gives no SIDECAR_IMAGE"; return 1; }
  repository="$(registry_first "$sidecar" "the Barman Cloud plugin's sidecar")" || { echo "$repository"; return 1; }
  PG_SIDECAR="$repository"
}

# ascender_task TREE: Ascender's task container as its operator makes it from the AWX of the
# application ascender on lab-sto2 from TREE: named after the AWX, <name>-task, on the AWX's image
# (roles/installer/templates/deployments/task.yaml.j2 of ascender-operator 25.6.3), in the AWX's
# namespace. Sets AT_NAMESPACE, the namespace its Kustomization targets, AT_CONTAINER, AT_REPOSITORY,
# the AWX's image as the runtime reports it, and AT_JOB_REPOSITORIES, the repositories, one a line,
# of the execution environments the job pods and the task pod's ascender-ee run, the AWX's
# ee_images and control_plane_ee_image, as the runtime reports them.
ascender_task() {
  local awx="$BATS_TEST_TMPDIR/awx.yaml" repository image
  build "$1" ascender || return 1
  yq -N 'select(.kind == "AWX")' "$BUILD" >"$awx"
  [ "$(yq -N '.metadata.name' "$awx" | grep -c .)" -eq 1 ] || { echo "ascender builds no one AWX"; return 1; }
  AT_NAMESPACE="$(yq '.spec.targetNamespace' "$BUILD_KS")"
  [ "$(yq '.metadata.namespace' "$awx")" = "$AT_NAMESPACE" ] || { echo "the AWX is not in the namespace its Kustomization targets"; return 1; }
  AT_CONTAINER="$(yq '.metadata.name' "$awx")-task"
  repository="$(registry_first "$(yq '.spec.image' "$awx")" "Ascender's task container")" || { echo "$repository"; return 1; }
  AT_REPOSITORY="$repository"
  AT_JOB_REPOSITORIES=""
  while read -r image; do
    AT_JOB_REPOSITORIES+="$(normalized "$image")"$'\n'
  done < <(yq '(.spec.ee_images // [] | .[].image), .spec.control_plane_ee_image' "$awx")
  AT_JOB_REPOSITORIES="$(LC_ALL=C sort -u <<<"$AT_JOB_REPOSITORIES" | grep .)"
}

# job_container: the name of the one container of Ascender's default job pod, as tests/ascender.bats
# models the pod from get_default_pod_spec in awx/main/utils/execution_environments.py of the image
# Ascender runs.
job_container() {
  # shellcheck disable=SC2016 # $image is a jq variable of tests/ascender.bats, matched as written.
  sed -n 's/^.*"containers": \[{"image": \$image, "name": "\([^"]*\)".*$/\1/p' "$REPO/tests/ascender.bats"
}

# The prefix of the command line of the shell PostgreSQL's archiver starts for each finished WAL
# segment: glibc from 2.38 runs the command system() is given as sh -c -- <command>
# (sysdeps/posix/system.c), and CloudNativePG v1.30.1 makes archive_command
# /controller/manager wal-archive --log-destination <LogPath>/<LogFileName>.json %p, with LogPath
# /controller/log and LogFileName postgres (pkg/postgres/configuration.go), where PostgreSQL gives
# %p as the segment's path under the data directory, pg_wal/<segment> (pgarch.c of PostgreSQL 18).
ARCHIVE_PREFIX='sh -c -- /controller/manager wal-archive --log-destination /controller/log/postgres.json pg_wal/'

# The directory containerd's overlayfs snapshotter unpacks each layer of an image in: under
# snapshots/<id>/fs (plugins/snapshots/overlay/overlay.go of containerd 2.3.7) of its directory in
# the CRI containerd's root, /var/lib/containerd on Talos (CRIContainerdDataPath in
# pkg/machinery/constants/constants.go of Talos v1.14.6). The image's macro containerd_activities
# names the same prefix.
SNAPSHOTS=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/

# The condition each item from the third on is made of, each function taking TREE: read from what
# runs on lab-sto2 from TREE, or, where a reading fails, what the workload is now, and a failure.
reports_exception() {
  robot_reports "$1" || return 1
  conjunction "$RR_NAMESPACE" "$RR_CONTAINER" "$RR_REPOSITORY" "$RR_PROCESS"
}
ha_controller_exception() {
  ha_controller "$1" || return 1
  conjunction "$HA_NAMESPACE" "$HA_CONTAINER" "$HA_REPOSITORY" "$(comm "$(executable ha-controller)")"
}
instance_manager_redirect_exception() {
  cnpg_databases "$1" || return 1
  conjunction "$PG_NAMESPACES" "$PG_CONTAINER" "$PG_REPOSITORY" "$(comm "$(executable instance-manager)")"
}
task_exception() {
  ascender_task "$1" || return 1
  conjunction "$AT_NAMESPACE" "$AT_CONTAINER" "$AT_REPOSITORY" "$(comm "$(executable ascender-task)")"
}
operator_exception() {
  chart_container "$1" ascender-operator Deployment awx-operator-controller-manager || return 1
  conjunction "$CC_NAMESPACE" "$CC_CONTAINER" "$CC_REPOSITORY" "$(comm "$(executable ascender-operator)")"
}
vector_exception() {
  chart_container "$1" vector DaemonSet vector || return 1
  conjunction "$CC_NAMESPACE" "$CC_CONTAINER" "$CC_REPOSITORY" "$(comm "$(executable vector)")"
}
kyverno_exception() {
  chart_container "$1" kyverno Deployment kyverno-admission-controller || return 1
  conjunction "$CC_NAMESPACE" "$CC_CONTAINER" "$CC_REPOSITORY" "$(comm "$(executable kyverno-admission-controller)")"
}
reports_controller_exception() {
  chart_container "$1" kyverno Deployment kyverno-reports-controller || return 1
  conjunction "$CC_NAMESPACE" "$CC_CONTAINER" "$CC_REPOSITORY" "$(comm "$(executable kyverno-reports-controller)")"
}
instance_manager_exception() {
  cnpg_databases "$1" || return 1
  conjunction "$PG_NAMESPACES" "$PG_JOB_CONTAINERS $PG_CONTAINER" "$PG_REPOSITORY" "$(comm "$(executable instance-manager)")"
}
sidecar_exception() {
  cnpg_databases "$1" || return 1
  conjunction "$PG_NAMESPACES" "$PG_SIDECAR_CONTAINER" "$PG_SIDECAR" "$(comm "$(executable barman-cloud-sidecar)")"
}
# The archiver's shell: a process whose parent is PostgreSQL's server, postgres, started with the
# fixed prefix of the archive command, in PostgreSQL's container of each database. Fails when the
# component's image is not on Debian trixie, whose glibc, 2.41, puts the -- in the prefix.
archiver_exception() {
  local namespaces
  cnpg_databases "$1" || return 1
  [[ $PG_IMAGE =~ :[^@/]*-trixie(@|$) ]] || {
    echo "the component's image $PG_IMAGE is not of Debian trixie, whose glibc 2.41 runs the command system() is given as sh -c --: read the glibc of the image the component runs (ldd --version), the prefix in ARCHIVE_PREFIX, the exception and its reason again"
    return 1
  }
  read -ra namespaces <<<"$PG_NAMESPACES"
  printf '(%s and %s and %s and %s and proc.cmdline startswith "%s")' "$(term k8s.ns.name "${namespaces[@]}")" "$(term container.name "$PG_CONTAINER")" \
    "$(term container.image.repository "$PG_REPOSITORY")" "$(term proc.pname "$(comm "$(executable postgres)")")" "$ARCHIVE_PREFIX"
}
# Truncation under containerd's snapshots by what Falco places in no container.
clear_log_exception() {
  printf '(not container and fd.name startswith "%s")' "$SNAPSHOTS"
}

# excepts_item INDEX WHAT EXCEPTION TREE: the item INDEX names WHAT, the condition the function
# EXCEPTION makes of TREE, and it alone.
excepts_item() {
  local expected
  item "$1"
  expected="$("$3" "$4")" || { echo "$expected"; return 1; }
  names "$expected" "$2"
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

# falco_loads OUT: Falco, run on what the pod holds, loads it cleanly, writing what it prints under
# OUT. A dry run exits 0: a condition with a field Falco does not know makes it exit 1 here, which
# on a node is a pod that crash-loops. It loads the image's rules and then the local file, each
# once, in this order. Validated in that order, every file loads without an error and without a
# warning: an override of a macro the image does not define loads with the warning
# LOAD_UNUSED_MACRO and exit 0, an exception that silently excepts nothing.
falco_loads() {
  local out="$1" file loaded=() validate=()
  falco_image falco --dry-run >"$out/dry-run.out" 2>"$out/dry-run.err" || { cat "$out/dry-run.err"; return 1; }
  mapfile -t loaded < <(sed -n '/Loading rules from:/,$ s/^.*: *\(\/[^ ]*\) | schema validation: .*$/\1/p' "$out/dry-run.err")
  printf 'loaded: %s\n' "${loaded[@]}"
  [ "${loaded[*]}" = "/etc/falco/falco_rules.yaml /etc/falco/falco_rules.local.yaml /etc/falco/rules.d/exceptions.yaml" ] ||
    { echo "the dry run loaded ${loaded[*]:-nothing}, not the image's rules and then the local file"; return 1; }
  for file in "${loaded[@]}"; do validate+=(-V "$file"); done
  falco_image falco "${validate[@]}" >"$out/validate.json" 2>"$out/validate.err" || { cat "$out/validate.err"; return 1; }
  jq -c '.falco_load_results[] | {name, successful, errors: [.errors[].code], warnings: [.warnings[].code]}' "$out/validate.json"
  [ "$(jq -r '[.falco_load_results[].name] | join(" ")' "$out/validate.json")" = "${loaded[*]}" ] ||
    { echo "the validation did not report the files in the order the dry run loaded them"; return 1; }
  [ "$(jq -c '[.falco_load_results[] | select(.successful != true or .errors != [] or .warnings != []) | .name]' "$out/validate.json")" = '[]' ] ||
    { echo "a file loads with an error or a warning"; return 1; }
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
  # The namespace also holds the flow recorder, network-audit, an application of its own.
  [ "$(of_security_system "$OVERLAY")" = ConfigMap/security-system/app-template-defaults,Kustomization/flux-system/falco,Kustomization/flux-system/network-audit,Namespace/-/security-system,NetworkPolicy/security-system/default-deny ]
  # It waits for the definitions of the monitors it makes and of its network policy, and is Ready
  # once its release is.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "falco") | .spec.dependsOn | map(.name) | join(" ")' "$OVERLAY")" = "prometheus-operator-crds cilium" ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "falco") | .spec.wait' "$OVERLAY")" = true ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # Without the entry of Falco's ks.yaml, and without Falco's dashboard, which goes with Falco, the
  # cluster builds the namespace, its defaults, its default deny and the flow recorder, which
  # stays, and nothing of Falco.
  tree_without '/security-system/falco/ks.yaml$' '/monitoring/falco-dashboard/ks.yaml$'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ "$(of_security_system "$OVERLAY")" = ConfigMap/security-system/app-template-defaults,Kustomization/flux-system/network-audit,Namespace/-/security-system,NetworkPolicy/security-system/default-deny ]
  # With no entry of security-system, nor the dashboard, nothing of security-system.
  tree_without '/security-system(/|$)' '/monitoring/falco-dashboard/ks.yaml$'
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
  local item mounts reason reasons=() layout seen index in_ascender
  # A condition's namespace, alone or in a set, is ascender.
  local ASCENDER_NAMESPACE='k8s\.ns\.name (= "ascender"|in \([^)]*"ascender")'
  render
  daemonset
  falco_config
  # One key of the values, customRules, a map of rule files by name: it holds one file.
  [ "$(yq '.customRules | type' "$VALUES")" = '!!map' ]
  [ "$(yq '.customRules | keys | join(" ")' "$VALUES")" = exceptions.yaml ]
  # The file is fourteen items, in this order, each of which overrides the condition of one
  # placeholder macro of the image's rules: the first item for a placeholder replaces it with one
  # conjunction in parentheses, and each further one appends or and one conjunction to it. The
  # placeholders are the redirect rule's, the drop-and-execute rule's, the redirect rule's three
  # times more, the API server rule's seven times, the shell rule's and the log-clearing rule's: no
  # rule of the tree's own, no list, nothing appended to a rule and no rule turned off.
  local_rules
  [ "$(yq 'type' "$EXCEPTIONS")" = '!!seq' ]
  [ "$(yq 'length' "$EXCEPTIONS")" -eq 14 ]
  [ "$(yq '.[].macro' "$EXCEPTIONS" | paste -sd' ' -)" = "user_known_stand_streams_redirect_activities known_drop_and_execute_activities$(printf ' user_known_stand_streams_redirect_activities%.0s' 1 2 3)$(printf ' user_known_contact_k8s_api_server_activities%.0s' 1 2 3 4 5 6 7) user_shell_container_exclusions allowed_clear_log_files" ]
  [ "$(yq '.[].override.condition' "$EXCEPTIONS" | paste -sd' ' -)" = "replace replace append append append replace append append append append append append replace replace" ]
  seen=" "
  while read -r item; do
    [ "$(jq -r 'keys | join(" ")' <<<"$item")" = "condition macro override" ]
    if [[ $seen == *" $(jq -r '.macro' <<<"$item") "* ]]; then
      [ "$(jq -c '.override' <<<"$item")" = '{"condition":"append"}' ]
      [[ $(jq -r '.condition' <<<"$item") == "or ("*")" ]]
    else
      [ "$(jq -c '.override' <<<"$item")" = '{"condition":"replace"}' ]
      [[ $(jq -r '.condition' <<<"$item") == "("*")" ]]
      seen+="$(jq -r '.macro' <<<"$item") "
    fi
  done < <(yq -o json -I0 '.[]' "$EXCEPTIONS")
  # Each has its own reason in a block of comments directly above it, which starts with it, and
  # nothing but comments stands above the first. Each says what its workload does that the rule
  # matches and why, where the sources show it, or that the cause is not established, and what still
  # matches. The first's says what httpd does, and that a shell in that container still matches; the
  # second's names cilium-sysctlfix, says how it runs and why Talos makes that match, that it
  # excepts whatever that container runs at that one path, as it names a path and not a file, and
  # that any binary the container runs from an upper layer at any other path, cilium-sysctlfix
  # included, still matches.
  [ "$(grep -c '^# Reason: ' "$EXCEPTIONS")" -eq 14 ]
  [ "$(sed '/^- /,$d' "$EXCEPTIONS" | grep -vc '^#' || true)" -eq 0 ]
  mapfile -t reasons < <(awk '/^#/ { sub(/^# */, ""); block = block (block == "" ? "" : " ") $0; next }
    /^- / { print block; block = ""; next } { block = "" }' "$EXCEPTIONS")
  printf 'reason: %s\n' "${reasons[@]}"
  [ "${#reasons[@]}" -eq 14 ]
  for reason in "${reasons[@]}"; do
    [[ $reason == "Reason: "* && ${reason#Reason: } != *"Reason: "* ]]
  done
  [[ ${reasons[0]} == *httpd*dup2* && ${reasons[0]} == *"a shell"*"in that container still matches"* ]]
  [[ ${reasons[1]} == *cilium-sysctlfix*nsenter*Talos*overlay* ]]
  [[ ${reasons[1]} == *"names a path and not a file, so it excepts whatever that container"*"runs at that one path"* ]]
  [[ ${reasons[1]} == *"any binary that container runs from an upper layer at any other path, cilium-sysctlfix included, still matches"* ]]
  # Each of the twelve after them ends saying what still matches, held whole so that a reason that
  # leaves part of it out fails; and each that excepts in the namespace ascender then says the price
  # of a pod made to look like its container there, which whoever holds Ascender's admin login can
  # start (docs/kubernetes.md, Ascender).
  # Robot's report server: busybox's httpd, which matches twice for every request, and what still
  # matches in its container.
  [[ ${reasons[2]} == *httpd*twice* && ${reasons[2]} == *": a shell, or any other process, in that container still matches, and so does every other workload." ]]
  # The HA controller and the instance manager: the os/exec children's dup3 under the parent's name,
  # on files that are no sockets, so the cause is not established.
  [[ ${reasons[3]} == *agent*os/exec*dup3*forkAndExecInChild1*"not sockets"*"is not established"* ]]
  [[ ${reasons[3]} == *": a shell, or any other process, in that container still matches, and so does every other workload." ]]
  [[ ${reasons[4]} == *manager*os/exec*"not established either"* ]]
  [[ ${reasons[4]} == *": PostgreSQL itself, a shell, or any other process, in that container still matches, and so does that container in any other namespace. In ascender, a pod started through a container group's override with that container's name and image, running manager, is excepted as that container is (docs/kubernetes.md, Tuning)." ]]
  # The API server's: the dispatcher's reaper and the job pods that still match, with the price of a
  # pod made to look like the task container; the executables whose names the kernel cuts to 15
  # characters; the restore's Jobs, whose own containers still match; the sidecar, which the plugin
  # puts into a restore's Job as well as into each instance's pod.
  [[ ${reasons[5]} == *"awx-manage run_dispatcher"*awx_k8s_reaper*forks* ]]
  [[ ${reasons[5]} == *": any other process there, the task pod's ascender-ee, the web pod and every job pod as Ascender starts it still match, and so does every other workload. A pod started through a container group's override with that container's name and image, running awx-manage, is excepted as the task container is (docs/kubernetes.md, Tuning)." ]]
  [[ ${reasons[6]} == */usr/local/bin/ansible-operator*"15 characters"*ansible-operato* ]]
  [[ ${reasons[6]} == *": any other process in that container, kube-rbac-proxy beside it and every other workload still match. A pod started through a container group's override with that container's name and image, running ansible-operator, is excepted as the operator's container is (docs/kubernetes.md, Tuning)." ]]
  [[ ${reasons[7]} == *kubernetes_logs*/usr/bin/vector* && ${reasons[7]} == *": any other process in that container and every other workload still match." ]]
  [[ ${reasons[8]} == */ko-app/kyverno* && ${reasons[8]} == *": the init container kyverno-pre, the chart's Jobs, any other process and every other workload still match." ]]
  [[ ${reasons[9]} == */ko-app/reports-controller*"15 characters"*reports-control* && ${reasons[9]} == *": any other process and every other workload still match." ]]
  [[ ${reasons[10]} == *initdb*join* ]]
  [[ ${reasons[10]} == *": the one container of each Job of a restore, named after its role (full-recovery, import, pgbasebackup, snapshot-recovery), PostgreSQL and any other process in the three, and those containers in any other namespace, still match. The Barman Cloud plugin's sidecar, which a restore's Job can hold as well, is the next item's. In ascender, a pod started through a container group's override with the name of one of the three and that image, running manager, is excepted as the three are (docs/kubernetes.md, Tuning)." ]]
  [[ ${reasons[11]} == *plugin-barman-cloud*"/manager instance"*full-recovery*snapshot-recovery*"/manager restore"*reconcileJob*ObjectStore* ]]
  [[ ${reasons[11]} == *", in a restore's Job as in an instance's pod: any other process in it, the restore Job's own container, and that container in any other namespace, still match. In ascender, a pod started through a container group's override with that container's name and image, running manager, is excepted as the sidecar is (docs/kubernetes.md, Tuning)." ]]
  # The archiver's: system(), glibc's -- and the image's macro that misses it; what still matches,
  # COPY ... TO PROGRAM among it, and the price of the prefix.
  [[ ${reasons[12]} == *"system()"*"sh -c -- <command>"*"glibc 2.41"*postgres_running_cnpg* ]]
  [[ ${reasons[12]} == *": any other command PostgreSQL runs through a shell, a COPY ... TO PROGRAM among them, still matches; one that starts with that prefix, which a superuser can have it run, is excepted with the archiver's. In ascender, a pod started through a container group's override with that container's name and image, in which a process named postgres starts such a shell, is excepted as the archiver is (docs/kubernetes.md, Tuning)." ]]
  # containerd's unpacking: O_TRUNC, the image's macro that needs a process, the events' missing
  # process not established, and what still matches.
  [[ ${reasons[13]} == *O_TRUNC*containerd_activities*"not established"* ]]
  [[ ${reasons[13]} == *": the same truncation by any process in a container, and of any file outside that path, still matches." ]]
  # The items whose namespaces include ascender, the redirect rule's for the instance manager, the
  # API server rule's for the task container, the operator, the instance manager and the sidecar,
  # and the shell rule's: each reason ends with that price.
  in_ascender=""
  for index in "${!reasons[@]}"; do
    [[ $(yq ".[$index].condition" "$EXCEPTIONS") =~ $ASCENDER_NAMESPACE ]] || continue
    in_ascender+="${in_ascender:+ }$((index + 1))"
    [[ ${reasons[index]} == *". "*"started through a container group's override with "*" is excepted as "*" (docs/kubernetes.md, Tuning)." ]] ||
      { echo "item $((index + 1)) excepts in ascender, and its reason does not end with the price of a pod made to look like its container there"; return 1; }
  done
  echo "items in ascender: $in_ascender"
  [ "$in_ascender" = "5 6 7 11 12 13" ]
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
  # The docs say where the key is and show each item's condition as the values hold it.
  runtime_detection_docs
  [[ $DOCS == *customRules* ]]
  while read -r item; do
    [[ $DOCS == *"$(jq -r '.condition' <<<"$item")"* ]] || { echo "the docs do not show the condition of $(jq -r '.macro' <<<"$item")"; return 1; }
  done < <(yq -o json -I0 '.[]' "$EXCEPTIONS")
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

@test "Falco loads the local rules at the pinned version and compiles the redirect rule with its exceptions under a single negation" {
  local out="$BATS_TEST_TMPDIR/falco" rule="Redirect STDOUT/STDIN to Network Connection in Container"
  local conjunction compiled plain negates name expected macro conditions=()
  render
  daemonset
  falco_config
  local_rules
  workload "$REPO"
  # The exceptions appended for the same rule, as the tree makes them from what runs.
  for name in reports ha_controller instance_manager_redirect; do
    expected="$("${name}_exception" "$REPO")" || { echo "$expected"; return 1; }
    conditions+=("$expected")
  done
  docker_or_skip
  mkdir -p "$out/no-rules"
  # A dry run on what the pod holds exits 0, having loaded the image's rules and then the local
  # file, and every file validates in that order without an error or a warning.
  falco_loads "$out"
  # The rule is enabled, at priority Notice, and compiles to the image's condition with one
  # negation, of the conjunction of hello's four values or those of the report server, the HA
  # controller and the instance manager, which Falco prints without quotes.
  falco_image falco -l "$rule" >"$out/rule.json" 2>"$out/rule.err" || { cat "$out/rule.err"; return 1; }
  [ "$(jq -r '.rules | map(.info.name) | join(",")' "$out/rule.json")" = "$rule" ]
  [ "$(jq -r '.rules[0].info.enabled' "$out/rule.json")" = true ]
  [ "$(jq -r '.rules[0].info.priority' "$out/rule.json")" = Notice ]
  conjunction="(k8s.ns.name = $W_NAMESPACE and container.name = $W_CONTAINER and container.image.repository = $W_REPOSITORY and proc.name = $W_PROCESS)"
  negates="(evt.type in (dup, dup2, dup3) and container.id != host and evt.rawres in (0, 1, 2) and fd.type in (ipv4, ipv6) and not"
  compiled="$(jq -r '.rules[0].details.condition_compiled' "$out/rule.json")"
  echo "compiled: $compiled"
  FALCO_RULES_D="$out/no-rules" falco_image falco -L >"$out/image.json" 2>"$out/image.err" || { cat "$out/image.err"; return 1; }
  macro="$(jq -r '.macros[] | select(.info.name == "container") | .details.condition_compiled' "$out/image.json")"
  expected="$(printed "$macro" "$conjunction" "${conditions[@]}")"
  [ "$compiled" = "$negates $expected)" ] || { echo "and the tree's exceptions make it: $negates $expected)"; return 1; }
  # Tuning prints the rule as Falco compiles it.
  runtime_detection_docs
  [[ $DOCS == *"\`$compiled\`"* ]] || { echo "Tuning does not print the redirect rule as Falco compiles it: $compiled"; return 1; }
  # Without the local file the same rule negates the image's placeholder, which is never true: the
  # exceptions are all that the local rules change in it.
  plain="$(RULE="$rule" jq -r '.rules[] | select(.info.name == env.RULE) | .details.condition_compiled' "$out/image.json")"
  echo "the image's: $plain"
  [ "$plain" = "$negates evt.num = 0)" ]
  # With the local file Falco lists as many rules enabled as the image has without it, the same
  # ones, and nothing differs but the five rules the local file excepts from, this one, Drop and
  # execute new binary in container, Contact K8S API Server From Container, Run shell untrusted and
  # Clear Log Activities, and the five placeholders it overrides: no other rule, no other macro and
  # no list.
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
  echo "differing rules: $(differing rules); macros: $(differing macros); lists: $(differing lists)"
  [ "$(differing rules)" = "Clear Log Activities,Contact K8S API Server From Container,Drop and execute new binary in container,$rule,Run shell untrusted" ]
  [ "$(differing macros)" = allowed_clear_log_files,known_drop_and_execute_activities,user_known_contact_k8s_api_server_activities,user_known_stand_streams_redirect_activities,user_shell_container_exclusions ]
  [ -z "$(differing lists)" ]
}

@test "The drop-and-execute rule excepts Cilium's sysctl fix by namespace, container, image and path, and nothing wider" {
  local values=kubernetes/apps/base/kube-system/cilium/app/values.yaml ks=kubernetes/apps/base/kube-system/cilium/ks.yaml
  local release=kubernetes/apps/base/kube-system/cilium/app/helmrelease.yaml index other others
  render
  local_rules
  # The second item replaces the placeholder that the rule Drop and execute new binary in container
  # negates.
  [ "$(yq '.[1].macro' "$EXCEPTIONS")" = known_drop_and_execute_activities ] ||
    { echo "the local rules' second item overrides $(yq '.[1].macro' "$EXCEPTIONS"), not the placeholder known_drop_and_execute_activities"; return 1; }
  CONDITION="$(yq '.[1].condition' "$EXCEPTIONS")"
  echo "$CONDITION"
  # The condition is, to the letter, the one made of the sysctl fix of the Cilium that Flux
  # installs, read from the chart's render with its values and its post-renderer: the namespace of
  # the DaemonSet cilium, which its Kustomization targets, the name of the one container that runs
  # cilium-sysctlfix, which no other container of the render has, that container's image without
  # tag or digest and the path it runs the binary at, each compared for equality, joined by and, in
  # parentheses. So it holds no or, no not and no other field or operator, and names what runs. The
  # reading also holds the container's command to the chart's, which makes that path the node's.
  excepts_sysctl_fix "$REPO"
  # Why the container's name is one of the four: the agent and other init containers of the
  # DaemonSet run the same image in the same namespace, under other names, which the condition does
  # not except.
  others="$(CONTAINER_NAME="$C_CONTAINER" REPOSITORY="$C_REPOSITORY" yq '.spec.template.spec | (.containers // []) + (.initContainers // []) | .[]
    | select(.name != strenv(CONTAINER_NAME) and (.image | split("@") | .[0] | sub(":[^:/]*$", "")) == strenv(REPOSITORY)) | .name' "$BATS_TEST_TMPDIR/cilium-daemonset.yaml" | paste -sd' ' -)"
  echo "other containers of $C_REPOSITORY in the DaemonSet: $others"
  [[ " $others " == *" cilium-agent "* ]]
  [ "$(wc -w <<<"$others")" -ge 2 ]
  # A Cilium whose CNI directory, image, namespace or container's name moves is no longer what the
  # exception names, which then names nothing that runs; one whose container runs the binary
  # otherwise is no longer what its reason says; and with the sysctl fix off there is nothing left
  # to except. Each fails, saying what Cilium is now.
  index="$(CONTAINER_NAME="$C_CONTAINER" yq '.spec.template.spec.initContainers | to_entries | .[] | select(.value.name == strenv(CONTAINER_NAME)) | .key' "$BATS_TEST_TMPDIR/cilium-daemonset.yaml")"
  other="$(CONTAINER_NAME="$C_CONTAINER" yq '.spec.template.spec.initContainers | to_entries | map(select(.value.name != strenv(CONTAINER_NAME))) | .[0].key' "$BATS_TEST_TMPDIR/cilium-daemonset.yaml")"
  [[ $index =~ ^[0-9]+$ && $other =~ ^[0-9]+$ ]]
  # post_render PATCH: appends PATCH, a JSON patch of the DaemonSet cilium, to the post-renderer of
  # the HelmRelease of the tree's Cilium.
  post_render() {
    PATCH="$1" yq -i '.spec.postRenderers[0].kustomize.patches += [{"target": {"kind": "DaemonSet", "name": "cilium"}, "patch": strenv(PATCH)}]' "$TREE/$release"
  }
  tree_without
  yq -i '.cni.binPath = "/opt/example/bin"' "$TREE/$values"
  run excepts_sysctl_fix "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"the exception does not name Cilium's sysctl fix and it alone"*'and the sysctl fix is '*'proc.exepath = "/opt/example/bin/cilium-sysctlfix"'* ]]
  tree_without
  yq -i '.image.repository = "registry.example.com/cilium/cilium"' "$TREE/$values"
  run excepts_sysctl_fix "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"the exception does not name Cilium's sysctl fix and it alone"*'and the sysctl fix is '*'container.image.repository = "registry.example.com/cilium/cilium"'* ]]
  tree_without
  yq -i '.image.repository = "cilium/cilium"' "$TREE/$values"
  run excepts_sysctl_fix "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"the sysctl fix's image cilium/cilium:"*"is not written as the runtime reports it"* ]]
  # The Kustomization's target namespace moved alone leaves the release, and the DaemonSet, where
  # they were, which the reading refuses; moved with the release's, the comparison names the new one.
  tree_without
  yq -i '.spec.targetNamespace = "cilium-example"' "$TREE/$ks"
  run excepts_sysctl_fix "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"Cilium's DaemonSet cilium renders in the namespace $C_NAMESPACE, and its Kustomization targets cilium-example"* ]]
  yq -i '.spec.targetNamespace = "cilium-example" | .spec.storageNamespace = "cilium-example"' "$TREE/$release"
  run excepts_sysctl_fix "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"the exception does not name Cilium's sysctl fix and it alone"*'and the sysctl fix is '*'k8s.ns.name = "cilium-example"'* ]]
  tree_without
  post_render "$(printf -- '- op: replace\n  path: /spec/template/spec/initContainers/%s/name\n  value: sysctl-overwrites\n' "$index")"
  run excepts_sysctl_fix "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"the exception does not name Cilium's sysctl fix and it alone"*'and the sysctl fix is '*'container.name = "sysctl-overwrites"'* ]]
  tree_without
  post_render "$(printf -- '- op: replace\n  path: /spec/template/spec/initContainers/%s/name\n  value: %s\n' "$other" "$C_CONTAINER")"
  run excepts_sysctl_fix "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"more containers of Cilium's render than the sysctl fix are named $C_CONTAINER"* ]]
  # Run from the container's own mount of the CNI directory, the binary's path would be
  # the container's, not the node's.
  tree_without
  post_render "$(printf -- '- op: replace\n  path: /spec/template/spec/initContainers/%s/command/2\n  value: cp /usr/bin/cilium-sysctlfix /hostbin/cilium-sysctlfix; /hostbin/cilium-sysctlfix; rm /hostbin/cilium-sysctlfix\n' "$index")"
  run excepts_sysctl_fix "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"read the chart's init container that runs cilium-sysctlfix again"* ]]
  tree_without
  yq -i '.sysctlfix.enabled = false' "$TREE/$values"
  run excepts_sysctl_fix "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"no container of Cilium's render runs cilium-sysctlfix, so the exception for it in exceptions.yaml names nothing that runs: remove it"* ]]
}

@test "Falco compiles the drop-and-execute rule with the one exception for Cilium's sysctl fix under a single negation" {
  local out="$BATS_TEST_TMPDIR/falco" rule="Drop and execute new binary in container" conjunction compiled plain negates
  sysctl_fix "$REPO"
  render
  daemonset
  falco_config
  local_rules
  docker_or_skip
  mkdir -p "$out/no-rules"
  # A dry run on what the pod holds exits 0, having loaded the image's rules and then the local
  # file, and every file validates in that order without an error or a warning.
  falco_loads "$out"
  # The rule is enabled, at priority Critical, and compiles to the image's condition with one
  # negation, of the conjunction of the sysctl fix's four values, which Falco prints without quotes,
  # beside the negation of the image's list of images, which is empty.
  falco_image falco -l "$rule" >"$out/rule.json" 2>"$out/rule.err" || { cat "$out/rule.err"; return 1; }
  [ "$(jq -r '.rules | map(.info.name) | join(",")' "$out/rule.json")" = "$rule" ]
  [ "$(jq -r '.rules[0].info.enabled' "$out/rule.json")" = true ]
  [ "$(jq -r '.rules[0].info.priority' "$out/rule.json")" = Critical ]
  conjunction="(k8s.ns.name = $C_NAMESPACE and container.name = $C_CONTAINER and container.image.repository = $C_REPOSITORY and proc.exepath = $C_PATH)"
  negates="(evt.type in (execve, execveat) and container.id != host and proc.is_exe_upper_layer = true and not container.image.repository in () and not"
  compiled="$(jq -r '.rules[0].details.condition_compiled' "$out/rule.json")"
  echo "compiled: $compiled"
  [ "$compiled" = "$negates $conjunction)" ]
  # Without the local file the same rule negates the image's placeholder, which is never true: the
  # exception is all that the local rules change in it.
  FALCO_RULES_D="$out/no-rules" falco_image falco -l "$rule" >"$out/image.json" 2>"$out/image.err" || { cat "$out/image.err"; return 1; }
  [ "$(jq -r '.rules | map(.info.name) | join(",")' "$out/image.json")" = "$rule" ]
  [ "$(jq -r '.rules[0].info.enabled' "$out/image.json")" = true ]
  plain="$(jq -r '.rules[0].details.condition_compiled' "$out/image.json")"
  echo "the image's: $plain"
  [ "$plain" = "$negates evt.num = 0)" ]
}

@test "The redirect rule also excepts Robot's report server, Piraeus' HA controller and CloudNativePG's instance manager, each by namespace, container, image and process, and nothing wider" {
  local reports=kubernetes/apps/base/robot/robot/app/deployment-reports.yaml index app owner image named=""
  local piraeus=kubernetes/apps/base/piraeus-datastore/piraeus-operator/app/values.yaml
  local linstor=kubernetes/apps/base/piraeus-datastore/linstor-cluster/app/linstorcluster.yaml bullet robot_docs
  render
  local_rules
  # The third, fourth and fifth items append to the placeholder of the rule Redirect STDOUT/STDIN to
  # Network Connection in Container, which the first replaces.
  for index in 2 3 4; do
    item "$index"
    [ "$MACRO" = user_known_stand_streams_redirect_activities ] && [ "$OVERRIDE" = append ] ||
      { echo "the local rules' item $((index + 1)) is a $OVERRIDE of $MACRO, not an append to the redirect rule's placeholder"; return 1; }
  done
  # Each condition is, to the letter, or and the conjunction of four values read from what runs: the
  # namespace, the container's name, the image's repository as the runtime reports it and the
  # process, as the kernel names it. Robot's report server is the Deployment robot-reports as Flux
  # applies it, its process the first word of its command; the HA controller is the operator's
  # DaemonSet, on the image the operator's rendered image configuration gives it; and the instance
  # manager runs in PostgreSQL's container of every database the component cnpg-cluster makes, in
  # every namespace of the applications that take it, on the component's image.
  excepts_item 2 "Robot's report server" reports_exception "$REPO"
  excepts_item 3 "Piraeus' HA controller" ha_controller_exception "$REPO"
  excepts_item 4 "CloudNativePG's instance manager" instance_manager_redirect_exception "$REPO"
  # Why the container's name is one of the four for the report server: of every container and init
  # container of every workload the overlay builds into its namespace, only its own has that name and
  # image, so no other httpd there is excepted.
  robot_reports "$REPO"
  overlay
  for app in $(NS="$RR_NAMESPACE" yq -N 'select(.kind == "Kustomization" and .spec.targetNamespace == strenv(NS)) | .metadata.name' "$OVERLAY"); do
    build "$REPO" "$app"
    while read -r owner image; do
      [ "$(normalized "$image")" != "$RR_REPOSITORY" ] || named+=" $app:$owner"
    done < <(yq -o json -I0 '.' "$BUILD" | CONTAINER_NAME="$RR_CONTAINER" jq -r '. as $object
      | (.spec.template.spec // .spec.jobTemplate.spec.template.spec // (if .kind == "Pod" then .spec else null end)) // empty
      | (.containers // []) + (.initContainers // []) | .[] | select(.name == env.CONTAINER_NAME)
      | "\($object.kind)/\($object.metadata.name)/\(.name) \(.image)"')
  done
  echo "containers $RR_CONTAINER of $RR_REPOSITORY in $RR_NAMESPACE:$named"
  [ "$named" = " robot:Deployment/$RR_DEPLOYMENT/$RR_CONTAINER" ]
  # A report server renamed or moved to another image, an image configuration whose base for the HA
  # controller moves, by a document the values add or by the LinstorCluster's repository, or a
  # LinstorCluster that turns the HA controller off: each fails, saying what the workload is now.
  tree_without
  yq -i '.spec.template.spec.containers[0].name = "web"' "$TREE/$reports"
  run excepts_item 2 "Robot's report server" reports_exception "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"the exception does not name Robot's report server and it alone"*"and Robot's report server is or "*'container.name = "web"'* ]]
  tree_without
  yq -i '.spec.template.spec.containers[0].image = "registry.example.com/library/busybox:1.38.0"' "$TREE/$reports"
  run excepts_item 2 "Robot's report server" reports_exception "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"and Robot's report server is or "*'container.image.repository = "registry.example.com/library/busybox"'* ]]
  tree_without
  yq -i '.imageConfigOverride = [{"base": "registry.example.com/piraeus", "components": {"ha-controller": {"image": "piraeus-ha-controller", "tag": "v1.3.4"}}}]' "$TREE/$piraeus"
  run excepts_item 3 "Piraeus' HA controller" ha_controller_exception "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"and Piraeus' HA controller is or "*'container.image.repository = "registry.example.com/piraeus/piraeus-ha-controller"'* ]]
  tree_without
  yq -i '.spec.repository = "registry.example.com/linstor"' "$TREE/$linstor"
  run excepts_item 3 "Piraeus' HA controller" ha_controller_exception "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"and Piraeus' HA controller is or "*'container.image.repository = "registry.example.com/linstor/piraeus-ha-controller"'* ]]
  tree_without
  yq -i '.spec.highAvailabilityController.enabled = false' "$TREE/$linstor"
  run excepts_item 3 "Piraeus' HA controller" ha_controller_exception "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"the LinstorCluster turns the HA controller off, so the exception for it names nothing that runs: remove it"* ]]
  # Tuning lists each of the three with why it matches and what still matches, each line held whole.
  runtime_detection_docs
  for bullet in \
    "Robot's report server (\`robot\`, \`httpd\`, \`docker.io/library/busybox\`, \`httpd\`): busybox's \`httpd\` answers each request in a child that puts the connection on its standard streams, as \`hello\`'s does; a shell in that container still matches." \
    "Piraeus' HA controller (\`piraeus-datastore\`, \`ha-controller\`, \`quay.io/piraeusdatastore/piraeus-ha-controller\`, \`agent\`): Falco reports the agent's call on a socket, and the cause is not established (below); a shell, or any other process, in that container still matches." \
    "CloudNativePG's instance manager in PostgreSQL's container (the databases' namespaces, \`postgres\`, \`ghcr.io/cloudnative-pg/postgresql\`, \`manager\`): the same, the cause not established either; PostgreSQL itself in that container still matches."; do
    [[ $DOCS == *"- $bullet "* ]] || { echo "Tuning does not list: $bullet"; return 1; }
  done
  # Robot Framework's own section says that the report server's requests raise no event of that
  # rule, as the third item excepts its httpd.
  robot_docs="$(awk '/^### Robot Framework$/ { on = 1; next } on && /^##+ / { exit } on' "$REPO/docs/kubernetes.md" | tr '\n' ' ' | tr -s ' ')"
  [[ $robot_docs == *"Falco's rule \`Redirect STDOUT/STDIN to Network Connection in Container\` matches at priority Notice; the rule's items in [Tuning](#tuning) except the server's \`httpd\`, so its requests raise no event of that rule, and no alert reads a rule of that priority."* ]] ||
    { echo "the Robot Framework section does not say that the redirect rule's items except the report server's httpd"; return 1; }
}

@test "The API server rule excepts the controllers that call the API by design, each by namespace, container, image and process, and no job pod of Ascender" {
  local awx=kubernetes/apps/base/ascender/ascender/app/awx.yaml operator=kubernetes/apps/base/ascender/ascender-operator/app/helmrelease.yaml
  local vector=kubernetes/apps/base/monitoring/vector/app/values.yaml kyverno=kubernetes/apps/base/kyverno/kyverno/app/values.yaml
  local robot=kubernetes/apps/base/robot/robot/ks.yaml index job repository terms bullet sentence
  render
  local_rules
  # The sixth item replaces the placeholder of the rule Contact K8S API Server From Container, which
  # no earlier item overrides, and the six after it append to it.
  for index in 5 6 7 8 9 10 11; do
    item "$index"
    [ "$MACRO" = user_known_contact_k8s_api_server_activities ] && [ "$OVERRIDE" = "$([ "$index" -eq 5 ] && echo replace || echo append)" ] ||
      { echo "the local rules' item $((index + 1)) is a $OVERRIDE of $MACRO"; return 1; }
  done
  # Each condition is, to the letter, the conjunction of four values read from what runs, after or
  # for an append: Ascender's task container, which its operator names after the AWX, on the AWX's
  # image; the operator's own container, the one its Deployment names its default; the log
  # collector's container; Kyverno's admission and reports controllers' containers; the instance
  # manager in PostgreSQL's container and in the Jobs that create and join an instance; and the
  # Barman Cloud plugin's sidecar, on the image its chart gives it. The process is each executable's
  # name as the kernel cuts it: ansible-operato and reports-control.
  excepts_item 5 "Ascender's task container" task_exception "$REPO"
  excepts_item 6 "Ascender's operator" operator_exception "$REPO"
  excepts_item 7 "the log collector" vector_exception "$REPO"
  excepts_item 8 "Kyverno's admission controller" kyverno_exception "$REPO"
  excepts_item 9 "Kyverno's reports controller" reports_controller_exception "$REPO"
  excepts_item 10 "CloudNativePG's instance manager" instance_manager_exception "$REPO"
  excepts_item 11 "the Barman Cloud plugin's sidecar" sidecar_exception "$REPO"
  # No item names the container of Ascender's job pods, nor the image they and the task pod's
  # ascender-ee run, in any term: those pods, as Ascender starts them, stay watched whole.
  job="$(job_container)"
  [ "$(grep -c . <<<"$job")" -eq 1 ] || { echo "tests/ascender.bats models no one container of the job pod: $job"; return 1; }
  ascender_task "$REPO"
  echo "the job pod's container: $job; its images: $(paste -sd' ' <<<"$AT_JOB_REPOSITORIES")"
  [ -n "$AT_JOB_REPOSITORIES" ]
  while read -r terms; do
    [[ $terms != *"\"$job\""* ]] || { echo "an item names the job pod's container $job: $terms"; return 1; }
  done < <(yq '.[].condition' "$EXCEPTIONS" | grep -oE 'container\.name (= "[^"]*"|in \([^)]*\))')
  while read -r repository; do
    [ "$(grep -cF "\"$repository\"" "$EXCEPTIONS" || true)" -eq 0 ] || { echo "an item names the job pods' image $repository"; return 1; }
  done <<<"$AT_JOB_REPOSITORIES"
  # The log collector, Kyverno or the operator on another image, and an AWX of another name, whose
  # task container the operator names after it, are no longer what the items name; nor is a set of
  # databases that a fifth application joins, whose namespace the items then leave out. Each fails,
  # saying what the workload is now.
  tree_without
  yq -i '.image.repository = "registry.example.com/timberio/vector"' "$TREE/$vector"
  run excepts_item 7 "the log collector" vector_exception "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"and the log collector is or "*'container.image.repository = "registry.example.com/timberio/vector"'* ]]
  tree_without
  yq -i '.admissionController.container.image.registry = "registry.example.com" | .reportsController.image.registry = "registry.example.com"' "$TREE/$kyverno"
  run excepts_item 8 "Kyverno's admission controller" kyverno_exception "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"and Kyverno's admission controller is or "*'container.image.repository = "registry.example.com/kyverno/kyverno"'* ]]
  run excepts_item 9 "Kyverno's reports controller" reports_controller_exception "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"and Kyverno's reports controller is or "*'container.image.repository = "registry.example.com/kyverno/reports-controller"'* ]]
  tree_without
  yq -i '(.spec.postRenderers[0].kustomize.images[] | select(.name == "ghcr.io/ctrliq/ascender-operator")).newName = "registry.example.com/ctrliq/ascender-operator"' "$TREE/$operator"
  run excepts_item 6 "Ascender's operator" operator_exception "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"and Ascender's operator is or "*'container.image.repository = "registry.example.com/ctrliq/ascender-operator"'* ]]
  tree_without
  yq -i '.metadata.name = "automation"' "$TREE/$awx"
  run excepts_item 5 "Ascender's task container" task_exception "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"and Ascender's task container is ("*'container.name = "automation-task"'* ]]
  tree_without
  yq -i '.spec.components = ["../../../../../components/cnpg-cluster"] | .spec.postBuild.substitute.CNPG_CLUSTER_NAME = "robot-db" | .spec.postBuild.substitute.CNPG_NAMESPACE = "robot"' "$TREE/$robot"
  run excepts_item 10 "CloudNativePG's instance manager" instance_manager_exception "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"and CloudNativePG's instance manager is or "*'k8s.ns.name in ("ai-system", "ascender", "backstage", "kguardian", "robot")'* ]]
  run excepts_item 11 "the Barman Cloud plugin's sidecar" sidecar_exception "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"and the Barman Cloud plugin's sidecar is or "*'k8s.ns.name in ("ai-system", "ascender", "backstage", "kguardian", "robot")'* ]]
  # Tuning lists each with why it calls the API server and what still matches, each line held whole:
  # the restore's Jobs among it, whose own containers still match and into two of which the Barman
  # Cloud plugin puts its sidecar as well.
  runtime_detection_docs
  for bullet in \
    "Ascender's dispatcher (\`ascender\`, \`ascender-task\`, \`ghcr.io/ctrliq/ascender\`, \`awx-manage\`), which supervisord runs as \`awx-manage run_dispatcher\` and which lists the pods of the container group Ascender registers in a Kubernetes install every minute, to remove those of finished jobs (\`awx_k8s_reaper\` in \`awx/main/tasks/system.py\`, \`k8s_reaper\` in \`awx/settings/defaults.py\`), from workers that are forks of it; the task pod's \`ascender-ee\`, the web pod and the job pods as Ascender starts them still match." \
    "Ascender's operator (\`ascender\`, \`awx-manager\`, \`ghcr.io/ctrliq/ascender-operator\`, \`ansible-operato\`), which watches the \`AWX\` and what it makes; kube-rbac-proxy beside it still matches." \
    "The log collector (\`monitoring\`, \`vector\`, \`docker.io/timberio/vector\`, \`vector\`), which watches pods, namespaces and nodes for the metadata of its \`kubernetes_logs\` source; any other process in that container still matches." \
    "Kyverno's admission controller (\`kyverno\`, \`kyverno\`, \`reg.kyverno.io/kyverno/kyverno\`, \`kyverno\`) and reports controller (\`kyverno\`, \`controller\`, \`reg.kyverno.io/kyverno/reports-controller\`, \`reports-control\`), which watch the policies and what runs and write their reports; the init container \`kyverno-pre\` and the chart's Jobs still match." \
    "CloudNativePG's instance manager (the databases' namespaces, \`initdb\`, \`join\` and \`postgres\`, the component's image, \`manager\`), which reads and writes its \`Cluster\`; the one container of each Job of a restore, named after its role, \`full-recovery\`, \`import\`, \`pgbasebackup\` or \`snapshot-recovery\`, still matches, and so does PostgreSQL itself in the three." \
    "The Barman Cloud plugin's sidecar (the databases' namespaces, \`plugin-barman-cloud\`, \`ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar\`, \`manager\`), which reads its \`ObjectStore\` and the credentials it names, as \`/manager instance\` in each instance's pod and as \`/manager restore\` in the \`full-recovery\` or \`snapshot-recovery\` Job of a restore from the plugin's archive, where the plugin puts it as well (\`reconcileJob\` in \`internal/cnpgi/operator/lifecycle.go\`); it is excepted in both, and any other process in it, and the restore Job's own container, still match."; do
    [[ $DOCS == *"- $bullet "* ]] || { echo "Tuning does not list: $bullet"; return 1; }
  done
  # Tuning says what stays reported of the job pods, as Ascender starts them, and the price of every
  # item in ascender, where whoever holds Ascender's admin login can start a pod with any container's
  # name and image, as Ascender's own section says.
  for sentence in \
    "nor the image of the execution environment, which those pods and the task pod's \`ascender-ee\` run: a job pod as Ascender starts it, which calls the API server or puts a socket on its standard streams, stays reported." \
    "The price is the one [Ascender](#ascender) states, that the login is as strong as the namespace: whoever holds Ascender's admin login can start a pod in \`ascender\` through a container group's override with any container name and image, so a pod made to look like a container an item names there, running what the item names, is excepted as that container is." \
    "A pod made to look like the task container, \`ascender-task\` on \`ghcr.io/ctrliq/ascender\`, running \`awx-manage\`, is excepted from the API server rule as the task container is; one made to look like the operator's container, from the same rule; and one made to look like a database's, from the redirect, API server and shell rules."; do
    [[ $DOCS == *" $sentence "* ]] || { echo "Tuning does not say: $sentence"; return 1; }
  done
  [[ $(tr '\n' ' ' <"$REPO/docs/kubernetes.md" | tr -s ' ') == *"with any labels and so with the flows of any of the namespace's policies: the login is as strong as the namespace."* ]] ||
    { echo "Ascender's section no longer says that the login is as strong as the namespace"; return 1; }
}

@test "The shell rule excepts PostgreSQL's WAL archive command in every database of the CloudNativePG component by its fixed prefix, and nothing wider" {
  local cluster=kubernetes/components/cnpg-cluster/cluster.yaml robot=kubernetes/apps/base/robot/robot/ks.yaml
  render
  local_rules
  # The thirteenth item replaces the placeholder of the rule Run shell untrusted.
  item 12
  [ "$MACRO" = user_shell_container_exclusions ] && [ "$OVERRIDE" = replace ] ||
    { echo "the local rules' item 13 is a $OVERRIDE of $MACRO, not a replace of the shell rule's placeholder"; return 1; }
  # Its condition is, to the letter, the conjunction of the databases' namespaces, PostgreSQL's
  # container, the component's image, the server as the shell's parent and the fixed prefix of the
  # archive command as the shell's command line: the command CloudNativePG makes, up to the
  # segment's name, after glibc's sh -c --.
  excepts_item 12 "PostgreSQL's archiver" archiver_exception "$REPO"
  cnpg_databases "$REPO"
  echo "databases in: $PG_NAMESPACES; image: $PG_IMAGE"
  [[ $(yq '.[12].condition' "$EXCEPTIONS") == *"proc.cmdline startswith \"sh -c -- /controller/manager wal-archive "*"pg_wal/\")" ]]
  # The docs say why the image's own macro misses it, from the glibc of the image the component runs.
  runtime_detection_docs
  [[ $DOCS == *"postgres_running_cnpg"* && $DOCS == *"glibc 2.41"* && $DOCS == *"sh -c --"* ]]
  # Tuning lists it with what still matches, and gives how often a database archives as what is
  # expected, which only the cluster shows, not as a fact.
  [[ $DOCS == *"- \`Run shell untrusted\`, Notice, \`user_shell_container_exclusions\` replaced: PostgreSQL's archiver in every database of the component (the databases' namespaces, \`postgres\`, the component's image, the parent \`postgres\` and a command line that starts with the archive command up to \`pg_wal/\`); any other command PostgreSQL runs through a shell still matches. "* ]]
  [[ $DOCS == *"so \`ascender-db\` is expected to archive a segment about every five minutes, and a database nothing writes to, none; that is reasoning, which only the cluster shows (What no proof shows, below)."* ]]
  # A component on another image, or on an image of another Debian release, whose glibc is to be
  # read again, and a set of databases that a fifth application joins, fail, saying what the
  # databases are now.
  tree_without
  yq -i '.spec.imageName = "registry.example.com/cloudnative-pg/postgresql:18.6-standard-trixie"' "$TREE/$cluster"
  run excepts_item 12 "PostgreSQL's archiver" archiver_exception "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"and PostgreSQL's archiver is ("*'container.image.repository = "registry.example.com/cloudnative-pg/postgresql"'* ]]
  tree_without
  yq -i '.spec.imageName = "ghcr.io/cloudnative-pg/postgresql:18.6-standard-bookworm"' "$TREE/$cluster"
  run excepts_item 12 "PostgreSQL's archiver" archiver_exception "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"is not of Debian trixie, whose glibc 2.41 runs the command system() is given as sh -c --"* ]]
  tree_without
  yq -i '.spec.components = ["../../../../../components/cnpg-cluster"] | .spec.postBuild.substitute.CNPG_CLUSTER_NAME = "robot-db" | .spec.postBuild.substitute.CNPG_NAMESPACE = "robot"' "$TREE/$robot"
  run excepts_item 12 "PostgreSQL's archiver" archiver_exception "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"and PostgreSQL's archiver is ("*'k8s.ns.name in ("ai-system", "ascender", "backstage", "kguardian", "robot")'* ]]
  run excepts_item 4 "CloudNativePG's instance manager" instance_manager_redirect_exception "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"and CloudNativePG's instance manager is or "*'k8s.ns.name in ("ai-system", "ascender", "backstage", "kguardian", "robot")'* ]]
}

@test "The log-clearing rule excepts the truncation of log files inside containerd's image snapshots on the node, and nothing in a container" {
  render
  local_rules
  # The fourteenth item replaces the placeholder of the rule Clear Log Activities, with a condition
  # that is, to the letter, the image's macro container negated and the path under which containerd
  # unpacks the layers of the images it pulls: no process, as the events it is for carry none, and
  # no other field.
  item 13
  [ "$MACRO" = allowed_clear_log_files ] && [ "$OVERRIDE" = replace ] ||
    { echo "the local rules' item 14 is a $OVERRIDE of $MACRO, not a replace of the log-clearing rule's placeholder"; return 1; }
  excepts_item 13 "the truncation under containerd's snapshots" clear_log_exception "$REPO"
  # The docs give the path, say that why those events carry no process is not established, and what
  # still matches.
  runtime_detection_docs
  [[ $DOCS == *"\`$SNAPSHOTS\`, by what Falco places in no container; the same truncation in a container, and of any file outside that path, still matches"* ]]
  [[ $DOCS == *"Falco reports these events with no process and no container: why they carry no process is not established"* ]]
}

@test "No exception names a pod, a whole namespace or a whole rule" {
  local entry condition fields field
  render
  local_rules
  # Every item overrides one macro's condition, replacing or appending to it, and holds nothing else:
  # no rule, no list, no exceptions block, no enabled key that turns a rule off.
  [ "$(yq 'type' "$EXCEPTIONS")" = '!!seq' ]
  while read -r entry; do
    [ "$(jq -r 'keys | join(" ")' <<<"$entry")" = "condition macro override" ] || { echo "an item is not a macro's override: $entry"; return 1; }
    [[ $(jq -c '.override' <<<"$entry") =~ ^\{\"condition\":\"(replace|append)\"\}$ ]] || { echo "an item overrides otherwise: $entry"; return 1; }
  done < <(yq -o json -I0 '.[]' "$EXCEPTIONS")
  [ "$(grep -cE '^ *(- )?(rule|list|enabled|exceptions|append|required_engine_version):' "$EXCEPTIONS" || true)" -eq 0 ]
  # Each condition names only these fields: the namespace, the container's name, the image's
  # repository, the process by its name or path, its parent's name and its command line, and a file's
  # name; and the image's macro container. No pod's name, labels or other field, no ancestor
  # (proc.aname), no proc.exe, which the caller chooses, and no argument list.
  while read -r condition; do
    fields="$(sed -E 's/"[^"]*"//g' <<<"$condition" | grep -oE '[a-z][a-z0-9_]*(\.[a-z0-9_]+)+(\[[^]]*\])?' | LC_ALL=C sort -u | paste -sd' ' -)"
    for field in $fields; do
      case "$field" in
        k8s.ns.name | container.name | container.image.repository | proc.name | proc.exepath | proc.pname | proc.cmdline | fd.name) ;;
        *)
          echo "an item names $field: $condition"
          return 1
          ;;
      esac
    done
    [ -z "$(sed -E 's/"[^"]*"//g; s/[a-z][a-z0-9_]*(\.[a-z0-9_]+)+(\[[^]]*\])?//g; s/[(),=]/ /g' <<<"$condition" | tr ' ' '\n' | grep -vxE '|and|or|not|in|startswith|container' || true)" ] ||
      { echo "an item holds a word that is no field, operator or the macro container: $condition"; return 1; }
  done < <(yq '.[].condition' "$EXCEPTIONS")
  # Each condition is one conjunction in parentheses, after or for an append: within it, its values
  # and sets aside, no parenthesis, no or, and no not but the one before the macro container.
  while read -r entry; do
    condition="$(jq -r '.condition' <<<"$entry")"
    [ "$(jq -r '.override.condition' <<<"$entry")" = replace ] || condition="${condition#or }"
    [[ $condition == "("*")" ]] || { echo "an item is not one conjunction in parentheses: $condition"; return 1; }
    condition="$(sed -E 's/"[^"]*"/""/g; s/ in \([^()]*\)/ in set/g' <<<"${condition:1:${#condition}-2}")"
    [[ $condition != *[\(\)]* && " $condition " != *" or "* ]] || { echo "an item holds more than one conjunction: $condition"; return 1; }
    [[ " ${condition#not container and } " != *" not "* ]] || { echo "an item negates more than the macro container: $condition"; return 1; }
  done < <(yq -o json -I0 '.[]' "$EXCEPTIONS")
  # Every one but the fourteenth names the namespace, the container's name, the image's repository
  # and the process, so none takes a whole namespace, or everything that runs on an image or under a
  # container's name. The fourteenth names a file's path under containerd's snapshots and what Falco
  # places in no container, and nothing else.
  while read -r condition; do
    for field in 'k8s.ns.name ' 'container.name ' 'container.image.repository '; do
      [[ $condition == *"$field"* ]] || { echo "an item names no ${field% }: $condition"; return 1; }
    done
    [[ $condition == *"proc.name "* || $condition == *"proc.exepath "* || $condition == *"proc.pname "* ]] ||
      { echo "an item names no process: $condition"; return 1; }
  done < <(yq 'to_entries | .[] | select(.key != 13) | .value.condition' "$EXCEPTIONS")
  [ "$(yq '.[13].condition' "$EXCEPTIONS")" = "(not container and fd.name startswith \"$SNAPSHOTS\")" ]
}

# printed MACRO CONDITION...: the conditions of local rules as Falco prints them in a rule it
# compiles: each without the or an append starts with, its values unquoted where they hold no space,
# and the image's macro container as Falco compiles it, MACRO; one as it is, several joined by or, in
# parentheses.
printed() {
  local macro="$1" condition joined=""
  shift
  [[ $macro != *[/\&\\]* ]] || { echo "the macro container compiles to $macro, which this cannot write" >&2; return 1; }
  for condition in "$@"; do
    condition="$(sed -E 's/^or //; s/"([^" ]*)"/\1/g; s/(^|[( ])container([ )])/\1'"$macro"'\2/g' <<<"$condition")"
    joined+="${joined:+ or }$condition"
  done
  if [ "$#" -eq 1 ]; then printf '%s' "$joined"; else printf '(%s)' "$joined"; fi
}

@test "Falco compiles the API server, shell and log-clearing rules with the tree's exceptions under a single negation each" {
  local out="$BATS_TEST_TMPDIR/falco" rule priority plain compiled expected conditions=() name macro tail
  render
  daemonset
  falco_config
  local_rules
  runtime_detection_docs
  # The exceptions as the tree makes them, each read from what runs, as the proofs above read them.
  for name in task operator vector kyverno reports_controller instance_manager sidecar archiver clear_log; do
    expected="$("${name}_exception" "$REPO")" || { echo "$expected"; return 1; }
    conditions+=("$expected")
  done
  docker_or_skip
  mkdir -p "$out/no-rules"
  # A dry run on what the pod holds exits 0, having loaded the image's rules and then the local
  # file, and every file validates in that order without an error or a warning.
  falco_loads "$out"
  FALCO_RULES_D="$out/no-rules" falco_image falco -L >"$out/image.json" 2>"$out/image.err" || { cat "$out/image.err"; return 1; }
  macro="$(jq -r '.macros[] | select(.info.name == "container") | .details.condition_compiled' "$out/image.json")"
  echo "the macro container: $macro"
  [ -n "$macro" ]
  # Each rule is enabled, at its priority, and compiles to the image's condition with the image's
  # placeholder, which is never true, replaced by one negation of the tree's exceptions for it, each
  # in parentheses, joined by or: nothing else of the rule changes.
  for rule in "Contact K8S API Server From Container" "Run shell untrusted" "Clear Log Activities"; do
    case "$rule" in
      Contact*) priority=Notice expected="$(printed "$macro" "${conditions[@]:0:7}")" ;;
      Run*) priority=Notice expected="$(printed "$macro" "${conditions[7]}")" ;;
      Clear*) priority=Warning expected="$(printed "$macro" "${conditions[8]}")" ;;
    esac
    falco_image falco -l "$rule" >"$out/rule.json" 2>"$out/rule.err" || { cat "$out/rule.err"; return 1; }
    [ "$(jq -r '.rules | map(.info.name) | join(",")' "$out/rule.json")" = "$rule" ]
    [ "$(jq -r '.rules[0].info.enabled' "$out/rule.json")" = true ]
    [ "$(jq -r '.rules[0].info.priority' "$out/rule.json")" = "$priority" ]
    plain="$(RULE="$rule" jq -r '.rules[] | select(.info.name == env.RULE) | .details.condition_compiled' "$out/image.json")"
    [[ $plain == *" and not evt.num = 0)" ]] || { echo "without the local file, $rule does not end negating the placeholder: $plain"; return 1; }
    compiled="$(jq -r '.rules[0].details.condition_compiled' "$out/rule.json")"
    echo "$rule compiles to: $compiled"
    [ "$compiled" = "${plain% evt.num = 0)} $expected)" ] || { echo "and the tree's exceptions make it: ${plain% evt.num = 0)} $expected)"; return 1; }
    # Tuning prints the end of each rule, the negation of its items, as Falco compiles it.
    tail="${compiled#"${plain% and not evt.num = 0)}"}"
    [[ $DOCS == *"\`...$tail\`"* ]] || { echo "Tuning does not print the end of $rule as Falco compiles it: ...$tail"; return 1; }
  done
  # Why the tree's items and not the image's own macros, which the rules negate as well:
  # postgres_running_cnpg excepts the archive command after sh -c, without the --, and
  # containerd_activities the same path only for the process containerd.
  [[ $(jq -r '.macros[] | select(.info.name == "postgres_running_cnpg") | .info.condition' "$out/image.json") == *'proc.cmdline startswith "sh -c /controller/manager wal-archive"'* ]]
  [[ $(jq -r '.macros[] | select(.info.name == "containerd_activities") | .info.condition' "$out/image.json") == "(proc.name=containerd and (fd.name startswith \"$SNAPSHOTS\" or"* ]]
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
  [ "$(grep -ci automount "$BATS_TEST_TMPDIR/falco-post-render/chart.yaml" || true)" -eq 0 ]
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
