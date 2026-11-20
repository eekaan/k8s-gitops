#!/usr/bin/env bats
# Proves features/probes.feature; each scenario's test carries its title, and the lower-case tests
# check what the exporter's chart makes of the values. The alerts on the probes are proved by
# promtool, through just rules-check (tests/rules/blackbox-exporter.yaml).
# Needs kustomize, flux, helm, yq, jq and sha256sum on PATH (the versions pinned for the repository).
# Everything is read from what scripts/render makes of the tree, offline: each application as Flux
# builds it, with the placeholders of the cluster's example key lists, and each release as its chart
# renders it, as helm-controller does; each chart is pulled once per run from its public registry.

# The tests share one render of the tree and one chart cache, made by whichever of them comes
# first, so they run one at a time.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

# Where a Probe's prober and its targets are, its one relabeling and its modules, which
# tests/node-listeners.bats holds the tree's Probes to as well.
load fixtures/probe-shape

setup_file() {
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG"
  # scripts/render pulls each chart once per run, whichever copy of the tree it renders.
  export RENDER_CHART_CACHE="$BATS_FILE_TMPDIR/charts"
  mkdir -p "$RENDER_CHART_CACHE"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLUSTER="$REPO/kubernetes/clusters/lab-sto2"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  DOMAIN="$(yq -e '.CLUSTER_DOMAIN' "$CLUSTER/cluster-config.example.yaml")"
  APP_DIR=kubernetes/apps/base/monitoring/blackbox-exporter
}

# copy_tree: copies kubernetes/ and versions.yaml to $TREE, to break one thing in.
copy_tree() {
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  mkdir -p "$TREE"
  cp -r "$REPO/kubernetes" "$TREE/kubernetes"
  cp "$REPO/versions.yaml" "$TREE/versions.yaml"
}

# render DIR OUT: what Flux and helm-controller would apply from the tree in DIR, rendered by
# scripts/render into OUT, a directory per cluster and application.
render() {
  KUBECONFIG=/dev/null "$REPO/scripts/render" "$2" "$1" >"$2.log" 2>&1 || { cat "$2.log"; return 1; }
}

# tree_render: renders this tree once per run and sets RENDER to it.
tree_render() {
  RENDER="$BATS_FILE_TMPDIR/render"
  [ -d "$RENDER" ] || render "$REPO" "$RENDER"
}

# overlay_only APP...: leaves in the overlay of $TREE its namespace directories and the ks.yaml of
# each APP alone, so the copy renders what a test reads and nothing else.
overlay_only() {
  local IFS='|'
  PATTERN="/($*)/ks.yaml\$" yq -i '.resources |= map(select((test("/ks.yaml$") | not) or test(strenv(PATTERN))))' \
    "$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
}

# choose_issuer ISSUER: the patches of the overlay of $TREE that choose the issuer of the Gateway's
# certificate and the one its probes trust both choose ISSUER, or neither is there when ISSUER is
# empty, which leaves the cluster's own CA.
choose_issuer() {
  local overlay="$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  if [ -z "$1" ]; then
    yq -i 'del(.patches[] | select(.target.name == "gateway-public" or .target.name == "blackbox-exporter"))' "$overlay"
    return
  fi
  CHOSEN="$1" yq -i '(.patches[] | select(.target.name == "gateway-public")).patch |= (from_yaml | (.[] | select(.path == "/spec/postBuild").value.substitute.PUBLIC_ISSUER) = strenv(CHOSEN) | to_yaml)' "$overlay"
  CHOSEN="$1" yq -i '(.patches[] | select(.target.name == "blackbox-exporter")).patch |= (from_yaml | .spec.postBuild.substitute.PROBE_ISSUER = strenv(CHOSEN) | to_yaml)' "$overlay"
}

# tree_without APP...: copies kubernetes/ to $TREE and takes the ks.yaml of each APP out of the
# overlay's resources.
tree_without() {
  local app
  copy_tree
  for app in "$@"; do
    yq -i '.resources |= map(select(test("/'"$app"'/ks.yaml$") | not))' "$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  done
}

