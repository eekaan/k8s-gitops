#!/usr/bin/env bats
# Proves the scenarios of features/node-firewall.feature that tie the node firewall's rules to the
# ports the cluster's pods hold on a node's own network; each test carries its scenario's title.
# The kubernetes/ tree is rendered once for the file by scripts/render, its charts pulled from their
# public registries, and read with yq and jq beside talos/firewall.yaml and
# node-firewall-exceptions.yaml. The checks are functions of this file that take a render, an
# inventory and an exceptions file, so each test runs them on the tree and then on copies with one
# change each. Needs flux, helm, kustomize, yq, jq and sha256sum on PATH (the versions pinned for
# the repository). Nothing here reaches a node, a cluster or the cloud.

load fixtures/probe-shape

# The kinds that carry a pod template, which scripts/pod-security-check evaluates, and the other
# kinds the checks read: the releases a chart's object takes its namespace from, what scrapes, and
# what holds a Probe's prober and targets to the pod network.
WORKLOADS='Pod Deployment StatefulSet DaemonSet ReplicaSet ReplicationController Job CronJob'
OTHERS='HelmRelease Service PodMonitor ServiceMonitor Probe ScrapeConfig Prometheus PrometheusAgent Gateway EnvoyProxy Namespace Endpoints EndpointSlice'

setup_file() {
  local repo kinds
  repo=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_FILE_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  "$repo/scripts/render" "$BATS_FILE_TMPDIR/render" > /dev/null
  # The files of the render that hold an object of those kinds, for a test to copy and change; the
  # render writes one object to a file, its kind on a line of its own.
  kinds="$WORKLOADS $OTHERS"
  mkdir "$BATS_FILE_TMPDIR/view"
  (cd "$BATS_FILE_TMPDIR/render" && grep -rlxE "kind: (${kinds// /|})" . |
    while IFS= read -r file; do cp --parents "$file" "$BATS_FILE_TMPDIR/view/"; done)
  # And the configuration of Envoy Gateway's controller, which fixtures/probe-shape.bash reads by
  # its path.
  (cd "$BATS_FILE_TMPDIR/render" && for file in */envoy-gateway/ConfigMap_*.yaml; do
    [ ! -f "$file" ] || cp --parents "$file" "$BATS_FILE_TMPDIR/view/"; done)
}

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  RENDER="$BATS_FILE_TMPDIR/render"
  VIEW="$BATS_FILE_TMPDIR/view"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/node-listeners"
  INVENTORY="$REPO/talos/firewall.yaml"
  EXCEPTIONS="$REPO/node-firewall-exceptions.yaml"
  DOCS="$REPO/docs/cluster.md"
}

