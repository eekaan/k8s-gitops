Feature: PostgreSQL
  The CloudNativePG operator, run by Flux in its own namespace, and the component that gives an application a PostgreSQL cluster of three instances on three workers. Each cluster's application database is dumped once a day, encrypted before it leaves the cluster, and the dump is uploaded to the object storage; the operator's own backup objects are not used.

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
    Then it yields one Cluster of that name in the application's namespace, with three instances that must run on three different nodes, the operator's disruption budgets on, an image whose tag names a PostgreSQL minor version and none of the operator's own backup objects, and one PodMonitor that selects that Cluster's instances and their metrics port

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

  Scenario: A PostgreSQL cluster from the component is dumped daily and only the encrypted dump is uploaded, to a path of its own
    Given an application whose Kustomization names the cnpg-cluster component, built as Flux applies it, and the job's scripts run with a stand-in for pg_dump and a recording stand-in for the S3 client
    When the job's steps run in order
    Then a CronJob runs once a day, never two at once, with a deadline that ends a run before the alert on a failing run fires, starting a time of its own that depends on the database's namespace and name alone, and the one object uploaded is the dump encrypted to the one recipient the operator's recipes use, named by its time and suffix, under the cluster, namespace and name of the database in the postgres bucket, while the plain dump is in a sized, memory-backed volume that only the dump and the encrypting step mount and no call of the client is given its path

  Scenario: The dump is taken as the application's own role and the S3 key reaches only the upload
    Given the component built for an application, and the job's dump step run with stand-ins for pg_dump and pg_isready
    When the containers' environments and volumes are read
    Then the dump reads the username, password and database name of the Secret the operator makes for the application's role and no superuser's, from a replica's Service and from the primary's only when no replica answers, and fails the job when it cannot write the dump, and the two fields of the S3 key reach the upload container alone

  Scenario: Two databases never share a path, and one's retention deletes none of another's
    Given three databases built from the component, two in one namespace and two of one name in two namespaces, and a bucket that holds more than the retention keeps of each, and objects of nobody's
    When one database's job uploads its dump
    Then the three paths differ, and only the oldest dumps of that database's own path are deleted, after the new one is listed there, and nothing else in the bucket is touched

  Scenario: The dump tool is of the PostgreSQL version the cluster runs
    Given the component's Cluster and the image of the dump step built for an application
    When their images are read
    Then the dump step runs an image of the operator's registry path whose tag names the same PostgreSQL major version as the Cluster's, and every image of the job is pinned by tag and digest
