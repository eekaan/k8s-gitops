#!/usr/bin/env bats
# Proves features/escape-canary.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq, jq, kyverno and gator on PATH (the versions pinned for the
# repository). Building is offline, with the placeholders of the cluster's example key lists; the
# tests of the flows, the table, the schedules, the mode and the bindings read the render of the
# tree, whose charts are pulled once per run from their public registries. The checks' scripts run on
# the host's sh against stand-ins for nc, nslookup, timeout and kubectl, which print what busybox
# 1.38.0 and the Flux CLI image's kubectl print, addresses included, and reach nothing; where a
# docker daemon answers, each check also runs in its pinned image with no network.

# The tests run one at a time even where bats runs a file's tests side by side: the tests that read
# the render share one, made by whichever of them comes first.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

bats_require_minimum_version 1.5.0

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
  NAMESPACE=escape-canary
  BASE="$REPO/kubernetes/apps/base/escape-canary"
  APP="$BASE/escape-canary"
  TABLE="$APP/app/expected.tsv"
  OVERLAY_DIR="$REPO/kubernetes/apps/overlays/lab-sto2"
  DOCS="$REPO/docs/kubernetes.md"
  NETWORK=escape-canary/CronJob/escape-canary-network
  RIGHTS=escape-canary/CronJob/escape-canary-rights
  HELLO=demo/Deployment/hello
  OPENBAO=openbao/StatefulSet/openbao
  # Pods no render holds, by their labels: the cluster's resolver, which Talos deploys, Prometheus,
  # which its operator makes, the public Gateway's proxies, which Envoy Gateway makes, an application
  # of another namespace, and a pod of the canary's namespace without the canary's labels.
  DNS='kube-system:k8s-app=kube-dns'
  PROMETHEUS='monitoring:app.kubernetes.io/name=prometheus'
  PROXY='envoy-gateway-system:app.kubernetes.io/name=envoy,app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,gateway.envoyproxy.io/owning-gateway-name=public,gateway.envoyproxy.io/owning-gateway-namespace=envoy-gateway-system'
  OTHER_APP='other:app.kubernetes.io/name=app'
  STRAY='escape-canary:app.kubernetes.io/name=escape-canary,app.kubernetes.io/component=stray'
  # The attempts of the table, in order, and the results it may give.
  ATTEMPTS='resolver metadata kubelet talos-api api-server hello secret-store read-secret list-pods'
  RESULTS='open refused blocked unresolved forbidden allowed'
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

# object FILE KIND NAME: the one object of that kind and name in FILE.
object() {
  KIND="$2" NAME="$3" yq -N 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$1"
}

# built NAME [ROOT]: the application NAME as Flux applies it on lab-sto2, from the tree ROOT (the
# repository when none is given): the cluster's root built as Flux builds it, so the overlay's
# Kustomization of the application carries what the root patches into every child, then that
# Kustomization built in memory with the example key lists under its own substitutions, strictly.
# Writes the build to $BUILT and sets KS, the Kustomization with those substitutions.
built() {
  local root="${2:-$REPO}" ks path rootfile
  ks="$root/kubernetes/clusters/lab-sto2/ks.yaml"
  path="$(yq '.spec.path' "$ks")"
  rootfile="$BATS_TEST_TMPDIR/root.yaml"
  (cd "$root" && flux build kustomization "$(yq '.metadata.name' "$ks")" \
    --path "./kubernetes/${path#./}" --kustomization-file "$ks" --dry-run --in-memory-build) >"$rootfile"
  KS="$BATS_TEST_TMPDIR/$1-ks.yaml"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  NAME="$1" yq ea 'select(fileIndex == 0) as $vars
    | select(fileIndex == 1 and .kind == "Kustomization" and .metadata.name == strenv(NAME))
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "$VARS" "$rootfile" >"$KS"
  [ -s "$KS" ] || { echo "the lab-sto2 overlay does not enable $1"; return 1; }
  path="$(yq '.spec.path' "$KS")"
  BUILT="$BATS_TEST_TMPDIR/$1-built.yaml"
  (cd "$root" && flux build kustomization "$1" --path "./kubernetes/${path#./}" \
    --kustomization-file "$KS" --dry-run --strict-substitute --in-memory-build) | yq 'select(. != null)' >"$BUILT"
}

# real_render: the render of this repository's tree, charts pulled, in $BATS_FILE_TMPDIR/render,
# made once for the file, and VIEW, the files of it that the evaluation of a flow reads (the
# namespaces, the workloads, the Gateways and the policies), as tests/network-policy.bats takes them.
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

# rendered NAME: the path of the one file of the render named NAME, in any application.
rendered() {
  local files=("$REAL"/*/*/"$1")
  [ "${#files[@]}" -eq 1 ] && [ -f "${files[0]}" ] || { echo "$1 is not one file of the render: ${files[*]}" >&2; return 1; }
  echo "${files[0]}"
}

# workload NAME: writes the CronJob NAME of $BUILT to $WORKLOAD, its pod template to $POD and its one
# container to $CONTAINER.
workload() {
  WORKLOAD="$BATS_TEST_TMPDIR/workload-$1.yaml"
  POD="$BATS_TEST_TMPDIR/pod-$1.yaml"
  CONTAINER="$BATS_TEST_TMPDIR/container-$1.yaml"
  object "$BUILT" CronJob "$1" >"$WORKLOAD"
  [ -s "$WORKLOAD" ] || { echo "the build has no CronJob $1"; return 1; }
  yq '.spec.jobTemplate.spec.template' "$WORKLOAD" >"$POD"
  [ "$(yq '.spec.containers | length' "$POD")" -eq 1 ] || { echo "the pod of $1 has not one container"; return 1; }
  yq '.spec.containers[0]' "$POD" >"$CONTAINER"
}

# restricted_failures FILE NAMESPACE: what the Pod Security restricted level refuses in the pod the
# pod template in FILE makes in NAMESPACE, by Kyverno's podSecurity rule as pod-security-check runs
# it: writes the failed controls, one per line, to $CONTROLS and the whole message to $FORBIDDEN.
restricted_failures() {
  local dir
  dir="$BATS_TEST_TMPDIR/restricted-$(basename "$1" .yaml)"
  rm -rf "$dir"
  mkdir -p "$dir"
  NS="$2" yq -o json '{"apiVersion": "v1", "kind": "Pod",
    "metadata": {"name": "pod", "namespace": strenv(NS)} * (.metadata | pick(["labels", "annotations"])),
    "spec": .spec}' "$1" >"$dir/pod.yaml"
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
  jq -e '.results | length == 1 and (.[0].result == "pass" or .[0].result == "fail")' "$dir/report.json" >/dev/null ||
    { echo "Kyverno gave no verdict on the pod: $(cat "$dir/out" "$dir/err")"; return 1; }
  CONTROLS="$dir/controls"
  FORBIDDEN="$dir/forbidden"
  jq -r '.results[0] | select(.result == "fail") | .properties.controls // "" | split(",") | .[] | select(. != "")' "$dir/report.json" | LC_ALL=C sort >"$CONTROLS"
  jq -r '.results[0] | select(.result == "fail") | .message // ""' "$dir/report.json" >"$FORBIDDEN"
}

