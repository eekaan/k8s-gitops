#!/usr/bin/env bats
# Proves the scenarios of features/rebuild.feature that run just cluster-last-copies; each test
# carries its scenario's title. The recipe and the recipes it runs, bao-seal-restore,
# bao-volsync-password, openbao-snapshot-check and postgres-dump-check, run from a copy of the
# repository with an environment of their own, so no run reads this checkout's .env, keys,
# kubeconfig or custody files. Encrypting and decrypting are local and offline, with the pinned age
# and throwaway keys in the test's own directory. Whatever would reach the cluster, the object
# storage or a container is a recording fake (tests/fixtures/cluster-last-copies): kubectl answers
# from files and keeps what a run changes, a Job made from a CronJob putting into the buckets what
# the job would upload; flux suspends and resumes there; rclone's buckets are directories; the
# container runtime's pg_restore reads a made-up archive; stat says which directories are
# memory-backed. tofu, openstack, talosctl, talman and helm fail when called. The keys, passwords,
# addresses and names the fakes hold are markers, which no run may print.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  JUST=$(command -v just)
  FIXTURES=$BATS_TEST_DIRNAME/fixtures/cluster-last-copies
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  STORE="$BATS_TEST_TMPDIR/store"
  STAGE="$BATS_TEST_TMPDIR/stage"
  # The recipes' TMPDIR, and the memory-backed directory the checks prefer, which must hold nothing
  # once a run has ended.
  WORK="$BATS_TEST_TMPDIR/tmp"
  RUN="$BATS_TEST_TMPDIR/run"
  CUSTODY="$BATS_TEST_TMPDIR/custody"
  mkdir -p "$BIN" "$RECORD" "$STATE/cluster" "$STORE" "$BATS_TEST_TMPDIR/store-fails" "$WORK" "$RUN" "$CUSTODY" \
    "$BATS_TEST_TMPDIR/keys" "$BATS_TEST_TMPDIR/repo/infra/openstack" "$BATS_TEST_TMPDIR/repo/talos/lab-sto2/clusterconfig" \
    "$BATS_TEST_TMPDIR/repo/kubernetes/components/cnpg-cluster" "$BATS_TEST_TMPDIR/repo/kubernetes/apps/base/openbao/openbao/app"
  : >"$RECORD/argv"
  : >"$RECORD/events"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp "$ROOT/talos/.sops.yaml" "$REPO/talos/.sops.yaml"
  cp "$ROOT/.sops.yaml" "$REPO/.sops.yaml"
  cp "$ROOT/kubernetes/components/cnpg-cluster/cronjob.yaml" "$REPO/kubernetes/components/cnpg-cluster/cronjob.yaml"
  # The values whose seal stanza names the seal keys' ids, which the recipes read from their checkout.
  VALUES="$REPO/kubernetes/apps/base/openbao/openbao/app/values.yaml"
  cp "$ROOT/kubernetes/apps/base/openbao/openbao/app/values.yaml" "$VALUES"
  # The kubeconfig the recipes point kubectl at; the fake reads none.
  : >"$REPO/talos/lab-sto2/clusterconfig/kubeconfig"
  # The backend file, the endpoint's only source, with a marker for the endpoint.
  ENDPOINT=https://marker-endpoint.example.invalid
  sed -E "s#https://[^\"]+#$ENDPOINT#" "$ROOT/infra/openstack/backend.hcl" >"$REPO/infra/openstack/backend.hcl"
  grep -qF "$ENDPOINT" "$REPO/infra/openstack/backend.hcl"
  # The Talos age key and the Flux age key, throwaway ones, whose recipients the two .sops.yaml name,
  # and a third key that is neither.
  KEY="$BATS_TEST_TMPDIR/keys/talos.agekey"
  FLUX_KEY="$BATS_TEST_TMPDIR/keys/flux.agekey"
  OTHER_KEY="$BATS_TEST_TMPDIR/keys/other.agekey"
  for key in "$KEY" "$FLUX_KEY" "$OTHER_KEY"; do
    age-keygen -o "$key" 2>/dev/null
  done
  RECIPIENT=$(age-keygen -y "$KEY")
  FLUX_RECIPIENT=$(age-keygen -y "$FLUX_KEY")
  OTHER_RECIPIENT=$(age-keygen -y "$OTHER_KEY")
  RECIPIENT=$RECIPIENT yq -i '.creation_rules[].age = strenv(RECIPIENT)' "$REPO/talos/.sops.yaml"
  FLUX_RECIPIENT=$FLUX_RECIPIENT yq -i '.creation_rules[].age = strenv(FLUX_RECIPIENT)' "$REPO/.sops.yaml"
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  printf '#!/usr/bin/env bash\n' >"$BIN/mise"
  chmod +x "$BIN/mise"
  for tool in kubectl flux rclone docker stat; do
    cp "$FIXTURES/$tool" "$BIN/$tool"
  done
  for tool in tofu openstack talosctl talman helm; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >> "%s"\necho "unexpected call: %s $*" >&2\nexit 1\n' \
      "$tool" "$RECORD/argv" "$tool" >"$BIN/$tool"
    chmod +x "$BIN/$tool"
  done
  command -v stat >"$STATE/real-stat"
  command -v age >"$STATE/real-age"
  record age age-keygen jq yq tar gzip sha256sum base64
  echo "$RECIPIENT" >"$STATE/recipient"
  echo marker-prefix >"$STATE/prefix"
  # What the jobs upload: a raft snapshot archive as the pinned OpenBao writes one, and a dump of a
  # database with tables, as the fake pg_restore reads one.
  snapshot_archive >"$STATE/snapshot.plain"
  dump_archive >"$STATE/dump.plain"
  # What the cluster holds: the seal key, the volume backups' master and the PostgreSQL backups'
  # customer key, each a marker, and the custody files that hold the same.
  SEAL=5ea15ea15ea15ea15ea15ea15ea15ea15ea15ea15ea15ea15ea15ea15ea10001
  MASTER=3a573a573a573a573a573a573a573a573a573a573a573a573a573a573a570001
  SSE=$(printf 'marker-customer-key-of-32-bytes!' | base64)
  OPENBAO_FILE="$CUSTODY/openbao.age"
  VOLSYNC_FILE="$CUSTODY/volsync.age"
  POSTGRES_FILE="$CUSTODY/postgres.age"
  openbao_custody "$SEAL"
  volsync_custody "$MASTER"
  postgres_custody "$SSE"
  a_cluster
  BASE_ENVIRONMENT=(
    SOPS_AGE_KEY_FILE="$KEY"
    FLUX_AGE_KEY_FILE="$FLUX_KEY"
    BACKUP_BUCKET_PREFIX=marker-prefix
    AWS_ACCESS_KEY_ID=marker-state-access-key-id
    AWS_SECRET_ACCESS_KEY=marker-state-secret-key
    CLUSTER_S3_ACCESS_KEY_ID=marker-cluster-access-key-id
    CLUSTER_S3_SECRET_ACCESS_KEY=marker-cluster-secret-key
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
    { echo '#!/usr/bin/env bash'; printf '%s\n' "printf '%s\n' \"$tool \$*\" >> \"$RECORD/argv\"" "exec \"$real\" \"\$@\""; } >"$BIN/$tool"
    chmod +x "$BIN/$tool"
  done
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

# reset_environment: the environment the recipes get, as setup made it.
reset_environment() {
  ENVIRONMENT=("${BASE_ENVIRONMENT[@]}")
}

# last_copies [ARG...]: runs just cluster-last-copies with the three custody files and ARG...
# against the copy, with only ENVIRONMENT set and the fakes first on PATH. A run that blocks fails
# after five minutes instead of hanging the tests.
last_copies() {
  run timeout 300 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" cluster-last-copies \
    "$OPENBAO_FILE" "$VOLSYNC_FILE" "$POSTGRES_FILE" "$@"
}

calls() {
  grep -E -- "$1" "$RECORD/argv" 2>/dev/null || true
}

# snapshot_archive: a raft snapshot archive on standard output, as the pinned OpenBao writes one and
# tests/openbao-snapshot-recipes.bats builds it: meta.json, state.bin, SHA256SUMS and
# SHA256SUMS.sealed in a ustar archive in a gzip stream, holding markers.
snapshot_archive() {
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  printf 'marker-storage-key\000\001marker-storage-value\n' >"$STAGE/state.bin"
  printf 'marker-sealed-checksums\000\002' >"$STAGE/SHA256SUMS.sealed"
  jq -cn --argjson size "$(stat -c %s "$STAGE/state.bin")" '{Version: 1, ID: "bolt-snapshot", Index: 4711, Term: 3, Peers: null,
    Configuration: {Servers: [range(3) | {Suffrage: 0, ID: "marker-member-\(.)", Address: "marker-address-\(.).example.invalid:8201"}]},
    ConfigurationIndex: 1, Size: $size}' >"$STAGE/meta.json"
  for member in state.bin meta.json; do
    printf '%s  %s\n' "$(sha256sum <"$STAGE/$member" | cut -d' ' -f1)" "$member"
  done >"$STAGE/SHA256SUMS"
  tar --create --format=ustar --owner=0 --group=0 --numeric-owner --mode=0600 --mtime='2026-11-18 00:43:07 UTC' \
    --blocking-factor=1 --directory "$STAGE" --file - meta.json state.bin SHA256SUMS SHA256SUMS.sealed | gzip -c
}

