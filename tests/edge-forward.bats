#!/usr/bin/env bats
# Proves the scenarios of features/edge-routers.feature about what an edge does with a client's
# connection: the edge stack's rendered nftables rules and proxy configuration, loaded into a
# network namespace of their own inside a user namespace (unshare -r -n -m), with a client, a worker
# that holds the Gateway's address and the cloud's router in namespaces beside it
# (tests/fixtures/edge-forward/scenario.sh). Each file is rendered by
# tests/fixtures/edge-forward/render.sh, which fails, with what tofu said, when a template does not
# render.
# The two tests in the namespaces look for the programs of NEEDED on PATH and for unprivileged user
# namespaces with networks and mounts of their own, and skip, saying which, on a host without one of
# them. The check needs haproxy on PATH. The edges run HAProxy 3.0, Debian 13's; the check takes
# whichever haproxy is there and does not compare its version, so a pass is a pass with that one,
# and one that refuses the rendered configuration fails the test with what it printed.
# The CI containers refuse unshare, so those two tests are tagged namespace, left out of just test,
# and run with just edge-forward-check on a developer's machine; the file's other tests need none of
# those programs but tofu and run everywhere. Nothing here reaches a network outside the namespaces.

# The tests run one at a time even where bats runs a file's tests side by side: a render holds the
# state lock in tests/fixtures/edge-forward while tofu console runs, so a second render at the same
# time fails on the lock.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

# The programs the tests in the namespaces look for on PATH before they run. The comment of the
# recipe edge-forward-check and docs/infrastructure.md name the same ones, which a test below holds
# them to.
NEEDED=(unshare nft ip ss socat haproxy tofu)

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RENDER="$ROOT/tests/fixtures/edge-forward/render.sh"
}

# in_namespaces: skips the test, saying which, unless every program of NEEDED is on PATH and the
# host allows an unprivileged user namespace with a network and mounts of its own.
in_namespaces() {
  local tool
  for tool in "${NEEDED[@]}"; do
    type -P "$tool" > /dev/null || skip "$tool is not on PATH"
  done
  unshare -r -n -m true 2> /dev/null || skip "this host refuses unprivileged user namespaces with a network and mounts of their own"
}

# reading NAME: the value the scenario printed for NAME.
reading() {
  sed -n "s/^$1=//p" <<< "$output"
}

# scenario MODE: runs the scenario script in its namespaces with the edge stack's rendered rules
# and proxy configuration, and leaves what it printed in $output. A file that does not render fails
# the test here, with what tofu said.
scenario() {
  "$RENDER" nftables_conf "$BATS_TEST_TMPDIR/edge.nft"
  "$RENDER" haproxy_conf "$BATS_TEST_TMPDIR/haproxy.cfg"
  run timeout 90 unshare -r -n -m bash "$ROOT/tests/fixtures/edge-forward/scenario.sh" "$1" "$BATS_TEST_TMPDIR/edge.nft" "$BATS_TEST_TMPDIR/haproxy.cfg"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(reading rules)" = loaded ]
  [ "$(reading proxy)" = listening ]
}

# fake_tofu: a tofu first on PATH in place of the real one, its body read from stdin.
fake_tofu() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  { echo '#!/usr/bin/env bash'; cat; } > "$BATS_TEST_TMPDIR/bin/tofu"
  chmod +x "$BATS_TEST_TMPDIR/bin/tofu"
}

# refused LOCAL FILE: the render that just ran failed, naming LOCAL, and FILE is not there.
refused() {
  [ "$status" -eq 1 ]
  [[ $output == "render.sh: tofu did not render local.$1 as one quoted base64 string; what it printed on standard error:"* ]]
  [ ! -e "$2" ]
}

# paragraph FILE START: the paragraph of FILE that starts with START, on one line, without the
# backticks that mark code.
paragraph() {
  awk -v start="$2" 'index($0, start) == 1 { found = 1 } found && /^$/ { exit } found' "$1" | tr -d '`' | paste -sd' ' -
}

# needed_in TEXT: the programs TEXT says are needed on PATH, where it first lists some between
# "needs" and "on PATH", separated by spaces.
needed_in() {
  grep -o '[Nn]eeds [a-z, -]* on PATH' <<< "$1" | head -n 1 | sed 's/^[Nn]eeds //; s/ on PATH$//; s/,//g; s/ and / /'
}

