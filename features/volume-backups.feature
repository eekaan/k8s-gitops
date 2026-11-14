Feature: Volume backups
  An application's volume is backed up on a schedule to its own restic repository in the VolSync bucket, and restored from the latest backup when the volume and its restore are created together: the VolSync operator under Flux, and the volsync component an application opts into (ADR 0015). No secret store holds the repository's credentials yet, so no backup runs.

  Scenario: The VolSync operator runs in its own namespace with its resource definitions
    Given the volsync application and its namespace directory, enabled in the cluster's overlay
    When its pinned chart is rendered offline with the repository's values
    Then its controller runs in the namespace volsync-system, no object it renders is in another namespace, and it yields the ReplicationSource and ReplicationDestination definitions, each kept when the release is uninstalled, while the application applies no definition itself

  Scenario: VolSync starts once the definitions it needs exist and is Ready only once it runs
    Given the volsync application
    When its Kustomization is read
    Then it names snapshot-controller and prometheus-operator-crds in dependsOn and waits for what it applies

  Scenario: The VolSync controller meets the restricted Pod Security level its namespace enforces
    Given the volsync-system namespace and the rendered chart
    When the namespace's labels and the pod templates are read
    Then the namespace enforces the restricted level, and no pod template uses a host namespace or path, allows privilege escalation, runs as root, runs without the runtime's seccomp profile or keeps a capability

  Scenario: The VolSync controller keeps running while a node is drained
    Given the rendered chart and the application's disruption budget
    When the Deployment and the budget are read
    Then two or more replicas with leader election run on different nodes, and a budget that selects them keeps one running and lets a drain evict another

  Scenario: VolSync's metrics are scraped without a credential
    Given the pinned chart and values, with the monitoring API present
    When it is rendered offline
    Then it yields one ServiceMonitor, which selects the metrics Service the chart yields and sends no credential, and the controller serves its metrics without asking for one

  Scenario: An application's volume is backed up on its schedule and restored when it is created
    Given the test application volsync-demo, which adds components/volsync with its name, size and schedule
    When it is built as Flux applies it, and again with other values
    Then it yields a claim of that name and size on the default StorageClass, filled on creation by a ReplicationDestination that restores the latest backup once, and a ReplicationSource that backs the claim up on that schedule from a snapshot taken through the cluster's default VolumeSnapshotClass, both with restic and the application's repository Secret

  Scenario: The repository and its credentials come from cluster-config and the secret store
    Given the test application built as Flux applies it, with known values for cluster-config's variables
    When its ExternalSecret is read
    Then it reads one key of the ClusterSecretStore openbao into the Secret the movers read, which holds only what its template renders: the repository, its password, the S3 key and the region, the repository being the application's own path in the VolSync bucket at the object storage's endpoint, and the bucket's prefix, the endpoint and the region coming from cluster-config, and the component holds no Secret

  Scenario: Each repository has a password of its own, and the master password never leaves the store
    Given the test application built as Flux applies it, under its own name and under another
    When the template of its Secret is executed offline against a known master password
    Then no value of the Secret holds the master, and the password is the SHA-256 digest of the master, a slash and the application's name, the same each time, different for the other application and for another master

  Scenario: The movers meet the restricted Pod Security level of the application's namespace
    Given the test application built as Flux applies it, and the demo namespace
    When the movers' security contexts are read
    Then the namespace enforces the restricted level and does not allow privileged movers, and each mover runs as a non-root user and group with the runtime's seccomp profile

  Scenario: Every object the component makes is one the cluster's definitions accept
    Given the test application built as Flux applies it, and the pinned VolSync and External Secrets charts rendered offline
    When each of its VolSync and External Secrets objects is compared with the definitions
    Then its kind and version are served, and every field it sets is in the definition's schema, of the type and among the values the schema allows

  Scenario: No backup runs until the secret store holds the repository's credentials
    Given the test application and the cluster's overlay, built as Flux applies them, OpenBao's initial configuration, and the manifests, scripts and recipes in the tree
    When the Secret the movers read, the secret stores in the tree, what writes into the store and the enabled applications are read
    Then only the component's ExternalSecret makes that Secret, which VolSync requires before it starts a mover, the only secret store the tree defines is the ClusterSecretStore that ExternalSecret names, nothing in the tree writes the key it reads into that store, as OpenBao's initial configuration makes no request under the store's mount and no manifest, script or recipe pushes a Secret, names the key's path or hands the key to bao-put, and the overlay applies the volsync application and its namespace and no application that includes components/volsync, and lists the test application commented out with the reason
