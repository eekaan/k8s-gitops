#!/usr/bin/env bats
# Proves features/cluster-lifecycle.feature; each test carries its scenario's title.
# cluster-check, cluster-reboot and cluster-destroy run from a copy of the repository with an
# environment of their own, so no run reads this checkout's .env, keys or kubeconfig. Whatever would
# reach a node, the cluster or the cloud is a recording fake: kubectl and talman are
# tests/fixtures/cluster-lifecycle/kubectl and talman, which answer from files in STATE; tofu plans
# and destroys from tests/fixtures/cluster-lifecycle/destroy-plan.json; openstack, helm, rclone and
# talosctl fail when called. sleep is the real one under the fakes' directory as its name, so that a
# probe left running is found by its command line, as are the fakes and the copy's scripts.

setup_file() {
  # The Talos check's fixture cluster: talos/talman.yaml.tftpl rendered from tests/fixtures/talos,
  # as talos/<cluster>/talman.yaml is rendered from the cluster stack.
  local encoded
  encoded=$(tofu -chdir="$BATS_TEST_DIRNAME/fixtures/talos" console -no-color <<< 'base64encode(local.talman_yaml)')
  base64 -d <<< "${encoded//\"/}" > "$BATS_FILE_TMPDIR/talman.yaml"
}

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/cluster-lifecycle"
  JUST=$(command -v just)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  # The recipes' TMPDIR, which must hold nothing once they have ended.
  WORK="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$BIN" "$RECORD" "$STATE" "$WORK" "$BATS_TEST_TMPDIR/keys" \
    "$BATS_TEST_TMPDIR/repo/talos/lab-sto2/clusterconfig"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  CLUSTER="$REPO/talos/lab-sto2"
  STACK="$REPO/infra/openstack/stacks/sto2/cluster"
  PLUMBING="$REPO/infra/openstack/stacks/sto2/plumbing"
  mkdir -p "$STACK" "$PLUMBING"
  # The scripts, the backend file and both stacks' configuration, without anything a stack's
  # directory holds that git ignores.
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp "$ROOT/infra/openstack/backend.hcl" "$REPO/infra/openstack/backend.hcl"
  cp "$ROOT"/infra/openstack/stacks/sto2/cluster/*.tf "$STACK/"
  cp "$ROOT"/infra/openstack/stacks/sto2/plumbing/*.tf "$PLUMBING/"
  # A git repository with this repository's ignore rules, as infra-destroy removes only what git
  # ignores.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q "$REPO"
  cp "$ROOT/.gitignore" "$REPO/.gitignore"
  cp "$BATS_FILE_TMPDIR/talman.yaml" "$CLUSTER/talman.yaml"
  KEY="$BATS_TEST_TMPDIR/keys/talos.agekey"
  echo 'AGE-SECRET-KEY-MARKER-AGE-KEY-FILE' > "$KEY"
  printf 'cluster:\n  secret: marker-bundle-secret\n' > "$CLUSTER/secrets.sops.yaml"
  echo 'marker-talosconfig' > "$CLUSTER/clusterconfig/talosconfig"
  KUBE_API_ADDRESS=203.0.113.80
  cat > "$CLUSTER/clusterconfig/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: lab-sto2
    cluster:
      server: https://$KUBE_API_ADDRESS:6443
      certificate-authority-data: marker-certificate-authority-data
users:
  - name: admin@lab-sto2
    user:
      client-key-data: marker-client-key-data
contexts:
  - name: admin@lab-sto2
    context:
      cluster: lab-sto2
      user: admin@lab-sto2
current-context: admin@lab-sto2
EOF
  GENERATED=(talman.yaml clusterconfig/talosconfig clusterconfig/kubeconfig)
  cp -R "$CLUSTER" "$BATS_TEST_TMPDIR/cluster.before"

  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise < /dev/null
  cp "$FIXTURES/kubectl" "$FIXTURES/talman" "$BIN/"
  yq '.nodes[].hostname' "$CLUSTER/talman.yaml" > "$STATE/nodes"
  local real_sleep
  real_sleep=$(command -v sleep)
  fake sleep <<EOF
exec -a "\$0" "$real_sleep" "\$@"
EOF
  # tofu prints a resource and an address as its own report, and plans the cluster stack's
  # destruction.
  TOFU_REPORT='module.nodes.openstack_networking_port_v2.node at 198.51.100.71'
  fake tofu <<EOF
printf '%s\n' "tofu \$*" >> "$RECORD/argv"
case \${2-} in
  init | plan | apply) echo "$TOFU_REPORT: tofu's own report" ;;
  show) cat "$FIXTURES/destroy-plan.json" ;;
  output) cat "$FIXTURES/outputs.json" ;;
esac
EOF
  for tool in openstack helm rclone talosctl; do
    fake "$tool" <<EOF
printf '%s\n' "$tool \$*" >> "$RECORD/argv"
echo "unexpected call: $tool \$*" >&2
exit 1
EOF
  done
  BASE_ENVIRONMENT=(
    SOPS_AGE_KEY_FILE="$KEY"
    KUBE_API_ADDRESS="$KUBE_API_ADDRESS"
    TMPDIR="$WORK"
    TF_STATE_BUCKET=fixture-state-bucket
    AWS_ACCESS_KEY_ID=marker-access-key-id
    AWS_SECRET_ACCESS_KEY=marker-secret-access-key
    TF_STATE_PASSPHRASE=marker-state-passphrase
    OS_AUTH_URL=https://identity.example.invalid/v3
    'OPERATOR_CIDRS=["203.0.113.77/32"]'
  )
  reset_environment
  CHECKS=('/readyz' 'nodes Ready' 'node count' 'no kube-proxy' 'pods in kube-system' 'pods in flux-system'
    'certificate requests' 'pod logs')
}

teardown() {
  # A run that left a process behind must not hold up the tests that follow.
  local pid _
  while read -r pid _; do
    kill -9 "$pid" 2> /dev/null || true
  done < <(leftovers)
}

# fake NAME: a binary first on the recipe's PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

reset_environment() {
  ENVIRONMENT=("${BASE_ENVIRONMENT[@]}")
}

# without NAME: drops NAME from the environment the recipes get.
without() {
  local kept=() entry
  for entry in "${ENVIRONMENT[@]}"; do
    [[ $entry == "$1="* ]] || kept+=("$entry")
  done
  ENVIRONMENT=("${kept[@]}")
}

# with ENTRY...: adds the NAME=VALUE ENTRY... to the environment the recipes get.
with() {
  ENVIRONMENT+=("$@")
}

# recipe NAME [ARG...]: runs the repository's recipe against the copy, with only ENVIRONMENT set,
# and sets status and output as bats' run does. The output goes through a file and bats' own
# descriptor 3 is closed, so a process the recipe leaves behind cannot keep the test waiting; a
# recipe that blocks fails after two minutes.
recipe() {
  local out="$BATS_TEST_TMPDIR/recipe.out"
  status=0
  timeout 120 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$@" > "$out" 2>&1 3>&- || status=$?
  output=$(< "$out")
}

# reset_cluster: a healthy cluster of every node in talman.yaml, which no recipe has run against.
reset_cluster() {
  find "$STATE" -mindepth 1 -delete
  yq '.nodes[].hostname' "$BATS_FILE_TMPDIR/talman.yaml" > "$STATE/nodes"
  rm -f "$RECORD"/*
}

# line_of CHECK: cluster-check's line for CHECK.
line_of() {
  grep -F -- "  $1: " <<< "$output" || true
}

# script_lines: the recipe's own lines of the last run, without just's line about a failed recipe.
script_lines() {
  grep -v '^error: recipe ' <<< "$output" || true
}

# calls PATTERN: the recorded calls matching the extended regex, one per line.
calls() {
  grep -E -- "$1" "$RECORD/argv" 2> /dev/null || true
}

# call_line PATTERN: the line number in the record of the first call matching the extended regex.
call_line() {
  grep -n -m1 -E -- "$1" "$RECORD/argv" | cut -d: -f1
}

# last_call_line PATTERN: the line number in the record of the last call matching the extended regex.
last_call_line() {
  grep -n -E -- "$1" "$RECORD/argv" | tail -1 | cut -d: -f1
}

# probes: how many times /readyz has been asked.
probes() {
  calls '^kubectl get --raw /readyz ' | wc -l
}

# reported: from cluster-reboot's output, how many probes it made, how many failed and the longest
# run of failures in seconds, on one line.
reported() {
  [[ $output =~ /readyz\ asked\ ([0-9]+)\ times,\ ([0-9]+)\ failed\;\ longest\ run\ of\ failures\ ([0-9]+)s ]] || return 1
  echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
}

# leftovers: each process still running whose command line names this test's directory, such as a
# fake, the real sleep under its fake's name or a copy's script, as its PID and command line.
leftovers() {
  local file pid
  local -a argv
  for file in /proc/[0-9]*/cmdline; do
    pid=${file#/proc/}
    pid=${pid%/cmdline}
    [[ $pid != "$$" && $pid != "$BASHPID" ]] || continue
    mapfile -d '' -t argv 2> /dev/null < "$file" || continue
    if [[ " ${argv[*]} " == *"$BATS_TEST_TMPDIR/"* ]]; then
      printf '%s %s\n' "$pid" "${argv[*]}"
    fi
  done
  return 0
}