# dump_archive: what a dump holds in the clear, as the fake pg_restore reads it: two tables, each
# named by a marker, and a row.
dump_archive() {
  cat <<'EOF'
PGDMP
;
; Archive created at 2026-11-18 02:00:12 UTC
;     dbname: marker_dbname
;     Format: CUSTOM
;     Dumped from database version: 18.6 (Debian 18.6-1.pgdg13+1)
;     Dumped by pg_dump version: 18.6 (Debian 18.6-1.pgdg13+1)
;
201; 1259 16381 TABLE public marker_table_1 marker_owner
202; 1259 16382 TABLE public marker_table_2 marker_owner
4001; 0 16381 TABLE DATA public marker_table_1 marker_owner
4002; 0 16382 TABLE DATA public marker_table_2 marker_owner
-----ROWS-----
marker-row-secret-value
EOF
}

# openbao_custody KEY [RECIPIENT]: the OpenBao custody file as bao-recovery writes it, holding marker
# shares and the seal key KEY, encrypted to RECIPIENT, the Talos age key's by default.
# shellcheck disable=SC2016 # $key is a jq variable.
openbao_custody() {
  rm -f "$OPENBAO_FILE"
  jq -n --arg key "$1" '{cluster: "lab-sto2", recovery: {shares: 5, threshold: 3,
    keys_base64: [range(5) | "marker-recovery-share-\(. + 1)" | @base64]},
    seal: {secret: "openbao-seal-1", key_id: "openbao-seal-1", key: $key}}' |
    age --encrypt --recipient "${2:-$RECIPIENT}" --output "$OPENBAO_FILE"
}

# rotated_openbao_custody CURRENT PREVIOUS: the OpenBao custody file as bao-seal-keep writes it after
# the rotation rotated makes: marker shares, the current key CURRENT of openbao-seal-2 as its seal and
# the previous key PREVIOUS of openbao-seal-1 as its previous_seal, encrypted to the Talos age key.
# shellcheck disable=SC2016 # $current and $previous are jq variables.
rotated_openbao_custody() {
  rm -f "$OPENBAO_FILE"
  jq -n --arg current "$1" --arg previous "$2" '{cluster: "lab-sto2", created: "2026-11-19T00:00:00Z",
    recovery: {shares: 5, threshold: 3, keys_base64: [range(5) | "marker-recovery-share-\(. + 1)" | @base64]},
    seal: {secret: "openbao-seal-2", key_id: "openbao-seal-2", key: $current},
    previous_seal: {secret: "openbao-seal-1", key_id: "openbao-seal-1", key: $previous}}' |
    age --encrypt --recipient "$RECIPIENT" --output "$OPENBAO_FILE"
}

