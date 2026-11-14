Feature: PostgreSQL
  The CloudNativePG operator, run by Flux in its own namespace, and the component that gives an application a PostgreSQL cluster of three instances on three workers. Backups are not configured yet.

  Scenario: The PostgreSQL operator is installed with its resource definitions
    Given the cloudnative-pg application and its namespace, enabled in the cluster's overlay
    When its pinned chart is rendered offline with the repository's values
    Then the operator runs in the namespace cnpg-system, no object it renders is in another namespace, and it yields the postgresql.cnpg.io definitions of Cluster, Database, Pooler, Backup and ScheduledBackup, each kept when the release is uninstalled, while the application applies no definition itself

  Scenario: The PostgreSQL operator keeps reconciling and admitting while a node is drained
    Given the rendered chart and the objects the application applies itself
    When the operator's Deployment and the disruption budgets that select its pods are read
    Then it runs two replicas with leader election that must be on different nodes, and one disruption budget keeps one running and lets a drain evict the other

  Scenario: The PostgreSQL operator is scraped through its PodMonitor
    Given the cloudnative-pg application and its chart rendered with the monitoring API present
    When its Kustomization and its monitoring objects are read
    Then the chart yields exactly one PodMonitor, which selects the operator's pods and their metrics port, and no dashboard, and the application names prometheus-operator-crds in dependsOn and is Ready only once the operator is

  Scenario: The PostgreSQL operator meets the restricted Pod Security level its namespace enforces
    Given the cnpg-system namespace and the rendered chart
    When the namespace's labels and the pod templates are read
    Then the namespace enforces the restricted level, and no pod template uses a host namespace, port or path, allows privilege escalation, runs as root, runs without the runtime's seccomp profile or keeps a capability

  Scenario: The operator chart and the PostgreSQL image are pinned where Renovate updates them
    Given the application's OCIRepository and the component's Cluster
    When their versions and the comment line above each are read
    Then the chart's tag is an exact version and the image's tag names a PostgreSQL minor version, each under a renovate comment that names the registry path it is pulled from

  Scenario: An application gets a three-instance PostgreSQL cluster from the component
    Given an application whose Kustomization names the cnpg-cluster component and sets its cluster's name
    When it is built as Flux applies it
    Then it yields one Cluster of that name in the application's namespace, with three instances that must run on three different nodes, the operator's disruption budgets on, an image whose tag names a PostgreSQL minor version and no backup, and one PodMonitor that selects that Cluster's instances and their metrics port

  Scenario: Each PostgreSQL instance keeps its data once, on its own node
    Given the component's Cluster built for an application, and the StorageClasses the cluster's applications apply
    When the StorageClass the Cluster names is read
    Then it is LINSTOR's single-replica class without DRBD, which only the volume's own node reaches and which is not the default

  Scenario: Every field of the component's Cluster is one the pinned operator defines
    Given the component's Cluster built for an application, and the Cluster definition of the pinned chart
    When each field and value is looked up in the definition's schema
    Then each field is defined there, and each value has the type the schema gives and, where it lists them, one of the values it allows

  Scenario: An application changes its cluster with a patch that targets the Cluster by kind
    Given two applications that take a cluster from the component and patch it in their own kustomization, one targeting the Cluster by kind and one by the name the application gives it
    When each is built as Flux applies it
    Then the patch by kind changes the Cluster the component made and leaves the rest of it, and the patch by name changes nothing, as the Cluster still has the variable for its name when the patches apply

  Scenario: An application must name the cluster it takes from the component
    Given an application whose Kustomization names the cnpg-cluster component without setting its cluster's name
    When it is built with Flux's strict substitution
    Then the build fails, naming the variable CNPG_CLUSTER_NAME
