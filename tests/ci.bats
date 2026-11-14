#!/usr/bin/env bats

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  WORKFLOW="$REPO/.github/workflows/ci.yaml"
  COMMENT="$REPO/.github/workflows/render-comment.yaml"
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
  # It waits for the list and for the job that picks the runner the groups run on, and nothing else.
  chooser=$(yq '[.jobs | to_entries[] | select(.value.steps[] | .run == "just ci-runner") | .key] | .[]' "$WORKFLOW")
  [ -n "$chooser" ]
  [ "$(yq -o=json -I=0 "[.jobs.$runner.needs] | flatten | sort" "$WORKFLOW")" = "$(jq -cn --arg a "$lister" --arg b "$chooser" '[$a, $b] | sort')" ]
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

# event KIND: sets EVENT to the variables GitHub Actions gives a job of the CI workflow of
# fixture-owner/fixture-repo, with the event's payload: push (to main), branch (a pull request from
# a branch of the repository) or fork (a pull request from a fork). WORKFLOW_FILE, ci.yaml unless
# set, is the workflow the job belongs to.
event() {
  local payload="$BATS_TEST_TMPDIR/event-$1.json" ref
  case $1 in
    push)
      ref=refs/heads/main
      jq -n '{ref: "refs/heads/main", repository: {full_name: "fixture-owner/fixture-repo"}}' > "$payload"
      EVENT=(GITHUB_EVENT_NAME=push)
      ;;
    branch | fork)
      ref=refs/pull/7/merge
      jq -n --arg head "$([[ $1 == branch ]] && echo fixture-owner || echo someone-else)/fixture-repo" '{
        number: 7,
        pull_request: {number: 7, head: {ref: "feature", repo: {full_name: $head, fork: ($head != "fixture-owner/fixture-repo")}},
          base: {ref: "main", repo: {full_name: "fixture-owner/fixture-repo"}}},
        repository: {full_name: "fixture-owner/fixture-repo"}}' > "$payload"
      EVENT=(GITHUB_EVENT_NAME=pull_request)
      ;;
  esac
  EVENT+=(GITHUB_REF="$ref" GITHUB_REPOSITORY=fixture-owner/fixture-repo GITHUB_EVENT_PATH="$payload"
    GITHUB_WORKFLOW_REF="fixture-owner/fixture-repo/.github/workflows/${WORKFLOW_FILE:-ci.yaml}@$ref")
}

