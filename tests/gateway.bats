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

# built APP: the application APP as Flux applies it on lab-sto2: the overlay's Kustomization of it,
# with whatever the overlay patches into it, built with the example key lists, or those of the file
# VARS names, and its own substitutions, strictly. Writes $BATS_TEST_TMPDIR/APP-built.yaml and sets
# BUILT and APP_DIR.
built() {
  local app=$1
  app_dir "$app"
  overlay
  BUILT="$BATS_TEST_TMPDIR/$app-built.yaml"
  build_from_overlay "$app" >"$BUILT"
}

# build_from_overlay APP: the objects the overlay's Kustomization of APP applies, built offline.
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

# var NAME: the value of the cluster-config variable NAME in the key lists built with: the example
# values, or those of the file VARS names.
var() {
  NAME="$1" yq -e '.[strenv(NAME)]' "${VARS:-$EXAMPLE}"
}

# other_vars: writes a copy of the example values with the Gateway's address and the domain changed
# and sets OTHER to it, so a test can build again and see that what it read came from the
# variables, not from a literal that happens to equal the example.
other_vars() {
  OTHER="$BATS_TEST_TMPDIR/other-vars.yaml"
  GATEWAY_ADDRESS=203.0.113.77 CLUSTER_DOMAIN=other.example.org \
    yq '.GATEWAY_ADDRESS = strenv(GATEWAY_ADDRESS) | .CLUSTER_DOMAIN = strenv(CLUSTER_DOMAIN)' "$EXAMPLE" >"$OTHER"
}

# overlay: the lab-sto2 overlay as Flux reads it, its namespaces and the Kustomization of each
# enabled application, so what a test reads is what an overlay patch would have changed too.
# Writes $OVERLAY.
overlay() {
  OVERLAY="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "$REPO/kubernetes/apps/overlays/lab-sto2" >"$OVERLAY"
}

# everything: the lab-sto2 overlay's build and every application it enables, each built as Flux
# applies it from the overlay's Kustomization, with the example key lists and its own substitutions,
# all in one file. Writes $EVERYTHING.
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

