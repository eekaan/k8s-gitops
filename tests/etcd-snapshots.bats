#!/usr/bin/env bats
# Proves the scheduled etcd snapshots of features/etcd-snapshots.feature, the CronJob of
# kubernetes/apps/base/etcd-snapshots/; each test that proves a scenario carries its title. The
# application is built as Flux applies it, offline, and its scripts run as its containers run them,
# with the pinned age and the recording fake S3 client of tests/fixtures/etcd-snapshots/rclone,
# whose buckets are directories. Nothing reaches a node, a cluster or the object storage.
# Needs flux, kustomize, yq, jq and age on PATH (the versions pinned for the repository).

bats_require_minimum_version 1.5.0
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

load fixtures/etcd-snapshots/job

setup_file() {
  job_setup_file
}

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  BIN="$BATS_TEST_TMPDIR/bin"
  STORE="$BATS_TEST_TMPDIR/store"
  FAILS="$BATS_TEST_TMPDIR/store-fails"
  RECORD="$BATS_TEST_TMPDIR/record"
  mkdir -p "$BIN" "$STORE" "$FAILS" "$RECORD" "$BATS_TEST_TMPDIR/plain" "$BATS_TEST_TMPDIR/out"
  cp "$ROOT/tests/fixtures/etcd-snapshots/rclone" "$BIN/rclone"
  PLAIN="$BATS_TEST_TMPDIR/plain/etcd.db"
  OUT="$BATS_TEST_TMPDIR/out"
  JOB_SCRIPTS="$BATS_TEST_TMPDIR/scripts"
  # The buckets the example key lists name, as the application builds them.
  BUCKET=example-backups-etcd
  CLUSTER_NAME=lab-sto2
  # The bucket exists: the upload never creates it.
  mkdir -p "$STORE/$BUCKET"
  AGEKEY="$BATS_TEST_TMPDIR/job.agekey"
  age-keygen -o "$AGEKEY" 2> /dev/null
  RECIPIENT=$(age-keygen -y "$AGEKEY")
  # The name of a snapshot as the operator's recipes list it: scripts/lib/s3.sh, the one source.
  NAME_RE=$(sed -n "s/^s3_snapshot_name_re='\\(.*\\)'\$/\\1/p" "$ROOT/scripts/lib/s3.sh")
  [ -n "$NAME_RE" ]
}

# encrypt_and_upload: the two steps of the job that touch the snapshot, in the order the job runs
# them, on a plain snapshot of marker content.
encrypt_and_upload() {
  printf 'marker-snapshot-content %s\n\001\002binary tail\n' "$RANDOM$RANDOM" > "$PLAIN"
  job_build
  job_scripts "$JOB_SCRIPTS"
  job_run encrypt encrypt.sh PLAIN_SNAPSHOT="$PLAIN" OUT_DIR="$OUT" AGE="$(command -v age)" AGE_RECIPIENT="$RECIPIENT"
  [ "$status" -eq 0 ]
  job_run upload upload.sh OUT_DIR="$OUT"
}

