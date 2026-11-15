Feature: etcd snapshots
  An etcd snapshot leaves the operator's machine only encrypted to the Talos age key, and is restored into the same cluster once the cluster's name is typed back.

  Scenario: A snapshot is uploaded encrypted and nothing is left on disk
    Given a cluster whose control plane gives talman an etcd snapshot, and the etcd backup bucket
    When cluster-snapshot runs
    Then the bucket holds one new object under the cluster's name, named after the UTC time, whose first line is the age header and which the Talos age key decrypts to what talman wrote; the recipe prints that object's name and size, and its private temporary directory is gone

  Scenario: The upload is only ever handed the encrypted file
    Given an S3 client that records what each upload is handed
    When cluster-snapshot runs, succeeding, with the upload failing and with CI set
    Then every upload is handed one file, which starts with the age header and is alone in its directory, the plaintext snapshot removed before the upload starts

  Scenario: A failed upload fails the recipe and leaves no snapshot on disk
    Given an S3 client whose upload fails
    When cluster-snapshot runs
    Then it exits non-zero naming the upload as the step it failed in and showing the reason the S3 client gave, without the endpoint, bucket or keys it names, and neither the snapshot nor its encrypted copy is left on disk

  Scenario: A failed S3 request says why, without an address, a bucket or a key
    Given an S3 client that fails a listing, a download or an upload as denied, a bucket that is not there, and an endpoint whose name does not resolve, each naming the endpoint, the bucket and an address
    When cluster-snapshot, cluster-restore and cluster-snapshots run, without CI and with CI set
    Then each exits non-zero, and without CI shows the reason the client gave, with no endpoint, bucket name, address or key; with CI set it shows none of the client's words and names the file git ignores that holds them

  Scenario: A failed S3 request shows at most eight lines of the client's errors, each cut at 300 characters
    Given an S3 client whose listing fails with a line of 350 characters and eleven more lines
    When cluster-restore runs without CI
    Then it exits non-zero showing eight lines of the client's errors, the first cut at 300 characters

  Scenario: A failed or interrupted snapshot leaves nothing on disk
    Given talman failing once it has started writing the snapshot, or the run interrupted while talman writes it, whether talman dies of the interruption or handles it and finishes
    When cluster-snapshot runs
    Then it exits non-zero, uploads nothing, and its private temporary directory is gone

  Scenario: The upload cannot create a bucket
    Given a bucket prefix whose etcd bucket does not exist
    When cluster-snapshot runs
    Then the upload carries rclone's no-check-bucket option and fails, no bucket is created, and the recipe exits non-zero saying the bucket must exist

  Scenario: Nothing but the object's name and size reaches the output
    Given a bucket prefix, S3 keys, an endpoint, an age key and snapshot content that are marker strings
    When cluster-snapshot, cluster-snapshots and cluster-restore run, succeeding and failing, with and without CI
    Then no marker appears in anything they print, and none but the bucket's name, which only the S3 client is given, appears in any recorded argument list

  Scenario: Snapshots are listed newest first for one cluster only
    Given the etcd bucket holding snapshots of the cluster, snapshots of other clusters and objects that are not snapshots
    When cluster-snapshots runs
    Then it prints the cluster's snapshots only, newest first by the time in their names, each by its name and size

  Scenario: A restore asks first, and nothing is reset without the cluster's name
    Given a snapshot of the cluster in the etcd bucket
    When cluster-restore runs for it and the cluster's name is not typed back
    Then it has said that the control planes are reset, the workers not, and the cluster's state replaced by the snapshot's, everything written after the snapshot lost, exits non-zero and resets nothing; with the name typed back, or with --yes, the restore goes ahead

  Scenario: A restore resets the nodes and recovers from the decrypted snapshot
    Given snapshots of the cluster in the etcd bucket, encrypted to the Talos age key
    When cluster-restore runs for one of them by name, and for latest, and the cluster's name is typed back
    Then talman resets the EPHEMERAL partition of every control plane and of no worker, without a graceful leave, then bootstraps etcd from a file holding that snapshot's content, then the kubeconfig is fetched and every node, workers included, is waited for until it reports Ready after the reset, in that order, and nothing applied before Flux starts is applied again

  Scenario: A restore reboots the control planes it resets
    Given snapshots of the cluster in the etcd bucket, and nodes that answer on the Talos API port only while they run
    When cluster-restore runs for the latest
    Then talman reset is told to reboot, the nodes it reset answer on the Talos API port again, and etcd is bootstrapped from the snapshot, where a reset told not to reboot would leave them silent and fail the wait

  Scenario: A restore counts the volumes first and says what it does to them
    Given a cluster with PersistentVolumes of LINSTOR's CSI driver beside others, or none, an API that does not answer or refuses the kubeconfig, and no kubeconfig
    When cluster-restore runs for a snapshot and the cluster's name is not typed back, and with --yes
    Then before it asks it says by number, without a volume's name, how many PersistentVolumes of LINSTOR the cluster has, or that they cannot be counted, because the API does not answer or the kubeconfig may not list them, and that LINSTOR keeps its database in the Kubernetes API, so a volume created after the snapshot is orphaned on the workers and one deleted after it comes back without its data, and where the runbook says what to do; nothing is reset without the name

  Scenario: A snapshot this key cannot decrypt stops the restore before anything is reset
    Given an object encrypted to another age key, and one that is not an age file
    When cluster-restore runs for each
    Then it exits non-zero saying which it is, asks nothing, resets nothing and leaves nothing on disk

  Scenario: A missing snapshot stops the restore before anything is reset
    Given an etcd bucket without the named snapshot, and one without any snapshot of the cluster
    When cluster-restore runs for that name, and for latest
    Then it exits non-zero saying the snapshot is not there, downloads nothing, asks nothing and resets nothing

  Scenario: The decrypted snapshot is removed whether the restore succeeds or fails
    Given a snapshot of the cluster in the etcd bucket
    When cluster-restore succeeds, fails while resetting, fails while bootstrapping, fails while waiting for the nodes, and is interrupted while bootstrapping
    Then no file of the restore, the decrypted snapshot among them, is left on disk after any of them

  Scenario: The age key never reaches a command line
    Given the Talos age key in a file SOPS_AGE_KEY_FILE names, or only in SOPS_AGE_KEY
    When cluster-snapshot and cluster-restore run
    Then cluster-snapshot hands age no key, cluster-restore hands it the key file's path or the key on its standard input, and the key appears in no recorded argument list and nothing printed

  Scenario: Only the snapshot job's namespace may reach the Talos API, and only to back up etcd
    Given every node's machine configuration rendered offline, and the snapshot application's namespace and Talos service account
    When the control planes' and the workers' configurations are read
    Then the control planes enable Kubernetes' access to the Talos API with the role os:etcd:backup alone and the snapshot job's namespace alone, the service account asks for that role alone, and the workers enable none of it

  Scenario: The job uploads only an encrypted snapshot, named as the operator's recipe names its own
    Given the job's scripts as the application ships them, a snapshot, the Talos age key's recipient and an S3 client that records what it is handed
    When the scripts that encrypt and upload run in the order the job runs them
    Then the plain snapshot is gone before the upload starts, the upload is handed one file that starts with the age header and that the Talos age key decrypts to the snapshot, under the cluster's name and a name the operator's recipes list, and the recipient is the one the operator's recipe encrypts to

  Scenario: The job keeps the newest snapshots and deletes no other object
    Given the cluster's prefix in the etcd bucket holding more snapshots than the job keeps, and objects that are not snapshots
    When the job's upload script runs
    Then the oldest snapshots beyond the count it keeps are deleted, after the new one is listed, and nothing else is

  Scenario: The job's Talos tool is the cluster's Talos version
    Given the application's talosctl image and the Talos version of versions.yaml
    When the image's tag is compared with the version, and with the talosctl pin of mise.toml
    Then they are the same version, and the image is pinned by tag and digest

  Scenario: The S3 key reaches the job from the secret store and is nowhere in the tree
    Given the application as Flux builds it
    When its objects are read
    Then an ExternalSecret reads the S3 key's two properties from the secret store, the job takes them from the Secret it writes into the one container that uploads, and no object or file of the application holds a key

  Scenario: A snapshot the job took is listed and restored by the operator's recipes
    Given a snapshot the job's scripts encrypted and uploaded, beside one the operator's recipe took
    When cluster-snapshots runs, and cluster-restore runs for latest
    Then both are listed newest first, and the restore recovers from the newest, whichever took it

  Scenario: A cluster that does not select the job builds none of it
    Given the cluster's overlay with the snapshot application listed, and with it left out
    When the overlay is built
    Then the namespace and the application's Kustomization are built only while it is listed
