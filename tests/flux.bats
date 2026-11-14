#!/usr/bin/env bats
# Proves features/flux.feature; each test carries its scenario's title.
# Needs helm, kustomize, yq and flux on PATH (the versions pinned for the repository). Each chart is
# pulled once per run from its public registry; everything else, rendering included, is offline.

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
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# render APP: renders the chart that APP's HelmRelease installs, from the URL and tag of the
# OCIRepository in its app/, with the values of the ConfigMap the HelmRelease reads, into
# $BATS_TEST_TMPDIR/APP.yaml. Sets CHART and VALUES.
render() {
  local app=$1 built url tag name
  built="$BATS_TEST_TMPDIR/$app-app.yaml"
  kustomize build "$CLUSTER/flux-system/$app/app" >"$built"
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$built")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$built")"
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$built")"
  VALUES="$BATS_TEST_TMPDIR/$app-values.yaml"
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\") | .data[\"values.yaml\"]" "$built" >"$VALUES"
  [ -s "$VALUES" ] || { echo "$app: no values in the ConfigMap $name its HelmRelease reads"; return 1; }
  local pulled="$BATS_FILE_TMPDIR/charts/$app/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  helm template "$app" "$CHART" --namespace flux-system --values "$VALUES" >"$BATS_TEST_TMPDIR/$app.yaml"
}

# instance EXPRESSION: yq EXPRESSION on the rendered FluxInstance.
instance() {
  yq -N "select(.kind == \"FluxInstance\") | $1" "$BATS_TEST_TMPDIR/flux-instance.yaml"
}

# patched_flux: the pinned Flux manifests and stand-ins for the sync OCIRepository and
# Kustomization the instance generates, with the instance's kustomize patches applied by
# kustomize, into $FLUX.
patched_flux() {
  render flux-instance
  local dir="$BATS_TEST_TMPDIR/patched" name namespace
  mkdir -p "$dir"
  # The instance names its sync objects after sync.name, or after its own namespace.
  name="$(instance '.spec.sync.name // .metadata.namespace')"
  namespace="$(instance '.metadata.namespace')"
  flux install --export >"$dir/flux.yaml"
  cat >"$dir/sync.yaml" <<EOF
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: $name
  namespace: $namespace
spec:
  interval: $(instance '.spec.sync.interval')
  url: $(instance '.spec.sync.url')
  ref:
    tag: $(instance '.spec.sync.ref')
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: $name
  namespace: $namespace
spec:
  interval: 10m
  path: $(instance '.spec.sync.path')
  prune: true
  sourceRef:
    kind: OCIRepository
    name: $name
EOF
  instance '{"apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization",
    "resources": ["flux.yaml", "sync.yaml"], "patches": .spec.kustomize.patches}' >"$dir/kustomization.yaml"
  FLUX="$BATS_TEST_TMPDIR/flux.yaml"
  kustomize build "$dir" >"$FLUX"
  SYNC="$name"
}

# patched EXPRESSION: yq EXPRESSION on each object of the patched Flux manifests.
patched() {
  yq -N "$1" "$FLUX"
}

# rejects PATTERN IDENTITY...: no IDENTITY matches the regular expression PATTERN.
rejects() {
  local pattern=$1 identity
  shift
  for identity in "$@"; do
    if [[ $identity =~ $pattern ]]; then
      echo "$pattern also matches $identity"
      return 1
    fi
  done
}

