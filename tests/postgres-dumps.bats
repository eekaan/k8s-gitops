#!/usr/bin/env bats
# Proves the daily dumps of features/postgresql.feature, the CronJob the component
# kubernetes/components/cnpg-cluster adds for every cluster made from it; each test that proves a
# scenario carries its title. An application that takes a cluster from the component is built as
# Flux applies it, offline, and the job's scripts run as its containers run them, with the pinned age
# and the recording stand-ins of tests/fixtures/postgres-dumps (pg_dump, pg_isready, sleep) and of
# tests/fixtures/etcd-snapshots/rclone, whose buckets are directories. Nothing reaches a cluster, a
# database or the object storage.
# Needs flux, kustomize, yq, jq and age on PATH (the versions pinned for the repository).

bats_require_minimum_version 1.5.0
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

# The job's steps, in the order the pod runs them: the three init containers, then the container
# that uploads.
steps=(fetch-age dump encrypt upload)

setup_file() {
  # flux build rewrites the kustomization.yaml of what it builds while it runs, so every build reads
  # a copy of kubernetes/, never this checkout, and the applications are written into that copy.
  export TREE=$BATS_FILE_TMPDIR/tree
  mkdir -p "$TREE"
  cp -R "$BATS_TEST_DIRNAME/../kubernetes" "$TREE/kubernetes"
}

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  CLUSTER_DIR=$TREE/kubernetes/clusters/lab-sto2
  COMPONENT=kubernetes/components/cnpg-cluster
  BIN=$BATS_TEST_TMPDIR/bin
  STORE=$BATS_TEST_TMPDIR/store
  FAILS=$BATS_TEST_TMPDIR/store-fails
  RECORD=$BATS_TEST_TMPDIR/record
  mkdir -p "$BIN" "$STORE" "$FAILS" "$RECORD"
  cp "$ROOT/tests/fixtures/etcd-snapshots/rclone" "$BIN/rclone"
  cp "$ROOT/tests/fixtures/postgres-dumps/pg_dump" "$ROOT/tests/fixtures/postgres-dumps/pg_isready" \
    "$ROOT/tests/fixtures/postgres-dumps/sleep" "$BIN/"
  # The bucket the example cluster configuration names; it exists, as the upload never creates it.
  BUCKET=example-backups-postgres
  mkdir -p "$STORE/$BUCKET"
  AGEKEY=$BATS_TEST_TMPDIR/job.agekey
  age-keygen -o "$AGEKEY" 2> /dev/null
  RECIPIENT=$(age-keygen -y "$AGEKEY")
  # The name of a dump as the upload lists it.
  NAME_RE='^[0-9]{8}T[0-9]{6}Z\.dump\.age$'
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG=$BATS_TEST_TMPDIR/no-kubeconfig
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# database NAMESPACE APP NAME: writes into the copy an application APP in NAMESPACE that has no
# manifests of its own and takes a cluster named NAME from the component, with the ks.yaml
# docs/kubernetes.md gives for it, and builds it as Flux applies it, with the example cluster
# configuration's values and Flux's strict substitution. Writes $BATS_TEST_TMPDIR/APP-built.yaml and
# sets BUILT to it.
database() {
  local ns=$1 app=$2 name=$3 dir="$TREE/kubernetes/apps/base/$1/$2"
  local vars=$BATS_TEST_TMPDIR/$app-vars.yaml ks=$BATS_TEST_TMPDIR/$app-ks.yaml
  mkdir -p "$dir/app"
  printf '%s\n' '---' 'apiVersion: kustomize.config.k8s.io/v1beta1' 'kind: Kustomization' 'resources: []' > "$dir/app/kustomization.yaml"
  APP_NAME=$app APP_NS=$ns CLUSTER_NAME=$name yq -n '{"apiVersion": "kustomize.toolkit.fluxcd.io/v1",
    "kind": "Kustomization", "metadata": {"name": strenv(APP_NAME), "namespace": "flux-system"},
    "spec": {"path": "./apps/base/" + strenv(APP_NS) + "/" + strenv(APP_NAME) + "/app", "targetNamespace": strenv(APP_NS),
      "dependsOn": [{"name": "cloudnative-pg"}, {"name": "prometheus-operator-crds"}, {"name": "external-secrets"}, {"name": "openbao-store"}],
      "components": ["../../../../../components/cnpg-cluster"],
      "postBuild": {"substitute": {"CNPG_CLUSTER_NAME": strenv(CLUSTER_NAME)}},
      "sourceRef": {"kind": "ExternalArtifact", "name": strenv(APP_NAME)}}}' > "$dir/ks.yaml"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER_DIR/cluster-config.example.yaml" "$CLUSTER_DIR/cluster-secrets.example.yaml" > "$vars"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = ($vars * (.spec.postBuild.substitute // {}))' "$vars" "$dir/ks.yaml" > "$ks"
  BUILT=$BATS_TEST_TMPDIR/$app-built.yaml
  (cd "$TREE" && flux build kustomization "$app" --path "./kubernetes/apps/base/$ns/$app/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute) > "$BUILT" 2> "$BATS_TEST_TMPDIR/$app-error.txt" ||
    { cat "$BATS_TEST_TMPDIR/$app-error.txt"; return 1; }
}

