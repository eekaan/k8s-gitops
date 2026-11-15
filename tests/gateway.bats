#!/usr/bin/env bats
# Proves features/gateway.feature; each test carries its scenario's title.
# Needs kustomize, flux, yq and jq on PATH (the versions pinned for the repository). Everything is
# built offline, as Flux applies it, with the placeholders of the cluster's example key lists.

# flux build rewrites the kustomization.yaml of the application it builds in this checkout and puts
# it back afterwards, so two builds at once could leave the rewritten file behind.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

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
}

# app_dir APP: sets APP_DIR to the directory of the application APP, in whichever namespace
# directory it is, relative to the repository.
app_dir() {
  local -a dirs=("$REPO"/kubernetes/apps/base/*/"$1")
  [ -f "${dirs[0]}/ks.yaml" ] || { echo "$1: no application directory with a ks.yaml"; return 1; }
  APP_DIR="${dirs[0]#"$REPO"/}"
}

# built APP: the application APP as Flux applies it, its app/ built with its ks.yaml, substituting
# strictly the variables of the example key lists. Writes $BATS_TEST_TMPDIR/APP-built.yaml and
# sets BUILT and APP_DIR.
built() {
  local app=$1 ks="$BATS_TEST_TMPDIR/$1-ks.yaml"
  app_dir "$app"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = $vars' "$EXAMPLE" "$REPO/$APP_DIR/ks.yaml" >"$ks"
  BUILT="$BATS_TEST_TMPDIR/$app-built.yaml"
  (cd "$REPO" && flux build kustomization "$app" --path "./$APP_DIR/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute) >"$BUILT"
}

# var NAME: the example value of the cluster-config variable NAME.
var() {
  NAME="$1" yq -e '.[strenv(NAME)]' "$EXAMPLE"
}

# object FILE KIND NAME: the one object of that kind and name in FILE.
object() {
  KIND="$2" NAME="$3" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$1"
}

# only FILE KIND: the name of the one object of that kind in FILE; fails, saying so, unless there is
# exactly one.
only() {
  local names
  names="$(KIND="$2" yq -N 'select(.kind == strenv(KIND)) | .metadata.name' "$1")"
  [ -n "$names" ] && [ "$(wc -l <<<"$names")" -eq 1 ] || { echo "$1 holds $(wc -l <<<"$names") $2 objects: ${names:-none}"; return 1; }
  echo "$names"
}

# depends_on APP: the names the application's ks.yaml lists in dependsOn, one per line.
depends_on() {
  app_dir "$1"
  yq '.spec.dependsOn // [] | .[].name' "$REPO/$APP_DIR/ks.yaml"
}

# listener FILE NAME: the Gateway's listener NAME, as JSON.
listener() {
  NAME="$2" yq -N -o json -I0 'select(.kind == "Gateway") | .spec.listeners[] | select(.name == strenv(NAME))' "$1"
}

# the gateway files: the one Gateway's file, for messages
GATEWAY_FILE=kubernetes/apps/base/envoy-gateway-system/gateway-public/app/gateway.yaml
EDGE_FILE=infra/openstack/stacks/sto2/edge/variables.tf

@test "The public Gateway asks for the Gateway address and is announced over BGP" {
  local gateway proxy service announce
  built gateway-public
  gateway="$(only "$BUILT" Gateway)"
  proxy="$(only "$BUILT" EnvoyProxy)"
  service="$BATS_TEST_TMPDIR/envoy-service.yaml"
  object "$BUILT" EnvoyProxy "$proxy" | yq '.spec.provider.kubernetes.envoyService' >"$service"
  echo "Gateway $gateway, EnvoyProxy $proxy; its Service: $(yq -o json -I0 . "$service")"
  # The Gateway's proxies are configured by that EnvoyProxy, in its own namespace.
  [ "$(object "$BUILT" Gateway "$gateway" | yq '.spec.infrastructure.parametersRef.group + "/" + .spec.infrastructure.parametersRef.kind + "/" + .spec.infrastructure.parametersRef.name')" \
    = "gateway.envoyproxy.io/EnvoyProxy/$proxy" ]
  [ "$(object "$BUILT" EnvoyProxy "$proxy" | yq '.metadata.namespace')" = "$(object "$BUILT" Gateway "$gateway" | yq '.metadata.namespace')" ]
  # The one class the controller application makes.
  built envoy-gateway
  [ "$(object "$BUILT" GatewayClass "$(only "$BUILT" GatewayClass)" | yq '.metadata.name')" = envoy-gateway ]
  built gateway-public
  [ "$(object "$BUILT" Gateway "$gateway" | yq '.spec.gatewayClassName')" = envoy-gateway ]
  # The Service takes the Gateway's address: the pool hands it out to a labelled Service, and the
  # annotation asks for the one address the edge routers translate to.
  [ "$(yq '.type' "$service")" = LoadBalancer ]
  [ "$(yq '.annotations["lbipam.cilium.io/ips"]' "$service")" = "$(var GATEWAY_ADDRESS)" ]
  # Announced: the label is what the pool and the BGP advertisement of cilium-bgp select.
  announce="$(yq '.labels["k8s-gitops/announce"]' "$service")"
  echo "the Service's k8s-gitops/announce: $announce"
  built cilium-bgp
  [ "$announce" = bgp ]
  [ "$(yq -N 'select(.kind == "CiliumLoadBalancerIPPool") | .spec.serviceSelector.matchLabels["k8s-gitops/announce"]' "$BUILT")" = "$announce" ]
  [ "$(yq -N 'select(.kind == "CiliumBGPAdvertisement") | .spec.advertisements[].selector.matchLabels["k8s-gitops/announce"]' "$BUILT")" = "$announce" ]
  # Every worker announces it and forwards to a proxy on any node, so a proxy that moves, or is
  # replaced in a rollout, does not change what the edge routers see.
  [ "$(yq '.externalTrafficPolicy' "$service")" = Cluster ]
  # It is applied after what it needs: the controller, the issuer and the BGP objects.
  [ "$(depends_on gateway-public | sort | paste -sd' ' -)" = "cilium-bgp cluster-ca envoy-gateway" ]
}

@test "Plain HTTP is answered only with a redirect to HTTPS" {
  local gateway http routes route stray
  built gateway-public
  gateway="$(only "$BUILT" Gateway)"
  http="$(listener "$BUILT" http)"
  echo "http listener: $http"
  [ "$(jq -r '.port' <<<"$http")" -eq 80 ]
  [ "$(jq -r '.protocol' <<<"$http")" = HTTP ]
  # Every hostname.
  [ "$(jq -r 'has("hostname")' <<<"$http")" = false ]
  # One route attached to it, in the Gateway's own namespace.
  routes="$(GATEWAY="$gateway" yq -N 'select(.kind == "HTTPRoute" and (.spec.parentRefs
    | map(select(.name == strenv(GATEWAY) and .sectionName == "http")) | length > 0)) | .metadata.name' "$BUILT")"
  echo "routes on the http listener: ${routes:-none}"
  [ -n "$routes" ] && [ "$(wc -l <<<"$routes")" -eq 1 ]
  route="$(object "$BUILT" HTTPRoute "$routes")"
  [ "$(yq '.metadata.namespace' <<<"$route")" = "$(object "$BUILT" Gateway "$gateway" | yq '.metadata.namespace')" ]
  # It redirects to https with a 301 and forwards nowhere: no backend, no other filter.
  [ "$(yq '.spec.rules | length' <<<"$route")" -eq 1 ]
  [ "$(yq '.spec.rules[0].filters | length' <<<"$route")" -eq 1 ]
  [ "$(yq '.spec.rules[0].filters[0].type' <<<"$route")" = RequestRedirect ]
  [ "$(yq '.spec.rules[0].filters[0].requestRedirect.scheme' <<<"$route")" = https ]
  [ "$(yq '.spec.rules[0].filters[0].requestRedirect.statusCode' <<<"$route")" -eq 301 ]
  [ "$(yq '.spec.rules[0] | has("backendRefs")' <<<"$route")" = false ]
  [ "$(yq '.spec | has("hostnames")' <<<"$route")" = false ]
  # No other route anywhere in the tree attaches to the http listener.
  stray="$(grep -rl 'sectionName: http$' "$REPO"/kubernetes/apps/base --include='*.yaml' | grep -v 'gateway-public/app/' || true)"
  echo "files naming the http listener outside the Gateway's application: ${stray:-none}"
  [ -z "$stray" ]
}

@test "The HTTPS listener serves a wildcard certificate for the cluster's domain from the cluster's issuer" {
  local gateway https domain leaf ca_issuer ca bootstrap cluster_issuer secret
  built cluster-ca
  cp "$BUILT" "$BATS_TEST_TMPDIR/issuers.yaml"
  built gateway-public
  gateway="$(only "$BUILT" Gateway)"
  domain="$(var CLUSTER_DOMAIN)"
  https="$(listener "$BUILT" https)"
  echo "https listener: $https"
  [ "$(jq -r '.port' <<<"$https")" -eq 443 ]
  [ "$(jq -r '.protocol' <<<"$https")" = HTTPS ]
  [ "$(jq -r '.hostname' <<<"$https")" = "*.$domain" ]
  [ "$(jq -r '.tls.mode' <<<"$https")" = Terminate ]
  secret="$(jq -r '.tls.certificateRefs | map(select((.kind // "Secret") == "Secret")) | .[0].name' <<<"$https")"
  # The Secret is the one of the Certificate for the wildcard and the apex, in the Gateway's
  # namespace, which a listener's certificateRefs reach without a grant.
  leaf="$(only "$BUILT" Certificate)"
  object "$BUILT" Certificate "$leaf" >"$BATS_TEST_TMPDIR/leaf.yaml"
  echo "Certificate $leaf: $(yq -o json -I0 '.spec' "$BATS_TEST_TMPDIR/leaf.yaml")"
  [ "$(yq '.spec.secretName' "$BATS_TEST_TMPDIR/leaf.yaml")" = "$secret" ]
  [ "$(yq '.metadata.namespace' "$BATS_TEST_TMPDIR/leaf.yaml")" = "$(object "$BUILT" Gateway "$gateway" | yq '.metadata.namespace')" ]
  [ "$(yq '.spec.dnsNames | sort | join(" ")' "$BATS_TEST_TMPDIR/leaf.yaml")" = "$(printf '%s %s' "*.$domain" "$domain")" ]
  [ "$(yq '.spec.privateKey.algorithm' "$BATS_TEST_TMPDIR/leaf.yaml")" = ECDSA ]
  [ "$(yq '.spec.duration' "$BATS_TEST_TMPDIR/leaf.yaml")" = 2160h ]
  [ "$(yq '.spec.renewBefore' "$BATS_TEST_TMPDIR/leaf.yaml")" = 720h ]
  # It is issued by the cluster-wide CA issuer, never by the bootstrap issuer that signs the CA.
  cluster_issuer="$(only "$BATS_TEST_TMPDIR/issuers.yaml" ClusterIssuer)"
  [ "$(yq '.spec.issuerRef.group // "cert-manager.io"' "$BATS_TEST_TMPDIR/leaf.yaml")" = cert-manager.io ]
  [ "$(yq '.spec.issuerRef.kind' "$BATS_TEST_TMPDIR/leaf.yaml")" = ClusterIssuer ]
  [ "$(yq '.spec.issuerRef.name' "$BATS_TEST_TMPDIR/leaf.yaml")" = "$cluster_issuer" ]
  ca_issuer="$(object "$BATS_TEST_TMPDIR/issuers.yaml" ClusterIssuer "$cluster_issuer")"
  [ "$(yq '.spec | has("ca")' <<<"$ca_issuer")" = true ]
  ca="$(yq '.spec.ca.secretName' <<<"$ca_issuer")"
  # That CA is a certificate of the cluster's own, in cert-manager's namespace, which the
  # bootstrap issuer, a self-signed Issuer, signs.
  [ "$(only "$BATS_TEST_TMPDIR/issuers.yaml" Certificate)" ]
  object "$BATS_TEST_TMPDIR/issuers.yaml" Certificate "$(only "$BATS_TEST_TMPDIR/issuers.yaml" Certificate)" >"$BATS_TEST_TMPDIR/ca.yaml"
  echo "CA: $(yq -o json -I0 '.spec' "$BATS_TEST_TMPDIR/ca.yaml")"
  [ "$(yq '.spec.secretName' "$BATS_TEST_TMPDIR/ca.yaml")" = "$ca" ]
  [ "$(yq '.metadata.namespace' "$BATS_TEST_TMPDIR/ca.yaml")" = cert-manager ]
  [ "$(yq '.spec.isCA' "$BATS_TEST_TMPDIR/ca.yaml")" = true ]
  [ "$(yq '.spec.privateKey.algorithm' "$BATS_TEST_TMPDIR/ca.yaml")" = ECDSA ]
  [[ $(yq '.spec.privateKey.size' "$BATS_TEST_TMPDIR/ca.yaml") =~ ^(256|384)$ ]]
  [[ $(yq '.spec.duration' "$BATS_TEST_TMPDIR/ca.yaml") =~ ^[0-9]+h$ ]]
  [[ $(yq '.spec.renewBefore' "$BATS_TEST_TMPDIR/ca.yaml") =~ ^[0-9]+h$ ]]
  bootstrap="$(yq '.spec.issuerRef.name' "$BATS_TEST_TMPDIR/ca.yaml")"
  [ "$(yq '.spec.issuerRef.kind' "$BATS_TEST_TMPDIR/ca.yaml")" = Issuer ]
  [ "$(object "$BATS_TEST_TMPDIR/issuers.yaml" Issuer "$bootstrap" | yq '.spec | has("selfSigned")')" = true ]
  [ "$(object "$BATS_TEST_TMPDIR/issuers.yaml" Issuer "$bootstrap" | yq '.metadata.namespace')" = cert-manager ]
  # It waits for the controller and is Ready only once the issuer is, so the Gateway's certificate
  # finds it.
  [ "$(depends_on cluster-ca)" = cert-manager ]
  app_dir cluster-ca
  [ "$(yq '.spec.wait' "$REPO/$APP_DIR/ks.yaml")" = true ]
  # No private key is committed: the CA's is made in the cluster, and no Secret is applied.
  [ -z "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$BATS_TEST_TMPDIR/issuers.yaml" "$BUILT")" ]
  [ -z "$(grep -rl 'PRIVATE KEY' "$REPO/$APP_DIR" "$REPO/kubernetes/apps/base/envoy-gateway-system/gateway-public" || true)" ]
  # TLS 1.2 at least, which the Gateway's client traffic policy says rather than leaving to the
  # controller's default.
  local policies versions
  policies="$(yq -N 'select(.kind == "ClientTrafficPolicy") | .spec.targetRefs[] | select(.kind == "Gateway") | .name' "$BUILT")"
  [ "$policies" = "$gateway" ]
  versions="$(yq -N 'select(.kind == "ClientTrafficPolicy") | .spec.tls.minVersion' "$BUILT")"
  echo "ClientTrafficPolicy minimum TLS version: $versions"
  [[ $versions == "1.2" || $versions == "1.3" ]]
}

@test "A route attaches to the public Gateway only from a namespace that opts in" {
  local gateway https http label dir name labels attached=()
  built gateway-public
  gateway="$(only "$BUILT" Gateway)"
  https="$(listener "$BUILT" https)"
  http="$(listener "$BUILT" http)"
  echo "https allowedRoutes: $(jq -c '.allowedRoutes' <<<"$https"); http: $(jq -c '.allowedRoutes' <<<"$http")"
  # https: the namespaces a label selects, and no other; http: the Gateway's own.
  [ "$(jq -r '.allowedRoutes.namespaces.from' <<<"$https")" = Selector ]
  [ "$(jq -r '.allowedRoutes.namespaces.selector | has("matchExpressions")' <<<"$https")" = false ]
  [ "$(jq -r '.allowedRoutes.namespaces.selector.matchLabels | keys | join(",")' <<<"$https")" = k8s-gitops/gateway ]
  label="$(jq -r '.allowedRoutes.namespaces.selector.matchLabels["k8s-gitops/gateway"]' <<<"$https")"
  [ "$label" = public ]
  [ "$(jq -r '.allowedRoutes.namespaces.from' <<<"$http")" = Same ]
  # A namespace of the tree attaches to https when its labels carry the selector's pair, and the
  # demo namespace is the only one that does.
  for dir in "$REPO"/kubernetes/apps/base/*/; do
    # flux-system is the Flux Operator's, which the FluxInstance labels.
    [ -f "$dir/namespace.yaml" ] || continue
    name="$(yq '.metadata.name' "$dir/namespace.yaml")"
    labels="$(yq '.metadata.labels["k8s-gitops/gateway"] // "none"' "$dir/namespace.yaml")"
    echo "namespace $name: k8s-gitops/gateway=$labels"
    if [ "$labels" = "$label" ]; then attached+=("$name"); fi
  done
  [ "${attached[*]}" = demo ]
  # Every route that names the Gateway from another namespace is in one that attached.
  built hello-route
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .spec.parentRefs[].name' "$BUILT")" = "$gateway" ]
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .metadata.namespace' "$BUILT")" = demo ]
}

@test "The Gateway listens on exactly the ports the edge routers translate" {
  local edge gateway
  built gateway-public
  edge="$(yq -p hcl -o json "$REPO/$EDGE_FILE" | jq -c '.variable.public_ports.default | sort')"
  gateway="$(yq -N -o json -I0 'select(.kind == "Gateway") | .spec.listeners | map(.port) | unique | sort' "$BUILT")"
  echo "$GATEWAY_FILE listens on $gateway; $EDGE_FILE translates $edge"
  [ "$gateway" = "$edge" ]
}

@test "The demo application has a public hostname under the cluster's domain" {
  local route service deployment domain
  domain="$(var CLUSTER_DOMAIN)"
  built hello-route
  route="$(only "$BUILT" HTTPRoute)"
  object "$BUILT" HTTPRoute "$route" >"$BATS_TEST_TMPDIR/route.yaml"
  echo "route $route: $(yq -o json -I0 '.spec' "$BATS_TEST_TMPDIR/route.yaml")"
  [ "$(yq '.spec.hostnames | join(",")' "$BATS_TEST_TMPDIR/route.yaml")" = "hello.$domain" ]
  # On the public Gateway's https listener.
  built gateway-public
  [ "$(yq '.spec.parentRefs | length' "$BATS_TEST_TMPDIR/route.yaml")" -eq 1 ]
  [ "$(yq '.spec.parentRefs[0].name' "$BATS_TEST_TMPDIR/route.yaml")" = "$(only "$BUILT" Gateway)" ]
  [ "$(yq '.spec.parentRefs[0].namespace' "$BATS_TEST_TMPDIR/route.yaml")" = "$(object "$BUILT" Gateway "$(only "$BUILT" Gateway)" | yq '.metadata.namespace')" ]
  [ "$(yq '.spec.parentRefs[0].sectionName' "$BATS_TEST_TMPDIR/route.yaml")" = https ]
  # Backed by a Service of the same namespace that selects the pods of an unprivileged workload.
  built hello
  service="$(yq '.spec.rules[0].backendRefs[0].name' "$BATS_TEST_TMPDIR/route.yaml")"
  object "$BUILT" Service "$service" >"$BATS_TEST_TMPDIR/service.yaml"
  [ "$(yq '.spec.rules | length' "$BATS_TEST_TMPDIR/route.yaml")" -eq 1 ]
  [ "$(yq '.spec.rules[0].backendRefs[0].port' "$BATS_TEST_TMPDIR/route.yaml")" = "$(yq '.spec.ports[0].port' "$BATS_TEST_TMPDIR/service.yaml")" ]
  deployment="$(only "$BUILT" Deployment)"
  object "$BUILT" Deployment "$deployment" >"$BATS_TEST_TMPDIR/deployment.yaml"
  # The Service selects the pods the Deployment makes.
  jq -e --argjson labels "$(yq -o json -I0 '.spec.template.metadata.labels' "$BATS_TEST_TMPDIR/deployment.yaml")" \
    'to_entries | length > 0 and all(. as $e | $labels[$e.key] == $e.value)' \
    <<<"$(yq -o json -I0 '.spec.selector' "$BATS_TEST_TMPDIR/service.yaml")"
  [ "$(yq '.spec.template.spec.securityContext.runAsNonRoot' "$BATS_TEST_TMPDIR/deployment.yaml")" = true ]
  [ "$(yq '.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation' "$BATS_TEST_TMPDIR/deployment.yaml")" = false ]
  [ "$(yq '.spec.template.spec.containers[0].securityContext.capabilities.drop | join(",")' "$BATS_TEST_TMPDIR/deployment.yaml")" = ALL ]
  [ "$(yq '.spec.template.spec.securityContext.seccompProfile.type' "$BATS_TEST_TMPDIR/deployment.yaml")" = RuntimeDefault ]
  # The workload is a real one, of a pinned image, and its namespace opts in and enforces restricted.
  [[ $(yq '.spec.template.spec.containers[0].image' "$BATS_TEST_TMPDIR/deployment.yaml") =~ :[0-9][^:]*$ ]]
  [ "$(yq '.spec.replicas' "$BATS_TEST_TMPDIR/deployment.yaml")" -ge 1 ]
  [ "$(yq '.metadata.labels["k8s-gitops/gateway"]' "$REPO/kubernetes/apps/base/demo/namespace.yaml")" = public ]
  [ "$(yq '.metadata.labels["pod-security.kubernetes.io/enforce"]' "$REPO/kubernetes/apps/base/demo/namespace.yaml")" = restricted ]
  # The route is applied after the Gateway, which it names.
  [ "$(depends_on hello-route | sort | paste -sd' ' -)" = "gateway-public hello" ]
}

# tree_without APP...: copies kubernetes/ to $TREE and takes the ks.yaml of each APP out of the
# overlay's resources.
tree_without() {
  local app
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE"
  cp -r "$REPO/kubernetes" "$TREE/kubernetes"
  for app in "$@"; do
    yq -i '.resources |= map(select(test("/'"$app"'/ks.yaml$") | not))' "$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  done
}

@test "A cluster that leaves the Gateway out still builds, and a route without its Gateway is refused" {
  # The tree as it is passes, with the issuer, the Gateway and the route listed.
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  for app in cluster-ca gateway-public hello-route; do
    [ "$(yq '.resources[] | select(test("/'"$app"'/ks.yaml$"))' "$REPO/kubernetes/apps/overlays/lab-sto2/kustomization.yaml")" ] \
      || { echo "the lab-sto2 overlay does not list $app"; return 1; }
  done
  # Leaving the Gateway and its route out builds: nothing else names them.
  tree_without gateway-public hello-route
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  # Listing the route alone is refused: it names a Gateway that cluster does not enable.
  rm -rf "$TREE"
  tree_without gateway-public
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"kubernetes/apps/base/demo/hello-route/ks.yaml: Kustomization hello-route names gateway-public"* ]]
  [[ $output == *"apps/overlays/lab-sto2"* ]]
  [[ $output == *"does not enable"* ]]
}

