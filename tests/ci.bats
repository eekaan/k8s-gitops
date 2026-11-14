#!/usr/bin/env bats

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  WORKFLOW="$REPO/.github/workflows/ci.yaml"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
}

# checkout: a throwaway repository holding, committed, what git would commit from this one, so the run
# sees changes not yet committed here and never writes to this checkout.
checkout() {
  local path
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
  while IFS= read -r -d '' path; do
    # A file deleted here but still in the index has nothing to copy.
    [[ -e $REPO/$path || -L $REPO/$path ]] || continue
    mkdir -p -- "$WORK/$(dirname -- "$path")"
    cp -pP -- "$REPO/$path" "$WORK/$path"
  done < <(git -C "$REPO" ls-files -z --cached --others --exclude-standard)
  # On main, so the commit messages after the default branch have a range to check.
  git -C "$WORK" init -q -b main
  git -C "$WORK" add -A
  commit "checkout under test"
}

# commit MESSAGE: commits whatever is staged in the checkout, or nothing, with MESSAGE.
commit() {
  git -C "$WORK" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m "$1"
}

# run_ci [GROUP]: runs the checkout's just ci, for GROUP alone when given, with none of the pinned
# tools on PATH, so only a container can run the checks.
run_ci() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  # A mise with nothing installed keeps the justfile from putting the pinned tools on PATH.
  printf '#!/usr/bin/env bash\n' > "$bin/mise"
  chmod +x "$bin/mise"
  # The container runtime and the Dagger CLI that starts it are all the host provides.
  ln -sf "$(command -v docker)" "$bin/docker"
  if command -v dagger > /dev/null; then
    ln -sf "$(command -v dagger)" "$bin/dagger"
  fi
  run env PATH="$bin:/usr/bin:/bin" "$(command -v just)" --justfile "$WORK/justfile" --working-directory "$WORK" ci "$@"
}

# groups_of JUSTFILE: the groups of checks, the checks recipe's dependencies, one per line.
groups_of() {
  just --justfile "$1" --dump --dump-format json | jq -r '.recipes.checks.dependencies[].recipe'
}

# runs_of JUSTFILE: what each group runs, one line per recipe: the group, a tab, then the recipe as
# just runs it, its name and the arguments it is given; the recipes a group depends on and the ones
# they depend on in turn.
runs_of() {
  just --justfile "$1" --dump --dump-format json | jq -r '
    .recipes as $recipes
    | def runs($name): $recipes[$name].dependencies[]? | ([.recipe] + .arguments | join(" ")), runs(.recipe);
    $recipes.checks.dependencies[].recipe as $group | runs($group) | "\($group)\t\(.)"' | sort -u
}

# bats test_tags=hermetic
@test "The hermetic run passes on a clean tree" {
  checkout

  run_ci

  [ "$status" -eq 0 ]
  # The tools check passes only where every pinned tool is installed, and the host PATH holds none of them.
  [[ $output == *"pinned tools match mise.toml"* ]]
}

# bats test_tags=hermetic
@test "just ci runs every group, and a group runs only its own checks" {
  checkout
  mapfile -t groups < <(groups_of "$WORK/justfile")
  [ "${#groups[@]}" -gt 1 ]
  tests=$(bats --count --filter-tags '!hermetic' "$WORK/tests")

  run_ci

  for group in "${groups[@]}"; do
    [[ $output == *"== $group: passed"* ]] || { echo "not reported as passed: $group"; return 1; }
  done
  [[ $output == *"passed: ${groups[*]}"* ]]
  [ "$status" -eq 0 ]
  # Each part of the bats tests prints its plan, 1..N for its N tests; together they plan every test once.
  planned=0
  while read -r count; do
    planned=$((planned + count))
  done < <(grep -oxE '1\.\.[0-9]+' <<< "$output" | cut -c4-)
  [ "$planned" -eq "$tests" ]

  # A group of the checkout's own, with one check, runs that check and nothing else.
  sed -i 's/^checks:.*$/& literals-only/' "$WORK/justfile"
  printf '\nliterals-only: check-literals\n' >> "$WORK/justfile"
  groups_of "$WORK/justfile" | grep -qx literals-only

  run_ci literals-only

  [ "$status" -eq 0 ]
  [[ $output == *"No undeclared address literals in the files git would commit."* ]]
  [[ $output != *"pinned tools match mise.toml"* ]]
  run grep -E '^== ' <<< "$output"
  [ "$output" = "== literals-only: passed (check-literals)" ]
}

