#!/usr/bin/env bats
# Proves features/alerts.feature; each test carries its scenario's title. The scenarios whose title
# starts with "The alert" are proved by promtool unit tests in tests/rules/, through just rules-check;
# the last test here checks that those names and the scenarios agree.
# Needs helm, flux, kustomize, yq and jq on PATH (the versions pinned for the repository). The tree
# is rendered once per run, charts pulled from their public registries; every fixture is a copy of
# that render or of tests/rules and docs/runbooks with one thing broken, so nothing here drifts from
# the rules the tree has. A rule promtool refuses is proved where promtool is, by rules-check itself.

setup_file() {
  local repo
  repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG"
  export RENDER_CHART_CACHE="$BATS_FILE_TMPDIR/charts"
  mkdir -p "$RENDER_CHART_CACHE"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  KUBECONFIG=/dev/null "$repo/scripts/render" "$BATS_FILE_TMPDIR/render" > "$BATS_FILE_TMPDIR/render.log" 2>&1 ||
    { cat "$BATS_FILE_TMPDIR/render.log" >&2; return 1; }
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RENDER="$BATS_FILE_TMPDIR/render"
  CLUSTER=lab-sto2
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# own_files RENDER: the PrometheusRule files of the render that no chart made, one per line.
own_files() {
  local file
  for file in "$1/$CLUSTER"/*/PrometheusRule.*.yaml; do
    if [ "$(yq '.metadata.labels["helm.toolkit.fluxcd.io/name"] // ""' "$file")" = "" ]; then
      echo "$file"
    fi
  done
}

# own_alerts RENDER: each alert of the tree's own rules, as APPLICATION ALERT per line.
own_alerts() {
  local file
  while IFS= read -r file; do
    yq '.spec.groups[].rules[] | select(has("alert")) | .alert' "$file" | sed "s|^|$(basename "$(dirname "$file")") |"
  done < <(own_files "$1")
}

# fixture: a copy of the render, of tests/rules and of docs/runbooks to break one thing in. Sets FX
# to the directory that holds render/ and repo/.
fixture() {
  FX="$BATS_TEST_TMPDIR/fx"
  rm -rf "$FX"
  mkdir -p "$FX/repo/tests" "$FX/repo/docs"
  cp -R "$RENDER" "$FX/render"
  cp -R "$REPO/tests/rules" "$FX/repo/tests/rules"
  cp -R "$REPO/docs/runbooks" "$FX/repo/docs/runbooks"
}

# collect [OUT]: runs scripts/rules-config on the fixture, as run does.
collect() {
  run env RULES_RENDER="$FX/render" "$REPO/scripts/rules-config" "${1:-$FX/out}" "$FX/repo"
}

# own_file APPLICATION: the fixture's own PrometheusRule of the application.
own_file() {
  local file
  while IFS= read -r file; do
    [ "$(basename "$(dirname "$file")")" = "$1" ] && { echo "$file"; return; }
  done < <(own_files "$FX/render")
  echo "no own rule of $1" >&2
  return 1
}

@test "An application's own rules are loaded by the monitoring stack, and leave with the application" {
  local rule app namespace file selectors tree left
  # Each application's rule is in its own app/ directory, beside its manifests.
  local count=0
  for rule in "$REPO"/kubernetes/apps/base/*/*/app/prometheusrule.yaml; do
    count=$((count + 1))
    app="$(basename "$(dirname "$(dirname "$rule")")")"
    namespace="$(basename "$(dirname "$(dirname "$(dirname "$rule")")")")"
    file="$(ls "$RENDER/$CLUSTER/$app"/PrometheusRule.*.yaml)"
    echo "$app: $(basename "$file")"
    [ "$(yq '.metadata.namespace' "$file")" = "$namespace" ]
    [ "$(yq '.metadata.labels["helm.toolkit.fluxcd.io/name"] // ""' "$file")" = "" ]
  done
  [ "$count" -ge 3 ]
  [ "$(own_files "$RENDER" | wc -l)" -eq "$count" ]
  # The Prometheus the stack runs takes every rule in every namespace, with no label.
  selectors="$(yq -N 'select(.kind == "Prometheus") | (.spec.ruleSelector | to_json(0)) + " " + (.spec.ruleNamespaceSelector | to_json(0))' \
    "$RENDER/$CLUSTER/kube-prometheus-stack"/Prometheus.*.yaml)"
  echo "rule selectors: $selectors"
  [ "$selectors" = "{} {}" ]

  # The rules are collected for each application the overlay applies ...
  fixture
  collect
  echo "$output"
  [ "$status" -eq 0 ]
  while read -r app _; do
    [ -f "$FX/out/$CLUSTER/$app.rules.yaml" ]
  done < <(own_alerts "$RENDER")

  # ... and an application the overlay leaves out brings none: openbao is taken out of a copy of the
  # tree, and its unit tests with it.
  tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree"
  cp -R "$REPO/kubernetes" "$REPO/versions.yaml" "$tree/"
  sed -i -e '\#^  - \.\./\.\./base/openbao#d' "$tree/kubernetes/apps/overlays/$CLUSTER/kustomization.yaml"
  left="$BATS_TEST_TMPDIR/left"
  "$REPO/scripts/render" "$left" "$tree" > "$BATS_TEST_TMPDIR/left.log" 2>&1 || { cat "$BATS_TEST_TMPDIR/left.log"; return 1; }
  [ ! -e "$left/$CLUSTER/openbao" ]
  rm -f "$FX/repo/tests/rules/openbao.yaml"
  run env RULES_RENDER="$left" "$REPO/scripts/rules-config" "$BATS_TEST_TMPDIR/left-out" "$FX/repo"
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/left-out/$CLUSTER/openbao.rules.yaml" ]
  [ -f "$BATS_TEST_TMPDIR/left-out/$CLUSTER/volsync.rules.yaml" ]
  # Its unit tests left behind would test a rule that is no longer there.
  cp "$REPO/tests/rules/openbao.yaml" "$FX/repo/tests/rules/openbao.yaml"
  run env RULES_RENDER="$left" "$REPO/scripts/rules-config" "$BATS_TEST_TMPDIR/left-out2" "$FX/repo"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"tests/rules/openbao.yaml"* ]]
}

