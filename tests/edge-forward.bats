#!/usr/bin/env bats
# Proves the scenarios of features/edge-routers.feature about what an edge does with a client's
# connection: the edge stack's rendered nftables rules and proxy configuration, loaded into a
# network namespace of their own inside a user namespace (unshare -r -n -m), with a client, a worker
# that holds the Gateway's address and the cloud's router in namespaces beside it
# (tests/fixtures/edge-forward/scenario.sh). It needs unprivileged user namespaces with networks
# and mounts of their own, and nft, ip, ss, socat and HAProxy (the proxy the edge's image packages;
# a newer one on the machine reads the same configuration); a host without them skips it, saying
# which. The CI containers refuse unshare, so it is tagged namespace, left out of just test, and run
# with just edge-forward-check on a developer's machine. Nothing here reaches a network outside the
# namespaces.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  local tool
  for tool in unshare nft ip ss socat haproxy tofu; do
    type -P "$tool" > /dev/null || skip "$tool is not on PATH"
  done
  unshare -r -n -m true 2> /dev/null || skip "this host refuses unprivileged user namespaces with a network and mounts of their own"
}

# reading NAME: the value the scenario printed for NAME.
reading() {
  sed -n "s/^$1=//p" <<< "$output"
}

# scenario MODE: runs the scenario script in its namespaces with the edge stack's rendered rules
# and proxy configuration, and leaves what it printed in $output.
scenario() {
  local encoded file
  for file in nftables_conf:edge.nft haproxy_conf:haproxy.cfg; do
    encoded=$(tofu -chdir="$ROOT/tests/fixtures/edge-forward" console -no-color <<< "base64encode(local.${file%%:*})")
    base64 -d <<< "${encoded//\"/}" > "$BATS_TEST_TMPDIR/${file##*:}"
  done
  run timeout 90 unshare -r -n -m bash "$ROOT/tests/fixtures/edge-forward/scenario.sh" "$1" "$BATS_TEST_TMPDIR/edge.nft" "$BATS_TEST_TMPDIR/haproxy.cfg"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(reading rules)" = loaded ]
  [ "$(reading proxy)" = listening ]
}

# bats test_tags=namespace
@test "An edge answers a client's connection to a public port through its proxy and names the client's address to the Gateway in a PROXY protocol header" {
  local expected
  scenario proxy
  # The client's connection is answered, and the server on the Gateway's address was connected to
  # once, from the edge's own address, which a worker answers straight back to.
  [ "$(reading reply)" = one ]
  [ "$(reading backend_connections)" = 1 ]
  [ "$(reading backend_peer)" = 192.0.2.7 ]
  # Its header: the 12 bytes that open one, version 2 and the proxy command, IPv4 over TCP, 12 bytes
  # of addresses; the client's address (198.51.100.10) and the address it connected to (192.0.2.7),
  # the client's port (40001) and the public port (80).
  expected=0d0a0d0a000d0a515549540a2111000cc633640ac00002079c410050
  [ "$(reading header)" = "$expected" ]
  # The proxy's log names the client.
  [ "$(reading proxy_logged_client)" -ge 1 ]
  # A port that is not listed, though a server listens on it, the edge's other address and the
  # Gateway's address through the edge get no answer, and nothing of them reaches the Gateway's
  # server, the worker or the router: the proxy's connection is the only one.
  [ -z "$(reading unlisted_port_answer)" ]
  [ -z "$(reading other_address_answer)" ]
  [ -z "$(reading gateway_through_edge_answer)" ]
  [ "$(reading backend_connections_after)" = 1 ]
  [ "$(reading from_client_to_worker)" = 0 ]
  [ "$(reading router_toward_gateway)" = 0 ]
}

# bats test_tags=namespace
@test "An edge that loses its routes to the Gateway fails connections fast and recovers without a restart" {
  scenario routes
  # Through a worker's /32 the connection is answered, and nothing goes to the router.
  [ "$(reading reply_through_worker)" = one ]
  [ "$(reading router_through_worker)" = 0 ]
  # Once the worker's route is gone, as when FRR stops, what the established connection sends
  # reaches the router no more than a new connection does, with the default route or with no route
  # at all, and a new connection is closed, unanswered, within a second and a half, not left to wait
  # for the proxy's timeout.
  [ "$(reading router_established_default_only)" = 0 ]
  [ -z "$(reading new_default_only_answer)" ]
  [ "$(reading new_default_only_ms)" -lt 1500 ]
  [ "$(reading router_new_default_only)" = 0 ]
  [ -z "$(reading new_no_route_answer)" ]
  [ "$(reading new_no_route_ms)" -lt 1500 ]
  [ "$(reading router_new_no_route)" = 0 ]
  # With the route back a new connection is answered, by the proxy that ran throughout.
  [ "$(reading reply_route_back)" = five ]
  [ "$(reading router_route_back)" = 0 ]
  [ "$(reading proxy_still_running)" = yes ]
}