# parents_of FILE GATEWAY NAMESPACE SELECT: kind/namespace/name of every object in FILE, of any
# kind, with a parentRef to the Gateway GATEWAY in NAMESPACE that the yq condition SELECT, applied
# to the parentRef, holds for.
parents_of() {
  # shellcheck disable=SC2016 # $own is a yq variable.
  GATEWAY="$2" NS="$3" yq -N 'select(.spec.parentRefs != null) | (.metadata.namespace // "") as $own
    | select(.spec.parentRefs | map(select(.name == strenv(GATEWAY)
        and (.group // "gateway.networking.k8s.io") == "gateway.networking.k8s.io"
        and (.kind // "Gateway") == "Gateway"
        and (.namespace // $own) == strenv(NS)
        and ('"$4"'))) | length > 0)
    | .kind + "/" + .metadata.namespace + "/" + .metadata.name' "$1"
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

# depends_on APP: the names the overlay's Kustomization of APP lists in dependsOn, one per line.
depends_on() {
  overlay
  APP="$1" yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(APP)) | .spec.dependsOn // [] | .[].name' "$OVERLAY"
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
  # Nothing else is set on the Service: no patch over the fields above, and nothing, such as a
  # loadBalancerClass or a loadBalancerIP, that would take its address from anything but the pool.
  [ "$(yq -o json -I0 'keys | sort' "$service")" = '["annotations","externalTrafficPolicy","labels","type"]' ]
  # The address comes from the variable: built with another value, the annotation follows it.
  other_vars
  VARS="$OTHER" built gateway-public
  [ "$(object "$BUILT" EnvoyProxy "$proxy" | yq '.spec.provider.kubernetes.envoyService.annotations["lbipam.cilium.io/ips"]')" \
    = "$(VARS="$OTHER" var GATEWAY_ADDRESS)" ]
  # It is applied after what it needs: the controller, the issuer and the BGP objects.
  [ "$(depends_on gateway-public | sort | paste -sd' ' -)" = "cilium-bgp cluster-ca envoy-gateway" ]
  # Nothing else can take the address first: of everything the cluster applies, built with an
  # address of its own, only this EnvoyProxy carries the label outside a selector, asks Cilium for
  # an address by annotation, or names the Gateway's address anywhere.
  local holders
  VARS="$OTHER" everything
  # shellcheck disable=SC2016 # $address, $o and $p are jq variables.
  holders="$(yq -N -o json -I0 '.' "$EVERYTHING" | jq -rs --arg address "$(VARS="$OTHER" var GATEWAY_ADDRESS)" '
    ($address | gsub("\\."; "\\.")) as $pattern
    | .[] | objects | . as $o | paths as $p
    | select(($p[-1] == "k8s-gitops/announce" and ([$p[] | tostring | test("[sS]elector|matchLabels")] | any | not))
        or $p[-1] == "lbipam.cilium.io/ips"
        or (($o | getpath($p) | type) == "string" and ($o | getpath($p) | test("(^|[^0-9.])" + $pattern + "([^0-9]|$)"))))
    | "\($o.kind)/\($o.metadata.name): \($p | map(tostring) | join("."))"' | sort -u)"
  echo "what carries the label or names the address: $holders"
  [ "$holders" = "$(printf '%s\n' "EnvoyProxy/$proxy: spec.provider.kubernetes.envoyService.annotations.lbipam.cilium.io/ips" \
    "EnvoyProxy/$proxy: spec.provider.kubernetes.envoyService.labels.k8s-gitops/announce")" ]
}

@test "Plain HTTP is answered only with a redirect to HTTPS" {
  local gateway http named unnamed spec expected namespace
  built gateway-public
  gateway="$(only "$BUILT" Gateway)"
  namespace="$(object "$BUILT" Gateway "$gateway" | yq '.metadata.namespace')"
  http="$(listener "$BUILT" http)"
  echo "http listener: $http"
  [ "$(jq -r '.port' <<<"$http")" -eq 80 ]
  [ "$(jq -r '.protocol' <<<"$http")" = HTTP ]
  # Every hostname.
  [ "$(jq -r 'has("hostname")' <<<"$http")" = false ]
  # HTTPRoutes only: an HTTP listener that names no kinds admits GRPCRoutes as well.
  [ "$(jq -c '.allowedRoutes.kinds // [] | map({group: (.group // "gateway.networking.k8s.io"), kind})' <<<"$http")" \
    = '[{"group":"gateway.networking.k8s.io","kind":"HTTPRoute"}]' ]
  # Of everything the cluster applies, routes of any kind (whatever has parentRefs), one names the
  # http listener, by its section or its port: the redirect, in the Gateway's own namespace.
  everything
  named="$(parents_of "$EVERYTHING" "$gateway" "$namespace" '.sectionName == "http" or (.sectionName == null and .port == 80)')"
  echo "routes that name the http listener: ${named:-none}"
  [ "$named" = "HTTPRoute/$namespace/https-redirect" ]
  # A parentRef that names no section attaches to every listener that allows its namespace, and
  # http allows the Gateway's own: no route there names the Gateway without a section.
  unnamed="$(parents_of "$EVERYTHING" "$gateway" "$namespace" '.sectionName == null' | grep "^[^/]*/$namespace/" || true)"
  echo "routes in $namespace that name no listener: ${unnamed:-none}"
  [ -z "$unnamed" ]
  # It redirects every path to https on the same host and the scheme's default port, with a 301,
  # and forwards nowhere: one rule, matching everything, with that one filter and no backend.
  spec="$(object "$BUILT" HTTPRoute https-redirect | yq -o json -I0 '.spec' \
    | jq -cS '.rules |= map(if .matches == [{"path": {"type": "PathPrefix", "value": "/"}}] then del(.matches) else . end)')"
  expected="$(jq -cnS --arg gateway "$gateway" '{parentRefs: [{name: $gateway, sectionName: "http"}],
    rules: [{filters: [{type: "RequestRedirect", requestRedirect: {scheme: "https", statusCode: 301}}]}]}')"
  echo "redirect: $spec"
  [ "$spec" = "$expected" ]
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
  # Only the https listener and the http one: a further listener would be an unreviewed way in.
  [ "$(yq -N '.spec.listeners | map(.name) | sort | join(" ")' <(object "$BUILT" Gateway "$gateway"))" = "http https" ]
  secret="$(jq -r '.tls.certificateRefs | map(select((.kind // "Secret") == "Secret")) | .[0].name' <<<"$https")"
  # In the Gateway's namespace, which a listener reaches without a ReferenceGrant.
  [ "$(jq -r '.tls.certificateRefs | length' <<<"$https")" -eq 1 ]
  [ "$(jq -r '.tls.certificateRefs[0].namespace // ""' <<<"$https")" = "" ] \
    || [ "$(jq -r '.tls.certificateRefs[0].namespace' <<<"$https")" = "$(object "$BUILT" Gateway "$gateway" | yq '.metadata.namespace')" ]
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
  # The names come from the variable: built with another domain they follow it.
  other_vars
  VARS="$OTHER" built gateway-public
  [ "$(listener "$BUILT" https | jq -r '.hostname')" = "*.$(VARS="$OTHER" var CLUSTER_DOMAIN)" ]
  [ "$(object "$BUILT" Certificate "$leaf" | yq '.spec.dnsNames | sort | join(" ")')" \
    = "$(printf '%s %s' "*.$(VARS="$OTHER" var CLUSTER_DOMAIN)" "$(VARS="$OTHER" var CLUSTER_DOMAIN)")" ]
  built gateway-public
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
  overlay
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "cluster-ca") | .spec.wait' "$OVERLAY")" = true ]
  # No private key is committed: the CA's is made in the cluster, and no Secret is applied.
  [ -z "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$BATS_TEST_TMPDIR/issuers.yaml" "$BUILT")" ]
  [ -z "$(grep -rl 'PRIVATE KEY' "$REPO/$APP_DIR" "$REPO/kubernetes/apps/base/envoy-gateway-system/gateway-public" || true)" ]
  # TLS 1.2 at least, which the Gateway's client traffic policy says rather than leaving to the
  # controller's default, and nothing more: another field, such as proxyProtocol, would change what
  # every client must send.
  local policy namespace targeting
  namespace="$(object "$BUILT" Gateway "$gateway" | yq '.metadata.namespace')"
  policy="$(object "$BUILT" ClientTrafficPolicy "$(only "$BUILT" ClientTrafficPolicy)" | yq -o json -I0 '.spec' | jq -cS .)"
  echo "ClientTrafficPolicy: $policy"
  [ "$policy" = "$(jq -cnS --arg gateway "$gateway" '{targetRefs: [{group: "gateway.networking.k8s.io", kind: "Gateway", name: $gateway}],
    tls: {minVersion: "1.2"}}')" ]
  # It is the one policy on the Gateway or on a route attached to it: of everything the cluster
  # applies, no other object's targetRef, targetRefs or targetSelectors names the Gateway or such a
  # route, and none selects a Gateway or a route by its labels.
  everything
  # shellcheck disable=SC2016 # $gateway, $namespace, $routes, $p and $own are jq variables.
  targeting="$(yq -N -o json -I0 '.' "$EVERYTHING" | jq -rs --arg gateway "$gateway" --arg namespace "$namespace" '
    [.[] | objects] as $all
    | [$all[] | select(.spec.parentRefs? != null) | .metadata.namespace as $own
        | select(any(.spec.parentRefs[]; .name == $gateway and (.kind // "Gateway") == "Gateway"
            and (.namespace // $own) == $namespace))
        | {namespace: $own, kind, name: .metadata.name}] as $routes
    | $all[] | . as $p | ($p.metadata.namespace // "") as $own
    | select(($p.spec | type) == "object")
    | select(any(([$p.spec.targetRef // empty] + ($p.spec.targetRefs // []))[];
          (.kind == "Gateway" and .name == $gateway and $own == $namespace)
          or ((.kind | tostring | endswith("Route")) and ({namespace: $own, kind, name} | IN($routes[]))))
        or any($p.spec.targetSelectors[]?; .kind == "Gateway" or (.kind | tostring | endswith("Route"))))
    | "\($p.kind)/\($own)/\($p.metadata.name)"')"
  echo "policies on the Gateway or its routes: $targeting"
  [ "$targeting" = "ClientTrafficPolicy/$namespace/$(only "$BUILT" ClientTrafficPolicy)" ]
}

@test "A route attaches to the public Gateway only from a namespace that opts in" {
  local gateway https http label name labels attached=()
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
  # Each listener names the one kind of route it takes, HTTPRoute, rather than every kind its
  # protocol admits.
  [ "$(jq -c '.allowedRoutes.kinds // [] | map({group: (.group // "gateway.networking.k8s.io"), kind})' <<<"$https")" \
    = '[{"group":"gateway.networking.k8s.io","kind":"HTTPRoute"}]' ]
  [ "$(jq -c '.allowedRoutes.kinds // [] | map({group: (.group // "gateway.networking.k8s.io"), kind})' <<<"$http")" \
    = '[{"group":"gateway.networking.k8s.io","kind":"HTTPRoute"}]' ]
  # No ListenerSet adds a listener: the Gateway allows none, the API's default, and nothing the
  # cluster applies names it as a ListenerSet's parent.
  local listener_sets
  [ "$(object "$BUILT" Gateway "$gateway" | yq '.spec.allowedListeners.namespaces.from // "None"')" = None ]
  everything
  listener_sets="$(GATEWAY="$gateway" yq -N 'select(.spec.parentRef != null and .spec.parentRef.name == strenv(GATEWAY))
    | .kind + "/" + .metadata.namespace + "/" + .metadata.name' "$EVERYTHING")"
  echo "what names the Gateway as its parent: ${listener_sets:-nothing}"
  [ -z "$listener_sets" ]
  # A namespace of the cluster attaches to https when its labels, as the overlay builds them,
  # carry the selector's pair, and the demo namespace is the only one that does.
  overlay
  while IFS=$'\t' read -r name labels; do
    echo "namespace $name: k8s-gitops/gateway=$labels"
    if [ "$labels" = "$label" ]; then attached+=("$name"); fi
  done < <(yq -N 'select(.kind == "Namespace") | .metadata.name + "\t" + (.metadata.labels["k8s-gitops/gateway"] // "none")' "$OVERLAY")
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
  # The hostname comes from the variable: built with another domain it follows it.
  other_vars
  VARS="$OTHER" built hello-route
  [ "$(object "$BUILT" HTTPRoute "$route" | yq '.spec.hostnames | join(",")')" = "hello.$(VARS="$OTHER" var CLUSTER_DOMAIN)" ]
  built hello-route
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
  # The Service's target is a port the workload's container declares, by name or number.
  [ -n "$(TARGET="$(yq '.spec.ports[0].targetPort' "$BATS_TEST_TMPDIR/service.yaml")" \
    yq '.spec.template.spec.containers[].ports[] | select(.name == strenv(TARGET) or (.containerPort | tostring) == strenv(TARGET)) | .name' \
    "$BATS_TEST_TMPDIR/deployment.yaml")" ]
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
  # Two replicas that a drain or a node's loss cannot take together: spread over the hostnames,
  # and a budget that keeps one running.
  [ "$(yq '.spec.replicas' "$BATS_TEST_TMPDIR/deployment.yaml")" -eq 2 ]
  [ "$(yq '.spec.template.spec.topologySpreadConstraints | map(select(.topologyKey == "kubernetes.io/hostname" and .whenUnsatisfiable == "DoNotSchedule" and .maxSkew == 1)) | length' "$BATS_TEST_TMPDIR/deployment.yaml")" -eq 1 ]
  jq -e --argjson labels "$(yq -o json -I0 '.spec.template.metadata.labels' "$BATS_TEST_TMPDIR/deployment.yaml")" \
    'to_entries | length > 0 and all(. as $e | $labels[$e.key] == $e.value)' \
    <<<"$(yq -o json -I0 '.spec.template.spec.topologySpreadConstraints[0].labelSelector.matchLabels' "$BATS_TEST_TMPDIR/deployment.yaml")"
  [ "$(yq -N 'select(.kind == "PodDisruptionBudget") | .spec.minAvailable' "$BUILT")" -eq 1 ]
  jq -e --argjson labels "$(yq -o json -I0 '.spec.template.metadata.labels' "$BATS_TEST_TMPDIR/deployment.yaml")" \
    'to_entries | length > 0 and all(. as $e | $labels[$e.key] == $e.value)' \
    <<<"$(yq -N -o json -I0 'select(.kind == "PodDisruptionBudget") | .spec.selector.matchLabels' "$BUILT")"
  overlay
  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "demo") | .metadata.labels["k8s-gitops/gateway"]' "$OVERLAY")" = public ]
  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "demo") | .metadata.labels["pod-security.kubernetes.io/enforce"]' "$OVERLAY")" = restricted ]
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
  overlay
  [ "$(NS="$namespace" yq -N 'select(.kind == "Namespace" and .metadata.name == strenv(NS)) | .metadata.labels["pod-security.kubernetes.io/enforce"]' "$OVERLAY")" = restricted ]
  [ "$(yq '.envoyDeployment.replicas' "$spec")" -eq 2 ]
  # No autoscaler: the controller drops the replica count when one is set, and two proxies on two
  # workers are what the spread below asks for.
  [ "$(yq 'has("envoyHpa")' "$spec")" = false ]
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
