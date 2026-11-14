#!/bin/sh
# Prints the server argument that adds OpenBao's initial configuration, or nothing. The chart runs
# it for the server's arguments on every start.
#
# Only openbao-0 initialises, and only while neither other member answers. OrderedReady starts the
# others once openbao-0 is Ready, so on the first install neither exists yet. Later a member that
# answers holds the store, and an openbao-0 whose volume is new must join it, not start a second one;
# with its storage in place, openbao-0 would skip the configuration anyway.
# shellcheck disable=SC3028 # the chart sets HOSTNAME in the server's environment to the pod's name.
[ "$HOSTNAME" = openbao-0 ] || exit 0
for member in openbao-1 openbao-2; do
  # bao status exits 0 for an unsealed member, 2 for a sealed one and 1 when nothing answers. Only
  # whether something answers counts, and nothing is sent, so its certificate is not checked.
  BAO_CLIENT_TIMEOUT=5s BAO_MAX_RETRIES=0 bao status -address="https://$member.openbao-internal:8200" \
    -tls-skip-verify > /dev/null 2>&1
  [ "$?" -eq 1 ] || exit 0
done
echo -config=/openbao/userconfig/openbao-initialize/initialize.json
