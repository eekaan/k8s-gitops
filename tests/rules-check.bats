#!/usr/bin/env bats
# Proves features/alerts.feature; each test carries its scenario's title. The scenarios whose title
# starts with "The alert" are proved by promtool unit tests in tests/rules/, through just rules-check;
# the last but one test here checks that those names and the scenarios agree, and the last that every
# metric they read is scraped.
# Needs helm, flux, kustomize, yq and jq on PATH (the versions pinned for the repository). The tree
# is rendered once per run, charts pulled from their public registries; every fixture is a copy of
# that render or of tests/rules and docs/runbooks with one thing broken, so nothing here drifts from
# the rules the tree has. A rule promtool refuses is proved where promtool is, by rules-check itself.

# selected, which matches a monitor with what it selects, and the operator-made targets of the storage
# layer.
load fixtures/monitors

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
  # tree, and its unit tests with it, those of the snapshot job in the namespace among them.
  tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree"
  cp -R "$REPO/kubernetes" "$REPO/versions.yaml" "$tree/"
  sed -i -e '\#^  - \.\./\.\./base/openbao#d' "$tree/kubernetes/apps/overlays/$CLUSTER/kustomization.yaml"
  left="$BATS_TEST_TMPDIR/left"
  "$REPO/scripts/render" "$left" "$tree" > "$BATS_TEST_TMPDIR/left.log" 2>&1 || { cat "$BATS_TEST_TMPDIR/left.log"; return 1; }
  [ ! -e "$left/$CLUSTER/openbao" ]
  rm -f "$FX/repo/tests/rules/openbao.yaml" "$FX/repo/tests/rules/openbao-snapshots.yaml"
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

# promtool_calls LOG ARGS: the files of each call in LOG whose arguments are ARGS and then files,
# one per line, sorted.
promtool_calls() {
  grep "^$2 [^-]" "$1" | sed "s|^$2 ||" | tr ' ' '\n' | sort
}

