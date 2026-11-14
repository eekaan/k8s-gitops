#!/usr/bin/env bats
# Proves features/etcd-snapshots.feature; each test carries its scenario's title.
# The recipes run from a copy of the repository with an environment of their own, so no run reads
# this checkout's .env. Encrypting and decrypting are local and offline, so they run the pinned age,
# recorded on its way, with throwaway keys inside the test's temporary directory. Everything that
# would reach a node, a cluster or the object storage is a recording fake: talman, kubectl, rclone
# (tests/fixtures/etcd-snapshots/rclone, whose buckets are directories), timeout, which carries the
# probe of the Talos API port, and the steps before Flux that a restore must not run again. openstack
# and helm are fakes that fail, so a run that starts either shows in the record.

setup_file() {
  # The Talos check's fixture cluster: talos/talman.yaml.tftpl rendered from tests/fixtures/talos,
  # as talos/<cluster>/talman.yaml is rendered from the cluster stack.
  local encoded
  encoded=$(tofu -chdir="$BATS_TEST_DIRNAME/fixtures/talos" console -no-color <<< 'base64encode(local.talman_yaml)')
  base64 -d <<< "${encoded//\"/}" > "$BATS_FILE_TMPDIR/talman.yaml"
}

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  JUST=$(command -v just)
  YQ=$(command -v yq)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  STORE="$BATS_TEST_TMPDIR/store"
  FAILS="$BATS_TEST_TMPDIR/store-fails"
  # The recipes' TMPDIR, where their private directories are made and must be gone afterwards.
  WORK="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$BIN" "$RECORD" "$STATE" "$STORE" "$FAILS" "$WORK" "$BATS_TEST_TMPDIR/keys" \
    "$BATS_TEST_TMPDIR/repo/talos/lab-sto2" "$BATS_TEST_TMPDIR/repo/infra/openstack"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  CLUSTER="$REPO/talos/lab-sto2"
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp "$ROOT/talos/.sops.yaml" "$REPO/talos/.sops.yaml"
  # The repository's own SOPS rules name its real recipients; a test starts before any key exists.
  yq -i '.creation_rules[].age = "example-talos-age-recipient"' "$REPO/talos/.sops.yaml"
  cp "$BATS_FILE_TMPDIR/talman.yaml" "$CLUSTER/talman.yaml"
  printf 'cluster:\n  secret: marker-bundle-secret\n' > "$CLUSTER/secrets.sops.yaml"
  # The backend file, the endpoint's only source, with a marker for the endpoint.
  ENDPOINT=https://marker-endpoint.example.invalid
  sed -E "s#https://[^\"]+#$ENDPOINT#" "$ROOT/infra/openstack/backend.hcl" > "$REPO/infra/openstack/backend.hcl"
  grep -qF "$ENDPOINT" "$REPO/infra/openstack/backend.hcl"
  # The Talos age key, a throwaway one, with its recipient in talos/.sops.yaml.
  KEY="$BATS_TEST_TMPDIR/keys/talos.agekey"
  age-keygen -o "$KEY" 2> /dev/null
  SECRET=$(grep '^AGE-SECRET-KEY-' "$KEY")
  RECIPIENT=$(age-keygen -y "$KEY")
  RECIPIENT=$RECIPIENT yq -i '.creation_rules[].age = strenv(RECIPIENT)' "$REPO/talos/.sops.yaml"
  # What talman's snapshot holds: a marker, never to be seen in the clear outside the fake etcd.
  printf 'marker-snapshot-content %s\n\001\002binary tail\n' "$RANDOM$RANDOM" > "$STATE/content"
  BUCKET='marker-prefix-etcd'
  mkdir -p "$STORE/$BUCKET"
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise < /dev/null
  cp "$BATS_TEST_DIRNAME/fixtures/etcd-snapshots/rclone" "$BIN/rclone"
  fake_cluster
  record age jq yq mktemp
  BASE_ENVIRONMENT=(
    SOPS_AGE_KEY_FILE="$KEY"
    KUBE_API_ADDRESS=203.0.113.80
    BACKUP_BUCKET_PREFIX=marker-prefix
    AWS_ACCESS_KEY_ID=marker-state-access-key-id
    AWS_SECRET_ACCESS_KEY=marker-state-secret-key
    TMPDIR="$WORK"
  )
  reset_environment
}

# fake NAME: a binary first on the recipe's PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# fake_tool NAME: like fake, with RECORD, STATE and the real yq set in the fake for its body to use.
fake_tool() {
  { printf 'RECORD=%q STATE=%q YQ=%q\n' "$RECORD" "$STATE" "$YQ"; cat; } | fake "$1"
}

