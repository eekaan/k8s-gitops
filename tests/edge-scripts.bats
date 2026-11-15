#!/usr/bin/env bats
# Proves the scenarios of features/edge-routers.feature about the edge scripts: edge-check and
# edge-rollout, with the tests of the scripts around them. The scripts run in a copy against
# recording fakes of tofu, ssh and the edge's own commands, so nothing here reaches a cloud or a
# host, no test reads this checkout's .env, and the edges' key is a file in the test's own directory.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$BATS_TEST_TMPDIR/bin"
  HOST_BIN="$BATS_TEST_TMPDIR/host-bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  HOME_DIR="$BATS_TEST_TMPDIR/home"
  HOST="$BATS_TEST_TMPDIR/host"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$BIN" "$HOST_BIN" "$RECORD" "$HOME_DIR/.local/state/k8s-gitops" "$HOST" \
    "$REPO/infra/openstack/stacks/sto2/edge" "$REPO/talos/lab-sto2" "$BATS_TEST_TMPDIR/keys"
  : > "$RECORD/argv"
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp "$ROOT/infra/openstack/backend.hcl" "$REPO/infra/openstack/backend.hcl"
  cp "$ROOT"/infra/openstack/stacks/sto2/edge/*.tf "$REPO/infra/openstack/stacks/sto2/edge/"
  ADDRESS_1=203.0.113.51
  ADDRESS_2=203.0.113.52
  KEY="$BATS_TEST_TMPDIR/keys/edge"
  echo 'fixture private key, never read' > "$KEY"
  echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureEdgePublicKeyFixtureFixtureFix fixture' > "$KEY.pub"
  # The cluster: three workers on the node subnet at host numbers 20, 21 and 22.
  cat > "$REPO/talos/lab-sto2/talman.yaml" << YAML
values:
  nodeSubnet: 192.0.2.0/24
  serviceRange: 203.0.113.16/28
nodes:
  - {hostname: lab-cp-1, role: controlplane, ipAddress: 203.0.113.61}
  - {hostname: lab-w-1, role: worker, ipAddress: 203.0.113.71}
  - {hostname: lab-w-2, role: worker, ipAddress: 203.0.113.72}
  - {hostname: lab-w-3, role: worker, ipAddress: 203.0.113.73}
YAML
  cat > "$BATS_TEST_TMPDIR/outputs.json" << JSON
{"addresses": {"sensitive": true, "value": ["$ADDRESS_1", "$ADDRESS_2"]},
 "names": {"sensitive": false, "value": ["lab-edge-1", "lab-edge-2"]}}
JSON
  # Each edge offers a host key of its own, kept in a file of the fake host, and both are recorded
  # already. A replacement of an edge offers another key at the same address.
  for address in "$ADDRESS_1" "$ADDRESS_2"; do
    echo "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${address//./}Original" > "$HOST/key-$address"
    echo "$address ssh-ed25519 $(cat "$HOST/key-$address")" >> "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  done

  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise < /dev/null
  for tool in jq yq grep flock cat sed; do
    record "$tool"
  done
  # The plan a run saves is plan.json, the change the configuration makes, with the instance of each
  # edge given with -replace replaced as well, and, when the run targets one edge, that edge's part
  # of it only. Once applied, the address of each edge whose instance the saved plan creates, alone
  # or as a replacement, offers a new host key.
  fake tofu << EOF
printf '%s\n' "tofu \$*" >> "$RECORD/argv"
case \${2-} in
  output) cat "$BATS_TEST_TMPDIR/outputs.json" ;;
  show) cat "$RECORD/plan.saved" ;;
  plan)
    targeted=0 forced=()
    for argument; do
      if [[ \$argument =~ ^-target=module\.edge\[\"([12])\"\]\$ ]]; then
        targeted=\${BASH_REMATCH[1]}
      elif [[ \$argument =~ ^-replace=module\.edge\[\"([12])\"\]\.openstack_compute_instance_v2\.this\$ ]]; then
        forced+=("\${BASH_REMATCH[1]}")
      fi
    done
    { [[ -f "$BATS_TEST_TMPDIR/plan.json" ]] && cat "$BATS_TEST_TMPDIR/plan.json" || echo '{}'; } |
      jq --arg targeted "\$targeted" --args '.resource_changes = ([.resource_changes[]?] + [\$ARGS.positional[]
        | {address: "module.edge[\\"\\(.)\\"].openstack_compute_instance_v2.this", mode: "managed",
           type: "openstack_compute_instance_v2", change: {actions: ["delete", "create"]}}]
        | unique_by(.address)
        | map(select(\$targeted == "0" or (.address | startswith("module.edge[\\"" + \$targeted + "\\"]")))))' \
        "\${forced[@]}" > "$RECORD/plan.saved"
    ;;
  apply)
    for number in \$(jq -r '.resource_changes[] | select(.type == "openstack_compute_instance_v2" and (.change.actions | index("create")))
        | .address | capture("^module\\\\.edge\\\\[\"(?<n>[12])\"\\\\]").n' "$RECORD/plan.saved"); do
      case \$number in
        1) echo "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_1//./}Replacement" > "$HOST/key-$ADDRESS_1" ;;
        2) echo "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_2//./}Replacement" > "$HOST/key-$ADDRESS_2" ;;
      esac
    done
    ;;
esac
EOF
  # The three calls the scripts make: a lookup (-F), dropping an address (-R) and the fingerprints
  # (-l) of the keys on standard input, on the unhashed known_hosts file the fake ssh-keyscan feeds.
  fake ssh-keygen << EOF
printf '%s\n' "ssh-keygen \$*" >> "$RECORD/argv"
case \$1 in
  -F) grep -q "^\$2 " "\$4" 2> /dev/null ;;
  -R) grep -v "^\$2 " "\$4" > "\$4.new" || true; mv "\$4.new" "\$4" ;;
  -l) read -r address type key; echo "256 SHA256:\$key \$address (ED25519)" ;;
  *) exit 1 ;;
esac
EOF
  # An ssh that refuses unless host key checking is strict against the recorded keys and the edges'
  # key is the one named, and otherwise runs the command here, as the edge's login shell would, with
  # the fake edge's own commands first on PATH.
  fake ssh << EOF
printf '%s\n' "ssh \$*" >> "$RECORD/argv"
strict= known= identity= only=
while ((\$#)); do
  case \$1 in
    -i) identity=\$2; shift 2 ;;
    -o)
      case \$2 in
        StrictHostKeyChecking=*) strict=\${2#*=} ;;
        UserKnownHostsFile=*) known=\${2#*=} ;;
        IdentitiesOnly=*) only=\${2#*=} ;;
      esac
      shift 2
      ;;
    *) break ;;
  esac
done
[[ \$strict == yes && \$only == yes && \$identity == "$KEY" && -s \$known ]] || { echo "fake ssh: refused" >&2; exit 255; }
case \$1 in
  debian@$ADDRESS_1) edge=1 address=$ADDRESS_1 ;;
  debian@$ADDRESS_2) edge=2 address=$ADDRESS_2 ;;
  *) echo "fake ssh: unexpected destination" >&2; exit 255 ;;
esac
# What strict host key checking does: the recorded key must be the one the host offers.
grep -qx "\$address ssh-ed25519 \$(cat "$HOST/key-\$address")" "\$known" || { echo "fake ssh: REMOTE HOST IDENTIFICATION HAS CHANGED" >&2; exit 255; }
shift
exec env EDGE_FIXTURE="$HOST/edge-\$edge" PATH="$HOST_BIN:\$PATH" bash -c "\$*"
EOF
  # Nothing else may reach a host, a cloud or a container runtime from this machine.
  for tool in scp sftp openstack curl docker; do
    fake "$tool" << EOF
printf '%s\n' "$tool \$*" >> "$RECORD/argv"
echo "unexpected call: $tool \$*" >&2
exit 1
EOF
  done
  # The host keys an address offers, as ssh-keyscan prints them; nothing from an address with none.
  fake ssh-keyscan << EOF
printf '%s\n' "ssh-keyscan \$*" >> "$RECORD/argv"
address=\${*: -1}
[[ -f "$HOST/key-\$address" ]] || exit 1
echo "\$address ssh-ed25519 \$(cat "$HOST/key-\$address")"
EOF
  # What an edge answers: FRR's state and tables, the loaded rules and the kernel's setting.
  host_fake sudo << 'EOF'
[[ $1 == -n ]] && shift
exec "$@"
EOF
  host_fake systemctl << 'EOF'
cat "$EDGE_FIXTURE/frr"
EOF
  host_fake vtysh << 'EOF'
case $2 in
  'show bgp ipv4 unicast summary json') cat "$EDGE_FIXTURE/sessions.json" ;;
  'show bgp ipv4 unicast json') cat "$EDGE_FIXTURE/table.json" ;;
  *) echo "fake vtysh: unexpected $*" >&2; exit 1 ;;
esac
EOF
  host_fake nft << 'EOF'
cat "$EDGE_FIXTURE/rules"
EOF
  host_fake sysctl << 'EOF'
cat "$EDGE_FIXTURE/forwarding"
EOF

  ENVIRONMENT=(
    PATH="$BIN:$PATH"
    HOME="$HOME_DIR"
    XDG_STATE_HOME=
    TF_STATE_BUCKET=fixture-state-bucket
    AWS_ACCESS_KEY_ID=marker-access-key-id
    AWS_SECRET_ACCESS_KEY=marker-secret-access-key
    TF_STATE_PASSPHRASE=marker-state-passphrase
    OS_AUTH_URL=https://identity.example.invalid/v3
    'OPERATOR_CIDRS=["198.51.100.0/24"]'
    EDGE_IMAGE=fixture-image
    EDGE_SSH_KEY_FILE="$KEY"
    EDGE_ROLLOUT_WAIT=0
    EDGE_ROLLOUT_INTERVAL=0
  )
  WORKERS='192.0.2.20 192.0.2.21 192.0.2.22'
}

# fake NAME: a binary first on the scripts' PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# host_fake NAME: a binary first on the fake edge's PATH, its body read from stdin.
host_fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$HOST_BIN/$1"
  chmod +x "$HOST_BIN/$1"
}

# record NAME: puts NAME's arguments in the record, then runs the real NAME.
record() {
  local real
  real=$(command -v "$1")
  fake "$1" << EOF
printf '%s\n' "$1 \$*" >> "$RECORD/argv"
exec "$real" "\$@"
EOF
}

# edge_state NUMBER FRR_STATE SESSIONS PREFIXES [FORWARDING]: what edge NUMBER answers. SESSIONS is
# the addresses of the established sessions and PREFIXES the routes in the table, each with a path
# per session.
edge_state() {
  local dir="$HOST/edge-$1"
  mkdir -p "$dir"
  echo "$2" > "$dir/frr"
  jq -n --arg addresses "$3" '{peers: ($addresses | split(" ") | map(select(. != ""))
    | map({key: ., value: {state: "Established"}}) | from_entries)}' > "$dir/sessions.json"
  jq -n --arg prefixes "$4" --arg addresses "$3" '{routes: ($prefixes | split(" ") | map(select(. != ""))
    | map({key: ., value: ($addresses | split(" ") | map(select(. != "")) | map({valid: true, bestpath: true, multipath: true}))})
    | from_entries)}' > "$dir/table.json"
  printf 'table inet edge\ntable ip edge-nat\n' > "$dir/rules"
  echo "${5:-1}" > "$dir/forwarding"
}

# edge_check [ARG...]: scripts/edge-check in the copy, in the environment above.
edge_check() {
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/edge-check" "$@"
}

# absent GREP_ARG...: fails when grep -q finds a match; the last command of a function, as bats
# ignores a failing ! anywhere else.
absent() {
  ! grep -q "$@"
}

# no_address OUTPUT: fails when OUTPUT holds an IPv4 address.
no_address() {
  ! grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' <<< "$1"
}

@test "edge-check passes with every worker's session established and fails, saying which, when one is missing or a route outside the range is present, and no address is printed" {
  # Both edges complete: three sessions each, and a next hop per session for every Service address.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" "203.0.113.17/32 203.0.113.18/32"
  edge_check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output != *FAIL* ]]
  [[ $output == *"lab-edge-1: 3 of 3 worker sessions are established"* ]]
  [[ $output == *"lab-edge-2: 3 of 3 worker sessions are established"* ]]
  no_address "$output"

  # One worker's session is missing on the second edge: it fails, and says which worker.
  edge_state 2 active "192.0.2.20 192.0.2.22" 203.0.113.17/32
  edge_check
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"pass  lab-edge-1: 3 of 3 worker sessions are established"* ]]
  [[ $output == *"FAIL  lab-edge-2: 2 of 3 worker sessions are established; no session from lab-w-2"* ]]
  no_address "$output"

  # A route outside the range, and a prefix shorter than a /32 inside it, are in the first edge's table.
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  edge_state 1 active "$WORKERS" "203.0.113.17/32 198.51.100.5/32 203.0.113.16/30"
  edge_check
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: 2 of 3 routes in the table are not a /32 inside the service range"* ]]
  [[ $output == *"pass  lab-edge-2: the table holds 1 routes, each a /32 inside the service range"* ]]
  no_address "$output"

  # FRR down, the rules not loaded and forwarding off each fail on their own.
  edge_state 1 inactive "$WORKERS" 203.0.113.17/32 0
  printf 'table inet filter\n' > "$HOST/edge-1/rules"
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: FRR is not running"* ]]
  [[ $output == *"FAIL  lab-edge-1: the nftables rules are not loaded"* ]]
  [[ $output == *"FAIL  lab-edge-1: the kernel does not forward"* ]]
  [[ $output != *lab-edge-2* ]]

  # A route with fewer next hops than sessions is for a person to read, as a local-only Service has.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  jq '.routes["203.0.113.17/32"] |= .[:1]' "$HOST/edge-1/table.json" > "$HOST/edge-1/table.tmp"
  mv "$HOST/edge-1/table.tmp" "$HOST/edge-1/table.json"
  edge_check --edge 1
  [ "$status" -eq 0 ]
  [[ $output == *"skip  lab-edge-1: next hops: 1 of 1 routes have fewer next hops than sessions"* ]]

  # Without the cluster's talman.yaml the checks that need it are skipped, not failed.
  mv "$REPO/talos/lab-sto2/talman.yaml" "$REPO/talos/lab-sto2/talman.moved"
  edge_check --edge 1
  [ "$status" -eq 0 ]
  [[ $output == *"skip  lab-edge-1: sessions:"* && $output == *"skip  lab-edge-1: routes:"* ]]
}

# rollout: scripts/edge-rollout --yes in the copy, the operator typing yes for every host key the
# replaced edges offer.
rollout() {
  run bash -c 'printf "yes\nyes\nyes\nyes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --yes
}

@test "a check of one edge asks nothing about the other edge's host key" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  grep -v "^$ADDRESS_2 " "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts" > "$BATS_TEST_TMPDIR/known"
  cp "$BATS_TEST_TMPDIR/known" "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  edge_check --edge 1 < /dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  absent '^ssh-keyscan ' "$RECORD/argv"
}

# plan_replacing NUMBER...: a plan, as tofu show -json prints it, that replaces the instances of the
# edges named and changes nothing else.
plan_replacing() {
  local numbers
  numbers=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  jq -n --argjson numbers "$numbers" '{resource_changes: [$numbers[] | {
    address: "module.edge[\"\(.)\"].openstack_compute_instance_v2.this",
    mode: "managed", type: "openstack_compute_instance_v2",
    change: {actions: ["delete", "create"]}}]}' > "$BATS_TEST_TMPDIR/plan.json"
}

# steps: the calls that matter to the order, one per line: edge-check, a targeted plan, an apply.
steps() {
  grep -E '^edge-check |^tofu .* plan .*-target=|^tofu .* apply ' "$RECORD/argv" |
    sed -E 's/ -input=false//; s|-chdir=[^ ]*/||; s/ -out=[^ ]*//; s/ -target=openstack_networking_floatingip_associate_v2[^ ]*//; s/ +/ /g; s/^tofu [^ ]* /tofu /; s/^(tofu apply) .*/\1/'
}