# collect RENDER OUT: what the rules of the probes read of the cluster lab-sto2 in RENDER, a render
# scripts/render made: every Gateway, HTTPRoute, SecurityPolicy and Probe the cluster applies, as a
# JSON array in OUT. The render holds each application as Flux builds it, its components and
# substitutions included (the sign-in component names its route and hostname by variables), and
# each release as its chart renders it, so a route or a Probe that a chart makes from a release's
# values is read as one a manifest declares. A chart's object that names no namespace gets its
# release's, where helm-controller installs it: helm-controller's labels name the HelmRelease, and
# that namespace is its targetNamespace, or its own. An object with a list of items, as a List a
# chart renders, is read as those items, and theirs in turn, each in the release of the object that
# holds it: Helm decodes any document with items as a list and installs each item (pkg/kube's
# Build, Flatten).
collect() {
  local files kind
  # A kind the render holds none of matches nothing, which is no failure: the others are still read.
  mapfile -t files < <({ for kind in Gateway.gateway.networking.k8s.io HTTPRoute.gateway.networking.k8s.io \
    SecurityPolicy.gateway.envoyproxy.io Probe.monitoring.coreos.com HelmRelease.helm.toolkit.fluxcd.io; do
    compgen -G "$1/lab-sto2/*/${kind}_*.yaml" || true
  done
    grep -l -E '^items:' "$1"/lab-sto2/*/*.yaml || true; } | awk '!seen[$0]++')
  [ "${#files[@]}" -gt 0 ] || { echo "the render $1 holds nothing of lab-sto2 that the probes' rules read"; return 1; }
  # shellcheck disable=SC2016 # $releases and $labels are jq variables.
  (set -o pipefail; yq -N -o json -I0 'select(. != null)' "${files[@]}" | jq -s '
    def items: if (.items | type) == "array" then .items[] | items else . end;
    def read: (.apiVersion // "" | sub("/[^/]*$"; "")) + "/" + (.kind // "")
      | IN("gateway.networking.k8s.io/Gateway", "gateway.networking.k8s.io/HTTPRoute",
        "gateway.envoyproxy.io/SecurityPolicy", "monitoring.coreos.com/Probe");
    ([.[] | select(.kind == "HelmRelease")
        | {key: "\(.metadata.namespace // "")/\(.metadata.name)", value: (.spec.targetNamespace // .metadata.namespace // "")}]
      | from_entries) as $releases
    | map(select(.kind != "HelmRelease") | (.metadata.labels // {}) as $labels
        | items | select(read)
        | .metadata.namespace //= ($releases["\($labels["helm.toolkit.fluxcd.io/namespace"] // "")/\($labels["helm.toolkit.fluxcd.io/name"] // "")"] // ""))' >"$2")
}

# proxy_service OBJECTS: the cluster name of the Service Envoy Gateway makes for the proxies of the
# one Gateway of OBJECTS (proxy_service_name of fixtures/probe-shape.bash), of the Gateway's
# namespace and name, in the controller's namespace, read from the render of this tree
# (controller_namespace).
proxy_service() {
  local namespace name controller
  namespace="$(jq -r '[.[] | select(.kind == "Gateway")] | if length == 1 then .[0].metadata.namespace else error("not one Gateway") end' "$1")"
  name="$(jq -r '[.[] | select(.kind == "Gateway")][0].metadata.name' "$1")"
  tree_render
  controller="$(controller_namespace "$RENDER/lab-sto2")" || return 1
  proxy_service_name "$namespace" "$name" "$controller"
}

# exporter_address: where a Probe reaches the exporter, read from the render of this tree
# (exporter_service of fixtures/probe-shape.bash).
exporter_address() {
  tree_render
  exporter_service "$RENDER/lab-sto2"
}

# unprobed OBJECTS: one line for each route of the public Gateway that no Probe covers. A Probe
# counts only when the alerts select it (the job public-endpoints), it goes to the exporter
# (prober.url), it uses the module of its listener and it sends its hostname label to the exporter as
# the parameter hostname: the last relabeling that writes __param_hostname copies the label hostname
# as it is, the default regex and replacement, and no relabeling writes another label, maps or drops
# labels, or keeps or drops the target. It counts only in the shape that probes, the fields hello's
# has and no other: its spec the job, the module, the prober and the targets; its prober the address
# alone; its targets one static target, the hostname label alone and the relabelings. Anything more
# is a way for a Probe that is there not to probe: a path or a scheme of the prober, an interval, a
# scrape timeout or metric relabelings of its own, discovered targets, a second target, a label
# Prometheus reads as a setting of the scrape (__metrics_path__, __scheme__, __param_module), or a
# relabeling that rewrites the address, the target, the path or the job after the operator's own,
# which come first. For a route on the https listener that is each hostname
# that no Probe names, with the hostname label, whose target is the proxies' Service over https with
# the module of the hostname: public_https_signin, which expects the redirect that starts a sign-in,
# for a hostname behind the cluster's sign-in, and public_https otherwise. A hostname is behind
# sign-in when a route of it on the listener is the target, by targetRefs or targetRef, of a
# SecurityPolicy with external authorisation (tests/gateway.bats refuses a policy that selects routes
# by label, or one on the Gateway but its ClientTrafficPolicy). The rule keys on hostnames: one
# Probe covers every route of its hostname, as the sign-in paths of a host behind sign-in, a route
# no policy covers, are covered by that host's Probe of the redirect. A Probe over https of a route's
# hostname with the other module is a line of its own: one for 200 behind sign-in would pass only
# once the policy were lost, and one for the redirect elsewhere could never pass. A route without
# hostnames serves every name under the listener's wildcard, so it is a line of its own. For a route
# on the http listener, it is the redirect that no Probe has as a target over http with the module
# public_http_redirect. Prints nothing when every route is probed.
unprobed() {
  local objects=$1 service gateway gateway_namespace prober
  service="$(proxy_service "$objects")"
  gateway="$(jq -r '[.[] | select(.kind == "Gateway")][0].metadata.name' "$objects")"
  gateway_namespace="$(jq -r '[.[] | select(.kind == "Gateway")][0].metadata.namespace' "$objects")"
  prober="$(exporter_address)"
  # shellcheck disable=SC2016 # $service, $gateway, $namespace, $prober, $listener, $all, $signin, $https, $behind, $hosts, $probes, $name, $module, $c, $r, $w, $own, $h, $want, $fields and $ref are jq variables.
  jq -r --arg service "$service" --arg gateway "$gateway" --arg namespace "$gateway_namespace" --arg prober "$prober" '
    def holds($fields): type == "object" and keys == $fields;
    def shaped:
      (.spec | holds(["jobName", "module", "prober", "targets"]))
      and (.spec.prober | holds(["url"]))
      and (.spec.targets | holds(["staticConfig"]))
      and (.spec.targets.staticConfig | holds(["labels", "relabelingConfigs", "static"]))
      and (.spec.targets.staticConfig.labels | holds(["hostname"]))
      and (.spec.targets.staticConfig.static | type == "array" and length == 1)
      and (.spec.targets.staticConfig.relabelingConfigs | type == "array");
    def sends_hostname:
      .spec.targets.staticConfig.relabelingConfigs as $r
      | ([$r[] | select(.targetLabel == "__param_hostname")] | last) as $w
      | $w != null
        and (($w.action // "replace") | ascii_downcase) == "replace" and $w.sourceLabels == ["hostname"]
        and ($w.regex // "(.*)") == "(.*)" and (($w.replacement // "$1") | IN("$1", "${1}"))
        and ([$r[] | select(.targetLabel != "__param_hostname"
          or ((.action // "replace") | ascii_downcase | IN("labelmap", "labeldrop", "labelkeep", "keep", "drop", "keepequal", "dropequal")))] | length == 0);
    def on_listener($listener): (.metadata.namespace // "") as $own
      | any(.spec.parentRefs[]?; .name == $gateway and (.namespace // $own) == $namespace and (.sectionName == "http") == ($listener == "http"));
    . as $all
    | [$all[] | select(.kind == "SecurityPolicy" and .spec.extAuth != null) | (.metadata.namespace // "") as $own
        | ([.spec.targetRef // empty] + (.spec.targetRefs // []))[]
        | select(.kind == "HTTPRoute" and (.group // "gateway.networking.k8s.io") == "gateway.networking.k8s.io")
        | "\($own)/\(.name)"] as $signin
    | [$all[] | select(.kind == "HTTPRoute" and on_listener("https"))] as $https
    | [$https[] | select("\(.metadata.namespace // "")/\(.metadata.name)" | IN($signin[])) | .spec.hostnames[]?] | unique as $behind
    | [$https[] | .spec.hostnames[]?] | unique as $hosts
    | [$all[] | select(.kind == "Probe")
      | select(shaped and .spec.jobName == "public-endpoints" and .spec.prober.url == $prober and sends_hostname)
      | {name: "\(.metadata.namespace)/\(.metadata.name)", target: .spec.targets.staticConfig.static[0], module: .spec.module,
         hostname: .spec.targets.staticConfig.labels.hostname}] as $probes
    | ($all[] | select(.kind == "HTTPRoute") | . as $r | (.metadata.namespace // "") as $own
      | .spec.parentRefs[]? | select(.name == $gateway and (.namespace // $own) == $namespace) | . as $ref
      | if $ref.sectionName == "http" then
          select([$probes[] | select(.module == "public_http_redirect" and (.target | startswith("http://" + $service + "/")))] | length == 0)
          | "HTTPRoute \($own)/\($r.metadata.name): no Probe has the redirect on plain HTTP through \($service) as its target"
        elif (($r.spec.hostnames // []) | length) == 0 then
          "HTTPRoute \($own)/\($r.metadata.name): no hostnames, so it serves every name under the listener and no Probe can name them"
        else
          $r.spec.hostnames[] as $h
          | (if $h | IN($behind[]) then "public_https_signin" else "public_https" end) as $want
          | select([$probes[] | select(.module == $want and .hostname == $h and (.target | startswith("https://" + $service + "/")))] | length == 0)
          | if $want == "public_https" then "HTTPRoute \($own)/\($r.metadata.name): no Probe over https through \($service) names the hostname \($h)"
            else "HTTPRoute \($own)/\($r.metadata.name): no Probe over https through \($service) expects the sign-in redirect for the hostname \($h)" end
        end),
      ($probes[] | select((.target | startswith("https://" + $service + "/")) and (.hostname | IN($hosts[])))
      | if .module == "public_https" and (.hostname | IN($behind[])) then
          "Probe \(.name) probes the hostname \(.hostname) for 200 with public_https, and an external-authorisation SecurityPolicy covers it: it would pass only once the policy were lost"
        elif .module == "public_https_signin" and (.hostname | IN($behind[]) | not) then
          "Probe \(.name) probes the hostname \(.hostname) for the sign-in redirect with public_https_signin, and no external-authorisation SecurityPolicy covers it"
        else empty end)' "$objects"
}

# header_problems RENDER: one line for each ClientTrafficPolicy of a cluster of RENDER that requires
# the PROXY protocol header on a Gateway whose listeners a Probe of the cluster reaches from inside,
# its target the proxies' Service by its cluster name (proxy_service), which the controller makes in
# its own namespace, read from the cluster's render. The exporter writes no header:
# its connection begins with the TLS handshake or the HTTP request, which a listener that requires a
# header resets. A policy requires it with proxyProtocol unless that is optional, and with the
# deprecated enableProxyProtocol, which can only require it; without either it takes no header.
# tests/gateway.bats holds the one policy on the Gateway to its targetRefs.
header_problems() {
  local dir cluster files objects services controller
  for dir in "$1"/*/; do
    dir="${dir%/}"
    cluster="${dir##*/}"
    mapfile -t files < <(compgen -G "$dir/*/Probe.monitoring.coreos.com_*.yaml"
      compgen -G "$dir/*/Gateway.gateway.networking.k8s.io_*.yaml"
      compgen -G "$dir/*/ClientTrafficPolicy.gateway.envoyproxy.io_*.yaml")
    [ "${#files[@]}" -gt 0 ] || continue
    controller="$(controller_namespace "$dir" 2>&1)" || { echo "$cluster: $controller"; continue; }
    objects="$(yq -N -o json -I0 'select(. != null)' "${files[@]}" | jq -cs .)"
    services="$(jq -r '.[] | select(.kind == "Gateway") | "\(.metadata.namespace) \(.metadata.name)"' <<<"$objects" |
      while read -r namespace name; do
        jq -cn --arg namespace "$namespace" --arg name "$name" --arg service "$(proxy_service_name "$namespace" "$name" "$controller")" \
          '{namespace: $namespace, name: $name, service: $service}'
      done | jq -cs .)"
    # shellcheck disable=SC2016 # $all, $cluster, $services, $g and $probes are jq variables.
    jq -r --arg cluster "$cluster" --argjson services "$services" '
      . as $all | $services[] as $g
      | [$all[] | select(.kind == "Probe")
          | select(any(.spec.targets.staticConfig.static[]?; test("^https?://" + ($g.service | gsub("\\."; "\\.")) + "(:[0-9]+)?(/|$)")))
          | "\(.metadata.namespace)/\(.metadata.name)"] | sort as $probes
      | select($probes | length > 0)
      | $all[] | select(.kind == "ClientTrafficPolicy" and .metadata.namespace == $g.namespace)
      | select([(.spec.targetRefs // [])[], (.spec.targetRef // empty)] | any(.kind == "Gateway" and .name == $g.name))
      | select(.spec.enableProxyProtocol == true or (.spec.proxyProtocol != null and .spec.proxyProtocol.optional != true))
      | "\($cluster): the ClientTrafficPolicy \(.metadata.namespace)/\(.metadata.name) requires the PROXY protocol header on the Gateway \($g.namespace)/\($g.name), and the Probes \($probes | join(", ")) reach its listeners from inside the cluster through \($g.service) without writing one: the probes would be cut"' <<<"$objects"
  done
}

# exporter_module DIR MODULE: the module MODULE as the exporter's chart writes it into the exporter's
# configuration, in DIR, the render of one cluster, as JSON.
exporter_module() {
  yq -N 'select(.kind == "ConfigMap" and .data["blackbox.yaml"] != null) | .data["blackbox.yaml"]' "$1"/blackbox-exporter/ConfigMap_*.yaml |
    MODULE="$2" yq -o json -I0 '.modules[strenv(MODULE)]' -
}

# Let's Encrypt's production directory, whose chain the system's roots verify, and its staging
# directory, whose chain no client trusts.
LETSENCRYPT_PRODUCTION=https://acme-v02.api.letsencrypt.org/directory
LETSENCRYPT_STAGING=https://acme-staging-v02.api.letsencrypt.org/directory

# trust_problems RENDER: one line for each way the probes of a cluster of RENDER do not verify the
# Gateway's certificate against the trust its issuer implies, read from what the cluster applies:
# the ClusterIssuer the Gateway's Certificate asks, the exporter's module public_https as its chart
# writes it into the exporter's configuration, and the exporter's pod. The other module over https,
# public_https_signin, verifies as public_https does: its tls_config is the same. An issuer of kind CA is
# trusted through its own certificate alone: the module's ca_file is the one key ca.crt of a Secret
# volume mounted read-only, the Secret of a Certificate of the exporter's application that the same
# issuer signs, as cert-manager puts the signing authority's certificate in that key. An ACME issuer
# of Let's Encrypt's production directory is trusted through the system's roots of the exporter's
# image: the module names no CA of its own and the pod holds no Secret. Under those two no module
# skips verification. An ACME issuer of Let's Encrypt's staging directory, whose chain no client
# trusts, is not verified: the module public_https skips verification, which is the one setting of
# its tls_config, no module but the two over https skips it, and the pod holds no Secret. No other
# issuer is trusted. A cluster without the exporter or the Gateway probes nothing over https.
trust_problems() {
  local dir cluster config issuer name issuer_file tls signin_tls deployment ca_file mount volume secret server
  for dir in "$1"/*/; do
    dir="${dir%/}"
    cluster="${dir##*/}"
    [ -d "$dir/blackbox-exporter" ] && [ -d "$dir/gateway-public" ] || continue
    config="$(yq -N 'select(.kind == "ConfigMap" and .data["blackbox.yaml"] != null) | .data["blackbox.yaml"]' "$dir"/blackbox-exporter/ConfigMap_*.yaml)"
    tls="$(yq -o json -I0 '.modules.public_https.http.tls_config // {}' <<<"$config")"
    signin_tls="$(yq -o json -I0 '.modules.public_https_signin.http.tls_config // {}' <<<"$config")"
    [ "$signin_tls" = "$tls" ] ||
      echo "$cluster: the module public_https_signin verifies otherwise than public_https: $signin_tls"
    issuer="$(yq -N 'select(.kind == "Certificate" and .spec.secretName == "public-wildcard-tls") | .spec.issuerRef.kind + "/" + .spec.issuerRef.name' "$dir"/gateway-public/*.yaml)"
    name="${issuer#ClusterIssuer/}"
    issuer_file="$(NAME="$name" yq -N 'select(.kind == "ClusterIssuer" and .metadata.name == strenv(NAME)) | filename' "$dir"/*/ClusterIssuer.*.yaml)"
    server=""
    [ -z "$issuer_file" ] || server="$(yq '.spec.acme.server // ""' "$issuer_file")"
    if [ "$server" = "$LETSENCRYPT_STAGING" ]; then
      [ "$tls" = '{"insecure_skip_verify":true}' ] ||
        echo "$cluster: the Gateway's certificate comes from $name, whose chain no client trusts, and the module public_https's tls_config is not insecure_skip_verify alone: $tls"
      [ "$(yq -o json -I0 '[.modules | to_entries[] | select(.key != "public_https" and .key != "public_https_signin") | .value | .. | select(tag == "!!map") | select(has("insecure_skip_verify")) | .insecure_skip_verify] | any' <<<"$config")" = false ] ||
        echo "$cluster: a module other than the two over https sets insecure_skip_verify"
    elif [ "$(yq -o json -I0 '[.. | select(tag == "!!map") | select(has("insecure_skip_verify")) | .insecure_skip_verify] | any' <<<"$config")" != false ]; then
      echo "$cluster: a module sets insecure_skip_verify"
    fi
    deployment="$(yq -N -o json -I0 'select(.kind == "Deployment")' "$dir"/blackbox-exporter/Deployment.*.yaml)"
    if [ "$issuer" != "ClusterIssuer/$name" ] || [ -z "$issuer_file" ]; then
      echo "$cluster: the Gateway's certificate asks $issuer, which is not a ClusterIssuer the cluster applies"
    elif [ "$(yq '.spec.ca != null' "$issuer_file")" = true ]; then
      ca_file="$(jq -r '.ca_file // ""' <<<"$tls")"
      [ "$(jq -c 'keys - ["ca_file"] | map(select(test("^(ca|ca_ref|server_name)$")))' <<<"$tls")" = '[]' ] ||
        echo "$cluster: the module public_https names a CA or a server name besides its ca_file"
      if [ -z "$ca_file" ]; then
        echo "$cluster: the Gateway's certificate comes from the cluster's authority $name, and the module public_https has no ca_file"
        continue
      fi
      mount="$(jq -c --arg dir "${ca_file%/*}" '[.spec.template.spec.containers[] | select(.name == "blackbox-exporter") | .volumeMounts[]? | select(.mountPath == $dir)]' <<<"$deployment")"
      [ "$(jq 'length' <<<"$mount")" -eq 1 ] && [ "$(jq '.[0].readOnly' <<<"$mount")" = true ] ||
        echo "$cluster: ca_file $ca_file is not in one read-only mount of the exporter"
      volume="$(jq -c --arg name "$(jq -r '.[0].name' <<<"$mount")" '[.spec.template.spec.volumes[]? | select(.name == $name)][0] // {}' <<<"$deployment")"
      [ "$(jq -c '.secret.items' <<<"$volume")" = "[{\"key\":\"ca.crt\",\"path\":\"${ca_file##*/}\"}]" ] ||
        echo "$cluster: ca_file $ca_file is not the one key ca.crt of a Secret"
      secret="$(jq -r '.secret.secretName // ""' <<<"$volume")"
      [ "$(SECRET="$secret" yq -N 'select(.kind == "Certificate" and .spec.secretName == strenv(SECRET)) | .spec.issuerRef.kind + "/" + .spec.issuerRef.name' "$dir"/blackbox-exporter/*.yaml)" = "$issuer" ] ||
        echo "$cluster: no Certificate of the exporter that $name signs makes the Secret $secret"
    elif [ "$(yq '.spec.acme.server' "$issuer_file")" = "$LETSENCRYPT_PRODUCTION" ]; then
      [ "$(jq -c 'keys | map(select(test("^(ca|ca_file|ca_ref|server_name)$")))' <<<"$tls")" = '[]' ] ||
        echo "$cluster: the Gateway's certificate comes from $name, which the system's roots verify, and the module public_https names a CA of its own: $tls"
      [ "$(jq '[.spec.template.spec.volumes[]? | select(.secret != null)] | length' <<<"$deployment")" -eq 0 ] ||
        echo "$cluster: the Gateway's certificate comes from $name, and the exporter's pod holds a Secret"
    elif [ "$server" = "$LETSENCRYPT_STAGING" ]; then
      [ "$(jq '[.spec.template.spec.volumes[]? | select(.secret != null)] | length' <<<"$deployment")" -eq 0 ] ||
        echo "$cluster: the Gateway's certificate comes from $name, and the exporter's pod holds a Secret"
    else
      echo "$cluster: the Gateway's certificate comes from $name, which the probes have no trust for"
    fi
  done
}

# secret_volume_problems RENDERED: one line for each way the pod of the rendered Deployment holds
# more of a Secret than the public certificate: the Secret volumes are one, of the exporter's trust
# Secret, with the one key ca.crt; no container mounts them read-write.
secret_volume_problems() {
  local deployment
  deployment="$(yq -N -o json -I0 'select(.kind == "Deployment")' "$1")"
  [ "$(jq '[.spec.template.spec.volumes[]? | select(.secret != null)] | length' <<<"$deployment")" -eq 1 ] ||
    echo "the pod does not hold exactly one Secret volume"
  [ "$(jq -c '[.spec.template.spec.volumes[]? | select(.secret != null) | [.secret.secretName, .secret.items]]' <<<"$deployment")" = '[["blackbox-exporter-trust",[{"key":"ca.crt","path":"ca.crt"}]]]' ] ||
    echo "a Secret volume is not the one key ca.crt of blackbox-exporter-trust"
}

# probe_apps_without_exporter RENDER: one line for each application of a cluster of RENDER, but the
# exporter's own, that holds a Probe and whose Kustomization, as the cluster applies it, does not
# name blackbox-exporter in dependsOn. RENDER is a render scripts/render made, a directory to each
# application named as its Kustomization: a Probe is an object of that directory whose kind is
# Probe, however its file writes it, one Flux builds of the tree or one a chart renders from a
# release's values.
probe_apps_without_exporter() {
  local dir cluster app
  local -a ks
  for dir in "$1"/*/; do
    dir="${dir%/}"
    cluster="${dir##*/}"
    for app in "$dir"/*/; do
      app="${app%/}"
      app="${app##*/}"
      [ "$app" != blackbox-exporter ] || continue
      compgen -G "$dir/$app/Probe.monitoring.coreos.com_*.yaml" >/dev/null || continue
      mapfile -t ks < <(compgen -G "$dir/*/Kustomization.kustomize.toolkit.fluxcd.io_*_$app.yaml")
      if [ "${#ks[@]}" -ne 1 ]; then
        echo "$cluster: the application $app declares a Probe, and the render holds not one Kustomization of its name"
      elif [ -z "$(yq '.spec.dependsOn[]?.name | select(. == "blackbox-exporter")' "${ks[0]}")" ]; then
        echo "$cluster: the application $app declares a Probe and its Kustomization does not name blackbox-exporter in dependsOn"
      fi
    done
  done
}