# use_build NAME: makes the build of the application NAME that a test kept as NAME-keep.yaml the one
# the helpers read.
use_build() {
  BUILT=$BATS_TEST_TMPDIR/$1-keep.yaml
}

# job_pod_field QUERY: yq's QUERY over the CronJob's pod template in the build BUILT.
job_pod_field() {
  yq -N 'select(.kind == "CronJob")' "$BUILT" | yq ".spec.jobTemplate.spec.template.spec | $1"
}

# job_container NAME QUERY: yq's QUERY over the container NAME, an init container or not.
job_container() {
  job_pod_field "(.initContainers + .containers)[] | select(.name == \"$1\") | $2"
}

# job_env CONTAINER: the container's environment as NAME=VALUE lines: each literal value as built, a
# marker for each value taken from a Secret, marker-secret-<key>, and for each taken from a field of
# the pod, marker-field-<path>.
job_env() {
  job_container "$1" '.env[] | .name + "=" + (.value
    // (.valueFrom.secretKeyRef.key | select(. != null) | "marker-secret-" + .)
    // (.valueFrom.fieldRef.fieldPath | select(. != null) | "marker-field-" + .))'
}

# job_scripts DIR: writes the scripts of the build's ConfigMap into DIR as files.
job_scripts() {
  local name
  mkdir -p "$1"
  while IFS= read -r name; do
    yq -N "select(.kind == \"ConfigMap\" and (.metadata.name | test(\"-dump-scripts\"))) | .data[\"$name\"]" "$BUILT" > "$1/$name"
  done < <(yq -N 'select(.kind == "ConfigMap" and (.metadata.name | test("-dump-scripts"))) | .data | keys | .[]' "$BUILT")
}

# job_run CONTAINER SCRIPT [NAME=VALUE...]: runs SCRIPT of the build's scripts, in $BATS_TEST_TMPDIR/scripts
# of the build, with the environment the container gets, each NAME=VALUE over it, and the stand-ins
# first on PATH. A value taken from the pod's namespace is the CronJob's. Sets status and output.
job_run() {
  local container=$1 script=$2 pair namespace
  local -a environment
  shift 2
  namespace=$(yq -N 'select(.kind == "CronJob") | .metadata.namespace' "$BUILT")
  mapfile -t environment < <(job_env "$container" | sed "s/^\\([A-Z_]*\\)=marker-field-metadata\\.namespace\$/\\1=$namespace/")
  for pair in "$@"; do
    environment+=("$pair")
  done
  [ -f "$BATS_TEST_TMPDIR/scripts/$script" ] || job_scripts "$BATS_TEST_TMPDIR/scripts"
  run env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${environment[@]}" sh "$BATS_TEST_TMPDIR/scripts/$script"
}

