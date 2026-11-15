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
  # The cluster: three workers with their own addresses on the node subnet, the second of them away
  # from host number 21, where a worker numbered after the first would be: the check reads each
  # worker's address from talman.yaml rather than working it out from its name.
  cat > "$REPO/talos/lab-sto2/talman.yaml" << YAML
values:
  nodeSubnet: 192.0.2.0/24
  serviceRange: 203.0.113.16/28
  bgp: {gatewayAddress: 203.0.113.21}
nodes:
  - {hostname: lab-cp-1, role: controlplane, ipAddress: 203.0.113.61, values: {privateAddress: 192.0.2.10}}
  - {hostname: lab-w-1, role: worker, ipAddress: 203.0.113.71, values: {privateAddress: 192.0.2.20}}
  - {hostname: lab-w-2, role: worker, ipAddress: 203.0.113.72, values: {privateAddress: 192.0.2.30}}
  - {hostname: lab-w-3, role: worker, ipAddress: 203.0.113.73, values: {privateAddress: 192.0.2.22}}
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
  'show running-config') cat "$EDGE_FIXTURE/config" ;;
  *) echo "fake vtysh: unexpected $*" >&2; exit 1 ;;
esac
EOF
  host_fake nft << 'EOF'
case $* in
  'list tables') cat "$EDGE_FIXTURE/rules" ;;
  'list chain inet edge forward') cat "$EDGE_FIXTURE/forward" ;;
  *) echo "fake nft: unexpected $*" >&2; exit 1 ;;
esac
EOF
  host_fake sysctl << 'EOF'
cat "$EDGE_FIXTURE/forwarding"
EOF
  host_fake ip << 'EOF'
case $* in
  '-4 -o route show type unreachable') cat "$EDGE_FIXTURE/unreachable" ;;
  '-4 -o route show default') cat "$EDGE_FIXTURE/default" ;;
  *) echo "fake ip: unexpected $*" >&2; exit 1 ;;
esac
EOF
  host_fake apt-config << 'EOF'
[[ $* == 'dump APT::Periodic::Unattended-Upgrade' ]] || { echo "fake apt-config: unexpected $*" >&2; exit 1; }
cat "$EDGE_FIXTURE/upgrades"
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
  WORKERS='192.0.2.20 192.0.2.30 192.0.2.22'
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
  # FRR's configuration with its reject route for the service range, the kernel's route from it, the
  # forward chain that admits a translated connection only through a worker, and no unattended
  # upgrades.
  printf 'router bgp 64497\nexit\nip route 203.0.113.16/28 reject\n' > "$dir/config"
  echo 'unreachable 203.0.113.16/28 proto static metric 20' > "$dir/unreachable"
  forward_chain '192.0.2.20-192.0.2.99' first > "$dir/forward"
  echo 'default via 192.0.2.1 dev ens3 proto dhcp src 192.0.2.7 metric 100' > "$dir/default"
  echo 'APT::Periodic::Unattended-Upgrade "0";' > "$dir/upgrades"
}

