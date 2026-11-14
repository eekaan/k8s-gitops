# shellcheck shell=bash
# Shared by scripts/cluster-snapshot and the upgrade recipes: an etcd snapshot of the cluster that
# scripts/cluster-env set up, kept encrypted in the etcd backup bucket, <BACKUP_BUCKET_PREFIX>-etcd.
# An etcd snapshot holds every Kubernetes Secret, and every S3 key of the project reaches the bucket
# (ADR 0008), so only the Talos age key opens what is uploaded:
#   1. talman etcd snapshot writes the snapshot into a private temporary directory outside the
#      repository, never into the cluster's clusterconfig/, where talman puts a snapshot it is given
#      no path for, and where it puts the one its upgrade and upgrade-k8s take with --snapshot, which
#      the recipes therefore never pass;
#   2. age encrypts it to the Talos age key's recipient in talos/.sops.yaml, which needs no private
#      key, and the plaintext is removed;
#   3. the encrypted file alone is uploaded with the state key as <cluster>/<UTC time>.snapshot.age,
#      without rclone checking for the bucket, which would create a bucket that is not there; an
#      object of that name, from a snapshot taken in the same second, is refused, not overwritten;
#   4. once the bucket lists the object at the size uploaded, one line is printed: the cluster, the
#      object's name and its size.
# Nothing is left on disk, whether the run succeeds, fails or is interrupted: make_private_dir's EXIT
# trap removes the directory. Neither talman's nor rclone's output is printed: they name the control
# plane's address, the bucket and the endpoint. Builds on scripts/lib/cluster.sh and scripts/lib/s3.sh.

# shellcheck source=scripts/lib/cluster.sh
. "$(dirname "${BASH_SOURCE[0]}")/cluster.sh"
# shellcheck source=scripts/lib/s3.sh
. "$(dirname "${BASH_SOURCE[0]}")/s3.sh"

# require_snapshot: fails naming each setting and command a snapshot needs and the environment lacks.
# The Talos age key's recipient, and the cluster's own files, are require_cluster's: age-key,
# recipient and talman.
require_snapshot() {
  local complete=1
  require_env BACKUP_BUCKET_PREFIX AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY || complete=0
  require_commands age || complete=0
  ((complete))
}

# prepare_snapshot: checks the bucket's name, reads the object storage's settings, and sets
# snapshot_recipient, the one age recipient talos/.sops.yaml names. Run after require_snapshot.
prepare_snapshot() {
  s3_bucket_name_ok BACKUP_BUCKET_PREFIX prefix || return 1
  s3_require_client || return 1
  snapshot_recipient=$(sops_recipient)
  if [[ ! $snapshot_recipient =~ ^age1[0-9a-z]+$ ]]; then
    infra_error "talos/.sops.yaml does not name exactly one age recipient"
    return 1
  fi
}

# take_etcd_snapshot: takes, encrypts and uploads the snapshot as above, after prepare_snapshot, and
# prints the line that names it. Returns 1 at the first step that fails, with step naming it.
take_etcd_snapshot() {
  local snapshot encrypted name list_status=0 listing taken size listed listed_size

  step="making a private directory for the snapshot"
  make_private_dir || return 1
  snapshot=$work_dir/etcd.db
  name=$(date -u +%Y%m%dT%H%M%SZ).snapshot.age
  encrypted=$work_dir/$name

  step="taking the etcd snapshot"
  cluster_talman etcd snapshot "$snapshot" > /dev/null || return
  if [[ ! -s $snapshot ]]; then
    infra_error "talman etcd snapshot wrote no snapshot"
    return 1
  fi

  step="encrypting the snapshot to the Talos age key's recipient"
  age --encrypt --recipient "$snapshot_recipient" --output "$encrypted" "$snapshot" || return
  rm -f -- "$snapshot"

  step="checking that the etcd bucket holds no $name of $cluster yet"
  # Two snapshots taken in the same second share a name, and an upload replaces an object. Without
  # the bucket there is nothing to replace, and the upload below fails without making one.
  listing=$(s3_etcd_snapshots "$cluster") || list_status=$?
  if ((list_status != 0 && list_status != 3)); then
    infra_error "rclone cannot list the etcd bucket with the state key"
    return 1
  fi
  while read -r taken _; do
    if [[ $taken == "$name" ]]; then
      infra_error "the etcd bucket holds $cluster/$name already; it is not overwritten"
      return 1
    fi
  done <<< "$listing"

  step="uploading the encrypted snapshot to the etcd bucket"
  if ! s3_rclone state copyto --s3-no-check-bucket "$encrypted" \
    "store:$BACKUP_BUCKET_PREFIX-etcd/$cluster/$name" > /dev/null 2>&1; then
    infra_error "rclone cannot upload the snapshot with the state key; the etcd bucket must exist; just infra-backup-buckets creates it"
    return 1
  fi

  step="checking that the etcd bucket lists the snapshot"
  if ! listing=$(s3_etcd_snapshots "$cluster"); then
    infra_error "rclone cannot list the etcd bucket with the state key"
    return 1
  fi
  size=
  while read -r listed listed_size; do
    if [[ $listed == "$name" ]]; then
      size=$listed_size
    fi
  done <<< "$listing"
  if [[ ! $size =~ ^[0-9]+$ ]] || ((size != $(wc -c < "$encrypted"))); then
    infra_error "the etcd bucket does not list $name at the size uploaded"
    return 1
  fi
  echo "${0##*/}: $cluster: $name, $size bytes"
}
