#!/bin/sh
# Uploads the encrypted dump in OUT_DIR to <cluster>/<namespace>/<name>/ in the postgres bucket, the
# path of its database alone, checks that the bucket lists it there, and deletes the oldest dumps of
# that path beyond the newest KEEP_DUMPS. The client reads its store and key from
# RCLONE_CONFIG_STORE_* in its environment.
# The bucket is never created (--s3-no-check-bucket) and an object is never modified (--immutable).
# Needs OUT_DIR, DUMP_BUCKET, DUMP_CLUSTER, DUMP_NAMESPACE, DUMP_NAME and KEEP_DUMPS.
set -eu
dump_re='^[0-9]{8}T[0-9]{6}Z\.dump\.age$'
prefix=store:$DUMP_BUCKET/$DUMP_CLUSTER/$DUMP_NAMESPACE/$DUMP_NAME

files=$(ls "$OUT_DIR")
name=$files
if [ "$(printf '%s\n' "$files" | wc -l)" -ne 1 ] || ! printf '%s\n' "$name" | grep -Eq "$dump_re"; then
  echo "upload: $OUT_DIR holds more or other than one dump" >&2
  exit 1
fi

rclone copyto --s3-no-check-bucket --immutable "$OUT_DIR/$name" "$prefix/$name"

# Newest first, as the bucket lists the objects directly under the database's prefix.
listing=$(rclone lsf --files-only "$prefix/" | grep -E "$dump_re" | sort -r)
if ! printf '%s\n' "$listing" | grep -qxF "$name"; then
  echo "upload: the bucket does not list $name after the upload" >&2
  exit 1
fi
echo "upload: $name"

for old in $(printf '%s\n' "$listing" | tail -n +$((KEEP_DUMPS + 1))); do
  rclone deletefile "$prefix/$old"
  echo "upload: deleted $old"
done