# admission PODS NAMESPACES: runs the rules of both admission engines, as their applications build
# them, over the Pods of the file PODS and the Namespaces of the file NAMESPACES, as
# tests/admission-policy.bats runs them over the render. Sets KYVERNO_STATUS, KYVERNO_OUTPUT,
# GATEKEEPER_FINDINGS, the number of the constraints' findings, and GATEKEEPER_OUTPUT.
admission() {
  local dir="$BATS_TEST_TMPDIR/admission"
  rm -rf "$dir"
  mkdir -p "$dir"
  built kyverno-policies
  cp "$BUILT" "$dir/kyverno.yaml"
  built gatekeeper-templates
  cp "$BUILT" "$dir/gatekeeper.yaml"
  built gatekeeper-policies
  { echo ---; cat "$BUILT"; } >>"$dir/gatekeeper.yaml"
  yq -N -o json -I0 'select(.kind == "Namespace")' "$2" | jq -s '{apiVersion: "cli.kyverno.io/v1alpha1", kind: "Values",
    namespaceSelector: [.[] | {name: .metadata.name, labels: (.metadata.labels // {})}]}' >"$dir/values.json"
  set +e
  KYVERNO_OUTPUT="$(kyverno apply "$dir/kyverno.yaml" --resource "$1" --resource "$2" --values-file "$dir/values.json" 2>&1)"
  KYVERNO_STATUS=$?
  GATEKEEPER_OUTPUT="$(gator test --filename "$dir/gatekeeper.yaml" --filename "$1" --filename "$2" --output json 2>&1)"
  set -e
  GATEKEEPER_FINDINGS="$(jq 'length' <<<"$GATEKEEPER_OUTPUT" 2>/dev/null || echo "not JSON")"
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

# of_namespace FILE: what an overlay built into FILE holds of the canary and of its namespace,
# sorted, as kind, namespace and name: the namespace itself, any object in it, and any Kustomization
# that deploys into it or from its directory.
of_namespace() {
  yq -N 'select((.kind == "Namespace" and .metadata.name == "escape-canary") or .metadata.namespace == "escape-canary"
      or .spec.targetNamespace == "escape-canary" or ((.spec.path // "") | test("/apps/base/escape-canary/")))
    | .kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$1" | LC_ALL=C sort | paste -sd, -
}

# allows FILE...: what the Cilium policies of the FILEs allow, one rule a line and sorted: the
# policy, the pods it selects, the direction, the peers and the ports. It fails on what it does not
# read rather than skip it, as tests/robot.bats' does.
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

# reaches and refused SIDE FROM TO PORT: assert what the policies of the render's view answer for the
# flow, as scripts/network-policy-check evaluates them the way Cilium decides: SIDE is --reach for the
# sender's egress and the receiver's ingress together, --reach-egress for the sender's alone and
# --reach-ingress for the receiver's alone.
reaches() {
  run "$REPO/scripts/network-policy-check" "$1" "$VIEW" "${@:2}"
  [ "$status" -eq 0 ] || { echo "expected ${*:2} to be allowed ($1): $output"; return 1; }
}
refused() {
  run "$REPO/scripts/network-policy-check" "$1" "$VIEW" "${@:2}"
  [ "$status" -eq 1 ] || { echo "expected ${*:2} to be denied ($1): $output"; return 1; }
}

# mounts FILE: the mounts of the one container of the pod template in FILE, as a set, one a line:
# the path, the kind of its volume, the object it names, or the medium and size of an emptyDir, and
# whether the container may write there.
mounts() {
  yq -o json '.spec' "$1" | jq -r '. as $pod | .containers[] | (.volumeMounts // [])[] | . as $m
    | ([$pod.volumes[] | select(.name == $m.name)][0] // {}) as $v
    | [$m.mountPath, ($v | del(.name) | keys | join("+")),
       (if $v.configMap then $v.configMap.name + (if $v.configMap.optional == true then " optional" else "" end)
        elif $v.emptyDir then ($v.emptyDir.medium // "disk") + ":" + ($v.emptyDir.sizeLimit // "unlimited")
        else "-" end),
       (if $m.readOnly == true then "read-only" else "writable" end)] | join(" ")' | LC_ALL=C sort
}

# rows: the table's rows, its comments and empty lines left out, one a line, tab-separated.
rows() {
  awk '!/^#/ && NF' "$TABLE"
}

# field ATTEMPT N: the Nth field of the table's row of ATTEMPT.
field() {
  rows | awk -F'\t' -v attempt="$1" -v n="$2" '$1 == attempt { print $n }'
}

# domain: the cluster's DNS domain, as the nodes' machine configuration sets it.
domain() {
  yq -N 'select(.kind == "KubeNetworkConfig") | .dnsDomain' "$REPO/talos/patches/all/cluster-network.yaml"
}

# flat: its input on one line, every run of white space one space.
flat() {
  tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

# section HEADING: the docs' section of that heading, from it to the next heading of its level or
# above.
section() {
  HEADING="$1" awk 'BEGIN { h = ENVIRON["HEADING"]; n = index(h, " ") - 1 }
    $0 == h { on = 1; next }
    on && /^#+ / { m = index($0, " ") - 1; if (m <= n) exit }
    on' "$DOCS"
}

# step N: step N of the docs' Turning it on, and back, on one line.
step() {
  section '### Turning it on, and back' | awk -v n="$1" '$0 ~ "^" n "\\. \\*\\*" { on = 1; print; next } on && /^[0-9]+\. \*\*/ { exit } on' | flat
}

# The stand-ins of the checks' tools, one script under four names, written by standins: each records
# its name and arguments, one call a line, in $STANDIN_CALLS, and answers as $STANDIN_RESULTS says
# for its call, a line of a key and a result, tab-separated: nc by its host and port, nslookup by
# its name and kubectl by all of its arguments. Each prints, for its result, what the tool it stands
# in for prints, addresses included: busybox 1.38.0's nc with -z -v -v (networking/nc_bloaty.c) and
# nslookup (networking/nslookup.c), as seen in a run of the pinned image, and the Flux CLI image's
# kubectl, as seen against a stand-in API server. nslookup also answers empty, which is no result:
# what it prints, by networking/nslookup.c, for a name that holds no record of the two types it asks
# for, its server's address and no Name: line, exiting 0. timeout passes its command on, and a
# command whose result is blocked ends as one timeout killed does, with no output and the status of
# the signal: busybox's timeout sends TERM unless told otherwise, and the rights check asks it for
# KILL.
standins() {
  local bash name
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  bash="$(command -v bash)"
  # The checks run with the stand-ins alone on PATH, so a stand-in names its own awk.
  cat >"$BIN/standin" <<STANDIN
#!$bash
awk=$(command -v awk)
STANDIN
  cat >>"$BIN/standin" <<'STANDIN'
name=${0##*/}
printf '%s\n' "$name $*" >>"$STANDIN_CALLS"
address() { if [[ $1 =~ ^[0-9.]+$ ]]; then echo "$1"; else echo 192.0.2.10; fi; }
case $name in
  timeout)
    [ "$1" != -s ] || shift 2
    shift
    exec "$@"
    ;;
  nc) host=${*: -2:1} port=${*: -1} key="nc ${*: -2:1} ${*: -1}" ;;
  nslookup) key="nslookup $1" ;;
  kubectl) key="kubectl $*" ;;
esac
result="$("$awk" -F'\t' -v key="$key" '$1 == key { print $2 }' "$STANDIN_RESULTS")"
[ -n "$result" ] || { echo "stand-in: no result for $key" >&2; exit 99; }
case $name:$result in
  nc:open) printf '%s (%s:%s) open\nsent 0, rcvd 0\n' "$host" "$(address "$host")" "$port" >&2; exit 0 ;;
  nc:refused) printf 'nc: %s (%s:%s): Connection refused\nsent 0, rcvd 0\n' "$host" "$(address "$host")" "$port" >&2; exit 1 ;;
  nc:blocked) printf 'nc: %s (%s:%s): Connection timed out\nsent 0, rcvd 0\n' "$host" "$(address "$host")" "$port" >&2; exit 1 ;;
  nc:unresolved) printf "nc: bad address '%s'\n" "$host" >&2; exit 1 ;;
  nc:other) printf 'nc: %s (%s:%s): No route to host\nsent 0, rcvd 0\n' "$host" "$(address "$host")" "$port" >&2; exit 1 ;;
  nslookup:open) printf 'Server:\t\t192.0.2.53\nAddress:\t192.0.2.53:53\n\nName:\t%s\nAddress: 192.0.2.1\n\n' "$1"; exit 0 ;;
  nslookup:empty) printf 'Server:\t\t192.0.2.53\nAddress:\t192.0.2.53:53\n\nNon-authoritative answer:\n\nNon-authoritative answer:\n\n'; exit 0 ;;
  nslookup:unresolved) printf "Server:\t\t192.0.2.53\nAddress:\t192.0.2.53:53\n\n** server can't find %s: NXDOMAIN\n\n** server can't find %s: NXDOMAIN\n\n" "$1" "$1"; exit 1 ;;
  nslookup:refused) printf "nslookup: write to '192.0.2.53': Connection refused\n;; connection timed out; no servers could be reached\n\n"; exit 1 ;;
  nslookup:blocked) exit 143 ;;
  nslookup:other) printf 'nslookup: can'"'"'t connect to remote host (192.0.2.53): Network is unreachable\n' >&2; exit 1 ;;
  kubectl:forbidden) printf 'Error from server (Forbidden): secrets "cluster-secrets" is forbidden: User "system:serviceaccount:escape-canary:escape-canary-rights" cannot get resource "secrets" in API group "" in the namespace "flux-system"\n' >&2; exit 1 ;;
  kubectl:allowed) printf 'secret/cluster-secrets\n'; exit 0 ;;
  kubectl:blocked) exit 137 ;;
  kubectl:other) printf 'The connection to the server 192.0.2.1:443 was refused - did you specify the right host or port?\n' >&2; exit 1 ;;
esac
echo "stand-in: $name has no answer $result" >&2
exit 98
STANDIN
  chmod +x "$BIN/standin"
  for name in nc nslookup timeout kubectl; do
    ln -sf standin "$BIN/$name"
  done
}

# The node a run of the checks names, and the address of its node, a documentation address.
NODE=worker-1
NODE_IP=192.0.2.7

# key ATTEMPT: the key of the stand-ins' answer for the call the row ATTEMPT makes.
key() {
  local target port
  target="$(field "$1" 3)" port="$(field "$1" 4)"
  case $1 in
    read-secret) echo "kubectl get secret cluster-secrets --namespace flux-system --output name" ;;
    list-pods) echo "kubectl get pods --all-namespaces --output name" ;;
    *)
      [ "$target" != node ] || target=$NODE_IP
      if [ "$port" = 53/udp ]; then echo "nslookup $target"; else echo "nc $target ${port%/tcp}"; fi
      ;;
  esac
}

