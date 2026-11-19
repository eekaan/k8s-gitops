Feature: PostgreSQL
  The CloudNativePG operator, run by Flux in its own namespace, the Barman Cloud plugin beside it, and the component that gives an application a PostgreSQL cluster of three instances on three workers. Each cluster's WAL is archived and its base backups are taken to the object storage, encrypted at the provider with a customer key (ADR 0008), so it can be restored to a point in time; its application database is also dumped once a day, encrypted before it leaves the cluster, and the dump is uploaded to the object storage.

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
    Then it yields one Cluster of that name in the application's namespace, with three instances that must run on three different nodes, the operator's disruption budgets on, an image whose tag names a PostgreSQL minor version, and one PodMonitor that selects that Cluster's instances and their metrics port and labels their series with the Cluster's name

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

  Scenario: The Barman Cloud plugin runs beside the operator it is made for and meets the restricted Pod Security level
    Given the plugin's application and its chart rendered offline with the repository's values, and the operator's chart
    When the operator's version, the plugin's objects and its pod templates are read
    Then the operator is of the release the plugin requires or a newer one, the plugin runs in cnpg-system on more than one node with a budget that keeps one running, its image and its sidecar image are the release its chart is made for, each pinned by digest, the chart makes neither certificates nor an issuer, and no pod template uses a host namespace, runs as root, allows privilege escalation or keeps a capability

  Scenario: The backup plugin and the operator each trust exactly the other's certificate
    Given the plugin's application as Flux builds it, its release with no post-renderer, and its chart rendered offline with the repository's values
    When its Certificates, the issuers they name, the files the plugin's server reads its certificates from and the Secrets the Service names for the operator are read, and certificates made as those issuers make them meet in a TLS 1.3 handshake between stand-ins for the plugin's server and the operator
    Then each Certificate has the name, Secret, usages and DNS names of the plugin's own manifest, is no CA, as there, and names a self-signed Issuer that the build holds in the plugin's namespace, the build holds no ClusterIssuer, the plugin's server takes the client Certificate's tls.crt as its only client authority and serves the server Certificate's, the Service names those two Secrets, and the handshake completes with the operator's certificate presented and verified, while certificates issued by the cluster's CA end it with certificate required

  Scenario: The plugin's chart and images are pinned where Renovate updates them
    Given the plugin's OCIRepository and the values that name its images
    When their versions and the comment line above each are read
    Then the chart's tag is an exact version under a renovate comment that names its registry path, and each image is pinned by a tag and a digest under a renovate comment that names its repository

  Scenario: A PostgreSQL cluster from the component archives its WAL and takes a daily base backup to a path of its own in the object store
    Given an application whose Kustomization names the cnpg-cluster component and sets its cluster's name and namespace, and the databases the cluster's overlay builds
    When each is built as Flux applies it
    Then the Cluster archives through the plugin's entry that names the application's ObjectStore, a ScheduledBackup of method plugin for that Cluster runs once a day at a minute no backup of another kind uses, outside the run of the dump job of each database the overlay builds, and takes its first backup when it is made, the ObjectStore keeps base backups and WAL for a recovery window, compresses both, and reaches the cluster's object storage at the endpoint of cluster-config, in the postgres bucket, under the cluster's name, the namespace and the database's name

  Scenario: Every database's volume has room for its data and the WAL its primary keeps while the archive is down, and grows in place
    Given the databases the cluster's overlay builds from the cnpg-cluster component, every other Cluster their applications build beside them, and the StorageClass each Cluster names
    When each application is built as Flux applies it, from its Kustomization as the overlay makes it, the component's defaults included
    Then each instance's volume is at least 4Gi, sixteen hours of 16MiB WAL segments at one every five minutes besides 1Gi for the data, each Cluster sets no WAL volume, segment size, archive timeout or WAL kept for standbys of its own, which the floor takes at the operator's defaults, it resizes volumes in use, and its StorageClass allows expansion

  Scenario: Every object a database archives is encrypted at the provider with a customer key the provider does not keep
    Given every ObjectStore the component makes for two applications
    When the encryption fields of each are read
    Then each names a Secret key for the customer key, in s3Credentials.sseCustomerKey, and none sets the encryption of its data or its WAL, which the plugin refuses together with it

  Scenario: The object store's key reaches the database's namespace from the secret store and is nowhere in the tree
    Given an application that takes the component, and the tree
    When its ExternalSecret and every file of the tree that is a Secret, a literal credential or an encrypted file are read
    Then the Secret the ObjectStore reads is made by an ExternalSecret of the application's namespace, each credential's key holding the one value of the store it is named for: the cluster's S3 key in the key volsync, its two fields only, and the key postgres-backups of the secret store for the customer key, no Secret holds a value in the tree, and no key is written in any file

  Scenario: Two databases never share a backup path
    Given four applications that take the component, two with different names and two more with the same names in another namespace
    When each is built as Flux applies it
    Then the four archives are in four different places, and the place changes with the name of the Kubernetes cluster that cluster-config holds and with the bucket's prefix, each alone, and ends in the namespace and the database's name

  Scenario: Two databases never share a backup path, whatever namespace an application names
    Given the tree, and a copy in which n8n's Kustomization sets CNPG_NAMESPACE to a namespace other than its targetNamespace, and one that leaves it out
    When scripts/kubernetes-check runs on each
    Then the tree passes, the first is refused naming the Kustomization, the value and the targetNamespace, and the second is refused

  Scenario: Every field of the component's ObjectStore and ScheduledBackup is one the pinned plugin and operator define
    Given the component's ObjectStore and ScheduledBackup built for an application, and the definitions of the pinned plugin chart and operator chart
    When each field and value is looked up in its definition's schema
    Then each field is defined there, and each value has the type the schema gives and, where it lists them, one of the values it allows

  Scenario: A cluster that does not select the backup plugin builds no database that needs it, and one that selects a database without it is refused
    Given the cluster's overlay, with the applications that take the component, n8n and Backstage, and with the plugin's application left out
    When it is built as Flux applies it and checked with scripts/kubernetes-check
    Then each of the two names the plugin's application in dependsOn, either one that takes the component without naming it is refused, and an overlay that lists them without the plugin's application is refused, naming each and the dependency, while one that lists none of the three builds none of them

  Scenario: The restore runbook's manifest is one the pinned operator defines and reads the archive of the cluster it replaces
    Given the Cluster manifest in docs/runbooks/postgres-restore.md and the Cluster definition of the pinned chart
    When each field and value is looked up in the definition's schema
    Then each field is defined there, and the recovery reads the ObjectStore of the old cluster by the old cluster's name and writes the new cluster's archive under its own name

  Scenario: A database held for a restore takes no dump and no base backup, and nothing else of it changes
    Given an application whose Kustomization names the cnpg-cluster component
    When it is built as Flux applies it without CNPG_BACKUPS_SUSPENDED, and with CNPG_BACKUPS_SUSPENDED "true" in its postBuild.substitute
    Then without it the dump CronJob <name>-pgdump and the ScheduledBackup <name> carry suspend false, with it both carry suspend true, each a boolean, every other field of every object the two builds yield is the same, and no other line of the component reads the variable

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

  Scenario: The dumps of a database are listed newest first by name and size
    Given the postgres bucket holds dumps of two databases, objects that are not dumps, and another cluster's dumps of the same database
    When just postgres-dumps runs for one database, for another cluster and with no database named
    Then it lists that database's dumps under its own path only, newest first, each by name and size and nothing else, or the databases that have a dump, and the output names no bucket, endpoint or key

  Scenario: A dump is checked by decrypting it and reading its archive, and nothing of its contents is printed
    Given dumps encrypted to the Talos age key's recipient, a stand-in for the object storage and a stand-in for pg_restore that reads a made-up archive whose table names and rows are markers
    When just postgres-dump-check runs for the newest dump and for a named one
    Then the dump is downloaded, begins with the age header, is decrypted with the Talos age key into a memory-backed directory and read by pg_restore from the cluster's PostgreSQL image, named by its digest in the component, without a network and from a read-only mount, and the recipe prints the dump's name, its encrypted and plain sizes, the archive's format, PostgreSQL version and time, and the number of tables, and no table name, row or other name from the database

  Scenario: A dump that is not encrypted, does not decrypt or cannot be read fails the check with its reason
    Given a dump that is a plain archive, one encrypted to another key and one that holds no archive
    When just postgres-dump-check runs for each
    Then each exits non-zero with a line that says which of the three it is, the plain archive and the one another key encrypted never reach pg_restore, and nothing of the archive's contents is printed

  Scenario: The check leaves nothing behind, whether it passes, fails or is interrupted
    Given a dump that checks, dumps that fail the check, a failing download, and a run interrupted while pg_restore reads the dump, whether pg_restore dies of the interruption or handles it
    When just postgres-dump-check runs for each, with a memory-backed directory and without one
    Then no run leaves a file or directory in the memory-backed directory or in TMPDIR, the plain dump included
