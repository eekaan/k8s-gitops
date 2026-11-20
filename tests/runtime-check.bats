#!/usr/bin/env bats
# Proves features/runtime-check.feature; each test carries its scenario's title. The recipe runs from
# a copy of the repository with an environment of its own, so no run reads this checkout's .env or
# kubeconfig. kubectl is a recording fake (tests/fixtures/runtime-check/kubectl) that keeps the
# namespace and the pods as state, schedules each pod and answers its end and its log from canned
# files; tofu, openstack, talosctl, talman, helm, docker and curl fail when called. The script the
# recipe gives the net and reference pods runs here too, with stand-ins for the tools it calls, so no
# lookup or connection leaves this machine. The test of the cluster's own rules renders the tree,
# with its charts pulled from their public registries, and needs helm, flux, kustomize, yq, jq,
# kyverno and gator on PATH.

bats_require_minimum_version 1.5.0

# The tests run one at a time even where bats runs a file's tests side by side: the render is made
# once for the file.
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
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  JUST=$(command -v just)
  FIXTURES=$BATS_TEST_DIRNAME/fixtures/runtime-check
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  # The recipe's TMPDIR, which must hold nothing once it has ended.
  WORK="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$BIN" "$RECORD" "$STATE/pods" "$STATE/scenario" "$WORK" "$BATS_TEST_TMPDIR/repo/talos/lab-sto2/clusterconfig"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  cp -R "$ROOT/scripts" "$REPO/scripts"
  # The kubeconfig the recipe points kubectl at; the fake reads none.
  : >"$REPO/talos/lab-sto2/clusterconfig/kubeconfig"
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  printf '#!/usr/bin/env bash\n' >"$BIN/mise"
  chmod +x "$BIN/mise"
  cp "$FIXTURES/kubectl" "$BIN/"
  for tool in tofu openstack talosctl talman helm docker curl; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >> "%s"\necho "unexpected call: %s $*" >&2\nexit 1\n' \
      "$tool" "$RECORD/argv" "$tool" >"$BIN/$tool"
    chmod +x "$BIN/$tool"
  done
  echo "$FIXTURES" >"$STATE/fixtures"
  printf '%s\n' gvisor kata >"$STATE/runtimeclasses"
  # The images the justfile pins, which the recipe hands the script.
  PROBE_IMAGE=$(just_variable openshell_sandbox_image)
  NET_IMAGE=$(just_variable cilium_agent_image)
  ENVIRONMENT=(TMPDIR="$WORK" RUNTIME_CHECK_TIMEOUT=60)
}

# just_variable NAME: the value of the justfile's variable NAME.
just_variable() {
  sed -nE "s/^$1 := \"([^\"]*)\"$/\1/p" "$ROOT/justfile"
}

# reset: a cluster as the fake starts it, for the next run of a test that makes several.
reset() {
  rm -rf "$STATE/pods" "$STATE/scenario" "$STATE"/namespace* "$STATE"/ns-* "$STATE"/sa-* "$STATE"/fail.* "$STATE"/refuse.* "$STATE"/lost.* \
    "$STATE"/then.* "$STATE"/interrupt* "$STATE/events.json" "$STATE/first-output"
  mkdir -p "$STATE/pods" "$STATE/scenario"
}

# runtime_check ARG...: just runtime-check ARG... against the copy, with only ENVIRONMENT set and
# the fakes first on PATH. A run that blocks fails after two minutes.
runtime_check() {
  : >"$RECORD/argv"
  : >"$RECORD/events"
  : >"$RECORD/created"
  run timeout 120 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" runtime-check "$@"
  echo "$output"
}

# script ARG...: the script itself, as the recipe runs it, with ARG... as its arguments.
script() {
  : >"$RECORD/argv"
  run timeout 120 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" "$REPO/scripts/runtime-check" "$@"
  echo "$output"
}

# checks: the check lines of the run, as printed.
checks() {
  grep -E '^(pass|FAIL)  ' <<<"$output"
}

# check NAME: the line of the check NAME.
check() {
  grep -E "^(pass|FAIL)  $1: " <<<"$output"
}

# below NAME: the lines indented below the line of the check NAME, without their indentation.
below() {
  awk -v name="$1" '/^(pass|FAIL)  / { inside = (index($0, "  " name ": ") == 5) ; next } inside && /^      / { print substr($0, 7) }' <<<"$output"
}

# object KIND NAME: the last object of KIND named NAME the recipe created, as JSON on one line.
object() {
  jq -c --arg kind "$1" --arg name "$2" '.items[]? // . | select(.kind == $kind and .metadata.name == $name)' "$RECORD/created" | tail -n 1
}

# order: what the run did to the cluster, in order.
order() {
  cat "$RECORD/events"
}

# nothing_secret: the output holds no address, neither the fake API server's nor the resolver's,
# no host name of the API server, and no control character or byte outside ASCII.
nothing_secret() {
  if grep -nE '[0-9]{1,3}(\.[0-9]{1,3}){3}|example\.net' <<<"$output"; then
    echo "an address or the API server's name is printed" >&2
    return 1
  fi
  if LC_ALL=C grep -n '[^[:print:][:space:]]' <<<"$output"; then
    echo "a control character or a byte outside ASCII is printed" >&2
    return 1
  fi
}

# absent GREP_ARG...: fails, showing what it found, when grep finds what GREP_ARG... asks for; the last
# command of a function, as bats ignores a failing ! anywhere else.
absent() {
  ! grep "$@"
}

# good_checks CLASS: the four check lines of a run under CLASS whose every check passes with the
# canned logs.
good_checks() {
  printf '%s\n' \
    "pass  kernel: OpenShell's capability probe qualified the runtime: Landlock ABI 6, seccomp user notification with addfd send, task-memory copy" \
    'pass  name: kube-dns.kube-system.svc resolved within 10 seconds' \
    "pass  service: a TCP connection to the resolver's Service address on port 53 opened within 5 seconds" \
    "pass  mtu: the default route's MTU is 1400 in net, from the route, and 1400 in reference, from the route"
}

# made_and_removed: the run made the namespace, its two policies and its three pods, and removed the
# namespace at its end, as the fake recorded it.
made_and_removed() {
  [ "$(order)" = "$(printf '%s\n' 'created namespace runtime-check' 'created networkpolicy default-deny' \
    'created ciliumnetworkpolicy runtime-check' 'created pod net' 'created pod probe' 'created pod reference' \
    'deleted namespace runtime-check' 'namespace runtime-check gone')" ]
  [ ! -e "$STATE/namespace.json" ]
}

# pod_script: the script the recipe gives net, from the manifest it created.
pod_script() {
  jq -er '.spec.containers[0] | select(.command[0:2] == ["bash", "-c"] and (.command | length) == 3) | .command[2]' <<<"$(object Pod net)"
}

# in_pod [VAR=VALUE...]: runs the script the recipe gave net here, with stand-ins for the tools it
# calls, each set by VAR=VALUE: LOOKUP (ok, v6, an answer without an IPv4 address, missing or slow),
# CONNECT (the status of the connection, 0, 1 or 124), ROUTE (the line ip prints for the default
# route, none for none), LSM (the LSM file's content, or none) and MTU (eth0's, or none). The
# stand-ins record their calls in $CALLS.
in_pod() {
  local dir="$BATS_TEST_TMPDIR/pod-bin"
  CALLS="$BATS_TEST_TMPDIR/pod-calls"
  : >"$CALLS"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    cat >"$dir/uname" <<'EOF'
#!/usr/bin/env bash
[ "$*" = -r ] && echo 6.12.47
EOF
    cat >"$dir/cat" <<'EOF'
#!/usr/bin/env bash
printf 'cat %s\n' "$*" >> "$CALLS"
case $1 in
  /sys/kernel/security/lsm) [ "$LSM" != none ] && printf '%s' "$LSM" ;;
  /sys/class/net/eth0/mtu) [ "$MTU" != none ] && echo "$MTU" ;;
  *) echo "cat: $1: No such file or directory" >&2; exit 1 ;;
esac
EOF
    cat >"$dir/getent" <<'EOF'
#!/usr/bin/env bash
printf 'getent %s\n' "$*" >> "$CALLS"
case $LOOKUP in
  ok) printf '%s\n' '198.51.100.10   STREAM kube-dns.kube-system.svc.cluster.local' '198.51.100.10   DGRAM  ' '198.51.100.10   RAW    ' ;;
  v6) printf '%s\n' '2001:db8::10    STREAM kube-dns.kube-system.svc.cluster.local' ;;
  *) exit 2 ;;
esac
EOF
    cat >"$dir/timeout" <<'EOF'
#!/usr/bin/env bash
printf 'timeout %s\n' "$*" >> "$CALLS"
case $2 in
  getent) [ "$LOOKUP" != slow ] || exit 124; shift; exec "$@" ;;
  bash) echo "bash: connect: Connection refused to $5" >&2; exit "$CONNECT" ;;
esac
exit 99
EOF
    cat >"$dir/ip" <<'EOF'
