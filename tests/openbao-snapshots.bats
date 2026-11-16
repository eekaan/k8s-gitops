#!/usr/bin/env bats
# Proves the scheduled snapshots of the secret store of features/openbao-snapshots.feature, the
# CronJob of kubernetes/apps/base/openbao/openbao-snapshots/; each test that proves a scenario
# carries its title. The application is built as Flux applies it, offline, and its scripts run as its
# containers run them, with the pinned age, the recording fake S3 client of
# tests/fixtures/etcd-snapshots/rclone, whose buckets are directories, and the fake OpenBao client of
# tests/fixtures/openbao-snapshots/bao. The OpenBao chart is pulled once per run from its public
# registry to read the version of its servers; nothing reaches a cluster, the store or the object
# storage.
# Needs flux, kustomize, helm, yq, jq and age on PATH (the versions pinned for the repository).

bats_require_minimum_version 1.5.0
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

# The application the helpers build, and its Kustomization, which the helpers loaded next read.
# shellcheck disable=SC2034
JOB_APP=kubernetes/apps/base/openbao/openbao-snapshots
# shellcheck disable=SC2034
JOB_NAME=openbao-snapshots
load fixtures/etcd-snapshots/job

setup_file() {
  job_setup_file
  # Helm's cache and registry settings stay in the run's own directory, and so does the Docker
  # configuration helm falls back to for credentials, so no login is read.
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG"
}

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  BIN="$BATS_TEST_TMPDIR/bin"
  STORE="$BATS_TEST_TMPDIR/store"
  FAILS="$BATS_TEST_TMPDIR/store-fails"
  RECORD="$BATS_TEST_TMPDIR/record"
  INIT="$ROOT/kubernetes/apps/base/openbao/openbao/app/initialize"
  mkdir -p "$BIN" "$STORE" "$FAILS" "$RECORD" "$BATS_TEST_TMPDIR/plain" "$BATS_TEST_TMPDIR/out"
  cp "$ROOT/tests/fixtures/etcd-snapshots/rclone" "$BIN/rclone"
  cp "$ROOT/tests/fixtures/openbao-snapshots/bao" "$BIN/bao"
  PLAIN="$BATS_TEST_TMPDIR/plain/raft.snap"
  OUT="$BATS_TEST_TMPDIR/out"
  JOB_SCRIPTS="$BATS_TEST_TMPDIR/scripts"
  # The bucket the example key lists name, as the application builds it.
  BUCKET=example-backups-openbao
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

