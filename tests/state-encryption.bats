#!/usr/bin/env bats

# The pinned tofu runs these on the local backend in a temporary directory; nothing reaches a
# network.

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  # shellcheck source=scripts/lib/infra.sh
  source "$ROOT/scripts/lib/infra.sh"
  STACK="$BATS_TEST_TMPDIR/stack"
  unset TF_ENCRYPTION TF_STATE_PASSPHRASE
}

# throwaway_stack DIR [STACK]: a stack on the local backend under the encryption block of the
# repository's STACK (plumbing unless named), whose resource and output carry a marker.
throwaway_stack() {
  mkdir -p "$1"
  {
    echo 'terraform {'
    sed -n '/^  encryption {$/,/^  }$/p' "$ROOT/infra/openstack/stacks/sto2/${2:-plumbing}/versions.tf"
    echo '}'
    cat <<'EOF'

resource "terraform_data" "marker" {
  input = "plaintext-marker"
}

output "marker" {
  value = terraform_data.marker.output
}
EOF
  } > "$1/main.tf"
}

# encrypt_with PASSPHRASE: exports the repository's encryption settings for PASSPHRASE.
encrypt_with() {
  export TF_STATE_PASSPHRASE=$1
  export_state_encryption
}

# applied DIR: initialises and applies DIR, showing tofu's output only when it fails.
applied() {
  run tofu -chdir="$1" init -input=false -no-color
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  run tofu -chdir="$1" apply -input=false -auto-approve -no-color
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

# absent TEXT FILE: fails when FILE holds TEXT.
absent() {
  if grep -qF -- "$1" "$2"; then
    echo "found $1 in $2" >&2
    return 1
  fi
}

@test "State written by OpenTofu is encrypted" {
  throwaway_stack "$STACK"
  encrypt_with passphrase-of-this-test

  applied "$STACK"

  [ -f "$STACK/terraform.tfstate" ]
  absent plaintext-marker "$STACK/terraform.tfstate"
  absent terraform_data "$STACK/terraform.tfstate"
  jq -e 'has("encrypted_data") and (has("resources") | not)' "$STACK/terraform.tfstate"

  # Without any encryption settings, the state cannot be read at all.
  mkdir "$BATS_TEST_TMPDIR/bare"
  cp "$STACK/terraform.tfstate" "$BATS_TEST_TMPDIR/bare/"
  run env -u TF_ENCRYPTION tofu -chdir="$BATS_TEST_TMPDIR/bare" state list -no-color
  [ "$status" -ne 0 ]
  [[ $output == *encrypted* ]]

  # With another passphrase, it does not decrypt.
  encrypt_with another-passphrase-of-this-test
  run tofu -chdir="$STACK" state list -no-color
  [ "$status" -ne 0 ]
  [[ $output == *"decryption failed"* ]]

  encrypt_with passphrase-of-this-test
  run tofu -chdir="$STACK" state list -no-color
  [ "$status" -eq 0 ]
  [ "$output" = terraform_data.marker ]
}

@test "Unencrypted state is refused" {
  throwaway_stack "$STACK"

  run export_state_encryption

  [ "$status" -ne 0 ]
  [[ $output == *"TF_STATE_PASSPHRASE is not set"* ]]

  # Without the settings, the stack's encryption block names no method, and tofu stops on it.
  for command in "init -input=false" "plan -input=false -out=$STACK/saved.tfplan" "apply -input=false -auto-approve"; do
    read -ra arguments <<< "$command"
    run tofu -chdir="$STACK" "${arguments[@]}" -no-color
    [ "$status" -ne 0 ]
    [[ $output == *"in terraform:"*"state {"*"A single static variable reference is required"* ]]
  done
  [ ! -e "$STACK/terraform.tfstate" ]
  [ ! -e "$STACK/saved.tfplan" ]
}

@test "A stack refuses an unencrypted method from the environment" {
  export TF_ENCRYPTION='{
    "method": {"unencrypted": {"plain": {}}},
    "state": {"method": "method.unencrypted.plain"},
    "plan": {"method": "method.unencrypted.plain"}
  }'
  for stack in plumbing cluster; do
    throwaway_stack "$STACK/$stack" "$stack"

    run tofu -chdir="$STACK/$stack" init -input=false -no-color
    [ "$status" -ne 0 ]
    [[ $output == *"Unable to use unencrypted method since the enforced flag is set"* ]]
    run tofu -chdir="$STACK/$stack" apply -input=false -auto-approve -no-color
    [ "$status" -ne 0 ]
    [[ $output == *"Unable to use unencrypted method since the enforced flag is set"* ]]
    [ ! -e "$STACK/$stack/terraform.tfstate" ]
  done
}