# nothing_left: no process of the run is left, its TMPDIR is empty, and no probe follows its end.
nothing_left() {
  local left asked
  left=$(leftovers)
  if [[ -n $left ]]; then
    echo "left running: $left" >&2
    return 1
  fi
  left=$(find "$WORK" -mindepth 1)
  if [[ -n $left ]]; then
    echo "left on disk: $left" >&2
    return 1
  fi
  asked=$(probes)
  sleep 1.5
  [ "$(probes)" -eq "$asked" ]
}

# generated_kept: the files generated for the cluster are where they were.
generated_kept() {
  local file
  for file in "${GENERATED[@]}"; do
    [ -f "$CLUSTER/$file" ]
  done
}

# restore_generated: the files generated for the cluster as they were before any run.
restore_generated() {
  local file
  for file in "${GENERATED[@]}"; do
    cp "$BATS_TEST_TMPDIR/cluster.before/$file" "$CLUSTER/$file"
  done
}

# no_tofu: tofu has not run.
no_tofu() {
  [ -z "$(calls '^tofu ')" ]
}

@test "A healthy cluster passes every check" {
  recipe cluster-check

  [ "$status" -eq 0 ]
  for check in "${CHECKS[@]}"; do
    [[ $(line_of "$check") == "pass  $check: "* ]]
  done
  [ "$(grep -cE '^(pass|FAIL|skip)  ' <<< "$output")" -eq "${#CHECKS[@]}" ]
  [[ $(line_of 'nodes Ready') == *"6 nodes"* ]]
  [[ $output == *"cluster-check: every check of lab-sto2 passes"* ]]

  # The same cluster by name.
  recipe cluster-check lab-sto2

  [ "$status" -eq 0 ]
}