# record NAME...: puts each NAME's arguments in the record, then runs the real NAME.
record() {
  local tool real
  for tool; do
    real=$(command -v "$tool")
    fake "$tool" <<EOF
printf '%s\n' "$tool \$*" >> "$RECORD/argv"
exec "$real" "\$@"
EOF
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

# fake_cluster: talman, kubectl, timeout and sleep as a cluster of six nodes that answer on the Talos
# API port, and recording fakes of the steps cluster-bootstrap runs before Flux. What a fake does is
# set by files in STATE:
#   content         what talman's etcd snapshot holds
#   snapshot-fails  talman fails once it has started writing the snapshot
#   interrupt       the run is interrupted, as by Ctrl-C, while talman writes the snapshot or
#                   bootstraps; talman dies of it when the file says dies, and when it says handles,
#                   handles it itself, finishes and exits 0
#   reset-fails     talman reset fails
# talman reset records in reset-nodes the hostnames it resets, selected as talman selects them: those
# -n/--node names by hostname or address and those -g/--group names by role or group, or, with
# neither, every node.
#   apply-fails     talman apply --bootstrap fails
#   stale           hostnames whose kubelet has not reported since the reset: their Ready condition
#                   is the one etcd held, from before
# talman records what it bootstraps from: the file's path in recovered-from and, as it was at that
# moment, its content in recovered. Like talman, the fake names the nodes it reaches by address.
fake_cluster() {
  fake_tool talman <<'EOF'
printf '%s\n' "talman $*" >> "$RECORD/argv"
addresses=$("$YQ" '.nodes[].ipAddress' "$TALMAN_CONFIG/talman.yaml" | paste -sd, -)
echo "== reaching the nodes at $addresses"
args=("$@")
given() {
  [[ " ${args[*]} " == *" $1 "* ]]
}
interrupt() {
  # Ctrl-C reaches the recipe and talman alike.
  case $(cat "$STATE/interrupt" 2> /dev/null) in
    dies)
      kill -INT "$PPID"
      kill -INT "$$"
      exit 130
      ;;
    handles) kill -INT "$PPID" ;;
  esac
}
case "$1" in
  etcd)
    path=${3-}
    printf 'path %s\nmode %s\n' "$path" "$(stat -c %a "$(dirname "$path")")" > "$RECORD/snapshot"
    if [[ -z $path || -e $path ]]; then
      echo "error: refusing to write over $path" >&2
      exit 1
    fi
    (umask 077 && head -c 20 "$STATE/content" > "$path")
    if [[ -e $STATE/snapshot-fails ]]; then
      echo "error: etcd on cp-1 ($addresses) closed the stream" >&2
      exit 1
    fi
    interrupt
    cat "$STATE/content" > "$path"
    echo "== snapshotting etcd on cp-1 ($addresses)"
    echo "wrote $path"
    ;;
  reset)
    if [[ -e $STATE/reset-fails ]]; then
      echo "error: talosctl reset exited with status 1 at $addresses" >&2
      exit 1
    fi
    selected=() selecting=0
    for ((i = 0; i < ${#args[@]}; i++)); do
      case ${args[i]} in
        -g | --group | -n | --node) by=${args[i]} values=${args[i + 1]-} && i=$((i + 1)) ;;
        --group=* | --node=*) by=${args[i]%%=*} values=${args[i]#*=} ;;
        *) continue ;;
      esac
      selecting=1
      IFS=, read -ra values <<< "$values"
      for value in "${values[@]}"; do
        if [[ $by == -g || $by == --group ]]; then
          query='.nodes[] | select(.role == strenv(VALUE) or ((.groups // []) | contains([strenv(VALUE)]))) | .hostname'
        else
          query='.nodes[] | select(.hostname == strenv(VALUE) or .ipAddress == strenv(VALUE)) | .hostname'
        fi
        mapfile -t -O "${#selected[@]}" selected < <(VALUE=$value "$YQ" "$query" "$TALMAN_CONFIG/talman.yaml")
      done
    done
    if ((!selecting)); then
      mapfile -t selected < <("$YQ" '.nodes[].hostname' "$TALMAN_CONFIG/talman.yaml")
    fi
    printf '%s\n' "${selected[@]}" | sort -u > "$STATE/reset-nodes"
    echo "== resetting $(paste -sd, "$STATE/reset-nodes") at $addresses"
    ;;
  apply)
    if ! given --bootstrap; then
      echo "unexpected call: talman $*" >&2
      exit 1
    fi
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ ${args[i]} == --recover-from ]]; then
        printf '%s\n' "${args[i + 1]-}" > "$STATE/recovered-from"
        cp "${args[i + 1]-}" "$STATE/recovered" 2> /dev/null || true
      fi
    done
    interrupt
    if [[ -e $STATE/apply-fails ]]; then
      echo "error: bootstrapping etcd on cp-1 at $addresses failed" >&2
      exit 1
    fi
    echo "== bootstrapping etcd on cp-1 ($addresses) from the snapshot"
    ;;
  kubeconfig)
    mkdir -p "$TALMAN_CONFIG/clusterconfig"
    cat > "$TALMAN_CONFIG/clusterconfig/kubeconfig" <<'KUBECONFIG'
apiVersion: v1
kind: Config
clusters:
  - name: example
    cluster:
      server: https://192.0.2.10:6443
      certificate-authority-data: marker-certificate-authority-data
users:
  - name: admin@example
    user:
      client-key-data: marker-client-key-data
contexts:
  - name: admin@example
    context:
      cluster: example
      user: admin@example
current-context: admin@example
KUBECONFIG
    echo "wrote clusterconfig/kubeconfig"
    ;;
  *)
    echo "unexpected call: talman $*" >&2
    exit 1
    ;;
esac
EOF
  fake_tool kubectl <<'EOF'
printf '%s\n' "kubectl $*" >> "$RECORD/argv"
if [[ "${1-} ${2-}" != "get nodes" ]]; then
  echo "unexpected call: kubectl $*" >&2
  exit 1
