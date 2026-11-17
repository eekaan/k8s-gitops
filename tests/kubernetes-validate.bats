#!/usr/bin/env bats
# Proves the scenarios of features/kubernetes-layout.feature that scripts/kubernetes-validate
# checks; each test carries its scenario's title.
# Needs kustomize, yq, jq, helm, flux and kubeconform on PATH (the versions pinned for the
# repository). The fixture tree in tests/fixtures/kubernetes-validate/tree validates against the
# small schemas beside it and renders the chart packaged from its charts/, so nothing is fetched;
# the one test of the repository's own tree fetches the real schemas and charts from their public
# sources.

setup_file() {
  # Helm's settings, and the Docker configuration it reads registry logins from, stay in the run's
  # own directory.
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG"
  export RENDER_CHART_CACHE="$BATS_FILE_TMPDIR/charts"
  helm package "$BATS_TEST_DIRNAME/fixtures/kubernetes-validate/charts/hooked" \
    --destination "$RENDER_CHART_CACHE/charts.example.invalid/hooked/1.0.0" >/dev/null
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/kubernetes-validate"
  VALIDATE="$REPO/scripts/kubernetes-validate"
  # A small tree that passes kubernetes-check and this one: one cluster with Flux's own two
  # applications, one namespace, one application. Each scenario breaks one rule in it.
  TREE="$BATS_TEST_TMPDIR/tree"
  cp -R "$FIXTURES/tree" "$TREE"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  export KUBERNETES_VALIDATE_SCHEMAS="$FIXTURES/schemas"
}

# put PATH: writes stdin to PATH in the fixture tree.
put() {
  mkdir -p "$(dirname "$TREE/$1")"
  cat >"$TREE/$1"
}

# validate: runs the check on the fixture tree, reading nothing from the test's own input; its output
# shows when a test fails.
validate() {
  run "$VALIDATE" "$TREE" </dev/null
  echo "$output"
}

# with_stdin STATE COMMAND...: runs COMMAND as run does, with its standard input in STATE: closed;
# null, at /dev/null; silent, a pipe that stays open and carries nothing; or carried, a pipe that
# carries $CARRIED and ends. A command still running after two minutes is ended, with status 124.
with_stdin() {
  local state=$1 fd
  shift
  case $state in
    # The shell that becomes the command closes it: closed for run instead, the command would find
    # a pipe of run's at descriptor 0.
    closed) run bash -c 'exec "$@" <&-' bash timeout 120 "$@" ;;
    null) run timeout 120 "$@" </dev/null ;;
    silent)
      [ -p "$BATS_TEST_TMPDIR/silent" ] || mkfifo "$BATS_TEST_TMPDIR/silent"
      # Open here for reading and writing: the pipe has a writer for as long as the command runs.
      exec {fd}<>"$BATS_TEST_TMPDIR/silent"
      run timeout 120 "$@" <&"$fd"
      exec {fd}>&-
      ;;
    carried) run timeout 120 "$@" < <(printf '%s\n' "$CARRIED") ;;
    *) echo "with_stdin: no state $state"; return 1 ;;
  esac
}

# fails_naming WHAT TEXT: the check failed, and one of its messages names WHAT and says TEXT.
fails_naming() {
  [ "$status" -ne 0 ] || { echo "expected the check to fail"; return 1; }
  grep -F -- "$1" <<<"$output" | grep -qF -- "$2" ||
    { echo "no failure message naming '$1' that says '$2'"; return 1; }
}

# refused_line FILE WORDS...: a failure message that names FILE and every one of WORDS.
refused_line() {
  local file=$1 line word
  shift
  line=$(grep -F -- "$file" <<<"$output") || { echo "no failure message names $file"; return 1; }
  for word in "$@"; do
    grep -qF -- "$word" <<<"$line" || { echo "no message that names $file says '$word':"; echo "$line"; return 1; }
  done
}

# overlay_add PATH: lists PATH, a ks.yaml, in the fixture cluster's overlay.
overlay_add() {
  yq -i ".resources += [\"$1\"]" "$TREE/kubernetes/apps/overlays/test/kustomization.yaml"
}

# hooked_app VALUES: the enabled application hooked, whose release installs the fixture chart with
# the values VALUES (a YAML map) and runs its Helm tests.
hooked_app() {
  local dir=kubernetes/apps/base/demo/hooked values
  if [ ! -d "$TREE/$dir" ]; then
    cp -R "$FIXTURES/hooked" "$TREE/$dir"
    overlay_add ../../base/demo/hooked/ks.yaml
  fi
  values="$(yq -o json -I0 '. // {}' <<<"$1")"
  yq -i ".spec.values = $values" "$TREE/$dir/app/helmrelease.yaml"
}

# definitions_app: the enabled application defs, whose app/ applies definitions from a GitRepository
# (Gizmo, in a Kustomization's directory) and from an OCIRepository's unpacked chart (Sprocket, in a
# directory of plain manifests). The sources are the fixtures' schemas/sources, in place of the
# network.
definitions_app() {
  local dir=kubernetes/apps/base/demo/defs
  cp -R "$FIXTURES/definitions" "$TREE/$dir"
  overlay_add ../../base/demo/defs/ks.yaml
}

# definitions_app_reset: the definitions application as the fixtures hold it.
definitions_app_reset() {
  rm -rf "$TREE/kubernetes/apps/base/demo/defs"
  cp -R "$FIXTURES/definitions" "$TREE/kubernetes/apps/base/demo/defs"
}

# operator_app: the enabled application operator, which holds the OCIRepository doohickey of an
# operator's chart at the tag 1.0.0 and no definition: the operator installs its own, Doohickey of
# operator.example.invalid, when it starts, from the files it embeds, which the fixtures' sources
# publish in github.com/example-org/doohickey, under deploy/crds, at the tag v1.0.0.
operator_app() {
  cp -R "$FIXTURES/operator" "$TREE/kubernetes/apps/base/demo/operator"
  overlay_add ../../base/demo/operator/ks.yaml
}

# declare_operator: operator-definitions.yaml in the fixture tree, which says where the operator
# application's operator publishes its definitions.
declare_operator() {
  put operator-definitions.yaml <<'EOF'
---
definitions:
  - group: operator.example.invalid
    repository: https://github.com/example-org/doohickey
    path: deploy/crds
    tagPrefix: v
    sourceRef:
      kind: OCIRepository
      namespace: demo
      name: doohickey
EOF
}

# objects NAME: writes stdin to the file NAME of the hello application and lists it there.
objects() {
  local dir=kubernetes/apps/base/demo/hello/app
  put "$dir/$1"
  yq -i ".resources = ((.resources // []) + [\"$1\"] | unique)" "$TREE/$dir/kustomization.yaml"
}

# unlist NAME: the hello application no longer holds its file NAME.
unlist() {
  yq -i "del(.resources[] | select(. == \"$1\"))" "$TREE/kubernetes/apps/base/demo/hello/app/kustomization.yaml"
  rm "$TREE/kubernetes/apps/base/demo/hello/app/$1"
}