@test "Each unhealthy condition fails its own check and is named" {
  conditions=(readyz not-ready missing kube-proxy kube-system-pod flux-system-pod pending-csr logs)
  for condition in "${conditions[@]}"; do
    echo "$condition"
    reset_cluster
    case $condition in
      readyz)
        : > "$STATE/readyz-fails"
        check='/readyz' named='no answer'
        ;;
      not-ready)
        echo worker-2 > "$STATE/not-ready"
        check='nodes Ready' named=worker-2
        ;;
      missing)
        yq '.nodes[].hostname' "$CLUSTER/talman.yaml" | grep -vx worker-3 > "$STATE/nodes"
        check='node count' named=worker-3
        ;;
      kube-proxy)
        : > "$STATE/kube-proxy"
        check='no kube-proxy' named=kube-system/kube-proxy-q3r4s
        ;;
      kube-system-pod)
        echo 'kube-system coredns-failing Failed' > "$STATE/pods"
        check='pods in kube-system' named=kube-system/coredns-failing
        ;;
      flux-system-pod)
        echo 'flux-system helm-controller-pending Pending' > "$STATE/pods"
        check='pods in flux-system' named=flux-system/helm-controller-pending
        ;;
      pending-csr)
        : > "$STATE/pending-csr"
        check='certificate requests' named=csr-pending-1
        ;;
      logs)
        : > "$STATE/logs-fail"
        check='pod logs' named=kube-system/
        ;;
    esac

    recipe cluster-check

    [ "$status" -ne 0 ]
    [[ $(line_of "$check") == "FAIL  $check: "*"$named"* ]]
    for other in "${CHECKS[@]}"; do
      if [[ $other != "$check" ]]; then
        [[ $(line_of "$other") == "pass  $other: "* ]]
      fi
    done
    [[ $output == *"cluster-check: 1 of ${#CHECKS[@]} checks failed"* ]]
  done
  # Neither the approved nor the denied request is Pending.
  [[ $output != *csr-approved-1* && $output != *csr-denied-1* ]]
}

@test "The health check changes nothing in the cluster" {
  snapshot() {
    (cd "$REPO" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum)
  }
  before=$(snapshot)
  recipe cluster-check
  [ "$status" -eq 0 ]
  echo worker-1 > "$STATE/not-ready"
  : > "$STATE/kube-proxy"
  : > "$STATE/pending-csr"
  : > "$STATE/logs-fail"

  recipe cluster-check

  [ "$status" -ne 0 ]
  calls '^kubectl get ' | grep -q .
  calls '^kubectl logs ' | grep -q .
  # Every call the record holds is a kubectl get or logs.
  [ "$(grep -cvE '^kubectl (get|logs) ' "$RECORD/argv")" -eq 0 ]
  [ "$(snapshot)" = "$before" ]
}

