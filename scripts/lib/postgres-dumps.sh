# shellcheck shell=bash
# Shared by scripts/postgres-dumps and scripts/postgres-dump-check: a PostgreSQL database's dumps in
# the postgres bucket, <BACKUP_BUCKET_PREFIX>-postgres, as the cnpg-cluster component's dump job
# keeps them: <cluster>/<namespace>/<name>/<UTC time>.dump.age, the cluster the Kubernetes cluster's
# name, the namespace and name those of the database's Cluster. Builds on scripts/lib/s3.sh.

# shellcheck source=scripts/lib/s3.sh
. "$(dirname "${BASH_SOURCE[0]}")/s3.sh"

# A dump's name is the UTC time it was taken, so that names sort as the dumps were taken.
pg_dump_name_re='^[0-9]{8}T[0-9]{6}Z\.dump\.age$'
# A namespace and a Cluster name are DNS labels; the pattern keeps a slash or a dot out of the path.
# shellcheck disable=SC2034 # read by the scripts that source this
pg_label_re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'

# s3_postgres_dumps CLUSTER NAMESPACE NAME: the dumps of the database, as the state key lists the
# objects directly under its path that are named as a dump is: each as its name and size in bytes,
# one per line, newest first; nothing when there is none. When the bucket cannot be listed, returns
# rclone's status and shows its reason as scripts/lib/errors.sh shows errors; a prefix without
# objects lists as empty (s3_backup_objects in scripts/lib/s3.sh).
s3_postgres_dumps() {
  s3_backup_objects postgres "$1/$2/$3" "$pg_dump_name_re"
}

# s3_postgres_databases CLUSTER: the databases that have a dump under CLUSTER, as <namespace>/<name>,
# one per line, sorted; nothing when there is none. Failures are shown as s3_postgres_dumps shows
# them.
s3_postgres_databases() {
  local status=0
  run_keeping_errors s3_rclone state lsjson --recursive --files-only "store:$BACKUP_BUCKET_PREFIX-postgres/$1/" || status=$?
  if ((status != 0)); then
    report_errors rclone
    return "$status"
  fi
  jq -r --arg dump "${pg_dump_name_re#^}" \
    '[.[].Path | select(test("^[a-z0-9-]+/[a-z0-9-]+/" + $dump)) | split("/")[0:2] | join("/")] | unique[]' <<< "$last_output"
}
