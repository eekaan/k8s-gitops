# Rotate one secret of an application that secret-rotation.yaml lists as generated, as just secret-rotate <path> <key> [--yes] [--wait <seconds>], with the path and the key as bao-put takes them: reads the ExternalSecrets that read the key, the workloads that mount their Secrets and the pods, shows what it will do and asks for the path to be typed back; then makes a new value from 32 random bytes of the kernel, writes it to OpenBao with bao-put, has each ExternalSecret refresh, waits for Reloader to restart the workloads, each wait up to --wait seconds (300), and proves from SHA-256 digests taken in the pods that every pod is a new one that holds the new value; prints neither a value nor a digest
[positional-arguments]
secret-rotate *args:
    scripts/secret-rotate "$@"
