#!/usr/bin/env bats
# Proves features/network-audit.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, kyverno, just, yq and jq on PATH (the versions pinned for the
# repository). The tests of the manifests build the application offline, with the placeholders of
# the cluster's example key lists, and render the tree once for the file, its charts pulled from
# their public registries: the Cilium chart's objects, Hubble Relay's among them, are read there.
# The tests of the recipe run it from a copy of the scripts with a kubeconfig of its own, a
# recording kubectl shaped like kubectl v1.37's output, which reads the operator's credential and
# forwards a port to vmauth, and a recording curl that answers through that forward as vmauth relays
# the store, so nothing reads this checkout's .env or reaches a cluster.
#
# The answer the recording curl gives for the store's query is the store's own.
# fixtures/network-audit/answer.jsonl is what VictoriaLogs, of the release victoria-logs-answers
# records below, the image the store's chart runs
# (victoriametrics/victoria-logs@sha256:ee4e820cac3721f5f5d91641b950c22439593adc4224f9655e5333d5a84c1dfe),
# returned to the recipe's query, asked as scripts/logs asks it, over the lines of
# fixtures/network-audit/bulk.ndjson inserted as the collector sends a pod's lines (the
# Elasticsearch bulk API with the sink's query arguments, fixtures/network-audit/bulk.args, the line
# whole in message, the recorder's namespace, pod, container and node in its stream): the 14 lines
# that the hubble of the agents' image, of the Cilium release hubble-flow-lines records below,
# printed on standard output with the recorder's arguments and --input-file - for the 15
# hand-written flows of fixtures/network-audit/flows.jsonl, one of them FORWARDED; the 2 lost-event
# records it printed there and the 2 node status records, a node's error and a node Relay could not
# reach, it printed on standard error for the hand-written records of
# fixtures/network-audit/records.jsonl, read without the verdicts, which the CLI applies to every
# record of a file while an agent and Relay pass such records whatever the request's filters, and of
# which it printed nothing for the nodes that connected; and the line of its own error when it
# cannot look Relay up, with a documentation address in the resolver's place. Beside them, a line of
# Falco's and one of a container of the same name in another namespace, which the query leaves out.
# The flows are written as an agent sends them under the recorder's mask, which the CLI does not
# apply to a file: an end on the reporting node with its workload, one of them on another node with
# its pod's name alone, the world with addresses of the documentation ranges in a cidr: label beside
# the reserved: one, and a pod's name with a control character. docs/kubernetes.md, The record of
# what policy drops, gives the proof's steps. A test that needs more than the store returned says so
# where it adds it; what the recording kubectl answers when it fails is shaped like kubectl v1.37's
# output, as in tests/logs.bats.
#
# The releases the fixture came from: the store's, which the store's image and its chart's
# appVersion are held to, and the Cilium release whose hubble printed the flow lines, which the
# recorder's image is held to. No manager moves them (.renovate/by-hand.tsv); when either moves on,
# the proof above is done again against the new release and the fixture replaced with its answer.
# victoria-logs-answers: v1.54.0
# hubble-flow-lines: v1.20.4

# The tests run one at a time even where bats runs a file's tests side by side: the tests on the
# tree share one render, made by whichever of them comes first.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

bats_require_minimum_version 1.5.0

setup_file() {
  # Helm's settings, and the Docker configuration it reads registry logins from, stay in the run's
  # own directory.
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG"
}

teardown() {
  local pid
  # A port-forward a failing recipe left behind is stopped here, so no test leaves one running.
  if [ -f "$BATS_TEST_TMPDIR/state/forwards" ]; then
    while read -r pid; do
      kill "$pid" 2>/dev/null || true
    done <"$BATS_TEST_TMPDIR/state/forwards"
  fi
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLUSTER="$REPO/kubernetes/clusters/lab-sto2"
  APP_DIR=kubernetes/apps/base/security-system/network-audit
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/network-audit"
  DOCS="$REPO/docs/kubernetes.md"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  EXAMPLE="$BATS_TEST_TMPDIR/example-vars.yaml"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$EXAMPLE"
  OVERLAY_DIR="$REPO/kubernetes/apps/overlays/lab-sto2"
  # The recorder's pods, as the evaluation of a flow names a workload of the render, and the pods
  # that no render holds: the resolver's, which Talos deploys, Prometheus', which its operator
  # makes, and the public Gateway's proxies, which Envoy Gateway makes.
  RECORDER=security-system/Deployment/network-audit
  DNS='kube-system:k8s-app=kube-dns'
  PROMETHEUS='monitoring:app.kubernetes.io/name=prometheus'
  PROXY='envoy-gateway-system:app.kubernetes.io/name=envoy,app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,gateway.envoyproxy.io/owning-gateway-name=public,gateway.envoyproxy.io/owning-gateway-namespace=envoy-gateway-system'
  # The fields the recorder asks Hubble for, and no other: what the recipe prints, and the time and
  # node name that the agents fill each record's own from.
  MASK='destination.labels destination.namespace destination.pod_name destination.workloads drop_reason_desc l4 node_name source.labels source.namespace source.pod_name source.workloads time traffic_direction uuid verdict'
  # The query the recipe has the store answer, whose answer the fixture holds.
  FIELDS='flow.verdict, flow.traffic_direction, flow.drop_reason_desc, flow.source.namespace, flow.source.pod_name, flow.source.workloads, flow.source.labels, flow.destination.namespace, flow.destination.pod_name, flow.destination.workloads, flow.destination.labels, flow.l4.TCP.destination_port, flow.l4.UDP.destination_port, flow.l4.SCTP.destination_port'
  RECORDER_LINES='{kubernetes.pod_namespace="security-system",kubernetes.container_name="hubble"}'
  STORE_QUERY="$RECORDER_LINES | unpack_json fields ($FIELDS) | stats by ($FIELDS) count() flows | sort by (flows desc)"
}

# overlay [DIR]: the lab-sto2 overlay as Flux reads it, its namespaces and the Kustomization of each
# enabled application. Writes $OVERLAY.
overlay() {
  OVERLAY="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "${1:-$OVERLAY_DIR}" >"$OVERLAY"
}

# object FILE KIND NAME: the one object of that kind and name in FILE.
object() {
  KIND="$2" NAME="$3" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$1"
}