# as_run CHECK: the container of the CronJob escape-canary-CHECK of $BUILT, as the kubelet would run
# it on a node: fails unless its command is the image's sh running the check's own script,
# /scripts/CHECK.sh, and its variables are the mode, the table, the node's name from the downward
# API's spec.nodeName and, for the network check, the node's address from status.hostIP, or, for the
# rights check, HOME. Writes each ConfigMap the container mounts under $BATS_TEST_TMPDIR/pod-CHECK at
# its mount path, a file a key, and makes its emptyDirs there; writes the container's variables to
# $BATS_TEST_TMPDIR/pod-CHECK.env, one NAME=VALUE a line, a path under a mount moved under that root
# and the downward API's fields given the node's name and address of a run of the checks; and the
# script its command runs, under that root, to $BATS_TEST_TMPDIR/pod-CHECK.script.
as_run() {
  local root="$BATS_TEST_TMPDIR/pod-$1" path kind source key name from value mount paths=() want
  workload "escape-canary-$1"
  [ "$(yq -o json -I0 '[.command, .args // null]' "$CONTAINER")" = "[[\"/bin/sh\",\"/scripts/$1.sh\"],null]" ] ||
    { echo "escape-canary-$1 runs $(yq -o json -I0 '[.command, .args // null]' "$CONTAINER"), not /bin/sh /scripts/$1.sh"; return 1; }
  rm -rf "$root"
  while read -r path kind source _; do
    paths+=("$path")
    case $kind in
      configMap)
        mkdir -p "$root$path"
        object "$BUILT" ConfigMap "$source" >"$root.configmap"
        [ -s "$root.configmap" ] || { echo "escape-canary-$1 mounts the ConfigMap $source, which the build does not hold"; return 1; }
        while IFS= read -r key; do
          KEY="$key" yq -o json '.data[strenv(KEY)]' "$root.configmap" | jq -j . >"$root$path/$key"
        done < <(yq '.data | keys | .[]' "$root.configmap")
        ;;
      emptyDir) mkdir -p "$root$path" ;;
      *) echo "escape-canary-$1 mounts $kind at $path, which this test does not make"; return 1 ;;
    esac
  done < <(mounts "$POD")
  chmod -R a+rX "$root"
  if [ "$1" = network ]; then want="CANARY_MODE CANARY_TABLE NODE_IP NODE_NAME"; else want="CANARY_MODE CANARY_TABLE HOME NODE_NAME"; fi
  [ "$(yq -o json '.env' "$CONTAINER" | jq -r '[.[].name] | sort | join(" ")')" = "$want" ] ||
    { echo "escape-canary-$1 sets $(yq -o json '.env' "$CONTAINER" | jq -r '[.[].name] | sort | join(" ")'), not $want"; return 1; }
  [ "$(yq '.env[] | select(.name == "NODE_NAME") | .valueFrom.fieldRef.fieldPath' "$CONTAINER")" = spec.nodeName ] ||
    { echo "escape-canary-$1 takes NODE_NAME from somewhere else than the pod's spec.nodeName"; return 1; }
  if [ "$1" = network ]; then
    [ "$(yq '.env[] | select(.name == "NODE_IP") | .valueFrom.fieldRef.fieldPath' "$CONTAINER")" = status.hostIP ] ||
      { echo "escape-canary-network takes NODE_IP from somewhere else than the pod's status.hostIP"; return 1; }
  fi
  : >"$root.env"
  while IFS=$'\t' read -r name from value; do
    case $from:$value in
      field:spec.nodeName) value=$NODE ;;
      field:status.hostIP) value=$NODE_IP ;;
      value:*) ;;
      *) echo "escape-canary-$1 sets $name from $from $value, which this test does not give"; return 1 ;;
    esac
    for mount in "${paths[@]}"; do
      if [[ $value == "$mount" || $value == "$mount"/* ]]; then value="$root$value"; fi
    done
    printf '%s=%s\n' "$name" "$value" >>"$root.env"
  done < <(yq -o json '.env' "$CONTAINER" | jq -r '.[] | [.name,
    (if has("value") then "value" elif .valueFrom.fieldRef then "field" else "other" end),
    (.value // .valueFrom.fieldRef.fieldPath // "-")] | @tsv')
  echo "$root$(yq '.command[1]' "$CONTAINER")" >"$root.script"
}

# check CHECK MODE [CHANGED RESULT]: runs the CHECK's script as its container runs it, as as_run CHECK
# has written it, under the host's sh with only the stand-ins on PATH, in MODE, each stand-in
# answering with the table's result for the mode, or RESULT for the row CHANGED; TABLE_OVERRIDE, when
# set, is the table it reads. Sets status, output and stderr, and CALLS, the stand-ins' calls.
check() {
  local mode="$2" attempt column var vars=()
  [ "$mode" = audit ] && column=6 || column=7
  STANDIN_RESULTS="$BATS_TEST_TMPDIR/results"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$STANDIN_RESULTS"
  : >"$CALLS"
  for attempt in $ATTEMPTS; do
    if [ "$attempt" = "${3:-}" ]; then
      printf '%s\t%s\n' "$(key "$attempt")" "$4" >>"$STANDIN_RESULTS"
    else
      printf '%s\t%s\n' "$(key "$attempt")" "$(field "$attempt" "$column")" >>"$STANDIN_RESULTS"
    fi
  done
  while IFS= read -r var; do
    case $var in
      CANARY_MODE=*) ;;
      CANARY_TABLE=*) vars+=("CANARY_TABLE=${TABLE_OVERRIDE:-${var#CANARY_TABLE=}}") ;;
      *) vars+=("$var") ;;
    esac
  done <"$BATS_TEST_TMPDIR/pod-$1.env"
  run --separate-stderr env -i PATH="$BIN" STANDIN_RESULTS="$STANDIN_RESULTS" STANDIN_CALLS="$CALLS" \
    "${vars[@]}" CANARY_MODE="$mode" "$(command -v sh)" "$(cat "$BATS_TEST_TMPDIR/pod-$1.script")"
}

# in_image CHECK SETUP TABLE [OPTION...]: runs the CHECK's script in the image of the build's CronJob
# escape-canary-CHECK, as as_run CHECK has written its scripts, by its command after SETUP, a shell
# command line, under docker with no network, a read-only root, user 65534, no capability and each
# docker OPTION, the file TABLE at the path its CANARY_TABLE names, in the mode audit, on the node
# $NODE, whose address is the loopback's. Sets status, output and stderr.
in_image() {
  local path command=()
  workload "escape-canary-$1"
  mapfile -t command < <(yq '.command[]' "$CONTAINER")
  path="$(yq '.env[] | select(.name == "CANARY_TABLE") | .value' "$CONTAINER")"
  run --separate-stderr docker run --rm --network none --read-only --user 65534:65534 --cap-drop ALL "${@:4}" \
    -v "$BATS_TEST_TMPDIR/pod-$1/scripts:/scripts:ro" -v "$3:$path:ro" \
    -e CANARY_MODE=audit -e CANARY_TABLE="$path" -e NODE_NAME="$NODE" -e NODE_IP=127.0.0.1 \
    --entrypoint /bin/sh "$(yq '.image' "$CONTAINER")" -c "$2; exec \"\$@\"" sh "${command[@]}"
}

# line CHECK MODE ATTEMPT RESULT EXPECTED: the line a check prints for an attempt.
line() {
  local verdict=ok
  [ "$4" = "$5" ] || verdict=UNEXPECTED
  echo "escape-canary $1 mode=$2 node=$NODE attempt=$3 result=$4 expected=$5 $verdict"
}

# no_address: fails when standard output or standard error of the last run holds an IPv4 literal,
# or the metadata address in any form, or a line of a tool's.
no_address() {
  if grep -nE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|169\.254|sent [0-9]|Error from server|server can.t find|Name:' <<<"$output"$'\n'"$stderr"; then
    echo "a check printed an address or a tool's line"
    return 1
  fi
}

@test "The escape canary is selected by overlay entries and builds nothing when it is not" {
  local entries ks dependency file key
  # The overlay selects it with two entries, the namespace directory and the application's ks.yaml.
  entries="$(yq '.resources[] | select(test("/escape-canary(/|$)"))' "$OVERLAY_DIR/kustomization.yaml" | paste -sd' ' -)"
  [ "$entries" = "../../base/escape-canary ../../base/escape-canary/escape-canary/ks.yaml" ]
  overlay
  [ "$(of_namespace "$OVERLAY")" = ConfigMap/escape-canary/app-template-defaults,Kustomization/flux-system/escape-canary,Namespace/-/escape-canary,NetworkPolicy/escape-canary/default-deny ]
  # The namespace directory holds what every namespace directory does: its namespace, its default
  # deny and the common component.
  [ "$(yq -o json -I0 '{"namespace": .namespace, "components": .components, "resources": .resources}' "$BASE/kustomization.yaml")" \
    = '{"namespace":"escape-canary","components":["../../../components/common"],"resources":["namespace.yaml","networkpolicy-default-deny.yaml"]}' ]
  # It waits for the definitions of its policies' and its rule's kinds, and for the Services it
  # attempts, so that a target not yet there is no result; it is Ready only once what it applies is,
  # and substitutes its mode alone.
  ks="$(object "$OVERLAY" Kustomization escape-canary | yq -o json -I0 '.spec')"
  [ "$(jq -c '.dependsOn | map(.name)' <<<"$ks")" = '["cilium","prometheus-operator-crds","hello","openbao"]' ]
  [ "$(jq -r '.wait' <<<"$ks")" = true ]
  [ "$(jq -r '.targetNamespace' <<<"$ks")" = "$NAMESPACE" ]
  [ "$(jq -r '.path' <<<"$ks")" = ./apps/base/escape-canary/escape-canary/app ]
  [ "$(jq -c '.postBuild.substitute | keys' <<<"$ks")" = '["ESCAPE_CANARY_MODE"]' ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # What the application builds, and nothing else.
  built escape-canary
  [ "$(yq -N '.kind + "/" + .metadata.name' "$BUILT" | LC_ALL=C sort | paste -sd' ' -)" \
    = "CiliumNetworkPolicy/escape-canary-resolver CiliumNetworkPolicy/escape-canary-rights-api-server ConfigMap/escape-canary-expected ConfigMap/escape-canary-scripts CronJob/escape-canary-network CronJob/escape-canary-rights PrometheusRule/escape-canary-alerts ServiceAccount/escape-canary-rights" ]
  # The table and the scripts, byte for byte, under names without a hash, which the jobs read afresh
  # at each run, and out of Flux's substitution.
  for file in expected.tsv scripts/network.sh scripts/rights.sh; do
    key="${file##*/}"
    case $key in
      expected.tsv) object "$BUILT" ConfigMap escape-canary-expected >"$BATS_TEST_TMPDIR/configmap.yaml" ;;
      *) object "$BUILT" ConfigMap escape-canary-scripts >"$BATS_TEST_TMPDIR/configmap.yaml" ;;
    esac
    KEY="$key" yq -o json '.data[strenv(KEY)]' "$BATS_TEST_TMPDIR/configmap.yaml" | jq -j . >"$BATS_TEST_TMPDIR/data"
    cmp "$BATS_TEST_TMPDIR/data" "$APP/app/$file"
    [ "$(yq '.metadata.annotations["kustomize.toolkit.fluxcd.io/substitute"]' "$BATS_TEST_TMPDIR/configmap.yaml")" = disabled ]
  done
  [ "$(object "$BUILT" ConfigMap escape-canary-expected | yq '.data | keys | join(" ")')" = expected.tsv ]
  [ "$(object "$BUILT" ConfigMap escape-canary-scripts | yq '.data | keys | join(" ")')" = "network.sh rights.sh" ]
  # With only the namespace directory's entry, the namespace, its defaults and its default deny.
  tree_without '/escape-canary/escape-canary/ks.yaml$'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ "$(of_namespace "$OVERLAY")" = ConfigMap/escape-canary/app-template-defaults,Namespace/-/escape-canary,NetworkPolicy/escape-canary/default-deny ]
  # With none, nothing of the namespace.
  tree_without '/escape-canary(/|$)'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ -z "$(of_namespace "$OVERLAY")" ]
  # Selecting it without what it names is refused, naming both.
  for dependency in kube-system/cilium kube-system/prometheus-operator-crds demo/hello openbao/openbao; do
    tree_without "/$dependency/ks.yaml\$"
    run "$REPO/scripts/kubernetes-check" "$TREE"
    echo "without ${dependency#*/}: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"kubernetes/apps/base/escape-canary/escape-canary/ks.yaml: Kustomization escape-canary names ${dependency#*/}"*"does not enable"* ]]
  done
}

