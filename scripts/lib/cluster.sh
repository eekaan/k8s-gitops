# shellcheck shell=bash
# Shared by scripts/cluster-env, the cluster-* scripts and the secrets bundle check: the Talos age
# key's location, talos/.sops.yaml's recipient, the check that a secrets bundle is encrypted, a
# cluster's nodes and the wait for their Talos API, and the line that names the step a recipe
# failed in. Builds on scripts/lib/infra.sh, which reads the environment. Nothing here reads the
# age key or prints a secret: sops and talman get the key's location from their environment.

# shellcheck source=scripts/lib/infra.sh
. "$(dirname "${BASH_SOURCE[0]}")/infra.sh"

sops_config=$infra_root/talos/.sops.yaml

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

# Go's HTTP/2 debug log (GODEBUG=http2debug=2) dumps the frames talosctl, kubectl and helm send and
# receive, which carry machine configurations and credentials, so the recipes run without it.
refuse_http2_debug() {
  if [[ ${GODEBUG-} == *http2debug* ]]; then
    infra_error "GODEBUG sets http2debug; unset it, as Go's HTTP/2 debug log would print machine configurations and credentials"
    return 1
  fi
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