# built: the network-audit application as Flux applies it on lab-sto2: the overlay's Kustomization
# of it, with the example key lists and its own substitutions over them, strictly, built in memory
# so that no file of this checkout is rewritten. Sets BUILT and KS, the Kustomization as built, and
# writes the Deployment to $DEPLOYMENT, its container hubble to $CONTAINER and the policy to
# $POLICY.
built() {
  local path
  overlay
  KS="$BATS_TEST_TMPDIR/network-audit-ks.yaml"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars
    | select(fileIndex == 1 and .kind == "Kustomization" and .metadata.name == "network-audit")
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "$EXAMPLE" "$OVERLAY" >"$KS"
  [ -s "$KS" ] || { echo "the lab-sto2 overlay does not enable network-audit"; return 1; }
  path="$(yq '.spec.path' "$KS")"
  BUILT="$BATS_TEST_TMPDIR/network-audit-built.yaml"
  (cd "$REPO" && flux build kustomization network-audit --path "./kubernetes/${path#./}" \
    --kustomization-file "$KS" --dry-run --strict-substitute --in-memory-build) >"$BUILT"
  DEPLOYMENT="$BATS_TEST_TMPDIR/deployment.yaml"
  CONTAINER="$BATS_TEST_TMPDIR/container.yaml"
  POLICY="$BATS_TEST_TMPDIR/policy.yaml"
  object "$BUILT" Deployment network-audit >"$DEPLOYMENT"
  [ -s "$DEPLOYMENT" ] || { echo "the application builds no Deployment network-audit"; return 1; }
  yq '.spec.template.spec.containers[] | select(.name == "hubble")' "$DEPLOYMENT" >"$CONTAINER"
  [ -s "$CONTAINER" ] || { echo "the pod has no container hubble"; return 1; }
  object "$BUILT" CiliumNetworkPolicy network-audit >"$POLICY"
  [ -s "$POLICY" ] || { echo "the application builds no CiliumNetworkPolicy network-audit"; return 1; }
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

# cilium_copy NAME: a copy of what the render holds of the Cilium application, in
# $BATS_TEST_TMPDIR/NAME/lab-sto2/cilium, for a test to change. Needs real_render first.
cilium_copy() {
  local to="$BATS_TEST_TMPDIR/$1/lab-sto2"
  mkdir -p "$to"
  cp -R "$REAL"/*/cilium "$to/cilium"
}

# relay RENDER: Hubble Relay as RENDER, a render of the tree, has it in the Cilium chart's objects:
# its Service, the one port the Service serves, the pods the Service selects and the container port
# its port targets in them. Sets RELAY_NAME, RELAY_NAMESPACE and RELAY_PORT, the Service's;
# RELAY_SELECTOR, the labels it selects pods by, as K=V,K=V; RELAY_PODS, the workload of those
# pods as the evaluation of a flow names it; RELAY_TARGET, the container port; and RELAY_OTHER, the
# other ports the pods' probes ask. Fails, saying what the recorder would then need, when Relay's
# server takes TLS.
relay() {
  local render=$1 service workloads workload target config configmap tls
  service=("$render"/*/cilium/Service_kube-system_hubble-relay.yaml)
  [ -f "${service[0]}" ] || { echo "the render of the Cilium chart holds no Service hubble-relay in kube-system: the recorder has no Relay to follow"; return 1; }
  RELAY_NAME="$(yq '.metadata.name' "${service[0]}")"
  RELAY_NAMESPACE="$(yq '.metadata.namespace' "${service[0]}")"
  [ "$(yq '.spec.ports | length' "${service[0]}")" -eq 1 ] || { echo "Relay's Service serves $(yq '.spec.ports | length' "${service[0]}") ports, not one"; return 1; }
  [ "$(yq '.spec.ports[0].protocol // "TCP"' "${service[0]}")" = TCP ]
  RELAY_PORT="$(yq '.spec.ports[0].port' "${service[0]}")"
  target="$(yq '.spec.ports[0].targetPort // .spec.ports[0].port' "${service[0]}")"
  RELAY_SELECTOR="$(yq -o json -I0 '.spec.selector // {}' "${service[0]}" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')"
  [ -n "$RELAY_SELECTOR" ] || { echo "Relay's Service selects no pod by a label"; return 1; }
  # The workloads of the namespace whose pods the Service selects: one, Relay's Deployment.
  workloads="$(yq -N -o json -I0 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet")' "$render"/*/cilium/*.yaml |
    jq -c --arg ns "$RELAY_NAMESPACE" --slurpfile service <(yq -o json -I0 '.' "${service[0]}") '
      select(.metadata.namespace == $ns) | (.spec.template.metadata.labels // {}) as $labels
      | select($service[0].spec.selector | to_entries | all($labels[.key] == .value))')"
  [ "$(grep -c . <<<"$workloads")" -eq 1 ] || { echo "Relay's Service selects the pods of $(grep -c . <<<"$workloads") workloads of the render, not one"; return 1; }
  workload=$workloads
  RELAY_PODS="$RELAY_NAMESPACE/$(jq -r '.kind + "/" + .metadata.name' <<<"$workload")"
  RELAY_TARGET="$(jq -r --arg target "$target" '[.spec.template.spec.containers[] | (.ports // [])[]
    | select(.name == $target or (.containerPort | tostring) == $target) | .containerPort] | unique | join(" ")' <<<"$workload")"
  [[ $RELAY_TARGET =~ ^[1-9][0-9]*$ ]] || { echo "the port $target of Relay's Service is not one container port of its pods: ${RELAY_TARGET:-none}"; return 1; }
  RELAY_OTHER="$(jq -r --arg port "$RELAY_TARGET" '[.spec.template.spec.containers[] | (.livenessProbe, .readinessProbe, .startupProbe)
    | select(. != null) | (.grpc.port // .httpGet.port // .tcpSocket.port) | select(. != null) | tostring | select(. != $port)] | unique | join(" ")' <<<"$workload")"
  # Relay's configuration is the file its pods mount, and it says whether its server takes TLS.
  config="$(jq -r '[.spec.template.spec.volumes[] | .configMap.name // empty] | join(" ")' <<<"$workload")"
  configmap=("$render"/*/cilium/"ConfigMap_${RELAY_NAMESPACE}_$config.yaml")
  [ -f "${configmap[0]}" ] || { echo "Relay's pods mount the configuration ${config:-none}, which is no ConfigMap of the render"; return 1; }
  tls="$(yq '.data["config.yaml"] | from_yaml | .["disable-server-tls"] // false' "${configmap[0]}")"
  if [ "$tls" != true ]; then
    echo "Hubble Relay's server takes TLS: its configuration does not set disable-server-tls: true. The recorder would then need" \
      "--tls, the CA that signed Relay's certificate, mounted from a Secret, in --tls-ca-cert-files, the name on that certificate" \
      "in --tls-server-name and, where Relay asks its clients for a certificate, --tls-client-cert-file and --tls-client-key-file:" \
      "volumes and flags the recorder does not have, and docs/kubernetes.md, The record of what policy drops, says it has none"
    return 1
  fi
}

# flag NAME: the values the recorder's command gives the flag NAME, one per line, in order. Needs
# built first.
flag() {
  # shellcheck disable=SC2016 # $name is a jq variable.
  yq -o json -I0 '.command' "$CONTAINER" | jq -r --arg name "$1" '. as $c | range(0; length) | select($c[.] == $name) | $c[. + 1]'
}

# follows RENDER: succeeds when the recorder's --server names Relay's Service as RENDER has it, by
# its name, namespace and port; fails, saying what to set, when it names anything else, and as
# relay does when Relay's server takes TLS. Needs built first.
follows() {
  local server
  relay "$1" || return 1
  server="$(flag --server)"
  if [ "$server" != "$RELAY_NAME.$RELAY_NAMESPACE.svc:$RELAY_PORT" ]; then
    echo "the recorder's --server is ${server:-not set}, but the render of the Cilium chart has Relay's Service as $RELAY_NAME in" \
      "$RELAY_NAMESPACE on port $RELAY_PORT: set --server to $RELAY_NAME.$RELAY_NAMESPACE.svc:$RELAY_PORT in $APP_DIR/app/deployment.yaml"
    return 1
  fi
}

# reach RENDER FROM TO PORT/PROTOCOL: whether the policies of RENDER let FROM reach TO.
reach() {
  run "$REPO/scripts/network-policy-check" --reach "$@"
}

# allowed and denied RENDER FROM TO PORT: assert the answer for the flow.
allowed() {
  reach "$@"
  [ "$status" -eq 0 ] || { echo "expected $* to be allowed: $output"; return 1; }
}
denied() {
  reach "$@"
  [ "$status" -eq 1 ] || { echo "expected $* to be denied: $output"; return 1; }
}

# tree_without PATTERN...: a copy of the tree in $TREE whose overlay lists no resource that matches
# any PATTERN, an extended regular expression.
tree_without() {
  local pattern
  TREE="$BATS_TEST_TMPDIR/tree"
  rm -rf "$TREE"
  mkdir -p "$TREE"
  cp -r "$REPO/kubernetes" "$TREE/kubernetes"
  for pattern in "$@"; do
    PATTERN="$pattern" yq -i '.resources |= map(select(test(strenv(PATTERN)) | not))' \
      "$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  done
}

# of_security_system FILE: what an overlay built into FILE holds of the namespace security-system,
# sorted, as kind, namespace and name: the namespace itself, any object in it, and any
# Kustomization that deploys into it.
of_security_system() {
  yq -N 'select((.kind == "Namespace" and .metadata.name == "security-system") or .metadata.namespace == "security-system"
      or .spec.targetNamespace == "security-system")
    | .kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$1" | LC_ALL=C sort | paste -sd, -
}

# flat: standard input as one line, every run of blanks and line ends one space and none at either
# end, so that a phrase of the docs is found wherever its lines break.
flat() {
  tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

# record_section: the docs' section on the record, from its heading to the next of its level or
# above.
record_section() {
  awk '/^### The record of what policy drops$/ { on = 1; next } on && /^##?#? / { exit } on' "$DOCS"
}

# turning_on: the docs' section that turns enforcement on, from its heading to the next of its
# level or above.
turning_on() {
  awk '/^### Turning it on, and back$/ { on = 1; next } on && /^##?#? / { exit } on' "$DOCS"
}

@test "The flow recorder is selected by one overlay entry and builds nothing when it is not" {
  local entity
  # The overlay selects it with one entry, its ks.yaml, beside the namespace directory that Falco's
  # entry already needs.
  [ "$(yq '.resources[] | select(test("/network-audit(/|$)"))' "$OVERLAY_DIR/kustomization.yaml" | paste -sd, -)" = ../../base/security-system/network-audit/ks.yaml ]
  overlay
  [ "$(of_security_system "$OVERLAY")" = ConfigMap/security-system/app-template-defaults,Kustomization/flux-system/falco,Kustomization/flux-system/network-audit,Namespace/-/security-system,NetworkPolicy/security-system/default-deny ]
  # Its Kustomization applies the application's own directory into security-system, waits for the
  # definition of its network policy, which is also the release that runs Relay, and is Ready once
  # the Deployment is available.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "network-audit") | .spec.path' "$OVERLAY")" = "./apps/base/security-system/network-audit/app" ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "network-audit") | .spec.targetNamespace' "$OVERLAY")" = security-system ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "network-audit") | .spec.dependsOn | map(.name) | join(" ")' "$OVERLAY")" = cilium ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "network-audit") | .spec.wait' "$OVERLAY")" = true ]
  # What it applies: one Deployment and its network policy, in security-system, and nothing else.
  built
  [ "$(yq -N 'select(. != null) | .kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$BUILT" | LC_ALL=C sort | paste -sd, -)" \
    = CiliumNetworkPolicy/security-system/network-audit,Deployment/security-system/network-audit ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # Backstage's catalogue holds its entity: a Component of the system observability, whose first
  # link is the docs' section on the record and which depends on what the Kustomization names.
  entity="$REPO/kubernetes/apps/base/backstage/backstage/app/catalogue/network-audit.yaml"
  [ "$(yq '.kind + " " + .metadata.name + " " + .spec.system' "$entity")" = "Component network-audit observability" ]
  [ "$(yq '.metadata.links[0].url' "$entity")" = "https://github.com/eekaan/k8s-gitops/blob/main/docs/kubernetes.md#the-record-of-what-policy-drops" ]
  [ "$(yq '.spec.dependsOn | join(" ")' "$entity")" = component:default/cilium ]
  # Without the entry, the cluster builds the namespace, its defaults, its default deny and Falco as
  # before, and nothing of the recorder.
  tree_without '/security-system/network-audit/ks.yaml$'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ "$(of_security_system "$OVERLAY")" = ConfigMap/security-system/app-template-defaults,Kustomization/flux-system/falco,Namespace/-/security-system,NetworkPolicy/security-system/default-deny ]
  [ "$(yq -N 'select((.metadata.name // "") == "network-audit" or ((.spec.path // "") | test("/network-audit/"))) | .kind' "$OVERLAY" | grep -c . || true)" -eq 0 ]
  # Selecting it without Cilium, whose operator defines the kind of its policy and whose release
  # runs Relay, is refused, naming both.
  tree_without '/kube-system/cilium/ks.yaml$'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "without cilium: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"$APP_DIR/ks.yaml: Kustomization network-audit names cilium"* ]]
  [[ $output == *"does not enable"* ]]
}

@test "The flow recorder follows the flows policy drops or would drop through Hubble Relay, one JSON line each that the log collector ships" {
  local image agents daemonset pin mask command path config key out="$BATS_TEST_TMPDIR/collector"
  built
  real_render
  # One container, hubble, and no other: no sidecar, no init container, no shell around the CLI.
  [ "$(yq '.spec.template.spec.containers | map(.name) | join(" ")' "$DEPLOYMENT")" = hubble ]
  [ "$(yq '.spec.template.spec.initContainers // [] | length' "$DEPLOYMENT")" -eq 0 ]
  [ "$(yq '.args // "absent"' "$CONTAINER")" = absent ]
  [ "$(yq '.env // "absent"' "$CONTAINER")" = absent ]
  [ "$(yq '.envFrom // "absent"' "$CONTAINER")" = absent ]
  # The server is Relay's Service by its name, namespace and port, as the render of the Cilium chart
  # with the tree's values has them, and Relay's server takes no TLS there.
  follows "$REAL"
  echo "Relay: Service $RELAY_NAME in $RELAY_NAMESPACE, port $RELAY_PORT to the container port $RELAY_TARGET of $RELAY_PODS"
  # The command, flag by flag: the server, follow, the two verdicts, the output and the mask, and
  # nothing else. No TLS flag, no --last, --since, --all or --debug.
  mask="$(flag --field-mask)"
  command="$(yq -o json -I0 '.command' "$CONTAINER")"
  echo "command: $command"
  [ "$command" = "$(jq -cn --arg server "$RELAY_NAME.$RELAY_NAMESPACE.svc:$RELAY_PORT" --arg mask "$mask" \
    '["hubble", "observe", "--server", $server, "--follow", "--verdict", "DROPPED", "--verdict", "AUDIT", "--output", "jsonpb", "--field-mask", $mask]')" ]
  # The mask, as a set: the fields the recipe prints, the time and node name that the agents fill
  # each record's own from, and the flow's identifier. No IP, ethernet or tunnel, the fields of a
  # flow's addresses, and no source_names or destination_names, the names they resolve to.
  [ "$(tr ',' '\n' <<<"$mask" | LC_ALL=C sort | paste -sd' ' -)" = "$MASK" ]
  [ "$(tr ',' '\n' <<<"$mask" | grep -c .)" -eq "$(wc -w <<<"$MASK")" ]
  for path in IP ethernet tunnel source_names destination_names; do
    if tr ',' '\n' <<<"$mask" | grep -qE "^$path(\\.|\$)"; then echo "the mask asks for $path"; return 1; fi
  done
  # One follower at a time: one replica, replaced before the next starts, and available only once it
  # has run for half a minute, which a recorder that cannot reach Relay never does.
  [ "$(yq '.spec.replicas' "$DEPLOYMENT")" -eq 1 ]
  [ "$(yq '.spec.strategy.type' "$DEPLOYMENT")" = Recreate ]
  [ "$(yq '.spec.strategy | keys | join(" ")' "$DEPLOYMENT")" = type ]
  [ "$(yq '.spec.minReadySeconds' "$DEPLOYMENT")" -eq 30 ]
  # It does not wait two hours on a Relay that went without closing the connection: the pod's own
  # TCP keepalive probes a silent connection after a minute, three times ten seconds apart.
  [ "$(yq -o json -I0 '.spec.template.spec.securityContext.sysctls' "$DEPLOYMENT")" \
    = '[{"name":"net.ipv4.tcp_keepalive_time","value":"60"},{"name":"net.ipv4.tcp_keepalive_intvl","value":"10"},{"name":"net.ipv4.tcp_keepalive_probes","value":"3"}]' ]
  # The image is the agents', tag and digest, as the same render gives the DaemonSet cilium, under
  # the comment Renovate reads, so that it moves with the chart.
  daemonset=("$REAL"/*/cilium/DaemonSet.apps_kube-system_cilium.yaml)
  [ -f "${daemonset[0]}" ]
  agents="$(yq '.spec.template.spec.containers[] | select(.name == "cilium-agent") | .image' "${daemonset[0]}")"
  image="$(yq '.image' "$CONTAINER")"
  echo "the recorder runs $image; the agents run $agents"
  [[ $agents =~ ^[a-z0-9./-]+:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]
  if [ "$image" != "$agents" ]; then
    echo "set the image of the container hubble in $APP_DIR/app/deployment.yaml to $agents, the image the Cilium chart's agents" \
      "run, whose hubble is of the release that Relay and the agents are, as Renovate sets it with the chart in one pull request"
    return 1
  fi
  pin="$(grep -B1 -E '^[[:blank:]]+image: ' "$REPO/$APP_DIR/app/deployment.yaml" | head -n 1 | sed 's/^[[:blank:]]*//')"
  echo "above the image: $pin"
  [ "$pin" = "# renovate: datasource=docker depName=${image%%:*}" ]
  [ "$(grep -cE '^[[:blank:]]+image: ' "$REPO/$APP_DIR/app/deployment.yaml")" -eq 1 ]
  # The check says what the recorder would need when Relay's server takes TLS, and what to set when
  # the Service's port moves.
  cilium_copy tls
  yq -i '.data["config.yaml"] |= (from_yaml | del(.["disable-server-tls"]) | to_yaml)' "$BATS_TEST_TMPDIR"/tls/*/cilium/ConfigMap_kube-system_hubble-relay-config.yaml
  run follows "$BATS_TEST_TMPDIR/tls"
  echo "with TLS: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"Hubble Relay's server takes TLS"*"--tls-ca-cert-files"*"--tls-server-name"* ]]
  cilium_copy tls-false
  yq -i '.data["config.yaml"] |= (from_yaml | .["disable-server-tls"] = false | to_yaml)' "$BATS_TEST_TMPDIR"/tls-false/*/cilium/ConfigMap_kube-system_hubble-relay-config.yaml
  run follows "$BATS_TEST_TMPDIR/tls-false"
  [ "$status" -ne 0 ]
  [[ $output == *"Hubble Relay's server takes TLS"* ]]
  cilium_copy moved
  yq -i '.spec.ports[0].port = 443' "$BATS_TEST_TMPDIR"/moved/*/cilium/Service_kube-system_hubble-relay.yaml
  run follows "$BATS_TEST_TMPDIR/moved"
  echo "with the port moved: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"set --server to hubble-relay.kube-system.svc:443 in $APP_DIR/app/deployment.yaml"* ]]
  # The agents hand Hubble what the recorder asks for: Hubble is on, and the datapath reports its
  # drops and its policy verdicts, which a DROPPED and an AUDIT flow are made from.
  config=("$REAL"/*/cilium/ConfigMap_kube-system_cilium-config.yaml)
  [ -f "${config[0]}" ]
  for key in enable-hubble bpf-events-drop-enabled bpf-events-policy-verdict-enabled; do
    [ "$(KEY=$key yq '.data[strenv(KEY)]' "${config[0]}")" = true ] ||
      { echo "the agents' rendered configuration does not set $key: true, so the recorder gets no such flow"; return 1; }
  done
  # One JSON line for each flow on standard output is what jsonpb prints. The collector reads every
  # pod's lines whatever its namespace, keeps each whole and sends it to the store, and the
  # recorder's pod is not one it leaves out.
  mkdir -p "$out"
  "$REPO/scripts/vector-config" "$out"
  [ "$(yq '.sources.pods.type' "$out/vector.yaml")" = kubernetes_logs ]
  [ "$(yq '.sources.pods | keys | join(" ")' "$out/vector.yaml")" = type ]
  [ "$(yq '.transforms.pod_fields.inputs | join(" ")' "$out/vector.yaml")" = pods ]
  [ "$(yq '.transforms.pod_fields.source' "$out/vector.yaml" | grep -cE '\.message|abort|drop' || true)" -eq 0 ]
  [ "$(yq '.sinks.victoria_logs.inputs | join(" ")' "$out/vector.yaml")" = "pod_fields drop_auditd_log" ]
  [ "$(yq '.sinks.victoria_logs.query._msg_field' "$out/vector.yaml")" = message ]
  [ "$(yq '.spec.template.metadata.labels | has("vector.dev/exclude")' "$DEPLOYMENT")" = false ]
  [ "$(yq '.spec.template.metadata.annotations // {} | length' "$DEPLOYMENT")" -eq 0 ]
  # The recipe finds the lines by the namespace and the container's name, which the collector makes
  # part of each line's stream.
  [ "$(yq '.sinks.victoria_logs.query._stream_fields' "$out/vector.yaml" | tr ',' '\n' | grep -cx -e kubernetes.pod_namespace -e kubernetes.container_name)" -eq 2 ]
  [ "$(yq '.metadata.namespace' "$DEPLOYMENT")" = security-system ]
}

