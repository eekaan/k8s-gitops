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

# Roll a cluster's configuration out: show what would change, then apply once its name is typed back (--yes: without asking; --onboard: configure new nodes too; --reboot: afterwards reboot, one at a time, the nodes whose change takes effect only at a reboot, such as etcd's arguments, which are otherwise only named, with --tolerate <seconds> and --no-bgp-wait passed to each reboot, so --no-bgp-wait, which skips only the wait for a worker's withdrawal, applies to every worker it reboots; --first <node>: apply to that node and then each other one alone in Talos' try mode, which reverts by itself, and keep it only once the paths into it from the other nodes, its readiness and cluster-check pass)
[positional-arguments]
cluster-talos *args:
    scripts/cluster-talos "$@"

# Take an etcd snapshot of a cluster, encrypt it to the Talos age key's recipient and upload only the encrypted file to the etcd backup bucket as <cluster>/<UTC time>.snapshot.age; prints its name and size
cluster-snapshot cluster='lab-sto2':
    scripts/cluster-snapshot {{ quote(cluster) }}

# List a cluster's etcd snapshots in the etcd backup bucket, newest first, by name and size
cluster-snapshots cluster='lab-sto2':
    scripts/cluster-snapshots {{ quote(cluster) }}

# Before a cluster is taken down, take and check a last copy of everything the rebuild restores from, as just cluster-last-copies <openbao file> <volsync file> <postgres file> [cluster] [--check]: first compare the Talos and Flux age keys and the three custody files with what the cluster holds, reading only, then print the plan (--check: stop there), then take an OpenBao snapshot and check it, a dump of each database, checked, and its WAL archived through a segment switched now, and a backup of each volume by VolSync's manual trigger with its Kustomization suspended meanwhile; prints one line per copy, nothing of a key, password, address or bucket; every wait bounded by LAST_COPIES_TIMEOUT; see docs/runbooks/rebuild.md
[positional-arguments]
cluster-last-copies *args:
    scripts/cluster-last-copies "$@"

# List a PostgreSQL database's dumps in the postgres backup bucket, newest first, by name and size, reading only; with no database named (just postgres-dumps [cluster]) list the databases that have a dump, as <namespace>/<name>; the namespace and name are those of the database's Cluster
[positional-arguments]
postgres-dumps *args:
    scripts/postgres-dumps "$@"

# Prove that a PostgreSQL database's dump can be restored from, printing counts and nothing of its contents: download the dump (latest: the newest) into a private directory on a memory-backed filesystem where there is one, check it begins with the age header, decrypt it with the Talos age key, have pg_restore --list read it from the cluster's PostgreSQL image with docker or podman, no network, and print its name, sizes, format, PostgreSQL version, time and number of tables, empty ones included; an archive without a table fails; everything is removed on every exit; see docs/runbooks/postgres-restore.md
postgres-dump-check namespace name dump='latest' cluster='lab-sto2':
    scripts/postgres-dump-check {{ quote(namespace) }} {{ quote(name) }} {{ quote(dump) }} {{ quote(cluster) }}

# Restore a cluster's etcd from a snapshot cluster-snapshots lists, or latest: download and decrypt it, then once the cluster's name is typed back reset the control planes' EPHEMERAL partitions, bootstrap etcd from the snapshot and wait until every node is Ready (--yes: without asking)
[positional-arguments]
cluster-restore snapshot *args:
    scripts/cluster-restore "$@"

# Check a cluster's health, reading only: /readyz through the kubeconfig, every node Ready and as many as talman.yaml lists, no Ready worker out of BGP, no kube-proxy, every pod in kube-system and flux-system Running or Succeeded, no certificate signing request Pending, a pod's logs fetched, no scrape target of the cluster's own components down in Prometheus; pass, FAIL or skip per check
cluster-check cluster='lab-sto2':
    scripts/cluster-check {{ quote(cluster) }}

# Check a cluster's public Gateway, reading only: the Gateway Accepted and Programmed at the GATEWAY_ADDRESS of cluster-config, its proxies' labelled LoadBalancer Service holding that address, two proxies Ready on different nodes, its certificate Ready, no route accepted from a namespace without the opt-in label; then through each edge's floating address with curl --resolve, plain HTTP answered with a 301 to https, HTTPS verified against the cluster CA's certificate serving the demo's page and a 404 for a host no route serves; then each routed host's A records at a public resolver, exactly the two edges' addresses, and one request by the name alone; pass, FAIL or skip per line, no address; see docs/kubernetes.md, Checking the public Gateway
gateway-check cluster='lab-sto2':
    scripts/gateway-check {{ quote(cluster) }}

