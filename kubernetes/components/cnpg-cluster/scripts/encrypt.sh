#!/bin/sh
# Encrypts the plain dump to the Talos age key's recipient into OUT_DIR, named <UTC time>.dump.age,
# and removes the plain dump, so the step that uploads is given the encrypted file alone. Only the
# recipient, the public half, is here: the private key never enters the cluster.
# Needs PLAIN_DUMP, OUT_DIR, AGE and AGE_RECIPIENT.
set -eu
if [ ! -s "$PLAIN_DUMP" ]; then
  echo "encrypt: pg_dump wrote no dump" >&2
  exit 1
fi
name=$(date -u +%Y%m%dT%H%M%SZ).dump.age
"$AGE" --encrypt --recipient "$AGE_RECIPIENT" --output "$OUT_DIR/$name" "$PLAIN_DUMP"
rm -f "$PLAIN_DUMP"
echo "encrypt: $name"
