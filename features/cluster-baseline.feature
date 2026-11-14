Feature: Cluster baseline
  Resource definitions, runtime classes and small services that later applications assume.

  Scenario: The monitoring resource definitions are installed without a controller
    Given the pinned chart and its values
    When it is rendered offline
    Then it yields only CustomResourceDefinitions

  Scenario: The Gateway API resource definitions are installed from the standard channel
    Given the pinned source
    When it is built offline
    Then it yields only CustomResourceDefinitions of the Gateway API group

  Scenario: Every baseline chart renders with the repository's values
    Given each baseline application's pinned chart and values
    When each is rendered offline
    Then all render without error and none yields a dashboard object

  Scenario: Every baseline application that serves metrics has its monitor on
    Given each baseline application's pinned chart and values, with the monitoring API present
    When each is rendered offline
    Then kubelet-csr-approver, metrics-server, descheduler and spegel each yield a ServiceMonitor and reloader a PodMonitor, each selected by the Service or pods the chart yields, and each of the five names prometheus-operator-crds in dependsOn

  Scenario: Serving certificates are approved only for this cluster's nodes
    Given the certificate approver's values
    When they are read
    Then the node name pattern and address range come from cluster variables and no request is approved by default

  Scenario: Metrics are scraped over verified kubelet certificates
    Given the metrics-server's rendered arguments
    When they are read
    Then no argument disables kubelet certificate verification

  Scenario: Resource definitions are never pruned
    Given the two resource-definition applications
    When their Kustomizations and objects are read
    Then removing either application from the tree would not delete its definitions

  Scenario: Each container runtime the image adds has a RuntimeClass with its handler
    Given the runtime-classes application, enabled in the cluster's overlay
    When it is built offline as Flux applies it
    Then it yields exactly two RuntimeClasses, without a namespace: gvisor with gVisor's handler runsc, and kata with Kata Containers' handler kata