#!/usr/bin/env bash
printf 'ip %s\n' "$*" >> "$CALLS"
[ "$ROUTE" = none ] || printf '%s\n' "$ROUTE"
EOF
    chmod +x "$dir"/*
  fi
  run env -i PATH="$dir:/usr/bin:/bin" CALLS="$CALLS" LOOKUP=ok CONNECT=0 ROUTE='default via 198.51.100.1 dev eth0 mtu 1400 ' \
    LSM=capability,landlock,yama MTU=1450 "$@" bash -c "$(pod_script)"
  echo "$output"
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

# real_render: the render of this repository's tree, charts pulled, in $BATS_FILE_TMPDIR/render, made
# once for the file.
real_render() {
  REAL="$BATS_FILE_TMPDIR/render"
  if [ ! -d "$REAL" ]; then
    "$ROOT/scripts/render" "$REAL.partial" >/dev/null
    mv "$REAL.partial" "$REAL"
  fi
}

# allowed, denied FROM TO PORT: assert the answer the policies of $VIEW give for the flow.
allowed() {
  run "$ROOT/scripts/network-policy-check" --reach "$VIEW" "$@"
  [ "$status" -eq 0 ] || { echo "expected $* to be allowed: $output"; return 1; }
}
denied() {
  run "$ROOT/scripts/network-policy-check" --reach "$VIEW" "$@"
  [ "$status" -eq 1 ] || { echo "expected $* to be denied: $output"; return 1; }
}

@test "The runtime check reports OpenShell's capability probe, a cluster name, a Service connection and the default route's MTU for the class it is given, and passes when all four pass" {
  local class label manifest
  for class in kata gvisor none; do
    reset
    runtime_check "$class"

    [ "$status" -eq 0 ]
    label=$class
    [ "$class" != none ] || label='the default runtime'
    [ "$(grep '^runtime-check: ' <<<"$output" | head -n 1)" = "runtime-check: $label on node worker-1: kernel 6.12.47, LSMs capability,landlock,yama, first output 7s after the pod was created" ]
    [ "$(checks)" = "$(good_checks)" ]
    # The probe and net run under the class, the reference under the default runtime, and both of
    # the latter on net's node.
    for manifest in probe net; do
      [ "$(jq -r '.spec.runtimeClassName // "none"' <<<"$(object Pod "$manifest")")" = "$class" ]
    done
    [ "$(jq -r '.spec.runtimeClassName // "none"' <<<"$(object Pod reference)")" = none ]
    for manifest in probe reference; do
      [ "$(jq -c '.spec.affinity' <<<"$(object Pod "$manifest")")" \
        = '{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchFields":[{"key":"metadata.name","operator":"In","values":["worker-1"]}]}]}}}' ]
    done
    [ -z "$(object Pod net | jq -c '.spec.affinity // empty')" ]
    # The RuntimeClass is asked for under kata and gvisor; none is the default runtime, which no
    # RuntimeClass names.
    if [ "$class" = none ]; then
      absent -q runtimeclass "$RECORD/argv"
    else
      grep -qxF "kubectl get --request-timeout=30s --ignore-not-found --output=json runtimeclass $class" "$RECORD/argv"
    fi
    made_and_removed
    nothing_secret
    [ -z "$(find "$WORK" -mindepth 1)" ]
  done

  # The script net and reference run: its key=value lines, the route's MTU, and no address, which
  # the cluster's logs would ship. The lookup goes to the resolver's Service by name, completed by
  # the pod's search path, within 10 seconds, and the connection to its first address on 53 within 5.
  in_pod
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$FIXTURES/net.log")" ]
  grep -qxF 'timeout 10 getent ahostsv4 kube-dns.kube-system.svc' "$CALLS"
  [ "$(grep '^timeout 5 bash ' "$CALLS" | grep -c '/53.* 198\.51\.100\.10$')" -eq 1 ]
  grep -qxF 'ip -4 -o route show default' "$CALLS"
  nothing_secret
  # Without the route's MTU, the device's.
  in_pod ROUTE='default via 198.51.100.1 dev eth0 ' LSM=none
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' kernel=6.12.47 lsm=- name=ok service=ok route_mtu=- device=eth0 device_mtu=1450)" ]
  in_pod ROUTE='default via 198.51.100.1 dev eth0 proto kernel mtu lock 1380'
  [ "$(grep '^route_mtu=' <<<"$output")" = route_mtu=1380 ]
}

@test "The runtime check fails, naming each check that fails and why, when the probe fails, a name does not resolve, a Service does not answer or the MTU differs" {
  local line
  # OpenShell's diagnostic as miette writes it without a terminal, Unicode drawing characters and no
  # colour: the chain the probe gives when its socket probe may not bind the DNS relay's port, as
  # without the pod's sysctl (crates/openshell-sandbox/src/main.rs, qualify_runtime and
  # probe_socket_virtualization), among lines that hold an address, a name and a control character;
  # ten lines, of which the last eight are shown.
  {
    for line in 1 2 3; do echo "starting probe step $line"; done
    printf 'Error:   \xc3\x97 socket virtualization probe\n'
    printf '  \xe2\x94\x9c\xe2\x94\x80\xe2\x96\xb6 bind socket probe DNS relay\n'
    printf '  \xe2\x95\xb0\xe2\x94\x80\xe2\x96\xb6 Permission denied (os error 13)\n'
    printf '  tried 127.0.0.53:53 on behalf of api.example.net\n'
    printf 'a line with a control character \033[31m in it\n'
    printf 'the probe ends here\n'
    printf 'it said nothing more\n'
  } >"$STATE/scenario/probe.log"
  echo 'exit 1' >"$STATE/scenario/probe"
  runtime_check kata

  [ "$status" -eq 1 ]
  [ "$(check kernel)" = "FAIL  kernel: OpenShell's capability probe exited 1; the end of its log:" ]
  [ "$(below kernel)" = "$(printf '%s\n' 'starting probe step 3' 'Error:   ?? socket virtualization probe' \
    '  ????????? bind socket probe DNS relay' '  ????????? Permission denied (os error 13)' '  tried <address> on behalf of <name>' \
    'a line with a control character ?[31m in it' 'the probe ends here' 'it said nothing more')" ]
  [ "$(checks | sed 1d)" = "$(good_checks | sed 1d)" ]
  made_and_removed
  nothing_secret

  # An end the probe does not make itself, here a kill with nothing printed, is told by the pod.
  reset
  : >"$STATE/scenario/probe.log"
  echo 'exit 137' >"$STATE/scenario/probe"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(check kernel)" = "FAIL  kernel: OpenShell's capability probe exited 137 and printed nothing" ]
  [ "$(below kernel)" = 'container probe: terminated with exit code 137, Error' ]

  # A qualified report is no pass when the probe did not exit 0.
  reset
  cp "$FIXTURES/probe.log" "$STATE/scenario/probe.log"
  echo 'exit 1' >"$STATE/scenario/probe"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(check kernel)" = "FAIL  kernel: OpenShell's capability probe exited 1; the end of its log:" ]

  # Nor is a report that is not qualified, one that lacks what the pass names, or a last line that
  # is no report.
  for line in '"qualified":true' '"seccomp_addfd_send":true' '"landlock_abi":6'; do
    reset
    case $line in
      *qualified*) sed 's/"qualified":true/"qualified":false/' "$FIXTURES/probe.log" ;;
      *addfd*) sed 's/"seccomp_addfd_send":true/"seccomp_addfd_send":false/' "$FIXTURES/probe.log" ;;
      *) sed 's/"landlock_abi":6,//' "$FIXTURES/probe.log" ;;
    esac >"$STATE/scenario/probe.log"
    runtime_check none
    [ "$status" -eq 1 ]
    [ "$(check kernel)" = "FAIL  kernel: OpenShell's capability probe exited 0 without a report that qualifies the runtime; the end of its log:" ]
    [ "$(below kernel | wc -l)" -eq 1 ]
    [ "$(checks | sed 1d)" = "$(good_checks | sed 1d)" ]
  done
  reset
  { cat "$FIXTURES/probe.log"; echo 'something after the report'; } >"$STATE/scenario/probe.log"
  runtime_check gvisor
  [ "$status" -eq 1 ]
  [ "$(check kernel)" = "FAIL  kernel: OpenShell's capability probe exited 0 without a report that qualifies the runtime; the end of its log:" ]

  # A name that does not resolve, and so no Service to connect to.
  reset
  sed 's/^name=ok$/name=fail:no answer within 10 seconds/; s/^service=ok$/service=fail:no address/' "$FIXTURES/net.log" >"$STATE/scenario/net.log"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(checks)" = "$(good_checks | sed \
    -e 's/^pass  name: .*/FAIL  name: kube-dns.kube-system.svc did not resolve: no answer within 10 seconds/' \
    -e "s/^pass  service: .*/FAIL  service: no TCP connection to the resolver's Service address on port 53: no address/")" ]
  made_and_removed
  nothing_secret

  # A Service that does not answer.
  reset
  sed 's/^service=ok$/service=fail:no connection within 5 seconds/' "$FIXTURES/net.log" >"$STATE/scenario/net.log"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(checks)" = "$(good_checks | sed "s/^pass  service: .*/FAIL  service: no TCP connection to the resolver's Service address on port 53: no connection within 5 seconds/")" ]

  # The route's MTU in net differs from the reference's while the devices agree, as when Kata copies
  # the device's MTU and not the route's; and two routes that differ over the same device MTU.
  reset
  sed 's/^route_mtu=1400$/route_mtu=-/' "$FIXTURES/net.log" >"$STATE/scenario/net.log"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(check mtu)" = "FAIL  mtu: the default route's MTU is 1450 in net, from the device eth0, and 1400 in reference, from the route" ]
  [ "$(checks | head -n 3)" = "$(good_checks | head -n 3)" ]
  reset
  sed 's/^route_mtu=1400$/route_mtu=1350/' "$FIXTURES/net.log" >"$STATE/scenario/net.log"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(check mtu)" = "FAIL  mtu: the default route's MTU is 1350 in net, from the route, and 1400 in reference, from the route" ]

  # Neither MTU readable in net is no pass, whatever the reference's.
  reset
  sed 's/^route_mtu=1400$/route_mtu=-/; s/^device_mtu=1450$/device_mtu=-/' "$FIXTURES/net.log" >"$STATE/scenario/net.log"
  runtime_check gvisor
  [ "$status" -eq 1 ]
  [ "$(check mtu)" = "FAIL  mtu: the default route's MTU cannot be read in net, from the route or the device eth0" ]

  # Nor in the reference, nor a reference that printed no route_mtu line or whose script did not end
  # as it does.
  reset
  sed 's/^route_mtu=1400$/route_mtu=-/; s/^device_mtu=1450$/device_mtu=-/' "$FIXTURES/reference.log" >"$STATE/scenario/reference.log"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(check mtu)" = "FAIL  mtu: the default route's MTU cannot be read in reference, from the route or the device eth0" ]
  [ "$(checks | head -n 3)" = "$(good_checks | head -n 3)" ]
  reset
  sed '/^route_mtu=/d' "$FIXTURES/reference.log" >"$STATE/scenario/reference.log"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(check mtu)" = 'FAIL  mtu: reference printed no route_mtu line' ]
  reset
  echo 'exit 1' >"$STATE/scenario/reference"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(check mtu)" = 'FAIL  mtu: the script of the pod reference exited 1' ]
  [ "$(checks | head -n 3)" = "$(good_checks | head -n 3)" ]

  # net killed after it printed every line: its lines decide nothing, and the checks they feed fail
  # with how it ended.
  reset
  echo 'exit 137' >"$STATE/scenario/net"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(checks)" = "$(good_checks | sed 1q; printf 'FAIL  %s: the script of the pod net exited 137\n' name service mtu)" ]
  [[ $output == *"runtime-check: kata on node worker-1: kernel unknown, LSMs unknown, no output"* ]]
  absent -q '^kubectl logs .*pod/net$' "$RECORD/argv"

  # A line missing, given twice or malformed fails the checks it feeds, and no other.
  reset
  sed '/^name=/d; s/^route_mtu=1400$/route_mtu=192.0.2.1/' "$FIXTURES/net.log" >"$STATE/scenario/net.log"
  echo 'service=ok' >>"$STATE/scenario/net.log"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(check name)" = 'FAIL  name: net printed no name line' ]
  [ "$(check service)" = "FAIL  service: net printed its service line more than once" ]
  [ "$(check mtu)" = "FAIL  mtu: net's route_mtu line is malformed" ]
  [ "$(check kernel)" = "$(good_checks | head -n 1)" ]
  nothing_secret

  # The script itself: a lookup that finds nothing, one that takes too long, a connection that times
  # out or is refused, a route without an MTU and no default route at all.
  in_pod LOOKUP=missing
  [ "$(grep -E '^(name|service)=' <<<"$output")" = "$(printf '%s\n' 'name=fail:the name was not found' 'service=fail:no address')" ]
  absent -q '^timeout 5 ' "$CALLS"
  in_pod LOOKUP=slow
  [ "$(grep -E '^(name|service)=' <<<"$output")" = "$(printf '%s\n' 'name=fail:no answer within 10 seconds' 'service=fail:no address')" ]
  in_pod LOOKUP=v6
  [ "$(grep -E '^(name|service)=' <<<"$output")" = "$(printf '%s\n' 'name=fail:the answer holds no IPv4 address' 'service=fail:no address')" ]
  absent -q '^timeout 5 ' "$CALLS"
  in_pod CONNECT=124
  [ "$(grep '^service=' <<<"$output")" = 'service=fail:no connection within 5 seconds' ]
  nothing_secret
  in_pod CONNECT=1
  [ "$(grep '^service=' <<<"$output")" = 'service=fail:the connection was refused or could not be made' ]
  nothing_secret
  in_pod ROUTE=none MTU=none
  [ "$status" -eq 0 ]
  [ "$(sed -n '5,$p' <<<"$output")" = "$(printf '%s\n' route_mtu=- device=- device_mtu=-)" ]
}

