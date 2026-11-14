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
    Then all render without error and none yields a ServiceMonitor, PodMonitor or dashboard object

  Scenario: Serving certificates are approved only for this cluster's nodes
    Given the certificate approver's values
    When they are read
    Then the node name pattern and address range come from cluster variables and no request is approved by default

  Scenario: Metrics are scraped over verified kubelet certificates
    Given the metrics-server's rendered arguments
    When they are read
    Then no argument disables kubelet certificate verification

  Scenario: Resource definitions are never pruned
    Given the resource-definition applications
    When their Kustomizations and objects are read
    Then removing any of them from the tree would not delete its definitions

  Scenario: Each container runtime the image adds has a RuntimeClass with its handler
    Given the runtime-classes application, enabled in the cluster's overlay
    When it is built offline as Flux applies it
    Then it yields exactly two RuntimeClasses, without a namespace: gvisor with gVisor's handler runsc, and kata with Kata Containers' handler kata

  Scenario: Envoy Gateway's chart installs no resource definitions
    Given the Envoy Gateway application's pinned chart and values
    When it is rendered offline with the chart's definitions included
    Then it yields the controller and no CustomResourceDefinition or admission policy

  Scenario: Envoy Gateway's resource definitions come from its chart at the controller's version
    Given the Envoy Gateway resource-definition application
    When its pinned chart is unpacked and built offline as its inner Kustomization applies it
    Then it yields exactly the chart's own gateway.envoyproxy.io definitions, from the chart and version the controller runs

  Scenario: The Gateway API definitions are a release Envoy Gateway supports
    Given the pinned Envoy Gateway chart and the pinned Gateway API source
    When the Gateway API release the chart is built against is compared with the one the repository installs
    Then the installed release has the same major version and is no older, and serves every stable kind and version of the chart's own copy

  Scenario: Envoy Gateway's controller keeps running through a node drain
    Given the controller's rendered Deployment, disruption budget and configuration
    When they are read
    Then two or more replicas with leader election run on different nodes, and the budget keeps at least one of them running

  Scenario: Everything Envoy Gateway runs meets its namespace's Pod Security level
    Given the Envoy Gateway namespace and the chart's rendered workloads
    When they are read
    Then the namespace enforces the restricted level and every pod template the chart renders meets it

  Scenario: Envoy Gateway has a GatewayClass and no Gateway
    Given the Envoy Gateway applications, enabled in the cluster's overlay
    When they are built offline as Flux applies them
    Then the controller waits for both definition applications and yields one GatewayClass for the controller name the chart configures, and no Gateway
