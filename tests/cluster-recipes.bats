#!/usr/bin/env bats
# Proves features/cluster-recipes.feature; each test carries its scenario's title.
# The recipes run from a copy of the repository. Creating an age key, generating a secrets bundle
# and encrypting it are local and offline, so those tests run the pinned age-keygen, talman,
# talosctl and sops, recorded on their way, with every key inside the test's temporary directory.
# Everything that would reach a node or a cluster runs against recording fakes: talman, talosctl,
# kubectl, install-cilium, cluster-config, install-app, and timeout, which carries the probe of the
# Talos API port. tests/cluster-flux.bats runs the real cluster-config and install-app. The upgrade
# recipes take their etcd snapshot as cluster-snapshot does, so age runs for real, with a throwaway
# key, and rclone is tests/fixtures/etcd-snapshots/rclone, whose buckets are directories.

setup_file() {
  # The tests that run the real talman and sops use whichever is first on PATH: the pinned installs
  # go first, as the justfile puts them, so that an older talman earlier on PATH does not answer.
  if command -v mise > /dev/null; then
    PATH="$(mise bin-paths | paste -sd: -):$PATH"
    export PATH
  fi
  # The Talos check's fixture cluster: talos/talman.yaml.tftpl rendered from tests/fixtures/talos,
  # as talos/<cluster>/talman.yaml is rendered from the cluster stack.
  local encoded
  encoded=$(tofu -chdir="$BATS_TEST_DIRNAME/fixtures/talos" console -no-color <<< 'base64encode(local.talman_yaml)')
  base64 -d <<< "${encoded//\"/}" > "$BATS_FILE_TMPDIR/talman.yaml"
}

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  JUST=$(command -v just)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  STORE="$BATS_TEST_TMPDIR/store"
  FAILS="$BATS_TEST_TMPDIR/store-fails"
  mkdir -p "$BIN" "$RECORD" "$STATE" "$BATS_TEST_TMPDIR/repo/talos/lab-sto2" "$BATS_TEST_TMPDIR/keys" \
    "$BATS_TEST_TMPDIR/repo/infra/openstack" "$STORE/marker-prefix-etcd" "$FAILS"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  CLUSTER="$REPO/talos/lab-sto2"
  BUNDLE="$CLUSTER/secrets.sops.yaml"
  # The scripts, the Talos tree and what cluster-bootstrap checks for cluster-config, so no run
  # touches this checkout.
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp -R "$ROOT/talos/patches" "$REPO/talos/patches"
  cp "$ROOT/talos/schematic.yaml" "$ROOT/talos/.sops.yaml" "$REPO/talos/"
  cp -R "$ROOT/kubernetes" "$REPO/kubernetes"
  cp "$ROOT/.sops.yaml" "$REPO/.sops.yaml"
  # The repository's own SOPS rules name its real recipients; a test starts before any key exists.
  yq -i '.creation_rules[].age = "example-talos-age-recipient"' "$REPO/talos/.sops.yaml"
  yq -i '.creation_rules[].age = "example-flux-age-recipient"' "$REPO/.sops.yaml"
  cp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/talos-sops.placeholder"
  cp "$ROOT/.gitignore" "$REPO/.gitignore"
  cp "$BATS_FILE_TMPDIR/talman.yaml" "$CLUSTER/talman.yaml"
  # The S3 backend settings cluster-config reads the object storage's endpoint from.
  mkdir -p "$REPO/infra/openstack"
  printf 'region = "us-east-1"\nendpoints = {\n  s3 = "https://s3.example.com"\n}\nuse_path_style = true\n' \
    > "$REPO/infra/openstack/backend.hcl"
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise < /dev/null
  KEY="$BATS_TEST_TMPDIR/keys/talos.agekey"
  FLUX_KEY="$BATS_TEST_TMPDIR/keys/flux.agekey"
  KUBE_API_ADDRESS=203.0.113.80
  # TMPDIR keeps the plaintext bundle talman stages before encrypting it inside the test's directory.
  BASE_ENVIRONMENT=(
    SOPS_AGE_KEY_FILE="$KEY"
    KUBE_API_ADDRESS="$KUBE_API_ADDRESS"
    FLUX_AGE_KEY_FILE="$FLUX_KEY"
    CLUSTER_DOMAIN=example.com
    BACKUP_BUCKET_PREFIX=marker-prefix
    AWS_ACCESS_KEY_ID=marker-state-access-key-id
    AWS_SECRET_ACCESS_KEY=marker-state-secret-key
    TMPDIR="$BATS_TEST_TMPDIR"
  )
  reset_environment
}

# fake NAME: a binary first on the recipe's PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# record NAME...: puts each NAME's arguments in the record, then runs the real NAME.
record() {
  local tool real
  for tool; do
    real=$(command -v "$tool")
    fake "$tool" <<EOF
printf '%s\n' "$tool \$*" >> "$RECORD/argv"
exec "$real" "\$@"
EOF
  done
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

# recipe NAME [ARG...]: runs the repository's recipe against the copy, with only ENVIRONMENT set.
# A recipe that blocks fails after two minutes instead of hanging the tests.
recipe() {
  run timeout 120 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$@"
}

# absent TEXT FILE...: fails when any FILE, or any file under a directory FILE, holds TEXT.
absent() {
  local text=$1
  shift
  if grep -rqF -- "$text" "$@"; then
    echo "found $text in $*" >&2
    return 1
  fi
}

# bundle_values FILE: every value of a plaintext secrets bundle, one per line.
bundle_values() {
  yq 'del(.sops) | .. | select(kind == "scalar")' "$1"
}

# A talman that writes the secrets bundle in plaintext, as with --plaintext, whatever it is asked.
plaintext_talman() {
  local real
  real=$(command -v talman)
  fake talman <<EOF
printf '%s\n' "talman \$*" >> "$RECORD/argv"
if [[ \$* == "secrets generate" ]]; then
  exec "$real" secrets generate --plaintext
fi
exec "$real" "\$@"
EOF
}

# git_repository: makes the copy a git repository, so the secrets bundle check sees what git would
# commit.
git_repository() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q "$REPO"
}

# fake_tool NAME: like fake, with RECORD and STATE set in the fake for its body to use.
fake_tool() {
  { printf 'RECORD=%q STATE=%q\n' "$RECORD" "$STATE"; cat; } | fake "$1"
}

# cluster_files: the age key and the secrets bundle the fakes are run with, each holding a secret
# that must never be seen.
cluster_files() {
  echo 'AGE-SECRET-KEY-MARKER-AGE-KEY-FILE' > "$KEY"
  printf 'cluster:\n  secret: marker-bundle-secret\n' > "$BUNDLE"
}

# fake_cluster: a cluster whose nodes wait in maintenance mode and answer on the Talos API port,
# behind recording fakes of talman, talosctl, kubectl, install-cilium, timeout and sleep. What a
# fake does is set by files in STATE:
#   bootstrapped       etcd runs, so talman refuses to bootstrap again
#   answers-on.ADDRESS the node at ADDRESS answers the probe at that try (the first by default)
#   silent.ADDRESS     the node at ADDRESS never answers
#   silent-tried.ADDRESS  the node at ADDRESS stops answering once a node has been applied in try mode
#   changes            applying the configuration would change cp-1
#   new-nodes          the hostnames of nodes in maintenance mode, which talman apply refuses to
#                      configure, and which a dry run does not count as a change, unless onboarding
#   unreachable        talman apply's dry run cannot reach cp-2 and fails
#   pending            the hostnames of running nodes the configuration would change, one per line;
#                      apply -n NODE --mode try puts NODE's in effect, as tried, and apply -n NODE
#                      without try mode keeps it, as kept
#   reverts.NODE       NODE's configuration in try mode reverts before anything else can ask it
#   unreachable.NODE   talman apply's dry run of NODE alone fails
#   etcd.NODE, etcd-subnets.NODE, etcd-args.NODE, network.NODE, scheduler.NODE, module-add.NODE,
#   module-remove.NODE, module-params.NODE
#                      what the change to NODE, one of pending, is: its diff (diff_of) and what
#                      Talos holds for NODE before and after NODE takes it (held)
#   taken.NODE         NODE has been applied the configuration; it runs it while it is not pending
#   unreadable.NODE    NODE's Talos API answers no talosctl get
#   unreadable-after.NODE  likewise, once NODE runs the configuration
#   withheld           talman cannot hide the cluster's secrets, so its dry run shows no diff
#   header-drift       talman's dry run heads each node's block in a format of another version
#   apply-fails.NODE   talman apply of every node fails at NODE, the nodes before it having taken
#                      the configuration
#   reboot-fails.NODE  scripts/cluster-reboot NODE does not bring the node back
#   unhealthy          scripts/cluster-check fails
#   unhealthy-tried    scripts/cluster-check fails once a node has been applied in try mode
#   slow-check         scripts/cluster-check takes that many seconds
#   kubelet-cut.NODE   the API server does not reach NODE's kubelet
#   exporter-cut.NODE  the API server does not reach node-exporter on NODE
#   overlay-cut.NODE   Cilium's health probes through the overlay to and from NODE fail
#   health-cut.NODE    Cilium's health probes of NODE's host, on its health port, fail
#   notready.NODE      NODE's Ready condition is Unknown
#   etcd-cut.NODE      NODE's etcd member has no leader
#   etcd-lost.NODE     NODE's etcd member has no leader once NODE has been rebooted
#   etcd-unlisted.NODE no control plane's etcd member lists NODE's
#   etcd-extra         etcd holds a member of the hostname this file names, no control plane of
#                      talman.yaml
#   etcd-old-table     talosctl's etcd status prints the older table of ten columns
#   api-cut.NODE       the Kubernetes API at NODE's own address does not answer
#   api-refused.NODE   the Kubernetes API at NODE's own address refuses connections; with a number
#                      in it, only that many requests for /readyz, as while a restarted API server
#                      does not listen yet
#   starting.NODE      NODE's API server answers that many requests for /readyz at its own address,
#                      after those it refuses, with an error, not ready, before it answers ok
#   asked.NODE         how many requests for /readyz NODE's API server has answered
#   api-gone.NODE      NODE's API server refuses connections once it has answered ok to /readyz
#   answered.NODE      NODE's API server has answered ok to /readyz
#   lb-slow            a request through the load balancer takes that many seconds
#   lb-cut.NODE        the load balancer sends no connection to NODE's API server
#   lb-back.NODE       the load balancer sends NODE's API server no connection for that many seconds
#                      from the first request through it, as its health monitor takes NODE back
#   lb-out.NODE        the time of that first request
#   lb-turn            which control plane the load balancer sends the next connection to
#   reverts-late.NODE  NODE's configuration in try mode reverts while scripts/cluster-check runs
#   clock              the time date +%s gives, which sleep and a slow cluster-check move on
#   talos-behind       the hostnames of nodes whose Talos is behind their configured version
#   k8s-behind         the kubelets run a Kubernetes behind kubernetesVersion
#   api-down           the Kubernetes API does not answer /readyz
# talosctl's own drain and upgrade-k8s reach the API at the cluster endpoint, the load balancer's
# address on the node network, so the fake talman fails them unless told otherwise. Like talman, the
# fake names the nodes it reaches by address.
fake_cluster() {
  cluster_files
  fake_tool talman <<'EOF'
printf '%s\n' "talman $*" >> "$RECORD/argv"
env | cut -d= -f1 >> "$RECORD/names.talman"
dir=$TALMAN_CONFIG
given() {
  [[ " ${args[*]} " == *" $1 "* ]]
}
# runs NODE: whether NODE runs the configuration it was applied, as it is not pending any more.
runs() {
  [[ -e $STATE/taken.$1 ]] && ! grep -qx -- "$1" "$STATE/pending" 2> /dev/null
}
# held NODE TYPE: what talosctl get TYPE --output json prints of NODE, one JSON object per resource,
# for the two resource types Talos derives from the settings that take effect only at a reboot: etcd's
# configuration, which only a control plane has, and the kernel modules it loads, one resource each.
# Before NODE runs the configuration they hold what the patches set; once it does, what the change
# to NODE makes of them (STATE files named for the node):
#   etcd.NODE            etcd gains extraArgs
#   etcd-subnets.NODE    etcd's listen subnets change
#   etcd-args.NODE       etcd has those extraArgs before as after
#   module-add.NODE      a module is added
#   module-remove.NODE   a module is removed
#   module-params.NODE   a module's parameters change
# The resources' version moves on as Talos rewrites them, whether or not their spec changes.
held() {
  local node=$1 type=$2 after=0 version=1 args='{}' listen='["198.51.100.0/24"]' modules
  if runs "$node"; then
    after=1 version=2
  fi
  if [[ -e $STATE/unreadable.$node ]] || { ((after)) && [[ -e $STATE/unreadable-after.$node ]]; }; then
    echo "error getting resources from 198.51.100.12: rpc error: code = Unavailable desc = connection refused" >&2
    exit 1
  fi
  case $type in
    EtcdConfigs.etcd.talos.dev)
      if [[ $node != cp-* ]]; then
        echo "error: rpc error: code = NotFound desc = resource EtcdConfigs.etcd.talos.dev(etcd/etcd@undefined) doesn't exist" >&2
        exit 1
      fi
      if [[ -e $STATE/etcd-args.$node ]] || { ((after)) && [[ -e $STATE/etcd.$node ]]; }; then
        args='{"listen-metrics-urls": {"values": ["http://0.0.0.0:2381"]}}'
      fi
      if ((after)) && [[ -e $STATE/etcd-subnets.$node ]]; then
        listen='["198.51.100.0/25"]'
      fi
      jq -n --arg node "$node" --argjson version "$version" --argjson args "$args" --argjson listen "$listen" '{
        node: "198.51.100.12",
        metadata: {namespace: "etcd", type: "EtcdConfigs.etcd.talos.dev", id: "etcd", version: $version, owner: "etcd.ConfigController", phase: "running"},
        spec: {advertiseValidSubnets: ["198.51.100.0/24"], advertiseExcludeSubnets: null, listenValidSubnets: $listen,
          listenExcludeSubnets: null, image: "registry.k8s.io/etcd:v3.6.5", extraArgs: $args}}'
      ;;
    KernelModuleSpecs.runtime.talos.dev)
      modules='drbd usermode_helper=disabled
drbd_transport_tcp
dm-thin-pool
dm-snapshot'
      if ((after)); then
        [[ ! -e $STATE/module-params.$node ]] || modules=${modules/usermode_helper=disabled/usermode_helper=enabled}
        [[ ! -e $STATE/module-remove.$node ]] || modules=${modules%$'\n'dm-snapshot}
        [[ ! -e $STATE/module-add.$node ]] || modules+=$'\nzfs'
      fi
      while read -r name parameters; do
        jq -n --arg name "$name" --arg parameters "$parameters" --argjson version "$version" '{
          node: "198.51.100.12",
          metadata: {namespace: "runtime", type: "KernelModuleSpecs.runtime.talos.dev", id: $name, version: $version, owner: "runtime.KernelModuleConfigController", phase: "running"},
          spec: {string: $name, parameters: ($parameters | split(" ") | map(select(. != "")))}}'
      done <<< "$modules"
      ;;
    *)
      echo "error: unexpected resource type $type" >&2
      exit 1
      ;;
  esac
}

