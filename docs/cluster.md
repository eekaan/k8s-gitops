# The cluster

The Talos cluster is created and changed by `just` recipes that check what they need before they
run anything. Each recipe that works on one cluster takes its name, `lab-sto2` when none is given,
and works in `talos/<cluster>/`: on `talman.yaml`, which the cluster stack renders, `just
infra-apply sto2/cluster` and `just infra-talman` write, and git ignores; on `secrets.sops.yaml`,
the cluster's encrypted secrets bundle, which is committed; and on talman's output directory
`clusterconfig/`, which git ignores and which holds the machine configurations, the talosconfig
and the kubeconfig.

## From nothing to a Ready cluster

1. `just infra-apply sto2/plumbing`, then `just infra-apply sto2/cluster`
   ([infrastructure.md](infrastructure.md)): the nodes boot and wait in maintenance mode, and
   the cluster's `talman.yaml` is written. `just infra-talman` writes it again from the stack's
   state, without applying.
2. `just cluster-age-key`, once: the Talos age key. Commit `talos/.sops.yaml`.
3. `just cluster-secrets`, once per cluster: the secrets bundle. Commit it.
4. `just cluster-flux-age-key`, once: the Flux age key. Commit `.sops.yaml`.
5. `just cluster-bootstrap`: every node configured, Cilium installed, what Flux needs before it
   starts applied, the kubelet serving-certificate approver installed, every node Ready.
