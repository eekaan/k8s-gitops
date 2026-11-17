#!/usr/bin/env bats
# Proves the last four scenarios of features/openbao-snapshots.feature, those of the recipes that
# list the secret store's snapshots and check one; each test that proves a scenario carries its title.
# The recipes run from a copy of the repository with an environment of their own, so no run reads
# this checkout's .env. Encrypting and decrypting are local and offline, so they run the pinned age,
# recorded on its way, with throwaway keys inside the test's temporary directory. What would reach
# the object storage is the recording fake of the dump recipes' tests
# (tests/fixtures/postgres-dump-recipes/rclone, whose buckets are directories), and stat is theirs
# too, which says which directories are memory-backed. tar, gzip and jq are the machine's and the
# pinned one, recorded on their way; sha256sum is a stand-in that hashes with the real one and, when
# a test says so, interrupts the recipe first (tests/fixtures/openbao-snapshot-recipes/sha256sum).
#
# The archives are built here, with tar, gzip, sha256sum and jq, as the pinned OpenBao builds one
# (internal/physical/raft/snapshot/archive.go in its source) and as GNU tar lists a genuine one of
# that release, taken from a server of its own:
#   -rw------- 0/0             195 2026-11-16 19:32:31 meta.json
#   -rw------- 0/0           15052 2026-11-16 19:32:31 state.bin
#   -rw------- 0/0             152 2026-11-16 19:32:31 SHA256SUMS
#   -rw------- 0/0             203 2026-11-16 19:32:31 SHA256SUMS.sealed
# a ustar archive, owner and group 0 without names, mode 0600, one time for every member, two empty
# blocks right after the last member, in a gzip stream. Its members hold markers (a server's ID and
# address, a storage key and value, the sealed checksums), which no recipe may print.
# Needs flux, kustomize, yq, jq and age on PATH (the versions pinned for the repository), and GNU tar.

bats_require_minimum_version 1.5.0

# The snapshot job, whose own scripts one test runs, and the helpers that build it.
# shellcheck disable=SC2034
JOB_APP=kubernetes/apps/base/openbao/openbao-snapshots
# shellcheck disable=SC2034
JOB_NAME=openbao-snapshots
load fixtures/etcd-snapshots/job

setup_file() {
  job_setup_file
}

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  JUST=$(command -v just)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  STORE="$BATS_TEST_TMPDIR/store"
  FAILS="$BATS_TEST_TMPDIR/store-fails"
  # Where a test builds an archive's members, and the archive itself, in the clear.
  STAGE="$BATS_TEST_TMPDIR/stage"
  PLAIN="$BATS_TEST_TMPDIR/plain"
  # The recipes' TMPDIR, and the memory-backed directory they prefer, where their private
  # directories are made and must be gone afterwards.
  WORK="$BATS_TEST_TMPDIR/tmp"
  RUN="$BATS_TEST_TMPDIR/run"
  mkdir -p "$BIN" "$RECORD" "$STATE" "$STORE" "$FAILS" "$WORK" "$RUN" "$BATS_TEST_TMPDIR/keys" \
    "$BATS_TEST_TMPDIR/repo/infra/openstack"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  cp -R "$ROOT/scripts" "$REPO/scripts"
  # The backend file, the endpoint's only source, with a marker for the endpoint.
  ENDPOINT=https://marker-endpoint.example.invalid
  sed -E "s#https://[^\"]+#$ENDPOINT#" "$ROOT/infra/openstack/backend.hcl" > "$REPO/infra/openstack/backend.hcl"
  grep -qF "$ENDPOINT" "$REPO/infra/openstack/backend.hcl"
  # The Talos age key, a throwaway one, and another that no snapshot is encrypted to.
  KEY="$BATS_TEST_TMPDIR/keys/talos.agekey"
  age-keygen -o "$KEY" 2> /dev/null
  RECIPIENT=$(age-keygen -y "$KEY")
  age-keygen -o "$BATS_TEST_TMPDIR/keys/other.agekey" 2> /dev/null
  OTHER_RECIPIENT=$(age-keygen -y "$BATS_TEST_TMPDIR/keys/other.agekey")
  BUCKET='marker-prefix-openbao'
  mkdir -p "$STORE/$BUCKET"
  # The time on the members of the archives a test builds, in UTC.
  TAKEN='2026-11-15 00:43:07'
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  printf '#!/usr/bin/env bash\n' > "$BIN/mise"
  chmod +x "$BIN/mise"
  for tool in rclone stat; do
    cp "$BATS_TEST_DIRNAME/fixtures/postgres-dump-recipes/$tool" "$BIN/$tool"
  done
  cp "$BATS_TEST_DIRNAME/fixtures/openbao-snapshot-recipes/sha256sum" "$BIN/sha256sum"
  command -v stat > "$STATE/real-stat"
  command -v sha256sum > "$STATE/real-sha256sum"
  record age jq tar gzip
  # Only the state key is there to reach the bucket with: a recipe that asked for the cluster's would
  # find none.
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