# diff_of NODE: the hunks of the unified diff talosctl prints of NODE's configuration, from the one it
# runs to the one talman renders, indented as talman indents them: a marker column, then the line.
# Each has three lines of context, so a change deep in the document shows none of the keys above its
# nearest ones: the cluster: that holds etcd is not in a hunk that adds etcd's arguments.
diff_of() {
  local node=$1 shown=0
  if [[ $node == cp-1 && -e $STATE/changes ]]; then
    echo "     @@ -80,6 +80,7 @@"
    if given --redact-secrets=false; then
      echo "           secret: marker-cluster-secret"
      echo "     +    token: marker-machine-token"
      echo "           ca:"
      echo "             crt: marker-machine-ca-certificate"
    else
      echo "           secret: [redacted]"
      echo "     +    token: [redacted]"
      echo "           ca:"
      echo "             crt: [redacted]"
    fi
    shown=1
  fi
  if [[ -e $STATE/etcd.$node ]]; then
    echo "     @@ -52,6 +52,8 @@"
    echo "             ca:"
    if given --redact-secrets=false; then
      echo "               crt: marker-etcd-certificate"
      echo "               key: marker-etcd-key"
    else
      echo "               crt: [redacted]"
      echo "               key: [redacted]"
    fi
    echo "     +      extraArgs:"
    echo "     +        listen-metrics-urls: http://0.0.0.0:2381"
    echo "           scheduler: {}"
    echo "           discovery:"
    echo "             enabled: true"
    shown=1
  fi
  if [[ -e $STATE/etcd-subnets.$node ]]; then
    echo "     @@ -46,7 +46,7 @@"
    echo "             advertisedSubnets:"
    echo "               - 198.51.100.0/24"
    echo "             listenSubnets:"
    echo "     -        - 198.51.100.0/24"
    echo "     +        - 198.51.100.0/25"
    echo "             ca:"
    shown=1
  fi
  if [[ -e $STATE/scheduler.$node ]]; then
    # etcd's lines are only the context of a change to the scheduler beside them.
    echo "     @@ -55,7 +55,9 @@"
    echo "           etcd:"
    echo "             extraArgs:"
    echo "               listen-metrics-urls: http://0.0.0.0:2381"
    echo "     -      scheduler: {}"
    echo "     +      scheduler:"
    echo "     +        extraArgs:"
    echo "     +          bind-address: 0.0.0.0"
    echo "           discovery:"
    echo "             enabled: true"
    shown=1
  fi
  if [[ -e $STATE/network.$node ]]; then
    echo "     @@ -12,6 +12,7 @@"
    echo "           type: $([[ $node == cp-* ]] && echo controlplane || echo worker)"
    echo "           network:"
    echo "     -        interfaces: []"
    echo "     +        hostname: $node"
    echo "           install:"
    echo "             disk: /dev/vda"
    shown=1
  fi
  if [[ -e $STATE/module-add.$node ]]; then
    echo "     @@ -120,3 +120,7 @@"
    echo "           name: drbd"
    echo "           parameters:"
    echo "             - usermode_helper=disabled"
    echo "     +---"
    echo "     +apiVersion: v1alpha1"
    echo "     +kind: KernelModuleConfig"
    echo "     +name: zfs"
    shown=1
  fi
  if [[ -e $STATE/module-remove.$node ]]; then
    echo "     @@ -120,7 +120,3 @@"
    echo "           name: drbd"
    echo "           parameters:"
    echo "             - usermode_helper=disabled"
    echo "     ----"
    echo "     -apiVersion: v1alpha1"
    echo "     -kind: KernelModuleConfig"
    echo "     -name: dm-snapshot"
    shown=1
  fi
  if [[ -e $STATE/module-params.$node ]]; then
    echo "     @@ -118,5 +118,5 @@"
    echo "           kind: KernelModuleConfig"
    echo "           name: drbd"
    echo "           parameters:"
    echo "     -      - usermode_helper=disabled"
    echo "     +      - usermode_helper=enabled"
    echo "           ---"
    shown=1
  fi
  if ((!shown)); then
    echo "     @@ -140,3 +140,7 @@"
    echo "           name: drbd"
    echo "           parameters:"
    echo "             - usermode_helper=disabled"
    echo "     +---"
    echo "     +apiVersion: v1alpha1"
    echo "     +kind: NetworkRuleConfig"
    echo "     +name: ingress"
  fi
}
args=("$@")
# talman talosctl runs talosctl with --nodes from -n, for each node one table row of what it asks.
if [[ $1 == talosctl ]]; then
  asked=()
  for ((i = 1; i < ${#args[@]}; i++)); do
    if [[ ${args[i]} == -n ]]; then
      asked+=("${args[i + 1]}")
    fi
  done
  if given get; then
    # talosctl get TYPE [ID] --output json of one node; only these types are asked.
    for ((i = 1; i < ${#args[@]}; i++)); do
      [[ ${args[i]} != get ]] || type=${args[i + 1]}
    done
    held "${asked[0]}" "$type"
  elif given status && [[ -e $STATE/etcd-old-table ]]; then
    printf 'NODE   MEMBER   DB SIZE   IN USE   LEADER   RAFT INDEX   RAFT TERM   RAFT APPLIED INDEX   LEARNER   ERRORS\n'
    for node in "${asked[@]}"; do
      printf '192.0.2.211   %s   41 MB   18 MB (43.90%%)   1a2b3c4d5e6f7a8b   1234   7   1234   false   etcdserver: no leader\n' "member-$node"
    done
  elif given status; then
    printf 'NODE   MEMBER   DB SIZE   IN USE   LEADER   RAFT INDEX   RAFT TERM   RAFT APPLIED INDEX   LEARNER   PROTOCOL   STORAGE   ERRORS\n'
    for node in "${asked[@]}"; do
      leader=1a2b3c4d5e6f7a8b errors=
      if [[ -e $STATE/etcd-cut.$node ]] || [[ -e $STATE/etcd-lost.$node && -e $STATE/rebooted.$node ]]; then
        leader=0000000000000000 errors='etcdserver: no leader'
      fi
      printf '192.0.2.211   %s   41 MB   18 MB (43.90%%)   %s   1234   7   1234   false   3.6.0   3.6.0   %s\n' \
        "member-$node" "$leader" "$errors"
    done
  elif given members; then
    printf 'NODE   ID   HOSTNAME   PEER URLS   CLIENT URLS   LEARNER\n'
    for node in $(yq '.nodes[] | select(.role == "controlplane") | .hostname' "$dir/talman.yaml"); do
      [[ ! -e $STATE/etcd-unlisted.$node ]] || continue
      printf '192.0.2.211   %s   %s   https://192.0.2.20:2380   https://192.0.2.20:2379   false\n' "id-$node" "$node"
    done
    if [[ -e $STATE/etcd-extra ]]; then
      printf '198.51.100.212   id-old   %s   https://198.51.100.213:2380   https://198.51.100.213:2379   false\n' "$(< "$STATE/etcd-extra")"
    fi
  fi
  exit 0
fi
echo "== reaching the nodes at $(sed -n 's/^ *ipAddress: //p' "$dir/talman.yaml" | paste -sd, -)"
# The node -n names and the mode --mode or -m names, if any.
target= mode=auto
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    -n) target=${args[i + 1]-} ;;
    -m | --mode) mode=${args[i + 1]-} ;;
    --mode=*) mode=${args[i]#--mode=} ;;
  esac
done
# take_own_snapshot: what upgrade --snapshot and upgrade-k8s --snapshot do before they change
# anything: a snapshot in the output directory, as the pinned talman writes it.
take_own_snapshot() {
  if given --snapshot; then
    (umask 077 && cp "$STATE/content" "$dir/clusterconfig/etcd-lab-sto2-$(date -u +%Y%m%dT%H%M%SZ).db")
  fi
}
case "$1" in
  apply)
    if given --bootstrap; then
      if [[ -e $STATE/bootstrapped ]]; then
        echo "error: cp-1 runs etcd: a cluster is here already, and bootstrapping it again would split it" >&2
        exit 1
      fi
      : > "$STATE/bootstrapped"
      echo "== bootstrapping etcd on cp-1"
      exit 0
    fi
    new=$(cat "$STATE/new-nodes" 2> /dev/null | tr '\n' ' ' || true)
    pending=$(cat "$STATE/pending" 2> /dev/null | tr '\n' ' ' || true)
    if given --dry-run; then
      if [[ -e $STATE/unreachable ]]; then
        echo "error: cp-2 answers neither the Talos API nor the maintenance service" >&2
        exit 1
      fi
      if [[ -n $target && -e $STATE/unreachable.$target ]]; then
        echo "error: $target answers neither the Talos API nor the maintenance service" >&2
        exit 1
      fi
      changed=0
      # Like talman, it prints, to standard error, each node's block in the order of talman.yaml: a
      # header, then what talosctl's dry run printed, indented, ending with the unified diff of the
      # whole document, three lines of context around each change. A talman that cannot hide the
      # cluster's secrets in a diff, without --redact-secrets=false, shows only whether there is one.
      withheld=0
      if [[ -e $STATE/withheld ]] && ! given --redact-secrets=false; then
        withheld=1
        printf '%s\n' "cannot hide this cluster's secrets in the diff: no SOPS key" '  diffs are not shown' >&2
      fi
      mapfile -t nodes < <(yq '.nodes[].hostname' "$dir/talman.yaml")
      position=0
      for node in "${nodes[@]}"; do
        position=$((position + 1))
        [[ -z $target || $node == "$target" ]] || continue
        address=$(yq ".nodes[] | select(.hostname == \"$node\") | .ipAddress" "$dir/talman.yaml")
        header="== [$position/${#nodes[@]}] $node ($address)"
        [[ ! -e $STATE/header-drift ]] || header="--- node $node at $address ($position of ${#nodes[@]})"
        if [[ " $new " == *" $node "* ]]; then
          continue
        fi
        node_changed=0
        if [[ " $pending " == *" $node "* || ( -z $target && $node == cp-1 && -e $STATE/changes ) ]]; then
          node_changed=1 changed=1
        fi
        {
          echo "$header"
          if ((withheld)); then
            if ((node_changed)); then
              echo "     changes; diff not shown"
            else
              echo "     no changes"
            fi
            continue
          fi
          echo "     Dry run summary:"
          echo "     Applied configuration without a reboot (skipped in dry-run)"
          echo "     Config diff:"
          echo "     "
          if ((node_changed)); then
            echo "     --- a"
            echo "     +++ b"
            diff_of "$node"
          else
            echo "     No changes."
          fi
        } >&2
      done
      for node in $new; do
        echo "== [?/${#nodes[@]}] $node (198.51.100.99) · new: a real run configures it only with --onboard-new-nodes" >&2
        if given --onboard-new-nodes; then
          changed=1
        else
          echo "     a real run would need --onboard-new-nodes" >&2
        fi
      done
      if given --detailed-exit-code && ((changed)); then
        exit 2
      fi
      exit 0
    fi
    if [[ -n $target ]]; then
      grep -vx -- "$target" "$STATE/pending" > "$STATE/pending.next" || true
      mv "$STATE/pending.next" "$STATE/pending"
      : > "$STATE/taken.$target"
      echo "     Applied configuration without a reboot"
      if [[ $mode == try ]]; then
        echo "$target" >> "$STATE/tried"
        echo "     The config is applied in 'try' mode and will be automatically reverted back in 5m0s"
        if [[ -e $STATE/reverts.$target ]]; then
          echo "$target" >> "$STATE/pending"
        fi
      else
        echo "$target" >> "$STATE/kept"
      fi
      exit 0
    fi
    if [[ -n $new ]] && ! given --onboard-new-nodes; then
      echo "error: new node(s), in maintenance mode: $new" >&2
      exit 1
    fi
    if given --onboard-new-nodes; then
      : > "$STATE/new-nodes"
    fi
    # One node after the other, in talman.yaml's order, until one fails.
    for node in $(yq '.nodes[].hostname' "$dir/talman.yaml"); do
      if [[ -e $STATE/apply-fails.$node ]]; then
        echo "error: applying the configuration to $node at 198.51.100.12: connection reset" >&2
        exit 1
      fi
      if [[ " $pending " == *" $node "* ]]; then
        : > "$STATE/taken.$node"
        grep -vx -- "$node" "$STATE/pending" > "$STATE/pending.next" || true
        mv "$STATE/pending.next" "$STATE/pending"
      fi
    done
    rm -f "$STATE/changes" "$STATE/pending"
    echo "     Applied configuration without a reboot"
    ;;
  kubeconfig)
    mkdir -p "$dir/clusterconfig"
    cat > "$dir/clusterconfig/kubeconfig" <<'KUBECONFIG'
apiVersion: v1
kind: Config
clusters:
  - name: example
    cluster:
      server: https://192.0.2.10:6443
      certificate-authority-data: marker-certificate-authority-data
users:
  - name: admin@example
    user:
      client-certificate-data: marker-client-certificate-data
      client-key-data: marker-client-key-data
contexts:
  - name: admin@example
    context:
      cluster: example
      user: admin@example
current-context: admin@example
KUBECONFIG
    chmod 644 "$dir/clusterconfig/kubeconfig"
    echo "wrote clusterconfig/kubeconfig"
    ;;
  upgrade)
    node=
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ ${args[i]} == -n ]]; then
        node=${args[i + 1]-}
      fi
    done
    behind=$(cat "$STATE/talos-behind" 2> /dev/null || true)
    if given --dry-run; then
      changed=0
      for each in $behind; do
        if [[ -z $node || $each == "$node" ]]; then
          echo "== $each: v1.14.5 -> v1.14.6"
          changed=1
        fi
      done
      if given --detailed-exit-code && ((changed)); then
        exit 2
      fi
      exit 0
    fi
    if ! given --extra-flags=--drain=false; then
      echo "error: draining $node: dial tcp 192.0.2.5:6443: i/o timeout" >&2
      exit 1
    fi
    # The node's kubelet reports once more while the upgrade starts, after the drain and before the
    # node goes away, and the next second begins before talman returns, as heartbeats are told to
    # the second.
    date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE/drained.$node"
    now=$(date -u +%s)
    while [[ $(date -u +%s) == "$now" ]]; do
      command sleep 0.1
    done
    take_own_snapshot
    grep -vx -- "$node" "$STATE/talos-behind" > "$STATE/talos-behind.next" || true
    mv "$STATE/talos-behind.next" "$STATE/talos-behind"
    : > "$STATE/upgraded.$node"
    echo "== $node: upgraded to v1.14.6"
    ;;
  upgrade-k8s)
    if given --dry-run; then
      if [[ -e $STATE/k8s-behind ]]; then
        echo "== cp-1 runs Kubernetes v1.37.0 -> v1.37.1"
        if given --detailed-exit-code; then
          exit 2
        fi
      else
        echo "nothing to upgrade: every node already runs Kubernetes v1.37.1"
      fi
      exit 0
    fi
    if [[ " ${args[*]} " != *" --extra-flags=--endpoint=https://"* ]]; then
      echo "error: dial tcp 192.0.2.5:6443: i/o timeout" >&2
      exit 1
    fi
    take_own_snapshot
    rm -f "$STATE/k8s-behind"
    echo "== upgraded Kubernetes to v1.37.1"
    ;;
  reboot)
    # The node goes down and comes back, its kubelet reporting Ready again.
    : > "$STATE/rebooted.$target"
    echo "== $target: rebooted"
    ;;
  etcd)
    # Without a path the snapshot lands in the output directory, as the pinned talman writes it, and
    # nothing is written over an existing file.
    path=${3-$dir/clusterconfig/etcd-lab-sto2-20261114T000000Z.db}
    if [[ -e $path ]]; then
      echo "error: refusing to write over $path" >&2
      exit 1
    fi
    printf 'path %s\nmode %s\n' "$path" "$(stat -c %a "$(dirname "$path")")" >> "$RECORD/snapshot"
    if [[ -e $STATE/snapshot-fails ]]; then
      echo "error: etcd on cp-1 closed the stream" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$path")"
    (umask 077 && cp "$STATE/content" "$path")
    echo "wrote $path"
    ;;
esac
EOF
  fake_tool talosctl <<'EOF'
printf '%s\n' "talosctl $*" >> "$RECORD/argv"
EOF
  fake_tool kubectl <<'EOF'
printf '%s\n' "kubectl $*" >> "$RECORD/argv"
env | cut -d= -f1 >> "$RECORD/names.kubectl"
printf '%s\n' "${KUBECONFIG-}" > "$RECORD/kubeconfig"
if [[ $* == *" /readyz"* && -e $STATE/api-down ]]; then
  echo "The connection to the server was refused" >&2
  exit 1