# duration_seconds DURATION: a Prometheus duration of hours, minutes and seconds, such as 1h or 45m30s,
# in seconds; fails on any other form.
duration_seconds() {
  [[ -n $1 && $1 =~ ^(([0-9]+)h)?(([0-9]+)m)?(([0-9]+)s)?$ ]] || { echo "not a duration of h, m and s: $1" >&2; return 1; }
  echo $((10#${BASH_REMATCH[2]:-0} * 3600 + 10#${BASH_REMATCH[4]:-0} * 60 + 10#${BASH_REMATCH[6]:-0}))
}

# dump_and_upload TAG: the job's three steps that touch the dump, in the order the pod runs them, for
# the build BUILT, with the plain dump and the encrypted file in directories of their own named TAG.
# Sets status, as the upload's run does, and PLAIN and OUT.
dump_and_upload() {
  PLAIN=$BATS_TEST_TMPDIR/$1/plain/db.dump
  OUT=$BATS_TEST_TMPDIR/$1/out
  mkdir -p "$(dirname "$PLAIN")" "$OUT"
  job_run dump dump.sh PLAIN_DUMP="$PLAIN"
  [ "$status" -eq 0 ]
  job_run encrypt encrypt.sh PLAIN_DUMP="$PLAIN" OUT_DIR="$OUT" AGE="$(command -v age)" AGE_RECIPIENT="$RECIPIENT"
  [ "$status" -eq 0 ]
  job_run upload upload.sh OUT_DIR="$OUT"
}

@test "A PostgreSQL cluster from the component is dumped daily and only the encrypted dump is uploaded, to a path of its own" {
  local -a handed objects
  database demo orders orders-db

  # The job: once a day, never two runs at once, with deadlines, history and a small retry budget.
  [ "$(yq -N 'select(.kind == "CronJob") | .metadata.name' "$BUILT")" = orders-db-pgdump ]
  [[ $(yq -N 'select(.kind == "CronJob") | .spec.schedule' "$BUILT") =~ ^([0-9]|[1-5][0-9])\ ([0-9]|1[0-9]|2[0-3])\ \*\ \*\ \*$ ]]
  [ "$(yq -N 'select(.kind == "CronJob") | .spec.concurrencyPolicy' "$BUILT")" = Forbid ]
  [[ $(yq -N 'select(.kind == "CronJob") | .spec.startingDeadlineSeconds' "$BUILT") =~ ^[1-9][0-9]*$ ]]
  deadline=$(yq -N 'select(.kind == "CronJob") | .spec.jobTemplate.spec.activeDeadlineSeconds' "$BUILT")
  [[ $deadline =~ ^[1-9][0-9]*$ ]]
  # The run's deadline ends it before PostgresDumpJobFailing has waited its `for` since the schedule,
  # so the alert never fires on a healthy dump that is still running.
  failing_for=$(yq '.spec.groups[].rules[] | select(.alert == "PostgresDumpJobFailing") | .for' \
    "$ROOT/kubernetes/apps/base/cnpg-system/cloudnative-pg/app/prometheusrule.yaml")
  [ "$deadline" -lt "$(duration_seconds "$failing_for")" ]
  [ "$(yq -N 'select(.kind == "CronJob") | .spec.jobTemplate.spec.backoffLimit' "$BUILT")" -le 2 ]
  [ "$(yq -N 'select(.kind == "CronJob") | .spec.successfulJobsHistoryLimit' "$BUILT")" -ge 1 ]
  [ "$(yq -N 'select(.kind == "CronJob") | .spec.failedJobsHistoryLimit' "$BUILT")" -ge 1 ]
  [ "$(job_pod_field '[.initContainers[].name, .containers[].name] | join(",")')" = "$(IFS=,; echo "${steps[*]}")" ]

  # Plain dump, encrypted file, upload: one encrypted object under the database's own path.
  dump_and_upload orders
  [ "$status" -eq 0 ]
  [ ! -e "$PLAIN" ]
  mapfile -t handed < <(find "$OUT" -type f -printf '%f\n')
  [ "${#handed[@]}" -eq 1 ]
  [[ ${handed[0]} =~ $NAME_RE ]]
  mapfile -t objects < <(find "$STORE" -type f -printf '%P\n')
  [ "${#objects[@]}" -eq 1 ]
  [ "${objects[0]}" = "$BUCKET/lab-sto2/demo/orders-db/${handed[0]}" ]
  [ "$(head -n 1 "$STORE/${objects[0]}")" = age-encryption.org/v1 ]
  age -d -i "$AGEKEY" "$STORE/${objects[0]}" | grep -q '^PGDMP marker-dump-content '
  run ! grep -aq 'marker-dump-content' "$STORE/${objects[0]}"
  # Encrypted to one recipient, the one the operator's recipes encrypt to, which the manifest holds.
  [ "$(grep -ac '^-> X25519 ' "$STORE/${objects[0]}")" -eq 1 ]
  [ "$(job_env encrypt | sed -n 's/^AGE_RECIPIENT=//p')" = "$(yq '.creation_rules[0].age' "$ROOT/talos/.sops.yaml")" ]
  # The client is handed the encrypted file alone, never the plain dump's path, and the key reaches
  # it in its environment, never its arguments.
  [ "$(grep -c '^rclone copyto ' "$RECORD/argv")" -eq 1 ]
  [[ $(grep '^rclone copyto ' "$RECORD/argv") == *" $OUT/${handed[0]} store:$BUCKET/lab-sto2/demo/orders-db/${handed[0]}" ]]
  [ -z "$(grep '^rclone ' "$RECORD/argv" | grep 'plain\|db\.dump' || true)" ]
  run ! grep -q 'marker-secret' "$RECORD/argv"
  # The bucket is the project's postgres bucket, the cluster the one whose directory the recipes name.
  [ "$(job_env upload | sed -n 's/^DUMP_BUCKET=//p')" = "$BUCKET" ]
  [ "$(job_env upload | sed -n 's/^DUMP_CLUSTER=//p')" = lab-sto2 ]
  [ -d "$ROOT/kubernetes/clusters/lab-sto2" ]
  # The plain dump lives in a sized, memory-backed volume the dump and the encrypting step mount; the
  # upload sees the encrypted file's volume alone, which is on disk.
  [ "$(job_pod_field '.volumes[] | select(.name == "plain") | .emptyDir.medium')" = Memory ]
  [[ $(job_pod_field '.volumes[] | select(.name == "plain") | .emptyDir.sizeLimit') =~ ^[1-9][0-9]*(Mi|Gi)$ ]]
  [ "$(job_pod_field '[(.initContainers + .containers)[] | select(.volumeMounts[]?.name == "plain") | .name] | join(",")')" = dump,encrypt ]
  [ "$(job_pod_field '.volumes[] | select(.name == "out") | .emptyDir.medium // "disk"')" = disk ]
  [[ $(job_pod_field '.volumes[] | select(.name == "out") | .emptyDir.sizeLimit') =~ ^[1-9][0-9]*(Mi|Gi)$ ]]
  [ "$(job_pod_field '[(.initContainers + .containers)[] | select(.volumeMounts[]?.name == "out") | .name] | join(",")')" = encrypt,upload ]
  [ "$(job_env dump | sed -n 's/^PLAIN_DUMP=//p')" = "$(job_container dump '.volumeMounts[] | select(.name == "plain") | .mountPath')/db.dump" ]

  # The dump starts a time of its own after the schedule, derived from the database's namespace and
  # name, so databases do not start together: the same database waits the same time at every run,
  # another database another time, always under the stagger the job allows for.
  stagger=$(job_env dump | sed -n 's/^DUMP_STAGGER_SECONDS=//p')
  [[ $stagger =~ ^[1-9][0-9]*$ ]]
  waited=$(tail -n 1 "$RECORD/sleep")
  [[ $waited =~ ^[0-9]+$ ]]
  [ "$waited" -lt "$stagger" ]
  mkdir -p "$BATS_TEST_TMPDIR/again"
  job_run dump dump.sh PLAIN_DUMP="$BATS_TEST_TMPDIR/again/db.dump"
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$RECORD/sleep")" = "$waited" ]
  database demo invoices invoices-db
  rm -rf "$BATS_TEST_TMPDIR/scripts" "$RECORD/sleep"
  dump_and_upload invoices
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$RECORD/sleep")" -lt "$stagger" ]
  [ "$(tail -n 1 "$RECORD/sleep")" != "$waited" ]
  # The namespace is part of what it is derived from: the same name in another namespace waits
  # another time.
  database shop orders orders-db
  rm -rf "$BATS_TEST_TMPDIR/scripts" "$RECORD/sleep"
  dump_and_upload orders-shop
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$RECORD/sleep")" -lt "$stagger" ]
  [ "$(tail -n 1 "$RECORD/sleep")" != "$waited" ]
}