@test "Before Flux is installed the Flux checks are skipped, and said to be" {
  : > "$STATE/no-flux"

  recipe cluster-check

  [ "$status" -eq 0 ]
  [[ $(line_of 'pods in flux-system') == "skip  pods in flux-system: the namespace flux-system does not exist"* ]]
  for check in "${CHECKS[@]}"; do
    if [[ $check != 'pods in flux-system' ]]; then
      [[ $(line_of "$check") == "pass  $check: "* ]]
    fi
  done
  [[ ${output##*$'\n'} == *"skipped: pods in flux-system"* ]]

  # A failing pod in kube-system still fails without Flux.
  echo 'kube-system coredns-failing Pending' > "$STATE/pods"

  recipe cluster-check

  [ "$status" -ne 0 ]
  [[ $(line_of 'pods in kube-system') == "FAIL  pods in kube-system: "*kube-system/coredns-failing* ]]
  [[ $(line_of 'pods in flux-system') == "skip  "* ]]
}

@test "A reboot that the API rides out passes" {
  recipe cluster-reboot cp-2 <<< cp-2

  [ "$status" -eq 0 ]
  [[ $output == *"Type cp-2 to reboot it"* ]]
  [ "$(cat "$STATE/rebooted")" = cp-2 ]
  reboots=$(calls '^talman reboot( |$)' | grep -v finished)
  [ "$(wc -l <<< "$reboots")" -eq 1 ]
  [ "$reboots" = 'talman reboot -n cp-2 --yes --extra-flags=--drain=false' ]
  # The probe asked /readyz, with a short timeout, while talman rebooted the node.
  started=$(call_line '^talman reboot -n ')
  finished=$(call_line '^talman reboot finished')
  during=$(awk -v from="$started" -v to="$finished" 'NR > from && NR < to && /^kubectl get --raw \/readyz /' "$RECORD/argv" | wc -l)
  [ "$during" -ge 2 ]
  [ "$(calls '^kubectl get --raw /readyz' | grep -cv -- ' --request-timeout=2s')" -eq 0 ]
  # The node was read after the reboot, until it reported Ready.
  [ "$(last_call_line '^kubectl get nodes ')" -gt "$finished" ]
  read -r asked failed _ <<< "$(reported)"
  [ "$asked" -ge "$during" ]
  [ "$failed" -eq 0 ]
  [ ! -e "$RECORD/readyz-refused" ]
  [[ $output == *"cp-2 is Ready again"* ]]

  reset_cluster

  recipe cluster-reboot cp-2 --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output != *"Type cp-2"* ]]
  [ "$(cat "$STATE/rebooted")" = cp-2 ]
}

@test "A reboot during which the API stops answering fails and reports the gap" {
  echo 3 > "$STATE/reboot-gap"

  recipe cluster-reboot cp-1 --yes < /dev/null

  [ "$status" -ne 0 ]
  read -r asked failed longest <<< "$(reported)"
  refused=$(wc -l < "$RECORD/readyz-refused")
  [ "$refused" -ge 2 ]
  [ "$failed" -eq "$refused" ]
  [ "$asked" -gt "$failed" ]
  [ "$longest" -ge 2 ]
  [[ $output == *"--tolerate"* ]]
  # The node itself came back: the gap alone fails the run.
  [ -e "$STATE/back.cp-1" ]
  [[ $output != *"has not reported Ready"* ]]
}

@test "A tolerated gap passes and is still reported" {
  echo 2 > "$STATE/reboot-gap"

  recipe cluster-reboot cp-1 --tolerate 30 --yes < /dev/null

  [ "$status" -eq 0 ]
  read -r _ failed longest <<< "$(reported)"
  [ "$failed" -ge 1 ]
  [ "$longest" -ge 1 ]
  [ "$failed" -eq "$(wc -l < "$RECORD/readyz-refused")" ]
  [[ $output == *"within the 30s tolerated"* ]]

  reset_cluster
  echo 3 > "$STATE/reboot-gap"

  recipe cluster-reboot cp-1 --yes --tolerate=1 < /dev/null

  [ "$status" -ne 0 ]
  read -r _ _ longest <<< "$(reported)"
  [ "$longest" -gt 1 ]
}

@test "A node that does not come back fails when the wait runs out" {
  : > "$STATE/never-back"
  with REBOOT_WAIT=4

  recipe cluster-reboot cp-3 --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"cp-3 has not reported Ready since its reboot"* ]]
  finished=$(call_line '^talman reboot finished')
  asked=$(awk -v from="$finished" 'NR > from && /^kubectl get nodes /' "$RECORD/argv" | wc -l)
  [ "$asked" -ge 2 ]
  reported > /dev/null
}