# record NAME...: puts each NAME's arguments in the record, then runs the real NAME. What a call of
# tar or gzip is given of the variables those read goes to the record as well, a line for each call:
# tar's locale, the value of LC_ALL, to tar-locale, and to options the program's name and then the
# name of each of TAR_OPTIONS and GZIP that its environment holds.
record() {
  local tool real
  for tool; do
    real=$(command -v "$tool")
    {
      echo '#!/usr/bin/env bash'
      printf '%s\n' "printf '%s\n' \"$tool \$*\" >> \"$RECORD/argv\""
      [[ $tool != tar ]] || printf '%s\n' "printf '%s\n' \"\${LC_ALL-unset}\" >> \"$RECORD/tar-locale\""
      [[ $tool != tar && $tool != gzip ]] ||
        printf '%s\n' "printf '%s\n' \"$tool:\${TAR_OPTIONS+ TAR_OPTIONS}\${GZIP+ GZIP}\" >> \"$RECORD/options\""
      printf '%s\n' "exec \"$real\" \"\$@\""
    } > "$BIN/$tool"
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

# recipe NAME [ARG...]: runs the repository's recipe against the copy, with only ENVIRONMENT set and
# the fakes first on PATH, or on RECIPE_PATH when a test sets it. A recipe that blocks fails after
# two minutes instead of hanging the tests.
recipe() {
  run timeout 120 env -i HOME="$BATS_TEST_TMPDIR" PATH="${RECIPE_PATH:-$BIN:$PATH}" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$@"
}

# recipe_streams NAME [ARG...]: recipe, with what it writes to standard error kept apart, in stderr.
recipe_streams() {
  run --separate-stderr timeout 120 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$@"
}

calls() {
  grep -E -- "$1" "$RECORD/argv" 2> /dev/null || true
}

clear_record() {
  rm -f "$RECORD"/*
}

# meta [FILTER]: writes meta.json into STAGE: raft's metadata as the pinned OpenBao encodes it, one
# line of JSON with the fields of raft's SnapshotMeta under Go's names, for the state.bin in STAGE,
# three servers named and addressed by markers, changed by the jq FILTER.
meta() {
  jq -cn --argjson size "$(stat -c %s "$STAGE/state.bin")" '{Version: 1, ID: "bolt-snapshot", Index: 4711, Term: 3, Peers: null,
    Configuration: {Servers: [range(3) | {Suffrage: 0, ID: "marker-member-\(.)", Address: "marker-address-\(.).example.invalid:8201"}]},
    ConfigurationIndex: 1, Size: $size} | '"${1:-.}" > "$STAGE/meta.json"
}

# sums [MEMBER...]: writes SHA256SUMS into STAGE as the pinned OpenBao writes it: for each MEMBER,
# in the order given, its SHA-256, two spaces and its name. OpenBao writes the two lines from a Go
# map, in an order that differs from one snapshot to the next: state.bin's first, when none is given.
sums() {
  local member
  (($#)) || set -- state.bin meta.json
  for member; do
    printf '%s  %s\n' "$(sha256sum < "$STAGE/$member" | cut -d' ' -f1)" "$member"
  done > "$STAGE/SHA256SUMS"
}

# members [FILTER]: the four members of a snapshot in STAGE: state.bin, bytes that stand for the
# storage's entries, their keys in the clear; SHA256SUMS.sealed, bytes that stand for the checksums
# sealed by the store's seal; meta.json, with FILTER, as meta writes it; and SHA256SUMS, as sums
# writes it. The state differs from one call to the next.
members() {
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  printf 'marker-storage-key\000\001marker-storage-value %s\n' "$RANDOM$RANDOM" > "$STAGE/state.bin"
  printf 'marker-sealed-checksums\000\002' > "$STAGE/SHA256SUMS.sealed"
  meta "${1:-.}"
  sums
}

# archive [ARGUMENT...]: the members of STAGE as one snapshot archive on standard output, as the
# header says a genuine one is. tar is given the four names in the order OpenBao writes them, or
# the ARGUMENTs in their place: other names, another order, options of its own.
archive() {
  (($#)) || set -- meta.json state.bin SHA256SUMS SHA256SUMS.sealed
  tar --create --format=ustar --owner=0 --group=0 --numeric-owner --mode=0600 --mtime="$TAKEN UTC" \
    --blocking-factor=1 --directory "$STAGE" --file - "$@" | gzip -c
}

# encrypt [RECIPIENT]: standard input encrypted with age to RECIPIENT, the Talos age key's by default.
encrypt() {
  age --encrypt --recipient "${1:-$RECIPIENT}"
}

# put NAME [CLUSTER]: stores standard input as the object NAME under CLUSTER's path, lab-sto2's by
# default, in the OpenBao bucket.
put() {
  mkdir -p "$STORE/$BUCKET/${2:-lab-sto2}"
  cat > "$STORE/$BUCKET/${2:-lab-sto2}/$1"
}

# snapshot NAME [CLUSTER [ARGUMENT...]]: stores the archive of STAGE's members, made with archive's
# ARGUMENTs, as the snapshot NAME of CLUSTER, lab-sto2 by default, encrypted to the Talos age key's
# recipient, keeps the archive in PLAIN, and sets what the check prints of it: plain_size,
# encrypted_size, state_size and sealed_size.
snapshot() {
  local name=$1 cluster=${2:-lab-sto2}
  shift
  (($# == 0)) || shift
  archive "$@" > "$PLAIN"
  encrypt < "$PLAIN" | put "$name" "$cluster"
  plain_size=$(stat -c %s "$PLAIN")
  encrypted_size=$(stat -c %s "$STORE/$BUCKET/$cluster/$name")
  state_size=$(stat -c %s "$STAGE/state.bin")
  sealed_size=$(stat -c %s "$STAGE/SHA256SUMS.sealed")
}

# result NAME TAKEN INDEX TERM SERVERS [SCRATCH]: the lines the check prints for the snapshot that
# snapshot stored last.
result() {
  cat <<EOF
snapshot: $1
scratch: ${6:-memory-backed}
encrypted: $encrypted_size bytes
plain: $plain_size bytes
taken: $2 UTC
index: $3
term: $4
metadata version: 1
members: $5
state: $state_size bytes
checksums: meta.json and state.bin match SHA256SUMS
sealed checksums: $sealed_size bytes, not opened: only the store's seal key opens them
EOF
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

# absent: the output names nothing of the snapshots' contents or of the deployment: no marker, and
# no checksum of a member of the archive in STAGE.
absent() {
  local marker member
  for marker in marker-member marker-address marker-storage marker-sealed marker-endpoint marker-prefix marker-state \
    "$ENDPOINT" "$RECIPIENT" "$BUCKET"; do
    [[ $output != *"$marker"* ]] || { echo "the output holds $marker" >&2; return 1; }
  done
  for member in meta.json state.bin; do
    [[ -f $STAGE/$member ]] || continue
    marker=$(sha256sum < "$STAGE/$member" | cut -d' ' -f1)
    [[ $output != *"$marker"* ]] || { echo "the output holds the checksum of $member" >&2; return 1; }
  done
}

# fails_with REASON...: the last run failed with exactly the lines REASON..., each after the recipe's
# name, then the step it failed in, the archive's verification unless STEP names another, and then
# only the line just reports a failed recipe with.
fails_with() {
  local reason n=0
  [ "$status" -eq 1 ]
  for reason; do
    [ "${lines[n]}" = "openbao-snapshot-check: $reason" ]
    n=$((n + 1))
  done
  [ "${lines[n]}" = "openbao-snapshot-check: failed while ${STEP:-verifying the archive of $newest}" ]
  # just quotes the recipe's name.
  [[ ${lines[n + 1]} == "error: recipe "?"openbao-snapshot-check"?" failed on line "*" with exit code 1" ]]
  [ "${#lines[@]}" -eq $((n + 2)) ]
}

# refused REASON: PLAIN, stored encrypted as a snapshot newer than every other, fails the check as
# no raft snapshot archive, for REASON, and nothing of it is printed or left.
refused() {
  day=$((${day:-0} + 1))
  newest=$(printf '202611%02dT004300Z.snapshot.age' "$day")
  encrypt < "$PLAIN" | put "$newest"
  echo "$newest: $1"
  recipe openbao-snapshot-check
  fails_with "$newest is not a raft snapshot archive: $1"
  absent
  nothing_left
}

# only_reads CALL: whether the recorded call of tar lists an archive, or extracts with every member
# written to standard output: either way it writes no file.
only_reads() {
  local word list=0 extract=0 stdout=0
  local -a words
  read -ra words <<< "$1"
  for word in "${words[@]:1}"; do
    case $word in
      --list) list=1 ;;
      --extract | --get) extract=1 ;;
      --to-stdout) stdout=1 ;;
      --*) ;;
      -*)
        [[ $word != *t* ]] || list=1
        [[ $word != *x* ]] || extract=1
        [[ $word != *O* ]] || stdout=1
        ;;
    esac
  done
  ((list && !extract)) || ((extract && stdout && !list))
}

@test "The secret store's snapshots are listed newest first by name and size" {
  # Every object has a size of its own. The S3 client lists a prefix's objects oldest name first, as
  # S3 lists keys.
  for object in lab-sto2/20261102T064300Z.snapshot.age:27 lab-sto2/20261103T124300Z.snapshot.age:31 \
    lab-sto2/20261101T004300Z.snapshot.age:29 lab-sto2/2026110T004300Z.snapshot.age:11 lab-sto2/notes.txt:12 \
    lab-sto2/20261104T004300Z.dump.age:13 lab-sto2/20261104T004300Z.snapshot.age.part:14 \
    lab-sto2/old/20261105T004300Z.snapshot.age:15 lab-sto2-old/20261106T004300Z.snapshot.age:16 \
    20261107T004300Z.snapshot.age:17; do
    mkdir -p "$(dirname "$STORE/$BUCKET/${object%:*}")"
    head -c "${object##*:}" /dev/zero > "$STORE/$BUCKET/${object%:*}"
  done
  # The etcd bucket holds snapshots of the same cluster, named the same way.
  mkdir -p "$STORE/marker-prefix-etcd/lab-sto2"
  head -c 18 /dev/zero > "$STORE/marker-prefix-etcd/lab-sto2/20261108T001700Z.snapshot.age"

  recipe_streams openbao-snapshots

  [ "$status" -eq 0 ]
  [ "$output" = $'20261103T124300Z.snapshot.age 31\n20261102T064300Z.snapshot.age 27\n20261101T004300Z.snapshot.age 29' ]
  [ -z "$stderr" ]
  # One request, for the cluster's own path of the OpenBao bucket, and nothing but listing.
  [ "$(calls '^rclone ')" = "rclone lsjson --files-only store:$BUCKET/lab-sto2/" ]
  [ -z "$(calls '^(age|tar|gzip|sha256sum) ')" ]
  absent

  # Another cluster's snapshots are its own path's.
  clear_record
  recipe_streams openbao-snapshots lab-sto2-old

  [ "$status" -eq 0 ]
  [ "$output" = '20261106T004300Z.snapshot.age 16' ]
  [ "$(calls '^rclone ')" = "rclone lsjson --files-only store:$BUCKET/lab-sto2-old/" ]

  # A cluster without snapshots lists nothing, and says so beside the listing, not in it.
  recipe_streams openbao-snapshots lab-sto2-new

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$stderr" = "openbao-snapshots: the openbao bucket holds no snapshot of lab-sto2-new" ]
  nothing_left
}

@test "A snapshot of the secret store is checked by decrypting it and verifying its archive, and nothing of the state is printed" {
  # Three snapshots of the cluster, the newest neither the first nor the last stored, each with
  # metadata and a time of its own, and one of another cluster.
  TAKEN='2026-11-01 00:43:11'
  members '.Index = 12 | .Term = 2 | .Configuration.Servers |= .[0:1]'
  snapshot 20261101T004300Z.snapshot.age
  first=$(result 20261101T004300Z.snapshot.age '2026-11-01 00:43:11' 12 2 1)
  TAKEN='2026-11-03 12:43:07'
  members
  snapshot 20261103T124300Z.snapshot.age
  newest_state=$state_size newest_plain=$plain_size newest_encrypted=$encrypted_size newest_sealed=$sealed_size
  cp -R "$STAGE" "$BATS_TEST_TMPDIR/newest"
  TAKEN='2026-11-02 06:43:09'
  members '.Index = 300'
  snapshot 20261102T064300Z.snapshot.age
  # No server in its metadata, and its checksums in the other order.
  TAKEN='2026-10-01 00:43:01'
  members '.Index = 7 | .Term = 1 | .Configuration = {Servers: null}'
  sums meta.json state.bin
  snapshot 20261001T004300Z.snapshot.age lab-sto2-old
  other=$(result 20261001T004300Z.snapshot.age '2026-10-01 00:43:01' 7 1 0)
  rm -rf "$STAGE"
  mv "$BATS_TEST_TMPDIR/newest" "$STAGE"

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "snapshot: 20261103T124300Z.snapshot.age
scratch: memory-backed
encrypted: $newest_encrypted bytes
plain: $newest_plain bytes
taken: 2026-11-03 12:43:07 UTC
index: 4711
term: 3
metadata version: 1
members: 3
state: $newest_state bytes
checksums: meta.json and state.bin match SHA256SUMS
sealed checksums: $newest_sealed bytes, not opened: only the store's seal key opens them" ]
  absent
  # The newest snapshot of the cluster, downloaded once into the memory-backed directory, and
  # nothing else of the bucket.
  [ "$(calls '^rclone ' | wc -l)" -eq 2 ]
  [ "$(calls '^rclone lsjson ')" = "rclone lsjson --files-only store:$BUCKET/lab-sto2/" ]
  [[ $(calls '^rclone copyto ') == "rclone copyto store:$BUCKET/lab-sto2/20261103T124300Z.snapshot.age $RUN/"*/20261103T124300Z.snapshot.age ]]
  # age reads that file and writes the plain archive beside it, in memory, and nowhere first.
  [ "$(calls '^age ' | wc -l)" -eq 1 ]
  downloaded=$(calls '^rclone copyto ' | sed 's/.* //')
  decrypted=$(calls '^age --decrypt ' | sed -n 's/.* --output \([^ ]*\) .*/\1/p')
  [[ $(calls '^age --decrypt ') == "age --decrypt --identity $KEY --output $decrypted $downloaded" ]]
  [[ $decrypted == "${downloaded%/*}"/* ]]
  # gzip tests the archive, and tar only lists it and writes members to standard output.
  [ -n "$(calls '^gzip (-t|--test)( |$)')" ]
  mapfile -t tars < <(calls '^tar ')
  [ "${#tars[@]}" -ge 4 ]
  for call in "${tars[@]}"; do
    only_reads "$call"
  done
  [ -z "$(find "$REPO" "$WORK" "$RUN" -name 'meta.json*' -o -name state.bin -o -name 'SHA256SUMS*')" ]
  nothing_left

  # A snapshot named, and the newest snapshot of another cluster, from that cluster's path.
  recipe openbao-snapshot-check 20261101T004300Z.snapshot.age

  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  absent
  nothing_left

  clear_record
  recipe openbao-snapshot-check latest lab-sto2-old

  [ "$status" -eq 0 ]
  [ "$output" = "$other" ]
  [[ $(calls '^rclone copyto ') == "rclone copyto store:$BUCKET/lab-sto2-old/20261001T004300Z.snapshot.age $RUN/"* ]]
  absent
  nothing_left
}

@test "A snapshot that is not encrypted, does not decrypt, is no raft snapshot archive or fails a checksum fails the check with its reason" {
  members

  # Not encrypted: a plain archive where the snapshot should be.
  newest=20261101T004300Z.snapshot.age
  archive | put "$newest"
  recipe openbao-snapshot-check

  STEP="decrypting $newest with the Talos age key" fails_with "$newest is not an age file"
  [ -z "$(calls '^(age|gzip|tar|sha256sum) ')" ]
  absent
  nothing_left

  # Not decryptable: encrypted to a key that is not the Talos age key.
  newest=20261102T004300Z.snapshot.age
  archive | encrypt "$OTHER_RECIPIENT" | put "$newest"
  recipe openbao-snapshot-check

  STEP="decrypting $newest with the Talos age key" fails_with "the Talos age key cannot decrypt $newest"
  [ -z "$(calls '^(gzip|tar|sha256sum) ')" ]
  absent
  nothing_left

  # No raft snapshot archive: an age file that holds a text.
  newest=20261103T004300Z.snapshot.age
  printf 'marker-storage-value is no archive\n' | encrypt | put "$newest"
  recipe openbao-snapshot-check

  fails_with "$newest is not a raft snapshot archive: it is not gzip to its end, with nothing after it but zero bytes"
  absent
  nothing_left

  # A checksum that differs: the state changed after its checksum was taken, at the same length, so
  # only the checksum tells.
  newest=20261104T004300Z.snapshot.age
  tr 'k' 'K' < "$STAGE/state.bin" > "$STAGE/changed"
  mv "$STAGE/changed" "$STAGE/state.bin"
  archive | encrypt | put "$newest"
  recipe openbao-snapshot-check

  fails_with "$newest fails its integrity check: the SHA-256 of state.bin is not the one SHA256SUMS gives"
  [[ $output != *"checksums: "* ]]
  absent
  nothing_left

  # And the metadata's: its checksum is another file's.
  newest=20261105T004300Z.snapshot.age
  members
  printf '%s  meta.json\n%s  state.bin\n' "$(sha256sum < "$STAGE/SHA256SUMS.sealed" | cut -d' ' -f1)" \
    "$(sha256sum < "$STAGE/state.bin" | cut -d' ' -f1)" > "$STAGE/SHA256SUMS"
  archive | encrypt | put "$newest"
  recipe openbao-snapshot-check

  fails_with "$newest fails its integrity check: the SHA-256 of meta.json is not the one SHA256SUMS gives"
  [[ $output != *"checksums: "* ]]
  absent
  nothing_left
}

@test "The snapshot check leaves nothing behind, whether it passes, fails or is interrupted" {
  members
  snapshot 20261103T124300Z.snapshot.age
  # Each way the check fails: no age file, another key's, no archive, a checksum list that is none,
  # and, for the cluster none, no snapshot.
  archive | put 20261101T004300Z.snapshot.age notage
  archive | encrypt "$OTHER_RECIPIENT" | put 20261101T004300Z.snapshot.age undecryptable
  printf 'no archive\n' | encrypt | put 20261101T004300Z.snapshot.age unreadable
  printf 'x  meta.json\n' > "$STAGE/SHA256SUMS"
  archive | encrypt | put 20261101T004300Z.snapshot.age unchecked

  # With a memory-backed directory, and then without one, when the archives are on the disk and the
  # check says so first.
  for kept in "$RUN" "$WORK"; do
    echo "kept under $kept"
    notice=0
    if [[ $kept == "$WORK" ]]; then
      : > "$STATE/no-memory"
      notice=1
    fi
    clear_record

    recipe openbao-snapshot-check

    [ "$status" -eq 0 ]
    # The plain archive was written, into a directory that is gone.
    decrypted=$(calls '^age --decrypt ' | sed -n 's/.* --output \([^ ]*\) .*/\1/p')
    [[ $decrypted == "$kept"/*/* ]]
    [ ! -e "${decrypted%/*}" ]
    nothing_left

    for cluster in notage undecryptable unreadable unchecked none; do
      echo "$cluster"
      recipe openbao-snapshot-check latest "$cluster"

      [ "$status" -eq 1 ]
      nothing_left
    done

    : > "$FAILS/download"
    recipe openbao-snapshot-check
    rm "$FAILS/download"

    [ "$status" -eq 1 ]
    nothing_left

    # Interrupted while the encrypted and the plain archive are in the private directory, by Ctrl-C
    # and by SIGTERM, whether the program then running dies of the signal or handles it and exits 0:
    # the run ends with the status a shell gives a run its signal ended.
    for signal in INT TERM; do
      echo "$signal" > "$STATE/signal"
      ended=130
      [[ $signal == INT ]] || ended=143
      for program in dies handles; do
        echo "$signal $program"
        echo "$program" > "$STATE/interrupt"
        clear_record

        recipe openbao-snapshot-check

        [ "$status" -eq "$ended" ]
        # The directory, which only the user can enter, held the encrypted and the plain archive,
        # each readable by the user alone.
        read -r private mode < "$RECORD/interrupted"
        [[ $private == "$kept"/* ]]
        [ "$mode" = 700 ]
        grep -qxF "20261103T124300Z.snapshot.age $encrypted_size 600" "$RECORD/interrupted"
        grep -qx ".* $plain_size 600" "$RECORD/interrupted"
        [ ! -e "$private" ]
        # The step it was in, and nothing of a result or of a verdict on the archive.
        [ "${lines[notice]}" = "openbao-snapshot-check: failed while verifying the archive of 20261103T124300Z.snapshot.age" ]
        [ "${#lines[@]}" -eq $((notice + 2)) ]
        [[ ${lines[notice + 1]} == "error: recipe "* ]]
        nothing_left
      done
    done
    rm "$STATE/interrupt" "$STATE/signal"
  done
}

@test "the snapshot recipes name every missing precondition before rclone runs" {
  members
  snapshot 20261101T004300Z.snapshot.age
  without SOPS_AGE_KEY_FILE
  without BACKUP_BUCKET_PREFIX
  without AWS_ACCESS_KEY_ID
  without AWS_SECRET_ACCESS_KEY
  with AWS_SECRET_ACCESS_KEY=example-secret

  recipe openbao-snapshots

  [ "$status" -ne 0 ]
  for message in "BACKUP_BUCKET_PREFIX is not set" "AWS_ACCESS_KEY_ID is not set" \
    "AWS_SECRET_ACCESS_KEY still holds the placeholder"; do
    [[ $output == *"openbao-snapshots: $message"* ]]
  done

  recipe openbao-snapshot-check

  [ "$status" -ne 0 ]
  for message in "BACKUP_BUCKET_PREFIX is not set" "AWS_ACCESS_KEY_ID is not set" \
    "AWS_SECRET_ACCESS_KEY still holds the placeholder" "neither SOPS_AGE_KEY_FILE nor SOPS_AGE_KEY is set"; do
    [[ $output == *"openbao-snapshot-check: $message"* ]]
  done
  [ -z "$(calls '^(rclone|age|tar|gzip|sha256sum) ')" ]
  nothing_left

  # The programs too, each by its name, together with the settings: on a PATH that holds every
  # program of this test's but those seven, the pinned ones and the machine's own.
  only="$BATS_TEST_TMPDIR/only"
  mkdir -p "$only/bin" "$only/programs"
  cp "$BIN/mise" "$only/bin/mise"
  IFS=: read -ra directories <<< "$PATH"
  for directory in "${directories[@]}"; do
    [[ -d $directory ]] || continue
    # A name an earlier directory holds stays that directory's, as on PATH.
    ln -s "$directory"/* "$only/programs/" 2> /dev/null || true
  done
  pinned=(age jq yq rclone)
  own=(tar gzip sha256sum)
  for program in "${pinned[@]}" "${own[@]}"; do
    rm -f "$only/programs/$program"
  done
  clear_record

  RECIPE_PATH="$only/bin:$only/programs" recipe openbao-snapshot-check

  [ "$status" -ne 0 ]
  for message in "BACKUP_BUCKET_PREFIX is not set" "AWS_ACCESS_KEY_ID is not set" \
    "neither SOPS_AGE_KEY_FILE nor SOPS_AGE_KEY is set"; do
    [[ $output == *"openbao-snapshot-check: $message"* ]]
  done
  for program in "${pinned[@]}"; do
    grep -qxF "openbao-snapshot-check: $program is not on PATH; install the pinned tools with: just tools" <<< "$output"
  done
  for program in "${own[@]}"; do
    grep -qxF "openbao-snapshot-check: $program is not on PATH; the check reads the archive with the machine's GNU tar, gzip and sha256sum" <<< "$output"
  done
  [[ $output == *"openbao-snapshot-check: failed while checking the environment"* ]]
  nothing_left

  # A bucket prefix that is not the start of a bucket's name is refused without being printed.
  reset_environment
  without BACKUP_BUCKET_PREFIX
  with BACKUP_BUCKET_PREFIX=Marker_Prefix
  for run in openbao-snapshots openbao-snapshot-check; do
    recipe "$run"

    [ "$status" -ne 0 ]
    [[ $output == *"$run: BACKUP_BUCKET_PREFIX is not the start of a bucket name"* ]]
    [[ $output != *Marker_Prefix* ]]
  done
  [ -z "$(calls '^(rclone|age|tar|gzip|sha256sum) ')" ]
  nothing_left
}

@test "the snapshot check refuses what is no snapshot name, latest or cluster with status 2, before anything runs" {
  members
  snapshot 20261101T004300Z.snapshot.age
  for arguments in "20261101.snapshot.age" "20261101T004300Z.dump.age" "../20261101T004300Z.snapshot.age" \
    "lab-sto2" "LATEST" "latest ../x" "latest Lab-sto2" "latest lab-sto2/x" "20261101T004300Z.snapshot.age lab_sto2"; do
    echo "$arguments"
    read -ra words <<< "$arguments"

    recipe openbao-snapshot-check "${words[@]}"

    [ "$status" -eq 2 ]
    [ "${lines[0]}" = "openbao-snapshot-check: usage: openbao-snapshot-check [<snapshot>|latest] [cluster]; <snapshot> is a name just openbao-snapshots prints" ]
    [[ $output != *"failed while"* ]]
  done
  # One argument too many: the recipe takes none, and the script, run without just, exits 2.
  recipe openbao-snapshot-check latest lab-sto2 extra

  [ "$status" -ne 0 ]
  run env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" "$REPO/scripts/openbao-snapshot-check" latest lab-sto2 extra

  [ "$status" -eq 2 ]
  [[ $output == "openbao-snapshot-check: usage: "* ]]
  [ -z "$(calls '^(rclone|age|tar|gzip|sha256sum) ')" ]
  nothing_left

  # The same recipe takes the arguments it is meant to.
  recipe openbao-snapshot-check latest lab-sto2

  [ "$status" -eq 0 ]
  recipe openbao-snapshot-check 20261101T004300Z.snapshot.age

  [ "$status" -eq 0 ]
}

@test "a failed listing or download shows its reason without the endpoint, the bucket or a key" {
  # A repository with this repository's ignore rules, to see which files git ignores.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q "$REPO"
  cp "$ROOT/.gitignore" "$REPO/.gitignore"
  members
  snapshot 20261101T004300Z.snapshot.age
  for ci in '' true; do
    for case in "list openbao-snapshots" "list openbao-snapshot-check" "download openbao-snapshot-check"; do
      echo "ci=$ci $case"
      read -r way run <<< "$case"
      reset_environment
      [[ -z $ci ]] || with CI=true
      rm -f "$FAILS"/* "$REPO"/talos/lab-sto2/clusterconfig/*.errors.log
      : > "$FAILS/$way"

      recipe "$run"

      [ "$status" -ne 0 ]
      if [[ $way == list ]]; then
        [[ $output == *"$run: rclone cannot list the openbao bucket with the state key, or it does not exist; just infra-backup-buckets creates it"* ]]
      else
        [[ $output == *"$run: rclone cannot download 20261101T004300Z.snapshot.age with the state key"* ]]
      fi
      if [[ -z $ci ]]; then
        [[ $output == *"$run: rclone: "*"AccessDenied"* ]]
      else
        # With CI set the reason is kept in a file git ignores, and only the file is named.
        [[ $output != *"AccessDenied"* ]]
        [[ $output == *"$run: rclone's errors are in talos/lab-sto2/clusterconfig/$run.errors.log"* ]]
        grep -q AccessDenied "$REPO/talos/lab-sto2/clusterconfig/$run.errors.log"
        git -C "$REPO" check-ignore -q "talos/lab-sto2/clusterconfig/$run.errors.log"
      fi
      absent
      nothing_left
    done
  done

  # A bucket that is not there reads differently from one that refuses, and is named by its role.
  reset_environment
  rm -f "$FAILS"/*
  rm -r "${STORE:?}/$BUCKET"
  for run in openbao-snapshots openbao-snapshot-check; do
    recipe "$run"

    [ "$status" -ne 0 ]
    [[ $output == *"$run: rclone: "*"directory not found"* ]]
    [[ $output == *"$run: rclone cannot list the openbao bucket with the state key, or it does not exist; just infra-backup-buckets creates it"* ]]
    absent
    nothing_left
  done
}

@test "a check that finds no snapshot, or not the one named, says so and downloads nothing" {
  recipe openbao-snapshot-check

  newest=
  STEP="finding the snapshot in the openbao bucket" \
    fails_with "the openbao bucket holds no snapshot of lab-sto2; just openbao-snapshots lists them"
  [ -z "$(calls '^rclone copyto ')" ]
  nothing_left

  members
  snapshot 20261101T004300Z.snapshot.age
  snapshot 20261101T004300Z.snapshot.age lab-sto2-old
  recipe openbao-snapshot-check 20261105T004300Z.snapshot.age

  STEP="finding the snapshot in the openbao bucket" \
    fails_with "the openbao bucket holds no snapshot 20261105T004300Z.snapshot.age of lab-sto2; just openbao-snapshots lists them"
  [ -z "$(calls '^rclone copyto ')" ]
  nothing_left

  # A cluster without snapshots, beside one that has them.
  recipe openbao-snapshot-check latest lab-sto2-new

  STEP="finding the snapshot in the openbao bucket" \
    fails_with "the openbao bucket holds no snapshot of lab-sto2-new; just openbao-snapshots lists them"
  [ -z "$(calls '^rclone copyto ')" ]

  # An object that is listed and gone by the time it is downloaded copies nothing: an empty file is
  # no download.
  : > "$STORE/$BUCKET/lab-sto2/20261102T004300Z.snapshot.age"
  recipe openbao-snapshot-check

  STEP="downloading 20261102T004300Z.snapshot.age" \
    fails_with "rclone cannot download 20261102T004300Z.snapshot.age with the state key"
  [ -z "$(calls '^(age|gzip|tar) ')" ]
  nothing_left
}

@test "the snapshot check says so when no memory-backed filesystem exists, and uses the disk TMPDIR names" {
  members
  snapshot 20261101T004300Z.snapshot.age
  : > "$STATE/no-memory"

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "openbao-snapshot-check: no memory-backed filesystem was found; the snapshot is kept on the disk, under TMPDIR, until the check removes it
$(result 20261101T004300Z.snapshot.age '2026-11-15 00:43:07' 4711 3 3 'disk, as no memory-backed filesystem was found; removed afterwards')" ]
  [[ $(calls '^rclone copyto ') == "rclone copyto store:$BUCKET/lab-sto2/20261101T004300Z.snapshot.age $WORK/"* ]]
  decrypted=$(calls '^age --decrypt ' | sed -n 's/.* --output \([^ ]*\) .*/\1/p')
  [[ $decrypted == "$WORK"/*/* ]]
  absent
  nothing_left

  # A check that fails there says where the snapshot was kept, too.
  printf 'no archive\n' | encrypt | put 20261102T004300Z.snapshot.age
  recipe openbao-snapshot-check

  [ "$status" -ne 0 ]
  [[ ${lines[0]} == "openbao-snapshot-check: no memory-backed filesystem was found; "* ]]
  nothing_left
}

@test "a binary object that is no age file is refused without bash warning about its bytes" {
  printf '\037\213\010\000\000\000\000\000\000\377binary gzip header bytes\000' | put 20261101T004300Z.snapshot.age

  recipe openbao-snapshot-check

  newest=20261101T004300Z.snapshot.age
  STEP="decrypting $newest with the Talos age key" fails_with "$newest is not an age file"
  [[ $output != *"null byte"* ]]
  [ -z "$(calls '^(age|gzip|tar) ')" ]
  nothing_left
}

@test "a snapshot that fails to decrypt for another reason than the key says so, and the key is not blamed" {
  members
  snapshot 20261101T004300Z.snapshot.age
  printf 'age-encryption.org/v1\ngarbage\n' | put 20261110T004300Z.snapshot.age

  recipe openbao-snapshot-check

  newest=20261110T004300Z.snapshot.age
  STEP="decrypting $newest with the Talos age key" \
    fails_with "age cannot read $newest, for a reason other than the key: it may be damaged, or the scratch directory full"
  [ -n "$(calls '^age --decrypt ')" ]
  [ -z "$(calls '^(gzip|tar) ')" ]
  nothing_left
}

@test "the Talos age key reaches age by its file's path or on its standard input, never as an argument" {
  members
  snapshot 20261101T004300Z.snapshot.age
  secret=$(grep '^AGE-SECRET-KEY-' "$KEY")
  without SOPS_AGE_KEY_FILE
  with SOPS_AGE_KEY="$secret"

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "$(result 20261101T004300Z.snapshot.age '2026-11-15 00:43:07' 4711 3 3)" ]
  [[ $(calls '^age --decrypt ') == "age --decrypt --identity - --output "* ]]
  [[ $output != *"${secret#AGE-SECRET-KEY-}"* ]]
  nothing_left
  # No program the test records was given the key as an argument.
  [ -n "$(calls '^(age|jq|tar|gzip|sha256sum|rclone) ')" ]
  run ! grep -qF -- "${secret#AGE-SECRET-KEY-}" "$RECORD/argv"
}

@test "the checksum list is taken with its two lines in either order, and its digits in either case" {
  # OpenBao writes the list from a Go map: the order of its lines differs from one snapshot to the next.
  members
  sums meta.json state.bin
  [[ $(head -n 1 "$STAGE/SHA256SUMS") == *"  meta.json" ]]
  snapshot 20261101T004300Z.snapshot.age

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "$(result 20261101T004300Z.snapshot.age '2026-11-15 00:43:07' 4711 3 3)" ]

  members
  sums state.bin meta.json
  [[ $(head -n 1 "$STAGE/SHA256SUMS") == *"  state.bin" ]]
  snapshot 20261102T004300Z.snapshot.age

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "$(result 20261102T004300Z.snapshot.age '2026-11-15 00:43:07' 4711 3 3)" ]

  # The members, too, in another order than OpenBao writes them, as its reader takes them.
  members
  snapshot 20261103T004300Z.snapshot.age lab-sto2 SHA256SUMS.sealed SHA256SUMS state.bin meta.json

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "$(result 20261103T004300Z.snapshot.age '2026-11-15 00:43:07' 4711 3 3)" ]

  # And the checksums in capitals, which OpenBao does not write and reads all the same.
  members
  sed -i 's/^[0-9a-f]*/\U&/' "$STAGE/SHA256SUMS"
  grep -q '^[0-9A-F]*[A-F][0-9A-F]*  ' "$STAGE/SHA256SUMS"
  snapshot 20261104T004300Z.snapshot.age

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "$(result 20261104T004300Z.snapshot.age '2026-11-15 00:43:07' 4711 3 3)" ]
  # A checksum in capitals that is not the member's fails as any other.
  tr 'k' 'K' < "$STAGE/state.bin" > "$STAGE/changed"
  mv "$STAGE/changed" "$STAGE/state.bin"
  newest=20261105T004300Z.snapshot.age
  archive | encrypt | put "$newest"

  recipe openbao-snapshot-check

  fails_with "$newest fails its integrity check: the SHA-256 of state.bin is not the one SHA256SUMS gives"
  nothing_left
}

@test "a file that is no gzip stream, or no tar archive of the four members, fails the check with words of its own" {
  members

  # Not gzip: the tar archive itself.
  archive | gzip -dc > "$PLAIN"
  refused "it is not gzip to its end, with nothing after it but zero bytes"
  # Cut short, and one byte changed: the stream's own checksum no longer holds.
  archive | head -c 300 > "$PLAIN"
  refused "it is not gzip to its end, with nothing after it but zero bytes"
  archive > "$PLAIN"
  printf '\377' | dd of="$PLAIN" bs=1 seek=200 conv=notrunc 2> /dev/null
  refused "it is not gzip to its end, with nothing after it but zero bytes"
  # Bytes after the gzip stream.
  { archive; printf 'marker-storage-value after the end'; } > "$PLAIN"
  refused "it is not gzip to its end, with nothing after it but zero bytes"

  # A gzip stream that holds no tar archive, or the start of one.
  head -c 4096 /dev/urandom | gzip -c > "$PLAIN"
  refused "tar cannot list it to its end"
  archive | gzip -dc | head -c 1000 | gzip -c > "$PLAIN"
  refused "tar cannot list it to its end"

  # A member missing: the sealed checksums, as when the store's seal sealed none, and the metadata.
  archive meta.json state.bin SHA256SUMS > "$PLAIN"
  refused "it holds no SHA256SUMS.sealed"
  archive state.bin SHA256SUMS SHA256SUMS.sealed > "$PLAIN"
  refused "it holds no meta.json"
  archive meta.json SHA256SUMS SHA256SUMS.sealed > "$PLAIN"
  refused "it holds no state.bin"
  archive meta.json state.bin SHA256SUMS.sealed > "$PLAIN"
  refused "it holds no SHA256SUMS"
  # No member at all: an archive of nothing, and a text too short to be one.
  printf 'marker-storage-value\n' | gzip -c > "$PLAIN"
  refused "it holds no meta.json"

  # An extra member.
  printf 'marker-storage-value\n' > "$STAGE/notes.txt"
  archive meta.json state.bin SHA256SUMS SHA256SUMS.sealed notes.txt > "$PLAIN"
  refused "it holds a member that is none of meta.json, state.bin, SHA256SUMS and SHA256SUMS.sealed"
  # A member twice, each a file of its own.
  mkdir "$STAGE/again"
  cp "$STAGE/meta.json" "$STAGE/again/meta.json"
  archive meta.json state.bin SHA256SUMS SHA256SUMS.sealed --directory "$STAGE/again" meta.json > "$PLAIN"
  refused "it holds meta.json more than once"
}

@test "a member under another name, or one that is no regular file, cannot pass as one of the four" {
  members

  # Names that lead out of a directory, or into one.
  archive --absolute-names --transform 's|^meta.json$|../meta.json|' meta.json state.bin SHA256SUMS SHA256SUMS.sealed > "$PLAIN"
  refused "it holds a member that is none of meta.json, state.bin, SHA256SUMS and SHA256SUMS.sealed"
  archive --absolute-names --transform 's|^state.bin$|/state.bin|' meta.json state.bin SHA256SUMS SHA256SUMS.sealed > "$PLAIN"
  refused "it holds a member that is none of meta.json, state.bin, SHA256SUMS and SHA256SUMS.sealed"
  archive --transform 's|^meta.json$|./meta.json|' meta.json state.bin SHA256SUMS SHA256SUMS.sealed > "$PLAIN"
  refused "it holds a member that is none of meta.json, state.bin, SHA256SUMS and SHA256SUMS.sealed"
  archive --transform 's|^SHA256SUMS$|sums/SHA256SUMS|' meta.json state.bin SHA256SUMS SHA256SUMS.sealed > "$PLAIN"
  refused "it holds a member that is none of meta.json, state.bin, SHA256SUMS and SHA256SUMS.sealed"
  # A name that holds a line of the listing in itself, after a newline: tar quotes the newline, so the
  # name stays on its own line and is none of the four.
  cp "$STAGE/meta.json" "$STAGE/decoy"
  archive --transform 's|^decoy$|x\n-rw------- 0/0             195 2026-11-15 00:43:07 meta.json|' \
    decoy state.bin SHA256SUMS SHA256SUMS.sealed > "$PLAIN"
  [ "$(gzip -dc "$PLAIN" | tar --list --file - | wc -l)" -eq 4 ]
  [ "$(gzip -dc "$PLAIN" | tar --list --quoting-style=literal --file - | wc -l)" -eq 5 ]
  refused "it holds a member that is none of meta.json, state.bin, SHA256SUMS and SHA256SUMS.sealed"
  rm "$STAGE/decoy"
  # And a name that is a member's and more.
  cp "$STAGE/meta.json" "$STAGE/meta.json "
  archive 'meta.json ' state.bin SHA256SUMS SHA256SUMS.sealed > "$PLAIN"
  refused "it holds a member that is none of meta.json, state.bin, SHA256SUMS and SHA256SUMS.sealed"
  rm "$STAGE/meta.json "

  # A symbolic link, a hard link and a directory under a member's name.
  mv "$STAGE/meta.json" "$STAGE/kept.json"
  ln -s state.bin "$STAGE/meta.json"
  archive meta.json state.bin SHA256SUMS SHA256SUMS.sealed > "$PLAIN"
  refused "it holds a member that is no regular file"
  rm "$STAGE/meta.json"
  ln "$STAGE/state.bin" "$STAGE/meta.json"
  archive state.bin meta.json SHA256SUMS SHA256SUMS.sealed > "$PLAIN"
  refused "it holds a member that is no regular file"
  rm "$STAGE/meta.json"
  mkdir "$STAGE/meta.json"
  archive meta.json state.bin SHA256SUMS SHA256SUMS.sealed > "$PLAIN"
  refused "it holds a member that is no regular file"
  rmdir "$STAGE/meta.json"
  mv "$STAGE/kept.json" "$STAGE/meta.json"

  # No file of a member's name appeared where the recipe ran, or where it kept the archive.
  [ -z "$(find "$REPO" "$WORK" "$RUN" -name 'meta.json*' -o -name state.bin -o -name 'SHA256SUMS*')" ]
  while IFS= read -r call; do
    only_reads "$call"
  done < <(calls '^tar ')
}

@test "a member OpenBao would not read whole, or an empty one, fails the check before it is read" {
  # OpenBao reads the metadata and both checksum lists up to 8192 bytes and takes that many for a
  # file cut short. One byte less is read whole: the sealed list is not opened, and JSON may end in
  # spaces.
  members
  head -c 8191 /dev/zero | tr '\0' 's' > "$STAGE/SHA256SUMS.sealed"
  { tr -d '\n' < "$STAGE/meta.json"; printf '%*s' $((8191 - $(stat -c %s "$STAGE/meta.json") + 1)) ''; } > "$STAGE/padded"
  mv "$STAGE/padded" "$STAGE/meta.json"
  [ "$(stat -c %s "$STAGE/meta.json")" -eq 8191 ]
  sums
  snapshot 20261101T004300Z.snapshot.age

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "$(result 20261101T004300Z.snapshot.age '2026-11-15 00:43:07' 4711 3 3)" ]
  [ "$sealed_size" -eq 8191 ]
  day=1

  for member in SHA256SUMS.sealed meta.json SHA256SUMS; do
    members
    head -c 8192 /dev/zero | tr '\0' ' ' > "$STAGE/$member"
    archive > "$PLAIN"
    clear_record
    refused "its $member is of 8192 bytes or more, which OpenBao does not read"
    # Refused from the listing: no member was written out.
    [ -z "$(calls '^tar .*(--extract|--to-stdout)')" ]

    members
    : > "$STAGE/$member"
    archive > "$PLAIN"
    clear_record
    refused "its $member is empty"
    [ -z "$(calls '^tar .*(--extract|--to-stdout)')" ]
  done
  # Far more than the bound, in a size of more digits than the bound has.
  members
  head -c 100000 /dev/zero > "$STAGE/SHA256SUMS"
  archive > "$PLAIN"
  refused "its SHA256SUMS is of 8192 bytes or more, which OpenBao does not read"
}

@test "metadata OpenBao does not write, or would not restore, fails the check, and its servers never do" {
  # No JSON, no object, and two of them.
  members
  printf 'marker-member-0 is no JSON\n' > "$STAGE/meta.json"
  sums
  archive > "$PLAIN"
  refused "its meta.json cannot be read as one JSON object"
  for json in '[1]' '"marker-member-0"' 'null' '{"Version":1}{"Version":1}'; do
    members
    printf '%s\n' "$json" > "$STAGE/meta.json"
    sums
    archive > "$PLAIN"
    refused "its meta.json cannot be read as one JSON object"
  done

  # A version OpenBao's snapshot store does not take: raft knows 0 and 1, and OpenBao restores 1.
  for version in 0 2 '"1"' 1.5 1.0 null; do
    members ".Version = $version"
    archive > "$PLAIN"
    refused "the Version in its meta.json is not 1, the only one OpenBao restores"
  done
  members 'del(.Version)'
  archive > "$PLAIN"
  refused "the Version in its meta.json is not 1, the only one OpenBao restores"

  # An index OpenBao takes no snapshot at, or that is no index: no whole number, or one beyond the
  # largest raft holds.
  for index in 0 -1 1.5 '"4711"' null 18446744073709551616 100000000000000000000; do
    members ".Index = $index"
    grep -qF "\"Index\":$index," "$STAGE/meta.json"
    archive > "$PLAIN"
    refused "the Index in its meta.json is not a whole number above 0"
  done
  for term in -1 0.5 '"3"' null 18446744073709551616; do
    members ".Term = $term"
    grep -qF "\"Term\":$term," "$STAGE/meta.json"
    archive > "$PLAIN"
    refused "the Term in its meta.json is not a whole number"
  done

  # A size that is not the state's: raft refuses a restore whose size differs.
  for size in '.Size + 1' '.Size - 1' '0' '(.Size | tostring)' 'null'; do
    members ".Size = ($size)"
    archive > "$PLAIN"
    refused "the Size in its meta.json is not the length of its state.bin"
  done

  # The servers are counted, whatever they are: a restore uses the store's own configuration.
  count=0
  for configuration in '{Servers: []}' 'null' '"marker-member-0"' '{Servers: "marker-address-0"}' \
    '{Servers: [range(7) | {Suffrage: 0, ID: "marker-member-\(.)", Address: "marker-address-\(.).example.invalid:8201"}]}'; do
    count=$((count + 1))
    members ".Configuration = $configuration"
    snapshot "202612$(printf '%02d' "$count")T004300Z.snapshot.age"
    servers=0
    [[ $configuration != *range* ]] || servers=7

    recipe openbao-snapshot-check

    echo "$configuration"
    [ "$status" -eq 0 ]
    [ "$output" = "$(result "202612$(printf '%02d' "$count")T004300Z.snapshot.age" '2026-11-15 00:43:07' 4711 3 "$servers")" ]
    absent
  done
  # A term of 0 with an index as large as raft's numbers go, and a term as large with an index of 1,
  # are printed as they are.
  members '.Term = 0 | .Index = 18446744073709551615'
  snapshot 20261220T004300Z.snapshot.age

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "$(result 20261220T004300Z.snapshot.age '2026-11-15 00:43:07' 18446744073709551615 0 3)" ]

  members '.Term = 18446744073709551615 | .Index = 1'
  snapshot 20261221T004300Z.snapshot.age

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "$(result 20261221T004300Z.snapshot.age '2026-11-15 00:43:07' 1 18446744073709551615 3)" ]
}

@test "a checksum list that is not one line for each of the two members fails the check as no archive" {
  members

  # A third line: another file's, one of the two again, an empty one, and one without its end,
  # which OpenBao reads as a line as well.
  sums state.bin meta.json SHA256SUMS.sealed
  archive > "$PLAIN"
  refused "its SHA256SUMS is not two lines, a SHA-256 and the name for each of meta.json and state.bin"
  sums state.bin meta.json state.bin
  archive > "$PLAIN"
  refused "its SHA256SUMS is not two lines, a SHA-256 and the name for each of meta.json and state.bin"
  sums
  echo >> "$STAGE/SHA256SUMS"
  archive > "$PLAIN"
  refused "its SHA256SUMS is not two lines, a SHA-256 and the name for each of meta.json and state.bin"
  sums
  printf 'marker-storage-value' >> "$STAGE/SHA256SUMS"
  archive > "$PLAIN"
  refused "its SHA256SUMS is not two lines, a SHA-256 and the name for each of meta.json and state.bin"

  # One line only, the same member twice, and a last line without its end.
  sums state.bin
  archive > "$PLAIN"
  refused "its SHA256SUMS is not two lines, a SHA-256 and the name for each of meta.json and state.bin"
  sums state.bin state.bin
  archive > "$PLAIN"
  refused "its SHA256SUMS is not two lines, a SHA-256 and the name for each of meta.json and state.bin"
  sums
  truncate -s -1 "$STAGE/SHA256SUMS"
  archive > "$PLAIN"
  refused "its SHA256SUMS is not two lines, a SHA-256 and the name for each of meta.json and state.bin"

  # Lines of another form: one space, a shorter checksum, one that is no hexadecimal number, a NUL
  # byte, another name, words before the checksum.
  for form in 's/  / /' 's/^.//' 's/^./g/' 's/  /\x00 /' 's/meta\.json/meta.json.bak/' 's/^/marker-storage-value /'; do
    echo "$form"
    sums
    cp "$STAGE/SHA256SUMS" "$STAGE/unchanged"
    sed -i "$form" "$STAGE/SHA256SUMS"
    run ! cmp -s "$STAGE/SHA256SUMS" "$STAGE/unchanged"
    rm "$STAGE/unchanged"
    archive > "$PLAIN"
    refused "its SHA256SUMS is not two lines, a SHA-256 and the name for each of meta.json and state.bin"
  done
}

@test "the time printed is the metadata member's own, and a time tar does not list to the second fails the check" {
  # Every member with a time of its own, the metadata neither the first nor the last of them: tar
  # keeps a file's own time when it is older than the one it is told to clamp to.
  members
  touch -d '2026-11-14 23:59:58 UTC' "$STAGE/SHA256SUMS.sealed"
  touch -d '2026-11-14 23:59:59 UTC' "$STAGE/SHA256SUMS"
  touch -d '2026-11-15 00:00:00 UTC' "$STAGE/state.bin"
  touch -d '2026-11-15 00:00:01 UTC' "$STAGE/meta.json"
  snapshot 20261101T004300Z.snapshot.age lab-sto2 --mtime='2099-01-01 UTC' --clamp-mtime \
    SHA256SUMS.sealed meta.json SHA256SUMS state.bin
  [ "$(gzip -dc "$PLAIN" | tar --list --verbose --utc --full-time --file - | awk '{print $5}' | sort -u | wc -l)" -eq 4 ]

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "$(result 20261101T004300Z.snapshot.age '2026-11-15 00:00:01' 4711 3 3)" ]

  # A time with a fraction of a second, which a PAX header holds and OpenBao's ustar header cannot:
  # tar lists it longer, and pads the time of every member after it by as much.
  day=1
  touch -d '2026-11-15 00:43:07.250000000 UTC' "$STAGE/meta.json"
  archive --format=pax --mtime='2099-01-01 UTC' --clamp-mtime meta.json state.bin SHA256SUMS SHA256SUMS.sealed > "$PLAIN"
  gzip -dc "$PLAIN" | tar --list --verbose --utc --full-time --file - > "$BATS_TEST_TMPDIR/listing"
  grep -q ' 2026-11-15 00:43:07\.25 meta\.json$' "$BATS_TEST_TMPDIR/listing"
  grep -q ' 2026-11-15 00:00:00    state\.bin$' "$BATS_TEST_TMPDIR/listing"
  refused "it holds a member whose time tar does not list as a date and a time to the second"

  # A time beyond the year 9999, which tar lists with a year of five digits.
  archive --format=gnu --mtime=@999999999999 meta.json state.bin SHA256SUMS SHA256SUMS.sealed > "$PLAIN"
  refused "it holds a member whose time tar does not list as a date and a time to the second"
}