fi
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
items=()
for node in $("$YQ" '.nodes[].hostname' "$TALMAN_CONFIG/talman.yaml"); do
  beat=$now
  if grep -qx "$node" "$STATE/stale" 2> /dev/null; then
    beat=2026-01-01T00:00:00Z
  fi
  items+=("{\"metadata\": {\"name\": \"$node\"}, \"status\": {\"conditions\": [
    {\"type\": \"MemoryPressure\", \"status\": \"False\", \"lastHeartbeatTime\": \"$now\"},
    {\"type\": \"Ready\", \"status\": \"True\", \"lastHeartbeatTime\": \"$beat\"}]}}")
done
printf '{"apiVersion": "v1", "kind": "List", "items": [%s]}\n' "$(IFS=,; echo "${items[*]}")"
EOF
  # The nodes answer a connection to the Talos API port only.
  fake_tool timeout <<'EOF'
printf '%s\n' "timeout $*" >> "$RECORD/argv"
[[ $* == *"/dev/tcp/"*50000* ]]
EOF
  fake sleep < /dev/null
  for tool in openstack helm; do
    fake_tool "$tool" <<EOF
printf '%s\n' "$tool \$*" >> "\$RECORD/argv"
echo "unexpected call: $tool \$*" >&2
exit 1
EOF
  done
  for step in install-cilium cluster-config install-app; do
    fake_tool "$step" <<EOF
printf '%s\n' "$step \$*" >> "\$RECORD/argv"
EOF
    mv "$BIN/$step" "$REPO/scripts/$step"
  done
}

# put_snapshot NAME [CONTENT_FILE]: a snapshot of lab-sto2 in the etcd bucket, encrypted to the Talos
# age key, holding CONTENT_FILE (what talman's snapshot holds by default).
put_snapshot() {
  mkdir -p "$STORE/$BUCKET/lab-sto2"
  age -r "$RECIPIENT" -o "$STORE/$BUCKET/lab-sto2/$1" "${2:-$STATE/content}"
}

# next_second: waits until the UTC second changes, so that the next snapshot takes a name of its own;
# one taken in the same second as another is refused.
next_second() {
  local now
  now=$(date -u +%s)
  while [[ $(date -u +%s) == "$now" ]]; do
    sleep 0.1
  done
}

# calls PATTERN: the recorded calls matching the extended regex, one per line.
calls() {
  grep -E -- "$1" "$RECORD/argv" 2> /dev/null || true
}

# call_line PATTERN: the line number in the record of the first call matching the extended regex.
call_line() {
  grep -n -m1 -E -- "$1" "$RECORD/argv" | cut -d: -f1
}

# last_call_line PATTERN: the line number in the record of the last call matching the extended regex.
last_call_line() {
  grep -n -E -- "$1" "$RECORD/argv" | tail -1 | cut -d: -f1
}

# absent TEXT FILE...: fails when any FILE holds TEXT.
absent() {
  local text=$1
  shift
  if grep -qaF -- "$text" "$@" 2> /dev/null; then
    echo "found $text in $*" >&2
    return 1
  fi
}

# clear_record: forgets every recorded call, so the next run's calls are numbered from one.
clear_record() {
  rm -rf "$RECORD"
  mkdir -p "$RECORD"
}

# nothing_left: the recipes' TMPDIR holds nothing, and the directory talman wrote into is gone.
nothing_left() {
  local left dir
  left=$(find "$WORK" -mindepth 1)
  if [[ -n $left ]]; then
    echo "left on disk: $left" >&2
    return 1
  fi
  if [[ -f $RECORD/snapshot ]]; then
    dir=$(dirname "$(sed -n 's/^path //p' "$RECORD/snapshot")")
    [ ! -e "$dir" ]
  fi
  if [[ -f $STATE/recovered-from ]]; then
    [ ! -e "$(cat "$STATE/recovered-from")" ]
  fi
}

# uploads: the recorded uploads, one file per upload.
uploads() {
  find "$RECORD" -maxdepth 1 -name 'upload.*' | sort
}

# resets_or_bootstraps: the recorded talman calls that change a node.
resets_or_bootstraps() {
  calls '^talman (reset|apply)( |$)'
}

@test "A snapshot is uploaded encrypted and nothing is left on disk" {
  before=$(date -u +%Y%m%dT%H%M%SZ)

  recipe cluster-snapshot

  after=$(date -u +%Y%m%dT%H%M%SZ)
  [ "$status" -eq 0 ]
  mapfile -t objects < <(find "$STORE/$BUCKET" -type f -printf '%P\n')
  [ "${#objects[@]}" -eq 1 ]
  [[ ${objects[0]} =~ ^lab-sto2/[0-9]{8}T[0-9]{6}Z\.snapshot\.age$ ]]
  name=${objects[0]#lab-sto2/}
  taken=${name%.snapshot.age}
  [[ ! $taken < $before && ! $taken > $after ]]
  object="$STORE/$BUCKET/${objects[0]}"
  [ "$(head -n 1 "$object")" = age-encryption.org/v1 ]
  age -d -i "$KEY" "$object" | cmp - "$STATE/content"
  [ "$output" = "cluster-snapshot: lab-sto2: $name, $(stat -c %s "$object") bytes" ]
  # talman wrote the snapshot into a private directory under TMPDIR, outside the repository.
  [ "$(sed -n 's/^mode //p' "$RECORD/snapshot")" = 700 ]
  [[ $(sed -n 's/^path //p' "$RECORD/snapshot") == "$WORK"/* ]]
  [ "$(calls '^talman ' | wc -l)" -eq 1 ]
  [ -n "$(calls '^talman etcd snapshot ')" ]
  nothing_left
  # Uploaded with the state key, through the S3 client, and listed back.
  [ "$(calls '^rclone copyto ' | wc -l)" -eq 1 ]
  [[ $(calls '^rclone copyto ') == *" store:$BUCKET/lab-sto2/$name" ]]
  # Listed before the upload, for an object of the same name, and after it, for the new one.
  [ "$(calls '^rclone lsjson ' | wc -l)" -eq 2 ]
  [ "$(call_line '^rclone lsjson ')" -lt "$(call_line '^rclone copyto ')" ]
  [ "$(call_line '^rclone copyto ')" -lt "$(last_call_line '^rclone lsjson ')" ]
  for file in "$RECORD"/env.rclone.*; do
    grep -qz '^RCLONE_CONFIG_STORE_ACCESS_KEY_ID=marker-state-access-key-id$' "$file"
  done
  [ -z "$(calls '^(openstack|helm|kubectl) ')" ]
}

@test "The upload is only ever handed the encrypted file" {
  recipe cluster-snapshot

  [ "$status" -eq 0 ]

  : > "$FAILS/upload"
  next_second

  recipe cluster-snapshot

  [ "$status" -ne 0 ]

  rm "$FAILS/upload"
  with CI=true
  next_second

  recipe cluster-snapshot

  [ "$status" -eq 0 ]
  mapfile -t handed < <(uploads)
  [ "${#handed[@]}" -eq 3 ]
  [ "$(calls '^rclone copyto ' | wc -l)" -eq 3 ]
  for upload in "${handed[@]}"; do
    source=$(sed -n 's/^source //p' "$upload")
    [[ $source == "$WORK"/*/*.snapshot.age ]]
    [ "$(sed -n 's/^header //p' "$upload")" = age-encryption.org/v1 ]
    [ "$(sed -n 's/^siblings //p' "$upload")" = "${source##*/} " ]
  done
  nothing_left
}

@test "A failed upload fails the recipe and leaves no snapshot on disk" {
  : > "$FAILS/upload"

  recipe cluster-snapshot

  [ "$status" -ne 0 ]
  [[ $output == *"cluster-snapshot: failed while uploading the encrypted snapshot to the etcd bucket"* ]]
  for shown in AccessDenied marker-endpoint marker-prefix; do
    [[ $output != *"$shown"* ]]
  done
  [ -n "$(calls '^rclone copyto ')" ]
  [ -z "$(find "$STORE" -type f)" ]
  nothing_left
}

@test "A failed or interrupted snapshot leaves nothing on disk" {
  : > "$STATE/snapshot-fails"

  recipe cluster-snapshot

  [ "$status" -ne 0 ]
  [[ $output == *"cluster-snapshot: failed while taking the etcd snapshot"* ]]
  [ -f "$RECORD/snapshot" ]
  [ -z "$(calls '^rclone ')" ]
  nothing_left

  rm "$STATE/snapshot-fails"
  for talman in dies handles; do
    echo "$talman" > "$STATE/interrupt"
    clear_record

    recipe cluster-snapshot

    [ "$status" -ne 0 ]
    [ -f "$RECORD/snapshot" ]
    [ -z "$(calls '^(rclone|age) ')" ]
    [ -z "$(find "$STORE" -type f)" ]
    nothing_left
  done
}

@test "The upload cannot create a bucket" {
  rm -r "${STORE:?}/$BUCKET"

  recipe cluster-snapshot

  [ "$status" -ne 0 ]
  [[ $output == *"the etcd bucket must exist; just infra-backup-buckets creates it"* ]]
  [ "$(calls '^rclone copyto ' | wc -l)" -eq 1 ]
  [[ " $(calls '^rclone copyto ') " == *" --s3-no-check-bucket "* ]]
  [ -z "$(find "$STORE" -mindepth 1)" ]
  nothing_left
  # Only the upload carries it: the store's own settings leave it off.
  for file in "$RECORD"/env.rclone.*; do
    absent NO_CHECK_BUCKET "$file"
  done
}

@test "Nothing but the object's name and size reaches the output" {
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
  for ci in '' true; do
    reset_environment
    [[ -z $ci ]] || with CI=true
    rm -rf "${STORE:?}"/* "${FAILS:?}"/*
    mkdir -p "$STORE/$BUCKET"
    run_and_keep ok cluster-snapshot
    run_and_keep ok cluster-snapshots
    run_and_keep ok cluster-restore latest --yes < /dev/null
    run_and_keep failed cluster-restore latest <<< no
    run_and_keep failed cluster-restore 20200101T000000Z.snapshot.age --yes < /dev/null
    : > "$FAILS/upload"
    next_second
    run_and_keep failed cluster-snapshot
    : > "$FAILS/download"
    run_and_keep failed cluster-restore latest --yes < /dev/null
    : > "$FAILS/list"
    run_and_keep failed cluster-snapshots
    run_and_keep failed cluster-restore latest --yes < /dev/null
    rm "$FAILS"/*
    : > "$STATE/apply-fails"
    run_and_keep failed cluster-restore latest --yes < /dev/null
    rm "$STATE/apply-fails"
    rm -r "${STORE:?}/$BUCKET"
    run_and_keep failed cluster-snapshot
    run_and_keep failed cluster-snapshots
  done

  # The record holds the calls the markers could reach.
  [ -n "$(calls '^rclone copyto ')" ]
  [ -n "$(calls '^talman apply ')" ]
  [ -n "$(calls '^age ')" ]
  [[ ${printed[*]} == *"cluster-snapshot: lab-sto2: "* ]]
  content=$(head -n 1 "$STATE/content")
  for marker in "$SECRET" marker-state-access-key-id marker-state-secret-key marker-endpoint "$content" \
    marker-bundle-secret marker-client-key-data; do
    absent "$marker" "$RECORD/argv"
    [[ ${printed[*]} != *"$marker"* ]]
  done
  # The bucket's name reaches the S3 client's command line, and no other.
  [[ ${printed[*]} != *marker-prefix* ]]
  [ "$(grep '^rclone ' "$RECORD/argv" | grep -cF marker-prefix)" -gt 0 ]
  [ "$(grep -v '^rclone ' "$RECORD/argv" | grep -cF marker-prefix)" -eq 0 ]
  # With CI set, as in a public CI log, not even the node addresses talman names show.
  ci_printed=("${printed[@]:${#printed[@]}/2}")
  [[ ${ci_printed[*]} == *"its output is in talos/lab-sto2/clusterconfig/"* ]]
  for address in $(yq '.nodes[].ipAddress' "$CLUSTER/talman.yaml"); do
    [[ ${ci_printed[*]} != *"$address"* ]]
  done
  nothing_left
}

@test "Snapshots are listed newest first for one cluster only" {
  # Each object holds as many bytes as its name has characters. The S3 client lists a prefix's
  # objects oldest name first, as S3 lists keys.
  for object in lab-sto2/20261102T000000Z.snapshot.age lab-sto2/20261103T120000Z.snapshot.age \
    lab-sto2/2026110T000000Z.snapshot.age lab-sto2/notes.txt lab-sto2/old/20261104T000000Z.snapshot.age \
    lab-sto2-old/20261105T000000Z.snapshot.age other/20261106T000000Z.snapshot.age \
    20261107T000000Z.snapshot.age; do
    mkdir -p "$(dirname "$STORE/$BUCKET/$object")"
    printf '%s' "${object//?/x}" > "$STORE/$BUCKET/$object"
  done
  printf 'x' > "$STORE/$BUCKET/lab-sto2/20261101T000000Z.snapshot.age"

  recipe cluster-snapshots

  [ "$status" -eq 0 ]
  [ "$output" = $'20261103T120000Z.snapshot.age 38\n20261102T000000Z.snapshot.age 38\n20261101T000000Z.snapshot.age 1' ]
  [ "$(calls '^rclone ' | wc -l)" -eq 1 ]
  [[ $(calls '^rclone ') == *" store:$BUCKET/lab-sto2/" ]]

  recipe cluster-snapshots lab-sto2-old

  [ "$status" -eq 0 ]
  [ "$output" = '20261105T000000Z.snapshot.age 42' ]

  recipe cluster-snapshots lab-sto2-new

  [ "$status" -eq 0 ]
  [ "$output" = "cluster-snapshots: the etcd bucket holds no snapshot of lab-sto2-new" ]
  [ -z "$(calls '^(talman|kubectl|age) ')" ]
}

@test "A restore asks first, and nothing is reset without the cluster's name" {
  put_snapshot 20261101T000000Z.snapshot.age

  recipe cluster-restore 20261101T000000Z.snapshot.age <<< no

  [ "$status" -ne 0 ]
  [[ $output == *"the control planes of lab-sto2 are reset, and the cluster's state is replaced by the one in 20261101T000000Z.snapshot.age: everything written to the cluster after the snapshot was taken is lost"* ]]
  [[ $output == *"the workers are not reset"* ]]
  [[ $output == *"Type lab-sto2 to reset and restore it: "* ]]
  [[ $output == *"lab-sto2 was not confirmed and is not restored"* ]]
  [ -z "$(resets_or_bootstraps)" ]
  [ -z "$(calls '^kubectl ')" ]
  nothing_left

  clear_record

  recipe cluster-restore 20261101T000000Z.snapshot.age lab-sto2 <<< lab-sto2

  [ "$status" -eq 0 ]
  [[ $output == *"Type lab-sto2 to reset and restore it: "* ]]
  [ "$(calls '^talman reset ' | wc -l)" -eq 1 ]
  [ "$(calls '^talman apply ' | wc -l)" -eq 1 ]

  clear_record

  recipe cluster-restore 20261101T000000Z.snapshot.age --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"the control planes of lab-sto2 are reset"* ]]
  [[ $output != *"Type lab-sto2"* ]]
  [ "$(calls '^talman reset ' | wc -l)" -eq 1 ]
  [ "$(calls '^talman apply ' | wc -l)" -eq 1 ]
}

@test "A restore resets the nodes and recovers from the decrypted snapshot" {
  printf 'marker-older-content\n' > "$STATE/older"
  put_snapshot 20261101T000000Z.snapshot.age
  put_snapshot 20261030T000000Z.snapshot.age "$STATE/older"

  recipe cluster-restore 20261101T000000Z.snapshot.age <<< lab-sto2

  [ "$status" -eq 0 ]
  cmp "$STATE/recovered" "$STATE/content"
  [[ $(cat "$STATE/recovered-from") == "$WORK"/* ]]
  reset=$(calls '^talman reset( |$)')
  [ "$(wc -l <<< "$reset")" -eq 1 ]
  for flag in --wipe-labels=EPHEMERAL --graceful=false --yes; do
    [[ " $reset " == *" $flag "* ]]
  done
  [[ " $reset " != *" --wipe-disk "* ]]
  # Every control plane, and no worker.
  [ "$(paste -sd' ' "$STATE/reset-nodes")" = "cp-1 cp-2 cp-3" ]
  apply=$(calls '^talman apply( |$)')
  [ "$(wc -l <<< "$apply")" -eq 1 ]
  [[ " $apply " == *" --bootstrap "* ]]
  [[ " $apply " == *" --recover-from $(cat "$STATE/recovered-from") "* ]]
  [[ " $apply " != *" --onboard-new-nodes "* && " $apply " != *" --recover-skip-hash-check "* ]]
  # In order: the nodes answer, the control planes are reset, the nodes answer again, etcd is
  # bootstrapped from the snapshot, the kubeconfig is fetched and the nodes are asked whether they
  # are Ready.
  downloaded=$(call_line '^rclone copyto store:')
  decrypted=$(call_line '^age (-d|--decrypt) ')
  probed=$(call_line '^timeout .*/dev/tcp/')
  reset_at=$(call_line '^talman reset ')
  probed_again=$(last_call_line '^timeout .*/dev/tcp/')
  applied=$(call_line '^talman apply ')
  fetched=$(call_line '^talman kubeconfig')
  ready=$(call_line '^kubectl get nodes ')
  for call in "$downloaded" "$decrypted" "$probed" "$reset_at" "$probed_again" "$applied" "$fetched" "$ready"; do
    [ -n "$call" ]
  done
  [ "$downloaded" -lt "$decrypted" ]
  [ "$decrypted" -lt "$reset_at" ]
  [ "$probed" -lt "$reset_at" ]
  [ "$reset_at" -lt "$probed_again" ]
  [ "$probed_again" -lt "$applied" ]
  [ "$applied" -lt "$fetched" ]
  [ "$fetched" -lt "$ready" ]
  [ "$(yq '.clusters[0].cluster.server' "$CLUSTER/clusterconfig/kubeconfig")" = "https://203.0.113.80:6443" ]
  # A recovered etcd holds what was applied before Flux started; none of it is applied again.
  [ -z "$(calls '^(install-cilium|cluster-config|install-app|helm|kubectl apply)( |$)')" ]
  [[ ${lines[-1]} == "cluster-restore: lab-sto2 is restored from 20261101T000000Z.snapshot.age; every node is Ready" ]]
  nothing_left

  # latest is the newest snapshot by the time in its name.
  put_snapshot 20261102T000000Z.snapshot.age "$STATE/older"
  clear_record

  recipe cluster-restore latest <<< lab-sto2

  [ "$status" -eq 0 ]
  cmp "$STATE/recovered" "$STATE/older"
  [[ $output == *"20261102T000000Z.snapshot.age"* ]]
  nothing_left
}

@test "A snapshot this key cannot decrypt stops the restore before anything is reset" {
  age-keygen -o "$BATS_TEST_TMPDIR/keys/other.agekey" 2> /dev/null
  put_snapshot 20261101T000000Z.snapshot.age
  age -r "$(age-keygen -y "$BATS_TEST_TMPDIR/keys/other.agekey")" -o "$STORE/$BUCKET/lab-sto2/20261102T000000Z.snapshot.age" "$STATE/content"
  printf 'marker-not-age\n' > "$STORE/$BUCKET/lab-sto2/20261103T000000Z.snapshot.age"

  recipe cluster-restore 20261102T000000Z.snapshot.age <<< lab-sto2

  [ "$status" -ne 0 ]
  [[ $output == *"cluster-restore: the Talos age key cannot decrypt 20261102T000000Z.snapshot.age; nothing was reset"* ]]
  [[ $output != *"Type lab-sto2"* ]]
  [ -z "$(resets_or_bootstraps)" ]
  [ -z "$(calls '^timeout ')" ]
  nothing_left

  recipe cluster-restore latest <<< lab-sto2

  [ "$status" -ne 0 ]
  [[ $output == *"cluster-restore: 20261103T000000Z.snapshot.age is not an age file; nothing was reset"* ]]
  [[ $output != *"Type lab-sto2"* && $output != *marker-not-age* ]]
  [ -z "$(resets_or_bootstraps)" ]
  nothing_left
}

@test "A missing snapshot stops the restore before anything is reset" {
  put_snapshot 20261101T000000Z.snapshot.age

  recipe cluster-restore 20261109T000000Z.snapshot.age <<< lab-sto2

  [ "$status" -ne 0 ]
  [[ $output == *"cluster-restore: the etcd bucket holds no snapshot 20261109T000000Z.snapshot.age of lab-sto2; just cluster-snapshots lists them"* ]]
  [[ $output != *"Type lab-sto2"* ]]
  [ -z "$(calls '^rclone copyto ')" ]
  [ -z "$(resets_or_bootstraps)" ]
  nothing_left

  rm -r "${STORE:?}/$BUCKET/lab-sto2"
  clear_record

  recipe cluster-restore latest <<< lab-sto2

  [ "$status" -ne 0 ]
  [[ $output == *"cluster-restore: the etcd bucket holds no snapshot of lab-sto2"* ]]
  [[ $output != *"Type lab-sto2"* ]]
  [ -z "$(calls '^rclone copyto ')" ]
  [ -z "$(resets_or_bootstraps)" ]
  nothing_left
}

@test "The decrypted snapshot is removed whether the restore succeeds or fails" {
  put_snapshot 20261101T000000Z.snapshot.age
  for case in ok reset-fails apply-fails stale interrupt-dies interrupt-handles; do
    echo "$case"
    rm -f "$STATE"/{reset-fails,apply-fails,stale,interrupt,recovered,recovered-from}
    case $case in
      stale) echo worker-2 > "$STATE/stale" ;;
      interrupt-*) echo "${case#interrupt-}" > "$STATE/interrupt" ;;
      ok) ;;
      *) : > "$STATE/$case" ;;
    esac
    clear_record

    recipe cluster-restore latest --yes < /dev/null

    case $case in
      ok)
        [ "$status" -eq 0 ]
        cmp "$STATE/recovered" "$STATE/content"
        ;;
      reset-fails)
        [ "$status" -ne 0 ]
        [[ $output == *"cluster-restore: failed while resetting the control planes of lab-sto2"* ]]
        [ -z "$(calls '^talman apply ')" ]
        ;;
      *)
        [ "$status" -ne 0 ]
        cmp "$STATE/recovered" "$STATE/content"
        ;;
    esac
    [ -n "$(calls '^age (-d|--decrypt) ')" ]
    nothing_left
  done
}