@test "A node that is not in the cluster is refused before anything is rebooted" {
  address=$(yq '.nodes[] | select(.hostname == "cp-2") | .ipAddress' "$CLUSTER/talman.yaml")
  [ -n "$address" ]
  for node in nope-1 "$address" cp-1,cp-2 cp; do
    echo "$node"

    recipe cluster-reboot "$node" --yes < /dev/null

    [ "$status" -ne 0 ]
    [[ $output == *"not a node of lab-sto2"* || $output == *"by its hostname"* ]]
    [[ $output == *"cp-1, cp-2, cp-3, worker-1, worker-2, worker-3"* ]]
    [[ $output != *"$address"* ]]
    [ ! -e "$RECORD/argv" ]
    [ ! -e "$STATE/rebooted" ]
  done
}

@test "The probe leaves nothing running behind, whether the reboot succeeds, fails or is interrupted" {
  for case in succeeds gap talman-fails never-back INT TERM declined; do
    echo "$case"
    reset_cluster
    reset_environment
    args=(cp-1 --yes)
    case $case in
      gap) echo 2 > "$STATE/reboot-gap" ;;
      talman-fails) : > "$STATE/reboot-fails" ;;
      never-back)
        : > "$STATE/never-back"
        with REBOOT_WAIT=1
        ;;
      INT | TERM) echo "$case" > "$STATE/interrupt" ;;
      declined) args=(cp-1) ;;
    esac

    recipe cluster-reboot "${args[@]}" <<< no

    if [[ $case == succeeds ]]; then
      [ "$status" -eq 0 ]
    else
      [ "$status" -ne 0 ]
    fi
    if [[ $case != declined ]]; then
      [ "$(probes)" -gt 0 ]
    fi
    nothing_left
  done
}

@test "The node is drained before it is rebooted and uncordoned once it is Ready" {
  recipe cluster-reboot cp-2 --yes < /dev/null

  [ "$status" -eq 0 ]
  cordoned=$(call_line '^kubectl cordon cp-2$')
  drained=$(call_line '^kubectl drain cp-2 ')
  rebooted=$(call_line '^talman reboot -n cp-2 ')
  finished=$(call_line '^talman reboot finished')
  ready=$(last_call_line '^kubectl get nodes ')
  uncordoned=$(call_line '^kubectl uncordon cp-2$')
  for call in "$cordoned" "$drained" "$rebooted" "$finished" "$ready" "$uncordoned"; do
    [ -n "$call" ]
  done
  [ "$cordoned" -lt "$drained" ]
  [ "$drained" -lt "$rebooted" ]
  # The probe runs through the drain too.
  evicted=$(call_line '^drain of cp-2 finished')
  [ "$evicted" -lt "$rebooted" ]
  during=$(awk -v from="$drained" -v to="$evicted" 'NR > from && NR < to && /^kubectl get --raw \/readyz /' "$RECORD/argv" | wc -l)
  [ "$during" -ge 1 ]
  [ "$finished" -lt "$ready" ]
  [ "$ready" -lt "$uncordoned" ]
  # Drained as cluster-upgrade drains, with talosctl's own drain off, and unschedulable going down.
  [ "$(calls '^kubectl drain ')" = 'kubectl drain cp-2 --ignore-daemonsets --delete-emptydir-data --timeout=10m' ]
  [[ " $(calls '^talman reboot -n ') " == *" --extra-flags=--drain=false "* ]]
  [ "$(cat "$RECORD/reboot-state")" = 'cp-2 cordoned' ]
  [ "$(cat "$RECORD/uncordoned")" = 'cp-2 back' ]
  [ ! -e "$STATE/cordoned.cp-2" ]
  [ "$(calls '^kubectl (cordon|drain|uncordon) ' | grep -Ecv ' cp-2( |$)')" -eq 0 ]
  [[ $output == *"cp-2 is schedulable again"* ]]
  [[ $output == *"cp-2 is Ready again, and /readyz answered every probe"* ]]

  recipe cluster-check

  [ "$status" -eq 0 ]
}

@test "A node that was cordoned before the reboot stays cordoned" {
  : > "$STATE/cordoned.cp-3"

  recipe cluster-reboot cp-3 --yes < /dev/null

  [ "$status" -eq 0 ]
  [ -n "$(calls '^kubectl drain cp-3 ')" ]
  [ "$(cat "$RECORD/reboot-state")" = 'cp-3 cordoned' ]
  [ -z "$(calls '^kubectl uncordon ')" ]
  [ -e "$STATE/cordoned.cp-3" ]
  [[ $output == *"cp-3 was cordoned before the reboot and stays cordoned"* ]]
  [[ $output != *"schedulable again"* ]]
}

