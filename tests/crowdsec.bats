#!/usr/bin/env bats
# Proves features/crowdsec.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq and jq on PATH (the versions pinned for the repository). The
# crowdsec chart is pulled once per run from its public repository; building and rendering are
# offline, with the placeholders of the cluster's example key lists. The one test that runs
# CrowdSec itself needs docker, and runs the image with no network. What a pod reads is taken from
# the render: the file each mount puts in its container, not the values that made it.

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
  DOCS="$REPO/docs/kubernetes.md"
  # The overlay's entries for CrowdSec: its namespace directory and two Kustomizations, the second
  # in the namespace of the proxies it reads, which it needs to be allowed to.
  NAMESPACE_ENTRY=../../base/crowdsec
  APP_ENTRY=../../base/crowdsec/crowdsec/ks.yaml
  ACCESS_ENTRY=../../base/envoy-gateway-system/crowdsec-gateway-logs/ks.yaml
  PROXY_LABELS="app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,app.kubernetes.io/name=envoy,gateway.envoyproxy.io/owning-gateway-name=public"
}

# overlay: the lab-sto2 overlay as Flux reads it, its namespaces and the Kustomization of each
# enabled application. Writes $OVERLAY.
overlay() {
  OVERLAY="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "$OVERLAY_DIR" >"$OVERLAY"
}

# built APP: the application APP as Flux applies it on lab-sto2: the overlay's Kustomization of it,
# with the example key lists, and its own substitutions over them, strictly. Writes
# $BATS_TEST_TMPDIR/APP-built.yaml and sets BUILT and KS, the Kustomization as built. The overlay is
# built once for a test.
built() {
  local app=$1 path
  [ -s "${OVERLAY:-}" ] || overlay
  KS="$BATS_TEST_TMPDIR/$app-ks.yaml"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  NAME="$app" yq ea 'select(fileIndex == 0) as $vars
    | select(fileIndex == 1 and .kind == "Kustomization" and .metadata.name == strenv(NAME))
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "$EXAMPLE" "$OVERLAY" >"$KS"
  [ -s "$KS" ] || { echo "the lab-sto2 overlay does not enable $app"; return 1; }
  path="$(yq '.spec.path' "$KS")"
  BUILT="$BATS_TEST_TMPDIR/$app-built.yaml"
  (cd "$REPO" && flux build kustomization "$app" --path "./kubernetes/${path#./}" \
    --kustomization-file "$KS" --dry-run --strict-substitute) >"$BUILT"
}

# every_build: every application the lab-sto2 overlay enables, each built as built builds it, in one
# file, $EVERY.
every_build() {
  local app
  [ -s "${OVERLAY:-}" ] || overlay
  EVERY="$BATS_TEST_TMPDIR/every-built.yaml"
  : >"$EVERY"
  for app in $(yq -N 'select(.kind == "Kustomization") | .metadata.name' "$OVERLAY"); do
    built "$app"
    { echo ---; cat "$BUILT"; } >>"$EVERY"
  done
}

