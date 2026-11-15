#!/bin/sh
# Encrypts the etcd snapshot to the Talos age key's recipient into OUT_DIR, named as
# scripts/lib/snapshot.sh names the operator's own, <UTC time>.snapshot.age, and removes the plain
# snapshot, so the step that uploads is given the encrypted file alone. Only the recipient, the
# public half, is here: the private key never enters the cluster.
# Needs PLAIN_SNAPSHOT, OUT_DIR, AGE and AGE_RECIPIENT.
set -eu
if [ ! -s "$PLAIN_SNAPSHOT" ]; then
  echo "encrypt: talosctl wrote no snapshot" >&2
  exit 1
fi
name=$(date -u +%Y%m%dT%H%M%SZ).snapshot.age
"$AGE" --encrypt --recipient "$AGE_RECIPIENT" --output "$OUT_DIR/$name" "$PLAIN_SNAPSHOT"
rm -f "$PLAIN_SNAPSHOT"
echo "encrypt: $name"
