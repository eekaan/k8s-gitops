#!/usr/bin/env bats
# Proves features/autoscaling.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq, jq and grep on PATH (the versions pinned for the repository).
# Each chart is pulled once per run from its public registry or repository; building and rendering
# are offline.

# The tests run one at a time even where bats runs a file's tests side by side: a test that starts
# while another pulls a chart finds the chart's directory before the chart is in it.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

setup_file() {
  # Helm's cache and registry settings stay in the run's own directory, and so does the Docker
  # configuration helm falls back to for credentials, so no login is read.
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG"
  # flux build rewrites the kustomization.yaml of what it builds and puts it back afterwards, so it
  # builds a copy of the applications, never this checkout. The cluster directories stay behind.
  export TREE="$BATS_FILE_TMPDIR/tree"
  mkdir -p "$TREE/kubernetes"
  cp -R "$BATS_TEST_DIRNAME/../kubernetes/apps" "$BATS_TEST_DIRNAME/../kubernetes/components" "$TREE/kubernetes/"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLUSTER="$REPO/kubernetes/clusters/lab-sto2"
  KUBE="$(yq -e '.kubernetes' "$REPO/versions.yaml")"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# app_dir APP: sets APP_DIR to the directory of the application APP, in whichever namespace
# directory it is, relative to the tree.
app_dir() {
  local -a dirs=("$TREE"/kubernetes/apps/base/*/"$1")
  [ -f "${dirs[0]}/ks.yaml" ] || { echo "$1: no application directory with a ks.yaml"; return 1; }
  APP_DIR="${dirs[0]#"$TREE"/}"
}

# built APP: the application as Flux applies it: its app/ built with its ks.yaml, substituting
# strictly the variables of the cluster's example key lists. Writes $BATS_TEST_TMPDIR/APP-built.yaml
# and sets BUILT and APP_DIR.
built() {
  local app=$1 vars="$BATS_TEST_TMPDIR/example-vars.yaml" ks="$BATS_TEST_TMPDIR/$1-ks.yaml"
  app_dir "$app"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$vars"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = $vars' "$vars" "$TREE/$APP_DIR/ks.yaml" >"$ks"
  BUILT="$BATS_TEST_TMPDIR/$app-built.yaml"
  # flux build reads only paths below the working directory.
  (cd "$TREE" && flux build kustomization "$app" --path "./$APP_DIR/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute) >"$BUILT"
}

# render APP [HELM TEMPLATE ARGS]: renders the chart that APP's HelmRelease installs, built as
# built() builds it, from the OCIRepository or HelmRepository it names at its pinned version, with
# the values helm-controller gives the chart: those of the ConfigMap the HelmRelease reads, then the
# HelmRelease's own over them. The ServiceMonitor and PodMonitor APIs count as present, as group
# versions and as kinds, as charts test for either, so that only the values keep such objects out.
# The definitions in a chart's crds directory are included unless the arguments say otherwise by
# naming --skip-crds. Writes $BATS_TEST_TMPDIR/APP.yaml and sets RENDERED, CHART, VALUES and INLINE.
render() {
  local app=$1 url tag name release namespace pulled chart repo crds=--include-crds
  shift
  [ "${1:-}" = --skip-crds ] && { crds=; shift; }
  built "$app"
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  VALUES="$BATS_TEST_TMPDIR/$app-values.yaml"
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\") | .data[\"values.yaml\"]" "$BUILT" >"$VALUES"
  [ -s "$VALUES" ] || { echo "$app: no values in the ConfigMap $name its HelmRelease reads"; return 1; }
  INLINE="$BATS_TEST_TMPDIR/$app-inline.yaml"
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$BUILT" >"$INLINE"
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  if [ -n "$url" ]; then
    tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
    pulled="$BATS_FILE_TMPDIR/charts/$app/$tag"
    if [ ! -d "$pulled" ]; then
      mkdir -p "$pulled"
      helm pull "$url" --version "$tag" --destination "$pulled"
    fi
  else
    chart="$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.chart' "$BUILT")"
    tag="$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.version' "$BUILT")"
    repo="$(yq -N 'select(.kind == "HelmRepository") | .spec.url' "$BUILT")"
    [ -n "$chart" ] && [ -n "$tag" ] && [ -n "$repo" ] || { echo "$app: no chart source"; return 1; }
    pulled="$BATS_FILE_TMPDIR/charts/$app/$tag"
    if [ ! -d "$pulled" ]; then
      mkdir -p "$pulled"
      helm pull "$chart" --repo "$repo" --version "$tag" --destination "$pulled"
    fi
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  RENDERED="$BATS_TEST_TMPDIR/$app.yaml"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" $crds "$@" \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor \
    --api-versions monitoring.coreos.com/v1/PodMonitor \
    --values "$VALUES" --values "$INLINE" >"$RENDERED"
}

# monitor_targets: one line per ServiceMonitor or PodMonitor in $RENDERED, "Kind/name -> Kind/name"
# naming each rendered object it scrapes: for a ServiceMonitor, a Service whose labels its selector
# matches and that names every port it scrapes; for a PodMonitor, a workload whose pod template
# does so. A monitor that scrapes none of them ends in "-> none".
monitor_targets() {
  yq -N -o json -I0 'select(. != null)' "$RENDERED" | jq -rs '. as $all | .[]
    | select(.kind == "ServiceMonitor" or .kind == "PodMonitor") | . as $monitor
    | ($monitor.spec.selector.matchLabels // {}) as $selector
    | [($monitor.spec.endpoints // $monitor.spec.podMetricsEndpoints // [])[].port] as $ports
    | [$all[] | if $monitor.kind == "ServiceMonitor" then
          select(.kind == "Service")
          | {name: ("Service/" + .metadata.name), labels: (.metadata.labels // {}), ports: [.spec.ports[]?.name]}
        else
          select(.kind == "Deployment" or .kind == "DaemonSet" or .kind == "StatefulSet")
          | {name: (.kind + "/" + .metadata.name), labels: (.spec.template.metadata.labels // {}),
             ports: [.spec.template.spec.containers[].ports[]?.name]}
        end
      | select(.labels as $labels | ($selector | length > 0)
          and ($selector | to_entries | all($labels[.key] == .value)))
      | select(.ports as $named | ($ports | length > 0) and ($ports | all(. as $port | any($named[]; . == $port))))
      | .name] as $targets
    | "\($monitor.kind)/\($monitor.metadata.name) -> \(if ($targets | length) > 0 then $targets | join(" ") else "none" end)"'
}

# pod_templates FILE: every pod template in FILE, one JSON object per line, with the workload's
# kind and name and its template's pod spec. Hook pods that Helm runs only for `helm test` are not
# part of what the release runs and are left out.
pod_templates() {
  yq -N -o json -I0 'select(. != null)' "$1" | jq -c '
    select(.metadata.annotations["helm.sh/hook"] // "" | test("test") | not)
    | select(.kind == "Deployment" or .kind == "DaemonSet" or .kind == "StatefulSet" or .kind == "Job"
        or .kind == "CronJob" or .kind == "Pod")
    | {workload: (.kind + "/" + .metadata.name),
       replicas: (.spec.replicas // 1),
       labels: (.spec.template.metadata.labels // {}),
       pod: (if .kind == "Pod" then .spec elif .kind == "CronJob" then .spec.jobTemplate.spec.template.spec
             else .spec.template.spec end)}'
}

@test "KEDA, the autoscaler's recommender and Reflector are enabled and pinned to exact versions" {
  local overlay app path version spec refkeys url
  overlay="$(kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2")"
  for app in keda vpa reflector; do
    path="$(APP=$app yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(APP)) | .spec.path' <<<"$overlay")"
    echo "$app in the overlay: ${path:-none}"
    [ -n "$path" ]
    built "$app"
    # The chart's version: the tag of an OCIRepository, or the version a HelmRelease asks a
    # HelmRepository for. An exact release, never a range, a digest-less moving tag or a latest.
    # Flux gives a ref's semver, semverFilter and digest precedence over its tag, so an
    # OCIRepository's ref holds the tag alone (or the tag and a digest), never a range.
    refkeys="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref // {} | keys | sort | join(",")' "$BUILT")"
    echo "$app ref keys: ${refkeys:-none}"
    [[ -z $refkeys || $refkeys == tag || $refkeys == digest,tag ]]
    version="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag // ""' "$BUILT")"
    [ -n "$version" ] || version="$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.version // ""' "$BUILT")"
    echo "$app chart version: ${version:-none}"
    [[ $version =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]
    # Renovate finds it: an OCIRepository tag carries its comment, a HelmRelease's chart version
    # is read by Renovate's Flux manager, which needs the HelmRepository beside it.
    spec="$(cat "$TREE/$APP_DIR/app/"*.yaml)"
    if grep -q '^kind: OCIRepository' <<<"$spec"; then
      # The comment names the repository the OCIRepository pulls from.
      url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
      grep -qxF "    # renovate: datasource=docker depName=${url#oci://}" <<<"$spec"
    else
      grep -q '^kind: HelmRepository' <<<"$spec"
    fi
  done
}

@test "KEDA's resource definitions are kept when its release is removed" {
  local definitions definition policy
  render keda
  definitions="$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$RENDERED")"
  echo "definitions: $(paste -sd' ' <<<"$definitions")"
  for definition in scaledobjects.keda.sh scaledjobs.keda.sh triggerauthentications.keda.sh \
    clustertriggerauthentications.keda.sh cloudeventsources.eventing.keda.sh \
    clustercloudeventsources.eventing.keda.sh; do
    grep -qxF "$definition" <<<"$definitions" || { echo "no definition $definition"; return 1; }
    policy="$(DEF=$definition yq -N 'select(.kind == "CustomResourceDefinition" and .metadata.name == strenv(DEF))
      | .metadata.annotations["helm.sh/resource-policy"] // "none"' "$RENDERED")"
    echo "$definition: resource-policy $policy"
    [ "$policy" = keep ]
  done
  # Only the chart installs them: nothing the application builds is a definition.
  built keda
  [ -z "$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$BUILT")" ]
}

@test "The autoscaler's resource definitions are never part of its release" {
  local with without
  render vpa
  with="$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$RENDERED" | sort)"
  render vpa --skip-crds
  without="$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$RENDERED" | sort)"
  echo "with crds/: $(paste -sd' ' <<<"$with"); without: ${without:-none}"
  [ "$with" = "$(printf '%s\n' verticalpodautoscalercheckpoints.autoscaling.k8s.io verticalpodautoscalers.autoscaling.k8s.io)" ]
  [ -z "$without" ]
  built vpa
  [ -z "$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$BUILT")" ]
}

@test "KEDA's metrics API does not collide with the resource metrics API" {
  local services duplicates
  render keda
  cp "$RENDERED" "$BATS_TEST_TMPDIR/keda-render.yaml"
  render metrics-server
  services="$(yq -N 'select(.kind == "APIService") | .spec.group + "/" + .spec.version' \
    "$BATS_TEST_TMPDIR/keda-render.yaml" "$RENDERED" | sort)"
  echo "APIService registrations: $(paste -sd' ' <<<"$services")"
  grep -qx 'external.metrics.k8s.io/v1beta1' <<<"$(yq -N 'select(.kind == "APIService") | .spec.group + "/" + .spec.version' "$BATS_TEST_TMPDIR/keda-render.yaml")"
  grep -qx 'metrics.k8s.io/v1beta1' <<<"$(yq -N 'select(.kind == "APIService") | .spec.group + "/" + .spec.version' "$RENDERED")"
  duplicates="$(uniq -d <<<"$services")"
  echo "claimed twice: ${duplicates:-none}"
  [ -z "$duplicates" ]
  # The names are group and version too, so one object cannot replace the other either.
  duplicates="$(yq -N 'select(.kind == "APIService") | .metadata.name' "$BATS_TEST_TMPDIR/keda-render.yaml" "$RENDERED" | sort | uniq -d)"
  [ -z "$duplicates" ]
}

@test "KEDA's admission webhooks let objects through while no webhook answers" {
  local policies
  render keda
  policies="$(yq -N 'select(.kind == "ValidatingWebhookConfiguration" or .kind == "MutatingWebhookConfiguration")
    | .kind + "/" + .metadata.name + " " + (.webhooks[].failurePolicy // "unset")' "$RENDERED")"
  echo "webhook failure policies: ${policies:-none}"
  [ -n "$policies" ]
  [ -z "$(grep -v ' Ignore$' <<<"$policies" || true)" ]
}

@test "KEDA's namespace holds its Pod Security level" {
  local level violations overlay
  # The level the cluster gets: the Namespace as the overlay builds it, not the source file.
  overlay="$(kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2")"
  level="$(yq -N 'select(.kind == "Namespace" and .metadata.name == "keda")
    | .metadata.labels["pod-security.kubernetes.io/enforce"] // "none"' <<<"$overlay")"
  echo "enforced level: $level"
  [ "$level" = restricted ]
  render keda
  echo "pod templates: $(pod_templates "$RENDERED" | jq -r .workload | paste -sd' ' -)"
  [ -n "$(pod_templates "$RENDERED")" ]
  # The restricted level's rules, for each pod template and each of its containers: the pod's
  # securityContext supplies runAsNonRoot, runAsUser and the seccomp profile where a container
  # sets none.
  violations="$(pod_templates "$RENDERED" | jq -r '
    .workload as $workload | .pod as $pod
    | ([
        {bad: (($pod.hostNetwork) == true or ($pod.hostPID) == true or ($pod.hostIPC) == true),
         why: "\($workload) shares a host namespace"},
        {bad: (($pod.volumes // []) | any(has("hostPath"))), why: "\($workload) mounts a host path"}
      ] + [
        (($pod.containers // []) + ($pod.initContainers // []))[]
        | (.securityContext // {}) as $c | "\($workload) container \(.name)" as $where
        | ($c.seccompProfile.type // $pod.securityContext.seccompProfile.type // "none") as $profile
        | {bad: ($c.privileged == true), why: "\($where) is privileged"},
          {bad: ($c.allowPrivilegeEscalation != false), why: "\($where) allows privilege escalation"},
          {bad: (($c.capabilities.drop // []) | any(. == "ALL") | not), why: "\($where) keeps its capabilities"},
          {bad: ((($c.capabilities.add // []) - ["NET_BIND_SERVICE"]) | length > 0), why: "\($where) adds capabilities"},
          {bad: ($c.runAsNonRoot == false or ($c.runAsNonRoot // $pod.securityContext.runAsNonRoot) != true),
           why: "\($where) may run as root"},
          {bad: (($c.runAsUser // $pod.securityContext.runAsUser) == 0), why: "\($where) runs as user 0"},
          {bad: ($profile != "RuntimeDefault" and $profile != "Localhost"), why: "\($where) has no seccomp profile"},
          {bad: ((.ports // []) | any(.hostPort != null)), why: "\($where) uses a host port"}
      ])[] | select(.bad) | .why')"
  echo "violations: ${violations:-none}"
  [ -z "$violations" ]
}

@test "The autoscaler renders a recommender and nothing that changes a pod" {
  local workloads kinds webhooks changers
  render vpa
  workloads="$(yq -N 'select(.kind == "Deployment" or .kind == "DaemonSet" or .kind == "StatefulSet"
    or .kind == "Job" or .kind == "CronJob") | .kind + "/" + .metadata.name' "$RENDERED")"
  echo "workloads: ${workloads:-none}"
  [ "$workloads" = "Deployment/vpa-recommender" ]
  webhooks="$(yq -N 'select(.kind == "MutatingWebhookConfiguration" or .kind == "ValidatingWebhookConfiguration"
    or .kind == "Job" or .kind == "Secret") | .kind + "/" + .metadata.name' "$RENDERED")"
  echo "webhooks, jobs and secrets: ${webhooks:-none}"
  [ -z "$webhooks" ]
  # No Deployment the chart names for the updater or the admission controller, in any form.
  kinds="$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[].image' "$RENDERED")"
  echo "images: $kinds"
  [[ $kinds == *vpa-recommender* && $kinds != *vpa-updater* && $kinds != *vpa-admission-controller* ]]
  # What each role bound in the render lets its subjects do to a pod.
  changers="$(yq -N -o json -I0 'select(. != null)' "$RENDERED" | jq -rs '
    ([.[] | select(.kind == "ClusterRole" or .kind == "Role") | {key: .metadata.name, value: .rules}] | from_entries) as $roles
    | .[] | select(.kind == "ClusterRoleBinding" or .kind == "RoleBinding")
    | select((.metadata.annotations["helm.sh/hook"] // "") == "")
    | . as $binding | ($roles[.roleRef.name] // [])[]
    | select((.apiGroups // [""]) | any(. == "" or . == "*"))
    | select((.resources // []) | any(. == "pods" or . == "pods/eviction" or . == "pods/resize" or . == "*"))
    | select((.verbs // []) | any(. == "create" or . == "update" or . == "patch" or . == "delete"
        or . == "deletecollection" or . == "*"))
    | "\($binding.metadata.name) -> \($binding.roleRef.name)"')"
  echo "bound roles that change a pod: ${changers:-none}"
  [ -z "$changers" ]
}

@test "Reflector's rights are what the docs say and nothing in the repository is reflected yet" {
  local rules bindings reflecting
  render reflector
  rules="$(yq -N -o json -I0 'select(.kind == "ClusterRole" or .kind == "Role") | .rules[]
    | (.apiGroups | join(",")) + "|" + (.resources | join(",")) + "|" + (.verbs | join(","))' "$RENDERED" | tr -d '"' | sort)"
  echo "rules: $(paste -sd' ' <<<"$rules")"
  [ "$rules" = "$(printf '%s\n' '|configmaps,secrets|*' '|namespaces|watch,list' | sort)" ]
  # Every binding, namespaced or not, so that no other grant is bound to anyone.
  bindings="$(yq -N 'select(.kind == "ClusterRoleBinding" or .kind == "RoleBinding")
    | .kind + " " + .roleRef.name + " <- " + (.subjects | map(.kind + "/" + .name + "/" + .namespace) | join(","))' "$RENDERED")"
  echo "bindings: $bindings"
  [ "$(wc -l <<<"$bindings")" -eq 1 ]
  [[ $bindings == 'ClusterRoleBinding '*' <- ServiceAccount/reflector/kube-system' ]]
  # The docs state the right and the control on it.
  grep -qF 'Reflector can read and write every Secret and ConfigMap in every namespace, and list and watch' "$REPO/docs/kubernetes.md"
  # shellcheck disable=SC2016 # The backticks are the docs' own.
  grep -qF 'only an object carrying `reflection-allowed` is copied' "$REPO/docs/kubernetes.md"
  # Nothing in the tree is reflected: a copy needs an annotation of Reflector's on its source. The
  # whole kubernetes directory is searched, the cluster directories with their secrets included;
  # grep writes nothing, so it reads the checkout.
  reflecting="$(grep -rIl 'reflector\.v1\.k8s\.emberstack\.com' "$REPO/kubernetes" || true)"
  echo "files with a reflection annotation: ${reflecting:-none}"
  [ -z "$reflecting" ]
}

@test "The add-ons keep running while a node is drained" {
  local app component replicas spread budget failed=""
  local -a components=(keda-operator keda-operator-metrics-apiserver keda-admission-webhooks)
  render keda
  for component in "${components[@]}"; do
    # The spread and the budget are compared with the labels of the rendered pod template, so a
    # selector that matches no pod of the component does not count.
    read -r replicas spread budget < <(yq -N -o json -I0 'select(. != null)' "$RENDERED" | jq -rs --arg c "$component" '
      (.[] | select(.kind == "Deployment" and .metadata.name == $c)) as $d
      | ($d.spec.template.metadata.labels // {}) as $labels
      | def selects: (.matchLabels // {}) as $m | ($m | length) > 0 and ($m | to_entries | all($labels[.key] == .value));
      [($d.spec.replicas // 1 | tostring),
       ([$d.spec.template.spec.topologySpreadConstraints // [] | .[]
         | select(.topologyKey == "kubernetes.io/hostname" and .maxSkew == 1 and (.labelSelector | selects))
         | .whenUnsatisfiable][0] // "none"),
       ([.[] | select(.kind == "PodDisruptionBudget" and (.spec.selector | selects))
         | (.spec.minAvailable // "none" | tostring) + "/" + (.spec.maxUnavailable // "none" | tostring)][0] // "none")]
      | join(" ")')
    echo "$component: replicas ${replicas:-none}, spread: ${spread:-none}, budget: ${budget:-none}"
    [ "${replicas:-0}" = 2 ] || failed+=" $component:replicas"
    [ "${spread:-none}" != none ] || failed+=" $component:spread"
    [ "$budget" = "1/none" ] || failed+=" $component:budget"
  done
  # One replica each, as neither elects a leader that a second replica could share the work with
  # (Reflector) or the second replica would hold 500Mi of requests for a failover the checkpoints
  # make cheap (the recommender); no budget, which would block every drain of the node a single
  # replica is on.
  for app in vpa reflector; do
    render "$app"
    replicas="$(pod_templates "$RENDERED" | jq -r '.replicas' | paste -sd' ' -)"
    budget="$(yq -N 'select(.kind == "PodDisruptionBudget") | .metadata.name' "$RENDERED")"
    echo "$app: replicas $replicas, budgets: ${budget:-none}"
    [ "$replicas" = 1 ] || failed+=" $app:replicas"
    [ -z "$budget" ] || failed+=" $app:budget"
  done
  echo "failed:${failed:- none}"
  [ -z "$failed" ]
}

@test "Every pod the add-ons run has resource requests" {
  local app unrequested limited="" templates
  for app in keda vpa reflector; do
    render "$app"
    templates="$(pod_templates "$RENDERED" | jq -r .workload | paste -sd' ' -)"
    echo "$app pod templates: $templates"
    [ -n "$templates" ]
    unrequested="$(pod_templates "$RENDERED" | jq -r '.workload as $w | .pod
      | ((.containers // []) + (.initContainers // []))[]
      | select((.resources.requests.cpu // "") == "" or (.resources.requests.memory // "") == "")
      | "\($w) container \(.name)"')"
    echo "$app without requests: ${unrequested:-none}"
    [ -z "$unrequested" ]
    # KEDA's publisher documents a limit for each component, which the chart sets; elsewhere none.
    if [ "$app" != keda ]; then
      limited="$(pod_templates "$RENDERED" | jq -r '.workload as $w | .pod
        | ((.containers // []) + (.initContainers // []))[]
        | select((.resources.limits // {}) | length > 0) | "\($w) container \(.name)"')"
      echo "$app with limits: ${limited:-none}"
      [ -z "$limited" ]
    fi
  done
}

@test "Every monitor selects a Service or pods that its own render contains" {
  local app targets depends monitors
  for app in keda vpa reflector; do
    render "$app"
    targets="$(monitor_targets)"
    echo "$app: ${targets:-no monitor}"
    if [ "$app" = reflector ]; then
      # Its chart serves no metrics and makes no monitor.
      [ -z "$targets" ]
      continue
    fi
    [[ $targets != *' -> none'* ]]
    depends="$(yq '.spec.dependsOn // [] | .[].name' "$TREE/$APP_DIR/ks.yaml")"
    echo "$app depends on: ${depends:-nothing}"
    grep -qx prometheus-operator-crds <<<"$depends"
  done
  # Exactly one monitor for each thing that serves metrics.
  render keda
  monitors="$(monitor_targets | grep -c . || true)"
  [ "$monitors" -eq 3 ]
  [ "$(monitor_targets | grep -cxF 'ServiceMonitor/keda-operator -> Service/keda-operator')" -eq 1 ]
  [ "$(monitor_targets | grep -cxF 'ServiceMonitor/keda-operator-metrics-apiserver -> Service/keda-operator-metrics-apiserver')" -eq 1 ]
  [ "$(monitor_targets | grep -cxF 'ServiceMonitor/keda-admission-webhooks -> Service/keda-admission-webhooks')" -eq 1 ]
  render vpa
  [ "$(monitor_targets)" = "PodMonitor/vpa-recommender -> Deployment/vpa-recommender" ]
}

# defined_keys APP: fails, naming them, on keys of APP's values file or of its HelmRelease's own
# values that the pinned chart's values do not define. Keys of maps only: list items are the
# chart's input, not keys. A map the chart leaves empty, such as an annotations map, takes keys of
# the user's choosing, and so does a security context map for the fields of Kubernetes' security
# context types (fixtures/security-context-fields).
defined_keys() {
  local app=$1 keys="$BATS_TEST_TMPDIR/keys" unknown="" key map open
  local paths='[.. | select(path | length > 0) | path | select(all_c(tag == "!!str")) | join(".")] | .[]'
  render "$app"
  mkdir -p "$keys"
  yq -N "$paths" "$VALUES" "$INLINE" | sort -u >"$keys/$app.ours"
  helm show values "$CHART" >"$keys/$app.defaults"
  yq -N "$paths" "$keys/$app.defaults" | sort -u >"$keys/$app.chart"
  open="$(yq -N '[.. | select(tag == "!!map" and length == 0) | path | join(".")] | .[]' "$keys/$app.defaults")"
  while read -r key; do
    for map in $open; do
      if [[ $key == "$map".* ]]; then continue 2; fi
    done
    # A security context map is Kubernetes' type, which the chart passes through to the pod or
    # container: a field of that type is a key of the user's choosing, a misspelt one is not.
    if [[ $key =~ (^|\.)(securityContext|podSecurityContext|containerSecurityContext)\.(.+)$ ]] &&
      grep -qxF -- "${BASH_REMATCH[3]}" "$BATS_TEST_DIRNAME/fixtures/security-context-fields"; then
      continue
    fi
    unknown+=" $key"
  done < <(comm -23 "$keys/$app.ours" "$keys/$app.chart")
  echo "$app: keys the chart does not define:${unknown:- none}"
  [ -z "$unknown" ]
}

@test "every values key of keda is one its pinned chart defines" {
  defined_keys keda
}

@test "every values key of vpa is one its pinned chart defines" {
  defined_keys vpa
}

@test "every values key of reflector is one its pinned chart defines" {
  defined_keys reflector
}