@test "The canary's pods meet the restricted level with a read-only root, and only the rights job's pods hold a token" {
  local ns name pods namespaces
  built escape-canary
  overlay
  # The namespace, as the overlay builds it, enforces restricted, keeps what runs in it when it
  # leaves the tree, and no workload of it is excepted.
  ns="$(object "$OVERLAY" Namespace "$NAMESPACE" | yq -o json -I0 '.metadata')"
  [ "$(jq -cS '.labels' <<<"$ns")" = '{"pod-security.kubernetes.io/enforce":"restricted"}' ]
  [ "$(jq -r '.annotations["kustomize.toolkit.fluxcd.io/prune"]' <<<"$ns")" = disabled ]
  [ "$(NS="$NAMESPACE" yq '[.exceptions[] | select(.namespace == strenv(NS))] | length' "$REPO/pod-security-exceptions.yaml")" -eq 0 ]
  pods="$BATS_TEST_TMPDIR/pods.yaml"
  : >"$pods"
  for name in escape-canary-network escape-canary-rights; do
    workload "$name"
    restricted_failures "$POD" "$NAMESPACE"
    echo "$name: failed controls: $(paste -sd' ' "$CONTROLS") $(cat "$FORBIDDEN")"
    [ ! -s "$CONTROLS" ]
    [ "$(yq -o json -I0 '.spec.securityContext' "$POD" | jq -cS .)" \
      = '{"runAsGroup":65534,"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}}' ]
    [ "$(yq -o json -I0 '.securityContext' "$CONTAINER" | jq -cS .)" \
      = '{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}' ]
    [ "$(yq '.spec.enableServiceLinks' "$POD")" = false ]
    [ "$(yq '.spec | (.hostNetwork // false) or (.hostPID // false) or (.hostIPC // false) or (.hostUsers == false)' "$POD")" = false ]
    [ "$(yq -o json -I0 '.spec | [has("hostAliases"), has("dnsPolicy"), has("dnsConfig")]' "$POD")" = '[false,false,false]' ]
    # No volume projects a token: the one token is the rights pods', which the kubelet mounts.
    [ "$(yq '[.spec.volumes[] | select(.projected != null)] | length' "$POD")" -eq 0 ]
    # The pod as admission sees it, for the engines below.
    NAME="$name" yq -o json -I0 '{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": strenv(NAME), "namespace": "escape-canary",
      "labels": .metadata.labels}, "spec": .spec}' "$POD" | { echo ---; cat; } >>"$pods"
  done
  # The network pods: no token and no account of their own; busybox at the drill's check's figures;
  # the scripts and the table read-only, and nothing else.
  workload escape-canary-network
  [ "$(yq -o json -I0 '.spec | [.automountServiceAccountToken, .serviceAccountName // null]' "$POD")" = '[false,null]' ]
  [ "$(yq -o json -I0 '.resources' "$CONTAINER" | jq -cS .)" = '{"limits":{"memory":"32Mi"},"requests":{"cpu":"1m","memory":"8Mi"}}' ]
  [ "$(yq -o json -I0 '.resources' "$CONTAINER" | jq -cS .)" \
    = "$(yq -o json -I0 '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "check") | .resources' "$REPO/kubernetes/components/volsync-drill/cronjob.yaml" | jq -cS .)" ]
  [ "$(mounts "$POD")" = "$(printf '%s\n' "/scripts configMap escape-canary-scripts read-only" "/table configMap escape-canary-expected read-only" | LC_ALL=C sort)" ]
  # The rights pods: the account escape-canary-rights and its token, which they ask for, as the
  # account mounts none for a pod that does not; kubectl's figures; HOME in memory.
  workload escape-canary-rights
  [ "$(yq -o json -I0 '.spec | [.automountServiceAccountToken, .serviceAccountName]' "$POD")" = '[true,"escape-canary-rights"]' ]
  [ "$(object "$BUILT" ServiceAccount escape-canary-rights | yq -o json -I0 '{"token": .automountServiceAccountToken, "other": (del(.apiVersion, .kind, .metadata, .automountServiceAccountToken) | keys)}')" \
    = '{"token":false,"other":[]}' ]
  [ "$(yq -o json -I0 '.resources' "$CONTAINER" | jq -cS .)" = '{"limits":{"memory":"128Mi"},"requests":{"cpu":"10m","memory":"64Mi"}}' ]
  [ "$(mounts "$POD")" = "$(printf '%s\n' "/home/canary emptyDir Memory:16Mi writable" "/scripts configMap escape-canary-scripts read-only" \
    "/table configMap escape-canary-expected read-only" | LC_ALL=C sort)" ]
  [ "$(yq -o json -I0 '.env[] | select(.name == "HOME")' "$CONTAINER")" = '{"name":"HOME","value":"/home/canary"}' ]
  # Only the rights pods hold a token, of every pod the application makes.
  [ "$(yq -N 'select(.kind == "CronJob") | select(.spec.jobTemplate.spec.template.spec.automountServiceAccountToken != false) | .metadata.name' "$BUILT")" = escape-canary-rights ]
  # Both admission engines' rules, the tree's own, pass the pods in their namespace as the overlay
  # builds it; a pod there that breaks them fails them, so the pass is no engine finding nothing.
  namespaces="$BATS_TEST_TMPDIR/namespaces.yaml"
  object "$OVERLAY" Namespace "$NAMESPACE" >"$namespaces"
  admission "$pods" "$namespaces"
  echo "Kyverno: $KYVERNO_OUTPUT"
  echo "Gatekeeper: $GATEKEEPER_OUTPUT"
  [ "$KYVERNO_STATUS" -eq 0 ]
  [ "$GATEKEEPER_FINDINGS" = 0 ]
  printf '%s\n' --- 'apiVersion: v1' 'kind: Pod' 'metadata: {name: broken, namespace: escape-canary}' \
    'spec: {containers: [{name: broken, image: "registry.example/broken:latest"}]}' >>"$pods"
  admission "$pods" "$namespaces"
  [ "$KYVERNO_STATUS" -ne 0 ]
  [ "$GATEKEEPER_FINDINGS" != 0 ]
}

@test "Each run of a check starts three pods that only three different workers can take, and ends within its deadline" {
  local name check minute spec affinity other minutes tcp udp rights
  built escape-canary
  real_render
  for name in escape-canary-network:23 escape-canary-rights:10; do
    minute="${name#*:}" name="${name%:*}" check="${name#escape-canary-}"
    workload "$name"
    # Every hour at its minute in the cluster's UTC, as no CronJob of the tree sets timeZone; no
    # second run while one runs, started within 600 seconds of its time or skipped, one successful and
    # three failed jobs kept.
    spec="$(yq -o json -I0 '.spec | del(.jobTemplate)' "$WORKLOAD")"
    [ "$(jq -cS . <<<"$spec")" = "{\"concurrencyPolicy\":\"Forbid\",\"failedJobsHistoryLimit\":3,\"schedule\":\"$minute * * * *\",\"startingDeadlineSeconds\":600,\"successfulJobsHistoryLimit\":1}" ]
    # Three pods at once, one per index, no retry of a failed pod, which fails the Job, and an end
    # after 300 seconds.
    [ "$(yq -o json -I0 '.spec.jobTemplate.spec | del(.template)' "$WORKLOAD" | jq -cS .)" \
      = '{"activeDeadlineSeconds":300,"backoffLimit":0,"completionMode":"Indexed","completions":3,"parallelism":3}' ]
    [ "$(yq -o json -I0 '.metadata.labels' "$POD" | jq -cS .)" \
      = "{\"app.kubernetes.io/component\":\"$check\",\"app.kubernetes.io/name\":\"escape-canary\",\"k8s-gitops/escape-canary\":\"true\"}" ]
    [ "$(yq '.spec.restartPolicy' "$POD")" = Never ]
    # A worker each: no node that carries the control planes' label, and no node that runs a pod of
    # the same Job, by the pods' own labels and the Job's controller-uid, which the Job controller
    # gives its pods and the API server joins to the selector, so another Job's pods do not count.
    affinity="$(yq -o json -I0 '.spec.affinity' "$POD")"
    [ "$(jq -cS . <<<"$affinity")" = "$(jq -cnS --arg check "$check" '{
      "nodeAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": {"nodeSelectorTerms": [{"matchExpressions": [
        {"key": "node-role.kubernetes.io/control-plane", "operator": "DoesNotExist"}]}]}},
      "podAntiAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": [{
        "labelSelector": {"matchLabels": {"app.kubernetes.io/name": "escape-canary", "app.kubernetes.io/component": $check}},
        "matchLabelKeys": ["batch.kubernetes.io/controller-uid"],
        "topologyKey": "kubernetes.io/hostname"}]}}')" ]
    # The selector selects the pods' own labels.
    [ "$(yq -o json -I0 '.metadata.labels' "$POD" | jq -c --argjson affinity "$affinity" \
      '. as $labels | $affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].labelSelector.matchLabels | to_entries | all($labels[.key] == .value)')" = true ]
    # A minute of its own among every CronJob of the render.
    other="$(find "$REAL" -name 'CronJob.batch_*' ! -name "CronJob.batch_escape-canary_$name.yaml" -exec yq -N '.spec.schedule' {} + | awk '{ print $1 }')"
    echo "$name at minute $minute; the other CronJobs' minutes: $(paste -sd' ' <<<"$other")"
    if grep -qxE "0*$minute" <<<"$other"; then echo "$name shares its minute with another CronJob"; return 1; fi
  done
  minutes="$(find "$REAL" -name 'CronJob.batch_escape-canary_*' -exec yq -N '.spec.schedule' {} + | awk '{ print $1 }' | LC_ALL=C sort -n | paste -sd' ' -)"
  [ "$minutes" = "10 23" ]
  # Within the deadline: each attempt is bounded, a TCP attempt's connect by nc's 3 seconds, the
  # resolver's lookup by timeout's 5 and a rights attempt by timeout's 10 (tests of the checks), and
  # the run's 300 seconds holds every attempt of its check at its bound. The lookup of a name before
  # nc connects is bounded by the resolver's own timeouts alone, so a run whose resolver does not
  # answer may end at this deadline instead; with the 600 seconds the run may start late, it ends
  # before the next hour's.
  tcp="$(rows | awk -F'\t' '$2 == "network" && $4 ~ /\/tcp$/' | grep -c .)"
  udp="$(rows | awk -F'\t' '$2 == "network" && $4 ~ /\/udp$/' | grep -c .)"
  rights="$(rows | awk -F'\t' '$2 == "rights"' | grep -c .)"
  echo "network: $tcp TCP attempts and $udp lookups; rights: $rights attempts"
  ((tcp * 3 + udp * 5 < 300))
  ((rights * 10 < 300))
  ((300 + 600 < 3600))
}

