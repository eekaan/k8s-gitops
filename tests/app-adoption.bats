#!/usr/bin/env bats
# Proves the adoption scenarios of features/cluster-flux.feature; each test carries its scenario's
# title. just app-adoption runs from a copy of the repository against recording fakes of kubectl,
# helm and sleep, so nothing reaches a cluster. The fakes answer from a cluster kept in STATE that
# can change from one poll to the next: each sleep between two polls moves it on by one poll.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/app-adoption"
  JUST=$(command -v just)
  YQ=$(command -v yq)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$BIN" "$RECORD" "$STATE" "$BATS_TEST_TMPDIR/repo/talos/lab-sto2/clusterconfig"
  : > "$RECORD/argv"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  # The scripts and the kubernetes/ tree, so no run touches this checkout; a kubeconfig the fakes
  # never read.
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp -R "$ROOT/kubernetes" "$REPO/kubernetes"
  : > "$REPO/talos/lab-sto2/clusterconfig/kubeconfig"
  APP=kubernetes/apps/base/kube-system/cilium
  VERSION=$(yq -e '.spec.ref.tag' "$ROOT/$APP/app/ocirepository.yaml")
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise < /dev/null
  ENVIRONMENT=(TMPDIR="$BATS_TEST_TMPDIR")
  fake_cluster
  adopted
}

# fake NAME: a binary first on the recipe's PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# fake_tool NAME: like fake, with RECORD, STATE and the real yq set in the fake for its body to use.
fake_tool() {
  { printf 'RECORD=%q STATE=%q YQ=%q\n' "$RECORD" "$STATE" "$YQ"; cat; } | fake "$1"
}

# with ENTRY...: adds the NAME=VALUE ENTRY... to the environment the recipe gets.
with() {
  ENVIRONMENT+=("$@")
}

# recipe NAME [ARG...]: runs the repository's recipe against the copy, with only ENVIRONMENT set.
# A recipe that blocks fails after two minutes instead of hanging the tests.
recipe() {
  run timeout 120 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$@"
  echo "$output"
}

# fake_cluster: kubectl, helm and sleep against a cluster kept in STATE. Polls count from 1, and
# each sleep starts the next; a check still polling after 50 fails instead of running on. For a
# poll, kubectl answers from the file of that poll or, without one, of the latest poll before it:
#   nodes.N            the nodes, as kubectl get nodes --output json lists them
#   kind.N             Flux's HelmRelease kind exists, named as kubectl get --output name names it
#   helmrelease.N      the HelmRelease, in JSON
# and helm from:
#   releases.json      every Helm release, as helm list --all-namespaces --output json lists them
#   history.json       the release's history, as helm history --output json prints it
#   manifest.N.yaml    the manifest of the release's revision N
#   kubectl-fails      kubectl fails, with an error that names the API server's address
fake_cluster() {
  echo 1 > "$STATE/poll"
  fake_tool kubectl <<'EOF'
printf '%s\n' "kubectl $*" >> "$RECORD/argv"
args=" $* "
# latest NAME: the file NAME.N in STATE for the current poll N or the latest poll before it.
latest() {
  local n
  for ((n = $(cat "$STATE/poll"); n > 0; n--)); do
    if [[ -e $STATE/$1.$n ]]; then
      cat "$STATE/$1.$n"
      return 0
    fi
  done
  return 1
}
if [[ -e $STATE/kubectl-fails ]]; then
  echo "Unable to connect to the server: dial tcp 203.0.113.80:6443: i/o timeout" >&2
  exit 1
fi
[[ $1 == get ]] || exit 0
if [[ $args == *" nodes "* ]]; then
  latest nodes
elif [[ $args == *" customresourcedefinitions "* ]]; then
  if ! latest kind && [[ $args != *" --ignore-not-found "* ]]; then
    echo 'Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "helmreleases.helm.toolkit.fluxcd.io" not found' >&2
    exit 1
  fi
elif [[ $args == *" helmreleases.helm.toolkit.fluxcd.io "* ]]; then
  if ! latest kind > /dev/null; then
    echo 'error: the server does not have a resource type "helmreleases"' >&2
    exit 1
  fi
  if ! latest helmrelease && [[ $args != *" --ignore-not-found "* ]]; then
    echo 'Error from server (NotFound): helmreleases.helm.toolkit.fluxcd.io not found' >&2
    exit 1
  fi
else
  echo "fake kubectl: nothing to get for: $*" >&2
  exit 1
fi
EOF
  fake_tool helm <<'EOF'
printf '%s\n' "helm $*" >> "$RECORD/argv"
args=("$@")
# flag NAME: the value helm was given for the flag NAME.
flag() {
  local i
  for ((i = 0; i < ${#args[@]} - 1; i++)); do
    if [[ ${args[i]} == "$1" ]]; then
      echo "${args[i + 1]}"
      return 0
    fi
  done
}
case $1 in
  list)
    jq --arg filter "$(flag --filter)" '[.[] | select(.name | test($filter))]' "$STATE/releases.json"
    ;;
  history)
    if [[ ! -e $STATE/history.json ]]; then
      echo "Error: release: not found" >&2
      exit 1
    fi
    cat "$STATE/history.json"
    ;;
  get)
    file=$STATE/manifest.$(flag --revision).yaml
    if [[ $2 != manifest || ! -e $file ]]; then
      echo "Error: release: not found" >&2
      exit 1
    fi
    cat "$file"
    ;;
esac
EOF
  fake_tool sleep <<'EOF'
printf '%s\n' "sleep $*" >> "$RECORD/argv"
poll=$(($(cat "$STATE/poll") + 1))
if ((poll > 50)); then
  echo "fake sleep: the check is still polling after 50 polls" >&2
  exit 1
fi
echo "$poll" > "$STATE/poll"
EOF
}