6. `just cluster-flux`: what Flux needs before it starts applied, and Flux installed
   ([kubernetes.md](kubernetes.md#installing-flux)). To see Flux take over Cilium without a node
   leaving Ready, start `just app-adoption kubernetes/apps/base/kube-system/cilium` in a second
   terminal first ([kubernetes.md](kubernetes.md#applications-installed-before-flux)).

`just cluster-check` then says whether the cluster is healthy. Later changes to a patch or to
`talman.yaml`, and nodes OpenTofu adds, reach the nodes with `just cluster-talos`.
[runbooks/rebuild.md](runbooks/rebuild.md) takes a running cluster down to nothing with
`just cluster-destroy` and builds it again.

## The node image

The nodes boot the image the Image Factory builds from `talos/schematic.yaml`, and install and
upgrade from its installer for the same schematic. Talos activates system extensions only when it
installs or upgrades
([Talos](https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/custom-images-and-development/system-extensions)),
so a running node gets a new one through `just cluster-upgrade`, and configuration that depends on
it follows with `just cluster-talos`
([runbooks/image-replacement.md](runbooks/image-replacement.md)). The image carries three official
extensions:

- `siderolabs/drbd`: the DRBD kernel modules, for the storage layer, LINSTOR through the Piraeus
  operator on DRBD, with LVM-thin storage pools and snapshots. Nothing in this repository installs
  that layer. An extension's modules load only when the machine configuration lists them, and on
  Talos the LINSTOR satellite cannot load a module itself
  ([Piraeus](https://github.com/piraeusdatastore/piraeus-operator/blob/v2/docs/how-to/talos.md)),
  so `talos/patches/all/kernel-modules.yaml` has every node load `drbd`, with its user-mode helper
  scripts disabled, its TCP transport `drbd_transport_tcp`, `dm-thin-pool` for LVM-thin pools and
  `dm-snapshot` for snapshots, which the Talos kernel has built in.
- `siderolabs/gvisor`: gVisor, which registers the containerd runtime handler `runsc`; the
  RuntimeClass `gvisor` selects it ([kubernetes.md](kubernetes.md#runtime-classes)). The
  extension's README says gVisor requires unprivileged user namespace creation
  ([gVisor extension](https://github.com/siderolabs/extensions/blob/main/container-runtime/gvisor/README.md)),
  which Talos turns off as the KSPP recommends (`user.max_user_namespaces` is 0), and no patch here
  turns it on.
- `siderolabs/kata-containers`: Kata Containers, which registers the containerd runtime handlers
  `kata`, on Cloud Hypervisor, and `kata-qemu`; the RuntimeClass `kata` selects the first. Kata
  runs each pod in a virtual machine of its own and needs hardware virtualisation on the node, which
  on a cloud instance means nested virtualisation
  ([Kata Containers](https://github.com/kata-containers/kata-containers/blob/main/docs/install/README.md)).
  On a node without it, a pod that selects `kata` does not start.

No workload selects either runtime class. `infra-check` refuses the QEMU guest agent extension
([runbooks/image-replacement.md](runbooks/image-replacement.md)).

## Upgrades

The Talos and Kubernetes versions are set in `versions.yaml` only, and reach the recipes through
the cluster's `talman.yaml`; the upgrade recipes take no version. The cluster stack renders
`talman.yaml` from `versions.yaml` when it is applied; `just infra-talman` writes what the stack's
state holds, so it does not pick a new version up.

A new Talos version, like a change to `talos/schematic.yaml`, gives the plumbing stack a new image.
[runbooks/image-replacement.md](runbooks/image-replacement.md) takes it from
`just infra-forget-image` to `just cluster-upgrade`, and a new Kubernetes version in the same
change on to `just cluster-upgrade-k8s`. After a new Kubernetes version alone:

1. `just infra-apply sto2/cluster`: its plan changes the output `talman_yaml` and no node, and the
   apply writes the new `talman.yaml`.
2. `just cluster-upgrade-k8s` moves the cluster to the Kubernetes version.

## The Talos age key

The secrets bundle holds the cluster's certificate authorities and keys. It is encrypted with sops
to one age key, the Talos age key, which the operator holds and CI gets as a secret; it never
enters the repository or the cluster (ADR 0005). The key Flux decrypts `kubernetes/` with is
another one, [the Flux age key](#the-flux-age-key), so a key held in the cluster does not open the
bundle.

Without the key the bundle cannot be decrypted, and no machine configuration, talosconfig or
kubeconfig can be made for the running cluster. Keep a copy of it away from the machine it was
made on.

`talos/.sops.yaml` holds its recipient, the public half, and a rule that matches
`secrets.sops.yaml` one directory below `talos/` and nothing else. talman hands sops that file and
the bundle's path itself, so the rule applies wherever talman runs from.

## The Flux age key

The SOPS files under `kubernetes/`, such as a cluster's `cluster-secrets`
([kubernetes.md](kubernetes.md#before-flux-starts)), are encrypted to the Flux age key. The operator
holds it, CI gets it as a secret, and the cluster holds it as the Secret `sops-age`, which Flux
decrypts with. The recipes refuse the Talos age key in its place.

`.sops.yaml` at the repository root holds its recipient and a rule that matches `*.sops.yaml`
under `kubernetes/` and nothing else, encrypting only `data` and `stringData`, so a Secret's kind,
name and keys stay readable. sops reads the nearest `.sops.yaml` above the directory it runs in,
and matches the rule against the file's path relative to that `.sops.yaml`. At the root it is
found from anywhere in the repository but `talos/`, where `talos/.sops.yaml` is nearer and matches
nothing under `kubernetes/`, so sops refuses rather than encrypt to the Talos age key; and it stays
out of the artifact, which is built from `kubernetes/`.

## Recipes

- `just cluster-age-key` creates the key with `age-keygen` at the path `SOPS_AGE_KEY_FILE` names,
  with mode 0600, unless a file is there, and writes its recipient into `talos/.sops.yaml` in place
  of the placeholder. It prints the recipient and nothing else. A second run changes nothing. It
  refuses a path inside the repository, and a `talos/.sops.yaml` that names another recipient,
  which it leaves as it is.
- `just cluster-flux-age-key` creates the Flux age key with `age-keygen` at the path
  `FLUX_AGE_KEY_FILE` names, with mode 0600, unless a file is there, and writes its recipient into
  `.sops.yaml` in place of the placeholder. It prints the recipient and nothing else. A second run
  changes nothing. It refuses a path inside the repository, the Talos age key, and a `.sops.yaml`
  that names another recipient, which it leaves as it is.
- `just cluster-secrets [cluster]` generates the bundle with `talman secrets generate`, which
  encrypts it by the rule in `talos/.sops.yaml`. It refuses when the cluster's `talman.yaml` is
  missing, while `talos/.sops.yaml` holds the placeholder, and when the bundle exists: a new bundle
  would not be trusted by the cluster's nodes. Afterwards it checks that the bundle has SOPS
  metadata and that every value in it is ciphertext; when not, it fails and leaves the file in
  place, to be removed without being committed.
- `just cluster-secrets-check`, part of `just ci`, fails on a `secrets.sops.yaml` anywhere under
  `talos/` that git tracks or would commit and that is not encrypted that way, naming the file
  and nothing of its content. It does not read `talos/.sops.yaml`, so the placeholder neither
  passes nor fails it; sops refuses to encrypt to the placeholder, so no bundle exists while it is
  there.
- `just cluster-bootstrap [cluster]` builds the cluster from nodes waiting in maintenance mode.
  It refuses, naming each, when the cluster's `talman.yaml` or `secrets.sops.yaml`, the age key's
  location or the API address is missing, or when `cluster-config` would refuse. Then, in order:
  1. It waits until every node in `talman.yaml` answers on the Talos API port, 50000, at the
     address talman reaches it on, for up to `TALOS_WAIT` seconds. It fails naming the nodes that
     did not answer; rebooting one is left to the operator.
  2. `talman apply --bootstrap --onboard-new-nodes` configures the first control plane, starts
     etcd on it, and configures the other nodes after it, one at a time.
  3. `just cluster-kubeconfig` fetches the kubeconfig.
  4. `scripts/install-cilium` installs Cilium through it
     ([kubernetes.md](kubernetes.md#applications-installed-before-flux)).
  5. `just cluster-config` applies what Flux needs before it starts, the approver's values among
     it.
  6. `scripts/install-app` installs the kubelet serving-certificate approver with those values.
     The kubelets request their serving certificates from the cluster
     (`talos/patches/all/kubelet.yaml`), and until the approver approves them, `kubectl logs` and
     `kubectl exec` fail.
  7. It waits until every node in `talman.yaml` is a Ready Kubernetes node.

  A second run is refused by talman, which bootstraps only when every control plane answers and
  none runs etcd. A bootstrap that stopped once etcd was running is therefore not run again: the
  nodes it did not reach are configured with `just cluster-talos --onboard`, and the steps after
  it are run by their own recipes, the approver's by
  `just app-install kubernetes/apps/base/kube-system/kubelet-csr-approver` with `KUBECONFIG` set to
  the cluster's kubeconfig. No health check runs: `talosctl health`, reaching the nodes through
  their floating addresses, compares those with the addresses the nodes hold on the node network,
  which differ by design, so it never passes.
- `just cluster-kubeconfig [cluster]` fetches the admin kubeconfig with `talman kubeconfig` into
  `clusterconfig/kubeconfig`, with mode 0600, and points it at `https://KUBE_API_ADDRESS:6443`:
  talman writes the cluster endpoint, the load balancer's address on the node network, which only
  the nodes reach. It prints the file's path. The recipes that use the cluster read it from there.
- `just cluster-talos [cluster] [--onboard] [--yes]` rolls the configuration out: the cluster's
  `talman.yaml` and the patches it lists, as they are now. It waits for every node as
  `cluster-bootstrap` does, then shows what `talman apply --dry-run` says would change on each
  node, with the cluster's secrets redacted, and applies once the cluster's name is typed back;
  `--yes` does not ask. talman applies one node at a time, control planes always alone, rebooting
  a node only when the change needs it and waiting for each to come back before the next. A node
  in maintenance mode, such as one OpenTofu has just added, is configured only with `--onboard`:
  the maintenance service authenticates nothing, and a node's configuration carries the cluster's
  keys. Without it, talman refuses a rollout while such a node is there. With nothing to change,
  nothing is asked or applied. It needs the cluster's `talman.yaml` and `secrets.sops.yaml` and
  the age key's location.
- `just cluster-upgrade [cluster] [--yes]` upgrades Talos on every node that does not run the
  version and schematic `talman.yaml` gives it. It shows which nodes `talman upgrade --dry-run`
  says are behind, and once the cluster's name is typed back, or with `--yes`, fetches the
  kubeconfig as `cluster-kubeconfig` does, takes an etcd snapshot with `talman etcd snapshot`, and
  goes through the nodes in `talman.yaml`'s order, one at a time. A node that is behind is drained
  with `kubectl drain`, upgraded with `talman upgrade`, and uncordoned once it is Ready, before the
  next is drained; a node on its version is left alone. Before each drain the API must answer
  `/readyz` through the kubeconfig within five minutes, or nothing more is drained. talosctl's own
  drain is turned off, as it reaches the API at the cluster endpoint, which only the nodes reach.
  At the end every node must run its version. A run that stops after draining a node leaves that
  node cordoned: uncordon it with kubectl once it is back; a second run skips it once it is on its
  version.
- `just cluster-upgrade-k8s [cluster] [--yes]` upgrades Kubernetes to the version `talman.yaml`
  gives. It shows what `talman upgrade-k8s --dry-run` says, and once the cluster's name is typed
  back, or with `--yes`, runs `talman upgrade-k8s` with an etcd snapshot first; talosctl moves the
  control plane components and the kubelets node by node. It reaches the API at
  `KUBE_API_ADDRESS`, given to talosctl as its endpoint. At the end every node must run the
  version.

  Both upgrade recipes do nothing and ask nothing when every node runs its version, and need what
  `cluster-talos` needs and the API address. An etcd snapshot holds every Secret in the cluster;
  talman writes it
  into `clusterconfig/` with mode 0600, and it stays there.
- `just cluster-snapshot [cluster]` keeps an etcd snapshot, encrypted, in the etcd backup bucket,
  `BACKUP_BUCKET_PREFIX` followed by `-etcd`
  ([infrastructure.md](infrastructure.md#s3-keys-and-backup-buckets)). `talman etcd snapshot`
  writes it into a private temporary directory, mode 0700, under `TMPDIR` and outside the
  repository; age encrypts it there to the Talos age key's recipient in `talos/.sops.yaml`, which
  needs no private key; the plaintext is removed; and only the encrypted file is uploaded, with the
  state key, as `<cluster>/<UTC time>.snapshot.age`, the time as `yyyymmddThhmmssZ`. The upload
  passes rclone's `--s3-no-check-bucket`, so it never creates a bucket: without the etcd bucket it
  fails. An object of the same name, from a snapshot taken in the same second, is not overwritten:
  the recipe fails, naming it. Once the bucket lists the object at the size uploaded, it prints one
  line, the cluster, the object's name and its size. The directory is removed whenever the recipe
  exits, a failed run and one interrupted by Ctrl-C or SIGTERM included. It needs the cluster's
  `talman.yaml` and `secrets.sops.yaml`, the age key's location and its recipient, the bucket
  prefix and the state key.
- `just cluster-snapshots [cluster]` lists the cluster's snapshots in the etcd bucket, reading only:
  one per line, newest first, by name and size in bytes. It needs the bucket prefix and the state
  key.
- `just cluster-restore <snapshot> [cluster] [--yes]` restores the cluster's etcd from a snapshot
  `cluster-snapshots` lists, or from `latest`, into the same nodes with the same secrets bundle;
  [runbooks/etcd-restore.md](runbooks/etcd-restore.md) says when, and what is lost. Before it
  changes anything it checks what it needs, finds the snapshot, downloads it into a private
  temporary directory as `cluster-snapshot` makes one, decrypts it there with the Talos age key, and
  waits for every node as `cluster-bootstrap` does; a snapshot that is not there, is not an age file
  or that the key cannot decrypt stops it. It says that the control planes are reset, the workers
  not, and the cluster's state replaced by the snapshot's, losing what was written since, and goes
  on once the cluster's name is typed back; `--yes` does not ask. `talman reset --group
  controlplane` then wipes each control plane's EPHEMERAL partition without leaving etcd and reboots
  it, and once every node answers again, `talman apply --bootstrap --recover-from` restores etcd
  from the snapshot on the first control plane, which the others join. It fetches the kubeconfig as
  `cluster-kubeconfig` does, and asks every ten seconds, ninety times at most, until every node in
  `talman.yaml`, workers included, reports Ready after the reset. What `cluster-bootstrap` applies
  before Flux is not applied again, as the restored etcd holds it. The decrypted snapshot is removed once etcd is restored and whenever the recipe exits.
  It needs what `cluster-talos` needs, the API address, the bucket prefix and the state key.
- `just cluster-config [cluster]` applies what Flux needs before it starts: the namespace
  `flux-system`, the ConfigMap `cluster-config`, the Secret `cluster-secrets` and the Secret
  `sops-age` ([kubernetes.md](kubernetes.md#before-flux-starts)). It refuses, naming each, when the
  cluster's `talman.yaml` or kubeconfig, `CLUSTER_DOMAIN`, the Flux age key or its recipient in
  `.sops.yaml` is missing, when the Flux age key is not the key of that recipient or is the Talos
  age key, and when a key of `cluster-config` or `cluster-secrets` cannot be filled or is not
  listed. A second run changes nothing.
- `just cluster-flux [cluster] [--reapply]` installs Flux on a cluster that runs none
  ([kubernetes.md](kubernetes.md#installing-flux)). It needs what `cluster-config` needs.
- `just app-adoption <application directory> [cluster]` watches Flux adopt an application that
  was installed before it and prints pass or FAIL per check; it only reads
  ([kubernetes.md](kubernetes.md#applications-installed-before-flux)).
- `just cluster-check [cluster]` says, reading only, whether the cluster is healthy, through its
  kubeconfig, which points at the API load balancer. It prints pass, FAIL or skip and one line of
  why for each check, and exits 0 only when none fails: `/readyz` answers; every node is Ready, a
  FAIL naming those that are not; there are as many nodes as the cluster's `talman.yaml` lists, a
  FAIL naming those missing and those it does not list; no kube-proxy pod runs anywhere; every pod
  in `kube-system` and in `flux-system` is Running or Succeeded, a FAIL naming the others; no
  certificate signing request is Pending; and kubectl fetches the last log line of a Running pod in
  `kube-system`, which the API server reads from the pod's kubelet over the kubelet's serving
  certificate. While the namespace `flux-system` does not exist, as before `just cluster-config`
  has run, the check of its pods is skipped, and its line and the last line say so. It runs
  `kubectl get` and `kubectl logs` only. It needs the cluster's `talman.yaml` and kubeconfig.
- `just cluster-reboot <node> [cluster] [--yes] [--tolerate <seconds>]` reboots one node, named by
  its hostname in the cluster's `talman.yaml`, while it watches the Kubernetes API through its load
  balancer; for a control plane, that is the check that the API does not go away with one. Any
  other name, an address among them, is refused before anything runs; a node kubectl cannot read
  through the kubeconfig, before anything changes. Once the node's name is typed back, or with
  `--yes`, a probe in the background
  asks `/readyz` through the kubeconfig once a second, giving each try two seconds, while the
  recipe, in order:
  1. cordons the node and drains it with `kubectl drain`, as `cluster-upgrade` drains, so nothing
     new is placed on it while it goes down: a kubelet that is shutting down rejects every pod it
     is given, and the scheduler would go on giving it the same replica, each rejected pod left in
     phase Failed;
  2. reboots it with `talman reboot -n <node> --yes`, which waits for it to come back, with
     talosctl's own drain off, as it reaches the API at the cluster endpoint, which only the nodes
     reach;
  3. waits, up to `REBOOT_WAIT` seconds, until the node is Ready with a heartbeat from after the
     reboot, as `cluster-restore` waits for its nodes.

  Then it stops the probe and prints how many probes it made, how many failed and the longest run
  of failures, in seconds. It uncordons the node, unless it was unschedulable before the recipe
  ran: such a node stays cordoned, and the recipe says so. It deletes, by namespace and name, the
  pods the shutdown left in phase Failed on the node, with the reason `NodeShutdown` (rejected
  while it shut down) or `Terminated` (terminated as it went down), which stay until they are
  deleted and on which `cluster-check` fails, and says how many, none included; every other pod
  stays. It exits 0 only when the node is Ready again and no probe failed; `--tolerate <seconds>`
  accepts runs of failures up to that long, for the operator to say what counts as an
  interruption. A run that stops once the node is cordoned, as when the drain, the reboot or the
  wait fails, leaves it cordoned and says so in its last line: uncordon it with kubectl once it is
  Ready. The probe keeps its counts in memory and writes no file; it is stopped, with the kubectl
  or sleep it is waiting for, on every exit of the recipe, a failed or interrupted run included. It
  needs what `cluster-talos` needs and the kubeconfig.
- `just cluster-destroy [cluster] [--yes] [--unreachable]` destroys the cluster stack,
  `sto2/cluster`, as `just infra-destroy sto2/cluster` does
  ([infrastructure.md](infrastructure.md#recipes)): it shows the plan's summary, destroys once the
  stack's name is typed back, or with `--yes`, and then removes the cluster's `talman.yaml`,
  talosconfig and kubeconfig. The plumbing stack, the secrets bundle and the buckets stay. First,
  through the kubeconfig of the cluster it is given, it lists
  every Service of type LoadBalancer and every PersistentVolume of a CSI driver: the cloud's load
  balancers and volumes behind them are made by the cluster, not by OpenTofu, so the destroy would
  leave them in the cloud, where they keep the network from being deleted. While there are any, it
  names each, by namespace and name or by the volume's name, and destroys nothing. A cluster whose
  API does not answer, or that has no kubeconfig, cannot be asked and is not destroyed either,
  unless `--unreachable` is given: the operator then takes on whatever it owned, which stays in the
  cloud. Before it asks the cluster it checks what `infra-destroy` needs for the stack.
  [runbooks/rebuild.md](runbooks/rebuild.md) has it in the procedure around it.

A failing recipe ends with a line naming the step it failed in.

## Not automated

- Rebooting a node that does not answer on the Talos API port.

## What the recipes print

The recipes' own lines name nodes by hostname, never by address, and print none of the age keys,
the bundle, the kubeconfig, `KUBE_API_ADDRESS`, the values of `cluster-config` and
`cluster-secrets`, an etcd snapshot's content, the backup buckets' names and the object storage's
endpoint. talman's output, talosctl's within it, names each node with the address talman
reaches it on and shows configuration diffs. Without `CI` set it passes through as talman prints
it. With `CI` set, as CI logs are public, `cluster-bootstrap`, `cluster-kubeconfig`,
`cluster-talos`, `cluster-reboot`, `cluster-restore`, `cluster-snapshot` and both upgrade recipes
write it to `clusterconfig/<recipe>.log` in the cluster's directory, which git ignores, started
afresh by each run, and print for each talman call only whether it succeeded or failed and that
file's path.
Of talman's output `cluster-snapshot` shows only the errors, and with `CI` set not those either.
What rclone prints names the bucket and the endpoint, so the etcd recipes never show it. kubectl's
and helm's output passes through, naming the objects they apply, except in `cluster-check`,
`cluster-reboot` and `cluster-destroy`: they print node and object names only, and none of what
kubectl prints, as the objects it reads and its errors hold the API server's, the nodes' and the
pods' addresses; only `kubectl drain`'s passes through in `cluster-reboot`, as in
`cluster-upgrade`, naming the pods it evicts and those it cannot.

## Environment

The recipes read `.env` and the environment as the infrastructure recipes do
([infrastructure.md](infrastructure.md#environment)), and name each variable that is missing. No
recipe prints a secret or passes one on a command line. sops and talman get the Talos age key's
location from their environment; `cluster-restore` hands age the key file's path, or, when only
`SOPS_AGE_KEY` holds the key, the key on standard input. `cluster-config` reads the Flux age key,
to hand it to kubectl and age-keygen on standard input.

- `SOPS_AGE_KEY_FILE`: the path of the Talos age key, outside the repository. In CI,
  `SOPS_AGE_KEY` holds the key itself instead. Every recipe that reaches the nodes needs one of
  them, as talman decrypts the bundle, and `cluster-restore` decrypts the snapshot with it.
- `BACKUP_BUCKET_PREFIX`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`: the start of the backup
  buckets' names and the state key ([infrastructure.md](infrastructure.md#environment)), with which
  `cluster-snapshot`, `cluster-snapshots` and `cluster-restore` reach the etcd bucket through
  rclone, configured as the infrastructure recipes configure it
  ([infrastructure.md](infrastructure.md#s3-keys-and-backup-buckets)).
- `TMPDIR`: where `cluster-snapshot` and `cluster-restore` make their private directory, `/tmp`
  when unset. Inside the repository it is refused.
- `KUBE_API_ADDRESS`: the Kubernetes API load balancer's floating address, an IPv4 address, as
  the API's certificate names are addresses. The cluster stack renders it into the cluster's
  `talman.yaml` as `values.apiAddress`, and the recipes read it from there; set in `.env` or the
  environment, it takes the place of that. `cluster-bootstrap`, `cluster-kubeconfig`,
  `cluster-restore` and the upgrade recipes need it. It reaches a command line in one place:
  `cluster-upgrade-k8s` hands it to talosctl as its endpoint.
- `TALOS_WAIT`: how many seconds `cluster-bootstrap`, `cluster-talos` and `cluster-restore` wait
  for the nodes, 600 when unset.
- `REBOOT_WAIT`: how many seconds `cluster-reboot` waits, once talman has rebooted the node, for it
  to report Ready, 600 when unset.
- `FLUX_AGE_KEY_FILE`: the path of the Flux age key, outside the repository. In CI, `FLUX_AGE_KEY`
  holds the key itself instead. `cluster-bootstrap`, `cluster-config` and `cluster-flux` need one
  of them.
- `CLUSTER_DOMAIN`: the domain the cluster's applications are published under, a lower-case DNS
  name, which becomes `CLUSTER_DOMAIN` in `cluster-config`; `cluster-bootstrap`, `cluster-config`
  and `cluster-flux` need it.
- `ADOPTION_INTERVAL` and `ADOPTION_WAIT`: how many seconds `app-adoption` waits between two
  polls, 10 when unset, and in all, 900 when unset.
- `CI`: when set, talman's output goes to a file instead of the output; see
  [What the recipes print](#what-the-recipes-print).

The recipes, the secrets bundle check aside, refuse to run while `GODEBUG` sets `http2debug`: Go's
HTTP/2 debug log prints the frames talosctl and kubectl send and receive, which carry machine
configurations and credentials.