@test "The canary's namespace denies traffic by default, its pods reach the resolver, the rights pods also the API server, and nothing else" {
  local deny flow want side from to port pod
  real_render
  # The namespace holds the default deny, every pod and both directions with no rule, and is not
  # listed among the namespaces without one.
  deny="$(rendered NetworkPolicy.networking.k8s.io_escape-canary_default-deny.yaml)"
  [ "$(yq -o json -I0 '[.metadata.name, .spec]' "$deny" | jq -cS .)" = '["default-deny",{"podSelector":{},"policyTypes":["Ingress","Egress"]}]' ]
  [ "$(NS="$NAMESPACE" yq '[.exceptions[] | select(.namespace == strenv(NS))] | length' "$REPO/network-policy-exceptions.yaml")" -eq 0 ]
  # The policies of the namespace are the default deny and the canary's two, nothing else.
  [ "$(cd "$REAL" && find . -type f -name '*Policy*_escape-canary_*' -printf '%f\n' | LC_ALL=C sort | paste -sd' ' -)" \
    = "CiliumNetworkPolicy.cilium.io_escape-canary_escape-canary-resolver.yaml CiliumNetworkPolicy.cilium.io_escape-canary_escape-canary-rights-api-server.yaml NetworkPolicy.networking.k8s.io_escape-canary_default-deny.yaml" ]
  # Every rule of the two, exactly: the resolver for every canary pod, the API server for the rights
  # pods, and no ingress.
  allows "$(rendered CiliumNetworkPolicy.cilium.io_escape-canary_escape-canary-resolver.yaml)" \
    "$(rendered CiliumNetworkPolicy.cilium.io_escape-canary_escape-canary-rights-api-server.yaml)"
  [ "$(allows "$(rendered CiliumNetworkPolicy.cilium.io_escape-canary_escape-canary-resolver.yaml)" \
    "$(rendered CiliumNetworkPolicy.cilium.io_escape-canary_escape-canary-rights-api-server.yaml)")" = "$(printf '%s\n' \
    "escape-canary-resolver [k8s-gitops/escape-canary=true] sends to io.kubernetes.pod.namespace=kube-system,k8s-app=kube-dns on 53/TCP+53/UDP" \
    "escape-canary-rights-api-server [app.kubernetes.io/component=rights,app.kubernetes.io/name=escape-canary] sends to @kube-apiserver on 443/TCP+6443/TCP" |
    LC_ALL=C sort)" ]
  # The flows, evaluated on the render as Cilium decides them, over every policy of every namespace.
  local flows=(
    # The network pods: the resolver, and nothing else.
    "reaches --reach $NETWORK $DNS 53/udp"
    "reaches --reach $NETWORK $DNS 53/tcp"
    "refused --reach $NETWORK $DNS 9153/tcp"
    "refused --reach $NETWORK @kube-apiserver 443/tcp"
    "refused --reach $NETWORK @kube-apiserver 6443/tcp"
    "refused --reach $NETWORK @world 80/tcp"
    "refused --reach $NETWORK @world 443/tcp"
    "refused --reach $NETWORK @world 53/udp"
    "refused --reach $NETWORK @host 10250/tcp"
    "refused --reach $NETWORK @host 50000/tcp"
    "refused --reach $NETWORK @remote-node 10250/tcp"
    "refused --reach $NETWORK @remote-node 50000/tcp"
    "refused --reach $NETWORK $HELLO 8080/tcp"
    "refused --reach $NETWORK $OPENBAO 8200/tcp"
    "refused --reach $NETWORK $PROXY 10443/tcp"
    "refused --reach $NETWORK $PROMETHEUS 9090/tcp"
    "refused --reach $NETWORK $OTHER_APP 8080/tcp"
    "refused --reach $NETWORK $RIGHTS 8080/tcp"
    # The rights pods: the resolver and the API server, and nothing else.
    "reaches --reach $RIGHTS $DNS 53/udp"
    "reaches --reach $RIGHTS $DNS 53/tcp"
    "reaches --reach $RIGHTS @kube-apiserver 443/tcp"
    "reaches --reach $RIGHTS @kube-apiserver 6443/tcp"
    "refused --reach $RIGHTS @kube-apiserver 10250/tcp"
    "refused --reach $RIGHTS $DNS 9153/tcp"
    "refused --reach $RIGHTS @world 443/tcp"
    "refused --reach $RIGHTS @world 80/tcp"
    "refused --reach $RIGHTS @host 10250/tcp"
    "refused --reach $RIGHTS @host 50000/tcp"
    "refused --reach $RIGHTS @remote-node 10250/tcp"
    "refused --reach $RIGHTS $HELLO 8080/tcp"
    "refused --reach $RIGHTS $OPENBAO 8200/tcp"
    "refused --reach $RIGHTS $PROXY 10443/tcp"
    "refused --reach $RIGHTS $OTHER_APP 8080/tcp"
    "refused --reach $RIGHTS $NETWORK 8080/tcp"
    # A pod of the namespace without the canary's labels reaches nothing.
    "refused --reach $STRAY $DNS 53/udp"
    "refused --reach $STRAY @kube-apiserver 6443/tcp"
    "refused --reach $STRAY @world 443/tcp"
  )
  for flow in "${flows[@]}"; do
    read -r want side from to port <<<"$flow"
    "$want" "$side" "$from" "$to" "$port"
  done
  # Nothing reaches a pod of the canary.
  for pod in "$NETWORK" "$RIGHTS"; do
    for flow in "@host 8080/tcp" "@remote-node 8080/tcp" "@world 443/tcp" "$HELLO 8080/tcp" "$PROXY 8080/tcp" "$PROMETHEUS 8080/tcp" \
      "$OTHER_APP 8080/tcp" "$STRAY 8080/tcp"; do
      read -r from port <<<"$flow"
      refused --reach-ingress "$from" "$pod" "$port"
    done
  done
  refused --reach-ingress "$RIGHTS" "$NETWORK" 8080/tcp
}