@test "The runtime check fails with the reason when the class is unknown or not on the cluster, a pod does not start, or the pods do not end in time" {
  local value
  # The usage: a class that is none of the three, an extra argument, an image without its digest, a
  # timeout that is not one; each before any call of kubectl.
  runtime_check docker
  [ "$status" -eq 2 ]
  [[ $output == *"usage: runtime-check PROBE_IMAGE NET_IMAGE kata|gvisor|none [cluster]"* ]]
  [ ! -s "$RECORD/argv" ]
  script "$PROBE_IMAGE" "$NET_IMAGE" kata lab-sto2 extra
  [ "$status" -eq 2 ]
  [[ $output == *"usage: runtime-check"* ]]
  [ ! -s "$RECORD/argv" ]
  for value in "${PROBE_IMAGE%@*}" "${NET_IMAGE%%:*}@${NET_IMAGE#*@}" "${PROBE_IMAGE%@*}@sha256:abc"; do
    script "$value" "$NET_IMAGE" kata
    [ "$status" -eq 2 ]
    [[ $output == *"$value is not an image pinned as name:tag@sha256:<64 hexadecimal digits>"* ]]
    script "$PROBE_IMAGE" "$value" none
    [ "$status" -eq 2 ]
    [ ! -s "$RECORD/argv" ]
  done
  for value in 0 -1 1m 1234567890; do
    ENVIRONMENT=(TMPDIR="$WORK" "RUNTIME_CHECK_TIMEOUT=$value")
    runtime_check kata
    [ "$status" -eq 2 ]
    [[ $output == *RUNTIME_CHECK_TIMEOUT* ]]
    [ ! -s "$RECORD/argv" ]
  done
  ENVIRONMENT=(TMPDIR="$WORK" RUNTIME_CHECK_TIMEOUT=60)

  # A class the cluster has no RuntimeClass of fails every check, and nothing is made.
  echo gvisor >"$STATE/runtimeclasses"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(checks)" = "$(printf 'FAIL  %s: the RuntimeClass kata is not on the cluster, so no pod was made\n' kernel name service mtu)" ]
  [ "$(cat "$RECORD/argv")" = 'kubectl get --request-timeout=30s --ignore-not-found --output=json runtimeclass kata' ]
  [ ! -s "$RECORD/events" ]
  # None is the default runtime, which no RuntimeClass names.
  runtime_check none
  [ "$status" -eq 0 ]
  absent -q runtimeclass "$RECORD/argv"
  printf '%s\n' gvisor kata >"$STATE/runtimeclasses"

  # The kubelet refuses the probe, for the groups policy it does not support: kernel fails with what
  # the pod's status says, and the network results still come.
  reset
  echo 'rejected SupplementalGroupsPolicyNotSupported SupplementalGroupsPolicy=Strict is not supported in this node' >"$STATE/scenario/probe"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(check kernel)" = 'FAIL  kernel: the pod probe ended without running its container' ]
  [ "$(below kernel)" = 'pod: Failed, SupplementalGroupsPolicyNotSupported: SupplementalGroupsPolicy=Strict is not supported in this node' ]
  [ "$(checks | sed 1d)" = "$(good_checks | sed 1d)" ]
  made_and_removed
  nothing_secret

  # net cannot pull its image: the checks it feeds fail with its container's state and the
  # namespace's Warning events for it, without an address; its log is not asked for.
  reset
  ENVIRONMENT=(TMPDIR="$WORK" RUNTIME_CHECK_TIMEOUT=3)
  echo 'waiting ErrImagePull failed to pull and unpack image: dial tcp 192.0.2.20:443: i/o timeout' >"$STATE/scenario/net"
  jq -n '[{type: "Warning", reason: "Failed", message: "Error: ErrImagePull from 192.0.2.20", involvedObject: {kind: "Pod", name: "net", uid: "uid-net"}},
    {type: "Normal", reason: "Pulling", message: "Pulling image", involvedObject: {kind: "Pod", name: "net", uid: "uid-net"}},
    {type: "Warning", reason: "FailedCreatePodSandBox", message: "not for this pod", involvedObject: {kind: "Pod", name: "elsewhere"}}]' >"$STATE/events.json"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(check kernel)" = "$(good_checks | head -n 1)" ]
  [ "$(check name)" = 'FAIL  name: the pod net did not start within 3 seconds' ]
  [ "$(below name)" = "$(printf '%s\n' 'container net: waiting, ErrImagePull: failed to pull and unpack image: dial tcp <name>.<address> i/o timeout' \
    'event Failed: Error: ErrImagePull from <address>')" ]
  [ "$(check service)" = 'FAIL  service: the pod net did not start within 3 seconds' ]
  [ "$(check mtu)" = 'FAIL  mtu: the pod net did not start within 3 seconds' ]
  [[ $output == *"runtime-check: the pods still running after 3 seconds: net"* ]]
  [[ $output == *"runtime-check: kata on node worker-1: kernel unknown, LSMs unknown, no output"* ]]
  absent -q '^kubectl logs .*pod/net$' "$RECORD/argv"
  made_and_removed
  nothing_secret

  # No node takes net: that is the reason of every check, and probe and reference are not made.
  reset
  echo 'unschedulable 0/3 nodes are available: 3 node(s) did not match the pod runtime class.' >"$STATE/scenario/net"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(checks)" = "$(printf 'FAIL  %s: the pod net was not scheduled within 3 seconds\n' kernel name service mtu)" ]
  [ "$(below kernel)" = 'PodScheduled: Unschedulable: 0/3 nodes are available: 3 node(s) did not match the pod runtime class.' ]
  [[ $output == *"runtime-check: kata on no node: kernel unknown, LSMs unknown, no output"* ]]
  [ "$(order)" = "$(printf '%s\n' 'created namespace runtime-check' 'created networkpolicy default-deny' \
    'created ciliumnetworkpolicy runtime-check' 'created pod net' 'deleted namespace runtime-check' 'namespace runtime-check gone')" ]
  nothing_secret

  # net deleted once it was made, before it was scheduled: that is the reason of every check at once,
  # probe and reference are not made, and the namespace goes.
  reset
  ENVIRONMENT=(TMPDIR="$WORK" RUNTIME_CHECK_TIMEOUT=60)
  echo gone >"$STATE/scenario/net"
  SECONDS=0
  runtime_check kata
  ((SECONDS < 30))
  [ "$status" -eq 1 ]
  [ "$(checks)" = "$(printf 'FAIL  %s: the pod net is no longer on the cluster\n' kernel name service mtu)" ]
  [[ $output == *"runtime-check: kata on no node: kernel unknown, LSMs unknown, no output"* ]]
  [ "$(order)" = "$(printf '%s\n' 'created namespace runtime-check' 'created networkpolicy default-deny' \
    'created ciliumnetworkpolicy runtime-check' 'created pod net' 'deleted namespace runtime-check' 'namespace runtime-check gone')" ]
  [ ! -e "$STATE/namespace.json" ]

  # Each pod deleted once it ran on its node: the checks it feeds fail saying so, and the others pass.
  reset
  echo 'gone 1' >"$STATE/scenario/net"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(checks)" = "$(good_checks | sed 1q; printf 'FAIL  %s: the pod net is no longer on the cluster\n' name service mtu)" ]
  made_and_removed
  reset
  echo gone >"$STATE/scenario/probe"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(checks)" = "$(printf '%s\n' 'FAIL  kernel: the pod probe is no longer on the cluster'; good_checks | sed 1d)" ]
  made_and_removed
  reset
  echo gone >"$STATE/scenario/reference"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(checks)" = "$(good_checks | sed '$d'; printf '%s\n' 'FAIL  mtu: the pod reference is no longer on the cluster')" ]
  made_and_removed
  ENVIRONMENT=(TMPDIR="$WORK" RUNTIME_CHECK_TIMEOUT=3)

  # A probe that never ends is named when the timeout passes, and the pods' own deadline is the
  # timeout too.
  reset
  echo running >"$STATE/scenario/probe"
  SECONDS=0
  runtime_check gvisor
  [ "$status" -eq 1 ]
  ((SECONDS < 30))
  [ "$(check kernel)" = 'FAIL  kernel: the pod probe did not end within 3 seconds' ]
  [ "$(checks | sed 1d)" = "$(good_checks | sed 1d)" ]
  [[ $output == *"runtime-check: the pods still running after 3 seconds: probe"* ]]
  for value in net probe reference; do
    [ "$(object Pod "$value" | jq '.spec.activeDeadlineSeconds')" -eq 3 ]
  done
  made_and_removed

  # kubectl's own errors are shown without the API server's address, and every call is bounded.
  reset
  ENVIRONMENT=(TMPDIR="$WORK" RUNTIME_CHECK_TIMEOUT=60)
  : >"$STATE/fail.get-runtimeclass"
  runtime_check kata
  [ "$status" -eq 1 ]
  [[ $output == *"kubectl: Unable to connect to the server: dial tcp <name>.<address> i/o timeout"* ]]
  [[ $output == *"the RuntimeClass kata cannot be read"* ]]
  [ ! -s "$RECORD/events" ]
  nothing_secret
  rm "$STATE/fail.get-runtimeclass"
  runtime_check kata
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$RECORD/argv")" -gt 8 ]
  absent -v -- '--request-timeout=30s' "$RECORD/argv"
}

