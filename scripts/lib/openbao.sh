# shellcheck shell=bash
# Shared by scripts/bao-put, bao-recovery, bao-root, bao-seal-restore, bao-seed-volsync and
# bao-volsync-password, which source it with scripts/cluster-env: where OpenBao answers and as whom
# an operator logs in to it, the names a key-value path may hold, opening the operator's custody
# file, and the session a recipe works in: a private directory, a port-forward to OpenBao's active
# member, a short-lived token, and requests to OpenBao's API through them. Nothing here prints a
# token, a value or a key, or passes one as an argument: they reach kubectl, curl, jq and age on
# standard input or through a file descriptor, and leave them on a pipe.

bao_namespace=openbao
bao_service=openbao-active
# A name the listener's certificate holds, which curl connects to through the port-forward.
bao_host=openbao-active.openbao.svc
bao_port=8200
bao_ca_secret=openbao-ca
# shellcheck disable=SC2034 # read by scripts/bao-recovery
bao_seal_secret=openbao-seal-1
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

# bao_open: makes work_dir, a directory only this user can enter, opens a port-forward to OpenBao's
# active member through the cluster's kubeconfig, and reads OpenBao's CA into work_dir. From here on
# every exit of the script, on success, on failure and on SIGINT, SIGTERM or SIGHUP, runs bao_close.
# Neither the port-forward's output nor kubectl's errors are printed: they can name the API server.
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
  kubectl get secret "$bao_ca_secret" --namespace "$bao_namespace" --output 'jsonpath={.data.ca\.crt}' |
    base64 -d > "$work_dir/ca.crt"
  if [[ ! -s $work_dir/ca.crt ]]; then
    infra_error "the Secret $bao_ca_secret in $bao_namespace holds no ca.crt"
    return 1
  fi
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
# Returns 0 for a 2xx answer and 44 for 404; for any other it names the status and OpenBao's errors
# and returns 1.
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
  infra_error "OpenBao answered $status to $method $path: $(printf '%s' "$body" | jq -r '.errors // [] | join("; ")' 2> /dev/null)"
  return 1
}

# bao_login: logs in to OpenBao as the operator role with a ten-minute token for its service account,
# minted through the Kubernetes API, which takes the right to create serviceaccounts/token for that
# account in OpenBao's namespace. Sets bao_token, which bao_close revokes.
bao_login() {
  local jwt response
  step="minting a token for the service account $bao_operator_account"
  jwt=$(kubectl create token "$bao_operator_account" --namespace "$bao_namespace" --audience "$bao_audience" --duration 10m)
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
