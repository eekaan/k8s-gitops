#!/usr/bin/env bats
# Proves features/storage.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq, jq, git, tofu, talman and talosctl on PATH (the versions pinned
# for the repository). The operator's chart is pulled once per run from its public registry, and the
# operator's, the LINSTOR Go client's it is built with and the external-snapshotter's repositories are
# cloned once each, at the pinned version and with only the directories read; building, rendering and
# the nodes' machine configurations, which scripts/talos-check renders, are offline. flux build
# rewrites the kustomization.yaml of what it builds while it runs, so every build reads a copy of
# kubernetes/, never this checkout.
#
# Two tests also need docker and openssl: the proofs of "The pinned LINSTOR controller refuses an API
# request without its authority's client certificate and keeps serving its metrics" and "The pinned
# LINSTOR satellite refuses a connection without a certificate from its own authority", which run the
# controller and a satellite from the image the rendered chart's image list names. Each skips, saying
# why, where no docker daemon answers, as in the CI containers; with one, a pull or a run that fails is
# a failure. Each container has no network, no capability and a read-only root, runs as a user that is
# not root, the controller as the one the LinstorCluster gives its pod, and is removed with what it
# made.

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

teardown() {
  # A start of the controller or a satellite does not outlive its test, nor does what it made.
  if [ -n "${CONTROLLER:-}" ]; then
    docker rm -f -v "$CONTROLLER" >/dev/null 2>&1 || true
  fi
  if [ -n "${SATELLITE_CONTAINER:-}" ]; then
    docker rm -f -v "$SATELLITE_CONTAINER" >/dev/null 2>&1 || true
  fi
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
  # Built from the tree's parent, with paths from there, as scripts/kubernetes-check builds.
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

# operator_source: the operator's repository at the version the pinned chart runs, cloned once per
# run with only the directories read: the templates and patches the operator makes the storage
# cluster's objects from (pkg/resources), the controllers that apply them (internal/controller), its
# merge of the satellite configurations (pkg/merge), the types of its objects (api/v1) and its own
# client of LINSTOR's API (pkg/linstorhelper). Leaves the piraeus-operator application built in BUILT
# and sets CHART and OPERATOR_SRC.
operator_source() {
  local source version
  operator_chart
  source="$(helm show chart "$CHART" | yq '.sources[0]')"
  version="$(helm show chart "$CHART" | yq '.appVersion')"
  echo "operator source: $source at $version"
  [ "$source" = https://github.com/piraeusdatastore/piraeus-operator ]
  OPERATOR_SRC="$BATS_FILE_TMPDIR/piraeus-operator/$version"
  if [ ! -d "$OPERATOR_SRC" ]; then
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$version" --filter=blob:none --sparse "$source" "$OPERATOR_SRC"
    git -C "$OPERATOR_SRC" sparse-checkout set pkg/resources internal/controller pkg/merge api/v1 pkg/linstorhelper
  fi
}

# golinstor_const NAME: the value of the constant NAME, as its source writes it, of the LINSTOR Go
# client the operator at OPERATOR_SRC is built with: github.com/LINBIT/golinstor at the version the
# operator's go.mod requires, whose apiconsts.go holds LINSTOR's own constants, cloned once per run
# with its top-level files alone.
golinstor_const() {
  local version src
  version="$(awk '$1 == "github.com/LINBIT/golinstor" { print $2 }' "$OPERATOR_SRC/go.mod")"
  [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "the operator's go.mod requires no released golinstor: ${version:-none}" >&2; return 1; }
  [ -z "$(grep -E '^replace|^[[:space:]]*github.com/LINBIT/golinstor =>' "$OPERATOR_SRC/go.mod" || true)" ] ||
    { echo "the operator's go.mod replaces a module, which this does not follow" >&2; return 1; }
  src="$BATS_FILE_TMPDIR/golinstor/$version"
  if [ ! -d "$src" ]; then
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$version" --filter=blob:none --sparse \
      https://github.com/LINBIT/golinstor "$src"
  fi
  sed -nE "s/^const $1 = (.*)$/\1/p" "$src/apiconsts.go"
}

# satellite: the operator's satellite resources, its DaemonSet and their ConfigMaps
# (pkg/resources/satellite/satellite), from the operator's repository at the version the pinned chart
# runs, as the operator makes them for a node whose name SATELLITE_NODE stands in for, with every
# LinstorSatelliteConfiguration of linstor-cluster applying to it: in the operator's order
# (internal/controller/linstorsatellite_controller.go), first its patch for internalTLS
# (pkg/resources/satellite/patches/internal-tls.yaml), when the configurations set it, as the operator
# merges them, the last by name that does (pkg/merge), filled as the operator fills it (every string
# of the patch that starts with $ is the parameter of that name): the Secret <node>-tls, or the one
# the configuration names, and, without a CA reference, that Secret again as the authority
# (api/v1/tls.go); then the podTemplate of each configuration in the order of their names, as a
# strategic merge patch of the DaemonSet linstor-satellite whose spec.template is the podTemplate. The
# operator's name suffix, labels, images and node affinity are left out. Leaves linstor-cluster built
# in BUILT and writes $BATS_TEST_TMPDIR/satellite.yaml, setting SATELLITE.
satellite() {
  local dir="$BATS_TEST_TMPDIR/satellite" res tls secret resource
  local satellite_files=()
  SATELLITE_NODE=worker-stand-in
  operator_source
  built piraeus-datastore linstor-cluster
  res="$OPERATOR_SRC/pkg/resources/satellite"
  mkdir -p "$dir"
  mapfile -t satellite_files < <(yq '.resources[]' "$res/satellite/kustomization.yaml")
  for resource in "${satellite_files[@]}"; do
    cp "$res/satellite/$resource" "$dir/$resource"
  done
  : >"$dir/patches.json"
  tls="$(yq ea -N -o json -I0 '[select(.kind == "LinstorSatelliteConfiguration" and .spec.internalTLS != null)]
    | sort_by(.metadata.name) | if length == 0 then null else .[length - 1].spec.internalTLS end' "$BUILT")"
  if [ "$tls" != null ]; then
    [ "$(jq -r 'has("caReference")' <<<"$tls")" = false ] ||
      { echo "a configuration's internalTLS names a CA reference, which this does not fill in"; return 1; }
    secret="$(jq -r --arg node "$SATELLITE_NODE" '.secretName // ($node + "-tls")' <<<"$tls")"
    # shellcheck disable=SC2016 # $p and $k are jq variables.
    yq -o json -I0 '.[] | .patch |= from_yaml' "$res/patches/internal-tls.yaml" |
      jq -c --arg secret "$secret" '{"LINSTOR_INTERNAL_TLS_SECRET_NAME": $secret,
        "LINSTOR_INTERNAL_TLS_CA_PROJECTION": {"secret": {"name": $secret}}} as $p
        | .patch |= (walk(if type == "string" and startswith("$")
            then (.[1:] as $k | $p[$k] // error("the patch names the parameter \($k), which this does not fill in"))
            else . end) | tojson)' >>"$dir/patches.json"
  fi
  yq ea -N -o json -I0 '[select(.kind == "LinstorSatelliteConfiguration" and .spec.podTemplate != null)]
    | sort_by(.metadata.name) | .[]
    | {"target": {"group": "apps", "version": "v1", "kind": "DaemonSet", "name": "linstor-satellite"},
       "patch": ({"apiVersion": "apps/v1", "kind": "DaemonSet", "metadata": {"name": "linstor-satellite"},
         "spec": {"template": .spec.podTemplate}} | to_yaml)}' "$BUILT" >>"$dir/patches.json"
  jq -s --args '{"apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization",
    "resources": $ARGS.positional, "patches": .}' "${satellite_files[@]}" <"$dir/patches.json" >"$dir/kustomization.yaml"
  SATELLITE="$BATS_TEST_TMPDIR/satellite.yaml"
  kustomize build "$dir" >"$SATELLITE"
}

# go_func FILE NAME: the Go function or method NAME of FILE, from its signature to its closing brace,
# a line each with its indentation dropped, runs of blanks made one and whole-line comments left out.
go_func() {
  awk -v name="$2" '$0 ~ "^func (\\([^)]*\\) )?" name "\\(" { inside = 1 } inside { print } inside && /^}/ { exit }' "$1" |
    sed -E 's#^[[:space:]]*//.*$##; s/[[:space:]]+/ /g; s/^ //; s/ $//' | grep .
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

# cm_object KIND NAME: cert-manager's object KIND NAME of BUILT as JSON on one line; fails unless the
# build holds exactly one.
cm_object() {
  local found
  found="$(KIND="$1" NAME="$2" yq -N -o json -I0 'select(.apiVersion == "cert-manager.io/v1" and .kind == strenv(KIND)
    and .metadata.name == strenv(NAME))' "$BUILT")"
  [ "$(grep -c . <<<"$found")" -eq 1 ] || { echo "$1 $2: $(grep -c . <<<"$found") in the build" >&2; return 1; }
  echo "$found"
}

# authority FIELD: the authority the LinstorCluster of BUILT names in spec.FIELD, apiTLS for its API or
# internalTLS for the link between the controller and the satellites, as JSON on one line: the one
# Certificate of the build that writes the Secret the Issuer of FIELD signs from. Fails, saying which
# link is missing, when there is none.
authority() {
  local issuer secret found
  issuer="$(FIELD="$1" yq -N 'select(.kind == "LinstorCluster") | .spec[strenv(FIELD)].certManager.name // ""' "$BUILT")"
  [ -n "$issuer" ] || { echo "the LinstorCluster names no issuer in spec.$1.certManager" >&2; return 1; }
  secret="$(cm_object Issuer "$issuer" | jq -r '.spec.ca.secretName // ""')"
  [ -n "$secret" ] || { echo "the Issuer $issuer signs from no authority's Secret (spec.ca)" >&2; return 1; }
  found="$(SECRET="$secret" yq -N -o json -I0 'select(.apiVersion == "cert-manager.io/v1" and .kind == "Certificate"
    and .spec.secretName == strenv(SECRET))' "$BUILT")"
  [ "$(grep -c . <<<"$found")" -eq 1 ] || { echo "$(grep -c . <<<"$found") Certificates of the build write the Secret $secret" >&2; return 1; }
  echo "$found"
}

# api_authority: the authority of LINSTOR's API, as authority apiTLS gives it.
api_authority() {
  authority apiTLS
}