@test "The flow recorder runs unprivileged, with no token for the API server and nothing of the host" {
  local pod
  built
  pod="$BATS_TEST_TMPDIR/pod.yaml"
  yq '.spec.template.spec' "$DEPLOYMENT" >"$pod"
  # The pod and its container set these keys and no other, so nothing else decides where it runs,
  # as whom, or where its lookup of Relay's name goes: a dnsPolicy, dnsConfig or hostAliases would
  # send it past the resolver, the one server its policy lets it ask.
  [ "$(yq 'keys | sort | join(" ")' "$pod")" = "automountServiceAccountToken containers securityContext terminationGracePeriodSeconds" ]
  [ "$(yq 'keys | sort | join(" ")' "$CONTAINER")" = "command image name resources securityContext" ]
  # A non-root user and group, the runtime's seccomp profile, no privilege escalation, every
  # capability dropped and none added, and a root filesystem nothing can write to. The pod's
  # sysctls are three of its own network namespace's that the restricted level admits, which the
  # check of the render below holds it to.
  [ "$(yq '.securityContext | keys | sort | join(" ")' "$pod")" = "runAsGroup runAsNonRoot runAsUser seccompProfile sysctls" ]
  [ "$(yq '.securityContext.sysctls | map(.name) | join(" ")' "$pod")" = "net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes" ]
  [ "$(yq '.securityContext.runAsNonRoot' "$pod")" = true ]
  [ "$(yq '.securityContext.runAsUser' "$pod")" -eq 65532 ]
  [ "$(yq '.securityContext.runAsGroup' "$pod")" -eq 65532 ]
  [ "$(yq '.securityContext.seccompProfile.type' "$pod")" = RuntimeDefault ]
  [ "$(yq '.securityContext | keys | sort | join(" ")' "$CONTAINER")" = "allowPrivilegeEscalation capabilities readOnlyRootFilesystem" ]
  [ "$(yq '.securityContext.allowPrivilegeEscalation' "$CONTAINER")" = false ]
  [ "$(yq '.securityContext.readOnlyRootFilesystem' "$CONTAINER")" = true ]
  [ "$(yq -o json -I0 '.securityContext.capabilities' "$CONTAINER")" = '{"drop":["ALL"]}' ]
  # No volume at all, as an empty set: nothing of the host, no Secret, no ConfigMap, no scratch
  # directory, and so nothing the container mounts.
  [ "$(yq -o json -I0 '.volumes // []' "$pod")" = '[]' ]
  [ "$(yq -o json -I0 '[.containers[] | .volumeMounts // [] | .[]]' "$pod")" = '[]' ]
  # No token for the API server, and no account of its own that a Role could name.
  [ "$(yq '.automountServiceAccountToken' "$pod")" = false ]
  [ "$(yq '.serviceAccountName // .serviceAccount // "absent"' "$pod")" = absent ]
  [ "$(yq -N 'select(.kind == "ServiceAccount" or .kind == "Role" or .kind == "RoleBinding" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding") | .kind' "$BUILT" | grep -c . || true)" -eq 0 ]
  # Nothing of the host: no namespace of its, no port of its, no path of its.
  [ "$(yq '(.hostNetwork // false) or (.hostPID // false) or (.hostIPC // false) or (.hostUsers == true)' "$pod")" = false ]
  [ "$(yq '[.containers[] | .ports // [] | .[] | select(.hostPort != null)] | length' "$pod")" -eq 0 ]
  [ "$(yq '.nodeName // .nodeSelector // .tolerations // "absent"' "$pod")" = absent ]
  # It listens on nothing, so it declares no port, no Service selects it and nothing probes it: the
  # process ends when its stream does, and the kubelet starts it again.
  [ "$(yq '.ports // "absent"' "$CONTAINER")" = absent ]
  [ "$(yq '.livenessProbe // .readinessProbe // .startupProbe // "absent"' "$CONTAINER")" = absent ]
  [ "$(yq '.lifecycle // "absent"' "$CONTAINER")" = absent ]
  [ "$(yq -N 'select(.kind == "Service") | .metadata.name' "$BUILT" | grep -c . || true)" -eq 0 ]
  [ "$(yq '.restartPolicy // "Always"' "$pod")" = Always ]
  grep -qE '^[[:blank:]]*# .*[Nn]o (port|probe)' "$REPO/$APP_DIR/app/deployment.yaml"
  # It ends on TERM within a second, so the kubelet waits five for it and no longer.
  [ "$(yq '.terminationGracePeriodSeconds' "$pod")" -eq 5 ]
  # Requests, and a limit on memory alone.
  [ "$(yq '.resources.requests | keys | sort | join(" ")' "$CONTAINER")" = "cpu memory" ]
  [ "$(yq '.resources.limits | keys | join(" ")' "$CONTAINER")" = memory ]
  [ "$(yq '.resources.requests.cpu' "$CONTAINER")" = 10m ]
  [ "$(yq '.resources.requests.memory' "$CONTAINER")" = 32Mi ]
  [ "$(yq '.resources.limits.memory' "$CONTAINER")" = 128Mi ]
  # The namespace enforces privileged for Falco, and its one exception is still Falco's: the check
  # of the render holds the recorder to restricted, as it does every pod that is no exception.
  [ "$(yq '[.exceptions[] | select(.namespace == "security-system")] | map(.workload + " " + .level) | join(",")' "$REPO/pod-security-exceptions.yaml")" = "DaemonSet/falco privileged" ]
  real_render
  run "$REPO/scripts/pod-security-check" --list "$REAL" "$REPO/pod-security-exceptions.yaml" "$REPO/versions.yaml"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"security-system privileged"* ]]
  [[ $output == *"$RECORDER restricted"* ]] || { echo "the recorder is not evaluated at restricted: $(grep security-system <<<"$output")"; return 1; }
}

@test "The flow recorder reaches Hubble Relay and the resolver and nothing else, and nothing reaches it" {
  local port other entry
  built
  real_render
  relay "$REAL"
  echo "Relay: $RELAY_PODS, selected by $RELAY_SELECTOR, on $RELAY_TARGET; its probes ask ${RELAY_OTHER:-no other port}"
  # The policy selects the recorder's pods, by the labels of the Deployment's selector, leaves the
  # deny to the namespace's default deny, and has no ingress rule: nothing connects to the recorder.
  [ "$(yq -o json -I0 '.spec.endpointSelector' "$POLICY")" = "$(yq -o json -I0 '{"matchLabels": .spec.selector.matchLabels}' "$DEPLOYMENT")" ]
  [ "$(yq -o json -I0 '.spec.template.metadata.labels' "$DEPLOYMENT")" = '{"app.kubernetes.io/name":"network-audit"}' ]
  [ "$(yq -o json -I0 '.spec.enableDefaultDeny' "$POLICY" | jq -cS .)" = '{"egress":false,"ingress":false}' ]
  [ "$(yq '.spec | keys | sort | join(" ")' "$POLICY")" = "egress enableDefaultDeny endpointSelector" ]
  [ "$(yq '.metadata.annotations // {} | length' "$POLICY")" -eq 0 ]
  # Two egress rules: the resolver on 53, UDP and TCP, and the pods Relay's Service selects, by the
  # labels of its selector in its namespace, on the container port the Service's port targets.
  [ "$(yq '.spec.egress | length' "$POLICY")" -eq 2 ]
  [ "$(yq -o json -I0 '.spec.egress[0]' "$POLICY" | jq -cS .)" = "$(jq -cnS '{toEndpoints: [{matchLabels: {"k8s:io.kubernetes.pod.namespace": "kube-system", "k8s:k8s-app": "kube-dns"}}],
    toPorts: [{ports: [{port: "53", protocol: "UDP"}, {port: "53", protocol: "TCP"}]}]}')" ]
  [ "$(yq -o json -I0 '.spec.egress[1]' "$POLICY" | jq -cS .)" = "$(jq -cnS --arg ns "$RELAY_NAMESPACE" --arg selector "$RELAY_SELECTOR" --arg port "$RELAY_TARGET" '
    {toEndpoints: [{matchLabels: ({"k8s:io.kubernetes.pod.namespace": $ns}
        + ($selector | split(",") | map(split("=") | {key: ("k8s:" + .[0]), value: (.[1:] | join("="))}) | from_entries))}],
     toPorts: [{ports: [{port: $port, protocol: "TCP"}]}]}')" ] ||
    { echo "the recorder's policy does not let it reach the pods Relay's Service selects ($RELAY_SELECTOR in $RELAY_NAMESPACE) on $RELAY_TARGET alone: $(yq -o json -I0 '.spec.egress[1]' "$POLICY")"; return 1; }
  # The kind of the policy is one Cilium's operator defines.
  [ "$(yq '.spec.dependsOn | map(.name) | join(" ")' "$KS")" = cilium ]
  # The flows, on the tree's render. It reaches Relay's pods on that port and the resolver.
  allowed "$VIEW" "$RECORDER" "$RELAY_PODS" "$RELAY_TARGET/tcp"
  allowed "$VIEW" "$RECORDER" "$RELAY_NAMESPACE:$RELAY_SELECTOR" "$RELAY_TARGET/tcp"
  allowed "$VIEW" "$RECORDER" "$DNS" 53/udp
  allowed "$VIEW" "$RECORDER" "$DNS" 53/tcp
  # Not Relay's other ports: those its probes ask, its gops port, the number of its Service's own
  # port, which is no port of a pod, and that port over UDP.
  [ -n "$RELAY_OTHER" ]
  for port in $RELAY_OTHER 9893 "$RELAY_PORT" 22; do
    [ "$port" != "$RELAY_TARGET" ]
    denied "$VIEW" "$RECORDER" "$RELAY_PODS" "$port/tcp"
  done
  denied "$VIEW" "$RECORDER" "$RELAY_PODS" "$RELAY_TARGET/udp"
  # No other pod of kube-system, on Relay's port or their own, the resolver's other port among them.
  for other in kube-system/Deployment/metrics-server kube-system/Deployment/cilium-operator kube-system/DaemonSet/cilium \
    kube-system/DaemonSet/spegel kube-system/Deployment/reloader-reloader "$DNS"; do
    denied "$VIEW" "$RECORDER" "$other" "$RELAY_TARGET/tcp"
  done
  denied "$VIEW" "$RECORDER" "$DNS" 9153/tcp
  denied "$VIEW" "$RECORDER" kube-system/Deployment/metrics-server 10250/tcp
  # Not the API server, not a node's Hubble port, which Relay reads, nor any other port of a node.
  denied "$VIEW" "$RECORDER" @kube-apiserver 6443/tcp
  denied "$VIEW" "$RECORDER" @kube-apiserver 443/tcp
  denied "$VIEW" "$RECORDER" @host 4244/tcp
  denied "$VIEW" "$RECORDER" @remote-node 4244/tcp
  denied "$VIEW" "$RECORDER" @remote-node 10250/tcp
  # Not the log store, Prometheus, Falco beside it, another application or the world.
  denied "$VIEW" "$RECORDER" monitoring/StatefulSet/victoria-logs 9428/tcp
  denied "$VIEW" "$RECORDER" "$PROMETHEUS" 9090/tcp
  denied "$VIEW" "$RECORDER" security-system/DaemonSet/falco 8765/tcp
  denied "$VIEW" "$RECORDER" demo/Deployment/hello 8080/tcp
  denied "$VIEW" "$RECORDER" openbao/StatefulSet/openbao 8200/tcp
  denied "$VIEW" "$RECORDER" @world 443/tcp
  denied "$VIEW" "$RECORDER" @world 80/tcp
  denied "$VIEW" "$RECORDER" @world 53/udp
  # Nothing reaches it, on Relay's port or any other: not the local host, as no probe asks it
  # anything, not Prometheus, the proxies, Relay, Falco, another node, the API server or the world.
  for other in @host "$PROMETHEUS" "$PROXY" "$RELAY_PODS" security-system/DaemonSet/falco demo/Deployment/hello @remote-node @kube-apiserver @world; do
    for port in "$RELAY_TARGET" 8080 80; do
      denied "$VIEW" "$other" "$RECORDER" "$port/tcp"
    done
  done
  # The check of the tree passes with the policy, and the namespace still holds its default deny.
  run "$REPO/scripts/network-policy-check" "$REAL" "$REPO/network-policy-exceptions.yaml"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"security-system denies ingress and egress"* ]]
  [[ $output == *"kube-system listed"* ]]
  # What Relay takes is declared where kube-system is listed: its entry names the recorder and the
  # port, and what covers it names the recorder's egress on that port alone.
  entry="$(yq -o json -I0 '.exceptions[] | select(.namespace == "kube-system")' "$REPO/network-policy-exceptions.yaml")"
  [ -n "$entry" ]
  [[ $(jq -r '.reason' <<<"$entry" | flat) == *"Hubble Relay takes the flow recorder of security-system on $RELAY_TARGET, the container port its Service's port $RELAY_PORT targets"* ]] ||
    { echo "kube-system's entry does not say that Hubble Relay takes the flow recorder of security-system on $RELAY_TARGET, the container port its Service's port $RELAY_PORT targets: $(jq -r '.reason' <<<"$entry")"; return 1; }
  [[ $(jq -r '.["covered-by"]' <<<"$entry" | flat) == *"the flow recorder's egress, which names Hubble Relay's pods on $RELAY_TARGET alone"* ]] ||
    { echo "what covers kube-system does not name the recorder's egress to Hubble Relay's pods on $RELAY_TARGET alone: $(jq -r '.["covered-by"]' <<<"$entry")"; return 1; }
  # The docs' table and its list of what the namespaces let through say the same, with that port.
  # shellcheck disable=SC2016 # The backticks are the docs' own.
  grep -E '^\| `kube-system` \| listed \|' "$DOCS" | grep -qF "Hubble Relay takes the flow recorder of \`security-system\` on $RELAY_TARGET"
  # shellcheck disable=SC2016 # The backticks are the docs' own.
  grep -E '^\| `security-system` \| default deny \|' "$DOCS" | grep -qF "the flow recorder takes nothing and reaches the resolver and Hubble Relay on $RELAY_TARGET"
  [[ $(awk '/^- \*\*`security-system`\.\*\*/ { on = 1 } on && /^- \*\*/ && !/security-system/ { exit } on' "$DOCS" | flat) \
    == *"The flow recorder's pods"*"the pods the Service \`$RELAY_NAME\` selects"*"on $RELAY_TARGET, the container port that Service's port $RELAY_PORT targets"* ]]
}

