#!/usr/bin/env bats
# Proves features/signatures.feature but its scenario of the pinned sources, which just
# signatures-verify proves against the registries themselves; each test that proves a scenario
# carries its title, and those named in lower case prove none.
# scripts/signatures-check runs on the repository's tree, built once for the file, and on a copy of
# tests/fixtures/signatures/tree, a small tree that passes kubernetes-check, with its sources on
# charts.example.invalid, which a test changes. For the verification, cosign and curl are recording
# fakes first on PATH: curl answers the probe of a registry's /v2/ as STATE says, and cosign,
# modelled on the one of tests/tools-image.bats, answers from the signatures STATE gives each
# reference, matching its two regular-expression flags with bash and a key file byte for byte, and
# looks for registry logins where cosign's default keychain does; the pinned cosign itself runs only
# as cosign env, offline, for the variables it lists. For just cluster-signatures, kubectl is a fake
# that answers the cluster's OCIRepositories from STATE. Nothing reaches a registry or a cluster.
# Needs kustomize, yq, jq, flux and cosign on PATH, the versions pinned for the repository.

# The identities the cluster verifies today, which this change keeps, and app-template's.
FLUX_CHARTS='^https://github\.com/controlplaneio-fluxcd/charts/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$'
GITHUB_ISSUER='^https://token\.actions\.githubusercontent\.com$'
PUBLISH='^https://github\.com/eekaan/k8s-gitops/\.github/workflows/publish\.yaml@refs/heads/main$'
APP_TEMPLATE='^https://github\.com/bjw-s-labs/helm-charts/\.github/workflows/chart-release-steps\.yaml@refs/heads/main$'

setup_file() {
  local root
  root=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export KUBECONFIG="$BATS_FILE_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  # What Flux builds of the repository's tree, as kubernetes-check keeps it, and what the check says
  # of the tree, once for every test of the file.
  mkdir -p "$BATS_FILE_TMPDIR/built"
  KUBERNETES_CHECK_BUILT="$BATS_FILE_TMPDIR/built" "$root/scripts/kubernetes-check" > "$BATS_FILE_TMPDIR/built.log" 2>&1 ||
    echo "kubernetes-check failed on the tree" > "$BATS_FILE_TMPDIR/built.failed"
  local status=0
  "$root/scripts/signatures-check" > "$BATS_FILE_TMPDIR/tree-check.out" 2>&1 < /dev/null || status=$?
  echo "$status" > "$BATS_FILE_TMPDIR/tree-check.status"
}

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  CHECK="$ROOT/scripts/signatures-check"
  TREE="$BATS_TEST_TMPDIR/tree"
  cp -R "$BATS_TEST_DIRNAME/fixtures/signatures/tree" "$TREE"
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$BIN" "$RECORD" "$STATE/refs" "$STATE/signatures" "$STATE/hosts" "$BATS_TEST_TMPDIR/home"
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  ISSUER='https://token.ci.example.invalid'
  ENVIRONMENT=(HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR")
  fakes
}

# The repository's tree: its rows as JSON, one a line, in order.
tree_rows() {
  yq -o json -I0 '.sources[]' "$ROOT/signatures.yaml"
}

# tree_objects: each source object Flux builds from the tree, one JSON object a line: its kind,
# namespace, name, url, ref and verify block.
tree_objects() {
  [ ! -e "$BATS_FILE_TMPDIR/built.failed" ] || { cat "$BATS_FILE_TMPDIR/built.log"; return 1; }
  local file
  for file in "$BATS_FILE_TMPDIR"/built/*.yaml; do
    yq -N -o json -I0 'select(. != null and ((.apiVersion // "") | test("^source\.toolkit\.fluxcd\.io/")))
      | {"kind": .kind, "namespace": .metadata.namespace, "name": .metadata.name, "url": .spec.url,
         "ref": .spec.ref, "verify": .spec.verify}' "$file"
  done
}

# instance_values: the values the flux-instance application builds into its ConfigMap, as JSON.
instance_values() {
  local file
  for file in "$BATS_FILE_TMPDIR"/built/*.yaml; do
    yq -N -o json -I0 'select(. != null and .kind == "ConfigMap" and (.metadata.name | test("^flux-instance-values")))
      | .data["values.yaml"] | from_yaml' "$file"
  done
}

# sync_verify: the verify block the FluxInstance's values patch onto the sync source, as JSON.
sync_verify() {
  instance_values | jq -c '.instance.kustomize.patches[] | select(.target.kind == "OCIRepository"
    and .target.name == "flux-system") | .patch' | jq -r . | yq -o json -I0 '.[] | select(.path == "/spec/verify") | .value'
}

# stub NAME: a binary first on the run's PATH, its body read from stdin.
stub() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# fake NAME: a stub that first records its call in RECORD/calls, one line of its name and its
# arguments quoted as printf %q quotes them, and its whole environment in RECORD/env.NAME.N, N the
# call's number; RECORD and STATE are set for its body.
fake() {
  {
    printf 'RECORD=%q STATE=%q\n' "$RECORD" "$STATE"
    cat << 'EOF'
{ printf '%q ' "${0##*/}" "$@"; echo; } >> "$RECORD/calls"
calls=$(grep -c "^${0##*/} " "$RECORD/calls")
env > "$RECORD/env.${0##*/}.$calls"
EOF
    cat
  } | stub "$1"
}

