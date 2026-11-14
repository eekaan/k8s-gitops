#!/usr/bin/env bats
# Proves features/pr-diff.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq, jq, git and diff on PATH (the versions pinned for the repository).
# Offline: the fixture's charts are packaged from tests/fixtures/render/charts. The OCI one is
# handed to the render through its chart cache; the registry its OCIRepository names does not
# resolve. The one a HelmRepository names is packaged at the version asked for by a stand-in for
# helm's pull from a repository, which logs what it was asked for; the repository does not resolve.

setup_file() {
  # Helm's settings, and the Docker configuration it reads registry logins from, stay in the run's
  # own directory.
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG"
  export RENDER_CHART_CACHE="$BATS_FILE_TMPDIR/charts"
  helm package "$BATS_TEST_DIRNAME/fixtures/render/charts/greeter" \
    --destination "$RENDER_CHART_CACHE/charts.example.invalid/greeter/1.0.0" >/dev/null
  export PULL_LOG="$BATS_FILE_TMPDIR/pull.log"
  export REAL_HELM LEDGER_CHART="$BATS_TEST_DIRNAME/fixtures/render/charts/ledger"
  REAL_HELM="$(command -v helm)"
  mkdir -p "$BATS_FILE_TMPDIR/bin"
  cat >"$BATS_FILE_TMPDIR/bin/helm" <<'EOF'
#!/usr/bin/env bash
# Stands in for helm pull from a repository (--repo); anything else is the real helm.
args=("$@")
if [[ ${1:-} == pull && " $* " == *" --repo "* ]]; then
  chart=${2:-}
  for ((i = 0; i < ${#args[@]}; i++)); do
    case ${args[i]} in
      --repo) repo=${args[i + 1]} ;;
      --version) version=${args[i + 1]} ;;
      --destination) destination=${args[i + 1]} ;;
    esac
  done
  echo "chart=$chart repo=$repo version=${version:-}" >>"$PULL_LOG"
  exec "$REAL_HELM" package "$LEDGER_CHART" --version "${version:?no version}" --destination "$destination"
fi
exec "$REAL_HELM" "$@"
EOF
  chmod +x "$BATS_FILE_TMPDIR/bin/helm"
  export PATH="$BATS_FILE_TMPDIR/bin:$PATH"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/render"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
}

# tree NAME: a copy of the fixture tree in $BATS_TEST_TMPDIR/NAME, for the test to change.
tree() {
  mkdir -p "$BATS_TEST_TMPDIR/$1"
  cp -R "$FIXTURE/kubernetes" "$FIXTURE/versions.yaml" "$BATS_TEST_TMPDIR/$1/"
}

# render NAME: runs just render for the tree NAME, into $BATS_TEST_TMPDIR/NAME.out.
render() {
  run just --justfile "$REPO/justfile" render "$BATS_TEST_TMPDIR/$1.out" "$BATS_TEST_TMPDIR/$1"
}

# render_direct NAME: the same without just, which puts the pinned tools ahead of the stand-in for
# helm's pull from a repository on PATH.
render_direct() {
  run "$REPO/scripts/render" "$BATS_TEST_TMPDIR/$1.out" "$BATS_TEST_TMPDIR/$1"
}

