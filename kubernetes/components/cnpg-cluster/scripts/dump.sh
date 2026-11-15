#!/bin/sh
# Writes a custom-format dump of the application's database to PLAIN_DUMP, as the application's own
# role, from a replica through DUMP_READ_HOST. A cluster of one instance has no replica, so its
# read-only Service has no endpoint; the dump is then taken from the primary, through DUMP_WRITE_HOST.
# First it waits a time of its own below DUMP_STAGGER_SECONDS, from a checksum of the database's
# namespace and name, so databases on one schedule do not all start together.
# The role, its password and the database come in PGUSER, PGPASSWORD and PGDATABASE, pg_dump's own
# variables, and never on a command line.
# Needs DUMP_NAMESPACE, DUMP_NAME, DUMP_STAGGER_SECONDS, DUMP_READ_HOST, DUMP_WRITE_HOST, PLAIN_DUMP
# and the PG* variables.
set -eu
delay=$(($(printf '%s/%s' "$DUMP_NAMESPACE" "$DUMP_NAME" | cksum | cut -d' ' -f1) % DUMP_STAGGER_SECONDS))
echo "dump: starts in $delay seconds"
sleep "$delay"

PGHOST=$DUMP_READ_HOST
if ! pg_isready -q -t 10 -h "$PGHOST"; then
  echo "dump: no replica answers at $PGHOST; dumping from the primary at $DUMP_WRITE_HOST" >&2
  PGHOST=$DUMP_WRITE_HOST
fi
export PGHOST

pg_dump --format=custom --no-password --file "$PLAIN_DUMP"
if [ ! -s "$PLAIN_DUMP" ]; then
  echo "dump: pg_dump wrote no dump" >&2
  exit 1
fi
echo "dump: $(wc -c < "$PLAIN_DUMP") bytes from $PGHOST"
