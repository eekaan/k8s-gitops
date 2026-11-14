#!/usr/bin/env bats
# Proves features/publish.feature, but for its last two scenarios, which read the workflow files and
# are proved in tests/ci.bats beside the CI workflow's own; each test carries its scenario's title.
# just publish runs in a copy of the repository: a git repository on main whose origin is a bare
# repository in the test's directory, so the newest-commit guard fetches from there. docker, cosign
# and flux are recording fakes, so nothing logs in, pushes, signs or tags; for a push, the fake flux
# builds what would be uploaded with the pinned flux build artifact, which is local and offline. git
# and jq are the real ones, recorded on their way. kubectl, openstack, gh and talosctl are fakes that
# fail, so a call to any of them shows. Each run gets only the environment a test gives it, as a
# publish job's own, with HOME in the test's directory.

setup_file() {
  # What git would commit here, committed on main once, and a bare origin made from it; each test
  # copies both.
  local root path template="$BATS_FILE_TMPDIR/template"
  root=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$template/repo"
  while IFS= read -r -d '' path; do
    # A file deleted here but still in the index has nothing to copy.
    [[ -e $root/$path || -L $root/$path ]] || continue
    mkdir -p -- "$template/repo/$(dirname -- "$path")"
    cp -pP -- "$root/$path" "$template/repo/$path"
  done < <(git -C "$root" ls-files -z --cached --others --exclude-standard)
  git -C "$template/repo" init -q -b main
  git -C "$template/repo" add -A
  git -C "$template/repo" -c user.name=test -c user.email=test@example.invalid commit -q -m "checkout under test"
  git clone -q --bare "$template/repo" "$template/origin.git"
}

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  JUST=$(command -v just)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$BIN" "$RECORD" "$STATE" "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/tmp"
  cp -R "$BATS_FILE_TMPDIR/template/repo" "$BATS_FILE_TMPDIR/template/origin.git" "$BATS_TEST_TMPDIR/"
  REPO="$BATS_TEST_TMPDIR/repo"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" fetch -q origin
  SHA=$(git -C "$REPO" rev-parse HEAD)
  # Each cluster's FluxInstance values: the artifact it syncs and the signature it requires.
  VALUES=("$ROOT"/kubernetes/clusters/*/flux-system/flux-instance/app/values.yaml)
  SYNC_URL=$(yq '.instance.sync.url' "${VALUES[0]}")
  # What the fake push reports as the pushed artifact's digest.
  DIGEST="sha256:$(printf 'pushed artifact' | sha256sum | cut -d' ' -f1)"
  printf '%s' "$DIGEST" > "$STATE/digest"
  TOKEN='registry-token-that-stays-hidden'
  ENVIRONMENT=(
    HOME="$BATS_TEST_TMPDIR/home"
    TMPDIR="$BATS_TEST_TMPDIR/tmp"
    GIT_CONFIG_GLOBAL=/dev/null
    GIT_CONFIG_NOSYSTEM=1
    KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
    GITHUB_ACTIONS=true
    GITHUB_REF=refs/heads/main
    GITHUB_ACTOR=example-actor
    # A host that never resolves: even a real cosign would get no identity token from it.
    ACTIONS_ID_TOKEN_REQUEST_URL=https://token.example.invalid/request
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=example-request-token
    REGISTRY_TOKEN="$TOKEN"
  )
  fakes
  check_stand_in
}

teardown() {
  # Nothing reaches a cluster, a cloud or GitHub's API.
  if [[ -e $RECORD/calls ]] && grep -E '^(kubectl|openstack|gh|talosctl) ' "$RECORD/calls"; then
    return 1
  fi
}

# stub NAME: a binary first on the run's PATH, its body read from stdin.
stub() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# fake NAME: a stub that first records its call in RECORD/calls, one line of its name and its
# arguments quoted as printf %q quotes them, and has RECORD, STATE and REAL_FLUX set for its body.
fake() {
  {
    printf 'RECORD=%q STATE=%q REAL_FLUX=%q\n' "$RECORD" "$STATE" "$REAL_FLUX"
    cat <<'EOF'
{ printf '%q ' "${0##*/}" "$@"; echo; } >> "$RECORD/calls"
EOF
    cat
  } | stub "$1"
}