@test "The job uploads only an encrypted snapshot, named as the operator's recipe names its own" {
  encrypt_and_upload

  [ "$status" -eq 0 ]
  # The plain snapshot is gone before the upload starts, and the upload is handed one file.
  [ ! -e "$PLAIN" ]
  mapfile -t handed < <(find "$OUT" -type f -printf '%f\n')
  [ "${#handed[@]}" -eq 1 ]
  [[ ${handed[0]} =~ $NAME_RE ]]
  mapfile -t objects < <(find "$STORE" -type f -printf '%P\n')
  [ "${#objects[@]}" -eq 1 ]
  [ "${objects[0]}" = "$BUCKET/$CLUSTER_NAME/${handed[0]}" ]
  [ "$(head -n 1 "$STORE/${objects[0]}")" = age-encryption.org/v1 ]
  age -d -i "$AGEKEY" "$STORE/${objects[0]}" | grep -q '^marker-snapshot-content '
  # No call hands the S3 client the plain snapshot's path, and no word of its content is uploaded.
  [ "$(grep -c '^rclone copyto ' "$RECORD/argv")" -eq 1 ]
  [[ $(grep '^rclone copyto ' "$RECORD/argv") == *" $OUT/${handed[0]} store:$BUCKET/$CLUSTER_NAME/${handed[0]}" ]]
  run ! grep -q 'etcd.db\|plain' "$RECORD/argv"
  run ! grep -aq 'marker-snapshot-content' "$STORE/${objects[0]}"
  # The key reaches the client in its environment, never its arguments.
  grep -qz '^RCLONE_CONFIG_STORE_ACCESS_KEY_ID=marker-secret-AWS_ACCESS_KEY_ID$' "$RECORD/env.rclone.1"
  run ! grep -q 'marker-secret' "$RECORD/argv"
  # Encrypted to the recipient the operator's recipe encrypts to.
  [ "$(job_env encrypt | sed -n 's/^AGE_RECIPIENT=//p')" = "$(yq '.creation_rules[0].age' "$ROOT/talos/.sops.yaml")" ]
  # The addressing style is the one the operator's recipes read from the backend settings.
  [ "$(job_env upload | sed -n 's/^RCLONE_CONFIG_STORE_FORCE_PATH_STYLE=//p')" = "$(sed -n 's/^use_path_style *= *//p' "$ROOT/infra/openstack/backend.hcl")" ]
  # The cluster is the one whose directory the operator's recipes name.
  [ -d "$ROOT/kubernetes/clusters/$CLUSTER_NAME" ]
  [ -d "$ROOT/talos/$CLUSTER_NAME" ]
  # The plain snapshot lives in a sized, memory-backed volume only the snapshot and the encrypting
  # step mount; the uploading container sees the encrypted file's volume alone.
  [ "$(job_pod_field '.volumes[] | select(.name == "plain") | .emptyDir.medium')" = Memory ]
  [[ $(job_pod_field '.volumes[] | select(.name == "plain") | .emptyDir.sizeLimit') =~ ^[1-9][0-9]*(Mi|Gi)$ ]]
  [ "$(job_container snapshot '.volumeMounts[].name' | grep -c '^plain$')" -eq 1 ]
  [ "$(job_container encrypt '.volumeMounts[].name' | grep -c '^plain$')" -eq 1 ]
  [ "$(job_container upload '.volumeMounts[].name' | grep -c '^plain$')" -eq 0 ]
}

@test "the plain snapshot is written to the memory-backed volume and the encrypted file to the disk-backed one" {
  job_build

  # talosctl's output file and the encrypting step's input are one path, directly under the mount of
  # the Memory volume "plain", in both containers that mount it.
  plain_mount=$(job_container snapshot '.volumeMounts[] | select(.name == "plain") | .mountPath')
  [ -n "$plain_mount" ]
  [ "$(job_container encrypt '.volumeMounts[] | select(.name == "plain") | .mountPath')" = "$plain_mount" ]
  written=$(job_container snapshot '.args[-1]')
  [ "$(dirname "$written")" = "$plain_mount" ]
  [ "$(job_env encrypt | sed -n 's/^PLAIN_SNAPSHOT=//p')" = "$written" ]
  [ "$(job_pod_field '.volumes[] | select(.name == "plain") | .emptyDir.medium')" = Memory ]
  # What the upload is handed is the encrypting step's output directory, the mount of "out", which
  # is not memory-backed and which the snapshot step does not mount.
  out_mount=$(job_container encrypt '.volumeMounts[] | select(.name == "out") | .mountPath')
  [ -n "$out_mount" ]
  [ "$out_mount" != "$plain_mount" ]
  [ "$(job_env encrypt | sed -n 's/^OUT_DIR=//p')" = "$out_mount" ]
  [ "$(job_env upload | sed -n 's/^OUT_DIR=//p')" = "$out_mount" ]
  [ "$(job_container upload '.volumeMounts[] | select(.name == "out") | .mountPath')" = "$out_mount" ]
  [ "$(job_container snapshot '.volumeMounts[].name' | grep -c '^out$')" -eq 0 ]
  [ "$(job_pod_field '.volumes[] | select(.name == "out") | .emptyDir.medium // "disk"')" = disk ]
}