fi
# What the try mode's checks ask: a node's kubelet and node-exporter through an API server, the
# Cilium agent on a node and its health probes, and a node's Ready condition.
line=" $* "
# The control plane at the address --server names, if any; the load balancer otherwise.
server=
if [[ $line == *" --server https://"* ]]; then
  server=${line#* --server https://}
  server=$(yq ".nodes[] | select(.ipAddress == \"${server%%:6443 *}\") | .hostname" "$TALMAN_CONFIG/talman.yaml")
fi
# long LINE...: each LINE, then several hundred kilobytes more, as a real API server's or exporter's
# metrics run to, far more than a pipe holds: a reader that stops at its match closes the pipe while
# this is still writing, which, under pipefail, fails the command as it would kubectl.
long() {
  printf '%s\n' "$@"
  printf '# HELP filler_metric_total A metric that is only there to make the answer long.\nfiller_metric_total{n="%s"} 0\n' $(seq 4000)
}
# address NODE: NODE's address in talman.yaml.
address() {
  yq ".nodes[] | select(.hostname == \"$1\") | .ipAddress" "$TALMAN_CONFIG/talman.yaml"
}
# unanswered ADDRESS PORT: fails as kubectl does when nothing answers at ADDRESS on PORT, with an
# error that names the address.
unanswered() {
  printf 'Error from server: error dialing backend: dial tcp %s:%s: i/o timeout\n' "$1" "$2" >&2
  exit 1
}
# unreachable SERVER: fails as kubectl does when the API server it is pointed at never answers,
# dropped or refused, naming the server's address.
unreachable() {
  if [[ -e $STATE/api-refused.$1 || -e $STATE/api-gone.$1 ]]; then
    printf 'The connection to the server %s:6443 was refused - did you specify the right host or port?\n' "$(address "$1")" >&2
  else
    printf 'Unable to connect to the server: dial tcp %s:6443: i/o timeout\n' "$(address "$1")" >&2
  fi
  exit 1
}
# refusing SERVER: whether SERVER refuses connections now: always with api-refused.SERVER empty, and
# for its first that many requests for /readyz with a number in it; with api-gone.SERVER, once it has
# answered ok to one.
refusing() {
  [[ ! -e $STATE/api-gone.$1 || ! -e $STATE/answered.$1 ]] || return 0
  [[ -e $STATE/api-refused.$1 ]] || return 1
  local first
  first=$(cat "$STATE/api-refused.$1")
  [[ -z $first ]] || (($(cat "$STATE/asked.$1" 2> /dev/null || echo 0) <= first))
}
clock=$(cat "$STATE/clock" 2> /dev/null || echo 1800000000)
case $line in
  *" get --raw /readyz "*)
    if [[ -n $server ]]; then
      asked=$(($(cat "$STATE/asked.$server" 2> /dev/null || echo 0) + 1))
      echo "$asked" > "$STATE/asked.$server"
      [[ ! -e $STATE/api-cut.$server ]] && ! refusing "$server" || unreachable "$server"
      # An API server that has just started is not ready until its post-start hooks are done: once it
      # takes connections, it answers the next starting.SERVER requests with 500 and the list of its
      # checks, as kubectl quotes a server's error.
      refused=$(cat "$STATE/api-refused.$server" 2> /dev/null || true)
      if ((asked <= ${refused:-0} + $(cat "$STATE/starting.$server" 2> /dev/null || echo 0))); then
        printf 'Error from server (InternalError): an error on the server ("%s") has prevented the request from succeeding\n' \
          '[+]ping ok\n[+]log ok\n[+]etcd ok\n[+]poststarthook/start-apiserver-admission-initializer ok\n[-]poststarthook/rbac/bootstrap-roles failed: reason withheld\n[-]poststarthook/scheduling/bootstrap-system-priority-classes failed: reason withheld\n[+]poststarthook/start-kube-aggregator-informers ok\n[+]shutdown ok\nreadyz check failed' >&2
        exit 1
      fi
      : > "$STATE/answered.$server"
    fi
    echo ok
    ;;
  *" get --raw /metrics "*)
    # An API server's metrics, with the start time of its process. Through the load balancer, each
    # new connection goes to the next control plane it can reach and that its health monitor has in
    # rotation: lb-back.NODE keeps NODE out for that many seconds from the first request through it.
    if [[ -z $server ]]; then
      mapfile -t members < <(yq '.nodes[] | select(.role == "controlplane") | .hostname' "$TALMAN_CONFIG/talman.yaml")
      turn=$(cat "$STATE/lb-turn" 2> /dev/null || echo 0)
      for ((i = 0; i < ${#members[@]}; i++)); do
        candidate=${members[(turn + i) % ${#members[@]}]}
        [[ ! -e $STATE/lb-cut.$candidate ]] || continue
        if [[ -e $STATE/lb-back.$candidate ]]; then
          [[ -e $STATE/lb-out.$candidate ]] || echo "$clock" > "$STATE/lb-out.$candidate"
          ((clock >= $(cat "$STATE/lb-out.$candidate") + $(cat "$STATE/lb-back.$candidate"))) || continue
        fi
        server=$candidate
        break
      done
      echo $((turn + i + 1)) > "$STATE/lb-turn"
      # A request through the load balancer that takes lb-slow seconds.
      [[ ! -e $STATE/lb-slow ]] || echo $((clock + $(cat "$STATE/lb-slow"))) > "$STATE/clock"
      [[ -n $server ]] || exit 1
    elif [[ -e $STATE/api-cut.$server ]] || refusing "$server"; then
      unreachable "$server"
    fi
    long '# TYPE process_start_time_seconds gauge' "process_start_time_seconds 1.8000000${server##*-}5e+09"
    ;;
  *" get --raw /api/v1/nodes/http:"*":9100/proxy/metrics "*)
    node=${line#* /api/v1/nodes/http:}
    node=${node%%:9100/*}
    [[ ! -e $STATE/exporter-cut.$node ]] || unanswered "$(address "$node")" 9100
    long '# TYPE node_exporter_build_info gauge' 'node_exporter_build_info{version="1.9.1"} 1'
    ;;
  *" get --raw /api/v1/nodes/"*"/proxy/healthz "*)
    node=${line#* /api/v1/nodes/}
    node=${node%%/proxy/healthz *}
    # The API server dials a kubelet at the node's InternalIP, which may be an IPv6 one.
    [[ ! -e $STATE/kubelet-cut.$node ]] || unanswered '[2001:db8::22]' 10250
    echo ok
    ;;
  *" get pods --selector k8s-app=cilium --field-selector spec.nodeName="*)
    node=${line#*spec.nodeName=}
    printf 'cilium-%s' "${node%% *}"
    ;;
  *" exec cilium-"*" -- cilium-health status --probe --output json "*)
    agent=${line#* exec cilium-}
    agent=${agent%% *}
    entries=()
    failed='Get \"http://192.0.2.20:4240/hello\": context deadline exceeded'
    for node in $(sed -n 's/^ *- hostname: //p' "$TALMAN_CONFIG/talman.yaml"); do
      [[ $node != "$agent" ]] || continue
      # The overlay fails both ways when either end drops it; the health port only into its node.
      endpoint= host=
      if [[ -e $STATE/overlay-cut.$node || -e $STATE/overlay-cut.$agent ]]; then
        endpoint=$failed host=$failed
      fi
      if [[ -e $STATE/health-cut.$node ]]; then
        host=$failed
      fi
      entries+=("{\"name\":\"default/$node\",\"host\":{\"primary-address\":{\"ip\":\"192.0.2.20\",\"http\":{\"status\":\"$host\"},\"icmp\":{}}},\"health-endpoint\":{\"primary-address\":{\"ip\":\"198.51.100.10\",\"http\":{\"status\":\"$endpoint\"},\"icmp\":{}}}}")
    done
    printf '{"nodes":[%s]}\n' "$(IFS=,; echo "${entries[*]}")"
    ;;
  *" get node "*" --output json "*)
    node=${line#* get node }
    node=${node%% *}
    ready=True
    [[ ! -e $STATE/notready.$node ]] || ready=Unknown
    # A warning the API server attaches to an answer, which kubectl prints and still succeeds.
    echo "Warning: node $node is answered from 192.0.2.211" >&2
    # The images a node holds are part of its status, which they make longer than a pipe holds.
    images=$(printf '{"names":["registry.example.com/filler/image-%s:v1"],"sizeBytes":1},' $(seq 3000))
    printf '{"status":{"conditions":[{"type":"Ready","status":"%s"}],"images":[%s]}}\n' "$ready" "${images%,}"
    ;;
esac
if [[ $1 == drain ]]; then
  # The node's kubelet reported Ready as the drain began, inside the run and before the upgrade, so
  # a Ready that counts is one reported after the upgrade began, not after the run did. The next
  # second begins before the drain returns, as heartbeats are told to the second.
  date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE/drained.$2"
  now=$(date -u +%s)
  while [[ $(date -u +%s) == "$now" ]]; do
    command sleep 0.1
  done
fi
if [[ $1 == get && $2 == nodes ]]; then
  # A node's kubelet reports Ready again some polls after the node was upgraded or rebooted, as many
  # as its stale.<hostname> file says, and never when it says never; until then, and before the
  # upgrade, its Ready condition is the last one it reported before its upgrade: the drain's time, or
  # an old one for a node never drained.
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  items=()
  for node in $(yq '.nodes[].hostname' "${TALMAN_CONFIG:?}/talman.yaml"); do
    beat=$(cat "$STATE/drained.$node" 2> /dev/null || echo 2026-01-01T00:00:00Z)
    if [[ -e $STATE/upgraded.$node || -e $STATE/rebooted.$node ]]; then
      stale=$(cat "$STATE/stale.$node" 2> /dev/null || echo 0)
      if [[ $stale == never ]]; then
        :
      elif ((stale > 0)); then
        echo "$((stale - 1))" > "$STATE/stale.$node"
      else
        beat=$now
      fi
    fi
    items+=("{\"metadata\": {\"name\": \"$node\"}, \"status\": {\"conditions\": [
      {\"type\": \"Ready\", \"status\": \"True\", \"lastHeartbeatTime\": \"$beat\"}]}}")
  done
  printf '{"apiVersion": "v1", "kind": "List", "items": [%s]}\n' "$(IFS=,; echo "${items[*]}")"
fi
EOF
  # The nodes answer a connection to the Talos API port only.
  fake_tool timeout <<'EOF'
printf '%s\n' "timeout $*" >> "$RECORD/argv"
[[ $* == *"/dev/tcp/"*50000* ]] || exit 1
address=${*: -1}
tries=$(($(cat "$STATE/tries.$address" 2> /dev/null || echo 0) + 1))
echo "$tries" > "$STATE/tries.$address"
[[ ! -e $STATE/silent.$address ]] && ! [[ -e $STATE/silent-tried.$address && -s $STATE/tried ]] &&
  ((tries >= $(cat "$STATE/answers-on.$address" 2> /dev/null || echo 1)))
EOF
  # A clock of its own: date +%s reads it, and sleep moves it on instead of waiting.
  fake_tool date <<'EOF'
if [[ $* == +%s ]]; then
  cat "$STATE/clock" 2> /dev/null || echo 1800000000
  exit 0
fi
exec "$(command -v -p date)" "$@"
EOF
  fake_tool sleep <<'EOF'
printf '%s\n' "sleep $*" >> "$RECORD/argv"
clock=$(cat "$STATE/clock" 2> /dev/null || echo 1800000000)
echo $((clock + ${1%%[!0-9]*})) > "$STATE/clock"
EOF
  fake_tool install-cilium <<'EOF'
printf '%s\n' "install-cilium KUBECONFIG=${KUBECONFIG-}" >> "$RECORD/argv"
EOF
  mv "$BIN/install-cilium" "$REPO/scripts/install-cilium"
  fake_tool cluster-config <<'EOF'
printf '%s\n' "cluster-config $*" >> "$RECORD/argv"
EOF
  mv "$BIN/cluster-config" "$REPO/scripts/cluster-config"
  fake_tool install-app <<'EOF'
printf '%s\n' "install-app $* KUBECONFIG=${KUBECONFIG-}" >> "$RECORD/argv"
EOF
  mv "$BIN/install-app" "$REPO/scripts/install-app"
  fake_tool cluster-check <<'EOF'
printf '%s\n' "cluster-check $*" >> "$RECORD/argv"
if [[ -e $STATE/slow-check ]]; then
  echo $(($(cat "$STATE/clock" 2> /dev/null || echo 1800000000) + $(cat "$STATE/slow-check"))) > "$STATE/clock"
fi
for late in "$STATE"/reverts-late.*; do
  if [[ -e $late ]] && grep -qx "${late##*.}" "$STATE/tried" 2> /dev/null; then
    echo "${late##*.}" >> "$STATE/pending"
  fi
done
if [[ -e $STATE/unhealthy ]] || [[ -e $STATE/unhealthy-tried && -s $STATE/tried ]]; then
  echo "FAIL  nodes Ready: not Ready: worker-2"
  echo "cluster-check: 1 of 7 checks failed" >&2
  exit 1
fi
echo "cluster-check: every check of lab-sto2 passes"
EOF
  mv "$BIN/cluster-check" "$REPO/scripts/cluster-check"
  # cluster-reboot, which cluster-talos --reboot runs for each node that needs a reboot, takes a
  # moment between its start and its end, so a second one that runs beside it shows in the record.
  fake_tool cluster-reboot <<'EOF'
printf '%s\n' "cluster-reboot $*" >> "$RECORD/argv"
printf '%s\n' "start $1" >> "$RECORD/reboots"
"$(command -v -p sleep)" 0.3
printf '%s\n' "end $1" >> "$RECORD/reboots"
if [[ -e $STATE/reboot-fails.$1 ]]; then
  echo "cluster-reboot: $1 has not reported Ready since its reboot" >&2
  exit 1
fi
EOF
  mv "$BIN/cluster-reboot" "$REPO/scripts/cluster-reboot"
  # The etcd bucket, the endpoint's only source, and the Talos age key's recipient the snapshot is
  # encrypted to, with its private half in SNAPSHOT_KEY for the tests to decrypt with.
  sed -E 's#https://[^"]+#https://marker-endpoint.example.invalid#' "$ROOT/infra/openstack/backend.hcl" > "$REPO/infra/openstack/backend.hcl"
  cp "$BATS_TEST_DIRNAME/fixtures/etcd-snapshots/rclone" "$BIN/rclone"
  SNAPSHOT_KEY="$BATS_TEST_TMPDIR/keys/snapshot.agekey"
  age-keygen -o "$SNAPSHOT_KEY" 2> /dev/null
  RECIPIENT=$(age-keygen -y "$SNAPSHOT_KEY") yq -i '.creation_rules[].age = strenv(RECIPIENT)' "$REPO/talos/.sops.yaml"
  printf 'marker-snapshot-content %s\n\001\002binary tail\n' "$RANDOM$RANDOM" > "$STATE/content"
  # The Flux age key, with its recipient in .sops.yaml, which cluster-bootstrap checks first.
  age-keygen -o "$FLUX_KEY" 2> /dev/null
  RECIPIENT=$(age-keygen -y "$FLUX_KEY") yq -i '.creation_rules[].age = strenv(RECIPIENT)' "$REPO/.sops.yaml"
}

# node_address HOSTNAME: the address talman reaches HOSTNAME on, from the cluster's talman.yaml.
node_address() {
  yq ".nodes[] | select(.hostname == \"$1\") | .ipAddress" "$CLUSTER/talman.yaml"
}

# call_line PATTERN: the line number in the record of the first call matching the extended regex.
call_line() {
  grep -n -m1 -E -- "$1" "$RECORD/argv" | cut -d: -f1
}

# last_call_line PATTERN: the line number in the record of the last call matching the extended regex.
last_call_line() {
  grep -n -E -- "$1" "$RECORD/argv" | tail -1 | cut -d: -f1
}

# calls PATTERN: the recorded calls matching the extended regex, one per line.
calls() {
  grep -E -- "$1" "$RECORD/argv" || true
}

# next_second: waits until the UTC second changes, so that the next snapshot takes a name of its own;
# one taken in the same second as another is refused.
next_second() {
  local now
  now=$(date -u +%s)
  while [[ $(date -u +%s) == "$now" ]]; do
    command sleep 0.1
  done
}

# applies: the recorded talman apply calls that are not dry runs, one per line.
applies() {
  calls '^talman apply( |$)' | grep -v -- ' --dry-run' || true
}

# early_readers FILE...: FILE:LINE for each pipeline in the bash scripts FILE... that feeds a reader
# which may stop before its input ends. Such a reader closes the pipe while the command before it is
# still writing, as soon as that writes more than the pipe holds, and the writer dies of SIGPIPE;
# under pipefail the pipeline then fails, whatever the reader found. The readers it knows: grep that
# stops at a match (-q, -l, -L, -m, or its output sent to /dev/null, which GNU grep takes as -q),
# head, read, sed with a q command, awk with an exit before its END, and jq that reads its input
# itself or halts. Commands are split at each | outside quotes and comments, and a pipeline is
# followed onto the next line after a trailing | or \ and while a quote is open.
early_readers() {
  awk -v q="'" '
    # program(command): the text of the first quoted program in command.
    function program(command,    from, rest, to) {
      from = index(command, q)
      if (!from) return ""
      rest = substr(command, from + 1)
      to = index(rest, q)
      return to ? substr(rest, 1, to - 1) : rest
    }
    function early(command,    text, end) {
      sub(/^[[:space:]]+/, "", command)
      if (command ~ /^(\{[[:space:]]*)?([A-Za-z_][A-Za-z_0-9]*=[^[:space:]]*[[:space:]]+)*read([[:space:]]|$)/) return 1
      if (command ~ /^head([[:space:]]|$)/) return 1
      if (command ~ /^grep[[:space:]]/)
        return command ~ /[[:space:]]-[A-Za-z]*[qlLm]/ || command ~ /--(quiet|silent|max-count|files-with)/ ||
          command ~ />[[:space:]]*\/dev\/null/
      if (command ~ /^sed[[:space:]]/) return program(command) ~ /(^|[;{}[:space:]0-9$\/])q([;}[:space:]]|$)/
      if (command ~ /^awk[[:space:]]/) {
        text = program(command)
        end = index(text, "END")
        if (end) text = substr(text, 1, end - 1)
        return text ~ /(^|[^A-Za-z_])exit([^A-Za-z_]|$)/
      }
      if (command ~ /^jq[[:space:]]/) return program(command) ~ /(^|[^A-Za-z_.$])(input|inputs|halt|halt_error)([^A-Za-z_]|$)/
      return 0
    }
    # split_commands(text): text cut into part[1..n] at each | outside quotes and comments that is
    # not part of ||; returns n, and sets open when text ends inside a quote.
    function split_commands(text,    i, c, n, single, double, comment) {
      n = 1
      part[1] = ""
      single = double = comment = 0
      for (i = 1; i <= length(text); i++) {
        c = substr(text, i, 1)
        if (comment) {
          if (c == "\n") comment = 0
          continue
        }
        if (single) {
          if (c == q) single = 0
        } else if (c == "\\") {
          part[n] = part[n] substr(text, i, 2)
          i++
          continue
        } else if (double) {
          if (c == "\"") double = 0
        } else if (c == q) {
          single = 1
        } else if (c == "\"") {
          double = 1
        } else if (c == "#" && (i == 1 || substr(text, i - 1, 1) ~ /[[:space:]]/)) {
          comment = 1
          continue
        } else if (c == "|") {
          if (substr(text, i + 1, 1) == "|") {
            part[n] = part[n] "||"
            i++
            continue
          }
          part[++n] = ""
          continue
        }
        part[n] = part[n] c
      }
      open = single || double
      return n
    }
    # A file that ends inside a pipeline or a quote was not split as bash would split it.
    FNR == 1 && held != "" {
      print file ":" start ": not read to its end"
      held = ""
    }
    { file = FILENAME }
    END {
      if (held != "") print file ":" start ": not read to its end"
    }
    held == "" && /^[[:space:]]*#/ { next }
    {
      if (held == "") start = FNR
      text = held $0
      held = ""
      n = split_commands(text)
      if (open || text ~ /(\||\\)[[:space:]]*$/) {
        held = text "\n"
        next
      }
      for (i = 2; i <= n; i++) {
        if (early(part[i])) {
          print FILENAME ":" start
          break
        }
      }
    }' "$@"
}

@test "The age key is created once and never printed" {
  record age-keygen yq

  recipe cluster-age-key

  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$KEY")" = 600 ]
  recipient=$(age-keygen -y "$KEY")
  [ "$output" = "$recipient" ]
  [ "$(yq '.creation_rules[].age' "$REPO/talos/.sops.yaml")" = "$recipient" ]
  cp "$KEY" "$BATS_TEST_TMPDIR/key.before"
  cp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"

  recipe cluster-age-key

  [ "$status" -eq 0 ]
  [ "$output" = "$recipient" ]
  cmp "$KEY" "$BATS_TEST_TMPDIR/key.before"
  cmp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"
  secret=$(grep '^AGE-SECRET-KEY-' "$KEY")
  absent "$secret" "$RECORD/argv" "$REPO"
}

@test "cluster-age-key refuses a key file inside the repository" {
  without SOPS_AGE_KEY_FILE
  with SOPS_AGE_KEY_FILE="$REPO/talos/talos.agekey"

  recipe cluster-age-key

  [ "$status" -ne 0 ]
  [[ $output == *"SOPS_AGE_KEY_FILE names a path inside the repository"* ]]
  [ ! -e "$REPO/talos/talos.agekey" ]
  cmp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/talos-sops.placeholder"
}

@test "cluster-age-key leaves a talos/.sops.yaml naming another recipient alone" {
  age-keygen -o "$BATS_TEST_TMPDIR/keys/other.agekey" 2> /dev/null
  other=$(age-keygen -y "$BATS_TEST_TMPDIR/keys/other.agekey")
  RECIPIENT=$other yq -i '.creation_rules[].age = strenv(RECIPIENT)' "$REPO/talos/.sops.yaml"
  cp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"

  recipe cluster-age-key

  [ "$status" -ne 0 ]
  [[ $output == *"talos/.sops.yaml names another recipient"* ]]
  cmp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"
  [ ! -e "$KEY" ]

  # A key of its own at SOPS_AGE_KEY_FILE does not replace the recipient either.
  age-keygen -o "$KEY" 2> /dev/null
  cp "$KEY" "$BATS_TEST_TMPDIR/key.before"

  recipe cluster-age-key

  [ "$status" -ne 0 ]
  [[ $output == *"talos/.sops.yaml names another recipient"* ]]
  cmp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"
  cmp "$KEY" "$BATS_TEST_TMPDIR/key.before"
}

@test "Cluster secrets are written encrypted and never regenerated" {
  record talman talosctl sops age-keygen
  recipe cluster-age-key
  [ "$status" -eq 0 ]
  recipient=$output

  recipe cluster-secrets

  [ "$status" -eq 0 ]
  [ "$(sops filestatus "$BUNDLE")" = '{"encrypted":true}' ]
  [ "$(yq '.sops.age[].recipient' "$BUNDLE")" = "$recipient" ]
  [ "$(yq 'del(.sops) | [.. | select(kind == "scalar")] | length' "$BUNDLE")" -gt 0 ]
  [ "$(yq 'del(.sops) | [.. | select(kind == "scalar") | select(test("^ENC\\[") | not)] | length' "$BUNDLE")" -eq 0 ]
  SOPS_AGE_KEY_FILE="$KEY" sops decrypt "$BUNDLE" > /dev/null
  cp "$BUNDLE" "$BATS_TEST_TMPDIR/bundle.before"
  : > "$RECORD/argv"

  recipe cluster-secrets

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/secrets.sops.yaml exists"* ]]
  cmp "$BUNDLE" "$BATS_TEST_TMPDIR/bundle.before"
  run grep -c '^talman ' "$RECORD/argv"
  [ "$output" -eq 0 ]
}

@test "cluster-secrets names what it needs before it calls talman" {
  record talman
  rm "$CLUSTER/talman.yaml"

  recipe cluster-secrets

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/talman.yaml does not exist"* ]]
  [[ $output == *"talos/.sops.yaml holds no age recipient yet"* ]]
  [ ! -e "$RECORD/argv" ]
  [ ! -e "$BUNDLE" ]
}

@test "Secrets written in plaintext fail the recipe and are kept" {
  recipe cluster-age-key
  [ "$status" -eq 0 ]
  plaintext_talman

  recipe cluster-secrets

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/secrets.sops.yaml is not encrypted"* ]]
  [ -s "$BUNDLE" ]
  [ "$(sops filestatus "$BUNDLE")" = '{"encrypted":false}' ]
  while IFS= read -r value; do
    [[ $output != *"$value"* ]]
  done < <(bundle_values "$BUNDLE")
}

@test "A plaintext secrets bundle fails the check" {
  git_repository
  mkdir -p "$REPO/talos/other"
  talman -c "$CLUSTER" secrets generate --plaintext > /dev/null
  cp "$BUNDLE" "$REPO/talos/other/secrets.sops.yaml"
  git -C "$REPO" add talos/other/secrets.sops.yaml

  recipe cluster-secrets-check

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/secrets.sops.yaml is not SOPS-encrypted"* ]]
  [[ $output == *"talos/other/secrets.sops.yaml is not SOPS-encrypted"* ]]
  while IFS= read -r value; do
    [[ $output != *"$value"* ]]
  done < <(bundle_values "$BUNDLE")

  # The same bundle encrypted passes.
  git -C "$REPO" rm -q --cached talos/other/secrets.sops.yaml
  rm -r "$REPO/talos/other" "$BUNDLE"
  recipe cluster-age-key
  [ "$status" -eq 0 ]
  recipe cluster-secrets
  [ "$status" -eq 0 ]

  recipe cluster-secrets-check

  [ "$status" -eq 0 ]
}

@test "the secrets bundle check fails on a bundle with a plaintext value or without SOPS metadata" {
  git_repository
  recipe cluster-age-key
  recipe cluster-secrets
  [ "$status" -eq 0 ]
  cp "$BUNDLE" "$BATS_TEST_TMPDIR/encrypted.yaml"
  yq -i '.cluster.id = "marker-plaintext-value"' "$BUNDLE"

  recipe cluster-secrets-check

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/secrets.sops.yaml is not SOPS-encrypted"* ]]
  [[ $output != *marker-plaintext-value* ]]

  yq 'del(.sops)' "$BATS_TEST_TMPDIR/encrypted.yaml" > "$BUNDLE"

  recipe cluster-secrets-check

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/secrets.sops.yaml is not SOPS-encrypted"* ]]
}

@test "the cluster recipes refuse Go's HTTP/2 debug log" {
  fake_cluster
  rm "$KEY"
  record age-keygen
  with GODEBUG=x509sha1=1,http2debug=2

  for name in cluster-age-key cluster-secrets cluster-bootstrap cluster-kubeconfig cluster-talos \
    cluster-upgrade cluster-upgrade-k8s; do
    recipe "$name"

    [ "$status" -ne 0 ]
    [[ $output == *"GODEBUG sets http2debug"* ]]
  done
  [ ! -e "$RECORD/argv" ]
  [ ! -e "$KEY" ]
}

@test "the secrets bundle is committable and the cluster's generated files are not" {
  cd "$ROOT"

  run git check-ignore --no-index -q talos/lab-sto2/secrets.sops.yaml
  [ "$status" -eq 1 ]
  for path in talos/lab-sto2/talman.yaml talos/lab-sto2/clusterconfig/kubeconfig talos/lab-sto2/clusterconfig/talosconfig; do
    git check-ignore --no-index -q "$path"
  done
}

@test "Bootstrap refuses without its preconditions" {
  fake_cluster
  # Each case takes one precondition away, or all of them, and collects the messages it expects.
  for case in talman secrets age-key api-address all wait; do
    echo "$case"
    reset_environment
    cluster_files
    cp "$BATS_FILE_TMPDIR/talman.yaml" "$CLUSTER/talman.yaml"
    rm -f "$RECORD/argv"
    messages=()
    if [[ $case == talman || $case == all ]]; then
      rm "$CLUSTER/talman.yaml"
      messages+=("talos/lab-sto2/talman.yaml does not exist")
    fi
    if [[ $case == secrets || $case == all ]]; then
      rm "$BUNDLE"
      messages+=("talos/lab-sto2/secrets.sops.yaml does not exist")
    fi
    if [[ $case == age-key || $case == all ]]; then
      without SOPS_AGE_KEY_FILE
      messages+=("neither SOPS_AGE_KEY_FILE nor SOPS_AGE_KEY is set")
    fi
    if [[ $case == api-address || $case == all ]]; then
      without KUBE_API_ADDRESS
      if [[ -f $CLUSTER/talman.yaml ]]; then
        yq -i 'del(.values.apiAddress)' "$CLUSTER/talman.yaml"
      fi
      messages+=("KUBE_API_ADDRESS is not set, and talos/lab-sto2/talman.yaml gives no values.apiAddress")
    fi
    if [[ $case == wait ]]; then
      with TALOS_WAIT=soon
      messages+=("TALOS_WAIT is not a whole number of seconds")
    fi

    recipe cluster-bootstrap

    [ "$status" -ne 0 ]
    for message in "${messages[@]}"; do
      [[ $output == *"$message"* ]]
    done
    [ ! -e "$RECORD/argv" ]
  done
}

@test "Bootstrap waits for every node and names the ones that do not answer" {
  fake_cluster
  slow=$(node_address cp-2)
  echo 3 > "$STATE/answers-on.$slow"

  recipe cluster-bootstrap

  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/tries.$slow")" -eq 3 ]
  for hostname in $(yq '.nodes[].hostname' "$CLUSTER/talman.yaml"); do
    [ -e "$STATE/tries.$(node_address "$hostname")" ]
  done
  answered=$(grep -n "^timeout .*/dev/tcp/.* $slow\$" "$RECORD/argv" | tail -1 | cut -d: -f1)
  [ "$answered" -lt "$(call_line '^talman ')" ]

  rm -f "$STATE"/* "$RECORD/argv"
  : > "$STATE/silent.$(node_address cp-3)"
  : > "$STATE/silent.$(node_address worker-2)"
  with TALOS_WAIT=0

  recipe cluster-bootstrap

  [ "$status" -ne 0 ]
  silent=$(grep 'no answer on the Talos API port' <<< "$output")
  [[ $silent == *cp-3* && $silent == *worker-2* ]]
  for hostname in cp-1 cp-2 worker-1 worker-3; do
    [[ $silent != *"$hostname"* ]]
  done
  for hostname in $(yq '.nodes[].hostname' "$CLUSTER/talman.yaml"); do
    [[ $output != *"$(node_address "$hostname")"* ]]
  done
  [ -z "$(call_line '^talman ')" ]
}

@test "Bootstrap applies, fetches the kubeconfig and installs Cilium in that order" {
  fake_cluster

  recipe cluster-bootstrap

  [ "$status" -eq 0 ]
  probed=$(grep -n '^timeout .*/dev/tcp/' "$RECORD/argv" | tail -1 | cut -d: -f1)
  applied=$(call_line '^talman apply ')
  fetched=$(call_line '^talman kubeconfig')
  installed=$(call_line '^install-cilium ')
  ready=$(call_line '^kubectl wait ')
  for call in "$probed" "$applied" "$fetched" "$installed" "$ready"; do
    [ -n "$call" ]
  done
  [ "$probed" -lt "$applied" ]
  [ "$applied" -lt "$fetched" ]
  [ "$fetched" -lt "$installed" ]
  [ "$installed" -lt "$ready" ]
  apply=$(calls '^talman apply( |$)')
  [ "$(wc -l <<< "$apply")" -eq 1 ]
  [[ " $apply " == *" --bootstrap "* && " $apply " == *" --onboard-new-nodes "* ]]
  [ "$(grep -c health "$RECORD/argv")" -eq 0 ]
  [ "$(grep -c '^talosctl ' "$RECORD/argv")" -eq 0 ]
  [ "$(grep '^install-cilium ' "$RECORD/argv")" = "install-cilium KUBECONFIG=$CLUSTER/clusterconfig/kubeconfig" ]
  wait=$(grep '^kubectl wait ' "$RECORD/argv")
  [[ " $wait " == *" --for=condition=Ready "* ]]
  for hostname in $(yq '.nodes[].hostname' "$CLUSTER/talman.yaml"); do
    [[ " $wait " == *" node/$hostname "* ]]
  done
  [[ $output != *"not implemented"* ]]

  : > "$RECORD/argv"

  recipe cluster-bootstrap

  [ "$status" -ne 0 ]
  [[ $output == *"failed while bootstrapping"* ]]
  [ -n "$(call_line '^talman apply .*--bootstrap')" ]
  [ -z "$(call_line '^(talman kubeconfig|install-cilium|cluster-config|install-app|kubectl)')" ]
}

@test "The kubeconfig is private and points at the API address from the environment" {
  fake_cluster
  record yq
  kubeconfig="$CLUSTER/clusterconfig/kubeconfig"

  recipe cluster-kubeconfig

  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "$kubeconfig" ]
  [ "$(stat -c %a "$kubeconfig")" = 600 ]
  [ "$(yq '[.clusters[].cluster.server] | unique | join(" ")' "$kubeconfig")" = "https://$KUBE_API_ADDRESS:6443" ]
  [ "$(yq '.users[0].user["client-key-data"]' "$kubeconfig")" = marker-client-key-data ]
  [[ $output != *marker-* ]]
  [[ $output != *"$KUBE_API_ADDRESS"* ]]
  absent "$KUBE_API_ADDRESS" "$RECORD/argv"

  # A second run fetches it again, with the same result.
  recipe cluster-kubeconfig

  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$kubeconfig")" = 600 ]
  [ "$(yq '.clusters[0].cluster.server' "$kubeconfig")" = "https://$KUBE_API_ADDRESS:6443" ]
}

@test "Without KUBE_API_ADDRESS the recipes reach the API at the address in talman.yaml" {
  fake_cluster
  record yq
  kubeconfig="$CLUSTER/clusterconfig/kubeconfig"
  address=$(yq '.values.apiAddress' "$CLUSTER/talman.yaml")
  [[ $address =~ ^[0-9]+(\.[0-9]+){3}$ ]]
  [ "$address" != "$KUBE_API_ADDRESS" ]
  without KUBE_API_ADDRESS

  recipe cluster-kubeconfig

  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "$kubeconfig" ]
  [ "$(yq '[.clusters[].cluster.server] | unique | join(" ")' "$kubeconfig")" = "https://$address:6443" ]
  [[ $output != *"$address"* ]]
  absent "$address" "$RECORD/argv"

  # KUBE_API_ADDRESS in the environment wins over talman.yaml.
  reset_environment

  recipe cluster-kubeconfig

  [ "$status" -eq 0 ]
  [ "$(yq '[.clusters[].cluster.server] | unique | join(" ")' "$kubeconfig")" = "https://$KUBE_API_ADDRESS:6443" ]
  [[ $output != *"$KUBE_API_ADDRESS"* ]]
}

@test "cluster-kubeconfig refuses an API address it cannot put in a URL, without printing it" {
  fake_cluster
  without KUBE_API_ADDRESS
  with 'KUBE_API_ADDRESS=https://marker-not-an-address:6443'

  recipe cluster-kubeconfig

  [ "$status" -ne 0 ]
  [[ $output == *"KUBE_API_ADDRESS is not an IPv4 address"* ]]
  [[ $output != *marker-not-an-address* ]]
  [ ! -e "$RECORD/argv" ]
}

@test "A configuration rollout shows the change and asks before applying" {
  fake_cluster
  : > "$STATE/changes"

  recipe cluster-talos <<< "no"

  [ "$status" -ne 0 ]
  [[ $output == *"Config diff:"* && $output == *"[redacted]"* ]]
  [[ $output != *marker-machine-token* ]]
  [[ $output == *"lab-sto2 was not confirmed"* ]]
  [ "$(calls '^talman apply( |$)' | wc -l)" -eq 1 ]
  [ -n "$(call_line '^talman apply .*--dry-run')" ]
  [ -e "$STATE/changes" ]
  probed=$(grep -n '^timeout .*/dev/tcp/' "$RECORD/argv" | tail -1 | cut -d: -f1)
  [ -n "$probed" ]
  [ "$probed" -lt "$(call_line '^talman ')" ]

  : > "$RECORD/argv"
  recipe cluster-talos lab-sto2 <<< "lab-sto2"

  [ "$status" -eq 0 ]
  [ "$(applies | wc -l)" -eq 1 ]
  [[ " $(applies) " != *" --health "* ]]
  [ "$(call_line '^talman apply .*--dry-run')" -lt "$(call_line "^$(applies)\$")" ]
  [ ! -e "$STATE/changes" ]

  : > "$STATE/changes"
  : > "$RECORD/argv"
  recipe cluster-talos --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output != *"Type lab-sto2"* ]]
  [ "$(applies | wc -l)" -eq 1 ]

  # Nothing changes: nothing is asked or applied.
  : > "$RECORD/argv"
  recipe cluster-talos < /dev/null

  [ "$status" -eq 0 ]
  [[ $output != *"Type lab-sto2"* ]]
  [ "$(applies | wc -l)" -eq 0 ]
}

@test "New nodes are onboarded only when asked" {
  fake_cluster
  echo worker-3 > "$STATE/new-nodes"
  : > "$STATE/changes"

  recipe cluster-talos --yes < /dev/null

  [ "$status" -ne 0 ]
  [ "$(grep -c -- '--onboard-new-nodes' "$RECORD/argv")" -eq 0 ]
  [ "$(cat "$STATE/new-nodes")" = worker-3 ]

  : > "$RECORD/argv"
  recipe cluster-talos --onboard --yes < /dev/null

  [ "$status" -eq 0 ]
  [ "$(calls '^talman apply( |$)' | wc -l)" -eq 2 ]
  [ "$(calls '^talman apply( |$)' | grep -vc -- ' --onboard-new-nodes')" -eq 0 ]
  [ ! -s "$STATE/new-nodes" ]
}

@test "A rollout that changes etcd's arguments says which control planes need a reboot" {
  fake_cluster
  printf '%s\n' cp-1 cp-2 worker-2 > "$STATE/pending"
  : > "$STATE/etcd.cp-1"
  : > "$STATE/etcd.cp-2"
  : > "$STATE/network.worker-2"

  recipe cluster-talos --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"cp-1 runs etcd as it was started until it reboots"* ]]
  [[ $output == *"cp-2 runs etcd as it was started until it reboots"* ]]
  [[ $output == *"just cluster-reboot cp-1"* && $output == *"just cluster-reboot cp-2"* ]]
  [[ $output == *"one at a time"* ]]
  # The node whose change applies at once is not named, and nothing is rebooted unasked.
  [[ $output != *"worker-2 runs"* && $output != *"cluster-reboot worker-2"* ]]
  [ -z "$(calls '^cluster-reboot ')" ]
  # What is said comes after the configuration is kept, and names no address.
  applied=$(grep -n 'Applied configuration' <<< "$output" | tail -1 | cut -d: -f1)
  said=$(grep -n 'until it reboots' <<< "$output" | head -1 | cut -d: -f1)
  [ -n "$applied" ]
  [ -n "$said" ]
  [ "$applied" -lt "$said" ]
  said_lines=$(grep -E 'until it reboots|cluster-reboot' <<< "$output")
  [ -n "$said_lines" ]
  if grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' <<< "$said_lines"; then false; fi

  # The same through --first, which keeps each node as it is checked.
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"
  printf '%s\n' cp-1 cp-2 worker-2 > "$STATE/pending"
  : > "$RECORD/argv"

  recipe cluster-talos --first worker-2 --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"cp-1 runs etcd as it was started until it reboots"* ]]
  [[ $output == *"cp-2 runs etcd as it was started until it reboots"* ]]
  [[ $output != *"worker-2 runs"* ]]
  [ -z "$(calls '^cluster-reboot ')" ]
  applied=$(grep -n 'Applied configuration' <<< "$output" | tail -1 | cut -d: -f1)
  said=$(grep -n 'until it reboots' <<< "$output" | head -1 | cut -d: -f1)
  [ -n "$applied" ]
  [ -n "$said" ]
  [ "$applied" -lt "$said" ]
}