# fakes: the stand-ins on the run's PATH.
fakes() {
  local tool real
  REAL_FLUX=$(command -v flux)
  # A mise with nothing installed keeps the justfile from putting the real tools in front of these.
  stub mise < /dev/null
  for tool in git jq; do
    real=$(command -v "$tool")
    printf 'exec %q "$@"\n' "$real" | fake "$tool"
  done
  for tool in kubectl openstack gh talosctl; do
    fake "$tool" <<'EOF'
echo "fake ${0##*/}: never called by a publish run" >&2
exit 1
EOF
  done
  # docker login keeps the login in the Docker configuration, as base64 of user:password.
  fake docker <<'EOF'
printf '%s\n' "${DOCKER_CONFIG:-$HOME/.docker}" >> "$RECORD/docker-config.docker"
case ${1-} in
  login)
    password=$(cat)
    printf '%s' "$password" > "$RECORD/docker-login.stdin"
    shift
    user=
    while (($#)); do
      case $1 in
        -u | --username) user=$2; shift ;;
        --username=*) user=${1#*=} ;;
      esac
      shift
    done
    dir=${DOCKER_CONFIG:-$HOME/.docker}
    mkdir -p "$dir"
    printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "$(printf '%s:%s' "$user" "$password" | base64 -w0)" > "$dir/config.json"
    echo "Login Succeeded"
    ;;
  *) echo "fake docker: unexpected call" >&2; exit 1 ;;
esac
EOF
  # flux push answers as the pinned flux does with --output json, with the digest in STATE/digest.
  fake flux <<'EOF'
printf '%s\n' "${DOCKER_CONFIG:-$HOME/.docker}" >> "$RECORD/docker-config.flux"
case "${1-} ${2-}" in
  "push artifact")
    shift 2
    # A push uploads what flux build artifact makes of the same directory with the same rules.
    build=(build artifact --output "$STATE/artifact.tgz")
    url=
    while (($#)); do
      case $1 in
        -f | --path | --ignore-paths | --add-ignore-paths) build+=("$1" "$2"); shift ;;
        --path=* | --ignore-paths=* | --add-ignore-paths=* | --resolve-symlinks*) build+=("$1") ;;
        -o | --output | --source | --revision | -a | --annotations | --creds | --provider | --timeout) shift ;;
        -*) ;;
        *) url=$1 ;;
      esac
      shift
    done
    if ! "$REAL_FLUX" "${build[@]}" > "$STATE/build.log" 2>&1; then
      cat "$STATE/build.log" >&2
      exit 1
    fi
    repository=${url#oci://}
    repository=${repository%:*}
    digest=$(cat "$STATE/digest")
    printf '{"url":"oci://%s@%s","repository":"%s","tag":"%s","digest":"%s"}\n' \
      "$repository" "$digest" "$repository" "${url##*:}" "$digest"
    ;;
  "tag artifact") ;;
  "build artifact") exec "$REAL_FLUX" "$@" ;;
  *) echo "fake flux: unexpected call" >&2; exit 1 ;;
esac
EOF
  # cosign verify fails while STATE/verify-fails exists.
  fake cosign <<'EOF'
printf '%s\n' "${DOCKER_CONFIG:-$HOME/.docker}" >> "$RECORD/docker-config.cosign"
case ${1-} in
  # A keyless signature carries the identity of the run that made it: this workflow at its ref.
  sign) printf '%s' "${GITHUB_REF-}" > "$STATE/signed-at" ;;
  verify)
    identity=
    while (($#)); do
      [[ $1 == --certificate-identity ]] && identity=$2
      shift
    done
    if [[ -e $STATE/verify-fails || $identity != *"/.github/workflows/publish.yaml@$(cat "$STATE/signed-at" 2> /dev/null)" ]]; then
      echo "Error: no matching signatures: none of the expected identities matched" >&2
      exit 1
    fi
    echo '[{"critical":{"type":"cosign container image signature"}}]'
    ;;
  *) echo "fake cosign: unexpected call" >&2; exit 1 ;;
esac
EOF
}