# audit_copy: a copy of the repository's scripts, with a kubeconfig for the cluster lab-sto2, for
# just network-audit to run in through the repository's justfile, against recording fakes: a mise
# with nothing installed, which keeps the justfile from putting real tools in front of the fakes;
# a kubectl that records its arguments, the kubeconfig it was given and the names of its
# environment, then acts as the files of $STATE say, each time after a warning naming the API
# server's address on its error output, as kubectl v1.37 does; and a curl that records its
# arguments and each request, its URL and the headers it read from a file or file descriptor, and
# answers as vmauth does in front of the store, through kubectl's forward alone.
#
# For the store's query, which just logs asks vmauth through a port-forward with the operator's
# credential, as $STATE/store says: kubectl's get secret answers with the base64 of
# $STATE/authorization, the Secret's key, and its port-forward with the line that names the local
# port it forwards from, 41234, after which it runs until it is stopped, its process id in
# $STATE/forwards; curl, through that forward, answers ok with the file $STATE/answer, and refuse
# with 400 and the plain-text body VictoriaLogs sends for a query it refuses, which vmauth relays;
# forbidden fails get secret as when the kubeconfig may not read the Secret; down fails it as when
# the API server does not answer, naming its address.
#
# For the recorder's pods, get pods, as $STATE/pods says, with the time in $STATE/time: running
# lists one pod whose container hubble has run since that time; replaced lists that pod and, before
# it, one on its way out, deleted but not yet gone, whose container has run for 30 days; waiting
# lists one whose container waits to be started again and last ended at that time; pending lists
# one that no node runs yet, which has no container status; none lists no pod; garbage answers with
# something that is no list; fail fails as when the API server does not answer, naming its address
# on its error output and printing a line on its standard output. A listed pod carries addresses,
# its own and its node's.
# Sets COPY, BIN, RECORD, STATE and KUBECONFIG_FILE, and AUTHORIZATION, the Secret's value.
audit_copy() {
  COPY="$BATS_TEST_TMPDIR/copy" BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record" STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$COPY/talos/lab-sto2/clusterconfig" "$BIN" "$RECORD" "$STATE"
  cp -R "$REPO/scripts" "$COPY/scripts"
  KUBECONFIG_FILE="$COPY/talos/lab-sto2/clusterconfig/kubeconfig"
  echo 'not a real kubeconfig' >"$KUBECONFIG_FILE"
  echo ok >"$STATE/store"
  echo running >"$STATE/pods"
  : >"$STATE/forwards"
  date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ >"$STATE/time"
  cp "$FIXTURES/answer.jsonl" "$STATE/answer"
  # The Basic value of the user operator, as vmauth-operator's ExternalSecret forms it.
  AUTHORIZATION="Basic $(printf 'operator:%s' marker-operator-password | base64 -w0)"
  printf '%s' "$AUTHORIZATION" >"$STATE/authorization"
  printf '#!/usr/bin/env bash\n' >"$BIN/mise"
  { printf '#!/usr/bin/env bash\nRECORD=%q STATE=%q\n' "$RECORD" "$STATE"; cat <<'EOF'; } >"$BIN/kubectl"
printf '%s\n' "$*" >>"$RECORD/argv"
printf '%s\n' "${KUBECONFIG-unset}" >>"$RECORD/kubeconfig"
env | cut -d= -f1 >>"$RECORD/names"
echo 'W1114 12:00:00 request to https://192.0.2.10:6443 was slow' >&2
if [[ " $* " == *" get secret vmauth-operator "* ]]; then
  case $(cat "$STATE/store") in
    forbidden)
      echo 'Error from server (Forbidden): secrets "vmauth-operator" is forbidden: User "operator" cannot get resource "secrets" in API group "" in the namespace "monitoring"' >&2
      exit 1
      ;;
    down)
      echo 'Unable to connect to the server: dial tcp 192.0.2.10:6443: connect: connection refused' >&2
      exit 1
      ;;
    *) base64 -w0 <"$STATE/authorization" ;;
  esac
elif [[ " $* " == *" port-forward "* ]]; then
  echo "Forwarding from 127.0.0.1:41234 -> 8427"
  echo "$$" >>"$STATE/forwards"
  exec sleep 600
elif [[ $1 == get && $2 == pods ]]; then
  at=$(cat "$STATE/time")
  leaving='[]'
  reversed=false
  case $(cat "$STATE/pods") in
    running | replaced | overlap | overlap-reversed)
      state=$(jq -cn --arg at "$at" '{name: "hubble", ready: true, restartCount: 0, started: true,
        state: {running: {startedAt: $at}}, lastState: {}}')
      if [[ $(cat "$STATE/pods") == overlap* ]]; then
        leaving=$(jq -cn --arg at "$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)" '[{apiVersion: "v1", kind: "Pod",
          metadata: {name: "network-audit-7d9c8b6f5-p3n6w", namespace: "security-system",
            labels: {"app.kubernetes.io/name": "network-audit", "pod-template-hash": "7d9c8b6f5"}},
          spec: {nodeName: "node-1", containers: [{name: "hubble"}]},
          status: {phase: "Running", hostIP: "192.0.2.11", podIP: "192.0.2.46",
            containerStatuses: [{name: "hubble", ready: true, restartCount: 0, started: true, state: {running: {startedAt: $at}}}]}}]')
        if [[ $(cat "$STATE/pods") == overlap-reversed ]]; then reversed=true; fi
      elif [[ $(cat "$STATE/pods") == replaced ]]; then
        leaving=$(jq -cn --arg at "$(date -u -d '-30 days' +%Y-%m-%dT%H:%M:%SZ)" '[{apiVersion: "v1", kind: "Pod",
          metadata: {name: "network-audit-5c6b7d8f9-q8r7s", namespace: "security-system", deletionTimestamp: "2026-11-14T12:00:00Z",
            labels: {"app.kubernetes.io/name": "network-audit", "pod-template-hash": "5c6b7d8f9"}},
          spec: {nodeName: "node-3", containers: [{name: "hubble"}]},
          status: {phase: "Running", hostIP: "192.0.2.13", podIP: "192.0.2.45",
            containerStatuses: [{name: "hubble", ready: true, restartCount: 0, started: true, state: {running: {startedAt: $at}}}]}}]')
      fi
      ;;
    pending)
      jq -n '{apiVersion: "v1", kind: "List", metadata: {resourceVersion: ""}, items: [
        {apiVersion: "v1", kind: "Pod",
         metadata: {name: "network-audit-7d9c8b6f5-k2m4x", namespace: "security-system",
           labels: {"app.kubernetes.io/name": "network-audit", "pod-template-hash": "7d9c8b6f5"}},
         spec: {containers: [{name: "hubble"}]},
         status: {phase: "Pending", conditions: [{type: "PodScheduled", status: "False", reason: "Unschedulable",
           message: "0/3 nodes are available at 192.0.2.10"}]}}]}'
      exit 0
      ;;
    garbage)
      echo 'Unexpected answer from 192.0.2.10'
      exit 0
      ;;
    waiting)
      state=$(jq -cn --arg at "$at" '{name: "hubble", ready: false, restartCount: 7, started: false,
        state: {waiting: {reason: "CrashLoopBackOff", message: "back-off 5m0s restarting failed container=hubble pod=network-audit-7d9c8b6f5-k2m4x at 192.0.2.44"}},
        lastState: {terminated: {exitCode: 1, reason: "Error", startedAt: $at, finishedAt: $at}}}')
      ;;
    none)
      echo '{"apiVersion":"v1","items":[],"kind":"List","metadata":{"resourceVersion":""}}'
      exit 0
      ;;
    fail)
      echo 'printed before the failure, at 192.0.2.10'
      echo 'Unable to connect to the server: dial tcp 192.0.2.10:6443: i/o timeout' >&2
      exit 1
      ;;
  esac
  jq -n --argjson state "$state" --argjson leaving "$leaving" --argjson reversed "$reversed" '{apiVersion: "v1", kind: "List", metadata: {resourceVersion: ""}, items: ([
    {apiVersion: "v1", kind: "Pod",
     metadata: {name: "network-audit-7d9c8b6f5-k2m4x", namespace: "security-system",
       labels: {"app.kubernetes.io/name": "network-audit", "pod-template-hash": "7d9c8b6f5"}},
     spec: {nodeName: "node-2", containers: [{name: "hubble"}]},
     status: {phase: "Running", hostIP: "192.0.2.12", podIP: "192.0.2.44", podIPs: [{ip: "192.0.2.44"}],
       containerStatuses: [$state]}}] as $pod | if $reversed then $pod + $leaving else $leaving + $pod end)}'
else
  echo "the recording kubectl does not know: $*" >&2
  exit 64
fi
EOF
  { printf '#!/usr/bin/env bash\nRECORD=%q STATE=%q\n' "$RECORD" "$STATE"; cat <<'EOF'; } >"$BIN/curl"
printf '%s\n' "$*" >>"$RECORD/curl-argv"
url="" output=/dev/stdout write_out="" headers=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    --header | -H)
      header=${args[++i]}
      if [[ $header == @* ]]; then headers+=$(cat "${header#@}")$'\n'; else headers+=$header$'\n'; fi
      ;;
    --output | -o) output=${args[++i]} ;;
    --write-out | -w) write_out=${args[++i]} ;;
    --max-time | -m | --connect-timeout) ((i++)) ;;
    http://* | https://*) url=${args[i]} ;;
  esac
done
running=0
while read -r pid; do
  if kill -0 "$pid" 2>/dev/null; then running=1; fi
