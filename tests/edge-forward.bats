#!/usr/bin/env bats
# Proves the scenario of features/edge-routers.feature about what an edge forwards: the edge stack's
# rendered nftables rules, loaded by nft into a network namespace of their own inside a user
# namespace (unshare -r -n -m), with a client, a worker and the cloud's router in namespaces beside
# it (tests/fixtures/edge-forward/scenario.sh). It needs unprivileged user namespaces with networks
# and mounts of their own, and nft, ip and socat; a host without them skips it, saying which. The
# CI containers refuse unshare, so it is tagged namespace, left out of just test, and run with just
# edge-forward-check on a developer's machine. Nothing here reaches a network outside the namespaces.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  local tool
  for tool in unshare nft ip socat tofu; do
    type -P "$tool" > /dev/null || skip "$tool is not on PATH"
  done
  unshare -r -n -m true 2> /dev/null || skip "this host refuses unprivileged user namespaces with a network and mounts of their own"
}

# reading NAME: the value the scenario printed for NAME.
reading() {
  sed -n "s/^$1=//p" <<< "$output"
}

# bats test_tags=namespace
@test "A translated connection leaves an edge only through a worker's route, new or established" {
  local encoded
  encoded=$(tofu -chdir="$ROOT/tests/fixtures/edge-forward" console -no-color <<< 'base64encode(local.nftables_conf)')
  base64 -d <<< "${encoded//\"/}" > "$BATS_TEST_TMPDIR/edge.nft"

  run timeout 90 unshare -r -n -m bash "$ROOT/tests/fixtures/edge-forward/scenario.sh" "$BATS_TEST_TMPDIR/edge.nft"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(reading rules)" = loaded ]
  # Through a worker's /32 the connection is answered, and nothing goes to the router.
  [ "$(reading reply_through_worker)" = one ]
  [ "$(reading router_through_worker)" = 0 ]
  # Once the worker's route is gone, as when FRR stops, the established connection sends nothing to
  # the router, and neither does a new one, with the default route or with no route at all.
  [ "$(reading router_established_default_only)" = 0 ]
  [ "$(reading router_new_default_only)" = 0 ]
  [ "$(reading router_new_no_route)" = 0 ]
  # With the route back, a new connection is answered again.
  [ "$(reading reply_route_back)" = five ]
  [ "$(reading router_route_back)" = 0 ]
}