# check_stand_in: replaces the copy's scripts/kubernetes-check, which has its own tests, with a
# recorded call that fails, saying why, for its own tree while STATE/check-fails exists and for any
# tree that holds kubernetes/breaks-the-check. It records the credentials it can see, the registry login included.
check_stand_in() {
  {
    echo '#!/usr/bin/env bash'
    printf 'RECORD=%q STATE=%q\n' "$RECORD" "$STATE"
    cat <<'EOF'
echo kubernetes-check >> "$RECORD/calls"
for name in REGISTRY_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN; do
  [[ -z ${!name+x} ]] || echo "$name" >> "$RECORD/check-env"
done
# The registry login is written to the Docker configuration by docker login.
[[ ! -e ${DOCKER_CONFIG:-$HOME/.docker}/config.json ]] || echo "the registry login" >> "$RECORD/check-env"
dir=${1:-$(dirname "$0")/..}
if [[ -e $STATE/check-fails && -z ${1:-} ]] || [[ -e $dir/kubernetes/breaks-the-check ]]; then
  echo "kubernetes-check: kubernetes/apps/base/demo/hello/ks.yaml: a rule of the layout is broken" >&2
  exit 1
fi
EOF
  } > "$REPO/scripts/kubernetes-check"
}

# with NAME=VALUE...: sets NAME in the environment the run gets, in place of any value it had.
with() {
  local entry
  for entry; do
    without "${entry%%=*}"
    ENVIRONMENT+=("$entry")
  done
}

# without NAME: drops NAME from the environment the run gets.
without() {
  local kept=() entry
  for entry in "${ENVIRONMENT[@]}"; do
    [[ $entry == "$1="* ]] || kept+=("$entry")
  done
  ENVIRONMENT=("${kept[@]}")
}

# publish: runs just publish in the copy with only ENVIRONMENT set. A run that blocks fails after two
# minutes instead of hanging the tests.
publish() {
  run timeout 120 env -i PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$REPO/justfile" --working-directory "$REPO" publish
  echo "$output"
}

# newer_commit PATH: a commit after the copy's on origin's main that changes PATH; sets NEWER to it.
newer_commit() {
  local other="$BATS_TEST_TMPDIR/other"
  git clone -q "$ORIGIN" "$other"
  mkdir -p "$other/$(dirname "$1")"
  echo '# changed after the run started' >> "$other/$1"
  git -C "$other" add -A
  git -C "$other" -c user.name=test -c user.email=test@example.invalid commit -q -m "change $1"
  git -C "$other" push -q origin main
  NEWER=$(git -C "$other" rev-parse HEAD)
}

# steps: the recorded calls to docker, flux and cosign, in order, as the tool and its subcommand.
steps() {
  [[ -e $RECORD/calls ]] || return 0
  awk '$1 == "docker" || $1 == "flux" || $1 == "cosign" { print $1, $2 }' "$RECORD/calls"
}

# flow: steps, with the tree's check in its place among them.
flow() {
  [[ -e $RECORD/calls ]] || return 0
  awk '$1 == "kubernetes-check" { print $1 } $1 == "docker" || $1 == "flux" || $1 == "cosign" { print $1, $2 }' "$RECORD/calls"
}

# step_list STEP...: STEPs one per line, as steps prints them.
step_list() {
  printf '%s\n' "$@"
}

# argv CALL: the arguments of the one recorded call that starts with CALL (a tool and its
# subcommand), one per line, each --flag=value split into the flag and its value.
argv() {
  local line arg
  local -a args
  line=$(grep -E -- "^$1 " "$RECORD/calls" || true)
  if [[ -z $line || $line == *$'\n'* ]]; then
    echo "not exactly one call of $1" >&2
    return 1
  fi
  eval "args=($line)"
  for arg in "${args[@]}"; do
    if [[ $arg == --*=* ]]; then
      printf '%s\n%s\n' "${arg%%=*}" "${arg#*=}"
    else
      printf '%s\n' "$arg"
    fi
  done
}

