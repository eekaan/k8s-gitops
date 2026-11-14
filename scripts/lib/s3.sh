# shellcheck shell=bash
# Shared by the scripts that reach the object storage through its S3 API: the key sets, the backup
# buckets' roles, and the one way rclone is run against the store. Builds on scripts/lib/infra.sh.

# shellcheck source=scripts/lib/infra.sh
. "$(dirname "${BASH_SOURCE[0]}")/infra.sh"

# The backup buckets are named <BACKUP_BUCKET_PREFIX>-<role>, one per role.
s3_backup_roles=(etcd openbao volsync postgres)

# What rclone keeps from the caller's environment: where programs and its home are, and how this
# machine reaches the network.
s3_kept_variables=(PATH HOME TMPDIR HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy)

# s3_key_names KEYSET: sets s3_key_id and s3_secret to the names of KEYSET's access key ID and
# secret key. The state key reaches OpenTofu's state and creates the buckets; the cluster's key is
# the one workloads in the cluster use, so that it can be revoked on its own.
s3_key_names() {
  case $1 in
    state) s3_key_id=AWS_ACCESS_KEY_ID s3_secret=AWS_SECRET_ACCESS_KEY ;;
    cluster) s3_key_id=CLUSTER_S3_ACCESS_KEY_ID s3_secret=CLUSTER_S3_SECRET_ACCESS_KEY ;;
    *)
      infra_error "$1 is not a key set; the key sets are state and cluster"
      return 1
      ;;
  esac
}

