#!/usr/bin/env bats
# Proves features/tools-image.feature; each test that proves a scenario carries its title, and those
# named in lower case prove none.
# The recipes run in a copy of the repository: a git repository on main holding, committed, what git
# would commit from this one. For just tools-image-publish and just tools-image-pin, docker, dagger
# and cosign are recording fakes, so nothing logs in, builds, pushes or signs; the fake cosign keeps
# the signatures a test gives it or the fake sign makes, and verifies against them as cosign does:
# the identity, the issuer, the workflow's repository and every annotation asked for. It looks for
# registry credentials where cosign's default keychain does, and records where it found them. For
# just ci without a container, dagger is a fake that records its arguments. kubectl, openstack, gh
# and talosctl are fakes that fail, so a call to any of them shows. The tests tagged hermetic run the
# real just ci and serve a tools image from a registry of their own in the network of the engine the
# pinned dagger starts in Docker, under a name their checkout's scripts/tools-image is changed to
# accept; they push nothing anywhere else.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  JUST=$(command -v just)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$BIN" "$RECORD" "$STATE/signatures" "$STATE/tags" "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/tmp"
  IMAGE=ghcr.io/eekaan/k8s-gitops/ci-tools
  WORKFLOW="$ROOT/.github/workflows/tools-image.yaml"
  IDENTITY=https://github.com/eekaan/k8s-gitops/.github/workflows/tools-image.yaml@refs/heads/main
  ISSUER=https://token.actions.githubusercontent.com
  # What the fake push reports as the pushed image's digest.
  DIGEST="sha256:$(printf 'pushed tools image' | sha256sum | cut -d' ' -f1)"
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
    GITHUB_REPOSITORY=eekaan/k8s-gitops
    GITHUB_WORKFLOW_REF=eekaan/k8s-gitops/.github/workflows/tools-image.yaml@refs/heads/main
    # A host that never resolves: even a real cosign would get no identity token from it.
    ACTIONS_ID_TOKEN_REQUEST_URL=https://token.example.invalid/request
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=example-request-token
    REGISTRY_TOKEN="$TOKEN"
  )
  fakes
}

teardown() {
  if [[ -n ${REGISTRY-} ]]; then
    docker stop "$REGISTRY" > /dev/null 2>&1 || true
  fi
  # Nothing reaches a cluster, a cloud or GitHub's API.
  if [[ -e $RECORD/calls ]] && grep -E '^(kubectl|openstack|gh|talosctl) ' "$RECORD/calls"; then
    return 1
  fi
}

# checkout: a throwaway repository holding, committed, what git would commit from this one, in WORK,
# so a run sees changes not yet committed here and never writes to this checkout.
checkout() {
  local path
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
  while IFS= read -r -d '' path; do
    # A file deleted here but still in the index has nothing to copy.
    [[ -e $ROOT/$path || -L $ROOT/$path ]] || continue
    mkdir -p -- "$WORK/$(dirname -- "$path")"
    cp -pP -- "$ROOT/$path" "$WORK/$path"
  done < <(git -C "$ROOT" ls-files -z --cached --others --exclude-standard)
  git -C "$WORK" init -q -b main
  commit "checkout under test"
}

# commit MESSAGE: commits everything in the checkout with MESSAGE.
commit() {
  git -C "$WORK" add -A
  git -C "$WORK" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m "$1"
}

# stub NAME: a binary first on the run's PATH, its body read from stdin.
stub() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# fake NAME: a stub that first records its call in RECORD/calls, one line of its name and its
# arguments quoted as printf %q quotes them, and its name in RECORD/token-in-environment when the
# registry token is in its environment; RECORD and STATE are set for its body.
fake() {
  {
    printf 'RECORD=%q STATE=%q\n' "$RECORD" "$STATE"
    cat <<'EOF'
{ printf '%q ' "${0##*/}" "$@"; echo; } >> "$RECORD/calls"
[[ -z ${REGISTRY_TOKEN-} ]] || echo "${0##*/}" >> "$RECORD/token-in-environment"
EOF
    cat
  } | stub "$1"
}

# fakes: the stand-ins on the run's PATH.
fakes() {
  local tool
  # A mise with nothing installed keeps the justfile from putting the real tools in front of these.
  stub mise < /dev/null
  for tool in kubectl openstack gh talosctl; do
    fake "$tool" <<'EOF'
echo "fake ${0##*/}: never called by a tools image run" >&2
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
  # A publish answers as the pinned dagger does: the address it pushed to, with the digest in
  # STATE/digest; the tag then names that digest. Any other call only records its arguments, one per
  # line, in RECORD/dagger.args, as just ci makes it.
  fake dagger <<'EOF'
printf '%s\n' "${DOCKER_CONFIG:-$HOME/.docker}" >> "$RECORD/docker-config.dagger"
printf '%s\n' "$@" > "$RECORD/dagger.args"
address= previous= publish=0
for arg; do
  case $arg in
    publish) publish=1 ;;
    --address=*) address=${arg#*=} ;;
  esac
  [[ $previous != --address ]] || address=$arg
  previous=$arg
done
if ((publish)); then
  [[ -n $address ]] || { echo "fake dagger: publish without an address" >&2; exit 1; }
  digest=$(cat "$STATE/digest")
  printf '%s' "$digest" > "$STATE/tags/${address##*:}"
  printf '%s@%s\n' "$address" "$digest"
fi
EOF
  # cosign looks for registry credentials as its default keychain does: in the Docker configuration
  # when $HOME/.docker/config.json or $DOCKER_CONFIG/config.json exists, and otherwise in
  # $REGISTRY_AUTH_FILE or podman's containers/auth.json; it records the file it read, or anonymous.
  # A keyless signature carries the identity of the job's workflow and the run's repository, as
  # GitHub's token names them. A lookup of a tag fails with the text of STATE/lookup-fails while it
  # exists; verify fails while STATE/verify-fails exists, and otherwise passes only for a signature
  # of the digest named, or of the one a tag names, with the identity, issuer and repository asked
  # for and every annotation asked for.
  fake cosign <<'EOF'
config=${DOCKER_CONFIG:-$HOME/.docker}
printf '%s\n' "$config" >> "$RECORD/docker-config.cosign"
found=
if [[ -f $HOME/.docker/config.json || ( -n ${DOCKER_CONFIG-} && -f $DOCKER_CONFIG/config.json ) ]]; then
  found=$config/config.json
elif [[ -n ${REGISTRY_AUTH_FILE-} && -f $REGISTRY_AUTH_FILE ]]; then
  found=$REGISTRY_AUTH_FILE
else
  podman=${XDG_RUNTIME_DIR-}/containers/auth.json
  if [[ -z ${XDG_RUNTIME_DIR-} || ! -f $podman ]]; then
    podman=${XDG_CONFIG_HOME:-$HOME/.config}/containers/auth.json
  fi
  [[ ! -f $podman ]] || found=$podman
fi
if [[ -n $found ]] && grep -q '"auth"' "$found" 2> /dev/null; then
  echo "${1-} with credentials from $found" >> "$RECORD/cosign-credentials"
else
  echo "${1-} anonymous" >> "$RECORD/cosign-credentials"
fi
command=${1-}
shift || true
identity= issuer= repository= ref=
annotations=()
while (($#)); do
  case $1 in
    --certificate-identity) identity=$2; shift ;;
    --certificate-identity=*) identity=${1#*=} ;;
    --certificate-oidc-issuer) issuer=$2; shift ;;
    --certificate-oidc-issuer=*) issuer=${1#*=} ;;
    --certificate-github-workflow-repository) repository=$2; shift ;;
    --certificate-github-workflow-repository=*) repository=${1#*=} ;;
    -a | --annotations) annotations+=("$2"); shift ;;
    --annotations=*) annotations+=("${1#*=}") ;;
    --oidc-provider | --output | --output-file | -o) shift ;;
    -*) ;;
    *) ref=$1 ;;
  esac
  shift
