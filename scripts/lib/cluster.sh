# shellcheck shell=bash
# Shared by scripts/cluster-env, the cluster-* scripts, the install scripts, the adoption check and
# the secrets bundle check: the Talos age key's location, talos/.sops.yaml's recipient, the check
# that a secrets bundle is encrypted, a cluster's nodes and the wait for their Talos API, the drain
# of a node with talosctl's own drain off, the nodes that have not reported Ready since a given time,
# the line that names the step a recipe failed in, the private directory an etcd snapshot is kept in
# while a recipe works on it, the talman run that keeps its output out of a CI log, the Flux age key
# and the other objects Flux needs before it starts, the release an application's HelmRelease makes,
# and the install of an application before Flux. Builds on scripts/lib/s3.sh, for the backup
# buckets' prefix and the object storage's endpoint, and so on scripts/lib/infra.sh, which reads the
# environment. Nothing here prints a secret or a deployment value, or passes one as
# an argument: sops and talman get the Talos age key's location from their environment, and the Flux
# age key and the values of the objects applied before Flux reach age-keygen, jq and kubectl on
# standard input.

# shellcheck source=scripts/lib/s3.sh
. "$(dirname "${BASH_SOURCE[0]}")/s3.sh"

sops_config=$infra_root/talos/.sops.yaml
# The rule for the SOPS files under kubernetes/, which Flux decrypts with the Flux age key.
flux_sops_config=$infra_root/.sops.yaml

# report_failed_step: from here on, a recipe that fails ends with a line naming the step it was in,
# which it keeps in step.
report_failed_step() {
  step="checking the environment"
  trap 'failed_step $?' EXIT
}

failed_step() {
  if (($1 != 0)); then
    infra_error "failed while $step"
  fi
}

# require_commands NAME...: fails naming each NAME that is not on PATH.
require_commands() {
  local name complete=1
  for name; do
    if ! type -P "$name" > /dev/null; then
      infra_error "$name is not on PATH; install the pinned tools with: just tools"
      complete=0
    fi
  done
  ((complete))
}

# make_private_dir: makes work_dir, a directory only this user can enter, under TMPDIR, for a file
# that must not stay on disk, such as an etcd snapshot, which holds every Kubernetes Secret. Every
# exit of the script removes it, through its EXIT trap, which bash runs on success, on failure and
# when SIGINT or SIGTERM ends it; after that, a failing script names its step as report_failed_step
# has it do. Ctrl-C ends the script even when the program it interrupted handles SIGINT itself and
# exits 0, after which bash would otherwise go on. A TMPDIR inside the repository is refused, as a
# file there could be committed.
make_private_dir() {
  if inside_repository "${TMPDIR:-/tmp}"; then
    infra_error "TMPDIR lies inside the repository; the snapshot is kept outside it"
    return 1
  fi
  work_dir=$(umask 077 && mktemp -d -t "${0##*/}.XXXXXXXXXX") || return 1
  trap 'remove_private_dir $?' EXIT
  trap 'exit 130' INT
}

remove_private_dir() {
  local status=$1
  if ! rm -rf -- "$work_dir"; then
    infra_error "cannot remove $work_dir, which holds an etcd snapshot; remove it"
    ((status != 0)) || status=1
  fi
  failed_step "$status"
  # A worker the run left out of BGP is the last thing a failed run says.
  bgp_report_out
  exit "$status"
}

# talman_log_start: with CI set, empties talman_log once per run. A caller that runs cluster_talman in
# a command substitution, whose variables do not outlast it, calls this first, or the next call
# would empty the log again.
talman_log_start() {
  [[ -z ${talman_log_started-} ]] || return 0
  # shellcheck disable=SC2154 # scripts/cluster-env sets talman_log
  (umask 077 && mkdir -p "${talman_log%/*}" && : > "$talman_log")
  talman_log_started=1
}