@test "the check reads the listing in the C locale and in UTC, whatever the machine's are" {
  members
  snapshot 20261101T004300Z.snapshot.age
  # A zone five and a half hours ahead of UTC, given as POSIX gives one, so no zone file is needed,
  # in which tar lists another time, and a locale that is not C, one this host has.
  [ "$(TZ=IST-5:30 tar --list --verbose --full-time --gzip --file "$PLAIN" | awk 'NR == 1 { print $4, $5 }')" = '2026-11-15 06:13:07' ]
  [ "$(LC_ALL=C.UTF-8 bash -c 'printf %s "${#1}"' bash "$(printf '\xc4\xb0')" 2> /dev/null)" = 1 ]
  with TZ=IST-5:30 LC_ALL=C.UTF-8 LANG=C.UTF-8 LANGUAGE=de

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "$(result 20261101T004300Z.snapshot.age '2026-11-15 00:43:07' 4711 3 3)" ]
  # Every call of tar was made in the C locale.
  [ "$(calls '^tar ' | wc -l)" -ge 4 ]
  [ "$(sort -u "$RECORD/tar-locale")" = C ]
  [ "$(wc -l < "$RECORD/tar-locale")" -eq "$(calls '^tar ' | wc -l)" ]
}

@test "tar is asked only to list the archive and to write a member to standard output, never to write a file" {
  members
  snapshot 20261101T004300Z.snapshot.age

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  # The listing, and the metadata, the state and the checksum list each written out to be read.
  mapfile -t tars < <(calls '^tar ')
  [ "${#tars[@]}" -ge 4 ]
  for call in "${tars[@]}"; do
    echo "$call"
    only_reads "$call"
  done
  for member in meta.json state.bin SHA256SUMS; do
    [ -n "$(calls "^tar .* $member\$")" ]
  done
  # The sealed checksums are never written out, to standard output either.
  [ -z "$(calls '^tar .*SHA256SUMS\.sealed')" ]
  nothing_left
  # A call that would write a file is told from those.
  run ! only_reads "tar --extract --gzip --file - meta.json"
  run ! only_reads "tar -xzf - meta.json"
  run ! only_reads "tar --extract --to-command=cat --file - meta.json"
  run ! only_reads "tar --create --file - meta.json"
  only_reads "tar -tvzf -"
  only_reads "tar -xOzf - meta.json"
}

@test "a tar header that is no member's fails the check, and so does an archive that does not end in two empty blocks" {
  out_of_place="its members do not follow one another, by their sizes, from its first block"
  no_end="its members are not followed by the two empty blocks that end an archive"
  members

  # PAX headers before each member, which tar lists no line for and OpenBao never writes.
  archive --format=pax meta.json state.bin SHA256SUMS SHA256SUMS.sealed > "$PLAIN"
  [ "$(gzip -dc "$PLAIN" | tar --list --file - | wc -l)" -eq 4 ]
  refused "$out_of_place"
  # A PAX global header and nothing else of PAX's: OpenBao's reader takes it for a member of
  # another name, and tar lists the four members alone.
  archive --format=pax --pax-option='delete=atime,delete=ctime,comment=global' meta.json state.bin SHA256SUMS SHA256SUMS.sealed > "$PLAIN"
  [ "$(gzip -dc "$PLAIN" | tar --list --verbose --file - 2>&1 | wc -l)" -eq 4 ]
  gzip -dc "$PLAIN" > "$BATS_TEST_TMPDIR/global.tar"
  [ "$(dd if="$BATS_TEST_TMPDIR/global.tar" bs=1 skip=156 count=1 2> /dev/null)" = g ]
  [ "$(dd if="$BATS_TEST_TMPDIR/global.tar" bs=1 skip=$((1024 + 156)) count=1 2> /dev/null)" = 0 ]
  refused "$out_of_place"
  # The same header after the last member, before the archive's end.
  archive | gzip -dc > "$BATS_TEST_TMPDIR/plain.tar"
  head -c -1024 "$BATS_TEST_TMPDIR/plain.tar" > "$BATS_TEST_TMPDIR/members.tar"
  { cat "$BATS_TEST_TMPDIR/members.tar"; head -c 1024 "$BATS_TEST_TMPDIR/global.tar"; head -c 1024 /dev/zero; } | gzip -c > "$PLAIN"
  [ "$(gzip -dc "$PLAIN" | tar --list --verbose --file - 2>&1 | wc -l)" -eq 4 ]
  refused "$no_end"
  # An empty block between two members: tar stops there and lists none of the members after it.
  {
    archive meta.json state.bin | gzip -dc | head -c -1024
    head -c 512 /dev/zero
    archive SHA256SUMS SHA256SUMS.sealed | gzip -dc
  } | gzip -c > "$PLAIN"
  [ "$(gzip -dc "$PLAIN" | tar --list --file - 2> /dev/null | wc -l)" -eq 2 ]
  refused "it holds no SHA256SUMS"

  # An end OpenBao's writer does not write, each of which tar lists without an error: nothing after
  # the last member, one empty block, one and then other bytes, one and part of another, and part
  # of one.
  [ "$(tail -c 1024 "$BATS_TEST_TMPDIR/plain.tar" | tr -d '\0' | wc -c)" -eq 0 ]
  [ "$(tail -c 1536 "$BATS_TEST_TMPDIR/plain.tar" | head -c 512 | tr -d '\0' | wc -c)" -gt 0 ]
  for ending in '' 512 '512 marker-storage-value' '512 100' 100; do
    echo "ending: $ending"
    read -r zeros more <<< "$ending"
    {
      cat "$BATS_TEST_TMPDIR/members.tar"
      head -c "${zeros:-0}" /dev/zero
      case $more in
        '') ;;
        *[!0-9]*) printf '%-512s' "$more" ;;
        *) head -c "$more" /dev/zero ;;
      esac
    } | gzip -c > "$PLAIN"
    gzip -dc "$PLAIN" | tar --list --file - > /dev/null 2>&1
    refused "$no_end"
  done

  # The two empty blocks OpenBao's writer ends an archive with, with nothing after them, with the
  # blocks tar pads an archive to a whole record with, and with other bytes: its reader stops at
  # the two blocks, whatever follows them.
  snapshot 20261201T004300Z.snapshot.age
  [ "$(gzip -dc "$PLAIN" | cmp - "$BATS_TEST_TMPDIR/plain.tar" && echo same)" = same ]

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "$(result 20261201T004300Z.snapshot.age '2026-11-15 00:43:07' 4711 3 3)" ]

  snapshot 20261202T004300Z.snapshot.age lab-sto2 --blocking-factor=20 meta.json state.bin SHA256SUMS SHA256SUMS.sealed
  [ $(($(gzip -dc "$PLAIN" | wc -c) % 10240)) -eq 0 ]
  [ "$(gzip -dc "$PLAIN" | wc -c)" -gt "$(stat -c %s "$BATS_TEST_TMPDIR/plain.tar")" ]

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "$(result 20261202T004300Z.snapshot.age '2026-11-15 00:43:07' 4711 3 3)" ]

  { cat "$BATS_TEST_TMPDIR/plain.tar"; printf '%-700s' 'bytes after the end of the archive'; } | gzip -c > "$PLAIN"
  encrypt < "$PLAIN" | put 20261203T004300Z.snapshot.age
  plain_size=$(stat -c %s "$PLAIN")
  encrypted_size=$(stat -c %s "$STORE/$BUCKET/lab-sto2/20261203T004300Z.snapshot.age")

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "$(result 20261203T004300Z.snapshot.age '2026-11-15 00:43:07' 4711 3 3)" ]
}

