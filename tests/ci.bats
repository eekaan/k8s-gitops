#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

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
  # The run resolved the Prometheus image for rules-check, which Dagger records in dagger.lock.
  [ -z "$(git -C "$WORK" status --porcelain)" ]
}

# bats test_tags=hermetic
@test "just ci runs every group, and a group runs only its own checks" {
  checkout
  mapfile -t groups < <(groups_of "$WORK/justfile")
  [ "${#groups[@]}" -gt 1 ]
  tests=$(bats --count --filter-tags '!hermetic,!namespace' "$WORK/tests")

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

# bats test_tags=hermetic
@test "just ci runs rules-check with promtool from the image the render names, after a chart update moves its tag" {
  local values rendered tag other
  checkout
  # The Prometheus the chart deploys, and the other variant of the same release: the render naming
  # another tag, as a chart update that moves it does, with nothing else in the tree changed.
  rendered=$(cd "$WORK" && scripts/rules-image)
  tag=${rendered##*:}
  other=${tag%-distroless}
  [[ $other != "$tag" ]] || other=$tag-distroless
  values="$WORK/kubernetes/apps/base/monitoring/kube-prometheus-stack/app/values.yaml"
  TAG=$other yq -i '.prometheus.prometheusSpec.image.tag = strenv(TAG)' "$values"
  [ "$(cd "$WORK" && scripts/rules-image)" = "${rendered%:*}:$other" ]
  # A group of the checkout's own: rules-check, and the bats tests of the rules.
  sed -i 's/^checks:.*$/& rules-only/' "$WORK/justfile"
  printf '\nrules-only: rules-check rules-tests\n\nrules-tests:\n    bats tests/rules-check.bats\n' >> "$WORK/justfile"

  run_ci rules-only

  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"== rules-only: passed"* ]]
  # The module runs rules-check: promtool from the image of the moved tag checks every rule and
  # refuses the broken ones, ...
  [[ $output == *"rules-check:"* ]]
  [[ $output == *"and the image ${rendered%:*}:$other to"* ]]
  [[ $output == *"rules-promtool: every rule is valid and every unit test passes"* ]]
  [[ $output == *"rules-refusal: promtool's check rules refuses the chart's rule"* ]]
  [[ $output == *"rules-refusal: promtool's check rules refuses the tree's own alert"*"defined twice, naming it"* ]]
  # ... and the tests of the rules pass on it, with no file edited by hand.
  [[ $output == *"ok "*" The rules are checked with the Prometheus image the chart deploys, in the static group of just ci"* ]]
  # The run resolved the moved tag, and Dagger's record of it stays out of the tree.
  [ -z "$(git -C "$WORK" status --porcelain -- dagger.lock)" ]
}

# bats test_tags=hermetic
@test "just ci reports a chart rules-check cannot pull as rules-check's failure, beside the group's other checks" {
  checkout
  # A chart version the registry does not have, so rules-image cannot pull the chart.
  TAG=0.0.0-none yq -i '.spec.ref.tag = strenv(TAG)' "$WORK/kubernetes/apps/base/monitoring/kube-prometheus-stack/app/ocirepository.yaml"
  sed -i 's/^checks:.*$/& rules-only/' "$WORK/justfile"
  printf '\nrules-only: rules-check check-literals\n' >> "$WORK/justfile"

  run_ci rules-only

  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"== rules-only: failed (rules-check check-literals)"* ]]
  [[ $output == *"rules-check:"*"kube-prometheus-stack:0.0.0-none: not found"* ]]
  [[ $output == *"No undeclared address literals in the files git would commit."* ]]
  [[ $output == *"failed: rules-only"* ]]
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

# stand_in MODE: puts a mise that installs nothing and a dagger that stands in for the real one on
# a PATH of its own, as BIN. The stand-in writes dagger.lock as Dagger does, then ends as MODE says:
# append adds a line and passes, truncate empties the file and passes, fail adds a line and exits 3.
# int, term and hup signal the process that started them, the recipe's own mechanism, and write the
# line only when that process has passed the signal on, as Dagger's shutdown writes the lock, after
# which they exit 2 (tests/fixtures/dagger-lock/signalled-dagger, which records the signal it got).
stand_in() {
  BIN="$BATS_TEST_TMPDIR/stand-in"
  mkdir -p "$BIN"
  printf '#!/usr/bin/env bash\n' > "$BIN/mise"
  add='printf '"'"'\n["","oci-sha",["example.invalid/prometheus/prometheus:v0.0.0"],"sha256:00"]'"'"' >> dagger.lock'
  case $1 in
    append) body=$add ;;
    truncate) body=': > dagger.lock' ;;
    fail) body="$add; exit 3" ;;
    int | term | hup)
      cp "$BATS_TEST_DIRNAME/fixtures/dagger-lock/signalled-dagger" "$BIN/dagger"
      chmod +x "$BIN/mise" "$BIN/dagger"
      return 0 ;;
    *) return 1 ;;
  esac
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$BIN/dagger"
  chmod +x "$BIN/mise" "$BIN/dagger"
}

# with_lock: commits in the checkout a dagger.lock of the fixture's, whatever the checkout holds: the
# containers of just ci hold the files git would commit but Dagger's own, this one among them.
with_lock() {
  cp -p "$BATS_TEST_DIRNAME/fixtures/dagger-lock/dagger.lock" "$WORK/dagger.lock"
  git -C "$WORK" add dagger.lock
  commit "dagger.lock of the fixture"
}

# run_stand_in MODE: runs the checkout's just ci with the stand-in of that MODE for Dagger.
# A stand-in that writes after a signal is still writing when the run returns, if the recipe did not
# wait for it, so the file is read once it has finished.
run_stand_in() {
  local waited=0
  stand_in "$1"
  rm -f "$BATS_TEST_TMPDIR/flushed"
  run env PATH="$BIN:/usr/bin:/bin" STAND_IN_SIGNAL="${1^^}" STAND_IN_MARK="$BATS_TEST_TMPDIR/flushed" \
    "$(command -v just)" --justfile "$WORK/justfile" --working-directory "$WORK" ci
  case $1 in
    int | term | hup)
      while [[ ! -e $BATS_TEST_TMPDIR/flushed ]] && ((waited++ < 100)); do sleep 0.1; done ;;
  esac
}

# expect_ended MODE STATUS OUTPUT: fails unless the run of the stand-in of MODE, which ended with
# STATUS and printed OUTPUT, ended as scripts/restore-after documents: with the command's status, or
# 128 plus the signal's number when a signal stopped the run, the command having received that signal
# and no other.
expect_ended() {
  local want
  case $1 in
    append | truncate) want=0 ;;
    fail) want=3 ;;
    int) want=130 ;;
    term) want=143 ;;
    hup) want=129 ;;
  esac
  [ "$2" -eq "$want" ] || { echo "$1: exit $2, want $want: $3"; return 1; }
  case $1 in
    int | term | hup)
      [ "$(cat "$BATS_TEST_TMPDIR/flushed")" = "${1^^}" ] || { echo "$1: the command received $(cat "$BATS_TEST_TMPDIR/flushed")"; return 1; } ;;
  esac
}

@test "A run of the checks leaves every tracked file as it found it, whether it passes, fails or is interrupted" {
  local mode
  checkout
  with_lock
  cp -p "$WORK/dagger.lock" "$BATS_TEST_TMPDIR/before"
  [ -z "$(git -C "$WORK" status --porcelain)" ]

  for mode in append truncate fail int term hup; do
    run_stand_in "$mode"

    expect_ended "$mode" "$status" "$output"
    cmp "$BATS_TEST_TMPDIR/before" "$WORK/dagger.lock" || { echo "$mode: dagger.lock differs"; return 1; }
    [ -z "$(git -C "$WORK" status --porcelain)" ] || { echo "$mode: $(git -C "$WORK" status --porcelain)"; return 1; }
  done
}

@test "A change made to the lock file before the run is still there after it" {
  local mode
  checkout
  with_lock
  # The developer's change: an entry dropped from the middle and one added at the end, with no
  # newline after it.
  sed -i '5d' "$WORK/dagger.lock"
  printf '\n["","git-latest",["example.invalid/mine"],"refs/tags/v9"]' >> "$WORK/dagger.lock"
  cp -p "$WORK/dagger.lock" "$BATS_TEST_TMPDIR/before"
  [ "$(git -C "$WORK" status --porcelain)" = " M dagger.lock" ]

  for mode in append truncate fail int term hup; do
    run_stand_in "$mode"

    cmp "$BATS_TEST_TMPDIR/before" "$WORK/dagger.lock" || { echo "$mode: dagger.lock differs from the developer's"; return 1; }
    [ "$(git -C "$WORK" status --porcelain)" = " M dagger.lock" ] || { echo "$mode: $(git -C "$WORK" status --porcelain)"; return 1; }
  done
}

@test "restore-after removes a file the run created, whether the command passes or fails" {
  local file="$BATS_TEST_TMPDIR/created"
  run "$REPO/scripts/restore-after" "$file" sh -c "echo made > '$file'"
  [ "$status" -eq 0 ]
  [ ! -e "$file" ]
  run "$REPO/scripts/restore-after" "$file" sh -c "echo made > '$file'; exit 3"
  [ "$status" -eq 3 ]
  [ ! -e "$file" ]
}

@test "restore-after says where the file's bytes are kept when it cannot put them back" {
  local file="$BATS_TEST_TMPDIR/lock" kept
  printf 'before the run\n' > "$file"
  cp -p "$file" "$BATS_TEST_TMPDIR/before"
  # The command leaves a directory where the file was, which no bytes can be written into.
  run "$REPO/scripts/restore-after" "$file" sh -c "rm '$file' && mkdir '$file'"
  echo "$output"
  [ "$status" -ne 0 ]
  kept=$(sed -n 's/^restore-after: .* could not be put back; its bytes from before the run are kept in //p' <<< "$output")
  [ -n "$kept" ]
  cmp "$BATS_TEST_TMPDIR/before" "$kept"
  rm -rf -- "${kept%/*}"
}