@test "rules-promtool runs promtool's check on every rule file, the charts' and the tree's own, and its unit tests on every test file" {
  local fake log cluster clusters=0
  fixture
  collect
  [ "$status" -eq 0 ]
  # A promtool that records each call, and fails the call whose arguments start with FAIL.
  fake="$BATS_TEST_TMPDIR/promtool"
  log="$BATS_TEST_TMPDIR/promtool.log"
  # shellcheck disable=SC2016 # expanded when the fake runs
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$PROMTOOL_LOG"' \
    '[[ -n ${FAIL-} && "$*" == "$FAIL"* ]] && exit 1' 'exit 0' > "$fake"
  chmod +x "$fake"
  run env PROMTOOL_LOG="$log" "$REPO/scripts/rules-promtool" "$FX/out" "$fake"
  echo "$output"
  cat "$log"
  [ "$status" -eq 0 ]
  for cluster in "$FX/out"/*/; do
    cluster="$(basename "$cluster")"
    clusters=$((clusters + 1))
    # Every chart's rules, with promtool's lint printed but not fatal; every own rule, with lint
    # fatal; every unit test file.
    compgen -G "$FX/out/$cluster/stock.*.rules.yaml" > /dev/null
    compgen -G "$FX/out/$cluster/*.test.yaml" > /dev/null
    [ "$(promtool_calls "$log" "check rules" | grep "^$cluster/")" = "$(cd "$FX/out" && printf '%s\n' "$cluster"/stock.*.rules.yaml | sort)" ]
    [ "$(promtool_calls "$log" "check rules --lint-fatal" | grep "^$cluster/")" = "$(cd "$FX/out" && printf '%s\n' "$cluster"/*.rules.yaml | grep -v "^$cluster/stock\." | sort)" ]
    [ "$(promtool_calls "$log" "test rules" | grep "^$cluster/")" = "$(cd "$FX/out" && printf '%s\n' "$cluster"/*.test.yaml | sort)" ]
  done
  # A step promtool fails fails the run, and the other steps still run, so one report holds every
  # failure.
  for fail in "check rules $CLUSTER/stock." "check rules --lint-fatal" "test rules"; do
    rm -f "$log"
    run env PROMTOOL_LOG="$log" FAIL="$fail" "$REPO/scripts/rules-promtool" "$FX/out" "$fake"
    echo "failing $fail: status $status: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"promtool refused a rule or a test"* ]]
    [ "$(grep -c "^check rules [^-]\|^check rules --lint-fatal \|^test rules " "$log")" -eq $((3 * clusters)) ]
  done
}

@test "An alert without a test in which it fires, or without one in which it stays quiet, fails the check" {
  local app alert lacking tests times time
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
  # A quiet test needs series to be quiet about: with the group's input_series gone, with series that
  # start only after the group's tests or are gone before them, or with no test of the alert at a
  # time before it fires, an expectation of nothing proves nothing.
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
    ALERT="$alert" yq -i '(.tests[] | select(.alert_rule_test | map(.alertname) | contains([strenv(ALERT)])) | .input_series[].values) |= "_x10000 " + .' "$tests"
    collect
    echo "$app $alert, series that start later: status $status: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"alert $alert: no test in which it stays quiet"* ]]
    fixture
    tests="$FX/repo/tests/rules/$app.yaml"
    ALERT="$alert" yq -i '(.tests[] | select(.alert_rule_test | map(.alertname) | contains([strenv(ALERT)])) | .input_series[].values) = "1 stale"' "$tests"
    collect
    echo "$app $alert, series gone before: status $status: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"alert $alert: no test in which it stays quiet"* ]]
    fixture
    tests="$FX/repo/tests/rules/$app.yaml"
    ALERT="$alert" yq -i '(.tests[].alert_rule_test[] | select(.alertname == strenv(ALERT) and ((.exp_alerts // []) | length) == 0)) |= (.eval_time = "10000h")' "$tests"
    collect
    echo "$app $alert, quiet only after it fires: status $status: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"alert $alert: no test in which it stays quiet"* ]]
    # Every series must have a sample: one series of the group that starts later, or whose last
    # sample is more than the 5 minutes Prometheus looks back old at each quiet test, is enough.
    fixture
    tests="$FX/repo/tests/rules/$app.yaml"
    ALERT="$alert" yq -i '(.tests[] | select(.alert_rule_test | map(.alertname) | contains([strenv(ALERT)])) | .input_series[0].values) |= "_x10000 " + .' "$tests"
    collect
    echo "$app $alert, one series that starts later: status $status: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"alert $alert: no test in which it stays quiet, an alert_rule_test"* ]]
    fixture
    tests="$FX/repo/tests/rules/$app.yaml"
    ALERT="$alert" yq -i '(.tests[] | select(.alert_rule_test | map(.alertname) | contains([strenv(ALERT)])) | .input_series[0].values) = "1"' "$tests"
    collect
    echo "$app $alert, one series with only an old sample: status $status: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"alert $alert: no test in which it stays quiet, an alert_rule_test"* ]]
    # Its tests in which it fires one evaluation later: the quiet test one evaluation before each is
    # then two before, and nothing pins when the alert starts to fire. The tests' times are minutes,
    # an evaluation apart.
    fixture
    tests="$FX/repo/tests/rules/$app.yaml"
    [ "$(yq '.evaluation_interval // "1m"' "$tests")" = 1m ]
    times="$(ALERT="$alert" yq '.tests[].alert_rule_test[] | select(.alertname == strenv(ALERT)) | .eval_time' "$tests")"
    [ -n "$times" ]
    while read -r time; do
      [[ $time =~ ^[0-9]+m$ ]]
    done <<<"$times"
    ALERT="$alert" yq -i '(.tests[].alert_rule_test[] | select(.alertname == strenv(ALERT) and ((.exp_alerts // []) | length) > 0) | .eval_time) |= ((sub("m$"; "") | to_number) + 1 | tostring) + "m"' "$tests"
    collect
    echo "$app $alert, firing one evaluation later: status $status: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"alert $alert: no test in which it stays quiet one evaluation"* ]]
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
  local image rendered named moved tag other moved_image line
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
  # The image is the chart's, by the tag the chart names, which Renovate moves with the chart:
  # nothing else git would commit names it, so there is no pin for Renovate to miss. The docs, tests
  # and features name it as text. dagger.lock is Dagger's record of the lookups it made: just ci
  # puts the file back after each run, and just lock-check fails on a committed entry for the
  # image, so the working copy's is the one file left out here. scripts/lib/derived-images.sh names the
  # repository for that check, with no tag or digest to pin.
  # The list is written first, so a git that fails fails the test, and must hold the justfile.
  (cd "$REPO" && git ls-files -z --cached --others --exclude-standard -- . ':!docs/' ':!tests/' ':!features/' ':!dagger.lock' ':!scripts/lib/derived-images.sh') > "$BATS_TEST_TMPDIR/files"
  tr '\0' '\n' < "$BATS_TEST_TMPDIR/files" | grep -qx justfile
  named="$(cd "$REPO" && while IFS= read -r -d '' file; do [ ! -f "$file" ] || grep -Il -- 'prometheus/prometheus' "$file" || true; done < "$BATS_TEST_TMPDIR/files")"
  echo "files that name the image: $named"
  [ -z "$named" ]
  run grep -E 'prometheus/prometheus[:@]' "$REPO/scripts/lib/derived-images.sh"
  [ "$status" -eq 1 ]
  # A chart update that moves the tag moves the image with it: a copy of the tree whose chart names
  # another tag gives the module that tag, with nothing else changed.
  moved="$BATS_TEST_TMPDIR/moved"
  mkdir -p "$moved"
  cp -R "$REPO/scripts" "$REPO/kubernetes" "$REPO/versions.yaml" "$moved/"
  tag=${rendered##*:}
  other=${tag%-distroless}
  [[ $other != "$tag" ]] || other=$tag-distroless
  TAG=$other yq -i '.prometheus.prometheusSpec.image.tag = strenv(TAG)' "$moved/kubernetes/apps/base/monitoring/kube-prometheus-stack/app/values.yaml"
  image="$("$moved/scripts/rules-image")"
  echo "with the tag moved: $image"
  [ "$image" = "${rendered%:*}:$other" ]
  # just rules-check runs promtool in the image the render names, with no network: with a render
  # whose Prometheus names another image, every container it starts is of that image. A docker that
  # runs nothing accepts every rule, which the refusal then fails.
  fixture
  moved_image=example.invalid/prometheus/prometheus:v0.0.0-moved
  IMAGE=$moved_image yq -i '.spec.image = strenv(IMAGE)' "$FX/render/$CLUSTER/kube-prometheus-stack"/Prometheus.*.yaml
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # shellcheck disable=SC2016 # expanded when the fake runs
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$DOCKER_LOG"' > "$BATS_TEST_TMPDIR/bin/docker"
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log" RULES_RENDER="$FX/render" \
    just --justfile "$REPO/justfile" rules-check
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"rules-refusal: promtool accepted"* ]]
  cat "$BATS_TEST_TMPDIR/docker.log"
  [ "$(grep -c . "$BATS_TEST_TMPDIR/docker.log")" -ge 3 ]
  while read -r line; do
    [[ $line == "run --rm --network none "*" --entrypoint promtool $moved_image "* ]]
  done < "$BATS_TEST_TMPDIR/docker.log"
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
  # Nothing in the table or the runbook is for an alert the tree does not define: every row of the
  # table, whatever its cells hold.
  rows="$(awk '/^\| Alert \| What it means \| Severity \| Runbook \|$/ { table = 1; next }
    table && !/^\|/ { exit }
    table && !/^\| -/ { split($0, cell, "|"); gsub(/[` ]/, "", cell[2]); print cell[2] }' "$REPO/docs/kubernetes.md" | sort)"
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

# The metrics of the tree's own alerts and where each is scraped, one entry for each source:
#   METRIC REGEX|APPLICATION|MONITOR FILE|TARGET FILE|NAMESPACE
# where the monitor and the target are files of the render of the application, without .yaml, and
# NAMESPACE is where an object the render holds without one lands. The target is a Service of a
# ServiceMonitor or the workload of a PodMonitor, or recorded:NAME, the operator's object of that name
# in linstor_targets, which the operator makes at run time and the render therefore does not hold.
# Metrics of the same source share an entry; an alert on a metric no entry matches fails.
scrapes=(
  # Prometheus' own series of each scrape: its target is up or it is not.
  '^up$|-|-|-|-'
  '^kube_|kube-prometheus-stack|ServiceMonitor.monitoring.coreos.com_monitoring_kube-prometheus-stack-kube-state-metrics|Service_monitoring_kube-prometheus-stack-kube-state-metrics|monitoring'
  '^volsync_|volsync|ServiceMonitor.monitoring.coreos.com__volsync|Service__volsync-metrics|volsync-system'
  '^vector_|vector|PodMonitor.monitoring.coreos.com_monitoring_vector|DaemonSet.apps_monitoring_vector|monitoring'
  '^certmanager_|cert-manager|ServiceMonitor.monitoring.coreos.com_cert-manager_cert-manager|Service_cert-manager_cert-manager|cert-manager'
  '^external_dns_|external-dns|ServiceMonitor.monitoring.coreos.com_external-dns_external-dns|Service_external-dns_external-dns|external-dns'
  '^flux_|flux-monitoring|ServiceMonitor.monitoring.coreos.com_monitoring_flux-operator|flux-operator/Service_flux-system_flux-operator|monitoring'
  '^cilium_|cilium-monitoring|PodMonitor.monitoring.coreos.com_kube-system_cilium-agent|cilium/DaemonSet.apps_kube-system_cilium|kube-system'
  '^linstor_|linstor-monitoring|ServiceMonitor.monitoring.coreos.com_piraeus-datastore_linstor-controller|recorded:Service/linstor-controller|piraeus-datastore'
  '^drbd_|linstor-monitoring|PodMonitor.monitoring.coreos.com_piraeus-datastore_linstor-satellite|recorded:Pod/linstor-satellite|piraeus-datastore'
)

# own_metrics RENDER: the metrics each own alert of the render reads, as APPLICATION ALERT METRIC per
# line: the names left in its expression once strings, label matchers, ranges, the label lists of
# by, on and the like, and PromQL's own words are taken out.
own_metrics() {
  local file app
  while IFS= read -r file; do
    app="$(basename "$(dirname "$file")")"
    yq -N -o json -I0 '.spec.groups[].rules[] | select(has("alert")) | {"alert": .alert, "expr": .expr}' "$file" |
      jq -r --arg app "$app" --argjson words '["sum","count","avg","min","max","quantile","rate","increase","delta","absent","last_over_time","label_replace","vector","scalar","time","and","or","unless","bool","by","without","on","ignoring","group_left","group_right"]' '
        .alert as $alert | .expr
        | gsub("\"[^\"]*\""; "") | gsub("\\{[^}]*\\}"; "") | gsub("\\[[^\\]]*\\]"; "")
        | gsub("(by|without|on|ignoring|group_left|group_right)[ \t\n]*\\([^)]*\\)"; "")
        | [scan("[a-zA-Z_:][a-zA-Z0-9_:]*")] | map(select(. as $word | $words | index($word) | not)) | unique[]
        | $app + " " + $alert + " " + .'
  done < <(own_files "$1")
}

# scrape_problem RENDER ENTRY: what is wrong with where an entry of scrapes says a metric is scraped,
# nothing when it is right: the monitor is in the render and selects the target through a port the
# target exposes.
scrape_problem() {
  local render="$1/$CLUSTER" regex app monitor target namespace file candidates json scraped pods
  IFS='|' read -r regex app monitor target namespace <<<"$2"
  [ "$app" = - ] && return 0
  file="$render/$app/$monitor.yaml"
  [ -f "$file" ] || { echo "no monitor $monitor in $app"; return 0; }
  json="$(yq -o json -I0 ".metadata.namespace = (.metadata.namespace // \"$namespace\")" "$file")"
  if [[ $target == recorded:* ]]; then
    candidates="$(linstor_targets)"
    candidates="$(jq -c "[.[] | select(.name == \"${target#recorded:}\")]" <<<"$candidates")"
  else
    [[ $target == */* ]] || target="$app/$target"
    file="$render/$target.yaml"
    [ -f "$file" ] || { echo "no target ${target#*/} in ${target%%/*}"; return 0; }
    candidates="$(yq -N -o json -I0 '(select(.kind == "Service") | {"name": ("Service/" + .metadata.name),
      "ns": (.metadata.namespace // "'"$namespace"'"), "labels": .metadata.labels, "ports": [.spec.ports[].name],
      "selector": .spec.selector, "targets": [.spec.ports[] | .targetPort // .port]}),
      (select(.kind == "DaemonSet" or .kind == "Deployment" or .kind == "StatefulSet") | {"name": (.kind + "/" + .metadata.name),
      "ns": (.metadata.namespace // "'"$namespace"'"), "labels": .spec.template.metadata.labels,
      "ports": [.spec.template.spec.containers[].ports[]? | .name]})' "$file" | jq -s 'map(select(.name != null))')"
    # A Service leads to the container ports, of the workloads its application renders, that its
    # selector picks and its ports target, and a monitor's endpoint that names a targetPort is matched
    # there alone. That is stricter than Prometheus, whose endpointslice discovery also makes targets
    # for the container ports of those pods that no Service port targets, so this can report a gap
    # that is not one but never misses one that is.
    pods="$(yq -N -o json -I0 'select(.kind == "DaemonSet" or .kind == "Deployment" or .kind == "StatefulSet")
      | {"ns": (.metadata.namespace // "'"$namespace"'"), "labels": .spec.template.metadata.labels,
      "ports": [.spec.template.spec.containers[].ports[]?]}' "$(dirname "$file")"/*.yaml | jq -s .)"
    # shellcheck disable=SC2016 # $pods, $svc and $pod are jq variables.
    candidates="$(jq -c --argjson pods "$pods" 'map(. as $svc | if ($svc.selector // {}) == {} then . else . + {"targetPorts": [
      $pods[] | . as $pod | select($pod.ns == $svc.ns and ($svc.selector | to_entries | all(.value == $pod.labels[.key])))
      | $pod.ports[] | select(. as $port | $svc.targets | any(. == $port.name or . == $port.containerPort))
      | .name, .containerPort]} end)' <<<"$candidates")"
  fi
  scraped="$(selected "$json" "$candidates")"
  [ -n "$scraped" ] || echo "the monitor $monitor selects nothing that exposes the port it scrapes of $(jq -r '.[0].name' <<<"$candidates")"
  return 0
}