# value FLAG: the value given to FLAG in the arguments on stdin, one per line; fails unless FLAG is
# given exactly once.
value() {
  awk -v flag="$1" 'found { print; found = 0; n++; next } $0 == flag { found = 1 } END { exit n != 1 }'
}

# named_by_digest REPOSITORY: fails unless the arguments on stdin name REPOSITORY, and only as
# REPOSITORY@DIGEST, with or without oci://.
named_by_digest() {
  local arg named=0
  while IFS= read -r arg; do
    [[ $arg == *"$1"* ]] || continue
    named=1
    if [[ $arg != "$1@$DIGEST" && $arg != "oci://$1@$DIGEST" ]]; then
      echo "names the artifact otherwise than by the signed digest: $arg" >&2
      return 1
    fi
  done
  ((named)) || { echo "does not name $1" >&2; return 1; }
}

# literal REGEX: the one string the anchored REGEX matches, when its only special characters are the
# anchors and punctuation escaped with a backslash; fails for any other REGEX.
literal() {
  local regex=$1 string='' char
  [[ $regex == ^* && $regex == *'$' ]] || return 1
  regex=${regex:1:${#regex}-2}
  while [[ -n $regex ]]; do
    char=${regex:0:1}
    if [[ $char == "\\" ]]; then
      char=${regex:1:1}
      # An escaped letter or digit is a class or a reference, not the character itself.
      [[ -n $char && $char != [[:alnum:]] ]] || return 1
      regex=${regex:2}
    elif [[ '.[]()*+?{}|^$' == *"$char"* ]]; then
      return 1
    else
      regex=${regex:1}
    fi
    string+=$char
  done
  printf '%s' "$string"
}

# accepts FLAG REGEX: fails unless the cosign arguments on stdin hold the claim FLAG names to exactly
# the strings REGEX matches: FLAG once with the one string REGEX matches, or FLAG-regexp once with
# REGEX itself, and not both.
accepts() {
  local flag=$1 regex=$2 args exact patterns want
  args=$(cat)
  exact=$(grep -cxF -- "$flag" <<< "$args" || true)
  patterns=$(grep -cxF -- "$flag-regexp" <<< "$args" || true)
  if ((exact + patterns != 1)); then
    echo "$flag: given $exact times, $flag-regexp $patterns times; want one of them once" >&2
    return 1
  fi
  if ((exact)); then
    want=$(literal "$regex") || { echo "$regex matches more than one string" >&2; return 1; }
    [ "$(value "$flag" <<< "$args")" = "$want" ]
  else
    [ "$(value "$flag-regexp" <<< "$args")" = "$regex" ]
  fi
}

@test "The artifact is signed and verified before the tag moves" {
  publish

  [ "$status" -eq 0 ]
  [[ $output == *"tag main moved to $DIGEST"* ]]
  run steps
  [ "$output" = "$(step_list 'docker login' 'flux push' 'cosign sign' 'cosign verify' 'flux tag')" ]
}

@test "The tag moves to the digest that was signed, not to a tag" {
  local values repository=${SYNC_URL#oci://}
  for values in "${VALUES[@]}"; do
    [ "$(yq '.instance.sync.url' "$values")" = "$SYNC_URL" ]
    [ "$(yq '.instance.sync.ref' "$values")" = main ]
  done

  publish

  [ "$status" -eq 0 ]
  [[ $output == *"$DIGEST"* ]]
  run argv 'cosign sign'
  [ "$status" -eq 0 ]
  named_by_digest "$repository" <<< "$output"
  run argv 'cosign verify'
  [ "$status" -eq 0 ]
  named_by_digest "$repository" <<< "$output"
  run argv 'flux tag'
  [ "$status" -eq 0 ]
  named_by_digest "$repository" <<< "$output"
  [ "$(value --tag <<< "$output")" = main ]
}

@test "A run that is not on main publishes and signs but leaves the tag alone" {
  with GITHUB_REF=refs/heads/feature/next

  publish

  [ "$status" -eq 0 ]
  [[ $output == *"tag main not moved"*"refs/heads/feature/next"* ]]
  run steps
  [ "$output" = "$(step_list 'docker login' 'flux push' 'cosign sign' 'cosign verify')" ]
}

@test "An older run does not move the tag back" {
  newer_commit kubernetes/apps/base/demo/hello/app/configmap.yaml

  publish

  [ "$status" -eq 0 ]
  [[ $output == *"tag main not moved"*"${NEWER:0:7}"* ]]
  run steps
  [ "$output" = "$(step_list 'docker login' 'flux push' 'cosign sign' 'cosign verify')" ]
}

@test "a newer commit that changes only the publish workflow keeps the tag where it is too" {
  newer_commit .github/workflows/publish.yaml

  publish

  [ "$status" -eq 0 ]
  [[ $output == *"tag main not moved"*"${NEWER:0:7}"* ]]
  run steps
  [ "$output" = "$(step_list 'docker login' 'flux push' 'cosign sign' 'cosign verify')" ]
}

@test "a newer commit that changes nothing published leaves the tag free to move" {
  newer_commit docs/kubernetes.md

  publish

  [ "$status" -eq 0 ]
  [[ $output == *"tag main moved to $DIGEST"* ]]
  run steps
  [ "$output" = "$(step_list 'docker login' 'flux push' 'cosign sign' 'cosign verify' 'flux tag')" ]
}

@test "The artifact is published only after the Kubernetes check passes" {
  publish

  [ "$status" -eq 0 ]
  run flow
  [ "$output" = "$(step_list 'kubernetes-check' 'docker login' 'flux push' 'cosign sign' 'cosign verify' 'flux tag')" ]
  # The check builds manifests and needs no credential, so it gets none.
  [ ! -e "$RECORD/check-env" ] || { echo "the check saw: $(cat "$RECORD/check-env")"; return 1; }
}

@test "A newer commit on main whose tree fails the check still keeps the tag where it is" {
  newer_commit kubernetes/breaks-the-check

  publish

  [ "$status" -eq 0 ]
  [[ $output == *"tag main not moved"*"${NEWER:0:7}"* ]]
  # The run judges its own tree only: what a newer commit's tree does is for that commit's run.
  run flow
  [ "$output" = "$(step_list 'kubernetes-check' 'docker login' 'flux push' 'cosign sign' 'cosign verify')" ]
}

# The ordering tests replay a history: A is the checkout under test, and B and C are commits that
# arrive on origin's main after it. COMMIT maps a name to its commit, and TAGGED is the artifact the
# tag main names, by the name of its commit. A run's artifact has the digest of its commit's name,
# and a run that tags says which one.
declare -gA COMMIT=()

# world N: a copy of the repository on A, with an origin of its own, for the Nth history.
world() {
  ORIGIN="$BATS_TEST_TMPDIR/origin-$1.git"
  REPO="$BATS_TEST_TMPDIR/repo-$1"
  OTHER="$BATS_TEST_TMPDIR/other-$1"
  cp -R "$BATS_FILE_TMPDIR/template/repo" "$REPO"
  cp -R "$BATS_FILE_TMPDIR/template/origin.git" "$ORIGIN"
  git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" fetch -q origin
  git clone -q "$ORIGIN" "$OTHER"
  check_stand_in
  COMMIT=([A]=$SHA)
  TAGGED=
}

# arrive NAME PATH: commits a change to PATH on origin's main as NAME.
arrive() {
  mkdir -p "$OTHER/$(dirname "$2")"
  echo "# $1" >> "$OTHER/$2"
  git -C "$OTHER" add -A
  git -C "$OTHER" -c user.name=test -c user.email=test@example.invalid commit -q -m "$1 changes $2"
  git -C "$OTHER" push -q origin main
  COMMIT[$1]=$(git -C "$OTHER" rev-parse HEAD)
}

# run_at NAME: a publish run for NAME's commit, as a late run or GitHub's "Re-run jobs" has it: the
# checkout is that commit and origin's main is wherever it is now. Moves TAGGED when the run tags.
run_at() {
  git -C "$REPO" fetch -q origin
  git -C "$REPO" checkout -q --detach "${COMMIT[$1]}"
  printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)" > "$STATE/digest"
  rm -f "$RECORD/calls"
  publish
  MOVED=0
  if [[ -e $RECORD/calls ]] && grep -q '^flux tag ' "$RECORD/calls"; then
    TAGGED=$1 MOVED=1
  fi
}

# every_run N C_PATH [passes]: a history in which B passes and C changes C_PATH, and at each state of
# main (A alone, then B, then C arrived) a run for every commit that exists. A run's outcome depends
# on its commit and on what main holds, and on nothing else, so these runs cover every order that
# runs and re-runs can come in. A run must tag exactly when its commit is the newest on main and its
# tree passes: with that, a run for an older commit never tags once a newer one has arrived, so the
# tag cannot go back.
every_run() {
  local latest name expect
  world "$1"
  for latest in A B C; do
    case $latest in
      B) arrive B kubernetes/apps/base/demo/hello/app/configmap.yaml ;;
      C) arrive C "$2" ;;
    esac
    for name in A B C; do
      [[ -n ${COMMIT[$name]:-} && $name < "$latest" || $name == "$latest" ]] || continue
      run_at "$name"
      expect=0
      [[ $name == "$latest" && ( $name != C || ${3-} == passes ) ]] && expect=1
      [ "$MOVED" -eq "$expect" ] || { echo "the run for $name with $latest the newest: tag moved $MOVED, want $expect"; return 1; }
    done
  done
}