# forward_chain SET ORDER [GATEWAY]: the forward chain as nft lists it once loaded, its guard's set
# SET, as nft writes the workers' block, and the rule that drops what does not go through a worker
# first, ahead of what belongs to a connection, or last, after it, or none.
forward_chain() {
  local drop="ip daddr ${3:-203.0.113.21} ct direction original ct status dnat rt ip nexthop != { $1 } drop"
  printf 'table inet edge {\n\tchain forward {\n\t\ttype filter hook forward priority filter; policy drop;\n'
  [[ $2 != first ]] || printf '\t\t%s\n' "$drop"
  printf '\t\tct state established,related accept\n\t\tct state invalid drop\n'
  [[ $2 != last ]] || printf '\t\t%s\n' "$drop"
  printf '\t\tip daddr %s tcp dport { 80, 443 } ct state new ct status dnat rt ip nexthop { %s } accept\n\t}\n}\n' "${3:-203.0.113.21}" "$1"
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

@test "edge-check fails when what keeps a translated connection from the cloud's router is missing, or unattended upgrades are on" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_check --edge 1
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"pass  lab-edge-1: the service range is unreachable on the edge but through a worker's route"* ]]
  [[ $output == *"pass  lab-edge-1: the forward chain sends a translated connection, new or established, toward the Gateway only through a worker"* ]]
  [[ $output == *"pass  lab-edge-1: unattended upgrades are off"* ]]

  # FRR runs its package's defaults, as after a first boot that failed: no reject route is configured.
  printf 'frr defaults traditional\n' > "$HOST/edge-1/config"
  : > "$HOST/edge-1/unreachable"
  edge_check --edge 1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: FRR's configuration holds no reject route for the service range"* ]]

  # Configured, but not in the kernel, as while FRR is stopped.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  : > "$HOST/edge-1/unreachable"
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: the service range's reject route is not in the kernel"* ]]

  # A reject route for another range than the cluster's service range.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  printf 'ip route 198.51.100.0/28 reject\n' > "$HOST/edge-1/config"
  echo 'unreachable 198.51.100.0/28 proto static metric 20' > "$HOST/edge-1/unreachable"
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: FRR's reject route is not for the cluster's service range"* ]]

  # The forward chain's guard, by the rules' content: missing, after what belongs to a connection,
  # for another Gateway, without a worker's address, or holding the default route's next hop.
  for chain in "192.0.2.20-192.0.2.99 none" "192.0.2.20-192.0.2.99 last" \
    "192.0.2.20-192.0.2.99 first 203.0.113.22" "192.0.2.20-192.0.2.29 first" \
    "192.0.2.0/24 first" "192.0.2.1, 192.0.2.20-192.0.2.99 first"; do
    edge_state 1 active "$WORKERS" 203.0.113.17/32
    # shellcheck disable=SC2086 # the set, the order and the Gateway, as words
    forward_chain $chain > "$HOST/edge-1/forward"
    edge_check --edge 1
    echo "$chain: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"FAIL  lab-edge-1: the forward chain"* ]]
  done
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  forward_chain '192.0.2.20-192.0.2.99' last > "$HOST/edge-1/forward"
  edge_check --edge 1
  [[ $output == *"FAIL  lab-edge-1: the forward chain does not drop an established connection's packets toward the Gateway that do not go through a worker"* ]]
  forward_chain '192.0.2.0/24' first > "$HOST/edge-1/forward"
  edge_check --edge 1
  [[ $output == *"FAIL  lab-edge-1: the forward chain's guard admits the default route's next hop"* ]]
  forward_chain '192.0.2.20-192.0.2.29' first > "$HOST/edge-1/forward"
  edge_check --edge 1
  [[ $output == *"FAIL  lab-edge-1: the forward chain's guard leaves out a worker's address"* ]]
  forward_chain '192.0.2.20-192.0.2.99' first 203.0.113.22 > "$HOST/edge-1/forward"
  edge_check --edge 1
  [[ $output == *"FAIL  lab-edge-1: the forward chain's guard is not for the cluster's Gateway address"* ]]

  # Forwarding on with no rules loaded.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  : > "$HOST/edge-1/rules"
  : > "$HOST/edge-1/forward"
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: the kernel forwards without the nftables rules"* ]]

  # Unattended upgrades on, as the image's package has them.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  echo 'APT::Periodic::Unattended-Upgrade "1";' > "$HOST/edge-1/upgrades"
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: unattended upgrades are on, and would upgrade and restart FRR in place"* ]]
  no_address "$output"
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
  [[ $output == *"no edge was replaced, and edge 1 2 passes"* ]]
  [[ $output != *"edge 1 2 replaced"* ]]
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
  # cluster stack puts its workers there, through its nodes module, which has no default of its own.
  # One TF_VAR_worker_first_host sets both.
  edge=$(yq -p hcl -o json "$ROOT/infra/openstack/stacks/sto2/edge/variables.tf" | jq -c '.variable.worker_first_host.default')
  cluster=$(yq -p hcl -o json "$ROOT/infra/openstack/stacks/sto2/cluster/variables.tf" | jq -c '.variable.worker_first_host.default')
  module=$(yq -p hcl -o json "$ROOT/infra/openstack/modules/talos-nodes/variables.tf" | jq -c '.variable.worker_first_host.default')
  [ "$module" = null ]
  [[ $cluster =~ ^[0-9]+$ ]]
  [ "$edge" = "$cluster" ]
}