# api_callers: every workload of the operator's templates, its patches left out, whose containers or
# init containers set LS_CONTROLLERS, the address of LINSTOR's API its clients read, one JSON object a
# line: its kind, name and file, relative to the repository, and those containers.
api_callers() {
  local file
  while IFS= read -r -d '' file; do
    FILE="${file#"$OPERATOR_SRC"/}" yq -N -o json -I0 'select(.spec.template.spec != null)
      | {"kind": .kind, "name": .metadata.name, "file": strenv(FILE),
         "containers": [(.spec.template.spec.initContainers // []) + (.spec.template.spec.containers // []) | .[]
           | select((.env // []) | any_c(.name == "LS_CONTROLLERS")) | .name]}
      | select(.containers | length > 0)' "$file"
  done < <(find "$OPERATOR_SRC/pkg/resources" -name '*.yaml' -not -path '*/patches/*' -print0 | LC_ALL=C sort -z)
}

# patch_containers FILE KIND NAME: each container and init container that the patch for KIND NAME in
# the operator's patch list FILE writes, with the patch's volumes beside it, as JSON lines.
patch_containers() {
  # shellcheck disable=SC2016 # $spec is a yq variable.
  KIND="$2" NAME="$3" yq -N -o json -I0 '.[] | select(.target.kind == strenv(KIND) and .target.name == strenv(NAME))
    | .patch | from_yaml | .spec.template.spec as $spec
    | (($spec.initContainers // []) + ($spec.containers // [])) | .[] | . + {"volumes": ($spec.volumes // [])}' "$1"
}

# renders PATCH: each function of the operator's internal/controller/patches.go that renders a patch
# list named PATCH, pkg/resources/cluster/patches/PATCH or pkg/resources/satellite/patches/PATCH, one
# a line.
renders() {
  awk -v want="\"patches/$1\"" '/^func [A-Za-z0-9_]+\(/ { name = $2; sub(/\(.*/, "", name) } index($0, want) { print name }' \
    "$OPERATOR_SRC/internal/controller/patches.go"
}

# client_certificate DIR: the name of the operator's Certificate template in
# pkg/resources/cluster/DIR whose one usage is client auth; fails unless there is one.
client_certificate() {
  local found
  found="$(yq -N -o json -I0 'select(.kind == "Certificate") | {"name": .metadata.name, "usages": .spec.usages}' \
    "$OPERATOR_SRC/pkg/resources/cluster/$1"/*.yaml | jq -r 'select(.usages == ["client auth"]) | .name')"
  [ "$(grep -c . <<<"$found")" -eq 1 ] || { echo "$1: $(grep -c . <<<"$found") client certificates in its cert-manager templates" >&2; return 1; }
  echo "$found"
}

# api_wiring: what the operator's patches for the API's address and apiTLS write into the workloads
# that call the API (pkg/resources/cluster/patches/api-endpoint.yaml and api-tls*.yaml), one a line:
# the environment variables their clients read, and the names and mount paths of the volumes the TLS
# patches add.
api_wiring() {
  # shellcheck disable=SC2016 # $s is a yq variable.
  yq -N '.[] | .patch | from_yaml | select(.spec.template.spec != null) | .spec.template.spec as $s
    | ((($s.initContainers // []) + ($s.containers // [])) as $c
      | [$c[] | (.env // [])[] | .name] + [($s.volumes // [])[] | .name] + [$c[] | (.volumeMounts // [])[] | .mountPath])
    | .[]' "$OPERATOR_SRC/pkg/resources/cluster/patches/api-endpoint.yaml" "$OPERATOR_SRC/pkg/resources/cluster/patches"/api-tls*.yaml |
    LC_ALL=C sort -u
}

# overrides: every name, mount path, port number and probe that the podTemplates and patches of the
# storage cluster's objects in BUILT write over the operator's own templates, and the name of every
# object such a patch targets, one a line: the object, a tab and the value.
overrides() {
  # shellcheck disable=SC2016 # $o is a yq variable.
  yq -N 'select(.apiVersion == "piraeus.io/*") | (.kind + "/" + .metadata.name) as $o
    | ([.spec | .. | select(tag == "!!map") | select(has("podTemplate")) | .podTemplate]
      + [(.spec.patches // [])[] | (.target // {}), (.patch | from_yaml)])
    | .[] | .. | select(tag == "!!map")
    | (((.name, .mountPath, .containerPort, .hostPort, .port) | select(tag == "!!str" or tag == "!!int") | tostring),
      (keys | .[] | select(test("Probe$"))))
    | $o + "\t" + .' "$BUILT"
}

# internal_configs: each ConfigMap that the operator's templates of the workloads its patches for
# internalTLS change (pkg/resources/cluster/patches/internal-tls.yaml and
# pkg/resources/satellite/patches/internal-tls.yaml) mount at the directory of a mount path those
# patches add, which holds the configuration the controller and the satellite read, one a line: its
# name, a tab and that directory.
internal_configs() {
  local kind name dir
  local tls=("$OPERATOR_SRC/pkg/resources/cluster/patches/internal-tls.yaml" "$OPERATOR_SRC/pkg/resources/satellite/patches/internal-tls.yaml")
  local template_files=()
  mapfile -t template_files < <(find "$OPERATOR_SRC/pkg/resources" -name '*.yaml' -not -path '*/patches/*' | LC_ALL=C sort)
  # shellcheck disable=SC2016 # $s, $t, $v and $n are yq variables.
  while IFS=$'\t' read -r kind name dir; do
    KIND="$kind" NAME="$name" DIR="$dir" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))
      | .spec.template.spec as $s
      | [($s.initContainers // []) + ($s.containers // []) | .[] | (.volumeMounts // [])[] | select(.mountPath == strenv(DIR)) | .name] as $v
      | ($s.volumes // [])[] | select(.name as $n | $v | any_c(. == $n)) | select(.configMap != null)
      | .configMap.name + "\t" + strenv(DIR)' "${template_files[@]}"
  done < <(yq -N '.[] | .target as $t | .patch | from_yaml | select(.spec.template.spec != null) | .spec.template.spec
    | (.initContainers // []) + (.containers // []) | .[] | (.volumeMounts // [])[]
    | $t.kind + "\t" + $t.name + "\t" + (.mountPath | sub("/[^/]+$"; ""))' "${tls[@]}" | LC_ALL=C sort -u) | LC_ALL=C sort -u
}

# internal_wiring: what the operator's patches for internalTLS write into the controller's and the
# satellites' workloads (pkg/resources/cluster/patches/internal-tls.yaml and
# pkg/resources/satellite/patches/internal-tls.yaml), one a line: the names and mount paths of the
# volumes they add, the ports they declare and the probes they set; and the ConfigMaps they patch or
# that internal_configs finds, with the directory each is mounted at.
internal_wiring() {
  local tls=("$OPERATOR_SRC/pkg/resources/cluster/patches/internal-tls.yaml" "$OPERATOR_SRC/pkg/resources/satellite/patches/internal-tls.yaml")
  {
    # shellcheck disable=SC2016 # $s and $c are yq variables, $patch a key of the patches.
    yq -N '.[] | .patch | from_yaml | select(.spec.template.spec != null) | .spec.template.spec as $s
      | (($s.initContainers // []) + ($s.containers // [])) as $c
      | [($s.volumes // [])[] | .name] + [$c[] | (.volumeMounts // [])[] | .mountPath]
        + [$c[] | (.ports // [])[] | select(has("$patch") | not) | .containerPort | tostring]
        + [$c[] | keys | .[] | select(test("Probe$"))]
      | .[]' "${tls[@]}"
    yq -N '.[] | select(.target.kind == "ConfigMap") | .target.name' "${tls[@]}"
    internal_configs | tr '\t' '\n'
  } | grep . | LC_ALL=C sort -u
}

# internal_targets: the objects the operator's patches for internalTLS change
# (pkg/resources/cluster/patches/internal-tls*.yaml and pkg/resources/satellite/patches/internal-tls*.yaml),
# and the ConfigMaps internal_configs finds, one a line: the kind, a tab, the name, a tab, and template
# for a workload whose pod template the patch changes or whole for an object whose content is what
# the wiring completes, a ConfigMap of the configuration or a Certificate.
internal_targets() {
  {
    # shellcheck disable=SC2016 # $p is a yq variable.
    yq -N '.[] | (.patch | from_yaml) as $p
      | .target.kind + "\t" + .target.name + "\t" + (if $p.spec.template.spec != null then "template" else "whole" end)' \
      "$OPERATOR_SRC/pkg/resources/cluster/patches"/internal-tls*.yaml "$OPERATOR_SRC/pkg/resources/satellite/patches"/internal-tls*.yaml
    internal_configs | awk -F '\t' '{ print "ConfigMap\t" $1 "\twhole" }'
  } | LC_ALL=C sort -u
}

# patched KIND NAME: each patch of the storage cluster's objects in BUILT that may change the object
# KIND NAME the operator makes, one a line: the object that carries it, a tab, and json6902 for a list
# of operations, which names what it changes by its path in the operator's object, or strategic for a
# strategic merge patch. A patch selects as kustomize selects it (pkg/utils/patch_convert.go): by its
# target, whose kind and name are regular expressions kustomize anchors and whose fields left out or
# empty select any, or, without one, by its own kind and name. A label or annotation selector, for
# which the operator's objects are not read here, is taken to select.
patched() {
  local object kind name type
  # shellcheck disable=SC2016 # $o, $p and $t are yq variables.
  while IFS=$'\t' read -r object kind name type; do
    if [[ $1 =~ ^($kind)$ && $2 =~ ^($name)$ ]]; then
      printf '%s\t%s\n' "$object" "$type"
    fi
  done < <(yq -N 'select(.apiVersion == "piraeus.io/*") | (.kind + "/" + .metadata.name) as $o
    | (.spec.patches // [])[] | (.patch | from_yaml) as $p
    | (if .target == null and ($p | tag) == "!!map" then {"kind": $p.kind, "name": $p.metadata.name} else .target // {} end) as $t
    | $o + "\t" + (if ($t.kind // "") == "" then ".*" else $t.kind end) + "\t" + (if ($t.name // "") == "" then ".*" else $t.name end)
      + "\t" + (if ($p | tag) == "!!seq" then "json6902" else "strategic" end)' "$BUILT")
}

# fills RESOURCES PATCH: the function of the operator's internal/controller/patches.go that renders the
# patch list pkg/resources/RESOURCES/patches/PATCH, RESOURCES being cluster or satellite, as its first
# line, and each parameter it fills, a line each: the parameter's name, a blank and the Go expression
# that fills it.
fills() {
  local name body
  for name in $(renders "$2"); do
    body="$(go_func "$OPERATOR_SRC/internal/controller/patches.go" "$name")"
    if grep -qxF "$1.Resources," <<<"$body" && grep -qxF "\"patches/$2\"," <<<"$body"; then
      echo "$name"
      sed -nE 's/^"([A-Z_]+)": (.*),$/\1 \2/p' <<<"$body"
    fi
  done
}

# api_names NAMESPACE: the DNS names the operator gives the controller's certificate when apiTLS names
# a cert-manager issuer, in place of its template's, for an operator in NAMESPACE, one a line
# (internal/controller/linstorcluster_controller.go).
api_names() {
  local go="$OPERATOR_SRC/internal/controller/linstorcluster_controller.go"
  grep -Eq 'ClusterApiTLSCertManagerPatch\(apiSecretName, lcluster\.Spec\.ApiTLS\.CertManager, serviceNames\)' "$go" ||
    { echo "the operator gives the controller's certificate other names than serviceNames" >&2; return 1; }
  sed -n '/serviceNames := \[\]string{/,/^[[:space:]]*}/p' "$go" |
    sed -nE 's/^[[:space:]]*(fmt\.Sprintf\()?"([^"]+)"(, r\.Namespace\))?,$/\2/p' | sed "s/%s/$1/"
}

# docker_or_skip: skips the test, saying why, where no docker daemon answers. Past it, whatever
# docker fails at fails the test, a pull of the image included.
docker_or_skip() {
  type -P docker >/dev/null || skip "no docker daemon answers: docker is not on PATH"
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1 ||
    skip "no docker daemon answers: docker version reaches none"
}

# in_docker ARG...: docker ARG..., run with none of the secrets the environment may hold, as the
# recipes run it (scripts/lib/tools.sh).
in_docker() {
  (
    # shellcheck source=scripts/lib/tools.sh
    . "$REPO/scripts/lib/tools.sh"
    docker "$@"
  )
}

# issue CERT_JSON NAME DIR [AUTHORITY]: DIR/NAME.crt and DIR/NAME.key, made with openssl as cert-manager
# makes the Certificate CERT_JSON: self-signed without AUTHORITY, as the SelfSigned issuer signs, or
# signed with DIR/AUTHORITY.crt and its key, as the CA issuer signs. The key is the one the Certificate
# names, RSA of 2048 bits when it names none, in the encoding cert-manager writes when it names none,
# PKCS#1, which is SEC 1 for ECDSA (pkg/util/pki/generate.go of cert-manager v1.21.3); the
# lifetime its duration, 90 days when it names none; the subject its common name, or empty; isCA a
# critical CA constraint; its usages, digital signature and key encipherment when it names none and
# cert sign added for an authority (pkg/util/pki/csr.go), the key usages critical, as Go marks them;
# and its DNS names, critical when the subject is empty (pkg/util/pki/certificatetemplate.go).
issue() {
  local cert=$1 name=$2 dir=$3 ca=${4:-} algorithm size duration ca_flag usage subject san
  local ku=() eku=()
  algorithm="$(jq -r '.spec.privateKey.algorithm // "RSA"' <<<"$cert")"
  size="$(jq -r '.spec.privateKey.size // 0' <<<"$cert")"
  [ "$(jq -r '.spec.privateKey.encoding // "PKCS1"' <<<"$cert")" = PKCS1 ] ||
    { echo "$name: the key encoding $(jq -r '.spec.privateKey.encoding' <<<"$cert") is not made here" >&2; return 1; }
  case $algorithm:$size in
    RSA:0) openssl genrsa -traditional -out "$dir/$name.key" 2048 2>/dev/null ;;
    RSA:*) openssl genrsa -traditional -out "$dir/$name.key" "$size" 2>/dev/null ;;
    ECDSA:0 | ECDSA:256) openssl ecparam -name prime256v1 -genkey -noout -out "$dir/$name.key" ;;
    ECDSA:384) openssl ecparam -name secp384r1 -genkey -noout -out "$dir/$name.key" ;;
    *) echo "$name: the key $algorithm $size is not made here" >&2 && return 1 ;;
  esac
  [ "$(head -n 1 "$dir/$name.key")" = "-----BEGIN $([ "$algorithm" = ECDSA ] && echo EC || echo RSA) PRIVATE KEY-----" ] ||
    { echo "$name: the key is not encoded as cert-manager writes it: $(head -n 1 "$dir/$name.key")" >&2; return 1; }
  duration="$(jq -r '.spec.duration // "2160h"' <<<"$cert")"
  [[ $duration =~ ^([0-9]+)h$ ]] || { echo "$name: the duration $duration is not in whole hours" >&2; return 1; }
  duration=$((BASH_REMATCH[1] / 24))
  ca_flag="$(jq -r '.spec.isCA // false' <<<"$cert")"
  if [ "$ca_flag" = true ]; then ku+=(keyCertSign); fi
  while IFS= read -r usage; do
    case $usage in
      "digital signature" | signing) ku+=(digitalSignature) ;;
      "key encipherment") ku+=(keyEncipherment) ;;
      "cert sign") ku+=(keyCertSign) ;;
      "server auth") eku+=(serverAuth) ;;
      "client auth") eku+=(clientAuth) ;;
      *) echo "$name: the usage $usage is not made here" >&2 && return 1 ;;
    esac
  done < <(jq -r 'if (.spec.usages // []) == [] then ["digital signature", "key encipherment"] else .spec.usages end | .[]' <<<"$cert")
  subject="$(jq -r 'if .spec.commonName then "/CN=" + .spec.commonName else "/" end' <<<"$cert")"
  san="$(jq -r '[(.spec.dnsNames // [])[] | "DNS:" + .] | join(",")' <<<"$cert")"
  {
    if [ "$ca_flag" = true ]; then echo "basicConstraints=critical,CA:TRUE"; fi
    if [ "${#ku[@]}" -gt 0 ]; then echo "keyUsage=critical,$(printf '%s\n' "${ku[@]}" | sort -u | paste -sd, -)"; fi
    if [ "${#eku[@]}" -gt 0 ]; then echo "extendedKeyUsage=$(printf '%s\n' "${eku[@]}" | sort -u | paste -sd, -)"; fi
    if [ -n "$san" ]; then echo "subjectAltName=$([ "$subject" = / ] && echo critical,)$san"; fi
  } >"$dir/$name.ext"
  openssl req -new -key "$dir/$name.key" -subj "$subject" -out "$dir/$name.csr"
  if [ -z "$ca" ]; then
    openssl x509 -req -in "$dir/$name.csr" -signkey "$dir/$name.key" -days "$duration" -sha256 \
      -extfile "$dir/$name.ext" -out "$dir/$name.crt" 2>/dev/null
  else
    openssl x509 -req -in "$dir/$name.csr" -CA "$dir/$ca.crt" -CAkey "$dir/$ca.key" -CAcreateserial \
      -days "$duration" -sha256 -extfile "$dir/$name.ext" -out "$dir/$name.crt" 2>/dev/null
  fi
}

# api_pki DIR NAMESPACE: the certificates of the controller's start, in DIR: the API's authority as its
# Certificate in BUILT, linstor-cluster built, states it; another authority made from the same
# Certificate, so of the same name, with a key of its own; and, as the operator's Certificate
# templates state them (pkg/resources/cluster/controller/cert-manager), the controller's server
# certificate, linstor-api-tls, with the DNS names the operator in NAMESPACE gives it in place of the
# template's, and the operator's client certificate, linstor-client-tls, signed by the API's
# authority, and the same client certificate signed by the other one.
api_pki() {
  local dir=$1 authority expected names templates="$OPERATOR_SRC/pkg/resources/cluster/controller/cert-manager"
  authority="$(api_authority)"
  echo "the API's authority: $authority"
  expected="$(api_names "$2")"
  issue "$authority" authority "$dir"
  issue "$authority" other-authority "$dir"
  issue "$(yq -N -o json -I0 'select(.kind == "Certificate" and .metadata.name == "linstor-api-tls")' "$templates"/api/*.yaml |
    NAMES="$expected" jq -c '.spec.dnsNames = (env.NAMES | split("\n"))')" server "$dir" authority
  names="$(openssl x509 -in "$dir/server.crt" -noout -ext subjectAltName | sed '1d' | tr ',' '\n' | sed -E 's/^[[:space:]]*DNS://')"
  echo "the controller's certificate holds: $(xargs <<<"$names")"
  [ "$(LC_ALL=C sort <<<"$names")" = "$(LC_ALL=C sort <<<"$expected")" ] ||
    { echo "the operator gives the controller's certificate the names $(xargs <<<"$expected")" >&2; return 1; }
  issue "$(yq -N -o json -I0 'select(.kind == "Certificate" and .metadata.name == "linstor-client-tls")' "$templates"/api-client/*.yaml)" client "$dir" authority
  issue "$(yq -N -o json -I0 'select(.kind == "Certificate" and .metadata.name == "linstor-client-tls")' "$templates"/api-client/*.yaml)" other-client "$dir" other-authority
}

# controller_start: starts, detached, the LINSTOR controller as the operator's template with its
# apiTLS patch runs it at the version the pinned chart runs (pkg/resources/cluster/controller and
# patches/api-tls.yaml), offline: the image the rendered chart's image list names; the container's
# arguments and the literal values of its environment, the leader election left out, as it needs an
# API server and the start has one controller; the user the LinstorCluster gives the pod, a read-only
# root, no capability and no privilege escalation; and each of the container's mounts: an empty
# directory for an emptyDir, the ConfigMap's files and the projected Secrets' tls.crt, tls.key and
# ca.crt, of mode 0644, the default of those volumes. The ConfigMap's linstor.toml is the patch's with
# its [db] table alone replaced by the image's own, a local database, as the k8s database the patch
# names needs an API server. The other authority's client certificate is mounted at
# /run/other-authority. The host the client configuration dials resolves to the loopback. Leaves
# linstor-cluster built in BUILT and sets CONTROLLER, the container, and START, the directory of what
# it mounts and read.
controller_start() {
  local image config spec user host patch path kind ro ns etc="" i
  local mounts=() envs=() args=()
  START="$BATS_TEST_TMPDIR/controller-start"
  mkdir -p "$START/pki" "$START/etc" "$START/api" "$START/client" "$START/other"
  render_operator
  # The image list the chart renders for the operator, with no override.
  config="$(yq -N 'select(.kind == "ConfigMap" and .data["0_piraeus_datastore_images.yaml"] != null)' "$RENDERED")"
  [ -z "$(yq '.data | keys | .[] | select(test("_helm_override"))' <<<"$config")" ] ||
    { echo "the chart's image list carries an override, which this start does not read"; return 1; }
  image="$(yq '.data["0_piraeus_datastore_images.yaml"] | from_yaml
    | .base + "/" + .components["linstor-controller"].image + ":" + .components["linstor-controller"].tag' <<<"$config")"
  echo "the controller's image: $image"
  operator_source
  ns="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  patch="$OPERATOR_SRC/pkg/resources/cluster/patches/api-tls.yaml"
  built piraeus-datastore linstor-cluster
  api_pki "$START/pki" "$ns"
  # The container as the template and the patch make it, which adds mounts and a port.
  spec="$START/spec.json"
  jq -s '.[0] as $base | .[1] as $patch
    | ($base.containers[] | select(.name == "linstor-controller")) as $c
    | ($patch.containers[] | select(.name == "linstor-controller")) as $p
    | {"container": ($c + {"volumeMounts": ($c.volumeMounts + $p.volumeMounts), "ports": ($c.ports + $p.ports)}),
       "volumes": ($base.volumes + $patch.volumes)}' \
    <(yq -o json '.spec.template.spec' "$OPERATOR_SRC/pkg/resources/cluster/controller/controller-deployment.yaml") \
    <(yq -o json '.[] | select(.target.kind == "Deployment" and .target.name == "linstor-controller") | .patch | from_yaml
      | .spec.template.spec' "$patch") >"$spec"
  [ "$(jq -r '.container.securityContext.readOnlyRootFilesystem' "$spec")" = true ]
  user="$(yq -N 'select(.kind == "LinstorCluster") | .spec.controller.podTemplate.spec.securityContext
    | (.runAsUser // "" | tostring) + ":" + (.runAsGroup // "" | tostring)' "$BUILT")"
  [[ $user =~ ^[1-9][0-9]*:[0-9]+$ ]] || { echo "the LinstorCluster gives the controller's pod no user that is not root: $user"; return 1; }
  # The ConfigMap's files: the patch's, linstor.toml with the image's [db].
  yq '.[] | select(.target.kind == "ConfigMap" and .target.name == "linstor-controller-config") | .patch | from_yaml
    | .data["linstor.toml"]' "$patch" >"$START/patch.toml"
  grep -q '^[[:space:]]*connection_url = "k8s"$' "$START/patch.toml"
  in_docker run --rm --network none --entrypoint cat "$image" /etc/linstor/linstor.toml >"$START/image.toml"
  {
    awk '/^[[:space:]]*\[/ { keep = ($0 !~ /^[[:space:]]*\[db[].]/) } keep' "$START/patch.toml"
    awk '/^[[:space:]]*\[/ { keep = ($0 ~ /^[[:space:]]*\[db[].]/) } keep' "$START/image.toml"
  } >"$START/etc/linstor.toml"
  grep -q '^\[https\]$' "$START/etc/linstor.toml"
  yq '.[] | select(.target.kind == "ConfigMap" and .target.name == "linstor-controller-config") | .patch | from_yaml
    | .data["linstor-client.conf"]' "$patch" >"$START/etc/linstor-client.conf"
  echo "linstor.toml:"; cat "$START/etc/linstor.toml"
  echo "linstor-client.conf:"; cat "$START/etc/linstor-client.conf"
  # The Secrets: the controller's own, and the client's the CLI reads, each with the authority as
  # ca.crt, as a CA issuer writes it; the operator's projection of each, without a CA reference, is
  # the Secret twice.
  cp "$START/pki/server.crt" "$START/api/tls.crt"
  cp "$START/pki/server.key" "$START/api/tls.key"
  cp "$START/pki/client.crt" "$START/client/tls.crt"
  cp "$START/pki/client.key" "$START/client/tls.key"
  cp "$START/pki/authority.crt" "$START/api/ca.crt"
  cp "$START/pki/authority.crt" "$START/client/ca.crt"
  cp "$START/pki/other-client.crt" "$START/other/tls.crt"
  cp "$START/pki/other-client.key" "$START/other/tls.key"
  chmod 0755 "$START/etc" "$START/api" "$START/client" "$START/other"
  chmod 0644 "$START"/etc/* "$START"/api/* "$START"/client/* "$START"/other/*
  while IFS=$'\t' read -r path kind ro; do
    # shellcheck disable=SC2016 # The patch's placeholders, which the operator replaces, are literal.
    case $kind in
      emptyDir) mounts+=(--tmpfs "$path:mode=0777") ;;
      configMap/linstor-controller-config)
        etc="$path"
        mounts+=(-v "$START/etc:$path:ro")
        ;;
      'projected/$LINSTOR_API_TLS_SECRET_NAME') mounts+=(-v "$START/api:$path:ro") ;;
      'projected/$LINSTOR_API_TLS_CLIENT_SECRET_NAME') mounts+=(-v "$START/client:$path:ro") ;;
      *) echo "the controller mounts $kind at $path, which this start does not stand in for"; return 1 ;;
    esac
    [ "$kind" = emptyDir ] || [ "$ro" = true ] || { echo "the controller mounts $kind at $path writable"; return 1; }
  done < <(jq -r '.volumes as $volumes | .container.volumeMounts[] | . as $m | ($volumes[] | select(.name == $m.name)) as $v
    | [$m.mountPath, (if $v.emptyDir then "emptyDir" elif $v.configMap then "configMap/" + $v.configMap.name
        elif $v.projected then "projected/" + ([$v.projected.sources[] | objects | .secret.name // empty] | unique | join(","))
        else "other" end),
       ($m.readOnly // false | tostring)] | @tsv' "$spec")
  # The mounts under the ConfigMap's directory need their mount points in it, which the kubelet makes.
  [ -n "$etc" ]
  while read -r path; do
    mkdir -p "$START/etc/${path#"$etc"/}"
  done < <(jq -r --arg etc "$etc" '.container.volumeMounts[].mountPath | select(startswith($etc + "/"))' "$spec")
  while IFS= read -r -d '' i; do
    envs+=(-e "$i")
  done < <(jq -j '.container.env[] | select(has("value") and (.name | startswith("K8S_AWAIT_ELECTION_") | not))
    | .name + "=" + .value + "\u0000"' "$spec")
  mapfile -t args < <(jq -r '.container.args[]' "$spec")
  host="$(sed -nE 's#^controllers *= *https://([^:/]+):[0-9]+$#\1#p' "$START/etc/linstor-client.conf")"
  [ -n "$host" ]
  CONTROLLER="linstor-controller-start-$$-$RANDOM"
  in_docker run --detach --name "$CONTROLLER" --network none --cap-drop ALL --security-opt no-new-privileges \
    --user "$user" --read-only --add-host "$host:127.0.0.1" "${mounts[@]}" -v "$START/other:/run/other-authority:ro" \
    "${envs[@]}" "$image" "${args[@]}" >/dev/null
  for ((i = 0; i < 120; i++)); do
    [ "$(in_docker inspect --format '{{.State.Running}}' "$CONTROLLER")" = true ] || break
    if in_docker exec "$CONTROLLER" curl -fsS -o /dev/null --max-time 2 \
      "http://localhost:$(jq -r '.container.ports[] | select(.name == "api") | .containerPort' "$spec")/health" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  in_docker logs "$CONTROLLER" 2>&1 | tail -n 40
  echo "the controller did not answer its health check"
  return 1
}

# internal_pki DIR: the certificates of the satellite's start, in DIR, made with issue as the build's
# issuers make them, linstor-cluster built in BUILT: the internal authority, as the Certificate of the
# issuer of internalTLS states it; another authority made from the same Certificate, so of the same
# name, with a key of its own; the API's authority; and, as the operator's Certificate templates state
# them, the satellite's server certificate (pkg/resources/satellite/satellite/cert-manager) with the
# name of the node, SATELLITE_NODE, as its DNS name, as the operator gives it, signed by the internal
# authority; the controller's client certificate (pkg/resources/cluster/controller/cert-manager/internal),
# signed by the internal authority and, separately, by the other one; and the operator's client
# certificate of the API, linstor-client-tls, signed by the API's authority.
internal_pki() {
  local dir=$1 internal controller templates="$OPERATOR_SRC/pkg/resources"
  internal="$(authority internalTLS)"
  echo "the internal authority: $internal"
  issue "$internal" internal-ca "$dir"
  issue "$internal" other-ca "$dir"
  issue "$(authority apiTLS)" api-ca "$dir"
  issue "$(yq -N -o json -I0 'select(.kind == "Certificate")' "$templates/satellite/satellite/cert-manager"/*.yaml |
    NODE="$SATELLITE_NODE" jq -c '.spec.dnsNames = [env.NODE]')" satellite "$dir" internal-ca
  controller="$(NAME="$(client_certificate controller/cert-manager/internal)" yq -N -o json -I0 \
    'select(.kind == "Certificate" and .metadata.name == strenv(NAME))' "$templates/cluster/controller/cert-manager/internal"/*.yaml)"
  issue "$controller" controller "$dir" internal-ca
  issue "$controller" other-controller "$dir" other-ca
  issue "$(yq -N -o json -I0 'select(.kind == "Certificate" and .metadata.name == "linstor-client-tls")' \
    "$templates/cluster/controller/cert-manager/api-client"/*.yaml)" api-client "$dir" api-ca
}

# satellite_start: starts, detached, the LINSTOR satellite as its pod runs it at the version the pinned
# chart runs, the operator's DaemonSet with its internalTLS patch and every satellite configuration
# applied (satellite), offline: the image the rendered chart's image list names; the arguments of the
# container linstor-satellite and the literal values of its environment; a user that is not root, a
# read-only root, no capability and no privilege escalation; and each of the container's mounts stood
# in for by its kind: the ConfigMap satellite-config by a directory of its files as the operator
# writes them, with the mount points of the mounts inside it made, as the kubelet makes them; the
# projected Secret by tls.crt, tls.key and ca.crt of mode 0644, the volume's default, here the
# satellite's certificate and key and the internal authority of internal_pki; each emptyDir and each
# host path by an empty tmpfs, never the host's own path; the ConfigMap talos-lvm-config by the
# build's; any other fails the start. Every certificate and key of internal_pki is mounted at
# /run/probes for the calls made from inside the container. Leaves linstor-cluster built in BUILT and
# sets SATELLITE_CONTAINER, the container, and SAT, the directory of what it mounts and read.
satellite_start() {
  local image config spec path kind ro tmpfs etc="" i port
  local mounts=() envs=() args=()
  SAT="$BATS_TEST_TMPDIR/satellite-start"
  mkdir -p "$SAT/pki" "$SAT/etc" "$SAT/pem" "$SAT/lvm" "$SAT/probes"
  render_operator
  # The image list the chart renders for the operator, with no override.
  config="$(yq -N 'select(.kind == "ConfigMap" and .data["0_piraeus_datastore_images.yaml"] != null)' "$RENDERED")"
  [ -z "$(yq '.data | keys | .[] | select(test("_helm_override"))' <<<"$config")" ] ||
    { echo "the chart's image list carries an override, which this start does not read"; return 1; }
  image="$(yq '.data["0_piraeus_datastore_images.yaml"] | from_yaml
    | .base + "/" + .components["linstor-satellite"].image + ":" + .components["linstor-satellite"].tag' <<<"$config")"
  echo "the satellite's image: $image"
  satellite
  internal_pki "$SAT/pki"
  spec="$SAT/spec.json"
  yq -o json 'select(.kind == "DaemonSet" and .metadata.name == "linstor-satellite") | .spec.template.spec
    | {"container": (.containers[] | select(.name == "linstor-satellite")), "volumes": .volumes}' "$SATELLITE" >"$spec"
  [ "$(jq -r '.container.securityContext.readOnlyRootFilesystem' "$spec")" = true ]
  # The ConfigMaps' files: satellite-config's as the operator's resources and its internalTLS patch make
  # it, talos-lvm-config's as the build applies it, each readable by the user the start runs as.
  yq -o json 'select(.kind == "ConfigMap" and .metadata.name == "satellite-config") | .data' "$SATELLITE" >"$SAT/etc.json"
  yq -o json 'select(.kind == "ConfigMap" and .metadata.name == "talos-lvm-config") | .data' "$BUILT" >"$SAT/lvm.json"
  for i in etc lvm; do
    while IFS= read -r path; do
      jq -j --arg key "$path" '.[$key]' "$SAT/$i.json" >"$SAT/$i/$path"
    done < <(jq -r 'keys[]' "$SAT/$i.json")
  done
  echo "linstor_satellite.toml:"; cat "$SAT/etc/linstor_satellite.toml"
  # The Secret <node>-tls, as a CA issuer writes it: the certificate, its key and the authority as
  # ca.crt; the operator's projection of it, without a CA reference, is the Secret twice.
  cp "$SAT/pki/satellite.crt" "$SAT/pem/tls.crt"
  cp "$SAT/pki/satellite.key" "$SAT/pem/tls.key"
  cp "$SAT/pki/internal-ca.crt" "$SAT/pem/ca.crt"
  cp "$SAT/pki"/*.crt "$SAT/pki"/*.key "$SAT/probes/"
  chmod 0755 "$SAT/etc" "$SAT/pem" "$SAT/lvm" "$SAT/probes"
  chmod 0644 "$SAT"/etc/* "$SAT"/pem/* "$SAT"/lvm/* "$SAT"/probes/*
  while IFS=$'\t' read -r path kind ro; do
    tmpfs="$path:mode=0777"
    if [ "$ro" = true ]; then tmpfs+=",ro"; fi
    case $kind in
      # The node's /dev is not given to the start: docker's own, which holds the devices a container
      # needs, stays.
      hostPath/*) [ "$path" = /dev ] || mounts+=(--tmpfs "$tmpfs") ;;
      emptyDir) mounts+=(--tmpfs "$tmpfs") ;;
      configMap/satellite-config)
        etc="$path"
        mounts+=(-v "$SAT/etc:$path:ro")
        ;;
      configMap/talos-lvm-config) mounts+=(-v "$SAT/lvm:$path:ro") ;;
      "projected/$SATELLITE_NODE-tls") mounts+=(-v "$SAT/pem:$path:ro") ;;
      *) echo "the satellite mounts $kind at $path, which this start does not stand in for"; return 1 ;;
    esac
    [[ $kind != configMap/* && $kind != projected/* ]] || [ "$ro" = true ] || { echo "the satellite mounts $kind at $path writable"; return 1; }
  done < <(jq -r '.volumes as $volumes | .container.volumeMounts[] | . as $m | ($volumes[] | select(.name == $m.name)) as $v
    | [$m.mountPath, (if $v.emptyDir then "emptyDir" elif $v.hostPath then "hostPath/" + $v.hostPath.path
        elif $v.configMap then "configMap/" + $v.configMap.name
        elif $v.projected then "projected/" + ([$v.projected.sources[] | objects | .secret.name // empty] | unique | join(","))
        else "other" end),
       ($m.readOnly // false | tostring)] | @tsv' "$spec")
  [ -n "$etc" ]
  while read -r path; do
    mkdir -p "$SAT/etc/${path#"$etc"/}"
  done < <(jq -r --arg etc "$etc" '.container.volumeMounts[].mountPath | select(startswith($etc + "/"))' "$spec")
  # LB_FORCE_NODE_NAME, which the pod takes from its node's name, is not a literal value: the
  # entrypoint gives the satellite that name as its host name in a UTS namespace of its own, which
  # takes a capability this start does not have, and the satellite runs under the container's.
  while IFS= read -r -d '' i; do
    envs+=(-e "$i")
  done < <(jq -j '.container.env[] | select(has("value")) | .name + "=" + .value + "\u0000"' "$spec")
  mapfile -t args < <(jq -r '.container.args[]' "$spec")
  port="$(jq -r '.container.ports[] | select(.name == "linstor") | .containerPort' "$spec")"
  [ -n "$port" ]
  SATELLITE_CONTAINER="linstor-satellite-start-$$-$RANDOM"
  # The pod runs it privileged as root; the start runs it as nobody, which its SSL connector starts as.
  in_docker run --detach --name "$SATELLITE_CONTAINER" --network none --cap-drop ALL --security-opt no-new-privileges \
    --user 65534:65534 --read-only "${mounts[@]}" -v "$SAT/probes:/run/probes:ro" "${envs[@]}" "$image" "${args[@]}" >/dev/null
  # Started once something takes a connection on the port linstor, as the pod's startup probe asks.
  for ((i = 0; i < 120; i++)); do
    [ "$(in_docker inspect --format '{{.State.Running}}' "$SATELLITE_CONTAINER")" = true ] || break
    if in_docker exec "$SATELLITE_CONTAINER" socat -u OPEN:/dev/null "TCP:localhost:$port" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  in_docker logs "$SATELLITE_CONTAINER" 2>&1 | tail -n 40
  echo "the satellite took no connection on $port"
  return 1
}

# satellite_refuses LOGGED [ARG...]: a TLS 1.2 handshake with the started satellite on its port
# linstor, made with openssl s_client from inside its container with ARG..., fails as the pinned
# satellite fails one, seen in the run that pinned it: it ends the connection without sending its
# alert, so s_client exits 1 having read the connection's end, and it logs one SSL error, the alert and
# its reason, LOGGED.
satellite_refuses() {
  local logged=$1 before i log
  shift
  before="$(in_docker logs "$SATELLITE_CONTAINER" 2>&1 | grep -c 'SSL error:' || true)"
  run in_docker exec "$SATELLITE_CONTAINER" timeout 20 openssl s_client -connect \
    "localhost:$(jq -r '.container.ports[] | select(.name == "linstor") | .containerPort' "$SAT/spec.json")" -tls1_2 "$@"
  echo "s_client ${*:-without a certificate}: $status"
  grep -E 'error|alert' <<<"$output" || true
  [ "$status" -eq 1 ]
  [[ $output == *':SSL routines::unexpected eof while reading:'* ]]
  for ((i = 0; i < 50; i++)); do
    log="$(in_docker logs "$SATELLITE_CONTAINER" 2>&1 | grep 'SSL error:' | tail -n +$((before + 1)))"
    if [ -n "$log" ]; then break; fi
    sleep 0.1
  done
  echo "the satellite logs: ${log:-nothing}"
  [ "$(grep -c . <<<"$log")" -eq 1 ]
  [[ $log == *"SSL error: $logged" ]]
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
  [ "$depends" = "cert-manager piraeus-operator snapshot-controller" ]
  # Its issuers and certificates are cert-manager's kinds, which cert-manager's webhook admits: it
  # starts once cert-manager's release is Ready.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "cert-manager") | .spec.wait' "$OVERLAY")" = true ]
  # linstor-cluster is Ready only once the operator reports the storage cluster Available, its
  # controller answering, and every satellite configuration Applied, each at the generation it
  # holds: kstatus reads neither from these kinds, which carry no Ready condition.
  local exprs
  [ "$(yq -N 'select(.metadata.name == "linstor-cluster") | .spec.wait' "$OVERLAY")" = true ]
  exprs="$(yq -N -o json -I0 'select(.metadata.name == "linstor-cluster") | .spec.healthCheckExprs // [] | .[]' "$OVERLAY")"
  echo "linstor-cluster health: ${exprs:-none}"
  jq -e -s 'any(.[]; .apiVersion == "piraeus.io/v1" and .kind == "LinstorCluster"
    and (.current | test("type == .Available.") and test("status == .True.") and test("observedGeneration == metadata.generation")))' <<<"$exprs"
  jq -e -s 'any(.[]; .apiVersion == "piraeus.io/v1" and .kind == "LinstorSatelliteConfiguration"
    and (.current | test("type == .Applied.") and test("status == .True.") and test("observedGeneration == metadata.generation")))' <<<"$exprs"
  # The satellites, the CSI node plugin and the HA controller run privileged with host paths.
  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "piraeus-datastore")
    | .metadata.labels["pod-security.kubernetes.io/enforce"]' "$OVERLAY")" = privileged ]
}

@test "The storage cluster's Kustomization waits long enough for a first install" {
  overlay
  # The root's defaults give a child 3m to become ready, and a child with this label 10m
  # (tests/kubernetes-check.bats); the storage cluster may take longer than 3m to report Available.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "linstor-cluster")
    | .metadata.labels["k8s-gitops/timeout"]' "$OVERLAY")" = long ]
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

@test "Satellites run in their node's network namespace and register the node's address" {
  local pod='select(.kind == "DaemonSet") | .spec.template.spec' configs dialers namespaces names state ready node wanted kept
  satellite
  # On the node's network, as Piraeus' how-to puts it (docs/how-to/drbd-host-networking.md of the
  # operator): DRBD's connections belong to the network namespace that configured them, and the
  # node's outlives every satellite pod. The default DNS policy, which on the host network is the
  # node's resolver.
  echo "the satellite's pod: hostNetwork $(yq -N "$pod | .hostNetwork" "$SATELLITE"), dnsPolicy $(yq -N "$pod | .dnsPolicy" "$SATELLITE")"
  [ "$(yq -N "$pod | .hostNetwork" "$SATELLITE")" = true ]
  [ "$(yq -N "$pod | .dnsPolicy" "$SATELLITE")" = null ]
  # Set by one configuration, in its podTemplate or a patch, which applies to every satellite and
  # sets nothing else.
  configs="$(yq -N -o json -I0 'select(.kind == "LinstorSatelliteConfiguration")
    | select([.spec.podTemplate, ((.spec.patches // [])[] | .patch | from_yaml)] | [.. | select(tag == "!!map" and has("hostNetwork"))] | length > 0)
    | {"name": .metadata.name, "spec": .spec}' "$BUILT")"
  echo "configurations that set hostNetwork: ${configs:-none}"
  [ "$(grep -c . <<<"$configs")" -eq 1 ]
  [ "$(jq -c '.spec' <<<"$configs")" = '{"podTemplate":{"spec":{"hostNetwork":true}}}' ]
  # It dials nothing by a name the cluster's DNS serves, which the node's resolver does not: no
  # container or init container is given the controller's address, LS_CONTROLLERS, or names a
  # Service or a name of the cluster's domain, whole or as <name>.<namespace> of a namespace of the
  # tree or default, which only the cluster's search domains complete.
  dialers="$(yq -N "$pod | (.initContainers // []) + .containers | .[] | select((.env // []) | any_c(.name == \"LS_CONTROLLERS\")) | .name" "$SATELLITE")"
  echo "containers given the controller's address: ${dialers:-none}"
  [ -z "$dialers" ]
  namespaces="$(find "$REPO/kubernetes/apps/base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | paste -sd '|')"
  [ -n "$namespaces" ]
  names="$(yq -N "$pod | (.initContainers // []) + .containers | .[] | .. | select(tag == \"!!str\")" "$SATELLITE" |
    grep -E "[.]svc([.:/]|\$)|cluster[.]local[.]?([:/]|\$)|[a-z0-9][.]($namespaces|default)([.:/]|\$)" || true)"
  echo "cluster names in its containers: ${names:-none}"
  [ -z "$names" ]

  # The operator at the version the chart runs registers the node in LINSTOR once the satellite's pod
  # is ready, with the interface default-ipv4 at the pod's IPv4 address, which on the host network
  # is the node's own (internal/controller/linstorsatellite_controller.go).
  state="$(go_func "$OPERATOR_SRC/internal/controller/linstorsatellite_controller.go" reconcileLinstorSatelliteState)"
  ready="$(go_func "$OPERATOR_SRC/internal/controller/linstorsatellite_controller.go" getReadyPod)"
  grep -qxF 'pod, err := r.getReadyPod(ctx, lsatellite)' <<<"$state"
  [ "$(grep -cxF 'return pod, nil' <<<"$ready")" -eq 1 ]
  [ "$(grep -xF -B1 'return pod, nil' <<<"$ready" | head -n 1)" = \
    'if condition.Type == corev1.PodReady && condition.Status == corev1.ConditionTrue {' ]
  grep -qxF 'for _, podIP := range pod.Status.PodIPs {' <<<"$state"
  grep -qxF 'ip := net.ParseIP(podIP.IP)' <<<"$state"
  [ "$(grep -xF -A1 'case ip.To4() != nil:' <<<"$state" | tail -n 1)" = 'name = "default-ipv4"' ]
  [ "$(sed -n '/^netIfs = append(netIfs, lapi.NetInterface{$/,/^})$/p' <<<"$state" | grep -xE 'Name: .*|Address: .*' | paste -sd " ")" = \
    'Name: name, Address: ip,' ]
  node="$(sed -n '/^lnode, err := lc.CreateOrUpdateNode(ctx, lapi.Node{$/,/^})$/p' <<<"$state")"
  echo "the node it registers: $(paste -sd " " <<<"$node")"
  grep -qxF 'Name: pod.Spec.NodeName,' <<<"$node"
  grep -qxF 'NetInterfaces: netIfs,' <<<"$node"
  # No configuration leaves IPv4 out of what it registers.
  [ -z "$(yq -N 'select(.kind == "LinstorSatelliteConfiguration") | select(.spec.ipFamilies != null)
    | select((.spec.ipFamilies | any_c(. == "IPv4")) | not) | .metadata.name' "$BUILT")" ]
  # And changes the address of an existing interface of that name in place: its client of LINSTOR's
  # API (pkg/linstorhelper/client.go) creates the node only when LINSTOR has none of that name,
  # deletes no node, modifies a wanted interface it finds and creates one it does not, and deletes
  # only an interface it manages that is no longer wanted.
  node="$(go_func "$OPERATOR_SRC/pkg/linstorhelper/client.go" CreateOrUpdateNode)"
  wanted="$(go_func "$OPERATOR_SRC/pkg/linstorhelper/client.go" ensureWantedInterface)"
  [ "$(grep -cF 'c.Nodes.Create(' <<<"$node")" -eq 1 ]
  [ "$(grep -xF -B5 'if err := c.Nodes.Create(ctx, node); err != nil {' <<<"$node" | grep -cxF 'if !errors.Is(err, lapi.NotFoundError) {')" -eq 1 ]
  [ "$(grep -cE 'Nodes[.](Delete|Lost)[(]' <<<"$node")" -eq 0 ]
  [ "$(grep -xF -A1 'for _, nic := range node.NetInterfaces {' <<<"$node" | tail -n 1)" = 'err = c.ensureWantedInterface(ctx, existingNode, nic)' ]
  kept="$(sed -n '/^for _, existingNic := range existingNode.NetInterfaces {$/,/DeleteNetinterface/p' <<<"$node")"
  grep -qxF 'if slices.ContainsFunc(node.NetInterfaces, func(netInterface lapi.NetInterface) bool {' <<<"$kept"
  [ "$(grep -xF -A2 'return netInterface.Name == existingNic.Name' <<<"$kept" | tail -n 1)" = continue ]
  [ "$(grep -cF 'DeleteNetinterface' <<<"$node")" -eq 1 ]
  echo "for a wanted interface: $(paste -sd " " <<<"$wanted")"
  [ "$(grep -xF -A1 'if nodeIf.Name != wanted.Name {' <<<"$wanted" | tail -n 1)" = continue ]
  grep -qxF 'return c.Nodes.ModifyNetInterface(ctx, node.Name, wanted.Name, wanted)' <<<"$wanted"
  grep -qxF 'return c.Nodes.CreateNetInterface(ctx, node.Name, wanted)' <<<"$wanted"
  [ "$(grep -c 'Delete' <<<"$wanted")" -eq 0 ]
}

@test "Every node admits the satellites, DRBD's replication and the DRBD reactor from those who use them" {
  local inventory="$REPO/talos/firewall.yaml" listeners declared protocol port admitting drbd overlapping moved
  # The ports of the one rule that admits each declared port: the satellite's, 3366 and 3367, as the
  # operator registers a satellite on either (internal/controller/linstorsatellite_controller.go),
  # and the reactor's alone.
  local -A spans=([3367]='["3366-3367"]' [9942]='["9942"]')
  satellite
  # TCP and UDP listeners of the nodes' firewall, each with its ports as [low, high].
  listeners="$(yq -o json -I0 '.listeners' "$inventory" |
    jq -c '[.[] | . + {"ranges": [.ports[] | tostring | split("-") | map(tonumber) | [.[0], .[-1]]]}]')"
  # Every port the satellite's containers and init containers declare: LINSTOR's satellite port, 3367
  # over TLS, and the DRBD reactor's metrics, which on the node's network are ports of the node itself.
  declared="$(yq -N 'select(.kind == "DaemonSet") | .spec.template.spec | (.initContainers // []) + .containers | .[]
    | (.ports // [])[] | ((.protocol // "TCP") | downcase) + " " + (.containerPort | tostring)' "$SATELLITE" | sort -u)"
  echo "the satellite's pod declares: $(xargs <<<"$declared")"
  [ "$(xargs <<<"$declared")" = "tcp 3367 tcp 9942" ]
  while read -r protocol port; do
    admitting="$(jq -c --arg protocol "$protocol" --argjson port "$port" '[.[] | select(.protocol == $protocol
      and any(.ranges[]; .[0] <= $port and $port <= .[1]))]' <<<"$listeners")"
    echo "$protocol $port: admitted by $(jq -c 'map({name, ports, nodes, from})' <<<"$admitting")"
    # One rule, on every node, from the nodes' own addresses, which a pod on another node arrives
    # from, and from the pod range, which a pod on the node itself arrives from.
    [ "$(jq 'length' <<<"$admitting")" -eq 1 ]
    [ "$(jq -c '.[0].ports | map(tostring)' <<<"$admitting")" = "${spans[$port]}" ]
    [ "$(jq -r '.[0].nodes' <<<"$admitting")" = all ]
    [ "$(jq -c '.[0].from | sort' <<<"$admitting")" = '["members","pods"]' ]
  done <<<"$declared"

  # DRBD's replication: LINSTOR gives each volume a TCP port on each node from its range, by default
  # 7000 to 7999 (server/src/main/java/com/linbit/linstor/core/objects/Node.java of linstor-server
  # v1.35.3, lines 89-90, the satellite image of the operator's version), on which DRBD in the kernel
  # listens at the node's address and connects to its peers from theirs.
  drbd=7000-7999
  overlapping="$(jq -c --argjson low "${drbd%-*}" --argjson high "${drbd#*-}" '[.[] | select(.protocol == "tcp"
    and any(.ranges[]; .[0] <= $high and $low <= .[1]))]' <<<"$listeners")"
  echo "TCP rules for ports of $drbd: $(jq -c 'map({name, ports, nodes, from})' <<<"$overlapping")"
  [ "$(jq 'length' <<<"$overlapping")" -eq 1 ]
  [ "$(jq -c '.[0].ports | map(tostring)' <<<"$overlapping")" = "[\"$drbd\"]" ]
  [ "$(jq -r '.[0].nodes' <<<"$overlapping")" = all ]
  # The kernels connect to each other from the nodes' own addresses, and nothing else does.
  [ "$(jq -c '.[0].from' <<<"$overlapping")" = '["members"]' ]
  # Nothing in the tree moves that range or the interface LINSTOR takes a resource's address from: a
  # resource's address is its node's PrefNic interface, else the one named default, else the node's
  # first (satellite/src/main/java/com/linbit/linstor/layer/drbd/resfiles/ConfFileBuilder.java of
  # linstor-server v1.35.3).
  moved="$(grep -rliE 'TcpPortAutoRange|PrefNic' "$REPO/kubernetes" || true)"
  echo "files that set LINSTOR's port range or preferred interface: ${moved:-none}"
  [ -z "$moved" ]
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

@test "No update of the Piraeus operator or the storage cluster merges itself" {
  local rules chart held
  # A rule that comes after the auto-merge switch, so that it wins over it, holds back every file of
  # the operator and the storage cluster and holds no other key, which would narrow what it matches;
  # and no rule after the switch turns merging on again, for them or for anything.
  rules="$(grep -v '^[[:space:]]*//' "$REPO/.renovate/automerge.json5" | yq -o json -I0 '.packageRules')"
  [ "$(jq -r '(map(.matchFileNames == ["kubernetes/**"] and .matchUpdateTypes == ["minor", "patch"] and has("automerge")) | index(true)) as $switch
    | if $switch == null then error("the auto-merge switch is not a rule of the file") else . end
    | to_entries | map(select(.key > $switch and .value.automerge == false and .value.matchFileNames == ["kubernetes/apps/base/piraeus-datastore/**"]
        and ((.value | keys) - ["automerge", "description", "matchFileNames"] | length) == 0)) | length' <<<"$rules")" -eq 1 ]
  [ "$(jq -r '(map(.matchFileNames == ["kubernetes/**"] and .matchUpdateTypes == ["minor", "patch"] and has("automerge")) | index(true)) as $switch
    | .[$switch + 1:] | map(select(has("automerge") and .automerge != false)) | length' <<<"$rules")" -eq 0 ]
  # The operator's chart, by the name Renovate reads it under, is pinned only where that rule holds
  # it back.
  chart="$(yq '.spec.url | sub("^oci://"; "")' "$REPO/kubernetes/apps/base/piraeus-datastore/piraeus-operator/app/ocirepository.yaml")"
  held="$(awk -F'\t' -v chart="$chart" '$3 == chart {print $1}' "$REPO/.renovate/extracted.tsv" | LC_ALL=C sort -u)"
  echo "$chart is read from: $held"
  [ -n "$held" ]
  [ -z "$(grep -v '^kubernetes/apps/base/piraeus-datastore/' <<<"$held" || true)" ]
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

@test "Only holders of a certificate from the storage cluster's API authority call LINSTOR's API" {
  local ns tls issuer ca bootstrap signed depends go patches resources caller kind name file comp container
  local tls_patch candidate cert renderer secret callers=() components=() names url conf port service wiring written
  operator_source
  # The operator makes its Certificates in its own namespace, the release's, where a Certificate's
  # issuer of kind Issuer is looked up.
  ns="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  echo "the operator's namespace: $ns"
  [ -n "$ns" ]
  built piraeus-datastore linstor-cluster
  tls="$(yq -N -o json -I0 'select(.kind == "LinstorCluster") | .spec.apiTLS // null' "$BUILT")"
  echo "apiTLS: $tls"
  # By cert-manager and nothing else: the operator writes its Certificates' Secrets under its default
  # names and each side trusts the ca.crt the issuer writes beside a certificate, so no Secret name
  # and no CA reference points anything at a Secret no Certificate of the issuer writes.
  [ "$(jq -c 'keys' <<<"$tls")" = '["certManager"]' ]
  [ "$(jq -c '.certManager | [.group, .kind]' <<<"$tls")" = '["cert-manager.io","Issuer"]' ]
  issuer="$(cm_object Issuer "$(jq -r '.certManager.name' <<<"$tls")")"
  echo "the API's issuer: $issuer"
  [ "$(jq -r '.metadata.namespace' <<<"$issuer")" = "$ns" ]
  # Of kind CA, signing from the Secret of an authority the build makes, which only that authority's
  # Certificate writes and the build's own self-signed Issuer issues.
  [ "$(jq -c '.spec | keys' <<<"$issuer")" = '["ca"]' ]
  ca="$(api_authority)"
  echo "its authority: $ca"
  [ "$(jq -r '.metadata.namespace' <<<"$ca")" = "$ns" ]
  [ "$(jq -r '.spec.isCA' <<<"$ca")" = true ]
  [ "$(jq -c '.spec.issuerRef | [.group // "cert-manager.io", .kind // "Issuer"]' <<<"$ca")" = '["cert-manager.io","Issuer"]' ]
  bootstrap="$(cm_object Issuer "$(jq -r '.spec.issuerRef.name' <<<"$ca")")"
  echo "the authority's issuer: $bootstrap"
  [ "$(jq -r '.metadata.namespace' <<<"$bootstrap")" = "$ns" ]
  [ "$(jq -c '.spec' <<<"$bootstrap")" = '{"selfSigned":{}}' ]
  # The self-signed Issuer signs authorities alone.
  signed="$(NAME="$(jq -r '.metadata.name' <<<"$bootstrap")" yq -N 'select(.kind == "Certificate"
    and .spec.issuerRef.name == strenv(NAME) and (.spec.issuerRef.kind // "Issuer") == "Issuer")
    | .metadata.name + " " + ((.spec.isCA // false) | tostring)' "$BUILT")"
  echo "the self-signed Issuer signs: $signed"
  [ "$(grep -vc ' true$' <<<"$signed")" -eq 0 ]
  # cert-manager's kinds and webhook are in place before linstor-cluster applies them.
  overlay
  depends="$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "linstor-cluster") | .spec.dependsOn // [] | .[].name' "$OVERLAY")"
  echo "linstor-cluster depends on: $(xargs <<<"$depends")"
  grep -qx cert-manager <<<"$depends"

  # The operator's source at the version the chart runs. Each workload that dials the API reads its
  # address from LS_CONTROLLERS; with apiTLS, each container that does is pointed at the address the
  # operator gives (below), reads its client certificate and key from a volume of its own Secret and
  # trusts the authority beside them, and the operator asks the issuer apiTLS names for that
  # Certificate. The HA controller and the satellites set no LS_CONTROLLERS: they call no API.
  go="$OPERATOR_SRC/internal/controller/linstorcluster_controller.go"
  resources="$OPERATOR_SRC/pkg/resources/cluster"
  patches="$resources/patches"
  mapfile -t callers < <(api_callers)
  printf 'dials the API: %s\n' "${callers[@]}"
  [ "${#callers[@]}" -gt 0 ]
  for caller in "${callers[@]}"; do
    kind="$(jq -r .kind <<<"$caller")" name="$(jq -r .name <<<"$caller")" file="$(jq -r .file <<<"$caller")"
    [[ $file == pkg/resources/cluster/*/* ]] || { echo "$kind $name is no component of the storage cluster: $file"; return 1; }
    comp="${file#pkg/resources/cluster/}" comp="${comp%%/*}"
    components+=("$comp")
    tls_patch=""
    for candidate in "$patches"/api-tls*.yaml; do
      if [ -n "$(patch_containers "$candidate" "$kind" "$name")" ]; then tls_patch="$candidate"; fi
    done
    echo "$kind $name ($comp): the TLS patch ${tls_patch:+patches/}$(basename "${tls_patch:-none}")"
    [ -n "$tls_patch" ]
    for container in $(jq -r '.containers[]' <<<"$caller"); do
      # shellcheck disable=SC2016 # The patch's placeholder, which the operator replaces, is literal.
      [ "$(patch_containers "$patches/api-endpoint.yaml" "$kind" "$name" | C="$container" jq -r 'select(.name == env.C)
        | .env[] | select(.name == "LS_CONTROLLERS") | .value')" = '$LINSTOR_CONTROLLER_URL' ]
      patch_containers "$tls_patch" "$kind" "$name" | C="$container" jq -e 'select(.name == env.C)
        | (.env // [] | map({"key": .name, "value": .}) | from_entries) as $env
        | [.volumeMounts[]? as $m | .volumes[] | select(.name == $m.name
            and ((.secret.secretName // "") | test("^[$][A-Z_]+_SECRET_NAME$"))) | $m.mountPath] as $mounts
        | (($env.LS_USER_CERTIFICATE_FILE.value // "") | sub("/[^/]*$"; "")) as $cert
        | (($env.LS_USER_KEY_FILE.value // "") | sub("/[^/]*$"; "")) as $key
        | $env.LS_ROOT_CA != null and ($mounts | index($cert)) != null and ($mounts | index($key)) != null' >/dev/null ||
        { echo "$kind $name: $container reads no client certificate from a Secret of its own in $tls_patch"; return 1; }
    done
    # The operator asks the issuer of apiTLS for the client certificate, and applies the TLS patch
    # with the Secret that Certificate writes.
    cert="$(client_certificate "$comp/cert-manager")"
    renderer="$(renders "$(basename "$tls_patch")")"
    secret="$(grep -oE "ClusterApiTLSClientCertManagerPatch\(\"$cert\", [A-Za-z]+, lcluster\.Spec\.ApiTLS\.CertManager\)" "$go" |
      sed -E 's/^[^,]*, ([A-Za-z]+),.*$/\1/')"
    echo "$kind $name: the Certificate $cert writes ${secret:-nothing}, which ${renderer:-nothing} mounts"
    [ -n "$renderer" ] && [ -n "$secret" ]
    grep -qF "resourceDirs = append(resourceDirs, \"$comp/cert-manager\")" "$go"
    grep -Eq "$renderer\($secret, lcluster\.Spec\.ApiTLS\.CAReference\)" "$go"
  done
  # Each of those components' resources takes the address the operator gives.
  [ "$(grep -c 'ClusterApiEndpointPatch(LinstorControllerUrl(lcluster))' "$go")" -eq "$(printf '%s\n' "${components[@]}" | sort -u | grep -c .)" ]
  # And keeps it, its client certificate and its authority as the operator writes them: no podTemplate
  # or patch of the build's storage cluster objects sets an address, a certificate, a key or an
  # authority the clients read, or names a volume or a mount path the TLS patches add.
  wiring="$(api_wiring)"
  echo "the operator's wiring of the API's clients: $(xargs <<<"$wiring")"
  grep -qx LS_CONTROLLERS <<<"$wiring"
  written="$(overrides | awk -F '\t' 'NR == FNR { wiring[$0]; next } $2 in wiring' <(printf '%s\n' "$wiring") -)"
  echo "the build writes over it: ${written:-nothing}"
  [ -z "$written" ]

  # The operator itself: it dials the controller's Service at the port named secure-api over HTTPS,
  # which the controller's TLS patch adds, with the client Secret of apiTLS, which the operator's
  # Certificate linstor-client-tls writes from the same issuer.
  grep -A1 -F 'if p.Name == "secure-api" {' "$OPERATOR_SRC/pkg/linstorhelper/client.go" | grep -qF 'return "https", p.Port, true'
  grep -qF 'opts = append(opts, lapi.BaseURL(&url.URL{' "$OPERATOR_SRC/pkg/linstorhelper/client.go"
  grep -qF 'Host:   fmt.Sprintf("%s.%s.svc:%d", s.Name, s.Namespace, port),' "$OPERATOR_SRC/pkg/linstorhelper/client.go"
  port="$(yq -N '.[] | select(.target.kind == "Service" and .target.name == "linstor-controller") | .patch | from_yaml
    | .spec.ports[] | select(.name == "secure-api") | .port' "$patches/api-tls.yaml")"
  service="$(yq -N 'select(.kind == "Service") | .metadata.name' "$resources/controller/controller-service.yaml")"
  echo "the controller's Service $service, secure-api: ${port:-none}"
  [ -n "$port" ]
  grep -qF 'clientSecret = lcluster.Spec.ApiTLS.GetClientSecretName()' "$go"
  [ "$(client_certificate controller/cert-manager/api-client)" = linstor-client-tls ]
  grep -qF '"controller/cert-manager/api-client"' "$go"
  grep -Eq 'ClusterApiTLSClientCertManagerPatch\("linstor-client-tls", clientSecretName, lcluster\.Spec\.ApiTLS\.CertManager\)' "$go"
  # The CLI in the controller's pod: the client configuration the patch writes dials HTTPS with the
  # certificate and key of the volume the patch mounts from that client Secret.
  conf="$(yq '.[] | select(.target.kind == "ConfigMap" and .target.name == "linstor-controller-config") | .patch | from_yaml
    | .data["linstor-client.conf"]' "$patches/api-tls.yaml")"
  echo "the CLI's configuration: $conf"
  patch_containers "$patches/api-tls.yaml" Deployment linstor-controller | jq -e \
    --arg cert "$(sed -nE 's#^certfile *= *(.*)/[^/]*$#\1#p' <<<"$conf")" --arg key "$(sed -nE 's#^keyfile *= *(.*)/[^/]*$#\1#p' <<<"$conf")" '
    select(.name == "linstor-controller")
    | [.volumeMounts[] as $m | .volumes[] | select(.name == $m.name
        and ([.projected.sources[]? | objects | .secret.name] | index("$LINSTOR_API_TLS_CLIENT_SECRET_NAME")) != null) | $m.mountPath] as $mounts
    | ($mounts | index($cert)) != null and ($mounts | index($key)) != null' >/dev/null
  grep -Eq '"LINSTOR_API_TLS_CLIENT_SECRET_NAME": +clientSecretName,' "$OPERATOR_SRC/internal/controller/patches.go"
  grep -qF 'p, err := ClusterApiTLSPatch(apiSecretName, clientSecretName, lcluster.Spec.ApiTLS.CAReference)' "$go"

  # Everyone dials HTTPS at the port secure-api, at a name the controller's certificate holds: the
  # names the operator gives the Certificate it asks the issuer of apiTLS for.
  names="$(api_names "$ns")"
  echo "the controller's certificate holds: $(xargs <<<"$names")"
  url="$(sed -n '/^func LinstorControllerUrl(/,/^}/p' "$go" | sed -n '/cluster\.Spec\.ApiTLS != nil {/,/}/p' |
    sed -nE 's/^[[:space:]]*return "([^"]*)"$/\1/p')"
  echo "the components dial $url, the CLI $(sed -n 's/^controllers *= *//p' <<<"$conf"), the operator $service.$ns.svc:$port"
  for url in "$url" "$(sed -n 's/^controllers *= *//p' <<<"$conf")" "https://$service.$ns.svc:$port"; do
    [[ $url =~ ^https://([^:/]+):([0-9]+)$ ]]
    grep -qxF "${BASH_REMATCH[1]}" <<<"$names"
    [ "${BASH_REMATCH[2]}" = "$port" ]
  done
}

@test "The pinned LINSTOR controller refuses an API request without its authority's client certificate and keeps serving its metrics" {
  local conf api plain ca cert key out version names
  docker_or_skip
  # The API's authority, which the certificates are made from, is the build's.
  built piraeus-datastore linstor-cluster
  api_authority >/dev/null
  controller_start
  conf="$START/etc/linstor-client.conf"
  api="$(sed -n 's/^controllers *= *//p' "$conf")"
  ca="$(sed -n 's/^cafile *= *//p' "$conf")" cert="$(sed -n 's/^certfile *= *//p' "$conf")" key="$(sed -n 's/^keyfile *= *//p' "$conf")"
  plain="http://${api#https://}" plain="${plain%:*}:$(jq -r '.container.ports[] | select(.name == "api") | .containerPort' "$START/spec.json")"
  echo "the API: $api; the plain port: $plain"
  # Without a client certificate the handshake fails: over TLS 1.2 within the handshake, which curl
  # reports as 35, and over TLS 1.3 at the server's first answer; no version is read.
  run in_docker exec "$CONTROLLER" curl -sS --max-time 10 --tls-max 1.2 --cacert "$ca" "$api/v1/controller/version"
  echo "no certificate, TLS 1.2: $status $output"
  [ "$status" -eq 35 ]
  [[ $output != *'"version"'* ]]
  run in_docker exec "$CONTROLLER" curl -sS --max-time 10 --cacert "$ca" "$api/v1/controller/version"
  echo "no certificate: $status $output"
  [ "$status" -ne 0 ]
  [[ $output != *'"version"'* ]]
  # With the client certificate of the API's authority, the version.
  out="$(in_docker exec "$CONTROLLER" curl -sS --max-time 10 --cacert "$ca" --cert "$cert" --key "$key" -w '\n%{http_code}' "$api/v1/controller/version")"
  echo "the API's client certificate: $out"
  [ "$(tail -n 1 <<<"$out")" = 200 ]
  version="$(head -n 1 <<<"$out" | jq -r '.version')"
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  # With a certificate of the same name another authority signed, the handshake fails as without one.
  run in_docker exec "$CONTROLLER" curl -sS --max-time 10 --tls-max 1.2 --cacert "$ca" \
    --cert /run/other-authority/tls.crt --key /run/other-authority/tls.key "$api/v1/controller/version"
  echo "another authority's certificate, TLS 1.2: $status $output"
  [ "$status" -eq 35 ]
  [[ $output != *'"version"'* ]]
  run in_docker exec "$CONTROLLER" curl -sS --max-time 10 --cacert "$ca" \
    --cert /run/other-authority/tls.crt --key /run/other-authority/tls.key "$api/v1/controller/version"
  echo "another authority's certificate: $status $output"
  [ "$status" -ne 0 ]
  [[ $output != *'"version"'* ]]
  # Over plain HTTP the API answers only with a redirect to the HTTPS port, and a request that would
  # create a resource definition creates none; one made over HTTPS with the certificate shows the
  # listing would hold it.
  out="$(in_docker exec "$CONTROLLER" curl -sS --max-time 10 -w '\n%{http_code} %{redirect_url}' "$plain/v1/controller/version")"
  echo "plain HTTP: $out"
  [ "$(tail -n 1 <<<"$out")" = "302 $api/v1/controller/version" ]
  [[ $out != *'"version"'* ]]
  out="$(in_docker exec "$CONTROLLER" curl -sS --max-time 10 -X POST -H 'Content-Type: application/json' \
    -d '{"resource_definition": {"name": "over-plain-http"}}' -w '\n%{http_code} %{redirect_url}' "$plain/v1/resource-definitions")"
  echo "plain HTTP, a new resource definition: $out"
  [ "$(tail -n 1 <<<"$out")" = "302 $api/v1/resource-definitions" ]
  out="$(in_docker exec "$CONTROLLER" curl -sS --max-time 10 -X POST -H 'Content-Type: application/json' \
    -d '{"resource_definition": {"name": "over-https"}}' --cacert "$ca" --cert "$cert" --key "$key" -o /dev/null -w '%{http_code}' \
    "$api/v1/resource-definitions")"
  echo "HTTPS with the certificate, a new resource definition: $out"
  [ "$out" = 201 ]
  names="$(in_docker exec "$CONTROLLER" curl -sS --max-time 10 --cacert "$ca" --cert "$cert" --key "$key" \
    "$api/v1/resource-definitions" | jq -r '.[].name' | xargs)"
  echo "resource definitions: ${names:-none}"
  [ "$names" = over-https ]
  # The metrics, LINSTOR's own series of the same controller, and the health check, over plain HTTP.
  out="$(in_docker exec "$CONTROLLER" curl -sS --max-time 10 -w '\n%{http_code}' "$plain/metrics")"
  [ "$(tail -n 1 <<<"$out")" = 200 ]
  grep -E '^linstor_info\{' <<<"$out"
  grep -qE "^linstor_info\{.*version=\"$version\".*\} 1(\.0)?$" <<<"$out"
  [ "$(in_docker exec "$CONTROLLER" curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "$plain/health")" = 200 ]
  # The CLI in the container, as the runbooks run it in the pod, reaches the API with the client
  # configuration the operator writes.
  out="$(in_docker exec "$CONTROLLER" linstor controller version)"
  echo "the CLI: $out"
  [[ $out == "linstor controller $version;"* ]]
}

@test "The LINSTOR controller and every satellite accept only each other's certificates" {
  local ns tls configs issuer ca api_ca bootstrap signed go sgo merge ctl sat nodes state secret dir cert
  local patch spatch toml mounts linstor wiring written targets kind name what
  operator_source
  # The operator makes its Certificates in its own namespace, the release's, where a Certificate's
  # issuer of kind Issuer is looked up.
  ns="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  echo "the operator's namespace: $ns"
  [ -n "$ns" ]
  built piraeus-datastore linstor-cluster
  # By cert-manager and nothing else, on the storage cluster and on the one configuration that sets it,
  # which selects every satellite and sets nothing else: no Secret name, no CA reference and no
  # handshake daemon, so the operator writes each certificate's Secret under its default name and each
  # side trusts the ca.crt the issuer writes beside its own certificate.
  tls="$(yq -N -o json -I0 'select(.kind == "LinstorCluster") | .spec.internalTLS // null' "$BUILT")"
  echo "the LinstorCluster's internalTLS: $tls"
  [ "$(jq -c 'keys' <<<"$tls")" = '["certManager"]' ]
  [ "$(jq -c '.certManager | [.group, .kind]' <<<"$tls")" = '["cert-manager.io","Issuer"]' ]
  configs="$(yq -N -o json -I0 'select(.kind == "LinstorSatelliteConfiguration" and .spec.internalTLS != null)
    | {"name": .metadata.name, "spec": .spec}' "$BUILT")"
  echo "configurations that set internalTLS: ${configs:-none}"
  [ "$(grep -c . <<<"$configs")" -eq 1 ]
  [ "$(jq -c '.spec | keys' <<<"$configs")" = '["internalTLS"]' ]
  [ "$(jq -S -c '.spec.internalTLS' <<<"$configs")" = "$(jq -S -c . <<<"$tls")" ]
  # The operator gives each satellite the internalTLS of the configurations that select its node, the
  # last by name that sets it (pkg/merge), and writes it onto the node's LinstorSatellite, named after
  # the node (internal/controller/linstorcluster_controller.go).
  go="$OPERATOR_SRC/internal/controller/linstorcluster_controller.go"
  merge="$(go_func "$OPERATOR_SRC/pkg/merge/linstorsatelliteconfiguration.go" SatelliteConfigurations)"
  [ "$(grep -xF -A1 'if cfg.Spec.InternalTLS != nil {' <<<"$merge" | tail -n 1)" = 'result.Spec.InternalTLS = cfg.Spec.InternalTLS' ]
  sat="$(go_func "$go" kustomizeLinstorSatellite)"
  grep -qxF 'cfg, matched := merge.SatelliteConfigurations(ctx, node, configs...)' <<<"$sat"
  [ "$(grep -xF -A4 'if cfg.Spec.InternalTLS != nil {' <<<"$sat" | paste -sd ' ')" = \
    'if cfg.Spec.InternalTLS != nil { patches = append(patches, utils.JsonPatch{ Op: utils.Add, Path: "/spec/internalTLS", Value: cfg.Spec.InternalTLS,' ]
  [ "$(grep -xF -A1 'Path: "/metadata/name",' <<<"$sat" | tail -n 1)" = 'Value: node.Name,' ]

  # The issuer: an Issuer of the build in the operator's namespace, of kind CA, signing from the Secret
  # of an authority the build makes, which only that authority's Certificate writes and the build's own
  # self-signed Issuer issues.
  issuer="$(cm_object Issuer "$(jq -r '.certManager.name' <<<"$tls")")"
  echo "the internal issuer: $issuer"
  [ "$(jq -r '.metadata.namespace' <<<"$issuer")" = "$ns" ]
  [ "$(jq -c '.spec | keys' <<<"$issuer")" = '["ca"]' ]
  ca="$(authority internalTLS)"
  echo "its authority: $ca"
  [ "$(jq -r '.metadata.namespace' <<<"$ca")" = "$ns" ]
  [ "$(jq -r '.spec.isCA' <<<"$ca")" = true ]
  [ "$(jq -c '.spec.issuerRef | [.group // "cert-manager.io", .kind // "Issuer"]' <<<"$ca")" = '["cert-manager.io","Issuer"]' ]
  bootstrap="$(cm_object Issuer "$(jq -r '.spec.issuerRef.name' <<<"$ca")")"
  echo "the authority's issuer: $bootstrap"
  [ "$(jq -r '.metadata.namespace' <<<"$bootstrap")" = "$ns" ]
  [ "$(jq -c '.spec' <<<"$bootstrap")" = '{"selfSigned":{}}' ]
  # Not the API's authority: another issuer, Certificate, Secret and common name, so a certificate the
  # API's callers hold is not one a satellite takes, nor a satellite's one the API takes.
  api_ca="$(authority apiTLS)"
  echo "the API's authority: $api_ca"
  [ "$(jq -r '.certManager.name' <<<"$tls")" != "$(yq -N 'select(.kind == "LinstorCluster") | .spec.apiTLS.certManager.name' "$BUILT")" ]
  [ "$(jq -r '.metadata.name' <<<"$ca")" != "$(jq -r '.metadata.name' <<<"$api_ca")" ]
  [ "$(jq -r '.spec.secretName' <<<"$ca")" != "$(jq -r '.spec.secretName' <<<"$api_ca")" ]
  [ "$(jq -r '.spec.commonName // ""' <<<"$ca")" != "$(jq -r '.spec.commonName // ""' <<<"$api_ca")" ]
  # The self-signed Issuer issues the storage cluster's two authorities and nothing else, and no
  # Certificate of the build asks the internal issuer for one: what it signs is the operator's.
  signed="$(NAME="$(jq -r '.metadata.name' <<<"$bootstrap")" yq -N 'select(.kind == "Certificate"
    and .spec.issuerRef.name == strenv(NAME) and (.spec.issuerRef.kind // "Issuer") == "Issuer") | .metadata.name' "$BUILT" |
    LC_ALL=C sort | xargs)"
  echo "the self-signed Issuer signs: $signed"
  [ "$signed" = "$(jq -r '.metadata.name' <<<"$api_ca"$'\n'"$ca" | LC_ALL=C sort | xargs)" ]
  [ -z "$(NAME="$(jq -r '.metadata.name' <<<"$issuer")" yq -N 'select(.kind == "Certificate"
    and .spec.issuerRef.name == strenv(NAME)) | .metadata.name' "$BUILT")" ]

  # The controller, at the version the chart runs: with internalTLS it takes the Secret
  # linstor-controller-internal-tls unless one is named, mounts it with the authority the CA reference
  # names, here the Secret's own ca.crt, and, with a cert-manager issuer, adds the Certificate of its
  # internal template, whose one usage is client auth, asked of that issuer and writing that Secret.
  ctl="$(go_func "$go" kustomizeControllerResources)"
  grep -qxF 'secretName := lcluster.Spec.InternalTLS.SecretName' <<<"$ctl"
  secret="$(grep -xF -A1 'if secretName == "" {' <<<"$ctl" | sed -nE 's/^secretName = "([^"]+)"$/\1/p')"
  echo "the controller's Secret: ${secret:-none}"
  [ "$secret" = linstor-controller-internal-tls ]
  grep -qxF 'p, err := ClusterLinstorInternalTLSPatch(secretName, lcluster.Spec.InternalTLS.CAReference)' <<<"$ctl"
  dir="$(grep -xF -A1 'if lcluster.Spec.InternalTLS.CertManager != nil {' <<<"$ctl" |
    sed -nE 's#^resourceDirs = append\(resourceDirs, "(controller/cert-manager/[a-z-]+)"\)$#\1#p')"
  echo "the controller's Certificate template: ${dir:-none}"
  [ -n "$dir" ]
  grep -qxF 'p, err := ClusterLinstorInternalTLSCertManagerPatch(secretName, lcluster.Spec.InternalTLS.CertManager)' <<<"$ctl"
  cert="$(client_certificate "$dir")"
  echo "the controller's Certificate: $cert"
  [ "$(fills cluster internal-tls-cert-manager.yaml | paste -sd ' ')" = \
    'ClusterLinstorInternalTLSCertManagerPatch LINSTOR_INTERNAL_TLS_SECRET_NAME secretName LINSTOR_INTERNAL_TLS_CERT_ISSUER issuer' ]
  # shellcheck disable=SC2016 # The patch's placeholders, which the operator replaces, are literal.
  [ "$(NAME="$cert" yq -N -o json -I0 '.[] | select(.target.kind == "Certificate" and .target.name == strenv(NAME)) | .patch | from_yaml
    | .spec | [.secretName, .issuerRef]' "$OPERATOR_SRC/pkg/resources/cluster/patches/internal-tls-cert-manager.yaml")" = \
    '["$LINSTOR_INTERNAL_TLS_SECRET_NAME","$LINSTOR_INTERNAL_TLS_CERT_ISSUER"]' ]
  [ "$(fills cluster internal-tls.yaml | paste -sd ' ')" = \
    'ClusterLinstorInternalTLSPatch LINSTOR_INTERNAL_TLS_SECRET_NAME secretName LINSTOR_INTERNAL_TLS_CA_PROJECTION caRef.ToVolumeProjection(secretName)' ]
  # Without a CA reference the authority projected beside the certificate is the Secret's own ca.crt,
  # which a CA issuer writes: every key of the same Secret (api/v1/tls.go).
  [ "$(go_func "$OPERATOR_SRC/api/v1/tls.go" ToVolumeProjection | grep -xF -A4 'if c == nil {' | paste -sd ' ')" = \
    'if c == nil { return corev1.VolumeProjection{ Secret: &corev1.SecretProjection{ LocalObjectReference: corev1.LocalObjectReference{Name: fallbackSecretName}, },' ]
  # The patch mounts that Secret, read-only, where the image's entrypoint makes the Java key and trust
  # stores from it, /etc/linstor/ssl-pem, and an emptyDir for those stores, in the controller and in its
  # migration, which starts from the same entrypoint.
  patch="$OPERATOR_SRC/pkg/resources/cluster/patches/internal-tls.yaml"
  # shellcheck disable=SC2016
  mounts="$(patch_containers "$patch" Deployment linstor-controller | jq -r '
    [.volumes[] | select(.projected.sources == [{"secret": {"name": "$LINSTOR_INTERNAL_TLS_SECRET_NAME"}}, "$LINSTOR_INTERNAL_TLS_CA_PROJECTION"]) | .name] as $pem
    | [.volumes[] | select(.emptyDir != null) | .name] as $java
    | .name + " " + ([.volumeMounts[] | select(.name | IN($pem[])) | .mountPath + ":" + ((.readOnly // false) | tostring)] | join(","))
      + " " + ([.volumeMounts[] | select(.name | IN($java[])) | .mountPath] | join(","))' | LC_ALL=C sort)"
  echo "the controller's mounts: $mounts"
  [ "$mounts" = $'linstor-controller /etc/linstor/ssl-pem:true /etc/linstor/ssl\nrun-migration /etc/linstor/ssl-pem:true /etc/linstor/ssl' ]

  # Each satellite, at the version the chart runs: with internalTLS it takes the Secret <node>-tls
  # unless one is named, mounts it with the authority the CA reference names, here the Secret's own,
  # and, with a cert-manager issuer, adds the Certificate of its template, whose one usage is server
  # auth, asked of that issuer and writing that Secret; the configurations' patches come after the
  # operator's own.
  sgo="$OPERATOR_SRC/internal/controller/linstorsatellite_controller.go"
  nodes="$(go_func "$sgo" kustomizeNodeResources)"
  grep -qxF 'secretName := lsatellite.Spec.InternalTLS.SecretName' <<<"$nodes"
  [ "$(grep -xF -A1 'if secretName == "" {' <<<"$nodes" | tail -n 1)" = 'secretName = lsatellite.Name + "-tls"' ]
  grep -qxF 'p, err := SatelliteLinstorInternalTLSPatch(secretName, lsatellite.Spec.InternalTLS.CAReference)' <<<"$nodes"
  dir="$(grep -xF -A1 'if lsatellite.Spec.InternalTLS.CertManager != nil {' <<<"$nodes" |
    sed -nE 's#^resourceDirs = append\(resourceDirs, "(satellite/[a-z-]+)"\)$#\1#p')"
  echo "the satellite's Certificate template: ${dir:-none}"
  [ -n "$dir" ]
  grep -qxF 'p, err := SatelliteLinstorInternalTLSCertManagerPatch(secretName, lsatellite.Spec.InternalTLS.CertManager)' <<<"$nodes"
  grep -qxF 'Patches: append(patches, utils.MakeKustPatches(userPatches...)...),' <<<"$nodes"
  cert="$(yq -N -o json -I0 'select(.kind == "Certificate") | {"name": .metadata.name, "usages": .spec.usages}' \
    "$OPERATOR_SRC/pkg/resources/satellite/$dir"/*.yaml)"
  echo "the satellite's Certificate: $cert"
  [ "$(grep -c . <<<"$cert")" -eq 1 ]
  [ "$(jq -c '.usages' <<<"$cert")" = '["server auth"]' ]
  [ "$(fills satellite internal-tls-cert-manager.yaml | paste -sd ' ')" = \
    'SatelliteLinstorInternalTLSCertManagerPatch LINSTOR_INTERNAL_TLS_SECRET_NAME secretName LINSTOR_INTERNAL_TLS_CERT_ISSUER issuer' ]
  # shellcheck disable=SC2016
  [ "$(NAME="$(jq -r '.name' <<<"$cert")" yq -N -o json -I0 '.[] | select(.target.kind == "Certificate" and .target.name == strenv(NAME))
    | .patch | from_yaml | .spec | [.secretName, .issuerRef]' "$OPERATOR_SRC/pkg/resources/satellite/patches/internal-tls-cert-manager.yaml")" = \
    '["$LINSTOR_INTERNAL_TLS_SECRET_NAME","$LINSTOR_INTERNAL_TLS_CERT_ISSUER"]' ]
  [ "$(fills satellite internal-tls.yaml | paste -sd ' ')" = \
    'SatelliteLinstorInternalTLSPatch LINSTOR_INTERNAL_TLS_SECRET_NAME secretName LINSTOR_INTERNAL_TLS_CA_PROJECTION caRef.ToVolumeProjection(secretName)' ]
  spatch="$OPERATOR_SRC/pkg/resources/satellite/patches/internal-tls.yaml"
  # shellcheck disable=SC2016
  mounts="$(patch_containers "$spatch" DaemonSet linstor-satellite | jq -r '
    [.volumes[] | select(.projected.sources == [{"secret": {"name": "$LINSTOR_INTERNAL_TLS_SECRET_NAME"}}, "$LINSTOR_INTERNAL_TLS_CA_PROJECTION"]) | .name] as $pem
    | [.volumes[] | select(.emptyDir != null) | .name] as $java
    | .name + " " + ([.volumeMounts[] | select(.name | IN($pem[])) | .mountPath + ":" + ((.readOnly // false) | tostring)] | join(","))
      + " " + ([.volumeMounts[] | select(.name | IN($java[])) | .mountPath] | join(","))')"
  echo "the satellite's mounts: $mounts"
  [ "$mounts" = 'linstor-satellite /etc/linstor/ssl-pem:true /etc/linstor/ssl' ]
  # Its one connector: the patch replaces the satellite's configuration, empty in the template, with a
  # TLS connector on the port the container declares as linstor in place of the template's, whose key
  # store and trust store are in the emptyDir the entrypoint fills; the ConfigMap it patches is the one
  # the template mounts at /etc/linstor, the satellite's configuration directory.
  [ "$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "satellite-config") | .data | to_entries | .[] | .key + "=" + .value' \
    "$OPERATOR_SRC/pkg/resources/satellite/satellite/config.yaml")" = 'linstor_satellite.toml=' ]
  # shellcheck disable=SC2016 # $s and $v are yq variables.
  [ "$(yq -N '.[] | select(.target.kind == "ConfigMap") | .target.name' "$spatch")" = \
    "$(yq -N 'select(.kind == "DaemonSet") | .spec.template.spec as $s | ($s.containers[] | select(.name == "linstor-satellite")
      | .volumeMounts[] | select(.mountPath == "/etc/linstor") | .name) as $v | $s.volumes[] | select(.name == $v) | .configMap.name' \
      "$OPERATOR_SRC/pkg/resources/satellite/satellite/daemonset.yaml")" ]
  toml="$(yq '.[] | select(.target.kind == "ConfigMap") | .patch | from_yaml | .data["linstor_satellite.toml"]' "$spatch" | yq -p toml -o json -I0 '.')"
  echo "the satellite's configuration: $toml"
  [ "$(jq -c 'keys' <<<"$toml")" = '["netcom"]' ]
  [ "$(jq -r '.netcom.type' <<<"$toml")" = ssl ]
  # shellcheck disable=SC2016 # $patch is a key of the patch.
  linstor="$(patch_containers "$spatch" DaemonSet linstor-satellite | jq -c '[.ports[] | {"port": .containerPort, "name": (.name // ""), "deleted": (."$patch" == "delete")}]')"
  echo "the satellite's ports: $linstor"
  [ "$(jq -c '[.[] | select(.deleted | not)]' <<<"$linstor")" = "[{\"port\":$(jq '.netcom.port' <<<"$toml"),\"name\":\"linstor\",\"deleted\":false}]" ]
  [ "$(jq -r '.[] | select(.deleted) | .port' <<<"$linstor")" = \
    "$(yq -N 'select(.kind == "DaemonSet") | .spec.template.spec.containers[] | select(.name == "linstor-satellite") | .ports[]
      | select(.name == "linstor") | .containerPort' "$OPERATOR_SRC/pkg/resources/satellite/satellite/daemonset.yaml")" ]
  [ "$(jq -r '[.netcom.server_certificate, .netcom.trusted_certificates] | map(sub("/[^/]+$"; "")) | unique | join(" ")' <<<"$toml")" = /etc/linstor/ssl ]
  # The key store and the trust store are the two files the image's entrypoint makes there from the
  # certificate, its key and the ca.crt beside them, the trust store from ca.crt alone
  # (dockerfiles/piraeus-server/entry.sh of github.com/piraeusdatastore/piraeus), which the proof of
  # "The pinned LINSTOR satellite refuses a connection without a certificate from its own authority"
  # runs from the pinned image.
  [ "$(jq -r '.netcom.server_certificate' <<<"$toml")" = /etc/linstor/ssl/keystore.jks ]
  [ "$(jq -r '.netcom.trusted_certificates' <<<"$toml")" = /etc/linstor/ssl/certificates.jks ]
  # And registers the node as SSL on that port once its pod is ready: LINSTOR's constants, in the
  # client the operator is built with.
  state="$(go_func "$sgo" reconcileLinstorSatelliteState)"
  [ "$(grep -xF -A3 'if lsatellite.Spec.InternalTLS != nil {' <<<"$state" | paste -sd ' ')" = \
    'if lsatellite.Spec.InternalTLS != nil { encryptType = linstor.ValNetcomTypeSsl port = linstor.DfltStltPortSsl }' ]
  grep -qxF 'SatellitePort: int32(port),' <<<"$state"
  grep -qxF 'SatelliteEncryptionType: encryptType,' <<<"$state"
  echo "LINSTOR's SSL type and port: $(golinstor_const ValNetcomTypeSsl) $(golinstor_const DfltStltPortSsl)"
  [ "$(golinstor_const ValNetcomTypeSsl)" = '"SSL"' ]
  [ "$(golinstor_const DfltStltPortSsl)" = "$(jq '.netcom.port' <<<"$toml")" ]
  [ "$(jq '.netcom.port' <<<"$toml")" = 3367 ]

  # And no podTemplate or patch of the build's storage cluster objects names a volume, a mount path, a
  # port or a probe those patches add, or a ConfigMap of the configuration they complete or the
  # directory it is mounted at; a mount path at or beneath a directory of the wiring mounts over it.
  wiring="$(internal_wiring)"
  echo "the operator's wiring of internalTLS: $(xargs <<<"$wiring")"
  grep -qxF /etc/linstor/ssl-pem <<<"$wiring"
  grep -qxF /etc/linstor/ssl <<<"$wiring"
  grep -qxF /etc/linstor <<<"$wiring"
  grep -qxF "$(jq '.netcom.port' <<<"$toml")" <<<"$wiring"
  grep -qxF livenessProbe <<<"$wiring"
  grep -qxF satellite-config <<<"$wiring"
  grep -qxF linstor-controller-config <<<"$wiring"
  written="$(overrides | awk -F '\t' 'NR == FNR { wiring[$0]; next }
    { for (w in wiring) if ($2 == w || (w ~ /^\// && index($2, w "/") == 1)) { print; next } }' <(printf '%s\n' "$wiring") -)"
  echo "the build writes over it: ${written:-nothing}"
  [ -z "$written" ]
  # Nor does a patch of the build change what those patches change as a whole: a list of operations
  # names what it changes by its path in the operator's object, which the build does not hold, so on
  # any of them it counts as writing over the wiring; a strategic merge patch of a workload names
  # what it changes, which the check above reads; and any patch of a ConfigMap of the configuration
  # or of a Certificate changes what the wiring completes.
  targets="$(internal_targets)"
  echo "what the operator's patches for internalTLS change: $(tr '\t' ' ' <<<"$targets" | paste -sd ',' | sed 's/,/, /g')"
  grep -qxF $'DaemonSet\tlinstor-satellite\ttemplate' <<<"$targets"
  grep -qxF $'Deployment\tlinstor-controller\ttemplate' <<<"$targets"
  grep -qxF $'Certificate\tlinstor-satellite\twhole' <<<"$targets"
  grep -qxF $'Certificate\tlinstor-controller-internal-tls\twhole' <<<"$targets"
  grep -qxF $'ConfigMap\tsatellite-config\twhole' <<<"$targets"
  grep -qxF $'ConfigMap\tlinstor-controller-config\twhole' <<<"$targets"
  written="$(while IFS=$'\t' read -r kind name what; do
    patched "$kind" "$name" | awk -F '\t' -v target="$kind/$name" -v what="$what" '$2 == "json6902" || what == "whole" { print $1 " patches " target " (" $2 ")" }'
  done <<<"$targets")"
  echo "patches of the build over it: ${written:-none}"
  [ -z "$written" ]
}

# This proves the TLS layer of the satellite's connector as the operator configures it: who completes
# a handshake on 3367, and that the satellite serves nothing else, 3366 included. It does not prove
# LINSTOR's protocol over the link, the controller's own check of the satellite's certificate or the
# operator's registration of the node: the proof of "The LINSTOR controller and every satellite accept
# only each other's certificates" reads from the operator's source the authority the controller checks
# with and the registration, and a satellite Online at 3367 (SSL) on the cluster shows the rest. It
# needs docker and skips without it, as under just ci and in CI.
@test "The pinned LINSTOR satellite refuses a connection without a certificate from its own authority" {
  local toml port plain out fingerprint served errors
  docker_or_skip
  # The internal authority, which the certificates are made from, is the build's.
  built piraeus-datastore linstor-cluster
  authority internalTLS >/dev/null
  satellite_start
  toml="$(yq -p toml -o json -I0 '.' "$SAT/etc/linstor_satellite.toml")"
  port="$(jq -r '.container.ports[] | select(.name == "linstor") | .containerPort' "$SAT/spec.json")"
  # The port of the operator's template without internalTLS.
  plain="$(yq -N 'select(.kind == "DaemonSet") | .spec.template.spec.containers[] | select(.name == "linstor-satellite") | .ports[]
    | select(.name == "linstor") | .containerPort' "$OPERATOR_SRC/pkg/resources/satellite/satellite/daemonset.yaml")"
  echo "the satellite's port: $port; without internalTLS: $plain"
  [ "$port" = "$(jq '.netcom.port' <<<"$toml")" ]
  [ "$port" != "$plain" ]
  # Its trust store, which the entrypoint makes from the ca.crt beside its certificate, holds the
  # internal authority and nothing else.
  out="$(in_docker exec "$SATELLITE_CONTAINER" keytool -list -keystore "$(jq -r '.netcom.trusted_certificates' <<<"$toml")" \
    -storepass "$(jq -r '.netcom.truststore_password' <<<"$toml")")"
  echo "$out"
  grep -qx 'Your keystore contains 1 entry' <<<"$out"
  fingerprint="$(openssl x509 -in "$SAT/pki/internal-ca.crt" -noout -fingerprint -sha256 | sed 's/^[^=]*=//')"
  echo "the internal authority: $fingerprint"
  [ "$(sed -nE 's/^Certificate fingerprint \(SHA-256\): //p' <<<"$out")" = "$fingerprint" ]
  # The handshake fails without a client certificate, with the client certificate of the API's
  # authority, and with the controller's certificate another authority of the same name signed. Each
  # as the pinned satellite fails it (satellite_refuses), which logs the alert and its reason.
  satellite_refuses '(handshake_failure) Empty client certificate chain'
  satellite_refuses '(certificate_unknown) PKIX path building failed: sun.security.provider.certpath.SunCertPathBuilderException: unable to find valid certification path to requested target' \
    -cert /run/probes/api-client.crt -key /run/probes/api-client.key
  satellite_refuses '(certificate_unknown) PKIX path validation failed: java.security.cert.CertPathValidatorException: Path does not chain with any of the trust anchors' \
    -cert /run/probes/other-controller.crt -key /run/probes/other-controller.key
  # With the controller's certificate of the internal authority the handshake completes, the
  # certificate the satellite presents, its own, verifies against that authority, and the satellite
  # logs no error.
  errors="$(in_docker logs "$SATELLITE_CONTAINER" 2>&1 | grep -c 'SSL error:' || true)"
  out="$(in_docker exec "$SATELLITE_CONTAINER" timeout 20 openssl s_client -connect "localhost:$port" -tls1_2 \
    -cert /run/probes/controller.crt -key /run/probes/controller.key -CAfile /run/probes/internal-ca.crt -verify_return_error 2>&1)"
  grep -E '^(Protocol|Verification|DONE)|Verify return code' <<<"$out"
  grep -qx 'Protocol: TLSv1.2' <<<"$out"
  grep -qx '    Verify return code: 0 (ok)' <<<"$out"
  served="$(sed -n '/^-----BEGIN CERTIFICATE-----$/,/^-----END CERTIFICATE-----$/p' <<<"$out" | openssl x509 -noout -fingerprint -sha256 | sed 's/^[^=]*=//')"
  echo "the satellite presents: $served"
  [ "$served" = "$(openssl x509 -in "$SAT/pki/satellite.crt" -noout -fingerprint -sha256 | sed 's/^[^=]*=//')" ]
  [ "$(in_docker logs "$SATELLITE_CONTAINER" 2>&1 | grep -c 'SSL error:')" -eq "$errors" ]
  # It listens on that port alone, and a connection to the port without internalTLS is refused.
  out="$(in_docker exec "$SATELLITE_CONTAINER" ss -Hltnu | awk '{ print $1, $5 }')"
  echo "listening: $out"
  [ "$out" = "tcp *:$port" ]
  run in_docker exec "$SATELLITE_CONTAINER" socat -u OPEN:/dev/null "TCP:localhost:$plain"
  echo "$plain: $status $output"
  [ "$status" -eq 1 ]
  [[ $output == *" E TCP:localhost:$plain: Connection refused"* ]]
}
