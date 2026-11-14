# shellcheck shell=bash
# Shared by scripts/stack-env, the infra-* scripts and os-smoke: the environment they read, the
# state encryption settings, the operator allowlist and the plan summary. Nothing here prints a
# variable's value or passes a secret on a command line: secrets reach tofu through its
# environment only.

infra_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

# infra_error MESSAGE: MESSAGE on stderr, after the name of the script that failed.
infra_error() {
  printf '%s: %s\n' "${0##*/}" "$1" >&2
}

# Reads .env at the repository root, when it exists, into the environment; CI has no .env and sets
# the variables itself. Each line is a literal NAME=value: nothing in a value is expanded or run,
# and one pair of matching quotes around it is dropped. Blank lines and # comments are skipped.
# Any other line stops the run, named by its number only, as it may hold a secret.
load_env() {
  local file=$infra_root/.env line name value number=0
  local skipped='^[[:space:]]*(#|$)' valid_name='^[A-Z_][A-Z0-9_]*$'
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    number=$((number + 1))
    line=${line%$'\r'}
    [[ $line =~ $skipped ]] && continue
    name=${line%%=*}
    value=${line#*=}
    if [[ $line != *=* || ! $name =~ $valid_name ]]; then
      infra_error ".env line $number is not a NAME=value line"
      return 1
    fi
    if ((${#value} >= 2)) && [[ ${value:0:1} == [\"\'] && ${value:0:1} == "${value: -1}" ]]; then
      value=${value:1:${#value}-2}
    fi
    export "$name=$value"
  done < "$file"
}

# Every placeholder in .env.example starts with example-, so a copy not filled in is caught.
is_placeholder() {
  [[ $1 == example-* ]]
}

# require_env NAME...: fails naming each NAME that is unset, empty or still a placeholder.
require_env() {
  local name failed=0
  for name; do
    if [[ -z ${!name:-} ]]; then
      infra_error "$name is not set; set it in .env or the environment"
      failed=1
    elif is_placeholder "${!name}"; then
      infra_error "$name still holds the placeholder from .env.example"
      failed=1
    fi
  done
  return "$failed"
}

# OpenStack clients and tofu's provider authenticate from either a clouds.yaml entry outside the
# repository or the application-credential variables; the scripts read neither.
require_openstack_auth() {
  local name
  for name in OS_CLOUD OS_AUTH_URL; do
    if [[ -n ${!name:-} ]] && is_placeholder "${!name}"; then
      infra_error "$name still holds the placeholder from .env.example"
      return 1
    fi
  done
  if [[ -z ${OS_CLOUD:-} && -z ${OS_AUTH_URL:-} ]]; then
    infra_error "OS_CLOUD or OS_AUTH_URL is not set; set one in .env or the environment"
    return 1
  fi
}

# openstack_client_recent: whether the openstack client on PATH is python-openstackclient 7.0.0 or
# newer, which os-smoke's quota with usage needs and which the recipes that use the client require.
openstack_client_recent() {
  local client
  client=$(openstack --version 2>&1) || return 1
  [[ $client =~ ([0-9]+)\.[0-9]+\.[0-9]+ ]] && ((BASH_REMATCH[1] >= 7))
}

# tofu's logs hold resource addresses and decrypted attribute values, on screen or in a file,
# TF_WORKSPACE would move a stack's state to another key, TF_CLI_ARGS and TF_CLI_ARGS_<command> add
# arguments to the commands the recipes run, which could turn off what they rely on, and TF_DATA_DIR
# would move the stack's working directory, with the saved plan and the lock, out of its .terraform/.
# So the recipes run without them; each is named, never its value.
refuse_tofu_overrides() {
  local name refused=0
  for name in TF_LOG TF_LOG_PATH TF_LOG_CORE TF_LOG_PROVIDER; do
    if [[ -n ${!name+set} ]]; then
      infra_error "$name is set; unset it, as tofu's logs would hold state and plan values"
      refused=1
    fi
  done
  if [[ -n ${TF_WORKSPACE+set} ]]; then
    infra_error "TF_WORKSPACE is set; unset it, as it would move the stack's state to another key"
    refused=1
  fi
  while IFS= read -r name; do
    if [[ $name == TF_CLI_ARGS || $name == TF_CLI_ARGS_* ]]; then
      infra_error "$name is set; unset it, as it would add arguments to the tofu commands the recipes run"
      refused=1
    fi
  done < <(compgen -e)
  if [[ -n ${TF_DATA_DIR+set} ]]; then
    infra_error "TF_DATA_DIR is set; unset it, as it would move the stack's working directory, with its saved plan and lock, out of .terraform/"
    refused=1
  fi
  return "$refused"
}

# Go's HTTP/2 debug log (GODEBUG=http2debug=2) dumps the frames a Go tool sends and receives: tofu's
# and its providers' with the cloud and the object storage, talosctl's, kubectl's and helm's, which
# carry credentials, state and machine configurations. So the recipes run without it.
refuse_http2_debug() {
  if [[ ${GODEBUG-} == *http2debug* ]]; then
    infra_error "GODEBUG sets http2debug; unset it, as Go's HTTP/2 debug log would print credentials, state and machine configurations"
    return 1
  fi
}

# confirm STACK VERB PARTICIPLE: whether STACK's name is typed back, before it is VERBed.
confirm() {
  local answer=
  printf 'Type %s to %s it: ' "$1" "$2" >&2
  read -r answer || true
  if [[ $answer != "$1" ]]; then
    infra_error "$1 was not confirmed and is not $3"
    return 1
  fi
}

# Exports TF_ENCRYPTION: OpenTofu's state and plan encryption in its environment form, written in
# HCL's JSON syntax, with a key derived from TF_STATE_PASSPHRASE. jq takes the passphrase from its
# environment and escapes it as JSON; ${ and %{ would start HCL templates, so they are doubled.
# Every stack enforces encryption in its own terraform block, so without these settings tofu
# writes nothing. The key provider and method names are stored with the encrypted state; renaming
# them makes existing state unreadable.
export_state_encryption() {
  require_env TF_STATE_PASSPHRASE || return 1
  # OpenTofu's pbkdf2 key provider refuses shorter passphrases.
  if ((${#TF_STATE_PASSPHRASE} < 16)); then
    infra_error "TF_STATE_PASSPHRASE is shorter than 16 characters"
    return 1
  fi
  TF_ENCRYPTION=$(TF_STATE_PASSPHRASE=$TF_STATE_PASSPHRASE jq -cn '
    def literal: gsub("\\$\\{"; "$${") | gsub("%\\{"; "%%{");
    {
      key_provider: {pbkdf2: {state: {passphrase: (env.TF_STATE_PASSPHRASE | literal)}}},
      method: {aes_gcm: {state: {keys: "${key_provider.pbkdf2.state}"}}},
      state: {method: "method.aes_gcm.state", enforced: true},
      plan: {method: "method.aes_gcm.state", enforced: true},
      remote_state_data_sources: {default: {method: "method.aes_gcm.state"}}
    }') || return 1
  export TF_ENCRYPTION
  # TF_ENCRYPTION carries the key now; no child process needs the passphrase on its own.
  export -n TF_STATE_PASSPHRASE
}

# Hook for adding this machine's public address to the allowlist for the run, so an operator on a
# new network is not locked out. Looking the address up needs a network call and is not done:
# the allowlist is passed on as it is, and the hook says so.
add_current_address() {
  infra_error "not implemented: adding this machine's public address to the allowlist; the allowlist is used as given"
  printf '%s' "$1"
}

# Exports TF_VAR_api_allowed_cidrs from OPERATOR_CIDRS (CI) or operator-cidrs.json at the
# repository root: a non-empty JSON list of IPv4 CIDRs, none of which covers every address. A wrong
# entry is named by its position, as the list is the operator's own and is never printed. jq's own
# errors would quote the list, so they are dropped.
export_api_allowed_cidrs() {
  local from cidrs position problem refused=0
  local valid='select(type == "array" and length > 0 and all(.[]; type == "string"
    and test("^([0-9]{1,3}[.]){3}[0-9]{1,3}/[0-9]{1,2}$|^[0-9A-Fa-f:]+/[0-9]{1,3}$")))'
  if [[ -n ${OPERATOR_CIDRS:-} ]]; then
    from=OPERATOR_CIDRS
    cidrs=$(jq -nce "env.OPERATOR_CIDRS | fromjson | $valid" 2> /dev/null) || cidrs=
  elif [[ -f $infra_root/operator-cidrs.json ]]; then
    from=operator-cidrs.json
    cidrs=$(jq -ce "$valid" "$infra_root/operator-cidrs.json" 2> /dev/null) || cidrs=
  else
    infra_error "OPERATOR_CIDRS is not set and operator-cidrs.json does not exist; one of them holds the operator allowlist"
    return 1
  fi
  if [[ -z $cidrs ]]; then
    infra_error "$from is not a JSON list of CIDRs"
    return 1
  fi
  # The cluster stack's networks and listener take IPv4 only, and a /0 would open the APIs to
  # every address.
  while read -r position problem; do
    case $problem in
      ipv6) infra_error "$from entry $position is an IPv6 network; the cluster stack takes IPv4 networks only" ;;
      all) infra_error "$from entry $position covers every address; the allowlist names the operator's own networks" ;;
    esac
    refused=1
  done < <(jq -r 'to_entries[]
    | if (.value | test(":")) then "\(.key + 1) ipv6" elif (.value | test("/0+$")) then "\(.key + 1) all" else empty end' <<< "$cidrs")
  ((!refused)) || return 1
  TF_VAR_api_allowed_cidrs=$(add_current_address "$cidrs")
  export TF_VAR_api_allowed_cidrs
}

# Reads a plan as tofu show -json prints it and prints tofu's counts line, then one line per action
# and resource type with how many resources of that type the action takes, then one line per output
# the plan changes, with its action and its name. Addresses and the values of attributes and
# outputs are never printed. Data sources, and resources and outputs without changes, are left out.
# A plan that changes outputs only, such as the cluster stack's talman_yaml after versions.yaml
# changes, is a change: applying it writes the new outputs to the state.
plan_summary() {
  jq -r '
    def action: if sort == ["create", "delete"] then "replace" else join("+") end;
    def rank: {"create": 0, "update": 1, "replace": 2, "delete": 3, "forget": 4}[.] // 5;
    [.resource_changes[]?
      | select(.mode == "managed")
      | {type, action: (.change.actions | action)}
      | select(.action != "no-op")] as $changes
    | [.output_changes // {} | to_entries[]
      | {name: .key, action: (.value.actions | action)}
      | select(.action != "no-op")] as $outputs
    | def count($a): [$changes[] | select(.action == $a)] | length;
    if ($changes | length) == 0 and ($outputs | length) == 0 then
      "No changes."
    else
      "Plan: \(count("create") + count("replace")) to add, \(count("update")) to change, \(count("delete") + count("replace")) to destroy\(if count("forget") > 0 then ", \(count("forget")) to forget" else "" end).",
      ($changes | group_by([(.action | rank), .action, .type])[] | "  \(.[0].action): \(length) \(.[0].type)"),
      ($outputs | sort_by([(.action | rank), .action, .name])[] | "  \(.action): output \(.name)")
    end'
}
