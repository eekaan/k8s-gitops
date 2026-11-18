#!/usr/bin/env bats
# Proves features/backstage.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq and jq on PATH (the versions pinned for the repository). The
# app-template chart is pulled once per run from its public registry; building and rendering are
# offline, with the placeholders of the cluster's example key lists.

# flux build rewrites the kustomization.yaml of what it builds and puts it back afterwards, and the
# chart is pulled once: so the tests run one at a time.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

# Names sort and compare byte for byte.
export LC_ALL=C

# The repository's public address, which the catalogue's links point into, and the application's
# files in the tree.
PUBLIC_URL=https://github.com/eekaan/k8s-gitops
APP_DIR=kubernetes/apps/base/backstage/backstage/app

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
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  EXAMPLE="$BATS_TEST_TMPDIR/example-vars.yaml"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$EXAMPLE"
  OVERLAY_DIR="$REPO/kubernetes/apps/overlays/lab-sto2"
  CATALOGUE="$REPO/$APP_DIR/catalogue"
}

# overlay: the lab-sto2 overlay as Flux reads it. Writes $OVERLAY.
overlay() {
  OVERLAY="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "${1:-$OVERLAY_DIR}" >"$OVERLAY"
}

# built APP: the application APP as Flux applies it on lab-sto2: the overlay's Kustomization of it,
# with the example key lists, or those of the file VARS names, and its own substitutions over them,
# strictly. Writes $BATS_TEST_TMPDIR/APP-built.yaml and sets BUILT and KS, the Kustomization as built.
built() {
  local app=$1 path
  overlay
  KS="$BATS_TEST_TMPDIR/$app-ks.yaml"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  NAME="$app" yq ea 'select(fileIndex == 0) as $vars
    | select(fileIndex == 1 and .kind == "Kustomization" and .metadata.name == strenv(NAME))
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "${VARS:-$EXAMPLE}" "$OVERLAY" >"$KS"
  [ -s "$KS" ] || { echo "the lab-sto2 overlay does not enable $app"; return 1; }
  path="$(yq '.spec.path' "$KS")"
  BUILT="$BATS_TEST_TMPDIR/$app-built.yaml"
  (cd "$REPO" && flux build kustomization "$app" --path "./kubernetes/${path#./}" \
    --kustomization-file "$KS" --dry-run --strict-substitute) >"$BUILT"
}