@test "Pods the shutdown left Failed on the node are removed, and nothing else" {
  # Not the shutdown's: a Failed pod on the node for another reason, pods a shutdown of other nodes
  # left Failed, and a running pod on the node.
  others=('kube-system job-crashed Failed cp-1 Error' 'apps web-rejected-old Failed cp-2 NodeShutdown'
    'apps agent-terminated-old Failed worker-1 Terminated' 'apps web-running Running cp-1')
  printf '%s\n' "${others[@]}" > "$STATE/pods"

  recipe cluster-reboot cp-1 --yes < /dev/null

  [ "$status" -eq 0 ]
  [ "$(sort "$RECORD/deleted")" = 'apps/web-cp-1-1
kube-system/node-agent-cp-1' ]
  [ -n "$(calls '^kubectl delete pod --namespace apps (.* )?web-cp-1-1( |$)')" ]
  [ -n "$(calls '^kubectl delete pod --namespace kube-system (.* )?node-agent-cp-1( |$)')" ]
  [ "$(call_line '^kubectl delete ')" -gt "$(last_call_line '^kubectl get nodes ')" ]
  [ "$(cat "$STATE/pods")" = "$(printf '%s\n' "${others[@]}")" ]
  [[ $output == *"removed 2 pods the shutdown left Failed on cp-1"* ]]

  # cluster-check still fails on the Failed pod that is not the shutdown's.
  recipe cluster-check

  [ "$status" -ne 0 ]
  [[ $(line_of 'pods in kube-system') == "FAIL  pods in kube-system: "*kube-system/job-crashed* ]]
  [[ $(line_of 'pods in kube-system') != *node-agent* ]]

  # A shutdown that leaves nothing: nothing is deleted, and the recipe says so.
  reset_cluster
  : > "$STATE/clean-shutdown"

  recipe cluster-reboot cp-1 --yes < /dev/null

  [ "$status" -eq 0 ]
  [ -z "$(calls '^kubectl delete ')" ]
  [[ $output == *"the shutdown left no pod Failed on cp-1"* ]]
}

@test "A failed reboot leaves the node cordoned and says so" {
  for case in drain-fails reboot-fails never-back cordoned-before; do
    echo "$case"
    reset_cluster
    reset_environment
    case $case in
      never-back)
        : > "$STATE/never-back"
        with REBOOT_WAIT=0
        ;;
      cordoned-before) : > "$STATE/cordoned.worker-2" && : > "$STATE/reboot-fails" ;;
      *) : > "$STATE/$case" ;;
    esac

    recipe cluster-reboot worker-2 --yes < /dev/null

    [ "$status" -ne 0 ]
    [ -e "$STATE/cordoned.worker-2" ]
    [ -z "$(calls '^kubectl uncordon ')" ]
    [ -z "$(calls '^kubectl delete ')" ]
    last=$(script_lines | tail -1)
    if [[ $case == cordoned-before ]]; then
      [[ $last == *"worker-2 stays cordoned, as it was before"* ]]
    else
      [[ $last == *"worker-2 is left cordoned"*"kubectl uncordon worker-2"* ]]
    fi
    if [[ $case == drain-fails ]]; then
      [ -z "$(calls '^talman ')" ]
    fi
  done
}

@test "A cluster that still owns a load balancer or a volume is not destroyed, and they are named" {
  for owned in load-balancer csi-volume both; do
    echo "$owned"
    reset_cluster
    case $owned in
      both) : > "$STATE/load-balancer" && : > "$STATE/csi-volume" ;;
      *) : > "$STATE/$owned" ;;
    esac

    recipe cluster-destroy --yes < /dev/null

    [ "$status" -ne 0 ]
    if [[ $owned != csi-volume ]]; then
      [[ $output == *"Service apps/web"* ]]
    fi
    if [[ $owned != load-balancer ]]; then
      [[ $output == *"PersistentVolume pvc-0a1b2c3d"* ]]
    fi
    for other in default/kubernetes kube-system/hubble-relay local-volume-1 marker-volume-handle 198.51.100.62; do
      [[ $output != *"$other"* ]]
    done
    no_tofu
    generated_kept
  done
}

