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

# Destroy the cluster stack, then the plumbing stack, each once its name is typed back (--yes: without asking); the cluster is asked first for the load balancers and volumes it owns outside the stack, and is not destroyed while it owns any or cannot be asked (--unreachable: unless the API does not answer); given one stack, or sto2/ci or sto2/edge, which only their names destroy, that one only; the plumbing stack is not destroyed while another stack still holds a resource, and the edge stack not while a name the tree's routes publish under CLUSTER_DOMAIN resolves at the public resolver to one of its addresses or cannot be looked up, each named by its label, nor while its addresses are not known (--ignore-dns, with sto2/edge alone: destroyed all the same, the names still listed); --check makes every refusal and stops before each plan, planning and destroying nothing
[positional-arguments]
infra-destroy *args:
    scripts/infra-destroy "$@"

# Make the CI host of the sto2/ci stack this repository's GitHub Actions runner, over SSH: the pinned Dagger engine with its state on the cache volume, the pinned runner, checksum verified, registered with a token from gh and run as a service; a host key not yet recorded is checked against the instance's console: recorded without a prompt when the console holds every key offered, refused when it holds another, and shown and recorded once yes is typed when it holds none; a second run changes nothing; see docs/runbooks/ci-host.md
ci-host-setup:
    scripts/ci-host-setup

# Stop and deregister the CI host's runner, with a remove token from gh; the engine and its cache stay
ci-host-remove:
    scripts/ci-host-remove

# Print the runner the CI workflow's check jobs run on, as JSON: CI_RUNNER_LABEL, the CI host's runner, for a job the host admits (a push to main or a pull request from a branch of this repository), ubuntu-latest otherwise or without the label; in a GitHub Actions step, also set it as the step's output runner
[script]
ci-runner:
    set -o pipefail
    . scripts/lib/ci-host.sh
    runner=ubuntu-latest
    label=${CI_RUNNER_LABEL-}
    if [[ -n $label ]]; then
      if [[ ! $label =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "ci-runner: CI_RUNNER_LABEL is not a runner label" >&2
        exit 1
      fi
      if reason=$(ci_host_admits 2>&1); then
        runner=$label
      else
        echo "ci-runner: on a hosted runner, as the CI host does not run $reason" >&2
      fi
    fi
    runner=$(jq -cn --arg runner "$runner" '$runner')
    echo "$runner"
    if [[ -n ${GITHUB_OUTPUT-} ]]; then
      echo "runner=$runner" >> "$GITHUB_OUTPUT"
    fi

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

# List the names of the public images the cloud offers, one per line, optionally only those containing a pattern, so that EDGE_IMAGE and CI_HOST_IMAGE can be chosen without a console; reads only and prints nothing but names
os-images pattern='':
    scripts/os-images {{ quote(pattern) }}

# Create the SSH key pair of the edge routers at EDGE_SSH_KEY_FILE, mode 0600 and without a passphrase, unless a key is there; says only whether it created one
edge-ssh-key:
    scripts/edge-ssh-key

# Check, reading only and over SSH, that both edge routers serve (or only edge 1 or 2): FRR runs, every worker has an established session, the table holds only /32s inside the service range, the reject route for the range is configured and in the kernel, the rules are loaded and nothing of the loaded ruleset translates an address, the forward chain forwards nothing, the output chain's guard keeps the proxy's connections to the Gateway on a worker's route, the proxy runs as its own user, listens on the public ports alone and sends the PROXY protocol header, the kernel forwards, unattended upgrades are off, and the SSH daemon runs with the first boot's settings; pass, FAIL or skip per line, no address; a host key not yet recorded is checked against the instance's console, and shown and recorded once yes is typed when the console holds no fingerprints or cannot be read: the yes is read from standard input, one line for each such edge; see docs/runbooks/edge.md
[positional-arguments]
edge-check *args:
    scripts/edge-check "$@"

# Print an edge router's BGP sessions and learned routes, with addresses, for a person learning the protocol; to a terminal only, refused in CI and in a pipe
edge-routes edge='1':
    scripts/edge-routes {{ quote(edge) }}

# Replace the edge routers one at a time after a change to their configuration, once the stack's name is typed back (--yes: without asking): replace one, wait until edge-check passes for it, then the other; stops at the first edge that does not pass. --replace replaces each edge's instance and boot volume even when the configuration is unchanged, which is how a new image reaches them; --edge N replaces edge N alone, and --other-down goes on with the other edge down once a sentence naming both is typed back. What is typed, the stack's name, that sentence and yes for a host key its instance's console does not vouch for, is read from standard input, one line each, in the order it is asked
[positional-arguments]
edge-rollout *flags:
    scripts/edge-rollout "$@"