# lock_check_repo: sets WORK to a repository of its own with the lock check, committed with the
# fixture's dagger.lock and a list of its own that names one repository, example.invalid/derived/image.
# The lock holds no entry for it, only for names close to it, which are other images: another
# repository of the same organisation, one that merely begins with its name, and a tag of one under it.
lock_check_repo() {
  local near
  WORK="$BATS_TEST_TMPDIR/lock-repo"
  mkdir -p "$WORK/scripts/lib"
  cp -p "$REPO/scripts/check-lock-entries" "$WORK/scripts/"
  printf '# shellcheck shell=bash\nderived_images=(\n  example.invalid/derived/image\n)\n' > "$WORK/scripts/lib/derived-images.sh"
  cp -p "$BATS_TEST_DIRNAME/fixtures/dagger-lock/dagger.lock" "$WORK/dagger.lock"
  for near in example.invalid/derived/other:v1 example.invalid/derived/image-config-reloader:v1 example.invalid/derived/images:v1; do
    printf '\n["","oci-sha",["%s"],"sha256:0000000000000000000000000000000000000000000000000000000000000000"]' "$near" >> "$WORK/dagger.lock"
  done
  git -C "$WORK" init -q -b main
  git -C "$WORK" add -A
  commit "lock without entries of derived images"
}

@test "A committed lock entry for an image the tree takes by a derived tag fails the checks" {
  local image entry line rendered repository listed=0
  lock_check_repo
  # The images are those of scripts/lib/derived-images.sh, so the repository of the one rules-check
  # takes from the render is an entry of the real list, whole: a longer name that begins with it is
  # another image. The check is one of the static group's, and runs scripts/check-lock-entries.
  rendered=$("$REPO/scripts/rules-image")
  repository=${rendered%%[:@]*}
  # shellcheck source=scripts/lib/derived-images.sh
  . "$REPO/scripts/lib/derived-images.sh"
  for entry in "${derived_images[@]}"; do
    if [ "$entry" = "$repository" ]; then listed=1; fi
  done
  [ "$listed" -eq 1 ] || { echo "scripts/lib/derived-images.sh does not list $repository: ${derived_images[*]}"; return 1; }
  run just --justfile "$REPO/justfile" --dump --dump-format json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.recipes.static.dependencies[].recipe | select(. == "lock-check")' <<< "$output")" = lock-check ]
  run just --justfile "$REPO/justfile" --dry-run lock-check
  [ "$status" -eq 0 ]
  [ "$output" = scripts/check-lock-entries ]

  # The committed lock holds none of the list's, only near misses: the check passes.
  run "$WORK/scripts/check-lock-entries"
  [ "$status" -eq 0 ]

  # An uncommitted entry is the working copy's: the check reads what is committed.
  image=example.invalid/derived/image:v1
  entry="[\"\",\"oci-sha\",[\"$image\"],\"sha256:0000000000000000000000000000000000000000000000000000000000000000\"]"
  printf '\n%s' "$entry" >> "$WORK/dagger.lock"
  run "$WORK/scripts/check-lock-entries"
  [ "$status" -eq 0 ]

  # Committed, the entry fails the check, which names its line, and a working copy without it does
  # not hide it.
  git -C "$WORK" add dagger.lock
  commit "lock with an entry of a derived image"
  line=$(grep -nF "$image" "$WORK/dagger.lock" | cut -d: -f1)
  head -n -1 "$WORK/dagger.lock" > "$BATS_TEST_TMPDIR/clean"
  cp "$BATS_TEST_TMPDIR/clean" "$WORK/dagger.lock"
  run "$WORK/scripts/check-lock-entries"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"dagger.lock:$line: "*"$image"* ]]
  [[ $output == *"scripts/lib/derived-images.sh"* ]]
  # Only its own line is named, not the near misses above it.
  [ "$(grep -c '^dagger.lock:' <<< "$output")" -eq 1 ]

  # A list entry that only begins with the committed entry's repository is another image too.
  printf '# shellcheck shell=bash\nderived_images=(\n  example.invalid/derived/image-exporter\n)\n' > "$WORK/scripts/lib/derived-images.sh"
  run "$WORK/scripts/check-lock-entries"
  [ "$status" -eq 0 ]

  # With the real list, a committed entry for the image rules-check takes fails the check, naming
  # its line alone.
  cp -p "$REPO/scripts/lib/derived-images.sh" "$WORK/scripts/lib/derived-images.sh"
  printf '\n["","oci-sha",["%s"],"sha256:0000000000000000000000000000000000000000000000000000000000000000"]' "$rendered" >> "$WORK/dagger.lock"
  git -C "$WORK" add dagger.lock
  commit "lock with an entry of the image rules-check takes"
  line=$(grep -nF "\"$rendered\"" "$WORK/dagger.lock" | cut -d: -f1)
  run "$WORK/scripts/check-lock-entries"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"dagger.lock:$line: "*"\"$rendered\""* ]]
  [ "$(grep -c '^dagger.lock:' <<< "$output")" -eq 1 ]
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
  # Every call leaves out the tests that run just ci, which need a container runtime, and those that
  # need unprivileged user namespaces, which the CI containers refuse.
  calls=$(grep -cx '' "$BATS_TEST_TMPDIR/bats.args")
  [ "$(grep -cx -- '!hermetic,!namespace' "$BATS_TEST_TMPDIR/bats.args")" -eq "$calls" ]
  # A file's tests run side by side, wherever bats has the lock it needs and there is more than one
  # processor; files never run side by side in one call, as the files' tests are not written for it.
  if env PATH="$bin:/usr/bin:/bin" bash -c 'command -v flock || command -v shlock' > /dev/null && (($(getconf _NPROCESSORS_ONLN) > 1)); then
    [ "$(grep -cx -- '--jobs' "$BATS_TEST_TMPDIR/bats.args")" -eq "$calls" ]
  fi
  [ "$(grep -cx -- '--no-parallelize-across-files' "$BATS_TEST_TMPDIR/bats.args")" -eq "$(grep -cx -- '--jobs' "$BATS_TEST_TMPDIR/bats.args")" ]
}

# recording_bats: BIN, a directory with a mise that installs nothing, so the justfile puts no pinned
# tool before what BIN holds on PATH, and a bats that records each argument it is handed, one per
# line, in $BATS_ARGS.
recording_bats() {
  BIN="$BATS_TEST_TMPDIR/recording"
  mkdir -p "$BIN"
  printf '#!/usr/bin/env bash\n' > "$BIN/mise"
  # shellcheck disable=SC2016 # the stand-in expands them
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >> "$BATS_ARGS"\n' > "$BIN/bats"
  chmod +x "$BIN/mise" "$BIN/bats"
  export BATS_ARGS="$BATS_TEST_TMPDIR/bats.args"
}