# running_config: the ConfigMap openbao/openbao-config of the cluster, holding the server configuration
# of the copy's values.yaml as it is now, as the chart renders it there for the servers to run.
running_config() {
  yq -o json '{"kind": "ConfigMap", "metadata": {"namespace": "openbao", "name": "openbao-config"},
    "data": {"extraconfig-from-values.hcl": .server.ha.raft.config}}' "$VALUES" >"$STATE/cluster/configmap.openbao.openbao-config.json"
}

# rotated: the copy's tree, and the cluster's servers, after the seal-key rotation
# docs/runbooks/openbao.md describes: extraVolumes mounts openbao-seal-2 beside openbao-seal-1, and the
# seal stanza's current key is openbao-seal-2 and its previous key openbao-seal-1.
rotated() {
  yq -i '.server.ha.raft.config |= sub("seal \"static\" \\{[^}]*\\}"; "seal \"static\" {\n  current_key_id = \"openbao-seal-2\"\n  current_key = \"file:///openbao/userconfig/openbao-seal-2/key\"\n  previous_key_id = \"openbao-seal-1\"\n  previous_key = \"file:///openbao/userconfig/openbao-seal-1/key\"\n}")
    | .server.extraVolumes = [{"type": "secret", "name": "openbao-seal-2"}] + .server.extraVolumes' "$VALUES"
  grep -qx '  previous_key_id = "openbao-seal-1"' <(yq '.server.ha.raft.config' "$VALUES")
  running_config
}

# volsync_custody MASTER [RECIPIENT]: the volume backups' custody file as bao-seed-volsync writes it.
# shellcheck disable=SC2016 # $master is a jq variable.
volsync_custody() {
  rm -f "$VOLSYNC_FILE"
  jq -n --arg master "$1" '{cluster: "lab-sto2", volsync: {master: $master}}' |
    age --encrypt --recipient "${2:-$RECIPIENT}" --output "$VOLSYNC_FILE"
}

# postgres_custody KEY [RECIPIENT]: the PostgreSQL backups' custody file as bao-seed-postgres writes it.
# shellcheck disable=SC2016 # $key is a jq variable.
postgres_custody() {
  rm -f "$POSTGRES_FILE"
  jq -n --arg key "$1" '{cluster: "lab-sto2", created: "2026-11-01T00:00:00Z", postgres: {sse_c_key: $key}}' |
    age --encrypt --recipient "${2:-$RECIPIENT}" --output "$POSTGRES_FILE"
}

# password APP: the repository password of APP derived from MASTER, as components/volsync derives it.
password() {
  printf '%s/%s' "$MASTER" "$1" | sha256sum | cut -d' ' -f1
}

# secret NAMESPACE NAME KEY VALUE: the Secret NAME in NAMESPACE holding VALUE under KEY.
# shellcheck disable=SC2016 # $ns, $name, $key and $value are jq variables.
secret() {
  jq -n --arg ns "$1" --arg name "$2" --arg key "$3" --arg value "$4" \
    '{kind: "Secret", metadata: {namespace: $ns, name: $name}, data: {($key): ($value | @base64)}}' >"$STATE/cluster/secret.$1.$2.json"
}