@test "A change to the configuration rolls out one edge at a time and stops when the check fails" {
  # The copy's edge-check is a recording fake whose verdict for an edge is the exit status in the
  # file check-<number> in the record's directory, 0 when there is none.
  cat > "$REPO/scripts/edge-check" << EOF
#!/usr/bin/env bash
printf '%s\n' "edge-check \$*" >> "$RECORD/argv"
status=\$(cat "$RECORD/check-\${2-}" 2> /dev/null || echo 0)
[[ \$status == 0 ]] || echo "FAIL  fixture: the check fails"
exit "\$status"
EOF
  chmod +x "$REPO/scripts/edge-check"
  plan_replacing 1 2

  # Applied as it is, a plan that replaces both is refused, and nothing is applied.
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge --yes
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"replaces both edge routers at once"* ]]
  [[ $output == *"just edge-rollout"* ]]
  absent ' apply ' "$RECORD/argv"

  # One edge replaced is applied as any plan is.
  plan_replacing 2
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge --yes
  [ "$status" -eq 0 ]
  grep -q ' apply ' "$RECORD/argv"

  # The rollout replaces the first edge, checks it, and only then replaces the second; and before it
  # replaces an edge it checks the other one.
  plan_replacing 1 2
  : > "$RECORD/argv"
  rollout
  echo "$output"
  [ "$status" -eq 0 ]
  expected=$(printf '%s\n' \
    'edge-check --edge 2' \
    'tofu plan -target=module.edge["1"]' \
    'tofu apply' \
    'edge-check --edge 1' \
    'edge-check --edge 1' \
    'tofu plan -target=module.edge["2"]' \
    'tofu apply' \
    'edge-check --edge 2')
  steps
  [ "$(steps)" = "$expected" ]

  # The first edge fails its check once replaced: the rollout stops, and the second edge is never
  # planned, applied or touched.
  : > "$RECORD/argv"
  echo 1 > "$RECORD/check-1"
  rollout
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"edge 1 does not pass its check"* ]]
  [ "$(grep -c '^tofu .* apply ' "$RECORD/argv")" -eq 1 ]
  absent 'module.edge\["2"\]' "$RECORD/argv"

  # The second edge not serving keeps the first from being replaced at all.
  : > "$RECORD/argv"
  rm "$RECORD/check-1"
  echo 1 > "$RECORD/check-2"
  rollout
  [ "$status" -ne 0 ]
  [[ $output == *"edge 2 does not pass its check, so edge 1 is not replaced"* ]]
  absent ' apply ' "$RECORD/argv"
}

