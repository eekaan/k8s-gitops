#!/usr/bin/env bats
# Proves features/cluster-lifecycle.feature; each test carries its scenario's title.
# cluster-check, cluster-reboot and cluster-destroy run from a copy of the repository with an
# environment of their own, so no run reads this checkout's .env, keys or kubeconfig. Whatever would
# reach a node, the cluster or the cloud is a recording fake: kubectl and talman are
# tests/fixtures/cluster-lifecycle/kubectl and talman, which answer from files in STATE; tofu plans
# and destroys from tests/fixtures/cluster-lifecycle/destroy-plan.json, with state.json as the
# stack's state; openstack, helm, rclone and talosctl fail when called. sleep is the real one under
# the fakes' directory as its name, so that a probe left running is found by its command line, as
# are the fakes and the copy's scripts.

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
  show)
    # Without a saved plan, the stack's state: the cluster stack holds resources.
    if [[ \$# -eq 3 ]]; then cat "$FIXTURES/state.json"; else cat "$FIXTURES/destroy-plan.json"; fi
    ;;
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
    # The settle time is real seconds here, as these tests run on the real clock;
    # tests/cluster-recipes.bats proves it on a fake one.
    FORWARD_SETTLE=0
  )
  reset_environment
  CHECKS=('/readyz' 'nodes Ready' 'node count' 'workers in BGP' 'no kube-proxy' 'pods in kube-system' 'pods in flux-system'
    'certificate requests' 'pod logs' 'scrape targets')
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
# fake, the real sleep under its fake's name or a copy's script, or whose working directory is in it,
# such as the recipe's own script, which is run from the copy of the repository there, as its PID
# and command line.
leftovers() {
  local file pid cwd
  local -a argv
  for file in /proc/[0-9]*/cmdline; do
    pid=${file#/proc/}
    pid=${pid%/cmdline}
    [[ $pid != "$$" && $pid != "$BASHPID" ]] || continue
    mapfile -d '' -t argv 2> /dev/null < "$file" || continue
    cwd=$(readlink "/proc/$pid/cwd" 2> /dev/null) || cwd=
    if [[ " ${argv[*]} " == *"$BATS_TEST_TMPDIR/"* || $cwd == "$BATS_TEST_TMPDIR"/* ]]; then
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

# no_tofu: every tofu call was an init, or a read of the stack's outputs or state, which name the
# cluster the stack holds and whether it holds anything; nothing was planned, applied, destroyed,
# imported or removed from state.
no_tofu() {
  local changed
  changed=$(awk '$1 == "tofu" && $3 != "init" && $3 != "output" && $3 != "show"' "$RECORD/argv" 2> /dev/null)
  if [[ -n $changed ]]; then
    echo "tofu changed or planned: $changed" >&2
    return 1
  fi
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

@test "cluster-check fails, naming job and node, while a component's scrape target is down" {
  printf '%s\n' 'kube-etcd cp-1' 'kube-etcd cp-2' 'node-exporter worker-3' > "$STATE/targets-down"

  recipe cluster-check

  [ "$status" -ne 0 ]
  [[ $(line_of 'scrape targets') == "FAIL  scrape targets: "* ]]
  line=$(line_of 'scrape targets')
  [[ $line == *"kube-etcd on cp-1, cp-2"* && $line == *"node-exporter on worker-3"* ]]
  [[ $line != *kube-scheduler* && $line != *kubelet* ]]
  [[ $output != *198.51.100.* ]]
  for other in "${CHECKS[@]}"; do
    if [[ $other != 'scrape targets' ]]; then
      [[ $(line_of "$other") == "pass  $other: "* ]]
    fi
  done
  [[ $output == *"cluster-check: 1 of ${#CHECKS[@]} checks failed"* ]]
  # Prometheus is asked through the API server's service proxy, by kubectl get.
  [ -n "$(calls '^kubectl get --raw /api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/targets')" ]

  # A component without a node, and each of the components the check names, by its node whichever
  # label gives it: the kubelet's only in its label node, node-exporter's (above) only as its pod's
  # node, etcd's (above) only as its endpoint's.
  for job in apiserver kube-controller-manager kube-scheduler kubelet; do
    node=cp-1
    [[ $job == apiserver ]] && node=''
    echo "$job${node:+ $node}" > "$STATE/targets-down"
    recipe cluster-check
    [ "$status" -ne 0 ]
    if [[ -n $node ]]; then
      [[ $(line_of 'scrape targets') == "FAIL  scrape targets: down: $job on $node" ]]
    else
      [[ $(line_of 'scrape targets') == "FAIL  scrape targets: down: $job" ]]
    fi
  done

  # A target of anything else that is down is not this check's concern; all up passes.
  : > "$STATE/targets-down"
  : > "$STATE/other-down"
  recipe cluster-check
  [ "$status" -eq 0 ]
  [[ $(line_of 'scrape targets') == "pass  scrape targets: "* ]]
  rm "$STATE/other-down"
  recipe cluster-check
  [ "$status" -eq 0 ]
  [[ $(line_of 'scrape targets') == "pass  scrape targets: "* ]]
  # The pass says how many targets of the jobs it saw: 1 + 3 * 3 + 2 * 6.
  [[ $(line_of 'scrape targets') == *"22 targets"* ]]

  # An answer too large for a pipe to hold, read to the end, is still read right.
  echo 3000 > "$STATE/many-targets"
  recipe cluster-check
  [ "$status" -eq 0 ]
  [[ $(line_of 'scrape targets') == "pass  scrape targets: "*"22 targets"* ]]
  echo 'kube-etcd cp-1' > "$STATE/targets-down"
  recipe cluster-check
  [ "$status" -ne 0 ]
  [[ $(line_of 'scrape targets') == "FAIL  scrape targets: "*"kube-etcd on cp-1"* ]]
}

@test "cluster-check skips the scrape check, saying why, without the monitoring stack or without an answer from Prometheus" {
  for condition in no-monitoring prometheus-silent prometheus-error targets-none etcd-unscraped; do
    reset_cluster
    if [[ $condition == etcd-unscraped ]]; then
      echo kube-etcd > "$STATE/unscraped"
    else
      : > "$STATE/$condition"
    fi
    # What a skip must not hide: a target down is not seen, but nothing is passed either.
    echo 'kube-etcd cp-1' > "$STATE/targets-down"

    recipe cluster-check

    [ "$status" -eq 0 ]
    line=$(line_of 'scrape targets')
    [[ $line == "skip  scrape targets: "* ]]
    case $condition in
      no-monitoring) [[ $line == *"monitoring stack is not installed"* ]] ;;
      # An answer without a target of a job names the job: nothing scrapes it, which is no pass.
      targets-none) [[ $line == *"no active target"* && $line == *apiserver* && $line == *kube-etcd* && $line == *node-exporter* ]] ;;
      etcd-unscraped) [[ $line == *"no active target"* && $line == *kube-etcd* && $line != *kubelet* ]] ;;
      *) [[ $line == *"Prometheus did not answer"* ]] ;;
    esac
    [[ ${output##*$'\n'} == *"skipped: scrape targets"* ]]
    [[ $output != *198.51.100.* ]]
  done
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

@test "A control plane that is Ready again without its etcd member fails the reboot" {
  : > "$STATE/etcd-down.cp-2"
  with REBOOT_WAIT=4

  recipe cluster-reboot cp-2 --yes < /dev/null

  [ "$status" -ne 0 ]
  [ -e "$STATE/back.cp-2" ]
  [[ $output == *"cp-2 is Ready again, but etcd was not whole within 4s: not every control plane's etcd member answered etcd status"* ]]
  [[ $output != *"has not reported Ready"* ]]
  [[ $output == *"cp-2 is left cordoned"* ]]
  [ -z "$(calls '^kubectl uncordon ')" ]
  # Every control plane's member was asked, through the Talos API, after the reboot, until the wait
  # ran out.
  finished=$(call_line '^talman reboot finished')
  asked=$(awk -v from="$finished" 'NR > from && /^talman talosctl -n cp-1 -n cp-2 -n cp-3 etcd status$/' "$RECORD/argv" | wc -l)
  [ "$asked" -ge 2 ]
  [[ $output != *198.51.100.9* ]]
  reported > /dev/null

  # A member that comes back a few seconds after the node is Ready is waited for.
  reset_cluster
  echo 1 > "$STATE/etcd-late.cp-2"

  recipe cluster-reboot cp-2 --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"cp-2 is Ready again"* ]]
  [ -n "$(calls '^kubectl uncordon cp-2$')" ]
  [ "$(calls '^talman talosctl .* etcd status$' | wc -l)" -ge 2 ]
  [ -n "$(calls '^talman talosctl -n cp-2 etcd members$')" ]

  # A member etcd holds besides the control planes of talman.yaml, as of a control plane removed
  # without its member, counts toward etcd's quorum: the wait fails on it, naming it.
  reset_cluster
  echo 'cp-old after' > "$STATE/etcd-extra"

  recipe cluster-reboot cp-2 --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"cp-2 is Ready again, but etcd was not whole within 4s: etcd holds cp-old, no control plane of talman.yaml"* ]]
  [[ $output != *198.51.100.9* ]]

  # A worker runs no etcd member.
  reset_cluster

  recipe cluster-reboot worker-2 --yes < /dev/null

  [ "$status" -eq 0 ]
  [ -z "$(calls '^talman talosctl ')" ]
}

@test "A control plane is not rebooted while etcd lacks a healthy member or holds one that is no control plane" {
  # cp-1's member is down before anything is rebooted: rebooting cp-2 as well would leave one
  # healthy member of three.
  : > "$STATE/etcd-away.cp-1"

  recipe cluster-reboot cp-2 --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"etcd is not whole, so cp-2 is not rebooted and nothing was changed: not every control plane's etcd member answered etcd status"* ]]
  [ -n "$(calls '^talman talosctl -n cp-1 -n cp-2 -n cp-3 etcd status$')" ]
  [ -z "$(calls '^kubectl (cordon|drain|uncordon) ')" ]
  [ -z "$(calls '^talman reboot ')" ]
  [ ! -e "$STATE/rebooted" ]
  [[ $output != *198.51.100.9* ]]

  # A member that is no control plane of talman.yaml, named by its hostname.
  reset_cluster
  echo cp-old > "$STATE/etcd-extra"

  recipe cluster-reboot cp-3 <<< cp-3

  [ "$status" -ne 0 ]
  [[ $output == *"etcd is not whole, so cp-3 is not rebooted and nothing was changed: etcd holds cp-old, no control plane of talman.yaml"* ]]
  [[ $output != *"Type cp-3"* ]]
  [ -z "$(calls '^kubectl (cordon|drain|uncordon) ')" ]
  [ -z "$(calls '^talman reboot ')" ]
  [[ $output != *198.51.100.9* ]]

  # A worker is rebooted whatever etcd's state, which it is not part of.
  reset_cluster
  echo cp-old > "$STATE/etcd-extra"

  recipe cluster-reboot worker-2 --yes < /dev/null

  [ "$status" -eq 0 ]
  [ -z "$(calls '^talman talosctl ')" ]
}

@test "cluster-reboot reboots nothing when it cannot read which nodes are control planes" {
  # talman.yaml gives a node a role that is neither controlplane nor worker.
  yq -i '(.nodes[] | select(.hostname == "cp-2") | .role) = "control-plane"' "$CLUSTER/talman.yaml"

  recipe cluster-reboot cp-1 --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/talman.yaml gives cp-2 the role control-plane, neither controlplane nor worker"* ]]
  [[ $output == *"nothing was changed"* ]]
  [ -z "$(calls '^(kubectl (cordon|drain)|talman reboot) ')" ]

  # yq fails to read the roles.
  reset_cluster
  restore_generated
  real_yq=$(command -v yq)
  fake yq <<EOF
if [[ \$* == *.role* ]]; then
  echo "Error: bad file" >&2
  exit 1
fi
exec "$real_yq" "\$@"
EOF

  recipe cluster-reboot cp-1 --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"cannot read the roles of the nodes in talos/lab-sto2/talman.yaml"* ]]
  [ -z "$(calls '^(kubectl (cordon|drain)|talman reboot) ')" ]
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
    # worker-2 is out of BGP too, which the last line says; the one before it is about the cordon.
    last=$(script_lines | tail -2 | head -1)
    [[ $(script_lines | tail -1) == *"worker-2 is out of BGP"* ]]
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

@test "A failed drain says why without the API's address" {
  : > "$STATE/drain-unreachable"
  for ci in '' true; do
    echo "ci=$ci"
    reset_cluster
    : > "$STATE/drain-unreachable"
    reset_environment
    [[ -z $ci ]] || with CI=true

    recipe cluster-reboot worker-2 --yes < /dev/null

    [ "$status" -ne 0 ]
    # The reason is shown, and where the API is is not.
    [[ $output == *"connection refused"* ]]
    for address in 198.51.100.66 "$KUBE_API_ADDRESS" 6443; do
      [[ $output != *"$address"* ]]
    done
    # Nothing was rebooted, and the node is left cordoned and said to be.
    [ -z "$(calls '^talman ')" ]
    [[ $(script_lines | tail -2 | head -1) == *"worker-2 is left cordoned"* ]]
    [[ $(script_lines | tail -1) == *"worker-2 is out of BGP"* ]]
  done
}

# OUT_LABEL: the label that takes a node out of BGP, as the recipes set it.
OUT_LABEL="node-restriction.kubernetes.io/bgp-out"

@test "A planned reboot takes the worker out of BGP, waits until it announces nothing, and puts it back once it is Ready" {
  # The operator and the agent take two reads of the node's BGP configuration to follow the label,
  # out and in.
  echo 2 > "$STATE/bgp-slow"

  recipe cluster-reboot worker-2 --yes < /dev/null

  [ "$status" -eq 0 ]
  labelled=$(call_line "^kubectl label node worker-2 $OUT_LABEL=true( |\$)")
  cordoned=$(call_line '^kubectl cordon worker-2$')
  rebooted=$(call_line '^talman reboot -n worker-2 ')
  uncordoned=$(call_line '^kubectl uncordon worker-2$')
  restored=$(call_line "^kubectl label node worker-2 $OUT_LABEL-\$")
  for call in "$labelled" "$cordoned" "$rebooted" "$uncordoned" "$restored"; do
    [ -n "$call" ]
  done
  [ "$labelled" -lt "$cordoned" ]
  [ "$uncordoned" -lt "$restored" ]
  # It asked the node's BGP configuration until it was gone, before it cordoned the node, and until
  # the peers were established again after it put the node back.
  reads() {
    awk -v from="$1" -v to="$2" 'NR > from && NR < to && /^kubectl get ciliumbgpnodeconfig worker-2 /' "$RECORD/argv" | wc -l
  }
  [ "$(reads "$labelled" "$cordoned")" -ge 3 ]
  [ "$(reads "$restored" 1000000)" -ge 3 ]
  # The node announced nothing when it was drained and when it went down, and nothing else was
  # taken out of BGP.
  [ "$(cat "$RECORD/drained-bgp")" = 'worker-2 withdrawn' ]
  [ "$(cat "$RECORD/reboot-bgp")" = 'worker-2 out' ]
  [ "$(calls '^kubectl label ' | grep -Ecv ' worker-2 ')" -eq 0 ]
  [ "$(calls '^kubectl label ' | wc -l)" -eq 2 ]
  [ ! -e "$STATE/bgp-out.worker-2" ]
  [[ $output == *"the BGP configuration of worker-2 is gone"* ]]
  [[ $output == *"worker-2 announces again"* ]]

  recipe cluster-check

  [ "$status" -eq 0 ]

  # A worker is back once the sessions that were established before are: one that is established at
  # once does not end the wait while the other is not.
  reset_cluster
  echo 2 > "$STATE/bgp-slow"
  : > "$STATE/bgp-peer-late"

  recipe cluster-reboot worker-2 --yes < /dev/null

  [ "$status" -eq 0 ]
  restored=$(call_line "^kubectl label node worker-2 $OUT_LABEL-\$")
  [ "$(awk -v from="$restored" 'NR > from && /^kubectl get ciliumbgpnodeconfig worker-2 /' "$RECORD/argv" | wc -l)" -ge 3 ]

  # With no session established before the node was taken out, as while the edge stack is not built
  # or an edge is stopped, none is waited for after: the reboot succeeds all the same, the node is
  # uncordoned and back in BGP, and the pods the shutdown left are removed.
  reset_cluster
  : > "$STATE/bgp-peers-down"
  with BGP_WAIT=0

  recipe cluster-reboot worker-2 --yes < /dev/null

  [ "$status" -eq 0 ]
  [ ! -e "$STATE/bgp-out.worker-2" ]
  [ -n "$(calls '^kubectl uncordon worker-2$')" ]
  [ -n "$(calls '^kubectl delete ')" ]
  [[ $output == *"worker-2 had no established BGP session before it was taken out, so it does not wait for one"* ]]
  [[ $output != *"does not announce again"* ]]
  [[ $output != *"is out of BGP"* ]]

  # A worker cordoned before the run stays cordoned, and is put back in BGP once it is Ready all the
  # same.
  reset_cluster
  reset_environment
  : > "$STATE/cordoned.worker-2"

  recipe cluster-reboot worker-2 --yes < /dev/null

  [ "$status" -eq 0 ]
  [ -z "$(calls '^kubectl uncordon ')" ]
  [ -e "$STATE/cordoned.worker-2" ]
  [ -n "$(calls "^kubectl label node worker-2 $OUT_LABEL-\$")" ]
  [ ! -e "$STATE/bgp-out.worker-2" ]
  [[ $output == *"worker-2 was cordoned before the reboot and stays cordoned"* ]]
  [[ $output == *"worker-2 announces again"* ]]

  # BGP_WAIT is read in base 10: with 08, a configuration that takes three reads, six seconds, to go
  # is waited for, and the node is cordoned and drained only once it is gone.
  reset_cluster
  reset_environment
  echo 3 > "$STATE/bgp-slow"
  with BGP_WAIT=08

  recipe cluster-reboot worker-2 --yes < /dev/null

  [ "$status" -eq 0 ]
  labelled=$(call_line "^kubectl label node worker-2 $OUT_LABEL=true( |\$)")
  cordoned=$(call_line '^kubectl cordon worker-2$')
  [ -n "$labelled" ] && [ -n "$cordoned" ]
  [ "$(awk -v from="$labelled" -v to="$cordoned" 'NR > from && NR < to && /^kubectl get ciliumbgpnodeconfig worker-2 /' "$RECORD/argv" | wc -l)" -ge 4 ]
  [ "$(cat "$RECORD/drained-bgp")" = 'worker-2 withdrawn' ]
  [[ $output == *"the BGP configuration of worker-2 is gone"* ]]
}

@test "A rebooted worker is put back into BGP only after its Cilium agent reports that it forwards" {
  # The agent's pod still reports the Ready it posted before the node went down, then is not Ready
  # twice, and then is Ready since the reboot.
  echo 'stale not not ready' > "$STATE/agent-sequence.worker-2"

  recipe cluster-reboot worker-2 --yes < /dev/null

  [ "$status" -eq 0 ]
  rebooted=$(call_line '^talman reboot -n worker-2 ')
  uncordoned=$(call_line '^kubectl uncordon worker-2$')
  first=$(call_line '^agent worker-2 ')
  last=$(last_call_line '^agent worker-2 ')
  restored=$(call_line "^kubectl label node worker-2 $OUT_LABEL-\$")
  for call in "$rebooted" "$uncordoned" "$first" "$last" "$restored"; do
    [ -n "$call" ]
  done
  # Ready and uncordoned, then the agent is read until it answers Ready since the reboot, and only
  # then is the label removed.
  [ "$rebooted" -lt "$uncordoned" ]
  [ "$uncordoned" -lt "$first" ]
  [ "$last" -lt "$restored" ]
  [ "$(calls '^agent worker-2 ' | paste -sd' ')" = 'agent worker-2 stale agent worker-2 not agent worker-2 not agent worker-2 ready' ]
  [ "$(cat "$RECORD/label-removed")" = 'worker-2 ready' ]
  [ "$(calls '^kubectl get pods --namespace kube-system --selector k8s-app=cilium --field-selector spec.nodeName=worker-2 ' | wc -l)" -eq 4 ]
  # The BGP configuration is awaited after the label, as before.
  [ "$(awk -v from="$restored" 'NR > from && /^kubectl get ciliumbgpnodeconfig worker-2 /' "$RECORD/argv" | wc -l)" -ge 1 ]
  [[ $output == *"the Cilium agent on worker-2 has been Ready since the reboot for 0s, so worker-2 is put back in BGP"* ]]
  [[ $output == *"worker-2 announces again"* ]]

  # A control plane has no BGP, so no agent is waited for.
  reset_cluster
  reset_environment

  recipe cluster-reboot cp-2 --yes < /dev/null

  [ "$status" -eq 0 ]
  [ -z "$(calls '^agent ')" ]
  [ -z "$(calls 'k8s-app=cilium')" ]
}

@test "A worker whose agent never reports that it forwards stays out of BGP, and the run says so last" {
  for case in not-ready stale missing no-bgp-wait unreadable; do
    echo "$case"
    reset_cluster
    reset_environment
    with FORWARD_WAIT=4
    args=(worker-2 --yes)
    case $case in
      not-ready) echo not > "$STATE/agent-sequence.worker-2" ;;
      # The pod keeps the Ready it posted before the node went down.
      stale) echo stale > "$STATE/agent-sequence.worker-2" ;;
      missing) : > "$STATE/agent-missing" ;;
      # --no-bgp-wait skips the wait for the withdrawal, not the wait for the agent.
      no-bgp-wait)
        echo not > "$STATE/agent-sequence.worker-2"
        : > "$STATE/bgp-stays"
        args+=(--no-bgp-wait)
        ;;
      # An agent that cannot be read is not taken for one that forwards.
      unreadable) : > "$STATE/agent-unreadable" ;;
    esac

    recipe cluster-reboot "${args[@]}" < /dev/null

    [ "$status" -ne 0 ]
    # The node was rebooted, is Ready and uncordoned, and stays out.
    [ -n "$(calls '^talman reboot -n worker-2 ')" ]
    [ -n "$(calls '^kubectl uncordon worker-2$')" ]
    [ -e "$STATE/bgp-out.worker-2" ]
    [ -z "$(calls "^kubectl label node worker-2 $OUT_LABEL-\$")" ]
    [ ! -e "$RECORD/label-removed" ]
    if [[ $case == unreadable ]]; then
      [[ $output == *"kubectl could not read the Cilium agent of worker-2 through the kubeconfig, so it is not known whether worker-2 forwards"* ]]
    else
      # What the run waited for, and for how long.
      [[ $output == *"the Cilium agent on worker-2 has not been Ready since the reboot for 0s within 4s"* ]]
      [[ $output == *"FORWARD_WAIT"* ]]
    fi
    if [[ $case == not-ready || $case == stale || $case == no-bgp-wait ]]; then
      [ "$(calls '^agent worker-2 ' | wc -l)" -ge 2 ]
    fi
    last=$(script_lines | tail -1)
    [[ $last == *"worker-2 is out of BGP"*"kubectl label node worker-2 $OUT_LABEL-"* ]]
  done
}

@test "A recipe killed outright does not leave the cluster locked" {
  # SIGKILL, which no trap sees, while talman reboots the node and the probe of /readyz runs.
  echo KILL > "$STATE/interrupt"

  recipe cluster-reboot cp-2 --yes < /dev/null

  [ "$status" -ne 0 ]
  # The probe, which the recipe that was killed started in the background, runs on; the lock is not
  # held by it.
  [ -n "$(leftovers)" ]
  flock -n "$CLUSTER/clusterconfig/cluster.lock" true

  rm -f "$STATE/interrupt"
  recipe cluster-reboot no-such-node --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"no-such-node is not a node of lab-sto2"* ]]
  [[ $output != *"is busy"* ]]
}

@test "A recipe that stops while a worker is out says so last, with the command that puts it back" {
  for case in drain-fails reboot-fails never-back withdrawal-never already-out terminated; do
    echo "$case"
    reset_cluster
    reset_environment
    case $case in
      # SIGTERM while talman reboots the worker ends the run as Ctrl-C does.
      terminated) echo TERM > "$STATE/interrupt" ;;
      never-back)
        : > "$STATE/never-back"
        with REBOOT_WAIT=0
        ;;
      withdrawal-never)
        : > "$STATE/bgp-stays"
        with BGP_WAIT=0
        ;;
      already-out)
        # A rerun after a recipe that stopped: the label is there, and the node stays out until the
        # run that finds it puts it back.
        : > "$STATE/bgp-out.worker-2"
        : > "$STATE/drain-fails"
        ;;
      *) : > "$STATE/$case" ;;
    esac

    recipe cluster-reboot worker-2 --yes < /dev/null

    [ "$status" -ne 0 ]
    [ -e "$STATE/bgp-out.worker-2" ]
    last=$(script_lines | tail -1)
    [[ $last == *"worker-2 is out of BGP"*"kubectl label node worker-2 $OUT_LABEL-"* ]]
    if [[ $case == withdrawal-never ]]; then
      # What was seen, not what it would mean: a node whose agent is not running announces nothing.
      [[ $output == *"the CiliumBGPNodeConfig of worker-2 is still there after 0s, as when its Cilium agent is not running to take up the label"* ]]
      [[ $output != *"announces"* ]]
      [ -z "$(calls '^kubectl (cordon|drain) ')" ]
      [ -z "$(calls '^talman ')" ]
    fi
    if [[ $case == already-out ]]; then
      [[ $output == *"worker-2 is out of BGP already"* ]]
      [ -z "$(calls "^kubectl label node worker-2 $OUT_LABEL=")" ]
    fi
    if [[ $case == terminated ]]; then
      [[ $(script_lines | grep -n 'failed while rebooting worker-2 with talman$' | cut -d: -f1) -eq $(($(script_lines | wc -l) - 2)) ]]
      [[ $(script_lines | tail -2 | head -1) == *"worker-2 is left cordoned"* ]]
    fi
  done

  # A BGP configuration that cannot be read says so, and is not taken for one that is gone: before
  # the label nothing is changed; after it the node is left out, said last, and not drained.
  for case in unreadable unreadable-out; do
    echo "$case"
    reset_cluster
    reset_environment
    : > "$STATE/bgp-$case"
    with BGP_WAIT=0

    recipe cluster-reboot worker-2 --yes < /dev/null

    [ "$status" -ne 0 ]
    [[ $output == *"could not read the BGP configuration of worker-2"* ]]
    [[ $output != *"still announces"* ]]
    [ -z "$(calls '^kubectl (cordon|drain|uncordon) ')" ]
    [ -z "$(calls '^talman ')" ]
    if [[ $case == unreadable ]]; then
      [ -z "$(calls '^kubectl label ')" ]
      [ ! -e "$STATE/bgp-out.worker-2" ]
      [[ $(script_lines | tail -1) != *"is out of BGP"* ]]
    else
      [ -e "$STATE/bgp-out.worker-2" ]
      [[ $(script_lines | tail -1) == *"worker-2 is out of BGP"*"kubectl label node worker-2 $OUT_LABEL-"* ]]
    fi
  done

  # A second worker is not taken out while one is out: nothing is labelled, cordoned, drained or
  # rebooted, and the run says last which worker is out and how to put it back.
  reset_cluster
  reset_environment
  : > "$STATE/bgp-out.worker-1"

  recipe cluster-reboot worker-2 --yes < /dev/null

  [ "$status" -ne 0 ]
  [ -z "$(calls '^kubectl (label|cordon|drain) ')" ]
  [ -z "$(calls '^talman ')" ]
  [ -e "$STATE/bgp-out.worker-1" ]
  [[ $(script_lines | tail -1) == *"worker-1 is out of BGP"*"kubectl label node worker-1 $OUT_LABEL-"* ]]

  # A rerun that succeeds puts back a node a stopped run left out, and waits until its BGP
  # configuration, which takes two reads to come back, is there again; which of its sessions were
  # established before is not known, so none is waited for.
  reset_cluster
  reset_environment
  : > "$STATE/bgp-out.worker-2"
  echo 2 > "$STATE/bgp-slow"
  : > "$STATE/bgp-back-late"

  recipe cluster-reboot worker-2 --yes < /dev/null

  [ "$status" -eq 0 ]
  [ ! -e "$STATE/bgp-out.worker-2" ]
  [[ $output == *"worker-2 is out of BGP already"* ]]
  restored=$(call_line "^kubectl label node worker-2 $OUT_LABEL-\$")
  [ -n "$restored" ]
  [ "$(awk -v from="$restored" 'NR > from && /^kubectl get ciliumbgpnodeconfig worker-2 /' "$RECORD/argv" | wc -l)" -ge 3 ]
  [[ $output == *"the BGP configuration of worker-2 is back; which of its sessions were established before it was taken out is not known, so none is waited for"* ]]

  # A node whose peers do not come back after the label is removed is not out of BGP: the label is
  # gone, and the run says it did not announce again, not that the node is out.
  reset_cluster
  reset_environment
  : > "$STATE/bgp-not-back"
  with BGP_WAIT=0

  recipe cluster-reboot worker-2 --yes < /dev/null

  [ "$status" -ne 0 ]
  [ ! -e "$STATE/bgp-out.worker-2" ]
  [[ $output == *"worker-2 does not announce again"* ]]
  [[ $(script_lines | tail -1) != *"is out of BGP"* ]]
}

@test "cluster-check fails while a Ready worker is out of BGP" {
  : > "$STATE/bgp-out.worker-1"

  recipe cluster-check

  [ "$status" -ne 0 ]
  [[ $(line_of 'workers in BGP') == "FAIL  workers in BGP: "*worker-1*"kubectl label node worker-1 $OUT_LABEL-"* ]]
  [ "$(grep -c '^FAIL ' <<< "$output")" -eq 1 ]

  # A worker that is not Ready is down for another reason, which another check names.
  reset_cluster
  : > "$STATE/bgp-out.worker-1"
  echo worker-1 > "$STATE/not-ready"

  recipe cluster-check

  [[ $(line_of 'workers in BGP') == "pass  workers in BGP: "* ]]
  [[ $(line_of 'nodes Ready') == "FAIL  nodes Ready: "* ]]

  # A control plane carrying the label is no worker left out: it has no BGP to leave.
  reset_cluster
  : > "$STATE/bgp-out.cp-1"

  recipe cluster-check

  [ "$status" -eq 0 ]
  [[ $(line_of 'workers in BGP') == "pass  workers in BGP: "* ]]
}

@test "A worker whose BGP configuration does not go is rebooted with --no-bgp-wait, which skips only the wait for its withdrawal" {
  # worker-2's BGP configuration stays although it carries the label, as when its Cilium agent is not
  # running to take the label up; once the label is removed, it takes two reads to come back.
  : > "$STATE/bgp-stays"
  echo 2 > "$STATE/bgp-slow"
  : > "$STATE/bgp-back-late"
  with BGP_WAIT=0

  # Without the flag the bounded wait stops the run before the drain, saying what it saw.
  recipe cluster-reboot worker-2 --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"the CiliumBGPNodeConfig of worker-2 is still there after 0s, as when its Cilium agent is not running to take up the label"* ]]
  [ -z "$(calls '^kubectl (cordon|drain) ')" ]
  [ -z "$(calls '^talman ')" ]
  [[ $(script_lines | tail -1) == *"worker-2 is out of BGP"*"kubectl label node worker-2 $OUT_LABEL-"* ]]

  # With it, the worker is labelled, then cordoned and drained with no read of its configuration
  # before; one line says what was skipped and what it can cost. It goes down out of BGP, and once
  # it is Ready the label is removed and its configuration is read until it is back.
  reset_cluster
  reset_environment
  : > "$STATE/bgp-stays"
  echo 2 > "$STATE/bgp-slow"
  : > "$STATE/bgp-back-late"

  recipe cluster-reboot worker-2 --yes --no-bgp-wait < /dev/null

  [ "$status" -eq 0 ]
  labelled=$(call_line "^kubectl label node worker-2 $OUT_LABEL=true( |\$)")
  cordoned=$(call_line '^kubectl cordon worker-2$')
  drained=$(call_line '^kubectl drain worker-2 ')
  restored=$(call_line "^kubectl label node worker-2 $OUT_LABEL-\$")
  for call in "$labelled" "$cordoned" "$drained" "$restored"; do
    [ -n "$call" ]
  done
  [ "$labelled" -lt "$cordoned" ]
  [ "$(awk -v to="$drained" 'NR < to && /^kubectl get ciliumbgpnodeconfig /' "$RECORD/argv" | wc -l)" -eq 0 ]
  [ "$(cat "$RECORD/reboot-bgp")" = 'worker-2 out' ]
  [ "$drained" -lt "$restored" ]
  [ "$(awk -v from="$restored" 'NR > from && /^kubectl get ciliumbgpnodeconfig worker-2 /' "$RECORD/argv" | wc -l)" -ge 3 ]
  [ "$(grep -c -- '--no-bgp-wait' <<< "$output")" -eq 1 ]
  [[ $output == *"not waiting for the CiliumBGPNodeConfig of worker-2 to be gone (--no-bgp-wait), so the edge routers may keep its paths as stale for up to the restart time"* ]]
  [ ! -e "$STATE/bgp-out.worker-2" ]
  [ -n "$(calls '^kubectl uncordon worker-2$')" ]

  # With it, a run that stops after the label, as when the drain fails, still says last that the
  # worker is out, with the command that puts it back.
  reset_cluster
  reset_environment
  : > "$STATE/bgp-stays"
  : > "$STATE/drain-fails"

  recipe cluster-reboot worker-2 --yes --no-bgp-wait < /dev/null

  [ "$status" -ne 0 ]
  [ -e "$STATE/bgp-out.worker-2" ]
  [[ $(script_lines | tail -1) == *"worker-2 is out of BGP"*"kubectl label node worker-2 $OUT_LABEL-"* ]]

  # A control plane has no BGP, so the flag changes nothing for it.
  reset_cluster
  reset_environment

  recipe cluster-reboot cp-2 --yes --no-bgp-wait < /dev/null

  [ "$status" -eq 0 ]
  [ -z "$(calls '^kubectl label ')" ]
  [[ $output != *"BGP"* ]]
}

@test "A control plane is rebooted without any BGP step" {
  recipe cluster-reboot cp-2 --yes < /dev/null

  [ "$status" -eq 0 ]
  [ -z "$(calls '^kubectl label ')" ]
  [ -z "$(calls 'ciliumbgp')" ]
  [[ $output != *"BGP"* ]]
}

@test "A cluster that still owns a load balancer or a volume is not destroyed, and they are named" {
  for owned in load-balancer csi-volume both; do
    echo "$owned"
    reset_cluster
    case $owned in
      both) : > "$STATE/load-balancer" && : > "$STATE/csi-volume" ;;
      *) : > "$STATE/$owned" ;;
    esac
    echo 2 > "$STATE/linstor-volumes"

    recipe cluster-destroy --yes < /dev/null

    [ "$status" -ne 0 ]
    if [[ $owned != csi-volume ]]; then
      [[ $output == *"Service apps/web"* ]]
    fi
    if [[ $owned != load-balancer ]]; then
      [[ $output == *"PersistentVolume pvc-0a1b2c3d"* ]]
    fi
    for other in default/kubernetes kube-system/hubble-relay local-volume-1 pvc-linstor marker-volume-handle 198.51.100.62; do
      [[ $output != *"$other"* ]]
    done
    no_tofu
    generated_kept
  done
}

@test "A Service on a pool address does not block a destroy, and a Service on any other load balancer still does" {
  # The fixture's service range holds the pool Service's address and neither of the others'.
  [ "$(yq '.values.serviceRange' "$CLUSTER/talman.yaml")" = 192.0.2.128/28 ]
  : > "$STATE/pool-load-balancer"

  recipe cluster-destroy --yes < /dev/null

  [ "$status" -eq 0 ]
  [ "$(calls '^tofu .* apply ' | wc -l)" -eq 1 ]
  [[ $output != *"gateways/public"* ]]

  # Beside a Service at another address, one with no address yet, one with an address in the range
  # and another outside it, or one whose load balancer has a host name, nothing is destroyed, and
  # only the Service that blocks is named.
  declare -A blocking=([load-balancer]=apps/web [pending-load-balancer]=apps/queued
    [mixed-load-balancer]=apps/mixed [hostname-load-balancer]=apps/named)
  for other in "${!blocking[@]}"; do
    echo "$other"
    reset_cluster
    restore_generated
    : > "$STATE/pool-load-balancer"
    : > "$STATE/$other"

    recipe cluster-destroy --yes < /dev/null

    [ "$status" -ne 0 ]
    no_tofu
    generated_kept
    [[ $output != *"gateways/public"* ]]
    [[ $output == *"the Service ${blocking[$other]} is of type LoadBalancer, with an address outside the service range, or none yet"* ]]
  done

  # Without a service range in talman.yaml, no address can be shown to be the pool's.
  reset_cluster
  restore_generated
  yq -i 'del(.values.serviceRange)' "$CLUSTER/talman.yaml"
  : > "$STATE/pool-load-balancer"

  recipe cluster-destroy --yes < /dev/null

  [ "$status" -ne 0 ]
  no_tofu
  [[ $output == *"Service gateways/public"* ]]
}

@test "a service range or a load-balancer address that is not a valid IPv4 one counts as not the pool's" {
  # Each a service range and a Service's only address that arithmetic alone would put inside it.
  cases=('192.0.2.128/0 192.0.2.130' '192.0.2.130/33 192.0.2.130' '999.0.0.0/8 999.0.0.1'
    '192.0.2.128/28 192.0.1.384' '192.0.2.128/28 192.0.2.130.1' '192.0.1.256/24 192.0.2.130')
  for case in "${cases[@]}"; do
    read -r range address <<< "$case"
    echo "$range $address"
    reset_cluster
    restore_generated
    range=$range yq -i '.values.serviceRange = strenv(range)' "$CLUSTER/talman.yaml"
    jq -nc --arg address "$address" '{metadata: {namespace: "apps", name: "odd"}, spec: {type: "LoadBalancer"},
      status: {loadBalancer: {ingress: [{ip: $address}]}}}' > "$STATE/extra-services"

    recipe cluster-destroy --yes < /dev/null

    [ "$status" -ne 0 ]
    no_tofu
    [[ $output == *"Service apps/odd"* ]]
  done

  # The same Service at a valid address in a valid range does not block.
  reset_cluster
  restore_generated
  jq -nc '{metadata: {namespace: "apps", name: "odd"}, spec: {type: "LoadBalancer"},
    status: {loadBalancer: {ingress: [{ip: "192.0.2.130"}]}}}' > "$STATE/extra-services"

  recipe cluster-destroy --yes < /dev/null

  [ "$status" -eq 0 ]
}

@test "LINSTOR's volumes go with the cluster stack once the destroy is confirmed, and are counted first" {
  for answer in '' no lab-sto2; do
    echo "answer: $answer"
    reset_cluster
    echo 3 > "$STATE/linstor-volumes"

    recipe cluster-destroy <<< "$answer"

    [ "$status" -ne 0 ]
    # What the recipe printed before it asked for the stack's name.
    asked=${output%%"Type sto2/cluster to destroy it"*}
    [ "$asked" != "$output" ]
    [[ $asked == *"3 PersistentVolumes of LINSTOR"*"destroyed with the stack"* ]]
    [ -z "$(calls '^tofu .* apply ')" ]
    generated_kept
  done

  reset_cluster
  echo 1 > "$STATE/linstor-volumes"

  recipe cluster-destroy <<< sto2/cluster

  [ "$status" -eq 0 ]
  asked=${output%%"Type sto2/cluster to destroy it"*}
  [ "$asked" != "$output" ]
  [[ $asked == *"1 PersistentVolume of LINSTOR"*"destroyed with the stack"* ]]
  [ "$(calls '^tofu .* apply ' | wc -l)" -eq 1 ]
  [[ $output == *"sto2/cluster destroyed"* ]]

  reset_cluster
  restore_generated
  echo 2 > "$STATE/linstor-volumes"

  recipe cluster-destroy --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"2 PersistentVolumes of LINSTOR"*"destroyed with the stack"* ]]
  [[ $output != *"Type sto2/cluster"* ]]
  [ "$(calls '^tofu .* apply ' | wc -l)" -eq 1 ]
  [[ $output == *"sto2/cluster destroyed"* ]]
  for leaked in pvc-linstor marker-volume-handle 198.51.100.84; do
    [[ $output != *"$leaked"* ]]
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
  [ -z "$(calls '^kubectl ')" ]
  no_tofu
  # Nothing but tofu's reads ran at all.
  [ "$(grep -cv '^tofu ' "$RECORD/argv")" -eq 0 ]
  mv "$BATS_TEST_TMPDIR/kubeconfig" "$CLUSTER/clusterconfig/kubeconfig"
  generated_kept

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
  [ "$(call_line '^tofu .* output ')" -lt "$asked" ]
  [ "$asked" -lt "$(call_line '^tofu .* plan ')" ]
  [ "$asked" -lt "$(call_line '^tofu .* apply ')" ]
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

@test "The cluster stack is asked the same way whichever recipe destroys it" {
  for args in 'sto2/cluster' ''; do
    for owned in load-balancer csi-volume; do
      echo "$args $owned"
      reset_cluster
      restore_generated
      : > "$STATE/$owned"

      # shellcheck disable=SC2086 # the arguments as an operator types them
      recipe infra-destroy $args --yes < /dev/null

      [ "$status" -ne 0 ]
      if [[ $owned == load-balancer ]]; then
        [[ $output == *"Service apps/web"* ]]
      else
        [[ $output == *"PersistentVolume pvc-0a1b2c3d"* ]]
      fi
      for other in default/kubernetes local-volume-1 marker-volume-handle 198.51.100.62; do
        [[ $output != *"$other"* ]]
      done
      no_tofu
      generated_kept
    done

    # A Service on a pool address is not a load balancer of the cloud's, by either recipe; beside a
    # Service at another address, that one is named and nothing is destroyed.
    reset_cluster
    restore_generated
    : > "$STATE/pool-load-balancer"
    : > "$STATE/load-balancer"
    # shellcheck disable=SC2086
    recipe infra-destroy $args --yes < /dev/null

    [ "$status" -ne 0 ]
    [[ $output == *"Service apps/web"* ]]
    [[ $output != *"gateways/public"* ]]
    no_tofu
    generated_kept

    reset_cluster
    restore_generated
    : > "$STATE/pool-load-balancer"
    # shellcheck disable=SC2086
    recipe infra-destroy $args --yes < /dev/null

    [ "$status" -eq 0 ]
    [[ $output == *"sto2/cluster destroyed"* ]]
    restore_generated

    # An API that does not answer, and no kubeconfig: refused, naming --unreachable.
    reset_cluster
    : > "$STATE/api-down"
    # shellcheck disable=SC2086
    recipe infra-destroy $args --yes < /dev/null

    [ "$status" -ne 0 ]
    [[ $output == *"--unreachable"* ]]
    [[ $output != *198.51.100.66* ]]
    no_tofu
    generated_kept

    # shellcheck disable=SC2086
    recipe infra-destroy $args --unreachable --yes < /dev/null

    [ "$status" -eq 0 ]
    [[ $output == *"sto2/cluster destroyed"* ]]
    restore_generated
  done

  # A cluster that owns nothing is destroyed, and nothing is said to be left undone.
  reset_cluster
  restore_generated
  echo 2 > "$STATE/linstor-volumes"

  recipe infra-destroy sto2/cluster --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"2 PersistentVolumes of LINSTOR"*"destroyed with the stack"* ]]
  [[ $output == *"sto2/cluster destroyed"* ]]
  [[ $output != *"not implemented: removing"* ]]
  [ "$(call_line '^kubectl get persistentvolumes ')" -lt "$(call_line '^tofu .* plan ')" ]
}

@test "A cluster is destroyed only under the name its stack holds" {
  # No directory under talos/ for the name: nothing is planned, asked or destroyed.
  recipe cluster-destroy other-cluster --unreachable --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"holds lab-sto2, not other-cluster"* ]]
  no_tofu
  [ -z "$(calls '^kubectl ')" ]
  generated_kept

  # A directory for it, as cluster-secrets and infra-talman make before a cluster exists: the stack
  # still holds another cluster, which is the only one it destroys.
  mkdir -p "$REPO/talos/other-cluster"
  for args in '--unreachable --yes' '--yes' ''; do
    rm -f "$RECORD/argv"
    # shellcheck disable=SC2086 # the arguments as an operator types them
    recipe cluster-destroy other-cluster $args <<< other-cluster

    [ "$status" -ne 0 ]
    [[ $output == *"holds lab-sto2, not other-cluster"* ]]
    no_tofu
    [ -z "$(calls '^kubectl ')" ]
    generated_kept
  done

  # The cluster the stack holds, without a directory of its own, is told so.
  rmdir "$REPO/talos/other-cluster"
  mv "$CLUSTER" "$REPO/talos/lab-sto2.away"
  rm -f "$RECORD/argv"
  recipe cluster-destroy lab-sto2 --unreachable --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2 does not exist"* ]]
  no_tofu
  [ -z "$(calls '^kubectl ')" ]
  mv "$REPO/talos/lab-sto2.away" "$CLUSTER"
  generated_kept

  # A stack whose outputs name no cluster, while its state holds resources, cannot be told to be any
  # name, and nothing is asked.
  fake tofu <<EOF
printf '%s\n' "tofu \$*" >> "$RECORD/argv"
case \${2-} in
  output) echo '{}' ;;
  show) cat "$FIXTURES/state.json" ;;
esac
EOF
  for args in 'lab-sto2 --unreachable --yes' 'lab-sto2 --yes' 'lab-sto2'; do
    rm -f "$RECORD/argv"
    # shellcheck disable=SC2086 # the arguments as an operator types them
    recipe cluster-destroy $args <<< lab-sto2

    [ "$status" -ne 0 ]
    [[ $output == *"outputs name no cluster"* ]]
    [[ $output == *"just infra-destroy sto2/cluster --unreachable"* ]]
    no_tofu
    [ -z "$(calls '^kubectl ')" ]
    generated_kept
  done
}

@test "A cluster destroy that is run again ends as the first run did, with the cluster stack holding nothing" {
  # The constitution's "A recipe that changes live state is idempotent": the stack is gone, so its
  # outputs name no cluster and its state holds no resource.
  fake tofu <<EOF
printf '%s\n' "tofu \$*" >> "$RECORD/argv"
case \${2-} in
  output) echo '{}' ;;
  show) echo '{"format_version": "1.0"}' ;;
esac
EOF
  # Another cluster's generated files are no concern of this one's destroy.
  mkdir -p "$REPO/talos/other-cluster/clusterconfig"
  for file in "${GENERATED[@]}"; do
    echo marker > "$REPO/talos/other-cluster/$file"
  done
  for args in '--unreachable --yes' '--yes' ''; do
    restore_generated
    rm -f "$RECORD/argv"
    # shellcheck disable=SC2086 # the arguments as an operator types them
    recipe cluster-destroy lab-sto2 $args < /dev/null

    [ "$status" -eq 0 ]
    [[ $output == *"sto2/cluster holds no resource, so there is nothing to destroy"* ]]
    no_tofu
    [ -z "$(calls '^kubectl ')" ]
    for file in "${GENERATED[@]}"; do
      [ ! -e "$CLUSTER/$file" ]
      [ -f "$REPO/talos/other-cluster/$file" ]
    done
  done

  # A name with no directory under talos/ is refused whatever the stack holds.
  rm -f "$RECORD/argv"
  recipe cluster-destroy ghost --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"talos/ghost does not exist"* ]]
  no_tofu

  # Run once more, with the generated files already gone.
  rm -f "$RECORD/argv"
  recipe cluster-destroy lab-sto2 --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"holds no resource, so there is nothing to destroy"* ]]
  no_tofu

  # A state that is not read and parsed is not taken for an empty one: no answer, or text that is no
  # JSON, leaves the generated files where they are.
  for answer in '' 'not a state' '[]'; do
    restore_generated
    fake tofu <<EOF
printf '%s\n' "tofu \$*" >> "$RECORD/argv"
case \${2-} in
  output) echo '{}' ;;
  show) printf '%s' '$answer' ;;
esac
EOF
    rm -f "$RECORD/argv"
    recipe cluster-destroy lab-sto2 --unreachable --yes < /dev/null

    [ "$status" -ne 0 ]
    [[ $output == *"cannot read the state of sto2/cluster"* ]]
    no_tofu
    generated_kept
  done

  # A read that fails the way bash does, with status 1, or that ends without the word that says what
  # it found, is not an answer that the stack holds nothing.
  for body in 'exit 1' 'exit 0' 'echo something; exit 0' 'printf "holds\nempty\n"' 'echo empty; exit 1' 'echo holds; exit 1'; do
    restore_generated
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$REPO/scripts/stack-state"
    fake tofu <<EOF
printf '%s\n' "tofu \$*" >> "$RECORD/argv"
case \${2-} in
  output) echo '{}' ;;
esac
EOF
    rm -f "$RECORD/argv"
    recipe cluster-destroy lab-sto2 --unreachable --yes < /dev/null

    [ "$status" -ne 0 ]
    [[ $output == *"cannot read the state of sto2/cluster"* ]]
    no_tofu
    generated_kept
  done
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
    for condition in load-balancer api-down owns-nothing unreachable linstor-volumes; do
      reset_cluster
      args=(--yes)
      case $condition in
        owns-nothing) ;;
        unreachable)
          : > "$STATE/api-down"
          args+=(--unreachable)
          ;;
        linstor-volumes) echo 2 > "$STATE/linstor-volumes" ;;
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