# first_poll: the cluster starts again at its first poll.
first_poll() {
  echo 1 > "$STATE/poll"
}

# nodes POLL [NODE]: from poll POLL on, the fixture's nodes, every one Ready except NODE.
nodes() {
  NODE=${2-} yq -o json '(.items[] | select(.metadata.name == strenv(NODE)) | .status.conditions[]
    | select(.type == "Ready")) |= (.status = "False" | .reason = "KubeletNotReady"
    | .message = "container runtime network not ready")' "$FIXTURES/nodes.yaml" > "$STATE/nodes.$1"
}

# kind POLL: Flux's HelmRelease kind exists from poll POLL on.
kind() {
  echo customresourcedefinition.apiextensions.k8s.io/helmreleases.helm.toolkit.fluxcd.io > "$STATE/kind.$1"
}

# The chart version helm-controller gives a chart from an OCIRepository: the pinned version, with
# the first twelve characters of the artifact's digest as build metadata.
CHART_VERSION="$(yq -e '.spec.ref.tag' "$BATS_TEST_DIRNAME/../kubernetes/apps/base/kube-system/cilium/app/ocirepository.yaml")+0123456789ab"

# helmrelease POLL [EXPRESSION]: from poll POLL on, the fixture's HelmRelease, with CHART_VERSION in
# its history, changed by the jq EXPRESSION.
helmrelease() {
  yq -o json '.' "$FIXTURES/helmrelease.yaml" |
    jq --arg version "$CHART_VERSION" ".status.history[0].chartVersion = \$version | ${2:-.}" > "$STATE/helmrelease.$1"
}

# The HelmRelease's state on its first reconcile, before anything is released.
PROGRESSING='.status = {conditions: [
  {type: "Reconciling", status: "True", reason: "Progressing", message: "Fulfilling prerequisites"},
  {type: "Ready", status: "Unknown", reason: "Progressing", message: "reconciliation in progress"}]}'
