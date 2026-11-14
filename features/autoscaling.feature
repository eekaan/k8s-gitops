Feature: Autoscaling and reflection add-ons
  KEDA for event-driven autoscaling, the vertical pod autoscaler's recommender for resource
  recommendations, and Reflector for copying a Secret or ConfigMap into other namespaces. Each
  cluster's overlay chooses which of them it enables.

  Scenario: KEDA, the autoscaler's recommender and Reflector are enabled and pinned to exact versions
    Given the keda, vpa and reflector applications
    When the lab-sto2 overlay and each application's source are read
    Then the overlay applies each application's Kustomization, and each chart is pinned to an exact version that Renovate can update

  Scenario: KEDA's resource definitions are kept when its release is removed
    Given the keda application's pinned chart and values
    When the chart is rendered offline
    Then it yields the keda.sh and eventing.keda.sh definitions, each carrying helm.sh/resource-policy keep, and the application applies no definition itself

  Scenario: The autoscaler's resource definitions are never part of its release
    Given the vpa application's pinned chart and values
    When the chart is rendered offline with and without its crds directory
    Then the definitions of VerticalPodAutoscaler and its checkpoint come only from the crds directory, which Helm never removes with a release, and the application applies no definition itself

  Scenario: KEDA's metrics API does not collide with the resource metrics API
    Given the rendered KEDA chart and the rendered metrics-server chart
    When their APIService objects are read
    Then KEDA registers external.metrics.k8s.io, metrics-server registers metrics.k8s.io, and no two APIService objects claim the same group and version

  Scenario: KEDA's admission webhooks let objects through while no webhook answers
    Given the rendered KEDA chart
    When its webhook configurations are read
    Then every webhook's failure policy is Ignore

  Scenario: KEDA's namespace holds its Pod Security level
    Given the keda namespace directory and the rendered chart
    When the namespace's labels and the pod templates are read
    Then the namespace enforces the restricted level, and no pod template uses a host namespace or path, allows privilege escalation, runs as root, runs without the runtime's seccomp profile or keeps a capability

  Scenario: The autoscaler renders a recommender and nothing that changes a pod
    Given the vpa application's pinned chart and values
    When the chart is rendered offline
    Then it yields the recommender and no other workload, no webhook configuration, no certificate generator, and no role bound to a service account lets it create, update, patch, delete or evict a pod

  Scenario: Reflector's rights are what the docs say and nothing in the repository is reflected yet
    Given the reflector application's pinned chart and the tree
    When its RBAC is rendered offline and the tree is searched for reflection annotations
    Then Reflector can do anything to Secrets and ConfigMaps in every namespace and only list and watch namespaces, and no file under kubernetes carries a reflection annotation

  Scenario: The add-ons keep running while a node is drained
    Given the three applications' rendered charts
    When their Deployments and disruption budgets are read
    Then KEDA's operator, metrics server and webhooks each run two replicas on different nodes where the scheduler can, under a budget that keeps one running, and the recommender and Reflector run one replica each

  Scenario: Every pod the add-ons run has resource requests
    Given the three applications' rendered charts
    When their pod templates are read
    Then every container and init container requests CPU and memory, except those of the chart's Helm test pods, which run only for `helm test` and set none, and no container has a limit except KEDA's, which its publisher's documentation sets

  Scenario: Every monitor selects a Service or pods that its own render contains
    Given the three applications' rendered charts, with the monitoring API present
    When their ServiceMonitors and PodMonitors are read
    Then each of KEDA's three components and the recommender is selected by exactly one monitor, whose Service or pods the same render contains, each application with a monitor names prometheus-operator-crds in dependsOn, and Reflector has none