@test "The dump is taken as the application's own role and the S3 key reaches only the upload" {
  local secret
  database demo orders orders-db

  # The application's role, with the Secret the operator makes for it: three keys, read by the dump
  # container alone, and no superuser's Secret anywhere.
  [ "$(job_container dump '[.env[] | select(.valueFrom.secretKeyRef != null) | .valueFrom.secretKeyRef.name + ":" + .valueFrom.secretKeyRef.key] | sort | join(",")')" = "orders-db-app:dbname,orders-db-app:password,orders-db-app:username" ]
  [ "$(job_pod_field '[(.initContainers + .containers)[] | select(.env[]?.valueFrom.secretKeyRef.name == "orders-db-app") | .name] | join(",")')" = dump ]
  [ "$(job_pod_field '[.volumes[]? | select(.secret.secretName == "orders-db-app")] | length')" -eq 0 ]
  run ! grep -qi 'superuser' "$BUILT"
  [ "$(job_env dump | sed -n 's/^PGUSER=//p')" = marker-secret-username ]
  [ "$(job_env dump | sed -n 's/^PGPASSWORD=//p')" = marker-secret-password ]
  [ "$(job_env dump | sed -n 's/^PGDATABASE=//p')" = marker-secret-dbname ]
  # Through the replicas' Service, the primary's only when no replica answers.
  [ "$(job_env dump | sed -n 's/^DUMP_READ_HOST=//p')" = orders-db-ro ]
  [ "$(job_env dump | sed -n 's/^DUMP_WRITE_HOST=//p')" = orders-db-rw ]

  job_run dump dump.sh PLAIN_DUMP="$BATS_TEST_TMPDIR/db.dump"
  [ "$status" -eq 0 ]
  # The step's output goes to the pod's log: neither the password nor a byte of the plain dump is in it.
  [[ $output != *marker-secret* ]]
  [[ $output != *marker-dump-content* ]]
  grep -qx 'PGUSER=marker-secret-username' "$RECORD/env.pg_dump"
  grep -qx 'PGPASSWORD=marker-secret-password' "$RECORD/env.pg_dump"
  grep -qx 'PGDATABASE=marker-secret-dbname' "$RECORD/env.pg_dump"
  grep -qx 'PGHOST=orders-db-ro' "$RECORD/env.pg_dump"
  grep -qx 'PGSSLMODE=require' "$RECORD/env.pg_dump"
  grep -q '^pg_dump --format=custom ' "$RECORD/argv"
  run ! grep -q 'marker-secret' "$RECORD/argv"
  # With one instance there is no replica: the Service has no endpoint, and the primary is dumped.
  rm -f "$RECORD/env.pg_dump"
  echo orders-db-ro > "$BATS_TEST_TMPDIR/hosts-down"
  job_run dump dump.sh PLAIN_DUMP="$BATS_TEST_TMPDIR/db.dump"
  [ "$status" -eq 0 ]
  grep -qx 'PGHOST=orders-db-rw' "$RECORD/env.pg_dump"
  # A dump that cannot be written fails the step, so the encrypting step never runs on a part of it.
  : > "$BATS_TEST_TMPDIR/dump-fails"
  job_run dump dump.sh PLAIN_DUMP="$BATS_TEST_TMPDIR/db.dump"
  [ "$status" -ne 0 ]

  # The S3 key: the two properties of the key the volume backups use and nothing else, in a Secret of
  # this database's, which only the upload container takes.
  [ "$(yq -N 'select(.kind == "ExternalSecret") | .spec.secretStoreRef.name' "$BUILT")" = openbao ]
  [ "$(yq -N 'select(.kind == "ExternalSecret") | .spec.data[].remoteRef | .key + ":" + .property' "$BUILT" | sort | paste -sd,)" = "volsync:AWS_ACCESS_KEY_ID,volsync:AWS_SECRET_ACCESS_KEY" ]
  [ "$(yq -N 'select(.kind == "ExternalSecret") | (.spec.dataFrom // []) | length' "$BUILT")" -eq 0 ]
  [ "$(yq -N 'select(.kind == "ExternalSecret") | .metadata.namespace' "$BUILT")" = demo ]
  secret=$(yq -N 'select(.kind == "ExternalSecret") | .spec.target.name' "$BUILT")
  [ -n "$secret" ]
  [ "$(job_pod_field '[(.initContainers + .containers)[] | select(.env[]?.valueFrom.secretKeyRef.name == "'"$secret"'") | .name] | join(",")')" = upload ]
  [ "$(job_pod_field '[(.initContainers + .containers)[] | select(.envFrom != null) | .name] | length')" -eq 0 ]
  [ "$(job_pod_field '[.volumes[]? | select(.secret.secretName == "'"$secret"'")] | length')" -eq 0 ]
  [ -z "$(job_pod_field '(.initContainers + .containers)[] | .env[]? | select(.name | test("SECRET|ACCESS_KEY|TOKEN|PASSWORD")) | select(.value != null) | .name')" ]
  run ! grep -rEi '(secret_access_key|access_key_id|AWS_SECRET)[^A-Za-z_]*[:=] *["'\'']?[A-Za-z0-9/+]{16,}' "$ROOT/$COMPONENT"
}