@test "The table gives every attempt a result for each mode, and its enforcement column is what the policies of the render allow" {
  local column attempt check target port reach audit enforce reason dom apiport deny service selector svcport tport workloads from answered=()
  real_render
  # The header says what each column holds and which results there are.
  for column in attempt check target port reach audit enforce reason; do
    grep -qE "^#   $column  " "$TABLE" || { echo "the table's header does not say what the column $column holds"; return 1; }
  done
  for column in $RESULTS; do
    grep -qE "^#.*\\b$column\\b" "$TABLE" || { echo "the table's header does not name the result $column"; return 1; }
  done
  # The rows, in order, each of eight fields of which none is empty.
  [ "$(rows | cut -f1 | paste -sd' ' -)" = "$ATTEMPTS" ]
  [ -z "$(rows | awk -F'\t' 'NF != 8 { print NR }')" ]
  [ -z "$(rows | awk -F'\t' '{ for (i = 1; i <= NF; i++) if ($i == "") print NR }')" ]
  dom="$(domain)"
  [ "$dom" = cluster.local ]
  # The API server's port behind the Service kubernetes, its listener's in the node firewall.
  apiport="$(yq '.listeners[] | select(.name == "kube-apiserver") | .ports | join(" ")' "$REPO/talos/firewall.yaml")"
  [ "$apiport" = 6443 ]
  # A denied attempt is blocked, and not refused, as the agents answer a packet a policy denies with
  # nothing.
  deny="$(yq '.data["policy-deny-response"] // "not set"' "$(rendered ConfigMap_kube-system_cilium-config.yaml)")"
  [ "$deny" = none ] ||
    { echo "the rendered cilium-config sets policy-deny-response to $deny, and the enforcement column's blocked needs none"; return 1; }
  while IFS=$'\t' read -r attempt check target port reach audit enforce reason; do
    echo "$attempt: $check $target $port as [$reach]: $audit, $enforce"
    [[ " $RESULTS " == *" $audit "* && " $RESULTS " == *" $enforce "* ]] || { echo "$attempt: a result the table may not give"; return 1; }
    [ -n "$reason" ]
    case $attempt in
      resolver)
        [ "$check $target $port $reach" = "network kubernetes.default.svc.$dom 53/udp $DNS 53/udp" ] ;;
      metadata)
        [ "$check $target $port $reach" = "network 169.254.169.254 80/tcp @world 80/tcp" ] ;;
      kubelet | talos-api)
        [[ $port =~ ^[0-9]+/tcp$ ]]
        [ "$check $target $reach" = "network node @host $port" ] ;;
      api-server)
        [ "$check $target $port $reach" = "network kubernetes.default.svc.$dom 443/tcp @kube-apiserver $apiport/tcp" ] ;;
      hello | secret-store)
        # A Service by its name of the cluster's domain, on a port the render gives it; the reach is
        # the workload of the render whose pods the Service selects, on the container port the port
        # targets.
        [ "$check" = network ]
        [[ $target =~ ^([a-z0-9-]+)\.([a-z0-9-]+)\.svc\.${dom//./\\.}$ && $port =~ ^([0-9]+)/tcp$ ]]
        svcport="${port%/tcp}"
        [[ $target =~ ^([a-z0-9-]+)\.([a-z0-9-]+)\. ]]
        service="$(rendered "Service_${BASH_REMATCH[2]}_${BASH_REMATCH[1]}.yaml")"
        selector="$(yq -o json -I0 '.spec.selector // {}' "$service")"
        [ "$(jq length <<<"$selector")" -gt 0 ]
        tport="$(P="$svcport" yq '.spec.ports[] | select(.port == env(P)) | .targetPort // .port' "$service")"
        [ -n "$tport" ]
        workloads="$(yq -o json -I0 '.' "$VIEW"/*/*/*.yaml | NS="$(yq '.metadata.namespace' "$service")" jq -c --argjson selector "$selector" '
          select(.metadata.namespace == env.NS and (.kind | IN("Deployment", "StatefulSet", "DaemonSet")))
          | select(.spec.template.metadata.labels as $labels | $selector | to_entries | all($labels[.key] == .value))')"
        [ "$(grep -c . <<<"$workloads")" -eq 1 ]
        tport="$(jq -r --arg port "$tport" '[.spec.template.spec.containers[] | (.ports // [])[]
          | select(.name == $port or (.containerPort | tostring) == $port) | .containerPort] | unique | join(" ")' <<<"$workloads")"
        [[ $tport =~ ^[0-9]+$ ]]
        [ "$reach" = "$(jq -r '.metadata.namespace + "/" + .kind + "/" + .metadata.name' <<<"$workloads") $tport/tcp" ] ;;
      read-secret | list-pods)
        [ "$check $target $port $reach" = "rights - - @kube-apiserver $apiport/tcp" ] ;;
    esac
    # The enforcement column is what the policies allow, from the CronJob of the row's check: denied
    # exactly where it says blocked.
    from="escape-canary/CronJob/escape-canary-$check"
    read -r -a reach <<<"$reach"
    run "$REPO/scripts/network-policy-check" --reach "$VIEW" "$from" "${reach[0]}" "${reach[1]}"
    echo "  $output"
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ] || { echo "$attempt: the evaluator gives no answer for its reach"; return 1; }
    if [ "$enforce" = blocked ]; then
      [ "$status" -eq 1 ] || { echo "$attempt: the policies allow it, and the table says blocked once Cilium enforces"; return 1; }
    else
      [ "$status" -eq 0 ] || { echo "$attempt: the policies deny it, and the table says $enforce once Cilium enforces"; return 1; }
    fi
    answered+=("$attempt")
  done < <(rows)
  [ "${answered[*]}" = "$ATTEMPTS" ]
  # The docs' table of the attempts is this one: each attempt, its reach and its two results.
  # shellcheck disable=SC2016 # The backticks are the docs' own.
  [ "$(section '### The escape canary' | grep -E '^  \| `[a-z-]+` \|' |
    sed -E 's/^  \| `([a-z-]+)` \| `([^`]+)` \| ([a-z]+) \| ([a-z]+) \|$/\1\t\2\t\3\t\4/')" = "$(rows | cut -f1,5,6,7)" ]
}

@test "The table's audit column for the pod's own node follows the node firewall, and nothing else is blocked while Cilium audits" {
  local attempt check target port reach audit enforce reason listener want nodes=()
  # A node drops what no rule admits.
  [ "$(yq -N 'select(.kind == "NetworkDefaultActionConfig") | .ingress' "$REPO/talos/patches/all/firewall.yaml")" = block ]
  while IFS=$'\t' read -r attempt check target port reach audit enforce reason; do
    if [ "$target" = node ]; then
      # A pod reaches its own node by its pod address, the source pods of the listener on the port.
      [[ $port =~ ^([0-9]+)/tcp$ ]]
      listener="$(yq -o json '.listeners' "$REPO/talos/firewall.yaml" | jq -c --argjson p "${BASH_REMATCH[1]}" '.[]
        | select(.protocol == "tcp")
        | select(any(.ports[]; (tostring | split("-") | map(tonumber)) as $r | $p >= $r[0] and $p <= $r[-1]))')"
      if [ -n "$listener" ] && [ "$(jq '.from | index("pods") != null' <<<"$listener")" = true ]; then want=open; else want=blocked; fi
      echo "$attempt: the listener on $port is $(jq -c '{name, from}' <<<"${listener:-null}"), so $want while Cilium audits"
      [ "$audit" = "$want" ] || { echo "$attempt: the table says $audit while Cilium audits, and the node firewall gives $want"; return 1; }
      nodes+=("$attempt")
    else
      # The agents drop nothing a policy denies at layers 3 and 4 while they audit.
      [ "$audit" != blocked ] || { echo "$attempt: blocked while Cilium audits, which drops nothing"; return 1; }
    fi
  done < <(rows)
  [ "${nodes[*]}" = "kubelet talos-api" ]
  [ "$(field kubelet 6) $(field talos-api 6)" = "open blocked" ]
}