# bats test_tags=hermetic
@test "A failing check fails just ci, names itself, and does not hide the other groups' results" {
  checkout
  mkdir "$WORK/config"
  cp "$BATS_TEST_DIRNAME/fixtures/check-address-literals/undeclared.txt" "$WORK/config/resolver.txt"
  git -C "$WORK" add config/resolver.txt
  literal=$(sed -n 's/^resolver: //p' "$WORK/config/resolver.txt")
  [ -n "$literal" ]
  failing=$(runs_of "$WORK/justfile" | awk -F'\t' '$2 == "check-literals" { print $1 }')
  [ -n "$failing" ]
  mapfile -t others < <(groups_of "$WORK/justfile" | grep -vxF "$failing")
  [ "${#others[@]}" -gt 0 ]

  run_ci

  [ "$status" -ne 0 ]
  [[ $output == *"config/resolver.txt:2: $literal"* ]]
  [[ $output == *"recipe \`check-literals\` failed"* ]]
  [[ $output == *"== $failing: failed"* ]]
  for group in "${others[@]}"; do
    [[ $output == *"== $group: passed"* ]] || { echo "not reported as passed: $group"; return 1; }
  done
  [[ $output == *"failed: $failing"* ]]
}

# bats test_tags=hermetic
@test "The hermetic run checks the messages of the commits after the default branch" {
  checkout
  literal=$(sed -n 's/^resolver: //p' "$BATS_TEST_DIRNAME/fixtures/check-address-literals/undeclared.txt")
  [ -n "$literal" ]
  git -C "$WORK" switch -q -c resolver
  commit "point the resolver at $literal"
  flagged=$(git -C "$WORK" rev-parse --short=7 HEAD)

  run_ci

  [ "$status" -ne 0 ]
  [[ $output == *"commit $flagged"*":1: $literal"* ]]
}

@test "just ci shows every step where there is no terminal" {
  checkout
  bin="$BATS_TEST_TMPDIR/shown"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\n' > "$bin/mise"
  # Records how Dagger is called; a run of several minutes that prints nothing looks hung.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\n' "$BATS_TEST_TMPDIR/dagger.args" > "$bin/dagger"
  chmod +x "$bin/mise" "$bin/dagger"

  run env PATH="$bin:/usr/bin:/bin" "$(command -v just)" --justfile "$WORK/justfile" --working-directory "$WORK" ci

  [ "$status" -eq 0 ]
  grep -qx 'checks' "$BATS_TEST_TMPDIR/dagger.args"
  # This run has no terminal, like a CI job, where only plain progress prints each step as it happens.
  grep -qx -- '--progress=plain' "$BATS_TEST_TMPDIR/dagger.args"
  run grep -xE -- '--silent|-s|--quiet|-q+' "$BATS_TEST_TMPDIR/dagger.args"
  [ "$status" -ne 0 ]
}

@test "The hermetic run validates the Renovate configuration with the image renovate-check uses" {
  # What each recipe would run, with the justfile's variables filled in.
  run just --justfile "$REPO/justfile" --dry-run renovate-check
  [ "$status" -eq 0 ]
  image=$(grep -oE "ghcr\.io/renovatebot/renovate[^[:space:]'\"]*" <<< "$output" | sort -u)
  [ -n "$image" ]
  [ "$(wc -l <<< "$image")" -eq 1 ]
  [[ $image == *@sha256:* ]]
  run just --justfile "$REPO/justfile" --dry-run ci
  [ "$status" -eq 0 ]
  [[ $output == *"$image"* ]]
  # The module validates with the image the recipe hands it, so it names none of its own.
  run grep -rl 'renovatebot/renovate' "$REPO/.dagger"
  [ "$status" -eq 1 ]
}

@test "Every check belongs to exactly one group, and the groups come from the justfile" {
  # A group is named alone, so that CI can run it by its name.
  run just --justfile "$REPO/justfile" --dump --dump-format json
  [ "$status" -eq 0 ]
  run jq -r '.recipes.checks.dependencies[] | select(.arguments != []) | .recipe' <<< "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  mapfile -t groups < <(groups_of "$REPO/justfile")
  [ "${#groups[@]}" -gt 1 ]
  runs=$(runs_of "$REPO/justfile")
  for group in "${groups[@]}"; do
    grep -q "^$group	" <<< "$runs" || { echo "runs no check: $group"; return 1; }
  done
  # A recipe that two groups run would run twice in just ci, once in each group's container.
  twice=$(cut -f2 <<< "$runs" | sort | uniq -d)
  [ -z "$twice" ] || { echo "in more than one group: $twice"; return 1; }

  run env -u GITHUB_OUTPUT just --justfile "$REPO/justfile" ci-groups

  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "${groups[@]}" | jq -Rnc '[inputs]')" ]
  # The list follows the justfile it is read from: a group added there is listed.
  copy="$BATS_TEST_TMPDIR/copy"
  mkdir -p "$copy"
  cp -R "$REPO/justfile" "$REPO/just" "$copy/"
  sed -i 's/^checks:.*$/& literals-only/' "$copy/justfile"
  printf '\nliterals-only: check-literals\n' >> "$copy/justfile"
  run env -u GITHUB_OUTPUT just --justfile "$copy/justfile" ci-groups
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "${groups[@]}" literals-only | jq -Rnc '[inputs]')" ]
}

