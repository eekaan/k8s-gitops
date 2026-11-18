#!/usr/bin/env bats
# Proves features/network-policy.feature, and the scenario of features/waf.feature on the firewall's
# flows; each test carries its scenario's title.
# Needs helm, flux, kustomize, yq and jq on PATH (the versions pinned for the repository). The tests
# on a fixture render are offline; those on the tree render it with its charts pulled from their
# public registries.

# The tests run one at a time even where bats runs a file's tests side by side: the tests on the
# tree share one render, made by whichever of them comes first.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

setup_file() {
  # Helm's settings, and the Docker configuration it reads registry logins from, stay in the run's
  # own directory.
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/network-policy"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  # The labels of the pods Envoy Gateway makes for the public Gateway at run time, which no render
  # holds, and of the pods the storage operator, VolSync and the PostgreSQL operator make.
  PROXY='envoy-gateway-system:app.kubernetes.io/name=envoy,app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,gateway.envoyproxy.io/owning-gateway-name=public,gateway.envoyproxy.io/owning-gateway-namespace=envoy-gateway-system'
  MOVER='demo:app.kubernetes.io/created-by=volsync'
  N8N_DB='ai-system:cnpg.io/cluster=n8n-db,cnpg.io/podRole=instance'
  STORAGE='piraeus-datastore:app.kubernetes.io/name=piraeus-datastore,app.kubernetes.io/component=linstor-controller'
  DNS='kube-system:k8s-app=kube-dns'
  PROMETHEUS='monitoring:app.kubernetes.io/name=prometheus'
  OTHER_APP='other:app.kubernetes.io/name=app'
  KROMGO=kromgo/Deployment/kromgo
  FALCO=security-system/DaemonSet/falco
  # Backstage's pod and its database's: the instances and the jobs the PostgreSQL operator makes for
  # the cluster backstage-db at run time, by the labels it gives them (pkg/specs/pods.go and jobs.go
  # of the pinned operator), its own pods in cnpg-system, and the daily dump job.
  BACKSTAGE=backstage/Deployment/backstage
  BACKSTAGE_DB='backstage:cnpg.io/cluster=backstage-db,cnpg.io/instanceName=backstage-db-1,cnpg.io/podRole=instance,app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=backstage-db,app.kubernetes.io/component=database,app.kubernetes.io/managed-by=cloudnative-pg'
  BACKSTAGE_DB_REPLICA='backstage:cnpg.io/cluster=backstage-db,cnpg.io/instanceName=backstage-db-2,cnpg.io/podRole=instance,app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=backstage-db,app.kubernetes.io/component=database,app.kubernetes.io/managed-by=cloudnative-pg'
  BACKSTAGE_DB_JOIN='backstage:cnpg.io/cluster=backstage-db,cnpg.io/instanceName=backstage-db-3,cnpg.io/jobRole=join,app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=backstage-db,app.kubernetes.io/component=database,app.kubernetes.io/managed-by=cloudnative-pg'
  CNPG_OPERATOR=cnpg-system/Deployment/cloudnative-pg
  PGDUMP=backstage/CronJob/backstage-db-pgdump
  OPEN_FEATURE="open-feature-operator/Deployment/open-feature-operator-controller-manager"
}

# tree NAME: a copy of the fixture in $BATS_TEST_TMPDIR/NAME, for the test to change.
tree() {
  mkdir -p "$BATS_TEST_TMPDIR/$1"
  cp -R "$FIXTURE/render" "$FIXTURE/exceptions.yaml" "$BATS_TEST_TMPDIR/$1/"
}

# check NAME: runs the check on the tree NAME.
check() {
  run "$REPO/scripts/network-policy-check" "$BATS_TEST_TMPDIR/$1/render" "$BATS_TEST_TMPDIR/$1/exceptions.yaml"
}

# object NAME FILE: the path of the one file named FILE in the tree NAME.
object() {
  local files=("$BATS_TEST_TMPDIR/$1"/render/*/*/"$2")
  [ "${#files[@]}" -eq 1 ] || { echo "$2 is not one file of $1: ${files[*]}"; return 1; }
  echo "${files[0]}"
}

# real_render: the render of this repository's tree, charts pulled, in $BATS_FILE_TMPDIR/render,
# made once for the file, and VIEW, the files of it that the evaluation of a flow reads (the
# namespaces, the workloads, the Gateways and the policies), which it reads fast.
real_render() {
  REAL="$BATS_FILE_TMPDIR/render"
  VIEW="$BATS_FILE_TMPDIR/view"
  if [ ! -d "$REAL" ]; then
    "$REPO/scripts/render" "$REAL.partial" >/dev/null
    mv "$REAL.partial" "$REAL"
  fi
  if [ ! -d "$VIEW" ]; then
    mkdir -p "$VIEW.partial"
    (cd "$REAL" && find . -type f \( -name 'Namespace_*' -o -name 'Deployment.apps_*' -o -name 'StatefulSet.apps_*' \
      -o -name 'DaemonSet.apps_*' -o -name 'Job.batch_*' -o -name 'CronJob.batch_*' -o -name 'Pod_*' \
      -o -name 'Gateway.gateway.networking.k8s.io_*' -o -name 'NetworkPolicy.*' -o -name 'CiliumNetworkPolicy.*' \
      -o -name 'CiliumClusterwideNetworkPolicy.*' \) -exec cp --parents {} "$VIEW.partial/" \;)
    mv "$VIEW.partial" "$VIEW"
  fi
}

# reach RENDER FROM TO PORT/PROTOCOL: whether the policies of RENDER let FROM reach TO.
reach() {
  run "$REPO/scripts/network-policy-check" --reach "$@"
}

# allowed, denied, allowed_in and denied_in RENDER FROM TO PORT: assert the answer for the flow, and
# for the destination's ingress alone.
allowed() {
  reach "$@"
  [ "$status" -eq 0 ] || { echo "expected $* to be allowed: $output"; return 1; }
}
denied() {
  reach "$@"
  [ "$status" -eq 1 ] || { echo "expected $* to be denied: $output"; return 1; }
}
allowed_in() {
  run "$REPO/scripts/network-policy-check" --reach-ingress "$@"
  [ "$status" -eq 0 ] || { echo "expected the ingress of $* to be allowed: $output"; return 1; }
}
denied_in() {
  run "$REPO/scripts/network-policy-check" --reach-ingress "$@"
  [ "$status" -eq 1 ] || { echo "expected the ingress of $* to be denied: $output"; return 1; }
}

# A policy added to the tree NAME as a file of the application web.
add_policy() {
  cat >"$BATS_TEST_TMPDIR/$1/render/lab/web/$2"
}

# allow NAME NAMESPACE SELECTOR RULES: a CiliumNetworkPolicy NAME added to the tree NAME in
# NAMESPACE, for the pods SELECTOR's labels select, that leaves the deny to the namespace's default
# deny, with RULES, its ingress and egress lines, as the rest of its spec.
allow() {
  {
    printf 'apiVersion: cilium.io/v2\nkind: CiliumNetworkPolicy\nmetadata:\n  name: %s\n  namespace: %s\n' "$1" "$2"
    printf 'spec:\n  endpointSelector:\n    matchLabels: %s\n  enableDefaultDeny: {ingress: false, egress: false}\n' "$3"
    printf '  %s\n' "${4//$'\n'/$'\n'  }"
  } >"$BATS_TEST_TMPDIR/$1/render/lab/$2/CiliumNetworkPolicy.cilium.io_$2_$1.yaml"
}

# reason NAME NAMESPACE TEXT: gives the policy NAME of the tree NAME the reason annotation TEXT.
reason() {
  TEXT=$3 yq -i '.metadata.annotations["k8s-gitops/network-policy-reason"] = strenv(TEXT)' \
    "$(object "$1" "CiliumNetworkPolicy.cilium.io_$2_$1.yaml")"
}

# The selectors, labels and namespaces both sides of the port comparison read, as jq definitions.
read -r -d '' PORTS_JQ <<'JQ' || true
def fail($w; $m): error("\($w): \($m)");
def key($w): if test("^(k8s|any):") then sub("^(k8s|any):"; "")
  elif test(":") then fail($w; "the key \(.) has a source this test does not read") else . end;
