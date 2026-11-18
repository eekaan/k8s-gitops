Feature: Volume backups
  An application's volume is backed up on a schedule to its own restic repository in the VolSync bucket, and restored from the latest backup when the volume and its restore are created together: the VolSync operator under Flux, and the volsync component an application opts into (ADR 0015). An operator seeds the repository's credentials into the secret store once, with a recipe, and the backups run by themselves from then on. An application that writes a canary into its volume can take the restore drill as well, the volsync-drill component, which restores the newest backup into a scratch claim every night and fails a check unless the canary in it is fresh.

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

  Scenario: Only the seeding recipe writes the repository's credentials into the secret store
    Given the test application built as Flux applies it, OpenBao's initial configuration, and the manifests, scripts and recipes in the tree
    When the Secret the movers read, the secret stores in the tree and what writes into the store are read
    Then only the component's ExternalSecret makes that Secret, which VolSync requires before it starts a mover, the only secret store the tree defines is the ClusterSecretStore that ExternalSecret names, OpenBao's initial configuration makes no request under the store's mount, no manifest pushes a Secret, the only file that names the key's path is bao-seed-volsync, which binds that key to its write, and the only scripts that write under the store's data path are it and bao-put, which takes its key as an argument

  Scenario: The demo volume's backup and restore objects are in what Flux applies for the cluster
    Given the cluster's overlay, built as Flux applies it, and the application volsync-demo
    When the Kustomizations the overlay applies and the objects volsync-demo builds are read
    Then the overlay applies the volsync application and its namespace, volsync-demo, n8n and open-webui are the only applications that add components/volsync, volsync-demo is the only one that adds components/volsync-drill, every application that adds the drill adds components/volsync, n8n and open-webui build no object of the drill, volsync-demo names volsync, external-secrets, linstor-cluster and the secret store's application in dependsOn, and volsync-demo builds its claim, the ReplicationDestination that restores it and the ReplicationSource that backs it up

  Scenario: An application that takes the drill restores its newest backup into a scratch claim every night
    Given the test application volsync-demo, which adds components/volsync-drill beside components/volsync with a restore schedule, a check schedule and a largest age
    When it is built as Flux applies it, again with other values, with each of those three variables taken out, and with the largest age as a bare number
    Then beside what components/volsync makes, which it leaves as it was, it yields exactly a scratch claim named after the application, of the volume's size on the default StorageClass with no data source, a ReplicationDestination that restores the newest backup straight into that claim on the restore schedule, with no manual trigger, the files the backup does not hold deleted, restic's cache deleted after each restore, the application's repository Secret and the security context components/volsync gives its movers, a CronJob on the check schedule that is given the largest age as text, which the largest age written with its quotes is and a bare number is not, and the ConfigMap of its one script, byte for byte the component's, under a name without a hash, the component's files name those three variables and four of components/volsync's and no other, the build fails without any one of the three, naming it, and the application's Kustomization waits for nothing it applies

  Scenario: The scratch claim is never backed up and the drill gives no key a new holder
    Given the test application built as Flux applies it, with both components
    When its objects are read
    Then it holds one ExternalSecret and no Secret, and the drill component neither, both ReplicationDestinations and the ReplicationSource name the one repository Secret that ExternalSecret writes, the only ReplicationSource backs the application's own claim up, the scratch claim is named by its ReplicationDestination, which copies into it directly, and by the check job and by nothing else, so nothing takes a snapshot or a clone of it, and the check job reads no Secret and mounts no token

  Scenario: The drill's check fails on an empty volume, a missing heartbeat and a stale one, and passes on a fresh one
    Given the check script of the built ConfigMap, run as the CronJob's container runs it, with the environment the built CronJob gives the container and a clock the test sets
    When it reads an empty directory, one that holds only lost+found, one with files and no heartbeat, one with only a hidden file, a heartbeat whose first field is no whole number of seconds or lies in the future, one a second older than the largest age, one exactly as old, a fresh one, and when its largest age or its directory is missing or wrong
    Then it passes on the fresh heartbeat and on the one exactly as old as the largest age, printing one line with the age in seconds and the bound, and fails every other case with its reason on standard error and nothing on standard output, saying of the empty directory that the restore brought nothing back and that a repository path that holds no backup restores nothing without an error, of the two directories without a heartbeat that they hold none, and of the stale heartbeat its age and the bound, and it asks the clock for the seconds alone, holds no ${...} that Flux would substitute, and writes nothing

  Scenario: The demo's canary writes a heartbeat the drill's check accepts
    Given the canary container of volsync-demo's Deployment as built, its command run as the container runs it against a directory, with stand-ins for sleep, which lets the loop go round once and then ends it with TERM, as the kubelet ends the container, for mv, which records what it renames, for fsync, which records what it syncs, what the file then holds and its place among the renames, and for date, which records each call
    When what it wrote is read, it is run again on the same directory, and the heartbeat is given to the drill's check, run as its container runs it
    Then it writes created once and never again, and at each round a heartbeat of one line, the Unix time in seconds and the same moment as a UTC date and time from one date call, written to a new file of the same directory, synced to disk and then renamed over the last, sleeps between rounds the 300 seconds its environment names, and ends with status 0, the check passes on that heartbeat, and the pod runs as the movers' user and group with the runtime's seccomp profile, no privilege escalation, no capability and a read-only root, is replaced by Recreate, and requests 1m of CPU and 8Mi of memory

  Scenario: The drill's check job meets the restricted level, holds no token and only reads the scratch claim
    Given the CronJob the drill component builds for volsync-demo, the policies of the namespace's movers, and every application that takes the component
    When its job and pod templates are read, and again built with another user and group
    Then never two checks run at once, a check's job is made within 600 seconds of its time and ends within 600 more, a failed check is tried once more, its last success and last three failures are kept, and it names no time zone and is not suspended, its one container runs the busybox the demo's Deployments pin, by that tag and a digest, as the movers' user and group with no fsGroup, the runtime's seccomp profile, no privilege escalation, no capability and a read-only root, with a memory request and limit and a CPU request, the pod mounts no service account token, takes no service links, reads no Secret and tolerates no taint, its only volumes are the scratch claim, read-only at the container's mount and not at the pod's volume, and the ConfigMap of its script, which its command names, its pod template carries labels of its own and none that a policy of the namespace's movers selects, and no application that takes the drill has an APP longer than 40 characters, so the CronJob's name stays within 52

  Scenario: The drill's schedules follow the backup's and its largest age follows from them
    Given the test application built as Flux applies it, the alert rules of the volsync application, and the ks.yaml of every application
    When the backup's, the restore's and the check's schedules, the largest age, the canary's interval and the check's two deadlines are read from what is built
    Then the backup runs at 03:17, the restore 3600 seconds after it and the check 3600 seconds after the restore, neither at a minute of the day at which another application backs up or drills, the largest age, 95400 seconds, is the day between two backups, the 7200 seconds from the backup's schedule to the check's, and a margin of 1800 seconds, which is the canary's interval, the check's two deadlines and 300 seconds, and RestoreDrillJobFailing waits longer than those two deadlines together
