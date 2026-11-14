#!/usr/bin/env bats

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  JUST=$(command -v just)
  REAL_TOFU=$(command -v tofu)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  mkdir -p "$BIN" "$RECORD" "$BATS_TEST_TMPDIR/repo/infra/openstack/stacks/sto2/plumbing"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  # A copy of the scripts, the backend file and the plumbing stack's configuration, so no run
  # touches this checkout.
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp "$ROOT/infra/openstack/backend.hcl" "$REPO/infra/openstack/backend.hcl"
  PLUMBING="$REPO/infra/openstack/stacks/sto2/plumbing"
  cp "$ROOT"/infra/openstack/stacks/sto2/plumbing/*.tf "$PLUMBING/"
  # The plumbing stack's image, as its state lists it.
  IMAGE=module.image.module.image.openstack_images_image_v2.this
  # What tofu itself prints: the state's entries, its report of a removal and its errors.
  STATE_MARKER='module.marker_state_listing.openstack_networking_port_v2.this["marker-state-key"]'
  REPORT_MARKER='marker-removal-report'
  ERROR_MARKER='marker-tofu-error'
  LISTING="$BATS_TEST_TMPDIR/listing"
  listing "$IMAGE" module.image.talos_image_factory_schematic.this "$STATE_MARKER"
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise < /dev/null
  recording_tofu
  ENVIRONMENT=(
    TF_STATE_BUCKET=fixture-state-bucket
    AWS_ACCESS_KEY_ID=marker-access-key-id
    AWS_SECRET_ACCESS_KEY=marker-secret-access-key
    TF_STATE_PASSPHRASE=marker-state-passphrase
    OS_AUTH_URL=https://identity.example.invalid/v3
  )
}

# fake NAME: a binary first on the recipe's PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# listing [ADDRESS...]: the state the recording tofu lists, one ADDRESS per line.
listing() {
  if (($#)); then
    printf '%s\n' "$@" > "$LISTING"
  else
    : > "$LISTING"
  fi
}

# recording_tofu: a tofu that records its arguments, one call per line; lists the state from
# LISTING; reports a removal on stdout, as tofu does, with a marker; and fails a removal, with an
# error holding a marker, while the file state-rm-fails exists.
recording_tofu() {
  fake tofu <<EOF
printf '%s\n' "\$*" >> "$RECORD/tofu"
case "\${2-} \${3-}" in
  'state list') cat "$LISTING" ;;
  'state rm')
    if [[ -e "$BATS_TEST_TMPDIR/state-rm-fails" ]]; then
      echo "Error: fixture failure removing \$4: $ERROR_MARKER" >&2
      exit 1
    fi
    echo "Removed \$4 $REPORT_MARKER"
    ;;
esac
EOF
}

# with ENTRY...: adds the NAME=VALUE ENTRY... to the environment the recipes get.
with() {
  ENVIRONMENT+=("$@")
}

# recipe NAME [ARG...]: runs the repository's recipe against the copy, with only ENVIRONMENT set.
# A recipe that blocks, such as on a held lock, fails after a minute instead of hanging the tests.
recipe() {
  run timeout 60 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$@"
}

# removals: the recorded tofu calls that remove something from the state.
removals() {
  awk '$2 == "state" && $3 == "rm"' "$RECORD/tofu" 2> /dev/null
}

@test "Forgetting the image removes it from state and leaves everything else" {
  # A stack on the local backend under the plumbing stack's encryption block, whose image sits at
  # the plumbing stack's module path beside a resource in the same module, as the schematic does,
  # and one outside it. tofu cannot plan an OpenStack image offline, so the image is a
  # terraform_data, and the tofu the recipe runs is the real one with the image's address swapped
  # for it on the way in and out.
  stack="$BATS_TEST_TMPDIR/stack"
  stand_in=module.image.module.image.terraform_data.this
  mkdir -p "$stack/talos-image/image"
  {
    echo 'terraform {'
    sed -n '/^  encryption {$/,/^  }$/p' "$ROOT/infra/openstack/stacks/sto2/plumbing/versions.tf"
    echo '}'
    cat <<'EOF'

module "image" {
  source = "./talos-image"
}

resource "terraform_data" "network" {
  input = "network"
}
EOF
  } > "$stack/main.tf"
  cat > "$stack/talos-image/main.tf" <<'EOF'
module "image" {
  source = "./image"
}

resource "terraform_data" "schematic" {
  input = "schematic"
}
EOF
  cat > "$stack/talos-image/image/main.tf" <<'EOF'
resource "terraform_data" "this" {
  input = "image"
}
EOF
  # shellcheck source=scripts/lib/infra.sh
  source "$ROOT/scripts/lib/infra.sh"
  export TF_STATE_PASSPHRASE=passphrase-of-this-test
  export_state_encryption
  run tofu -chdir="$stack" init -input=false -no-color
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  run tofu -chdir="$stack" apply -input=false -auto-approve -no-color
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  # The stack is initialised on its local backend already, so the recipe's init is left out.
  fake tofu <<EOF
set -o pipefail
[[ \${2-} == init ]] && exit 0
arguments=()
for argument; do
  case \$argument in
    -chdir=*) arguments+=(-chdir="$stack") ;;
    "$IMAGE") arguments+=("$stand_in") ;;
    *) arguments+=("\$argument") ;;
  esac
done
printf '%s\n' "\${arguments[*]}" >> "$RECORD/tofu"
"$REAL_TOFU" "\${arguments[@]}" | awk -v stand_in="$stand_in" -v image="$IMAGE" '\$0 == stand_in { \$0 = image } 1'
EOF
  with TF_STATE_PASSPHRASE=passphrase-of-this-test

  recipe infra-forget-image --yes < /dev/null

  [ "$status" -eq 0 ]
  [ "$(removals)" = "-chdir=$stack state rm $stand_in" ]
  [ "$(tofu -chdir="$stack" state list -no-color | sort)" = "module.image.terraform_data.schematic
terraform_data.network" ]
  # Written back with the repository's settings: encrypted, and read with the same passphrase.
  jq -e 'has("encrypted_data") and (has("resources") | not)' "$stack/terraform.tfstate"
  run tofu -chdir="$stack" plan -input=false -no-color -out="$stack/next.tfplan"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  plan=$(tofu -chdir="$stack" show -json "$stack/next.tfplan")
  [ "$(plan_summary <<< "$plan")" = 'Plan: 1 to add, 0 to change, 0 to destroy.
  create: 1 terraform_data' ]
  [ "$(jq -r '.resource_changes[] | select(.change.actions != ["no-op"]) | .address' <<< "$plan")" = "$stand_in" ]
}

@test "The recipe forgets exactly the plumbing stack's image resource" {
  recipe infra-forget-image --yes < /dev/null

  [ "$status" -eq 0 ]
  init=$(awk '$2 == "init"' "$RECORD/tofu")
  [ "$(wc -l <<< "$init")" -eq 1 ]
  [[ " $init " == *" -backend-config=$REPO/infra/openstack/backend.hcl "* ]]
  [[ " $init " == *" -backend-config=bucket=fixture-state-bucket "* ]]
  [[ " $init " == *" -backend-config=key=sto2/plumbing.tfstate "* ]]
  # Every call is on the plumbing stack; it lists the state and removes the image, nothing else.
  [ "$(awk '{ print $1 }' "$RECORD/tofu" | sort -u)" = "-chdir=$PLUMBING" ]
  [ "$(awk '{ print $2 }' "$RECORD/tofu" | sort -u | paste -sd ' ')" = "init state" ]
  [ "$(awk '$2 == "state"' "$RECORD/tofu")" = "-chdir=$PLUMBING state list
-chdir=$PLUMBING state rm $IMAGE" ]
}

@test "Nothing is forgotten without confirmation" {
  told="sto2/plumbing: only the state forgets the Talos image; the image itself stays in the cloud"

  recipe infra-forget-image <<< "no"

  [ "$status" -ne 0 ]
  # The line before the question says what happens to the image.
  [[ $output == *"$told"*"Type sto2/plumbing to "* ]]
  [[ $output == *"sto2/plumbing was not confirmed"* ]]
  [ -z "$(removals)" ]

  recipe infra-forget-image < /dev/null

  [ "$status" -ne 0 ]
  [ -z "$(removals)" ]

  recipe infra-forget-image <<< "sto2/plumbing"

  [ "$status" -eq 0 ]
  [ "$(removals)" = "-chdir=$PLUMBING state rm $IMAGE" ]

  rm "$RECORD/tofu"
  for flags in --force '--yes --yes' 'sto2/plumbing --yes'; do
    # shellcheck disable=SC2086 # the arguments as an operator types them
    recipe infra-forget-image $flags < /dev/null

    [ "$status" -eq 2 ]
    [[ $output == *"usage: infra-forget-image [--yes]"* ]]
    [ ! -e "$RECORD/tofu" ]
  done
}

@test "A state without the image is left alone, and the recipe says so" {
  # Near misses: the image module's other resource, an image of another name, and a data source.
  listing module.image.talos_image_factory_schematic.this "${IMAGE}_old" \
    "module.image.module.image.data.openstack_images_image_v2.this" "$STATE_MARKER"

  # Without --yes and with nothing to answer: a run that asked would fail.
  recipe infra-forget-image < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"sto2/plumbing: the state holds no Talos image; nothing to forget"* ]]
  [[ $output != *Type* ]]
  [ -z "$(removals)" ]
  [ "$(awk '$2 == "state"' "$RECORD/tofu")" = "-chdir=$PLUMBING state list" ]

  listing

  recipe infra-forget-image < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"nothing to forget"* ]]
  [ -z "$(removals)" ]
}

@test "Nothing from the state reaches the output" {
  printed=()

  recipe infra-forget-image --yes < /dev/null

  [ "$status" -eq 0 ]
  printed+=("$output")

  with CI=true
  recipe infra-forget-image --yes < /dev/null

  [ "$status" -eq 0 ]
  printed+=("$output")

  listing "$STATE_MARKER"
  recipe infra-forget-image < /dev/null

  [ "$status" -eq 0 ]
  printed+=("$output")

  # A removal that fails with CI set: tofu's errors go to the stack's error log.
  listing "$IMAGE" "$STATE_MARKER"
  : > "$BATS_TEST_TMPDIR/state-rm-fails"
  recipe infra-forget-image --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $output == *"tofu state failed for sto2/plumbing; its errors are in infra/openstack/stacks/sto2/plumbing/.terraform/tofu-errors.log"* ]]
  grep -qF "$ERROR_MARKER" "$PLUMBING/.terraform/tofu-errors.log"
  printed+=("$output")

  [ "$(removals | wc -l)" -eq 3 ]
  for marker in "$STATE_MARKER" marker-state-key "$REPORT_MARKER" "$ERROR_MARKER"; do
    [[ ${printed[*]} != *"$marker"* ]]
  done
}

@test "Two operations on the stack do not overlap" {
  # While another operation holds the plumbing stack's lock, the forget starts nothing.
  mkdir -p "$PLUMBING/.terraform"
  exec {held}> "$PLUMBING/.terraform/infra.lock"
  flock -n "$held"

  recipe infra-forget-image --yes < /dev/null

  exec {held}>&-
  [ "$status" -ne 0 ]
  [[ $output == *"sto2/plumbing is busy"* ]]
  [ ! -e "$RECORD/tofu" ]

  # While the forget runs, with its tofu holding on until the test releases it, a plan of the
  # stack is refused.
  fake tofu <<EOF
if [[ "\${2-} \${3-}" == 'state list' ]]; then
  : > "$BATS_TEST_TMPDIR/started"
  for _ in {1..100}; do
    [[ -e "$BATS_TEST_TMPDIR/release" ]] && break
    sleep 0.1
  done
  cat "$LISTING"
fi
EOF
  env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" infra-forget-image --yes \
    < /dev/null > "$BATS_TEST_TMPDIR/first.out" 2>&1 &
  first=$!
  for _ in {1..100}; do
    [[ -e "$BATS_TEST_TMPDIR/started" ]] && break
    sleep 0.1
  done

  recipe infra-plan sto2/plumbing

  touch "$BATS_TEST_TMPDIR/release"
  wait "$first"
  [ "$status" -ne 0 ]
  [[ $output == *"sto2/plumbing is busy"* ]]
}

@test "the address the recipe forgets is the image in the plumbing stack's mocked plan" {
  recipe infra-forget-image --yes < /dev/null

  [ "$status" -eq 0 ]
  address=$(removals | awk '{ print $4 }')
  [[ $address == *.openstack_images_image_v2.* ]]
  # The plumbing stack with its modules, its tests and what they read, as in this checkout.
  cp -R "$ROOT/infra/openstack/modules" "$REPO/infra/openstack/modules"
  cp -R "$ROOT/infra/openstack/stacks/sto2/plumbing/tests" "$ROOT/infra/openstack/stacks/sto2/plumbing/.terraform.lock.hcl" "$PLUMBING/"
  mkdir -p "$REPO/talos" "$REPO/tests/fixtures"
  cp "$ROOT/talos/schematic.yaml" "$REPO/talos/"
  cp "$ROOT/versions.yaml" "$REPO/"
  cp -R "$ROOT/tests/fixtures/image-replacement" "$REPO/tests/fixtures/"
  # The providers infra-check installed in this checkout's plumbing stack, when it has; the public
  # registry otherwise.
  installed="$ROOT/infra/openstack/stacks/sto2/plumbing/.terraform/providers"
  if [[ -d $installed ]]; then
    printf 'provider_installation {\n  filesystem_mirror {\n    path = "%s"\n  }\n}\n' "$installed" > "$BATS_TEST_TMPDIR/tofurc"
    export TF_CLI_CONFIG_FILE="$BATS_TEST_TMPDIR/tofurc"
  fi
  run tofu -chdir="$PLUMBING" init -backend=false -input=false -no-color
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }

  # Every provider is mocked; -verbose prints each run's plan.
  run tofu -chdir="$PLUMBING" test -verbose -no-color

  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [[ $output == *"# $address will be created"* ]]
}
