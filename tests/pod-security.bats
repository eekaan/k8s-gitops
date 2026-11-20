#!/usr/bin/env bats
# Proves features/pod-security.feature; each test carries its scenario's title.
# Needs kyverno (its podSecurity rule runs the Pod Security admission policy library), flux, kustomize,
# helm, yq and jq on PATH (the versions pinned for the repository). The tests on a fixture render are
# offline; the two on the tree render it with its charts pulled from their public registries.

# The tests run one at a time even where bats runs a file's tests side by side: the tests on the
# tree share one render, made by whichever of them comes first.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

setup_file() {
  # Helm's settings, and the Docker configuration it reads registry logins from, stay in the run's
  # own directory.
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/pod-security"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# tree NAME: a copy of the fixture in $BATS_TEST_TMPDIR/NAME, for the test to change.
tree() {
  mkdir -p "$BATS_TEST_TMPDIR/$1"
  cp -R "$FIXTURE/render" "$FIXTURE/exceptions.yaml" "$FIXTURE/versions.yaml" "$BATS_TEST_TMPDIR/$1/"
}

# check NAME [OPTION...]: runs the check on the tree NAME.
check() {
  local name=$1
  shift
  run "$REPO/scripts/pod-security-check" "$@" "$BATS_TEST_TMPDIR/$name/render" \
    "$BATS_TEST_TMPDIR/$name/exceptions.yaml" "$BATS_TEST_TMPDIR/$name/versions.yaml"
}

# object NAME FILE: the path of the one file named FILE in the tree NAME.
object() {
  local files=("$BATS_TEST_TMPDIR/$1"/render/*/*/"$2")
  [ "${#files[@]}" -eq 1 ] || { echo "$2 is not one file of $1: ${files[*]}"; return 1; }
  echo "${files[0]}"
}

# real_render: the render of this repository's tree, charts pulled, in $BATS_FILE_TMPDIR/render,
# made once for the file.
real_render() {
  REAL="$BATS_FILE_TMPDIR/render"
  if [ ! -d "$REAL" ]; then
    "$REPO/scripts/render" "$REAL.partial" >/dev/null
    mv "$REAL.partial" "$REAL"
  fi
}

@test "A namespace's enforced level is the lowest its workloads pass" {
  tree good
  check good
  [ "$status" -eq 0 ]
  [[ $output == *"web restricted"* ]]
  [[ $output == *"legacy baseline"* ]]
  [[ $output == *"agents privileged"* ]]
  # The same, with every workload's own level.
  check good --list
  [ "$status" -eq 0 ]
  [[ $output == *"web/Deployment/site restricted"* ]]
  [[ $output == *"web/CronJob/nightly restricted"* ]]
  [[ $output == *"legacy/Deployment/ledger baseline"* ]]
  [[ $output == *"agents/DaemonSet/collector privileged"* ]]
}

@test "A pod that needs more than its namespace enforces is refused, naming the checks it fails" {
  tree hostpath
  yq -i '.spec.template.spec.volumes = [{"name": "data", "hostPath": {"path": "/var/data"}}]
    | .spec.template.spec.containers[0].volumeMounts = [{"name": "data", "mountPath": "/data"}]' \
    "$(object hostpath Deployment.apps_web_site.yaml)"
  check hostpath
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web enforces restricted, but Deployment/site fails it"* ]]
  [[ $output == *hostPathVolumes* ]]
  # A pod that passes baseline only, in a namespace that enforces restricted.
  tree baseline-pod
  yq -i '.metadata.labels["pod-security.kubernetes.io/enforce"] = "restricted"
    | del(.metadata.labels["pod-security.kubernetes.io/audit"], .metadata.labels["pod-security.kubernetes.io/audit-version"],
      .metadata.labels["pod-security.kubernetes.io/warn"], .metadata.labels["pod-security.kubernetes.io/warn-version"])' \
    "$(object baseline-pod Namespace__legacy.yaml)"
  check baseline-pod
  [ "$status" -eq 1 ]
  [[ $output == *"namespace legacy enforces restricted, but Deployment/ledger fails it"* ]]
  [[ $output == *"allowPrivilegeEscalation"* ]]
  [[ $output != *"could enforce"* ]]
}

@test "a privileged init container of a DaemonSet and a hook Job are evaluated" {
  # Only the init container asks for privilege, in a namespace that enforces privileged for others.
  tree init
  yq '.metadata.name = "unlisted"
    | .spec.selector.matchLabels.app = "unlisted"
    | .spec.template.metadata.labels.app = "unlisted"
    | .spec.template.spec.initContainers[0].securityContext.privileged = true
    | .spec.template.spec.securityContext = {"runAsNonRoot": true, "seccompProfile": {"type": "RuntimeDefault"}}
    | del(.spec.template.spec.hostNetwork, .spec.template.spec.volumes, .spec.template.spec.containers[0].volumeMounts)
    | .spec.template.spec.containers[0].securityContext = {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}' \
    "$(object init DaemonSet.apps_agents_collector.yaml)" >"$BATS_TEST_TMPDIR/init/render/lab/agents/DaemonSet.apps_agents_unlisted.yaml"
  check init
  [ "$status" -eq 1 ]
  [[ $output == *"agents: DaemonSet/unlisted needs privileged"* ]]
  tree hook
  yq -i 'del(.spec.template.spec.containers[0].securityContext) | del(.spec.template.spec.securityContext)' \
    "$(object hook Job.batch_web_site-migrate.yaml)"
  check hook
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web enforces restricted, but Job/site-migrate fails it"* ]]
}

@test "A namespace that could enforce a lower level is refused" {
  # Every workload passes restricted, and the namespace enforces baseline.
  tree lenient
  yq -i '.metadata.labels["pod-security.kubernetes.io/enforce"] = "baseline"
    | .metadata.labels["pod-security.kubernetes.io/audit"] = "restricted"
    | .metadata.labels["pod-security.kubernetes.io/audit-version"] = "v1.37"
    | .metadata.labels["pod-security.kubernetes.io/warn"] = "restricted"
    | .metadata.labels["pod-security.kubernetes.io/warn-version"] = "v1.37"' "$(object lenient Namespace__web.yaml)"
  check lenient
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web enforces baseline, but could enforce restricted"* ]]
  # The levels are ordered by what they permit, not by their names: privileged permits more than
  # baseline, although it sorts after it.
  tree privileged-ledger
  yq -i '.metadata.labels["pod-security.kubernetes.io/enforce"] = "privileged"' "$(object privileged-ledger Namespace__legacy.yaml)"
  check privileged-ledger
  [ "$status" -eq 1 ]
  [[ $output == *"namespace legacy enforces privileged, but could enforce baseline"* ]]
  [[ $output != *"fails it"* ]]
  # A namespace whose only privileged workload is gone.
  tree gone
  rm "$(object gone DaemonSet.apps_agents_collector.yaml)"
  yq -i 'del(.exceptions[] | select(.workload == "DaemonSet/collector" or .workload == "DaemonSet/scanner"))' "$BATS_TEST_TMPDIR/gone/exceptions.yaml"
  rm "$(object gone Scanner.example.com_agents_main.yaml)"
  check gone
  [ "$status" -eq 1 ]
  [[ $output == *"namespace agents enforces privileged, but could enforce restricted"* ]]
}

@test "A workload above restricted is allowed only when it is listed with its reason" {
  tree unlisted
  yq -i 'del(.exceptions[] | select(.workload == "DaemonSet/collector"))' "$BATS_TEST_TMPDIR/unlisted/exceptions.yaml"
  check unlisted
  [ "$status" -eq 1 ]
  [[ $output == *"agents: DaemonSet/collector needs privileged"* ]]
  [[ $output == *"is not listed in the exceptions file"* ]]
  tree no-reason
  yq -i '(.exceptions[] | select(.workload == "DaemonSet/collector") | .reason) = ""' "$BATS_TEST_TMPDIR/no-reason/exceptions.yaml"
  check no-reason
  [ "$status" -eq 1 ]
  [[ $output == *"DaemonSet/collector"*"has no reason"* ]]
  tree missing-reason
  yq -i 'del(.exceptions[] | select(.workload == "Deployment/ledger") | .reason)' "$BATS_TEST_TMPDIR/missing-reason/exceptions.yaml"
  check missing-reason
  [ "$status" -eq 1 ]
  [[ $output == *"Deployment/ledger"*"has no reason"* ]]
  # An entry for a level the workload does not need, either way.
  tree too-high
  yq -i '(.exceptions[] | select(.workload == "Deployment/ledger") | .level) = "privileged"' "$BATS_TEST_TMPDIR/too-high/exceptions.yaml"
  check too-high
  [ "$status" -eq 1 ]
  [[ $output == *"lists Deployment/ledger at privileged, but it passes baseline"* ]]
  tree too-low
  yq -i '(.exceptions[] | select(.workload == "DaemonSet/collector") | .level) = "baseline"' "$BATS_TEST_TMPDIR/too-low/exceptions.yaml"
  check too-low
  [ "$status" -eq 1 ]
  [[ $output == *"lists DaemonSet/collector at baseline, but it needs privileged"* ]]
  # An entry for a workload the render does not hold, and for a pod an operator creates whose
  # custom resource is gone.
  tree stale
  yq -i '.exceptions += [{"namespace": "web", "workload": "Deployment/gone", "level": "baseline", "reason": "was removed"}]' "$BATS_TEST_TMPDIR/stale/exceptions.yaml"
  check stale
  [ "$status" -eq 1 ]
  [[ $output == *"lists Deployment/gone in web, which the render does not hold"* ]]
  tree orphan
  rm "$(object orphan Scanner.example.com_agents_main.yaml)"
  check orphan
  [ "$status" -eq 1 ]
  [[ $output == *"DaemonSet/scanner"*"Scanner/main"*"not in the render"* ]]
  # A pod made at run time is made by a custom resource: naming a workload the check evaluates
  # itself would lower that workload's level without evaluating it.
  tree borrowed
  yq -i '.exceptions += [{"namespace": "web", "workload": "Pod/sidecar", "created-by": "Deployment/site", "level": "privileged", "reason": "claims the level of a workload that is evaluated"}]' "$BATS_TEST_TMPDIR/borrowed/exceptions.yaml"
  check borrowed
  [ "$status" -eq 1 ]
  [[ $output == *"Pod/sidecar"*"Deployment/site"*"workload the check evaluates itself"* ]]
}

@test "An application that deploys into an undeclared namespace is refused" {
  tree ghost
  yq -i '.spec.targetNamespace = "ghost"' "$(object ghost Kustomization.kustomize.toolkit.fluxcd.io_flux-system_site.yaml)"
  check ghost
  [ "$status" -eq 1 ]
  [[ $output == *"namespace ghost has no Namespace manifest with a pod-security.kubernetes.io/enforce label"* ]]
  [[ $output == *"Kustomization/site"* ]]
  # A Namespace manifest without the label does not declare a level.
  tree unlabelled
  yq -i 'del(.metadata.labels["pod-security.kubernetes.io/enforce"])' "$(object unlabelled Namespace__web.yaml)"
  check unlabelled
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web has no Namespace manifest with a pod-security.kubernetes.io/enforce label"* ]]
  # A workload in a namespace nothing declares, which a chart may name without any Kustomization.
  tree stray
  yq -i '.metadata.namespace = "stray"' "$(object stray Deployment.apps_agents_console.yaml)"
  check stray
  [ "$status" -eq 1 ]
  [[ $output == *"namespace stray has no Namespace manifest"* ]]
  [[ $output == *"Deployment/console"* ]]
  # A namespace only an exception names has nothing deploying into it to name.
  tree nowhere
  yq -i '.exceptions += [{"namespace": "nowhere", "workload": "DaemonSet/ghost", "created-by": "Scanner/main", "level": "privileged", "reason": "made by an operator"}]' "$BATS_TEST_TMPDIR/nowhere/exceptions.yaml"
  check nowhere
  [ "$status" -eq 1 ]
  [[ $output == *"namespace nowhere has no Namespace manifest with a pod-security.kubernetes.io/enforce label"* ]]
  [[ $output != *"and  deploys"* && $output != *"label, and"* ]]
}

@test "An object in an undeclared namespace is refused" {
  # A Role says nothing of pods, but a custom resource in the same namespace may make them: the
  # namespace of every namespaced object is in use.
  tree role
  mkdir -p "$BATS_TEST_TMPDIR/role/render/lab/ghost"
  printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: Role\nmetadata:\n  name: reader\n  namespace: ghost\nrules: []\n' \
    >"$BATS_TEST_TMPDIR/role/render/lab/ghost/Role.rbac.authorization.k8s.io_ghost_reader.yaml"
  check role
  [ "$status" -eq 1 ]
  [[ $output == *"namespace ghost has no Namespace manifest with a pod-security.kubernetes.io/enforce label"* ]]
  [[ $output == *"Role/reader"* ]]
  # With the Namespace declared the same render passes.
  printf -- '---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: ghost\n  labels:\n    pod-security.kubernetes.io/enforce: restricted\n' \
    >"$BATS_TEST_TMPDIR/role/render/lab/ghost/Namespace__ghost.yaml"
  check role
  [ "$status" -eq 0 ]
}

@test "A namespace below restricted audits and warns at restricted at the cluster's minor" {
  local label=pod-security.kubernetes.io
  tree no-audit
  yq -i "del(.metadata.labels[\"$label/audit\"])" "$(object no-audit Namespace__legacy.yaml)"
  check no-audit
  [ "$status" -eq 1 ]
  [[ $output == *"namespace legacy enforces baseline and must audit and warn at restricted"* ]]
  tree no-warn
  yq -i "del(.metadata.labels[\"$label/warn\"])" "$(object no-warn Namespace__agents.yaml)"
  check no-warn
  [ "$status" -eq 1 ]
  [[ $output == *"namespace agents enforces privileged and must audit and warn at restricted"* ]]
  tree weak-audit
  yq -i ".metadata.labels[\"$label/audit\"] = \"baseline\"" "$(object weak-audit Namespace__legacy.yaml)"
  check weak-audit
  [ "$status" -eq 1 ]
  [[ $output == *"namespace legacy enforces baseline and must audit and warn at restricted"* ]]
  # The versions name the cluster's minor, each of them.
  tree old-audit
  yq -i ".metadata.labels[\"$label/audit-version\"] = \"v1.36\"" "$(object old-audit Namespace__agents.yaml)"
  check old-audit
  [ "$status" -eq 1 ]
  [[ $output == *"namespace agents enforces privileged and must pin audit and warn to the cluster minor"*"v1.37"* ]]
  tree old-warn
  yq -i ".metadata.labels[\"$label/warn-version\"] = \"latest\"" "$(object old-warn Namespace__legacy.yaml)"
  check old-warn
  [ "$status" -eq 1 ]
  [[ $output == *"namespace legacy enforces baseline and must pin audit and warn to the cluster minor"* ]]
  tree no-version
  yq -i "del(.metadata.labels[\"$label/warn-version\"])" "$(object no-version Namespace__legacy.yaml)"
  check no-version
  [ "$status" -eq 1 ]
  [[ $output == *"namespace legacy enforces baseline and must pin audit and warn to the cluster minor"* ]]
  # A namespace that enforces restricted needs neither.
  tree strict
  check strict
  [ "$status" -eq 0 ]
  [ "$(yq ".metadata.labels | has(\"$label/audit\")" "$(object strict Namespace__web.yaml)")" = false ]
}

@test "A cluster minor newer than the one the evaluator covers is refused" {
  # The evaluator is the Pod Security library of the Kyverno CLI pinned in mise.toml, whose record
  # there names the newest Kubernetes minor whose checks it is known to apply no more loosely than
  # the API server does.
  tree newer
  yq -i '.kubernetes = "v1.99.0"' "$BATS_TEST_TMPDIR/newer/versions.yaml"
  check newer
  [ "$status" -eq 1 ]
  [[ $output == *"versions.yaml names Kubernetes v1.99, newer than v1.37, the newest minor the Pod Security evaluator pinned in mise.toml covers"* ]]
}

@test "a ReplicaSet and a ReplicationController are evaluated" {
  tree good
  check good --list
  [ "$status" -eq 0 ]
  [[ $output == *"web/ReplicaSet/worker restricted"* ]]
  [[ $output == *"web/ReplicationController/pool restricted"* ]]
  local kind file
  for kind in ReplicaSet:ReplicaSet.apps_web_worker.yaml ReplicationController:ReplicationController__web_pool.yaml; do
    file=${kind#*:}
    kind=${kind%%:*}
    tree "$kind"
    yq -i '.spec.template.spec.volumes = [{"name": "data", "hostPath": {"path": "/var/data"}}]' "$(object "$kind" "$file")"
    check "$kind"
    [ "$status" -eq 1 ]
    [[ $output == *"namespace web enforces restricted, but $kind/"*"fails it"* ]]
    [[ $output == *hostPathVolumes* ]]
  done
}

@test "a pod template label whose value YAML 1.1 reads as a boolean is judged as the string it is" {
  # Gatekeeper's chart labels its pods gatekeeper.sh/system: "yes", which Kyverno's parser reads as
  # a boolean when the pod is handed to it unquoted and then refuses the pod.
  tree boolean
  yq -i '.spec.template.metadata.labels["gatekeeper.sh/system"] = "yes"' "$(object boolean ReplicaSet.apps_web_worker.yaml)"
  check boolean
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "a pod without a verdict from the evaluator fails the check" {
  # A run of the evaluator that reports on fewer pods than it was given leaves some pod unjudged,
  # which must not read as a pass.
  mkdir "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "{\\"results\\": []}"\n' >"$BATS_TEST_TMPDIR/bin/kyverno"
  chmod +x "$BATS_TEST_TMPDIR/bin/kyverno"
  tree silent
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" check silent
  [ "$status" -eq 1 ]
  [[ $output == *"kyverno gave no verdict on every one of the"* ]]
}

@test "The Flux controllers' namespace enforces a level and its controllers pass it" {
  real_render
  run "$REPO/scripts/pod-security-check" --list "$REAL" "$REPO/pod-security-exceptions.yaml" "$REPO/versions.yaml"
  [ "$status" -eq 0 ]
  [[ $output == *"flux-system restricted"* ]]
  local controller
  for controller in source-controller kustomize-controller helm-controller notification-controller source-watcher flux-operator; do
    [[ $output == *"flux-system/Deployment/$controller restricted"* ]] || { echo "$controller is not evaluated at restricted"; return 1; }
  done
  # The level is the FluxInstance's patch of the namespace: without it nothing declares it.
  rm -rf "$BATS_TEST_TMPDIR/unpatched"
  cp -R "$REAL" "$BATS_TEST_TMPDIR/unpatched"
  local instance=("$BATS_TEST_TMPDIR"/unpatched/*/*/FluxInstance*.yaml)
  [ "${#instance[@]}" -eq 1 ]
  yq -i '.spec.kustomize.patches |= map(select((.target.kind // "") != "Namespace"))' "${instance[0]}"
  run "$REPO/scripts/pod-security-check" "$BATS_TEST_TMPDIR/unpatched" "$REPO/pod-security-exceptions.yaml" "$REPO/versions.yaml"
  [ "$status" -eq 1 ]
  [[ $output == *"namespace flux-system has no Namespace manifest with a pod-security.kubernetes.io/enforce label"* ]]
  # The instance's patches of the controllers are evaluated too: one that puts a controller in the
  # host's network namespace fails the namespace's level.
  rm -rf "$BATS_TEST_TMPDIR/host-network"
  cp -R "$REAL" "$BATS_TEST_TMPDIR/host-network"
  instance=("$BATS_TEST_TMPDIR"/host-network/*/*/FluxInstance*.yaml)
  [ "${#instance[@]}" -eq 1 ]
  yq -i '.spec.kustomize.patches += [{"target": {"kind": "Deployment", "name": "source-controller"},
    "patch": "- op: add\n  path: /spec/template/spec/hostNetwork\n  value: true\n"}]' "${instance[0]}"
  run "$REPO/scripts/pod-security-check" "$BATS_TEST_TMPDIR/host-network" "$REPO/pod-security-exceptions.yaml" "$REPO/versions.yaml"
  [ "$status" -eq 1 ]
  [[ $output == *"namespace flux-system enforces restricted, but Deployment/source-controller fails it: hostNamespaces"* ]]
}

@test "the workloads whose values set the context restricted requires pass it" {
  # Each of these fails restricted with its chart's defaults; the application's values set the
  # seccomp profile or container context the level requires, so none is an exception.
  real_render
  run "$REPO/scripts/pod-security-check" --list "$REAL" "$REPO/pod-security-exceptions.yaml" "$REPO/versions.yaml"
  [ "$status" -eq 0 ]
  local workload
  for workload in kube-system/Deployment/descheduler kube-system/Deployment/reloader-reloader kube-system/Deployment/reflector \
    kube-system/Pod/vpa-test-crds-available kube-system/Pod/vpa-test-create-vpa kube-system/Pod/vpa-test-metrics-api-available \
    monitoring/Deployment/grafana-operator monitoring/StatefulSet/victoria-logs monitoring/Deployment/vmauth \
    piraeus-datastore/Deployment/piraeus-operator-controller-manager; do
    [[ $output == *"$workload restricted"* ]] || { echo "$workload does not pass restricted"; return 1; }
  done
}

@test "A Flux install patch that names a file is refused" {
  # A file beside the render, whose content a build that read it would show.
  local marker="marker-outside-the-render-$RANDOM$RANDOM" entry
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  printf '%s\n' '---' 'apiVersion: v1' 'kind: ConfigMap' 'metadata:' '  name: outside' 'data:' "  marker: $marker" \
    >"$BATS_TEST_TMPDIR/outside/patch.yaml"
  # The operator applies a patch and its target, which is all its patch type holds: a path, outside
  # the render or a URL, is refused, neither read nor fetched.
  for entry in "$BATS_TEST_TMPDIR/outside/patch.yaml" https://example.invalid/patch.yaml; do
    tree instance
    printf -- '---\napiVersion: fluxcd.controlplane.io/v1\nkind: FluxInstance\nmetadata:\n  name: flux\n  namespace: flux-system\nspec:\n  components: [source-controller]\n' \
      >"$BATS_TEST_TMPDIR/instance/render/lab/flux-system/FluxInstance.fluxcd.controlplane.io_flux-system_flux.yaml"
    P="$entry" yq -i '.spec.kustomize.patches = [{"path": strenv(P)}]' \
      "$BATS_TEST_TMPDIR/instance/render/lab/flux-system/FluxInstance.fluxcd.controlplane.io_flux-system_flux.yaml"
    check instance
    echo "$output"
    [ "$status" -eq 1 ]
    [[ $output == *"FluxInstance flux-system/flux: spec.kustomize.patches[0].path is not one of the fields kustomize"* ]]
    [[ $output != *"$marker"* ]]
    rm -rf "$BATS_TEST_TMPDIR/instance"
  done
}

@test "The custom resources that make an operator create pods ask for what restricted requires" {
  # The operators create these pods at run time, so the check cannot evaluate them. Each resource
  # sets the pod's security context, and that of every container it names, which are the
  # containers the operator's templates create at the pinned version where the operator leaves a
  # field restricted requires unset: the LINSTOR controller's, the CSI controller's and the
  # affinity controller's. The Grafana and Prometheus operators and VolSync set those container
  # fields themselves, and so does Ascender's operator, in the restricted mode its AWX asks for
  # (tests/ascender.bats). Each field must lie under a path the resource's definition declares, or the
  # API server prunes it. An entry: the resource, the path of the pod's spec in it, the name of the
  # pod's security context there, and the init containers and containers it names.
  real_render
  # The LinstorCluster names the containers of the operator's templates at the version recorded
  # beside them. Another version may name them otherwise, and a name its templates lack becomes a
  # container without an image, which the operator cannot apply: a new operator fails here until
  # its templates are read again.
  local cluster="$REPO/kubernetes/apps/base/piraeus-datastore/linstor-cluster/app/linstorcluster.yaml" recorded operator
  recorded="$(sed -n 's/^ *# piraeus-operator-templates: *\(v[0-9][0-9.]*\) *$/\1/p' "$cluster")"
  operator="$(yq -N '.spec.template.spec.containers[] | select(.name == "manager") | .image | sub("^.*:"; "")' \
    "$REAL"/*/piraeus-operator/Deployment.apps_piraeus-datastore_piraeus-operator-controller-manager.yaml)"
  echo "container names read from piraeus-operator ${recorded:-(no record)}; the render runs ${operator:-(none)}"
  [ -n "$recorded" ] || { echo "linstorcluster.yaml has no line '# piraeus-operator-templates: vX.Y.Z' beside its podTemplates"; return 1; }
  [ "$recorded" = "$operator" ] || {
    echo "the operator is $operator: read pkg/resources/cluster/{controller,csi-controller,affinity-controller} at $operator for the containers of each template, then update the podTemplates, the entries below and the record"
    return 1
  }
  local entries=(
    "Grafana grafana .spec.deployment.spec.template.spec securityContext - -"
    "Prometheus kube-prometheus-stack-prometheus .spec securityContext - -"
    "Alertmanager kube-prometheus-stack-alertmanager .spec securityContext - -"
    "LinstorCluster linstorcluster .spec.controller.podTemplate.spec securityContext run-migration linstor-controller"
    "LinstorCluster linstorcluster .spec.csiController.podTemplate.spec securityContext linstor-wait-api-online linstor-csi,csi-attacher,csi-livenessprobe,csi-provisioner,csi-snapshotter,csi-resizer"
    "LinstorCluster linstorcluster .spec.affinityController.podTemplate.spec securityContext - linstor-affinity-controller"
    "ReplicationSource volsync-demo .spec.restic moverSecurityContext - -"
    "ReplicationDestination volsync-demo-restore .spec.restic moverSecurityContext - -"
    "ReplicationDestination volsync-demo-drill .spec.restic moverSecurityContext - -"
    "AWX ascender .spec security_context_settings - -"
  )
  yq -N -o json -I0 'select(.kind == "CustomResourceDefinition")
    | {"group": .spec.group, "kind": .spec.names.kind, "versions": [.spec.versions[] | {"name": .name, "schema": .schema.openAPIV3Schema}]}' \
    "$REAL"/*/*/CustomResourceDefinition.*.yaml >"$BATS_TEST_TMPDIR/crds.jsonl"
  local entry kind name at context init containers files problems=()
  for entry in "${entries[@]}"; do
    read -r kind name at context init containers <<<"$entry"
    files=("$REAL"/*/*/"$kind".*_*_"$name".yaml)
    [ -f "${files[0]}" ] && [ "${#files[@]}" -eq 1 ] || { echo "the render holds no one $kind/$name"; return 1; }
    mapfile -t -O "${#problems[@]}" problems < <(yq -o json -I0 '.' "${files[0]}" | jq -r --slurpfile crds "$BATS_TEST_TMPDIR/crds.jsonl" \
      --arg at "$at" --arg context "$context" --arg init "$init" --arg containers "$containers" '
      # Whether a schema keeps the field at path $p: it declares it, or keeps unknown fields there.
      def kept($p):
        if ($p | length) == 0 then true
        elif ($p[0] | type) == "number" then
          (if .items then (.items | kept($p[1:])) else .["x-kubernetes-preserve-unknown-fields"] == true end)
        elif (.properties // {}) | has($p[0]) then (.properties[$p[0]] | kept($p[1:]))
        elif (.additionalProperties | type) == "object" then (.additionalProperties | kept($p[1:]))
        else .["x-kubernetes-preserve-unknown-fields"] == true end;
      . as $cr | (.kind + "/" + .metadata.name) as $id
      | (.apiVersion | split("/")) as [$group, $version]
      | ([$crds[] | select(.group == $group and .kind == $cr.kind) | .versions[] | select(.name == $version) | .schema] | first) as $schema
      | getpath($at | ltrimstr(".") | split(".")) as $pod
      | def names($list): $list | split(",") | map(select(. != "-"));
      if $schema == null then "\($id): the render holds no definition of \($cr.apiVersion) \($cr.kind)"
      else
        ($cr.spec | paths(scalars) as $p | select($schema.properties.spec | kept($p) | not)
          | "\($id): its definition does not declare spec.\($p | map(tostring) | join("."))"),
        (if $pod[$context].runAsNonRoot != true then "\($id): \($at).\($context).runAsNonRoot is not true" else empty end),
        (if ($pod[$context].runAsUser // 1) == 0 then "\($id): \($at).\($context).runAsUser is root" else empty end),
        (if $pod[$context].seccompProfile.type != "RuntimeDefault" then "\($id): \($at).\($context).seccompProfile.type is not RuntimeDefault" else empty end),
        (["initContainers", names($init)], ["containers", names($containers)]) as [$field, $wanted]
        | $wanted[] as $c | ([$pod[$field][]? | select(.name == $c)] | first) as $container
        | if $container == null then "\($id): \($at).\($field) names no \($c)"
          elif $container.securityContext.allowPrivilegeEscalation != false then "\($id): \($at).\($field) \($c) does not set allowPrivilegeEscalation to false"
          elif ($container.securityContext.capabilities.drop // [] | index("ALL")) == null then "\($id): \($at).\($field) \($c) does not drop ALL capabilities"
          else empty end
      end')
  done
  printf '%s\n' "${problems[@]}"
  [ "${#problems[@]}" -eq 0 ]
}

# isolate FILE ISOLATION: gives the pod template of the workload in FILE the isolation ISOLATION:
# userns sets hostUsers to false, gvisor or kata sets that runtime class, hostUsers=true and
# runtimeClassName=CLASS set those, and none takes both fields away.
isolate() {
  local spec
  case "$(yq '.kind' "$1")" in
    CronJob) spec=.spec.jobTemplate.spec.template.spec ;;
    Pod) spec=.spec ;;
    *) spec=.spec.template.spec ;;
  esac
  yq -i "del($spec.hostUsers, $spec.runtimeClassName)" "$1"
  case $2 in
    userns) yq -i "$spec.hostUsers = false" "$1" ;;
    hostUsers=true) yq -i "$spec.hostUsers = true" "$1" ;;
    gvisor | kata) yq -i "$spec.runtimeClassName = \"$2\"" "$1" ;;
    runtimeClassName=*) C="${2#runtimeClassName=}" yq -i "$spec.runtimeClassName = strenv(C)" "$1" ;;
    none) ;;
    *) echo "isolate: no isolation $2"; return 1 ;;
  esac
}