@test "The age key never reaches a command line" {
  printed=()
  put_snapshot 20261101T000000Z.snapshot.age

  recipe cluster-snapshot

  [ "$status" -eq 0 ]
  printed+=("$output")

  recipe cluster-restore 20261101T000000Z.snapshot.age --yes < /dev/null

  [ "$status" -eq 0 ]
  printed+=("$output")
  cmp "$STATE/recovered" "$STATE/content"
  encrypt=$(calls '^age (-e|--encrypt|-r|--recipient) ')
  [ "$(wc -l <<< "$encrypt")" -eq 1 ]
  [[ " $encrypt " == *" $RECIPIENT "* ]]
  [[ " $encrypt " != *" -i "* && " $encrypt " != *" --identity "* ]]
  decrypt=$(calls '^age (-d|--decrypt) ')
  [ "$(wc -l <<< "$decrypt")" -eq 1 ]
  [[ " $decrypt " == *" --identity $KEY "* || " $decrypt " == *" -i $KEY "* ]]

  # In CI only SOPS_AGE_KEY holds the key, and age reads it on its standard input.
  without SOPS_AGE_KEY_FILE
  with SOPS_AGE_KEY="$SECRET"
  clear_record
  rm "$STATE/recovered"
  next_second

  recipe cluster-snapshot

  [ "$status" -eq 0 ]
  printed+=("$output")

  recipe cluster-restore 20261101T000000Z.snapshot.age --yes < /dev/null

  [ "$status" -eq 0 ]
  printed+=("$output")
  cmp "$STATE/recovered" "$STATE/content"
  decrypt=$(calls '^age (-d|--decrypt) ')
  [ "$(wc -l <<< "$decrypt")" -eq 1 ]
  [[ " $decrypt " == *" --identity - "* || " $decrypt " == *" -i - "* ]]

  absent "${SECRET#AGE-SECRET-KEY-}" "$RECORD/argv"
  [[ ${printed[*]} != *"${SECRET#AGE-SECRET-KEY-}"* ]]
  nothing_left
}