# Its upgrade failed, and helm-controller retries it.
FAILED='.status.conditions = [
  {type: "Reconciling", status: "True", reason: "ProgressingWithRetry", message: "retrying after 1m0s"},
  {type: "Ready", status: "False", reason: "UpgradeFailed", message: "Helm upgrade failed for release kube-system/cilium with chart cilium: marker failure"},
  {type: "Released", status: "False", reason: "UpgradeFailed", message: "Helm upgrade failed for release kube-system/cilium with chart cilium: marker failure"}]'
# Its upgrade succeeded, and the Helm tests failed.
TEST_FAILED='.status.conditions = [
  {type: "Ready", status: "False", reason: "TestFailed", message: "Helm test failed for release kube-system/cilium.v2 with chart cilium: marker test failure"},
  {type: "Released", status: "True", reason: "UpgradeSucceeded", message: "Helm upgrade succeeded for release kube-system/cilium.v2 with chart cilium"},
  {type: "TestSuccess", status: "False", reason: "TestFailed", message: "Helm test failed for release kube-system/cilium.v2 with chart cilium: marker test failure"}]'
# helm-controller gave up after its retries.
STALLED='.status.conditions = [
  {type: "Ready", status: "False", reason: "UpgradeFailed", message: "Helm upgrade failed for release kube-system/cilium with chart cilium: marker failure"},
  {type: "Stalled", status: "True", reason: "RetriesExceeded", message: "Failed to upgrade after 4 attempt(s)"}]'

# releases NAMESPACE...: helm's releases: cilium at the pinned version in each NAMESPACE, and
# another application's release beside them.
releases() {
  local namespace
  for namespace; do
    jq -n --arg namespace "$namespace" --arg version "$VERSION" \
      '{name: "cilium", namespace: $namespace, revision: "2", updated: "2026-01-01 00:10:00 +0000 UTC",
        status: "deployed", chart: "cilium-\($version)", app_version: $version}'
  done | jq -s '. + [{name: "kubelet-csr-approver", namespace: "kube-system", revision: "1",
    updated: "2026-01-01 00:05:00 +0000 UTC", status: "deployed", chart: "kubelet-csr-approver-1.2.15",
    app_version: "v1.2.15"}]' > "$STATE/releases.json"
}

# revisions STATUS...: the release's history: revision 1, installed before Flux, and one upgrade
# after it for each further STATUS, each revision with the next STATUS.
revisions() {
  local status revision=0
  for status; do
    revision=$((revision + 1))
    jq -n --argjson revision "$revision" --arg status "$status" --arg version "$VERSION" \
      '{revision: $revision, updated: "2026-01-01T00:00:00Z", status: $status, chart: "cilium-\($version)",
        app_version: $version, description: (if $revision == 1 then "Install complete" else "Upgrade complete" end)}'
  done | jq -s '.' > "$STATE/history.json"
}

# The data of the Secret in the release's manifest, which nothing may print, as it is and as a
# manifest holds it. The Secret is made here: the secrets scan rightly flags one written out.
SECRET_DATA='marker-secret-data'
SECRET_DATA_ENCODED=$(printf '%s' "$SECRET_DATA" | base64)

# manifest REVISION [labelled]: the manifest of the release's REVISION: the fixture's objects and a
# Secret holding SECRET_DATA, with the labels helm-controller's post-renderer gives every object it
# renders when labelled is given.
manifest() {
  local file="$STATE/manifest.$1.yaml"
  {
    cat "$FIXTURES/manifest.yaml"
    echo '---'
    DATA=$SECRET_DATA_ENCODED yq -n '.apiVersion = "v1" | .kind = "Secret" | .type = "Opaque"
      | .metadata.name = "hubble-server-certs" | .metadata.namespace = "kube-system" | .data.marker = strenv(DATA)'
  } > "$file"
  if [[ ${2-} == labelled ]]; then
    yq -i '.metadata.labels["helm.toolkit.fluxcd.io/name"] = "cilium"
      | .metadata.labels["helm.toolkit.fluxcd.io/namespace"] = "kube-system"' "$file"
  fi
}