done <"$STATE/forwards"
if [[ $url != http://127.0.0.1:41234/* ]] || ((!running)); then
  echo "curl: (7) Failed to connect to ${url#http://} after 0 ms: Could not connect to server" >&2
  exit 7
fi
jq -nc --arg url "$url" --arg headers "$headers" '{url: $url, headers: ($headers | split("\n") | map(select(. != "")))}' >>"$RECORD/requests"
respond() {
  cat >"$output"
  if [[ -n $write_out ]]; then printf '%s' "$1"; fi
  exit 0
}
case $(cat "$STATE/store") in
  ok) respond 200 <"$STATE/answer" ;;
  refuse)
    printf '%s\n' 'cannot parse `query` arg: cannot parse "stats" pipe at 192.0.2.77:9428: unexpected token' | respond 400
    ;;
esac
EOF
  chmod +x "$BIN/mise" "$BIN/kubectl" "$BIN/curl"
}

# The secret variables the recipes read, which just network-audit must not pass on to kubectl.
AUDIT_SECRETS=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CLUSTER_S3_ACCESS_KEY_ID CLUSTER_S3_SECRET_ACCESS_KEY
  OS_CLOUD OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET TF_STATE_PASSPHRASE
  TF_ENCRYPTION SOPS_AGE_KEY SOPS_AGE_KEY_FILE FLUX_AGE_KEY FLUX_AGE_KEY_FILE GH_TOKEN OPERATOR_CIDRS)

# audit_recipe ARG...: runs just network-audit ARG... in the copy with only TMPDIR, HOME and a
# marker for each of the secrets set, failing after a minute rather than hanging; its standard
# output is in $output and its error output in $stderr.
audit_recipe() {
  local markers=() name
  for name in "${AUDIT_SECRETS[@]}"; do markers+=("$name=marker-$name"); done
  run --separate-stderr timeout 60 env -i HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${markers[@]}" \
    "$(command -v just)" --justfile "$REPO/justfile" --working-directory "$COPY" network-audit "$@"
}

# audit_merged: just network-audit run the same way with no argument, both outputs in $output in the
# order they were written.
audit_merged() {
  run timeout 60 env -i HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" \
    "$(command -v just)" --justfile "$REPO/justfile" --working-directory "$COPY" network-audit
}

# store_request: the one request for the store that curl recorded, as its address, path and decoded
# parameters, in REQUEST_ADDRESS, REQUEST_PATH, QUERY, START and LIMIT, and the value of the header
# Authorization it sent in REQUEST_AUTHORIZATION; fails unless there is exactly one.
store_request() {
  local request url params
  request="$(cat "$RECORD/requests" 2>/dev/null || true)"
  [ "$(grep -c . <<<"$request")" -eq 1 ] || { echo "curl asked the store $(grep -c . <<<"$request") times: $request"; return 1; }
  url="$(jq -r '.url' <<<"$request")"
  REQUEST_ADDRESS="${url#http://}"
  REQUEST_ADDRESS="${REQUEST_ADDRESS%%/*}"
  REQUEST_PATH="/${url#http://*/}"
  params="${REQUEST_PATH#*\?}"
  REQUEST_PATH="${REQUEST_PATH%%\?*}"
  QUERY="$(jq -rn --arg p "$params" '$p | split("&") | map(select(startswith("query="))) | .[0] | .[6:] | @urid')"
  START="$(jq -rn --arg p "$params" '$p | split("&") | map(select(startswith("start="))) | .[0] // "" | .[6:] | @urid')"
  LIMIT="$(jq -rn --arg p "$params" '$p | split("&") | map(select(startswith("limit="))) | .[0] // "" | .[6:]')"
  REQUEST_AUTHORIZATION="$(jq -r '[.headers[] | select(test("^authorization:"; "i")) | sub("^[^:]*: *"; "")] | if length == 1 then .[0] else "\(length) Authorization headers" end' <<<"$request")"
}

# forwards_closed: every port-forward the recipe started has stopped.
forwards_closed() {
  local pid left=""
  while read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then left+=" $pid"; fi
  done <"$STATE/forwards"
  echo "port-forwards still running:${left:- none}"
  [ -z "$left" ]
}

# no_credential OUTPUT STDERR: no recorded argument of kubectl or curl holds the Secret's value, its
# base64 or the password inside it, and neither output of the recipe, OUTPUT and STDERR, does.
no_credential() {
  local value
  for value in "$AUTHORIZATION" "$(base64 -w0 <"$STATE/authorization")" marker-operator-password "${AUTHORIZATION#Basic }"; do
    if grep -qF -- "$value" "$RECORD/argv" "$RECORD/curl-argv" 2>/dev/null; then
      echo "a recorded argument holds $value"
      return 1
    fi
    if [[ $1 == *"$value"* || $2 == *"$value"* ]]; then
      echo "the recipe printed $value"
      return 1
    fi
  done
}