@test "the etcd recipes name every missing precondition before anything runs" {
  put_snapshot 20261101T000000Z.snapshot.age
  rm "$CLUSTER/talman.yaml" "$CLUSTER/secrets.sops.yaml"
  without SOPS_AGE_KEY_FILE
  without BACKUP_BUCKET_PREFIX
  without AWS_ACCESS_KEY_ID
  without AWS_SECRET_ACCESS_KEY
  with AWS_SECRET_ACCESS_KEY=example-secret
  cp "$ROOT/talos/.sops.yaml" "$REPO/talos/.sops.yaml"
  yq -i '.creation_rules[].age = "example-talos-age-recipient"' "$REPO/talos/.sops.yaml"

  for run in cluster-snapshot 'cluster-restore latest'; do
    read -ra words <<< "$run"

    recipe "${words[@]}" <<< lab-sto2

    [ "$status" -ne 0 ]
    for message in "talos/lab-sto2/talman.yaml does not exist" "talos/lab-sto2/secrets.sops.yaml does not exist" \
      "neither SOPS_AGE_KEY_FILE nor SOPS_AGE_KEY is set" "BACKUP_BUCKET_PREFIX is not set" \
      "AWS_ACCESS_KEY_ID is not set" "AWS_SECRET_ACCESS_KEY still holds the placeholder"; do
      [[ $output == *"$message"* ]]
    done
    # Encrypting needs the recipient, and decrypting the key only.
    if [[ $run == cluster-snapshot ]]; then
      [[ $output == *"talos/.sops.yaml holds no age recipient yet"* ]]
    else
      [[ $output != *"talos/.sops.yaml holds no age recipient"* ]]
    fi
  done

  recipe cluster-snapshots

  [ "$status" -ne 0 ]
  [[ $output == *"BACKUP_BUCKET_PREFIX is not set"* && $output == *"AWS_ACCESS_KEY_ID is not set"* ]]

  # A bucket prefix that is not the start of a bucket's name is refused without being printed.
  reset_environment
  without BACKUP_BUCKET_PREFIX
  with BACKUP_BUCKET_PREFIX=Marker_Prefix
  cp "$BATS_FILE_TMPDIR/talman.yaml" "$CLUSTER/talman.yaml"
  : > "$CLUSTER/secrets.sops.yaml"
  RECIPIENT=$RECIPIENT yq -i '.creation_rules[].age = strenv(RECIPIENT)' "$REPO/talos/.sops.yaml"
  for run in cluster-snapshot cluster-snapshots 'cluster-restore latest'; do
    read -ra words <<< "$run"

    recipe "${words[@]}" <<< lab-sto2

    [ "$status" -ne 0 ]
    [[ $output == *"BACKUP_BUCKET_PREFIX is not the start of a bucket name"* ]]
    [[ $output != *Marker_Prefix* ]]
  done
  [ ! -e "$RECORD/argv" ] || [ -z "$(calls '^(talman|rclone|age|kubectl|timeout) ')" ]
  nothing_left
}