def nskey: . == "io.kubernetes.pod.namespace" or startswith("io.cilium.k8s.namespace.labels.");
# A selector as its requirements, each a key, an operator and values.
def reqs($w):
  if type != "object" or (keys - ["matchLabels", "matchExpressions"] | length) > 0 then fail($w; "the selector \(tojson) is one this test does not read")
  else [ ((.matchLabels // {}) | to_entries[] | {key: (.key | key($w)), op: "In", values: [.value]}),
         ((.matchExpressions // [])[] | {key: (.key | key($w)), op: .operator, values: (.values // [])}
          | if .op | IN("In", "NotIn", "Exists", "DoesNotExist") then . else fail($w; "the operator \(.op) is one this test does not read") end) ] end;
def holds($l): $l[.key] as $v
  | if .op == "In" then $v != null and (.values | index($v)) != null
    elif .op == "NotIn" then $v == null or (.values | index($v)) == null
    elif .op == "Exists" then $v != null
    else $v == null end;
# Each namespace's labels, the name label Kubernetes adds among them.
def nslabels: [ .[] | select(.kind == "Namespace") | {key: .metadata.name, value: ((.metadata.labels // {}) + {"kubernetes.io/metadata.name": .metadata.name})} ]
  | from_entries;
# The namespaces whose routes the Gateway public takes by their labels: the labelled namespaces.
def labelled($nsl):
  [ .[] | select(.kind == "Gateway" and .metadata.namespace == "envoy-gateway-system" and .metadata.name == "public")
    | .spec.listeners[] | select(.allowedRoutes.namespaces.from == "Selector") | .allowedRoutes.namespaces.selector | reqs("the Gateway public") ]
  | if length == 0 then error("the Gateway public takes routes by no namespace label") else . end
  | . as $gsel | [ $nsl | to_entries[] | .value as $l | select(any($gsel[]; all(.[]; holds($l)))) | .key ];
JQ

# routed_ports RENDER: the namespace and container port, NAMESPACE:PORT, of each backend the public
# Gateway's routes send to: each backend of an HTTPRoute attached to the Gateway public, through its
# Service, in the route's namespace unless the reference names another, to the Service port's
# targetPort, the port itself where it gives none, and a named targetPort to the container port of
# that name in the pods the Service selects. A backend in a namespace that is not labelled, or
# behind a Service without a selector, fails it.
routed_ports() {
  (set -o pipefail; yq -N -o json -I0 'select(. != null)' "$1"/*/*/HTTPRoute.gateway.networking.k8s.io_*.yaml \
    "$1"/*/*/Service_*.yaml "$1"/*/*/Deployment.apps_*.yaml "$1"/*/*/StatefulSet.apps_*.yaml \
    "$1"/*/*/DaemonSet.apps_*.yaml "$1"/*/*/Namespace_*.yaml "$1"/*/*/Gateway.gateway.networking.k8s.io_*.yaml | jq -s -r "$PORTS_JQ"'
    . as $objs
    | labelled(nslabels) as $labelled
    | [ $objs[] | select(.kind == "HTTPRoute") | .metadata.namespace as $rns | .metadata.name as $route
        | select(any(.spec.parentRefs[]; .name == "public" and (.namespace // $rns) == "envoy-gateway-system"))
        | (.spec.rules // [])[] | (.backendRefs // [])[] | select((.kind // "Service") == "Service" and (.group // "") == "")
        | (.namespace // $rns) as $ns | .name as $name | .port as $port
        | if ($labelled | index($ns)) == null then
            error("the route \($rns)/\($route) sends to \($ns)/\($name), but \($ns) does not carry the label the Gateway public takes routes by, and the proxies reach the labelled namespaces alone: give \($ns) that label in its namespace.yaml")
          else . end
        | ([ $objs[] | select(.kind == "Service" and .metadata.namespace == $ns and .metadata.name == $name) ][0]
           // error("a route sends to \($ns)/\($name), which is no Service of the render")) as $svc
        | if (($svc.spec.selector // {}) | length) == 0 then
            error("the Service \($ns)/\($name), which a route sends to, has no selector, so the render does not say which pods serve it: give it one")
          else . end
        | ([ $svc.spec.ports[] | select(.port == $port) ][0] // error("the Service \($ns)/\($name) has no port \($port)")) as $sp
        | ($sp.targetPort // $sp.port) as $target
        | if ($target | type) == "number" then $target
          else [ $objs[] | select(.kind | IN("Deployment", "StatefulSet", "DaemonSet")) | select(.metadata.namespace == $ns)
                 | (.spec.template.metadata.labels // {}) as $l
                 | select($svc.spec.selector | to_entries | all(.[]; $l[.key] == .value))
                 | .spec.template.spec.containers[] | (.ports // [])[] | select(.name == $target) | .containerPort ] | unique
               | if length == 1 then .[0] else error("the port \($target) of the Service \($ns)/\($name) is not one container port of its pods") end
          end
        | "\($ns):\(.)" ]
    | unique | join(" ")')
}

# proxies_egress RENDER: the namespace and port, NAMESPACE:PORT, of each labelled namespace and
# port on which the egress of the public Gateway's proxies, the pods of PROXY, lets them reach a
# pod of that namespace. It reads every policy that can select the proxies: each Cilium policy of
# their namespace or of none, and each NetworkPolicy of their namespace, whose selector holds for
# their namespace and for the labels PROXY gives them; a requirement on a label PROXY does not
# give them is taken to hold, as the pods may carry it at run time. Of those, it reads every egress
# rule whose peers can be a pod of a labelled namespace: a selector whose requirements on the
# namespace and its labels that namespace meets, whatever it asks of the pod, the entities cluster
# and all, and a rule that names no peer. It fails on what it cannot compare rather than skip it: a
# port entry for a protocol other than TCP or for none, a range, a named port, a rule that names no
# port, a NetworkPolicy that allows the proxies egress, and a peer, a selector or a field of a
# rule that it does not read.
proxies_egress() {
  (set -o pipefail; yq -N -o json -I0 'select(. != null)' "$1"/*/*/*.yaml | jq -s -r --arg proxy "$PROXY" "$PORTS_JQ"'
    # What Cilium matches the namespace part of a selector against for a pod of the namespace $n.
    def nsfull($n; $nsl): {"io.kubernetes.pod.namespace": $n}
      + ($nsl[$n] | with_entries(.key |= "io.cilium.k8s.namespace.labels." + .));
    def ports($w):
      if ((.toPorts // []) | length) == 0 then fail($w; "a rule to a labelled namespace names no port, so it allows every port")
      else .toPorts[]
        | if (keys - ["ports"] | length) > 0 then fail($w; "a port rule with \(keys - ["ports"] | join(", ")), which this test cannot compare")
          elif ((.ports // []) | length) == 0 then fail($w; "a rule to a labelled namespace names no port, so it allows every port")
          else .ports[] end
        | if (keys - ["port", "protocol"] | length) > 0 then fail($w; "the port entry \(tojson) has \(keys - ["port", "protocol"] | join(", ")), which this test cannot compare")
          elif .protocol != "TCP" then fail($w; "the port entry \(tojson) is for \(.protocol // "every protocol"), not TCP alone, which this test cannot compare")
          elif ((.port | tostring | test("^[1-9][0-9]{0,4}$")) and (.port | tostring | tonumber) <= 65535) | not then
            fail($w; "the port entry \(tojson) names no one port by its number, which this test cannot compare")
          else .port | tostring | tonumber end
      end;
    . as $objs
    | ($proxy | capture("^(?<ns>[^:]+):(?<l>.*)$")) as $p
    | ($p.l | split(",") | map(split("=") | {key: .[0], value: (.[1:] | join("="))}) | from_entries) as $pl
    | nslabels as $nsl
    | (nsfull($p.ns; $nsl) + $pl) as $self
    | def selects_proxies($w): reqs($w) | all(.[]; .key as $k | if ($k | nskey) or ($pl | has($k)) then holds($self) else true end);
    labelled($nsl) as $labelled
    | [ $objs[] | select(.kind == "NetworkPolicy" and .metadata.namespace == $p.ns) | . as $np | "NetworkPolicy/\($np.metadata.name)" as $w
        | select(($np.spec.podSelector // {}) | selects_proxies($w)) | select((($np.spec.egress // []) | length) > 0)
        | fail($w; "a NetworkPolicy that allows the proxies egress, which this test does not read") ]
    | [ $objs[] | select(.kind == "CiliumClusterwideNetworkPolicy" or (.kind == "CiliumNetworkPolicy" and .metadata.namespace == $p.ns))
        | . as $pol | "\($pol.kind)/\($pol.metadata.name)" as $w
        | ((if .spec != null then [.spec] else [] end) + (.specs // []))[] | select(.endpointSelector != null)
        | select(.endpointSelector | selects_proxies($w))
        | (.egress // [])[] | . as $r
        | (keys - ["toEndpoints", "toEntities", "toPorts"]) as $other
        | if ($other | length) > 0 then fail($w; "an egress rule with \($other | join(", ")), which this test does not read") else . end
        | [ if (((.toEndpoints // []) + (.toEntities // [])) | length) == 0 then $labelled[]
            else
              ((.toEndpoints // [])[] | reqs($w) | map(select(.key | nskey)) as $nq
               | $labelled[] as $n
               | select(if ($nq | length) == 0 then $pol.kind == "CiliumClusterwideNetworkPolicy" or $n == $p.ns
                        else $nq | all(.[]; holds(nsfull($n; $nsl))) end) | $n),
              ((.toEntities // [])[]
               | if IN("cluster", "all") then $labelled[]
                 elif IN("world", "world-ipv4", "world-ipv6", "host", "remote-node", "kube-apiserver", "health", "init", "ingress", "unmanaged") then empty
                 else fail($w; "the entity \(.) is one this test does not read") end)
            end ] | unique
        | select(length > 0) as $nss
        | $r | ports($w) as $port | $nss[] | "\(.):\($port)" ]
    | unique | join(" ")')
}

@test "An application namespace denies ingress and egress by default" {
  tree good
  check good
  [ "$status" -eq 0 ]
  [[ $output == *"web denies ingress and egress"* ]]
  [[ $output == *"gw denies ingress and egress"* ]]
  [[ $output == *"legacy listed"* ]]
  # The tree: exactly these namespaces hold the default deny, and every other namespace it deploys
  # into is listed.
  real_render
  run "$REPO/scripts/network-policy-check" "$REAL" "$REPO/network-policy-exceptions.yaml"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep ' denies ingress and egress' <<<"$output" | cut -d' ' -f1 | paste -sd' ')" = "ascender backstage crowdsec demo envoy-gateway-system kromgo locust open-feature-operator security-system sso-system" ]
  [ "$(grep -c ' listed' <<<"$output")" -eq "$(yq '.exceptions | length' "$REPO/network-policy-exceptions.yaml")" ]
}

@test "A namespace without the posture fails the check unless it is listed with its reason" {
  tree nopolicy
  rm "$(object nopolicy NetworkPolicy.networking.k8s.io_web_default-deny.yaml)"
  check nopolicy
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web has no default deny of ingress and egress"* ]]
  # A default deny that selects only some pods.
  tree partial
  yq -i '.spec.podSelector = {"matchLabels": {"app.kubernetes.io/name": "site"}}' \
    "$(object partial NetworkPolicy.networking.k8s.io_web_default-deny.yaml)"
  check partial
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web"* && $output == *"does not select every pod"* ]]
  # One that leaves egress open, and one that leaves ingress open.
  tree open-egress
  yq -i '.spec.policyTypes = ["Ingress"]' "$(object open-egress NetworkPolicy.networking.k8s.io_web_default-deny.yaml)"
  check open-egress
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web"* && $output == *"egress"* ]]
  tree open-ingress
  yq -i '.spec.policyTypes = ["Egress"]' "$(object open-ingress NetworkPolicy.networking.k8s.io_web_default-deny.yaml)"
  check open-ingress
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web"* && $output == *"ingress"* ]]
  # One that has an allow of its own is not a default deny.
  tree allowing
  yq -i '.spec.ingress = [{"from": [{"podSelector": {}}]}]' "$(object allowing NetworkPolicy.networking.k8s.io_web_default-deny.yaml)"
  check allowing
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web"* ]]
  # A deny under another name is no default deny: the default deny is the one named default-deny,
  # the object the way back for a namespace takes out.
  tree renamed
  yq -i '.metadata.name = "deny-all"' "$(object renamed NetworkPolicy.networking.k8s.io_web_default-deny.yaml)"
  check renamed
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web has no default deny of ingress and egress"*"NetworkPolicy/deny-all is not named default-deny"* ]]
  # The exceptions list is read: without the entry of a namespace that has no default deny, or
  # with an entry that gives no reason or says nothing covers it.
  tree unlisted
  yq -i '.exceptions = []' "$BATS_TEST_TMPDIR/unlisted/exceptions.yaml"
  check unlisted
  [ "$status" -eq 1 ]
  [[ $output == *"namespace legacy has no default deny"* ]]
  tree noreason
  yq -i 'del(.exceptions[0].reason)' "$BATS_TEST_TMPDIR/noreason/exceptions.yaml"
  check noreason
  [ "$status" -eq 1 ]
  [[ $output == *"legacy"* && $output == *"reason"* ]]
  tree nocover
  yq -i '.exceptions[0]["covered-by"] = ""' "$BATS_TEST_TMPDIR/nocover/exceptions.yaml"
  check nocover
  [ "$status" -eq 1 ]
  [[ $output == *"legacy"* && $output == *"covered-by"* ]]
}

@test "A listed namespace that has the posture, or that does not exist, fails the check" {
  tree stale
  yq -i '.exceptions += [{"namespace": "web", "reason": "a reason", "covered-by": "something"}]' "$BATS_TEST_TMPDIR/stale/exceptions.yaml"
  check stale
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web is listed but has the default deny"* ]]
  tree ghost
  yq -i '.exceptions += [{"namespace": "ghost", "reason": "a reason", "covered-by": "something"}]' "$BATS_TEST_TMPDIR/ghost/exceptions.yaml"
  check ghost
  [ "$status" -eq 1 ]
  [[ $output == *"namespace ghost is listed but the render holds no object in it"* ]]
  # An entry twice.
  tree twice
  yq -i '.exceptions += .exceptions' "$BATS_TEST_TMPDIR/twice/exceptions.yaml"
  check twice
  [ "$status" -eq 1 ]
  [[ $output == *"namespace legacy is listed twice"* ]]
}

@test "An allow that undoes the default fails the check unless it says why" {
  local name
  local site='{app.kubernetes.io/name: site}'
  local proxies='{app.kubernetes.io/name: envoy, app.kubernetes.io/component: proxy, app.kubernetes.io/managed-by: envoy-gateway, gateway.envoyproxy.io/owning-gateway-name: public}'
  # Each allow, as the one rule of a policy of the namespace in ns (web when unset), for the pods sel
  # selects (site's when unset).
  local -A rule=(
    [empty-peer]='ingress: [{fromEndpoints: [{}]}]'
    [world-in]='ingress: [{fromEntities: [world], toPorts: [{ports: [{port: "8080", protocol: TCP}]}]}]'
    [remote-node-in]='ingress: [{fromEntities: [remote-node]}]'
    [cluster-out]='egress: [{toEntities: [cluster]}]'
    [mesh-out]='egress: [{toEntities: [cluster-mesh]}]'
    [all-in]='ingress: [{fromEntities: [all]}]'
    [all-out]='egress: [{toEntities: [all]}]'
    [unmanaged-in]='ingress: [{fromEntities: [unmanaged]}]'
    [unmanaged-out]='egress: [{toEntities: [unmanaged]}]'
    [world-out]='egress: [{toEntities: [world]}]'
    [ports-only]='egress: [{toPorts: [{ports: [{port: "53", protocol: ANY}]}]}]'
    [any-name]='egress: [{toFQDNs: [{matchPattern: "*"}], toPorts: [{ports: [{port: "443"}]}]}]'
    # Every pod of every namespace, by a selector of the namespace alone, as Cilium names it with
    # and without the source of the label.
    [ns-exists-in]='ingress: [{fromEndpoints: [{matchExpressions: [{key: "k8s:io.kubernetes.pod.namespace", operator: Exists}]}]}]'
    [ns-exists-out]='egress: [{toEndpoints: [{matchExpressions: [{key: io.kubernetes.pod.namespace, operator: Exists}]}], toPorts: [{ports: [{port: "8080", protocol: TCP}]}]}]'
    [ns-notin-out]='egress: [{toEndpoints: [{matchExpressions: [{key: "k8s:io.kubernetes.pod.namespace", operator: Exists}, {key: "k8s:io.kubernetes.pod.namespace", operator: NotIn, values: [kube-system]}]}]}]'
    [ns-labels-in]='ingress: [{fromEndpoints: [{matchExpressions: [{key: "k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name", operator: Exists}]}]}]'
    # The world into the Gateway's namespace other than to its proxies on its listener ports, and
    # other nodes' hosts there.
    [gw-other-pods]='ingress: [{fromEntities: [world], toPorts: [{ports: [{port: "10443", protocol: TCP}]}]}]'
    [gw-other-port]='ingress: [{fromEntities: [world], toPorts: [{ports: [{port: "22", protocol: TCP}]}]}]'
    [gw-every-port]='ingress: [{fromEntities: [world]}]'
    [gw-other-gateway]='ingress: [{fromEntities: [world], toPorts: [{ports: [{port: "10443", protocol: TCP}]}]}]'
    [gw-name-only]='ingress: [{fromEntities: [world], toPorts: [{ports: [{port: "10443", protocol: TCP}]}]}]'
    [gw-remote-node]='ingress: [{fromEntities: [remote-node], toPorts: [{ports: [{port: "10443", protocol: TCP}]}]}]'
  )
  local -A ns=([gw-other-pods]=gw [gw-other-port]=gw [gw-every-port]=gw [gw-other-gateway]=gw [gw-name-only]=gw [gw-remote-node]=gw)
  local -A sel=(
    [gw-other-pods]='{control-plane: gw-controller}'
    [gw-other-port]=$proxies [gw-every-port]=$proxies [gw-remote-node]=$proxies
    [gw-other-gateway]='{app.kubernetes.io/name: envoy, app.kubernetes.io/component: proxy, app.kubernetes.io/managed-by: envoy-gateway, gateway.envoyproxy.io/owning-gateway-name: private}'
    [gw-name-only]='{gateway.envoyproxy.io/owning-gateway-name: public}'
  )
  local file
  for name in "${!rule[@]}"; do
    tree "$name"
    allow "$name" "${ns[$name]:-web}" "${sel[$name]:-$site}" "${rule[$name]}"
    file=$(object "$name" "CiliumNetworkPolicy.cilium.io_${ns[$name]:-web}_$name.yaml")
    check "$name"
    [ "$status" -eq 1 ] || { echo "$name: $output"; return 1; }
    [[ $output == *"namespace ${ns[$name]:-web}: CiliumNetworkPolicy/$name"* ]] || { echo "$name: $output"; return 1; }
    # The same policy with its reason passes, its rule on the ports it names, or on 8080 where it
    # names none.
    reason "$name" "${ns[$name]:-web}" 'the application needs it'
    PORTS='{"toPorts": [{"ports": [{"port": "8080", "protocol": "TCP"}]}]}' yq -i '
      (.spec | select(has("ingress")) | .ingress[]) |= (env(PORTS) * .)
      | (.spec | select(has("egress")) | .egress[]) |= (env(PORTS) * .)' "$file"
    check "$name"
    [ "$status" -eq 0 ] || { echo "$name with its reason: $output"; return 1; }
    # A reason with nothing in it is none.
    reason "$name" "${ns[$name]:-web}" ''
    check "$name"
    [ "$status" -eq 1 ] || { echo "$name with an empty reason: $output"; return 1; }
    # A reason excuses a rule on the ports it names: without them, the rule is refused, reason and
    # all.
    reason "$name" "${ns[$name]:-web}" 'the application needs it'
    yq -i 'del(.spec.ingress[].toPorts, .spec.egress[].toPorts)' "$file"
    check "$name"
    [ "$status" -eq 1 ] || { echo "$name with its reason and no port: $output"; return 1; }
    [[ $output == *"namespace ${ns[$name]:-web}: CiliumNetworkPolicy/$name carries a reason but its rule names no port"* ]] || { echo "$name: $output"; return 1; }
  done
  # The Gateway's proxies may take the world on the listener ports without a reason: the fixture's
  # proxy policy does, and passes.
  tree gateway
  check gateway
  [ "$status" -eq 0 ]
  # A reason excuses the one rule of its policy: with a second rule, broad or not, or a rule in a
  # second spec, the policy is refused, reason and all.
  local -A more=(
    [two-broad]='egress: [{toEntities: [world]}, {toEntities: [cluster]}]'
    [broad-and-narrow]=$'egress: [{toEntities: [world]}]\ningress: [{fromEntities: [host], toPorts: [{ports: [{port: "8080", protocol: TCP}]}]}]'
  )
  for name in "${!more[@]}"; do
    tree "$name"
    allow "$name" web "$site" "${more[$name]}"
    reason "$name" web 'the application needs it'
    check "$name"
    [ "$status" -eq 1 ] || { echo "$name: $output"; return 1; }
    [[ $output == *"namespace web: CiliumNetworkPolicy/$name carries a reason but holds 2 rules"* ]] || { echo "$name: $output"; return 1; }
  done
  tree two-specs
  allow two-specs web "$site" 'egress: [{toEntities: [world]}]'
  yq -i '.specs = [.spec, .spec] | del(.spec) | .specs[1].egress = [{"toEntities": ["cluster"]}]' \
    "$(object two-specs CiliumNetworkPolicy.cilium.io_web_two-specs.yaml)"
  reason two-specs web 'the application needs it'
  check two-specs
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web: CiliumNetworkPolicy/two-specs carries a reason but holds 2 rules"* ]]
  # An entity written as a label of an endpoint selector, and a selector of the namespace or its
  # labels that does not require one (DoesNotExist, NotIn), select what is no pod of the cluster:
  # Cilium adds the policy's namespace to neither (pkg/k8s/apis/cilium.io/utils/utils.go,
  # getEndpointSelector), and NotIn holds for a peer without the label. Each is refused, reason or
  # not, in a namespace with the default deny, in a listed one and as the policy's own selector.
  local -A outside=(
    [reserved-in]='ingress: [{fromEndpoints: [{matchLabels: {"reserved:world": ""}}], toPorts: [{ports: [{port: "8080", protocol: TCP}]}]}]'
    [reserved-out]='egress: [{toEndpoints: [{matchExpressions: [{key: "reserved:host", operator: Exists}]}], toPorts: [{ports: [{port: "10250", protocol: TCP}]}]}]'
    [ns-absent-in]='ingress: [{fromEndpoints: [{matchExpressions: [{key: "k8s:io.kubernetes.pod.namespace", operator: DoesNotExist}]}], toPorts: [{ports: [{port: "8080", protocol: TCP}]}]}]'
    [ns-notin-alone-out]='egress: [{toEndpoints: [{matchExpressions: [{key: io.kubernetes.pod.namespace, operator: NotIn, values: [kube-system]}]}], toPorts: [{ports: [{port: "8080", protocol: TCP}]}]}]'
    [labelled-notin-in]='ingress: [{fromEndpoints: [{matchLabels: {world: ""}, matchExpressions: [{key: "k8s:io.kubernetes.pod.namespace", operator: NotIn, values: [kube-system]}]}], toPorts: [{ports: [{port: "8080", protocol: TCP}]}]}]'
    [ns-label-absent-in]='ingress: [{fromEndpoints: [{matchExpressions: [{key: "k8s:io.cilium.k8s.namespace.labels.team", operator: DoesNotExist}]}], toPorts: [{ports: [{port: "8080", protocol: TCP}]}]}]'
  )
  for name in "${!outside[@]}"; do
    tree "$name"
    allow "$name" web "$site" "${outside[$name]}"
    reason "$name" web 'the application needs it'
    check "$name"
    [ "$status" -eq 1 ] || { echo "$name: $output"; return 1; }
    [[ $output == *"namespace web: CiliumNetworkPolicy/$name "*"what is no pod of the cluster"* ]] || { echo "$name: $output"; return 1; }
  done
  tree reserved-listed
  allow reserved-listed legacy '{app.kubernetes.io/name: ledger}' "${outside[reserved-in]}"
  check reserved-listed
  [ "$status" -eq 1 ]
  [[ $output == *"namespace legacy: CiliumNetworkPolicy/reserved-listed "*"what is no pod of the cluster"* ]]
  tree reserved-subject
  allow reserved-subject web '{"reserved:host": ""}' 'ingress: [{fromEntities: [host], toPorts: [{ports: [{port: "8080", protocol: TCP}]}]}]'
  check reserved-subject
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web: CiliumNetworkPolicy/reserved-subject "*"what is no pod of the cluster"* ]]
  # The evaluator, which reads endpoint selectors as selecting pods, does not answer over a render
  # that holds one.
  for name in reserved-in ns-absent-in; do
    run "$REPO/scripts/network-policy-check" --reach "$BATS_TEST_TMPDIR/$name/render" @world web/Deployment/site 8080/tcp
    [ "$status" -eq 2 ] || { echo "$name: $output"; return 1; }
    [[ $output == *"does not read"*"CiliumNetworkPolicy/$name "* ]] || { echo "$name: $output"; return 1; }
  done
  # A Kubernetes NetworkPolicy that allows everything is as much an undoing, and so is one whose
  # peer is every pod of every namespace.
  tree k8s-all
  add_policy k8s-all NetworkPolicy.networking.k8s.io_web_allow-all.yaml <<'E'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all
  namespace: web
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - {}
E
  check k8s-all
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web"* && $output == *"NetworkPolicy/allow-all"* ]]
  local -A k8s=(
    [k8s-ns-exists-in]='ingress: [{from: [{namespaceSelector: {matchExpressions: [{key: kubernetes.io/metadata.name, operator: Exists}]}}], ports: [{port: 8080}]}]'
    [k8s-ns-empty-out]='egress: [{to: [{namespaceSelector: {}}], ports: [{port: 8080}]}]'
  )
  for name in "${!k8s[@]}"; do
    tree "$name"
    add_policy "$name" "NetworkPolicy.networking.k8s.io_web_$name.yaml" <<E
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: $name
  namespace: web
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: site
  ${k8s[$name]}
E
    check "$name"
    [ "$status" -eq 1 ] || { echo "$name: $output"; return 1; }
    [[ $output == *"namespace web: NetworkPolicy/$name undoes the default deny ("*"allows every pod of every namespace"* ]] || { echo "$name: $output"; return 1; }
  done
}

@test "Traffic from the public Gateway reaches a routed backend and nothing else in its namespace" {
  real_render
  local hello=demo/Deployment/hello
  # The chain: the world to the proxies' listener ports, the proxies to the backend's port, the
  # proxies to their controller for configuration, and DNS. A connection a worker forwards to a
  # proxy on another node crosses the tunnel as the world (the pinned Cilium's
  # bpf/lib/nodeport.h), so other nodes' hosts are no peer of the listeners.
  allowed "$VIEW" @world "$PROXY" 10443/tcp
  allowed "$VIEW" @world "$PROXY" 10080/tcp
  denied "$VIEW" @remote-node "$PROXY" 10443/tcp
  allowed "$VIEW" "$PROXY" "$hello" 8080/tcp
  # n8n's route sends the proxies to its port in ai-system, which carries the Gateway label: the
  # proxies' egress allows it, and n8n's side takes it unrestricted, as ai-system is listed.
  allowed "$VIEW" "$PROXY" ai-system/Deployment/n8n 5678/tcp
  # kromgo's route sends them to its badge port in kromgo, which carries the Gateway label and
  # denies by default: the proxies' egress and kromgo's own ingress both take that port, and
  # neither takes its metrics port.
  allowed "$VIEW" "$PROXY" "$KROMGO" 8080/tcp
  allowed_in "$VIEW" "$PROXY" "$KROMGO" 8080/tcp
  denied "$VIEW" "$PROXY" "$KROMGO" 8081/tcp
  denied_in "$VIEW" "$PROXY" "$KROMGO" 8081/tcp
  denied "$VIEW" "$PROXY" "$KROMGO" 22/tcp
  # Backstage's route sends them to its port in backstage, which carries the Gateway label and
  # denies by default: the proxies' egress and Backstage's own ingress both take that port, and
  # neither reaches its database.
  allowed "$VIEW" "$PROXY" "$BACKSTAGE" 7007/tcp
  allowed_in "$VIEW" "$PROXY" "$BACKSTAGE" 7007/tcp
  denied "$VIEW" "$PROXY" "$BACKSTAGE" 22/tcp
  denied "$VIEW" "$PROXY" "$BACKSTAGE_DB" 5432/tcp
  denied_in "$VIEW" "$PROXY" "$BACKSTAGE_DB" 5432/tcp
  denied "$VIEW" "$PROXY" "$PGDUMP" 7007/tcp
  # Ascender's route sends them to nginx's 8052 in its web pods in ascender, which carries the
  # Gateway label and denies by default: the pods are the operator's, by the labels its templates
  # give them. The proxies' egress and the web pods' ingress both take that port and no other, and
  # neither reaches the task pods, the job pods or the database.
  local ascender_web='ascender:app.kubernetes.io/name=ascender-web,app.kubernetes.io/part-of=ascender,app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/component=awx'
  allowed "$VIEW" "$PROXY" "$ascender_web" 8052/tcp
  allowed_in "$VIEW" "$PROXY" "$ascender_web" 8052/tcp
  denied "$VIEW" "$PROXY" "$ascender_web" 8050/tcp
  denied_in "$VIEW" "$PROXY" "$ascender_web" 8050/tcp
  denied "$VIEW" "$PROXY" 'ascender:app.kubernetes.io/name=ascender-task,app.kubernetes.io/part-of=ascender,app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/component=awx' 8052/tcp
  denied "$VIEW" "$PROXY" 'ascender:ansible_job=' 8052/tcp
  denied "$VIEW" "$PROXY" 'ascender:cnpg.io/cluster=ascender-db,cnpg.io/podRole=instance' 5432/tcp
  denied "$VIEW" @world "$ascender_web" 8052/tcp
  # The proxies' egress names each routed backend's pods and the port its route sends to, and no
  # other, so in a namespace that is listed, and takes them on every port, they reach neither n8n's
  # other ports, demo's backend's port among them, nor its database on any port.
  denied "$VIEW" "$PROXY" ai-system/Deployment/n8n 5680/tcp
  denied "$VIEW" "$PROXY" ai-system/Deployment/n8n 8080/tcp
  denied "$VIEW" "$PROXY" "$N8N_DB" 5432/tcp
  denied "$VIEW" "$PROXY" "$N8N_DB" 5678/tcp
  # Open WebUI's route sends the proxies to its 8080 in ai-system, and they reach no other port of
  # its pod, n8n's among them.
  allowed "$VIEW" "$PROXY" ai-system/Deployment/open-webui 8080/tcp
  denied "$VIEW" "$PROXY" ai-system/Deployment/open-webui 5678/tcp
  # The sign-in's routes send the proxies to dex's 5556 and oauth2-proxy's 4180 in sso-system, which
  # carries the Gateway label and denies by default; oauth2-proxy's 4180 is also where the proxies ask
  # about each request of a route that opts in (components/sso). Each takes them on that port alone,
  # by their labels, and nothing from outside the cluster.
  allowed "$VIEW" "$PROXY" sso-system/Deployment/dex 5556/tcp
  allowed "$VIEW" "$PROXY" sso-system/Deployment/oauth2-proxy 4180/tcp
  denied "$VIEW" "$PROXY" sso-system/Deployment/dex 5558/tcp
  denied "$VIEW" "$PROXY" sso-system/Deployment/dex 5557/tcp
  denied "$VIEW" "$PROXY" sso-system/Deployment/oauth2-proxy 44180/tcp
  denied "$VIEW" "$PROXY" sso-system/Deployment/oauth2-proxy 5556/tcp
  denied "$VIEW" @world sso-system/Deployment/dex 5556/tcp
  denied "$VIEW" @world sso-system/Deployment/oauth2-proxy 4180/tcp
  denied "$VIEW" @remote-node sso-system/Deployment/oauth2-proxy 4180/tcp
  denied_in "$VIEW" envoy-gateway-system/Deployment/envoy-gateway sso-system/Deployment/dex 5556/tcp
  denied_in "$VIEW" envoy-gateway-system/Deployment/envoy-gateway sso-system/Deployment/oauth2-proxy 4180/tcp
  # The log store's route sends the proxies to VictoriaLogs' 9428 in monitoring, which carries the
  # Gateway label and is listed, so it takes them on every port: the proxies' egress names the
  # store's pod on that port alone, so they reach no other port of it and no pod of Prometheus,
  # Grafana, Alertmanager or the collector. Those pods and ports are read from the render: the
  # Services of Prometheus and Alertmanager, which select the pods their operator makes; the Grafana
  # its operator runs, whose pods it labels app with the Grafana's name and serves on 3000 unless the
  # Grafana's configuration sets another port (grafana-operator v5.25.0, controllers/reconcilers/grafana/
  # and controllers/config/operator_constants.go); and the collector's DaemonSet. The controller's
  # pods do not reach the store.
  local store=monitoring/StatefulSet/victoria-logs selector port grafana
  allowed "$VIEW" "$PROXY" "$store" 9428/tcp
  denied "$VIEW" "$PROXY" "$store" 9429/tcp
  denied "$VIEW" "$PROXY" "$store" 8080/tcp
  denied "$VIEW" envoy-gateway-system/Deployment/envoy-gateway "$store" 9428/tcp
  selector=$(yq '.spec.selector | to_entries | map(.key + "=" + .value) | join(",")' "$REAL"/*/kube-prometheus-stack/Service_monitoring_kube-prometheus-stack-prometheus.yaml)
  port=$(yq '.spec.ports[] | select(.name == "http-web") | .targetPort' "$REAL"/*/kube-prometheus-stack/Service_monitoring_kube-prometheus-stack-prometheus.yaml)
  [ "$port" = 9090 ] || { echo "Prometheus' web port in the render: $port"; return 1; }
  denied "$VIEW" "$PROXY" "monitoring:$selector" "$port/tcp"
  selector=$(yq '.spec.selector | to_entries | map(.key + "=" + .value) | join(",")' "$REAL"/*/kube-prometheus-stack/Service_monitoring_kube-prometheus-stack-alertmanager.yaml)
  port=$(yq '.spec.ports[] | select(.name == "http-web") | .targetPort' "$REAL"/*/kube-prometheus-stack/Service_monitoring_kube-prometheus-stack-alertmanager.yaml)
  [ "$port" = 9093 ] || { echo "Alertmanager's web port in the render: $port"; return 1; }
  denied "$VIEW" "$PROXY" "monitoring:$selector" "$port/tcp"
  grafana=$(yq '.metadata.name + " " + ((.spec.config.server.http_port // 3000) | tostring)' "$REAL"/*/grafana/Grafana.grafana.integreatly.org_monitoring_*.yaml)
  [ "$grafana" = "grafana 3000" ] || { echo "the Grafana of the render and its port: $grafana"; return 1; }
  denied "$VIEW" "$PROXY" "monitoring:app=${grafana% *}" "${grafana#* }/tcp"
  port=$(yq '.spec.template.spec.containers[].ports[] | select(.name == "prom-exporter") | .containerPort' "$REAL"/*/vector/DaemonSet.apps_monitoring_vector.yaml)
  [ "$port" = 9598 ] || { echo "the collector's metrics port in the render: $port"; return 1; }
  denied "$VIEW" "$PROXY" monitoring/DaemonSet/vector "$port/tcp"
  # The rule names the store's pod, not the namespace: another pod of monitoring is no backend on the
  # store's port either.
  denied "$VIEW" "$PROXY" monitoring/DaemonSet/vector 9428/tcp
  denied "$VIEW" "$PROXY" "monitoring:app=${grafana% *}" 9428/tcp
  allowed "$VIEW" "$PROXY" envoy-gateway-system/Deployment/envoy-gateway 18000/tcp
  allowed "$VIEW" "$PROXY" "$DNS" 53/udp
  # Nothing but the listener ports reaches the proxies from outside.
  denied "$VIEW" @world "$PROXY" 22/tcp
  denied "$VIEW" @world "$PROXY" 19001/tcp
  # The controller takes the API server and other nodes' hosts on its webhook's port alone, and the
  # world on none.
  allowed "$VIEW" @kube-apiserver envoy-gateway-system/Deployment/envoy-gateway 9443/tcp
  allowed "$VIEW" @remote-node envoy-gateway-system/Deployment/envoy-gateway 9443/tcp
  denied "$VIEW" @remote-node envoy-gateway-system/Deployment/envoy-gateway 18000/tcp
  denied "$VIEW" @remote-node envoy-gateway-system/Deployment/envoy-gateway 19001/tcp
  denied "$VIEW" @world envoy-gateway-system/Deployment/envoy-gateway 9443/tcp
  denied "$VIEW" @world envoy-gateway-system/Deployment/envoy-gateway 18000/tcp
  # The proxies reach the one port of the backend, and no other pod of demo.
  denied "$VIEW" "$PROXY" "$hello" 22/tcp
  denied "$VIEW" "$PROXY" "$hello" 80/tcp
  denied "$VIEW" "$PROXY" demo/Deployment/volsync-demo 8080/tcp
  denied "$VIEW" "$PROXY" "$MOVER" 8080/tcp
  # A namespace without the Gateway label is not a backend, whatever it allows itself.
  denied "$VIEW" "$PROXY" "$OTHER_APP" 8080/tcp
  denied "$VIEW" "$PROXY" "$STORAGE" 3370/tcp
  # The Gateway's controller is not the proxies: the allow names their labels, not the namespace.
  # The backend's ingress alone refuses the pods of the Gateway's namespace that are no proxy.
  allowed_in "$VIEW" "$PROXY" "$hello" 8080/tcp
  denied_in "$VIEW" envoy-gateway-system/Deployment/envoy-gateway "$hello" 8080/tcp
  denied_in "$VIEW" envoy-gateway-system:app=certgen "$hello" 8080/tcp
  denied_in "$VIEW" envoy-gateway-system:app.kubernetes.io/name=envoy "$hello" 8080/tcp
  denied "$VIEW" envoy-gateway-system/Deployment/envoy-gateway "$hello" 8080/tcp
  denied "$VIEW" @world "$hello" 8080/tcp
  denied "$VIEW" @remote-node "$hello" 8080/tcp
  denied_in "$VIEW" envoy-gateway-system/Deployment/envoy-gateway "$KROMGO" 8080/tcp
  denied "$VIEW" @world "$KROMGO" 8080/tcp
  denied_in "$VIEW" envoy-gateway-system/Deployment/envoy-gateway "$BACKSTAGE" 7007/tcp
  denied "$VIEW" @world "$BACKSTAGE" 7007/tcp
  denied "$VIEW" @remote-node "$BACKSTAGE" 7007/tcp
  # No monitor of the tree scrapes the Gateway, so Prometheus reaches neither its controller nor
  # its proxies.
  denied "$VIEW" "$PROMETHEUS" envoy-gateway-system/Deployment/envoy-gateway 19001/tcp
  denied "$VIEW" "$PROMETHEUS" "$PROXY" 19001/tcp
  # kromgo's monitor scrapes the port of its Service it names, so Prometheus reaches that port's
  # container port, read from the render, and no other port of kromgo; nothing else of monitoring
  # reaches it.
  local metrics
  metrics=$(P="$(yq -N '.spec.endpoints[].port' "$REAL"/*/kromgo/ServiceMonitor.monitoring.coreos.com_kromgo_kromgo.yaml)" \
    yq '.spec.ports[] | select(.name == strenv(P)) | .targetPort' "$REAL"/*/kromgo/Service_kromgo_kromgo.yaml)
  [[ $metrics =~ ^[0-9]+$ && $metrics != 8080 ]] || { echo "kromgo's monitor scrapes no one numbered port apart from its badges: $metrics"; return 1; }
  allowed "$VIEW" "$PROMETHEUS" "$KROMGO" "$metrics/tcp"
  denied "$VIEW" "$PROMETHEUS" "$KROMGO" 8080/tcp
  denied "$VIEW" monitoring/Deployment/kube-prometheus-stack-kube-state-metrics "$KROMGO" "$metrics/tcp"
  # The kubelet reaches the probe port of every pod of the namespaces that deny by default,
  # proxies included, which no render holds: Envoy Gateway v1.10.0 probes the envoy container on
  # its readiness port 19003 (internal/xds/bootstrap/bootstrap.go,
  # internal/infrastructure/kubernetes/proxy/resource.go) and the shutdown manager on 19002
  # (internal/cmd/envoy/shutdown_manager.go); 19001 is the stats port, which no probe uses.
  allowed "$VIEW" @host "$PROXY" 19003/tcp
  allowed "$VIEW" @host "$PROXY" 19002/tcp
  denied "$VIEW" @host "$PROXY" 19001/tcp
  local probes pod port
  probes=$(yq -N -o json -I0 'select(. != null)' "$VIEW"/*/*/*.yaml | jq -r '
    select(.kind | IN("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"))
    | select(.metadata.namespace | IN("ascender", "backstage", "demo", "envoy-gateway-system", "kromgo", "open-feature-operator", "security-system", "sso-system"))
    | . as $w
    | (if .kind == "CronJob" then .spec.jobTemplate.spec.template else .spec.template end).spec.containers[]
    | . as $c
    | [$c.readinessProbe, $c.livenessProbe, $c.startupProbe][] | select(. != null)
    | (.httpGet.port // .tcpSocket.port // .grpc.port) as $p
    | select($p != null)
    | ($p | if type == "number" then . else (($c.ports // [])[] | select(.name == $p) | .containerPort) end) as $n
    | "\($w.metadata.namespace)/\($w.kind)/\($w.metadata.name) \($n)"' | sort -u)
  [ -n "$probes" ]
  while read -r pod port; do
    allowed "$VIEW" @host "$pod" "$port/tcp"
  done <<<"$probes"
  # Each such pod is among those the evaluator knows: a workload the probe list names is not a typo.
  [[ $probes == *"demo/Deployment/hello 8080"* ]]
  [[ $probes == *"envoy-gateway-system/Deployment/envoy-gateway 8081"* ]]
  [[ $probes == *"kromgo/Deployment/kromgo 8080"* ]]
  [[ $probes == *"sso-system/Deployment/dex 5558"* ]]
  [[ $probes == *"sso-system/Deployment/oauth2-proxy 4180"* ]]
  [[ $probes == *"backstage/Deployment/backstage 7007"* ]]
  [[ $probes == *"security-system/DaemonSet/falco 8765"* ]]
  [[ $probes == *"open-feature-operator/Deployment/open-feature-operator-controller-manager 8081"* ]]
  # The database's instances, which no render holds, are probed on the status port, where the pinned
  # operator puts its startup, liveness and readiness probes (pkg/specs/pods.go), and on no other.
  allowed "$VIEW" @host "$BACKSTAGE_DB" 8000/tcp
  denied "$VIEW" @host "$BACKSTAGE_DB" 5432/tcp
  # The ports the proxies' egress names in each labelled namespace are exactly the container ports
  # the Gateway's routes send to in that namespace, read from the render. A route to a backend on
  # another port, or in another labelled namespace, fails here until the rules name it.
  local routed named
  routed=$(routed_ports "$REAL")
  named=$(proxies_egress "$VIEW")
  echo "the routes' backends' container ports: $routed; the proxies' egress to the labelled namespaces: ${named:-every port}"
  [[ " $routed " == *" demo:8080 "* && " $routed " == *" ai-system:5678 "* && " $routed " == *" ai-system:8080 "* \
    && " $routed " == *" kromgo:8080 "* && " $routed " == *" backstage:7007 "* && " $routed " == *" ascender:8052 "* ]]
  [[ " $routed " == *" sso-system:4180 "* && " $routed " == *" sso-system:5556 "* ]]
  [[ " $routed " == *" monitoring:9428 "* ]]
  [ "$named" = "$routed" ]
  # A route to a backend in a namespace without the Gateway label, or behind a Service without a
  # selector, has no port the comparison could name, and fails it saying why.
  local backends="$BATS_TEST_TMPDIR/backends"
  mkdir -p "$backends"
  (cd "$REAL" && find . -type f \( -name 'HTTPRoute.*' -o -name 'Service_*' -o -name 'Deployment.apps_*' -o -name 'StatefulSet.apps_*' \
    -o -name 'DaemonSet.apps_*' -o -name 'Namespace_*' -o -name 'Gateway.gateway.networking.k8s.io_*' \) -exec cp --parents {} "$backends/" \;)
  cp -R "$backends" "$backends-unlabelled"
  yq -i '.spec.rules[0].backendRefs[0] |= (.namespace = "openbao" | .name = "openbao" | .port = 8200)' \
    "$backends-unlabelled"/*/*/HTTPRoute.gateway.networking.k8s.io_demo_hello.yaml
  run routed_ports "$backends-unlabelled"
  [ "$status" -ne 0 ] && [[ $output == *"sends to openbao/openbao, but openbao does not carry the label the Gateway public takes routes by"* ]] \
    || { echo "a backend in a namespace without the label: $output"; return 1; }
  cp -R "$backends" "$backends-selectorless"
  yq -i 'del(.spec.selector)' "$backends-selectorless"/*/*/Service_demo_hello.yaml
  run routed_ports "$backends-selectorless"
  [ "$status" -ne 0 ] && [[ $output == *"the Service demo/hello, which a route sends to, has no selector"* ]] \
    || { echo "a backend behind a Service without a selector: $output"; return 1; }
  # Each way of widening that egress, which the evaluation answers allowed for, fails the
  # comparison: a port entry with no protocol, a range, a second policy that selects the proxies
  # by one of their labels, and the labelled namespaces written as an expression.
  local case dir policy port
  local -A says=([no-protocol]='cannot compare' [end-port]='cannot compare' [one-label]=8000 [expressions]=8000)
  for case in no-protocol end-port one-label expressions; do
    dir="$BATS_TEST_TMPDIR/$case"
    cp -R "$VIEW" "$dir"
    policy=$(echo "$dir"/*/*/CiliumNetworkPolicy.cilium.io_envoy-gateway-system_public-proxy.yaml)
    case $case in
      no-protocol) yq -i '(.spec.egress[] | select(.toPorts[0].ports | any_c(.port == "5678")) | .toPorts[0].ports) += [{"port": "8000"}]' "$policy" ;;
      end-port) yq -i '(.spec.egress[].toPorts[].ports[] | select(.port == "5678")).endPort = 5679' "$policy" ;;
      one-label) cat >"${policy%_*}_widened.yaml" <<'E' ;;
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: widened
  namespace: envoy-gateway-system
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/component: proxy
  enableDefaultDeny: {ingress: false, egress: false}
  egress:
    - toEndpoints: [{matchLabels: {"k8s:io.cilium.k8s.namespace.labels.k8s-gitops/gateway": public}}]
      toPorts: [{ports: [{port: "8000", protocol: TCP}]}]
E
      expressions) yq -i '.spec.egress += [{"toEndpoints": [{"matchExpressions": [{"key": "k8s:io.cilium.k8s.namespace.labels.k8s-gitops/gateway",
          "operator": "In", "values": ["public"]}]}], "toPorts": [{"ports": [{"port": "8000", "protocol": "TCP"}]}]}]' "$policy" ;;
    esac
    port=8000
    [ "$case" != end-port ] || port=5679
    run "$REPO/scripts/network-policy-check" --reach-egress "$dir" "$PROXY" ai-system/Deployment/n8n "$port/tcp"
    [ "$status" -eq 0 ] || { echo "$case is no widening: $output"; return 1; }
    run proxies_egress "$dir"
    [ "$output" != "$routed" ] && [[ $output == *"${says[$case]}"* ]] || { echo "$case passes the comparison: $output"; return 1; }
  done
}

# probe_ports RENDER: the container port of the proxies each Probe of RENDER asks for, sorted and
# unique: a Probe's target names the proxies' Service, which takes the port of the public Gateway's
# listener of the target's scheme, https or http, where it names none, and Envoy Gateway serves a
# listener under 1024 on its port plus 10000. A target that names a port, or a scheme no listener
# has, fails it.
probe_ports() {
  (set -o pipefail; yq -N -o json -I0 'select(. != null)' "$1"/*/*/Probe.monitoring.coreos.com_*.yaml \
    "$1"/*/*/Gateway.gateway.networking.k8s.io_*.yaml | jq -s -r '
    ([ .[] | select(.kind == "Gateway" and .metadata.namespace == "envoy-gateway-system" and .metadata.name == "public") ][0]
      // error("no Gateway public")) as $gw
    | [ .[] | select(.kind == "Probe") | .spec.targets.staticConfig.static[]
        | capture("^(?<scheme>https?)://(?<host>[^/:]+)(?<port>:[0-9]+)?(/|$)") // error("the target \(.) is not http or https")
        | if .port != null then error("the target names the port \(.port), which this test does not map to a listener") else . end
        | .scheme | ascii_upcase as $protocol
        | ([ $gw.spec.listeners[] | select(.protocol == $protocol) | .port ] | unique
           | if length == 1 then .[0] else error("the Gateway has not one listener of \($protocol)") end)
        | if . < 1024 then . + 10000 else . end ]
    | unique | map(tostring) | join(" ")')
}

@test "The probes of the public hostnames reach the Gateway's listeners from inside the cluster, and no other pod does" {
  real_render
  local exporter ports port pod pods taken=()
  # The exporter is the workload whose pods the Service of the Probes' prober selects: the prober is
  # that Service's cluster name and port, the same for every Probe.
  exporter=$(yq -N -o json -I0 'select(. != null)' "$REAL"/*/*/Probe.monitoring.coreos.com_*.yaml "$REAL"/*/*/Service_*.yaml \
    "$REAL"/*/*/Deployment.apps_*.yaml | jq -s -r '
    ([ .[] | select(.kind == "Probe") | .spec.prober.url ] | unique
      | if length == 1 then .[0] else error("the Probes name not one prober: \(.)") end
      | capture("^(?<name>[a-z0-9-]+)\\.(?<ns>[a-z0-9-]+)\\.svc\\.cluster\\.local:(?<port>[0-9]+)$")
      // error("the prober is no Service by its cluster name")) as $p
    | ([ .[] | select(.kind == "Service" and .metadata.name == $p.name and .metadata.namespace == $p.ns) ][0]
      // error("no Service \($p.ns)/\($p.name)")) as $svc
    | [ .[] | select(.kind == "Deployment" and .metadata.namespace == $p.ns)
        | select(.spec.template.metadata.labels as $l | $svc.spec.selector | to_entries | all(.[]; $l[.key] == .value))
        | "\(.metadata.namespace)/Deployment/\(.metadata.name)" ]
    | if length == 1 then .[0] else error("not one Deployment behind \($p.ns)/\($p.name)") end')
  echo "the exporter: $exporter"
  [ "$exporter" = monitoring/Deployment/blackbox-exporter ]
  # A Probe's target is the proxies' Service by its cluster name (tests/probes.bats), whose address
  # Cilium translates to a proxy's before policy applies: the proxies see the exporter's pods, not
  # the world, on the container port of the listener the target's scheme names.
  ports=$(probe_ports "$REAL")
  echo "the listener ports the Probes ask for: $ports"
  [ "$ports" = "10080 10443" ]
  for port in $ports; do
    allowed "$VIEW" "$exporter" "$PROXY" "$port/tcp"
  done
  # And no other port of the proxies: not their readiness, shutdown, stats or admin port.
  for port in 19000 19001 19002 19003 22; do
    denied "$VIEW" "$exporter" "$PROXY" "$port/tcp"
  done
  # A probe goes through the proxies: the exporter reaches no backend in a namespace that denies by
  # default, nor the Gateway's controller.
  denied "$VIEW" "$exporter" demo/Deployment/hello 8080/tcp
  denied "$VIEW" "$exporter" "$KROMGO" 8080/tcp
  denied "$VIEW" "$exporter" envoy-gateway-system/Deployment/envoy-gateway 18000/tcp
  # The exporter's are the only pods the proxies take on those ports from inside the cluster: every
  # workload of the render, in every namespace, and the pods the operators make at run time.
  mapfile -t pods < <(yq -N -o json -I0 'select(. != null)' "$VIEW"/*/*/*.yaml | jq -r '
    select(.kind | IN("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "Pod"))
    | select((.metadata.namespace // "") != "") | "\(.metadata.namespace)/\(.kind)/\(.metadata.name)"' | sort -u)
  [ "${#pods[@]}" -gt 30 ]
  pods+=("$PROMETHEUS" "$MOVER" "$N8N_DB" "$STORAGE" "$OTHER_APP")
  for pod in "${pods[@]}"; do
    for port in $ports; do
      run "$REPO/scripts/network-policy-check" --reach-ingress "$VIEW" "$pod" "$PROXY" "$port/tcp"
      case $status in
        0) taken+=("$pod:$port") ;;
        1) ;;
        *) echo "no answer for $pod on $port: $output"; return 1 ;;
      esac
    done
  done
  echo "taken on the listener ports from inside the cluster, of ${#pods[@]} sources: ${taken[*]}"
  [ "${taken[*]}" = "$exporter:10080 $exporter:10443" ]
}

@test "A pod of an application cannot reach the secret store, the storage controller or another application" {
  real_render
  local pods=(demo/Deployment/hello demo/Deployment/volsync-demo "$MOVER" "$KROMGO" "$BACKSTAGE" "$PGDUMP" "$FALCO")
  local pod
  for pod in "${pods[@]}"; do
    denied "$VIEW" "$pod" openbao/StatefulSet/openbao 8200/tcp
    denied "$VIEW" "$pod" openbao/StatefulSet/openbao 8201/tcp
    denied "$VIEW" "$pod" "$STORAGE" 3370/tcp
    denied "$VIEW" "$pod" "$STORAGE" 3371/tcp
    denied "$VIEW" "$pod" "$OTHER_APP" 8080/tcp
    denied "$VIEW" "$pod" ai-system/Deployment/n8n 5678/tcp
    denied "$VIEW" "$pod" ai-system/Deployment/open-webui 8080/tcp
    denied "$VIEW" "$pod" envoy-gateway-system/Deployment/envoy-gateway 18000/tcp
    denied "$VIEW" "$pod" "$PROXY" 10443/tcp
    denied "$VIEW" "$pod" external-secrets/Deployment/external-secrets 8080/tcp
    denied "$VIEW" "$pod" @kube-apiserver 6443/tcp
    denied "$VIEW" "$pod" @host 10250/tcp
    denied "$VIEW" "$pod" openbao/StatefulSet/openbao 53/udp
    denied "$VIEW" "$pod" "$OTHER_APP" 53/udp
  done
  # The application pods open no connection at all; the movers resolve names through the cluster's
  # resolver and nothing else.
  denied "$VIEW" demo/Deployment/hello "$DNS" 53/udp
  denied "$VIEW" demo/Deployment/volsync-demo "$DNS" 53/udp
  allowed "$VIEW" "$MOVER" "$DNS" 53/udp
  allowed "$VIEW" "$MOVER" "$DNS" 53/tcp
  denied "$VIEW" "$MOVER" "$DNS" 9153/tcp
  # Neither reaches the other, and nothing else of demo reaches either.
  denied "$VIEW" demo/Deployment/hello demo/Deployment/volsync-demo 8080/tcp
  denied "$VIEW" demo/Deployment/volsync-demo demo/Deployment/hello 8080/tcp
  denied "$VIEW" "$MOVER" demo/Deployment/hello 8080/tcp
  denied "$VIEW" "$MOVER" demo/Deployment/volsync-demo 8080/tcp
  denied "$VIEW" "$OTHER_APP" demo/Deployment/hello 8080/tcp
  denied "$VIEW" openbao/StatefulSet/openbao demo/Deployment/hello 8080/tcp
  # kromgo resolves the name of the Prometheus its configuration names and reaches the pods that
  # Service selects, by its selector, on the port it sends kromgo's queries to, all read from the
  # render; no other port of them, no other pod of monitoring, nothing outside the cluster.
  local url name ns port service upstream target
  url=$(yq '.spec.template.spec.containers[0].env[] | select(.name == "KROMGO_PROMETHEUS_URL") | .value' \
    "$REAL"/*/kromgo/Deployment.apps_kromgo_kromgo.yaml)
  [[ $url =~ ^http://([a-z0-9-]+)\.([a-z0-9-]+)\.svc:([0-9]+)$ ]] || { echo "kromgo's Prometheus is no Service of the cluster by its name and port: $url"; return 1; }
  name=${BASH_REMATCH[1]} ns=${BASH_REMATCH[2]} port=${BASH_REMATCH[3]}
  service=$(echo "$REAL"/*/*/"Service_${ns}_${name}.yaml")
  [ -f "$service" ] || { echo "kromgo's Prometheus, $ns/$name, is no Service of the render"; return 1; }
  upstream="$ns:$(yq -o json -I0 '.spec.selector' "$service" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')"
  target=$(P=$port yq '.spec.ports[] | select(.port == env(P)) | .targetPort' "$service")
  [[ $target =~ ^[0-9]+$ ]] || { echo "the Service $ns/$name sends port $port to no one numbered port: $target"; return 1; }
  allowed "$VIEW" "$KROMGO" "$DNS" 53/udp
  allowed "$VIEW" "$KROMGO" "$DNS" 53/tcp
  denied "$VIEW" "$KROMGO" "$DNS" 9153/tcp
  allowed "$VIEW" "$KROMGO" "$upstream" "$target/tcp"
  denied "$VIEW" "$KROMGO" "$upstream" 8080/tcp
  denied "$VIEW" "$KROMGO" "$PROMETHEUS" "$target/tcp"
  denied "$VIEW" "$KROMGO" monitoring/Deployment/kube-prometheus-stack-kube-state-metrics "$target/tcp"
  denied "$VIEW" "$KROMGO" monitoring/Deployment/kube-prometheus-stack-kube-state-metrics 8080/tcp
  denied "$VIEW" "$KROMGO" monitoring/StatefulSet/victoria-logs 9428/tcp
  denied "$VIEW" "$KROMGO" @world 443/tcp
  # No other application's pod reaches kromgo, and kromgo reaches none.
  denied "$VIEW" "$OTHER_APP" "$KROMGO" 8080/tcp
  denied "$VIEW" demo/Deployment/hello "$KROMGO" 8080/tcp
  denied "$VIEW" "$MOVER" "$KROMGO" 8080/tcp
  denied "$VIEW" ai-system/Deployment/n8n "$KROMGO" 8080/tcp
  denied "$VIEW" "$KROMGO" demo/Deployment/hello 8080/tcp
  # Falco's pods take Prometheus' scrape of the port of its Service that its monitor names, read from
  # the render, and the kubelet's probes on it, and nothing else; they reach the cluster's resolver
  # on 53, for the name the image's rule "Contact K8S API Server From Container" compares, and
  # nothing else, not the API server, the nodes or anything outside the cluster: Falco reads the
  # runtime's socket and the node's files through host paths, and writes its events to standard
  # output.
  local falco_metrics
  falco_metrics=$(P="$(yq -N '.spec.endpoints[].port' "$REAL"/*/falco/ServiceMonitor.monitoring.coreos.com_security-system_falco.yaml)" \
    yq '.spec.ports[] | select(.name == strenv(P)) | .targetPort' "$REAL"/*/falco/Service_security-system_falco-metrics.yaml)
  [[ $falco_metrics =~ ^[0-9]+$ ]] || { echo "Falco's monitor scrapes no one numbered port: $falco_metrics"; return 1; }
  allowed "$VIEW" "$PROMETHEUS" "$FALCO" "$falco_metrics/tcp"
  allowed "$VIEW" @host "$FALCO" "$falco_metrics/tcp"
  denied "$VIEW" "$PROMETHEUS" "$FALCO" 22/tcp
  denied "$VIEW" monitoring/Deployment/kube-prometheus-stack-kube-state-metrics "$FALCO" "$falco_metrics/tcp"
  denied "$VIEW" "$OTHER_APP" "$FALCO" "$falco_metrics/tcp"
  denied "$VIEW" demo/Deployment/hello "$FALCO" "$falco_metrics/tcp"
  denied "$VIEW" "$KROMGO" "$FALCO" "$falco_metrics/tcp"
  denied "$VIEW" "$PROXY" "$FALCO" "$falco_metrics/tcp"
  denied "$VIEW" @world "$FALCO" "$falco_metrics/tcp"
  denied "$VIEW" @remote-node "$FALCO" "$falco_metrics/tcp"
  denied "$VIEW" @kube-apiserver "$FALCO" "$falco_metrics/tcp"
  allowed "$VIEW" "$FALCO" "$DNS" 53/udp
  allowed "$VIEW" "$FALCO" "$DNS" 53/tcp
  denied "$VIEW" "$FALCO" "$DNS" 9153/tcp
  denied "$VIEW" "$FALCO" @kube-apiserver 443/tcp
  denied "$VIEW" "$FALCO" @world 443/tcp
  denied "$VIEW" "$FALCO" @world 80/tcp
  denied "$VIEW" "$FALCO" @remote-node 10250/tcp
  denied "$VIEW" "$FALCO" "$PROMETHEUS" 9090/tcp
  denied "$VIEW" "$FALCO" monitoring/StatefulSet/victoria-logs 9428/tcp
  # The backup movers reach the object storage on 443 and no other port of the world; the other
  # pods reach none of it.
  allowed "$VIEW" "$MOVER" @world 443/tcp
  denied "$VIEW" "$MOVER" @world 80/tcp
  # That is the port of the endpoint as cluster-config's example gives it: 443 for one that names
  # none, as the validation of the endpoint (scripts/lib/s3.sh) allows, or the port it names.
  local endpoint s3_port
  endpoint=$(yq '.S3_ENDPOINT' "$REPO/kubernetes/clusters/lab-sto2/cluster-config.example.yaml")
  [[ $endpoint =~ ^https://[^/:]+(:([0-9]+))?$ ]]
  s3_port=${BASH_REMATCH[2]:-443}
  allowed "$VIEW" "$MOVER" @world "$s3_port/tcp"
  denied "$VIEW" demo/Deployment/hello @world 443/tcp
  denied "$VIEW" demo/Deployment/volsync-demo @world 443/tcp
  # Backstage resolves its database's name and reaches the database's instances on PostgreSQL's port,
  # the one a failover moves the primary between, and nothing else: no other port of them, no other
  # application's database or pod, not the API server, nothing outside the cluster on any port.
  allowed "$VIEW" "$BACKSTAGE" "$DNS" 53/udp
  allowed "$VIEW" "$BACKSTAGE" "$DNS" 53/tcp
  denied "$VIEW" "$BACKSTAGE" "$DNS" 9153/tcp
  allowed "$VIEW" "$BACKSTAGE" "$BACKSTAGE_DB" 5432/tcp
  allowed "$VIEW" "$BACKSTAGE" "$BACKSTAGE_DB_REPLICA" 5432/tcp
  denied "$VIEW" "$BACKSTAGE" "$BACKSTAGE_DB" 8000/tcp
  denied "$VIEW" "$BACKSTAGE" "$BACKSTAGE_DB" 9187/tcp
  denied "$VIEW" "$BACKSTAGE" "$BACKSTAGE_DB_JOIN" 5432/tcp
  denied "$VIEW" "$BACKSTAGE" "$N8N_DB" 5432/tcp
  denied "$VIEW" "$BACKSTAGE" "$KROMGO" 8080/tcp
  denied "$VIEW" "$BACKSTAGE" "$PGDUMP" 5432/tcp
  local port
  for port in 443 80 22 5432 53; do
    denied "$VIEW" "$BACKSTAGE" @world "$port/tcp"
  done
  denied "$VIEW" "$BACKSTAGE" @world 53/udp
  denied "$VIEW" "$BACKSTAGE" @kube-apiserver 443/tcp
  # No other application's pod, nor the database, reaches Backstage.
  denied "$VIEW" "$OTHER_APP" "$BACKSTAGE" 7007/tcp
  denied "$VIEW" "$KROMGO" "$BACKSTAGE" 7007/tcp
  denied "$VIEW" ai-system/Deployment/n8n "$BACKSTAGE" 7007/tcp
  denied "$VIEW" "$BACKSTAGE_DB" "$BACKSTAGE" 7007/tcp
  # The dump job resolves the Services' names, reaches the instances on PostgreSQL's port, and the
  # world on 443 alone, for the age release and the object storage (docs/kubernetes.md, Dumps).
  allowed "$VIEW" "$PGDUMP" "$DNS" 53/udp
  allowed "$VIEW" "$PGDUMP" "$BACKSTAGE_DB" 5432/tcp
  allowed "$VIEW" "$PGDUMP" "$BACKSTAGE_DB_REPLICA" 5432/tcp
  denied "$VIEW" "$PGDUMP" "$BACKSTAGE_DB" 8000/tcp
  denied "$VIEW" "$PGDUMP" "$BACKSTAGE" 7007/tcp
  allowed "$VIEW" "$PGDUMP" @world 443/tcp
  denied "$VIEW" "$PGDUMP" @world 80/tcp
  denied "$VIEW" "$PGDUMP" @world 5432/tcp
  # The database: the operator reaches every pod of the cluster on the status port and PostgreSQL's,
  # as its documentation asks, the cluster's pods reach each other, a joining instance among them,
  # and the API server, and Prometheus scrapes the exporter's port; nothing else reaches them. The
  # instances, whose pods hold the Barman Cloud plugin's sidecar, reach the object storage, the
  # world on 443 and on the port cluster-config's example gives the endpoint, for the WAL archive
  # and the base backups (docs/kubernetes.md, Backups and restores), and no other port of it; a
  # job that creates or joins an instance holds no sidecar and reaches nothing outside the cluster.
  allowed "$VIEW" "$CNPG_OPERATOR" "$BACKSTAGE_DB" 8000/tcp
  allowed "$VIEW" "$CNPG_OPERATOR" "$BACKSTAGE_DB" 5432/tcp
  allowed "$VIEW" "$CNPG_OPERATOR" "$BACKSTAGE_DB_JOIN" 8000/tcp
  denied "$VIEW" "$CNPG_OPERATOR" "$BACKSTAGE_DB" 9187/tcp
  denied "$VIEW" "$CNPG_OPERATOR" "$BACKSTAGE" 7007/tcp
  denied "$VIEW" cnpg-system:app.kubernetes.io/name=other "$BACKSTAGE_DB" 8000/tcp
  allowed "$VIEW" "$BACKSTAGE_DB_REPLICA" "$BACKSTAGE_DB" 5432/tcp
  allowed "$VIEW" "$BACKSTAGE_DB" "$BACKSTAGE_DB_REPLICA" 5432/tcp
  allowed "$VIEW" "$BACKSTAGE_DB_JOIN" "$BACKSTAGE_DB" 5432/tcp
  allowed "$VIEW" "$BACKSTAGE_DB" "$DNS" 53/udp
  allowed "$VIEW" "$BACKSTAGE_DB" @kube-apiserver 6443/tcp
  allowed "$VIEW" "$BACKSTAGE_DB_JOIN" @kube-apiserver 6443/tcp
  allowed "$VIEW" "$PROMETHEUS" "$BACKSTAGE_DB" 9187/tcp
  denied "$VIEW" "$PROMETHEUS" "$BACKSTAGE_DB" 5432/tcp
  allowed "$VIEW" "$BACKSTAGE_DB" @world 443/tcp
  allowed "$VIEW" "$BACKSTAGE_DB_REPLICA" @world 443/tcp
  allowed "$VIEW" "$BACKSTAGE_DB" @world "$s3_port/tcp"
  denied "$VIEW" "$BACKSTAGE_DB" @world 80/tcp
  denied "$VIEW" "$BACKSTAGE_DB" @world 5432/tcp
  denied "$VIEW" "$BACKSTAGE_DB" @world 53/udp
  denied "$VIEW" "$BACKSTAGE_DB_JOIN" @world 443/tcp
  denied "$VIEW" "$BACKSTAGE_DB" openbao/StatefulSet/openbao 8200/tcp
  denied "$VIEW" "$BACKSTAGE_DB" "$N8N_DB" 5432/tcp
  denied "$VIEW" "$N8N_DB" "$BACKSTAGE_DB" 5432/tcp
  denied "$VIEW" "$OTHER_APP" "$BACKSTAGE_DB" 5432/tcp
  denied "$VIEW" ai-system/Deployment/n8n "$BACKSTAGE_DB" 5432/tcp
  denied "$VIEW" "$MOVER" "$BACKSTAGE_DB" 5432/tcp
  denied "$VIEW" "$KROMGO" "$BACKSTAGE_DB" 5432/tcp
  # The OpenFeature Operator's pod takes Prometheus on the port its PodMonitor names and the API
  # server's calls to its webhooks on the port its webhook Service targets, both read from the
  # render: the calls arrive as the API server, as the local host or as another node's host. It
  # reaches the API server and nothing else: it looks no name up and calls nothing outside the
  # cluster, the secret store or another application. Nothing else reaches either port.
  local open_feature_metrics open_feature_webhook
  open_feature_metrics=$(P="$(yq -N '.spec.podMetricsEndpoints[].port' "$REAL"/*/open-feature-operator/PodMonitor.monitoring.coreos.com_open-feature-operator_open-feature-operator.yaml)" \
    yq '.spec.template.spec.containers[].ports[] | select(.name == strenv(P)) | .containerPort' \
    "$REAL"/*/open-feature-operator/Deployment.apps_open-feature-operator_open-feature-operator-controller-manager.yaml)
  open_feature_webhook=$(yq '.spec.ports[].targetPort' "$REAL"/*/open-feature-operator/Service_open-feature-operator_open-feature-operator-webhook-service.yaml)
  [[ $open_feature_metrics =~ ^[0-9]+$ && $open_feature_webhook =~ ^[0-9]+$ && $open_feature_metrics != "$open_feature_webhook" ]] ||
    { echo "the operator's monitor and webhook Service name no two numbered ports: $open_feature_metrics, $open_feature_webhook"; return 1; }
  allowed "$VIEW" "$PROMETHEUS" "$OPEN_FEATURE" "$open_feature_metrics/tcp"
  allowed "$VIEW" @kube-apiserver "$OPEN_FEATURE" "$open_feature_webhook/tcp"
  allowed "$VIEW" @host "$OPEN_FEATURE" "$open_feature_webhook/tcp"
  allowed "$VIEW" @remote-node "$OPEN_FEATURE" "$open_feature_webhook/tcp"
  allowed "$VIEW" "$OPEN_FEATURE" @kube-apiserver 443/tcp
  allowed "$VIEW" "$OPEN_FEATURE" @kube-apiserver 6443/tcp
  denied "$VIEW" @world "$OPEN_FEATURE" "$open_feature_webhook/tcp"
  denied "$VIEW" "$OTHER_APP" "$OPEN_FEATURE" "$open_feature_webhook/tcp"
  denied "$VIEW" demo/Deployment/hello "$OPEN_FEATURE" "$open_feature_webhook/tcp"
  denied "$VIEW" "$PROMETHEUS" "$OPEN_FEATURE" "$open_feature_webhook/tcp"
  denied "$VIEW" @kube-apiserver "$OPEN_FEATURE" "$open_feature_metrics/tcp"
  denied "$VIEW" @remote-node "$OPEN_FEATURE" "$open_feature_metrics/tcp"
  denied "$VIEW" @world "$OPEN_FEATURE" "$open_feature_metrics/tcp"
  denied "$VIEW" "$OTHER_APP" "$OPEN_FEATURE" "$open_feature_metrics/tcp"
  denied "$VIEW" monitoring/Deployment/kube-prometheus-stack-kube-state-metrics "$OPEN_FEATURE" "$open_feature_metrics/tcp"
  denied "$VIEW" "$OPEN_FEATURE" @world 443/tcp
  denied "$VIEW" "$OPEN_FEATURE" @world 80/tcp
  denied "$VIEW" "$OPEN_FEATURE" "$DNS" 53/udp
  denied "$VIEW" "$OPEN_FEATURE" openbao/StatefulSet/openbao 8200/tcp
  denied "$VIEW" "$OPEN_FEATURE" "$STORAGE" 3370/tcp
  denied "$VIEW" "$OPEN_FEATURE" "$OTHER_APP" 8080/tcp
  denied "$VIEW" "$OPEN_FEATURE" ai-system/Deployment/n8n 5678/tcp
  denied "$VIEW" "$OPEN_FEATURE" demo/Deployment/hello 8080/tcp
  denied "$VIEW" "$OPEN_FEATURE" @host 10250/tcp
}

@test "The restore drill's mover has the movers' flows and its check job has none" {
  real_render
  local destination job drill_mover check=demo/CronJob/volsync-demo-drill-check endpoint s3 port peer
  # The ReplicationDestination of volsync-demo's drill, whose mover VolSync runs, and the check's
  # CronJob, whose pod template the render holds.
  destination=$(echo "$REAL"/*/volsync-demo/ReplicationDestination.volsync.backube_demo_volsync-demo-drill.yaml)
  [ -f "$destination" ] || { echo "the render holds no ReplicationDestination volsync-demo-drill"; return 1; }
  [ -f "$(echo "$VIEW"/*/volsync-demo/CronJob.batch_demo_volsync-demo-drill-check.yaml)" ] ||
    { echo "the render holds no CronJob volsync-demo-drill-check"; return 1; }
  # The labels of the mover's pod at the pinned VolSync, v0.17.0: the restic mover's ensureJob
  # (internal/controller/mover/restic/mover.go) names the Job volsync-dst-<name> and labels its pod
  # template app.kubernetes.io/created-by: volsync (utils.SetOwnedByVolSync, labels.go), which only
  # spec.restic.moverPodLabels would add to; the Job controller adds the Job's name and uid.
  [ "$(yq '.spec.restic.moverPodLabels // {} | length' "$destination")" -eq 0 ]
  job="volsync-dst-$(yq '.metadata.name' "$destination")"
  drill_mover="demo:app.kubernetes.io/created-by=volsync,batch.kubernetes.io/job-name=$job,job-name=$job,batch.kubernetes.io/controller-uid=marker-uid,controller-uid=marker-uid"
  # The mover resolves the repository's name through the cluster's resolver and reaches the object
  # storage on the port of its endpoint as cluster-config's example gives it, and nothing else.
  endpoint=$(yq '.S3_ENDPOINT' "$REPO/kubernetes/clusters/lab-sto2/cluster-config.example.yaml")
  [[ $endpoint =~ ^https://[^/:]+(:([0-9]+))?$ ]]
  s3=${BASH_REMATCH[2]:-443}
  allowed "$VIEW" "$drill_mover" "$DNS" 53/udp
  allowed "$VIEW" "$drill_mover" "$DNS" 53/tcp
  allowed "$VIEW" "$drill_mover" @world "$s3/tcp"
  denied "$VIEW" "$drill_mover" "$DNS" 9153/tcp
  for port in 80 22 53 5432 6443 8080; do
    [ "$port" = "$s3" ] || denied "$VIEW" "$drill_mover" @world "$port/tcp"
  done
  for peer in @kube-apiserver @host @remote-node; do
    for port in 443 6443 10250; do
      denied "$VIEW" "$drill_mover" "$peer" "$port/tcp"
    done
  done
  denied "$VIEW" "$drill_mover" demo/Deployment/hello 8080/tcp
  denied "$VIEW" "$drill_mover" demo/Deployment/volsync-demo 8080/tcp
  denied "$VIEW" "$drill_mover" "$check" 8080/tcp
  denied "$VIEW" "$drill_mover" openbao/StatefulSet/openbao 8200/tcp
  denied "$VIEW" "$drill_mover" "$STORAGE" 3370/tcp
  # The check job, by the labels of its pod template in the render, reaches nothing on any port tried:
  # not the resolver, the object storage's port, the API server, a node's kubelet, another pod of
  # demo, the secret store or the world.
  for port in 53/udp 53/tcp 9153/tcp; do
    denied "$VIEW" "$check" "$DNS" "$port"
  done
  for port in "$s3/tcp" 443/tcp 80/tcp 53/udp 53/tcp 22/tcp; do
    denied "$VIEW" "$check" @world "$port"
  done
  for peer in @kube-apiserver @host @remote-node; do
    for port in 443 6443 10250; do
      denied "$VIEW" "$check" "$peer" "$port/tcp"
    done
  done
  denied "$VIEW" "$check" demo/Deployment/hello 8080/tcp
  denied "$VIEW" "$check" demo/Deployment/volsync-demo 8080/tcp
  denied "$VIEW" "$check" "$drill_mover" 8080/tcp
  denied "$VIEW" "$check" "$MOVER" 443/tcp
  denied "$VIEW" "$check" openbao/StatefulSet/openbao 8200/tcp
  denied "$VIEW" "$check" openbao/StatefulSet/openbao 8201/tcp
  denied "$VIEW" "$check" "$STORAGE" 3370/tcp
  denied "$VIEW" "$check" "$OTHER_APP" 8080/tcp
  # Nothing reaches either.
  for peer in "$drill_mover" "$check"; do
    denied "$VIEW" @world "$peer" 443/tcp
    denied "$VIEW" @remote-node "$peer" 8080/tcp
    denied "$VIEW" demo/Deployment/hello "$peer" 8080/tcp
    denied "$VIEW" demo/Deployment/volsync-demo "$peer" 8080/tcp
    denied "$VIEW" "$PROMETHEUS" "$peer" 8080/tcp
    denied "$VIEW" "$PROXY" "$peer" 8080/tcp
    denied "$VIEW" "$OTHER_APP" "$peer" 8080/tcp
  done
}

@test "An allow that names an address fails the check" {
  local name rule
  local -A rules=(
    [cidr]='egress: [{toCIDR: ["192.0.2.0/24"]}]'
    [cidr-set]='egress: [{toCIDRSet: [{cidr: "198.51.100.0/24"}]}]'
    [from-cidr]='ingress: [{fromCIDR: ["203.0.113.5/32"]}]'
    [label-address]='ingress: [{fromEndpoints: [{matchLabels: {peer: "198.51.100.7"}}]}]'
    [v6]='egress: [{toCIDR: ["2001:db8::/32"]}]'
  )
  for name in "${!rules[@]}"; do
    rule=${rules[$name]}
    tree "$name"
    add_policy "$name" "CiliumNetworkPolicy.cilium.io_web_$name.yaml" <<E
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: $name
  namespace: web
  annotations:
    k8s-gitops/network-policy-reason: the reason does not excuse an address
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: site
  enableDefaultDeny: {ingress: false, egress: false}
  $rule
E
    check "$name"
    [ "$status" -eq 1 ] || { echo "$name: $output"; return 1; }
    [[ $output == *"namespace web"* && $output == *"CiliumNetworkPolicy/$name"* && $output == *"address"* ]] || { echo "$name: $output"; return 1; }
  done
  # An address block of a Kubernetes NetworkPolicy.
  tree block
  add_policy block NetworkPolicy.networking.k8s.io_web_block.yaml <<'E'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block
  namespace: web
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - ipBlock:
            cidr: 192.0.2.0/24
E
  check block
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web"* && $output == *"NetworkPolicy/block"* && $output == *"address"* ]]
}

@test "A namespace without its default deny takes and sends everything, whatever its allows say" {
  local name
  # An allow that does not leave the deny to the namespace's default deny is refused, naming it:
  # one that puts its pods in default deny for a direction itself, or that does not say so.
  local -A modes=(
    [unset]=''
    [ingress-deny]='enableDefaultDeny: {ingress: true, egress: false}'
    [egress-unsaid]='enableDefaultDeny: {ingress: false}'
  )
  for name in "${!modes[@]}"; do
    tree "$name"
    add_policy "$name" "CiliumNetworkPolicy.cilium.io_web_$name.yaml" <<E
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: $name
  namespace: web
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: worker
  ${modes[$name]}
  ingress:
    - fromEndpoints:
        - matchLabels:
            app.kubernetes.io/name: site
      toPorts:
        - ports:
            - port: "9000"
              protocol: TCP
E
    check "$name"
    [ "$status" -eq 1 ] || { echo "$name: $output"; return 1; }
    [[ $output == *"namespace web: CiliumNetworkPolicy/$name"* && $output == *enableDefaultDeny* ]] || { echo "$name: $output"; return 1; }
  done
  # A Kubernetes NetworkPolicy that allows is refused too: Cilium puts every pod a NetworkPolicy
  # selects in default deny.
  tree k8s-allow
  add_policy k8s-allow NetworkPolicy.networking.k8s.io_web_worker.yaml <<'E'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: worker
  namespace: web
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: worker
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: site
      ports:
        - port: 9000
E
  check k8s-allow
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web: NetworkPolicy/worker"* ]]
  # So is a second deny beside the namespace's default deny: with it, taking the default deny out
  # would leave the namespace closed.
  tree second-deny
  add_policy second-deny NetworkPolicy.networking.k8s.io_web_deny-all.yaml <<'E'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: web
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
E
  check second-deny
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web: NetworkPolicy/deny-all is a NetworkPolicy other than the default deny"* ]]
  # A deny rule drops what it names whatever the allows say, and a policy of the nodes polices the
  # hosts; the evaluator reads neither. The check refuses each wherever it is, in a namespace with
  # the default deny, in a listed one and cluster-wide, reason or not, and the evaluator does not
  # answer over a render that holds one.
  tree deny-in
  allow deny-in web '{app.kubernetes.io/name: site}' 'ingressDeny: [{fromEntities: [world], toPorts: [{ports: [{port: "8080", protocol: TCP}]}]}]'
  reason deny-in web 'a reason does not excuse a deny rule'
  check deny-in
  [ "$status" -eq 1 ]
  [[ $output == *"namespace web: CiliumNetworkPolicy/deny-in holds a deny rule"* ]]
  tree deny-out
  allow deny-out legacy '{app.kubernetes.io/name: ledger}' 'egressDeny: [{toEntities: [world]}]'
  check deny-out
  [ "$status" -eq 1 ]
  [[ $output == *"namespace legacy: CiliumNetworkPolicy/deny-out holds a deny rule"* ]]
  tree deny-cluster
  add_policy deny-cluster CiliumClusterwideNetworkPolicy.cilium.io__deny-cluster.yaml <<'E'
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: deny-cluster
  annotations:
    k8s-gitops/network-policy-reason: a reason does not excuse a deny rule
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: envoy
  enableDefaultDeny: {ingress: false, egress: false}
  ingressDeny:
    - fromEntities: [world]
E
  check deny-cluster
  [ "$status" -eq 1 ]
  [[ $output == *"cluster-wide CiliumClusterwideNetworkPolicy/deny-cluster holds a deny rule"* ]]
  run "$REPO/scripts/network-policy-check" --reach "$BATS_TEST_TMPDIR/deny-cluster/render" @world \
    gw:app.kubernetes.io/name=envoy,app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,gateway.envoyproxy.io/owning-gateway-name=public 10443/tcp
  [ "$status" -eq 2 ]
  [[ $output == *"does not read"*"CiliumClusterwideNetworkPolicy/deny-cluster holds a deny rule"* ]]
  tree nodes
  add_policy nodes CiliumClusterwideNetworkPolicy.cilium.io__nodes.yaml <<'E'
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: nodes
spec:
  nodeSelector: {}
  ingress:
    - fromEntities: [cluster]
E
  check nodes
  [ "$status" -eq 1 ]
  [[ $output == *"cluster-wide CiliumClusterwideNetworkPolicy/nodes selects nodes"* ]]

  # The tree: the agents honour the field, and the allows of backstage, demo, envoy-gateway-system,
  # kromgo, open-feature-operator, security-system and sso-system let exactly their flows through
  # with the namespaces' default deny, and every flow without it.
  real_render
  [ "$(yq '.data["enable-non-default-deny-policies"]' "$REAL"/*/cilium/ConfigMap_kube-system_cilium-config.yaml)" = true ]
  local open="$BATS_TEST_TMPDIR/open" removed
  cp -R "$VIEW" "$open"
  removed=("$open"/*/*/NetworkPolicy.networking.k8s.io_demo_default-deny.yaml "$open"/*/*/NetworkPolicy.networking.k8s.io_envoy-gateway-system_default-deny.yaml
    "$open"/*/*/NetworkPolicy.networking.k8s.io_kromgo_default-deny.yaml
    "$open"/*/*/NetworkPolicy.networking.k8s.io_sso-system_default-deny.yaml
    "$open"/*/*/NetworkPolicy.networking.k8s.io_backstage_default-deny.yaml
    "$open"/*/*/NetworkPolicy.networking.k8s.io_security-system_default-deny.yaml
    "$open"/*/*/NetworkPolicy.networking.k8s.io_open-feature-operator_default-deny.yaml)
  [ "${#removed[@]}" -eq 7 ]
  rm -- "${removed[@]}"
  local flow want from to port
  local flows=(
    "allowed @world $PROXY 10443/tcp"
    "denied @world $PROXY 22/tcp"
    "allowed $PROXY demo/Deployment/hello 8080/tcp"
    "denied $PROXY demo/Deployment/hello 22/tcp"
    "denied @world demo/Deployment/hello 8080/tcp"
    "denied demo/Deployment/hello openbao/StatefulSet/openbao 8200/tcp"
    "denied demo/Deployment/hello @world 443/tcp"
    "denied demo/Deployment/volsync-demo demo/Deployment/hello 8080/tcp"
    "allowed $MOVER @world 443/tcp"
    "denied $MOVER @world 80/tcp"
    "allowed $MOVER $DNS 53/udp"
    "denied $MOVER openbao/StatefulSet/openbao 8200/tcp"
    "allowed $PROXY envoy-gateway-system/Deployment/envoy-gateway 18000/tcp"
    "denied $OTHER_APP envoy-gateway-system/Deployment/envoy-gateway 18000/tcp"
    "allowed envoy-gateway-system/Deployment/envoy-gateway @kube-apiserver 6443/tcp"
    "allowed envoy-gateway-system/Deployment/envoy-gateway @world 443/tcp"
    "denied envoy-gateway-system/Deployment/envoy-gateway @world 80/tcp"
    "denied envoy-gateway-system/Job/envoy-gateway-gateway-helm-certgen @world 443/tcp"
    "allowed $PROXY $KROMGO 8080/tcp"
    "denied $PROXY $KROMGO 8081/tcp"
    "allowed $PROMETHEUS $KROMGO 8081/tcp"
    "denied $OTHER_APP $KROMGO 8080/tcp"
    "allowed $KROMGO $DNS 53/udp"
    "denied $KROMGO openbao/StatefulSet/openbao 8200/tcp"
    "denied $KROMGO @world 443/tcp"
    "allowed $PROXY sso-system/Deployment/dex 5556/tcp"
    "allowed $PROXY sso-system/Deployment/oauth2-proxy 4180/tcp"
    "denied @world sso-system/Deployment/dex 5556/tcp"
    "allowed sso-system/Deployment/oauth2-proxy sso-system/Deployment/dex 5556/tcp"
    "denied sso-system/Deployment/oauth2-proxy sso-system/Deployment/dex 5558/tcp"
    "denied sso-system/Deployment/dex sso-system/Deployment/oauth2-proxy 4180/tcp"
    "allowed sso-system/Deployment/dex @kube-apiserver 6443/tcp"
    "denied sso-system/Deployment/oauth2-proxy @kube-apiserver 6443/tcp"
    "allowed sso-system/Deployment/dex @world 443/tcp"
    "denied sso-system/Deployment/dex @world 80/tcp"
    "denied sso-system/Deployment/oauth2-proxy @world 443/tcp"
    "allowed sso-system/Deployment/dex $DNS 53/udp"
    "allowed sso-system/Deployment/oauth2-proxy $DNS 53/udp"
    "denied sso-system/Deployment/dex openbao/StatefulSet/openbao 8200/tcp"
    "denied sso-system/Deployment/oauth2-proxy openbao/StatefulSet/openbao 8200/tcp"
    "denied sso-system/Deployment/oauth2-proxy demo/Deployment/hello 8080/tcp"
    "denied demo/Deployment/hello sso-system/Deployment/oauth2-proxy 4180/tcp"
    "denied $OTHER_APP sso-system/Deployment/dex 5556/tcp"
    "allowed $PROXY $BACKSTAGE 7007/tcp"
    "denied $PROXY $BACKSTAGE_DB 5432/tcp"
    "allowed $BACKSTAGE $BACKSTAGE_DB 5432/tcp"
    "denied $BACKSTAGE @world 443/tcp"
    "denied $OTHER_APP $BACKSTAGE_DB 5432/tcp"
    "allowed $BACKSTAGE_DB @world 443/tcp"
    "denied $BACKSTAGE_DB @world 80/tcp"
    "denied $BACKSTAGE_DB_JOIN @world 443/tcp"
    "allowed $PGDUMP @world 443/tcp"
    "denied $PGDUMP @world 80/tcp"
    "allowed $PROMETHEUS $FALCO 8765/tcp"
    "denied $OTHER_APP $FALCO 8765/tcp"
    "allowed $FALCO $DNS 53/udp"
    "denied $FALCO @kube-apiserver 6443/tcp"
    "denied $FALCO @world 443/tcp"
    "allowed @kube-apiserver $OPEN_FEATURE 9443/tcp"
    "denied @world $OPEN_FEATURE 9443/tcp"
    "allowed $PROMETHEUS $OPEN_FEATURE 8080/tcp"
    "denied $OTHER_APP $OPEN_FEATURE 8080/tcp"
    "allowed $OPEN_FEATURE @kube-apiserver 6443/tcp"
    "denied $OPEN_FEATURE @world 443/tcp"
  )
  for flow in "${flows[@]}"; do
    read -r want from to port <<<"$flow"
    "$want" "$VIEW" "$from" "$to" "$port"
    allowed "$open" "$from" "$to" "$port"
  done
}

@test "The proxies fetch the firewall's module from the controller, and the controller alone reaches the registry, on 443" {
  real_render
  local controller=envoy-gateway-system/Deployment/envoy-gateway certgen=envoy-gateway-system/Job/envoy-gateway-gateway-helm-certgen
  local service deployment policy
  # The controller serves the modules it cached on 18002, the port its chart's Service names wasm,
  # from the emptyDir the chart mounts where the controller keeps them (docs/kubernetes.md, Web
  # application firewall).
  service=("$REAL"/*/envoy-gateway/Service_envoy-gateway-system_envoy-gateway.yaml)
  deployment=("$REAL"/*/envoy-gateway/Deployment.apps_envoy-gateway-system_envoy-gateway.yaml)
  [ "${#service[@]}" -eq 1 ] && [ -f "${service[0]}" ] && [ "${#deployment[@]}" -eq 1 ] && [ -f "${deployment[0]}" ]
  [ "$(yq -o json -I0 '.spec.ports[] | select(.name == "wasm") | [.port, .targetPort]' "${service[0]}")" = '[18002,18002]' ]
  [ "$(yq '.spec.template.spec.containers[] | select(.name == "envoy-gateway") | .volumeMounts[] | select(.mountPath == "/var/lib/eg/wasm") | .name' "${deployment[0]}")" = wasm-cache ]
  [ "$(yq '.spec.template.spec.volumes[] | select(.name == "wasm-cache") | .emptyDir | tag' "${deployment[0]}")" = '!!map' ]
  # The proxies reach it there; nothing else does, from inside the cluster or outside it.
  allowed "$VIEW" "$PROXY" "$controller" 18002/tcp
  allowed_in "$VIEW" "$PROXY" "$controller" 18002/tcp
  denied "$VIEW" "$OTHER_APP" "$controller" 18002/tcp
  denied "$VIEW" demo/Deployment/hello "$controller" 18002/tcp
  denied "$VIEW" @world "$controller" 18002/tcp
  denied "$VIEW" @remote-node "$controller" 18002/tcp
  denied "$VIEW" @host "$controller" 18002/tcp
  denied "$VIEW" "$PROXY" "$controller" 18001/tcp
  # The controller reaches the registry, the world on 443 and on no other port; the certificate job
  # and the proxies, which fetch no image, do not.
  allowed "$VIEW" "$controller" @world 443/tcp
  denied "$VIEW" "$controller" @world 80/tcp
  denied "$VIEW" "$controller" @world 5000/tcp
  denied "$VIEW" "$certgen" @world 443/tcp
  denied "$VIEW" "$PROXY" @world 443/tcp
  denied "$VIEW" "$PROXY" @world 80/tcp
  # By a policy of its own that says why, whose one rule is that flow: the registry answers a blob
  # request with a redirect to another host, which no name rule covers without Cilium's DNS proxy.
  policy=("$VIEW"/*/envoy-gateway/CiliumNetworkPolicy.cilium.io_envoy-gateway-system_envoy-gateway-registry.yaml)
  [ -f "${policy[0]}" ] || { echo "there is no policy envoy-gateway-registry"; return 1; }
  [ -n "$(yq '.metadata.annotations["k8s-gitops/network-policy-reason"] // ""' "${policy[0]}")" ]
  [ "$(yq -o json -I0 '.spec.endpointSelector' "${policy[0]}")" = '{"matchLabels":{"control-plane":"envoy-gateway"}}' ]
  [ "$(yq -o json -I0 '.spec | del(.endpointSelector, .enableDefaultDeny)' "${policy[0]}" | jq -cS .)" \
    = '{"egress":[{"toEntities":["world"],"toPorts":[{"ports":[{"port":"443","protocol":"TCP"}]}]}]}' ]
  # No other policy of the namespace lets anything of it out to the world.
  [ "$(yq -N 'select(.kind == "CiliumNetworkPolicy") | select([.spec.egress[]?.toEntities[]?] | any_c(. == "world")) | .metadata.name' "$VIEW"/*/*/CiliumNetworkPolicy.cilium.io_envoy-gateway-system_*.yaml)" = envoy-gateway-registry ]
}

@test "The cluster audits or enforces the policies as the docs say" {
  real_render
  local values="$REPO/kubernetes/apps/base/kube-system/cilium/app/values.yaml" said mode
  local config=("$REAL"/*/cilium/ConfigMap_kube-system_cilium-config.yaml) agents=("$REAL"/*/cilium/DaemonSet.apps_kube-system_cilium.yaml)
  [ "${#config[@]}" -eq 1 ] && [ "${#agents[@]}" -eq 1 ]
  # The docs state the mode once, at the start of a paragraph: the cluster audits network policy, or
  # enforces the policies.
  local statement='^\*\*The cluster (audits network policy|enforces the policies)\.\*\*'
  said=$(grep -cE "$statement" "$REPO/docs/kubernetes.md" || true)
  [ "$said" -eq 1 ] || { echo "docs/kubernetes.md states the mode $said times: once, as **The cluster audits network policy.** or **The cluster enforces the policies.**"; return 1; }
  mode=$(grep -oE "$statement" "$REPO/docs/kubernetes.md")
  # The values the chart and scripts/install-cilium read set it, and the agents' configuration
  # carries it. The policies land on a cluster that already audits, and the value goes only with
  # the paragraph that says the cluster enforces them (docs/kubernetes.md, Turning it on, and back).
  if [[ $mode == *audits* ]]; then
    [ "$(yq '.policyAuditMode' "$values")" = true ] \
      || { echo "docs/kubernetes.md says the cluster audits network policy, but the Cilium values do not set policyAuditMode: true, so every agent enforces the policies of the tree: say **The cluster enforces the policies.** instead, once the policies have been watched in audit mode"; return 1; }
    [ "$(yq '.data["policy-audit-mode"]' "${config[0]}")" = true ]
  else
    [ "$(yq '.policyAuditMode // false' "$values")" = false ] \
      || { echo "the Cilium values set policyAuditMode: true, so every agent audits and drops nothing: docs/kubernetes.md says **The cluster audits network policy.**"; return 1; }
    [ "$(yq '.data["policy-audit-mode"] // "false"' "${config[0]}")" = false ]
  fi
  # A change of the configuration rolls the agents, so each runs the mode it says.
  [ -n "$(yq '.spec.template.metadata.annotations["cilium.io/cilium-configmap-checksum"] // ""' "${agents[0]}")" ]
}