@test "The canary's mode follows Cilium's audit setting in the render" {
  local mode audit want name
  real_render
  mode="$(yq '.spec.postBuild.substitute.ESCAPE_CANARY_MODE' "$APP/ks.yaml")"
  audit="$(yq '.data["policy-audit-mode"] // ""' "$(rendered ConfigMap_kube-system_cilium-config.yaml)")"
  if [ "$audit" = true ]; then want=audit; else want=enforce; fi
  echo "cilium-config's policy-audit-mode: ${audit:-not set}; the canary's mode: $mode"
  [ "$mode" = "$want" ] ||
    { echo "the rendered cilium-config $([ "$audit" = true ] && echo holds || echo does not hold) policy-audit-mode \"true\": set ESCAPE_CANARY_MODE: $want in kubernetes/apps/base/escape-canary/escape-canary/ks.yaml"; return 1; }
  # Both CronJobs take it, as the build substitutes it.
  built escape-canary
  for name in escape-canary-network escape-canary-rights; do
    # shellcheck disable=SC2016 # The variable is Flux's to substitute.
    [ "$(yq '.spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == "CANARY_MODE") | .value' "$APP/app/cronjob-${name#escape-canary-}.yaml")" = '${ESCAPE_CANARY_MODE}' ]
    workload "$name"
    [ "$(yq -o json -I0 '.env[] | select(.name == "CANARY_MODE")' "$CONTAINER")" = "{\"name\":\"CANARY_MODE\",\"value\":\"$mode\"}" ]
  done
  # The step that makes the cluster enforce sets the mode in the same pull request, and the step
  # back reverses each of its edits.
  # shellcheck disable=SC2016 # The backticks are the docs' own.
  [[ $(step 4) == *'`kubernetes/apps/base/escape-canary/escape-canary/ks.yaml`: `ESCAPE_CANARY_MODE: audit` becomes `ESCAPE_CANARY_MODE: enforce`'* ]]
  [[ $(step 5) == *"reverses each edit of step 4"* ]]
}

@test "A check exits zero only when every result is the table's for its mode, prints one line for each attempt and names no address" {
  local check mode attempt column expected changed lines want got n docker_dir table
  standins
  # Each check runs as the build's CronJob runs it: its command, the scripts and the table from the
  # ConfigMaps its container mounts, and its variables, the node's from the downward API.
  built escape-canary
  as_run network
  as_run rights
  for check in network rights; do
    for mode in audit enforce; do
      [ "$mode" = audit ] && column=6 || column=7
      # Every result as the table gives it: one line for each attempt of the check, in its order, the
      # summary, and 0.
      check "$check" "$mode"
      echo "$check, $mode: $status: $output $stderr"
      [ "$status" -eq 0 ]
      [ -z "$stderr" ]
      want=""
      n=0
      for attempt in $ATTEMPTS; do
        [ "$(field "$attempt" 2)" = "$check" ] || continue
        want+="$(line "$check" "$mode" "$attempt" "$(field "$attempt" "$column")" "$(field "$attempt" "$column")")"$'\n'
        n=$((n + 1))
      done
      want+="escape-canary $check mode=$mode node=$NODE attempts=$n unexpected=0 ok"
      [ "$output" = "$want" ]
      no_address
      # The calls, in the table's order, exactly so.
      if [ "$check" = network ]; then
        [ "$(cat "$CALLS")" = "$(printf '%s\n' "timeout 5 nslookup kubernetes.default.svc.cluster.local" "nslookup kubernetes.default.svc.cluster.local" \
          "nc -z -v -v -w 3 169.254.169.254 80" "nc -z -v -v -w 3 $NODE_IP 10250" "nc -z -v -v -w 3 $NODE_IP 50000" \
          "nc -z -v -v -w 3 kubernetes.default.svc.cluster.local 443" "nc -z -v -v -w 3 hello.demo.svc.cluster.local 80" \
          "nc -z -v -v -w 3 openbao.openbao.svc.cluster.local 8200")" ]
      else
        # kubectl takes the pod's in-cluster configuration only while no flag changes its client
        # configuration (client-go's tools/clientcmd/merged_client_builder.go): no --request-timeout,
        # --server or --token, and timeout bounds the call instead.
        [ "$(cat "$CALLS")" = "$(printf '%s\n' "timeout -s KILL 10 kubectl get secret cluster-secrets --namespace flux-system --output name" \
          "kubectl get secret cluster-secrets --namespace flux-system --output name" \
          "timeout -s KILL 10 kubectl get pods --all-namespaces --output name" "kubectl get pods --all-namespaces --output name")" ]
      fi
      # One result changed at a time: that line is UNEXPECTED, the others ok, and the check exits 1.
      for attempt in $ATTEMPTS; do
        [ "$(field "$attempt" 2)" = "$check" ] || continue
        expected="$(field "$attempt" "$column")"
        case $expected in
          open) changed=blocked ;;
          forbidden) changed=allowed ;;
          *) changed=open ;;
        esac
        # kubectl's stand-in gives no open.
        [ "$check" = network ] || [ "$changed" != open ] || changed=allowed
        check "$check" "$mode" "$attempt" "$changed"
        echo "$check, $mode, $attempt $changed: $status: $output $stderr"
        [ "$status" -eq 1 ]
        [ -z "$stderr" ]
        grep -qxF "$(line "$check" "$mode" "$attempt" "$changed" "$expected")" <<<"$output"
        [ "$(grep -c ' UNEXPECTED$' <<<"$output")" -eq 2 ]
        [ "$(tail -n 1 <<<"$output")" = "escape-canary $check mode=$mode node=$NODE attempts=$n unexpected=1 UNEXPECTED" ]
        [ "$(grep -c ' ok$' <<<"$output")" -eq $((n - 1)) ]
        no_address
      done
    done
  done
  # Each message of the tools gives its result: nc's open, refused, timed out, bad address and
  # anything else; nslookup's answer, its NXDOMAIN, a refusal, no answer within the bound and
  # anything else; kubectl's success, its refusal by the API server, no answer within the bound and
  # anything else.
  for got in open refused blocked unresolved other; do
    check network audit hello "$got"
    grep -qF "attempt=hello result=$got " <<<"$output"
    no_address
  done
  for got in open unresolved refused blocked other; do
    check network audit resolver "$got"
    grep -qF "attempt=resolver result=$got " <<<"$output"
    no_address
  done
  # nslookup's answer with no address exits 0, and the name is unresolved all the same.
  check network audit resolver empty
  echo "network, audit, resolver empty: $status: $output $stderr"
  [ "$status" -eq 1 ]
  grep -qxF "$(line network audit resolver unresolved open)" <<<"$output"
  no_address
  for got in allowed forbidden blocked other; do
    check rights audit read-secret "$got"
    grep -qF "attempt=read-secret result=$got " <<<"$output"
    no_address
  done
  # A mode it does not know, a table it cannot read and a table with no row of the check: 2, the
  # reason on standard error, no attempt made.
  for check in network rights; do
    check "$check" permissive
    echo "$check, unknown mode: $status: $output | $stderr"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ $stderr == "escape-canary $check error: "*"permissive"* ]]
    [ ! -s "$CALLS" ]
    TABLE_OVERRIDE="$BATS_TEST_TMPDIR/no-such-table.tsv" check "$check" audit
    echo "$check, no table: $status: $output | $stderr"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ $stderr == "escape-canary $check error: "* ]]
    [ ! -s "$CALLS" ]
    grep -v $'\t'"$check"$'\t' "$TABLE" >"$BATS_TEST_TMPDIR/other-rows.tsv"
    TABLE_OVERRIDE="$BATS_TEST_TMPDIR/other-rows.tsv" check "$check" audit
    echo "$check, no row: $status: $output | $stderr"
    [ "$status" -eq 2 ]
    [[ $stderr == "escape-canary $check error: "* ]]
    [ ! -s "$CALLS" ]
    no_address
  done
  # Where a docker daemon answers, each check in its own image, as its container runs it, with the
  # image's own sh, timeout and tools against what the container's loopback holds. network.sh in
  # busybox: its nc gives open for a listener, by its address, by the node's and by a name the
  # resolver there answers, refused for a closed port, blocked for a listener whose queue is full,
  # which completes no handshake, and unresolved for a name the resolver does not know, as its
  # nslookup does, which gives blocked for a resolver that never answers and refused for none.
  # rights.sh in the Flux CLI image: a kubectl that never answers gives blocked once timeout kills
  # it. Each check prints its lines and nothing else, though its shell reports a command a signal
  # ended, and a result not the table's fails it. Port 53 is the resolver's, so the containers that
  # serve it let user 65534 bind a low port of their own network.
  if ! type -P docker >/dev/null || ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    echo "no docker daemon answers: the checks were not run in their images"
    return 0
  fi
  for check in network rights; do
    workload "escape-canary-$check"
    docker image inspect "$(yq '.image' "$CONTAINER")" >/dev/null 2>&1 || docker pull --quiet "$(yq '.image' "$CONTAINER")" >/dev/null
  done
  docker_dir="$BATS_TEST_TMPDIR/images"
  mkdir -p "$docker_dir/standin"
  printf 'nameserver 127.0.0.1\n' >"$docker_dir/resolv.conf"
  printf 'listener.canary.test 127.0.0.1\n' >"$docker_dir/dnsd.conf"
  printf '#!/bin/sh\nexec sleep 60\n' >"$docker_dir/standin/kubectl"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    loopback network 127.0.0.1 9000/tcp - open open "a listener on the loopback" \
    closed network 127.0.0.1 9001/tcp - refused refused "nothing listens" \
    own-node network node 9000/tcp - open open "the listener, by the node's address" \
    by-name network listener.canary.test 9000/tcp - open open "the listener, by a name the resolver answers" \
    full network 127.0.0.1 9002/tcp - blocked blocked "a listener whose queue is full" \
    no-name network missing.canary.test 9000/tcp - unresolved unresolved "a name the resolver does not know" \
    lookup-missing network missing.canary.test 53/udp - unresolved unresolved "a name the resolver does not know" >"$docker_dir/answers.tsv"
  sed 's/\topen\topen\t/\trefused\trefused\t/' "$docker_dir/answers.tsv" >"$docker_dir/wrong.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    lookup-silent network listener.canary.test 53/udp - blocked blocked "a resolver that never answers" >"$docker_dir/silent.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    lookup-none network listener.canary.test 53/udp - refused refused "no resolver" >"$docker_dir/none.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    read-secret rights - - - blocked blocked "kubectl gets no answer" \
    list-pods rights - - - blocked blocked "kubectl gets no answer" >"$docker_dir/rights.tsv"
  chmod -R a+rX "$docker_dir"
  chmod a+x "$docker_dir/standin/kubectl"
  local resolver=(--sysctl net.ipv4.ip_unprivileged_port_start=0 -v "$docker_dir/resolv.conf:/etc/resolv.conf:ro")
  # dnsd answers the one name of its file and nothing else; tcpsvd takes one connection at a time and
  # queues one more, which the two clients before the check fill. A client that connects while the
  # other still waits in the queue finds it full and gets in only at its next SYN, so the check
  # starts once port 9002, 232A in /proc/net/tcp, holds two connections the listener's side has
  # established, the one tcpsvd took and the one queued, or after 10 seconds. udpsvd hands each
  # client to a program that never answers.
  # shellcheck disable=SC2016 # The container's sh expands them.
  local full='n=0; until [ "$(grep -cE "^ *[0-9]+: 0100007F:232A 0100007F:[0-9A-F]{4} 01 " /proc/net/tcp)" -ge 2 ] || [ "$n" -ge 10 ]; do n=$((n + 1)); sleep 1; done'
  local answers="dnsd -c /conf/dnsd.conf -i 127.0.0.1 -p 53 >/dev/null 2>&1 & httpd -p 127.0.0.1:9000 -h /
    tcpsvd -c 1 -b 0 127.0.0.1 9002 sleep 60 >/dev/null 2>&1 & sleep 1
    sleep 30 | nc 127.0.0.1 9002 >/dev/null 2>&1 & sleep 30 | nc 127.0.0.1 9002 >/dev/null 2>&1 & $full"
  for table in answers wrong; do
    in_image network "$answers" "$docker_dir/$table.tsv" "${resolver[@]}" -v "$docker_dir/dnsd.conf:/conf/dnsd.conf:ro"
    echo "busybox, $table: $status: $output | $stderr"
    if [ "$table" = answers ]; then
      [ "$status" -eq 0 ]
      [ "$output" = "$(printf '%s\n' "$(line network audit loopback open open)" "$(line network audit closed refused refused)" \
        "$(line network audit own-node open open)" "$(line network audit by-name open open)" "$(line network audit full blocked blocked)" \
        "$(line network audit no-name unresolved unresolved)" "$(line network audit lookup-missing unresolved unresolved)" \
        "escape-canary network mode=audit node=$NODE attempts=7 unexpected=0 ok")" ]
    else
      [ "$status" -eq 1 ]
      [ "$output" = "$(printf '%s\n' "$(line network audit loopback open refused)" "$(line network audit closed refused refused)" \
        "$(line network audit own-node open refused)" "$(line network audit by-name open refused)" "$(line network audit full blocked blocked)" \
        "$(line network audit no-name unresolved unresolved)" "$(line network audit lookup-missing unresolved unresolved)" \
        "escape-canary network mode=audit node=$NODE attempts=7 unexpected=3 UNEXPECTED")" ]
    fi
    [ -z "$stderr" ]
    no_address
  done
  in_image network "udpsvd 127.0.0.1 53 sleep 60 >/dev/null 2>&1 & sleep 1" "$docker_dir/silent.tsv" "${resolver[@]}"
  echo "busybox, a silent resolver: $status: $output | $stderr"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "$(line network audit lookup-silent blocked blocked)" "escape-canary network mode=audit node=$NODE attempts=1 unexpected=0 ok")" ]
  [ -z "$stderr" ]
  no_address
  in_image network : "$docker_dir/none.tsv" "${resolver[@]}"
  echo "busybox, no resolver: $status: $output | $stderr"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "$(line network audit lookup-none refused refused)" "escape-canary network mode=audit node=$NODE attempts=1 unexpected=0 ok")" ]
  [ -z "$stderr" ]
  no_address
  in_image rights : "$docker_dir/rights.tsv" -v "$docker_dir/standin:/standin:ro" \
    -e PATH=/standin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  echo "the Flux CLI image, a kubectl that never answers: $status: $output | $stderr"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "$(line rights audit read-secret blocked blocked)" "$(line rights audit list-pods blocked blocked)" \
    "escape-canary rights mode=audit node=$NODE attempts=2 unexpected=0 ok")" ]
  [ -z "$stderr" ]
  no_address
}

