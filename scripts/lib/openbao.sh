# shellcheck shell=bash
# Shared by scripts/bao-put, bao-recovery, bao-root, bao-seal-keep, bao-seal-restore,
# bao-seed-volsync and bao-volsync-password, which source it with scripts/cluster-env: where OpenBao
# answers and as whom an operator logs in to it, the names a key-value path may hold, the ids of the
# seal keys the checkout names and those the servers run with, opening the operator's custody file
# and putting a new one in place without replacing a file, and the session a recipe works in: a
# private directory, a port-forward to OpenBao's active member, a short-lived token, and requests to
# OpenBao's API through them. Nothing here prints a token, a value or a key, or passes one as an
# argument: they reach kubectl, curl, jq and age on standard input or through a file descriptor, and
# leave them on a pipe. scripts/secret-rotate sources it too, for the refusal to run traced, the
# names and bao_kubectl: it opens no session, and its one write to OpenBao is bao-put's.
# scripts/cluster-last-copies sources it for the custody checks and the seal keys' ids.

# Traced, bash writes every command a recipe runs with the values it holds, the secrets among them,
# so a recipe refuses to run while the shell traces, however that was turned on (bash -x,
# SHELLOPTS=xtrace, a BASH_ENV that sets -x), before it reads anything. The one trace that goes on is
# that of tests/openbao-recipes.bats and tests/secret-rotate.bats: their BASH_ENV sets
# BAO_TESTS_XTRACE_DIR, which nothing else sets, and sends the trace to a file in that directory,
# as nothing does by accident.
if [[ $- == *x* ]] && ! [[ -n ${BAO_TESTS_XTRACE_DIR-} && -n ${BASH_XTRACEFD-} &&
  /proc/$$/fd/$BASH_XTRACEFD -ef $BAO_TESTS_XTRACE_DIR/$$ ]]; then
  set +x
  echo "${0##*/}: the shell traces each command, which would print the secrets this recipe reads; run it without bash -x, SHELLOPTS=xtrace or a BASH_ENV that sets -x" >&2
  exit 1
fi
# A shell the recipe starts, such as the command bao-root or bao-volsync-password runs, reads no file
# the recipe was given for one.
unset BASH_ENV ENV

bao_namespace=openbao
bao_service=openbao-active
# A name the listener's certificate holds, which curl connects to through the port-forward.
bao_host=openbao-active.openbao.svc
bao_port=8200
bao_ca_secret=openbao-ca
# The ConfigMap the chart renders the server configuration into, <release>-config, which every member
# starts with; its seal stanza names the seal keys the servers run with, by their ids and files.
bao_config_map=openbao-config
# The account and role an operator logs in as, and the audience OpenBao's role checks.
bao_operator_account=openbao-operator
bao_operator_role=operator
bao_audience=openbao
# shellcheck disable=SC2034 # read by scripts/bao-put and bao-seed-volsync
bao_mount=secrets

# A name in a key-value path or a key: letters, digits, '_', '.' and '-', not starting with '.' or
# '-', so no name is '.' or '..' and none reads as an option.
bao_name='[A-Za-z0-9_][A-Za-z0-9_.-]*'

# bao_valid_path PATH: whether PATH is a key-value path, names joined by '/'.
bao_valid_path() {
  [[ $1 =~ ^$bao_name(/$bao_name)*$ ]]
}

# bao_valid_key KEY: whether KEY is one name.
bao_valid_key() {
  [[ $1 =~ ^$bao_name$ ]]
}

# OpenBao's static seal holds a current key and, after a rotation, the key before it, each under a
# permanent id (https://openbao.org/docs/configuration/seal/static/#key-rotation); it seals with the
# current key and opens what was sealed with either, by the id the sealed value carries, and nothing
# else (Encrypt and Decrypt in wrappers/static/static.go of go-kms-wrapping, at the version OpenBao
# v2.7.2 pins). The tree mounts each key from the Secret of its id, at /openbao/userconfig/<id>/key,
# and an ExternalSecret of that name makes the Secret once (tests/openbao.bats), so an id names its
# Secret too.