@test "The public Gateway's proxies run on different workers and meet the namespace's Pod Security level" {
  local proxy deployment namespace spec
  built gateway-public
  proxy="$(only "$BUILT" EnvoyProxy)"
  spec="$BATS_TEST_TMPDIR/proxy.yaml"
  object "$BUILT" EnvoyProxy "$proxy" | yq '.spec.provider.kubernetes' >"$spec"
  echo "proxy deployment: $(yq -o json -I0 '.envoyDeployment' "$spec")"
  namespace="$(object "$BUILT" Gateway "$(only "$BUILT" Gateway)" | yq '.metadata.namespace')"
  # The proxies' Deployment is made by the controller at run time, so no render holds it: its
  # level is what the namespace enforces, and the fields that produce its pods are these.
  [ "$(yq '.metadata.labels["pod-security.kubernetes.io/enforce"]' "$REPO/kubernetes/apps/base/$namespace/namespace.yaml")" = restricted ]
  [ "$(yq '.envoyDeployment.replicas' "$spec")" -eq 2 ]
  # Spread over the workers, never two on one: the selector is the proxies' own labels.
  [ "$(yq '.envoyDeployment.pod.topologySpreadConstraints | length' "$spec")" -eq 1 ]
  [ "$(yq '.envoyDeployment.pod.topologySpreadConstraints[0].topologyKey' "$spec")" = kubernetes.io/hostname ]
  [ "$(yq '.envoyDeployment.pod.topologySpreadConstraints[0].maxSkew' "$spec")" -eq 1 ]
  [ "$(yq '.envoyDeployment.pod.topologySpreadConstraints[0].whenUnsatisfiable' "$spec")" = DoNotSchedule ]
  [ "$(yq '.envoyDeployment.pod.topologySpreadConstraints[0].labelSelector.matchLabels["gateway.envoyproxy.io/owning-gateway-name"]' "$spec")" \
    = "$(only "$BUILT" Gateway)" ]
  [ "$(yq '.envoyDeployment.pod.topologySpreadConstraints[0].labelSelector.matchLabels["app.kubernetes.io/name"]' "$spec")" = envoy ]
  # A drain leaves one running.
  [ "$(yq '.envoyPDB.minAvailable' "$spec")" -eq 1 ]
  # Requests, so the scheduler places the pods by what they need.
  [ -n "$(yq '.envoyDeployment.container.resources.requests.cpu // ""' "$spec")" ]
  [ -n "$(yq '.envoyDeployment.container.resources.requests.memory // ""' "$spec")" ]
  # What the restricted level asks of the pod and of the proxy container, which the controller adds
  # its own shutdown manager beside with the same hardened defaults.
  [ "$(yq '.envoyDeployment.pod.securityContext.runAsNonRoot' "$spec")" = true ]
  [ "$(yq '.envoyDeployment.pod.securityContext.runAsUser // 1' "$spec")" -ne 0 ]
  [ "$(yq '.envoyDeployment.pod.securityContext.seccompProfile.type' "$spec")" = RuntimeDefault ]
  [ "$(yq '.envoyDeployment.container.securityContext.allowPrivilegeEscalation' "$spec")" = false ]
  [ "$(yq '.envoyDeployment.container.securityContext.capabilities.drop | join(",")' "$spec")" = ALL ]
  [ "$(yq '.envoyDeployment.container.securityContext.privileged // false' "$spec")" = false ]
  [ "$(yq '.envoyDeployment.container.securityContext.runAsNonRoot' "$spec")" = true ]
  [ "$(yq '.envoyDeployment.container.securityContext.seccompProfile.type' "$spec")" = RuntimeDefault ]
  deployment="$(yq '.envoyDeployment | has("patch")' "$spec")"
  # No patch that could undo any of this.
  [ "$deployment" = false ]
}