@test "A cluster whose API does not answer is not destroyed unless asked" {
  : > "$STATE/api-down"

  recipe cluster-destroy --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"--unreachable"* ]]
  calls '^kubectl get ' | grep -q .
  no_tofu
  generated_kept

  # Without a kubeconfig the cluster cannot be asked either.
  rm -f "$STATE/api-down" "$RECORD/argv"
  mv "$CLUSTER/clusterconfig/kubeconfig" "$BATS_TEST_TMPDIR/kubeconfig"

  recipe cluster-destroy --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"--unreachable"* ]]
  [ ! -e "$RECORD/argv" ]
  mv "$BATS_TEST_TMPDIR/kubeconfig" "$CLUSTER/clusterconfig/kubeconfig"

  # With --unreachable, an API that does not answer is not asked to answer.
  : > "$STATE/api-down"

  recipe cluster-destroy --unreachable --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"sto2/cluster destroyed"* ]]
  [ "$(calls '^tofu .* apply ' | wc -l)" -eq 1 ]

  # --unreachable does not let a cluster that answers be destroyed while it owns a load balancer.
  reset_cluster
  restore_generated
  : > "$STATE/load-balancer"

  recipe cluster-destroy --unreachable --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"Service apps/web"* ]]
  no_tofu
}

@test "Destroying the cluster leaves the plumbing stack, the secrets bundle and the buckets alone" {
  recipe cluster-destroy --yes < /dev/null

  [ "$status" -eq 0 ]
  # The cluster is asked first, then only the cluster stack is planned for destruction and destroyed.
  asked=$(last_call_line '^kubectl get ')
  [ -n "$asked" ]
  [ "$asked" -lt "$(call_line '^tofu ')" ]
  [ "$(calls '^tofu ' | grep -cv "^tofu -chdir=$STACK ")" -eq 0 ]
  [ "$(calls '^tofu .* plan ' | wc -l)" -eq 1 ]
  [[ $(calls '^tofu .* plan ') == *" -destroy "* ]]
  [ "$(calls '^tofu .* apply ' | wc -l)" -eq 1 ]
  [ -z "$(calls "$PLUMBING")" ]
  [[ $output == *"Plan: 0 to add, 0 to change, 3 to destroy."* ]]
  [[ $output == *"sto2/cluster destroyed"* ]]
  [[ $output != *"sto2/plumbing"* ]]
  # The generated files go, the secrets bundle stays as it was, and no bucket is touched.
  for file in "${GENERATED[@]}"; do
    [ ! -e "$CLUSTER/$file" ]
  done
  cmp "$CLUSTER/secrets.sops.yaml" "$BATS_TEST_TMPDIR/cluster.before/secrets.sops.yaml"
  [ -z "$(calls '^(rclone|openstack|helm|talosctl|talman) ')" ]
}

@test "Nothing is destroyed without the stack's name" {
  for answer in '' no lab-sto2 sto2/plumbing; do
    echo "answer: $answer"
    rm -f "$RECORD/argv"

    recipe cluster-destroy <<< "$answer"

    [ "$status" -ne 0 ]
    [[ $output == *"Type sto2/cluster to destroy it"* ]]
    [ -z "$(calls '^tofu .* apply ')" ]
    generated_kept
  done

  recipe cluster-destroy < /dev/null

  [ "$status" -ne 0 ]
  [ -z "$(calls '^tofu .* apply ')" ]

  rm -f "$RECORD/argv"
  recipe cluster-destroy lab-sto2 <<< sto2/cluster

  [ "$status" -eq 0 ]
  [ "$(calls '^tofu .* apply ' | wc -l)" -eq 1 ]
}

