#!/bin/sh
# Takes a snapshot of OpenBao's raft storage into PLAIN_SNAPSHOT: logs in to the Kubernetes auth
# method as the role BAO_ROLE with the pod's own token, a file the kubelet projects for the
# audience the role checks, and saves the snapshot from the active member with the token the login
# returns. The role's policy permits that one request. The token lives in this shell's variable and
# in the environment of the one command that needs it: never in a file, an argument or the output,
# and it expires with the role's ten minutes. The client verifies the listener's certificate against
# the CA in BAO_CACERT for the name in BAO_ADDR.
# Needs BAO_ADDR, BAO_CACERT, BAO_ROLE, JWT_FILE and PLAIN_SNAPSHOT.
set -eu
umask 077
unset BAO_TOKEN
if [ ! -s "$JWT_FILE" ]; then
  echo "snapshot: no service account token at $JWT_FILE" >&2
  exit 1
fi
if ! token=$(bao write -field=token auth/kubernetes/login role="$BAO_ROLE" jwt=@"$JWT_FILE"); then
  echo "snapshot: the login as the role $BAO_ROLE failed" >&2
  exit 1
fi
if [ -z "$token" ]; then
  echo "snapshot: the login as the role $BAO_ROLE returned no token" >&2
  exit 1
fi
if ! BAO_TOKEN=$token bao operator raft snapshot save "$PLAIN_SNAPSHOT"; then
  rm -f "$PLAIN_SNAPSHOT"
  echo "snapshot: saving the snapshot failed" >&2
  exit 1
fi
if [ ! -s "$PLAIN_SNAPSHOT" ]; then
  echo "snapshot: OpenBao wrote no snapshot" >&2
  exit 1
fi
echo "snapshot: saved"
