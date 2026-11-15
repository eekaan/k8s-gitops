#!/usr/bin/env bats
# Proves features/certificates.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq and jq on PATH (the versions pinned for the repository). The test
# of the self-check renders the whole tree with scripts/render, its charts pulled from their public
# registries; building and rendering are offline, as Flux applies the tree, with the placeholders of
# the cluster's example key lists.

# flux build rewrites the kustomization.yaml of the application it builds in this checkout and puts
# it back afterwards, so two builds at once could leave the rewritten file behind.
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
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  EXAMPLE="$BATS_TEST_TMPDIR/example-vars.yaml"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$EXAMPLE"
  STAGING=https://acme-staging-v02.api.letsencrypt.org/directory
  PRODUCTION=https://acme-v02.api.letsencrypt.org/directory
}

# app_dir APP: sets APP_DIR to the directory of the application APP, relative to the repository.
app_dir() {
  local -a dirs=("$REPO"/kubernetes/apps/base/*/"$1")
  [ -f "${dirs[0]}/ks.yaml" ] || { echo "$1: no application directory with a ks.yaml"; return 1; }
  APP_DIR="${dirs[0]#"$REPO"/}"
}

# overlay: the lab-sto2 overlay as Flux reads it: its namespaces and the Kustomization of each
# enabled application, with whatever the overlay patches into them. Writes $OVERLAY.
overlay() {
  OVERLAY="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "$REPO/kubernetes/apps/overlays/lab-sto2" >"$OVERLAY"
}

# built APP: the application APP as Flux applies it on lab-sto2: the overlay's Kustomization of it,
# built with the example key lists, or those of the file VARS names, and its own substitutions,
# strictly. Writes $BATS_TEST_TMPDIR/APP-built.yaml and sets BUILT and APP_DIR.
built() {
  local app=$1 ks="$BATS_TEST_TMPDIR/overlay-$1-ks.yaml" path
  app_dir "$app"
  overlay
  # shellcheck disable=SC2016 # $vars is a yq variable.
  NAME="$app" yq ea 'select(fileIndex == 0) as $vars
    | select(fileIndex == 1 and .kind == "Kustomization" and .metadata.name == strenv(NAME))
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "${VARS:-$EXAMPLE}" "$OVERLAY" >"$ks"
  [ -s "$ks" ] || { echo "the lab-sto2 overlay does not enable $app"; return 1; }
  path="$(yq '.spec.path' "$ks")"
  BUILT="$BATS_TEST_TMPDIR/$app-built.yaml"
  (cd "$REPO" && flux build kustomization "$app" --path "./kubernetes/${path#./}" \
    --kustomization-file "$ks" --dry-run --strict-substitute) >"$BUILT"
}

# built_default APP: the application APP as its own ks.yaml has it, with no patch of any overlay:
# what a cluster that chooses nothing gets. Writes $BATS_TEST_TMPDIR/APP-default.yaml and sets BUILT.
built_default() {
  local app=$1 ks="$BATS_TEST_TMPDIR/default-$1-ks.yaml"
  app_dir "$app"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "${VARS:-$EXAMPLE}" "$REPO/$APP_DIR/ks.yaml" >"$ks"
  BUILT="$BATS_TEST_TMPDIR/$app-default.yaml"
  (cd "$REPO" && flux build kustomization "$app" --path "./$APP_DIR/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute) >"$BUILT"
}

# object FILE KIND NAME: the one object of that kind and name in FILE.
object() {
  KIND="$2" NAME="$3" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$1"
}

# names FILE KIND: the names of the objects of that kind in FILE, sorted, one per line.
names() {
  KIND="$2" yq -N 'select(.kind == strenv(KIND)) | .metadata.name' "$1" | sort
}

# overlay_ks APP: the overlay's Kustomization of APP.
overlay_ks() {
  overlay
  NAME="$1" yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(NAME))' "$OVERLAY"
}

# tree_copy: copies kubernetes/ to $TREE, for a test that changes the overlay.
tree_copy() {
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  mkdir -p "$TREE"
  cp -r "$REPO/kubernetes" "$TREE/kubernetes"
  TREE_OVERLAY="$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
}

@test "The DNS provider's token reaches cert-manager from the secret store and is nowhere in the tree" {
  local external issuer secret key kind
  built acme-issuers
  # One ExternalSecret, in cert-manager's namespace, from the one store, for the one key.
  [ "$(names "$BUILT" ExternalSecret | wc -l)" -eq 1 ]
  external="$(names "$BUILT" ExternalSecret)"
  object "$BUILT" ExternalSecret "$external" >"$BATS_TEST_TMPDIR/external.yaml"
  echo "ExternalSecret: $(yq -o json -I0 '.spec' "$BATS_TEST_TMPDIR/external.yaml")"
  [ "$(yq '.metadata.namespace' "$BATS_TEST_TMPDIR/external.yaml")" = cert-manager ]
  [ "$(yq '.spec.secretStoreRef.kind + " " + .spec.secretStoreRef.name' "$BATS_TEST_TMPDIR/external.yaml")" = "ClusterSecretStore openbao" ]
  [ "$(yq '.spec.data | length' "$BATS_TEST_TMPDIR/external.yaml")" -eq 1 ]
  [ "$(yq '.spec.data[0].remoteRef.key' "$BATS_TEST_TMPDIR/external.yaml")" = cert-manager/cloudflare ]
  [ "$(yq '.spec.data[0].remoteRef.property' "$BATS_TEST_TMPDIR/external.yaml")" = api-token ]
  [ "$(yq '.spec | has("dataFrom")' "$BATS_TEST_TMPDIR/external.yaml")" = false ]
  [ "$(yq '.spec.target.creationPolicy' "$BATS_TEST_TMPDIR/external.yaml")" = Owner ]
  secret="$(yq '.spec.target.name' "$BATS_TEST_TMPDIR/external.yaml")"
  key="$(yq '.spec.data[0].secretKey' "$BATS_TEST_TMPDIR/external.yaml")"
  # Both issuers read that Secret and that key, and no other credential.
  [ "$(names "$BUILT" ClusterIssuer | wc -l)" -eq 2 ]
  for issuer in $(names "$BUILT" ClusterIssuer); do
    [ "$(object "$BUILT" ClusterIssuer "$issuer" | yq '.spec.acme.solvers[0].dns01.cloudflare | keys | join(" ")')" = apiTokenSecretRef ]
    [ "$(object "$BUILT" ClusterIssuer "$issuer" | yq '.spec.acme.solvers[0].dns01.cloudflare.apiTokenSecretRef.name')" = "$secret" ]
    [ "$(object "$BUILT" ClusterIssuer "$issuer" | yq '.spec.acme.solvers[0].dns01.cloudflare.apiTokenSecretRef.key')" = "$key" ]
  done
  # Nothing secret is in the tree: no Secret object, no field that holds a credential, in what the
  # application builds or in its directory.
  [ -z "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$BUILT")" ]
  [ -z "$(grep -rEil 'stringData|apiKeySecretRef|apiToken:|BEGIN [A-Z ]*PRIVATE KEY' "$REPO/$APP_DIR" || true)" ]
  # Nor in any other application of cert-manager's namespace, whose Secret an issuer could name.
  [ -z "$(grep -rEil 'stringData|apiKeySecretRef|apiToken:|BEGIN [A-Z ]*PRIVATE KEY' "$REPO/kubernetes/apps/base/cert-manager" || true)" ]
  # It reads the store only once the store is Ready, and is Ready only once the secret and the
  # issuers are, which kstatus does not read from these kinds by itself.
  overlay_ks acme-issuers >"$BATS_TEST_TMPDIR/ks.yaml"
  [ "$(yq '.spec.dependsOn | map(.name) | sort | join(" ")' "$BATS_TEST_TMPDIR/ks.yaml")" = "cert-manager openbao-store" ]
  [ "$(yq '.spec.targetNamespace' "$BATS_TEST_TMPDIR/ks.yaml")" = cert-manager ]
  [ "$(yq '.spec.wait' "$BATS_TEST_TMPDIR/ks.yaml")" = true ]
  [ "$(yq '.spec.healthCheckExprs | map(.kind) | sort | join(" ")' "$BATS_TEST_TMPDIR/ks.yaml")" = "ClusterIssuer ExternalSecret" ]
  # Healthy is Ready with status True and failed is Ready with status False, for each kind: a Ready
  # condition of any status would count an unregistered issuer as healthy.
  local ready="has(status.conditions) && status.conditions.exists(e, e.type == 'Ready' && e.status == 'True')"
  local failed="has(status.conditions) && status.conditions.exists(e, e.type == 'Ready' && e.status == 'False')"
  for kind in ClusterIssuer ExternalSecret; do
    [ "$(KIND="$kind" yq '.spec.healthCheckExprs[] | select(.kind == strenv(KIND)) | .current' "$BATS_TEST_TMPDIR/ks.yaml")" = "$ready" ]
    [ "$(KIND="$kind" yq '.spec.healthCheckExprs[] | select(.kind == strenv(KIND)) | .failed' "$BATS_TEST_TMPDIR/ks.yaml")" = "$failed" ]
  done
}

@test "An ACME issuer solves DNS-01 only for names under the cluster's domain" {
  local issuer server account zones domain accounts=()
  built acme-issuers
  domain="$(yq -e '.CLUSTER_DOMAIN' "$EXAMPLE")"
  [ "$(names "$BUILT" ClusterIssuer | tr '\n' ' ')" = "letsencrypt-production letsencrypt-staging " ]
  for issuer in letsencrypt-staging letsencrypt-production; do
    object "$BUILT" ClusterIssuer "$issuer" >"$BATS_TEST_TMPDIR/$issuer.yaml"
    echo "$issuer: $(yq -o json -I0 '.spec' "$BATS_TEST_TMPDIR/$issuer.yaml")"
    server="$STAGING"
    [ "$issuer" = letsencrypt-staging ] || server="$PRODUCTION"
    [ "$(yq '.spec.acme.server' "$BATS_TEST_TMPDIR/$issuer.yaml")" = "$server" ]
    # Its own account key, which cert-manager makes; no contact address, which the CA does not ask
    # for.
    account="$(yq '.spec.acme.privateKeySecretRef.name' "$BATS_TEST_TMPDIR/$issuer.yaml")"
    [ -n "$account" ] && [ "$account" != null ]
    accounts+=("$account")
    [ "$(yq '.spec.acme | has("email")' "$BATS_TEST_TMPDIR/$issuer.yaml")" = false ]
    [ "$(yq '.spec.acme | has("externalAccountBinding")' "$BATS_TEST_TMPDIR/$issuer.yaml")" = false ]
    # One solver, DNS-01 through Cloudflare, for the cluster's domain and nothing else.
    [ "$(yq '.spec.acme.solvers | length' "$BATS_TEST_TMPDIR/$issuer.yaml")" -eq 1 ]
    [ "$(yq '.spec.acme.solvers[0] | keys | sort | join(" ")' "$BATS_TEST_TMPDIR/$issuer.yaml")" = "dns01 selector" ]
    [ "$(yq '.spec.acme.solvers[0].dns01 | keys | join(" ")' "$BATS_TEST_TMPDIR/$issuer.yaml")" = cloudflare ]
    [ "$(yq '.spec.acme.solvers[0].selector | keys | join(" ")' "$BATS_TEST_TMPDIR/$issuer.yaml")" = dnsZones ]
    zones="$(yq '.spec.acme.solvers[0].selector.dnsZones | join(" ")' "$BATS_TEST_TMPDIR/$issuer.yaml")"
    [ "$zones" = "$domain" ]
  done
  [ "${accounts[0]}" != "${accounts[1]}" ]
  # The zone comes from the variable: built with another domain it follows.
  VARS="$BATS_TEST_TMPDIR/other-vars.yaml"
  CLUSTER_DOMAIN=other.example.org yq '.CLUSTER_DOMAIN = strenv(CLUSTER_DOMAIN)' "$EXAMPLE" >"$VARS"
  built acme-issuers
  [ "$(object "$BUILT" ClusterIssuer letsencrypt-staging | yq '.spec.acme.solvers[0].selector.dnsZones | join(" ")')" = other.example.org ]
  [ "$(object "$BUILT" ClusterIssuer letsencrypt-production | yq '.spec.acme.solvers[0].selector.dnsZones | join(" ")')" = other.example.org ]
  unset VARS
}

@test "The DNS-01 self-check asks the zone's own nameservers, so a cached negative answer cannot hold a challenge" {
  local deployment controller args path mount configmap config resolvers
  # The controller as the cluster would run it, so a value set in the HelmRelease itself, a
  # post-renderer or a patch of a Kustomization on the way counts as much as the values file.
  cluster_render
  deployment="$(rendered Deployment.apps_cert-manager_cert-manager.yaml)"
  controller='.spec.template.spec.containers[] | select(.name == "cert-manager-controller")'
  [ "$(yq "[$controller] | length" "$deployment")" -eq 1 ]
  args="$(yq "$controller | .args[]" "$deployment")"
  echo "controller arguments: $args"
  # The nameservers-only setting would send the TXT lookup to the listed resolver, whose cache holds
  # a negative answer for the zone's SOA time. Without it the controller finds the zone's
  # nameservers through the resolver and asks each of them for the record. It can be given as an
  # argument or in the config file the controller loads with --config, so both are read.
  [ -z "$(grep -- '^--dns01-recursive-nameservers-only' <<<"$args" || true)" ]
  # The config file is the one --config names, in the ConfigMap mounted at its directory.
  [ "$(grep -c -- '^--config=' <<<"$args")" -eq 1 ]
  path="$(grep -- '^--config=' <<<"$args" | cut -d= -f2-)"
  mount="$(DIR="${path%/*}" yq "$controller | .volumeMounts[] | select(.mountPath == strenv(DIR)) | .name" "$deployment")"
  configmap="$(MOUNT="$mount" yq '.spec.template.spec.volumes[] | select(.name == strenv(MOUNT)) | .configMap.name' "$deployment")"
  config="$(KEY="${path##*/}" yq '.data[strenv(KEY)]' "$(rendered "ConfigMap_cert-manager_$configmap.yaml")")"
  echo "controller config, $path from ConfigMap $configmap: $config"
  [ "$(yq '.kind' <<<"$config")" = ControllerConfiguration ]
  [ "$(yq '.acmeDNS01Config.recursiveNameserversOnly // false' <<<"$config")" = false ]
  [ "$(yq '.acmeDNS01Config | has("recursiveNameservers")' <<<"$config")" = false ]
  # The resolver that finds the zone and its nameservers is one name over HTTPS, so the tree holds no
  # address, and only one: each endpoint listed is one more destination the controller's egress
  # must allow.
  [ "$(grep -c -- '^--dns01-recursive-nameservers=' <<<"$args")" -eq 1 ]
  resolvers="$(grep -- '^--dns01-recursive-nameservers=' <<<"$args" | cut -d= -f2-)"
  echo "resolvers: $resolvers"
  [ "$(tr ',' '\n' <<<"$resolvers" | grep -cE '^https://([a-z0-9-]+\.)+[a-z]{2,}/[a-z-]+$')" -eq 1 ]
  [ "$(tr ',' '\n' <<<"$resolvers" | wc -l)" -eq 1 ]
}