# adopted: an adoption as designed, seen from the first poll: Flux's kind and the HelmRelease Ready
# with the pinned chart version, every node Ready, one release cilium in kube-system, and its
# history: revision 1 as installed before Flux, and revision 2, deployed, labelled by helm-controller.
adopted() {
  kind 1
  helmrelease 1
  nodes 1
  releases kube-system
  revisions superseded deployed
  manifest 1
  manifest 2 labelled
}

# calls PATTERN: the recorded calls matching the extended regex, one per line.
calls() {
  grep -E -- "$1" "$RECORD/argv" 2> /dev/null || true
}

# call_line PATTERN: the line number in the record of the first call matching the extended regex.
call_line() {
  grep -n -m1 -E -- "$1" "$RECORD/argv" | cut -d: -f1
}

# polls: how many polls the check made; each reads the nodes.
polls() {
  calls '^kubectl get nodes ' | wc -l
}

# results: each check's result and name, in the order printed.
results() {
  sed -nE 's/^(pass|FAIL) +([^:]*):.*/\1 \2/p' <<< "$output"
}

# absent TEXT FILE...: fails when any FILE holds TEXT.
absent() {
  local text=$1
  shift
  if grep -qF -- "$text" "$@"; then
    echo "found $text in $*" >&2
    return 1
  fi
}

