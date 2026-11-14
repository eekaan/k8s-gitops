#!/usr/bin/env bats
# Proves features/cluster-recipes.feature; each test carries its scenario's title.
# The recipes run from a copy of the repository. Creating an age key, generating a secrets bundle
# and encrypting it are local and offline, so those tests run the pinned age-keygen, talman,
# talosctl and sops, recorded on their way, with every key inside the test's temporary directory.

setup_file() {
  # The Talos check's fixture cluster: talos/talman.yaml.tftpl rendered from tests/fixtures/talos,
  # as talos/<cluster>/talman.yaml is rendered from the cluster stack.
  local encoded
  encoded=$(tofu -chdir="$BATS_TEST_DIRNAME/fixtures/talos" console -no-color <<< 'base64encode(local.talman_yaml)')
  base64 -d <<< "${encoded//\"/}" > "$BATS_FILE_TMPDIR/talman.yaml"
}

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  JUST=$(command -v just)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  mkdir -p "$BIN" "$RECORD" "$BATS_TEST_TMPDIR/repo/talos/lab-sto2" "$BATS_TEST_TMPDIR/keys"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  CLUSTER="$REPO/talos/lab-sto2"
  BUNDLE="$CLUSTER/secrets.sops.yaml"
  # The scripts and the Talos tree the recipes read, so no run touches this checkout.
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp -R "$ROOT/talos/patches" "$REPO/talos/patches"
  cp "$ROOT/talos/schematic.yaml" "$ROOT/talos/.sops.yaml" "$REPO/talos/"
  cp "$ROOT/.gitignore" "$REPO/.gitignore"
  cp "$BATS_FILE_TMPDIR/talman.yaml" "$CLUSTER/talman.yaml"
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise < /dev/null
  KEY="$BATS_TEST_TMPDIR/keys/talos.agekey"
  # TMPDIR keeps the plaintext bundle talman stages before encrypting it inside the test's directory.
  BASE_ENVIRONMENT=(
    SOPS_AGE_KEY_FILE="$KEY"
    TMPDIR="$BATS_TEST_TMPDIR"
  )
  reset_environment
}

# fake NAME: a binary first on the recipe's PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# record NAME...: puts each NAME's arguments in the record, then runs the real NAME.
record() {
  local tool real
  for tool; do
    real=$(command -v "$tool")
    fake "$tool" <<EOF
printf '%s\n' "$tool \$*" >> "$RECORD/argv"
exec "$real" "\$@"
EOF
  done
}

reset_environment() {
  ENVIRONMENT=("${BASE_ENVIRONMENT[@]}")
}

# without NAME: drops NAME from the environment the recipes get.
without() {
  local kept=() entry
  for entry in "${ENVIRONMENT[@]}"; do
    [[ $entry == "$1="* ]] || kept+=("$entry")
  done
  ENVIRONMENT=("${kept[@]}")
}

# with ENTRY...: adds the NAME=VALUE ENTRY... to the environment the recipes get.
with() {
  ENVIRONMENT+=("$@")
}

# recipe NAME [ARG...]: runs the repository's recipe against the copy, with only ENVIRONMENT set.
# A recipe that blocks fails after two minutes instead of hanging the tests.
recipe() {
  run timeout 120 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$@"
}

# absent TEXT FILE...: fails when any FILE, or any file under a directory FILE, holds TEXT.
absent() {
  local text=$1
  shift
  if grep -rqF -- "$text" "$@"; then
    echo "found $text in $*" >&2
    return 1
  fi
}

# bundle_values FILE: every value of a plaintext secrets bundle, one per line.
bundle_values() {
  yq 'del(.sops) | .. | select(kind == "scalar")' "$1"
}

# A talman that writes the secrets bundle in plaintext, as with --plaintext, whatever it is asked.
plaintext_talman() {
  local real
  real=$(command -v talman)
  fake talman <<EOF
printf '%s\n' "talman \$*" >> "$RECORD/argv"
if [[ \$* == "secrets generate" ]]; then
  exec "$real" secrets generate --plaintext
fi
exec "$real" "\$@"
EOF
}

# git_repository: makes the copy a git repository, so the secrets bundle check sees what git would
# commit.
git_repository() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q "$REPO"
}