# trail: what the host key handling did, in order, one step per line: an apply, dropping an edge's
# recorded keys, scanning an edge for its keys, and a connection to an edge. EDGE is 1 or 2.
trail() {
  grep -E "^tofu .* apply |^ssh-keygen -R |^ssh-keyscan |^ssh .*@" "$RECORD/argv" |
    sed -E "s/^tofu .*/apply/; s/^ssh-keygen -R $ADDRESS_1 .*/forget 1/; s/^ssh-keygen -R $ADDRESS_2 .*/forget 2/; \
      s/^ssh-keyscan .*$ADDRESS_1\$/scan 1/; s/^ssh-keyscan .*$ADDRESS_2\$/scan 2/; \
      s/^ssh .*@$ADDRESS_1 .*/ssh 1/; s/^ssh .*@$ADDRESS_2 .*/ssh 2/"
}

# recorded NUMBER: the key the known_hosts file holds for edge NUMBER.
recorded() {
  local address=$ADDRESS_1
  [[ $1 == 1 ]] || address=$ADDRESS_2
  grep "^$address " "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts" | awk '{ print $3 }'
}

# original_keys: both edges offer their original host keys again, and those are the ones recorded.
original_keys() {
  local address
  for address in "$ADDRESS_1" "$ADDRESS_2"; do
    echo "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${address//./}Original" > "$HOST/key-$address"
    grep -v "^$address " "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts" > "$BATS_TEST_TMPDIR/known" || true
    echo "$address ssh-ed25519 $(cat "$HOST/key-$address")" >> "$BATS_TEST_TMPDIR/known"
    cp "$BATS_TEST_TMPDIR/known" "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  done
}

