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

# validate: runs the check on the fixture tree; its output shows when a test fails.
validate() {
  run "$VALIDATE" "$TREE"
  echo "$output"
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

@test "The tree passes the schema and image rules" {
  # The repository's own tree is validated against the real schemas and its charts are pulled from
  # their publishers: the fixtures' schema location is left unset.
  unset KUBERNETES_VALIDATE_SCHEMAS
  run "$VALIDATE"
  echo "$output"
  [ "$status" -eq 0 ]

  # Every rule had something to look at: objects validated against a schema, the ones without a
  # schema counted by kind, and the images of the rendered releases looked at.
  [[ $output =~ ([1-9][0-9]*)\ flux\ builds ]]
  [[ $output =~ ([1-9][0-9]*)\ objects\ validated ]]
  [[ $output =~ ([1-9][0-9]*)\ images ]]
  grep -qE '^kubernetes-validate: no schema for [A-Za-z]+ \([^)]+\): [1-9][0-9]* objects?$' <<<"$output"
}

@test "An object with a field its schema does not have is refused, and objects without a schema are counted by kind" {
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

  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hello/app/deployment.yaml "Deployment hello" replicaz
  refused_line kubernetes/apps/base/demo/hello/ks.yaml "Kustomization hello" waitt
  # The kinds with no schema are not failures, and none is passed over unnamed.
  grep -qxF "kubernetes-validate: no schema for Widget (example.invalid/v1): 2 objects" <<<"$output"
  grep -qxF "kubernetes-validate: no schema for Gadget (example.invalid/v1): 1 object" <<<"$output"

  yq -i 'del(.spec.waitt)' "$TREE/kubernetes/apps/base/demo/hello/ks.yaml"
  yq -i 'del(.spec.replicaz) | .spec.replicas = 2' "$TREE/$dir/deployment.yaml"
  validate
  [ "$status" -eq 0 ]
  grep -qxF "kubernetes-validate: no schema for Widget (example.invalid/v1): 2 objects" <<<"$output"
  grep -qxF "kubernetes-validate: no schema for Gadget (example.invalid/v1): 1 object" <<<"$output"

  # A definition the render holds, here the fixture chart's for Widget, gives its kind a schema,
  # unknown fields refused at every level, the object's own top level included.
  hooked_app '{}'
  yq -i 'select(.metadata.name == "second") |= (.spec.colour = "red" | .spec.size = 1)' "$TREE/$dir/widgets.yaml"
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hello/app/widgets.yaml "Widget second" colour
  [[ $output != *"no schema for Widget"* ]]
  grep -qxF "kubernetes-validate: no schema for Gadget (example.invalid/v1): 1 object" <<<"$output"
  yq -i 'select(.metadata.name == "second") |= (del(.spec.colour) | .spek = {})' "$TREE/$dir/widgets.yaml"
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hello/app/widgets.yaml "Widget second" spek
  yq -i 'select(.metadata.name == "second") |= del(.spek)' "$TREE/$dir/widgets.yaml"
  validate
  [ "$status" -eq 0 ]
  [[ $output != *"no schema for Widget"* ]]
  # A field the definition types is held to its type.
  yq -i 'select(.metadata.name == "second") |= .spec.size = "large"' "$TREE/$dir/widgets.yaml"
  validate
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/hello/app/widgets.yaml "Widget second" size
  yq -i 'select(.metadata.name == "second") |= .spec.size = 1' "$TREE/$dir/widgets.yaml"

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
