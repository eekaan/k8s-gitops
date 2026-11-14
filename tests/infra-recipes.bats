#!/usr/bin/env bats

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/infra-recipes"
  JUST=$(command -v just)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  mkdir -p "$BIN" "$RECORD" "$BATS_TEST_TMPDIR/repo/infra/openstack/stacks/sto2/plumbing" \
    "$BATS_TEST_TMPDIR/repo/infra/openstack/stacks/sto2/cluster"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  # A copy of the scripts, the backend file and both stacks' configuration, so no run touches this
  # checkout and a renamed stack input fails here.
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp "$ROOT/infra/openstack/backend.hcl" "$REPO/infra/openstack/backend.hcl"
  PLUMBING="$REPO/infra/openstack/stacks/sto2/plumbing"
  CLUSTER="$REPO/infra/openstack/stacks/sto2/cluster"
  cp "$ROOT"/infra/openstack/stacks/sto2/plumbing/*.tf "$PLUMBING/"
  cp "$ROOT"/infra/openstack/stacks/sto2/cluster/*.tf "$CLUSTER/"
  # What tofu itself prints: a resource address on stdout, and on stderr when it fails.
  STDOUT_MARKER='module.fixture.openstack_networking_port_v2.stdout_marker'
  ERROR_MARKER='module.fixture.openstack_networking_port_v2.error_marker'
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise < /dev/null
  recording_tofu
  # The tools the recipes hand values to, recorded on their way to the real binaries.
  for tool in jq yq grep flock; do
    record "$tool"
  done
  # talman, which infra-apply runs on the cluster's talman.yaml, recorded and agreeing with the
  # fixture's schematic ID; tests/infra-talman.bats runs the real one.
  fake talman <<EOF
printf '%s\n' "talman \$*" >> "$RECORD/argv"
if [[ " \$* " == *' schematic id -o json '* ]]; then
  jq '{nodes: [{hostname: "fixture", schematicID: .schematic_id.value}]}' "$FIXTURES/outputs.json"
fi
EOF
  # Everything the recipes read; the secrets are markers that must never be seen.
  BASE_ENVIRONMENT=(
    TF_STATE_BUCKET=fixture-state-bucket
    AWS_ACCESS_KEY_ID=marker-access-key-id
    AWS_SECRET_ACCESS_KEY=marker-secret-access-key
    TF_STATE_PASSPHRASE=marker-state-passphrase
    OS_AUTH_URL=https://identity.example.invalid/v3
    OS_APPLICATION_CREDENTIAL_SECRET=marker-application-credential-secret
    'OPERATOR_CIDRS=["203.0.113.77/32"]'
  )
  reset_environment
  MARKERS=(
    marker-access-key-id
    marker-secret-access-key
    marker-state-passphrase
    marker-application-credential-secret
    203.0.113.77
    marker-sensitive-network-id
    "$STDOUT_MARKER"
  )
}

# fake NAME: a binary first on the recipe's PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# record NAME: puts NAME's arguments in the record, then runs the real NAME.
record() {
  local real
  real=$(command -v "$1")
  fake "$1" <<EOF
printf '%s\n' "$1 \$*" >> "$RECORD/argv"
exec "$real" "\$@"
EOF
}

# recording_tofu [PLAN_JSON [FAILING_SUBCOMMAND]]: a tofu that records its arguments, one call per
# line, and its environment per subcommand; prints a resource address on stdout as tofu's own
# report; shows PLAN_JSON as every saved plan; and fails FAILING_SUBCOMMAND with an error naming a
# resource.
recording_tofu() {
  fake tofu <<EOF
printf '%s\n' "\$*" >> "$RECORD/tofu"
printf '%s\n' "tofu \$*" >> "$RECORD/argv"
env -0 > "$RECORD/env.\${2-}"
case \${2-} in
  init | plan | apply) echo "$STDOUT_MARKER: tofu's own report" ;;
  show) cat "${1:-$FIXTURES/no-changes.json}" ;;
  output) cat "$FIXTURES/outputs.json" ;;
esac
if [[ \${2-} == "${2:-none}" ]]; then
  echo "Error: fixture failure in $ERROR_MARKER" >&2
  exit 1
fi
EOF
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

# only [ENTRY...]: the recipes get the NAME=VALUE ENTRY... and nothing else.
only() {
  ENVIRONMENT=("$@")
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

# tofu_calls SUBCOMMAND: the recorded tofu calls of SUBCOMMAND, as recorded.
tofu_calls() {
  awk -v subcommand="$1" '$2 == subcommand' "$RECORD/tofu" 2> /dev/null
}

# tofu_env SUBCOMMAND NAME: NAME's value in the environment of the last tofu SUBCOMMAND.
tofu_env() {
  local entry
  while IFS= read -r -d '' entry; do
    if [[ $entry == "$2="* ]]; then
      printf '%s\n' "${entry#*=}"
    fi
  done < "$RECORD/env.$1"
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

@test "A missing required variable is named and nothing runs" {
  for name in TF_STATE_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY TF_STATE_PASSPHRASE OS_AUTH_URL OPERATOR_CIDRS; do
    for how in unset empty; do
      echo "$name $how"
      reset_environment
      without "$name"
      if [[ $how == empty ]]; then
        with "$name="
      fi
      rm -f "$RECORD/tofu"

      recipe infra-plan sto2/cluster

      [ "$status" -ne 0 ]
      [[ $output == *"$name is not set"* ]]
      [ ! -e "$RECORD/tofu" ]
    done
  done
}

@test "An empty or placeholder value is refused by name" {
  cp "$ROOT/.env.example" "$REPO/.env"
  only

  recipe infra-plan sto2/plumbing

  [ "$status" -ne 0 ]
  for name in TF_STATE_BUCKET OS_CLOUD; do
    [[ $output == *"$name still holds the placeholder from .env.example"* ]]
  done
  for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY TF_STATE_PASSPHRASE; do
    [[ $output == *"$name is not set"* ]]
  done
  [ ! -e "$RECORD/tofu" ]
}

@test "The .env file is read as literal NAME=value lines" {
  # shellcheck disable=SC2016 # the lines must hold dollar signs and backticks as written
  printf '%s\n' \
    '# A comment, and a blank line.' \
    '' \
    'TF_STATE_BUCKET="fixture-state-bucket"' \
    "AWS_ACCESS_KEY_ID='marker-access-key-id'" \
    'AWS_SECRET_ACCESS_KEY=marker-secret-$HOME-$UNSET_VARIABLE' \
    'TF_STATE_PASSPHRASE=marker-passphrase-$$-`touch '"$BATS_TEST_TMPDIR"'/ran`-"inner"' \
    'OS_AUTH_URL=https://identity.example.invalid/v3' \
    "OPERATOR_CIDRS='[\"203.0.113.77/32\"]'" > "$REPO/.env"
  only

  recipe infra-plan sto2/cluster

  [ "$status" -eq 0 ]
  [[ " $(tofu_calls init) " == *" -backend-config=bucket=fixture-state-bucket "* ]]
  [ "$(tofu_env plan AWS_ACCESS_KEY_ID)" = marker-access-key-id ]
  # shellcheck disable=SC2016 # as above
  [ "$(tofu_env plan AWS_SECRET_ACCESS_KEY)" = 'marker-secret-$HOME-$UNSET_VARIABLE' ]
  # shellcheck disable=SC2016 # as above
  [ "$(tofu_env plan TF_ENCRYPTION | jq -r .key_provider.pbkdf2.state.passphrase)" = 'marker-passphrase-$$-`touch '"$BATS_TEST_TMPDIR"'/ran`-"inner"' ]
  [ "$(tofu_env plan TF_VAR_api_allowed_cidrs | jq -c .)" = '["203.0.113.77/32"]' ]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "A .env line that is not NAME=value is refused by its number" {
  for line in 'not-an-assignment marker-bad-line' 'lower_case=marker-bad-line' \
    'export TF_STATE_BUCKET=marker-bad-line' 'BAD NAME=marker-bad-line' '=marker-bad-line'; do
    echo "$line"
    printf '%s\n' "${BASE_ENVIRONMENT[@]:0:2}" "$line" "${BASE_ENVIRONMENT[@]:2}" > "$REPO/.env"
    only
    rm -f "$RECORD/tofu"

    recipe infra-plan sto2/plumbing

    [ "$status" -ne 0 ]
    [[ $output == *".env line 3 "* ]]
    [[ $output != *marker-bad-line* ]]
    [ ! -e "$RECORD/tofu" ]
  done
}

@test "OpenTofu's logging and workspace variables are refused" {
  for name in TF_LOG TF_LOG_PATH TF_LOG_CORE TF_LOG_PROVIDER TF_WORKSPACE; do
    echo "$name"
    reset_environment
    with "$name=marker-log-setting"
    rm -f "$RECORD/tofu"

    recipe infra-plan sto2/plumbing

    [ "$status" -ne 0 ]
    [[ $output == *"$name is set"* ]]
    [[ $output != *marker-log-setting* ]]
    [ ! -e "$RECORD/tofu" ]
  done
}

@test "The backend is configured from the environment" {
  recipe infra-plan sto2/plumbing

  [ "$status" -eq 0 ]
  init=$(tofu_calls init)
  [ "$(wc -l <<< "$init")" -eq 1 ]
  [[ " $init " == *" -chdir=$PLUMBING "* ]]
  [[ " $init " == *" -backend-config=$REPO/infra/openstack/backend.hcl "* ]]
  [[ " $init " == *" -backend-config=bucket=fixture-state-bucket "* ]]
  [[ " $init " == *" -backend-config=key=sto2/plumbing.tfstate "* ]]
  cmp "$REPO/infra/openstack/backend.hcl" "$ROOT/infra/openstack/backend.hcl"
}

@test "No secret reaches a command line or the output" {
  fake_openstack
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

  run_and_keep ok infra-plan sto2/plumbing
  run_and_keep ok infra-apply sto2/plumbing --yes < /dev/null
  run_and_keep ok infra-plan sto2/cluster
  run_and_keep ok infra-apply sto2/cluster --yes < /dev/null
  run_and_keep ok infra-output sto2/plumbing talos_version
  run_and_keep failed infra-output sto2/plumbing network
  run_and_keep ok os-smoke
  run_and_keep ok infra-destroy --yes < /dev/null
  # The ways a run stops: confirmation declined, the stack busy, tofu failing, in and out of CI.
  run_and_keep failed infra-destroy <<< no
  run_and_keep failed infra-apply sto2/cluster <<< no
  mkdir -p "$PLUMBING/.terraform"
  exec {held}> "$PLUMBING/.terraform/infra.lock"
  flock -n "$held"
  run_and_keep failed infra-plan sto2/plumbing
  exec {held}>&-
  for subcommand in init plan apply; do
    recording_tofu "$FIXTURES/no-changes.json" "$subcommand"
    run_and_keep failed infra-apply sto2/cluster --yes < /dev/null
    with CI=true
    run_and_keep failed infra-apply sto2/cluster --yes < /dev/null
    without CI
  done

  # The record holds every call: tofu's and those of the tools the recipes pass values to.
  grep -q '^tofu .* apply ' "$RECORD/argv"
  grep -q '^jq ' "$RECORD/argv"
  grep -q '^flock ' "$RECORD/argv"
  grep -q '^openstack ' "$RECORD/argv"
  [[ ${printed[*]} == *"is busy"* ]]
  [[ ${printed[*]} == *"was not confirmed"* ]]
  [[ ${printed[*]} == *"$ERROR_MARKER"* ]]
  for marker in "${MARKERS[@]}"; do
    absent "$marker" "$RECORD/argv"
    [[ ${printed[*]} != *"$marker"* ]]
    absent "$marker" "$REPO"
  done
}

@test "The plan summary shows counts and types only" {
  recording_tofu "$FIXTURES/plan.json"

  recipe infra-plan sto2/plumbing

  [ "$status" -eq 0 ]
  summary='Plan: 4 to add, 1 to change, 2 to destroy.
  create: 1 openstack_compute_instance_v2
  create: 2 openstack_networking_port_v2
  update: 1 openstack_networking_router_v2
  replace: 1 openstack_networking_floatingip_v2
  delete: 1 openstack_blockstorage_volume_v3'
  [[ $output == *"$summary"* ]]
  [[ $output != *"$STDOUT_MARKER"* ]]
  while IFS= read -r shown; do
    if [[ $output == *"$shown"* ]]; then
      echo "the summary shows $shown" >&2
      return 1
    fi
  done < <(jq -r '.resource_changes[] | .address, (.change.before, .change.after | .. | strings)' "$FIXTURES/plan.json")
}

@test "Errors from tofu stay out of a public CI log" {
  recording_tofu "$FIXTURES/no-changes.json" plan
  with CI=true

  recipe infra-plan sto2/plumbing

  [ "$status" -ne 0 ]
  [[ $output == *"tofu plan failed for sto2/plumbing; its errors are in infra/openstack/stacks/sto2/plumbing/.terraform/tofu-errors.log"* ]]
  [[ $output != *"$ERROR_MARKER"* ]]
  grep -qF "$ERROR_MARKER" "$PLUMBING/.terraform/tofu-errors.log"

  without CI
  recipe infra-plan sto2/plumbing

  [ "$status" -ne 0 ]
  [[ $output == *"$ERROR_MARKER"* ]]
}

@test "One non-sensitive output is printed and a sensitive one is refused" {
  recipe infra-output sto2/plumbing talos_version

  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = v0.0.0-fixture ]
  [[ $(tofu_calls output) == "-chdir=$PLUMBING output -json"* ]]

  recipe infra-output sto2/plumbing network

  [ "$status" -ne 0 ]
  [[ $output == *"network is sensitive"* ]]
  [[ $output != *marker-sensitive-network-id* ]]
  [[ $output != *192.0.2.0* ]]

  recipe infra-output sto2/plumbing nothing

  [ "$status" -ne 0 ]
  [[ $output == *"sto2/plumbing has no output nothing"* ]]
}

@test "The allowlist reaches the cluster stack through the environment" {
  without OPERATOR_CIDRS
  printf '%s\n' '["198.51.100.0/24", "203.0.113.7/32"]' > "$REPO/operator-cidrs.json"

  recipe infra-plan sto2/cluster

  [ "$status" -eq 0 ]
  [ "$(tofu_env plan TF_VAR_api_allowed_cidrs | jq -c .)" = '["198.51.100.0/24","203.0.113.7/32"]' ]
  for address in 198.51.100.0 203.0.113.7; do
    absent "$address" "$RECORD/argv"
    [[ $output != *"$address"* ]]
  done
}

@test "Two operations on one stack do not overlap" {
  # The first operation's tofu holds on until the test releases it.
  fake tofu <<EOF
if [[ \${2-} == init ]]; then
  : > "$BATS_TEST_TMPDIR/started"
  for _ in {1..100}; do
    [[ -e "$BATS_TEST_TMPDIR/release" ]] && break
    sleep 0.1
  done
elif [[ \${2-} == show ]]; then
  cat "$FIXTURES/no-changes.json"
fi
EOF
  env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" infra-plan sto2/plumbing \
    > "$BATS_TEST_TMPDIR/first.out" 2>&1 &
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

@test "Apply asks before it applies the saved plan" {
  recording_tofu "$FIXTURES/plan.json"

  recipe infra-apply sto2/plumbing <<< "no"

  [ "$status" -ne 0 ]
  [[ $output == *"Plan: 4 to add, 1 to change, 2 to destroy."* ]]
  [ -z "$(tofu_calls apply)" ]

  rm -f "$RECORD/tofu"
  recipe infra-apply sto2/plumbing <<< "sto2/plumbing"

  [ "$status" -eq 0 ]
  [ "$(tofu_calls plan | wc -l)" -eq 1 ]
  [[ " $(tofu_calls plan) " =~ \ -out=([^ ]+)\  ]]
  saved=${BASH_REMATCH[1]}
  [[ $(tofu_calls apply) == "-chdir=$PLUMBING apply "*" $saved" ]]
}

@test "Destroy takes the cluster before the plumbing and asks first" {
  recipe infra-destroy <<< "no"

  [ "$status" -ne 0 ]
  [ -z "$(tofu_calls apply)" ]
  [ -z "$(tofu_calls destroy)" ]

  rm -f "$RECORD/tofu"
  recipe infra-destroy <<< $'sto2/cluster\nsto2/plumbing'

  [ "$status" -eq 0 ]
  [ "$(tofu_calls plan | awk '{ print $1 }')" = "-chdir=$CLUSTER
-chdir=$PLUMBING" ]
  [ "$(tofu_calls plan | grep -c ' -destroy')" -eq 2 ]
  [ "$(tofu_calls apply | awk '{ print $1 }')" = "-chdir=$CLUSTER
-chdir=$PLUMBING" ]
}

@test "infra-destroy --yes destroys the cluster and then the plumbing without asking" {
  recipe infra-destroy --yes < /dev/null

  [ "$status" -eq 0 ]
  [ "$(tofu_calls apply | awk '{ print $1 }')" = "-chdir=$CLUSTER
-chdir=$PLUMBING" ]
}

@test "infra-destroy leaves the plumbing stack when the cluster destroy fails" {
  fake tofu <<EOF
printf '%s\n' "\$*" >> "$RECORD/tofu"
case \${2-} in
  show) cat "$FIXTURES/no-changes.json" ;;
  apply) [[ \$1 != *cluster ]] ;;
esac
EOF

  recipe infra-destroy --yes < /dev/null

  [ "$status" -ne 0 ]
  [[ $(tofu_calls apply) == "-chdir=$CLUSTER apply "* ]]
  absent "-chdir=$PLUMBING " "$RECORD/tofu"
}

@test "infra-apply --yes applies the plan it saved under the stack's .terraform without asking" {
  recipe infra-apply sto2/plumbing --yes < /dev/null

  [ "$status" -eq 0 ]
  plan=$(tofu_calls plan)
  [[ " $plan " =~ \ -out=("$PLUMBING"/\.terraform/[^ ]+)\  ]]
  saved=${BASH_REMATCH[1]}
  [[ " $(tofu_calls show) " == *" $saved "* ]]
  [[ " $(tofu_calls apply) " == *" $saved "* ]]
}

@test "the cluster stack gets the plumbing stack's state settings through the environment" {
  recipe infra-plan sto2/cluster

  [ "$status" -eq 0 ]
  state=$(tofu_env plan TF_VAR_plumbing_state)
  backend=$(yq -p hcl -o json "$ROOT/infra/openstack/backend.hcl")
  [ "$(jq -r .bucket <<< "$state")" = fixture-state-bucket ]
  [ "$(jq -r .key <<< "$state")" = sto2/plumbing.tfstate ]
  [ "$(jq -c 'del(.bucket, .key)' <<< "$state")" = "$(jq -c . <<< "$backend")" ]

  recipe infra-plan sto2/plumbing

  [ "$status" -eq 0 ]
  [ -z "$(tofu_env plan TF_VAR_plumbing_state)" ]
  [ -z "$(tofu_env plan TF_VAR_api_allowed_cidrs)" ]
}

@test "tofu gets the encryption settings and not the passphrase variable" {
  recipe infra-plan sto2/plumbing

  [ "$status" -eq 0 ]
  [ "$(tofu_env plan TF_ENCRYPTION | jq -r .key_provider.pbkdf2.state.passphrase)" = marker-state-passphrase ]
  [ -z "$(tofu_env plan TF_STATE_PASSPHRASE)" ]
}

@test "a .env at the repository root supplies the environment" {
  cat > "$REPO/.env" <<'EOF'
TF_STATE_BUCKET=fixture-state-bucket
AWS_ACCESS_KEY_ID=marker-access-key-id
AWS_SECRET_ACCESS_KEY=marker-secret-access-key
TF_STATE_PASSPHRASE=marker-state-passphrase
OS_CLOUD=fixture-cloud
OPERATOR_CIDRS='["203.0.113.77/32"]'
EOF
  only

  recipe infra-plan sto2/cluster

  [ "$status" -eq 0 ]
  [[ " $(tofu_calls init) " == *" -backend-config=bucket=fixture-state-bucket "* ]]
  [ "$(tofu_env plan TF_VAR_api_allowed_cidrs | jq -c .)" = '["203.0.113.77/32"]' ]
}

@test "an allowlist that is not a list of CIDRs is refused without being printed" {
  without OPERATOR_CIDRS
  with 'OPERATOR_CIDRS=["203.0.113.77/32", "marker-not-a-cidr"]'

  recipe infra-plan sto2/cluster

  [ "$status" -ne 0 ]
  [[ $output == *OPERATOR_CIDRS* ]]
  [[ $output != *marker-not-a-cidr* ]]
  [[ $output != *203.0.113.77* ]]
  [ ! -e "$RECORD/tofu" ]
}

@test "infra-plan names a stack that does not exist" {
  recipe infra-plan sto2/nothing

  [ "$status" -ne 0 ]
  [[ $output == *sto2/nothing* ]]
  [ ! -e "$RECORD/tofu" ]
}

@test "the recipes say flock is required when it is missing" {
  # A PATH with the tools the recipes use, but no flock.
  tools="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$tools"
  for tool in bash env dirname mkdir cat paste sed awk tr sort; do
    ln -s "$(command -v "$tool")" "$tools/$tool"
  done
  rm "$BIN/flock"

  run env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$tools" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" infra-plan sto2/plumbing

  [ "$status" -ne 0 ]
  [[ $output == *"flock is required"* ]]
  [[ $output != *busy* ]]
  [ ! -e "$RECORD/tofu" ]
}

@test "the unimplemented hooks say so when they are reached" {
  recipe infra-plan sto2/cluster

  [ "$status" -eq 0 ]
  [[ $output == *"not implemented: adding this machine's public address to the allowlist"* ]]

  recipe infra-destroy --yes < /dev/null

  [ "$status" -eq 0 ]
  [[ $output == *"not implemented: removing the load balancers and volumes the cluster created outside OpenTofu; they are left in place"* ]]
}

# fake_openstack [--missing-flavor NAME] [--version TEXT] [--no-octavia] [--lb-quota JSON]:
# answers os-smoke's reads from the fixtures, records its arguments and its environment.
fake_openstack() {
  local missing=none version='openstack 10.5.0' octavia=0 lb_quota='{"load_balancer": 4482, "listener": 4483}'
  while (($#)); do
    case $1 in
      --missing-flavor)
        missing=$2
        shift
        ;;
      --version)
        version=$2
        shift
        ;;
      --no-octavia) octavia=1 ;;
      --lb-quota)
        lb_quota=$2
        shift
        ;;
    esac
    shift
  done
  fake openstack <<EOF
printf '%s\n' "openstack \$*" >> "$RECORD/argv"
env -0 > "$RECORD/env.openstack"
case "\$*" in
  --version) echo '$version' ;;
  'loadbalancer quota show --help') exit $octavia ;;
  'token issue -f value -c project_id') echo fixture-project-id ;;
  'quota show --usage -f json') cat "$FIXTURES/quota.json" ;;
  'loadbalancer quota show fixture-project-id -f json') echo '$lb_quota' ;;
  'loadbalancer list -f json') echo '[{"id": "fixture-lb-id"}]' ;;
  'flavor show $missing -f value -c name') echo "No Flavor found for $missing" >&2; exit 1 ;;
  'flavor show '*' -f value -c name') echo "\$3" ;;
  'network show ext-net -f json') echo '{"id": "fixture-network-id", "router:external": true}' ;;
  *) echo "unexpected call: openstack \$*" >&2; exit 1 ;;
esac
EOF
}

# The flavors the cluster stack's variables name, which os-smoke must check.
stack_flavors() {
  yq -p hcl -o json "$CLUSTER/variables.tf" |
    jq -r '.variable | to_entries[] | select(.key | test("flavors?$")) | .value.default | strings'
}

# no_figures_in OUTPUT: fails when OUTPUT holds any quota or usage figure the fake cloud reports.
no_figures_in() {
  local figure
  for figure in $(jq '.. | numbers | select(. > 99)' "$FIXTURES/quota.json") 4482 4483; do
    if [[ $1 == *"$figure"* ]]; then
      echo "os-smoke printed the figure $figure" >&2
      return 1
    fi
  done
}

@test "os-smoke passes when every item is there and prints no figures" {
  fake_openstack
  only OS_CLOUD=fixture-cloud

  recipe os-smoke

  [ "$status" -eq 0 ]
  [[ $output == *"pass  openstack client"* ]]
  [[ $output == *"pass  token"* ]]
  flavors=$(stack_flavors)
  [ -n "$flavors" ]
  while IFS= read -r flavor; do
    [[ $output == *"pass  flavor $flavor"* ]]
  done <<< "$flavors"
  [[ $output == *"pass  external network ext-net"* ]]
  for item in instances cores ram volumes gigabytes networks subnets routers floating-ips secgroup-rules load-balancers; do
    [[ $output == *"pass  quota $item"* ]]
  done
  [[ $output != *FAIL* ]]
  no_figures_in "$output"
  [[ $output != *fixture-project-id* ]]
  [[ $output != *fixture-network-id* ]]
}

@test "os-smoke fails naming a flavor that does not exist" {
  missing=$(stack_flavors | tail -1)
  fake_openstack --missing-flavor "$missing"
  only OS_CLOUD=fixture-cloud

  recipe os-smoke

  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  flavor $missing"* ]]
  [[ $output == *"pass  flavor $(stack_flavors | head -1)"* ]]
  no_figures_in "$output"
}

@test "os-smoke names the client it needs" {
  fake_openstack --version 'openstack 6.2.0'
  only OS_CLOUD=fixture-cloud

  recipe os-smoke

  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  openstack client: python-openstackclient 7.0.0 or newer is needed"* ]]
  [[ $output != *"pass  token"* ]]

  fake_openstack --no-octavia

  recipe os-smoke

  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  openstack client: its load-balancer plugin, python-octaviaclient, is needed"* ]]
}

@test "os-smoke reads a load-balancer quota reported as a string and never evaluates it" {
  fake_openstack --lb-quota '{"load_balancer": "4482"}'
  only OS_CLOUD=fixture-cloud

  recipe os-smoke

  [ "$status" -eq 0 ]
  [[ $output == *"pass  quota load-balancers"* ]]

  # Bash arithmetic would run the command substitution in this string's subscript.
  # shellcheck disable=SC2016 # the substitution must reach os-smoke unexpanded
  fake_openstack --lb-quota '{"load_balancer": "BASH_VERSINFO[$(touch '"$BATS_TEST_TMPDIR"'/evaluated)]"}'

  recipe os-smoke

  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  quota load-balancers: not reported"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/evaluated" ]
  [[ $output != *evaluated* ]]
}

@test "os-smoke keeps the S3 keys and the passphrase from the openstack client" {
  fake_openstack
  with OS_CLOUD=fixture-cloud

  recipe os-smoke

  [ "$status" -eq 0 ]
  for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY TF_STATE_PASSPHRASE; do
    if tr '\0' '\n' < "$RECORD/env.openstack" | grep -q "^$name="; then
      echo "the openstack client got $name" >&2
      return 1
    fi
  done
}
