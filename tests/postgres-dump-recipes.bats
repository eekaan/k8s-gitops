#!/usr/bin/env bats
# Proves the last four scenarios of features/postgresql.feature, those of the recipes that list a
# database's dumps and check one; each test carries its scenario's title.
# The recipes run from a copy of the repository with an environment of their own, so no run reads
# this checkout's .env. Encrypting and decrypting are local and offline, so they run the pinned age
# with throwaway keys inside the test's temporary directory. Everything that would reach the object
# storage or run a container is a recording fake: rclone (tests/fixtures/postgres-dump-recipes/rclone,
# whose buckets are directories), the container runtime, whose pg_restore reads a made-up archive,
# and stat, which says which directories are memory-backed. The archives hold markers (a table's name,
# a row), which no recipe may print.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  JUST=$(command -v just)
  FIXTURES=$BATS_TEST_DIRNAME/fixtures/postgres-dump-recipes
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  STORE="$BATS_TEST_TMPDIR/store"
  FAILS="$BATS_TEST_TMPDIR/store-fails"
  # The recipes' TMPDIR, and the memory-backed directory they prefer, where their private
  # directories are made and must be gone afterwards.
  WORK="$BATS_TEST_TMPDIR/tmp"
  RUN="$BATS_TEST_TMPDIR/run"
  mkdir -p "$BIN" "$RECORD" "$STATE" "$STORE" "$FAILS" "$WORK" "$RUN" "$BATS_TEST_TMPDIR/keys" \
    "$BATS_TEST_TMPDIR/repo/infra/openstack" "$BATS_TEST_TMPDIR/repo/kubernetes/components/cnpg-cluster"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  cp -R "$ROOT/scripts" "$REPO/scripts"
  # The component's own CronJob: the check reads the PostgreSQL image from it.
  cp "$ROOT/kubernetes/components/cnpg-cluster/cronjob.yaml" "$REPO/kubernetes/components/cnpg-cluster/cronjob.yaml"
  # The backend file, the endpoint's only source, with a marker for the endpoint.
  ENDPOINT=https://marker-endpoint.example.invalid
  sed -E "s#https://[^\"]+#$ENDPOINT#" "$ROOT/infra/openstack/backend.hcl" > "$REPO/infra/openstack/backend.hcl"
  grep -qF "$ENDPOINT" "$REPO/infra/openstack/backend.hcl"
  # The Talos age key, a throwaway one, and another that no dump is encrypted to.
  KEY="$BATS_TEST_TMPDIR/keys/talos.agekey"
  age-keygen -o "$KEY" 2> /dev/null
  RECIPIENT=$(age-keygen -y "$KEY")
  age-keygen -o "$BATS_TEST_TMPDIR/keys/other.agekey" 2> /dev/null
  OTHER_RECIPIENT=$(age-keygen -y "$BATS_TEST_TMPDIR/keys/other.agekey")
  BUCKET='marker-prefix-postgres'
  mkdir -p "$STORE/$BUCKET"
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  printf '#!/usr/bin/env bash\n' > "$BIN/mise"
  chmod +x "$BIN/mise"
  for tool in rclone docker stat; do
    cp "$FIXTURES/$tool" "$BIN/$tool"
  done
  command -v stat > "$STATE/real-stat"
  record age jq yq mktemp
  BASE_ENVIRONMENT=(
    SOPS_AGE_KEY_FILE="$KEY"
    BACKUP_BUCKET_PREFIX=marker-prefix
    AWS_ACCESS_KEY_ID=marker-state-access-key-id
    AWS_SECRET_ACCESS_KEY=marker-state-secret-key
    TMPDIR="$WORK"
    XDG_RUNTIME_DIR="$RUN"
  )
  reset_environment
}