# fetch_recorders: stand-ins first on PATH for the tools that fetch, and the fixtures' schemas unset,
# so that the sources would be fetched: curl writes each URL it is asked for to FETCHED and hands back
# ARCHIVE when the test has made it, and an empty archive otherwise; helm writes each pull there and
# fails it, running any other command as itself; kubeconform reports nothing; and kustomize writes
# each run to BUILT and runs as itself. versions.yaml pins a schemas commit, which nothing fetches.
fetch_recorders() {
  local bin="$BATS_TEST_TMPDIR/fetchers" helm kustomize
  helm="$(type -P helm)"
  kustomize="$(type -P kustomize)"
  FETCHED="$BATS_TEST_TMPDIR/fetched"
  BUILT="$BATS_TEST_TMPDIR/built"
  ARCHIVE="$BATS_TEST_TMPDIR/archive.tar.gz"
  mkdir -p "$bin"
  cat >"$bin/curl" <<EOF
#!/usr/bin/env bash
out=""
for arg; do [[ \$arg != https://* ]] || echo "curl \$arg" >>"$FETCHED"; done
while ((\$#)); do [[ \$1 == --output ]] && out=\$2; shift; done
if [[ -f "$ARCHIVE" ]]; then
  cp "$ARCHIVE" "\$out"
else
  tar -czf "\$out" -T /dev/null
fi
EOF
  cat >"$bin/helm" <<EOF
#!/usr/bin/env bash
if [[ \${1:-} == pull ]]; then
  echo "helm \$*" >>"$FETCHED"
  exit 1
fi
exec "$helm" "\$@"
EOF
  cat >"$bin/kustomize" <<EOF
#!/usr/bin/env bash
echo "kustomize \$*" >>"$BUILT"
exec "$kustomize" "\$@"
EOF
  printf '#!/usr/bin/env bash\necho %q\n' '{"resources": []}' >"$bin/kubeconform"
  chmod +x "$bin/curl" "$bin/helm" "$bin/kubeconform" "$bin/kustomize"
  printf '%s\n' '---' 'kubernetes: v1.37.1' 'kubernetes_schemas: 0123456789abcdef0123456789abcdef01234567' >"$TREE/versions.yaml"
  unset KUBERNETES_VALIDATE_SCHEMAS
}

# recorded_validate: runs the check on the fixture tree with fetch_recorders' stand-ins, FETCHED and
# BUILT emptied first, reading nothing from the test's own input.
recorded_validate() {
  : >"$FETCHED"
  : >"$BUILT"
  run env PATH="$BATS_TEST_TMPDIR/fetchers:$PATH" "$VALIDATE" "$TREE" </dev/null
  echo "$output"
  echo "fetched:"
  cat "$FETCHED"
}

# not_fetched TEXT: nothing the last recorded run fetched names TEXT.
not_fetched() {
  ! grep -F -- "$1" "$FETCHED" || { echo "fetched before it was refused: $1"; return 1; }
}

# gizmo_archive [EDIT [LINK]]: ARCHIVE, as GitHub serves the archive of a tag of gizmo-crds, one top
# directory holding config/crd as the fixtures' sources hold it at v1.0.0, its kustomization.yaml
# changed by the yq expression EDIT, and with LINK a link there to /dev/null.
gizmo_archive() {
  local top="$BATS_TEST_TMPDIR/archive/gizmo-crds-1.0.0"
  rm -rf "$BATS_TEST_TMPDIR/archive"
  mkdir -p "$top/config"
  cp -R "$FIXTURES/schemas/sources/github.com/example-org/gizmo-crds/v1.0.0/config/crd" "$top/config/"
  [ -z "${1:-}" ] || yq -i "$1" "$top/config/crd/kustomization.yaml"
  [ -z "${2:-}" ] || ln -s /dev/null "$top/config/crd/$2"
  tar -czf "$ARCHIVE" -C "$BATS_TEST_TMPDIR/archive" gizmo-crds-1.0.0
}

# shown TEXT: TEXT as the checks show a value of the tree: each byte that is not printable ASCII as
# \xHH, read from od, whatever the locale.
shown() {
  local LC_ALL=C byte char out=""
  for byte in $(printf '%s' "$1" | od -An -v -tx1); do
    if ((16#$byte >= 32 && 16#$byte < 127)); then
      printf -v char '%b' "\\x$byte"
      out+=$char
    else
      out+="\\x$byte"
    fi
  done
  printf '%s' "$out"
}

# with_folded TYPE FILE: FILE, a YAML document, with every spelling that folds to a field of TYPE
# in tree_paths_read_fields without being it, at every position of the fields the checks read, each
# holding x; KEYS is where each is, as the checks name it. The spellings are those encoding/json's
# folding reads as the field: its first letter, all of it or its last letter in upper case, and each
# s as U+017F and each k as U+212A.
with_folded() {
  local reg
  reg="$(bash -c '. "$1/scripts/lib/tree-paths.sh" && printf "%s" "$tree_paths_read"' bash "$REPO")"
  # shellcheck disable=SC2016 # jq variables.
  local jq_folded='
    def variants: . as $n
      | [($n[:1] | ascii_upcase) + $n[1:], ($n | ascii_upcase), $n[:-1] + ($n[-1:] | ascii_upcase)]
        + (if ($n | test("s")) then [$n | gsub("s"; "ſ")] else [] end)
        + (if ($n | test("k")) then [$n | gsub("k"; "K")] else [] end)
      | unique | map(select(. != $n)) | .[];
    def sub($c): ($c | ltrimstr("[]")) as $t | if ($reg.types | has($t)) then $t else null end;
    def gen($t): $reg.types[$t] as $f
      | reduce ($f | keys[] | select(. != "*")) as $k ({};
          reduce ($k | variants) as $v (.; .[$v] = "x")
          | sub($f[$k]) as $s
          | if $s == null then . else .[$k] = (gen($s) | if ($f[$k] | startswith("[]")) then [.] else . end) end);
    def where($t; $w): $reg.types[$t] as $f
      | ($f | keys[] | select(. != "*")) as $k
      | (if $w == "" then $k else $w + "." + $k end) as $p
      | ((($k | variants) | if $w == "" then . else $w + "." + . end),
         (sub($f[$k]) as $s | if $s == null then empty
          elif ($f[$k] | startswith("[]")) then where($s; $p + "[0]") else where($s; $p) end));'
  yq -o json -I0 '.' "$2" | jq -c --argjson reg "$reg" --arg t "$1" "$jq_folded"' . * gen($t)' >"$2.json"
  mv "$2.json" "$2"
  KEYS="$(jq -rn --argjson reg "$reg" --arg t "$1" "$jq_folded"' where($t; "")')"
}

# names_every FILE: the run failed, and for each key in KEYS a line names FILE and the key, as the
# check shows it.
names_every() {
  local key lines missing=""
  [ "$status" -ne 0 ] || { echo "the run passed"; return 1; }
  lines="$(grep -F -- "$1" <<<"$output")" || { echo "no line names $1"; return 1; }
  while IFS= read -r key; do
    grep -qF -- " $(shown "$key") " <<<"$lines" || missing+=" $key"
  done <<<"$KEYS"
  [ -z "$missing" ] || { echo "not named with $1:$missing"; return 1; }
}

# validated: the number of objects the last run validated against a schema.
validated() {
  [[ $output =~ ([0-9]+)\ objects\ validated ]] || { echo "the check says how many objects it validated"; return 1; }
  echo "${BASH_REMATCH[1]}"
}

@test "The tree passes the schema and image rules" {
  # The repository's own tree is validated against the real schemas and its charts are pulled from
  # their publishers: the fixtures' schema location is left unset.
  unset KUBERNETES_VALIDATE_SCHEMAS
  run "$VALIDATE"
  echo "$output"
  [ "$status" -eq 0 ]

  # Every rule had something to look at: objects validated against a schema and the images of the
  # rendered releases. The only kinds listed as having no schema are the three constraint kinds
  # Gatekeeper makes from its templates at run time, which gator checks instead
  # (schema-exceptions.yaml). Every other object of the tree has one: the kinds whose definitions a
  # definitions application's source brings, and those Cilium's operator installs, are validated.
  [[ $output =~ ([1-9][0-9]*)\ flux\ builds ]]
  [[ $output =~ ([1-9][0-9]*)\ objects\ validated ]]
  [[ $output =~ ,\ ([0-9]+)\ of\ listed\ kinds ]]
  [ "${BASH_REMATCH[1]}" -eq 3 ]
  [[ $output =~ ([1-9][0-9]*)\ images ]]
  [ "$(grep -c 'listed without a schema' <<<"$output")" -eq 3 ]
  [ "$(grep 'listed without a schema' <<<"$output" | grep -vc 'constraints.gatekeeper.sh/v1beta1')" -eq 0 ]
  [[ $output != *"GatewayClass"* && $output != *"VolumeSnapshotClass"* && $output != *"CiliumBGPPeerConfig"* ]]
}

@test "An object with a field its schema does not have is refused, and objects of listed kinds without a schema are counted by kind" {
  local dir=kubernetes/apps/base/demo/hello/app
  put "$dir/deployment.yaml" <<'EOF'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
spec:
  replicaz: 2
EOF
  put "$dir/widgets.yaml" <<'EOF'
---
apiVersion: example.invalid/v1
kind: Widget
metadata:
  name: first
---
apiVersion: example.invalid/v1
kind: Widget
metadata:
  name: second
---
apiVersion: example.invalid/v1
kind: Gadget
metadata:
  name: only
EOF
  yq -i '.resources += ["deployment.yaml", "widgets.yaml"]' "$TREE/$dir/kustomization.yaml"
  yq -i '.spec.waitt = true' "$TREE/kubernetes/apps/base/demo/hello/ks.yaml"
  put schema-exceptions.yaml <<'EOF2'
---
exceptions:
  - group: example.invalid
    kind: Widget
    reason: the fixture has no definition of it until a chart brings one
  - group: example.invalid
    kind: Gadget
    reason: the fixture has no definition of it
EOF2

  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hello/app/deployment.yaml "Deployment hello" replicaz
  refused_line kubernetes/apps/base/demo/hello/ks.yaml "Kustomization hello" waitt
  # The listed kinds with no schema are not failures, and none is passed over unnamed.
  grep -qxF "kubernetes-validate: listed without a schema: Widget (example.invalid/v1): 2 objects" <<<"$output"
  grep -qxF "kubernetes-validate: listed without a schema: Gadget (example.invalid/v1): 1 object" <<<"$output"

  yq -i 'del(.spec.waitt)' "$TREE/kubernetes/apps/base/demo/hello/ks.yaml"
  yq -i 'del(.spec.replicaz) | .spec.replicas = 2' "$TREE/$dir/deployment.yaml"
  validate
  [ "$status" -eq 0 ]
  grep -qxF "kubernetes-validate: listed without a schema: Widget (example.invalid/v1): 2 objects" <<<"$output"
  grep -qxF "kubernetes-validate: listed without a schema: Gadget (example.invalid/v1): 1 object" <<<"$output"

  # A definition the render holds, here the fixture chart's for Widget, gives its kind a schema,
  # unknown fields refused at every level, the object's own top level included. The kind is no
  # longer listed.
  put schema-exceptions.yaml <<'EOF2'
---
exceptions:
  - group: example.invalid
    kind: Gadget
    reason: the fixture has no definition of it
EOF2
  hooked_app '{}'
  yq -i 'select(.metadata.name == "second") |= (.spec.colour = "red" | .spec.size = 1)' "$TREE/$dir/widgets.yaml"
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hello/app/widgets.yaml "Widget second" colour
  [[ $output != *"Widget (example.invalid/v1)"* ]]
  grep -qxF "kubernetes-validate: listed without a schema: Gadget (example.invalid/v1): 1 object" <<<"$output"
  yq -i 'select(.metadata.name == "second") |= (del(.spec.colour) | .spek = {})' "$TREE/$dir/widgets.yaml"
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hello/app/widgets.yaml "Widget second" spek
  yq -i 'select(.metadata.name == "second") |= del(.spek)' "$TREE/$dir/widgets.yaml"
  validate
  [ "$status" -eq 0 ]
  [[ $output != *"Widget (example.invalid/v1)"* ]]
  # A field the definition types is held to its type.
  yq -i 'select(.metadata.name == "second") |= .spec.size = "large"' "$TREE/$dir/widgets.yaml"
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hello/app/widgets.yaml "Widget second" size
  yq -i 'select(.metadata.name == "second") |= .spec.size = 1' "$TREE/$dir/widgets.yaml"
  # What the API server fills in or allows passes: a required field the definition defaults, null
  # where it allows null, and any field under one that keeps unknown fields; a field the definition
  # types under it is still held to its type.
  local spec
  for spec in '{}' '{"size": 1, "note": null}' '{"size": 1, "extra": {"anything": {"at": "all"}}}'; do
    yq -i "select(.metadata.name == \"second\") |= .spec = $spec" "$TREE/$dir/widgets.yaml"
    validate
    [ "$status" -eq 0 ]
  done
  yq -i 'select(.metadata.name == "second") |= .spec = {"size": 1, "extra": {"known": 5}}' "$TREE/$dir/widgets.yaml"
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hello/app/widgets.yaml "Widget second" known
  yq -i 'select(.metadata.name == "second") |= .spec = {"size": 1}' "$TREE/$dir/widgets.yaml"

  # A kind of Kubernetes' own or Flux's that the schemas lack is an error, never a skip: the schemas
  # would be out of date, or the apiVersion wrong.
  put "$dir/statefulset.yaml" <<'EOF'
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: hello
EOF
  yq -i '.resources += ["statefulset.yaml"]' "$TREE/$dir/kustomization.yaml"
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hello/app/statefulset.yaml "StatefulSet hello" "no schema"

  # So is a kind of any other group Kubernetes serves itself.
  local group_kind
  for group_kind in flowcontrol.apiserver.k8s.io/v1:FlowSchema resource.k8s.io/v1:ResourceClaim \
    authentication.k8s.io/v1:TokenReview authorization.k8s.io/v1:SubjectAccessReview \
    storagemigration.k8s.io/v1beta1:StorageVersionMigration; do
    put "$dir/other.yaml" <<<"---
apiVersion: ${group_kind%%:*}
kind: ${group_kind##*:}
metadata:
  name: other"
    yq -i '.resources = ((.resources // []) + ["other.yaml"] | unique)' "$TREE/$dir/kustomization.yaml"
    validate
    [ "$status" -ne 0 ]
    refused_line kubernetes/apps/base/demo/hello/app/other.yaml "${group_kind##*:} other" "no schema"
  done
}

@test "An image without a tag or digest in a rendered release or its hooks is refused" {
  local digest=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  local release=kubernetes/apps/base/demo/hooked/app/helmrelease.yaml

  # The chart's own Deployment and a test that names a tag pass.
  hooked_app 'testImage: registry.example.invalid/probe:1.0.0'
  validate
  [ "$status" -eq 0 ]
  [[ $output =~ ([1-9][0-9]*)\ images ]]

  # A hook that pulls an image by no tag, by latest, or by a registry's port alone is refused.
  local image
  for image in busybox busybox:latest registry.example.invalid:5000/busybox; do
    hooked_app "testImage: $image"
    validate
    [ "$status" -ne 0 ]
    refused_line kubernetes/apps/base/demo/hooked/ks.yaml "Job hooked-test-connection" "$image" "tag"
  done

  # An object of the chart that is no hook, and a hook that is no test, are the same.
  hooked_app 'image: registry.example.invalid/hooked'
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hooked/ks.yaml "Deployment hooked" registry.example.invalid/hooked
  hooked_app 'upgradeImage: busybox'
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hooked/ks.yaml "Job hooked-migrate" busybox

  # A bare Pod that is a test hook, and an init container of a pod template, are read as well.
  hooked_app 'podTestImage: busybox'
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hooked/ks.yaml "Pod hooked-test-pod" busybox
  hooked_app 'initImage: busybox'
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hooked/ks.yaml "Deployment hooked" busybox
  hooked_app 'podTestImage: busybox:1.37.0
initImage: busybox:1.37.0'
  validate
  [ "$status" -eq 0 ]

  # So is the image a custom resource names in its own spec.image, as Prometheus and Alertmanager
  # name the one their operator runs.
  hooked_app 'widgetImage: busybox'
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hooked/ks.yaml "Widget hooked" busybox
  hooked_app 'widgetImage: busybox:1.37.0'
  validate
  [ "$status" -eq 0 ]

  # A tag other than latest, or a digest, is a reference that does not move under the release.
  hooked_app 'testImage: busybox:1.37.0'
  validate
  [ "$status" -eq 0 ]
  hooked_app "testImage: busybox@$digest"
  validate
  [ "$status" -eq 0 ]
  # A digest is sha256 and 64 hexadecimal digits, or it pins nothing.
  hooked_app 'testImage: busybox@sha256:0123456789abcdef'
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hooked/ks.yaml "Job hooked-test-connection" "busybox@sha256:0123456789abcdef"

  # A test the release does not run pulls nothing: tests off, or this one excluded by name.
  hooked_app 'testImage: busybox'
  yq -i '.spec.test.enable = false' "$TREE/$release"
  validate
  [ "$status" -eq 0 ]
  # A hook that is no test runs whether tests do or not.
  hooked_app 'testImage: busybox
upgradeImage: busybox'
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hooked/ks.yaml "Job hooked-migrate" busybox
  [[ $output != *"hooked-test-connection"* ]]
  hooked_app 'testImage: busybox'
  yq -i '.spec.test.enable = true | .spec.test.filters = [{"name": "hooked-test-connection", "exclude": true}]' "$TREE/$release"
  validate
  [ "$status" -eq 0 ]
  yq -i '.spec.test.filters = [{"name": "another-test", "exclude": true}]' "$TREE/$release"
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hooked/ks.yaml "Job hooked-test-connection" busybox

  # An exception is listed by application and image, with its reason, in one file of the tree.
  put .image-allowlist <<'EOF'
# One exception per line: the application, the image as the chart renders it, and why it is safe.
hooked busybox  # the fixture's probe, pulled from a registry the fixture controls
EOF
  validate
  [ "$status" -eq 0 ]
  put .image-allowlist <<'EOF'
hooked busybox
EOF
  validate
  [ "$status" -ne 0 ]
  fails_naming .image-allowlist "reason"
}

@test "An application that renders no object passes the image rule without reading standard input" {
  local state app=kubernetes/apps/base/demo/hello/app
  local -A statuses=() printed=()
  # The application's kustomization lists nothing, so Flux builds no object of it, and the render
  # keeps a directory for it that holds no file: the image rule has nothing of it to read.
  rm "$TREE/$app/configmap.yaml"
  put "$app/kustomization.yaml" <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
EOF
  # hooked, which the rule reads after hello, runs one image, pinned: the rule goes on past the
  # empty directory and counts it.
  hooked_app '{}'
  "$REPO/scripts/render" "$BATS_TEST_TMPDIR/render" "$TREE" </dev/null
  [ -d "$BATS_TEST_TMPDIR/render/test/hello" ]
  [ -z "$(find "$BATS_TEST_TMPDIR/render/test/hello" -mindepth 1 -print -quit)" ]
  [ -n "$(find "$BATS_TEST_TMPDIR/render/test/hooked" -name '*.yaml' -print -quit)" ]
  # A pod the image rule refuses when it reads it: its image has no tag.
  CARRIED="$(printf '%s\n' '---' 'apiVersion: v1' 'kind: Pod' 'metadata:' '  name: carried' '  namespace: demo' \
    'spec:' '  containers:' '    - name: main' '      image: registry.example.invalid/carried')"

  # Every state of standard input, and every run made before one is judged, so that a failure shows
  # them all.
  for state in closed null silent carried; do
    with_stdin "$state" "$VALIDATE" "$TREE"
    statuses[$state]=$status
    printed[$state]=$output
    echo "standard input: $state; status $status"
    echo "$output"
  done
  for state in closed null silent carried; do
    [ "${statuses[$state]}" -eq 0 ] || { echo "with standard input $state the validation ended with status ${statuses[$state]}"; return 1; }
    # Nothing but the verdict, which counts hooked's one image and not the pod's, tagged or not.
    [ "${printed[$state]}" = "kubernetes-validate: passed (6 flux builds, 10 objects validated, 0 of listed kinds, 1 images)" ]
  done
}

@test "the check validates nothing on a tree that fails kubernetes-check, and says so" {
  put kubernetes/apps/base/demo/hello/extra.yaml <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: extra
EOF
  validate
  [ "$status" -ne 0 ]
  fails_naming kubernetes/apps/base/demo/hello/extra.yaml "outside app/"
  fails_naming scripts/kubernetes-check "nothing was validated"
  [[ $output != *"kubernetes-validate: passed"* ]]
}

@test "a tree from which a build would read outside it is not validated, and nothing of what it names appears" {
  # kubernetes-check runs first and refuses the tree before anything is built; nothing is rendered.
  local marker="marker-outside-the-tree-$RANDOM$RANDOM"
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  printf '%s\n' '---' 'apiVersion: v1' 'kind: ConfigMap' 'metadata:' '  name: outside' 'data:' "  marker: $marker" \
    >"$BATS_TEST_TMPDIR/outside/marker.yaml"
  P="$BATS_TEST_TMPDIR/outside/marker.yaml" yq -i '.configMapGenerator += [{"name": "leak", "files": ["leak=" + strenv(P)]}]' \
    "$TREE/kubernetes/apps/base/demo/hello/app/kustomization.yaml"
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hello/app/kustomization.yaml "leak=$BATS_TEST_TMPDIR/outside/marker.yaml"
  fails_naming scripts/kubernetes-check "nothing was validated"
  [[ $output != *"$marker"* ]]
}

@test "the check runs by a relative path on a tree elsewhere" {
  run bash -c 'cd "$1" && scripts/kubernetes-validate "$2"' bash "$REPO" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"kubernetes-validate: passed"* ]]
}

@test "the check runs kubeconform in the C locale, whatever the caller's" {
  local bin="$BATS_TEST_TMPDIR/locale-bin" log="$BATS_TEST_TMPDIR/locale.log" real
  mkdir -p "$bin"
  real="$(type -P kubeconform)"
  # shellcheck disable=SC2016 # ${LC_ALL:-unset} is the stand-in's own.
  printf '#!/usr/bin/env bash\necho "${LC_ALL:-unset}" >>%q\nexec %q "$@"\n' "$log" "$real" >"$bin/kubeconform"
  chmod +x "$bin/kubeconform"
  run env LC_ALL=C.UTF-8 PATH="$bin:$PATH" "$VALIDATE" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -s "$log" ]
  [ "$(grep -cvx C "$log")" -eq 0 ]
}

# schemas_ref_manager: the custom manager of .renovate/managers.json5 that reads a git ref from
# versions.yaml, as JSON (the file is JSON5 with comments, which YAML reads once they are dropped).
schemas_ref_manager() {
  grep -v '^[[:space:]]*//' "$REPO/.renovate/managers.json5" |
    yq -o json -I0 '.customManagers[] | select(.datasourceTemplate == "git-refs" and (.managerFilePatterns | join(" ") | contains("versions")))'
}

@test "the schemas commit is a versions.yaml entry that Renovate moves in the Kubernetes group" {
  local manager ref dep groups
  manager="$(schemas_ref_manager)"
  [ -n "$manager" ]

  # What the manager reads out of versions.yaml is the commit under its comment, of a public
  # repository at a branch, which is the shape Renovate's git-refs datasource moves.
  [ "$(jq -r '.customType' <<<"$manager")" = regex ]
  ref="$(jq -Rs --argjson m "$manager" '. as $text | $m.matchStrings | map(. as $re | $text | capture($re)) | first' "$REPO/versions.yaml")"
  echo "$ref"
  [[ $(jq -r '.depName' <<<"$ref") =~ ^https://github\.com/yannh/kubernetes-json-schema$ ]]
  [[ $(jq -r '.currentValue' <<<"$ref") =~ ^[a-z]+$ ]]
  [[ $(jq -r '.currentDigest' <<<"$ref") =~ ^[0-9a-f]{40}$ ]]
  [ "$(jq -r '.currentDigest' <<<"$ref")" = "$(yq '.kubernetes_schemas' "$REPO/versions.yaml")" ]

  # It is in the group of the Kubernetes version it holds schemas for.
  dep="$(jq -r '.depName' <<<"$ref")"
  groups="$(grep -v '^[[:space:]]*//' "$REPO/.renovate/groups.json5" | yq -o json -I0 '.packageRules')"
  jq -e --arg dep "$dep" 'map(select(.groupName == "Kubernetes" and (.matchPackageNames | index($dep) != null) and (.matchPackageNames | index("kubernetes/kubernetes") != null))) | length == 1' <<<"$groups"
}

@test "the check fetches Kubernetes' schemas at the commit versions.yaml holds, and Flux's from the pinned release" {
  local shims="$BATS_TEST_TMPDIR/shims" ref=0123456789abcdef0123456789abcdef01234567 flux
  mkdir -p "$shims"
  # curl hands back an empty archive and kubeconform reports nothing; both record what they were asked.
  cat >"$shims/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$BATS_TEST_TMPDIR/curl.args"
while ((\$#)); do [[ \$1 == --output ]] && out=\$2; shift; done
tar -czf "\$out" -T /dev/null
EOF
  cat >"$shims/kubeconform" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$BATS_TEST_TMPDIR/kubeconform.args"
echo '{"resources": []}'
EOF
  chmod +x "$shims/curl" "$shims/kubeconform"
  unset KUBERNETES_VALIDATE_SCHEMAS
  flux="$(yq -p toml '.tools.flux2' "$REPO/mise.toml")"
  [[ $flux =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]

  printf '%s\n' '---' 'kubernetes: v1.37.1' "kubernetes_schemas: $ref" >"$TREE/versions.yaml"
  run env PATH="$shims:$PATH" "$VALIDATE" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qF "yannh/kubernetes-json-schema/$ref/" "$BATS_TEST_TMPDIR/kubeconform.args"
  cat "$BATS_TEST_TMPDIR/curl.args"
  [ "$(grep -c 'https://' "$BATS_TEST_TMPDIR/curl.args")" -eq 1 ]
  grep -qF " https://github.com/fluxcd/flux2/releases/download/v$flux/crd-schemas.tar.gz" "$BATS_TEST_TMPDIR/curl.args"

  printf '%s\n' '---' 'kubernetes: v1.37.1' >"$TREE/versions.yaml"
  run env PATH="$shims:$PATH" "$VALIDATE" "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  fails_naming versions.yaml kubernetes_schemas
}

@test "the check runs kubeconform and kubernetes-check with none of the secrets" {
  local shims="$BATS_TEST_TMPDIR/shims" tool real name
  mkdir -p "$shims"
  # Each records the names in its environment, then runs as itself.
  for tool in kubeconform flux; do
    real="$(command -v "$tool")"
    printf '#!/usr/bin/env bash\nenv | cut -d= -f1 >> %q\nexec %q "$@"\n' "$BATS_TEST_TMPDIR/names.$tool" "$real" >"$shims/$tool"
    chmod +x "$shims/$tool"
  done
  local names=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CLUSTER_S3_ACCESS_KEY_ID OS_CLOUD
    OS_APPLICATION_CREDENTIAL_SECRET TF_STATE_PASSPHRASE SOPS_AGE_KEY FLUX_AGE_KEY OPERATOR_CIDRS)
  local settings=()
  for name in "${names[@]}"; do settings+=("$name=marker-$name"); done

  run env PATH="$shims:$PATH" "${settings[@]}" "$VALIDATE" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]
  for tool in kubeconform flux; do
    [ -s "$BATS_TEST_TMPDIR/names.$tool" ]
    for name in "${names[@]}"; do
      if grep -qx "$name" "$BATS_TEST_TMPDIR/names.$tool"; then
        echo "$tool got $name"
        return 1
      fi
    done
  done
}

@test "a jq that fails on what the check reads fails the check, naming what it could not read" {
  hooked_app 'testImage: registry.example.invalid/probe:1.0.0'
  local shims="$BATS_TEST_TMPDIR/shims" real
  real="$(command -v jq)"
  mkdir -p "$shims"
  # A jq that fails on the program named in FAIL_ON and runs every other program.
  cat >"$shims/jq" <<EOF
#!/usr/bin/env bash
if [[ -n \${FAIL_ON:-} && "\$*" == *"\$FAIL_ON"* ]]; then
  echo "jq: error: simulated" >&2
  exit 5
fi
exec "$real" "\$@"
EOF
  chmod +x "$shims/jq"

  run env PATH="$shims:$PATH" "$VALIDATE" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]

  run env FAIL_ON='def pinned' PATH="$shims:$PATH" "$VALIDATE" "$TREE"
  echo "$output"
  fails_naming hooked "none of its images was checked"

  run env FAIL_ON='.resources[]' PATH="$shims:$PATH" "$VALIDATE" "$TREE"
  echo "$output"
  fails_naming kubeconform "not all checked"

  run env FAIL_ON='def strict' PATH="$shims:$PATH" "$VALIDATE" "$TREE"
  echo "$output"
  fails_naming CustomResourceDefinition "no schema was made"
}

@test "an image that holds a '|' is read whole, and an exception for another image does not cover it" {
  put .image-allowlist <<'EOF'
hooked busybox  # the fixture's probe, pulled from a registry the fixture controls
EOF
  hooked_app 'testImage: busybox|latest'
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hooked/ks.yaml "Job hooked-test-connection" "busybox|latest"
}

@test "a definition whose group, kind or version the API server would refuse is refused, and nothing is written outside the check's own directory" {
  # The check's scratch directory is four levels under the test's own, where a sentinel directory
  # holds one file a definition's path could overwrite.
  local sentinel="$BATS_TEST_TMPDIR/sentinel" scratch="$BATS_TEST_TMPDIR/scratch/a" value
  mkdir -p "$sentinel" "$scratch"
  echo '{}' >"$sentinel/settings.json"
  # A group with no dot is a shape the API server refuses of a definition, not of every group.
  for value in 'definitionGroup: ../../../../sentinel/escaped' 'definitionGroup: widgets' \
    $'definitionGroup: example.invalid\ndefinitionVersion: v1/../../../../../../sentinel/settings' \
    $'definitionGroup: example.invalid\ndefinitionKind: ../Escape'; do
    hooked_app "$value"
    run env TMPDIR="$scratch" "$VALIDATE" "$TREE"
    echo "$output"
    [ "$status" -ne 0 ]
    refused_line kubernetes/apps/base/demo/hooked/ks.yaml "CustomResourceDefinition escapes.example.invalid" "the API server"
    [ "$(find "$sentinel" -mindepth 1 | wc -l)" -eq 1 ]
    [ "$(cat "$sentinel/settings.json")" = '{}' ]
  done
}

@test "an object whose kind or name holds a line break and a command runs nothing, and is refused naming its file" {
  local sentinel="$BATS_TEST_TMPDIR/sentinel" dir=kubernetes/apps/base/demo/later
  mkdir -p "$sentinel"
  # later is an application no overlay enables, so only the offline check's build holds it.
  cp -R "$TREE/kubernetes/apps/base/demo/hello" "$TREE/$dir"
  yq -i '.metadata.name = "later" | .spec.path = "./apps/base/demo/later/app" | .spec.sourceRef.name = "later"' "$TREE/$dir/ks.yaml"
  put "$dir/app/odd.yaml" <<EOF
---
apiVersion: v1
kind: "ConfigMap\n0|built_labels[\$(touch $sentinel/kind)0]|x"
metadata:
  name: odd
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: "odd\nstatusInvalid|built_labels[\$(touch $sentinel/name)0]|ConfigMap|v1|x|y"
unknown: 1
EOF
  yq -i '.resources += ["odd.yaml"]' "$TREE/$dir/app/kustomization.yaml"

  validate
  [ "$status" -ne 0 ]
  ls -A "$sentinel"
  [ -z "$(ls -A "$sentinel")" ]
  refused_line "$dir/app/odd.yaml" "a kind or apiVersion the API server would refuse"
  # The other is validated, its name read as one field, and refused for its unknown field.
  refused_line "$dir/ks.yaml" "ConfigMap odd?statusInvalid" "'unknown' not allowed"
}

@test "a definition whose schema does not compile fails the check, naming it" {
  hooked_app 'brokenDefinition: true'
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hooked/ks.yaml "Broken example.invalid/v1" "does not compile"
}

@test "a HelmRelease is validated as the root's patches build it" {
  hooked_app '{}'
  local root=kubernetes/clusters/test/ks.yaml
  # The root gives each child a patch that gives each of its HelmReleases a field the schema lacks.
  yq -i '.spec.patches = [{"target": {"group": "kustomize.toolkit.fluxcd.io", "kind": "Kustomization"},
    "patch": "apiVersion: kustomize.toolkit.fluxcd.io/v1\nkind: Kustomization\nmetadata:\n  name: _\nspec:\n  patches:\n    - target:\n        kind: HelmRelease\n      patch: |-\n        apiVersion: helm.toolkit.fluxcd.io/v2\n        kind: HelmRelease\n        metadata:\n          name: _\n        spec:\n          instal:\n            timeout: 10m\n"}]' \
    "$TREE/$root"
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hooked/app/helmrelease.yaml "HelmRelease hooked" instal "the root's patches"
  sed -i 's/instal:/install:/' "$TREE/$root"
  validate
  [ "$status" -eq 0 ]
}

@test "a field the definition requires and defaults may be left out, as the API server fills it in" {
  # The repository's own tree, its ClusterSecretStore without the mount path, which the definition
  # requires and defaults to kubernetes, and with a role that is not a string, which it types.
  unset KUBERNETES_VALIDATE_SCHEMAS
  local tree="$BATS_TEST_TMPDIR/real" store=kubernetes/apps/base/external-secrets/openbao-store/app/clustersecretstore.yaml
  mkdir -p "$tree"
  cp -R "$REPO/kubernetes" "$REPO/versions.yaml" "$tree/"
  yq -i 'del(.spec.provider.vault.auth.kubernetes.mountPath) | .spec.provider.vault.auth.kubernetes.role = 5' "$tree/$store"

  run env RENDER_CHART_CACHE="$BATS_TEST_TMPDIR/charts" "$VALIDATE" "$tree"
  echo "$output"
  [ "$status" -ne 0 ]
  refused_line "$store" "ClusterSecretStore openbao" role
  [[ $output != *mountPath* ]]
}

@test "A definition whose name ends in a line break is refused, not skipped" {
  local value
  # An object of the definition's kind, with a field no schema could give it, is in the tree: a
  # definition the check silently dropped would leave the object failing for want of a schema, and
  # the definition that is at fault unnamed.
  put kubernetes/apps/base/demo/hello/app/escape.yaml <<'EOF'
---
apiVersion: example.invalid/v1
kind: Escape
metadata:
  name: escape
unknown: 1
EOF
  yq -i '.resources += ["escape.yaml"]' "$TREE/kubernetes/apps/base/demo/hello/app/kustomization.yaml"

  for value in $'definitionGroup: "example.invalid\\n"' \
    $'definitionGroup: example.invalid\ndefinitionKind: "Escape\\n"' \
    $'definitionGroup: example.invalid\ndefinitionVersion: "v1\\n"'; do
    hooked_app "$value"
    validate
    [ "$status" -ne 0 ]
    refused_line kubernetes/apps/base/demo/hooked/ks.yaml "CustomResourceDefinition escapes.example.invalid" "the API server"
  done
}

@test "an image that ends in a line break is refused, not read as pinned" {
  hooked_app 'testImage: "busybox:1.37.0\n"'
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hooked/ks.yaml "Job hooked-test-connection" "busybox:1.37.0" "tag"
  hooked_app 'testImage: "busybox@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"'
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hooked/ks.yaml "Job hooked-test-connection" "busybox@sha256:"
}

# values_source NAME: the hooked application takes the values of the ConfigMap x-extra, which pins
# the probe's image, through a valuesFrom entry with the name NAME.
values_source() {
  hooked_app 'probe: true'
  put kubernetes/apps/base/demo/hooked/app/extra.yaml <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: x-extra
data:
  values.yaml: |
    probeImage: busybox:1.37.0
EOF
  yq -i '.resources = (.resources + ["extra.yaml"] | unique)' "$TREE/kubernetes/apps/base/demo/hooked/app/kustomization.yaml"
  yq -i ".spec.valuesFrom = [{\"kind\": \"ConfigMap\", \"name\": \"$1\", \"optional\": true}]" \
    "$TREE/kubernetes/apps/base/demo/hooked/app/helmrelease.yaml"
}

@test "a values source named by a pattern leaves the chart's untagged image to the image rule" {
  # helm-controller finds no ConfigMap of that name and deploys the chart's defaults, whose probe
  # runs an image without a tag.
  values_source 'x-*'
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hooked/ks.yaml "Pod hooked-probe" busybox "tag"

  # The ConfigMap by its exact name pins it.
  values_source x-extra
  validate
  [ "$status" -eq 0 ]
}

@test "An object of a kind whose definition a chart or a definitions application brings is validated against that definition" {
  local things=kubernetes/apps/base/demo/hello/app/things.yaml before
  hooked_app '{}'
  definitions_app
  validate
  [ "$status" -eq 0 ]
  before=$(validated)

  # One kind of each source: a chart's templates, a repository's directory at a tag, and a chart
  # unpacked from an OCI artifact. Under a field that keeps unknown fields, and in a condition that
  # lists some fields of an object, others are no fault.
  objects things.yaml <<'EOF'
---
apiVersion: example.invalid/v1
kind: Widget
metadata:
  name: from-a-chart
spec:
  size: 2
---
apiVersion: example.invalid/v1
kind: Gizmo
metadata:
  name: from-a-repository
spec:
  size: 3
  extra:
    anything:
      at: all
  parts:
    - label: first
  addresses:
    - type: Hostname
      value: gizmo.example.invalid
---
apiVersion: example.invalid/v1alpha1
kind: Sprocket
metadata:
  name: from-an-artifact
spec:
  teeth: 12
EOF
  validate
  [ "$status" -eq 0 ]
  [ "$(validated)" -eq $((before + 3)) ]
  [[ $output != *"no schema"* ]]

  # The schema is the one of the version the tree pins: the release that requires a colour refuses
  # the object that has none, and accepts one that has it; the release before it refuses the colour.
  yq -i '.spec.ref.tag = "v2.0.0"' "$TREE/kubernetes/apps/base/demo/defs/app/gitrepository.yaml"
  validate
  [ "$status" -ne 0 ]
  refused_line "$things" "Gizmo from-a-repository" colour
  objects things.yaml <<'EOF'
---
apiVersion: example.invalid/v1
kind: Gizmo
metadata:
  name: from-a-repository
spec:
  size: 3
  colour: red
EOF
  validate
  [ "$status" -eq 0 ]
  yq -i '.spec.ref.tag = "v1.0.0"' "$TREE/kubernetes/apps/base/demo/defs/app/gitrepository.yaml"
  validate
  [ "$status" -ne 0 ]
  refused_line "$things" "Gizmo from-a-repository" colour

  # A release the sources hold nothing of fails the check, naming the source, and leaves nothing
  # unvalidated unnoticed.
  yq -i '.spec.ref.tag = "v9.9.9"' "$TREE/kubernetes/apps/base/demo/defs/app/gitrepository.yaml"
  validate
  [ "$status" -ne 0 ]
  fails_naming kubernetes/apps/base/demo/defs/app/gizmo-crds.yaml "Kustomization gizmo-crds"
  fails_naming kubernetes/apps/base/demo/defs/app/gizmo-crds.yaml "v9.9.9"
}

@test "A field the definition does not have fails the check, naming the object and the field" {
  local bad=kubernetes/apps/base/demo/hello/app/bad.yaml case kind api spec word
  hooked_app '{}'
  definitions_app
  # A misspelt field, a wrong type and a missing required field, of a kind of each source, and of
  # the levels below the top that list their fields.
  for case in \
    'Widget|example.invalid/v1|{"size": 1, "colour": "red"}|colour' \
    'Widget|example.invalid/v1|{"size": "large"}|size' \
    'Gizmo|example.invalid/v1|{"size": 1, "sise": 2}|sise' \
    'Gizmo|example.invalid/v1|{"size": "big"}|size' \
    'Gizmo|example.invalid/v1|{"name": "no size"}|size' \
    'Gizmo|example.invalid/v1|{"size": 1, "parts": [{"label": "a", "labell": "b"}]}|labell' \
    'Gizmo|example.invalid/v1|{"size": 1, "parts": [{}]}|label' \
    'Gizmo|example.invalid/v1|{"size": 1, "extra": {"known": 5}}|known' \
    'Gizmo|example.invalid/v1|{"size": 1, "addresses": [{"type": "Hostname", "valu": "x"}]}|valu' \
    'Sprocket|example.invalid/v1alpha1|{"teeth": 12, "tooth": 1}|tooth' \
    'Sprocket|example.invalid/v1alpha1|{"teeth": "many"}|teeth' \
    'Sprocket|example.invalid/v1alpha1|{}|teeth'; do
    IFS='|' read -r kind api spec word <<<"$case"
    objects bad.yaml <<<"---
apiVersion: $api
kind: $kind
metadata:
  name: bad
spec: $spec"
    validate
    [ "$status" -ne 0 ]
    refused_line "$bad" "$kind bad" "$word"
  done
  # The object's own top level lists its fields too.
  objects bad.yaml <<'EOF'
---
apiVersion: example.invalid/v1alpha1
kind: Sprocket
metadata:
  name: bad
specs:
  teeth: 1
EOF
  validate
  [ "$status" -ne 0 ]
  refused_line "$bad" "Sprocket bad" specs
}

@test "An object of a kind without a schema fails the check unless the kind is listed with its reason" {
  local gadgets=kubernetes/apps/base/demo/hello/app/gadgets.yaml
  objects gadgets.yaml <<'EOF'
---
apiVersion: example.invalid/v1
kind: Gadget
metadata:
  name: only
EOF
  validate
  [ "$status" -ne 0 ]
  refused_line "$gadgets" "Gadget only" "example.invalid/v1" "no schema" schema-exceptions.yaml
  [[ $output != *"kubernetes-validate: passed"* ]]

  # Listed with its reason, the kind is counted, not failed.
  put schema-exceptions.yaml <<'EOF'
---
exceptions:
  - group: example.invalid
    kind: Gadget
    reason: the fixture has no definition of it, and nothing else proves its objects
EOF
  validate
  [ "$status" -eq 0 ]
  grep -qxF "kubernetes-validate: listed without a schema: Gadget (example.invalid/v1): 1 object" <<<"$output"

  # An entry names a group, a kind and a reason, and covers that kind of that group alone.
  put schema-exceptions.yaml <<'EOF'
---
exceptions:
  - group: example.invalid
    kind: Gadget
EOF
  validate
  [ "$status" -ne 0 ]
  fails_naming "schema-exceptions.yaml: entry 1 (Gadget of example.invalid)" "no reason"
  local reason
  for reason in '""' '"  "'; do
    put schema-exceptions.yaml <<EOF
---
exceptions:
  - group: example.invalid
    kind: Gadget
    reason: $reason
EOF
    validate
    [ "$status" -ne 0 ]
    fails_naming "schema-exceptions.yaml: entry 1 (Gadget of example.invalid)" "no reason"
  done
  put schema-exceptions.yaml <<'EOF'
---
exceptions:
  - group: other.invalid
    kind: Gadget
    reason: another group's kind of that name
EOF
  validate
  [ "$status" -ne 0 ]
  refused_line "$gadgets" "Gadget only" "no schema"
  # A kind of Kubernetes' own groups or Flux's is never listed: no schema there is a wrong
  # apiVersion or old schemas.
  put schema-exceptions.yaml <<'EOF'
---
exceptions:
  - group: example.invalid
    kind: Gadget
    reason: the fixture has no definition of it
  - group: apps
    kind: StatefulSet
    reason: no schema for it
  - group: kustomize.toolkit.fluxcd.io
    kind: Kustomization
    reason: no schema for it
EOF
  validate
  [ "$status" -ne 0 ]
  fails_naming "schema-exceptions.yaml: entry 2 (StatefulSet of apps)" "never listed"
  fails_naming "schema-exceptions.yaml: entry 3 (Kustomization of kustomize.toolkit.fluxcd.io)" "never listed"
}

@test "A listed kind that has a schema, or that no object uses, fails the check" {
  hooked_app '{}'
  definitions_app
  objects things.yaml <<'EOF'
---
apiVersion: example.invalid/v1
kind: Gizmo
metadata:
  name: first
spec:
  size: 1
---
apiVersion: example.invalid/v1
kind: Gadget
metadata:
  name: only
EOF
  put schema-exceptions.yaml <<'EOF'
---
exceptions:
  - group: example.invalid
    kind: Gadget
    reason: the fixture has no definition of it
EOF
  validate
  [ "$status" -eq 0 ]

  # A kind a definition now describes: the entry has no use, and the object is validated.
  put schema-exceptions.yaml <<'EOF'
---
exceptions:
  - group: example.invalid
    kind: Gadget
    reason: the fixture has no definition of it
  - group: example.invalid
    kind: Gizmo
    reason: listed before a repository brought its definition
EOF
  validate
  [ "$status" -ne 0 ]
  refused_line schema-exceptions.yaml Gizmo example.invalid "has a schema"
  [[ $output != *"Gadget of"* ]]

  # A kind no object of the tree is of.
  put schema-exceptions.yaml <<'EOF'
---
exceptions:
  - group: example.invalid
    kind: Gadget
    reason: the fixture has no definition of it
  - group: example.invalid
    kind: Gimcrack
    reason: nothing in the fixture is of it
EOF
  validate
  [ "$status" -ne 0 ]
  refused_line schema-exceptions.yaml Gimcrack example.invalid "no object"
  [[ $output != *"Gadget of"* ]]

  # Without the entry that has no use, the tree passes.
  put schema-exceptions.yaml <<'EOF'
---
exceptions:
  - group: example.invalid
    kind: Gadget
    reason: the fixture has no definition of it
EOF
  validate
  [ "$status" -eq 0 ]
}

@test "The tree passes, and the check says how many objects it validated and how many are of listed kinds" {
  hooked_app '{}'
  definitions_app
  objects things.yaml <<'EOF'
---
apiVersion: example.invalid/v1
kind: Gizmo
metadata:
  name: first
spec:
  size: 1
---
apiVersion: example.invalid/v1alpha1
kind: Sprocket
metadata:
  name: first
spec:
  teeth: 1
---
apiVersion: example.invalid/v1
kind: Gadget
metadata:
  name: first
---
apiVersion: example.invalid/v1
kind: Gadget
metadata:
  name: second
EOF
  put schema-exceptions.yaml <<'EOF'
---
exceptions:
  - group: example.invalid
    kind: Gadget
    reason: the fixture has no definition of it
EOF
  validate
  [ "$status" -eq 0 ]
  grep -qxF "kubernetes-validate: listed without a schema: Gadget (example.invalid/v1): 2 objects" <<<"$output"
  [[ $output =~ kubernetes-validate:\ passed\ \([0-9]+\ flux\ builds,\ ([0-9]+)\ objects\ validated,\ ([0-9]+)\ of\ listed\ kinds,\ ([0-9]+)\ images\) ]]
  [ "${BASH_REMATCH[2]}" -eq 2 ]
}

@test "An object of a Gateway API or Envoy Gateway kind is validated against the definitions the tree pins, and a wrong one fails" {
  # The repository's own tree with objects of the Gateway API's and Envoy Gateway's kinds added to
  # an application: the definitions are fetched from the sources the tree pins, the Gateway API's
  # release and Envoy Gateway's chart, as the cluster gets them.
  unset KUBERNETES_VALIDATE_SCHEMAS
  local tree="$BATS_TEST_TMPDIR/real" app=kubernetes/apps/base/demo/hello/app file=kubernetes/apps/base/demo/hello/app/gateway.yaml
  mkdir -p "$tree"
  cp -R "$REPO/kubernetes" "$REPO/versions.yaml" "$REPO/schema-exceptions.yaml" "$REPO/operator-definitions.yaml" "$tree/"
  cat >"$tree/$app/gateway.yaml" <<'EOF'
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: right
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: right
spec:
  gatewayClassName: right
  listeners:
    - name: http
      port: 80
      protocol: HTTP
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: right
spec:
  parentRefs:
    - name: right
  hostnames:
    - www.example.com
  rules:
    - backendRefs:
        - name: hello
          port: 80
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: right
spec:
  logging:
    level:
      default: warn
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: right
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: right
  connection:
    connectionLimit:
      value: 100
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: misspelt
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  descriptionn: a misspelt field
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: required
spec:
  description: no controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: misspelt
spec:
  gatewayClassName: right
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      hostnamee: www.example.com
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: wrongtype
spec:
  gatewayClassName: right
  listeners:
    - name: http
      port: eighty
      protocol: HTTP
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: required
spec:
  gatewayClassName: right
  listeners:
    - name: http
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: misspelt
spec:
  parentRefs:
    - name: right
  hostnamess:
    - www.example.com
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: wrongtype
spec:
  parentRefs:
    - name: right
  hostnames: www.example.com
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: required
spec:
  parentRefs:
    - name: right
  rules:
    - backendRefs:
        - port: 80
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: misspelt
spec:
  loging:
    level:
      default: warn
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: wrongtype
spec:
  concurrency: four
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: misspelt
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: right
  conection: {}
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: wrongtype
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: right
  connection:
    connectionLimit:
      value: many
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: required
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      name: right
EOF
  yq -i '.resources += ["gateway.yaml"]' "$tree/$app/kustomization.yaml"

  run "$VALIDATE" "$tree"
  echo "$output"
  [ "$status" -ne 0 ]
  # Each wrong object fails naming the object and the field; the right ones are not named.
  fails_naming "GatewayClass misspelt" descriptionn
  fails_naming "GatewayClass required" controllerName
  fails_naming "Gateway misspelt" hostnamee
  fails_naming "Gateway wrongtype" port
  fails_naming "Gateway required" protocol
  fails_naming "HTTPRoute misspelt" hostnamess
  fails_naming "HTTPRoute wrongtype" hostnames
  fails_naming "HTTPRoute required" name
  fails_naming "EnvoyProxy misspelt" loging
  fails_naming "EnvoyProxy wrongtype" concurrency
  fails_naming "ClientTrafficPolicy misspelt" conection
  fails_naming "ClientTrafficPolicy wrongtype" value
  fails_naming "ClientTrafficPolicy required" kind
  local kind
  for kind in GatewayClass Gateway HTTPRoute EnvoyProxy ClientTrafficPolicy; do
    [[ $output != *"$kind right"* ]]
  done
  [ "$(grep -c "$file" <<<"$output")" -eq 13 ]
  # None of them is counted as an object without a schema.
  [[ $output != *"no schema"* ]]
}

@test "An object of a kind an operator defines is validated against the definitions published for the version the tree pins" {
  local things=kubernetes/apps/base/demo/hello/app/things.yaml bad=kubernetes/apps/base/demo/hello/app/bad.yaml case spec word
  local repository=kubernetes/apps/base/demo/operator/app/ocirepository.yaml
  operator_app
  objects things.yaml <<'EOF'
---
apiVersion: operator.example.invalid/v1
kind: Doohickey
metadata:
  name: right
spec:
  size: 2
  peers:
    - name: first
      port: 179
EOF
  # Nothing in the tree describes the kind until operator-definitions.yaml says where its operator
  # publishes its definition.
  validate
  [ "$status" -ne 0 ]
  refused_line "$things" "Doohickey right" "no schema"
  declare_operator
  validate
  [ "$status" -eq 0 ]
  [[ $output != *"no schema"* ]]

  # A misspelt field, a wrong type and a missing required field, at the top of the spec and in the
  # objects of a list.
  for case in '{"size": 1, "sise": 2}|sise' '{"size": "big"}|size' '{"peers": []}|size' \
    '{"size": 1, "peers": [{"name": "a", "portt": 1}]}|portt' '{"size": 1, "peers": [{"port": 1}]}|name'; do
    IFS='|' read -r spec word <<<"$case"
    objects bad.yaml <<<"---
apiVersion: operator.example.invalid/v1
kind: Doohickey
metadata:
  name: bad
spec: $spec"
    validate
    [ "$status" -ne 0 ]
    refused_line "$bad" "Doohickey bad" "$word"
  done
  unlist bad.yaml

  # The definition is the one of the release the source object's tag pins, with the prefix: the
  # release of 2.0.0 requires a colour and has no peers, and the one of 1.0.0 has no colour.
  yq -i '.spec.ref.tag = "2.0.0"' "$TREE/$repository"
  validate
  [ "$status" -ne 0 ]
  refused_line "$things" "Doohickey right" colour
  objects things.yaml <<'EOF'
---
apiVersion: operator.example.invalid/v1
kind: Doohickey
metadata:
  name: right
spec:
  size: 2
  colour: red
EOF
  validate
  [ "$status" -eq 0 ]
  yq -i '.spec.ref.tag = "1.0.0"' "$TREE/$repository"
  validate
  [ "$status" -ne 0 ]
  refused_line "$things" "Doohickey right" colour
  # A release whose definitions the repository does not hold fails, naming the declaration and the
  # tag it was read at.
  yq -i '.spec.ref.tag = "9.9.9"' "$TREE/$repository"
  validate
  [ "$status" -ne 0 ]
  refused_line operator-definitions.yaml "entry 1" v9.9.9
  yq -i '.spec.ref.tag = "2.0.0"' "$TREE/$repository"
  validate
  [ "$status" -eq 0 ]

  # Only the definitions of the group declared are read from the directory: at 1.0.0 it also holds
  # a definition of another group, which gives the object of that group no schema.
  yq -i '.spec.ref.tag = "1.0.0"' "$TREE/$repository"
  objects other.yaml <<'EOF'
---
apiVersion: other.example.invalid/v1
kind: Thingamajig
metadata:
  name: other
EOF
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hello/app/other.yaml "Thingamajig other" "no schema"
  unlist other.yaml
  yq -i '.spec.ref.tag = "2.0.0"' "$TREE/$repository"

  # For what no source object pins, the tag is the version versions.yaml holds under the key the
  # entry names, with the prefix, and the source object's tag is not read: moving that version
  # moves the schema.
  yq -i 'del(.definitions[0].sourceRef) | .definitions[0].versionsKey = "doohickey"' "$TREE/operator-definitions.yaml"
  yq -i '.doohickey = "2.0.0"' "$TREE/versions.yaml"
  validate
  [ "$status" -eq 0 ]
  yq -i '.doohickey = "1.0.0"' "$TREE/versions.yaml"
  validate
  [ "$status" -ne 0 ]
  refused_line "$things" "Doohickey right" colour
  yq -i '.doohickey = "9.9.9"' "$TREE/versions.yaml"
  validate
  [ "$status" -ne 0 ]
  refused_line operator-definitions.yaml "entry 1" v9.9.9
}

@test "A declaration of where an operator's definitions are published that is malformed, or that nothing uses, fails the check" {
  local file="$TREE/operator-definitions.yaml" edit word
  operator_app
  objects things.yaml <<'EOF'
---
apiVersion: operator.example.invalid/v1
kind: Doohickey
metadata:
  name: right
spec:
  size: 2
EOF
  declare_operator
  validate
  [ "$status" -eq 0 ]

  # An entry is a group, a repository on github.com, a plain path in it, a prefix of the tag, and the
  # source object whose tag the prefix goes before, by kind, namespace and name, or in its place the
  # key of versions.yaml whose version it goes before; nothing else.
  while IFS='|' read -r edit word; do
    declare_operator
    yq -i "$edit" "$file"
    validate
    [ "$status" -ne 0 ]
    refused_line operator-definitions.yaml "$word"
  done <<'EOF'
.definitions[0].tag = "v1.0.0"|entry 1 (operator.example.invalid): an entry has no field but
.definitions[0].repository = "https://gitlab.example.invalid/example-org/doohickey"|entry 1 (operator.example.invalid): its repository is not
.definitions[0].repository = "http://github.com/example-org/doohickey"|entry 1 (operator.example.invalid): its repository is not
.definitions[0].repository = "https://github.com/example-org/doohickey/tree/main"|entry 1 (operator.example.invalid): its repository is not
.definitions[0].repository = "https://github.com/example-org/.."|entry 1 (operator.example.invalid): its repository is not
.definitions[0].path = "../crds"|entry 1 (operator.example.invalid): its path
.definitions[0].path = "/deploy/crds"|entry 1 (operator.example.invalid): its path
.definitions[0].path = "deploy/../../crds"|entry 1 (operator.example.invalid): its path
.definitions[0].path = "deploy//crds"|entry 1 (operator.example.invalid): its path
del(.definitions[0].path)|entry 1 (operator.example.invalid): its path
.definitions[0].group = "apps"|entry 1 (apps): a group of Kubernetes' own or Flux's
.definitions[0].group = "Operator.Example"|entry 1 (Operator.Example): its group is not an API group
.definitions[0].tagPrefix = "v/"|entry 1 (operator.example.invalid): its tagPrefix
.definitions[0].tagPrefix = 1|entry 1 (operator.example.invalid): its tagPrefix
.definitions[0].sourceRef.kind = "HelmRelease"|entry 1 (operator.example.invalid): its sourceRef
.definitions[0].sourceRef.url = "x"|entry 1 (operator.example.invalid): its sourceRef
del(.definitions[0].sourceRef)|entry 1 (operator.example.invalid): its sourceRef
.definitions[0].sourceRef.name = "Doohickey"|entry 1 (operator.example.invalid): its sourceRef
.definitions[0].versionsKey = "doohickey"|entry 1 (operator.example.invalid): it names both a sourceRef and a versionsKey
.definitions[0] = {"group": "operator.example.invalid", "repository": "https://github.com/example-org/doohickey", "path": "deploy/crds", "versionsKey": "Doohickey"}|entry 1 (operator.example.invalid): its versionsKey is not
.definitions[0] = {"group": "operator.example.invalid", "repository": "https://github.com/example-org/doohickey", "path": "deploy/crds", "versionsKey": ["doohickey"]}|entry 1 (operator.example.invalid): its versionsKey is not
.definitions += [.definitions[0]]|entry 2 (operator.example.invalid): the group and path are declared twice
.definitions = {}|the file is a map of one key, definitions, a list of entries
EOF

  # The source object's tag is what pins the definitions: a ref other than a tag pins nothing read.
  declare_operator
  yq -i '.spec.ref = {"semver": "1.x"}' "$TREE/kubernetes/apps/base/demo/operator/app/ocirepository.yaml"
  validate
  [ "$status" -ne 0 ]
  refused_line operator-definitions.yaml "OCIRepository demo/doohickey" "a ref other than a tag"
  yq -i '.spec.ref = {"tag": "1.0.0"}' "$TREE/kubernetes/apps/base/demo/operator/app/ocirepository.yaml"

  # A declaration whose source object is not in the tree, or whose definitions no object is of, has
  # no use.
  for edit in '.definitions[0].sourceRef.name = "gone"' '.definitions[0].sourceRef.namespace = "elsewhere"'; do
    declare_operator
    yq -i "$edit" "$file"
    validate
    [ "$status" -ne 0 ]
    refused_line operator-definitions.yaml "entry 1 (operator.example.invalid)" "no object of the tree is the OCIRepository"
  done
  # So has one whose key versions.yaml does not hold, or holds no version under.
  for edit in 'del(.doohickey)' '.doohickey = ["1.0.0"]'; do
    declare_operator
    yq -i 'del(.definitions[0].sourceRef) | .definitions[0].versionsKey = "doohickey"' "$file"
    yq -i "$edit" "$TREE/versions.yaml"
    validate
    [ "$status" -ne 0 ]
    refused_line operator-definitions.yaml "entry 1 (operator.example.invalid)" "versions.yaml holds no version under doohickey" "remove"
  done
  declare_operator
  unlist things.yaml
  validate
  [ "$status" -ne 0 ]
  refused_line operator-definitions.yaml "entry 1 (operator.example.invalid)" "no object of the tree is of a kind" "remove"
}

@test "An object of a Cilium kind is validated against the definitions of the Cilium release the tree pins, and a wrong one fails" {
  # The repository's own tree with Cilium objects added to an application: the definitions are read
  # where operator-definitions.yaml says Cilium publishes them, at the tag of the chart the tree pins.
  unset KUBERNETES_VALIDATE_SCHEMAS
  local tree="$BATS_TEST_TMPDIR/real" app=kubernetes/apps/base/demo/hello/app file=kubernetes/apps/base/demo/hello/app/cilium.yaml
  mkdir -p "$tree"
  cp -R "$REPO/kubernetes" "$REPO/versions.yaml" "$REPO/schema-exceptions.yaml" "$REPO/operator-definitions.yaml" "$tree/"
  cat >"$tree/$file" <<'EOF'
---
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: misspelt
spec:
  timers:
    holdTimeSecondz: 9
---
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: wrongtype
spec:
  timers:
    holdTimeSeconds: nine
---
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: required
spec:
  families:
    - safi: unicast
---
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: misspelt
spec:
  blockz:
    - cidr: 192.0.2.0/28
---
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: wrongtype
spec:
  disabled: "no"
---
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: required
EOF
  yq -i '.resources += ["cilium.yaml"]' "$tree/$app/kustomization.yaml"

  run "$VALIDATE" "$tree"
  echo "$output"
  [ "$status" -ne 0 ]
  # Each wrong object fails naming the object and the field; the tree's own Cilium objects pass.
  fails_naming "CiliumBGPPeerConfig misspelt" holdTimeSecondz
  fails_naming "CiliumBGPPeerConfig wrongtype" holdTimeSeconds
  fails_naming "CiliumBGPPeerConfig required" afi
  fails_naming "CiliumLoadBalancerIPPool misspelt" blockz
  fails_naming "CiliumLoadBalancerIPPool wrongtype" disabled
  fails_naming "CiliumLoadBalancerIPPool required" spec
  [ "$(grep -c "$file" <<<"$output")" -eq 6 ]
  [[ $output != *"kube-system/cilium-bgp/"* && $output != *"no schema"* ]]
  # Nothing is listed without a schema but Gatekeeper's three constraint kinds (schema-exceptions.yaml).
  [ "$(grep -c 'listed without a schema' <<<"$output")" -eq 3 ]
  [ "$(grep 'listed without a schema' <<<"$output" | grep -vc 'constraints.gatekeeper.sh/v1beta1')" -eq 0 ]

  # The definitions are read at the tag prefix followed by the tag of the Cilium chart the tree pins,
  # and the operator that chart runs, with the tree's values, is that release: Cilium tags a chart
  # with the version it runs, and the chart's operator image with that version after a v.
  local tag prefix image
  local -a tgz
  tag="$(yq '.spec.ref.tag' "$REPO/kubernetes/apps/base/kube-system/cilium/app/ocirepository.yaml")"
  prefix="$(yq '.definitions[] | select(.group == "cilium.io") | .tagPrefix // ""' "$REPO/operator-definitions.yaml")"
  [ "$(yq '.definitions[] | select(.group == "cilium.io") | .sourceRef.name' "$REPO/operator-definitions.yaml")" = cilium ]
  tgz=("$RENDER_CHART_CACHE/quay.io/cilium/charts/cilium/$tag"/*.tgz)
  [ "${#tgz[@]}" -eq 1 ]
  [ "$(helm show chart "${tgz[0]}" | yq '.version')" = "$tag" ]
  image="$(helm template cilium "${tgz[0]}" --namespace kube-system --kube-version "$(yq '.kubernetes' "$REPO/versions.yaml")" \
    --values "$REPO/kubernetes/apps/base/kube-system/cilium/app/values.yaml" |
    yq 'select(.kind == "Deployment" and .metadata.name == "cilium-operator") | .spec.template.spec.containers[] | select(.name == "cilium-operator") | .image')"
  echo "operator image: $image"
  [[ ${image%@sha256:*} == *":$prefix$tag" ]]
}

@test "A Talos ServiceAccount is validated against Talos' definition at the version the tree pins, and a wrong one fails" {
  # The repository's own tree with Talos ServiceAccounts added to an application: the definition is
  # read where operator-definitions.yaml says Talos' repository holds it, at the tag that is the
  # Talos version versions.yaml pins.
  unset KUBERNETES_VALIDATE_SCHEMAS
  local tree="$BATS_TEST_TMPDIR/real" app=kubernetes/apps/base/demo/hello/app file=kubernetes/apps/base/demo/hello/app/talos.yaml
  mkdir -p "$tree"
  cp -R "$REPO/kubernetes" "$REPO/versions.yaml" "$REPO/schema-exceptions.yaml" "$REPO/operator-definitions.yaml" "$tree/"
  cat >"$tree/$file" <<'EOF'
---
apiVersion: talos.dev/v1alpha1
kind: ServiceAccount
metadata:
  name: misspelt
spec:
  role:
    - os:reader
---
apiVersion: talos.dev/v1alpha1
kind: ServiceAccount
metadata:
  name: wrongtype
spec:
  roles: os:reader
EOF
  yq -i '.resources += ["talos.yaml"]' "$tree/$app/kustomization.yaml"
  [ "$(yq '.definitions[] | select(.group == "talos.dev") | .versionsKey' "$REPO/operator-definitions.yaml")" = talos ]

  run "$VALIDATE" "$tree"
  echo "$output"
  [ "$status" -ne 0 ]
  # Each wrong one fails naming the object and the field; the snapshot job's own passes.
  fails_naming "ServiceAccount misspelt" role
  fails_naming "ServiceAccount wrongtype" roles
  [ "$(grep -c "$file" <<<"$output")" -eq 2 ]
  [[ $output != *"etcd-snapshots"* && $output != *"no schema"* ]]
  # Nothing is listed without a schema but Gatekeeper's three constraint kinds (schema-exceptions.yaml).
  [ "$(grep -c 'listed without a schema' <<<"$output")" -eq 3 ]
  [ "$(grep 'listed without a schema' <<<"$output" | grep -vc 'constraints.gatekeeper.sh/v1beta1')" -eq 0 ]
}

@test "A definition of one of Kubernetes' own groups or Flux's is refused, whatever brings it" {
  local schemas="$BATS_TEST_TMPDIR/schemas" crd value deployment=kubernetes/apps/base/demo/hello/app/deployment.yaml
  local refusal="a group of Kubernetes' own or Flux's"
  # The fixtures' sources, where the directory the definitions application applies at the tag it
  # pins holds, beside Gizmo's, a definition of Deployment in the apps group whose top level keeps
  # unknown fields: a schema made of it would pass any Deployment.
  cp -R "$FIXTURES/schemas" "$schemas"
  export KUBERNETES_VALIDATE_SCHEMAS="$schemas"
  crd="$schemas/sources/github.com/example-org/gizmo-crds/v1.0.0/config/crd"
  cat >"$crd/deployments.yaml" <<'EOF'
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: deployments.apps
spec:
  group: apps
  names:
    kind: Deployment
    listKind: DeploymentList
    plural: deployments
    singular: deployment
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          x-kubernetes-preserve-unknown-fields: true
EOF
  yq -i '.resources += ["deployments.yaml"]' "$crd/kustomization.yaml"
  definitions_app
  objects deployment.yaml <<'EOF'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
spec:
  replicas: 1
  bogusField: true
EOF
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/defs/ks.yaml "CustomResourceDefinition deployments.apps" "$refusal" "no schema is made of it"
  # Kubernetes' schema is the Deployment's still.
  refused_line "$deployment" "Deployment hello" bogusField

  # A chart's definition in the apps group, in one of Kubernetes' dotted groups or in one of Flux's
  # is refused too. Its schema lists no field but the top level's, so a schema made of it would
  # refuse the Deployment, which Kubernetes' passes.
  export KUBERNETES_VALIDATE_SCHEMAS="$FIXTURES/schemas"
  yq -i 'del(.spec.bogusField)' "$TREE/$deployment"
  for value in $'definitionGroup: apps\ndefinitionKind: Deployment' \
    $'definitionGroup: networking.k8s.io\ndefinitionKind: Ingress' \
    $'definitionGroup: kustomize.toolkit.fluxcd.io\ndefinitionKind: Kustomization'; do
    hooked_app "$value"
    validate
    [ "$status" -ne 0 ]
    refused_line kubernetes/apps/base/demo/hooked/ks.yaml "CustomResourceDefinition escapes.example.invalid" "$refusal" "no schema is made of it"
    [[ $output != *"$deployment"* ]]
  done
  hooked_app '{}'
  validate
  [ "$status" -eq 0 ]
}

@test "a source the check cannot pin or read is refused, naming the file and the Kustomization, before anything is fetched" {
  local defs=kubernetes/apps/base/demo/defs/app edit
  definitions_app
  fetch_recorders
  # Both sources are fetched when nothing is refused; the stand-ins give nothing back.
  recorded_validate
  grep -qxF "curl https://github.com/example-org/gizmo-crds/archive/refs/tags/v1.0.0.tar.gz" "$FETCHED"
  grep -qF "helm pull oci://registry.example.invalid/charts/sprocket --version 1.0.0" "$FETCHED"

  # A GitRepository's URL, tag, ref and sparseCheckout, and the path of the Kustomization that
  # applies from it.
  while IFS='|' read -r edit word; do
    definitions_app_reset
    yq -i "$edit" "$TREE/$defs/gitrepository.yaml"
    recorded_validate
    [ "$status" -ne 0 ]
    refused_line "$defs/gizmo-crds.yaml" "Kustomization gizmo-crds" "$word"
    not_fetched gizmo-crds
  done <<'EOF'
.spec.url = "https://gitlab.example.invalid/example-org/gizmo-crds"|URL is not that of a repository on github.com
.spec.url = "https://github.com/example-org/gizmo-crds/../other"|URL is not that of a repository on github.com
.spec.url = "https://github.com/example-org/gizmo-crds.git"|URL ends in .git
.spec.ref.tag = "v1..0"|tag v1..0 has not the shape of a tag
.spec.ref.tag = "../v1.0.0"|tag ../v1.0.0 has not the shape of a tag
.spec.ref = {}|names no tag
.spec.ref = {"branch": "main"}|a ref other than a tag
.spec.ref = {"tag": "v1.0.0", "commit": "0123456789abcdef0123456789abcdef01234567"}|a ref other than a tag
.spec.sparseCheckout = ["config/../.."]|sparseCheckout entry config/../.. is not a plain path
.spec.sparseCheckout = ["/config"]|sparseCheckout entry /config is not a plain path
EOF
  while IFS='|' read -r edit word; do
    definitions_app_reset
    yq -i "$edit" "$TREE/$defs/gizmo-crds.yaml"
    recorded_validate
    [ "$status" -ne 0 ]
    refused_line "$defs/gizmo-crds.yaml" "Kustomization gizmo-crds" "$word"
    not_fetched gizmo-crds
  done <<'EOF'
.spec.path = "./config/../../outside"|spec.path ./config/../../outside is not a plain path
.spec.path = "/config/crd"|spec.path /config/crd is not a plain path
.spec.sourceRef.name = "gone"|the GitRepository it applies from is not an object of the application
EOF

  # An OCIRepository's URL, tag and layerSelector.
  while IFS='|' read -r edit word; do
    definitions_app_reset
    yq -i "$edit" "$TREE/$defs/ocirepository.yaml"
    recorded_validate
    [ "$status" -ne 0 ]
    refused_line "$defs/sprocket-crds.yaml" "Kustomization sprocket-crds" "$word"
    not_fetched sprocket
  done <<'EOF'
.spec.url = "https://registry.example.invalid/charts/sprocket"|URL is not an OCI chart URL
.spec.url = "oci://registry.example.invalid/charts/../sprocket"|URL is not an OCI chart URL
.spec.ref.tag = "1.0.0/../x"|tag 1.0.0/../x has not the shape of a tag
.spec.ref = {"digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}|a ref other than a tag
.spec.layerSelector.operation = "copy"|layerSelector
del(.spec.layerSelector)|layerSelector
EOF

  # The repository operator-definitions.yaml names, and the tag of its source object.
  definitions_app_reset
  operator_app
  objects things.yaml <<'EOF'
---
apiVersion: operator.example.invalid/v1
kind: Doohickey
metadata:
  name: right
spec:
  size: 2
EOF
  declare_operator
  recorded_validate
  grep -qxF "curl https://github.com/example-org/doohickey/archive/refs/tags/v1.0.0.tar.gz" "$FETCHED"
  yq -i '.definitions[0].repository = "https://gitlab.example.invalid/example-org/doohickey"' "$TREE/operator-definitions.yaml"
  recorded_validate
  [ "$status" -ne 0 ]
  refused_line operator-definitions.yaml "entry 1 (operator.example.invalid)" "its repository is not"
  not_fetched doohickey
  declare_operator
  yq -i '.definitions[0].repository = "https://github.com/example-org/doohickey.git"' "$TREE/operator-definitions.yaml"
  recorded_validate
  [ "$status" -ne 0 ]
  refused_line operator-definitions.yaml "entry 1 (operator.example.invalid)" "its repository ends in .git"
  not_fetched doohickey
  declare_operator
  yq -i '.spec.ref.tag = "1..0"' "$TREE/kubernetes/apps/base/demo/operator/app/ocirepository.yaml"
  recorded_validate
  [ "$status" -ne 0 ]
  refused_line operator-definitions.yaml "entry 1 (operator.example.invalid)" "v1..0 has not the shape of a tag"
  not_fetched doohickey
  # So is the version versions.yaml holds, for an entry that takes its tag from there.
  yq -i '.spec.ref.tag = "1.0.0"' "$TREE/kubernetes/apps/base/demo/operator/app/ocirepository.yaml"
  yq -i 'del(.definitions[0].sourceRef) | .definitions[0].versionsKey = "doohickey"' "$TREE/operator-definitions.yaml"
  yq -i '.doohickey = "2.0.0"' "$TREE/versions.yaml"
  recorded_validate
  grep -qxF "curl https://github.com/example-org/doohickey/archive/refs/tags/v2.0.0.tar.gz" "$FETCHED"
  yq -i '.doohickey = "1..0"' "$TREE/versions.yaml"
  recorded_validate
  [ "$status" -ne 0 ]
  refused_line operator-definitions.yaml "entry 1 (operator.example.invalid)" "v1..0 has not the shape of a tag"
  not_fetched doohickey
}

@test "a source that holds what the checks refuse in a tree is refused before anything of it is built" {
  local defs=kubernetes/apps/base/demo/defs/app edit word link
  local source="https://github.com/example-org/gizmo-crds at v1.0.0"
  definitions_app
  fetch_recorders
  # The release as the fixtures hold it is fetched, unpacked and built.
  gizmo_archive
  recorded_validate
  grep -qxF "curl https://github.com/example-org/gizmo-crds/archive/refs/tags/v1.0.0.tar.gz" "$FETCHED"
  grep -q '/sources/[0-9]*/config/crd$' "$BUILT"
  [[ $output != *"Kustomization gizmo-crds"* ]]

  # A kustomization of it that names a URL, which kustomize would fetch, the loopback's directly,
  # past the closed proxy; one that names a path that climbs out of it, or a field the checks
  # refuse; and a link in it that leads out of it.
  while IFS='|' read -r edit link word; do
    gizmo_archive "$edit" "$link"
    recorded_validate
    [ "$status" -ne 0 ]
    refused_line "$defs/gizmo-crds.yaml" "Kustomization gizmo-crds" "$source holds what the checks refuse in a tree" "$word"
    [[ $output != *"kustomize does not build"* ]]
    ! grep -F /sources/ "$BUILT" || { echo "built before it was refused"; return 1; }
  done <<'EOF'
.resources += ["http://127.0.0.1:9/x.yaml"]||config/crd/kustomization.yaml: resources names "http://127.0.0.1:9/x.yaml", which is not a plain path
.resources += ["../../../outside"]||config/crd/kustomization.yaml: resources names "../../../outside", a path that leaves the source
.transformers = ["transformer.yaml"]||config/crd/kustomization.yaml: transformers is a field the checks refuse
.resources += ["linked.yaml"]|linked.yaml|config/crd/linked.yaml: a link to /dev/null, which is no path in the source
EOF
}

@test "a key of a source or of the Kustomization that applies from it, read under another spelling, is refused before anything is fetched" {
  local defs=kubernetes/apps/base/demo/defs/app kind file
  definitions_app
  fetch_recorders
  # The Kustomization applied from a GitRepository and that GitRepository, and the OCIRepository a
  # Kustomization applies from.
  for kind in Kustomization:gizmo-crds.yaml GitRepository:gitrepository.yaml OCIRepository:ocirepository.yaml; do
    file="$defs/${kind#*:}"
    definitions_app_reset
    with_folded "${kind%%:*}" "$TREE/$file"
    recorded_validate
    names_every "$file"
    case ${kind%%:*} in
      OCIRepository) not_fetched sprocket ;;
      *) not_fetched gizmo-crds ;;
    esac
  done

  # The source object operator-definitions.yaml reads the tag of.
  definitions_app_reset
  operator_app
  declare_operator
  file=kubernetes/apps/base/demo/operator/app/ocirepository.yaml
  with_folded OCIRepository "$TREE/$file"
  recorded_validate
  names_every "$file"
  not_fetched doohickey
}