# probe_places RENDER: where a Probe in the one shape the checks accept has its prober and its
# targets, read from RENDER by fixtures/probe-shape.bash as tests/probes.bats reads them, as one JSON
# document: .exporter, the address of the blackbox exporter's Service; .controller, the namespace of
# Envoy Gateway's controller and the default EnvoyProxy its configuration holds; and .gateways, each
# Gateway of the render with the cluster name of its proxies' Service. Each has an .error in place
# of what cannot be read, as in a render of more than one cluster.
probe_places() {
  local render=$1 dir exporter='' exporter_error='' controller='' controller_error='' default='{}'
  local file namespace name service gateways=()
  local -a controllers=() exporters=()
  for dir in "$render"/*/envoy-gateway; do [ ! -d "$dir" ] || controllers+=("${dir%/envoy-gateway}"); done
  for dir in "$render"/*/blackbox-exporter; do [ ! -d "$dir" ] || exporters+=("${dir%/blackbox-exporter}"); done
  if [ "${#exporters[@]}" -ne 1 ]; then
    exporter_error="the render holds ${#exporters[@]} applications blackbox-exporter, not one"
  elif ! exporter=$(exporter_service "${exporters[0]}" 2>&1); then
    exporter_error=$exporter
    exporter=''
  fi
  if [ "${#controllers[@]}" -ne 1 ]; then
    controller_error="the render holds ${#controllers[@]} applications envoy-gateway, not one"
  elif ! controller=$(controller_namespace "${controllers[0]}" 2>&1); then
    controller_error=$controller
    controller=''
  else
    default=$(yq -N -o json -I0 'select(.kind == "ConfigMap" and .data["envoy-gateway.yaml"] != null) | .data["envoy-gateway.yaml"] | from_yaml
      | .envoyProxy // {}' "${controllers[0]}"/envoy-gateway/ConfigMap_*.yaml) || return 2
  fi
  while IFS= read -r file; do
    while read -r namespace name; do
      if [ -z "$controller" ]; then
        gateways+=("$(jq -cn --arg gateway "$namespace/$name" '{gateway: $gateway, error: "no controller to name its proxies"}')")
      elif service=$(proxy_service_name "$namespace" "$name" "$controller" 2>&1); then
        gateways+=("$(jq -cn --arg gateway "$namespace/$name" --arg service "$service" '{gateway: $gateway, service: $service}')")
      else
        gateways+=("$(jq -cn --arg gateway "$namespace/$name" --arg error "$service" '{gateway: $gateway, error: $error}')")
      fi
    done < <(yq -N 'select(.kind == "Gateway") | (.metadata.namespace // "") + " " + .metadata.name' "$file")
  done < <(grep -rlx 'kind: Gateway' "$render" || true)
  jq -n --arg exporter "$exporter" --arg exporterError "$exporter_error" --arg controller "$controller" \
    --arg controllerError "$controller_error" --argjson default "$default" --argjson gateways "$(printf '%s\n' "${gateways[@]}" | jq -cs 'map(select(. != null))')" '
    {exporter: (if $exporterError != "" then {error: $exporterError} else {address: $exporter} end),
     controller: (if $controllerError != "" then {error: $controllerError} else {namespace: $controller, default: $default} end),
     gateways: $gateways}'
}

# evaluate RENDER INVENTORY EXCEPTIONS: what the checks find, as one JSON document. RENDER is a
# directory of rendered objects, one or more to a file; INVENTORY is talos/firewall.yaml or a copy;
# EXCEPTIONS is node-firewall-exceptions.yaml or a copy, read as two empty lists when it is not
# there, which is itself a finding.
#   A listener is a port a container or an init container declares in a pod template that sets
#   hostNetwork: its namespace (the template's, or its release's for a chart's object without one),
#   Kind/name, protocol (TCP when unset) and containerPort. A rule of INVENTORY admits it when it
#   has its protocol and its port lies in one of the rule's ports or ranges.
#   .malformed   EXCEPTIONS missing, or with a key, a list or an entry that is not of its form
#   .unplaced    workloads, Services and monitors with no namespace and no release to take one from
#   .unaccounted listeners that are not admitted by exactly one rule every node has, or listed once
#                under no-rule, and not both; and a hostPort that is not the containerPort
#   .account     one line per listener: its rule's name, nodes and sources, or no-rule
#   .unserved    rules that no listener uses and no-pod does not name, or both; entries without use
#   .served      one line per rule: the listeners it admits, or no-pod
#   .hostPorts   host ports that pod templates off the host network declare
#   .onHost      one line per host port that a pod template on the host network declares
#   .scraped     monitors that scrape a listener listed under no-rule, Probes that are not in the
#                one shape it accepts, and scrapers it cannot read
#   .unscraped   one line per listener listed under no-rule
#   .read        how many pod templates, on and off the host network, monitors and Probes it read
evaluate() {
  local render=$1 inventory=$2 exceptions=$3 file listed='{}' present=true probing
  local -a files=()
  # A file yq cannot read fails the evaluation, instead of leaving jq with what came before it.
  local -
  set -o pipefail
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(find "$render" -type f -name '*.yaml' -print0 | sort -z)
  if [ "${#files[@]}" -eq 0 ]; then
    echo "$render holds no rendered object"
    return 2
  fi
  if [ -f "$exceptions" ]; then
    listed=$(yq -o json -I0 '.' "$exceptions") || return 2
  else
    present=false
  fi
  probing=$(probe_places "$render") || return 2
  # shellcheck disable=SC2016 # a jq program
  yq -N -o json -I0 'select(. != null)' "${files[@]}" | jq -n --arg workloads "$WORKLOADS" --arg others "$OTHERS" \
    --argjson inventory "$(yq -o json -I0 '.' "$inventory")" --argjson exceptions "$listed" --argjson present "$present" \
    --argjson probing "$probing" --argjson relabelings "$PROBE_RELABELINGS" --argjson modules "$PROBE_MODULES" '
    ($workloads / " ") as $workloadKinds
    | [inputs | select(type == "object" and (.kind | IN(($workloads + " " + $others) / " " | .[])))] as $objects
    # A chart object without a namespace is installed into its release namespace, which the labels
    # helm-controller gives it name through the HelmRelease, as scripts/pod-security-check reads it.
    | ([$objects[] | select(.kind == "HelmRelease")
        | {key: ((.metadata.namespace // "") + "/" + .metadata.name), value: (.spec.targetNamespace // .metadata.namespace // "")}]
       | from_entries) as $releases
    | def namespace: (.metadata.labels // {}) as $labels
        | .metadata.namespace
          // $releases[($labels["helm.toolkit.fluxcd.io/namespace"] // "") + "/" + ($labels["helm.toolkit.fluxcd.io/name"] // "")] // "";
      def named: "\(.kind) \(namespace)/\(.metadata.name)";
      def id: "\(.ns) \(.workload) \(.protocol) \(.port)";
      # How the pods of a pod spec on input resolve a name besides by the resolver of the cluster:
      # by addresses of their own for it, by a resolver configuration of their own, or by none of
      # those of the cluster.
      def resolution: [(select(.hostAliases != null) | "hostAliases"), (select(.dnsConfig != null) | "dnsConfig"),
        (select(.dnsPolicy == "None") | "dnsPolicy None")];

    [$objects[] | select(.kind | IN($workloadKinds[]))
      | (if .kind == "Pod" then {metadata, spec} elif .kind == "CronJob" then .spec.jobTemplate.spec.template else .spec.template end) as $template
      | {ns: namespace, workload: "\(.kind)/\(.metadata.name)", host: ($template.spec.hostNetwork == true),
         labels: ($template.metadata.labels // {}), resolution: ($template.spec | resolution),
         ports: [($template.spec.initContainers // [])[], ($template.spec.containers // [])[] | (.ports // [])[]
           | {name: (.name // ""), protocol: ((.protocol // "TCP") | ascii_downcase), port: .containerPort, hostPort: (.hostPort // 0)}]}] as $templates
    | ([$templates[] | select(.host) | . as $t | .ports[] | {ns: $t.ns, workload: $t.workload, protocol, port}]
       | unique_by([.ns, .workload, .protocol, .port])) as $listeners

    | [$inventory.listeners[] | {name, protocol, nodes, from: (.from | sort | join(",")),
        ranges: [.ports[] | tostring | split("-") | map(tonumber) | {lo: .[0], hi: .[-1]}]}] as $rules
    | def admits($l): .protocol == $l.protocol and any(.ranges[]; .lo <= $l.port and $l.port <= .hi);
      def ports: [.ranges[] | if .lo == .hi then "\(.lo)" else "\(.lo)-\(.hi)" end] | join(",");

    (if ($exceptions | type) == "object" then $exceptions else {} end) as $lists
    | [($lists["no-rule"] | arrays)[] | objects] as $noRule
    | [($lists["no-pod"] | arrays)[] | objects] as $noPod
    | def entries($list; $keys): ($lists[$list] | arrays) | to_entries[] | "\($list) entry \(.key + 1)" as $where | .value as $entry
        | if ($entry | type) != "object" then "\($where) is not a map of \($keys | join(", "))"
          else ($keys[] | select(. as $key | $entry | has($key) | not) | "\($where) has no \(.)"),
               ($entry | keys_unsorted[] | select(IN($keys[]) | not) | "\($where) has the unknown key \(.)"),
               (if ($entry | has("reason")) and ($entry.reason == null or (($entry.reason | type) == "string" and ($entry.reason | test("^\\s*$"))))
                then "\($where) has an empty reason" else empty end)
          end;
    [if $present | not then "the exceptions file does not exist"
     elif ($exceptions | type) != "object" then "the exceptions file is not a map of the lists no-rule and no-pod"
     else ($exceptions | keys_unsorted[] | select(IN("no-rule", "no-pod") | not) | "the exceptions file has the unknown key \(.)"),
          (("no-rule", "no-pod") as $list | select(($exceptions[$list] | type) != "array") | "the exceptions file has no list \($list)"),
          entries("no-rule"; ["namespace", "workload", "protocol", "port", "reason"]),
          entries("no-pod"; ["rule", "reason"])
     end] as $malformed

    | [($templates[] | select(.ns == "") | "\(.workload) has no namespace and no HelmRelease to take one from"),
       ($objects[] | select(.kind | IN("Service", "PodMonitor", "ServiceMonitor", "Probe")) | select(namespace == "")
         | "\(.kind)/\(.metadata.name) has no namespace and no HelmRelease to take one from")] as $unplaced

    | [$listeners[] | . as $l
        | {l: $l, id: ($l | id), admit: [$rules[] | select(admits($l))],
           listed: ([$noRule[] | select(.namespace == $l.ns and .workload == $l.workload and .protocol == $l.protocol and .port == $l.port)] | length)}] as $judged
    | [($templates[] | select(.host) | . as $t | .ports[] | select(.hostPort != 0 and .hostPort != .port)
         | "\($t.ns) \($t.workload) \(.protocol) \(.port): its hostPort \(.hostPort) is not its containerPort, and on the host network the two are one port"),
       ($judged[] | (.admit | map(.name) | join(", ")) as $names
         | if (.admit | length) == 0 and .listed == 0 then
             "\(.id): no rule of the inventory admits it and the exceptions file does not list it under no-rule"
           elif (.admit | length) > 0 and .listed > 0 then
             "\(.id): the rule \($names) admits it and the exceptions file lists it under no-rule"
           elif (.admit | length) > 1 then "\(.id): \(.admit | length) rules admit it: \($names)"
           elif .listed > 1 then "\(.id): the exceptions file lists it \(.listed) times under no-rule"
           elif (.admit | length) == 1 and .admit[0].nodes != "all" then
             "\(.id): the rule \($names) admits it on \(.admit[0].nodes) nodes alone, which covers no pod of the render"
           else empty end)] as $unaccounted
    | [$judged[] | "\(.id): " + ([(.admit[] | "\(.name), \(.nodes), \(.from)"), (if .listed > 0 then "no-rule" else empty end)]
        | if length == 0 then "nothing" else join("; ") end)] as $account

    | [$rules[] | . as $r
        | {r: $r, users: [$listeners[] | select(. as $l | $r | admits($l))], named: ([$noPod[] | select(.rule == $r.name)] | length)}] as $matched
    | ([($matched[] | "the rule \(.r.name) (\(.r.protocol) \(.r | ports))" as $rule
          | if (.users | length) == 0 and .named == 0 then
              "\($rule): no host-network pod of the render declares a port it admits and the exceptions file does not name it under no-pod: a stale rule, or a listener to name there"
            elif (.users | length) > 0 and .named > 0 then
              "\($rule): the exceptions file names it under no-pod, but it admits \(.users | map(id) | join(", ")): an entry without use"
            elif .named > 1 then "\($rule): the exceptions file names it \(.named) times under no-pod"
            else empty end),
        ($noPod[] | select(.rule != null) | .rule as $name | select(all($rules[]; .name != $name))
          | "no-pod names the rule \($name), which the inventory does not hold: an entry without use"),
        ($noRule[] | select(has("namespace") and has("workload") and has("protocol") and has("port")) | . as $entry
          | select(all($listeners[]; .ns != $entry.namespace or .workload != $entry.workload or .protocol != $entry.protocol or .port != $entry.port))
          | "no-rule lists \($entry.namespace) \($entry.workload) \($entry.protocol) \($entry.port), which no host-network pod of the render declares: an entry without use")]
       | unique) as $unserved
    | [$matched[] | "\(.r.name): " + (if (.users | length) > 0 then (.users | map(id) | join(", ")) elif .named > 0 then "no-pod" else "nothing" end)] as $served

    | ([$templates[] | select(.host | not) | . as $t | .ports[] | select(.hostPort != 0)
         | "\($t.ns) \($t.workload) \(.protocol) \(.port): a pod on the pod network declares the host port \(.hostPort), which Cilium serves before the node firewall sees the packet"]
       | unique) as $hostPorts
    | ([$templates[] | select(.host) | . as $t | .ports[] | select(.hostPort != 0)
         | "\($t.ns) \($t.workload) \(.protocol) \(.port): a host port on the host network"]
       | unique) as $onHost

    # The namespaces a monitor looks in: every one (null), those it names, or its own when it names none.
    | def looks_in: if .spec.namespaceSelector.any == true then null
        elif ((.spec.namespaceSelector.matchNames // []) | length) > 0 then .spec.namespaceSelector.matchNames
        else [namespace] end;
      def holds($ns): . == null or any(.[]; . == $ns);
      # Whether the label selector on input selects LABELS. An operator this does not know selects.
      def selects($labels):
        ((.matchLabels // {}) | to_entries | all(.key as $key | .value == $labels[$key]))
        and ((.matchExpressions // []) | all(.key as $key | (.values // []) as $values
          | if .operator == "In" then ($labels | has($key)) and any($values[]; . == $labels[$key])
            elif .operator == "NotIn" then (($labels | has($key)) and any($values[]; . == $labels[$key])) | not
            elif .operator == "Exists" then $labels | has($key)
            elif .operator == "DoesNotExist" then $labels | has($key) | not
            else true end));
      # Whether the endpoint of a monitor on input rewrites the address it scrapes, which this does not
      # follow: by name, or by a relabeling that writes a label it does not name, which can be the
      # address. A labelmap writes the labels its replacement makes of the names its regex matches,
      # and a replacement expands the groups of the regex in its target label (relabel.go of
      # Prometheus).
      def readdressed: any(.relabelings[]?; .targetLabel == "__address__"
        or ((.action // "replace") | ascii_downcase) == "labelmap" or ((.targetLabel // "") | contains("$")));
      # The target port of the endpoint or the Service port on input, a name or a number, or 0 where
      # it names none: one that is 0 or empty names none, to the Prometheus Operator, which then
      # keeps every port, and to Kubernetes, which then takes the number of the Service port itself.
      def target: (.targetPort // 0) | if . == "" then 0 else . end;
      # The keys of an object on input, and none of anything else.
      def fields: if type == "object" then keys else [] end;
      # The endpoints the render holds for the Service NAME in NAMESPACE, written by hand, which lead
      # where they say: an EndpointSlice that names the Service, or its Endpoints, which the cluster
      # mirrors into one.
      def endpoints($namespace; $name): [$objects[] | select(namespace == $namespace
          and ((.kind == "EndpointSlice" and (.metadata.labels // {})["kubernetes.io/service-name"] == $name)
            or (.kind == "Endpoints" and .metadata.name == $name)))
        | "\(.kind) \(namespace)/\(.metadata.name)"];

    # The one shape of a Probe this accepts, where probe_places reads with fixtures/probe-shape.bash
    # what it names: its prober the Service of the blackbox exporter, by the name and port the
    # render gives it, whose pods the render holds, none on the host network and none resolving
    # names their own way, nor Prometheus, which resolves the name of the prober; its targets
    # static, each the Service of the proxies of the one Gateway of the render, by the name the
    # controller gives it, over http or https on a port of the listeners of the Gateway, the port
    # the URL names or the one its scheme implies, as the http prober of every module the Probe may
    # name takes it; its spec, its prober and its targets nothing more, its labels the hostname
    # alone, and its relabelings the one of the tree, which run after those of the operator, that
    # set the address to the prober and the target to the static one, and change neither. The
    # controller makes the proxies and their Service at run time, by its source at
    # PROXY_SERVICE_READ_AT: the Service by that name, of one of the types an EnvoyProxy may give
    # it, each of which leads to the pods it selects, while no EnvoyProxy and no default of the
    # controller names it, patches it or merges the Gateways, and the render holds no Service of the
    # name; the pods off the host network unless a patch puts them there, in a namespace whose Pod
    # Security level must refuse it. Whatever a module runs, the only hosts a Probe in the shape
    # reaches are those two Services, on the ports they have. Any other Probe is refused, as this
    # does not follow where another name leads: a Service made at run time, a headless Service,
    # whose name resolves to the own addresses of its pods, those of the nodes for pods on the host
    # network, a Service without a selector and an ExternalName, which lead where endpoints or
    # another name say.
    ([$objects[] | select(.kind == "Probe")] | length > 0) as $probed
    | ($probing.exporter.address // null) as $prober
    | ($prober // "" | capture("^(?<name>[^.]+)[.](?<namespace>[^.]+)[.]svc[.]cluster[.]local:[0-9]+$") // null) as $exporterAt
    | [$objects[] | select($exporterAt != null and .kind == "Service" and .metadata.name == $exporterAt.name and namespace == $exporterAt.namespace)] as $exporterServices
    | (if $probing.exporter.error != null then [$probing.exporter.error]
       elif ($exporterServices | length) != 1 then ["the render holds not one Service \($prober)"]
       else $exporterServices[0] as $s | ($s | namespace) as $ns
         | "the Service of the blackbox exporter, \($ns)/\($s.metadata.name)," as $it
         | [if ($s.spec.type // "ClusterIP") != "ClusterIP" then "\($it) is of the type \($s.spec.type)"
            elif (($s.spec.selector // {}) | length) == 0 then "\($it) has no selector"
            else [$templates[] | select(.ns == $ns) | . as $t | select($s.spec.selector | to_entries | all(.key as $key | .value == $t.labels[$key]))] as $selected
              | if ($selected | length) == 0 then "\($it) selects no pod template of the render"
                else $selected[] | (select(.host) | "\($it) selects \(.workload), whose pods are on the host network"),
                  (select(.resolution | length > 0) | "\($it) selects \(.workload), whose pods resolve names by their own \(.resolution | join(", "))") end
            end,
            (endpoints($ns; $s.metadata.name) | select(length > 0)
              | "the render holds endpoints of the Service of the blackbox exporter, which lead where they say: \(join(", "))")]
       end
       # Prometheus resolves the name of the prober.
       + [$objects[] | select(.kind == "Prometheus" or .kind == "PrometheusAgent") | (.spec | resolution) as $own | select($own | length > 0)
           | "\(named) resolves names by its own \($own | join(", "))"]) as $exporterProblems
    | [$objects[] | select(.kind == "Gateway")] as $gateways
    | (if ($gateways | length) == 1 then $gateways[0] | "\(namespace)/\(.metadata.name)" else null end) as $gateway
    | ([$probing.gateways[] | select($gateway != null and .gateway == $gateway)][0] // null) as $named
    | {service: ($named.service // null), ports: ([$gateways[0].spec.listeners[]?.port] | unique)} as $proxies
    # What of the EnvoyProxy spec on input leaves the proxies other than the controller builds them:
    # a patch of their pods, or of their Service, which can make it any type, an ExternalName to
    # another name among them, a name of its own for the Service, or the Gateways merged, the
    # objects of whose proxies then take the name of their GatewayClass
    # (internal/gatewayapi/translator.go).
    | def rebuilds($who; $by): (.provider.kubernetes // {}) as $k
        | (select($k.envoyDeployment.patch != null or $k.envoyDaemonSet.patch != null)
            | "\($who) patches the pods of the proxies\($by), which can put them on the host network"),
          (select($k.envoyService.patch != null) | "\($who) patches the Service of the proxies\($by), which can lead its name elsewhere"),
          (select($k.envoyService.name != null)
            | "\($who) names the Service of the proxies\($by), which then has another name than the one derived"),
          (select(.mergeGateways == true) | "\($who) merges the Gateways\($by), whose proxies then take the name of their class");
    (if ($gateways | length) != 1 then
         ["the render holds \($gateways | length) Gateways, and a Probe may name the Service of the proxies of the one public Gateway alone"]
       elif $probing.controller.error != null then [$probing.controller.error]
       elif $named == null then ["no Service of the proxies of the Gateway \($gateway) was named"]
       elif $named.error != null then [$named.error]
       else [($objects[] | select(.kind == "EnvoyProxy") | "the EnvoyProxy \(namespace)/\(.metadata.name)" as $who | .spec // {} | rebuilds($who; "")),
             ($probing.controller.default | rebuilds("the configuration of the controller of Envoy Gateway"; " by default")),
             (($proxies.service | split(".")[0]) as $name
               | $objects[] | select(.kind == "Service" and namespace == $probing.controller.namespace and .metadata.name == $name)
               | "the render holds \(named) by the name of the Service of the proxies, which leads where it says and not to the proxies the controller makes"),
             ([$objects[] | select(.kind == "Namespace" and .metadata.name == $probing.controller.namespace)][0] // null
               | select((. // {} | .metadata.labels // {})["pod-security.kubernetes.io/enforce"] | IN("baseline", "restricted") | not)
               | "the namespace \($probing.controller.namespace), where the controller makes the proxies, does not enforce the Pod Security level baseline or restricted, which refuse pods on the host network"),
             (endpoints($probing.controller.namespace; $proxies.service | split(".")[0]) | select(length > 0)
               | "the render holds endpoints of the Service of the proxies, which lead where they say: \(join(", "))")]
       end) as $proxiesProblems
    # Whether a static target on input is the Service of the proxies on a port of the listeners.
    | def at_proxies: (capture("^(?<scheme>https?)://(?<host>[^/:?#]+)(?::(?<port>[0-9]+))?(?:[/?#].*)?$") // null)
        | . != null and .host == $proxies.service
          and ((if .port != null then .port | tonumber elif .scheme == "https" then 443 else 80 end) | IN($proxies.ports[]));
    [($objects[] | select(.kind == "Probe") | "\(named) is not in the one shape this check accepts: " as $refused
      | (((.spec | fields) - ["jobName", "module", "prober", "targets"] | select(length > 0)
          | $refused + "its spec holds \(join(", ")) beyond jobName, module, prober and targets"),
        ((.spec.prober | fields) - ["url"] | select(length > 0) | $refused + "its prober holds \(join(", ")) beyond url"),
        (select($prober != null and .spec.prober.url != $prober)
          | $refused + "its prober is \(.spec.prober.url), which is not the Service of the blackbox exporter, \($prober)"),
        (select(.spec.module | IN($modules[]) | not)
          | $refused + "its module is \(.spec.module), which is not one of those tests/probes.bats pins whole: \($modules | join(", "))"),
        ((.spec.targets | fields) - ["staticConfig"] | select(length > 0) | $refused + "its targets hold \(join(", ")) beyond staticConfig"),
        (.spec.targets.staticConfig as $static
          | if ($static.static | type) != "array" or ($static.static | length) == 0 then $refused + "it has no static target"
            else (($static | fields) - ["labels", "relabelingConfigs", "static"] | select(length > 0)
                   | $refused + "its static targets hold \(join(", ")) beyond static, labels and relabelingConfigs"),
                 (($static.labels | fields) - ["hostname"] | select(length > 0) | $refused + "its labels hold \(join(", ")) beyond hostname"),
                 (select($static.relabelingConfigs != $relabelings)
                   | $refused + "its relabelings are not the one of the tree, which makes the label hostname the parameter hostname"),
                 (select($proxies.service != null) | $static.static[] | select((type == "string" and at_proxies) | not)
                   | $refused + "it probes \(.), which is not the Service of the proxies of the public Gateway, \($proxies.service), over http or https on a port of its listeners, \($proxies.ports | map(tostring) | join(" or "))")
            end))),
     ($exporterProblems[] | select($probed) | "no prober of a Probe is accepted: \(.)"),
     ($proxiesProblems[] | select($probed) | "no target of a Probe is accepted: \(.)")] as $refusedProbes
    | ([($judged[] | select(.listed > 0) | .l as $l | .id as $id
         | $templates[] | select(.host and .ns == $l.ns and .workload == $l.workload) | . as $t
         # The names the template gives the port, by which a monitor or a Service may mean it.
         | ([$t.ports[] | select(.port == $l.port and .name != "") | .name] | unique) as $names
         | (($objects[] | select(.kind == "PodMonitor")
              | select((looks_in | holds($t.ns)) and ((.spec.selector // {}) | selects($t.labels)))
              | select(any(.spec.podMetricsEndpoints[]?; readdressed
                  or (if (.port // "") != "" then (.port as $port | any($names[]; . == $port))
                      elif (.portNumber // 0) != 0 then .portNumber == $l.port
                      elif target != 0 then (target as $port | $port == $l.port or any($names[]; . == $port))
                      else true end)))
              | "\(named) scrapes \($id), which has no rule"),
            ($objects[] | select(.kind == "ServiceMonitor") | . as $monitor
              | $objects[] | select(.kind == "Service") | . as $service
              | select(($monitor | looks_in | holds($service | namespace))
                  and (($monitor.spec.selector // {}) | selects($service.metadata.labels // {})))
              # The Service leads to the template when its selector selects the template in its namespace; one
              # without a selector leads where its endpoints say, which this does not read.
              | select((.spec.selector // {}) | length == 0
                  or (($service | namespace) == $t.ns and (to_entries | all(.key as $key | .value == $t.labels[$key]))))
              | select(any($monitor.spec.endpoints[]?; readdressed
                  or (if (.port // "") != "" then
                        (.port as $port | any($service.spec.ports[]? | select((.name // "") == $port) | (target as $to | if $to == 0 then .port else $to end);
                          . == $l.port or (. as $to | any($names[]; . == $to))))
                      elif target != 0 then (target as $port | $port == $l.port or any($names[]; . == $port))
                      else true end)))
              | "\($monitor | named) scrapes \($id), which has no rule, through \($service | named)"))),
        $refusedProbes[],
        ($objects[] | select(.kind == "ScrapeConfig")
          | "\(named): this reads PodMonitors, ServiceMonitors and Probes alone, and must learn to read a \(.kind) before the render holds one"),
        ($objects[] | select((.kind == "Prometheus" or .kind == "PrometheusAgent") and .spec.additionalScrapeConfigs != null)
          | "\(named) takes additional scrape configurations, which this does not read"),
        ($objects[] | select((.kind == "Prometheus" or .kind == "PrometheusAgent") and any(.spec.scrapeClasses[]?; (.relabelings // []) | length > 0))
          | "\(named) has a scrape class with relabelings, which run on the monitors and Probes it selects and which this does not read")]
       | unique) as $scraped
    | [$judged[] | select(.listed > 0) | "\(.id): no monitor"] as $unscraped

    | {malformed: $malformed, unplaced: $unplaced, unaccounted: $unaccounted, account: $account, unserved: $unserved,
       served: $served, hostPorts: $hostPorts, onHost: $onHost, scraped: $scraped, unscraped: $unscraped,
       read: {onHostNetwork: ([$templates[] | select(.host)] | length), onPodNetwork: ([$templates[] | select(.host | not)] | length),
              monitors: ([$objects[] | select(.kind == "PodMonitor" or .kind == "ServiceMonitor" or .kind == "Probe")] | length),
              probes: ([$objects[] | select(.kind == "Probe")] | length)}}'
}

# verdict PROBLEMS ACCOUNT RENDER INVENTORY EXCEPTIONS: the lines of the lists of evaluate's
# document that the jq expression PROBLEMS names, and status 1, when there are any; otherwise the
# lines of the jq expression ACCOUNT.
verdict() {
  local problems=$1 account=$2 found
  shift 2
  found=$(evaluate "$@") || { echo "$found"; return 2; }
  if jq -e "($problems) | length > 0" <<< "$found" > /dev/null; then
    jq -r "($problems)[]" <<< "$found"
    return 1
  fi
  jq -r "$account" <<< "$found"
}

# listeners RENDER INVENTORY EXCEPTIONS: the account of the listeners, a line each; or, with status
# 1, what is wrong with the exceptions file, with a namespace or with a listener's account.
listeners() {
  verdict '.malformed + .unplaced + .unaccounted' '.account[]' "$@"
}

# rules RENDER INVENTORY EXCEPTIONS: what serves each rule of the inventory, a line each; or, with
# status 1, what is wrong with the exceptions file, with a namespace, with a rule or with an entry.
rules() {
  verdict '.malformed + .unplaced + .unserved' '.served[]' "$@"
}

# host_ports RENDER INVENTORY EXCEPTIONS: how many pod templates off the host network it read, then
# a line for each host port a template on the host network declares; or, with status 1, each host
# port a template off the host network declares.
host_ports() {
  verdict '.unplaced + .hostPorts' '"\(.read.onPodNetwork) pod templates on the pod network, none with a host port", .onHost[]' "$@"
}

# monitors RENDER INVENTORY EXCEPTIONS: a line for each listener listed under no-rule; or, with
# status 1, what is wrong with the exceptions file or a namespace, and each monitor that scrapes
# such a listener and each scraper the check cannot read.
monitors() {
  verdict '.malformed + .unplaced + .scraped' '.unscraped[]' "$@"
}

# unnamed EXCEPTIONS PAGE: the ports listed under no-rule that the section "What gets no rule" of
# PAGE, docs/cluster.md or a copy, does not hold as a whole word, one per line.
unnamed() {
  local section port
  section=$(awk '$0 == "### What gets no rule" { inside = 1; next } /^#/ { inside = 0 } inside' "$2")
  for port in $(yq '.["no-rule"][].port' "$1" | sort -un); do
    grep -qwF -- "$port" <<< "$section" || echo "$port"
  done
}

# copy NAME: sets COPY to $BATS_TEST_TMPDIR/NAME, a copy for a test to change of what the checks
# read: the view of the render as render, the inventory as firewall.yaml and the exceptions file
# as exceptions.yaml.
copy() {
  COPY="$BATS_TEST_TMPDIR/$1"
  mkdir "$COPY"
  cp -R "$VIEW" "$COPY/render"
  cp "$INVENTORY" "$COPY/firewall.yaml"
  cp "$EXCEPTIONS" "$COPY/exceptions.yaml"
}

# object FILE: the path of the one file named FILE in the render of COPY.
object() {
  local files=("$COPY"/render/*/*/"$1")
  [ "${#files[@]}" -eq 1 ] && [ -f "${files[0]}" ] || { echo "$1 is not one file of $COPY: ${files[*]}"; return 1; }
  echo "${files[0]}"
}

# add FILE: adds the fixture object FILE to the render of COPY.
add() {
  mkdir -p "$COPY/render/fixture/added"
  cp "$FIXTURE/$1" "$COPY/render/fixture/added/"
}

# on_copy CHECK: runs CHECK, a check of this file, on COPY.
on_copy() {
  run "$1" "$COPY/render" "$COPY/firewall.yaml" "$COPY/exceptions.yaml"
  echo "$output"
}

@test "Every port a host-network pod declares is admitted by a rule for every node or listed with its reason" {
  run listeners "$RENDER" "$INVENTORY" "$EXCEPTIONS"
  echo "$output"
  [ "$status" -eq 0 ]
  # A chart that adds a port, and a rule that changes its nodes or its sources, change this account.
  account='kube-system DaemonSet/cilium tcp 4244: hubble, all, members,pods
kube-system DaemonSet/cilium tcp 9879: no-rule
kube-system DaemonSet/cilium tcp 9962: cilium-agent-metrics, all, members,pods
kube-system DaemonSet/cilium-envoy tcp 9964: no-rule
kube-system Deployment/cilium-operator tcp 9234: no-rule
kube-system Deployment/cilium-operator tcp 9963: no-rule
monitoring DaemonSet/kube-prometheus-stack-prometheus-node-exporter tcp 9100: node-exporter, all, members,pods'
  diff <(echo "$account") <(echo "$output")
  # The page names every port without a rule where it says what gets none.
  run unnamed "$EXCEPTIONS" "$DOCS"
  echo "ports without a rule that the page does not name: ${output:-none}"
  [ -z "$output" ]

  # The copy that the tests change says what the tree says.
  copy same
  on_copy listeners
  [ "$status" -eq 0 ]
  [ "$output" = "$account" ]

  # A port added to a template on the host network, by a container and by an init container, and
  # one of another protocol than the rule for its number.
  copy added
  yq -i '.spec.template.spec.containers[0].ports += [{"name": "pprof", "containerPort": 6060}]
    | .spec.template.spec.initContainers[0].ports = [{"containerPort": 6061, "protocol": "UDP"}]' "$(object DaemonSet.apps_kube-system_cilium.yaml)"
  yq -i '.spec.template.spec.containers[0].ports += [{"containerPort": 9100, "protocol": "UDP"}]' \
    "$(object DaemonSet.apps_monitoring_kube-prometheus-stack-prometheus-node-exporter.yaml)"
  on_copy listeners
  [ "$status" -eq 1 ]
  [ "$output" = 'kube-system DaemonSet/cilium tcp 6060: no rule of the inventory admits it and the exceptions file does not list it under no-rule
kube-system DaemonSet/cilium udp 6061: no rule of the inventory admits it and the exceptions file does not list it under no-rule
monitoring DaemonSet/kube-prometheus-stack-prometheus-node-exporter udp 9100: no rule of the inventory admits it and the exceptions file does not list it under no-rule' ]

  # A workload of each other kind that moves to the host network, with the ports it declares, on
  # ports no rule of the inventory admits.
  copy moved
  yq -i '.spec.template.spec.hostNetwork = true' "$(object Deployment.apps_kube-system_hubble-relay.yaml)"
  yq -i '.spec.template.spec.hostNetwork = true' "$(object StatefulSet.apps_openbao_openbao.yaml)"
  yq -i '.spec.jobTemplate.spec.template.spec.hostNetwork = true
    | .spec.jobTemplate.spec.template.spec.containers[0].ports = [{"containerPort": 8001}]' "$(object CronJob.batch_etcd-snapshots_etcd-snapshots.yaml)"
  yq -i '.spec.template.spec.hostNetwork = true
    | .spec.template.spec.containers[0].ports = [{"containerPort": 8002}]' "$(object Job.batch_cert-manager_cert-manager-startupapicheck.yaml)"
  yq -i '.spec.hostNetwork = true | .spec.containers[0].ports = [{"containerPort": 8003}]' "$(object Pod_kube-system_spegel-cleanup-wait.yaml)"
  on_copy listeners
  [ "$status" -eq 1 ]
  [ "$output" = 'cert-manager Job/cert-manager-startupapicheck tcp 8002: no rule of the inventory admits it and the exceptions file does not list it under no-rule
etcd-snapshots CronJob/etcd-snapshots tcp 8001: no rule of the inventory admits it and the exceptions file does not list it under no-rule
kube-system Deployment/hubble-relay tcp 4245: no rule of the inventory admits it and the exceptions file does not list it under no-rule
kube-system Pod/spegel-cleanup-wait tcp 8003: no rule of the inventory admits it and the exceptions file does not list it under no-rule
openbao StatefulSet/openbao tcp 8200: no rule of the inventory admits it and the exceptions file does not list it under no-rule
openbao StatefulSet/openbao tcp 8201: no rule of the inventory admits it and the exceptions file does not list it under no-rule
openbao StatefulSet/openbao tcp 8202: no rule of the inventory admits it and the exceptions file does not list it under no-rule' ]

  # An entry taken out of no-rule.
  copy unlisted
  yq -i 'del(.["no-rule"][] | select(.port == 9963))' "$COPY/exceptions.yaml"
  on_copy listeners
  [ "$status" -eq 1 ]
  [ "$output" = 'kube-system Deployment/cilium-operator tcp 9963: no rule of the inventory admits it and the exceptions file does not list it under no-rule' ]

  # An entry under no-rule for a port a rule admits, and one given twice.
  copy both
  yq -i '.["no-rule"] += [{"namespace": "kube-system", "workload": "DaemonSet/cilium", "protocol": "tcp", "port": 4244, "reason": "listed although a rule admits it"}]
    | .["no-rule"] += [.["no-rule"][] | select(.port == 9879)]' "$COPY/exceptions.yaml"
  on_copy listeners
  [ "$status" -eq 1 ]
  [ "$output" = 'kube-system DaemonSet/cilium tcp 4244: the rule hubble admits it and the exceptions file lists it under no-rule
kube-system DaemonSet/cilium tcp 9879: the exceptions file lists it 2 times under no-rule' ]

  # A rule only control planes have.
  copy controlplane
  yq -i '(.listeners[] | select(.name == "hubble") | .nodes) = "controlplane"' "$COPY/firewall.yaml"
  on_copy listeners
  [ "$status" -eq 1 ]
  [ "$output" = 'kube-system DaemonSet/cilium tcp 4244: the rule hubble admits it on controlplane nodes alone, which covers no pod of the render' ]

  # A second rule for a port, as a range around it.
  copy twice
  yq -i '.listeners += [{"name": "exporters", "protocol": "tcp", "ports": ["9100-9199"], "nodes": "all", "from": ["members"]}]' "$COPY/firewall.yaml"
  on_copy listeners
  [ "$status" -eq 1 ]
  [ "$output" = 'monitoring DaemonSet/kube-prometheus-stack-prometheus-node-exporter tcp 9100: 2 rules admit it: node-exporter, exporters' ]

  # A host port that is not the container port: on the host network Kubernetes gives a port the
  # host port of its own number, so a template that names another does not say which port it holds.
  copy other-port
  yq -i '(.spec.template.spec.containers[0].ports[] | select(.containerPort == 9100) | .hostPort) = 9101' \
    "$(object DaemonSet.apps_monitoring_kube-prometheus-stack-prometheus-node-exporter.yaml)"
  on_copy listeners
  [ "$status" -eq 1 ]
  [ "$output" = 'monitoring DaemonSet/kube-prometheus-stack-prometheus-node-exporter tcp 9100: its hostPort 9101 is not its containerPort, and on the host network the two are one port' ]

  # A workload of a chart that gives it no namespace is in the namespace its release installs into:
  # the release's own, or the one it targets. One that no release claims is in none.
  copy unplaced
  yq -i 'del(.metadata.namespace)' "$(object DaemonSet.apps_kube-system_cilium-envoy.yaml)"
  yq -i 'del(.spec.targetNamespace)' "$(object HelmRelease.helm.toolkit.fluxcd.io_kube-system_cilium.yaml)"
  on_copy listeners
  [ "$status" -eq 0 ]
  [ "$output" = "$account" ]
  yq -i '.spec.targetNamespace = "elsewhere"' "$(object HelmRelease.helm.toolkit.fluxcd.io_kube-system_cilium.yaml)"
  on_copy listeners
  [ "$status" -eq 1 ]
  [ "$output" = 'elsewhere DaemonSet/cilium-envoy tcp 9964: no rule of the inventory admits it and the exceptions file does not list it under no-rule' ]
  yq -i 'del(.metadata.labels["helm.toolkit.fluxcd.io/name"])' "$(object DaemonSet.apps_kube-system_cilium-envoy.yaml)"
  on_copy listeners
  [ "$status" -eq 1 ]
  [[ $output == 'DaemonSet/cilium-envoy has no namespace and no HelmRelease to take one from'* ]]

  # A port without a rule that the page no longer names where it says what gets none.
  awk '$0 == "### What gets no rule" { inside = 1 } /^### What the firewall does not see/ { inside = 0 }
    inside { gsub(/9234/, "") } { print }' "$DOCS" > "$BATS_TEST_TMPDIR/page.md"
  run cmp -s "$DOCS" "$BATS_TEST_TMPDIR/page.md"
  [ "$status" -eq 1 ]
  run unnamed "$EXCEPTIONS" "$BATS_TEST_TMPDIR/page.md"
  [ "$output" = 9234 ]
}

@test "Every rule of the node firewall has a listener, a port a host-network pod declares or a listed node service" {
  run rules "$RENDER" "$INVENTORY" "$EXCEPTIONS"
  echo "$output"
  [ "$status" -eq 0 ]
  # A rule for a listener no pod of the render declares, and a rule a chart's port comes to use,
  # change this account.
  served='apid: no-pod
trustd: no-pod
kube-apiserver: no-pod
etcd: no-pod
etcd-metrics: no-pod
kube-controller-manager: no-pod
kube-scheduler: no-pod
kubelet: no-pod
cilium-vxlan: no-pod
cilium-wireguard: no-pod
cilium-health: no-pod
hubble: kube-system DaemonSet/cilium tcp 4244
node-exporter: monitoring DaemonSet/kube-prometheus-stack-prometheus-node-exporter tcp 9100
cilium-agent-metrics: kube-system DaemonSet/cilium tcp 9962
linstor-satellite: no-pod
drbd: no-pod
drbd-reactor: no-pod'
  diff <(echo "$served") <(echo "$output")

  copy same
  on_copy rules
  [ "$status" -eq 0 ]
  [ "$output" = "$served" ]

  # A rule nothing uses, for one port and for a range.
  copy stale
  yq -i '.listeners += [{"name": "left-behind", "protocol": "tcp", "ports": [9999], "nodes": "all", "from": ["members"]},
    {"name": "left-range", "protocol": "udp", "ports": ["9100-9962"], "nodes": "all", "from": ["members"]}]' "$COPY/firewall.yaml"
  on_copy rules
  [ "$status" -eq 1 ]
  [ "$output" = 'the rule left-behind (tcp 9999): no host-network pod of the render declares a port it admits and the exceptions file does not name it under no-pod: a stale rule, or a listener to name there
the rule left-range (udp 9100-9962): no host-network pod of the render declares a port it admits and the exceptions file does not name it under no-pod: a stale rule, or a listener to name there' ]

  # An entry taken out of no-pod.
  copy unnamed
  yq -i 'del(.["no-pod"][] | select(.rule == "cilium-health"))' "$COPY/exceptions.yaml"
  on_copy rules
  [ "$status" -eq 1 ]
  [ "$output" = 'the rule cilium-health (tcp 4240): no host-network pod of the render declares a port it admits and the exceptions file does not name it under no-pod: a stale rule, or a listener to name there' ]

  # A rule whose pod leaves the host network, or no longer declares the port.
  copy left
  yq -i 'del(.spec.template.spec.hostNetwork)' "$(object DaemonSet.apps_monitoring_kube-prometheus-stack-prometheus-node-exporter.yaml)"
  yq -i 'del(.spec.template.spec.containers[0].ports[] | select(.containerPort == 4244))' "$(object DaemonSet.apps_kube-system_cilium.yaml)"
  on_copy rules
  [ "$status" -eq 1 ]
  [ "$output" = 'the rule hubble (tcp 4244): no host-network pod of the render declares a port it admits and the exceptions file does not name it under no-pod: a stale rule, or a listener to name there
the rule node-exporter (tcp 9100): no host-network pod of the render declares a port it admits and the exceptions file does not name it under no-pod: a stale rule, or a listener to name there' ]

  # An entry under no-pod for a rule a pod uses, one given twice, and one for a rule that is not there.
  copy used
  yq -i '.["no-pod"] += [{"rule": "hubble", "reason": "named although a pod declares its port"}, {"rule": "apid", "reason": "named twice"},
    {"rule": "gone", "reason": "a rule the inventory lost"}]' "$COPY/exceptions.yaml"
  on_copy rules
  [ "$status" -eq 1 ]
  [ "$output" = 'no-pod names the rule gone, which the inventory does not hold: an entry without use
the rule apid (tcp 50000): the exceptions file names it 2 times under no-pod
the rule hubble (tcp 4244): the exceptions file names it under no-pod, but it admits kube-system DaemonSet/cilium tcp 4244: an entry without use' ]

  # An entry under no-rule that no listener matches: another workload, protocol or port, or a pod
  # that is not on the host network.
  copy unmatched
  yq -i '.["no-rule"] += [{"namespace": "kube-system", "workload": "DaemonSet/gone", "protocol": "tcp", "port": 9879, "reason": "a workload the render lost"},
    {"namespace": "kube-system", "workload": "DaemonSet/cilium", "protocol": "udp", "port": 9879, "reason": "another protocol"},
    {"namespace": "kube-system", "workload": "DaemonSet/cilium", "protocol": "tcp", "port": 9880, "reason": "another port"},
    {"namespace": "monitoring", "workload": "DaemonSet/cilium", "protocol": "tcp", "port": 9879, "reason": "another namespace"},
    {"namespace": "kube-system", "workload": "DaemonSet/spegel", "protocol": "tcp", "port": 5000, "reason": "a pod on the pod network"}]' "$COPY/exceptions.yaml"
  on_copy rules
  [ "$status" -eq 1 ]
  [ "$output" = 'no-rule lists kube-system DaemonSet/cilium tcp 9880, which no host-network pod of the render declares: an entry without use
no-rule lists kube-system DaemonSet/cilium udp 9879, which no host-network pod of the render declares: an entry without use
no-rule lists kube-system DaemonSet/gone tcp 9879, which no host-network pod of the render declares: an entry without use
no-rule lists kube-system DaemonSet/spegel tcp 5000, which no host-network pod of the render declares: an entry without use
no-rule lists monitoring DaemonSet/cilium tcp 9879, which no host-network pod of the render declares: an entry without use' ]
}

@test "No pod on the pod network declares a host port" {
  run host_ports "$RENDER" "$INVENTORY" "$EXCEPTIONS"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ ${lines[0]} =~ ^([0-9]+)\ pod\ templates\ on\ the\ pod\ network,\ none\ with\ a\ host\ port$ ]]
  [ "${BASH_REMATCH[1]}" -gt 0 ]
  # The host ports the render does declare are all of pods on the host network, where the port is
  # the node's own: those of Cilium's agent, its Envoy and its operator. node-exporter, on the host
  # network as well, declares its port without one. A chart that changes either changes this
  # account, and what docs/cluster.md and docs/infrastructure.md say of host ports with it.
  declared='kube-system DaemonSet/cilium tcp 4244: a host port on the host network
kube-system DaemonSet/cilium tcp 9879: a host port on the host network
kube-system DaemonSet/cilium tcp 9962: a host port on the host network
kube-system DaemonSet/cilium-envoy tcp 9964: a host port on the host network
kube-system Deployment/cilium-operator tcp 9234: a host port on the host network
kube-system Deployment/cilium-operator tcp 9963: a host port on the host network'
  diff <(echo "$declared") <(tail -n +2 <<< "$output")
  on_the_tree=$output

  copy same
  on_copy host_ports
  [ "$status" -eq 0 ]
  [ "$output" = "$on_the_tree" ]

  # A host port on a template of each kind that is off the host network, by a container and by an
  # init container, and on one that says so itself. Those of the templates on the host network,
  # which the tree holds, are not among them.
  copy declared
  yq -i '(.spec.template.spec.containers[0].ports[] | select(.name == "registry") | .hostPort) = 5000
    | .spec.template.spec.hostNetwork = false
    | .spec.template.spec.initContainers = [{"name": "first", "ports": [{"containerPort": 81, "hostPort": 8081, "protocol": "UDP"}]}]' \
    "$(object DaemonSet.apps_kube-system_spegel.yaml)"
  yq -i '(.spec.template.spec.containers[0].ports[] | select(.name == "grpc") | .hostPort) = 4245' "$(object Deployment.apps_kube-system_hubble-relay.yaml)"
  yq -i '(.spec.template.spec.containers[0].ports[] | select(.name == "https") | .hostPort) = 8200' "$(object StatefulSet.apps_openbao_openbao.yaml)"
  yq -i '.spec.jobTemplate.spec.template.spec.containers[0].ports = [{"containerPort": 7001, "hostPort": 7001}]' "$(object CronJob.batch_etcd-snapshots_etcd-snapshots.yaml)"
  yq -i '.spec.template.spec.containers[0].ports = [{"containerPort": 7002, "hostPort": 7002}]' "$(object Job.batch_cert-manager_cert-manager-startupapicheck.yaml)"
  yq -i '.spec.containers[0].ports = [{"containerPort": 7003, "hostPort": 7003}]' "$(object Pod_kube-system_spegel-cleanup-wait.yaml)"
  on_copy host_ports
  [ "$status" -eq 1 ]
  [ "$output" = 'cert-manager Job/cert-manager-startupapicheck tcp 7002: a pod on the pod network declares the host port 7002, which Cilium serves before the node firewall sees the packet
etcd-snapshots CronJob/etcd-snapshots tcp 7001: a pod on the pod network declares the host port 7001, which Cilium serves before the node firewall sees the packet
kube-system DaemonSet/spegel tcp 5000: a pod on the pod network declares the host port 5000, which Cilium serves before the node firewall sees the packet
kube-system DaemonSet/spegel udp 81: a pod on the pod network declares the host port 8081, which Cilium serves before the node firewall sees the packet
kube-system Deployment/hubble-relay tcp 4245: a pod on the pod network declares the host port 4245, which Cilium serves before the node firewall sees the packet
kube-system Pod/spegel-cleanup-wait tcp 7003: a pod on the pod network declares the host port 7003, which Cilium serves before the node firewall sees the packet
openbao StatefulSet/openbao tcp 8200: a pod on the pod network declares the host port 8200, which Cilium serves before the node firewall sees the packet' ]

  # A pod that leaves the host network with the host ports it declared there.
  copy left
  yq -i 'del(.spec.template.spec.hostNetwork)' "$(object DaemonSet.apps_kube-system_cilium-envoy.yaml)"
  on_copy host_ports
  [ "$status" -eq 1 ]
  [ "$output" = 'kube-system DaemonSet/cilium-envoy tcp 9964: a pod on the pod network declares the host port 9964, which Cilium serves before the node firewall sees the packet' ]

  # A host port that a pod on the host network comes to declare is no refusal, and is in the account.
  copy on-host
  yq -i '(.spec.template.spec.containers[0].ports[] | select(.containerPort == 9100) | .hostPort) = 9100' \
    "$(object DaemonSet.apps_monitoring_kube-prometheus-stack-prometheus-node-exporter.yaml)"
  on_copy host_ports
  [ "$status" -eq 0 ]
  [ "$(tail -n +2 <<< "$output")" = "$declared"$'\n''monitoring DaemonSet/kube-prometheus-stack-prometheus-node-exporter tcp 9100: a host port on the host network' ]
}

@test "No monitor scrapes a port that has no rule" {
  run monitors "$RENDER" "$INVENTORY" "$EXCEPTIONS"
  echo "$output"
  [ "$status" -eq 0 ]
  unscraped='kube-system DaemonSet/cilium tcp 9879: no monitor
kube-system DaemonSet/cilium-envoy tcp 9964: no monitor
kube-system Deployment/cilium-operator tcp 9234: no monitor
kube-system Deployment/cilium-operator tcp 9963: no monitor'
  diff <(echo "$unscraped") <(echo "$output")

  copy same
  on_copy monitors
  [ "$status" -eq 0 ]
  [ "$output" = "$unscraped" ]

  # The tree's own monitors are found where they scrape: the agents' PodMonitor by the name of
  # their metrics port, and node-exporter's ServiceMonitor through its Service, once the two
  # ports are listed as having no rule.
  copy scraped
  yq -i '.["no-rule"] += [{"namespace": "kube-system", "workload": "DaemonSet/cilium", "protocol": "tcp", "port": 9962, "reason": "listed to see its monitor found"},
    {"namespace": "monitoring", "workload": "DaemonSet/kube-prometheus-stack-prometheus-node-exporter", "protocol": "tcp", "port": 9100, "reason": "listed to see its monitor found"}]' \
    "$COPY/exceptions.yaml"
  run monitors "$RENDER" "$INVENTORY" "$COPY/exceptions.yaml"
  echo "$output"
  [ "$status" -eq 1 ]
  [ "$output" = 'PodMonitor kube-system/cilium-agent scrapes kube-system DaemonSet/cilium tcp 9962, which has no rule
ServiceMonitor monitoring/kube-prometheus-stack-prometheus-node-exporter scrapes monitoring DaemonSet/kube-prometheus-stack-prometheus-node-exporter tcp 9100, which has no rule, through Service monitoring/kube-prometheus-stack-prometheus-node-exporter' ]

  # The monitors the Cilium chart renders once they are turned on, with the Service of the
  # operator's that comes with its monitor; Envoy's Service is in the tree already.
  copy chart
  add cilium-operator-monitor.yaml
  add cilium-envoy-monitor.yaml
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = 'ServiceMonitor kube-system/cilium-envoy scrapes kube-system DaemonSet/cilium-envoy tcp 9964, which has no rule, through Service kube-system/cilium-envoy
ServiceMonitor kube-system/cilium-operator scrapes kube-system Deployment/cilium-operator tcp 9963, which has no rule, through Service kube-system/cilium-operator' ]

  # PodMonitors that reach such a port: by its name, by its number, by the deprecated target port
  # as a name and as a number, with no port at all or a target port that names none, which is
  # every port of the pod, from its own namespace where it names none, from another that it names
  # or from any, by expressions, by one of an operator the test does not know, and by rewriting the
  # address it scrapes: by name, by a labelmap, or by a target label built from the regex's groups.
  copy pods
  add podmonitors-scraping.yaml
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = 'PodMonitor kube-system/by-name scrapes kube-system Deployment/cilium-operator tcp 9963, which has no rule
PodMonitor kube-system/by-number scrapes kube-system DaemonSet/cilium-envoy tcp 9964, which has no rule
PodMonitor kube-system/by-target-name scrapes kube-system DaemonSet/cilium tcp 9879, which has no rule
PodMonitor kube-system/by-target-number scrapes kube-system Deployment/cilium-operator tcp 9234, which has no rule
PodMonitor kube-system/every-port scrapes kube-system Deployment/cilium-operator tcp 9234, which has no rule
PodMonitor kube-system/every-port scrapes kube-system Deployment/cilium-operator tcp 9963, which has no rule
PodMonitor kube-system/from-its-own-namespace scrapes kube-system DaemonSet/cilium-envoy tcp 9964, which has no rule
PodMonitor kube-system/labelmapped scrapes kube-system DaemonSet/cilium tcp 9879, which has no rule
PodMonitor kube-system/readdressed scrapes kube-system DaemonSet/cilium tcp 9879, which has no rule
PodMonitor kube-system/target-empty scrapes kube-system DaemonSet/cilium tcp 9879, which has no rule
PodMonitor kube-system/target-zero scrapes kube-system DaemonSet/cilium-envoy tcp 9964, which has no rule
PodMonitor kube-system/templated scrapes kube-system DaemonSet/cilium tcp 9879, which has no rule
PodMonitor kube-system/unknown-operator scrapes kube-system DaemonSet/cilium-envoy tcp 9964, which has no rule
PodMonitor monitoring/by-expressions scrapes kube-system DaemonSet/cilium-envoy tcp 9964, which has no rule
PodMonitor monitoring/from-a-named-namespace scrapes kube-system DaemonSet/cilium-envoy tcp 9964, which has no rule
PodMonitor monitoring/from-any-namespace scrapes kube-system DaemonSet/cilium-envoy tcp 9964, which has no rule' ]

  # PodMonitors that reach none: another namespace, its own or one it names, a label or a value
  # the pods lack, an expression of each operator that leaves the pods out, ports of the pods that
  # have a rule, ports the pods lack, and no endpoint.
  copy pods-elsewhere
  add podmonitors-not-scraping.yaml
  on_copy monitors
  [ "$status" -eq 0 ]
  [ "$output" = "$unscraped" ]

  # ServiceMonitors that reach such a port: through a Service port whose target is the port's name
  # or its number, or that names no target, by none or by an empty one, and has its number, by the
  # deprecated target port as a name and as a number, with no port at all or a target port that
  # names none, by rewriting the address, by name, by a labelmap or by a target label built from the
  # regex's groups, and through a Service without a selector, which leads where its endpoints say.
  copy services
  add servicemonitors-scraping.yaml
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = 'ServiceMonitor kube-system/by-empty-target scrapes kube-system Deployment/cilium-operator tcp 9963, which has no rule, through Service kube-system/operator-by-empty-target
ServiceMonitor kube-system/by-port-number scrapes kube-system Deployment/cilium-operator tcp 9963, which has no rule, through Service kube-system/operator-by-port-number
ServiceMonitor kube-system/by-target-name scrapes kube-system Deployment/cilium-operator tcp 9234, which has no rule, through Service kube-system/operator-by-target-name
ServiceMonitor kube-system/by-target-number scrapes kube-system Deployment/cilium-operator tcp 9234, which has no rule, through Service kube-system/operator-other-port
ServiceMonitor kube-system/by-target-port scrapes kube-system Deployment/cilium-operator tcp 9963, which has no rule, through Service kube-system/operator-other-port
ServiceMonitor kube-system/every-port scrapes kube-system Deployment/cilium-operator tcp 9234, which has no rule, through Service kube-system/operator-other-port
ServiceMonitor kube-system/every-port scrapes kube-system Deployment/cilium-operator tcp 9963, which has no rule, through Service kube-system/operator-other-port
ServiceMonitor kube-system/labelmapped scrapes kube-system Deployment/cilium-operator tcp 9234, which has no rule, through Service kube-system/operator-other-port
ServiceMonitor kube-system/labelmapped scrapes kube-system Deployment/cilium-operator tcp 9963, which has no rule, through Service kube-system/operator-other-port
ServiceMonitor kube-system/readdressed scrapes kube-system Deployment/cilium-operator tcp 9234, which has no rule, through Service kube-system/operator-other-port
ServiceMonitor kube-system/readdressed scrapes kube-system Deployment/cilium-operator tcp 9963, which has no rule, through Service kube-system/operator-other-port
ServiceMonitor kube-system/target-zero scrapes kube-system Deployment/cilium-operator tcp 9234, which has no rule, through Service kube-system/operator-other-port
ServiceMonitor kube-system/target-zero scrapes kube-system Deployment/cilium-operator tcp 9963, which has no rule, through Service kube-system/operator-other-port
ServiceMonitor kube-system/templated scrapes kube-system Deployment/cilium-operator tcp 9234, which has no rule, through Service kube-system/operator-other-port
ServiceMonitor kube-system/templated scrapes kube-system Deployment/cilium-operator tcp 9963, which has no rule, through Service kube-system/operator-other-port
ServiceMonitor kube-system/through-target-number scrapes kube-system Deployment/cilium-operator tcp 9963, which has no rule, through Service kube-system/operator-by-target-number
ServiceMonitor monitoring/without-selector scrapes kube-system DaemonSet/cilium-envoy tcp 9964, which has no rule, through Service monitoring/without-selector' ]

  # ServiceMonitors that reach none: a Service that selects other pods, one in another namespace
  # than the pods its selector names, one that asks for a label the pods lack, ports that have a
  # rule, another port of a Service than the one that leads to such a port, a Service no monitor
  # selects, and a Service without a selector on another port.
  copy services-elsewhere
  add servicemonitors-not-scraping.yaml
  on_copy monitors
  [ "$status" -eq 0 ]
  [ "$output" = "$unscraped" ]

  # A Probe is accepted in the one shape the tree's Probes have, and every other is refused, saying
  # so. Prometheus scrapes a Probe's prober and the exporter there connects to each of its targets,
  # and the check does not follow where a name leads: a Service that a controller makes at run time,
  # the kubelet's among them, a headless Service, whose name is its pods' own addresses, the nodes'
  # for pods on the host network, a Service without a selector or an ExternalName, which lead where
  # endpoints or another name say. In the shape, the prober is the blackbox exporter's Service, by
  # the name and port the render gives it, and every target the public Gateway's proxies' Service,
  # by the name tests/probes.bats derives, over http or https on a port of the Gateway's listeners;
  # the spec, the prober and the targets hold nothing more, the labels the hostname alone, the module
  # is one tests/probes.bats pins whole and the relabelings are the tree's one
  # (tests/fixtures/probe-shape.bash). The tree's Probes are in it, and the check refuses none of
  # them, as the account of the tree above shows; that it read every one is shown below.

  # Probes in that shape beside the tree's: the ports each scheme implies, the listeners' ports
  # named, two targets, and another of the modules.
  copy probes-accepted
  add probes-accepted.yaml
  on_copy monitors
  [ "$status" -eq 0 ]
  [ "$output" = "$unscraped" ]

  # Probes that leave it, each in one way, many of them ways to a port that has no rule.
  local shape="is not in the one shape this check accepts" exporter="blackbox-exporter.monitoring.svc.cluster.local:9115"
  local proxies="which is not the Service of the proxies of the public Gateway, envoy-envoy-gateway-system-public-5ea56ca9.envoy-gateway-system.svc.cluster.local, over http or https on a port of its listeners, 80 or 443"
  local relabelings="its relabelings are not the one of the tree, which makes the label hostname the parameter hostname"
  copy probes-refused
  add probes-refused.yaml
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "Probe monitoring/external-name $shape: it probes https://rev-external.kube-system.svc:9963/, $proxies
Probe monitoring/from-ingresses $shape: it has no static target
Probe monitoring/from-ingresses $shape: its targets hold ingress beyond staticConfig
Probe monitoring/headless-host-network $shape: it probes http://cilium-envoy.kube-system.svc.cluster.local:9963/, $proxies
Probe monitoring/headless-static-pods $shape: its prober is kube-prometheus-stack-kube-scheduler.kube-system.svc:9964, which is not the Service of the blackbox exporter, $exporter
Probe monitoring/kubelet-prober $shape: its prober is kube-prometheus-stack-kubelet.kube-system.svc:9879, which is not the Service of the blackbox exporter, $exporter
Probe monitoring/kubelet-target $shape: it probes http://kube-prometheus-stack-kubelet.kube-system.svc.cluster.local:9963/metrics, $proxies
Probe monitoring/labelmapped $shape: $relabelings
Probe monitoring/not-the-exporter $shape: its prober is prober.example:9115, which is not the Service of the blackbox exporter, $exporter
Probe monitoring/other-module $shape: its module is tcp_connect, which is not one of those tests/probes.bats pins whole: public_http_redirect, public_https, public_https_signin
Probe monitoring/other-namespace $shape: it probes https://envoy-envoy-gateway-system-public-5ea56ca9.monitoring.svc.cluster.local/, $proxies
Probe monitoring/other-port $shape: it probes https://envoy-envoy-gateway-system-public-5ea56ca9.envoy-gateway-system.svc.cluster.local:9964/, $proxies
Probe monitoring/prober-proxy $shape: its prober holds proxyUrl beyond url
Probe monitoring/prober-scheme $shape: its prober holds scheme beyond url
Probe monitoring/readdressed $shape: $relabelings
Probe monitoring/retargeted $shape: $relabelings
Probe monitoring/scrape-class $shape: its spec holds scrapeClass beyond jobName, module, prober and targets
Probe monitoring/second-label $shape: its labels hold __scheme__ beyond hostname
Probe monitoring/second-target $shape: it probes http://node.example:9963/, $proxies
Probe monitoring/static-and-ingresses $shape: its targets hold ingress beyond staticConfig
Probe monitoring/templated $shape: $relabelings
Probe monitoring/without-scheme $shape: it probes envoy-envoy-gateway-system-public-5ea56ca9.envoy-gateway-system.svc.cluster.local:443, $proxies
Probe monitoring/without-selector $shape: it probes http://without-selector.kube-system.svc:9963/, $proxies" ]

  # The shape holds only while the render says the two Services lead to pods on the pod network. The
  # exporter's pods are in the render: its Service of a type that leads elsewhere, an ExternalName
  # to another name among them, selecting no pod template of the render, or the exporter's on the
  # host network, refuses every Probe's prober, as do the exporter's pods or the Prometheus that
  # scrapes it resolving names their own way, and no Service of the exporter's release to name. A
  # selector of two keys selects a template that carries both, and not the node exporter's, on the
  # host network, which carries one.
  copy exporter-external-name
  yq -i '.spec.type = "ExternalName" | .spec.externalName = "node.example"' "$(object Service_monitoring_blackbox-exporter.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no prober of a Probe is accepted: the Service of the blackbox exporter, monitoring/blackbox-exporter, is of the type ExternalName" ]
  copy exporter-two-keys
  yq -i '.spec.selector = {"app.kubernetes.io/instance": "blackbox-exporter", "app.kubernetes.io/managed-by": "Helm"}' "$(object Service_monitoring_blackbox-exporter.yaml)"
  on_copy monitors
  [ "$status" -eq 0 ]
  [ "$output" = "$unscraped" ]
  copy exporter-resolving
  yq -i '.spec.template.spec.hostAliases = [{"ip": "192.0.2.10", "hostnames": ["envoy-envoy-gateway-system-public-5ea56ca9.envoy-gateway-system.svc.cluster.local"]}]
    | .spec.template.spec.dnsPolicy = "None" | .spec.template.spec.dnsConfig = {"nameservers": ["192.0.2.10"]}' \
    "$(object Deployment.apps_monitoring_blackbox-exporter.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no prober of a Probe is accepted: the Service of the blackbox exporter, monitoring/blackbox-exporter, selects Deployment/blackbox-exporter, whose pods resolve names by their own hostAliases, dnsConfig, dnsPolicy None" ]
  copy prometheus-resolving
  yq -i '.spec.hostAliases = [{"ip": "192.0.2.10", "hostnames": ["blackbox-exporter.monitoring.svc.cluster.local"]}]
    | .spec.dnsPolicy = "None" | .spec.dnsConfig = {"nameservers": ["192.0.2.10"]}' \
    "$(object Prometheus.monitoring.coreos.com_monitoring_kube-prometheus-stack-prometheus.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no prober of a Probe is accepted: Prometheus monitoring/kube-prometheus-stack-prometheus resolves names by its own hostAliases, dnsConfig, dnsPolicy None" ]
  copy exporter-unselected
  yq -i '.spec.selector = {"app.kubernetes.io/name": "elsewhere"}' "$(object Service_monitoring_blackbox-exporter.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no prober of a Probe is accepted: the Service of the blackbox exporter, monitoring/blackbox-exporter, selects no pod template of the render" ]
  copy exporter-on-host
  yq -i '.spec.template.spec.hostNetwork = true' "$(object Deployment.apps_monitoring_blackbox-exporter.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no prober of a Probe is accepted: the Service of the blackbox exporter, monitoring/blackbox-exporter, selects Deployment/blackbox-exporter, whose pods are on the host network" ]
  copy exporter-gone
  rm "$(object Service_monitoring_blackbox-exporter.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [[ $output == "no prober of a Probe is accepted: not one Service of the release blackbox-exporter in "* ]]
  # The proxies' pods are not: Envoy Gateway makes them at run time, and at the version
  # tests/probes.bats holds its controller to builds their pods without the host network, which only
  # a patch changes, in the controller's namespace, where Pod Security refuses the host network
  # below the privileged level. Nor is their Service, which the controller makes by the name
  # tests/probes.bats derives unless an EnvoyProxy names it otherwise, patches it, into an
  # ExternalName among others, or merges the Gateways, whose proxies then take their class's name.
  # An EnvoyProxy with such a patch, a name or the merge, the default EnvoyProxy of the controller's
  # configuration with one, a Service of that name in the render, which leads where it says, the
  # namespace at the privileged level or not in the render, the controller deploying the proxies in
  # each Gateway's namespace, for which the name's rule was not read, and a second Gateway refuse
  # every Probe's target.
  copy proxies-patched
  yq -i '.spec.provider.kubernetes.envoyDeployment.patch = {"type": "StrategicMerge", "value": {"spec": {"template": {"spec": {"hostNetwork": true}}}}}' \
    "$(object EnvoyProxy.gateway.envoyproxy.io_envoy-gateway-system_public.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no target of a Probe is accepted: the EnvoyProxy envoy-gateway-system/public patches the pods of the proxies, which can put them on the host network" ]
  copy controller-patched
  yq -i '.data["envoy-gateway.yaml"] |= (from_yaml | .envoyProxy = {"provider": {"type": "Kubernetes", "kubernetes": {"envoyDaemonSet":
    {"patch": {"type": "StrategicMerge", "value": {"spec": {"template": {"spec": {"hostNetwork": true}}}}}}}}} | to_yaml)' \
    "$(object ConfigMap_envoy-gateway-system_envoy-gateway-config.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no target of a Probe is accepted: the configuration of the controller of Envoy Gateway patches the pods of the proxies by default, which can put them on the host network" ]
  local elsewhere='{"type": "StrategicMerge", "value": {"spec": {"type": "ExternalName", "externalName": "node.example"}}}'
  copy service-patched
  yq -i ".spec.provider.kubernetes.envoyService.patch = $elsewhere" "$(object EnvoyProxy.gateway.envoyproxy.io_envoy-gateway-system_public.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no target of a Probe is accepted: the EnvoyProxy envoy-gateway-system/public patches the Service of the proxies, which can lead its name elsewhere" ]
  copy service-named
  yq -i '.spec.provider.kubernetes.envoyService.name = "public-proxies"' "$(object EnvoyProxy.gateway.envoyproxy.io_envoy-gateway-system_public.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no target of a Probe is accepted: the EnvoyProxy envoy-gateway-system/public names the Service of the proxies, which then has another name than the one derived" ]
  copy gateways-merged
  yq -i '.spec.mergeGateways = true' "$(object EnvoyProxy.gateway.envoyproxy.io_envoy-gateway-system_public.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no target of a Probe is accepted: the EnvoyProxy envoy-gateway-system/public merges the Gateways, whose proxies then take the name of their class" ]
  copy controller-service-patched
  yq -i ".data[\"envoy-gateway.yaml\"] |= (from_yaml | .envoyProxy = {\"provider\": {\"type\": \"Kubernetes\", \"kubernetes\": {\"envoyService\": {\"patch\": $elsewhere}}}} | to_yaml)" \
    "$(object ConfigMap_envoy-gateway-system_envoy-gateway-config.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no target of a Probe is accepted: the configuration of the controller of Envoy Gateway patches the Service of the proxies by default, which can lead its name elsewhere" ]
  copy controller-service-named
  yq -i '.data["envoy-gateway.yaml"] |= (from_yaml | .envoyProxy = {"provider": {"type": "Kubernetes", "kubernetes": {"envoyService": {"name": "public-proxies"}}}} | to_yaml)' \
    "$(object ConfigMap_envoy-gateway-system_envoy-gateway-config.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no target of a Probe is accepted: the configuration of the controller of Envoy Gateway names the Service of the proxies by default, which then has another name than the one derived" ]
  copy controller-merged
  yq -i '.data["envoy-gateway.yaml"] |= (from_yaml | .envoyProxy = {"mergeGateways": true} | to_yaml)' \
    "$(object ConfigMap_envoy-gateway-system_envoy-gateway-config.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no target of a Probe is accepted: the configuration of the controller of Envoy Gateway merges the Gateways by default, whose proxies then take the name of their class" ]
  copy service-held
  yq -n '{"apiVersion": "v1", "kind": "Service", "metadata": {"name": "envoy-envoy-gateway-system-public-5ea56ca9", "namespace": "envoy-gateway-system"},
    "spec": {"type": "ExternalName", "externalName": "node.example"}}' \
    > "$COPY/render/lab-sto2/envoy-gateway/Service_envoy-gateway-system_envoy-envoy-gateway-system-public-5ea56ca9.yaml"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no target of a Probe is accepted: the render holds Service envoy-gateway-system/envoy-envoy-gateway-system-public-5ea56ca9 by the name of the Service of the proxies, which leads where it says and not to the proxies the controller makes" ]
  copy proxies-privileged
  yq -i '.metadata.labels["pod-security.kubernetes.io/enforce"] = "privileged"' "$(object Namespace__envoy-gateway-system.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no target of a Probe is accepted: the namespace envoy-gateway-system, where the controller makes the proxies, does not enforce the Pod Security level baseline or restricted, which refuse pods on the host network" ]
  copy proxies-namespace-gone
  rm "$(object Namespace__envoy-gateway-system.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no target of a Probe is accepted: the namespace envoy-gateway-system, where the controller makes the proxies, does not enforce the Pod Security level baseline or restricted, which refuse pods on the host network" ]
  copy proxies-elsewhere
  yq -i '.data["envoy-gateway.yaml"] |= (from_yaml | .provider.kubernetes.deploy.type = "GatewayNamespace" | to_yaml)' \
    "$(object ConfigMap_envoy-gateway-system_envoy-gateway-config.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [[ $output == "no target of a Probe is accepted: Envoy Gateway's controller in "*" deploys the proxies in the mode GatewayNamespace, for which the rule for their Service's name was not read" ]]
  copy two-gateways
  yq '.metadata.name = "second"' "$(object Gateway.gateway.networking.k8s.io_envoy-gateway-system_public.yaml)" > "$COPY/render/lab-sto2/gateway-public/Gateway.gateway.networking.k8s.io_envoy-gateway-system_second.yaml"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no target of a Probe is accepted: the render holds 2 Gateways, and a Probe may name the Service of the proxies of the one public Gateway alone" ]
  # Endpoints written by hand for either Service lead where they say, beside the pods.
  copy endpoints
  add probes-endpoints.yaml
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = "no prober of a Probe is accepted: the render holds endpoints of the Service of the blackbox exporter, which lead where they say: EndpointSlice monitoring/blackbox-exporter-by-hand
no target of a Probe is accepted: the render holds endpoints of the Service of the proxies, which lead where they say: Endpoints envoy-gateway-system/envoy-envoy-gateway-system-public-5ea56ca9" ]
  # The check read every Probe of the tree, and refused none.
  copy probes-of-the-tree
  [ "$(find "$RENDER" -name 'Probe.monitoring.coreos.com_*.yaml' | wc -l)" -gt 0 ]
  [ "$(evaluate "$COPY/render" "$COPY/firewall.yaml" "$COPY/exceptions.yaml" | jq '.read.probes')" -eq "$(find "$RENDER" -name 'Probe.monitoring.coreos.com_*.yaml' | wc -l)" ]

  # A scraper of a kind the check does not read, and a Prometheus with scrape configurations of
  # its own and with a scrape class whose relabelings run on every monitor and Probe it selects.
  copy unread
  add scrapeconfig.yaml
  yq -i '.spec.additionalScrapeConfigs = {"name": "scrapes", "key": "scrapes.yaml"}
    | .spec.scrapeClasses = [{"name": "nodes", "default": true, "relabelings": [{"targetLabel": "__address__", "replacement": "node.example:9963"}]}]' \
    "$(object Prometheus.monitoring.coreos.com_monitoring_kube-prometheus-stack-prometheus.yaml)"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = 'Prometheus monitoring/kube-prometheus-stack-prometheus has a scrape class with relabelings, which run on the monitors and Probes it selects and which this does not read
Prometheus monitoring/kube-prometheus-stack-prometheus takes additional scrape configurations, which this does not read
ScrapeConfig monitoring/node-ports: this reads PodMonitors, ServiceMonitors and Probes alone, and must learn to read a ScrapeConfig before the render holds one' ]

  # A monitor of a chart that gives it no namespace is in its release's, and without a release it
  # is in none the check can name: a PodMonitor, and a Probe of the tree's.
  copy unplaced
  add podmonitors-scraping.yaml
  yq -i 'select(.metadata.name == "by-number") | del(.metadata.namespace)
    | .metadata.labels = {"helm.toolkit.fluxcd.io/name": "cilium", "helm.toolkit.fluxcd.io/namespace": "kube-system"}' \
    "$COPY/render/fixture/added/podmonitors-scraping.yaml"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = 'PodMonitor kube-system/by-number scrapes kube-system DaemonSet/cilium-envoy tcp 9964, which has no rule' ]
  yq -i 'del(.metadata.labels)' "$COPY/render/fixture/added/podmonitors-scraping.yaml"
  yq 'del(.metadata.namespace) | del(.metadata.labels)' "$(object Probe.monitoring.coreos.com_demo_hello.yaml)" > "$COPY/render/fixture/added/probe-unplaced.yaml"
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = 'PodMonitor/by-number has no namespace and no HelmRelease to take one from
Probe/hello has no namespace and no HelmRelease to take one from' ]
}

@test "the copy of the render that the tests change holds everything the checks read" {
  [ "$(evaluate "$VIEW" "$INVENTORY" "$EXCEPTIONS")" = "$(evaluate "$RENDER" "$INVENTORY" "$EXCEPTIONS")" ]
  run jq -r '.read | "\(.onHostNetwork) pod templates on the host network, \(.monitors > 0)"' <(evaluate "$RENDER" "$INVENTORY" "$EXCEPTIONS")
  echo "$output"
  [ "$output" = "4 pod templates on the host network, true" ]
}

@test "an exceptions file that is not there, or an entry of it with a missing or unknown key or an empty reason, fails every check that reads it" {
  # Not there: every port without a rule and every rule without a pod is then unaccounted for.
  copy missing
  rm "$COPY/exceptions.yaml"
  on_copy listeners
  [ "$status" -eq 1 ]
  [ "$output" = 'the exceptions file does not exist
kube-system DaemonSet/cilium tcp 9879: no rule of the inventory admits it and the exceptions file does not list it under no-rule
kube-system DaemonSet/cilium-envoy tcp 9964: no rule of the inventory admits it and the exceptions file does not list it under no-rule
kube-system Deployment/cilium-operator tcp 9234: no rule of the inventory admits it and the exceptions file does not list it under no-rule
kube-system Deployment/cilium-operator tcp 9963: no rule of the inventory admits it and the exceptions file does not list it under no-rule' ]
  on_copy rules
  [ "$status" -eq 1 ]
  [ "$(grep -c 'a stale rule, or a listener to name there$' <<< "$output")" -eq 14 ]
  on_copy monitors
  [ "$status" -eq 1 ]
  [ "$output" = 'the exceptions file does not exist' ]

  # Each malformed file fails the three checks that read it with the same line.
  malformed() {
    local check
    for check in listeners rules monitors; do
      on_copy "$check"
      [ "$status" -eq 1 ]
      [[ $output == "$1"* ]] || return 1
    done
  }
  copy missing-key
  yq -i 'del(.["no-rule"][0].protocol) | del(.["no-pod"][1].rule)' "$COPY/exceptions.yaml"
  malformed 'no-rule entry 1 has no protocol
no-pod entry 2 has no rule'
  copy no-reason
  yq -i 'del(.["no-rule"][2].reason) | del(.["no-pod"][0].reason)' "$COPY/exceptions.yaml"
  malformed 'no-rule entry 3 has no reason
no-pod entry 1 has no reason'
  copy empty-reason
  yq -i '.["no-rule"][1].reason = "" | .["no-pod"][2].reason = "  " | .["no-pod"][3].reason = null' "$COPY/exceptions.yaml"
  malformed 'no-rule entry 2 has an empty reason
no-pod entry 3 has an empty reason
no-pod entry 4 has an empty reason'
  copy unknown-key
  yq -i '.["no-rule"][0].level = "privileged" | .["no-pod"][0].port = 50000 | .["no-listener"] = []' "$COPY/exceptions.yaml"
  malformed 'the exceptions file has the unknown key no-listener
no-rule entry 1 has the unknown key level
no-pod entry 1 has the unknown key port'
  copy no-list
  yq -i 'del(.["no-pod"])' "$COPY/exceptions.yaml"
  malformed 'the exceptions file has no list no-pod'
  copy not-a-list
  yq -i '.["no-rule"] = {"port": 9879}' "$COPY/exceptions.yaml"
  malformed 'the exceptions file has no list no-rule'
  copy not-a-map
  yq -i '.["no-pod"] += ["apid"]' "$COPY/exceptions.yaml"
  malformed 'no-pod entry 15 is not a map of rule, reason'
  copy not-lists
  echo '[]' > "$COPY/exceptions.yaml"
  malformed 'the exceptions file is not a map of the lists no-rule and no-pod'
}
