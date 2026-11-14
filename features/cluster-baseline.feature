Feature: Cluster baseline
  Resource definitions and small services that later applications assume.

  Scenario: The monitoring resource definitions are installed without a controller
    Given the pinned chart and its values
    When it is rendered offline
    Then it yields only CustomResourceDefinitions

  Scenario: The Gateway API resource definitions are installed from the standard channel
    Given the pinned source
    When it is built offline
    Then it yields only CustomResourceDefinitions of the Gateway API group

  @pending #FLX-9
  Scenario: Every baseline chart renders with the repository's values
    Given each baseline application's pinned chart and values
    When each is rendered offline
    Then all render without error and none yields a ServiceMonitor, PodMonitor or dashboard object

  @pending #FLX-9
  Scenario: Serving certificates are approved only for this cluster's nodes
    Given the certificate approver's values
    When they are read
    Then the node name pattern and address range come from cluster variables and no request is approved by default

  @pending #FLX-9
  Scenario: Metrics are scraped over verified kubelet certificates
    Given the metrics-server's rendered arguments
    When they are read
    Then no argument disables kubelet certificate verification

  Scenario: Resource definitions are never pruned
    Given the two resource-definition applications
    When their Kustomizations and objects are read
    Then removing either application from the tree would not delete its definitions
