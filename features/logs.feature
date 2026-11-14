Feature: Logs
  VictoriaLogs keeps the cluster's logs for two weeks, and Vector on every node ships them: every pod's, and the node's own Talos service and kernel logs, read from the files Talos writes.

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

  Scenario: The collector ships every pod's logs and every Talos service's log to the store
    Given the vector and victoria-logs applications' pinned charts and values
    When the collector's rendered configuration is read
    Then it reads every pod's log files and the log file Talos writes for each of its services, the kernel's included, current and rotated, and sends both to the store's Service on the store's port, by the cluster's DNS domain

  Scenario: The collector ships nothing from the API server's audit log directory
    Given the collector's rendered configuration and a directory laid out as Talos lays out /var/log, with the API server's audit logs under audit/kube
    When the file source's patterns are matched against it
    Then they match each top-level service log and its rotated file and nothing below audit/, pods/ or containers/, and the pod-log source reads only pods/

  @by:vector-check
  Scenario: Vector loads the collector's configuration and reads Talos's lines as intended
    Given the collector's rendered configuration and Vector's unit tests of it
    When the Vector image the collector runs validates the configuration and runs the tests
    Then the configuration loads, and lines of each format Talos writes keep their own time and level, the node's name and their service's

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