@test "Two databases never share a path, and one's retention deletes none of another's" {
  local -a paths
  local path other day
  database demo orders orders-db
  cp "$BUILT" "$BATS_TEST_TMPDIR/orders-keep.yaml"
  database demo invoices invoices-db
  cp "$BUILT" "$BATS_TEST_TMPDIR/invoices-keep.yaml"
  database shop orders orders-db
  cp "$BUILT" "$BATS_TEST_TMPDIR/shop-orders-keep.yaml"

  # What each database's upload is given for its path, from the manifests as built: its namespace
  # and name come from the pod and the Cluster, so a database of the same name in another namespace,
  # and another in the same namespace, are told apart.
  for built in orders invoices shop-orders; do
    use_build "$built"
    [ "$(job_env upload | sed -n 's/^DUMP_NAMESPACE=//p')" = marker-field-metadata.namespace ]
    path=$(job_env upload | sed -n 's/^DUMP_CLUSTER=//p;s/^DUMP_NAME=//p' | paste -sd/)
    paths+=("$(yq -N 'select(.kind == "CronJob") | .metadata.namespace' "$BUILT")/$path")
  done
  [ "$(printf '%s\n' "${paths[@]}" | sort -u | wc -l)" -eq 3 ]

  # Forty dumps of each, and an object of nobody's, in the bucket; the first database uploads once.
  keep=$(yq -N 'select(.kind == "CronJob")' "$BATS_TEST_TMPDIR/orders-keep.yaml" |
    yq '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "upload") | .env[] | select(.name == "KEEP_DUMPS") | .value')
  [[ $keep =~ ^[1-9][0-9]*$ ]]
  for path in demo/orders-db demo/invoices-db shop/orders-db; do
    mkdir -p "$STORE/$BUCKET/lab-sto2/$path"
    for day in $(seq 1 $((keep + 10))); do
      printf x > "$STORE/$BUCKET/lab-sto2/$path/$(printf '2026%02d%02dT000000Z' $(((day - 1) / 28 + 1)) $(((day - 1) % 28 + 1))).dump.age"
    done
  done
  printf x > "$STORE/$BUCKET/lab-sto2/demo/orders-db/notes.txt"
  printf x > "$STORE/$BUCKET/lab-sto2/demo/orders-db-extra"
  printf x > "$STORE/$BUCKET/20250101T000000Z.dump.age"
  use_build orders
  rm -rf "$BATS_TEST_TMPDIR/scripts"
  dump_and_upload orders
  [ "$status" -eq 0 ]

  # Its own directory is cut to the newest `keep`, the new dump among them; nothing of the others, of
  # the bucket's root or of what is no dump has gone.
  mapfile -t kept < <(find "$STORE/$BUCKET/lab-sto2/demo/orders-db" -maxdepth 1 -type f -printf '%f\n' | grep -E "$NAME_RE")
  [ "${#kept[@]}" -eq "$keep" ]
  new=$(find "$OUT" -type f -printf '%f\n')
  [ -f "$STORE/$BUCKET/lab-sto2/demo/orders-db/$new" ]
  [ ! -e "$STORE/$BUCKET/lab-sto2/demo/orders-db/20260101T000000Z.dump.age" ]
  [ -f "$STORE/$BUCKET/lab-sto2/demo/orders-db/notes.txt" ]
  [ -f "$STORE/$BUCKET/lab-sto2/demo/orders-db-extra" ]
  [ -f "$STORE/$BUCKET/20250101T000000Z.dump.age" ]
  for other in demo/invoices-db shop/orders-db; do
    [ "$(find "$STORE/$BUCKET/lab-sto2/$other" -type f | wc -l)" -eq $((keep + 10)) ]
  done
  # It listed its own directory, after the upload, and deleted only dumps of it.
  [ "$(grep '^rclone lsf ' "$RECORD/argv" | sed 's/^rclone lsf --files-only //')" = "store:$BUCKET/lab-sto2/demo/orders-db/" ]
  [ "$(grep -n '^rclone lsf ' "$RECORD/argv" | head -n 1 | cut -d: -f1)" -gt "$(grep -n '^rclone copyto ' "$RECORD/argv" | head -n 1 | cut -d: -f1)" ]
  [ "$(grep -c '^rclone deletefile ' "$RECORD/argv")" -eq 11 ]
  while read -r _ _ target; do
    [[ $target == "store:$BUCKET/lab-sto2/demo/orders-db/"* ]]
    [[ ${target##*/} =~ $NAME_RE ]]
  done < <(grep '^rclone deletefile ' "$RECORD/argv")
  # A dump that is not listed after its upload deletes nothing, so a listing that fails never costs
  # the dumps already there.
  : > "$FAILS/list"
  rm -f "$RECORD/argv"
  use_build orders
  job_run upload upload.sh OUT_DIR="$OUT"
  [ "$status" -ne 0 ]
  [ -z "$(grep '^rclone deletefile ' "$RECORD/argv" || true)" ]
}

@test "The dump tool is of the PostgreSQL version the cluster runs" {
  local image cluster
  database demo orders orders-db

  cluster=$(yq -N 'select(.kind == "Cluster") | .spec.imageName' "$BUILT")
  [[ $cluster =~ ^ghcr\.io/cloudnative-pg/postgresql:([0-9]+)\.[0-9]+(-[a-z0-9]+)*$ ]]
  major=${BASH_REMATCH[1]}
  image=$(job_container dump '.image')
  # The tool is the image of the same registry path and the same major version, pinned by tag and
  # digest, as is every image of the job.
  [[ $image =~ ^ghcr\.io/cloudnative-pg/postgresql:([0-9]+)\.[0-9]+(-[a-z0-9]+)*@sha256:[0-9a-f]{64}$ ]]
  [ "${BASH_REMATCH[1]}" = "$major" ]
  while IFS= read -r image; do
    [[ $image =~ ^[a-z0-9./-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]]
  done < <(job_pod_field '(.initContainers + .containers)[] | .image')
}

@test "the component's scripts are the etcd snapshot job's, apart from the differences named here" {
  local etcd=$ROOT/kubernetes/apps/base/etcd-snapshots/etcd-snapshots/app/scripts
  local mine=$ROOT/$COMPONENT/scripts
  # Fetching age is the same file, byte for byte.
  cmp "$etcd/fetch-age.sh" "$mine/fetch-age.sh"
  # The encrypting and the uploading differ in the words that say what they handle, a dump for a
  # snapshot and pg_dump for talosctl, and the upload in its path, which names the namespace and the
  # database below the cluster. Every line that is not a comment is the etcd job's with those
  # substitutions made; the comments are each file's own.
  diff <(sed -e 's/snapshot/dump/g' -e 's/SNAPSHOT/DUMP/g' -e 's/talosctl/pg_dump/g' <(grep -v '^#' "$etcd/encrypt.sh")) \
    <(grep -v '^#' "$mine/encrypt.sh")
  # shellcheck disable=SC2016 # the sed expression names shell variables.
  diff <(sed -e 's/snapshot/dump/g' -e 's/SNAPSHOT/DUMP/g' -e 's|^prefix=store:\$DUMP_BUCKET/\$DUMP_CLUSTER$|prefix=store:$DUMP_BUCKET/$DUMP_CLUSTER/$DUMP_NAMESPACE/$DUMP_NAME|' <(grep -v '^#' "$etcd/upload.sh")) \
    <(grep -v '^#' "$mine/upload.sh")
  # Flux substitutes `${...}` in what it applies, so no script holds one.
  # shellcheck disable=SC2016 # the pattern is the characters themselves.
  run ! grep -F '${' "$mine"/*.sh
}

@test "the dump job runs restricted, holds no cluster credential and bounds what it uses" {
  database demo orders orders-db

  [ "$(job_pod_field '.automountServiceAccountToken')" = false ]
  [ "$(job_pod_field '.enableServiceLinks')" = false ]
  [ "$(job_pod_field '.restartPolicy')" = Never ]
  [ "$(job_pod_field '.securityContext.runAsNonRoot')" = true ]
  [ "$(job_pod_field '.securityContext.seccompProfile.type')" = RuntimeDefault ]
  [ "$(job_pod_field '.tolerations // [] | length')" -eq 0 ]
  [ "$(job_pod_field '[.volumes[] | select(.emptyDir == null and .configMap == null)] | length')" -eq 0 ]
  while IFS= read -r name; do
    [ "$(job_container "$name" '.securityContext.allowPrivilegeEscalation')" = false ]
    [ "$(job_container "$name" '.securityContext.runAsNonRoot')" = true ]
    [ "$(job_container "$name" '.securityContext.capabilities.drop | join(",")')" = ALL ]
    [ "$(job_container "$name" '.securityContext.readOnlyRootFilesystem')" = true ]
    [ "$(job_container "$name" '.securityContext.seccompProfile.type')" = RuntimeDefault ]
    [ -n "$(job_container "$name" '.resources.requests.memory')" ]
    [ -n "$(job_container "$name" '.resources.limits.memory')" ]
  done < <(job_pod_field '(.initContainers + .containers)[] | .name')
  # The age the job fetches is the pinned one.
  [ "$(job_env fetch-age | sed -n 's/^AGE_VERSION=//p')" = "$(sed -n 's/^age = "\(.*\)"$/\1/p' "$ROOT/mise.toml")" ]
  # The CronJob is named <cluster>-pgdump and a CronJob's name is at most 52 characters, so a longer
  # cluster name is refused by the API, and with it the whole application. Each application's name is
  # read as Flux reads its ks.yaml, quoted or not.
  names=$(find "$ROOT/kubernetes" -name ks.yaml -exec yq -N '.spec.postBuild.substitute.CNPG_CLUSTER_NAME | select(. != null)' {} +)
  [ -n "$names" ]
  while IFS= read -r name; do
    [ "${#name}" -le 45 ]
  done <<<"$names"
  # Its checksums are the etcd job's, which follow the same version: a version moved without them
  # fails only when the pod fetches the archive.
  etcd_job=$ROOT/kubernetes/apps/base/etcd-snapshots/etcd-snapshots/app/cronjob.yaml
  for name in AGE_SHA256_AMD64 AGE_SHA256_ARM64; do
    [[ $(job_env fetch-age | sed -n "s/^$name=//p") =~ ^[0-9a-f]{64}$ ]]
    [ "$(job_env fetch-age | sed -n "s/^$name=//p")" = "$(yq -N ".spec.jobTemplate.spec.template.spec | (.initContainers + .containers)[] | select(.name == \"fetch-age\") | .env[] | select(.name == \"$name\") | .value" "$etcd_job")" ]
  done
}
