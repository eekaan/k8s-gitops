Feature: Cluster baseline
  Resource definitions, runtime classes, the certificate controller and small services that later applications assume.

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
    Given the two resource-definition applications
    When their Kustomizations and objects are read
    Then removing either application from the tree would not delete its definitions

  Scenario: Each container runtime the image adds has a RuntimeClass with its handler
    Given the runtime-classes application, enabled in the cluster's overlay
    When it is built offline as Flux applies it
    Then it yields exactly two RuntimeClasses, without a namespace: gvisor with gVisor's handler runsc, and kata with Kata Containers' handler kata

  Scenario: The certificate controller runs in its own namespace with its resource definitions
    Given the cert-manager application and its namespace directory, enabled in the cluster's overlay
    When its pinned chart is rendered offline with the repository's values
    Then its controller, webhook and CA injector run in the namespace cert-manager, no object it renders is in another namespace, and it yields the cert-manager.io and acme.cert-manager.io definitions, each kept when the release is uninstalled

  Scenario: The certificate controller handles Gateway API resources
    Given the cert-manager application and the Gateway API resource definitions application
    When its Kustomization is read and its chart is rendered offline
    Then the controller's configuration turns Gateway API support on, and the application starts only once the Gateway API definitions are established

  Scenario: The certificate controller keeps running while a node is drained
    Given the cert-manager chart rendered offline with the repository's values
    When its Deployments and PodDisruptionBudgets are read
    Then the controller, webhook and CA injector each run at least two replicas spread over the nodes, under a disruption budget that keeps one available and leaves at least one free to evict