@test "the etcd recipes refuse Go's HTTP/2 debug log" {
  with GODEBUG=x509sha1=1,http2debug=2

  for run in cluster-snapshot cluster-snapshots 'cluster-restore latest --yes'; do
    read -ra words <<< "$run"

    recipe "${words[@]}" < /dev/null

    [ "$status" -ne 0 ]
    [[ $output == *"GODEBUG sets http2debug"* ]]
  done
  [ -z "$(calls '^(talman|rclone|age|kubectl|timeout) ')" ]
}

@test "cluster-restore takes a snapshot's name or latest, a cluster and --yes" {
  for arguments in '--yes' '../20261101T000000Z.snapshot.age' 'lab-sto2/20261101T000000Z.snapshot.age' \
    '--force latest' 'latest lab-sto2 extra' 'latest lab-sto2 --onboard'; do
    read -ra words <<< "$arguments"

    recipe cluster-restore "${words[@]}" < /dev/null

    [ "$status" -eq 2 ]
    [[ $output == *"usage: cluster-restore <snapshot>|latest [cluster] [--yes]"* ]]
  done
  [ -z "$(calls '^(talman|rclone|age|kubectl|timeout) ')" ]
}

@test "a restore counts a node Ready only once its kubelet has reported after the reset" {
  put_snapshot 20261101T000000Z.snapshot.age
  printf '%s\n' worker-2 cp-3 > "$STATE/stale"

  recipe cluster-restore latest --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"cluster-restore: cp-3, worker-2 did not report Ready after the reset"* ]]
  [[ $output == *"cluster-restore: failed while waiting for every node to be Ready"* ]]
  [ "$(calls '^kubectl get nodes ' | wc -l)" -gt 1 ]
  nothing_left
}

