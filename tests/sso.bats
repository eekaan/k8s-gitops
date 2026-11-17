#!/usr/bin/env bats
# Proves features/sso.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq and jq on PATH (the versions pinned for the repository). The charts
# are pulled once per run from their public registries; building and rendering are offline, with the
# placeholders of the cluster's example key lists. What only a browser, GitHub and a running Gateway
# can show, the answers of Envoy and oauth2-proxy to a request and the redirects through dex, is not
# proved here (docs/kubernetes.md, Sign-in).

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
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  EXAMPLE="$BATS_TEST_TMPDIR/example-vars.yaml"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$EXAMPLE"
  OVERLAY_DIR="$REPO/kubernetes/apps/overlays/lab-sto2"
  NS=sso-system
}

# overlay: the lab-sto2 overlay as Flux reads it, its namespaces and the Kustomization of each
# enabled application. Writes $OVERLAY.
overlay() {
  OVERLAY="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "${1:-$OVERLAY_DIR}" >"$OVERLAY"
}

# build_from_overlay APP: the objects the overlay's Kustomization of APP applies, built offline with
# the example key lists, or those of the file VARS names, and its own substitutions, strictly.
build_from_overlay() {
  local ks="$BATS_TEST_TMPDIR/overlay-$1-ks.yaml" path
  # shellcheck disable=SC2016 # $vars is a yq variable.
  NAME="$1" yq ea 'select(fileIndex == 0) as $vars
    | select(fileIndex == 1 and .kind == "Kustomization" and .metadata.name == strenv(NAME))
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "${VARS:-$EXAMPLE}" "$OVERLAY" >"$ks"
  [ -s "$ks" ] || { echo "the lab-sto2 overlay does not enable $1"; return 1; }
  path="$(yq '.spec.path' "$ks")"
  (cd "$REPO" && flux build kustomization "$1" --path "./kubernetes/${path#./}" \
    --kustomization-file "$ks" --dry-run --strict-substitute)
}

# built APP: the application APP as Flux applies it on lab-sto2. Writes $BATS_TEST_TMPDIR/APP-built.yaml
# and sets BUILT.
built() {
  overlay
  BUILT="$BATS_TEST_TMPDIR/$1-built.yaml"
  build_from_overlay "$1" >"$BUILT"
}

# everything: the overlay's build and every application it enables, each built as Flux applies it,
# in one file. Writes $EVERYTHING.
everything() {
  local name
  overlay
  EVERYTHING="$BATS_TEST_TMPDIR/everything.yaml"
  cp "$OVERLAY" "$EVERYTHING"
  for name in $(yq -N 'select(.kind == "Kustomization") | .metadata.name' "$OVERLAY"); do
    echo --- >>"$EVERYTHING"
    build_from_overlay "$name" >>"$EVERYTHING"
  done
}

# var NAME: the value of the cluster-config variable NAME in the key lists built with.
var() {
  NAME="$1" yq -e '.[strenv(NAME)]' "${VARS:-$EXAMPLE}"
}

# other_vars: writes a copy of the example values with another domain and sets OTHER to it, so a
# test can build again and see that what it read came from the variable, not from a literal that
# happens to equal the example.
other_vars() {
  OTHER="$BATS_TEST_TMPDIR/other-vars.yaml"
  CLUSTER_DOMAIN=other.example.org yq '.CLUSTER_DOMAIN = strenv(CLUSTER_DOMAIN)' "$EXAMPLE" >"$OTHER"
}

