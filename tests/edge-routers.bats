#!/usr/bin/env bats
# Proves features/edge-routers.feature; each test carries its scenario's title. The scripts run
# against recording fakes of tofu, ssh, openstack and the rest, so nothing here reaches a cloud, a
# host or a cluster, and no test reads or writes a key at a real path.

load fixtures/edge-stack

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  mkdir -p "$BIN" "$RECORD"
  : > "$RECORD/argv"
}

# fake NAME: a binary first on the recipe's PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# absent GREP_ARG...: fails when grep -q finds a match; the last command of a function, as bats
# ignores a failing ! anywhere else.
absent() {
  ! grep -q "$@"
}

# ipv4_number ADDRESS: the address as an integer.
ipv4_number() {
  local -a octets
  IFS=. read -r -a octets <<< "$1"
  echo $(((octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]))
}

@test "The Gateway's address is inside the service range and reaches cluster-config" {
  # The cluster stack's talman.yaml as the fixture renders it, and the ConfigMap the copy of
  # scripts/lib/cluster.sh makes of it.
  local encoded talman config range gateway bits mask blocks
  encoded=$(tofu -chdir="$ROOT/tests/fixtures/talos" console -no-color <<< 'base64encode(local.talman_yaml)')
  talman="$BATS_TEST_TMPDIR/talman.yaml"
  base64 -d <<< "${encoded//\"/}" > "$talman"
  config="$BATS_TEST_TMPDIR/cluster-config.json"
  # The edges' public addresses come from the edge stack's outputs, which a fake of tofu answers.
  edge_stack_fixture "$BATS_TEST_TMPDIR/unused" "$BATS_TEST_TMPDIR/edge-bin" "$BATS_TEST_TMPDIR/edge-state"
  # shellcheck disable=SC2016 # $1 and $2 are the inner shell's.
  env -i PATH="$BATS_TEST_TMPDIR/edge-bin:$PATH" HOME="$BATS_TEST_TMPDIR" "${EDGE_STACK_ENVIRONMENT[@]}" \
    CLUSTER_DOMAIN=example.com BACKUP_BUCKET_PREFIX=marker-backups bash -c \
    '. "$1/scripts/lib/cluster.sh" && fill_cluster_config lab-sto2 "$2" && cluster_config_manifest' _ "$ROOT" "$talman" |
    jq '.data' > "$config"

  range=$(yq -e '.values.serviceRange' "$talman")
  gateway=$(jq -er '.GATEWAY_ADDRESS' "$config")
  [ "$gateway" = "$(yq -e '.values.bgp.gatewayAddress' "$talman")" ]
  [[ $gateway =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
  # It is the address the stack was given, which is not the range's first host, the plumbing
  # stack's default: a template that worked the address out from the range could not match.
  [ "$gateway" = "$(yq -e '.bgp.gateway_address' "$ROOT/tests/fixtures/talos/inputs.yaml")" ]

  # Inside the range, and neither its network address nor its last.
  bits=${range#*/}
  mask=$(((0xffffffff << (32 - bits)) & 0xffffffff))
  [ $(($(ipv4_number "$gateway") & mask)) -eq "$(ipv4_number "${range%/*}")" ]
  [ "$(ipv4_number "$gateway")" -ne "$(ipv4_number "${range%/*}")" ]
  [ "$(ipv4_number "$gateway")" -ne $(($(ipv4_number "${range%/*}") + 1)) ]
  [ "$(ipv4_number "$gateway")" -ne $(($(ipv4_number "${range%/*}") + (1 << (32 - bits)) - 1)) ]

  # The example lists the key, and the pool is untouched: it holds one block, the whole range, as
  # the ConfigMap fills it in, so keeping the Gateway's address from another Service is the
  # Gateway's own change, which asks the pool for it by annotation.
  yq -e 'has("GATEWAY_ADDRESS")' "$ROOT/kubernetes/clusters/lab-sto2/cluster-config.example.yaml"
  [ "$(jq -r '.SERVICE_RANGE' "$config")" = "$range" ]
  blocks=$(yq -o=json -I=0 '.spec.blocks' "$ROOT/kubernetes/apps/base/kube-system/cilium-bgp/app/pool.yaml")
  # shellcheck disable=SC2016 # the pool names the variable Flux substitutes, which is text here
  [ "${blocks//'${SERVICE_RANGE}'/$range}" = "[{\"cidr\":\"$range\"}]" ]
}

@test "os-images prints names only" {
  fake openstack <<EOF
printf '%s\n' "openstack \$*" >> "$RECORD/argv"
case "\$*" in
  'image list --public --status active -f json -c Name')
    echo '[{"Name": "Debian 13 (Trixie)"}, {"Name": "Ubuntu 24.04"}, {"Name": "Debian 12 (Bookworm)"}]'
    ;;
  *) echo "unexpected call: openstack \$*" >&2; exit 1 ;;
esac
EOF
  # A copy of the scripts, so no run reads this checkout's .env.
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  cp -R "$ROOT/scripts" "$BATS_TEST_TMPDIR/repo/scripts"
  run env PATH="$BIN:$PATH" OS_CLOUD=fixture-cloud HOME="$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR/repo/scripts/os-images"

  [ "$status" -eq 0 ]
  [ "$output" = $'Debian 12 (Bookworm)\nDebian 13 (Trixie)\nUbuntu 24.04' ]

  run env PATH="$BIN:$PATH" OS_CLOUD=fixture-cloud HOME="$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR/repo/scripts/os-images" debian
  [ "$status" -eq 0 ]
  [ "$output" = $'Debian 12 (Bookworm)\nDebian 13 (Trixie)' ]

  # Read-only: only listings, and nothing about an image but its name was asked for.
  [ "$(grep -c . "$RECORD/argv")" -eq 2 ]
  absent -E 'create|delete|set|unset|save|add|remove' "$RECORD/argv"
}

# policy_copy: a copy in $COPY of what the render of the proof's input reads, each file where the
# repository has it: the scripts, the fixture's three files and the two files its main.tf names.
policy_copy() {
  local path
  COPY="$BATS_TEST_TMPDIR/copy"
  mkdir -p "$COPY"
  cp -R "$ROOT/scripts" "$COPY/scripts"
  for path in tests/fixtures/edge-policy/main.tf tests/fixtures/edge-policy/proof.sh \
    tests/fixtures/edge-policy/speaker.conf.in infra/openstack/stacks/sto2/edge/frr.conf.tftpl \
    kubernetes/apps/base/kube-system/cilium-bgp/app/bgp-peer.yaml; do
    mkdir -p "$COPY/$(dirname "$path")"
    cp "$ROOT/$path" "$COPY/$path"
  done
}

teardown() {
  [[ -n ${HOLDER-} ]] || return 0
  # The console that holds the state lock ends when its standard input does, here or when the test's
  # process goes; one that never got its input is ended by hand.
  if [[ -n ${HOLD-} ]]; then
    exec {HOLD}>&-
  else
    kill "$HOLDER" 2> /dev/null || true
  fi
  wait "$HOLDER" 2> /dev/null || true
}

@test "The routing policy's proof renders its input while another run holds the fixture's state lock" {
  local fixture lock waited
  policy_copy
  fixture="$COPY/tests/fixtures/edge-policy"
  lock="$fixture/.terraform.tfstate.lock.info"
  # The render with no lock held, which the renders under the lock are compared with.
  "$COPY/scripts/edge-policy-render" "$BATS_TEST_TMPDIR/free"
  grep -qx 'hostname proof-edge' "$BATS_TEST_TMPDIR/free/edge.conf"
  [ ! -e "$lock" ]

  # Another tofu console in the copy's fixture holds the directory's state lock while its standard
  # input is open, and this test's process keeps it open. Its descriptor 3 is closed, as bats waits
  # for whatever holds that one, and the bound ends it whatever becomes of the test.
  mkfifo "$BATS_TEST_TMPDIR/hold"
  timeout -k 5 300 tofu -chdir="$fixture" console -no-color \
    < "$BATS_TEST_TMPDIR/hold" > "$BATS_TEST_TMPDIR/holder.out" 2>&1 3>&- &
  HOLDER=$!
  exec {HOLD}> "$BATS_TEST_TMPDIR/hold"
  waited=0
  until [ -e "$lock" ] || ((waited >= 300)); do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$lock" ] || { echo "the other console took no state lock within 30 s; it printed:"; cat "$BATS_TEST_TMPDIR/holder.out"; return 1; }

  run "$COPY/scripts/edge-policy-render" "$BATS_TEST_TMPDIR/held"
  echo "the render under the lock: status $status"
  echo "$output"
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/free/edge.conf" "$BATS_TEST_TMPDIR/held/edge.conf"

  # The proof's own render, and what it hands docker: the fake keeps the file the proof would read
  # from the directory mounted at /work.
  fake docker << EOF
printf '%s\n' "\$@" > "$RECORD/docker.args"
for arg in "\$@"; do
  [[ \$arg != *:/work:ro ]] || cp "\${arg%:/work:ro}/edge.conf" "$RECORD/edge.conf"
done
printf '%s\n' '== proof' 'ran to its end'
EOF
  run env PATH="$BIN:$PATH" "$COPY/scripts/edge-policy-check" fixture-image
  echo "the proof under the lock: status $status"
  echo "$output"
  [ -f "$RECORD/docker.args" ] || { echo "docker was not run: the proof ended before it"; return 1; }
  [ "$(head -n 1 "$RECORD/docker.args")" = run ]
  grep -qx fixture-image "$RECORD/docker.args"
  cmp "$BATS_TEST_TMPDIR/free/edge.conf" "$RECORD/edge.conf"
  # The lock was the other console's from the first render under it to the last.
  [ -e "$lock" ]
  kill -0 "$HOLDER"
}

@test "a proof of the routing policy that fails says why" {
  # A container that prints part of the proof's report, a wait that ran out among it, and fails.
  fake docker << EOF
printf '%s\n' "docker \$*" >> "$RECORD/argv"
printf '%s\n' '== syntax' "the edge's file is accepted" 'a file with an unknown command is refused'
printf '%s\n' '== daemons' 'edge: running' 'a: running' 'b: running' 'c: running'
printf '%s\n' '== waits' 'met: every daemon answers, after 1 s'
printf '%s\n' "not met: the speaker in the cluster's AS has its session established and has offered its five prefixes, after 120 s; last seen: state Active, pfxSnt None"
exit 1
EOF
  run env PATH="$BIN:$PATH" "$ROOT/scripts/edge-policy-check" fixture-image
  echo "$output"
  [ "$status" -ne 0 ]
  grep -q '^docker run ' "$RECORD/argv"
  # The verdicts, the failing ones among them, then everything the proof printed.
  [[ $output == *"pass  every BGP daemon of the proof is running"* ]]
  [[ $output == *"FAIL  the speaker in the cluster's AS has its session established and has offered its five prefixes, within the bound"* ]]
  [[ $output == *"FAIL  the proof ran to its end"* ]]
  [[ $output == *"not met: the speaker in the cluster's AS has its session established and has offered its five prefixes, after 120 s; last seen: state Active, pfxSnt None"* ]]
  [[ $output == *"ended with status 1"* ]]
}

@test "the routing policy's proof runs with no capability, no new privileges and a read-only root" {
  # The proof's daemons write only under a directory of the proof's own in /tmp, and run from a copy
  # of the image's bgpd there, which /tmp must let run; they need no privilege, so a runtime that
  # grants less than Docker's defaults cannot stop them unseen.
  fake docker << EOF
printf '%s\n' "\$@" > "$RECORD/docker.args"
printf '%s\n' '== proof' 'ran to its end'
EOF
  run env PATH="$BIN:$PATH" "$ROOT/scripts/edge-policy-check" fixture-image
  # The fake's proof is no passing one, so the status proves nothing; it is shown with what the
  # script printed, which says why when the script ended before it reached docker.
  echo "status $status"
  echo "$output"
  [ -f "$RECORD/docker.args" ] || { echo "docker was not run: the script ended before it"; return 1; }
  for flag in --cap-drop=ALL --security-opt=no-new-privileges --read-only --tmpfs=/tmp:exec --network=none; do
    echo "$flag"
    grep -qx -- "${flag%%=*}" "$RECORD/docker.args"
    [[ $flag != *=* ]] || grep -A1 -x -- "${flag%%=*}" "$RECORD/docker.args" | grep -qx -- "${flag#*=}"
  done
}