# pick KIND [LABEL]: runs just ci-runner for the event KIND, with CI_RUNNER_LABEL set to LABEL when
# given, as the CI workflow's step does.
pick() {
  event "$1"
  local label=()
  if (($# > 1)); then
    label=(CI_RUNNER_LABEL="$2")
  fi
  : > "$BATS_TEST_TMPDIR/github-output"
  run env -u CI_RUNNER_LABEL "${EVENT[@]}" "${label[@]}" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output" \
    just --justfile "$REPO/justfile" ci-runner
}

# hook KIND: runs the CI host's job-started hook, as scripts/lib/ci-host.sh writes it, for a job of
# the event KIND, the way the runner runs a .sh hook: bash -e with the file.
hook() {
  event "$1"
  (. "$REPO/scripts/lib/ci-host.sh" && ci_host_hook) > "$BATS_TEST_TMPDIR/job-started.sh"
  run env -i PATH="$PATH" "${EVENT[@]}" bash -e "$BATS_TEST_TMPDIR/job-started.sh"
}

# the_jobs: sets chooser to the CI workflow's job that runs just ci-runner, and checker to the one
# that runs a job per group.
the_jobs() {
  chooser=$(yq '[.jobs | to_entries[] | select(.value.steps[] | .run == "just ci-runner") | .key] | .[]' "$WORKFLOW")
  [ -n "$chooser" ]
  [ "$(wc -l <<< "$chooser")" -eq 1 ]
  checker=$(yq '[.jobs | to_entries[] | select(.value | has("strategy")) | .key] | .[]' "$WORKFLOW")
  [ -n "$checker" ]
  [ "$(wc -l <<< "$checker")" -eq 1 ]
}

@test "A pull request from a fork never runs on the self-hosted runner" {
  the_jobs
  # The check jobs run where the job that runs just ci-runner says, which runs on a hosted runner
  # itself and hands the recipe the repository's label variable.
  [ "$(yq ".jobs.$checker.runs-on" "$WORKFLOW")" = "\${{ fromJSON(needs.$chooser.outputs.runner) }}" ]
  [ "$(yq ".jobs.$chooser.runs-on" "$WORKFLOW")" = ubuntu-latest ]
  step=$(yq ".jobs.$chooser.steps[] | select(.run == \"just ci-runner\") | .id" "$WORKFLOW")
  [ "$(yq ".jobs.$chooser.outputs.runner" "$WORKFLOW")" = "\${{ steps.$step.outputs.runner }}" ]
  # shellcheck disable=SC2016 # the workflow's expression, as written
  [ "$(yq ".jobs.$chooser.steps[] | select(.run == \"just ci-runner\") | .env | @json" "$WORKFLOW")" = '{"CI_RUNNER_LABEL":"${{ vars.CI_RUNNER_LABEL }}"}' ]

  # The label goes to a push to main and a pull request from a branch of the repository only.
  for kind in push branch; do
    pick "$kind" lab-ci
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = '"lab-ci"' ]
    [ "$(cat "$BATS_TEST_TMPDIR/github-output")" = 'runner="lab-ci"' ]
  done
  pick fork lab-ci
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = '"ubuntu-latest"' ]
  [ "$(cat "$BATS_TEST_TMPDIR/github-output")" = 'runner="ubuntu-latest"' ]

  # A fork's pull request runs the fork's workflow file, which can ask for the host's label itself:
  # the host's job-started hook fails the job before any of its steps runs.
  for kind in push branch; do
    hook "$kind"
    [ "$status" -eq 0 ]
  done
  hook fork
  [ "$status" -ne 0 ]
  [[ $output == *"pull requests from other repositories"* ]]
}

@test "Without a self-hosted runner configured, every job runs on a hosted runner" {
  the_jobs
  for kind in push branch fork; do
    for label in unset empty; do
      if [[ $label == unset ]]; then
        pick "$kind"
      else
        pick "$kind" ''
      fi
      [ "$status" -eq 0 ]
      [ "${lines[-1]}" = '"ubuntu-latest"' ]
      [ "$(cat "$BATS_TEST_TMPDIR/github-output")" = 'runner="ubuntu-latest"' ]
    done
  done
  # Every other job names ubuntu-latest itself.
  run yq -o=json -I=0 "[.jobs | to_entries[] | select(.key != \"$checker\") | .value.runs-on] | unique" "$WORKFLOW"
  [ "$output" = '["ubuntu-latest"]' ]
  # A label that is not one stops the run instead of naming a runner.
  pick push 'lab-ci, ubuntu-latest'
  [ "$status" -ne 0 ]
  [[ $output == *"CI_RUNNER_LABEL is not a runner label"* ]]
}

@test "The publish workflow never runs on the self-hosted runner" {
  local publish="$REPO/.github/workflows/publish.yaml"
  run yq -o=json -I=0 '[.jobs[].runs-on]' "$publish"
  [ "$status" -eq 0 ]
  [ "$output" = '["ubuntu-latest"]' ]

  WORKFLOW_FILE=publish.yaml hook push

  [ "$status" -ne 0 ]
  [[ $output == *"jobs of workflows other than .github/workflows/ci.yaml"* ]]
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

# render_job: sets RENDER, exported, to the CI workflow's one job that runs just ci-render.
render_job() {
  RENDER=$(yq '[.jobs | to_entries[] | select(.value.steps[] | .run // "" | test("^just ci-render( |$)")) | .key] | .[]' "$WORKFLOW")
  [ -n "$RENDER" ]
  [ "$(wc -l <<< "$RENDER")" -eq 1 ]
  export RENDER
}

@test "The render job has read-only permissions, no secrets, and always a hosted runner" {
  render_job
  # pull_request gives a fork's run a read-only token and no secrets; pull_request_target would
  # give it write access and secrets.
  [ "$(yq -o=json -I=0 '.on | keys' "$WORKFLOW")" = '["pull_request","push"]' ]
  [ "$(yq -o=json -I=0 '.permissions' "$WORKFLOW")" = '{"contents":"read"}' ]
  [ "$(yq '.jobs[strenv(RENDER)] | has("permissions")' "$WORKFLOW")" = false ]
  # No step is handed a secret or the job's token.
  [ "$(yq '[.jobs[strenv(RENDER)] | .. | select(tag == "!!str") | select(test("secrets\.|github\.token|GITHUB_TOKEN"))] | length' "$WORKFLOW")" = 0 ]
  # A hosted runner named in the job itself, never the runner the check jobs are given.
  [ "$(yq '.jobs[strenv(RENDER)].runs-on' "$WORKFLOW")" = ubuntu-latest ]
  # Its one command writes the comment where the one upload takes it from, as an artifact of one file.
  # shellcheck disable=SC2016 # the workflow's command, as written
  [ "$(yq '[.jobs[strenv(RENDER)].steps[] | select(has("run")) | .run] | .[]' "$WORKFLOW")" = 'just ci-render "$RUNNER_TEMP/render-diff/comment.md"' ]
  run yq -o=json -I=0 '[.jobs[strenv(RENDER)].steps[] | select(.uses // "" | test("^actions/upload-artifact@")) | .with | to_entries | sort_by(.key) | from_entries]' "$WORKFLOW"
  # shellcheck disable=SC2016 # the workflow's expression, as written
  [ "$output" = '[{"if-no-files-found":"error","name":"render-diff","path":"${{ runner.temp }}/render-diff/comment.md","retention-days":7}]' ]

  # The recipe renders in the Dagger module and saves what its function returns to that file.
  local bin="$BATS_TEST_TMPDIR/bin" out="$BATS_TEST_TMPDIR/out/comment.md"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\n' > "$bin/mise"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\n' "$BATS_TEST_TMPDIR/dagger.args" > "$bin/dagger"
  chmod +x "$bin/mise" "$bin/dagger"
  run env PATH="$bin:/usr/bin:/bin" "$(command -v just)" --justfile "$REPO/justfile" --working-directory "$REPO" ci-render "$out"
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/dagger.args"
  [[ $output == *$'\nci\nrender-diff\n'* ]]
  [[ $output == *$'\n-o\n'"$out"$'\n'* || $output == *$'\n--output='"$out"$'\n'* ]]
}

@test "The comment job runs no code and checks out nothing from the pull request" {
  [ -f "$COMMENT" ]
  # It runs once the CI workflow completes, from the default branch's copy of this file, never for
  # a pull request's own event, whose files are the pull request's.
  [ "$(yq -o=json -I=0 '.on | keys' "$COMMENT")" = '["workflow_run"]' ]
  [ "$(yq -o=json -I=0 '.on.workflow_run.workflows' "$COMMENT")" = "$(yq -o=json -I=0 '[.name]' "$WORKFLOW")" ]
  [ "$(yq -o=json -I=0 '.on.workflow_run.types' "$COMMENT")" = '["completed"]' ]
  # One job, for runs of pull requests only, on a hosted runner.
  [ "$(yq '.jobs | length' "$COMMENT")" = 1 ]
  [[ "$(yq '.jobs[].if' "$COMMENT")" == *"github.event.workflow_run.event == 'pull_request'"* ]]
  [ "$(yq '.jobs[].runs-on' "$COMMENT")" = ubuntu-latest ]
  # Each checkout takes the commit the run is for, the default branch's: no other ref, repository
  # or path, and the token is not left in it.
  run yq -o=json -I=0 '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@")) | .with] | unique' "$COMMENT"
  [ "$output" = '[{"persist-credentials":false}]' ]
  # Only the checkout and mise actions, pinned as the CI workflow pins them.
  [ "$(yq -o=json -I=0 '[.jobs[].steps[] | select(has("uses")) | .uses] | unique' "$COMMENT")" = "$(yq -o=json -I=0 '[.jobs[].steps[] | select(.uses // "" | test("^(actions/checkout|jdx/mise-action)@")) | .uses] | unique' "$WORKFLOW")" ]
  [ "$(yq '[.jobs[].steps[] | select(has("uses") | not) | select(has("run") | not)] | length' "$COMMENT")" = 0 ]
  # One command, one recipe, which gets the run's identifiers as variables and never as text in
  # the command; no command holds an expression.
  [ "$(yq -o=json -I=0 '[.jobs[].steps[] | select(has("run")) | .run]' "$COMMENT")" = '["just ci-comment"]' ]
  run yq -o=json -I=0 '.jobs[].steps[] | select(has("run")) | .env | to_entries | sort_by(.key) | from_entries' "$COMMENT"
  [ "$output" = "$(jq -c -S . <<'EOF'
{"GH_TOKEN": "${{ github.token }}", "RUN_ID": "${{ github.event.workflow_run.id }}",
 "HEAD_SHA": "${{ github.event.workflow_run.head_sha }}",
 "HEAD_REPOSITORY": "${{ github.event.workflow_run.head_repository.full_name }}",
 "HEAD_BRANCH": "${{ github.event.workflow_run.head_branch }}"}
EOF
)" ]
  [ "$(yq '[.jobs[].steps[] | select(has("run")) | .run | select(test("\$\{\{"))] | length' "$COMMENT")" = 0 ]
  # The pull request's head is named nowhere else but in the name of the concurrency group, so
  # nothing checks it out or runs it.
  [ "$(yq '[del(.concurrency) | .. | select(tag == "!!str") | select(test("head_|pull_request\.|github\.head_ref"))] | length' "$COMMENT")" = 3 ]
}

# fake_gh: a gh first on PATH that records each call in $FAKE/calls, plays GitHub from the files in
# $FAKE, and keeps each comment it is asked to write as $FAKE/written.json, its method and path in
# $FAKE/writes.
fake_gh() {
  BIN="$BATS_TEST_TMPDIR/bin"
  FAKE="$BATS_TEST_TMPDIR/github"
  mkdir -p "$BIN" "$FAKE"
  cat > "$BIN/gh" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/calls"
if [[ $1 == run && $2 == download ]]; then
  while (($#)); do
    [[ $1 == --dir ]] && dir=$2
    shift
  done
  mkdir -p "$dir"
  if [[ -d $FAKE/artifact ]]; then
    cp -a "$FAKE/artifact/." "$dir/"
  else
    echo "no valid artifacts found to download" >&2
    exit 1
  fi
  exit 0
fi
[[ $1 == api ]] || { echo "fake gh: unexpected: $*" >&2; exit 1; }
shift
method=GET input= path=
while (($#)); do
  case $1 in
    --method | -X) method=$2; shift 2 ;;
    --input) input=$2; shift 2 ;;
    -f | -F | --raw-field | --field) shift 2 ;;
    --paginate) shift ;;
    *) path=$1; shift ;;
  esac
done
case "$method $path" in
  "GET repos/fixture-owner/fixture-repo/pulls") cat "$FAKE/pulls.json" ;;
  "GET repos/fixture-owner/fixture-repo/issues/7/comments"*) cat "$FAKE/comments.json" ;;
  "POST "* | "PATCH "*)
    cp "$input" "$FAKE/written.json"
    echo "$method $path" >> "$FAKE/writes"
    echo '{}'
    ;;
  *) echo "fake gh: unexpected: $method $path" >&2; exit 1 ;;
