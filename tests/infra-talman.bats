#!/usr/bin/env bats

# schematic_id_of SCHEMATIC: the ID talman computes for the schematic file, from a configuration
# that holds little but it.
schematic_id_of() {
  local dir
  dir=$(mktemp -d "${BATS_TEST_TMPDIR:-$BATS_FILE_TMPDIR}/schematic.XXXXXX")
  cat > "$dir/talman.yaml" <<EOF
apiVersion: talman.dev/v1
clusterName: schematic
endpoint: https://192.0.2.5:6443
talosVersion: v1.0.0
kubernetesVersion: v1.0.0
schematic: $1
nodes:
  - hostname: node
    ipAddress: 192.0.2.5
    role: controlplane
EOF
  talman -c "$dir/talman.yaml" schematic id -o json | jq -r '.nodes[0].schematicID'
}

setup_file() {
  local root encoded
  root=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  # The cluster stack's talman_yaml for six nodes: talos/talman.yaml.tftpl as tofu renders it from
  # the Talos check's fixture inputs. tofu console exits zero when it cannot render the template, so
  # only a quoted base64 string counts as the rendered file.
  encoded=$(tofu -chdir="$root/tests/fixtures/talos" console -no-color <<< 'base64encode(local.talman_yaml)')
  [[ $encoded =~ ^\"[A-Za-z0-9+/]+=*\"$ ]]
  export STACK_YAML="$BATS_FILE_TMPDIR/talman.yaml"
  base64 -d <<< "${encoded//\"/}" > "$STACK_YAML"
  # The schematic the stack's image was built from: the repository's own.
  SCHEMATIC_ID=$(schematic_id_of "$root/talos/schematic.yaml")
  [[ $SCHEMATIC_ID =~ ^[0-9a-f]{64}$ ]]
  export SCHEMATIC_ID
}

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  JUST=$(command -v just)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  mkdir -p "$BIN" "$RECORD" "$BATS_TEST_TMPDIR/repo"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  # A copy of what the recipes read from the files git would commit, so no run touches this
  # checkout. Ignored files, such as a talman.yaml written here, stay behind.
  local path
  while IFS= read -r -d '' path; do
    if [[ -f $ROOT/$path ]]; then
      mkdir -p "$REPO/$(dirname "$path")"
      cp "$ROOT/$path" "$REPO/$path"
    fi
  done < <(git -C "$ROOT" ls-files -z --cached --others --exclude-standard -- \
    scripts infra/openstack/backend.hcl infra/openstack/stacks/sto2 talos)
  STACK="$REPO/infra/openstack/stacks/sto2/cluster"
  # The fixture's cluster is named example.
  CLUSTER_DIR="$REPO/talos/example"
  WRITTEN="$CLUSTER_DIR/talman.yaml"
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise < /dev/null
  stack_outputs "$STACK_YAML" "$SCHEMATIC_ID"
  recording_tofu
  recording_talman
  ENVIRONMENT=(
    TF_STATE_BUCKET=fixture-state-bucket
    AWS_ACCESS_KEY_ID=fixture-access-key-id
    AWS_SECRET_ACCESS_KEY=fixture-secret-access-key
    TF_STATE_PASSPHRASE=fixture-state-passphrase
    OS_AUTH_URL=https://identity.example.invalid/v3
    'OPERATOR_CIDRS=["203.0.113.77/32"]'
  )
}

# fake NAME: a binary first on the recipe's PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# stack_outputs YAML SCHEMATIC_ID: what tofu output -json gives for the applied cluster stack: the
# file YAML as its talman_yaml and SCHEMATIC_ID as its schematic_id.
stack_outputs() {
  jq -n --rawfile yaml "$1" --arg id "$2" '{
    talman_yaml: {sensitive: true, type: "string", value: $yaml},
    schematic_id: {sensitive: false, type: "string", value: $id}
  }' > "$BATS_TEST_TMPDIR/outputs.json"
}

# A tofu that records its arguments, one call per line; shows a plan without changes and answers
# output with the stack's outputs.
recording_tofu() {
  fake tofu <<EOF
printf '%s\n' "\$*" >> "$RECORD/tofu"
case \${2-} in
  show) echo '{"resource_changes": []}' ;;
  output) cat "$BATS_TEST_TMPDIR/outputs.json" ;;
esac
EOF
}

# The real talman, its arguments recorded one call per line, and a copy kept of each configuration
# it validates.
recording_talman() {
  local real
  real=$(command -v talman)
  fake talman <<EOF
printf '%s\n' "talman \$*" >> "$RECORD/talman"
if [[ \$1 == -c && \${3-} == validate ]]; then
  cp "\$2" "$RECORD/validated.yaml"
fi
exec "$real" "\$@"
EOF
}

# recipe NAME [ARG...]: runs the repository's recipe against the copy, with only ENVIRONMENT set.
recipe() {
  run timeout 60 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$@"
}

# tofu_calls SUBCOMMAND: the recorded tofu calls of SUBCOMMAND, as recorded.
tofu_calls() {
  awk -v subcommand="$1" '$2 == subcommand' "$RECORD/tofu" 2> /dev/null
}

