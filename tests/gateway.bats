#!/usr/bin/env bats
# Proves features/gateway.feature; each test carries its scenario's title.
# Needs kustomize, flux, yq and jq on PATH (the versions pinned for the repository). Everything is
# built offline, as Flux applies it, with the placeholders of the cluster's example key lists.

# flux build rewrites the kustomization.yaml of the application it builds in this checkout and puts
# it back afterwards, so two builds at once could leave the rewritten file behind.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

# tree_without, a copy of the tree whose overlay leaves applications out.
load fixtures/tree-without

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

# built_default APP: the application APP as its own ks.yaml has it, with no patch of any overlay,
# which is what a cluster that chooses nothing gets. Writes $BATS_TEST_TMPDIR/APP-default.yaml and
# sets BUILT and APP_DIR.
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
# The edge routers' proxy configuration, whose limits the Gateway's listeners follow, and the rate
# limit component.
EDGE_PROXY_FILE=infra/openstack/stacks/sto2/edge/haproxy.cfg.tftpl
RATELIMIT=kubernetes/components/ratelimit

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
  # It is applied after what it needs: the controller, the issuer, the BGP objects and the exporter
  # that answers its Probe, and, where the cluster chooses an ACME issuer for its certificate, the
  # application that makes the issuers.
  [ "$(yq '.spec.dependsOn | map(.name) | sort | join(" ")' "$REPO/$APP_DIR/ks.yaml")" = "blackbox-exporter cilium-bgp cluster-ca envoy-gateway" ]
  [ "$(depends_on gateway-public | sort | paste -sd' ' -)" = "acme-issuers blackbox-exporter cilium-bgp cluster-ca envoy-gateway" ]
  # Nothing else can take the address first: of everything the cluster applies, built with an
  # address of its own, only this EnvoyProxy carries the label outside a selector, sets an LB-IPAM
  # annotation or names the Gateway's address anywhere, and no text, such as the values a chart
  # takes from a ConfigMap, holds the label's key or an LB-IPAM key.
  local holders references namespace
  namespace="$(object "$BUILT" Gateway "$gateway" | yq '.metadata.namespace')"
  VARS="$OTHER" everything
  # shellcheck disable=SC2016 # $address, $pattern, $o, $p, $v and $key are jq variables.
  holders="$(yq -N -o json -I0 '.' "$EVERYTHING" | jq -rs --arg address "$(VARS="$OTHER" var GATEWAY_ADDRESS)" '
    ($address | gsub("\\."; "\\.")) as $pattern
    | .[] | objects | . as $o | paths as $p | ($o | getpath($p)) as $v | ($p[-1] | tostring) as $key
    | select(($key == "k8s-gitops/announce" and ([$p[] | tostring | test("[sS]elector|matchLabels")] | any | not))
        or ($key | startswith("lbipam.cilium.io/")) or ($key | startswith("io.cilium/lb-ipam"))
        or (($v | type) == "string" and (($v | test("(^|[^0-9.])" + $pattern + "([^0-9]|$)"))
          or ($v | test("k8s-gitops/announce|lbipam\\.cilium\\.io/|io\\.cilium/lb-ipam")))))
    | "\($o.kind)/\($o.metadata.name): \($p | map(tostring) | join("."))"' | sort -u)"
  echo "what carries the label or names the address: $holders"
  [ "$holders" = "$(printf '%s\n' "EnvoyProxy/$proxy: spec.provider.kubernetes.envoyService.annotations.lbipam.cilium.io/ips" \
    "EnvoyProxy/$proxy: spec.provider.kubernetes.envoyService.labels.k8s-gitops/announce")" ]
  # And only this Gateway makes the controller apply that EnvoyProxy: no other Gateway, and no
  # GatewayClass, names it in a parametersRef, so no second Service asks for the address.
  # shellcheck disable=SC2016 # $proxy, $namespace, $o, $own and $p are jq variables.
  references="$(yq -N -o json -I0 '.' "$EVERYTHING" | jq -rs --arg proxy "$proxy" --arg namespace "$namespace" '
    .[] | objects | . as $o | ($o.metadata.namespace // "") as $own
    | select(any(paths | select(.[-1] == "parametersRef") as $p | $o | getpath($p) | objects;
        .kind == "EnvoyProxy" and .name == $proxy and (.namespace // $own) == $namespace))
    | "\($o.kind)/\($own)/\($o.metadata.name)"')"
  echo "what names the EnvoyProxy: $references"
  [ "$references" = "Gateway/$namespace/$gateway" ]
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
  # With nothing chosen, as a cluster that says nothing gets it: the cluster's own CA issues it.
  built_default gateway-public
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
  # Renewed with two fifths of the lifetime left, which holds whatever lifetime the CA gives and is
  # above the third gateway-check fails below, and with a new key.
  [ "$(yq '.spec | has("renewBefore")' "$BATS_TEST_TMPDIR/leaf.yaml")" = false ]
  [ "$(yq '.spec.renewBeforePercentage' "$BATS_TEST_TMPDIR/leaf.yaml")" -eq 40 ]
  [ "$(yq '.spec.privateKey.rotationPolicy' "$BATS_TEST_TMPDIR/leaf.yaml")" = Always ]
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
  # controller's default, and the PROXY protocol as optional, and nothing more: any other field
  # would change what every client must send.
  local policy namespace targeting
  namespace="$(object "$BUILT" Gateway "$gateway" | yq '.metadata.namespace')"
  policy="$(object "$BUILT" ClientTrafficPolicy "$(only "$BUILT" ClientTrafficPolicy)" | yq -o json -I0 '.spec' | jq -cS .)"
  echo "ClientTrafficPolicy: $policy"
  # The listener limits are the policy's other three keys, which the scenario of what one client
  # connection may hold pins.
  [ "$(jq -cS 'del(.connection, .http2, .timeout)' <<<"$policy")" = "$(jq -cnS --arg gateway "$gateway" '{targetRefs: [{group: "gateway.networking.k8s.io", kind: "Gateway", name: $gateway}],
    proxyProtocol: {optional: true}, tls: {minVersion: "1.2"}}')" ]
  [ "$(jq -c 'keys' <<<"$policy")" = '["connection","http2","proxyProtocol","targetRefs","timeout","tls"]' ]
  # It is the one policy on the Gateway, and the only one on a route attached to it but the sign-in's
  # and the web application firewall's below: of everything the cluster applies, no other object's
  # targetRef, targetRefs or targetSelectors names the Gateway or such a route, and none selects a
  # Gateway or a route by its labels.
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
  # Each route that opts in to the cluster's sign-in (features/sso.feature) has the one
  # SecurityPolicy that asks oauth2-proxy about its requests, the one route behind the web
  # application firewall (features/waf.feature) the EnvoyExtensionPolicy that runs it, and each
  # route that takes a rate limit the BackendTrafficPolicy that holds it; they are named here, not
  # found in the tree, so a policy on the Gateway or on any other route is a failure. A route that
  # opts in later adds its policy to this list.
  [ "$(sort <<<"$targeting")" = "$({ printf '%s\n' "ClientTrafficPolicy/$namespace/$(only "$BUILT" ClientTrafficPolicy)" SecurityPolicy/demo/hello-sso \
    SecurityPolicy/monitoring/logs EnvoyExtensionPolicy/demo/hello \
    SecurityPolicy/locust/locust \
    BackendTrafficPolicy/demo/hello BackendTrafficPolicy/demo/hello-sso BackendTrafficPolicy/kromgo/kromgo \
    SecurityPolicy/reportportal/reportportal; } | sort)" ]
  # Nor does anything patch around it: no EnvoyPatchPolicy anywhere, which rewrites the translated
  # configuration of a Gateway, or of every Gateway of its class, whatever the policies say.
  local patches forwarded
  patches="$(yq -N 'select(.kind == "EnvoyPatchPolicy") | .kind + "/" + .metadata.namespace + "/" + .metadata.name' "$EVERYTHING")"
  echo "patch policies: ${patches:-none}"
  [ -z "$patches" ]
  # And no filter of a route attached to the Gateway, on a rule or on a backend, sets, adds or
  # removes x-forwarded-for, which would change what a backend reads as the client's address: a
  # request header modifier, or an extension filter that injects a credential into that header.
  # shellcheck disable=SC2016 # $gateway, $namespace, $all, $own, $route and $ref are jq variables.
  forwarded="$(yq -N -o json -I0 '.' "$EVERYTHING" | jq -rs --arg gateway "$gateway" --arg namespace "$namespace" '
    [.[] | objects] as $all
    | $all[] | select(.spec.parentRefs? != null) | . as $route | .metadata.namespace as $own
    | select(any(.spec.parentRefs[]; .name == $gateway and (.kind // "Gateway") == "Gateway"
        and (.namespace // $own) == $namespace))
    | [.spec.rules[]? | .filters[]?, .backendRefs[]?.filters[]?] as $filters
    | [($filters[].requestHeaderModifier // empty | .set[]?.name, .add[]?.name, .remove[]?),
        ($filters[] | select(.type == "ExtensionRef") | .extensionRef as $ref
          | $all[] | select(.kind == "HTTPRouteFilter" and .kind == $ref.kind
              and .metadata.namespace == $own and .metadata.name == $ref.name)
          | .spec.credentialInjection.header // empty)]
    | select(any(.[]; ascii_downcase == "x-forwarded-for"))
    | "\($route.kind)/\($own)/\($route.metadata.name)"')"
  echo "routes whose filters set or remove x-forwarded-for: ${forwarded:-none}"
  [ -z "$forwarded" ]
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
  # carry the selector's pair, and the namespaces of the applications that have a route are the
  # only ones that do.
  overlay
  while IFS=$'\t' read -r name labels; do
    echo "namespace $name: k8s-gitops/gateway=$labels"
    if [ "$labels" = "$label" ]; then attached+=("$name"); fi
  done < <(yq -N 'select(.kind == "Namespace") | .metadata.name + "\t" + (.metadata.labels["k8s-gitops/gateway"] // "none")' "$OVERLAY")
  [ "${attached[*]}" = "ai-system ascender backstage demo kromgo locust monitoring reportportal sso-system" ]
  # Every route that names the Gateway from another namespace is in one that attached.
  built hello-route
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .spec.parentRefs[].name' "$BUILT")" = "$gateway" ]
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .metadata.namespace' "$BUILT")" = demo ]
  built n8n
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .spec.parentRefs[].name' "$BUILT")" = "$gateway" ]
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .metadata.namespace' "$BUILT")" = ai-system ]
  built kromgo
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .spec.parentRefs[].name' "$BUILT")" = "$gateway" ]
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .metadata.namespace' "$BUILT")" = kromgo ]
  built open-webui
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .spec.parentRefs[].name' "$BUILT")" = "$gateway" ]
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .metadata.namespace' "$BUILT")" = ai-system ]
  built backstage
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .spec.parentRefs[].name' "$BUILT")" = "$gateway" ]
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .metadata.namespace' "$BUILT")" = backstage ]
  built ascender
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .spec.parentRefs[].name' "$BUILT")" = "$gateway" ]
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .metadata.namespace' "$BUILT")" = ascender ]
  # The log store's route and its sign-in route.
  built victoria-logs-route
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .spec.parentRefs[].name' "$BUILT" | sort -u)" = "$gateway" ]
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .metadata.namespace' "$BUILT" | sort -u)" = monitoring ]
  # Locust's route and its sign-in route.
  built locust-route
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .spec.parentRefs[].name' "$BUILT" | sort -u)" = "$gateway" ]
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .metadata.namespace' "$BUILT" | sort -u)" = locust ]
  # ReportPortal's route and its sign-in route.
  built reportportal-route
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .spec.parentRefs[].name' "$BUILT" | sort -u)" = "$gateway" ]
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .metadata.namespace' "$BUILT" | sort -u)" = reportportal ]
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
  [ "$(depends_on hello-route | sort | paste -sd' ' -)" = "blackbox-exporter gateway-public hello" ]
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
  # Leaving the Gateway, the applications that have a route on it, the DNS records of their routes
  # and the dashboard of those records, and CrowdSec, whose agent reads the Gateway's proxies, out
  # builds: nothing else names them but Robot Framework's suite of Ascender's sign-in page,
  # robot-ascender, which names ascender and goes with it. Locust's and ReportPortal's routes go, and
  # Locust and ReportPortal stay.
  tree_without gateway-public hello-route n8n kromgo external-dns open-webui hello-sso dex oauth2-proxy backstage crowdsec crowdsec-gateway-logs victoria-logs-route external-dns-dashboard ascender robot-ascender \
    locust-route reportportal-route
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

@test "The public Gateway takes a client's address from a PROXY protocol header and still serves a connection without one" {
  local gateway policy spec
  built gateway-public
  gateway="$(only "$BUILT" Gateway)"
  policy="$(only "$BUILT" ClientTrafficPolicy)"
  spec="$BATS_TEST_TMPDIR/policy.yaml"
  object "$BUILT" ClientTrafficPolicy "$policy" | yq '.spec' >"$spec"
  echo "ClientTrafficPolicy $policy: $(yq -o json -I0 '.' "$spec")"
  # Accepted, not required: Envoy's PROXY protocol listener filter lets a connection through that
  # does not start with a header only when the listener allows requests without one, which is
  # `optional`. Required, a connection from a sender that writes no header would be cut.
  [ "$(yq '.proxyProtocol.optional' "$spec")" = true ]
  # Nothing else of it: forwardProtoConfig would set x-forwarded-proto from the header's
  # destination port, which the listeners' own protocols already decide.
  [ "$(yq -o json -I0 '.proxyProtocol | keys' "$spec")" = '["optional"]' ]
  # The deprecated boolean can only require the header.
  [ "$(yq 'has("enableProxyProtocol")' "$spec")" = false ]
  # On the Gateway as a whole, so both listeners take it: a section name would leave the other
  # without the filter, which then reads a sender's header as the start of a request and refuses it.
  [ "$(yq '.targetRefs | length' "$spec")" -eq 1 ]
  [ "$(yq '.targetRefs[0] | .kind + "/" + .name + "/" + (.sectionName // "")' "$spec")" = "Gateway/$gateway/" ]
  [ "$(yq 'has("targetRef") or has("targetSelectors")' "$spec")" = false ]
  [ "$(object "$BUILT" Gateway "$gateway" | yq '.spec.listeners | map(.name) | sort | join(" ")')" = "http https" ]
  # No client IP detection: without it the controller has the connection manager use the
  # connection's remote address, which the PROXY header replaces when there is one, and never read
  # the client's own x-forwarded-for for it. Any xForwardedFor setting, trusted hops or CIDRs, or a
  # custom header, would hand that choice to the request.
  [ "$(yq 'has("clientIPDetection")' "$spec")" = false ]
}

@test "The proxies' access log names the client address, host, method, path, status and duration of each request, and no query string" {
  local proxy log key value
  built gateway-public
  proxy="$(only "$BUILT" EnvoyProxy)"
  log="$BATS_TEST_TMPDIR/accesslog.yaml"
  object "$BUILT" EnvoyProxy "$proxy" | yq '.spec.telemetry.accessLog' >"$log"
  echo "access log of $proxy: $(yq -o json -I0 '.' "$log")"
  [ "$(yq '.disable // false' "$log")" = false ]
  # One setting that matches everything: no type, which logs every route's requests and, through
  # the listener, those no route took; no CEL match.
  [ "$(yq '.settings | length' "$log")" -eq 1 ]
  [ "$(yq '.settings[0] | (has("type") or has("matches"))' "$log")" = false ]
  # JSON, to standard output, where the log collector reads the container's lines.
  [ "$(yq '.settings[0].format.type' "$log")" = JSON ]
  [ "$(yq '.settings[0].sinks | length' "$log")" -eq 1 ]
  [ "$(yq '.settings[0].sinks[0].type + " " + .settings[0].sinks[0].file.path' "$log")" = "File /dev/stdout" ]
  # The fields, with the operator that fills each. The client address is the one Envoy took, which
  # is the PROXY header's source when the connection carried one; the peer is the socket's, the
  # sender of that claim.
  [ "$(yq -o json -I0 '.settings[0].format.json | keys' "$log")" \
    = '["bytes_received","bytes_sent","client_address","duration_ms","host","method","path","peer_address","response_flags","status"]' ]
  field() { yq ".settings[0].format.json.$1" "$log"; }
  [ "$(field client_address)" = '%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%' ]
  [ "$(field peer_address)" = '%DOWNSTREAM_DIRECT_REMOTE_ADDRESS_WITHOUT_PORT%' ]
  [ "$(field host)" = '%REQ(:AUTHORITY)%' ]
  [ "$(field method)" = '%REQ(:METHOD)%' ]
  [ "$(field status)" = '%RESPONSE_CODE%' ]
  [ "$(field duration_ms)" = '%DURATION%' ]
  [ "$(field bytes_sent)" = '%BYTES_SENT%' ]
  [ "$(field bytes_received)" = '%BYTES_RECEIVED%' ]
  [ "$(field response_flags)" = '%RESPONSE_FLAGS%' ]
  # The path leaves out the query string, which can hold a secret.
  [ "$(field path)" = '%REQ_WITHOUT_QUERY(X-ENVOY-ORIGINAL-PATH?:PATH)%' ]
  # No field carries a query string or the client's own x-forwarded-for: whatever names the path
  # does so through the operator that drops the query, and none names the header.
  while IFS=$'\t' read -r key value; do
    echo "$key: $value"
    if [[ ${value^^} == *PATH* ]]; then [[ $value == '%REQ_WITHOUT_QUERY('* ]]; fi
    [[ ${value^^} != *FORWARDED-FOR* ]]
  done < <(yq '.settings[0].format.json | to_entries | .[] | .key + "\t" + .value' "$log")
}

# component_header DIR: the ks.yaml block the header of the component in DIR shows, as YAML.
component_header() {
  sed -n '/^#   components:$/,/^#$/p' "$REPO/$1/kustomization.yaml" | sed -e '/^#$/d' -e 's/^#   //'
}

# ratelimit_takers FILE...: each Flux Kustomization of FILE... that takes the rate limit component,
# as its file, name, target namespace and the RATELIMIT_ variables it substitutes as JSON, a tab
# between each, one a line. It takes the component when one of its components, resolved from its
# spec.path as Flux resolves it, is the component's directory, however the path is written.
ratelimit_takers() {
  local own entry path component
  own="$(realpath -m -- "$REPO/$RATELIMIT")"
  # shellcheck disable=SC2016 # $k is a yq variable.
  yq -N -o json -I0 'select(.kind == "Kustomization") | . as $k | (.spec.components // [])[]
    | {"file": filename, "name": $k.metadata.name, "namespace": ($k.spec.targetNamespace // $k.metadata.namespace // ""),
       "variables": ($k.spec.postBuild.substitute // {} | with_entries(select(.key | test("^RATELIMIT_")))),
       "path": ($k.spec.path // "."), "component": .}' "$@" |
    while IFS= read -r entry; do
      path="$(jq -r '.path' <<<"$entry")" component="$(jq -r '.component' <<<"$entry")"
      [ "$(realpath -m -- "$REPO/kubernetes/${path#./}/$component")" = "$own" ] || continue
      jq -r '[.file, .name, .namespace, (.variables | tojson)] | join("\t")' <<<"$(jq -cS . <<<"$entry")"
    done
}

# milliseconds DURATION: DURATION in milliseconds, written as HAProxy writes one, a bare number of
# milliseconds, or as a Gateway API duration, numbers each followed by h, m, s or ms.
milliseconds() {
  local rest=$1 total=0
  if [[ $rest =~ ^[0-9]+$ ]]; then
    echo "$rest"
    return
  fi
  while [[ $rest =~ ^([0-9]+)(ms|h|m|s)(.*)$ ]]; do
    case ${BASH_REMATCH[2]} in
      h) total=$((total + BASH_REMATCH[1] * 3600000)) ;;
      m) total=$((total + BASH_REMATCH[1] * 60000)) ;;
      s) total=$((total + BASH_REMATCH[1] * 1000)) ;;
      ms) total=$((total + BASH_REMATCH[1])) ;;
    esac
    rest=${BASH_REMATCH[3]}
  done
  [ -n "$1" ] && [ -z "$rest" ] || { echo "not a duration: $1" >&2; return 1; }
  echo "$total"
}

@test "A route opts into a request rate limit with one component, at 300 requests a minute unless its ks.yaml says otherwise" {
  local component="$REPO/$RATELIMIT" policy="$REPO/$RATELIMIT/backendtrafficpolicy.yaml" health takers file name namespace
  local route figure unit expected found
  local -a files
  [ -f "$component/kustomization.yaml" ] || { echo "there is no component $RATELIMIT"; return 1; }
  # A Component of one BackendTrafficPolicy and nothing else.
  [ "$(yq '.kind' "$component/kustomization.yaml")" = Component ]
  [ "$(yq -o json -I0 'keys' "$component/kustomization.yaml")" = '["apiVersion","kind","resources"]' ]
  [ "$(yq -o json -I0 '.resources' "$component/kustomization.yaml")" = '["backendtrafficpolicy.yaml"]' ]
  [ "$(find "$component" -type f | sort | sed "s|^$component/||" | paste -sd' ' -)" = "backendtrafficpolicy.yaml kustomization.yaml" ]
  # Three variables and no other: the route's, with no default, so a route that takes the
  # component and names no route fails Flux's strict substitution; the figure and the unit, with
  # theirs, 300 a minute.
  # shellcheck disable=SC2016 # What the files hold is a ${NAME} reference, not for the shell to expand.
  [ "$(grep -rhoE '\$\{[^}]*\}?' "$component" | sort -u | paste -sd' ' -)" = '${RATELIMIT_REQUESTS:=300} ${RATELIMIT_ROUTE} ${RATELIMIT_UNIT:=Minute}' ]
  # The header documents each, as components/waf's documents its own.
  grep -qE '^#   RATELIMIT_ROUTE +[^ ]' "$component/kustomization.yaml"
  grep -qE '^#   RATELIMIT_REQUESTS +[^ ]' "$component/kustomization.yaml"
  grep -qE '^#   RATELIMIT_UNIT +[^ ]' "$component/kustomization.yaml"
  # The policy is named after the route and targets that one HTTPRoute of the Gateway API, by name,
  # in its own namespace, with one local rule and nothing else: no target selector, which could
  # select a Gateway by its labels, no merge with a Gateway's policy, no namespace anywhere; no
  # client selector, so the limit is the route's and not a client's; no global limit, which needs a
  # rate limit service; neither the deprecated type nor a cost, a shared bucket or a header setting;
  # no timeout, retry, circuit breaker or load balancing.
  [ "$(yq -N '.kind' "$policy" | paste -sd' ' -)" = BackendTrafficPolicy ]
  [ "$(yq '.apiVersion' "$policy")" = gateway.envoyproxy.io/v1alpha1 ]
  # shellcheck disable=SC2016 # As above.
  [ "$(yq -o json -I0 '.metadata' "$policy")" = '{"name":"${RATELIMIT_ROUTE}"}' ]
  # shellcheck disable=SC2016 # As above.
  [ "$(yq -o json -I0 '.spec' "$policy" | jq -cS .)" = "$(jq -cnS '{targetRefs: [{group: "gateway.networking.k8s.io", kind: "HTTPRoute", name: "${RATELIMIT_ROUTE}"}],
    rateLimit: {local: {rules: [{limit: {requests: "${RATELIMIT_REQUESTS:=300}", unit: "${RATELIMIT_UNIT:=Minute}"}}]}}}')" ]
  [ "$(yq '[.. | select(tag == "!!map" and has("namespace"))] | length' "$policy")" -eq 0 ]
  # A route that takes it waits for the policy's acceptance, in the form components/waf gives for its
  # own policy, whose expressions tests/waf.bats evaluates: both kinds have the Gateway API's policy
  # status, an Accepted condition for each ancestor.
  [ "$(component_header "$RATELIMIT" | yq -o json -I0 '.components')" = '["../../../../../components/ratelimit"]' ]
  [ "$(component_header "$RATELIMIT" | yq '.wait')" = true ]
  health="$(component_header kubernetes/components/waf | yq -o json -I0 '.healthCheckExprs | map(.kind = "BackendTrafficPolicy")' | jq -cS .)"
  [ "$(component_header "$RATELIMIT" | yq -o json -I0 '.healthCheckExprs' | jq -cS .)" = "$health" ] \
    || { echo "the component's header gives other health expressions: $(component_header "$RATELIMIT" | yq -o json -I0 '.healthCheckExprs')"; return 1; }
  # Who takes it, enabled or not, and at what figure: kromgo and the demo's signed-in route at the
  # defaults, the demo route at 5 a second, low enough for gateway-check to see a 429.
  mapfile -t files < <(cd "$REPO" && find kubernetes -type f -name ks.yaml | sort)
  takers="$(cd "$REPO" && ratelimit_takers "${files[@]}" | sort)"
  echo "the ks.yaml that take the component: $takers"
  [ "$(cut -f1,4 <<<"$takers")" = "$(printf '%s\t%s\n' \
    kubernetes/apps/base/demo/hello-route/ks.yaml '{"RATELIMIT_REQUESTS":"5","RATELIMIT_ROUTE":"hello","RATELIMIT_UNIT":"Second"}' \
    kubernetes/apps/base/demo/hello-sso/ks.yaml '{"RATELIMIT_ROUTE":"hello-sso"}' \
    kubernetes/apps/base/kromgo/kromgo/ks.yaml '{"RATELIMIT_ROUTE":"kromgo"}')" ]
  # Each waits, and holds the health expressions beside any it had.
  while IFS=$'\t' read -r file _; do
    [ "$(yq '.spec.wait' "$REPO/$file")" = true ] || { echo "$file does not wait, so its health expressions are never read"; return 1; }
    [ "$(yq -o json -I0 '[(.spec.healthCheckExprs // [])[] | select(.kind == "BackendTrafficPolicy")]' "$REPO/$file" | jq -cS .)" = "$health" ] \
      || { echo "$file: the health expressions for BackendTrafficPolicy are not the component's"; return 1; }
  done <<<"$takers"
  [ "$(yq -o json -I0 '[.spec.healthCheckExprs[].kind]' "$REPO/kubernetes/apps/base/demo/hello-route/ks.yaml")" = '["EnvoyExtensionPolicy","BackendTrafficPolicy"]' ]
  # Built as Flux applies them on lab-sto2, strictly substituted: an integer figure, which the
  # definition's integer type needs, and a unit of its enum, targeting the route of the build. Each
  # entry: the namespace, the application and its route, the figure and the unit.
  for route in kromgo/kromgo:kromgo/300/Minute demo/hello-route:hello/5/Second demo/hello-sso:hello-sso/300/Minute; do
    IFS=/ read -r namespace name figure unit <<<"$route"
    built "${name%%:*}"
    name=${name##*:}
    expected="$(jq -cnS --arg namespace "$namespace" --arg name "$name" --argjson figure "$figure" --arg unit "$unit" '{namespace: $namespace, name: $name,
      spec: {targetRefs: [{group: "gateway.networking.k8s.io", kind: "HTTPRoute", name: $name}], rateLimit: {local: {rules: [{limit: {requests: $figure, unit: $unit}}]}}}}')"
    found="$(yq -N -o json -I0 'select(.kind == "BackendTrafficPolicy") | {"namespace": .metadata.namespace, "name": .metadata.name, "spec": .spec}' "$BUILT" | jq -cS .)"
    echo "$namespace/$name: $found"
    [ "$found" = "$expected" ]
    [ "$(object "$BUILT" HTTPRoute "$name" | yq '.metadata.namespace')" = "$namespace" ]
  done
  # No other: of every file under kubernetes/, the component's is the one document of the kind,
  # whether an overlay enables it or not.
  (cd "$REPO" && find kubernetes -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z |
    xargs -0 yq -N 'select(.kind == "BackendTrafficPolicy") | filename') >"$BATS_TEST_TMPDIR/files"
  [ "$(cat "$BATS_TEST_TMPDIR/files")" = "$RATELIMIT/backendtrafficpolicy.yaml" ] \
    || { echo "files with a BackendTrafficPolicy: $(cat "$BATS_TEST_TMPDIR/files")"; return 1; }
  # Of everything the cluster applies, with what the charts of its releases render: the three, each
  # targeting HTTPRoutes alone, of its own namespace, that the render holds, and none targeting a
  # Gateway or a ListenerSet or selecting its targets.
  RENDER="$BATS_TEST_TMPDIR/render"
  "$REPO/scripts/render" "$RENDER" >/dev/null
  found="$(cd "$RENDER" && find . -type f -name 'BackendTrafficPolicy[._]*' | sed 's|^\./||' | sort | paste -sd' ' -)"
  [ "$found" = "lab-sto2/hello-route/BackendTrafficPolicy.gateway.envoyproxy.io_demo_hello.yaml lab-sto2/hello-sso/BackendTrafficPolicy.gateway.envoyproxy.io_demo_hello-sso.yaml lab-sto2/kromgo/BackendTrafficPolicy.gateway.envoyproxy.io_kromgo_kromgo.yaml" ] \
    || { echo "BackendTrafficPolicies in the render: ${found:-none}"; return 1; }
  find "$RENDER" -type f -name '*.yaml' -print0 | sort -z | xargs -0 -r yq -N -o json -I0 '.' >"$BATS_TEST_TMPDIR/rendered.jsonl"
  # shellcheck disable=SC2016 # $all, $p, $own and $t are jq variables.
  jq -rs '
    [.[] | objects] as $all
    | $all[] | select(.kind == "BackendTrafficPolicy") | . as $p | .metadata.namespace as $own
    | if (.spec | has("targetRef") or has("targetSelectors") or has("mergeType")) or ((.spec.targetRefs // []) | length) == 0 then
        "\($own)/\(.metadata.name): targets other than by targetRefs"
      else .spec.targetRefs[] | . as $t
        | if .group != "gateway.networking.k8s.io" or .kind != "HTTPRoute" or has("namespace") then
            "\($own)/\($p.metadata.name): targets \(tojson)"
          elif ([$all[] | select(.kind == "HTTPRoute" and .metadata.namespace == $own and .metadata.name == $t.name)] | length) != 1 then
            "\($own)/\($p.metadata.name): targets \($t.name), which is no HTTPRoute of its namespace"
          else empty end
      end' "$BATS_TEST_TMPDIR/rendered.jsonl" >"$BATS_TEST_TMPDIR/wrong"
  [ ! -s "$BATS_TEST_TMPDIR/wrong" ] || { cat "$BATS_TEST_TMPDIR/wrong"; return 1; }
}

@test "A route keeps its sign-in and its firewall when it takes a rate limit, and the sign-in paths are not limited" {
  local targets doubles
  everything
  # Every policy of any kind that names an HTTPRoute in targetRef or targetRefs, by the route it
  # names, in the policy's own namespace, which is where a policy's target is.
  # shellcheck disable=SC2016 # $p and $own are jq variables.
  targets="$(yq -N -o json -I0 '.' "$EVERYTHING" | jq -rs '
    .[] | objects | . as $p | ($p.metadata.namespace // "") as $own | select(($p.spec | type) == "object")
    | ([$p.spec.targetRef // empty] + ($p.spec.targetRefs // []))[]
    | select(.kind == "HTTPRoute") | "\($own)/\(.name) \($p.kind)"' | sort)"
  echo "routes and the kinds that target them: $targets"
  # The demo's signed-in route keeps its sign-in beside its limit, the demo route its firewall.
  [ "$(grep '^demo/hello-sso ' <<<"$targets" | cut -d' ' -f2 | paste -sd' ' -)" = "BackendTrafficPolicy SecurityPolicy" ]
  [ "$(grep '^demo/hello ' <<<"$targets" | cut -d' ' -f2 | paste -sd' ' -)" = "BackendTrafficPolicy EnvoyExtensionPolicy" ]
  # The sign-in paths, the route components/sso adds, are a route the build holds and no policy
  # targets: neither the sign-in, which is the flow itself, nor the limit.
  [ "$(yq -N 'select(.kind == "HTTPRoute" and .metadata.name == "hello-sso-oauth2") | .metadata.namespace' "$EVERYTHING")" = demo ]
  [ -z "$(grep '^demo/hello-sso-oauth2 ' <<<"$targets" || true)" ]
  # No route is the target of two policies of one kind, which the controller would settle by age.
  doubles="$(uniq -d <<<"$targets")"
  [ -z "$doubles" ] || { echo "routes targeted twice by one kind: $doubles"; return 1; }
  # The signed-in route is still probed for the redirect to sign-in.
  built hello-sso
  [ "$(object "$BUILT" Probe hello-sso | yq '.spec.module')" = public_https_signin ]
  # The proxies keep the controller's order of filters, which runs external authorisation and the
  # Wasm filter before the local rate limit (internal/xds/translator/httpfilters.go of Envoy
  # Gateway v1.10.0): an EnvoyProxy's filterOrder could move the limit in front of the sign-in.
  built gateway-public
  [ "$(object "$BUILT" EnvoyProxy "$(only "$BUILT" EnvoyProxy)" | yq '.spec | has("filterOrder")')" = false ]
}

@test "The public listeners bound what one client connection may hold, within the edges' own limits" {
  local gateway spec maxconn client server edges edge_ms idle stream timed
  built gateway-public
  gateway="$(only "$BUILT" Gateway)"
  spec="$(object "$BUILT" ClientTrafficPolicy "$(only "$BUILT" ClientTrafficPolicy)" | yq -o json -I0 '.spec' | jq -cS .)"
  echo "ClientTrafficPolicy: $spec"
  # The PROXY protocol stays optional and TLS 1.2 the minimum; nothing else of the policy but the
  # three keys.
  [ "$(jq -cS '{targetRefs, proxyProtocol, tls}' <<<"$spec")" = "$(jq -cnS --arg gateway "$gateway" '{targetRefs: [{group: "gateway.networking.k8s.io", kind: "Gateway", name: $gateway}],
    proxyProtocol: {optional: true}, tls: {minVersion: "1.2"}}')" ]
  [ "$(jq -c 'keys' <<<"$spec")" = '["connection","http2","proxyProtocol","targetRefs","timeout","tls"]' ]
  # What one connection may hold: no more than the buffer limit, 32 KiB, which is also each HTTP/1.1
  # request's, and 100 streams on HTTP/2; no close delay, maximum connection or stream duration or
  # request count, which would close or reset a websocket or a stream.
  [ "$(jq -cS '.connection' <<<"$spec")" = '{"bufferLimit":"32Ki","connectionLimit":{"value":8000}}' ]
  [ "$(jq -cS '.http2' <<<"$spec")" = '{"maxConcurrentStreams":100}' ]
  # A header phase of at most 10 seconds, an idle connection closed after 4 minutes and an idle
  # stream after 5; no request timeout, which would cut a slow upload, and no TCP timeouts.
  [ "$(jq -cS '.timeout' <<<"$spec")" = '{"http":{"idleTimeout":"4m","requestHeadersReceivedTimeout":"10s","streamIdleTimeout":"5m"}}' ]
  # Within the edges' own limits: the connection limit is each edge's maxconn times the edges the
  # Gateway's records name, so a proxy refuses no connection the edges admit even alone, and the
  # idle timeouts are within the edges' time with nothing sent, the idle one below it, so a
  # connection is closed with an HTTP/2 GOAWAY before an edge cuts it without one.
  maxconn="$(awk '$1 == "maxconn" { print $2 }' "$REPO/$EDGE_PROXY_FILE")"
  client="$(awk '$1 == "timeout" && $2 == "client" { print $3 }' "$REPO/$EDGE_PROXY_FILE")"
  server="$(awk '$1 == "timeout" && $2 == "server" { print $3 }' "$REPO/$EDGE_PROXY_FILE")"
  edges="$(object "$BUILT" Gateway "$gateway" | yq '.metadata.annotations["external-dns.kubernetes.io/target"] | split(",") | map(select(. != "")) | length')"
  echo "$EDGE_PROXY_FILE: maxconn $maxconn, timeout client $client, server $server; $GATEWAY_FILE names $edges edges"
  [[ $maxconn =~ ^[0-9]+$ ]] && [ "$edges" -ge 1 ]
  [ "$(jq '.connection.connectionLimit.value' <<<"$spec")" -eq $((maxconn * edges)) ] \
    || { echo "the connection limit is not maxconn of $EDGE_PROXY_FILE times the edges $GATEWAY_FILE names, $maxconn times $edges"; return 1; }
  edge_ms="$(milliseconds "$client")"
  [ "$(milliseconds "$server")" -ge "$edge_ms" ] || edge_ms="$(milliseconds "$server")"
  idle="$(milliseconds "$(jq -r '.timeout.http.idleTimeout' <<<"$spec")")"
  stream="$(milliseconds "$(jq -r '.timeout.http.streamIdleTimeout' <<<"$spec")")"
  [ "$idle" -lt "$edge_ms" ] || { echo "the idle timeout is not below the edges' timeout of $EDGE_PROXY_FILE, $client and $server"; return 1; }
  [ "$stream" -le "$edge_ms" ] || { echo "the stream idle timeout is above the edges' timeout of $EDGE_PROXY_FILE, $client and $server"; return 1; }
  # No route or BackendTrafficPolicy of what the cluster applies sets a request or idle timeout of
  # its own: with one, the controller sets a route's idle timeout from its request timeout, and
  # leaves that out once the listener sets a stream idle timeout (idleTimeout in
  # internal/xds/translator/route.go), which would make the listener's 5 minutes its limit.
  everything
  timed="$(yq -N 'select(((.kind == "HTTPRoute" or .kind == "GRPCRoute") and ([.spec.rules[]? | select(has("timeouts"))] | length) > 0)
      or (.kind == "BackendTrafficPolicy" and (.spec | has("timeout"))))
    | .kind + "/" + .metadata.namespace + "/" + .metadata.name' "$EVERYTHING")"
  [ -z "$timed" ] || { echo "routes or policies with timeouts of their own: $timed"; return 1; }
}
