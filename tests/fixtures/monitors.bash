# Helpers of the tests that match a ServiceMonitor or a PodMonitor with what it selects, loaded with
# `load fixtures/monitors` by tests/monitoring.bats and tests/rules-check.bats.

# selected MONITOR_JSON CANDIDATES_JSON: the candidates a monitor scrapes, one name per line: a
# candidate is {name, ns, labels, ports}, a Service for a ServiceMonitor or a pod template for a
# PodMonitor; a Service may also carry targetPorts, the names and numbers of the container ports its
# ports lead to. The monitor selects it when the candidate is in a namespace the monitor looks in (its
# own without a namespaceSelector), carries every label of the monitor's selector and meets each of
# its expressions (a selector that names none selects nothing here) and, for every endpoint, has the
# port it scrapes by name or, for an endpoint that names a targetPort instead, leads to a container
# port of that name or number, which is how the Prometheus Operator keeps such a target. In is the one
# operator of an expression known here: any other is met by nothing, so a monitor that needs one fails
# the scrape tests until this learns it.
selected() {
  # shellcheck disable=SC2016 # $m, $c, $key, $value and $port are jq variables.
  jq -r --argjson m "$1" --argjson c "$2" -n '
    ($m.spec.selector.matchLabels // {}) as $sel
    | ($m.spec.selector.matchExpressions // []) as $exprs
    | ([$m.spec.endpoints[]?, $m.spec.podMetricsEndpoints[]?]) as $endpoints
    | ($m.spec.namespaceSelector.matchNames // [$m.metadata.namespace]) as $namespaces
    | $c[] | . as $cand
    | select($cand.ns | IN($namespaces[]))
    | select(($sel | length) + ($exprs | length) > 0
      and ($sel | to_entries | all(.key as $key | .value == $cand.labels[$key]))
      and ($exprs | all(.key as $key | $cand.labels[$key] as $value
        | if .operator == "In" then $value != null and (.values | index($value) != null)
          else false end)))
    | select(($endpoints | length) > 0 and ($endpoints | all(
        if .port != null then (.port as $port | $cand.ports | index($port) != null)
        elif .targetPort != null then (.targetPort as $port | ($cand.targetPorts // []) | index($port) != null)
        else false end)))
    | $cand.name'
}

# linstor_targets: what the Piraeus operator makes at run time that the monitors of linstor-monitoring
# select, as candidates for selected, read from the operator's templates at the version the monitors
# record (pkg/resources/cluster/controller/controller-service.yaml and
# pkg/resources/satellite/satellite/daemonset.yaml), with the pods of the other components it makes,
# which a monitor must not select.
linstor_targets() {
  echo '[
    {"name": "Service/linstor-controller", "ns": "piraeus-datastore",
     "labels": {"app.kubernetes.io/component": "linstor-controller"}, "ports": ["api"]},
    {"name": "Pod/linstor-satellite", "ns": "piraeus-datastore",
     "labels": {"app.kubernetes.io/component": "linstor-satellite"}, "ports": ["prometheus"]},
    {"name": "Pod/linstor-csi-controller", "ns": "piraeus-datastore",
     "labels": {"app.kubernetes.io/component": "linstor-csi-controller"}, "ports": ["metrics"]},
    {"name": "Pod/linstor-controller", "ns": "piraeus-datastore",
     "labels": {"app.kubernetes.io/component": "linstor-controller"}, "ports": ["api"]}]'
}

# cnpg_targets: what the CloudNativePG operator makes at run time that the PodMonitor of
# components/cnpg-cluster selects, as candidates for selected: the pod of an instance of n8n-db, the
# cluster of the render whose PodMonitor the scrape tests read, with the labels and the container
# ports the operator gives it at the version the cloudnative-pg chart runs, 1.30 (pkg/specs/pods.go,
# pkg/utils/labels_annotations.go). The exporter on the port metrics serves the operator's metrics
# and the Barman Cloud plugin's.
cnpg_targets() {
  echo '[
    {"name": "Pod/n8n-db-1", "ns": "ai-system",
     "labels": {"cnpg.io/cluster": "n8n-db", "cnpg.io/instanceName": "n8n-db-1", "cnpg.io/podRole": "instance",
       "app.kubernetes.io/name": "postgresql", "app.kubernetes.io/instance": "n8n-db",
       "app.kubernetes.io/component": "database", "app.kubernetes.io/managed-by": "cloudnative-pg"},
     "ports": ["postgresql", "metrics", "status"]}]'
}
