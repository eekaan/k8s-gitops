Feature: Rebuilding the cluster
  The cluster is taken down to nothing and built again from the repository, the operator's keys and custody files, and the copies in the backup buckets (docs/runbooks/rebuild.md). Before it is taken down, one recipe takes and checks a last copy of everything the rebuild restores from, and compares every custody file the restores need with what the running cluster holds; the runbook then leads through every restore in order, the secret store's first, names every database the cluster builds with the way it comes back, and brings Ascender's secret key back with the store before Ascender's database.

  Scenario: The rebuild runbook links every restore the runbooks hold, the secret store's before what reads it
    Given the "## Restoring" headings of the runbooks, and the runbooks whose title begins with Restoring
    When docs/runbooks/rebuild.md is read
    Then it links each of them by its anchor, and in "Building it again" the hold of the databases' backups is merged and published before just cluster-flux, the old seal key goes in place in the step that runs just cluster-flux, which after a seal-key rotation takes the custody file just bao-seal-keep wrote, writes the previous key's Secret too and links the rotation, OpenBao's restore comes before the volumes', and the volumes' before the databases', and in "Taking it down" just cluster-last-copies comes before just cluster-destroy

  Scenario: The rebuild runbook names every database the cluster's render builds, and how each comes back
    Given the render of lab-sto2
    When its PostgreSQL Clusters are listed
    Then each <namespace>/<name> has a row of its own in the runbook's table of databases, with a link to a restore or the words "made again by a start", the table has no row for a database the render does not build, and a render with one more Cluster fails naming it

  Scenario: The rebuild runbook brings Ascender's secret key back with the secret store, before Ascender's database
    Given the render of lab-sto2
    When the AWX's secret_key_secret, the ExternalSecret of the render that writes that Secret and the store path it reads are found, and docs/runbooks/rebuild.md is read
    Then the step "The secret store." names that path and Ascender, the step "The databases." comes after it and its Ascender row names the store, neither "What does not" nor "What no restore brings back." names ascender-secret-key as lost, a render whose AWX names no Secret of the store fails, naming it, and a runbook that names ascender-secret-key there, in backquotes or not, fails, naming each place

  Scenario: The last copies are taken and checked before the cluster is taken down, and what each covers is printed
    Given a running cluster with the secret store, three databases from the component, one of them idle, and two backed-up volumes, and the three custody files of what it holds
    When just cluster-last-copies runs with the three files
    Then it takes, in this order, a snapshot of the secret store by a Job from its CronJob, checked with openbao-snapshot-check; for each database a dump by a Job from its dump CronJob, checked with postgres-dump-check, a WAL segment switched on its primary, the newest complete one even where nothing was written since the last switch, and waited for until the archiver has archived it, and its ObjectStore's recovery window; and for each volume a backup by VolSync's manual trigger, once no backup of it runs, while the Kustomization that owns it is suspended, resumed afterwards; every copy is newer than the run, every kubectl call it makes itself but exec is made with a request timeout, and it prints one line per copy: the snapshot's name, each database's dump and the segment and time its WAL is archived through, and each volume's backup time

  Scenario: A custody file that is missing, does not open or does not hold what the cluster holds stops the last copies before any is taken, and is named
    Given a running cluster and the three custody files, the Talos age key and the Flux age key, and the same after a seal-key rotation, its current key openbao-seal-2 and its previous key openbao-seal-1
    When one file is missing, is not where only the operator can have written it, does not open with the Talos age key or holds another key than the cluster holds for any one of its databases or volumes, or an age key is missing or is not the one its .sops.yaml encrypts to, or after the rotation the OpenBao custody file is the one written before it, and just cluster-last-copies runs
    Then it exits non-zero naming that file or key by its role, the older OpenBao custody file with bao-seal-restore's reason on the lines above and each seal Secret by its id, having created no Job, patched nothing, suspended nothing and run nothing in a pod, while after the rotation the custody file bao-seal-keep wrote passes the comparison

  Scenario: A last copy that fails, or is not newer than the run, fails the recipe naming it, and what it suspended is resumed
    Given a running cluster and the custody files of what it holds
    When the snapshot job fails or uploads nothing, a dump is older than the run, by a day or by seconds, or fails its check, the archiver does not reach the switched segment, an ObjectStore has no recovery window, a mover ends Failed, before or once its tag is reported, a wait outlasts LAST_COPIES_TIMEOUT, a Kustomization that owns a volume is suspended already, or a Kustomization cannot be resumed
    Then the recipe exits non-zero naming the copy and the reason, takes no later copy, resumes every Kustomization it suspended, names one suspended already before any copy is taken and leaves it suspended, and names last, with the command that resumes it, one it could not resume

  Scenario: The last copies' check takes no copy and changes nothing
    Given a running cluster and the custody files of what it holds
    When just cluster-last-copies runs with --check
    Then it compares every custody file, prints the plan of the copies by namespace and name and exits 0, having created no Job, patched nothing, suspended nothing, run nothing in a pod and read no bucket

  Scenario: The last copies print no key, password, address or bucket name, and pass none as an argument
    Given a running cluster, the custody files and the object storage, holding markers for their keys, passwords, addresses and names
    When just cluster-last-copies runs, and runs again while kubectl's errors name the API server's address
    Then neither run prints a key, a password, an address, the endpoint or a bucket's name, and no command either run starts is given a key or a password as an argument