@test "The runtime check leaves nothing behind, however it ends, and clears what an earlier run left" {
  local signal name at code made
  # An earlier run's namespace, by its label, is deleted and waited for before anything is made.
  jq -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check",
    labels: {"app.kubernetes.io/managed-by": "runtime-check", "pod-security.kubernetes.io/enforce": "restricted"}}}' >"$STATE/namespace.json"
  echo 1 >"$STATE/ns-terminating"
  runtime_check kata
  [ "$status" -eq 0 ]
  [ "$(order | head -n 3)" = "$(printf '%s\n' 'deleted namespace runtime-check' 'namespace runtime-check gone' 'created namespace runtime-check')" ]
  [ "$(checks)" = "$(good_checks)" ]
  [ ! -e "$STATE/namespace.json" ]

  # One without the label is no earlier run's: refused, and nothing is changed.
  reset
  jq -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check", labels: {"team": "someone"}}}' >"$STATE/namespace.json"
  cp "$STATE/namespace.json" "$BATS_TEST_TMPDIR/theirs.json"
  runtime_check kata
  [ "$status" -eq 1 ]
  [[ $output == *"the namespace runtime-check exists without the label app.kubernetes.io/managed-by: runtime-check, so it is no earlier run's; nothing was changed"* ]]
  [ ! -s "$RECORD/events" ]
  absent -qE '^kubectl (create|delete) ' "$RECORD/argv"
  cmp "$STATE/namespace.json" "$BATS_TEST_TMPDIR/theirs.json"
  # Nor is one whose label names another manager.
  reset
  jq -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check", labels: {"app.kubernetes.io/managed-by": "someone"}}}' >"$STATE/namespace.json"
  cp "$STATE/namespace.json" "$BATS_TEST_TMPDIR/theirs.json"
  runtime_check kata
  [ "$status" -eq 1 ]
  [[ $output == *"the namespace runtime-check exists without the label app.kubernetes.io/managed-by: runtime-check, so it is no earlier run's; nothing was changed"* ]]
  [ ! -s "$RECORD/events" ]
  absent -qE '^kubectl (create|delete) ' "$RECORD/argv"
  cmp "$STATE/namespace.json" "$BATS_TEST_TMPDIR/theirs.json"

  # A run whose checks fail removes what it made.
  reset
  echo 'exit 1' >"$STATE/scenario/probe"
  runtime_check kata
  [ "$status" -eq 1 ]
  made_and_removed
  reset
  runtime_check kata
  [ "$status" -eq 0 ]
  [ "$(checks)" = "$(good_checks)" ]

  # A kubectl call that fails after the namespace was made.
  reset
  : >"$STATE/fail.create-pods"
  runtime_check kata
  [ "$status" -eq 1 ]
  [[ $output == *"kubectl: Unable to connect to the server: dial tcp <name>.<address> i/o timeout"* ]]
  [[ $output == *"the pods probe and reference could not be created"* ]]
  [ "$(order | tail -n 2)" = "$(printf '%s\n' 'deleted namespace runtime-check' 'namespace runtime-check gone')" ]
  [ ! -e "$STATE/namespace.json" ]
  nothing_secret
  reset
  runtime_check kata
  [ "$status" -eq 0 ]
  made_and_removed

  # A run that times out.
  reset
  ENVIRONMENT=(TMPDIR="$WORK" RUNTIME_CHECK_TIMEOUT=3)
  echo running >"$STATE/scenario/net"
  runtime_check none
  [ "$status" -eq 1 ]
  made_and_removed
  reset
  ENVIRONMENT=(TMPDIR="$WORK" RUNTIME_CHECK_TIMEOUT=60)
  runtime_check none
  [ "$status" -eq 0 ]
  made_and_removed

  # Ctrl-C or TERM once the namespace is made, after the pods are made or while the run waits.
  for signal in INT:create-pods:130 TERM:get-pods:143; do
    IFS=: read -r name at code <<<"$signal"
    reset
    echo "$name" >"$STATE/interrupt"
    echo "$at" >"$STATE/interrupt-at"
    runtime_check kata
    [ "$status" -eq "$code" ]
    grep -qx "interrupted with $name" "$RECORD/events"
    [ "$(order | tail -n 2)" = "$(printf '%s\n' 'deleted namespace runtime-check' 'namespace runtime-check gone')" ]
    [ ! -e "$STATE/namespace.json" ]
    [ -z "$(checks)" ]
    [ -z "$(find "$WORK" -mindepth 1)" ]
    reset
    runtime_check kata
    [ "$status" -eq 0 ]
    [ "$(checks)" = "$(good_checks)" ]
    made_and_removed
  done

  # A namespace that does not go is named, with the command that deletes it, and fails the run.
  reset
  ENVIRONMENT=(TMPDIR="$WORK" RUNTIME_CHECK_TIMEOUT=3)
  : >"$STATE/ns-stuck"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(checks)" = "$(good_checks)" ]
  [[ $output == *"the namespace runtime-check is still on the cluster after 3 seconds; delete it with: kubectl delete namespace runtime-check"* ]]
  [[ $output == *"; if it is terminating already, its status conditions say what holds it: kubectl get namespace runtime-check --output=yaml"* ]]
  [ -z "$(find "$WORK" -mindepth 1)" ]

  # The run deletes only the namespace it made. One that another party makes between the run's read,
  # which finds none, and its create is theirs, even with the run's label, as another checkout's run
  # makes it: the run says so and exits 1, and neither deletes nor changes it, nor puts its policies or
  # pods in it; so too when INT comes to the run alone as the create is answered, as the run waits for
  # that answer before it ends.
  ENVIRONMENT=(TMPDIR="$WORK" RUNTIME_CHECK_TIMEOUT=60)
  for at in answer answer-labelled create-namespace create-namespace-labelled; do
    reset
    if [[ $at == *-labelled ]]; then
      jq -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check",
        labels: {"app.kubernetes.io/managed-by": "runtime-check", "pod-security.kubernetes.io/enforce": "restricted"}}}'
    else
      jq -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check", labels: {"team": "someone"}}}'
    fi >"$STATE/ns-appears"
    cp "$STATE/ns-appears" "$BATS_TEST_TMPDIR/theirs.json"
    if [[ $at == create-namespace* ]]; then
      echo INT >"$STATE/interrupt"
      echo create-namespace >"$STATE/interrupt-at"
    fi
    runtime_check kata
    echo "what the cluster saw: $(order | paste -sd, -)"
    [ "$(order | grep -vx "interrupted with INT")" = 'another party created namespace runtime-check' ]
    absent -qE '^kubectl delete ' "$RECORD/argv"
    cmp "$STATE/namespace.json" "$BATS_TEST_TMPDIR/theirs.json"
    [ -z "$(checks)" ]
    [[ $output == *"kubectl: Error from server (AlreadyExists): "* ]]
    [[ $output == *"the namespace runtime-check was made by someone else after the run found none, so it is not this run's; it was left alone"* ]]
    if [[ $at == create-namespace* ]]; then
      grep -qx 'interrupted with INT' "$RECORD/events"
      [ "$status" -eq 130 ]
    else
      [ "$status" -eq 1 ]
    fi
    nothing_secret
  done

  # A create of the namespace whose answer is lost: the namespace there with the run's label is the
  # one it asked for, and goes.
  reset
  : >"$STATE/lost.create-namespace"
  runtime_check kata
  [ "$status" -eq 1 ]
  [[ $output == *"the namespace runtime-check could not be created"* ]]
  [ "$(order)" = "$(printf '%s\n' 'created namespace runtime-check' 'deleted namespace runtime-check' 'namespace runtime-check gone')" ]
  [ ! -e "$STATE/namespace.json" ]
  # One there without the label, which another party made as the run asked for its own, is not the
  # run's and is left alone; one the run cannot read is named, with the command that deletes it if it
  # carries the label; and when none is there, as after a create that got no answer, the run says that
  # one may yet come of it and how to delete it.
  reset
  jq -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check", labels: {"team": "someone"}}}' >"$STATE/ns-appears"
  cp "$STATE/ns-appears" "$BATS_TEST_TMPDIR/theirs.json"
  : >"$STATE/lost.create-namespace"
  runtime_check kata
  [ "$status" -eq 1 ]
  [[ $output == *"the namespace runtime-check is on the cluster without the label app.kubernetes.io/managed-by: runtime-check, so the run did not make it; it was left alone"* ]]
  absent -qE '^kubectl delete ' "$RECORD/argv"
  cmp "$STATE/namespace.json" "$BATS_TEST_TMPDIR/theirs.json"
  reset
  : >"$STATE/lost.create-namespace"
  echo fail.get-namespace >"$STATE/then.create-namespace"
  runtime_check kata
  [ "$status" -eq 1 ]
  [[ $output == *"the namespace runtime-check cannot be read, so whether the run made it is not known; if it carries the label app.kubernetes.io/managed-by: runtime-check, delete it with: kubectl delete namespace runtime-check"* ]]
  absent -qE '^kubectl delete ' "$RECORD/argv"
  [ "$(order)" = 'created namespace runtime-check' ]
  nothing_secret
  reset
  : >"$STATE/fail.create-namespace"
  runtime_check kata
  [ "$status" -eq 1 ]
  [[ $output == *"no namespace runtime-check is on the cluster, though the run asked for one and got no answer; one with the label app.kubernetes.io/managed-by: runtime-check may yet come of that request: delete it with: kubectl delete namespace runtime-check"* ]]
  absent -qE '^kubectl delete ' "$RECORD/argv"
  [ ! -s "$RECORD/events" ]
  # A create the API server answered with a refusal made nothing: the run says no more than that.
  reset
  : >"$STATE/refuse.create-namespace"
  runtime_check kata
  [ "$status" -eq 1 ]
  [[ $output == *"kubectl: Error from server (Forbidden): "* ]]
  [[ $output == *"the namespace runtime-check could not be created"* ]]
  absent -q 'may yet come' <<<"$output"
  absent -qE '^kubectl delete ' "$RECORD/argv"
  [ ! -s "$RECORD/events" ]
  nothing_secret

  # The run's namespace, deleted while the run waits and made again by another party, as another
  # checkout's run does to an earlier run's: the run's own goes, with its pods, and the one in its
  # place, though it carries the label, is left alone.
  reset
  jq -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check", uid: "uid-theirs",
    labels: {"app.kubernetes.io/managed-by": "runtime-check", "pod-security.kubernetes.io/enforce": "restricted"}}}' >"$STATE/ns-replace"
  cp "$STATE/ns-replace" "$BATS_TEST_TMPDIR/theirs.json"
  runtime_check kata
  echo "what the cluster saw: $(order | paste -sd, -)"
  [ "$(order | tail -n 1)" = 'another party replaced namespace runtime-check' ]
  cmp "$STATE/namespace.json" "$BATS_TEST_TMPDIR/theirs.json"
  [ "$status" -eq 1 ]
  [ "$(checks)" = "$(printf 'FAIL  %s: the pod net is no longer on the cluster\n' kernel name service mtu)" ]
  [[ $output == *"the namespace runtime-check on the cluster is not the one the run made; it was left alone"* ]]
  nothing_secret

  # So too when that party has made pods of its own there under the same names, as another
  # checkout's run does, before the run makes its pod net, before it reads it as scheduled, or just
  # after: the run judges none of their pods, makes none of its own in their namespace, and fails,
  # saying its namespace went; their namespace and pods are left as they are, their events unshown.
  for at in get-serviceaccount-answered get-pods get-pods-answered; do
    reset
    jq -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check", uid: "uid-theirs",
      labels: {"app.kubernetes.io/managed-by": "runtime-check", "pod-security.kubernetes.io/enforce": "restricted"}}}' >"$STATE/ns-replace"
    echo "$at" >"$STATE/ns-replace-at"
    mkdir -p "$STATE/ns-replace-pods"
    jq -n '{apiVersion: "v1", kind: "Pod", metadata: {name: "net", namespace: "runtime-check", uid: "uid-theirs-net",
      labels: {"app.kubernetes.io/name": "runtime-check", "app.kubernetes.io/component": "net"}},
      spec: {restartPolicy: "Never", containers: [{name: "net", image: "registry.example/theirs:1"}]}}' >"$STATE/ns-replace-pods/net.json"
    jq -n '[{type: "Warning", reason: "BackOff", message: "their pod restarts", involvedObject: {kind: "Pod", name: "net", uid: "uid-theirs-net"}}]' >"$STATE/events.json"
    cp "$STATE/ns-replace" "$BATS_TEST_TMPDIR/theirs.json"
    cp "$STATE/ns-replace-pods/net.json" "$BATS_TEST_TMPDIR/their-net.json"
    runtime_check kata
    echo "what the cluster saw: $(order | paste -sd, -)"
    [ "$status" -eq 1 ]
    absent -q '^pass  ' <<<"$output"
    if [ "$at" = get-pods ]; then
      [ "$(checks)" = "$(printf 'FAIL  %s: the pod net is no longer on the cluster\n' kernel name service mtu)" ]
    else
      [ -z "$(checks)" ]
      [[ $output == *"the namespace runtime-check the run made is no longer on the cluster, so the run makes no more pods"* ]]
    fi
    made=$(printf '%s\n' 'created namespace runtime-check' 'created networkpolicy default-deny' 'created ciliumnetworkpolicy runtime-check')
    [ "$at" = get-serviceaccount-answered ] || made+=$'\ncreated pod net'
    [ "$(order)" = "$made"$'\n''another party replaced namespace runtime-check' ]
    cmp "$STATE/namespace.json" "$BATS_TEST_TMPDIR/theirs.json"
    [ "$(ls "$STATE/pods")" = net.json ]
    cmp "$STATE/pods/net.json" "$BATS_TEST_TMPDIR/their-net.json"
    absent -q 'their pod restarts' <<<"$output"
    [[ $output == *"the namespace runtime-check the run made is gone, and the run's deletion of it was not answered as done: another party deleted it, or the answer to that deletion was lost, and the run, unable to tell which, fails"* ]]
    [[ $output == *"the namespace runtime-check on the cluster is not the one the run made; it was left alone"* ]]
    nothing_secret
  done
  # Or between the run's last read of its namespace and its create of net, which no precondition can
  # close: the API server refuses the run's pod of the name theirs has, and the run fails, leaving
  # their namespace and pod as they are.
  reset
  jq -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check", uid: "uid-theirs",
    labels: {"app.kubernetes.io/managed-by": "runtime-check", "pod-security.kubernetes.io/enforce": "restricted"}}}' >"$STATE/ns-replace"
  echo create-net >"$STATE/ns-replace-at"
  mkdir -p "$STATE/ns-replace-pods"
  jq -n '{apiVersion: "v1", kind: "Pod", metadata: {name: "net", namespace: "runtime-check", uid: "uid-theirs-net",
    labels: {"app.kubernetes.io/name": "runtime-check", "app.kubernetes.io/component": "net"}},
    spec: {restartPolicy: "Never", containers: [{name: "net", image: "registry.example/theirs:1"}]}}' >"$STATE/ns-replace-pods/net.json"
  cp "$STATE/ns-replace" "$BATS_TEST_TMPDIR/theirs.json"
  cp "$STATE/ns-replace-pods/net.json" "$BATS_TEST_TMPDIR/their-net.json"
  runtime_check kata
  echo "what the cluster saw: $(order | paste -sd, -)"
  [ "$status" -eq 1 ]
  [ -z "$(checks)" ]
  [[ $output == *"kubectl: Error from server (AlreadyExists): "* ]]
  [[ $output == *"the pod net could not be created"* ]]
  [ "$(order)" = "$(printf '%s\n' 'created namespace runtime-check' 'created networkpolicy default-deny' \
    'created ciliumnetworkpolicy runtime-check' 'another party replaced namespace runtime-check')" ]
  cmp "$STATE/namespace.json" "$BATS_TEST_TMPDIR/theirs.json"
  [ "$(ls "$STATE/pods")" = net.json ]
  cmp "$STATE/pods/net.json" "$BATS_TEST_TMPDIR/their-net.json"
  [[ $output == *"the namespace runtime-check on the cluster is not the one the run made; it was left alone"* ]]
  nothing_secret
  # The run makes no pod in its namespace while another party's deletion of it is under way, before
  # net or before probe and reference, as that party may make its own of the name once it has gone.
  for at in get-serviceaccount-answered get-pods-answered; do
    reset
    : >"$STATE/ns-delete"
    echo 1 >"$STATE/ns-terminating"
    echo "$at" >"$STATE/ns-replace-at"
    runtime_check kata
    echo "what the cluster saw: $(order | paste -sd, -)"
    [ "$status" -eq 1 ]
    [ -z "$(checks)" ]
    [[ $output == *"the namespace runtime-check the run made is being deleted, so the run makes no more pods"* ]]
    made=$(printf '%s\n' 'created namespace runtime-check' 'created networkpolicy default-deny' 'created ciliumnetworkpolicy runtime-check')
    [ "$at" = get-serviceaccount-answered ] || made+=$'\ncreated pod net'
    [ "$(order)" = "$made"$'\n'"$(printf '%s\n' 'another party deleted namespace runtime-check' 'deleted namespace runtime-check' 'namespace runtime-check gone')" ]
    [ "$(grep -c '^kubectl create --request-timeout=30s --namespace=' "$RECORD/argv")" -eq "$(grep -c '^created pod ' <<<"$made")" ]
    [ ! -e "$STATE/namespace.json" ]
  done

  # Replaced, with pods of that party's under the same names, as the run reads its pods' logs, which
  # go by name: the run cannot tell that what it read was its own, and prints neither its header nor
  # a check, whichever log it had read last.
  for at in logs-net-answered logs-reference-answered logs-probe-answered; do
    reset
    jq -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check", uid: "uid-theirs",
      labels: {"app.kubernetes.io/managed-by": "runtime-check", "pod-security.kubernetes.io/enforce": "restricted"}}}' >"$STATE/ns-replace"
    echo "$at" >"$STATE/ns-replace-at"
    mkdir -p "$STATE/ns-replace-pods" "$BATS_TEST_TMPDIR/their-pods"
    for name in net probe reference; do
      jq -n --arg name "$name" '{apiVersion: "v1", kind: "Pod", metadata: {name: $name, namespace: "runtime-check", uid: "uid-theirs-\($name)",
        labels: {"app.kubernetes.io/name": "runtime-check", "app.kubernetes.io/component": $name}},
        spec: {restartPolicy: "Never", containers: [{name: (if $name == "probe" then "probe" else "net" end), image: "registry.example/theirs:1"}]}}' \
        >"$STATE/ns-replace-pods/$name.json"
      cp "$STATE/ns-replace-pods/$name.json" "$BATS_TEST_TMPDIR/their-pods/"
    done
    cp "$STATE/ns-replace" "$BATS_TEST_TMPDIR/theirs.json"
    runtime_check kata
    echo "what the cluster saw: $(order | paste -sd, -)"
    [ "$status" -eq 1 ]
    absent -q '^pass  ' <<<"$output"
    [ -z "$(checks)" ]
    absent -q '^runtime-check: kata on ' <<<"$output"
    [[ $output == *"the namespace runtime-check the run made is no longer on the cluster, so the logs the run read by its pods' names may be another party's, and it judges none of them"* ]]
    [ "$(order)" = "$(printf '%s\n' 'created namespace runtime-check' 'created networkpolicy default-deny' 'created ciliumnetworkpolicy runtime-check' \
      'created pod net' 'created pod probe' 'created pod reference' 'another party replaced namespace runtime-check')" ]
    cmp "$STATE/namespace.json" "$BATS_TEST_TMPDIR/theirs.json"
    diff -r "$STATE/pods" "$BATS_TEST_TMPDIR/their-pods"
    [[ $output == *"the namespace runtime-check on the cluster is not the one the run made; it was left alone"* ]]
    nothing_secret
  done
  # Replaced once the run has read all it reads and found its namespace still its own, as it comes to
  # delete it: what the run read was its own, and it prints its checks, but its deletion was not
  # answered as done, and it fails.
  reset
  jq -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check", uid: "uid-theirs",
    labels: {"app.kubernetes.io/managed-by": "runtime-check", "pod-security.kubernetes.io/enforce": "restricted"}}}' >"$STATE/ns-replace"
  echo delete-namespace >"$STATE/ns-replace-at"
  cp "$STATE/ns-replace" "$BATS_TEST_TMPDIR/theirs.json"
  runtime_check kata
  echo "what the cluster saw: $(order | paste -sd, -)"
  [ "$status" -eq 1 ]
  [ "$(checks)" = "$(good_checks)" ]
  [[ $output == *"the namespace runtime-check the run made is gone, and the run's deletion of it was not answered as done: another party deleted it, or the answer to that deletion was lost, and the run, unable to tell which, fails"* ]]
  [ "$(order | tail -n 1)" = 'another party replaced namespace runtime-check' ]
  cmp "$STATE/namespace.json" "$BATS_TEST_TMPDIR/theirs.json"
  # Replaced only once the run's own deletion of it is answered, the namespace was the run's
  # throughout: the run keeps its results, and leaves the new one alone.
  reset
  jq -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check", uid: "uid-theirs",
    labels: {"app.kubernetes.io/managed-by": "runtime-check", "pod-security.kubernetes.io/enforce": "restricted"}}}' >"$STATE/ns-replace"
  echo delete-namespace-answered >"$STATE/ns-replace-at"
  cp "$STATE/ns-replace" "$BATS_TEST_TMPDIR/theirs.json"
  runtime_check kata
  echo "what the cluster saw: $(order | paste -sd, -)"
  [ "$status" -eq 0 ]
  [ "$(checks)" = "$(good_checks)" ]
  [ "$(order | tail -n 2)" = "$(printf '%s\n' 'deleted namespace runtime-check' 'another party replaced namespace runtime-check')" ]
  [[ $output == *"the namespace runtime-check on the cluster is not the one the run made; it was left alone"* ]]
  absent -q 'was not answered as done' <<<"$output"
  cmp "$STATE/namespace.json" "$BATS_TEST_TMPDIR/theirs.json"
  # The run's own deletion whose answer is lost, though the namespace goes, is not answered as done:
  # the run cannot tell it from another party's, and fails.
  reset
  : >"$STATE/lost.delete-namespace"
  runtime_check kata
  [ "$status" -eq 1 ]
  [ "$(checks)" = "$(good_checks)" ]
  [[ $output == *"the namespace runtime-check the run made is gone, and the run's deletion of it was not answered as done: another party deleted it, or the answer to that deletion was lost, and the run, unable to tell which, fails"* ]]
  made_and_removed
  nothing_secret
  # Nor is one that finds no namespace, as when another party has deleted the run's, and made none in
  # its place, just before the run deletes it.
  reset
  : >"$STATE/ns-delete"
  echo delete-namespace >"$STATE/ns-replace-at"
  runtime_check kata
  echo "what the cluster saw: $(order | paste -sd, -)"
  [ "$status" -eq 1 ]
  [ "$(checks)" = "$(good_checks)" ]
  [ "$(order | tail -n 1)" = 'another party deleted namespace runtime-check' ]
  [[ $output == *"kubectl: Error from server (NotFound): "* ]]
  [[ $output == *"the namespace runtime-check the run made is gone, and the run's deletion of it was not answered as done: another party deleted it, or the answer to that deletion was lost, and the run, unable to tell which, fails"* ]]
  absent -q 'is not the one the run made' <<<"$output"
  [ ! -e "$STATE/namespace.json" ]

  # So too when another party puts its own namespace in place of an earlier run's as the run deletes
  # that: the deletion is refused, and the run stops before it makes anything.
  reset
  jq -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check",
    labels: {"app.kubernetes.io/managed-by": "runtime-check", "pod-security.kubernetes.io/enforce": "restricted"}}}' >"$STATE/namespace.json"
  jq -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check", uid: "uid-theirs", labels: {"team": "someone"}}}' >"$STATE/ns-replace"
  echo delete-namespace >"$STATE/ns-replace-at"
  cp "$STATE/ns-replace" "$BATS_TEST_TMPDIR/theirs.json"
  runtime_check kata
  echo "what the cluster saw: $(order | paste -sd, -)"
  [ "$(order)" = 'another party replaced namespace runtime-check' ]
  cmp "$STATE/namespace.json" "$BATS_TEST_TMPDIR/theirs.json"
  [ "$status" -eq 1 ]
  [[ $output == *"kubectl: Error from server (Conflict): "* ]]
  [[ $output == *"the earlier run's namespace runtime-check could not be deleted"* ]]
  absent -q '^kubectl create ' "$RECORD/argv"
  # And when it does so as soon as the earlier run's has gone: the run says what it found, and makes
  # nothing.
  reset
  jq -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check",
    labels: {"app.kubernetes.io/managed-by": "runtime-check", "pod-security.kubernetes.io/enforce": "restricted"}}}' >"$STATE/namespace.json"
  jq -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check", uid: "uid-theirs",
    labels: {"app.kubernetes.io/managed-by": "runtime-check", "pod-security.kubernetes.io/enforce": "restricted"}}}' >"$STATE/ns-replace"
  echo delete-namespace-answered >"$STATE/ns-replace-at"
  cp "$STATE/ns-replace" "$BATS_TEST_TMPDIR/theirs.json"
  runtime_check kata
  echo "what the cluster saw: $(order | paste -sd, -)"
  [ "$status" -eq 1 ]
  [ "$(order)" = "$(printf '%s\n' 'deleted namespace runtime-check' 'another party replaced namespace runtime-check')" ]
  [[ $output == *"the earlier run's namespace runtime-check went, and another party made one in its place; it was left alone"* ]]
  cmp "$STATE/namespace.json" "$BATS_TEST_TMPDIR/theirs.json"
  absent -q '^kubectl create ' "$RECORD/argv"
}