@test "a private directory inside the repository is refused" {
  without TMPDIR
  with TMPDIR="$REPO/talos"
  put_snapshot 20261101T000000Z.snapshot.age

  for run in cluster-snapshot 'cluster-restore latest --yes'; do
    read -ra words <<< "$run"

    recipe "${words[@]}" < /dev/null

    [ "$status" -ne 0 ]
    [[ $output == *"TMPDIR lies inside the repository; the snapshot is kept outside it"* ]]
  done
  [ -z "$(calls '^(talman|age) ')" ]
  [ -z "$(calls '^rclone copyto ')" ]
  [ -z "$(find "$REPO/talos" -mindepth 1 -maxdepth 1 -name 'cluster-*')" ]
}

@test "cluster-snapshot refuses to overwrite a snapshot taken in the same second" {
  # A date that gives the recipe the second of a snapshot already in the bucket.
  real=$(command -v date)
  fake date <<EOF
if [[ \$* == '-u +%Y%m%dT%H%M%SZ' ]]; then
  echo 20261114T101500Z
  exit 0
fi
exec "$real" "\$@"
EOF
  printf 'marker-earlier-snapshot\n' > "$BATS_TEST_TMPDIR/earlier"
  put_snapshot 20261114T101500Z.snapshot.age "$BATS_TEST_TMPDIR/earlier"
  object="$STORE/$BUCKET/lab-sto2/20261114T101500Z.snapshot.age"
  cp "$object" "$BATS_TEST_TMPDIR/object.before"

  recipe cluster-snapshot

  [ "$status" -ne 0 ]
  [[ $output == *"cluster-snapshot: the etcd bucket holds lab-sto2/20261114T101500Z.snapshot.age already; it is not overwritten"* ]]
  [ -n "$(calls '^talman etcd snapshot ')" ]
  [ -z "$(calls '^rclone copyto ')" ]
  cmp "$object" "$BATS_TEST_TMPDIR/object.before"
  [ "$(find "$STORE" -type f | wc -l)" -eq 1 ]
  nothing_left

  # A bucket that cannot be listed is not written to either.
  : > "$FAILS/list"
  clear_record

  recipe cluster-snapshot

  [ "$status" -ne 0 ]
  [[ $output == *"rclone cannot list the etcd bucket with the state key"* ]]
  [ -z "$(calls '^rclone copyto ')" ]
  cmp "$object" "$BATS_TEST_TMPDIR/object.before"
  nothing_left
}

@test "with CI set, the etcd recipes keep talman's output in their logs" {
  put_snapshot 20261101T000000Z.snapshot.age
  with CI=true

  recipe cluster-snapshot

  [ "$status" -eq 0 ]
  grep -q 'snapshotting etcd' "$CLUSTER/clusterconfig/cluster-snapshot.log"

  recipe cluster-restore latest --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"cluster-restore: talman reset succeeded; its output is in talos/lab-sto2/clusterconfig/cluster-restore.log"* ]]
  grep -q '== resetting cp-1' "$CLUSTER/clusterconfig/cluster-restore.log"
  grep -q 'bootstrapping etcd' "$CLUSTER/clusterconfig/cluster-restore.log"
  [[ $output != *"reaching the nodes"* ]]
}