@test "what tar says of an archive is not shown" {
  # A PAX header keyword that tar does not know, named by a marker: tar names it in a warning, for
  # each member it lists.
  members
  archive --format=pax --pax-option='marker-member-0:=marker-storage-value' \
    meta.json state.bin SHA256SUMS SHA256SUMS.sealed > "$PLAIN"
  run tar --list --gzip --file "$PLAIN"
  [[ $output == *"Ignoring unknown extended header keyword 'marker-member-0'"* ]]

  refused "its members do not follow one another, by their sizes, from its first block"

  # A member under a name of its own, which tar is never asked for and which it lists to the check
  # alone.
  printf 'marker-storage-value\n' > "$STAGE/marker-member-0.txt"
  archive meta.json state.bin SHA256SUMS SHA256SUMS.sealed marker-member-0.txt > "$PLAIN"
  refused "it holds a member that is none of meta.json, state.bin, SHA256SUMS and SHA256SUMS.sealed"

  # A tar that writes a line of the archive to standard error on every call, listing or writing a
  # member out, as a tar of another release may of an archive this one reads in silence: none of it
  # is shown, and the archive passes.
  {
    echo '#!/usr/bin/env bash'
    printf '%s\n' "echo 'tar: marker-storage-value: a word of its own' >&2"
    printf '%s\n' "exec \"$(command -v tar)\" \"\$@\""
  } > "$BIN/tar"
  snapshot 20261201T004300Z.snapshot.age

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "$(result 20261201T004300Z.snapshot.age '2026-11-15 00:43:07' 4711 3 3)" ]
  absent
  nothing_left
}