# dotless IDENTITY: IDENTITY once for each of its dots, with that dot made an x, so a pattern that
# leaves any dot unescaped matches one of them.
dotless() {
  local identity=$1 i
  for ((i = 0; i < ${#identity}; i++)); do
    if [[ ${identity:i:1} == . ]]; then
      echo "${identity:0:i}x${identity:i+1}"
    fi
  done
}

@test "The operator and instance charts render with the repository's values" {
  render flux-operator
  [ "$(yq -N 'select(.kind == "Deployment") | .metadata.name' "$BATS_TEST_TMPDIR/flux-operator.yaml")" = flux-operator ]
  render flux-instance
  [ "$(instance '.kind')" = FluxInstance ]
}

@test "every key of the values files is one the chart defines" {
  local app keys="$BATS_TEST_TMPDIR/keys" unknown key map open
  mkdir -p "$keys"
  # Keys of maps only: list items, such as the instance's patches, are the chart's input, not keys.
  local paths='[.. | select(path | length > 0) | path | select(all_c(tag == "!!str")) | join(".")] | .[]'
  for app in flux-operator flux-instance; do
    render "$app"
    yq -N "$paths" "$VALUES" | sort -u >"$keys/$app.ours"
    helm show values "$CHART" >"$keys/$app.defaults"
    yq -N "$paths" "$keys/$app.defaults" | sort -u >"$keys/$app.chart"
    # A map the chart leaves empty, such as commonAnnotations, takes keys of the user's choosing.
    open="$(yq -N '[.. | select(tag == "!!map" and length == 0) | path | join(".")] | .[]' "$keys/$app.defaults")"
    unknown=""
    while read -r key; do
      for map in $open; do
        if [[ $key == "$map".* ]]; then continue 2; fi
      done
      unknown+=" $key"
    done < <(comm -23 "$keys/$app.ours" "$keys/$app.chart")
    [ -z "$unknown" ] || { echo "$app: keys the chart does not define:$unknown"; return 1; }
  done
}

@test "The instance syncs this cluster's path from the main tag" {
  render flux-instance
  local sync
  sync="$(instance '.spec.sync | [.kind, .url, .ref, .path] | join(" ")')"
  echo "kind, url, ref and path: $sync"
  # The artifact CI publishes from this repository holds the kubernetes/ tree, so the path is read
  # from there.
  [ "$sync" = "OCIRepository oci://ghcr.io/eekaan/k8s-gitops/manifests main ./clusters/lab-sto2" ]
  [ -f "$REPO/kubernetes/clusters/lab-sto2/kustomization.yaml" ]
}

@test "The synced artifact must be signed by the publish workflow on main" {
  patched_flux
  local verify issuer subject
  verify="$(patched "select(.kind == \"OCIRepository\" and .metadata.name == \"$SYNC\") | .spec.verify")"
  echo "verify: $verify"
  [ "$(yq '.provider' <<<"$verify")" = cosign ]
  [ "$(yq '.matchOIDCIdentity | length' <<<"$verify")" -eq 1 ]
  [ "$(yq '.secretRef // "none"' <<<"$verify")" = none ]
  issuer="$(yq '.matchOIDCIdentity[0].issuer' <<<"$verify")"
  subject="$(yq '.matchOIDCIdentity[0].subject' <<<"$verify")"

  # Flux reads the patterns as Go regular expressions and bash as POSIX extended ones. The values
  # keep to syntax both read alike, so what bash accepts here is what Flux accepts.
  local github=https://token.actions.githubusercontent.com
  local main="https://github.com/eekaan/k8s-gitops/.github/workflows/publish.yaml@refs/heads/main"
  [[ $github =~ $issuer ]]
  [[ $main =~ $subject ]]
  local -a others
  mapfile -t others < <(dotless "$github")
  rejects "$issuer" "${others[@]}" "$github.example.com" "https://example.com/$github"
  mapfile -t others < <(dotless "$main")
  rejects "$subject" "${others[@]}" \
    "https://example.com/$main" \
    "${main%main}feature" \
    "${main}-old" \
    "${main%heads/main}tags/main" \
    "${main%heads/main}tags/v1.0.0" \
    "${main%heads/main}pull/1/merge" \
    "${main/k8s-gitops/other}" \
    "${main/eekaan/someone-else}" \
    "${main/publish.yaml/other.yaml}"
}

@test "The Flux manifests are pinned to the operator's version" {
  render flux-instance
  local artifact operator
  artifact="$(instance '.spec.distribution.artifact')"
  operator="$(kustomize build "$CLUSTER/flux-system/flux-operator/app" |
    yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag')"
  echo "manifests: $artifact; operator chart: $operator"
  [[ $operator =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  [ "$artifact" = "oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests:v$operator" ]
}

@test "The source-watcher runs" {
  render flux-instance
  instance '.spec.components[]'
  instance '.spec.components[]' | grep -qx source-watcher
}

@test "the instance gives kustomize-controller the age key" {
  patched_flux
  local args
  args="$(patched 'select(.kind == "Deployment" and .metadata.name == "kustomize-controller")
    | .spec.template.spec.containers[0].args[]')"
  echo "kustomize-controller: $args"
  grep -qx -- --sops-age-secret=sops-age <<<"$args"
}

@test "the instance's sync Kustomization decrypts and substitutes as the root does" {
  patched_flux
  local want got
  local fields='{"decryption": .spec.decryption, "substituteFrom": .spec.postBuild.substituteFrom}'
  want="$(yq -o json -I0 "$fields" "$CLUSTER/ks.yaml")"
  got="$(patched "select(.kind == \"Kustomization\" and .metadata.name == \"$SYNC\") | $fields" | yq -o json -I0)"
  echo "root: $want"
  echo "sync: $got"
  [ "$got" = "$want" ]
}

@test "A failed upgrade of Flux's own releases is retried and rolled back" {
  local app remediation
  for app in flux-operator flux-instance; do
    remediation="$(kustomize build "$CLUSTER/flux-system/$app/app" | yq ea '[select(.kind == "HelmRelease")]
      | .[0].spec.upgrade.remediation | [.retries // 0, .strategy // "none", .remediateLastFailure // false]
      | map(tostring) | join(" ")')"
    echo "$app: retries, strategy, last failure remediated: $remediation"
    [[ $remediation =~ ^[1-5]\ rollback\ true$ ]]
  done
}

@test "Removing Flux's own applications does not uninstall Flux" {
  local app built kept
  for app in flux-operator flux-instance; do
    built="$(kustomize build "$CLUSTER/flux-system/$app/app")"
    kept="$(yq -N 'select(.kind == "HelmRelease" or .kind == "OCIRepository")
      | .kind + "/" + .metadata.name + " " + (.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"] // "none")' <<<"$built")"
    echo "$app: $kept"
    [ "$(grep -c ' disabled$' <<<"$kept")" -eq 2 ]
    # A values ConfigMap left behind by a change of values is still collected.
    [ "$(yq -N 'select(.kind == "ConfigMap")
      | .metadata.annotations["kustomize.toolkit.fluxcd.io/prune"] // "none"' <<<"$built")" = none ]
  done
  render flux-instance
  instance '.metadata.annotations'
  [ "$(instance '.metadata.annotations["helm.sh/resource-policy"]')" = keep ]
}

@test "The cluster directory builds only the root and Flux itself" {
  local root got want
  root="$(yq '.metadata.name' "$CLUSTER/ks.yaml")"
  got="$(kustomize build "$CLUSTER" | yq -N '.apiVersion + " " + .kind + "/" + .metadata.name' | sort)"
  want="$(printf 'kustomize.toolkit.fluxcd.io/v1 Kustomization/%s\n' "$root" flux-operator flux-instance | sort)"
  echo "built: $got"
  [ "$got" = "$want" ]
}

@test "the cluster directory builds nothing the instance generates" {
  render flux-instance
  local name built
  name="$(instance '.spec.sync.name // .metadata.namespace')"
  built="$(kustomize build "$CLUSTER" | yq -N '.kind + "/" + .metadata.name')"
  echo "sync objects: $name; cluster directory: $built"
  if grep -qx -e "Kustomization/$name" -e "OCIRepository/$name" <<<"$built"; then
    echo "the cluster directory builds an object the instance also generates"
    return 1
  fi
}
