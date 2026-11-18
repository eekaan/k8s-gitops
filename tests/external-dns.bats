#!/usr/bin/env bats
# Proves features/dns.feature, except the scenario about just gateway-check, which
# tests/gateway-check.bats proves; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq and jq on PATH (the versions pinned for the repository). The chart
# is pulled once per run from its public registry; building and rendering are offline, with the
# placeholders of the cluster's example key lists. The cluster-config scenarios run the copy of the
# scripts against a fake of tofu that answers the edge stack's outputs, so nothing reaches a cloud.

# flux build rewrites the kustomization.yaml of the application it builds in this checkout and puts
# it back afterwards, so two builds at once could leave the rewritten file behind; the chart's
# directory is found whole only when no other test is pulling it.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

load fixtures/edge-stack
# tree_without, a copy of the tree whose overlay leaves applications out.
load fixtures/tree-without

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
  # The cluster the overlay under test is for, which names its records' owner.
  CLUSTER_NAME=lab-sto2
  GATEWAY_NAMESPACE=envoy-gateway-system
  GATEWAY_NAME=public
  APP='external-dns'
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

# overlay: the lab-sto2 overlay as Flux reads it, its namespaces and the Kustomization of each
# enabled application. Writes $OVERLAY.
overlay() {
  OVERLAY="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "$REPO/kubernetes/apps/overlays/lab-sto2" >"$OVERLAY"
}

# build_from_overlay APP: the objects the overlay's Kustomization of APP applies, built offline with
# the example key lists, or those of the file VARS names, and the Kustomization's own substitutions,
# strictly.
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
# and sets BUILT and APP_DIR.
built() {
  app_dir "$1"
  overlay
  BUILT="$BATS_TEST_TMPDIR/$1-built.yaml"
  build_from_overlay "$1" >"$BUILT"
}

# everything: the overlay's build and every application it enables, each built as Flux applies it,
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

# var NAME: the value of the cluster-config variable NAME in the key lists built with.
var() {
  NAME="$1" yq -e '.[strenv(NAME)]' "${VARS:-$EXAMPLE}"
}

