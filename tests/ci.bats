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

# run_ci: runs the checkout's just ci with none of the pinned tools on PATH, so only a container can run the checks.
run_ci() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  # A mise with nothing installed keeps the justfile from putting the pinned tools on PATH.
  printf '#!/usr/bin/env bash\n' > "$bin/mise"
  chmod +x "$bin/mise"
  # The container runtime and the Dagger CLI that starts it are all the host provides.
  ln -s "$(command -v docker)" "$bin/docker"
  if command -v dagger > /dev/null; then
    ln -s "$(command -v dagger)" "$bin/dagger"
  fi
  run env PATH="$bin:/usr/bin:/bin" "$(command -v just)" --justfile "$WORK/justfile" --working-directory "$WORK" ci
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
@test "A failing check fails the hermetic run" {
  checkout
  mkdir "$WORK/config"
  cp "$BATS_TEST_DIRNAME/fixtures/check-address-literals/undeclared.txt" "$WORK/config/resolver.txt"
  git -C "$WORK" add config/resolver.txt
  literal=$(sed -n 's/^resolver: //p' "$WORK/config/resolver.txt")
  [ -n "$literal" ]

  run_ci

  [ "$status" -ne 0 ]
  [[ $output == *"config/resolver.txt:2: $literal"* ]]
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

@test "The workflow runs one recipe and nothing else" {
  run yq -o=json -I=0 '.jobs | keys' "$WORKFLOW"
  [ "$status" -eq 0 ]
  [ "$output" = '["ci"]' ]
  # Steps that only use an action check out and install; the run steps are the commands.
  run yq -o=json -I=0 '[.jobs[].steps[] | select(has("run")) | .run]' "$WORKFLOW"
  [ "$output" = '["just ci"]' ]
  run yq '.jobs.ci.steps[-1].run' "$WORKFLOW"
  [ "$output" = "just ci" ]
  # A required check from a workflow that a path filter kept from starting never reports.
  run yq '[.on | .. | select(tag == "!!map") | keys | .[] | select(test("^paths"))] | length' "$WORKFLOW"
  [ "$output" = 0 ]
  # pull_request_target would run with write access and secrets for a fork.
  run yq -o=json -I=0 '.on | keys' "$WORKFLOW"
  [ "$output" = '["pull_request","push"]' ]
  run yq -o=json -I=0 '.permissions' "$WORKFLOW"
  [ "$output" = '{"contents":"read"}' ]
  run yq '[.jobs[] | select(has("permissions"))] | length' "$WORKFLOW"
  [ "$output" = 0 ]
}

@test "Every action is pinned to a commit" {
  run yq '.. | select(tag == "!!map" and has("uses")) | .uses' "$WORKFLOW"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  while IFS= read -r ref; do
    [[ $ref =~ ^[^@[:space:]]+@[0-9a-f]{40}$ ]] || { echo "not pinned to a commit: $ref"; return 1; }
  done <<< "$output"
}