# a_cluster: the cluster the recipe reads: the secret store with its seal Secret, the server
# ConfigMap whose seal stanza names it, and its snapshot CronJob; three databases from the component, n8n's, Ascender's and Backstage's, each with its
# primary, its dump CronJob, its ObjectStore with a recovery window, and its backup Secret with the
# customer key; two volumes backed up by VolSync, n8n's and Open WebUI's, each owned by its
# application's Kustomization, which is not suspended, and with its Secret's password; and in the
# buckets the copies of an earlier night.
# shellcheck disable=SC2016 # the $ words are jq variables.
a_cluster() {
  local db ns name app
  secret openbao openbao-seal-1 key "$SEAL"
  running_config
  DATABASES=(ai-system/n8n-db ascender/ascender-db backstage/backstage-db)
  PRIMARIES=(n8n-db-1 ascender-db-3 backstage-db-2)
  VOLUMES=(ai-system/n8n ai-system/open-webui)
  for i in 0 1 2; do
    db=${DATABASES[i]}
    ns=${db%/*} name=${db#*/}
    jq -n --arg ns "$ns" --arg name "$name" --arg primary "${PRIMARIES[i]}" '{kind: "Cluster",
      metadata: {namespace: $ns, name: $name},
      spec: {instances: 3, plugins: [{name: "barman-cloud.cloudnative-pg.io", isWALArchiver: true,
        parameters: {barmanObjectName: $name, serverName: $name}}]},
      status: {currentPrimary: $primary}}'
  done | jq -s '{items: .}' >"$STATE/cluster/clusters.json"
  for db in "${DATABASES[@]}"; do
    ns=${db%/*} name=${db#*/}
    jq -n --arg ns "$ns" --arg name "$name" '{kind: "ObjectStore", metadata: {namespace: $ns, name: $name},
      spec: {retentionPolicy: "30d", configuration: {destinationPath: "s3://marker-prefix-postgres/lab-sto2/\($ns)",
        s3Credentials: {sseCustomerKey: {name: "\($name)-backup", key: "SSE_C_KEY"}}}},
      status: {serverRecoveryWindow: {($name): {firstRecoverabilityPoint: "2026-10-19T02:47:31Z",
        lastSuccessfulBackupTime: "2026-11-18T02:49:02Z"}}}}' >"$STATE/cluster/objectstore.$ns.$name.json"
    secret "$ns" "$name-backup" SSE_C_KEY "$SSE"
    mkdir -p "$STORE/marker-prefix-postgres/lab-sto2/$ns/$name"
    age --encrypt --recipient "$RECIPIENT" --output "$STORE/marker-prefix-postgres/lab-sto2/$ns/$name/20261117T020533Z.dump.age" "$STATE/dump.plain"
  done
  mkdir -p "$STORE/marker-prefix-openbao/lab-sto2"
  age --encrypt --recipient "$RECIPIENT" --output "$STORE/marker-prefix-openbao/lab-sto2/20261117T184300Z.snapshot.age" "$STATE/snapshot.plain"
  {
    jq -n '{metadata: {namespace: "openbao", name: "openbao-snapshots"}}'
    for db in "${DATABASES[@]}"; do
      jq -n --arg ns "${db%/*}" --arg name "${db#*/}-pgdump" '{metadata: {namespace: $ns, name: $name}}'
    done
  } | jq -s '{items: .}' >"$STATE/cluster/cronjobs.json"
  for app in "${VOLUMES[@]}"; do
    jq -n --arg ns "${app%/*}" --arg name "${app#*/}" '{kind: "ReplicationSource",
      metadata: {namespace: $ns, name: $name,
        labels: {"kustomize.toolkit.fluxcd.io/name": $name, "kustomize.toolkit.fluxcd.io/namespace": "flux-system"}},
      spec: {sourcePVC: $name, trigger: {schedule: "23 3 * * *"}, restic: {repository: "\($name)-volsync"}}}'
    secret "${app%/*}" "${app#*/}-volsync" RESTIC_PASSWORD "$(password "${app#*/}")"
  done | jq -s '{items: .}' >"$STATE/cluster/replicationsources.json"
  for app in "${VOLUMES[@]}"; do
    jq -n --arg name "${app#*/}" '{kind: "Kustomization", metadata: {namespace: "flux-system", name: $name}}'
  done | jq -s '{items: .}' >"$STATE/cluster/kustomizations.json"
}

# nothing_changed: the run created no Job, patched nothing, suspended nothing and ran nothing in a
# pod: the fakes recorded no change, and no call that makes one.
nothing_changed() {
  echo "changes: $(paste -sd'|' - <"$RECORD/events")"
  [ ! -s "$RECORD/events" ]
  [ -z "$(calls '^kubectl (create|patch|exec|apply|delete|label|annotate|scale|replace|edit) ')" ]
  [ -z "$(calls '^flux ')" ]
}

# nothing_left: neither the recipes' TMPDIR nor their memory-backed directory holds anything.
nothing_left() {
  local left
  left=$(find "$WORK" "$RUN" -mindepth 1)
  [ -z "$left" ] || { echo "left on disk: $left" >&2; return 1; }
}

# start_of: the run's start, in Unix seconds, from the name of the first Job the run created.
start_of() {
  sed -nE '1s/^job [a-z0-9-]+\/last-([0-9]{10})-.*/\1/p' "$RECORD/events"
}

# newest PATH: the name of the newest object under PATH of the store.
newest() {
  find "$STORE/$1" -maxdepth 1 -type f -printf '%f\n' | sort | tail -n 1
}

# refused LINE...: the last run failed, printing each LINE, and changed nothing.
refused() {
  local line
  echo "$output"
  [ "$status" -ne 0 ]
  for line; do
    grep -qxF -- "cluster-last-copies: $line" <<<"$output" || { echo "missing: $line"; return 1; }
  done
  nothing_changed
  nothing_left
}

# failed_on COPY REASON: the last run failed naming COPY and REASON, and every Kustomization it
# suspended was resumed.
failed_on() {
  echo "$output"
  [ "$status" -ne 0 ]
  grep -qxF -- "cluster-last-copies: $1: $2" <<<"$output" || { echo "missing: $1: $2"; return 1; }
  [ "$(grep -c '^suspended ' "$RECORD/events")" -eq "$(grep -c '^resumed ' "$RECORD/events")" ]
  [ "$(find "$STATE" -maxdepth 1 -name 'suspended.*' | wc -l)" -eq 0 ]
  nothing_left
}

# again: a fresh record and cluster state for the next run, the toggles a test set removed.
again() {
  : >"$RECORD/argv"
  : >"$RECORD/events"
  rm -rf "$STATE/jobs"
  rm -f "$STATE"/{job-fails,job-stuck,no-upload,plain-upload,archiver-stuck,archiver-late,archiver-ahead,mover-fails,mover-stuck,manual-result,last-manual,syncing,manual,synced,switched,idle,resume-fails}.*
}

# leaked TEXT...: fails naming each TEXT that the outputs or the record of calls hold.
leaked() {
  local text found=0
  for text; do
    if grep -qF -- "$text" "$BATS_TEST_TMPDIR/outputs" "$BATS_TEST_TMPDIR/calls"; then
      echo "leaked: $text" >&2
      found=1
    fi
  done
  return "$found"
}