# no_address TEXT: fails when TEXT holds an address of the documentation ranges, as every address of
# the fixtures is, a URL, a label of a flow's endpoint or a control character.
no_address() {
  if [[ $1 == *192.0.2.* || $1 == *198.51.100.* || $1 == *203.0.113.* || $1 == *://* ]]; then echo "an address in: $1"; return 1; fi
  if [[ $1 == *cidr:* || $1 == *reserved:* || $1 == *k8s:* ]]; then echo "a label in: $1"; return 1; fi
  if LC_ALL=C grep -q $'[\x01-\x08\x0b-\x1f\x7f]' <<<"$1"; then echo "a control character in: $(cat -v <<<"$1")"; return 1; fi
}

# fixture_record FILE NAME: the release that the header of FILE records as NAME, on its one line
# "# NAME: <release>"; fails, saying so, unless there is exactly one.
fixture_record() {
  local line
  line="$(grep -E "^#[[:blank:]]*$2:" "$1" || true)"
  [ "$(grep -c . <<<"$line")" -eq 1 ] || { echo "$1 needs one '# $2: <release>' line in its header"; return 1; }
  sed -E "s/^#[[:blank:]]*$2:[[:blank:]]*//; s/[[:blank:]]*\$//" <<<"$line"
}

# image_tag IMAGE: the tag of the image reference IMAGE, without its digest; nothing when it has
# none.
image_tag() {
  local name="${1%%@*}"
  if [[ ${name##*/} == *:* ]]; then echo "${name##*:}"; fi
}

# store_answers FILE IMAGE VERSION: fails, saying what to do again and what to set, unless the
# VictoriaLogs release whose answers the fixture holds, which the header of FILE records as
# victoria-logs-answers, is the tag of IMAGE, the image the store runs, and VERSION, the appVersion
# of the store's chart.
store_answers() {
  local recorded tag
  recorded="$(fixture_record "$1" victoria-logs-answers)" || { echo "$recorded"; return 1; }
  tag="$(image_tag "$2")"
  echo "the fixture holds the answers of VictoriaLogs $recorded; the store runs $2, of a chart whose appVersion is $3"
  if [ "$recorded" != "$tag" ] || [ "$recorded" != "$3" ]; then
    echo "fixtures/network-audit/answer.jsonl holds what VictoriaLogs $recorded answered, and the store's chart, of VictoriaLogs $3," \
      "runs $2: do the store proof that the header of tests/network-audit.bats describes again against the image the store runs," \
      "inserting the same lines into it, fixtures/network-audit/bulk.ndjson with the query arguments of" \
      "fixtures/network-audit/bulk.args, and asking it the recipe's query as scripts/logs asks it, as docs/kubernetes.md," \
      "The record of what policy drops, sets out; replace the fixture with its answer, change scripts/network-audit and these" \
      "tests where they no longer hold, and set the record victoria-logs-answers and the image's digest in the header to the" \
      "release and the image of the proof, which the store's image and its chart's appVersion are both to be"
    return 1
  fi
}

# flow_lines FILE IMAGE: fails, saying what to do again and what to set, unless the Cilium release
# whose hubble printed the flow lines that the fixture's answers were made from, which the header of
# FILE records as hubble-flow-lines, is the tag of IMAGE, the recorder's image.
flow_lines() {
  local recorded tag
  recorded="$(fixture_record "$1" hubble-flow-lines)" || { echo "$recorded"; return 1; }
  tag="$(image_tag "$2")"
  echo "the fixture's flow lines are what the hubble of Cilium $recorded printed; the recorder runs $2"
  if [ "$recorded" != "$tag" ]; then
    echo "the flow lines that fixtures/network-audit/answer.jsonl was made from are what the hubble of Cilium $recorded printed," \
      "and the recorder runs $2: print them again with the hubble of that image, the recorder's arguments and --input-file -," \
      "for flows and records written as the header of tests/network-audit.bats describes, fixtures/network-audit/flows.jsonl" \
      "and fixtures/network-audit/records.jsonl, put them into the messages of fixtures/network-audit/bulk.ndjson as" \
      "docs/kubernetes.md, The record of what policy drops, sets out, do the store proof over them, replace the fixture with" \
      "the store's answer, change scripts/network-audit and these tests where they no longer hold, and set the record" \
      "hubble-flow-lines to ${tag:-the release of the image}"
    return 1
  fi
}

# The table the recipe prints for the fixture's answer: 14 flows on 10 lines.
TABLE='3 AUDIT demo ingress envoy-gateway-system/Deployment/envoy-public demo/Deployment/hello 8080/tcp -
2 AUDIT backstage egress backstage/CronJob/backstage-db-pgdump @world 443/tcp -
2 DROPPED demo ingress @world demo/Deployment/hello 53/udp POLICY_DENIED
1 AUDIT backstage ingress monitoring/StatefulSet/prometheus-kube-prometheus-stack-prometheus backstage/backstage-db-1 9187/tcp -
1 AUDIT demo egress demo/Deployment/hello kube-system/Deployment/coredns 53/udp -
1 AUDIT demo egress demo/odd[31mpod @kube-apiserver 6443/tcp -
1 AUDIT demo ingress envoy-gateway-system/envoy-public-6c9f7d8b5c-7hj2m demo/Deployment/hello 8080/tcp -
1 AUDIT flux-system ingress kube-system/Deployment/reloader flux-system/Deployment/source-controller 9090/tcp -
1 DROPPED - - @remote-node @host 0/other UNSUPPORTED_L3_PROTOCOL
1 DROPPED demo egress demo/Deployment/hello @world 0/other POLICY_DENIED'

@test "The audit recipe prints the recorded flows by workload and port, counted, with no address" {
  local seconds name started source statefulset deployment recorder store moved version messages printed counted
  # The store's answers in the fixture are those of the release the store runs, and the flow lines
  # they were made from are what the recorder's hubble prints: the header records both releases,
  # which no manager moves (.renovate/by-hand.tsv), and they are held to the store's image, its
  # chart's appVersion and the recorder's image as the render has them.
  real_render
  source=("$REAL"/*/victoria-logs/OCIRepository.source.toolkit.fluxcd.io_monitoring_victoria-logs.yaml)
  statefulset=("$REAL"/*/victoria-logs/StatefulSet.apps_monitoring_victoria-logs.yaml)
  deployment=("$REAL"/*/network-audit/Deployment.apps_security-system_network-audit.yaml)
  [ -f "${source[0]}" ]
  [ -f "${statefulset[0]}" ]
  [ -f "${deployment[0]}" ]
  store="$(yq '[.spec.template.spec.containers[].image | select(test("(^|/)victoria-logs[:@]"))] | join(" ")' "${statefulset[0]}")"
  [[ $store =~ ^[^[:space:]]+$ ]] || { echo "the store's pod runs the VictoriaLogs images '$store', not one"; return 1; }
  version="$(helm show chart "$(yq '.spec.url' "${source[0]}")" --version "$(yq '.spec.ref.tag' "${source[0]}")" | yq -e '.appVersion')"
  store_answers "$BATS_TEST_FILENAME" "$store" "$version"
  recorder="$(yq '.spec.template.spec.containers[] | select(.name == "hubble") | .image' "${deployment[0]}")"
  flow_lines "$BATS_TEST_FILENAME" "$recorder"
  for name in victoria-logs-answers hubble-flow-lines; do
    awk -F'\t' -v name="$name" '$1 == "tests/network-audit.bats" && $2 == name { found = 1 } END { exit !found }' "$REPO/.renovate/by-hand.tsv" ||
      { echo "no row of .renovate/by-hand.tsv for $name in tests/network-audit.bats"; return 1; }
  done
  # The proof's inputs are committed beside its answer, and the docs' section on the record gives its
  # steps over them, the bulk request's body sent with the type the collector's sink gives it.
  for name in flows.jsonl records.jsonl bulk.ndjson bulk.args; do
    [ -s "$FIXTURES/$name" ] || { echo "the store proof's input fixtures/network-audit/$name is missing"; return 1; }
    grep -qF "tests/fixtures/network-audit/$name" <(record_section) ||
      { echo "docs/kubernetes.md, The record of what policy drops, does not name the store proof's input tests/fixtures/network-audit/$name"; return 1; }
  done
  # shellcheck disable=SC2016 # The backticks are the docs' own.
  [[ $(record_section | flat) == *'`Content-Type: application/x-ndjson`'* ]] ||
    { echo "docs/kubernetes.md, The record of what policy drops, does not say that the proof sends bulk.ndjson as Content-Type: application/x-ndjson, as the collector's sink does"; return 1; }
  # And the inputs agree with the answer. The recorder's messages in bulk.ndjson are, as JSON, which
  # the CLI writes in a form of its own, and in order: the flows of flows.jsonl but the FORWARDED
  # one, the records of records.jsonl but that of the nodes that connected, and the CLI's own error.
  messages="$BATS_TEST_TMPDIR/recorder-messages.jsonl"
  jq -c 'select(.kubernetes.pod_namespace == "security-system" and .kubernetes.container_name == "hubble") | .message' \
    "$FIXTURES/bulk.ndjson" >"$messages"
  printed="$(jq -cS 'select(.flow.verdict != "FORWARDED")' "$FIXTURES/flows.jsonl"
    jq -cS 'select(.node_status.state_change != "NODE_CONNECTED")' "$FIXTURES/records.jsonl")"
  diff <(head -n "$(grep -c . <<<"$printed")" "$messages" | jq -cS 'fromjson') <(echo "$printed") ||
    { echo "the recorder's messages in fixtures/network-audit/bulk.ndjson are not what the CLI prints for fixtures/network-audit/flows.jsonl and fixtures/network-audit/records.jsonl: print them again, as docs/kubernetes.md, The record of what policy drops, sets out"; return 1; }
  [ "$(grep -c . "$messages")" -eq "$(($(grep -c . <<<"$printed") + 1))" ]
  [[ $(tail -n 1 "$messages" | jq -r .) == *"lookup hubble-relay."* ]]
  # The store's answer is those messages counted by the query's fields: a field left out where the
  # line has none or an empty one, every value a string, a list as its JSON text, and the lines that
  # are no flow one group without any.
  counted="$(jq -cnS --arg fields "$FIELDS" '($fields | split(", ")) as $fields
    | [inputs | (try fromjson catch {}) as $line
      | reduce $fields[] as $field ({}; ($line | try getpath($field | split(".")) catch null) as $value
        | if $value == null or $value == "" then . else .[$field] = (if ($value | type) == "string" then $value else ($value | tojson) end) end)]
    | group_by(.)[] | .[0] + {flows: (length | tostring)}' "$messages" | LC_ALL=C sort)"
  diff <(jq -cS . "$FIXTURES/answer.jsonl" | LC_ALL=C sort) <(echo "$counted") ||
    { echo "fixtures/network-audit/answer.jsonl is not the recorder's messages in fixtures/network-audit/bulk.ndjson counted by the recipe's query: do the store proof again over them, as docs/kubernetes.md, The record of what policy drops, sets out"; return 1; }
  # A store whose image or chart is of another release, or a recorder of another, fails, saying what
  # to do again over which inputs and what to set.
  moved="${store%%@*}"
  moved="${moved%:*}:v1.0.0"
  run store_answers "$BATS_TEST_FILENAME" "$moved" "$version"
  echo "the store's image moved: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"runs $moved: do the store proof that the header of tests/network-audit.bats describes again"*"replace the fixture with its answer"*"set the record victoria-logs-answers"* ]]
  [[ $output == *"inserting the same lines into it, fixtures/network-audit/bulk.ndjson with the query arguments of fixtures/network-audit/bulk.args,"*"as docs/kubernetes.md, The record of what policy drops, sets out"* ]]
  run store_answers "$BATS_TEST_FILENAME" "$store" v1.0.0
  echo "the store's chart moved: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"the store's chart, of VictoriaLogs v1.0.0,"*"do the store proof"* ]]
  run flow_lines "$BATS_TEST_FILENAME" quay.io/cilium/cilium:v1.0.0
  echo "the recorder's image moved: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"print them again with the hubble of that image"*"do the store proof over them, replace the fixture"*"set the record hubble-flow-lines to v1.0.0"* ]]
  [[ $output == *"fixtures/network-audit/flows.jsonl and fixtures/network-audit/records.jsonl"*"into the messages of fixtures/network-audit/bulk.ndjson"*"as docs/kubernetes.md, The record of what policy drops, sets out"* ]]

  audit_copy
  started="$(cat "$STATE/time")"
  # The store's answer holds addresses in the cidr: labels of the world's endpoints and an escaped
  # control character in a pod's name; to its first line that is a flow the test adds a field the
  # query does not ask for, with an address, as a store that answered with more would.
  grep -q 'cidr:192.0.2.7/32' "$STATE/answer"
  grep -q 'cidr:198.51.100.9/32' "$STATE/answer"
  grep -qF 'odd\u001b[31mpod' "$STATE/answer"
  jq -cs '(map(has("flow.verdict")) | index(true)) as $first | to_entries[]
    | if .key == $first then .value + {"flow.IP.source": "192.0.2.10", "flow.IP.destination": "203.0.113.20"} else .value end' \
    "$FIXTURES/answer.jsonl" >"$STATE/answer"
  [ "$(grep -c '"flow.IP.source":"192.0.2.10"' "$STATE/answer")" -eq 1 ]
  [ "$(grep -c . "$STATE/answer")" -eq "$(grep -c . "$FIXTURES/answer.jsonl")" ]

  audit_recipe
  echo "status $status; $output"
  echo "stderr: $stderr"
  [ "$status" -eq 0 ]
  # One line for each verdict, deciding namespace, direction, source, destination, port and reason,
  # the most frequent first: the proxies' two pods to hello's two are one line of 3 flows, and two
  # nights' dump jobs, each with a job's own labels and an address of its own to reach, one of 2.
  # A proxy on another node than the one that reported the flow has no workload in the line and is
  # named by its pod, on a line of its own.
  [ "$output" = "$TABLE" ]
  no_address "$output"
  no_address "$stderr"
  # Then, on standard error: the recorder's lines that are no flows, with the query that shows them,
  # and that the recorder has run since before the window began.
  [[ $stderr == *"network-audit: 5 of the recorder's lines in the last 24h are not flows"* ]]
  [[ $stderr == *"just logs '$RECORDER_LINES | unpack_json | filter flow.verdict:\"\"' --since 24h lab-sto2"* ]]
  [[ $stderr == *"network-audit: the recorder has run since $started, before the last 24h began"* ]]
  [[ $stderr != *"is cut"* && $stderr != *"is not running"* && $stderr != *"inside the last"* ]]
  # It asks the store once, as just logs does, through a port-forward to vmauth's Service and port
  # with the operator's credential from the Secret vmauth-operator, with the one query whose answer
  # the fixture is, for the last 24 hours and at most 10000 groups.
  store_request
  echo "request: $REQUEST_ADDRESS $REQUEST_PATH; query: $QUERY; start: $START; limit: $LIMIT"
  [ "$REQUEST_ADDRESS" = 127.0.0.1:41234 ]
  [ "$REQUEST_PATH" = /select/logsql/query ]
  [ "$REQUEST_AUTHORIZATION" = "$AUTHORIZATION" ]
  [ "$QUERY" = "$STORE_QUERY" ]
  [ "$LIMIT" = 10000 ]
  seconds=$(($(date -u +%s) - $(date -u -d "$START" +%s)))
  echo "the window starts $seconds seconds ago"
  ((seconds >= 86399 && seconds <= 86410))
  grep -qx -- 'get secret vmauth-operator --namespace monitoring --output jsonpath={.data.authorization} --request-timeout=30s' "$RECORD/argv"
  grep -qx -- 'port-forward --namespace monitoring service/vmauth :8427 --address 127.0.0.1' "$RECORD/argv"
  no_credential "$output" "$stderr"
  forwards_closed
  # And the pods once, by the recorder's label in its namespace, reading only.
  [ "$(grep -c '^get pods ' "$RECORD/argv")" -eq 1 ]
  grep -qx -- 'get pods --namespace security-system --selector app.kubernetes.io/name=network-audit --output json --request-timeout=10s' "$RECORD/argv"
  [ "$(grep -c . "$RECORD/argv")" -eq 3 ]
  # kubectl is run with the cluster's kubeconfig and none of the secrets the recipes read.
  [ "$(sort -u "$RECORD/kubeconfig")" = "$KUBECONFIG_FILE" ]
  grep -qx KUBECONFIG "$RECORD/names"
  for name in "${AUDIT_SECRETS[@]}"; do
    echo "$name"
    if grep -qx "$name" "$RECORD/names"; then return 1; fi
  done

  # A window and a cluster: the window is the store's and the one the recorder's start is held to.
  rm "$RECORD/argv" "$RECORD/requests"
  audit_recipe 90m lab-sto2
  echo "status $status; $output"
  echo "stderr: $stderr"
  [ "$status" -eq 0 ]
  [ "$output" = "$TABLE" ]
  store_request
  seconds=$(($(date -u +%s) - $(date -u -d "$START" +%s)))
  echo "the window starts $seconds seconds ago"
  ((seconds >= 5399 && seconds <= 5410))
  [ "$LIMIT" = 10000 ]
  [[ $stderr == *"in the last 90m are not flows"*"--since 90m lab-sto2"* ]]
  [[ $stderr == *"before the last 90m began"* ]]

  # With no flow in the window it says so, and still says what else the recorder wrote: here its
  # lines that are no flows, the store's one group without a verdict.
  head -n 1 "$FIXTURES/answer.jsonl" >"$STATE/answer"
  [ "$(cat "$STATE/answer")" = '{"flows":"5"}' ]
  audit_recipe 7d
  echo "status $status; $output"
  [ "$status" -eq 1 ]
  [ "$output" = "no dropped or audited flow in the record of the last 7d" ]
  [[ $stderr == *"5 of the recorder's lines in the last 7d are not flows"* ]]
  # The recorder of three days ago started inside the last seven.
  [[ $stderr == *"the recorder's container started at $started, inside the last 7d"* ]]
  # And with no line of the recorder at all, as before it ever ran, for which the store answers
  # with nothing.
  : >"$STATE/answer"
  audit_recipe
  echo "status $status; $output"
  [ "$status" -eq 0 ]
  [ "$output" = "no dropped or audited flow in the record of the last 24h" ]
  [[ $stderr != *"are not flows"* && $stderr != *"is not a flow"* ]]
  [[ $stderr == *"the recorder has run since $started"* ]]

  # What the store's answer above does not hold, in groups written here as the store writes one: a
  # flow over SCTP, audited, with a drop reason, which an audited flow of the pinned Cilium has not;
  # a workload and a list of labels that are no JSON, as a value cut short would be, which leave the
  # pod's name and no name; a pod's name with a bell, a tab, a line end, a space and a delete in
  # it; a direction that is neither of the two; labels of which none is a reserved name, one of
  # them with an address; a port that is an address; a dropped flow without a reason; and one line
  # that is no flow.
  cat >"$STATE/answer" <<'EOF'
{"flows":"4","flow.verdict":"AUDIT","flow.traffic_direction":"EGRESS","flow.drop_reason_desc":"POLICY_DENIED","flow.source.namespace":"demo","flow.source.pod_name":"hello-5d9c7b6f4d-abcde","flow.source.workloads":"[{\"name\":\"hello\",\"kind\":\"Deployment\"}]","flow.source.labels":"[\"k8s:app.kubernetes.io/name=hello\"]","flow.destination.labels":"[\"reserved:world\"]","flow.l4.SCTP.destination_port":"3868"}
{"flows":"2","flow.verdict":"AUDIT","flow.traffic_direction":"INGRESS","flow.source.labels":"[\"reserved:wor","flow.destination.namespace":"demo","flow.destination.pod_name":"he\u0007l\tl\no -\u007f5d9c","flow.destination.workloads":"[{\"name\":\"hel","flow.l4.TCP.destination_port":"8080"}
{"flows":"1","flow.verdict":"DROPPED","flow.traffic_direction":"SIDEWAYS","flow.source.namespace":"demo","flow.source.labels":"[\"reserved:World 192.0.2.99\",\"k8s:app=x\"]","flow.destination.namespace":"demo","flow.destination.labels":"[\"cidr:203.0.113.5/32\"]","flow.l4.TCP.destination_port":"192.0.2.5"}
{"flows":"1"}
EOF
  audit_recipe
  echo "status $status; $output"
  echo "stderr: $stderr"
  [ "$status" -eq 0 ]
  [ "$output" = '4 AUDIT demo egress demo/Deployment/hello @world 3868/sctp -
2 AUDIT demo ingress @unknown demo/hello-5d9c 8080/tcp -
1 DROPPED - - @unknown @unknown 0/other -' ]
  no_address "$output"
  [[ $stderr == *"network-audit: 1 of the recorder's lines in the last 24h is not a flow"* ]]
  [[ $stderr == *"just logs '$RECORDER_LINES | unpack_json | filter flow.verdict:\"\"' --since 24h lab-sto2"* ]]
}

@test "The audit recipe fails, after the table, when the recorder did not run through the window" {
  local at table_end note seconds order
  audit_copy

  # A container started inside the window: named with its start time, after the table, and the run
  # fails, as flows from before it started are not in the record.
  at="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
  echo "$at" >"$STATE/time"
  audit_recipe
  echo "started inside: status $status; $stderr"
  [ "$status" -eq 1 ]
  [ "$output" = "$TABLE" ]
  [[ $stderr == *"network-audit: the recorder's container started at $at, inside the last 24h: what was dropped before that is not in the record"* ]]
  [[ $stderr != *"has run since"* ]]
  no_address "$stderr"
  # The table comes first, whole, and what the run says of the record after it.
  audit_merged
  [ "$status" -eq 1 ]
  table_end="$(grep -n -F -x -- "$(tail -n 1 <<<"$TABLE")" <<<"$output" | cut -d: -f1)"
  note="$(grep -n -F -- "the recorder's container started at $at" <<<"$output" | cut -d: -f1)"
  echo "the table ends on line $table_end; the recorder's start is on line $note"
  [ "$(head -n 10 <<<"$output")" = "$TABLE" ]
  [ "$table_end" -eq 10 ] && [ "$note" -gt 10 ]
  [ "$(grep -n -F -- "are not flows" <<<"$output" | cut -d: -f1)" -gt 10 ]
  # A shorter window that began after it started passes.
  audit_recipe 90m
  [ "$status" -eq 0 ]
  [[ $stderr == *"the recorder has run since $at, before the last 90m began"* ]]
  # A window in weeks and one in seconds hold the start alike, and ask the store for the same
  # window: a start just inside is named and fails the run, and one just before it passes.
  at="$(date -u -d '-13 days' +%Y-%m-%dT%H:%M:%SZ)"
  echo "$at" >"$STATE/time"
  rm "$RECORD/argv" "$RECORD/requests"
  audit_recipe 2w
  echo "inside 2w: status $status; $stderr"
  [ "$status" -eq 1 ]
  [[ $stderr == *"the recorder's container started at $at, inside the last 2w"* ]]
  store_request
  seconds=$(($(date -u +%s) - $(date -u -d "$START" +%s)))
  ((seconds >= 1209599 && seconds <= 1209610))
  date -u -d '-15 days' +%Y-%m-%dT%H:%M:%SZ >"$STATE/time"
  audit_recipe 2w
  echo "before 2w: status $status; $stderr"
  [ "$status" -eq 0 ]
  [[ $stderr == *"before the last 2w began"* ]]
  at="$(date -u -d '-60 seconds' +%Y-%m-%dT%H:%M:%SZ)"
  echo "$at" >"$STATE/time"
  rm "$RECORD/argv" "$RECORD/requests"
  audit_recipe 90s
  echo "inside 90s: status $status; $stderr"
  [ "$status" -eq 1 ]
  [[ $stderr == *"the recorder's container started at $at, inside the last 90s"* ]]
  store_request
  seconds=$(($(date -u +%s) - $(date -u -d "$START" +%s)))
  ((seconds >= 89 && seconds <= 100))
  date -u -d '-120 seconds' +%Y-%m-%dT%H:%M:%SZ >"$STATE/time"
  audit_recipe 90s
  echo "before 90s: status $status; $stderr"
  [ "$status" -eq 0 ]
  [[ $stderr == *"before the last 90s began"* ]]
  at="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
  echo "$at" >"$STATE/time"

  # No running container: the recorder is not running, said with its state and when it last ended.
  echo waiting >"$STATE/pods"
  audit_recipe
  echo "not running: status $status; $stderr"
  [ "$status" -eq 1 ]
  [ "$output" = "$TABLE" ]
  [[ $stderr == *"network-audit: the recorder is not running (CrashLoopBackOff; its container last ended at $at): what is dropped meanwhile is not in the record"* ]]
  [[ $stderr != *"has run since"* && $stderr != *"back-off"* ]]
  no_address "$stderr"
  # And however long ago that was: a recorder that is down now did not run through any window.
  date -u -d '-30 days' +%Y-%m-%dT%H:%M:%SZ >"$STATE/time"
  audit_recipe 90m
  [ "$status" -eq 1 ]
  [[ $stderr == *"the recorder is not running"* ]]

  # A pod no node runs yet has no container to speak of: its phase is all that is said.
  echo pending >"$STATE/pods"
  audit_recipe
  echo "pending: status $status; $stderr"
  [ "$status" -eq 1 ]
  [ "$output" = "$TABLE" ]
  [[ $stderr == *"network-audit: the recorder is not running (Pending): what is dropped meanwhile is not in the record"* ]]
  [[ $stderr != *"nodes are available"* ]]
  no_address "$stderr"

  # A pod on its way out does not count: beside one that has run for 30 days and is deleted, the
  # recorder is the new pod, whose container started inside the window.
  echo replaced >"$STATE/pods"
  at="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
  echo "$at" >"$STATE/time"
  audit_recipe
  echo "replaced: status $status; $stderr"
  [ "$status" -eq 1 ]
  [[ $stderr == *"network-audit: the recorder's container started at $at, inside the last 24h"* ]]
  [[ $stderr != *"has run since"* ]]

  # Two recorders running, as when a second pod is started beside the first: the one that started
  # first has followed the whole window, so the record holds it, whichever the listing names first:
  # the later one, then the earlier one.
  at="$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ)"
  echo "$at" >"$STATE/time"
  for order in overlap overlap-reversed; do
    echo "$order" >"$STATE/pods"
    audit_recipe
    echo "two running, $order: status $status; $stderr"
    [ "$status" -eq 0 ]
    [[ $stderr == *"network-audit: the recorder has run since $at, before the last 24h began"* ]]
    [[ $stderr != *"inside the last"* ]]
  done

  # No pod at all.
  echo none >"$STATE/pods"
  audit_recipe
  echo "no pod: status $status; $stderr"
  [ "$status" -eq 1 ]
  [ "$output" = "$TABLE" ]
  [[ $stderr == *"network-audit: no pod of the recorder exists in security-system: nothing is recorded"* ]]

  # A listing that fails: the run cannot tell, fails, and shows nothing kubectl printed, on either
  # of its outputs.
  echo fail >"$STATE/pods"
  audit_recipe
  echo "listing failed: status $status; $stderr"
  [ "$status" -eq 1 ]
  [ "$output" = "$TABLE" ]
  [[ $stderr == *"network-audit: cannot tell whether the recorder ran through the last 24h: listing its pod through the kubeconfig failed"* ]]
  [[ $stderr != *"Unable to connect"* && $stderr != *"printed before"* && $stderr != *6443* && $stderr != *"was slow"* ]]
  no_address "$stderr"

  # So does a listing that is no list, and a start time that is no time: neither is shown.
  echo garbage >"$STATE/pods"
  audit_recipe
  echo "no list: status $status; $stderr"
  [ "$status" -eq 1 ]
  [ "$output" = "$TABLE" ]
  [[ $stderr == *"network-audit: cannot tell whether the recorder ran through the last 24h: the listing of its pod holds no state the recipe reads"* ]]
  [[ $stderr != *"Unexpected answer"* ]]
  no_address "$stderr"
  echo running >"$STATE/pods"
  echo 'soon, at 192.0.2.10' >"$STATE/time"
  audit_recipe
  echo "no time: status $status; $stderr"
  [ "$status" -eq 1 ]
  [[ $stderr == *"network-audit: cannot tell whether the recorder ran through the last 24h: the listing of its pod holds no state the recipe reads"* ]]
  [[ $stderr != *soon* ]]
  no_address "$stderr"

  # An answer of as many groups as the limit is cut: said so, and the run fails though the recorder
  # ran through the window. One group fewer is whole.
  echo running >"$STATE/pods"
  date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ >"$STATE/time"
  awk 'BEGIN { for (i = 1; i <= 10000; i++)
    printf "{\"flows\":\"1\",\"flow.verdict\":\"AUDIT\",\"flow.traffic_direction\":\"EGRESS\",\"flow.source.namespace\":\"demo\",\"flow.source.pod_name\":\"pod-%d\",\"flow.source.labels\":\"[]\",\"flow.destination.labels\":\"[\\\"reserved:world\\\"]\",\"flow.l4.TCP.destination_port\":\"443\"}\n", i }' >"$STATE/answer"
  audit_recipe
  echo "at the limit: status $status; $(wc -l <<<"$output") lines; $stderr"
  [ "$status" -eq 1 ]
  [ "$(wc -l <<<"$output")" -eq 10000 ]
  [[ $stderr == *"network-audit: the store answered with 10000 groups, as many as the recipe asks for at most: the table is cut"* ]]
  [[ $stderr == *"has run since"* ]]
  sed -i '$d' "$STATE/answer"
  audit_recipe
  echo "below the limit: status $status; $(wc -l <<<"$output") lines"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<<"$output")" -eq 9999 ]
  [[ $stderr != *"is cut"* ]]

  # Each run lists the pods once, by the recorder's label in security-system.
  [ "$(sort -u <(grep '^get pods ' "$RECORD/argv"))" = 'get pods --namespace security-system --selector app.kubernetes.io/name=network-audit --output json --request-timeout=10s' ]
  [ "$(grep -c '^get pods ' "$RECORD/argv")" -eq "$(grep -c . "$RECORD/requests")" ]
}

@test "The audit recipe refuses a window that is not a duration and says why when the store does not answer" {
  local since line
  audit_copy

  # A window that is no duration, an option and a third argument are refused with the usage, exit 2,
  # before kubectl is called.
  for since in soon 24 h 0h 1h30m 24H '24 h' 1.5h; do
    audit_recipe "$since"
    echo "since '$since': status $status; $stderr"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ $stderr == *"network-audit: since is not a duration: a whole number with s, m, h, d or w, such as 90m or 24h"* ]]
    [[ $stderr == *"usage: network-audit [since] [cluster]"* ]]
  done
  # shellcheck disable=SC2016 # $1 is the inner shell's.
  run --separate-stderr env -i HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" bash -c 'cd "$1" && scripts/network-audit --since 24h' _ "$COPY"
  echo "an option: status $status; $stderr"
  [ "$status" -eq 2 ]
  [[ $stderr == *"usage: network-audit [since] [cluster]"* ]]
  # shellcheck disable=SC2016 # $1 is the inner shell's.
  run --separate-stderr env -i HOME="$BATS_TEST_TMPDIR" TMPDIR="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" bash -c 'cd "$1" && scripts/network-audit 24h lab-sto2 more' _ "$COPY"
  echo "a third argument: status $status; $stderr"
  [ "$status" -eq 2 ]
  [[ $stderr == *"usage: network-audit [since] [cluster]"* ]]
  [ ! -e "$RECORD/argv" ]

  # A query the store refuses fails with the store's own message, as just logs words it, without the
  # address it names, and nothing of the recipe's own: no table, no word on the recorder.
  echo refuse >"$STATE/store"
  audit_recipe
  echo "refused: status $status; $stderr"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # shellcheck disable=SC2016 # The backticks are the store's own.
  [[ $stderr == *'logs: vmauth or VictoriaLogs refused the query: cannot parse `query` arg: cannot parse "stats" pipe at <address>: unexpected token'* ]]
  no_address "$stderr"
  while IFS= read -r line; do
    # shellcheck disable=SC2016 # The backticks are just's own.
    [[ $line == "logs: "* || $line == 'error: recipe `network-audit` failed '* ]] || { echo "not a line of just logs: $line"; return 1; }
  done <<<"$stderr"
  [ "$(grep -c '^get pods ' "$RECORD/argv" || true)" -eq 0 ]
  no_credential "$output" "$stderr"
  forwards_closed

  # A kubeconfig that may not read the operator's credential is shown as kubectl words it, before
  # any port is forwarded.
  echo forbidden >"$STATE/store"
  rm -f "$RECORD/argv"
  audit_recipe
  echo "forbidden: status $status; $stderr"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ $stderr == *'logs: cannot read the Secret vmauth-operator in monitoring: secrets "vmauth-operator" is forbidden'* ]]
  [[ $stderr != *"network-audit:"* ]]
  [ "$(grep -c 'port-forward' "$RECORD/argv" || true)" -eq 0 ]

  # An API that does not answer.
  echo down >"$STATE/store"
  audit_recipe
  echo "down: status $status; $stderr"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ $stderr == *"logs: the Kubernetes API did not answer"* ]]
  [[ $stderr != *"network-audit:"* && $stderr != *6443* ]]
  no_address "$stderr"
  [ "$(grep -c '^get pods ' "$RECORD/argv" || true)" -eq 0 ]

  # An answer that is not what the store sends is no success: not JSON lines, which just logs says,
  # and lines whose count the recipe cannot read, which it says itself.
  echo ok >"$STATE/store"
  echo '<html>bad gateway</html>' >"$STATE/answer"
  audit_recipe
  echo "not records: status $status; $stderr"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ $stderr == *"logs: VictoriaLogs answered with something that is not JSON lines"* ]]
  echo '{"flow.verdict":"AUDIT","flows":"many"}' >"$STATE/answer"
  audit_recipe
  echo "no count: status $status; $stderr"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ $stderr == *"network-audit: failed while reading the store's answer"* ]]

  # Without a kubeconfig it says where one comes from, and calls nothing.
  rm -f "$RECORD/argv"
  rm "$KUBECONFIG_FILE"
  audit_recipe
  echo "no kubeconfig: status $status; $stderr"
  [ "$status" -ne 0 ]
  [[ $stderr == *"talos/lab-sto2/clusterconfig/kubeconfig does not exist; just cluster-kubeconfig fetches it"* ]]
  [ ! -e "$RECORD/argv" ]
}

@test "The docs turn enforcement on from a day of the record and say how long it is kept" {
  local values="$REPO/kubernetes/apps/base/monitoring/victoria-logs/app/values.yaml" retention cap record steps step enforce listed default rules rule alert
  local denying nightly job name schedule fields at database named holding waited
  # The record has its own section, in Network policy, right before the steps that turn enforcement
  # on.
  [ "$(grep -c '^### The record of what policy drops$' "$DOCS")" -eq 1 ]
  [ "$(awk '/^## Network policy$/ { on = 1; next } on && /^## / { exit } on && /^### / { print }' "$DOCS" |
    grep -A1 -x '### The record of what policy drops' | paste -sd'|' -)" = '### The record of what policy drops|### Turning it on, and back' ]
  record="$(record_section | flat)"
  [ -n "$record" ]
  # How long the record is kept is the store's retention: its days and its size cap, as the store's
  # values have them, which is what the rendered store runs with (tests/logs.bats).
  retention="$(yq '.server.retentionPeriod' "$values")"
  cap="$(yq '.server.retentionDiskSpaceUsage' "$values")"
  echo "the store keeps: $retention, $cap"
  [[ $retention =~ ^([1-9][0-9]*)d$ ]] || { echo "the store's retention, $retention, is not a number of days the docs' sentence can be held to"; return 1; }
  [[ $record == *"keeps them ${BASH_REMATCH[1]} days"* ]] ||
    { echo "the store's values keep logs $retention, and the section on the record does not say \"keeps them ${BASH_REMATCH[1]} days\""; return 1; }
  [[ $cap =~ ^([1-9][0-9]*)GiB$ ]] || { echo "the store's size cap, $cap, is not a number of GiB the docs' sentence can be held to"; return 1; }
  [[ $record == *"once they take ${BASH_REMATCH[1]} GiB"* ]] ||
    { echo "the store's values cap its data at $cap, and the section on the record does not say \"once they take ${BASH_REMATCH[1]} GiB\""; return 1; }
  # The section names the recipe, its columns and the query that finds the lines.
  # shellcheck disable=SC2016 # The backticks are the docs' own, here and in the patterns below.
  [[ $record == *'`just network-audit [since] [cluster]`'* ]]
  # shellcheck disable=SC2016
  [[ $record == *'`COUNT VERDICT NAMESPACE DIRECTION SOURCE DESTINATION PORT/PROTOCOL REASON`'* ]]
  [[ $record == *"$RECORDER_LINES"* ]]
  # The steps turn enforcement on from a day of it: step 3 asks for the recipe over 24 hours, which
  # is the recipe's own default, to exit 0 with no AUDIT line of a namespace that holds the default
  # deny, and still names just network-drops, for what the agents hold at that moment.
  steps="$(turning_on)"
  step="$(awk '/^3\. \*\*/ { on = 1 } on && /^4\. \*\*/ { exit } on' <<<"$steps" | flat)"
  [ -n "$step" ]
  # shellcheck disable=SC2016
  [[ $step == *'`just network-audit 24h` must exit 0 and print no `AUDIT` line whose `NAMESPACE` is'* ]] ||
    { echo "step 3 does not ask for just network-audit 24h to exit 0 with no AUDIT line of a namespace that holds the default deny"; return 1; }
  # shellcheck disable=SC2016
  [[ $step == *'`just network-drops` stays for what the agents hold at this moment'*'It needs neither the recorder nor the log store'* ]]
  # The window holds the night's dump and backup, and the lines of flux-system are expected.
  [[ $step == *"02:00"*"03:17"* ]]
  # shellcheck disable=SC2016
  [[ $step == *'`AUDIT` lines whose `NAMESPACE` is `flux-system` are expected'* ]]
  # The window holds every job the render schedules in a namespace that holds the default deny: the
  # step names the time each starts, and the dump and the volume backup are two of them. A database
  # there that archives its WAL, which it does as each segment fills, has the step force a segment.
  real_render
  denying="$(find "$REAL" -name 'NetworkPolicy.networking.k8s.io_*_default-deny.yaml' -exec yq -N '.metadata.namespace' {} + | LC_ALL=C sort -u)"
  nightly=0
  while IFS= read -r job; do
    grep -qxF -- "$(yq '.metadata.namespace' "$job")" <<<"$denying" || continue
    name="$(yq '.kind + " " + .metadata.namespace + "/" + .metadata.name' "$job")"
    schedule="$(yq '.spec.schedule // .spec.trigger.schedule // ""' "$job")"
    read -ra fields <<<"$schedule"
    ((${#fields[@]} != 6)) || fields=("${fields[@]:1}")
    if ((${#fields[@]} != 5)) || [[ ! ${fields[0]} =~ ^[0-9]{1,2}$ || ! ${fields[1]} =~ ^[0-9]{1,2}$ || ${fields[*]:2} != '* * *' ]]; then
      echo "$name runs on '$schedule', not once a day at a time step 3 can name"
      return 1
    fi
    at="$(printf '%02d:%02d' "$((10#${fields[1]}))" "$((10#${fields[0]}))")"
    echo "$name starts at $at"
    [[ $step == *"$at"* ]] || { echo "step 3 does not name $at, when $name starts: the night the record covers is to hold it"; return 1; }
    nightly=$((nightly + 1))
  done < <(find "$REAL" \( -name 'CronJob.batch_*' -o -name 'ScheduledBackup.postgresql.cnpg.io_*' -o -name 'ReplicationSource.volsync.backube_*' \) | LC_ALL=C sort)
  ((nightly >= 2))
  while IFS= read -r database; do
    grep -qxF -- "$(yq '.metadata.namespace' "$database")" <<<"$denying" || continue
    # shellcheck disable=SC2016 # The backticks are the docs' own.
    [ "$(yq '[.spec.plugins // [] | .[] | select(.isWALArchiver == true)] | length' "$database")" -eq 0 ] ||
      [[ $step == *'`select pg_switch_wal()`'* ]] ||
      { echo "$(yq '.metadata.namespace + "/" + .metadata.name' "$database") archives its WAL, and step 3 does not force a segment with select pg_switch_wal()"; return 1; }
  done < <(find "$REAL" -name 'Cluster.postgresql.cnpg.io_*' | LC_ALL=C sort)
  # The namespaces whose AUDIT lines the step forbids are those the render gives the default deny.
  # shellcheck disable=SC2016 # The backticks are the docs' own.
  named="$(grep -o 'that holds the default deny: [^.]*\.' <<<"$step" | grep -o '`[a-z0-9-]*`' | tr -d '`' | LC_ALL=C sort | paste -sd' ' -)"
  [ "$named" = "$(paste -sd' ' - <<<"$denying")" ] ||
    { echo "step 3 names ${named:-no namespace} as holding the default deny, and the render gives it to $(paste -sd' ' - <<<"$denying")"; return 1; }
  # The Kustomizations the step waits for are those of the render that hold an allow in one of those
  # namespaces: any policy there but the default deny, which the root applies.
  holding="$(while IFS= read -r name; do
    find "$REAL" -mindepth 3 -maxdepth 3 \( -name "CiliumNetworkPolicy.cilium.io_${name}_*" -o -name "NetworkPolicy.networking.k8s.io_${name}_*" \) \
      ! -name "NetworkPolicy.networking.k8s.io_${name}_default-deny.yaml" -printf '%h\n'
  done <<<"$denying" | sed 's|.*/||' | LC_ALL=C sort -u | paste -sd' ' -)"
  # shellcheck disable=SC2016 # The backticks are the docs' own.
  waited="$(grep -o 'the Kustomizations that hold the allows, [^(]*are Ready' <<<"$step" | grep -o '`[a-z0-9-]*`' | tr -d '`' | LC_ALL=C sort | paste -sd' ' -)"
  [ "$waited" = "$holding" ] ||
    { echo "step 3 waits for ${waited:-no Kustomization} to be Ready, and the Kustomizations of the render that hold the allows of those namespaces are $holding"; return 1; }
  default="$(just --justfile "$REPO/justfile" --dump --dump-format json | jq -r '.recipes["network-audit"].parameters | map(select(.name == "since")) | .[0].default')"
  echo "the recipe's default window: $default"
  [ "$default" = 24h ]
  # Step 4 and the paragraph on a listed namespace read DROPPED lines with their reason from the
  # record, and neither sends the reader to the agents' recent flows.
  enforce="$(awk '/^4\. \*\*/ { on = 1 } on && /^5\. \*\*/ { exit } on' <<<"$steps" | flat)"
  listed="$(awk '/^\*\*A listed namespace that takes the posture/ { on = 1 } on' <<<"$steps" | flat)"
  [ -n "$enforce" ] && [ -n "$listed" ]
  # shellcheck disable=SC2016
  [[ $enforce == *'`just network-audit` then prints, where a policy denied, `DROPPED` lines with the reason `POLICY_DENIED`'* ]]
  # shellcheck disable=SC2016
  [[ $listed == *'`just network-audit`: a `DROPPED` line whose `NAMESPACE` is the namespace, with the reason `POLICY_DENIED`'* ]]
  # shellcheck disable=SC2016
  [[ $enforce != *'`just network-drops`'* && $listed != *'`just network-drops`'* ]]
  # No alert reads the record: the docs name the monitoring chart's alerts that fire for a recorder
  # that is not available, and the render holds them, for every namespace, as the docs describe them:
  # the Deployment short of its replica while no rollout moves, the container crash-looping, the pod
  # pending or not ready, and the container waiting for another reason.
  real_render
  rules=("$REAL"/*/kube-prometheus-stack/PrometheusRule.monitoring.coreos.com_monitoring_kube-prometheus-stack-kubernetes-apps.yaml)
  [ -f "${rules[0]}" ]
  for alert in KubeDeploymentReplicasMismatch:15m KubePodCrashLooping:15m KubePodNotReady:15m KubeContainerWaiting:1h; do
    rule="$(ALERT=${alert%%:*} yq -o json -I0 '.spec.groups[].rules[] | select(.alert == strenv(ALERT))' "${rules[0]}")"
    [ "$(grep -c . <<<"$rule")" -eq 1 ] || { echo "the render holds $(grep -c . <<<"$rule") rules ${alert%%:*}"; return 1; }
    echo "${alert%%:*}: $(jq -r '.expr' <<<"$rule" | flat)"
    [ "$(jq -r '.for' <<<"$rule")" = "${alert#*:}" ]
    [ "$(jq -r '.labels.severity' <<<"$rule")" = warning ]
    [[ $(jq -r '.expr' <<<"$rule") == *'namespace=~".*"'* ]]
    grep -qF "\`${alert%%:*}\`" <(record_section)
  done
  [ "$(yq -o json -I0 '.spec.groups[].rules[] | select(.alert == "KubeDeploymentReplicasMismatch") | .expr' "${rules[0]}" | jq -r . | flat)" \
    = '( kube_deployment_spec_replicas{job="kube-state-metrics", namespace=~".*"} > kube_deployment_status_replicas_available{job="kube-state-metrics", namespace=~".*"} ) and ( changes(kube_deployment_status_replicas_updated{job="kube-state-metrics", namespace=~".*"}[10m]) == 0 )' ]
  [ "$(yq -o json -I0 '.spec.groups[].rules[] | select(.alert == "KubePodCrashLooping") | .expr' "${rules[0]}" | jq -r . | flat)" \
    = 'max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff", job="kube-state-metrics", namespace=~".*"}[5m]) >= 1' ]
  [[ $(yq -o json -I0 '.spec.groups[].rules[] | select(.alert == "KubePodNotReady") | .expr' "${rules[0]}" | jq -r . | flat) \
    == *'phase=~"Pending|Unknown"'*'condition="true"} == 0'*'kube_pod_owner{owner_kind!="Job"}'* ]]
  [ "$(yq -o json -I0 '.spec.groups[].rules[] | select(.alert == "KubeContainerWaiting") | .expr' "${rules[0]}" | jq -r . | flat)" \
    = 'kube_pod_container_status_waiting_reason{reason!="CrashLoopBackOff", job="kube-state-metrics", namespace=~".*"} > 0' ]
  [[ $record == *"no alert reads the record"* ]]
  # And nothing in the render evaluates rules over the log store: no vmalert, VictoriaMetrics' rules
  # engine, no object of its operator's, and no alert rule group of Grafana's, which could query the
  # store's datasource.
  [ "$(grep -rlE 'image: .*vmalert' "$REAL" | grep -c . || true)" -eq 0 ]
  [ "$(grep -rlE '^apiVersion: operator\.victoriametrics\.com/' "$REAL" | grep -c . || true)" -eq 0 ]
  [ "$(find "$REAL" -name 'GrafanaAlertRuleGroup.*' | grep -c . || true)" -eq 0 ]
}
