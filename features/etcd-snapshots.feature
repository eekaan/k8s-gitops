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
    Then it exits non-zero naming the upload as the step it failed in, without what the S3 client reported, and neither the snapshot nor its encrypted copy is left on disk

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
    Then it has said that every node is reset and the cluster's state replaced by the snapshot's, everything written after the snapshot lost, exits non-zero and resets nothing; with the name typed back, or with --yes, the restore goes ahead

  Scenario: A restore resets the nodes and recovers from the decrypted snapshot
    Given snapshots of the cluster in the etcd bucket, encrypted to the Talos age key
    When cluster-restore runs for one of them by name, and for latest, and the cluster's name is typed back
    Then talman resets every node's EPHEMERAL partition without a graceful leave, then bootstraps etcd from a file holding that snapshot's content, then the kubeconfig is fetched and every node is waited for until it reports Ready after the reset, in that order, and nothing applied before Flux starts is applied again

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