@test "A rollout that changes only what applies at once says nothing about a reboot" {
  fake_cluster
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"
  printf '%s\n' cp-1 worker-2 > "$STATE/pending"
  : > "$STATE/network.cp-1"
  : > "$STATE/network.worker-2"

  recipe cluster-talos --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"the configuration of lab-sto2 is applied"* ]]
  [[ $output != *"until it reboots"* && $output != *"cluster-reboot"* ]]

  # --reboot reboots nothing when no change needs it.
  printf '%s\n' cp-1 > "$STATE/pending"
  recipe cluster-talos --yes --reboot < /dev/null

  [ "$status" -eq 0 ]
  [[ $output != *"until it reboots"* ]]
  [ -z "$(calls '^cluster-reboot ')" ]
}

@test "With --reboot, the nodes that need one are rebooted one at a time, and the first that does not come back stops the rest" {
  fake_cluster
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"
  printf '%s\n' cp-1 cp-2 cp-3 worker-2 > "$STATE/pending"
  : > "$STATE/etcd.cp-1"
  : > "$STATE/etcd.cp-2"
  : > "$STATE/etcd.cp-3"
  : > "$STATE/network.worker-2"

  recipe cluster-talos --yes --reboot < /dev/null

  [ "$status" -eq 0 ]
  # Only the control planes the change needs it for, each through cluster-reboot, which asks nothing
  # more, one after the other and after the configuration is kept.
  [ "$(calls '^cluster-reboot ' | paste -sd'|')" = "cluster-reboot cp-1 lab-sto2 --yes|cluster-reboot cp-2 lab-sto2 --yes|cluster-reboot cp-3 lab-sto2 --yes" ]
  [ "$(paste -sd' ' "$RECORD/reboots")" = "start cp-1 end cp-1 start cp-2 end cp-2 start cp-3 end cp-3" ]
  [ "$(call_line "^$(applies | head -1)\$")" -lt "$(call_line '^cluster-reboot cp-1 ')" ]
  [[ $output == *"cp-1 is rebooted"* && $output == *"cp-3 is rebooted"* ]]
  [[ $output != *"until it reboots"* ]]
  # Before anything is applied it names the nodes it may reboot: each the dry run shows a change on.
  announced=$(grep -nxF 'cluster-talos: once every node keeps the configuration, those of cp-1, cp-2, cp-3, worker-2 that then run a setting only a reboot takes up are rebooted, one at a time' <<< "$output" | cut -d: -f1)
  applied=$(grep -n 'Applied configuration without a reboot$' <<< "$output" | head -1 | cut -d: -f1)
  [ -n "$announced" ]
  [ -n "$applied" ]
  [ "$announced" -lt "$applied" ]

  # A reboot is not the default: the operator says so with --reboot.
  : > "$RECORD/argv"
  : > "$RECORD/reboots"
  printf '%s\n' cp-1 cp-2 cp-3 > "$STATE/pending"
  recipe cluster-talos --yes < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$(calls '^cluster-reboot ')" ]

  # The first that does not come back stops the rest.
  : > "$RECORD/argv"
  : > "$RECORD/reboots"
  printf '%s\n' cp-1 cp-2 cp-3 > "$STATE/pending"
  : > "$STATE/reboot-fails.cp-2"
  recipe cluster-talos --yes --reboot < /dev/null

  [ "$status" -ne 0 ]
  [ "$(calls '^cluster-reboot ' | awk '{ print $2 }' | paste -sd' ')" = "cp-1 cp-2" ]
  [[ $output == *"cp-2 did not come back"* ]]
  [[ $output == *"not rebooted: cp-3"* ]]

  # A control plane that is Ready again while its etcd member is not back did not come back either:
  # with scripts/cluster-reboot itself rebooting cp-1, whose member is healthy before the reboot and
  # reports no leader once cp-1 is Ready again, cp-2 and cp-3 are not rebooted. The waits are real
  # ones.
  cp "$ROOT/scripts/cluster-reboot" "$REPO/scripts/cluster-reboot"
  fake sleep <<'EOF'
exec "$(command -v -p sleep)" "$@"
EOF
  rm "$STATE/reboot-fails.cp-2"
  : > "$STATE/etcd-lost.cp-1"
  : > "$RECORD/argv"
  printf '%s\n' cp-1 cp-2 cp-3 > "$STATE/pending"
  with REBOOT_WAIT=1
  recipe cluster-talos --yes --reboot < /dev/null

  [ "$status" -ne 0 ]
  [ "$(calls '^talman reboot ' | paste -sd'|')" = 'talman reboot -n cp-1 --yes --extra-flags=--drain=false' ]
  [[ $output == *"cp-1 is Ready again, but etcd was not whole within 1s"* ]]
  [[ $output == *"cp-1 did not come back"* && $output == *"not rebooted: cp-2, cp-3"* ]]
}