@test "a replaced edge offers new host keys at its old address, and the rollout goes on only after they are recorded" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  plan_replacing 1 2
  original_1=$(recorded 1)

  # The operator types yes once per replaced edge, as the fingerprints are shown. edge-check is the
  # real script here: its ssh refuses a host whose key is not the recorded one.
  : > "$RECORD/argv"
  run bash -c 'printf "yes\nyes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"SHA256:AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_1//./}Replacement"* ]]
  [ "$(recorded 1)" = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_1//./}Replacement" ]
  [ "$(recorded 1)" != "$original_1" ]
  [ "$(recorded 2)" = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_2//./}Replacement" ]
  # The first edge's keys are dropped before its replacement, the new ones are scanned and recorded
  # after it, and only then is it connected to; the second edge is not replaced before that.
  expected=$(printf '%s\n' \
    'ssh 2' 'forget 1' 'apply' 'scan 1' 'ssh 1' \
    'ssh 1' 'forget 2' 'apply' 'scan 2' 'ssh 2')
  [ "$(trail)" = "$expected" ]
  no_address "$output"

  # Declined: the first edge's new keys are not recorded, the rollout stops at once, without waiting
  # for an answer that will not change, and the second edge is never touched. The wait is long here,
  # and the clock is a sleep that records how long it was asked to wait and ends the rollout, so one
  # that waited could not hang the test.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  original_keys
  fake sleep << EOF
printf '%s\n' "sleep \$*" >> "$RECORD/argv"
kill -TERM "\$PPID"
EOF
  : > "$RECORD/argv"
  run bash -c 'printf "no\n" | env "$@"' _ "${ENVIRONMENT[@]}" EDGE_ROLLOUT_WAIT=900 EDGE_ROLLOUT_INTERVAL=15 \
    "$REPO/scripts/edge-rollout" --yes
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"edge 1's new SSH host key"*"was not accepted"* ]]
  absent '^sleep ' "$RECORD/argv"
  absent "^ssh .*@$ADDRESS_1 " "$RECORD/argv"
  [ "$(grep -c '^tofu .* apply ' "$RECORD/argv")" -eq 1 ]
  absent 'module.edge\["2"\]' "$RECORD/argv"
  [ "$(recorded 1)" = "" ]
}