# render: builds crowdsec, then renders the chart its HelmRelease installs, from the repository and
# version its HelmRepository and HelmRelease name, with the values helm-controller gives it: those
# of each ConfigMap the HelmRelease reads, in order, each from the key its entry names, then the
# HelmRelease's own over them, as scripts/render does. It fails on what it does not apply rather
# than render without it: values into a targetPath, and any post-renderer, through which
# helm-controller would pass the manifests after the chart. Writes $BATS_TEST_TMPDIR/crowdsec.yaml
# and sets BUILT and APP_BUILT (the application as built, which stays when another is built),
# VALUES (the merged values), RENDERED and RELEASE_NAMESPACE, the namespace helm-controller installs
# the chart's objects into.
render() {
  local url chart version release namespace pulled name key i values=() count
  built crowdsec
  APP_BUILT="$BUILT"
  url="$(yq -N 'select(.kind == "HelmRepository") | .spec.url' "$BUILT")"
  chart="$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.chart' "$BUILT")"
  version="$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.version' "$BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.postRenderers // [] | length' "$BUILT")" -eq 0 ] ||
    { echo "the HelmRelease has a post-renderer, which this render does not apply"; return 1; }
  count="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom | length' "$BUILT")"
  for ((i = 0; i < count; i++)); do
    name="$(I=$i yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[env(I)].name' "$BUILT")"
    [ "$(I=$i yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[env(I)].kind' "$BUILT")" = ConfigMap ] ||
      { echo "valuesFrom $name is not a ConfigMap"; return 1; }
    [ -z "$(I=$i yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[env(I)].targetPath // ""' "$BUILT")" ] ||
      { echo "valuesFrom $name puts its values into a targetPath, which this render does not apply"; return 1; }
    key="$(I=$i yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[env(I)].valuesKey // "values.yaml"' "$BUILT")"
    values[i]="$BATS_TEST_TMPDIR/values-$i.yaml"
    NAME="$name" KEY="$key" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .data
      | select(has(strenv(KEY))) | .[strenv(KEY)]' "$BUILT" >"${values[i]}"
    [ -s "${values[i]}" ] || { echo "no values under $key in the ConfigMap $name the HelmRelease reads"; return 1; }
  done
  INLINE="$BATS_TEST_TMPDIR/inline.yaml"
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$BUILT" >"$INLINE"
  VALUES="$BATS_TEST_TMPDIR/values.yaml"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' "${values[@]}" "$INLINE" >"$VALUES"
  pulled="$BATS_FILE_TMPDIR/charts/$chart-$version"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$chart" --repo "$url" --version "$version" --destination "$pulled"
  fi
  RENDERED="$BATS_TEST_TMPDIR/crowdsec.yaml"
  RELEASE_NAMESPACE="$namespace"
  helm template "$release" "$pulled"/*.tgz --namespace "$namespace" --kube-version "$KUBE" \
    "${values[@]/#/--values=}" --values "$INLINE" >"$RENDERED"
}

# mounts NAME: what the containers of the Deployment NAME of RENDERED mount, one a line and sorted:
# the path, and whether it comes from a ConfigMap, a claim or an emptyDir.
mounts() {
  object "$RENDERED" Deployment "$1" | yq -o json -I0 '.spec.template.spec' | jq -r '
    . as $spec | .containers[] | (.volumeMounts // [])[] | . as $mount
    | ([$spec.volumes[] | select(.name == $mount.name)][0]) as $volume
    | $mount.mountPath + " " + (
        if $volume.configMap != null then "ConfigMap"
        elif $volume.persistentVolumeClaim != null then "claim"
        elif $volume.emptyDir != null then "emptyDir"
        else ($volume | tojson) end)' | LC_ALL=C sort
}

# mounted NAME PATH: the file a container of the Deployment NAME of RENDERED has at PATH: the one
# key of a ConfigMap that its mount there names, found in RENDERED or, for a ConfigMap the
# application generates, in APP_BUILT. Fails, saying so, unless exactly one mount is at PATH and it
# is one key of a ConfigMap.
mounted() {
  local from name key
  from="$(object "$RENDERED" Deployment "$1" | yq -o json -I0 '.spec.template.spec' | jq -r --arg path "$2" '
    . as $spec | [.containers[] | (.volumeMounts // [])[] | select(.mountPath == $path)] as $at
    | if ($at | length) != 1 then error("\($at | length) mounts at \($path)") else $at[0] end
    | . as $mount | ([$spec.volumes[] | select(.name == $mount.name)][0]) as $volume
    | if $volume.configMap == null or ($mount.subPath // "") == "" then error("the mount at \($path) is not one key of a ConfigMap") else . end
    | $volume.configMap.name + " " + ((($volume.configMap.items // []) | map(select(.path == $mount.subPath)) | first | .key) // $mount.subPath)')"
  read -r name key <<<"$from"
  [ -n "$name" ] && [ -n "$key" ] || { echo "the Deployment $1 mounts no key of a ConfigMap at $2"; return 1; }
  NAME="$name" KEY="$key" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .data[strenv(KEY)]' \
    "$RENDERED" "$APP_BUILT"
}

# pods NAME: the pods of the Deployment NAME of RENDERED, as scripts/network-policy-check takes pods
# that no render names by their namespace: the release's namespace and the labels of the pod
# template.
pods() {
  echo "$RELEASE_NAMESPACE:$(object "$RENDERED" Deployment "$1" | yq -o json -I0 '.spec.template.metadata.labels' |
    jq -r 'to_entries | map(.key + "=" + .value) | join(",")')"
}

# reaches and refused SIDE FROM TO PORT: assert what the policies in $FLOWS answer for the flow, as
# scripts/network-policy-check evaluates them the way Cilium decides: SIDE is --reach for the
# sender's egress and the receiver's ingress together, --reach-egress for the sender's alone and
# --reach-ingress for the receiver's alone.
reaches() {
  run "$REPO/scripts/network-policy-check" "$1" "$FLOWS" "${@:2}"
  [ "$status" -eq 0 ] || { echo "expected ${*:2} to be allowed ($1): $output"; return 1; }
}
refused() {
  run "$REPO/scripts/network-policy-check" "$1" "$FLOWS" "${@:2}"
  [ "$status" -eq 1 ] || { echo "expected ${*:2} to be denied ($1): $output"; return 1; }
}

# allows FILE: what the Cilium policies of FILE allow, one rule a line and sorted: the policy, the
# pods it selects, the direction, the peers and the ports. It fails on what it does not read rather
# than skip it: a policy with more than one spec, or with anything besides its selector, the default
# deny it leaves to the namespace and its two lists of rules; a peer that is neither pods by their
# labels nor an entity; a rule without a port; and a port that is not one number and a protocol.
allows() {
  yq -o json -I0 'select(.kind == "CiliumNetworkPolicy")' "$1" | jq -r '
    def only($what; $read): if (keys - $read | length) > 0 then error("\($what) holds \(keys - $read | join(", ")), which this test does not read") else . end;
    def pods($what): only($what; ["matchLabels"]) | .matchLabels | to_entries | map((.key | sub("^k8s:"; "")) + "=" + .value) | sort | join(",");
    def ports($what): [(.toPorts // error("\($what) names no port"))[] | only($what; ["ports"]) | .ports[] | only($what; ["port", "protocol"])
      | if (.port | type) == "string" and (.port | test("^[1-9][0-9]*$")) and (.protocol | IN("TCP", "UDP")) then .port + "/" + .protocol
        else error("\($what) names the port \(tojson), which is not one number and a protocol") end] | sort | join("+");
    def peers($what; $pods; $entities): [(.[$pods] // [])[] | pods($what)] + [(.[$entities] // [])[] | "@" + .]
      | if length == 0 then error("\($what) names no peer") else sort | join(" ") end;
    .metadata.name as $name | "the policy \($name)" as $what
    | only($what; ["apiVersion", "kind", "metadata", "spec"]) | .spec
    | only($what; ["endpointSelector", "enableDefaultDeny", "ingress", "egress"])
    | if .enableDefaultDeny != {"ingress": false, "egress": false} then error("\($what) does not leave the default deny to the namespace") else . end
    | (.endpointSelector | pods($what)) as $self
    | ((.ingress // [])[] | only($what; ["fromEndpoints", "fromEntities", "toPorts"])
        | "\($name) [\($self)] takes \(peers($what; "fromEndpoints"; "fromEntities")) on \(ports($what))"),
      ((.egress // [])[] | only($what; ["toEndpoints", "toEntities", "toPorts"])
        | "\($name) [\($self)] sends to \(peers($what; "toEndpoints"; "toEntities")) on \(ports($what))")' | LC_ALL=C sort
}

# scraped SERVICE: the container port the monitor of the Service SERVICE of RENDERED scrapes: the
# target of the Service's port that a ServiceMonitor selecting the Service by its labels names.
scraped() {
  yq -N -o json -I0 'select(.kind == "Service" or .kind == "ServiceMonitor")' "$RENDERED" | jq -rs --arg name "$1" '
    ([.[] | select(.kind == "Service" and .metadata.name == $name)][0]) as $service
    | [.[] | select(.kind == "ServiceMonitor")
       | select(.spec.selector.matchLabels | to_entries | all(.[]; ($service.metadata.labels // {})[.key] == .value))
       | .spec.endpoints[].port] as $scraped
    | [$service.spec.ports[] | select(.name as $port | $scraped | index($port)) | .targetPort] | unique
    | if length == 1 then .[0] else error("the monitors of the Service \($name) scrape \(length) ports") end'
}

# probed NAME: the container ports the probes of the Deployment NAME of RENDERED name, on one line.
probed() {
  object "$RENDERED" Deployment "$1" | yq -o json -I0 '.spec.template.spec' | jq -r '
    [.containers[] | . as $container | ($container.readinessProbe, $container.livenessProbe, $container.startupProbe) | select(. != null)
      | (.httpGet.port // .tcpSocket.port // .grpc.port) as $port | select($port != null)
      | if ($port | type) == "number" then $port else ($container.ports[] | select(.name == $port) | .containerPort) end]
    | unique | map(tostring) | join(" ")'
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

# tree_without ENTRY...: a copy of the tree in $TREE whose lab-sto2 overlay lacks each ENTRY, a
# resource of it as written.
tree_without() {
  local entry
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  mkdir -p "$TREE"
  cp -r "$REPO/kubernetes" "$TREE/kubernetes"
  for entry in "$@"; do
    ENTRY="$entry" yq -i '.resources |= map(select(. != strenv(ENTRY)))' \
      "$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  done
}

# of_crowdsec FILE: what an overlay built into FILE holds of CrowdSec, sorted, as kind, namespace and
# name: the namespace itself, any object in it, and any Kustomization that deploys into it or from a
# directory of CrowdSec's.
of_crowdsec() {
  yq -N 'select((.kind == "Namespace" and .metadata.name == "crowdsec") or .metadata.namespace == "crowdsec"
      or .spec.targetNamespace == "crowdsec" or ((.spec.path // "") | test("crowdsec")))
    | .kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$1" | LC_ALL=C sort | paste -sd, -
}

# crowdsec_docs: the CrowdSec part of the docs, from its heading to the next heading of its level or
# above.
crowdsec_docs() {
  awk '/^### CrowdSec$/ {in_part = 1; next} /^(#|##|###) / {in_part = 0} in_part {print}' "$DOCS"
}

# docs_rows HEADER: the rows of the table of the docs' CrowdSec part whose header row is HEADER,
# without that row and the rule under it.
docs_rows() {
  crowdsec_docs | awk -v header="$1" '
    !in_table && index($0, header) {in_table = 1; getline; next}
    in_table && /^ *\|/ {print; next}
    in_table {exit}'
}

teardown() {
  # A start of the agent or of the local API that outlived its test does not outlive the run, and
  # nor does a volume it made.
  local container
  for container in "${AGENT_CONTAINER:-}" "${LAPI_CONTAINER:-}"; do
    if [ -n "$container" ]; then
      docker rm -f -v "$container" >/dev/null 2>&1 || true
    fi
  done
}

# agent_start: starts the agent's container of RENDERED as the chart's pod starts it, with no
# network: its image, its command, its environment, its capabilities and the files of its ConfigMap
# mounts, each found in RENDERED or in APP_BUILT, where the acquisition's is. Its emptyDir holds a
# credentials file in place of the one its init container writes. Go's resolver in each process of
# the image names every lookup it makes (GODEBUG=netdns=2). Writes the start's output to
# $BATS_TEST_TMPDIR/agent-start.log.
agent_start() {
  local spec dir path volume sub name key index=0 image url
  local mounts=() envs=() command=() security=()
  spec="$BATS_TEST_TMPDIR/agent-spec.json"
  object "$RENDERED" Deployment crowdsec-agent | yq -o json '.spec.template.spec' >"$spec"
  [ "$(jq '.containers | length' "$spec")" -eq 1 ]
  dir="$BATS_TEST_TMPDIR/agent-start"
  mkdir -p "$dir/files"
  # Every variable is a literal, as the start is run with no Secret and no field of a pod.
  [ "$(jq '[.containers[0].env[] | select(has("value") | not)] | length' "$spec")" -eq 0 ]
  while IFS= read -r -d '' key; do
    envs+=(-e "$key")
  done < <(jq -j '.containers[0].env[] | .name + "=" + .value + "\u0000"' "$spec")
  [ "$(jq -c '.containers[0].securityContext | [.allowPrivilegeEscalation, .capabilities.drop]' "$spec")" = '[false,["ALL"]]' ]
  security=(--cap-drop ALL --security-opt no-new-privileges)
  while IFS=$'\t' read -r path volume sub; do
    if [ "$(VOLUME="$volume" jq -r '.volumes[] | select(.name == env.VOLUME) | has("emptyDir")' "$spec")" = true ]; then
      # The init container registers the agent and leaves its credentials here; the address is the
      # local API's, as it registers with it.
      url="$(jq -r '.initContainers[0].env[] | select(.name == "LAPI_URL") | .value' "$spec")"
      mkdir -p "$dir/$volume"
      printf 'url: %s\nlogin: offline\npassword: offline\n' "$url" >"$dir/$volume/local_api_credentials.yaml"
      mounts+=(-v "$dir/$volume:$path")
      continue
    fi
    name="$(VOLUME="$volume" jq -r '.volumes[] | select(.name == env.VOLUME) | .configMap.name // ""' "$spec")"
    [ -n "$name" ] && [ -n "$sub" ] || { echo "the agent mounts $volume at $path, which is no file of a ConfigMap"; return 1; }
    key="$(VOLUME="$volume" SUB="$sub" jq -r '.volumes[] | select(.name == env.VOLUME)
      | (.configMap.items // [] | map(select(.path == env.SUB)) | first | .key) // env.SUB' "$spec")"
    index=$((index + 1))
    NAME="$name" KEY="$key" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME)) | .data[strenv(KEY)]' \
      "$RENDERED" "$APP_BUILT" >"$dir/files/$index"
    [ -s "$dir/files/$index" ] || { echo "no key $key in a ConfigMap $name"; return 1; }
    mounts+=(-v "$dir/files/$index:$path:ro")
  done < <(jq -r '.containers[0].volumeMounts[] | [.mountPath, .name, (.subPath // "")] | @tsv' "$spec")
  mapfile -d '' -t command < <(jq -j '.containers[0] | (.command + (.args // []))[] | . + "\u0000"' "$spec")
  image="$(jq -r '.containers[0].image' "$spec")"
  AGENT_CONTAINER="crowdsec-agent-start-$$-$RANDOM"
  timeout 300 docker run --rm --name "$AGENT_CONTAINER" --network none "${security[@]}" "${envs[@]}" -e GODEBUG=netdns=2 \
    "${mounts[@]}" --entrypoint "${command[0]}" "$image" "${command[@]:1}" >"$BATS_TEST_TMPDIR/agent-start.log" 2>&1 || true
}

# lapi_start: starts the local API's container of RENDERED as the chart's pod starts it, with no
# network: its image, its command, its environment, its capabilities and the files of its ConfigMap
# mounts, with an empty volume in place of each claim, as at a pod's first start. The two values the
# pod reads from the Secret are stand-ins of the form the application's generators make, twice the
# generator's length in hexadecimal digits, and the pod's name is a stand-in too. Go's resolver in
# each process of the image names every lookup it makes (GODEBUG=netdns=2). It waits until the
# container answers on its metrics port, which it does once everything the start runs is up, and
# then asks the health endpoint the kubelet probes. Writes that answer to
# $BATS_TEST_TMPDIR/lapi-health, the number of notifications each profile the container holds names
# to $BATS_TEST_TMPDIR/lapi-notifications, and the start's output to
# $BATS_TEST_TMPDIR/lapi-start.log.
lapi_start() {
  local spec dir line path kind name key length count i index=0 image health metrics
  local lines=() mounts=() envs=() command=() security=()
  spec="$BATS_TEST_TMPDIR/lapi-spec.json"
  object "$RENDERED" Deployment crowdsec-lapi | yq -o json '.spec.template.spec' >"$spec"
  [ "$(jq '.containers | length' "$spec")" -eq 1 ]
  dir="$BATS_TEST_TMPDIR/lapi-start"
  mkdir -p "$dir"
  count="$(jq '.containers[0].env | length' "$spec")"
  for ((i = 0; i < count; i++)); do
    name="$(jq -r --argjson i "$i" '.containers[0].env[$i].name' "$spec")"
    kind="$(jq -r --argjson i "$i" '.containers[0].env[$i]
      | if has("value") then "literal" elif .valueFrom.fieldRef.fieldPath == "metadata.name" then "name" elif .valueFrom.secretKeyRef != null then "secret" else "other" end' "$spec")"
    case $kind in
      literal) envs+=(-e "$name=$(jq -r --argjson i "$i" '.containers[0].env[$i].value' "$spec")") ;;
      name) envs+=(-e "$name=crowdsec-lapi-offline") ;;
      secret)
        key="$(jq -r --argjson i "$i" '.containers[0].env[$i].valueFrom.secretKeyRef.key' "$spec")"
        length="$(KEY="$key" yq -N 'select(.kind == "Password" and .spec.encoding == "hex" and (.spec.secretKeys | any_c(. == strenv(KEY)))) | .spec.length' "$APP_BUILT")"
        [[ $length =~ ^[0-9]+$ ]] || { echo "no Password generator of the application makes the key $key in hexadecimal"; return 1; }
        envs+=(-e "$name=$(printf '%*s' "$((2 * length))" '' | tr ' ' a)")
        ;;
      *) echo "the local API's variable $name is neither a literal, its pod's name nor a key of a Secret"; return 1 ;;
    esac
  done
  mapfile -t lines < <(mounts crowdsec-lapi)
  [ "${#lines[@]}" -gt 0 ]
  for line in "${lines[@]}"; do
    read -r path kind <<<"$line"
    case $kind in
      claim) mounts+=(--tmpfs "$path") ;;
      ConfigMap)
        index=$((index + 1))
        mounted crowdsec-lapi "$path" >"$dir/$index"
        [ -s "$dir/$index" ] || { echo "the local API's mount at $path is empty"; return 1; }
        mounts+=(-v "$dir/$index:$path:ro")
        ;;
      *) echo "the local API mounts $kind at $path, which this start does not stand in for"; return 1 ;;
    esac
  done
  [ "$(jq -c '.containers[0].securityContext | [.allowPrivilegeEscalation, .capabilities.drop]' "$spec")" = '[false,["ALL"]]' ]
  security=(--cap-drop ALL --security-opt no-new-privileges)
  mapfile -d '' -t command < <(jq -j '.containers[0] | (.command + (.args // []))[] | . + "\u0000"' "$spec")
  image="$(jq -r '.containers[0].image' "$spec")"
  health="$(jq -r '.containers[0] | .readinessProbe.httpGet as $probe
    | "http://127.0.0.1:\(.ports[] | select(.name == $probe.port) | .containerPort)\($probe.path)"' "$spec")"
  metrics="$(jq -r '.containers[0] | "http://127.0.0.1:\(.ports[] | select(.name == "metrics") | .containerPort)/metrics"' "$spec")"
  LAPI_CONTAINER="crowdsec-lapi-start-$$-$RANDOM"
  docker run --detach --name "$LAPI_CONTAINER" --network none "${security[@]}" "${envs[@]}" -e GODEBUG=netdns=2 \
    "${mounts[@]}" --entrypoint "${command[0]}" "$image" "${command[@]:1}" >/dev/null
  for ((i = 0; i < 120; i++)); do
    [ "$(docker inspect --format '{{.State.Running}}' "$LAPI_CONTAINER" 2>/dev/null)" = true ] || break
    if docker exec "$LAPI_CONTAINER" wget -q -T 2 -O /dev/null "$metrics" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  docker exec "$LAPI_CONTAINER" wget -q -T 5 -O - "$health" >"$BATS_TEST_TMPDIR/lapi-health" 2>/dev/null || true
  docker exec "$LAPI_CONTAINER" yq e -N '(.notifications // []) | length' /etc/crowdsec/profiles.yaml \
    >"$BATS_TEST_TMPDIR/lapi-notifications" 2>/dev/null || true
  docker logs "$LAPI_CONTAINER" >"$BATS_TEST_TMPDIR/lapi-start.log" 2>&1 || true
  docker rm -f -v "$LAPI_CONTAINER" >/dev/null 2>&1 || true
}

# env_names FILE KIND NAME: the names of the variables of every container of the workload.
env_names() {
  KIND="$2" NAME="$3" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))
    | [.spec.template.spec.containers[], .spec.template.spec.initContainers[]?] | .[].env[]?.name' "$1" | LC_ALL=C sort -u
}

@test "CrowdSec is selected by overlay entries and builds nothing when it is not" {
  local dependency
  local dependencies=(cilium crowdsec-gateway-logs external-secrets linstor-cluster prometheus-operator-crds)
  # The overlay selects it with three entries: the namespace directory and the two Kustomizations.
  [ "$(yq '.resources[] | select(test("crowdsec"))' "$OVERLAY_DIR/kustomization.yaml" | LC_ALL=C sort | paste -sd, -)" \
    = "$NAMESPACE_ENTRY,$APP_ENTRY,$ACCESS_ENTRY" ]
  overlay
  [ "$(of_crowdsec "$OVERLAY")" = ConfigMap/crowdsec/app-template-defaults,Kustomization/flux-system/crowdsec,Kustomization/flux-system/crowdsec-gateway-logs,Namespace/-/crowdsec,NetworkPolicy/crowdsec/default-deny ]
  # The application names what it needs, no more and no less, and waits for its release; the other
  # waits for the Gateway whose proxies it grants a read of.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "crowdsec") | .spec.dependsOn | map(.name) | sort | join(" ")' "$OVERLAY")" \
    = "$(printf '%s\n' "${dependencies[@]}" | sort | paste -sd' ' -)" ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "crowdsec") | .spec.wait' "$OVERLAY")" = true ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "crowdsec-gateway-logs") | .spec.dependsOn | map(.name) | join(" ")' "$OVERLAY")" = gateway-public ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "crowdsec-gateway-logs") | .spec.targetNamespace' "$OVERLAY")" = envoy-gateway-system ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "crowdsec-gateway-logs") | .spec.wait' "$OVERLAY")" = true ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # With only the namespace directory's entry, the cluster builds the namespace and its defaults,
  # and nothing else of CrowdSec.
  tree_without "$APP_ENTRY" "$ACCESS_ENTRY"
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2" >"$BATS_TEST_TMPDIR/namespace-only.yaml"
  [ "$(of_crowdsec "$BATS_TEST_TMPDIR/namespace-only.yaml")" = ConfigMap/crowdsec/app-template-defaults,Namespace/-/crowdsec,NetworkPolicy/crowdsec/default-deny ]
  # With none of the entries, nothing of CrowdSec.
  tree_without "$NAMESPACE_ENTRY" "$APP_ENTRY" "$ACCESS_ENTRY"
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2" >"$BATS_TEST_TMPDIR/none.yaml"
  [ -z "$(of_crowdsec "$BATS_TEST_TMPDIR/none.yaml")" ]
  [ "$(grep -c crowdsec "$BATS_TEST_TMPDIR/none.yaml")" -eq 0 ]
  # Selecting it without one of the applications it needs is refused, naming both.
  for dependency in "${dependencies[@]}"; do
    case $dependency in
      crowdsec-gateway-logs) tree_without "$ACCESS_ENTRY" ;;
      *) tree_without "$(DEPENDENCY=$dependency yq '.resources[] | select(test("/" + strenv(DEPENDENCY) + "/ks.yaml$"))' "$OVERLAY_DIR/kustomization.yaml")" ;;
    esac
    run "$REPO/scripts/kubernetes-check" "$TREE"
    echo "without $dependency: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"kubernetes/apps/base/crowdsec/crowdsec/ks.yaml: Kustomization crowdsec names $dependency"* ]]
    [[ $output == *"does not enable"* ]]
  done
  # The Kustomization that grants the read is refused without the Gateway.
  tree_without "$(yq '.resources[] | select(test("/gateway-public/ks.yaml$"))' "$OVERLAY_DIR/kustomization.yaml")"
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "without gateway-public: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"kubernetes/apps/base/envoy-gateway-system/crowdsec-gateway-logs/ks.yaml: Kustomization crowdsec-gateway-logs names gateway-public"* ]]
}

@test "CrowdSec's agents read the public Gateway's access logs with a pinned parser" {
  local proxy proxy_namespace proxy_labels document key keys parser file statics whitelist
  local rows expected scenario groupby distinct capacity leakspeed counts filter row per rules image held
  # The public Gateway's EnvoyProxy as Flux applies it, the one the Gateway names for its proxies:
  # its namespace is theirs, and the labels it spreads them by are the ones the controller gives
  # them.
  built gateway-public
  [ "$(yq -N 'select(.kind == "Gateway" and .metadata.name == "public") | .spec.infrastructure.parametersRef | .kind + "/" + .name' "$BUILT")" = EnvoyProxy/public ]
  proxy="$BATS_TEST_TMPDIR/envoyproxy.yaml"
  yq 'select(.kind == "EnvoyProxy" and .metadata.name == "public")' "$BUILT" >"$proxy"
  proxy_namespace="$(yq '.metadata.namespace' "$proxy")"
  [ "$proxy_namespace" = envoy-gateway-system ]
  proxy_labels="$(yq '.spec.provider.kubernetes.envoyDeployment.pod.topologySpreadConstraints[0].labelSelector.matchLabels
    | to_entries | map(.key + "=" + .value) | sort | join(",")' "$proxy")"
  [ "$proxy_labels" = "$PROXY_LABELS" ]
  render
  # What the agent's container mounts, and nothing else: the two acquisition files it reads, its
  # parser, its scenarios and its configuration, each one key of a ConfigMap, and the directory its
  # init container leaves its credentials in.
  mounts crowdsec-agent
  [ "$(mounts crowdsec-agent)" = "$(printf '%s\n' \
    "/etc/crowdsec/acquis.d/envoy-gateway.yaml ConfigMap" \
    "/etc/crowdsec/acquis.yaml ConfigMap" \
    "/etc/crowdsec/config.yaml.local ConfigMap" \
    "/etc/crowdsec/parsers/s01-parse/envoy-gateway-json.yaml ConfigMap" \
    "/etc/crowdsec/scenarios/http-auth-failures.yaml ConfigMap" \
    "/etc/crowdsec/scenarios/http-probing.yaml ConfigMap" \
    "/etc/crowdsec/scenarios/http-sensitive-paths.yaml ConfigMap" \
    "/tmp_config emptyDir")" ]
  # The agent reads acquisitions from the image's two places, the file and the directory those
  # mounts fill: its configuration over the image's names the hub's branch and nothing else, so it
  # moves neither place.
  [ "$(mounted crowdsec-agent /etc/crowdsec/config.yaml.local | yq -o json -I0 '.')" = '{"cscli":{"hub_branch":"master"}}' ]
  # One acquisition, through the Kubernetes API, of the proxies' pods in their namespace by the
  # labels the controller gives them, with the label the parser selects: the one document of the one
  # key of the ConfigMap the application generates, mounted into the directory the agent reads
  # acquisitions from.
  document="$(mounted crowdsec-agent /etc/crowdsec/acquis.d/envoy-gateway.yaml | yq -o json -I0 '.')"
  echo "$document"
  [ "$(wc -l <<<"$document")" -eq 1 ]
  [ "$(jq -r '.source' <<<"$document")" = kubernetes ]
  [ "$(jq -r '.namespace' <<<"$document")" = "$proxy_namespace" ]
  [ "$(jq -r '.selector | split(",") | sort | join(",")' <<<"$document")" = "$proxy_labels" ]
  [ "$(jq -c '.labels' <<<"$document")" = '{"type":"envoy-gateway-json"}' ]
  [ "$(jq -r 'keys | sort | join(",")' <<<"$document")" = labels,namespace,selector,source ]
  [ "$(yq -N 'select(.kind == "ConfigMap" and (.metadata.name | test("^crowdsec-acquisition-"))) | .data | keys | join(",")' "$APP_BUILT")" = envoy-gateway.yaml ]
  [ "$(yq -N 'select(.kind == "Deployment" and .metadata.name == "crowdsec-agent") | .spec.template.spec.containers[0].volumeMounts[]
    | select(.mountPath == "/etc/crowdsec/acquis.d/envoy-gateway.yaml") | .name + " " + .subPath' "$RENDERED")" = "acquisition envoy-gateway.yaml" ]
  [ "$(yq -N 'select(.kind == "Deployment" and .metadata.name == "crowdsec-agent") | .spec.template.spec.volumes[] | select(.name == "acquisition")
    | .configMap.name' "$RENDERED")" = "$(yq -N 'select(.kind == "ConfigMap" and (.metadata.name | test("^crowdsec-acquisition-"))) | .metadata.name' "$APP_BUILT")" ]
  # The chart's own acquisition, which it requires, is the placeholder: one file source, whose path
  # no mount of the pod provides.
  [ "$(mounted crowdsec-agent /etc/crowdsec/acquis.yaml | yq -o json -I0 '.' | jq -cS '.')" \
    = '{"filenames":["/var/log/crowdsec-none/*.log"],"labels":{"type":"none"},"source":"file"}' ]
  # The only parser the agent loads from outside its image is the tree's own, of the stage that
  # parses, and the only scenarios the tree's own: nothing names an item of the hub, and no
  # variable of the agent installs one.
  [ "$(yq '(.config.parsers // {}) | to_entries | map(select(.value | length > 0) | .key + ":" + (.value | keys | join("+"))) | join(",")' "$VALUES")" \
    = "s01-parse:envoy-gateway-json.yaml" ]
  [ "$(yq '.config.scenarios | keys | sort | join(",")' "$VALUES")" = http-auth-failures.yaml,http-probing.yaml,http-sensitive-paths.yaml ]
  [ "$(yq '(.config.postoverflows // {}) | to_entries | map(select(.value | length > 0)) | length' "$VALUES")" -eq 0 ]
  for key in COLLECTIONS PARSERS SCENARIOS POSTOVERFLOWS CONTEXTS APPSEC_CONFIGS APPSEC_RULES; do
    [ -z "$(env_names "$RENDERED" Deployment crowdsec-agent | grep -x "$key" || true)" ]
    [ -z "$(env_names "$RENDERED" Deployment crowdsec-lapi | grep -x "$key" || true)" ]
  done
  # The agent's one variable removes post-overflow items of its image; it installs none.
  [ "$(yq '.agent.env // [] | map(.name) | join(",")' "$VALUES")" = DISABLE_POSTOVERFLOWS ]
  [ "$(yq '.lapi.env | map(.name) | join(",")' "$VALUES")" = DISABLE_ONLINE_API ]
  [ -z "$(yq -N 'select(.kind == "ConfigMap" and (.data | keys | any_c(test("^(collections|parsers)")))) | .metadata.name' "$RENDERED")" ]
  [ "$(yq '.config["agent_config.yaml.local"]' "$VALUES" | yq '.cscli.hub_branch')" = master ]
  # The parser's file, as the agent mounts it, holds the tree's name, selects the acquisition's
  # label and reads only keys the proxies' access log writes, the EnvoyProxy's as built, and none
  # that names the query string or the client's own x-forwarded-for; it takes the client address
  # only from a connection that carried a header.
  parser="$BATS_TEST_TMPDIR/parser.yaml"
  mounted crowdsec-agent /etc/crowdsec/parsers/s01-parse/envoy-gateway-json.yaml >"$parser"
  [ -s "$parser" ]
  [ "$(yq 'keys | sort | join(",")' "$parser")" = description,filter,name,nodes,onsuccess,statics ]
  [[ "$(yq '.name' "$parser")" == k8s-gitops/* ]]
  [[ "$(yq '.filter' "$parser")" == *"evt.Line.Labels.type == 'envoy-gateway-json'"* ]]
  keys="$(yq -N '.spec.telemetry.accessLog.settings[0].format.json | keys | .[]' "$proxy" | LC_ALL=C sort)"
  file="$BATS_TEST_TMPDIR/used-keys"
  # Every call, whatever its quoting and spacing, reads a literal key of the one line; a call that
  # does not is left whole in the list and fails the first check below.
  grep -oE 'JsonExtract\([^)]*\)' "$parser" |
    sed -E "s/^JsonExtract\(evt\.Line\.Raw,[[:space:]]*(['\"])([a-z_]*)\1\)$/\2/" | LC_ALL=C sort -u >"$file"
  [ -s "$file" ]
  [ -z "$(grep -vx '[a-z_]*' "$file" || true)" ]
  [ -z "$(LC_ALL=C comm -23 "$file" <(echo "$keys"))" ]
  for key in client_address peer_address host method path status; do grep -qx "$key" "$file"; done
  [ -z "$(grep -iE 'query|forwarded' "$file" || true)" ]
  # What a decision names and what the scenarios count, each written by exactly one static: the
  # address is the client's, which Envoy took from the PROXY protocol header, never the connection's
  # own peer, an edge router's; the host, the path and the status are their own keys. A static is
  # read as the field it writes, whether named by meta, parsed or target, and its expression.
  statics="$(yq -o json -I0 '.statics' "$parser" | jq -r '.[]
      | ((if .meta then "evt.Meta." + .meta elif .parsed then "evt.Parsed." + .parsed else .target end)
        + " = " + (.expression // ("\"" + (.value // "" | tostring) + "\"")))
      | select(test("^evt\\.Meta\\.(source_ip|target_fqdn|http_path|http_status) = "))' | LC_ALL=C sort)"
  echo "$statics"
  [ "$statics" = "$(printf '%s\n' \
    "evt.Meta.http_path = JsonExtract(evt.Line.Raw, 'path')" \
    "evt.Meta.http_status = JsonExtract(evt.Line.Raw, 'status')" \
    "evt.Meta.source_ip = JsonExtract(evt.Line.Raw, 'client_address')" \
    "evt.Meta.target_fqdn = JsonExtract(evt.Line.Raw, 'host')")" ]
  # One child node, which whitelists a line whose client address is the connection's own peer: a
  # connection that carried no header, which names no client.
  whitelist="JsonExtract(evt.Line.Raw, 'client_address') == JsonExtract(evt.Line.Raw, 'peer_address')"
  [ "$(yq -o json -I0 '.nodes' "$parser" | jq -c 'map(.whitelist |= del(.reason))')" \
    = "$(jq -cn --arg whitelist "$whitelist" '[{"whitelist": {"expression": [$whitelist]}}]')" ]
  [ -n "$(yq '.nodes[0].whitelist.reason // ""' "$parser")" ]
  # Each scenario, as the agent mounts it, is the tree's own and reads what the parser writes: its
  # filter, the bucket it pours an event into, the client's address alone or with the host asked,
  # what it counts once, its capacity and its leak are the ones below, and its row of the docs'
  # table, whole, is the one they make with the words below for what the filter counts. It has no
  # field besides these, its name, its description and its labels: no scope, so an overflow is of
  # the address the parser wrote, and no data, so it reads no file.
  [ "$(docs_rows '| Scenario | Counts | In a bucket per | Overflows above | Leaks one every |' | wc -l)" -eq 3 ]
  # The scenario's file, its bucket, what it counts once, its capacity, its leak, the docs' words
  # for what it counts, and its filter.
  mapfile -t rows <<'E'
http-probing|evt.Meta.source_ip + '/' + evt.Meta.target_fqdn|evt.Meta.http_path|10|10s|distinct paths answered with 400, 403 or 404, static files left out|evt.Meta.service == 'http' && evt.Meta.http_status in ['400', '403', '404'] && evt.Parsed.static_ressource == 'false'
http-sensitive-paths|evt.Meta.source_ip|evt.Meta.http_path|3|30s|distinct paths of the kind scanners ask for first, `.env`, `.git`, `wp-login.php`, `xmlrpc.php` and the like|evt.Meta.service == 'http' && evt.Meta.http_path matches '(?i)(^|/)(\\.env|\\.git(/|$)|\\.svn|\\.hg|\\.aws|\\.ssh|\\.ds_store|wp-login\\.php|wp-admin|xmlrpc\\.php|phpmyadmin|phpinfo\\.php|id_rsa|etc/passwd|cgi-bin)'
http-auth-failures|evt.Meta.source_ip + '/' + evt.Meta.target_fqdn|-|10|30s|answers with 401|evt.Meta.service == 'http' && evt.Meta.http_status == '401'
E
  for expected in "${rows[@]}"; do
    IFS='|' read -r file groupby distinct capacity leakspeed counts filter <<<"$expected"
    scenario="$(mounted crowdsec-agent "/etc/crowdsec/scenarios/$file.yaml" | yq -o json -I0 '.')"
    echo "$scenario"
    [ "$(wc -l <<<"$scenario")" -eq 1 ]
    [ "$(jq -r '.name' <<<"$scenario")" = "k8s-gitops/$file" ]
    [ "$(jq -r 'keys - ["distinct"] | join(",")' <<<"$scenario")" = blackhole,capacity,description,filter,groupby,labels,leakspeed,name,type ]
    [ "$(jq -r '[.type, .groupby, (.distinct // "-"), (.capacity | tostring), .leakspeed, .blackhole, (.labels.remediation | tostring)] | join("|")' <<<"$scenario")" \
      = "leaky|$groupby|$distinct|$capacity|$leakspeed|5m|true" ]
    [ "$(jq -r '.filter' <<<"$scenario")" = "$filter" ]
    # A scenario that counts a path once says so in the docs, and one that does not, does not.
    [[ $distinct == evt.Meta.http_path && $counts == "distinct paths "* ]] || [[ $distinct == - && $counts != *distinct* ]]
    per=client
    [ "$groupby" = evt.Meta.source_ip ] || per="client and host"
    row="$(docs_rows '| Scenario | Counts | In a bucket per | Overflows above | Leaks one every |' | grep -F "| \`k8s-gitops/$file\` |" | sed -E 's/^ +//' || true)"
    [ "$row" = "| \`k8s-gitops/$file\` | $counts | $per | $capacity | $leakspeed |" ] ||
      { echo "the docs' row is not the scenario k8s-gitops/$file, which counts $counts, per $per, overflows above $capacity and leaks one every $leakspeed: ${row:-no row}"; return 1; }
  done
  # One agent, as a Deployment: a pod per node would each tail every proxy and decide on the same
  # lines. No pod of the release reads a path of the node, and the agent has the service account
  # the tree makes.
  [ "$(yq -N 'select(.kind == "DaemonSet") | .metadata.name' "$RENDERED" | wc -l)" -eq 0 ]
  [ "$(yq -N 'select(.kind == "Deployment" and .metadata.name == "crowdsec-agent") | .spec.replicas' "$RENDERED")" -eq 1 ]
  [ -z "$(yq -N 'select(.kind == "Deployment" or .kind == "DaemonSet") | .spec.template.spec.volumes[]? | select(has("hostPath")) | .name' "$RENDERED")" ]
  [ "$(yq -N 'select(.kind == "Deployment" and .metadata.name == "crowdsec-agent") | .spec.template.spec.serviceAccountName' "$RENDERED")" = crowdsec-agent ]
  [ "$(yq -N 'select(.kind == "ServiceAccount" and .metadata.name == "crowdsec-agent") | .metadata.namespace' "$APP_BUILT")" = crowdsec ]
  # The grant: one Role and its binding, in the proxies' namespace, to list and watch its pods and
  # read their logs, each rule's whole list of resources and nothing besides its groups, resources
  # and verbs, bound to the agent's account alone. The application and its chart hold no role or
  # binding of their own, of the namespace or of the cluster.
  built crowdsec-gateway-logs
  [ "$(yq -N 'select(.kind != null) | .kind + "/" + .metadata.namespace + "/" + .metadata.name' "$BUILT" | LC_ALL=C sort | paste -sd, -)" \
    = "Role/$proxy_namespace/crowdsec-agent-gateway-logs,RoleBinding/$proxy_namespace/crowdsec-agent-gateway-logs" ]
  [ "$(only "$BUILT" Role)" = crowdsec-agent-gateway-logs ]
  [ "$(yq -N 'select(.kind == "Role") | .rules | map((.resources | join("+")) + ":" + (.verbs | sort | join("+")) + ":" + (.apiGroups | join("+")))
    | sort | join(",")' "$BUILT")" = "pods/log:get:,pods:get+list+watch:" ]
  [ "$(yq -N 'select(.kind == "Role") | .rules | map(keys | sort | join("+")) | unique | join(",")' "$BUILT")" = apiGroups+resources+verbs ]
  [ "$(yq -N 'select(.kind == "RoleBinding") | .subjects | map(.kind + "/" + .namespace + "/" + .name) | join(",")' "$BUILT")" = ServiceAccount/crowdsec/crowdsec-agent ]
  [ "$(yq -N 'select(.kind == "RoleBinding") | .roleRef.kind + "/" + .roleRef.name' "$BUILT")" = Role/crowdsec-agent-gateway-logs ]
  [ -z "$(yq -N 'select(.kind == "Role" or .kind == "RoleBinding" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding") | .kind + "/" + .metadata.name' "$RENDERED" "$APP_BUILT")" ]
  [ -z "$(yq -N 'select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding") | .metadata.name' "$BUILT")" ]
  # Among what every application of the overlay builds, that binding is the only one, of a
  # namespace or of the cluster, that names the agent's account or the accounts of its namespace:
  # by the account, by its user name, or by a group it is in, its namespace's accounts, every
  # account, or every caller the API server authenticates.
  every_build
  [ "$(yq -N -o json -I0 'select(.kind == "RoleBinding" or .kind == "ClusterRoleBinding")' "$EVERY" | jq -r '
      . as $binding | select(any(.subjects[]?;
        (.kind == "ServiceAccount" and .name == "crowdsec-agent" and (.namespace // $binding.metadata.namespace) == "crowdsec")
        or (.kind == "User" and .name == "system:serviceaccount:crowdsec:crowdsec-agent")
        or (.kind == "Group" and (.name | IN("system:serviceaccounts:crowdsec", "system:serviceaccounts", "system:authenticated")))))
      | .kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' | LC_ALL=C sort | paste -sd, -)" \
    = "RoleBinding/$proxy_namespace/crowdsec-agent-gateway-logs" ]
  # The image is pinned by digest, and every container of the render runs it.
  [[ "$(yq '.image.tag' "$VALUES")" =~ ^v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]
  [ -z "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec | [.containers[], .initContainers[]?] | .[].image | select(test("@sha256:[0-9a-f]{64}$") | not)' "$RENDERED")" ]
  # Renovate proposes the image and the chart and merges neither by itself: a rule that comes after
  # the auto-merge switch, so that it wins over it, holds back the files Renovate reads the two
  # pins from, and no rule after the switch turns merging on again, for them or for anything.
  rules="$(grep -v '^[[:space:]]*//' "$REPO/.renovate/automerge.json5" | yq -o json -I0 '.packageRules')"
  [ "$(jq -r '(map(.matchFileNames == ["kubernetes/**"] and .matchUpdateTypes == ["minor", "patch"] and has("automerge")) | index(true)) as $switch
    | if $switch == null then error("the auto-merge switch is not a rule of the file") else . end
    | to_entries | map(select(.key > $switch and .value.automerge == false and .value.matchFileNames == ["kubernetes/apps/base/crowdsec/**"]
        and ((.value | keys) - ["automerge", "description", "matchFileNames"] | length) == 0)) | length' <<<"$rules")" -eq 1 ]
  [ "$(jq -r '(map(.matchFileNames == ["kubernetes/**"] and .matchUpdateTypes == ["minor", "patch"] and has("automerge")) | index(true)) as $switch
    | .[$switch + 1:] | map(select(has("automerge") and .automerge != false)) | length' <<<"$rules")" -eq 0 ]
  image="$(yq '.image.repository' "$VALUES")"
  held="$(awk -F'\t' -v image="$image" '$3 == image || ($2 == "flux" && $3 == "crowdsec") {print $1}' "$REPO/.renovate/extracted.tsv" | LC_ALL=C sort -u)"
  echo "$held"
  [ "$(wc -l <<<"$held")" -eq 2 ]
  [ -z "$(grep -v '^kubernetes/apps/base/crowdsec/' <<<"$held" || true)" ]
}

# It runs CrowdSec's image, so it needs docker; the tools container of just ci has none, and there
# it checks the sample lines, which needs none, and skips the rest, saying so.
@test "The parser and scenarios decide on a client that probes, scans or fails to sign in, and never on a connection without a client address" {
  local fixture format offender image dir file decisions removed lookups
  # The sample lines are in the form the proxies write: each access log line has the keys of the
  # EnvoyProxy's format as Flux applies it, and its status is a number, as Envoy's JSON format
  # writes a response code.
  fixture="$REPO/tests/fixtures/crowdsec/access.log"
  built gateway-public
  format="$(yq -o json -I0 'select(.kind == "EnvoyProxy" and .metadata.name == "public") | .spec.telemetry.accessLog.settings[0].format.json | keys' "$BUILT")"
  [ "$(jq 'length' <<<"$format")" -gt 0 ]
  grep -F '"client_address"' "$fixture" |
    jq -s -e --argjson keys "$format" 'length > 0 and all(.[]; keys == ($keys | sort) and (.status | type) == "number")'
  # The bystander's lines lie among each offender's, after its first and before its last, so a
  # bucket that more than one client filled would hold both.
  for offender in 203.0.113.7 203.0.113.8 203.0.113.9; do
    grep -F '"client_address"' "$fixture" | jq -r '.client_address' | awk -v offender="$offender" -v bystander=203.0.113.11 '
      $0 == offender {if (!first) first = NR; last = NR}
      $0 == bystander {at[NR] = 1}
      END {for (line in at) if (line + 0 > first && line + 0 < last) among = 1; exit !(first && among)}'
  done
  command -v docker >/dev/null && docker info >/dev/null 2>&1 || skip "needs docker, which runs the CrowdSec image with no network"
  render
  image="$(object "$RENDERED" Deployment crowdsec-agent | yq '.spec.template.spec.containers[0].image')"
  dir="$BATS_TEST_TMPDIR/crowdsec"
  mkdir -p "$dir"
  # The parser and the scenarios as the agent's container mounts them.
  mounted crowdsec-agent /etc/crowdsec/parsers/s01-parse/envoy-gateway-json.yaml >"$dir/parser.yaml"
  for file in $(mounts crowdsec-agent | sed -n 's#^/etc/crowdsec/scenarios/\([^ ]*\) ConfigMap$#\1#p'); do
    mounted crowdsec-agent "/etc/crowdsec/scenarios/$file" >"$dir/scenario-$file"
  done
  [ -s "$dir/parser.yaml" ]
  [ "$(find "$dir" -name 'scenario-*.yaml' -size +0 | wc -l)" -eq 3 ]
  cp "$fixture" "$REPO/tests/fixtures/crowdsec/decide.sh" "$dir/"
  # The post-overflow items the agent's pod removes, by the variable it sets.
  removed="$(object "$RENDERED" Deployment crowdsec-agent | yq '.spec.template.spec.containers[0].env[] | select(.name == "DISABLE_POSTOVERFLOWS") | .value')"
  decisions="$(docker run --rm --network none -e DISABLE_POSTOVERFLOWS="$removed" -v "$dir":/t:ro --entrypoint sh "$image" /t/decide.sh)"
  echo "$decisions"
  # The probing client, the scanning one and the one that fails to sign in, each with its scenario
  # and a ban of its own address for the four hours of the image's profile, and no one else: not the
  # client whose few failed requests lie among theirs, which a bucket shared by a host's clients
  # would decide on with them.
  [ "$(jq -r '[.decisions[].decisions[]? | .type + " " + .scope + " " + .value + " " + .scenario] | sort | join(",")' <<<"$decisions")" \
    = "ban Ip 203.0.113.7 k8s-gitops/http-probing,ban Ip 203.0.113.8 k8s-gitops/http-sensitive-paths,ban Ip 203.0.113.9 k8s-gitops/http-auth-failures" ]
  [ -z "$(jq -r '.decisions[].decisions[]? | .duration | select(test("^(4h|3h59m)") | not)' <<<"$decisions")" ]
  # The overflows of those three addresses make no reverse DNS lookup, which would send each decided
  # address to the cluster's resolver and out of the cluster.
  [ "$(jq -r '.postoverflows' <<<"$decisions")" = crowdsecurity/cdn-whitelist,crowdsecurity/google-special-crawlers-whitelist ]
  [ "$(jq -r '.reverse_dns' <<<"$decisions")" -eq 0 ]
  # The agent's own start, as its pod starts it, with no network: the one name any process looks up
  # is the local API's, whose login ends a start that has no network. Its entrypoint fetches nothing
  # from the hub, asks for no version and falls back to no hub update.
  agent_start
  lookups="$(sed -n 's/^go package net: hostLookupOrder(\(.*\)) = .*$/\1/p' "$BATS_TEST_TMPDIR/agent-start.log" | LC_ALL=C sort -u)"
  echo "names looked up: ${lookups:-none}"
  tail -n 5 "$BATS_TEST_TMPDIR/agent-start.log"
  [ "$lookups" = "$(jq -r '.containers[0].env[] | select(.name == "LOCAL_API_URL") | .value' "$BATS_TEST_TMPDIR/agent-spec.json" | sed -E 's#^https?://([^:/]+).*$#\1#')" ]
  [ -z "$(grep -i 'hub update' "$BATS_TEST_TMPDIR/agent-start.log" | grep -v '^Skipping hub update, index file is not in a volume$' || true)" ]
  # The local API's own start, as its pod starts it, with no network, no capability, an empty volume
  # for each claim and stand-ins of the form the generators make for the two secrets: it answers the
  # health endpoint the kubelet probes, and the one name any of its processes looks up is the
  # loopback's, where the log processor that the chart's script starts beside the API logs in. That
  # log processor loads one acquisition file, the image's own, whose one source matches no file, so
  # it reads no line; the start updates nothing from the hub; and the profiles the container holds,
  # the image's, name no notification.
  lapi_start
  lookups="$(sed -n 's/^go package net: hostLookupOrder(\(.*\)) = .*$/\1/p' "$BATS_TEST_TMPDIR/lapi-start.log" | LC_ALL=C sort -u)"
  echo "names the local API looked up: ${lookups:-none}"
  tail -n 5 "$BATS_TEST_TMPDIR/lapi-start.log"
  [ "$(cat "$BATS_TEST_TMPDIR/lapi-health")" = '{"status":"up"}' ]
  [ "$lookups" = localhost ]
  [ "$lookups" = "$(jq -r '.containers[0].env[] | select(.name == "LOCAL_API_URL") | .value' "$BATS_TEST_TMPDIR/lapi-spec.json" | sed -E 's#^https?://([^:/]+).*$#\1#')" ]
  [ "$(grep -c 'msg="loading acquisition file : ' "$BATS_TEST_TMPDIR/lapi-start.log")" -eq 1 ]
  [ "$(grep -c 'msg="Configuring datasource"' "$BATS_TEST_TMPDIR/lapi-start.log")" -eq 1 ]
  [ "$(grep -c 'msg="No matching files for pattern ' "$BATS_TEST_TMPDIR/lapi-start.log")" -eq 1 ]
  [ -z "$(grep -i 'hub update' "$BATS_TEST_TMPDIR/lapi-start.log" || true)" ]
  [ "$(LC_ALL=C sort -u "$BATS_TEST_TMPDIR/lapi-notifications")" = 0 ]
}

@test "CrowdSec sends nothing about the cluster's traffic outside the cluster" {
  local policy row call variable state line path secrets generators url api lapi_metrics agent_metrics flow want side from to port
  local agent lapi resolver prometheus monitoring proxies other stray impostor workload probes probe
  render
  # The pods of the release are the local API's and the agent's, a Deployment of one container
  # each, and those of the chart's two Helm tests, which the release does not run (below): what
  # follows reads every pod there is. The one init container is the chart's own in the agent's pod,
  # which waits for the local API and registers with it; the local API's pod has none.
  [ "$(yq -N 'select(.kind == "Pod" or .spec.template.spec.containers != null or .spec.jobTemplate != null) | .kind + "/" + .metadata.name' "$RENDERED" | LC_ALL=C sort | paste -sd, -)" \
    = Deployment/crowdsec-agent,Deployment/crowdsec-lapi,Pod/crowdsec-test-agent,Pod/crowdsec-test-lapi-up ]
  [ "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers | length' "$RENDERED" | paste -sd, -)" = 1,1 ]
  [ "$(yq -N 'select(.kind == "Deployment") | .metadata.name + ":" + ([.spec.template.spec.initContainers[]?.name] | join("+"))' "$RENDERED" | LC_ALL=C sort | paste -sd, -)" \
    = crowdsec-agent:wait-for-lapi-and-register,crowdsec-lapi: ]
  # The local API turns the Central API off by the variable the image reads, which stops its
  # registration, its signals, its metrics, its community blocklist and every call to the console;
  # nothing enrols it and nothing is shared by configuration.
  [ "$(yq -N 'select(.kind == "Deployment" and .metadata.name == "crowdsec-lapi") | .spec.template.spec.containers[0].env[] | select(.name == "DISABLE_ONLINE_API") | .value' "$RENDERED")" = true ]
  [ "$(yq -N 'select(.kind == "Deployment" and .metadata.name == "crowdsec-agent") | .spec.template.spec.containers[0].env[] | select(.name == "DISABLE_ONLINE_API") | .value' "$RENDERED")" = true ]
  [ -z "$(env_names "$RENDERED" Deployment crowdsec-lapi | grep -E '^(ENROLL_|CAPI|ONLINE|CONSOLE|SHARE)' || true)" ]
  [ -z "$(env_names "$RENDERED" Deployment crowdsec-agent | grep -E '^(ENROLL_|CAPI|ONLINE|CONSOLE|SHARE)' || true)" ]
  [ -z "$(yq '.config["console.yaml"] // ""' "$VALUES")" ]
  [ -z "$(yq '.config["capi_whitelists.yaml"] // ""' "$VALUES")" ]
  [ "$(yq '.lapi.envFrom // [] | length' "$VALUES")" -eq 0 ]
  [ "$(yq '.agent.envFrom // [] | length' "$VALUES")" -eq 0 ]
  # What the local API's container mounts, and nothing else: the chart's start script, its two
  # claims and its configuration. No profile of the release's replaces the image's and no
  # notification plugin is given settings; the configuration over the image's holds the agents'
  # registration and nothing else, so no key for CrowdSec's threat intelligence service, as the
  # agent's holds none, and no parser or scenario the agent mounts calls that service or looks a
  # name up.
  mounts crowdsec-lapi
  [ "$(mounts crowdsec-lapi)" = "$(printf '%s\n' \
    "/docker_start.sh ConfigMap" \
    "/etc/crowdsec_data claim" \
    "/etc/crowdsec_data/config.yaml.local ConfigMap" \
    "/var/lib/crowdsec/data claim")" ]
  [ -z "$(yq '.config["profiles.yaml"] // ""' "$VALUES")" ]
  [ "$(yq '(.config.notifications // {}) | to_entries | map(select(.value != null and .value != "")) | length' "$VALUES")" -eq 0 ]
  [ "$(mounted crowdsec-lapi /etc/crowdsec_data/config.yaml.local | yq -o json -I0 'del(.api.server.auto_registration)')" = '{"api":{"server":{}}}' ]
  [ "$(mounted crowdsec-agent /etc/crowdsec/config.yaml.local | yq -o json -I0 '.')" = '{"cscli":{"hub_branch":"master"}}' ]
  for path in $(mounts crowdsec-agent | sed -n 's#^\(/etc/crowdsec/\(parsers\|scenarios\)/[^ ]*\) ConfigMap$#\1#p'); do
    [ -z "$(mounted crowdsec-agent "$path" | grep -E 'CrowdsecCTI|LookupHost' || true)" ]
  done
  # The chart's hooks, which register the instance with the Central API and keep the credentials
  # in a Secret, are not rendered; the only hooks are its two Helm tests, which pull an image with no
  # tag and the release excludes by name, and no Job, CronJob or Secret is.
  [ -z "$(yq -N 'select(.kind == "Job" or .kind == "CronJob" or .kind == "Secret") | .metadata.name' "$RENDERED")" ]
  [ "$(yq -N 'select(.metadata.annotations["helm.sh/hook"] != null) | .metadata.annotations["helm.sh/hook"] + " " + .metadata.name' "$RENDERED" | LC_ALL=C sort | paste -sd, -)" \
    = "test crowdsec-test-agent,test crowdsec-test-lapi-up" ]
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.test.filters | map(select(.exclude) | .name) | sort | join(",")' "$APP_BUILT")" = crowdsec-test-agent,crowdsec-test-lapi-up ]
  [ -z "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec | [.containers[], .initContainers[]?] | .[].image | select(test(":latest$"))' "$RENDERED")" ]
  # The secrets the local API and its agent share are made in the cluster, never in the tree: every
  # key of a Secret that a pod of the release reads is of the one Secret an ExternalSecret of the
  # application makes, once, from the application's own Password generators and nothing else, which
  # make exactly those keys, with no template of its own for what the Secret holds; neither the
  # application nor its chart holds a Secret, and no pod reads one whole.
  secrets="$(yq -N -o json -I0 'select(.kind == "Deployment") | .spec.template.spec | [.containers[], .initContainers[]?] | .[] | .env[]? | .valueFrom.secretKeyRef | select(. != null)' "$RENDERED" |
    jq -rs 'map(.name + "/" + .key) | unique | join(",")')"
  [ "$secrets" = crowdsec-lapi-secrets/csLapiSecret,crowdsec-lapi-secrets/registrationToken ]
  [ -z "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec
    | ([.containers[], .initContainers[]?] | .[] | select(has("envFrom")) | "envFrom of " + .name), (.volumes[]? | select(has("secret") or has("projected")) | "volume " + .name)' "$RENDERED")" ]
  [ "$(yq -N 'select(.kind == "ExternalSecret") | .metadata.name + " " + .spec.target.name + " " + .spec.refreshPolicy + " " + (.spec | keys | sort | join("+"))
    + " " + (.spec.target | keys | sort | join("+"))' "$APP_BUILT")" = "crowdsec-lapi-secrets crowdsec-lapi-secrets CreatedOnce dataFrom+refreshPolicy+target creationPolicy+name" ]
  generators="$(yq -N -o json -I0 'select(.kind == "ExternalSecret") | .spec.dataFrom' "$APP_BUILT" |
    jq -r 'map(if (keys == ["sourceRef"]) and (.sourceRef | keys == ["generatorRef"]) then .sourceRef.generatorRef | .kind + "/" + .name else "not a generator: " + tojson end) | sort | join(",")')"
  [ "$generators" = Password/crowdsec-lapi-secret,Password/crowdsec-registration-token ]
  [ "$(yq -N 'select(.kind == "Password") | .metadata.name + ":" + (.spec.secretKeys | join("+"))' "$APP_BUILT" | LC_ALL=C sort | paste -sd, -)" \
    = "crowdsec-lapi-secret:csLapiSecret,crowdsec-registration-token:registrationToken" ]
  [ -z "$(yq -N 'select(.kind == "Secret") | .metadata.name' "$APP_BUILT" "$RENDERED")" ]
  # The agent removes the post-overflow items that look up an address's name, which would send every
  # decided address to the resolver and out of the cluster.
  [ "$(yq -N 'select(.kind == "Deployment" and .metadata.name == "crowdsec-agent") | .spec.template.spec.containers[0].env[] | select(.name == "DISABLE_POSTOVERFLOWS") | .value' "$RENDERED")" \
    = "crowdsecurity/rdns crowdsecurity/seo-bots-whitelist" ]
  [ -z "$(env_names "$RENDERED" Deployment crowdsec-lapi | grep POSTOVERFLOWS || true)" ]
  # The pods' flows, as Flux applies the policies, overlay patches included: the local API sends
  # nothing; the agent sends to the cluster's resolver, the local API's pods and the Kubernetes API,
  # and to no address, name or entity outside the cluster other than those.
  policy="$BATS_TEST_TMPDIR/policies.yaml"
  yq 'select(.kind == "CiliumNetworkPolicy")' "$APP_BUILT" >"$policy"
  [ "$(yq -N '.metadata.name' "$policy" | LC_ALL=C sort | paste -sd, -)" = crowdsec-agent,crowdsec-lapi ]
  [ "$(yq -N 'select(.metadata.name == "crowdsec-lapi") | .spec.egress // [] | length' "$policy")" -eq 0 ]
  [ "$(yq -N 'select(.metadata.name == "crowdsec-agent") | .spec.egress | map(
      ((.toEndpoints // [] | map(.matchLabels["k8s:k8s-app"] // (.matchLabels["k8s-app"] + "/" + .matchLabels.type)) | join("+"))
       + (.toEntities // [] | join("+")))
      + ":" + (.toPorts[0].ports | map(.port) | unique | join("+"))) | sort | join(",")' "$policy")" \
    = "crowdsec/lapi:8080,kube-apiserver:443+6443,kube-dns:53" ]
  [ -z "$(grep -E 'toCIDR|toServices|toGroups|toFQDNs|matchName|matchPattern|rules:|world|0\.0\.0\.0' "$policy" | grep -v '^[[:space:]]*#' || true)" ]
  # Every rule of the two policies, in both directions, and no other: what each pod takes and what
  # it sends, by its peers and its ports. A policy with a second list of specs, a deny rule, a peer
  # by address, name or service, or a port range fails here, as the reading does not skip it.
  allows "$policy"
  [ "$(allows "$policy")" = "$(printf '%s\n' \
    "crowdsec-agent [k8s-app=crowdsec,type=agent] sends to @kube-apiserver on 443/TCP+6443/TCP" \
    "crowdsec-agent [k8s-app=crowdsec,type=agent] sends to io.kubernetes.pod.namespace=crowdsec,k8s-app=crowdsec,type=lapi on 8080/TCP" \
    "crowdsec-agent [k8s-app=crowdsec,type=agent] sends to io.kubernetes.pod.namespace=kube-system,k8s-app=kube-dns on 53/TCP+53/UDP" \
    "crowdsec-agent [k8s-app=crowdsec,type=agent] takes @host on 6060/TCP" \
    "crowdsec-agent [k8s-app=crowdsec,type=agent] takes app.kubernetes.io/name=prometheus,io.kubernetes.pod.namespace=monitoring on 6060/TCP" \
    "crowdsec-lapi [k8s-app=crowdsec,type=lapi] takes @host on 8080/TCP" \
    "crowdsec-lapi [k8s-app=crowdsec,type=lapi] takes app.kubernetes.io/name=prometheus,io.kubernetes.pod.namespace=monitoring on 6060/TCP" \
    "crowdsec-lapi [k8s-app=crowdsec,type=lapi] takes io.kubernetes.pod.namespace=crowdsec,k8s-app=crowdsec,type=agent on 8080/TCP")" ]
  # Those rules against what the chart renders, evaluated as Cilium decides a flow, over every
  # policy that can select a pod of the namespace, of either kind, the namespace's own and any of
  # the whole cluster, among what the overlay's applications build, where the namespace's own are
  # those two alone, and among what the overlay builds itself, where they are the default deny
  # alone, with every namespace's labels: the pods by the labels of their templates, and the ports
  # read from the render, the one of the local API's Service that the agent's address names, the one
  # each monitor scrapes and the ones the kubelet probes. A flow from or to a pod of CrowdSec is
  # asked of that pod's side alone, so that the answer is its own policies' and not the peer's.
  FLOWS="$BATS_TEST_TMPDIR/flows"
  mkdir -p "$FLOWS"
  every_build
  NAMESPACE="$RELEASE_NAMESPACE" yq 'select(.kind == "CiliumClusterwideNetworkPolicy"
    or ((.kind == "CiliumNetworkPolicy" or .kind == "NetworkPolicy") and .metadata.namespace == strenv(NAMESPACE)))' "$EVERY" >"$FLOWS/applications.yaml"
  [ "$(NAMESPACE="$RELEASE_NAMESPACE" yq -N 'select(.metadata.namespace == strenv(NAMESPACE)) | .kind + "/" + .metadata.name' "$FLOWS/applications.yaml" | LC_ALL=C sort | paste -sd, -)" \
    = CiliumNetworkPolicy/crowdsec-agent,CiliumNetworkPolicy/crowdsec-lapi ]
  NAMESPACE="$RELEASE_NAMESPACE" yq 'select(.kind == "Namespace" or .kind == "CiliumClusterwideNetworkPolicy"
    or ((.kind == "CiliumNetworkPolicy" or .kind == "NetworkPolicy") and .metadata.namespace == strenv(NAMESPACE)))' "$OVERLAY" >"$FLOWS/overlay.yaml"
  [ "$(NAMESPACE="$RELEASE_NAMESPACE" yq -N 'select(.metadata.namespace == strenv(NAMESPACE) or (.kind == "Namespace" and .metadata.name == strenv(NAMESPACE)))
    | .kind + "/" + .metadata.name' "$FLOWS/overlay.yaml" | LC_ALL=C sort | paste -sd, -)" = Namespace/crowdsec,NetworkPolicy/default-deny ]
  agent="$(pods crowdsec-agent)" lapi="$(pods crowdsec-lapi)"
  url="$(yq -N 'select(.kind == "Deployment" and .metadata.name == "crowdsec-agent") | .spec.template.spec.containers[0].env[] | select(.name == "LOCAL_API_URL") | .value' "$RENDERED")"
  [[ $url =~ ^http://([a-z0-9-]+)\.([a-z0-9-]+):([0-9]+)$ ]]
  [ "${BASH_REMATCH[2]}" = "$RELEASE_NAMESPACE" ]
  api="$(NAME="${BASH_REMATCH[1]}" PORT="${BASH_REMATCH[3]}" yq -N 'select(.kind == "Service" and .metadata.name == strenv(NAME)) | .spec.ports[] | select(.port == env(PORT)) | .targetPort' "$RENDERED")"
  lapi_metrics="$(scraped crowdsec-service)" agent_metrics="$(scraped crowdsec-agent-service)"
  echo "the local API's port $api, its metrics port $lapi_metrics, the agent's metrics port $agent_metrics"
  [[ $api =~ ^[0-9]+$ && $lapi_metrics =~ ^[0-9]+$ && $agent_metrics =~ ^[0-9]+$ && $api != "$lapi_metrics" ]]
  resolver='kube-system:k8s-app=kube-dns' prometheus='monitoring:app.kubernetes.io/name=prometheus'
  monitoring='monitoring:app.kubernetes.io/name=kube-state-metrics' proxies="envoy-gateway-system:$PROXY_LABELS"
  other='other:app.kubernetes.io/name=app' stray="$RELEASE_NAMESPACE:app.kubernetes.io/name=stray"
  impostor="other:${agent#*:}"
  local flows=(
    # The agent: the local API on its port, the resolver, the Kubernetes API, and nothing else.
    "reaches --reach $agent $lapi $api/tcp"
    "reaches --reach-egress $agent $resolver 53/udp"
    "reaches --reach-egress $agent $resolver 53/tcp"
    "reaches --reach-egress $agent @kube-apiserver 443/tcp"
    "reaches --reach-egress $agent @kube-apiserver 6443/tcp"
    "refused --reach-egress $agent $lapi $lapi_metrics/tcp"
    "refused --reach-egress $agent $resolver 9153/tcp"
    "refused --reach-egress $agent kube-system:k8s-app=hubble-relay 53/udp"
    "refused --reach-egress $agent @kube-apiserver 10250/tcp"
    "refused --reach-egress $agent @world 443/tcp"
    "refused --reach-egress $agent @world 80/tcp"
    "refused --reach-egress $agent @world 53/udp"
    "refused --reach-egress $agent @host 10250/tcp"
    "refused --reach-egress $agent @remote-node 10250/tcp"
    "refused --reach-egress $agent $proxies 10443/tcp"
    "refused --reach-egress $agent $prometheus 9090/tcp"
    "refused --reach-egress $agent $other 8080/tcp"
    "refused --reach-egress $agent $stray 8080/tcp"
    # The local API sends nothing.
    "refused --reach-egress $lapi $agent $agent_metrics/tcp"
    "refused --reach-egress $lapi $resolver 53/udp"
    "refused --reach-egress $lapi @kube-apiserver 6443/tcp"
    "refused --reach-egress $lapi @world 443/tcp"
    "refused --reach-egress $lapi @host 10250/tcp"
    "refused --reach-egress $lapi $prometheus 9090/tcp"
    "refused --reach-egress $lapi $other 8080/tcp"
    # The local API takes the agent on its port and Prometheus on its metrics port, and no one else.
    "reaches --reach-ingress $prometheus $lapi $lapi_metrics/tcp"
    "refused --reach-ingress $prometheus $lapi $api/tcp"
    "refused --reach-ingress $agent $lapi $lapi_metrics/tcp"
    "refused --reach-ingress $monitoring $lapi $lapi_metrics/tcp"
    "refused --reach-ingress $impostor $lapi $api/tcp"
    "refused --reach-ingress $stray $lapi $api/tcp"
    "refused --reach-ingress $proxies $lapi $api/tcp"
    "refused --reach-ingress $other $lapi $api/tcp"
    "refused --reach-ingress @world $lapi $api/tcp"
    "refused --reach-ingress @remote-node $lapi $api/tcp"
    "refused --reach-ingress @kube-apiserver $lapi $api/tcp"
    # The agent takes Prometheus on its metrics port, and no one else.
    "reaches --reach-ingress $prometheus $agent $agent_metrics/tcp"
    "refused --reach-ingress $lapi $agent $agent_metrics/tcp"
    "refused --reach-ingress $monitoring $agent $agent_metrics/tcp"
    "refused --reach-ingress $stray $agent $agent_metrics/tcp"
    "refused --reach-ingress $proxies $agent $agent_metrics/tcp"
    "refused --reach-ingress $other $agent $agent_metrics/tcp"
    "refused --reach-ingress @world $agent $agent_metrics/tcp"
    "refused --reach-ingress @remote-node $agent $agent_metrics/tcp"
  )
  for flow in "${flows[@]}"; do
    read -r want side from to port <<<"$flow"
    "$want" "$side" "$from" "$to" "$port"
  done
  # The kubelet reaches each port a probe of either pod names, and no other port of it.
  for flow in "crowdsec-lapi $lapi $lapi_metrics" "crowdsec-agent $agent $api"; do
    read -r workload to port <<<"$flow"
    probes="$(probed "$workload")"
    echo "the kubelet probes $workload on: $probes"
    [[ $probes =~ ^[0-9]+( [0-9]+)*$ && " $probes " != *" $port "* ]]
    for probe in $probes; do
      reaches --reach-ingress @host "$to" "$probe/tcp"
    done
    refused --reach-ingress @host "$to" "$port/tcp"
  done
  # Every outbound call is a row of the docs' table, with its state.
  crowdsec_docs | grep -qF '| Call | What leaves | Variable | State |'
  [ "$(docs_rows '| Call | What leaves | Variable | State |' | wc -l)" -eq 10 ]
  for call in "Central API registration|DISABLE_ONLINE_API|off" "Signals to the Central API|DISABLE_ONLINE_API|off" \
    "Metrics to the Central API|DISABLE_ONLINE_API|off" \
    "Community blocklist|DISABLE_ONLINE_API|off" "Console enrolment|ENROLL_KEY|off" "Version check|hub_branch|off" \
    "Reverse DNS lookups|DISABLE_POSTOVERFLOWS|off" "Hub index and items|hub_branch|not made" \
    "Notifications|config.notifications|off" "Threat intelligence lookups|api.cti|off"; do
    IFS='|' read -r row variable state <<<"$call"
    line="$(docs_rows '| Call | What leaves | Variable | State |' | grep -F "| $row |" || true)"
    [ -n "$line" ] || { echo "the docs' table has no row for: $row"; return 1; }
    grep -qF "$variable" <<<"$line" || { echo "the row $row does not name $variable"; return 1; }
    grep -qE "\\| $state \\|\$" <<<"$line" || { echo "the row $row is not $state: $line"; return 1; }
  done
}

@test "CrowdSec's decisions are listed and enforced by nothing, and the docs say what would enforce them" {
  local part
  render
  # Nothing acts on a decision: no bouncer is rendered, no object of the tree of a kind that calls a
  # service or runs a filter in a route's path (an external authorisation, a processor, a patch of
  # the proxy's configuration) names CrowdSec or a bouncer. Other external authorisations, the
  # sign-in's, are none of its business.
  [ "$(yq -N '.kind' "$RENDERED" | LC_ALL=C sort -u | paste -sd, -)" = ConfigMap,Deployment,PersistentVolumeClaim,Pod,Service,ServiceMonitor ]
  [ -z "$(env_names "$RENDERED" Deployment crowdsec-lapi | grep -i bouncer || true)" ]
  [ -z "$(env_names "$RENDERED" Deployment crowdsec-agent | grep -i bouncer || true)" ]
  [ -z "$(yq '.tls.enabled // false | select(. == true)' "$VALUES")" ]
  [ -z "$(grep -rlE '^kind: (SecurityPolicy|BackendTrafficPolicy|EnvoyExtensionPolicy|EnvoyPatchPolicy)$' "$REPO/kubernetes" | xargs -r grep -liE 'crowdsec|bouncer' || true)" ]
  # The same of what Flux applies: among the objects every application of the overlay builds, the
  # sign-in's external authorisation included, none of the Gateway API's groups, a route, a policy,
  # a filter or a grant to refer across namespaces, names CrowdSec or a bouncer.
  every_build
  [ "$(yq -N 'select(.kind == "SecurityPolicy" and .spec.extAuth != null) | .metadata.name' "$EVERY" | wc -l)" -ge 1 ]
  [ -z "$(yq -N -o json -I0 'select((.apiVersion // "") | test("^gateway[.](networking[.]k8s|envoyproxy)[.]io/"))' "$EVERY" | grep -iE 'crowdsec|bouncer' |
    jq -r '.kind + "/" + (.metadata.namespace // "") + "/" + .metadata.name' || true)" ]
  [ "$(yq -N 'select(.kind == "Service") | .spec.type' "$RENDERED" | sort -u)" = ClusterIP ]
  # The docs' part says so, and says how to list and delete a decision.
  part="$(crowdsec_docs)"
  [ -n "$part" ]
  grep -qF 'Decisions are not enforced' <<<"$part"
  grep -qF 'cscli decisions list' <<<"$part"
  grep -qF 'cscli decisions delete' <<<"$part"
  grep -qF 'PROXY protocol' <<<"$part"
  grep -qF 'SecurityPolicy' <<<"$part"
  # A route takes one external authorisation, so a bouncer's would not combine with the sign-in's:
  # the sentences as the docs wrap them, read as one line.
  part="$(tr '\n' ' ' <<<"$part" | tr -s ' ')"
  grep -qF "Envoy Gateway applies one \`extAuth\` to a route" <<<"$part"
  grep -qF "An authorisation \`SecurityPolicy\` for a bouncer therefore does not combine with the sign-in's on a route" <<<"$part"
}