# cluster_render: the tree as Flux and helm-controller would apply it on lab-sto2, rendered by
# scripts/render: every Kustomization built from the cluster's root with the patches it is given on
# the way, and each HelmRelease's chart rendered with the values of its ConfigMaps, its own values
# over them and its post-renderers. Sets RENDER to lab-sto2's render, a directory per application.
cluster_render() {
  "$REPO/scripts/render" "$BATS_TEST_TMPDIR/render" >/dev/null
  RENDER="$BATS_TEST_TMPDIR/render/${CLUSTER##*/}"
}

# rendered FILE: the path of the one file named FILE among the applications of $RENDER.
rendered() {
  local files=("$RENDER"/*/"$1")
  if [ "${#files[@]}" -ne 1 ] || [ ! -f "${files[0]}" ]; then
    echo "$1 is not one file of the render: ${files[*]}" >&2
    return 1
  fi
  echo "${files[0]}"
}

@test "A cluster chooses its public certificate's issuer in one place, and the cluster's own CA is the default" {
  local certificate chosen
  # Nothing chosen: the cluster's own CA, which is what a cluster whose overlay says nothing gets.
  built_default gateway-public
  certificate="$(names "$BUILT" Certificate)"
  [ -n "$certificate" ]
  [ "$(object "$BUILT" Certificate "$certificate" | yq '.spec.issuerRef.kind + " " + .spec.issuerRef.name')" = "ClusterIssuer cluster-ca" ]
  [ "$(object "$BUILT" Certificate "$certificate" | yq '.spec.issuerRef.group // "cert-manager.io"')" = cert-manager.io ]

  # lab-sto2 chooses the production issuer, whose chain a client with the usual public roots trusts.
  # The choice is one patch of the Gateway's Kustomization, and no other Kustomization of the
  # overlay sets the variable.
  overlay
  chosen="$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "gateway-public") | .spec.postBuild.substitute.PUBLIC_ISSUER' "$OVERLAY")"
  echo "chosen: $chosen"
  [ "$chosen" = letsencrypt-production ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .spec.postBuild.substitute.PUBLIC_ISSUER != null) | .metadata.name' "$OVERLAY")" = gateway-public ]
  # The overlay's patches are this one and the one that names external-dns' record owner, each of
  # its own Kustomization.
  [ "$(yq -o json -I0 '[.patches[].target.name]' "$REPO/kubernetes/apps/overlays/lab-sto2/kustomization.yaml")" = '["gateway-public","external-dns"]' ]
  # It is not a cluster-config key: the tree's builds see it, and no cluster's key list holds it.
  [ -z "$(grep -rl PUBLIC_ISSUER "$REPO"/kubernetes/clusters || true)" ]
  # The Certificate follows the choice, and the choice names an issuer the cluster applies.
  built gateway-public
  [ "$(object "$BUILT" Certificate "$certificate" | yq '.spec.issuerRef.kind + " " + .spec.issuerRef.name')" = "ClusterIssuer $chosen" ]
  built acme-issuers
  object "$BUILT" ClusterIssuer "$chosen" | yq -e '.spec.acme.server' | grep -qx "$PRODUCTION"
  [ "$(yq -N 'select(.kind == "ClusterIssuer" and .metadata.name == "letsencrypt-staging") | .metadata.name' "$BUILT")" = letsencrypt-staging ]
}

@test "A cluster that chooses an ACME issuer without the issuers application is refused" {
  local chosen
  # The tree as it is passes.
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]

  # The cluster applies the Gateway's dependency on the issuers, but not the issuers.
  tree_copy
  yq -i '.resources |= map(select(test("/acme-issuers/ks.yaml$") | not))' "$TREE_OVERLAY"
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"Kustomization gateway-public names acme-issuers"* ]]
  [[ $output == *"does not enable"* ]]

  # The cluster applies the issuers and chooses one, with no dependency on them: either of the two.
  for chosen in letsencrypt-staging letsencrypt-production; do
    tree_copy
    yq -i '(.patches[] | select(.target.name == "gateway-public")).patch |= (from_yaml | map(select(.path != "/spec/dependsOn/-")) | to_yaml)' "$TREE_OVERLAY"
    CHOSEN="$chosen" yq -i '(.patches[] | select(.target.name == "gateway-public")).patch |= (from_yaml | (.[] | select(.path == "/spec/postBuild").value.substitute.PUBLIC_ISSUER) = strenv(CHOSEN) | to_yaml)' "$TREE_OVERLAY"
    run "$REPO/scripts/kubernetes-check" "$TREE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ $output == *"Kustomization gateway-public chooses the issuer $chosen"* ]]
    [[ $output == *"acme-issuers"* ]]
  done

  # The cluster chooses a name acme-issuers does not make, with the dependency in place.
  tree_copy
  yq -i '(.patches[] | select(.target.name == "gateway-public")).patch |= (from_yaml | (.[] | select(.path == "/spec/postBuild").value.substitute.PUBLIC_ISSUER) = "letsencrypt-stagin" | to_yaml)' "$TREE_OVERLAY"
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"Kustomization gateway-public chooses the issuer letsencrypt-stagin"* ]]
  [[ $output == *"makes no issuer of that name"* ]]

  # A cluster that chooses nothing needs no issuers.
  tree_copy
  yq -i 'del(.patches[] | select(.target.name == "gateway-public")) | .resources |= map(select(test("/acme-issuers/ks.yaml$") | not))' "$TREE_OVERLAY"
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
}