@test "tar and gzip are given no option from the environment the check is run in" {
  members
  snapshot 20261101T004300Z.snapshot.age
  # Zero bytes after the gzip stream, which gzip ignores unless it is told to say more.
  head -c 512 /dev/zero >> "$PLAIN"
  gzip --test < "$PLAIN"
  encrypt < "$PLAIN" | put 20261101T004300Z.snapshot.age
  plain_size=$(stat -c %s "$PLAIN")
  encrypted_size=$(stat -c %s "$STORE/$BUCKET/lab-sto2/20261101T004300Z.snapshot.age")
  # An option that has tar leave the metadata out of what it lists, and one that has a gzip which
  # still reads its variable warn of those bytes, failing its test.
  [ "$(TAR_OPTIONS=--exclude=meta.json tar --list --gzip --file "$PLAIN" | wc -l)" -eq 3 ]
  with TAR_OPTIONS=--exclude=meta.json GZIP=--verbose

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "$(result 20261101T004300Z.snapshot.age '2026-11-15 00:43:07' 4711 3 3)" ]
  # No call of tar or gzip was given either variable, the gzip that tar runs included.
  [ "$(sort -u "$RECORD/options")" = $'gzip:\ntar:' ]
  [ "$(grep -c '^tar:' "$RECORD/options")" -eq "$(calls '^tar ' | wc -l)" ]
  [ "$(grep -c '^gzip:' "$RECORD/options")" -eq "$(calls '^gzip ' | wc -l)" ]
  [ "$(calls '^gzip ' | wc -l)" -gt "$(calls '^gzip (-t|--test)( |$)' | wc -l)" ]
}

