#!/usr/bin/env bats
# Proves features/waf.feature, but for its scenario of the firewall's flows, which
# tests/network-policy.bats proves; each test carries its scenario's title.
# Needs kustomize, flux, helm, yq, jq, kyverno, curl and sha256sum on PATH (the versions pinned for
# the repository). Building is offline, with the placeholders of the cluster's example key lists;
# the render of the tree pulls its charts from their public registries, and the filter's image is
# read from its public registry, anonymously, as the other tests pull public charts. What only a
# running Gateway can show, the controller fetching the module and the proxies refusing a request,
# is not proved here (docs/kubernetes.md, Web application firewall).

# flux build rewrites the kustomization.yaml of what it builds and puts it back afterwards: so the
# tests run one at a time.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLUSTER="$REPO/kubernetes/clusters/lab-sto2"
  COMPONENT="$REPO/kubernetes/components/waf"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  EXAMPLE="$BATS_TEST_TMPDIR/example-vars.yaml"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$EXAMPLE"
  # The configuration the filter is given for a mode: the filter's recommended configuration, which
  # sets the rule engine to DetectionOnly and the audit engine off, then the route's mode over it,
  # then the Core Rule Set's setup and every rule file of the set, at their defaults.
  # shellcheck disable=SC2016 # $mode is a jq variable.
  DIRECTIVES='["Include @recommended-conf", "SecRuleEngine \($mode)", "Include @crs-setup-conf", "Include @owasp_crs/*.conf"]'
  # The policy's acceptance, as a route that takes the component holds it as its health: current
  # while every ancestor accepts the policy at its generation, failed once one refuses it.
  CURRENT="has(status.ancestors) && size(status.ancestors) > 0 && status.ancestors.all(a, a.conditions.exists(c, c.type == 'Accepted' && c.status == 'True' && c.observedGeneration == metadata.generation))"
  FAILED="has(status.ancestors) && status.ancestors.exists(a, a.conditions.exists(c, c.type == 'Accepted' && c.status == 'False' && c.observedGeneration == metadata.generation))"
}

# overlay [TREE]: the lab-sto2 overlay of TREE, the repository by default, as Flux reads it, its
# namespaces and the Kustomization of each enabled application. Writes $OVERLAY.
overlay() {
  OVERLAY="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "${1:-$REPO}/kubernetes/apps/overlays/lab-sto2" >"$OVERLAY"
}

# build_from_overlay APP [TREE]: the objects the overlay's Kustomization of APP applies, built from
# TREE, the repository by default, offline with the example key lists and its own substitutions,
# strictly.
build_from_overlay() {
  local ks="$BATS_TEST_TMPDIR/overlay-$1-ks.yaml" path tree=${2:-$REPO}
  # shellcheck disable=SC2016 # $vars is a yq variable.
  NAME="$1" yq ea 'select(fileIndex == 0) as $vars
    | select(fileIndex == 1 and .kind == "Kustomization" and .metadata.name == strenv(NAME))
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "$EXAMPLE" "$OVERLAY" >"$ks"
  [ -s "$ks" ] || { echo "the lab-sto2 overlay does not enable $1"; return 1; }
  path="$(yq '.spec.path' "$ks")"
  (cd "$tree" && flux build kustomization "$1" --path "./kubernetes/${path#./}" \
    --kustomization-file "$ks" --dry-run --strict-substitute)
}