@test "an edge whose instance the rollout's plan does not replace keeps its recorded host keys" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  # A change that updates the edges' security group in place and replaces no instance.
  jq -n '{resource_changes: [{address: "openstack_networking_secgroup_rule_v2.ssh[\"0\"]", mode: "managed",
    type: "openstack_networking_secgroup_rule_v2", change: {actions: ["update"]}}]}' > "$BATS_TEST_TMPDIR/plan.json"
  original_1=$(recorded 1) original_2=$(recorded 2)
  : > "$RECORD/argv"
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --yes < /dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(trail)" = "$(printf '%s\n' 'ssh 2' 'apply' 'ssh 1' 'ssh 1' 'apply' 'ssh 2')" ]
  [ "$(recorded 1)" = "$original_1" ]
  [ "$(recorded 2)" = "$original_2" ]
  [[ $output == *"edge 1: applied; its instance was not replaced"* ]]
}

# sequence: what a rollout did, in order, one step per line: every plan with what it targets and
# replaces, a check of an edge, dropping an edge's recorded keys, an apply, and scanning an edge for
# its keys.
sequence() {
  grep -E '^edge-check |^tofu .* plan |^tofu .* apply |^ssh-keygen -R |^ssh-keyscan ' "$RECORD/argv" |
    sed -E "s/^edge-check --edge ([12])$/check \1/; s/^tofu .* apply .*/apply/; \
      s/^tofu [^ ]* plan( -input=false)?( -out=[^ ]*)?/plan/; \
      s/^ssh-keygen -R $ADDRESS_1 .*/forget 1/; s/^ssh-keygen -R $ADDRESS_2 .*/forget 2/; \
      s/^ssh-keyscan .*$ADDRESS_1\$/scan 1/; s/^ssh-keyscan .*$ADDRESS_2\$/scan 2/"
}

# real_edge_check: the copy's edge-check, recorded: the real script runs behind it, so a check
# passes only with every worker's session established, over a connection that holds to the
# recorded keys.
real_edge_check() {
  mv "$REPO/scripts/edge-check" "$REPO/scripts/edge-check.real"
  cat > "$REPO/scripts/edge-check" << EOF
#!/usr/bin/env bash
printf '%s\n' "edge-check \$*" >> "$RECORD/argv"
exec "$REPO/scripts/edge-check.real" "\$@"
EOF
  chmod +x "$REPO/scripts/edge-check"
}

