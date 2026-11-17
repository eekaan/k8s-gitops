# shellcheck shell=bash
# Helpers, loaded by tests/etcd-snapshots.bats, tests/cluster-snapshot.bats,
# tests/openbao-snapshots.bats and tests/openbao-snapshot-recipes.bats, that build a snapshot
# application as Flux applies it and run its scripts as its containers run them, against the recording
# fakes of the tests. Needs flux, kustomize, yq and jq on PATH.

JOB_REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
JOB_CLUSTER=$JOB_REPO/kubernetes/clusters/lab-sto2
# The application and Kustomization it builds; tests/openbao-snapshots.bats and
# tests/openbao-snapshot-recipes.bats, whose job has the same shape, set both before they load this
# file.
JOB_APP=${JOB_APP:-kubernetes/apps/base/etcd-snapshots/etcd-snapshots}
JOB_NAME=${JOB_NAME:-etcd-snapshots}

# job_setup_file: a copy of the applications and components in the file's temporary directory, as
# flux build rewrites the kustomization.yaml of what it builds and puts it back afterwards.
job_setup_file() {
  export JOB_TREE=$BATS_FILE_TMPDIR/tree
  mkdir -p "$JOB_TREE/kubernetes"
  cp -R "$JOB_REPO/kubernetes/apps" "$JOB_REPO/kubernetes/components" "$JOB_TREE/kubernetes/"
}

# job_build [NAME=VALUE...]: the application as Flux applies it, substituting strictly the variables
# of the cluster's example key lists and the application's own postBuild.substitute over them, then
# each NAME=VALUE. Writes $BATS_TEST_TMPDIR/job-built.yaml and sets JOB_BUILT.
job_build() {
  local vars=$BATS_TEST_TMPDIR/job-vars.yaml ks=$BATS_TEST_TMPDIR/job-ks.yaml pair
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$JOB_CLUSTER/cluster-config.example.yaml" "$JOB_CLUSTER/cluster-secrets.example.yaml" > "$BATS_TEST_TMPDIR/job-example.yaml"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | $vars * (.spec.postBuild.substitute // {})' "$BATS_TEST_TMPDIR/job-example.yaml" "$JOB_TREE/$JOB_APP/ks.yaml" > "$vars"
  for pair in "$@"; do
    NAME="${pair%%=*}" VALUE="${pair#*=}" yq -i '.[strenv(NAME)] = strenv(VALUE)' "$vars"
  done
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = $vars' "$vars" "$JOB_TREE/$JOB_APP/ks.yaml" > "$ks"
  JOB_BUILT=$BATS_TEST_TMPDIR/job-built.yaml
  (cd "$JOB_TREE" && flux build kustomization "$JOB_NAME" --path "./$JOB_APP/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute) > "$JOB_BUILT"
}

# job_pod_field QUERY: yq's QUERY over the CronJob's pod template in the built application.
job_pod_field() {
  yq -N 'select(.kind == "CronJob")' "$JOB_BUILT" | yq ".spec.jobTemplate.spec.template.spec | $1"
}

# job_container NAME QUERY: yq's QUERY over the container NAME, an init container or not.
job_container() {
  job_pod_field "(.initContainers + .containers)[] | select(.name == \"$1\") | $2"
}

# job_scripts DIR: writes the scripts of the application's ConfigMap into DIR as files.
job_scripts() {
  local name
  mkdir -p "$1"
  while IFS= read -r name; do
    yq -N "select(.kind == \"ConfigMap\" and (.metadata.name | test(\"^${JOB_NAME}-scripts\"))) | .data[\"$name\"]" "$JOB_BUILT" > "$1/$name"
  done < <(yq -N "select(.kind == \"ConfigMap\" and (.metadata.name | test(\"^${JOB_NAME}-scripts\"))) | .data | keys | .[]" "$JOB_BUILT")
}

# job_env CONTAINER: the container's environment as NAME=VALUE lines: each literal value as built,
# and a marker for each value taken from a Secret, marker-secret-<key>.
job_env() {
  job_container "$1" '.env[] | .name + "=" + (.value // ("marker-secret-" + .valueFrom.secretKeyRef.key))'
}

# job_run CONTAINER SCRIPT [NAME=VALUE...]: runs SCRIPT of the built application's scripts in DIR
# $JOB_SCRIPTS with the environment the container gets, each NAME=VALUE over it, and the fakes first
# on PATH. Sets status and output, as run does.
job_run() {
  local container=$1 script=$2 pair
  local -a environment
  shift 2
  mapfile -t environment < <(job_env "$container")
  for pair in "$@"; do
    environment+=("$pair")
  done
  run env -i HOME="$BATS_TEST_TMPDIR" PATH="$BATS_TEST_TMPDIR/bin:$PATH" "${environment[@]}" sh "$JOB_SCRIPTS/$script"
}
