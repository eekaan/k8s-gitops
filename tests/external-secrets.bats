#!/usr/bin/env bats
# Proves features/external-secrets.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux and yq on PATH (the versions pinned for the repository). The chart is
# pulled once per run from its public registry; building and rendering are offline.

# The tests run one at a time even where bats runs a file's tests side by side: a test that starts
# while another pulls the chart finds the chart's directory before the chart is in it.
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
  APP=external-secrets
  NAMESPACE=external-secrets
  APP_DIR="kubernetes/apps/base/$NAMESPACE/$APP"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# built: the application as Flux applies it: its app/ built with its ks.yaml, substituting strictly
# the variables of the cluster's example key lists. Writes $BATS_TEST_TMPDIR/built.yaml and sets
# BUILT.
built() {
  local vars="$BATS_TEST_TMPDIR/example-vars.yaml" ks="$BATS_TEST_TMPDIR/ks.yaml"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$vars"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = $vars' "$vars" "$TREE/$APP_DIR/ks.yaml" >"$ks"
  BUILT="$BATS_TEST_TMPDIR/built.yaml"
  # Built from the tree's parent, with paths from there, as scripts/kubernetes-check builds.
  (cd "$TREE" && flux build kustomization "$APP" --path "./$APP_DIR/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute) >"$BUILT"
}

# render: renders the chart that the application's HelmRelease installs, built as built() builds
# it, from the URL and tag of its OCIRepository, with the values helm-controller gives the chart:
# those of the ConfigMap the HelmRelease reads, then the HelmRelease's own over them. The
# ServiceMonitor and Grafana dashboard APIs count as present, as group versions and as kinds, which
# this chart looks for, so that only the values keep such objects out. Writes
# $BATS_TEST_TMPDIR/rendered.yaml and sets RENDERED, CHART, VALUES and INLINE.
render() {
  local url tag name release namespace pulled
  built
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  VALUES="$BATS_TEST_TMPDIR/values.yaml"
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\") | .data[\"values.yaml\"]" "$BUILT" >"$VALUES"
  [ -s "$VALUES" ] || { echo "no values in the ConfigMap $name the HelmRelease reads"; return 1; }
  INLINE="$BATS_TEST_TMPDIR/inline.yaml"
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$BUILT" >"$INLINE"
  pulled="$BATS_FILE_TMPDIR/charts/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  RENDERED="$BATS_TEST_TMPDIR/rendered.yaml"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" --include-crds \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor \
    --api-versions monitoring.coreos.com/v1/PodMonitor --api-versions grafana.integreatly.org/v1beta1 \
    --api-versions grafana.integreatly.org/v1beta1/GrafanaDashboard \
    --values "$VALUES" --values "$INLINE" >"$RENDERED"
}

@test "The External Secrets operator is installed with its resource definitions" {
  local overlay enabled namespace deployments definitions definition
  # The cluster runs it: its overlay applies the namespace directory and the application's
  # Kustomization.
  overlay="$(kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2")"
  enabled="$(yq -N "select(.kind == \"Kustomization\" and .metadata.name == \"$APP\") | .spec.path" <<<"$overlay")"
  namespace="$(yq -N "select(.kind == \"Namespace\" and .metadata.name == \"$NAMESPACE\") | .metadata.name" <<<"$overlay")"
  echo "$APP in the overlay: ${enabled:-none}; namespace: ${namespace:-none}"
  [ "$enabled" = "./apps/base/$NAMESPACE/$APP/app" ]
  [ "$namespace" = "$NAMESPACE" ]
  render
  echo "renders: $(yq -N 'select(. != null) | .kind' "$RENDERED" | sort | uniq -c | xargs)"
  deployments="$(yq -N 'select(.kind == "Deployment") | .metadata.name' "$RENDERED" | sort)"
  [ "$deployments" = "$(printf '%s\n' external-secrets external-secrets-cert-controller external-secrets-webhook)" ]
  definitions="$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$RENDERED")"
  for definition in externalsecrets.external-secrets.io clustersecretstores.external-secrets.io \
    passwords.generators.external-secrets.io; do
    grep -qxF "$definition" <<<"$definitions" || { echo "no definition $definition"; return 1; }
  done
}

