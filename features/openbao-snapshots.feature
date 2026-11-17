Feature: OpenBao snapshots
  The raft storage of the secret store is snapshotted every six hours from inside the cluster, and a snapshot leaves it only encrypted to the Talos age key's recipient, so losing the three volumes does not lose the secrets while the operator keeps the seal key.

  Scenario: The snapshot job logs in as the snapshot role and can do nothing else in the store
    Given the snapshot job as Flux builds it and OpenBao's initial configuration
    When the job's pod, its token and its script are read, and the script is run against a client that records its calls
    Then the pod runs as the account the role snapshot binds, in the namespace it binds, with the audience the role checks and a token that lives in no disk-backed volume, the role's policy reads the raft snapshot path alone, the script calls the client to log in as that role and to save a snapshot and for nothing else, passes the token in the client's environment and never prints it, and the client verifies OpenBao's certificate against the CA, by a name the certificate holds

  Scenario: The job uploads only an encrypted snapshot of the raft storage, named as the etcd snapshots are
    Given the job's scripts as the application ships them, a snapshot, the Talos age key's recipient and an S3 client that records what it is handed
    When the scripts that encrypt and upload run in the order the job runs them
    Then the plain snapshot is gone before the upload starts, the upload is handed one file that starts with the age header and that the Talos age key decrypts to the snapshot, under the cluster's name and a name the operator's recipes list, in the OpenBao bucket, and the recipient is the one the operator's recipe encrypts to

  Scenario: The job's OpenBao client is the cluster's OpenBao version
    Given the snapshot job's client image and the OpenBao chart the cluster pins, rendered with the repository's values
    When the image's repository and tag are compared with the servers'
    Then they are the same, and the image is pinned by tag and digest

  Scenario: The S3 key reaches the OpenBao snapshot job from the secret store and is nowhere in the tree
    Given the snapshot application as Flux builds it
    When its objects are read
    Then an ExternalSecret reads the S3 key's two properties from the secret store, the job takes them from the Secret it writes into the one container that uploads, and no object or file of the application holds a key

  Scenario: A cluster that does not select the OpenBao snapshot job builds none of it
    Given the cluster's overlay with the snapshot application listed, and with it left out
    When the overlay is built
    Then the application's Kustomization is built only while it is listed, and waits for the store and its ClusterSecretStore

  Scenario: The secret store's snapshots are listed newest first by name and size
    Given the OpenBao bucket holding snapshots of the cluster, objects of other names and in deeper paths, and another cluster's snapshots, and the etcd bucket holding snapshots of the same cluster
    When just openbao-snapshots runs for the cluster, for the other cluster and for a cluster without snapshots
    Then it prints the objects directly under the cluster's own path of the OpenBao bucket that are named as a snapshot is, newest first, each by its name and size and nothing else, from one listing request made with the state key; a cluster without snapshots lists nothing, says so on standard error and exits 0; and the output names no bucket, endpoint or key

  Scenario: A snapshot of the secret store is checked by decrypting it and verifying its archive, and nothing of the state is printed
    Given snapshots encrypted to the Talos age key's recipient, each an archive as the pinned OpenBao writes one, whose members' IDs and addresses, storage and sealed checksums are markers, and a stand-in for the object storage
    When just openbao-snapshot-check runs for the newest snapshot, for a named one and for another cluster's newest
    Then the one object is downloaded, begins with the age header and is decrypted with the Talos age key into a memory-backed directory, where tar lists the archive and writes members to standard output and nothing to a file, and the recipe prints exactly the snapshot's name, where it was kept, its encrypted and plain sizes, the time on its metadata's member in UTC, the index, term and version of the metadata and the number of its servers, the size of the state, that both checksums match and that the sealed checksums were not opened, and no member's ID or address, storage key or value, checksum or byte of the sealed file

  Scenario: A snapshot that is not encrypted, does not decrypt, is no raft snapshot archive or fails a checksum fails the check with its reason
    Given a snapshot that is a plain archive, one encrypted to another key, one that holds no archive, one whose state differs from its checksum and one whose metadata does
    When just openbao-snapshot-check runs for each
    Then each exits non-zero with one line that names the snapshot and says which of them it is, in words of the recipe's own, followed only by the step it failed in; the plain archive and the one another key encrypted are never handed to gzip or tar; and nothing of an archive is printed

  Scenario: The snapshot check leaves nothing behind, whether it passes, fails or is interrupted
    Given a snapshot that checks, snapshots that fail the check, a failing download, and runs interrupted by Ctrl-C and by SIGTERM while the plain archive is in the private directory, whether the program then running dies of the signal or handles it and exits 0
    When just openbao-snapshot-check runs for each, with a memory-backed directory and without one
    Then no run leaves a file or directory in the memory-backed directory or in TMPDIR, the encrypted and the plain archive included, and an interrupted run exits non-zero without a line of its result