@test "cluster-talos names a node by what its configuration changes, not by the lines around the change" {
  fake_cluster
  # cp-2's change is the scheduler's, in a hunk that shows etcd's arguments as context; cp-3's is a
  # kernel module added, which Talos loads at once; worker-1's is a NetworkRuleConfig.
  printf '%s\n' cp-2 cp-3 worker-1 > "$STATE/pending"
  : > "$STATE/etcd-args.cp-2"
  : > "$STATE/scheduler.cp-2"
  : > "$STATE/module-add.cp-3"

  recipe cluster-talos --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"+      scheduler:"* ]]
  [[ $output != *"until it reboots"* && $output != *"cluster-reboot"* ]]

  # What a node does not take up until a reboot, besides etcd's arguments: etcd's listen subnets,
  # and a kernel module removed or given other parameters, on a control plane as on a worker; none of
  # them shows as such in a diff.
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"
  printf '%s\n' cp-1 cp-2 cp-3 worker-1 worker-2 > "$STATE/pending"
  rm "$STATE/scheduler.cp-2" "$STATE/module-add.cp-3"
  : > "$STATE/module-remove.cp-1"
  : > "$STATE/etcd-subnets.cp-2"
  : > "$STATE/module-params.cp-3"
  : > "$STATE/module-remove.worker-1"
  : > "$STATE/network.worker-2"

  recipe cluster-talos --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"cp-1 runs its kernel modules as they were loaded until it reboots"* ]]
  [[ $output == *"cp-2 runs etcd as it was started until it reboots"* ]]
  [[ $output == *"cp-3 runs its kernel modules as they were loaded until it reboots"* ]]
  [[ $output == *"worker-1 runs its kernel modules as they were loaded until it reboots"* ]]
  [[ $output != *"cp-1 runs etcd"* && $output != *"cp-2 runs its kernel"* && $output != *"worker-2 runs"* ]]
  # A worker runs no etcd, so its etcd configuration is not asked for; nothing asked holds a secret.
  [ -z "$(calls '^talman talosctl -n worker-[0-9]+ get EtcdConfigs')" ]
  [ -n "$(calls '^talman talosctl -n cp-2 get EtcdConfigs.etcd.talos.dev etcd --output json$')" ]
  [ -n "$(calls '^talman talosctl -n worker-1 get KernelModuleSpecs.runtime.talos.dev --output json$')" ]
  [ -z "$(calls 'machineconfig')" ]
}

@test "cluster-talos says when it cannot tell whether a changed node needs a reboot" {
  fake_cluster
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"
  printf '%s\n' cp-1 cp-2 cp-3 > "$STATE/pending"
  : > "$STATE/etcd.cp-1"
  : > "$STATE/etcd.cp-2"
  : > "$STATE/etcd.cp-3"
  : > "$STATE/unreadable.cp-2"
  : > "$STATE/unreadable-after.cp-3"

  recipe cluster-talos --yes --reboot < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"could not read cp-2's settings that take effect only at a reboot from its Talos API before the configuration was applied, so it is not said whether it needs a reboot"* ]]
  [[ $output == *"could not read cp-3's settings that take effect only at a reboot from its Talos API after the configuration was applied, so it is not said whether it needs a reboot"* ]]
  [[ $output != *"198.51.100.12"* ]]
  # Only the node known to need one is rebooted; the others are named for the operator to look at.
  [ "$(calls '^cluster-reboot ' | paste -sd'|')" = "cluster-reboot cp-1 lab-sto2 --yes" ]
}

@test "cluster-talos says when it cannot tell from talman's dry run which nodes change, and then reboots nothing" {
  fake_cluster
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"
  printf '%s\n' cp-1 cp-2 > "$STATE/pending"
  : > "$STATE/etcd.cp-1"
  : > "$STATE/etcd.cp-2"
  : > "$STATE/header-drift"

  recipe cluster-talos --yes < /dev/null

  # The configuration is applied as asked; whether a node needs a reboot is left open, and said so.
  [ "$status" -eq 0 ]
  [[ $output == *"cannot tell from talman's dry run which nodes the configuration changes, so it cannot say whether any needs a reboot"* ]]
  [ -n "$(applies)" ]
  [[ $output != *"until it reboots"* ]]

  # With --reboot it does not go on to reboot blind: nothing is applied or rebooted.
  printf '%s\n' cp-1 cp-2 > "$STATE/pending"
  : > "$RECORD/argv"

  recipe cluster-talos --yes --reboot < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"cannot tell from talman's dry run which nodes the configuration changes"* ]]
  [[ $output == *"nothing is applied; without --reboot the configuration is applied and the nodes are not rebooted"* ]]
  [ -z "$(applies)" ]
  [ -z "$(calls '^cluster-reboot ')" ]

  # A dry run whose only change is a new node to onboard reads as such.
  rm "$STATE/header-drift" "$STATE/pending"
  echo worker-3 > "$STATE/new-nodes"

  recipe cluster-talos --onboard --yes --reboot < /dev/null

  [ "$status" -eq 0 ]
  [[ $output != *"cannot tell"* ]]
}

@test "cluster-talos compares a changed node whose diff talman does not show" {
  fake_cluster
  printf '%s\n' cp-1 cp-2 > "$STATE/pending"
  : > "$STATE/etcd.cp-1"
  : > "$STATE/network.cp-2"
  : > "$STATE/withheld"

  recipe cluster-talos --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"changes; diff not shown"* ]]
  [[ $output == *"cp-1 runs etcd as it was started until it reboots"* ]]
  [[ $output != *"cp-2 runs"* ]]
}

@test "cluster-talos names the nodes that took a change needing a reboot when talman apply stops partway" {
  fake_cluster
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"
  printf '%s\n' cp-1 cp-2 cp-3 > "$STATE/pending"
  : > "$STATE/etcd.cp-1"
  : > "$STATE/etcd.cp-2"
  : > "$STATE/etcd.cp-3"
  : > "$STATE/apply-fails.cp-2"

  recipe cluster-talos --yes --reboot < /dev/null

  # cp-1 took the configuration before talman stopped at cp-2; a later run finds nothing to change
  # on cp-1, so this one says what it runs. Nothing of a rollout that is not done is rebooted.
  [ "$status" -ne 0 ]
  [[ $output == *"failed while applying the configuration"* ]]
  [[ $output == *"cp-1 runs etcd as it was started until it reboots; reboot it with: just cluster-reboot cp-1"* ]]
  [[ $output != *"cp-2 runs"* && $output != *"cp-3 runs"* ]]
  [ -z "$(calls '^cluster-reboot ')" ]
}

@test "cluster-talos --first --reboot reboots only once every node keeps the configuration" {
  fake_cluster
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"
  printf '%s\n' cp-1 cp-2 worker-2 > "$STATE/pending"
  : > "$STATE/etcd.cp-1"
  : > "$STATE/etcd.cp-2"
  : > "$STATE/network.worker-2"

  recipe cluster-talos --first worker-2 --yes --reboot --tolerate 30 < /dev/null

  [ "$status" -eq 0 ]
  # A reboot between a node's try and its keep would revert what the checks saw.
  [ "$(calls '^cluster-reboot ' | paste -sd'|')" = "cluster-reboot cp-1 lab-sto2 --yes --tolerate 30|cluster-reboot cp-2 lab-sto2 --yes --tolerate 30" ]
  last_keep=$(last_call_line "^$(keeps cp-2 | tail -1)\$")
  [ -n "$last_keep" ]
  [ "$last_keep" -lt "$(call_line '^cluster-reboot cp-1 ')" ]
  [ "$last_keep" -gt "$(last_call_line "^$(keeps worker-2 | tail -1)\$")" ]

  # --tolerate is for the reboots.
  recipe cluster-talos --yes --tolerate 30 < /dev/null
  [ "$status" -eq 2 ]
}

@test "cluster-talos --first names the kept nodes that need a reboot when it stops before the rest" {
  fake_cluster
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"
  printf '%s\n' cp-1 cp-2 > "$STATE/pending"
  : > "$STATE/etcd.cp-1"
  : > "$STATE/etcd.cp-2"
  : > "$STATE/unreachable.cp-2"

  recipe cluster-talos --first cp-1 --yes --reboot < /dev/null

  # A later run finds nothing to change on cp-1, so this one says what it runs; nothing is rebooted
  # of a rollout that is not done.
  [ "$status" -ne 0 ]
  [[ $output == *"kept before it: cp-1"* ]]
  [[ $output == *"cp-1 runs etcd as it was started until it reboots; reboot it with: just cluster-reboot cp-1"* ]]
  [[ $output != *"cp-2 runs"* ]]
  [ -z "$(calls '^cluster-reboot ')" ]
}

@test "cluster-talos with CI set finds the nodes that need a reboot from talman's log, and prints no address" {
  fake_cluster
  with CI=true
  printf '%s\n' cp-1 cp-2 worker-2 > "$STATE/pending"
  : > "$STATE/etcd.cp-1"
  : > "$STATE/etcd.cp-2"
  : > "$STATE/network.worker-2"

  recipe cluster-talos --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"cp-1 runs etcd as it was started until it reboots"* ]]
  [[ $output == *"cp-2 runs etcd as it was started until it reboots"* ]]
  [[ $output != *"worker-2 runs"* ]]
  if grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' <<< "$output"; then false; fi
}

@test "no patch sets a setting that takes effect only at a reboot and that the rollout does not read back" {
  expression=$(bash -c ". '$ROOT/scripts/lib/cluster.sh' && printf '%s' \"\$reboot_unwatched\"")
  [ -n "$expression" ]
  mapfile -t patches < <(find "$ROOT/talos/patches" -name '*.yaml')
  [ "${#patches[@]}" -gt 10 ]
  found=$(yq ea "$expression" "${patches[@]}")
  echo "set by a patch: $found"
  [ -z "$found" ]

  # Each such setting, in a patch, is named.
  printf '%s\n' 'machine:' '  env:' '    HTTP_PROXY: http://proxy.example.com' > "$BATS_TEST_TMPDIR/env.yaml"
  printf '%s\n' 'apiVersion: v1alpha1' 'kind: EnvironmentConfig' 'variables:' '  HTTP_PROXY: http://proxy.example.com' > "$BATS_TEST_TMPDIR/environment.yaml"
  printf '%s\n' 'apiVersion: v1alpha1' 'kind: SecurityProfileConfig' 'workloadIsolation: true' > "$BATS_TEST_TMPDIR/sandbox.yaml"
  printf '%s\n' 'apiVersion: v1alpha1' 'kind: RawVolumeConfig' 'name: data' 'encryption:' '  provider: luks2' > "$BATS_TEST_TMPDIR/volume.yaml"
  printf '%s\n' 'machine:' '  systemDiskEncryption:' '    state:' '      provider: luks2' > "$BATS_TEST_TMPDIR/system-disk.yaml"
  for patch in env environment sandbox volume system-disk; do
    named=$(yq ea "$expression" "$BATS_TEST_TMPDIR/$patch.yaml")
    echo "$patch: $named"
    [ -n "$named" ]
  done
}

@test "the Talos documentation the reboot list cites is the minor version versions.yaml pins" {
  minor=$(yq '.talos' "$ROOT/versions.yaml" | sed -E 's/^(v[0-9]+\.[0-9]+)\..*/\1/')
  [[ $minor == v* ]]
  cited=$(grep -ho 'docs.siderolabs.com/talos/v[0-9.]*/' "$ROOT/scripts/lib/cluster.sh" "$ROOT/docs/cluster.md" | sort -u)
  [ "$cited" = "docs.siderolabs.com/talos/$minor/" ]
}

@test "a rollout whose dry run fails applies nothing and names the step" {
  fake_cluster
  : > "$STATE/changes"
  : > "$STATE/unreachable"

  recipe cluster-talos --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"cluster-talos: failed while asking each node what the configuration would change"* ]]
  [ "$(applies | wc -l)" -eq 0 ]
}

@test "cluster-talos refuses an argument it does not know before it runs anything" {
  fake_cluster

  recipe cluster-talos --force < /dev/null

  [ "$status" -eq 2 ]
  [[ $output == *"usage: cluster-talos [cluster] [--onboard] [--yes]"* ]]
  [ ! -e "$RECORD/argv" ]
}