@test "No secret store, external secret or monitoring object comes with the operator" {
  local own monitors
  render
  # Every kind the operator defines is in one of its groups, external-secrets.io and its subgroups.
  own="$(yq -N 'select(. != null) | select(.apiVersion | test("(^|\.)external-secrets\.io/"))
    | .kind + "/" + .metadata.name' "$BUILT" "$RENDERED")"
  echo "objects of the operator's kinds: ${own:-none}"
  [ -z "$own" ]
  monitors="$(yq -N 'select(. != null) | select(.kind == "ServiceMonitor" or .kind == "PodMonitor"
    or .kind == "GrafanaDashboard" or (.kind == "ConfigMap" and (.metadata.labels // {} | has("grafana_dashboard"))))
    | .kind + "/" + .metadata.name' "$RENDERED")"
  echo "monitoring objects: ${monitors:-none}"
  [ -z "$monitors" ]
}

@test "The External Secrets webhook keeps admitting while a node is drained" {
  local deployments budgets name replicas spread count min max
  render
  # Each Deployment, with the number of its constraints that put no two of its own pods on one node.
  # shellcheck disable=SC2016 # $labels is a yq variable.
  deployments="$(yq -N 'select(.kind == "Deployment") | .spec.template.metadata.labels as $labels
    | .metadata.name + " " + (.spec.replicas | tostring) + " " + ([.spec.template.spec.topologySpreadConstraints // [] | .[]
      | select(.topologyKey == "kubernetes.io/hostname" and .whenUnsatisfiable == "DoNotSchedule" and .maxSkew == 1
        and (.labelSelector.matchLabels // {} | length > 0)
        and (.labelSelector.matchLabels // {} | to_entries | all_c(.value == $labels[.key])))] | length | tostring)' "$RENDERED" | sort)"
  echo "name replicas spread:"
  echo "$deployments"
  [ "$(cut -d' ' -f1 <<<"$deployments" | paste -sd' ' -)" = "external-secrets external-secrets-cert-controller external-secrets-webhook" ]
  while read -r name replicas spread; do
    [ "$replicas" -eq 2 ] || { echo "$name runs $replicas replicas"; return 1; }
    [ "$spread" -ge 1 ] || { echo "$name may put both replicas on one node"; return 1; }
  done <<<"$deployments"
  # Each Deployment's disruption budgets, those whose selector picks its pods.
  yq ea -o json -I0 '[select(.kind == "PodDisruptionBudget")]' "$RENDERED" >"$BATS_TEST_TMPDIR/budgets.json"
  # shellcheck disable=SC2016 # $budgets, $labels and $mine are yq variables.
  budgets="$(BUDGETS="$BATS_TEST_TMPDIR/budgets.json" yq -N 'load(strenv(BUDGETS)) as $budgets
    | select(.kind == "Deployment") | .spec.template.metadata.labels as $labels
    | [$budgets[] | select(.spec.selector.matchLabels // {} | length > 0)
      | select(.spec.selector.matchLabels | to_entries | all_c(.value == $labels[.key]))] as $mine
    | .metadata.name + " " + (.spec.replicas | tostring) + " " + ($mine | length | tostring)
      + " " + ($mine[0].spec.minAvailable // "unset" | tostring) + " " + ($mine[0].spec.maxUnavailable // "unset" | tostring)' "$RENDERED")"
  echo "name replicas budgets minAvailable maxUnavailable:"
  echo "$budgets"
  while read -r name replicas count min max; do
    [ "$count" -eq 1 ] || { echo "$name has $count disruption budgets"; return 1; }
    # One pod stays running and one may be evicted; a budget in percent is not read here.
    if [[ $min =~ ^[0-9]+$ ]]; then
      ((min >= 1 && min < replicas)) || { echo "$name: minAvailable $min of $replicas"; return 1; }
    elif [[ $max =~ ^[0-9]+$ ]]; then
      ((max >= 1 && max < replicas)) || { echo "$name: maxUnavailable $max of $replicas"; return 1; }
    else
      echo "$name: the budget sets neither minAvailable nor maxUnavailable as a number"
      return 1
    fi
  done <<<"$budgets"
}

@test "The External Secrets resource definitions outlive the release" {
  local kept
  # The application applies no definition itself, so pruning what it applies deletes none.
  render
  echo "the application applies: $(yq -N 'select(. != null) | .kind' "$BUILT" | sort | paste -sd' ' -)"
  [ -z "$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$BUILT")" ]
  # Removing the application uninstalls its release, and Helm keeps every object marked keep.
  kept="$(yq -N 'select(.kind == "CustomResourceDefinition")
    | .metadata.name + " " + (.metadata.annotations["helm.sh/resource-policy"] // "none")' "$RENDERED")"
  echo "$kept"
  [ -n "$kept" ]
  [ "$(grep -vc ' keep$' <<<"$kept")" -eq 0 ]
}

@test "The External Secrets pods meet the restricted Pod Security level their namespace enforces" {
  local level pods containers line
  level="$(yq -N 'select(.kind == "Namespace") | .metadata.labels["pod-security.kubernetes.io/enforce"] // "none"' \
    "$TREE/kubernetes/apps/base/$NAMESPACE/namespace.yaml")"
  echo "the namespace enforces: $level"
  [ "$level" = restricted ]
  render
  # The checks of the restricted level that a pod template can show. A pod template that sets no
  # user leaves the image's, which must not be root; runAsNonRoot makes the kubelet refuse root.
  # shellcheck disable=SC2016 # $p is a yq variable.
  pods="$(yq -N 'select(.kind == "Deployment") | .spec.template.spec as $p
    | .metadata.name + " hostNamespaces=" + ([$p.hostNetwork, $p.hostPID, $p.hostIPC] | map(select(. == true)) | length | tostring)
      + " volumes=" + ([$p.volumes // [] | .[] | keys | .[] | select(. != "name")] | unique | join(","))' "$RENDERED")"
  echo "$pods"
  [ -n "$pods" ]
  while read -r line; do
    [[ $line =~ \ hostNamespaces=0\ volumes=((configMap|csi|downwardAPI|emptyDir|ephemeral|persistentVolumeClaim|projected|secret)(,|$))*$ ]] ||
      { echo "not restricted: $line"; return 1; }
  done <<<"$pods"
  # shellcheck disable=SC2016 # $d, $p and $c are yq variables.
  containers="$(yq -N 'select(.kind == "Deployment") | .metadata.name as $d | .spec.template.spec as $p
    | (($p.initContainers // []) + $p.containers)[] as $c
    | $d + "/" + $c.name
      + " privileged=" + ($c.securityContext.privileged // false | tostring)
      + " allowPrivilegeEscalation=" + ($c.securityContext.allowPrivilegeEscalation | tostring)
      + " runAsNonRoot=" + ($c.securityContext.runAsNonRoot // $p.securityContext.runAsNonRoot // false | tostring)
      + " runAsUser=" + ($c.securityContext.runAsUser // $p.securityContext.runAsUser // "unset" | tostring)
      + " seccomp=" + ($c.securityContext.seccompProfile.type // $p.securityContext.seccompProfile.type // "unset")
      + " drop=" + ($c.securityContext.capabilities.drop // [] | join(","))
      + " add=" + ($c.securityContext.capabilities.add // [] | map(select(. != "NET_BIND_SERVICE")) | join(","))
      + " hostPorts=" + ([$c.ports // [] | .[] | select((.hostPort // 0) != 0)] | length | tostring)' "$RENDERED")"
  echo "$containers"
  [ -n "$containers" ]
  while read -r line; do
    [[ $line =~ \ privileged=false\ allowPrivilegeEscalation=false\ runAsNonRoot=true\ runAsUser=([1-9][0-9]*|unset)\ seccomp=(RuntimeDefault|Localhost)\ drop=([^ ]*,)?ALL(,[^ ]*)?\ add=\ hostPorts=0$ ]] ||
      { echo "not restricted: $line"; return 1; }
  done <<<"$containers"
}

@test "every values key of external-secrets is one its pinned chart defines" {
  local keys="$BATS_TEST_TMPDIR/keys" unknown="" key map open
  local paths='[.. | select(path | length > 0) | path | select(all_c(tag == "!!str")) | join(".")] | .[]'
  render
  mkdir -p "$keys"
  yq -N "$paths" "$VALUES" "$INLINE" | sort -u >"$keys/ours"
  helm show values "$CHART" >"$keys/defaults"
  yq -N "$paths" "$keys/defaults" | sort -u >"$keys/chart"
  # A map the chart leaves empty, such as an annotations map, takes keys of the user's choosing.
  open="$(yq -N '[.. | select(tag == "!!map" and length == 0) | path | join(".")] | .[]' "$keys/defaults")"
  while read -r key; do
    for map in $open; do
      if [[ $key == "$map".* ]]; then continue 2; fi
    done
    unknown+=" $key"
  done < <(comm -23 "$keys/ours" "$keys/chart")
  echo "keys the chart does not define:${unknown:- none}"
  [ -z "$unknown" ]
}
