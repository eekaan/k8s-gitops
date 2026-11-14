#!/usr/bin/env bats

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  JUST=$(command -v just)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STORE="$BATS_TEST_TMPDIR/store"
  mkdir -p "$BIN" "$RECORD" "$STORE" "$BATS_TEST_TMPDIR/repo/infra/openstack"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  # A copy of the scripts in a repository of its own with this one's ignore rules, so no run
  # touches this checkout or its .env.
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp "$ROOT/.gitignore" "$REPO/.gitignore"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q "$REPO"
  # The backend file, the endpoint's only source, with a marker for the endpoint.
  ENDPOINT=https://marker-endpoint.example.invalid
  sed -E "s#https://[^\"]+#$ENDPOINT#" "$ROOT/infra/openstack/backend.hcl" > "$REPO/infra/openstack/backend.hcl"
  grep -qF "$ENDPOINT" "$REPO/infra/openstack/backend.hcl"
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise < /dev/null
  cp "$BATS_TEST_DIRNAME/fixtures/s3/rclone" "$BIN/rclone"
  touch "$STORE/ours" "$STORE/theirs"
  fake_openstack
  # The tools the recipes hand values to, recorded on their way to the real binaries.
  for tool in jq yq grep sed git mktemp mv; do
    record "$tool"
  done
  BASE_ENVIRONMENT=(
    BACKUP_BUCKET_PREFIX=marker-prefix
    TF_STATE_BUCKET=marker-state-bucket
    AWS_ACCESS_KEY_ID=marker-state-access-key-id
    AWS_SECRET_ACCESS_KEY=marker-state-secret-key
    CLUSTER_S3_ACCESS_KEY_ID=marker-cluster-access-key-id
    CLUSTER_S3_SECRET_ACCESS_KEY=marker-cluster-secret-key
    TF_STATE_PASSPHRASE=marker-state-passphrase
    OS_CLOUD=fixture-cloud
  )
  reset_environment
  # Never on a command line nor printed: every key, those the openstack client creates included.
  KEYS=(marker-state-access-key-id marker-state-secret-key marker-cluster-access-key-id
    marker-cluster-secret-key marker-new-access-key marker-new-secret-key marker-state-passphrase)
  # Never printed; the buckets' names reach the S3 client's command line.
  NAMES=(marker-prefix marker-state-bucket marker-endpoint fixture-project-id fixture-user-id)
  SUFFIXES=(etcd openbao volsync postgres)
}

# fake NAME: a binary first on the recipe's PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# record NAME: puts NAME's arguments in the record, then runs the real NAME.
record() {
  local real
  real=$(command -v "$1")
  fake "$1" <<EOF
printf '%s\n' "$1 \$*" >> "$RECORD/argv"
exec "$real" "\$@"
EOF
}

# fake_openstack [VERSION]: an openstack client, reporting VERSION (10.5.0 by default), that
# creates an EC2 credential; records its arguments and its environment.
fake_openstack() {
  fake openstack <<EOF
printf '%s\n' "openstack \$*" >> "$RECORD/argv"
env -0 > "$RECORD/env.openstack"
case "\$*" in
  --version) echo 'openstack ${1:-10.5.0}' ;;
  'ec2 credentials create -f json')
    echo '{"access": "marker-new-access-key", "project_id": "fixture-project-id", "secret": "marker-new-secret-key", "trust_id": null, "user_id": "fixture-user-id"}'
    ;;
  *) echo "unexpected call: openstack \$*" >&2; exit 1 ;;
esac
EOF
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
recipe() {
  run timeout 60 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$@"
}

