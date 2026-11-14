Feature: External Secrets
  The External Secrets operator, which brings runtime secrets from the secret store into the cluster
  (ADR 0005). No secret store is configured yet.

  Scenario: The External Secrets operator is installed with its resource definitions
    Given the external-secrets application and its namespace, enabled in the cluster's overlay
    When its pinned chart is rendered offline with the repository's values
    Then it yields the controller, the webhook and the certificate controller, and the definitions of ExternalSecret, ClusterSecretStore and the Password generator

  Scenario: No secret store, external secret or monitoring object comes with the operator
    Given the external-secrets application
    When it is built as Flux applies it and its chart is rendered offline
    Then neither yields an object of the operator's own kinds, nor a ServiceMonitor, PodMonitor or dashboard

  Scenario: The External Secrets webhook keeps admitting while a node is drained
    Given the rendered chart
    When its Deployments and disruption budgets are read
    Then the webhook, the controller and the certificate controller each run two replicas that must be on different nodes, and each has a disruption budget that keeps one running and lets a drain evict the other

  Scenario: The External Secrets resource definitions outlive the release
    Given the external-secrets application
    When it is built as Flux applies it and its chart is rendered offline
    Then the application applies no definition itself, and Helm keeps every definition the chart installs when the release is uninstalled

  Scenario: The External Secrets pods meet the restricted Pod Security level their namespace enforces
    Given the external-secrets namespace and the rendered chart
    When the namespace's labels and the pod templates are read
    Then the namespace enforces the restricted level, and no pod template uses a host namespace, port or path, allows privilege escalation, runs as root, runs without the runtime's seccomp profile or keeps a capability