# replay NAME=PATH... -- EVENT...: arrivals are +NAME, which commits a change to NAME's PATH on
# main, and runs are rNAME. Fails when a run moves the tag from an artifact to an older one, older
# meaning that its commit arrived earlier.
replay() {
  local -A path=()
  local event name before order=ABC
  while [[ $1 != -- ]]; do
    path[${1%%=*}]=${1#*=}
    shift
  done
  shift
  for event; do
    name=${event:1}
    before=$TAGGED
    case $event in
      +*) arrive "$name" "${path[$name]}" ;;
      r*) run_at "$name" ;;
    esac
    if [[ -n $before && $TAGGED != "$before" && ${order%%"$before"*} == *"$TAGGED"* ]]; then
      echo "after $event the tag went from $before back to $TAGGED"
      return 1
    fi
  done
}

@test "The tag only ever moves forward, in every order of runs and re-runs, when the newest commit fails the check" {
  local passes=kubernetes/apps/base/demo/hello/app/configmap.yaml fails=kubernetes/breaks-the-check

  every_run 0 "$fails"

  # Runs as commits arrive, then old runs again: the tag ends on B, the last commit that passed.
  world 1
  replay B=$passes C=$fails -- rA +B rB +C rC rA rB rC
  [ "$TAGGED" = B ]
  # B's run came after C arrived, and C's run before it ran: no run tags, the tag stays on A.
  world 2
  replay B=$passes C=$fails -- rA +B +C rB rC rA rB
  [ "$TAGGED" = A ]
  # Both arrive before A's run, and the runs come newest first: nothing moves the tag.
  world 3
  replay B=$passes C=$fails -- +B +C rC rB rA
  [ -z "$TAGGED" ]
}