# bao_stanza_ids WHERE: reads a server configuration on standard input and sets stanza_current and
# stanza_previous to the current_key_id and previous_key_id of its seal "static" block, the previous
# empty when the block names none. Fails naming WHERE, where the configuration is from, when it holds
# more than one such block or none that names a current id, when an id is no name a Secret and its
# volume take, or when the two ids are the same.
bao_stanza_ids() {
  local where=$1 line blocks=0 inside=0 id
  local setting='^[[:space:]]*(current_key_id|previous_key_id)[[:space:]]*=[[:space:]]*"([^"]*)"[[:space:]]*(#.*)?$'
  stanza_current="" stanza_previous=""
  while IFS= read -r line || [[ -n $line ]]; do
    if ((inside)); then
      if [[ $line == '}'* ]]; then
        inside=0
      elif [[ $line =~ $setting ]]; then
        if [[ ${BASH_REMATCH[1]} == current_key_id ]]; then
          stanza_current=${BASH_REMATCH[2]}
        else
          stanza_previous=${BASH_REMATCH[2]}
        fi
      fi
    elif [[ $line =~ ^seal[[:space:]]+\"static\"[[:space:]]*\{ ]]; then
      inside=1 blocks=$((blocks + 1))
    fi
  done
  if ((blocks >= 2)); then
    infra_error "$where holds $blocks seal \"static\" blocks, and the recipes read one"
    return 1
  elif [[ -z $stanza_current ]]; then
    infra_error "$where names no current_key_id in a seal \"static\" block"
    return 1
  fi
  # The chart names the volume of a Secret userconfig-<name>, a DNS label of at most 63 characters.
  for id in "$stanza_current" ${stanza_previous:+"$stanza_previous"}; do
    if [[ ! $id =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || ! ((${#id} <= 52)); then
      infra_error "the seal \"static\" block of $where names the key id $(printf '%s' "$id" | printable), which is no name a Secret and its volume take"
      return 1
    fi
  done
  if [[ $stanza_previous == "$stanza_current" ]]; then
    infra_error "the seal \"static\" block of $where names $stanza_current as both current_key_id and previous_key_id"
    return 1
  fi
}

# bao_seal_ids [VALUES]: sets bao_seal_current and bao_seal_previous to the ids of the seal keys the
# seal "static" block of server.ha.raft.config in VALUES names, this checkout's values.yaml of
# OpenBao by default, as bao_stanza_ids reads them: the tree is what a rebuild applies, and the
# servers' ConfigMap does not exist before OpenBao is installed. Fails as bao_stanza_ids does, and
# when VALUES cannot be read.
bao_seal_ids() {
  local values=${1:-$infra_root/kubernetes/apps/base/openbao/openbao/app/values.yaml} config
  if ! config=$(yq '.server.ha.raft.config // ""' "$values" 2> /dev/null); then
    infra_error "$values cannot be read for the seal stanza"
    return 1
  fi
  bao_stanza_ids "server.ha.raft.config in $values" <<< "$config" || return 1
  # shellcheck disable=SC2034 # read by the scripts that source this file
  bao_seal_current=$stanza_current bao_seal_previous=$stanza_previous
}

# bao_seal_named CURRENT PREVIOUS: the seal keys CURRENT and PREVIOUS, as a refusal names them.
bao_seal_named() {
  if [[ -n $2 ]]; then
    printf 'current %s and previous %s' "$1" "$2"
  else
    printf 'current %s and no previous' "$1"
  fi
}

# bao_seal_running: whether the servers run with the seal keys this checkout names, bao_seal_current
# and bao_seal_previous, which bao_seal_ids sets: reads the seal stanza of the server ConfigMap,
# which holds file paths and no key, and compares its ids with those. Fails naming both when they
# differ, and when the ConfigMap is missing or its stanza is not one bao_stanza_ids reads.
bao_seal_running() {
  local config
  config=$(bao_kubectl get configmap "$bao_config_map" --namespace "$bao_namespace" --output json \
    --ignore-not-found --request-timeout=30s) || return 1
  if [[ -z $config ]]; then
    infra_error "the ConfigMap $bao_config_map does not exist in $bao_namespace, so the seal keys the servers run with are not known"
    return 1
  fi
  bao_stanza_ids "the ConfigMap $bao_namespace/$bao_config_map" \
    <<< "$(printf '%s' "$config" | jq -r '.data["extraconfig-from-values.hcl"] // ""')" || return 1
  if [[ $stanza_current != "$bao_seal_current" || $stanza_previous != "$bao_seal_previous" ]]; then
    infra_error "the servers run with the seal keys $(bao_seal_named "$stanza_current" "$stanza_previous"), and this checkout names $(bao_seal_named "$bao_seal_current" "$bao_seal_previous"): run it from a checkout of main"
    return 1
  fi
}

# bao_decrypt FILE: FILE decrypted with the Talos age key, the operator's, on standard output for a
# pipe: from SOPS_AGE_KEY through a file descriptor when it holds the key, as in CI, and otherwise
# from the file SOPS_AGE_KEY_FILE names, as require_age_key in scripts/lib/cluster.sh checks them.
bao_decrypt() {
  if [[ -n ${SOPS_AGE_KEY:-} ]]; then
    age --decrypt --identity <(printf '%s\n' "$SOPS_AGE_KEY") -- "$1"
  else
    age --decrypt --identity "$SOPS_AGE_KEY_FILE" -- "$1"
  fi
}

# bao_custody_trusted FILE: whether FILE may be read as the operator's custody file. age
# authenticates no writer and the Talos age key's recipient is public, so whoever can write a file at
# the path could put one there with content of their choosing; only where the file is vouches for
# it. FILE is a regular file, no symbolic link, owned by this user and writable by no one else, in a
# place bao_custody_place accepts. Fails naming the first that is not, and why.
bao_custody_trusted() {
  local file=$1 info
  if [[ -L $file ]]; then
    infra_error "$file is a symbolic link; give the custody file itself"
    return 1
  elif [[ ! -f $file ]]; then
    infra_error "$file is not a regular file; give the custody file itself"
    return 1
  fi
  info=$(stat -c '%u %a' -- "$file") || return 1
  if [[ ${info%% *} != "$EUID" ]]; then
    infra_error "$file is owned by another user; a custody file is read only when this user owns it"
    return 1
  elif ((8#${info#* } & 8#022)); then
    infra_error "$file is writable by its group or others, who could have put it there; chmod go-w it once it is known to be the file that was written"
    return 1
  fi
  bao_custody_place "$file"
}

# bao_custody_place FILE: whether the directories above FILE, which need not exist yet, may hold a
# custody file: each of them, on FILE's path as given and as it resolves past symbolic links, is
# owned by this user or root, and writable by no one else unless its sticky bit keeps others from
# removing or replacing what they do not own. Fails naming the first that is not, and why.
bao_custody_place() {
  local path=$1 dir info
  local -a dirs=()
  [[ $path == /* ]] || path=$PWD/$path
  dir=$path
  while [[ $dir != / ]]; do
    dir=${dir%/*}
    dir=${dir:-/}
    dirs+=("$dir")
  done
  if ! dir=$(cd -P -- "${dirs[0]}" 2> /dev/null && pwd -P); then
    infra_error "${dirs[0]} is not a directory this user can enter"
    return 1
  fi
  dirs+=("$dir")
  while [[ $dir != / ]]; do
    dir=${dir%/*}
    dir=${dir:-/}
    dirs+=("$dir")
  done
  for dir in "${dirs[@]}"; do
    info=$(stat -L -c '%u %a' -- "$dir") || return 1
    if [[ ${info%% *} != "$EUID" && ${info%% *} != 0 ]]; then
      infra_error "$dir is owned by another user than this one or root, who could put a custody file in it; keep custody files where only this user can write, beside the Talos age key"
      return 1
    elif ((8#${info#* } & 8#022 && !(8#${info#* } & 8#1000))); then
      infra_error "$dir is writable by its group or others, who could put a custody file in it; keep custody files where only this user can write, beside the Talos age key"
      return 1
    fi
  done
}

# bao_place PARTIAL FILE CONSEQUENCE: puts PARTIAL, a file the script wrote beside FILE, in place as
# FILE with a hard link, which fails where FILE exists, so a file made after the script checked the
# path is never replaced. When the link fails it says so with CONSEQUENCE: that FILE exists now or,
# after ln's own error, as on a filesystem without hard links, that FILE is put in place no other
# way. PARTIAL stays, for the caller to remove.
bao_place() {
  ln -- "$1" "$2" && return 0
  if [[ -e $2 || -L $2 ]]; then
    infra_error "$2 exists now and is never replaced; $3"
  else
    infra_error "$2 is not in place: no hard link to it could be made, and no other way puts it there without the risk of replacing a file; $3"
  fi
  return 1
}

# bao_open: makes work_dir, a directory only this user can enter, opens a port-forward to OpenBao's
# active member through the cluster's kubeconfig, and reads OpenBao's CA into work_dir. From here on
# every exit of the script, on success, on failure and on SIGINT, SIGTERM or SIGHUP, runs bao_close.
# The port-forward's output is not printed, and kubectl's errors only as bao_kubectl shows them: they
# can name the API server.
bao_open() {
  local attempt log forwarded='Forwarding from [^ ]*:([0-9]+) ->'
  work_dir=$(umask 077 && mktemp -d -t "${0##*/}.XXXXXXXXXX")
  trap 'bao_close $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  step="opening a port-forward to service/$bao_service in $bao_namespace"
  log=$work_dir/port-forward
  # Made first, so it can be read before kubectl writes to it.
  : > "$log"
  # kubectl is the process whose id forward_pid holds, which a function would put one process below.
  (exec_tool kubectl port-forward --namespace "$bao_namespace" "service/$bao_service" ":$bao_port") > "$log" 2>&1 &
  forward_pid=$!
  for ((attempt = 0; attempt < 150; attempt++)); do
    if [[ $(< "$log") =~ $forwarded ]]; then
      bao_local_port=${BASH_REMATCH[1]}
      break
    fi
    if ! kill -0 "$forward_pid" 2> /dev/null; then
      infra_error "kubectl port-forward stopped before it forwarded a port"
      return 1
    fi
    sleep 0.1
  done
  if [[ -z ${bao_local_port-} ]]; then
    infra_error "kubectl port-forward forwarded no port within 15 seconds"
    return 1
  fi
  step="reading OpenBao's CA from the Secret $bao_ca_secret"
  bao_kubectl get secret "$bao_ca_secret" --namespace "$bao_namespace" --output 'jsonpath={.data.ca\.crt}' |
    base64 -d > "$work_dir/ca.crt"
  if [[ ! -s $work_dir/ca.crt ]]; then
    infra_error "the Secret $bao_ca_secret in $bao_namespace holds no ca.crt"
    return 1
  fi
}

# bao_kubectl ARG...: kubectl ARG..., its standard output as it is, and its errors, which can name
# the API server, through redact_stream (scripts/lib/errors.sh): they say why without its address,
# and with no control character. Returns kubectl's status.
bao_kubectl() {
  local status=0
  { kubectl "$@" 2>&1 1>&3 3>&- | redact_stream >&2; status=${PIPESTATUS[0]}; } 3>&1 || true
  return "$status"
}

# bao_close STATUS: runs bao_abort when the script defines it, revokes the token the script logged in
# with, stops the port-forward, removes work_dir and exits with STATUS, naming the step a failure was
# in.
bao_close() {
  local status=$1
  trap '' INT TERM HUP
  if declare -F bao_abort > /dev/null; then
    bao_abort || true
  fi
  if [[ -n ${bao_token-} ]]; then
    bao_request POST auth/token/revoke-self < /dev/null > /dev/null ||
      infra_error "could not revoke the OpenBao token; it expires within ten minutes"
    bao_token=
  fi
  if [[ -n ${forward_pid-} ]]; then
    kill "$forward_pid" 2> /dev/null || true
    wait "$forward_pid" 2> /dev/null || true
  fi
  if ! rm -rf -- "$work_dir"; then
    infra_error "cannot remove $work_dir; remove it"
    ((status != 0)) || status=1
  fi
  failed_step "$status"
  exit "$status"
}

# bao_request METHOD PATH [CONTENT_TYPE]: sends METHOD to /v1/PATH of OpenBao's API through the
# port-forward, verifying OpenBao's certificate against its CA under the name the certificate holds.
# A POST, PUT or PATCH sends standard input as its body, as CONTENT_TYPE, JSON when not given; once
# logged in, the token goes in a header read from a file descriptor. Prints the response's body.
# Returns 0 for a 2xx answer and 44 for 404; for any other it names the status and OpenBao's errors,
# as printable (scripts/lib/errors.sh) shows them, and returns 1.
bao_request() {
  local method=$1 path=$2 type=${3:-application/json} response status body
  local -a args=(--silent --show-error --max-time 30 --request "$method" --cacert "$work_dir/ca.crt"
    --connect-to "$bao_host:$bao_port:localhost:$bao_local_port" --write-out '\n%{http_code}')
  if [[ $method == POST || $method == PUT || $method == PATCH ]]; then
    args+=(--header "Content-Type: $type" --data-binary @-)
  fi
  if [[ -n ${bao_token-} ]]; then
    response=$(curl "${args[@]}" --header @<(printf 'X-Vault-Token: %s\n' "$bao_token") \
      "https://$bao_host:$bao_port/v1/$path") || return 1
  else
    response=$(curl "${args[@]}" "https://$bao_host:$bao_port/v1/$path") || return 1
  fi
  status=${response##*$'\n'}
  body=${response%$'\n'*}
  [[ $response == *$'\n'* ]] || body=
  printf '%s' "$body"
  if [[ $status == 2[0-9][0-9] ]]; then
    return 0
  elif [[ $status == 404 ]]; then
    return 44
  fi
  infra_error "OpenBao answered $status to $method $path: $(printf '%s' "$body" | jq -r '.errors // [] | join("; ")' 2> /dev/null | printable)"
  return 1
}

# bao_login: logs in to OpenBao as the operator role with a ten-minute token for its service account,
# minted through the Kubernetes API, which takes the right to create serviceaccounts/token for that
# account in OpenBao's namespace. Sets bao_token, which bao_close revokes.
bao_login() {
  local jwt response
  step="minting a token for the service account $bao_operator_account"
  jwt=$(bao_kubectl create token "$bao_operator_account" --namespace "$bao_namespace" --audience "$bao_audience" --duration 10m)
  # shellcheck disable=SC2034 # failed_step in scripts/lib/cluster.sh names it
  step="logging in to OpenBao as the role $bao_operator_role"
  response=$(printf '%s' "$jwt" | jq -Rc --arg role "$bao_operator_role" '{role: $role, jwt: .}' |
    bao_request POST auth/kubernetes/login)
  jwt=
  bao_token=$(printf '%s' "$response" | jq -r '.auth.client_token // empty')
  if [[ -z $bao_token ]]; then
    infra_error "OpenBao answered the login without a token"
    return 1
  fi
}