# first_apply WORD...: the line number in the record of the first talman apply call that has every
# WORD among its arguments; nothing when there is none.
first_apply() {
  local n line word found
  while IFS=: read -r n line; do
    found=1
    for word; do
      [[ " $line " == *" $word "* ]] || found=0
    done
    if ((found)); then
      echo "$n"
      return
    fi
  done < <(grep -n '^talman apply ' "$RECORD/argv")
}

# between AFTER BEFORE PATTERN: whether the record holds a call matching the extended regex after
# line AFTER, and the first such comes before line BEFORE.
between() {
  local line
  line=$(grep -n -E -- "$3" "$RECORD/argv" | cut -d: -f1 | awk -v after="$1" '$1 > after' | head -1)
  if [[ -z $line ]] || ((line >= $2)); then
    echo "no call matching $3 between lines $1 and $2" >&2
    return 1
  fi
}

# tries NODE: the recorded applies to NODE in try mode, one per line.
tries() {
  applies | grep -E -- "(^| )-n $1( |$)" | grep -E -- ' (--mode try|-m try|--mode=try)( |$)' || true
}

# keeps NODE: the recorded applies to NODE that are not in try mode, one per line.
keeps() {
  applies | grep -E -- "(^| )-n $1( |$)" | grep -vE -- ' (--mode try|-m try|--mode=try)( |$)' || true
}