@test "The runtime check's probe runs under the security context OpenShell gives a sandbox's workload, and the cluster's Pod Security, admission rules and network policy leave its pods alone" {
  local pod probe expected file kyverno_out gator_out with pods
  runtime_check kata
  [ "$status" -eq 0 ]

  # The probe pod: OpenShell 0.1.9's workload pod as the probe can tell it, as a whole.
  probe=$(object Pod probe)
  expected=$(jq -cS -n --arg image "$PROBE_IMAGE" '{
    securityContext: {runAsUser: 10001, runAsGroup: 10001, runAsNonRoot: true, fsGroup: 10001, fsGroupChangePolicy: "OnRootMismatch",
      supplementalGroups: [], supplementalGroupsPolicy: "Strict", seccompProfile: {type: "RuntimeDefault"},
      sysctls: [{name: "net.ipv4.ip_unprivileged_port_start", value: "0"}]},
    containers: [{name: "probe", image: $image, imagePullPolicy: "IfNotPresent", args: ["capability-probe"],
      resources: {requests: {cpu: "50m", memory: "64Mi"}, limits: {memory: "128Mi"}},
      securityContext: {runAsUser: 10001, runAsGroup: 10001, runAsNonRoot: true, allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}},
      volumeMounts: [{name: "tmp", mountPath: "/tmp"}]}],
    volumes: [{name: "tmp", emptyDir: {sizeLimit: "16Mi"}}]}')
  if [ "$(jq -cS '.spec | {securityContext, containers, volumes}' <<<"$probe")" != "$expected" ]; then
    echo "the probe pod is not OpenShell 0.1.9's workload: the pod's security context of crates/openshell-driver-kubernetes/src/driver.rs L7497-7510 and the agent container's of L7584-7593, with the UID and GID of src/config.rs L487 and L794-822"
    echo "expected: $expected"
    echo "found:    $(jq -cS '.spec | {securityContext, containers, volumes}' <<<"$probe")"
    return 1
  fi
  [ "$(jq -c '.spec | keys' <<<"$probe")" \
    = '["activeDeadlineSeconds","affinity","automountServiceAccountToken","containers","enableServiceLinks","restartPolicy","runtimeClassName","securityContext","volumes"]' ]

  # net and reference: the agents' image, the script, restricted, a read-only root and no volume.
  for pod in net reference; do
    [ "$(object Pod "$pod" | jq -cS '.spec | {securityContext, containers: [.containers[] | .command |= .[0:2]], volumes}')" \
      = "$(jq -cS -n --arg image "$NET_IMAGE" --arg pod "$pod" '{securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532,
        seccompProfile: {type: "RuntimeDefault"}},
        containers: [{name: "net", image: $image, imagePullPolicy: "IfNotPresent", command: ["bash", "-c"],
          resources: {requests: {cpu: "10m", memory: "32Mi"}, limits: {memory: "64Mi"}},
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}}],
        volumes: null}')" ]
    [ "$(object Pod "$pod" | jq -r '.spec.containers[0].command[2]')" = "$(object Pod net | jq -r '.spec.containers[0].command[2]')" ]
  done
  [ "$(object Pod net | jq -c '.spec | keys')" \
    = '["activeDeadlineSeconds","automountServiceAccountToken","containers","enableServiceLinks","restartPolicy","runtimeClassName","securityContext"]' ]
  [ "$(object Pod reference | jq -c '.spec | keys')" \
    = '["activeDeadlineSeconds","affinity","automountServiceAccountToken","containers","enableServiceLinks","restartPolicy","securityContext"]' ]

  # What the three share: their labels, one run, the timeout as their deadline, no token, no service
  # links, and nothing of the host.
  for pod in probe net reference; do
    [ "$(object Pod "$pod" | jq -c '{metadata, spec: (.spec | {restartPolicy, activeDeadlineSeconds, automountServiceAccountToken, enableServiceLinks})}')" \
      = "$(jq -c -n --arg pod "$pod" '{metadata: {name: $pod, namespace: "runtime-check",
          labels: {"app.kubernetes.io/name": "runtime-check", "app.kubernetes.io/component": $pod}},
          spec: {restartPolicy: "Never", activeDeadlineSeconds: 60, automountServiceAccountToken: false, enableServiceLinks: false}}')" ]
  done

  # The namespace, its default deny exactly as the tree's, and its one allow: the resolver, on 53 over
  # UDP and TCP, for net and reference, and nothing in.
  [ "$(object Namespace runtime-check | jq -cS .)" = "$(jq -cS -n '{apiVersion: "v1", kind: "Namespace", metadata: {name: "runtime-check",
    labels: {"pod-security.kubernetes.io/enforce": "restricted", "app.kubernetes.io/managed-by": "runtime-check"}}}')" ]
  [ "$(object NetworkPolicy default-deny | jq -cS 'del(.metadata.namespace)')" \
    = "$(yq -o json "$ROOT/kubernetes/apps/base/security-system/networkpolicy-default-deny.yaml" | jq -cS .)" ]
  [ "$(object NetworkPolicy default-deny | jq -r .metadata.namespace)" = runtime-check ]
  [ "$(object CiliumNetworkPolicy runtime-check | jq -cS .)" = "$(jq -cS -n '{apiVersion: "cilium.io/v2", kind: "CiliumNetworkPolicy",
    metadata: {name: "runtime-check", namespace: "runtime-check"},
    spec: {endpointSelector: {matchLabels: {"app.kubernetes.io/name": "runtime-check"},
        matchExpressions: [{key: "app.kubernetes.io/component", operator: "In", values: ["net", "reference"]}]},
      enableDefaultDeny: {ingress: false, egress: false},
      egress: [{toEndpoints: [{matchLabels: {"k8s:io.kubernetes.pod.namespace": "kube-system", "k8s:k8s-app": "kube-dns"}}],
        toPorts: [{ports: [{port: "53", protocol: "UDP"}, {port: "53", protocol: "TCP"}]}]}]}}')" ]

  # Pod Security: each pod passes restricted by Kyverno's podSecurity rule, and the exceptions list
  # has no entry for the namespace.
  for pod in probe net reference; do
    object Pod "$pod" | yq -P . >"$BATS_TEST_TMPDIR/$pod.yaml"
    restricted_failures "$BATS_TEST_TMPDIR/$pod.yaml" runtime-check
    echo "$pod: failed controls: $(paste -sd' ' "$CONTROLS") $(cat "$FORBIDDEN")"
    [ ! -s "$CONTROLS" ]
    [ ! -s "$FORBIDDEN" ]
  done
  [ "$(yq '[.exceptions[] | select(.namespace == "runtime-check")] | length' "$ROOT/pod-security-exceptions.yaml")" -eq 0 ]

  # The tree's admission rules in both engines, the rules as the render holds them: nothing found in
  # the pods or the namespace, while a pod beside them that breaks the rules is found. Three rules
  # are in both engines; sandbox-tier, Kyverno's alone, matches only a namespace labelled
  # k8s-gitops/sandbox, which this one is not.
  real_render
  with="$BATS_TEST_TMPDIR/engines"
  mkdir -p "$with"
  pods="$with/pods.yaml"
  for pod in probe net reference; do
    printf -- '---\n' >>"$pods"
    object Pod "$pod" >>"$pods"
  done
  object Namespace runtime-check | jq -c '{apiVersion, kind, metadata}' | sed 's/^/---\n/' >"$with/namespaces.yaml"
  object Namespace runtime-check | jq -c '{apiVersion: "cli.kyverno.io/v1alpha1", kind: "Values",
    namespaceSelector: [{name: .metadata.name, labels: .metadata.labels}]}' >"$with/values.yaml"
  for file in "$REAL"/*/kyverno-policies/*.yaml; do
    printf -- '---\n' >>"$with/kyverno.yaml"
    cat "$file" >>"$with/kyverno.yaml"
  done
  for file in "$REAL"/*/gatekeeper-templates/*.yaml "$REAL"/*/gatekeeper-policies/*.yaml; do
    printf -- '---\n' >>"$with/gatekeeper.yaml"
    cat "$file" >>"$with/gatekeeper.yaml"
  done
  [ "$(yq -N 'select(.kind == "ValidatingPolicy") | .metadata.name' "$with/kyverno.yaml" | sort | paste -sd' ')" \
    = 'image-pinned namespace-pod-security-level restricted-security-context sandbox-tier' ]
  run kyverno apply "$with/kyverno.yaml" --resource "$pods" --resource "$with/namespaces.yaml" --values-file "$with/values.yaml"
  kyverno_out=$output
  echo "Kyverno: $kyverno_out"
  [ "$status" -eq 0 ]
  [[ $kyverno_out =~ pass:\ ([0-9]+),\ fail:\ 0, ]]
  [ "${BASH_REMATCH[1]}" -ge 7 ]
  run gator test --filename "$with/gatekeeper.yaml" --filename "$pods" --filename "$with/namespaces.yaml" --output json
  gator_out=$output
  echo "Gatekeeper: $gator_out"
  [ "$(jq 'length' <<<"$gator_out")" -eq 0 ]
  printf -- '---\n%s\n' '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"broken","namespace":"runtime-check"},"spec":{"containers":[{"name":"broken","image":"registry.example/broken:latest"}]}}' >>"$pods"
  run kyverno apply "$with/kyverno.yaml" --resource "$pods" --resource "$with/namespaces.yaml" --values-file "$with/values.yaml"
  [ "$status" -ne 0 ]
  grep -q 'policy restricted-security-context -> resource .*broken' <<<"$output"
  grep -q 'policy image-pinned -> resource .*broken' <<<"$output"
  run gator test --filename "$with/gatekeeper.yaml" --filename "$pods" --filename "$with/namespaces.yaml" --output json
  echo "Gatekeeper, with a pod that breaks the rules: $output"
  [ "$(jq -c '[.[] | .constraint.metadata.name] | unique' <<<"$output")" = '["image-pinned","restricted-security-context"]' ]
  [ "$(jq 'all(.[]; .msg | test("broken"))' <<<"$output")" = true ]

  # Network policy: over a copy of the render with the namespace's objects added, net and reference
  # reach the resolver alone, the probe nothing, and nothing reaches any of them; the check passes.
  WITH="$BATS_TEST_TMPDIR/render"
  cp -R "$REAL" "$WITH"
  file="$WITH/lab-sto2/runtime-check"
  mkdir -p "$file"
  object Namespace runtime-check | yq -P . >"$file/Namespace__runtime-check.yaml"
  object NetworkPolicy default-deny | yq -P . >"$file/NetworkPolicy.networking.k8s.io_runtime-check_default-deny.yaml"
  object CiliumNetworkPolicy runtime-check | yq -P . >"$file/CiliumNetworkPolicy.cilium.io_runtime-check_runtime-check.yaml"
  for pod in probe net reference; do
    object Pod "$pod" | yq -P . >"$file/Pod_runtime-check_$pod.yaml"
  done
  run "$ROOT/scripts/network-policy-check" "$WITH" "$ROOT/network-policy-exceptions.yaml"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qx 'runtime-check denies ingress and egress' <<<"$output"
  VIEW="$BATS_TEST_TMPDIR/view"
  mkdir -p "$VIEW"
  (cd "$WITH" && find . -type f \( -name 'Namespace_*' -o -name 'Deployment.apps_*' -o -name 'StatefulSet.apps_*' \
    -o -name 'DaemonSet.apps_*' -o -name 'Job.batch_*' -o -name 'CronJob.batch_*' -o -name 'Pod_*' \
    -o -name 'NetworkPolicy.*' -o -name 'CiliumNetworkPolicy.*' -o -name 'CiliumClusterwideNetworkPolicy.*' \) -exec cp --parents {} "$VIEW/" \;)
  for pod in net reference; do
    allowed "runtime-check/Pod/$pod" kube-system:k8s-app=kube-dns 53/udp
    allowed "runtime-check/Pod/$pod" kube-system:k8s-app=kube-dns 53/tcp
    denied "runtime-check/Pod/$pod" kube-system:k8s-app=kube-dns 9153/tcp
    denied "runtime-check/Pod/$pod" @kube-apiserver 443/tcp
    denied "runtime-check/Pod/$pod" @kube-apiserver 6443/tcp
    denied "runtime-check/Pod/$pod" @world 443/tcp
    denied "runtime-check/Pod/$pod" @world 53/udp
    denied "runtime-check/Pod/$pod" @host 53/udp
    denied "runtime-check/Pod/$pod" @remote-node 10250/tcp
    denied "runtime-check/Pod/$pod" kube-system:k8s-app=hubble-relay 4245/tcp
    denied "runtime-check/Pod/$pod" kromgo/Deployment/kromgo 8080/tcp
    denied "runtime-check/Pod/$pod" runtime-check/Pod/probe 53/tcp
  done
  for pod in probe net reference; do
    denied @world "runtime-check/Pod/$pod" 53/tcp
    denied @host "runtime-check/Pod/$pod" 8080/tcp
    denied @kube-apiserver "runtime-check/Pod/$pod" 443/tcp
    denied monitoring:app.kubernetes.io/name=prometheus "runtime-check/Pod/$pod" 9090/tcp
    denied kromgo/Deployment/kromgo "runtime-check/Pod/$pod" 53/udp
  done
  denied runtime-check/Pod/probe kube-system:k8s-app=kube-dns 53/udp
  denied runtime-check/Pod/probe @world 443/tcp
  denied runtime-check/Pod/probe @kube-apiserver 443/tcp
  denied runtime-check/Pod/net runtime-check/Pod/reference 53/udp
}

@test "The runtime check's images are pinned by digest where Renovate moves them: OpenShell's sandbox on its stable releases, the Cilium agents' image with its chart" {
  local recorder rule allowed tag
  # Each image under its comment and a renovate line the justfile's manager reads, by tag and digest.
  # The probe pod and the kernel check follow OpenShell 0.1.9, so a new tag or digest is read against
  # them before this line changes.
  if [ "$PROBE_IMAGE" != 'ghcr.io/nvidia/openshell/sandbox:0.1.9@sha256:e57d07cd6cc1fc314b80368d6b51ec6fbf825fb62cd8f081312941180846866f' ]; then
    echo "openshell_sandbox_image is $PROBE_IMAGE, not OpenShell 0.1.9's sandbox image. At the new release, check and carry over:"
    echo "  the workload pod's security context, crates/openshell-driver-kubernetes/src/driver.rs, against the probe pod of scripts/runtime-check and the expected context and its message in this file's test of the probe's security context;"
    echo "  the capability-probe subcommand and the report's fields, crates/openshell-sandbox/src/main.rs, against the kernel check of scripts/runtime-check and tests/fixtures/runtime-check/probe.log;"
    echo "  the support matrix link at v0.1.9 and 'OpenShell 0.1.9' in docs/kubernetes.md, and the release in scripts/runtime-check's comments;"
    echo "  then the image this test expects."
    return 1
  fi
  [ "$(grep -B1 '^openshell_sandbox_image := ' "$ROOT/justfile" | head -n 1)" = '# renovate: datasource=docker depName=ghcr.io/nvidia/openshell/sandbox' ]
  [ "$(grep -B2 '^openshell_sandbox_image := ' "$ROOT/justfile" | head -n 1 | cut -c1-2)" = '# ' ]
  [ "$(grep -B1 '^cilium_agent_image := ' "$ROOT/justfile" | head -n 1)" = '# renovate: datasource=docker depName=quay.io/cilium/cilium' ]
  [ "$(grep -B2 '^cilium_agent_image := ' "$ROOT/justfile" | head -n 1 | cut -c1-2)" = '# ' ]
  for tag in "$PROBE_IMAGE" "$NET_IMAGE"; do
    [[ $tag =~ ^[a-z0-9./-]+:[A-Za-z0-9_.-]+@sha256:[0-9a-f]{64}$ ]] || { echo "$tag is not pinned by tag and digest"; return 1; }
  done
  # The agents' image is the flow recorder's, tag and digest, which tests/network-audit.bats holds to
  # the one the Cilium chart gives the agents.
  recorder=$(yq '.spec.template.spec.containers[] | select(.name == "hubble") | .image' \
    "$ROOT/kubernetes/apps/base/security-system/network-audit/app/deployment.yaml")
  if [ "$NET_IMAGE" != "$recorder" ]; then
    echo "set cilium_agent_image in the justfile to $recorder, the flow recorder's image in kubernetes/apps/base/security-system/network-audit/app/deployment.yaml"
    return 1
  fi
  # The recipe hands the script both, and the script names no image of its own.
  [ "$(sed -n '/^runtime-check class /,/^$/p' "$ROOT/just/cluster.just" | sed -n 2p)" \
    = "    scripts/runtime-check '{{ openshell_sandbox_image }}' '{{ cilium_agent_image }}' {{ quote(class) }} {{ quote(cluster) }}" ]
  absent -nE '[a-z0-9-]+\.[a-z]{2,}(:[0-9]+)?/[a-z0-9./-]+(:[A-Za-z0-9_.-]+|@sha256)' "$ROOT/scripts/runtime-check"

  # Renovate: the tags of OpenShell's sandbox as its registry lists them, its stable releases alone
  # proposed, one group for OpenShell, never merged by itself; both pins in the extraction record.
  [ "$(awk -F'\t' '$1 == "docker" && $2 == "ghcr.io/nvidia/openshell/sandbox" && $4 != "" { print $3 }' "$ROOT/.renovate/tag-forms.tsv")" \
    = '^[0-9]+\.[0-9]+\.[0-9]+$' ]
  rule=$(json5_rules managers | jq -c '[.[] | select(.matchPackageNames == ["ghcr.io/nvidia/openshell/**"])]')
  [ "$(jq length <<<"$rule")" -eq 1 ]
  allowed=$(jq -r '.[0].allowedVersions' <<<"$rule")
  [ "$allowed" = '/^[0-9]+\.[0-9]+\.[0-9]+$/' ]
  allowed=${allowed#/}
  allowed=${allowed%/}
  tag=${PROBE_IMAGE#*:}
  tag=${tag%@*}
  [[ $tag =~ $allowed ]]
  for tag in 0.1.10-pre.2 ce58cf8e9b953281352d98a637e41616295b1318 ce58cf8e9b953281352d98a637e41616295b1318-amd64 latest; do
    [[ ! $tag =~ $allowed ]] || { echo "$tag is allowed"; return 1; }
  done
  [ "$(json5_rules groups | jq -c '[.[] | select(.groupName == "OpenShell")] | map(.matchPackageNames)')" = '[["ghcr.io/nvidia/openshell/**"]]' ]
  [ "$(json5_rules automerge | jq -c '[.[] | select(.matchPackageNames == ["ghcr.io/nvidia/openshell/**"])] | map(.automerge)')" = '[false]' ]
  # The Cilium group and the CNI's rule already take the agents' image.
  [ "$(json5_rules groups | jq -r '.[] | select(.groupName == "Cilium") | .matchPackageNames | index("quay.io/cilium/**") != null')" = true ]
  grep -qxF "$(printf 'justfile\tregex\tghcr.io/nvidia/openshell/sandbox\topenshell_sandbox_image')" "$ROOT/.renovate/extracted.tsv"
  grep -qxF "$(printf 'justfile\tregex\tquay.io/cilium/cilium\tcilium_agent_image')" "$ROOT/.renovate/extracted.tsv"
}

# json5_rules NAME: the packageRules of .renovate/NAME.json5 as a JSON list, read as the other tests
# read them, the comment lines taken out.
json5_rules() {
  grep -v '^[[:space:]]*//' "$ROOT/.renovate/$1.json5" | yq -o json -I0 '.packageRules'
}