@test "Every test file runs exactly once in the parallel run" {
  # The parts of the bats tests the groups run: each test recipe they run and its arguments.
  mapfile -t parts < <(runs_of "$REPO/justfile" | cut -f2 | grep -E '^test( |$)')
  [ "${#parts[@]}" -gt 0 ]
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  # A mise with nothing installed keeps the justfile from putting the pinned tools on PATH, and a
  # bats that records what it is handed, one argument per line and a blank line after each call.
  printf '#!/usr/bin/env bash\n' > "$bin/mise"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" "" >> "%s"\n' "$BATS_TEST_TMPDIR/bats.args" > "$bin/bats"
  chmod +x "$bin/mise" "$bin/bats"

  for part in "${parts[@]}"; do
    read -ra words <<< "$part"
    run env PATH="$bin:/usr/bin:/bin" "$(command -v just)" --justfile "$REPO/justfile" --working-directory "$REPO" "${words[@]}"
    [ "$status" -eq 0 ]
  done

  handed=$(grep -E '^tests/[^/]+\.bats$' "$BATS_TEST_TMPDIR/bats.args" | sort)
  [ "$handed" = "$(cd "$REPO" && printf '%s\n' tests/*.bats | sort)" ]
  # Every call leaves out the tests that run just ci, which need a container runtime.
  calls=$(grep -cx '' "$BATS_TEST_TMPDIR/bats.args")
  [ "$(grep -cx -- '!hermetic' "$BATS_TEST_TMPDIR/bats.args")" -eq "$calls" ]
  # A file's tests run side by side, wherever bats has the lock it needs and there is more than one
  # processor; files never run side by side in one call, as the files' tests are not written for it.
  if env PATH="$bin:/usr/bin:/bin" bash -c 'command -v flock || command -v shlock' > /dev/null && (($(getconf _NPROCESSORS_ONLN) > 1)); then
    [ "$(grep -cx -- '--jobs' "$BATS_TEST_TMPDIR/bats.args")" -eq "$calls" ]
  fi
  [ "$(grep -cx -- '--no-parallelize-across-files' "$BATS_TEST_TMPDIR/bats.args")" -eq "$(grep -cx -- '--jobs' "$BATS_TEST_TMPDIR/bats.args")" ]
}

@test "The workflow's jobs are computed from the justfile" {
  # The job that lists the groups hands on what just ci-groups writes as its step's output.
  run yq '[.jobs | to_entries[] | select(.value.steps[] | .run == "just ci-groups") | .key] | .[]' "$WORKFLOW"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(wc -l <<< "$output")" -eq 1 ]
  lister=$output
  step=$(yq ".jobs.$lister.steps[] | select(.run == \"just ci-groups\") | .id" "$WORKFLOW")
  [ -n "$step" ]
  [ "$(yq ".jobs.$lister.outputs.groups" "$WORKFLOW")" = "\${{ steps.$step.outputs.groups }}" ]
  # One job per group in that list: the matrix is the list itself, not one written here.
  run yq '[.jobs | to_entries[] | select(.value | has("strategy")) | .key] | .[]' "$WORKFLOW"
  [ -n "$output" ]
  [ "$(wc -l <<< "$output")" -eq 1 ]
  runner=$output
  [ "$(yq -o=json -I=0 ".jobs.$runner.strategy.matrix | keys" "$WORKFLOW")" = '["group"]' ]
  [ "$(yq ".jobs.$runner.strategy.matrix.group | tag" "$WORKFLOW")" = '!!str' ]
  [ "$(yq ".jobs.$runner.strategy.matrix.group" "$WORKFLOW")" = "\${{ fromJSON(needs.$lister.outputs.groups) }}" ]
  [ "$(yq -o=json -I=0 "[.jobs.$runner.needs] | flatten" "$WORKFLOW")" = "[\"$lister\"]" ]
  # Each runs just ci with its group, and every group reports its own result, whichever fails first.
  [ "$(yq ".jobs.$runner.strategy.fail-fast" "$WORKFLOW")" = false ]
  run yq -o=json -I=0 "[.jobs.$runner.steps[] | select(has(\"run\"))]" "$WORKFLOW"
  [ "$output" = "$(cat <<'EOF'
[{"run":"just ci \"$GROUP\"","env":{"GROUP":"${{ matrix.group }}"}}]
EOF
)" ]

  run env GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output" just --justfile "$REPO/justfile" ci-groups

  [ "$status" -eq 0 ]
  listed=$(groups_of "$REPO/justfile" | jq -Rnc '[inputs]')
  [ "$output" = "$listed" ]
  [ "$(cat "$BATS_TEST_TMPDIR/github-output")" = "groups=$listed" ]
}

