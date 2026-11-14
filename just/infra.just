# Format-check, validate and tofu test every OpenTofu stack, without credentials or a state backend
infra-check: tools-check
    scripts/infra-check

# Plan a stack such as sto2/plumbing; prints counts per action and resource type, never the plan
infra-plan stack:
    scripts/infra-plan {{ quote(stack) }}

# Plan a stack such as sto2/plumbing, print the plan's summary, and apply that plan once the stack's name is typed back (--yes: without asking); after the cluster stack, write its talman.yaml as infra-talman does
[positional-arguments]
infra-apply stack *flags:
    scripts/infra-apply "$@"

# Remove the Talos image from the plumbing stack's state, leaving it in the cloud, once the stack's name is typed back (--yes: without asking); see docs/runbooks/image-replacement.md
[positional-arguments]
infra-forget-image *flags:
    scripts/infra-forget-image "$@"

# Write talos/<cluster>/talman.yaml from the cluster stack's output, mode 0600 and never printed, once talman computes the image's schematic and validates it
infra-talman stack='sto2/cluster':
    scripts/infra-talman {{ quote(stack) }}

# Print one non-sensitive output of a stack, such as: just infra-output sto2/plumbing talos_version
infra-output stack name:
    scripts/infra-output {{ quote(stack) }} {{ quote(name) }}

# Destroy the cluster stack, then the plumbing stack, each once its name is typed back (--yes: without asking); given one of them, such as sto2/cluster, that one only
[positional-arguments]
infra-destroy *args:
    scripts/infra-destroy "$@"

# Check the OpenStack credential, quota, flavors and external network; pass or FAIL per item, no figures
os-smoke:
    scripts/os-smoke

# Create the state bucket TF_STATE_BUCKET names through the S3 API with the state key, unless it exists; prints neither its name nor a credential
infra-state-bucket:
    scripts/infra-state-bucket

# Create an S3 key pair for the state or the cluster key set and write it to .env, unless a name there already holds one; never shows either value
infra-s3-key keyset:
    scripts/infra-s3-key {{ quote(keyset) }}

# Create the etcd, openbao, volsync and postgres buckets under BACKUP_BUCKET_PREFIX through the S3 API with the state key, unless they exist; names them by role only
infra-backup-buckets:
    scripts/infra-backup-buckets

# Check that the cluster's S3 key is not the state key and lists each backup bucket; pass or FAIL per item, no names or keys
infra-backup-check:
    scripts/infra-backup-check