# shellcheck disable=SC2016 # The backquotes are the docs' own.
@test "The docs say what the runtime check does and when to run it" {
  local paragraph section text
  section=$(awk '/^## / { inside = ($0 == "## Runtime classes") } inside' "$ROOT/docs/kubernetes.md")
  [ "$(grep -c '^\*\*Whether a runtime class can host a sandbox\.\*\*' <<<"$section")" -eq 1 ]
  [ "$(grep -c '^\*\*Whether a runtime class can host a sandbox\.\*\*' "$ROOT/docs/kubernetes.md")" -eq 1 ]
  # The paragraph, joined into one line.
  paragraph=$(awk '/^\*\*Whether a runtime class can host a sandbox\.\*\*/ { inside = 1 } inside && /^$/ { exit } inside' "$ROOT/docs/kubernetes.md" | tr -s '\n ' '  ')
  echo "$paragraph"
  for text in '`just runtime-check' '`kernel`' '`name`' '`service`' '`mtu`' '`RUNTIME_CHECK_TIMEOUT`' 'runtime-check' \
    'https://github.com/NVIDIA/OpenShell/blob/v0.1.9/docs/about/support-matrix.mdx' \
    'https://github.com/cilium/cilium/blob/v1.20.4/Documentation/network/kubernetes/kata.rst#limitations' \
    'user and group 10001' '`supplementalGroupsPolicy: Strict`' '`net.ipv4.ip_unprivileged_port_start=0`' 'every capability dropped' \
    '`restricted`' 'default deny' 'lock' 'judges no class' \
    'Run it after every change of the node image' 'after a change of Cilium'"'"'s values'; do
    [[ $paragraph == *"$text"* ]] || { echo "the paragraph does not say: $text"; return 1; }
  done
  # No sentence says any longer that no workload selects a runtime class without naming the recipe.
  absent -q 'A pod selects one with `runtimeClassName`; none does\.' "$ROOT/docs/kubernetes.md"
  absent -q '^No workload selects either runtime class\.' "$ROOT/docs/cluster.md"
  tr -s '\n ' '  ' <"$ROOT/docs/kubernetes.md" | grep -qF 'No workload of the tree selects one; `just runtime-check` runs pods under the class it is given'
  tr -s '\n ' '  ' <"$ROOT/docs/cluster.md" | grep -qF 'No workload of the tree selects either runtime class; `just runtime-check` runs pods under the one it is given'
}
