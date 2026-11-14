#!/bin/sh
# Decides whether this server may initialise OpenBao, and writes the decision to DECISION_FILE for
# the server's arguments (initialize-args.sh): the -config flag of the initial configuration, or
# nothing. The init container initialize-guard runs it before every start of every member.
# Usage: initialize-guard.sh DATA_DIR DECISION_FILE
#
# Only openbao-0 initialises, and only on a first install, which needs positive evidence: its own
# data directory is empty, and the Kubernetes API answers that neither data-openbao-1 nor
# data-openbao-2 exists. The StatefulSet makes those claims when it first starts the other members
# and keeps them for the cluster's life, so either one means the store exists, and an empty
# openbao-0 must join it, never start a second one. When the API gives no answer, for whatever
# reason, the guard fails, and the pod does not start.
set -u
data=$1 decision=$2
: > "$decision" || exit 1
[ "${POD_NAME:-}" = openbao-0 ] || exit 0
if [ ! -d "$data" ]; then
  echo "initialize-guard: $data is not a directory; not initialising" >&2
  exit 1
fi
# A new XFS volume holds nothing; a new ext4 one holds lost+found.
if [ -n "$(ls -A "$data" | grep -vx 'lost+found')" ]; then
  exit 0
fi
if ! claims=$(kubectl get persistentvolumeclaim data-openbao-1 data-openbao-2 --namespace "${POD_NAMESPACE:-}" \
  --ignore-not-found --output name --request-timeout 10s); then
  echo "initialize-guard: no answer from the Kubernetes API on the other members' claims; not initialising" >&2
  exit 1
fi
if [ -n "$claims" ]; then
  echo "initialize-guard: the other members' claims exist, so openbao-0 joins them" >&2
  exit 0
fi
echo "-config=/openbao/userconfig/openbao-initialize/initialize.json" > "$decision"