@test "The first rollout applies to one node in a self-reverting mode and stops unless the checks pass" {
  fake_cluster
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"
  printf '%s\n' cp-1 worker-2 > "$STATE/pending"

  recipe cluster-talos --first worker-2 --yes < /dev/null

  [ "$status" -eq 0 ]
  [ ! -s "$STATE/pending" ]
  [ "$(applies | wc -l)" -eq 4 ]
  [ "$(tries worker-2 | wc -l)" -eq 1 ]
  [ "$(keeps worker-2 | wc -l)" -eq 1 ]
  [ "$(tries cp-1 | wc -l)" -eq 1 ]
  [ "$(keeps cp-1 | wc -l)" -eq 1 ]
  # Talos reverts a configuration applied in try mode once the timeout talosctl is given has passed.
  [[ " $(tries worker-2) " == *" --extra-flags=--timeout="* ]]
  checked=$(call_line '^cluster-check')
  tried=$(first_apply -n worker-2 --mode try)
  [ -z "$tried" ] && tried=$(first_apply -n worker-2 -m try)
  kept_at=$(call_line "^$(keeps worker-2)\$")
  next=$(call_line "^$(tries cp-1)\$")
  for call in "$checked" "$tried" "$kept_at" "$next"; do
    [ -n "$call" ]
  done
  # The cluster is checked before anything is applied, the named node goes first and alone, and it
  # is kept only after its Talos API, every node's Talos API port and cluster-check have answered.
  [ "$checked" -lt "$tried" ]
  [ "$(applies | head -1)" = "$(tries worker-2)" ]
  [ "$tried" -lt "$kept_at" ]
  [ "$kept_at" -lt "$next" ]
  asked=$(grep -n '^talman apply ' "$RECORD/argv" | grep -E -- ' --dry-run( |$)' | grep -E -- ' -n worker-2( |$)' |
    cut -d: -f1 | awk -v after="$tried" '$1 > after' | head -1)
  [ -n "$asked" ]
  [ "$asked" -lt "$kept_at" ]
  for hostname in $(yq '.nodes[].hostname' "$CLUSTER/talman.yaml"); do
    probed=$(grep -n "^timeout .*/dev/tcp/.* $(node_address "$hostname")\$" "$RECORD/argv" | cut -d: -f1 |
      awk -v after="$tried" '$1 > after' | head -1)
    [ -n "$probed" ]
    [ "$probed" -lt "$kept_at" ]
  done
  # The paths into the tried node from another: the API server on another control plane reaches its
  # kubelet and its node-exporter, as a pod there would, and the Cilium agents on it and on another
  # node probe each other through the overlay and on the health port.
  via="https://$(node_address cp-1):6443"
  between "$tried" "$kept_at" "^kubectl --server $via get --raw /api/v1/nodes/worker-2/proxy/healthz "
  between "$tried" "$kept_at" "^kubectl --server $via get --raw /api/v1/nodes/http:worker-2:9100/proxy/metrics "
  between "$tried" "$kept_at" '^kubectl .* exec cilium-worker-2 .*-- cilium-health status --probe --output json'
  between "$tried" "$kept_at" '^kubectl .* exec cilium-cp-1 .*-- cilium-health status --probe --output json'
  # Long enough after the try that a kubelet that cannot report has made the node not Ready, and only
  # then the node's readiness and the cluster.
  waited=$(grep -n -E '^sleep [0-9]+$' "$RECORD/argv" | awk -F: -v after="$tried" '$1 > after { print $1 ":" $2; exit }')
  [ -n "$waited" ]
  [ "${waited#*:sleep }" -ge 65 ]
  between "${waited%%:*}" "$kept_at" '^kubectl get node worker-2 --output json'
  between "${waited%%:*}" "$kept_at" '^cluster-check'
  # A worker has no etcd member to ask.
  [ -z "$(sed -n "${tried},${kept_at}p" "$RECORD/argv" | awk '/^talman talosctl/')" ]
  # A control plane's etcd member, as it and another control plane see it.
  tried_cp=$(call_line "^$(tries cp-1)\$")
  kept_cp=$(call_line "^$(keeps cp-1)\$")
  between "$tried_cp" "$kept_cp" '^talman talosctl -n cp-1 -n cp-2 etcd status$'
  between "$tried_cp" "$kept_cp" '^talman talosctl -n cp-2 etcd members$'
  between "$tried_cp" "$kept_cp" "^kubectl --server https://$(node_address cp-2):6443 get --raw /api/v1/nodes/cp-1/proxy/healthz "
  # A control plane's own Kubernetes API, at its own address, and a fresh request through the load
  # balancer that lands on it, told apart by its API server's start time.
  between "$tried_cp" "$kept_cp" "^kubectl --server https://$(node_address cp-1):6443 get --raw /readyz "
  between "$tried_cp" "$kept_cp" "^kubectl --server https://$(node_address cp-1):6443 get --raw /metrics "
  between "$tried_cp" "$kept_cp" '^kubectl get --raw /metrics '
  # A worker has no API server to ask.
  [ -z "$(sed -n "${tried},${kept_at}p" "$RECORD/argv" | awk '/ get --raw \/(readyz|metrics) /')" ]

  # Each check stops the rollout when it fails: the tried node is not kept and nothing follows it.
  for failing in kubelet-cut.worker-2 exporter-cut.worker-2 overlay-cut.worker-2 overlay-cut.cp-1 \
    health-cut.worker-2 notready.worker-2 "silent-tried.$(node_address worker-3)" unhealthy-tried slow-check \
    reverts-late.worker-2; do
    rm -f "$STATE"/* "$RECORD/argv"
    printf '%s\n' cp-1 worker-2 > "$STATE/pending"
    if [[ $failing == slow-check ]]; then
      # The checks run past the try timeout less the margin kept before Talos reverts the node.
      echo 300 > "$STATE/slow-check"
    else
      : > "$STATE/$failing"
    fi

    recipe cluster-talos --first worker-2 --yes < /dev/null

    echo "$failing: $status"
    [ "$status" -ne 0 ]
    [ "$(applies)" = "$(tries worker-2)" ]
    [[ $output == *"worker-2 is not kept"* ]]
  done
  for failing in api-cut.cp-1 lb-cut.cp-1 etcd-old-table; do
    rm -f "$STATE"/* "$RECORD/argv"
    printf '%s\n' cp-1 worker-2 > "$STATE/pending"
    : > "$STATE/$failing"

    recipe cluster-talos --first cp-1 --yes < /dev/null

    echo "$failing: $status"
    [ "$status" -ne 0 ]
    [ "$(applies)" = "$(tries cp-1)" ]
    [[ $output == *"cp-1 is not kept"* ]]
  done
  for failing in etcd-cut.cp-1 etcd-cut.cp-2 etcd-unlisted.cp-1; do
    rm -f "$STATE"/* "$RECORD/argv"
    printf '%s\n' cp-1 worker-2 > "$STATE/pending"
    : > "$STATE/$failing"

    recipe cluster-talos --first cp-1 --yes < /dev/null

    echo "$failing: $status"
    [ "$status" -ne 0 ]
    [ "$(applies)" = "$(tries cp-1)" ]
    [[ $output == *"cp-1's etcd member is not healthy"* ]]
  done
  # A member etcd still holds that is no control plane of talman.yaml counts toward its quorum.
  rm -f "$STATE"/* "$RECORD/argv"
  printf '%s\n' cp-1 worker-2 > "$STATE/pending"
  echo cp-old > "$STATE/etcd-extra"

  recipe cluster-talos --first cp-1 --yes < /dev/null

  [ "$status" -ne 0 ]
  [ "$(applies)" = "$(tries cp-1)" ]
  [[ $output == *"cp-1's etcd member is not healthy as cp-1 and cp-2 see it: etcd holds cp-old, no control plane of talman.yaml"* ]]
  [[ $output != *198.51.100.21* ]]
  rm -f "$STATE"/* "$RECORD/argv"

  # An unhealthy cluster gets no apply at all.
  printf '%s\n' cp-1 worker-2 > "$STATE/pending"
  : > "$STATE/unhealthy"
  : > "$RECORD/argv"

  recipe cluster-talos --first worker-2 --yes < /dev/null

  [ "$status" -ne 0 ]
  [ -n "$(call_line '^cluster-check')" ]
  [ -z "$(applies)" ]
  [ "$(cat "$STATE/pending")" = "$(printf '%s\n' cp-1 worker-2)" ]

  # A configuration that reverted before the checks ended is not kept, as the checks did not see it.
  rm "$STATE/unhealthy"
  : > "$STATE/reverts.worker-2"
  : > "$RECORD/argv"

  recipe cluster-talos --first worker-2 --yes < /dev/null

  [ "$status" -ne 0 ]
  [ "$(applies)" = "$(tries worker-2)" ]
  [ "$(tries worker-2 | wc -l)" -eq 1 ]
  [[ $output == *"worker-2 runs the configuration it had"* ]]
}

@test "A failed check after the first node leaves the other nodes untouched and says how the first reverts" {
  fake_cluster
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"
  printf '%s\n' cp-1 worker-2 > "$STATE/pending"
  : > "$STATE/unhealthy-tried"

  recipe cluster-talos --first cp-1 --yes < /dev/null

  [ "$status" -ne 0 ]
  [ "$(applies)" = "$(tries cp-1)" ]
  [ "$(tries cp-1 | wc -l)" -eq 1 ]
  tried=$(call_line "^$(tries cp-1)\$")
  [ -z "$(sed -n "$((tried + 1)),\$p" "$RECORD/argv" | awk '/^talman apply .*-n worker-2( |$)/')" ]
  [ "$(cat "$STATE/pending")" = worker-2 ]
  # The recipe's last lines, before just's own: how the node reverts, which nodes are untouched and
  # the step the rollout stopped in.
  last=$(grep -n -m1 'cluster-talos: failed while checking cp-1 and the cluster' <<< "$output" | cut -d: -f1)
  [ -n "$last" ]
  [ -z "$(sed -n "$((last + 1)),\$p" <<< "$output" | awk '!/^error: recipe .cluster-talos. failed/')" ]
  [[ $(sed -n "$((last - 2))p" <<< "$output") == *"cp-1 reverts by itself to the configuration it had 5 minutes after it was applied"* ]]
  untouched=$(sed -n "$((last - 1))p" <<< "$output")
  [[ $untouched == "cluster-talos: untouched: "* ]]
  for hostname in cp-2 cp-3 worker-1 worker-2 worker-3; do
    [[ $untouched == *"$hostname"* ]]
  done
  [[ $untouched != *cp-1* ]]
}

@test "cluster-talos --first names nodes by hostname only, and with CI set keeps talman's output in its log" {
  fake_cluster
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"
  printed=()
  for ci in '' true; do
    reset_environment
    [[ -z $ci ]] || with CI=true
    printf '%s\n' cp-1 worker-2 > "$STATE/pending"
    : > "$STATE/silent-tried.$(node_address worker-3)"
    rm -f "$STATE/tried" "$RECORD/argv"

    recipe cluster-talos --first worker-2 --yes < /dev/null

    [ "$status" -ne 0 ]
    printed+=("$output")
    [[ $output == *"no answer on the Talos API port from worker-3 once worker-2 was applied in try mode"* ]]
    [ "$(applies)" = "$(tries worker-2)" ]
  done
  [[ ${printed[1]} == *"its output is in talos/lab-sto2/clusterconfig/cluster-talos.log"* ]]
  [[ ${printed[1]} != *"Config diff:"* ]]
  for address in $(yq '.nodes[].ipAddress' "$CLUSTER/talman.yaml"); do
    [[ ${printed[1]} != *"$address"* ]]
    [[ ${printed[0]} != *"no answer on the Talos API port from $address"* ]]
  done
}

@test "cluster-talos --first says what the tool of a failed check said, its addresses masked" {
  fake_cluster
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"
  # With CI set, talman's own output, which names nodes by address, stays in its log.
  with CI=true
  for failing in exporter-cut.worker-2 kubelet-cut.worker-2 notready.worker-2; do
    rm -f "$STATE"/* "$RECORD/argv"
    printf '%s\n' cp-1 worker-2 > "$STATE/pending"
    : > "$STATE/$failing"

    recipe cluster-talos --first worker-2 --yes < /dev/null

    echo "$failing: $status"
    [ "$status" -ne 0 ]
    [ "$(applies)" = "$(tries worker-2)" ]
    case $failing in
      exporter-cut.*)
        [[ $output == *"cp-1 does not reach node-exporter on worker-2, as a pod on cp-1 would"* ]]
        [[ $output == *"kubectl said: Error from server: error dialing backend: dial tcp <address>:9100: i/o timeout"* ]]
        ;;
      kubelet-cut.*)
        [[ $output == *"the API server on cp-1 does not reach worker-2's kubelet"* ]]
        [[ $output == *"kubectl said: Error from server: error dialing backend: dial tcp [<address>]:10250: i/o timeout"* ]]
        [[ $output != *2001:db8* ]]
        ;;
      notready.*)
        # A check whose tool answered, with an answer that fails it, has nothing of the tool's to add,
        # not even a warning it printed.
        [[ $output == *"worker-2 is not Ready"* ]]
        [[ $output != *" said: "* ]]
        [[ $output != *Warning* ]]
        ;;
    esac
    for address in $(yq '.nodes[].ipAddress' "$CLUSTER/talman.yaml"); do
      [[ $output != *"$address"* ]]
    done
    # The file that held it is gone.
    [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'cluster-talos.*')" ]
  done

  rm -f "$STATE"/* "$RECORD/argv"
  printf '%s\n' cp-1 worker-2 > "$STATE/pending"
  : > "$STATE/api-cut.cp-1"

  recipe cluster-talos --first cp-1 --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"cp-1's Kubernetes API did not answer at its own address within 90s"* ]]
  [[ $output == *"kubectl said: Unable to connect to the server: dial tcp <address>:6443: i/o timeout"* ]]
  for address in $(yq '.nodes[].ipAddress' "$CLUSTER/talman.yaml"); do
    [[ $output != *"$address"* ]]
  done

  # A tool that fails without a word is named with its status.
  rm -f "$STATE"/* "$RECORD/argv"
  printf '%s\n' cp-1 worker-2 > "$STATE/pending"
  : > "$STATE/lb-cut.cp-1"
  : > "$STATE/lb-cut.cp-2"
  : > "$STATE/lb-cut.cp-3"

  recipe cluster-talos --first cp-1 --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"no fresh request through the load balancer reached cp-1's API server within 20s"* ]]
  [[ $output == *"kubectl failed with status 1 and said nothing"* ]]
}

# waited PATTERN: the seconds the recorded sleeps between the first and the last call matching the
# extended regex add up to, which is how far the fake clock moved on between them.
waited() {
  local first last
  first=$(call_line "$1")
  last=$(grep -n -E -- "$1" "$RECORD/argv" | tail -n 1 | cut -d: -f1)
  awk -v first="$first" -v last="$last" 'NR > first && NR < last && /^sleep [0-9]+$/ { total += $2 }
    END { print total + 0 }' "$RECORD/argv"
}

@test "cluster-talos --first gives a restarted API server time to become ready, and says whether it never answered or was not ready" {
  fake_cluster
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"
  # With CI set, talman's own output, which names nodes by address, stays in its log.
  with CI=true
  readyz="^kubectl --server https://$(node_address cp-1):6443 get --raw /readyz "

  # A configuration that changes the API server's own settings makes Talos restart it: a server that
  # is restarting refuses connections until it listens, then answers /readyz with an error until its
  # post-start hooks are done.
  printf '%s\n' cp-1 worker-2 > "$STATE/pending"
  echo 2 > "$STATE/api-refused.cp-1"
  echo 3 > "$STATE/starting.cp-1"

  recipe cluster-talos --first cp-1 --yes < /dev/null

  [ "$status" -eq 0 ]
  [ "$(keeps cp-1 | wc -l)" -eq 1 ]
  [ "$(calls "$readyz" | wc -l)" -eq 6 ]
  # The requests were apart in time.
  [ "$(waited "$readyz")" -ge 20 ]

  # One that never becomes ready is not kept, and the failure names the checks still failing, without
  # the rest of what the server answered or what kubectl said while it refused connections.
  rm -f "$STATE"/* "$RECORD/argv"
  printf '%s\n' cp-1 worker-2 > "$STATE/pending"
  echo 2 > "$STATE/api-refused.cp-1"
  echo 1000 > "$STATE/starting.cp-1"

  recipe cluster-talos --first cp-1 --yes < /dev/null

  [ "$status" -ne 0 ]
  [ "$(applies)" = "$(tries cp-1)" ]
  [[ $output == *"cp-1's Kubernetes API answered at its own address but was not ready within 90s; still failing: poststarthook/rbac/bootstrap-roles, poststarthook/scheduling/bootstrap-system-priority-classes"* ]]
  [[ $output != *"[+]"* && $output != *" said: "* && $output != *"did not answer"* ]]
  # It waited as long as the bound, and no longer.
  [ "$(waited "$readyz")" -ge 85 ]
  [ "$(waited "$readyz")" -le 95 ]

  # One that never answers, dropped or refused, as a firewall that cuts it off makes it, is not kept,
  # with kubectl's own line, its address masked.
  for failing in api-refused.cp-1 api-cut.cp-1; do
    rm -f "$STATE"/* "$RECORD/argv"
    printf '%s\n' cp-1 worker-2 > "$STATE/pending"
    : > "$STATE/$failing"

    recipe cluster-talos --first cp-1 --yes < /dev/null

    echo "$failing: $status"
    [ "$status" -ne 0 ]
    [ "$(applies)" = "$(tries cp-1)" ]
    [[ $output == *"cp-1's Kubernetes API did not answer at its own address within 90s"* ]]
    [[ $output != *"not ready"* ]]
    case $failing in
      api-refused.*) [[ $output == *"kubectl said: The connection to the server <address>:6443 was refused"* ]] ;;
      api-cut.*) [[ $output == *"kubectl said: Unable to connect to the server: dial tcp <address>:6443: i/o timeout"* ]] ;;
    esac
    for address in $(yq '.nodes[].ipAddress' "$CLUSTER/talman.yaml"); do
      [[ $output != *"$address"* ]]
    done
  done

  # One that stops answering at its own address once it was ready fails as that, not as the load
  # balancer's.
  rm -f "$STATE"/* "$RECORD/argv"
  printf '%s\n' cp-1 worker-2 > "$STATE/pending"
  : > "$STATE/api-gone.cp-1"

  recipe cluster-talos --first cp-1 --yes < /dev/null

  [ "$status" -ne 0 ]
  [ "$(applies)" = "$(tries cp-1)" ]
  [[ $output == *"cp-1's API server was ready at its own address, then did not answer there for its metrics"* ]]
  [[ $output == *"kubectl said: The connection to the server <address>:6443 was refused"* ]]
  [[ $output != *"load balancer"* ]]
}

@test "cluster-talos --first gives the load balancer's health monitor time to take a restarted control plane back" {
  fake_cluster
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"

  # The monitor takes a member that was down back after two successful checks five seconds apart.
  printf '%s\n' cp-1 worker-2 > "$STATE/pending"
  echo 12 > "$STATE/lb-back.cp-1"

  recipe cluster-talos --first cp-1 --yes < /dev/null

  [ "$status" -eq 0 ]
  [ "$(keeps cp-1 | wc -l)" -eq 1 ]
  [ "$(waited '^kubectl get --raw /metrics ')" -ge 12 ]

  # A member it never takes back is not kept once the bound has passed.
  rm -f "$STATE"/* "$RECORD/argv"
  printf '%s\n' cp-1 worker-2 > "$STATE/pending"
  echo 1000 > "$STATE/lb-back.cp-1"

  recipe cluster-talos --first cp-1 --yes < /dev/null

  [ "$status" -ne 0 ]
  [ "$(applies)" = "$(tries cp-1)" ]
  [[ $output == *"no fresh request through the load balancer reached cp-1's API server within 20s"* ]]
  [ "$(waited '^kubectl get --raw /metrics ')" -ge 15 ]
  [ "$(waited '^kubectl get --raw /metrics ')" -le 25 ]

  # Requests that are slow to come back end the wait by its bound too, not after a round of them.
  rm -f "$STATE"/* "$RECORD/argv"
  printf '%s\n' cp-1 worker-2 > "$STATE/pending"
  echo 1000 > "$STATE/lb-back.cp-1"
  echo 4 > "$STATE/lb-slow"

  recipe cluster-talos --first cp-1 --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"no fresh request through the load balancer reached cp-1's API server within 20s"* ]]
  # Requests start at 0, 4, 8, 12, 16 and 20 seconds, and none after.
  [ "$(calls '^kubectl get --raw /metrics ' | wc -l)" -eq 6 ]
}

@test "cluster-talos --first keeps a node only while its try window allows, however long the waits ran" {
  fake_cluster
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"
  # The API server is ready at its last chance, 90 seconds after the Ready wait, the load balancer
  # takes it back after 20 more, and cluster-check takes 70: the checks end 245 seconds after the
  # try, five past the last moment a node is kept, 60 seconds before Talos reverts it.
  printf '%s\n' cp-1 worker-2 > "$STATE/pending"
  echo 18 > "$STATE/starting.cp-1"
  echo 20 > "$STATE/lb-back.cp-1"
  echo 70 > "$STATE/slow-check"

  recipe cluster-talos --first cp-1 --yes < /dev/null

  [ "$status" -ne 0 ]
  [ "$(applies)" = "$(tries cp-1)" ]
  [[ $output == *"the checks of cp-1 ended less than 60s before Talos reverts it"* ]]
}

@test "the rollout's scripts feed no command's output to a reader that may stop before it ends" {
  # The scan sees the pipelines that failed or could fail a check, and passes those that read on.
  cat > "$BATS_TEST_TMPDIR/early.sh" <<'EOF'
get_through "$via" --raw "/api/v1/nodes/http:$node:9100/proxy/metrics" | grep -q '^node_exporter_build_info'
talman_nodes "$file" | cut -d' ' -f1 |
  grep -qxF -- "$first"
via=$(yq ".nodes[] | select(.role == \"controlplane\") | .hostname" "$file" | head -1)
kubectl get --raw /metrics | awk '$1 == "process_start_time_seconds" { print $2; exit }'
kubectl get --raw /metrics | awk -v name=x '$1 == name {
    print $2; exit
  } END { exit !found }'
kubectl get --raw /metrics | grep '^x' > /dev/null
kubectl get pods --output name | IFS= read -r pod
kubectl get pods --output json | jq -n 'first(inputs | .items[])'
kubectl get --raw /metrics | sed -n '/^x/{p;q}'
EOF
  cat > "$BATS_TEST_TMPDIR/reading-on.sh" <<'EOF'
# A comment that says | head -1 is no pipeline.
kubectl get --raw /metrics | awk '$1 == "x" && !found { value = $2; found = 1 } END { if (found) print value; exit !found }'
kubectl get node x --output json | jq -e 'any(.status.conditions[]?; .type == "Ready")' > /dev/null
failure="$node's metrics | head do not count, quoted"
grep -qxF -- "$first" <<< "$names" || echo "it's | head in a string"
printf '%s\n' "${kept[@]}" | paste -sd, - | sed 's/,/, /g'
kubectl get pods | while read -r pod; do echo "$pod"; done
EOF

  run early_readers "$BATS_TEST_TMPDIR/early.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf "$BATS_TEST_TMPDIR/early.sh:%s\n" 1 2 4 5 6 9 10 11 12)" ]
  run early_readers "$BATS_TEST_TMPDIR/reading-on.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # cluster-talos, what it sources and the cluster-check it runs.
  run early_readers "$ROOT/scripts/cluster-talos" "$ROOT/scripts/cluster-env" "$ROOT/scripts/cluster-check" \
    "$ROOT/scripts/lib/cluster.sh" "$ROOT/scripts/lib/s3.sh" "$ROOT/scripts/lib/infra.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cluster-talos --first says which nodes kept the configuration when a later node cannot say what would change" {
  fake_cluster
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"
  printf '%s\n' cp-1 worker-2 > "$STATE/pending"
  : > "$STATE/unreachable.cp-1"

  recipe cluster-talos --first worker-2 --yes < /dev/null

  [ "$status" -ne 0 ]
  [ "$(applies)" = "$(printf '%s\n' "$(tries worker-2)" "$(keeps worker-2)")" ]
  [[ $output == *"cp-1 did not say what the configuration would change, so it is not applied"* ]]
  [[ $output == *"kept before it: worker-2"* ]]
  untouched=$(grep 'cluster-talos: untouched: ' <<< "$output")
  for hostname in cp-1 cp-2 cp-3 worker-1 worker-3; do
    [[ $untouched == *"$hostname"* ]]
  done
  [[ $untouched != *worker-2* ]]
}

@test "cluster-talos --first refuses a node talman.yaml does not list, and --onboard, before it runs anything" {
  fake_cluster
  mkdir -p "$CLUSTER/clusterconfig"
  : > "$CLUSTER/clusterconfig/kubeconfig"

  recipe cluster-talos --first cp-9 --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"cp-9 is not a node of talos/lab-sto2/talman.yaml"* ]]
  [ ! -e "$RECORD/argv" ]

  recipe cluster-talos --first cp-1 --onboard --yes < /dev/null

  [ "$status" -eq 2 ]
  [[ $output == *"--first does not onboard"* ]]
  [ ! -e "$RECORD/argv" ]

  rm "$CLUSTER/clusterconfig/kubeconfig"

  recipe cluster-talos --first cp-1 --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/clusterconfig/kubeconfig does not exist"* ]]
  [ ! -e "$RECORD/argv" ]
}

@test "A Talos upgrade drains through the Kubernetes API one node at a time" {
  fake_cluster
  printf '%s\n' cp-2 worker-1 > "$STATE/talos-behind"
  # upgrades: the recorded talman upgrade calls that are not dry runs.
  upgrades() {
    calls '^talman upgrade( |$)' | grep -v -- ' --dry-run' || true
  }

  recipe cluster-upgrade <<< "no"

  [ "$status" -ne 0 ]
  [[ $output == *"cp-2: v1.14.5 -> v1.14.6"* && $output == *"worker-1: v1.14.5 -> v1.14.6"* ]]
  [[ $output == *"lab-sto2 was not confirmed"* ]]
  [ -z "$(upgrades)" ]
  [ -z "$(calls '^(kubectl drain|talman etcd)')" ]

  : > "$RECORD/argv"
  recipe cluster-upgrade <<< "lab-sto2"

  [ "$status" -eq 0 ]
  [ ! -s "$STATE/talos-behind" ]
  [ "$(calls '^kubectl drain ' | wc -l)" -eq 2 ]
  [ "$(upgrades | wc -l)" -eq 2 ]
  previous=$(call_line '^talman etcd snapshot')
  [ -n "$previous" ]
  for node in cp-2 worker-1; do
    readyz=$(grep -n '^kubectl get --raw /readyz' "$RECORD/argv" | cut -d: -f1 |
      awk -v after="$previous" '$1 > after' | head -1)
    drained=$(call_line "^kubectl drain $node( |\$)")
    upgraded=$(grep -nE "^talman upgrade -n $node( |\$)" "$RECORD/argv" | grep -v -- ' --dry-run' | head -1 | cut -d: -f1)
    uncordoned=$(call_line "^kubectl uncordon $node( |\$)")
    ready=$(grep -n '^kubectl get nodes ' "$RECORD/argv" | cut -d: -f1 |
      awk -v after="$upgraded" -v before="$uncordoned" '$1 > after && $1 < before' | tail -1)
    for call in "$readyz" "$drained" "$upgraded" "$ready" "$uncordoned"; do
      [ -n "$call" ]
    done
    [ "$previous" -lt "$readyz" ]
    [ "$readyz" -lt "$drained" ]
    [ "$drained" -lt "$upgraded" ]
    [ "$upgraded" -lt "$ready" ]
    [ "$ready" -lt "$uncordoned" ]
    [[ " $(upgrades | grep -E "^talman upgrade -n $node( |\$)") " == *" --extra-flags=--drain=false "* ]]
    previous=$uncordoned
  done
  checked=$(grep -n '^talman upgrade --dry-run' "$RECORD/argv" | tail -1 | cut -d: -f1)
  [ "$checked" -gt "$previous" ]
  [ "$(cat "$RECORD/kubeconfig")" = "$CLUSTER/clusterconfig/kubeconfig" ]
  [ "$(yq '.clusters[0].cluster.server' "$CLUSTER/clusterconfig/kubeconfig")" = "https://$KUBE_API_ADDRESS:6443" ]
  [ -z "$(calls '^talman .*( --to| --force)')" ]
  [ -z "$(calls '^talosctl |health')" ]

  # The API does not answer: no node is drained.
  printf '%s\n' cp-2 worker-1 > "$STATE/talos-behind"
  : > "$STATE/api-down"
  : > "$RECORD/argv"
  recipe cluster-upgrade --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"the Kubernetes API does not answer"* ]]
  [ -z "$(calls '^kubectl drain ')" ]
  [ -z "$(upgrades)" ]

  # Every node on its version: nothing is asked, drained or upgraded.
  rm "$STATE/api-down"
  : > "$STATE/talos-behind"
  : > "$RECORD/argv"
  recipe cluster-upgrade < /dev/null

  [ "$status" -eq 0 ]
  [[ $output != *"Type lab-sto2"* ]]
  [ -z "$(calls '^(kubectl drain|talman etcd)')" ]
  [ -z "$(upgrades)" ]
}

@test "A Kubernetes upgrade shows the change and asks before applying" {
  fake_cluster
  : > "$STATE/k8s-behind"
  # upgrades: the recorded talman upgrade-k8s calls that are not dry runs.
  upgrades() {
    calls '^talman upgrade-k8s( |$)' | grep -v -- ' --dry-run' || true
  }

  recipe cluster-upgrade-k8s <<< "no"

  [ "$status" -ne 0 ]
  [[ $output == *"v1.37.0 -> v1.37.1"* ]]
  [[ $output == *"lab-sto2 was not confirmed"* ]]
  [ -z "$(upgrades)" ]
  [ -e "$STATE/k8s-behind" ]

  : > "$RECORD/argv"
  recipe cluster-upgrade-k8s <<< "lab-sto2"

  [ "$status" -eq 0 ]
  [ ! -e "$STATE/k8s-behind" ]
  [ "$(upgrades | wc -l)" -eq 1 ]
  [[ " $(upgrades) " != *" --snapshot "* ]]
  [[ " $(upgrades) " == *" --extra-flags=--endpoint=https://$KUBE_API_ADDRESS:6443 "* ]]
  [[ " $(upgrades) " != *" --to"* && " $(upgrades) " != *" --force "* ]]
  upgraded=$(call_line "^$(upgrades)\$")
  [ "$(call_line '^talman upgrade-k8s .*--dry-run')" -lt "$upgraded" ]
  checked=$(grep -n '^talman upgrade-k8s .*--dry-run' "$RECORD/argv" | tail -1 | cut -d: -f1)
  [ "$checked" -gt "$upgraded" ]
  [[ $output != *"$KUBE_API_ADDRESS"* ]]

  : > "$RECORD/argv"
  recipe cluster-upgrade-k8s < /dev/null

  [ "$status" -eq 0 ]
  [[ $output != *"Type lab-sto2"* ]]
  [ -z "$(upgrades)" ]
}

@test "An upgrade's etcd snapshot is uploaded encrypted and nothing is left on disk" {
  fake_cluster
  printf '%s\n' cp-2 worker-1 > "$STATE/talos-behind"
  : > "$STATE/k8s-behind"
  bucket="$STORE/marker-prefix-etcd"

  recipe cluster-upgrade --yes < /dev/null

  [ "$status" -eq 0 ]
  talos_snapshot=$(call_line '^talman etcd snapshot ')
  [ -n "$talos_snapshot" ]
  [ "$talos_snapshot" -lt "$(call_line '^kubectl drain ')" ]
  [ "$talos_snapshot" -lt "$(grep -nE '^talman upgrade -n ' "$RECORD/argv" | grep -v -- ' --dry-run' | head -1 | cut -d: -f1)" ]
  [[ $output =~ cluster-upgrade:\ lab-sto2:\ [0-9]{8}T[0-9]{6}Z\.snapshot\.age,\ [0-9]+\ bytes ]]
  next_second

  recipe cluster-upgrade-k8s --yes < /dev/null

  [ "$status" -eq 0 ]
  k8s_snapshot=$(last_call_line '^talman etcd snapshot ')
  [ "$k8s_snapshot" -gt "$talos_snapshot" ]
  [ "$k8s_snapshot" -lt "$(grep -n '^talman upgrade-k8s ' "$RECORD/argv" | grep -v -- ' --dry-run' | head -1 | cut -d: -f1)" ]
  # Each run kept one object of its own in the bucket, which only the Talos age key opens.
  mapfile -t objects < <(find "$bucket" -type f -printf '%P\n' | sort)
  [ "${#objects[@]}" -eq 2 ]
  for object in "${objects[@]}"; do
    [[ $object =~ ^lab-sto2/[0-9]{8}T[0-9]{6}Z\.snapshot\.age$ ]]
    [ "$(head -n 1 "$bucket/$object")" = age-encryption.org/v1 ]
    age -d -i "$SNAPSHOT_KEY" "$bucket/$object" | cmp - "$STATE/content"
  done
  # talman wrote each snapshot into a private directory outside the repository, and none of its own.
  [ "$(grep -c '^path ' "$RECORD/snapshot")" -eq 2 ]
  while read -r _ written; do
    [[ $written == "$BATS_TEST_TMPDIR"/cluster-upgrade*/etcd.db ]]
  done < <(grep '^path ' "$RECORD/snapshot")
  [ -z "$(calls '^talman .*--snapshot')" ]
  [ -z "$(find "$CLUSTER" -name 'etcd-*')" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -type d -name 'cluster-upgrade*')" ]
  # The snapshot's content is in the bucket, encrypted, and nowhere else on disk.
  found=$(grep -rlaF marker-snapshot-content "$BATS_TEST_TMPDIR" --exclude-dir=state || true)
  [ -z "$found" ]
}