@test "An alert without a test in which it fires, or without one in which it stays quiet, fails the check" {
  local app alert lacking tests
  [ "$(own_alerts "$RENDER" | wc -l)" -ge 1 ]
  while read -r app alert; do
    for lacking in fires quiet; do
      fixture
      tests="$FX/repo/tests/rules/$app.yaml"
      if [ "$lacking" = fires ]; then
        ALERT="$alert" yq -i 'del(.tests[].alert_rule_test[] | select(.alertname == strenv(ALERT) and ((.exp_alerts // []) | length) > 0))' "$tests"
      else
        ALERT="$alert" yq -i 'del(.tests[].alert_rule_test[] | select(.alertname == strenv(ALERT) and ((.exp_alerts // []) | length) == 0))' "$tests"
      fi
      collect
      echo "$app $alert without a test in which it $lacking: status $status: $output"
      [ "$status" -ne 0 ]
      [[ $output == *"$alert"* ]]
      if [ "$lacking" = fires ]; then
        [[ $output == *"no test in which it fires"* ]]
      else
        [[ $output == *"no test in which it stays quiet"* ]]
      fi
    done
  done < <(own_alerts "$RENDER")
  # A quiet test needs series to be quiet about: with the group's input_series gone, or with no test
  # of the alert at a time before it fires, an expectation of nothing proves nothing.
  while read -r app alert; do
    fixture
    tests="$FX/repo/tests/rules/$app.yaml"
    ALERT="$alert" yq -i '(.tests[] | select(.alert_rule_test | map(.alertname) | contains([strenv(ALERT)])) | .input_series) = []' "$tests"
    collect
    echo "$app $alert, no series: status $status: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"alert $alert: no test in which it stays quiet"* ]]
    fixture
    tests="$FX/repo/tests/rules/$app.yaml"
    ALERT="$alert" yq -i '(.tests[].alert_rule_test[] | select(.alertname == strenv(ALERT) and ((.exp_alerts // []) | length) == 0)) |= (.eval_time = "10000h")' "$tests"
    collect
    echo "$app $alert, quiet only after it fires: status $status: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"alert $alert: no test in which it stays quiet"* ]]
  done < <(own_alerts "$RENDER")
  # The tree as it is passes, and a test that only expects nothing is not a test that it fires.
  fixture
  collect
  echo "$output"
  [ "$status" -eq 0 ]
  while read -r app alert; do
    fixture
    ALERT="$alert" yq -i '(.tests[].alert_rule_test[] | select(.alertname == strenv(ALERT)) | .exp_alerts) = []' "$FX/repo/tests/rules/$app.yaml"
    collect
    [ "$status" -ne 0 ]
    [[ $output == *"$alert"* && $output == *"no test in which it fires"* ]]
  done < <(own_alerts "$RENDER" | head -n 1)
}