# pull_chart: pulls the exporter's chart at the tag of its OCIRepository, once per run, and sets
# CHART to its archive.
pull_chart() {
  local url tag pulled
  url="$(yq '.spec.url' "$REPO/$APP_DIR/app/ocirepository.yaml")"
  tag="$(yq '.spec.ref.tag' "$REPO/$APP_DIR/app/ocirepository.yaml")"
  pulled="$BATS_FILE_TMPDIR/chart/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
}

# render_chart [VALUES...]: renders the exporter's chart with the shared values of the application
# (or the files VALUES, each over the one before), as Flux's HelmRelease does, into RENDERED.
render_chart() {
  local file values=()
  RENDERED="$BATS_TEST_TMPDIR/rendered.yaml"
  pull_chart
  for file in "${@:-$REPO/$APP_DIR/app/values.yaml}"; do
    values+=(--values "$file")
  done
  helm template blackbox-exporter "$CHART" --namespace monitoring --kube-version "$(yq -e '.kubernetes' "$REPO/versions.yaml")" \
    --api-versions monitoring.coreos.com/v1 "${values[@]}" >"$RENDERED"
}

@test "A route on the public Gateway is probed over HTTPS through the Gateway, by name, without leaving the cluster" {
  local objects="$BATS_TEST_TMPDIR/objects.json" service controller probe prober other="$BATS_TEST_TMPDIR/other"
  tree_render
  collect "$RENDER" "$objects"
  service="$(proxy_service "$objects")"
  echo "the proxies' Service: $service"
  # The controller makes that Service at run time, so no render holds its name: the rule for it was
  # read in the controller's source, at the version the cluster runs. A controller of another
  # version, which could name the Service otherwise and so fail every probe at the name's
  # resolution, fails here until the rule is read again in its source.
  controller="$(yq '.spec.template.spec.containers[] | select(.name == "envoy-gateway") | .image | sub("@.*$"; "") | sub("^.*:"; "")' \
    "$RENDER"/lab-sto2/envoy-gateway/Deployment.apps_envoy-gateway-system_envoy-gateway.yaml)"
  echo "the controller: $controller; the rule for its Service's name was read at $PROXY_SERVICE_READ_AT"
  [ "$controller" = "$PROXY_SERVICE_READ_AT" ]
  # The controller makes the proxies' Service in its own namespace, whichever namespace the Gateway
  # is in: the Gateway public taken into another namespace is reached at the Service of its new name
  # in the controller's namespace, envoy-gateway-system.
  jq '(.[] | select(.kind == "Gateway") | .metadata.namespace) = "edge"' "$objects" >"$BATS_TEST_TMPDIR/moved.json"
  [ "$(proxy_service "$BATS_TEST_TMPDIR/moved.json")" = \
    "envoy-edge-public-$(printf edge/public | sha256sum | cut -c1-8).envoy-gateway-system.svc.cluster.local" ]
  # That holds while the controller deploys the proxies in its own namespace. Configured to deploy
  # them in each Gateway's namespace, where they take another name, it is refused.
  mkdir -p "$BATS_TEST_TMPDIR/mode"
  cp -R "$RENDER/lab-sto2/envoy-gateway" "$BATS_TEST_TMPDIR/mode/"
  yq -i '.data["envoy-gateway.yaml"] |= (from_yaml | .provider.kubernetes.deploy.type = "GatewayNamespace" | to_yaml)' \
    "$BATS_TEST_TMPDIR/mode/envoy-gateway/ConfigMap_envoy-gateway-system_envoy-gateway-config.yaml"
  run controller_namespace "$BATS_TEST_TMPDIR/mode"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"deploys the proxies in the mode GatewayNamespace"* ]]
  # A render without the controller's configuration says nothing of the mode, and is refused too.
  rm "$BATS_TEST_TMPDIR/mode/envoy-gateway/ConfigMap_envoy-gateway-system_envoy-gateway-config.yaml"
  run controller_namespace "$BATS_TEST_TMPDIR/mode"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"no configuration of Envoy Gateway's controller"* ]]
  # The exporter is reached at the one Service its release renders, in the namespace monitoring, on
  # that Service's port.
  prober="$(exporter_address)"
  echo "the exporter: $prober"
  [[ $prober == *.monitoring.svc.cluster.local:* ]]
  # The route's Probe: the one target is the Service over https, the hostname is the route's, and
  # goes to the exporter as the parameter that sets the Host header and the name TLS verifies.
  probe="$(jq -c '[.[] | select(.kind == "Probe" and .metadata.name == "hello")] | if length == 1 then .[0] else error("not one Probe hello") end' "$objects")"
  echo "$probe"
  [ "$(jq -r '.spec.prober.url' <<<"$probe")" = "$prober" ]
  [ "$(jq -r '.spec.module' <<<"$probe")" = public_https ]
  [ "$(jq -r '.spec.jobName' <<<"$probe")" = public-endpoints ]
  [ "$(jq -c '.spec.targets.staticConfig.static' <<<"$probe")" = "[\"https://$service/\"]" ]
  [ "$(jq -r '.spec.targets.staticConfig.labels.hostname' <<<"$probe")" = "hello.$DOMAIN" ]
  [ "$(jq -c '.spec.targets.staticConfig.relabelingConfigs' <<<"$probe")" = "$PROBE_RELABELINGS" ]
  # The route is the one that has that hostname, on the public Gateway's https listener.
  [ "$(jq -r '[.[] | select(.kind == "HTTPRoute" and .metadata.name == "hello")][0].spec.hostnames | join(",")' "$objects")" = "hello.$DOMAIN" ]
  # The target names the cluster's Service: no address, and nothing under the domain, which would
  # go out through public DNS to the edges.
  [[ $service == *.svc.cluster.local ]]
  [ -z "$(jq -r '.. | strings' <<<"$probe" | grep -E '(^|[^0-9.])[0-9]{1,3}(\.[0-9]{1,3}){3}([^0-9]|$)' || true)" ]
  [ -z "$(jq -r '.spec.targets.staticConfig.static[]' <<<"$probe" | grep -F "$DOMAIN" || true)" ]
  # Rendered with another domain, the hostname follows it and the target does not: a copy of the
  # tree whose example cluster-config names another, with the route and the Gateway alone.
  copy_tree
  yq -i '.CLUSTER_DOMAIN = "other.example.org"' "$TREE/kubernetes/clusters/lab-sto2/cluster-config.example.yaml"
  overlay_only gateway-public hello-route
  render "$TREE" "$other"
  collect "$other" "$other.json"
  [ "$(jq -r '[.[] | select(.kind == "Probe" and .metadata.name == "hello")][0].spec.targets.staticConfig.labels.hostname' "$other.json")" = hello.other.example.org ]
  [ "$(proxy_service "$other.json")" = "$service" ]
  # The module the exporter runs takes a 200 only, over TLS, and does not follow a redirect. It sets
  # no server_name and no Host header, so the hostname parameter is the name TLS asks for and
  # verifies and the Host the proxies route on (the exporter's prober/http.go and prober/handler.go);
  # it asks for IPv4 and gives up after five seconds. The whole module is pinned, as the chart
  # renders it into the configuration of the exporter lab-sto2 runs, so a name or a header fixed in it
  # fails here; what it verifies against is the trust of the cluster's issuer, which the scenario of
  # the trust pins for each.
  [ "$(exporter_module "$RENDER/lab-sto2" public_https)" = \
    '{"http":{"fail_if_not_ssl":true,"follow_redirects":false,"preferred_ip_protocol":"ip4","valid_status_codes":[200]},"prober":"http","timeout":"5s"}' ]
  # The Gateway's own Probe is the redirect: plain HTTP, the apex of the domain, a 301 that is not
  # followed, as the redirect's route sends it.
  probe="$(jq -c '[.[] | select(.kind == "Probe" and .metadata.name == "https-redirect")] | if length == 1 then .[0] else error("not one Probe https-redirect") end' "$objects")"
  echo "$probe"
  [ "$(jq -r '.spec.prober.url' <<<"$probe")" = "$prober" ]
  [ "$(jq -r '.spec.module' <<<"$probe")" = public_http_redirect ]
  [ "$(jq -r '.spec.jobName' <<<"$probe")" = public-endpoints ]
  [ "$(jq -c '.spec.targets.staticConfig.static' <<<"$probe")" = "[\"http://$service/\"]" ]
  [ "$(jq -r '.spec.targets.staticConfig.labels.hostname' <<<"$probe")" = "$DOMAIN" ]
  [ "$(jq -c '.spec.targets.staticConfig.relabelingConfigs' <<<"$probe")" = "$PROBE_RELABELINGS" ]
  [ "$(exporter_module "$RENDER/lab-sto2" public_http_redirect)" = \
    '{"http":{"follow_redirects":false,"preferred_ip_protocol":"ip4","valid_status_codes":[301]},"prober":"http","timeout":"5s"}' ]
  # A route behind the cluster's sign-in is probed for the redirect that starts a sign-in: a 302 over
  # TLS, not followed, which oauth2-proxy sends through the proxies to a request without a session.
  # The module is the one over https but for the status, so it carries the same trust.
  [ "$(exporter_module "$RENDER/lab-sto2" public_https_signin)" = \
    '{"http":{"fail_if_not_ssl":true,"follow_redirects":false,"preferred_ip_protocol":"ip4","valid_status_codes":[302]},"prober":"http","timeout":"5s"}' ]
  probe="$(jq -c '[.[] | select(.kind == "Probe" and .metadata.name == "hello-sso")] | if length == 1 then .[0] else error("not one Probe hello-sso") end' "$objects")"
  echo "$probe"
  [ "$(jq -r '.spec.module' <<<"$probe")" = public_https_signin ]
  [ "$(jq -c '.spec.targets.staticConfig.static' <<<"$probe")" = "[\"https://$service/\"]" ]
  [ "$(jq -r '.spec.targets.staticConfig.labels.hostname' <<<"$probe")" = "hello-sso.$DOMAIN" ]
  # The targets of each Probe over https, which are one, the proxies' Service, shown here as the
  # path it asks for there, which its application answers 200 without a session and its route sends
  # on: the demo's page, n8n's health and Open WebUI's readiness endpoints, a badge of kromgo's,
  # dex's discovery document, oauth2-proxy's readiness endpoint, Backstage's and Ascender's ping
  # endpoint; and the pages behind
  # sign-in, which answer with the redirect: the demo's, the log store's interface, not its root,
  # which its route redirects itself, and Locust's interface, whose page Locust answers to anyone. A
  # second target, or one that is not the Service, shows whole.
  # shellcheck disable=SC2016 # $service is a jq variable.
  [ "$(jq -r --arg service "$service" '[.[] | select(.kind == "Probe" and (.spec.module | startswith("public_https")))
      | "\(.metadata.namespace)/\(.metadata.name) \(.spec.module) \(.spec.targets.staticConfig.static | map(ltrimstr("https://" + $service)) | join(" "))"] | sort | join(",")' "$objects")" = \
    "ai-system/n8n public_https /healthz,ai-system/open-webui public_https /health/db,ascender/ascender public_https /api/v2/ping/,backstage/backstage public_https /.backstage/health/v1/readiness,demo/hello public_https /,demo/hello-sso public_https_signin /,kromgo/kromgo public_https /badges/cluster_node_count,locust/locust public_https_signin /,monitoring/logs public_https_signin /select/vmui/,sso-system/auth public_https /ready,sso-system/dex public_https /.well-known/openid-configuration" ]
  # The Probes are in the namespaces of their routes, and the rules read the job they name: of the
  # five alerts the cluster applies, read from the render, every reference to a series of a probe or
  # of its scrape, two in each of the first three and one in each of the last two, selects that job,
  # so a probe of another job raises none of them.
  [ "$(jq -r '[.[] | select(.kind == "Probe") | .metadata.namespace] | sort | join(",")' "$objects")" = "ai-system,ai-system,ascender,backstage,demo,demo,envoy-gateway-system,kromgo,locust,monitoring,sso-system,sso-system" ]
  [ "$(yq -o json -I0 '.spec.groups' "$RENDER"/lab-sto2/blackbox-exporter/PrometheusRule.monitoring.coreos.com_monitoring_blackbox-exporter-alerts.yaml |
    jq -c '[.[].rules[] | [.alert, (.expr | [scan("\\b(?:probe_[a-z_]+|up)\\b")] | length),
      (.expr | [scan("\\b(?:probe_[a-z_]+|up)\\{job=\"public-endpoints\"\\}")] | length)]]')" = \
    '[["PublicEndpointDown",2,2],["PublicEndpointWrongStatus",2,2],["PublicCertificateExpiring",2,2],["PublicCertificateExpiryImminent",1,1],["ProbeNotRunning",1,1]]' ]
  # kromgo's route sends only the badge paths, and kromgo answers a badge it does not serve with a
  # 200 as well, in the SVG form: its Probe asks for one badge its configuration serves.
  probe="$(jq -r '[.[] | select(.kind == "Probe" and .metadata.name == "kromgo")][0].spec.targets.staticConfig.static | if length == 1 then .[0] else error("not one target of the Probe kromgo") end' "$objects")"
  echo "kromgo: $probe"
  [[ $probe == "https://$service/badges/"* ]]
  BADGE="${probe#"https://$service/badges/"}" yq -e '.badges[] | select(.id == strenv(BADGE)) | .id' "$REPO/kubernetes/apps/base/kromgo/kromgo/app/config.yaml"
}