@test "The age key is created once and never printed" {
  record age-keygen yq

  recipe cluster-age-key

  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$KEY")" = 600 ]
  recipient=$(age-keygen -y "$KEY")
  [ "$output" = "$recipient" ]
  [ "$(yq '.creation_rules[].age' "$REPO/talos/.sops.yaml")" = "$recipient" ]
  cp "$KEY" "$BATS_TEST_TMPDIR/key.before"
  cp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"

  recipe cluster-age-key

  [ "$status" -eq 0 ]
  [ "$output" = "$recipient" ]
  cmp "$KEY" "$BATS_TEST_TMPDIR/key.before"
  cmp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"
  secret=$(grep '^AGE-SECRET-KEY-' "$KEY")
  absent "$secret" "$RECORD/argv" "$REPO"
}

@test "cluster-age-key refuses a key file inside the repository" {
  without SOPS_AGE_KEY_FILE
  with SOPS_AGE_KEY_FILE="$REPO/talos/talos.agekey"

  recipe cluster-age-key

  [ "$status" -ne 0 ]
  [[ $output == *"SOPS_AGE_KEY_FILE names a path inside the repository"* ]]
  [ ! -e "$REPO/talos/talos.agekey" ]
  cmp "$REPO/talos/.sops.yaml" "$ROOT/talos/.sops.yaml"
}

@test "cluster-age-key leaves a talos/.sops.yaml naming another recipient alone" {
  age-keygen -o "$BATS_TEST_TMPDIR/keys/other.agekey" 2> /dev/null
  other=$(age-keygen -y "$BATS_TEST_TMPDIR/keys/other.agekey")
  RECIPIENT=$other yq -i '.creation_rules[].age = strenv(RECIPIENT)' "$REPO/talos/.sops.yaml"
  cp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"

  recipe cluster-age-key

  [ "$status" -ne 0 ]
  [[ $output == *"talos/.sops.yaml names another recipient"* ]]
  cmp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"
  [ ! -e "$KEY" ]

  # A key of its own at SOPS_AGE_KEY_FILE does not replace the recipient either.
  age-keygen -o "$KEY" 2> /dev/null
  cp "$KEY" "$BATS_TEST_TMPDIR/key.before"

  recipe cluster-age-key

  [ "$status" -ne 0 ]
  [[ $output == *"talos/.sops.yaml names another recipient"* ]]
  cmp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/sops.before"
  cmp "$KEY" "$BATS_TEST_TMPDIR/key.before"
}

