#!/usr/bin/env bats
# Proves features/alert-routes.feature, except the scenarios tagged @by:alerts-route-check, which
# just alerts-route-check proves with amtool and Alertmanager from the image the chart deploys; each
# test carries its scenario's title. Needs helm, flux, kustomize, just, yq and jq on PATH (the
# versions pinned for the repository), and neither docker nor amtool: a stand-in records what the
# check would run. Each chart is pulled once per run from its public registry, the charts of the
# whole tree included, which the rules of every application are read from through scripts/render;
# building and rendering are offline.

# The tests run one at a time even where bats runs a file's tests side by side: they share the
# charts, the builds and the renders the file makes once.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

# The Prometheus Operator whose own types each key of Alertmanager's configuration was read against
# (pkg/alertmanager/types.go, into which it parses the configuration strictly, and the sanitize
# functions of pkg/alertmanager/amcfg.go, which drop what the deployed Alertmanager does not take),
# and whose own volumes, mounts and directories the Alertmanager's volume was held apart from
# (pkg/alertmanager/statefulset.go). The keys are the sets of shape_problems and receiver_problems,
# the names and directories those of destination_problems. A chart that runs another operator fails
# here until they are read again at its version.
OPERATOR_READ=v0.95.2

setup_file() {
  # Helm's cache and registry settings stay in the run's own directory, and so does the Docker
  # configuration helm falls back to for credentials, so no login is read.
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG"
  # Each chart is pulled once for the file, here, by whichever render needs it first.
  export RENDER_CHART_CACHE="$BATS_FILE_TMPDIR/render-charts"
  mkdir -p "$RENDER_CHART_CACHE"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLUSTER="$REPO/kubernetes/clusters/lab-sto2"
  KUBE="$(yq -e '.kubernetes' "$REPO/versions.yaml")"
  NAMESPACE=monitoring
  STACK=kube-prometheus-stack
  APP=alert-destinations
  OVERLAY_ENTRY="$NAMESPACE/$APP/ks.yaml"
  CASES="$REPO/tests/alert-routes/cases.yaml"
  FEATURE="$REPO/features/alert-routes.feature"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# built APP: the application APP of the monitoring namespace as Flux applies it: its app/ built in
# memory with its ks.yaml, substituting strictly the variables of the cluster's example key lists.
# Built once per run into $BATS_FILE_TMPDIR/APP-built.yaml; sets BUILT.
built() {
  local app=$1 vars="$BATS_TEST_TMPDIR/vars.yaml" ks="$BATS_TEST_TMPDIR/$1-ks.yaml"
  BUILT="$BATS_FILE_TMPDIR/$app-built.yaml"
  [ ! -s "$BUILT" ] || return 0
  [ -f "$REPO/kubernetes/apps/base/$NAMESPACE/$app/ks.yaml" ] ||
    { echo "the tree has no application $NAMESPACE/$app"; return 1; }
  # shellcheck disable=SC2016 # $list is a yq variable.
  yq ea '. as $list ireduce ({}; . * ($list // {}))' \
    "$CLUSTER/cluster-config.example.yaml" "$CLUSTER/cluster-secrets.example.yaml" >"$vars"
  # shellcheck disable=SC2016 # $vars is a yq variable.
  yq ea 'select(fileIndex == 0) as $vars | select(fileIndex == 1 and . != null)
    | .spec.postBuild.substitute = $vars' "$vars" "$REPO/kubernetes/apps/base/$NAMESPACE/$app/ks.yaml" >"$ks"
  # Built from the tree's root, with paths from there, as scripts/kubernetes-check builds.
  (cd "$REPO" && flux build kustomization "$app" --path "./kubernetes/apps/base/$NAMESPACE/$app/app" \
    --kustomization-file "$ks" --dry-run --strict-substitute --in-memory-build) >"$BATS_TEST_TMPDIR/$app-built.yaml"
  mv "$BATS_TEST_TMPDIR/$app-built.yaml" "$BUILT"
}

# stack: renders the chart the monitoring stack's HelmRelease installs, built as built() builds it,
# from the URL and tag of its OCIRepository, with the values helm-controller gives the chart: those
# of the ConfigMap the HelmRelease reads, then the HelmRelease's own over them. The monitoring APIs
# count as present, as prometheus-operator-crds installs them before the application starts. The
# chart is where scripts/render keeps it, so either pulls it for the other. Rendered once per run;
# sets RENDERED, VALUES, the values the tree gives the chart, DEFAULTS, the chart's own, and CHART.
stack() {
  local url tag name release namespace pulled built
  RENDERED="$BATS_FILE_TMPDIR/stack-rendered.yaml"
  VALUES="$BATS_FILE_TMPDIR/stack-values.yaml"
  DEFAULTS="$BATS_FILE_TMPDIR/stack-defaults.yaml"
  built "$STACK"
  built=$BUILT
  url="$(yq -N 'select(.kind == "OCIRepository") | .spec.url' "$built")"
  tag="$(yq -N 'select(.kind == "OCIRepository") | .spec.ref.tag' "$built")"
  pulled="$RENDER_CHART_CACHE/${url#oci://}/$tag"
  if ! compgen -G "$pulled/*.tgz" >/dev/null; then
    mkdir -p "$pulled"
    helm pull "$url" --version "$tag" --destination "$pulled"
  fi
  CHART="$(echo "$pulled"/*.tgz)"
  [ ! -s "$RENDERED" ] || return 0
  name="$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[0].name' "$built")"
  release="$(yq -N 'select(.kind == "HelmRelease") | .spec.releaseName // .metadata.name' "$built")"
  namespace="$(yq -N 'select(.kind == "HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$built")"
  yq -N "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\") | .data[\"values.yaml\"]" "$built" >"$VALUES"
  [ -s "$VALUES" ] || { echo "no values in the ConfigMap $name the HelmRelease reads"; return 1; }
  yq -N 'select(.kind == "HelmRelease") | .spec.values // {}' "$built" >"$BATS_TEST_TMPDIR/inline.yaml"
  helm show values "$CHART" >"$DEFAULTS"
  helm template "$release" "$CHART" --namespace "$namespace" --kube-version "$KUBE" \
    --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1alpha1 \
    --values "$VALUES" --values "$BATS_TEST_TMPDIR/inline.yaml" >"$BATS_TEST_TMPDIR/stack-rendered.yaml"
  mv "$BATS_TEST_TMPDIR/stack-rendered.yaml" "$RENDERED"
}

# tree_render: the tree as scripts/render writes it, the render pod-security-check and
# kubernetes-validate read: every application the overlay applies, each chart expanded. Rendered
# once per run; sets RENDER.
tree_render() {
  RENDER="$BATS_FILE_TMPDIR/render"
  [ ! -d "$RENDER" ] || return 0
  "$REPO/scripts/render" "$BATS_FILE_TMPDIR/render.partial" >"$BATS_FILE_TMPDIR/render.log" 2>&1 ||
    { cat "$BATS_FILE_TMPDIR/render.log"; return 1; }
  mv "$BATS_FILE_TMPDIR/render.partial" "$RENDER"
}

# alertmanager_json: the one Alertmanager the chart renders, as JSON on one line. Needs stack first.
alertmanager_json() {
  local found
  found="$(yq -N -o json -I0 'select(.kind == "Alertmanager")' "$RENDERED")"
  [ "$(grep -c . <<<"$found")" -eq 1 ] || { echo "the chart renders $(grep -c . <<<"$found") Alertmanager objects" >&2; return 1; }
  echo "$found"
}

# config_json: the configuration the chart renders for Alertmanager, as JSON on one line: the
# alertmanager.yaml of the Secret the rendered Alertmanager reads, spec.configSecret or, without
# one, alertmanager- and its name, as the operator names it (defaultConfigSecretName in its
# pkg/alertmanager/statefulset.go). Needs stack first.
config_json() {
  local name
  name="$(alertmanager_json | jq -r 'if (.spec.configSecret // "") != "" then .spec.configSecret else "alertmanager-" + .metadata.name end')"
  yq -N -o json -I0 'select(.kind == "Secret")' "$RENDERED" |
    jq -r --arg name "$name" 'select(.metadata.name == $name) | .data["alertmanager.yaml"]' | base64 -d | yq -o json -I0 '.'
}

# default_config_json: the configuration the chart's own values hold, as JSON. Needs stack first.
default_config_json() {
  yq -o json -I0 '.alertmanager.config' "$DEFAULTS"
}

# external_secret_json: the one ExternalSecret of the built alert-destinations application, as JSON
# on one line. Needs built first.
external_secret_json() {
  local found
  found="$(yq -N -o json -I0 'select(.kind == "ExternalSecret")' "$BUILT")"
  [ "$(grep -c . <<<"$found")" -eq 1 ] || { echo "$APP builds $(grep -c . <<<"$found") ExternalSecrets" >&2; return 1; }
  echo "$found"
}

# shape_problems CONFIG CHART_CONFIG: reads Alertmanager's configuration CONFIG, as JSON, and prints
# a line for each position, but the receivers, whose keys are not the recorded set or whose route
# tree is not the one the tree means; prints nothing when all hold. The root sends to null, which
# sends nothing, grouped by the alert's name and namespace, with the wait, interval and repeat of
# the chart's own configuration CHART_CONFIG; the first route takes the Watchdog to heartbeat with
# no wait, a flush a minute and a repeat after five, and does not continue; the second takes the
# critical and warning alerts to notify; there is no third. global, templates and the inhibit rules
# are the chart's, as it ships them.
shape_problems() {
  jq -r --argjson chart "$2" '
    def keyset($where; $want):
      if type != "object" then "\($where) is not a mapping"
      elif (keys | sort) != ($want | sort) then "\($where) holds the keys \(keys | join(", ")), not \($want | sort | join(", "))"
      else empty end;
    def same($where; $want): if . != $want then "\($where) is \(tojson), not \($want | tojson)" else empty end;
    keyset("the configuration"; ["global", "inhibit_rules", "receivers", "route", "templates"]),
    (.global | keyset("global"; ["resolve_timeout"]), same("global"; $chart.global)),
    (.templates | same("templates"; $chart.templates)),
    (.inhibit_rules | same("inhibit_rules"; $chart.inhibit_rules)),
    (.inhibit_rules | if type == "array" then to_entries[] else empty end | .key as $i | .value
      | keyset("inhibit rule \($i + 1)"; if $i < 3 then ["equal", "source_matchers", "target_matchers"] else ["target_matchers"] end)),
    (.route | keyset("the root route"; ["group_by", "group_interval", "group_wait", "receiver", "repeat_interval", "routes"])),
    (.route.receiver | same("the receiver of the root route"; "null")),
    (.route.group_by | same("the grouping of the root route"; ["alertname", "namespace"])),
    (("group_wait", "group_interval", "repeat_interval") as $k
      | .route[$k] | same("the \($k) of the root route"; $chart.route[$k])),
    (.route.routes | (if type == "array" then length else 0 end) | same("the number of routes under the root"; 2)),
    (.route.routes[0] | keyset("route 1"; ["group_interval", "group_wait", "matchers", "receiver", "repeat_interval"]),
      same("route 1"; {"receiver": "heartbeat", "matchers": ["alertname = \"Watchdog\""],
        "group_wait": "0s", "group_interval": "1m", "repeat_interval": "5m"})),
    (.route.routes[1] | keyset("route 2"; ["matchers", "receiver"]),
      same("route 2"; {"receiver": "notify", "matchers": ["severity =~ \"critical|warning\""]}))
  ' <<<"$1"
}

# receiver_problems CONFIG: prints a line for each receiver of the configuration CONFIG, as JSON,
# whose keys are not the recorded set; prints nothing when all hold. There are three: null, which
# holds no integration and so sends nothing, and notify and heartbeat, each one webhook that holds
# the file its address is read from and whether it is told of resolved alerts, and nothing else.
# notify is told; heartbeat is not, as the notification Alertmanager would send once the Watchdog
# stops arriving must not count as a beat.
receiver_problems() {
  jq -r '
    def keyset($where; $want):
      if type != "object" then "\($where) is not a mapping"
      elif (keys | sort) != ($want | sort) then "\($where) holds the keys \(keys | join(", ")), not \($want | sort | join(", "))"
      else empty end;
    def same($where; $want): if . != $want then "\($where) is \(tojson), not \($want | tojson)" else empty end;
    ([.receivers[]?.name] | sort | same("the receivers"; ["heartbeat", "notify", "null"])),
    (.receivers[]? | .name as $n
      | keyset("the receiver \($n)"; if $n == "null" then ["name"] else ["name", "webhook_configs"] end),
        (select(type == "object" and has("webhook_configs"))
          | (.webhook_configs | length | same("the number of webhooks of \($n)"; 1)),
            (.webhook_configs[] | keyset("the webhook of \($n)"; ["send_resolved", "url_file"])))),
    (.receivers[]? | select(.name == "notify") | .webhook_configs[0].send_resolved | same("the send_resolved of notify"; true)),
    (.receivers[]? | select(.name == "heartbeat") | .webhook_configs[0].send_resolved | same("the send_resolved of heartbeat"; false))
  ' <<<"$1"
}

# url_problems CONFIG: prints a line for each place of the configuration CONFIG, as JSON, that
# holds an address or says how one is reached: a key url, a key ending in _url, an http_config, or
# a value with a scheme in it. The line names the place and never the value.
url_problems() {
  jq -r '
    (paths as $p | $p[-1] | select(type == "string") | select(. == "url" or . == "http_config" or test("_url$"))
      | "\($p | map(tostring) | join(".")) is a key for an address or for how one is reached, and the configuration holds none"),
    (paths(type == "string") as $p | select(getpath($p) | test("://"))
      | "\($p | map(tostring) | join(".")) holds an address")
  ' <<<"$1"
}

# destination_problems EXTERNALSECRET ALERTMANAGER CONFIG: reads the three, as JSON, and prints a
# line for each way they disagree; prints nothing when they agree. The ExternalSecret says which
# Secret it writes and which keys; the Alertmanager must mount that Secret once, as a volume that
# is optional, so the pod starts without the Secret, and names no keys of its own, read-only and
# whole, as a file mounted by subPath does not follow its Secret, in a directory of its own; and
# each receiver's url_file must be the key named after the receiver in that directory, the keys
# read being exactly the keys written. The Secret is not in spec.secrets, the operator's own list,
# whose volume it makes without optional. The volume's name and the directory are none of the
# operator's own (pkg/alertmanager/statefulset.go at OPERATOR_READ: its volumes config-volume,
# tls-assets, config-out, web-config, cluster-tls-config and notification-templates, the storage
# volume alertmanager-<name>-db, and secret-<name> and configmap-<name> for spec.secrets and
# spec.configMaps; its directories below).
destination_problems() {
  jq -r --argjson es "$1" --argjson am "$2" '
    def operator_volumes: ["config-volume", "tls-assets", "config-out", "web-config", "cluster-tls-config",
      "notification-templates", "alertmanager-\($am.metadata.name)-db"];
    def operator_directories: ["/alertmanager", "/etc/alertmanager/certs", "/etc/alertmanager/cluster_tls_config",
      "/etc/alertmanager/config", "/etc/alertmanager/config_out", "/etc/alertmanager/configmaps",
      "/etc/alertmanager/secrets", "/etc/alertmanager/templates", "/etc/alertmanager/web_config"];
    . as $config
    | ($es.spec.target.name // $es.metadata.name) as $secret
    | [$es.spec.data[]?.secretKey] as $keys
    | [($am.spec.volumes // [])[] | select(.secret.secretName == $secret)] as $volumes
    | (if any(($am.spec.secrets // [])[]; . == $secret)
        then "the Alertmanager names the Secret \($secret) in spec.secrets, whose volume the operator makes without optional: without the Secret the pod does not start" else empty end),
      if ($volumes | length) != 1
      then "the Alertmanager has \($volumes | length) volumes of the Secret \($secret), which the ExternalSecret writes, not one"
      else $volumes[0] as $v
        | [($am.spec.volumeMounts // [])[] | select(.name == $v.name)] as $mounts
        | (if $v.secret.optional != true
            then "the volume \($v.name) is not optional: without the Secret \($secret) the pod does not start" else empty end),
          ((($v | keys) - ["name", "secret"]) + (($v.secret | keys) - ["optional", "secretName"]) | sort) as $more
          | (if $more != []
            then "the volume \($v.name) holds \($more | join(", ")), more than the Secret \($secret), whole and optional" else empty end),
          (if any(operator_volumes[]; . == $v.name) or ($v.name | test("^(secret|configmap)-"))
            then "the name of the volume \($v.name) is one the operator gives a volume of its own" else empty end),
          (if ($mounts | length) != 1 then "the volume \($v.name) is mounted \($mounts | length) times, not once"
            else $mounts[0] as $m
              | (if (($m | keys) - ["mountPath", "name", "readOnly"]) != []
                  then "the mount of \($v.name) holds \($m | keys - ["mountPath", "name", "readOnly"] | join(", ")): a file mounted by subPath does not follow its Secret" else empty end),
                (if $m.readOnly != true then "the mount of \($v.name) is not read-only" else empty end),
                (if any(operator_directories[]; . as $d | $m.mountPath == $d or ($m.mountPath | startswith($d + "/")) or ($d | startswith($m.mountPath + "/")))
                  then "the mount path \($m.mountPath) is, holds or is in a directory the operator mounts" else empty end),
                ([$config.receivers[]? | select(type == "object" and has("webhook_configs")) | .name as $n
                    | .webhook_configs[]? | {"receiver": $n, "file": (.url_file // "")}] as $read
                  | ($read[] | select(.file != "\($m.mountPath)/\(.receiver)-url")
                      | "\(.receiver) reads \(if .file == "" then "no file" else .file end), not \($m.mountPath)/\(.receiver)-url, the key named after it where the Secret is mounted"),
                    (([$read[].file | ltrimstr($m.mountPath + "/")] | sort) as $used
                      | if $used != ($keys | sort)
                        then "the receivers read the keys \($used | join(", ")) of the mount, and the ExternalSecret writes \($keys | sort | join(", "))" else empty end))
            end)
      end
  ' <<<"$3"
}

# address_problems EXTERNALSECRET ALERTMANAGER CONFIG: everything the three checks above find.
address_problems() {
  receiver_problems "$3"
  url_problems "$3"
  destination_problems "$1" "$2" "$3"
}

# alertmanagerconfigs TREE RENDER: one line for each AlertmanagerConfig object in the app/ of an
# application under TREE's apps/base, built by kustomize whether an overlay enables it or not, and
# in the render RENDER, by the kind the object has. The chart's Alertmanager selects such objects
# in every namespace, and the operator puts their routes before the configuration's own, so one
# would change the route tree every proof here reads.
alertmanagerconfigs() {
  local root=$1 render=$2 dir built file
  for dir in "$root"/kubernetes/apps/base/*/*/app; do
    built="$(kustomize build --load-restrictor LoadRestrictionsNone "$dir")" || { echo "$dir does not build"; return 1; }
    DIR="${dir#"$root"/}" yq -N 'select(.kind == "AlertmanagerConfig") | strenv(DIR) + ": AlertmanagerConfig " + .metadata.name' <<<"$built"
  done
  while IFS= read -r file; do
    echo "the render: ${file#"$render"/}"
  done < <(grep -rlx 'kind: AlertmanagerConfig' "$render" || true)
}

# severity_problems RENDER: one line for each alert rule of the render RENDER, the charts' and the
# tree's own, that has no place in the route tree: its severity is not critical or warning, which
# notify takes, or info, which the interfaces show and nothing sends, written out and not made from
# a template, and it is not the Watchdog, which has its own route, or the info inhibitor, which
# exists to be inhibited. Such an alert would end at the root, unseen. Names the application and
# the alert.
severity_problems() {
  yq -N -o json -I0 '{"app": (filename | split("/") | .[-2]),
    "alerts": [.spec.groups[].rules[] | select(has("alert")) | {"alert": .alert, "severity": .labels.severity}]}' \
    "$1"/*/*/PrometheusRule.*.yaml |
    jq -r '.app as $app | .alerts[]
      | select(.alert != "Watchdog" and .alert != "InfoInhibitor")
      | select(.severity as $severity | ["critical", "warning", "info"] | index($severity) | not)
      | "\($app): alert \(.alert): severity is \(.severity // "missing" | tostring), not critical, warning or info, so it reaches no receiver and no one sees it"'
}

# stand_in NAME: writes a stand-in for the shell that has the image's binaries, or for the docker
# that starts it, to $BATS_TEST_TMPDIR/bin/NAME and sets STAND_IN_LOG. It records each call as one
# line of three fields separated by tabs: what came before the shell's -c, run for a command handed
# on as it is or live for the script that drives an Alertmanager, and the command or the script's
# instructions. It answers as STAND_IN says: silent, or unset, prints nothing; agree prints, for
# amtool's routes test, the receivers it is asked to verify, as an amtool that agreed with every
# expectation would; frames prints, for the script, the file STAND_IN_FRAMES, which holds what that
# script prints of its steps. Whichever, it exits 0. It also records the names of its environment,
# in STAND_IN_LOG.env.
stand_in() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  STAND_IN_LOG="$BATS_TEST_TMPDIR/$1.log"
  : >"$STAND_IN_LOG"
  : >"$STAND_IN_LOG.env"
  export STAND_IN_LOG
  cat >"$BATS_TEST_TMPDIR/bin/$1" <<'STAND_IN'
#!/usr/bin/env bash
args=("$@")
i=0
while ((i < ${#args[@]})) && [[ ${args[i]} != -c ]]; do i=$((i + 1)); done
kind=live
[[ ${args[i + 1]-} != 'exec "$@"' ]] || kind=run
rest=("${args[@]:i + 3}")
printf '%s\t%s\t%s\n' "${args[*]:0:i}" "$kind" "${rest[*]}" >>"$STAND_IN_LOG"
env | cut -d= -f1 >>"$STAND_IN_LOG.env"
if [[ ${STAND_IN:-silent} == agree ]]; then
  for arg in "${rest[@]}"; do
    [[ $arg != --verify.receivers=* ]] || echo "${arg#--verify.receivers=}"
  done
fi
if [[ ${STAND_IN:-silent} == frames && $kind == live ]]; then
  cat "$STAND_IN_FRAMES"
fi
exit 0
STAND_IN
  chmod +x "$BATS_TEST_TMPDIR/bin/$1"
}

# start_frames LOG COUNTERS: writes to STAND_IN_FRAMES, and exports it, what the script that drives
# an Alertmanager prints of its steps for $CHECK/cases.yaml when that holds the start case alone:
# no file at any path a receiver reads its address from, an Alertmanager that became ready and holds
# each alert of the case with the receivers the case expects, and then the log LOG and the counters
# COUNTERS, each as text.
start_frames() {
  export STAND_IN_FRAMES="$BATS_TEST_TMPDIR/frames"
  {
    echo '@@ files 0'
    yq -N '.receivers[] | select(has("webhook_configs")) | .webhook_configs[].url_file | "absent " + .' "$CHECK/alertmanager.yaml"
    printf '%s\n' '@@ end files' '@@ ready 0' ready '@@ end ready' '@@ alerts.0 0'
    yq -o json -I0 '[.cases[0].alerts[] | {"labels": .labels, "receivers": [.receivers[] | {"name": .}],
      "status": {"state": "active", "silencedBy": [], "inhibitedBy": []}}]' "$CHECK/cases.yaml"
    printf '%s\n' '@@ end alerts.0' '@@ log.0 0' "$1" '@@ end log.0' '@@ counters.0 0' "$2" '@@ end counters.0'
  } >"$STAND_IN_FRAMES"
}

# check_dir: a directory as scripts/alerts-route-config writes it, made without it: the rendered
# configuration, the image the rendered Alertmanager names and the cases. Sets CHECK. Needs stack
# first.
check_dir() {
  CHECK="$BATS_TEST_TMPDIR/check"
  rm -rf "$CHECK"
  mkdir -p "$CHECK"
  config_json | yq -p json -o yaml '.' >"$CHECK/alertmanager.yaml"
  alertmanager_json | jq -r '.spec.image' >"$CHECK/image"
  cp "$CASES" "$CHECK/cases.yaml"
}

# case_names KIND...: the names of the cases of those kinds, one per line, as written.
case_names() {
  local kind
  for kind in "$@"; do
    KIND="$kind" yq -N '.cases[] | select(.kind == strenv(KIND)) | .name' "$CASES"
  done
}

@test "No receiver's address is in the tree: each is a file of the Secret Alertmanager mounts" {
  local es am config problems mount which description expression expected mutants survivors=""
  stack
  built "$APP"
  es="$(external_secret_json)"
  am="$(alertmanager_json)"
  config="$(config_json)"
  problems="$(address_problems "$es" "$am" "$config")"
  echo "the tree: ${problems:-no problems}"
  [ -z "$problems" ]
  # A Secret volume is a type the restricted level admits, and the one volume the values add.
  [ "$(jq -c '[.spec.volumes[] | keys - ["name"]] | flatten' <<<"$am")" = '["secret"]' ]
  # The documentation says where the files are and which two commands put the addresses in the
  # store, as the tree has them.
  mount="$(jq -r --argjson es "$es" '.spec.volumes[] as $v | select($v.secret.secretName == $es.spec.target.name)
    | .spec.volumeMounts[] | select(.name == $v.name) | .mountPath' <<<"$am")"
  echo "the Secret is mounted at $mount"
  grep -qF "\`$mount\`" "$REPO/docs/kubernetes.md"
  while read -r key property; do
    echo "just bao-put $key $property"
    grep -qF "just bao-put $key $property" "$REPO/docs/kubernetes.md"
  done < <(jq -r '.spec.data[] | .remoteRef.key + " " + .remoteRef.property' <<<"$es")

  # The proofs are not empty ones: each change to the configuration (C), to the Alertmanager (A) or
  # to the ExternalSecret (E) alone is refused for its own reason.
  mutants=0
  while IFS='#' read -r which description expression expected; do
    case $which in
      C) problems="$(address_problems "$es" "$am" "$(jq -c "$expression" <<<"$config")")" ;;
      A) problems="$(address_problems "$es" "$(jq -c "$expression" <<<"$am")" "$config")" ;;
      E) problems="$(address_problems "$(jq -c "$expression" <<<"$es")" "$am" "$config")" ;;
    esac
    echo "$description: ${problems:-accepted}"
    grep -qxF -- "$expected" <<<"$problems" || survivors+=" $description;"
    mutants=$((mutants + 1))
  done <<'MUTANTS'
C#a url beside the url_file#(.receivers[] | select(.name == "notify") | .webhook_configs[0].url) = "http://example.invalid/hook"#receivers.1.webhook_configs.0.url is a key for an address or for how one is reached, and the configuration holds none
C#a url in place of the url_file#(.receivers[] | select(.name == "notify") | .webhook_configs[0]) |= (del(.url_file) | .url = "http://example.invalid/hook")#receivers.1.webhook_configs.0.url holds an address
C#an http_config on a webhook#(.receivers[] | select(.name == "notify") | .webhook_configs[0].http_config) = {"proxy_url": "http://example.invalid:3128"}#the webhook of notify holds the keys http_config, send_resolved, url_file, not send_resolved, url_file
C#an address of another integration in global#.global.slack_api_url = "https://example.invalid/services"#global.slack_api_url is a key for an address or for how one is reached, and the configuration holds none
C#send_resolved dropped from heartbeat#del(.receivers[] | select(.name == "heartbeat") | .webhook_configs[0].send_resolved)#the webhook of heartbeat holds the keys url_file, not send_resolved, url_file
C#heartbeat told of resolved alerts#(.receivers[] | select(.name == "heartbeat") | .webhook_configs[0].send_resolved) = true#the send_resolved of heartbeat is true, not false
C#notify not told of resolved alerts#(.receivers[] | select(.name == "notify") | .webhook_configs[0].send_resolved) = false#the send_resolved of notify is false, not true
C#a key the set does not hold on a webhook#(.receivers[] | select(.name == "notify") | .webhook_configs[0].max_alerts) = 10#the webhook of notify holds the keys max_alerts, send_resolved, url_file, not send_resolved, url_file
C#a second webhook on notify#(.receivers[] | select(.name == "notify") | .webhook_configs) |= . + .#the number of webhooks of notify is 2, not 1
C#an integration on null#(.receivers[] | select(.name == "null") | .webhook_configs) = [{"url_file": "/etc/alertmanager/destinations/notify-url"}]#the receiver null holds the keys name, webhook_configs, not name
C#a fourth receiver#.receivers += [{"name": "pager"}]#the receivers is ["heartbeat","notify","null","pager"], not ["heartbeat","notify","null"]
C#notify reading heartbeat's file#(.receivers[] | select(.name == "notify") | .webhook_configs[0].url_file) = "/etc/alertmanager/destinations/heartbeat-url"#notify reads /etc/alertmanager/destinations/heartbeat-url, not /etc/alertmanager/destinations/notify-url, the key named after it where the Secret is mounted
C#a file outside the mount#(.receivers[] | select(.name == "heartbeat") | .webhook_configs[0].url_file) = "/etc/alertmanager/secrets/heartbeat-url"#heartbeat reads /etc/alertmanager/secrets/heartbeat-url, not /etc/alertmanager/destinations/heartbeat-url, the key named after it where the Secret is mounted
A#optional dropped from the volume#del(.spec.volumes[0].secret.optional)#the volume alert-destinations is not optional: without the Secret alert-destinations the pod does not start
A#optional false#.spec.volumes[0].secret.optional = false#the volume alert-destinations is not optional: without the Secret alert-destinations the pod does not start
A#a subPath on the mount#.spec.volumeMounts[0].subPath = "notify-url"#the mount of alert-destinations holds subPath: a file mounted by subPath does not follow its Secret
A#a mount that is not read-only#.spec.volumeMounts[0].readOnly = false#the mount of alert-destinations is not read-only
A#keys chosen in the volume#.spec.volumes[0].secret.items = [{"key": "notify-url", "path": "notify-url"}]#the volume alert-destinations holds items, more than the Secret alert-destinations, whole and optional
A#another Secret in the volume#.spec.volumes[0].secret.secretName = "other"#the Alertmanager has 0 volumes of the Secret alert-destinations, which the ExternalSecret writes, not one
A#no mount#.spec.volumeMounts = []#the volume alert-destinations is mounted 0 times, not once
A#a mount over the operator's configuration#.spec.volumeMounts[0].mountPath = "/etc/alertmanager/config"#the mount path /etc/alertmanager/config is, holds or is in a directory the operator mounts
A#a volume named as the operator names its own#(.spec.volumes[0].name, .spec.volumeMounts[0].name) = "config-volume"#the name of the volume config-volume is one the operator gives a volume of its own
A#the Secret in the operator's own list as well#.spec.secrets = ["alert-destinations"]#the Alertmanager names the Secret alert-destinations in spec.secrets, whose volume the operator makes without optional: without the Secret the pod does not start
E#one key renamed in the ExternalSecret alone#.spec.data[0].secretKey = "notify"#the receivers read the keys heartbeat-url, notify-url of the mount, and the ExternalSecret writes heartbeat-url, notify
E#a third key in the ExternalSecret#.spec.data += [{"secretKey": "pager-url", "remoteRef": {"key": "monitoring/alert-destinations", "property": "pager-url"}}]#the receivers read the keys heartbeat-url, notify-url of the mount, and the ExternalSecret writes heartbeat-url, notify-url, pager-url
E#another Secret written#.spec.target.name = "destinations"#the Alertmanager has 0 volumes of the Secret destinations, which the ExternalSecret writes, not one
MUTANTS
  echo "survivors:${survivors:- none}"
  [ -z "$survivors" ]
  [ "$mutants" -eq 26 ]
}

@test "The destinations are one Secret from the store, selected by one overlay entry, and nothing waits for it" {
  local overlay="$REPO/kubernetes/apps/overlays/lab-sto2/kustomization.yaml" tree="$BATS_TEST_TMPDIR/tree"
  local entries with without ks es others entity
  entries="$(grep -c "^  - ../../base/$OVERLAY_ENTRY\$" "$overlay")" || true
  echo "overlay lines naming $OVERLAY_ENTRY: $entries"
  [ "$entries" -eq 1 ]
  with="$(kustomize build --load-restrictor LoadRestrictionsNone "$(dirname "$overlay")" | yq -N -o json -I0 'select(.kind == "Kustomization")' | jq -s .)"
  ks="$(jq -c --arg app "$APP" '[.[] | select(.metadata.name == $app)]' <<<"$with")"
  echo "$APP in the overlay: $(jq -c '.[] | {path: .spec.path, targetNamespace: .spec.targetNamespace, dependsOn: .spec.dependsOn, wait: .spec.wait}' <<<"$ks")"
  [ "$(jq 'length' <<<"$ks")" -eq 1 ]
  [ "$(jq -r '.[0].spec.path' <<<"$ks")" = "./apps/base/$NAMESPACE/$APP/app" ]
  [ "$(jq -r '.[0].spec.targetNamespace' <<<"$ks")" = "$NAMESPACE" ]
  # The store is Ready before the ExternalSecret that names it is applied, and the store's own
  # application names the one whose chart brings the ExternalSecret kind, which waits for its
  # release: the kind is there before the object.
  [ "$(jq -c '.[0].spec.dependsOn | map(.name)' <<<"$ks")" = '["openbao-store"]' ]
  jq -e '.[] | select(.metadata.name == "openbao-store") | .spec.wait == true and (.spec.dependsOn | map(.name) | index("external-secrets") != null)' <<<"$with" >/dev/null
  jq -e '.[] | select(.metadata.name == "external-secrets") | .spec.wait == true' <<<"$with" >/dev/null
  # Not waited for, and no one waits for it: until an operator writes the two addresses to the
  # store the ExternalSecret reports the missing key, and that stalls no Kustomization and no
  # release, the monitoring stack's least of all.
  jq -e '.[0].spec | .wait == false and (has("healthChecks") or has("healthCheckExprs") | not)' <<<"$ks" >/dev/null
  grep -B4 -E '^  wait: false$' "$REPO/kubernetes/apps/base/$NAMESPACE/$APP/ks.yaml" | grep -q '^  # '
  others="$(jq -r --arg app "$APP" '.[] | select(any(.spec.dependsOn[]?; .name == $app)) | .metadata.name' <<<"$with")"
  echo "Kustomizations that name $APP in dependsOn: ${others:-none}"
  [ -z "$others" ]
  built "$STACK"
  [ -z "$(yq -N 'select(.kind == "HelmRelease") | .spec.valuesFrom[] | select(.kind != "ConfigMap") | .kind' "$BUILT")" ]

  # The application is one ExternalSecret and nothing else.
  built "$APP"
  echo "$APP builds: $(yq -N 'select(. != null) | .kind + "/" + .metadata.namespace + "/" + .metadata.name' "$BUILT" | paste -sd' ' -)"
  [ "$(yq -N 'select(. != null) | .kind + "/" + .metadata.namespace + "/" + .metadata.name' "$BUILT")" = "ExternalSecret/$NAMESPACE/$APP" ]
  es="$(external_secret_json)"
  echo "$es"
  # Two data entries, so the Secret holds those two keys and nothing else the store's entry holds;
  # the interval the tree's other ExternalSecrets are read again at.
  others="$(cd "$REPO" && grep -rhoE '^[[:blank:]]*refreshInterval:[[:blank:]]*[^[:blank:]#]+' kubernetes --include='*.yaml' --exclude-dir="$APP" |
    sed -E 's/^[[:blank:]]*refreshInterval:[[:blank:]]*//' | sort -u)"
  echo "the other ExternalSecrets' refresh interval: $(paste -sd' ' - <<<"$others")"
  [ "$(grep -c . <<<"$others")" -eq 1 ]
  jq -e --arg interval "$others" --arg app "$APP" --arg namespace "$NAMESPACE" '
    .apiVersion == "external-secrets.io/v1"
    and (.spec | keys) == ["data", "refreshInterval", "secretStoreRef", "target"]
    and .spec.refreshInterval == $interval
    and .spec.secretStoreRef == {"kind": "ClusterSecretStore", "name": "openbao"}
    and .spec.target == {"name": $app, "creationPolicy": "Owner"}
    and .spec.data == [
      {"secretKey": "notify-url", "remoteRef": {"key": ($namespace + "/" + $app), "property": "notify-url"}},
      {"secretKey": "heartbeat-url", "remoteRef": {"key": ($namespace + "/" + $app), "property": "heartbeat-url"}}]' <<<"$es" >/dev/null

  # The same overlay without the entry, in a copy of the tree: it builds, the checks of the tree
  # pass, and nothing of the application is in it.
  mkdir -p "$tree"
  cp -R "$REPO/kubernetes" "$REPO/versions.yaml" "$tree/"
  grep -v "^  - ../../base/$OVERLAY_ENTRY\$" "$overlay" >"$tree/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  without="$(kustomize build --load-restrictor LoadRestrictionsNone "$tree/kubernetes/apps/overlays/lab-sto2")"
  echo "objects of the build without the entry: $(yq -N '.kind' <<<"$without" | grep -c .)"
  [ -n "$without" ]
  if grep -q "$APP" <<<"$without"; then
    echo "the build without the entry still names $APP"
    return 1
  fi
  run "$REPO/scripts/kubernetes-check" "$tree"
  echo "$output"
  [ "$status" -eq 0 ]

  # The catalogue holds it as what it is: configuration, in the system the monitoring stack is in,
  # with the dependency its Kustomization names.
  entity="$REPO/kubernetes/apps/base/backstage/backstage/app/catalogue/$APP.yaml"
  [ "$(yq -o json -I0 '[.kind, .metadata.name, .spec.system, .spec.dependsOn]' "$entity")" = "[\"Resource\",\"$APP\",\"observability\",[\"resource:default/openbao-store\"]]" ]
}

@test "Alertmanager's configuration is the one the values state, of a shape the pinned operator reads" {
  local config stated chart operator problems found tree fake description expression expected mutants survivors=""
  stack
  config="$(config_json)"
  stated="$(yq -o json -I0 '.alertmanager.config' "$VALUES")"
  echo "the values state: $stated"
  echo "the chart renders: $config"
  # Stated whole, so nothing rides on Helm merging the chart's own configuration in: what the chart
  # renders is what the values hold, compared as data.
  [ "$stated" != null ]
  [ "$(jq -S . <<<"$config")" = "$(jq -S . <<<"$stated")" ]
  # The values' configuration is the one the chart takes: it is not passed through Helm's
  # templates, and no configuration given as text stands in its place.
  # shellcheck disable=SC2016 # $doc is a yq variable.
  [ "$(yq ea -o json -I0 '. as $doc ireduce ({}; . * $doc) | [.alertmanager.tplConfig, .alertmanager.stringConfig, .alertmanager.alertmanagerSpec.useExistingSecret]' "$DEFAULTS" "$VALUES")" = '[false,"",false]' ]

  # The operator does not copy the Secret into the pod. With the selector the chart renders, which
  # is not null, it loads the configuration, parses it strictly into its own types, drops what the
  # deployed Alertmanager does not take and writes its own serialisation: every key is one read
  # against those types at this operator version.
  [ "$(alertmanager_json | jq -c '.spec.alertmanagerConfigSelector')" = '{}' ]
  # It is the Secret's configuration that it loads: with spec.alertmanagerConfiguration set, the
  # operator builds the configuration from the global AlertmanagerConfig that names and reads the
  # Secret no more.
  [ "$(alertmanager_json | jq -c '.spec | has("alertmanagerConfiguration")')" = false ]
  operator="$(helm show chart "$CHART" | yq '.appVersion')"
  echo "the chart runs the operator $operator; the keys were read at $OPERATOR_READ"
  if [ "$operator" != "$OPERATOR_READ" ]; then
    echo "read pkg/alertmanager/types.go, the sanitize functions of pkg/alertmanager/amcfg.go and the volumes of pkg/alertmanager/statefulset.go at $operator for each key and name of this file's sets, then set OPERATOR_READ to $operator"
    return 1
  fi
  chart="$(default_config_json)"
  problems="$(shape_problems "$config" "$chart"; receiver_problems "$config")"
  echo "the tree: ${problems:-no problems}"
  [ -z "$problems" ]

  # The sets are not empty ones: each change to the configuration is refused for its own reason.
  mutants=0
  while IFS='#' read -r description expression expected; do
    problems="$(shape_problems "$(jq -c "$expression" <<<"$config")" "$chart"; receiver_problems "$(jq -c "$expression" <<<"$config")")"
    echo "$description: ${problems:-accepted}"
    grep -qxF -- "$expected" <<<"$problems" || survivors+=" $description;"
    mutants=$((mutants + 1))
  done <<'MUTANTS'
the route of the Watchdog removed#del(.route.routes[0])#the number of routes under the root is 1, not 2
the route of the Watchdog given continue#.route.routes[0].continue = true#route 1 holds the keys continue, group_interval, group_wait, matchers, receiver, repeat_interval, not group_interval, group_wait, matchers, receiver, repeat_interval
the two routes swapped#.route.routes |= reverse#route 2 holds the keys group_interval, group_wait, matchers, receiver, repeat_interval, not matchers, receiver
the severities narrowed to critical#.route.routes[1].matchers = ["severity = \"critical\""]#route 2 is {"matchers":["severity = \"critical\""],"receiver":"notify"}, not {"receiver":"notify","matchers":["severity =~ \"critical|warning\""]}
the root sending to notify#.route.receiver = "notify"#the receiver of the root route is "notify", not "null"
namespace dropped from the first inhibit rule#.inhibit_rules[0].equal = ["alertname"]#inhibit_rules is [{"equal":["alertname"],"source_matchers":["severity = critical"],"target_matchers":["severity =~ warning|info"]},{"equal":["namespace","alertname"],"source_matchers":["severity = warning"],"target_matchers":["severity = info"]},{"equal":["namespace"],"source_matchers":["alertname = InfoInhibitor"],"target_matchers":["severity = info"]},{"target_matchers":["alertname = InfoInhibitor"]}], not [{"source_matchers":["severity = critical"],"target_matchers":["severity =~ warning|info"],"equal":["namespace","alertname"]},{"source_matchers":["severity = warning"],"target_matchers":["severity = info"],"equal":["namespace","alertname"]},{"source_matchers":["alertname = InfoInhibitor"],"target_matchers":["severity = info"],"equal":["namespace"]},{"target_matchers":["alertname = InfoInhibitor"]}]
an inhibit rule in the deprecated form#.inhibit_rules[3] = {"target_match": {"alertname": "InfoInhibitor"}}#inhibit rule 4 holds the keys target_match, not target_matchers
a third route#.route.routes += [{"receiver": "notify", "matchers": ["team = \"platform\""]}]#the number of routes under the root is 3, not 2
a route under a route#.route.routes[1].routes = [{"receiver": "null", "matchers": ["severity = \"warning\""]}]#route 2 holds the keys matchers, receiver, routes, not matchers, receiver
a key the set does not hold at the top#.time_intervals = []#the configuration holds the keys global, inhibit_rules, receivers, route, templates, time_intervals, not global, inhibit_rules, receivers, route, templates
a key the set does not hold in global#.global.smtp_from = "alerts@example.invalid"#global holds the keys resolve_timeout, smtp_from, not resolve_timeout
the root grouped by namespace alone#.route.group_by = ["namespace"]#the grouping of the root route is ["namespace"], not ["alertname","namespace"]
the root waiting otherwise than the chart#.route.group_wait = "10s"#the group_wait of the root route is "10s", not "30s"
the root repeating otherwise than the chart#.route.repeat_interval = "4h"#the repeat_interval of the root route is "4h", not "12h"
a heartbeat that waits#.route.routes[0].group_wait = "30s"#route 1 is {"group_interval":"1m","group_wait":"30s","matchers":["alertname = \"Watchdog\""],"receiver":"heartbeat","repeat_interval":"5m"}, not {"receiver":"heartbeat","matchers":["alertname = \"Watchdog\""],"group_wait":"0s","group_interval":"1m","repeat_interval":"5m"}
a heartbeat every four hours#.route.routes[0].repeat_interval = "4h"#route 1 is {"group_interval":"1m","group_wait":"0s","matchers":["alertname = \"Watchdog\""],"receiver":"heartbeat","repeat_interval":"4h"}, not {"receiver":"heartbeat","matchers":["alertname = \"Watchdog\""],"group_wait":"0s","group_interval":"1m","repeat_interval":"5m"}
the Watchdog sent to notify#.route.routes[0].receiver = "notify"#route 1 is {"group_interval":"1m","group_wait":"0s","matchers":["alertname = \"Watchdog\""],"receiver":"notify","repeat_interval":"5m"}, not {"receiver":"heartbeat","matchers":["alertname = \"Watchdog\""],"group_wait":"0s","group_interval":"1m","repeat_interval":"5m"}
another template glob#.templates = ["/etc/alertmanager/templates/*.tmpl"]#templates is ["/etc/alertmanager/templates/*.tmpl"], not ["/etc/alertmanager/config/*.tmpl"]
a key the set does not hold on a webhook#(.receivers[] | select(.name == "heartbeat") | .webhook_configs[0].timeout) = "10s"#the webhook of heartbeat holds the keys send_resolved, timeout, url_file, not send_resolved, url_file
a key the set does not hold on a receiver#(.receivers[] | select(.name == "notify") | .email_configs) = []#the receiver notify holds the keys email_configs, name, webhook_configs, not name, webhook_configs
MUTANTS
  echo "survivors:${survivors:- none}"
  [ -z "$survivors" ]
  [ "$mutants" -eq 20 ]

  # No AlertmanagerConfig object is in the render or in any application.
  tree_render
  found="$(alertmanagerconfigs "$REPO" "$RENDER")"
  echo "AlertmanagerConfig objects: ${found:-none}"
  [ -z "$found" ]
  # One added to an application, enabled or not, or rendered by anything, is found.
  tree="$BATS_TEST_TMPDIR/tree"
  fake="$BATS_TEST_TMPDIR/fake-render"
  mkdir -p "$tree/kubernetes/apps" "$fake/lab-sto2/hello"
  cp -R "$REPO/kubernetes/apps/base" "$tree/kubernetes/apps/base"
  cp -R "$REPO/kubernetes/components" "$tree/kubernetes/components"
  printf '%s\n' 'apiVersion: monitoring.coreos.com/v1alpha1' 'kind: AlertmanagerConfig' 'metadata:' '  name: extra' 'spec: {}' \
    >"$tree/kubernetes/apps/base/demo/hello/app/alertmanagerconfig.yaml"
  yq -i '.resources += ["alertmanagerconfig.yaml"]' "$tree/kubernetes/apps/base/demo/hello/app/kustomization.yaml"
  cp "$tree/kubernetes/apps/base/demo/hello/app/alertmanagerconfig.yaml" "$fake/lab-sto2/hello/AlertmanagerConfig.monitoring.coreos.com_demo_extra.yaml"
  found="$(alertmanagerconfigs "$tree" "$fake")"
  echo "$found"
  [ "$found" = "$(printf '%s\n' 'kubernetes/apps/base/demo/hello/app: AlertmanagerConfig extra' 'the render: lab-sto2/hello/AlertmanagerConfig.monitoring.coreos.com_demo_extra.yaml')" ]
}

@test "Every alert the tree renders has a place in the route tree" {
  local problems counts routes rule rendered severity fixture file
  tree_render
  problems="$(severity_problems "$RENDER")"
  counts="$(yq -N '.spec.groups[].rules[] | select(has("alert")) | .labels.severity // "missing"' "$RENDER"/*/*/PrometheusRule.*.yaml | sort | uniq -c | xargs)"
  echo "alert rules of the render by severity: $counts"
  echo "problems: ${problems:-none}"
  [ -z "$problems" ]
  # The render holds the chart's rules and the tree's own, so the check is not of nothing.
  for severity in critical warning info none; do
    [[ " $counts " == *" $severity "* ]]
  done
  [ "$(yq -N '.spec.groups[].rules[] | select(has("alert")) | .alert' "$RENDER"/*/*/PrometheusRule.*.yaml | grep -c .)" -gt 100 ]

  # The route cases hold an alert of each of the five: a critical, a warning and an info alert, the
  # Watchdog and the info inhibitor.
  routes="$(yq -o json -I0 '[.cases[] | select(.kind == "route") | .alerts[]]' "$CASES")"
  for severity in critical warning info; do
    jq -e --arg severity "$severity" 'any(.[]; .labels.severity == $severity and .labels.alertname != "Watchdog" and .labels.alertname != "InfoInhibitor")' <<<"$routes" >/dev/null
  done
  # The Watchdog and the info inhibitor are routed by the labels their rendered rules give them:
  # the rule's own labels and its name, and beyond those only the labels its expression groups by.
  for rule in Watchdog InfoInhibitor; do
    rendered="$(RULE="$rule" yq -N -o json -I0 '.spec.groups[].rules[] | select(.alert == strenv(RULE)) | {"labels": .labels, "expr": .expr}' \
      "$RENDER"/*/*/PrometheusRule.*.yaml)"
    echo "$rule as rendered: $rendered"
    [ "$(grep -c . <<<"$rendered")" -eq 1 ]
    jq -e --arg rule "$rule" --argjson rendered "$rendered" '
      ($rendered.expr | (capture("^group by \\((?<by>[^)]*)\\)").by // "") | split(",") | map(gsub("^ +| +$"; "")) | map(select(. != ""))) as $grouped
      | any(.[]; .labels.alertname == $rule
          and (.labels | del(.alertname) | with_entries(select(.key as $k | $grouped | index($k) | not))) == $rendered.labels
          and ((.labels | del(.alertname) | keys) - ($rendered.labels | keys) - $grouped) == [])' <<<"$routes" >/dev/null
  done

  # A rule with another severity, with none, or with one made from a template is refused, naming
  # the application and the alert, in a copy of one of the tree's own rules.
  fixture="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$fixture/lab-sto2/vector"
  file="$fixture/lab-sto2/vector/PrometheusRule.monitoring.coreos.com_monitoring_vector.yaml"
  cp "$RENDER"/lab-sto2/vector/PrometheusRule.*.yaml "$file"
  [ -z "$(severity_problems "$fixture")" ]
  yq -i '.spec.groups[0].rules[0].labels.severity = "page"' "$file"
  # shellcheck disable=SC2016 # {{ $labels.severity }} is the rule's own template, as written
  yq -i '.spec.groups[0].rules += [{"alert": "NoSeverity", "expr": "vector(1)"}, {"alert": "TemplatedSeverity", "expr": "vector(1)", "labels": {"severity": "{{ $labels.severity }}"}}]' "$file"
  rule="$(yq '.spec.groups[0].rules[0].alert' "$file")"
  problems="$(severity_problems "$fixture")"
  echo "$problems"
  # shellcheck disable=SC2016 # {{ $labels.severity }} is the rule's own template, as written
  [ "$problems" = "$(printf '%s\n' \
    "vector: alert $rule: severity is page, not critical, warning or info, so it reaches no receiver and no one sees it" \
    "vector: alert NoSeverity: severity is missing, not critical, warning or info, so it reaches no receiver and no one sees it" \
    'vector: alert TemplatedSeverity: severity is {{ $labels.severity }}, not critical, warning or info, so it reaches no receiver and no one sees it')" ]
}

@test "The routes are checked with the Alertmanager image the chart deploys, in the static group of just ci" {
  local runs checked pin group moved line name
  stack
  runs="$(alertmanager_json | jq -r '.spec.image')"
  echo "the rendered Alertmanager runs: ${runs:-nothing}"
  [ -n "$runs" ]
  # What each recipe would run, with the justfile's variables filled in.
  run just --justfile "$REPO/justfile" --dry-run alerts-route-check
  [ "$status" -eq 0 ]
  # It runs the cases, and then its refusals.
  # shellcheck disable=SC2016 # the recipe's own text, as written
  [ "$(grep -E '^[[:blank:]]*scripts/alerts-route-run ' <<<"$output" | sed -E 's/^[[:blank:]]+//')" = "$(printf '%s\n' \
    'scripts/alerts-route-run "$dir/check" "${shell[@]}"' 'scripts/alerts-route-run --refusals "$dir/check" "${shell[@]}"')" ]
  checked="$(grep -oE "[a-z0-9.-]+/prometheus/alertmanager[^[:space:]'\"]*" <<<"$output" | sort -u)"
  echo "alerts-route-check runs: ${checked:-nothing}"
  [ "$(grep -c . <<<"$checked")" -eq 1 ]
  # The same repository and tag, pinned to one image by its digest.
  [[ $checked =~ ^(.+)@sha256:[0-9a-f]{64}$ ]]
  if [ "${BASH_REMATCH[1]}" != "$runs" ]; then
    echo "set alertmanager_image in the justfile to \"$runs@sha256:<digest>\", where <digest> is that tag's image index digest," \
      "as Renovate sets it with the chart in one pull request"
    return 1
  fi
  # Renovate's custom manager for the justfile moves the tag and the digest of the line under this
  # comment, in the pull request that moves the chart: the group that names the chart names the image.
  pin="$(grep -B1 -E '^alertmanager_image[[:blank:]]*:=' "$REPO/justfile" | head -n 1)"
  echo "above alertmanager_image: $pin"
  [ "$pin" = "# renovate: datasource=docker depName=${runs%:*}" ]
  group="$(awk '/matchPackageNames/ { block = ""; on = 1 } on { block = block $0 "\n" }
    on && /groupName/ { on = 0; if (block ~ /charts\/kube-prometheus-stack"/) printf "%s", block }' "$REPO/.renovate/groups.json5")"
  echo "the chart's Renovate group: $group"
  grep -qF "\"${runs%:*}\"" <<<"$group"
  run just --justfile "$REPO/justfile" --dry-run ci
  [ "$status" -eq 0 ]
  [[ $output == *"--alertmanager-image='$checked'"* ]]
  # The module checks with the image the recipe hands it, so it names none of its own; the image
  # has a pin, so its repository is no derived image and the lock holds no entry for it.
  run grep -rl 'prometheus/alertmanager' "$REPO/.dagger" "$REPO/scripts/lib/derived-images.sh" "$REPO/dagger.lock"
  [ "$status" -eq 1 ]
  # alerts-route-check is a check of the static group, which runs in just ci, and the module runs it
  # with the image's amtool and alertmanager.
  [ "$(just --justfile "$REPO/justfile" --dump --dump-format json | jq -r '.recipes.static.dependencies[].recipe | select(. == "alerts-route-check")')" = alerts-route-check ]
  grep -q 'alerts-route-check' "$REPO/.dagger/modules/ci/main.dang"
  grep -q '"/bin/amtool"' "$REPO/.dagger/modules/ci/main.dang"
  grep -q '"/bin/alertmanager"' "$REPO/.dagger/modules/ci/main.dang"

  # just alerts-route-check runs the image's shell in a container of that image with no network. A
  # docker that runs nothing prints no verdict of amtool or Alertmanager, and every case fails.
  stand_in docker
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" ALERTS_ROUTE_RENDER="$RENDERED" just --justfile "$REPO/justfile" alerts-route-check
  echo "$output"
  [ "$status" -ne 0 ]
  while IFS= read -r name; do
    grep -qxF -- "FAILED  $name" <<<"$output"
  done < <(yq -N '.cases[].name' "$CASES")
  [ "$(grep -c '^FAILED  ' <<<"$output")" -eq "$(yq '.cases | length' "$CASES")" ]
  [ "$(grep -c '^ok  ' <<<"$output")" -eq 0 ]
  cat "$STAND_IN_LOG"
  [ "$(grep -c . "$STAND_IN_LOG")" -ge 3 ]
  # Each container also has a read-only filesystem and no capability, and cannot gain one.
  while IFS=$'\t' read -r line _; do
    [[ $line == "run --rm --network none "*" --entrypoint sh $checked" ]]
    for flag in --read-only '--cap-drop ALL' '--security-opt no-new-privileges'; do
      [[ " $line " == *" $flag "* ]]
    done
  done <"$STAND_IN_LOG"

  # With a render whose Alertmanager names another image, the check fails before it runs anything,
  # saying which image the render deploys.
  moved="$BATS_TEST_TMPDIR/moved.yaml"
  IMAGE="${runs%:*}:v0.0.0-moved" yq '(select(.kind == "Alertmanager") | .spec.image) = strenv(IMAGE)' "$RENDERED" >"$moved"
  stand_in docker
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" ALERTS_ROUTE_RENDER="$moved" just --justfile "$REPO/justfile" alerts-route-check
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"the render deploys ${runs%:*}:v0.0.0-moved, not $runs"* ]]
  [ ! -s "$STAND_IN_LOG" ]
}

@test "the scenarios the check proves and its cases name each other" {
  local titles names kinds
  # A case's name is the title of the scenario it proves, and each such scenario has its case.
  titles="$(awk '/^[[:blank:]]*@/ { tagged = /@by:alerts-route-check([[:blank:]]|$)/; next }
    /^[[:blank:]]*Scenario:/ { if (tagged) { sub(/^[[:blank:]]*Scenario:[[:blank:]]*/, ""); print } tagged = 0 }' "$FEATURE" | sort)"
  names="$(yq -N '.cases[].name' "$CASES" | sort)"
  echo "scenarios: $titles"
  echo "cases: $names"
  [ -n "$titles" ]
  [ "$titles" = "$names" ]
  # Each is of a kind the check runs, and every kind has a case.
  kinds="$(yq -N '.cases[].kind' "$CASES" | sort -u | xargs)"
  echo "kinds: $kinds"
  [ "$kinds" = "inhibition route silence start" ]
}

@test "the stock alerts on failed notifications read the series the start case counts" {
  local rules name
  stack
  # While the files are not there every notification fails, and the two stock alerts that say so
  # fire: each reads the failed notifications against all notifications, by integration, the two
  # series the check reads after the start without files.
  rules="$(yq -N -o json -I0 'select(.kind == "PrometheusRule") | .spec.groups[].rules[] | select(has("alert"))
    | select(.alert == "AlertmanagerFailedToSendAlerts" or .alert == "AlertmanagerClusterFailedToSendAlerts")
    | {"alert": .alert, "severity": .labels.severity, "expr": .expr}' "$RENDERED" | jq -s .)"
  echo "$rules"
  for name in AlertmanagerFailedToSendAlerts AlertmanagerClusterFailedToSendAlerts; do
    jq -e --arg name "$name" 'any(.[]; .alert == $name
      and (.expr | test("rate\\(alertmanager_notifications_failed_total\\{[^}]*\\}\\[15m\\]\\)"))
      and (.expr | test("rate\\(alertmanager_notifications_total\\{[^}]*\\}\\[15m\\]\\)"))
      and (.expr | test("integration!~") | not))' <<<"$rules" >/dev/null
  done
  # A warning for one instance and a critical alert for the cluster of them: both go to notify, once
  # it has its file.
  [ "$(jq -r '[.[] | select(.expr | test("integration!~") | not) | .alert + " " + .severity] | sort | join(", ")' <<<"$rules")" \
    = "AlertmanagerClusterFailedToSendAlerts critical, AlertmanagerFailedToSendAlerts warning" ]
  grep -qF 'alertmanager_notifications_failed_total' "$REPO/scripts/alerts-route-run"
  grep -qF 'alertmanager_notifications_total' "$REPO/scripts/alerts-route-run"
  # The documentation names the two.
  grep -q 'AlertmanagerFailedToSendAlerts' "$REPO/docs/kubernetes.md"
  grep -q 'AlertmanagerClusterFailedToSendAlerts' "$REPO/docs/kubernetes.md"
}

@test "alerts-route-config writes the configuration of the Secret the one rendered Alertmanager reads" {
  local out="$BATS_TEST_TMPDIR/out" fixture="$BATS_TEST_TMPDIR/fixture.yaml" expected
  stack
  # From the tree, rendered by the script itself, it is the configuration this file's own render holds.
  run "$REPO/scripts/alerts-route-config" "$out"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(yq -o json -I0 '.' "$out/alertmanager.yaml" | jq -S .)" = "$(config_json | jq -S .)" ]
  [ "$(cat "$out/image")" = "$(alertmanager_json | jq -r '.spec.image')" ]
  cmp "$out/cases.yaml" "$CASES"
  [ "$(find "$out" -type f | wc -l)" -eq 3 ]
  # A directory that holds something is left alone.
  run "$REPO/scripts/alerts-route-config" "$out"
  [ "$status" -ne 0 ]
  [[ $output == *"exists and is not an empty directory"* ]]

  # A render with no Alertmanager, with two, or without the Secret the Alertmanager reads is
  # refused, saying which: the check would otherwise run on a configuration no Alertmanager has.
  while IFS='#' read -r description expression expected; do
    yq "$expression" "$RENDERED" >"$fixture"
    rm -rf "$out"
    run env ALERTS_ROUTE_RENDER="$fixture" "$REPO/scripts/alerts-route-config" "$out"
    echo "$description: status $status: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"$expected"* ]]
  done <<'FIXTURES'
no Alertmanager#del(select(.kind == "Alertmanager"))#the chart renders 0 Alertmanager objects, not exactly one
no Secret of the Alertmanager's#del(select(.kind == "Secret" and .metadata.name == "alertmanager-kube-prometheus-stack-alertmanager"))#the chart renders 0 Secrets named alertmanager-kube-prometheus-stack-alertmanager, the one its Alertmanager reads, not exactly one
an Alertmanager that reads another Secret#(select(.kind == "Alertmanager") | .spec.configSecret) = "elsewhere"#the chart renders 0 Secrets named elsewhere, the one its Alertmanager reads, not exactly one
a Secret without the configuration#del(select(.kind == "Secret" and .metadata.name == "alertmanager-kube-prometheus-stack-alertmanager") | .data["alertmanager.yaml"])#holds no alertmanager.yaml
FIXTURES
  yq '.' "$RENDERED" >"$fixture"
  yq 'select(.kind == "Alertmanager") | .metadata.name = "second"' "$RENDERED" | sed '1i ---' >>"$fixture"
  rm -rf "$out"
  run env ALERTS_ROUTE_RENDER="$fixture" "$REPO/scripts/alerts-route-config" "$out"
  echo "two Alertmanagers: status $status: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"the chart renders 2 Alertmanager objects, not exactly one"* ]]
}

@test "alerts-route-run runs amtool on every route case, reports every case and fails the ones nothing answers for" {
  local expected ran cases="$BATS_TEST_TMPDIR/cases.json" name
  stack
  check_dir
  yq -o json -I0 '.cases' "$CASES" >"$cases"
  stand_in shell

  # A shell that prints nothing: no case has a verdict of amtool or Alertmanager, and every case
  # fails under its name.
  run "$REPO/scripts/alerts-route-run" "$CHECK" "$BATS_TEST_TMPDIR/bin/shell"
  echo "$output"
  [ "$status" -ne 0 ]
  while IFS= read -r name; do
    grep -qxF -- "FAILED  $name" <<<"$output"
  done < <(yq -N '.cases[].name' "$CASES")
  [ "$(grep -c '^FAILED  ' <<<"$output")" -eq "$(jq 'length' "$cases")" ]

  # An amtool that agrees with every expectation: the route cases pass, each alert of each handed to
  # amtool's routes test with the receivers the case expects, and the cases that need an Alertmanager
  # still fail, as nothing answered for them.
  stand_in shell
  run env STAND_IN=agree "$REPO/scripts/alerts-route-run" "$CHECK" "$BATS_TEST_TMPDIR/bin/shell"
  echo "$output"
  [ "$status" -ne 0 ]
  while IFS= read -r name; do
    grep -qxF -- "ok      $name" <<<"$output"
  done < <(case_names route)
  while IFS= read -r name; do
    grep -qxF -- "FAILED  $name" <<<"$output"
  done < <(case_names start inhibition silence)
  [ "$(grep -c '^ok      ' <<<"$output")" -eq "$(case_names route | grep -c .)" ]
  cat "$STAND_IN_LOG"
  expected="$(jq -r '.[] | select(.kind == "route") | .alerts[]
    | "amtool config routes test --config.file=alertmanager.yaml --verify.receivers=" + (.receivers | join(","))
      + " " + (.labels | to_entries | sort_by(.key) | map(.key + "=" + .value) | join(" "))' "$cases" | sort)"
  ran="$(awk -F'\t' '$2 == "run" && $3 ~ /^amtool config routes test / { print $3 }' "$STAND_IN_LOG" | sort)"
  [ -n "$expected" ]
  [ "$ran" = "$expected" ]
  # amtool checks the configuration first, and one Alertmanager serves the cases that need one: it
  # is started once, given every alert of those cases, and stopped.
  [ "$(awk -F'\t' '$2 == "run" { print $3 }' "$STAND_IN_LOG" | head -n 1)" = "amtool check-config alertmanager.yaml" ]
  [ "$(awk -F'\t' '$2 == "live"' "$STAND_IN_LOG" | grep -c .)" -eq 1 ]
  [ "$(awk -F'\t' '$2 == "live"' "$STAND_IN_LOG" | grep -o 'add	' | grep -c .)" -eq "$(jq '[.[] | select(.kind != "route") | .alerts[]] | length' "$cases")" ]

  # A case of a kind the check does not know fails it, and so does one whose expectation is not
  # written as its kind's is; the others still run.
  yq -i '.cases += [{"name": "An alert is teleported", "kind": "teleport", "alerts": [{"labels": {"alertname": "X"}}]},
    {"name": "A route case without receivers", "kind": "route", "alerts": [{"labels": {"alertname": "X"}, "receivers": []}]},
    {"name": "A route case with a key of no kind", "kind": "route", "alerts": [{"labels": {"alertname": "X"}, "receivers": ["null"], "recievers": ["notify"]}]},
    {"name": "A route case with a label amtool would read otherwise", "kind": "route", "alerts": [{"labels": {"alertname": "X Y"}, "receivers": ["null"]}]}]' "$CHECK/cases.yaml"
  stand_in shell
  run env STAND_IN=agree "$REPO/scripts/alerts-route-run" "$CHECK" "$BATS_TEST_TMPDIR/bin/shell"
  echo "$output"
  [ "$status" -ne 0 ]
  grep -qxF -- "FAILED  An alert is teleported" <<<"$output"
  grep -qF -- "is of the kind teleport, which the check does not run" <<<"$output"
  grep -qxF -- "FAILED  A route case without receivers" <<<"$output"
  grep -qxF -- "FAILED  A route case with a key of no kind" <<<"$output"
  grep -qxF -- "FAILED  A route case with a label amtool would read otherwise" <<<"$output"
  [ "$(grep -c '^ok      ' <<<"$output")" -eq "$(case_names route | grep -c .)" ]
  # Two cases of one name could not be told apart in the report.
  check_dir
  yq -i '.cases += [.cases[0]]' "$CHECK/cases.yaml"
  run env STAND_IN=agree "$REPO/scripts/alerts-route-run" "$CHECK" "$BATS_TEST_TMPDIR/bin/shell"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"two cases are named"* ]]
}

@test "alerts-route-run fails the start case unless every notification failed on its file" {
  local name receiver path failed_on_files=() sent total reasons
  stack
  check_dir
  yq -i '.cases |= map(select(.kind == "start"))' "$CHECK/cases.yaml"
  [ "$(yq '.cases | length' "$CHECK/cases.yaml")" -eq 1 ]
  name="$(yq -N '.cases[0].name' "$CHECK/cases.yaml")"
  # Alertmanager's line for a notification of RECEIVER that failed for the reason given.
  notify_failed() {
    printf 'time=2026-01-01T00:00:00.000Z level=ERROR source=dispatch.go:360 msg="Notify failed" component=dispatcher receiver=%s integration=webhook[0] attempts=1 err="%s/webhook[0]: notify retry canceled due to unrecoverable error after 1 attempts: %s"\n' "$1" "$1" "$2"
  }
  while read -r receiver path; do
    failed_on_files+=("$(notify_failed "$receiver" "read url_file: open $path: no such file or directory")")
    [ "$receiver" != notify ] || sent="$(notify_failed notify 'Post "<redacted>": dial tcp: lookup example.invalid: no such host')"
  done < <(yq -N '.receivers[] | select(has("webhook_configs")) | .name + " " + .webhook_configs[0].url_file' "$CHECK/alertmanager.yaml")
  total="$(yq '[.cases[0].alerts[].receivers[]] | unique | length' "$CHECK/cases.yaml")"
  [ -n "$sent" ] && [ "$total" -eq "${#failed_on_files[@]}" ]
  stand_in shell

  # Every receiver's notification failed on its file, and every one attempted is counted as failed:
  # the case holds.
  start_frames "$(printf '%s\n' "${failed_on_files[@]}")" "$(printf '%s\n' \
    "alertmanager_notifications_total{integration=\"webhook\"} $total" \
    "alertmanager_notifications_failed_total{integration=\"webhook\",reason=\"other\"} $total")"
  run env STAND_IN=frames "$REPO/scripts/alerts-route-run" "$CHECK" "$BATS_TEST_TMPDIR/bin/shell"
  echo "$output"
  grep -qxF -- "ok      $name" <<<"$output"

  # A notification of notify that failed on its way to a host and not on the file: it read an
  # address, so the case fails for that alone.
  start_frames "$(printf '%s\n' "${failed_on_files[@]}" | grep -v ' receiver=notify '; echo "$sent")" "$(printf '%s\n' \
    "alertmanager_notifications_total{integration=\"webhook\"} $total" \
    "alertmanager_notifications_failed_total{integration=\"webhook\",reason=\"other\"} $total")"
  run env STAND_IN=frames "$REPO/scripts/alerts-route-run" "$CHECK" "$BATS_TEST_TMPDIR/bin/shell"
  echo "$output"
  grep -qxF -- "FAILED  $name" <<<"$output"
  reasons="$(grep '^        ' <<<"$output")"
  [ "$reasons" = "        the log holds no notification of notify that failed on $(yq -N '.receivers[] | select(.name == "notify") | .webhook_configs[0].url_file' "$CHECK/alertmanager.yaml")" ]

  # One notification attempted and not counted as failed may have left: the case fails for that alone.
  start_frames "$(printf '%s\n' "${failed_on_files[@]}")" "$(printf '%s\n' \
    "alertmanager_notifications_total{integration=\"webhook\"} $total" \
    "alertmanager_notifications_failed_total{integration=\"webhook\",reason=\"other\"} $((total - 1))")"
  run env STAND_IN=frames "$REPO/scripts/alerts-route-run" "$CHECK" "$BATS_TEST_TMPDIR/bin/shell"
  echo "$output"
  grep -qxF -- "FAILED  $name" <<<"$output"
  reasons="$(grep '^        ' <<<"$output")"
  [ "$reasons" = "        of $total webhook notifications $((total - 1)) are counted in alertmanager_notifications_failed_total, so one may have left" ]
}

@test "alerts-route-run proves its refusals, and a shell that accepts everything fails them" {
  local before
  stack
  check_dir
  before="$(cd "$CHECK" && sha256sum alertmanager.yaml cases.yaml image)"
  # An amtool that agrees with every expectation agrees with the route case whose expectation is
  # wrong: the refusals fail, saying what the check let through.
  stand_in shell
  run env STAND_IN=agree "$REPO/scripts/alerts-route-run" --refusals "$CHECK" "$BATS_TEST_TMPDIR/bin/shell"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"alerts-route-run: the check passed a route case whose expectation is wrong"* ]]
  # What the refusals changed is put back, however they end.
  [ "$(cd "$CHECK" && sha256sum alertmanager.yaml cases.yaml image)" = "$before" ]
  [ "$(find "$CHECK" -type f | wc -l)" -eq 3 ]
}

@test "alerts-route-config and alerts-route-run give what they run none of the secrets" {
  local bin="$BATS_TEST_TMPDIR/recorded" tool real name
  mkdir -p "$bin"
  # Each tool is recorded, by the names of its environment, and then runs as itself.
  for tool in flux helm; do
    real=$(command -v "$tool")
    printf '#!/usr/bin/env bash\nenv | cut -d= -f1 >> %q\nexec %q "$@"\n' \
      "$BATS_TEST_TMPDIR/names.$tool" "$real" >"$bin/$tool"
    chmod +x "$bin/$tool"
  done
  local names=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CLUSTER_S3_ACCESS_KEY_ID CLUSTER_S3_SECRET_ACCESS_KEY
    OS_CLOUD OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET TF_STATE_PASSPHRASE
    TF_ENCRYPTION SOPS_AGE_KEY SOPS_AGE_KEY_FILE FLUX_AGE_KEY FLUX_AGE_KEY_FILE OPERATOR_CIDRS GH_TOKEN)
  local settings=()
  for name in "${names[@]}"; do settings+=("$name=marker-$name"); done

  run env PATH="$bin:$PATH" "${settings[@]}" "$REPO/scripts/alerts-route-config" "$BATS_TEST_TMPDIR/out"
  echo "$output"
  [ "$status" -eq 0 ]
  for tool in flux helm; do
    echo "$tool"
    [ -s "$BATS_TEST_TMPDIR/names.$tool" ]
    grep -qx HELM_CACHE_HOME "$BATS_TEST_TMPDIR/names.$tool"
    for name in "${names[@]}"; do
      if grep -qx "$name" "$BATS_TEST_TMPDIR/names.$tool"; then
        echo "$tool got $name"
        return 1
      fi
    done
  done

  # The command alerts-route-run is given, docker or a shell, and so amtool, Alertmanager and
  # whatever else that shell starts.
  stand_in shell
  run env "${settings[@]}" "$REPO/scripts/alerts-route-run" "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/bin/shell"
  [ -s "$STAND_IN_LOG.env" ]
  grep -qx PATH "$STAND_IN_LOG.env"
  for name in "${names[@]}"; do
    if grep -qx "$name" "$STAND_IN_LOG.env"; then
      echo "the shell got $name"
      return 1
    fi
  done
}