@test "The probe verifies the certificate against the trust the cluster's issuer implies" {
  local problems module ca_render="$BATS_TEST_TMPDIR/ca-render" mixed="$BATS_TEST_TMPDIR/mixed" fx="$BATS_TEST_TMPDIR/fx"
  local certificate=gateway-public/Certificate.cert-manager.io_envoy-gateway-system_public-wildcard.yaml
  # lab-sto2 chooses letsencrypt-production in its overlay. In what the cluster applies, the
  # Gateway's Certificate asks that issuer, and the module that probes over https verifies against
  # the system's roots of the exporter's image: it names no CA of its own, and the pod holds no Secret.
  tree_render
  [ "$(yq '.spec.issuerRef.name' "$RENDER/lab-sto2/$certificate")" = letsencrypt-production ]
  module="$(exporter_module "$RENDER/lab-sto2" public_https)"
  echo "lab-sto2: $module"
  [ "$(jq -c '.http.tls_config // {}' <<<"$module")" = '{}' ]
  # The module that probes a route behind sign-in over https carries the same trust, under every issuer.
  [ "$(exporter_module "$RENDER/lab-sto2" public_https_signin | jq -c '.http.tls_config // {}')" = '{}' ]
  problems="$(trust_problems "$RENDER")"
  echo "$problems"
  [ -z "$problems" ]
  # A cluster that chooses nothing has the cluster's own CA, and the module trusts that authority
  # alone, through the one key of a Secret that holds its public certificate.
  copy_tree
  choose_issuer ""
  overlay_only cluster-ca gateway-public blackbox-exporter
  render "$TREE" "$ca_render"
  [ "$(yq '.spec.issuerRef.name' "$ca_render/lab-sto2/$certificate")" = cluster-ca ]
  module="$(exporter_module "$ca_render/lab-sto2" public_https)"
  echo "cluster-ca: $module"
  [ "$(jq -c '.http.tls_config' <<<"$module")" = '{"ca_file":"/etc/probe-trust/ca.crt"}' ]
  [ "$(exporter_module "$ca_render/lab-sto2" public_https_signin | jq -c '.http.tls_config')" = '{"ca_file":"/etc/probe-trust/ca.crt"}' ]
  problems="$(trust_problems "$ca_render")"
  echo "$problems"
  [ -z "$problems" ]
  # Never a private key: the pod holds one Secret volume, of the one key ca.crt.
  problems="$(secret_volume_problems "$ca_render"/lab-sto2/blackbox-exporter/Deployment.*.yaml)"
  echo "$problems"
  [ -z "$problems" ]
  # The values are the application's own, its shared values and the trust of the issuer the cluster
  # chose, and the HelmRelease adds none of its own over them.
  # shellcheck disable=SC2016 # ${PROBE_ISSUER:=cluster-ca} is the variable's name in the manifest, not the shell's.
  [ "$(yq -o json -I0 '[.spec.values // "", (.spec.valuesFrom[] | .name + ":" + (.valuesKey // "values.yaml"))]' "$REPO/$APP_DIR/app/helmrelease.yaml")" = \
    '["","blackbox-exporter-values:values.yaml","blackbox-exporter-trust-values:${PROBE_ISSUER:=cluster-ca}.yaml"]' ]
  # Probes that trust another issuer than the one the Gateway's certificate comes from are refused,
  # either way round: a Gateway of each render with the exporter of the other.
  rm -rf "$mixed" && mkdir -p "$mixed/lab-sto2"
  cp -R "$RENDER/lab-sto2/gateway-public" "$RENDER/lab-sto2/acme-issuers" "$RENDER/lab-sto2/cluster-ca" "$ca_render/lab-sto2/blackbox-exporter" "$mixed/lab-sto2/"
  run trust_problems "$mixed"
  echo "$output"
  [[ $output == *"comes from letsencrypt-production, which the system's roots verify, and the module public_https names a CA of its own"* ]]
  [[ $output == *"comes from letsencrypt-production, and the exporter's pod holds a Secret"* ]]
  rm -rf "$mixed" && mkdir -p "$mixed/lab-sto2"
  cp -R "$ca_render/lab-sto2/gateway-public" "$ca_render/lab-sto2/cluster-ca" "$RENDER/lab-sto2/blackbox-exporter" "$mixed/lab-sto2/"
  run trust_problems "$mixed"
  echo "$output"
  [[ $output == *"comes from the cluster's authority cluster-ca, and the module public_https has no ca_file"* ]]
  # A module that skips verification is refused, whatever the issuer.
  for problems in "$RENDER" "$ca_render"; do
    rm -rf "$fx" && cp -R "$problems" "$fx"
    yq -i '.data["blackbox.yaml"] |= (from_yaml | .modules.public_https.http.tls_config.insecure_skip_verify = true | to_yaml)' \
      "$fx"/lab-sto2/blackbox-exporter/ConfigMap_monitoring_blackbox-exporter.yaml
    run trust_problems "$fx"
    echo "$output"
    [[ $output == *"lab-sto2: a module sets insecure_skip_verify"* ]]
  done
  # A module over https that verifies otherwise than public_https, against no CA of its own or one
  # where public_https names none, is refused.
  for problems in "$RENDER" "$ca_render"; do
    rm -rf "$fx" && cp -R "$problems" "$fx"
    yq -i '.data["blackbox.yaml"] |= (from_yaml | .modules.public_https_signin.http.tls_config = {"ca_file": "/etc/elsewhere/ca.crt"} | to_yaml)' \
      "$fx"/lab-sto2/blackbox-exporter/ConfigMap_monitoring_blackbox-exporter.yaml
    run trust_problems "$fx"
    echo "$output"
    [[ $output == *"lab-sto2: the module public_https_signin verifies otherwise than public_https: "* ]]
  done
  rm -rf "$fx" && cp -R "$ca_render" "$fx"
  yq -i '.data["blackbox.yaml"] |= (from_yaml | .modules.public_https_signin.http |= del(.tls_config) | to_yaml)' \
    "$fx"/lab-sto2/blackbox-exporter/ConfigMap_monitoring_blackbox-exporter.yaml
  run trust_problems "$fx"
  echo "$output"
  [ "$output" = "lab-sto2: the module public_https_signin verifies otherwise than public_https: {}" ]
  # With the cluster's own CA, a volume of the Secret that holds more than the one key, and a pod
  # that mounts the whole Secret as well, are refused.
  rm -rf "$fx" && cp -R "$ca_render" "$fx"
  yq -i '(.spec.template.spec.volumes[] | select(.secret != null) | .secret) |= del(.items)' "$fx"/lab-sto2/blackbox-exporter/Deployment.*.yaml
  run trust_problems "$fx"
  echo "$output"
  [[ $output == *"is not the one key ca.crt of a Secret"* ]]
  # shellcheck disable=SC2016 # $f is a yq variable.
  yq ea '. as $f ireduce ({}; . * $f)' "$REPO/$APP_DIR/app/values.yaml" "$REPO/$APP_DIR/app/trust/cluster-ca.yaml" >"$BATS_TEST_TMPDIR/values.yaml"
  yq -i '.extraSecretMounts = [{"name": "whole", "secretName": "blackbox-exporter-trust", "mountPath": "/etc/whole"}]' "$BATS_TEST_TMPDIR/values.yaml"
  render_chart "$BATS_TEST_TMPDIR/values.yaml"
  run secret_volume_problems "$RENDERED"
  echo "$output"
  [[ $output == *"the pod does not hold exactly one Secret volume"* ]]
  # letsencrypt-staging, whose chain no client trusts, so the probes cannot verify it: the values of
  # that issuer make the modules that probe over https skip verification, and that is their one
  # setting. The kubernetes check accepts the cluster that chooses it, as the probes have values for
  # every issuer of the tree. Each module is the production one but for that setting, and the pod
  # holds no Secret.
  local staging_render="$BATS_TEST_TMPDIR/staging-render" production_module
  copy_tree
  choose_issuer letsencrypt-staging
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay_only cluster-ca acme-issuers gateway-public blackbox-exporter
  render "$TREE" "$staging_render"
  [ "$(yq '.spec.issuerRef.name' "$staging_render/lab-sto2/$certificate")" = letsencrypt-staging ]
  [ "$(yq '.spec.valuesFrom[1].valuesKey' "$staging_render"/lab-sto2/blackbox-exporter/HelmRelease.*.yaml)" = letsencrypt-staging.yaml ]
  [ "$(yq -o json -I0 '.data | keys' "$staging_render"/lab-sto2/blackbox-exporter/ConfigMap_monitoring_blackbox-exporter-trust-values.yaml)" = \
    '["cluster-ca.yaml","letsencrypt-production.yaml","letsencrypt-staging.yaml"]' ]
  module="$(exporter_module "$staging_render/lab-sto2" public_https)"
  echo "letsencrypt-staging: $module"
  [ "$module" = '{"http":{"fail_if_not_ssl":true,"follow_redirects":false,"preferred_ip_protocol":"ip4","tls_config":{"insecure_skip_verify":true},"valid_status_codes":[200]},"prober":"http","timeout":"5s"}' ]
  production_module="$(exporter_module "$RENDER/lab-sto2" public_https)"
  [ "$(jq -c 'del(.http.tls_config)' <<<"$module")" = "$(jq -c 'del(.http.tls_config)' <<<"$production_module")" ]
  module="$(exporter_module "$staging_render/lab-sto2" public_https_signin)"
  echo "letsencrypt-staging, behind sign-in: $module"
  [ "$module" = '{"http":{"fail_if_not_ssl":true,"follow_redirects":false,"preferred_ip_protocol":"ip4","tls_config":{"insecure_skip_verify":true},"valid_status_codes":[302]},"prober":"http","timeout":"5s"}' ]
  [ "$(jq -c 'del(.http.tls_config)' <<<"$module")" = "$(exporter_module "$RENDER/lab-sto2" public_https_signin)" ]
  [ "$(exporter_module "$staging_render/lab-sto2" public_http_redirect)" = "$(exporter_module "$RENDER/lab-sto2" public_http_redirect)" ]
  problems="$(trust_problems "$staging_render")"
  echo "$problems"
  [ -z "$problems" ]
  # Under staging, a module that verifies, one that skips with another setting beside it or says
  # false, and another module that skips as well, are each refused.
  local fixture
  for fixture in \
    '.modules.public_https.http |= del(.tls_config)' \
    '.modules.public_https.http.tls_config.insecure_skip_verify = false' \
    '.modules.public_https.http.tls_config.ca_file = "/etc/probe-trust/ca.crt"' \
    '.modules.public_https.http.tls_config.server_name = "elsewhere.example.org"' \
    '.modules.public_https_signin.http |= del(.tls_config)' \
    '.modules.public_http_redirect.http.tls_config.insecure_skip_verify = true'; do
    rm -rf "$fx" && cp -R "$staging_render" "$fx"
    FIXTURE="$fixture" yq -i '.data["blackbox.yaml"] |= (from_yaml | eval(strenv(FIXTURE)) | to_yaml)' \
      "$fx"/lab-sto2/blackbox-exporter/ConfigMap_monitoring_blackbox-exporter.yaml
    run trust_problems "$fx"
    echo "$fixture: $output"
    [ -n "$output" ]
    [[ $output == "lab-sto2: "* ]]
  done
  # Probes on staging's values with a Gateway of another issuer, and the other way round, are
  # refused: a Gateway of one render with the exporter of the other.
  rm -rf "$mixed" && mkdir -p "$mixed/lab-sto2"
  cp -R "$RENDER/lab-sto2/gateway-public" "$RENDER/lab-sto2/acme-issuers" "$RENDER/lab-sto2/cluster-ca" "$staging_render/lab-sto2/blackbox-exporter" "$mixed/lab-sto2/"
  run trust_problems "$mixed"
  echo "$output"
  [ "$output" = "lab-sto2: a module sets insecure_skip_verify" ]
  rm -rf "$mixed" && mkdir -p "$mixed/lab-sto2"
  cp -R "$ca_render/lab-sto2/gateway-public" "$ca_render/lab-sto2/cluster-ca" "$staging_render/lab-sto2/blackbox-exporter" "$mixed/lab-sto2/"
  run trust_problems "$mixed"
  echo "$output"
  [[ $output == *"lab-sto2: a module sets insecure_skip_verify"* ]]
  [[ $output == *"comes from the cluster's authority cluster-ca, and the module public_https has no ca_file"* ]]
  rm -rf "$mixed" && mkdir -p "$mixed/lab-sto2"
  cp -R "$staging_render/lab-sto2/gateway-public" "$staging_render/lab-sto2/acme-issuers" "$staging_render/lab-sto2/cluster-ca" "$RENDER/lab-sto2/blackbox-exporter" "$mixed/lab-sto2/"
  run trust_problems "$mixed"
  echo "$output"
  [ "$output" = "lab-sto2: the Gateway's certificate comes from letsencrypt-staging, whose chain no client trusts, and the module public_https's tls_config is not insecure_skip_verify alone: {}" ]
  # An issuer the probes hold no values for is refused by the kubernetes check, for the Gateway's
  # certificate and for the probes: here one more ACME issuer, which the copy's acme-issuers defines
  # and both choose.
  copy_tree
  yq '.metadata.name = "letsencrypt-other" | .spec.acme.privateKeySecretRef.name = "letsencrypt-other-account"' \
    "$TREE/kubernetes/apps/base/cert-manager/acme-issuers/app/clusterissuer-production.yaml" \
    >"$TREE/kubernetes/apps/base/cert-manager/acme-issuers/app/clusterissuer-other.yaml"
  yq -i '.resources += ["clusterissuer-other.yaml"]' "$TREE/kubernetes/apps/base/cert-manager/acme-issuers/app/kustomization.yaml"
  choose_issuer letsencrypt-other
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"kubernetes/apps/base/monitoring/blackbox-exporter/ks.yaml: Kustomization blackbox-exporter probes the public Gateway of kubernetes/apps/overlays/lab-sto2, whose certificate comes from letsencrypt-other, and the probes hold no trust for letsencrypt-other"* ]]
  [[ $output == *"Kustomization blackbox-exporter is given the issuer letsencrypt-other to trust in kubernetes/apps/overlays/lab-sto2, and the probes hold no trust for letsencrypt-other"* ]]
  [[ $output == *"add kubernetes/apps/base/monitoring/blackbox-exporter/app/trust/letsencrypt-other.yaml"* ]]
  [[ $output != *"probe after moving"* ]]
  # And its release fails rather than probe without the values: the key it reads is not in the
  # ConfigMap, which helm-controller refuses, and so does the render.
  overlay_only cluster-ca acme-issuers gateway-public blackbox-exporter
  run render "$TREE" "$BATS_TEST_TMPDIR/other-render"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"lab-sto2/blackbox-exporter: HelmRelease monitoring/blackbox-exporter: values from ConfigMap blackbox-exporter-trust-values-"*" name the key letsencrypt-other.yaml, which the ConfigMap does not hold"* ]]
}

