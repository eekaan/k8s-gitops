#!/usr/bin/env bats
# Proves features/applications.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq and jq on PATH (the versions pinned for the repository). The
# app-template chart is pulled once per run from its public registry; building and rendering are
# offline, with the placeholders of the cluster's example key lists.

# flux build rewrites the kustomization.yaml of what it builds and puts it back afterwards, and the
# chart is pulled once: so the tests run one at a time.
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
  kustomize build --load-restrictor LoadRestrictionsNone "$OVERLAY_DIR" >"$OVERLAY"
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

# other_vars: writes a copy of the example values with another domain and sets OTHER to it, so a
# test can build again and see that what it read came from the variable, not from a literal that
# happens to equal the example.
other_vars() {
  OTHER="$BATS_TEST_TMPDIR/other-vars.yaml"
  CLUSTER_DOMAIN=other.example.org yq '.CLUSTER_DOMAIN = strenv(CLUSTER_DOMAIN)' "$EXAMPLE" >"$OTHER"
}

# render: renders the chart that n8n's HelmRelease installs, from the URL and tag of its
# OCIRepository, with the values helm-controller gives it: those of each ConfigMap the HelmRelease
# reads, in order, then the HelmRelease's own over them, as scripts/render does: a ConfigMap is one
# the application builds. Builds n8n, writes $BATS_TEST_TMPDIR/n8n.yaml and sets BUILT, RENDERED and
# INLINE.
render() {
  local url tag release namespace pulled name i values=() count
  built n8n
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
  RENDERED="$BATS_TEST_TMPDIR/n8n.yaml"
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

# container: writes the Deployment that RENDERED holds to $DEPLOYMENT, its container main, n8n, to
# $CONTAINER, and its container runners, the task runners, to $RUNNER, which is empty when the pod
# has none.
container() {
  DEPLOYMENT="$BATS_TEST_TMPDIR/deployment.yaml"
  CONTAINER="$BATS_TEST_TMPDIR/container.yaml"
  RUNNER="$BATS_TEST_TMPDIR/runner.yaml"
  object "$RENDERED" Deployment "$(only "$RENDERED" Deployment)" >"$DEPLOYMENT"
  yq '.spec.template.spec.containers[] | select(.name == "main")' "$DEPLOYMENT" >"$CONTAINER"
  [ -s "$CONTAINER" ] || { echo "the pod has no container main"; return 1; }
  yq '.spec.template.spec.containers[] | select(.name == "runners")' "$DEPLOYMENT" >"$RUNNER"
}

# env_of NAME [FILE]: the entry called NAME of the environment of the container in FILE, n8n's by
# default, as compact JSON; empty when none.
env_of() {
  NAME="$1" yq -o json -I0 '.env[] | select(.name == strenv(NAME))' "${2:-$CONTAINER}"
}

# env_value NAME [FILE]: the literal value of the variable NAME of the container in FILE, n8n's by
# default; fails when it has none.
env_value() {
  NAME="$1" yq -e '.env[] | select(.name == strenv(NAME)) | .value' "${2:-$CONTAINER}"
}

# secret_key NAME SECRET KEY [FILE]: succeeds when the variable NAME of the container in FILE, n8n's
# by default, is read from the key KEY of the Secret SECRET.
secret_key() {
  [ "$(env_of "$1" "${4:-$CONTAINER}" | jq -cS .)" = "$(SECRET="$2" KEY="$3" NAME="$1" yq -o json -I0 -n \
    '{"name": strenv(NAME), "valueFrom": {"secretKeyRef": {"name": strenv(SECRET), "key": strenv(KEY)}}}' | jq -cS .)" ]
}

# mounts FILE: every volume mount of the container in FILE, one per line and sorted: its path, the
# kind of volume, emptyDir or the claim and its name, and the claim's directory it mounts, if any.
mounts() {
  yq -o json '.spec.template.spec.volumes // []' "$DEPLOYMENT" >"$BATS_TEST_TMPDIR/volumes.json"
  yq -o json '.volumeMounts // []' "$1" | jq -r --slurpfile volumes "$BATS_TEST_TMPDIR/volumes.json" '
    .[] | . as $m | (first($volumes[0][] | select(.name == $m.name)) // {}) as $v
    | [$m.mountPath,
       (if $v.emptyDir then "emptyDir"
        elif $v.persistentVolumeClaim then "claim " + $v.persistentVolumeClaim.claimName
        else "other" end)]
      + (if $m.subPath then [$m.subPath] else [] end)
      + (if $m.readOnly then ["read-only"] else [] end)
    | join(" ")' | LC_ALL=C sort
}

# volume_at FILE PATH: the name of the volume the container in FILE mounts at PATH.
volume_at() {
  MOUNT="$2" yq '.volumeMounts[] | select(.mountPath == strenv(MOUNT)) | .name' "$1"
}

# image_version FILE: the version of the tag of the container in FILE's image.
image_version() {
  yq '.image' "$1" | sed -E 's/@sha256:[0-9a-f]{64}$//; s/^.*://'
}

@test "n8n's database is a PostgreSQL cluster from the template, and no credential is in the tree" {
  local cluster
  render
  # The Kustomization takes the component and names the cluster.
  [ "$(yq '.spec.components | map(select(test("/components/cnpg-cluster$"))) | length' "$KS")" -eq 1 ]
  [ "$(yq '.spec.postBuild.substitute.CNPG_CLUSTER_NAME' "$KS")" = n8n-db ]
  # What it yields: one Cluster of three instances, and the PodMonitor that scrapes it.
  cluster="$(only "$BUILT" Cluster)"
  [ "$cluster" = n8n-db ]
  [ "$(object "$BUILT" Cluster "$cluster" | yq '.metadata.namespace')" = ai-system ]
  [ "$(object "$BUILT" Cluster "$cluster" | yq '.spec.instances')" -eq 3 ]
  [ "$(only "$BUILT" PodMonitor)" = n8n-db ]
  # n8n reads its connection from the keys of the Secret the operator makes for the cluster.
  container
  [ "$(env_value DB_TYPE)" = postgresdb ]
  secret_key DB_POSTGRESDB_HOST "$cluster-app" host
  secret_key DB_POSTGRESDB_PORT "$cluster-app" port
  secret_key DB_POSTGRESDB_DATABASE "$cluster-app" dbname
  secret_key DB_POSTGRESDB_USER "$cluster-app" username
  secret_key DB_POSTGRESDB_PASSWORD "$cluster-app" password
  # No credential in the tree: nothing built or rendered is a Secret, and no variable whose name
  # says it holds a password, key, secret or token has a value of its own.
  [ -z "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$BUILT" "$RENDERED")" ]
  [ -z "$(yq -N '.spec.template.spec.containers[]?.env[]? | select(.name | test("PASSWORD|KEY|SECRET|TOKEN|CREDENTIAL")) | select(has("value")) | .name' "$RENDERED")" ]
  [ -z "$(yq -N '.spec.template.spec.initContainers[].env[]? | select(.name | test("PASSWORD|KEY|SECRET|TOKEN|CREDENTIAL")) | select(has("value")) | .name' "$RENDERED")" ]
  # No encrypted file stands in for one, either.
  [ -z "$(find "$REPO/kubernetes/apps/base/ai-system" \( -name '*.enc.*' -o -name '*.sops.*' -o -name '*.age*' \))" ]
}

@test "n8n's encryption key comes from the secret store" {
  local es secret key
  render
  # n8n reads the variable from a key of a Secret, and nothing gives it a value.
  container
  secret="$(env_of N8N_ENCRYPTION_KEY | jq -r '.valueFrom.secretKeyRef.name // empty')"
  key="$(env_of N8N_ENCRYPTION_KEY | jq -r '.valueFrom.secretKeyRef.key // empty')"
  [ -n "$secret" ] && [ -n "$key" ] || { echo "N8N_ENCRYPTION_KEY is not read from a Secret: $(env_of N8N_ENCRYPTION_KEY)"; return 1; }
  secret_key N8N_ENCRYPTION_KEY "$secret" "$key"
  # One ExternalSecret writes that Secret, and it reads the key from the store at the namespace's
  # path, where `just bao-put ai-system/n8n encryption-key` writes it.
  es="$(SECRET="$secret" yq -N 'select(.kind == "ExternalSecret" and .spec.target.name == strenv(SECRET)) | .metadata.name' "$BUILT")"
  [ "$es" = n8n-encryption-key ]
  object "$BUILT" ExternalSecret "$es" >"$BATS_TEST_TMPDIR/es.yaml"
  [ "$(yq '.spec.secretStoreRef.kind + "/" + .spec.secretStoreRef.name' "$BATS_TEST_TMPDIR/es.yaml")" = ClusterSecretStore/openbao ]
  [ "$(yq -o json -I0 '.spec.data' "$BATS_TEST_TMPDIR/es.yaml" | jq -cS .)" = \
    "$(KEY="$key" jq -cnS '[{secretKey: env.KEY, remoteRef: {key: "ai-system/n8n", property: "encryption-key"}}]')" ]
  # No generator makes it: the ExternalSecret has no generated data, and the one generator the
  # application builds feeds another Secret, the task runners' token.
  [ "$(yq '.spec.dataFrom // [] | length' "$BATS_TEST_TMPDIR/es.yaml")" -eq 0 ]
  [ "$(yq -N 'select(.apiVersion | test("^generators\.external-secrets\.io/")) | .kind + "/" + .metadata.name' "$BUILT")" = Password/n8n-runners ]
  [ "$(yq -N 'select(.kind == "ExternalSecret" and .spec.dataFrom[]?.sourceRef.generatorRef.name == "n8n-runners") | .spec.target.name' "$BUILT")" = n8n-runners ]
  # The application waits for the store's application, which is Ready once the store is.
  [ "$(yq '.spec.dependsOn[] | select(.name == "openbao-store") | .name' "$KS")" = openbao-store ]
}

@test "n8n's data is on a volume that is backed up and restored on create" {
  local claim source destination
  render
  # The Kustomization takes the volsync component for the application of its own name.
  [ "$(yq '.spec.components | map(select(test("/components/volsync$"))) | length' "$KS")" -eq 1 ]
  [ "$(yq '.spec.postBuild.substitute.APP' "$KS")" = n8n ]
  claim="$(only "$BUILT" PersistentVolumeClaim)"
  [ "$claim" = n8n ]
  # The claim is filled from the restore on create, and the restore is of the application's repository.
  [ "$(object "$BUILT" PersistentVolumeClaim "$claim" | yq '.spec.dataSourceRef.kind')" = ReplicationDestination ]
  destination="$(object "$BUILT" PersistentVolumeClaim "$claim" | yq '.spec.dataSourceRef.name')"
  [ "$(only "$BUILT" ReplicationDestination)" = "$destination" ]
  [ "$(object "$BUILT" ReplicationDestination "$destination" | yq '.spec.trigger.manual')" = restore-once ]
  # Backed up every night, with the component's retention.
  source="$(only "$BUILT" ReplicationSource)"
  [ "$(object "$BUILT" ReplicationSource "$source" | yq '.spec.sourcePVC')" = "$claim" ]
  [[ $(object "$BUILT" ReplicationSource "$source" | yq '.spec.trigger.schedule') =~ ^[0-9]+\ [0-9]+\ \*\ \*\ \*$ ]]
  [ "$(object "$BUILT" ReplicationSource "$source" | yq -o json -I0 '.spec.restic.retain' | jq -cS .)" = '{"daily":7,"monthly":3,"weekly":4}' ]
  [ "$(object "$BUILT" ExternalSecret n8n-volsync | yq '.spec.secretStoreRef.name')" = openbao ]
  # n8n's directory is that claim, and the directory its workflows keep files in is the claim's
  # directory files; and the one replica lets go of it before its successor starts.
  container
  [ "$(yq '.spec.template.spec.volumes[] | select(.persistentVolumeClaim.claimName == "'"$claim"'") | .name' "$DEPLOYMENT")" = data ]
  [ "$(mounts "$CONTAINER" | grep " claim $claim" | paste -sd, -)" = "/home/node/.n8n claim $claim,/home/node/.n8n-files claim $claim files" ]
  [ "$(env_value N8N_RESTRICT_FILE_ACCESS_TO)" = /home/node/.n8n-files ]
  [ "$(yq '.spec.replicas' "$DEPLOYMENT")" -eq 1 ]
  [ "$(yq '.spec.strategy.type' "$DEPLOYMENT")" = Recreate ]
}

@test "n8n has a public hostname under the cluster's domain, and its own settings agree with it" {
  local route service domain
  domain="$(yq -e '.CLUSTER_DOMAIN' "$EXAMPLE")"
  render
  route="$(only "$BUILT" HTTPRoute)"
  [ "$route" = n8n ]
  object "$BUILT" HTTPRoute "$route" >"$BATS_TEST_TMPDIR/route.yaml"
  [ "$(yq '.metadata.namespace' "$BATS_TEST_TMPDIR/route.yaml")" = ai-system ]
  [ "$(yq '.spec.hostnames | join(",")' "$BATS_TEST_TMPDIR/route.yaml")" = "n8n.$domain" ]
  # On the public Gateway's https listener, and no other.
  [ "$(yq '.spec.parentRefs | length' "$BATS_TEST_TMPDIR/route.yaml")" -eq 1 ]
  [ "$(yq '.spec.parentRefs[0] | .name + "/" + .namespace + "/" + .sectionName' "$BATS_TEST_TMPDIR/route.yaml")" = public/envoy-gateway-system/https ]
  # Backed by the Service n8n's chart makes, at the port it serves on.
  service="$(yq '.spec.rules[0].backendRefs[0].name' "$BATS_TEST_TMPDIR/route.yaml")"
  [ "$(yq '.spec.rules | length' "$BATS_TEST_TMPDIR/route.yaml")" -eq 1 ]
  [ "$(only "$RENDERED" Service)" = "$service" ]
  [ "$(object "$RENDERED" Service "$service" | yq '.spec.ports[0].port')" = "$(yq '.spec.rules[0].backendRefs[0].port' "$BATS_TEST_TMPDIR/route.yaml")" ]
  container
  [ "$(env_value N8N_PORT)" = "$(yq '.spec.rules[0].backendRefs[0].port' "$BATS_TEST_TMPDIR/route.yaml")" ]
  # n8n's own settings are that name, reached over https through one proxy.
  [ "$(env_value N8N_HOST)" = "n8n.$domain" ]
  [ "$(env_value N8N_PROTOCOL)" = https ]
  [ "$(env_value N8N_WEBHOOK_URL)" = "https://n8n.$domain/" ]
  [ "$(env_value N8N_EDITOR_BASE_URL)" = "https://n8n.$domain" ]
  [ "$(env_value N8N_PROXY_HOPS)" = 1 ]
  # Not the name n8n deprecates, which it warns about at every start.
  [ -z "$(env_of WEBHOOK_URL)" ]
  # They follow the variable: built with another domain, each follows it.
  other_vars
  VARS="$OTHER" render
  container
  domain="$(yq -e '.CLUSTER_DOMAIN' "$OTHER")"
  [ "$(only "$BUILT" HTTPRoute)" = n8n ]
  [ "$(object "$BUILT" HTTPRoute n8n | yq '.spec.hostnames | join(",")')" = "n8n.$domain" ]
  [ "$(env_value N8N_HOST)" = "n8n.$domain" ]
  [ "$(env_value N8N_WEBHOOK_URL)" = "https://n8n.$domain/" ]
  [ "$(env_value N8N_EDITOR_BASE_URL)" = "https://n8n.$domain" ]
  # The namespace lets its routes attach to that listener.
  overlay
  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "ai-system") | .metadata.labels["k8s-gitops/gateway"]' "$OVERLAY")" = public ]
}

@test "n8n's pods meet the restricted Pod Security level and do not phone home" {
  local name file
  render
  container
  overlay
  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "ai-system") | .metadata.labels["pod-security.kubernetes.io/enforce"]' "$OVERLAY")" = restricted ]
  # The pod: a non-root user, the runtime's seccomp profile, no host namespace, and two containers,
  # n8n and its task runners.
  [ "$(yq '.spec.template.spec.securityContext.runAsNonRoot' "$DEPLOYMENT")" = true ]
  [ "$(yq '.spec.template.spec.securityContext.runAsUser' "$DEPLOYMENT")" -gt 0 ]
  [ "$(yq '.spec.template.spec.securityContext.seccompProfile.type' "$DEPLOYMENT")" = RuntimeDefault ]
  [ "$(yq '[.spec.template.spec.hostNetwork, .spec.template.spec.hostPID, .spec.template.spec.hostIPC] | map(. // false) | join(",")' "$DEPLOYMENT")" = false,false,false ]
  [ "$(yq '[.spec.template.spec.containers[].name] | sort | join(",")' "$DEPLOYMENT")" = main,runners ]
  [ "$(yq '.spec.template.spec.initContainers // [] | length' "$DEPLOYMENT")" -eq 0 ]
  # Each container: no escalation, no capability, a root filesystem it cannot write, an image of a
  # tag and a digest, requests and a memory limit.
  for file in "$CONTAINER" "$RUNNER"; do
    name="$(yq '.name' "$file")"
    [ "$(yq '.securityContext.allowPrivilegeEscalation' "$file")" = false ] || { echo "$name escalates"; return 1; }
    [ "$(yq '.securityContext.readOnlyRootFilesystem' "$file")" = true ] || { echo "$name writes its root filesystem"; return 1; }
    [ "$(yq '.securityContext.capabilities.drop | join(",")' "$file")" = ALL ] || { echo "$name keeps capabilities"; return 1; }
    [ "$(yq '.securityContext.capabilities.add // [] | length' "$file")" -eq 0 ]
    [ "$(yq '.securityContext.privileged // false' "$file")" = false ]
    [[ $(yq '.image' "$file") =~ ^[a-z0-9./-]+:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]] || { echo "$name: $(yq '.image' "$file")"; return 1; }
    [ "$(yq '.resources.requests.cpu' "$file")" != null ]
    [ "$(yq '.resources.requests.memory' "$file")" != null ]
    [ "$(yq '.resources.limits.memory' "$file")" != null ] || { echo "$name has no memory limit"; return 1; }
  done
  # Where each writes, and nowhere else: n8n to the claim, for its own directory and the files its
  # workflows keep, to its static cache, which it writes at every start, and to /tmp; the runners
  # to a /tmp of their own, where Python's code runner keeps its socket, apart from n8n's.
  echo "n8n mounts: $(mounts "$CONTAINER" | paste -sd, -)"
  echo "runners mount: $(mounts "$RUNNER" | paste -sd, -)"
  [ "$(mounts "$CONTAINER" | paste -sd, -)" = "/home/node/.cache emptyDir,/home/node/.n8n claim n8n,/home/node/.n8n-files claim n8n files,/tmp emptyDir" ]
  [ "$(mounts "$RUNNER" | paste -sd, -)" = "/tmp emptyDir" ]
  [ "$(volume_at "$RUNNER" /tmp)" != "$(volume_at "$CONTAINER" /tmp)" ]
  # Health, on n8n's own endpoints and the runners' launcher's.
  [ "$(yq '.livenessProbe.httpGet.path' "$CONTAINER")" = /healthz ]
  [ "$(yq '.readinessProbe.httpGet.path' "$CONTAINER")" = /healthz/readiness ]
  [ "$(yq '.startupProbe.httpGet.path' "$CONTAINER")" = /healthz ]
  [ "$(yq '.livenessProbe.httpGet.path + " " + (.livenessProbe.httpGet.port | tostring)' "$RUNNER")" = "/healthz 5680" ]
  # Nothing it calls n8n's services for: telemetry, version checks, templates, the dynamic banners,
  # community packages and the list of verified ones, and the MCP server registry, which n8n
  # refreshes from n8n's API at start and every eight hours; nor the public API and the banner.
  for name in N8N_DIAGNOSTICS_ENABLED N8N_VERSION_NOTIFICATIONS_ENABLED N8N_TEMPLATES_ENABLED \
    N8N_DYNAMIC_BANNERS_ENABLED N8N_COMMUNITY_PACKAGES_ENABLED N8N_VERIFIED_PACKAGES_ENABLED \
    N8N_HIRING_BANNER_ENABLED N8N_PERSONALIZATION_ENABLED; do
    [ "$(env_value "$name")" = false ] || { echo "$name is not false"; return 1; }
  done
  [ "$(env_value N8N_DISABLED_MODULES)" = mcp-registry ]
  [ "$(env_value N8N_PUBLIC_API_DISABLED)" = true ]
}

