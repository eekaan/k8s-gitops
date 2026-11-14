# Render every node's Talos machine configuration from the template, the patches and fixture node data, and validate it, offline
talos-check: tools-check
    scripts/talos-check

# Install Cilium from its application in kubernetes/ on the cluster KUBECONFIG names, before Flux runs; a release Flux manages is refused (--yes: installed over)
[positional-arguments]
cilium-install *flags:
    scripts/install-cilium "$@"

# Install an application from kubernetes/, such as kubernetes/apps/base/kube-system/kubelet-csr-approver, on the cluster KUBECONFIG names before Flux runs, as the release Flux adopts; a release Flux manages is refused (--yes: installed over)
[positional-arguments]
app-install path *flags:
    scripts/install-app "$@"

# Watch Flux adopt an application installed before it, such as kubernetes/apps/base/kube-system/cilium, on a cluster (lab-sto2 when none is given), reading only; start it before Flux adopts it. Prints pass or FAIL for one release, the bootstrap revision followed by helm-controller's, the HelmRelease Ready and every node Ready
[positional-arguments]
app-adoption path *args:
    scripts/app-adoption "$@"

# Create the Talos age key at SOPS_AGE_KEY_FILE unless a file is there, and write its recipient into talos/.sops.yaml; prints the recipient
cluster-age-key:
    scripts/cluster-age-key

# Generate a cluster's Talos secrets bundle into talos/<cluster>/secrets.sops.yaml, SOPS-encrypted; refused when the bundle exists
cluster-secrets cluster='lab-sto2':
    scripts/cluster-secrets {{ quote(cluster) }}

# Fail on a secrets.sops.yaml under talos/ that git would commit without SOPS encryption
cluster-secrets-check:
    scripts/cluster-secrets-check

# Build a cluster from nodes in maintenance mode: wait for every node, talman apply --bootstrap, fetch the kubeconfig, install Cilium, apply what Flux needs before it starts, install the kubelet serving-certificate approver, wait until every node is Ready
cluster-bootstrap cluster='lab-sto2':
    scripts/cluster-bootstrap {{ quote(cluster) }}

# Create the Flux age key at FLUX_AGE_KEY_FILE unless a file is there, and write its recipient into .sops.yaml; prints the recipient
cluster-flux-age-key:
    scripts/cluster-flux-age-key

# Apply what Flux needs before it starts to a cluster: the namespace flux-system, the ConfigMap cluster-config, the Secret cluster-secrets and the Secret sops-age with the Flux age key
cluster-config cluster='lab-sto2':
    scripts/cluster-config {{ quote(cluster) }}

# Install Flux on a cluster without it: what Flux needs before it starts, the Flux Operator and the FluxInstance from kubernetes/clusters/<cluster>/flux-system/, then wait until it is Ready (--reapply: on a cluster that runs Flux, apply what Flux needs before it starts again, and install nothing)
[positional-arguments]
cluster-flux *args:
    scripts/cluster-flux "$@"

# Fetch a cluster's admin kubeconfig into talos/<cluster>/clusterconfig/kubeconfig, mode 0600, served at KUBE_API_ADDRESS; prints its path
cluster-kubeconfig cluster='lab-sto2':
    scripts/cluster-kubeconfig {{ quote(cluster) }}

# Roll a cluster's configuration out: show what would change, then apply once its name is typed back (--yes: without asking; --onboard: configure new nodes too)
[positional-arguments]
cluster-talos *args:
    scripts/cluster-talos "$@"

# Take an etcd snapshot of a cluster, encrypt it to the Talos age key's recipient and upload only the encrypted file to the etcd backup bucket as <cluster>/<UTC time>.snapshot.age; prints its name and size
cluster-snapshot cluster='lab-sto2':
    scripts/cluster-snapshot {{ quote(cluster) }}

# List a cluster's etcd snapshots in the etcd backup bucket, newest first, by name and size
cluster-snapshots cluster='lab-sto2':
    scripts/cluster-snapshots {{ quote(cluster) }}

# Restore a cluster's etcd from a snapshot cluster-snapshots lists, or latest: download and decrypt it, then once the cluster's name is typed back reset the control planes' EPHEMERAL partitions, bootstrap etcd from the snapshot and wait until every node is Ready (--yes: without asking)
[positional-arguments]
cluster-restore snapshot *args:
    scripts/cluster-restore "$@"

# Upgrade Talos to the version talman.yaml gives: show which nodes are behind, then snapshot etcd and drain, upgrade and uncordon each in turn once the cluster's name is typed back (--yes: without asking)
[positional-arguments]
cluster-upgrade *args:
    scripts/cluster-upgrade "$@"

# Upgrade Kubernetes to the version talman.yaml gives: show what would change, then snapshot etcd and upgrade once the cluster's name is typed back (--yes: without asking)
[positional-arguments]
cluster-upgrade-k8s *args:
    scripts/cluster-upgrade-k8s "$@"
