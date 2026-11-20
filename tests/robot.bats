#!/usr/bin/env bats
# Proves features/robot.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq, jq, kyverno, git and just on PATH (the versions pinned for the
# repository). Building is offline, with the placeholders of the cluster's example key lists; the
# tests of the flows and the schedules read the render of the tree, whose charts are pulled once per
# run from their public registries. run.sh runs on the host's bash against a fake robot, and just
# robot and just robot-run run from a copy of the scripts against a recording kubectl, which reaches
# no cluster.

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
  NAMESPACE=robot
  BASE="$REPO/kubernetes/apps/base/robot"
  APP="$BASE/robot"
  PIECE="$BASE/robot-ascender"
  OVERLAY_DIR="$REPO/kubernetes/apps/overlays/lab-sto2"
  DOCS="$REPO/docs/kubernetes.md"
  RUNNER=robot/CronJob/robot-suites
  SERVER=robot/Deployment/robot-reports
  HELLO=demo/Deployment/hello
  # The pods of the render the flows are asked of, and pods no render holds, by their labels: the
  # public Gateway's proxies, which Envoy Gateway makes at run time, the cluster's resolver, Ascender's
  # web and task pods, which its operator makes, an application of another namespace, a pod of robot
  # that is neither the runner nor the server, and a pod of another namespace that carries the
  # runner's labels.
  PROXY='envoy-gateway-system:app.kubernetes.io/name=envoy,app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,gateway.envoyproxy.io/owning-gateway-name=public,gateway.envoyproxy.io/owning-gateway-namespace=envoy-gateway-system'
  DNS='kube-system:k8s-app=kube-dns'
  ASCENDER_WEB='ascender:app.kubernetes.io/name=ascender-web,app.kubernetes.io/part-of=ascender,app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/component=awx'
  ASCENDER_TASK='ascender:app.kubernetes.io/name=ascender-task,app.kubernetes.io/part-of=ascender,app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/component=awx'
  OTHER_APP='other:app.kubernetes.io/name=app'
  STRAY='robot:app.kubernetes.io/name=robot,app.kubernetes.io/component=stray'
  IMPOSTOR='other:app.kubernetes.io/name=robot,app.kubernetes.io/component=runner'
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

# flux_build ROOT NAME KS: what the Flux Kustomization in the file KS applies, built from its
# spec.path in the tree ROOT with strict substitution. In memory: flux build otherwise rewrites the
# kustomization.yaml of what it builds, in the checkout, and puts it back afterwards.
flux_build() {
  local path
  path="$(yq '.spec.path' "$3")"
  (cd "$1" && flux build kustomization "$2" --path "./kubernetes/${path#./}" \
    --kustomization-file "$3" --dry-run --strict-substitute --in-memory-build)
}