# render APP: builds APP, renders the chart its HelmRelease installs, from the URL and tag of its
# OCIRepository, with the values helm-controller gives it (those of each ConfigMap the release reads,
# in order, then the release's own over them), and writes $BATS_TEST_TMPDIR/APP-rendered.yaml. Sets
# BUILT and RENDERED.
render() {
  local app=$1 url tag release namespace pulled name i values=() count inline
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
    values[i]="$BATS_TEST_TMPDIR/$app-values-$i.yaml"
    NAME="$name" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .data["values.yaml"]' \
      "$BUILT" >"${values[i]}"
    [ -s "${values[i]}" ] || { echo "no values in the ConfigMap $name the HelmRelease reads"; return 1; }
  done
  inline="$BATS_TEST_TMPDIR/$app-inline.yaml"
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$BUILT" >"$inline"
  pulled="$BATS_FILE_TMPDIR/charts/$app-$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  RENDERED="$BATS_TEST_TMPDIR/$app-rendered.yaml"
  helm template "$release" "$pulled"/*.tgz --namespace "$namespace" --kube-version "$KUBE" \
    "${values[@]/#/--values=}" --values "$inline" >"$RENDERED"
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

# dex_config FILE: the configuration the chart puts in the Secret dex of FILE, decoded.
dex_config() {
  object "$1" Secret dex | yq -e '.data["config.yaml"]' | base64 -d
}

# workload FILE: the one Deployment of FILE.
workload() {
  object "$1" Deployment "$(only "$1" Deployment)"
}

# none PATTERN [FILE...]: fails, showing the matches, when a line of the files, or of the standard
# input when there are none, matches the extended regular expression PATTERN in any case. A bare
# `! grep` would never fail a test: errexit ignores a negated command.
none() {
  local pattern=$1 found
  shift
  if [ $# -gt 0 ]; then
    found="$(grep -rEIih -e "$pattern" -- "$@" || true)"
  else
    found="$(grep -Eih -e "$pattern" || true)"
  fi
  [ -z "$found" ] || { echo "matches of $pattern: $found"; return 1; }
}

# cfg_line FILE LINE: fails unless LINE is a whole line of FILE.
cfg_line() {
  grep -qxF -- "$2" "$1" || { echo "$1 has no line: $2"; return 1; }
}

# tree_without APP...: copies kubernetes/ to $TREE and takes the ks.yaml of each APP out of the
# overlay's resources.
tree_without() {
  local app
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE"
  cp -r "$REPO/kubernetes" "$TREE/kubernetes"
  cp "$REPO/versions.yaml" "$TREE/versions.yaml"
  for app in "$@"; do
    yq -i '.resources |= map(select(test("/'"$app"'/ks.yaml$") | not))' "$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  done
}

# secret_targets FILE...: the name of each Secret an ExternalSecret of the files makes, one per line.
secret_targets() {
  yq -N 'select(.kind == "ExternalSecret") | .spec.target.name // .metadata.name' "$@"
}

@test "A route that opts in sends a request without a session to sign-in, and the backend receives nothing" {
  local policy domain route proxy
  domain="$(var CLUSTER_DOMAIN)"
  built hello-sso
  policy="$(only "$BUILT" SecurityPolicy)"
  object "$BUILT" SecurityPolicy "$policy" >"$BATS_TEST_TMPDIR/policy.yaml"
  echo "policy $policy: $(yq -o json -I0 '.spec' "$BATS_TEST_TMPDIR/policy.yaml")"
  route="$(yq -N 'select(.kind == "HTTPRoute" and (.spec.hostnames[0] // "") == "hello-sso.'"$domain"'" and ((.spec.rules[0].matches[0].path.value // "") != "/oauth2/")) | .metadata.name' "$BUILT")"
  [ "$(wc -l <<<"$route")" -eq 1 ] && [ -n "$route" ]
  # The policy targets the protected route and no other object.
  [ "$(yq '.spec.targetRefs | length' "$BATS_TEST_TMPDIR/policy.yaml")" -eq 1 ]
  [ "$(yq -o json -I0 '.spec.targetRefs[0] | [.group, .kind, .name]' "$BATS_TEST_TMPDIR/policy.yaml")" \
    = "[\"gateway.networking.k8s.io\",\"HTTPRoute\",\"$route\"]" ]
  [ "$(yq '.spec.targetRefs[0] | has("sectionName")' "$BATS_TEST_TMPDIR/policy.yaml")" = false ]
  # External authorisation by HTTP to oauth2-proxy's Service.
  [ "$(yq '.spec.extAuth | has("grpc")' "$BATS_TEST_TMPDIR/policy.yaml")" = false ]
  [ "$(yq '.spec.extAuth.http.backendRefs | length' "$BATS_TEST_TMPDIR/policy.yaml")" -eq 1 ]
  [ "$(yq -o json -I0 '.spec.extAuth.http.backendRefs[0] | [(.kind // "Service"), .name, .namespace, .port]' "$BATS_TEST_TMPDIR/policy.yaml")" \
    = '["Service","oauth2-proxy","sso-system",80]' ]
  # Envoy lets a request through only on a 200 and answers the client with any other answer below
  # 500, its status, Location and Set-Cookie included. oauth2-proxy is asked at its root, which its
  # catch-all handler serves: 200 from its static upstream for a session of a listed identity, a
  # redirect to dex for none. The request's own path is not passed: oauth2-proxy answers /ping,
  # /ready and /robots.txt with 200 before it looks for a session, and the path option would append
  # it. The query names the route's own host, where a person returns after signing in.
  [ "$(yq '.spec.extAuth.http.pathOverride' "$BATS_TEST_TMPDIR/policy.yaml")" = "/?rd=https://hello-sso.$domain/" ]
  [ "$(yq '.spec.extAuth.http | has("path")' "$BATS_TEST_TMPDIR/policy.yaml")" = false ]
  # Fail closed: an answer that cannot be had is not a pass.
  [ "$(yq '.spec.extAuth.failOpen // false' "$BATS_TEST_TMPDIR/policy.yaml")" = false ]
  # Of the request, the session cookie alone reaches oauth2-proxy, besides the host, the method, the
  # path and Authorization, which Envoy always sends; and the identity it answers with reaches the
  # backend.
  [ "$(yq -o json -I0 '.spec.extAuth.headersToExtAuth' "$BATS_TEST_TMPDIR/policy.yaml")" = '["cookie"]' ]
  yq -e '.spec.extAuth.http.headersToBackend | contains(["x-auth-request-user", "x-auth-request-email"])' "$BATS_TEST_TMPDIR/policy.yaml"
  # The protected route has one rule and one backend, the demo's Service: no second way to it.
  object "$BUILT" HTTPRoute "$route" >"$BATS_TEST_TMPDIR/route.yaml"
  [ "$(yq '.spec.rules | length' "$BATS_TEST_TMPDIR/route.yaml")" -eq 1 ]
  [ "$(yq -o json -I0 '[.spec.rules[0].backendRefs[] | .name]' "$BATS_TEST_TMPDIR/route.yaml")" = '["hello"]' ]
  [ "$(yq '.spec.rules[0] | has("filters")' "$BATS_TEST_TMPDIR/route.yaml")" = false ]
  [ "$(yq -o json -I0 '.spec.parentRefs | map([.name, .namespace, .sectionName])' "$BATS_TEST_TMPDIR/route.yaml")" \
    = '[["public","envoy-gateway-system","https"]]' ]
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .spec.rules[].backendRefs[] | select(.name == "hello") | .name' "$BUILT" | wc -l)" -eq 1 ]
  # The sign-in paths on the same host go to oauth2-proxy, and no policy covers them: they are the
  # flow itself.
  yq -N 'select(.kind == "HTTPRoute" and .spec.rules[0].matches[0].path.value == "/oauth2/")' "$BUILT" >"$BATS_TEST_TMPDIR/signin.yaml"
  [ -s "$BATS_TEST_TMPDIR/signin.yaml" ]
  [ "$(yq '.spec.hostnames | join(",")' "$BATS_TEST_TMPDIR/signin.yaml")" = "hello-sso.$domain" ]
  [ "$(yq '.spec.rules[0].matches[0].path.type' "$BATS_TEST_TMPDIR/signin.yaml")" = PathPrefix ]
  [ "$(yq -o json -I0 '.spec.rules[0].backendRefs | map([.name, .namespace, .port])' "$BATS_TEST_TMPDIR/signin.yaml")" \
    = '[["oauth2-proxy","sso-system",80]]' ]
  [ "$(yq '.metadata.name' "$BATS_TEST_TMPDIR/signin.yaml")" != "$route" ]
  [ "$(yq -N 'select(.kind == "SecurityPolicy") | .spec.targetRefs[].name' "$BUILT")" = "$route" ]
  # The host follows the cluster's domain.
  other_vars
  VARS="$OTHER" built hello-sso
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .spec.hostnames[0]' "$BUILT" | sort -u)" = hello-sso.other.example.org ]
  # oauth2-proxy's own end: Service on 80; its catch-all handler answers a session with its static
  # upstream's 200 and the identity in the X-Auth-Request headers, and no session with the redirect
  # to dex, not a page with a sign-in button; the return address is under the domain it accepts.
  # Nothing answers without a session otherwise: no route or address that skips authentication, no
  # prefix that would make the root one of oauth2-proxy's own paths, no health check at the root, no
  # JSON error in place of the redirect, no forwarded headers trusted, no password file that admits a
  # request by its Authorization header and no password form.
  render oauth2-proxy
  proxy="$(only "$RENDERED" Service)"
  [ "$proxy" = oauth2-proxy ]
  [ "$(yq -N 'select(.kind == "Service" and .metadata.name == "oauth2-proxy") | .spec.ports[] | select(.port == 80) | .port' "$RENDERED")" = 80 ]
  object "$RENDERED" ConfigMap oauth2-proxy | yq '.data["oauth2_proxy.cfg"]' >"$BATS_TEST_TMPDIR/oauth2-proxy.cfg"
  cfg_line "$BATS_TEST_TMPDIR/oauth2-proxy.cfg" 'upstreams = [ "static://200" ]'
  cfg_line "$BATS_TEST_TMPDIR/oauth2-proxy.cfg" 'skip_provider_button = true'
  cfg_line "$BATS_TEST_TMPDIR/oauth2-proxy.cfg" 'set_xauthrequest = true'
  cfg_line "$BATS_TEST_TMPDIR/oauth2-proxy.cfg" "whitelist_domains = [ \".$domain\" ]"
  none 'skip_auth|trusted_ip|api_routes|skip_jwt|insecure_oidc|proxy_prefix|ping_path|ready_path|force_json_errors|reverse_proxy|htpasswd_file|display_htpasswd_form' "$BATS_TEST_TMPDIR/oauth2-proxy.cfg"
  workload "$RENDERED" | yq '.spec.template.spec.containers[0].args[]' | none 'skip-auth|trusted-ip|skip-jwt|insecure-oidc|proxy-prefix|ping-path|ready-path|force-json-errors|reverse-proxy|upstream'
}

@test "Every client and cookie secret comes from the secret store or is made once in the cluster, and none is in a ConfigMap or the tree" {
  local targets env_name value secret key rendered
  render dex
  cp "$BUILT" "$BATS_TEST_TMPDIR/dex-b.yaml"
  cp "$RENDERED" "$BATS_TEST_TMPDIR/dex-r.yaml"
  render oauth2-proxy
  cp "$BUILT" "$BATS_TEST_TMPDIR/proxy-b.yaml"
  cp "$RENDERED" "$BATS_TEST_TMPDIR/proxy-r.yaml"
  # The GitHub client's ID and secret: the owner's, read from the secret store.
  object "$BATS_TEST_TMPDIR/dex-b.yaml" ExternalSecret dex-github >"$BATS_TEST_TMPDIR/github.yaml"
  [ "$(yq '.spec.secretStoreRef | [.kind, .name] | join("/")' "$BATS_TEST_TMPDIR/github.yaml")" = ClusterSecretStore/openbao ]
  [ "$(yq -o json -I0 '[.spec.data[] | [.secretKey, .remoteRef.key, .remoteRef.property]] | sort' "$BATS_TEST_TMPDIR/github.yaml")" \
    = '[["client-id","sso-system/dex","github-client-id"],["client-secret","sso-system/dex","github-client-secret"]]' ]
  [ "$(yq '.spec | has("dataFrom")' "$BATS_TEST_TMPDIR/github.yaml")" = false ]
  # The secret dex and oauth2-proxy share, and oauth2-proxy's cookie secret: each made once by a
  # generator, read through the cluster's API only.
  [ "$(yq -N 'select(.kind == "Password") | .metadata.name' "$BATS_TEST_TMPDIR/dex-b.yaml" "$BATS_TEST_TMPDIR/proxy-b.yaml" | sort | paste -sd' ' -)" \
    = "dex-oauth2-proxy-client oauth2-proxy-cookie" ]
  for secret in dex-oauth2-proxy-client oauth2-proxy-cookie; do
    object "$BATS_TEST_TMPDIR/dex-b.yaml" ExternalSecret "$secret" >"$BATS_TEST_TMPDIR/es.yaml"
    [ -s "$BATS_TEST_TMPDIR/es.yaml" ] || object "$BATS_TEST_TMPDIR/proxy-b.yaml" ExternalSecret "$secret" >"$BATS_TEST_TMPDIR/es.yaml"
    [ "$(yq '.spec.refreshPolicy' "$BATS_TEST_TMPDIR/es.yaml")" = CreatedOnce ]
    [ "$(yq '.spec.target.creationPolicy' "$BATS_TEST_TMPDIR/es.yaml")" = Owner ]
    [ "$(yq '.spec.dataFrom[0].sourceRef.generatorRef | [.kind, .name] | join("/")' "$BATS_TEST_TMPDIR/es.yaml")" = "Password/$secret" ]
    [ "$(yq '.spec | has("data") or has("secretStoreRef")' "$BATS_TEST_TMPDIR/es.yaml")" = false ]
  done
  # Every secret a container reads is a Secret one of those ExternalSecrets makes, by reference, and
  # none has a value of its own: three variables of dex's, two of oauth2-proxy's.
  targets="$(secret_targets "$BATS_TEST_TMPDIR/dex-b.yaml" "$BATS_TEST_TMPDIR/proxy-b.yaml")"
  for rendered in dex-r proxy-r; do
    workload "$BATS_TEST_TMPDIR/$rendered.yaml" >"$BATS_TEST_TMPDIR/deployment.yaml"
    yq '.spec.template.spec.containers[].env[] | select(.name | test("SECRET|CLIENT_ID")) |
      .name + "\t" + (.value // "none") + "\t" + .valueFrom.secretKeyRef.name + "\t" + .valueFrom.secretKeyRef.key' \
      "$BATS_TEST_TMPDIR/deployment.yaml" >"$BATS_TEST_TMPDIR/secret-env.tsv"
    echo "$rendered: $(cat "$BATS_TEST_TMPDIR/secret-env.tsv")"
    while IFS=$'\t' read -r env_name value secret key; do
      [ "$value" = none ] && [ -n "$key" ] && grep -qxF "$secret" <<<"$targets" || { echo "$env_name is not a reference to a Secret of an ExternalSecret"; return 1; }
    done <"$BATS_TEST_TMPDIR/secret-env.tsv"
  done
  [ "$(workload "$BATS_TEST_TMPDIR/dex-r.yaml" | yq '[.spec.template.spec.containers[].env[] | select(.name | test("SECRET|CLIENT_ID"))] | length')" -eq 3 ]
  [ "$(workload "$BATS_TEST_TMPDIR/proxy-r.yaml" | yq '[.spec.template.spec.containers[].env[] | select(.name | test("SECRET|CLIENT_ID"))] | length')" -eq 2 ]
  [ "$(workload "$BATS_TEST_TMPDIR/proxy-r.yaml" | yq '.spec.template.spec.containers[0].env[] | select(.name == "OAUTH2_PROXY_COOKIE_SECRET") | .valueFrom.secretKeyRef.name')" = oauth2-proxy-cookie ]
  [ "$(workload "$BATS_TEST_TMPDIR/proxy-r.yaml" | yq '.spec.template.spec.containers[0].env[] | select(.name == "OAUTH2_PROXY_CLIENT_SECRET") | .valueFrom.secretKeyRef.name')" = dex-oauth2-proxy-client ]
  [ "$(workload "$BATS_TEST_TMPDIR/dex-r.yaml" | yq '.spec.template.spec.containers[0].env[] | select(.name == "OAUTH2_PROXY_CLIENT_SECRET") | .valueFrom.secretKeyRef.name')" = dex-oauth2-proxy-client ]
  # No Secret of the builds or the renders but the chart's holder of dex's configuration, which holds
  # references to the environment and no secret.
  [ "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$BATS_TEST_TMPDIR"/{dex-b,dex-r,proxy-b,proxy-r}.yaml | paste -sd' ' -)" = dex ]
  [ -z "$(dex_config "$BATS_TEST_TMPDIR/dex-r.yaml" | yq '.staticClients[] | select(has("secret")) | .id')" ]
  # shellcheck disable=SC2016 # What dex is given is a ${NAME} reference, not for the shell to expand.
  [ "$(dex_config "$BATS_TEST_TMPDIR/dex-r.yaml" | yq '.connectors[0].config.clientSecret')" = '${DEX_GITHUB_CLIENT_SECRET}' ]
  # No ConfigMap holds a client secret, a cookie secret or a client ID of the GitHub app: the keys
  # and values of every ConfigMap of the builds and renders, one per line.
  yq -N 'select(.kind == "ConfigMap") | .data | to_entries | .[] | .key + "=" + .value' \
    "$BATS_TEST_TMPDIR"/{dex-b,dex-r,proxy-b,proxy-r}.yaml >"$BATS_TEST_TMPDIR/configmaps.txt"
  [ -s "$BATS_TEST_TMPDIR/configmaps.txt" ]
  # shellcheck disable=SC2016 # A pattern with a ${ in it, not for the shell to expand.
  none '(client_?secret|cookie_?secret|client-secret|cookie-secret)[a-z_]*"? *[:=] *"?[^${"[:space:]]' "$BATS_TEST_TMPDIR/configmaps.txt"
  # Nothing of the two applications, or of the key lists, is a Flux variable that carries one.
  none '(^|[^$])\$\{[A-Z0-9_]*(SECRET|COOKIE|CLIENT|PASSWORD|TOKEN)[A-Z0-9_]*' "$REPO/kubernetes/apps/base/$NS" "$REPO/kubernetes/components/sso"
  cat "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" | grep -v '^[[:space:]]*#' |
    none 'SECRET|COOKIE|CLIENT|DEX|OAUTH'
}

@test "The identities allowed to sign in come from the secret store and are nowhere in the tree" {
  render oauth2-proxy
  object "$BUILT" ExternalSecret oauth2-proxy-allowed-emails >"$BATS_TEST_TMPDIR/es.yaml"
  [ "$(yq '.spec.secretStoreRef | [.kind, .name] | join("/")' "$BATS_TEST_TMPDIR/es.yaml")" = ClusterSecretStore/openbao ]
  [ "$(yq -o json -I0 '[.spec.data[] | [.secretKey, .remoteRef.key, .remoteRef.property]]' "$BATS_TEST_TMPDIR/es.yaml")" \
    = '[["allowed-emails","sso-system/oauth2-proxy","allowed-emails"]]' ]
  [ "$(yq '.spec.target.name' "$BATS_TEST_TMPDIR/es.yaml")" = oauth2-proxy-allowed-emails ]
  # A file of oauth2-proxy's pod, made from that Secret, and the option that names it.
  workload "$RENDERED" >"$BATS_TEST_TMPDIR/deployment.yaml"
  [ "$(yq '.spec.template.spec.volumes[] | select(.name == "configaccesslist") | .secret.secretName' "$BATS_TEST_TMPDIR/deployment.yaml")" = oauth2-proxy-allowed-emails ]
  [ "$(yq '.spec.template.spec.volumes[] | select(.name == "configaccesslist") | .secret.items[0].key' "$BATS_TEST_TMPDIR/deployment.yaml")" = allowed-emails ]
  # The pod waits for the Secret rather than starting without a list.
  [ "$(yq '.spec.template.spec.volumes[] | select(.name == "configaccesslist") | .secret | has("optional")' "$BATS_TEST_TMPDIR/deployment.yaml")" = false ]
  [ "$(yq '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "configaccesslist") | .mountPath' "$BATS_TEST_TMPDIR/deployment.yaml")" = /etc/oauth2-proxy ]
  [ "$(yq '.spec.template.spec.volumes[] | select(.name == "configaccesslist") | .secret.items[0].path' "$BATS_TEST_TMPDIR/deployment.yaml")" = oauth2-proxy-allowed-emails ]
  yq -e '.spec.template.spec.containers[0].args[] | select(. == "--authenticated-emails-file=/etc/oauth2-proxy/oauth2-proxy-allowed-emails")' "$BATS_TEST_TMPDIR/deployment.yaml"
  # Nothing else admits anybody: no domain, no group and no Secret the chart would fill from a value.
  object "$RENDERED" ConfigMap oauth2-proxy | yq '.data["oauth2_proxy.cfg"]' >"$BATS_TEST_TMPDIR/oauth2-proxy.cfg"
  none 'email_domains|allowed_groups|authenticated_emails_file' "$BATS_TEST_TMPDIR/oauth2-proxy.cfg"
  yq '.spec.template.spec.containers[0].args[]' "$BATS_TEST_TMPDIR/deployment.yaml" | none '^--(email-domain|allowed-group|allowed-email)'
  [ -z "$(yq -N 'select(.kind == "Secret" or .kind == "ConfigMap") | .metadata.name | select(test("accesslist|allowed"))' "$RENDERED")" ]
  # And the list is in no file: no e-mail address in what the applications build or render, in their
  # directory or in the key lists. The addresses of the documentation's domains are examples.
  render dex
  cp "$RENDERED" "$BATS_TEST_TMPDIR/dex-r.yaml"
  built hello-sso
  none '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' \
    "$BATS_TEST_TMPDIR/oauth2-proxy-built.yaml" "$BATS_TEST_TMPDIR/oauth2-proxy-rendered.yaml" \
    "$BATS_TEST_TMPDIR/dex-built.yaml" "$BATS_TEST_TMPDIR/dex-r.yaml" "$BATS_TEST_TMPDIR/hello-sso-built.yaml" \
    "$REPO/kubernetes/apps/base/$NS" "$REPO/kubernetes/components/sso" \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml"
}

@test "dex signs people in with GitHub alone, keeps its state in Kubernetes objects and has no password database" {
  local domain route
  domain="$(var CLUSTER_DOMAIN)"
  render dex
  dex_config "$RENDERED" >"$BATS_TEST_TMPDIR/config.yaml"
  [ "$(yq '.issuer' "$BATS_TEST_TMPDIR/config.yaml")" = "https://dex.$domain" ]
  [ "$(yq -o json -I0 '[.storage.type, .storage.config.inCluster]' "$BATS_TEST_TMPDIR/config.yaml")" = '["kubernetes",true]' ]
  # No password database, and so no password.
  [ "$(yq '.enablePasswordDB' "$BATS_TEST_TMPDIR/config.yaml")" = false ]
  [ "$(yq 'has("staticPasswords")' "$BATS_TEST_TMPDIR/config.yaml")" = false ]
  # One connector, GitHub's, with credentials taken from the environment and the callback under the
  # issuer.
  [ "$(yq '.connectors | length' "$BATS_TEST_TMPDIR/config.yaml")" -eq 1 ]
  [ "$(yq '.connectors[0].type' "$BATS_TEST_TMPDIR/config.yaml")" = github ]
  # shellcheck disable=SC2016 # What dex is given is a ${NAME} reference, not for the shell to expand.
  [ "$(yq '.connectors[0].config.clientID' "$BATS_TEST_TMPDIR/config.yaml")" = '${DEX_GITHUB_CLIENT_ID}' ]
  # shellcheck disable=SC2016 # As above.
  [ "$(yq '.connectors[0].config.clientSecret' "$BATS_TEST_TMPDIR/config.yaml")" = '${DEX_GITHUB_CLIENT_SECRET}' ]
  [ "$(yq '.connectors[0].config.redirectURI' "$BATS_TEST_TMPDIR/config.yaml")" = "https://dex.$domain/callback" ]
  # One static client, oauth2-proxy's, whose secret comes from the environment and whose one redirect
  # URI is on the sign-in host.
  [ "$(yq '.staticClients | length' "$BATS_TEST_TMPDIR/config.yaml")" -eq 1 ]
  [ "$(yq -o json -I0 '.staticClients[0] | [.id, .secretEnv, has("secret"), .redirectURIs]' "$BATS_TEST_TMPDIR/config.yaml")" \
    = "[\"oauth2-proxy\",\"OAUTH2_PROXY_CLIENT_SECRET\",false,[\"https://auth.$domain/oauth2/callback\"]]" ]
  [ "$(yq -o json -I0 '.oauth2.responseTypes' "$BATS_TEST_TMPDIR/config.yaml")" = '["code"]' ]
  # The names follow the domain.
  other_vars
  VARS="$OTHER" render dex
  [ "$(dex_config "$RENDERED" | yq '.issuer')" = "https://dex.other.example.org" ]
  [ "$(dex_config "$RENDERED" | yq '.connectors[0].config.redirectURI')" = "https://dex.other.example.org/callback" ]
  [ "$(dex_config "$RENDERED" | yq '.staticClients[0].redirectURIs[0]')" = "https://auth.other.example.org/oauth2/callback" ]
  render dex
  # The route serves the issuer's name on the public Gateway's https listener, to dex's Service.
  route="$(only "$BUILT" HTTPRoute)"
  object "$BUILT" HTTPRoute "$route" >"$BATS_TEST_TMPDIR/route.yaml"
  [ "$(yq '.spec.hostnames | join(",")' "$BATS_TEST_TMPDIR/route.yaml")" = "dex.$domain" ]
  [ "$(yq -o json -I0 '.spec.parentRefs | map([.name, .namespace, .sectionName])' "$BATS_TEST_TMPDIR/route.yaml")" \
    = '[["public","envoy-gateway-system","https"]]' ]
  [ "$(yq -o json -I0 '.spec.rules[0].backendRefs | map([.name, .port])' "$BATS_TEST_TMPDIR/route.yaml")" = '[["dex",5556]]' ]
  [ "$(yq -N 'select(.kind == "Service" and .metadata.name == "dex") | .spec.ports[] | select(.name == "http") | .port' "$RENDERED")" = 5556 ]
}

@test "oauth2-proxy admits only the owner's list through dex, with a session cookie for the cluster's domain" {
  local domain cfg="$BATS_TEST_TMPDIR/oauth2-proxy.cfg"
  domain="$(var CLUSTER_DOMAIN)"
  render oauth2-proxy
  object "$RENDERED" ConfigMap oauth2-proxy | yq '.data["oauth2_proxy.cfg"]' >"$cfg"
  cfg_line "$cfg" 'provider = "oidc"'
  cfg_line "$cfg" "oidc_issuer_url = \"https://dex.$domain\""
  cfg_line "$cfg" 'client_id = "oauth2-proxy"'
  # The browser meets dex at its public name; the proxy itself reads the keys and redeems the code
  # inside the cluster, so it needs neither a route out and back nor trust in the Gateway's
  # certificate.
  cfg_line "$cfg" 'skip_oidc_discovery = true'
  cfg_line "$cfg" "login_url = \"https://dex.$domain/auth\""
  cfg_line "$cfg" 'redeem_url = "http://dex.sso-system.svc.cluster.local:5556/token"'
  cfg_line "$cfg" 'oidc_jwks_url = "http://dex.sso-system.svc.cluster.local:5556/keys"'
  cfg_line "$cfg" 'code_challenge_method = "S256"'
  # One callback, on the sign-in host, whatever host a person starts from.
  cfg_line "$cfg" "redirect_url = \"https://auth.$domain/oauth2/callback\""
  # A secure, HTTP-only cookie for the whole domain, holding the session.
  cfg_line "$cfg" "cookie_domains = [ \".$domain\" ]"
  cfg_line "$cfg" 'cookie_secure = true'
  cfg_line "$cfg" 'cookie_httponly = true'
  cfg_line "$cfg" 'session_store_type = "cookie"'
  # After sign-in a person returns only to a host under the domain.
  cfg_line "$cfg" "whitelist_domains = [ \".$domain\" ]"
  cfg_line "$cfg" 'set_xauthrequest = true'
  # Admitted by the file and by nothing else, with a verified address.
  none 'email_domains|insecure_oidc_allow_unverified_email' "$cfg"
  yq -e '.spec.template.spec.containers[0].args[] | select(test("^--authenticated-emails-file="))' <(workload "$RENDERED")
  # oauth2-proxy reads every option from OAUTH2_PROXY_* variables too, so the environment is held to
  # the two secrets: a variable that set an e-mail domain or skipped authentication would undo the above.
  workload "$RENDERED" >"$BATS_TEST_TMPDIR/deployment.yaml"
  [ "$(yq '[.spec.template.spec.containers[].env[].name] | sort | join(" ")' "$BATS_TEST_TMPDIR/deployment.yaml")" \
    = 'OAUTH2_PROXY_CLIENT_SECRET OAUTH2_PROXY_COOKIE_SECRET' ]
  [ "$(yq '[.spec.template.spec.containers[] | select(has("envFrom"))] | length' "$BATS_TEST_TMPDIR/deployment.yaml")" -eq 0 ]
  # A command-line flag overrides the configuration file, so the one container's arguments are held
  # to the four the chart renders: the two addresses, the file and the list. An extra one could open
  # the redirect to another domain or weaken the cookie.
  [ "$(yq '.spec.template.spec.containers | length' "$BATS_TEST_TMPDIR/deployment.yaml")" -eq 1 ]
  [ "$(yq '.spec.template.spec.containers[0] | has("command")' "$BATS_TEST_TMPDIR/deployment.yaml")" = false ]
  [ "$(yq -o json -I0 '.spec.template.spec.containers[0].args' "$BATS_TEST_TMPDIR/deployment.yaml")" \
    = '["--http-address=0.0.0.0:4180","--https-address=0.0.0.0:4443","--config=/etc/oauth2_proxy/oauth2_proxy.cfg","--authenticated-emails-file=/etc/oauth2-proxy/oauth2-proxy-allowed-emails"]' ]
  # The names follow the domain.
  other_vars
  VARS="$OTHER" render oauth2-proxy
  object "$RENDERED" ConfigMap oauth2-proxy | yq '.data["oauth2_proxy.cfg"]' >"$cfg"
  cfg_line "$cfg" 'cookie_domains = [ ".other.example.org" ]'
  cfg_line "$cfg" 'login_url = "https://dex.other.example.org/auth"'
  render oauth2-proxy
  # The sign-in host's route.
  yq -N 'select(.kind == "HTTPRoute")' "$BUILT" >"$BATS_TEST_TMPDIR/route.yaml"
  [ "$(yq '.spec.hostnames | join(",")' "$BATS_TEST_TMPDIR/route.yaml")" = "auth.$domain" ]
  [ "$(yq -o json -I0 '.spec.parentRefs | map([.name, .namespace, .sectionName])' "$BATS_TEST_TMPDIR/route.yaml")" \
    = '[["public","envoy-gateway-system","https"]]' ]
  [ "$(yq -o json -I0 '.spec.rules[0].backendRefs | map([.name, .port])' "$BATS_TEST_TMPDIR/route.yaml")" = '[["oauth2-proxy",80]]' ]
}

@test "dex and oauth2-proxy run two replicas under disruption budgets and meet the restricted Pod Security level" {
  local app pod pdb
  overlay
  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "sso-system") | .metadata.labels["pod-security.kubernetes.io/enforce"]' "$OVERLAY")" = restricted ]
  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "sso-system") | .metadata.labels["k8s-gitops/gateway"]' "$OVERLAY")" = public ]
  for app in dex oauth2-proxy; do
    render "$app"
    workload "$RENDERED" >"$BATS_TEST_TMPDIR/deployment.yaml"
    pod="$BATS_TEST_TMPDIR/deployment.yaml"
    [ "$(yq '.spec.replicas' "$pod")" -eq 2 ]
    [ "$(yq '.spec.template.spec.topologySpreadConstraints | map(select(.topologyKey == "kubernetes.io/hostname" and .whenUnsatisfiable == "DoNotSchedule" and .maxSkew == 1)) | length' "$pod")" -eq 1 ]
    jq -e --argjson labels "$(yq -o json -I0 '.spec.template.metadata.labels' "$pod")" \
      'to_entries | length > 0 and all(. as $e | $labels[$e.key] == $e.value)' \
      <<<"$(yq -o json -I0 '.spec.template.spec.topologySpreadConstraints[0].labelSelector.matchLabels' "$pod")"
    pdb="$(only "$RENDERED" PodDisruptionBudget)"
    [ "$(object "$RENDERED" PodDisruptionBudget "$pdb" | yq '.spec.minAvailable')" -eq 1 ]
    jq -e --argjson labels "$(yq -o json -I0 '.spec.template.metadata.labels' "$pod")" \
      'to_entries | length > 0 and all(. as $e | $labels[$e.key] == $e.value)' \
      <<<"$(object "$RENDERED" PodDisruptionBudget "$pdb" | yq -o json -I0 '.spec.selector.matchLabels')"
    [ "$(yq '.spec.template.spec.securityContext.runAsNonRoot' "$pod")" = true ] ||
      [ "$(yq '[.spec.template.spec.containers[].securityContext.runAsNonRoot] | all' "$pod")" = true ]
    [ "$(yq '.spec.template.spec.securityContext.seccompProfile.type // .spec.template.spec.containers[0].securityContext.seccompProfile.type' "$pod")" = RuntimeDefault ]
    # Every container, init containers included: nothing writable, nothing extra, and a bound.
    [ -z "$(yq '(.spec.template.spec.containers + (.spec.template.spec.initContainers // []))[] | select(
        .securityContext.readOnlyRootFilesystem != true
        or .securityContext.allowPrivilegeEscalation != false
        or ((.securityContext.capabilities.drop // []) | contains(["ALL"]) | not)
        or (.securityContext.privileged // false)
        or .resources.requests.cpu == null or .resources.requests.memory == null or .resources.limits.memory == null) | .name' "$pod")" ]
    [ -z "$(yq '.spec.template.spec.containers[] | select(.livenessProbe == null or .readinessProbe == null) | .name' "$pod")" ]
    # dex's image starts through an entrypoint that writes its expanded configuration to /tmp, which a
    # read-only root filesystem refuses, so its container needs a writable emptyDir there.
    if [ "$app" = dex ]; then
      [ "$(yq '.spec.template.spec.volumes[] | select(.name == "tmp") | .emptyDir | tag' "$pod")" = '!!map' ]
      [ "$(yq '.spec.template.spec.containers[0].volumeMounts[] | select(.mountPath == "/tmp") | .name' "$pod")" = tmp ]
    fi
    # A non-root user by number: the kubelet cannot verify a name.
    [ -n "$(yq '.spec.template.spec.securityContext.runAsUser // .spec.template.spec.containers[0].securityContext.runAsUser // ""' "$pod")" ]
  done
}

@test "An application opts a route in with one component, and a namespace that has not opted in cannot use oauth2-proxy" {
  local policies namespaces ns grant host
  everything
  # The component yields the policy and the sign-in route, and takes two variables of its own.
  # shellcheck disable=SC2016 # What the files hold is a ${NAME} reference, not for the shell to expand.
  [ "$(grep -rhoE '\$\{[A-Z_]+' "$REPO/kubernetes/components/sso" | sort -u | paste -sd' ' -)" = '${CLUSTER_DOMAIN ${SSO_HOSTNAME ${SSO_ROUTE' ]
  [ "$(yq -N 'select(.kind == "Component") | .kind' "$REPO/kubernetes/components/sso/kustomization.yaml")" = Component ]
  [ "$(yq -N '.kind' "$REPO"/kubernetes/components/sso/*.yaml | grep -v '^Component$' | sort | paste -sd' ' -)" = 'HTTPRoute SecurityPolicy' ]
  # Every policy with external authorisation asks oauth2-proxy's Service and nothing else.
  policies="$BATS_TEST_TMPDIR/policies.txt"
  yq -N 'select(.kind == "SecurityPolicy" and .spec.extAuth != null) | .metadata.namespace + " " + .metadata.name' "$EVERYTHING" >"$policies"
  [ -s "$policies" ]
  [ -z "$(yq -N 'select(.kind == "SecurityPolicy" and .spec.extAuth != null) | select(
      (.spec.extAuth.http.backendRefs | length) != 1
      or .spec.extAuth.http.backendRefs[0].name != "oauth2-proxy"
      or .spec.extAuth.http.backendRefs[0].namespace != "sso-system"
      or ((.spec.extAuth.http.backendRefs[0].kind // "Service") != "Service")) | .metadata.name' "$EVERYTHING")" ]
  # The grant is in oauth2-proxy's namespace: a ReferenceGrant is read from the namespace of the
  # object that is referred to, and Flux's target namespace would move it out of the opting
  # application's. It is one, for the one Service, and names the namespaces that opted in, for the
  # two kinds that refer to the Service, and no other.
  grant="$BATS_TEST_TMPDIR/grant.yaml"
  yq -N 'select(.kind == "ReferenceGrant")' "$EVERYTHING" >"$grant"
  [ "$(yq '.metadata.namespace' "$grant")" = sso-system ]
  [ "$(yq -o json -I0 '.spec.to' "$grant")" = '[{"group":"","kind":"Service","name":"oauth2-proxy"}]' ]
  namespaces="$(cut -d' ' -f1 "$policies" | sort -u)"
  for ns in $namespaces; do
    [ "$(NS=$ns yq '[.spec.from[] | select(.namespace == strenv(NS)) | .group + "/" + .kind] | sort | join(",")' "$grant")" \
      = "gateway.envoyproxy.io/SecurityPolicy,gateway.networking.k8s.io/HTTPRoute" ]
  done
  [ "$(yq '[.spec.from[].namespace] | unique | join(" ")' "$grant")" = "$(paste -sd' ' - <<<"$namespaces")" ]
  [ "$(yq '.spec.from | length' "$grant")" -eq $((2 * $(wc -l <<<"$namespaces"))) ]
  # Only the opted-in namespaces' routes and policies refer to oauth2-proxy's Service across
  # namespaces: anything else that names it is in its own namespace.
  # shellcheck disable=SC2016 # $own is a yq variable.
  [ -z "$(yq -N 'select(.kind == "HTTPRoute" or .kind == "SecurityPolicy") | .metadata.namespace as $own
      | (.spec.rules[].backendRefs[]?, .spec.extAuth.http.backendRefs[]?) | select(.name == "oauth2-proxy" and (.namespace // $own) != "sso-system") | .name' "$EVERYTHING")" ]
  # A route that opts in has both the policy and the sign-in route, in its own namespace, on its own
  # host.
  while read -r ns name; do
    [ "$(NS=$ns NAME=$name yq -N 'select(.kind == "SecurityPolicy" and .metadata.namespace == strenv(NS) and .metadata.name == strenv(NAME)) | .spec.targetRefs[0].name' "$EVERYTHING")" = "$name" ]
    [ "$(NS=$ns NAME=$name yq -N 'select(.kind == "HTTPRoute" and .metadata.namespace == strenv(NS) and .metadata.name == strenv(NAME)) | .spec.hostnames[0]' "$EVERYTHING")" \
      = "$(NS=$ns NAME=$name yq -N 'select(.kind == "HTTPRoute" and .metadata.namespace == strenv(NS) and .metadata.name == strenv(NAME) + "-oauth2") | .spec.hostnames[0]' "$EVERYTHING")" ]
    [ "$(NS=$ns NAME=$name yq -N 'select(.kind == "HTTPRoute" and .metadata.namespace == strenv(NS) and .metadata.name == strenv(NAME) + "-oauth2") | .spec.rules[0].matches[0].path.value' "$EVERYTHING")" = /oauth2/ ]
    # No other route of the tree lists the host: an unprotected route on it could win the conflict
    # as the older one and bypass the policy.
    host="$(NS=$ns NAME=$name yq -N 'select(.kind == "HTTPRoute" and .metadata.namespace == strenv(NS) and .metadata.name == strenv(NAME)) | .spec.hostnames[0]' "$EVERYTHING")"
    [ -n "$host" ]
    [ -z "$(NS=$ns NAME=$name HOST=$host yq -N 'select(.kind == "HTTPRoute") | select((.spec.hostnames // []) | contains([strenv(HOST)]))
      | select(.metadata.namespace != strenv(NS) or (.metadata.name != strenv(NAME) and .metadata.name != strenv(NAME) + "-oauth2"))
      | .metadata.namespace + "/" + .metadata.name' "$EVERYTHING")" ]
  done <"$policies"
}

@test "The sign-in applications are selected by overlay entries and build nothing when they are not, and nothing else waits on them" {
  local dependency app
  # Every entry: the namespace, its defaults, its default deny and the two Kustomizations, which wait
  # for what they apply, and the demo route that opts in.
  overlay
  [ "$(yq -N 'select(.metadata.namespace == "sso-system" or .metadata.name == "sso-system") | .kind + "/" + .metadata.name' "$OVERLAY" | sort | paste -sd' ' -)" \
    = "ConfigMap/app-template-defaults Namespace/sso-system NetworkPolicy/default-deny" ]
  [ "$(yq -N 'select(.kind == "Kustomization" and (.spec.targetNamespace == "sso-system")) | .metadata.name' "$OVERLAY" | sort | paste -sd' ' -)" = "dex oauth2-proxy" ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .spec.targetNamespace == "sso-system") | .spec.wait' "$OVERLAY" | sort -u)" = true ]
  # The namespace directory alone, and then neither entry.
  tree_without dex oauth2-proxy hello-sso
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ "$(yq -N 'select(.metadata.namespace == "sso-system" or .metadata.name == "sso-system") | .kind + "/" + .metadata.name' "$OVERLAY" | sort | paste -sd' ' -)" \
    = "ConfigMap/app-template-defaults Namespace/sso-system NetworkPolicy/default-deny" ]
  [ -z "$(yq -N 'select(.kind == "Kustomization" and .spec.targetNamespace == "sso-system") | .metadata.name' "$OVERLAY")" ]
  yq -i '.resources |= map(select(test("/sso-system$") | not))' "$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ -z "$(yq -N 'select(.metadata.namespace == "sso-system" or .metadata.name == "sso-system" or .spec.targetNamespace == "sso-system") | .metadata.name' "$OVERLAY")" ]
  # Without the sign-in applications, and the route that opts in, the tree still builds and passes.
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  rm -rf "$TREE"
  # Each application that is a dependency, left out in turn, is refused by name.
  for dependency in external-secrets openbao-store gateway-public cilium blackbox-exporter; do
    for app in dex oauth2-proxy; do
      tree_without "$dependency"
      run "$REPO/scripts/kubernetes-check" "$TREE"
      [ "$status" -ne 0 ]
      [[ $output == *"Kustomization $app names $dependency"* ]] || { echo "$dependency left out: $output"; return 1; }
      rm -rf "$TREE"
    done
  done
  tree_without dex
  run "$REPO/scripts/kubernetes-check" "$TREE"
  [ "$status" -ne 0 ]
  [[ $output == *"Kustomization oauth2-proxy names dex"* ]]
  rm -rf "$TREE"
  tree_without oauth2-proxy
  run "$REPO/scripts/kubernetes-check" "$TREE"
  [ "$status" -ne 0 ]
  [[ $output == *"Kustomization hello-sso names oauth2-proxy"* ]]
  rm -rf "$TREE"
  # Nothing else waits on them: only oauth2-proxy names dex, only the demo route names oauth2-proxy,
  # and nothing names the demo route.
  overlay
  [ "$(yq -N 'select(.kind == "Kustomization") | select(.spec.dependsOn // [] | map(.name) | contains(["dex"])) | .metadata.name' "$OVERLAY")" = oauth2-proxy ]
  [ "$(yq -N 'select(.kind == "Kustomization") | select(.spec.dependsOn // [] | map(.name) | contains(["oauth2-proxy"])) | .metadata.name' "$OVERLAY")" = hello-sso ]
  [ -z "$(yq -N 'select(.kind == "Kustomization") | select(.spec.dependsOn // [] | map(.name) | contains(["hello-sso"])) | .metadata.name' "$OVERLAY")" ]
}