# cluster_talman ARG...: talman with ARG... on the cluster scripts/cluster-env set up. talman's output,
# talosctl's within it, names the nodes by address and shows configuration diffs, and CI logs are
# public, so with CI set it goes to talman_log, in the cluster's clusterconfig/, which git ignores,
# and only whether talman succeeded and where its output is are printed. The file holds what this
# run's talman calls printed. With --detailed-exit-code, talman's 2 reports changes, not a failure.
# Returns talman's status.
cluster_talman() {
  local status=0 log
  if [[ -z ${CI:-} ]]; then
    talman "$@"
    return
  fi
  talman_log_start
  talman "$@" >> "$talman_log" 2>&1 || status=$?
  log=${talman_log#"$infra_root"/}
  if ((status == 0)) || { ((status == 2)) && [[ " $* " == *" --detailed-exit-code "* ]]; }; then
    printf '%s: talman %s succeeded; its output is in %s\n' "${0##*/}" "$1" "$log"
  else
    infra_error "talman $1 failed; its output is in $log"
  fi
  return "$status"
}

# stack_cluster_name: the name of the cluster the stack's talman_yaml output configures, empty when
# the stack has none, for a stack that scripts/stack-env has set up and initialised. tofu's JSON holds
# every output's value; only jq and yq read it.
stack_cluster_name() {
  local outputs name
  outputs=$(stack_tofu output -json) || return 1
  name=$(jq -r '.talman_yaml.value // ""' <<< "$outputs" | yq '.clusterName // ""')
  # The name becomes a path under talos/, so it is a plain name that cannot lead out of it.
  if [[ -n $name && ! $name =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    # shellcheck disable=SC2154 # scripts/stack-env sets stack
    infra_error "the clusterName in $stack's talman_yaml is not a name of lower-case letters, digits and hyphens"
    return 1
  fi
  printf '%s' "$name"
}

# stack_holds_resources: prints holds when the state of the stack that scripts/stack-env has set up
# and initialised holds a managed resource, and empty when it holds none; data sources are not
# resources and a stack never applied holds none. Only a state that was read and parsed as a JSON
# object counts as empty. Any other outcome prints nothing and fails, and a caller takes anything but
# exactly one of the two words, whatever the status, for a state it could not read, as a failure of
# bash itself leaves no word to take for an answer.
stack_holds_resources() {
  local state count
  state=$(stack_tofu show -json) || return 2
  count=$(jq -r 'if type != "object" then error("not a state") else
    [.values.root_module? // empty | .. | objects | select(.mode? == "managed")] | length end' <<< "$state" 2> /dev/null) || return 2
  [[ $count =~ ^[0-9]+$ ]] || return 2
  if ((count > 0)); then echo holds; else echo empty; fi
}

# holds_resources STACK: whether STACK's state holds a managed resource: 0 when it does, 1 when it
# holds none, 2 when it cannot be read. STACK's lock is taken and the stack initialised in a process
# of its own (scripts/stack-state), so STACK's inputs and lock do not carry over; its answer is taken
# only as the word it prints, with status 0.
holds_resources() {
  local answer
  answer=$("$(dirname "${BASH_SOURCE[0]}")/../stack-state" "$1") || return 2
  case $answer in
    holds) return 0 ;;
    empty) return 1 ;;
    *) return 2 ;;
  esac
}

# remove_generated CLUSTER: removes the files generated for CLUSTER that hold the addresses of its
# nodes and its API: talman.yaml, and the talosconfig and kubeconfig talman writes into
# clusterconfig/. A later bootstrap or onboarding would otherwise send machine configuration to
# whoever answers at those addresses. Only a file that git ignores, and so neither tracks nor would
# commit, is removed; the secrets bundle and etcd snapshots stay. Names what it removes, never what
# the files held.
remove_generated() {
  local path
  local -a removed=()
  for path in "talos/$1/talman.yaml" "talos/$1/clusterconfig/talosconfig" "talos/$1/clusterconfig/kubeconfig"; do
    [[ -e $infra_root/$path || -L $infra_root/$path ]] || continue
    if git -C "$infra_root" check-ignore -q -- "$path"; then
      rm -f -- "${infra_root:?}/$path"
      removed+=("$path")
    else
      infra_error "$path is not a file git ignores, so it is left in place; it may hold the destroyed cluster's addresses"
    fi
  done
  if ((${#removed[@]} > 0)); then
    echo "removed what held the destroyed cluster's addresses: ${removed[*]}"
  fi
}

# require_cluster_owns_nothing CLUSTER STACK UNREACHABLE: the check before the cluster stack STACK is
# destroyed, shared by cluster-destroy and infra-destroy. The load balancers that Services of type
# LoadBalancer get and the volumes behind PersistentVolumes of a CSI driver are made by the cluster,
# not by OpenTofu, so the stack's destroy would leave them in the cloud, where they also keep the
# network from being deleted. So, through CLUSTER's kubeconfig, it lists every such Service and
# PersistentVolume, and while there are any, names them and fails. A Service whose every
# load-balancer address lies in the service range of the cluster's talman.yaml is left out: Cilium
# gave it that address from its pool, the workers announce it over BGP, and nothing in the cloud
# stands behind it. A Service with no address yet, or one outside the range, still counts, as does
# every such Service when talman.yaml names no service range. LINSTOR's volumes are the other
# exception: their data is on the workers' data volumes, which the stack holds and destroys, so
# nothing of them stays in the cloud; it says how many there are. A cluster whose API does not
# answer, that has no kubeconfig, or whose name the stack does not give (empty CLUSTER), cannot be
# asked and may still own some, so it fails too, unless UNREACHABLE is 1, with which the operator takes
# on what may be left. Neither kubectl's errors nor anything of the objects but their names are
# printed, as they can hold addresses.
require_cluster_owns_nothing() {
  local cluster=$1 stack=$2 unreachable=$3 kubeconfig why services volumes balancers csi_volumes
  local linstor_volumes counted name driver service_range
  # LINSTOR's CSI driver, whose volumes are on the workers' data volumes in the stack.
  local linstor_driver=linstor.csi.linbit.com
  require_commands kubectl jq yq || return 1
  local asked=0
  if [[ -z $cluster ]]; then
    why="$stack names no cluster, which leaves no kubeconfig to ask"
    cluster="the cluster of $stack"
  else
    kubeconfig=$infra_root/talos/$cluster/clusterconfig/kubeconfig
    if [[ ! -f $kubeconfig ]]; then
      why="${kubeconfig#"$infra_root"/} does not exist"
    elif services=$(KUBECONFIG=$kubeconfig kubectl get services --all-namespaces --output json --request-timeout=30s 2> /dev/null) &&
      volumes=$(KUBECONFIG=$kubeconfig kubectl get persistentvolumes --output json --request-timeout=30s 2> /dev/null); then
      asked=1
    else
      why="the API of $cluster does not answer through its kubeconfig"
    fi
  fi

  if ((asked)); then
    # The service range the cluster stack rendered into talman.yaml; without one, no address counts
    # as the pool's.
    service_range=
    if [[ -f $infra_root/talos/$cluster/talman.yaml ]]; then
      service_range=$(yq '.values.serviceRange // ""' "$infra_root/talos/$cluster/talman.yaml" 2> /dev/null) || service_range=
    fi
    # A range is known only as an IPv4 network with octets 0 to 255 and a prefix of 1 to 32, and an
    # address is the pool's only as an IPv4 address with octets 0 to 255 inside it: anything else
    # could pass the arithmetic without being in the range.
    balancers=$(jq -r --arg range "$service_range" '
      def ipv4: type == "string" and test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$")
        and (split(".") | all(tonumber <= 255));
      def ip4: split(".") | map(tonumber) | .[0] * 16777216 + .[1] * 65536 + .[2] * 256 + .[3];
      def in_range($cidr): ($cidr | split("/")) as $net | pow(2; 32 - ($net[1] | tonumber)) as $size
        | ((ip4 / $size) | floor) == (($net[0] | ip4) / $size | floor);
      def from_pool: if .hostname == null and (.ip | ipv4) then .ip | in_range($range) else false end;
      ($range | test("^[^/]+/[0-9]{1,2}$") and (split("/") | (.[0] | ipv4) and (.[1] | tonumber | . >= 1 and . <= 32))) as $known
      | .items[] | select(.spec.type == "LoadBalancer")
      | (.status.loadBalancer.ingress // []) as $ingress
      | select(if $known and ($ingress | length) > 0 then ($ingress | all(from_pool)) | not else true end)
      | "\(.metadata.namespace)/\(.metadata.name)"' <<< "$services")
    csi_volumes=$(jq -r --arg linstor "$linstor_driver" '.items[]
      | select(.spec.csi != null and .spec.csi.driver != $linstor)
      | "\(.metadata.name) \(.spec.csi.driver // "unnamed")"' <<< "$volumes")
    linstor_volumes=$(jq --arg linstor "$linstor_driver" '[.items[] | select(.spec.csi.driver? == $linstor)] | length' <<< "$volumes")
    if [[ -n $balancers || -n $csi_volumes ]]; then
      while read -r name; do
        [[ -z $name ]] || infra_error "the Service $name is of type LoadBalancer, with an address outside the service range, or none yet"
      done <<< "$balancers"
      while read -r name driver; do
        [[ -z $name ]] || infra_error "the PersistentVolume $name is a volume of the CSI driver $driver"
      done <<< "$csi_volumes"
      infra_error "$cluster still owns load balancers or volumes that are not in the state of $stack, which a destroy would leave in the cloud, keeping the network from being deleted; remove them first. Nothing was destroyed"
      return 1
    fi
    if ((linstor_volumes == 0)); then
      infra_say "$cluster owns no Service of type LoadBalancer outside its service range and no PersistentVolume of a CSI driver"
    else
      infra_say "$cluster owns no Service of type LoadBalancer outside its service range and no PersistentVolume of a CSI driver other than LINSTOR's"
      if ((linstor_volumes == 1)); then
        counted="1 PersistentVolume of LINSTOR ($linstor_driver), whose data is on the workers' data volumes in $stack: it is"
      else
        counted="$linstor_volumes PersistentVolumes of LINSTOR ($linstor_driver), whose data is on the workers' data volumes in $stack: they are"
      fi
      infra_say "$cluster has $counted destroyed with the stack, and confirming its destroy confirms that"
    fi
  elif ((unreachable)); then
    infra_say "$why; with --unreachable it is destroyed without being asked, and a load balancer or volume it owns stays in the cloud"
  else
    infra_error "$why, so $cluster cannot be asked whether it owns load balancers or volumes, which are not in the state of $stack. Nothing was destroyed; --unreachable destroys it without asking, leaving any it owns in the cloud"
    return 1
  fi
}

# infra_say MESSAGE: MESSAGE on stdout, after the name of the script, as infra_error does on stderr.
infra_say() {
  printf '%s: %s\n' "${0##*/}" "$1"
}

# inside_repository PATH: whether PATH, with symlinks resolved, lies in the repository.
inside_repository() {
  local resolved root
  resolved=$(realpath -m -- "$1")
  root=$(realpath -m -- "$infra_root")
  [[ $resolved == "$root" || $resolved == "$root"/* ]]
}

# require_age_key: the Talos age key's location is set, as SOPS_AGE_KEY holding the key (CI) or
# SOPS_AGE_KEY_FILE naming a file outside the repository. sops reads either itself.
require_age_key() {
  if [[ -n ${SOPS_AGE_KEY_FILE:-} ]] && inside_repository "$SOPS_AGE_KEY_FILE"; then
    infra_error "SOPS_AGE_KEY_FILE names a path inside the repository; the Talos age key is kept outside it"
    return 1
  fi
  if [[ -n ${SOPS_AGE_KEY:-} ]]; then
    return 0
  fi
  if [[ -z ${SOPS_AGE_KEY_FILE:-} ]]; then
    infra_error "neither SOPS_AGE_KEY_FILE nor SOPS_AGE_KEY is set; set SOPS_AGE_KEY_FILE in .env or the environment"
    return 1
  fi
  if [[ ! -f $SOPS_AGE_KEY_FILE ]]; then
    infra_error "SOPS_AGE_KEY_FILE names no file; just cluster-age-key creates the key there"
    return 1
  fi
}

# sops_recipient: the age recipient talos/.sops.yaml encrypts secrets bundles to.
sops_recipient() {
  yq '.creation_rules[0].age // ""' "$sops_config"
}

# bundle_encrypted FILE: whether FILE is SOPS-encrypted: it carries SOPS metadata, which is what
# sops filestatus reads, and every value in it is sops ciphertext. Nothing of FILE is printed.
bundle_encrypted() {
  local status counts values plaintext
  status=$(sops filestatus "$1" 2> /dev/null) || return 1
  jq -e '.encrypted == true' <<< "$status" > /dev/null || return 1
  # How many values there are, and how many of them are not ciphertext.
  counts=$(yq 'del(.sops) | [.. | select(kind == "scalar")]
    | [length, (map(select(tag != "!!str" or (test("^ENC\\[") | not))) | length)] | join(" ")' "$1" 2> /dev/null) || return 1
  read -r values plaintext <<< "$counts"
  [[ $values =~ ^[0-9]+$ && $plaintext == 0 ]] && ((values > 0))
}

# talman_nodes TALMAN_FILE: each node in TALMAN_FILE as its hostname and the address talman reaches
# it on, one node per line, in the file's order. Fails, naming the file, when a node lacks either or
# the file lists none.
talman_nodes() {
  local nodes line
  nodes=$(yq '.nodes[] | (.hostname // "") + " " + (.ipAddress // "")' "$1") || return 1
  if [[ -z $nodes ]]; then
    infra_error "${1#"$infra_root"/} lists no nodes"
    return 1
  fi
  while IFS= read -r line; do
    if [[ ! $line =~ ^[a-z0-9][a-z0-9.-]*\ [A-Za-z0-9.:-]+$ ]]; then
      infra_error "${1#"$infra_root"/} has a node without a hostname or an address"
      return 1
    fi
  done <<< "$nodes"
  printf '%s\n' "$nodes"
}

# talos_api_answers ADDRESS: whether ADDRESS accepts a connection on the Talos API port, 50000,
# within three seconds. A node in maintenance mode answers on the same port.
talos_api_answers() {
  # shellcheck disable=SC2016 # the inner bash expands $1, its own argument, so no address is code
  timeout 3 bash -c ': < "/dev/tcp/$1/50000"' talos-api "$1" 2> /dev/null
}

# wait_for_talos_api TALMAN_FILE: waits until every node in TALMAN_FILE answers on the Talos API
# port, trying those still silent every ten seconds, for up to TALOS_WAIT seconds (600 when unset).
# Fails naming the nodes that never answered, by hostname only, as their addresses belong to the
# deployment. A node that never answers is the operator's to reboot; nothing here reboots it.
wait_for_talos_api() {
  local wait=${TALOS_WAIT:-600} nodes node address deadline names
  local -a waiting silent
  nodes=$(talman_nodes "$1") || return 1
  mapfile -t waiting <<< "$nodes"
  deadline=$((SECONDS + 10#$wait))
  while :; do
    silent=()
    for node in "${waiting[@]}"; do
      address=${node#* }
      talos_api_answers "$address" || silent+=("$node")
    done
    ((${#silent[@]} > 0)) || return 0
    names=$(printf '%s\n' "${silent[@]%% *}" | paste -sd, - | sed 's/,/, /g')
    if ((SECONDS >= deadline)); then
      infra_error "no answer on the Talos API port after ${wait}s from $names; reboot a node that does not answer, and run this again"
      return 1
    fi
    echo "waiting for the Talos API to answer on $names"
    waiting=("${silent[@]}")
    sleep 10
  done
}

# require_kubeconfig: the cluster's kubeconfig, which KUBECONFIG names, exists.
require_kubeconfig() {
  if [[ ! -f $KUBECONFIG ]]; then
    infra_error "${KUBECONFIG#"$infra_root"/} does not exist; just cluster-kubeconfig fetches it"
    return 1
  fi
}

# cluster_talman_drain_off ARG...: cluster_talman with ARG... and talosctl's own drain turned off.
# talosctl drains through the cluster endpoint, the API load balancer's address on the node network,
# which only the nodes reach, so the recipes drain with drain_node instead. talosctl upgrade drains
# by default; talosctl reboot does not, and is told so all the same.
cluster_talman_drain_off() {
  cluster_talman "$@" --extra-flags=--drain=false
}

# drain_node NODE: cordons NODE and evicts its pods with kubectl through the kubeconfig, which points
# at the API load balancer, leaving DaemonSets' pods and dropping emptyDir data, for up to ten
# minutes. kubectl's output names the node and the pods it evicts and passes through. Its errors do
# too, line by line as they come, through redact_stream (scripts/lib/errors.sh), as they can name the
# API server's address when it cannot be reached; the reason stays.
drain_node() {
  local status
  { kubectl drain "$1" --ignore-daemonsets --delete-emptydir-data --timeout=10m 2>&1 1>&3 3>&- |
    redact_stream >&2; status=${PIPESTATUS[0]}; } 3>&1
  return "$status"
}

# A worker leaves BGP before it is drained or rebooted: the label under which the cluster's
# CiliumBGPClusterConfig stops selecting a node (kubernetes/apps/base/kube-system/cilium-bgp). A
# kubelet may not set or remove a label under this key on its own Node (NodeRestriction admission).
# The node's Cilium agent copies its Node's labels to its CiliumNode, which the operator matches the
# selector against; the operator then deletes the node's CiliumBGPNodeConfig, and the agent, which
# acts on that, withdraws its routes and stops its BGP server, which sends a notification to each
# peer, so the edge routers withdraw its paths at once, where a node that stops or reboots with its
# sessions up has its paths kept as stale for the whole graceful restart time. A node whose agent is
# not running takes up no label, so its CiliumBGPNodeConfig stays. docs/infrastructure.md cites
# Cilium's source for each step. tests/install-cilium.bats fails when the selector and this key
# differ.
bgp_out_label="node-restriction.kubernetes.io/bgp-out"
# The workers this run has left out of BGP and not put back, for bgp_report_out.
bgp_left_out=()
# For each worker leave_bgp took out: whether it had a CiliumBGPNodeConfig, and which of its peers
# were established, as bgp_established_peers names them, so join_bgp waits for those again.
declare -gA bgp_had_config=() bgp_had_peers=()

# require_bgp_wait: fails unless BGP_WAIT, how long the recipes wait for a node's BGP state to follow
# its label, is a whole number of seconds.
require_bgp_wait() {
  if [[ ! ${BGP_WAIT:-120} =~ ^[0-9]+$ ]]; then
    infra_error "BGP_WAIT is not a whole number of seconds"
    return 1
  fi
}

# bgp_say MESSAGE: a line of the recipe's progress.
bgp_say() {
  printf '%s: %s\n' "${0##*/}" "$1"
}

# bgp_read_config NODE: NODE's CiliumBGPNodeConfig as JSON, nothing when there is none. The operator
# makes one for each node the cluster configuration selects and removes it when it stops selecting
# the node, and its status holds the state of each peer's session. Read through the API with the
# access the recipes have already; the agent's own view (cilium bgp peers, through kubectl exec)
# needs more, and the edge routers' needs SSH and prints addresses, so just edge-routes shows that
# side to a person. Fails, saying nothing, when the API does not answer: an object that cannot be
# read is not one that is gone.
bgp_read_config() {
  kubectl get ciliumbgpnodeconfig "$1" --ignore-not-found --output json --request-timeout=10s 2> /dev/null
}

# bgp_established_peers: from a CiliumBGPNodeConfig on standard input, each peer whose session is
# established, as INSTANCE/PEER, one per line. status.bgpInstances[].peers[].peeringState is the
# agent's report, which it makes while bgpControlPlane.statusReport is on (the chart's default,
# which kubernetes/apps/base/kube-system/cilium/app/values.yaml sets and tests/install-cilium.bats
# checks).
bgp_established_peers() {
  jq -r '.status.bgpInstances[]? | .name as $instance | .peers[]? | select(.peeringState == "established") | "\($instance)/\(.name)"' 2> /dev/null
}

# wait_bgp NODE absent | wait_bgp NODE present [PEER...]: waits for up to BGP_WAIT seconds (120),
# checked every two and once at least, until NODE has no CiliumBGPNodeConfig, or has one in which
# every PEER is established. Fails with 1 when the time runs out and with 2 when it runs out with
# the last read having failed, which is not the same as the state not having come. The time is read
# with date +%s, so a test's clock bounds the wait.
wait_bgp() {
  local node=$1 want=$2 deadline config established peer missing result
  deadline=$(($(date +%s) + ${BGP_WAIT:-120}))
  shift 2
  while :; do
    result=2
    if config=$(bgp_read_config "$node"); then
      result=1
      if [[ $want == absent ]]; then
        [[ -n $config ]] || return 0
      elif [[ -n $config ]]; then
        established=$(bgp_established_peers <<< "$config")
        missing=0
        for peer; do
          grep -qxF -- "$peer" <<< "$established" || missing=1
        done
        ((!missing)) && return 0
      fi
    fi
    (($(date +%s) < deadline)) || return "$result"
    sleep 2
  done
}

# bgp_workers_out: the workers carrying the opt-out label, one per line, as NAME and then idle when
# the worker is Ready and schedulable, busy otherwise. Fails when the API does not answer.
bgp_workers_out() {
  local nodes
  nodes=$(kubectl get nodes --output json --request-timeout=10s 2> /dev/null) || return 1
  jq -r --arg key "$bgp_out_label" '.items[]
    | select((.metadata.labels // {}) | has("node-role.kubernetes.io/control-plane") | not)
    | select((.metadata.labels // {}) | has($key))
    | "\(.metadata.name) \(if any(.status.conditions[]?; .type == "Ready" and .status == "True") and ((.spec.unschedulable // false) | not) then "idle" else "busy" end)"' <<< "$nodes"
}

# bgp_note_out NODE: adds NODE to bgp_left_out unless it is there.
bgp_note_out() {
  local each
  for each in "${bgp_left_out[@]}"; do
    [[ $each != "$1" ]] || return 0
  done
  bgp_left_out+=("$1")
}

# leave_bgp NODE WAIT: takes the worker NODE out of BGP and, unless WAIT is 0, waits until its
# CiliumBGPNodeConfig is gone. A node that is out already, as after a run that stopped, is
# recognised and waited for all the same; no other worker may be out, as no more than one is at a
# time, and then nothing is changed. WAIT 0, a recipe's --no-bgp-wait, is for a worker whose Cilium
# agent is not running, whose configuration then stays: the label is set all the same, the
# configuration is not read, and the recipe says what that can cost. From the label on, NODE is in
# bgp_left_out until join_bgp puts it back.
leave_bgp() {
  local node=$1 wait=$2 out name state carries=0 others=0 config waited=0
  step="reading which workers are out of BGP"
  if ! out=$(bgp_workers_out); then
    infra_error "kubectl could not read the nodes through the kubeconfig; nothing was changed"
    return 1
  fi
  step="taking $node out of BGP"
  while read -r name state; do
    [[ -n $name ]] || continue
    if [[ $name == "$node" ]]; then
      carries=1
    else
      bgp_note_out "$name"
      others=1
    fi
  done <<< "$out"
  if ((others)); then
    infra_error "$node is not taken out of BGP while another worker is out, as no more than one is at a time; nothing was changed"
    return 1
  fi
  if ((carries)); then
    bgp_say "$node is out of BGP already"
  else
    if ((wait)); then
      if ! config=$(bgp_read_config "$node"); then
        infra_error "kubectl could not read the BGP configuration of $node through the kubeconfig; nothing was changed"
        return 1
      fi
      bgp_had_config[$node]=0 bgp_had_peers[$node]=
      if [[ -n $config ]]; then
        bgp_had_config[$node]=1
        bgp_had_peers[$node]=$(bgp_established_peers <<< "$config" | paste -sd' ' -)
      fi
    fi
    if ! kubectl label node "$node" "$bgp_out_label=true" > /dev/null 2>&1; then
      infra_error "kubectl could not label $node out of BGP; nothing was changed"
      return 1
    fi
  fi
  bgp_note_out "$node"
  if ((!wait)); then
    bgp_say "not waiting for the CiliumBGPNodeConfig of $node to be gone (--no-bgp-wait), so the edge routers may keep its paths as stale for up to the restart time"
    return 0
  fi
  step="waiting for the BGP configuration of $node to be gone"
  wait_bgp "$node" absent || waited=$?
  if ((waited == 1)); then
    infra_error "the CiliumBGPNodeConfig of $node is still there after ${BGP_WAIT:-120}s, as when its Cilium agent is not running to take up the label; BGP_WAIT sets how long to wait, and --no-bgp-wait goes on without waiting"
    return 1
  elif ((waited != 0)); then
    infra_error "kubectl could not read the BGP configuration of $node through the kubeconfig, so it is not known whether its BGP configuration is gone"
    return 1
  fi
  bgp_say "the BGP configuration of $node is gone, so its agent closes its sessions with a notification and the edge routers withdraw its paths at once (just edge-routes shows their side)"
}

# join_bgp NODE: puts the worker NODE back in BGP and waits until its CiliumBGPNodeConfig is back and
# the peers that were established before leave_bgp took it out are again; when that is not known, as
# for a node that was out already or one taken out with --no-bgp-wait, only until its configuration
# is back. Once the label is gone the node is no longer out, whether or not it announces yet.
join_bgp() {
  local node=$1 still_out=() each peers waited=0
  step="putting $node back in BGP"
  if ! kubectl label node "$node" "$bgp_out_label-" > /dev/null 2>&1; then
    infra_error "kubectl could not remove the label that has $node out of BGP"
    return 1
  fi
  for each in "${bgp_left_out[@]}"; do
    [[ $each == "$node" ]] || still_out+=("$each")
  done
  bgp_left_out=("${still_out[@]}")
  # Sessions that were down before, as while the edge stack is not built or an edge is stopped or
  # being replaced, are no sign of a node that did not come back.
  if [[ ${bgp_had_config[$node]-} == 0 ]]; then
    bgp_say "$node had no BGP configuration before it was taken out, so it does not wait for one"
    return 0
  fi
  step="waiting for $node to announce again"
  read -ra peers <<< "${bgp_had_peers[$node]-}"
  wait_bgp "$node" present "${peers[@]}" || waited=$?
  if ((waited == 1)); then
    infra_error "$node does not announce again within ${BGP_WAIT:-120}s: its BGP configuration is not back, or its sessions are not established again; BGP_WAIT sets how long to wait"
    return 1
  elif ((waited != 0)); then
    infra_error "kubectl could not read the BGP configuration of $node through the kubeconfig, so it is not known whether $node announces again"
    return 1
  fi
  if [[ -z ${bgp_had_config[$node]-} ]]; then
    bgp_say "the BGP configuration of $node is back; which of its sessions were established before it was taken out is not known, so none is waited for"
  elif [[ -z ${bgp_had_peers[$node]-} ]]; then
    bgp_say "$node had no established BGP session before it was taken out, so it does not wait for one now that it is back"
  else
    bgp_say "$node announces again"
  fi
}

# bgp_report_out: for each worker this run left out of BGP and did not put back, says so and which
# command puts it back; a recipe calls it last when it stops.
bgp_report_out() {
  local node
  for node in "${bgp_left_out[@]}"; do
    infra_error "$node is out of BGP; kubectl label node $node $bgp_out_label- puts it back"
  done
}

# bgp_report_labelled: bgp_report_out for the workers that carry the label now, as read from the
# API, for a recipe that runs another which may have left one out, as cluster-talos --reboot runs
# cluster-reboot; says nothing when the API does not answer.
bgp_report_labelled() {
  local out name _
  out=$(bgp_workers_out) || return 0
  bgp_left_out=()
  while read -r name _; do
    [[ -z $name ]] || bgp_left_out+=("$name")
  done <<< "$out"
  bgp_report_out
}

# Nothing records which run set a worker's label, or whether that run is still working on it, so a
# worker a run that stopped left out and one another run is taking out look the same. A recipe
# therefore removes a label it did not set only once the operator has confirmed the run
# (bgp_settle_left_out), and otherwise only reports it (bgp_check_left_out); cluster-reboot, run
# again for the worker that is out, puts it back after the reboot as one it took out itself.

# bgp_settle_left_out: once the operator has confirmed the run, puts back each worker that carries
# the label although this run did not set it, when it is Ready and schedulable; any other stays out,
# and is left in bgp_left_out for bgp_report_out. Fails when the API does not answer.
bgp_settle_left_out() {
  local out name state
  step="reading which workers are out of BGP"
  if ! out=$(bgp_workers_out); then
    infra_error "kubectl could not read the nodes through the kubeconfig, so it is not known whether a worker is out of BGP"
    return 1
  fi
  while read -r name state; do
    [[ -n $name ]] || continue
    bgp_note_out "$name"
    if [[ $state == idle ]]; then
      bgp_say "$name is out of BGP by a label this run did not set, and is Ready and schedulable; putting it back, as the run is confirmed"
      join_bgp "$name"
    fi
  done <<< "$out"
}

# bgp_check_left_out WHY: for a run that asked nothing: fails while a worker carries the label,
# saying for each that it is out of BGP and WHY it is not put back, and leaving it in bgp_left_out
# for bgp_report_out. Fails when the API does not answer.
bgp_check_left_out() {
  local out name _
  step="checking that no worker is out of BGP"
  if ! out=$(bgp_workers_out); then
    infra_error "kubectl could not read the nodes through the kubeconfig, so it is not known whether a worker is out of BGP"
    return 1
  fi
  while read -r name _; do
    [[ -n $name ]] || continue
    infra_error "$name is out of BGP; $1"
    bgp_note_out "$name"
  done <<< "$out"
  ((${#bgp_left_out[@]} == 0))
}

# not_ready_since SINCE HOSTNAME...: the HOSTNAMEs that are not a Ready node whose kubelet has
# reported since SINCE, a UTC time as Kubernetes writes it, comma-separated; nothing when every one
# is. A Ready condition from before SINCE does not count, as etcd keeps a node's last report while
# the node is away. Fails when the API does not answer through the kubeconfig.
not_ready_since() {
  local since=$1 nodes
  shift
  nodes=$(kubectl get nodes --output json --request-timeout=10s 2> /dev/null) || return 1
  jq -r --arg since "$since" '
    [.items[] | select(any(.status.conditions[]?;
        .type == "Ready" and .status == "True" and .lastHeartbeatTime >= $since))
      | .metadata.name] as $ready
    | [$ARGS.positional[] | select(IN($ready[]) | not)] | join(", ")' --args "$@" <<< "$nodes"
}

# etcd_status_healthy COUNT: whether the table talosctl etcd status prints on standard input, a row
# for each member asked, has COUNT rows and shows every member following the same leader in the same
# term as a voting member, with no error, such as having no leader. Columns are padded with three
# spaces or more; a value holds single spaces only. The columns are read by position, so the table
# must be the one talosctl 1.14 prints: twelve columns, ERRORS last.
etcd_status_healthy() {
  awk -F '   +' -v count="$1" '
    NR == 1 { if (NF != 12 || $1 != "NODE" || $5 != "LEADER" || $NF != "ERRORS") { unknown = 1; exit } next }
    { rows++
      if (rows == 1) { leader = $5; term = $7 } else if ($5 != leader || $7 != term) bad = 1
      if ($5 ~ /^0+$/ || $9 != "false" || $12 != "") bad = 1 }
    END { exit unknown || !(rows == count && !bad) }'
}

# etcd_members_are HOSTNAME...: whether the members in the table talosctl etcd members prints on
# standard input are exactly the HOSTNAMEs, the control planes of talman.yaml: a member etcd holds
# besides them, as of a control plane removed without its member, counts toward its quorum. When
# they are not, it says why, naming members by hostname, never by address.
etcd_members_are() {
  awk -F '   +' '
    BEGIN { for (i = 1; i < ARGC; i++) { want[ARGV[i]] = 1; names[i] = ARGV[i] } count = ARGC - 1; ARGC = 1 }
    NR == 1 { if ($3 != "HOSTNAME") unknown = 1; next }
    { if ($3 in want) seen[$3] = 1; else extra = extra (extra == "" ? "" : ", ") $3 }
    END {
      if (unknown || NR == 0) { print "etcd members printed a table this does not read"; exit 1 }
      for (i = 1; i <= count; i++) if (!(names[i] in seen)) missing = missing (missing == "" ? "" : ", ") names[i]
      if (extra != "") said = "etcd holds " extra ", no control plane of talman.yaml"
      if (missing != "") said = said (said == "" ? "" : "; ") "etcd does not list " missing " as a member"
      if (said != "") { print said; exit 1 }
    }' "$@"
}

# Where the monitoring application's Prometheus runs, and the jobs that scrape the cluster's own
# components, as the application's kube-prometheus-stack chart names them: the Service of its
# Prometheus and the job label of the API server, the controller manager, the scheduler, etcd, the
# kubelets and node-exporter. tests/monitoring.bats renders the chart and fails when one is renamed.
# shellcheck disable=SC2034 # read by scripts/cluster-check and tests/monitoring.bats
prometheus_namespace=monitoring prometheus_service=kube-prometheus-stack-prometheus prometheus_port=9090
# shellcheck disable=SC2034 # read by scripts/cluster-check and tests/monitoring.bats
scrape_jobs=(apiserver kube-controller-manager kube-scheduler kube-etcd kubelet node-exporter)

# The settings of a node that take effect only when it reboots. Talos' documentation of editing the
# machine configuration, for the version in versions.yaml
# (https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/editing-machine-configuration),
# says a configuration is always applied to the running node without a reboot, and names what a
# running node does not take up, as a service reads it only when it starts and Talos does not restart
# it:
#   - .cluster.etcd: etcd's image, extra arguments and advertised and listen subnets;
#   - kernel modules (.machine.kernel.modules, KernelModuleConfig): Talos never unloads a module and
#     sets a module's parameters only when it first loads it, so a module removed stays loaded and a
#     loaded one keeps its parameters; a module added is loaded at once;
#   - environment variables (.machine.env, EnvironmentConfig), which a running service keeps;
#   - the sandbox (SecurityProfileConfig);
#   - volume encryption keys, a new one taking a reboot to re-encrypt the volume.
# The first two, which the patches in talos/patches/ set, are read back: for each node the dry run
# shows a change on, reboot_state reads what Talos derives from them, the resources
# EtcdConfigs.etcd.talos.dev and KernelModuleSpecs.runtime.talos.dev, which hold no secret, before
# the configuration is applied and again once the node runs it, and a node on which they differ runs
# the old setting until it reboots (reboot_pending). The other three are not read back, as their
# values can be secrets, and no patch sets them: reboot_unwatched names them in a patch, and a test
# fails when a patch sets one. The page calls its list not exhaustive; a setting found to need a
# reboot that is missing here is added. It also names UnattendedInstallConfig and .machine.install,
# which talos/patches/all/install.yaml sets, as used only when Talos installs or upgrades itself,
# with no effect on an installed node even after a reboot: they are not on the list, and
# just cluster-upgrade is what applies them.
#
# What changes is read from Talos, not from the diff the dry run prints: a unified diff has three
# lines of context around a change, so the section a changed line belongs to is not in it.

# reboot_only_program: the jq program reboot_pending runs on the two states it compares.
# shellcheck disable=SC2016 # a jq program
reboot_only_program='
  .[0] as $before | .[1] as $after
  | (if $before.etcd != $after.etcd then "etcd as it was started" else empty end),
    (if any($before.modules | to_entries[]; ($after.modules[.key] // null) as $now
        | $now == null or ($now | sort) != (.value | sort))
      then "its kernel modules as they were loaded" else empty end)'

# reboot_unwatched: a yq expression that, over the documents of a machine configuration patch, names
# each setting on the list above that the rollout does not read back. Each name is made from the
# document, as yq yields a bare string even where select yielded nothing.
# shellcheck disable=SC2016,SC2034 # a yq expression, read by tests/cluster-recipes.bats
reboot_unwatched='
  (select(.machine.env != null) | .machine.env | path | join(".")),
  (select(.kind == "EnvironmentConfig" or .kind == "SecurityProfileConfig") | .kind),
  (select(.machine.systemDiskEncryption != null) | .machine.systemDiskEncryption | path | join(".")),
  (select(.encryption != null) | .kind + " encryption")'

# reboot_state NODE ROLE: what NODE, whose role in talman.yaml is ROLE, holds of the settings on the
# list above that the rollout reads back, asked of its Talos API through talman, as one line of JSON:
# etcd's configuration, which only a control plane has, and each kernel module Talos loads, with its
# parameters. Neither resource holds a secret; they name the node's subnets, and stay in variables and
# pipes, never printed. Fails, saying nothing, when NODE does not answer with them: what talosctl says
# then names addresses.
reboot_state() {
  local etcd='' modules
  if [[ $2 == controlplane ]]; then
    etcd=$(talman talosctl -n "$1" get EtcdConfigs.etcd.talos.dev etcd --output json 2> /dev/null) || return 1
  fi
  modules=$(talman talosctl -n "$1" get KernelModuleSpecs.runtime.talos.dev --output json 2> /dev/null) || return 1
  printf '%s\n%s\n' "$etcd" "$modules" | jq -cs --arg role "$2" '
    (map(select(.metadata.type? == "EtcdConfigs.etcd.talos.dev")) | if length == 1 then .[0].spec else null end) as $etcd
    | if $role == "controlplane" and $etcd == null then error("no etcd configuration") else . end
    | {etcd: $etcd, modules: (map(select(.metadata.type? == "KernelModuleSpecs.runtime.talos.dev")
        | {key: .metadata.id, value: (.spec.parameters // [])}) | from_entries)}' 2> /dev/null
}

# reboot_pending BEFORE AFTER: what a node runs until it reboots, one per line, when AFTER, what it
# holds of those settings once it runs a configuration (reboot_state), differs from BEFORE, what it
# held before; nothing when they agree.
reboot_pending() {
  printf '%s\n%s\n' "$1" "$2" | jq -rs "$reboot_only_program"
}

# new_nodes DRY_RUN: the hostnames of the nodes whose block of the dry run DRY_RUN, as changed_nodes
# reads it, is a new node's, one per line.
new_nodes() {
  awk '/^== \[[0-9?]+\/[0-9]+\] / && /\) ·/ { print $3 }' <<< "$1"
}

# changed_nodes DRY_RUN: the hostnames of the nodes whose block of the dry run DRY_RUN, as talman
# prints it, does not say the node is unchanged, one per line, in the order of the blocks, which is
# talman.yaml's; not those that are new, which run no configuration to change. A block starts at a
# header "== [i/n] HOSTNAME (ADDRESS)", with a note after the address for a new node, and says "No
# changes." after its "Config diff:", or, from a talman that cannot hide the cluster's secrets in a
# diff, "no changes" in place of the diff, as it says "changes; diff not shown" for a change. The
# address is not printed.
changed_nodes() {
  awk '
    function finish() { if (node != "" && !note && !same) print node }
    /^== \[[0-9?]+\/[0-9]+\] / { finish(); node = $3; note = ($0 ~ /\) ·/); same = 0; next }
    /^ +(No changes\.|no changes)$/ { same = 1 }
    END { finish() }' <<< "$1"
}

# flux_recipient: the age recipient .sops.yaml encrypts the SOPS files under kubernetes/ to.
flux_recipient() {
  yq '.creation_rules[0].age // ""' "$flux_sops_config"
}

# flux_age_key: the Flux age key, from FLUX_AGE_KEY (CI) or the file FLUX_AGE_KEY_FILE names, for a
# pipe only.
flux_age_key() {
  if [[ -n ${FLUX_AGE_KEY:-} ]]; then
    printf '%s\n' "$FLUX_AGE_KEY"
  else
    cat < "$FLUX_AGE_KEY_FILE"
  fi
}

# require_flux_age_key: .sops.yaml names a recipient, and the Flux age key is set, as FLUX_AGE_KEY
# holding the key (CI) or FLUX_AGE_KEY_FILE naming a file outside the repository, is the key of that
# recipient and is not the Talos age key, which a key held in the cluster must never be. age-keygen
# derives the recipient from the key on its standard input.
require_flux_age_key() {
  local written recipient complete=1
  written=$(flux_recipient)
  if is_placeholder "$written"; then
    infra_error ".sops.yaml holds no Flux age recipient yet; just cluster-flux-age-key writes it"
    complete=0
  fi
  if [[ -n ${FLUX_AGE_KEY_FILE:-} ]] && inside_repository "$FLUX_AGE_KEY_FILE"; then
    infra_error "FLUX_AGE_KEY_FILE names a path inside the repository; the Flux age key is kept outside it"
    return 1
  fi
  if [[ -z ${FLUX_AGE_KEY:-} ]]; then
    if [[ -z ${FLUX_AGE_KEY_FILE:-} ]]; then
      infra_error "neither FLUX_AGE_KEY_FILE nor FLUX_AGE_KEY is set; set FLUX_AGE_KEY_FILE in .env or the environment"
      return 1
    fi
    if [[ ! -f $FLUX_AGE_KEY_FILE ]]; then
      infra_error "FLUX_AGE_KEY_FILE names no file; just cluster-flux-age-key creates the key there"
      return 1
    fi
  fi
  ((complete)) || return 1
  recipient=$(flux_age_key | age-keygen -y 2> /dev/null) || recipient=
  if [[ ! $recipient =~ ^age1[0-9a-z]+$ ]]; then
    infra_error "the Flux age key is not exactly one age key"
    return 1
  fi
  if [[ $recipient == "$(sops_recipient)" ]]; then
    infra_error "the Flux age key is the Talos age key; Flux gets a key of its own, so the key the cluster holds does not open the Talos secrets bundles"
    return 1
  fi
  if [[ $recipient != "$written" ]]; then
    infra_error "the Flux age key is not the key .sops.yaml encrypts to; point FLUX_AGE_KEY_FILE at that key"
    return 1
  fi
}

# flux_sops ARG...: sops with the Flux age key as its only age key, whichever key the environment
# gives sops for the Talos secrets bundles. The key reaches sops in its environment.
flux_sops() {
  local key=${FLUX_AGE_KEY:-} file=${FLUX_AGE_KEY_FILE:-}
  (
    export -n SOPS_AGE_KEY SOPS_AGE_KEY_FILE SOPS_AGE_KEY_CMD
    if [[ -n $key ]]; then
      SOPS_AGE_KEY=$key sops "$@"
    else
      SOPS_AGE_KEY_FILE=$file sops "$@"
    fi
  )
}

# node_name_regex: from the node names on standard input, one per line, a regular expression (Go RE2
# syntax) that each name matches in full. A name that ends in a number stands for every number: a
# node OpenTofu adds is numbered after the others, and matches without cluster-config changing.
node_name_regex() {
  local name pattern
  local -a patterns=()
  local -A seen=()
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    pattern=$name
    if [[ $name =~ ^(.*[^0-9])[0-9]+$ ]]; then
      pattern="${BASH_REMATCH[1]}[0-9]+"
    fi
    # A hostname holds letters, digits, - and ., of which only . means something in a pattern.
    pattern=${pattern//./\\.}
    if [[ -z ${seen[$pattern]-} ]]; then
      seen[$pattern]=1
      patterns+=("$pattern")
    fi
  done
  ((${#patterns[@]} > 0)) || return 1
  local IFS='|'
  printf '%s\n' "${patterns[*]}"
}

# read_keys FILE EXPRESSION: the keys yq's EXPRESSION yields from FILE, one per line. Fails naming
# FILE when yq cannot read it, as keys read as none would pass every check.
read_keys() {
  if ! yq "$2" "$1" 2> /dev/null; then
    infra_error "cannot read the keys of ${1#"$infra_root"/}"
    return 1
  fi
}

# The values of the ConfigMap cluster-config, by key, once fill_cluster_config has run.
declare -A cluster_config=()

# fill_cluster_config CLUSTER TALMAN_FILE: fills cluster_config, and fails naming each key of the
# cluster's cluster-config.example.yaml it cannot fill and each key it fills that the example does not
# list. Every value depends on the deployment, and none is printed. The ConfigMap itself is never
# committed; the object storage's endpoint and region are, in the backend settings OpenTofu's state
# reads them from.
#   CLUSTER_DOMAIN        the domain the cluster's applications are published under, from the
#                         environment
#   BACKUP_BUCKET_PREFIX  the start of the backup buckets' names, from the environment
#                         (s3_bucket_name_ok)
#   S3_ENDPOINT,          the object storage's S3 endpoint and region, from
#   S3_REGION             infra/openstack/backend.hcl (s3_read_backend)
#   NODE_CIDR             the node subnet, values.nodeSubnet in the cluster's talman.yaml, which the
#                         cluster stack renders and the kubelets take their node addresses from
#   NODE_NAME_REGEX       a pattern of the hostnames in that talman.yaml (node_name_regex)
#   SERVICE_RANGE         the range LoadBalancer Services take their addresses from,
#                         values.serviceRange
#   BGP_CLUSTER_ASN,      the workers' and the edge routers' AS numbers, values.bgp
#   BGP_EDGE_ASN
#   BGP_EDGE_ADDRESS_1,   the edge routers' two addresses, values.bgp
#   BGP_EDGE_ADDRESS_2
#   GATEWAY_ADDRESS       the public Gateway's address, a host of the service range, which the edge
#                         routers forward public traffic to, values.bgp.gatewayAddress
# The last six the cluster stack renders from the plumbing stack's numbers for BGP (ADR 0013).
# A missing talman.yaml leaves its keys to the caller's require_cluster, which names the file.
fill_cluster_config() {
  local cluster=$1 talman=$2 example value keys key complete=1 i
  local dns_name='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
  local ipv4='([0-9]{1,3}\.){3}[0-9]{1,3}'
  local -a listed=() edges=()
  local -A sources=([CLUSTER_DOMAIN]=1 [BACKUP_BUCKET_PREFIX]=1 [S3_ENDPOINT]=1 [S3_REGION]=1
    [NODE_CIDR]=1 [NODE_NAME_REGEX]=1 [SERVICE_RANGE]=1 [BGP_CLUSTER_ASN]=1 [BGP_EDGE_ASN]=1
    [BGP_EDGE_ADDRESS_1]=1 [BGP_EDGE_ADDRESS_2]=1 [GATEWAY_ADDRESS]=1) wanted=()
  example=$infra_root/kubernetes/clusters/$cluster/cluster-config.example.yaml
  cluster_config=()
  if [[ ! -f $example ]]; then
    infra_error "${example#"$infra_root"/} does not exist; it lists the keys of cluster-config"
    return 1
  fi

  if require_env CLUSTER_DOMAIN; then
    if [[ $CLUSTER_DOMAIN =~ $dns_name ]]; then
      cluster_config[CLUSTER_DOMAIN]=$CLUSTER_DOMAIN
    else
      infra_error "cannot fill CLUSTER_DOMAIN of cluster-config: CLUSTER_DOMAIN is not a lower-case DNS name"
      complete=0
    fi
  else
    complete=0
  fi
  if require_env BACKUP_BUCKET_PREFIX && s3_bucket_name_ok BACKUP_BUCKET_PREFIX prefix; then
    cluster_config[BACKUP_BUCKET_PREFIX]=$BACKUP_BUCKET_PREFIX
  else
    complete=0
  fi
  if s3_read_backend; then
    cluster_config[S3_ENDPOINT]=$s3_endpoint
    cluster_config[S3_REGION]=$s3_region
  else
    infra_error "cannot fill S3_ENDPOINT and S3_REGION of cluster-config from infra/openstack/backend.hcl"
    complete=0
  fi
  if [[ -f $talman ]]; then
    value=$(yq '.values.nodeSubnet // ""' "$talman" 2> /dev/null) || value=
    if [[ $value =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
      cluster_config[NODE_CIDR]=$value
    else
      infra_error "cannot fill NODE_CIDR of cluster-config: ${talman#"$infra_root"/} gives no IPv4 network in values.nodeSubnet"
      complete=0
    fi
    if value=$(talman_nodes "$talman" | cut -d' ' -f1 | node_name_regex); then
      cluster_config[NODE_NAME_REGEX]=$value
    else
      infra_error "cannot fill NODE_NAME_REGEX of cluster-config: ${talman#"$infra_root"/} gives no node hostnames"
      complete=0
    fi
    value=$(yq '.values.serviceRange // ""' "$talman" 2> /dev/null) || value=
    if [[ $value =~ ^$ipv4/[0-9]{1,2}$ ]]; then
      cluster_config[SERVICE_RANGE]=$value
    else
      infra_error "cannot fill SERVICE_RANGE of cluster-config: ${talman#"$infra_root"/} gives no IPv4 network in values.serviceRange"
      complete=0
    fi
    for key in clusterASN:BGP_CLUSTER_ASN edgeASN:BGP_EDGE_ASN; do
      value=$(yq ".values.bgp.${key%%:*} // \"\"" "$talman" 2> /dev/null) || value=
      if [[ $value =~ ^[1-9][0-9]*$ ]]; then
        cluster_config[${key#*:}]=$value
      else
        infra_error "cannot fill ${key#*:} of cluster-config: ${talman#"$infra_root"/} gives no AS number in values.bgp.${key%%:*}"
        complete=0
      fi
    done
    value=$(yq '.values.bgp.edgeAddresses // [] | .[]' "$talman" 2> /dev/null) || value=
    mapfile -t edges < <(printf '%s' "$value")
    if ((${#edges[@]} == 2)) && [[ ${edges[0]} =~ ^$ipv4$ && ${edges[1]} =~ ^$ipv4$ ]]; then
      for i in 0 1; do
        cluster_config[BGP_EDGE_ADDRESS_$((i + 1))]=${edges[i]}
      done
    else
      infra_error "cannot fill BGP_EDGE_ADDRESS_1 and BGP_EDGE_ADDRESS_2 of cluster-config: ${talman#"$infra_root"/} gives no two IPv4 addresses in values.bgp.edgeAddresses"
      complete=0
    fi
    value=$(yq '.values.bgp.gatewayAddress // ""' "$talman" 2> /dev/null) || value=
    if [[ $value =~ ^$ipv4$ ]]; then
      cluster_config[GATEWAY_ADDRESS]=$value
    else
      infra_error "cannot fill GATEWAY_ADDRESS of cluster-config: ${talman#"$infra_root"/} gives no IPv4 address in values.bgp.gatewayAddress"
      complete=0
    fi
  fi

  keys=$(read_keys "$example" 'keys | .[]') || return 1
  mapfile -t listed < <(printf '%s' "$keys")
  for key in "${listed[@]}"; do
    wanted[$key]=1
    if [[ -z ${sources[$key]-} ]]; then
      infra_error "cannot fill $key of cluster-config: nothing in scripts/lib/cluster.sh gives it a value"
      complete=0
    fi
  done
  for key in "${!sources[@]}"; do
    if [[ -z ${wanted[$key]-} ]]; then
      infra_error "cluster-config would set $key, which ${example#"$infra_root"/} does not list"
      complete=0
    fi
  done
  ((complete))
}

# cluster_config_manifest: the ConfigMap cluster-config in flux-system, as JSON, from cluster_config.
# The values reach jq on its standard input.
cluster_config_manifest() {
  local key
  for key in "${!cluster_config[@]}"; do
    printf '%s\0%s\0' "$key" "${cluster_config[$key]}"
  done | jq -Rs '
    split("\u0000") | .[:-1] | [range(0; length; 2) as $i | {key: .[$i], value: .[$i + 1]}]
    | {apiVersion: "v1", kind: "ConfigMap", metadata: {name: "cluster-config", namespace: "flux-system"},
       data: from_entries}'
}

# cluster_secrets_file CLUSTER: where the cluster's SOPS-encrypted cluster-secrets is committed.
cluster_secrets_file() {
  printf '%s\n' "$infra_root/kubernetes/clusters/$1/secrets/cluster-secrets.sops.yaml"
}

# check_cluster_secrets CLUSTER: the cluster's secrets/cluster-secrets.sops.yaml, when it exists, is
# the Secret cluster-secrets for flux-system, SOPS-encrypted, and holds exactly the keys
# cluster-secrets.example.yaml lists; without it, the example lists none. sops encrypts values only,
# so the keys are read without decrypting anything.
check_cluster_secrets() {
  local file example keys key name complete=1
  local -a listed=() held=()
  local -A in_example=() in_file=()
  file=$(cluster_secrets_file "$1")
  name=${file#"$infra_root"/}
  example=$infra_root/kubernetes/clusters/$1/cluster-secrets.example.yaml
  if [[ -f $file ]]; then
    if ! sops filestatus "$file" 2> /dev/null | jq -e '.encrypted == true' > /dev/null; then
      infra_error "$name is not SOPS-encrypted; encrypt it, or remove it without committing it"
      return 1
    fi
    if ! yq -e '.kind == "Secret" and .metadata.name == "cluster-secrets"
      and (.metadata.namespace // "flux-system") == "flux-system"' "$file" > /dev/null 2>&1; then
      infra_error "$name is not the Secret cluster-secrets for flux-system"
      return 1
    fi
    keys=$(read_keys "$file" '(.data // {}) * (.stringData // {}) | keys | .[]') || return 1
    mapfile -t held < <(printf '%s' "$keys")
  fi
  keys=$(read_keys "$example" 'keys | .[]') || return 1
  mapfile -t listed < <(printf '%s' "$keys")
  for key in "${held[@]}"; do
    in_file[$key]=1
  done
  for key in "${listed[@]}"; do
    in_example[$key]=1
    if [[ -z ${in_file[$key]-} ]]; then
      if [[ -f $file ]]; then
        infra_error "cannot fill $key of cluster-secrets: $name does not hold it"
      else
        infra_error "cannot fill $key of cluster-secrets: $name does not exist"
      fi
      complete=0
    fi
  done
  for key in "${held[@]}"; do
    if [[ -z ${in_example[$key]-} ]]; then
      infra_error "cluster-secrets would set $key, which ${example#"$infra_root"/} does not list"
      complete=0
    fi
  done
  ((complete))
}

# require_pre_flux CLUSTER TALMAN_FILE: every object Flux needs before it starts can be made, checked
# offline and before anything else runs, naming each problem: the Flux age key, cluster-config and
# cluster-secrets. Fills cluster_config.
require_pre_flux() {
  local complete=1
  require_flux_age_key || complete=0
  fill_cluster_config "$1" "$2" || complete=0
  check_cluster_secrets "$1" || complete=0
  ((complete))
}

# apply_in_flux_system: applies the object on standard input in flux-system, server-side, so a second
# run with the same object changes nothing and no copy of it is kept in an annotation.
apply_in_flux_system() {
  kubectl apply --server-side --namespace flux-system -f -
}

# require_install_tools: KUBECONFIG names the cluster's kubeconfig, and what installing an
# application runs is on PATH. The kubeconfig reaches kubectl and helm through the environment.
require_install_tools() {
  local kubeconfig tool
  local -a kubeconfigs=()
  if [[ -z ${KUBECONFIG:-} ]]; then
    infra_error "KUBECONFIG is not set: export the path of the cluster's kubeconfig"
    return 1
  fi
  IFS=: read -ra kubeconfigs <<< "$KUBECONFIG"
  for kubeconfig in "${kubeconfigs[@]}"; do
    if [[ -n $kubeconfig && ! -f $kubeconfig ]]; then
      infra_error "KUBECONFIG names $kubeconfig, which is not a file"
      return 1
    fi
  done
  for tool in yq helm kubectl; do
    if ! type -P "$tool" > /dev/null; then
      infra_error "$tool not found on PATH"
      return 1
    fi
  done
}

# substitute FILE: FILE as Flux's post-build substitution makes it, with the data of the ConfigMap
# in JSON on standard input as the only variables, strictly, so a variable with neither a value nor
# a default fails, named. flux envsubst is Flux's own substitution; the values reach it in its
# environment, which holds nothing else, and leave it on standard output.
substitute() {
  local file=$1 flux name value i
  local -a names=() values=()
  flux=$(type -P flux) || {
    infra_error "flux not found on PATH"
    return 1
  }
  # Flux takes only names a shell variable could have; any other would not be exported.
  while IFS= read -r -d '' name && IFS= read -r -d '' value; do
    names+=("$name")
    values+=("$value")
  done < <(jq -j '.data // {} | to_entries[] | select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$"))
    | .key, "\u0000", .value, "\u0000"')
  (
    while IFS= read -r name; do
      export -n "${name?}"
    done < <(compgen -e)
    for i in "${!names[@]}"; do
      export "${names[i]}=${values[i]}"
    done
    exec "$flux" envsubst --strict < "$file"
  )
}

# helmrelease_values FILE: the values the HelmRelease in FILE sets itself, which helm-controller
# merges over those of its valuesFrom, as YAML, {} when it sets none. Where it uses a variable they
# are what Flux makes of them: substituted from the ConfigMap cluster-config on the cluster, as the
# root gives every application, read with kubectl and handed on through pipes only.
helmrelease_values() {
  local file=$1 config
  # shellcheck disable=SC2016 # a literal ${, with which every Flux variable starts
  if ! grep -qF '${' "$file"; then
    yq '.spec.values // {}' "$file"
    return
  fi
  config=$(kubectl get configmap cluster-config --namespace flux-system --ignore-not-found --output json) || return 1
  if [[ -z $config ]]; then
    infra_error "flux-system holds no ConfigMap cluster-config, which ${file#"$infra_root"/} takes variables from; just cluster-config applies it"
    return 1
  fi
  printf '%s' "$config" | substitute "$file" | yq '.spec.values // {}'
}

# managed_by_flux RELEASE NAMESPACE [REVISION]: whether Flux's helm-controller installed or upgraded
# the release last, or, given REVISION, made that revision. Its post-renderer labels every object it
# renders with helm.toolkit.fluxcd.io/name and helm.toolkit.fluxcd.io/namespace, the HelmRelease's
# (helm-controller v1.7.1, which the pinned Flux runs: internal/postrender/build.go and
# common_renderer.go), and helm keeps the rendered objects in the manifest of each revision. Returns
# 1 when they lack the label, and 2 when helm has no manifest: without a release there is none, and
# nothing manages it. Nothing of the manifest is printed.
managed_by_flux() {
  local manifest
  local -a revision=()
  [[ -z ${3-} ]] || revision=(--revision "$3")
  manifest=$(helm get manifest "$1" --namespace "$2" "${revision[@]}" 2> /dev/null) || return 2
  yq ea -e '[select(.metadata.labels["helm.toolkit.fluxcd.io/name"] != null)] | length > 0' <<< "$manifest" > /dev/null 2>&1
}

# app_field FILE PATH: the value at PATH in FILE, which must be set.
app_field() {
  if ! yq -e "$2" "$1" 2> /dev/null; then
    infra_error "cannot read $2 from $1"
    return 1
  fi
}

# app_release DIR: the Helm release that the HelmRelease of the application in DIR, a directory of
# kubernetes/ with the application's ks.yaml beside its app/, makes, as helm-controller makes it
# (GetReleaseName, GetReleaseNamespace and GetStorageNamespace in its api/v2): the HelmRelease's
# releaseName, targetNamespace and storageNamespace where it sets them, and otherwise its name, after
# its targetNamespace and a dash when it has one, and its own namespace, which Flux takes from
# ks.yaml's targetNamespace. Prints, on one line, the release, the namespace it is installed into and
# keeps its history in, the HelmRelease's name and the HelmRelease's namespace. Fails, naming the
# file, when the release has no namespace or would keep its history in another one.
app_release() {
  local dir=$1 app name namespace release target storage
  if [[ ! -f $dir/ks.yaml || ! -f $dir/app/helmrelease.yaml ]]; then
    infra_error "$dir is not an application directory: it has no ks.yaml beside app/helmrelease.yaml"
    return 1
  fi
  app=$(cd "$dir/app" && pwd)
  name=$(app_field "$app/helmrelease.yaml" .metadata.name) || return 1
  namespace=$(yq '.spec.targetNamespace // ""' "$dir/ks.yaml")
  [[ -n $namespace ]] || namespace=$(yq '.metadata.namespace // ""' "$app/helmrelease.yaml")
  if [[ -z $namespace ]]; then
    infra_error "$dir/ks.yaml sets no targetNamespace, and app/helmrelease.yaml no namespace: the release has none"
    return 1
  fi
  release=$(yq '.spec.releaseName // ""' "$app/helmrelease.yaml")
  target=$(yq '.spec.targetNamespace // ""' "$app/helmrelease.yaml")
  storage=$(yq '.spec.storageNamespace // ""' "$app/helmrelease.yaml")
  [[ -n $release ]] || release=${target:+$target-}$name
  storage=${storage:-$namespace}
  # helm keeps a release's history in the namespace it installs into; Flux finds the release
  # installed there only if the HelmRelease looks for it there.
  if [[ $storage != "${target:-$namespace}" ]]; then
    infra_error "helmrelease.yaml installs into ${target:-$namespace} but keeps the history in $storage; helm uses one namespace for both"
    return 1
  fi
  printf '%s %s %s %s\n' "$release" "${target:-$namespace}" "$name" "$namespace"
}

# install_app DIR [YES]: installs the application in DIR, a directory of kubernetes/ with the
# application's ks.yaml beside its app/, on the cluster KUBECONFIG names, as the Helm release its
# HelmRelease adopts once Flux runs (app_release). The chart location and version come from
# app/ocirepository.yaml; the values from app/values.yaml as it is, then the HelmRelease's own values
# as Flux substitutes them (helmrelease_values), on helm's standard input. Waits for the API server
# first. A release that runs that chart version with those values already is left alone, so a second
# run changes nothing. A release Flux manages (managed_by_flux) is refused, as Flux owns it from then
# on, unless YES is 1.
install_app() {
  local dir=$1 yes=${2:-0} app fields namespace url version release values overrides wanted chart installed attempts
  step="reading the application"
  fields=$(app_release "$dir") || return 1
  read -r release namespace _ <<< "$fields"
  app=$(cd "$dir/app" && pwd)
  url=$(app_field "$app/ocirepository.yaml" .spec.url) || return 1
  version=$(app_field "$app/ocirepository.yaml" .spec.ref.tag) || return 1
  values=$app/values.yaml
  if ! yq -e 'tag == "!!map"' "$values" > /dev/null 2>&1; then
    infra_error "$values is not a YAML map of values"
    return 1
  fi
  # helm names an OCI chart after the last element of its location.
  chart=${url##*/}

  step="waiting for the API server"
  printf '%s: waiting for the API server\n' "${0##*/}"
  # Ten minutes, as the control plane may still be starting.
  attempts=0
  until kubectl get --raw /readyz --request-timeout=10s > /dev/null 2>&1; do
    attempts=$((attempts + 1))
    if ((attempts >= 120)); then
      infra_error "no answer on /readyz after $attempts attempts, 5 seconds apart"
      return 1
    fi
    sleep 5
  done

  step="reading the HelmRelease's values"
  overrides=$(helmrelease_values "$app/helmrelease.yaml") || return 1
  # helm merges its values files in order, as helm-controller merges the HelmRelease's own values
  # over those of its valuesFrom.
  # shellcheck disable=SC2016 # $file is a yq variable.
  wanted=$(printf '%s\n' "$overrides" |
    yq ea -o json -I0 '. as $file ireduce ({}; . * $file) | sort_keys(..)' "$values" -) || return 1

  step="checking the installed release"
  installed=$(helm list --namespace "$namespace" --filter "^$release\$" --deployed --output json |
    yq -p json '.[0].chart // ""') || return 1
  if [[ $installed == "$chart-$version" ]] &&
    [[ "$(helm get values "$release" --namespace "$namespace" --output json | yq -p json -o json -I0 'sort_keys(..)')" == "$wanted" ]]; then
    printf '%s: release %s already runs %s %s with these values; nothing to install\n' "${0##*/}" "$release" "$chart" "$version"
    return 0
  fi
  if ((!yes)) && managed_by_flux "$release" "$namespace"; then
    infra_error "release $release in $namespace is managed by Flux's helm-controller, whose label helm.toolkit.fluxcd.io/name its objects carry; installing over it changes what Flux manages, and Flux undoes it. --yes installs anyway"
    return 1
  fi

  step="installing the chart"
  printf '%s: installing %s %s from %s as release %s in %s\n' "${0##*/}" "$chart" "$version" "$url" "$release" "$namespace"
  # Helm's default of five minutes is short for a first install that pulls the images on every node.
  if [[ $overrides == '{}' ]]; then
    helm upgrade --install "$release" "$url" --version "$version" --namespace "$namespace" \
      --values "$values" --wait --timeout 15m || return 1
  else
    printf '%s\n' "$overrides" |
      helm upgrade --install "$release" "$url" --version "$version" --namespace "$namespace" \
        --values "$values" --values - --wait --timeout 15m || return 1
  fi
  printf '%s: %s %s runs as release %s in %s\n' "${0##*/}" "$chart" "$version" "$release" "$namespace"
}
