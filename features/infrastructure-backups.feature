Feature: Backup buckets and the cluster's S3 key
  The backup buckets exist outside every stack, and the cluster has its own S3 key, distinct from the state key, without a bucket's name or a key on screen.

  Scenario: The four backup buckets are created through the S3 API and a second run creates nothing
    Given the state key, a bucket prefix and an object storage without the backup buckets
    When infra-backup-buckets runs, and then runs again
    Then the first run creates the etcd, openbao, volsync and postgres buckets through the S3 client with the state key, naming each by its role, and the second creates nothing, says each exists and exits 0

  Scenario: A bucket name that is taken fails naming the bucket by its role only
    Given a backup bucket's name that another project owns, which the S3 client creates without an error
    When infra-backup-buckets runs
    Then it exits non-zero with a line that names only that bucket's role, creates the other buckets, and prints nothing the S3 client reported

  Scenario: No bucket name, key or endpoint reaches the output, and no key reaches a command line
    Given keys, a bucket prefix and an S3 endpoint that are marker strings
    When infra-backup-buckets, infra-s3-key, infra-backup-check and infra-state-bucket run, succeeding and failing
    Then no marker appears in anything they print, no key or endpoint appears in any recorded argument list, and the openstack client gets no S3 key

  Scenario: The S3 client reads nothing but its environment
    Given an rclone config file wherever rclone looks for one, and the operator's own RCLONE_ and AWS_ variables
    When the S3 client runs for the recipes
    Then its environment holds only its own settings, the endpoint from the backend file and an in-memory config, and rclone itself lists no remote but the object storage's

  Scenario: A new key pair is written to .env without being shown
    Given a .env with the key set's names empty, holding placeholders, or absent, or no .env at all
    When infra-s3-key creates a key pair for the set
    Then .env holds the pair under the set's two names in the form the recipes read, mode 0600, through a temporary file renamed into place, with every other line unchanged, and neither value is printed

  Scenario: A name that already holds a key is refused before anything is created
    Given a .env in which one of the key set's names holds a value
    When infra-s3-key runs for that set
    Then it exits non-zero naming the variable and not its value, never starts the openstack client, and leaves .env unchanged

  Scenario: A .env that is a symlink or not ignored is refused
    Given a .env that is a symlink, or a repository whose ignore rules do not cover .env
    When infra-s3-key runs
    Then it exits non-zero saying why, never starts the openstack client, and writes nothing

  Scenario: The cluster's key must differ from the state key
    Given the cluster's key and the state key
    When infra-backup-check runs with different access key IDs, and with the same one
    Then it passes the first and fails the second, printing neither ID

  Scenario: The backup check reports each bucket the cluster's key cannot list
    Given two of the four backup buckets missing
    When infra-backup-check runs
    Then it lists each bucket through the S3 client with the cluster's key, passes the two that exist and fails the two that do not, naming each by its role only

  Scenario: No stack owns a bucket
    Given a stack that declares an object storage container and a module that declares an S3 bucket
    When the infrastructure check runs
    Then it fails naming the stack and the module, so no destroy can remove a bucket

  Scenario: A missing variable stops the backup and key recipes before anything runs
    Given an environment without one of the names a recipe needs, or with it empty or a placeholder
    When infra-backup-buckets, infra-backup-check or infra-s3-key runs
    Then it exits non-zero naming the variable, and neither the S3 client nor the openstack client is started