@test "A failed snapshot stops an upgrade before any node is touched" {
  fake_cluster
  # changes: the recorded calls that drain, upgrade or uncordon a node, or ask talman for a snapshot.
  changes() {
    calls '^kubectl (drain|cordon|uncordon) |^talman (upgrade|upgrade-k8s)( .*)?$' |
      grep -v -- ' --dry-run' || true
  }
  for recipe in cluster-upgrade cluster-upgrade-k8s; do
    for failure in taking uploading; do
      echo "$recipe $failure"
      printf '%s\n' cp-2 worker-1 > "$STATE/talos-behind"
      : > "$STATE/k8s-behind"
      rm -rf "$RECORD" "$STATE/snapshot-fails" "$FAILS/upload"
      mkdir -p "$RECORD"
      if [[ $failure == taking ]]; then
        : > "$STATE/snapshot-fails"
        expected="failed while taking the etcd snapshot"
      else
        : > "$FAILS/upload"
        expected="failed while uploading the encrypted snapshot to the etcd bucket"
      fi
      next_second

      recipe "$recipe" --yes < /dev/null

      [ "$status" -ne 0 ]
      [[ $output == *"$recipe: $expected"* ]]
      # A failed upload says why, as cluster-snapshot's does, and names none of the places and keys.
      if [[ $failure == uploading ]]; then
        [[ $output == *"AccessDenied"* ]]
      else
        [[ $output != *"AccessDenied"* ]]
      fi
      for shown in marker-endpoint marker-prefix marker-state; do
        [[ $output != *"$shown"* ]]
      done
      [ -n "$(calls '^talman etcd snapshot ')" ]
      [ -z "$(changes)" ]
      [ -z "$(find "$STORE" -type f)" ]
      [ -z "$(find "$CLUSTER" -name 'etcd-*')" ]
      [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -type d -name 'cluster-upgrade*')" ]
    done
  done
}

@test "the upgrade recipes name the snapshot settings they lack before they ask" {
  fake_cluster
  printf '%s\n' cp-2 worker-1 > "$STATE/talos-behind"
  : > "$STATE/k8s-behind"
  for name in BACKUP_BUCKET_PREFIX AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    for recipe in cluster-upgrade cluster-upgrade-k8s; do
      echo "$recipe $name"
      reset_environment
      without "$name"
      : > "$RECORD/argv"

      recipe "$recipe" <<< "lab-sto2"

      [ "$status" -ne 0 ]
      [[ $output == *"$name is not set"* ]]
      [[ $output != *"Type lab-sto2"* ]]
      [ -z "$(calls '^(kubectl|talman etcd)')" ]
      if calls '^talman upgrade' | grep -qv -- ' --dry-run'; then
        return 1
      fi
    done
  done
}

@test "An upgrade waits for a Ready the node reports after it was upgraded" {
  fake_cluster
  printf '%s\n' cp-2 worker-1 > "$STATE/talos-behind"
  # cp-2 reports Ready on the first poll after its upgrade; worker-1's kubelet reports Ready as of
  # before the upgrade for two polls, as etcd keeps a node's last report while the node is away.
  echo 0 > "$STATE/stale.cp-2"
  echo 2 > "$STATE/stale.worker-1"
  # polls NODE: how many times the nodes were read between NODE's upgrade and its uncordon.
  polls() {
    local upgraded uncordoned
    upgraded=$(grep -nE "^talman upgrade -n $1( |\$)" "$RECORD/argv" | grep -v -- ' --dry-run' | head -1 | cut -d: -f1)
    uncordoned=$(call_line "^kubectl uncordon $1( |\$)")
    [ -n "$upgraded" ] && [ -n "$uncordoned" ]
    grep -n '^kubectl get nodes ' "$RECORD/argv" | cut -d: -f1 |
      awk -v after="$upgraded" -v before="$uncordoned" '$1 > after && $1 < before' | wc -l
  }

  recipe cluster-upgrade --yes < /dev/null

  [ "$status" -eq 0 ]
  [ "$(polls cp-2)" -eq 1 ]
  [ "$(polls worker-1)" -eq 3 ]

  # A kubelet that never reports again leaves the node cordoned and the recipe failing by its name.
  printf '%s\n' cp-2 > "$STATE/talos-behind"
  rm -f "$STATE"/upgraded.*
  echo never > "$STATE/stale.cp-2"
  : > "$RECORD/argv"
  next_second

  recipe cluster-upgrade --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"cp-2 did not report Ready after the upgrade"* ]]
  [ -z "$(calls '^kubectl uncordon ')" ]
}

@test "The cluster recipes run their tools with only the secrets they use" {
  fake_cluster
  real_age=$(command -v age)
  fake_tool age <<EOF
env | cut -d= -f1 >> "\$RECORD/names.age"
exec "$real_age" "\$@"
EOF
  with SOPS_AGE_KEY=marker-talos-age-key CLUSTER_S3_ACCESS_KEY_ID=marker-cluster-key-id \
    CLUSTER_S3_SECRET_ACCESS_KEY=marker-cluster-secret OS_CLOUD=marker-cloud \
    OS_APPLICATION_CREDENTIAL_SECRET=marker-application-credential-secret \
    TF_STATE_PASSPHRASE=marker-state-passphrase TF_ENCRYPTION=marker-encryption \
    'OPERATOR_CIDRS=["203.0.113.77/32"]'
  printf '%s\n' cp-2 > "$STATE/talos-behind"
  # names_of TOOL: the names of the secret variables TOOL had in its environment, sorted and unique.
  names_of() {
    grep -E '^(AWS_|CLUSTER_S3_|OS_|TF_STATE_PASSPHRASE|TF_ENCRYPTION|TF_VAR_|FLUX_AGE_|OPERATOR_CIDRS|SOPS_AGE_)' \
      "$RECORD/names.$1" | sort -u | paste -sd' ' -
  }

  recipe cluster-kubeconfig
  [ "$status" -eq 0 ]
  recipe cluster-upgrade --yes < /dev/null
  [ "$status" -eq 0 ]
  # The rollout's checks pass their kubectl and talman calls through quietly, to the same functions.
  printf '%s\n' cp-1 worker-2 > "$STATE/pending"
  recipe cluster-talos --first cp-1 --yes < /dev/null
  [ "$status" -eq 0 ]
  [ -n "$(calls '^talman talosctl -n cp-1 -n cp-2 etcd status$')" ]
  [ -n "$(calls '^kubectl --server https://[^ ]+:6443 get --raw /readyz ')" ]

  # talman runs sops, so it gets the Talos age key and none of the S3, cloud or state secrets.
  [ "$(names_of talman)" = "SOPS_AGE_KEY SOPS_AGE_KEY_FILE" ]
  [ -z "$(names_of kubectl)" ]
  [ "$(names_of age)" = SOPS_AGE_KEY_FILE ]
  # The S3 client gets the state key pair as its own variables and no secret of the environment.
  for file in "$RECORD"/env.rclone.*; do
    names=$(tr '\0' '\n' < "$file" | cut -d= -f1)
    if grep -qE '^(AWS_|CLUSTER_S3_|OS_|TF_STATE_PASSPHRASE|TF_ENCRYPTION|FLUX_AGE_|OPERATOR_CIDRS|SOPS_AGE_)' <<< "$names"; then
      return 1
    fi
    grep -qx RCLONE_CONFIG_STORE_ACCESS_KEY_ID <<< "$names"
  done
}

@test "With CI set, talman's output stays out of the log" {
  fake_cluster
  with CI=true
  mapfile -t addresses < <(yq '.nodes[].ipAddress' "$CLUSTER/talman.yaml")
  [ "${#addresses[@]}" -eq 6 ]
  printed=()
  # shown_in RECIPE: the file RECIPE keeps talman's output in, as the recipes name it.
  shown_in() {
    echo "its output is in talos/lab-sto2/clusterconfig/$1.log"
  }

  recipe cluster-bootstrap

  [ "$status" -eq 0 ]
  [[ $output == *"cluster-bootstrap: talman apply succeeded; $(shown_in cluster-bootstrap)"* ]]
  [[ $output == *"cluster-kubeconfig: talman kubeconfig succeeded; $(shown_in cluster-kubeconfig)"* ]]
  grep -q 'bootstrapping etcd' "$CLUSTER/clusterconfig/cluster-bootstrap.log"
  printed+=("$output")

  : > "$STATE/changes"

  recipe cluster-talos --yes < /dev/null

  [ "$status" -eq 0 ]
  [ "$(grep -c "cluster-talos: talman apply succeeded; $(shown_in cluster-talos)" <<< "$output")" -eq 2 ]
  grep -q 'Config diff:' "$CLUSTER/clusterconfig/cluster-talos.log"
  grep -q "${addresses[0]}" "$CLUSTER/clusterconfig/cluster-talos.log"
  printed+=("$output")

  printf '%s\n' cp-2 > "$STATE/talos-behind"
  : > "$STATE/k8s-behind"

  recipe cluster-upgrade --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"cluster-upgrade: talman upgrade succeeded; $(shown_in cluster-upgrade)"* ]]
  [[ $output =~ cluster-upgrade:\ lab-sto2:\ [0-9]{8}T[0-9]{6}Z\.snapshot\.age,\ [0-9]+\ bytes ]]
  grep -q 'cp-2: upgraded' "$CLUSTER/clusterconfig/cluster-upgrade.log"
  printed+=("$output")

  next_second

  recipe cluster-upgrade-k8s --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"cluster-upgrade-k8s: talman upgrade-k8s succeeded; $(shown_in cluster-upgrade-k8s)"* ]]
  grep -q 'upgraded Kubernetes' "$CLUSTER/clusterconfig/cluster-upgrade-k8s.log"
  printed+=("$output")

  # A talman call that fails says so and where its output is, and each run starts its file afresh.
  : > "$STATE/changes"
  : > "$STATE/unreachable"

  recipe cluster-talos --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"cluster-talos: talman apply failed; $(shown_in cluster-talos)"* ]]
  [[ $output == *"cluster-talos: failed while asking each node what the configuration would change"* ]]
  printed+=("$output")
  grep -q 'answers neither' "$CLUSTER/clusterconfig/cluster-talos.log"
  run grep -c 'Applied configuration' "$CLUSTER/clusterconfig/cluster-talos.log"
  [ "$output" -eq 0 ]

  for shown in "${addresses[@]}" 'Config diff:' 'answers neither' 'dial tcp'; do
    [[ ${printed[*]} != *"$shown"* ]]
  done
  cd "$ROOT"
  git check-ignore --no-index -q talos/lab-sto2/clusterconfig/cluster-talos.log
}

@test "No cluster secret reaches a command line or the output" {
  git_repository
  record talman talosctl sops age-keygen yq jq git
  printed=()
  # run_and_keep STATUS RECIPE...: runs the recipe, expects STATUS (ok or failed), keeps its output.
  run_and_keep() {
    local expected=$1
    shift
    recipe "$@"
    if [[ $expected == ok ]]; then
      [ "$status" -eq 0 ]
    else
      [ "$status" -ne 0 ]
    fi
    printed+=("$output")
  }

  run_and_keep ok cluster-age-key
  run_and_keep ok cluster-age-key
  run_and_keep ok cluster-secrets
  run_and_keep failed cluster-secrets
  run_and_keep ok cluster-secrets-check
  mv "$BUNDLE" "$BATS_TEST_TMPDIR/encrypted.yaml"
  plaintext_talman
  run_and_keep failed cluster-secrets
  run_and_keep failed cluster-secrets-check

  # The secrets so far: the age key, and every value of both bundles.
  markers=("$(grep '^AGE-SECRET-KEY-' "$KEY")")
  mapfile -t -O 1 markers < <(bundle_values "$BUNDLE"; SOPS_AGE_KEY_FILE="$KEY" sops decrypt "$BATS_TEST_TMPDIR/encrypted.yaml" | bundle_values /dev/stdin)
  [ "${#markers[@]}" -gt 20 ]
  grep -q '^talman secrets generate' "$RECORD/argv"
  grep -q '^sops ' "$RECORD/argv"
  grep -q '^talosctl ' "$RECORD/argv"

  # The recipes that reach the cluster, against the fakes, with a key and a bundle of markers.
  fake_cluster
  run_and_keep ok cluster-bootstrap
  run_and_keep failed cluster-bootstrap
  run_and_keep ok cluster-kubeconfig
  without SOPS_AGE_KEY_FILE
  with SOPS_AGE_KEY=marker-sops-age-key
  run_and_keep ok cluster-kubeconfig
  reset_environment
  rm "$STATE/bootstrapped"
  : > "$STATE/silent.$(node_address worker-3)"
  with TALOS_WAIT=0
  run_and_keep failed cluster-bootstrap
  run_and_keep failed cluster-talos --yes < /dev/null
  reset_environment
  rm "$STATE/silent.$(node_address worker-3)"
  : > "$STATE/changes"
  echo worker-3 > "$STATE/new-nodes"
  run_and_keep failed cluster-talos <<< no
  run_and_keep failed cluster-talos --yes < /dev/null
  run_and_keep ok cluster-talos --onboard --yes < /dev/null
  run_and_keep ok cluster-talos < /dev/null
  # A rollout whose diff, unredacted, would show the cluster's tokens and etcd's CA key, and which
  # reads back what needs a reboot, names it, reboots it, and stops partway.
  reboot_rollout() {
    : > "$STATE/changes"
    printf '%s\n' cp-1 cp-2 > "$STATE/pending"
    : > "$STATE/etcd.cp-1"
    : > "$STATE/etcd.cp-2"
    run_and_keep ok cluster-talos --yes < /dev/null
    : > "$STATE/changes"
    printf '%s\n' cp-1 cp-2 > "$STATE/pending"
    run_and_keep ok cluster-talos --yes --reboot < /dev/null
    printf '%s\n' cp-1 cp-2 > "$STATE/pending"
    : > "$STATE/apply-fails.cp-2"
    run_and_keep failed cluster-talos --yes < /dev/null
    rm "$STATE/apply-fails.cp-2" "$STATE/pending"
  }
  reboot_rollout
  printf '%s\n' cp-2 worker-1 > "$STATE/talos-behind"
  : > "$STATE/k8s-behind"
  run_and_keep failed cluster-upgrade <<< no
  run_and_keep failed cluster-upgrade-k8s <<< no
  : > "$STATE/api-down"
  run_and_keep failed cluster-upgrade --yes < /dev/null
  rm "$STATE/api-down"
  run_and_keep ok cluster-upgrade --yes < /dev/null
  next_second
  run_and_keep ok cluster-upgrade-k8s --yes < /dev/null
  run_and_keep ok cluster-upgrade < /dev/null
  run_and_keep ok cluster-upgrade-k8s < /dev/null

  # The same recipes with CI set, as in a public CI log, where no node address may show either.
  local_runs=${#printed[@]}
  with CI=true
  rm -f "$STATE/bootstrapped"
  run_and_keep ok cluster-bootstrap
  run_and_keep failed cluster-bootstrap
  run_and_keep ok cluster-kubeconfig
  : > "$STATE/changes"
  echo worker-3 > "$STATE/new-nodes"
  run_and_keep failed cluster-talos <<< no
  run_and_keep failed cluster-talos --yes < /dev/null
  run_and_keep ok cluster-talos --onboard --yes < /dev/null
  reboot_rollout
  printf '%s\n' cp-2 worker-1 > "$STATE/talos-behind"
  : > "$STATE/k8s-behind"
  run_and_keep failed cluster-upgrade <<< no
  run_and_keep failed cluster-upgrade-k8s <<< no
  : > "$STATE/api-down"
  run_and_keep failed cluster-upgrade --yes < /dev/null
  rm "$STATE/api-down"
  next_second
  run_and_keep ok cluster-upgrade --yes < /dev/null
  next_second
  run_and_keep ok cluster-upgrade-k8s --yes < /dev/null
  reset_environment
  ci_printed=("${printed[@]:local_runs}")
  [ "${#ci_printed[@]}" -eq 14 ]
  [[ ${ci_printed[*]} == *"cp-1 runs etcd as it was started until it reboots"* ]]
  [[ ${ci_printed[*]} == *"its output is in talos/lab-sto2/clusterconfig/"* ]]
  for address in $(yq '.nodes[].ipAddress' "$CLUSTER/talman.yaml"); do
    [[ ${ci_printed[*]} != *"$address"* ]]
  done

  markers+=(
    AGE-SECRET-KEY-MARKER-AGE-KEY-FILE
    marker-bundle-secret
    marker-sops-age-key
    marker-certificate-authority-data
    marker-client-certificate-data
    marker-client-key-data
    marker-state-access-key-id
    marker-state-secret-key
    marker-machine-token
    marker-cluster-secret
    marker-machine-ca-certificate
    marker-etcd-certificate
    marker-etcd-key
  )
  grep -q '^talman apply ' "$RECORD/argv"
  grep -q '^kubectl ' "$RECORD/argv"
  grep -q '^yq ' "$RECORD/argv"
  grep -q '^talman talosctl -n cp-1 get EtcdConfigs.etcd.talos.dev ' "$RECORD/argv"
  [ -z "$(calls 'machineconfig')" ]
  [[ ${printed[*]} == *"no answer on the Talos API port"* ]]
  [[ ${printed[*]} != *"$KUBE_API_ADDRESS"* ]]
  # talman's output in CI, in the recipes' logs, holds no secret either.
  mapfile -t logs < <(find "$CLUSTER/clusterconfig" -name '*.log')
  [ "${#logs[@]}" -ge 4 ]
  for marker in "${markers[@]}"; do
    absent "$marker" "${logs[@]}"
  done
  # The kubeconfig and the bundle hold their own secrets; nothing else may.
  rm -r "$BUNDLE" "$CLUSTER/clusterconfig"
  for marker in "${markers[@]}"; do
    absent "$marker" "$RECORD/argv"
    [[ ${printed[*]} != *"$marker"* ]]
    absent "$marker" "$REPO"
  done
}