@test "The tag only ever moves forward, in every order of runs and re-runs, when every commit passes" {
  local passes=kubernetes/apps/base/demo/hello/app/configmap.yaml

  every_run 0 "$passes" passes

  world 1
  replay B=$passes C=$passes -- rA +B +C rB rC rA rB rC
  [ "$TAGGED" = C ]
  world 2
  replay B=$passes C=$passes -- +B rA rB +C rC rB rA rC
  [ "$TAGGED" = C ]
  world 3
  replay B=$passes C=$passes -- +B +C rC rB rA rC
  [ "$TAGGED" = C ]
}

@test "A failing check publishes nothing, moves no tag and fails the run with the check's reason" {
  local ref
  : > "$STATE/check-fails"
  for ref in refs/heads/main refs/heads/feature/next; do
    with GITHUB_REF="$ref"
    rm -f "$RECORD/calls"

    publish

    [ "$status" -ne 0 ] || { echo "published on $ref"; return 1; }
    [[ $output == *"a rule of the layout is broken"* ]]
    [[ $output == *"failed while checking"* ]]
    [[ $output != *"tag main moved"* ]]
    run flow
    [ "$output" = kubernetes-check ] || { echo "ran more than the check on $ref: $output"; return 1; }
  done
}

@test "A failed verification leaves the tag alone and fails the run" {
  : > "$STATE/verify-fails"

  publish

  [ "$status" -ne 0 ]
  [[ $output == *"failed while verifying $DIGEST"* ]]
  [[ $output != *"tag main moved"* ]]
  run steps
  [ "$output" = "$(step_list 'docker login' 'flux push' 'cosign sign' 'cosign verify')" ]
}