done
if [[ $ref == *@* ]]; then
  digest=${ref##*@}
elif [[ -e $STATE/lookup-fails ]]; then
  cat "$STATE/lookup-fails" >&2
  exit 1
elif ! digest=$(cat "$STATE/tags/${ref##*:}" 2> /dev/null); then
  echo "Error: GET ${ref%%/*}: MANIFEST_UNKNOWN: manifest unknown" >&2
  exit 1
fi
case $command in
  sign)
    { printf 'identity=https://github.com/%s\nissuer=https://token.actions.githubusercontent.com\nrepository=%s\n' \
        "$GITHUB_WORKFLOW_REF" "$GITHUB_REPOSITORY"
      printf 'annotation=%s\n' "${annotations[@]}"; } > "$STATE/signatures/$digest"
    ;;
  verify)
    signature=$STATE/signatures/$digest
    if [[ -e $STATE/verify-fails || ! -e $signature ]]; then
      echo "Error: no signatures found" >&2
      exit 1
    fi
    if ! grep -qxF "identity=$identity" "$signature" || ! grep -qxF "issuer=$issuer" "$signature"; then
      echo "Error: no matching signatures: none of the expected identities matched" >&2
      exit 1
    fi
    if [[ -n $repository ]] && ! grep -qxF "repository=$repository" "$signature"; then
      echo "Error: no matching signatures: expected GitHub Workflow Repository not found in certificate" >&2
      exit 1
    fi
    for annotation in "${annotations[@]}"; do
      if ! grep -qxF -- "annotation=$annotation" "$signature"; then
        echo "Error: no matching attestations: missing or incorrect annotation" >&2
        exit 1
      fi
    done
    printf '[{"critical":{"identity":{"docker-reference":"%s"},"image":{"docker-manifest-digest":"%s"},"type":"https://sigstore.dev/cosign/sign/v1"},"optional":{}}]\n' "${ref%@*}" "$digest"
    ;;
  *) echo "fake cosign: unexpected call" >&2; exit 1 ;;
esac
EOF
}

# signed DIGEST IDENTITY KEY [REPOSITORY]: a signature of DIGEST, as cosign would find one, by IDENTITY
# from GitHub's token issuer, in a run of REPOSITORY, this one unless given, with KEY as its tools-key
# annotation.
signed() {
  printf 'identity=%s\nissuer=%s\nrepository=%s\nannotation=tools-key=%s\n' "$2" "$ISSUER" "${4:-eekaan/k8s-gitops}" "$3" \
    > "$STATE/signatures/$1"
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

# recipe NAME ARGS...: runs just NAME in the checkout with only ENVIRONMENT set and the fakes first on
# PATH; stdout in output, stderr in stderr. A run that blocks fails after two minutes.
recipe() {
  bats_require_minimum_version 1.5.0
  run --separate-stderr timeout 120 env -i PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$WORK/justfile" --working-directory "$WORK" "$@"
  printf '%s\n' "$output" "$stderr"
}

# key_of DIRECTORY: the key just tools-image-key prints for the checkout in DIRECTORY.
key_of() {
  env PATH="$BIN:$PATH" "$JUST" --justfile "$1/justfile" --working-directory "$1" tools-image-key
}

# record KEY IMAGE: versions.yaml in the checkout records IMAGE for KEY, as just tools-image-pin writes
# them, or no image when both are empty.
record() {
  sed -i -E -e "s|^ci_tools_inputs:.*$|ci_tools_inputs: ${1:-\"\"}|" -e "s|^ci_tools_image:.*$|ci_tools_image: ${2:-\"\"}|" "$WORK/versions.yaml"
  [ "$(yq '.ci_tools_inputs' "$WORK/versions.yaml")" = "$1" ]
  [ "$(yq '.ci_tools_image' "$WORK/versions.yaml")" = "$2" ]
}

# change INPUT: changes one input of the tools in the checkout: pin (a tool's version in mise.toml),
# base (the base image's digest), packages (the package step) or layer (a step of the module's
# toolsLayer); fails unless the file changed.
change() {
  local file before
  case $1 in
    pin) file=mise.toml ;;
    base | packages) file=versions.yaml ;;
    layer) file=.dagger/modules/ci/main.dang ;;
  esac
  before=$(cat "$WORK/$file")
  case $1 in
    pin) sed -i -E 's/^jq = "[^"]+"/jq = "0.0.1"/' "$WORK/$file" ;;
    base) sed -i -E "s/^(ci_tools_base: [^@]+@sha256:)[0-9a-f]{64}$/\\1$(printf 'other base' | sha256sum | cut -d' ' -f1)/" "$WORK/$file" ;;
    packages) sed -i -E 's/^(ci_tools_packages: .*)pipx/\1pipx ca-certificates/' "$WORK/$file" ;;
    layer) sed -i -E 's/^( *)\.withExec\(\["mise", "install"\]\)$/\1.withEnvVariable("MISE_JOBS", "1")\n&/' "$WORK/$file" ;;
  esac
  [ "$(cat "$WORK/$file")" != "$before" ] || { echo "the change of $1 changed nothing in $file"; return 1; }
}