# sandbox NAME TIER: labels the namespace web of the tree NAME with the sandbox tier TIER, and every
# workload in it gets the isolation TIER asks for.
sandbox() {
  local file
  T="$2" yq -i '.metadata.labels["k8s-gitops/sandbox"] = strenv(T)' "$(object "$1" Namespace__web.yaml)"
  for file in "$(dirname "$(object "$1" Namespace__web.yaml)")"/*.yaml; do
    case "$(yq '.kind' "$file")" in
      Pod | Deployment | StatefulSet | DaemonSet | ReplicaSet | ReplicationController | Job | CronJob) isolate "$file" "$2" ;;
    esac
  done
}

@test "A pod template in a sandbox namespace without its tier's isolation is refused" {
  local tier entry file isolation workload want ns pool
  # A runtime tier names its class exactly, so a class that only starts with its name is refused.
  local -A cases=(
    [userns]="CronJob.batch_web_nightly.yaml:none Deployment.apps_web_site.yaml:hostUsers=true ReplicaSet.apps_web_worker.yaml:gvisor
      StatefulSet.apps_web_db.yaml:none Pod__web_bare.yaml:kata"
    [gvisor]="CronJob.batch_web_nightly.yaml:none Deployment.apps_web_site.yaml:kata Job.batch_web_site-migrate.yaml:userns
      ReplicaSet.apps_web_worker.yaml:runtimeClassName=gvisor-debug StatefulSet.apps_web_db.yaml:userns Pod__web_bare.yaml:none"
    [kata]="CronJob.batch_web_nightly.yaml:none Deployment.apps_web_site.yaml:gvisor ReplicationController__web_pool.yaml:userns
      Job.batch_web_site-migrate.yaml:runtimeClassName=kata-qemu StatefulSet.apps_web_db.yaml:gvisor Pod__web_bare.yaml:hostUsers=true"
  )
  for tier in userns gvisor kata; do
    # Every workload of web meets the tier: the check passes, and only web's line names a tier.
    rm -rf "$BATS_TEST_TMPDIR/tier"
    tree tier
    # web also gets a StatefulSet and a bare pod, of pool's template, so that every kind a pod comes
    # from is among the cases.
    pool="$(object tier ReplicationController__web_pool.yaml)"
    yq '.apiVersion = "apps/v1" | .kind = "StatefulSet" | .metadata.name = "db" | .spec.serviceName = "db"
      | .spec.selector = {"matchLabels": {"app": "db"}} | .spec.template.metadata.labels.app = "db"' "$pool" \
      >"$(dirname "$pool")/StatefulSet.apps_web_db.yaml"
    yq '{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "bare", "namespace": "web"}, "spec": .spec.template.spec}' "$pool" \
      >"$(dirname "$pool")/Pod__web_bare.yaml"
    sandbox tier "$tier"
    check tier
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx "web restricted 7 workloads, 0 listed, sandbox $tier" <<<"$output"
    grep -qx 'legacy baseline 1 workloads, 1 listed' <<<"$output"
    grep -qx 'agents privileged 2 workloads, 2 listed' <<<"$output"
    [ "$(grep -c sandbox <<<"$output")" -eq 1 ]
    want="runtimeClassName: $tier"
    [ "$tier" != userns ] || want="hostUsers: false"
    # One workload without the tier's isolation, or with another tier's, is refused by name, and no
    # other workload is.
    for entry in ${cases[$tier]}; do
      file=${entry%%:*}
      isolation=${entry#*:}
      rm -rf "$BATS_TEST_TMPDIR/refused"
      cp -R "$BATS_TEST_TMPDIR/tier" "$BATS_TEST_TMPDIR/refused"
      isolate "$(object refused "$file")" "$isolation"
      workload="$(yq '.kind + "/" + .metadata.name' "$(object refused "$file")")"
      check refused
      echo "$tier, $workload $isolation: $output"
      [ "$status" -eq 1 ]
      [[ $output == *"pod-security-check: namespace web is of the $tier sandbox tier, but $workload does not set $want"* ]]
      [ "$(grep -c 'sandbox tier' <<<"$output")" -eq 1 ]
    done
    # The exceptions file lists levels, not tiers: in legacy and agents, labelled with the tier and
    # their workloads left without it, the two the file lists are refused by name as the one it
    # does not list is.
    rm -rf "$BATS_TEST_TMPDIR/listed"
    tree listed
    for ns in legacy agents; do
      T="$tier" yq -i '.metadata.labels["k8s-gitops/sandbox"] = strenv(T)' "$(object listed "Namespace__$ns.yaml")"
    done
    check listed
    echo "$tier, legacy and agents: $output"
    [ "$status" -eq 1 ]
    for workload in "legacy Deployment/ledger" "agents DaemonSet/collector" "agents Deployment/console"; do
      [[ $output == *"pod-security-check: namespace ${workload%% *} is of the $tier sandbox tier, but ${workload#* } does not set $want"* ]]
    done
    [ "$(grep -c '^pod-security-check: ' <<<"$output")" -eq 3 ]
  done
}

@test "A sandbox namespace with an unknown tier is refused" {
  local value shown
  for value in firecracker Gvisor ""; do
    rm -rf "$BATS_TEST_TMPDIR/unknown"
    tree unknown
    # web's workloads meet gvisor, and idle has no workload.
    sandbox unknown gvisor
    V="$value" yq -i '.metadata.labels["k8s-gitops/sandbox"] = strenv(V)' "$(object unknown Namespace__web.yaml)"
    mkdir -p "$BATS_TEST_TMPDIR/unknown/render/lab/idle"
    V="$value" yq -n '{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "idle",
      "labels": {"pod-security.kubernetes.io/enforce": "restricted", "k8s-gitops/sandbox": strenv(V)}}}' \
      >"$BATS_TEST_TMPDIR/unknown/render/lab/idle/Namespace__idle.yaml"
    check unknown
    echo "$output"
    [ "$status" -eq 1 ]
    shown=${value:-'""'}
    [[ $output == *"pod-security-check: namespace web carries k8s-gitops/sandbox $shown, which is not userns, gvisor or kata"* ]]
    [[ $output == *"pod-security-check: namespace idle carries k8s-gitops/sandbox $shown, which is not userns, gvisor or kata"* ]]
    [ "$(grep -c '^pod-security-check: ' <<<"$output")" -eq 2 ]
  done
}

@test "A sandbox namespace that holds a VolSync or CloudNativePG resource is refused" {
  local dir
  tree operators
  sandbox operators kata
  dir="$(dirname "$(object operators Namespace__web.yaml)")"
  # The objects of components/volsync and components/cnpg-cluster that make an operator create pods.
  yq -n '{"apiVersion": "volsync.backube/v1alpha1", "kind": "ReplicationSource", "metadata": {"name": "site", "namespace": "web"},
    "spec": {"sourcePVC": "site", "restic": {"repository": "site-volsync"}}}' >"$dir/ReplicationSource.volsync.backube_web_site.yaml"
  yq -n '{"apiVersion": "volsync.backube/v1alpha1", "kind": "ReplicationDestination", "metadata": {"name": "site-restore", "namespace": "web"},
    "spec": {"trigger": {"manual": "restore"}, "restic": {"repository": "site-volsync"}}}' >"$dir/ReplicationDestination.volsync.backube_web_site-restore.yaml"
  yq -n '{"apiVersion": "postgresql.cnpg.io/v1", "kind": "Cluster", "metadata": {"name": "site-db", "namespace": "web"},
    "spec": {"instances": 1}}' >"$dir/Cluster.postgresql.cnpg.io_web_site-db.yaml"
  # One a chart makes, with no namespace of its own: it is installed into its release's, which
  # helm-controller's labels name through the HelmRelease.
  yq -n '{"apiVersion": "helm.toolkit.fluxcd.io/v2", "kind": "HelmRelease", "metadata": {"name": "site", "namespace": "web"},
    "spec": {"chartRef": {"kind": "OCIRepository", "name": "site"}}}' >"$dir/HelmRelease.helm.toolkit.fluxcd.io_web_site.yaml"
  yq -n '{"apiVersion": "volsync.backube/v1alpha1", "kind": "ReplicationSource", "metadata": {"name": "chart-backup",
      "labels": {"helm.toolkit.fluxcd.io/name": "site", "helm.toolkit.fluxcd.io/namespace": "web"}},
    "spec": {"sourcePVC": "site", "restic": {"repository": "site-volsync"}}}' >"$dir/ReplicationSource.volsync.backube_chart-backup.yaml"
  check operators
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"pod-security-check: namespace web is of the kata sandbox tier, but ReplicationSource/site makes pods its operator gives no tier (components/volsync)"* ]]
  [[ $output == *"pod-security-check: namespace web is of the kata sandbox tier, but ReplicationDestination/site-restore makes pods its operator gives no tier (components/volsync)"* ]]
  [[ $output == *"pod-security-check: namespace web is of the kata sandbox tier, but Cluster/site-db makes pods its operator gives no tier (components/cnpg-cluster)"* ]]
  [[ $output == *"pod-security-check: namespace web is of the kata sandbox tier, but ReplicationSource/chart-backup makes pods its operator gives no tier (components/volsync)"* ]]
  [ "$(grep -c '^pod-security-check: ' <<<"$output")" -eq 4 ]
  # The same objects in a namespace of no tier are no concern of the tiers.
  yq -i 'del(.metadata.labels["k8s-gitops/sandbox"])' "$(object operators Namespace__web.yaml)"
  check operators
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qx 'web restricted 5 workloads, 0 listed' <<<"$output"
}

@test "The tree passes" {
  run just --justfile "$REPO/justfile" pod-security-check
  echo "$output"
  [ "$status" -eq 0 ]
  # The recipe reports what it checked, so one that checks nothing fails here.
  [[ $output == *"flux-system restricted"* ]]
  [[ $output == *"kube-system privileged"* ]]
  [[ $output == *"monitoring privileged"* ]]
  [[ $output == *"piraeus-datastore privileged"* ]]
}