@test "An adopted release passes every check" {
  recipe app-adoption "$APP"

  [ "$status" -eq 0 ]
  [ "$(results)" = "pass one release
pass adopted
pass HelmRelease Ready
pass nodes Ready" ]
  [[ $output == *"pass  one release: cilium exists once, in kube-system"* ]]
  [[ $output == *"pass  adopted: revision 1, installed before Flux, does not carry helm-controller's labels, and the deployed revision 2 does"* ]]
  [[ $output == *"pass  HelmRelease Ready: kube-system/cilium is Ready, and its status.history gives the deployed revision 2 chart version $CHART_VERSION, which is ocirepository.yaml's $VERSION"* ]]
  [[ $output == *"pass  nodes Ready: every node was Ready at every poll, 1 in all"* ]]
  [ -n "$(calls '^helm get manifest cilium --namespace kube-system --revision 1$')" ]
  [ -n "$(calls '^helm get manifest cilium --namespace kube-system --revision 2$')" ]
  [[ ${lines[-1]} == *"release cilium in kube-system is adopted by the HelmRelease kube-system/cilium"* ]]
}

@test "The check waits for a HelmRelease that does not exist yet" {
  rm "$STATE/kind.1" "$STATE/helmrelease.1"
  kind 2
  helmrelease 3 "$PROGRESSING"
  helmrelease 5

  recipe app-adoption "$APP"

  [ "$status" -eq 0 ]
  # Five polls, ten seconds apart, each reading the nodes.
  [ "$(polls)" -eq 5 ]
  [ "$(calls '^sleep ')" = "$(printf 'sleep 10\n%.0s' 1 2 3 4)" ]
  # The HelmRelease is looked for once its kind exists, and the release only once it is Ready.
  [ "$(calls '^kubectl get helmreleases' | wc -l)" -eq 4 ]
  last_get=$(grep -n '^kubectl get ' "$RECORD/argv" | tail -1 | cut -d: -f1)
  first_helm=$(call_line '^helm ')
  [ -n "$first_helm" ]
  [ "$last_get" -lt "$first_helm" ]
  [[ $output == *"waiting for Flux's HelmRelease kind to exist"* ]]
  [[ $output == *"waiting for the HelmRelease kube-system/cilium to exist"* ]]
  [[ $output == *"waiting for the HelmRelease kube-system/cilium to be Ready for generation 1 (Ready: Unknown Progressing)"* ]]
  [[ $output == *"pass  nodes Ready: every node was Ready at every poll, 5 in all"* ]]
}

@test "a HelmRelease Ready for an earlier generation is waited for" {
  helmrelease 1 '.metadata.generation = 2'
  helmrelease 3 '.metadata.generation = 2 | .status.observedGeneration = 2'

  recipe app-adoption "$APP"

  [ "$status" -eq 0 ]
  [ "$(polls)" -eq 3 ]
  [[ $output == *"waiting for the HelmRelease kube-system/cilium to be Ready for generation 2 (Ready: True UpgradeSucceeded)"* ]]
}

@test "the seconds between polls come from ADOPTION_INTERVAL in .env" {
  printf 'ADOPTION_INTERVAL=3\n' > "$REPO/.env"
  helmrelease 1 "$PROGRESSING"
  helmrelease 2

  recipe app-adoption "$APP"

  [ "$status" -eq 0 ]
  [ "$(calls '^sleep ')" = "sleep 3" ]
}

@test "A second release of the same name fails the check" {
  releases kube-system default

  recipe app-adoption "$APP"

  [ "$status" -ne 0 ]
  [ "$(results)" = "FAIL one release
pass adopted
pass HelmRelease Ready
pass nodes Ready" ]
  [[ $output == *"FAIL  one release: 2 releases named cilium exist, in default, kube-system"* ]]
}

@test "A release whose history holds only the bootstrap revision fails the check" {
  revisions deployed
  rm "$STATE/manifest.2.yaml"

  recipe app-adoption "$APP"

  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  adopted: release cilium has 1 revision; helm-controller has not upgraded the revision installed before Flux"* ]]
}

@test "A release whose first revision already carries helm-controller's labels fails the check" {
  manifest 1 labelled

  recipe app-adoption "$APP"

  [ "$status" -ne 0 ]
  [ "$(results)" = "pass one release
FAIL adopted
pass HelmRelease Ready
pass nodes Ready" ]
  [[ $output == *"FAIL  adopted: revision 1 already carries helm-controller's labels: Flux installed release cilium, and nothing was adopted"* ]]
}

@test "a deployed revision without helm-controller's labels fails the check" {
  manifest 2

  recipe app-adoption "$APP"

  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  adopted: the deployed revision 2 does not carry helm-controller's labels"* ]]

  # Nor does a revision helm has no manifest of pass.
  rm "$STATE/manifest.1.yaml"
  manifest 2 labelled
  first_poll

  recipe app-adoption "$APP"

  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  adopted: helm has no manifest of revision 1 of release cilium"* ]]
}

@test "a HelmRelease history that does not give the deployed revision the pinned chart version fails the check" {
  helmrelease 1 '.status.history[0].chartVersion = "0.0.1+0123456789ab"'

  recipe app-adoption "$APP"

  [ "$status" -ne 0 ]
  [ "$(results)" = "pass one release
pass adopted
FAIL HelmRelease Ready
pass nodes Ready" ]
  [[ $output == *"FAIL  HelmRelease Ready: kube-system/cilium is Ready, but its status.history gives the deployed revision 2 chart version 0.0.1+0123456789ab, and ocirepository.yaml $VERSION"* ]]

  helmrelease 1 '.status.history[0].version = 3'
  first_poll

  recipe app-adoption "$APP"

  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  HelmRelease Ready: kube-system/cilium is Ready, but its status.history has no revision 2"* ]]
}

@test "a chart version without the artifact's digest passes the check" {
  # As helm-controller gives it with its digest tracking turned off.
  helmrelease 1 ".status.history[0].chartVersion = \"$VERSION\""

  recipe app-adoption "$APP"

  [ "$status" -eq 0 ]
  [[ $output == *"chart version $VERSION, which is ocirepository.yaml's $VERSION"* ]]
}

@test "A node that leaves Ready during the adoption fails the check and is named" {
  helmrelease 1 "$PROGRESSING"
  nodes 2 example-worker-2
  nodes 4
  helmrelease 5

  recipe app-adoption "$APP"

  [ "$status" -ne 0 ]
  [ "$(polls)" -eq 5 ]
  [ "$(results)" = "pass one release
pass adopted
pass HelmRelease Ready
FAIL nodes Ready" ]
  [[ $output == *"node example-worker-2 is not Ready"* ]]
  [[ $output == *"node example-worker-2 is Ready again"* ]]
  [[ $output == *"FAIL  nodes Ready: not Ready during the wait: example-worker-2 for 2 of 5 polls"* ]]
  [[ $output != *example-worker-1* && $output != *example-cp-1* ]]
}

@test "A HelmRelease that reports failure ends the wait with its reason" {
  helmrelease 1 "$PROGRESSING"
  helmrelease 2 "$FAILED"
  # Never reached: the wait ends at the poll that sees the failure.
  helmrelease 3

  recipe app-adoption "$APP"

  [ "$status" -ne 0 ]
  [ "$(polls)" -eq 2 ]
  [ "$(calls '^sleep ' | wc -l)" -eq 1 ]
  [[ $output == *"FAIL  HelmRelease Ready: kube-system/cilium reports Released UpgradeFailed: Helm upgrade failed for release kube-system/cilium with chart cilium: marker failure"* ]]

  helmrelease 2 "$TEST_FAILED"
  first_poll
  : > "$RECORD/argv"

  recipe app-adoption "$APP"

  [ "$status" -ne 0 ]
  [ "$(polls)" -eq 2 ]
  [[ $output == *"FAIL  HelmRelease Ready: kube-system/cilium reports TestSuccess TestFailed: Helm test failed for release kube-system/cilium.v2 with chart cilium: marker test failure"* ]]

  helmrelease 2 "$STALLED"
  first_poll
  : > "$RECORD/argv"

  recipe app-adoption "$APP"

  [ "$status" -ne 0 ]
  [ "$(polls)" -eq 2 ]
  [[ $output == *"FAIL  HelmRelease Ready: kube-system/cilium reports Stalled RetriesExceeded: Failed to upgrade after 4 attempt(s)"* ]]
}

@test "A HelmRelease that never becomes Ready fails when the wait runs out" {
  with ADOPTION_WAIT=0
  helmrelease 1 "$PROGRESSING"

  recipe app-adoption "$APP"

  [ "$status" -ne 0 ]
  [ "$(polls)" -eq 1 ]
  [ -z "$(calls '^sleep ')" ]
  [[ $output == *"FAIL  HelmRelease Ready: waited 0s for the HelmRelease kube-system/cilium to be Ready for generation 1 (Ready: Unknown Progressing)"* ]]

  rm "$STATE/helmrelease.1"

  recipe app-adoption "$APP"

  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  HelmRelease Ready: waited 0s for the HelmRelease kube-system/cilium to exist"* ]]

  rm "$STATE/kind.1"

  recipe app-adoption "$APP"

  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  HelmRelease Ready: waited 0s for Flux's HelmRelease kind to exist"* ]]
}

@test "The check changes nothing in the cluster" {
  recipe app-adoption "$APP"
  [ "$status" -eq 0 ]

  helmrelease 1 "$PROGRESSING"
  helmrelease 2 "$FAILED"
  nodes 2 example-worker-1
  manifest 1 labelled
  first_poll

  recipe app-adoption "$APP"
  [ "$status" -ne 0 ]

  [ -n "$(calls '^kubectl ')" ]
  [ -n "$(calls '^helm ')" ]
  [ "$(calls '^kubectl ' | grep -cvE '^kubectl get ')" -eq 0 ]
  [ "$(calls '^helm ' | grep -cvE '^helm (list|history|get) ')" -eq 0 ]
}

@test "Nothing but object names reaches the output" {
  printed="$BATS_TEST_TMPDIR/printed"
  # The markers are there to be read.
  grep -qF 198.51.100.21 "$STATE/nodes.1"
  grep -qF "$SECRET_DATA_ENCODED" "$STATE/manifest.1.yaml"
  grep -qF "$SECRET_DATA_ENCODED" "$STATE/manifest.2.yaml"

  recipe app-adoption "$APP"
  [ "$status" -eq 0 ]
  echo "$output" > "$printed"

  helmrelease 1 "$PROGRESSING"
  helmrelease 2 "$FAILED"
  nodes 2 example-worker-1
  first_poll
  recipe app-adoption "$APP"
  [ "$status" -ne 0 ]
  echo "$output" >> "$printed"

  : > "$STATE/kubectl-fails"
  first_poll
  recipe app-adoption "$APP"
  [ "$status" -ne 0 ]
  [[ $output == *"kubectl could not read the nodes"* ]]
  echo "$output" >> "$printed"

  grep -qF example-worker-1 "$printed"
  for marker in 198.51.100. 203.0.113. "$SECRET_DATA" "$SECRET_DATA_ENCODED"; do
    absent "$marker" "$printed"
  done
}

@test "app-adoption names the HelmRelease and the release as install-app does" {
  cp -R "$BATS_TEST_DIRNAME/fixtures/install-app/example" "$BATS_TEST_TMPDIR/example"

  recipe app-adoption "$BATS_TEST_TMPDIR/example"

  # The HelmRelease example in example, the ks.yaml's targetNamespace, and the release
  # other-example in other, its own targetNamespace.
  [ -n "$(calls '^kubectl get helmreleases.helm.toolkit.fluxcd.io example --namespace example ')" ]
  [ -n "$(calls '^helm list --all-namespaces --filter \^other-example\$ ')" ]
  [ -n "$(calls '^helm history other-example --namespace other ')" ]
  [[ $output == *"ocirepository.yaml 1.0.0"* ]]

  # Without storageNamespace helm-controller keeps the history in the HelmRelease's own namespace,
  # example, apart from the release, which helm cannot do.
  yq -i 'del(.spec.storageNamespace)' "$BATS_TEST_TMPDIR/example/app/helmrelease.yaml"
  : > "$RECORD/argv"

  recipe app-adoption "$BATS_TEST_TMPDIR/example"

  [ "$status" -ne 0 ]
  [[ $output == *"installs into other but keeps the history in example"* ]]
  [ -z "$(calls '^(kubectl|helm) ')" ]
}

@test "app-adoption names what it needs before it calls anything" {
  rm "$REPO/talos/lab-sto2/clusterconfig/kubeconfig"
  with ADOPTION_WAIT=soon ADOPTION_INTERVAL=0

  recipe app-adoption kubernetes/apps/base/kube-system

  [ "$status" -ne 0 ]
  [[ $output == *"talos/lab-sto2/clusterconfig/kubeconfig does not exist"* ]]
  [[ $output == *"kubernetes/apps/base/kube-system is not an application directory"* ]]
  [[ $output == *"ADOPTION_WAIT is not a whole number of seconds"* ]]
  [[ $output == *"ADOPTION_INTERVAL is not a whole number of seconds above zero"* ]]

  # The cluster it is given, whose kubeconfig is not there either.
  : > "$REPO/talos/lab-sto2/clusterconfig/kubeconfig"
  ENVIRONMENT=(TMPDIR="$BATS_TEST_TMPDIR")

  recipe app-adoption "$APP" example-cluster

  [ "$status" -ne 0 ]
  [[ $output == *"talos/example-cluster/clusterconfig/kubeconfig does not exist"* ]]
  [ -z "$(calls '^(kubectl|helm|sleep) ')" ]
}

@test "app-adoption refuses an argument it does not know and Go's HTTP/2 debug log before it calls anything" {
  recipe app-adoption "$APP" --force

  [ "$status" -eq 2 ]
  [[ $output == *"usage: app-adoption <application directory> [cluster]"* ]]

  with GODEBUG=http2debug=2
  recipe app-adoption "$APP"

  [ "$status" -ne 0 ]
  [[ $output == *"GODEBUG sets http2debug"* ]]
  [ -z "$(calls '^(kubectl|helm|sleep) ')" ]
}
