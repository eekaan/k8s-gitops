# Write one value into OpenBao's key-value mount, as just bao-put <path> <key> with the value on standard input (typed without echo at a terminal), through a port-forward the recipe opens and closes, as the operator role with a ten-minute token; prints the path and the key, never the value
[positional-arguments]
bao-put *args:
    scripts/bao-put "$@"

# Make OpenBao's recovery keys, once, and write them with the seal keys its servers mount, the current one and after a rotation the previous one, to a new file outside the repository, encrypted to the Talos age key's recipient, as just bao-recovery <file> [cluster]; refuses before it asks OpenBao for anything when the servers run other seal keys than this checkout names or a key's Secret is missing or malformed
[positional-arguments]
bao-recovery *args:
    scripts/bao-recovery "$@"

# Make a root token from the recovery keys in bao-recovery's file, run one command with it in BAO_TOKEN and OpenBao's address in BAO_ADDR, then revoke it, as just bao-root <file> <command> [argument...]; prints no share or token
[positional-arguments]
bao-root *args:
    scripts/bao-root "$@"

# Write OpenBao's seal keys back into the Secrets of the keys the seal stanza names, the current one and after a rotation the previous one, from the custody file bao-recovery or bao-seal-keep wrote, as just bao-seal-restore <file> [--replace|--check]; refuses a file older than the current key, naming the file to give; a Secret holding another key is replaced only with --replace, and --check checks that the servers run the stanza's keys and compares each Secret's key with the file's, writing nothing, failing for a Secret that holds another key or does not exist
[positional-arguments]
bao-seal-restore *args:
    scripts/bao-seal-restore "$@"

# After a seal-key rotation is applied and every member runs it, write the custody file of the current and the previous seal key from the custody file of the key before the rotation, as just bao-seal-keep <file> <new file>: <new file>, outside the repository and never over a file, gets the recovery keys of <file>, the key of the current key's Secret and, as the previous key, the key of <file>, which the previous key's Secret must hold; encrypted to the Talos age key's recipient, opened again, then checked with bao-seal-restore <new file> --check; prints no key
[positional-arguments]
bao-seal-keep *args:
    scripts/bao-seal-keep "$@"

# Seed the key the volume backups read, once for each store: make the master password, keep it in a new file outside the repository encrypted to the Talos age key's recipient and opened again before the store holds anything, then create the key with the cluster's S3 key (CLUSTER_S3_ACCESS_KEY_ID and CLUSTER_S3_SECRET_ACCESS_KEY), as just bao-seed-volsync <file> [cluster]; refuses a store that holds the key, writes the master an existing file holds to a store that holds none, as after an interruption or on a rebuilt cluster, where <file> must be the existing custody file and never a new one, and with --rotate-s3 replaces only the S3 key (just bao-seed-volsync --rotate-s3 [cluster]); prints neither the master nor the key
[positional-arguments]
bao-seed-volsync *args:
    scripts/bao-seed-volsync "$@"

# Seed the key the PostgreSQL backups read, once for each store: make the SSE-C customer key, keep it in a new file outside the repository encrypted to the Talos age key's recipient and opened again before the store holds anything, then create the key, as just bao-seed-postgres <file> [cluster]; refuses a store that holds the key, writes the key an existing file holds to a store that holds none, as after an interruption or on a rebuilt cluster, where <file> must be the existing custody file and never a new one; prints nothing of the key
[positional-arguments]
bao-seed-postgres *args:
    scripts/bao-seed-postgres "$@"

# Run one command, such as restic, with one application's volume repository, its derived password and the cluster's S3 key in its environment, from the custody file bao-seed-volsync wrote, as just bao-volsync-password <file> <app> <command> [argument...]; prints no password
[positional-arguments]
bao-volsync-password *args:
    scripts/bao-volsync-password "$@"

# List a cluster's OpenBao snapshots in the OpenBao backup bucket, newest first, by name and size, reading only, with the state key
openbao-snapshots cluster='lab-sto2':
    scripts/openbao-snapshots {{ quote(cluster) }}

# Prove that an OpenBao snapshot is a whole raft snapshot archive, as far as that shows without the store's seal key, printing its metadata and nothing of the store: download the snapshot (latest: the newest) into a private directory on a memory-backed filesystem where there is one, check it begins with the age header, decrypt it with the Talos age key, have gzip test it and tar list it, and compare the metadata's size and both SHA-256 checksums with its members, which tar writes to standard output and never to a file; print its name, sizes, time, index, term, metadata version and number of members; the sealed checksums are not opened; everything is removed on every exit; see docs/runbooks/openbao.md
openbao-snapshot-check snapshot='latest' cluster='lab-sto2':
    scripts/openbao-snapshot-check {{ quote(snapshot) }} {{ quote(cluster) }}