@test "A forced rollout replaces one edge at a time and stops when the check fails" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  # The configuration changed nothing: only the forced replacement replaces anything.
  echo '{"resource_changes": []}' > "$BATS_TEST_TMPDIR/plan.json"
  real_edge_check

  : > "$RECORD/argv"
  run bash -c 'printf "yes\nyes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --replace --yes
  echo "$output"
  [ "$status" -eq 0 ]
  # Each plan that is applied targets one edge and replaces that edge's instance and nothing else;
  # the second edge is planned only once the first one's new keys are recorded and its check passes.
  expected=$(printf '%s\n' \
    'plan' \
    'check 2' \
    'plan -target=module.edge["1"] -target=openstack_networking_floatingip_associate_v2.edge["1"] -replace=module.edge["1"].openstack_compute_instance_v2.this' \
    'forget 1' 'apply' 'scan 1' 'check 1' \
    'check 1' \
    'plan -target=module.edge["2"] -target=openstack_networking_floatingip_associate_v2.edge["2"] -replace=module.edge["2"].openstack_compute_instance_v2.this' \
    'forget 2' 'apply' 'scan 2' 'check 2' \
    'plan')
  sequence
  [ "$(sequence)" = "$expected" ]
  [ "$(recorded 1)" = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_1//./}Replacement" ]
  [ "$(recorded 2)" = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_2//./}Replacement" ]
  [[ $output == *"pass  lab-edge-1: 3 of 3 worker sessions are established"* ]]
  no_address "$output"

  # Once replaced, the first edge has no session from one worker: its check fails, the rollout
  # stops, and the second edge is never planned, applied or touched.
  original_keys
  edge_state 1 active "192.0.2.20 192.0.2.22" 203.0.113.17/32
  : > "$RECORD/argv"
  run bash -c 'printf "yes\nyes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --replace --yes
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: 2 of 3 worker sessions are established; no session from lab-w-2"* ]]
  [[ $output == *"edge 1 does not pass its check"* ]]
  expected=$(printf '%s\n' \
    'plan' \
    'check 2' \
    'plan -target=module.edge["1"] -target=openstack_networking_floatingip_associate_v2.edge["1"] -replace=module.edge["1"].openstack_compute_instance_v2.this' \
    'forget 1' 'apply' 'scan 1' 'check 1')
  [ "$(sequence)" = "$expected" ]
  absent 'edge\["2"\]' "$RECORD/argv"
  [ "$(recorded 2)" = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_2//./}Original" ]
}

# instance_plan NUMBER ACTIONS: a plan, as tofu show -json prints it, whose only change is ACTIONS,
# a JSON list such as ["create"], on the instance of edge NUMBER.
instance_plan() {
  jq -n --arg number "$1" --argjson actions "$2" '{resource_changes: [{
    address: "module.edge[\"\($number)\"].openstack_compute_instance_v2.this", mode: "managed",
    type: "openstack_compute_instance_v2", change: {actions: $actions}}]}' > "$BATS_TEST_TMPDIR/plan.json"
}

@test "infra-apply replaces or deletes one edge only while the other passes its check" {
  real_edge_check
  edge_state 1 inactive "" "" 0
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  original_2=$(recorded 2)
  # Edge 1 does not serve: a plan that replaces edge 2, or deletes it, would leave none serving.
  for actions in '["delete", "create"]' '["delete"]'; do
    instance_plan 2 "$actions"
    : > "$RECORD/argv"
    run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge --yes < /dev/null
    echo "$output"
    [ "$status" -ne 0 ]
    [[ $output == *"edge 1 does not pass its check, so the plan that takes edge 2 down is not applied"* ]]
    [[ $output == *"just edge-rollout --replace --edge 2 --other-down"* ]]
    grep -qx 'edge-check --edge 1' "$RECORD/argv"
    absent '^tofu .* apply ' "$RECORD/argv"
    [ "$(recorded 2)" = "$original_2" ]
  done

  # Once edge 1 serves, the plan is applied, after edge 1's check.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  instance_plan 2 '["delete", "create"]'
  : > "$RECORD/argv"
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge --yes < /dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(sequence | grep -v '^plan$')" = "$(printf '%s\n' 'check 1' 'forget 2' 'apply')" ]

  # A plan that only creates edge 2, gone from the cloud, takes nothing down and needs no check.
  edge_state 1 inactive "" "" 0
  instance_plan 2 '["create"]'
  : > "$RECORD/argv"
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge --yes < /dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  absent '^edge-check ' "$RECORD/argv"
}

@test "an edge whose instance a plan creates has its recorded host keys dropped, and new ones recorded" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  original_1=$(recorded 1)
  # Edge 2's instance is gone from the cloud: the refreshed plan creates it, and deletes nothing.
  instance_plan 2 '["create"]'
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge --yes < /dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(trail)" = "$(printf '%s\n' 'forget 2' 'apply')" ]
  [ "$(recorded 2)" = "" ]
  [ "$(recorded 1)" = "$original_1" ]
  [[ $output == *"edge 2's SSH host keys are no longer recorded"* ]]
  # The new instance's keys are shown and recorded once yes is typed, and its check passes.
  run bash -c 'printf "yes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-check" --edge 2
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(recorded 2)" = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_2//./}Replacement" ]

  # The rollout does the same for an edge its plan only creates: the old keys go before the apply
  # and the new ones are recorded before the edge's check.
  original_keys
  : > "$RECORD/argv"
  run bash -c 'printf "yes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(trail)" = "$(printf '%s\n' 'ssh 2' 'apply' 'ssh 1' 'ssh 1' 'forget 2' 'apply' 'scan 2' 'ssh 2')" ]
  [ "$(recorded 2)" = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_2//./}Replacement" ]
}