@test "The last copies are taken and checked before the cluster is taken down, and what each covers is printed" {
  local start tag since db volume line expected i before after
  # A backup of Open WebUI's volume runs when the run begins, n8n's database is idle, so its switch
  # leaves the WAL as it is, Backstage's archiver takes two reads to reach the switched segment, and
  # Ascender's switch completes a segment of its own, which its archiver is past by the first read.
  echo 2 >"$STATE/syncing.ai-system.open-webui"
  : >"$STATE/idle.ai-system.n8n-db"
  echo 2 >"$STATE/archiver-late.backstage.backstage-db"
  echo 0000000100000000000000A3 >"$STATE/segment.ascender.ascender-db"
  : >"$STATE/archiver-ahead.ascender.ascender-db"
  before=$(date -u +%s)
  last_copies
  after=$(date -u +%s)
  echo "$output"
  [ "$status" -eq 0 ]
  start=$(start_of)
  [[ $start =~ ^[0-9]{10}$ ]] && ((start >= before && start <= after))
  tag=last-$start
  # The copies, in this order: the secret store, each database, each volume, every Job named for the
  # run and its CronJob, the trigger for the run, and every Kustomization resumed.
  expected="job openbao/$tag-openbao-snapshots from openbao-snapshots
job ai-system/$tag-n8n-db-pgdump from n8n-db-pgdump
switched ai-system/n8n-db 00000001000000000000002A
job ascender/$tag-ascender-db-pgdump from ascender-db-pgdump
switched ascender/ascender-db 0000000100000000000000A3
job backstage/$tag-backstage-db-pgdump from backstage-db-pgdump
switched backstage/backstage-db 00000001000000000000002A
suspended flux-system/n8n
patched ai-system/n8n manual $tag while its Kustomization is suspended
resumed flux-system/n8n
suspended flux-system/open-webui
patched ai-system/open-webui manual $tag while its Kustomization is suspended
resumed flux-system/open-webui"
  diff <(echo "$expected") "$RECORD/events"
  # Each copy was checked: the snapshot and every dump downloaded and decrypted, every dump read by
  # pg_restore, each switch made through psql in the postgres container of the primary.
  [ "$(calls '^rclone copyto ' | grep -c "/$(newest marker-prefix-openbao/lab-sto2) ")" -eq 1 ]
  for db in "${DATABASES[@]}"; do
    [ "$(calls '^rclone copyto ' | grep -c "/lab-sto2/$db/$(newest "marker-prefix-postgres/lab-sto2/$db") ")" -eq 1 ]
  done
  [ "$(calls '^docker run ' | grep -c ' --list /dump/plain.dump$')" -eq 3 ]
  for i in 0 1 2; do
    [ "$(calls "^kubectl exec ${PRIMARIES[i]} --namespace ${DATABASES[i]%/*} --container postgres -- psql " | grep -c 'pg_switch_wal')" -eq 1 ]
  done
  # Every call the recipe makes of kubectl but exec, whose stream kubectl gives no deadline, is
  # bounded; the one read bao-seal-restore makes is its own.
  calls '^kubectl ' | grep -v '^kubectl exec ' |
    grep -vxF 'kubectl get secret openbao-seal-1 --namespace openbao --output json --ignore-not-found' >"$BATS_TEST_TMPDIR/bounded"
  [ -s "$BATS_TEST_TMPDIR/bounded" ]
  echo "unbounded: $(grep -v -- ' --request-timeout=30s$' "$BATS_TEST_TMPDIR/bounded" | paste -sd'|' -)"
  [ "$(grep -vc -- ' --request-timeout=30s$' "$BATS_TEST_TMPDIR/bounded")" -eq 0 ]
  # The summary, last: one line for each copy, by namespace and name.
  since=$(date -u -d "@$start" '+%Y-%m-%d %H:%M:%S')
  expected="cluster-last-copies: the last copies of lab-sto2, each taken since $since UTC:
  openbao/openbao-snapshots: snapshot $(newest marker-prefix-openbao/lab-sto2)"
  for i in 0 1 2; do
    db=${DATABASES[i]}
    line="  $db: dump $(newest "marker-prefix-postgres/lab-sto2/$db"); WAL archived through $(cat "$STATE/segment.${db%/*}.${db#*/}" 2>/dev/null || echo 00000001000000000000002A)"
    expected+=$'\n'"$line"
  done
  for volume in "${VOLUMES[@]}"; do
    expected+=$'\n'"  $volume: volume backed up at $(cat "$STATE/synced.${volume%/*}.${volume#*/}")"
  done
  echo "expected summary:"
  echo "$expected"
  [ "${lines[${#lines[@]} - 7]}" = "cluster-last-copies: the last copies of lab-sto2, each taken since $since UTC:" ]
  for i in 1 2 3 4 5 6; do
    line=$(sed -n "$((i + 1))p" <<<"$expected")
    if ((i >= 2 && i <= 4)); then
      [[ ${lines[${#lines[@]} - 7 + i]} =~ ^"$line, which holds every transaction committed before "[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}" UTC"$ ]]
    else
      [ "${lines[${#lines[@]} - 7 + i]}" = "$line" ]
    fi
  done
  # Every copy in a bucket is this run's, beside the earlier night's.
  [ "$(find "$STORE/marker-prefix-openbao/lab-sto2" -type f | wc -l)" -eq 2 ]
  [[ ! $(newest marker-prefix-openbao/lab-sto2) < $(date -u -d "@$start" +%Y%m%dT%H%M%SZ) ]]
  for db in "${DATABASES[@]}"; do
    [ "$(find "$STORE/marker-prefix-postgres/lab-sto2/$db" -type f | wc -l)" -eq 2 ]
    [[ ! $(newest "marker-prefix-postgres/lab-sto2/$db") < $(date -u -d "@$start" +%Y%m%dT%H%M%SZ) ]]
  done
  nothing_left
}

@test "A custody file that is missing, does not open or does not hold what the cluster holds stops the last copies before any is taken, and is named" {
  local role file kept reason above own
  local -A roles=([openbao]="the OpenBao custody file" [volsync]="the volume backups' custody file" [postgres]="the PostgreSQL backups' custody file")
  local -A holds=([openbao]="the seal key the Secret openbao/openbao-seal-1 holds"
    [volsync]="the master the Secret ai-system/n8n-volsync's password is derived from"
    [postgres]="the customer key the Secret ai-system/n8n-db-backup holds")
  for role in openbao volsync postgres; do
    file="$CUSTODY/$role.age"
    kept="$BATS_TEST_TMPDIR/$role.kept"
    cp -p "$file" "$kept"
    # Missing.
    rm "$file"
    last_copies
    refused "${roles[$role]}, $file, does not exist"
    # Where another could have written it: writable by its group.
    cp -p "$kept" "$file"
    chmod g+w "$file"
    last_copies
    refused "${roles[$role]}, $file, is not read: it is not where only this user can have written it"
    chmod g-w "$file"
    # Encrypted to another key than the Talos age key.
    case $role in
      openbao) openbao_custody "$SEAL" "$OTHER_RECIPIENT" ;;
      volsync) volsync_custody "$MASTER" "$OTHER_RECIPIENT" ;;
      postgres) postgres_custody "$SSE" "$OTHER_RECIPIENT" ;;
    esac
    last_copies
    refused "${roles[$role]}, $file, does not open with the Talos age key"
    # Holding another key than the cluster's.
    case $role in
      openbao) openbao_custody "${SEAL%0001}0002" ;;
      volsync) volsync_custody "${MASTER%0001}0002" ;;
      postgres) postgres_custody "$(printf 'marker-another-key-of-32-bytes!!' | base64)" ;;
    esac
    last_copies
    refused "${roles[$role]}, $file, does not hold ${holds[$role]}"
    cp -p "$kept" "$file"
  done
  # Every volume's and every database's Secret is compared, the last as the first: Open WebUI's
  # password alone derived from another master, then Backstage's customer key alone another.
  secret ai-system open-webui-volsync RESTIC_PASSWORD "$(printf '%s/%s' "${MASTER%0001}0002" open-webui | sha256sum | cut -d' ' -f1)"
  last_copies
  refused "the volume backups' custody file, $VOLSYNC_FILE, does not hold the master the Secret ai-system/open-webui-volsync's password is derived from"
  [ "$(grep -c 'does not hold the master' <<<"$output")" -eq 1 ]
  secret ai-system open-webui-volsync RESTIC_PASSWORD "$(password open-webui)"
  secret backstage backstage-db-backup SSE_C_KEY "$(printf 'marker-another-key-of-32-bytes!!' | base64)"
  last_copies
  refused "the PostgreSQL backups' custody file, $POSTGRES_FILE, does not hold the customer key the Secret backstage/backstage-db-backup holds"
  [ "$(grep -c 'does not hold the customer key' <<<"$output")" -eq 1 ]
  secret backstage backstage-db-backup SSE_C_KEY "$SSE"
  # The Talos age key: missing, or not the key talos/.sops.yaml encrypts to.
  without SOPS_AGE_KEY_FILE
  last_copies
  refused "the Talos age key is missing: it opens the custody files and the copies"
  with SOPS_AGE_KEY_FILE="$OTHER_KEY"
  last_copies
  refused "the Talos age key is not the key talos/.sops.yaml encrypts to"
  reset_environment
  # The Flux age key: missing, or not the key .sops.yaml encrypts to.
  without FLUX_AGE_KEY_FILE
  last_copies
  refused "the Flux age key is missing: FLUX_AGE_KEY_FILE names no file"
  reset_environment
  OTHER_RECIPIENT=$OTHER_RECIPIENT yq -i '.creation_rules[].age = strenv(OTHER_RECIPIENT)' "$REPO/.sops.yaml"
  last_copies
  refused "the Flux age key is not the key .sops.yaml encrypts to; point FLUX_AGE_KEY_FILE at that key"
  FLUX_RECIPIENT=$FLUX_RECIPIENT yq -i '.creation_rules[].age = strenv(FLUX_RECIPIENT)' "$REPO/.sops.yaml"
  # What is missing is named all at once.
  rm "$VOLSYNC_FILE" "$POSTGRES_FILE"
  without FLUX_AGE_KEY_FILE
  last_copies
  refused "the volume backups' custody file, $VOLSYNC_FILE, does not exist" "the PostgreSQL backups' custody file, $POSTGRES_FILE, does not exist" \
    "the Flux age key is missing: FLUX_AGE_KEY_FILE names no file"
  reset_environment
  volsync_custody "$MASTER"
  postgres_custody "$SSE"
  # After a seal-key rotation the OpenBao custody file written before it holds the old key alone: it
  # is refused with bao-seal-restore's reason on the lines above the recipe's own, which names each
  # seal Secret by its id. The file bao-seal-keep wrote passes.
  rotated
  secret openbao openbao-seal-2 key "${SEAL%0001}0003"
  openbao_custody "$SEAL"
  last_copies
  refused "the OpenBao custody file, $OPENBAO_FILE, does not hold the seal keys the Secrets openbao/openbao-seal-2 and openbao/openbao-seal-1 hold"
  reason="bao-seal-restore: $OPENBAO_FILE holds the seal key openbao-seal-1, and the store's current seal key is openbao-seal-2: give the custody file just bao-seal-keep wrote after the rotation, or write it with just bao-seal-keep $OPENBAO_FILE <new file>"
  above=$(grep -nxF -- "$reason" <<<"$output" | cut -d: -f1)
  own=$(grep -nxF -- "cluster-last-copies: the OpenBao custody file, $OPENBAO_FILE, does not hold the seal keys the Secrets openbao/openbao-seal-2 and openbao/openbao-seal-1 hold" <<<"$output" | cut -d: -f1)
  echo "bao-seal-restore's reason on line ${above:-none}, the recipe's own on line $own"
  [ -n "$above" ] && ((above < own))
  rotated_openbao_custody "${SEAL%0001}0003" "$SEAL"
  last_copies --check
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qxF "bao-seal-restore: the Secret openbao-seal-2 holds the key in $OPENBAO_FILE" <<<"$output"
  grep -qxF "bao-seal-restore: the Secret openbao-seal-1 holds the key in $OPENBAO_FILE" <<<"$output"
  nothing_changed
  nothing_left
}