# fake_ci: runs the checkout's just ci with the fake dagger and none of the pinned tools on PATH, as
# a CI job's host has them.
fake_ci() {
  rm -f "$RECORD/dagger.args"
  bats_require_minimum_version 1.5.0
  run --separate-stderr env PATH="$BIN:/usr/bin:/bin" "$JUST" --justfile "$WORK/justfile" --working-directory "$WORK" ci
  printf '%s\n' "$output" "$stderr"
}

# handed NAME: the value of the one --NAME=VALUE argument dagger was given; fails unless there is
# exactly one.
handed() {
  local values
  values=$(sed -n "s/^--$1=//p" "$RECORD/dagger.args")
  [[ $(grep -c "^--$1=" "$RECORD/dagger.args") -eq 1 ]] || { echo "--$1 given $(grep -c "^--$1=" "$RECORD/dagger.args") times" >&2; return 1; }
  printf '%s' "$values"
}

# steps: the recorded calls to docker, dagger and cosign, in order, as the tool and its subcommand.
steps() {
  [[ -e $RECORD/calls ]] || return 0
  awk '$1 == "docker" || $1 == "dagger" || $1 == "cosign" { print $1, $2 }' "$RECORD/calls"
}

# step_list STEP...: STEPs one per line, as steps prints them.
step_list() {
  printf '%s\n' "$@"
}

# calls_of CALL: the arguments of each recorded call that starts with CALL (a tool and its
# subcommand), one call per line, as recorded.
calls_of() {
  grep -E -- "^$1 " "$RECORD/calls" || true
}