# s3_bucket_name_ok NAME [prefix]: whether the value of NAME is a bucket's name under the S3 rules,
# or with prefix the start of every backup bucket's name: lower-case letters, digits and hyphens,
# starting and ending with a letter or a digit, 3 to 63 characters. Dots are left out, and rclone
# would read a slash as a path inside the bucket. A wrong value is named by NAME, not printed.
s3_bucket_name_ok() {
  local value=${!1} what="a bucket name" shortest=3 longest=63 role
  if [[ ${2-} == prefix ]]; then
    what="the start of a bucket name"
    shortest=1
    for role in "${s3_backup_roles[@]}"; do
      if ((63 - 1 - ${#role} < longest)); then
        longest=$((63 - 1 - ${#role}))
      fi
    done
  fi
  if [[ ! $value =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || ((${#value} < shortest || ${#value} > longest)); then
    infra_error "$1 is not $what: lower-case letters, digits and hyphens, starting and ending with a letter or a digit, $shortest to $longest characters"
    return 1
  fi
}

# s3_require_client: fails unless rclone is on PATH, then reads the object storage's S3 endpoint,
# region and addressing into s3_endpoint, s3_region and s3_path_style from
# infra/openstack/backend.hcl, where OpenTofu's s3 backend reads them. The values are not printed.
s3_require_client() {
  local backend=infra/openstack/backend.hcl settings
  if ! command -v rclone > /dev/null; then
    infra_error "rclone is not on PATH; install the pinned tools with: just tools"
    return 1
  fi
  if ! settings=$(yq -p hcl -o json "$infra_root/$backend" 2> /dev/null | jq -er '
    [.endpoints.s3, .region, .use_path_style]
    | select((.[0] | type == "string" and test("^https://[^[:space:]]+$"))
      and (.[1] | type == "string" and test("^[a-z0-9-]+$"))
      and (.[2] | type == "boolean"))
    | @tsv' 2> /dev/null); then
    infra_error "$backend does not hold the object storage's https endpoint (endpoints.s3), region and use_path_style"
    return 1
  fi
  IFS=$'\t' read -r s3_endpoint s3_region s3_path_style <<< "$settings"
}

# s3_rclone KEYSET ARG...: runs rclone ARG... with the remote store: as the object storage, reached
# with KEYSET's key, and returns its status. Its output is rclone's own, which can name buckets
# and the endpoint, so a caller that prints anything prints its own lines instead. It guarantees:
#   - the key reaches rclone in its environment only, never on its command line or in a file;
#   - rclone reads no config file: RCLONE_CONFIG=/dev/null keeps its configuration in memory, so
#     the operator's rclone.conf, wherever it is, is never read;
#   - rclone gets nothing else of the caller's environment but s3_kept_variables: none of the
#     operator's RCLONE_ settings, which could add a log of the requests with their signatures or
#     a public ACL, no AWS_ variable or profile (env_auth is off), and no other secret;
#   - the endpoint, region and addressing are those of infra/openstack/backend.hcl.
# The provider is rclone's Other, any S3-compatible store.
s3_rclone() {
  local name
  s3_key_names "$1" || return 1
  shift
  require_env "$s3_key_id" "$s3_secret" || return 1
  if [[ -z ${s3_endpoint-} ]]; then
    s3_require_client || return 1
  fi
  (
    while IFS= read -r name; do
      if [[ " ${s3_kept_variables[*]} " != *" $name "* ]]; then
        export -n "${name?}"
      fi
    done < <(compgen -e)
    while read -r _ _ name; do
      export -fn "${name?}"
    done < <(declare -Fx)
    export RCLONE_CONFIG=/dev/null \
      RCLONE_CONFIG_STORE_TYPE=s3 \
      RCLONE_CONFIG_STORE_PROVIDER=Other \
      RCLONE_CONFIG_STORE_ENV_AUTH=false \
      RCLONE_CONFIG_STORE_ACCESS_KEY_ID="${!s3_key_id}" \
      RCLONE_CONFIG_STORE_SECRET_ACCESS_KEY="${!s3_secret}" \
      RCLONE_CONFIG_STORE_ENDPOINT="$s3_endpoint" \
      RCLONE_CONFIG_STORE_REGION="$s3_region" \
      RCLONE_CONFIG_STORE_FORCE_PATH_STYLE="$s3_path_style"
    exec rclone "$@"
  )
}

# s3_owned_buckets KEYSET: the buckets of KEYSET's project, one per line. S3 lists only the
# buckets the requester's project owns.
s3_owned_buckets() {
  local listing line
  listing=$(s3_rclone "$1" lsf --dirs-only store: 2> /dev/null) || return 1
  while IFS= read -r line; do
    if [[ -n $line ]]; then
      printf '%s\n' "${line%/}"
    fi
  done <<< "$listing"
}

# s3_create_buckets KEYSET NAME...: creates each bucket NAME that KEYSET's project does not own
# yet, and sets s3_bucket_state[NAME] to exists, created, taken, failed, or unconfirmed when the
# buckets could not be listed after it was made. Returns 1, having created nothing, when the
# buckets cannot be listed first. Prints nothing.
# rclone, with the provider Other, takes a bucket that another project owns as made without an
# error, as S3 stores differ in what they answer, so only a listing after the create tells whether
# the project owns it.
s3_create_buckets() {
  local keyset=$1 owned name made=0 listed=1
  shift
  declare -gA s3_bucket_state=()
  owned=$(s3_owned_buckets "$keyset") || return 1
  for name; do
    if grep -qxF -- "$name" <<< "$owned"; then
      s3_bucket_state[$name]=exists
    elif s3_rclone "$keyset" mkdir "store:$name" > /dev/null 2>&1; then
      s3_bucket_state[$name]=made
      made=1
    else
      s3_bucket_state[$name]=failed
    fi
  done
  ((made)) || return 0
  owned=$(s3_owned_buckets "$keyset") || listed=0
  for name; do
    if [[ ${s3_bucket_state[$name]} != made ]]; then
      continue
    elif ((!listed)); then
      s3_bucket_state[$name]=unconfirmed
    elif grep -qxF -- "$name" <<< "$owned"; then
      s3_bucket_state[$name]=created
    else
      s3_bucket_state[$name]=taken
    fi
  done
}