@test "A last copy that fails, or is not newer than the run, fails the recipe naming it, and what it suspended is resumed" {
  local start began earlier
  # The snapshot job fails: no database is touched.
  : >"$STATE/job-fails.openbao-snapshots"
  last_copies
  start=$(start_of)
  failed_on openbao/openbao-snapshots "the Job openbao/last-$start-openbao-snapshots failed"
  [ "$(wc -l <"$RECORD/events")" -eq 1 ]
  # A snapshot job that uploads nothing: the newest snapshot is the earlier night's.
  again
  : >"$STATE/no-upload.openbao-snapshots"
  last_copies
  failed_on openbao/openbao-snapshots "the newest snapshot, 20261117T184300Z.snapshot.age, was not taken by this run"
  [ "$(wc -l <"$RECORD/events")" -eq 1 ]
  # A dump job that uploads nothing: the newest dump is the earlier night's.
  again
  : >"$STATE/no-upload.n8n-db-pgdump"
  last_copies
  failed_on ai-system/n8n-db "the newest dump, 20261117T020533Z.dump.age, was not taken by this run"
  [ "$(grep -v n8n-db "$RECORD/events" | grep -cv openbao)" -eq 0 ]
  # Nor is one taken earlier the same day, seconds before the run started.
  again
  : >"$STATE/no-upload.n8n-db-pgdump"
  earlier=$(date -u -d '-5 seconds' +%Y%m%dT%H%M%SZ)
  [[ ${earlier:0:8} == $(date -u +%Y%m%d) ]] || { sleep 6 && earlier=$(date -u -d '-5 seconds' +%Y%m%dT%H%M%SZ); }
  age --encrypt --recipient "$RECIPIENT" --output "$STORE/marker-prefix-postgres/lab-sto2/ai-system/n8n-db/$earlier.dump.age" "$STATE/dump.plain"
  last_copies
  failed_on ai-system/n8n-db "the newest dump, $earlier.dump.age, was not taken by this run"
  rm "$STORE/marker-prefix-postgres/lab-sto2/ai-system/n8n-db/$earlier.dump.age"
  # A dump that fails its check: here not an age file.
  again
  : >"$STATE/plain-upload.ascender-db-pgdump"
  last_copies
  failed_on ascender/ascender-db "its dump does not pass postgres-dump-check"
  grep -q '^postgres-dump-check: [0-9TZ]*\.dump\.age is not an age file$' <<<"$output"
  # The archiver never reaches the switched segment.
  again
  : >"$STATE/archiver-stuck.ai-system.n8n-db"
  with LAST_COPIES_TIMEOUT=1
  began=$SECONDS
  last_copies
  failed_on ai-system/n8n-db "the archiver did not reach 00000001000000000000002A within 1 seconds; it last archived 000000010000000000000029"
  # The wait is the one second and a poll, far below the forty seconds a longer wait would take.
  ((SECONDS - began < 40))
  reset_environment
  # An ObjectStore without a recovery window for the database.
  again
  cp "$STATE/cluster/objectstore.backstage.backstage-db.json" "$STATE/objectstore.kept"
  jq 'del(.status.serverRecoveryWindow["backstage-db"].firstRecoverabilityPoint)' "$STATE/objectstore.kept" \
    >"$STATE/cluster/objectstore.backstage.backstage-db.json"
  last_copies
  failed_on backstage/backstage-db "the ObjectStore backstage/backstage-db holds no recovery window of backstage-db with a first recoverability point and a last successful backup"
  mv "$STATE/objectstore.kept" "$STATE/cluster/objectstore.backstage.backstage-db.json"
  # Nor one whose window holds no last successful backup.
  again
  cp "$STATE/cluster/objectstore.backstage.backstage-db.json" "$STATE/objectstore.kept"
  jq 'del(.status.serverRecoveryWindow["backstage-db"].lastSuccessfulBackupTime)' "$STATE/objectstore.kept" \
    >"$STATE/cluster/objectstore.backstage.backstage-db.json"
  last_copies
  failed_on backstage/backstage-db "the ObjectStore backstage/backstage-db holds no recovery window of backstage-db with a first recoverability point and a last successful backup"
  mv "$STATE/objectstore.kept" "$STATE/cluster/objectstore.backstage.backstage-db.json"
  # A mover that ends Failed: its Kustomization is resumed, and the next volume is not touched.
  again
  : >"$STATE/mover-fails.ai-system.n8n"
  last_copies
  failed_on ai-system/n8n "its backup ended Failed"
  [ "$(grep -c 'open-webui' "$RECORD/events")" -eq 0 ]
  grep -qx 'resumed flux-system/n8n' "$RECORD/events"
  # A backup reported with the run's tag and another result than Successful.
  again
  echo Failed >"$STATE/manual-result.ai-system.open-webui"
  last_copies
  failed_on ai-system/open-webui "its backup ended Failed"
  grep -qx 'resumed flux-system/open-webui' "$RECORD/events"
  # A wait that runs out: a job that never ends, and a backup that never ends.
  again
  : >"$STATE/job-stuck.backstage-db-pgdump"
  with LAST_COPIES_TIMEOUT=1
  began=$SECONDS
  last_copies
  start=$(start_of)
  failed_on backstage/backstage-db "the Job backstage/last-$start-backstage-db-pgdump did not complete within 1 seconds"
  ((SECONDS - began < 40))
  again
  : >"$STATE/mover-stuck.ai-system.open-webui"
  began=$SECONDS
  last_copies
  failed_on ai-system/open-webui "its backup did not complete within 1 seconds"
  grep -qx 'resumed flux-system/open-webui' "$RECORD/events"
  ((SECONDS - began < 40))
  # Nor is the tag an earlier run's trigger left in status.lastManualSync taken for this run's.
  again
  echo last-1763348400 >"$STATE/last-manual.ai-system.open-webui"
  : >"$STATE/mover-stuck.ai-system.open-webui"
  began=$SECONDS
  last_copies
  failed_on ai-system/open-webui "its backup did not complete within 1 seconds"
  grep -qx 'resumed flux-system/open-webui' "$RECORD/events"
  ((SECONDS - began < 40))
  # And a backup that began before the trigger and does not end.
  again
  echo 1000 >"$STATE/syncing.ai-system.n8n"
  began=$SECONDS
  last_copies
  failed_on ai-system/n8n "a backup of it that began before the trigger did not end within 1 seconds"
  grep -qx 'resumed flux-system/n8n' "$RECORD/events"
  ((SECONDS - began < 40))
  reset_environment
  # A Kustomization that owns a volume and is suspended already, as for a restore by hand, would be
  # resumed by the run: it is named before any copy is taken, and left suspended.
  again
  : >"$STATE/suspended.flux-system.open-webui"
  last_copies
  refused "ai-system/open-webui: the Kustomization flux-system/open-webui that owns it is suspended already, and the run would resume it; end what it is suspended for and resume it first"
  [ -e "$STATE/suspended.flux-system.open-webui" ]
  rm "$STATE/suspended.flux-system.open-webui"
  # A Kustomization that cannot be resumed is named last, with the command that resumes it.
  again
  : >"$STATE/resume-fails.flux-system.n8n"
  last_copies
  echo "$output"
  [ "$status" -ne 0 ]
  [ "${lines[${#lines[@]} - 2]}" = "cluster-last-copies: the Kustomization flux-system/n8n is still suspended; resume it: flux resume kustomization n8n --namespace flux-system" ]
  [ "$(grep -c 'open-webui' "$RECORD/events")" -eq 0 ]
  [[ $output != *192.0.2.10* ]]
  nothing_left
}

