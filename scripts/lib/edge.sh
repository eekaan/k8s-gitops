# shellcheck shell=bash
# Shared by scripts/edge-check, scripts/edge-routes, scripts/edge-rollout, scripts/infra-apply and
# scripts/infra-destroy: the edge routers' addresses, the SSH connection to them, and which of them a
# plan replaces or creates. Needs scripts/stack-env sourced with sto2/edge, and for edge_connect the
# stack locked and initialised.

# shellcheck source=scripts/lib/infra.sh
. "$(dirname "${BASH_SOURCE[0]}")/infra.sh"
# shellcheck source=scripts/lib/host-keys.sh
. "$(dirname "${BASH_SOURCE[0]}")/host-keys.sh"

# edge_load: reads the edges' names, floating addresses and instance identifiers from the stack's
# outputs. Sets edge_names, edge_addresses, edge_instances (an element is empty when the outputs
# hold no identifier for the edge, or one that is not a UUID) and edge_known_hosts. The addresses
# are never printed.
edge_load() {
  local outputs i
  outputs=$(stack_tofu output -json) || return 1
  # tofu's JSON holds every output's value, sensitive ones included; only jq reads it.
  mapfile -t edge_addresses < <(jq -r '.addresses.value // [] | .[] | strings' <<< "$outputs")
  mapfile -t edge_names < <(jq -r '.names.value // [] | .[] | strings' <<< "$outputs")
  if ((${#edge_addresses[@]} != 2 || ${#edge_names[@]} != 2)); then
    # shellcheck disable=SC2154 # scripts/stack-env sets stack
    infra_error "$stack has no addresses and names outputs for two edges: it is not applied"
    return 1
  fi
  for i in 0 1; do
    if [[ ! ${edge_addresses[i]} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || ! ${edge_names[i]} =~ ^[a-z0-9-]+$ ]]; then
      infra_error "$stack's addresses and names outputs are not two addresses and two names"
      return 1
    fi
  done
  edge_instances=()
  for i in 0 1; do
    edge_instances[i]=$(jq -r --arg number "$((i + 1))" '.instances.value[$number].id // "" | strings' <<< "$outputs")
    [[ ${edge_instances[i]} =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]] || edge_instances[i]=
  done
  edge_known_hosts=${XDG_STATE_HOME:-$HOME/.local/state}/k8s-gitops/edge.known_hosts
}

# edge_connect [NUMBER]: edge_load, and makes sure the SSH host key of edge NUMBER, or of both
# edges, is recorded, as for the CI host: checked against the console of the edge's instance, for up
# to HOST_CONSOLE_WAIT seconds, 30 when unset.
edge_connect() {
  local i
  host_console_wait || return 1
  require_env EDGE_SSH_KEY_FILE || return 1
  if [[ ! -f $EDGE_SSH_KEY_FILE ]]; then
    infra_error "$EDGE_SSH_KEY_FILE does not exist; just edge-ssh-key creates the key pair"
    return 1
  fi
  edge_load || return 1
  for i in 0 1; do
    if [[ -z ${1-} || $1 == $((i + 1)) ]]; then
      ssh_host_trust "${edge_addresses[i]}" "$edge_known_hosts" "edge router ${edge_names[i]}" \
        "${edge_instances[i]}" "$host_console_wait" || return 1
    fi
  done
}

# edge_forget_keys NUMBER...: drops the recorded SSH host keys of the edges, 1 or 2. A new instance,
# a replacement or one created again, has host keys of its own at the same floating address, and
# the connection checks them strictly against what is recorded, so the old ones would refuse it for
# good. Needs edge_load.
edge_forget_keys() {
  local number
  for number; do
    ssh-keygen -R "${edge_addresses[number - 1]}" -f "$edge_known_hosts" > /dev/null 2>&1 || true
    rm -f "$edge_known_hosts.old"
  done
}

# edge_ssh INDEX COMMAND: runs COMMAND, one string, on edge INDEX (0 or 1) as EDGE_SSH_USER, the
# image's default user, debian when unset, with the edges' key only, strict host key checking against
# the recorded keys only, and without asking for a password.
edge_ssh() {
  ssh -i "$EDGE_SSH_KEY_FILE" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$edge_known_hosts" -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no \
    -o ConnectTimeout=30 "${EDGE_SSH_USER:-debian}@${edge_addresses[$1]}" "$2"
}

# edge_planned ACTION: the edge numbers, 1 and 2, whose instance the saved plan's change on it
# includes ACTION, delete or create, one per line, each once. A replacement is both.
edge_planned() {
  # shellcheck disable=SC2154 # scripts/stack-env sets plan_file
  stack_tofu show -json "$plan_file" | jq -r --arg action "$1" '
    [.resource_changes[]?
      | select(.type == "openstack_compute_instance_v2" and (.change.actions | index($action)))
      | .address | capture("^module\\.edge\\[\"(?<number>[0-9]+)\"\\]") | .number]
    | unique[]'
}

# edge_replaced: the edges whose instance the saved plan deletes, replacing it or not.
edge_replaced() {
  edge_planned delete
}

# edge_created: the edges whose instance the saved plan creates: a replacement, or a new instance
# for one that is gone from the cloud. Either has SSH host keys of its own.
edge_created() {
  edge_planned create
}

# edge_applied: whether the stack's outputs name two edges, as they do once it is applied.
edge_applied() {
  stack_tofu output -json | jq -e '(.addresses.value // []) | length == 2' > /dev/null
}

# edge_check_passes NUMBER: whether scripts/edge-check passes for edge NUMBER, run under the lock
# the caller holds on the stack, whose descriptor it shares with it (lock_stack). stack-env keeps
# the state passphrase out of the environment of what it runs, and edge-check, which sources
# stack-env itself, needs it again.
edge_check_passes() {
  # shellcheck disable=SC2154 # lock_stack sets infra_lock_fd
  EDGE_STACK_LOCKED=$infra_lock_fd TF_STATE_PASSPHRASE=${TF_STATE_PASSPHRASE-} \
    "$(dirname "${BASH_SOURCE[0]}")/../edge-check" --edge "$1"
}

# edge_require_other_serves: for a saved plan that deletes or replaces one edge, whether the other
# passes its check; fails, naming the way to replace the edge anyway, when it does not, as the plan
# would leave no edge serving. Needs edge_refuse_double_replace's edge_replaced_numbers.
edge_require_other_serves() {
  local number other
  ((${#edge_replaced_numbers[@]} == 1)) || return 0
  number=${edge_replaced_numbers[0]}
  other=$((3 - number))
  echo "checking that edge $other serves before edge $number is taken down"
  if ! edge_check_passes "$other"; then
    infra_error "edge $other does not pass its check, so the plan that takes edge $number down is not applied; to replace edge $number while edge $other is down, run: just edge-rollout --replace --edge $number --other-down"
    return 1
  fi
}

# edge_refuse_double_replace: sets edge_replaced_numbers to the edges the saved plan deletes or
# replaces, and fails when that is both, which would leave nothing serving until both are rebuilt.
edge_refuse_double_replace() {
  mapfile -t edge_replaced_numbers < <(edge_replaced | sort -u)
  if ((${#edge_replaced_numbers[@]} > 1)); then
    infra_error "the plan replaces both edge routers at once, or deletes both instances, which would leave none serving; just edge-rollout replaces them one at a time, with a check in between"
    return 1
  fi
}