# bats test_tags=namespace
@test "An edge answers a client's connection to a public port through its proxy and names the client's address to the Gateway in a PROXY protocol header" {
  local expected
  in_namespaces
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
  in_namespaces
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

@test "A template that does not render fails the forward check where it is rendered, with what tofu said" {
  local copy="$BATS_TEST_TMPDIR/copy" out="$BATS_TEST_TMPDIR/out" stack=infra/openstack/stacks/sto2/edge
  mkdir "$out"

  # The fixture as it is renders both files: the rules with the fixture's table and its guard for
  # the Gateway's address, and the proxy's configuration with its listener and its header.
  run "$RENDER" nftables_conf "$out/edge.nft"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(head -n 1 "$out/edge.nft")" = "flush ruleset" ]
  grep -qx 'table inet edge {' "$out/edge.nft"
  grep -q '^    ip daddr 203\.0\.113\.21 rt ip nexthop != { .* } reject$' "$out/edge.nft"
  run "$RENDER" haproxy_conf "$out/haproxy.cfg"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qx '    bind 192\.0\.2\.7:80' "$out/haproxy.cfg"
  grep -qx '    server gateway 203\.0\.113\.21:80 send-proxy-v2 source 192\.0\.2\.7' "$out/haproxy.cfg"

  # The real tofu on a copy of the fixture beside a stack whose proxy template is absent: tofu
  # console exits 0 for a local it cannot evaluate. The render fails, names the local, and shows why,
  # in tofu's words; no file is written, and one a render before it left is gone.
  mkdir -p "$copy/tests/fixtures" "$copy/$stack"
  cp -R "$ROOT/tests/fixtures/edge-forward" "$copy/tests/fixtures/edge-forward"
  cp "$ROOT/$stack/nftables.conf.tftpl" "$copy/$stack/"
  run "$copy/tests/fixtures/edge-forward/render.sh" haproxy_conf "$out/haproxy.cfg"
  echo "$output"
  refused haproxy_conf "$out/haproxy.cfg"
  [[ $output == *"Invalid function argument"* ]]
  [[ $output == *"no file exists at"*"haproxy.cfg.tftpl"* ]]
  # The other local of that copy evaluates, and tofu says beside it that some expressions may
  # produce unexpected results: more than the one string, so not a render either.
  run "$copy/tests/fixtures/edge-forward/render.sh" nftables_conf "$out/edge.nft"
  echo "$output"
  refused nftables_conf "$out/edge.nft"
  [[ $output == *"no file exists at"*"haproxy.cfg.tftpl"* ]]

  # A tofu that exits 0 and prints what the console prints for a value it does not know.
  fake_tofu << 'EOF'
echo "fake tofu: the diagnostic of a local that does not evaluate" >&2
echo
echo "(known after apply)"
EOF
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" "$RENDER" haproxy_conf "$out/haproxy.cfg"
  echo "$output"
  refused haproxy_conf "$out/haproxy.cfg"
  [[ $output == *"fake tofu: the diagnostic of a local that does not evaluate"* ]]

  # A tofu that exits non-zero, though what it printed is a quoted base64 string.
  fake_tofu << 'EOF'
echo "fake tofu: failed" >&2
echo '"Zmx1c2ggcnVsZXNldAo="'
exit 1
EOF
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" "$RENDER" nftables_conf "$out/edge.nft"
  echo "$output"
  refused nftables_conf "$out/edge.nft"
  [[ $output == *"fake tofu: failed"* ]]

  # Without both arguments nothing is rendered.
  run "$RENDER" nftables_conf
  [ "$status" -eq 2 ]
  [[ $output == *"usage: render.sh LOCAL FILE"* ]]
}

@test "the forward check's recipe comment and its documentation name every tool its tests look for" {
  local comment documented
  comment=$(grep -B1 '^edge-forward-check:' "$ROOT/justfile" | head -n 1)
  [[ $comment == '# '* ]]
  # shellcheck disable=SC2016 # The backticks are the docs' own.
  documented=$(paragraph "$ROOT/docs/infrastructure.md" '`just edge-forward-check` proves')
  echo "the recipe's comment names: $(needed_in "$comment")"
  echo "the documentation names: $(needed_in "$documented")"
  # The same programs, in the order the tests look for them, and no other.
  [ "$(needed_in "$comment")" = "${NEEDED[*]}" ]
  [ "$(needed_in "$documented")" = "${NEEDED[*]}" ]
  # And the namespaces the host must allow.
  [[ $comment == *"unprivileged user namespaces with networks and mounts of their own"* ]]
  [[ $documented == *"unprivileged user namespaces with networks and mounts of their own"* ]]
}

@test "the forward check's documentation says of haproxy what this file's header says" {
  local header said documented
  # The header: the comment lines the file starts with, after its first line, on one line.
  header=$(awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$BATS_TEST_FILENAME" | paste -sd' ' -)
  said=$(grep -o 'The check needs haproxy on PATH\..*with what it printed\.' <<< "$header")
  echo "$said"
  [ -n "$said" ]
  # shellcheck disable=SC2016 # The backticks are the docs' own.
  documented=$(paragraph "$ROOT/docs/infrastructure.md" '`just edge-forward-check` proves')
  [[ $documented == *"$said"* ]]
  # Neither names the version anywhere else, as one the check would ask for, nor says what a newer
  # one reads.
  [ "$(grep -o '\b3\.0\b' <<< "$header" | wc -l)" -eq 1 ]
  [ "$(grep -o '\b3\.0\b' <<< "$documented" | wc -l)" -eq 1 ]
  [[ $header != *newer* && $documented != *newer* ]]
}
