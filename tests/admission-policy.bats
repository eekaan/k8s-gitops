#!/usr/bin/env bats
# Proves features/admission-policy.feature; each test carries its scenario's title.
# Needs helm, kustomize, flux, yq, jq, kyverno and gator on PATH (the versions pinned for the
# repository). Each chart is pulled once per run from its public registry or repository, and the
# tree is rendered once by the test that runs both engines over it; building, rendering and the
# engines' own tools are offline.

# The tests run one at a time even where bats runs a file's tests side by side: a test that starts
# while another pulls a chart finds the chart's directory before the chart is in it.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

setup_file() {
  # Helm's cache and registry settings stay in the run's own directory, and so does the Docker
  # configuration helm falls back to for credentials, so no login is read.
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG"
  # flux build rewrites the kustomization.yaml of what it builds and puts it back afterwards, so it
  # builds a copy of the applications, never this checkout. The cluster directories stay behind.
  export TREE="$BATS_FILE_TMPDIR/tree"
  mkdir -p "$TREE/kubernetes"
  cp -R "$BATS_TEST_DIRNAME/../kubernetes/apps" "$BATS_TEST_DIRNAME/../kubernetes/components" "$TREE/kubernetes/"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLUSTER="$REPO/kubernetes/clusters/lab-sto2"
  KUBE="$(yq -e '.kubernetes' "$REPO/versions.yaml")"
  # The rules of the three of them, in the order the docs give them.
  RULES=(image-pinned restricted-security-context namespace-pod-security-level)
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# app_dir APP: sets APP_DIR to the directory of the application APP, in whichever namespace
# directory it is, relative to the tree.
app_dir() {
  local -a dirs=("$TREE"/kubernetes/apps/base/*/"$1")
  [ -f "${dirs[0]}/ks.yaml" ] || { echo "$1: no application directory with a ks.yaml"; return 1; }
  APP_DIR="${dirs[0]#"$TREE"/}"
}

# built APP: the application as Flux applies it: its app/ built with its ks.yaml, substituting
# strictly the variables of the cluster's example key lists. Writes $BATS_TEST_TMPDIR/APP-built.yaml
# and sets BUILT and APP_DIR.
built() {
  local app=$1 vars="$BATS_TEST_TMPDIR/example-vars.yaml" ks="$BATS_TEST_TMPDIR/$1-ks.yaml"
  app_dir "$app"
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$vars"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = $vars' "$vars" "$TREE/$APP_DIR/ks.yaml" >"$ks"
  BUILT="$BATS_TEST_TMPDIR/$app-built.yaml"
  # Built from the tree's parent, with paths from there, as scripts/kubernetes-check builds.
  (cd "$TREE" && flux build kustomization "$app" --path "./$APP_DIR/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute) >"$BUILT"
}

# render APP: the chart that APP's HelmRelease installs, built as built() builds it, from the
# OCIRepository or HelmRepository it names at its pinned version, with the values helm-controller
# gives the chart (those of the ConfigMap the HelmRelease reads, then the HelmRelease's own over
# them), the chart's definitions included and the HelmRelease's post-renderer patches applied by
# kustomize. The ServiceMonitor and PodMonitor APIs count as present, as group versions and as kinds.
# Writes $BATS_TEST_TMPDIR/APP.yaml and sets RENDERED, CHART, VALUES and INLINE.
render() {
  local app=$1 url tag name release namespace pulled chart repo dir="$BATS_TEST_TMPDIR/post-render-$1"
  built "$app"
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$BUILT")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$BUILT")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$BUILT")"
  VALUES="$BATS_TEST_TMPDIR/$app-values.yaml"
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\") | .data[\"values.yaml\"]" "$BUILT" >"$VALUES"
  [ -s "$VALUES" ] || { echo "$app: no values in the ConfigMap $name its HelmRelease reads"; return 1; }
  INLINE="$BATS_TEST_TMPDIR/$app-inline.yaml"
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$BUILT" >"$INLINE"
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
  if [ -n "$url" ]; then
    tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$BUILT")"
    pulled="$BATS_FILE_TMPDIR/charts/$app/$tag"
    if [ ! -d "$pulled" ]; then
      mkdir -p "$pulled"
      helm pull "$url" --version "$tag" --destination "$pulled"
    fi
  else
    chart="$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.chart' "$BUILT")"
    tag="$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.version' "$BUILT")"
    repo="$(yq -N 'select(.kind == "HelmRepository") | .spec.url' "$BUILT")"
    [ -n "$chart" ] && [ -n "$tag" ] && [ -n "$repo" ] || { echo "$app: no chart source"; return 1; }
    pulled="$BATS_FILE_TMPDIR/charts/$app/$tag"
    if [ ! -d "$pulled" ]; then
      mkdir -p "$pulled"
      helm pull "$chart" --repo "$repo" --version "$tag" --destination "$pulled"
    fi
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  mkdir -p "$dir"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" --include-crds \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor \
    --api-versions monitoring.coreos.com/v1/PodMonitor \
    --values "$VALUES" --values "$INLINE" >"$dir/rendered.yaml"
  yq ea -N '[select(.kind == "HelmRelease")] | .[0] | {"apiVersion": "kustomize.config.k8s.io/v1beta1",
    "kind": "Kustomization", "resources": ["rendered.yaml"],
    "patches": [(.spec.postRenderers // [])[] | (.kustomize.patches // [])[]]}' "$BUILT" >"$dir/kustomization.yaml"
  RENDERED="$BATS_TEST_TMPDIR/$app.yaml"
  kustomize build "$dir" >"$RENDERED"
}

# pod_templates FILE: every pod template in FILE, one JSON object per line, with the workload's
# kind and name and its template's pod spec. Hook pods that Helm runs only for `helm test` are not
# part of what the release runs and are left out.
pod_templates() {
  yq -N -o json -I0 'select(. != null)' "$1" | jq -c '
    select(.metadata.annotations["helm.sh/hook"] // "" | test("test") | not)
    | select(.kind == "Deployment" or .kind == "DaemonSet" or .kind == "StatefulSet" or .kind == "Job"
        or .kind == "CronJob" or .kind == "Pod")
    | {workload: (.kind + "/" + .metadata.name),
       replicas: (.spec.replicas // 1),
       labels: (.spec.template.metadata.labels // {}),
       pod: (if .kind == "Pod" then .spec elif .kind == "CronJob" then .spec.jobTemplate.spec.template.spec
             else .spec.template.spec end)}'
}

# overlay_without NS-DIR...: copies kubernetes/ to $TREE_OUT and takes the namespace directory NS-DIR
# of each argument, and every application in it, out of the lab-sto2 overlay. Sets OVERLAY_OUT to
# the overlay as Flux reads it.
overlay_without() {
  local dir
  TREE_OUT="$BATS_TEST_TMPDIR/tree-without"
  rm -rf "$TREE_OUT"
  mkdir -p "$TREE_OUT"
  cp -R "$REPO/kubernetes" "$TREE_OUT/kubernetes"
  for dir in "$@"; do
    DIR="$dir" yq -i '.resources |= map(select(test("^../../base/" + strenv(DIR) + "(/|$)") | not))' \
      "$TREE_OUT/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  done
  OVERLAY_OUT="$BATS_TEST_TMPDIR/overlay-without.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "$TREE_OUT/kubernetes/apps/overlays/lab-sto2" >"$OVERLAY_OUT"
}

@test "Each policy engine is selected on its own and builds nothing when it is not" {
  local engine other app names dependents
  # Each engine's namespace directory and the applications in it: the engine and its rules.
  local -A ns_dir=([kyverno]=kyverno [gatekeeper]=gatekeeper-system)
  local -A apps=([kyverno]="kyverno kyverno-policies" [gatekeeper]="gatekeeper gatekeeper-templates gatekeeper-policies")
  overlay_without
  for engine in kyverno gatekeeper; do
    for app in ${apps[$engine]}; do
      [ "$(APP="$app" yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(APP)) | .metadata.name' "$OVERLAY_OUT")" = "$app" ] \
        || { echo "the lab-sto2 overlay does not enable $app"; return 1; }
    done
    [ "$(DIR="${ns_dir[$engine]}" yq -N 'select(.kind == "Namespace" and .metadata.name == strenv(DIR)) | .metadata.name' "$OVERLAY_OUT")" = "${ns_dir[$engine]}" ]
  done
  for engine in kyverno gatekeeper; do
    other=kyverno
    [ "$engine" = kyverno ] && other=gatekeeper
    # The engine taken out leaves nothing in the build, and the other engine is whole: the build
    # holds each of its applications and its namespace.
    overlay_without "${ns_dir[$engine]}"
    echo "$engine out: $(grep -ci "$engine" "$OVERLAY_OUT" || true) lines name it"
    [ "$(grep -ci "$engine" "$OVERLAY_OUT" || true)" -eq 0 ]
    for app in ${apps[$other]}; do
      [ "$(APP="$app" yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(APP)) | .metadata.name' "$OVERLAY_OUT")" = "$app" ]
    done
    # The tree without the engine passes the check that builds every application and its
    # dependencies, so nothing left in it needs what was taken out.
    run "$REPO/scripts/kubernetes-check" "$TREE_OUT"
    echo "$output"
    [ "$status" -eq 0 ]
  done
  # The dependencies the overlay holds: an engine's rules wait for that engine, Gatekeeper's
  # constraints through the application of its templates, and nothing else names an engine, and
  # each engine waits for the monitoring definitions alone, never for the other engine.
  overlay_without
  # shellcheck disable=SC2016 # $name is a yq variable.
  dependents="$(yq -N 'select(.kind == "Kustomization" and .apiVersion == "kustomize.toolkit.fluxcd.io/*")
    | .metadata.name as $name | (.spec.dependsOn // [])[]
    | select(.name == "kyverno" or .name == "kyverno-policies" or .name == "gatekeeper" or .name == "gatekeeper-templates" or .name == "gatekeeper-policies")
    | $name + " -> " + .name' "$OVERLAY_OUT" | sort)"
  echo "dependencies on an engine: $dependents"
  [ "$dependents" = "$(printf '%s\n' 'gatekeeper-policies -> gatekeeper-templates' 'gatekeeper-templates -> gatekeeper' 'kyverno-policies -> kyverno')" ]
  for app in kyverno gatekeeper; do
    names="$(APP="$app" yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(APP)) | .spec.dependsOn[].name' "$OVERLAY_OUT" | paste -sd' ')"
    echo "$app depends on: $names"
    [ "$names" = prometheus-operator-crds ]
  done
}

@test "The engines' webhooks fail open, skip the system namespaces and refuse nothing but what the sandbox tier rule refuses" {
  local webhooks skipped args kinds policies actions timeouts runbook
  # Gatekeeper registers its webhooks itself, so they are in the render, with the chart's post-
  # renderer applied: every one fails open and skips the three namespaces.
  render gatekeeper
  webhooks="$(yq -N 'select(.kind == "ValidatingWebhookConfiguration" or .kind == "MutatingWebhookConfiguration")
    | .kind + "/" + .metadata.name + " " + .webhooks[].name' "$RENDERED")"
  echo "Gatekeeper's webhooks: ${webhooks:-none}"
  [ -n "$webhooks" ]
  # No mutation: no mutating webhook at all.
  [ -z "$(grep '^MutatingWebhookConfiguration' <<<"$webhooks" || true)" ]
  [ "$(grep -c '^ValidatingWebhookConfiguration' <<<"$webhooks")" -eq 2 ]
  policies="$(yq -N 'select(.kind == "ValidatingWebhookConfiguration") | .webhooks[] | .name + " " + .failurePolicy' "$RENDERED")"
  echo "failure policies: $policies"
  [ -z "$(grep -v ' Ignore$' <<<"$policies" || true)" ]
  # A slow answer delays the API server as a refusal would hold it up: each webhook waits the
  # chart's three seconds at most, and the failure policy then admits the object.
  timeouts="$(yq -N 'select(.kind == "ValidatingWebhookConfiguration") | .webhooks[] | .name + " " + (.timeoutSeconds | tostring)' "$RENDERED")"
  echo "timeouts: $timeouts"
  [ "$(grep -c . <<<"$timeouts")" -eq 2 ]
  [ -z "$(grep -v ' 3$' <<<"$timeouts" || true)" ]
  # Each webhook's namespaceSelector skips kube-system, flux-system and the engine's namespace: a
  # NotIn expression on the namespace's own name lists each, and nothing opts a namespace back in.
  skipped="$(yq -N -o json -I0 'select(.kind == "ValidatingWebhookConfiguration") | .webhooks[]' "$RENDERED" | jq -r '
    .name + " " + ([.namespaceSelector.matchExpressions[]
      | select(.key == "kubernetes.io/metadata.name" and .operator == "NotIn") | .values[]] | sort | join(","))')"
  echo "skipped namespaces: $skipped"
  [ "$(grep -c . <<<"$skipped")" -eq 2 ]
  [ -z "$(grep -v ' flux-system,gatekeeper-system,kube-system$' <<<"$skipped" || true)" ]
  # The audit leaves out only the namespaces a Config object excludes from it, and neither the
  # application nor its release has one, so it sees every namespace (the docs' scope of each engine).
  [ -z "$(yq -N 'select(.apiVersion == "config.gatekeeper.sh/*") | .metadata.name' "$BUILT" "$RENDERED")" ]
  # No mutation and no generation: the chart's mutation is off, and nothing of the rules mutates.
  [ "$(yq -N 'select(.kind == "Deployment" and .metadata.name == "gatekeeper-controller-manager")
    | .spec.template.spec.containers[0].args[]' "$RENDERED" | grep -cx -- '--disable-opa-builtin={http.send}')" -eq 1 ]
  yq -N 'select(.kind == "Deployment" and .metadata.name == "gatekeeper-controller-manager")
    | .spec.template.spec.containers[0].args[]' "$RENDERED" | grep -qx -- '--operation=webhook'
  [ -z "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args[]' "$RENDERED" | grep -x -- '--operation=mutation-webhook' || true)" ]
  # Kyverno's chart registers none: its controller makes them at run time, from what these values
  # and the policies decide. The values force the failure policy Ignore on every webhook that
  # matches resources, skip the three namespaces in the selector of each, and leave out the
  # webhook that protects generation labels, the generation of Kubernetes' own policies and the
  # background and cleanup controllers that mutate and clean up.
  render kyverno
  [ -z "$(yq -N 'select(.kind == "ValidatingWebhookConfiguration" or .kind == "MutatingWebhookConfiguration")
    | .metadata.name' "$RENDERED")" ]
  args="$(yq -N 'select(.kind == "Deployment" and .metadata.name == "kyverno-admission-controller")
    | .spec.template.spec.containers[] | select(.name == "kyverno") | .args[]' "$RENDERED")"
  echo "admission controller's flags: $(paste -sd' ' <<<"$args")"
  grep -qx -- '--forceFailurePolicyIgnore=true' <<<"$args"
  grep -qx -- '--protectGenerationLabels=false' <<<"$args"
  grep -qx -- '--generateValidatingAdmissionPolicy=false' <<<"$args"
  # A slow answer holds the API server up as a refusal would. Kyverno 1.20.0 sets no wait on the
  # webhooks that match resources unless a policy sets webhookConfiguration.timeoutSeconds, which
  # none does (below), so the API server's default of 10 seconds applies there. --webhookTimeout sets
  # the wait of the webhooks on Kyverno's own kinds, which fail closed; it stays at its default of
  # 10 seconds or below.
  timeouts="$(grep -E -- '^--?webhookTimeout(=|$)' <<<"$args" || true)"
  echo "admission controller's webhook timeout: ${timeouts:-the default, 10 seconds}"
  if [ -n "$timeouts" ]; then
    [[ $timeouts =~ ^--?webhookTimeout=([0-9]+)$ ]]
    [ "${BASH_REMATCH[1]}" -ge 1 ]
    [ "${BASH_REMATCH[1]}" -le 10 ]
  fi
  skipped="$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "kyverno") | .data.webhooks' "$RENDERED" |
    jq -r '[.namespaceSelector.matchExpressions[] | select(.key == "kubernetes.io/metadata.name" and .operator == "NotIn") | .values[]]
      | sort | join(",")')"
  echo "namespaces the resource webhooks skip: $skipped"
  [ "$skipped" = flux-system,kube-system,kyverno ]
  # Beyond the webhooks, Kyverno leaves out of admission and of its scans everything in the
  # namespaces its resourceFilters name, the chart's defaults, from which the docs say what each
  # engine's first report holds.
  skipped="$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "kyverno") | .data.resourceFilters' "$RENDERED" |
    grep -oE '\[\*/\*,[^],]+,\*\]' | sed -E 's/^\[\*\/\*,([^,]+),\*\]$/\1/' | sort | paste -sd, -)"
  echo "namespaces the resource filters leave out: $skipped"
  [ "$skipped" = kube-node-lease,kube-public,kube-system,kyverno ]
  [ -z "$(yq -N 'select(.kind == "Deployment" and (.metadata.name == "kyverno-background-controller" or .metadata.name == "kyverno-cleanup-controller")) | .metadata.name' "$RENDERED")" ]
  # What the rules do: Kyverno's are ValidatingPolicies alone, each failing open: the three shared
  # rules in audit, and sandbox-tier, Kyverno's own, the one rule that refuses.
  rules_built kyverno-policies
  kinds="$(yq -N '.kind' "$BUILT" | sort | uniq -c | paste -sd' ')"
  echo "Kyverno's rule objects: $kinds"
  [ "$(yq -N '.kind' "$BUILT" | sort -u)" = ValidatingPolicy ]
  [ "$(yq -N '.kind' "$BUILT" | grep -c .)" -eq 4 ]
  # No policy sets a timeout of its own for the webhook its rule is served by.
  [ -z "$(yq -N 'select(.spec.webhookConfiguration != null) | .metadata.name' "$BUILT")" ]
  actions="$(yq -N '.metadata.name + " " + (.spec.validationActions | join(",")) + " " + .spec.failurePolicy' "$BUILT" | sort)"
  echo "$actions"
  [ "$actions" = "$({ printf '%s Audit Ignore\n' "${RULES[@]}"; echo 'sandbox-tier Deny Ignore'; } | sort)" ]
  # The docs count the four objects, and the runbook of the admission controller says what its
  # absence lets through: a pod of a sandbox namespace, admitted without its tier.
  grep -qF '| Rules | 4 objects | 6 objects |' "$REPO/docs/kubernetes.md"
  runbook="$(sed -n '/^## KyvernoAdmissionControllerDown$/,/^## /p' "$REPO/docs/runbooks/alerts.md" | tr -s "\n " "  ")"
  grep -qF "a pod created in a namespace labelled \`k8s-gitops/sandbox\` is admitted without its tier" <<<"$runbook"
  # Gatekeeper's are ConstraintTemplates and constraints in dry-run, and no mutator, expansion or
  # config object that would change an object or what is watched.
  gatekeeper_rules_built
  kinds="$(yq -N '.kind' "$BUILT" | sort -u | grep -v '^ConstraintTemplate$' || true)"
  echo "Gatekeeper's constraint kinds: $(paste -sd' ' <<<"$kinds")"
  [ "$(yq -N 'select(.kind == "ConstraintTemplate") | .metadata.name' "$BUILT" | grep -c .)" -eq 3 ]
  [ "$(yq -N 'select(.apiVersion == "constraints.gatekeeper.sh/*") | .metadata.name' "$BUILT" | grep -c .)" -eq 3 ]
  [ -z "$(yq -N '.apiVersion' "$BUILT" | sort -u | grep -v -e '^templates.gatekeeper.sh/' -e '^constraints.gatekeeper.sh/' || true)" ]
  # Rego alone: the chart's default of making a ValidatingAdmissionPolicy for a template acts only on
  # a template with CEL source.
  [ "$(yq -N 'select(.kind == "ConstraintTemplate") | .spec.targets[] | keys | join(",")' "$BUILT" | sort -u)" = rego,target ]
  actions="$(yq -N 'select(.apiVersion == "constraints.gatekeeper.sh/*") | .metadata.name + " " + .spec.enforcementAction' "$BUILT")"
  echo "$actions"
  [ -z "$(grep -v ' dryrun$' <<<"$actions" || true)" ]
  # What only a live cluster shows is stated beside the settings that decide it.
  # Kyverno's six run-time webhook configurations are listed with each one's failure policy.
  for name in kyverno-exception-validating-webhook-cfg kyverno-cel-exception-validating-webhook-cfg \
    kyverno-global-context-validating-webhook-cfg kyverno-policy-mutating-webhook-cfg \
    kyverno-policy-validating-webhook-cfg kyverno-verify-mutating-webhook-cfg; do
    grep -qF "\`$name\`" "$REPO/docs/kubernetes.md"
  done
  tr -s "\n " "  " <"$REPO/docs/kubernetes.md" | grep -qF "Kyverno registers six more webhook configurations at run time, five of which fail closed"
  tr -s "\n " "  " <"$REPO/docs/kubernetes.md" | grep -qF "while no Kyverno pod answers, a write of a Kyverno policy, PolicyException or GlobalContextEntry is refused"
  tr -s "\n " "  " <"$REPO/docs/runbooks/alerts.md" | grep -qF "a write of a Kyverno policy, PolicyException or GlobalContextEntry is refused"
}

# rules_built APP: built APP, with the empty documents flux build leaves out of $BUILT, so that
# every document of it is an object.
rules_built() {
  built "$1"
  yq 'select(. != null)' "$BUILT" >"$BUILT.objects"
  mv "$BUILT.objects" "$BUILT"
}

# gatekeeper_rules_built: Gatekeeper's rules as its two applications build them, the templates and
# then the constraints, in one file; sets BUILT to it.
gatekeeper_rules_built() {
  local all="$BATS_TEST_TMPDIR/gatekeeper-rules.yaml"
  rules_built gatekeeper-templates
  yq '.' "$BUILT" >"$all"
  echo --- >>"$all"
  rules_built gatekeeper-policies
  yq '.' "$BUILT" >>"$all"
  BUILT="$all"
}

# engine_inputs OUT: from a render in OUT, the pods and namespaces the engines evaluate, in
# $BATS_TEST_TMPDIR: pods.yaml, one Pod for each pod template of each workload with the workload's
# namespace, namespaces.yaml, the Namespace objects, and values.yaml, the namespaces' labels as
# Kyverno's CLI takes them.
engine_inputs() {
  local all="$BATS_TEST_TMPDIR/render-objects.ndjson" missing
  find "$1" -name '*.yaml' -print0 | xargs -0 yq -N -o json -I0 'select(. != null)' >"$all"
  # A Helm test hook that the release does not run (the root's defaults turn the tests on, and a
  # release excludes one by name in test.filters) is never a pod of the cluster, and the image check
  # of just kubernetes-validate leaves it out in the same way.
  jq -cs 'def hooks: ((.metadata.annotations["helm.sh/hook"] // "") | split(",") | map(gsub("^ +| +$"; "")) | map(select(. != "")));
      def testonly: (hooks | length > 0) and (hooks | all(. == "test" or . == "test-success" or . == "test-failure"));
      . as $all
      # A chart object without a namespace is installed into the namespace of its release, which
      # the labels of helm-controller name through the HelmRelease.
      | ([$all[] | select(.kind == "HelmRelease") | {key: ((.metadata.namespace // "") + "/" + .metadata.name),
          value: (.spec.targetNamespace // .metadata.namespace // "")}] | from_entries) as $releases
      | def namespace_of: .metadata.namespace // $releases[(.metadata.labels["helm.toolkit.fluxcd.io/namespace"] // "") + "/"
          + (.metadata.labels["helm.toolkit.fluxcd.io/name"] // "")] // "default";
      def runs($n; $release):
          ($all | map(select(.kind == "HelmRelease" and .metadata.name == $release.name
              and (.metadata.namespace // "default") == $release.namespace)) | first) as $hr
          | if $hr == null then true
            else ($hr.spec.test.enable // false) == true
              and (($hr.spec.test.filters // []) as $f
                | (($f | map(select(.exclude != true) | .name)) as $in
                  | ($in | length) == 0 or ($in | index($n) != null))
                  and (($f | map(select(.exclude == true) | .name) | index($n)) == null))
            end;
      $all[]
      | select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "ReplicaSet"
          or .kind == "ReplicationController" or .kind == "Job" or .kind == "CronJob" or .kind == "Pod")
      | . as $o
      | select(($o | testonly | not) or runs($o.metadata.name;
          {"name": ($o.metadata.labels["helm.toolkit.fluxcd.io/name"] // ""),
           "namespace": ($o.metadata.labels["helm.toolkit.fluxcd.io/namespace"] // "default")}))
      | {apiVersion: "v1", kind: "Pod",
         metadata: {name: ((.kind | ascii_downcase) + "-" + .metadata.name), namespace: namespace_of},
         spec: (if .kind == "Pod" then .spec elif .kind == "CronJob" then .spec.jobTemplate.spec.template.spec
                else .spec.template.spec end)}' "$all" | jq -c '.' | sed 's/^/---\n/' >"$BATS_TEST_TMPDIR/pods.yaml"
  # flux-system is the one namespace of a pod that the render holds no Namespace of: the Flux
  # Operator makes it, and the FluxInstance's patches give it its level (Pod Security, above). Any
  # other namespace without an object is a pod in a namespace nothing declares, which the check of
  # the render refuses, so it fails here too.
  missing="$(jq -rs --slurpfile pods <(grep '^{' "$BATS_TEST_TMPDIR/pods.yaml" | jq -c '.metadata.namespace') \
    '([.[] | select(.kind == "Namespace") | .metadata.name]) as $declared | ($pods | unique)
    | map(select(. as $n | $declared | index($n) | not)) | join(" ")' "$all")"
  echo "namespaces of pods that no Namespace of the render declares: ${missing:-none}"
  [ -z "$missing" ] || [ "$missing" = flux-system ]
  if [ "$missing" = flux-system ]; then
    printf '%s\n' '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"flux-system","labels":{"pod-security.kubernetes.io/enforce":"restricted"}}}' >>"$all"
  fi
  jq -c 'select(.kind == "Namespace") | {apiVersion: "v1", kind: "Namespace",
    metadata: {name: .metadata.name, labels: (.metadata.labels // {})}}' "$all" | sed 's/^/---\n/' >"$BATS_TEST_TMPDIR/namespaces.yaml"
  jq -cs '{apiVersion: "cli.kyverno.io/v1alpha1", kind: "Values",
    namespaceSelector: [.[] | select(.kind == "Namespace") | {name: .metadata.name, labels: (.metadata.labels // {})}]}' "$all" \
    >"$BATS_TEST_TMPDIR/values.yaml"
}

# broken_inputs: pods.yaml, namespaces.yaml and values.yaml gain, in a namespace that enforces the
# restricted level, a pod that breaks the first two rules, and a namespace that breaks the third.
broken_inputs() {
  local ns="$1"
  cat >>"$BATS_TEST_TMPDIR/pods.yaml" <<EOF
---
apiVersion: v1
kind: Pod
metadata: {name: broken, namespace: $ns}
spec:
  containers:
    - {name: broken, image: "registry.example/broken:latest"}
EOF
  cat >>"$BATS_TEST_TMPDIR/namespaces.yaml" <<EOF
---
apiVersion: v1
kind: Namespace
metadata: {name: unlabelled}
EOF
}

# engines_over DIR: runs both engines over the inputs of engine_inputs, with each engine's rules
# from the tree. Sets KYVERNO_STATUS, KYVERNO_OUTPUT, and GATEKEEPER_FINDINGS, the number of
# findings of the constraints, and GATEKEEPER_OUTPUT.
engines_over() {
  local dir="$BATS_TEST_TMPDIR/engine-rules" policy
  rm -rf "$dir"
  mkdir -p "$dir/kyverno" "$dir/gatekeeper"
  rules_built kyverno-policies
  yq '.' "$BUILT" >"$dir/kyverno/policies.yaml"
  gatekeeper_rules_built
  yq '.' "$BUILT" >"$dir/gatekeeper/rules.yaml"
  policy="$dir/kyverno/policies.yaml"
  set +e
  KYVERNO_OUTPUT="$(kyverno apply "$policy" --resource "$BATS_TEST_TMPDIR/pods.yaml" --resource "$BATS_TEST_TMPDIR/namespaces.yaml" \
    --values-file "$BATS_TEST_TMPDIR/values.yaml" 2>&1)"
  KYVERNO_STATUS=$?
  GATEKEEPER_OUTPUT="$(gator test --filename "$dir/gatekeeper/rules.yaml" --filename "$BATS_TEST_TMPDIR/pods.yaml" \
    --filename "$BATS_TEST_TMPDIR/namespaces.yaml" --output json 2>&1)"
  set -e
  GATEKEEPER_FINDINGS="$(jq 'length' <<<"$GATEKEEPER_OUTPUT" 2>/dev/null || echo "not JSON")"
}

# scope_kyverno, scope_gatekeeper: one line for each rule of $BUILT, "NAME kinds namespaceSelector",
# the objects it matches in a form both engines share. A match key beyond the kinds and the
# namespace selector (an excluded namespace, a label selector, a match condition) is printed as
# "unsupported" so it differs from the engine without it.
scope_kyverno() {
  yq -N -o json -I0 '.' "$BUILT" | jq -r '
    def kind: {pods: "Pod", namespaces: "Namespace"}[.] // .;
    .metadata.name + " " + ([.spec.matchConstraints.resourceRules[].resources[] | kind] | sort | join(","))
      + " " + (.spec.matchConstraints.namespaceSelector // {} | tojson)
      + (if ((.spec.matchConstraints | keys) - ["resourceRules", "namespaceSelector"]) != []
          or (.spec.matchConditions // []) != []
          or ([.spec.matchConstraints.resourceRules[] | keys] | flatten | unique) != ["apiGroups", "apiVersions", "operations", "resources"]
          or ([.spec.matchConstraints.resourceRules[].operations] | flatten | unique) != ["CREATE", "UPDATE"]
         then " unsupported" else "" end)' | sort
}
scope_gatekeeper() {
  yq -N -o json -I0 'select(.apiVersion == "constraints.gatekeeper.sh/*")' "$BUILT" | jq -r '
    .metadata.name + " " + ([.spec.match.kinds[].kinds[]] | sort | join(","))
      + " " + (.spec.match.namespaceSelector // {} | tojson)
      + (if ((.spec.match | keys) - ["kinds", "namespaceSelector"]) != [] then " unsupported" else "" end)' | sort
}

@test "Both engines hold the same three rules, in audit, and the tree's own render passes them" {
  local rule out="$BATS_TEST_TMPDIR/render" kyverno_names gatekeeper_names offline file ns own
  # The same three names in both, each naming the offline check of the tree it mirrors. Kyverno's
  # one rule beyond them, sandbox-tier, has no twin in Gatekeeper (The sandbox tier rule), so the
  # comparison reads the three alone.
  rules_built kyverno-policies
  # shellcheck disable=SC2016 # $n is a yq variable.
  own="$(RULES="${RULES[*]}" yq -N 'select(.metadata.name as $n | strenv(RULES) | split(" ") | any_c(. == $n) | not) | .metadata.name' "$BUILT" | paste -sd' ')"
  echo "Kyverno's rules beyond the three: ${own:-none}"
  [ "$own" = sandbox-tier ]
  # shellcheck disable=SC2016 # $n is a yq variable.
  RULES="${RULES[*]}" yq -i 'select(.metadata.name as $n | strenv(RULES) | split(" ") | any_c(. == $n))' "$BUILT"
  kyverno_names="$(yq -N '.metadata.name' "$BUILT" | sort | paste -sd' ')"
  yq -N '.metadata.name + " " + .metadata.annotations["k8s-gitops/offline-check"]' "$BUILT" | sort >"$BATS_TEST_TMPDIR/kyverno-checks"
  # What each rule matches: the kind and the namespace selector, and nothing else that would narrow
  # it, so a rule cannot be held back in one engine and not the other.
  scope_kyverno >"$BATS_TEST_TMPDIR/kyverno-scope"
  gatekeeper_rules_built
  gatekeeper_names="$(yq -N 'select(.apiVersion == "constraints.gatekeeper.sh/*") | .metadata.name' "$BUILT" | sort | paste -sd' ')"
  yq -N 'select(.apiVersion == "constraints.gatekeeper.sh/*") | .metadata.name + " " + .metadata.annotations["k8s-gitops/offline-check"]' "$BUILT" \
    | sort >"$BATS_TEST_TMPDIR/gatekeeper-checks"
  scope_gatekeeper >"$BATS_TEST_TMPDIR/gatekeeper-scope"
  echo "Kyverno: $kyverno_names; Gatekeeper: $gatekeeper_names"
  [ "$kyverno_names" = "$(printf '%s\n' "${RULES[@]}" | sort | paste -sd' ')" ]
  [ "$gatekeeper_names" = "$kyverno_names" ]
  diff "$BATS_TEST_TMPDIR/kyverno-checks" "$BATS_TEST_TMPDIR/gatekeeper-checks"
  cat "$BATS_TEST_TMPDIR/kyverno-scope"
  diff "$BATS_TEST_TMPDIR/kyverno-scope" "$BATS_TEST_TMPDIR/gatekeeper-scope"
  while read -r rule offline; do
    echo "$rule mirrors $offline"
    file="${offline%% *}"
    [ -x "$REPO/$file" ]
  done <"$BATS_TEST_TMPDIR/kyverno-checks"
  # The tree's own render: every pod template and every namespace in it passes every rule in both.
  "$REPO/scripts/render" "$out" "$REPO"
  engine_inputs "$out"
  [ "$(grep -c '^kind: Pod\|"kind":"Pod"' "$BATS_TEST_TMPDIR/pods.yaml")" -gt 20 ]
  [ "$(grep -c '"kind":"Namespace"' "$BATS_TEST_TMPDIR/namespaces.yaml")" -gt 10 ]
  engines_over
  echo "Kyverno: $KYVERNO_OUTPUT"
  echo "Gatekeeper: $GATEKEEPER_OUTPUT"
  [ "$KYVERNO_STATUS" -eq 0 ]
  [ "$GATEKEEPER_FINDINGS" = 0 ]
  # A pod and a namespace that break the rules fail them, in both: the passes above are not the
  # engines finding nothing to look at.
  ns="$(jq -r 'select(.kind == "Namespace" and .metadata.labels["pod-security.kubernetes.io/enforce"] == "restricted") | .metadata.name' \
    <(yq -N -o json -I0 '.' "$BATS_TEST_TMPDIR/namespaces.yaml") | head -n 1)"
  [ -n "$ns" ]
  broken_inputs "$ns"
  engines_over
  echo "Kyverno: $KYVERNO_OUTPUT"
  echo "Gatekeeper: $GATEKEEPER_OUTPUT"
  [ "$KYVERNO_STATUS" -ne 0 ]
  for rule in "${RULES[@]}"; do
    grep -q "policy $rule -> resource .*broken\|policy $rule -> resource .*unlabelled" <<<"$KYVERNO_OUTPUT"
    jq -e --arg rule "$rule" 'any(.[]; .constraint.metadata.name == $rule)' <<<"$GATEKEEPER_OUTPUT"
  done
}

@test "Each rule fails the object it is written to catch, in each engine's own test" {
  local rows row name message passed=0 failed=0 skipped=0 cases
  # Kyverno's: every resource of a test is named for what its policy must do with it, pass-,
  # fail- or skip-, and its result is read from the engine's own report, so that an object the
  # engine excluded cannot stand for one it refused.
  run kyverno test "$REPO/tests/admission-policy/kyverno" --require-tests
  echo "$output"
  [ "$status" -eq 0 ]
  rows="$(kyverno test "$REPO/tests/admission-policy/kyverno" --output-format json --detailed-results 2>/dev/null |
    sed -n '/^\[/,/^\]/p' | jq -c '.[]')"
  [ -n "$rows" ]
  while read -r row; do
    name="$(jq -r '.RESOURCE | split("/") | last' <<<"$row")"
    message="$(jq -r '.Message' <<<"$row")"
    echo "$name: $message"
    [ "$(jq -r '.RESULT' <<<"$row")" = Pass ]
    case $name in
      pass-*) [ "$message" = success ]; passed=$((passed + 1)) ;;
      fail-*) [ "$message" != success ] && [ "$message" != Excluded ]; failed=$((failed + 1)) ;;
      skip-*) [ "$message" = Excluded ]; skipped=$((skipped + 1)) ;;
    esac
  done <<<"$rows"
  echo "Kyverno: $passed pass, $failed fail, $skipped skip"
  [ "$passed" -ge 3 ] && [ "$failed" -ge 5 ] && [ "$skipped" -ge 1 ]
  # Gatekeeper's: gator verify runs each case against the template and constraint of the tree and
  # fails when a case's assertion does not hold; a case that must be refused asserts the rule's
  # message, one that must not asserts no violation.
  run gator verify "$REPO/tests/admission-policy/gatekeeper/suite.yaml" --verbose
  echo "$output"
  [ "$status" -eq 0 ]
  cases="$(yq -N '[.tests[].cases[]] | length' "$REPO/tests/admission-policy/gatekeeper/suite.yaml")"
  [ "$(grep -c -- '--- PASS: ' <<<"$output")" -eq $((cases + $(yq -N '.tests | length' "$REPO/tests/admission-policy/gatekeeper/suite.yaml"))) ]
  [ -z "$(grep -- '--- FAIL' <<<"$output" || true)" ]
  # Each rule has a case that is refused and one that is not, with the rule's own message.
  for name in "${RULES[@]}"; do
    [ "$(NAME="$name" yq -N '[.tests[] | select(.name == strenv(NAME)) | .cases[].assertions[] | select(.violations != "no")] | length' \
      "$REPO/tests/admission-policy/gatekeeper/suite.yaml")" -ge 1 ]
    [ "$(NAME="$name" yq -N '[.tests[] | select(.name == strenv(NAME)) | .cases[].assertions[] | select(.violations == "no")] | length' \
      "$REPO/tests/admission-policy/gatekeeper/suite.yaml")" -ge 1 ]
  done
}

@test "A namespace labelled with a sandbox tier admits only pods with that tier's isolation, in Kyverno's own test" {
  local dir="$REPO/tests/admission-policy/kyverno/sandbox-tier" rows row name policy message want tier moved="$BATS_TEST_TMPDIR/moved.yaml"
  local -A messages=(
    [unknown]="the namespace's k8s-gitops/sandbox label is userns, gvisor or kata"
    [userns]="a pod in a namespace of the userns sandbox tier sets hostUsers to false"
    [gvisor]="a pod in a namespace of the gvisor sandbox tier sets runtimeClassName to gvisor"
    [kata]="a pod in a namespace of the kata sandbox tier sets runtimeClassName to kata"
  )
  local -A seen=()
  run kyverno test "$dir" --require-tests
  echo "$output"
  [ "$status" -eq 0 ]
  rows="$(kyverno test "$dir" --output-format json --detailed-results 2>/dev/null | sed -n '/^\[/,/^\]/p' | jq -c '.[]')"
  [ -n "$rows" ]
  # Each case's result is read from the engine's own report: a pass- pod is admitted, a skip- pod
  # excluded, and a fail- pod refused with the message of the validation its name points at, its
  # namespace's tier or, for fail-unknown-, a value that is no tier.
  while read -r row; do
    name="$(jq -r '.RESOURCE | split("/") | last' <<<"$row")"
    policy="$(jq -r '.POLICY' <<<"$row")"
    message="$(jq -r '.Message' <<<"$row")"
    case $name in
      pass-*) want=success ;;
      skip-*) want=Excluded ;;
      fail-unknown-*) want="${messages[unknown]}" ;;
      fail-*)
        tier="${name#fail-}"
        want="${messages[${tier%%-*}]:-no tier named $name}"
        ;;
      *) want="a case named pass-, fail- or skip-" ;;
    esac
    echo "$name ($policy): $message"
    [ "$policy" = sandbox-tier ]
    [ "$(jq -r '.RESULT' <<<"$row")" = Pass ]
    [ "$message" = "$want" ] || { echo "$name: expected \"$want\""; return 1; }
    seen[$name]=1
  done <<<"$rows"
  # The cases of each tier and of the values that are none.
  for name in pass-userns pass-gvisor pass-kata fail-userns-unset fail-gvisor-unset fail-kata-unset \
    fail-userns-true fail-gvisor-kata fail-kata-gvisor fail-gvisor-debug fail-kata-qemu \
    fail-gvisor-userns fail-userns-gvisor \
    skip-userns-unlabelled skip-gvisor-unlabelled skip-kata-unlabelled skip-unprefixed \
    fail-unknown-value fail-unknown-case fail-unknown-empty; do
    [ -n "${seen[$name]:-}" ] || { echo "no case $name"; return 1; }
  done
  # A skip- pod is excluded by its namespace alone: each unlabelled one, moved to the namespace of
  # its tier, is refused there with that tier's message, and the unprefixed one in gvisor's.
  yq 'select(.metadata.name | test("^skip-"))
    | .metadata.namespace = "sandbox-" + (.metadata.name | sub("^skip-"; "") | sub("-unlabelled$"; "") | sub("^unprefixed$"; "gvisor"))
    | .metadata.name |= sub("^skip-"; "moved-")' "$dir/resources.yaml" >"$moved"
  [ "$(yq -N '.metadata.namespace' "$moved" | sort | paste -sd' ')" = "sandbox-gvisor sandbox-gvisor sandbox-kata sandbox-userns" ]
  run kyverno apply "$dir/../../../../kubernetes/apps/base/kyverno/kyverno-policies/app/sandbox-tier.yaml" \
    --resource "$moved" --values-file "$dir/values.yaml" -p --output-format json
  echo "$output"
  [ "$status" -eq 1 ]
  rows="$(grep '^{' <<<"$output" | jq -r '.results[] | .resources[0].name + " " + .result + " " + .message' | sort)"
  [ "$rows" = "$(printf '%s\n' "moved-gvisor-unlabelled fail ${messages[gvisor]}" "moved-kata-unlabelled fail ${messages[kata]}" \
    "moved-unprefixed fail ${messages[gvisor]}" "moved-userns-unlabelled fail ${messages[userns]}" | sort)" ]
}

# docs_section HEADING: the text of the section of docs/kubernetes.md whose heading line is HEADING,
# "## Name" or "### Name", up to the next heading of its level or above, each line break and run of
# spaces one space, so a sentence is found whole wherever its lines break.
docs_section() {
  local marks="${1%% *}"
  awk -v heading="$1" -v level="${#marks}" '
    /^#+ / { if (on && index($0, " ") - 1 <= level) exit; if ($0 == heading) on = 1 }
    on' "$REPO/docs/kubernetes.md" | tr '\n' ' ' | tr -s ' '
}

# docs_bullets HEADING: each top-level bullet of the section HEADING of docs/kubernetes.md, as
# docs_section bounds it, on one line, its indented lines joined to it.
docs_bullets() {
  local marks="${1%% *}"
  awk -v heading="$1" -v level="${#marks}" '
    /^#+ / { if (on && index($0, " ") - 1 <= level) exit; if ($0 == heading) on = 1; next }
    !on { next }
    /^- / { if (b != "") print b; b = $0; next }
    /^  / && b != "" { b = b " " $0; next }
    { if (b != "") print b; b = "" }
    END { if (b != "") print b }' "$REPO/docs/kubernetes.md" | tr -s ' '
}

@test "The sandbox tier rule refuses at admission in every namespace that can carry the label, fails open and matches no namespace of the tree" {
  local policy="$BATS_TEST_TMPDIR/sandbox-tier.json" args skipped dropped excluded overlay labelled filter kind sub ns _
  local runtime admission adr bullet identities
  # The policy as Flux applies it: a refusal that fails open, for pods created in a namespace where
  # the label exists and nowhere else, the pod alone, naming its offline check, with no field beyond
  # these that would narrow or widen it (a match condition, an object selector, a webhook timeout, an
  # evaluation mode).
  rules_built kyverno-policies
  yq -N -o json 'select(.metadata.name == "sandbox-tier")' "$BUILT" >"$policy"
  cat "$policy"
  jq -e '.apiVersion == "policies.kyverno.io/v1" and .kind == "ValidatingPolicy"' "$policy"
  jq -e '.metadata.annotations == {"k8s-gitops/offline-check": "scripts/pod-security-check (sandbox tiers)"}' "$policy"
  jq -e '(.spec | keys) == ["autogen", "failurePolicy", "matchConstraints", "validationActions", "validations", "variables"]' "$policy"
  jq -e '.spec.validationActions == ["Deny"] and .spec.failurePolicy == "Ignore"' "$policy"
  jq -e '.spec.autogen == {"podControllers": {"controllers": []}}' "$policy"
  jq -e '.spec.matchConstraints == {
    "namespaceSelector": {"matchExpressions": [{"key": "k8s-gitops/sandbox", "operator": "Exists"}]},
    "resourceRules": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE"], "resources": ["pods"]}]}' "$policy"
  jq -e '[.spec.variables[].name] == ["tier"]
    and (.spec.variables[0].expression | contains("namespaceObject") and contains("k8s-gitops/sandbox"))' "$policy"
  jq -e '[.spec.validations[].message] == [
    "the namespace'"'"'s k8s-gitops/sandbox label is userns, gvisor or kata",
    "a pod in a namespace of the userns sandbox tier sets hostUsers to false",
    "a pod in a namespace of the gvisor sandbox tier sets runtimeClassName to gvisor",
    "a pod in a namespace of the kata sandbox tier sets runtimeClassName to kata"]' "$policy"
  # Kyverno's settings: every webhook that matches resources fails open, PolicyException stays off,
  # and the webhook's namespace selector, which Kyverno 1.20.0 makes the policy's selector merged with
  # the kyverno ConfigMap's (resolveNamespaceSelector), can only narrow by skipping namespaces by
  # name; no object selector of the ConfigMap's lets a pod past it by its labels.
  render kyverno
  args="$(yq -N 'select(.kind == "Deployment" and .metadata.name == "kyverno-admission-controller")
    | .spec.template.spec.containers[] | select(.name == "kyverno") | .args[]' "$RENDERED")"
  grep -qx -- '--forceFailurePolicyIgnore=true' <<<"$args"
  grep -qx -- '--enablePolicyException=false' <<<"$args"
  yq -N 'select(.kind == "ConfigMap" and .metadata.name == "kyverno") | .data.webhooks' "$RENDERED" >"$BATS_TEST_TMPDIR/webhooks.json"
  cat "$BATS_TEST_TMPDIR/webhooks.json"
  jq -e '(keys == ["namespaceSelector"]) and (.namespaceSelector.matchLabels // {} | length == 0)
    and (.namespaceSelector.matchExpressions | all(.key == "kubernetes.io/metadata.name" and .operator == "NotIn"))' "$BATS_TEST_TMPDIR/webhooks.json"
  skipped="$(jq -r '.namespaceSelector.matchExpressions[].values[]' "$BATS_TEST_TMPDIR/webhooks.json" | sort -u)"
  # Nor does a requester: Kyverno admits a request of a user, group or role its ConfigMap excludes
  # without evaluating it (withFilter), and the one it excludes is the chart's default, the group of
  # the kubelets, which register a mirror pod for each static pod of their node.
  identities="$(yq -N -o json -I0 'select(.kind == "ConfigMap" and .metadata.name == "kyverno") | .data
    | with_entries(select(.key | test("^exclude(Groups|Usernames|Roles|ClusterRoles)$")))' "$RENDERED")"
  echo "requesters Kyverno does not evaluate: $identities"
  [ "$identities" = '{"excludeGroups":"system:nodes"}' ]
  # The namespaces whose pods a resource filter drops: a filter whose kind matches Pod with no
  # subresource, whatever names it gives, as Kyverno matches each part (ToFilter).
  dropped=""
  while IFS= read -r filter; do
    IFS=, read -r kind ns _ <<<"${filter:1:-1}"
    sub=""
    [[ $kind != */* ]] || sub="${kind#*/}"
    kind="${kind%%/*}"
    # shellcheck disable=SC2053 # The filter's parts are patterns.
    if [[ Pod == $kind && "" == $sub ]]; then dropped+="$ns"$'\n'; fi
  done < <(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "kyverno") | .data.resourceFilters' "$RENDERED" | grep -oE '\[[^]]*\]')
  [ -n "$dropped" ]
  excluded="$(printf '%s\n%s' "$skipped" "$dropped" | grep . | sort -u | paste -sd, -)"
  echo "namespaces Kyverno never sees a pod of at admission: $excluded"
  [ "$excluded" = flux-system,kube-node-lease,kube-public,kube-system,kyverno ]
  # The namespaces that carry the label: each Namespace of the lab-sto2 overlay, and flux-system, as
  # the FluxInstance's patches label it. None of them is one Kyverno never sees at admission, and
  # today none carries it at all, so the rule matches no namespace of the tree.
  overlay="$BATS_TEST_TMPDIR/overlay.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2" >"$overlay"
  [ "$(yq -N 'select(.kind == "Namespace") | .metadata.name' "$overlay" | grep -c .)" -gt 10 ]
  # shellcheck disable=SC2016 # $patch is a yq variable.
  labelled="$({
    yq -N 'select(.kind == "Namespace" and (.metadata.labels // {} | has("k8s-gitops/sandbox"))) | .metadata.name' "$overlay"
    yq -N '.instance.kustomize.patches[] | select(.target.kind == "Namespace") | .patch | from_yaml
      | select(.metadata.labels // {} | has("k8s-gitops/sandbox")) | .metadata.name' \
      "$REPO/kubernetes/clusters/lab-sto2/flux-system/flux-instance/app/values.yaml"
  } | sort -u)"
  echo "namespaces labelled with a sandbox tier: ${labelled:-none}"
  for ns in $labelled; do
    [[ ,$excluded, != *",$ns,"* ]] || { echo "$ns carries k8s-gitops/sandbox, and Kyverno never sees its pods at admission"; return 1; }
  done
  [ -z "$labelled" ]
  # The docs state the contract where a reader looks for it.
  runtime="$(docs_section '## Runtime classes')"
  [[ $runtime == *"**A namespace asks for a sandbox tier.**"* ]]
  [[ $runtime == *"Falco watches the host's kernel, so it sees little of what a pod does inside gVisor or a Kata guest"* ]]
  [[ $runtime == *"\`k8s-gitops/sandbox\`"* ]]
  # The paragraph opens a line of its own, once, after the one tests/install-cilium.bats pins.
  [ "$(grep -cxE '\*\*A namespace asks for a sandbox tier\.\*\*.*' "$REPO/docs/kubernetes.md")" -eq 1 ]
  [ "$(grep -nE '^\*\*A namespace asks for a sandbox tier\.\*\*' "$REPO/docs/kubernetes.md" | cut -d: -f1)" -gt \
    "$(grep -nE '^\*\*Pods under a sandbox runtime reach Services\.\*\*' "$REPO/docs/kubernetes.md" | cut -d: -f1)" ]
  [[ $(docs_section '### What Falco costs and what it sees') == *"(#runtime-classes)"* ]]
  bullet="$(docs_bullets '## Pod Security' | grep -F -- '- **Sandbox tiers.**')"
  [[ $bullet == *"\`k8s-gitops/sandbox\`"* && $bullet == *"\`components/volsync\`"* && $bullet == *"\`components/cnpg-cluster\`"* ]]
  bullet="$(docs_bullets '## Adding an application' | grep -F -- "\`k8s-gitops/sandbox\`")"
  [ "$(grep -c . <<<"$bullet")" -eq 1 ]
  [[ $bullet == *"\`namespace.yaml\`"* && $bullet == *"\`components/volsync\`"* && $bullet == *"\`components/cnpg-cluster\`"* ]]
  admission="$(docs_section '## Admission policy')"
  [[ $admission == *'### The three rules'*'### The sandbox tier rule'* ]]
  [[ $admission == *"\`k8s-gitops/sandbox\`"* ]]
  [[ $admission == *"The refusal holds only while Kyverno's webhook answers"* ]]
  [[ $(docs_section '### The sandbox tier rule') == *"\`system:nodes\`"* ]]
  [[ $admission == *'Policy sandbox-tier failed: <message>'* ]]
  adr=adr/0021-a-namespace-label-names-its-sandbox-tier-and-kyverno-alone-refuses-pods-without-it.md
  [[ $admission == *"($adr)"* ]]
  [ -f "$REPO/docs/$adr" ]
  # The catalogue's entity of the rules names the fourth.
  [[ $(yq '.metadata.description' "$REPO/kubernetes/apps/base/backstage/backstage/app/catalogue/kyverno-policies.yaml") == *sandbox* ]]
}

@test "Each engine is pinned to an exact chart version that Renovate can update" {
  local overlay app path version spec refkeys url
  overlay="$(kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2")"
  for app in kyverno kyverno-policies gatekeeper gatekeeper-templates gatekeeper-policies; do
    path="$(APP=$app yq -N 'select(.kind == "Kustomization" and .metadata.name == strenv(APP)) | .spec.path' <<<"$overlay")"
    echo "$app in the overlay: ${path:-none}"
    [ -n "$path" ]
  done
  for app in kyverno gatekeeper; do
    built "$app"
    # An exact release, never a range or a moving tag. Flux gives a ref's semver and digest
    # precedence over its tag, so an OCIRepository's ref holds the tag alone.
    refkeys="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref // {} | keys | sort | join(",")' "$BUILT")"
    echo "$app ref keys: ${refkeys:-none}"
    [[ -z $refkeys || $refkeys == tag || $refkeys == digest,tag ]]
    version="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag // ""' "$BUILT")"
    [ -n "$version" ] || version="$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.version // ""' "$BUILT")"
    echo "$app chart version: ${version:-none}"
    [[ $version =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]
    # Renovate finds it: an OCIRepository tag carries its comment, a HelmRelease's chart version
    # is read by Renovate's Flux manager, which needs the HelmRepository beside it.
    spec="$(cat "$TREE/$APP_DIR/app/"*.yaml)"
    if grep -q '^kind: OCIRepository' <<<"$spec"; then
      url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$BUILT")"
      grep -qxF "    # renovate: datasource=docker depName=${url#oci://}" <<<"$spec"
    else
      grep -q '^kind: HelmRepository' <<<"$spec"
    fi
  done
  # Gatekeeper's test CLI is the release of the chart's application, so the two move together.
  [ "$(yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.version' "$BUILT")" = \
    "$(sed -n 's/^"http:gator" = { version = "\([^"]*\)".*/\1/p' "$REPO/mise.toml")" ]
}

@test "Each engine's pods keep running while a node is drained, request their memory and pass the restricted level" {
  local app deployment replicas spread budget unrequested violations level overlay failed=""
  local -A deployments=([kyverno]=kyverno-admission-controller [gatekeeper]=gatekeeper-controller-manager)
  local -A namespaces=([kyverno]=kyverno [gatekeeper]=gatekeeper-system)
  overlay="$(kustomize build --load-restrictor LoadRestrictionsNone "$TREE/kubernetes/apps/overlays/lab-sto2")"
  for app in kyverno gatekeeper; do
    deployment="${deployments[$app]}"
    render "$app"
    # The controller that answers the webhooks runs two replicas, spread over nodes where the
    # scheduler can, under a budget that keeps one. The spread and the budget are compared with
    # the labels of the rendered pod template, so a selector that matches none of its pods does
    # not count.
    read -r replicas spread budget < <(yq -N -o json -I0 'select(. != null)' "$RENDERED" | jq -rs --arg c "$deployment" '
      (.[] | select(.kind == "Deployment" and .metadata.name == $c)) as $d
      | ($d.spec.template.metadata.labels // {}) as $labels
      | def selects: (.matchLabels // {}) as $m | ($m | length) > 0 and ($m | to_entries | all($labels[.key] == .value));
      [($d.spec.replicas // 1 | tostring),
       ([$d.spec.template.spec.topologySpreadConstraints // [] | .[]
         | select(.topologyKey == "kubernetes.io/hostname" and .maxSkew == 1 and (.labelSelector | selects))
         | .whenUnsatisfiable][0] // "none"),
       ([.[] | select(.kind == "PodDisruptionBudget" and (.spec.selector | selects))
         | (.spec.minAvailable // "none" | tostring) + "/" + (.spec.maxUnavailable // "none" | tostring)][0] // "none")]
      | join(" ")')
    echo "$deployment: replicas ${replicas:-none}, spread: ${spread:-none}, budget: ${budget:-none}"
    [ "${replicas:-0}" = 2 ] || failed+=" $deployment:replicas"
    [ "${spread:-none}" != none ] || failed+=" $deployment:spread"
    [ "$budget" = "1/none" ] || failed+=" $deployment:budget"
    # Every container of every pod template the release runs requests CPU and memory, and has a
    # memory limit, so an engine cannot starve the node it runs on.
    unrequested="$(pod_templates "$RENDERED" | jq -r '.workload as $w | .pod
      | ((.containers // []) + (.initContainers // []))[]
      | select((.resources.requests.cpu // "") == "" or (.resources.requests.memory // "") == ""
          or (.resources.limits.memory // "") == "")
      | "\($w) container \(.name)"')"
    echo "$app containers without requests or a memory limit: ${unrequested:-none}"
    [ -z "$unrequested" ] || failed+=" $app:requests"
    # The namespace is the level the cluster gets, from the overlay: restricted, which every pod
    # template here meets, by the restricted level's rules read for each container.
    level="$(NS="${namespaces[$app]}" yq -N 'select(.kind == "Namespace" and .metadata.name == strenv(NS))
      | .metadata.labels["pod-security.kubernetes.io/enforce"] // "none"' <<<"$overlay")"
    echo "$app namespace enforces: $level"
    [ "$level" = restricted ] || failed+=" $app:level"
    violations="$(pod_templates "$RENDERED" | jq -r '
      .workload as $workload | .pod as $pod
      | ([
          {bad: (($pod.hostNetwork) == true or ($pod.hostPID) == true or ($pod.hostIPC) == true),
           why: "\($workload) shares a host namespace"},
          {bad: (($pod.volumes // []) | any(has("hostPath"))), why: "\($workload) mounts a host path"}
        ] + [
          (($pod.containers // []) + ($pod.initContainers // []))[]
          | (.securityContext // {}) as $c | "\($workload) container \(.name)" as $where
          | ($c.seccompProfile.type // $pod.securityContext.seccompProfile.type // "none") as $profile
          | {bad: ($c.privileged == true), why: "\($where) is privileged"},
            {bad: ($c.allowPrivilegeEscalation != false), why: "\($where) allows privilege escalation"},
            {bad: (($c.capabilities.drop // []) | any(. == "ALL") | not), why: "\($where) keeps its capabilities"},
            {bad: ((($c.capabilities.add // []) - ["NET_BIND_SERVICE"]) | length > 0), why: "\($where) adds capabilities"},
            {bad: ($c.runAsNonRoot == false or ($c.runAsNonRoot // $pod.securityContext.runAsNonRoot) != true),
             why: "\($where) may run as root"},
            {bad: (($c.runAsUser // $pod.securityContext.runAsUser) == 0), why: "\($where) runs as user 0"},
            {bad: ($profile != "RuntimeDefault" and $profile != "Localhost"), why: "\($where) has no seccomp profile"},
            {bad: ((.ports // []) | any(.hostPort != null)), why: "\($where) uses a host port"}
        ])[] | select(.bad) | .why')"
    echo "$app violations of the restricted level: ${violations:-none}"
    [ -z "$violations" ] || failed+=" $app:restricted"
  done
  echo "failed:${failed:- none}"
  [ -z "$failed" ]
}

# monitor_targets: one line per ServiceMonitor or PodMonitor in $RENDERED, "Kind/name -> Kind/name"
# naming each rendered object it scrapes: for a ServiceMonitor, a Service whose labels its selector
# matches and that names every port it scrapes; for a PodMonitor, a workload whose pod template
# does so. A monitor that scrapes none of them ends in "-> none".
monitor_targets() {
  yq -N -o json -I0 'select(. != null)' "$RENDERED" | jq -rs '. as $all | .[]
    | select(.kind == "ServiceMonitor" or .kind == "PodMonitor") | . as $monitor
    | ($monitor.spec.selector.matchLabels // {}) as $selector
    | [($monitor.spec.endpoints // $monitor.spec.podMetricsEndpoints // [])[].port] as $ports
    | [$all[] | if $monitor.kind == "ServiceMonitor" then
          select(.kind == "Service")
          | {name: ("Service/" + .metadata.name), labels: (.metadata.labels // {}), ports: [.spec.ports[]?.name]}
        else
          select(.kind == "Deployment" or .kind == "DaemonSet" or .kind == "StatefulSet")
          | {name: (.kind + "/" + .metadata.name), labels: (.spec.template.metadata.labels // {}),
             ports: [.spec.template.spec.containers[].ports[]?.name]}
        end
      | select(.labels as $labels | ($selector | length > 0)
          and ($selector | to_entries | all($labels[.key] == .value)))
      | select(.ports as $named | ($ports | length > 0) and ($ports | all(. as $port | any($named[]; . == $port))))
      | .name] as $targets
    | "\($monitor.kind)/\($monitor.metadata.name) -> \(if ($targets | length) > 0 then $targets | join(" ") else "none" end)"'
}

@test "Each engine's metrics are scraped and each engine's findings can be read" {
  local app targets depends
  for app in kyverno gatekeeper; do
    render "$app"
    # Gatekeeper's chart makes no monitor, so the application's own PodMonitor joins its render.
    if [ "$app" = gatekeeper ]; then
      { echo ---; yq -N 'select(.kind == "PodMonitor")' "$BUILT"; } >>"$RENDERED"
    fi
    targets="$(monitor_targets)"
    echo "$app: ${targets:-no monitor}"
    [ -n "$targets" ]
    [[ $targets != *' -> none'* ]]
    depends="$(yq '.spec.dependsOn // [] | .[].name' "$TREE/$APP_DIR/ks.yaml")"
    echo "$app depends on: ${depends:-nothing}"
    grep -qx prometheus-operator-crds <<<"$depends"
  done
  # Kyverno's admission and reports controllers; Gatekeeper's controller manager and audit pods,
  # one monitor for both, which share the label it selects.
  render kyverno
  [ "$(monitor_targets | grep -cxF 'ServiceMonitor/kyverno-admission-controller -> Service/kyverno-svc-metrics')" -eq 1 ]
  [ "$(monitor_targets | grep -cxF 'ServiceMonitor/kyverno-reports-controller -> Service/kyverno-reports-controller-metrics')" -eq 1 ]
  render gatekeeper
  { echo ---; yq -N 'select(.kind == "PodMonitor")' "$BUILT"; } >>"$RENDERED"
  [ "$(monitor_targets | grep -c 'PodMonitor/gatekeeper -> Deployment/gatekeeper-audit Deployment/gatekeeper-controller-manager')" -eq 1 ]
  # How to read the findings is in the docs: each engine's reports, where the audit puts them and
  # the metrics that count them.
  grep -qF 'kubectl get policyreport --all-namespaces' "$REPO/docs/kubernetes.md"
  grep -qF 'kubectl get clusterpolicyreport' "$REPO/docs/kubernetes.md"
  grep -qF 'kubectl get constraints' "$REPO/docs/kubernetes.md"
  grep -qF 'gatekeeper_violations' "$REPO/docs/kubernetes.md"
  grep -qF 'kyverno_validating_policy_results_total' "$REPO/docs/kubernetes.md"
}

@test "Kyverno's release renders each key once and keeps every definition when the release goes" {
  local rendered no_schemas="$BATS_TEST_TMPDIR/no-schemas" definitions kept
  mkdir -p "$no_schemas"
  render kyverno
  rendered="$BATS_TEST_TMPDIR/post-render-kyverno/rendered.yaml"
  # The chart's own output, before the post-renderer, holds each key once, read with both of the
  # render's strict parses: helm-controller's yaml.v3 decode refuses a repeat, which helm's own
  # template step and yq let through, and a kustomize post-renderer folds only repeated annotations
  # first, a repeated annotation key or a repeated annotations mapping, and none of an object one of
  # its JSON patches targets. kubeconform's strict parse compares the values keys stand for; no
  # schema is looked up.
  run kubeconform -strict -ignore-missing-schemas -verbose -output json \
    -schema-location "$no_schemas/{{.ResourceKind}}.json" "$rendered"
  echo "$output"
  jq -e '.resources | length > 0' <<<"$output" >/dev/null
  [ -z "$(jq -r '.resources[] | select((.msg // "") | contains("already set in map")) | .kind + " " + .name' <<<"$output")" ]
  # kustomize's decode, helm-controller's own, compares the keys' text: a JSON patch that copies each
  # object's kind onto itself has kustomize decode every object whole, before a build folds anything.
  mkdir -p "$BATS_TEST_TMPDIR/decode"
  cp "$rendered" "$BATS_TEST_TMPDIR/decode/rendered.yaml"
  printf '%s\n' 'apiVersion: kustomize.config.k8s.io/v1beta1' 'kind: Kustomization' 'resources: [rendered.yaml]' \
    'patches:' '  - target: {name: ".*"}' "    patch: '[{\"op\": \"copy\", \"from\": \"/kind\", \"path\": \"/kind\"}]'" \
    >"$BATS_TEST_TMPDIR/decode/kustomization.yaml"
  kustomize build "$BATS_TEST_TMPDIR/decode" >/dev/null
  # Every definition the release installs carries helm.sh/resource-policy: keep, once: deleting a
  # definition deletes every policy and report of its kind.
  definitions="$(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$RENDERED" | grep -c .)"
  kept="$(yq -N 'select(.kind == "CustomResourceDefinition" and .metadata.annotations["helm.sh/resource-policy"] == "keep") | .metadata.name' "$RENDERED" | grep -c .)"
  echo "$kept of $definitions definitions are kept"
  [ "$definitions" -gt 0 ]
  [ "$kept" -eq "$definitions" ]
}

@test "Gatekeeper's constraints are applied by an application that waits for their templates' kinds" {
  local templates policies kinds made
  overlay_without
  # Both applications are in the overlay: the templates wait for the release, the constraints for
  # the templates and for nothing else.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "gatekeeper-templates") | .spec.dependsOn[].name' "$OVERLAY_OUT" | paste -sd' ')" = gatekeeper ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "gatekeeper-policies") | .spec.dependsOn[].name' "$OVERLAY_OUT" | paste -sd' ')" = gatekeeper-templates ]
  # The kind of a constraint exists only once Gatekeeper has made it from its template, so the
  # templates' Kustomization is Ready only when each template's status says its kind was created:
  # Flux waits for the objects it applies, and without an expression it takes a template for ready
  # as soon as it is applied.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "gatekeeper-templates") | .spec.wait' "$OVERLAY_OUT")" = true ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "gatekeeper-templates") | .spec.healthCheckExprs | length' "$OVERLAY_OUT")" -eq 1 ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "gatekeeper-templates") | .spec.healthCheckExprs[0] | .apiVersion + " " + .kind' "$OVERLAY_OUT")" = "templates.gatekeeper.sh/v1 ConstraintTemplate" ]
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "gatekeeper-templates") | .spec.healthCheckExprs[0].current' "$OVERLAY_OUT")" = "status.created == true" ]
  # Flux reads inProgress and failed before current, so an entry with either could hold the
  # Kustomization back for good.
  [ "$(yq -N 'select(.kind == "Kustomization" and .metadata.name == "gatekeeper-templates") | .spec.healthCheckExprs[0] | keys | sort | join(" ")' "$OVERLAY_OUT")" = "apiVersion current kind" ]
  # The status the expression reads is one the pinned chart's definition of ConstraintTemplate
  # serves at that version, a boolean below a status subresource: a missing field is an error to
  # Flux, which never counts the template as ready.
  render gatekeeper
  [ "$(yq -N 'select(.kind == "CustomResourceDefinition" and .metadata.name == "constrainttemplates.templates.gatekeeper.sh")
    | .spec.versions[] | select(.name == "v1")
    | (.served | tostring) + " " + (.subresources.status != null | tostring) + " "
      + (.schema.openAPIV3Schema.properties.status.properties.created.type // "none")' "$RENDERED")" = "true true boolean" ]
  # What each application holds: the templates alone, and the constraints alone, one of each kind.
  rules_built gatekeeper-templates
  templates="$BUILT"
  rules_built gatekeeper-policies
  policies="$BUILT"
  [ "$(yq -N '.kind' "$templates" | sort -u)" = ConstraintTemplate ]
  [ "$(yq -N '.apiVersion' "$policies" | sort -u)" = constraints.gatekeeper.sh/v1beta1 ]
  made="$(yq -N '.spec.crd.spec.names.kind' "$templates" | sort | paste -sd' ')"
  kinds="$(yq -N '.kind' "$policies" | sort | paste -sd' ')"
  echo "templates make $made; constraints are of $kinds"
  [ "$(wc -w <<<"$made")" -eq 3 ]
  [ "$made" = "$kinds" ]
}