@test "The last copies' check takes no copy and changes nothing" {
  local store_before
  store_before=$(find "$STORE" -type f -printf '%P %s\n' | sort)
  last_copies --check
  echo "$output"
  [ "$status" -eq 0 ]
  nothing_changed
  nothing_left
  [ "$(find "$STORE" -type f -printf '%P %s\n' | sort)" = "$store_before" ]
  [ -z "$(calls '^(rclone|docker) ')" ]
  # It reads the cluster, and compares every custody file with it.
  [ "$(calls '^kubectl ' | grep -cv '^kubectl get ')" -eq 0 ]
  grep -qxF "bao-seal-restore: the Secret openbao-seal-1 holds the key in $OPENBAO_FILE" <<<"$output"
  [ "$(calls '^kubectl get secret ' | grep -cE ' (n8n|open-webui)-volsync ')" -eq 2 ]
  [ "$(calls '^kubectl get secret ' | grep -cE ' (n8n|ascender|backstage)-db-backup ')" -eq 3 ]
  # The plan, by namespace and name, and that the check took none of it.
  expected="cluster-last-copies: the last copies of lab-sto2, in this order:
  openbao/openbao-snapshots: a snapshot, by a Job from the CronJob openbao/openbao-snapshots
  ai-system/n8n-db: a dump, by a Job from the CronJob ai-system/n8n-db-pgdump, and its WAL archived through a segment switched on ai-system/n8n-db-1
  ascender/ascender-db: a dump, by a Job from the CronJob ascender/ascender-db-pgdump, and its WAL archived through a segment switched on ascender/ascender-db-3
  backstage/backstage-db: a dump, by a Job from the CronJob backstage/backstage-db-pgdump, and its WAL archived through a segment switched on backstage/backstage-db-2
  ai-system/n8n: a backup of its volume, by its manual trigger, with the Kustomization flux-system/n8n suspended meanwhile
  ai-system/open-webui: a backup of its volume, by its manual trigger, with the Kustomization flux-system/open-webui suspended meanwhile
cluster-last-copies: --check takes none of them"
  diff <(echo "$expected") <(tail -n 8 <<<"$output")
}