@test "destroying the edge stack drops the edges' recorded host keys" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  echo "198.51.100.200 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOfAnotherHost" >> "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  echo '{"resource_changes": []}' > "$BATS_TEST_TMPDIR/plan.json"
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-destroy" sto2/edge --yes < /dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(recorded 1)" = "" ]
  [ "$(recorded 2)" = "" ]
  grep -q '^198.51.100.200 ' "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  [[ $output == *"the edges' SSH host keys are no longer recorded"* ]]
  no_address "$output"
}

@test "edge-rollout --replace --edge replaces the one edge named, and with the other down only once that is typed back" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  echo '{"resource_changes": []}' > "$BATS_TEST_TMPDIR/plan.json"
  real_edge_check
  : > "$RECORD/argv"
  run bash -c 'printf "yes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --replace --edge 2 --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(sequence)" = "$(printf '%s\n' \
    'plan' \
    'check 1' \
    'plan -target=module.edge["2"] -target=openstack_networking_floatingip_associate_v2.edge["2"] -replace=module.edge["2"].openstack_compute_instance_v2.this' \
    'forget 2' 'apply' 'scan 2' 'check 2' \
    'plan')" ]
  absent 'edge\["1"\]' "$RECORD/argv"

  # Edge 1 is down as well: edge 2 is not replaced, and the run names the way to do it anyway.
  original_keys
  edge_state 1 inactive "" "" 0
  : > "$RECORD/argv"
  run bash -c 'printf "yes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --replace --edge 2 --yes
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"edge 1 does not pass its check, so edge 2 is not replaced"* ]]
  [[ $output == *"--other-down"* ]]
  absent '^tofu .* apply ' "$RECORD/argv"

  # --other-down asks for the sentence that names both edges, --yes or not; anything else stops it.
  : > "$RECORD/argv"
  run bash -c 'printf "yes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --replace --edge 2 --other-down --yes
  echo "$output"
  [ "$status" -ne 0 ]
  absent '^tofu .* apply ' "$RECORD/argv"
  [ "$(recorded 2)" = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_2//./}Original" ]

  : > "$RECORD/argv"
  run bash -c 'printf "replace edge 2 with edge 1 down\nyes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --replace --edge 2 --other-down --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(sequence)" = "$(printf '%s\n' \
    'plan' \
    'check 1' \
    'plan -target=module.edge["2"] -target=openstack_networking_floatingip_associate_v2.edge["2"] -replace=module.edge["2"].openstack_compute_instance_v2.this' \
    'forget 2' 'apply' 'scan 2' 'check 2' \
    'plan')" ]

  # --other-down replaces one named edge only.
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --replace --other-down --yes < /dev/null
  [ "$status" -eq 2 ]
}

@test "applying a plan that replaces one edge drops its recorded host keys and no other edge's" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  plan_replacing 2
  original_1=$(recorded 1)
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge --yes
  echo "$output"
  [ "$status" -eq 0 ]
  # Edge 1 is checked over its connection first, as the plan takes edge 2 down.
  [ "$(trail)" = "$(printf '%s\n' 'ssh 1' 'forget 2' 'apply')" ]
  [ "$(recorded 2)" = "" ]
  [ "$(recorded 1)" = "$original_1" ]
  no_address "$output"

  # Deleting both instances outright leaves none serving as much as replacing both does.
  plan_replacing 1 2
  jq '.resource_changes[].change.actions = ["delete"]' "$BATS_TEST_TMPDIR/plan.json" > "$BATS_TEST_TMPDIR/plan.tmp"
  mv "$BATS_TEST_TMPDIR/plan.tmp" "$BATS_TEST_TMPDIR/plan.json"
  : > "$RECORD/argv"
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge --yes
  [ "$status" -ne 0 ]
  [[ $output == *"both edge routers"* ]]
  absent ' apply ' "$RECORD/argv"
}

@test "the edge key is made once, at the path .env names, mode 0600, and nothing but that is printed" {
  rm "$KEY" "$KEY.pub"
  # An ssh-keygen that makes the two files, as the real one does, and records its arguments.
  fake ssh-keygen << EOF
printf '%s\n' "ssh-keygen \$*" >> "$RECORD/argv"
file=\${*: -1}
printf 'fixture private key\n' > "\$file"
chmod 600 "\$file"
printf 'ssh-ed25519 fixture\n' > "\$file.pub"
EOF
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/edge-ssh-key"
  [ "$status" -eq 0 ]
  [ "$output" = "created the edge routers' SSH key pair" ]
  [ "$(stat -c %a "$KEY")" = 600 ]
  [ "$(grep -c '^ssh-keygen ' "$RECORD/argv")" -eq 1 ]

  run env "${ENVIRONMENT[@]}" "$REPO/scripts/edge-ssh-key"
  [ "$status" -eq 0 ]
  [ "$output" = "the edge routers' SSH key pair exists; nothing was created" ]
  [ "$(grep -c '^ssh-keygen ' "$RECORD/argv")" -eq 1 ]

  # A relative path is refused, and so is a name that is not set.
  run env "${ENVIRONMENT[@]}" EDGE_SSH_KEY_FILE=relative/key "$REPO/scripts/edge-ssh-key"
  [ "$status" -ne 0 ]
  run env "${ENVIRONMENT[@]}" EDGE_SSH_KEY_FILE= "$REPO/scripts/edge-ssh-key"
  [ "$status" -ne 0 ]
  [[ $output == *EDGE_SSH_KEY_FILE* ]]
}

