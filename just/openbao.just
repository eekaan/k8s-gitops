# Write one value into OpenBao's key-value mount, as just bao-put <path> <key> with the value on standard input (typed without echo at a terminal), through a port-forward the recipe opens and closes, as the operator role with a ten-minute token; prints the path and the key, never the value
[positional-arguments]
bao-put *args:
    scripts/bao-put "$@"

# Make OpenBao's recovery keys, once, and write them with its seal key to a new file outside the repository, encrypted to the Talos age key's recipient, as just bao-recovery <file> [cluster]
[positional-arguments]
bao-recovery *args:
    scripts/bao-recovery "$@"

# Make a root token from the recovery keys in bao-recovery's file, run one command with it in BAO_TOKEN and OpenBao's address in BAO_ADDR, then revoke it, as just bao-root <file> <command> [argument...]; prints no share or token
[positional-arguments]
bao-root *args:
    scripts/bao-root "$@"

# Write OpenBao's seal key back into its Secret from bao-recovery's file, as just bao-seal-restore <file> [--replace]; a Secret holding another key is replaced only with --replace
[positional-arguments]
bao-seal-restore *args:
    scripts/bao-seal-restore "$@"

# Seed the key the volume backups read, once for each store: make the master password, keep it in a new file outside the repository encrypted to the Talos age key's recipient and opened again before the store holds anything, then create the key with the cluster's S3 key (CLUSTER_S3_ACCESS_KEY_ID and CLUSTER_S3_SECRET_ACCESS_KEY), as just bao-seed-volsync <file> [cluster]; refuses a store that holds the key, writes the master an existing file holds to a store that holds none, as after an interruption or on a rebuilt cluster, and with --rotate-s3 replaces only the S3 key (just bao-seed-volsync --rotate-s3 [cluster]); prints neither the master nor the key
[positional-arguments]
bao-seed-volsync *args:
    scripts/bao-seed-volsync "$@"

# Run one command, such as restic, with one application's volume repository, its derived password and the cluster's S3 key in its environment, from the custody file bao-seed-volsync wrote, as just bao-volsync-password <file> <app> <command> [argument...]; prints no password
[positional-arguments]
bao-volsync-password *args:
    scripts/bao-volsync-password "$@"