# tree_without ENTRY...: copies kubernetes/ to $TREE and takes each ENTRY out of the overlay's
# resources: an application's name, for its ks.yaml, or a namespace directory's path under
# apps/base/, such as ai-system, for the directory.
tree_without() {
  local entry
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  mkdir -p "$TREE"
  cp -r "$REPO/kubernetes" "$TREE/kubernetes"
  for entry in "$@"; do
    ENTRY="$entry" yq -i '.resources |= map(select((test("/" + strenv(ENTRY) + "/ks.yaml$") or . == "../../base/" + strenv(ENTRY)) | not))' \
      "$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  done
}

# of_ai_system FILE: what an overlay built into FILE holds of ai-system, sorted, as kind, namespace
# and name: the namespace itself, any object in it, and any Kustomization that deploys into it or
# from its directory.
of_ai_system() {
  yq -N 'select((.kind == "Namespace" and .metadata.name == "ai-system") or .metadata.namespace == "ai-system"
      or .spec.targetNamespace == "ai-system" or ((.spec.path // "") | test("/apps/base/ai-system/")))
    | .kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$1" | LC_ALL=C sort | paste -sd, -
}

@test "A cluster that does not select n8n builds none of it, and one that selects it without what it depends on is refused" {
  local dependency dependencies=(cloudnative-pg prometheus-operator-crds external-secrets openbao-store volsync linstor-cluster gateway-public)
  # The overlay selects it with two entries, its namespace directory and its ks.yaml, and builds
  # the namespace, the defaults every namespace directory holds, and the Kustomization.
  # Open WebUI's ks.yaml is a third entry, selected by it alone.
  [ "$(yq '.resources[] | select(test("/ai-system(/|$)"))' "$OVERLAY_DIR/kustomization.yaml" | paste -sd, -)" = ../../base/ai-system,../../base/ai-system/n8n/ks.yaml,../../base/ai-system/open-webui/ks.yaml ]
  overlay
  [ "$(of_ai_system "$OVERLAY")" = ConfigMap/ai-system/app-template-defaults,Kustomization/flux-system/n8n,Kustomization/flux-system/open-webui,Namespace/-/ai-system ]
  # Its Kustomization names what it needs, no more and no less.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "n8n") | .spec.dependsOn | map(.name) | sort | join(" ")' "$OVERLAY")" \
    = "$(printf '%s\n' "${dependencies[@]}" | sort | paste -sd' ' -)" ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "n8n") | .spec.wait' "$OVERLAY")" = true ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # With only the namespace directory's entry, the cluster builds the namespace and its defaults,
  # and nothing else of ai-system.
  tree_without n8n open-webui
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2" >"$BATS_TEST_TMPDIR/namespace-only.yaml"
  [ "$(of_ai_system "$BATS_TEST_TMPDIR/namespace-only.yaml")" = ConfigMap/ai-system/app-template-defaults,Namespace/-/ai-system ]
  # With neither, nothing of ai-system.
  tree_without n8n open-webui ai-system
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2" >"$BATS_TEST_TMPDIR/neither.yaml"
  [ -z "$(of_ai_system "$BATS_TEST_TMPDIR/neither.yaml")" ]
  # Selecting it without one of the applications it needs is refused, naming both.
  for dependency in "${dependencies[@]}"; do
    tree_without "$dependency"
    run "$REPO/scripts/kubernetes-check" "$TREE"
    echo "without $dependency: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"kubernetes/apps/base/ai-system/n8n/ks.yaml: Kustomization n8n names $dependency"* ]]
    [[ $output == *"does not enable"* ]]
  done
}

@test "n8n runs its code nodes in a task runner of its own version beside it" {
  local secret key es
  render
  container
  [ -s "$RUNNER" ] || { echo "the pod has no container runners"; return 1; }
  # n8n hands code to an external runner, through its broker on the pod's loopback.
  [ "$(env_value N8N_RUNNERS_MODE)" = external ]
  [ "$(env_value N8N_RUNNERS_BROKER_LISTEN_ADDRESS)" = 127.0.0.1 ]
  [ "$(env_value N8N_RUNNERS_BROKER_PORT)" = 5679 ]
  # The runners are n8n's runners image, of n8n's own version, pinned by digest, and reach the
  # broker there.
  [[ $(yq '.image' "$RUNNER") =~ ^docker\.io/n8nio/runners:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]
  [[ $(yq '.image' "$CONTAINER") =~ ^docker\.io/n8nio/n8n:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]
  echo "n8n $(image_version "$CONTAINER"), runners $(image_version "$RUNNER")"
  [ "$(image_version "$RUNNER")" = "$(image_version "$CONTAINER")" ]
  [ "$(env_value N8N_RUNNERS_TASK_BROKER_URI "$RUNNER")" = "http://127.0.0.1:$(env_value N8N_RUNNERS_BROKER_PORT)" ]
  # Both read the same token from a Secret that External Secrets fills once from a generator, so
  # the token does not change under a running pod.
  secret="$(env_of N8N_RUNNERS_AUTH_TOKEN | jq -r '.valueFrom.secretKeyRef.name // empty')"
  key="$(env_of N8N_RUNNERS_AUTH_TOKEN | jq -r '.valueFrom.secretKeyRef.key // empty')"
  [ -n "$secret" ] && [ -n "$key" ] || { echo "N8N_RUNNERS_AUTH_TOKEN is not read from a Secret: $(env_of N8N_RUNNERS_AUTH_TOKEN)"; return 1; }
  secret_key N8N_RUNNERS_AUTH_TOKEN "$secret" "$key"
  secret_key N8N_RUNNERS_AUTH_TOKEN "$secret" "$key" "$RUNNER"
  es="$(SECRET="$secret" yq -N 'select(.kind == "ExternalSecret" and .spec.target.name == strenv(SECRET)) | .metadata.name' "$BUILT")"
  [ "$es" = n8n-runners ]
  object "$BUILT" ExternalSecret "$es" >"$BATS_TEST_TMPDIR/es.yaml"
  [ "$(yq '.spec.refreshPolicy' "$BATS_TEST_TMPDIR/es.yaml")" = CreatedOnce ]
  [ "$(yq '.spec.dataFrom | length' "$BATS_TEST_TMPDIR/es.yaml")" -eq 1 ]
  [ "$(yq '.spec.dataFrom[0].sourceRef.generatorRef.kind' "$BATS_TEST_TMPDIR/es.yaml")" = Password ]
  object "$BUILT" Password "$(yq '.spec.dataFrom[0].sourceRef.generatorRef.name' "$BATS_TEST_TMPDIR/es.yaml")" >"$BATS_TEST_TMPDIR/generator.yaml"
  [ "$(yq '.spec.secretKeys | join(",")' "$BATS_TEST_TMPDIR/generator.yaml")" = "$key" ]
  [ "$(yq '.spec.length' "$BATS_TEST_TMPDIR/generator.yaml")" -ge 32 ]
  # The broker is reached only inside the pod: the Service has n8n's port alone.
  [ "$(only "$RENDERED" Service)" = n8n ]
  [ "$(object "$RENDERED" Service n8n | yq '[.spec.ports[].port] | join(",")')" = 5678 ]
}

# render_app APP: renders the chart that APP's HelmRelease installs, as render does for n8n: from the
# URL and tag of its OCIRepository, with the values of each ConfigMap the HelmRelease reads and its
# own over them. Builds APP, writes $BATS_TEST_TMPDIR/APP.yaml and sets BUILT, KS, RENDERED and
# INLINE.
render_app() {
  local app=$1 url tag release namespace pulled name i values=() count
  built "$app"
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
  RENDERED="$BATS_TEST_TMPDIR/$app.yaml"
  helm template "$release" "$pulled"/*.tgz --namespace "$namespace" --kube-version "$KUBE" \
    "${values[@]/#/--values=}" --values "$INLINE" >"$RENDERED"
}

# The variables that keep Open WebUI from calling anyone before a person configures a connection,
# with the state each has; docs/kubernetes.md has a row for each.
OPEN_WEBUI_OFF="ENABLE_OLLAMA_API=false ENABLE_OPENAI_API=false ENABLE_VERSION_UPDATE_CHECK=false
  ENABLE_COMMUNITY_SHARING=false ANONYMIZED_TELEMETRY=false SCARF_NO_ANALYTICS=true
  OFFLINE_MODE=true DO_NOT_TRACK=true ENABLE_CODE_EXECUTION=false ENABLE_CODE_INTERPRETER=false
  BYPASS_EMBEDDING_AND_RETRIEVAL=true"

# The other variables the container sets, none of which makes Open WebUI call anyone: where it
# listens, where it writes, how it is reached, and who may register.
OPEN_WEBUI_REVIEWED="PORT HOME DATA_DIR WEBUI_SECRET_KEY_FILE WEBUI_AUTH_COOKIE_SECURE WEBUI_URL
  CORS_ALLOW_ORIGIN ENABLE_SIGNUP DEFAULT_USER_ROLE OLLAMA_BASE_URL"

@test "Open WebUI is selected by one overlay entry and builds nothing when it is not" {
  local dependency dependencies=(external-secrets gateway-public linstor-cluster openbao-store volsync)
  # The namespace directory is the one n8n's entry selects; Open WebUI adds its ks.yaml alone.
  [ "$(yq '.resources[] | select(test("/ai-system/open-webui/ks.yaml$"))' "$OVERLAY_DIR/kustomization.yaml" | paste -sd, -)" = ../../base/ai-system/open-webui/ks.yaml ]
  overlay
  of_ai_system "$OVERLAY" | tr , '\n' | grep -qx 'Kustomization/flux-system/open-webui'
  # Its Kustomization names what it needs, no more and no less, and waits for its release.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "open-webui") | .spec.dependsOn | map(.name) | sort | join(" ")' "$OVERLAY")" \
    = "$(printf '%s\n' "${dependencies[@]}" | sort | paste -sd' ' -)" ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "open-webui") | .spec.wait' "$OVERLAY")" = true ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # Without the entry, nothing of Open WebUI: n8n's, the namespace and its defaults remain.
  tree_without open-webui
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2" >"$BATS_TEST_TMPDIR/without.yaml"
  [ "$(of_ai_system "$BATS_TEST_TMPDIR/without.yaml")" = ConfigMap/ai-system/app-template-defaults,Kustomization/flux-system/n8n,Namespace/-/ai-system ]
  [ "$(grep -c open-webui "$BATS_TEST_TMPDIR/without.yaml")" -eq 0 ]
  # Selecting it without one of the applications it needs is refused, naming both.
  for dependency in "${dependencies[@]}"; do
    tree_without "$dependency"
    run "$REPO/scripts/kubernetes-check" "$TREE"
    echo "without $dependency: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"kubernetes/apps/base/ai-system/open-webui/ks.yaml: Kustomization open-webui names $dependency"* ]]
    [[ $output == *"does not enable"* ]]
  done
}

@test "Open WebUI starts with no secret seeded and no model backend" {
  local name data
  render_app open-webui
  container
  # No PostgreSQL: the database is SQLite's file on the volume, which Open WebUI makes itself.
  [ "$(yq '.spec.components | map(select(test("/components/cnpg-cluster$"))) | length' "$KS")" -eq 0 ]
  [ -z "$(yq -N 'select(.kind == "Cluster") | .metadata.name' "$BUILT")" ]
  [ -z "$(env_of DATABASE_URL)" ]
  # The one ExternalSecret is the volume's backup credentials, which every volume of the component has;
  # no Secret is built or rendered, and no generator makes one.
  [ "$(yq -N 'select(.kind == "ExternalSecret") | .metadata.name' "$BUILT")" = open-webui-volsync ]
  [ -z "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$BUILT" "$RENDERED")" ]
  [ -z "$(yq -N 'select(.apiVersion | test("^generators\.external-secrets\.io/")) | .metadata.name' "$BUILT")" ]
  # Nothing the pod reads comes from a Secret, and no variable that holds a credential has a value.
  [ "$(yq '[.env[] | select(has("valueFrom"))] | length' "$CONTAINER")" -eq 0 ]
  [ "$(yq '.envFrom // [] | length' "$CONTAINER")" -eq 0 ]
  [ "$(yq '[.spec.template.spec.volumes[] | select(has("secret"))] | length' "$DEPLOYMENT")" -eq 0 ]
  [ -z "$(yq -N '.spec.template.spec.containers[].env[]? | select(.name | test("PASSWORD|KEY|SECRET|TOKEN|CREDENTIAL|^WEBUI_ADMIN_")) | select(.name != "WEBUI_SECRET_KEY_FILE") | .name' "$RENDERED")" ]
  # The key that signs sessions is the file Open WebUI generates when it has none, kept on the volume.
  data="$(env_value DATA_DIR)"
  [ "$(mounts "$CONTAINER" | grep ' claim ' | cut -d' ' -f1)" = "$data" ]
  [[ $(env_value WEBUI_SECRET_KEY_FILE) == "$data"/* ]]
  # No model backend: both connections are off and neither is given a key. The Ollama one is at the
  # pod's own loopback, where nothing listens; the OpenAI one is given no address, so it keeps Open
  # WebUI's default, OpenAI's own API, which nothing contacts while the connection is off.
  [ "$(env_value ENABLE_OLLAMA_API)" = false ]
  [ "$(env_value ENABLE_OPENAI_API)" = false ]
  [[ $(env_value OLLAMA_BASE_URL) =~ ^http://127\.0\.0\.1:[0-9]+$ ]] || { echo "OLLAMA_BASE_URL is $(env_value OLLAMA_BASE_URL)"; return 1; }
  for name in OPENAI_API_BASE_URL OPENAI_API_BASE_URLS OPENAI_API_KEY OPENAI_API_KEYS OLLAMA_BASE_URLS OLLAMA_API_BASE_URL; do
    [ -z "$(env_of "$name")" ] || { echo "$name is set"; return 1; }
  done
}

@test "Open WebUI calls nothing outside the cluster until a person configures a connection" {
  local pair name want
  render_app open-webui
  container
  # The slim image, which holds no embedding, speech or tokenizer weights to fetch or to be hidden
  # under the volume.
  [[ $(yq '.image' "$CONTAINER") =~ ^ghcr\.io/open-webui/open-webui:[0-9]+\.[0-9]+\.[0-9]+-slim@sha256:[0-9a-f]{64}$ ]]
  for pair in $OPEN_WEBUI_OFF; do
    name="${pair%%=*}"
    want="${pair#*=}"
    [ "$(env_value "$name")" = "$want" ] || { echo "$name is not $want"; return 1; }
    grep -q "\`$name\`" "$REPO/docs/kubernetes.md" || { echo "docs/kubernetes.md has no row for $name"; return 1; }
  done
  # The default Ollama address is a name Open WebUI looks up at start; here it is the pod's own.
  [[ $(env_value OLLAMA_BASE_URL) =~ ^http://127\.0\.0\.1:[0-9]+$ ]]
  grep -q "\`OLLAMA_BASE_URL\`" "$REPO/docs/kubernetes.md"
  # A variable outside the ones reviewed for what it makes Open WebUI call is refused, whatever it
  # does: a name that turns a fetch or an export on (CUSTOM_NAME, ENABLE_OTEL with an endpoint) is
  # not among them, so adding one is a decision this list records.
  want="$OPEN_WEBUI_REVIEWED"
  for pair in $OPEN_WEBUI_OFF; do want="$want ${pair%%=*}"; done
  name="$(yq -N '.env[].name' "$CONTAINER" | LC_ALL=C sort | paste -sd' ' -)"
  want="$(xargs -n1 <<<"$want" | LC_ALL=C sort | paste -sd' ' -)"
  [ "$name" = "$want" ] || { echo "variables: $name; reviewed: $want"; return 1; }
  # The image's own start script runs with that environment: a command or arguments of the
  # container's own could set any variable before it.
  [ "$(yq '.command // [] | length' "$CONTAINER")" -eq 0 ] || { echo "command: $(yq -o json -I0 '.command' "$CONTAINER")"; return 1; }
  [ "$(yq '.args // [] | length' "$CONTAINER")" -eq 0 ] || { echo "args: $(yq -o json -I0 '.args' "$CONTAINER")"; return 1; }
}

@test "Open WebUI lets nobody but the first account register and makes later accounts wait for approval" {
  render_app open-webui
  container
  # The first account becomes the administrator whatever these say; they decide the ones after it.
  [ "$(env_value ENABLE_SIGNUP)" = false ]
  [ "$(env_value DEFAULT_USER_ROLE)" = pending ]
  # No account, administrator or login provider is given by a variable.
  [ -z "$(yq -N '.spec.template.spec.containers[].env[]? | select(.name | test("^WEBUI_ADMIN_|^ENABLE_OAUTH|^OAUTH_|^ENABLE_LDAP|^ENABLE_LOGIN_FORM|^ENABLE_PASSWORD_AUTH|^WEBUI_AUTH$|^ENABLE_API_KEY")) | .name' "$RENDERED")" ]
}

@test "Open WebUI's pod meets the restricted level with a read-only root and only the writable mounts it needs" {
  local name
  render_app open-webui
  container
  overlay
  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "ai-system") | .metadata.labels["pod-security.kubernetes.io/enforce"]' "$OVERLAY")" = restricted ]
  [ "$(yq '.spec.template.spec.securityContext.runAsNonRoot' "$DEPLOYMENT")" = true ]
  [ "$(yq '.spec.template.spec.securityContext.runAsUser' "$DEPLOYMENT")" -gt 0 ]
  [ "$(yq '.spec.template.spec.securityContext.seccompProfile.type' "$DEPLOYMENT")" = RuntimeDefault ]
  [ "$(yq '[.spec.template.spec.hostNetwork, .spec.template.spec.hostPID, .spec.template.spec.hostIPC] | map(. // false) | join(",")' "$DEPLOYMENT")" = false,false,false ]
  [ "$(yq '[.spec.template.spec.containers[].name] | join(",")' "$DEPLOYMENT")" = main ]
  [ "$(yq '.spec.template.spec.initContainers // [] | length' "$DEPLOYMENT")" -eq 0 ]
  [ "$(yq '.securityContext.allowPrivilegeEscalation' "$CONTAINER")" = false ]
  [ "$(yq '.securityContext.readOnlyRootFilesystem' "$CONTAINER")" = true ]
  [ "$(yq '.securityContext.capabilities.drop | join(",")' "$CONTAINER")" = ALL ]
  [ "$(yq '.securityContext.capabilities.add // [] | length' "$CONTAINER")" -eq 0 ]
  [ "$(yq '.securityContext.privileged // false' "$CONTAINER")" = false ]
  [[ $(yq '.image' "$CONTAINER") =~ ^[a-z0-9./-]+:[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+)?@sha256:[0-9a-f]{64}$ ]]
  # The values docs/kubernetes.md gives from the measured run: requests above its peak, a memory
  # limit, and no CPU limit.
  echo "resources: $(yq -o json -I0 '.resources' "$CONTAINER")"
  [ "$(yq -o json -I0 '.resources' "$CONTAINER" | jq -cS .)" = '{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"384Mi"}}' ]
  # Where it writes, and nowhere else: the claim, the static files it copies from its build at every
  # start and then serves, and /tmp.
  echo "mounts: $(mounts "$CONTAINER" | paste -sd, -)"
  [ "$(mounts "$CONTAINER" | paste -sd, -)" = "/app/backend/data claim open-webui,/app/backend/open_webui/static emptyDir,/tmp emptyDir" ]
  [ "$(volume_at "$CONTAINER" /tmp)" != "$(volume_at "$CONTAINER" /app/backend/open_webui/static)" ]
  # Health, on Open WebUI's own endpoints: the process answers, and its database does.
  [ "$(yq '.livenessProbe.httpGet.path' "$CONTAINER")" = /health ]
  [ "$(yq '.readinessProbe.httpGet.path' "$CONTAINER")" = /health/db ]
  [ "$(yq '.startupProbe.httpGet.path' "$CONTAINER")" = /health ]
  for name in livenessProbe readinessProbe startupProbe; do
    [ "$(NAME="$name" yq '.[strenv(NAME)].httpGet.port' "$CONTAINER")" = "$(env_value PORT)" ]
  done
}

@test "Open WebUI's data is on a backed-up volume and it is reached by its hostname on the public Gateway" {
  local claim source destination route service domain schedule other
  domain="$(yq -e '.CLUSTER_DOMAIN' "$EXAMPLE")"
  render_app open-webui
  container
  # The volume: the volsync component's claim for the application, filled from the restore on create
  # and backed up every night with the component's retention.
  [ "$(yq '.spec.components | map(select(test("/components/volsync$"))) | length' "$KS")" -eq 1 ]
  [ "$(yq '.spec.postBuild.substitute.APP' "$KS")" = open-webui ]
  # The restore on a first rollout takes longer than the default timeout, which the label lengthens;
  # the schedule is a minute of its own, so the mover pods of two volumes do not start together.
  [ "$(yq '.metadata.labels["k8s-gitops/timeout"]' "$KS")" = long ]
  schedule="$(yq '.spec.postBuild.substitute.VOLSYNC_SCHEDULE' "$KS")"
  for other in "$REPO"/kubernetes/apps/base/*/*/ks.yaml; do
    [ "$(yq '.metadata.name' "$other")" = open-webui ] && continue
    [ "$(yq '.spec.postBuild.substitute.VOLSYNC_SCHEDULE // ""' "$other")" != "$schedule" ] || { echo "$other has the schedule $schedule"; return 1; }
  done
  claim="$(only "$BUILT" PersistentVolumeClaim)"
  [ "$claim" = open-webui ]
  [ "$(object "$BUILT" PersistentVolumeClaim "$claim" | yq '.spec.dataSourceRef.kind')" = ReplicationDestination ]
  destination="$(object "$BUILT" PersistentVolumeClaim "$claim" | yq '.spec.dataSourceRef.name')"
  [ "$(only "$BUILT" ReplicationDestination)" = "$destination" ]
  [ "$(object "$BUILT" ReplicationDestination "$destination" | yq '.spec.trigger.manual')" = restore-once ]
  source="$(only "$BUILT" ReplicationSource)"
  [ "$(object "$BUILT" ReplicationSource "$source" | yq '.spec.sourcePVC')" = "$claim" ]
  [[ $(object "$BUILT" ReplicationSource "$source" | yq '.spec.trigger.schedule') =~ ^[0-9]+\ [0-9]+\ \*\ \*\ \*$ ]]
  [ "$(object "$BUILT" ReplicationSource "$source" | yq -o json -I0 '.spec.restic.retain' | jq -cS .)" = '{"daily":7,"monthly":3,"weekly":4}' ]
  # The data directory is the claim, and the one replica lets go of it before its successor starts.
  [ "$(yq '.spec.template.spec.volumes[] | select(.persistentVolumeClaim.claimName == "'"$claim"'") | .name' "$DEPLOYMENT")" = data ]
  [ "$(mounts "$CONTAINER" | grep " claim $claim" | paste -sd, -)" = "$(env_value DATA_DIR) claim $claim" ]
  [ "$(yq '.spec.replicas' "$DEPLOYMENT")" -eq 1 ]
  [ "$(yq '.spec.strategy.type' "$DEPLOYMENT")" = Recreate ]
  # The route: the public Gateway's https listener, and no other, to the Service at the port the
  # application listens on.
  route="$(only "$BUILT" HTTPRoute)"
  [ "$route" = open-webui ]
  object "$BUILT" HTTPRoute "$route" >"$BATS_TEST_TMPDIR/route.yaml"
  [ "$(yq '.metadata.namespace' "$BATS_TEST_TMPDIR/route.yaml")" = ai-system ]
  [ "$(yq '.spec.hostnames | join(",")' "$BATS_TEST_TMPDIR/route.yaml")" = "open-webui.$domain" ]
  [ "$(yq '.spec.parentRefs | length' "$BATS_TEST_TMPDIR/route.yaml")" -eq 1 ]
  [ "$(yq '.spec.parentRefs[0] | .name + "/" + .namespace + "/" + .sectionName' "$BATS_TEST_TMPDIR/route.yaml")" = public/envoy-gateway-system/https ]
  [ "$(yq '.spec.rules | length' "$BATS_TEST_TMPDIR/route.yaml")" -eq 1 ]
  service="$(yq '.spec.rules[0].backendRefs[0].name' "$BATS_TEST_TMPDIR/route.yaml")"
  [ "$(only "$RENDERED" Service)" = "$service" ]
  [ "$(object "$RENDERED" Service "$service" | yq '.spec.ports[0].port')" = "$(yq '.spec.rules[0].backendRefs[0].port' "$BATS_TEST_TMPDIR/route.yaml")" ]
  [ "$(env_value PORT)" = "$(yq '.spec.rules[0].backendRefs[0].port' "$BATS_TEST_TMPDIR/route.yaml")" ]
  # The origin it allows and the URL it names itself by are that name over https, and the session
  # cookie is for https alone; they follow the variable.
  [ "$(env_value CORS_ALLOW_ORIGIN)" = "https://open-webui.$domain" ]
  [ "$(env_value WEBUI_URL)" = "https://open-webui.$domain" ]
  [ "$(env_value WEBUI_AUTH_COOKIE_SECURE)" = true ]
  other_vars
  VARS="$OTHER" render_app open-webui
  container
  domain="$(yq -e '.CLUSTER_DOMAIN' "$OTHER")"
  [ "$(object "$BUILT" HTTPRoute open-webui | yq '.spec.hostnames | join(",")')" = "open-webui.$domain" ]
  [ "$(env_value CORS_ALLOW_ORIGIN)" = "https://open-webui.$domain" ]
  [ "$(env_value WEBUI_URL)" = "https://open-webui.$domain" ]
  # The namespace lets its routes attach to that listener.
  overlay
  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "ai-system") | .metadata.labels["k8s-gitops/gateway"]' "$OVERLAY")" = public ]
}