# other_vars: a copy of the example values with the domain, its zone and both edge addresses
# changed, in OTHER, so a test can build again and see that what it read came from the variables,
# not from a literal that happens to equal the example. The example's domain is its own zone; this
# one is a name two labels under its zone.
other_vars() {
  OTHER="$BATS_TEST_TMPDIR/other-vars.yaml"
  DOMAIN=lab.other.example.org ZONE=example.org EDGE_1=203.0.113.201 EDGE_2=203.0.113.202 \
    yq '.CLUSTER_DOMAIN = strenv(DOMAIN) | .CLUSTER_DNS_ZONE = strenv(ZONE)
      | .EDGE_PUBLIC_ADDRESS_1 = strenv(EDGE_1) | .EDGE_PUBLIC_ADDRESS_2 = strenv(EDGE_2)' \
    "$EXAMPLE" >"$OTHER"
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

# render: renders the chart that the application's HelmRelease installs, built as built() builds it,
# from the URL and tag of its OCIRepository, with the values helm-controller gives the chart: those
# of the ConfigMap the HelmRelease reads, then the HelmRelease's own, which Flux has substituted,
# over them. Writes $BATS_TEST_TMPDIR/rendered.yaml and sets RENDERED and ARGS, the arguments of
# external-dns' container, one per line.
render() {
  local url tag name release namespace pulled values inline
  built "$APP"
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace // "'"$APP"'"' "$BUILT")"
  values="$BATS_TEST_TMPDIR/values.yaml"
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\") | .data[\"values.yaml\"]" "$BUILT" >"$values"
  [ -s "$values" ] || { echo "no values in the ConfigMap $name the HelmRelease reads"; return 1; }
  inline="$BATS_TEST_TMPDIR/inline.yaml"
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$BUILT" >"$inline"
  pulled="$BATS_FILE_TMPDIR/charts/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  RENDERED="$BATS_TEST_TMPDIR/rendered.yaml"
  helm template "$release" "$(echo "$pulled"/*.tgz)" --namespace "$namespace" --kube-version "$KUBE" --include-crds \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor \
    --values "$values" --values "$inline" >"$RENDERED" || return
  ARGS="$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "external-dns") | .args[]' "$RENDERED")"
}

# arg PREFIX: the arguments that start with PREFIX, one per line.
arg() {
  grep -F -- "$1" <<<"$ARGS" || true
}

@test "A route on the public Gateway is published at both edge routers' public addresses" {
  local gateway key keys holders
  key='external-dns.kubernetes.io/target'
  built gateway-public
  gateway="$(only "$BUILT" Gateway)"
  [ "$gateway" = "$GATEWAY_NAME" ]
  # The Gateway's own address is private, which the edge routers translate to; without the
  # annotation external-dns would publish it, from the Gateway's status. The annotation names the
  # edges' two public addresses, from the variables.
  echo "the Gateway's annotations: $(object "$BUILT" Gateway "$gateway" | yq -o json -I0 '.metadata.annotations')"
  [ "$(object "$BUILT" Gateway "$gateway" | KEY="$key" yq '.metadata.annotations[strenv(KEY)]')" \
    = "$(var EDGE_PUBLIC_ADDRESS_1),$(var EDGE_PUBLIC_ADDRESS_2)" ]
  other_vars
  VARS="$OTHER" built gateway-public
  [ "$(object "$BUILT" Gateway "$gateway" | KEY="$key" yq '.metadata.annotations[strenv(KEY)]')" \
    = "$(VARS="$OTHER" var EDGE_PUBLIC_ADDRESS_1),$(VARS="$OTHER" var EDGE_PUBLIC_ADDRESS_2)" ]
  # Nothing else sets a target, under either prefix the pinned version reads, and neither address
  # is named anywhere else: of everything the cluster applies, built with addresses of their own,
  # only the Gateway's annotation holds them.
  VARS="$OTHER" everything
  # shellcheck disable=SC2016 # $one, $two, $o, $p, $v and $key are jq variables.
  holders="$(yq -N -o json -I0 '.' "$EVERYTHING" | jq -rs --arg one "$(VARS="$OTHER" var EDGE_PUBLIC_ADDRESS_1)" \
    --arg two "$(VARS="$OTHER" var EDGE_PUBLIC_ADDRESS_2)" '
    .[] | objects | . as $o | paths as $p | ($o | getpath($p)) as $v | ($p[-1] | tostring) as $key
    | select(($key | test("^external-dns\\.(alpha\\.)?kubernetes\\.io/target$"))
        or (($v | type) == "string" and (($v | contains($one)) or ($v | contains($two)))))
    | "\($o.kind)/\($o.metadata.name): \($p | map(tostring) | join("."))"' | sort -u)"
  echo "what sets a target or names an edge: $holders"
  [ "$holders" = "Gateway/$gateway: metadata.annotations.$key" ]

  # What external-dns reads and writes, from the chart rendered with the repository's values.
  render
  echo "external-dns' arguments: $(paste -sd' ' - <<<"$ARGS")"
  # Routes only, and of the public Gateway only.
  [ "$(arg --source=)" = "--source=gateway-httproute" ]
  [ "$(arg --gateway-namespace=)" = "--gateway-namespace=$GATEWAY_NAMESPACE" ]
  [ "$(arg --gateway-name=)" = "--gateway-name=$GATEWAY_NAME" ]
  [ -z "$(arg --default-targets)" ]
  # A records only, the provider's proxy off, and a TTL stated.
  [ "$(arg --managed-record-types=)" = "--managed-record-types=A" ]
  [ -z "$(arg cloudflare-proxied)" ]
  [ "$(arg --min-ttl=)" = "--min-ttl=300s" ]
  [ "$(arg --provider=)" = "--provider=cloudflare" ]
  # Its permissions are read access to what the source follows, cluster-wide as the routes are in
  # every namespace that opts in, and nothing wider: no write, no Secret, no Service, no Ingress.
  [ "$(yq -N 'select(.kind == "ClusterRole") | .metadata.name' "$RENDERED" | wc -l)" -eq 1 ]
  [ -z "$(yq -N 'select(.kind == "Role")' "$RENDERED")" ]
  keys="$(yq -N -o json -I0 'select(.kind == "ClusterRole") | .rules' "$RENDERED" |
    jq -c 'map({g: (.apiGroups | join(",")), r: (.resources | join(",")), v: (.verbs | sort | join(","))}) | sort_by(.r)')"
  echo "its ClusterRole: $keys"
  [ "$keys" = '[{"g":"gateway.networking.k8s.io","r":"gateways","v":"get,list,watch"},{"g":"gateway.networking.k8s.io","r":"httproutes","v":"get,list,watch"},{"g":"","r":"namespaces","v":"get,list,watch"}]' ]
  # The listener's wildcard is published only for a route that names no host of its own, which the
  # source gives the listener's hostname: every route on the Gateway names concrete hostnames, so
  # a record is made for those and never for the wildcard.
  everything
  # shellcheck disable=SC2016 # $gateway is a jq variable.
  holders="$(yq -N -o json -I0 '.' "$EVERYTHING" | jq -rs --arg gateway "$gateway" '
    [.[] | objects | select(.kind == "HTTPRoute")
      | select(any(.spec.parentRefs[]?; .name == $gateway and (.sectionName // "") != "http"))
      | select((.spec.hostnames // []) | (length == 0 or any(.[]; startswith("*"))))
      | .metadata.namespace + "/" + .metadata.name] | join(" ")')"
  echo "routes on the https listener that name no host or a wildcard: ${holders:-none}"
  [ -z "$holders" ]
  [ "$(yq -N 'select(.kind == "HTTPRoute" and .metadata.name == "hello") | .spec.hostnames[0]' "$EVERYTHING")" = "hello.$(var CLUSTER_DOMAIN)" ]
  # The http listener has no hostname, so a host a route on it named would be published as it is:
  # the routes on it name none.
  # shellcheck disable=SC2016 # $gateway is a jq variable.
  holders="$(yq -N -o json -I0 '.' "$EVERYTHING" | jq -rs --arg gateway "$gateway" '
    [.[] | objects | select(.kind == "HTTPRoute")
      | select(any(.spec.parentRefs[]?; .name == $gateway and .sectionName == "http"))
      | select((.spec.hostnames // []) | length > 0)
      | .metadata.namespace + "/" + .metadata.name] | join(" ")')"
  echo "routes on the http listener that name a host: ${holders:-none}"
  [ -z "$holders" ]
  # No route carries an annotation of external-dns, under either prefix the pinned version reads,
  # which could give it more hostnames, a wildcard, a target, a TTL of its own or the provider's
  # proxy, so the arguments above are all that decide a route's records.
  holders="$(yq -N -o json -I0 '.' "$EVERYTHING" | jq -rs '
    [.[] | objects | select(.kind == "HTTPRoute")
      | select((.metadata.annotations // {}) | keys | any(test("^external-dns\\.(alpha\\.)?kubernetes\\.io/")))
      | .metadata.namespace + "/" + .metadata.name] | join(" ")')"
  echo "routes with an annotation of external-dns: ${holders:-none}"
  [ -z "$holders" ]
  # It runs after the Gateway, the secret store and the monitoring definitions it needs.
  [ "$(depends_on "$APP" | sort | paste -sd' ' -)" = "gateway-public openbao-store prometheus-operator-crds" ]
}

@test "The edges' public addresses come from the cluster's configuration and are nowhere in the tree" {
  local talman encoded config printed address
  # The example lists both keys, with addresses from the documentation ranges.
  for address in EDGE_PUBLIC_ADDRESS_1 EDGE_PUBLIC_ADDRESS_2; do
    [[ $(var "$address") =~ ^(192\.0\.2|198\.51\.100|203\.0\.113)\.[0-9]+$ ]]
  done
  [ "$(var EDGE_PUBLIC_ADDRESS_1)" != "$(var EDGE_PUBLIC_ADDRESS_2)" ]
  # The cluster stack's talman.yaml as the fixture renders it, and a copy of the scripts with the
  # edge stack's configuration, where tofu is a fake that answers the edge stack's outputs, which
  # are sensitive.
  encoded=$(tofu -chdir="$REPO/tests/fixtures/talos" console -no-color <<<'base64encode(local.talman_yaml)')
  talman="$BATS_TEST_TMPDIR/talman.yaml"
  base64 -d <<<"${encoded//\"/}" >"$talman"
  edge_copy
  config="$BATS_TEST_TMPDIR/cluster-config.json"
  printed="$BATS_TEST_TMPDIR/printed.txt"
  # shellcheck disable=SC2016 # $1 and $2 are the inner shell's.
  env -i PATH="$BIN:$PATH" HOME="$BATS_TEST_TMPDIR" "${EDGE_ENVIRONMENT[@]}" bash -c \
    '. "$1/scripts/lib/cluster.sh" && fill_cluster_config lab-sto2 "$2" && cluster_config_manifest' _ "$COPY" "$talman" \
    2>"$printed" | jq '.data' >"$config"
  # In the order the stack's outputs give them, and not the BGP addresses on the node network.
  [ "$(jq -r '.EDGE_PUBLIC_ADDRESS_1' "$config")" = 203.0.113.51 ]
  [ "$(jq -r '.EDGE_PUBLIC_ADDRESS_2' "$config")" = 203.0.113.52 ]
  [ "$(jq -r '.BGP_EDGE_ADDRESS_1' "$config")" != 203.0.113.51 ]
  [ "$(jq -r 'keys | join(" ")' "$config")" = "$(yq 'keys | sort | join(" ")' "$CLUSTER/cluster-config.example.yaml")" ]
  # Never printed: nothing reaches the error output, where the recipes say what they do.
  [ ! -s "$printed" ] || ! grep -qE '[0-9]{1,3}(\.[0-9]{1,3}){3}' "$printed"
  # Nowhere in the tree: the tree's check of address literals passes with the new files in it, and
  # a build with other values follows them (the Gateway's annotation, proved in the scenario about
  # the records' targets, is the one place they are named).
  run "$REPO/scripts/check-address-literals"
  echo "$output"
  [ "$status" -eq 0 ]
  other_vars
  VARS="$OTHER" built gateway-public
  [ "$(object "$BUILT" Gateway "$GATEWAY_NAME" | yq '.metadata.annotations["external-dns.kubernetes.io/target"]')" = "203.0.113.201,203.0.113.202" ]
}

# admits FILTER NAME...: every NAME matches FILTER, a regular expression of Go's syntax, which
# external-dns compiles, as yq, also written in Go, does; fails naming the first that does not.
admits() {
  local filter=$1 name
  shift
  for name in "$@"; do
    [ "$(N="$name" F="$filter" yq -n 'strenv(N) | test(strenv(F))')" = true ] || { echo "the filter refuses $name"; return 1; }
  done
}

# refuses FILTER NAME...: no NAME matches FILTER; fails naming the first that does.
refuses() {
  local filter=$1 name
  shift
  for name in "$@"; do
    [ "$(N="$name" F="$filter" yq -n 'strenv(N) | test(strenv(F))')" = false ] || { echo "the filter admits $name"; return 1; }
  done
}

# filled NAME=VALUE...: fill_cluster_config for lab-sto2 run from the copy edge_copy makes, with the
# fixture's talman.yaml, the edge stack's outputs and NAME=VALUE... in its environment, as run runs
# it; the ConfigMap's data goes to $FILLED as JSON, and the errors to output.
filled() {
  local encoded talman="$BATS_TEST_TMPDIR/talman.yaml"
  FILLED="$BATS_TEST_TMPDIR/filled.json"
  if [ ! -f "$talman" ]; then
    encoded=$(tofu -chdir="$REPO/tests/fixtures/talos" console -no-color <<<'base64encode(local.talman_yaml)')
    base64 -d <<<"${encoded//\"/}" >"$talman"
  fi
  [ -n "${COPY-}" ] || edge_copy
  rm -f "$FILLED"
  # shellcheck disable=SC2016 # $1, $2 and $3 are the inner shell's.
  run env -i PATH="$BIN:$PATH" HOME="$BATS_TEST_TMPDIR" "${EDGE_ENVIRONMENT[@]}" "$@" bash -c \
    '. "$1/scripts/lib/cluster.sh" && fill_cluster_config lab-sto2 "$2" && cluster_config_manifest | jq -c .data >"$3"' \
    _ "$COPY" "$talman" "$FILLED"
}

@test "Only names under the cluster's domain are ever touched, and only records this cluster owns" {
  local owner filter zone
  # Names: one filter, a regular expression, which external-dns matches the provider's zones and
  # every record's name against, and which takes the place of a domain filter wholly; nothing else
  # selects or leaves out a name or a zone.
  render
  echo "external-dns' arguments: $(paste -sd' ' - <<<"$ARGS")"
  [ "$(arg --regex-domain-filter= | wc -l)" -eq 1 ]
  [ -z "$(arg --domain-filter)" ]
  [ -z "$(arg --exclude-domains)" ]
  [ -z "$(arg --regex-domain-exclusion)" ]
  [ -z "$(arg --zone-id-filter)" ]
  # A domain that is its own zone, as the example's: the domain and the names under it, and no name
  # that merely ends like it or holds it.
  filter="$(arg --regex-domain-filter= | sed 's/^--regex-domain-filter=//')"
  echo "filter: $filter"
  [ "$(var CLUSTER_DNS_ZONE)" = "$(var CLUSTER_DOMAIN)" ]
  [ "$filter" = '\A(example\.com|(.+\.)?example\.com)\z' ]
  admits "$filter" example.com hello.example.com a.b.example.com
  refuses "$filter" '' example.org hello.example.org xexample.com example-com hello.example-com \
    example.com.example.net hello.example.com.example.net

  # Records: a TXT registry, whose owner id is the cluster's own name, which the overlay knows, and
  # not the default two clusters of one zone would share, and a prefix that keeps its records from
  # the ones made by hand. A record without a registry entry of this owner is never changed or
  # deleted, so a record made by hand is never taken over.
  [ "$(arg --registry=)" = "--registry=txt" ]
  owner="$(arg --txt-owner-id= | sed 's/^--txt-owner-id=//')"
  echo "owner id: $owner"
  [ "$owner" = "$CLUSTER_NAME" ]
  [ "$owner" != default ]
  [ -n "$(arg --txt-prefix=)" ]
  # A removed route removes its records: sync, which deletes only what the registry says this owner
  # made. Removing the application itself deletes nothing, as it stops with its records in place.
  [ "$(arg --policy=)" = "--policy=sync" ]
  [ -z "$(yq -N 'select(.kind == "Job" or .kind == "CronJob")' "$RENDERED")" ]
  # A new route's record follows within a minute or two, without hammering the provider: a sync
  # every minute and one on a route's change, at most every 30 seconds.
  [ "$(arg --interval=)" = "--interval=1m" ]
  [ "$(arg --events)" = "--events" ]
  [ "$(arg --min-event-sync-interval=)" = "--min-event-sync-interval=30s" ]
  # Its metrics are scraped.
  [ "$(yq -N 'select(.kind == "ServiceMonitor") | .metadata.name' "$RENDERED" | wc -l)" -eq 1 ]

  # A domain under its zone: the zone's own name, which selects the zone, and the domain and the
  # names under it, each dot a dot. Not the zone's other names, the domain's siblings or parent, or
  # a name whose dots are other characters.
  other_vars
  [ "$(VARS="$OTHER" var CLUSTER_DOMAIN) $(VARS="$OTHER" var CLUSTER_DNS_ZONE)" = "lab.other.example.org example.org" ]
  VARS="$OTHER" render
  filter="$(arg --regex-domain-filter= | sed 's/^--regex-domain-filter=//')"
  echo "filter: $filter"
  [ "$filter" = '\A(example\.org|(.+\.)?lab\.other\.example\.org)\z' ]
  admits "$filter" example.org lab.other.example.org hello.lab.other.example.org a.b.lab.other.example.org
  refuses "$filter" '' other.example.org www.example.org x.other.example.org lab-other.example.org \
    labxother.example.org hello.lab-other.example.org hellolab.other.example.org xexample.org example-org \
    example.org.example.net hello.lab.other.example.org.example.net example.com
  # Without the zone in the cluster's configuration the chart refuses to render, naming the key,
  # rather than run with a filter that selects no zone.
  yq -i '.CLUSTER_DNS_ZONE = ""' "$OTHER"
  VARS="$OTHER" run render
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"cluster-config holds no CLUSTER_DNS_ZONE"* ]]

  # cluster-config fills the zone from CLUSTER_DNS_ZONE, and from the domain when that is unset or
  # empty, and refuses a zone the domain is not under, printing neither.
  filled
  [ "$status" -eq 0 ]
  [ "$(jq -r '.CLUSTER_DNS_ZONE + " " + .CLUSTER_DOMAIN' "$FILLED")" = "example.com example.com" ]
  filled CLUSTER_DNS_ZONE=
  [ "$status" -eq 0 ]
  [ "$(jq -r '.CLUSTER_DNS_ZONE' "$FILLED")" = example.com ]
  filled CLUSTER_DOMAIN=lab.example.com CLUSTER_DNS_ZONE=example.com
  [ "$status" -eq 0 ]
  [ "$(jq -r '.CLUSTER_DNS_ZONE + " " + .CLUSTER_DOMAIN' "$FILLED")" = "example.com lab.example.com" ]
  for zone in example.org ample.com xlab.example.com hello.lab.example.com Example.com com -x.example.com; do
    filled CLUSTER_DOMAIN=lab.example.com CLUSTER_DNS_ZONE="$zone"
    echo "$zone: $output"
    [ "$status" -ne 0 ]
    [[ $output == *CLUSTER_DNS_ZONE* ]]
    [[ $zone != *.* || $output != *"$zone"* ]]
    [ ! -s "$FILLED" ]
  done
}

@test "The DNS provider's token reaches external-dns from the secret store and is nowhere in the tree" {
  local external secret file readers
  built "$APP"
  external="$(only "$BUILT" ExternalSecret)"
  # From the one store, the key api-token of cert-manager/cloudflare, into a Secret of this
  # application's own namespace.
  overlay
  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "'"$APP"'") | .metadata.name' "$OVERLAY")" = "$APP" ]
  [ "$(object "$BUILT" ExternalSecret "$external" | yq '.spec.secretStoreRef.kind + "/" + .spec.secretStoreRef.name')" = ClusterSecretStore/openbao ]
  [ "$(object "$BUILT" ExternalSecret "$external" | yq '.spec.data | length')" -eq 1 ]
  [ "$(object "$BUILT" ExternalSecret "$external" | yq '.spec.data[0].remoteRef.key + " " + .spec.data[0].remoteRef.property')" = "cert-manager/cloudflare api-token" ]
  [ -z "$(object "$BUILT" ExternalSecret "$external" | yq '.spec.dataFrom // ""')" ]
  secret="$(object "$BUILT" ExternalSecret "$external" | yq '.spec.target.name')"
  # The pod reads it by reference, as CF_API_TOKEN, and sets no other variable.
  render
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "external-dns") | .env | length' "$RENDERED")" -eq 1 ]
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "external-dns") | .env[0].name' "$RENDERED")" = CF_API_TOKEN ]
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "external-dns") | .env[0].valueFrom.secretKeyRef.name' "$RENDERED")" = "$secret" ]
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "external-dns") | .env[0].valueFrom.secretKeyRef.key' "$RENDERED")" \
    = "$(object "$BUILT" ExternalSecret "$external" | yq '.spec.data[0].secretKey')" ]
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "external-dns") | .env[0] | has("value")' "$RENDERED")" = false ]
  # No Secret, no key file and no value of the chart's own for a credential, in the build or in the
  # render, and no file of the application holds a token.
  [ -z "$(yq -N 'select(.kind == "Secret")' "$BUILT" "$RENDERED")" ]
  [ "$(yq '.secretConfiguration.enabled // false' "$BATS_TEST_TMPDIR/values.yaml")" = false ]
  [ -z "$(arg --cloudflare-api)" ]
  for file in "$REPO/$APP_DIR"/app/*.yaml; do
    ! grep -qiE 'CF_API_(TOKEN|KEY)[^a-z]*:[[:space:]]*"?[A-Za-z0-9_-]{20,}|apiToken|(^|[^a-z-])token:[[:space:]]*[A-Za-z0-9_-]{20,}' "$file" || { echo "a token in $file"; return 1; }
  done
  # The store entry reaches a Secret in this namespace and, through the ACME issuers' ExternalSecret,
  # in cert-manager's, and in no other: of everything the overlay applies, those two ExternalSecrets
  # read it, and none finds keys by a pattern that could.
  everything
  readers="$(yq -N -o json -I0 '.' "$EVERYTHING" | jq -rs '
    [.[] | objects | select(.kind == "ExternalSecret")
      | select(any(.spec.data[]?; .remoteRef.key == "cert-manager/cloudflare")
          or any(.spec.dataFrom[]?; .extract.key == "cert-manager/cloudflare" or .find != null))
      | .metadata.namespace + "/" + .metadata.name] | sort | join(" ")')"
  echo "what reads the token: $readers"
  [ "$readers" = "cert-manager/cloudflare-api-token $APP/$external" ]
}

# edge_copy: sets COPY to a copy of the scripts with the edge stack's files and the backend file,
# BIN to the directory of the fakes, and EDGE_ENVIRONMENT, what scripts/stack-env needs. tofu is a
# fake that answers the edge stack's outputs, which STATE/no-edge-outputs empties.
edge_copy() {
  COPY="$BATS_TEST_TMPDIR/copy"
  BIN="$BATS_TEST_TMPDIR/bin"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$COPY/kubernetes/clusters/lab-sto2"
  cp -R "$REPO/scripts" "$COPY/scripts"
  cp "$CLUSTER/cluster-config.example.yaml" "$COPY/kubernetes/clusters/lab-sto2/"
  edge_stack_fixture "$COPY" "$BIN" "$STATE"
  EDGE_ENVIRONMENT=("${EDGE_STACK_ENVIRONMENT[@]}" CLUSTER_DOMAIN=example.com BACKUP_BUCKET_PREFIX=marker-backups
    TMPDIR="$BATS_TEST_TMPDIR")
}

@test "A cluster that selects DNS records without the Gateway or the edges' addresses is refused" {
  local talman encoded refused
  # The tree as it is passes, with the application, the Gateway and the demo's route listed.
  [ "$(yq '.resources[] | select(test("/'"$APP"'/ks.yaml$"))' "$REPO/kubernetes/apps/overlays/lab-sto2/kustomization.yaml" | wc -l)" -eq 1 ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # Without the Gateway, the applications whose routes name it and CrowdSec, whose agent reads its
  # proxies, nothing but external-dns needs the Gateway, so it is the one refused, naming it.
  tree_without gateway-public hello-route n8n kromgo open-webui hello-sso dex oauth2-proxy backstage crowdsec crowdsec-gateway-logs victoria-logs-route
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  refused="kubernetes-check: kubernetes/apps/base/external-dns/external-dns/ks.yaml: Kustomization $APP"
  refused+=" names gateway-public in dependsOn, but kubernetes/apps/overlays/lab-sto2 does not enable"
  refused+=" gateway-public, nor does kubernetes/clusters/lab-sto2 build it, so $APP would never"
  refused+=" reconcile; list the ks.yaml of gateway-public in kubernetes/apps/overlays/lab-sto2/kustomization.yaml,"
  refused+=" or drop the dependency"
  [ "$(grep -v '^built ' <<<"$output")" = "$refused"$'\n'"kubernetes-check: 1 failure(s)" ]
  # With the Gateway but without an edge address in the cluster's key lists, the annotation names a
  # variable nothing sets.
  tree_without
  yq -i 'del(.EDGE_PUBLIC_ADDRESS_2)' "$TREE/kubernetes/clusters/lab-sto2/cluster-config.example.yaml"
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"variable EDGE_PUBLIC_ADDRESS_2 is not set"* ]]
  # And cluster-config, which fills the keys, refuses a cluster whose edge stack has no outputs,
  # naming the keys and the stack, and prints no address.
  encoded=$(tofu -chdir="$REPO/tests/fixtures/talos" console -no-color <<<'base64encode(local.talman_yaml)')
  talman="$BATS_TEST_TMPDIR/talman.yaml"
  base64 -d <<<"${encoded//\"/}" >"$talman"
  edge_copy
  : >"$STATE/no-edge-outputs"
  # shellcheck disable=SC2016 # $1 and $2 are the inner shell's.
  run env -i PATH="$BIN:$PATH" HOME="$BATS_TEST_TMPDIR" "${EDGE_ENVIRONMENT[@]}" bash -c \
    '. "$1/scripts/lib/cluster.sh" && fill_cluster_config lab-sto2 "$2"' _ "$COPY" "$talman"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *EDGE_PUBLIC_ADDRESS_1* && $output == *EDGE_PUBLIC_ADDRESS_2* && $output == *sto2/edge* ]]
  [ "$(grep -cE '203\.0\.113\.[0-9]+' <<<"$output")" -eq 0 ]
}