@test "No address reaches the output of any of the three recipes" {
  printed=() ci_printed=()
  # keep: keeps the last run's output, with CI set apart.
  keep() {
    if [[ " ${ENVIRONMENT[*]} " == *" CI=true "* ]]; then
      ci_printed+=("$output")
    else
      printed+=("$output")
    fi
  }
  for ci in no yes; do
    reset_environment
    with REBOOT_WAIT=0
    if [[ $ci == yes ]]; then
      with CI=true
    fi
    for condition in healthy not-ready kube-proxy pending-csr logs-fail no-flux api-down; do
      reset_cluster
      [[ $condition == healthy ]] || : > "$STATE/$condition"
      recipe cluster-check
      keep
    done
    for condition in rides-out reboot-gap reboot-fails never-back api-down; do
      reset_cluster
      case $condition in
        rides-out) ;;
        reboot-gap) echo 2 > "$STATE/reboot-gap" ;;
        *) : > "$STATE/$condition" ;;
      esac
      recipe cluster-reboot worker-1 --yes < /dev/null
      keep
    done
    recipe cluster-reboot 192.0.2.221 --yes < /dev/null
    keep
    for condition in load-balancer api-down owns-nothing unreachable; do
      reset_cluster
      args=(--yes)
      case $condition in
        owns-nothing) ;;
        unreachable)
          : > "$STATE/api-down"
          args+=(--unreachable)
          ;;
        *) : > "$STATE/$condition" ;;
      esac
      recipe cluster-destroy "${args[@]}" < /dev/null
      keep
      restore_generated
    done
  done

  # Each address the fakes hold: the nodes' and the pods' in kubectl's answers, the log line's, the
  # API server's and the node's in kubectl's errors, the Services', tofu's, the plan's, the stack's
  # output's, the API address and the allowlist from the environment, and talman.yaml's.
  mapfile -t talman_addresses < <(yq '.. | select(tag == "!!str") | select(test("^[0-9]+([.][0-9]+){3}$"))' "$BATS_FILE_TMPDIR/talman.yaml")
  [ "${#talman_addresses[@]}" -ge 6 ]
  addresses=(198.51.100.31 198.51.100.41 198.51.100.51 198.51.100.52 198.51.100.61 198.51.100.62
    198.51.100.63 198.51.100.64 198.51.100.66 198.51.100.71 198.51.100.81 198.51.100.82 198.51.100.83
    198.51.100.84 "$KUBE_API_ADDRESS" 203.0.113.77)
  [[ ${printed[*]} == *"FAIL  "* && ${printed[*]} == *"pass  "* ]]
  [[ ${printed[*]} == *"/readyz asked"* && ${printed[*]} == *"Service apps/web"* ]]
  [[ ${ci_printed[*]} == *"its output is in talos/lab-sto2/clusterconfig/cluster-reboot.log"* ]]
  grep -qF "$(yq '.nodes[0].ipAddress' "$BATS_FILE_TMPDIR/talman.yaml")" "$CLUSTER/clusterconfig/cluster-reboot.log"
  for address in "${addresses[@]}"; do
    [[ ${printed[*]} != *"$address"* ]]
    [[ ${ci_printed[*]} != *"$address"* ]]
  done
  # talman's own output names the nodes by address, and is printed only without CI.
  for address in "${talman_addresses[@]}"; do
    [[ ${ci_printed[*]} != *"$address"* ]]
  done
  for marker in marker-volume-handle marker-subnet-id marker-client-key-data marker-bundle-secret; do
    [[ ${printed[*]} != *"$marker"* && ${ci_printed[*]} != *"$marker"* ]]
  done
}

@test "the lifecycle recipes check what they need before they run anything" {
  rm "$CLUSTER/clusterconfig/kubeconfig"

  recipe cluster-check

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/clusterconfig/kubeconfig does not exist"* ]]

  recipe cluster-reboot cp-1 --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/clusterconfig/kubeconfig does not exist"* ]]
  [ ! -e "$RECORD/argv" ]

  reset_cluster
  rm "$CLUSTER/talman.yaml" "$CLUSTER/secrets.sops.yaml"
  without SOPS_AGE_KEY_FILE
  with REBOOT_WAIT=soon

  recipe cluster-reboot cp-1 --yes --tolerate a-while < /dev/null

  [ "$status" -ne 0 ]
  for message in "talos/lab-sto2/talman.yaml does not exist" "talos/lab-sto2/secrets.sops.yaml does not exist" \
    "neither SOPS_AGE_KEY_FILE nor SOPS_AGE_KEY is set" "REBOOT_WAIT is not a whole number of seconds" \
    "--tolerate takes a whole number of seconds"; do
    [[ $output == *"$message"* ]]
  done

  recipe cluster-check

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/talman.yaml does not exist"* ]]
  [ ! -e "$RECORD/argv" ]

  # cluster-destroy checks the cluster stack's environment before it asks the cluster.
  reset_environment
  without TF_STATE_BUCKET

  recipe cluster-destroy --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"TF_STATE_BUCKET is not set"* ]]
  [ ! -e "$RECORD/argv" ]

  # Go's HTTP/2 debug log is refused by each.
  reset_environment
  with GODEBUG=http2debug=2
  cp "$BATS_FILE_TMPDIR/talman.yaml" "$CLUSTER/talman.yaml"
  for run in cluster-check 'cluster-reboot cp-1 --yes' 'cluster-destroy --yes'; do
    # shellcheck disable=SC2086 # each run is a recipe and its arguments
    recipe $run < /dev/null

    [ "$status" -ne 0 ]
    [[ $output == *"GODEBUG sets http2debug"* ]]
    [ ! -e "$RECORD/argv" ]
  done
}

@test "the lifecycle recipes refuse an argument they do not know" {
  for run in 'cluster-check --yes' 'cluster-reboot cp-1 --force' 'cluster-reboot cp-1 lab-sto2 extra' \
    'cluster-reboot cp-1 --tolerate' 'cluster-destroy --force' 'cluster-destroy lab-sto2 extra'; do
    echo "$run"
    # shellcheck disable=SC2086 # each run is a recipe and its arguments
    recipe $run < /dev/null

    [ "$status" -ne 0 ]
    [[ $output == *"usage: "* ]]
    [ ! -e "$RECORD/argv" ]
  done
}