@test "A route on the public Gateway without a probe fails the checks" {
  local objects="$BATS_TEST_TMPDIR/objects.json" routes fixture="$BATS_TEST_TMPDIR/fixture.json" copy="$BATS_TEST_TMPDIR/copy" app
  tree_render
  collect "$RENDER" "$objects"
  # Every route of the tree is probed: the demo's, kromgo's, n8n's, Open WebUI's, dex's, the sign-in
  # host's, Backstage's, Ascender's, and the demo's, the log store's interface's and Locust's
  # interface's behind sign-in with their sign-in paths by their hostnames, and the redirect. They
  # are the routes of the render, which holds those a chart makes as well.
  routes="$(jq -r '[.[] | select(.kind == "HTTPRoute") | .metadata.name] | sort | join(",")' "$objects")"
  echo "routes: $routes"
  [ "$routes" = "ascender,auth,backstage,dex,hello,hello-sso,hello-sso-oauth2,https-redirect,kromgo,locust,locust-oauth2,logs,logs-oauth2,n8n,open-webui" ]
  run unprobed "$objects"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # A copy of the tree with a route, in the demo namespace that opts in, for a hostname that no
  # Probe names fails, naming the route and the hostname.
  copy_tree
  cat >"$TREE/kubernetes/apps/base/demo/hello-route/app/httproute-fixture.yaml" <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: unprobed
spec:
  parentRefs:
    - name: public
      namespace: envoy-gateway-system
      sectionName: https
  hostnames:
    - unprobed.\${CLUSTER_DOMAIN}
  rules:
    - backendRefs:
        - name: hello
          port: 80
EOF
  yq -i '.resources += ["httproute-fixture.yaml"]' "$TREE/kubernetes/apps/base/demo/hello-route/app/kustomization.yaml"
  render "$TREE" "$copy-route"
  collect "$copy-route" "$fixture"
  run unprobed "$fixture"
  echo "$output"
  [ "$(wc -l <<<"$output")" -eq 1 ]
  [[ $output == "HTTPRoute demo/unprobed: no Probe over https through "*" names the hostname unprobed.$DOMAIN" ]]
  # A Probe that names the hostname but goes elsewhere, to the hostname itself, which leaves the
  # cluster through public DNS, does not count. The copies from here on render the applications
  # they change and the Gateway alone.
  # shellcheck disable=SC2016 # ${CLUSTER_DOMAIN} is the variable's name in the manifest, not the shell's.
  yq -i '.spec.targets.staticConfig.static = ["https://hello.${CLUSTER_DOMAIN}/"]' "$TREE/kubernetes/apps/base/demo/hello-route/app/probe.yaml"
  overlay_only gateway-public hello-route
  render "$TREE" "$copy-target"
  collect "$copy-target" "$fixture"
  run unprobed "$fixture"
  echo "$output"
  [[ $output == *"names the hostname hello.$DOMAIN"* ]]
  # A route that a chart renders from its release's values is a route of the cluster all the same:
  # kromgo's release with a second route in its values, for a hostname that no Probe names, fails,
  # naming the route the chart makes and the hostname.
  copy_tree
  app="$TREE/kubernetes/apps/base/kromgo/kromgo/app"
  # shellcheck disable=SC2016 # ${CLUSTER_DOMAIN} is the variable's name in the manifest, not the shell's.
  yq -i '.spec.values.route.unprobed = {"suffix": "unprobed", "hostnames": ["unprobed.${CLUSTER_DOMAIN}"],
    "parentRefs": [{"name": "public", "namespace": "envoy-gateway-system", "sectionName": "https"}],
    "rules": [{"backendRefs": [{"name": "kromgo", "port": 8080}]}]}' "$app/helmrelease.yaml"
  overlay_only gateway-public kromgo
  render "$TREE" "$copy-chart-route"
  collect "$copy-chart-route" "$fixture"
  [ "$(jq -r '[.[] | select(.kind == "HTTPRoute" and .metadata.labels["helm.toolkit.fluxcd.io/name"] == "kromgo") | "\(.metadata.namespace)/\(.metadata.name)"] | join(",")' "$fixture")" = kromgo/kromgo-unprobed ]
  run unprobed "$fixture"
  echo "a route the chart renders: $output"
  [ "$(wc -l <<<"$output")" -eq 1 ]
  [[ $output == "HTTPRoute kromgo/kromgo-unprobed: no Probe over https through "*" names the hostname unprobed.$DOMAIN" ]]
  # A Probe that the chart renders from the same values counts as one a manifest declares, in the
  # namespace of its release, which the chart leaves unnamed: with it, the copy passes.
  # shellcheck disable=SC2016 # ${CLUSTER_DOMAIN} is the variable's name in the manifest, not the shell's.
  PROBE="$(yq -o json -I0 '{"apiVersion": .apiVersion, "kind": .kind, "spec": .spec}
    | .spec.targets.staticConfig.labels.hostname = "unprobed.${CLUSTER_DOMAIN}"' "$app/probe.yaml")" \
    yq -i '.spec.values.rawResources.unprobed = {"suffix": "unprobed", "manifest": env(PROBE)}' "$app/helmrelease.yaml"
  render "$TREE" "$copy-chart-probe"
  [ "$(yq '.metadata.namespace // "none"' "$copy-chart-probe"/lab-sto2/kromgo/Probe.monitoring.coreos.com__kromgo-unprobed.yaml)" = none ]
  collect "$copy-chart-probe" "$fixture"
  [ "$(jq -r '[.[] | select(.kind == "Probe") | "\(.metadata.namespace)/\(.metadata.name)"] | sort | join(",")' "$fixture")" = \
    envoy-gateway-system/https-redirect,kromgo/kromgo,kromgo/kromgo-unprobed ]
  run unprobed "$fixture"
  echo "a route and its Probe the chart renders: $output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # What a chart renders inside a List is read as the List's items, each an object, as Helm installs
  # them: a route the chart renders in a List, for a hostname that no Probe names, fails, naming the
  # item, and with its Probe in the same List the copy passes.
  # shellcheck disable=SC2016 # ${CLUSTER_DOMAIN} is the variable's name in the manifest, not the shell's.
  yq -i '.spec.values.rawResources.listed = {"suffix": "listed", "manifest": {"apiVersion": "v1", "kind": "List", "items": [
    {"apiVersion": "gateway.networking.k8s.io/v1", "kind": "HTTPRoute", "metadata": {"name": "kromgo-listed"},
     "spec": {"parentRefs": [{"name": "public", "namespace": "envoy-gateway-system", "sectionName": "https"}],
       "hostnames": ["listed.${CLUSTER_DOMAIN}"], "rules": [{"backendRefs": [{"name": "kromgo", "port": 8080}]}]}}]}}' "$app/helmrelease.yaml"
  render "$TREE" "$copy-chart-list"
  [ "$(yq '.kind + " " + (.items | map(.kind) | join(","))' "$copy-chart-list"/lab-sto2/kromgo/List__kromgo-listed.yaml)" = "List HTTPRoute" ]
  collect "$copy-chart-list" "$fixture"
  run unprobed "$fixture"
  echo "a route the chart renders in a List: $output"
  [ "$(wc -l <<<"$output")" -eq 1 ]
  [[ $output == "HTTPRoute kromgo/kromgo-listed: no Probe over https through "*" names the hostname listed.$DOMAIN" ]]
  # shellcheck disable=SC2016 # ${CLUSTER_DOMAIN} is the variable's name in the manifest, not the shell's.
  PROBE="$(yq -o json -I0 '{"apiVersion": .apiVersion, "kind": .kind, "metadata": {"name": "kromgo-listed"}, "spec": .spec}
    | .spec.targets.staticConfig.labels.hostname = "listed.${CLUSTER_DOMAIN}"' "$app/probe.yaml")" \
    yq -i '.spec.values.rawResources.listed.manifest.items += [env(PROBE)]' "$app/helmrelease.yaml"
  render "$TREE" "$copy-chart-list-probe"
  collect "$copy-chart-list-probe" "$fixture"
  [ "$(jq -r '[.[] | select(.kind == "Probe") | "\(.metadata.namespace)/\(.metadata.name)"] | sort | join(",")' "$fixture")" = \
    envoy-gateway-system/https-redirect,kromgo/kromgo,kromgo/kromgo-listed,kromgo/kromgo-unprobed ]
  run unprobed "$fixture"
  echo "a route and its Probe the chart renders in a List: $output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # The redirect without its Probe is refused too.
  copy_tree
  rm "$TREE/kubernetes/apps/base/envoy-gateway-system/gateway-public/app/probe.yaml"
  yq -i '.resources |= map(select(. != "probe.yaml"))' "$TREE/kubernetes/apps/base/envoy-gateway-system/gateway-public/app/kustomization.yaml"
  overlay_only gateway-public hello-route
  render "$TREE" "$copy-redirect"
  collect "$copy-redirect" "$fixture"
  run unprobed "$fixture"
  echo "$output"
  [[ $output == "HTTPRoute envoy-gateway-system/https-redirect: no Probe has the redirect on plain HTTP through "* ]]
  # A route on the https listener without hostnames inherits the listener's wildcard: refused.
  jq '(.[] | select(.kind == "HTTPRoute" and .metadata.name == "hello") | .spec) |= del(.hostnames)' "$objects" >"$fixture"
  run unprobed "$fixture"
  echo "$output"
  [[ $output == "HTTPRoute demo/hello: no hostnames, so it serves every name"* ]]
  # A Probe that names the hostname and the Service does not count unless the alerts select it, it
  # goes to the exporter, uses the module of its listener and sends the hostname on as it is: not
  # through a regex or a replacement of its own, not overwritten by a later relabeling, not with its
  # label rewritten first, and not with labels mapped or dropped or the target kept or dropped. Nor
  # does one that holds more than the fields that make it a probe: a path or a scheme of the prober,
  # which ask the exporter for something else than a probe, or over TLS it does not serve; an
  # interval, a scrape timeout or metric relabelings of its own, which can stretch the probe to once
  # a day, cut every scrape short or drop its series; discovered targets beside the static one; a
  # second target, which can leave the cluster; a label beside the hostname, which Prometheus can
  # read as a setting of the scrape; or a relabeling that writes another label than the parameter,
  # which can send the scrape or the probe elsewhere, or take it out of the job the alerts read.
  local refusal probe
  for refusal in \
    '.spec.jobName = "something-else"' \
    '.spec.prober.url = "nowhere:1"' \
    '.spec.module = "http_2xx"' \
    'del(.spec.targets.staticConfig.relabelingConfigs)' \
    '.spec.targets.staticConfig.relabelingConfigs[0].targetLabel = "__param_other"' \
    '.spec.targets.staticConfig.relabelingConfigs[0].sourceLabels = ["instance"]' \
    '.spec.targets.staticConfig.relabelingConfigs[0].regex = "([^.]+)\\..*"' \
    '.spec.targets.staticConfig.relabelingConfigs[0].replacement = "elsewhere.example.org"' \
    '.spec.targets.staticConfig.relabelingConfigs += [{"targetLabel": "__param_hostname", "replacement": "elsewhere.example.org"}]' \
    '.spec.targets.staticConfig.relabelingConfigs = [{"targetLabel": "hostname", "replacement": "elsewhere.example.org"}] + .spec.targets.staticConfig.relabelingConfigs' \
    '.spec.targets.staticConfig.relabelingConfigs += [{"action": "labeldrop", "regex": "__param_hostname"}]' \
    '.spec.targets.staticConfig.relabelingConfigs += [{"action": "Drop", "sourceLabels": ["hostname"], "regex": ".+"}]' \
    '.spec.prober.path = "/metrics"' \
    '.spec.prober.scheme = "https"' \
    '.spec.interval = "24h"' \
    '.spec.scrapeTimeout = "1s"' \
    '.spec.metricRelabelings = [{"action": "drop", "sourceLabels": ["__name__"], "regex": "probe_.*"}]' \
    '.spec.targets.ingress = {"namespaceSelector": {"any": true}}' \
    '.spec.targets.staticConfig.static += ["https://elsewhere.example.org/"]' \
    '.spec.targets.staticConfig.labels.__metrics_path__ = "/metrics"' \
    '.spec.targets.staticConfig.relabelingConfigs += [{"targetLabel": "__param_target", "replacement": "https://elsewhere.example.org/"}]' \
    '.spec.targets.staticConfig.relabelingConfigs += [{"targetLabel": "__address__", "replacement": "elsewhere.example.org:9115"}]' \
    '.spec.targets.staticConfig.relabelingConfigs += [{"targetLabel": "job", "replacement": "something-else"}]' \
    '.spec.targets.staticConfig.relabelingConfigs += [{"targetLabel": "__metrics_path__", "replacement": "/metrics"}]'; do
    for probe in hello https-redirect; do
      jq "(.[] | select(.kind == \"Probe\" and .metadata.name == \"$probe\")) |= ($refusal)" "$objects" >"$fixture"
      run unprobed "$fixture"
      echo "$probe $refusal: $output"
      [ "$(wc -l <<<"$output")" -eq 1 ]
      [[ $output == "HTTPRoute "*"/$probe: no Probe "* ]]
    done
  done
  # A route behind the cluster's sign-in, the target of a SecurityPolicy with external authorisation,
  # is probed for the redirect that starts a sign-in, and a probe of its host for 200 is refused: it
  # would pass only once the policy were lost and the backend answered anyone. The rule keys on
  # hostnames: hello-sso's sign-in paths, a route of the same host that no policy covers, are covered
  # by the one Probe of that host, and without it both routes are named, each with the host.
  jq 'map(select(.kind != "Probe" or .metadata.name != "hello-sso"))' "$objects" >"$fixture"
  run unprobed "$fixture"
  echo "$output"
  [ "$(wc -l <<<"$output")" -eq 2 ]
  [[ $output == *"HTTPRoute demo/hello-sso: no Probe over https through "*" expects the sign-in redirect for the hostname hello-sso.$DOMAIN"* ]]
  [[ $output == *"HTTPRoute demo/hello-sso-oauth2: no Probe over https through "*" expects the sign-in redirect for the hostname hello-sso.$DOMAIN"* ]]
  # The host behind sign-in probed for 200, in place of the redirect or beside it, is refused,
  # naming the Probe.
  jq '(.[] | select(.kind == "Probe" and .metadata.name == "hello-sso") | .spec.module) = "public_https"' "$objects" >"$fixture"
  run unprobed "$fixture"
  echo "$output"
  [ "$(wc -l <<<"$output")" -eq 3 ]
  [[ $output == *"Probe demo/hello-sso probes the hostname hello-sso.$DOMAIN for 200 with public_https, and an external-authorisation SecurityPolicy covers it"* ]]
  [[ $output == *"HTTPRoute demo/hello-sso: no Probe over https through "*" expects the sign-in redirect for the hostname hello-sso.$DOMAIN"* ]]
  jq '. + [.[] | select(.kind == "Probe" and .metadata.name == "hello-sso") | .metadata.name = "hello-sso-200" | .spec.module = "public_https"]' "$objects" >"$fixture"
  run unprobed "$fixture"
  echo "$output"
  [[ $output == "Probe demo/hello-sso-200 probes the hostname hello-sso.$DOMAIN for 200 with public_https, and an external-authorisation SecurityPolicy covers it"* ]]
  [ "$(wc -l <<<"$output")" -eq 1 ]
  # The policy written with the older single targetRef covers the route the same.
  jq '(.[] | select(.kind == "SecurityPolicy") | .spec) |= (.targetRef = .targetRefs[0] | del(.targetRefs))' "$objects" >"$fixture"
  run unprobed "$fixture"
  echo "$output"
  [ -z "$output" ]
  # A route that no such policy covers probed for the redirect is refused: hello's Probe expecting it,
  # and hello-sso's, the log store's and Locust's once the policies are gone or ask for no external
  # authorisation, when each host needs a Probe for 200.
  jq '(.[] | select(.kind == "Probe" and .metadata.name == "hello") | .spec.module) = "public_https_signin"' "$objects" >"$fixture"
  run unprobed "$fixture"
  echo "$output"
  [ "$(wc -l <<<"$output")" -eq 2 ]
  [[ $output == *"Probe demo/hello probes the hostname hello.$DOMAIN for the sign-in redirect with public_https_signin, and no external-authorisation SecurityPolicy covers it"* ]]
  [[ $output == *"HTTPRoute demo/hello: no Probe over https through "*" names the hostname hello.$DOMAIN"* ]]
  for refusal in 'map(select(.kind != "SecurityPolicy"))' '(.[] | select(.kind == "SecurityPolicy") | .spec) |= del(.extAuth)'; do
    jq "$refusal" "$objects" >"$fixture"
    run unprobed "$fixture"
    echo "$refusal: $output"
    [ "$(wc -l <<<"$output")" -eq 9 ]
    [[ $output == *"Probe demo/hello-sso probes the hostname hello-sso.$DOMAIN for the sign-in redirect with public_https_signin, and no external-authorisation SecurityPolicy covers it"* ]]
    [[ $output == *"HTTPRoute demo/hello-sso: no Probe over https through "*" names the hostname hello-sso.$DOMAIN"* ]]
    [[ $output == *"HTTPRoute demo/hello-sso-oauth2: no Probe over https through "*" names the hostname hello-sso.$DOMAIN"* ]]
    [[ $output == *"Probe monitoring/logs probes the hostname logs.$DOMAIN for the sign-in redirect with public_https_signin, and no external-authorisation SecurityPolicy covers it"* ]]
    [[ $output == *"HTTPRoute monitoring/logs: no Probe over https through "*" names the hostname logs.$DOMAIN"* ]]
    [[ $output == *"HTTPRoute monitoring/logs-oauth2: no Probe over https through "*" names the hostname logs.$DOMAIN"* ]]
    [[ $output == *"Probe locust/locust probes the hostname locust.$DOMAIN for the sign-in redirect with public_https_signin, and no external-authorisation SecurityPolicy covers it"* ]]
    [[ $output == *"HTTPRoute locust/locust: no Probe over https through "*" names the hostname locust.$DOMAIN"* ]]
    [[ $output == *"HTTPRoute locust/locust-oauth2: no Probe over https through "*" names the hostname locust.$DOMAIN"* ]]
  done
}