# clear_record: forgets every recorded call, so the next run's calls are numbered from one.
clear_record() {
  rm -f "$RECORD"/*
}

# started TOOL...: the recorded calls of any TOOL.
started() {
  local tool
  for tool; do
    grep "^$tool " "$RECORD/argv" 2> /dev/null || true
  done
}

# calls TOOL WORD...: the recorded calls of TOOL whose arguments start with WORD....
calls() {
  grep "^$* " "$RECORD/argv" 2> /dev/null || true
}

# env_value FILE NAME: NAME's value in a recorded environment.
env_value() {
  local entry
  while IFS= read -r -d '' entry; do
    if [[ $entry == "$2="* ]]; then
      printf '%s\n' "${entry#*=}"
    fi
  done < "$1"
}

# env_names FILE: the names in a recorded environment, sorted.
env_names() {
  local entry
  while IFS= read -r -d '' entry; do
    printf '%s\n' "${entry%%=*}"
  done < "$1" | sort
}

# rclone_envs PATTERN: the recorded environment of each rclone call whose arguments match PATTERN.
rclone_envs() {
  local call=0 line
  while IFS= read -r line; do
    call=$((call + 1))
    if [[ $line =~ $1 ]]; then
      echo "$RECORD/env.rclone.$call"
    fi
  done < <(started rclone)
}

# absent TEXT FILE...: fails when any FILE holds TEXT.
absent() {
  local text=$1
  shift
  if grep -qF -- "$text" "$@" 2> /dev/null; then
    echo "found $text in $*" >&2
    return 1
  fi
}

# all_buckets: the object storage holds the four backup buckets.
all_buckets() {
  local suffix
  for suffix in "${SUFFIXES[@]}"; do
    echo "marker-prefix-$suffix"
  done > "$STORE/ours"
}

@test "The four backup buckets are created through the S3 API and a second run creates nothing" {
  recipe infra-backup-buckets

  [ "$status" -eq 0 ]
  [ "$(calls rclone mkdir | wc -l)" -eq 4 ]
  for suffix in "${SUFFIXES[@]}"; do
    [ "$(calls rclone mkdir | grep -cx "rclone mkdir store:marker-prefix-$suffix")" -eq 1 ]
    grep -qx "marker-prefix-$suffix" "$STORE/ours"
    [[ $output == *"infra-backup-buckets: created the $suffix bucket"* ]]
  done
  # Every call reached the object storage through the S3 API with the state key, not through
  # the openstack client.
  [ -n "$(rclone_envs .)" ]
  while IFS= read -r file; do
    [ "$(env_value "$file" RCLONE_CONFIG_STORE_ACCESS_KEY_ID)" = marker-state-access-key-id ]
    [ "$(env_value "$file" RCLONE_CONFIG_STORE_SECRET_ACCESS_KEY)" = marker-state-secret-key ]
  done < <(rclone_envs .)
  [ -z "$(started openstack)" ]

  clear_record
  recipe infra-backup-buckets

  [ "$status" -eq 0 ]
  [ -z "$(calls rclone mkdir)" ]
  for suffix in "${SUFFIXES[@]}"; do
    [[ $output == *"infra-backup-buckets: the $suffix bucket exists; nothing to create"* ]]
    [ "$(grep -cx "marker-prefix-$suffix" "$STORE/ours")" -eq 1 ]
  done
}

@test "A bucket name that is taken fails naming the bucket by its role only" {
  echo marker-prefix-volsync > "$STORE/theirs"

  recipe infra-backup-buckets

  [ "$status" -ne 0 ]
  grep -qx "infra-backup-buckets: the volsync bucket's name is taken; choose another BACKUP_BUCKET_PREFIX" <<< "$output"
  [ "$(grep -c volsync <<< "$output")" -eq 1 ]
  [ "$(grep -cx marker-prefix-volsync "$STORE/ours")" -eq 0 ]
  for suffix in etcd openbao postgres; do
    [[ $output == *"infra-backup-buckets: created the $suffix bucket"* ]]
    grep -qx "marker-prefix-$suffix" "$STORE/ours"
  done
  for shown in marker-prefix marker-endpoint AccessDenied INFO ERROR; do
    [[ $output != *"$shown"* ]]
  done
}

@test "No bucket name, key or endpoint reaches the output, and no key reaches a command line" {
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

  run_and_keep ok infra-backup-buckets
  run_and_keep ok infra-backup-buckets
  run_and_keep ok infra-backup-check
  printf '%s\n' "CLUSTER_S3_ACCESS_KEY_ID=" "CLUSTER_S3_SECRET_ACCESS_KEY=" > "$REPO/.env"
  run_and_keep ok infra-s3-key cluster
  run_and_keep ok infra-backup-check
  # The ways a run stops: a key already in .env, the keys the same (the fake client hands out one
  # pair), a taken name, a bucket that cannot be made or listed, the buckets not listed.
  run_and_keep failed infra-s3-key cluster
  run_and_keep ok infra-s3-key state
  run_and_keep failed infra-backup-check
  rm "$REPO/.env"
  : > "$STORE/ours"
  echo marker-prefix-etcd > "$STORE/theirs"
  run_and_keep failed infra-backup-buckets
  run_and_keep failed infra-backup-check
  : > "$STORE/mkdir-fails"
  : > "$STORE/ours"
  run_and_keep failed infra-backup-buckets
  : > "$STORE/list-fails"
  run_and_keep failed infra-backup-buckets
  without CLUSTER_S3_ACCESS_KEY_ID
  with CLUSTER_S3_ACCESS_KEY_ID=marker-state-access-key-id
  run_and_keep failed infra-backup-check

  # The record holds the calls of the S3 client, the openstack client and the tools the recipes
  # pass values to.
  [ -n "$(calls rclone mkdir)" ]
  [ -n "$(calls rclone lsf)" ]
  [ -n "$(calls openstack ec2 credentials create)" ]
  [ -n "$(started mv)" ]
  [ -n "$(started yq)" ]
  [[ ${printed[*]} == *"is taken"* ]]
  [[ ${printed[*]} == *FAIL* ]]
  for marker in "${KEYS[@]}" marker-endpoint; do
    absent "$marker" "$RECORD/argv"
  done
  for marker in "${KEYS[@]}" "${NAMES[@]}"; do
    [[ ${printed[*]} != *"$marker"* ]]
  done
  for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CLUSTER_S3_ACCESS_KEY_ID CLUSTER_S3_SECRET_ACCESS_KEY TF_STATE_PASSPHRASE; do
    [ -z "$(env_value "$RECORD/env.openstack" "$name")" ]
  done
}

@test "The S3 client reads nothing but its environment" {
  all_buckets
  # The operator's own rclone and AWS settings, any of which would change what rclone does.
  with RCLONE_CONFIG="$BATS_TEST_TMPDIR/operator.conf" \
    RCLONE_CONFIG_STORE_ENDPOINT=https://operator.example.invalid \
    RCLONE_S3_BUCKET_ACL=public-read RCLONE_DUMP=headers,auth \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg" AWS_PROFILE=operator \
    AWS_SHARED_CREDENTIALS_FILE="$BATS_TEST_TMPDIR/aws-credentials" \
    HTTPS_PROXY=http://proxy.example.invalid:3128

  recipe infra-backup-buckets

  [ "$status" -eq 0 ]

  recipe infra-backup-check

  [ "$status" -eq 0 ]
  region=$(yq -p hcl -o json '.region' "$REPO/infra/openstack/backend.hcl" | jq -r .)
  expected=$(printf '%s\n' HOME HTTPS_PROXY PATH RCLONE_CONFIG RCLONE_CONFIG_STORE_ACCESS_KEY_ID \
    RCLONE_CONFIG_STORE_ENDPOINT RCLONE_CONFIG_STORE_ENV_AUTH RCLONE_CONFIG_STORE_FORCE_PATH_STYLE \
    RCLONE_CONFIG_STORE_PROVIDER RCLONE_CONFIG_STORE_REGION RCLONE_CONFIG_STORE_SECRET_ACCESS_KEY \
    RCLONE_CONFIG_STORE_TYPE | sort)
  # One listing of the buckets, then one per bucket.
  [ "$(rclone_envs . | wc -l)" -eq 5 ]
  while IFS= read -r file; do
    [ "$(env_names "$file" | grep -vx _)" = "$expected" ]
    [ "$(env_value "$file" RCLONE_CONFIG)" = /dev/null ]
    [ "$(env_value "$file" RCLONE_CONFIG_STORE_TYPE)" = s3 ]
    [ "$(env_value "$file" RCLONE_CONFIG_STORE_PROVIDER)" = Other ]
    [ "$(env_value "$file" RCLONE_CONFIG_STORE_ENV_AUTH)" = false ]
    [ "$(env_value "$file" RCLONE_CONFIG_STORE_ENDPOINT)" = "$ENDPOINT" ]
    [ "$(env_value "$file" RCLONE_CONFIG_STORE_REGION)" = "$region" ]
    [ "$(env_value "$file" RCLONE_CONFIG_STORE_FORCE_PATH_STYLE)" = true ]
    [ "$(env_value "$file" HTTPS_PROXY)" = http://proxy.example.invalid:3128 ]
  done < <(rclone_envs .)

  # The pinned rclone itself, given what the recipes give it, with a config file in each place it
  # looks for one: it keeps its configuration in memory and knows no remote but the object
  # storage. Neither command reaches the network.
  home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home/.config/rclone" "$BATS_TEST_TMPDIR/xdg/rclone"
  printf '[operator-home]\ntype = local\n' > "$home/.config/rclone/rclone.conf"
  printf '[operator-dotfile]\ntype = local\n' > "$home/.rclone.conf"
  printf '[operator-xdg]\ntype = local\n' > "$BATS_TEST_TMPDIR/xdg/rclone/rclone.conf"
  printf '[operator-pointed]\ntype = local\n' > "$BATS_TEST_TMPDIR/operator.conf"
  real=$(command -v rclone)
  [[ $real != "$BIN"/* ]]

  # shellcheck disable=SC2016 # $1 is the copy's path, expanded by the inner shell
  run env -i HOME="$home" PATH="$PATH" XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg" \
    RCLONE_CONFIG="$BATS_TEST_TMPDIR/operator.conf" AWS_ACCESS_KEY_ID=marker-state-access-key-id \
    AWS_SECRET_ACCESS_KEY=marker-state-secret-key \
    bash -c '. "$1/scripts/lib/s3.sh" && s3_rclone state listremotes && s3_rclone state config file' _ "$REPO"

  [ "$status" -eq 0 ]
  [ "$output" = $'store:\nConfiguration is in memory only' ]
}

@test "A new key pair is written to .env without being shown" {
  # Names empty or quoted empty, a comment between them, and lines that must stay as they are:
  # quotes, a CRLF ending, a line without a value the recipes read.
  {
    printf '%s\n' '# The operator'"'"'s own notes.' 'OS_CLOUD=fixture-cloud' 'TF_STATE_BUCKET="marker-state-bucket"' '' \
      'CLUSTER_S3_ACCESS_KEY_ID=' '# Between the pair.' 'CLUSTER_S3_SECRET_ACCESS_KEY=""'
    printf 'WINDOWS_LINE=kept\r\n'
    printf '%s\n' "OTHER='kept as it is'  "
  } > "$REPO/.env"
  cp "$REPO/.env" "$BATS_TEST_TMPDIR/before"
  inode=$(stat -c %i "$REPO/.env")

  recipe infra-s3-key cluster

  [ "$status" -eq 0 ]
  [[ $output == *"infra-s3-key: wrote a new cluster key pair to .env as CLUSTER_S3_ACCESS_KEY_ID and CLUSTER_S3_SECRET_ACCESS_KEY"* ]]
  [ "$(calls openstack ec2)" = 'openstack ec2 credentials create -f json' ]
  [ "$(grep -cx 'CLUSTER_S3_ACCESS_KEY_ID=marker-new-access-key' "$REPO/.env")" -eq 1 ]
  [ "$(grep -cx 'CLUSTER_S3_SECRET_ACCESS_KEY=marker-new-secret-key' "$REPO/.env")" -eq 1 ]
  [ "$(wc -l < "$REPO/.env")" -eq "$(wc -l < "$BATS_TEST_TMPDIR/before")" ]
  pair='^CLUSTER_S3_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)='
  cmp <(grep -avE "$pair" "$BATS_TEST_TMPDIR/before") <(grep -avE "$pair" "$REPO/.env")
  # Written through a temporary file beside it, mode 0600, renamed into place.
  [ "$(stat -c %a "$REPO/.env")" = 600 ]
  [ "$(stat -c %i "$REPO/.env")" != "$inode" ]
  started mv | grep -qE "^mv -f -- $REPO/\.env\.[^ /]+ $REPO/\.env$"
  [ -z "$(find "$REPO" -maxdepth 1 -name '.env.*')" ]
  for marker in marker-new-access-key marker-new-secret-key fixture-project-id; do
    [[ $output != *"$marker"* ]]
  done
  # The recipes read the pair back as written.
  all_buckets
  clear_record

  recipe infra-backup-check

  [ "$status" -eq 0 ]
  [ -n "$(rclone_envs ' store:marker-prefix-etcd$')" ]
  while IFS= read -r file; do
    [ "$(env_value "$file" RCLONE_CONFIG_STORE_ACCESS_KEY_ID)" = marker-new-access-key ]
    [ "$(env_value "$file" RCLONE_CONFIG_STORE_SECRET_ACCESS_KEY)" = marker-new-secret-key ]
  done < <(rclone_envs ' store:marker-prefix-')

  # Placeholders are replaced.
  printf '%s\n' 'CLUSTER_S3_ACCESS_KEY_ID=example-cluster-access-key' "CLUSTER_S3_SECRET_ACCESS_KEY='example-cluster-secret-key'" > "$REPO/.env"

  recipe infra-s3-key cluster

  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/.env")" = $'CLUSTER_S3_ACCESS_KEY_ID=marker-new-access-key\nCLUSTER_S3_SECRET_ACCESS_KEY=marker-new-secret-key' ]

  # Absent names are appended, each after a one-line comment, after a last line without a newline.
  printf '%s' 'OS_CLOUD=fixture-cloud' > "$REPO/.env"
  without OS_CLOUD

  recipe infra-s3-key state

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$REPO/.env")" -eq 5 ]
  [ "$(sed -n 1p "$REPO/.env")" = OS_CLOUD=fixture-cloud ]
  [ "$(sed -n 3p "$REPO/.env")" = AWS_ACCESS_KEY_ID=marker-new-access-key ]
  [ "$(sed -n 5p "$REPO/.env")" = AWS_SECRET_ACCESS_KEY=marker-new-secret-key ]
  [[ $(sed -n 2p "$REPO/.env") == '# '* && $(sed -n 4p "$REPO/.env") == '# '* ]]
  [ "$(stat -c %a "$REPO/.env")" = 600 ]

  # Without a .env, one is created, mode 0600.
  rm "$REPO/.env"
  reset_environment

  recipe infra-s3-key cluster

  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$REPO/.env")" = 600 ]
  [ "$(grep -v '^#' "$REPO/.env")" = $'CLUSTER_S3_ACCESS_KEY_ID=marker-new-access-key\nCLUSTER_S3_SECRET_ACCESS_KEY=marker-new-secret-key' ]

  # When the rename fails, .env is as it was and the temporary file is gone.
  printf '%s\n' 'OS_CLOUD=fixture-cloud' 'CLUSTER_S3_ACCESS_KEY_ID=' > "$REPO/.env"
  cp "$REPO/.env" "$BATS_TEST_TMPDIR/before"
  fake mv <<EOF
printf '%s\n' "mv \$*" >> "$RECORD/argv"
exit 1
EOF

  recipe infra-s3-key cluster

  [ "$status" -ne 0 ]
  [[ $output == *".env was not written"* ]]
  cmp "$BATS_TEST_TMPDIR/before" "$REPO/.env"
  [ -z "$(find "$REPO" -maxdepth 1 -name '.env.*')" ]
  [[ $output != *marker-new-* ]]
}

@test "A name that already holds a key is refused before anything is created" {
  for set in cluster state; do
    if [[ $set == cluster ]]; then
      name=CLUSTER_S3_ACCESS_KEY_ID
      printf '%s\n' 'CLUSTER_S3_ACCESS_KEY_ID=marker-existing-key' 'CLUSTER_S3_SECRET_ACCESS_KEY=' > "$REPO/.env"
    else
      name=AWS_SECRET_ACCESS_KEY
      printf '%s\n' 'AWS_ACCESS_KEY_ID=' 'AWS_SECRET_ACCESS_KEY="marker-existing-key"' > "$REPO/.env"
    fi
    echo "$set"
    cp "$REPO/.env" "$BATS_TEST_TMPDIR/before"
    clear_record

    recipe infra-s3-key "$set"

    [ "$status" -ne 0 ]
    [[ $output == *"$name already holds a value in .env"* ]]
    [[ $output != *marker-existing-key* ]]
    [ -z "$(started openstack)" ]
    cmp "$BATS_TEST_TMPDIR/before" "$REPO/.env"
  done
}

@test "A .env that is a symlink or not ignored is refused" {
  echo 'OS_CLOUD=fixture-cloud' > "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$REPO/.env"

  recipe infra-s3-key cluster

  [ "$status" -ne 0 ]
  [[ $output == *".env is a symlink"* ]]
  [ -L "$REPO/.env" ]
  [ "$(cat "$BATS_TEST_TMPDIR/elsewhere")" = OS_CLOUD=fixture-cloud ]
  [ -z "$(started openstack)" ]

  rm "$REPO/.env"
  echo '*.tfstate' > "$REPO/.gitignore"

  recipe infra-s3-key cluster

  [ "$status" -ne 0 ]
  [[ $output == *".env is not ignored by git"* ]]
  [ ! -e "$REPO/.env" ]
  [ -z "$(started openstack)" ]

  # A .env git tracks is not ignored either, whatever the ignore rules say.
  cp "$ROOT/.gitignore" "$REPO/.gitignore"
  echo 'OS_CLOUD=fixture-cloud' > "$REPO/.env"
  git -C "$REPO" add -f .env

  recipe infra-s3-key cluster

  [ "$status" -ne 0 ]
  [[ $output == *".env is not ignored by git"* ]]
  [ "$(cat "$REPO/.env")" = OS_CLOUD=fixture-cloud ]
  [ -z "$(started openstack)" ]
}

@test "The cluster's key must differ from the state key" {
  all_buckets

  recipe infra-backup-check

  [ "$status" -eq 0 ]
  [[ $output == *"pass  the cluster's key is not the state key"* ]]
  [[ $output != *FAIL* ]]

  without CLUSTER_S3_ACCESS_KEY_ID
  with CLUSTER_S3_ACCESS_KEY_ID=marker-state-access-key-id

  recipe infra-backup-check

  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  the cluster's key is not the state key: both have the same access key ID"* ]]
  [[ $output != *marker-state-access-key-id* ]]
  [[ $output != *marker-cluster-secret-key* ]]
}

@test "The backup check reports each bucket the cluster's key cannot list" {
  printf '%s\n' marker-prefix-etcd marker-prefix-postgres > "$STORE/ours"

  recipe infra-backup-check

  [ "$status" -ne 0 ]
  for suffix in etcd postgres; do
    [[ $output == *"pass  the cluster's key lists the $suffix bucket"* ]]
  done
  for suffix in openbao volsync; do
    [[ $output == *"FAIL  the cluster's key lists the $suffix bucket: "* ]]
  done
  for suffix in "${SUFFIXES[@]}"; do
    [ "$(rclone_envs "^rclone lsf .*store:marker-prefix-$suffix\$" | wc -l)" -eq 1 ]
    file=$(rclone_envs "^rclone lsf .*store:marker-prefix-$suffix\$")
    [ "$(env_value "$file" RCLONE_CONFIG_STORE_ACCESS_KEY_ID)" = marker-cluster-access-key-id ]
    [ "$(env_value "$file" RCLONE_CONFIG_STORE_SECRET_ACCESS_KEY)" = marker-cluster-secret-key ]
  done
  [ -z "$(calls rclone mkdir)" ]
  [[ $output != *marker-prefix* && $output != *"not found"* && $output != *marker-endpoint* ]]
}

@test "No stack owns a bucket" {
  fake tofu < /dev/null
  repo="$BATS_TEST_TMPDIR/stacks"
  git init -q "$repo"
  cd "$repo" || return 1
  encrypted='terraform {
  encryption {
    state {
      enforced = true
    }
    plan {
      enforced = true
    }
  }
}'
  mkdir -p infra/openstack/stacks/region/good infra/openstack/stacks/region/state \
    infra/openstack/stacks/region/backups infra/openstack/modules/store
  # Reading a bucket, or an object in one, does not own it.
  cat > infra/openstack/stacks/region/good/main.tf <<EOF
$encrypted

data "aws_s3_bucket" "existing" {
  bucket = "fixture-existing"
}

resource "openstack_objectstorage_object_v1" "note" {
  container_name = "fixture-existing"
  name           = "note"
}
EOF
  cat > infra/openstack/stacks/region/state/main.tf <<EOF
$encrypted

resource "openstack_objectstorage_container_v1" "state" {
  name = "fixture-state"
}
EOF
  cat > infra/openstack/stacks/region/backups/main.tf <<EOF
$encrypted

module "store" {
  source = "../../../modules/store"
}
EOF
  cat > infra/openstack/modules/store/main.tf <<'EOF'
resource aws_s3_bucket backups {
  bucket = "fixture-backups"
}
EOF

  run env PATH="$BIN:$PATH" "$ROOT/scripts/infra-check"

  [ "$status" -ne 0 ]
  [[ $output == *"infra-check: infra/openstack/stacks/region/state: declares the bucket openstack_objectstorage_container_v1.state;"* ]]
  [[ $output == *"infra-check: infra/openstack/modules/store: declares the bucket aws_s3_bucket.backups;"* ]]
  [[ $output != *"region/good: declares"* && $output != *"region/backups: declares"* ]]
  [[ ${lines[-1]} == "infra-check: failed: "* ]]
  [[ " ${lines[-1]#infra-check: failed: } " == *" infra/openstack/stacks/region/state "* ]]
  [[ " ${lines[-1]#infra-check: failed: } " == *" infra/openstack/modules/store "* ]]
  [[ ${lines[-1]} != *region/good* ]]
}

@test "A missing variable stops the backup and key recipes before anything runs" {
  all_buckets
  needs=(
    'infra-backup-buckets: BACKUP_BUCKET_PREFIX AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY'
    'infra-backup-check: BACKUP_BUCKET_PREFIX AWS_ACCESS_KEY_ID CLUSTER_S3_ACCESS_KEY_ID CLUSTER_S3_SECRET_ACCESS_KEY'
    'infra-s3-key cluster: OS_CLOUD'
    'infra-s3-key state: OS_CLOUD'
  )
  for need in "${needs[@]}"; do
    read -ra run_names <<< "${need#*: }"
    read -ra run <<< "${need%%: *}"
    for name in "${run_names[@]}"; do
      for how in unset empty placeholder; do
        echo "${run[*]}: $name $how"
        reset_environment
        without "$name"
        case $how in
          empty) with "$name=" ;;
          placeholder) with "$name=example-$name" ;;
        esac
        clear_record

        recipe "${run[@]}"

        [ "$status" -ne 0 ]
        if [[ $name == OS_CLOUD && $how != placeholder ]]; then
          [[ $output == *"OS_CLOUD or OS_AUTH_URL is not set"* ]]
        elif [[ $how == placeholder ]]; then
          [[ $output == *"$name still holds the placeholder from .env.example"* ]]
        else
          [[ $output == *"$name is not set"* ]]
        fi
        [ -z "$(started rclone openstack)" ]
      done
    done
  done
}

@test "a bucket prefix that is not part of a bucket name is refused without being printed" {
  for prefix in Marker_Prefix -marker-prefix marker-prefix- "marker prefix" \
    marker-prefix-that-is-much-too-long-for-a-bucket-name-with-its-role; do
    echo "$prefix"
    reset_environment
    without BACKUP_BUCKET_PREFIX
    with "BACKUP_BUCKET_PREFIX=$prefix"
    for run in infra-backup-buckets infra-backup-check; do
      clear_record

      recipe "$run"

      [ "$status" -ne 0 ]
      [[ $output == *"BACKUP_BUCKET_PREFIX is not "* ]]
      [[ $output != *"$prefix"* ]]
      [ -z "$(started rclone)" ]
    done
  done
}

@test "the bucket recipe creates nothing when the state key cannot list the buckets" {
  : > "$STORE/list-fails"

  recipe infra-backup-buckets

  [ "$status" -ne 0 ]
  [[ $output == *"the state key cannot list the object storage's buckets; nothing was created"* ]]
  [ -z "$(calls rclone mkdir)" ]
  [[ $output != *marker-endpoint* && $output != *AccessDenied* ]]
}

@test "a bucket the S3 client cannot create is named by its role" {
  echo marker-prefix-etcd > "$STORE/ours"
  : > "$STORE/mkdir-fails"

  recipe infra-backup-buckets

  [ "$status" -ne 0 ]
  [[ $output == *"infra-backup-buckets: the etcd bucket exists; nothing to create"* ]]
  for suffix in openbao volsync postgres; do
    grep -qx "infra-backup-buckets: the $suffix bucket could not be created" <<< "$output"
  done
  [[ $output != *marker-prefix* && $output != *TooManyBuckets* ]]
}

@test "the backup recipes say the S3 client is required when it is missing" {
  # A PATH with the tools the recipes use, but no rclone.
  tools="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$tools"
  for tool in bash env dirname mkdir cat paste sed awk tr sort; do
    ln -s "$(command -v "$tool")" "$tools/$tool"
  done
  rm "$BIN/rclone"

  for run in infra-backup-buckets infra-backup-check; do
    run timeout 60 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$tools" "${ENVIRONMENT[@]}" \
      "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$run"

    [ "$status" -ne 0 ]
    [[ $output == *"rclone is not on PATH; install the pinned tools with: just tools"* ]]
  done
}

@test "infra-s3-key takes the state or the cluster key set" {
  recipe infra-s3-key other

  [ "$status" -eq 2 ]
  [[ $output == *"usage: infra-s3-key state|cluster"* ]]
  [ -z "$(started openstack)" ]
}

@test "infra-s3-key needs the openstack client os-smoke needs" {
  fake_openstack 6.2.0

  recipe infra-s3-key cluster

  [ "$status" -ne 0 ]
  [[ $output == *"python-openstackclient 7.0.0 or newer is needed"* ]]
  [ -z "$(calls openstack ec2)" ]
  [ ! -e "$REPO/.env" ]
}

@test "infra-s3-key writes nothing when the openstack client fails or answers without a key pair" {
  for answer in fails '{"access": "marker-new-access-key", "secret": ""}' 'not json marker-new-secret-key'; do
    echo "$answer"
    if [[ $answer == fails ]]; then
      fake openstack <<EOF
[[ \$1 == --version ]] && { echo 'openstack 10.5.0'; exit 0; }
echo "Unauthorized at https://identity.example.invalid for fixture-project-id" >&2
exit 1
EOF
    else
      fake openstack <<EOF
[[ \$1 == --version ]] && { echo 'openstack 10.5.0'; exit 0; }
echo '$answer'
EOF
    fi

    recipe infra-s3-key cluster

    [ "$status" -ne 0 ]
    if [[ $answer == fails ]]; then
      [[ $output == *"the openstack client cannot create an EC2 credential with these credentials"* ]]
    else
      [[ $output == *"the openstack client's answer holds no access key and secret key; .env was not written"* ]]
    fi
    [ ! -e "$REPO/.env" ]
    [[ $output != *marker-new-* && $output != *fixture-project-id* && $output != *identity.example.invalid* ]]
  done
}