# render: renders the chart that Backstage's HelmRelease installs, from the URL and tag of its
# OCIRepository, with the values helm-controller gives it: those of each ConfigMap the HelmRelease
# reads, in order, then the HelmRelease's own over them, as scripts/render does. Builds backstage,
# writes $BATS_TEST_TMPDIR/rendered.yaml and sets BUILT, RENDERED and INLINE.
render() {
  local url tag release namespace pulled name i values=() count
  built backstage
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  count="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom | length' "$BUILT")"
  for ((i = 0; i < count; i++)); do
    name="$(I=$i yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[env(I)].name' "$BUILT")"
    [ "$(I=$i yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[env(I)].kind' "$BUILT")" = ConfigMap ] ||
      { echo "valuesFrom $name is not a ConfigMap"; return 1; }
    values[i]="$BATS_TEST_TMPDIR/values-$i.yaml"
    NAME="$name" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .data["values.yaml"]' \
      "$BUILT" >"${values[i]}"
    [ -s "${values[i]}" ] || { echo "no values in the ConfigMap $name the HelmRelease reads"; return 1; }
  done
  INLINE="$BATS_TEST_TMPDIR/inline.yaml"
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$BUILT" >"$INLINE"
  pulled="$BATS_FILE_TMPDIR/charts/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  RENDERED="$BATS_TEST_TMPDIR/rendered.yaml"
  helm template "$release" "$pulled"/*.tgz --namespace "$namespace" --kube-version "$KUBE" \
    "${values[@]/#/--values=}" --values "$INLINE" >"$RENDERED"
}

# only FILE KIND: the name of the one object of that kind in FILE; fails, saying so, unless there is
# exactly one.
only() {
  local names
  names="$(KIND="$2" yq -N 'select(.kind == strenv(KIND)) | .metadata.name' "$1")"
  [ -n "$names" ] && [ "$(wc -l <<<"$names")" -eq 1 ] || { echo "$1 holds $(wc -l <<<"$names") $2 objects: ${names:-none}"; return 1; }
  echo "$names"
}

# object FILE KIND NAME: the one object of that kind and name in FILE.
object() {
  KIND="$2" NAME="$3" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$1"
}

# container: writes the Deployment that RENDERED holds to $DEPLOYMENT and its one container, main,
# to $CONTAINER.
container() {
  DEPLOYMENT="$BATS_TEST_TMPDIR/deployment.yaml"
  CONTAINER="$BATS_TEST_TMPDIR/container.yaml"
  object "$RENDERED" Deployment "$(only "$RENDERED" Deployment)" >"$DEPLOYMENT"
  [ "$(yq '.spec.template.spec.containers | length' "$DEPLOYMENT")" -eq 1 ]
  yq '.spec.template.spec.containers[] | select(.name == "main")' "$DEPLOYMENT" >"$CONTAINER"
  [ -s "$CONTAINER" ] || { echo "the pod has no container main"; return 1; }
}

# env_of NAME: the entry called NAME of the container's environment, as compact JSON; empty when
# none.
env_of() {
  NAME="$1" yq -o json -I0 '.env[] | select(.name == strenv(NAME))' "$CONTAINER"
}

# env_value NAME: the literal value of the variable NAME of the container; fails when it has none.
env_value() {
  NAME="$1" yq -e '.env[] | select(.name == strenv(NAME)) | .value' "$CONTAINER"
}

# secret_key NAME SECRET KEY: succeeds when the variable NAME of the container is read from the key
# KEY of the Secret SECRET.
secret_key() {
  [ "$(env_of "$1" | jq -cS .)" = "$(SECRET="$2" KEY="$3" NAME="$1" yq -o json -I0 -n \
    '{"name": strenv(NAME), "valueFrom": {"secretKeyRef": {"name": strenv(SECRET), "key": strenv(KEY)}}}' | jq -cS .)" ]
}

# mounts: every volume mount of the container, one per line and sorted: its path, what the volume
# is (emptyDir, claim NAME, or configMap NAME, as built) and read-only when the mount is.
mounts() {
  yq -o json '.spec.template.spec.volumes // []' "$DEPLOYMENT" >"$BATS_TEST_TMPDIR/volumes.json"
  yq -o json '.volumeMounts // []' "$CONTAINER" | jq -r --slurpfile volumes "$BATS_TEST_TMPDIR/volumes.json" '
    .[] | . as $m | (first($volumes[0][] | select(.name == $m.name)) // {}) as $v
    | [$m.mountPath,
       (if $v.emptyDir then "emptyDir"
        elif $v.persistentVolumeClaim then "claim " + $v.persistentVolumeClaim.claimName
        elif $v.configMap then "configMap"
        elif $v.secret then "secret"
        else "other" end)]
      + (if $m.readOnly then ["read-only"] else [] end)
    | join(" ")' | LC_ALL=C sort
}

# configmap_at PATH: the name of the ConfigMap the container mounts at PATH.
configmap_at() {
  local volume
  volume="$(MOUNT="$1" yq '.volumeMounts[] | select(.mountPath == strenv(MOUNT)) | .name' "$CONTAINER")"
  [ -n "$volume" ] || { echo "nothing is mounted at $1"; return 1; }
  VOLUME="$volume" yq -e '.spec.template.spec.volumes[] | select(.name == strenv(VOLUME)) | .configMap.name' "$DEPLOYMENT"
}

# app_config: writes the configuration Backstage is given, the file in the ConfigMap mounted at
# /config, to $APP_CONFIG.
app_config() {
  APP_CONFIG="$BATS_TEST_TMPDIR/app-config.yaml"
  NAME="$(configmap_at /config)" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .data["app-config.yaml"]' \
    "$BUILT" >"$APP_CONFIG"
  [ -s "$APP_CONFIG" ] || { echo "no app-config.yaml in the ConfigMap mounted at /config"; return 1; }
}

# other_vars: writes a copy of the example values with another domain and sets OTHER to it, so a
# test can build again and see that what it read came from the variable.
other_vars() {
  OTHER="$BATS_TEST_TMPDIR/other-vars.yaml"
  CLUSTER_DOMAIN=other.example.org yq '.CLUSTER_DOMAIN = strenv(CLUSTER_DOMAIN)' "$EXAMPLE" >"$OTHER"
}

# tree_without_ks APP / tree_without_dir NAME: copy kubernetes/ to $TREE and take an application's
# ks.yaml, or a namespace directory, out of the overlay's resources.
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
    APP="$app" yq -i '.resources |= map(select(test("/" + strenv(APP) + "/ks.yaml$") | not))' \
      "$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  done
}

tree_without_dir() {
  tree_copy
  NS="$1" yq -i '.resources |= map(select(. != "../../base/" + strenv(NS)))' \
    "$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
}

# of_backstage FILE: what an overlay built into FILE holds of backstage, sorted, as kind, namespace
# and name: the namespace itself, any object in it, and any Kustomization that deploys into it or
# from its directory.
of_backstage() {
  yq -N 'select((.kind == "Namespace" and .metadata.name == "backstage") or .metadata.namespace == "backstage"
      or .spec.targetNamespace == "backstage" or ((.spec.path // "") | test("/apps/base/backstage/")))
    | .kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$1" | LC_ALL=C sort | paste -sd, -
}

@test "Backstage is selected by overlay entries and builds nothing when it is not" {
  local dependency dependencies=(cloudnative-pg plugin-barman-cloud prometheus-operator-crds external-secrets openbao-store gateway-public cilium blackbox-exporter)
  # The overlay selects it with two entries, its namespace directory and its ks.yaml, and builds the
  # namespace, the defaults every namespace directory holds, the namespace's default deny, and the
  # Kustomization.
  [ "$(yq '.resources[] | select(test("/backstage(/|$)"))' "$OVERLAY_DIR/kustomization.yaml" | paste -sd, -)" = ../../base/backstage,../../base/backstage/backstage/ks.yaml ]
  overlay
  [ "$(of_backstage "$OVERLAY")" = ConfigMap/backstage/app-template-defaults,Kustomization/flux-system/backstage,Namespace/-/backstage,NetworkPolicy/backstage/default-deny ]
  # Its Kustomization names what it needs, no more and no less, and is Ready once Backstage is.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "backstage") | .spec.dependsOn | map(.name) | sort | join(" ")' "$OVERLAY")" \
    = "$(printf '%s\n' "${dependencies[@]}" | sort | paste -sd' ' -)" ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "backstage") | .spec.wait' "$OVERLAY")" = true ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # With only the namespace directory's entry, the cluster builds the namespace, its defaults and its
  # default deny, and nothing else of backstage.
  tree_without_ks backstage
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2" >"$BATS_TEST_TMPDIR/namespace-only.yaml"
  [ "$(of_backstage "$BATS_TEST_TMPDIR/namespace-only.yaml")" = ConfigMap/backstage/app-template-defaults,Namespace/-/backstage,NetworkPolicy/backstage/default-deny ]
  # With neither, nothing of backstage.
  tree_without_ks backstage
  NS=backstage yq -i '.resources |= map(select(. != "../../base/" + strenv(NS)))' "$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2" >"$BATS_TEST_TMPDIR/neither.yaml"
  [ -z "$(of_backstage "$BATS_TEST_TMPDIR/neither.yaml")" ]
  # Selecting it without one of the applications it needs is refused, naming both.
  for dependency in "${dependencies[@]}"; do
    tree_without_ks "$dependency"
    run "$REPO/scripts/kubernetes-check" "$TREE"
    echo "without $dependency: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"kubernetes/apps/base/backstage/backstage/ks.yaml: Kustomization backstage names $dependency"* ]]
    [[ $output == *"does not enable"* ]]
  done
}

# slug HEADING: the anchor GitHub gives a heading: lower case, anything but letters, digits, spaces,
# hyphens and underscores dropped, spaces made hyphens.
slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9 _-]//g; s/ /-/g'
}

# anchors FILE: the anchor of every heading of the Markdown file FILE outside code fences, one per
# line.
anchors() {
  local heading
  awk '/^```/ { fence = !fence; next } !fence && /^#+ / { sub(/^#+ +/, ""); print }' "$1" |
    while IFS= read -r heading; do slug "$heading"; echo; done
}

# entities: every entity of the catalogue's files, one per line: file name, kind, name.
entities() {
  yq -N '[filename | sub("^.*/", ""), .kind, .metadata.name] | join(" ")' "$CATALOGUE"/*.yaml
}