@test "the repository's settings refuse a stack's unencrypted fallback" {
  # A stack that would read plaintext state, as a planted state object, if encryption allowed it.
  mkdir -p "$STACK"
  cat > "$STACK/main.tf" <<'EOF'
terraform {
  encryption {
    method "unencrypted" "migrate" {}
    state {
      fallback {
        method = method.unencrypted.migrate
      }
    }
    plan {
      fallback {
        method = method.unencrypted.migrate
      }
    }
  }
}

resource "terraform_data" "marker" {
  input = "plaintext-marker"
}
EOF
  encrypt_with passphrase-of-this-test

  run tofu -chdir="$STACK" init -input=false -no-color

  [ "$status" -ne 0 ]
  [[ $output == *"Unable to use unencrypted method since the enforced flag is set"* ]]
  run tofu -chdir="$STACK" plan -input=false -no-color
  [ "$status" -ne 0 ]
  [[ $output == *"Unable to use unencrypted method since the enforced flag is set"* ]]
}

@test "a saved plan is encrypted and its summary reads it" {
  throwaway_stack "$STACK"
  encrypt_with passphrase-of-this-test
  run tofu -chdir="$STACK" init -input=false -no-color
  [ "$status" -eq 0 ]

  run tofu -chdir="$STACK" plan -input=false -no-color -out="$STACK/saved.tfplan"

  [ "$status" -eq 0 ]
  encrypt_with another-passphrase-of-this-test
  run tofu -chdir="$STACK" show -json "$STACK/saved.tfplan"
  [ "$status" -ne 0 ]
  encrypt_with passphrase-of-this-test
  [ "$(tofu -chdir="$STACK" show -json "$STACK/saved.tfplan" | plan_summary)" = 'Plan: 1 to add, 0 to change, 0 to destroy.
  create: 1 terraform_data
  create: output marker' ]
}

@test "another stack reads the plumbing stack's encrypted outputs with the same settings" {
  throwaway_stack "$STACK/plumbing"
  mkdir -p "$STACK/cluster"
  cat > "$STACK/cluster/main.tf" <<EOF
data "terraform_remote_state" "plumbing" {
  backend = "local"
  config = {
    path = "$STACK/plumbing/terraform.tfstate"
  }
}

output "from_plumbing" {
  value = data.terraform_remote_state.plumbing.outputs.marker
}
EOF
  encrypt_with passphrase-of-this-test
  applied "$STACK/plumbing"

  applied "$STACK/cluster"

  [ "$(tofu -chdir="$STACK/cluster" output -raw from_plumbing)" = plaintext-marker ]
}

@test "a passphrase with quotes, backslashes and template sequences is used as written" {
  throwaway_stack "$STACK"
  # shellcheck disable=SC2016 # the template sequences must reach tofu as written, unexpanded
  encrypt_with 'a "quoted" \back\slashed ${template} %{directive} passphrase'
  applied "$STACK"

  run tofu -chdir="$STACK" state list -no-color
  [ "$status" -eq 0 ]

  # One backslash more than above.
  # shellcheck disable=SC2016 # as above
  encrypt_with 'a "quoted" \\back\slashed ${template} %{directive} passphrase'
  run tofu -chdir="$STACK" state list -no-color
  [ "$status" -ne 0 ]
  [[ $output == *"decryption failed"* ]]
}

@test "a passphrase shorter than OpenTofu accepts is refused by name" {
  run encrypt_with tooFewChars

  [ "$status" -ne 0 ]
  [[ $output == *TF_STATE_PASSPHRASE* ]]
  [[ $output != *tooFewChars* ]]
}
