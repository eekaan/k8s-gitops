#!/usr/bin/env bats
# Proves features/locust.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq, jq, kyverno, git and just on PATH (the versions pinned for the
# repository). Building is offline, with the placeholders of the cluster's example key lists; the
# tests of the flows read the render of the tree, whose charts are pulled once per run from their
# public registries. just locust runs from a copy of the scripts against a recording kubectl, which
# reaches no cluster.

# The tests run one at a time even where bats runs a file's tests side by side: the tests that read
# the render share one, made by whichever of them comes first.
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
  NAMESPACE=locust
  APP="$REPO/kubernetes/apps/base/locust/locust"
  OVERLAY_DIR="$REPO/kubernetes/apps/overlays/lab-sto2"
  MASTER=locust/Deployment/locust-master
  WORKER=locust/Deployment/locust-worker
  HELLO=demo/Deployment/hello
  # The pods of the render the flows are asked of, and pods no render holds, by their labels: the
  # public Gateway's proxies, which Envoy Gateway makes at run time, the cluster's resolver, an
  # application of another namespace, a pod of locust that is neither the master nor a worker, and
  # a pod of another namespace that carries the workers' labels.
  PROXY='envoy-gateway-system:app.kubernetes.io/name=envoy,app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,gateway.envoyproxy.io/owning-gateway-name=public,gateway.envoyproxy.io/owning-gateway-namespace=envoy-gateway-system'
  DNS='kube-system:k8s-app=kube-dns'
  OTHER_APP='other:app.kubernetes.io/name=app'
  STRAY='locust:app.kubernetes.io/name=locust,app.kubernetes.io/component=stray'
  IMPOSTOR='other:app.kubernetes.io/name=locust,app.kubernetes.io/component=worker'
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  VARS="$BATS_TEST_TMPDIR/example-vars.yaml"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$VARS"
}

# overlay [DIR]: the lab-sto2 overlay as Flux reads it, its namespaces and the Kustomization of each
# enabled application. Writes $OVERLAY.
overlay() {
  OVERLAY="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "${1:-$OVERLAY_DIR}" >"$OVERLAY"
}

# with_vars NAME FILE: the Flux Kustomization NAME of FILE, with the example key lists under its own
# substitutions.
with_vars() {
  # shellcheck disable=SC2016 # $vars is a yq variable.
  NAME="$1" yq ea 'select(fileIndex == 0) as $vars
    | select(fileIndex == 1 and .kind == "Kustomization" and .metadata.name == strenv(NAME))
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "$VARS" "$2"
}

# flux_build NAME KS: what the Flux Kustomization in the file KS applies, built from its spec.path
# with strict substitution. In memory: flux build otherwise rewrites the kustomization.yaml of what
# it builds, in the checkout, and puts it back afterwards.
flux_build() {
  local path
  path="$(yq '.spec.path' "$2")"
  (cd "$REPO" && flux build kustomization "$1" --path "./kubernetes/${path#./}" \
    --kustomization-file "$2" --dry-run --strict-substitute --in-memory-build)
}

# built: Locust as Flux applies it on lab-sto2. The cluster's root is built as Flux builds it, so
# the overlay's Kustomization of the application carries what the root patches into every child;
# that Kustomization is then built with the example key lists under its own substitutions. Writes
# the application's build to $BUILT and sets KS, the Kustomization as the root builds it, with
# those substitutions.
built() {
  local root="$CLUSTER/ks.yaml" path
  path="$(yq '.spec.path' "$root")"
  ROOT="$BATS_TEST_TMPDIR/root.yaml"
  (cd "$REPO" && flux build kustomization "$(yq '.metadata.name' "$root")" \
    --path "./kubernetes/${path#./}" --kustomization-file "$root" --dry-run --in-memory-build) >"$ROOT"
  KS="$BATS_TEST_TMPDIR/locust-ks.yaml"
  with_vars locust "$ROOT" >"$KS"
  [ -s "$KS" ] || { echo "the lab-sto2 overlay does not enable locust"; return 1; }
  BUILT="$BATS_TEST_TMPDIR/locust-built.yaml"
  flux_build locust "$KS" >"$BUILT"
}

# real_render: the render of this repository's tree, charts pulled, in $BATS_FILE_TMPDIR/render,
# made once for the file, and VIEW, the files of it that the evaluation of a flow reads (the
# namespaces, the workloads and the policies), as tests/network-policy.bats takes them. Sets REAL,
# VIEW and FLOWS, the directory the flows are asked of.
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
  FLOWS="$VIEW"
}

# rendered NAME: the path of the one file of the render named NAME, in any application.
rendered() {
  local files=("$REAL"/*/*/"$1")
  [ "${#files[@]}" -eq 1 ] && [ -f "${files[0]}" ] || { echo "$1 is not one file of the render: ${files[*]}" >&2; return 1; }
  echo "${files[0]}"
}

# object FILE KIND NAME: the one object of that kind and name in FILE.
object() {
  KIND="$2" NAME="$3" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$1"
}

# deployment NAME: writes the Deployment NAME of $BUILT to $DEPLOYMENT and its one container to
# $CONTAINER.
deployment() {
  DEPLOYMENT="$BATS_TEST_TMPDIR/deployment-$1.yaml"
  CONTAINER="$BATS_TEST_TMPDIR/container-$1.yaml"
  object "$BUILT" Deployment "$1" >"$DEPLOYMENT"
  [ -s "$DEPLOYMENT" ] || { echo "the build has no Deployment $1"; return 1; }
  [ "$(yq '.spec.template.spec.containers | length' "$DEPLOYMENT")" -eq 1 ] || { echo "the pod of $1 has not one container"; return 1; }
  yq '.spec.template.spec.containers[0]' "$DEPLOYMENT" >"$CONTAINER"
}

# restricted_failures FILE NAMESPACE: what the Pod Security restricted level refuses in the pod the
# workload in FILE makes in NAMESPACE, by Kyverno's podSecurity rule as pod-security-check runs it:
# writes the failed controls, one per line, to $CONTROLS and the whole message to $FORBIDDEN.
restricted_failures() {
  local dir
  dir="$BATS_TEST_TMPDIR/restricted-$(basename "$1" .yaml)"
  rm -rf "$dir"
  mkdir -p "$dir"
  NS="$2" yq -o json '{"apiVersion": "v1", "kind": "Pod",
    "metadata": {"name": .metadata.name, "namespace": strenv(NS)} * (.spec.template.metadata | pick(["labels", "annotations"])),
    "spec": .spec.template.spec}' "$1" >"$dir/pod.yaml"
  cat >"$dir/policy.yaml" <<'POLICY'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restricted
spec:
  validationFailureAction: Enforce
  rules:
    - name: restricted
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        podSecurity:
          level: restricted
          version: latest
POLICY
  # Exit 1 is a failed pod, which is the verdict; the report is the one line that starts with a brace.
  kyverno apply "$dir/policy.yaml" --resource "$dir/pod.yaml" -p --output-format json >"$dir/out" 2>"$dir/err" || [ $? -eq 1 ]
  grep '^{' "$dir/out" >"$dir/report.json"
  # A pod Kyverno gave no verdict on has not passed.
  jq -e '.results | length == 1 and (.[0].result == "pass" or .[0].result == "fail")' "$dir/report.json" >/dev/null ||
    { echo "Kyverno gave no verdict on the pod: $(cat "$dir/out" "$dir/err")"; return 1; }
  CONTROLS="$dir/controls"
  FORBIDDEN="$dir/forbidden"
  jq -r '.results[0] | select(.result == "fail") | .properties.controls // "" | split(",") | .[] | select(. != "")' "$dir/report.json" | LC_ALL=C sort >"$CONTROLS"
  jq -r '.results[0] | select(.result == "fail") | .message // ""' "$dir/report.json" >"$FORBIDDEN"
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