# first_boot [OS_RELEASE]: the edge stack's first-boot script, run here with the edge's file system
# under EDGE_ROOT, a directory of the test's, and fakes of the system's commands first on PATH, on an
# image of the release OS_RELEASE names, trixie by default. The fake vtysh's dry run refuses a file
# with a command FRR does not have, as FRR's does (tests/fixtures/edge-policy/proof.sh checks that of
# FRR's own); the fake systemctl fails to restart FRR when the file restart-fails says so; the fake
# ip shows the kernel's unreachable route for the service range once FRR is restarted.
first_boot() {
  local root="$BATS_TEST_TMPDIR/edge-root" bin="$BATS_TEST_TMPDIR/edge-bin" tool
  mkdir -p "$root/etc/edge" "$root/etc/sysctl.d" "$root/etc/apt/apt.conf.d" "$root/dev" "$root/var/log" "$bin"
  printf 'PRETTY_NAME="Debian GNU/Linux"\nVERSION_CODENAME=%s\n' "${1:-trixie}" > "$root/etc/os-release"
  # A console that cannot be written, when the test asks for one: a directory in its place.
  rm -rf "$root/dev/console"
  if [[ -f "$BATS_TEST_TMPDIR/console-unwritable" ]]; then
    mkdir "$root/dev/console"
  else
    : > "$root/dev/console"
  fi
  for tool in apt-get sysctl nft sleep; do
    cat > "$bin/$tool" << EOF
#!/usr/bin/env bash
printf '%s\n' "$tool \$*" >> "$RECORD/argv"
EOF
  done
  cat > "$bin/systemctl" << EOF
#!/usr/bin/env bash
printf '%s\n' "systemctl \$*" >> "$RECORD/argv"
[[ "\$*" != 'restart frr' || ! -f "$BATS_TEST_TMPDIR/restart-fails" ]] || exit 1
[[ "\$*" != 'restart frr' ]] || touch "$BATS_TEST_TMPDIR/frr-restarted"
EOF
  cat > "$bin/ip" << EOF
#!/usr/bin/env bash
printf '%s\n' "ip \$*" >> "$RECORD/argv"
[[ ! -f "$BATS_TEST_TMPDIR/frr-restarted" ]] || echo "unreachable 203.0.113.16/28 proto static metric 20"
EOF
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
  rm -f "$BATS_TEST_TMPDIR/frr-restarted"
  : > "$RECORD/argv"
  run env EDGE_ROOT="$root" PATH="$bin:$PATH" bash "$ROOT/infra/openstack/stacks/sto2/edge/first-boot.sh"
}

# edge_files: the files cloud-init writes under /etc/edge, FRR's naming the service range.
edge_files() {
  local root="$BATS_TEST_TMPDIR/edge-root" file
  mkdir -p "$root/etc/edge"
  for file in daemons nftables.conf sysctl.conf; do
    echo "fixture $file" > "$root/etc/edge/$file"
  done
  printf 'router bgp 64497\nexit\nip route 203.0.113.16/28 reject\n' > "$root/etc/edge/frr.conf"
}

# first_line PATTERN: the number of the first line of the record that matches PATTERN, 0 for none.
first_line() {
  grep -nE "$1" "$RECORD/argv" | head -1 | cut -d: -f1 | grep . || echo 0
}

# disarmed: what a failed first boot leaves: forwarding off now and at the next boot, and FRR stopped
# and kept from starting at the next boot.
disarmed() {
  local root="$BATS_TEST_TMPDIR/edge-root"
  [ ! -e "$root/etc/sysctl.d/90-edge.conf" ]
  grep -qx 'sysctl -q -w net.ipv4.ip_forward=0' "$RECORD/argv"
  grep -qx 'systemctl disable --now frr' "$RECORD/argv"
}