# built NAME [ROOT]: the application NAME as Flux applies it on lab-sto2, from the tree ROOT (the
# repository when none is given). The cluster's root is built as Flux builds it, so the overlay's
# Kustomization of the application carries what the root patches into every child; that
# Kustomization is then built with the example key lists under its own substitutions. Writes the
# application's build to $BUILT and sets KS, the Kustomization as the root builds it, with those
# substitutions.
built() {
  local root="${2:-$REPO}" ks path
  ks="$root/kubernetes/clusters/lab-sto2/ks.yaml"
  path="$(yq '.spec.path' "$ks")"
  ROOT="$BATS_TEST_TMPDIR/root.yaml"
  (cd "$root" && flux build kustomization "$(yq '.metadata.name' "$ks")" \
    --path "./kubernetes/${path#./}" --kustomization-file "$ks" --dry-run --in-memory-build) >"$ROOT"
  KS="$BATS_TEST_TMPDIR/$1-ks.yaml"
  with_vars "$1" "$ROOT" >"$KS"
  [ -s "$KS" ] || { echo "the lab-sto2 overlay does not enable $1"; return 1; }
  BUILT="$BATS_TEST_TMPDIR/$1-built.yaml"
  flux_build "$root" "$1" "$KS" >"$BUILT"
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

# workload KIND NAME: writes the workload of $BUILT to $WORKLOAD, its pod spec to $POD and its one
# container to $CONTAINER.
workload() {
  WORKLOAD="$BATS_TEST_TMPDIR/workload-$2.yaml"
  POD="$BATS_TEST_TMPDIR/pod-$2.yaml"
  CONTAINER="$BATS_TEST_TMPDIR/container-$2.yaml"
  object "$BUILT" "$1" "$2" >"$WORKLOAD"
  [ -s "$WORKLOAD" ] || { echo "the build has no $1 $2"; return 1; }
  yq '.spec.jobTemplate.spec.template // .spec.template' "$WORKLOAD" >"$POD"
  [ "$(yq '.spec.containers | length' "$POD")" -eq 1 ] || { echo "the pod of $2 has not one container"; return 1; }
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

# of_namespace FILE: what an overlay built into FILE holds of Robot Framework and of its namespace,
# sorted, as kind, namespace and name: the namespace itself, any object in it, and any Kustomization
# that deploys into it or from its directory.
of_namespace() {
  yq -N 'select((.kind == "Namespace" and .metadata.name == "robot") or .metadata.namespace == "robot"
      or .spec.targetNamespace == "robot" or ((.spec.path // "") | test("/apps/base/robot/")))
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

# mounts FILE: the mounts of the one container of the pod spec in FILE, as a set, one a line: the
# path, the kind of its volume, the object it names (a ConfigMap's name, with "optional" when it may
# be missing, a claim's name, "read-only" when the volume itself is), and whether the container may
# write there.
mounts() {
  yq -o json '.spec' "$1" | jq -r '. as $pod | .containers[] | (.volumeMounts // [])[] | . as $m
    | ([$pod.volumes[] | select(.name == $m.name)][0] // {}) as $v
    | [$m.mountPath, ($v | del(.name) | keys | join("+")),
       (if $v.configMap then $v.configMap.name + (if $v.configMap.optional == true then " optional" else "" end)
        elif $v.persistentVolumeClaim then $v.persistentVolumeClaim.claimName + (if $v.persistentVolumeClaim.readOnly == true then " read-only" else "" end)
        else "-" end),
       (if $m.readOnly == true then "read-only" else "writable" end)] | join(" ")' | LC_ALL=C sort
}

# containers FILE: every container of every pod template of FILE, as JSON, one a line.
containers() {
  yq -o json -I0 'select(. != null)' "$1" | jq -c '
    select(.kind == "Pod" or .spec.template != null or .spec.jobTemplate != null)
    | (if .kind == "Pod" then .spec elif .spec.template != null then .spec.template.spec else .spec.jobTemplate.spec.template.spec end)
    | ((.containers // []) + (.initContainers // []) + (.ephemeralContainers // []))[]'
}

# pod_specs FILE: every pod spec of every pod template of FILE, as JSON, one a line.
pod_specs() {
  yq -o json -I0 'select(. != null)' "$1" | jq -c '
    select(.kind == "Pod" or .spec.template != null or .spec.jobTemplate != null)
    | if .kind == "Pod" then .spec elif .spec.template != null then .spec.template.spec else .spec.jobTemplate.spec.template.spec end'
}

# suite_files: every Robot Framework file of both pieces, one path a line.
suite_files() {
  find "$BASE" -type f \( -name '*.robot' -o -name '*.resource' \) | LC_ALL=C sort
}

# code FILE: FILE's lines that Robot Framework reads as data, numbered: comments, from an unescaped
# # that starts a cell, at the row's start or after a tab or two spaces, to the row's end, and empty
# lines left out. A # within a cell is data, as Robot reads it.
code() {
  awk '{ line = $0; sub(/(^[ \t]*|\t|  )#.*$/, "", line); if (line ~ /[^ \t]/) print FILENAME ":" FNR ": " line }' "$1"
}

# The keywords a suite may call besides those its file and common.resource define, as refused_calls
# matches names: the Browser library's that open the target, read the page, wait, take a screenshot
# or fetch with Http, and Robot's own that compare. None clicks, types, runs another keyword or a
# program, or evaluates an expression it is given. A keyword not listed goes in here in the pull
# request whose suite calls it.
SUITE_KEYWORDS='newbrowser newcontext newpage goto closebrowser http takescreenshot setbrowsertimeout
  gettext gettitle geturl getattribute getelementby getelementbyrole getelementcount getelementstates
  waitforelementsstate waitforloadstate
  shouldbeequal shouldbeequalasintegers shouldbeequalasstrings shouldcontain shouldnotcontain
  shouldmatchregexp'

# foreign_bytes FILE: how many bytes of FILE are other than a tab, a line feed or printable ASCII,
# 0x20 to 0x7e, and the lines that hold them; nothing when none is. A carriage return, every other
# control character, DEL and every byte of a character beyond ASCII count.
foreign_bytes() {
  local count
  count="$(LC_ALL=C tr -d '\t\n\040-\176' <"$1" | wc -c)"
  ((count == 0)) ||
    echo "$1: $((count)) bytes other than a tab, a line feed or printable ASCII, on the lines $(LC_ALL=C awk '/[^\t -~]/ { printf "%s ", FNR }' "$1")"
}

# refused_calls FILE: what the check of a suite's text refuses in FILE, one a line. It is a lint of
# the text, which keeps a suite from doing these things by accident or in an obvious form; it is no
# confinement, and what bounds the runner is its egress once the cluster enforces network policy.
# It reads each cell as it is written: except where a refusal says so, the Http path and the Take
# Screenshot name, which must be literals with no variable or escape, it does not follow Robot's
# escapes or variables, so a suite written to get round it can. It first refuses every byte but a
# tab, a line feed and printable ASCII (foreign_bytes), and every row of Robot's pipe format, one
# whose first character but white space is a pipe: Robot Framework splits rows at every line end
# Python's str.splitlines knows and cells at two or more of any Unicode white space, and the split
# here, rows at line feeds and cells at two spaces or more or a tab, agrees with Robot's only in
# that alphabet and the space-separated format. Each keyword's name is matched without case,
# spaces or underscores, and with a Browser. or BuiltIn. prefix dropped, the libraries a suite may
# name. A suite imports no library but Browser alone, no resource but common.resource and no
# variable file; it calls only the keywords of SUITE_KEYWORDS and those its file or a resource
# defines, in a step, a setup or a teardown, so no control structure, whose conditions Robot
# evaluates as Python; New Browser only as a headless Chromium and New Context with no argument;
# it assigns no target's variable, ${<NAME>_URL}, and continues no row but a documentation's, as a
# continued row adds arguments to the one above. In every cell, so in a keyword's arguments too,
# by its name and by the name after its last dot, it refuses a keyword that clicks, taps, fills,
# types, presses keys, moves or presses the mouse, hovers, focuses, checks, selects, drags,
# uploads, evaluates Python or JavaScript, runs a program or imports a library; the assertion
# operators that evaluate Python, validate, then and evaluate, spelled out by position, and
# assertion_operator given by name, whatever its value, which no suite needs; Http but as a GET of
# a literal path, / or /<path>, <path> not starting with /, with no backslash and no variable
# anywhere in it: Robot unescapes a cell and substitutes its variables before the page's fetch
# resolves it, which takes //<host> and /\<host> to another host and drops a tab or a newline
# first, so a path given as a variable or a keyword's argument is refused too; Take Screenshot
# with anything but no argument or one bare file name, with no /, backslash, variable or = in it,
# as the library writes a relative name under the run's browser/screenshot/ and a path with a
# directory where that path leads; Go To, New Page and the suites' Open Target with anything but
# one target's variable, or, in common.resource, New Page with the ${url} Open Target is given;
# inline Python, ${{...}}; and a variable that is more than a name, ${name.attribute} or
# ${a + b}, which Robot evaluates as Python.
refused_calls() {
  local files bytes
  bytes="$(foreign_bytes "$1")"
  if [ -n "$bytes" ]; then
    echo "$bytes"
    return 0
  fi
  mapfile -t files < <(suite_files)
  awk -v resource="$([[ ${1##*/} == common.resource ]] && echo 1)" -v listed="${SUITE_KEYWORDS//$'\n'/ }" '
    function name(cell) { cell = tolower(cell); gsub(/[ _]/, "", cell); sub(/^(browser|builtin)\./, "", cell); return cell }
    function trim(text) { sub(/^[ \t]+/, "", text); sub(/[ \t]+$/, "", text); return text }
    # refused(k): whether the name k is a keyword or an operator no cell may name.
    function refused(k) {
      return k ~ /^(click|fill|typetext|typesecret|presskeys|keyboard|upload|evaluate|mouse|checkcheckbox|uncheckcheckbox|selectoptions|deselectoptions|draganddrop|hover|focus|runprocess|startprocess|importlibrary)/ ||
        k ~ /^(tap|run|validate|then)$/ || k ~ /^assertionoperator=/
    }
    # row: whether the record holds data; if it does, the data in data, its first cell in first and
    # its other cells, empty ones left out, in cell[1] to cell[m].
    function row(raw, n, i) {
      data = $0
      sub(/(^[ \t]*|\t|  )#.*$/, "", data)
      if (data !~ /[^ \t]/) return 0
      n = split(data, raw, /\t+|  +/)
      first = trim(raw[1])
      m = 0
      for (i = 2; i <= n; i++) if (trim(raw[i]) != "") cell[++m] = trim(raw[i])
      return 1
    }
    # call J SETUP: why the keyword of cell[J], the cells after it its arguments, is refused, or "".
    # Robot looks a name up in the file first, then in its resources, then in its libraries, so a
    # keyword a suite file defines counts only in that file or, defined in a resource, in every
    # suite, and only when the call names no library or resource before a dot.
    function call(j, setup, k) {
      k = name(cell[j])
      if (setup && k == "none") return ""
      if (!(k in allowed) && !(cell[j] !~ /\./ && ((FILENAME, k) in defined || k in shared))) return "a keyword the suites may not call"
      if (k == "newbrowser" && !(m == j + 2 && cell[j + 1] == "chromium" && cell[j + 2] == "headless=True")) return "New Browser but as a headless Chromium"
      if (k == "newcontext" && m > j) return "New Context with an argument"
      return ""
    }
    BEGIN { n = split(listed, list, / +/); for (i = 1; i <= n; i++) if (list[i] != "") allowed[list[i]] = 1 }
    FNR == 1 { section = ""; doc = 0 }
    # Robot reads a row whose first character but white space is a pipe in its pipe format, where a
    # # after two spaces is data, not a comment; the suites are in the space-separated format.
    /^[ \t]*\|/ { if (pass == 2) print FILENAME ":" FNR ": a row of the pipe format: " $0; next }
    !row() { next }
    first ~ /^\*/ {
      section = tolower(first)
      gsub(/[* ]/, "", section)
      sub(/s$/, "", section)
      if (pass == 2 && section !~ /^(setting|variable|testcase|task|keyword|comment)$/) print FILENAME ":" FNR ": a section the suites do not use: " $0
      next
    }
    # The first pass reads the names of the keywords each suite file defines.
    pass == 1 {
      if (section == "keyword" && first != "") { defined[FILENAME, name(first)] = 1; if (FILENAME ~ /\.resource$/) shared[name(first)] = 1 }
      next
    }
    {
      if (data ~ /\$\{\{/) { print FILENAME ":" FNR ": inline Python: " $0; next }
      plain = data
      gsub(/[$@&%]\{[A-Za-z0-9_ ]*\}/, "", plain)
      if (plain ~ /[$@&%]\{/) { print FILENAME ":" FNR ": a variable that is more than a name: " $0; next }
      for (i = 1; i <= m; i++) {
        k = name(cell[i])
        last = k
        sub(/^.*\./, "", last)
        if (refused(k) || refused(last)) { print FILENAME ":" FNR ": " cell[i] ": " $0; next }
        if (last == "http" && !(m == i + 2 && cell[i + 1] ~ /^\/([^\/\\$@&%{ ][^ \\$@&%{]*)?$/ && cell[i + 2] == "GET")) { print FILENAME ":" FNR ": " cell[i] ": " $0; next }
        if (last == "takescreenshot" && !(m == i || (m == i + 1 && cell[i + 1] ~ /^[^\/\\$@&%{= ]+$/))) { print FILENAME ":" FNR ": " cell[i] ": " $0; next }
        if (last == "goto" || last == "newpage" || last == "opentarget") {
          if (m == i + 1 && cell[i + 1] ~ /^\$\{[A-Z][A-Z0-9_]*_URL\}$/) continue
          if (m == i + 1 && resource && last == "newpage" && cell[i + 1] == "${url}") continue
          print FILENAME ":" FNR ": " cell[i] ": " $0
          next
        }
      }
      if (section == "") { print FILENAME ":" FNR ": data before any section: " $0; next }
      if (section == "variable" || section == "comment") next
      if (first == "..." || cell[1] == "...") {
        if (!doc) print FILENAME ":" FNR ": a row that continues another: " $0
        next
      }
      doc = 0
      why = ""
      if (section == "setting") {
        s = tolower(first)
        gsub(/ /, "", s)
        if (s == "documentation") doc = 1
        else if (s == "library") { if (m != 1 || cell[1] != "Browser") why = "a library but Browser alone" }
        else if (s == "resource") { if (m != 1 || cell[1] != "common.resource") why = "a resource but common.resource" }
        else if (s ~ /^(suite|test)(setup|teardown)$/) { if (m) why = call(1, 1) }
        else if (s != "testtags" && s != "testtimeout") why = "a setting the suites do not use"
      } else if (m && cell[1] ~ /^\[.*\]$/) {
        s = tolower(cell[1])
        gsub(/ /, "", s)
        if (s == "[documentation]") doc = 1
        else if (s == "[setup]" || s == "[teardown]") { if (m > 1) why = call(2, 1) }
        else if (s == "[arguments]") { for (j = 2; j <= m; j++) if (cell[j] ~ /^[$@&]\{[A-Z][A-Z0-9_]*_URL\}/) why = "an argument named as a target" }
        else if (s != "[tags]" && s != "[timeout]") why = "a setting the suites do not use"
      } else if (m) {
        for (j = 1; j < m && cell[j] ~ /^[$@&]\{[^}]*\}(\[[^]]*\])*( ?=)?$/; j++)
          if (cell[j] ~ /^[$@&]\{[A-Z][A-Z0-9_]*_URL\}/) why = "an assignment to a target"
        if (why == "") why = call(j, 0)
      }
      if (why != "") print FILENAME ":" FNR ": " why ": " $0
    }' pass=1 "${files[@]}" pass=2 "$1"
}

# fake_run: a directory standing in for the claim, a fake robot, date, rm and mktemp on PATH, for
# run.sh as the container runs it. The fake robot records its arguments, writes Robot's three files
# into its --outputdir and exits with the number in $STATE/rc; and while $STATE/robot-waits exists
# it touches $STATE/robot-ready and runs until SIGTERM, which it records in $STATE/robot-signals, or
# for at most 20 seconds. The fake date prints $STATE/stamp for the run's directory. As $STATE/lock
# says, the run's directory (run) or the claim's root (reports) refuses writes, as a full or failing
# claim would, in a way no mode bit gives, since none stops root: with run, robot leaves a directory
# where each of the run's status and job is written; with reports, rm and mktemp refuse, so no run
# leaves the claim's root and nothing is made in it. Otherwise rm and mktemp are the system's. Sets
# REPORTS, SUITES, FAKE, STATE and RUN_ENVIRONMENT, the only variables run.sh gets.
fake_run() {
  local tool
  REPORTS="$BATS_TEST_TMPDIR/reports" SUITES="$BATS_TEST_TMPDIR/suites" FAKE="$BATS_TEST_TMPDIR/fake"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$REPORTS" "$SUITES/base" "$SUITES/ascender" "$FAKE" "$STATE"
  echo 0 >"$STATE/rc"
  echo 2026-11-18T054500Z >"$STATE/stamp"
  { printf '#!/usr/bin/env bash\nSTATE=%q\n' "$STATE"; cat <<'EOF'; } >"$FAKE/robot"
printf '%s\n' "$@" >"$STATE/robot-argv"
out=
while (($#)); do
  if [[ $1 == --outputdir ]]; then out=$2; fi
  shift
done
for file in output.xml log.html report.html; do echo "$file" >"$out/$file"; done
echo '==============================================================================='
echo 'Suites'
case $(cat "$STATE/lock" 2>/dev/null) in
  run) mkdir "$out/status" "$out/job" ;;
esac
if [[ -e $STATE/robot-waits ]]; then
  trap 'echo SIGTERM >"$STATE/robot-signals"; exit "$(cat "$STATE/rc")"' TERM
  touch "$STATE/robot-ready"
  for ((tick = 0; tick < 200; tick++)); do sleep 0.1; done
fi
exit "$(cat "$STATE/rc")"
EOF
  { printf '#!/usr/bin/env bash\nSTATE=%q\n' "$STATE"; cat <<'EOF'; } >"$FAKE/date"
[[ $* == '-u +%Y-%m-%dT%H%M%SZ' ]] || { echo "date: unexpected $*" >&2; exit 1; }
cat "$STATE/stamp"
EOF
  for tool in rm mktemp; do
    { printf '#!/usr/bin/env bash\nSTATE=%q\n' "$STATE"; cat <<'EOF'; } >"$FAKE/$tool"
if [[ $(cat "$STATE/lock" 2>/dev/null) == reports ]]; then
  echo "${0##*/}: the claim's root refuses writes: $*" >&2
  exit 1
fi
PATH=${PATH#*:}
exec "${0##*/}" "$@"
EOF
  done
  chmod +x "$FAKE/robot" "$FAKE/date" "$FAKE/rm" "$FAKE/mktemp"
  RUN_ENVIRONMENT=(HOME=/tmp KEEP_RUNS=30 JOB_NAME=robot-suites-29384750 REPORTS_DIR="$REPORTS" SUITES_DIR="$SUITES"
    PATH="$FAKE:/usr/bin:/bin")
}

# run_sh ARG...: run.sh, run by bash as the container runs it, with only RUN_ENVIRONMENT set and the
# CronJob's arguments unless others are given.
run_sh() {
  if (($# == 0)); then
    set -- --variable HELLO_URL:http://hello.demo.svc.cluster.local:80 --variable ASCENDER_URL:http://ascender-web.ascender.svc.cluster.local:80
  fi
  run env -i "${RUN_ENVIRONMENT[@]}" /bin/bash "$APP/app/run.sh" "$@"
}

# index_rows: the rows of the index's table of runs, one a line, as the run's directory and the text
# of its result cell, newest first as the index lists them.
index_rows() {
  grep -o '<tr><td>[^<]*</td><td>[^<]*</td><td>[^<]*\(<br>[^<]*\)\?</td><td><a href="[^"/]*/report.html">' "$REPORTS/index.html" |
    sed -E 's|^<tr><td>[^<]*</td><td>[^<]*</td><td>([^<]*)(<br>([^<]*))?</td><td><a href="([^"/]*)/report.html">$|\4 \1\2|; s|<br>| / |'
}

# recipe_copy: a copy of the repository's scripts, with a kubeconfig for the cluster lab-sto2, for
# just robot and just robot-run to run in through the repository's justfile, against recording
# fakes: a mise with nothing installed, which keeps the justfile from putting real tools in front of
# the fakes; a date that names the run robot-run-20261118-054500; and a kubectl that records its
# arguments, the kubeconfig it was given and the names of its environment. For port-forward it acts
# as the file $STATE/mode says: forward reports a forward and runs until SIGTERM ends it, as kubectl
# does; silent runs without reporting one; fail stops at once with an error naming an address; drop
# reports a forward and stops a moment later. For just robot-run it answers get jobs with
# $STATE/jobs.json, create job with a line, or with an error naming an address while
# $STATE/create-fails exists, the Nth get pods with $STATE/pods.N.json or else $STATE/pods.json,
# logs with $STATE/logs, then fails with an error naming an address while $STATE/logs-fails exists
# or runs until SIGTERM while $STATE/logs-hangs exists, and get job with $STATE/job.json. Sets COPY,
# BIN, RECORD, STATE, KUBECONFIG_FILE, JOB, JUST and ENVIRONMENT, the only variables the recipe
# gets.
recipe_copy() {
  COPY="$BATS_TEST_TMPDIR/copy" BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record" STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$COPY/talos/lab-sto2/clusterconfig" "$BIN" "$RECORD" "$STATE"
  cp -R "$REPO/scripts" "$COPY/scripts"
  KUBECONFIG_FILE="$COPY/talos/lab-sto2/clusterconfig/kubeconfig"
  echo 'not a real kubeconfig' >"$KUBECONFIG_FILE"
  echo forward >"$STATE/mode"
  JOB=robot-run-20261118-054500
  echo '{"items": []}' >"$STATE/jobs.json"
  pods Succeeded 0 >"$STATE/pods.json"
  job_condition Complete >"$STATE/job.json"
  printf '%s\n' '==============================================================================' 'Suites' \
    '3 tests, 3 passed, 0 failed' >"$STATE/logs"
  JUST=$(command -v just)
  only
  printf '#!/usr/bin/env bash\n' >"$BIN/mise"
  printf '#!/usr/bin/env bash\n[[ $* == "-u +%%Y%%m%%d-%%H%%M%%S" ]] && { echo 20261118-054500; exit 0; }\nexec %q "$@"\n' "$(command -v date)" >"$BIN/date"
  { printf '#!/usr/bin/env bash\nRECORD=%q STATE=%q\n' "$RECORD" "$STATE"; cat <<'EOF'; } >"$BIN/kubectl"
printf '%s\n' "$*" >>"$RECORD/argv"
printf '%s\n' "${KUBECONFIG-unset}" >>"$RECORD/kubeconfig"
env | cut -d= -f1 >>"$RECORD/names"
echo "$$ $PPID" >"$STATE/pids"
last=${!#}
case $1 in
  port-forward)
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
    ;;
  create)
    if [[ -e $STATE/create-fails ]]; then
      echo 'error: failed to create job: Post "https://192.0.2.10:6443/apis/batch/v1/namespaces/robot/jobs": dial tcp 192.0.2.10:6443: connect: connection refused' >&2
      exit 1
    fi
    echo "job.batch/$last created"
    ;;
  logs)
    cat "$STATE/logs"
    if [[ -e $STATE/logs-fails ]]; then
      echo 'error: Get "https://192.0.2.10:6443/api/v1/namespaces/robot/pods/robot-run-20261118-054500-x7k2p/log?follow=true": dial tcp 192.0.2.10:6443: connect: connection refused' >&2
      exit 1
    fi
    if [[ -e $STATE/logs-hangs ]]; then
      trap 'echo SIGTERM >>"$RECORD/ended"; exit 0' TERM
      while :; do sleep 0.1; done
    fi
    ;;
  get)
    case $2 in
      jobs) cat "$STATE/jobs.json" ;;
      job) cat "$STATE/job.json" ;;
      pods)
        n=$(($(cat "$STATE/pods.count" 2>/dev/null || echo 0) + 1))
        echo "$n" >"$STATE/pods.count"
        if [[ -e $STATE/pods.$n.json ]]; then cat "$STATE/pods.$n.json"; else cat "$STATE/pods.json"; fi
        ;;
      *) exit 3 ;;
    esac
    ;;
  *) exit 3 ;;
esac
EOF
  chmod +x "$BIN/mise" "$BIN/date" "$BIN/kubectl"
}

# pods PHASE [CODE]: kubectl's list of the job's one pod in PHASE, its container robot ended with
# CODE when one is given; no PHASE is an empty list.
pods() {
  if [[ -z ${1-} ]]; then
    echo '{"apiVersion": "v1", "kind": "List", "items": []}'
    return
  fi
  jq -n --arg phase "$1" --arg code "${2-}" '{"apiVersion": "v1", "kind": "List", "items": [{"metadata": {"name": "robot-run-20261118-054500-x7k2p"},
    "status": {"phase": $phase, "containerStatuses": [{"name": "robot",
      "state": (if $code == "" then {"running": {}} else {"terminated": {"exitCode": ($code | tonumber), "reason": (if $code == "0" then "Completed" else "Error" end)}} end)}]}}]}'
}

# job_condition TYPE [REASON]: kubectl's view of the job with the condition TYPE true, for REASON.
job_condition() {
  jq -n --arg type "$1" --arg reason "${2-}" '{"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": "robot-run-20261118-054500"},
    "status": {"conditions": [{"type": $type, "status": "True", "reason": $reason,
      "message": (if $reason == "DeadlineExceeded" then "Job was active longer than specified deadline" else "" end)}]}}'
}

# with ENTRY...: adds the NAME=VALUE ENTRY... to the environment the recipes get.
with() {
  ENVIRONMENT+=("$@")
}

# only ENTRY...: the environment the recipes get is TMPDIR and the NAME=VALUE ENTRY... alone.
only() {
  ENVIRONMENT=(TMPDIR="$BATS_TEST_TMPDIR" "$@")
}

# recipe NAME: runs just NAME in the copy with only ENVIRONMENT set, failing after a minute rather
# than hanging.
recipe() {
  run timeout 60 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$REPO/justfile" --working-directory "$COPY" "$1"
}

# recipe_start NAME: starts just NAME as recipe runs it, in the background, with its output in
# $BATS_TEST_TMPDIR/out. Sets OUT and JUST_PID.
recipe_start() {
  OUT="$BATS_TEST_TMPDIR/out"
  env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$REPO/justfile" --working-directory "$COPY" "$1" >"$OUT" 2>&1 3>&- &
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

# finished: waits up to 20 seconds for just, started by recipe_start, to end, and sets STATUS to
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
  echo "just still runs after 20 seconds"
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

# flat: its input on one line, every run of white space one space.
flat() {
  tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

# section: the docs' section on Robot Framework, from its heading to the next of its level or above.
section() {
  awk '/^### Robot Framework$/ { on = 1; next } on && /^##?#? / { exit } on' "$DOCS"
}

@test "Robot Framework is selected by overlay entries, builds nothing when it is not, and builds without Ascender" {
  local ks entries named
  # The overlay selects it with three entries, the namespace directory and the two ks.yaml, the
  # piece that names Ascender after the application it adds to.
  entries="$(yq '.resources[] | select(test("/robot(/|$)"))' "$OVERLAY_DIR/kustomization.yaml" | paste -sd' ' -)"
  [ "$entries" = "../../base/robot ../../base/robot/robot/ks.yaml ../../base/robot/robot-ascender/ks.yaml" ]
  overlay
  [ "$(of_namespace "$OVERLAY")" = ConfigMap/robot/app-template-defaults,Kustomization/flux-system/robot,Kustomization/flux-system/robot-ascender,Namespace/-/robot,NetworkPolicy/robot/default-deny ]
  # The namespace directory holds what every namespace directory does: its namespace, its default
  # deny and the common component.
  [ "$(yq -o json -I0 '{"namespace": .namespace, "components": .components, "resources": .resources}' "$BASE/kustomization.yaml")" \
    = '{"namespace":"robot","components":["../../../components/common"],"resources":["namespace.yaml","networkpolicy-default-deny.yaml"]}' ]
  # robot waits for the definition of its policies' kind alone, as the runner starts without its
  # targets, is Ready only once what it applies is, and substitutes its two targets.
  ks="$(object "$OVERLAY" Kustomization robot | yq -o json -I0 '.spec')"
  [ "$(jq -c '.dependsOn | map(.name)' <<<"$ks")" = '["cilium"]' ]
  [ "$(jq -r '.wait' <<<"$ks")" = true ]
  [ "$(jq -r '.targetNamespace' <<<"$ks")" = "$NAMESPACE" ]
  [ "$(jq -r '.path' <<<"$ks")" = ./apps/base/robot/robot/app ]
  [ "$(jq -c '.postBuild.substitute | keys' <<<"$ks")" = '["ROBOT_TARGET_ASCENDER","ROBOT_TARGET_HELLO"]' ]
  # robot-ascender deploys into robot, names what its ConfigMap and policy need, robot's CronJob and
  # Ascender's web pods, and substitutes nothing of its own.
  ks="$(object "$OVERLAY" Kustomization robot-ascender | yq -o json -I0 '.spec')"
  [ "$(jq -c '.dependsOn | map(.name)' <<<"$ks")" = '["cilium","robot","ascender"]' ]
  [ "$(jq -r '.wait' <<<"$ks")" = true ]
  [ "$(jq -r '.targetNamespace' <<<"$ks")" = "$NAMESPACE" ]
  [ "$(jq -r '.path' <<<"$ks")" = ./apps/base/robot/robot-ascender/app ]
  [ "$(jq -c '.postBuild' <<<"$ks")" = null ]
  run "$REPO/scripts/kubernetes-check" "$REPO"
  echo "$output"
  [ "$status" -eq 0 ]
  # With only the namespace directory's entry, the namespace, its defaults and its default deny.
  tree_without '/robot/robot/ks.yaml$' '/robot/robot-ascender/ks.yaml$'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ "$(of_namespace "$OVERLAY")" = ConfigMap/robot/app-template-defaults,Namespace/-/robot,NetworkPolicy/robot/default-deny ]
  # With none, nothing of the namespace.
  tree_without '/robot(/|$)'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ -z "$(of_namespace "$OVERLAY")" ]
  # Without Ascender's three entries and robot-ascender's, the cluster builds everything of robot.
  # Its one object that names Ascender is the CronJob, by the variable Robot is handed and does not
  # use there and by the suite volume it mounts, which is optional; without the two, it names none.
  tree_without '/ascender(/|$)' '/robot/robot-ascender/ks.yaml$'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  overlay "$TREE/kubernetes/apps/overlays/lab-sto2"
  [ "$(of_namespace "$OVERLAY")" = ConfigMap/robot/app-template-defaults,Kustomization/flux-system/robot,Namespace/-/robot,NetworkPolicy/robot/default-deny ]
  built robot "$TREE"
  [ "$(yq -N 'select(. != null) | .kind + "/" + .metadata.name' "$BUILT" | sed -E 's/-[a-z0-9]{10}$/-<hash>/' | LC_ALL=C sort | paste -sd' ' -)" \
    = "CiliumNetworkPolicy/robot-reports CiliumNetworkPolicy/robot-runner ConfigMap/robot-scripts-<hash> ConfigMap/robot-suites-<hash> CronJob/robot-suites Deployment/robot-reports PersistentVolumeClaim/robot-reports Service/robot-reports" ]
  named="$(yq -N -o json -I0 'select(. != null)' "$BUILT" | jq -r 'select(tojson | test("ascender")) | .kind + "/" + .metadata.name')"
  [ "$named" = CronJob/robot-suites ]
  [ -z "$(object "$BUILT" CronJob robot-suites | yq -o json -I0 '.spec.jobTemplate.spec.template.spec
    | .containers[0].args |= map(select(test("^ASCENDER_URL:") | not))
    | .containers[0].volumeMounts |= map(select(.name != "suite-ascender"))
    | .volumes |= map(select(.name != "suite-ascender"))' | grep -i ascender || true)" ]
  [ "$(object "$BUILT" CronJob robot-suites | yq -o json -I0 '.spec.jobTemplate.spec.template.spec.volumes[] | select(.name == "suite-ascender") | .configMap')" \
    = '{"name":"robot-suite-ascender","optional":true}' ]
  # Selecting robot-ascender without Ascender, or without robot, is refused, naming both.
  tree_without '/ascender(/|$)'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "without Ascender: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"kubernetes/apps/base/robot/robot-ascender/ks.yaml: Kustomization robot-ascender names ascender"*"does not enable"* ]]
  tree_without '/robot/robot/ks.yaml$'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "without robot: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"kubernetes/apps/base/robot/robot-ascender/ks.yaml: Kustomization robot-ascender names robot"*"does not enable"* ]]
  # Selecting it without cilium is refused, naming both.
  tree_without '/kube-system/cilium/ks.yaml$'
  run "$REPO/scripts/kubernetes-check" "$TREE"
  echo "without cilium: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"kubernetes/apps/base/robot/robot/ks.yaml: Kustomization robot names cilium"*"does not enable"* ]]
}

@test "Robot Framework's runner and report server run images pinned by tag and digest" {
  local image rules pattern tag
  built robot
  # The CronJob and the Deployment make every pod of the application, one container each and
  # nothing else.
  [ "$(yq -N 'select(.spec.template != null or .spec.jobTemplate != null or .kind == "Pod") | .kind + "/" + .metadata.name' "$BUILT" | LC_ALL=C sort | paste -sd' ' -)" \
    = "CronJob/robot-suites Deployment/robot-reports" ]
  [ -z "$(containers "$BUILT" | jq -r 'select(.name != "robot" and .name != "httpd") | .name')" ]
  workload CronJob robot-suites
  [ "$(yq '.spec | (.initContainers // []) + (.ephemeralContainers // []) | length' "$POD")" -eq 0 ]
  image="$(yq '.image' "$CONTAINER")"
  echo "the runner runs $image"
  # A release of three numbers, with the digest of its image index: a tag alone moves, and the
  # registry's 21, 21.0 and latest are moving tags beside the releases.
  [[ $image =~ ^docker\.io/marketsquare/robotframework-browser:([0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$ ]]
  tag="${BASH_REMATCH[1]}"
  workload Deployment robot-reports
  [ "$(yq '.spec | (.initContainers // []) + (.ephemeralContainers // []) | length' "$POD")" -eq 0 ]
  echo "the server runs $(yq '.image' "$CONTAINER")"
  [[ $(yq '.image' "$CONTAINER") =~ ^docker\.io/library/busybox:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]
  # The busybox of the drill's check, by the same reference, which Renovate moves with it.
  [ "$(yq '.image' "$CONTAINER")" = "$(yq '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "check") | .image' "$REPO/kubernetes/components/volsync-drill/cronjob.yaml")" ]
  # Renovate's kubernetes manager reads both from their manifests, as it reads every plain
  # manifest's image, and no custom manager does: the files hold no comment of Renovate's, and the
  # tag forms name neither.
  [ "$(awk -F'\t' '$1 ~ /^kubernetes\/apps\/base\/robot\//' "$REPO/.renovate/extracted.tsv")" = "$(printf '%s\t%s\t%s\t%s\n' \
    kubernetes/apps/base/robot/robot/app/cronjob.yaml kubernetes docker.io/marketsquare/robotframework-browser - \
    kubernetes/apps/base/robot/robot/app/deployment-reports.yaml kubernetes docker.io/library/busybox -)" ]
  [ -z "$(grep -rn 'renovate' "$BASE" || true)" ]
  [ -z "$(grep -n 'robotframework' "$REPO/.renovate/tag-forms.tsv" || true)" ]
  # One rule keeps Renovate to releases.
  rules="$(grep -v '^[[:space:]]*//' "$REPO/.renovate/managers.json5" | yq -o json -I0 '.packageRules')"
  [ "$(jq -c '[.[] | select([.matchPackageNames // [] | .[] | test("robotframework")] | any)] | map(del(.description))' <<<"$rules")" \
    = '[{"matchPackageNames":["docker.io/marketsquare/robotframework-browser"],"allowedVersions":"/^[0-9]+\\.[0-9]+\\.[0-9]+$/"}]' ]
  pattern="$(jq -r '.[] | select((.matchPackageNames // []) | index("docker.io/marketsquare/robotframework-browser")) | .allowedVersions | ltrimstr("/") | rtrimstr("/")' <<<"$rules")"
  [[ $tag =~ $pattern ]]
  for tag in 21 21.0 latest 21.0.0b1 21.1.0-alpha; do
    if [[ $tag =~ $pattern ]]; then echo "the rule lets Renovate propose $tag"; return 1; fi
  done
  # Both merge by the switch alone: no rule of the auto-merge file names either.
  [ "$(grep -v '^[[:space:]]*//' "$REPO/.renovate/automerge.json5" | yq -o json -I0 '.packageRules' |
    jq '[.[] | select(tojson | test("robotframework|robot/"))] | length')" -eq 0 ]
  # No chart: nothing of either piece is a source signatures.yaml would hold a row for.
  [ -z "$(yq -N 'select(.kind | test("^(OCIRepository|HelmRepository|HelmRelease|GitRepository)$")) | .kind' "$BUILT")" ]
  built robot-ascender
  [ -z "$(yq -N 'select(.kind | test("^(OCIRepository|HelmRepository|HelmRelease|GitRepository)$")) | .kind' "$BUILT")" ]
  [ -z "$(containers "$BUILT")" ]
}

@test "Robot Framework's pods meet the restricted level with a read-only root and no service account token, and its browser runs without a privilege" {
  local ns name suites scripts cpu memory limit size file
  built robot
  overlay
  # The namespace, as the overlay builds it, enforces restricted, keeps what runs in it when it
  # leaves the tree, and no workload of it is excepted.
  ns="$(object "$OVERLAY" Namespace "$NAMESPACE" | yq -o json -I0 '.metadata')"
  [ "$(jq -cS '.labels' <<<"$ns")" = '{"pod-security.kubernetes.io/enforce":"restricted"}' ]
  [ "$(jq -r '.annotations["kustomize.toolkit.fluxcd.io/prune"]' <<<"$ns")" = disabled ]
  [ "$(NS="$NAMESPACE" yq '[.exceptions[] | select(.namespace == strenv(NS))] | length' "$REPO/pod-security-exceptions.yaml")" -eq 0 ]
  suites="$(yq -N 'select(.kind == "ConfigMap" and (.metadata.name | test("^robot-suites-"))) | .metadata.name' "$BUILT")"
  scripts="$(yq -N 'select(.kind == "ConfigMap" and (.metadata.name | test("^robot-scripts-"))) | .metadata.name' "$BUILT")"
  [ -n "$suites" ] && [ -n "$scripts" ]
  for name in CronJob/robot-suites Deployment/robot-reports; do
    workload "${name%/*}" "${name#*/}"
    # The pod passes the restricted level, by the evaluator pod-security-check runs.
    restricted_failures "$POD" "$NAMESPACE"
    echo "$name: failed controls: $(paste -sd' ' "$CONTROLS") $(cat "$FORBIDDEN")"
    [ ! -s "$CONTROLS" ]
    # Nothing here calls the API: no token. No Service of the namespace hands the pod variables,
    # which would hand Robot ROBOT_REPORTS_* among them.
    [ "$(yq '.spec.automountServiceAccountToken' "$POD")" = false ]
    [ "$(yq '.spec.enableServiceLinks' "$POD")" = false ]
    [ "$(yq '.spec | (.hostNetwork // false) or (.hostPID // false) or (.hostIPC // false) or (.hostUsers == false)' "$POD")" = false ]
    # Names resolve as the cluster's resolver answers them, the one the runner's egress names: no
    # host alias and no DNS setting of the pod's own.
    [ "$(yq -o json -I0 '.spec | [has("hostAliases"), has("dnsPolicy"), has("dnsConfig")]' "$POD")" = '[false,false,false]' ]
    [ "$(yq -o json -I0 '.securityContext' "$CONTAINER" | jq -cS .)" \
      = '{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}' ]
  done
  # The runner: the image's user is the name pwuser, uid and gid 1001, which the kubelet cannot hold
  # to runAsNonRoot, so the numbers are given, with the group the claim's root is given on its
  # read-write mount when its group differs.
  workload CronJob robot-suites
  [ "$(yq -o json -I0 '.spec.securityContext' "$POD" | jq -cS .)" \
    = '{"fsGroup":1001,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":1001,"runAsNonRoot":true,"runAsUser":1001,"seccompProfile":{"type":"RuntimeDefault"}}' ]
  # Its mounts, as a set: the suites, the scripts and the optional Ascender suite read-only, the
  # claim, and /tmp in memory, where Chromium's profile, Playwright's artifacts and Chromium's
  # shared memory go; nothing at /dev/shm.
  mounts "$POD"
  [ "$(mounts "$POD")" = "$(printf '%s\n' \
    "/mnt/robot/scripts configMap $scripts read-only" \
    "/mnt/robot/suites/ascender configMap robot-suite-ascender optional read-only" \
    "/mnt/robot/suites/base configMap $suites read-only" \
    "/reports persistentVolumeClaim robot-reports writable" \
    "/tmp emptyDir - writable" | LC_ALL=C sort)" ]
  [ "$(yq -o json -I0 '.spec.volumes[] | select(.emptyDir != null) | .emptyDir | keys' "$POD")" = '["medium","sizeLimit"]' ]
  [ "$(yq '.spec.volumes[] | select(.emptyDir != null) | .emptyDir.medium' "$POD")" = Memory ]
  size="$(yq '.spec.volumes[] | select(.emptyDir != null) | .emptyDir.sizeLimit' "$POD")"
  echo "/tmp holds at most $size"
  [[ $size =~ ^([1-9][0-9]*)Mi$ ]]
  ((BASH_REMATCH[1] <= 512))
  [ -z "$(mounts "$POD" | grep '^/dev/shm ' || true)" ]
  # Requests of CPU and memory, a memory limit of twice the request, no CPU limit, within the caps.
  [ "$(yq -o json -I0 '.resources | {"requests": (.requests | keys), "limits": (.limits | keys)}' "$CONTAINER")" = '{"requests":["cpu","memory"],"limits":["memory"]}' ]
  cpu="$(yq '.resources.requests.cpu' "$CONTAINER")" memory="$(yq '.resources.requests.memory' "$CONTAINER")" limit="$(yq '.resources.limits.memory' "$CONTAINER")"
  echo "the runner requests $cpu and $memory, limited to $limit"
  # One statement each: a failure inside an && list does not end a test.
  [[ $cpu =~ ^([1-9][0-9]*)m$ ]]
  ((BASH_REMATCH[1] <= 500))
  [[ $memory =~ ^([1-9][0-9]*)Mi$ ]]
  ((BASH_REMATCH[1] % 64 == 0))
  ((BASH_REMATCH[1] <= 1024))
  [[ $limit =~ ^([1-9][0-9]*)Mi$ ]]
  ((BASH_REMATCH[1] <= 2048))
  ((BASH_REMATCH[1] == 2 * ${memory%Mi}))
  # The server runs as hello does, as 65534, with the claim read-only in its container and nothing
  # writable, and the requests and limit of the drill's check, which runs the same image.
  workload Deployment robot-reports
  [ "$(yq -o json -I0 '.spec.securityContext' "$POD" | jq -cS .)" \
    = '{"runAsGroup":65534,"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}}' ]
  [ "$(mounts "$POD")" = "/reports persistentVolumeClaim robot-reports read-only" ]
  [ "$(yq -o json -I0 '.resources' "$CONTAINER" | jq -cS .)" = '{"limits":{"memory":"32Mi"},"requests":{"cpu":"1m","memory":"8Mi"}}' ]
  # The browser: Playwright starts Chromium with --no-sandbox unless chromiumSandbox is true, and the
  # sandbox needs clones the runtime's seccomp profile refuses, so no suite asks for it, nor gives
  # Chromium arguments of its own; no container adds a capability or runs privileged.
  [ "$(suite_files | grep -c .)" -eq 4 ]
  for file in $(suite_files); do
    if grep -niE 'chromiumSandbox|--no-sandbox|args=' "$file"; then echo "$file asks for a sandbox or Chromium's arguments"; return 1; fi
  done
  [ -z "$(containers "$BUILT" | jq -r 'select(.securityContext.privileged == true or (.securityContext.capabilities.add // [] | length) > 0) | .name')" ]
}

@test "Robot Framework's namespace denies traffic by default, its runner reaches the resolver and its targets and nothing else, and its report server takes only the host" {
  local deny policies flow want side from to port
  real_render
  # The namespace holds the default deny, every pod and both directions with no rule, and is not
  # listed among the namespaces without one.
  deny="$(rendered NetworkPolicy.networking.k8s.io_robot_default-deny.yaml)"
  [ "$(yq -o json -I0 '[.metadata.name, .spec]' "$deny" | jq -cS .)" = '["default-deny",{"podSelector":{},"policyTypes":["Ingress","Egress"]}]' ]
  [ "$(NS="$NAMESPACE" yq '[.exceptions[] | select(.namespace == strenv(NS))] | length' "$REPO/network-policy-exceptions.yaml")" -eq 0 ]
  # The policies of the namespace are the default deny and Robot Framework's three, nothing else.
  [ "$(cd "$REAL" && find . -type f -name '*Policy*_robot_*' -printf '%f\n' | LC_ALL=C sort | paste -sd' ' -)" \
    = "CiliumNetworkPolicy.cilium.io_robot_robot-reports.yaml CiliumNetworkPolicy.cilium.io_robot_robot-runner-ascender.yaml CiliumNetworkPolicy.cilium.io_robot_robot-runner.yaml NetworkPolicy.networking.k8s.io_robot_default-deny.yaml" ]
  # Every rule of the three and of the two beside the targets, exactly: the runner takes nothing and
  # reaches the resolver, hello's pods and Ascender's web pods; the server takes the kubelet's probe
  # and sends nothing; hello takes the runner beside the proxies, Locust's workers and the kubelet,
  # and Ascender's web pods take it beside the proxies, the kubelet and the task pods.
  policies=("$(rendered CiliumNetworkPolicy.cilium.io_robot_robot-runner.yaml)" "$(rendered CiliumNetworkPolicy.cilium.io_robot_robot-reports.yaml)"
    "$(rendered CiliumNetworkPolicy.cilium.io_robot_robot-runner-ascender.yaml)" "$(rendered CiliumNetworkPolicy.cilium.io_demo_hello.yaml)"
    "$(rendered CiliumNetworkPolicy.cilium.io_ascender_ascender-web.yaml)")
  allows "${policies[@]}"
  [ "$(allows "${policies[@]}")" = "$(printf '%s\n' \
    "ascender-web [app.kubernetes.io/component=awx,app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/name=ascender-web] takes @host on 8052/TCP" \
    "ascender-web [app.kubernetes.io/component=awx,app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/name=ascender-web] takes app.kubernetes.io/component=awx,app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/name=ascender-task on 8052/TCP" \
    "ascender-web [app.kubernetes.io/component=awx,app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/name=ascender-web] takes app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,app.kubernetes.io/name=envoy,gateway.envoyproxy.io/owning-gateway-name=public,gateway.envoyproxy.io/owning-gateway-namespace=envoy-gateway-system,io.kubernetes.pod.namespace=envoy-gateway-system on 8052/TCP" \
    "ascender-web [app.kubernetes.io/component=awx,app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/name=ascender-web] takes app.kubernetes.io/component=runner,app.kubernetes.io/name=robot,io.kubernetes.pod.namespace=robot on 8052/TCP" \
    "hello [app.kubernetes.io/name=hello] takes @host on 8080/TCP" \
    "hello [app.kubernetes.io/name=hello] takes app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,app.kubernetes.io/name=envoy,gateway.envoyproxy.io/owning-gateway-name=public,gateway.envoyproxy.io/owning-gateway-namespace=envoy-gateway-system,io.kubernetes.pod.namespace=envoy-gateway-system on 8080/TCP" \
    "hello [app.kubernetes.io/name=hello] takes app.kubernetes.io/component=runner,app.kubernetes.io/name=robot,io.kubernetes.pod.namespace=robot on 8080/TCP" \
    "hello [app.kubernetes.io/name=hello] takes app.kubernetes.io/component=worker,app.kubernetes.io/name=locust,io.kubernetes.pod.namespace=locust on 8080/TCP" \
    "robot-reports [app.kubernetes.io/component=reports,app.kubernetes.io/name=robot] takes @host on 8080/TCP" \
    "robot-runner [app.kubernetes.io/component=runner,app.kubernetes.io/name=robot] sends to app.kubernetes.io/name=hello,io.kubernetes.pod.namespace=demo on 8080/TCP" \
    "robot-runner [app.kubernetes.io/component=runner,app.kubernetes.io/name=robot] sends to io.kubernetes.pod.namespace=kube-system,k8s-app=kube-dns on 53/TCP+53/UDP" \
    "robot-runner-ascender [app.kubernetes.io/component=runner,app.kubernetes.io/name=robot] sends to app.kubernetes.io/component=awx,app.kubernetes.io/managed-by=awx-operator,app.kubernetes.io/name=ascender-web,io.kubernetes.pod.namespace=ascender on 8052/TCP" |
    LC_ALL=C sort)" ]
  # The flows, evaluated on the render as Cilium decides them, over every policy of every namespace.
  local flows=(
    # The runner: the resolver, hello's port, Ascender's web port, and nothing else.
    "reaches --reach $RUNNER $DNS 53/udp"
    "reaches --reach $RUNNER $DNS 53/tcp"
    "reaches --reach $RUNNER $HELLO 8080/tcp"
    "reaches --reach $RUNNER $ASCENDER_WEB 8052/tcp"
    "refused --reach-egress $RUNNER @world 80/tcp"
    "refused --reach-egress $RUNNER @world 443/tcp"
    "refused --reach-egress $RUNNER @world 53/udp"
    "refused --reach-egress $RUNNER @kube-apiserver 443/tcp"
    "refused --reach-egress $RUNNER @kube-apiserver 6443/tcp"
    "refused --reach-egress $RUNNER @host 10250/tcp"
    "refused --reach-egress $RUNNER @remote-node 10250/tcp"
    "refused --reach-egress $RUNNER openbao/StatefulSet/openbao 8200/tcp"
    "refused --reach-egress $RUNNER $DNS 9153/tcp"
    "refused --reach-egress $RUNNER ai-system/Deployment/n8n 5678/tcp"
    "refused --reach-egress $RUNNER locust/Deployment/locust-master 8089/tcp"
    "refused --reach-egress $RUNNER $HELLO 22/tcp"
    "refused --reach-egress $RUNNER $HELLO 80/tcp"
    "refused --reach-egress $RUNNER $ASCENDER_WEB 8050/tcp"
    "refused --reach-egress $RUNNER $ASCENDER_TASK 8052/tcp"
    "refused --reach-egress $RUNNER $PROXY 10443/tcp"
    "refused --reach-egress $RUNNER $OTHER_APP 8080/tcp"
    "refused --reach-egress $RUNNER $OTHER_APP 80/tcp"
    # The runner writes the claim; it does not connect to the server, nor does any other pod of robot.
    "refused --reach $RUNNER $SERVER 8080/tcp"
    "refused --reach $STRAY $SERVER 8080/tcp"
    # The server sends nothing.
    "refused --reach-egress $SERVER $HELLO 8080/tcp"
    "refused --reach-egress $SERVER $DNS 53/udp"
    "refused --reach-egress $SERVER $DNS 53/tcp"
    "refused --reach-egress $SERVER $ASCENDER_WEB 8052/tcp"
    "refused --reach-egress $SERVER @world 443/tcp"
    "refused --reach-egress $SERVER @kube-apiserver 6443/tcp"
    "refused --reach-egress $SERVER $OTHER_APP 8080/tcp"
    # The server takes the kubelet's probe and no one else.
    "reaches --reach @host $SERVER 8080/tcp"
    "refused --reach @world $SERVER 8080/tcp"
    "refused --reach $PROXY $SERVER 8080/tcp"
    "refused --reach @remote-node $SERVER 8080/tcp"
    "refused --reach $OTHER_APP $SERVER 8080/tcp"
    "refused --reach-ingress $IMPOSTOR $SERVER 8080/tcp"
    # The runner takes nothing.
    "refused --reach-ingress @host $RUNNER 8080/tcp"
    "refused --reach-ingress $SERVER $RUNNER 8080/tcp"
    "refused --reach-ingress @world $RUNNER 443/tcp"
    # The targets' rules admit the runner alone of robot.
    "refused --reach-ingress $SERVER $HELLO 8080/tcp"
    "refused --reach-ingress $STRAY $HELLO 8080/tcp"
    "refused --reach-ingress $SERVER $ASCENDER_WEB 8052/tcp"
    "refused --reach-ingress $STRAY $ASCENDER_WEB 8052/tcp"
  )
  for flow in "${flows[@]}"; do
    read -r want side from to port <<<"$flow"
    "$want" "$side" "$from" "$to" "$port"
  done
}

@test "Robot Framework's targets are Services of the cluster read from the render, and each admits only the runner on its port" {
  local domain cronjob variables variable url pattern name ns port service selector target pods pod rules numbered pod_ns kind pod_name
  local checked=() policy file
  real_render
  # The cluster's DNS domain, as the nodes' machine configuration sets it.
  domain="$(yq -N 'select(.kind == "KubeNetworkConfig") | .dnsDomain' "$REPO/talos/patches/all/cluster-network.yaml")"
  [[ $domain =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$ ]]
  # The variables the runner hands Robot, as the render substitutes them: each the value after
  # --variable, NAME:URL.
  cronjob="$(rendered CronJob.batch_robot_robot-suites.yaml)"
  variables="$(yq -o json -I0 '.spec.jobTemplate.spec.template.spec.containers[0].args' "$cronjob" |
    jq -r '. as $a | range(0; length) | select($a[.] == "--variable") | $a[. + 1]')"
  [ "$(grep -c . <<<"$variables")" -eq 2 ]
  pattern="^http://([a-z0-9-]+)\\.([a-z0-9-]+)\\.svc\\.${domain//./\\.}:([0-9]+)\$"
  while IFS= read -r variable; do
    url="${variable#*:}"
    [[ $url =~ $pattern ]] || { echo "the target ${variable%%:*} is no Service of the cluster by its name and port: $url"; return 1; }
    name=${BASH_REMATCH[1]} ns=${BASH_REMATCH[2]} port=${BASH_REMATCH[3]}
    # Ascender's target is reached only by the piece that names Ascender, and is checked as the
    # render holds it.
    if [ "$ns" = ascender ] && [ ! -d "$REAL/lab-sto2/robot-ascender" ]; then continue; fi
    service="$(rendered "Service_${ns}_${name}.yaml")" || { echo "the target ${variable%%:*}, $ns/$name, is no Service of the render"; return 1; }
    selector="$(yq -o json -I0 '.spec.selector // {}' "$service")"
    [ "$(jq length <<<"$selector")" -gt 0 ] || { echo "the Service $ns/$name selects no pods by labels"; return 1; }
    target="$(P="$port" yq '.spec.ports[] | select(.port == env(P)) | .targetPort // .port' "$service")"
    [ -n "$target" ] || { echo "the Service $ns/$name has no port $port"; return 1; }
    # The pods the Service selects, among the workloads of the render in its namespace, and the
    # container port its port targets: a number, or the port of that name in the pods. Pods an
    # operator makes are in no render; a numbered port needs none, and the flows are asked of the
    # Service's labels in its namespace.
    pods="$(yq -o json -I0 '.' "$VIEW"/*/*/*.yaml | NS="$ns" jq -r --argjson selector "$selector" '
      select(.metadata.namespace == env.NS and (.kind | IN("Deployment", "StatefulSet", "DaemonSet")))
      | select(.spec.template.metadata.labels as $labels | $selector | to_entries | all($labels[.key] == .value))
      | .metadata.namespace + "/" + .kind + "/" + .metadata.name')"
    if [[ ! $target =~ ^[0-9]+$ ]]; then
      [ -n "$pods" ] || { echo "the Service $ns/$name names its port $target and selects no workload of the render"; return 1; }
      numbered=""
      for pod in $pods; do
        IFS=/ read -r pod_ns kind pod_name <<<"$pod"
        numbered+="$(T="$target" yq '.spec.template.spec.containers[].ports[] | select(.name == strenv(T)) | .containerPort' \
          "$(rendered "$kind.apps_${pod_ns}_$pod_name.yaml")")"$'\n'
      done
      target="$(grep . <<<"$numbered" | LC_ALL=C sort -u || true)"
    fi
    [[ $target =~ ^[0-9]+$ ]] || { echo "the Service $ns/$name sends port $port to no one numbered port of its pods: $target"; return 1; }
    [ -n "$pods" ] || pods="$ns:$(jq -r 'to_entries | map(.key + "=" + .value) | join(",")' <<<"$selector")"
    echo "the target $url is the Service $ns/$name, selecting $pods, on the container port $target"
    # The runner's egress to that namespace is one rule, of its policies, exactly the Service's pods
    # on that port.
    rules="$(for policy in robot-runner robot-runner-ascender; do
      file="$(compgen -G "$REAL/*/*/CiliumNetworkPolicy.cilium.io_robot_$policy.yaml" || true)"
      [ -z "$file" ] || yq -o json -I0 '.spec.egress // [] | .[]' "$file"
    done | NS="$ns" jq -c '
      select([(.toEndpoints // [])[] | .matchLabels["k8s:io.kubernetes.pod.namespace"] // .matchLabels["io.kubernetes.pod.namespace"]] | index(env.NS))
      | {"toEndpoints": [.toEndpoints[] | .matchLabels | with_entries(.key |= sub("^k8s:"; ""))], "toPorts": .toPorts, "other": (keys - ["toEndpoints", "toPorts"])}')"
    echo "the runner's egress to $ns: $rules"
    [ "$(grep -c . <<<"$rules")" -eq 1 ]
    [ "$(jq -cS '.toEndpoints' <<<"$rules")" = "$(NS="$ns" jq -cS '[{"io.kubernetes.pod.namespace": env.NS} + .]' <<<"$selector")" ]
    [ "$(jq -c '.toPorts' <<<"$rules")" = "[{\"ports\":[{\"port\":\"$target\",\"protocol\":\"TCP\"}]}]" ]
    [ "$(jq -c '.other' <<<"$rules")" = '[]' ]
    # The target takes the runner there, by its own policy, and not the server, another pod of robot
    # or a pod of another namespace with the runner's labels; nor does the runner reach another
    # port of it.
    for pod in $pods; do
      reaches --reach "$RUNNER" "$pod" "$target/tcp"
      reaches --reach-ingress "$RUNNER" "$pod" "$target/tcp"
      refused --reach-ingress "$SERVER" "$pod" "$target/tcp"
      refused --reach-ingress "$STRAY" "$pod" "$target/tcp"
      refused --reach-ingress "$IMPOSTOR" "$pod" "$target/tcp"
      refused --reach "$RUNNER" "$pod" 22/tcp
    done
    checked+=("${variable%%:*}=$ns/$name:$target")
  done <<<"$variables"
  echo "checked: ${checked[*]}"
  [ "${checked[*]}" = "HELLO_URL=demo/hello:8080 ASCENDER_URL=ascender/ascender-web:8052" ]
  # Without Ascender and the piece that names it, no rule of robot names Ascender.
  tree_without '/ascender(/|$)' '/robot/robot-ascender/ks.yaml$'
  built robot "$TREE"
  [ "$(yq -N 'select(.kind == "CiliumNetworkPolicy") | .metadata.name' "$BUILT" | LC_ALL=C sort | paste -sd' ' -)" = "robot-reports robot-runner" ]
  [ -z "$(yq -N 'select(.kind == "CiliumNetworkPolicy")' "$BUILT" | grep -i ascender || true)" ]
}

@test "Robot Framework runs the tree's suites every night at a time no other nightly job takes, and a failed test fails the job" {
  local spec cronjob job name kind schedule fields minute hours hour sds ads start length robot_start robot_end
  local windows=() window other_start other_end shift rule
  built robot
  workload CronJob robot-suites
  # The window of every nightly job of the render, from its start to its start with both its
  # deadlines for a CronJob, which a CronJob without one counts as nothing to start and 30 minutes to
  # run, and 30 minutes for a base backup or a volume backup; an hour of */N is each Nth hour from 0,
  # and an hour of * every hour, as the escape canary's checks run.
  real_render
  while IFS= read -r job; do
    kind="$(yq '.kind' "$job")" name="$(yq '.metadata.namespace + "/" + .metadata.name' "$job")"
    schedule="$(yq '.spec.schedule // .spec.trigger.schedule // ""' "$job")"
    read -ra fields <<<"$schedule"
    # CloudNativePG's schedules lead with the seconds.
    [ "$kind" != ScheduledBackup ] || fields=("${fields[@]:1}")
    if ((${#fields[@]} != 5)) || [[ ! ${fields[0]} =~ ^[0-9]{1,2}$ || ${fields[*]:2} != '* * *' ]]; then
      echo "$kind $name runs on '$schedule', which this test cannot give a window"
      return 1
    fi
    minute=$((10#${fields[0]}))
    if [[ ${fields[1]} =~ ^[0-9]{1,2}(,[0-9]{1,2})*$ ]]; then
      hours="${fields[1]//,/ }"
    elif [[ ${fields[1]} =~ ^\*/([1-9][0-9]?)$ ]]; then
      hours="$(seq 0 "${BASH_REMATCH[1]}" 23 | paste -sd' ' -)"
    elif [[ ${fields[1]} == '*' ]]; then
      hours="$(seq 0 23 | paste -sd' ' -)"
    else
      echo "$kind $name runs at the hours '${fields[1]}', which this test cannot read"
      return 1
    fi
    if [ "$kind" = CronJob ]; then
      sds="$(yq '.spec.startingDeadlineSeconds // 0' "$job")" ads="$(yq '.spec.jobTemplate.spec.activeDeadlineSeconds // 1800' "$job")"
      length=$((sds + ads))
    else
      length=1800
    fi
    for hour in $hours; do
      start=$(((10#$hour * 60 + minute) * 60))
      windows+=("$name $start $((start + length))")
    done
  done < <(find "$REAL" \( -name 'CronJob.batch_*' -o -name 'ScheduledBackup.postgresql.cnpg.io_*' -o -name 'ReplicationSource.volsync.backube_*' \) | LC_ALL=C sort)
  ((${#windows[@]} > 10))
  [ "$(printf '%s\n' "${windows[@]}" | grep -c '^robot/')" -eq 1 ]
  read -r _ robot_start robot_end <<<"$(printf '%s\n' "${windows[@]}" | grep '^robot/robot-suites ')"
  echo "robot-suites runs from $robot_start to $robot_end seconds of the day"
  for window in "${windows[@]}"; do
    read -r name other_start other_end <<<"$window"
    [ "$name" != robot/robot-suites ] || continue
    # A window that runs past midnight is compared with the next day's and the previous day's too.
    for shift in -86400 0 86400; do
      if ((other_start + shift < robot_end && robot_start < other_end + shift)); then
        echo "robot-suites overlaps $name, from $((other_start / 3600)):$((other_start % 3600 / 60)) for $(((other_end - other_start) / 60)) minutes"
        return 1
      fi
    done
  done
  # Its window is 05:45 to 06:10.
  [ "$robot_start" -eq $(((5 * 60 + 45) * 60)) ]
  [ "$robot_end" -eq $(((6 * 60 + 10) * 60)) ]
  # Once a day, as tests/network-audit.bats reads every CronJob of a namespace that denies by
  # default, at a time step 3 of Turning it on names.
  read -ra fields <<<"$(yq '.spec.schedule' "$(rendered CronJob.batch_robot_robot-suites.yaml)")"
  ((${#fields[@]} == 5))
  [[ ${fields[0]} =~ ^[0-9]{1,2}$ && ${fields[1]} =~ ^[0-9]{1,2}$ && ${fields[*]:2} == '* * *' ]]
  # Every night at 05:45 in the cluster's UTC, no second run while one runs, started within five
  # minutes of its time or skipped, one successful and three failed jobs kept.
  spec="$(yq -o json -I0 '.spec | del(.jobTemplate)' "$WORKLOAD")"
  [ "$(jq -cS . <<<"$spec")" = '{"concurrencyPolicy":"Forbid","failedJobsHistoryLimit":3,"schedule":"45 5 * * *","startingDeadlineSeconds":300,"successfulJobsHistoryLimit":1}' ]
  # The job: labelled as the runner, so a job made from the CronJob by hand carries the labels, no
  # retry of a failed pod, which would write a second dated directory, and an end after 20 minutes.
  [ "$(yq -o json -I0 '.spec.jobTemplate.metadata.labels' "$WORKLOAD" | jq -cS .)" = '{"app.kubernetes.io/component":"runner","app.kubernetes.io/name":"robot"}' ]
  [ "$(yq -o json -I0 '.spec.jobTemplate.spec | del(.template)' "$WORKLOAD" | jq -cS .)" = '{"activeDeadlineSeconds":1200,"backoffLimit":0}' ]
  # At the deadline the pod has the default 30 seconds to stop, which the docs and run.sh count on.
  [ "$(yq '.spec.jobTemplate.spec.template.spec.terminationGracePeriodSeconds' "$WORKLOAD")" = null ]
  [ "$(yq -o json -I0 '.metadata.labels' "$POD" | jq -cS .)" = '{"app.kubernetes.io/component":"runner","app.kubernetes.io/name":"robot"}' ]
  [ "$(yq '.spec.restartPolicy' "$POD")" = Never ]
  # The container's status is run.sh's, which is Robot's: the command runs the script and nothing
  # around it, and the arguments are the two targets as Robot variables, from ks.yaml, and nothing
  # that would change what Robot returns.
  [ "$(yq '.name' "$CONTAINER")" = robot ]
  [ "$(yq -o json -I0 '.command' "$CONTAINER")" = '["/bin/bash","/mnt/robot/scripts/run.sh"]' ]
  [ "$(yq -o json -I0 '.args' "$CONTAINER")" = "$(jq -cn --arg hello "HELLO_URL:$(yq '.spec.postBuild.substitute.ROBOT_TARGET_HELLO' "$KS")" \
    --arg ascender "ASCENDER_URL:$(yq '.spec.postBuild.substitute.ROBOT_TARGET_ASCENDER' "$KS")" '["--variable", $hello, "--variable", $ascender]')" ]
  # shellcheck disable=SC2016 # The variables are Flux's to substitute.
  [ "$(yq -o json -I0 '.spec.jobTemplate.spec.template.spec.containers[0].args' "$APP/app/cronjob.yaml")" \
    = '["--variable","HELLO_URL:${ROBOT_TARGET_HELLO}","--variable","ASCENDER_URL:${ROBOT_TARGET_ASCENDER}"]' ]
  # Its environment is HOME, the runs to keep and the job's name, which the Job controller gives its
  # pods as a label, and nothing Robot or the Browser library reads, whose variables start ROBOT_.
  [ "$(yq -o json -I0 '.env' "$CONTAINER")" \
    = '[{"name":"HOME","value":"/tmp"},{"name":"KEEP_RUNS","value":"30"},{"name":"JOB_NAME","valueFrom":{"fieldRef":{"fieldPath":"metadata.labels['"'"'batch.kubernetes.io/job-name'"'"']"}}}]' ]
  [ -z "$(containers "$BUILT" | jq -r '((.env // [])[] | .name | select(test("^ROBOT_"))), (select(.envFrom != null) | "\(.name): envFrom")')" ]
  # A failed run raises the monitoring chart's KubeJobFailed, a warning of every namespace after 15
  # minutes, which the docs name; no rule of Robot Framework's own.
  rule="$(yq -o json -I0 '.spec.groups[].rules[] | select(.alert == "KubeJobFailed")' "$(rendered PrometheusRule.monitoring.coreos.com_monitoring_kube-prometheus-stack-kubernetes-apps.yaml)")"
  [ "$(grep -c . <<<"$rule")" -eq 1 ]
  [ "$(jq -r '.for' <<<"$rule")" = 15m ]
  [ "$(jq -r '.labels.severity' <<<"$rule")" = warning ]
  [[ $(jq -r '.expr' <<<"$rule") == 'kube_job_failed{'*'namespace=~".*"}'*'> 0' ]]
  # shellcheck disable=SC2016 # The backticks are the docs' own.
  [[ $(section | flat) == *'`KubeJobFailed`'* ]]
  [ -z "$(cd "$REAL" && find . -name 'PrometheusRule.*' -exec grep -l 'robot' {} + || true)" ]
}

@test "A run writes its reports into a dated directory, lists the runs newest first and keeps the newest thirty" {
  local day name run expected pid tick
  fake_run
  # Every test passes: one run of robot, with its output in the run's directory, colours off, the
  # base suites on its path, the CronJob's variables and the suites' directory; the return code and
  # the job's name beside the reports; Robot's status as the script's.
  run_sh
  echo "passing: status $status; $output"
  [ "$status" -eq 0 ]
  run="$REPORTS/2026-11-18T054500Z"
  [ "$(cat "$STATE/robot-argv")" = "$(printf '%s\n' --outputdir "$run" --consolecolors off --pythonpath "$SUITES/base" \
    --variable HELLO_URL:http://hello.demo.svc.cluster.local:80 --variable ASCENDER_URL:http://ascender-web.ascender.svc.cluster.local:80 "$SUITES")" ]
  [[ $output == *'Suites'* ]]
  [ "$(cat "$run/status")" = 0 ]
  [ "$(cat "$run/job")" = robot-suites-29384750 ]
  [ -f "$run/report.html" ] && [ -f "$run/log.html" ] && [ -f "$run/output.xml" ]
  # The server reads the claim as another user: the run's directory, its files and the index are
  # readable by anyone.
  [ "$(stat -c %a "$run" "$run/status" "$run/job" "$REPORTS/index.html" | paste -sd' ' -)" = "755 644 644 644" ]
  [ "$(index_rows)" = "2026-11-18T054500Z passed" ]
  # The same time again is refused: a run never writes into another's directory.
  rm "$STATE/robot-argv"
  run_sh
  echo "again: status $status; $output"
  [ "$status" -eq 1 ]
  [[ $output == *"failed while making the run's directory"* ]]
  [ ! -e "$STATE/robot-argv" ]
  # Three tests fail, then Robot refuses its data: the script exits with Robot's code, and the index
  # says how many failed, or the error and what the user guide says it means.
  echo 2026-11-18T060000Z >"$STATE/stamp"
  echo 3 >"$STATE/rc"
  run_sh
  echo "three failed: status $status; $output"
  [ "$status" -eq 3 ]
  echo 2026-11-18T061500Z >"$STATE/stamp"
  echo 252 >"$STATE/rc"
  run_sh
  echo "invalid data: status $status; $output"
  [ "$status" -eq 252 ]
  [ "$(cat "$REPORTS/2026-11-18T061500Z/status")" = 252 ]
  index_rows
  [ "$(index_rows)" = "$(printf '%s\n' '2026-11-18T061500Z error 252 / Invalid data or command line option.' \
    '2026-11-18T060000Z 3 failed' '2026-11-18T054500Z passed')" ]
  # Plain HTML: no script, no style or page from elsewhere, and every link relative, to a run's report
  # and log.
  if grep -niE '<script|<link|<iframe|<img|<object|<embed|https?:|//|src=' "$REPORTS/index.html"; then return 1; fi
  [ "$(grep -o 'href="[^"]*"' "$REPORTS/index.html" | LC_ALL=C sort | paste -sd' ' -)" = "$(printf 'href="%s/%s.html"\n' \
    2026-11-18T054500Z log 2026-11-18T054500Z report 2026-11-18T060000Z log 2026-11-18T060000Z report 2026-11-18T061500Z log 2026-11-18T061500Z report | LC_ALL=C sort | paste -sd' ' -)" ]
  # A step after Robot fails, as on a claim that refuses writes: each names itself, and the script
  # exits 1 when every test passed and with Robot's code when tests failed.
  echo 2026-11-18T063000Z >"$STATE/stamp"
  echo 0 >"$STATE/rc"
  echo run >"$STATE/lock"
  run_sh
  echo "passing, the run's directory refusing writes: status $status; $output"
  [ "$status" -eq 1 ]
  [[ $output == *"failed while writing the run's status and job into $REPORTS/2026-11-18T063000Z"* ]]
  echo 2026-11-18T064500Z >"$STATE/stamp"
  echo 3 >"$STATE/rc"
  run_sh
  echo "three failed, the run's directory refusing writes: status $status; $output"
  [ "$status" -eq 3 ]
  [[ $output == *"failed while writing the run's status and job into $REPORTS/2026-11-18T064500Z"* ]]
  echo 2026-11-18T070000Z >"$STATE/stamp"
  echo 0 >"$STATE/rc"
  echo reports >"$STATE/lock"
  RUN_ENVIRONMENT+=(KEEP_RUNS=2)
  run_sh
  unset 'RUN_ENVIRONMENT[-1]'
  rm "$STATE/lock"
  echo "passing, the claim's root refusing writes: status $status; $output"
  [ "$status" -eq 1 ]
  [[ $output == *"failed while removing the run 2026-11-18T054500Z, older than the newest 2"* ]]
  [[ $output == *"failed while writing $REPORTS/index.html"* ]]
  # The job's deadline: the kubelet stops the pod with SIGTERM, which bash, the container's first
  # process, would ignore were it not caught. The script passes it on to Robot, which here returns at
  # once what it counts failed; the script then writes the status and the index and exits with that
  # code. A Robot still running when the pod's grace ends is killed with the pod, as below.
  echo 2026-11-18T073000Z >"$STATE/stamp"
  echo 4 >"$STATE/rc"
  touch "$STATE/robot-waits"
  env -i "${RUN_ENVIRONMENT[@]}" /bin/bash "$APP/app/run.sh" --variable HELLO_URL:http://hello.demo.svc.cluster.local:80 3>&- &
  pid=$!
  for ((tick = 0; tick < 200; tick++)); do
    if [ -e "$STATE/robot-ready" ] && (($(printf '%d' "0x$(awk '$1 == "SigCgt:" { print $2 }' "/proc/$pid/status")") >> 14 & 1)); then break; fi
    sleep 0.1
  done
  [ -e "$STATE/robot-ready" ] || { echo "robot did not start"; return 1; }
  (($(printf '%d' "0x$(awk '$1 == "SigCgt:" { print $2 }' "/proc/$pid/status")") >> 14 & 1)) || { kill -KILL "$pid"; echo "run.sh does not take SIGTERM while Robot runs"; return 1; }
  kill -TERM "$pid"
  status=0
  wait "$pid" || status=$?
  rm "$STATE/robot-waits" "$STATE/robot-ready"
  echo "SIGTERM: status $status"
  [ "$status" -eq 4 ]
  [ "$(cat "$STATE/robot-signals")" = SIGTERM ]
  [ "$(cat "$REPORTS/2026-11-18T073000Z/status")" = 4 ]
  [ "$(index_rows | head -1)" = "2026-11-18T073000Z 4 failed" ]
  # A pod killed before the script wrote the status leaves its directory with neither the status nor
  # the job nor Robot's reports: the next run lists it without a result.
  mkdir "$REPORTS/2026-11-18T074500Z"
  : >"$REPORTS/2026-11-18T074500Z/output.xml"
  echo 2026-11-18T080000Z >"$STATE/stamp"
  echo 0 >"$STATE/rc"
  run_sh
  echo "after a killed run: status $status; $output"
  [ "$status" -eq 0 ]
  [ "$(index_rows | sed -n 2p)" = "2026-11-18T074500Z no result / The run is still going, or ended before Robot did." ]
  # Over thirty-two runs and stray names: the oldest go, down to thirty with the new one, and nothing
  # that is not a run's directory goes, whatever its name sorts as.
  rm -rf "$REPORTS"
  mkdir -p "$REPORTS"
  for ((day = 1; day <= 32; day++)); do
    name="$(printf '2026-10-%02dT054500Z' "$day")"
    mkdir "$REPORTS/$name"
    echo 0 >"$REPORTS/$name/status"
    echo "robot-suites-$day" >"$REPORTS/$name/job"
  done
  mkdir "$REPORTS/lost+found" "$REPORTS/2020-01-01T000000Z-kept" "$REPORTS/0000-01-01T000000Z.old" "$REPORTS/2026-10-01T0545Z"
  echo stray >"$REPORTS/notes.txt"
  echo 2026-11-18T054500Z >"$STATE/stamp"
  echo 0 >"$STATE/rc"
  run_sh
  echo "thirty-two runs: status $status; $output"
  [ "$status" -eq 0 ]
  expected="$( (echo 2026-11-18T054500Z; for ((day = 32; day >= 4; day--)); do printf '2026-10-%02dT054500Z\n' "$day"; done) | LC_ALL=C sort)"
  [ "$(find "$REPORTS" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z' -printf '%f\n' | LC_ALL=C sort)" = "$expected" ]
  for name in lost+found 2020-01-01T000000Z-kept 0000-01-01T000000Z.old 2026-10-01T0545Z notes.txt; do
    [ -e "$REPORTS/$name" ] || { echo "the stray $name was removed"; return 1; }
  done
  [ "$(index_rows | grep -c .)" -eq 30 ]
  [ "$(index_rows | cut -d' ' -f1)" = "$(LC_ALL=C sort -r <<<"$expected")" ]
  [ "$(index_rows | sed -n 2p)" = "2026-10-32T054500Z passed" ]
  # Over thirty runs whose names sort after the new one's, as after the clock stepped back: the new
  # run is kept and listed, with the newest twenty-nine of the others.
  rm -rf "$REPORTS"
  mkdir -p "$REPORTS"
  for ((day = 1; day <= 30; day++)); do
    name="$(printf '2027-01-%02dT054500Z' "$day")"
    mkdir "$REPORTS/$name"
    echo 0 >"$REPORTS/$name/status"
  done
  echo 2026-11-18T054500Z >"$STATE/stamp"
  run_sh
  echo "after the clock stepped back: status $status; $output"
  [ "$status" -eq 0 ]
  [ -f "$REPORTS/2026-11-18T054500Z/report.html" ]
  expected="$( (echo 2026-11-18T054500Z; for ((day = 30; day >= 2; day--)); do printf '2027-01-%02dT054500Z\n' "$day"; done) | LC_ALL=C sort)"
  [ "$(find "$REPORTS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort)" = "$expected" ]
  [ "$(index_rows | cut -d' ' -f1)" = "$(LC_ALL=C sort -r <<<"$expected")" ]
  # Another option than a variable is refused before robot runs, so the CronJob's arguments cannot
  # turn off Robot's status or select fewer tests.
  for option in --nostatusrc --dryrun '--include smoke' '--exclude ui' '--variable lower:value' '--variable HELLO_URL' '--variablefile x.py'; do
    rm -f "$STATE/robot-argv"
    # shellcheck disable=SC2086 # Each option is its words.
    run_sh --variable HELLO_URL:http://hello.demo.svc.cluster.local:80 $option
    echo "$option: status $status; $output"
    [ "$status" -eq 2 ]
    [[ $output == *"takes only --variable NAME:VALUE pairs"* ]]
    [ ! -e "$STATE/robot-argv" ]
  done
  # A claim it cannot make the run's directory in, a file where the claim's directory should be,
  # which refuses root as well: nothing runs, and the step is named.
  rm -rf "$REPORTS"
  : >"$REPORTS"
  echo 2026-11-19T054500Z >"$STATE/stamp"
  run_sh
  echo "unwritable: status $status; $output"
  [ "$status" -eq 1 ]
  [[ $output == *"failed while making the run's directory $REPORTS/2026-11-19T054500Z"* ]]
  [ ! -e "$STATE/robot-argv" ]
  # As the container runs it, the claim is /reports.
  RUN_ENVIRONMENT=("${RUN_ENVIRONMENT[@]/#REPORTS_DIR=*/REPORTS_UNSET=1}")
  run_sh
  echo "default: status $status; $output"
  [ "$status" -eq 1 ]
  [[ $output == *"failed while making the run's directory /reports/2026-11-19T054500Z"* ]]
}

@test "The runner and the report server share one claim on one node, the server reading it only" {
  local server labels
  built robot
  # One claim, of one node at a time, on the default StorageClass, which makes the volume for the
  # first pod that uses it.
  [ "$(yq -N 'select(.kind == "PersistentVolumeClaim") | .metadata.name' "$BUILT")" = robot-reports ]
  [ "$(object "$BUILT" PersistentVolumeClaim robot-reports | yq -o json -I0 '.spec' | jq -cS .)" \
    = '{"accessModes":["ReadWriteOnce"],"resources":{"requests":{"storage":"1Gi"}}}' ]
  # One server, replaced rather than rolled, as a new pod on another node would wait for the volume
  # the old one holds.
  workload Deployment robot-reports
  server="$(yq -o json -I0 '.' "$WORKLOAD")"
  labels="$(jq -cS '.spec.template.metadata.labels' <<<"$server")"
  [ "$labels" = '{"app.kubernetes.io/component":"reports","app.kubernetes.io/name":"robot"}' ]
  [ "$(jq -r '.spec.replicas' <<<"$server")" = 1 ]
  [ "$(jq -c '.spec.strategy' <<<"$server")" = '{"type":"Recreate"}' ]
  [ "$(jq -cS '.spec.selector.matchLabels' <<<"$server")" = "$labels" ]
  [ "$(yq '.name' "$CONTAINER")" = httpd ]
  [ "$(yq -o json -I0 '.command' "$CONTAINER")" = '["httpd","-f","-v","-p","8080","-h","/reports"]' ]
  [ "$(yq '.args // [] | length' "$CONTAINER")" -eq 0 ]
  [ "$(yq -o json -I0 '.ports' "$CONTAINER" | jq -cS .)" = '[{"containerPort":8080,"name":"http"}]' ]
  # Ready once it takes a connection: / is 404 until a run writes the index, and a probe that waited
  # for one would hold the Kustomization's wait until the night's run.
  [ "$(yq -o json -I0 '.readinessProbe' "$CONTAINER" | jq -cS .)" = '{"tcpSocket":{"port":"http"}}' ]
  [ "$(yq '[.livenessProbe, .startupProbe] | map(select(. != null)) | length' "$CONTAINER")" -eq 0 ]
  # The claim writable in the volume, as the runner's is, and read-only in the container's mount. The
  # kubelet hands the CSI driver each pod's volume read-only or not as its persistentVolumeClaim
  # says, the LINSTOR driver mounts the device itself for each pod, and Linux refuses a second mount
  # of a device with the other read-only state: a read-only volume here would keep the runner's pod
  # from its claim. The container's read-only mount is a bind the runtime makes over the pod's, so
  # the server still cannot write.
  [ "$(yq -o json -I0 '.spec.volumes' "$POD" | jq -cS .)" = '[{"name":"reports","persistentVolumeClaim":{"claimName":"robot-reports"}}]' ]
  [ "$(yq -o json -I0 '.volumeMounts' "$CONTAINER" | jq -cS .)" = '[{"mountPath":"/reports","name":"reports","readOnly":true}]' ]
  # The Service selects the server's pods on its port.
  [ "$(yq -N 'select(.kind == "Service") | .metadata.name' "$BUILT")" = robot-reports ]
  [ "$(object "$BUILT" Service robot-reports | yq -o json -I0 '.spec' | jq -cS .)" \
    = "{\"ports\":[{\"name\":\"http\",\"port\":8080,\"targetPort\":\"http\"}],\"selector\":$labels}" ]
  # The runner's pod requires the node a pod with the server's labels runs on, where the kubelet
  # mounts the same volume for both, and mounts the claim there writable.
  workload CronJob robot-suites
  [ "$(yq -o json -I0 '.spec.affinity' "$POD" | jq -cS .)" \
    = "{\"podAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":[{\"labelSelector\":{\"matchLabels\":$labels},\"topologyKey\":\"kubernetes.io/hostname\"}]}}" ]
  [ "$(yq -o json -I0 '.spec.volumes[] | select(.persistentVolumeClaim != null)' "$POD" | jq -cS .)" = '{"name":"reports","persistentVolumeClaim":{"claimName":"robot-reports"}}' ]
  [ "$(yq -o json -I0 '.volumeMounts[] | select(.name == "reports")' "$CONTAINER" | jq -cS .)" = '{"mountPath":"/reports","name":"reports"}' ]
  # Every pod that mounts the claim publishes it in the same state, writable, so the driver can
  # mount it for each of them on the one node.
  [ "$(pod_specs "$BUILT" | jq -c '[(.volumes // [])[] | select(.persistentVolumeClaim.claimName == "robot-reports") | .persistentVolumeClaim.readOnly // false]' | paste -sd' ' -)" \
    = '[false] [false]' ]
}

@test "The suites check hello over HTTP and in a browser and Ascender's sign-in page, and hold no credential and sign in nowhere" {
  local cm name data file key mount found files
  built robot
  # The suites and the script: one ConfigMap each, by a hashed name, so a change gives the CronJob a
  # new one, from the files and holding them byte for byte, with Flux's substitution off, as Robot's
  # ${...} and bash's are Flux's syntax.
  [ "$(yq -N 'select(.kind == "ConfigMap") | .metadata.name' "$BUILT" | grep -c .)" -eq 2 ]
  for name in robot-suites:common.resource,hello-http.robot,hello-ui.robot robot-scripts:run.sh; do
    cm="$(yq -N -o json -I0 'select(.kind == "ConfigMap")' "$BUILT" | jq -c --arg prefix "${name%%:*}-" 'select(.metadata.name | startswith($prefix))')"
    [ "$(grep -c . <<<"$cm")" -eq 1 ]
    [[ $(jq -r '.metadata.name' <<<"$cm") =~ ^${name%%:*}-[a-z0-9]{10}$ ]]
    [ "$(jq -r '.metadata.annotations["kustomize.toolkit.fluxcd.io/substitute"]' <<<"$cm")" = disabled ]
    [ "$(jq -r '.data | keys | join(",")' <<<"$cm")" = "${name#*:}" ]
    IFS=, read -ra files <<<"${name#*:}"
    for key in "${files[@]}"; do
      data="$BATS_TEST_TMPDIR/$key"
      jq -j --arg key "$key" '.data[$key]' <<<"$cm" >"$data"
      if [ "$key" = run.sh ]; then cmp "$data" "$APP/app/run.sh"; else cmp "$data" "$APP/app/suites/$key"; fi
    done
  done
  [ "$(yq -o json -I0 '.configMapGenerator | map(del(.options)) | sort_by(.name)' "$APP/app/kustomization.yaml" | jq -c .)" \
    = '[{"name":"robot-scripts","files":["run.sh"]},{"name":"robot-suites","files":["suites/common.resource","suites/hello-http.robot","suites/hello-ui.robot"]}]' ]
  # The runner mounts each read-only and whole where run.sh and Robot read them, and the Ascender
  # suite's ConfigMap, which another Kustomization makes, under its fixed name and optional, so the
  # directory is empty without it.
  workload CronJob robot-suites
  for mount in "robot-suites-:/mnt/robot/suites/base" "robot-scripts-:/mnt/robot/scripts" "robot-suite-ascender:/mnt/robot/suites/ascender"; do
    # shellcheck disable=SC2016 # $pod and $n are yq variables.
    found="$(PREFIX="${mount%%:*}" yq '.spec as $pod | $pod.containers[0].volumeMounts[]
      | select(.name as $n | $pod.volumes[] | select(.name == $n and (.configMap.name | test("^" + strenv(PREFIX))) and (.configMap.items == null)))
      | select(.readOnly == true and .subPath == null) | .mountPath' "$POD")"
    [ "$found" = "${mount#*:}" ] || { echo "${mount%%:*} is mounted at '$found'"; return 1; }
  done
  [ "$(yq -o json -I0 '.spec.volumes[] | select(.configMap.name == "robot-suite-ascender") | .configMap' "$POD")" = '{"name":"robot-suite-ascender","optional":true}' ]
  built robot-ascender
  [ "$(yq -N 'select(. != null) | .kind + "/" + .metadata.name' "$BUILT" | LC_ALL=C sort | paste -sd' ' -)" = "CiliumNetworkPolicy/robot-runner-ascender ConfigMap/robot-suite-ascender" ]
  cm="$(object "$BUILT" ConfigMap robot-suite-ascender | yq -o json -I0 '.')"
  [ "$(jq -r '.metadata.annotations["kustomize.toolkit.fluxcd.io/substitute"]' <<<"$cm")" = disabled ]
  [ "$(jq -c '.data | keys' <<<"$cm")" = '["ascender-ui.robot"]' ]
  jq -j '.data["ascender-ui.robot"]' <<<"$cm" >"$BATS_TEST_TMPDIR/ascender-ui.robot"
  cmp "$BATS_TEST_TMPDIR/ascender-ui.robot" "$PIECE/app/suites/ascender-ui.robot"
  [ "$(yq -o json -I0 '.configMapGenerator' "$PIECE/app/kustomization.yaml" | jq -c 'map(del(.options.annotations))')" \
    = '[{"name":"robot-suite-ascender","files":["suites/ascender-ui.robot"],"options":{"disableNameSuffixHash":true}}]' ]
  # Each file starts with a comment that says what it checks, and each suite finds the shared
  # keywords by name, through --pythonpath.
  for file in $(suite_files); do
    head -1 "$file" | grep -q '^# ' || { echo "$file does not start with a comment"; return 1; }
    [[ $file == *.resource ]] || [ "$(code "$file" | grep -cE ': Resource {2,}common\.resource$')" -eq 1 ] || { echo "$file does not import common.resource by name"; return 1; }
  done
  # The shared keywords: a headless Chromium, its context and a page, and a teardown that closes it.
  file="$APP/app/suites/common.resource"
  code "$file" | grep -qE ': {2,}New Browser {2,}chromium {2,}headless=True$'
  code "$file" | grep -qE ': {2,}New Context$'
  code "$file" | grep -qE ': {2,}New Page {2,}\$\{url\}$'
  code "$file" | grep -qE ': {2,}Close Browser {2,}ALL$'
  # hello over HTTP, by Http after opening its page, of paths of the page's own origin.
  file="$APP/app/suites/hello-http.robot"
  code "$file" | grep -qE ': Suite Setup {2,}Open Target {2,}\$\{HELLO_URL\}$'
  [ "$(code "$file" | grep -oE 'Http {2,}[^ ]+ {2,}GET' | paste -sd'|' -)" = 'Http    /    GET|Http    /robot-no-such-page    GET' ]
  code "$file" | grep -qE 'Should Be Equal As Integers {2,}\$\{response\}\[status\] {2,}200$'
  code "$file" | grep -qE 'Should Contain {2,}\$\{response\}\[body\] {2,}hello$'
  code "$file" | grep -qE 'Should Be Equal As Integers {2,}\$\{response\}\[status\] {2,}404$'
  # hello in the browser: the page's text, and a screenshot in the report.
  file="$APP/app/suites/hello-ui.robot"
  code "$file" | grep -qE ': Suite Setup {2,}Open Target {2,}\$\{HELLO_URL\}$'
  code "$file" | grep -qE ': {2,}Get Text {2,}body {2,}contains {2,}hello$'
  code "$file" | grep -qE ': {2,}Take Screenshot$'
  # Ascender's sign-in form: the two fields by their labels and the button by its role and name,
  # the strings of the pinned image's interface, and a screenshot.
  file="$PIECE/app/suites/ascender-ui.robot"
  code "$file" | grep -qE ': Suite Setup {2,}Open Target {2,}\$\{ASCENDER_URL\}$'
  # The interface draws the form once its script has run: before the first lookup the test gives
  # the library's lookups and waits a minute, where the library's default is 10 seconds.
  code "$file" | grep -E 'Set Browser Timeout|Get Element By' | head -1 | grep -qE ': {2,}Set Browser Timeout {2,}60s {2,}scope=Test$'
  code "$file" | grep -qE 'Get Element By {2,}Label {2,}Username$'
  code "$file" | grep -qE 'Get Element By {2,}Label {2,}Password$'
  code "$file" | grep -qE 'Get Element By Role {2,}button {2,}name=Log In$'
  code "$file" | grep -qE ': {2,}Take Screenshot$'
  # The variables the suites read are those the CronJob hands Robot, and none else.
  # shellcheck disable=SC2016 # The variables are Robot's.
  [ "$(suite_files | while IFS= read -r file; do cat "$file"; done | grep -oE '\$\{[A-Z][A-Z0-9_]*\}' | LC_ALL=C sort -u | paste -sd' ' -)" = '${ASCENDER_URL} ${HELLO_URL}' ]
  # The check of the suites' text, a lint and no confinement: tab, line feed and printable ASCII
  # alone, in the space-separated format, no library but Browser, no keyword but those listed or
  # defined, so none that types, clicks, presses, uploads, evaluates or runs a program, no assertion
  # operator that evaluates Python spelled out by position or any given by name, no request but a
  # GET of a literal path of the page's origin, with no variable or escape in it, no page but a
  # target's, no inline Python, no sandbox, no variable of the environment, no address with ://, and
  # no word of a secret outside a comment and the labels the Ascender suite asserts.
  for file in $(suite_files); do
    found="$(code "$file" | grep -inE '(^|: |  )(Fill Text|Fill Secret|Type Text|Type Secret|Click|Click With Options|Press Keys|Keyboard Key|Keyboard Input|Upload File|Upload File By Selector)( |$)' || true)"
    [ -z "$found" ] || { echo "$found"; return 1; }
    found="$(code "$file" | grep -iE '(^|  )Http( |$)' | grep -vE 'Http {2,}/([^/\\$@&%{ ][^ \\$@&%{]*)? {2,}GET$' || true)"
    [ -z "$found" ] || { echo "a request that is not a GET of a literal path: $found"; return 1; }
    found="$(refused_calls "$file")"
    [ -z "$found" ] || { echo "refused: $found"; return 1; }
    found="$(grep -niE 'chromiumSandbox|%\{|https?://' "$file" || true)"
    [ -z "$found" ] || { echo "$file: $found"; return 1; }
    found="$(code "$file" | sed -E 's/(Get Element By {2,}Label {2,})Password$/\1<label>/' | grep -inE 'password|passwd|token|secret|authorization|cookie' || true)"
    [ -z "$found" ] || { echo "$found"; return 1; }
  done
  # No pod reads a Secret.
  built robot
  [ -z "$(containers "$BUILT" | jq -r '(.env // [])[] | select(.valueFrom.secretKeyRef != null) | .name')" ]
  [ -z "$(containers "$BUILT" | jq -r 'select(.envFrom != null) | .name')" ]
  [ -z "$(pod_specs "$BUILT" | jq -r '.volumes // [] | .[] | select(.secret != null or .projected != null) | .name')" ]
  [ -z "$(yq -N 'select(.kind == "Secret" or .kind == "ExternalSecret") | .kind' "$BUILT")" ]
}

@test "Nothing routes to Robot Framework's reports or scrapes them" {
  local named
  built robot
  overlay
  real_render
  # What it applies is its workloads, their Service, its claim, its ConfigMaps and its policies, and
  # no route, probe, monitor, rule or dashboard, nothing of the Gateway API or Envoy Gateway's.
  [ "$(yq -N 'select(. != null) | .kind' "$BUILT" | LC_ALL=C sort -u | paste -sd' ' -)" = "CiliumNetworkPolicy ConfigMap CronJob Deployment PersistentVolumeClaim Service" ]
  [ -z "$(yq -N 'select(.kind | test("^(HTTPRoute|GRPCRoute|TLSRoute|TCPRoute|UDPRoute|Probe|ServiceMonitor|PodMonitor|PrometheusRule|GrafanaDashboard)$")) | .kind' "$BUILT")" ]
  [ -z "$(yq -N 'select(.apiVersion | test("^gateway\\.(networking\\.k8s\\.io|envoyproxy\\.io)/")) | .kind' "$BUILT")" ]
  # The namespace carries no Gateway label, so no route of it may attach to the public Gateway, and
  # the Service is of the cluster alone, with no external address and no label that would announce
  # it.
  [ "$(object "$OVERLAY" Namespace "$NAMESPACE" | yq '.metadata.labels | has("k8s-gitops/gateway")')" = false ]
  [ "$(object "$BUILT" Service robot-reports | yq -o json -I0 '.' | jq -c '[.spec.type // "ClusterIP", (.spec.externalIPs // [] | length),
    (.metadata.labels // {} | has("k8s-gitops/announce")), (.metadata.annotations // {} | keys | map(select(startswith("lbipam.cilium.io/"))))]')" \
    = '["ClusterIP",0,false,[]]' ]
  # Its pods ask for no scrape: neither serves metrics.
  [ -z "$(yq -o json -I0 'select(. != null)' "$BUILT" | jq -r 'select(.spec.template != null or .spec.jobTemplate != null)
    | (.spec.jobTemplate.spec.template // .spec.template).metadata.annotations // {} | keys[]')" ]
  built robot-ascender
  [ "$(yq -N 'select(. != null) | .kind' "$BUILT" | LC_ALL=C sort -u | paste -sd' ' -)" = "CiliumNetworkPolicy ConfigMap" ]
  # No route, grant or monitor of the whole render names robot, wherever it is.
  named="$(cd "$REAL" && find . -type f \( -name 'HTTPRoute.*' -o -name 'GRPCRoute.*' -o -name 'TLSRoute.*' -o -name 'TCPRoute.*' \
    -o -name 'UDPRoute.*' -o -name 'ReferenceGrant.*' -o -name 'ServiceMonitor.*' -o -name 'PodMonitor.*' -o -name 'Probe.*' \
    -o -name 'ScrapeConfig.*' -o -name 'PrometheusRule.*' -o -name 'GrafanaDashboard.*' \) -exec grep -lw 'robot' {} + || true)"
  [ -z "$named" ] || { echo "these name robot: $named"; return 1; }
  [ -z "$(cd "$REAL" && find . -type f -name '*_robot_*' ! -name '*Policy*' ! -name 'Deployment.apps_*' ! -name 'CronJob.batch_*' \
    ! -name 'Service_*' ! -name 'ConfigMap_*' ! -name 'PersistentVolumeClaim_*' -printf '%f\n')" ]
}

@test "just robot-run starts one run from the CronJob, follows its log and exits with its result" {
  local script_pid
  recipe_copy
  # A run that passes: the runner's jobs, one job from the CronJob, its pod out of Pending, its log,
  # its condition and its container's code, in that order and nothing else.
  recipe robot-run
  echo "passing: status $status; $output"
  [ "$status" -eq 0 ]
  [ "$(cat "$RECORD/argv")" = "$(printf '%s\n' \
    'get jobs --namespace robot --selector app.kubernetes.io/name=robot,app.kubernetes.io/component=runner --output json' \
    "create job --namespace robot --from=cronjob/robot-suites $JOB" \
    "get pods --namespace robot --selector batch.kubernetes.io/job-name=$JOB --output json" \
    "logs --namespace robot --follow job/$JOB" \
    "get job --namespace robot $JOB --output json" \
    "get pods --namespace robot --selector batch.kubernetes.io/job-name=$JOB --output json")" ]
  [ "$(sort -u "$RECORD/kubeconfig")" = "$KUBECONFIG_FILE" ]
  [[ $output == *"Starting job $JOB from cronjob/robot-suites in robot."* ]]
  [[ $output == *"3 tests, 3 passed, 0 failed"* ]]
  [[ $output == *"Every test passed."* ]]
  [[ $output == *"just robot"* ]]
  if grep -qF 'created' <<<"$output"; then echo "kubectl's own output was printed"; return 1; fi
  # The log's connection breaks with an error that names the API server's address: it says the
  # following stopped, prints none of kubectl's words and reads the result all the same.
  rm "$RECORD/argv" "$STATE/pods.count"
  touch "$STATE/logs-fails"
  recipe robot-run
  rm "$STATE/logs-fails"
  echo "log broken: status $status; $output"
  [ "$status" -eq 0 ]
  [[ $output == *"kubectl logs stopped with status 1; the job's result follows"* ]]
  [[ $output == *"Every test passed."* ]]
  [[ $output != *192.0.2.10* ]]
  # Two tests fail: the container's code is the script's.
  rm "$RECORD/argv" "$STATE/pods.count"
  pods Failed 2 >"$STATE/pods.json"
  job_condition Failed BackoffLimitExceeded >"$STATE/job.json"
  recipe robot-run
  echo "two failed: status $status; $output"
  [ "$status" -eq 2 ]
  [[ $output == *"2 tests failed."* ]]
  [[ $output != *"Every test passed."* ]]
  # Its deadline ends the run: the pod goes with no code, and the job's reason is the result.
  rm "$RECORD/argv" "$STATE/pods.count"
  pods Running >"$STATE/pods.1.json"
  pods >"$STATE/pods.json"
  job_condition Failed DeadlineExceeded >"$STATE/job.json"
  recipe robot-run
  echo "deadline: status $status; $output"
  [ "$status" -eq 1 ]
  [[ $output == *"DeadlineExceeded"* ]]
  [[ $output == *"Job was active longer than specified deadline"* ]]
  [[ $output != *"tests failed."* && $output != *"Every test passed."* ]]
  # The create fails with an error that names the API server's address: the step is named, and none
  # of kubectl's words are printed.
  rm "$RECORD/argv" "$STATE/pods.count" "$STATE/pods.1.json"
  touch "$STATE/create-fails"
  recipe robot-run
  echo "create failing: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"failed while creating the job"* ]]
  [[ $output != *192.0.2.10* ]]
  [ "$(grep -c . "$RECORD/argv")" -eq 2 ]
  rm "$STATE/create-fails"
  # Ctrl-C while it follows: it stops following, says the job goes on and how to follow it again,
  # and deletes nothing.
  rm "$RECORD/argv"
  pods Running >"$STATE/pods.json"
  touch "$STATE/logs-hangs"
  recipe_start robot-run
  printed '3 tests, 3 passed, 0 failed'
  read -r _ script_pid <"$STATE/pids"
  kill -INT "$script_pid" "$JUST_PID"
  finished
  echo "after Ctrl-C: status $STATUS; $(cat "$OUT")"
  [ "$STATUS" -eq 130 ]
  kubectl_gone
  [ "$(cat "$RECORD/ended")" = SIGTERM ]
  grep -qF "The job $JOB goes on in the cluster" "$OUT"
  grep -qF "logs --follow job/$JOB" "$OUT"
  if grep -q '^delete' "$RECORD/argv"; then echo "kubectl was asked to delete"; return 1; fi
  [ "$(tail -1 "$RECORD/argv")" = "logs --namespace robot --follow job/$JOB" ]
}

@test "just robot-run refuses while a run is active and needs the cluster's kubeconfig and a wait" {
  local wait
  recipe_copy
  # A job of the runner still has a pod: refused, naming it, and nothing is created.
  jq -n '{"items": [{"metadata": {"name": "robot-suites-29384750"}, "status": {"active": 1}}, {"metadata": {"name": "robot-run-20261117-101010"}, "status": {"succeeded": 1}}]}' >"$STATE/jobs.json"
  recipe robot-run
  echo "active: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"robot-suites-29384750"* ]]
  [[ $output != *"robot-run-20261117-101010"* ]]
  [ "$(cat "$RECORD/argv")" = 'get jobs --namespace robot --selector app.kubernetes.io/name=robot,app.kubernetes.io/component=runner --output json' ]
  # The pod never leaves Pending within the wait: it fails, saying so, and that the job goes on.
  rm "$RECORD/argv"
  echo '{"items": []}' >"$STATE/jobs.json"
  pods Pending >"$STATE/pods.json"
  with ROBOT_RUN_WAIT=1
  recipe robot-run
  echo "pending: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"did not leave Pending within 1 seconds"* ]]
  [[ $output == *"The job $JOB goes on in the cluster"* ]]
  if grep -q '^logs\|^delete' "$RECORD/argv"; then echo "it followed or deleted: $(cat "$RECORD/argv")"; return 1; fi
  # No kubeconfig, an argument too many and a wait that is no whole number of seconds from 1 to 9999:
  # each named, and no kubectl runs.
  rm "$RECORD/argv" "$KUBECONFIG_FILE"
  only ROBOT_RUN_WAIT=soon
  recipe robot-run
  echo "no kubeconfig: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/clusterconfig/kubeconfig does not exist; just cluster-kubeconfig fetches it"* ]]
  [[ $output == *"ROBOT_RUN_WAIT is not a whole number of seconds from 1 to 9999"* ]]
  echo 'not a real kubeconfig' >"$KUBECONFIG_FILE"
  for wait in 0 10000 08x -1; do
    only ROBOT_RUN_WAIT="$wait"
    recipe robot-run
    echo "ROBOT_RUN_WAIT='$wait': status $status; $output"
    [ "$status" -ne 0 ]
    [[ $output == *"ROBOT_RUN_WAIT is not a whole number of seconds from 1 to 9999"* ]]
  done
  only
  run timeout 60 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$REPO/justfile" --working-directory "$COPY" robot-run lab-sto2 again
  echo "two arguments: status $status; $output"
  [ "$status" -ne 0 ]
  run timeout 60 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" "$COPY/scripts/robot-run" lab-sto2 again
  echo "the script with two arguments: status $status; $output"
  [ "$status" -eq 2 ]
  [[ $output == *"usage: robot-run [cluster]"* ]]
  [ ! -e "$RECORD/argv" ]
}

@test "just robot forwards a local port to Robot Framework's report server" {
  local script_pid port
  recipe_copy
  for port in default 3456; do
    if [[ $port == default ]]; then port=8090; else with ROBOT_PORT="$port"; fi
    recipe_start robot
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
    'port-forward --address 127.0.0.1 --namespace robot service/robot-reports 8090:8080' \
    'port-forward --address 127.0.0.1 --namespace robot service/robot-reports 3456:8080')" ]
  [ "$(sort -u "$RECORD/kubeconfig")" = "$KUBECONFIG_FILE" ]
  grep -qxF "Robot Framework's reports: http://127.0.0.1:3456" "$OUT"
  # What reaching them means, in one line: screenshots and whatever the suites print, to anything on
  # this machine while the forward runs.
  grep -qxF 'The reports hold screenshots and whatever the suites print, and are served to anything on this machine while the forward runs.' "$OUT"
  grep -qxF 'Ctrl-C ends the forward.' "$OUT"
  if grep -qF 'Forwarding from' "$OUT"; then echo "kubectl's own output was printed"; return 1; fi
}

@test "just robot ends the forward on every way out" {
  local script_pid
  recipe_copy
  # Ctrl-C: the terminal signals the recipe, while kubectl, run in the background, ignores it.
  recipe_start robot
  printed "http://127.0.0.1:8090"
  read -r _ script_pid <"$STATE/pids"
  kill -INT "$script_pid" "$JUST_PID"
  finished
  echo "after Ctrl-C: status $STATUS; $(cat "$OUT")"
  [ "$STATUS" -ne 0 ]
  kubectl_gone
  [ "$(cat "$RECORD/ended")" = SIGTERM ]
  [[ "$(cat "$OUT")" == *"The forward to Robot Framework's reports has ended."* ]]

  # SIGTERM, which just passes on to the recipe.
  rm "$RECORD/ended"
  recipe_start robot
  printed "http://127.0.0.1:8090"
  kill -TERM "$JUST_PID"
  finished
  echo "after SIGTERM: status $STATUS"
  [ "$STATUS" -ne 0 ]
  kubectl_gone
  [ "$(cat "$RECORD/ended")" = SIGTERM ]

  # kubectl never reports the forward.
  rm "$RECORD/ended"
  echo silent >"$STATE/mode"
  with ROBOT_WAIT=1
  recipe robot
  echo "kubectl silent: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"did not report the forward within 1 seconds"* ]]
  [[ $output != *"http://"* ]]
  kubectl_gone
  [ "$(cat "$RECORD/ended")" = SIGTERM ]

  # kubectl stops before it forwards, with an error that names the API server's address.
  echo fail >"$STATE/mode"
  recipe robot
  echo "kubectl failing: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"stopped with status 1 before it forwarded"* ]]
  [[ $output != *192.0.2.10* ]]
  kubectl_gone

  # kubectl stops while it forwards.
  echo drop >"$STATE/mode"
  recipe robot
  echo "kubectl dropping: status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"http://127.0.0.1:8090"* ]]
  [[ $output == *"stopped with status 1"* ]]
  kubectl_gone
}

@test "just robot and just robot-run run kubectl with none of the secrets" {
  local recipe_name
  recipe_copy
  # Every secret variable the recipes read, as a marker, besides the settings the recipes read.
  names=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CLUSTER_S3_ACCESS_KEY_ID CLUSTER_S3_SECRET_ACCESS_KEY
    OS_CLOUD OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET TF_STATE_PASSPHRASE
    TF_ENCRYPTION SOPS_AGE_KEY SOPS_AGE_KEY_FILE FLUX_AGE_KEY FLUX_AGE_KEY_FILE OPERATOR_CIDRS)
  for name in "${names[@]}"; do with "$name=marker-$name"; done
  with ROBOT_PORT=3456 ROBOT_RUN_WAIT=30
  echo fail >"$STATE/mode"
  for recipe_name in robot robot-run; do
    rm -f "$RECORD/names"
    recipe "$recipe_name"
    echo "$recipe_name: status $status; $output"
    [ -s "$RECORD/names" ]
    # What is no secret reaches kubectl, and the kubeconfig it is run with.
    grep -qx KUBECONFIG "$RECORD/names"
    grep -qx ROBOT_PORT "$RECORD/names"
    grep -qx ROBOT_RUN_WAIT "$RECORD/names"
    for name in "${names[@]}"; do
      if grep -qx "$name" "$RECORD/names"; then echo "$recipe_name hands kubectl $name"; return 1; fi
    done
  done
}

@test "just robot needs the cluster's kubeconfig and a port" {
  local port
  recipe_copy
  rm "$KUBECONFIG_FILE"
  with ROBOT_PORT=65536 ROBOT_WAIT=soon
  recipe robot
  echo "status $status; $output"
  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/clusterconfig/kubeconfig does not exist; just cluster-kubeconfig fetches it"* ]]
  [[ $output == *"ROBOT_PORT is not a port number"* ]]
  [[ $output == *"ROBOT_WAIT is not a whole number of seconds"* ]]
  # With the kubeconfig in place, each port alone is refused.
  echo 'not a real kubeconfig' >"$KUBECONFIG_FILE"
  for port in 0 080 abc 3000x; do
    only ROBOT_PORT="$port"
    recipe robot
    echo "ROBOT_PORT='$port': status $status; $output"
    [ "$status" -ne 0 ]
    [[ $output == *"ROBOT_PORT is not a port number"* ]]
  done
  [ ! -e "$RECORD/argv" ]
}
