#!/usr/bin/env bats
# Proves features/edge-routers.feature; each test carries its scenario's title. The scripts run
# against recording fakes of tofu, ssh, openstack and the rest, so nothing here reaches a cloud, a
# host or a cluster, and no test reads or writes a key at a real path.

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
  local encoded talman config range gateway bits mask
  encoded=$(tofu -chdir="$ROOT/tests/fixtures/talos" console -no-color <<< 'base64encode(local.talman_yaml)')
  talman="$BATS_TEST_TMPDIR/talman.yaml"
  base64 -d <<< "${encoded//\"/}" > "$talman"
  config="$BATS_TEST_TMPDIR/cluster-config.json"
  # shellcheck disable=SC2016 # $1 and $2 are the inner shell's.
  env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" CLUSTER_DOMAIN=example.com BACKUP_BUCKET_PREFIX=marker-backups bash -c \
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

  # The example lists the key, and the pool is untouched: it still holds the whole range, so
  # keeping the Gateway's address from another Service is the Gateway's own change, which asks the
  # pool for it by annotation.
  yq -e 'has("GATEWAY_ADDRESS")' "$ROOT/kubernetes/clusters/lab-sto2/cluster-config.example.yaml"
  [ "$(yq '.spec.blocks | length' "$ROOT/kubernetes/apps/base/kube-system/cilium-bgp/app/pool.yaml")" -eq 1 ]
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
