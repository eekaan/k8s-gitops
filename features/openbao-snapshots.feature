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