@test "The required job passes only when every group passed" {
  # The job named ci, the required check on main, runs whatever became of the jobs it waits for,
  # and waits for every other job: a skipped required check would count as passed.
  [ "$(yq '.jobs.ci.if' "$WORKFLOW")" = 'always()' ]
  [ "$(yq -o=json -I=0 '[.jobs.ci.needs] | flatten | sort' "$WORKFLOW")" = "$(yq -o=json -I=0 '[.jobs | keys | .[] | select(. != "ci")] | sort' "$WORKFLOW")" ]
  # It hands the result of each of them to the recipe that decides.
  run yq -o=json -I=0 '[.jobs.ci.steps[] | select(has("run"))]' "$WORKFLOW"
  [ "$output" = "$(cat <<'EOF'
[{"run":"just ci-passed $RESULTS","env":{"RESULTS":"${{ join(needs.*.result, ' ') }}"}}]
EOF
)" ]

  run just --justfile "$REPO/justfile" ci-passed success success success
  [ "$status" -eq 0 ]
  for result in failure cancelled skipped; do
    run just --justfile "$REPO/justfile" ci-passed success "$result" success
    [ "$status" -ne 0 ]
    [[ $output == *"$result"* ]]
  done
  run just --justfile "$REPO/justfile" ci-passed
  [ "$status" -ne 0 ]
}

@test "The workflow keeps its triggers, permissions and pinned actions" {
  # A required check from a workflow that a path filter kept from starting never reports.
  run yq '[.on | .. | select(tag == "!!map") | keys | .[] | select(test("^paths"))] | length' "$WORKFLOW"
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
  # pull_request_target would run with write access and secrets for a fork.
  [ "$(yq -o=json -I=0 '.on | keys' "$WORKFLOW")" = '["pull_request","push"]' ]
  [ "$(yq -o=json -I=0 '.on.push.branches' "$WORKFLOW")" = '["main"]' ]
  [ "$(yq -o=json -I=0 '.permissions' "$WORKFLOW")" = '{"contents":"read"}' ]
  [ "$(yq '[.jobs[] | select(has("permissions"))] | length' "$WORKFLOW")" = 0 ]
  [ "$(yq '[.. | select(tag == "!!str") | select(test("secrets\."))] | length' "$WORKFLOW")" = 0 ]
  # A new push to a pull request cancels its older run; each push to main keeps its own.
  [ "$(yq '.concurrency.group' "$WORKFLOW")" = "ci-\${{ github.event.pull_request.number || github.sha }}" ]
  [ "$(yq '.concurrency.cancel-in-progress' "$WORKFLOW")" = true ]
  [ "$(yq '[.jobs[] | select(has("concurrency"))] | length' "$WORKFLOW")" = 0 ]
  # Every job checks out the same way with the same pinned action, then installs with the same
  # pinned mise-action and mise.
  jobs=$(yq '.jobs | length' "$WORKFLOW")
  [ "$(yq '[.jobs[] | select(.steps[0].uses | test("^actions/checkout@"))] | length' "$WORKFLOW")" -eq "$jobs" ]
  [ "$(yq '[.jobs[].steps[0].uses] | unique | length' "$WORKFLOW")" = 1 ]
  [ "$(yq '[.jobs[].steps[0].with | to_entries | sort_by(.key) | from_entries | @json] | unique | .[]' "$WORKFLOW")" = '{"fetch-depth":0,"persist-credentials":false}' ]
  [ "$(yq '[.jobs[] | select(.steps[1].uses | test("^jdx/mise-action@"))] | length' "$WORKFLOW")" -eq "$jobs" ]
  [ "$(yq '[.jobs[].steps[1] | {"uses": .uses, "version": .with.version} | @json] | unique | length' "$WORKFLOW")" = 1 ]
  # The rest are commands, each one just recipe and nothing else.
  run yq '.jobs[].steps[] | select(has("run")) | .run' "$WORKFLOW"
  [ -n "$output" ]
  local recipe='^just [a-z][a-z0-9-]*( [^;&|<>`()]*)?$'
  while IFS= read -r command; do
    [[ $command =~ $recipe ]] || { echo "not one just recipe: $command"; return 1; }
  done <<< "$output"
  [ "$(yq '[.jobs[].steps[] | select(has("run"))] | length' "$WORKFLOW")" -eq "$jobs" ]
  [ "$(yq '[.jobs[].steps[] | select(has("uses") | not) | select(has("run") | not)] | length' "$WORKFLOW")" = 0 ]
}