# record NAME...: puts each NAME's arguments in the record, then runs the real NAME.
record() {
  local tool real
  for tool; do
    real=$(command -v "$tool")
    { echo '#!/usr/bin/env bash'; printf '%s\n' "printf '%s\n' \"$tool \$*\" >> \"$RECORD/argv\"" "exec \"$real\" \"\$@\""; } > "$BIN/$tool"
    chmod +x "$BIN/$tool"
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

calls() {
  grep -E -- "$1" "$RECORD/argv" 2> /dev/null || true
}

clear_record() {
  rm -f "$RECORD"/*
}

# archive TABLES EMPTY: what a dump holds in the clear, as the fake pg_restore reads it: TABLES tables
# that hold rows and EMPTY tables that hold none, each named by a marker, and a row of each marker. As
# pg_dump writes them, every table has its TABLE entry and its TABLE DATA entry, an empty one too, and
# pg_restore --list prints the TABLE entries first.
archive() {
  local table
  cat <<'EOF'
PGDMP
;
; Archive created at 2026-11-15 02:00:12 UTC
;     dbname: marker_dbname
;     TOC Entries: 12
;     Compression: gzip
;     Dump Version: 1.16-0
;     Format: CUSTOM
;     Integer: 4 bytes
;     Offset: 8 bytes
;     Dumped from database version: 18.6 (Debian 18.6-1.pgdg13+1)
;     Dumped by pg_dump version: 18.6 (Debian 18.6-1.pgdg13+1)
;
;
; Selected TOC Entries:
;
EOF
  for ((table = 1; table <= ${1:-2}; table++)); do
    echo "$((200 + table)); 1259 1638$table TABLE public marker_table_$table marker_owner"
  done
  for ((table = 1; table <= ${2:-1}; table++)); do
    echo "$((250 + table)); 1259 1639$table TABLE public marker_empty_table_$table marker_owner"
  done
  for ((table = 1; table <= ${1:-2}; table++)); do
    echo "$((4000 + table)); 0 1638$table TABLE DATA public marker_table_$table marker_owner"
  done
  for ((table = 1; table <= ${2:-1}; table++)); do
    echo "$((4050 + table)); 0 1639$table TABLE DATA public marker_empty_table_$table marker_owner"
  done
  echo '-----ROWS-----'
  echo 'marker-row-secret-value'
}

# put_object NAMESPACE NAME OBJECT: stores the standard input as OBJECT of the database's path.
put_object() {
  mkdir -p "$(dirname "$STORE/$BUCKET/lab-sto2/$1/$2/$3")"
  cat > "$STORE/$BUCKET/lab-sto2/$1/$2/$3"
}

# put_dump NAMESPACE NAME OBJECT [TABLES [EMPTY]]: stores an archive of TABLES tables with rows and
# EMPTY without, encrypted to the Talos age key's recipient.
put_dump() {
  archive "${4:-2}" "${5:-1}" | age --encrypt --recipient "$RECIPIENT" | put_object "$1" "$2" "$3"
}

# put_dumps: three dumps of apps/db, of 2, 3 and 4 tables, and one of apps/other, which holds no table,
# as the dump of a database without one does.
put_dumps() {
  put_dump apps db 20261101T020000Z.dump.age 1
  put_dump apps db 20261103T020012Z.dump.age 2
  put_dump apps db 20261102T020000Z.dump.age 3
  put_dump apps other 20261104T020000Z.dump.age 0 0
}

# nothing_left: neither the recipes' TMPDIR nor their memory-backed directory holds anything.
nothing_left() {
  local left
  left=$(find "$WORK" "$RUN" -mindepth 1)
  if [[ -n $left ]]; then
    echo "left on disk: $left" >&2
    return 1
  fi
}

# absent: the output names nothing of the dumps' contents or of the deployment.
absent() {
  local marker
  for marker in marker_table marker_empty marker_owner marker_pgrestore marker_dbname marker-row marker-endpoint marker-prefix \
    marker-state "$ENDPOINT" "$RECIPIENT" "$BUCKET"; do
    [[ $output != *"$marker"* ]] || { echo "the output holds $marker" >&2; return 1; }
  done
}

@test "The dumps of a database are listed newest first by name and size" {
  # Each object holds as many bytes as its name has characters, and the dumps a few more each, so
  # that every name is paired with its own size. The S3 client lists a prefix's objects oldest name
  # first, as S3 lists keys.
  for object in 20261102T020000Z.dump.age:2 20261103T020012Z.dump.age:6 2026110T020000Z.dump.age:0 notes.txt:0 \
    20261101T020000Z.dump.age:4; do
    printf '%s' "${object%:*}${object%:*}" | head -c $((${#object} - 2 + ${object##*:})) | put_object apps db "${object%:*}"
  done
  printf 'x' | put_object apps db old/20261105T020000Z.dump.age
  printf '%s' 20261106T020000Z.dump.age | put_object apps other 20261106T020000Z.dump.age
  printf 'x' | put_object apps db 20261104T020000Z.snapshot.age

  recipe postgres-dumps apps db

  [ "$status" -eq 0 ]
  [ "$output" = $'20261103T020012Z.dump.age 31\n20261102T020000Z.dump.age 27\n20261101T020000Z.dump.age 29' ]
  [ "$(calls '^rclone ' | wc -l)" -eq 1 ]
  [[ $(calls '^rclone ') == *" store:$BUCKET/lab-sto2/apps/db/" ]]
  absent

  # Another cluster's dumps are its own path's, and a database without a dump lists nothing.
  mkdir -p "$STORE/$BUCKET/lab-sto2-old/apps/db"
  printf 'x' > "$STORE/$BUCKET/lab-sto2-old/apps/db/20261105T020000Z.dump.age"

  recipe postgres-dumps apps db lab-sto2-old

  [ "$status" -eq 0 ]
  [ "$output" = '20261105T020000Z.dump.age 1' ]

  recipe postgres-dumps apps none

  [ "$status" -eq 0 ]
  [ "$output" = "postgres-dumps: the postgres bucket holds no dump of apps/none on lab-sto2" ]

  # With no database named, the databases that have a dump, and not a database's path that holds
  # other objects only.
  printf 'x' | put_object apps stray notes.txt
  recipe postgres-dumps

  [ "$status" -eq 0 ]
  [ "$output" = $'apps/db\napps/other' ]
  absent
  [ -z "$(calls '^(docker|age) ')" ]

  recipe postgres-dumps lab-sto2-old

  [ "$status" -eq 0 ]
  [ "$output" = 'apps/db' ]
}

@test "A dump is checked by decrypting it and reading its archive, and nothing of its contents is printed" {
  put_dumps
  encrypted=$(stat -c %s "$STORE/$BUCKET/lab-sto2/apps/db/20261103T020012Z.dump.age")
  plain=$(archive 2 1 | wc -c)

  recipe postgres-dump-check apps db

  [ "$status" -eq 0 ]
  [ "$output" = "dump: 20261103T020012Z.dump.age
scratch: memory-backed
encrypted: $encrypted bytes
plain: $plain bytes
format: CUSTOM
PostgreSQL: 18.6, dumped by pg_dump 18.6
taken: 2026-11-15 02:00:12 UTC
tables: 3" ]
  absent
  # pg_restore runs from the component's image, by its digest, in a container that is removed, logs
  # nowhere, has no network and no capability, and is confined, from a read-only mount of a directory
  # of the memory-backed one, as the user's own uid; and the image follows the component's.
  image=$(yq '.spec.jobTemplate.spec.template.spec.initContainers[] | select(.name == "dump") | .image' \
    "$ROOT/kubernetes/components/cnpg-cluster/cronjob.yaml")
  [[ $image == *@sha256:* ]]
  for fact in "image $image" "network none" "entrypoint pg_restore" "mode ro" "rm yes" "read-only yes" \
    "log-driver none" "cap-drop ALL" "security-opt no-new-privileges" "user $(id -u):$(id -g)"; do
    grep -qxF "$fact" "$RECORD/docker-mount"
  done
  [[ $(sed -n 's/^host //p' "$RECORD/docker-mount") == "$RUN"/* ]]
  other=ghcr.io/cloudnative-pg/postgresql:18.7-standard-trixie@sha256:$(printf 'a%.0s' {1..64})
  IMAGE=$other yq -i '(.spec.jobTemplate.spec.template.spec.initContainers[] | select(.name == "dump") | .image) = strenv(IMAGE)' \
    "$REPO/kubernetes/components/cnpg-cluster/cronjob.yaml"
  recipe postgres-dump-check apps db
  [ "$status" -eq 0 ]
  grep -qxF "image $other" "$RECORD/docker-mount"
  cp "$ROOT/kubernetes/components/cnpg-cluster/cronjob.yaml" "$REPO/kubernetes/components/cnpg-cluster/cronjob.yaml"
  clear_record
  recipe postgres-dump-check apps db
  [ "$status" -eq 0 ]
  # The newest dump of the database, downloaded once, and nothing else of the bucket.
  [ "$(calls '^rclone copyto ' | wc -l)" -eq 1 ]
  [[ $(calls '^rclone copyto ') == *" store:$BUCKET/lab-sto2/apps/db/20261103T020012Z.dump.age "* ]]
  # age writes the plain dump straight into the private directory in memory, and nowhere first.
  [ "$(calls '^age --decrypt ' | wc -l)" -eq 1 ]
  decrypted=$(calls '^age --decrypt ' | sed -n 's/.* --output \([^ ]*\) .*/\1/p')
  [[ $decrypted == "$RUN"/* && $decrypted == "$(sed -n 's/^host //p' "$RECORD/docker-mount")"/* ]]
  nothing_left

  # A dump named, and the newest dump of the database on another cluster, from that cluster's path.
  recipe postgres-dump-check apps db 20261101T020000Z.dump.age

  [ "$status" -eq 0 ]
  [[ $output == "dump: 20261101T020000Z.dump.age"$'\n'* && $output == *$'\ntables: 2' ]]
  absent
  nothing_left

  mkdir -p "$STORE/$BUCKET/lab-sto2-old/apps/db"
  archive 1 0 | age --encrypt --recipient "$RECIPIENT" > "$STORE/$BUCKET/lab-sto2-old/apps/db/20261001T020000Z.dump.age"
  clear_record
  recipe postgres-dump-check apps db latest lab-sto2-old

  [ "$status" -eq 0 ]
  [[ $output == "dump: 20261001T020000Z.dump.age"$'\n'* && $output == *$'\ntables: 1' ]]
  [[ $(calls '^rclone copyto ') == *" store:$BUCKET/lab-sto2-old/apps/db/20261001T020000Z.dump.age "* ]]
  absent
  nothing_left
}

@test "the check reads pg_restore's image from the component and runs it without a network on a read-only mount in memory" {
  put_dumps
  image=$(yq '.spec.jobTemplate.spec.template.spec.initContainers[] | select(.name == "dump") | .image' \
    "$ROOT/kubernetes/components/cnpg-cluster/cronjob.yaml")
  [[ $image == ghcr.io/cloudnative-pg/postgresql:*@sha256:* ]]

  recipe postgres-dump-check apps db

  [ "$status" -eq 0 ]
  grep -qxF "image $image" "$RECORD/docker-mount"
  grep -qxF "network none" "$RECORD/docker-mount"
  grep -qxF "entrypoint pg_restore" "$RECORD/docker-mount"
  grep -qxF "mode ro" "$RECORD/docker-mount"
  [[ $(sed -n 's/^host //p' "$RECORD/docker-mount") == "$RUN"/* ]]
  [[ $(calls '^docker ') == *"--list"* ]]
  # The digest has one source: a component whose image changes changes the check's.
  other=ghcr.io/cloudnative-pg/postgresql:18.7-standard-trixie@sha256:$(printf 'a%.0s' {1..64})
  IMAGE=$other yq -i '(.spec.jobTemplate.spec.template.spec.initContainers[] | select(.name == "dump") | .image) = strenv(IMAGE)' \
    "$REPO/kubernetes/components/cnpg-cluster/cronjob.yaml"

  recipe postgres-dump-check apps db

  [ "$status" -eq 0 ]
  grep -qxF "image $other" "$RECORD/docker-mount"
}

@test "a component whose dump step's image has no digest fails the check, naming the component" {
  put_dumps
  yq -i '(.spec.jobTemplate.spec.template.spec.initContainers[] | select(.name == "dump") | .image) |= sub("@sha256:[0-9a-f]+$"; "")' \
    "$REPO/kubernetes/components/cnpg-cluster/cronjob.yaml"
  image=$(yq '.spec.jobTemplate.spec.template.spec.initContainers[] | select(.name == "dump") | .image' \
    "$REPO/kubernetes/components/cnpg-cluster/cronjob.yaml")
  [[ $image == ghcr.io/cloudnative-pg/postgresql:* && $image != *@* ]]

  recipe postgres-dump-check apps db

  [ "$status" -ne 0 ]
  grep -qxF "postgres-dump-check: kubernetes/components/cnpg-cluster/cronjob.yaml names no image of the dump step by tag and digest" \
    <<< "$output"
  [ -z "$(calls '^(rclone|docker|age) ')" ]
  nothing_left
}

@test "the check says so when no memory-backed filesystem exists, and uses the disk TMPDIR names" {
  put_dumps
  : > "$STATE/no-memory"

  recipe postgres-dump-check apps db

  [ "$status" -eq 0 ]
  [[ $output == *$'\nscratch: disk, as no memory-backed filesystem was found; removed afterwards\n'* ]]
  [[ $(sed -n 's/^host //p' "$RECORD/docker-mount") == "$WORK"/* ]]
  decrypted=$(calls '^age --decrypt ' | sed -n 's/.* --output \([^ ]*\) .*/\1/p')
  [[ $decrypted == "$WORK"/* && $decrypted == "$(sed -n 's/^host //p' "$RECORD/docker-mount")"/* ]]
  absent
  nothing_left
}

@test "A dump that is not encrypted, does not decrypt or cannot be read fails the check with its reason" {
  # Not encrypted: a plain archive where the dump should be.
  archive 2 1 | put_object apps db 20261101T020000Z.dump.age

  recipe postgres-dump-check apps db latest

  [ "$status" -ne 0 ]
  [[ $output == *"postgres-dump-check: 20261101T020000Z.dump.age is not an age file"* ]]
  [ -z "$(calls '^docker ')" ]
  absent
  nothing_left

  # Not decryptable: encrypted to a key that is not the Talos age key.
  archive 2 1 | age --encrypt --recipient "$OTHER_RECIPIENT" | put_object apps db 20261102T020000Z.dump.age

  recipe postgres-dump-check apps db latest

  [ "$status" -ne 0 ]
  [[ $output == *"postgres-dump-check: the Talos age key cannot decrypt 20261102T020000Z.dump.age"* ]]
  [ -z "$(calls '^docker ')" ]
  absent
  nothing_left

  # Not readable: an age file that holds no archive.
  printf 'marker-row-secret-value is no archive\n' | age --encrypt --recipient "$RECIPIENT" | put_object apps db 20261103T020000Z.dump.age

  recipe postgres-dump-check apps db latest

  [ "$status" -ne 0 ]
  [[ $output == *"postgres-dump-check: pg_restore cannot read 20261103T020000Z.dump.age"* ]]
  [ -n "$(calls '^docker ')" ]
  absent
  nothing_left
}

@test "a check that finds no dump, no table or no object fails with its reason" {
  recipe postgres-dump-check apps db

  [ "$status" -ne 0 ]
  [[ $output == *"postgres-dump-check: the postgres bucket holds no dump of apps/db on lab-sto2"* ]]
  nothing_left

  put_dumps
  recipe postgres-dump-check apps db 20261105T020000Z.dump.age

  [ "$status" -ne 0 ]
  [[ $output == *"postgres-dump-check: the postgres bucket holds no dump 20261105T020000Z.dump.age of apps/db on lab-sto2"* ]]
  nothing_left

  recipe postgres-dump-check apps other

  [ "$status" -ne 0 ]
  grep -qxF "postgres-dump-check: the archive of 20261104T020000Z.dump.age holds no table" <<< "$output"
  [[ $output != *"tables: "* ]]
  absent
  nothing_left

  # Tables that hold no row are tables of the archive all the same: pg_dump writes a data entry for
  # each, so the count does not tell an empty database's dump from one of the same tables with rows.
  put_dump apps empty 20261105T020000Z.dump.age 0 2
  recipe postgres-dump-check apps empty

  [ "$status" -eq 0 ]
  [[ $output == *$'\ntables: 2' ]]
  absent
  nothing_left

  : > "$FAILS/download"
  recipe postgres-dump-check apps db

  [ "$status" -ne 0 ]
  [[ $output == *"postgres-dump-check: rclone cannot download 20261103T020012Z.dump.age"* ]]
  [[ $output == *"AccessDenied"* ]]
  absent
  nothing_left
}

@test "The check leaves nothing behind, whether it passes, fails or is interrupted" {
  put_dumps
  archive 2 1 | put_object apps notage 20261101T020000Z.dump.age
  printf 'no archive\n' | age --encrypt --recipient "$RECIPIENT" | put_object apps unreadable 20261101T020000Z.dump.age

  recipe postgres-dump-check apps db

  [ "$status" -eq 0 ]
  [ -n "$(sed -n 's/^host //p' "$RECORD/docker-mount")" ]
  [ ! -e "$(sed -n 's/^host //p' "$RECORD/docker-mount")" ]
  nothing_left

  archive 2 1 | age --encrypt --recipient "$OTHER_RECIPIENT" | put_object apps undecryptable 20261101T020000Z.dump.age
  for database in notage undecryptable unreadable other none; do
    recipe postgres-dump-check apps "$database"

    [ "$status" -ne 0 ]
    nothing_left
  done

  : > "$FAILS/download"
  recipe postgres-dump-check apps db
  rm "$FAILS/download"

  [ "$status" -ne 0 ]
  nothing_left

  for container in dies handles; do
    echo "$container" > "$STATE/interrupt"
    clear_record

    recipe postgres-dump-check apps db

    [ "$status" -ne 0 ]
    [ -f "$RECORD/docker-mount" ]
    [ ! -e "$(sed -n 's/^host //p' "$RECORD/docker-mount")" ]
    [[ $output != *"tables: "* ]]
    nothing_left
  done
  rm "$STATE/interrupt"

  # With no memory-backed filesystem the plain dump is on the disk, and goes just the same.
  : > "$STATE/no-memory"
  recipe postgres-dump-check apps db

  [ "$status" -eq 0 ]
  nothing_left
}

@test "the dump recipes name every missing precondition before anything runs" {
  put_dumps
  without SOPS_AGE_KEY_FILE
  without BACKUP_BUCKET_PREFIX
  without AWS_ACCESS_KEY_ID

  recipe postgres-dumps apps db

  [ "$status" -ne 0 ]
  [[ $output == *"BACKUP_BUCKET_PREFIX is not set"* && $output == *"AWS_ACCESS_KEY_ID is not set"* ]]
  [ -z "$(calls '^rclone ')" ]

  # Without the container runtime, or the age key, the check says which is missing, and downloads
  # nothing. A runtime named by CONTAINER_RUNTIME that is not on PATH is one that is missing.
  with CONTAINER_RUNTIME=marker-runtime

  recipe postgres-dump-check apps db

  [ "$status" -ne 0 ]
  for message in "BACKUP_BUCKET_PREFIX is not set" "AWS_ACCESS_KEY_ID is not set" \
    "neither SOPS_AGE_KEY_FILE nor SOPS_AGE_KEY is set" "marker-runtime is not on PATH"; do
    [[ $output == *"$message"* ]]
  done
  [ -z "$(calls '^rclone ')" ]
  nothing_left

  # A bucket prefix that is not the start of a bucket's name is refused without being printed.
  reset_environment
  without BACKUP_BUCKET_PREFIX
  with BACKUP_BUCKET_PREFIX=Marker_Prefix
  for run in "postgres-dumps apps db" "postgres-dump-check apps db"; do
    read -ra words <<< "$run"
    recipe "${words[@]}"

    [ "$status" -ne 0 ]
    [[ $output == *"BACKUP_BUCKET_PREFIX is not the start of a bucket name"* ]]
    [[ $output != *Marker_Prefix* ]]
  done
}

@test "the dump recipes refuse what is no namespace, name, dump or cluster" {
  put_dumps
  for arguments in "Apps db" "apps db/old" "apps .." "apps db latest -x" "apps db 20261101.dump.age" "apps db latest ../x" \
    "apps"; do
    read -ra words <<< "$arguments"
    recipe postgres-dump-check "${words[@]}"

    [ "$status" -ne 0 ]
  done
  recipe postgres-dumps Apps db

  [ "$status" -ne 0 ]
  recipe postgres-dumps apps db/x

  [ "$status" -ne 0 ]
  [ -z "$(calls '^(rclone|docker|age) ')" ]

  # The same recipes take the arguments they are meant to.
  recipe postgres-dumps apps db

  [ "$status" -eq 0 ]
  recipe postgres-dump-check apps db latest lab-sto2

  [ "$status" -eq 0 ]
}

@test "a failed S3 request shows its reason without the endpoint, the bucket or a key" {
  put_dumps
  : > "$FAILS/list"

  for run in "postgres-dumps apps db" "postgres-dumps" "postgres-dump-check apps db"; do
    read -ra words <<< "$run"
    recipe "${words[@]}"

    [ "$status" -ne 0 ]
    [[ $output == *"AccessDenied"* ]]
    absent
    nothing_left
  done
  rm "$FAILS/list"
  rm -r "${STORE:?}/$BUCKET"

  recipe postgres-dumps apps db

  [ "$status" -ne 0 ]
  [[ $output == *"directory not found"* ]]
  absent
}

@test "the container runtime, called by name as podman or by path, sees none of the secrets, and podman alone keeps the uid" {
  put_dumps
  cp "$BIN/docker" "$BIN/podman"
  with AWS_SECRET_ACCESS_KEY=marker-state-secret-key CLUSTER_S3_ACCESS_KEY_ID=marker-cluster-id \
    CLUSTER_S3_SECRET_ACCESS_KEY=marker-cluster-secret OS_APPLICATION_CREDENTIAL_SECRET=marker-cloud-secret \
    SOPS_AGE_KEY=marker-age-key TF_VAR_marker=marker-input

  for runtime in docker podman "$BIN/docker"; do
    clear_record
    with CONTAINER_RUNTIME="$runtime"

    recipe postgres-dump-check apps db

    [ "$status" -eq 0 ]
    [ -s "$RECORD/runtime-env" ]
    # Not a name of a secret, and not a value of one.
    if grep -qE '^(AWS_|OS_|CLUSTER_S3_|SOPS_AGE_|TF_VAR_)|marker-(state|cluster|cloud|age|input)' "$RECORD/runtime-env"; then
      echo "$runtime saw a secret" >&2
      return 1
    fi
    # The scratch directory is the recipe's own: the runtime's temporary files are not kept in it.
    grep -qxF "TMPDIR=$WORK" "$RECORD/runtime-env"
    [[ $(calls "^${runtime##*/} ") == *"--list"* ]]
    # podman is told to map the user's uid into the container; docker, which has no such mode, is not.
    if [[ ${runtime##*/} == podman ]]; then
      grep -qxF "userns keep-id" "$RECORD/docker-mount"
    else
      grep -qxF "userns " "$RECORD/docker-mount"
    fi
  done
}

@test "the check shows the container runtime's own errors, and nothing pg_restore says" {
  put_dumps

  # The runtime fails: it cannot reach its daemon.
  echo 125 > "$STATE/runtime-exit"
  recipe postgres-dump-check apps db

  [ "$status" -ne 0 ]
  [[ $output == *"marker-daemon"* ]]
  [[ $output == *"postgres-dump-check: docker cannot run pg_restore"* ]]
  absent
  nothing_left

  # The container is killed by a signal, so its standard error is pg_restore's.
  echo 137 > "$STATE/runtime-exit"
  recipe postgres-dump-check apps db

  [ "$status" -ne 0 ]
  [[ $output != *marker-daemon* ]]
  [[ $output == *"postgres-dump-check: pg_restore cannot read 20261103T020012Z.dump.age"* ]]
  absent
  nothing_left
  rm "$STATE/runtime-exit"

  # pg_restore fails on the archive.
  printf 'no archive\n' | age --encrypt --recipient "$RECIPIENT" | put_object apps db 20261110T020000Z.dump.age
  recipe postgres-dump-check apps db

  [ "$status" -ne 0 ]
  absent
}

@test "a dump that fails to decrypt for another reason than the key says so, and the key is not blamed" {
  put_dumps
  printf 'age-encryption.org/v1\ngarbage\n' | put_object apps db 20261110T020000Z.dump.age

  recipe postgres-dump-check apps db

  [ "$status" -ne 0 ]
  [[ $output == *"postgres-dump-check: age cannot read 20261110T020000Z.dump.age"* ]]
  [[ $output != *"key cannot decrypt"* ]]
  [ -z "$(calls '^docker ')" ]
  nothing_left
}

@test "a failed check says which disk it used when no memory-backed filesystem exists" {
  put_dumps
  : > "$STATE/no-memory"
  printf 'no archive\n' | age --encrypt --recipient "$RECIPIENT" | put_object apps db 20261110T020000Z.dump.age

  recipe postgres-dump-check apps db

  [ "$status" -ne 0 ]
  [[ $output == *"no memory-backed filesystem was found"* ]]
  nothing_left
}

@test "a binary object that is no age file is refused without bash warning about its bytes" {
  printf 'PGDMP\000\001\002binary archive header bytes' | put_object apps db 20261101T020000Z.dump.age

  recipe postgres-dump-check apps db

  [ "$status" -ne 0 ]
  [[ $output == *"is not an age file"* ]]
  [[ $output != *"null byte"* ]]
}