@test "An alert without a known severity, a summary, a description or a runbook heading that exists fails the check" {
  local app alert kind file filter message
  [ "$(own_alerts "$RENDER" | wc -l)" -ge 1 ]
  while read -r app alert; do
    for kind in severity-unknown severity-missing summary description-no-labels runbook-other-repository runbook-other-host runbook-other-branch runbook-no-heading runbook-no-file for-missing; do
      fixture
      file="$(own_file "$app")"
      # Each break is refused for its own reason, which the output states. The links to another
      # repository, host or branch have the anchor of an existing heading, so only the address is wrong.
      case $kind in
        severity-unknown) filter='.labels.severity = "urgent"' message='severity is urgent' ;;
        severity-missing) filter='del(.labels.severity)' message='severity is missing' ;;
        summary) filter='del(.annotations.summary)' message='no summary' ;;
        description-no-labels) filter='.annotations.description = "something is wrong"' message='no description that names' ;;
        runbook-other-repository) filter='.annotations.runbook_url |= sub("/eekaan/"; "/someone-else/")' message='runbook_url is' ;;
        runbook-other-host) filter='.annotations.runbook_url |= sub("^https://github.com/"; "https://example.com/")' message='runbook_url is' ;;
        runbook-other-branch) filter='.annotations.runbook_url |= sub("/blob/main/"; "/blob/dev/")' message='runbook_url is' ;;
        runbook-no-heading) filter='.annotations.runbook_url |= sub("#.*$"; "#no-such-heading")' message='names a heading that is not' ;;
        runbook-no-file) filter='.annotations.runbook_url |= sub("alerts.md"; "no-such-file.md")' message='is a file that is not' ;;
        for-missing) filter='del(.for)' message='no for' ;;
      esac
      ALERT="$alert" yq -i "(.spec.groups[].rules[] | select(.alert == strenv(ALERT))) |= ($filter)" "$file"
      collect
      echo "$app $alert, $kind: status $status: $output"
      [ "$status" -ne 0 ]
      [[ $output == *"alert $alert: "*"$message"* ]]
    done
  done < <(own_alerts "$RENDER")
  # A runbook link is checked against the file in the tree: with its heading gone from the file, the
  # alert's own link fails too.
  fixture
  read -r app alert < <(own_alerts "$RENDER" | head -n 1)
  sed -i "/^#.*$alert/d" "$FX/repo/docs/runbooks/alerts.md"
  collect
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"alert $alert: "*"names a heading that is not"* ]]
}