@test "The publish workflow runs one recipe with only the permissions it needs, and runs queue" {
  local publish="$REPO/.github/workflows/publish.yaml"
  [ -f "$publish" ]
  run yq -o=json -I=0 '.jobs | keys' "$publish"
  [ "$status" -eq 0 ]
  [ "$output" = '["publish"]' ]
  run yq -o=json -I=0 '[.jobs[].steps[] | select(has("run")) | .run]' "$publish"
  [ "$output" = '["just publish"]' ]
  run yq '.jobs.publish.steps[-1].run' "$publish"
  [ "$output" = "just publish" ]
  # A pull request, from a fork or not, never gets packages: write or an identity token.
  run yq -o=json -I=0 '.on | keys' "$publish"
  [ "$output" = '["push","workflow_dispatch"]' ]
  run yq -o=json -I=0 '.on.push | keys' "$publish"
  [ "$output" = '["branches","paths"]' ]
  run yq -o=json -I=0 '.on.push.branches' "$publish"
  [ "$output" = '["main"]' ]
  run yq -o=json -I=0 '.on.push.paths | sort' "$publish"
  [ "$output" = '[".github/workflows/publish.yaml","kubernetes/**"]' ]
  run yq -o=json -I=0 '.permissions | to_entries | sort_by(.key) | from_entries' "$publish"
  [ "$output" = '{"contents":"read","id-token":"write","packages":"write"}' ]
  run yq '[.jobs[] | select(has("permissions") or has("concurrency"))] | length' "$publish"
  [ "$output" = 0 ]
  # One group for every run, whatever its ref, and a run in progress is never cancelled: a newer
  # run waits for it.
  run yq '.concurrency.group' "$publish"
  [ -n "$output" ]
  [[ $output != *"\${{"* ]]
  run yq '.concurrency.cancel-in-progress' "$publish"
  [ "$output" = false ]
  # The newest-commit guard reads main's history; the job's token is not left in the checkout.
  run yq -o=json -I=0 '[.jobs.publish.steps[] | select(.uses | test("^actions/checkout@")) | .with | to_entries | sort_by(.key) | from_entries]' "$publish"
  [ "$output" = '[{"fetch-depth":0,"persist-credentials":false}]' ]
  # The same pinned mise-action and mise as every CI job, installing the pinned tools the recipe runs and no others.
  local select='[.jobs[].steps[] | select(.uses | test("^jdx/mise-action@")) | {"uses": .uses, "version": .with.version} | @json] | unique'
  run yq -o=json -I=0 "$select" "$publish"
  [ "$(yq 'length' <<< "$output")" -eq 1 ]
  [ "$output" = "$(yq -o=json -I=0 "$select" "$WORKFLOW")" ]
  run yq '.jobs.publish.steps[] | select(.uses | test("^jdx/mise-action@")) | .with.install_args' "$publish"
  [ "$(tr ' ' '\n' <<< "$output" | sort | paste -sd ' ')" = "cosign flux2 jq just" ]
  local tool
  for tool in $output; do
    yq -p toml -o yaml -e ".tools | has(\"$tool\")" "$REPO/mise.toml" > /dev/null || { echo "not pinned in mise.toml: $tool"; return 1; }
  done
}

@test "Every action in every workflow is pinned to a commit" {
  local workflow refs=0
  shopt -s nullglob
  for workflow in "$REPO"/.github/workflows/*.yaml "$REPO"/.github/workflows/*.yml; do
    run yq '.. | select(tag == "!!map" and has("uses")) | .uses' "$workflow"
    [ "$status" -eq 0 ]
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      refs=$((refs + 1))
      [[ $ref =~ ^[^@[:space:]]+@[0-9a-f]{40}$ ]] || { echo "${workflow##*/}: not pinned to a commit: $ref"; return 1; }
    done <<< "$output"
  done
  [ "$refs" -gt 0 ]
}