@test "the release whose source the snapshot check follows is the one the snapshot job runs" {
  # The check reads the archive as the pinned OpenBao's source writes and reads it, and records the
  # release it read. The snapshots are taken by the job's client, the servers' own version.
  recorded=$(sed -n 's/^# openbao-snapshot-archive: \(v[0-9][0-9.]*\)$/\1/p' "$ROOT/scripts/openbao-snapshot-check")
  image=$(yq '.spec.jobTemplate.spec.template.spec.initContainers[] | select(.name == "snapshot") | .image' \
    "$ROOT/kubernetes/apps/base/openbao/openbao-snapshots/app/cronjob.yaml")
  [[ $image =~ ^quay\.io/openbao/openbao:([0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$ ]]
  echo "the check follows ${recorded:-(no record)}; the job runs v${BASH_REMATCH[1]}"
  [ "$recorded" = "v${BASH_REMATCH[1]}" ]
  # The list of what is moved by hand says how the record moves.
  grep -q $'^scripts/openbao-snapshot-check\topenbao-snapshot-archive\t' "$ROOT/.renovate/by-hand.tsv"
}

@test "a snapshot the job's own scripts encrypted and uploaded is listed and checked by the recipes" {
  # The job's scripts, as the application ships them, encrypt an archive and upload it with the
  # recording fake of the job's tests to the bucket of this test's prefix; the recipes then read the
  # same store.
  job_build BACKUP_BUCKET_PREFIX=marker-prefix
  JOB_SCRIPTS="$BATS_TEST_TMPDIR/job-scripts"
  job_scripts "$JOB_SCRIPTS"
  mkdir -p "$BATS_TEST_TMPDIR/job-plain" "$BATS_TEST_TMPDIR/job-out"
  members
  archive > "$BATS_TEST_TMPDIR/job-plain/raft.snap"
  cp "$BATS_TEST_TMPDIR/job-plain/raft.snap" "$PLAIN"
  cp "$BIN/rclone" "$BATS_TEST_TMPDIR/recipes-rclone"
  cp "$BATS_TEST_DIRNAME/fixtures/etcd-snapshots/rclone" "$BIN/rclone"
  job_run encrypt encrypt.sh PLAIN_SNAPSHOT="$BATS_TEST_TMPDIR/job-plain/raft.snap" OUT_DIR="$BATS_TEST_TMPDIR/job-out" \
    AGE="$(command -v age)" AGE_RECIPIENT="$RECIPIENT"
  [ "$status" -eq 0 ]
  job_run upload upload.sh OUT_DIR="$BATS_TEST_TMPDIR/job-out"
  [ "$status" -eq 0 ]
  cp "$BATS_TEST_TMPDIR/recipes-rclone" "$BIN/rclone"
  job_name=$(find "$BATS_TEST_TMPDIR/job-out" -type f -printf '%f\n')
  [ -f "$STORE/$BUCKET/lab-sto2/$job_name" ]
  # An earlier one is there too; the job's is the newest.
  snapshot 20200101T004300Z.snapshot.age
  plain_size=$(stat -c %s "$PLAIN")
  encrypted_size=$(stat -c %s "$STORE/$BUCKET/lab-sto2/$job_name")
  clear_record

  recipe openbao-snapshots

  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$job_name $encrypted_size" ]
  [[ ${lines[1]} == "20200101T004300Z.snapshot.age "* ]]

  recipe openbao-snapshot-check

  [ "$status" -eq 0 ]
  [ "$output" = "$(result "$job_name" '2026-11-15 00:43:07' 4711 3 3)" ]
  nothing_left
}