@test "The rights job's account is bound to nothing in the tree" {
  local bindings named
  built escape-canary
  [ -z "$(yq -N 'select(.kind | test("^(Cluster)?Role(Binding)?$")) | .kind + "/" + .metadata.name' "$BUILT")" ]
  # Every binding of the render, which holds every application's build and every chart's objects as
  # Flux applies them, of a namespace or of the cluster: none names the account, by itself, by its
  # user name, or by a group it is in, its namespace's accounts, every account or every caller the
  # API server authenticates.
  real_render
  bindings="$BATS_TEST_TMPDIR/bindings.jsonl"
  find "$REAL" \( -name 'RoleBinding.rbac.authorization.k8s.io_*' -o -name 'ClusterRoleBinding.rbac.authorization.k8s.io_*' \) -print0 |
    xargs -0 yq -N -o json -I0 'select(. != null)' >"$bindings"
  echo "bindings of the render: $(grep -c . "$bindings")"
  [ "$(grep -c . "$bindings")" -gt 50 ]
  named="$(jq -r '. as $binding | select(any(.subjects[]?;
      (.kind == "ServiceAccount" and .name == "escape-canary-rights" and (.namespace // $binding.metadata.namespace) == "escape-canary")
      or (.kind == "User" and .name == "system:serviceaccount:escape-canary:escape-canary-rights")
      or (.kind == "Group" and (.name | IN("system:serviceaccounts:escape-canary", "system:serviceaccounts", "system:authenticated")))))
    | .kind + "/" + (.metadata.namespace // "-") + "/" + .metadata.name' "$bindings" | LC_ALL=C sort | paste -sd, -)"
  [ -z "$named" ] || { echo "a binding of the render names the canary's account or a group it is in: $named"; return 1; }
}

@test "The canary's images are pinned by tag and digest, and its kubectl is the Flux CLI of the repository's pin" {
  local image tag flux guard rules
  built escape-canary
  # The two CronJobs make every pod of the application, one container each and nothing else.
  [ "$(yq -N 'select(.spec.template != null or .spec.jobTemplate != null or .kind == "Pod") | .kind + "/" + .metadata.name' "$BUILT" | LC_ALL=C sort | paste -sd' ' -)" \
    = "CronJob/escape-canary-network CronJob/escape-canary-rights" ]
  workload escape-canary-network
  [ "$(yq '.spec | (.initContainers // []) + (.ephemeralContainers // []) | length' "$POD")" -eq 0 ]
  [ "$(yq '.name' "$CONTAINER")" = network ]
  image="$(yq '.image' "$CONTAINER")"
  echo "the network check runs $image"
  [[ $image =~ ^docker\.io/library/busybox:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]
  # The busybox of the drill's check and Robot's report server, by the same reference.
  [ "$image" = "$(yq '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "check") | .image' "$REPO/kubernetes/components/volsync-drill/cronjob.yaml")" ]
  workload escape-canary-rights
  [ "$(yq '.spec | (.initContainers // []) + (.ephemeralContainers // []) | length' "$POD")" -eq 0 ]
  [ "$(yq '.name' "$CONTAINER")" = kubectl ]
  image="$(yq '.image' "$CONTAINER")"
  echo "the rights check runs $image"
  [[ $image =~ ^ghcr\.io/fluxcd/flux-cli:(v[0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$ ]]
  tag="${BASH_REMATCH[1]}"
  # The Flux CLI of the repository's pin, the image OpenBao's guard runs.
  flux="$(sed -nE 's/^flux2 = "([^"]+)"$/\1/p' "$REPO/mise.toml")"
  echo "its tag: $tag; the repository's flux2 pin: ${flux:-none}"
  [ "$tag" = "v$flux" ]
  guard="$(yq '.server.extraInitContainers[] | select(.name == "initialize-guard") | .image' "$REPO/kubernetes/apps/base/openbao/openbao/app/values.yaml")"
  [ "$image" = "$guard" ]
  # Renovate's kubernetes manager reads both from the manifests, as it reads every plain manifest's
  # image, and no custom manager does: the files hold no comment of Renovate's.
  [ "$(awk -F'\t' '$1 ~ /^kubernetes\/apps\/base\/escape-canary\//' "$REPO/.renovate/extracted.tsv")" = "$(printf '%s\t%s\t%s\t%s\n' \
    kubernetes/apps/base/escape-canary/escape-canary/app/cronjob-network.yaml kubernetes docker.io/library/busybox - \
    kubernetes/apps/base/escape-canary/escape-canary/app/cronjob-rights.yaml kubernetes ghcr.io/fluxcd/flux-cli -)" ]
  [ -z "$(grep -rn 'renovate' "$BASE" || true)" ]
  # The Flux group moves the image with the flux2 pin, in one pull request.
  rules="$(grep -v '^[[:space:]]*//' "$REPO/.renovate/groups.json5" | yq -o json -I0 '.packageRules')"
  [ "$(jq -c '[.[] | select((.matchPackageNames // []) | index("ghcr.io/fluxcd/flux-cli")) | {groupName, matchPackageNames}]' <<<"$rules")" \
    = '[{"groupName":"Flux","matchPackageNames":["fluxcd/flux2","ghcr.io/fluxcd/flux-cli"]}]' ]
}

@test "Falco keeps the canary's attempts in its record" {
  local values="$REPO/kubernetes/apps/base/security-system/falco/app/values.yaml" items entry condition conjunction tuning
  items="$BATS_TEST_TMPDIR/items.yaml"
  yq '.customRules["exceptions.yaml"]' "$values" >"$items"
  [ "$(yq 'length' "$items")" -gt 0 ]
  # No item names the canary.
  [ -z "$(yq '.customRules' "$values" | grep -n 'escape-canary' || true)" ]
  # Each item is one conjunction in parentheses, after the or of an append, as tests/falco.bats holds:
  # within it, its values and sets aside, no parenthesis, no or, and no not but the one before the
  # macro container, so a clause it holds bounds every event it excepts. Every item but the one for
  # what Falco places in no container holds an event to namespaces it names, by k8s.ns.name = or in,
  # among which the canary's is not, so no item excepts its attempts. The namespace clause is read
  # with the single-quoted values set aside, as a clause written inside one is a value and bounds
  # nothing.
  local bare
  while IFS= read -r entry; do
    condition="$(jq -r '.condition' <<<"$entry")"
    conjunction="$condition"
    [ "$(jq -r '.override.condition' <<<"$entry")" = replace ] || conjunction="${conjunction#or }"
    [[ $conjunction == "("*")" ]] || { echo "an item is not one conjunction in parentheses: $condition"; return 1; }
    conjunction="$(sed -E 's/"[^"]*"/""/g; s/ in \([^()]*\)/ in set/g' <<<"${conjunction:1:${#conjunction}-2}")"
    [[ $conjunction != *[\(\)]* && " $conjunction " != *" or "* ]] || { echo "an item holds more than one conjunction: $condition"; return 1; }
    [[ " ${conjunction#not container and } " != *" not "* ]] || { echo "an item negates more than the macro container: $condition"; return 1; }
    if [[ $condition == "(not container and "* ]]; then continue; fi
    # Double-quoted values are kept whole, so a quote of either kind inside the other's value stays
    # part of that value.
    bare="$(sed -E "s/(\"[^\"]*\")|'[^']*'/\\1/g" <<<"$condition")"
    [[ $bare =~ k8s\.ns\.name\ (=\ \"[a-z0-9-]+\"|in\ \(\"[a-z0-9-]+\"(,\ \"[a-z0-9-]+\")*\)) ]] ||
      { echo "an item holds no event to the namespaces it names: $condition"; return 1; }
    [[ ${BASH_REMATCH[1]} != *'"escape-canary"'* ]] || { echo "an item excepts the canary: $condition"; return 1; }
  done < <(yq -o json -I0 '.[]' "$items")
  # The canary's nc never runs with -e or -c, which the image's rule Netcat Remote Code Execution in
  # Container matches in its command line.
  standins
  built escape-canary
  as_run network
  check network audit
  [ "$status" -eq 0 ]
  [ -z "$(grep -E '^nc .* -(e|c)( |$)' "$CALLS" || true)" ]
  [ -z "$(grep -E '^nc ' "$CALLS" | grep -E ' -[a-z]*[ec]' || true)" ]
  # The docs' tuning section says which rule the attempts raise, at what priority, how often and how
  # to find them.
  tuning="$(section '### Tuning' | flat)"
  # shellcheck disable=SC2016 # The backticks are the docs' own.
  [[ $tuning == *'The escape canary'*'`Contact K8S API Server From Container`'*'Notice'*'an hour'*'`output_fields."k8s.ns.name"`'*'`escape-canary`'* ]]
}