@test "Cluster secrets are written encrypted and never regenerated" {
  record talman talosctl sops age-keygen
  recipe cluster-age-key
  [ "$status" -eq 0 ]
  recipient=$output

  recipe cluster-secrets

  [ "$status" -eq 0 ]
  [ "$(sops filestatus "$BUNDLE")" = '{"encrypted":true}' ]
  [ "$(yq '.sops.age[].recipient' "$BUNDLE")" = "$recipient" ]
  [ "$(yq 'del(.sops) | [.. | select(kind == "scalar")] | length' "$BUNDLE")" -gt 0 ]
  [ "$(yq 'del(.sops) | [.. | select(kind == "scalar") | select(test("^ENC\\[") | not)] | length' "$BUNDLE")" -eq 0 ]
  SOPS_AGE_KEY_FILE="$KEY" sops decrypt "$BUNDLE" > /dev/null
  cp "$BUNDLE" "$BATS_TEST_TMPDIR/bundle.before"
  : > "$RECORD/argv"

  recipe cluster-secrets

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/secrets.sops.yaml exists"* ]]
  cmp "$BUNDLE" "$BATS_TEST_TMPDIR/bundle.before"
  run grep -c '^talman ' "$RECORD/argv"
  [ "$output" -eq 0 ]
}

@test "cluster-secrets names what it needs before it calls talman" {
  record talman
  rm "$CLUSTER/talman.yaml"

  recipe cluster-secrets

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/talman.yaml does not exist"* ]]
  [[ $output == *"talos/.sops.yaml holds no age recipient yet"* ]]
  [ ! -e "$RECORD/argv" ]
  [ ! -e "$BUNDLE" ]
}

@test "Secrets written in plaintext fail the recipe and are kept" {
  recipe cluster-age-key
  [ "$status" -eq 0 ]
  plaintext_talman

  recipe cluster-secrets

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/secrets.sops.yaml is not encrypted"* ]]
  [ -s "$BUNDLE" ]
  [ "$(sops filestatus "$BUNDLE")" = '{"encrypted":false}' ]
  while IFS= read -r value; do
    [[ $output != *"$value"* ]]
  done < <(bundle_values "$BUNDLE")
}

@test "A plaintext secrets bundle fails the check" {
  git_repository
  mkdir -p "$REPO/talos/other"
  talman -c "$CLUSTER" secrets generate --plaintext > /dev/null
  cp "$BUNDLE" "$REPO/talos/other/secrets.sops.yaml"
  git -C "$REPO" add talos/other/secrets.sops.yaml

  recipe cluster-secrets-check

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/secrets.sops.yaml is not SOPS-encrypted"* ]]
  [[ $output == *"talos/other/secrets.sops.yaml is not SOPS-encrypted"* ]]
  while IFS= read -r value; do
    [[ $output != *"$value"* ]]
  done < <(bundle_values "$BUNDLE")

  # The same bundle encrypted passes.
  git -C "$REPO" rm -q --cached talos/other/secrets.sops.yaml
  rm -r "$REPO/talos/other" "$BUNDLE"
  recipe cluster-age-key
  [ "$status" -eq 0 ]
  recipe cluster-secrets
  [ "$status" -eq 0 ]

  recipe cluster-secrets-check

  [ "$status" -eq 0 ]
}

@test "the secrets bundle check fails on a bundle with a plaintext value or without SOPS metadata" {
  git_repository
  recipe cluster-age-key
  recipe cluster-secrets
  [ "$status" -eq 0 ]
  cp "$BUNDLE" "$BATS_TEST_TMPDIR/encrypted.yaml"
  yq -i '.cluster.id = "marker-plaintext-value"' "$BUNDLE"

  recipe cluster-secrets-check

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/secrets.sops.yaml is not SOPS-encrypted"* ]]
  [[ $output != *marker-plaintext-value* ]]

  yq 'del(.sops)' "$BATS_TEST_TMPDIR/encrypted.yaml" > "$BUNDLE"

  recipe cluster-secrets-check

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/secrets.sops.yaml is not SOPS-encrypted"* ]]
}

@test "the cluster recipes refuse Go's HTTP/2 debug log" {
  record age-keygen talman
  with GODEBUG=x509sha1=1,http2debug=2

  for name in cluster-age-key cluster-secrets; do
    recipe "$name"

    [ "$status" -ne 0 ]
    [[ $output == *"GODEBUG sets http2debug"* ]]
  done
  [ ! -e "$RECORD/argv" ]
  [ ! -e "$KEY" ]
}

@test "the secrets bundle is committable and the cluster's generated files are not" {
  cd "$ROOT"

  run git check-ignore --no-index -q talos/lab-sto2/secrets.sops.yaml
  [ "$status" -eq 1 ]
  for path in talos/lab-sto2/talman.yaml talos/lab-sto2/clusterconfig/kubeconfig talos/lab-sto2/clusterconfig/talosconfig; do
    git check-ignore --no-index -q "$path"
  done
}

@test "No cluster secret reaches a command line or the output" {
  git_repository
  record talman talosctl sops age-keygen yq jq git
  printed=()
  # run_and_keep STATUS RECIPE...: runs the recipe, expects STATUS (ok or failed), keeps its output.
  run_and_keep() {
    local expected=$1
    shift
    recipe "$@"
    if [[ $expected == ok ]]; then
      [ "$status" -eq 0 ]
    else
      [ "$status" -ne 0 ]
    fi
    printed+=("$output")
  }

  run_and_keep ok cluster-age-key
  run_and_keep ok cluster-age-key
  run_and_keep ok cluster-secrets
  run_and_keep failed cluster-secrets
  run_and_keep ok cluster-secrets-check
  mv "$BUNDLE" "$BATS_TEST_TMPDIR/encrypted.yaml"
  plaintext_talman
  run_and_keep failed cluster-secrets
  run_and_keep failed cluster-secrets-check

  # The secrets: the age key, and every value of both bundles.
  markers=("$(grep '^AGE-SECRET-KEY-' "$KEY")")
  mapfile -t -O 1 markers < <(bundle_values "$BUNDLE"; SOPS_AGE_KEY_FILE="$KEY" sops decrypt "$BATS_TEST_TMPDIR/encrypted.yaml" | bundle_values /dev/stdin)
  [ "${#markers[@]}" -gt 20 ]
  grep -q '^talman secrets generate' "$RECORD/argv"
  grep -q '^sops ' "$RECORD/argv"
  grep -q '^talosctl ' "$RECORD/argv"
  rm "$BUNDLE"
  for marker in "${markers[@]}"; do
    absent "$marker" "$RECORD/argv"
    [[ ${printed[*]} != *"$marker"* ]]
    absent "$marker" "$REPO"
  done
}