@test "the first boot starts FRR only once FRR's dry run accepts its file, and fails saying why otherwise" {
  local root="$BATS_TEST_TMPDIR/edge-root"
  edge_files
  first_boot
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"edge-first-boot: done"* ]]
  # Both files are checked as cloud-init wrote them, before anything of theirs is installed under
  # /etc; FRR is restarted only after that, with the file that was checked.
  [ "$(first_line "^nft --check --file $root/etc/edge/nftables.conf\$")" -gt 0 ]
  [ "$(first_line "^vtysh -C -f $root/etc/edge/frr.conf\$")" -gt 0 ]
  [ "$(first_line "^nft --check")" -lt "$(first_line '^install ')" ]
  [ "$(first_line "^vtysh -C")" -lt "$(first_line '^install ')" ]
  [ "$(first_line '^install ')" -lt "$(first_line '^systemctl restart frr$')" ]
  cmp "$root/etc/edge/frr.conf" "$root/etc/frr/frr.conf"

  # A file FRR refuses: the first boot fails, says why on the console and in the log, installs
  # nothing under /etc, and leaves FRR stopped and forwarding off.
  rm -rf "$root/etc/frr" "$root/etc/sysctl.d/90-edge.conf"
  printf 'router bgp 64497\nno-such-command\nexit\n' > "$root/etc/edge/frr.conf"
  first_boot
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"edge-first-boot: FRR's dry run refuses /etc/edge/frr.conf"* ]]
  [[ $output == *"Unknown command: no-such-command"* ]]
  grep -q "FRR's dry run refuses /etc/edge/frr.conf" "$root/dev/console"
  grep -q "FRR's dry run refuses /etc/edge/frr.conf" "$root/var/log/edge-first-boot.log"
  [ ! -e "$root/etc/frr/frr.conf" ]
  absent '^install ' "$RECORD/argv"
  absent -E '^systemctl (enable|restart) frr' "$RECORD/argv"
  disarmed
}

@test "the first boot turns forwarding on last, once FRR answers and the reject route is in the kernel" {
  local root="$BATS_TEST_TMPDIR/edge-root"
  edge_files
  first_boot
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$root/etc/sysctl.d/90-edge.conf" ]
  forwarding=$(first_line '^sysctl --system$')
  [ "$forwarding" -gt "$(first_line '^systemctl restart nftables$')" ]
  [ "$forwarding" -gt "$(first_line "^vtysh -c show bgp summary\$")" ]
  [ "$forwarding" -gt "$(first_line '^ip -4 route show exact 203.0.113.16/28 type unreachable$')" ]
  [ "$forwarding" -gt "$(first_line '^nft list table ip edge-nat$')" ]
  # The forwarding setting is installed with it, and not before.
  [ "$(first_line "^install -m 0644 $root/etc/edge/sysctl.conf ")" -gt "$(first_line '^systemctl restart frr$')" ]

  # FRR fails to restart: the trap leaves forwarding off, its setting gone, and FRR stopped.
  touch "$BATS_TEST_TMPDIR/restart-fails"
  rm -f "$root/etc/sysctl.d/90-edge.conf"
  first_boot
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"edge-first-boot: FAILED at line"* ]]
  absent '^sysctl --system$' "$RECORD/argv"
  disarmed
}

@test "a failed first boot leaves the edge disarmed even when the console cannot be written" {
  local root="$BATS_TEST_TMPDIR/edge-root"
  edge_files
  touch "$BATS_TEST_TMPDIR/console-unwritable"
  # FRR's dry run refuses the file.
  printf 'router bgp 64497\nno-such-command\nexit\n' > "$root/etc/edge/frr.conf"
  first_boot
  echo "$output"
  [ "$status" -ne 0 ]
  disarmed
  # FRR does not restart.
  edge_files
  touch "$BATS_TEST_TMPDIR/restart-fails"
  first_boot
  echo "$output"
  [ "$status" -ne 0 ]
  disarmed
}

@test "the first boot installs nothing on an image of another release" {
  edge_files
  first_boot bookworm
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"written for Debian trixie"* ]]
  absent -E '^(apt-get|install|systemctl) ' "$RECORD/argv"
}

@test "the first boot turns unattended upgrades off before it installs anything" {
  local root="$BATS_TEST_TMPDIR/edge-root"
  edge_files
  first_boot
  [ "$status" -eq 0 ]
  grep -qx 'APT::Periodic::Unattended-Upgrade "0";' "$root/etc/apt/apt.conf.d/99edge-no-unattended-upgrades"
  [ "$(first_line '^systemctl disable --now apt-daily-upgrade.timer$')" -gt 0 ]
  [ "$(first_line '^systemctl disable --now apt-daily-upgrade.timer$')" -lt "$(first_line '^apt-get ')" ]
  # apt waits for a lock another apt run holds at first boot, instead of failing at once.
  grep -q '^apt-get .*-o DPkg::Lock::Timeout=' "$RECORD/argv"
}