@test "The last copies print no key, password, address or bucket name, and pass none as an argument" {
  local secrets=() app
  last_copies
  echo "$output"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/outputs"
  cp "$RECORD/argv" "$BATS_TEST_TMPDIR/calls"
  # Again, with kubectl's errors naming the API server's address.
  again
  : >"$STATE/noisy"
  last_copies
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"<address>"* ]]
  printf '%s\n' "$output" >>"$BATS_TEST_TMPDIR/outputs"
  cat "$RECORD/argv" >>"$BATS_TEST_TMPDIR/calls"
  # No key or password, in the clear or as the base64 a Secret holds it in, on a command line or
  # in the output.
  secrets=("$SEAL" "$(printf %s "$SEAL" | base64 -w0)" "$MASTER" "$SSE" "$(printf %s "$SSE" | base64 -w0)"
    marker-customer-key marker-state-access-key-id marker-state-secret-key marker-cluster-access-key-id
    marker-cluster-secret-key marker-recovery-share "$(grep -h '^AGE-SECRET-KEY-' "$KEY")" "$(grep -h '^AGE-SECRET-KEY-' "$FLUX_KEY")")
  for app in n8n open-webui; do
    secrets+=("$(password "$app")" "$(password "$app" | base64 -w0)")
  done
  leaked "${secrets[@]}"
  # No address, endpoint or bucket name in the output, and nothing of what the copies hold; the
  # endpoint on no command line either.
  [ "$(grep -cE 'marker-endpoint|marker-prefix|192\.0\.2\.10|marker-row|marker_table|marker-storage|marker-member|marker-address' "$BATS_TEST_TMPDIR/outputs")" -eq 0 ]
  [ "$(grep -cF -- "$ENDPOINT" "$BATS_TEST_TMPDIR/calls")" -eq 0 ]
}