# render_both: renders the trees base and head, each of which must render.
render_both() {
  render base
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  render head
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# compare: just render-diff of the renders of base and head, into the file BODY, which the comment
# job's check must accept.
compare() {
  BODY="$BATS_TEST_TMPDIR/comment.md"
  just --justfile "$REPO/justfile" render-diff "$BATS_TEST_TMPDIR/base.out" "$BATS_TEST_TMPDIR/head.out" >"$BODY"
  cat "$BODY"
  (. "$REPO/scripts/lib/render-comment.sh" && render_comment_check "$BODY")
}

# object DIR KIND NAME: the object of KIND named NAME among the files of the application's render
# in DIR.
object() {
  yq -N "select(.kind == \"$2\" and .metadata.name == \"$3\")" "$1"/*.yaml
}

# rows: the rows of the comment's summary table, one per application.
rows() {
  grep -E '^\| `' "$BODY" || true
}

# row APP ADDED REMOVED CHANGED...: the summary table's rows for each application APP with the
# numbers of objects it adds, removes and changes, given four words per row.
row() {
  # shellcheck disable=SC2016 # a Markdown code span
  printf '| `%s` | %s | %s | %s |\n' "$@"
}

# object_diff APP PATTERN: the diff lines of the object of APP whose file name matches PATTERN.
object_diff() {
  awk -v want="+++ b/$1/" -v pattern="$2" '
    index($0, "+++ ") == 1 { inside = (index($0, want) == 1 && $0 ~ pattern); next }
    index($0, "--- ") == 1 || /^```/ { inside = 0 }
    inside' "$BODY"
}

@test "Every enabled application is rendered to the objects Flux would apply, charts expanded" {
  tree base

  render base

  [ "$status" -eq 0 ]
  local out="$BATS_TEST_TMPDIR/base.out/demo" deployment hr
  [ "$(find "$out" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd' ')" = "cluster flux-system greeter monitoring-crds site" ]
  # The sync applies the root, and the root the namespace and the enabled applications'
  # Kustomizations, with its defaults; the disabled one's is not there.
  [ "$(object "$out/flux-system" Kustomization cluster | yq '.spec.path')" = ./apps/overlays/demo ]
  [ "$(object "$out/cluster" Namespace web | yq '.metadata.name')" = web ]
  [ "$(object "$out/cluster" Kustomization greeter | yq '.spec.prune')" = true ]
  [ -z "$(object "$out/cluster" Kustomization later)" ]
  # Manifests with the example values substituted, in the target namespace, labelled by Flux.
  deployment="$(object "$out/site" Deployment site)"
  [ "$(yq '.spec.template.spec.containers[0].env[0].value' <<<"$deployment")" = "hello from the example" ]
  [ "$(yq '.metadata.namespace' <<<"$deployment")" = web ]
  [ "$(yq '.metadata.labels["kustomize.toolkit.fluxcd.io/name"]' <<<"$deployment")" = site ]
  # The HelmRelease with the root's release defaults, and beside it what its chart renders: the
  # repository's values over the chart's, the HelmRelease's own values substituted over those.
  hr="$(object "$out/greeter" HelmRelease greeter)"
  [ "$(yq '.spec.install.remediation.retries' <<<"$hr")" = 3 ]
  [ -n "$(object "$out/greeter" OCIRepository greeter)" ]
  deployment="$(object "$out/greeter" Deployment greeter)"
  [ "$(yq '.spec.replicas' <<<"$deployment")" = 1 ]
  [ "$(yq '.spec.template.spec.containers[0].env[0].value' <<<"$deployment")" = greeter.example.com ]
  [ "$(yq '.metadata.namespace' <<<"$deployment")" = web ]
  # Post-rendered and labelled as helm-controller does.
  [ "$(yq '.metadata.annotations["fixture/post-rendered"]' <<<"$deployment")" = true ]
  [ "$(yq '.metadata.labels["helm.toolkit.fluxcd.io/name"]' <<<"$deployment")" = greeter ]
  [ "$(yq '.metadata.labels["helm.toolkit.fluxcd.io/namespace"]' <<<"$deployment")" = web ]
  # A value the chart makes up anew on every render is masked, so it never shows as a change.
  [ "$(yq '.spec.template.metadata.annotations["checksum/random"]' <<<"$deployment")" = "(generated at render time)" ]
  # The chart's definitions, and the monitor it renders only where the cluster serves the
  # monitoring API, which another application defines.
  [ "$(object "$out/greeter" CustomResourceDefinition greetings.example.com | yq '.spec.group')" = example.com ]
  [ "$(object "$out/greeter" ServiceMonitor greeter | yq '.metadata.namespace')" = web ]
  [ -n "$(object "$out/greeter" Secret greeter)" ]
}

@test "A changed value shows as a changed object in that application's diff, and nowhere else" {
  tree base
  tree head
  yq -i '.replicas = 2' "$BATS_TEST_TMPDIR/head/kubernetes/apps/base/web/greeter/app/values.yaml"
  render_both

  compare

  [ "$(rows)" = "$(row demo/greeter 0 0 3)" ]
  run object_diff demo/greeter Deployment
  printf '%s\n' "$output"
  [[ $output == *$'\n-  replicas: 1\n+  replicas: 2'* ]]
}

@test "An added and a removed application show as added and removed objects" {
  tree base
  tree head
  local overlay="$BATS_TEST_TMPDIR/head/kubernetes/apps/overlays/demo/kustomization.yaml"
  sed -i -e 's|^  # - \(../../base/web/later/ks.yaml\).*|  - \1|' -e '\|base/web/site/ks.yaml|d' "$overlay"
  render_both

  compare

  [ "$(rows)" = "$(row demo/cluster 1 1 0 demo/later 1 0 0 demo/site 0 2 0)" ]
  run object_diff demo/later ConfigMap
  [[ $output == *$'\n+  name: later'* ]]
  run object_diff demo/site Deployment
  [[ $output == *$'\n-  name: site'* ]]
}

@test "A change that renders identically says nothing changed" {
  tree base
  tree head
  printf '# A comment changes nothing Flux applies.\n' >>"$BATS_TEST_TMPDIR/head/kubernetes/apps/base/web/site/app/deployment.yaml"
  printf '# Nor does this one.\n' >>"$BATS_TEST_TMPDIR/head/kubernetes/apps/base/web/greeter/app/helmrelease.yaml"
  render_both

  compare

  grep -qxF 'Nothing that Flux applies changes.' "$BODY"
  [ -z "$(rows)" ]
  run grep -c -e '<details>' -e '^```' "$BODY"
  [ "$output" = 0 ]
}

@test "No Secret's data appears in a render or a diff" {
  tree base
  tree head
  local app="$BATS_TEST_TMPDIR/head/kubernetes/apps/base/web" value values=() secret
  # data as well as stringData, written here so that no file of the repository holds a Secret's data.
  config="$(printf %s fixture-site-config-value | base64)" \
    yq -i '.data.config = strenv(config)' "$BATS_TEST_TMPDIR/base/kubernetes/apps/base/web/site/app/secret.yaml"
  config="$(printf %s fixture-site-config-other | base64)" token=fixture-site-token-other \
    yq -i '.data.config = strenv(config) | .stringData.token = strenv(token)' "$app/site/app/secret.yaml"
  yq -i '.password = "fixture-chart-other"' "$app/greeter/app/values.yaml"
  render_both

  compare

  # The values the two trees give the Secrets, plain and in base64: the chart derives its own from
  # its values, so that value is in no file of the tree.
  for value in fixture-site-token-value fixture-site-token-other fixture-site-config-value \
    fixture-site-config-other fixture-chart-password-for-greeter fixture-chart-other-for-greeter; do
    values+=("$value" "$(printf %s "$value" | base64)")
  done
  for value in "${values[@]}"; do
    run grep -rlF -e "$value" "$BATS_TEST_TMPDIR/base.out" "$BATS_TEST_TMPDIR/head.out" "$BODY"
    [ "$status" -eq 1 ] || { echo "$value is in $output"; return 1; }
  done
  # The Secrets themselves are there, with their keys.
  for out in base.out head.out; do
    secret="$(object "$BATS_TEST_TMPDIR/$out/demo/site" Secret site-token)"
    [ "$(yq -o json -I0 '[.stringData, .data]' <<<"$secret")" = '[{"token":"(redacted)"},{"config":"(redacted)"}]' ]
    [ "$(yq 'has("sops")' <<<"$secret")" = false ]
    secret="$(object "$BATS_TEST_TMPDIR/$out/demo/greeter" Secret greeter)"
    [ "$(yq -o json -I0 '.data | to_entries | sort_by(.key) | from_entries' <<<"$secret")" = '{"generated":"(redacted)","password":"(redacted)"}' ]
  done
}

@test "A diff too large for one comment is truncated and says so" {
  tree base
  tree head
  local site="$BATS_TEST_TMPDIR/head/kubernetes/apps/base/web/site/app" i size
  {
    printf -- '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: large\ndata:\n'
    for ((i = 0; i < 3000; i++)); do
      printf '  key-%04d: a value long enough to fill a comment quickly\n' "$i"
    done
  } >"$site/large.yaml"
  yq -i '.resources += ["large.yaml"]' "$site/kustomization.yaml"
  yq -i '.replicas = 2' "$BATS_TEST_TMPDIR/head/kubernetes/apps/base/web/greeter/app/values.yaml"
  render_both

  compare >/dev/null

  size=$(wc -c <"$BODY")
  echo "comment: $size bytes"
  # GitHub refuses a comment over 65536 characters; no character takes less than a byte.
  [ "$size" -le 65536 ]
  grep -q 'truncated' "$BODY"
  # The whole summary and the footer stay.
  [ "$(rows)" = "$(row demo/greeter 0 0 3 demo/site 1 0 0)" ]
  grep -qF 'cluster-config.example.yaml' "$BODY"
  # Every block it opens is closed.
  [ "$(grep -c '^<details>' "$BODY")" -eq "$(grep -c '^</details>' "$BODY")" ]
  [ $(($(grep -c '^```' "$BODY") % 2)) -eq 0 ]
}

@test "render-diff fences each diff with more backquotes than any line of it holds" {
  tree base
  tree head
  # A value that would end a code block of six backquotes or fewer, and start one of its own.
  printf -- '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: fences\ndata:\n  fence: |\n    ``````\n    <details><summary>not a section</summary>\n' \
    >"$BATS_TEST_TMPDIR/head/kubernetes/apps/base/web/later/app/configmap.yaml"
  sed -i 's|^  # - \(../../base/web/later/ks.yaml\).*|  - \1|' "$BATS_TEST_TMPDIR/head/kubernetes/apps/overlays/demo/kustomization.yaml"
  render_both

  compare

  grep -qxF '+    ``````' "$BODY"
  # The application's diff opens and closes with a longer fence, and only fences start a line with
  # backquotes.
  run grep -B1 -xF -- '--- a/demo/later/ConfigMap_web_fences.yaml' "$BODY"
  [[ ${lines[0]} =~ ^\`{7,}diff$ ]]
  fence=${lines[0]%diff}
  grep -qxF "$fence" "$BODY"
  run grep -E '^`' "$BODY"
  while IFS= read -r line; do
    [[ $line =~ ^\`{3,}(diff)?$ ]] || { echo "not a fence: $line"; return 1; }
  done <<<"$output"
  [ "$(grep -c '^<details>' "$BODY")" -eq 2 ]
}

@test "render fails, naming the application, when a chart does not render" {
  tree base
  yq -i '.broken = true' "$BATS_TEST_TMPDIR/base/kubernetes/apps/base/web/greeter/app/values.yaml"

  render base

  [ "$status" -ne 0 ]
  [[ $output == *"demo/greeter"* ]]
  [[ $output == *"the greeter chart refuses broken: true"* ]]
}

# repository NAME: a git repository in $BATS_TEST_TMPDIR/NAME whose one commit, the base, holds the
# fixture tree; sets WORK.
repository() {
  WORK="$BATS_TEST_TMPDIR/$1"
  tree "$1"
  mkdir -p "$WORK/scripts"
  git -C "$WORK" init -q -b main
  commit base
}

# commit MESSAGE: commits everything in WORK with MESSAGE.
commit() {
  git -C "$WORK" add -A
  git -C "$WORK" -c user.name=test -c user.email=test@example.invalid commit -q -m "$1"
}

# render_code: puts this checkout's render code in WORK.
render_code() {
  mkdir -p "$WORK/scripts/lib"
  cp "$REPO/scripts/render" "$REPO/scripts/render-diff" "$REPO/scripts/render-pr" "$WORK/scripts/"
  cp "$REPO/scripts/lib/render-comment.sh" "$WORK/scripts/lib/"
}

@test "render-pr renders both commits with the base's render code, or this checkout's when the base has none" {
  repository with-code
  render_code
  # The base's render-diff marks the comments it writes; the head has this checkout's.
  mv "$WORK/scripts/render-diff" "$WORK/scripts/render-diff.unmarked"
  cat >"$WORK/scripts/render-diff" <<'EOF'
#!/usr/bin/env bash
"$(dirname "$0")/render-diff.unmarked" "$@"
echo "written by the base's render-diff"
EOF
  chmod +x "$WORK/scripts/render-diff"
  commit "mark the base's render-diff"
  render_code
  yq -i '.replicas = 2' "$WORK/kubernetes/apps/base/web/greeter/app/values.yaml"
  commit "change a value"

  # Without a base, the base is the first parent of HEAD.
  run bash -c 'cd "$1" && scripts/render-pr "" "$2"' bash "$WORK" "$BATS_TEST_TMPDIR/with-code.md"

  [ "$status" -eq 0 ]
  BODY="$BATS_TEST_TMPDIR/with-code.md"
  grep -qxF "written by the base's render-diff" "$BODY"
  [ "$(rows)" = "$(row demo/greeter 0 0 3)" ]

  repository without-code
  render_code
  yq -i '.replicas = 2' "$WORK/kubernetes/apps/base/web/greeter/app/values.yaml"
  commit "add the render code and change a value"

  run bash -c 'cd "$1" && scripts/render-pr HEAD~1 "$2"' bash "$WORK" "$BATS_TEST_TMPDIR/without-code.md"

  [ "$status" -eq 0 ]
  [[ $output == *"the base has no render code"* ]]
  BODY="$BATS_TEST_TMPDIR/without-code.md"
  [ "$(rows)" = "$(row demo/greeter 0 0 3)" ]
}

# ledger NAME: a copy of the fixture tree in $BATS_TEST_TMPDIR/NAME that enables the ledger, whose
# chart comes from a Helm repository; sets LEDGER to its application directory.
ledger() {
  tree "$1"
  sed -i 's|^  # - \(../../base/web/ledger/ks.yaml\).*|  - \1|' "$BATS_TEST_TMPDIR/$1/kubernetes/apps/overlays/demo/kustomization.yaml"
  LEDGER="$BATS_TEST_TMPDIR/$1/kubernetes/apps/base/web/ledger/app"
}

# refused FILE EXPRESSION WORDS: the ledger with the yq EXPRESSION applied to its FILE is refused,
# the message naming the release and holding WORDS.
refused() {
  n=$((${n:-0} + 1))
  ledger "refused-$n"
  yq -i "$2" "$LEDGER/$1"

  if message="$("$REPO/scripts/render" "$BATS_TEST_TMPDIR/refused-$n.out" "$BATS_TEST_TMPDIR/refused-$n" 2>&1)"; then
    echo "$2: rendered"
    return 1
  fi

  [[ $message == *"demo/ledger: HelmRelease web/ledger"* ]] || { echo "$2: $message"; return 1; }
  [[ $message == *"$3"* ]] || { echo "$2: $message"; return 1; }
}

@test "A release whose chart comes from a Helm repository is rendered to the objects its chart renders at the pinned version" {
  ledger base
  rm -f "$PULL_LOG"

  render_direct base

  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local out="$BATS_TEST_TMPDIR/base.out/demo/ledger" config
  # The chart is pulled by name from the repository's URL at exactly the version the release pins.
  [ "$(cat "$PULL_LOG")" = "chart=ledger repo=https://charts.example.invalid/stable version=2.3.4" ]
  config="$(object "$out" ConfigMap ledger)"
  [ "$(yq '.data["chart-version"]' <<<"$config")" = 2.3.4 ]
  [ "$(yq '.data.greeting' <<<"$config")" = "from the release" ]
  [ "$(yq '.metadata.namespace' <<<"$config")" = web ]
  [ "$(yq '.metadata.labels["helm.toolkit.fluxcd.io/name"]' <<<"$config")" = ledger ]
  [ -n "$(object "$out" HelmRepository ledger)" ]
}

@test "A release whose chart version is not exact, or whose source needs a credential, is refused, and the refusal names it" {
  rm -f "$PULL_LOG"

  refused helmrelease.yaml '.spec.chart.spec.version = "~2.3.0"' "not an exact version"
  refused helmrelease.yaml '.spec.chart.spec.version = ">=2.0.0"' "not an exact version"
  refused helmrelease.yaml '.spec.chart.spec.version = "2.x"' "not an exact version"
  refused helmrelease.yaml 'del(.spec.chart.spec.version)' "not an exact version"
  refused helmrelease.yaml '.spec.chart.spec.chart = "--repo"' "not a chart name"
  refused helmrelease.yaml '.spec.chart.spec.sourceRef.kind = "GitRepository"' "a GitRepository"
  refused helmrepository.yaml '.spec.url = "http://charts.example.invalid/stable"' "not an https"
  refused helmrepository.yaml '.spec.url = "https://user@charts.example.invalid/stable"' "not an https"
  refused helmrepository.yaml '.spec.secretRef.name = "registry-login"' "secretRef"
  refused helmrepository.yaml '.spec.certSecretRef.name = "registry-ca"' "certSecretRef"
  refused helmrepository.yaml '.spec.type = "oci"' "not an oci://"
  # Nothing was pulled for any of them.
  [ ! -e "$PULL_LOG" ]
}

@test "Every release the cluster's overlay enables is one the render accepts" {
  run "$REPO/scripts/render" --forms "$REPO"

  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ $output == *"releases accepted"* ]]

  # A form the render refuses fails it, naming the release, with nothing pulled.
  ledger refused
  yq -i '.spec.chart.spec.version = "~2.3.0"' "$LEDGER/helmrelease.yaml"
  rm -f "$PULL_LOG"
  run "$REPO/scripts/render" --forms "$BATS_TEST_TMPDIR/refused"
  [ "$status" -ne 0 ]
  [[ $output == *"demo/ledger: HelmRelease web/ledger: chart version ~2.3.0 is not an exact version"* ]]
  [ ! -e "$PULL_LOG" ]
}