@test "A digest that is not a sha256 digest stops the run before anything is signed" {
  local hex=${DIGEST#sha256:} digest
  # As they would stand in the JSON flux prints: the backslash-n is a newline in the digest.
  local -a digests=(
    ''
    latest
    null
    "$hex"
    "sha256:${hex:1}"
    "sha256:${hex}0"
    "sha256:${hex^^}"
    "sha512:$hex"
    "sha256:$hex "
    "sha256:$hex\\nsha256:$hex"
  )
  for digest in "${digests[@]}"; do
    printf '%s' "$digest" > "$STATE/digest"
    rm -f "$RECORD/calls"

    publish

    [ "$status" -ne 0 ] || { echo "accepted the digest $digest"; return 1; }
    run steps
    [ "$output" = "$(step_list 'docker login' 'flux push')" ] || { echo "with the digest $digest"; return 1; }
  done
}

@test "Nobody publishes from outside the workflow" {
  local -a base=("${ENVIRONMENT[@]}")
  local name
  # A laptop: none of what Actions sets, even with a token at hand.
  without GITHUB_ACTIONS
  without ACTIONS_ID_TOKEN_REQUEST_URL
  without ACTIONS_ID_TOKEN_REQUEST_TOKEN
  publish
  [ "$status" -ne 0 ]
  [[ $output == *refusing* ]]
  [ ! -e "$RECORD/calls" ]

  # Actions, but a job without an identity token, or something that only claims the identity token.
  for name in GITHUB_ACTIONS ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN GITHUB_ACTIONS=false; do
    ENVIRONMENT=("${base[@]}")
    if [[ $name == *=* ]]; then
      with "$name"
    else
      without "$name"
    fi

    publish

    [ "$status" -ne 0 ] || { echo "published without $name"; return 1; }
    [[ $output == *refusing* ]]
    [ ! -e "$RECORD/calls" ] || { echo "called something without $name"; return 1; }
  done
}

@test "The registry token reaches no command line and no output" {
  publish

  [ "$status" -eq 0 ]
  [[ $output != *"$TOKEN"* ]]
  [ "$(cat "$RECORD/docker-login.stdin")" = "$TOKEN" ]
  run argv 'docker login'
  grep -qxF -- --password-stdin <<< "$output"
  run grep -F -- "$TOKEN" "$RECORD/calls"
  [ "$status" -eq 1 ]
  # flux and cosign get no credentials of their own: they read the login docker wrote.
  run grep -E -- '--(creds|registry-username|registry-password|registry-token)( |=|$)' "$RECORD/calls"
  [ "$status" -eq 1 ]
  run sort -u "$RECORD/docker-config.docker" "$RECORD/docker-config.flux" "$RECORD/docker-config.cosign"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ $output != *$'\n'* ]] || { echo "docker, flux and cosign read different Docker configurations"; return 1; }
  [ ! -e "$output" ] || { echo "the Docker configuration with the login is left after the run"; return 1; }
}