# Check each OCIRepository of a cluster against signatures.yaml, reading only: one whose row the cluster verifies has exactly its row's verify block and is Ready and verified for its current generation, every other has no block; pass or FAIL per object, by namespace and name, with the condition's reason; see docs/kubernetes.md, Signatures
cluster-signatures cluster='lab-sto2':
    scripts/cluster-signatures {{ quote(cluster) }}

# List, changing nothing, the flows the network policies drop or, in audit mode, would drop: the last DROPPED and AUDIT flows of each Cilium agent, read by its own hubble through kubectl exec, so the kubeconfig needs exec on the agents' pods in kube-system; counted by source, destination and port, pod names and ports only and no address; NETWORK_DROPS_LAST bounds the flows asked of each agent (500) and NETWORK_DROPS_TIMEOUT the seconds each call may take (60); see docs/kubernetes.md, Network policy
network-drops cluster='lab-sto2':
    scripts/network-drops {{ quote(cluster) }}

# Print, changing nothing, the record of the flows the network policies dropped or, in audit mode, would have dropped over a window that ends now (24h when none is given; a whole number with s, m, h, d or w): the lines the flow recorder in security-system wrote, counted by the log store and read as just logs reads it, through the Kubernetes API's service proxy; one line per COUNT VERDICT NAMESPACE DIRECTION SOURCE DESTINATION PORT/PROTOCOL REASON, the most frequent first, a pod under its workload, names and ports only and no address; then, on standard error, how many of the recorder's lines are not flows and whether the recorder ran through the window; fails when it did not, when its pod cannot be listed, when the answer is cut at 10000 groups, and with just logs' own reason when the API does not answer or the store refuses the query; see docs/kubernetes.md, The record of what policy drops
network-audit since='24h' cluster='lab-sto2':
    scripts/network-audit {{ quote(since) }} {{ quote(cluster) }}

# Forward a local port, GRAFANA_PORT or 3000, on 127.0.0.1 only, to Grafana on a cluster through its kubeconfig until Ctrl-C; prints the local URL and where the admin password is kept, never the password
grafana cluster='lab-sto2':
    scripts/grafana {{ quote(cluster) }}

# Forward a local port, LOCUST_PORT or 8089, on 127.0.0.1 only, to Locust's master on a cluster through its kubeconfig until Ctrl-C; prints the local URL and that the interface has no sign-in, so that anything on this machine can start a test through it while the forward runs
locust cluster='lab-sto2':
    scripts/locust {{ quote(cluster) }}

# Print the logs a LogsQL query matches, one line per record, the oldest first, through the Kubernetes API's service proxy to VictoriaLogs: just logs 'kubernetes.pod_namespace:monitoring error' [--since 15m] [--limit 200] [cluster]; --since is a number with s, m, h, d or w; fails with the reason when the API does not answer or the store refuses the query
[positional-arguments]
logs *args:
    scripts/logs "$@"

# Reboot one node, by its hostname in talman.yaml, once its name is typed back (--yes: without asking), asking /readyz through the kubeconfig once a second until the node is Ready again, a control plane with its etcd member, which is rebooted only while etcd has every control plane as a healthy member, a worker taken out of BGP first and put back once it is Ready and its Cilium agent has stayed Ready since the reboot; fails when a probe failed (--tolerate <seconds>: accept a gap that long; --no-bgp-wait: do not wait for a worker's BGP configuration to go, as when its Cilium agent is not running, and still wait for the agent before the worker is put back)
[positional-arguments]
cluster-reboot node *args:
    scripts/cluster-reboot "$@"

# Destroy a cluster's stack, sto2/cluster, once the cluster owns no Service of type LoadBalancer and no PersistentVolume of a CSI driver and the stack's name is typed back (--yes: without asking; --unreachable: also when the API does not answer); the plumbing stack and the secrets bundle stay
[positional-arguments]
cluster-destroy *args:
    scripts/cluster-destroy "$@"

# Upgrade Talos to the version talman.yaml gives: show which nodes are behind, then snapshot etcd and drain, upgrade and uncordon each in turn once the cluster's name is typed back, a worker taken out of BGP first and put back once it is Ready and its Cilium agent has stayed Ready since the upgrade (--yes: without asking; --no-bgp-wait: do not wait for the BGP configuration of any worker the run takes out to go, as when a worker's Cilium agent is not running, and still wait for the agent before the worker is put back)
[positional-arguments]
cluster-upgrade *args:
    scripts/cluster-upgrade "$@"

# Upgrade Kubernetes to the version talman.yaml gives: show what would change, then snapshot etcd and upgrade once the cluster's name is typed back (--yes: without asking)
[positional-arguments]
cluster-upgrade-k8s *args:
    scripts/cluster-upgrade-k8s "$@"