# fakes: the stand-ins on the run's PATH.
fakes() {
  # curl answers a registry's /v2/ with what STATE/hosts/HOST says: unresolved, silent (no answer in
  # time), limited (429), down (503), or 401, the answer of a registry that wants a token, which is
  # also what a registry that limits the pulls alone, limits-pulls, answers.
  fake curl << 'EOF'
url=
for arg; do
  [[ $arg != https://* ]] || url=$arg
done
host=${url#https://}
host=${host%%/*}
case $(cat "$STATE/hosts/$host" 2> /dev/null) in
  unresolved) echo "curl: (6) Could not resolve host: $host" >&2; exit 6 ;;
  silent) echo "curl: (28) Connection timed out after 20001 milliseconds" >&2; exit 28 ;;
  limited) printf 429 ;;
  down) printf 503 ;;
  *) printf 401 ;;
esac
EOF
  # cosign verify: a host STATE/hosts marks unresolved fails as cosign does, naming the resolver's
  # address, and one marked limited as a rate limit; a reference with no STATE/refs entry is a tag
  # that is not there (11); one without STATE/signatures has no signature (10). Otherwise the
  # signature's lines say its format (legacy, which has exit codes of its own, or bundle, whose
  # failures exit 1) and either a keyless issuer and subject, matched with bash against the two
  # regular-expression flags, or a key file and digest, compared byte for byte with --key and
  # --signature-digest-algorithm, sha256 when not given, and needing --insecure-ignore-tlog. It
  # prints a marker of its own on both streams. A reference STATE/slow names takes that many seconds,
  # and, as cosign does, it stops at its --timeout with exit 1.
  fake cosign << 'EOF'
config=${DOCKER_CONFIG:-$HOME/.docker}
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
echo "cosign-says-this 192.0.2.10"
echo "cosign-says-this 192.0.2.10 on its errors" >&2
[[ ${1-} == verify ]] || { echo "fake cosign: unexpected call" >&2; exit 1; }
shift
issuer_re= subject_re= key= digest=sha256 tlog=1 ref= timeout=180
while (($#)); do
  case $1 in
    --certificate-oidc-issuer-regexp) issuer_re=$2; shift ;;
    --certificate-identity-regexp) subject_re=$2; shift ;;
    --key) key=$2; shift ;;
    --signature-digest-algorithm) digest=$2; shift ;;
    --insecure-ignore-tlog) tlog=0 ;;
    --timeout) timeout=${2%s}; shift ;;
    -*) echo "fake cosign: unexpected flag $1" >&2; exit 1 ;;
    *) ref=$1 ;;
  esac
  shift
done
name=${ref//[\/:@]/_}
if [[ -e $STATE/slow/$name ]]; then
  if (($(cat "$STATE/slow/$name") >= timeout)); then
    sleep "$timeout"
    echo "Error: context deadline exceeded" >&2
    exit 1
  fi
  sleep "$(cat "$STATE/slow/$name")"
fi
host=${ref%%/*}
case $(cat "$STATE/hosts/$host" 2> /dev/null) in
  unresolved | silent) echo "Error: Get \"https://$host/v2/\": dial tcp: lookup $host on 192.0.2.53:53: no such host" >&2; exit 1 ;;
  limited | limits-pulls) echo "Error: GET https://$host/v2/: TOOMANYREQUESTS: rate limited" >&2; exit 1 ;;
esac
[[ -e $STATE/refs/$name ]] || { echo "Error: image tag not found: MANIFEST_UNKNOWN" >&2; exit 11; }
signature=$STATE/signatures/$name
[[ -e $signature ]] || { echo "Error: no signatures found" >&2; exit 10; }
format=$(sed -n 's/^format=//p' "$signature")
mismatch() {
  if [[ $format == bundle ]]; then
    echo "Error: no matching attestations: failed to verify certificate identity" >&2
    exit 1
  fi
  echo "Error: no matching signatures: none of the expected identities matched" >&2
  exit 12
}
if [[ -n $key ]]; then
  [[ -n $(sed -n 's/^key=//p' "$signature") ]] || mismatch
  cmp -s "$key" "$(sed -n 's/^key=//p' "$signature")" || mismatch
  [[ $digest == "$(sed -n 's/^digest=//p' "$signature")" ]] || mismatch
  ((tlog == 0)) || { echo "Error: no transparency log entry" >&2; exit 1; }
else
  [[ -n $issuer_re && -n $subject_re ]] || { echo "fake cosign: keyless without both flags" >&2; exit 1; }
  issuer=$(sed -n 's/^issuer=//p' "$signature")
  subject=$(sed -n 's/^subject=//p' "$signature")
  [[ -n $subject ]] || mismatch
  [[ $issuer =~ $issuer_re && $subject =~ $subject_re ]] || mismatch
fi
echo '[{"critical":{"type":"cosign container image signature"}}]'
EOF
  # kubectl get answers the cluster's OCIRepositories from STATE/ocirepositories.json; while
  # STATE/kubectl-fails exists it fails with an error that names the API server's address, as
  # kubectl's do. Any other verb fails.
  fake kubectl << 'EOF'
[[ ${1-} == get ]] || { echo "fake kubectl: not a get" >&2; exit 1; }
if [[ -e $STATE/kubectl-fails ]]; then
  echo "Unable to connect to the server: dial tcp 192.0.2.80:6443: i/o timeout" >&2
  exit 1
fi
cat "$STATE/ocirepositories.json"
EOF
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

# serve REF: the registry has the tag or digest REF, a reference without oci://.
serve() {
  : > "$STATE/refs/${1//[\/:@]/_}"
}

# signed_keyless REF SUBJECT [FORMAT]: REF is served with a keyless signature by SUBJECT from the
# fixture's issuer, in FORMAT, legacy unless given.
signed_keyless() {
  serve "$1"
  printf 'format=%s\nissuer=%s\nsubject=%s\n' "${3:-legacy}" "$ISSUER" "$2" > "$STATE/signatures/${1//[\/:@]/_}"
}

# signed_key REF KEYFILE DIGEST [FORMAT]: REF is served with a signature by the key in KEYFILE over
# DIGEST.
signed_key() {
  serve "$1"
  printf 'format=%s\nkey=%s\ndigest=%s\n' "${4:-legacy}" "$2" "$3" > "$STATE/signatures/${1//[\/:@]/_}"
}

# TOOLS_DIGEST: the digest the fixture's versions.yaml records for the tools image.
TOOLS_DIGEST=sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945

# as_rows: the registry serves every pinned source of the fixture signed as its row says.
as_rows() {
  local code=https://code.example.invalid/example
  signed_keyless charts.example.invalid/tree/manifests:main "$code/tree/.ci/publish.yml@refs/heads/main"
  signed_keyless "charts.example.invalid/example/tree/ci-tools@$TOOLS_DIGEST" "$code/tree/.ci/tools-image.yml@refs/heads/main" bundle
  signed_keyless charts.example.invalid/charts/hello:2.0.0 "$code/hello/.ci/release.yml@refs/heads/main" bundle
  signed_key charts.example.invalid/charts/keyed:4.0.0 "$BATS_TEST_DIRNAME/fixtures/signatures/tree/signatures/keyed.pem" sha512
  signed_keyless charts.example.invalid/charts/mirrored:5.0.0 "$code/mirror/.ci/mirror.yml@refs/heads/main"
  serve charts.example.invalid/charts/plain:3.0.0
  signed_keyless charts.example.invalid/flux/instance:1.0.0 "$code/charts/.ci/release.yml@refs/tags/v1.0.0" bundle
  signed_keyless charts.example.invalid/flux/operator:1.0.0 "$code/charts/.ci/release.yml@refs/tags/v1.0.0"
}

# check [DIR]: the offline check of DIR, the fixture copy unless given, as run sets status and output.
check() {
  run "$CHECK" "${1:-$TREE}" < /dev/null
  echo "$output"
}

# verify: the verification of the fixture copy with the fakes first on PATH and only ENVIRONMENT
# set, stdout in output and stderr in stderr. A run that blocks fails after two minutes.
verify() {
  bats_require_minimum_version 1.5.0
  run --separate-stderr timeout 120 env -i PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" "$CHECK" verify "$TREE" < /dev/null
  printf '%s\n' "$output" "$stderr"
}

# line_of SOURCE: the verification's line for SOURCE.
line_of() {
  grep -F -- "  $1: " <<< "$output" || true
}

# fails_naming TEXT...: the check failed, and one of its lines holds every TEXT.
fails_naming() {
  local line text ok
  [ "$status" -ne 0 ] || { echo "expected the check to fail"; return 1; }
  while IFS= read -r line; do
    ok=1
    for text; do
      [[ $line == *"$text"* ]] || { ok=0; break; }
    done
    ((ok)) && return 0
  done <<< "$output"
  echo "no line holds all of: $*"
  return 1
}

# put FILE: writes stdin to FILE in the fixture copy.
put() {
  mkdir -p "$(dirname "$TREE/$1")"
  cat > "$TREE/$1"
}

# edit FILE EXPRESSION: yq EXPRESSION applied in place to FILE in the fixture copy.
edit() {
  yq -i "$2" "$TREE/$1"
}

# row_index SOURCE: the index of SOURCE's row in the fixture copy's signatures.yaml.
row_index() {
  yq ".sources | to_entries | .[] | select(.value.source == \"$1\") | .key" "$TREE/signatures.yaml"
}

# rejects PATTERN IDENTITY...: no IDENTITY matches the regular expression PATTERN.
rejects() {
  local pattern=$1 identity
  shift
  for identity in "$@"; do
    if [[ $identity =~ $pattern ]]; then
      echo "$pattern also matches $identity"
      return 1
    fi
  done
}

# dotless IDENTITY: IDENTITY once for each of its dots, with that dot made an x, so a pattern that
# leaves any dot unescaped matches one of them.
dotless() {
  local identity=$1 i
  for ((i = 0; i < ${#identity}; i++)); do
    if [[ ${identity:i:1} == . ]]; then
      echo "${identity:0:i}x${identity:i+1}"
    fi
  done
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

# sample SUBJECT: one string the anchored SUBJECT matches: its literal part up to the ref, then the
# ref with each run of digits a class repeats made 1 and each escaped dot a dot. Fails for a ref of
# any other construct.
sample() {
  local subject=$1 head ref
  [[ $subject == ^* && $subject == *'$' ]] || return 1
  if [[ $subject == *@* ]]; then
    head=${subject%%@*}
    ref=${subject#*@}
    ref=${ref%'$'}
    head=$(literal "$head\$") || return 1
    ref=${ref//'[0-9]+'/1}
    ref=${ref//\\./.}
    [[ $ref != *[][\\\(\)*+?{}\|^\$]* ]] || return 1
    printf '%s@%s' "$head" "$ref"
  else
    literal "$subject"
  fi
}

# argv LINE: the arguments of one recorded call, one per line.
argv() {
  local arg
  local -a args
  eval "args=($1)"
  for arg in "${args[@]}"; do
    printf '%s\n' "$arg"
  done
}

# value FLAG: the value given to FLAG in the arguments on stdin, one per line; fails unless FLAG is
# given exactly once.
value() {
  awk -v flag="$1" 'found { print; found = 0; n++; next } $0 == flag { found = 1 } END { exit n != 1 }'
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

# docs_table: the lines of the table under docs/kubernetes.md's heading Signatures, but its header
# and the line under it, one per line: source, signed by, verified and why, separated by tabs, the
# source's backquotes off.
docs_table() {
  # shellcheck disable=SC2016 # Markdown's backquotes, not expansions.
  awk '/^## Signatures$/ { inside = 1; next } inside && /^## / { exit } inside && /^\| / { print }' "$ROOT/docs/kubernetes.md" |
    sed -n '2,$p' | sed -E 's/^\| *//; s/ *\|$//; s/ *\| */\t/g' | sed -E 's/^`([^`]+)`/\1/'
}

# cluster_signatures: just cluster-signatures against a copy of the repository's scripts, its
# signatures.yaml and a kubeconfig of the fixture, with the fakes first on PATH, as run sets status
# and output.
cluster_signatures() {
  local repo="$BATS_TEST_TMPDIR/repo"
  if [[ ! -d $repo ]]; then
    mkdir -p "$repo/talos/lab-sto2/clusterconfig"
    cp -R "$ROOT/scripts" "$repo/scripts"
    cp "$ROOT/signatures.yaml" "$repo/"
    printf 'apiVersion: v1\nkind: Config\nclusters:\n  - name: lab-sto2\n    cluster:\n      server: https://203.0.113.80:6443\n' \
      > "$repo/talos/lab-sto2/clusterconfig/kubeconfig"
  fi
  # A mise with nothing installed keeps the justfile from putting the real tools in front of the fakes.
  stub mise < /dev/null
  run timeout 120 env -i HOME="$BATS_TEST_TMPDIR/home" PATH="$BIN:$PATH" TMPDIR="$BATS_TEST_TMPDIR" \
    "$(command -v just)" --justfile "$ROOT/justfile" --working-directory "$repo" cluster-signatures
  echo "$output"
}

# ocirepository NAMESPACE NAME URL [VERIFY [READY [VERIFIED [OBSERVED [REASON [STATUS]]]]]]: one
# OCIRepository as the cluster would hold it, at generation 2: VERIFY the block's JSON or null; READY
# and VERIFIED the status of the Ready and SourceVerified conditions (none for no SourceVerified);
# OBSERVED the generation SourceVerified was observed at; REASON the reasons; STATUS the generation
# the object's status and its Ready condition were observed at, 2 unless given. Every message names
# an address.
ocirepository() {
  jq -nc --arg ns "$1" --arg name "$2" --arg url "$3" --argjson verify "${4:-null}" --arg ready "${5:-True}" \
    --arg verified "${6:-none}" --argjson observed "${7:-2}" --arg reason "${8:-Succeeded}" --argjson status "${9:-2}" '{
    apiVersion: "source.toolkit.fluxcd.io/v1", kind: "OCIRepository",
    metadata: {namespace: $ns, name: $name, generation: 2},
    spec: ({url: $url, ref: {tag: "1.0.0"}} + (if $verify == null then {} else {verify: $verify} end)),
    status: {observedGeneration: $status, conditions: ([
      {type: "Ready", status: $ready, reason: (if $ready == "True" then "Succeeded" else $reason end), observedGeneration: $status,
       message: "stored artifact from 192.0.2.44"}]
      + (if $verified == "none" then [] else [{type: "SourceVerified", status: $verified, reason: $reason,
         observedGeneration: $observed, message: "verified at 192.0.2.45"}] end))}}'
}

# identity SOURCE: the verify block signatures.yaml gives SOURCE, as JSON.
identity() {
  tree_rows | jq -c --arg source "$1" 'select(.source == $source) | {provider: "cosign", matchOIDCIdentity: [{issuer, subject}]}'
}

@test "A chart source without a row fails the check, and so does a row without a source" {
  # The tree: every source Flux builds, the sync source and the tools image is one row, and every
  # row is one of them.
  local built rows sync tools
  built=$(tree_objects | jq -r 'select(.kind != "GitRepository") | .url' | sort -u)
  sync=$(instance_values | jq -r '.instance.sync.url')
  tools="oci://$(sed -n 's/^image=//p' "$ROOT/scripts/tools-image" | sed "s|\$repository|$(sed -n 's/^repository=//p' "$ROOT/scripts/tools-image")|")"
  [ "$sync" = oci://ghcr.io/eekaan/k8s-gitops/manifests ]
  [ "$tools" = oci://ghcr.io/eekaan/k8s-gitops/ci-tools ]
  rows=$(tree_rows | jq -r '.source')
  [ -z "$(sort <<< "$rows" | uniq -d)" ] || { echo "listed twice: $(sort <<< "$rows" | uniq -d)"; return 1; }
  diff <(printf '%s\n' "$built" "$sync" "$tools" | sort -u) <(sort <<< "$rows")
  [ "$(cat "$BATS_FILE_TMPDIR/tree-check.status")" -eq 0 ] || { cat "$BATS_FILE_TMPDIR/tree-check.out"; return 1; }
  grep -qx "signatures-check: passed ($(wc -l <<< "$rows") rows)" "$BATS_FILE_TMPDIR/tree-check.out"

  check
  [ "$status" -eq 0 ]
  [ "$output" = "signatures-check: passed (9 rows)" ]

  # A source without its row and a row without its source, in one run: both are reported.
  edit signatures.yaml 'del(.sources[] | select(.source == "oci://charts.example.invalid/charts/plain"))'
  edit signatures.yaml '.sources += [{"source": "oci://charts.example.invalid/charts/zzz-gone", "signed": "unsigned", "reason": "removed"}]'

  check

  fails_naming oci://charts.example.invalid/charts/plain "OCIRepository demo/plain" kubernetes/apps/base/demo/plain/app/ocirepository.yaml "no row"
  fails_naming "signatures.yaml" oci://charts.example.invalid/charts/zzz-gone "no source"
  [ "$(grep -c '^signatures-check: ' <<< "$output")" -ge 2 ]

  # The sync source and the tools image need their rows too.
  cp "$BATS_TEST_DIRNAME/fixtures/signatures/tree/signatures.yaml" "$TREE/signatures.yaml"
  edit signatures.yaml 'del(.sources[0, 1])'
  check
  fails_naming oci://charts.example.invalid/tree/manifests "no row"
  fails_naming oci://charts.example.invalid/example/tree/ci-tools "no row" scripts/tools-image
}

@test "a source listed twice, rows out of order and a field missing, unknown or not on one line fail the check" {
  local plain hello
  plain=$(row_index oci://charts.example.invalid/charts/plain)
  hello=$(row_index oci://charts.example.invalid/charts/hello)
  edit signatures.yaml ".sources += [.sources[$plain]]"
  check
  fails_naming oci://charts.example.invalid/charts/plain "listed twice"

  cp "$BATS_TEST_DIRNAME/fixtures/signatures/tree/signatures.yaml" "$TREE/signatures.yaml"
  edit signatures.yaml ".sources[$plain] as \$p | .sources[$hello] as \$h | .sources[$plain] = \$h | .sources[$hello] = \$p"
  check
  fails_naming oci://charts.example.invalid/charts/hello "out of order"
  # The synced artifact and the tools image come first, whatever the order of their sources.
  cp "$BATS_TEST_DIRNAME/fixtures/signatures/tree/signatures.yaml" "$TREE/signatures.yaml"
  edit signatures.yaml ".sources[0] as \$a | .sources[1] as \$b | .sources[0] = \$b | .sources[1] = \$a"
  check
  fails_naming oci://charts.example.invalid/example/tree/ci-tools "out of order"

  cp "$BATS_TEST_DIRNAME/fixtures/signatures/tree/signatures.yaml" "$TREE/signatures.yaml"
  edit signatures.yaml "del(.sources[$plain].reason) | .sources[$hello].note = \"x\" | del(.sources[$(row_index oci://charts.example.invalid/flux/operator)].from)"
  check
  fails_naming oci://charts.example.invalid/charts/plain reason missing
  fails_naming oci://charts.example.invalid/charts/hello note unknown
  fails_naming oci://charts.example.invalid/flux/operator from missing

  # A from folded over two lines, a reason that keeps a line break, a field that is not text and a
  # field of another kind.
  cp "$BATS_TEST_DIRNAME/fixtures/signatures/tree/signatures.yaml" "$TREE/signatures.yaml"
  edit signatures.yaml ".sources[$(row_index oci://charts.example.invalid/flux/instance)].from = 12 | .sources[$(row_index oci://charts.example.invalid/charts/mirrored)].key = \"signatures/keyed.pem\""
  sed -i 's|^    from: the certificate of the signature of 2.0.0$|    from: the certificate of the\n      signature of 2.0.0|' "$TREE/signatures.yaml"
  sed -i 's|^    reason: the fixture publisher signs nothing$|    reason: \|\n      the fixture publisher\n      signs nothing|' "$TREE/signatures.yaml"
  grep -qx '      signature of 2.0.0' "$TREE/signatures.yaml"
  check
  fails_naming oci://charts.example.invalid/charts/hello from "one line"
  fails_naming oci://charts.example.invalid/charts/plain reason "one line"
  fails_naming oci://charts.example.invalid/flux/instance from "one line"
  fails_naming oci://charts.example.invalid/charts/mirrored key unknown
  # A reason folded over lines reads as one, and passes.
  cp "$BATS_TEST_DIRNAME/fixtures/signatures/tree/signatures.yaml" "$TREE/signatures.yaml"
  grep -q '^      SHA-256 alone$' "$TREE/signatures.yaml"
  check
  [ "$status" -eq 0 ]
}

@test "a Helm repository not listed as unsigned, a source kind without a rule and a ref that is no tag or digest fail the check" {
  local classic
  classic=$(row_index https://charts.example.invalid/classic)
  edit signatures.yaml ".sources[$classic].signed = \"keyless\""
  check
  fails_naming https://charts.example.invalid/classic "HelmRepository demo/classic" kubernetes/apps/base/demo/classic/app/helmrepository.yaml unsigned

  cp "$BATS_TEST_DIRNAME/fixtures/signatures/tree/signatures.yaml" "$TREE/signatures.yaml"
  edit kubernetes/apps/base/demo/classic/app/helmrepository.yaml '.spec.type = "oci" | .spec.url = "oci://charts.example.invalid/classic"'
  edit signatures.yaml ".sources[$classic].source = \"oci://charts.example.invalid/classic\""
  put kubernetes/apps/base/demo/plain/app/bucket.yaml << 'EOF'
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: Bucket
metadata:
  name: plain-bucket
spec:
  interval: 1h
  bucketName: charts
  endpoint: charts.example.invalid
EOF
  edit kubernetes/apps/base/demo/plain/app/kustomization.yaml '.resources += ["bucket.yaml"]'
  edit kubernetes/apps/base/demo/mirrored/app/ocirepository.yaml 'del(.spec.ref.tag) | .spec.ref.semver = ">=5.0.0"'
  check
  fails_naming "HelmRepository demo/classic" kubernetes/apps/base/demo/classic/app/helmrepository.yaml "type oci"
  fails_naming "Bucket demo/plain-bucket" kubernetes/apps/base/demo/plain/app/bucket.yaml "no rule"
  fails_naming "OCIRepository demo/mirrored" kubernetes/apps/base/demo/mirrored/app/ocirepository.yaml "neither a tag nor a digest"

  # A digest is a pin; a GitRepository is passed over, and has no row.
  cp -R "$BATS_TEST_DIRNAME/fixtures/signatures/tree/." "$TREE/"
  edit kubernetes/apps/base/demo/mirrored/app/ocirepository.yaml '.spec.ref = {"digest": "sha256:'"${TOOLS_DIGEST#sha256:}"'"}'
  rm "$TREE/kubernetes/apps/base/demo/plain/app/bucket.yaml"
  edit kubernetes/apps/base/demo/plain/app/kustomization.yaml '.resources = ["ocirepository.yaml"]'
  check
  [ "$status" -eq 0 ]
}

@test "a key that is no PEM public key file under signatures/, and a file there no row names, fail the check" {
  local keyed key
  keyed=$(row_index oci://charts.example.invalid/charts/keyed)
  for key in keyed.pem signatures/missing.pem 'k8s://demo/cosign-key' 'https://charts.example.invalid/key.pem' 'awskms:///alias/key' signatures/../signatures/keyed.pem; do
    cp "$BATS_TEST_DIRNAME/fixtures/signatures/tree/signatures.yaml" "$TREE/signatures.yaml"
    edit signatures.yaml ".sources[$keyed].key = \"$key\""
    check
    fails_naming oci://charts.example.invalid/charts/keyed key || { echo "accepted the key $key"; return 1; }
  done

  cp "$BATS_TEST_DIRNAME/fixtures/signatures/tree/signatures.yaml" "$TREE/signatures.yaml"
  cat "$TREE/signatures/keyed.pem" "$TREE/signatures/keyed.pem" > "$TREE/signatures/two.pem"
  printf 'not a key\n' > "$TREE/signatures/text.pem"
  sed 's/PUBLIC KEY/PRIVATE KEY/' "$TREE/signatures/keyed.pem" > "$TREE/signatures/private.pem"
  for key in two text private; do
    edit signatures.yaml ".sources[$keyed].key = \"signatures/$key.pem\""
    check
    fails_naming oci://charts.example.invalid/charts/keyed "signatures/$key.pem" "one PEM public key" || return 1
  done

  # The keys no row names.
  cp "$BATS_TEST_DIRNAME/fixtures/signatures/tree/signatures.yaml" "$TREE/signatures.yaml"
  check
  fails_naming signatures/two.pem "no row"
  fails_naming signatures/text.pem "no row"

  # A key row is verified before merge alone, as no key's block is built.
  rm "$TREE"/signatures/{two,text,private}.pem
  edit signatures.yaml "del(.sources[$keyed].cluster) | del(.sources[$keyed].reason)"
  check
  fails_naming oci://charts.example.invalid/charts/keyed "cluster: false"
}

@test "A row that names a keyless identity is the verify block of every source it covers, and no other source has one" {
  # The tree, after kustomize and Flux's substitution: each OCIRepository against its row.
  local objects rows verdicts sync row
  objects=$(tree_objects | jq -c 'select(.kind == "OCIRepository")')
  rows=$(tree_rows | jq -sc 'map({(.source): .}) | add')
  verdicts=$(jq -r --argjson rows "$rows" '. as $o | $rows[$o.url] as $row
    | if $row == null then "\($o.namespace)/\($o.name): no row"
      elif $row.signed == "keyless" and $row.cluster != false then
        (if $o.verify == {"provider": "cosign", "matchOIDCIdentity": [{"issuer": $row.issuer, "subject": $row.subject}]}
          then "ok" else "\($o.namespace)/\($o.name): not its row'"'"'s block: \($o.verify | tojson)" end)
      elif $o.verify == null then "ok" else "\($o.namespace)/\($o.name): a block its row does not give it" end' <<< "$objects")
  if grep -qv '^ok$' <<< "$verdicts"; then
    grep -v '^ok$' <<< "$verdicts"
    return 1
  fi
  # app-template is one row and four objects, each with the block.
  run jq -r 'select(.url == "oci://ghcr.io/bjw-s-labs/helm/app-template") | "\(.namespace)/\(.name) \(.verify.matchOIDCIdentity[0].subject)"' <<< "$objects"
  [ "$(sort <<< "$output")" = "$(printf '%s %s\n' ai-system/app-template "$APP_TEMPLATE" ai-system/open-webui "$APP_TEMPLATE" backstage/app-template "$APP_TEMPLATE" kromgo/app-template "$APP_TEMPLATE")" ]
  # The Flux Operator's charts and cilium keep and get theirs; cert-manager, signed with a key, and
  # kyverno, whose signatures are elsewhere, have none.
  [ "$(jq -r 'select(.name == "flux-operator") | .verify.matchOIDCIdentity[0].subject' <<< "$objects")" = "$FLUX_CHARTS" ]
  [ "$(jq -r 'select(.name == "cilium") | .verify.matchOIDCIdentity[0].subject' <<< "$objects")" = '^https://github\.com/cilium/cilium/\.github/workflows/release\.yaml@refs/heads/main$' ]
  [ "$(jq -c 'select(.name == "cert-manager" or .name == "kyverno") | .verify' <<< "$objects" | sort -u)" = null ]
  # The sync source's patch holds its row's identity the same way.
  sync=$(sync_verify)
  row=$(tree_rows | jq -c 'select(.source == "oci://ghcr.io/eekaan/k8s-gitops/manifests")')
  [ "$(jq -c '{provider: "cosign", matchOIDCIdentity: [{issuer, subject}]}' <<< "$row")" = "$(jq -c . <<< "$sync")" ]

  check
  [ "$status" -eq 0 ]

  # One character of a block's subject changed, a block removed, a block added where the row gives
  # none, a block with another field or a second identity, and the sync source's patch changed.
  sed -i 's|example/hello/|example/hellp/|' "$TREE/kubernetes/apps/base/demo/hello/app/ocirepository.yaml"
  edit kubernetes/apps/base/demo/greeting/app/ocirepository.yaml 'del(.spec.verify)'
  edit kubernetes/apps/base/demo/plain/app/ocirepository.yaml '.spec.verify = {"provider": "cosign", "matchOIDCIdentity": [{"issuer": "^https://token\\.ci\\.example\\.invalid$", "subject": "^x$"}]}'
  edit kubernetes/apps/base/demo/mirrored/app/ocirepository.yaml '.spec.verify = {"provider": "cosign"}'
  edit kubernetes/clusters/test/flux-system/flux-operator/app/ocirepository.yaml '.spec.verify.secretRef = {"name": "keys"}'
  edit kubernetes/clusters/test/flux-system/flux-instance/app/ocirepository.yaml '.spec.verify.matchOIDCIdentity += .spec.verify.matchOIDCIdentity'
  sed -i 's|example/tree/\\.ci/publish|example/trex/\\.ci/publish|' "$TREE/kubernetes/clusters/test/flux-system/flux-instance/app/values.yaml"

  check

  fails_naming oci://charts.example.invalid/charts/hello "OCIRepository demo/hello" kubernetes/apps/base/demo/hello/app/ocirepository.yaml "not its row's identity"
  fails_naming oci://charts.example.invalid/charts/hello "OCIRepository demo/greeting" kubernetes/apps/base/demo/greeting/app/ocirepository.yaml "no verify block"
  fails_naming oci://charts.example.invalid/charts/plain "OCIRepository demo/plain" kubernetes/apps/base/demo/plain/app/ocirepository.yaml "a verify block"
  fails_naming oci://charts.example.invalid/charts/mirrored "OCIRepository demo/mirrored" "a verify block"
  fails_naming oci://charts.example.invalid/flux/operator "OCIRepository flux-system/flux-operator" "not its row's identity"
  fails_naming oci://charts.example.invalid/flux/instance "OCIRepository flux-system/flux-instance" "not its row's identity"
  fails_naming oci://charts.example.invalid/tree/manifests kubernetes/clusters/test/flux-system/flux-instance "not its row's identity"
  [ "$(grep -c '^signatures-check: ' <<< "$output")" -ge 7 ]

  # A second patch whose target, a regular expression as kustomize reads a target's kind and name,
  # also selects the sync source could change its block, so the check refuses it.
  local values=kubernetes/clusters/test/flux-system/flux-instance/app/values.yaml target
  for target in '{"kind": "OCIRepository", "name": "flux-.*"}' '{"kind": "OCI(Repository)?", "name": "flux-system"}' \
    '{"kind": "OCIRepository"}' '{"kind": "", "name": "flux-system"}'; do
    rm -r "$TREE"
    cp -R "$BATS_TEST_DIRNAME/fixtures/signatures/tree" "$TREE"
    edit "$values" ".instance.kustomize.patches += [{\"target\": $target, \"patch\": \"- op: replace\n  path: /spec/verify/matchOIDCIdentity/0/subject\n  value: '^x\$'\n\"}]"

    check

    fails_naming oci://charts.example.invalid/tree/manifests kubernetes/clusters/test/flux-system/flux-instance "more than one patch" ||
      { echo "accepted a second patch of target $target"; return 1; }
    # The sync source is still one of the tree's, in its place: the patches are the one failure.
    grep -qx 'signatures-check: 1 failure(s)' <<< "$output" || { echo "more failures than the patches of target $target"; return 1; }
  done
  # A patch of the sync source that is no JSON patch is refused, and is the one failure.
  rm -r "$TREE"
  cp -R "$BATS_TEST_DIRNAME/fixtures/signatures/tree" "$TREE"
  edit "$values" '.instance.kustomize.patches[1].patch = "apiVersion: source.toolkit.fluxcd.io/v1\nkind: OCIRepository\nmetadata:\n  name: flux-system\nspec:\n  verify:\n    provider: cosign\n"'

  check

  fails_naming oci://charts.example.invalid/tree/manifests kubernetes/clusters/test/flux-system/flux-instance "not a JSON patch"
  grep -qx 'signatures-check: 1 failure(s)' <<< "$output"
}

@test "The rows of the cluster's own artifacts are the identities their recipes sign and verify with" {
  local first second row app block work digest
  # The synced artifact, then the tools image.
  first=$(tree_rows | sed -n 1p)
  second=$(tree_rows | sed -n 2p)
  [ "$(jq -r .source <<< "$first")" = "$(instance_values | jq -r '.instance.sync.url')" ]
  [ "$(jq -r .source <<< "$second")" = oci://ghcr.io/eekaan/k8s-gitops/ci-tools ]
  # The synced artifact's row is the identity the instance's patch has today, and so are the Flux
  # Operator's two rows.
  [ "$(jq -r '[.signed, .issuer, .subject, .cluster // "cluster"] | join(" ")' <<< "$first")" = "keyless $GITHUB_ISSUER $PUBLISH cluster" ]
  [ "$(sync_verify | jq -r '.matchOIDCIdentity[0] | [.issuer, .subject] | join(" ")')" = "$GITHUB_ISSUER $PUBLISH" ]
  for app in flux-operator flux-instance; do
    row=$(tree_rows | jq -c "select(.source == \"oci://ghcr.io/controlplaneio-fluxcd/charts/$app\")")
    [ "$(jq -r '[.signed, .issuer, .subject, .cluster // "cluster"] | join(" ")' <<< "$row")" = "keyless $GITHUB_ISSUER $FLUX_CHARTS cluster" ]
    block=$(yq -o json -I0 '.spec.verify' "$ROOT/kubernetes/clusters/lab-sto2/flux-system/$app/app/ocirepository.yaml")
    [ "$block" = "{\"provider\":\"cosign\",\"matchOIDCIdentity\":[{\"issuer\":\"${GITHUB_ISSUER//\\/\\\\}\",\"subject\":\"${FLUX_CHARTS//\\/\\\\}\"}]}" ]
  done

  # The tools image's row, read as a literal, is what just tools-image-pin hands cosign: a copy of
  # what the pin reads, and a fake cosign that records the call and passes.
  [ "$(jq -r '[.signed, .cluster] | join(" ")' <<< "$second")" = "keyless false" ]
  work="$BATS_TEST_TMPDIR/pin"
  mkdir -p "$work/scripts" "$work/.dagger/modules/ci"
  cp "$ROOT/scripts/tools-image" "$work/scripts/"
  cp "$ROOT/versions.yaml" "$ROOT/mise.toml" "$work/"
  cp "$ROOT/.dagger/modules/ci/main.dang" "$work/.dagger/modules/ci/"
  stub cosign << EOF
{ printf '%q ' cosign "\$@"; echo; } >> "$RECORD/calls"
EOF
  digest="sha256:$(printf 'a tools image' | sha256sum | cut -d' ' -f1)"
  run env -i PATH="$BIN:$PATH" HOME="$BATS_TEST_TMPDIR/home" "$work/scripts/tools-image" pin "$digest"
  [ "$status" -eq 0 ]
  run argv "$(grep '^cosign verify ' "$RECORD/calls")"
  accepts --certificate-identity "$(jq -r .subject <<< "$second")" <<< "$output"
  accepts --certificate-oidc-issuer "$(jq -r .issuer <<< "$second")" <<< "$output"
  grep -qxF "ghcr.io/eekaan/k8s-gitops/ci-tools@$digest" <<< "$output"
  # And the synced artifact's row, read as a literal, is the identity of the publish workflow on main.
  [ "$(literal "$(jq -r .subject <<< "$first")")" = https://github.com/eekaan/k8s-gitops/.github/workflows/publish.yaml@refs/heads/main ]
  [ "$(literal "$(jq -r .issuer <<< "$first")")" = https://token.actions.githubusercontent.com ]
}

@test "An identity that is not anchored, or that leaves the publisher's repository or workflow open, fails the check" {
  # Every keyless row of the tree matches an identity of its own repository's workflow, and refuses
  # another repository, another workflow, an unescaped dot, a prefix and a suffix.
  local row issuer subject identity repository workflow bad mirrored field
  local -a others
  while IFS= read -r row; do
    issuer=$(jq -r .issuer <<< "$row")
    subject=$(jq -r .subject <<< "$row")
    identity=$(sample "$subject") || { echo "no sample for $subject"; return 1; }
    [[ $identity =~ $subject ]] || { echo "$subject does not match $identity"; return 1; }
    [[ $(literal "$issuer") =~ $issuer ]]
    mapfile -t others < <(dotless "$identity")
    rejects "$subject" "${others[@]}" "https://example.com/$identity" "$identity-x" "x$identity"
    mapfile -t others < <(dotless "$(literal "$issuer")")
    rejects "$issuer" "${others[@]}" "$(literal "$issuer").example.com" "https://example.com/$(literal "$issuer")"
    # The repository is the path after the host, and the workflow what follows it, up to the ref.
    if [[ $identity =~ ^https://github\.com/([^/]+/[^/]+)/(\.github/workflows/[^@]+)@ ]]; then
      repository=${BASH_REMATCH[1]} workflow=${BASH_REMATCH[2]}
      rejects "$subject" "${identity/$repository\//${repository}x/}" "${identity/$repository\//${repository%?}/}" \
        "${identity/$workflow/${workflow%.*}x.${workflow##*.}}" "${identity/@/x@}"
    elif [[ $identity =~ ^https://circleci\.com/api/v2/projects/([^/]+)/ ]]; then
      repository=${BASH_REMATCH[1]}
      rejects "$subject" "${identity/$repository/${repository%?}0}" "${identity/$repository/${repository%?}}"
    else
      echo "a subject of no form the test knows: $subject"
      return 1
    fi
  done < <(tree_rows | jq -c 'select(.signed == "keyless")')

  # The fixture's row verified before merge alone, so no block follows it: each pattern fails the
  # check, naming the source and the field.
  mirrored=$(row_index oci://charts.example.invalid/charts/mirrored)
  for bad in \
    'subject=https://code\.example\.invalid/example/mirror/\.ci/mirror\.yml@refs/heads/main$' \
    'subject=^https://code\.example\.invalid/example/mirror/\.ci/mirror\.yml@refs/heads/main' \
    'subject=^https://code.example\.invalid/example/mirror/\.ci/mirror\.yml@refs/heads/main$' \
    'subject=^https://code\.example\.invalid/example/mirror/\.ci/[a-z]+\.yml@refs/heads/main$' \
    'subject=^https://code\.example\.invalid/example/[^/]+/\.ci/mirror\.yml@refs/heads/main$' \
    'subject=^https://code\.example\.invalid/example/mirror/\.ci/mirror\.yml@refs/tags/v\d+$' \
    'subject=^https://code\.example\.invalid/example/mirror/\.ci/mirror\.yml@refs/tags/.+$' \
    'subject=^https://code\.example\.invalid/example/mirror/\.ci/mirror\.yml@refs/tags/v[0-9]+?$' \
    'subject=(?i)^https://code\.example\.invalid/example/mirror/\.ci/mirror\.yml@refs/heads/main$' \
    'subject=^https://code\.example\.invalid/example/mirror/\.ci/mirror\.yml@refs/heads/main|x$' \
    'subject=^https://code\.example\.invalid/example/mirror/\.ci/mirror\.yml@refs/heads/main$|^x$' \
    'subject=^https://code\.example\.invalid/example/mirror/\.ci/mirror\.yml@refs/heads/[\w]+$' \
    'subject=^https://code\.example\.invalid/example/mirror/\.ci/mirror\.yml@refs/heads/ma\in$' \
    'issuer=^https://token\.ci\.example\.invalid' \
    'issuer=https://token\.ci\.example\.invalid$' \
    'issuer=^https://token.ci\.example\.invalid$' \
    'issuer=^https://token\.ci\.example\.(invalid|test)$' \
    'issuer=^https://[a-z]+\.ci\.example\.invalid$'; do
    field=${bad%%=*}
    cp "$BATS_TEST_DIRNAME/fixtures/signatures/tree/signatures.yaml" "$TREE/signatures.yaml"
    BAD=${bad#*=} yq -i ".sources[$mirrored].$field = strenv(BAD)" "$TREE/signatures.yaml"

    check

    fails_naming oci://charts.example.invalid/charts/mirrored "$field" || { echo "accepted $bad"; return 1; }
  done

  # A ref of the forms Go and POSIX read alike passes: a bracket expression, a quantifier, a group
  # and an alternation inside it.
  cp "$BATS_TEST_DIRNAME/fixtures/signatures/tree/signatures.yaml" "$TREE/signatures.yaml"
  BAD='^https://code\.example\.invalid/example/mirror/\.ci/mirror\.yml@refs/(heads/main|tags/v[0-9]{1,3}\.[0-9]+)$' \
    yq -i ".sources[$mirrored].subject = strenv(BAD)" "$TREE/signatures.yaml"
  check
  [ "$status" -eq 0 ]
}

@test "the verification passes when every source is signed as its row says, with the row's identity and nothing else" {
  local call
  as_rows

  verify

  [ "$status" -eq 0 ]
  [ "$(line_of oci://charts.example.invalid/tree/manifests)" = "pass  oci://charts.example.invalid/tree/manifests: verified keyless at main" ]
  [ "$(line_of oci://charts.example.invalid/example/tree/ci-tools)" = "pass  oci://charts.example.invalid/example/tree/ci-tools: verified keyless at $TOOLS_DIGEST" ]
  [ "$(line_of https://charts.example.invalid/classic)" = "pass  https://charts.example.invalid/classic: unsigned, a Helm repository: nothing to fetch" ]
  [ "$(line_of oci://charts.example.invalid/charts/hello)" = "pass  oci://charts.example.invalid/charts/hello: verified keyless at 2.0.0" ]
  [ "$(line_of oci://charts.example.invalid/charts/keyed)" = "pass  oci://charts.example.invalid/charts/keyed: verified with signatures/keyed.pem at 4.0.0" ]
  [ "$(line_of oci://charts.example.invalid/charts/plain)" = "pass  oci://charts.example.invalid/charts/plain: unsigned: no signature at 3.0.0" ]
  # The keyless rows with their two regular-expression flags and a time bound, nothing else.
  call=$(grep -F 'charts.example.invalid/charts/hello:2.0.0' "$RECORD/calls")
  [ "$call" = "$(printf '%q ' cosign verify --certificate-oidc-issuer-regexp '^https://token\.ci\.example\.invalid$' \
    --certificate-identity-regexp '^https://code\.example\.invalid/example/hello/\.ci/release\.yml@refs/heads/main$' \
    --timeout 120s charts.example.invalid/charts/hello:2.0.0)" ]
  # The key row with its key, no transparency log and its digest algorithm.
  call=$(grep -F 'charts.example.invalid/charts/keyed:4.0.0' "$RECORD/calls")
  [ "$call" = "$(printf '%q ' cosign verify --key "$TREE/signatures/keyed.pem" --insecure-ignore-tlog \
    --signature-digest-algorithm sha512 --timeout 120s charts.example.invalid/charts/keyed:4.0.0)" ]
  # The tools image by its recorded digest; the Helm repository is not asked at all.
  grep -qF "charts.example.invalid/example/tree/ci-tools@$TOOLS_DIGEST" "$RECORD/calls"
  run grep -c '^cosign ' "$RECORD/calls"
  [ "$output" -eq 8 ]
  run grep -cF 'charts.example.invalid/classic' "$RECORD/calls"
  [ "$output" -eq 0 ]
}

@test "A source whose signature does not match its row fails the verification, naming the source" {
  local code=https://code.example.invalid/example other="$BATS_TEST_TMPDIR/other.pem"
  as_rows
  # Another subject, in each format, and a key signature by another key or over another digest.
  signed_keyless charts.example.invalid/charts/hello:2.0.0 "$code/hellp/.ci/release.yml@refs/heads/main" bundle
  signed_keyless charts.example.invalid/flux/operator:1.0.0 "$code/charts/.ci/release.yml@refs/tags/v1.0.0-rc.1"
  signed_keyless charts.example.invalid/tree/manifests:main "$code/tree/.ci/publish.yml@refs/heads/feature"
  sed 's/^MFkw/MFkx/' "$TREE/signatures/keyed.pem" > "$other"
  signed_key charts.example.invalid/charts/keyed:4.0.0 "$other" sha512

  verify

  [ "$status" -ne 0 ]
  [[ $(line_of oci://charts.example.invalid/charts/hello) == "FAIL  oci://charts.example.invalid/charts/hello: "* ]]
  [ "$(line_of oci://charts.example.invalid/flux/operator)" = "FAIL  oci://charts.example.invalid/flux/operator: the signature at 1.0.0 does not match the row" ]
  [ "$(line_of oci://charts.example.invalid/tree/manifests)" = "FAIL  oci://charts.example.invalid/tree/manifests: the signature at main does not match the row" ]
  [ "$(line_of oci://charts.example.invalid/charts/keyed)" = "FAIL  oci://charts.example.invalid/charts/keyed: the signature at 4.0.0 does not match the row" ]
  # Every other row still has its line.
  [ "$(line_of oci://charts.example.invalid/flux/instance)" = "pass  oci://charts.example.invalid/flux/instance: verified keyless at 1.0.0" ]
  [ "$(grep -c '^\(pass\|FAIL\)  ' <<< "$output")" -eq 9 ]

  # The key's signature over SHA-256 where the row says SHA-512, a tag that is not there, no signature
  # where the row names one, and a cosign that does not finish in its time.
  as_rows
  signed_key charts.example.invalid/charts/keyed:4.0.0 "$TREE/signatures/keyed.pem" sha256
  rm "$STATE/refs/charts.example.invalid_flux_instance_1.0.0"
  rm "$STATE/signatures/charts.example.invalid_charts_mirrored_5.0.0"
  verify
  [ "$status" -ne 0 ]
  [ "$(line_of oci://charts.example.invalid/charts/keyed)" = "FAIL  oci://charts.example.invalid/charts/keyed: the signature at 4.0.0 does not match the row" ]
  [ "$(line_of oci://charts.example.invalid/flux/instance)" = "FAIL  oci://charts.example.invalid/flux/instance: the tag or digest 1.0.0 is not there" ]
  [ "$(line_of oci://charts.example.invalid/charts/mirrored)" = "FAIL  oci://charts.example.invalid/charts/mirrored: no signature at 5.0.0, where the row names one" ]
}

@test "a cosign that does not finish in its time, or fails without an outcome of its own, fails the verification" {
  as_rows
  mkdir -p "$STATE/slow"
  echo 3 > "$STATE/slow/charts.example.invalid_charts_hello_2.0.0"
  with SIGNATURES_VERIFY_TIMEOUT=2

  verify

  [ "$status" -ne 0 ]
  [ "$(line_of oci://charts.example.invalid/charts/hello)" = "FAIL  oci://charts.example.invalid/charts/hello: cosign did not finish within 2s at 2.0.0" ]
  grep -qF -- '--timeout 2s' "$RECORD/calls"

  [ "$(line_of oci://charts.example.invalid/charts/plain)" = "pass  oci://charts.example.invalid/charts/plain: unsigned: no signature at 3.0.0" ]
  # A bundle whose identity does not match exits 1, as any other failure does: it fails, and says it
  # had no outcome of its own.
  rm -r "$STATE/slow"
  as_rows
  signed_keyless charts.example.invalid/charts/hello:2.0.0 https://code.example.invalid/example/hellp/.ci/release.yml@refs/heads/main bundle
  without SIGNATURES_VERIFY_TIMEOUT
  verify
  [ "$status" -ne 0 ]
  [ "$(line_of oci://charts.example.invalid/charts/hello)" = "FAIL  oci://charts.example.invalid/charts/hello: cosign failed at 2.0.0 with no outcome of its own (exit 1), as for a bundle that does not match the row" ]
}

@test "A source listed as unsigned that carries a signature fails the verification" {
  local format
  for format in legacy bundle; do
    as_rows
    signed_keyless charts.example.invalid/charts/plain:3.0.0 https://code.example.invalid/example/plain/.ci/release.yml@refs/heads/main "$format"

    verify

    [ "$status" -ne 0 ] || { echo "passed with a $format signature on the unsigned source"; return 1; }
    [[ $(line_of oci://charts.example.invalid/charts/plain) == "FAIL  oci://charts.example.invalid/charts/plain: "* ]]
    [ "$(line_of oci://charts.example.invalid/charts/hello)" = "pass  oci://charts.example.invalid/charts/hello: verified keyless at 2.0.0" ]
  done
  # A legacy signature has an exit code of its own, and the line says what it found.
  as_rows
  signed_key charts.example.invalid/charts/plain:3.0.0 "$TREE/signatures/keyed.pem" sha256
  verify
  [ "$(line_of oci://charts.example.invalid/charts/plain)" = "FAIL  oci://charts.example.invalid/charts/plain: a signature at 3.0.0, where the row says unsigned" ]
}

@test "A registry that cannot be reached fails the verification, naming the source, and the offline check passes without it" {
  as_rows
  # A source on Docker Hub, whose registry host is registry-1.docker.io, signed as its row says.
  put kubernetes/apps/base/demo/plain/app/hub.yaml << 'EOF'
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: hub
spec:
  interval: 1h
  url: oci://docker.io/example/chart
  ref:
    tag: 6.0.0
EOF
  edit kubernetes/apps/base/demo/plain/app/kustomization.yaml '.resources += ["hub.yaml"]'
  edit signatures.yaml '.sources += [{"source": "oci://docker.io/example/chart", "signed": "unsigned", "reason": "x"}]'
  edit signatures.yaml '.sources = .sources[0:2] + (.sources[2:] | sort_by(.source))'
  serve docker.io/example/chart:6.0.0
  # Every other source is on a registry that cannot be resolved: cosign would fail with exit 1.
  echo unresolved > "$STATE/hosts/charts.example.invalid"

  verify

  [ "$status" -ne 0 ]
  [ "$(line_of oci://charts.example.invalid/charts/plain)" = "FAIL  oci://charts.example.invalid/charts/plain: the registry charts.example.invalid could not be reached" ]
  [ "$(line_of oci://charts.example.invalid/charts/hello)" = "FAIL  oci://charts.example.invalid/charts/hello: the registry charts.example.invalid could not be reached" ]
  [ "$(line_of oci://docker.io/example/chart)" = "pass  oci://docker.io/example/chart: unsigned: no signature at 6.0.0" ]
  # The probe asked Docker Hub's registry host, and cosign ran only where the probe was answered.
  grep -qF 'https://registry-1.docker.io/v2/' "$RECORD/calls"
  run grep -F 'https://docker.io/' "$RECORD/calls"
  [ "$status" -eq 1 ]
  [ "$(grep '^cosign ' "$RECORD/calls")" = "$(printf '%q ' cosign verify --certificate-oidc-issuer-regexp '^$' --certificate-identity-regexp '^$' --timeout 120s docker.io/example/chart:6.0.0)" ]

  # One that does not answer in time, one that limits anonymous requests and one that fails.
  for answer in silent:'could not be reached' limited:'limits anonymous requests' down:'could not be reached'; do
    rm -f "$RECORD/calls"
    echo "${answer%%:*}" > "$STATE/hosts/charts.example.invalid"
    verify
    [ "$status" -ne 0 ]
    [ "$(line_of oci://charts.example.invalid/charts/plain)" = "FAIL  oci://charts.example.invalid/charts/plain: the registry charts.example.invalid ${answer#*:}" ] || { echo "for ${answer%%:*}"; return 1; }
    [ "$(grep -c '^cosign ' "$RECORD/calls")" -eq 1 ]
  done

  # One that answers the probe and then limits cosign's requests: the unsigned source fails too, as
  # only cosign's own "no signatures found" rules a signature out.
  rm -f "$RECORD/calls"
  echo limits-pulls > "$STATE/hosts/charts.example.invalid"
  verify
  [ "$status" -ne 0 ]
  [ "$(line_of oci://charts.example.invalid/charts/plain)" = "FAIL  oci://charts.example.invalid/charts/plain: cosign failed at 3.0.0 with no outcome of its own (exit 1), as for a bundle or a registry's error, so no signature was ruled out" ]
  [ "$(line_of oci://charts.example.invalid/charts/hello)" = "FAIL  oci://charts.example.invalid/charts/hello: cosign failed at 2.0.0 with no outcome of its own (exit 1), as for a bundle that does not match the row" ]
  echo unresolved > "$STATE/hosts/charts.example.invalid"

  # The offline check passes with every registry out of reach, and asks none of them.
  rm -f "$RECORD/calls"
  run env -i PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" "$CHECK" "$TREE"
  [ "$status" -eq 0 ]
  [ ! -e "$RECORD/calls" ]
}

@test "The verification runs without credentials and prints a source and a reason on each line, nothing else" {
  local login file sources name own text
  as_rows
  # The caller's logins where cosign's default keychain looks, its own TUF root, every variable of
  # cosign env that moves where a signature is read from or what is trusted, and secrets. The run's
  # own Docker configuration always exists, so the keychain, as the fake does, reads it and never
  # reaches REGISTRY_AUTH_FILE or podman's places: that the run unsets those too is defence in depth
  # this test cannot tell apart.
  login=$(printf '{"auths":{"charts.example.invalid":{"auth":"%s"}}}' "$(printf 'user:caller-login' | base64 -w0)")
  for file in home/.docker/config.json docker/config.json auth/registry-auth.json run/containers/auth.json config/containers/auth.json; do
    mkdir -p "$BATS_TEST_TMPDIR/$(dirname "$file")"
    printf '%s\n' "$login" > "$BATS_TEST_TMPDIR/$file"
  done
  mkdir -p "$BATS_TEST_TMPDIR/caller-tuf"
  with \
    DOCKER_CONFIG="$BATS_TEST_TMPDIR/docker" \
    REGISTRY_AUTH_FILE="$BATS_TEST_TMPDIR/auth/registry-auth.json" \
    XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run" \
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config" \
    TUF_ROOT="$BATS_TEST_TMPDIR/caller-tuf" \
    TUF_MIRROR=https://tuf.example.invalid \
    TUF_ROOT_JSON="$BATS_TEST_TMPDIR/caller-tuf/root.json" \
    COSIGN_REPOSITORY=charts.example.invalid/elsewhere \
    COSIGN_EXPERIMENTAL=1 \
    COSIGN_DOCKER_MEDIA_TYPES=1 \
    COSIGN_MAX_ATTACHMENT_SIZE=1K \
    SIGSTORE_ROOT_FILE="$BATS_TEST_TMPDIR/root.pem" \
    SIGSTORE_REKOR_PUBLIC_KEY="$BATS_TEST_TMPDIR/rekor.pem" \
    SIGSTORE_CT_LOG_PUBLIC_KEY_FILE="$BATS_TEST_TMPDIR/ctlog.pem" \
    SIGSTORE_TSA_CERTIFICATE_FILE="$BATS_TEST_TMPDIR/tsa.pem" \
    SIGSTORE_ID_TOKEN=caller-identity-token \
    GITHUB_TOKEN=caller-github-token \
    AWS_SECRET_ACCESS_KEY=caller-secret-key \
    OS_APPLICATION_CREDENTIAL_SECRET=caller-cloud-secret

  verify

  [ "$status" -eq 0 ]
  # cosign read no login and ran verify alone, once for each OCI row.
  [ "$(sort -u "$RECORD/cosign-credentials")" = 'verify anonymous' ]
  if grep '^cosign ' "$RECORD/calls" | grep -qv '^cosign verify '; then
    echo "cosign ran another subcommand than verify"
    return 1
  fi
  for file in "$RECORD"/env.cosign.*; do
    for name in REGISTRY_AUTH_FILE TUF_MIRROR TUF_ROOT_JSON COSIGN_REPOSITORY COSIGN_EXPERIMENTAL COSIGN_DOCKER_MEDIA_TYPES \
      COSIGN_MAX_ATTACHMENT_SIZE SIGSTORE_ROOT_FILE SIGSTORE_REKOR_PUBLIC_KEY SIGSTORE_CT_LOG_PUBLIC_KEY_FILE \
      SIGSTORE_TSA_CERTIFICATE_FILE SIGSTORE_ID_TOKEN GITHUB_TOKEN AWS_SECRET_ACCESS_KEY OS_APPLICATION_CREDENTIAL_SECRET; do
      ! grep -q "^$name=" "$file" || { echo "cosign saw $name"; return 1; }
    done
    # A Docker configuration, a home and a TUF root of the run's own, in its temporary directory, which
    # is gone once the run has ended.
    for name in DOCKER_CONFIG HOME TUF_ROOT; do
      own=$(sed -n "s/^$name=//p" "$file")
      [[ $own == "$BATS_TEST_TMPDIR"/tmp.* && ! -e $own ]] || { echo "cosign's $name is not the run's own: $own"; return 1; }
    done
  done
  for file in "$RECORD"/env.curl.*; do
    ! grep -qE '^(GITHUB_TOKEN|AWS_SECRET_ACCESS_KEY|OS_APPLICATION_CREDENTIAL_SECRET)=' "$file" || { echo "curl saw a secret"; return 1; }
  done

  # One line per row, in the rows' order: the verdict, the source and a reason of the check's own.
  sources=$(yq '.sources[].source' "$TREE/signatures.yaml")
  [ "$(sed -E 's/^(pass|FAIL)  ([^ ]+): .+$/\2/' <<< "$output")" = "$sources" ]
  [ -z "$stderr" ]
  # No address, no path of the machine and nothing cosign printed, when cosign fails.
  signed_keyless charts.example.invalid/charts/hello:2.0.0 https://code.example.invalid/example/hellp/.ci/release.yml@refs/heads/main
  verify
  [ "$status" -ne 0 ]
  for text in 192.0.2 cosign-says-this "$BATS_TEST_TMPDIR" "$HOME" Error: /tmp; do
    [[ $output$stderr != *"$text"* ]] || { echo "printed $text"; return 1; }
  done
  [ "$(sed -E 's/^(pass|FAIL)  ([^ ]+): .+$/\2/' <<< "$output")" = "$sources" ]

  # A setup error is one line: cosign is not on PATH, which holds the tools the offline rules need,
  # bash and dirname, and nothing else.
  rm "$BIN/cosign"
  for name in yq jq kustomize flux bash dirname; do
    ln -s "$(command -v "$name")" "$BIN/$name"
  done
  run env -i PATH="$BIN" "${ENVIRONMENT[@]}" "$CHECK" verify "$TREE"
  [ "$status" -ne 0 ]
  [ "$output" = "signatures-check: cosign not found on PATH" ]
}

@test "no value the caller gives a variable the pinned cosign's env lists reaches cosign" {
  local cosign names name file
  # The pinned binary's own list, offline and in an empty environment, so it prints names and no
  # value of the caller's; a cosign that lists another variable holds the check to it too.
  cosign=$(type -P cosign) || { echo "the pinned cosign is not on PATH"; return 1; }
  names=$(env -i HOME="$BATS_TEST_TMPDIR/home" "$cosign" env --show-descriptions=false | sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*$/\1/p')
  grep -qx COSIGN_REPOSITORY <<< "$names" || { echo "cosign env lists no variables: $names"; return 1; }
  as_rows
  while IFS= read -r name; do
    with "$name=caller-$name"
  done <<< "$names"

  verify

  [ "$status" -eq 0 ]
  [ -e "$RECORD/env.cosign.1" ]
  for file in "$RECORD"/env.cosign.*; do
    while IFS= read -r name; do
      ! grep -qxF "$name=caller-$name" "$file" || { echo "cosign saw the caller's $name"; return 1; }
    done <<< "$names"
  done
}

@test "The verification is a group of its own, outside static and outside the publish run" {
  local dump
  dump=$(just --justfile "$ROOT/justfile" --dump --dump-format json)
  # signatures is a group, with one check, signatures-verify, which runs the verification.
  jq -e '[.recipes.checks.dependencies[].recipe] | index("signatures")' <<< "$dump" > /dev/null
  [ "$(jq -c '[.recipes.signatures.dependencies[] | [.recipe, .arguments]]' <<< "$dump")" = '[["signatures-verify",[]]]' ]
  [ "$(jq -c '.recipes["signatures-verify"].body' <<< "$dump")" = '[["scripts/signatures-check verify"]]' ]
  # The offline check is one of static's, and the verification is not.
  jq -e '[.recipes.static.dependencies[].recipe] | index("signatures-check")' <<< "$dump" > /dev/null
  [ "$(jq '[.recipes.static.dependencies[].recipe] | index("signatures-verify")' <<< "$dump")" = null ]
  [ "$(jq -c '.recipes["signatures-check"].body' <<< "$dump")" = '[["scripts/signatures-check"]]' ]
  # Of the groups, only signatures runs the verification, and only static the offline check.
  [ "$(jq -r '.recipes as $r | [$r.checks.dependencies[].recipe | select(. as $g | $r[$g].dependencies | any(.recipe == "signatures-verify"))] | join(" ")' <<< "$dump")" = signatures ]
  [ "$(jq -r '.recipes as $r | [$r.checks.dependencies[].recipe | select(. as $g | $r[$g].dependencies | any(.recipe == "signatures-check"))] | join(" ")' <<< "$dump")" = static ]
  # The CI matrix lists the group.
  run env -u GITHUB_OUTPUT just --justfile "$ROOT/justfile" ci-groups
  [ "$status" -eq 0 ]
  jq -e 'index("signatures")' <<< "$output" > /dev/null
  # The publish run runs neither: its one step is just publish, which runs scripts/publish alone, and
  # that script runs kubernetes-check as its check.
  [ "$(jq -c '.recipes.publish.body' <<< "$dump")" = '[["scripts/publish"]]' ]
  run grep -nE 'signatures-(check|verify)|signatures\.yaml' "$ROOT/scripts/publish" "$ROOT/.github/workflows/publish.yaml"
  [ "$status" -eq 1 ]
}

@test "The table of who signs in the docs is the rows of signatures.yaml" {
  local table rows line source signed verified why row repository subject identity workflow ref expected
  table=$(docs_table)
  [ -n "$table" ]
  # The same sources, in the same order, one line each.
  [ "$(cut -f1 <<< "$table")" = "$(tree_rows | jq -r .source)" ]
  while IFS=$'\t' read -r source signed verified why; do
    row=$(tree_rows | jq -c --arg source "$source" 'select(.source == $source)')
    case $(jq -r '.signed + " " + (if .cluster == false then "merge" else "cluster" end)' <<< "$row") in
      "keyless cluster") [ "$verified" = "before merge and by the cluster" ] ;;
      "keyless merge" | "key merge") [ "$verified" = "before merge alone" ] ;;
      "unsigned cluster") [ "$verified" = "unsigned" ] ;;
      *) echo "$source: a row of no kind the table knows"; return 1 ;;
    esac || { echo "$source: verified says $verified"; return 1; }
    # Who signs it: the repository, workflow file and ref a keyless subject of GitHub names, the key
    # file, or a dash.
    case $(jq -r .signed <<< "$row") in
      keyless)
        subject=$(jq -r .subject <<< "$row")
        identity=$(sample "$subject") || { echo "$source: no sample for $subject"; return 1; }
        if [[ $identity =~ ^https://github\.com/([^/]+/[^/]+)/\.github/workflows/([^@/]+)@refs/(heads|tags)/(.+)$ ]]; then
          repository=${BASH_REMATCH[1]} workflow=${BASH_REMATCH[2]} ref=${BASH_REMATCH[4]}
          if [[ ${BASH_REMATCH[3]} == tags ]]; then
            [[ $subject == *'@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "$source: a tag the table cannot name: $subject"; return 1; }
            expected="$repository, \`$workflow\` at a version tag"
          else
            expected="$repository, \`$workflow\` on \`$ref\`"
          fi
          [ "$signed" = "$expected" ] || { echo "$source: signed by '$signed', where the subject names '$expected'"; return 1; }
        else
          [ -n "$signed" ]
        fi
        ;;
      key) [[ $signed == *"$(jq -r .key <<< "$row")"* ]] || { echo "$source: signed by does not name the key"; return 1; } ;;
      unsigned) [ "$signed" = "—" ] || { echo "$source: signed by '$signed', not a dash"; return 1; } ;;
    esac
    # A reason in a few words for each row that has one.
    if [[ $(jq -r '.reason // ""' <<< "$row") != "" ]]; then
      [ -n "$why" ] || { echo "$source: no reason in the table"; return 1; }
    fi
  done <<< "$table"
}

@test "A source the cluster did not verify fails the cluster's check, naming it" {
  local cilium sync
  cilium=$(identity oci://quay.io/cilium/charts/cilium)
  sync=$(identity oci://ghcr.io/eekaan/k8s-gitops/manifests)
  {
    ocirepository flux-system flux-system oci://ghcr.io/eekaan/k8s-gitops/manifests "$sync" True True
    ocirepository kube-system cilium oci://quay.io/cilium/charts/cilium "$cilium" True True
    ocirepository kube-system cilium-unverified oci://quay.io/cilium/charts/cilium "$cilium" False False 2 VerificationError
    ocirepository kube-system cilium-stale oci://quay.io/cilium/charts/cilium "$cilium" True True 1
    ocirepository kube-system cilium-unblocked oci://quay.io/cilium/charts/cilium
    ocirepository kube-system cilium-other oci://quay.io/cilium/charts/cilium '{"provider":"cosign","matchOIDCIdentity":[{"issuer":"^x$","subject":"^x$"}]}' True True
    ocirepository kube-system cilium-notready oci://quay.io/cilium/charts/cilium "$cilium" False True 2 ArtifactFailed
    ocirepository kube-system cilium-behind oci://quay.io/cilium/charts/cilium "$cilium" True True 2 Succeeded 1
    ocirepository kyverno kyverno oci://ghcr.io/kyverno/charts/kyverno
    ocirepository cert-manager cert-manager oci://quay.io/jetstack/charts/cert-manager "$cilium" True True
    ocirepository demo unlisted oci://charts.example.invalid/unlisted
  } | jq -s '{apiVersion: "v1", kind: "List", items: .}' > "$STATE/ocirepositories.json"

  cluster_signatures

  [ "$status" -ne 0 ]
  [[ $(grep -F '  flux-system/flux-system: ' <<< "$output") == "pass  flux-system/flux-system: "* ]]
  [[ $(grep -F '  kube-system/cilium: ' <<< "$output") == "pass  kube-system/cilium: "* ]]
  [[ $(grep -F '  kyverno/kyverno: ' <<< "$output") == "pass  kyverno/kyverno: "* ]]
  [ "$(grep -F '  kube-system/cilium-unverified: ' <<< "$output")" = "FAIL  kube-system/cilium-unverified: not verified: SourceVerified False (VerificationError)" ]
  [ "$(grep -F '  kube-system/cilium-stale: ' <<< "$output")" = "FAIL  kube-system/cilium-stale: not verified for its current generation 2" ]
  [ "$(grep -F '  kube-system/cilium-unblocked: ' <<< "$output")" = "FAIL  kube-system/cilium-unblocked: no verify block, which its row gives it" ]
  [ "$(grep -F '  kube-system/cilium-other: ' <<< "$output")" = "FAIL  kube-system/cilium-other: a verify block that is not its row's identity" ]
  [ "$(grep -F '  kube-system/cilium-notready: ' <<< "$output")" = "FAIL  kube-system/cilium-notready: verified, not Ready: ArtifactFailed" ]
  # Ready for the generation before, while the current one is still being reconciled.
  [ "$(grep -F '  kube-system/cilium-behind: ' <<< "$output")" = "FAIL  kube-system/cilium-behind: verified, not Ready for its current generation 2" ]
  [ "$(grep -F '  cert-manager/cert-manager: ' <<< "$output")" = "FAIL  cert-manager/cert-manager: a verify block its row does not give it" ]
  [ "$(grep -F '  demo/unlisted: ' <<< "$output")" = "FAIL  demo/unlisted: no row of signatures.yaml has its source" ]
  # Names and reasons, never an address or a message.
  [[ $output != *192.0.2* && $output != *203.0.113* && $output != *"stored artifact"* ]]
  # It only reads: kubectl get, and nothing else.
  if grep '^kubectl ' "$RECORD/calls" | grep -qv '^kubectl get '; then
    echo "kubectl ran another verb than get"
    return 1
  fi

  # Every object as its row says passes.
  {
    ocirepository flux-system flux-system oci://ghcr.io/eekaan/k8s-gitops/manifests "$sync" True True
    ocirepository kube-system cilium oci://quay.io/cilium/charts/cilium "$cilium" True True
    ocirepository kyverno kyverno oci://ghcr.io/kyverno/charts/kyverno
  } | jq -s '{apiVersion: "v1", kind: "List", items: .}' > "$STATE/ocirepositories.json"
  cluster_signatures
  [ "$status" -eq 0 ]
  [ "$(grep -c '^pass  ' <<< "$output")" -eq 3 ]

  # A cluster with no OCIRepository at all has not even the sync source.
  jq -n '{apiVersion: "v1", kind: "List", items: []}' > "$STATE/ocirepositories.json"
  cluster_signatures
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  OCIRepositories: the cluster holds none, not even the sync source"* ]]

  # kubectl's own errors, which name the API server's address, are not printed.
  : > "$STATE/kubectl-fails"
  cluster_signatures
  [ "$status" -ne 0 ]
  [[ $output != *192.0.2* && $output != *"Unable to connect"* ]]
  [[ $output == *"FAIL  OCIRepositories: kubectl could not read them"* ]]
}
