#!/bin/bash
# One connection to the Gateway's address in tests/fixtures/edge-forward/scenario.sh, run by socat:
# records the connection's peer and the 28 bytes a PROXY protocol version 2 header for IPv4 takes,
# as hex, in the file BACKEND_LOG, then echoes what the client sends. A connection that sends no
# header, or less, is recorded with what it sent after three seconds.
# The bytes are read one at a time, as a read that takes more would take the client's data with it.
header=$(timeout 3 dd bs=1 count=28 status=none | od -An -v -tx1 | tr -d ' \n')
echo "$SOCAT_PEERADDR $header" >> "$BACKEND_LOG"
exec cat