@test "The recipe writes talman.yaml privately and atomically" {
  # A talman.yaml from an earlier run, readable by everyone. Written over in place, it would keep
  # its inode and its mode.
  mkdir -p "$CLUSTER_DIR"
  echo 'earlier: true' > "$WRITTEN"
  chmod 0644 "$WRITTEN"
  earlier=$(stat -c %i "$WRITTEN")

  recipe infra-talman

  [ "$status" -eq 0 ]
  [ "$(tofu_calls output)" = "-chdir=$STACK output -json" ]
  [ "$(stat -c %a "$WRITTEN")" = 600 ]
  cmp "$WRITTEN" "$STACK_YAML"
  [ "$(stat -c %i "$WRITTEN")" != "$earlier" ]
  [ "$(ls -A "$CLUSTER_DIR")" = talman.yaml ]
  [[ $output == *"talos/example/talman.yaml"* ]]
  # No value in the file is printed, save the cluster's name, which its path holds.
  values=$(yq '.. | select(tag != "!!map" and tag != "!!seq" and key != "clusterName")' "$STACK_YAML")
  [ "$(wc -l <<< "$values")" -gt 20 ]
  while IFS= read -r value; do
    if [[ $output == *"$value"* ]]; then
      echo "the recipe printed $value" >&2
      return 1
    fi
  done <<< "$values"
}

@test "A schematic mismatch fails the recipe" {
  # talos/schematic.yaml changed after the stack's image was built from it.
  yq -i '.customization.extraKernelArgs = ["console=ttyS0"]' "$REPO/talos/schematic.yaml"
  computed=$(schematic_id_of "$REPO/talos/schematic.yaml")
  [[ $computed =~ ^[0-9a-f]{64}$ ]]
  [ "$computed" != "$SCHEMATIC_ID" ]

  recipe infra-talman

  [ "$status" -ne 0 ]
  [[ $output == *"$computed"* ]]
  [[ $output == *"$SCHEMATIC_ID"* ]]
  [ -z "$(ls -A "$CLUSTER_DIR" 2> /dev/null)" ]

  # A talman.yaml from an earlier run stays as it was, and nothing is left beside it.
  mkdir -p "$CLUSTER_DIR"
  echo 'earlier: true' > "$WRITTEN"
  cp "$WRITTEN" "$BATS_TEST_TMPDIR/earlier.yaml"

  recipe infra-talman

  [ "$status" -ne 0 ]
  cmp "$WRITTEN" "$BATS_TEST_TMPDIR/earlier.yaml"
  [ "$(ls -A "$CLUSTER_DIR")" = talman.yaml ]
}

@test "The written file validates" {
  [ "$(yq '.nodes | length' "$STACK_YAML")" -eq 6 ]

  recipe infra-talman

  [ "$status" -eq 0 ]
  # talman validated the file the recipe wrote, in the cluster's directory, where the file's
  # relative paths name the repository's patches and schematic.
  validated=$(grep ' validate$' "$RECORD/talman")
  [ "$(wc -l <<< "$validated")" -eq 1 ]
  config=${validated#talman -c }
  config=${config% validate}
  [ "$(dirname "$config")" = "$CLUSTER_DIR" ]
  cmp "$RECORD/validated.yaml" "$WRITTEN"

  # A patch talman cannot render fails the recipe, named in talman's message.
  printf 'broken: "{{ .Values.missing.key }}"\n' >> "$REPO/talos/patches/all/kubelet.yaml"

  recipe infra-talman

  [ "$status" -ne 0 ]
  [[ $output == *"patches/all/kubelet.yaml"* ]]
}

@test "infra-apply writes the cluster's talman.yaml after applying the cluster stack, and only that stack's" {
  recipe infra-apply sto2/cluster --yes < /dev/null

  [ "$status" -eq 0 ]
  # From the state the apply wrote, in the same run: no second init.
  [ "$(awk '{ print $2 }' "$RECORD/tofu" | paste -sd ' ')" = "init plan show apply output" ]
  cmp "$WRITTEN" "$STACK_YAML"
  [ "$(stat -c %a "$WRITTEN")" = 600 ]

  rm -r "$RECORD" "$CLUSTER_DIR"
  mkdir "$RECORD"
  recipe infra-apply sto2/plumbing --yes < /dev/null

  [ "$status" -eq 0 ]
  [ -z "$(tofu_calls output)" ]
  [ ! -e "$CLUSTER_DIR" ]
}

@test "talman's errors stay out of a public CI log" {
  # Two nodes on one address: talman's error quotes it.
  address=$(yq '.nodes[0].ipAddress' "$STACK_YAML")
  yq '.nodes[1].ipAddress = .nodes[0].ipAddress' "$STACK_YAML" > "$BATS_TEST_TMPDIR/duplicate.yaml"
  stack_outputs "$BATS_TEST_TMPDIR/duplicate.yaml" "$SCHEMATIC_ID"
  ENVIRONMENT+=(CI=true)

  recipe infra-talman

  [ "$status" -ne 0 ]
  [[ $output =~ talman\ [a-z]+\ failed\ for\ sto2/cluster\;\ its\ errors\ are\ in\ infra/openstack/stacks/sto2/cluster/\.terraform/tofu-errors\.log ]]
  [[ $output != *"$address"* ]]
  grep -qF "$address" "$STACK/.terraform/tofu-errors.log"
  [ ! -e "$WRITTEN" ]

  unset 'ENVIRONMENT[-1]'
  recipe infra-talman

  [ "$status" -ne 0 ]
  [[ $output == *"$address"* ]]
}

@test "infra-talman refuses a cluster name that would leave talos/" {
  yq '.clusterName = "../outside"' "$STACK_YAML" > "$BATS_TEST_TMPDIR/outside.yaml"
  stack_outputs "$BATS_TEST_TMPDIR/outside.yaml" "$SCHEMATIC_ID"

  recipe infra-talman

  [ "$status" -ne 0 ]
  [[ $output == *clusterName* ]]
  [ ! -e "$REPO/outside" ]
  [ -z "$(find "$REPO" -name '*talman.yaml*' ! -name talman.yaml.tftpl)" ]
}