@test "The bats tests are split into groups by the time each file took, and no group takes much longer than another" {
  local file seconds part total heaviest most=0 least=0 too_heavy='' over='' report=''
  local -a parts words files handed=()
  local -A recorded=()
  while IFS=$'\t' read -r file seconds; do
    recorded[$file]=$seconds
  done < <(grep -v '^#' "$REPO/tests/times.tsv")
  # The parts of the bats tests the groups run: each test recipe they run and its arguments.
  mapfile -t parts < <(runs_of "$REPO/justfile" | cut -f2 | grep -E '^test( |$)')
  [ "${#parts[@]}" -gt 1 ]
  recording_bats

  for part in "${parts[@]}"; do
    read -ra words <<< "$part"
    rm -f "$BATS_ARGS"
    run env PATH="$BIN:/usr/bin:/bin" "$(command -v just)" --justfile "$REPO/justfile" --working-directory "$REPO" "${words[@]}"
    [ "$status" -eq 0 ] || { echo "$part: $output"; return 1; }
    files=()
    if [[ -e $BATS_ARGS ]]; then
      mapfile -t files < <(grep -E '^tests/[^/]+\.bats$' "$BATS_ARGS")
    fi
    handed+=("${files[@]}")
    # The part's recorded total, and its heaviest file.
    total=0 heaviest=
    for file in "${files[@]}"; do
      [ -n "${recorded[$file]-}" ] || { echo "$file has no time in tests/times.tsv"; return 1; }
      total=$((total + recorded[$file]))
      if [[ -z $heaviest ]] || ((recorded[$file] > recorded[$heaviest])); then
        heaviest=$file
      fi
    done
    report+="$part: ${#files[@]} files, ${total}s"$'\n'
    if ((${#files[@]} > 1)); then
      if ((total > most)); then
        most=$total too_heavy="$heaviest, ${recorded[$heaviest]}s,"
      fi
      if ((least == 0 || total < least)); then
        least=$total
      fi
    fi
    if ((total > 1500)); then
      over+=" $part"
    fi
  done

  # Every test file goes to one part, and to one only.
  [ "$(printf '%s\n' "${handed[@]}" | sort)" = "$(cd "$REPO" && printf '%s\n' tests/*.bats | sort)" ] || {
    echo "the parts do not hand bats every test file once:"
    diff <(printf '%s\n' "${handed[@]}" | sort) <(cd "$REPO" && printf '%s\n' tests/*.bats | sort)
    return 1
  }
  # The parts of more than one file take about as long as each other, and none longer than 25 minutes.
  ((most * 100 <= least * 105)) || {
    printf '%s' "$report"
    echo "the parts of more than one file differ by more than 5%: $too_heavy is too heavy to balance around in the heaviest part; change the number of groups until its part balances or it has one of its own"
    return 1
  }
  [ -z "$over" ] || {
    printf '%s' "$report"
    echo "recorded at more than 25 minutes:$over; add a group: a recipe tests-N that runs test 'N/M', its name in the checks recipe's dependencies, and test 'N/M' in every group"
    return 1
  }
}

# record_copy: COPY, a copy of the justfile, just/, scripts/, the test files and their record, and
# PARTS, the parts of the bats tests its groups run.
record_copy() {
  COPY="$BATS_TEST_TMPDIR/copy"
  mkdir -p "$COPY/tests"
  cp -R "$REPO/justfile" "$REPO/just" "$REPO/scripts" "$COPY/"
  cp "$REPO"/tests/*.bats "$REPO/tests/times.tsv" "$COPY/tests/"
  mapfile -t PARTS < <(runs_of "$COPY/justfile" | cut -f2 | grep -E '^test( |$)')
  [ "${#PARTS[@]}" -gt 1 ]
}

@test "A test file without a recorded time stops the tests, naming the command that records it" {
  local part
  local -a words
  record_copy
  # A new test file without its time, and a line for a file that is gone.
  printf '@test "%s" {\n  true\n}\n' 'a new application' > "$COPY/tests/new-app.bats"
  printf 'tests/gone.bats\t9\n' >> "$COPY/tests/times.tsv"
  recording_bats
  rm -f "$BATS_ARGS"

  for part in "${PARTS[@]}"; do
    read -ra words <<< "$part"
    run env PATH="$BIN:/usr/bin:/bin" "$(command -v just)" --justfile "$COPY/justfile" --working-directory "$COPY" "${words[@]}"

    echo "$output"
    [ "$status" -ne 0 ]
    # Every part fails the same way, before bats is called.
    [ ! -e "$BATS_ARGS" ] || { echo "$part called bats"; return 1; }
    [ "$(grep '^test: ' <<< "$output")" = "$(printf '%s\n' \
      'test: tests/new-app.bats has no time in tests/times.tsv; record it with just test-time tests/new-app.bats' \
      'test: tests/times.tsv has a line for tests/gone.bats, which tests/ no longer has; delete the line or run just test-times-record')" ]
  done
}

@test "a line of the record that is not a test file, a tab and whole seconds stops the tests" {
  local part number
  local -a words
  record_copy
  # A space where the tab belongs.
  printf 'tests/ci.bats 21\n' >> "$COPY/tests/times.tsv"
  number=$(wc -l < "$COPY/tests/times.tsv")
  recording_bats
  rm -f "$BATS_ARGS"

  for part in "${PARTS[@]}"; do
    read -ra words <<< "$part"
    run env PATH="$BIN:/usr/bin:/bin" "$(command -v just)" --justfile "$COPY/justfile" --working-directory "$COPY" "${words[@]}"

    echo "$output"
    [ "$status" -ne 0 ]
    [ ! -e "$BATS_ARGS" ] || { echo "$part called bats"; return 1; }
    [ "$(grep '^test: ' <<< "$output")" = "test: tests/times.tsv:$number is not a test file, a tab and its whole seconds" ]
  done
}

@test "a test file with two lines in the record stops the tests" {
  local part number
  local -a words
  record_copy
  # A second line for a file the record holds, with another time.
  printf 'tests/ci.bats\t99\n' >> "$COPY/tests/times.tsv"
  number=$(wc -l < "$COPY/tests/times.tsv")
  recording_bats
  rm -f "$BATS_ARGS"

  for part in "${PARTS[@]}"; do
    read -ra words <<< "$part"
    run env PATH="$BIN:/usr/bin:/bin" "$(command -v just)" --justfile "$COPY/justfile" --working-directory "$COPY" "${words[@]}"

    echo "$output"
    [ "$status" -ne 0 ]
    [ ! -e "$BATS_ARGS" ] || { echo "$part called bats"; return 1; }
    [ "$(grep '^test: ' <<< "$output")" = "test: tests/times.tsv:$number repeats tests/ci.bats; a test file has one line" ]
  done
}

@test "a test file whose tests the tags all leave out runs, passes and prints its time" {
  local dir="$BATS_TEST_TMPDIR/left-out"
  mkdir -p "$dir/tests"
  # Only tests that just test leaves out: one tagged hermetic, one tagged namespace.
  printf '# bats test_tags=%s\n@test "%s" {\n  true\n}\n\n' hermetic 'left out 1' namespace 'left out 2' > "$dir/tests/left-out.bats"
  [ "$(bats --count "$dir/tests/left-out.bats")" -eq 2 ]
  cd "$dir"

  run "$REPO/scripts/test-run" tests/left-out.bats

  echo "$output"
  [ "$status" -eq 0 ]
  # bats ran the file, which planned no test.
  [ "$(grep -cx '1\.\.0' <<< "$output")" -eq 1 ]
  [ "$(grep -cxE 'test: tests/left-out\.bats took [0-9]+s' <<< "$output")" -eq 1 ]
}

# times_tree: TREE, a copy of the justfile, just/ and scripts/ whose tests/ holds no test file yet
# and a tests/times.tsv of this record's header alone; BIN, a directory for stand-ins, with a mise that
# installs nothing, so the justfile puts no pinned tool before them on PATH.
times_tree() {
  TREE="$BATS_TEST_TMPDIR/tree"
  BIN="$BATS_TEST_TMPDIR/stand-ins"
  mkdir -p "$TREE/tests" "$BIN"
  cp -R "$REPO/justfile" "$REPO/just" "$REPO/scripts" "$TREE/"
  grep '^#' "$REPO/tests/times.tsv" > "$TREE/tests/times.tsv"
  printf '#!/usr/bin/env bash\n' > "$BIN/mise"
  chmod +x "$BIN/mise"
}

# times_file NAME SECONDS [TESTS]: adds tests/NAME.bats to the tree, with TESTS tests, one by
# default, and a line of its record saying it took SECONDS.
times_file() {
  local i
  for ((i = 1; i <= ${3:-1}; i++)); do
    printf '@test "%s %d" {\n  true\n}\n' "$1" "$i"
  done > "$TREE/tests/$1.bats"
  printf 'tests/%s.bats\t%s\n' "$1" "$2" >> "$TREE/tests/times.tsv"
}

# times_just ARG...: runs the tree's just with ARG..., the stand-ins first on PATH.
times_just() {
  run env PATH="$BIN:/usr/bin:/bin" "$(command -v just)" --justfile "$TREE/justfile" --working-directory "$TREE" "$@"
}

@test "Each test file prints how long it took, and the record is written from what a run printed" {
  local entry name sleep printed fixture plan live heading report line
  local -A took=()
  times_tree
  # broken.bats fails; the heaviest by its recorded time and by its number of tests, it runs first.
  times_file broken 30 3
  times_file slow 20 2
  times_file quick 10
  # A bats that records the file it is handed and sleeps a known time for it: two seconds for
  # slow.bats, one for broken.bats, after which it fails, none for quick.bats.
  cat > "$BIN/bats" << 'EOF'
#!/usr/bin/env bash
file=${!#}
printf '%s\n' "$file" >> "$STAND_IN_CALLS"
case $file in
  tests/slow.bats) sleep 2 ;;
  tests/broken.bats) sleep 1; printf '1..1\nnot ok 1 broken 1\n'; exit 1 ;;
esac
printf '1..1\nok 1 fine\n'
EOF
  chmod +x "$BIN/bats"
  export STAND_IN_CALLS="$BATS_TEST_TMPDIR/calls"

  run --separate-stderr env PATH="$BIN:/usr/bin:/bin" "$(command -v just)" --justfile "$TREE/justfile" --working-directory "$TREE" test 1/1

  echo "$output"
  echo "$stderr"
  [ "$status" -ne 0 ]
  # Every file ran, those after the failing one too, each with one line on standard output of the
  # whole seconds it took: its sleep, or a second more for starting and rounding.
  [ "$(head -n 1 "$STAND_IN_CALLS")" = tests/broken.bats ]
  [ "$(sort "$STAND_IN_CALLS")" = "$(printf '%s\n' tests/broken.bats tests/quick.bats tests/slow.bats)" ]
  for entry in broken:1 slow:2 quick:0; do
    name=${entry%:*} sleep=${entry#*:}
    [ "$(grep -cxE "test: tests/$name\.bats took [0-9]+s" <<< "$output")" -eq 1 ] || { echo "not one time for $name"; return 1; }
    took[$name]=$(sed -nE "s|^test: tests/$name\.bats took ([0-9]+)s$|\1|p" <<< "$output")
    ((took[$name] >= sleep && took[$name] <= sleep + 1)) || { echo "$name took ${took[$name]}s, slept ${sleep}s"; return 1; }
  done
  # The run ends naming the file that failed.
  printed=$output$'\n'$stderr
  [ "$(grep -cx 'test: failed: tests/broken.bats' <<< "$printed")" -eq 1 ]

  # Since the run, a test file came with its line, and a line was added for one that is gone.
  times_file later 7
  printf 'tests/gone.bats\t9\n' >> "$TREE/tests/times.tsv"
  cp -p "$TREE/tests/times.tsv" "$BATS_TEST_TMPDIR/before"
  # The run's output, both streams, as a CI job's log carries it (tests/fixtures/test-times): each
  # line after GitHub's timestamp and Dagger's prefix, colour codes included, and before a carriage
  # return, then again after the timestamp alone in the group's report. The log also times the gone
  # file, as a run older than the tree would.
  fixture="$BATS_TEST_DIRNAME/fixtures/test-times/job-1001.log"
  plan=$(grep -m 1 -E '1\.\.[0-9]+$' "$fixture")
  live=${plan%1..*}
  [[ $live == *$'\e[90m|\e[0m ' ]]
  heading=$(grep -m 1 -E '== tests-[0-9]+: ' "$fixture")
  report=${heading%%== *}
  [[ $report =~ ^[0-9]{4}-[0-9T:.-]+Z\ $ ]]
  {
    while IFS= read -r line; do printf '%s%s\r\n' "$live" "$line"; done <<< "$printed"
    printf '%stest: tests/gone.bats took 12s\r\n' "$live"
    printf '%s== tests-1: failed (test 1/1)\n' "$report"
    while IFS= read -r line; do printf '%s%s\n' "$report" "$line"; done <<< "$printed"
  } > "$BATS_TEST_TMPDIR/job.log"

  # A log without a timing line, and one that gives a file two times, change nothing.
  grep -v ' took ' "$BATS_TEST_TMPDIR/job.log" > "$BATS_TEST_TMPDIR/untimed.log"
  run "$TREE/scripts/test-times" < "$BATS_TEST_TMPDIR/untimed.log"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"test-times: no line test: tests/<name>.bats took <N>s in the input"* ]]
  cmp "$BATS_TEST_TMPDIR/before" "$TREE/tests/times.tsv"
  { cat "$BATS_TEST_TMPDIR/job.log"; printf '%stest: tests/slow.bats took %ss\r\n' "$live" "$((took[slow] + 5))"; } > "$BATS_TEST_TMPDIR/twice.log"
  run "$TREE/scripts/test-times" < "$BATS_TEST_TMPDIR/twice.log"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"test-times: tests/slow.bats took ${took[slow]}s and $((took[slow] + 5))s in the input"* ]]
  cmp "$BATS_TEST_TMPDIR/before" "$TREE/tests/times.tsv"

  run "$TREE/scripts/test-times" < "$BATS_TEST_TMPDIR/job.log"

  echo "$output"
  [ "$status" -eq 0 ]
  # Each timed file's line holds its time, once though the log prints it twice; the added file keeps
  # its line, the gone file's is dropped, and the header stays.
  {
    grep '^#' "$REPO/tests/times.tsv"
    printf 'tests/%s.bats\t%s\n' broken "${took[broken]}" later 7 quick "${took[quick]}" slow "${took[slow]}"
  } > "$BATS_TEST_TMPDIR/expected"
  cmp "$BATS_TEST_TMPDIR/expected" "$TREE/tests/times.tsv"
  # One line for the gone file's line, dropped, and one for each file whose time changed.
  [ "$output" = "$(
    echo 'test-times: tests/gone.bats 9s -> dropped (not in tests/)'
    printf 'test-times: tests/%s.bats %ss -> %ss\n' broken 30 "${took[broken]}" quick 10 "${took[quick]}" slow 20 "${took[slow]}"
  )" ]
}

@test "test-times drops each line of the record just test refuses, saying so, and writes one just test reads" {
  local headed
  times_tree
  times_file a 5
  times_file b 8
  times_file c 3
  headed=$(grep -c '^#' "$TREE/tests/times.tsv")
  # Under the header: seconds that are not whole, before c.bats's own line; a space where the tab
  # belongs; a second line for a.bats; and a line for a file that is gone.
  {
    grep '^#' "$REPO/tests/times.tsv"
    printf 'tests/a.bats\t5\ntests/c.bats\t2.5\ntests/b.bats 7\ntests/b.bats\t8\ntests/a.bats\t6\ntests/c.bats\t3\ntests/gone.bats\t9\n'
  } > "$TREE/tests/times.tsv"

  run "$TREE/scripts/test-times" <<< 'test: tests/c.bats took 4s'

  echo "$output"
  [ "$status" -eq 0 ]
  {
    grep '^#' "$REPO/tests/times.tsv"
    printf 'tests/%s.bats\t%s\n' a 5 b 8 c 4
  } > "$BATS_TEST_TMPDIR/expected"
  cmp "$BATS_TEST_TMPDIR/expected" "$TREE/tests/times.tsv"
  [ "$output" = "$(printf '%s\n' \
    "test-times: tests/times.tsv:$((headed + 2)) is not a test file, a tab and its whole seconds; dropped" \
    "test-times: tests/times.tsv:$((headed + 3)) is not a test file, a tab and its whole seconds; dropped" \
    "test-times: tests/times.tsv:$((headed + 5)) repeats tests/a.bats; dropped" \
    'test-times: tests/gone.bats 9s -> dropped (not in tests/)' \
    'test-times: tests/c.bats 3s -> 4s')" ]

  # just test takes the record as written.
  printf '#!/usr/bin/env bash\nprintf "1..1\\nok 1 fine\\n"\n' > "$BIN/bats"
  chmod +x "$BIN/bats"
  times_just test 1/1
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "just test-time records the files it runs, one that fails too, and then fails" {
  local broken quick
  times_tree
  times_file broken 30
  times_file other 7
  times_file quick 10
  # A bats that fails broken.bats and passes any other file.
  cat > "$BIN/bats" << 'EOF'
#!/usr/bin/env bash
case ${!#} in
  tests/broken.bats) printf '1..1\nnot ok 1 broken 1\n'; exit 1 ;;
esac
printf '1..1\nok 1 fine\n'
EOF
  chmod +x "$BIN/bats"

  times_just test-time tests/broken.bats tests/quick.bats

  echo "$output"
  [ "$status" -ne 0 ]
  # The run's output shows, and each file's time goes into the record; the file not run keeps its line.
  [[ $output == *"not ok 1 broken 1"* ]]
  broken=$(sed -nE 's|^test: tests/broken\.bats took ([0-9]+)s$|\1|p' <<< "$output")
  quick=$(sed -nE 's|^test: tests/quick\.bats took ([0-9]+)s$|\1|p' <<< "$output")
  [[ $broken =~ ^[0-9]+$ && $quick =~ ^[0-9]+$ ]]
  {
    grep '^#' "$REPO/tests/times.tsv"
    printf 'tests/%s.bats\t%s\n' broken "$broken" other 7 quick "$quick"
  } > "$BATS_TEST_TMPDIR/expected"
  cmp "$BATS_TEST_TMPDIR/expected" "$TREE/tests/times.tsv"
  [[ $output == *"test-times: tests/broken.bats 30s -> ${broken}s"* ]]

  # A path that is not tests/<name>.bats, which its timing line would not name, is refused.
  times_just test-time ./tests/quick.bats

  [ "$status" -ne 0 ]
  [[ $output == *"test-time: ./tests/quick.bats is not a test file, tests/<name>.bats"* ]]
  cmp "$BATS_TEST_TMPDIR/expected" "$TREE/tests/times.tsv"
}

@test "the split hands the heaviest file first to the part of least recorded time, ties by path and to the lowest part" {
  local part
  local -a split_files=()
  times_tree
  times_file a 10
  times_file b 10
  times_file c 10
  times_file d 10
  times_file e 25
  # A bats that records the file it is handed.
  cat > "$BIN/bats" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "${!#}" >> "$BATS_ARGS"
printf '1..1\nok 1 fine\n'
EOF
  chmod +x "$BIN/bats"
  export BATS_ARGS="$BATS_TEST_TMPDIR/bats.args"

  for part in 1 2; do
    rm -f "$BATS_ARGS"
    times_just test "$part/2"
    echo "$output"
    [ "$status" -eq 0 ]
    split_files[part]=$(sort "$BATS_ARGS" | paste -sd ' ')
  done

  # e, the heaviest, goes first, to part 1 of two empty parts; a, b and c, of equal time and taken
  # by path, to part 2 while it holds less than part 1; d to part 1, by then the lighter.
  [ "${split_files[1]}" = 'tests/d.bats tests/e.bats' ]
  [ "${split_files[2]}" = 'tests/a.bats tests/b.bats tests/c.bats' ]
}

# gh_reads FILE: fails unless every call FILE records, its arguments separated by tabs, is one that
# only reads: gh run list, gh run view, or gh api with neither a method nor a field or input, which
# would make it write.
gh_reads() {
  local call words word
  while IFS= read -r call; do
    IFS=$'\t' read -ra words <<< "$call"
    case "${words[0]} ${words[1]-}" in
      "run list" | "run view") ;;
      api\ *)
        for word in "${words[@]}"; do
          case $word in
            -X* | --method* | -f* | -F* | --field* | --raw-field* | --input*) echo "writes: $call"; return 1 ;;
          esac
        done
        ;;
      *) echo "not a read: $call"; return 1 ;;
    esac
  done < "$1"
}

# gh_called FILE WORD...: the calls FILE records that hold every WORD as an argument of their own.
gh_called() {
  local file=$1 call word
  shift
  while IFS= read -r call; do
    for word in "$@"; do
      [[ $'\t'$call$'\t' == *$'\t'"$word"$'\t'* ]] || continue 2
    done
    printf '%s\n' "$call"
  done < "$file"
}

@test "The record of the test files' times is written from the logs of a CI run" {
  local fixtures calls job
  times_tree
  # The files whose times the fixture's tests job prints, and one it does not.
  times_file cluster-recipes 80
  times_file other 7
  times_file secret-rotate 40
  cp -p "$TREE/tests/times.tsv" "$BATS_TEST_TMPDIR/before"
  {
    grep '^#' "$REPO/tests/times.tsv"
    printf 'tests/%s.bats\t%s\n' cluster-recipes 83 other 7 secret-rotate 43
  } > "$BATS_TEST_TMPDIR/expected"
  fixtures="$BATS_TEST_DIRNAME/fixtures/test-times"
  calls="$BATS_TEST_TMPDIR/gh-calls"
  # A gh that records each call, its arguments separated by tabs, and answers from the fixtures:
  # the run list, the run's jobs, whatever run is asked for, and each job's log, which it refuses
  # to print when the log holds terminal escapes and the call does not allow them, as gh does.
  cat > "$BIN/gh" << 'EOF'
#!/usr/bin/env bash
(IFS=$'\t'; printf '%s\n' "$*") >> "$GH_CALLS"
args=("$@") filter=
for ((i = 0; i < $#; i++)); do
  if [[ ${args[i]} == --jq ]]; then filter=${args[i + 1]}; fi
done
answer() {
  if [[ -n $filter ]]; then "$JQ" -r "$filter" "$1"; else cat "$1"; fi
}
case "$1 ${2-}" in
  "run list") answer "$GH_FIXTURES/runs.json" ;;
  "run view") answer "$GH_FIXTURES/jobs.json" ;;
  api\ *)
    path=${!#}
    if [[ ! $path =~ ^repos/[^/]+/[^/]+/actions/jobs/([0-9]+)/logs$ || ! -f $GH_FIXTURES/job-${BASH_REMATCH[1]}.log ]]; then
      echo "stand-in gh: no such log: $path" >&2
      exit 1
    fi
    log=$GH_FIXTURES/job-${BASH_REMATCH[1]}.log
    if grep -q $'\e' "$log" && [[ " $* " != *" --allow-escape-sequences "* ]]; then
      echo "the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway" >&2
      exit 1
    fi
    cat "$log"
    ;;
  *) echo "stand-in gh: unexpected: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$BIN/gh"
  JQ=$(command -v jq)
  export GH_CALLS="$calls" GH_FIXTURES="$fixtures" JQ
  # The fixture's tests job prints its times live and again in its report.
  [ "$(grep -c 'test: tests/cluster-recipes.bats took 83s' "$fixtures/job-1001.log")" -eq 2 ]
  grep -q $'\e' "$fixtures/job-1001.log"

  times_just test-times-record 42

  echo "$output"
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/expected" "$TREE/tests/times.tsv"
  # Run 42's jobs, and the log of each job that ran, with nothing else asked for: job 1003 was
  # skipped and has no log.
  [ "$(jq -r '.jobs[] | select(.databaseId == 1003) | .conclusion' "$fixtures/jobs.json")" = skipped ]
  [ -z "$(gh_called "$calls" run list)" ]
  [ "$(gh_called "$calls" run view 42 --json jobs | wc -l)" -eq 1 ]
  for job in 1001 1002; do
    [ "$(gh_called "$calls" api --allow-escape-sequences "repos/{owner}/{repo}/actions/jobs/$job/logs" | wc -l)" -eq 1 ] || { echo "job $job's log not read once"; return 1; }
  done
  [ "$(wc -l < "$calls")" -eq 3 ]
  gh_reads "$calls"

  cp -p "$BATS_TEST_TMPDIR/before" "$TREE/tests/times.tsv"
  rm "$calls"

  times_just test-times-record

  echo "$output"
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/expected" "$TREE/tests/times.tsv"
  # The latest successful push run of ci on main, which the run list gives as 43.
  [ "$(gh_called "$calls" run list --workflow ci --branch main --event push --status success --limit 1 | wc -l)" -eq 1 ]
  [ "$(gh_called "$calls" run view 43 --json jobs | wc -l)" -eq 1 ]
  [ "$(wc -l < "$calls")" -eq 4 ]
  gh_reads "$calls"
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
  [ "$(tr ' ' '\n' <<< "$output" | sort | paste -sd ' ')" = "cosign flux2 jq just kustomize yq" ]
  local tool
  # just publish runs just kubernetes-check first, with the tools that script requires.
  local required
  required=$(sed -n 's/^for tool in \(.*\); do$/\1/p' "$REPO/scripts/kubernetes-check")
  [ -n "$required" ]
  for tool in ${required/flux/flux2}; do
    grep -qw -- "$tool" <<< "$output" || { echo "not installed for the check: $tool"; return 1; }
  done
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

# dagger_call: whether the commands on stdin run dagger with any subcommand, on a line that is not a
# comment.
dagger_call() {
  grep -vE '^[[:space:]]*#' | grep -qE '(^|[^[:alnum:]_./$-])dagger[[:space:]]+[-a-z]'
}

# just_recipes: the recipe each just on stdin runs, a line that is not a comment, one per line: the
# first word after just that is neither one of its options nor an option's argument, wherever just
# stands, after a prefix such as mise exec -- or VAR=value included.
just_recipes() {
  awk '
    /^[[:space:]]*#/ { next }
    {
      n = split($0, w, /[[:space:];&|()]+/)
      for (i = 1; i <= n; i++) {
        word = w[i]
        gsub(/["\047]/, "", word)
        if (word != "just" && word !~ /\/just$/) continue
        for (j = i + 1; j <= n; j++) {
          arg = w[j]
          gsub(/["\047]/, "", arg)
          if (arg == "") continue
          if (arg ~ /^-/) {
            if (arg !~ /=/ && arg ~ /^(-f|--justfile|-d|--working-directory|--set|--dotenv-filename|--dotenv-path|--shell|--shell-arg|--color|--dump-format|--command|-c)$/) j++
            continue
          }
          print arg
          break
        }
      }
    }'
}

# script_paths ROOT: the scripts under ROOT/scripts the commands on stdin run or source, a line that
# is not a comment, one per line, as paths below ROOT: a path that starts with scripts/, or one
# after a slash, as in "$here/lib/ci-host.sh", that names a file under scripts/.
script_paths() {
  local root=$1 path
  grep -vE '^[[:space:]]*#' | grep -oE '(scripts/|/)[A-Za-z0-9_][A-Za-z0-9_./-]*' | sort -u |
    while IFS= read -r path; do
      path=${path#/}
      [[ $path == scripts/* ]] || path=scripts/$path
      [[ -f $root/$path ]] && printf '%s\n' "$path"
    done
  return 0
}

# reaches_module JUSTFILE: whether the commands on stdin call the Dagger module: run dagger, or run a
# recipe of JUSTFILE or a script beside it that does. A recipe reaches it through its body, the
# recipes it depends on and those its body runs with just; a script through the scripts it runs or
# sources; as far as they go.
reaches_module() {
  local justfile=$1 root dump item kind name text
  root=$(cd "$(dirname "$justfile")" && pwd)
  dump=$(just --justfile "$justfile" --dump --dump-format json)
  local -A seen=()
  local -a queue=("text:$(cat)")
  while ((${#queue[@]})); do
    item=${queue[0]}
    queue=("${queue[@]:1}")
    kind=${item%%:*}
    name=${item#*:}
    if [[ $kind != text ]]; then
      [[ -z ${seen[$item]-} ]] || continue
      seen[$item]=1
    fi
    case $kind in
      text) text=$name ;;
      recipe)
        jq -e --arg recipe "$name" '.recipes | has($recipe)' <<< "$dump" > /dev/null || continue
        text=$(just --justfile "$justfile" --show "$name")
        while IFS= read -r name; do
          queue+=("recipe:$name")
        done < <(jq -r --arg recipe "${item#*:}" '.recipes[$recipe].dependencies[].recipe' <<< "$dump")
        ;;
      script) text=$(cat "$root/$name") ;;
    esac
    if dagger_call <<< "$text"; then
      return 0
    fi
    while IFS= read -r name; do
      queue+=("recipe:$name")
    done < <(just_recipes <<< "$text")
    while IFS= read -r name; do
      queue+=("script:$name")
    done < <(script_paths "$root" <<< "$text")
  done
  return 1
}

# module_jobs WORKFLOWS JUSTFILE: the jobs of the workflow files in the directory WORKFLOWS whose
# commands call the Dagger module, as the file's name and the job's, one per line.
module_jobs() {
  local workflow json job
  shopt -s nullglob
  for workflow in "$1"/*.yaml "$1"/*.yml; do
    json=$(yq -o=json '.' "$workflow")
    while IFS= read -r job; do
      if jq -r --arg job "$job" '[.jobs[$job].steps[]? | .run // empty] | join("\n")' <<< "$json" | reaches_module "$2"; then
        printf '%s %s\n' "${workflow##*/}" "$job"
      fi
    done < <(jq -r '.jobs | keys[]' <<< "$json")
  done
}

# shallow_jobs WORKFLOWS JUSTFILE: those of the module jobs that do not check this repository out to
# the workspace root with its whole history: with actions/checkout and neither repository nor path,
# every such step with fetch-depth 0, written as a number or a string, and at least one such step.
# A checkout of another repository or to another path, alongside it, is not the module's workspace.
shallow_jobs() {
  local file job depths
  while read -r file job; do
    depths=$(JOB=$job yq -r '[.jobs[strenv(JOB)].steps[] | select(.uses // "" | test("^actions/checkout@"))
      | select((.with.repository // "") == "" and (.with.path // "") == "") | .with["fetch-depth"] // "none" | tostring] | .[]' "$1/$file")
    if [[ -z $depths ]] || grep -qvx 0 <<< "$depths"; then
      printf '%s %s\n' "$file" "$job"
    fi
  done < <(module_jobs "$1" "$2")
}

@test "Every workflow job that calls the Dagger module checks out the whole history" {
  # These jobs call it, through the recipes and scripts they run; one that drops out of the list, or
  # joins it, fails here first.
  run module_jobs "$REPO/.github/workflows" "$REPO/justfile"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' 'ci.yaml check' 'ci.yaml render' 'tools-image.yaml publish')" ] || { echo "found: $output"; return 1; }
  # The module reads the workspace's Git history, which a shallow clone of a commit with parents
  # cannot give.
  run shallow_jobs "$REPO/.github/workflows" "$REPO/justfile"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "without the whole history: $output"; return 1; }
}

# checkout_fixture DEPTH: a repository in FIXTURE with a justfile, scripts and one workflow,
# ways.yaml, with a job for each way of reaching the Dagger module and two that do not, each checking
# out with fetch-depth DEPTH, as written into the YAML.
checkout_fixture() {
  FIXTURE="$BATS_TEST_TMPDIR/fixture"
  rm -rf "$FIXTURE"
  mkdir -p "$FIXTURE/scripts/lib" "$FIXTURE/workflows"
  cat > "$FIXTURE/justfile" <<'EOF'
direct:
    dagger api call ci checks

# A dependency reaches it.
by-dependency: direct

by-just:
    echo before
    just direct

by-script:
    scripts/outer

by-dagger-call:
    dagger call ci checks

by-dagger-c:
    dagger -c 'ci | checks'

# Mentions dagger api call only in a comment, and runs a script that does nothing with it.
none:
    # dagger api call ci checks
    scripts/plain
EOF
  # shellcheck disable=SC2016 # the scripts' own expansions, as written
  printf '#!/usr/bin/env bash\nhere=$(dirname "$0")\n"$here/lib/inner" "$@"\n' > "$FIXTURE/scripts/outer"
  # shellcheck disable=SC2016 # the scripts' own expansions, as written
  printf '#!/usr/bin/env bash\npushed=$(dagger api call ci tools-layer)\n' > "$FIXTURE/scripts/lib/inner"
  printf '#!/usr/bin/env bash\n# dagger api call ci checks\necho dagger-engine is a name\n' > "$FIXTURE/scripts/plain"
  {
    printf 'name: ways\n"on": push\njobs:\n'
    local job command
    while IFS='|' read -r job command; do
      printf '  %s:\n    runs-on: ubuntu-latest\n    steps:\n' "$job"
      printf '      - uses: actions/checkout@0000000000000000000000000000000000000000\n        with:\n          fetch-depth: %s\n' "$1"
      printf '      - run: %b\n' "$command"
    done <<'EOF'
direct|just direct "$GROUP"
dependency|just by-dependency
body|just by-just
script|just by-script
dagger-call|just by-dagger-call
dagger-c|just by-dagger-c
mise-exec|mise exec -- just direct
variable|GROUP=x just direct
option|just --justfile justfile direct
run-dagger|dagger api call ci checks
multi-line||\n          echo start\n          just direct
not-module|just none
not-just|echo just a word
EOF
  } > "$FIXTURE/workflows/ways.yaml"
}

@test "the whole-history rule finds every way a job reaches the Dagger module" {
  local -a reaching=(body dagger-c dagger-call dependency direct mise-exec multi-line option run-dagger script variable)
  checkout_fixture 1
  run module_jobs "$FIXTURE/workflows" "$FIXTURE/justfile"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ways.yaml %s\n' "${reaching[@]}" | LC_ALL=C sort)" ] || { echo "found: $output"; return 1; }
  # Shallow, every one of them is refused; with the whole history, written as a number or a string,
  # none is.
  run shallow_jobs "$FIXTURE/workflows" "$FIXTURE/justfile"
  [ "$output" = "$(printf 'ways.yaml %s\n' "${reaching[@]}" | LC_ALL=C sort)" ]
  checkout_fixture 0
  run shallow_jobs "$FIXTURE/workflows" "$FIXTURE/justfile"
  [ -z "$output" ]
  checkout_fixture "'0'"
  run shallow_jobs "$FIXTURE/workflows" "$FIXTURE/justfile"
  [ -z "$output" ]

  # Of two checkouts, the one to the workspace root is the module's: another repository or another
  # path alongside it is not, whatever its depth.
  cat > "$FIXTURE/workflows/two.yaml" <<'EOF'
name: two
"on": push
jobs:
  root-whole:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@0000000000000000000000000000000000000000
        with:
          repository: someone/else
          path: else
      - uses: actions/checkout@0000000000000000000000000000000000000000
        with:
          fetch-depth: 0
      - run: just direct
  root-shallow:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@0000000000000000000000000000000000000000
        with:
          path: elsewhere
          fetch-depth: 0
      - uses: actions/checkout@0000000000000000000000000000000000000000
      - run: just direct
  no-checkout:
    runs-on: ubuntu-latest
    steps:
      - run: just direct
EOF
  run shallow_jobs "$FIXTURE/workflows" "$FIXTURE/justfile"
  [ "$output" = "$(printf 'two.yaml %s\n' no-checkout root-shallow)" ] || { echo "refused: $output"; return 1; }

  # This repository's CI jobs that call the module, made shallow, are refused.
  mkdir -p "$BATS_TEST_TMPDIR/workflows"
  cp "$REPO"/.github/workflows/*.yaml "$BATS_TEST_TMPDIR/workflows/"
  yq -i '.jobs.check.steps[0].with["fetch-depth"] = 1 | .jobs.render.steps[0].with["fetch-depth"] = 1' "$BATS_TEST_TMPDIR/workflows/ci.yaml"
  run shallow_jobs "$BATS_TEST_TMPDIR/workflows" "$REPO/justfile"
  [ "$output" = "$(printf 'ci.yaml %s\n' check render)" ] || { echo "refused: $output"; return 1; }
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
  # No step is handed a secret or the job's token; the checkout and mise actions take the read-only
  # token by default.
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
  # One job, for runs of pull requests that were not cancelled only, on a hosted runner.
  [ "$(yq '.jobs | length' "$COMMENT")" = 1 ]
  [ "$(yq '.jobs[].if' "$COMMENT")" = "github.event.workflow_run.event == 'pull_request' && github.event.workflow_run.conclusion != 'cancelled'" ]
  [ "$(yq '.jobs[].runs-on' "$COMMENT")" = ubuntu-latest ]
  # Reading the default branch and the run's artifact, and writing to pull requests: nothing more,
  # and no job asks for more.
  [ "$(yq -o=json -I=0 '.permissions' "$COMMENT" | jq -c -S .)" = '{"actions":"read","contents":"read","pull-requests":"write"}' ]
  [ "$(yq '[.jobs[] | select(has("permissions"))] | length' "$COMMENT")" = 0 ]
  # Each checkout takes the commit the run is for, the default branch's: no other ref, repository
  # or path, and the token is not left in it.
  run yq -o=json -I=0 '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@")) | .with] | unique' "$COMMENT"
  [ "$output" = '[{"persist-credentials":false}]' ]
  # Only the checkout and mise actions, pinned as the CI workflow pins them.
  [ "$(yq -o=json -I=0 '[.jobs[].steps[] | select(has("uses")) | .uses] | unique' "$COMMENT")" = "$(yq -o=json -I=0 '[.jobs[].steps[] | select(.uses // "" | test("^(actions/checkout|jdx/mise-action)@")) | .uses] | unique' "$WORKFLOW")" ]
  [ "$(yq '[.jobs[].steps[] | select(has("uses") | not) | select(has("run") | not)] | length' "$COMMENT")" = 0 ]
  # mise installs the tools without the job's token, which can write to pull requests.
  [ "$(yq -o=json -I=0 '[.jobs[].steps[] | select(.uses // "" | test("^jdx/mise-action@")) | .with.github_token]' "$COMMENT")" = '[""]' ]
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
# $FAKE/writes. The run's artifact is the directory $FAKE/artifact, listed by the API while it exists.
fake_gh() {
  BIN="$BATS_TEST_TMPDIR/bin"
  FAKE="$BATS_TEST_TMPDIR/github"
  mkdir -p "$BIN" "$FAKE"
  cat > "$BIN/gh" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/calls"
env | cut -d= -f1 >> "$FAKE/names"
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
  "GET repos/fixture-owner/fixture-repo/actions/runs/42/artifacts")
    if [[ -d $FAKE/artifact ]]; then
      echo '{"total_count": 1, "artifacts": [{"id": 9, "name": "render-diff", "expired": false}]}'
    else
      echo '{"total_count": 0, "artifacts": []}'
    fi
    ;;
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
  run comment_job
}

# comment_job: post's run of the script, its output and its exit status its own.
comment_job() {
  rm -f "$FAKE/writes" "$FAKE/written.json"
  # Where anything the artifact made run would leave its files.
  cd "$BATS_TEST_TMPDIR" || return 1
  env -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
    PATH="${AWKBIN:+$AWKBIN:}$BIN:$PATH" FAKE="$FAKE" GH_CONFIG_DIR="$BATS_TEST_TMPDIR/gh-config" GH_TOKEN=fixture-token \
    GITHUB_REPOSITORY=fixture-owner/fixture-repo RUN_ID=42 HEAD_SHA="$HEAD_SHA" \
    HEAD_REPOSITORY=someone-else/fixture-repo HEAD_BRANCH=feature "$REPO/scripts/ci-comment" 2>&1
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

# posted: the body of the comment the fake gh was asked to write, into $BATS_TEST_TMPDIR/posted.md.
posted() {
  jq -j '.body' "$FAKE/written.json" > "$BATS_TEST_TMPDIR/posted.md"
}

# comment NAME: writes $BATS_TEST_TMPDIR/NAME.md, what render-diff writes for the renders in
# $BATS_TEST_TMPDIR/NAME-base and NAME-head, made empty when they do not exist.
comment() {
  mkdir -p "$BATS_TEST_TMPDIR/$1-base" "$BATS_TEST_TMPDIR/$1-head"
  "$REPO/scripts/render-diff" "$BATS_TEST_TMPDIR/$1-base" "$BATS_TEST_TMPDIR/$1-head" > "$BATS_TEST_TMPDIR/$1.md"
}

# added NAME LINE...: the comment render-diff writes when the render adds one object to the
# application demo/app, whose lines are LINE..., into $BATS_TEST_TMPDIR/NAME.md.
added() {
  local name=$1
  shift
  mkdir -p "$BATS_TEST_TMPDIR/$name-base/demo/app" "$BATS_TEST_TMPDIR/$name-head/demo/app"
  printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/$name-head/demo/app/ConfigMap_web_app.yaml"
  comment "$name"
}

# room: the most bytes of a comment the comment job accepts.
room() {
  (. "$REPO/scripts/lib/render-comment.sh" && echo "$render_comment_room")
}

# refused NAME [REASON]: the comment job refuses the artifact holding
# $BATS_TEST_TMPDIR/NAME/comment.md, saying REASON, by default that it is not a comment render-diff
# writes, and writes nothing.
refused() {
  local said
  artifact "$1/comment.md"
  if said=$(comment_job); then
    echo "posted $1"
    return 1
  fi
  [ ! -e "$FAKE/writes" ] || { echo "wrote for $1"; return 1; }
  [[ $said == *"${2:-is not a comment render-diff writes}"* ]] || { echo "refused $1 for another reason: $said"; return 1; }
}

@test "The comment job treats the artifact as text of a bounded size" {
  fake_gh
  # Shell, workflow command and expression syntax, in the diff, where render-diff puts what a pull
  # request writes.
  # shellcheck disable=SC2016 # the syntax is the point
  added hostile 'data:' '  a: $(touch ran-a-command)' '  b: `touch ran-a-backquote`' \
    '  c: ${{ secrets.ANYTHING }}' "  d: '; touch ran-quoted; '" '::stop-commands::fixture' 'touch ran-a-line'
  cp "$BATS_TEST_TMPDIR/hostile.md" "$BATS_TEST_TMPDIR/comment.md"
  artifact comment.md

  post

  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE/writes")" = "POST repos/fixture-owner/fixture-repo/issues/7/comments" ]
  posted
  # The artifact byte for byte, then the job's own line naming the commit it describes.
  size=$(wc -c < "$BATS_TEST_TMPDIR/comment.md")
  head -c "$size" "$BATS_TEST_TMPDIR/posted.md" | cmp - "$BATS_TEST_TMPDIR/comment.md"
  tail -c +$((size + 1)) "$BATS_TEST_TMPDIR/posted.md" > "$BATS_TEST_TMPDIR/trailer.md"
  grep -q "$HEAD_SHA" "$BATS_TEST_TMPDIR/trailer.md"
  grep -q "own CI run" "$BATS_TEST_TMPDIR/trailer.md"
  # Nothing of it ran, and none of it reached the log, where GitHub reads workflow commands.
  [[ $output != *"stop-commands"* ]]
  run find "$BATS_TEST_TMPDIR" "$REPO" -name 'ran-*'
  [ -z "$output" ]

  # A comment exactly as long as the job accepts is posted, and stays within GitHub's limit with
  # the job's line; a byte more is refused.
  local limit
  limit=$(room)
  added long x
  mkdir -p "$BATS_TEST_TMPDIR/exact" "$BATS_TEST_TMPDIR/over"
  awk -v pad=$((limit - $(wc -c < "$BATS_TEST_TMPDIR/long.md"))) \
    '!done && $0 == "+x" { line = $0; while (pad-- > 0) line = line "x"; $0 = line; done = 1 } 1' \
    "$BATS_TEST_TMPDIR/long.md" > "$BATS_TEST_TMPDIR/exact/comment.md"
  [ "$(wc -c < "$BATS_TEST_TMPDIR/exact/comment.md")" -eq "$limit" ]
  sed 's/^+x/+xx/' "$BATS_TEST_TMPDIR/exact/comment.md" > "$BATS_TEST_TMPDIR/over/comment.md"
  artifact exact/comment.md
  post
  [ "$status" -eq 0 ]
  posted
  [ "$(wc -m < "$BATS_TEST_TMPDIR/posted.md")" -le 65536 ]
  refused over

  # Every other artifact is refused before anything is posted or run.
  local case marker
  marker=$(sed -n 1p "$BATS_TEST_TMPDIR/hostile.md")
  for case in two symlink other none unmarked prefixed cr nul-diff cr-diff nul-marker; do
    mkdir -p "$BATS_TEST_TMPDIR/$case"
  done
  cp "$BATS_TEST_TMPDIR/hostile.md" "$BATS_TEST_TMPDIR/two/comment.md"
  cp "$BATS_TEST_TMPDIR/hostile.md" "$BATS_TEST_TMPDIR/two/other.md"
  ln -s "$BATS_TEST_TMPDIR/hostile.md" "$BATS_TEST_TMPDIR/symlink/comment.md"
  cp "$BATS_TEST_TMPDIR/hostile.md" "$BATS_TEST_TMPDIR/other/other.md"
  sed 1d "$BATS_TEST_TMPDIR/hostile.md" > "$BATS_TEST_TMPDIR/unmarked/comment.md"
  { echo "$marker x"; sed 1d "$BATS_TEST_TMPDIR/hostile.md"; } > "$BATS_TEST_TMPDIR/prefixed/comment.md"
  { printf '%s\r\n' "$marker"; sed 1d "$BATS_TEST_TMPDIR/hostile.md"; } > "$BATS_TEST_TMPDIR/cr/comment.md"
  sed 's/^+data:$/+da\x00ta:/' "$BATS_TEST_TMPDIR/hostile.md" > "$BATS_TEST_TMPDIR/nul-diff/comment.md"
  sed 's/^+data:$/+data:\r/' "$BATS_TEST_TMPDIR/hostile.md" > "$BATS_TEST_TMPDIR/cr-diff/comment.md"
  for case in cr nul-diff cr-diff; do
    # shellcheck disable=SC2094 # the file is only read, twice
    if tr -d '\000\r' < "$BATS_TEST_TMPDIR/$case/comment.md" | cmp -s - "$BATS_TEST_TMPDIR/$case/comment.md"; then
      echo "$case holds no NUL or carriage return"
      return 1
    fi
  done
  # bash drops a run of NULs and reads the line up to them: a command named after the marker's
  # middle, with its input from a file named after its start, would run were the file sourced.
  { printf '<!-- k8s-gitops:render-diff --'; head -c 300 /dev/zero; printf '>\nrest\n'; } > "$BATS_TEST_TMPDIR/nul-marker/comment.md"
  printf '#!/bin/sh\ntouch "%s/ran-from-artifact"\n' "$BATS_TEST_TMPDIR" > "$BIN/k8s-gitops:render-diff"
  chmod +x "$BIN/k8s-gitops:render-diff"
  : > "$BATS_TEST_TMPDIR/!--"
  refused symlink "not a regular file"
  for case in unmarked prefixed cr nul-diff cr-diff nul-marker; do
    refused "$case"
  done
  for case in "two/comment.md two/other.md" other/other.md ""; do
    # shellcheck disable=SC2086 # the files of each case, split on blanks
    artifact $case
    post
    [ "$status" -ne 0 ] || { echo "posted an artifact of: ${case:-nothing}"; return 1; }
    [ ! -e "$FAKE/writes" ] || { echo "wrote for an artifact of: ${case:-nothing}"; return 1; }
    [[ $output == *"it must hold one file, comment.md"* || $output == *"comment.md is not a comment render-diff writes: not a regular file"* ]]
  done
  [ ! -e "$BATS_TEST_TMPDIR/ran-from-artifact" ]
}

# variant NAME: sets AWKBIN to a directory whose awk is the implementation NAME, gawk, mawk or
# busybox's, for the comment job to run first on its PATH; fails when this machine has no such awk.
variant() {
  AWKBIN="$BATS_TEST_TMPDIR/awk-$1"
  mkdir -p "$AWKBIN"
  case $1 in
    busybox)
      command -v busybox > /dev/null && busybox awk 'BEGIN { exit 0 }' 2> /dev/null || return 1
      printf '#!/bin/sh\nexec busybox awk "$@"\n' > "$AWKBIN/awk"
      chmod +x "$AWKBIN/awk"
      ;;
    *)
      command -v "$1" > /dev/null || return 1
      ln -sf "$(command -v "$1")" "$AWKBIN/awk"
      ;;
  esac
}

# grammar_comments: writes every kind of comment render-diff writes: nothing changed; objects
# added, removed and changed across applications; a diff whose backquotes need a longer fence; a
# diff cut to fit.
grammar_comments() {
  comment unchanged
  mkdir -p "$BATS_TEST_TMPDIR"/mixed-{base,head}/demo/{one,two,three}
  printf 'a: 1\n' > "$BATS_TEST_TMPDIR/mixed-base/demo/one/ConfigMap_web_a.yaml"
  printf 'b: 1\n' > "$BATS_TEST_TMPDIR/mixed-base/demo/one/ConfigMap_web_b.yaml"
  printf 'b: 2\n' > "$BATS_TEST_TMPDIR/mixed-head/demo/one/ConfigMap_web_b.yaml"
  printf 'c: 1\n' > "$BATS_TEST_TMPDIR/mixed-head/demo/one/ConfigMap_web_c.yaml"
  printf 'new: 1\n' > "$BATS_TEST_TMPDIR/mixed-head/demo/two/Namespace__new.yaml"
  printf 'old: 1\n' > "$BATS_TEST_TMPDIR/mixed-base/demo/three/ClusterRole.rbac.authorization.k8s.io__old.yaml"
  comment mixed
  added fenced 'fence: |' '  ``````' '  <details><summary>not a section</summary>'
  mkdir -p "$BATS_TEST_TMPDIR"/cut-{base,head}/demo/{small,large}
  printf 'small: 1\n' > "$BATS_TEST_TMPDIR/cut-head/demo/small/ConfigMap_web_small.yaml"
  for ((i = 0; i < 3000; i++)); do
    printf 'key-%04d: a value long enough to fill a comment quickly\n' "$i"
  done > "$BATS_TEST_TMPDIR/cut-head/demo/large/ConfigMap_web_large.yaml"
  comment cut
  grep -q 'truncated' "$BATS_TEST_TMPDIR/cut.md"
  local body
  for body in unchanged mixed fenced cut; do
    mkdir -p "$BATS_TEST_TMPDIR/written-$body"
    cp "$BATS_TEST_TMPDIR/$body.md" "$BATS_TEST_TMPDIR/written-$body/comment.md"
  done
}

# edit NAME [OLD NEW]...: the mixed comment with each of its lines OLD made NEW, as NAME/comment.md.
edit() {
  local name=$1 file
  shift
  mkdir -p "$BATS_TEST_TMPDIR/$name"
  file="$BATS_TEST_TMPDIR/$name/comment.md"
  cp "$BATS_TEST_TMPDIR/mixed.md" "$file"
  while (($# >= 2)); do
    OLD=$1 NEW=$2 awk '$0 == ENVIRON["OLD"] { $0 = ENVIRON["NEW"] } { print }' "$file" > "$file.new"
    if cmp -s "$file" "$file.new"; then
      echo "$name: no line $1"
      return 1
    fi
    mv "$file.new" "$file"
    shift 2
  done
}

# accepted NAME: the comment job posts the artifact holding $BATS_TEST_TMPDIR/NAME/comment.md.
accepted() {
  local said
  artifact "$1/comment.md"
  said=$(comment_job) || { echo "refused $1: $said"; return 1; }
  [ -e "$FAKE/writes" ] || { echo "posted nothing for $1"; return 1; }
}

# grammar_cases: the comment job, with the awk first on PATH that AWKBIN holds, posts every comment
# render-diff writes and refuses every other.
grammar_cases() {
  local body name row summary
  for body in unchanged mixed fenced cut; do
    accepted "written-$body"
  done
  # shellcheck disable=SC2016 # Markdown code spans
  row='| `demo/two` | 1 | 0 | 0 |'
  summary='<summary><code>demo/two</code>: 1 added</summary>'
  # Counts of up to six digits, which GitHub links to no commit.
  # shellcheck disable=SC2016 # a Markdown code span
  edit counted "$row" '| `demo/two` | 999999 | 0 | 0 |' "$summary" '<summary><code>demo/two</code>: 999999 added</summary>'
  accepted counted

  # Anything else outside a diff would render as Markdown in the bot's name: each is refused.
  # insert NAME LINE: the mixed comment with LINE after its table's last row, refused.
  insert() {
    mkdir -p "$BATS_TEST_TMPDIR/$1"
    LINE=$2 awk '{ print } /^\| `demo\/two` / { print ENVIRON["LINE"] }' "$BATS_TEST_TMPDIR/mixed.md" > "$BATS_TEST_TMPDIR/$1/comment.md"
    cmp -s "$BATS_TEST_TMPDIR/mixed.md" "$BATS_TEST_TMPDIR/$1/comment.md" && { echo "$1: nothing inserted"; return 1; }
    refused "$1"
  }
  insert mention '@someone this is ready to merge'
  insert team '@fixture-owner/maintainers'
  insert reference 'Fixes #7'
  insert cross-reference 'fixture-owner/fixture-repo#7'
  insert link '[the checks passed](https://example.invalid/checks)'
  insert image '![passed](https://example.invalid/passed.png)'
  insert html '<img src="https://example.invalid/pixel.png">'
  insert free 'All checks have passed.'
  # shellcheck disable=SC2016 # a Markdown code span
  insert row '| `demo/two` | 1 | 0 | 0 | @someone |'
  # A section's summary holds nothing but the application's name and its counts.
  edit summary "$summary" '<summary><code>@someone</code>: 1 added</summary>'
  refused summary
  edit summary-then-text "$summary" "$summary @someone"
  refused summary-then-text
  edit summary-text-first "$summary" '<summary><code>demo/two</code>: @someone 1 added</summary>'
  refused summary-text-first
  # An application's name is two DNS labels, in the table and in a summary alike.
  for name in '@someone/x' 'de@mo/two' 'de.mo/two' 'de#mo/two' 'de mo/two' 'demo/t@o' 'demo/t.o' 'demo/t#o' 'demo/t o'; do
    # shellcheck disable=SC2016 # a Markdown code span
    edit row-name "$row" "| \`$name\` | 1 | 0 | 0 |"
    refused row-name
    edit summary-name "$summary" "<summary><code>$name</code>: 1 added</summary>"
    refused summary-name
  done
  # Seven digits or more could be read as a commit.
  # shellcheck disable=SC2016 # a Markdown code span
  edit row-count "$row" '| `demo/two` | 1000000 | 0 | 0 |'
  refused row-count
  edit summary-count "$summary" '<summary><code>demo/two</code>: 1000000 added</summary>'
  refused summary-count
  edit closing '+new: 1' '```'
  refused closing
  edit indented-closing '+new: 1' ' ```'
  refused indented-closing
  edit heading '### Render diff' '### Render diff: approved'
  refused heading
  edit footer "$(grep -m1 '^<sub>' "$BATS_TEST_TMPDIR/mixed.md")" '<sub>Approved by the maintainers.</sub>'
  refused footer
  mkdir -p "$BATS_TEST_TMPDIR/after"
  { cat "$BATS_TEST_TMPDIR/mixed.md"; echo '@someone'; } > "$BATS_TEST_TMPDIR/after/comment.md"
  refused after
}

@test "The comment job posts nothing but what render-diff writes" {
  fake_gh
  grammar_comments
  # Under every awk this machine has of those a runner may run the check with.
  local awk ran=()
  for awk in gawk mawk busybox; do
    if variant "$awk"; then
      # Called plainly, so that the first case that fails stops the test.
      echo "under $awk:"
      grammar_cases
      ran+=("$awk")
    else
      echo "# $awk is not on this machine: the comment check's run under it is skipped" >&3
    fi
  done
  AWKBIN=
  echo "under the awk first on PATH:"
  grammar_cases
  echo "# the comment check ran under: ${ran[*]:-none of them} and the awk first on PATH" >&3
}

@test "the comment job updates its own comment, and posts nothing for a pull request that moved on" {
  fake_gh
  comment unchanged
  cp "$BATS_TEST_TMPDIR/unchanged.md" "$BATS_TEST_TMPDIR/comment.md"
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

  # Not when two open pull requests have that head, nor when the one that has it is another
  # repository's: no pull request is the run's for certain, and nothing is posted.
  local pulls="$FAKE/pulls.json"
  cp "$pulls" "$FAKE/one.json"
  jq '. + [.[0] | .number = 8]' "$FAKE/one.json" > "$pulls"
  post
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE/writes" ]
  jq '.[0].head.repo.full_name = "someone-else/another-repo"' "$FAKE/one.json" > "$pulls"
  post
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE/writes" ]

  # A newer push moved the head on: its own run comments, this one posts nothing.
  jq '.[0].head.sha = "fedcba9876543210fedcba9876543210fedcba98"' "$FAKE/one.json" > "$pulls"
  post
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE/writes" ]
  [[ $output == *"no open pull request"* ]]

  # Runs for one pull request's head never overlap, and a running one is never cancelled: the
  # older of two finds the head moved on.
  # shellcheck disable=SC2016 # the workflow's expression, as written
  [ "$(yq '.concurrency.group' "$COMMENT")" = 'render-comment-${{ github.event.workflow_run.head_repository.full_name }}-${{ github.event.workflow_run.head_branch }}' ]
  [ "$(yq '.concurrency.cancel-in-progress' "$COMMENT")" = false ]
}

@test "the comment job says when a commit did not render, and posts nothing else without an artifact" {
  fake_gh
  comment unchanged
  # The CI run left no artifact: its render did not complete.
  rm -rf "$FAKE/artifact"

  post

  [ "$status" -eq 0 ]
  [[ $output == *"left no render diff"* ]]
  [ ! -e "$FAKE/writes" ]

  # Its own earlier comment is updated to say so, in words of the job's own.
  jq -n --rawfile body "$BATS_TEST_TMPDIR/unchanged.md" \
    '[{id: 202, user: {login: "github-actions[bot]", type: "Bot"}, body: $body}]' > "$FAKE/comments.json"
  post
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE/writes")" = "PATCH repos/fixture-owner/fixture-repo/issues/comments/202" ]
  posted
  [ "$(sed -n 1p "$BATS_TEST_TMPDIR/posted.md")" = "$(sed -n 1p "$BATS_TEST_TMPDIR/unchanged.md")" ]
  grep -q "$HEAD_SHA did not render" "$BATS_TEST_TMPDIR/posted.md"

  # Not when the pull request has moved on.
  jq '.[0].head.sha = "fedcba9876543210fedcba9876543210fedcba98"' "$FAKE/pulls.json" > "$FAKE/moved.json"
  mv "$FAKE/moved.json" "$FAKE/pulls.json"
  post
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE/writes" ]
}

@test "The comment job runs gh with its own token and none of the other secrets" {
  fake_gh
  comment unchanged
  cp "$BATS_TEST_TMPDIR/unchanged.md" "$BATS_TEST_TMPDIR/comment.md"
  artifact comment.md
  local names=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CLUSTER_S3_ACCESS_KEY_ID CLUSTER_S3_SECRET_ACCESS_KEY
    OS_CLOUD OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET TF_STATE_PASSPHRASE
    TF_ENCRYPTION SOPS_AGE_KEY SOPS_AGE_KEY_FILE FLUX_AGE_KEY FLUX_AGE_KEY_FILE OPERATOR_CIDRS)
  local name
  for name in "${names[@]}"; do export "$name=marker-$name"; done

  post

  [ "$status" -eq 0 ]
  [ -s "$FAKE/names" ]
  grep -qx GH_TOKEN "$FAKE/names"
  for name in "${names[@]}"; do
    echo "$name"
    if grep -qx "$name" "$FAKE/names"; then return 1; fi
  done
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

@test "just ci renders the tree as the render job does" {
  # The render is a check of exactly one of just ci's groups.
  [ "$(runs_of "$REPO/justfile" | awk -F'\t' '$2 == "render-check"' | wc -l)" -eq 1 ]
  # A checkout whose tree is the render fixture's, with the fixture's chart at hand, so nothing is
  # pulled; Helm's settings and its registry logins are the test's own.
  local work="$BATS_TEST_TMPDIR/work" scratch="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$work" "$scratch"
  cp -R "$REPO/justfile" "$REPO/just" "$REPO/scripts" "$REPO/tests/fixtures/render/kubernetes" \
    "$REPO/tests/fixtures/render/versions.yaml" "$work/"
  local -a env=(HELM_CACHE_HOME="$BATS_TEST_TMPDIR/helm/cache" HELM_CONFIG_HOME="$BATS_TEST_TMPDIR/helm/config"
    HELM_DATA_HOME="$BATS_TEST_TMPDIR/helm/data" DOCKER_CONFIG="$BATS_TEST_TMPDIR/docker"
    RENDER_CHART_CACHE="$BATS_TEST_TMPDIR/charts" KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig" TMPDIR="$scratch")
  mkdir -p "$BATS_TEST_TMPDIR/docker"
  env "${env[@]}" helm package "$REPO/tests/fixtures/render/charts/greeter" \
    --destination "$BATS_TEST_TMPDIR/charts/charts.example.invalid/greeter/1.0.0" > /dev/null

  run env "${env[@]}" just --justfile "$work/justfile" render-check

  [ "$status" -eq 0 ]
  [[ $output == *"render: 5 applications"* ]]
  # It keeps nothing.
  [ -z "$(ls -A "$scratch")" ]
  # A tree that does not render fails it, as it fails the render job, naming the application.
  yq -i '.broken = true' "$work/kubernetes/apps/base/web/greeter/app/values.yaml"
  run env "${env[@]}" just --justfile "$work/justfile" render-check
  [ "$status" -ne 0 ]
  [[ $output == *"demo/greeter"* ]]
  [ -z "$(ls -A "$scratch")" ]
}

@test "The tool installer is pinned to an exact version in every workflow, a workflow whose token can write checks its binary, and the publish job keeps no cache" {
  local workflow uses=0 version
  shopt -s nullglob
  for workflow in "$REPO"/.github/workflows/*.yaml "$REPO"/.github/workflows/*.yml; do
    run yq '.jobs[].steps[] | select(.uses | test("^jdx/mise-action@")) | .with.version' "$workflow"
    [ "$status" -eq 0 ]
    while IFS= read -r version; do
      [ -n "$version" ] || continue
      uses=$((uses + 1))
      [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "${workflow##*/}: mise is not pinned to an exact version: $version"; return 1; }
    done <<< "$output"
  done
  [ "$uses" -gt 0 ]
  # A workflow whose token can write has the mise binary checked against a checksum, the same in
  # every such use. Whether the value is the pinned release's is not read here: a mise bump, which is
  # by hand (.renovate/by-hand.tsv), carries its checksum, and the publish job fails closed on a
  # mismatch.
  local writes sums=() sum
  for workflow in "$REPO"/.github/workflows/*.yaml "$REPO"/.github/workflows/*.yml; do
    writes=$(yq '[.permissions // {}, (.jobs[].permissions // {})] | map(to_entries) | flatten | map(select(.value == "write")) | length' "$workflow")
    ((writes)) || continue
    run yq '.jobs[].steps[] | select(.uses | test("^jdx/mise-action@")) | .with.sha256' "$workflow"
    [ "$status" -eq 0 ]
    while IFS= read -r sum; do
      [ -n "$sum" ] || continue
      [[ $sum =~ ^[0-9a-f]{64}$ ]] || { echo "${workflow##*/}: no checksum for a mise whose workflow can write: $sum"; return 1; }
      sums+=("$sum")
    done <<< "$output"
  done
  [ "${#sums[@]}" -ge 2 ]
  [ "$(printf '%s\n' "${sums[@]}" | sort -u | wc -l)" -eq 1 ]
  # The job that signs never restores a tool cache: an entry is chosen by key, and the job's
  # identity token can sign.
  local publish="$REPO/.github/workflows/publish.yaml"
  run yq '.jobs.publish.steps[] | select(.uses | test("^jdx/mise-action@")) | .with.cache' "$publish"
  [ "$output" = false ]
}