@test "The artifact holds only what is under kubernetes/" {
  local cluster entry
  for cluster in "$REPO"/kubernetes/clusters/*/; do
    mkdir -p "$cluster/secrets"
    printf 'stand-in: applied before Flux starts\n' > "$cluster/secrets/cluster-secrets.sops.yaml"
  done
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=test -c user.email=test@example.invalid commit -q -m "add stand-in secrets"

  publish

  [ "$status" -eq 0 ]
  # Files only, at their paths below kubernetes/.
  run tar -tzvf "$STATE/artifact.tgz"
  [ "$status" -eq 0 ]
  awk '$1 ~ /^-/ { print $NF }' <<< "$output" | sort > "$BATS_TEST_TMPDIR/listed"
  git -C "$REPO" ls-files kubernetes | sed 's|^kubernetes/||' | grep -Ev '^clusters/[^/]+/secrets/' |
    sort > "$BATS_TEST_TMPDIR/expected"
  [ -s "$BATS_TEST_TMPDIR/listed" ]
  diff "$BATS_TEST_TMPDIR/expected" "$BATS_TEST_TMPDIR/listed"
  # And every entry, directories included, is something under kubernetes/.
  run tar -tzf "$STATE/artifact.tgz"
  while IFS= read -r entry; do
    [ -e "$REPO/kubernetes/$entry" ] || { echo "not under kubernetes/: $entry"; return 1; }
    [[ ! $entry =~ ^(\./)?clusters/[^/]+/secrets(/|$) ]] || { echo "a cluster's secrets: $entry"; return 1; }
    case ${entry##*/} in
      *.agekey | age.txt | *.key | *.pem | kubeconfig | talosconfig | .env | .env.* | talman.yaml | clouds.yaml | secure.yaml | *.tfstate | *.tfvars)
        echo "named like key material or credentials: $entry"
        return 1
        ;;
    esac
  done <<< "$output"
}

@test "The verification accepts exactly the identity Flux is configured to accept" {
  local values patch identities issuer subject workflow

  publish

  [ "$status" -eq 0 ]
  run argv 'cosign verify'
  [ "$status" -eq 0 ]
  local args=$output
  # Nothing loosens what a keyless verification checks.
  run grep -xE -- '--(key|insecure-ignore-tlog|insecure-ignore-sct|certificate-chain|trusted-root|allow-insecure-registry|allow-http-registry)' <<< "$args"
  [ "$status" -eq 1 ]
  for values in "${VALUES[@]}"; do
    patch=$(yq '.instance.kustomize.patches[] | select(.target.kind == "OCIRepository" and .target.name == "flux-system") | .patch' "$values")
    identities=$(yq -o=json -I=0 '.[] | select(.path == "/spec/verify") | .value.matchOIDCIdentity' <<< "$patch")
    [ "$(yq 'length' <<< "$identities")" -eq 1 ]
    issuer=$(yq '.[0].issuer' <<< "$identities")
    subject=$(yq '.[0].subject' <<< "$identities")
    accepts --certificate-oidc-issuer "$issuer" <<< "$args"
    accepts --certificate-identity "$subject" <<< "$args"
  done
  # The subject is a workflow file of this repository on main, and that file runs this recipe.
  subject=$(literal "$subject")
  [[ $subject =~ ^https://github\.com/[^/]+/[^/]+/(\.github/workflows/[^/@]+)@refs/heads/main$ ]]
  workflow="$ROOT/${BASH_REMATCH[1]}"
  [ -f "$workflow" ]
  run yq -o=json -I=0 '[.jobs[].steps[] | select(has("run")) | .run]' "$workflow"
  [ "$output" = '["just publish"]' ]
}

@test "the push names the commit, the repository it came from and the revision of the run's branch" {
  local repository=${SYNC_URL#oci://}

  publish

  [ "$status" -eq 0 ]
  run argv 'flux push'
  [ "$status" -eq 0 ]
  grep -qxF -- "oci://$repository:$SHA" <<< "$output"
  grep -qxF -- --reproducible <<< "$output"
  [ "$(value --source <<< "$output")" = https://github.com/eekaan/k8s-gitops ]
  [ "$(value --revision <<< "$output")" = "main@sha1:$SHA" ]

  with GITHUB_REF=refs/heads/feature/next
  rm "$RECORD/calls"
  publish
  [ "$status" -eq 0 ]
  run argv 'flux push'
  [ "$(value --revision <<< "$output")" = "feature/next@sha1:$SHA" ]
}