@test "The rules are checked with the Prometheus image the chart deploys, in the static group of just ci" {
  local image rendered
  rendered="$(yq -N 'select(.kind == "Prometheus") | .spec.image' "$RENDER/$CLUSTER/kube-prometheus-stack"/Prometheus.*.yaml)"
  echo "the rendered Prometheus runs: $rendered"
  [[ $rendered =~ ^quay\.io/prometheus/prometheus:v[0-9.]+ ]]
  # scripts/rules-image names it from the stack's chart alone, as just ci's module needs it before
  # it renders anything else, and rules-config writes the one the whole render names.
  image="$("$REPO/scripts/rules-image")"
  echo "scripts/rules-image: $image"
  [ "$image" = "$rendered" ]
  fixture
  collect
  [ "$status" -eq 0 ]
  [ "$(cat "$FX/out/image")" = "$rendered" ]
  # rules-check is a check of the static group, which runs in just ci, and the module hands promtool
  # from the image to it.
  [ "$(just --justfile "$REPO/justfile" --dump --dump-format json | jq -r '.recipes.static.dependencies[].recipe | select(. == "rules-check")')" = rules-check ]
  grep -q 'rules-check' "$REPO/.dagger/modules/ci/main.dang"
  grep -q 'scripts/rules-image' "$REPO/.dagger/modules/ci/main.dang"
  # The image is the chart's: no pin of it in the justfile, the module or the tools, so no pin for
  # Renovate to miss. Dagger itself records the digest of the image it pulls in dagger.lock, and
  # that is the one entry the tree holds: for the tag the render names, so that a chart update that
  # moves the tag leaves a stale entry, which fails here until dagger lock update refreshes it.
  run grep -rIl 'prometheus/prometheus' "$REPO/justfile" "$REPO/just" "$REPO/.dagger" "$REPO/mise.toml" "$REPO/renovate.json5" "$REPO/versions.yaml"
  echo "$output"
  [ "$status" -eq 1 ]
  run grep -c 'prometheus/prometheus' "$REPO/dagger.lock"
  echo "dagger.lock entries of the Prometheus image: $output"
  [ "$output" = 1 ]
  grep 'prometheus/prometheus' "$REPO/dagger.lock" | grep -qF "[\"$rendered\"]"
  run grep -rIl 'prometheus/prometheus' "$REPO" --exclude-dir=.git --exclude-dir=.dagger --exclude-dir=docs --exclude-dir=tests --exclude-dir=features --exclude=dagger.lock --exclude=justfile
  echo "$output"
  [ "$status" -eq 1 ]
}

@test "The documentation lists every alert the tree defines" {
  local app alert url severity row names rows headings
  names="$(own_alerts "$RENDER" | cut -d' ' -f2 | sort)"
  while read -r app alert; do
    echo "$app $alert"
    url="$(yq -N 'select(.kind == "PrometheusRule") | .spec.groups[].rules[] | select(.alert == "'"$alert"'") | .annotations.runbook_url' "$RENDER/$CLUSTER/$app"/PrometheusRule.*.yaml)"
    severity="$(yq -N 'select(.kind == "PrometheusRule") | .spec.groups[].rules[] | select(.alert == "'"$alert"'") | .labels.severity' "$RENDER/$CLUSTER/$app"/PrometheusRule.*.yaml)"
    row="$(grep "^| \`$alert\` |" "$REPO/docs/kubernetes.md")"
    [ "$(wc -l <<<"$row")" -eq 1 ]
    [[ $row == *"| $severity |"* ]]
    [[ $row == *"($url) |" ]]
    grep -q "^## $alert\$" "$REPO/docs/runbooks/alerts.md"
  done < <(own_alerts "$RENDER")
  # Nothing in the table or the runbook is for an alert the tree does not define.
  rows="$(sed -n 's/^| `\([A-Za-z0-9_]*\)` | .*| \(critical\|warning\|info\) |.*$/\1/p' "$REPO/docs/kubernetes.md" | sort)"
  headings="$(sed -n 's/^## //p' "$REPO/docs/runbooks/alerts.md" | sort)"
  echo "table: $rows"
  echo "runbook: $headings"
  [ "$rows" = "$names" ]
  [ "$headings" = "$names" ]
  grep -q 'alerts go nowhere\|no destination' "$REPO/docs/kubernetes.md"
  grep -q 'just rules-check' "$REPO/README.md"
}

@test "the alert scenarios and the promtool test groups name each other" {
  local title app alert names
  # A test group's name is the title of the scenario it proves.
  names="$(yq -N '.tests[].name' "$REPO"/tests/rules/*.yaml | sort)"
  while read -r title; do
    echo "scenario: $title"
    grep -qxF -- "$title" <<<"$names"
  done < <(sed -n 's/^  Scenario: \(The alert .*\)$/\1/p' "$REPO/features/alerts.feature")
  while read -r app alert; do
    grep -qxF -- "The alert $alert fires after its time in the failing case and stays quiet in the healthy one" <<<"$names"
    grep -q "^  Scenario: The alert $alert fires after its time in the failing case and stays quiet in the healthy one\$" "$REPO/features/alerts.feature"
  done < <(own_alerts "$RENDER")
  [ "$(grep -c . <<<"$names")" -eq "$(sed -n 's/^  Scenario: \(The alert .*\)$/\1/p' "$REPO/features/alerts.feature" | wc -l)" ]
}