# argv LINE: the arguments of one recorded call, one per line, each --flag=value split into the flag
# and its value.
argv() {
  local arg
  local -a args
  eval "args=($1)"
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

# values FLAG: every value given to FLAG in the arguments on stdin, one per line.
values() {
  awk -v flag="$1" 'found { print; found = 0; next } $0 == flag { found = 1 }'
}

# The pinned registry the hermetic tests serve a tools image from: Distribution 3.1.1.
REGISTRY_IMAGE=registry@sha256:325b4b29b041e82803abeb703e201655e4e23ab83264ec1a7c9ddb0a5b14a6e0

# run_ci [GROUP]: runs the checkout's just ci, for GROUP alone when given, with none of the pinned
# tools on PATH, so only a container can run the checks.
run_ci() {
  local bin="$BATS_TEST_TMPDIR/hermetic-bin"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\n' > "$bin/mise"
  chmod +x "$bin/mise"
  ln -sf "$(command -v docker)" "$bin/docker"
  ln -sf "$(command -v dagger)" "$bin/dagger"
  run env PATH="$bin:/usr/bin:/bin" "$JUST" --justfile "$WORK/justfile" --working-directory "$WORK" ci "$@"
}

# registry: starts a registry that listens on the loopback address of the engine the pinned dagger
# starts in Docker, which reaches it there as a registry on localhost, over HTTP, and makes the
# checkout's scripts/tools-image take SERVED/ci-tools for this repository's tools image, as just ci
# accepts no other. Sets REGISTRY to the container, which teardown stops, and SERVED to the address
# images are served from.
registry() {
  local version engine port
  if [[ -n ${DAGGER_ENGINE-}${_EXPERIMENTAL_DAGGER_RUNNER_HOST-} ]]; then
    echo "the stand-in registry joins the engine container the dagger CLI starts in Docker; unset DAGGER_ENGINE" >&2
    return 1
  fi
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  # Any call starts the engine; outside a workspace no module loads.
  (cd "$BATS_TEST_TMPDIR/empty" && dagger -c 'default-platform' > "$BATS_TEST_TMPDIR/engine-platform")
  version=$(dagger version | awk '$1 == "version:" { print $2 }')
  engine=dagger-engine-$version
  [ "$(docker inspect --format '{{.State.Running}}' "$engine")" = true ]
  port=$((20000 + RANDOM % 20000))
  REGISTRY=tools-image-stand-in-$$-$BATS_TEST_NUMBER
  docker run -d --rm --name "$REGISTRY" --network "container:$engine" \
    -e REGISTRY_HTTP_ADDR="127.0.0.1:$port" -e REGISTRY_HTTP_DEBUG_ADDR="127.0.0.1:$((port + 1))" \
    "$REGISTRY_IMAGE" > /dev/null
  for _ in {1..50}; do
    if docker logs "$REGISTRY" 2>&1 | grep -q 'listening on'; then
      SERVED=localhost:$port
      sed -i "s|^image=.*$|image=$SERVED/ci-tools|" "$WORK/scripts/tools-image"
      grep -qxF "image=$SERVED/ci-tools" "$WORK/scripts/tools-image"
      return 0
    fi
    sleep 0.2
  done
  docker logs "$REGISTRY" >&2
  return 1
}

# stand_in [FILE]: serves the checkout's tools, as just tools-image-publish builds them, from the
# registry under a tag other than the key, so that only its digest finds it; with FILE, a file of
# that name is added at /. Records it by digest in the checkout's versions.yaml with the checkout's
# key, commits, and sets STAND_IN to it.
stand_in() {
  local -a chain
  local pushed
  registry
  chain=(ci tools-layer --base="$(yq '.ci_tools_base' "$WORK/versions.yaml")" --packages="$(yq '.ci_tools_packages' "$WORK/versions.yaml")")
  if (($#)); then
    chain+=(with-new-file --path="/$1" --contents="$1")
  fi
  pushed=$(cd "$WORK" && dagger api call --progress=plain "${chain[@]}" publish --address="$SERVED/ci-tools:stand-in")
  [[ $pushed =~ ^$SERVED/ci-tools:stand-in@(sha256:[0-9a-f]{64})$ ]]
  STAND_IN=$SERVED/ci-tools@${BASH_REMATCH[1]}
  record "$(key_of "$WORK")" "$STAND_IN"
  commit "record the stand-in"
}

# verdicts: the groups' verdicts and the checks each ran, the recipes that failed, and the summary,
# in the output.
verdicts() {
  # shellcheck disable=SC2016 # just's backticks, as it prints them
  grep -oE '== [a-z0-9-]+: (passed|failed) \([^)]*\)|recipe `[a-z0-9-]+` failed|(failed|passed): [a-z0-9 -]+$' <<< "$output" | sort -u
}

@test "The key changes when a pinned tool, the base image, the package step or a step of the tools layer changes, and not otherwise" {
  local key input variant
  checkout
  key=$(key_of "$WORK")
  [[ $key =~ ^[0-9a-f]{64}$ ]]
  # The same inputs give the same key, wherever the checkout is.
  [ "$(key_of "$WORK")" = "$key" ]
  cp -R "$WORK" "$BATS_TEST_TMPDIR/elsewhere"
  [ "$(key_of "$BATS_TEST_TMPDIR/elsewhere")" = "$key" ]
  local pristine="$BATS_TEST_TMPDIR/pristine"
  cp -R "$WORK" "$pristine"

  local -a keys=("$key")
  for input in pin base packages layer; do
    rm -rf "$WORK"
    cp -R "$pristine" "$WORK"
    change "$input"
    variant=$(key_of "$WORK")
    [[ $variant =~ ^[0-9a-f]{64}$ ]]
    [ "$variant" != "$key" ] || { echo "the key did not change with $input"; return 1; }
    keys+=("$variant")
  done
  # Each input changes it its own way.
  [ "$(printf '%s\n' "${keys[@]}" | sort -u | wc -l)" -eq 5 ]

  # Nothing else does: another line of versions.yaml, the recorded image and its key among them, the
  # module outside its tools layer, the justfile, the docs, the comments around the inputs, or a new
  # file.
  rm -rf "$WORK"
  cp -R "$pristine" "$WORK"
  sed -i -E 's/^talos: .*/talos: v0.0.1/' "$WORK/versions.yaml"
  record "$(printf 'other inputs' | sha256sum | cut -d' ' -f1)" "$IMAGE@$DIGEST"
  sed -i '1a # a comment that is not an input' "$WORK/versions.yaml"
  printf '\n# a comment\n' >> "$WORK/.dagger/modules/ci/main.dang"
  sed -i 's/Run the justfile.s groups of checks side by side/Run the groups of checks side by side/' "$WORK/.dagger/modules/ci/main.dang"
  sed -i 's/^  The tools pinned in mise.toml/  The tools mise.toml pins/' "$WORK/.dagger/modules/ci/main.dang"
  run diff "$pristine/.dagger/modules/ci/main.dang" "$WORK/.dagger/modules/ci/main.dang"
  [ "$(grep -c '^>' <<< "$output")" -eq 4 ]
  printf '\n# a comment\n' >> "$WORK/justfile"
  printf '\nmore words\n' >> "$WORK/README.md"
  printf 'new\n' > "$WORK/new-file"
  run diff -rq "$pristine" "$WORK"
  [ "$status" -ne 0 ]
  [ "$(key_of "$WORK")" = "$key" ]
}

@test "With changed inputs, the recorded image is not used and the tools are built from the pins" {
  local input
  checkout
  record "$(key_of "$WORK")" "$IMAGE@$DIGEST"
  commit "record an image for these inputs"
  local pristine="$BATS_TEST_TMPDIR/pristine"
  cp -R "$WORK" "$pristine"
  # With the inputs it was recorded for, the module is handed the recorded image, by its digest.
  fake_ci
  [ "$status" -eq 0 ]
  [ "$(handed tools-image)" = "$IMAGE@$DIGEST" ]
  [[ $stderr == *"$IMAGE@$DIGEST"* ]]

  for input in pin base packages layer; do
    rm -rf "$WORK"
    cp -R "$pristine" "$WORK"
    change "$input"
    commit "change $input"

    fake_ci

    [ "$status" -eq 0 ]
    if grep -q '^--tools-image' "$RECORD/dagger.args"; then
      echo "handed the recorded image after a change of $input"
      return 1
    fi
    # The module builds from the changed inputs, as YAML reads them.
    [ "$(handed tools-base)" = "$(yq '.ci_tools_base' "$WORK/versions.yaml")" ]
    [ "$(handed tools-packages)" = "$(yq '.ci_tools_packages' "$WORK/versions.yaml")" ]
    [[ $stderr == *"built from the pins"*"other inputs"* ]]
  done

  # And without a recorded image, it builds from the pins too.
  rm -rf "$WORK"
  cp -R "$pristine" "$WORK"
  record '' ''
  fake_ci
  [ "$status" -eq 0 ]
  [[ $stderr == *"built from the pins"*"no tools image"* ]]
  run grep -c '^--tools-image' "$RECORD/dagger.args"
  [ "$output" = 0 ]
}

@test "just ci refuses a recorded image other than this repository's tools image by its digest, and a record that is not whole" {
  local key bad
  checkout
  key=$(key_of "$WORK")
  local pristine="$BATS_TEST_TMPDIR/pristine"
  cp -R "$WORK" "$pristine"
  # A merged record is what every later run on main executes in, the self-hosted runner's among them:
  # only the image this repository's workflow publishes, by its digest, with the key it was built for.
  local -a records=(
    "$key|$IMAGE:$key"
    "$key|$IMAGE"
    "$key|$IMAGE:$key@$DIGEST"
    "$key|$IMAGE@sha256:${DIGEST:7:63}"
    "$key|$IMAGE@sha256:$(tr a-f A-F <<< "${DIGEST#sha256:}")"
    "$key|evil.example/eekaan/k8s-gitops/ci-tools@$DIGEST"
    "$key|ghcr.io/eekaan-k8s/k8s-gitops/ci-tools@$DIGEST"
    "$key|$IMAGE/extra@$DIGEST"
    "$key|${IMAGE}2@$DIGEST"
    "$key|ghcr.io/eekaan/k8s-gitops/manifests@$DIGEST"
    "$key|docker.io/library/busybox@$DIGEST"
    "$key|localhost:5000/ci-tools@$DIGEST"
    "${key:1}|$IMAGE@$DIGEST"
    '""|'"$IMAGE@$DIGEST"
    "$key|\"\""
  )
  for bad in "${records[@]}"; do
    rm -rf "$WORK"
    cp -R "$pristine" "$WORK"
    sed -i -E -e "s|^ci_tools_inputs:.*$|ci_tools_inputs: ${bad%%|*}|" -e "s|^ci_tools_image:.*$|ci_tools_image: ${bad#*|}|" "$WORK/versions.yaml"

    fake_ci

    [ "$status" -ne 0 ] || { echo "accepted the record $bad"; return 1; }
    [ ! -e "$RECORD/dagger.args" ] || { echo "called dagger with the record $bad"; return 1; }
    [[ $stderr == *versions.yaml* ]]
  done
}

@test "just ci refuses a versions.yaml it would read otherwise than YAML does, and a module without one tools layer" {
  local form
  checkout
  local pristine="$BATS_TEST_TMPDIR/pristine"
  cp -R "$WORK" "$pristine"
  # Each form, as an awk program that rewrites versions.yaml: YAML reads a tab before # as a
  # comment, and an indented line under a value as more of it.
  # shellcheck disable=SC2016 # awk programs, as awk reads them
  local -a forms=(
    '/^ci_tools_base: / { $0 = $0 "\t# a note" } 1'
    '/^ci_tools_packages: / { $0 = $0 "\t# a note" } 1'
    '/^ci_tools_packages: / { sub(/pipx/, "pipx\tcurl") } 1'
    '/^ci_tools_packages: / { print; print "  && apt-get install -y curl"; next } 1'
    '/^ci_tools_packages: / { print; print ""; print "  && apt-get install -y curl"; next } 1'
    '/^ci_tools_base: / { print; print "  -extra"; next } 1'
    '/^ci_tools_inputs: / { print; print "  more"; next } 1'
    '/^ci_tools_packages: / { $0 = $0 " # a note" } 1'
    '/^ci_tools_base: / { sub(/: /, ": \"") ; $0 = $0 "\"" } 1'
  )
  for form in "${forms[@]}"; do
    rm -rf "$WORK"
    cp -R "$pristine" "$WORK"
    awk "$form" "$pristine/versions.yaml" > "$WORK/versions.yaml"
    [ "$(cat "$WORK/versions.yaml")" != "$(cat "$pristine/versions.yaml")" ] || { echo "the form changed nothing: $form"; return 1; }

    fake_ci

    [ "$status" -ne 0 ] || { echo "read $form"; return 1; }
    [ ! -e "$RECORD/dagger.args" ] || { echo "called dagger with $form"; return 1; }
    [[ $stderr == *versions.yaml* ]]
  done

  # The tools layer is read from the module as the block its definition opens; without one, no key.
  rm -rf "$WORK"
  cp -R "$pristine" "$WORK"
  sed -i 's/^  pub toolsLayer(/  pub toolsContainer(/' "$WORK/.dagger/modules/ci/main.dang"
  fake_ci
  [ "$status" -ne 0 ]
  [ ! -e "$RECORD/dagger.args" ]
  [[ $stderr == *main.dang* ]]
}

@test "a recorded tools image passes the secrets scan" {
  checkout
  record "$(key_of "$WORK")" "$IMAGE@$DIGEST"
  commit "record a tools image"

  run env PATH="$BIN:$PATH" "$JUST" --justfile "$WORK/justfile" --working-directory "$WORK" secrets-scan

  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# bats test_tags=hermetic
@test "With a recorded image for the current inputs, the checks run in that image, by digest" {
  checkout
  # A group of the checkout's own whose one check passes only in the stand-in.
  sed -i 's/^checks:.*$/& in-stand-in/' "$WORK/justfile"
  printf '\nin-stand-in: stand-in-marker\n\nstand-in-marker:\n    test -e /tools-image-stand-in\n    echo "the checks ran in the stand-in"\n' >> "$WORK/justfile"
  stand_in tools-image-stand-in

  run_ci in-stand-in

  [ "$status" -eq 0 ]
  [[ $output == *"the checks ran in the stand-in"* ]]
  [[ $output == *"== in-stand-in: passed (stand-in-marker)"* ]]
  [[ $output == *"tools: $STAND_IN"* ]]
  # The engine asked the registry for the image by its digest; the tag it is served under is not the key.
  docker logs "$REGISTRY" 2>&1 | grep -q "/v2/ci-tools/manifests/${STAND_IN##*@}"
}

# bats test_tags=hermetic
@test "The checks give the same result in the recorded image as in the tools built from the pins" {
  local in_image built failing
  checkout
  mkdir "$WORK/config"
  cp "$BATS_TEST_DIRNAME/fixtures/check-address-literals/undeclared.txt" "$WORK/config/resolver.txt"
  commit "add a file that fails a check"
  stand_in

  run_ci

  [ "$status" -ne 0 ]
  [[ $output == *"tools: $STAND_IN"* ]]
  in_image=$(verdicts)
  [ "$(grep -c ': failed (' <<< "$in_image")" -eq 1 ]
  [ "$(grep -c ': passed (' <<< "$in_image")" -ge 1 ]
  # shellcheck disable=SC2016 # just's backticks, as it prints them
  [ "$(grep -c '^recipe `check-literals` failed$' <<< "$in_image")" -eq 1 ]
  failing=$(grep -oE '^== [a-z0-9-]+: failed' <<< "$in_image")

  # The same checkout, its record for other inputs, builds the tools from the pins.
  record "$(printf 'other inputs' | sha256sum | cut -d' ' -f1)" "$STAND_IN"
  commit "record the image for other inputs"

  run_ci

  [ "$status" -ne 0 ]
  [[ $output == *"tools: built from the pins"* ]]
  built=$(verdicts)
  [ "$built" = "$in_image" ]
  [[ $built == *"$failing"* ]]
}

# bats test_tags=hermetic
@test "a recorded image for another platform than the engine's is not used" {
  local platform other pushed
  checkout
  sed -i 's/^checks:.*$/& literals-only/' "$WORK/justfile"
  printf '\nliterals-only: check-literals\n' >> "$WORK/justfile"
  registry
  platform=$(cat "$BATS_TEST_TMPDIR/engine-platform")
  case $platform in
    linux/amd64) other=linux/arm64 ;;
    *) other=linux/amd64 ;;
  esac
  pushed=$(cd "$BATS_TEST_TMPDIR/empty" && dagger --progress=plain -c "container --platform $other | with-new-file /other-platform other | publish $SERVED/ci-tools:other-platform")
  [[ $pushed =~ (sha256:[0-9a-f]{64})$ ]]
  record "$(key_of "$WORK")" "$SERVED/ci-tools@${BASH_REMATCH[1]}"
  commit "record an image for another platform"

  run_ci literals-only

  [ "$status" -eq 0 ]
  [[ $output == *"== literals-only: passed (check-literals)"* ]]
  [[ $output == *"tools: built from the pins"*"$other"* ]]
}

@test "The tools image is signed and verified before its digest is printed, and nothing is published outside the workflow" {
  local key name
  checkout
  key=$(key_of "$WORK")

  recipe tools-image-publish

  [ "$status" -eq 0 ]
  # The digest is the one line on standard output, printed last.
  [ "$output" = "$DIGEST" ]
  # The lookup says why it found no image to reuse.
  [[ $stderr == *MANIFEST_UNKNOWN* ]]
  run steps
  [ "$output" = "$(step_list 'docker login' 'cosign verify' 'dagger api' 'cosign sign' 'cosign verify')" ]
  # The lookup asks for the key's tag signed by this workflow on main, in this repository, for the key.
  run argv "$(calls_of 'cosign verify' | head -n 1)"
  [ "$(grep -cxF -- "$IMAGE:$key" <<< "$output")" -eq 1 ]
  [ "$(value --certificate-identity <<< "$output")" = "$IDENTITY" ]
  [ "$(value --certificate-oidc-issuer <<< "$output")" = "$ISSUER" ]
  [ "$(value --certificate-github-workflow-repository <<< "$output")" = eekaan/k8s-gitops ]
  [ "$(values -a <<< "$output"; values --annotations <<< "$output")" = "tools-key=$key" ]
  # The push builds the tools from the checkout's inputs and tags them with their key.
  run argv "$(calls_of 'dagger api')"
  [ "$(value --base <<< "$output")" = "$(yq '.ci_tools_base' "$WORK/versions.yaml")" ]
  [ "$(value --packages <<< "$output")" = "$(yq '.ci_tools_packages' "$WORK/versions.yaml")" ]
  [ "$(value --address <<< "$output")" = "$IMAGE:$key" ]
  grep -qx tools-layer <<< "$output"
  grep -qx publish <<< "$output"
  # Signed and verified by the digest the push reported, with the key, as this workflow on main.
  run argv "$(calls_of 'cosign sign')"
  [ "$(grep -cxF -- "$IMAGE@$DIGEST" <<< "$output")" -eq 1 ]
  [ "$(values -a <<< "$output"; values --annotations <<< "$output")" = "tools-key=$key" ]
  run argv "$(calls_of 'cosign verify' | tail -n 1)"
  [ "$(grep -cxF -- "$IMAGE@$DIGEST" <<< "$output")" -eq 1 ]
  [ "$(value --certificate-identity <<< "$output")" = "$IDENTITY" ]
  [ "$(value --certificate-oidc-issuer <<< "$output")" = "$ISSUER" ]
  [ "$(value --certificate-github-workflow-repository <<< "$output")" = eekaan/k8s-gitops ]
  [ "$(values -a <<< "$output"; values --annotations <<< "$output")" = "tools-key=$key" ]

  # A failed verification prints no digest and fails the run, naming the step, and the run's Docker
  # configuration with the login is gone all the same.
  rm -f "$RECORD/calls" "$STATE"/tags/* "$STATE"/signatures/*
  : > "$STATE/verify-fails"
  recipe tools-image-publish
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ $stderr == *"failed while verifying $DIGEST"* ]]
  [ ! -e "$(tail -n 1 "$RECORD/docker-config.docker")" ] || { echo "the login is left after a failed run"; return 1; }
  rm "$STATE/verify-fails"

  # Outside the workflow, or on another branch, it refuses and calls nothing.
  local -a base_environment=("${ENVIRONMENT[@]}")
  for name in GITHUB_ACTIONS ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN GITHUB_ACTIONS=false GITHUB_REF=refs/heads/feature/next REGISTRY_TOKEN; do
    ENVIRONMENT=("${base_environment[@]}")
    if [[ $name == *=* ]]; then
      with "$name"
    else
      without "$name"
    fi
    rm -f "$RECORD/calls"

    recipe tools-image-publish

    [ "$status" -ne 0 ] || { echo "published with $name changed"; return 1; }
    [ -z "$output" ]
    [[ $stderr == *refusing* || $stderr == *"is not set"* ]]
    [ ! -e "$RECORD/calls" ] || { echo "called something with $name changed"; return 1; }
  done
}

@test "a pushed digest that is not a sha256 digest stops the tools image run before anything is signed" {
  local hex=${DIGEST#sha256:} digest
  checkout
  local -a digests=('' latest "$hex" "sha256:${hex:1}" "sha256:${hex}0" "sha256:${hex^^}" "sha512:$hex")
  for digest in "${digests[@]}"; do
    printf '%s' "$digest" > "$STATE/digest"
    rm -f "$RECORD/calls"

    recipe tools-image-publish

    [ "$status" -ne 0 ] || { echo "accepted the digest $digest"; return 1; }
    [ -z "$output" ]
    [ ! -e "$(tail -n 1 "$RECORD/docker-config.docker")" ] || { echo "the login is left after the digest $digest"; return 1; }
    run steps
    [ "$output" = "$(step_list 'docker login' 'cosign verify' 'dagger api')" ] || { echo "with the digest $digest"; return 1; }
  done
}

@test "a tag for the key signed otherwise than by this workflow on main for the key is built and signed again" {
  local key old variant
  checkout
  key=$(key_of "$WORK")
  old="sha256:$(printf 'pushed before' | sha256sum | cut -d' ' -f1)"
  # A branch's run, a run elsewhere that called this workflow, a run for other inputs, a lookup that
  # cannot reach the transparency log, and no signature at all.
  local -a variants=(branch repository inputs unreachable unsigned)
  for variant in "${variants[@]}"; do
    rm -f "$RECORD/calls" "$STATE"/signatures/* "$STATE/lookup-fails"
    printf '%s' "$old" > "$STATE/tags/$key"
    case $variant in
      branch) signed "$old" https://github.com/eekaan/k8s-gitops/.github/workflows/tools-image.yaml@refs/heads/feature "$key" ;;
      repository) signed "$old" "$IDENTITY" "$key" someone-else/other-repo ;;
      inputs) signed "$old" "$IDENTITY" "$(printf 'other inputs' | sha256sum | cut -d' ' -f1)" ;;
      unreachable)
        signed "$old" "$IDENTITY" "$key"
        echo "Error: getting Rekor public keys: transparency log unreachable" > "$STATE/lookup-fails"
        ;;
      unsigned) ;;
    esac

    recipe tools-image-publish

    [ "$status" -eq 0 ] || { echo "with $variant"; return 1; }
    [ "$output" = "$DIGEST" ] || { echo "with $variant: $output"; return 1; }
    # The lookup says why it built.
    [[ $variant != unreachable || $stderr == *"transparency log unreachable"* ]]
    run steps
    [ "$output" = "$(step_list 'docker login' 'cosign verify' 'dagger api' 'cosign sign' 'cosign verify')" ] || { echo "with $variant"; return 1; }
  done
}

@test "a key already published and signed is not built again" {
  checkout
  recipe tools-image-publish
  [ "$status" -eq 0 ]
  rm "$RECORD/calls"
  printf '%s' "sha256:$(printf 'a second build' | sha256sum | cut -d' ' -f1)" > "$STATE/digest"

  recipe tools-image-publish

  [ "$status" -eq 0 ]
  [ "$output" = "$DIGEST" ]
  run steps
  [ "$output" = "$(step_list 'docker login' 'cosign verify')" ]
}

@test "The tools image's registry token reaches no command line and no output" {
  checkout

  recipe tools-image-publish

  [ "$status" -eq 0 ]
  [[ $output != *"$TOKEN"* && $stderr != *"$TOKEN"* ]]
  [ "$(cat "$RECORD/docker-login.stdin")" = "$TOKEN" ]
  run argv "$(calls_of 'docker login')"
  grep -qxF -- --password-stdin <<< "$output"
  run grep -F -- "$TOKEN" "$RECORD/calls"
  [ "$status" -eq 1 ]
  # Nor any command's environment, so nothing it prints, such as why a lookup failed, can hold it.
  [ ! -e "$RECORD/token-in-environment" ] || { echo "in the environment of: $(sort -u "$RECORD/token-in-environment" | paste -sd ' ')"; return 1; }
  # dagger and cosign get no credentials of their own: they read the login docker wrote.
  run grep -E -- '--(creds|registry-username|registry-password|registry-token|password|token)( |=|$)' "$RECORD/calls"
  [ "$status" -eq 1 ]
  run sort -u "$RECORD/docker-config.docker" "$RECORD/docker-config.dagger" "$RECORD/docker-config.cosign"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ $output != *$'\n'* ]] || { echo "docker, dagger and cosign read different Docker configurations"; return 1; }
  [ ! -e "$output" ] || { echo "the Docker configuration with the login is left after the run"; return 1; }
}

@test "Only a digest whose signature verifies against this repository's workflow can be pinned" {
  local key good stale foreign branch elsewhere unsigned before digest workflow login file
  checkout
  # Whatever this checkout records, the copy records another key's image, so a pin changes both lines.
  record "$(printf 'other inputs' | sha256sum | cut -d' ' -f1)" "$IMAGE@sha256:$(printf 'recorded before' | sha256sum | cut -d' ' -f1)"
  key=$(key_of "$WORK")
  good="sha256:$(printf 'built on main for these inputs' | sha256sum | cut -d' ' -f1)"
  stale="sha256:$(printf 'built on main for other inputs' | sha256sum | cut -d' ' -f1)"
  foreign="sha256:$(printf 'built by another workflow' | sha256sum | cut -d' ' -f1)"
  branch="sha256:$(printf 'built on a branch' | sha256sum | cut -d' ' -f1)"
  elsewhere="sha256:$(printf 'built by a run elsewhere that called this workflow' | sha256sum | cut -d' ' -f1)"
  unsigned="sha256:$(printf 'never signed' | sha256sum | cut -d' ' -f1)"
  signed "$good" "$IDENTITY" "$key"
  signed "$stale" "$IDENTITY" "$(printf 'other inputs' | sha256sum | cut -d' ' -f1)"
  signed "$foreign" https://github.com/eekaan/k8s-gitops/.github/workflows/publish.yaml@refs/heads/main "$key"
  signed "$branch" https://github.com/eekaan/k8s-gitops/.github/workflows/tools-image.yaml@refs/heads/feature "$key"
  signed "$elsewhere" "$IDENTITY" "$key" someone-else/other-repo
  # On a laptop with no Docker login but podman's, where cosign looks for one when it finds no Docker
  # configuration: logins the pin must not use.
  without GITHUB_ACTIONS
  login=$(printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "$(printf 'laptop-user:laptop-login' | base64 -w0)")
  for file in auth/registry-auth.json run/containers/auth.json config/containers/auth.json; do
    mkdir -p "$BATS_TEST_TMPDIR/$(dirname "$file")"
    printf '%s\n' "$login" > "$BATS_TEST_TMPDIR/$file"
  done
  with REGISTRY_AUTH_FILE="$BATS_TEST_TMPDIR/auth/registry-auth.json" XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
  before=$(cat "$WORK/versions.yaml")

  for digest in "$stale" "$foreign" "$branch" "$elsewhere" "$unsigned" '' latest "$IMAGE@$good" "${good#sha256:}" "sha256:$(tr a-f A-F <<< "${good#sha256:}")" "$good "; do
    rm -f "$RECORD/calls"

    recipe tools-image-pin "$digest"

    [ "$status" -ne 0 ] || { echo "pinned $digest"; return 1; }
    [ "$(cat "$WORK/versions.yaml")" = "$before" ] || { echo "versions.yaml changed for $digest"; return 1; }
  done

  rm -f "$RECORD/calls" "$RECORD/cosign-credentials"
  recipe tools-image-pin "$good"

  [ "$status" -eq 0 ]
  [ "$(yq '.ci_tools_inputs' "$WORK/versions.yaml")" = "$key" ]
  [ "$(yq '.ci_tools_image' "$WORK/versions.yaml")" = "$IMAGE@$good" ]
  # Those two lines and nothing else.
  run diff <(printf '%s\n' "$before") "$WORK/versions.yaml"
  [ "$(grep -c '^[<>]' <<< "$output")" -eq 4 ]
  [ "$(grep -cE '^[<>] ci_tools_(inputs|image): ' <<< "$output")" -eq 4 ]
  # The one verification: by digest, of exactly this workflow's identity on main, its issuer and the
  # checkout's key, without the credentials at hand, so a package the checks cannot pull is refused.
  run steps
  [ "$output" = 'cosign verify' ]
  run argv "$(calls_of 'cosign verify')"
  [ "$(grep -cxF -- "$IMAGE@$good" <<< "$output")" -eq 1 ]
  [ "$(value --certificate-identity <<< "$output")" = "$IDENTITY" ]
  [ "$(value --certificate-oidc-issuer <<< "$output")" = "$ISSUER" ]
  [ "$(value --certificate-github-workflow-repository <<< "$output")" = eekaan/k8s-gitops ]
  [ "$(values -a <<< "$output"; values --annotations <<< "$output")" = "tools-key=$key" ]
  run grep -xE -- '--(key|insecure-ignore-tlog|insecure-ignore-sct|certificate-chain|trusted-root|allow-insecure-registry|allow-http-registry|certificate-identity-regexp|certificate-oidc-issuer-regexp|k8s-keychain)' <<< "$output"
  [ "$status" -eq 1 ]
  [ "$(cat "$RECORD/cosign-credentials")" = 'verify anonymous' ] || { cat "$RECORD/cosign-credentials"; return 1; }
  # With a Docker login at hand as well, the same.
  record "$(printf 'other inputs' | sha256sum | cut -d' ' -f1)" "$IMAGE@sha256:$(printf 'recorded before' | sha256sum | cut -d' ' -f1)"
  mkdir -p "$BATS_TEST_TMPDIR/home/.docker"
  printf '%s\n' "$login" > "$BATS_TEST_TMPDIR/home/.docker/config.json"
  rm -f "$RECORD/cosign-credentials"
  recipe tools-image-pin "$good"
  [ "$status" -eq 0 ]
  [ "$(cat "$RECORD/cosign-credentials")" = 'verify anonymous' ] || { cat "$RECORD/cosign-credentials"; return 1; }
  # The identity is this repository's tools image workflow on main, and that file runs the publish.
  [[ $IDENTITY =~ ^https://github\.com/eekaan/k8s-gitops/(\.github/workflows/[^/@]+)@refs/heads/main$ ]]
  workflow="$ROOT/${BASH_REMATCH[1]}"
  [ "$workflow" = "$WORKFLOW" ]
  run yq -o=json -I=0 '[.jobs[].steps[] | select(has("run")) | .run]' "$workflow"
  [ "$output" = '["just tools-image-publish"]' ]

  # just ci then runs the checks in the image pinned.
  commit "pin the tools image"
  fake_ci
  [ "$status" -eq 0 ]
  [ "$(handed tools-image)" = "$IMAGE@$good" ]
}

@test "The tools image workflow has only the permissions it needs, runs on a hosted runner, and pins every action to a commit" {
  local ref refs=0 payload
  [ -f "$WORKFLOW" ]
  run yq -o=json -I=0 '.jobs | keys' "$WORKFLOW"
  [ "$status" -eq 0 ]
  [ "$output" = '["publish"]' ]
  run yq -o=json -I=0 '[.jobs[].steps[] | select(has("run")) | .run]' "$WORKFLOW"
  [ "$output" = '["just tools-image-publish"]' ]
  run yq '.jobs.publish.steps[-1] | @json' "$WORKFLOW"
  # shellcheck disable=SC2016 # the workflow's expression, as written
  [ "$output" = '{"run":"just tools-image-publish","env":{"REGISTRY_TOKEN":"${{ secrets.GITHUB_TOKEN }}"}}' ]
  # A pull request, from a fork or not, never gets packages: write or an identity token.
  [ "$(yq -o=json -I=0 '.on | keys' "$WORKFLOW")" = '["push","workflow_dispatch"]' ]
  [ "$(yq -o=json -I=0 '.on.push | keys' "$WORKFLOW")" = '["branches","paths"]' ]
  [ "$(yq -o=json -I=0 '.on.push.branches' "$WORKFLOW")" = '["main"]' ]
  # Every file the key or the image is made from: the inputs, the module whose tools layer is one of
  # them, the script that computes the key and publishes, and the workflow itself.
  [ "$(yq -o=json -I=0 '.on.push.paths | sort' "$WORKFLOW")" = '[".dagger/modules/ci/main.dang",".github/workflows/tools-image.yaml","mise.toml","scripts/tools-image","versions.yaml"]' ]
  [ "$(yq -o=json -I=0 '.permissions | to_entries | sort_by(.key) | from_entries' "$WORKFLOW")" = '{"contents":"read","id-token":"write","packages":"write"}' ]
  [ "$(yq '[.jobs[] | select(has("permissions") or has("concurrency"))] | length' "$WORKFLOW")" = 0 ]
  # One group for every run, and a run in progress is never cancelled: a newer run waits for it.
  run yq '.concurrency.group' "$WORKFLOW"
  [ -n "$output" ]
  [[ $output != *"\${{"* ]]
  [ "$(yq '.concurrency.cancel-in-progress' "$WORKFLOW")" = false ]
  # The job's token is not left in the checkout, and the tools come from the same pinned mise-action
  # and mise as every CI job, installing the pinned tools the recipe runs and no others.
  [ "$(yq -o=json -I=0 '[.jobs.publish.steps[] | select(.uses | test("^actions/checkout@")) | .with.persist-credentials]' "$WORKFLOW")" = '[false]' ]
  local select='[.jobs[].steps[] | select(.uses | test("^jdx/mise-action@")) | {"uses": .uses, "version": .with.version} | @json] | unique'
  run yq -o=json -I=0 "$select" "$WORKFLOW"
  [ "$(yq 'length' <<< "$output")" -eq 1 ]
  [ "$output" = "$(yq -o=json -I=0 "$select" "$ROOT/.github/workflows/ci.yaml")" ]
  run yq '.jobs.publish.steps[] | select(.uses | test("^jdx/mise-action@")) | .with.install_args' "$WORKFLOW"
  [ "$(tr ' ' '\n' <<< "$output" | sort | paste -sd ' ')" = "cosign http:dagger jq just" ]
  local tool
  for tool in $output; do
    yq -p toml -o yaml -e ".tools | has(\"$tool\")" "$ROOT/mise.toml" > /dev/null || { echo "not pinned in mise.toml: $tool"; return 1; }
  done
  # Every action is pinned to a commit.
  run yq '.. | select(tag == "!!map" and has("uses")) | .uses' "$WORKFLOW"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    refs=$((refs + 1))
    [[ $ref =~ ^[^@[:space:]]+@[0-9a-f]{40}$ ]] || { echo "not pinned to a commit: $ref"; return 1; }
  done <<< "$output"
  [ "$refs" -gt 0 ]
  # A hosted runner, which the CI host's job-started hook enforces as well.
  [ "$(yq -o=json -I=0 '[.jobs[].runs-on]' "$WORKFLOW")" = '["ubuntu-latest"]' ]
  payload="$BATS_TEST_TMPDIR/event.json"
  jq -n '{ref: "refs/heads/main", repository: {full_name: "fixture-owner/fixture-repo"}}' > "$payload"
  # shellcheck source=scripts/lib/ci-host.sh
  (. "$ROOT/scripts/lib/ci-host.sh" && ci_host_hook) > "$BATS_TEST_TMPDIR/job-started.sh"
  run env -i PATH="$PATH" GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main GITHUB_REPOSITORY=fixture-owner/fixture-repo \
    GITHUB_EVENT_PATH="$payload" GITHUB_WORKFLOW_REF=fixture-owner/fixture-repo/.github/workflows/tools-image.yaml@refs/heads/main \
    bash -e "$BATS_TEST_TMPDIR/job-started.sh"
  [ "$status" -ne 0 ]
  [[ $output == *"jobs of workflows other than .github/workflows/ci.yaml"* ]]
}