# scrape_gaps RENDER: one line for each metric an own alert of the render reads that no monitor of the
# render scrapes, or whose monitor selects nothing of its target, naming the application and the
# alert.
scrape_gaps() {
  local app alert metric entry regex candidate problem
  while read -r app alert metric; do
    entry=""
    for candidate in "${scrapes[@]}"; do
      IFS='|' read -r regex _ <<<"$candidate"
      if [[ $metric =~ $regex ]]; then
        entry=$candidate
        break
      fi
    done
    if [ -z "$entry" ]; then
      echo "$app: alert $alert reads $metric, which no monitor scrapes"
      continue
    fi
    problem="$(scrape_problem "$1" "$entry")"
    [ -z "$problem" ] || echo "$app: alert $alert reads $metric: $problem"
  done < <(own_metrics "$1")
}

@test "Every alert in the tree is on a metric a monitor in the render scrapes" {
  local gaps shown
  # Every own alert reads metrics that a monitor of the render scrapes, from a target that exposes the
  # port the monitor names.
  gaps="$(scrape_gaps "$RENDER")"
  echo "gaps in the tree: ${gaps:-none}"
  [ -z "$gaps" ]
  shown="$(own_metrics "$RENDER" | awk '{ print $1 }' | sort -u | xargs)"
  echo "applications with alerts: $shown"
  [[ $shown == *flux-monitoring* && $shown == *cilium-monitoring* && $shown == *linstor-monitoring* ]]

  # An alert on a metric nothing scrapes is refused, naming the alert and the metric.
  fixture
  yq -i '.spec.groups[0].rules += [{"alert": "NothingScrapesThis", "expr": "unscraped_thing_total > 0", "for": "5m"}]' \
    "$(own_file vector)"
  gaps="$(scrape_gaps "$FX/render")"
  echo "$gaps"
  [ "$gaps" = "vector: alert NothingScrapesThis reads unscraped_thing_total, which no monitor scrapes" ]

  # A monitor that selects nothing of its target, whether its selector or the port it names is wrong,
  # is refused, naming the alert that reads what it should scrape.
  fixture
  yq -i '.spec.selector.matchLabels."app.kubernetes.io/name" = "not-the-operator"' \
    "$FX/render/$CLUSTER/flux-monitoring/ServiceMonitor.monitoring.coreos.com_monitoring_flux-operator.yaml"
  gaps="$(scrape_gaps "$FX/render")"
  echo "$gaps"
  [ "$(grep -c 'selects nothing' <<<"$gaps")" -eq "$(grep -c . <<<"$gaps")" ]
  [ "$(grep -c 'flux-monitoring: alert Flux' <<<"$gaps")" -ge 1 ]
  [ "$(grep -c -v 'flux-monitoring' <<<"$gaps")" -eq 0 ]
  fixture
  yq -i '.spec.podMetricsEndpoints[0].port = "renamed"' \
    "$FX/render/$CLUSTER/cilium-monitoring/PodMonitor.monitoring.coreos.com_kube-system_cilium-agent.yaml"
  gaps="$(scrape_gaps "$FX/render")"
  echo "$gaps"
  [ "$(grep -c 'cilium-monitoring: alert Cilium.*selects nothing' <<<"$gaps")" -ge 1 ]
  [ "$(grep -c -v 'cilium-monitoring' <<<"$gaps")" -eq 0 ]
  # Each names the target it was matched with.
  [ "$(grep -c 'selects nothing that exposes the port it scrapes of DaemonSet/cilium$' <<<"$gaps")" -eq "$(grep -c . <<<"$gaps")" ]
  # The same for the operator-made targets.
  fixture
  yq -i '.spec.podMetricsEndpoints[0].port = "renamed"' \
    "$FX/render/$CLUSTER/linstor-monitoring/PodMonitor.monitoring.coreos.com_piraeus-datastore_linstor-satellite.yaml"
  gaps="$(scrape_gaps "$FX/render")"
  echo "$gaps"
  [ "$(grep -c 'linstor-monitoring: alert Drbd.*selects nothing' <<<"$gaps")" -ge 1 ]
  [ "$(grep -c -v 'linstor-monitoring' <<<"$gaps")" -eq 0 ]
  # The same for a monitor that selects by expressions and scrapes a container port behind the Service:
  # one whose expressions leave the controller out, and one that names a container port it lacks.
  fixture
  yq -i '(.spec.selector.matchExpressions[] | select(.key == "app.kubernetes.io/component") | .values) = ["cainjector", "webhook"]' \
    "$FX/render/$CLUSTER/cert-manager/ServiceMonitor.monitoring.coreos.com_cert-manager_cert-manager.yaml"
  gaps="$(scrape_gaps "$FX/render")"
  echo "$gaps"
  [ "$(grep -c '^cert-manager: alert CertManager' <<<"$gaps")" -ge 1 ]
  [ "$(grep -c -v 'selects nothing that exposes the port it scrapes of Service/cert-manager$' <<<"$gaps")" -eq 0 ]
  fixture
  yq -i '.spec.endpoints[0].targetPort = "renamed"' \
    "$FX/render/$CLUSTER/cert-manager/ServiceMonitor.monitoring.coreos.com_cert-manager_cert-manager.yaml"
  gaps="$(scrape_gaps "$FX/render")"
  echo "$gaps"
  [ "$(grep -c '^cert-manager: alert CertManager' <<<"$gaps")" -ge 1 ]
  [ "$(grep -c -v 'selects nothing that exposes the port it scrapes of Service/cert-manager$' <<<"$gaps")" -eq 0 ]
  # The same when only the Service no longer leads to the container port: the controller's port renamed,
  # or the Service's selector pointing away from the controller. The Service's own port keeps the name
  # the monitor's targetPort gives, so these hold only if the targetPort is matched behind the Service.
  fixture
  yq -i '(.spec.template.spec.containers[].ports[] | select(.name == "http-metrics") | .name) = "renamed"' \
    "$FX/render/$CLUSTER/cert-manager/Deployment.apps_cert-manager_cert-manager.yaml"
  gaps="$(scrape_gaps "$FX/render")"
  echo "$gaps"
  [ "$(grep -c '^cert-manager: alert CertManager' <<<"$gaps")" -ge 1 ]
  [ "$(grep -c -v 'selects nothing that exposes the port it scrapes of Service/cert-manager$' <<<"$gaps")" -eq 0 ]
  fixture
  yq -i '.spec.selector."app.kubernetes.io/component" = "not-the-controller"' \
    "$FX/render/$CLUSTER/cert-manager/Service_cert-manager_cert-manager.yaml"
  gaps="$(scrape_gaps "$FX/render")"
  echo "$gaps"
  [ "$(grep -c '^cert-manager: alert CertManager' <<<"$gaps")" -ge 1 ]
  [ "$(grep -c -v 'selects nothing that exposes the port it scrapes of Service/cert-manager$' <<<"$gaps")" -eq 0 ]
  # A monitor whose selector needs an operator the matcher does not know, NotIn here, is reported as
  # selecting nothing, whatever its values: one that Kubernetes reads as keeping the controller, and one
  # that it reads as leaving it out.
  fixture
  yq -i '(.spec.selector.matchExpressions[] | select(.key == "app.kubernetes.io/component")) |= {"key": .key, "operator": "NotIn", "values": ["cainjector", "webhook"]}' \
    "$FX/render/$CLUSTER/cert-manager/ServiceMonitor.monitoring.coreos.com_cert-manager_cert-manager.yaml"
  gaps="$(scrape_gaps "$FX/render")"
  echo "$gaps"
  [ "$(grep -c '^cert-manager: alert CertManager' <<<"$gaps")" -ge 1 ]
  [ "$(grep -c -v 'selects nothing that exposes the port it scrapes of Service/cert-manager$' <<<"$gaps")" -eq 0 ]
  fixture
  yq -i '(.spec.selector.matchExpressions[] | select(.key == "app.kubernetes.io/component") | .operator) = "NotIn"' \
    "$FX/render/$CLUSTER/cert-manager/ServiceMonitor.monitoring.coreos.com_cert-manager_cert-manager.yaml"
  gaps="$(scrape_gaps "$FX/render")"
  echo "$gaps"
  [ "$(grep -c '^cert-manager: alert CertManager' <<<"$gaps")" -ge 1 ]
  [ "$(grep -c -v 'selects nothing that exposes the port it scrapes of Service/cert-manager$' <<<"$gaps")" -eq 0 ]
}
