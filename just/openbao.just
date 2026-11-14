# Write one value into OpenBao's key-value mount, as just bao-put <path> <key> [cluster] with the value on standard input (typed without echo at a terminal), through a port-forward the recipe opens and closes, as the operator role with a ten-minute token; prints the path and the key, never the value
[positional-arguments]
bao-put *args:
    scripts/bao-put "$@"

# Make OpenBao's recovery keys, once, and write them with its seal key to a new file outside the repository, encrypted to the Talos age key's recipient, as just bao-recovery <file> [cluster]
[positional-arguments]
bao-recovery *args:
    scripts/bao-recovery "$@"