@test "A cluster that selects the probes without the exporter or the Gateway is refused" {
  local app dir problems fixture="$BATS_TEST_TMPDIR/fixture"
  # The tree as it is passes, with the exporter, the issuer, the Gateway and the routes listed, and
  # the twelve applications that declare a Probe name the exporter.
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  for app in blackbox-exporter cluster-ca gateway-public hello-route kromgo n8n open-webui dex oauth2-proxy hello-sso backstage victoria-logs-route ascender \
    locust-route; do
    [ "$(yq '.resources[] | select(test("/'"$app"'/ks.yaml$"))' "$REPO/kubernetes/apps/overlays/lab-sto2/kustomization.yaml")" ] \
      || { echo "the lab-sto2 overlay does not list $app"; return 1; }
  done
  # Every application of the cluster that holds a Probe, in what the cluster applies, names the
  # exporter, which is what makes a cluster that lists it without the exporter refused below. They
  # are these twelve, read from the render, which holds a Probe a chart makes as well.
  tree_render
  problems="$(probe_apps_without_exporter "$RENDER")"
  echo "$problems"
  [ -z "$problems" ]
  [ "$(for dir in "$RENDER"/lab-sto2/*/; do
      if compgen -G "${dir}Probe.monitoring.coreos.com_*.yaml" >/dev/null; then basename "$dir"; fi
    done | LC_ALL=C sort | paste -sd' ' -)" = "ascender backstage dex gateway-public hello-route hello-sso kromgo locust-route n8n oauth2-proxy open-webui victoria-logs-route" ]
  for app in gateway-public hello-route kromgo n8n open-webui dex oauth2-proxy hello-sso backstage victoria-logs-route ascender locust-route; do
    [ "$(yq '.spec.dependsOn[].name | select(. == "blackbox-exporter")' "$REPO"/kubernetes/apps/base/*/"$app"/ks.yaml)" = blackbox-exporter ]
  done
  # A Probe added to another application is refused, however its file spells the kind: hello with a
  # Probe among its manifests. And an application whose chart renders its Probe is held to the same:
  # kromgo with its Probe in its release's values, and without the exporter in its dependsOn.
  copy_tree
  app="$TREE/kubernetes/apps/base/demo/hello/app"
  printf -- '---\napiVersion: monitoring.coreos.com/v1\nkind: "Probe" # quoted, with a comment\nmetadata:\n  name: hello\n' >"$app/probe-fixture.yaml"
  yq -i '.resources += ["probe-fixture.yaml"]' "$app/kustomization.yaml"
  app="$TREE/kubernetes/apps/base/kromgo/kromgo"
  PROBE="$(yq -o json -I0 '{"apiVersion": .apiVersion, "kind": .kind, "spec": .spec}' "$app/app/probe.yaml")" \
    yq -i '.spec.values.rawResources.probe = {"suffix": "chart", "manifest": env(PROBE)}' "$app/app/helmrelease.yaml"
  yq -i '.resources |= map(select(. != "probe.yaml"))' "$app/app/kustomization.yaml"
  yq -i '.spec.dependsOn |= map(select(.name != "blackbox-exporter"))' "$app/ks.yaml"
  overlay_only hello kromgo
  render "$TREE" "$fixture"
  [ "$(yq '.metadata.labels["helm.toolkit.fluxcd.io/name"]' "$fixture"/lab-sto2/kromgo/Probe.monitoring.coreos.com__kromgo-chart.yaml)" = kromgo ]
  [ "$(find "$fixture/lab-sto2" -name 'Probe.*' | wc -l)" -eq 2 ]
  run probe_apps_without_exporter "$fixture"
  echo "$output"
  [ "$output" = "lab-sto2: the application hello declares a Probe and its Kustomization does not name blackbox-exporter in dependsOn
lab-sto2: the application kromgo declares a Probe and its Kustomization does not name blackbox-exporter in dependsOn" ]
  # With the exporter in kromgo's dependsOn again, hello alone is refused.
  yq -i '.spec.dependsOn += [{"name": "blackbox-exporter"}]' "$app/ks.yaml"
  render "$TREE" "$fixture-named"
  run probe_apps_without_exporter "$fixture-named"
  echo "$output"
  [ "$output" = "lab-sto2: the application hello declares a Probe and its Kustomization does not name blackbox-exporter in dependsOn" ]
  # Without the exporter all twelve are refused, each naming it and the overlay.
  tree_without blackbox-exporter
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"kubernetes/apps/base/demo/hello-route/ks.yaml: Kustomization hello-route names blackbox-exporter"* ]]
  [[ $output == *"kubernetes/apps/base/envoy-gateway-system/gateway-public/ks.yaml: Kustomization gateway-public names blackbox-exporter"* ]]
  [[ $output == *"kubernetes/apps/base/ai-system/n8n/ks.yaml: Kustomization n8n names blackbox-exporter"* ]]
  [[ $output == *"kubernetes/apps/base/kromgo/kromgo/ks.yaml: Kustomization kromgo names blackbox-exporter"* ]]
  [[ $output == *"kubernetes/apps/base/ai-system/open-webui/ks.yaml: Kustomization open-webui names blackbox-exporter"* ]]
  [[ $output == *"kubernetes/apps/base/sso-system/dex/ks.yaml: Kustomization dex names blackbox-exporter"* ]]
  [[ $output == *"kubernetes/apps/base/sso-system/oauth2-proxy/ks.yaml: Kustomization oauth2-proxy names blackbox-exporter"* ]]
  [[ $output == *"kubernetes/apps/base/demo/hello-sso/ks.yaml: Kustomization hello-sso names blackbox-exporter"* ]]
  [[ $output == *"kubernetes/apps/base/backstage/backstage/ks.yaml: Kustomization backstage names blackbox-exporter"* ]]
  [[ $output == *"kubernetes/apps/base/monitoring/victoria-logs-route/ks.yaml: Kustomization victoria-logs-route names blackbox-exporter"* ]]
  [[ $output == *"kubernetes/apps/base/ascender/ascender/ks.yaml: Kustomization ascender names blackbox-exporter"* ]]
  [[ $output == *"kubernetes/apps/base/locust/locust-route/ks.yaml: Kustomization locust-route names blackbox-exporter"* ]]
  [[ $output == *"apps/overlays/lab-sto2"* ]]
  [[ $output == *"does not enable"* ]]
  # Without the Gateway, and with the route that declares a Probe, the route is refused.
  tree_without gateway-public
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"kubernetes/apps/base/demo/hello-route/ks.yaml: Kustomization hello-route names gateway-public"* ]]
  [[ $output == *"apps/overlays/lab-sto2"* ]]
  [[ $output == *"does not enable"* ]]
  # Without the Gateway and what needs it, CrowdSec's reader of its access logs and CrowdSec, which
  # needs the reader, and external-dns's dashboard, which needs external-dns, among them, the
  # exporter alone builds: it probes nothing, and nothing alerts on that (ProbeNotRunning reads the
  # scrapes of declared Probes). Robot Framework's suite of Ascender's sign-in page, robot-ascender,
  # names ascender and goes with it.
  tree_without gateway-public hello-route n8n kromgo open-webui external-dns external-dns-dashboard hello-sso dex \
    oauth2-proxy backstage crowdsec-gateway-logs crowdsec victoria-logs-route ascender robot-ascender locust-route
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "The Gateway does not require the PROXY protocol header while the probes reach its listeners from inside the cluster" {
  local policy probes mutant="$BATS_TEST_TMPDIR/mutant" mutation
  tree_render
  policy="$(compgen -G "$RENDER/lab-sto2/gateway-public/ClientTrafficPolicy.gateway.envoyproxy.io_*.yaml")"
  echo "the Gateway's policy: $(yq -o json -I0 '.spec.proxyProtocol' "$policy")"
  probes="$(yq -N 'select(.kind == "Probe") | .metadata.namespace + "/" + .metadata.name' "$RENDER"/lab-sto2/*/Probe.monitoring.coreos.com_*.yaml |
    LC_ALL=C sort | sed -z 's/\n$//; s/\n/, /g')"
  echo "the Probes: $probes"
  [[ $probes == *demo/hello* && $probes == *envoy-gateway-system/https-redirect* ]]
  # The tree: every Probe reaches the listeners through the proxies' Service, and the policy takes the
  # header as optional.
  run header_problems "$RENDER"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(yq '.spec.proxyProtocol.optional' "$policy")" = true ]
  # A policy that requires the header is refused, naming it, the Gateway and every Probe it would cut:
  # proxyProtocol without optional, optional false, and the deprecated boolean.
  for mutation in 'del(.spec.proxyProtocol.optional)' '.spec.proxyProtocol.optional = false' \
    'del(.spec.proxyProtocol) | .spec.enableProxyProtocol = true'; do
    rm -rf "$mutant"
    cp -r "$RENDER" "$mutant"
    yq -i "$mutation" "$mutant/lab-sto2/gateway-public/${policy##*/}"
    run header_problems "$mutant"
    echo "$mutation: $output"
    [ "$status" -eq 0 ]
    [ "$(wc -l <<<"$output")" -eq 1 ]
    [[ $output == "lab-sto2: the ClientTrafficPolicy envoy-gateway-system/public requires the PROXY protocol header on the Gateway envoy-gateway-system/public, and the Probes $probes reach its listeners from inside the cluster through envoy-envoy-gateway-system-public-"*".envoy-gateway-system.svc.cluster.local without writing one: the probes would be cut" ]]
  done
  # The same with the Gateway and its policy in another namespace than the controller, whose
  # proxies' Service the controller makes in its own namespace and the Probes reach there.
  local moved
  moved="envoy-edge-public-$(printf edge/public | sha256sum | cut -c1-8).envoy-gateway-system.svc.cluster.local"
  rm -rf "$mutant"
  cp -r "$RENDER" "$mutant"
  yq -i '.metadata.namespace = "edge" | del(.spec.proxyProtocol.optional)' "$mutant/lab-sto2/gateway-public/${policy##*/}"
  yq -i '.metadata.namespace = "edge"' "$mutant"/lab-sto2/gateway-public/Gateway.gateway.networking.k8s.io_*.yaml
  MOVED="$moved" yq -i '.spec.targets.staticConfig.static[] |= sub("envoy-[a-z0-9-]+[.]envoy-gateway-system[.]svc[.]cluster[.]local"; strenv(MOVED))' \
    "$mutant"/lab-sto2/*/Probe.monitoring.coreos.com_*.yaml
  run header_problems "$mutant"
  echo "a Gateway in another namespace: $output"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<<"$output")" -eq 1 ]
  [ "$output" = "lab-sto2: the ClientTrafficPolicy edge/public requires the PROXY protocol header on the Gateway edge/public, and the Probes $probes reach its listeners from inside the cluster through $moved without writing one: the probes would be cut" ]
  # A policy that takes no header does not cut them.
  rm -rf "$mutant"
  cp -r "$RENDER" "$mutant"
  yq -i 'del(.spec.proxyProtocol)' "$mutant/lab-sto2/gateway-public/${policy##*/}"
  run header_problems "$mutant"
  echo "$output"
  [ -z "$output" ]
  # Nor does a requirement matter to the probes on a cluster whose Probes do not reach the listeners.
  rm -rf "$mutant"
  cp -r "$RENDER" "$mutant"
  yq -i 'del(.spec.proxyProtocol.optional)' "$mutant/lab-sto2/gateway-public/${policy##*/}"
  rm "$mutant"/lab-sto2/*/Probe.monitoring.coreos.com_*.yaml
  run header_problems "$mutant"
  echo "$output"
  [ -z "$output" ]
}

@test "the exporter runs two replicas at the restricted level, trusts only the public certificate and is scraped" {
  local rendered deployment
  render_chart "$REPO/$APP_DIR/app/values.yaml" "$REPO/$APP_DIR/app/trust/cluster-ca.yaml"
  rendered="$RENDERED"
  # Every object of the release is of a kind the chart makes for the exporter and its monitor.
  [ "$(yq -N '.kind' "$rendered" | sort | paste -sd' ' -)" = "ConfigMap Deployment PodDisruptionBudget Service ServiceAccount ServiceMonitor" ]
  deployment="$(yq -N -o json -I0 'select(.kind == "Deployment")' "$rendered")"
  echo "$deployment"
  [ "$(jq '.spec.replicas' <<<"$deployment")" -eq 2 ]
  [ "$(jq -r '.metadata.name' <<<"$deployment")" = blackbox-exporter ]
  # Restricted: non-root, no escalation, every capability dropped, the runtime's seccomp profile.
  [ "$(jq -c '.spec.template.spec.containers[0].securityContext | [.runAsNonRoot, .allowPrivilegeEscalation, .capabilities.drop, .readOnlyRootFilesystem]' <<<"$deployment")" = '[true,false,["ALL"],true]' ]
  [ "$(jq -r '.spec.template.spec.securityContext.seccompProfile.type' <<<"$deployment")" = RuntimeDefault ]
  # Requests, and two replicas that never share a worker, under a budget that keeps one.
  [ "$(jq -r '.spec.template.spec.containers[0].resources.requests | .cpu + " " + .memory' <<<"$deployment")" != " " ]
  [ "$(jq '.spec.template.spec.topologySpreadConstraints | map(select(.topologyKey == "kubernetes.io/hostname" and .whenUnsatisfiable == "DoNotSchedule" and .maxSkew == 1)) | length' <<<"$deployment")" -eq 1 ]
  [ "$(yq -N 'select(.kind == "PodDisruptionBudget") | .spec.maxUnavailable' "$rendered")" -eq 1 ]
  # With the cluster's own CA, the private key of the Secret is not in the pod: the volume holds the
  # one key, mounted as a file.
  [ "$(jq -c '.spec.template.spec.volumes[] | select(.secret != null) | .secret.items' <<<"$deployment")" = '[{"key":"ca.crt","path":"ca.crt"}]' ]
  [ "$(jq -c '[.spec.template.spec.containers[0].volumeMounts[] | select(.mountPath != "/config")] | map(.readOnly // false)' <<<"$deployment")" = '[true]' ]
  # With either ACME issuer the pod holds no Secret and mounts nothing but its configuration.
  local issuer
  for issuer in letsencrypt-production letsencrypt-staging; do
    render_chart "$REPO/$APP_DIR/app/values.yaml" "$REPO/$APP_DIR/app/trust/$issuer.yaml"
    deployment="$(yq -N -o json -I0 'select(.kind == "Deployment")' "$RENDERED")"
    [ "$(jq '[.spec.template.spec.volumes[]? | select(.secret != null)] | length' <<<"$deployment")" -eq 0 ]
    [ "$(jq -c '[.spec.template.spec.containers[0].volumeMounts[]?.mountPath]' <<<"$deployment")" = '["/config"]' ]
  done
  # The exporter's own metrics are scraped, and the modules are in its configuration.
  [ "$(yq -N 'select(.kind == "ServiceMonitor") | .spec.endpoints | length' "$rendered")" -eq 1 ]
  [ "$(yq -N 'select(.kind == "ConfigMap") | .data["blackbox.yaml"]' "$rendered" | yq -o json -I0 '.modules | keys | sort' -)" = "$PROBE_MODULES" ]
}
