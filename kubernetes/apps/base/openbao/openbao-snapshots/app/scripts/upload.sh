#!/bin/sh
# Uploads the encrypted snapshot in OUT_DIR to <cluster>/<name> in the OpenBao bucket, named as
# scripts/lib/s3.sh names a snapshot, as the etcd snapshot job names its own, checks that the bucket
# lists it, and deletes the oldest snapshots of the cluster beyond the newest KEEP_SNAPSHOTS. The
# client reads its store and key from RCLONE_CONFIG_STORE_* in its environment.
# The bucket is never created (--s3-no-check-bucket) and an object is never modified (--immutable).
# Needs OUT_DIR, SNAPSHOT_BUCKET, SNAPSHOT_CLUSTER and KEEP_SNAPSHOTS.
set -eu
snapshot_re='^[0-9]{8}T[0-9]{6}Z\.snapshot\.age$'
prefix=store:$SNAPSHOT_BUCKET/$SNAPSHOT_CLUSTER

files=$(ls "$OUT_DIR")
name=$files
if [ "$(printf '%s\n' "$files" | wc -l)" -ne 1 ] || ! printf '%s\n' "$name" | grep -Eq "$snapshot_re"; then
  echo "upload: $OUT_DIR holds more or other than one snapshot" >&2
  exit 1
fi

rclone copyto --s3-no-check-bucket --immutable "$OUT_DIR/$name" "$prefix/$name"

# Newest first, as the bucket lists the objects directly under the cluster's prefix.
listing=$(rclone lsf --files-only "$prefix/" | grep -E "$snapshot_re" | sort -r)
if ! printf '%s\n' "$listing" | grep -qxF "$name"; then
  echo "upload: the bucket does not list $name after the upload" >&2
  exit 1
fi
echo "upload: $name"

for old in $(printf '%s\n' "$listing" | tail -n +$((KEEP_SNAPSHOTS + 1))); do
  rclone deletefile "$prefix/$old"
  echo "upload: deleted $old"
done
