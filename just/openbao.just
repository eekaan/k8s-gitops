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