# built APP [TREE]: the application APP as Flux applies it on lab-sto2. Writes
# $BATS_TEST_TMPDIR/APP-built.yaml and sets BUILT.
built() {
  overlay "${2:-}"
  BUILT="$BATS_TEST_TMPDIR/$1-built.yaml"
  build_from_overlay "$1" "${2:-}" >"$BUILT"
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

# only FILE KIND: the name of the one object of that kind in FILE; fails, saying so, unless there is
# exactly one.
only() {
  local names count=0
  names="$(KIND="$2" yq -N 'select(.kind == strenv(KIND)) | .metadata.name' "$1")"
  [ -z "$names" ] || count="$(wc -l <<<"$names")"
  [ "$count" -eq 1 ] || { echo "$1 holds $count $2 objects: ${names:-none}"; return 1; }
  echo "$names"
}

# object FILE KIND NAME: the one object of that kind and name in FILE.
object() {
  KIND="$2" NAME="$3" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$1"
}

# built_own KS: the application of the ks.yaml KS, relative to the repository, as its own file has
# it, with no patch of any overlay, built with the example key lists and its own substitutions,
# strictly. Writes $BATS_TEST_TMPDIR/own.yaml and sets BUILT.
built_own() {
  local ks="$BATS_TEST_TMPDIR/own-ks.yaml" name path
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "$EXAMPLE" "$REPO/$1" >"$ks"
  name="$(yq '.metadata.name' "$ks")" path="$(yq '.spec.path' "$ks")"
  BUILT="$BATS_TEST_TMPDIR/own.yaml"
  (cd "$REPO" && flux build kustomization "$name" --path "./kubernetes/${path#./}" \
    --kustomization-file "$ks" --dry-run --strict-substitute) >"$BUILT"
}

# header: the ks.yaml block the component's header shows, as YAML.
header() {
  sed -n '/^#   components:$/,/^#$/p' "$COMPONENT/kustomization.yaml" | sed -e '/^#$/d' -e 's/^#   //'
}

# takers FILE...: each Flux Kustomization of FILE... that takes the component, as its file, name,
# target namespace and WAF_ROUTE, a tab between each, one a line. It takes the component when one of
# its components, resolved from its spec.path as Flux resolves it, is the component's directory,
# however the path is written: quoted or not, with a trailing slash, through ./ or ../.
takers() {
  local own file name namespace route path component
  own="$(realpath -m -- "$COMPONENT")"
  # shellcheck disable=SC2016 # $k is a yq variable.
  yq -N 'select(.kind == "Kustomization") | . as $k | (.spec.components // [])[]
    | [filename, $k.metadata.name, ($k.spec.targetNamespace // $k.metadata.namespace // ""),
       ($k.spec.postBuild.substitute.WAF_ROUTE // ""), ($k.spec.path // "."), .] | @tsv' "$@" |
    while IFS=$'\t' read -r file name namespace route path component; do
      [ "$(realpath -m -- "$REPO/kubernetes/${path#./}/$component")" = "$own" ] || continue
      printf '%s\t%s\t%s\t%s\n' "$file" "$name" "$namespace" "$route"
    done
}

# taking: the ks.yaml of every application of the tree that takes the component, one per line,
# relative to the repository, whether an overlay enables it or not.
taking() {
  local files
  mapfile -t files < <(cd "$REPO" && find kubernetes -type f -name ks.yaml | sort)
  (cd "$REPO" && takers "${files[@]}") | cut -f1 | sort -u
}

# rendered: what the clusters apply, as scripts/render renders it: every Kustomization built as Flux
# builds it, and the chart of each HelmRelease, pulled from its public registry, rendered as
# helm-controller renders it, one object a file under $RENDER/<cluster>/<application>/. Writes every
# object of it, one JSON line each, to $RENDERED.
rendered() {
  RENDER="$BATS_TEST_TMPDIR/render"
  "$REPO/scripts/render" "$RENDER" >/dev/null
  RENDERED="$BATS_TEST_TMPDIR/rendered.jsonl"
  find "$RENDER" -type f -name '*.yaml' -print0 | sort -z | xargs -0 -r yq -N -o json -I0 '.' >"$RENDERED"
  [ -s "$RENDERED" ]
}

# registry PATH [ACCEPT]: the answer of the filter image's registry to an anonymous GET of the
# repository's PATH under /v2/, with the token the registry hands anyone for a pull. Writes the body
# to $BATS_TEST_TMPDIR/answer and its media type to $BATS_TEST_TMPDIR/answer.type.
registry() {
  local token
  token="$(curl --disable --silent --show-error --fail --max-time 30 \
    "https://$REGISTRY/token?scope=repository:$REPOSITORY:pull" | jq -er .token)"
  curl --disable --silent --show-error --fail --max-time 60 -H "Authorization: Bearer $token" \
    -H "Accept: ${2:-application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json}" \
    -o "$BATS_TEST_TMPDIR/answer" -w '%{content_type}' "https://$REGISTRY/v2/$REPOSITORY/$1" >"$BATS_TEST_TMPDIR/answer.type"
}

@test "A route opts into the web application firewall with one component, and no policy puts it on the Gateway as a whole" {
  local policy="$COMPONENT/envoyextensionpolicy.yaml" targets expected found allowed named files
  [ -f "$COMPONENT/kustomization.yaml" ] || { echo "there is no component kubernetes/components/waf"; return 1; }
  # A Component of one EnvoyExtensionPolicy and nothing else.
  [ "$(yq '.kind' "$COMPONENT/kustomization.yaml")" = Component ]
  [ "$(yq -o json -I0 'keys' "$COMPONENT/kustomization.yaml")" = '["apiVersion","kind","resources"]' ]
  [ "$(yq -o json -I0 '.resources' "$COMPONENT/kustomization.yaml")" = '["envoyextensionpolicy.yaml"]' ]
  [ "$(find "$COMPONENT" -type f | sort | sed "s|^$COMPONENT/||" | paste -sd' ' -)" = "envoyextensionpolicy.yaml kustomization.yaml" ]
  # Its two variables and no other, neither with a default: Flux would substitute a default where
  # the route sets none.
  # shellcheck disable=SC2016 # What the files hold is a ${NAME} reference, not for the shell to expand.
  [ "$(grep -rhoE '\$\{[^}]*\}?' "$COMPONENT" | sort -u | paste -sd' ' -)" = '${WAF_MODE} ${WAF_ROUTE}' ]
  # The header documents both, as components/sso's documents its own.
  grep -qE '^#   WAF_ROUTE +[^ ]' "$COMPONENT/kustomization.yaml"
  grep -qE '^#   WAF_MODE +[^ ]' "$COMPONENT/kustomization.yaml"
  # The policy is named after the route and targets that one HTTPRoute of the Gateway API, by name,
  # in its own namespace: no target selector, which could select a Gateway by its labels, no merge
  # with a Gateway's policy, and no namespace anywhere in it.
  [ "$(yq -N '.kind' "$policy" | paste -sd' ' -)" = EnvoyExtensionPolicy ]
  [ "$(yq '.apiVersion' "$policy")" = gateway.envoyproxy.io/v1alpha1 ]
  # shellcheck disable=SC2016 # As above.
  [ "$(yq -o json -I0 '.metadata' "$policy")" = '{"name":"${WAF_ROUTE}"}' ]
  [ "$(yq -o json -I0 '.spec | keys' "$policy")" = '["targetRefs","wasm"]' ]
  # shellcheck disable=SC2016 # As above.
  [ "$(yq -o json -I0 '.spec.targetRefs' "$policy" | jq -cS .)" = '[{"group":"gateway.networking.k8s.io","kind":"HTTPRoute","name":"${WAF_ROUTE}"}]' ]
  [ "$(yq '[.. | select(tag == "!!map" and has("namespace"))] | length' "$policy")" -eq 0 ]
  # The tree holds no other EnvoyExtensionPolicy, no EnvoyPatchPolicy, which rewrites a Gateway's
  # translated configuration whatever the policies say, and no Wasm module an EnvoyProxy registers
  # for its proxies, in any file under kubernetes/, whether an overlay enables it or not.
  (cd "$REPO" && find kubernetes -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z |
    xargs -0 yq -N 'select(.kind == "EnvoyExtensionPolicy" or .kind == "EnvoyPatchPolicy") | filename + " " + .kind') >"$BATS_TEST_TMPDIR/files"
  [ "$(cat "$BATS_TEST_TMPDIR/files")" = "kubernetes/components/waf/envoyextensionpolicy.yaml EnvoyExtensionPolicy" ] \
    || { echo "files of these kinds: $(cat "$BATS_TEST_TMPDIR/files")"; return 1; }
  [ -z "$(cd "$REPO" && grep -rl 'wasmModules' kubernetes || true)" ]
  # What the cluster applies, with what the charts of its HelmReleases render, a chart's extra
  # objects from its values among it. None of it is of two forms the render does not expand as the
  # cluster would, where the checks below would not see an object: no List with items, whose items
  # Flux applies as objects of their own, and no Flux object a chart renders, which scripts/render
  # does not follow.
  overlay
  rendered
  # shellcheck disable=SC2016 # $o and $id are jq variables.
  jq -r 'objects | . as $o | "\(.kind)/\(.metadata.namespace // "")/\(.metadata.name // "")" as $id
    | (select((.kind // "" | endswith("List")) and has("items")) | "\($id): a List with items, which the render holds as one object"),
      (select((.metadata.labels // {} | has("helm.toolkit.fluxcd.io/name"))
          and (.apiVersion // "" | test("^(kustomize|helm|source)\\.toolkit\\.fluxcd\\.io/|^source\\.extensions\\.fluxcd\\.io/")))
        | "\($id): a Flux object the chart of HelmRelease \($o.metadata.labels["helm.toolkit.fluxcd.io/namespace"])/\($o.metadata.labels["helm.toolkit.fluxcd.io/name"]) renders, which the render does not follow")' \
    "$RENDERED" >"$BATS_TEST_TMPDIR/unexpanded"
  [ ! -s "$BATS_TEST_TMPDIR/unexpanded" ] || { cat "$BATS_TEST_TMPDIR/unexpanded"; return 1; }
  # Its EnvoyExtensionPolicy and EnvoyPatchPolicy objects are the component's alone, one for each
  # Kustomization of the overlay that takes it, named after its route in its target namespace.
  expected="$(takers "$OVERLAY" | while IFS=$'\t' read -r _ name namespace route; do
    echo "${CLUSTER##*/}/$name/EnvoyExtensionPolicy.gateway.envoyproxy.io_${namespace}_$route.yaml"
  done | sort)"
  found="$(cd "$RENDER" && find . -type f \( -name 'EnvoyExtensionPolicy[._]*' -o -name 'EnvoyPatchPolicy[._]*' \) | sed 's|^\./||' | sort)"
  [ "$found" = "$expected" ] || { echo "policies of these kinds in the render: $(paste -sd' ' - <<<"${found:-none}"); the component's: $(paste -sd' ' - <<<"${expected:-none}")"; return 1; }
  # Of all of it: every EnvoyExtensionPolicy targets HTTPRoutes alone, of its own namespace, that the
  # render holds; no object of any kind with a Wasm extension targets a Gateway or a ListenerSet or
  # selects its targets; no EnvoyProxy registers a module; no EnvoyPatchPolicy.
  # shellcheck disable=SC2016 # $all, $p, $own and $t are jq variables.
  jq -rs '
    [.[] | objects] as $all
    | $all[] | select(.kind == "EnvoyExtensionPolicy") | . as $p | .metadata.namespace as $own
    | if (.spec | has("targetRef") or has("targetSelectors") or has("mergeType")) or ((.spec.targetRefs // []) | length) == 0 then
        "\($own)/\(.metadata.name): targets other than by targetRefs"
      else .spec.targetRefs[] | . as $t
        | if .group != "gateway.networking.k8s.io" or .kind != "HTTPRoute" or has("namespace") then
            "\($own)/\($p.metadata.name): targets \(tojson)"
          elif ([$all[] | select(.kind == "HTTPRoute" and .metadata.namespace == $own and .metadata.name == $t.name)] | length) != 1 then
            "\($own)/\($p.metadata.name): targets \($t.name), which is no HTTPRoute of its namespace"
          else empty end
      end' "$RENDERED" >"$BATS_TEST_TMPDIR/wrong"
  [ ! -s "$BATS_TEST_TMPDIR/wrong" ] || { cat "$BATS_TEST_TMPDIR/wrong"; return 1; }
  # shellcheck disable=SC2016 # $o is a jq variable.
  jq -rs '
    .[] | objects | . as $o | select((.spec.wasm // []) | length > 0)
    | select(any(([.spec.targetRef // empty] + (.spec.targetRefs // []))[]; .kind == "Gateway" or .kind == "ListenerSet")
        or ((.spec.targetSelectors // []) | length > 0))
    | "\($o.kind)/\($o.metadata.namespace)/\($o.metadata.name)"' "$RENDERED" >"$BATS_TEST_TMPDIR/gateway-wide"
  [ ! -s "$BATS_TEST_TMPDIR/gateway-wide" ] || { echo "Wasm on a Gateway or a ListenerSet: $(cat "$BATS_TEST_TMPDIR/gateway-wide")"; return 1; }
  [ -n "$(jq -r 'select(.kind == "EnvoyProxy") | .metadata.name' "$RENDERED")" ]
  [ -z "$(jq -r 'select(.kind == "EnvoyProxy" and .spec.wasmModules != null) | .metadata.name' "$RENDERED")" ]
  [ -z "$(jq -r 'select(.kind == "EnvoyPatchPolicy") | .metadata.name' "$RENDERED")" ]
  # Nor does any object of it name either kind or its resource, in any field or string, or have a
  # key Wasm modules are given under, but the component's policies, the Kustomizations that take the
  # component, whose health reads the policy, and the controller's own ClusterRole, with which it
  # watches the policies. That is a reading of text: what an admission controller mutates or
  # generates at run time, and what a role lets write, are outside it (docs/kubernetes.md, Putting a
  # route behind the firewall).
  mapfile -t files < <(cd "$RENDER" && find . -type f -name 'Kustomization.kustomize.toolkit.fluxcd.io_*' | sort)
  [ "${#files[@]}" -gt 0 ]
  allowed="$( {
    echo "$expected"
    (cd "$RENDER" && takers "${files[@]}") | cut -f1 | sed 's|^\./||'
    echo "${CLUSTER##*/}/envoy-gateway/ClusterRole.rbac.authorization.k8s.io__envoy-gateway-gateway-helm-envoy-gateway-role.yaml"
  } | grep . | sort -u)"
  named="$(cd "$RENDER" && {
    grep -rliE 'envoy(extension|patch)polic(y|ies)|wasmmodules' . || true
    find . -type f -name '*.yaml' -print0 | sort -z |
      xargs -0 -r yq -N 'select([.. | select(tag == "!!map") | keys | .[] | select(. == "wasm" or . == "wasmModules")] | length > 0) | filename'
  } | sed 's|^\./||' | sort -u)"
  [ "$named" = "$allowed" ] || { echo "objects that name the policies or a Wasm key: $(paste -sd' ' - <<<"${named:-none}"); those that may: $(paste -sd' ' - <<<"$allowed")"; return 1; }
  # The routes behind the firewall: the demo's hello, and no other.
  targets="$(jq -r 'select(.kind == "EnvoyExtensionPolicy" and (.spec.wasm // []) != []) | .metadata.namespace + "/" + (.spec.targetRefs // [])[].name' "$RENDERED" | sort -u | paste -sd' ' -)"
  echo "routes behind the firewall: ${targets:-none}"
  [ "$targets" = demo/hello ]
  # The demo route takes the component, beside its rate limit's, and hello-sso, a second hostname on
  # the same backend, does not: no EnvoyExtensionPolicy of its own, and no other, targets it.
  overlay
  [ "$(yq -N -o json -I0 'select(.kind == "Kustomization" and .metadata.name == "hello-route") | .spec.components' "$OVERLAY")" = '["../../../../../components/waf","../../../../../components/ratelimit"]' ]
  [ "$(taking)" = kubernetes/apps/base/demo/hello-route/ks.yaml ] || { echo "the ks.yaml that take the component: $(taking | paste -sd' ' -)"; return 1; }
  built hello-sso
  [ -z "$(yq -N 'select(.kind == "EnvoyExtensionPolicy") | .metadata.name' "$BUILT")" ]
  [ "$(yq -N 'select(.kind == "HTTPRoute" and .metadata.name == "hello-sso") | .spec.rules[].backendRefs[].name' "$BUILT")" = hello ]
  [ "$(jq -r 'select(.kind == "HTTPRoute" and .metadata.namespace == "demo" and .metadata.name == "hello") | .spec.rules[].backendRefs[].name' "$RENDERED")" = hello ]
  [ -z "$(jq -r 'select(.kind == "EnvoyExtensionPolicy" and .metadata.namespace == "demo") | select(any((.spec.targetRefs // [])[]; .name == "hello-sso")) | .metadata.name' "$RENDERED")" ]
}

@test "The firewall is Coraza with the Core Rule Set at its defaults, from an image pinned by tag and the digest the controller checks, and it fails open" {
  local policy entry url tag digest index_digest pinned
  built hello-route
  policy="$(only "$BUILT" EnvoyExtensionPolicy)" || { echo "the demo route: $policy"; return 1; }
  [ "$policy" = hello ]
  entry="$BATS_TEST_TMPDIR/entry.json"
  object "$BUILT" EnvoyExtensionPolicy hello | yq -o json -I0 '.spec.wasm' >"$BATS_TEST_TMPDIR/wasm.json"
  echo "wasm: $(cat "$BATS_TEST_TMPDIR/wasm.json")"
  [ "$(jq length "$BATS_TEST_TMPDIR/wasm.json")" -eq 1 ]
  jq -c '.[0]' "$BATS_TEST_TMPDIR/wasm.json" >"$entry"
  # One entry, coraza, failing open, with no field beyond its source and its configuration: no
  # checksum, pull policy or pull secret, no VM or root of its own, no environment of the host.
  [ "$(jq -c 'keys' "$entry")" = '["code","config","failOpen","name"]' ]
  [ "$(jq -r .name "$entry")" = coraza ]
  [ "$(jq -c .failOpen "$entry")" = true ]
  # An Image source by tag and digest: the controller compares the digest of the image manifest it
  # resolves with the digest in the URL, as the entry has no sha256 of its own.
  url="$(jq -r '.code.image.url' "$entry")"
  [ "$(jq -cS .code "$entry")" = "$(jq -cnS --arg url "$url" '{type: "Image", image: {url: $url}}')" ]
  [[ $url =~ ^ghcr\.io/corazawaf/coraza-proxy-wasm:([0-9]+\.[0-9]+\.[0-9]+)@(sha256:[0-9a-f]{64})$ ]] \
    || { echo "the image is not ghcr.io/corazawaf/coraza-proxy-wasm by a release tag and a digest: $url"; return 1; }
  tag=${BASH_REMATCH[1]} digest=${BASH_REMATCH[2]}
  # Renovate's custom manager reads the tag and the digest from the line under its comment.
  pinned="$(grep -B1 -F "url: $url" "$COMPONENT/envoyextensionpolicy.yaml" | head -n 1 | sed 's/^[[:space:]]*//')"
  [ "$pinned" = "# renovate: datasource=docker depName=ghcr.io/corazawaf/coraza-proxy-wasm" ]
  # The Core Rule Set at its defaults: the recommended configuration, the mode, the set's setup and
  # all of its rule files, and nothing else, for the demo route in blocking mode.
  [ "$(jq -cS .config "$entry")" = "$(jq -cnS --arg mode On "{directives_map: {default: $DIRECTIVES}, default_directives: \"default\"}")" ]
  # No policy the overlay applies tunes the set: no rule, action, variable, paranoia level,
  # threshold, exclusion, removal, control or audit setting of its own.
  everything
  yq -N -o json -I0 'select(.kind == "EnvoyExtensionPolicy") | .spec.wasm[].config' "$EVERYTHING" >"$BATS_TEST_TMPDIR/configs"
  [ -s "$BATS_TEST_TMPDIR/configs" ]
  [ -z "$(jq -r '.directives_map[][]' "$BATS_TEST_TMPDIR/configs" | grep -vE '^(Include @recommended-conf|SecRuleEngine (On|DetectionOnly)|Include @crs-setup-conf|Include @owasp_crs/\*\.conf)$' || true)" ]
  [ "$(jq -c 'keys' "$BATS_TEST_TMPDIR/configs" | sort -u)" = '["default_directives","directives_map"]' ]
  # The registry: the tag's index lists the pinned digest for linux/amd64, as an image manifest, and
  # the index's own digest is another, which the controller would refuse; that manifest is the one
  # whose bytes have the digest, an OCI image with one gzipped tar layer, the layer the controller
  # extracts plugin.wasm from.
  REGISTRY=ghcr.io REPOSITORY=corazawaf/coraza-proxy-wasm
  registry "manifests/$tag"
  echo "the index of $tag: $(cat "$BATS_TEST_TMPDIR/answer.type") $(jq -c '[.manifests[] | {digest, mediaType, platform}]' "$BATS_TEST_TMPDIR/answer")"
  [ "$(cat "$BATS_TEST_TMPDIR/answer.type")" = application/vnd.oci.image.index.v1+json ]
  index_digest="sha256:$(sha256sum <"$BATS_TEST_TMPDIR/answer" | cut -d' ' -f1)"
  [ "$index_digest" != "$digest" ] || { echo "the pin is the digest of the index, which the controller refuses as a checksum mismatch"; return 1; }
  [ "$(D="$digest" jq -r '[.manifests[] | select(.digest == env.D)] | length' "$BATS_TEST_TMPDIR/answer")" -eq 1 ] \
    || { echo "the index of $tag does not list $digest"; return 1; }
  [ "$(D="$digest" jq -c '.manifests[] | select(.digest == env.D) | [.mediaType, .platform.os, .platform.architecture]' "$BATS_TEST_TMPDIR/answer")" \
    = '["application/vnd.oci.image.manifest.v1+json","linux","amd64"]' ] \
    || { echo "$digest is not the index's linux/amd64 image manifest"; return 1; }
  registry "manifests/$digest" 'application/vnd.oci.image.manifest.v1+json'
  [ "sha256:$(sha256sum <"$BATS_TEST_TMPDIR/answer" | cut -d' ' -f1)" = "$digest" ]
  [ "$(cat "$BATS_TEST_TMPDIR/answer.type")" = application/vnd.oci.image.manifest.v1+json ]
  [ "$(jq -r .mediaType "$BATS_TEST_TMPDIR/answer")" = application/vnd.oci.image.manifest.v1+json ]
  [ "$(jq -c '[.layers[].mediaType]' "$BATS_TEST_TMPDIR/answer")" = '["application/vnd.oci.image.layer.v1.tar+gzip"]' ]
}

@test "The demo route's firewall blocks, a route may choose detection only, and a route's health shows whether its firewall was accepted" {
  local file ks mode route tree health cel verdicts
  # The demo route takes it in blocking mode and waits on gateway-public, whose chain brings the
  # policy's definition through envoy-gateway and envoy-gateway-crds, on hello, and on the blackbox
  # exporter its Probe needs.
  overlay
  yq -N 'select(.kind == "Kustomization" and .metadata.name == "hello-route")' "$OVERLAY" >"$BATS_TEST_TMPDIR/ks.yaml"
  echo "hello-route: $(yq -o json -I0 '.spec' "$BATS_TEST_TMPDIR/ks.yaml")"
  [ "$(yq -o json -I0 '.spec.postBuild.substitute' "$BATS_TEST_TMPDIR/ks.yaml" | jq -cS .)" = '{"RATELIMIT_REQUESTS":"5","RATELIMIT_ROUTE":"hello","RATELIMIT_UNIT":"Second","WAF_MODE":"On","WAF_ROUTE":"hello"}' ]
  [ "$(yq '.spec.dependsOn | map(.name) | sort | join(" ")' "$BATS_TEST_TMPDIR/ks.yaml")" = "blackbox-exporter gateway-public hello" ]
  # Every application that takes the component, enabled or not, names its route and one of the two
  # modes, waits, and holds the policy's acceptance as its health: with failOpen the route keeps
  # serving when the module cannot be had, so the leading controller replica's failure to fetch it
  # shows as the Kustomization not Ready.
  # The component's header gives the expressions a route that takes it carries.
  health="$(jq -cnS --arg current "$CURRENT" --arg failed "$FAILED" '[{apiVersion: "gateway.envoyproxy.io/v1alpha1", kind: "EnvoyExtensionPolicy", current: $current, failed: $failed}]')"
  [ "$(header | yq -o json -I0 '.healthCheckExprs' | jq -cS .)" = "$health" ] \
    || { echo "the component's header gives other health expressions: $(header | yq -o json -I0 '.healthCheckExprs')"; return 1; }
  [ "$(header | yq '.wait')" = true ]
  # The expressions do what they say, evaluated by the pinned Kyverno's CEL against statuses of the
  # shape the controller writes, a Gateway API PolicyStatus with an Accepted condition for each
  # ancestor: current while every ancestor accepts the policy at its generation, failed once one
  # refuses it at its generation, and neither without an ancestor or while a condition is of an
  # earlier generation. Flux gives an expression the object's top-level fields as its variables,
  # where a ValidatingAdmissionPolicy gives it the object as object, so each is evaluated with
  # object. before those. The definition only maps the kind to its resource and takes any field.
  cel="$BATS_TEST_TMPDIR/cel"
  mkdir -p "$cel"
  # shellcheck disable=SC2016 # What jq reads is a jq program.
  jq -nc --arg current "$CURRENT" --arg failed "$FAILED" '
    def policy($name; $expr): {apiVersion: "admissionregistration.k8s.io/v1", kind: "ValidatingAdmissionPolicy",
      metadata: {name: $name}, spec: {failurePolicy: "Fail",
        matchConstraints: {resourceRules: [{apiGroups: ["gateway.envoyproxy.io"], apiVersions: ["v1alpha1"],
          operations: ["CREATE", "UPDATE"], resources: ["envoyextensionpolicies"]}]},
        validations: [{expression: ($expr | gsub("(?<p>^|[^.\\w])(?<v>status|metadata)\\."; "\(.p)object.\(.v)."))}]}};
    policy("current"; $current), policy("failed"; $failed)' | sed 's/^/---\n/' >"$cel/policies.yaml"
  jq -nc '{apiVersion: "apiextensions.k8s.io/v1", kind: "CustomResourceDefinition",
    metadata: {name: "envoyextensionpolicies.gateway.envoyproxy.io"},
    spec: {group: "gateway.envoyproxy.io", scope: "Namespaced",
      names: {kind: "EnvoyExtensionPolicy", listKind: "EnvoyExtensionPolicyList", plural: "envoyextensionpolicies", singular: "envoyextensionpolicy"},
      versions: [{name: "v1alpha1", served: true, storage: true,
        schema: {openAPIV3Schema: {type: "object", "x-kubernetes-preserve-unknown-fields": true}}}]}}' >"$cel/definition.yaml"
  # shellcheck disable=SC2016 # As above.
  jq -nc '
    def accepted($status; $generation): {type: "Accepted", status: $status, reason: "Accepted", message: "",
      observedGeneration: $generation, lastTransitionTime: "2026-01-01T00:00:00Z"};
    def ancestor($listener; $condition): {ancestorRef: {group: "gateway.networking.k8s.io", kind: "Gateway",
      namespace: "envoy-gateway-system", name: "public", sectionName: $listener},
      controllerName: "gateway.envoyproxy.io/gatewayclass-controller", conditions: [$condition]};
    def policy($name; $ancestors): {apiVersion: "gateway.envoyproxy.io/v1alpha1", kind: "EnvoyExtensionPolicy",
      metadata: {name: $name, namespace: "demo", generation: 2}, spec: {}, status: {ancestors: $ancestors}};
    policy("accepted"; [ancestor("https"; accepted("True"; 2))]),
    policy("accepted-by-both"; [ancestor("https"; accepted("True"; 2)), ancestor("http"; accepted("True"; 2))]),
    policy("accepted-before"; [ancestor("https"; accepted("True"; 1))]),
    policy("refused"; [ancestor("https"; accepted("False"; 2))]),
    policy("refused-by-one"; [ancestor("https"; accepted("True"; 2)), ancestor("http"; accepted("False"; 2))]),
    policy("refused-before"; [ancestor("https"; accepted("False"; 1))]),
    policy("no-ancestor"; [])' | sed 's/^/---\n/' >"$cel/statuses.yaml"
  # Kyverno exits 1 when an expression is false, which is a verdict.
  kyverno apply "$cel/policies.yaml" --resource "$cel/statuses.yaml" --crd-paths "$cel/definition.yaml" -p --output-format json \
    >"$cel/out" 2>"$cel/err" || [[ $? -eq 1 ]] || { echo "kyverno failed: $(cat "$cel/err")"; return 1; }
  grep '^{' "$cel/out" >"$cel/report.json" || { echo "kyverno gave no report: $(cat "$cel/out" "$cel/err")"; return 1; }
  [ "$(jq '[.results[] | select(.result == "pass" or .result == "fail")] | length' "$cel/report.json")" -eq 14 ] \
    || { echo "kyverno gave no verdict on every status: $(jq -c '[.results[] | {policy, result, message}]' "$cel/report.json")"; return 1; }
  verdicts="$(jq -r '[.results[] | select(.result == "pass") | .policy + " " + .resources[0].name] | sort | join(", ")' "$cel/report.json")"
  [ "$verdicts" = "current accepted, current accepted-by-both, failed refused, failed refused-by-one" ] \
    || { echo "the expressions hold true for: $verdicts"; return 1; }
  [ -n "$(taking)" ]
  for file in $(taking); do
    ks="$REPO/$file"
    route="$(yq '.spec.postBuild.substitute.WAF_ROUTE // ""' "$ks")"
    mode="$(yq '.spec.postBuild.substitute.WAF_MODE // ""' "$ks")"
    echo "$file: WAF_ROUTE=$route WAF_MODE=$mode"
    [[ $route =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "$file: WAF_ROUTE is no route name: $route"; return 1; }
    [[ $mode == On || $mode == DetectionOnly ]] || { echo "$file: WAF_MODE is neither On nor DetectionOnly: $mode"; return 1; }
    [ "$(yq '.spec.wait' "$ks")" = true ] || { echo "$file does not wait, so its health expressions are never read"; return 1; }
    [ "$(yq -o json -I0 '[(.spec.healthCheckExprs // [])[] | select(.kind == "EnvoyExtensionPolicy")]' "$ks" | jq -cS .)" = "$health" ] \
      || { echo "$file: the health expressions for EnvoyExtensionPolicy are not the component's"; return 1; }
    # Its policy, built from its own file, renders its mode after the recommended configuration's.
    built_own "$file"
    yq -N -o json -I0 'select(.kind == "EnvoyExtensionPolicy") | .spec.wasm[].config.directives_map.default' "$BUILT" >"$BATS_TEST_TMPDIR/directives"
    [ "$(jq -c . "$BATS_TEST_TMPDIR/directives")" = "$(jq -cn --arg mode "$mode" "$DIRECTIVES")" ] \
      || { echo "$file renders $(cat "$BATS_TEST_TMPDIR/directives") for $mode"; return 1; }
  done
  # The rendered rule engine line is the mode's: On for the demo route as the tree has it...
  built hello-route
  object "$BUILT" EnvoyExtensionPolicy hello | yq -o json -I0 '.spec.wasm[0].config.directives_map.default' >"$BATS_TEST_TMPDIR/directives"
  [ "$(jq -c . "$BATS_TEST_TMPDIR/directives")" = "$(jq -cn --arg mode On "$DIRECTIVES")" ]
  # ...and DetectionOnly, after the recommended configuration's own line, once the route chooses it.
  tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree"
  cp -r "$REPO/kubernetes" "$tree/kubernetes"
  yq -i '.spec.postBuild.substitute.WAF_MODE = "DetectionOnly"' "$tree/kubernetes/apps/base/demo/hello-route/ks.yaml"
  built hello-route "$tree"
  object "$BUILT" EnvoyExtensionPolicy hello | yq -o json -I0 '.spec.wasm[0].config.directives_map.default' >"$BATS_TEST_TMPDIR/directives"
  [ "$(jq -c . "$BATS_TEST_TMPDIR/directives")" = "$(jq -cn --arg mode DetectionOnly "$DIRECTIVES")" ]
  [ "$(jq -r '.[] | select(startswith("SecRuleEngine"))' "$BATS_TEST_TMPDIR/directives")" = "SecRuleEngine DetectionOnly" ]
  rm -rf "$tree"
}