@test "edge-routes prints to a terminal only" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  # Not a terminal: standard output is the pipe bats captures.
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/edge-routes"
  [ "$status" -ne 0 ]
  [[ $output == *"not a terminal"* ]]
  # CI set: refused whatever standard output is.
  run env "${ENVIRONMENT[@]}" CI=true "$REPO/scripts/edge-routes"
  [ "$status" -ne 0 ]
  [[ $output == *"CI is set"* ]]
  absent '^ssh ' "$RECORD/argv"
}

@test "the edge stack's public ports default to the cluster stack's service ports" {
  # The workers admit the service ports from the edges, and the edges forward the public ports.
  edge=$(yq -p hcl -o json "$ROOT/infra/openstack/stacks/sto2/edge/variables.tf" | jq -c '.variable.public_ports.default')
  cluster=$(yq -p hcl -o json "$ROOT/infra/openstack/stacks/sto2/cluster/variables.tf" | jq -c '.variable.service_ports.default')
  [ "$edge" = "$cluster" ]
}

@test "the edge stack's workers' block starts where the cluster stack numbers its workers" {
  # The edges take BGP sessions from the block that starts at the first worker's host number; the
  # cluster stack's nodes module puts its workers there.
  edge=$(yq -p hcl -o json "$ROOT/infra/openstack/stacks/sto2/edge/variables.tf" | jq -c '.variable.worker_first_host.default')
  cluster=$(yq -p hcl -o json "$ROOT/infra/openstack/modules/talos-nodes/variables.tf" | jq -c '.variable.worker_first_host.default')
  [[ $cluster =~ ^[0-9]+$ ]]
  [ "$edge" = "$cluster" ]
}

# first_boot: the edge stack's first-boot script, run here with the edge's file system under
# EDGE_ROOT, a directory of the test's, and fakes of the system's commands first on PATH. The fake
# vtysh's dry run refuses a file with a command FRR does not have, as FRR's does
# (tests/fixtures/edge-policy/proof.sh checks that of FRR's own).
first_boot() {
  local root="$BATS_TEST_TMPDIR/edge-root" bin="$BATS_TEST_TMPDIR/edge-bin" tool
  mkdir -p "$root/etc/edge" "$root/dev" "$root/var/log" "$bin"
  printf 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"\nVERSION_CODENAME=trixie\n' > "$root/etc/os-release"
  : > "$root/dev/console"
  for tool in apt-get sysctl nft systemctl sleep; do
    cat > "$bin/$tool" << EOF
#!/usr/bin/env bash
printf '%s\n' "$tool \$*" >> "$RECORD/argv"
EOF
  done
  cat > "$bin/install" << EOF
#!/usr/bin/env bash
printf '%s\n' "install \$*" >> "$RECORD/argv"
mkdir -p "\$(dirname "\${*: -1}")"
cp "\${@: -2:1}" "\${*: -1}"
EOF
  cat > "$bin/vtysh" << EOF
#!/usr/bin/env bash
printf '%s\n' "vtysh \$*" >> "$RECORD/argv"
if [[ \$1 == -C ]] && grep -qx 'no-such-command' "\$3"; then
  echo "line 2: % Unknown command: no-such-command"
  exit 2
fi
EOF
  chmod +x "$bin"/*
  run env EDGE_ROOT="$root" PATH="$bin:$PATH" bash "$ROOT/infra/openstack/stacks/sto2/edge/first-boot.sh"
}

@test "the first boot starts FRR only once FRR's dry run accepts its file, and fails saying why otherwise" {
  local root="$BATS_TEST_TMPDIR/edge-root" steps
  mkdir -p "$root/etc/edge"
  for file in daemons nftables.conf sysctl.conf; do
    echo "fixture $file" > "$root/etc/edge/$file"
  done
  printf 'router bgp 64497\nexit\n' > "$root/etc/edge/frr.conf"
  first_boot
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"edge-first-boot: done"* ]]
  # The check of FRR's file, as it was put in place, comes before FRR is started.
  steps=$(grep -nE "^vtysh -C -f $root/etc/frr/frr.conf\$|^systemctl restart frr\$" "$RECORD/argv" | cut -d: -f2-)
  [ "$steps" = "$(printf '%s\n' "vtysh -C -f $root/etc/frr/frr.conf" 'systemctl restart frr')" ]

  # A file FRR refuses: the first boot fails, says why on the console and in the log, and FRR is
  # neither enabled nor restarted with it.
  printf 'router bgp 64497\nno-such-command\nexit\n' > "$root/etc/edge/frr.conf"
  : > "$RECORD/argv"
  first_boot
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"edge-first-boot: FRR's dry run refuses /etc/frr/frr.conf"* ]]
  [[ $output == *"Unknown command: no-such-command"* ]]
  grep -q "FRR's dry run refuses /etc/frr/frr.conf" "$root/dev/console"
  grep -q "FRR's dry run refuses /etc/frr/frr.conf" "$root/var/log/edge-first-boot.log"
  absent -E '^systemctl (enable|restart) frr' "$RECORD/argv"
}