@test "the upload refuses a file that is not a snapshot's, and never replaces an object" {
  encrypt_and_upload
  [ "$status" -eq 0 ]
  name=$(find "$OUT" -type f -printf '%f\n')

  # The client is told never to modify an object that is there.
  grep -q -- '--immutable' <<< "$(grep '^rclone copyto ' "$RECORD/argv" | tail -n 1)"
  [ -f "$STORE/$BUCKET/$CLUSTER_NAME/$name" ]
  # The file the upload is handed is the only one in its directory, named as a snapshot.
  mv "$OUT/$name" "$OUT/etcd.db"
  job_run upload upload.sh OUT_DIR="$OUT"
  [ "$status" -ne 0 ]
  [ ! -e "$STORE/$BUCKET/$CLUSTER_NAME/etcd.db" ]
}

@test "The job keeps the newest snapshots and deletes no other object" {
  mkdir -p "$STORE/$BUCKET/$CLUSTER_NAME/old" "$STORE/$BUCKET/other"
  # Sixty snapshots, one a day, the oldest first; and objects that are none of the job's.
  for day in $(seq 1 60); do
    printf x > "$STORE/$BUCKET/$CLUSTER_NAME/$(printf '2026%02d%02dT000000Z' $(((day - 1) / 28 + 1)) $(((day - 1) % 28 + 1))).snapshot.age"
  done
  printf x > "$STORE/$BUCKET/$CLUSTER_NAME/notes.txt"
  printf x > "$STORE/$BUCKET/$CLUSTER_NAME/old/20250101T000000Z.snapshot.age"
  printf x > "$STORE/$BUCKET/other/20250101T000000Z.snapshot.age"
  encrypt_and_upload

  [ "$status" -eq 0 ]
  keep=$(job_env upload | sed -n 's/^KEEP_SNAPSHOTS=//p')
  # Two weeks of the six-hourly schedule, as docs/cluster.md and the restore runbook promise.
  [ "$keep" -eq 56 ]
  mapfile -t kept < <(find "$STORE/$BUCKET/$CLUSTER_NAME" -maxdepth 1 -type f -printf '%f\n' | grep -E "$NAME_RE")
  [ "${#kept[@]}" -eq "$keep" ]
  # The new snapshot is among them, and what went was the oldest.
  new=$(find "$OUT" -type f -printf '%f\n')
  [ -f "$STORE/$BUCKET/$CLUSTER_NAME/$new" ]
  [ ! -e "$STORE/$BUCKET/$CLUSTER_NAME/20260101T000000Z.snapshot.age" ]
  [ -f "$STORE/$BUCKET/$CLUSTER_NAME/notes.txt" ]
  [ -f "$STORE/$BUCKET/$CLUSTER_NAME/old/20250101T000000Z.snapshot.age" ]
  [ -f "$STORE/$BUCKET/other/20250101T000000Z.snapshot.age" ]
  # Only after the new snapshot was listed, and only snapshots of the cluster's prefix.
  [ "$(grep -n '^rclone lsf ' "$RECORD/argv" | head -n 1 | cut -d: -f1)" -lt "$(grep -n '^rclone deletefile ' "$RECORD/argv" | head -n 1 | cut -d: -f1)" ]
  while read -r _ _ target; do
    [[ $target == "store:$BUCKET/$CLUSTER_NAME/"* ]]
    [[ ${target##*/} =~ $NAME_RE ]]
  done < <(grep '^rclone deletefile ' "$RECORD/argv")
  [ "$(grep -c '^rclone deletefile ' "$RECORD/argv")" -eq $((61 - keep)) ]
}

@test "a snapshot the job cannot find listed again deletes nothing" {
  mkdir -p "$STORE/$BUCKET/$CLUSTER_NAME"
  for day in $(seq 1 60); do
    printf x > "$STORE/$BUCKET/$CLUSTER_NAME/$(printf '20260101T0000%02dZ' "$day").snapshot.age"
  done
  : > "$FAILS/list"

  encrypt_and_upload

  [ "$status" -ne 0 ]
  [ -z "$(grep '^rclone deletefile ' "$RECORD/argv" || true)" ]
  [ "$(find "$STORE/$BUCKET/$CLUSTER_NAME" -type f | wc -l)" -eq 61 ]
}

@test "The job's Talos tool is the cluster's Talos version" {
  job_build

  image=$(job_container snapshot '.image')
  [[ $image =~ ^ghcr\.io/siderolabs/talosctl:(v[0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$ ]]
  [ "${BASH_REMATCH[1]}" = "$(yq '.talos' "$ROOT/versions.yaml")" ]
  [ "${BASH_REMATCH[1]}" = "v$(sed -n 's/^talosctl = "\(.*\)"$/\1/p' "$ROOT/mise.toml")" ]
  # Every image of the job is pinned by tag and digest.
  while IFS= read -r image; do
    [[ $image =~ ^[a-z0-9./-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]]
  done < <(job_pod_field '(.initContainers + .containers)[] | .image')
}

@test "The S3 key reaches the job from the secret store and is nowhere in the tree" {
  job_build

  # An ExternalSecret reads the two properties of the cluster's key from the store's key volsync,
  # and nothing else of it, into the Secret the job reads.
  [ "$(yq -N 'select(.kind == "ExternalSecret") | .spec.secretStoreRef.name' "$JOB_BUILT")" = openbao ]
  properties=$(yq -N 'select(.kind == "ExternalSecret") | .spec.data[].remoteRef | .key + ":" + .property' "$JOB_BUILT" | sort | paste -sd,)
  [ "$properties" = "volsync:AWS_ACCESS_KEY_ID,volsync:AWS_SECRET_ACCESS_KEY" ]
  [ "$(yq -N 'select(.kind == "ExternalSecret") | (.spec.dataFrom // []) | length' "$JOB_BUILT")" -eq 0 ]
  secret=$(yq -N 'select(.kind == "ExternalSecret") | .spec.target.name' "$JOB_BUILT")
  # Only the uploading container takes it, as environment variables from that Secret.
  [ "$(job_pod_field '[(.initContainers + .containers)[] | select(.env[]?.valueFrom.secretKeyRef.name == "'"$secret"'") | .name] | join(",")')" = upload ]
  [ "$(job_pod_field '[.volumes[]? | select(.secret.secretName == "'"$secret"'")] | length')" -eq 0 ]
  # No literal value of an environment variable holds a key, and nothing in the application's files
  # does either: the values the tree holds are names.
  [ -z "$(job_pod_field '(.initContainers + .containers)[] | .env[]? | select(.name | test("SECRET|ACCESS_KEY|TOKEN|PASSWORD")) | select(.value != null) | .name')" ]
  run ! grep -rEi '(secret_access_key|access_key_id|AWS_SECRET)[^A-Za-z_]*[:=] *["'\'']?[A-Za-z0-9/+]{16,}' "$ROOT/kubernetes/apps/base/etcd-snapshots"
  # No other container reads the Talos grant's Secret.
  [ "$(job_pod_field '[(.initContainers + .containers)[] | select(.volumeMounts[]?.mountPath == "/var/run/secrets/talos.dev") | .name] | join(",")')" = snapshot ]
}

@test "A cluster that does not select the job builds none of it" {
  overlay=kubernetes/apps/overlays/lab-sto2
  cp -R "$ROOT/kubernetes" "$BATS_TEST_TMPDIR/kubernetes"
  cd "$BATS_TEST_TMPDIR"

  kustomize build --load-restrictor LoadRestrictionsNone "$overlay" > selected.yaml

  [ "$(yq -N 'select(.kind == "Namespace" and .metadata.name == "etcd-snapshots") | .metadata.name' selected.yaml)" = etcd-snapshots ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "etcd-snapshots") | .metadata.name' selected.yaml)" = etcd-snapshots ]
  # It waits for the secret store it reads the S3 key from.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "etcd-snapshots") | .spec.dependsOn[].name' selected.yaml | sort | paste -sd,)" = external-secrets,openbao-store,prometheus-operator-crds ]

  sed -i '/etcd-snapshots/d' "$overlay/kustomization.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "$overlay" > left-out.yaml

  [ -s left-out.yaml ]
  run ! grep -q 'etcd-snapshots' left-out.yaml
}

@test "the job's fetch of age refuses an archive whose checksum differs" {
  job_build
  job_scripts "$JOB_SCRIPTS"
  # The release archive as a fake wget serves it: age's own directory with an age that says so.
  mkdir -p "$BATS_TEST_TMPDIR/release/age" "$BATS_TEST_TMPDIR/tools"
  printf '#!/bin/sh\necho marker-age\n' > "$BATS_TEST_TMPDIR/release/age/age"
  chmod +x "$BATS_TEST_TMPDIR/release/age/age"
  tar -czf "$BATS_TEST_TMPDIR/release.tgz" -C "$BATS_TEST_TMPDIR/release" age
  { echo '#!/bin/sh'; echo "while [ \$# -gt 0 ]; do [ \"\$1\" = -O ] && out=\$2; shift; done"; echo "cp $BATS_TEST_TMPDIR/release.tgz \"\$out\""; } > "$BIN/wget"
  chmod +x "$BIN/wget"
  sum=$(sha256sum "$BATS_TEST_TMPDIR/release.tgz" | cut -d' ' -f1)

  job_run fetch-age fetch-age.sh TOOLS_DIR="$BATS_TEST_TMPDIR/tools" AGE_SHA256_AMD64="$sum" AGE_SHA256_ARM64="$sum"

  [ "$status" -eq 0 ]
  [ "$("$BATS_TEST_TMPDIR/tools/age/age")" = marker-age ]

  rm -rf "$BATS_TEST_TMPDIR/tools"
  mkdir "$BATS_TEST_TMPDIR/tools"
  job_run fetch-age fetch-age.sh TOOLS_DIR="$BATS_TEST_TMPDIR/tools" AGE_SHA256_AMD64="${sum//[0-9a-f]/0}" AGE_SHA256_ARM64="${sum//[0-9a-f]/0}"

  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/tools/age/age" ]
  # The release is the pinned age's.
  [ "$(job_env fetch-age | sed -n 's/^AGE_VERSION=//p')" = "$(sed -n 's/^age = "\(.*\)"$/\1/p' "$ROOT/mise.toml")" ]
}

@test "the job runs every six hours, never two at once, with a deadline, and holds no cluster credential" {
  job_build

  [ "$(yq -N 'select(.kind == "CronJob") | .spec.schedule' "$JOB_BUILT")" = '17 */6 * * *' ]
  [ "$(yq -N 'select(.kind == "CronJob") | .spec.concurrencyPolicy' "$JOB_BUILT")" = Forbid ]
  [[ $(yq -N 'select(.kind == "CronJob") | .spec.jobTemplate.spec.activeDeadlineSeconds' "$JOB_BUILT") =~ ^[1-9][0-9]*$ ]]
  [[ $(yq -N 'select(.kind == "CronJob") | .spec.startingDeadlineSeconds' "$JOB_BUILT") =~ ^[1-9][0-9]*$ ]]
  [ "$(yq -N 'select(.kind == "CronJob") | .spec.jobTemplate.spec.backoffLimit' "$JOB_BUILT")" -le 2 ]
  [ "$(yq -N 'select(.kind == "CronJob") | .spec.successfulJobsHistoryLimit' "$JOB_BUILT")" -ge 1 ]
  [ "$(yq -N 'select(.kind == "CronJob") | .spec.failedJobsHistoryLimit' "$JOB_BUILT")" -ge 1 ]
  # No Kubernetes token, and no way onto a control plane: the pod runs on a worker, from which the
  # nodes' firewall admits it to the Talos API (docs/cluster.md).
  [ "$(job_pod_field '.automountServiceAccountToken')" = false ]
  [ "$(job_pod_field '.tolerations // [] | length')" -eq 0 ]
  while IFS= read -r name; do
    [ "$(job_container "$name" '.securityContext.allowPrivilegeEscalation')" = false ]
    [ "$(job_container "$name" '.securityContext.runAsNonRoot')" = true ]
    [ "$(job_container "$name" '.securityContext.capabilities.drop | join(",")')" = ALL ]
    [ "$(job_container "$name" '.securityContext.readOnlyRootFilesystem')" = true ]
    [ "$(job_container "$name" '.securityContext.seccompProfile.type')" = RuntimeDefault ]
    [ -n "$(job_container "$name" '.resources.requests.memory')" ]
    [ -n "$(job_container "$name" '.resources.limits.memory')" ]
  done < <(job_pod_field '(.initContainers + .containers)[] | .name')
}
