#!/usr/bin/env bats
# Proves features/storage.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq, jq, git, tofu, talman and talosctl on PATH (the versions pinned
# for the repository). The operator's chart is pulled once per run from its public registry, and the
# operator's and the external-snapshotter's repositories are cloned once each, at the pinned version
# and with only the directories read; building, rendering and the nodes' machine configurations,
# which scripts/talos-check renders, are offline. flux build rewrites the kustomization.yaml of what
# it builds while it runs, so every build reads a copy of kubernetes/, never this checkout.

# The tests run one at a time even where bats runs a file's tests side by side: a test that starts
# while another pulls the chart or clones a repository finds its directory before it is complete.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

setup_file() {
  # Helm's cache and registry settings stay in the run's own directory, and so does the Docker
  # configuration helm falls back to for credentials, so no login is read.
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG" "$BATS_FILE_TMPDIR/tree"
  # Nor does git read the user's or the system's configuration, credential helpers included.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
  cp -R "$BATS_TEST_DIRNAME/../kubernetes" "$BATS_FILE_TMPDIR/tree/kubernetes"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TREE="$BATS_FILE_TMPDIR/tree"
  CLUSTER="$TREE/kubernetes/clusters/lab-sto2"
  KUBE="$(yq -e '.kubernetes' "$REPO/versions.yaml")"
  # LINSTOR's CSI driver, as its StorageClasses and VolumeSnapshotClasses name it.
  LINSTOR=linstor.csi.linbit.com
  CONTROL_PLANE='node-role.kubernetes.io/control-plane'
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# built NAMESPACE APP: the application as Flux applies it: its app/ built from the copy with its
# ks.yaml, substituting strictly the variables of the cluster's example key lists. Writes
# $BATS_TEST_TMPDIR/APP-built.yaml and sets BUILT.
built() {
  local ns=$1 app=$2 vars="$BATS_TEST_TMPDIR/example-vars.yaml" ks="$BATS_TEST_TMPDIR/$2-ks.yaml"
  # shellcheck disable=SC2016 # $list and $vars are yq variables.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$vars"
  # shellcheck disable=SC2016
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = $vars' "$vars" "$TREE/kubernetes/apps/base/$ns/$app/ks.yaml" >"$ks"
  BUILT="$BATS_TEST_TMPDIR/$app-built.yaml"
  # flux build reads only paths below the working directory.
  (cd "$TREE" && flux build kustomization "$app" --path "./kubernetes/apps/base/$ns/$app/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute) >"$BUILT"
}

# overlay: the Flux Kustomizations and namespaces the cluster's overlay applies. Writes OVERLAY.
overlay() {
  OVERLAY="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2" >"$OVERLAY"
}

# enabled KIND: every object of KIND that the applications the overlay enables apply themselves,
# built from each application's path. Writes $BATS_TEST_TMPDIR/KIND.yaml and sets OBJECTS.
enabled() {
  local path
  overlay
  OBJECTS="$BATS_TEST_TMPDIR/$1.yaml"
  : >"$OBJECTS"
  while read -r path; do
    { echo ---; kustomize build "$TREE/kubernetes/${path#./}" | yq "select(.kind == \"$1\")"; } >>"$OBJECTS"
  done < <(yq -N 'select(.kind == "Kustomization" and .apiVersion == "kustomize.toolkit.fluxcd.io/*") | .spec.path' "$OVERLAY")
}

# operator_chart: the chart the piraeus-operator HelmRelease installs, pulled once from the URL and
# tag of its OCIRepository. Leaves the application built in BUILT and sets CHART.
operator_chart() {
  local url tag pulled
  built piraeus-datastore piraeus-operator
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
  pulled="$BATS_FILE_TMPDIR/charts/piraeus-operator/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
}

# render_operator: the operator's chart as helm-controller installs it: rendered with the values of
# the ConfigMap the HelmRelease reads, then its own values over them, and the HelmRelease's
# post-renderer patches applied by kustomize. Writes $BATS_TEST_TMPDIR/piraeus-operator.yaml and
# sets RENDERED, VALUES and INLINE.
render_operator() {
  local name release namespace dir="$BATS_TEST_TMPDIR/post-render"
  operator_chart
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  VALUES="$BATS_TEST_TMPDIR/piraeus-operator-values.yaml"
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\") | .data[\"values.yaml\"]" "$BUILT" >"$VALUES"
  [ -s "$VALUES" ] || { echo "no values in the ConfigMap $name the HelmRelease reads"; return 1; }
  INLINE="$BATS_TEST_TMPDIR/piraeus-operator-inline.yaml"
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$BUILT" >"$INLINE"
  mkdir -p "$dir"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" --include-crds \
    --values "$VALUES" --values "$INLINE" >"$dir/rendered.yaml"
  yq ea -N '[select(.kind == "HelmRelease")] | .[0] | {"apiVersion": "kustomize.config.k8s.io/v1beta1",
    "kind": "Kustomization", "resources": ["rendered.yaml"],
    "patches": [(.spec.postRenderers // [])[] | (.kustomize.patches // [])[]]}' "$BUILT" >"$dir/kustomization.yaml"
  RENDERED="$BATS_TEST_TMPDIR/piraeus-operator.yaml"
  kustomize build "$dir" >"$RENDERED"
}

# satellite: the operator's satellite DaemonSet, from the operator's repository at the version the
# pinned chart runs, with the podTemplate of every LinstorSatelliteConfiguration of linstor-cluster
# applied as the operator applies it: as a strategic merge patch of the DaemonSet linstor-satellite
# whose spec.template is the podTemplate. Leaves linstor-cluster built in BUILT and writes
# $BATS_TEST_TMPDIR/satellite.yaml, setting SATELLITE.
satellite() {
  local source version src dir="$BATS_TEST_TMPDIR/satellite"
  operator_chart
  source="$(helm show chart "$CHART" | yq '.sources[0]')"
  version="$(helm show chart "$CHART" | yq '.appVersion')"
  echo "operator source: $source at $version"
  [ "$source" = https://github.com/piraeusdatastore/piraeus-operator ]
  src="$BATS_FILE_TMPDIR/piraeus-operator/$version"
  if [ ! -d "$src" ]; then
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$version" --filter=blob:none --sparse "$source" "$src"
    git -C "$src" sparse-checkout set pkg/resources/satellite/satellite
  fi
  built piraeus-datastore linstor-cluster
  mkdir -p "$dir"
  cp "$src/pkg/resources/satellite/satellite/daemonset.yaml" "$dir/daemonset.yaml"
  yq ea -N '[select(.kind == "LinstorSatelliteConfiguration" and .spec.podTemplate != null)]
    | {"apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization", "resources": ["daemonset.yaml"],
       "patches": map({"target": {"group": "apps", "version": "v1", "kind": "DaemonSet", "name": "linstor-satellite"},
         "patch": ({"apiVersion": "apps/v1", "kind": "DaemonSet", "metadata": {"name": "linstor-satellite"},
           "spec": {"template": .spec.podTemplate}} | to_yaml)})}' "$BUILT" >"$dir/kustomization.yaml"
  SATELLITE="$BATS_TEST_TMPDIR/satellite.yaml"
  kustomize build "$dir" >"$SATELLITE"
}

# nodes: every node's machine configuration, rendered once per run by scripts/talos-check from the
# repository's patches and its test fixture, as NODES/<hostname>.yaml.
nodes() {
  NODES="$BATS_FILE_TMPDIR/nodes"
  if [ ! -d "$NODES" ]; then
    "$REPO/scripts/talos-check" "$NODES.rendering" >/dev/null
    mv "$NODES.rendering" "$NODES"
  fi
}

# node_type HOSTNAME: controlplane or worker, as the node's machine configuration says.
node_type() {
  yq -N 'select(.machine != null) | .machine.type' "$NODES/$1.yaml"
}

# node_labels HOSTNAME: the labels the node gets, as JSON: the kubelet's own hostname label and
# those of its machine configuration, which Talos applies.
node_labels() {
  yq -N -o json -I0 'select(.kind == "KubeNodeConfig") | .labels // {}' "$NODES/$1.yaml" |
    jq -c --arg host "$1" '{"kubernetes.io/hostname": $host} + (. // {})'
}

# selects AFFINITY LABELS: whether a node with the JSON LABELS matches the JSON node affinity
# AFFINITY, in the form of a required nodeSelector: any of its terms, each with all of its
# expressions.
selects() {
  jq -e -n --argjson aff "$1" --argjson labels "$2" 'any($aff.nodeSelectorTerms[]; all((.matchExpressions // [])[];
    . as $e | $labels[$e.key] as $v |
    if $e.operator == "Exists" then $labels | has($e.key)
    elif $e.operator == "DoesNotExist" then $labels | has($e.key) | not
    elif $e.operator == "In" then $v != null and ($e.values | index($v)) != null
    elif $e.operator == "NotIn" then $v == null or ($e.values | index($v)) == null
    else error("operator \($e.operator) is not handled here") end))' >/dev/null
}

# param CLASS KEY: parameter KEY of the StorageClass CLASS in OBJECTS as LINSTOR's driver reads it:
# with or without its linstor.csi.linbit.com/ prefix, in any case. Empty when it is not set.
param() {
  local key
  key="$(tr '[:upper:]' '[:lower:]' <<<"$2")"
  yq -N "select(.metadata.name == \"$1\") | .parameters // {} | to_entries | .[]
    | select((.key | downcase | sub(\"^linstor[.]csi[.]linbit[.]com/\"; \"\")) == \"$key\") | .value" "$OBJECTS"
}

# replicas CLASS: how many replicas the StorageClass CLASS places: placementCount or its alias
# autoPlace, 1 when neither is set.
replicas() {
  local count
  count="$(param "$1" placementCount)"
  [ -n "$count" ] || count="$(param "$1" autoPlace)"
  echo "${count:-1}"
}

@test "The storage applications are enabled and wait for what they need" {
  local app ns path
  overlay
  for app in kube-system/snapshot-controller piraeus-datastore/piraeus-operator piraeus-datastore/linstor-cluster; do
    ns=${app%/*} app=${app#*/}
    path="$(yq -N "select(.kind == \"Kustomization\" and .metadata.name == \"$app\") | .spec.path" "$OVERLAY")"
    echo "$app in the overlay: ${path:-none}"
    [ "$path" = "./apps/base/$ns/$app/app" ]
    built "$ns" "$app"
    echo "$app builds: $(yq -N 'select(. != null) | .kind' "$BUILT" | sort | uniq -c | xargs)"
  done
  # Ready only once what they install is: the definitions and the controller, the operator's release.
  for app in snapshot-controller piraeus-operator; do
    [ "$(yq -N "select(.metadata.name == \"$app\") | .spec.wait" "$OVERLAY")" = true ]
  done
  local depends
  depends="$(yq -N 'select(.metadata.name == "linstor-cluster") | .spec.dependsOn // [] | .[].name' "$OVERLAY" | sort | xargs)"
  echo "linstor-cluster depends on: $depends"
  [ "$depends" = "piraeus-operator snapshot-controller" ]
  # The satellites, the CSI node plugin and the HA controller run privileged with host paths.
  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "piraeus-datastore")
    | .metadata.labels["pod-security.kubernetes.io/enforce"]' "$OVERLAY")" = privileged ]
}

@test "Satellites run with the Talos settings, on the workers only" {
  local pod='select(.kind == "DaemonSet") | .spec.template.spec' inits loaders hostpaths lvm config node
  satellite
  inits="$(yq -N "$pod | .initContainers // [] | .[].name" "$SATELLITE" | xargs)"
  echo "init containers: $inits"
  [ -n "$inits" ]
  [ "$(grep -cwE 'drbd-module-loader|drbd-shutdown-guard' <<<"$inits")" -eq 0 ]
  loaders="$(yq -N "$pod | (.initContainers // []) + .containers | .[]
    | select((.securityContext.capabilities.add // []) | any_c(. == \"SYS_MODULE\")) | .name" "$SATELLITE")"
  echo "containers that may load a module: ${loaders:-none}"
  [ -z "$loaders" ]
  hostpaths="$(yq -N "$pod | .volumes[] | select(.hostPath != null) | .name + \" \" + .hostPath.path" "$SATELLITE")"
  echo "$hostpaths"
  [ "$(grep -cE ' (/run/systemd|/run/dbus|/run/drbd-shutdown-guard|/lib/modules|/usr/src)(/|$)' <<<"$hostpaths")" -eq 0 ]
  # LVM's configuration comes from the ConfigMap the application applies beside it, and keeps its
  # backups and archives under /var, as /etc is read-only on Talos.
  config="$(yq -N "$pod | .volumes[] | select(.name == \"etc-lvm\") | select(.hostPath == null) | .configMap.name" "$SATELLITE")"
  echo "etc-lvm from the ConfigMap: ${config:-none}"
  [ -n "$config" ]
  lvm="$(yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$config\") | .data[\"lvm.conf\"]" "$BUILT")"
  echo "$lvm"
  grep -qE '^[[:space:]]*backup = 1$' <<<"$lvm"
  grep -qE '^[[:space:]]*archive = 1$' <<<"$lvm"
  grep -qx 'etc-lvm-backup /var/etc/lvm/backup' <<<"$hostpaths"
  grep -qx 'etc-lvm-archive /var/etc/lvm/archive' <<<"$hostpaths"

  # LINSTOR runs on the nodes its LinstorCluster selects, and every satellite configuration applies
  # to each of them.
  local clusters affinity selector configs
  clusters="$(yq -N 'select(.kind == "LinstorCluster") | .metadata.name' "$BUILT")"
  [ "$(grep -c . <<<"$clusters")" -eq 1 ]
  selector="$(yq -N -o json -I0 'select(.kind == "LinstorCluster") | .spec.nodeSelector // {}' "$BUILT")"
  affinity="$(yq -N -o json -I0 'select(.kind == "LinstorCluster") | .spec.nodeAffinity // {"nodeSelectorTerms": [{}]}' "$BUILT")"
  echo "LinstorCluster nodeSelector: $selector, nodeAffinity: $affinity"
  configs="$(yq -N 'select(.kind == "LinstorSatelliteConfiguration")
    | select(.spec.nodeSelector != null or .spec.nodeAffinity != null) | .metadata.name' "$BUILT")"
  [ -z "$configs" ]
  # Talos labels every control plane with the role label and no worker; the selection takes every
  # worker and no control plane, whatever it is called.
  nodes
  local workers=0 labels
  for node in "$NODES"/*.yaml; do
    node="$(basename "$node" .yaml)"
    labels="$(node_labels "$node")"
    echo "$node: $(node_type "$node") $labels"
    if [ "$(node_type "$node")" = controlplane ]; then
      jq -e --arg key "$CONTROL_PLANE" 'has($key)' <<<"$labels" >/dev/null
      if selects "$affinity" "$labels"; then echo "LINSTOR would run on $node"; return 1; fi
    else
      [ "$(node_type "$node")" = worker ]
      jq -e --arg key "$CONTROL_PLANE" 'has($key) | not' <<<"$labels" >/dev/null
      selects "$affinity" "$labels"
      jq -e --argjson labels "$labels" 'to_entries | all(.[]; $labels[.key] == .value)' <<<"$selector" >/dev/null
      workers=$((workers + 1))
    fi
    # Nothing selects or names a node.
    [ "$(grep -cw -- "$node" "$BUILT")" -eq 0 ]
  done
  [ "$workers" -gt 0 ]
  [ "$(grep -c 'kubernetes.io/hostname' "$BUILT")" -eq 0 ]
}

@test "Each worker's data device is an LVM-thin storage pool" {
  local pools pool device names node
  built piraeus-datastore linstor-cluster
  # One pool, in a configuration that applies to every satellite.
  pools="$(yq -N -o json -I0 'select(.kind == "LinstorSatelliteConfiguration" and .spec.storagePools != null)
    | select(.spec.nodeSelector == null and .spec.nodeAffinity == null) | .spec.storagePools[]' "$BUILT")"
  echo "storage pools: $pools"
  [ "$(grep -c . <<<"$pools")" -eq 1 ]
  [ "$(yq -N 'select(.kind == "LinstorSatelliteConfiguration") | .spec.storagePools // [] | .[].name' "$BUILT" | grep -c .)" -eq 1 ]
  pool="$(jq -r '.name' <<<"$pools")"
  jq -e '.lvmThinPool != null' <<<"$pools" >/dev/null
  # The device Talos links for every worker's raw data volume, as a partition labelled r-<name>.
  nodes
  names=""
  for node in "$NODES"/*.yaml; do
    node="$(basename "$node" .yaml)"
    local raw
    raw="$(yq -N 'select(.kind == "RawVolumeConfig") | .name' "$NODES/$node.yaml")"
    echo "$node: $(node_type "$node"), raw volumes: ${raw:-none}"
    if [ "$(node_type "$node")" = worker ]; then
      [ "$(grep -c . <<<"$raw")" -eq 1 ]
      names+="$raw"$'\n'
    else
      [ -z "$raw" ]
    fi
  done
  [ "$(sort -u <<<"$names" | grep -c .)" -eq 1 ]
  device="/dev/disk/by-partlabel/r-$(sort -u <<<"$names" | grep .)"
  echo "pool $pool from: $(jq -c '.source.hostDevices' <<<"$pools"); the data device: $device"
  [ "$(jq -c '.source.hostDevices' <<<"$pools")" = "[\"$device\"]" ]
  # Every StorageClass of LINSTOR places its volumes in that pool.
  local class classes=0
  enabled StorageClass
  for class in $(yq -N "select(.provisioner == \"$LINSTOR\") | .metadata.name" "$OBJECTS"); do
    echo "$class: $(param "$class" storagePool)"
    [ "$(param "$class" storagePool)" = "$pool" ]
    classes=$((classes + 1))
  done
  [ "$classes" -gt 0 ]
}

@test "The default StorageClass replicates a volume on two workers" {
  local defaults class
  enabled StorageClass
  defaults="$(yq -N 'select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name' "$OBJECTS")"
  echo "default StorageClasses: ${defaults:-none}"
  [ "$(grep -c . <<<"$defaults")" -eq 1 ]
  class="$defaults"
  yq -N "select(.metadata.name == \"$class\")" "$OBJECTS"
  [ "$(yq -N "select(.metadata.name == \"$class\") | .provisioner" "$OBJECTS")" = "$LINSTOR" ]
  [ "$(replicas "$class")" = 2 ]
  # DRBD replicates, and is on the volume's layers unless the class names others.
  [[ -z $(param "$class" layerList) || " $(param "$class" layerList | tr '[:upper:]' '[:lower:]') " == *" drbd "* ]]
  [[ $(param "$class" allowRemoteVolumeAccess) =~ ^(|true)$ ]]
  [ -z "$(param "$class" nodeList)" ]
  [ "$(yq -N "select(.metadata.name == \"$class\") | .volumeBindingMode" "$OBJECTS")" = WaitForFirstConsumer ]
  [ "$(yq -N "select(.metadata.name == \"$class\") | .allowVolumeExpansion" "$OBJECTS")" = true ]
  [ "$(param "$class" csi.storage.k8s.io/fstype)" = xfs ]
  [ "$(param "$class" property.linstor.csi.linbit.com/DrbdOptions/auto-quorum)" = suspend-io ]
}

@test "The node-local StorageClass keeps one replica on the consumer's node" {
  local others class
  enabled StorageClass
  others="$(yq -N "select(.provisioner == \"$LINSTOR\")
    | select(.metadata.annotations[\"storageclass.kubernetes.io/is-default-class\"] != \"true\") | .metadata.name" "$OBJECTS")"
  echo "LINSTOR's other StorageClasses: ${others:-none}"
  [ "$(grep -c . <<<"$others")" -eq 1 ]
  class="$others"
  yq -N "select(.metadata.name == \"$class\")" "$OBJECTS"
  [ "$(replicas "$class")" = 1 ]
  [ "$(param "$class" layerList | tr '[:upper:]' '[:lower:]')" = storage ]
  [ "$(param "$class" allowRemoteVolumeAccess)" = false ]
  [ -z "$(param "$class" nodeList)$(param "$class" clientList)" ]
  [ "$(yq -N "select(.metadata.name == \"$class\") | .volumeBindingMode" "$OBJECTS")" = WaitForFirstConsumer ]
}

@test "Snapshots are taken by LINSTOR's driver through the upstream snapshot controller" {
  local url tag src inners inner name path crds controller depends classes
  local -a dirs
  built kube-system snapshot-controller
  url="$(yq -N 'select(.kind == "GitRepository") | .spec.url' "$BUILT")"
  tag="$(yq -N 'select(.kind == "GitRepository") | .spec.ref.tag' "$BUILT")"
  echo "source: $url at $tag"
  [ "$url" = https://github.com/kubernetes-csi/external-snapshotter ]
  mapfile -t dirs < <(yq -N 'select(.kind == "GitRepository") | .spec.sparseCheckout // [] | .[]' "$BUILT")
  [ "${#dirs[@]}" -gt 0 ]
  src="$BATS_FILE_TMPDIR/external-snapshotter/$tag"
  if [ ! -d "$src" ]; then
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" --filter=blob:none --sparse "$url" "$src"
    git -C "$src" sparse-checkout set "${dirs[@]}"
  fi
  # Each inner Kustomization built from the source as it applies it.
  inners="$(yq -N 'select(.kind == "Kustomization") | .metadata.name' "$BUILT")"
  [ "$(grep -c . <<<"$inners")" -eq 2 ]
  for name in $inners; do
    inner="$BATS_TEST_TMPDIR/inner-$name.yaml"
    yq -N "select(.kind == \"Kustomization\" and .metadata.name == \"$name\")" "$BUILT" >"$inner"
    [ "$(yq '.spec.sourceRef.kind + "/" + .spec.sourceRef.name' "$inner")" = \
      "GitRepository/$(yq -N 'select(.kind == "GitRepository") | .metadata.name' "$BUILT")" ]
    path="$(yq '.spec.path' "$inner")"
    (cd "$src" && flux build kustomization "$name" --namespace "$(yq '.metadata.namespace' "$inner")" \
      --path "$path" --kustomization-file "$inner" --dry-run) >"$BATS_TEST_TMPDIR/inner-$name-built.yaml"
    if [ -z "$(yq -N 'select(. != null and .kind != "CustomResourceDefinition") | .kind' "$BATS_TEST_TMPDIR/inner-$name-built.yaml")" ]; then
      crds="$name"
    else
      controller="$name"
    fi
  done
  echo "definitions: ${crds:-none}; controller: ${controller:-none}"
  [ -n "$crds" ] && [ -n "$controller" ]
  for name in volumesnapshotclasses volumesnapshotcontents volumesnapshots; do
    [ "$(yq -N "select(.metadata.name == \"$name.snapshot.storage.k8s.io\") | .kind" "$BATS_TEST_TMPDIR/inner-$crds-built.yaml")" = CustomResourceDefinition ]
  done
  [ -n "$(yq -N 'select(.kind == "Deployment" and .metadata.name == "snapshot-controller" and .metadata.namespace == "kube-system")
    | .spec.template.spec.containers[] | select(.image == "registry.k8s.io/sig-storage/snapshot-controller:*") | .name' \
    "$BATS_TEST_TMPDIR/inner-$controller-built.yaml")" ]
  depends="$(yq '.spec.dependsOn // [] | .[].name' "$BATS_TEST_TMPDIR/inner-$controller.yaml" | xargs)"
  echo "the controller waits for: ${depends:-nothing}"
  [ "$depends" = "$crds" ]
  [ "$(yq '.spec.wait' "$BATS_TEST_TMPDIR/inner-$crds.yaml")" = true ]

  # The one VolumeSnapshotClass of the cluster's applications.
  enabled VolumeSnapshotClass
  classes="$(yq -N 'select(.kind == "VolumeSnapshotClass") | .metadata.name + " " + .driver + " " + .deletionPolicy + " "
    + (.metadata.annotations["snapshot.storage.kubernetes.io/is-default-class"] // "false")' "$OBJECTS")"
  echo "VolumeSnapshotClasses: $classes"
  [ "$(grep -c . <<<"$classes")" -eq 1 ]
  [[ $classes == *" $LINSTOR Delete true" ]]
}

@test "The storage resource definitions are never deleted with their applications" {
  local app kept inner
  # No application applies a definition itself, so pruning what it applies deletes none.
  for app in kube-system/snapshot-controller piraeus-datastore/piraeus-operator piraeus-datastore/linstor-cluster; do
    built "${app%/*}" "${app#*/}"
    echo "$app applies: $(yq -N 'select(. != null) | .kind' "$BUILT" | sort | uniq -c | xargs)"
    [ -z "$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$BUILT")" ]
  done
  # The operator's release installs its definitions, and Helm keeps every one when the release is
  # uninstalled, as it is when the application leaves the tree.
  render_operator
  kept="$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name + " "
    + (.metadata.annotations["helm.sh/resource-policy"] // "none")' "$RENDERED")"
  echo "$kept"
  grep -q '^linstorclusters.piraeus.io ' <<<"$kept"
  grep -q '^linstorsatelliteconfigurations.piraeus.io ' <<<"$kept"
  [ "$(grep -vc ' keep$' <<<"$kept")" -eq 0 ]
  # The snapshot definitions' Kustomization prunes nothing it applied, and leaves it when it is
  # deleted itself.
  built kube-system snapshot-controller
  inner="$(yq -N 'select(.kind == "Kustomization" and .spec.path == "./client/config/crd")
    | (.spec.prune | tostring) + " " + (.spec.deletionPolicy // "MirrorPrune")' "$BUILT")"
  echo "definitions' Kustomization prune and deletion policy: ${inner:-none}"
  [ "$inner" = "false Orphan" ]
}

@test "every values key of piraeus-operator is one its pinned chart defines" {
  local keys="$BATS_TEST_TMPDIR/keys" unknown="" key map open
  local paths='[.. | select(path | length > 0) | path | select(all_c(tag == "!!str")) | join(".")] | .[]'
  render_operator
  mkdir -p "$keys"
  yq -N "$paths" "$VALUES" "$INLINE" | sort -u >"$keys/ours"
  helm show values "$CHART" >"$keys/defaults"
  yq -N "$paths" "$keys/defaults" | sort -u >"$keys/chart"
  open="$(yq -N '[.. | select(tag == "!!map" and length == 0) | path | join(".")] | .[]' "$keys/defaults")"
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
  done < <(comm -23 "$keys/ours" "$keys/chart")
  echo "keys the chart does not define:${unknown:- none}"
  [ -z "$unknown" ]
}
