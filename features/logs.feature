Feature: Logs
  VictoriaLogs keeps the cluster's logs for two weeks, and Vector on every node ships them: every pod's, and the node's own Talos service and kernel logs but its audit log, read from the files Talos writes. A person on the cluster's sign-in list reads them in VictoriaLogs' own interface at logs under the cluster's domain, and nothing else of the store is reachable through the public Gateway.

  Scenario: The log store builds with Flux and runs once in the monitoring namespace
    Given the victoria-logs application and its namespace directory, enabled in the cluster's overlay
    When it is built as Flux applies it and its pinned chart is rendered with the repository's values
    Then it yields one VictoriaLogs StatefulSet with one replica in the namespace monitoring, no disruption budget that would keep a drain from evicting it, and no dashboard

  Scenario: The log store keeps two weeks of logs on a claim from the default storage class
    Given the victoria-logs application's pinned chart and values
    When the chart is rendered offline
    Then the store keeps logs for 14 days and drops the oldest days once they take a stated size, written as VictoriaLogs reads a size, that leaves a fifth of its volume free, on a claim of a stated size, written as Kubernetes reads a quantity, that names no storage class

  Scenario: A collector runs on every node, control planes included
    Given the vector application, enabled in the cluster's overlay
    When it is built as Flux applies it and its pinned chart is rendered with the repository's values
    Then it yields one DaemonSet in the namespace monitoring that tolerates every taint, the control planes' included, with no node selector or affinity keeping it off a node

  Scenario: The collector ships every pod's logs and every Talos service's log but the audit log to the store
    Given the vector and victoria-logs applications' pinned charts and values, and Vector's unit tests of the collector's configuration
    When the collector's rendered configuration is read
    Then it reads every pod's log files and the log file Talos writes for each of its services, the kernel's included, current and rotated, and sends both to the store's Service on the store's port, by the cluster's DNS domain, Talos's lines along one path, on which the unit tests find a line of each service whose format the collector reads, and of udevd, at the last transform before the store with its service's name, and no line of the audit log, auditd's

  Scenario: The collector ships nothing from the API server's audit log directory
    Given the collector's rendered configuration and a directory laid out as Talos lays out /var/log, with the API server's audit logs under audit/kube
    When the file source's patterns are matched against it
    Then they match each top-level service log and its rotated file and nothing below audit/, pods/ or containers/, and the pod-log source reads only pods/

  @by:vector-check
  Scenario: Vector loads the collector's configuration and reads Talos's lines as intended
    Given the collector's rendered configuration and Vector's unit tests of it
    When the Vector image the collector runs validates the configuration and runs the tests
    Then the configuration loads, and lines of each format Talos writes keep their own time and level, the node's name and their service's

  Scenario: The collector's configuration is rendered with flux and helm given none of the secrets
    Given every secret variable the recipes read set to a marker, and a recording flux and helm
    When scripts/vector-config renders the configuration
    Then each tool's recorded environment holds none of the secrets, and holds the run's own settings

  Scenario: The collector's configuration is checked with the image the collector runs
    Given the justfile, the Dagger module and the vector application's pinned chart
    When the image vector-check runs and the image the rendered DaemonSet runs are read
    Then vector-check and just ci name one Vector image, pinned by digest, of the version and variant the chart runs, under the comment by which Renovate moves its tag and digest, and the module names no image of its own for it

  Scenario: The collector has the host access it needs and no more
    Given the collector's rendered DaemonSet and the monitoring namespace in the cluster's built overlay
    When they are read
    Then the collector runs as root, which owns the log files, mounts /var/log read-only and its own state directory and no other host path, is not privileged, shares none of the host's namespaces, drops every capability and adds none, and the namespace's Pod Security level admits it

  Scenario: Nothing in the log pipeline listens beyond what it serves
    Given the vector and victoria-logs applications' pinned charts and values
    When they are rendered offline
    Then neither yields an Ingress, a route, a Gateway or a Service of type LoadBalancer or NodePort, no pod of either uses the host's network or a host port, and the collector's only listener, in its configuration and in its DaemonSet's ports, is its metrics exporter

  Scenario: The log store and the collector have their monitors on
    Given the vector and victoria-logs applications' pinned charts and values, with the monitoring API present
    When they are rendered offline
    Then the store yields a ServiceMonitor that selects its Service on a port the Service serves, the collector a PodMonitor that selects its pods on the port its metrics exporter listens on, and both applications name prometheus-operator-crds in dependsOn

  Scenario: An operator's query prints the matching records, oldest first, without an address
    Given a cluster's kubeconfig and a kubectl that answers VictoriaLogs' query endpoint through the service proxy with records in neither time order, as for a query whose pipes reorder them, one with control characters in its message
    When just logs runs with a LogsQL query, and with --since, --limit and a cluster
    Then kubectl asks the Kubernetes API for the query, the start of the window, 15 minutes back unless --since says otherwise, and the limit, 200 unless --limit says otherwise, through the cluster's kubeconfig, and the recipe prints one line per record, its time, its node or namespace and pod, and its message without a control character, the oldest first, and no address

  Scenario: A query VictoriaLogs refuses, and an API that does not answer, each fail and say why
    Given a kubectl that reports a refused query as the server's error, with a short message and with one longer than it keeps, one that reports another error the store or the API server answered with, and one that fails naming the API server's address
    When just logs runs
    Then it exits non-zero in each case and prints no record: for the refused query the server's own message, as much of it as kubectl keeps and saying so, for another error kubectl's message, and for the API a reason, none with an address; it refuses a missing query, a bad duration or limit and a missing kubeconfig without running kubectl

  Scenario: An answer larger than a pipe's buffer is printed whole
    Given a kubectl that answers with far more than a pipe holds
    When just logs runs
    Then every record is printed and the recipe exits zero

  Scenario: Grafana reads logs from VictoriaLogs through a datasource the tree declares
    Given the grafana application and the victoria-logs application's pinned chart
    When the first is built as Flux applies it and the second is rendered offline
    Then a GrafanaDatasource selects the Grafana without being its default, is of the VictoriaLogs plugin's type, names the store's Service in its namespace on a port the Service serves, asks for exactly that plugin at an exact version that Renovate updates and for no other, the Grafana's container sets what makes the image's entrypoint install it while Grafana's own preinstall of plugins stays off, and a GrafanaDashboard loads a dashboard of log volume by namespace and by node and a logs panel with namespace and pod variables, from a ConfigMap of the application

  @by:vector-check
  Scenario: Kernel audit records are dropped and counted
    Given the collector's rendered configuration, whose Talos source names a line's fields as Vector's unit tests of it do and whose sink to the store takes Talos's lines only from the last of its Talos transforms, and those unit tests
    When a kernel audit line and another kernel line are sent through the collector's Talos transforms
    Then the audit line leaves the pipeline at a filter transform, which Vector counts as discarded events in its own metrics, so the store never gets it, and the other line goes on to the store

  @by:vector-check
  Scenario: A pod's record carries the named labels and no field per other label
    Given the collector's rendered configuration, whose pod source names a record's fields as Vector's unit tests of it do and whose sink to the store takes a pod's records only from its pod transform, and those unit tests
    When a pod's record with many labels and annotations, from a node with many labels and a namespace with many labels and annotations, is sent through the collector's pod transform
    Then it goes on to the store with the app.kubernetes.io name, instance and component labels it has and no other label or annotation, the pod's, the node's or the namespace's, with the node's name in node and the pod's and its container's single fields, their time and their message as they came

  @by:vector-check
  Scenario: The audit log's records of a permissive denial do not reach the store, and are counted
    Given the collector's rendered configuration, whose Talos source names a line's fields as Vector's unit tests of it do and whose sink to the store takes Talos's lines only from the last of its Talos transforms, and those unit tests
    When the records of one audit event, an AVC record with permissive=1 and its SYSCALL, PATH, PROCTITLE and EOE records, are sent through the collector's Talos transforms as lines of the node's audit log
    Then every one of them leaves the pipeline at a filter transform, which Vector counts as discarded events in its own metrics, so the store never gets any

  @by:vector-check
  Scenario: No record of the audit log reaches the store, and a line of another service does
    Given the collector's rendered configuration, whose Talos source names a line's fields as Vector's unit tests of it do and whose sink to the store takes Talos's lines only from the last of its Talos transforms, and those unit tests
    When a record of the audit log of a type no event above has, a kernel line and a line of another service that mentions an audit record type are sent through the collector's Talos transforms
    Then the audit log's record is dropped and the other two go on to the store, with the node's name and their service's

  Scenario: The store's own writes cannot add records to the store
    Given the collector's rendered configuration
    When every path from a source to a sink is read
    Then the only path from the Talos source to the store runs through the filter that drops the audit log's records, after the filter that drops the kernel's audit lines, and no other transform or sink takes Talos's lines before it

  Scenario: The log store's interface is reached at logs under the cluster's domain on the public Gateway, behind the cluster's sign-in
    Given the victoria-logs-route application as the lab-sto2 overlay applies it, the store's application, the monitoring namespace and oauth2-proxy's grant, built with two different cluster domains
    When its Kustomization, its route, its SecurityPolicy, its sign-in route, the namespace's labels and the grant are read
    Then the application sits beside the store in monitoring, takes the sso component with the route and the host logs, waits, and names gateway-public, victoria-logs and oauth2-proxy in dependsOn, and the store's application waits too; monitoring carries the Gateway label; the route logs is on the public Gateway's https listener for logs under the cluster's domain; its one SecurityPolicy targets it alone and asks oauth2-proxy's Service of sso-system at "/?rd=https://logs.<domain>/", sending it only the cookie, passing the backend the identity it answers with and never letting a request through when the answer cannot be had, and sets nothing else; the route logs-oauth2 sends /oauth2/ on the same host to oauth2-proxy; the grant names monitoring for SecurityPolicy and HTTPRoute; and the route's host, the return address and the sign-in route's host follow the domain

  Scenario: Only the interface and its queries are routed to the log store, and the root is redirected to the interface
    Given the route logs as Flux applies it and the store's rendered Service
    When its rules are read whole and requests are matched against them as Gateway API matches a route
    Then it has two rules: one for exactly / that redirects with status 302 to /select/vmui/ and has no backend, and one with no filter to the store's Service on its port that matches, by path alone and in this order, the prefixes /select/vmui and /select/logsql and exactly /select/buildinfo and /select/tenant_ids; the interface's files, every query handler, the build information and the tenants are sent on, and the root, /select itself, the vmalert proxy, every writer, the delete, internal, metrics, flags, profiling and health paths, and the routed paths changed in letter case, by a suffix or by a trailing slash are sent nowhere

  Scenario: No route of the tree reaches the log store without the cluster's sign-in
    Given every application the overlay enables, built as Flux applies them, and the render of the tree with every chart expanded
    When every route, every object that targets a route, every SecurityPolicy, every ReferenceGrant and the Grafana are read, as they are and with a second route to the store, a route in monitoring without a policy, a second Service in front of the store's pods that another namespace's route names through a grant in monitoring, the policy failing open, another route on the host, a second object on the route or a Grafana that asks its operator for a route added
    Then logs of monitoring is the only route that sends to the store's Service, whatever namespace a reference names or leaves out, every route in monitoring on the public Gateway is one that a policy asking oauth2-proxy of sso-system without failing open targets, or that route's sign-in route to oauth2-proxy alone, no Grafana there asks for a route, logs is targeted by that policy and by nothing else, no other route lists its host, no grant of monitoring lets another namespace refer to its Services, and each addition is named as what breaks this

  Scenario: The log store's route is selected by an overlay entry, builds nothing when it is not, and is refused without the store, the Gateway or the sign-in
    Given the lab-sto2 overlay, which lists victoria-logs-route in one entry of its own
    When it is built with the entry and without it, and the tree is checked without the entry and with victoria-logs, gateway-public or oauth2-proxy left out in turn
    Then with the entry it applies the Kustomization victoria-logs-route and without it nothing of the route and nothing else changes, the tree without it passes the kubernetes check, and each of the three left out is refused, naming victoria-logs-route and the missing application

  Scenario: The routed paths were read from the VictoriaLogs release the pinned chart deploys
    Given the route logs, whose header records the VictoriaLogs release its paths were read from, and the store's pinned chart
    When the record, its Source line and the chart's appVersion are compared
    Then the record is the chart's appVersion, the Source line names app/vlselect/main.go at that release's tag, .renovate/by-hand.tsv holds the record as moved by hand, and a record that differs from the chart's fails, saying what to read again and what to set