esac
EOF
  chmod +x "$BIN/gh"
  HEAD_SHA=0123456789abcdef0123456789abcdef01234567
  jq -n --arg sha "$HEAD_SHA" '[{number: 7, head: {sha: $sha, ref: "feature", repo: {full_name: "someone-else/fixture-repo"}}}]' > "$FAKE/pulls.json"
  echo '[]' > "$FAKE/comments.json"
}

# post: runs the comment recipe's script for run 42 of a fork's pull request, with the fake gh first
# on PATH and no credential in reach.
post() {
  rm -f "$FAKE/writes" "$FAKE/written.json"
  # Where anything the artifact made run would leave its files.
  cd "$BATS_TEST_TMPDIR" || return 1
  run env -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
    PATH="$BIN:$PATH" FAKE="$FAKE" GH_CONFIG_DIR="$BATS_TEST_TMPDIR/gh-config" GH_TOKEN=fixture-token \
    GITHUB_REPOSITORY=fixture-owner/fixture-repo RUN_ID=42 HEAD_SHA="$HEAD_SHA" \
    HEAD_REPOSITORY=someone-else/fixture-repo HEAD_BRANCH=feature "$REPO/scripts/ci-comment"
}

# artifact [FILE...]: makes the run's artifact hold FILE..., each copied from $BATS_TEST_TMPDIR/FILE.
artifact() {
  rm -rf "$FAKE/artifact"
  mkdir -p "$FAKE/artifact"
  local file
  for file in "$@"; do
    cp -P "$BATS_TEST_TMPDIR/$file" "$FAKE/artifact/"
  done
}

