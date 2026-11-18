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
  # The overlay selects it with two entries, the namespace directory and the application's ks.yaml.
  [ "$(yq '.resources[] | select(test("/locust(/|$)"))' "$OVERLAY_DIR/kustomization.yaml" | LC_ALL=C sort | paste -sd' ' -)" \
    = "../../base/locust ../../base/locust/locust/ks.yaml" ]
  overlay
  [ "$(of_namespace "$OVERLAY")" = ConfigMap/locust/app-template-defaults,Kustomization/flux-system/locust,Namespace/-/locust,NetworkPolicy/locust/default-deny ]
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
  # its default deny, and nothing of Locust.
  tree_without '/locust/locust/ks.yaml$'
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
  # leaves the tree, and no workload of it is excepted.
  ns="$(object "$OVERLAY" Namespace "$NAMESPACE" | yq -o json -I0 '.metadata')"
  [ "$(jq -cS '.labels' <<<"$ns")" = '{"pod-security.kubernetes.io/enforce":"restricted"}' ]
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
  # The policies of the namespace are the default deny and Locust's two, nothing else.
  [ "$(cd "$REAL" && find . -type f -name '*Policy*_locust_*' -printf '%f\n' | LC_ALL=C sort | paste -sd' ' -)" \
    = "CiliumNetworkPolicy.cilium.io_locust_locust-master.yaml CiliumNetworkPolicy.cilium.io_locust_locust-worker.yaml NetworkPolicy.networking.k8s.io_locust_default-deny.yaml" ]
  # Every rule of the two and of hello's, exactly: the master takes the workers and the kubelet's
  # probe and sends nothing; the workers take nothing and reach the master, the resolver and hello's
  # pods; hello takes the workers beside the proxies and the kubelet.
  policies=("$(rendered CiliumNetworkPolicy.cilium.io_locust_locust-master.yaml)" "$(rendered CiliumNetworkPolicy.cilium.io_locust_locust-worker.yaml)"
    "$(rendered CiliumNetworkPolicy.cilium.io_demo_hello.yaml)")
  allows "${policies[@]}"
  [ "$(allows "${policies[@]}")" = "$(printf '%s\n' \
    "hello [app.kubernetes.io/name=hello] takes @host on 8080/TCP" \
    "hello [app.kubernetes.io/name=hello] takes app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,app.kubernetes.io/name=envoy,gateway.envoyproxy.io/owning-gateway-name=public,gateway.envoyproxy.io/owning-gateway-namespace=envoy-gateway-system,io.kubernetes.pod.namespace=envoy-gateway-system on 8080/TCP" \
    "hello [app.kubernetes.io/name=hello] takes app.kubernetes.io/component=worker,app.kubernetes.io/name=locust,io.kubernetes.pod.namespace=locust on 8080/TCP" \
    "locust-master [app.kubernetes.io/component=master,app.kubernetes.io/name=locust] takes @host on 8089/TCP" \
    "locust-master [app.kubernetes.io/component=master,app.kubernetes.io/name=locust] takes app.kubernetes.io/component=worker,app.kubernetes.io/name=locust,io.kubernetes.pod.namespace=locust on 5557/TCP" \
    "locust-worker [app.kubernetes.io/component=worker,app.kubernetes.io/name=locust] sends to app.kubernetes.io/component=master,app.kubernetes.io/name=locust,io.kubernetes.pod.namespace=locust on 5557/TCP" \
    "locust-worker [app.kubernetes.io/component=worker,app.kubernetes.io/name=locust] sends to app.kubernetes.io/name=hello,io.kubernetes.pod.namespace=demo on 8080/TCP" \
    "locust-worker [app.kubernetes.io/component=worker,app.kubernetes.io/name=locust] sends to io.kubernetes.pod.namespace=kube-system,k8s-app=kube-dns on 53/TCP+53/UDP" |
    LC_ALL=C sort)" ]
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
    # The master takes the workers on its port and the kubelet's probe, and no one else.
    "reaches --reach @host $MASTER $probe/tcp"
    "refused --reach @world $MASTER 8089/tcp"
    "refused --reach @world $MASTER 5557/tcp"
    "refused --reach @remote-node $MASTER 8089/tcp"
    "refused --reach $PROXY $MASTER 8089/tcp"
    "refused --reach $PROXY $MASTER 5557/tcp"
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

@test "Nothing routes to Locust or scrapes it" {
  local named
  built
  overlay
  real_render
  # What it applies is its workloads, their Service, its locustfile and its policies, and no route,
  # probe, monitor, rule or dashboard, nothing of the Gateway API or Envoy Gateway's.
  [ "$(yq -N 'select(. != null) | .kind' "$BUILT" | LC_ALL=C sort -u | paste -sd' ' -)" = "CiliumNetworkPolicy ConfigMap Deployment Service" ]
  [ -z "$(yq -N 'select(.kind | test("^(HTTPRoute|GRPCRoute|TLSRoute|TCPRoute|UDPRoute|Probe|ServiceMonitor|PodMonitor|PrometheusRule|GrafanaDashboard)$")) | .kind' "$BUILT")" ]
  [ -z "$(yq -N 'select(.apiVersion | test("^gateway\\.(networking\\.k8s\\.io|envoyproxy\\.io)/")) | .kind' "$BUILT")" ]
  # The namespace carries no Gateway label, so no route of it may attach to the public Gateway, and
  # the Service is of the cluster alone, with no external address and no label that would announce
  # it.
  [ "$(object "$OVERLAY" Namespace "$NAMESPACE" | yq '.metadata.labels | has("k8s-gitops/gateway")')" = false ]
  [ "$(object "$BUILT" Service locust-master | yq -o json -I0 '.' | jq -c '[.spec.type // "ClusterIP", (.spec.externalIPs // [] | length),
    (.metadata.labels // {} | has("k8s-gitops/announce")), (.metadata.annotations // {} | keys | map(select(startswith("lbipam.cilium.io/"))))]')" \
    = '["ClusterIP",0,false,[]]' ]
  # Its pods ask for no scrape: Locust serves no metrics.
  [ -z "$(yq -o json -I0 'select(. != null)' "$BUILT" | jq -r 'select(.spec.template != null) | .spec.template.metadata.annotations // {} | keys[]')" ]
  # No route, grant or monitor of the whole render names Locust, wherever it is.
  named="$(cd "$REAL" && find . -type f \( -name 'HTTPRoute.*' -o -name 'GRPCRoute.*' -o -name 'TLSRoute.*' -o -name 'TCPRoute.*' \
    -o -name 'UDPRoute.*' -o -name 'ReferenceGrant.*' -o -name 'ServiceMonitor.*' -o -name 'PodMonitor.*' -o -name 'Probe.*' \
    -o -name 'ScrapeConfig.*' -o -name 'PrometheusRule.*' -o -name 'GrafanaDashboard.*' \) -exec grep -l 'locust' {} + || true)"
  [ -z "$named" ] || { echo "these name Locust: $named"; return 1; }
  [ -z "$(cd "$REAL" && find . -type f -name '*_locust_*' ! -name '*Policy*' ! -name 'Deployment.apps_*' ! -name 'Service_*' ! -name 'ConfigMap_*' -printf '%f\n')" ]
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
