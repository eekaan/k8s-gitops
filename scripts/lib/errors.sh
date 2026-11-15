# shellcheck shell=bash
# Shared by scripts/lib/s3.sh, scripts/lib/cluster.sh and scripts/lib/openbao.sh: what the recipes
# show of the errors of the S3 client, the cloud client, kubectl and OpenBao, whose messages can name
# an endpoint, a bucket, an API server, a project or a key, or carry control characters a terminal
# acts on. Builds on scripts/lib/infra.sh.
#
# What is shown is the reason, never the places. Every line passes through redact_stream first, which
# replaces, before anything is printed:
#   - the value of each variable in error_secret_variables, and of each value a recipe adds to
#     error_secrets, matched literally, in bash, so none of them reaches a command line;
#   - every byte that is not printable ASCII or a tab, the C0 and C1 control characters among them,
#     by a question mark, as printable shows text;
#   - every URL, IPv4 and IPv6 address, host name with a dot in it, and every run of 20 or more
#     letters, digits and +/=_- that holds a digit, or of 20 or more hexadecimal digits and hyphens (a
#     key, a token, an ID), by pattern. A long word of letters only, such as an S3 error code, stays.
# A line is cut at 300 characters, and at most 8 lines of a command's errors are shown. With CI set,
# as CI logs are public, nothing is shown: the errors go to errors_log, in a directory git ignores,
# and only that file's name is printed.

# shellcheck source=scripts/lib/infra.sh
. "$(dirname "${BASH_SOURCE[0]}")/infra.sh"

# The variables whose values are the deployment's or the operator's own, as the recipes read them.
error_secret_variables=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CLUSTER_S3_ACCESS_KEY_ID
  CLUSTER_S3_SECRET_ACCESS_KEY BACKUP_BUCKET_PREFIX TF_STATE_BUCKET TF_STATE_PASSPHRASE SOPS_AGE_KEY
  KUBE_API_ADDRESS OS_AUTH_URL OS_CLOUD OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET
  OS_PROJECT_ID OS_USERNAME)
# Values a recipe learns while it runs, such as a key the cloud client has just made, and the S3
# endpoint, region and addressing it has read.
error_secrets=()

# start_errors_log FILE: where the errors go with CI set, empty at the start of the run. FILE is in a
# directory git ignores.
start_errors_log() {
  errors_log=$1
  if [[ -n ${CI:-} ]]; then
    (umask 077 && mkdir -p "${errors_log%/*}" && : > "$errors_log")
  fi
}

# printable: the lines on standard input with every byte that is not printable ASCII or a tab shown as
# a question mark. A control character, C0 or C1, would reach the terminal as an instruction, to move
# the cursor, clear the screen or set the window's title; text outside ASCII is shown so too.
printable() {
  local LC_ALL=C line
  while IFS= read -r line || [[ -n $line ]]; do
    printf '%s\n' "${line//[^[:print:]$'\t']/?}"
  done
}

# redact_stream: the lines on standard input with every secret and every place replaced, as the
# header says.
redact_stream() {
  local line name value
  local -a redactions=("${error_secrets[@]}")
  for name in "${error_secret_variables[@]}"; do
    redactions+=("${!name:-}")
  done
  [[ -z ${s3_endpoint-} ]] || redactions+=("$s3_endpoint")
  while IFS= read -r line || [[ -n $line ]]; do
    for value in "${redactions[@]}"; do
      # A short value would redact every line it happens to be part of.
      if ((${#value} >= 3)); then
        line=${line//"$value"/<redacted>}
      fi
    done
    printf '%s\n' "${line:0:300}"
  done | printable | sed -E \
    -e 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]"'"'"')]+#<url>#g' \
    -e 's#\[?([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}\]?#<address>#g' \
    -e 's#[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]+)?#<address>#g' \
    -e 's#[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+#<name>#g' \
    -e 's#[0-9A-Fa-f-]{20,}#<token>#g' \
    -e 's#[A-Za-z0-9+/=_-]{10,}[0-9][A-Za-z0-9+/=_-]*|[A-Za-z0-9+/=_-]{0,9}[0-9][A-Za-z0-9+/=_-]{10,}#<token>#g'
}

# run_keeping_errors COMMAND [ARG...]: runs COMMAND, a program or a function, with its standard
# output in last_output and its standard error in last_errors, neither shown, and returns its status.
# The standard error passes through a file in TMPDIR that only this user can read, removed at once.
run_keeping_errors() {
  local file status=0
  file=$(umask 077 && mktemp "${TMPDIR:-/tmp}/errors.XXXXXXXXXX") || return 1
  # shellcheck disable=SC2034 # read by the caller
  last_output=$("$@" 2> "$file") || status=$?
  last_errors=$(< "$file")
  rm -f -- "$file"
  return "$status"
}

# report_errors WHAT: what last_errors holds, as the errors of WHAT, shown as the header says, and
# nothing when it holds none.
report_errors() {
  local line shown=0
  [[ -n ${last_errors-} ]] || return 0
  if [[ -n ${CI:-} ]]; then
    if [[ -n ${errors_log-} ]]; then
      (umask 077 && mkdir -p "${errors_log%/*}" && printf '%s\n' "$last_errors" >> "$errors_log")
      infra_error "$1's errors are in ${errors_log#"$infra_root"/}"
    else
      infra_error "$1's errors are not shown in CI"
    fi
    return 0
  fi
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    infra_error "$1: $line"
    shown=$((shown + 1))
    ((shown < 8)) || break
  done < <(redact_stream <<< "$last_errors")
}