# a_comment: writes to $BATS_TEST_TMPDIR/comment.md what just render-diff writes for two renders
# that do not differ, so its marker is the one the recipe looks for.
a_comment() {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  "$REPO/scripts/render-diff" "$BATS_TEST_TMPDIR/empty" "$BATS_TEST_TMPDIR/empty" > "$BATS_TEST_TMPDIR/comment.md"
}

@test "The comment job treats the artifact as text of a bounded size" {
  fake_gh
  a_comment
  # Shell and workflow syntax that would run, or be expanded, anywhere it was not plain text: right
  # after the marker, before anything that would stop a shell parsing on.
  {
    sed -n 1p "$BATS_TEST_TMPDIR/comment.md"
    cat << 'EOF'
touch ran-a-line
$(touch ran-a-command) `touch ran-a-backquote` ${{ secrets.ANYTHING }} '; touch ran-quoted; '
::stop-commands::fixture
EOF
    sed 1d "$BATS_TEST_TMPDIR/comment.md"
  } > "$BATS_TEST_TMPDIR/hostile.md"
  mv "$BATS_TEST_TMPDIR/hostile.md" "$BATS_TEST_TMPDIR/comment.md"
  artifact comment.md

  post

  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE/writes")" = "POST repos/fixture-owner/fixture-repo/issues/7/comments" ]
  jq -j '.body' "$FAKE/written.json" > "$BATS_TEST_TMPDIR/posted.md"
  cmp "$BATS_TEST_TMPDIR/comment.md" "$BATS_TEST_TMPDIR/posted.md"
  # Nothing of it ran, and none of it reached the log, where GitHub reads workflow commands.
  [[ $output != *"::stop-commands::"* ]]
  run find "$BATS_TEST_TMPDIR" "$REPO" -name 'ran-*'
  [ -z "$output" ]

  # Every other artifact is refused before anything is posted.
  cp "$BATS_TEST_TMPDIR/comment.md" "$BATS_TEST_TMPDIR/other.md"
  ln -s "$BATS_TEST_TMPDIR/other.md" "$BATS_TEST_TMPDIR/linked.md"
  mkdir -p "$BATS_TEST_TMPDIR/symlink" "$BATS_TEST_TMPDIR/unmarked" "$BATS_TEST_TMPDIR/large"
  ln -s "$BATS_TEST_TMPDIR/other.md" "$BATS_TEST_TMPDIR/symlink/comment.md"
  sed 1d "$BATS_TEST_TMPDIR/comment.md" > "$BATS_TEST_TMPDIR/unmarked/comment.md"
  { cat "$BATS_TEST_TMPDIR/comment.md"; head -c 65536 /dev/zero | tr '\0' x; } > "$BATS_TEST_TMPDIR/large/comment.md"
  local refused
  for refused in "comment.md other.md" "symlink/comment.md" "other.md" "unmarked/comment.md" "large/comment.md" ""; do
    # shellcheck disable=SC2086 # the files of each case, split on blanks
    artifact $refused
    post
    [ "$status" -ne 0 ] || { echo "posted an artifact of: ${refused:-nothing}"; return 1; }
    [ ! -e "$FAKE/writes" ] || { echo "wrote for an artifact of: $refused"; return 1; }
  done
}