# snapshot_step [NAME=VALUE...]: the step that takes the snapshot, as the job runs it, against the fake
# client that knows the pod's token and the role the job asks for; each NAME=VALUE over the
# container's environment. The pod's token and the CA are files of the test's own.
snapshot_step() {
  job_build
  job_scripts "$JOB_SCRIPTS"
  printf 'marker-pod-token' > "$BATS_TEST_TMPDIR/token"
  printf 'marker-ca' > "$BATS_TEST_TMPDIR/ca.crt"
  job_env snapshot | sed -n 's/^BAO_ROLE=//p' > "$RECORD/role"
  # The step's HOME and temporary directory are in the test's own, where the check for the token
  # looks, as in the pod they are a volume that only this step mounts.
  mkdir -p "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/home-tmp"
  job_run snapshot snapshot.sh JWT_FILE="$BATS_TEST_TMPDIR/token" BAO_CACERT="$BATS_TEST_TMPDIR/ca.crt" \
    PLAIN_SNAPSHOT="$PLAIN" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/home-tmp" "$@"
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

# role_data NAME: the data of the Kubernetes auth role NAME in OpenBao's initial configuration.
role_data() {
  jq -c --arg path "auth/kubernetes/role/$1" \
    '[.initialize[] | to_entries[] | .value.request[] | to_entries[] | .value | select(.path == $path)] | .[0].data' \
    "$INIT/initialize.json"
}

@test "The snapshot job logs in as the snapshot role and can do nothing else in the store" {
  local role policy_file namespace volume tls_secret host dir account home step_output
  job_build

  # The pod runs as the one account the role binds, in the namespace the role binds, and the job is
  # built into that namespace.
  role=$(role_data snapshot)
  [ "$(jq -r '.bound_service_account_names | join(",")' <<< "$role")" = "$(job_pod_field '.serviceAccountName')" ]
  namespace=$(jq -r '.bound_service_account_namespaces | join(",")' <<< "$role")
  [ "$(yq '.spec.targetNamespace' "$JOB_TREE/$JOB_APP/ks.yaml")" = "$namespace" ]
  [ "$(yq -N 'select(.kind == "CronJob") | .metadata.namespace' "$JOB_BUILT")" = "$namespace" ]
  # It logs in as that role, and the role carries the snapshot policy alone, without OpenBao's
  # default policy.
  [ "$(job_env snapshot | sed -n 's/^BAO_ROLE=//p')" = snapshot ]
  [ "$(jq -c '.token_policies' <<< "$role")" = '["snapshot"]' ]
  [ "$(jq -r '.token_no_default_policy' <<< "$role")" = true ]
  # That policy reads the raft snapshot path and nothing else.
  policy_file=$(jq -r '[.initialize[] | to_entries[] | .value.request[] | to_entries[] | .value
    | select(.path == "sys/policies/acl/snapshot")] | .[0].data.policy.path | split("/") | last' "$INIT/initialize.json")
  [ "$(jq -cS '.path' "$INIT/$policy_file")" = '{"sys/storage/raft/snapshot":{"capabilities":["read"]}}' ]

  # The token is the pod's own, projected for the audience the role checks and for the shortest time
  # Kubernetes allows, into a volume that is not a disk, and mounted by the one step that logs in.
  [ "$(job_pod_field '.automountServiceAccountToken')" = false ]
  [ "$(job_pod_field '[.volumes[] | select(.projected.sources[]?.serviceAccountToken)] | length')" -eq 1 ]
  volume=$(job_pod_field '.volumes[] | select(.projected.sources[]?.serviceAccountToken) | .name')
  [ "$(job_pod_field ".volumes[] | select(.name == \"$volume\") | .projected.sources[0].serviceAccountToken.audience")" = "$(jq -r '.audience' <<< "$role")" ]
  [ "$(job_pod_field ".volumes[] | select(.name == \"$volume\") | .projected.sources[0].serviceAccountToken.expirationSeconds")" -le 3600 ]
  [ "$(job_pod_field "[(.initContainers + .containers)[] | select(.volumeMounts[]?.name == \"$volume\") | .name] | join(\",\")")" = snapshot ]
  [ "$(job_container snapshot ".volumeMounts[] | select(.name == \"$volume\") | .readOnly")" = true ]
  [ "$(job_env snapshot | sed -n 's/^JWT_FILE=//p')" = "$(job_container snapshot ".volumeMounts[] | select(.name == \"$volume\") | .mountPath")/token" ]
  # No volume the step mounts writable is backed by a disk: what it writes stays in memory.
  while IFS= read -r volume; do
    if [ "$(job_container snapshot ".volumeMounts[] | select(.name == \"$volume\") | .readOnly // false")" != true ]; then
      [ "$(job_pod_field ".volumes[] | select(.name == \"$volume\") | .emptyDir.medium")" = Memory ]
    fi
  done < <(job_container snapshot '.volumeMounts[].name')
  # No RoleBinding or ClusterRoleBinding in what the tree's applications build gives the account a
  # right in the cluster's API; the bindings that are there (the build holds some) are others'.
  for dir in "$ROOT"/kubernetes/apps/base/*/*/app; do
    kustomize build --load-restrictor LoadRestrictionsNone "$dir"
    echo '---'
  done > "$BATS_TEST_TMPDIR/apps.yaml"
  [ "$(yq -N 'select(.kind == "RoleBinding" or .kind == "ClusterRoleBinding") | .metadata.name' "$BATS_TEST_TMPDIR/apps.yaml" | wc -l)" -gt 0 ]
  [ "$(yq -N 'select(.kind == "RoleBinding" or .kind == "ClusterRoleBinding") | .subjects[] | select(.name == "'"$(job_pod_field '.serviceAccountName')"'") | .name' "$BATS_TEST_TMPDIR/apps.yaml" | wc -l)" -eq 0 ]
  # No other role of the Kubernetes auth method binds the account, by name or by a wildcard, in the
  # job's namespace.
  account=$(job_pod_field '.serviceAccountName')
  [ "$(jq -r --arg account "$account" --arg namespace "$namespace" '
    [.initialize[] | to_entries[] | .value.request[] | to_entries[] | .value
      | select((.path | test("^auth/kubernetes/role/")) and .path != "auth/kubernetes/role/snapshot")
      | select((.data.bound_service_account_names | index($account) or index("*"))
          and (.data.bound_service_account_namespaces | index($namespace) or index("*")))
      | .path] | length' "$INIT/initialize.json")" -eq 0 ]
  # The step's HOME is a volume of its own: a file the token could be written to there is not on a
  # volume another container mounts.
  home=$(job_env snapshot | sed -n 's/^HOME=//p')
  volume=$(job_container snapshot ".volumeMounts[] | select(.mountPath == \"$home\") | .name")
  [ -n "$volume" ]
  [ "$(job_pod_field "[(.initContainers + .containers)[] | select(.volumeMounts[]?.name == \"$volume\") | .name] | join(\",\")")" = snapshot ]

  # The client reaches the active member over TLS by a name the listener's certificate holds,
  # verified against the CA, which is the one file of the certificate's Secret the pod gets: the
  # listener's key never reaches it.
  [[ $(job_env snapshot | sed -n 's/^BAO_ADDR=//p') =~ ^https://([a-z0-9.-]+):8200$ ]]
  host=${BASH_REMATCH[1]}
  [[ $host == *-active.* ]]
  yq -N 'select(.kind == "Certificate" and .metadata.name == "openbao-tls") | .spec.dnsNames[]' "$ROOT/kubernetes/apps/base/openbao/openbao/app/tls.yaml" | grep -qxF "$host"
  tls_secret=$(yq -N 'select(.kind == "Certificate" and .metadata.name == "openbao-tls") | .spec.secretName' "$ROOT/kubernetes/apps/base/openbao/openbao/app/tls.yaml")
  [ "$(job_env snapshot | sed -n 's/^BAO_CACERT=//p' | xargs basename)" = ca.crt ]
  volume=$(job_container snapshot ".volumeMounts[] | select(.mountPath == \"$(job_env snapshot | sed -n 's/^BAO_CACERT=//p' | xargs dirname)\") | .name")
  [ -n "$volume" ]
  [ "$(job_pod_field ".volumes[] | select(.name == \"$volume\") | .secret.secretName")" = "$tls_secret" ]
  [ "$(job_pod_field ".volumes[] | select(.name == \"$volume\") | .secret.items | map(.key + \":\" + .path) | join(\",\")")" = ca.crt:ca.crt ]
  run ! grep -Ei 'skip|insecure' <<< "$(job_env snapshot)"
  run ! grep -Ei 'skip.?verify|insecure|-tls-' "$JOB_SCRIPTS/snapshot.sh"

  # Run as the container runs it, the script makes two calls, to log in as the role with the pod's
  # token and to save the snapshot with the token it was given, and no other.
  snapshot_step
  [ "$status" -eq 0 ]
  # The step's own output, both streams, before the next run replaces it.
  step_output=$output
  [ "$(cat "$RECORD/argv")" = "$(printf '%s\n' "bao write -field=token auth/kubernetes/login role=snapshot jwt=@$BATS_TEST_TMPDIR/token" "bao operator raft snapshot save $PLAIN")" ]
  grep -q '^marker-snapshot-content ' "$PLAIN"
  # The token is in the second call's environment alone, and in no argument, output or file.
  run ! grep -qz '^BAO_TOKEN=' "$RECORD/env.bao.1"
  grep -qz '^BAO_TOKEN=marker-bao-token$' "$RECORD/env.bao.2"
  [[ $step_output != *marker-* ]]
  run ! grep -q 'marker-' "$RECORD/argv"
  run ! grep -rl 'marker-bao-token' "$BATS_TEST_TMPDIR" --exclude-dir=record --exclude-dir=scripts --exclude-dir=bin
  # A role the pod's token is not bound to, or a listener the CA did not sign, ends the step without
  # a snapshot and without a second call.
  rm -f "$PLAIN" "$RECORD/argv" "$RECORD"/env.bao.*
  snapshot_step BAO_ROLE=operator
  [ "$status" -ne 0 ]
  [ ! -e "$PLAIN" ]
  [ "$(grep -c . "$RECORD/argv")" -eq 1 ]
  : > "$FAILS/tls"
  rm -f "$RECORD/argv" "$RECORD"/env.bao.*
  snapshot_step
  [ "$status" -ne 0 ]
  [ ! -e "$PLAIN" ]
}

@test "The job uploads only an encrypted snapshot of the raft storage, named as the etcd snapshots are" {
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
  run ! grep -q 'raft.snap\|plain' "$RECORD/argv"
  run ! grep -aq 'marker-snapshot-content' "$STORE/${objects[0]}"
  # The key reaches the client in its environment, never its arguments.
  grep -qz '^RCLONE_CONFIG_STORE_ACCESS_KEY_ID=marker-secret-AWS_ACCESS_KEY_ID$' "$RECORD/env.rclone.1"
  run ! grep -q 'marker-secret' "$RECORD/argv"
  # Encrypted to the recipient the operator's recipe encrypts to, and to it alone: the file's header
  # holds one recipient.
  [ "$(job_env encrypt | sed -n 's/^AGE_RECIPIENT=//p')" = "$(yq '.creation_rules[0].age' "$ROOT/talos/.sops.yaml")" ]
  [ "$(sed '/^--- /q' "$STORE/${objects[0]}" | grep -c '^-> ')" -eq 1 ]
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

  # The client's output file and the encrypting step's input are one path, directly under the mount
  # of the Memory volume "plain", in both containers that mount it.
  plain_mount=$(job_container snapshot '.volumeMounts[] | select(.name == "plain") | .mountPath')
  [ -n "$plain_mount" ]
  [ "$(job_container encrypt '.volumeMounts[] | select(.name == "plain") | .mountPath')" = "$plain_mount" ]
  written=$(job_env snapshot | sed -n 's/^PLAIN_SNAPSHOT=//p')
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

@test "the encrypting step refuses a missing snapshot and the upload a file that is not a snapshot's, and never replaces an object" {
  encrypt_and_upload
  [ "$status" -eq 0 ]
  name=$(find "$OUT" -type f -printf '%f\n')

  # The client is told never to modify an object that is there.
  grep -q -- '--immutable' <<< "$(grep '^rclone copyto ' "$RECORD/argv" | tail -n 1)"
  [ -f "$STORE/$BUCKET/$CLUSTER_NAME/$name" ]
  # The file the upload is handed is the only one in its directory, named as a snapshot.
  mv "$OUT/$name" "$OUT/raft.snap"
  job_run upload upload.sh OUT_DIR="$OUT"
  [ "$status" -ne 0 ]
  [ ! -e "$STORE/$BUCKET/$CLUSTER_NAME/raft.snap" ]
  # Nothing to encrypt, nothing uploaded.
  rm -f "$OUT/raft.snap" "$PLAIN"
  job_run encrypt encrypt.sh PLAIN_SNAPSHOT="$PLAIN" OUT_DIR="$OUT" AGE="$(command -v age)" AGE_RECIPIENT="$RECIPIENT"
  [ "$status" -ne 0 ]
  [ -z "$(ls "$OUT")" ]
}

@test "the job keeps the newest snapshots and deletes no other object" {
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
  # Two weeks of the six-hourly schedule, as the etcd snapshots keep.
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

@test "The job's OpenBao client is the cluster's OpenBao version" {
  local url tag pulled image
  job_build
  url=$(yq -N '.spec.url' "$ROOT/kubernetes/apps/base/openbao/openbao/app/ocirepository.yaml")
  tag=$(yq -N '.spec.ref.tag' "$ROOT/kubernetes/apps/base/openbao/openbao/app/ocirepository.yaml")
  pulled="$BATS_FILE_TMPDIR/chart/$tag"
  if [ ! -d "$pulled" ]; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  # The servers' image as the chart renders it with the repository's values.
  helm template openbao "$(echo "$pulled"/*.tgz)" --namespace openbao --kube-version "$(yq '.kubernetes' "$ROOT/versions.yaml")" \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor \
    --values "$ROOT/kubernetes/apps/base/openbao/openbao/app/values.yaml" > "$BATS_TEST_TMPDIR/rendered.yaml"
  server=$(yq -N 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "openbao") | .image' "$BATS_TEST_TMPDIR/rendered.yaml")
  [[ $server =~ ^[a-z0-9./-]+:[0-9]+\.[0-9]+\.[0-9]+$ ]]

  image=$(job_container snapshot '.image')
  [[ $image =~ ^([a-z0-9./-]+:[A-Za-z0-9._-]+)@sha256:[0-9a-f]{64}$ ]]
  [ "${BASH_REMATCH[1]}" = "$server" ]
  # Every image of the job is pinned by tag and digest.
  while IFS= read -r image; do
    [[ $image =~ ^[a-z0-9./-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]]
  done < <(job_pod_field '(.initContainers + .containers)[] | .image')
}

@test "The S3 key reaches the OpenBao snapshot job from the secret store and is nowhere in the tree" {
  job_build

  # An ExternalSecret reads the two properties of the cluster's key from the store's key volsync,
  # and nothing else of it, into the Secret the job reads.
  [ "$(yq -N 'select(.kind == "ExternalSecret") | .spec.secretStoreRef.name' "$JOB_BUILT")" = openbao ]
  properties=$(yq -N 'select(.kind == "ExternalSecret") | .spec.data[].remoteRef | .key + ":" + .property' "$JOB_BUILT" | sort | paste -sd,)
  [ "$properties" = "volsync:AWS_ACCESS_KEY_ID,volsync:AWS_SECRET_ACCESS_KEY" ]
  [ "$(yq -N 'select(.kind == "ExternalSecret") | (.spec.dataFrom // []) | length' "$JOB_BUILT")" -eq 0 ]
  secret=$(yq -N 'select(.kind == "ExternalSecret") | .spec.target.name' "$JOB_BUILT")
  # Only the uploading container takes it, as environment variables from that Secret; no other
  # container names it, one key at a time or whole through envFrom.
  [ "$(job_pod_field '[(.initContainers + .containers)[] | select(.env[]?.valueFrom.secretKeyRef.name == "'"$secret"'") | .name] | join(",")')" = upload ]
  [ -z "$(job_pod_field '(.initContainers + .containers)[] | select(.name != "upload") | select(.envFrom[]?.secretRef.name == "'"$secret"'") | .name')" ]
  [ "$(job_pod_field '[.volumes[]? | select(.secret.secretName == "'"$secret"'")] | length')" -eq 0 ]
  # No literal value of an environment variable holds a key, and nothing in the application's files
  # does either: the values the tree holds are names.
  [ -z "$(job_pod_field '(.initContainers + .containers)[] | .env[]? | select(.name | test("SECRET|ACCESS_KEY|TOKEN|PASSWORD")) | select(.value != null) | .name')" ]
  run ! grep -rEi '(secret_access_key|access_key_id|AWS_SECRET)[^A-Za-z_]*[:=] *["'\'']?[A-Za-z0-9/+]{16,}' "$ROOT/kubernetes/apps/base/openbao/openbao-snapshots"
  # The step that logs in to OpenBao holds neither the key nor the S3 client's settings.
  [ -z "$(job_container snapshot '.env[]? | select(.name | test("RCLONE|AWS")) | .name')" ]
}

@test "A cluster that does not select the OpenBao snapshot job builds none of it" {
  overlay=kubernetes/apps/overlays/lab-sto2
  cp -R "$ROOT/kubernetes" "$BATS_TEST_TMPDIR/kubernetes"
  cd "$BATS_TEST_TMPDIR"

  kustomize build --load-restrictor LoadRestrictionsNone "$overlay" > selected.yaml

  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "openbao-snapshots") | .metadata.name' selected.yaml)" = openbao-snapshots ]
  # It waits for the store, its ClusterSecretStore, External Secrets and the monitoring definitions.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "openbao-snapshots") | .spec.dependsOn[].name' selected.yaml | sort | paste -sd,)" = external-secrets,openbao,openbao-store,prometheus-operator-crds ]

  sed -i '/openbao-snapshots/d' "$overlay/kustomization.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "$overlay" > left-out.yaml

  [ -s left-out.yaml ]
  run ! grep -q 'openbao-snapshots' left-out.yaml
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
  # The release is the pinned age's, and the checksums are the etcd snapshot job's for the same release.
  [ "$(job_env fetch-age | sed -n 's/^AGE_VERSION=//p')" = "$(sed -n 's/^age = "\(.*\)"$/\1/p' "$ROOT/mise.toml")" ]
  [ "$(job_env fetch-age | sort)" = "$(yq -N 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.initContainers[] | select(.name == "fetch-age") | .env[] | .name + "=" + .value' \
    "$ROOT/kubernetes/apps/base/etcd-snapshots/etcd-snapshots/app/cronjob.yaml" | sort)" ]
}

@test "the recipient the job encrypts to is the Talos age key's, which the etcd snapshot job's is too" {
  job_build

  [ "$(yq '.spec.postBuild.substitute.OPENBAO_SNAPSHOT_AGE_RECIPIENT' "$JOB_TREE/$JOB_APP/ks.yaml")" = "$(yq '.creation_rules[0].age' "$ROOT/talos/.sops.yaml")" ]
  [ "$(yq '.spec.postBuild.substitute.OPENBAO_SNAPSHOT_AGE_RECIPIENT' "$JOB_TREE/$JOB_APP/ks.yaml")" = "$(yq '.spec.postBuild.substitute.ETCD_SNAPSHOT_AGE_RECIPIENT' "$ROOT/kubernetes/apps/base/etcd-snapshots/etcd-snapshots/ks.yaml")" ]
  [ "$(job_env encrypt | sed -n 's/^AGE_RECIPIENT=//p')" = "$(yq '.creation_rules[0].age' "$ROOT/talos/.sops.yaml")" ]
  # The step that encrypts gets only the recipient, the public half: no key of any kind.
  [ -z "$(job_container encrypt '.env[]? | select(.name | test("KEY|IDENTITY|SECRET")) | .name')" ]
}

@test "the job runs every six hours at a minute of its own, never two at once, with a deadline, and holds no credential of the cluster's API" {
  job_build

  schedule=$(yq -N 'select(.kind == "CronJob") | .spec.schedule' "$JOB_BUILT")
  [[ $schedule =~ ^[0-9]+\ \*/6\ \*\ \*\ \*$ ]]
  # Its minute is not the etcd snapshot job's, read from that job's CronJob.
  etcd_schedule=$(yq -N 'select(.kind == "CronJob") | .spec.schedule' "$ROOT/kubernetes/apps/base/etcd-snapshots/etcd-snapshots/app/cronjob.yaml")
  [[ $etcd_schedule =~ ^[0-9]+\  ]]
  [ "${schedule%% *}" != "${etcd_schedule%% *}" ]
  [ "$(yq -N 'select(.kind == "CronJob") | .spec.concurrencyPolicy' "$JOB_BUILT")" = Forbid ]
  [[ $(yq -N 'select(.kind == "CronJob") | .spec.jobTemplate.spec.activeDeadlineSeconds' "$JOB_BUILT") =~ ^[1-9][0-9]*$ ]]
  [[ $(yq -N 'select(.kind == "CronJob") | .spec.startingDeadlineSeconds' "$JOB_BUILT") =~ ^[1-9][0-9]*$ ]]
  [ "$(yq -N 'select(.kind == "CronJob") | .spec.jobTemplate.spec.backoffLimit' "$JOB_BUILT")" -le 2 ]
  [ "$(yq -N 'select(.kind == "CronJob") | .spec.successfulJobsHistoryLimit' "$JOB_BUILT")" -ge 1 ]
  [ "$(yq -N 'select(.kind == "CronJob") | .spec.failedJobsHistoryLimit' "$JOB_BUILT")" -ge 1 ]
  # No token for the cluster's API, whose audience the account's projected token does not have, and
  # no way onto a control plane.
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