@test "The catalogue holds exactly one entity for every application the overlay selects, and every entity's links and dependencies exist in the tree" {
  local apps file kind name app dep ref expected actual url path anchor line
  overlay
  apps="$(yq -N 'select(.kind == "Kustomization") | .metadata.name' "$OVERLAY" | LC_ALL=C sort)"
  [ -n "$apps" ]
  echo "applications: $(paste -sd' ' - <<<"$apps")"
  # Every Component and Resource is an application, in a file of its own name; Domain, System and
  # Group entities give them their place and their owner.
  : >"$BATS_TEST_TMPDIR/entity-names"
  : >"$BATS_TEST_TMPDIR/refs"
  while read -r file kind name; do
    echo "$kind:default/$name" | tr '[:upper:]' '[:lower:]' >>"$BATS_TEST_TMPDIR/refs"
    case "$kind" in
      Component | Resource)
        [ "$file" = "$name.yaml" ] || { echo "$kind $name is in $file, not $name.yaml"; return 1; }
        echo "$name" >>"$BATS_TEST_TMPDIR/entity-names"
        ;;
      Domain | System | Group) ;;
      *) echo "$file holds a $kind $name: the catalogue has Domain, System, Group, Component and Resource entities"; return 1 ;;
    esac
  done < <(entities)
  # Exactly one entity per application, and none for anything else.
  [ -z "$(LC_ALL=C sort "$BATS_TEST_TMPDIR/entity-names" | uniq -d)" ] || { echo "two entities of one name: $(LC_ALL=C sort "$BATS_TEST_TMPDIR/entity-names" | uniq -d)"; return 1; }
  [ -z "$(comm -23 <(echo "$apps") <(LC_ALL=C sort "$BATS_TEST_TMPDIR/entity-names"))" ] ||
    { echo "applications without an entity: $(comm -23 <(echo "$apps") <(LC_ALL=C sort "$BATS_TEST_TMPDIR/entity-names") | paste -sd' ' -)"; return 1; }
  [ -z "$(comm -13 <(echo "$apps") <(LC_ALL=C sort "$BATS_TEST_TMPDIR/entity-names"))" ] ||
    { echo "entities of no application: $(comm -13 <(echo "$apps") <(LC_ALL=C sort "$BATS_TEST_TMPDIR/entity-names") | paste -sd' ' -)"; return 1; }
  # The owner, system and domain of each entity are entities of the catalogue.
  while IFS= read -r ref; do
    grep -qxF "$ref" "$BATS_TEST_TMPDIR/refs" || { echo "no entity $ref"; return 1; }
  done < <(yq -N '.spec.owner // ""' "$CATALOGUE"/*.yaml | grep -v '^$' | LC_ALL=C sort -u)
  while IFS= read -r ref; do
    grep -qxF "system:default/$ref" "$BATS_TEST_TMPDIR/refs" || { echo "no System $ref"; return 1; }
  done < <(yq -N 'select(.kind == "Component" or .kind == "Resource") | .spec.system' "$CATALOGUE"/*.yaml | LC_ALL=C sort -u)
  while IFS= read -r ref; do
    grep -qxF "domain:default/$ref" "$BATS_TEST_TMPDIR/refs" || { echo "no Domain $ref"; return 1; }
  done < <(yq -N 'select(.kind == "System") | .spec.domain' "$CATALOGUE"/*.yaml | LC_ALL=C sort -u)
  # Each entity has a description and an owner and a system.
  [ -z "$(yq -N 'select(.kind == "Component" or .kind == "Resource") | select((.metadata.description // "") == "" or (.spec.owner // "") == "" or (.spec.system // "") == "") | .metadata.name' "$CATALOGUE"/*.yaml)" ]
  # What each depends on is what its Kustomization, as the overlay builds it, names in dependsOn,
  # as the entities of those applications.
  while read -r app; do
    expected=""
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      kind="$(entities | awk -v n="$dep" '$3 == n && ($2 == "Component" || $2 == "Resource") { print tolower($2) }')"
      [ -n "$kind" ] || { echo "$app depends on $dep, which has no entity"; return 1; }
      expected+="$kind:default/$dep"$'\n'
    done < <(APP="$app" yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(APP)) | .spec.dependsOn[]?.name' "$OVERLAY")
    expected="$(LC_ALL=C sort <<<"$expected" | grep -v '^$' || true)"
    actual="$(NAME="$app" yq -N 'select((.kind == "Component" or .kind == "Resource") and .metadata.name == strenv(NAME)) | .spec.dependsOn[]?' "$CATALOGUE/$app.yaml" | LC_ALL=C sort)"
    [ "$actual" = "$expected" ] || { echo "$app: its entity depends on [$(paste -sd' ' - <<<"$actual")], its Kustomization on [$(paste -sd' ' - <<<"$expected")]"; return 1; }
    while IFS= read -r ref; do
      [ -z "$ref" ] || grep -qxF "$ref" "$BATS_TEST_TMPDIR/refs" || { echo "$app depends on $ref, which is no entity"; return 1; }
    done <<<"$actual"
  done <<<"$apps"
  # No key anywhere in the files begins with $, as the placeholders $text, $json and $yaml do: the
  # catalogue replaces each with what it reads at the address or path the placeholder names.
  local placeholders
  # shellcheck disable=SC2016 # $file is a jq variable.
  placeholders="$(for file in "$CATALOGUE"/*.yaml; do
    yq -o json -I0 '.' "$file" | jq -r --arg file "${file##*/}" '.. | objects | keys[] | select(startswith("$")) | $file + ": " + .'
  done)"
  echo "keys that begin with \$: ${placeholders:-none}"
  [ -z "$placeholders" ]
  # Every link is to this repository's own files: a file that exists, a directory that does, and for
  # a Markdown file the heading its anchor names. No other address is in the catalogue.
  [ -z "$(grep -hv '^[[:space:]]*#' "$CATALOGUE"/*.yaml | grep -oE 'https?://[^ "]+' | grep -v "^$PUBLIC_URL/" || true)" ] || { echo "an address outside the repository: $(grep -hv '^[[:space:]]*#' "$CATALOGUE"/*.yaml | grep -oE 'https?://[^ "]+' | grep -v "^$PUBLIC_URL/")"; return 1; }
  [ -n "$(yq -N '.metadata.links[]?.url' "$CATALOGUE"/*.yaml)" ]
  # shellcheck disable=SC2016 # $n is a yq variable.
  while read -r app url; do
    path="${url#"$PUBLIC_URL"/}"
    case "$path" in
      blob/main/*) path="${path#blob/main/}" ;;
      tree/main/*) path="${path#tree/main/}" ;;
      *) echo "$app: the link $url is neither a blob nor a tree of main"; return 1 ;;
    esac
    anchor=""
    if [[ $path == *"#"* ]]; then
      anchor="${path#*#}"
      path="${path%%#*}"
    fi
    case "$url" in
      "$PUBLIC_URL"/tree/main/*) [ -d "$REPO/$path" ] || { echo "$app: $url, but $path is not a directory of the tree"; return 1; } ;;
      *) [ -f "$REPO/$path" ] || { echo "$app: $url, but $path is not a file of the tree"; return 1; } ;;
    esac
    if [ -n "$anchor" ]; then
      [[ $path == *.md ]] || { echo "$app: $url names an anchor in $path, which is not Markdown"; return 1; }
      anchors "$REPO/$path" | grep -qxF "$anchor" || { echo "$app: $url, but $path has no heading with the anchor #$anchor"; return 1; }
    fi
  done < <(yq -N '.metadata.name as $n | .metadata.links[]? | $n + " " + .url' "$CATALOGUE"/*.yaml)
  # Each application's entity links to its section of the docs, as the first link.
  while IFS= read -r line; do
    [[ $line == *"$PUBLIC_URL/blob/main/docs/"*".md#"* ]] || { echo "an application's first link is not to a section of the docs: $line"; return 1; }
  done < <(yq -N 'select(.kind == "Component" or .kind == "Resource") | .metadata.name + " " + .metadata.links[0].url' "$CATALOGUE"/*.yaml)
}

@test "The catalogue's dependencies are regenerated from the Kustomizations" {
  tree_copy
  cp -r "$REPO/scripts" "$TREE/scripts"
  # The tree as it is needs no change.
  (cd "$TREE" && find "$APP_DIR/catalogue" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) >"$BATS_TEST_TMPDIR/before"
  run "$REPO/scripts/catalogue-dependencies" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  (cd "$TREE" && find "$APP_DIR/catalogue" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) >"$BATS_TEST_TMPDIR/after"
  diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  # An application that names another in dependsOn, which its entity does not list.
  [ "$(yq '[.spec.dependsOn[]?.name] | join(",")' "$TREE/kubernetes/apps/base/demo/hello/ks.yaml")" = cilium ]
  yq -i '.spec.dependsOn += [{"name": "keda"}]' "$TREE/kubernetes/apps/base/demo/hello/ks.yaml"
  run "$REPO/scripts/catalogue-dependencies" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(yq '.spec.dependsOn | join(",")' "$TREE/$APP_DIR/catalogue/hello.yaml")" = component:default/cilium,component:default/keda ]
  # Only that entity changed, and a second run changes nothing.
  (cd "$TREE" && find "$APP_DIR/catalogue" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) >"$BATS_TEST_TMPDIR/changed"
  [ "$(diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/changed" | grep -c '^<')" -eq 1 ]
  run "$REPO/scripts/catalogue-dependencies" "$TREE"
  [ "$status" -eq 0 ]
  (cd "$TREE" && find "$APP_DIR/catalogue" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) >"$BATS_TEST_TMPDIR/again"
  diff "$BATS_TEST_TMPDIR/changed" "$BATS_TEST_TMPDIR/again"
  # A dependency with no entity is refused, naming both.
  # The refusal leaves every file as it was, the entity of the application with the dependency
  # that does not resolve included, though the one it does resolve is a change.
  yq -i '.spec.dependsOn = [{"name": "cilium"}, {"name": "missing-app"}]' "$TREE/kubernetes/apps/base/demo/hello/ks.yaml"
  run "$REPO/scripts/catalogue-dependencies" "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"hello"*"missing-app"* ]]
  (cd "$TREE" && find "$APP_DIR/catalogue" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) >"$BATS_TEST_TMPDIR/refused"
  diff "$BATS_TEST_TMPDIR/changed" "$BATS_TEST_TMPDIR/refused"
}

@test "Backstage reads its catalogue from files in the cluster and calls nothing outside" {
  local name key location
  render
  container
  app_config
  # The locations are one glob of files, in the directory the pod mounts read-only from the
  # ConfigMap, which holds exactly the entity files of the catalogue's directory.
  [ "$(yq '.catalog.locations | length' "$APP_CONFIG")" -eq 1 ]
  [ "$(yq '.catalog.locations[0].type' "$APP_CONFIG")" = file ]
  location="$(yq '.catalog.locations[0].target' "$APP_CONFIG")"
  [ "$location" = '/catalogue/*.yaml' ]
  [ "$(mounts | grep '^/catalogue ')" = "/catalogue configMap read-only" ]
  name="$(configmap_at /catalogue)"
  [ "$(NAME="$name" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .data | keys | .[]' "$BUILT" | LC_ALL=C sort | paste -sd, -)" \
    = "$(cd "$CATALOGUE" && printf '%s\n' *.yaml | LC_ALL=C sort | paste -sd, -)" ]
  for key in $(cd "$CATALOGUE" && printf '%s\n' *.yaml); do
    [ "$(NAME="$name" KEY="$key" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .data[strenv(KEY)]' "$BUILT")" = "$(cat "$CATALOGUE/$key")" ] ||
      { echo "the ConfigMap's $key is not the file"; return 1; }
  done
  # No other kind of location anywhere in the configuration, and nothing that reads from or calls
  # a service: no integration, no proxy endpoint, no entity provider, no Kubernetes cluster, no
  # TechDocs builder, no analytics.
  [ -z "$(yq '.. | select(has("type")) | select(.type == "url")' "$APP_CONFIG")" ]
  [ -z "$(grep -E '^[[:space:]]*(type: *url|target: *https?:)' "$APP_CONFIG" || true)" ]
  for key in integrations proxy kubernetes scaffolder analytics; do
    [ "$(KEY=$key yq '.[strenv(KEY)] // "absent"' "$APP_CONFIG")" = absent ] || { echo "the configuration has $key"; return 1; }
  done
  [ "$(yq '.app.analytics // "absent"' "$APP_CONFIG")" = absent ]
  [ "$(yq '.catalog.providers // "absent"' "$APP_CONFIG")" = absent ]
  [ "$(yq '.backend.reading // "absent"' "$APP_CONFIG")" = absent ]
  [ "$(yq '.techdocs.builder' "$APP_CONFIG")" = external ]
  [ "$(yq '.techdocs.publisher // "absent"' "$APP_CONFIG")" = absent ]
  # The configuration Backstage loads is that file and nothing else: the command is the image's own
  # with one --config, no argument follows it, and the only variables are the database's and the two
  # base URLs, so no other app-config file of the image and no APP_CONFIG_* setting adds to it.
  [ "$(yq -o json -I0 '.command' "$CONTAINER")" = '["node","packages/backend","--config","/config/app-config.yaml"]' ]
  [ "$(yq '.args // "absent"' "$CONTAINER")" = absent ]
  [ "$(yq '.envFrom // "absent"' "$CONTAINER")" = absent ]
  [ "$(yq '.env[].name' "$CONTAINER" | LC_ALL=C sort | paste -sd, -)" \
    = APP_CONFIG_app_baseUrl,APP_CONFIG_backend_baseUrl,DB_HOST,DB_NAME,DB_PASSWORD,DB_PORT,DB_USER ]
  # The catalogue's own files hold no address but the links to this repository, and no variable.
  # shellcheck disable=SC2016 # the text searched for is a literal.
  [ -z "$(grep -l '\${' "$CATALOGUE"/*.yaml || true)" ]
  # Behind the route, the network: the namespace denies traffic both ways by default, with no rule,
  # and the policies that select Backstage's pod let it send to the cluster's resolver and to its
  # database's instances on PostgreSQL's port, and nowhere else (tests/network-policy.bats evaluates
  # the flows on the render of the tree).
  overlay
  [ "$(yq -N 'select(.kind == "NetworkPolicy" and .metadata.namespace == "backstage") | .metadata.name' "$OVERLAY")" = default-deny ]
  [ "$(yq -N -o json -I0 'select(.kind == "NetworkPolicy" and .metadata.namespace == "backstage") | .spec' "$OVERLAY")" \
    = '{"podSelector":{},"policyTypes":["Ingress","Egress"]}' ]
  yq -o json -I0 '.spec.template.metadata.labels' "$DEPLOYMENT" >"$BATS_TEST_TMPDIR/labels.json"
  [ -z "$(yq -N 'select(.kind == "CiliumNetworkPolicy" and (.spec.endpointSelector.matchExpressions // [] | length) > 0) | .metadata.name' "$BUILT")" ]
  [ "$(yq -N -o json -I0 'select(.kind == "CiliumNetworkPolicy")' "$BUILT" | jq -s -c --slurpfile labels "$BATS_TEST_TMPDIR/labels.json" '
      [ .[] | select(.spec.endpointSelector.matchLabels | to_entries | all(.[]; $labels[0][.key] == .value)) | .spec.egress[]? ] | sort')" \
    = '[{"toEndpoints":[{"matchLabels":{"cnpg.io/cluster":"backstage-db","cnpg.io/podRole":"instance"}}],"toPorts":[{"ports":[{"port":"5432","protocol":"TCP"}]}]},{"toEndpoints":[{"matchLabels":{"k8s:io.kubernetes.pod.namespace":"kube-system","k8s:k8s-app":"kube-dns"}}],"toPorts":[{"ports":[{"port":"53","protocol":"UDP"},{"port":"53","protocol":"TCP"}]}]}]' ]
  # The application's three generated ConfigMaps are the tree's files as they are: Flux substitutes
  # none of them. The database component's ConfigMap of the dump job's scripts is not one of them.
  [ "$(yq -N 'select(.kind == "ConfigMap" and (.metadata.name | test("^backstage-(values|config|catalogue)-[a-z0-9]+$"))) | .metadata.name | sub("-[a-z0-9]+$"; "")' "$BUILT" | LC_ALL=C sort | paste -sd, -)" \
    = backstage-catalogue,backstage-config,backstage-values ]
  [ "$(yq -N 'select(.kind == "ConfigMap" and (.metadata.name | test("^backstage-(values|config|catalogue)-[a-z0-9]+$"))) | .metadata.annotations["kustomize.toolkit.fluxcd.io/substitute"]' "$BUILT" | sort -u)" = disabled ]
}

@test "Backstage's pod meets the restricted level with a read-only root and only the writable mounts it needs, and its database comes from the PostgreSQL component" {
  local cluster
  render
  container
  overlay
  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "backstage") | .metadata.labels["pod-security.kubernetes.io/enforce"]' "$OVERLAY")" = restricted ]
  # The pod: a non-root user, the runtime's seccomp profile, no host namespace, no service account
  # token, one container, no init container.
  [ "$(yq '.spec.template.spec.securityContext.runAsNonRoot' "$DEPLOYMENT")" = true ]
  [ "$(yq '.spec.template.spec.securityContext.runAsUser' "$DEPLOYMENT")" -gt 0 ]
  [ "$(yq '.spec.template.spec.securityContext.seccompProfile.type' "$DEPLOYMENT")" = RuntimeDefault ]
  [ "$(yq '[.spec.template.spec.hostNetwork, .spec.template.spec.hostPID, .spec.template.spec.hostIPC] | map(. // false) | join(",")' "$DEPLOYMENT")" = false,false,false ]
  [ "$(yq '.spec.template.spec.automountServiceAccountToken' "$DEPLOYMENT")" = false ]
  [ "$(yq '.spec.template.spec.initContainers // [] | length' "$DEPLOYMENT")" -eq 0 ]
  # The container: no escalation, no capability, a root filesystem it cannot write, an image of a
  # tag and a digest, requests and a memory limit, and the image's own health endpoints.
  [ "$(yq '.securityContext.allowPrivilegeEscalation' "$CONTAINER")" = false ]
  [ "$(yq '.securityContext.readOnlyRootFilesystem' "$CONTAINER")" = true ]
  [ "$(yq '.securityContext.capabilities.drop | join(",")' "$CONTAINER")" = ALL ]
  [ "$(yq '.securityContext.capabilities.add // [] | length' "$CONTAINER")" -eq 0 ]
  [ "$(yq '.securityContext.privileged // false' "$CONTAINER")" = false ]
  [[ $(yq '.image' "$CONTAINER") =~ ^ghcr\.io/backstage/backstage:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]] || { echo "image: $(yq '.image' "$CONTAINER")"; return 1; }
  [ "$(yq '.resources.requests.cpu' "$CONTAINER")" != null ]
  [ "$(yq '.resources.requests.memory' "$CONTAINER")" != null ]
  [ "$(yq '.resources.limits.memory' "$CONTAINER")" != null ]
  [ "$(yq '.livenessProbe.httpGet.path' "$CONTAINER")" = /.backstage/health/v1/liveness ]
  [ "$(yq '.readinessProbe.httpGet.path' "$CONTAINER")" = /.backstage/health/v1/readiness ]
  [ "$(yq '.startupProbe.httpGet.path' "$CONTAINER")" = /.backstage/health/v1/liveness ]
  # What it mounts: its configuration and its catalogue, read-only, from ConfigMaps, and nothing it
  # can write: the pinned image, run read-only with those two alone, starts and serves.
  echo "mounts: $(mounts | paste -sd, -)"
  [ "$(mounts | paste -sd, -)" = "/catalogue configMap read-only,/config configMap read-only" ]
  [ -z "$(mounts | grep -v ' read-only$' || true)" ]
  [ -z "$(yq '.spec.template.spec.volumes[] | select(has("emptyDir") or has("persistentVolumeClaim") or has("hostPath"))' "$DEPLOYMENT")" ]
  # One replica, which lets go of the database before its successor starts: two pods that start
  # together against an empty database both fail creating the schemas and tables. No budget, which
  # with one pod would stop every drain.
  [ "$(yq '.spec.replicas' "$DEPLOYMENT")" -eq 1 ]
  [ "$(yq '.spec.strategy.type' "$DEPLOYMENT")" = Recreate ]
  [ -z "$(yq -N 'select(.kind == "PodDisruptionBudget") | .metadata.name' "$BUILT" "$RENDERED")" ]
  # The database is the component's: the Kustomization takes it for the cluster backstage-db, which
  # yields one Cluster of three instances and its PodMonitor, and Backstage reads its connection
  # from the keys of the Secret the operator makes for it.
  [ "$(yq '.spec.components | map(select(test("/components/cnpg-cluster$"))) | length' "$KS")" -eq 1 ]
  [ "$(yq '.spec.postBuild.substitute.CNPG_CLUSTER_NAME' "$KS")" = backstage-db ]
  cluster="$(only "$BUILT" Cluster)"
  [ "$cluster" = backstage-db ]
  [ "$(object "$BUILT" Cluster "$cluster" | yq '.metadata.namespace')" = backstage ]
  [ "$(object "$BUILT" Cluster "$cluster" | yq '.spec.instances')" -eq 3 ]
  [ "$(only "$BUILT" PodMonitor)" = backstage-db ]
  secret_key DB_HOST "$cluster-app" host
  secret_key DB_PORT "$cluster-app" port
  secret_key DB_NAME "$cluster-app" dbname
  secret_key DB_USER "$cluster-app" username
  secret_key DB_PASSWORD "$cluster-app" password
  app_config
  [ "$(yq '.backend.database.client' "$APP_CONFIG")" = pg ]
  # The user the operator makes may not create databases, so each plugin gets a schema of the one.
  [ "$(yq '.backend.database.pluginDivisionMode' "$APP_CONFIG")" = schema ]
  [ "$(yq '.backend.database.connection | [.host, .port, .database, .user, .password] | join(" ")' "$APP_CONFIG")" \
    = "\${DB_HOST} \${DB_PORT} \${DB_NAME} \${DB_USER} \${DB_PASSWORD}" ]
  # No credential in the tree: nothing built or rendered is a Secret, no variable whose name says it
  # holds one has a value of its own, and nothing the configuration holds looks like one.
  [ -z "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$BUILT" "$RENDERED")" ]
  [ -z "$(yq -N '.spec.template.spec.containers[]?.env[]? | select(.name | test("PASSWORD|KEY|SECRET|TOKEN|CREDENTIAL")) | select(has("value")) | .name' "$RENDERED")" ]
  [ -z "$(find "$REPO/kubernetes/apps/base/backstage" \( -name '*.enc.*' -o -name '*.sops.*' -o -name '*.age*' \))" ]
  [ -z "$(yq '.. | select(tag == "!!str") | select(test("(?i)(password|secret|token): *[^$ ]"))' "$APP_CONFIG")" ]
}

# route_admits METHOD TARGET: succeeds when the route in $BATS_TEST_TMPDIR/route.yaml sends the
# request to a backend, as Gateway API matches an HTTPRoute (gateway-api apis/v1/httproute_types.go):
# a rule without matches matches every request, and a match without a path is a prefix of "/"; a
# method matches exactly; an Exact path is the request's path, without its query, byte for byte; a
# PathPrefix matches the path whole or up to a "/", a trailing "/" of the prefix aside. Of the
# matches the request meets, an Exact path wins, then the longest prefix, then one with a method,
# then the earlier rule; the request is sent on when that match's rule has a backend. Exits 0 when it
# is sent on and 1 when not; a match of any other type or field exits otherwise, as one this test
# cannot evaluate.
route_admits() {
  yq -o json '.' "$BATS_TEST_TMPDIR/route.yaml" | jq -e --arg method "$1" --arg target "$2" '
    ($target | split("?")[0]) as $path
    | def path_of: .path // {"type": "PathPrefix", "value": "/"};
      def path_matches:
        path_of as $p
        | if $p.type == "Exact" then $path == $p.value
          elif $p.type == "PathPrefix" then ($p.value | sub("/+$"; "")) as $v | $v == "" or $path == $v or ($path | startswith($v + "/"))
          else error("a path match of type \($p.type), which this test does not evaluate") end;
      def request_matches:
        if (keys - ["method", "path"] | length) > 0 then error("a match by \(keys - ["method", "path"] | join(", ")), which this test does not evaluate")
        else ((.method // $method) == $method) and path_matches end;
    [ .spec.rules | to_entries[] | .key as $rule | ((.value.backendRefs // []) | length > 0) as $backend
      | (.value.matches // [{}])[] | select(request_matches)
      | {exact: (if path_of.type == "Exact" then 1 else 0 end), length: (path_of.value | length),
         method: (if .method then 1 else 0 end), rule: (0 - $rule), $backend} ]
    | if length == 0 then false else (sort_by(.exact, .length, .method, .rule) | last | .backend) end' >/dev/null
}

@test "Backstage is reached by its hostname on the public Gateway, and nothing but reading is possible without the cluster's sign-in" {
  local route service domain
  domain="$(yq -e '.CLUSTER_DOMAIN' "$EXAMPLE")"
  render
  route="$(only "$BUILT" HTTPRoute)"
  [ "$route" = backstage ]
  object "$BUILT" HTTPRoute "$route" >"$BATS_TEST_TMPDIR/route.yaml"
  [ "$(yq '.metadata.namespace' "$BATS_TEST_TMPDIR/route.yaml")" = backstage ]
  [ "$(yq '.spec.hostnames | join(",")' "$BATS_TEST_TMPDIR/route.yaml")" = "backstage.$domain" ]
  # On the public Gateway's https listener, and no other, for the whole of the host.
  [ "$(yq '.spec.parentRefs | length' "$BATS_TEST_TMPDIR/route.yaml")" -eq 1 ]
  [ "$(yq '.spec.parentRefs[0] | .name + "/" + .namespace + "/" + .sectionName' "$BATS_TEST_TMPDIR/route.yaml")" = public/envoy-gateway-system/https ]
  # Backed by the Service the chart makes, at the port Backstage listens on, by one rule that admits
  # by allowlist: GET and HEAD of any path, and POST of the one read the pages a reader opens need as
  # a POST. Any other request matches no rule, and the Gateway answers it itself, 404, without
  # reaching the pod (docs/kubernetes.md, Backstage). The matches are pinned, in full.
  [ "$(yq '.spec.rules | length' "$BATS_TEST_TMPDIR/route.yaml")" -eq 1 ]
  [ "$(yq '.spec.rules[0].filters // [] | length' "$BATS_TEST_TMPDIR/route.yaml")" -eq 0 ]
  [ "$(yq '.spec.rules[0].backendRefs | length' "$BATS_TEST_TMPDIR/route.yaml")" -eq 1 ]
  # The one backend in full, the Service and its port: no filter of its own, no weight, no other
  # kind or namespace.
  echo "backends: $(yq -o json -I0 '.spec.rules[0].backendRefs' "$BATS_TEST_TMPDIR/route.yaml")"
  [ "$(yq -o json -I0 '.spec.rules[0].backendRefs' "$BATS_TEST_TMPDIR/route.yaml")" = '[{"name":"backstage","port":7007}]' ]
  # Nothing else the application builds or its chart renders acts on the route's traffic: no object
  # of Envoy Gateway's API group, whose policies and filters would, and no object that names the
  # route as its target.
  local envoy attached
  envoy="$(yq -N 'select((.apiVersion // "") | test("^gateway[.]envoyproxy[.]io/")) | .kind + "/" + .metadata.name' "$BUILT" "$RENDERED")"
  echo "objects of gateway.envoyproxy.io: ${envoy:-none}"
  [ -z "$envoy" ]
  attached="$(yq -o json -I0 '.' "$BUILT" "$RENDERED" | jq -r --arg route "$route" '
    objects | select([.spec?.targetRef? // empty, (.spec?.targetRefs? // [])[]]
      | any(.name == $route and (.kind // "HTTPRoute") == "HTTPRoute"))
    | .kind + "/" + .metadata.name')"
  echo "objects that target the route: ${attached:-none}"
  [ -z "$attached" ]
  [ "$(yq '.spec.rules[0].matches[] | (.method // "any") + " " + (.path.type // "none") + " " + (.path.value // "none") + " " + ((keys - ["method", "path"]) | join(","))' "$BATS_TEST_TMPDIR/route.yaml" | paste -sd, -)" \
    = "GET PathPrefix / ,HEAD PathPrefix / ,POST Exact /api/catalog/entities/by-refs " ]
  # What reaches the pod, by Gateway API's matching of the rendered rules: a request is sent on when
  # its method and its path, without the query, meet a match of a rule with a backend; a path match
  # is exact, or by whole segments for a prefix, and both are case-sensitive. A request whose path
  # differs from a listed one in letter case or by a trailing slash meets no match.
  local request method target
  local admitted=(
    "GET /"
    "GET /catalog/default/component/n8n"
    "GET /api/auth/guest/refresh"
    "GET /api/catalog/entities/by-query?filter=kind=component"
    "GET /api/catalog/entities/by-name/component/default/n8n"
    "GET /api/search/query?term=gateway"
    "GET /.backstage/health/v1/readiness"
    "HEAD /"
    "POST /api/catalog/entities/by-refs"
    "POST /api/catalog/entities/by-refs?fields=metadata.name"
  )
  local refused=(
    "POST /api/catalog/locations"
    "POST /api/catalog/locations?dryRun=true"
    "POST /api/catalog/Locations?dryRun=true"
    "POST /API/CATALOG/LOCATIONS?dryRun=true"
    "PUT /api/catalog/locations/0"
    "DELETE /api/catalog/locations/0"
    "DELETE /api/catalog/entities/by-uid/0"
    "DELETE /api/catalog/Entities/by-uid/0"
    "POST /api/catalog/refresh"
    "POST /api/catalog/analyze-location"
    "POST /api/catalog/analyze-location/"
    "POST /api/catalog/validate-entity"
    "POST /api/catalog/.backstage/actions/v1/actions/catalog:validate-entity/invoke"
    "POST /api/mcp-actions/v1"
    "POST /api/scaffolder/v2/dry-run"
    "POST /api/scaffolder/v2/tasks"
    "POST /api/scaffolder/v2/autocomplete/github/owners"
    "POST /api/search/.backstage/scheduler/v1/tasks/search_index/trigger"
    "POST /api/catalog/entities/by-query"
    "POST /api/catalog/entity-facets"
    "POST /api/catalog/locations/by-query"
    "POST /api/permission/authorize"
    "POST /api/user-settings/multiget"
    "PUT /api/user-settings/buckets/default.starredEntities/keys/entityRefs"
    "DELETE /api/user-settings/buckets/default.starredEntities/keys/entityRefs"
    "POST /api/notifications/update"
    "POST /api/auth/guest/refresh"
    "POST /api/auth/v1/token"
    "POST /api/catalog/entities/by-refs/"
    "POST /api/catalog/Entities/by-refs"
    "POST /API/CATALOG/ENTITIES/BY-REFS"
    "POST /api/catalog/entities/by-refsx"
    "POST /api/catalog/entities/by-refs/x"
    "POST /api/catalog/entities"
    "PUT /api/catalog/entities/by-refs"
    "PATCH /api/catalog/entities/by-refs"
    "DELETE /api/catalog/entities/by-refs"
    "POST /"
    "OPTIONS /"
    "TRACE /"
  )
  for request in "${admitted[@]}"; do
    read -r method target <<<"$request"
    run route_admits "$method" "$target"
    [ "$status" -eq 0 ] || { echo "the route does not send $request to Backstage: $output"; return 1; }
  done
  for request in "${refused[@]}"; do
    read -r method target <<<"$request"
    run route_admits "$method" "$target"
    [ "$status" -eq 1 ] || { echo "the route sends $request to Backstage: $output"; return 1; }
  done
  service="$(yq '.spec.rules[0].backendRefs[0].name' "$BATS_TEST_TMPDIR/route.yaml")"
  [ "$(only "$RENDERED" Service)" = "$service" ]
  [ "$(object "$RENDERED" Service "$service" | yq '.spec.ports[0].port')" = "$(yq '.spec.rules[0].backendRefs[0].port' "$BATS_TEST_TMPDIR/route.yaml")" ]
  container
  app_config
  [ "$(yq '.backend.listen.port' "$APP_CONFIG")" = "$(yq '.spec.rules[0].backendRefs[0].port' "$BATS_TEST_TMPDIR/route.yaml")" ]
  # Backstage's own base URLs are that name over https, from the variable.
  [ "$(env_value APP_CONFIG_app_baseUrl)" = "https://backstage.$domain" ]
  [ "$(env_value APP_CONFIG_backend_baseUrl)" = "https://backstage.$domain" ]
  other_vars
  VARS="$OTHER" render
  container
  domain="$(yq -e '.CLUSTER_DOMAIN' "$OTHER")"
  [ "$(object "$BUILT" HTTPRoute backstage | yq '.spec.hostnames | join(",")')" = "backstage.$domain" ]
  [ "$(env_value APP_CONFIG_app_baseUrl)" = "https://backstage.$domain" ]
  [ "$(env_value APP_CONFIG_backend_baseUrl)" = "https://backstage.$domain" ]
  # The namespace lets its routes attach to that listener.
  overlay
  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "backstage") | .metadata.labels["k8s-gitops/gateway"]' "$OVERLAY")" = public ]
  # What a visitor can do. The catalogue is files, so the backend refuses to register, unregister or
  # change a location; the guest provider is the only sign-in the image's frontend offers, and the
  # backend allows it outside development, which is what lets anyone who reaches the route in; and
  # the default policy, which refuses every request without credentials, stays on.
  app_config
  [ "$(yq '.catalog.readonly' "$APP_CONFIG")" = true ]
  [ "$(yq '.auth.providers | keys | join(",")' "$APP_CONFIG")" = guest ]
  [ "$(yq '.auth.providers.guest.dangerouslyAllowOutsideDevelopment' "$APP_CONFIG")" = true ]
  [ "$(yq '.backend.auth.dangerouslyDisableDefaultAuthPolicy // "absent"' "$APP_CONFIG")" = absent ]
  [ "$(yq '.backend.auth.externalAccess // "absent"' "$APP_CONFIG")" = absent ]
  [ "$(yq '.backend.auth.keys // "absent"' "$APP_CONFIG")" = absent ]
  # Nothing in the environment gives a request more than that.
  [ -z "$(yq -N '.spec.template.spec.containers[].env[] | select(.name | test("^APP_CONFIG_(auth|backend_auth|catalog|permission)")) | .name' "$RENDERED")" ]
}