@test "the comment job updates its own comment, and posts nothing for a pull request that moved on" {
  fake_gh
  a_comment
  artifact comment.md
  # A comment of someone else's that starts with the marker is left alone.
  jq -n --rawfile body "$BATS_TEST_TMPDIR/comment.md" '[
    {id: 101, user: {login: "someone", type: "User"}, body: $body},
    {id: 202, user: {login: "github-actions[bot]", type: "Bot"}, body: $body}]' > "$FAKE/comments.json"

  post

  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE/writes")" = "PATCH repos/fixture-owner/fixture-repo/issues/comments/202" ]
  # The pull request is found by the head the run was for, never by a number the artifact names.
  grep -qx 'api --method GET repos/fixture-owner/fixture-repo/pulls -f state=open -f head=someone-else:feature -f per_page=100' "$FAKE/calls"

  # A newer push moved the head on: its own run comments, this one posts nothing.
  jq '.[0].head.sha = "fedcba9876543210fedcba9876543210fedcba98"' "$FAKE/pulls.json" > "$FAKE/moved.json"
  mv "$FAKE/moved.json" "$FAKE/pulls.json"
  post
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE/writes" ]
  [[ $output == *"no open pull request"* ]]
}

@test "The render is part of the required result, and the comment is not" {
  render_job
  # The required job waits for the render job and hands its result to ci-passed, which fails on
  # anything but success; nothing skips the render job or lets it fail without failing.
  [ "$(yq '.jobs.ci.needs | contains([strenv(RENDER)])' "$WORKFLOW")" = true ]
  [ "$(yq '.jobs[strenv(RENDER)] | [has("if"), has("continue-on-error")] | any' "$WORKFLOW")" = false ]
  [ "$(yq '[.jobs[strenv(RENDER)].steps[] | select(has("if") or has("continue-on-error"))] | length' "$WORKFLOW")" = 0 ]
  run just --justfile "$REPO/justfile" ci-passed success success success failure
  [ "$status" -ne 0 ]
  # The comment is a workflow of its own, which nothing in the CI workflow waits for, and none of
  # its jobs reports a check named ci, the required check's name.
  [ -f "$COMMENT" ]
  [ "$(yq '.name' "$COMMENT")" != "$(yq '.name' "$WORKFLOW")" ]
  [ "$(yq '[.jobs | to_entries[] | select(.key == "ci" or .value.name == "ci")] | length' "$COMMENT")" = 0 ]
  [ "$(yq '[.. | select(tag == "!!str") | select(test("workflow_run|render-comment"))] | length' "$WORKFLOW")" = 0 ]
}