# of_namespace FILE: what an overlay built into FILE holds of Locust and of its namespace, sorted,
# as kind, namespace and name: the namespace itself, any object in it, and any Kustomization that
# deploys into it or from its directory.
of_namespace() {
  yq -N 'select((.kind == "Namespace" and .metadata.name == "locust") or .metadata.namespace == "locust"
      or .spec.targetNamespace == "locust" or ((.spec.path // "") | test("/apps/base/locust/")))
    | .kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$1" | LC_ALL=C sort | paste -sd, -
}

# allows FILE...: what the Cilium policies of the FILEs allow, one rule a line and sorted: the
# policy, the pods it selects, the direction, the peers and the ports. It fails on what it does not
# read rather than skip it: a policy with anything besides its selector, the default deny it leaves
# to the namespace and its two lists of rules; a peer that is neither pods by their labels nor an
# entity; a rule without a port; and a port that is not one number and a protocol. One jq program
# reads every policy, as jq run over each input in turn exits by the last input's result alone, and
# the pipe fails with it rather than end in sort's status.
allows() {
  local -
  set -o pipefail
  yq -o json -I0 'select(.kind == "CiliumNetworkPolicy")' "$@" | jq -nr '
    def only($what; $read): if (keys - $read | length) > 0 then error("\($what) holds \(keys - $read | join(", ")), which this test does not read") else . end;
    def pods($what): only($what; ["matchLabels"]) | .matchLabels | to_entries | map((.key | sub("^k8s:"; "")) + "=" + .value) | sort | join(",");
    def ports($what): [(.toPorts // error("\($what) names no port"))[] | only($what; ["ports"]) | .ports[] | only($what; ["port", "protocol"])
      | if (.port | type) == "string" and (.port | test("^[1-9][0-9]*$")) and (.protocol | IN("TCP", "UDP")) then .port + "/" + .protocol
        else error("\($what) names the port \(tojson), which is not one number and a protocol") end] | sort | join("+");
    def peers($what; $pods; $entities): [(.[$pods] // [])[] | pods($what)] + [(.[$entities] // [])[] | "@" + .]
      | if length == 0 then error("\($what) names no peer") else sort | join(" ") end;
    inputs | .metadata.name as $name | "the policy \($name)" as $what
    | only($what; ["apiVersion", "kind", "metadata", "spec"]) | .spec
    | only($what; ["endpointSelector", "enableDefaultDeny", "ingress", "egress"])
    | if .enableDefaultDeny != {"ingress": false, "egress": false} then error("\($what) does not leave the default deny to the namespace") else . end
    | (.endpointSelector | pods($what)) as $self
    | ((.ingress // [])[] | only($what; ["fromEndpoints", "fromEntities", "toPorts"])
        | "\($name) [\($self)] takes \(peers($what; "fromEndpoints"; "fromEntities")) on \(ports($what))"),
      ((.egress // [])[] | only($what; ["toEndpoints", "toEntities", "toPorts"])
        | "\($name) [\($self)] sends to \(peers($what; "toEndpoints"; "toEntities")) on \(ports($what))")' | LC_ALL=C sort
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

# probed FILE: the container ports the probes of the workload in FILE name, numbered, on one line.
probed() {
  yq -o json -I0 '.spec.template.spec' "$1" | jq -r '
    [.containers[] | . as $container | ($container.readinessProbe, $container.livenessProbe, $container.startupProbe) | select(. != null)
      | (.httpGet.port // .tcpSocket.port // .grpc.port) as $port | select($port != null)
      | if ($port | type) == "number" then $port else ($container.ports[] | select(.name == $port) | .containerPort) end]
    | unique | map(tostring) | join(" ")'
}

# forbidden FILE: each option of a container of the workloads in FILE that would start or shape a
# test, read a configuration file, send telemetry or put a sign-in hook in front of the interface,
# one per line as "<workload>/<container>: <token>". Every element of command and args is split on
# white space, so an option inside a shell command counts too. A long option counts in any prefix
# that names it, as Locust's parser takes an unambiguous abbreviation (argparse's allow_abbrev,
# which its parser leaves on), with its value after = or as the next token; a short one, -u, -r or
# -t, with its value attached or not.
forbidden() {
  local long='autostart headless autoquit users spawn-rate run-time processes config-users config otel web-login' where token name
  yq -o json -I0 'select(. != null)' "$1" | jq -r '
    select(.kind == "Pod" or .spec.template != null or .spec.jobTemplate != null) | . as $w
    | (if .kind == "Pod" then .spec elif .spec.template != null then .spec.template.spec else .spec.jobTemplate.spec.template.spec end) as $pod
    | (($pod.containers // []) + ($pod.initContainers // []) + ($pod.ephemeralContainers // []))[]
    | .name as $container | ((.command // []) + (.args // []))[] | splits("\\s+") | select(. != "")
    | "\($w.kind)/\($w.metadata.name)/\($container)\t\(.)"' |
    while IFS=$'\t' read -r where token; do
      if [[ $token =~ ^--([a-z-]+)(=.*)?$ ]]; then
        for name in $long; do
          if [[ $name == "${BASH_REMATCH[1]}"* ]]; then echo "$where: $token"; break; fi
        done
      elif [[ $token =~ ^-[urt] ]]; then
        echo "$where: $token"
      fi
    done
}

# containers FILE: every container of every pod template of FILE, as JSON, one a line.
containers() {
  yq -o json -I0 'select(. != null)' "$1" | jq -c '
    select(.kind == "Pod" or .spec.template != null or .spec.jobTemplate != null)
    | (if .kind == "Pod" then .spec elif .spec.template != null then .spec.template.spec else .spec.jobTemplate.spec.template.spec end)
    | ((.containers // []) + (.initContainers // []) + (.ephemeralContainers // []))[]'
}

# recipe_copy: a copy of the repository's scripts, with a kubeconfig for the cluster lab-sto2, for
# just locust to run in through the repository's justfile, against recording fakes: a mise with
# nothing installed, which keeps the justfile from putting real tools in front of the fakes, and a
# kubectl that records its arguments and the kubeconfig it was given, then acts as the file
# $STATE/mode says: forward reports a forward and runs until SIGTERM ends it, as kubectl does;
# silent runs without reporting one; fail stops at once with an error naming an address; drop
# reports a forward and stops a moment later. Sets COPY, BIN, RECORD, STATE, KUBECONFIG_FILE, JUST
# and ENVIRONMENT, the only variables the recipe gets.
recipe_copy() {
  COPY="$BATS_TEST_TMPDIR/copy" BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record" STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$COPY/talos/lab-sto2/clusterconfig" "$BIN" "$RECORD" "$STATE"
  cp -R "$REPO/scripts" "$COPY/scripts"
  KUBECONFIG_FILE="$COPY/talos/lab-sto2/clusterconfig/kubeconfig"
  echo 'not a real kubeconfig' >"$KUBECONFIG_FILE"
  echo forward >"$STATE/mode"
  JUST=$(command -v just)
  only
  printf '#!/usr/bin/env bash\n' >"$BIN/mise"
  { printf '#!/usr/bin/env bash\nRECORD=%q STATE=%q\n' "$RECORD" "$STATE"; cat <<'EOF'; } >"$BIN/kubectl"
printf '%s\n' "$*" >>"$RECORD/argv"
printf '%s\n' "${KUBECONFIG-unset}" >>"$RECORD/kubeconfig"
env | cut -d= -f1 >>"$RECORD/names"
echo "$$ $PPID" >"$STATE/pids"
last=${!#}
case $(cat "$STATE/mode") in
  fail)
    echo 'error: dial tcp 192.0.2.10:6443: connect: connection refused' >&2
    exit 1
    ;;
  forward | drop) echo "Forwarding from 127.0.0.1:${last%%:*} -> ${last##*:}" ;;
esac
trap 'echo SIGTERM >>"$RECORD/ended"; exit 0' TERM
if [[ $(cat "$STATE/mode") == drop ]]; then
  sleep 1
  echo 'error: lost connection to pod' >&2
  exit 1
fi
while :; do sleep 0.1; done
EOF
  chmod +x "$BIN/mise" "$BIN/kubectl"
}

# with ENTRY...: adds the NAME=VALUE ENTRY... to the environment just locust gets.
with() {
  ENVIRONMENT+=("$@")
}

# only ENTRY...: the environment just locust gets is TMPDIR and the NAME=VALUE ENTRY... alone.
only() {
  ENVIRONMENT=(TMPDIR="$BATS_TEST_TMPDIR" "$@")
}

# locust_recipe: runs just locust in the copy with only ENVIRONMENT set, failing after a minute
# rather than hanging.
locust_recipe() {
  run timeout 60 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$REPO/justfile" --working-directory "$COPY" locust
}

# locust_start: starts just locust as locust_recipe runs it, in the background, with its output in
# $BATS_TEST_TMPDIR/out. Sets OUT and JUST_PID.
locust_start() {
  OUT="$BATS_TEST_TMPDIR/out"
  env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$REPO/justfile" --working-directory "$COPY" locust >"$OUT" 2>&1 3>&- &
  JUST_PID=$!
}

# printed TEXT: waits up to 20 seconds for TEXT in OUT.
printed() {
  local tick
  for ((tick = 0; tick < 200; tick++)); do
    if grep -qF -- "$1" "$OUT"; then return 0; fi
    sleep 0.1
  done
  echo "no '$1' after 20 seconds in:"
  cat "$OUT"
  return 1
}

# finished: waits up to 20 seconds for just, started by locust_start, to end, and sets STATUS to
# its exit status.
finished() {
  local tick
  for ((tick = 0; tick < 200; tick++)); do
    if ! kill -0 "$JUST_PID" 2>/dev/null; then
      STATUS=0
      wait "$JUST_PID" || STATUS=$?
      return 0
    fi
    sleep 0.1
  done
  echo "just locust still runs after 20 seconds"
  return 1
}

# teardown: ends what a recipe test started, should it fail before it stopped it: just, which
# passes SIGTERM on to the recipe, and the last kubectl the fake recorded.
teardown() {
  local kubectl_pid
  if [[ -n ${JUST_PID:-} ]]; then
    kill -TERM "$JUST_PID" 2>/dev/null || true
  fi
  if [[ -s ${STATE:-/nonexistent}/pids ]]; then
    read -r kubectl_pid _ <"$STATE/pids"
    kill -TERM "$kubectl_pid" 2>/dev/null || true
  fi
}

# kubectl_gone: fails while the last kubectl the fake recorded still runs.
kubectl_gone() {
  local kubectl_pid
  read -r kubectl_pid _ <"$STATE/pids"
  if kill -0 "$kubectl_pid" 2>/dev/null; then
    echo "kubectl $kubectl_pid still runs"
    return 1
  fi
}

@test "Locust is selected by overlay entries and builds nothing when it is not" {
  local ks
  # The overlay selects it with two entries, the namespace directory and the application's ks.yaml,
  # beside the entry of its route, an application of its own in the namespace's directory.
  [ "$(yq '.resources[] | select(test("/locust(/|$)"))' "$OVERLAY_DIR/kustomization.yaml" | LC_ALL=C sort | paste -sd' ' -)" \
    = "../../base/locust ../../base/locust/locust-route/ks.yaml ../../base/locust/locust/ks.yaml" ]
  overlay
  [ "$(of_namespace "$OVERLAY")" = ConfigMap/locust/app-template-defaults,Kustomization/flux-system/locust,Kustomization/flux-system/locust-route,Namespace/-/locust,NetworkPolicy/locust/default-deny ]
  # The namespace directory holds what every namespace directory does: its namespace, its default
  # deny and the common component.
  [ "$(yq -o json -I0 '{"namespace": .namespace, "components": .components, "resources": .resources}' "$REPO/kubernetes/apps/base/locust/kustomization.yaml")" \
    = '{"namespace":"locust","components":["../../../components/common"],"resources":["namespace.yaml","networkpolicy-default-deny.yaml"]}' ]
  # It waits for the definition of its policies' kind alone, as it starts without its target, is
  # Ready only once its pods are, and substitutes one variable of its own, its target.
  ks="$(object "$OVERLAY" Kustomization locust | yq -o json -I0 '.spec')"
  [ "$(jq -c '.dependsOn | map(.name)' <<<"$ks")" = '["cilium"]' ]
  [ "$(jq -r '.wait' <<<"$ks")" = true ]
  [ "$(jq -r '.targetNamespace' <<<"$ks")" = "$NAMESPACE" ]
  [ "$(jq -r '.path' <<<"$ks")" = ./apps/base/locust/locust/app ]
  [ "$(jq -c '.postBuild.substitute | keys' <<<"$ks")" = '["LOCUST_TARGET"]' ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # With only the namespace directory's entry, the cluster builds the namespace, its defaults and
  # its default deny, and nothing of Locust or of its route.
  tree_without '/locust/locust(-route)?/ks.yaml$'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ "$(of_namespace "$OVERLAY")" = ConfigMap/locust/app-template-defaults,Namespace/-/locust,NetworkPolicy/locust/default-deny ]
  # With neither, nothing of the namespace.
  tree_without '/locust(/|$)'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ -z "$(of_namespace "$OVERLAY")" ]
  # Selecting it without cilium is refused, naming both.
  tree_without '/kube-system/cilium/ks.yaml$'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "without cilium: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"kubernetes/apps/base/locust/locust/ks.yaml: Kustomization locust names cilium"* ]]
  [[ $output == *"does not enable"* ]]
}

@test "Locust's master and workers run one image, pinned by tag and digest" {
  local name image images=() rules pattern tag
  built
  # The two Deployments make every pod of the application, one container each and nothing else.
  [ "$(yq -N 'select(.spec.template != null or .spec.jobTemplate != null or .kind == "Pod") | .kind + "/" + .metadata.name' "$BUILT" | LC_ALL=C sort | paste -sd' ' -)" \
    = "Deployment/locust-master Deployment/locust-worker" ]
  for name in locust-master locust-worker; do
    deployment "$name"
    [ "$(yq '.spec.template.spec | (.initContainers // []) + (.ephemeralContainers // []) | length' "$DEPLOYMENT")" -eq 0 ]
    image="$(yq '.image' "$CONTAINER")"
    echo "$name runs $image"
    # A release of three numbers, with the digest of its image index: a tag alone moves, and latest
    # or a build of master is no release.
    [[ $image =~ ^docker\.io/locustio/locust:([0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$ ]]
    tag="${BASH_REMATCH[1]}"
    images+=("$image")
  done
  # One reference: a worker of another version is only warned of, and one reference is what
  # Renovate moves in one pull request.
  [ "${images[0]}" = "${images[1]}" ]
  # Renovate's kubernetes manager reads it from both Deployments, as it reads every plain manifest's
  # image, and no custom manager does: the files hold no comment of Renovate's, and the tag forms
  # name no Locust.
  [ "$(awk -F'\t' '$3 == "docker.io/locustio/locust"' "$REPO/.renovate/extracted.tsv")" = "$(printf '%s\t%s\t%s\t%s\n' \
    kubernetes/apps/base/locust/locust/app/deployment-master.yaml kubernetes docker.io/locustio/locust - \
    kubernetes/apps/base/locust/locust/app/deployment-worker.yaml kubernetes docker.io/locustio/locust -)" ]
  [ -z "$(grep -n 'renovate' "$APP"/app/deployment-*.yaml || true)" ]
  [ -z "$(grep -n 'locust' "$REPO/.renovate/tag-forms.tsv" || true)" ]
  # One rule keeps Renovate to releases: the registry also tags builds of Locust's master branch as
  # x.y.z.devN, and holds master, latest and older pre-releases.
  rules="$(grep -v '^[[:space:]]*//' "$REPO/.renovate/managers.json5" | yq -o json -I0 '.packageRules')"
  [ "$(jq -c '[.[] | select([.matchPackageNames // [] | .[] | test("locust")] | any)] | map(del(.description))' <<<"$rules")" \
    = '[{"matchPackageNames":["docker.io/locustio/locust"],"allowedVersions":"/^[0-9]+\\.[0-9]+\\.[0-9]+$/"}]' ]
  pattern="$(jq -r '.[] | select((.matchPackageNames // []) | index("docker.io/locustio/locust")) | .allowedVersions | ltrimstr("/") | rtrimstr("/")' <<<"$rules")"
  [[ $tag =~ $pattern ]]
  for tag in 2.47.1.dev61 master latest reallylatest 2.0b4 sha-460908d; do
    if [[ $tag =~ $pattern ]]; then echo "the rule lets Renovate propose $tag"; return 1; fi
  done
  # It merges by the switch alone: no rule of the auto-merge file names it.
  [ "$(grep -v '^[[:space:]]*//' "$REPO/.renovate/automerge.json5" | yq -o json -I0 '.packageRules' |
    jq '[.[] | select(tojson | test("locust"))] | length')" -eq 0 ]
}

@test "Locust's pods meet the restricted level with a read-only root and no service account token" {
  local ns name mounts cm cpu memory limit
  built
  overlay
  # The namespace, as the overlay builds it, enforces restricted, keeps what runs in it when it
  # leaves the tree, and no workload of it is excepted. Its one other label lets its route attach to
  # the public Gateway.
  ns="$(object "$OVERLAY" Namespace "$NAMESPACE" | yq -o json -I0 '.metadata')"
  [ "$(jq -cS '.labels' <<<"$ns")" = '{"k8s-gitops/gateway":"public","pod-security.kubernetes.io/enforce":"restricted"}' ]
  [ "$(jq -r '.annotations["kustomize.toolkit.fluxcd.io/prune"]' <<<"$ns")" = disabled ]
  [ "$(NS="$NAMESPACE" yq '[.exceptions[] | select(.namespace == strenv(NS))] | length' "$REPO/pod-security-exceptions.yaml")" -eq 0 ]
  cm="$(yq -N 'select(.kind == "ConfigMap" and (.metadata.name | test("^locust-locustfile-"))) | .metadata.name' "$BUILT")"
  [ -n "$cm" ]
  for name in locust-master locust-worker; do
    deployment "$name"
    # The pod passes the restricted level, by the evaluator pod-security-check runs.
    restricted_failures "$DEPLOYMENT" "$NAMESPACE"
    echo "$name: failed controls: $(paste -sd' ' "$CONTROLS") $(cat "$FORBIDDEN")"
    [ ! -s "$CONTROLS" ]
    # The image's user is the name locust, uid and gid 1000, and the kubelet cannot hold a name to
    # runAsNonRoot, so the pod gives the numbers; the runtime's seccomp profile.
    [ "$(yq -o json -I0 '.spec.template.spec.securityContext' "$DEPLOYMENT" | jq -cS .)" \
      = '{"runAsGroup":1000,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}' ]
    # Locust calls no API: no token. And no Service of the namespace hands the pod variables, which
    # Locust would read as its options.
    [ "$(yq '.spec.template.spec.automountServiceAccountToken' "$DEPLOYMENT")" = false ]
    [ "$(yq '.spec.template.spec.enableServiceLinks' "$DEPLOYMENT")" = false ]
    [ "$(yq '.spec.template.spec | (.hostNetwork // false) or (.hostPID // false) or (.hostIPC // false)' "$DEPLOYMENT")" = false ]
    # Names resolve as the cluster's resolver answers them, the one the workers' egress names: no
    # host alias and no DNS setting of the pod's own.
    [ "$(yq -o json -I0 '.spec.template.spec | [has("hostAliases"), has("dnsPolicy"), has("dnsConfig")]' "$DEPLOYMENT")" = '[false,false,false]' ]
    [ "$(yq -o json -I0 '.securityContext' "$CONTAINER" | jq -cS .)" \
      = '{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}' ]
    # The mounts, as a set: the locustfile, read-only, and nothing the container can write to.
    mounts="$(yq -o json '.spec.template.spec' "$DEPLOYMENT" | jq -r '. as $pod | .containers[] | (.volumeMounts // [])[] | . as $m
      | ([$pod.volumes[] | select(.name == $m.name)][0] // {}) as $v
      | [$m.mountPath, ($v | del(.name) | keys | join("+")), ($v.configMap.name // "-"), (if $m.readOnly == true then "read-only" else "writable" end)] | join(" ")' | LC_ALL=C sort)"
    echo "$name mounts: $mounts"
    [ "$mounts" = "/mnt/locust configMap $cm read-only" ]
    [ "$(yq '[.spec.template.spec.volumes[] | .name + "=" + (del(.name) | keys | join("+"))] | join(" ")' "$DEPLOYMENT")" = locustfile=configMap ]
    # Requests of CPU and memory, a memory limit of twice the request, no CPU limit, within the caps.
    [ "$(yq -o json -I0 '.resources | {"requests": (.requests | keys), "limits": (.limits | keys)}' "$CONTAINER")" = '{"requests":["cpu","memory"],"limits":["memory"]}' ]
    cpu="$(yq '.resources.requests.cpu' "$CONTAINER")" memory="$(yq '.resources.requests.memory' "$CONTAINER")" limit="$(yq '.resources.limits.memory' "$CONTAINER")"
    echo "$name requests $cpu and $memory, limited to $limit"
    # One statement each: a failure inside an && list does not end a test.
    [[ $cpu =~ ^([1-9][0-9]*)m$ ]]
    ((BASH_REMATCH[1] <= 100))
    [[ $memory =~ ^([1-9][0-9]*)Mi$ ]]
    ((BASH_REMATCH[1] <= 256))
    [[ $limit =~ ^([1-9][0-9]*)Mi$ ]]
    ((BASH_REMATCH[1] <= 512))
    ((BASH_REMATCH[1] == 2 * ${memory%Mi}))
  done
}

@test "Locust's namespace denies traffic by default, and its workers reach the master, the resolver and the target and nothing else" {
  local deny policies probe flow want side from to port
  real_render
  # The namespace holds the default deny, every pod and both directions with no rule, and is not
  # listed among the namespaces without one.
  deny="$(rendered NetworkPolicy.networking.k8s.io_locust_default-deny.yaml)"
  [ "$(yq -o json -I0 '[.metadata.name, .spec]' "$deny" | jq -cS .)" = '["default-deny",{"podSelector":{},"policyTypes":["Ingress","Egress"]}]' ]
  [ "$(NS="$NAMESPACE" yq '[.exceptions[] | select(.namespace == strenv(NS))] | length' "$REPO/network-policy-exceptions.yaml")" -eq 0 ]
  # The policies of the namespace are the default deny and Locust's two, nothing else, beside the
  # sign-in's SecurityPolicy of its route, which is no network policy.
  [ "$(cd "$REAL" && find . -type f -name '*Policy*_locust_*' -printf '%f\n' | LC_ALL=C sort | paste -sd' ' -)" \
    = "CiliumNetworkPolicy.cilium.io_locust_locust-master.yaml CiliumNetworkPolicy.cilium.io_locust_locust-worker.yaml NetworkPolicy.networking.k8s.io_locust_default-deny.yaml SecurityPolicy.gateway.envoyproxy.io_locust_locust.yaml" ]
  # Every rule of the two and of hello's, exactly: the master takes the workers, the public Gateway's
  # proxies and the kubelet's probe and sends nothing; the workers take nothing and reach the master,
  # the resolver and hello's pods; hello takes the workers beside the proxies, the kubelet and Robot
  # Framework's runner.
  policies=("$(rendered CiliumNetworkPolicy.cilium.io_locust_locust-master.yaml)" "$(rendered CiliumNetworkPolicy.cilium.io_locust_locust-worker.yaml)"
    "$(rendered CiliumNetworkPolicy.cilium.io_demo_hello.yaml)")
  allows "${policies[@]}"
  [ "$(allows "${policies[@]}")" = "$(printf '%s\n' \
    "hello [app.kubernetes.io/name=hello] takes @host on 8080/TCP" \
    "hello [app.kubernetes.io/name=hello] takes app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,app.kubernetes.io/name=envoy,gateway.envoyproxy.io/owning-gateway-name=public,gateway.envoyproxy.io/owning-gateway-namespace=envoy-gateway-system,io.kubernetes.pod.namespace=envoy-gateway-system on 8080/TCP" \
    "hello [app.kubernetes.io/name=hello] takes app.kubernetes.io/component=worker,app.kubernetes.io/name=locust,io.kubernetes.pod.namespace=locust on 8080/TCP" \
    "hello [app.kubernetes.io/name=hello] takes app.kubernetes.io/component=runner,app.kubernetes.io/name=robot,io.kubernetes.pod.namespace=robot on 8080/TCP" \
    "locust-master [app.kubernetes.io/component=master,app.kubernetes.io/name=locust] takes @host on 8089/TCP" \
    "locust-master [app.kubernetes.io/component=master,app.kubernetes.io/name=locust] takes app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,app.kubernetes.io/name=envoy,gateway.envoyproxy.io/owning-gateway-name=public,gateway.envoyproxy.io/owning-gateway-namespace=envoy-gateway-system,io.kubernetes.pod.namespace=envoy-gateway-system on 8089/TCP" \
    "locust-master [app.kubernetes.io/component=master,app.kubernetes.io/name=locust] takes app.kubernetes.io/component=worker,app.kubernetes.io/name=locust,io.kubernetes.pod.namespace=locust on 5557/TCP" \
    "locust-worker [app.kubernetes.io/component=worker,app.kubernetes.io/name=locust] sends to app.kubernetes.io/component=master,app.kubernetes.io/name=locust,io.kubernetes.pod.namespace=locust on 5557/TCP" \
    "locust-worker [app.kubernetes.io/component=worker,app.kubernetes.io/name=locust] sends to app.kubernetes.io/name=hello,io.kubernetes.pod.namespace=demo on 8080/TCP" \
    "locust-worker [app.kubernetes.io/component=worker,app.kubernetes.io/name=locust] sends to io.kubernetes.pod.namespace=kube-system,k8s-app=kube-dns on 53/TCP+53/UDP" |
    LC_ALL=C sort)" ]
  # The proxies' egress to locust is one rule, whole: the master's pods, in locust while it carries
  # the label the Gateway takes routes by, on the web port alone.
  [ "$(yq -o json -I0 '.spec.egress[]' "$(rendered CiliumNetworkPolicy.cilium.io_envoy-gateway-system_public-proxy.yaml)" |
    jq -cS 'select(any(.toEndpoints[]?; .matchLabels["k8s:io.kubernetes.pod.namespace"] == "locust"))')" = "$(jq -cnS '{
      toEndpoints: [{matchLabels: {"k8s:io.kubernetes.pod.namespace": "locust", "k8s:io.cilium.k8s.namespace.labels.k8s-gitops/gateway": "public",
        "app.kubernetes.io/name": "locust", "app.kubernetes.io/component": "master"}}],
      toPorts: [{ports: [{port: "8089", protocol: "TCP"}]}]}')" ]
  # The port the kubelet probes the master on, read from the render.
  probe="$(probed "$(rendered Deployment.apps_locust_locust-master.yaml)")"
  [ "$probe" = 8089 ]
  [ -z "$(probed "$(rendered Deployment.apps_locust_locust-worker.yaml)")" ]
  # The flows, evaluated on the render as Cilium decides them, over every policy of every namespace.
  local flows=(
    # The workers: the master's port, the resolver, hello's port, and nothing else.
    "reaches --reach $WORKER $MASTER 5557/tcp"
    "reaches --reach $WORKER $DNS 53/udp"
    "reaches --reach $WORKER $DNS 53/tcp"
    "reaches --reach $WORKER $HELLO 8080/tcp"
    "refused --reach-egress $WORKER @world 80/tcp"
    "refused --reach-egress $WORKER @world 443/tcp"
    "refused --reach-egress $WORKER @world 53/udp"
    "refused --reach-egress $WORKER @kube-apiserver 443/tcp"
    "refused --reach-egress $WORKER @kube-apiserver 6443/tcp"
    "refused --reach-egress $WORKER @host 10250/tcp"
    "refused --reach-egress $WORKER @remote-node 10250/tcp"
    "refused --reach-egress $WORKER openbao/StatefulSet/openbao 8200/tcp"
    "refused --reach-egress $WORKER $DNS 9153/tcp"
    "refused --reach-egress $WORKER ai-system/Deployment/n8n 5678/tcp"
    "refused --reach-egress $WORKER $HELLO 22/tcp"
    "refused --reach-egress $WORKER $HELLO 80/tcp"
    "refused --reach-egress $WORKER $PROXY 10443/tcp"
    "refused --reach-egress $WORKER $OTHER_APP 8080/tcp"
    "refused --reach-egress $WORKER $OTHER_APP 80/tcp"
    "refused --reach-egress $WORKER $MASTER 8089/tcp"
    "refused --reach-egress $WORKER $STRAY 5557/tcp"
    # The master sends nothing: it runs no users, and the workers connect to it.
    "refused --reach-egress $MASTER $HELLO 8080/tcp"
    "refused --reach-egress $MASTER $WORKER 5557/tcp"
    "refused --reach-egress $MASTER $DNS 53/udp"
    "refused --reach-egress $MASTER $DNS 53/tcp"
    "refused --reach-egress $MASTER @world 443/tcp"
    "refused --reach-egress $MASTER @world 80/tcp"
    "refused --reach-egress $MASTER @kube-apiserver 6443/tcp"
    "refused --reach-egress $MASTER $OTHER_APP 8080/tcp"
    # The master takes the workers on its port, and the public Gateway's proxies and the kubelet's
    # probe on the web port, and no one else: not the proxies on the workers' port, nor the Gateway's
    # controller or a pod of its namespace with one of the proxies' labels on the web port.
    "reaches --reach @host $MASTER $probe/tcp"
    "reaches --reach $PROXY $MASTER 8089/tcp"
    "refused --reach @world $MASTER 8089/tcp"
    "refused --reach @world $MASTER 5557/tcp"
    "refused --reach @remote-node $MASTER 8089/tcp"
    "refused --reach $PROXY $MASTER 5557/tcp"
    "refused --reach-ingress $PROXY $MASTER 5557/tcp"
    "refused --reach envoy-gateway-system/Deployment/envoy-gateway $MASTER 8089/tcp"
    "refused --reach-ingress envoy-gateway-system/Deployment/envoy-gateway $MASTER 8089/tcp"
    "refused --reach-ingress envoy-gateway-system:app.kubernetes.io/name=envoy $MASTER 8089/tcp"
    # The proxies reach no worker and no other pod of locust, whatever its port.
    "refused --reach $PROXY $WORKER 8089/tcp"
    "refused --reach-egress $PROXY $WORKER 8089/tcp"
    "refused --reach-egress $PROXY $WORKER 5557/tcp"
    "refused --reach-egress $PROXY $STRAY 8089/tcp"
    "refused --reach $OTHER_APP $MASTER 8089/tcp"
    "refused --reach $OTHER_APP $MASTER 5557/tcp"
    "refused --reach $HELLO $MASTER 8089/tcp"
    "refused --reach-ingress $IMPOSTOR $MASTER 5557/tcp"
    "refused --reach-ingress $STRAY $MASTER 5557/tcp"
    "refused --reach-ingress $STRAY $MASTER 8089/tcp"
    "refused --reach-ingress @host $MASTER 5557/tcp"
    # The workers take nothing.
    "refused --reach-ingress $MASTER $WORKER 5557/tcp"
    "refused --reach-ingress @host $WORKER 8089/tcp"
    "refused --reach-ingress @world $WORKER 8089/tcp"
    # hello's rule admits the workers alone of locust.
    "refused --reach-ingress $MASTER $HELLO 8080/tcp"
    "refused --reach-ingress $STRAY $HELLO 8080/tcp"
  )
  for flow in "${flows[@]}"; do
    read -r want side from to port <<<"$flow"
    "$want" "$side" "$from" "$to" "$port"
  done
}

@test "Locust's target is a Service of the cluster read from the render, and the target admits only Locust's workers on its port" {
  local domain master hosts url pattern name ns port service selector target pods pod rules numbered pod_ns kind pod_name
  real_render
  # The cluster's DNS domain, as the nodes' machine configuration sets it.
  domain="$(yq -N 'select(.kind == "KubeNetworkConfig") | .dnsDomain' "$REPO/talos/patches/all/cluster-network.yaml")"
  [[ $domain =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$ ]]
  # The host the master hands its workers, as the render substitutes it.
  master="$(rendered Deployment.apps_locust_locust-master.yaml)"
  hosts="$(yq '.spec.template.spec.containers[].args[] | select(test("^--host="))' "$master")"
  [ "$(grep -c . <<<"$hosts")" -eq 1 ]
  url="${hosts#--host=}"
  pattern="^http://([a-z0-9-]+)\\.([a-z0-9-]+)\\.svc\\.${domain//./\\.}:([0-9]+)\$"
  [[ $url =~ $pattern ]] || { echo "Locust's target is no Service of the cluster by its name and port: $url"; return 1; }
  name=${BASH_REMATCH[1]} ns=${BASH_REMATCH[2]} port=${BASH_REMATCH[3]}
  service="$(rendered "Service_${ns}_${name}.yaml")" || { echo "Locust's target, $ns/$name, is no Service of the render"; return 1; }
  selector="$(yq -o json -I0 '.spec.selector // {}' "$service")"
  [ "$(jq length <<<"$selector")" -gt 0 ] || { echo "the Service $ns/$name selects no pods by labels"; return 1; }
  target="$(P="$port" yq '.spec.ports[] | select(.port == env(P)) | .targetPort // .port' "$service")"
  [ -n "$target" ] || { echo "the Service $ns/$name has no port $port"; return 1; }
  # The pods the Service selects, among the workloads of the render in its namespace, and the
  # container port its port targets: a number, or the port of that name in the pods.
  pods="$(yq -o json -I0 '.' "$VIEW"/*/*/*.yaml | NS="$ns" jq -r --argjson selector "$selector" '
    select(.metadata.namespace == env.NS and (.kind | IN("Deployment", "StatefulSet", "DaemonSet")))
    | select(.spec.template.metadata.labels as $labels | $selector | to_entries | all($labels[.key] == .value))
    | .metadata.namespace + "/" + .kind + "/" + .metadata.name')"
  [ -n "$pods" ] || { echo "the Service $ns/$name selects no workload of the render"; return 1; }
  if [[ ! $target =~ ^[0-9]+$ ]]; then
    numbered=""
    for pod in $pods; do
      IFS=/ read -r pod_ns kind pod_name <<<"$pod"
      numbered+="$(T="$target" yq '.spec.template.spec.containers[].ports[] | select(.name == strenv(T)) | .containerPort' \
        "$(rendered "$kind.apps_${pod_ns}_$pod_name.yaml")")"$'\n'
    done
    target="$(grep . <<<"$numbered" | LC_ALL=C sort -u || true)"
  fi
  [[ $target =~ ^[0-9]+$ ]] || { echo "the Service $ns/$name sends port $port to no one numbered port of its pods: $target"; return 1; }
  echo "the target $url is the Service $ns/$name, selecting $pods, on the container port $target"
  # The workers' egress to that namespace is one rule, exactly the Service's pods on that port.
  rules="$(yq -o json -I0 '.spec.egress // [] | .[]' "$(rendered CiliumNetworkPolicy.cilium.io_locust_locust-worker.yaml)" | NS="$ns" jq -c '
    select([(.toEndpoints // [])[] | .matchLabels["k8s:io.kubernetes.pod.namespace"] // .matchLabels["io.kubernetes.pod.namespace"]] | index(env.NS))
    | {"toEndpoints": [.toEndpoints[] | .matchLabels | with_entries(.key |= sub("^k8s:"; ""))], "toPorts": .toPorts, "other": (keys - ["toEndpoints", "toPorts"])}')"
  echo "the workers' egress to $ns: $rules"
  [ "$(grep -c . <<<"$rules")" -eq 1 ]
  [ "$(jq -cS '.toEndpoints' <<<"$rules")" = "$(NS="$ns" jq -cS '[{"io.kubernetes.pod.namespace": env.NS} + .]' <<<"$selector")" ]
  [ "$(jq -c '.toPorts' <<<"$rules")" = "[{\"ports\":[{\"port\":\"$target\",\"protocol\":\"TCP\"}]}]" ]
  [ "$(jq -c '.other' <<<"$rules")" = '[]' ]
  # The target takes the workers there, by its own policy, and not the master, another pod of
  # locust or a pod of another namespace with the workers' labels; nor do the workers reach another
  # port of it.
  for pod in $pods; do
    reaches --reach "$WORKER" "$pod" "$target/tcp"
    reaches --reach-ingress "$WORKER" "$pod" "$target/tcp"
    refused --reach-ingress "$MASTER" "$pod" "$target/tcp"
    refused --reach-ingress "$STRAY" "$pod" "$target/tcp"
    refused --reach-ingress "$IMPOSTOR" "$pod" "$target/tcp"
    refused --reach "$WORKER" "$pod" 22/tcp
  done
}

@test "Locust's master serves its interface from the tree's locustfile and starts no test by itself" {
  local target master worker service cm data name mount found workload
  built
  # The target, as the root builds the application's Kustomization: the one variable of its own.
  target="$(yq '.spec.postBuild.substitute.LOCUST_TARGET' "$KS")"
  [ -n "$target" ]
  [ "$target" != null ]
  # One master, replaced rather than rolled: two masters would split the workers between them.
  deployment locust-master
  master="$(yq -o json -I0 '.' "$DEPLOYMENT")"
  [ "$(jq -r '.spec.replicas' <<<"$master")" = 1 ]
  [ "$(jq -c '.spec.strategy' <<<"$master")" = '{"type":"Recreate"}' ]
  [ "$(jq -cS '.spec.selector.matchLabels' <<<"$master")" = '{"app.kubernetes.io/component":"master","app.kubernetes.io/name":"locust"}' ]
  [ "$(jq -cS '.spec.template.metadata.labels' <<<"$master")" = '{"app.kubernetes.io/component":"master","app.kubernetes.io/name":"locust"}' ]
  [ "$(yq -o json -I0 '.args' "$CONTAINER")" = "$(jq -cn --arg host "--host=$target" \
    '["--master", "--locustfile=/mnt/locust/locustfile.py", $host, "--web-port=8089", "--master-bind-port=5557"]')" ]
  # The variable is the one place the target is written: the manifest's host is the variable itself.
  # shellcheck disable=SC2016 # ${LOCUST_TARGET} is Flux's to substitute.
  [ "$(yq '.spec.template.spec.containers[0].args[] | select(test("^--host="))' "$APP/app/deployment-master.yaml")" = '--host=${LOCUST_TARGET}' ]
  [ "$(yq -o json -I0 '.ports' "$CONTAINER" | jq -cS .)" = '[{"containerPort":8089,"name":"web"},{"containerPort":5557,"name":"master"}]' ]
  # Its readiness probe asks for the page, which needs no sign-in, on the web port.
  [ "$(yq -o json -I0 '.readinessProbe' "$CONTAINER" | jq -cS .)" = '{"httpGet":{"path":"/","port":"web"}}' ]
  [ "$(yq '[.livenessProbe, .startupProbe] | map(select(. != null)) | length' "$CONTAINER")" -eq 0 ]
  # Two workers, which listen on nothing, so have no port and no probe.
  deployment locust-worker
  worker="$(yq -o json -I0 '.' "$DEPLOYMENT")"
  [ "$(jq -r '.spec.replicas' <<<"$worker")" = 2 ]
  [ "$(jq -cS '.spec.selector.matchLabels' <<<"$worker")" = '{"app.kubernetes.io/component":"worker","app.kubernetes.io/name":"locust"}' ]
  [ "$(jq -cS '.spec.template.metadata.labels' <<<"$worker")" = '{"app.kubernetes.io/component":"worker","app.kubernetes.io/name":"locust"}' ]
  [ "$(yq -o json -I0 '.args' "$CONTAINER")" = '["--worker","--locustfile=/mnt/locust/locustfile.py","--master-host=locust-master","--master-port=5557"]' ]
  [ "$(yq '[.ports, .readinessProbe, .livenessProbe, .startupProbe] | map(select(. != null)) | length' "$CONTAINER")" -eq 0 ]
  # The Service the workers name selects the master's pods and serves the web port and the master's
  # port, each to the master's container port of that name and number.
  service="$(object "$BUILT" Service locust-master | yq -o json -I0 '.')"
  [ "$(yq -N 'select(.kind == "Service") | .metadata.name' "$BUILT")" = locust-master ]
  [ "$(jq -cS '.spec.selector' <<<"$service")" = "$(jq -cS '.spec.selector.matchLabels' <<<"$master")" ]
  [ "$(jq -cS '.spec.ports' <<<"$service")" = '[{"name":"web","port":8089,"targetPort":"web"},{"name":"master","port":5557,"targetPort":"master"}]' ]
  [ "$(jq -c --argjson service "$service" '[.spec.template.spec.containers[0].ports[] | . as $c
      | $service.spec.ports[] | select(.targetPort == $c.name and .port == $c.containerPort) | .name] | sort' <<<"$master")" = '["master","web"]' ]
  # The locustfile: one ConfigMap, by a hashed name so that a change restarts every pod, generated
  # from the file and holding it byte for byte, with Flux's substitution off.
  cm="$(yq -N -o json -I0 'select(.kind == "ConfigMap")' "$BUILT")"
  [ "$(grep -c . <<<"$cm")" -eq 1 ]
  name="$(jq -r '.metadata.name' <<<"$cm")"
  [[ $name =~ ^locust-locustfile-[a-z0-9]{10}$ ]]
  [ "$(jq -r '.metadata.annotations["kustomize.toolkit.fluxcd.io/substitute"]' <<<"$cm")" = disabled ]
  [ "$(jq -c '.data | keys' <<<"$cm")" = '["locustfile.py"]' ]
  data="$BATS_TEST_TMPDIR/locustfile.py"
  jq -j '.data["locustfile.py"]' <<<"$cm" >"$data"
  cmp "$data" "$APP/app/locustfile.py"
  [ "$(yq -o json -I0 '.configMapGenerator' "$APP/app/kustomization.yaml" | jq -c '[.[] | select(.name == "locust-locustfile") | del(.options)]')" \
    = '[{"name":"locust-locustfile","files":["locustfile.py"]}]' ]
  # Both pods mount it, read-only and whole, where their --locustfile argument reads it.
  for workload in locust-master locust-worker; do
    deployment "$workload"
    found="$(yq '.args[] | select(test("^--locustfile="))' "$CONTAINER")"
    # shellcheck disable=SC2016 # $pod and $n are yq variables.
    mount="$(NAME="$name" yq '.spec.template.spec as $pod | $pod.containers[0].volumeMounts[]
      | select(.name as $n | $pod.volumes[] | select(.name == $n and .configMap.name == strenv(NAME) and (.configMap.items == null)))
      | select(.readOnly == true and .subPath == null) | .mountPath' "$DEPLOYMENT")"
    echo "$workload reads $found from $mount"
    [ "$found" = "--locustfile=$mount/locustfile.py" ]
  done
  # One HttpUser, waiting one to three seconds between tasks, with one task that asks for /, and a
  # comment that says what it does; nothing of it reaches the runner, which could start a test.
  [ "$(grep -cE '^class [A-Za-z]+\(HttpUser\):$' "$APP/app/locustfile.py")" -eq 1 ]
  [ "$(grep -cE '^    wait_time = between\(1, 3\)$' "$APP/app/locustfile.py")" -eq 1 ]
  [ "$(grep -cE '^    @task$' "$APP/app/locustfile.py")" -eq 1 ]
  [ "$(grep -cF 'self.client.get("/")' "$APP/app/locustfile.py")" -eq 1 ]
  # Every request is a path of the host the master hands out, and nothing but Locust is imported: an
  # absolute URL, or a client of another library, would go past the target as a typed host does.
  [ -z "$(grep -oE 'self\.client\.[A-Za-z_]+\([^,)]*' "$APP/app/locustfile.py" | grep -vE '^self\.client\.[A-Za-z_]+\("/' || true)" ]
  # Nor does the locustfile give a host of its own: the target is written in the variable alone.
  [ -z "$(grep -nE '\bhost\b[[:space:]]*(:[^=]*)?=([^=]|$)' "$APP/app/locustfile.py" | grep -v ':#' || true)" ]
  [ "$(grep -E '^[[:space:]]*(import|from)[[:space:]]' "$APP/app/locustfile.py")" = 'from locust import HttpUser, between, task' ]
  grep -qE '^#' "$APP/app/locustfile.py"
  [ -z "$(grep -nE '\b(events|runner|environment|on_start|on_test_start)\b' "$APP/app/locustfile.py" | grep -v ':#' || true)" ]
  # No test starts by itself: no container runs a command of its own, an option that starts or
  # shapes a test, reads a configuration file, turns on OpenTelemetry or the login hook, in any
  # spelling Locust takes; and no container is handed a variable Locust reads its options from, or
  # anything at the working directory, where Locust looks for its configuration files.
  [ "$(containers "$BUILT" | grep -c .)" -eq 2 ]
  [ -z "$(containers "$BUILT" | jq -r 'select(.command != null) | .name')" ]
  forbidden "$BUILT"
  [ -z "$(forbidden "$BUILT")" ]
  [ -z "$(containers "$BUILT" | jq -r '((.env // [])[] | .name | select(test("^LOCUST_"))), (select(.envFrom != null) | "\(.name): envFrom")')" ]
  [ -z "$(containers "$BUILT" | jq -r '(.volumeMounts // [])[] | select(.mountPath | test("^/home(/|$)")) | .mountPath')" ]
  [ "$(yq -N 'select(.spec.template != null) | .spec.template.spec.enableServiceLinks' "$BUILT" | LC_ALL=C sort -u)" = false ]
}

ROUTE_DIR=kubernetes/apps/base/locust/locust-route
ROUTE_FILE=$ROUTE_DIR/app/httproute.yaml

# build_app NAME [VARS]: the application NAME as Flux applies it on lab-sto2, built as built() builds
# Locust, from the root's Kustomization of it, with the key lists of the file VARS, the example's by
# default, under its own substitutions. Writes the build to $BATS_TEST_TMPDIR/NAME-app.yaml and sets
# APP_BUILT to it and APP_KS to the Kustomization.
build_app() {
  local root="$CLUSTER/ks.yaml" path
  path="$(yq '.spec.path' "$root")"
  (cd "$REPO" && flux build kustomization "$(yq '.metadata.name' "$root")" \
    --path "./kubernetes/${path#./}" --kustomization-file "$root" --dry-run --in-memory-build) >"$BATS_TEST_TMPDIR/root.yaml"
  APP_KS="$BATS_TEST_TMPDIR/$1-app-ks.yaml"
  VARS="${2:-$VARS}" with_vars "$1" "$BATS_TEST_TMPDIR/root.yaml" >"$APP_KS"
  [ -s "$APP_KS" ] || { echo "the lab-sto2 overlay does not enable $1"; return 1; }
  APP_BUILT="$BATS_TEST_TMPDIR/$1-app.yaml"
  flux_build "$1" "$APP_KS" >"$APP_BUILT"
}

# other_vars: a copy of the example key lists with another domain, in $OTHER, so a test can build
# again and see that what it read came from the variable, not from a literal that happens to equal
# the example.
other_vars() {
  OTHER="$BATS_TEST_TMPDIR/other-vars.yaml"
  CLUSTER_DOMAIN=other.example.org yq '.CLUSTER_DOMAIN = strenv(CLUSTER_DOMAIN)' "$VARS" >"$OTHER"
}

# route_admits METHOD TARGET [NAME=VALUE...]: succeeds when the route in $BATS_TEST_TMPDIR/route.yaml
# sends the request, with the headers NAME=VALUE, to a backend, as Gateway API matches an HTTPRoute
# (gateway-api apis/v1/httproute_types.go), as tests/backstage.bats's route_admits does, and with
# header matches: a rule without matches matches every request, and a match without a path is a
# prefix of "/"; a method matches exactly; an Exact path is the request's path, without its query,
# byte for byte; a PathPrefix matches the path whole or up to a "/", a trailing "/" of the prefix
# aside; a header match of type Exact, the default, holds when the request has the header, its name
# compared without regard to case, with exactly the value. Of the matches the request meets, an Exact
# path wins, then the longest prefix, then one with a method, then the most header matches, then the
# earlier rule; the request is sent on when that match's rule has a backend. Exits 0 when it is sent
# on and 1 when not; a match of any other type or field exits otherwise, as one this test cannot
# evaluate.
route_admits() {
  local headers='{}' header
  for header in "${@:3}"; do
    headers="$(jq -c --arg name "${header%%=*}" --arg value "${header#*=}" '. + {($name | ascii_downcase): $value}' <<<"$headers")"
  done
  yq -o json '.' "$BATS_TEST_TMPDIR/route.yaml" | jq -e --arg method "$1" --arg target "$2" --argjson headers "$headers" '
    ($target | split("?")[0]) as $path
    | def path_of: .path // {"type": "PathPrefix", "value": "/"};
      def path_matches:
        path_of as $p
        | if $p.type == "Exact" then $path == $p.value
          elif $p.type == "PathPrefix" then ($p.value | sub("/+$"; "")) as $v | $v == "" or $path == $v or ($path | startswith($v + "/"))
          else error("a path match of type \($p.type), which this test does not evaluate") end;
      def headers_match:
        all((.headers // [])[]; (.type // "Exact") as $t
          | if $t != "Exact" then error("a header match of type \($t), which this test does not evaluate")
            else $headers[.name | ascii_downcase] == .value end);
      def request_matches:
        if (keys - ["method", "path", "headers"] | length) > 0 then error("a match by \(keys - ["method", "path", "headers"] | join(", ")), which this test does not evaluate")
        else ((.method // $method) == $method) and path_matches and headers_match end;
    [ .spec.rules | to_entries[] | .key as $rule | ((.value.backendRefs // []) | length > 0) as $backend
      | (.value.matches // [{}])[] | select(request_matches)
      | {exact: (if path_of.type == "Exact" then 1 else 0 end), length: (path_of.value | length),
         method: (if .method then 1 else 0 end), headers: ((.headers // []) | length), rule: (0 - $rule), $backend} ]
    | if length == 0 then false else (sort_by(.exact, .length, .method, .headers, .rule) | last | .backend) end' >/dev/null
}

# interface_reach FILE...: one line for each way, in the objects of the files, that Locust's master
# is reached from the public Gateway other than through the route locust behind the cluster's
# sign-in, naming what does it: a route other than locust of locust whose rules send to the Service
# locust-master of locust, as a backend, a backend's mirror or a rule's mirror, whatever namespace
# the reference names or leaves out, or that route sending to it on another port than 8089; a route
# of locust on the public Gateway that no SecurityPolicy of locust asking oauth2-proxy of sso-system,
# without failing open, targets by name and that is not such a route's sign-in route <name>-oauth2
# sending to oauth2-proxy of sso-system alone; an object other than that policy that targets the
# route locust, by reference, or a route of locust, by selector; a route other than locust and
# locust-oauth2 of locust that lists the host of the route locust; and a ReferenceGrant of locust
# that lets another namespace refer to its Services, as a route there could then reach the master's
# pods through any Service of locust that selects them. Prints nothing when none does.
interface_reach() {
  # shellcheck disable=SC2016 # $all, $own, $r, $p, $to, $protected and $hosts are jq variables.
  yq -N -o json -I0 'select(. != null)' "$@" | jq -rs '
    [.[] | objects] as $all
    | def on_public: .metadata.namespace as $own | any(.spec.parentRefs[]?; .name == "public"
        and (.kind // "Gateway") == "Gateway" and (.namespace // $own) == "envoy-gateway-system");
      def refs: .metadata.namespace as $own
        | (.spec.rules[]? | (.backendRefs[]? | ., (.filters[]?.requestMirror.backendRef // empty)),
            (.filters[]?.requestMirror.backendRef // empty))
        | select((.kind // "Service") == "Service" and (.group // "") == "") | {name, namespace: (.namespace // $own), port};
      def asks_sign_in: .kind == "SecurityPolicy" and .spec.extAuth != null
        and (.spec.extAuth.failOpen // false) == false
        and ([.spec.extAuth.http.backendRefs[]? | [(.kind // "Service"), .name, .namespace]] == [["Service", "oauth2-proxy", "sso-system"]]);
      def the_route: .kind == "HTTPRoute" and .metadata.namespace == "locust" and .metadata.name == "locust";
    [$all[] | select(.metadata.namespace == "locust" and asks_sign_in) | .spec.targetRefs[]?
      | select((.group // "") == "gateway.networking.k8s.io" and .kind == "HTTPRoute") | .name] as $protected
    | ([$all[] | select(the_route) | .spec.hostnames[]?]) as $hosts
    | ($all[] | select(.kind | tostring | endswith("Route")) | . as $r
        | [refs | select(.name == "locust-master" and .namespace == "locust")] as $to
        | select($to | length > 0)
        | if ($r | the_route) then ($to[] | select(.port != 8089) | "HTTPRoute/locust/locust sends to the Service locust-master of locust on \(.port)")
          else "\($r.kind)/\($r.metadata.namespace)/\($r.metadata.name) sends to the Service locust-master of locust" end),
      ($all[] | select(.kind | tostring | endswith("Route")) | select(.metadata.namespace == "locust" and on_public) | . as $r
        | select(($protected | index($r.metadata.name)) == null)
        | select(($r.metadata.name | endswith("-oauth2")) and ($protected | index($r.metadata.name | sub("-oauth2$"; ""))) != null
            and ([$r | refs | [.name, .namespace]] | unique == [["oauth2-proxy", "sso-system"]]) | not)
        | "\($r.kind)/locust/\($r.metadata.name) is on the public Gateway and no policy that asks oauth2-proxy targets it"),
      ($all[] | . as $p | ($p.metadata.namespace // "") as $own | select(($p.spec | type) == "object")
        | select(any(([$p.spec.targetRef // empty] + ($p.spec.targetRefs // []))[];
              (.kind // "") == "HTTPRoute" and .name == "locust" and $own == "locust")
            or ($own == "locust" and any($p.spec.targetSelectors[]?; (.kind // "") == "HTTPRoute")))
        | select(($p.kind == "SecurityPolicy" and $p.metadata.name == "locust" and ($p | asks_sign_in)) | not)
        | "\($p.kind)/\($own)/\($p.metadata.name) targets the route locust"),
      ($all[] | select(.kind | tostring | endswith("Route")) | . as $r
        | select(any(.spec.hostnames[]?; . as $h | $hosts | index($h) != null))
        | select(($r.metadata.namespace == "locust" and ($r.metadata.name == "locust" or $r.metadata.name == "locust-oauth2")) | not)
        | "\($r.kind)/\($r.metadata.namespace)/\($r.metadata.name) lists the host of the route locust"),
      ($all[] | select(.kind == "ReferenceGrant" and .metadata.namespace == "locust")
        | select(any(.spec.to[]?; (.group // "") == "" and .kind == "Service"))
        | "ReferenceGrant/locust/\(.metadata.name) lets another namespace refer to the Services of locust")'
}

# paths_record FILE VERSION: fails, saying what to read again and what to set, unless the header of
# the route in FILE records, once, that its matches were read from the Locust release VERSION,
# beside one Source line that names locust/web.py at that release's tag.
paths_record() {
  local file=$1 version=$2 record source
  record="$(grep -E '^#[[:blank:]]*locust-paths:' "$file" || true)"
  source="$(grep -E '^#[[:blank:]]*Source:[[:blank:]]*https://' "$file" | sed -E 's/^#[[:blank:]]*Source:[[:blank:]]*//' || true)"
  echo "record: ${record:-none}; source: ${source:-none}; the master runs Locust $version"
  [ "$(grep -c . <<<"$record")" -eq 1 ] && [ "$(grep -c . <<<"$source")" -eq 1 ] ||
    { echo "$file needs one '# locust-paths: <release>' line and one '# Source:' line"; return 1; }
  record="$(sed -E 's/^#[[:blank:]]*locust-paths:[[:blank:]]*//; s/[[:blank:]]*$//' <<<"$record")"
  if [ "$record" != "$version" ] || [ "$source" != "https://github.com/locustio/locust/blob/$version/locust/web.py" ]; then
    echo "the route's matches were read from Locust $record, and the master runs $version:" \
      "read locust/web.py, locust/argument_parser.py and locust/env.py and the interface's page and bundle in" \
      "locust/webui/dist/ at $version again, change the route's matches and the requests tests/locust.bats sends" \
      "through them to what the interface asks, and set the record to $version and the Source line to" \
      "https://github.com/locustio/locust/blob/$version/locust/web.py"
    return 1
  fi
}

@test "Locust's interface answers at locust under the cluster's domain on the public Gateway, behind the cluster's sign-in" {
  local ks domain objects route policy signin grant
  domain="$(yq -e '.CLUSTER_DOMAIN' "$VARS")"
  ks="$REPO/$ROUTE_DIR/ks.yaml"
  # The application beside Locust, in its namespace, as the overlay applies it: shaped as the log
  # store's route, with the component, the route's and the host's names, waiting, after the Gateway,
  # Locust, the sign-in and the exporter that answers its Probe. No patch of the overlay changes it.
  overlay
  [ "$(yq -o json -I0 '.spec | sort_keys(..)' "$ks")" \
    = "$(yq -N -o json -I0 'select(.kind == "Kustomization" and .metadata.name == "locust-route") | .spec | sort_keys(..)' "$OVERLAY")" ]
  echo "the Kustomization: $(yq -o json -I0 '.spec' "$ks")"
  [ "$(yq '.metadata.name + " " + .metadata.namespace' "$ks")" = "locust-route flux-system" ]
  [ "$(yq '.spec.path' "$ks")" = "./apps/base/locust/locust-route/app" ]
  [ "$(yq '.spec.targetNamespace' "$ks")" = "$NAMESPACE" ]
  [ "$(yq -o json -I0 '.spec.components' "$ks")" = '["../../../../../components/sso"]' ]
  [ "$(yq -o json -I0 '.spec.postBuild.substitute | sort_keys(.)' "$ks")" = '{"SSO_HOSTNAME":"locust","SSO_ROUTE":"locust"}' ]
  [ "$(yq '.spec.dependsOn | map(.name) | sort | join(" ")' "$ks")" = "blackbox-exporter gateway-public locust oauth2-proxy" ]
  [ "$(yq '.spec.wait' "$ks")" = true ]
  [ "$(yq -o json -I0 '.spec.sourceRef' "$ks")" = '{"kind":"ExternalArtifact","name":"locust-route"}' ]
  # Locust waits, so the route is applied once the master answers its readiness probe.
  [ "$(object "$OVERLAY" Kustomization locust | yq '.spec.wait')" = true ]
  # The namespace's routes may attach to the public Gateway's https listener.
  [ "$(object "$OVERLAY" Namespace "$NAMESPACE" | yq '.metadata.labels["k8s-gitops/gateway"]')" = public ]
  # app/ holds the one HTTPRoute and its Probe; the component adds the policy and the sign-in route,
  # all in locust.
  [ "$(cd "$REPO/$ROUTE_DIR" && find . -type f | LC_ALL=C sort | paste -sd' ' -)" = "./app/httproute.yaml ./app/kustomization.yaml ./app/probe.yaml ./ks.yaml" ]
  # shellcheck disable=SC2016 # The files hold a ${NAME} reference, not for the shell to expand.
  [ "$(yq -N 'select(.kind != "Kustomization") | .kind + "/" + .metadata.name' "$REPO/$ROUTE_DIR"/app/*.yaml | paste -sd' ' -)" \
    = 'HTTPRoute/${SSO_ROUTE} Probe/${SSO_ROUTE}' ]
  [ "$(yq -o json -I0 '.resources' "$REPO/$ROUTE_DIR/app/kustomization.yaml")" = '["httproute.yaml","probe.yaml"]' ]
  build_app locust-route
  objects="$(yq -N 'select(.kind != null) | .kind + "/" + .metadata.namespace + "/" + .metadata.name' "$APP_BUILT" | LC_ALL=C sort | paste -sd' ' -)"
  echo "built: $objects"
  [ "$objects" = "HTTPRoute/locust/locust HTTPRoute/locust/locust-oauth2 Probe/locust/locust SecurityPolicy/locust/locust" ]
  # The route: on the public Gateway's https listener, for locust under the cluster's domain, with
  # one backend, the master's Service on its web port.
  route="$(yq -N -o json -I0 'select(.kind == "HTTPRoute" and .metadata.name == "locust")' "$APP_BUILT")"
  [ "$(jq -cS '.spec.parentRefs' <<<"$route")" = '[{"name":"public","namespace":"envoy-gateway-system","sectionName":"https"}]' ]
  [ "$(jq -cS '.spec.hostnames' <<<"$route")" = "[\"locust.$domain\"]" ]
  [ "$(jq -cS '[.spec.rules[] | (.backendRefs // [])[]]' <<<"$route")" = '[{"name":"locust-master","port":8089}]' ]
  # Its one policy targets it alone, asks oauth2-proxy's Service at the root with the route's host
  # to return to, sends it the cookie and nothing else of the request's headers, and does not fail
  # open: the whole spec, so that no field added to it goes unseen.
  policy="$(yq -N -o json -I0 'select(.kind == "SecurityPolicy")' "$APP_BUILT")"
  echo "the policy: $(jq -cS '.spec' <<<"$policy")"
  [ "$(jq -cS '.spec' <<<"$policy")" = "$(jq -cnS --arg domain "$domain" '{
    targetRefs: [{group: "gateway.networking.k8s.io", kind: "HTTPRoute", name: "locust"}],
    extAuth: {headersToExtAuth: ["cookie"],
      http: {backendRefs: [{name: "oauth2-proxy", namespace: "sso-system", port: 80}],
        pathOverride: "/?rd=https://locust.\($domain)/", headersToBackend: ["x-auth-request-user", "x-auth-request-email"]}}}')" ]
  # The sign-in route: /oauth2/ on the same host, to oauth2-proxy.
  signin="$(yq -N -o json -I0 'select(.kind == "HTTPRoute" and .metadata.name == "locust-oauth2")' "$APP_BUILT")"
  [ "$(jq -cS '.spec.parentRefs' <<<"$signin")" = '[{"name":"public","namespace":"envoy-gateway-system","sectionName":"https"}]' ]
  [ "$(jq -cS '.spec.hostnames' <<<"$signin")" = "[\"locust.$domain\"]" ]
  [ "$(jq -cS '.spec.rules' <<<"$signin")" = "$(jq -cnS '[{matches: [{path: {type: "PathPrefix", value: "/oauth2/"}}],
    backendRefs: [{name: "oauth2-proxy", namespace: "sso-system", port: 80}]}]')" ]
  # oauth2-proxy's grant, as its application applies it in sso-system, lets locust's policy and
  # sign-in route refer to the Service, and the Service alone.
  build_app oauth2-proxy
  grant="$(yq -N -o json -I0 'select(.kind == "ReferenceGrant" and .metadata.name == "oauth2-proxy")' "$APP_BUILT")"
  [ "$(jq -r '.metadata.namespace' <<<"$grant")" = sso-system ]
  [ "$(jq -cS '.spec.to' <<<"$grant")" = '[{"group":"","kind":"Service","name":"oauth2-proxy"}]' ]
  [ "$(jq -r '[.spec.from[] | select(.namespace == "locust") | .group + "/" + .kind] | sort | join(",")' <<<"$grant")" \
    = "gateway.envoyproxy.io/SecurityPolicy,gateway.networking.k8s.io/HTTPRoute" ]
  # The host, the return address and the hostname the Probe sends on follow the domain.
  other_vars
  build_app locust-route "$OTHER"
  [ "$(yq -N 'select(.kind == "HTTPRoute") | .metadata.name + " " + (.spec.hostnames | join(","))' "$APP_BUILT" | LC_ALL=C sort | paste -sd, -)" \
    = "locust locust.other.example.org,locust-oauth2 locust.other.example.org" ]
  [ "$(yq -N 'select(.kind == "SecurityPolicy") | .spec.extAuth.http.pathOverride' "$APP_BUILT")" = "/?rd=https://locust.other.example.org/" ]
  [ "$(yq -N 'select(.kind == "Probe") | .spec.targets.staticConfig.labels.hostname' "$APP_BUILT")" = locust.other.example.org ]
}

@test "Only the interface's reads and its own page's posts are routed to Locust's master" {
  local domain origin service request method target header
  domain="$(yq -e '.CLUSTER_DOMAIN' "$VARS")"
  origin="https://locust.$domain"
  build_app locust-route
  yq -N 'select(.kind == "HTTPRoute" and .metadata.name == "locust")' "$APP_BUILT" >"$BATS_TEST_TMPDIR/route.yaml"
  [ "$(yq '.metadata.namespace' "$BATS_TEST_TMPDIR/route.yaml")" = "$NAMESPACE" ]
  echo "rules: $(yq -o json -I0 '.spec.rules' "$BATS_TEST_TMPDIR/route.yaml")"
  # One rule in full, its matches in order, with no filter and one backend: GET and HEAD of any path,
  # which serve the interface's page, its files, its polled reads, the report and the CSVs; and POST
  # of the three paths the interface posts to, each only with the Origin of the route's own host,
  # which a browser sends with every POST and a page of another origin cannot set.
  [ "$(yq -o json -I0 '.spec.rules' "$BATS_TEST_TMPDIR/route.yaml" | jq -cS .)" = "$(jq -cnS --arg origin "$origin" '[{
    matches: [
      {method: "GET", path: {type: "PathPrefix", value: "/"}},
      {method: "HEAD", path: {type: "PathPrefix", value: "/"}},
      {method: "POST", path: {type: "Exact", value: "/swarm"}, headers: [{type: "Exact", name: "Origin", value: $origin}]},
      {method: "POST", path: {type: "Exact", value: "/stop"}, headers: [{type: "Exact", name: "Origin", value: $origin}]},
      {method: "POST", path: {type: "Exact", value: "/stats/reset"}, headers: [{type: "Exact", name: "Origin", value: $origin}]}],
    backendRefs: [{name: "locust-master", port: 8089}]}]')" ]
  # The backend's port is the Service's web port, which targets the master's web port, 8089, and not
  # the port the workers connect to.
  build_app locust
  service="$(object "$APP_BUILT" Service locust-master | yq -o json -I0 '.spec.ports[] | select(.port == 8089)')"
  [ "$(jq -c '[.name, .targetPort]' <<<"$service")" = '["web","web"]' ]
  [ "$(object "$APP_BUILT" Deployment locust-master | yq '.spec.template.spec.containers[0].ports[] | select(.name == "web") | .containerPort')" = 8089 ]
  # What reaches the master, by Gateway API's matching of the rule: the page and the files it loads
  # (locust/webui/dist/index.html of 2.47.0), the reads its bundle polls (its RTK Query endpoints,
  # relative to the page), the report and the CSVs it links, as GET and HEAD, and its three posts
  # with the route's own Origin.
  local admitted=(
    "GET /"
    "HEAD /"
    "GET /assets/src-Cl6CiemE.js"
    "GET /assets/favicon-light.png"
    "GET /assets/favicon-dark.png"
    "HEAD /assets/src-Cl6CiemE.js"
    "GET /stats/requests"
    "GET /tasks"
    "GET /exceptions"
    "GET /logs"
    "GET /worker-count"
    "GET /stats/report?theme=dark"
    "GET /stats/requests/csv"
    "GET /stats/requests_full_history/csv"
    "GET /stats/failures/csv"
    "GET /exceptions/csv"
    "POST /swarm Origin=$origin"
    "POST /stop Origin=$origin"
    "POST /stats/reset Origin=$origin"
    "POST /swarm origin=$origin"
  )
  # What does not: the posts without the Origin, with a null one, from the route's host over http,
  # from another host under the domain, which the session cookie's SameSite=Lax would reach, or in
  # another spelling; the user-class post and the posts' paths changed by a trailing slash or a
  # letter's case; and every other method.
  local refused=(
    "POST /swarm"
    "POST /stop"
    "POST /stats/reset"
    "POST /swarm Origin=null"
    "POST /stop Origin=null"
    "POST /swarm Origin=http://locust.$domain"
    "POST /swarm Origin=https://hello-sso.$domain"
    "POST /stop Origin=https://logs.$domain"
    "POST /stats/reset Origin=https://other.$domain"
    "POST /swarm Origin=https://locust.$domain:443"
    "POST /swarm Origin=https://LOCUST.$domain"
    "POST /swarm Origin=$origin/"
    "POST /swarm Referer=$origin/"
    "POST /user Origin=$origin"
    "POST /swarm/ Origin=$origin"
    "POST /Swarm Origin=$origin"
    "POST /stop/ Origin=$origin"
    "POST /stats/reset/ Origin=$origin"
    "POST / Origin=$origin"
    "POST /stats/requests Origin=$origin"
    "PUT /swarm Origin=$origin"
    "PUT / Origin=$origin"
    "DELETE /swarm Origin=$origin"
    "DELETE / Origin=$origin"
    "PATCH /swarm Origin=$origin"
    "PATCH /user Origin=$origin"
    "OPTIONS /swarm Origin=$origin"
    "OPTIONS / Origin=$origin"
    "TRACE / Origin=$origin"
  )
  for request in "${admitted[@]}"; do
    read -r method target header <<<"$request"
    run route_admits "$method" "$target" ${header:+"$header"}
    [ "$status" -eq 0 ] || { echo "the route does not send $request to the master: $output"; return 1; }
  done
  for request in "${refused[@]}"; do
    read -r method target header <<<"$request"
    run route_admits "$method" "$target" ${header:+"$header"}
    [ "$status" -eq 1 ] || { echo "the route sends $request to the master: $output"; return 1; }
  done
}

@test "The paths routed to Locust were read from the Locust release the master runs" {
  local image version pin
  built
  deployment locust-master
  image="$(yq '.image' "$CONTAINER")"
  [[ $image =~ ^docker\.io/locustio/locust:([0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$ ]]
  version="${BASH_REMATCH[1]}"
  echo "the master runs $image"
  paths_record "$REPO/$ROUTE_FILE" "$version"
  # Renovate moves none of it: the pin check holds the record as moved by hand.
  pin="$(awk -F'\t' -v file="$ROUTE_FILE" '$1 == file && $2 == "locust-paths"' "$REPO/.renovate/by-hand.tsv")"
  [ -n "$pin" ] || { echo "no row of .renovate/by-hand.tsv for locust-paths in $ROUTE_FILE"; return 1; }
  # A record of another release than the master's fails, saying what to read and what to set.
  sed -E 's/^(#[[:blank:]]*locust-paths:[[:blank:]]*).*/\12.0.0/' "$REPO/$ROUTE_FILE" >"$BATS_TEST_TMPDIR/moved.yaml"
  run paths_record "$BATS_TEST_TMPDIR/moved.yaml" "$version"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"read locust/web.py, locust/argument_parser.py and locust/env.py and the interface's page and bundle in locust/webui/dist/ at $version again"* ]]
  [[ $output == *"set the record to $version and the Source line to https://github.com/locustio/locust/blob/$version/locust/web.py"* ]]
  # So does a Source line of another release beside the right record.
  sed -E 's#^(\#[[:blank:]]*Source:.*/blob/)[^/]+(/.*)$#\12.0.0\2#' "$REPO/$ROUTE_FILE" >"$BATS_TEST_TMPDIR/source.yaml"
  run paths_record "$BATS_TEST_TMPDIR/source.yaml" "$version"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"set the record to $version and the Source line to"* ]]
}

@test "Locust's route is probed for the sign-in redirect at the interface's page" {
  local domain probe hello target path
  domain="$(yq -e '.CLUSTER_DOMAIN' "$VARS")"
  build_app locust-route
  probe="$(yq -N -o json -I0 'select(.kind == "Probe")' "$APP_BUILT")"
  echo "the Probe: $probe"
  [ "$(jq -r '.metadata.namespace + "/" + .metadata.name' <<<"$probe")" = locust/locust ]
  # hello-sso's Probe, but for the hostname it sends on: the job the alerts read, the module that
  # expects the redirect to sign-in, the exporter as its prober and the proxies' Service at / as its
  # one target.
  build_app hello-sso
  hello="$(yq -N -o json -I0 'select(.kind == "Probe")' "$APP_BUILT")"
  [ "$(jq -cS '.spec | .targets.staticConfig.labels.hostname = "-"' <<<"$probe")" = "$(jq -cS '.spec | .targets.staticConfig.labels.hostname = "-"' <<<"$hello")" ]
  [ "$(jq -r '.spec.targets.staticConfig.labels.hostname' <<<"$probe")" = "locust.$domain" ]
  [ "$(jq -r '.spec.jobName + " " + .spec.module + " " + .spec.prober.url' <<<"$probe")" \
    = "public-endpoints public_https_signin blackbox-exporter.monitoring.svc.cluster.local:9115" ]
  target="$(jq -r '.spec.targets.staticConfig.static | if length == 1 then .[0] else error("not one target") end' <<<"$probe")"
  [[ $target =~ ^https://envoy-envoy-gateway-system-public-[0-9a-f]{8}\.envoy-gateway-system\.svc\.cluster\.local(/.*)$ ]]
  path="${BASH_REMATCH[1]}"
  [ "$path" = / ]
  # That path is the interface's page, which the master's readiness probe asks on its web port, and
  # which no sign-in of Locust's guards: the master runs no --web-login (forbidden, above). So the
  # day the policy is lost the probe meets Locust's 200, and only the redirect passes it.
  built
  deployment locust-master
  [ "$(yq -o json -I0 '.readinessProbe.httpGet' "$CONTAINER" | jq -cS .)" = "{\"path\":\"$path\",\"port\":\"web\"}" ]
  [ -z "$(forbidden "$BUILT")" ]
}

@test "Locust's route is selected by an overlay entry, builds nothing when it is not, and is refused without Locust, the Gateway, the sign-in or the exporter" {
  local with without dependency
  # One entry of the overlay, which builds the Kustomization.
  [ "$(yq '.resources[] | select(test("/locust-route/"))' "$OVERLAY_DIR/kustomization.yaml")" = ../../base/locust/locust-route/ks.yaml ]
  overlay
  [ "$(object "$OVERLAY" Kustomization locust-route | yq '.spec.path')" = ./apps/base/locust/locust-route/app ]
  with="$(yq -N '.kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$OVERLAY" | LC_ALL=C sort)"
  # Without it, the overlay builds what it built but that Kustomization, and the tree passes.
  tree_without '/locust/locust-route/ks.yaml$'
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  without="$(yq -N '.kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$OVERLAY" | LC_ALL=C sort)"
  echo "only with the entry: $(comm -23 <(echo "$with") <(echo "$without") | paste -sd' ' -); only without: $(comm -13 <(echo "$with") <(echo "$without") | paste -sd' ' -)"
  [ "$(comm -23 <(echo "$with") <(echo "$without"))" = Kustomization/flux-system/locust-route ]
  [ -z "$(comm -13 <(echo "$with") <(echo "$without"))" ]
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  # Each application it names, left out, is refused, naming both.
  for dependency in locust gateway-public oauth2-proxy blackbox-exporter; do
    tree_without "/$dependency/ks.yaml\$"
    run "$REPO/scripts/kubernetes-check" "$TREE"
    echo "without $dependency: status $status"
    [ "$status" -ne 0 ]
    [[ $output == *"kubernetes/apps/base/locust/locust-route/ks.yaml: Kustomization locust-route names $dependency in dependsOn"* ]] ||
      { echo "$output"; return 1; }
  done
}

@test "Only Locust's route behind the cluster's sign-in reaches its interface, and nothing scrapes it" {
  local found named domain
  domain="$(yq -e '.CLUSTER_DOMAIN' "$VARS")"
  built
  real_render
  # What the application applies is its workloads, their Service, its locustfile and its policies,
  # and no route, probe, monitor, rule or dashboard, nothing of the Gateway API or Envoy Gateway's:
  # its route is an application of its own.
  [ "$(yq -N 'select(. != null) | .kind' "$BUILT" | LC_ALL=C sort -u | paste -sd' ' -)" = "CiliumNetworkPolicy ConfigMap Deployment Service" ]
  [ -z "$(yq -N 'select(.kind | test("^(HTTPRoute|GRPCRoute|TLSRoute|TCPRoute|UDPRoute|Probe|ServiceMonitor|PodMonitor|PrometheusRule|GrafanaDashboard)$")) | .kind' "$BUILT")" ]
  [ -z "$(yq -N 'select(.apiVersion | test("^gateway\\.(networking\\.k8s\\.io|envoyproxy\\.io)/")) | .kind' "$BUILT")" ]
  # The Service is of the cluster alone, with no external address and no label that would announce
  # it.
  [ "$(object "$BUILT" Service locust-master | yq -o json -I0 '.' | jq -c '[.spec.type // "ClusterIP", (.spec.externalIPs // [] | length),
    (.metadata.labels // {} | has("k8s-gitops/announce")), (.metadata.annotations // {} | keys | map(select(startswith("lbipam.cilium.io/"))))]')" \
    = '["ClusterIP",0,false,[]]' ]
  # Its pods ask for no scrape: Locust serves no metrics.
  [ -z "$(yq -o json -I0 'select(. != null)' "$BUILT" | jq -r 'select(.spec.template != null) | .spec.template.metadata.annotations // {} | keys[]')" ]
  # In the whole render, the route locust, behind its policy, is the one way from the Gateway to the
  # master: no other route sends there, it sends nowhere else, nothing else attaches to it or to its
  # host, and no grant opens locust's Services to another namespace.
  [ -f "$(rendered HTTPRoute.gateway.networking.k8s.io_locust_locust.yaml)" ]
  [ -f "$(rendered SecurityPolicy.gateway.envoyproxy.io_locust_locust.yaml)" ]
  found="$(interface_reach "$REAL"/*/*/*.yaml)"
  echo "ways to the master past the sign-in: ${found:-none}"
  [ -z "$found" ]
  # The only route, grant, Gateway or Envoy Gateway object, probe or monitor of the render that names
  # Locust is the route, its sign-in route, its policy, its Probe and oauth2-proxy's grant.
  named="$(cd "$REAL" && find . -type f \( -name 'HTTPRoute.*' -o -name 'GRPCRoute.*' -o -name 'TLSRoute.*' -o -name 'TCPRoute.*' \
    -o -name 'UDPRoute.*' -o -name 'ReferenceGrant.*' -o -name '*.gateway.envoyproxy.io_*' -o -name 'ServiceMonitor.*' -o -name 'PodMonitor.*' \
    -o -name 'Probe.*' -o -name 'ScrapeConfig.*' -o -name 'PrometheusRule.*' -o -name 'GrafanaDashboard.*' \) -exec grep -l 'locust' {} + |
    sed 's#.*/##' | LC_ALL=C sort | paste -sd' ' -)"
  echo "what names Locust: $named"
  [ "$named" = "HTTPRoute.gateway.networking.k8s.io_locust_locust-oauth2.yaml HTTPRoute.gateway.networking.k8s.io_locust_locust.yaml Probe.monitoring.coreos.com_locust_locust.yaml ReferenceGrant.gateway.networking.k8s.io_sso-system_oauth2-proxy.yaml SecurityPolicy.gateway.envoyproxy.io_locust_locust.yaml" ]
  # The one Probe of the host is the route's.
  [ "$(yq -N 'select(.kind == "Probe") | select(.spec.targets.staticConfig.labels.hostname == "locust.'"$domain"'") | .metadata.namespace + "/" + .metadata.name' \
    "$REAL"/*/*/Probe.monitoring.coreos.com_*.yaml)" = locust/locust ]
  # And locust holds nothing else but its workloads, their Service and ConfigMaps and its policies.
  [ "$(cd "$REAL" && find . -type f -name '*_locust_*' ! -name '*Policy*' ! -name 'Deployment.apps_*' ! -name 'Service_*' ! -name 'ConfigMap_*' -printf '%f\n' | LC_ALL=C sort | paste -sd' ' -)" \
    = "HTTPRoute.gateway.networking.k8s.io_locust_locust-oauth2.yaml HTTPRoute.gateway.networking.k8s.io_locust_locust.yaml Probe.monitoring.coreos.com_locust_locust.yaml" ]
  # Each way past the sign-in is named: a second route to the master's Service from another
  # namespace; a route of locust that no policy covers; the route to the master's other port; the
  # policy failing open; another object on the route; another route on its host; and a grant that
  # opens locust's Services to another namespace.
  awk 'FNR == 1 { print "---" } { print }' "$REAL"/*/*/*.yaml >"$BATS_TEST_TMPDIR/all.yaml"
  cp "$BATS_TEST_TMPDIR/all.yaml" "$BATS_TEST_TMPDIR/second.yaml"
  cat >>"$BATS_TEST_TMPDIR/second.yaml" <<'YAML'
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: locust-open
  namespace: demo
spec:
  parentRefs:
    - name: public
      namespace: envoy-gateway-system
      sectionName: https
  hostnames:
    - locust-open.example.org
  rules:
    - backendRefs:
        - name: hello
          port: 80
          filters:
            - type: RequestMirror
              requestMirror:
                backendRef:
                  name: locust-master
                  namespace: locust
                  port: 8089
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: locust-bare
  namespace: locust
spec:
  parentRefs:
    - name: public
      namespace: envoy-gateway-system
      sectionName: https
  hostnames:
    - locust-bare.example.org
  rules:
    - backendRefs:
        - name: locust-master
          port: 8089
YAML
  found="$(interface_reach "$BATS_TEST_TMPDIR/second.yaml")"
  echo "with a second route and a mirror: $found"
  [ "$(LC_ALL=C sort <<<"$found" | paste -sd'|' -)" = "HTTPRoute/demo/locust-open sends to the Service locust-master of locust|HTTPRoute/locust/locust-bare is on the public Gateway and no policy that asks oauth2-proxy targets it|HTTPRoute/locust/locust-bare sends to the Service locust-master of locust" ]
  yq '(select(.kind == "HTTPRoute" and .metadata.namespace == "locust" and .metadata.name == "locust") | .spec.rules[0].backendRefs[0].port) = 5557' \
    "$BATS_TEST_TMPDIR/all.yaml" >"$BATS_TEST_TMPDIR/port.yaml"
  found="$(interface_reach "$BATS_TEST_TMPDIR/port.yaml")"
  echo "with the route to the workers' port: $found"
  [ "$found" = "HTTPRoute/locust/locust sends to the Service locust-master of locust on 5557" ]
  yq '(select(.kind == "SecurityPolicy" and .metadata.namespace == "locust") | .spec.extAuth.failOpen) = true' \
    "$BATS_TEST_TMPDIR/all.yaml" >"$BATS_TEST_TMPDIR/open.yaml"
  found="$(interface_reach "$BATS_TEST_TMPDIR/open.yaml")"
  echo "with the policy failing open: $found"
  [ "$(LC_ALL=C sort <<<"$found" | paste -sd'|' -)" = "HTTPRoute/locust/locust is on the public Gateway and no policy that asks oauth2-proxy targets it|HTTPRoute/locust/locust-oauth2 is on the public Gateway and no policy that asks oauth2-proxy targets it|SecurityPolicy/locust/locust targets the route locust" ]
  cp "$BATS_TEST_TMPDIR/all.yaml" "$BATS_TEST_TMPDIR/host.yaml"
  cat >>"$BATS_TEST_TMPDIR/host.yaml" <<YAML
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hello-locust
  namespace: demo
spec:
  parentRefs:
    - name: public
      namespace: envoy-gateway-system
      sectionName: https
  hostnames:
    - locust.$domain
  rules:
    - backendRefs:
        - name: hello
          port: 80
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: locust
  namespace: locust
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: locust
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: locust-open
  namespace: locust
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: demo
  to:
    - group: ""
      kind: Service
YAML
  found="$(interface_reach "$BATS_TEST_TMPDIR/host.yaml")"
  echo "with another route on the host, a second object on the route and a grant: $found"
  [ "$(LC_ALL=C sort <<<"$found" | paste -sd'|' -)" = "EnvoyExtensionPolicy/locust/locust targets the route locust|HTTPRoute/demo/hello-locust lists the host of the route locust|ReferenceGrant/locust/locust-open lets another namespace refer to the Services of locust" ]
}

@test "just locust forwards a local port to Locust's master" {
  local script_pid port
  recipe_copy
  for port in default 3456; do
    if [[ $port == default ]]; then port=8089; else with LOCUST_PORT="$port"; fi
    locust_start
    printed "http://127.0.0.1:$port"
    cat "$OUT"
    # Only once kubectl reports the forward.
    [ -s "$STATE/pids" ]
    read -r _ script_pid <"$STATE/pids"
    kill -INT "$script_pid" "$JUST_PID"
    finished
  done
  echo "kubectl ran: $(cat "$RECORD/argv")"
  [ "$(cat "$RECORD/argv")" = "$(printf '%s\n' \
    'port-forward --address 127.0.0.1 --namespace locust service/locust-master 8089:8089' \
    'port-forward --address 127.0.0.1 --namespace locust service/locust-master 3456:8089')" ]
  [ "$(sort -u "$RECORD/kubeconfig")" = "$KUBECONFIG_FILE" ]
  # What reaching it means, in one line: no sign-in, and whatever runs on this machine can start a
  # test.
  grep -qxF 'The interface has no sign-in: anything on this machine, a web page in the browser included, can start a test through it while the forward runs.' "$OUT"
  grep -qxF 'Ctrl-C ends the forward.' "$OUT"
  if grep -qF 'Forwarding from' "$OUT"; then echo "kubectl's own output was printed"; return 1; fi
}

@test "just locust ends the forward on every way out" {
  local script_pid
  recipe_copy
  # Ctrl-C: the terminal signals the recipe, while kubectl, run in the background, ignores it.
  locust_start
  printed "http://127.0.0.1:8089"
  read -r _ script_pid <"$STATE/pids"
  kill -INT "$script_pid" "$JUST_PID"
  finished
  echo "after Ctrl-C: status $STATUS; $(cat "$OUT")"
  [ "$STATUS" -ne 0 ]
  kubectl_gone
  [ "$(cat "$RECORD/ended")" = SIGTERM ]
  [[ "$(cat "$OUT")" == *"The forward to Locust has ended."* ]]

  # SIGTERM, which just passes on to the recipe.
  rm "$RECORD/ended"
  locust_start
  printed "http://127.0.0.1:8089"
  kill -TERM "$JUST_PID"
  finished
  echo "after SIGTERM: status $STATUS"
  [ "$STATUS" -ne 0 ]
  kubectl_gone
  [ "$(cat "$RECORD/ended")" = SIGTERM ]

  # kubectl never reports the forward.
  rm "$RECORD/ended"
  echo silent >"$STATE/mode"
  with LOCUST_WAIT=1
  locust_recipe
  echo "kubectl silent: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"did not report the forward within 1 seconds"* ]]
  [[ $output != *"http://"* ]]
  kubectl_gone
  [ "$(cat "$RECORD/ended")" = SIGTERM ]

  # kubectl stops before it forwards, with an error that names the API server's address.
  echo fail >"$STATE/mode"
  locust_recipe
  echo "kubectl failing: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"stopped with status 1 before it forwarded"* ]]
  [[ $output != *192.0.2.10* ]]
  kubectl_gone

  # kubectl stops while it forwards.
  echo drop >"$STATE/mode"
  locust_recipe
  echo "kubectl dropping: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"http://127.0.0.1:8089"* ]]
  [[ $output == *"stopped with status 1"* ]]
  kubectl_gone
}

@test "just locust runs kubectl with none of the secrets" {
  recipe_copy
  # Every secret variable the recipes read, as a marker, besides the settings the recipe reads.
  names=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CLUSTER_S3_ACCESS_KEY_ID CLUSTER_S3_SECRET_ACCESS_KEY
    OS_CLOUD OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET TF_STATE_PASSPHRASE
    TF_ENCRYPTION SOPS_AGE_KEY SOPS_AGE_KEY_FILE FLUX_AGE_KEY FLUX_AGE_KEY_FILE OPERATOR_CIDRS)
  for name in "${names[@]}"; do with "$name=marker-$name"; done
  with LOCUST_PORT=3456
  echo fail >"$STATE/mode"

  locust_recipe

  [ -s "$RECORD/names" ]
  # What is no secret reaches kubectl, and the kubeconfig it is run with.
  grep -qx KUBECONFIG "$RECORD/names"
  grep -qx LOCUST_PORT "$RECORD/names"
  for name in "${names[@]}"; do
    echo "$name"
    if grep -qx "$name" "$RECORD/names"; then return 1; fi
  done
}

@test "just locust needs the cluster's kubeconfig and a port" {
  local port
  recipe_copy
  rm "$KUBECONFIG_FILE"
  with LOCUST_PORT=65536 LOCUST_WAIT=soon
  locust_recipe
  echo "status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/clusterconfig/kubeconfig does not exist; just cluster-kubeconfig fetches it"* ]]
  [[ $output == *"LOCUST_PORT is not a port number"* ]]
  [[ $output == *"LOCUST_WAIT is not a whole number of seconds"* ]]
  # With the kubeconfig in place, each port alone is refused.
  echo 'not a real kubeconfig' >"$KUBECONFIG_FILE"
  for port in 0 080 abc 3000x; do
    only LOCUST_PORT="$port"
    locust_recipe
    echo "LOCUST_PORT='$port': status $status; $output"
    [ "$status" -ne 0 ]
    [[ $output == *"LOCUST_PORT is not a port number"* ]]
  done
  [ ! -e "$RECORD/argv" ]
}
