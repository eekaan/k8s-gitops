# The cluster

The Talos cluster is created and changed by `just` recipes that check what they need before they
run anything. Each recipe that works on one cluster takes its name, `lab-sto2` when none is given,
and works in `talos/<cluster>/`: on `talman.yaml`, which the cluster stack renders, `just
infra-apply sto2/cluster` and `just infra-talman` write, and git ignores; on `secrets.sops.yaml`,
the cluster's encrypted secrets bundle, which is committed; and on talman's output directory
`clusterconfig/`, which git ignores and which holds the machine configurations, the talosconfig
and the kubeconfig.

## From nothing to a Ready cluster

1. `just infra-apply sto2/plumbing`, then `just infra-apply sto2/cluster` and
   `just infra-apply sto2/edge` ([infrastructure.md](infrastructure.md)): the nodes boot and wait
   in maintenance mode, the cluster's `talman.yaml` is written, and the edge routers start. The
   edge stack's first build, with `EDGE_IMAGE`, `EDGE_SSH_KEY_FILE` and `OPERATOR_CIDRS` in the
   environment, is in [runbooks/edge.md](runbooks/edge.md#first-build). `just infra-talman` writes
   `talman.yaml` again from the cluster stack's state, without applying.
2. `just cluster-age-key`, once: the Talos age key. Commit `talos/.sops.yaml`.
3. `just cluster-secrets`, once per cluster: the secrets bundle. Commit it.
4. `just cluster-flux-age-key`, once: the Flux age key. Commit `.sops.yaml`.
5. `just cluster-bootstrap`: every node configured, Cilium installed, what Flux needs before it
   starts applied, the kubelet serving-certificate approver installed, every node Ready. What Flux
   needs includes `cluster-config`, whose two keys of the edge routers' public addresses come from
   the edge stack's outputs, so this step and the next need the edge stack applied in step 1 and
   its environment ([infrastructure.md](infrastructure.md#environment)), and refuse, naming the
   stack, without them.
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
  operator on DRBD, with LVM-thin storage pools and snapshots, which `apps/base/piraeus-datastore/`
  installs ([kubernetes.md](kubernetes.md#storage)). An extension's modules load only when the
  machine configuration lists them, and on
  Talos the LINSTOR satellite cannot load a module itself
  ([Piraeus](https://github.com/piraeusdatastore/piraeus-operator/blob/v2/docs/how-to/talos.md)),
  so `talos/patches/all/kernel-modules.yaml` has every node load `drbd`, with its user-mode helper
  scripts disabled, its TCP transport `drbd_transport_tcp`, `dm-thin-pool` for LVM-thin pools and
  `dm-snapshot` for snapshots, which the Talos kernel has built in.
- `siderolabs/gvisor`: gVisor, which registers the containerd runtime handler `runsc`; the
  RuntimeClass `gvisor` selects it ([kubernetes.md](kubernetes.md#runtime-classes)). gVisor
  requires unprivileged user namespace creation
  ([gVisor extension](https://github.com/siderolabs/extensions/blob/release-1.14/container-runtime/gvisor/README.md)),
  which Talos turns off with its kernel hardening defaults
  ([Talos](https://docs.siderolabs.com/talos/v1.14/security/talos-default-hardening-and-cis-compliance)):
  as the KSPP recommends ([KSPP](https://kspp.github.io/Recommended_Settings#sysctls)), it sets
  `user.max_user_namespaces` to 0. `talos/patches/all/user-namespaces.yaml` overrides that default
  on every node with the limit the README and Talos' guide to user namespaces give, 11255
  ([Talos](https://docs.siderolabs.com/kubernetes-guides/security/usernamespace)), so a pod that
  selects `gvisor` can start. The cost is that unprivileged user namespaces widen the kernel's
  attack surface for every workload on the node, not only gVisor's, which is why Talos leaves them
  off. `just cluster-talos` applies the setting to running nodes, where a sysctl takes effect
  without a reboot
  ([Talos](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/editing-machine-configuration)).

  The kubelet's seccomp default narrows that cost. `talos/patches/all/seccomp-default.yaml` has
  every node's kubelet run a container whose pod sets no seccomp profile under the container
  runtime's default profile instead of none
  ([Kubernetes](https://kubernetes.io/docs/tutorials/security/seccomp/#enable-the-use-of-runtimedefault-as-the-default-seccomp-profile-for-all-workloads),
  [Talos](https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubeletconfig)).
  To a container without `CAP_SYS_ADMIN` among its capabilities, containerd's default profile
  refuses `unshare`, `setns`, `clone3`, and a `clone` that asks for any new namespace, a user
  namespace among them
  ([containerd](https://github.com/containerd/containerd/blob/v2.3.7/contrib/seccomp/seccomp_default.go),
  the version Talos 1.14.6 runs). It narrows nothing for a privileged container, which always runs
  without a profile ([Kubernetes](https://kubernetes.io/docs/tutorials/security/seccomp/)), for a
  container that sets `Unconfined` or a profile of its own, or for a container with
  `CAP_SYS_ADMIN`, to which the default profile allows these calls. The configuration Talos
  generates turns the default on by itself; the patch states it, so that a change of that default
  cannot turn it off, and changes nothing on a node that runs the generated configuration.
- `siderolabs/kata-containers`: Kata Containers, which registers the containerd runtime handlers
  `kata`, on Cloud Hypervisor, and `kata-qemu`; the RuntimeClass `kata` selects the first. Kata
  runs each pod in a virtual machine of its own and needs hardware virtualisation on the node, which
  on a cloud instance means nested virtualisation
  ([Kata Containers](https://github.com/kata-containers/kata-containers/blob/main/docs/install/README.md)).
  On a node without it, a pod that selects `kata` does not start.

No workload of the tree selects either runtime class; `just runtime-check` runs pods under the one
it is given while it checks whether a pod under it could host a sandbox
([kubernetes.md](kubernetes.md#runtime-classes)). `infra-check` refuses the QEMU guest agent extension
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

## The workers' data device

Every worker's machine configuration adds `talos/patches/worker/data-volume.yaml`, which
`talman.yaml` lists in the workers' own patch group; no control plane's does. It is a Talos raw
volume named `data`, on the disk that is not the system disk: the worker's data volume
([infrastructure.md](infrastructure.md#the-workers-data-volumes)). Talos makes it one partition
over that disk, labelled `r-data`, with no filesystem and nothing mounted, and links it as
`/dev/disk/by-partlabel/r-data`. That path is the same on every worker, whatever the kernel calls
the disk and whatever the cloud assigns the volume, and it is the device LINSTOR's storage pool is
made from ([kubernetes.md](kubernetes.md#the-storage-pool), ADR 0011). A disk with less than 1 GiB
free is not taken.

On running workers, `just infra-apply sto2/cluster` attaches the volumes and writes the
`talman.yaml` that lists the patch, and `just cluster-talos` then creates the raw volume. Taking
the patch out later leaves the partition and its data on the disk.

## Image layers for Spegel

Spegel shares images between the nodes ([kubernetes.md](kubernetes.md#the-kube-system-baseline)),
serving the layers of each node's images from containerd's content store. Talos has containerd
discard a layer from the content store once it is unpacked, to save disk space
([Talos](https://docs.siderolabs.com/kubernetes-guides/advanced-guides/spegel)): its own CRI
configuration sets `discard_unpacked_layers = true`
([Talos](https://github.com/siderolabs/talos/blob/v1.14.6/hack/cri-plugin.part#L3-L4)).
`talos/patches/all/spegel.yaml` has every node keep them: a `CRICustomizationConfig` named `spegel`
sets `discard_unpacked_layers` to false in containerd's images plugin, as that guide gives it for
Talos 1.14 and later. Talos merges it as `20-spegel.part`, after its own `00-base.part`
([Talos](https://github.com/siderolabs/talos/blob/v1.14.6/internal/app/machined/pkg/controllers/files/cri_config.go#L154-L161)).

This is not a combination Talos supports: its maintainers support neither Spegel nor a changed
`discard_unpacked_layers` "in a way it should work fully"
([siderolabs/talos#14784](https://github.com/siderolabs/talos/issues/14784), open, reported on
Talos 1.14.5 with Spegel 0.8.1). The setting reaches the images the kubelet pulls, and no others:

- An image the kubelet pulls once the patch is live on the node keeps its layers, and Spegel serves
  them to the other nodes.
- An image pulled before that lost its layers when it was unpacked, and the setting does not bring
  them back, so Spegel cannot serve it from that node until it is removed and pulled again
  (inferred from containerd's documentation, not yet seen on a cluster).
- An image pulled through the Talos API, such as by `talosctl image pull`, loses its layers
  whatever the setting: Talos pulls it with containerd's `ChildGCLabelsFilterLayers`, which leaves
  the layers unreferenced for garbage collection
  ([Talos](https://github.com/siderolabs/talos/blob/v1.14.6/internal/pkg/containers/image/pull.go#L186-L190)),
  as the issue above shows.

### What it costs

The setting lets containerd's garbage collection remove a layer from the content store once it is
unpacked into the snapshotter
([containerd](https://github.com/containerd/containerd/blob/v2.3.7/docs/cri/config.md)). With it
off, an image the kubelet pulls keeps its layers as the registry served them, usually compressed,
in the content store, beside their unpacked copy in the snapshotter, until the image is removed.
Both are under `/var/lib/containerd`, which stays a directory of the system disk's EPHEMERAL volume
unless a `VolumeConfig` gives it a partition of its own, as does `/var/lib/kubelet`
([Talos](https://github.com/siderolabs/talos/releases/tag/v1.14.0)), and none does.

Spegel collects nothing itself and leaves it to the kubelet's image garbage collection
([Spegel](https://spegel.dev/docs/faq/#why-is-my-node-running-out-of-disk-space)), which bounds
it: from 75% use of that filesystem the kubelet deletes unused images, least recently used first,
down to 65% (`talos/patches/all/kubelet.yaml`,
[Kubernetes](https://kubernetes.io/docs/concepts/architecture/garbage-collection/#containers-images)).
Below the kubelet's default hard eviction thresholds, 15% free for images and 10% for the node,
which neither Talos nor the patches change, it reports disk pressure, collects dead containers and
unused images, and then evicts pods
([Kubernetes](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/#hard-eviction-thresholds)).

### Rolling it out

The patch reaches the nodes before Spegel runs: `just cluster-talos` applies it from the pull
request's branch, and the merge that has Flux start Spegel comes after. Applying, changing or
removing a `CRICustomizationConfig` restarts containerd's CRI instance and needs no reboot
([Talos](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/images-container-runtime/containerd)).
Talos' Spegel guide still has a reboot step, which Talos 1.14 made unnecessary ("a machine reboot is
no longer required to apply changes to CRI configuration",
[Talos](https://github.com/siderolabs/talos/releases/tag/v1.14.0)); this follows the 1.14
documentation. Talos stops CRI by signalling the containerd process alone, whether or not it runs
in the workload sandbox
([Talos](https://github.com/siderolabs/talos/blob/v1.14.6/internal/app/machined/pkg/system/runner/process/process.go#L475-L496),
[Talos](https://github.com/siderolabs/talos/blob/v1.14.6/internal/app/machined/pkg/system/runner/process/process.go#L575-L592)),
and runc's shims, which hold the containers, run in a cgroup apart from containerd's
([Talos](https://github.com/siderolabs/talos/blob/v1.14.6/hack/cri-plugin.part#L14-L15),
[Talos](https://github.com/siderolabs/talos/blob/v1.14.6/internal/app/machined/pkg/system/services/cri.go#L184)),
so running containers keep running while the kubelet loses the CRI for the restart (inferred from
source, not yet seen on a cluster).

Once Flux starts it, each Spegel pod's init container writes the mirror configuration that sends
the node's pulls to Spegel first, `_default/hosts.toml` under `/etc/cri/conf.d/hosts`
([Spegel](https://github.com/spegel-org/spegel/blob/v0.8.1/pkg/oci/containerd/mirror.go#L121-L134)).
Talos rewrites that directory whenever the node's registry configuration or a CRI customization
changes
([Talos](https://github.com/siderolabs/talos/blob/v1.14.6/internal/app/machined/pkg/controllers/files/cri_config.go#L43-L58)),
and removes from it every directory its own registry configuration does not name
([Talos](https://github.com/siderolabs/talos/blob/v1.14.6/internal/app/machined/pkg/controllers/files/cri_config.go#L260-L280)),
which is all of Spegel's, as no machine configuration here sets a registry mirror. A CRI restart
recreates no pod, so nothing writes it back, and the nodes pull from the upstream registries, with
nothing reporting it, until Spegel's pods start again (inferred from source, not yet seen on a
cluster). So while Spegel runs, its DaemonSet is restarted after any `just cluster-talos` that
changes the nodes' CRI customizations or registry mirrors, this patch included, and its init
containers write the configuration again.

### Checking it on a node

- The merged CRI configuration, `/etc/cri/conf.d/cri.toml`, which containerd imports, names
  `in-memory customization "spegel"` in its header, and its `plugins."io.containerd.cri.v1.images"`
  table holds `discard_unpacked_layers = false`
  ([Talos](https://github.com/siderolabs/talos/blob/v1.14.6/hack/cri-containerd.toml#L12-L14),
  [Talos](https://github.com/siderolabs/talos/blob/v1.14.6/internal/pkg/toml/merge.go#L44-L50)).
- Once `just cluster-talos` has run and Spegel's pods have started again,
  `/etc/cri/conf.d/hosts/_default/hosts.toml` is there and names the node's Spegel, on port 30020.
- A layer of an image the kubelet pulled after the rollout is still in containerd's content store,
  under `/var/lib/containerd/io.containerd.content.v1.content/blobs/sha256/`, minutes later.
- Spegel's `spegel_mirror_requests_total` with `cache="hit"` rises in Prometheus as nodes pull
  images another node holds
  ([Spegel](https://github.com/spegel-org/spegel/blob/v0.8.1/pkg/registry/registry.go#L239-L247)).

## The control planes' metrics

Every control plane's machine configuration adds `talos/patches/controlplane/metrics.yaml`, so
Prometheus, from its pod, can scrape the controller manager, the scheduler and etcd
([kubernetes.md](kubernetes.md#monitoring)). Talos binds the controller manager and the scheduler
to 127.0.0.1, and etcd serves its metrics only on its client port, which takes client
certificates. The patch makes each listen on all of the node's addresses, as `talman.yaml` gives no
node its own address on the node network:

- the controller manager's secure port, 10257, and the scheduler's, 10259: HTTPS, with every
  request but the health checks authorized by the API server, so only a token allowed to read
  `/metrics`, such as Prometheus's, gets the metrics;
- etcd's metrics and health on 2381: plain HTTP, without authentication. It serves etcd's own
  counters and latencies, not the keys or values it stores.

Each control plane's firewall admits the three ports from the nodes' own addresses and the pod
range only ([The node firewall](#the-node-firewall)): Prometheus's scrapes arrive from the address
of the node its pod runs on, or from the pod's own address when that node is the control plane
itself. Nothing outside the cluster reaches them, also not on a node's floating address.
`just cluster-talos` rolls the patch out; until it has, the three targets are down in Prometheus and
their alerts fire. The controller manager and the scheduler take their new arguments as soon as
Talos has restarted them; etcd serves 2381 from its next start, which is the control plane's next
reboot ([A change that needs a reboot](#a-change-that-needs-a-reboot)): until then its etcd target
is down and `cluster-check` fails on it. If an etcd alert fires on a healthy cluster, read the
`kube-etcd` target on the control plane in Prometheus; a target that is down while `talosctl etcd
status` is healthy means that control plane has not rebooted since the patch reached it, and
`just cluster-reboot <node>` fixes it.

## A change that needs a reboot

Talos applies a machine configuration to the running node without a reboot
([Talos](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/editing-machine-configuration)),
but some of it is read only when a service starts, and Talos does not restart the service:

- `cluster.etcd`: etcd's image, extra arguments, such as `listen-metrics-urls`, and advertised and
  listen subnets. Talos does not restart etcd on a change, so the node runs the old setting until
  it reboots.
- Kernel modules (`machine.kernel.modules`, `KernelModuleConfig`): a module removed stays loaded and
  a loaded one keeps its parameters until the node reboots. A module added is loaded at once.
- Environment variables (`machine.env`, `EnvironmentConfig`): running services keep theirs until
  they restart.
- The sandbox (`SecurityProfileConfig`).
- Volume encryption keys: a new key re-encrypts the volume at the next reboot.

The patches in `talos/patches/` set the first two, and `just cluster-talos` reads them back. For
each node whose dry run shows a change, a diff talman did not show included, it reads from the
node's Talos API, through `talman talosctl get`, what Talos derives from them: etcd's configuration
(`EtcdConfigs.etcd.talos.dev`, on a control plane) and the kernel modules it loads with their
parameters (`KernelModuleSpecs.runtime.talos.dev`). Neither holds a secret. It reads them before it
applies the configuration and again once the node runs it; a node on which they differ runs the old
setting until it reboots. The diff does not decide it: a unified diff shows three lines around a
change, not the section that holds them. The other three are not read back, as their values can be
secrets; no patch sets them, and a test fails when one does. The kubelet, the API server, the
controller manager and the scheduler, which the patches also configure, are not on the list: Talos'
page names none of them, but it calls its own list not exhaustive, so a setting found to need a
reboot is added to the list above `reboot_state` in `scripts/lib/cluster.sh`, which holds it with
the citation. A test fails when the version in that citation is not the Talos minor version in
`versions.yaml`. The page also names `UnattendedInstallConfig` and `machine.install`, which
`talos/patches/all/install.yaml` sets, as used only when Talos installs or upgrades itself, with
no effect on an installed node even after a reboot: they are not on the list, and
`just cluster-upgrade` is what applies them.

Once the nodes keep the configuration, the rollout names each node that runs an old setting, saying
what it runs until it reboots and the recipe that reboots it, for example `cp-1 runs etcd as it was
started until it reboots; reboot it with: just cluster-reboot cp-1`. Reboot the control planes one
at a time: `cluster-reboot` reboots a control plane only while etcd has every control plane as a
healthy member, and returns once the node is Ready again and etcd has its member back. A change to
nothing on the list prints nothing about a reboot. A dry run that shows changes in no node's block
that reads as the pinned talman prints one, as another talman version's might, leaves the recipe
unable to tell which nodes change: it says so, and that it cannot say whether any needs a reboot,
and applies the configuration; with `--reboot` it applies nothing. A node whose Talos API does not
answer with those settings, before or after, is named as one it could not read, not passed over. A
run that stops after some nodes took the configuration, with `--first` or when `talman apply` fails
partway, names those of them that need a reboot, as a later run finds nothing to change on them and
would not. A node that took such a change in an earlier run and has not rebooted since is not named
again: what Talos holds for it already matches the configuration, and says nothing of what its etcd
was started with; its etcd target, down in Prometheus, does ([The control planes'
metrics](#the-control-planes-metrics)).

With `--reboot` the recipe names, before it asks for the cluster's name and applies anything, the
nodes the dry run shows a change on as those it reboots if they then run an old setting. It reboots
those that do itself, through `scripts/cluster-reboot`, one at a time, once every node has kept the
configuration, and stops at the first that does not come back, Ready and with its etcd member,
naming the nodes it did not reboot; `--tolerate <seconds>` is passed to each `cluster-reboot`, for
the interruption of the API a control plane's reboot causes behind its load balancer. A reboot is
not the default: it takes a control plane out of etcd and the API load balancer for a few minutes,
and the operator says so by passing `--reboot`.

## The node firewall

Every node filters what reaches it itself, with Talos' ingress firewall
([Talos](https://docs.siderolabs.com/talos/v1.14/networking/ingress-firewall),
[ADR 0017](adr/0017-nodes-firewall-themselves-with-talos-ingress-firewall.md)), so the cluster's
protection does not depend on the cloud's security groups. `talos/patches/all/firewall.yaml` sets
the firewall's default action to block and gives the node one rule for each listener of its role.
Talos itself admits traffic on the loopback interface, replies to connections the node opened,
ICMP at up to five packets a second and traffic from the pod and service ranges to those ranges;
every other packet addressed to the node is dropped unless a rule admits it. It is the layer for
what reaches the node's own listeners; what a pod takes and sends is the layer of the namespaces'
network policies ([Network policy](kubernetes.md#network-policy), [ADR
0019](adr/0019-namespaces-deny-traffic-by-default-and-each-declares-its-flows.md)), which does not
select pods in the host's network namespace.

The listeners are written down once, in `talos/firewall.yaml`: each with its protocol and ports, the
nodes that have it, all or control planes only, and the sources it accepts. The cluster stack
renders them into the cluster's `talman.yaml` as `values.firewall`, a list of rules for each role
whose sources are networks, and the patch writes each into the node's machine configuration as a
`NetworkRuleConfig`. The operator allowlist reaches the rules that way only: from the same
`api_allowed_cidrs` the security group takes, through the generated `talman.yaml`, which git
ignores; no committed file holds it. A new listener, or a listener that moves, needs its entry in
`talos/firewall.yaml`, or the firewall drops what reaches it. The tests then fail until the entry
has its row in the table below, its port in the account of
[what a rollout proves](#what-the-checks-prove-and-what-to-watch-afterwards), and its listener: a
port that a pod of the render of `kubernetes/` on the host network declares, in the account
`tests/node-listeners.bats` holds, or an entry under `no-pod` in `node-firewall-exceptions.yaml`,
at the repository's root, that says what listens there. The counts of rules that the tests hold
change with it. A port that such a pod declares and that needs no rule is an entry under
`no-rule` in the same file, with where it listens and who calls it, and is named under
[What gets no rule](#what-gets-no-rule).

`tests/node-firewall.bats` renders every node's configuration offline and fails when a node has a
rule `talos/firewall.yaml` does not list or lacks one it lists, when a rule accepts other networks
than its sources stand for, and when the table below and the file disagree.
`tests/node-listeners.bats` renders the `kubernetes/` tree and ties the rules to the ports its pods
hold on a node. A pod on the host network holds the ports it listens on as the node's own, so the
test reads every pod template of the render that sets `hostNetwork` for the ports its containers
and init containers declare, and fails when such a port is neither admitted by exactly one rule
that every node has nor listed under `no-rule`, or is both; when a rule admits no such port and is
not named under `no-pod`, or is both; when an entry of either list matches nothing; when a pod
template that is not on the host network declares a host port; when a monitor of the render
scrapes a port listed under `no-rule`, an endpoint that rewrites the address it scrapes, by name, by
a labelmap or by a target label built from its regex's groups, counting as one that scrapes every
port of the pods it selects; when a `Probe` is not in the one shape the test accepts, below; and
when the render holds what the test cannot follow: a `ScrapeConfig`, or a Prometheus with scrape
configurations of its own or a scrape class with relabelings, which run on every monitor it
selects. It holds the account of the ports, of the rules and of the host ports as literals, so a
chart that adds a port or a host port, and a rule that changes its nodes or its sources, change the
test.

Prometheus scrapes a `Probe`'s prober, and the blackbox exporter there connects to each of its
targets ([Probes](kubernetes.md#probes)). The test does not follow where those names lead, which a
render cannot show: a Service that a controller makes at run time, as the Prometheus Operator makes
the kubelet's, headless over the nodes' addresses; a headless Service, whose name is its pods' own
addresses, the nodes' for pods on the host network and the control planes' for their static pods; a
Service without a selector or an ExternalName, which lead where endpoints or another name say. It
accepts a `Probe` in one shape, that of the tree's Probes, and refuses every other, saying how it
leaves the shape:

- its prober is the blackbox exporter's Service, by the name and port the render gives it, whose
  selector selects the exporter's pods in the render, none on the host network and none that
  resolves names its own way, by `hostAliases`, a `dnsConfig` or the `dnsPolicy` `None`, as the
  Prometheus that resolves the prober's name does not either;
- each target is the public Gateway's proxies' Service, by the name `tests/probes.bats` derives
  from the render's one Gateway, over `http` or `https` on a port of the Gateway's listeners. Envoy
  Gateway makes the proxies and their Service at run time, so no render holds them: at the version
  `tests/probes.bats` holds the controller to, it builds the pods without the host network, which
  only a patch changes, and the Service by that name, of one of the types an `EnvoyProxy` may give
  it, each of which leads to the pods it selects; only a patch of the Service, a name of its own
  or merged Gateways, whose proxies then take their GatewayClass's name, change that
  ([resource_provider.go](https://github.com/envoyproxy/gateway/blob/v1.10.0/internal/infrastructure/kubernetes/proxy/resource_provider.go)).
  So the test holds that no `EnvoyProxy` and no default of the controller's configuration patches
  the pods or the Service, names the Service or merges the Gateways, that the render holds no
  Service of that name in the controller's namespace, and that the namespace, the controller's,
  enforces the Pod Security level `baseline` or `restricted`, either of which refuses the host
  network;
- the render holds no endpoints written by hand for either Service;
- its spec holds the job, the module, the prober and the targets and nothing more, the prober its
  address alone and the targets static ones with the label `hostname` alone; its module is one of
  the three `tests/probes.bats` pins whole, each of the http prober; and its relabelings are the one
  that makes that label the parameter `hostname`.

The name of the proxies' Service, the relabeling and the modules are in
`tests/fixtures/probe-shape.bash`, which both tests load. Three things are outside what the test
reads:

- A port that a process on the host network opens without declaring it in its pod: Cilium's health
  checks on TCP 4240, which the agent serves on its node's address
  ([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/pkg/health/server/server.go#L436-L465)),
  Envoy's health listener on TCP 9878, the kernel's VXLAN port, UDP 8472, Cilium's WireGuard
  device on UDP 51871, and DRBD's replication, which the kernel serves on a TCP port of 7000-7999
  for each volume a node holds. No rule admits such a port unless the inventory names it, so one
  that a client off the node needs and that has no rule shows as a path that does not work, as the
  health checks, the overlay, its encryption and DRBD's replication would without theirs. Their
  rules are entries under `no-pod`, which say in prose what listens there.
- A pod that an operator creates at run time, which no render holds. LINSTOR's CSI node plugin and
  its satellites are such pods on the host network, from the operator's templates: the plugin's
  ports are accounted for in prose, under [What gets no rule](#what-gets-no-rule), and the
  satellites' ports, LINSTOR's and their DRBD reactor's, have rules of their own
  ([What each node admits](#what-each-node-admits)), named under `no-pod`. Pod Security refuses the
  host network and host ports below the privileged level
  ([kubernetes.md](kubernetes.md#pod-security)), so only a namespace that enforces that level,
  `kube-system`, `monitoring`, `piraeus-datastore` or `security-system`, can hold another. A
  Service that a controller makes at run time is outside it as well, which is why a `Probe` that
  names one is refused, but for the public Gateway's proxies' Service, on the terms above.
- Whether a process binds the address its reason names. The reasons rest on the sources cited under
  [What gets no rule](#what-gets-no-rule), read at the versions the tree pins, and a chart update
  can change what a process binds without changing what its pod declares.

### Sources

- `operators`: the operator allowlist, `OPERATOR_CIDRS` or `operator-cidrs.json`
  ([infrastructure.md](infrastructure.md#environment)).
- `floating`: each node's floating address. A node that reaches another node's floating address goes
  out through the router and arrives from its own.
- `members`: each node's own address on the node network, the one its kubelet registers it with
  (`talos/patches/all/node-ip.yaml`), and so the one Kubernetes reports for it. A node's own
  connections come from it, and so does a pod's connection to another node's address. Cilium routes
  in tunnel mode, and a node's address has a tunnel endpoint only with Cilium's host firewall or
  node encryption on
  ([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/pkg/node/manager/manager.go#L577-L584)),
  neither of which `kubernetes/apps/base/kube-system/cilium/app/values.yaml` turns on, so the packet
  leaves through the node's own interface. There it is masqueraded to that interface's address:
  with eBPF masquerading off, as by the chart's default
  ([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/install/kubernetes/cilium/values.yaml#L704-L707)),
  Cilium's iptables rule masquerades what leaves the node's pod range, for an address outside it,
  on any device but Cilium's own
  ([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/pkg/datapath/iptables/iptables.go#L2206-L2241)),
  and exempts traffic to other nodes from it only without tunnelling
  ([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/pkg/option/config.go#L2061-L2063)).
- `pods`: the pod range, from which a pod arrives at the node it runs on.
- `controlplanes`: each control plane's address on the node network.
- `loadbalancer`: the API load balancer's address on the node network, and the networks of the
  node subnet's DHCP pool. A load balancer that proxies, as Octavia's amphora provider does,
  connects to the API servers and health-checks them from its own ports' addresses, not from the
  client's. An amphora configures each of its ports with the address Neutron gave the port, or
  takes it by DHCP
  ([Octavia](https://github.com/openstack/octavia/blob/19.0.0/octavia/amphorae/backends/utils/interface_file.py#L109-L131),
  [member ports](https://github.com/openstack/octavia/blob/19.0.0/octavia/amphorae/backends/utils/interface_file.py#L248-L278)),
  and Neutron allocates a port that asks for no particular address an available one of its subnet
  and returns it, when the port goes, to the subnet's allocation pools, here the DHCP pool
  ([Neutron](https://docs.openstack.org/api-ref/network/v2/index.html#create-port)). The cluster
  stack renders the pool as the fewest networks that hold it exactly.
- `cihost`: the CI host's address on the node network, once the cluster stack's `ci_host_number`
  gives it ([infrastructure.md](infrastructure.md#the-ci-host)); nothing without it.

A port that pods reach therefore accepts both `members` and `pods`. No source is the node network as
a whole, which also holds the two edge routers the workers announce Services to
([infrastructure.md](infrastructure.md#services-announced-over-bgp)), at host numbers outside every
source above. An edge router's address therefore reaches no listener on any node: at the firewall it
gets only what Talos admits to everyone, replies to connections the node opened, such as a worker's
BGP sessions to it, and ICMP at up to five packets a second.

### What each node admits

| Rule | Protocol and ports | Nodes | Accepted from | Who connects, and why |
| --- | --- | --- | --- | --- |
| `apid` | TCP 50000 | all | `operators`, `members`, `floating`, `cihost` | The Talos API: talman and talosctl on the operator's machine and the CI host, and a node's Talos API passing a request on to another node. |
| `trustd` | TCP 50001 | control planes | `members` | Talos' trust daemon, from which a worker gets its certificates. |
| `kube-apiserver` | TCP 6443 | control planes | `operators`, `members`, `floating`, `pods`, `loadbalancer`, `cihost` | The Kubernetes API: the operator and the CI host, the load balancer, every node's KubePrism and kubelet, and every pod that reaches the `kubernetes` Service, which Cilium sends to a control plane's address. |
| `etcd` | TCP 2379-2380 | control planes | `controlplanes` | etcd's client and peer ports: the other members, and a control plane that joins. |
| `etcd-metrics` | TCP 2381 | control planes | `members`, `pods` | etcd's metrics, which Prometheus scrapes ([above](#the-control-planes-metrics)). |
| `kube-controller-manager` | TCP 10257 | control planes | `members`, `pods` | The controller manager's secure port, which Prometheus scrapes. |
| `kube-scheduler` | TCP 10259 | control planes | `members`, `pods` | The scheduler's secure port, which Prometheus scrapes. |
| `kubelet` | TCP 10250 | all | `members`, `pods` | The kubelet: the API server, for logs, exec and port forwarding, and metrics-server and Prometheus, for metrics. metrics-server serves the API's metrics, so a node it cannot reach makes that API unavailable, which breaks API discovery and the deletion of namespaces. |
| `cilium-vxlan` | UDP 8472 | all | `members` | Cilium's overlay, which carries pod traffic between nodes in VXLAN on Linux's default port ([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/Documentation/operations/system_requirements.rst#firewall-rules)). Cilium trusts the identity a VXLAN packet carries, so only the nodes may send it. |
| `cilium-wireguard` | UDP 51871 | all | `members` | Cilium's WireGuard device, which each agent makes in the kernel and which the overlay's packets to another node pass through, encrypted, once Cilium's values turn WireGuard on: a peer's endpoint is the address its node is registered with, on this port ([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/Documentation/operations/system_requirements.rst#firewall-rules), [kubernetes.md](kubernetes.md#encryption-between-nodes)). Only the agents send to it. |
| `cilium-health` | TCP 4240 | all | `members` | Cilium's health checks between nodes; the ICMP echo they send as well is admitted by Talos itself. |
| `hubble` | TCP 4244 | all | `members`, `pods` | The Hubble server in each node's Cilium agent, from which Hubble Relay reads the node's flows. |
| `node-exporter` | TCP 9100 | all | `members`, `pods` | node-exporter, on the host network, which Prometheus scrapes. |
| `cilium-agent-metrics` | TCP 9962 | all | `members`, `pods` | The Cilium agent's metrics, on the host network, which Prometheus scrapes: the workers' BGP sessions among them ([kubernetes.md](kubernetes.md#monitoring)). |
| `linstor-satellite` | TCP 3366-3367 | all | `members`, `pods` | LINSTOR's satellites, on the host network of the workers: the LINSTOR controller, a pod, connects to each over TLS on 3367, the port the operator registers it with ([Piraeus](https://github.com/piraeusdatastore/piraeus-operator/blob/v2.12.1/internal/controller/linstorsatellite_controller.go#L460-L465), [kubernetes.md](kubernetes.md#who-may-call-linstor)). |
| `drbd` | TCP 7000-7999 | all | `members` | DRBD's replication, between the workers' kernels: a volume's resource listens at the node's own address on a port of LINSTOR's range, 7000-7999 by default ([LINSTOR](https://github.com/LINBIT/linstor-server/blob/v1.35.3/server/src/main/java/com/linbit/linstor/core/objects/Node.java#L89-L90)), on each node that holds it, and its peers connect from theirs. |
| `drbd-reactor` | TCP 9942 | all | `members`, `pods` | The DRBD reactor beside each satellite, on the host network, whose metrics Prometheus scrapes ([kubernetes.md](kubernetes.md#storage-monitoring)). |

### What gets no rule

- KubePrism and Talos' own DNS listen for the node itself; the loopback interface is always
  admitted, and Talos admits the cluster's DNS traffic to its host DNS from the pod and service
  ranges itself, as the machine configuration forwards the cluster's DNS to it.
- The Cilium agent's health API, TCP 9879, and the Cilium operator's API, TCP 9234, which serves
  its health check, listen on the loopback address only, although both pods declare the port: the
  agent's by its source
  ([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/daemon/healthz/agenthealth.go#L58-L84),
  [its ports](https://github.com/cilium/cilium/blob/v1.20.4/Documentation/operations/system_requirements.rst#firewall-rules)),
  the operator's at the address the chart gives it, `operator-api-serve-addr` in the rendered
  `cilium-config`
  ([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/install/kubernetes/cilium/templates/cilium-configmap.yaml#L27-L31),
  [the server](https://github.com/cilium/cilium/blob/v1.20.4/operator/api/server.go#L119-L134)).
  The node's own kubelet probes each there, as the chart's probes name the loopback address.
- The Cilium operator and Cilium's Envoy serve their metrics, TCP 9963 and 9964, on every address
  of the node, and both pods declare the port: the operator at `operator-prometheus-serve-addr`
  in the rendered `cilium-config`, which the chart sets by default
  ([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/install/kubernetes/cilium/templates/cilium-configmap.yaml#L248-L255),
  [the address](https://github.com/cilium/cilium/blob/v1.20.4/operator/metrics/cell.go#L13-L16)),
  Envoy on the metrics listener of its bootstrap configuration, whose health listener, TCP 9878,
  is on the loopback address
  ([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/install/kubernetes/cilium/files/cilium-envoy/configmap/bootstrap-config.yaml#L13-L18),
  [the health listener](https://github.com/cilium/cilium/blob/v1.20.4/install/kubernetes/cilium/files/cilium-envoy/configmap/bootstrap-config.yaml#L119-L123)).
  Nothing calls them: their monitors are off ([kubernetes.md](kubernetes.md#monitoring)), no
  monitor of the render scrapes them, which `tests/node-listeners.bats` holds, and the kubelet
  probes the operator's API and Envoy's health listener instead. The agent's metrics are the
  exception, with a rule of their own above.
- LINSTOR's CSI node plugin runs on the host network with health ports, TCP 9808 and 9809, that
  only its own kubelet probes; a connection to the node's own address goes over the loopback
  interface
  ([Piraeus](https://github.com/piraeusdatastore/piraeus-operator/blob/v2.12.1/pkg/resources/cluster/csi-node/csi-node-daemon-set.yaml)).
  The operator creates the pod at run time, so the render does not hold it and no test reads its
  ports.
- Spegel runs on the pod network: its peers reach each other, and Prometheus its metrics, at pod
  addresses, and its registry is a NodePort that each node's own containerd reaches at the node's
  own address
  ([Spegel](https://github.com/spegel-org/spegel/blob/v0.8.1/charts/spegel/templates/daemonset.yaml)),
  which Cilium serves on the node.
- Cilium's BGP control plane runs on the workers ([kubernetes.md](kubernetes.md#service-addresses)):
  each opens its sessions to the two edge routers, and listens on no port, as no BGP instance of
  `cilium-bgp` sets `localPort`
  ([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/pkg/bgp/manager/manager.go#L961-L966)).
  What an edge router sends on a session is a reply to the worker's connection, which Talos admits.

### What the firewall does not see

The firewall's chains are netfilter's input and prerouting hooks, for packets addressed to the node
itself. What Cilium serves before netfilter, or delivers to a pod rather than to the node, never
reaches them, and neither does a node without machine configuration. Each, with what controls it:

- Traffic to a pod's address, between pods or through a Service. No route from outside the node
  network leads to the pod range, and each node's cloud port carries only its node's own address;
  between pods, Talos leaves it to network policies.
- NodePorts, which Cilium serves from its eBPF datapath at the node's network device as it replaces
  kube-proxy. The security group keeps Kubernetes' NodePort range, 30000-32767, closed to everything
  outside the nodes in both of its sets ([infrastructure.md](infrastructure.md#the-nodes-security-group)).
- Host ports of pods on the pod network, which Cilium serves the same way, outside the NodePort
  range
  ([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/Documentation/network/kubernetes/kubeproxy-free.rst#container-hostport-support)).
  No pod template of the render that is on the pod network declares one, which
  `tests/node-listeners.bats` holds, and Pod Security refuses them at the baseline level, which
  Talos enforces wherever a namespace sets no other; only `kube-system`, `monitoring`,
  `piraeus-datastore` and `security-system` enforce the privileged level, which allows them. The
  pods of the render that declare a host port are Cilium's agent, its Envoy and its operator, six
  ports between them, as the test holds, and all three are on the host network, where Cilium maps
  no host port
  ([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/pkg/loadbalancer/reflectors/k8s.go#L148-L153))
  and the port is the node's own, which the firewall filters: each has its rule
  [above](#what-each-node-admits) or its reason under [What gets no rule](#what-gets-no-rule).
  node-exporter, on the host network as well, declares its port without a host port, which comes
  to the same: Kubernetes gives every port that a pod on the host network declares the host port
  of its own number when the pod is made, and refuses a container's port that names another
  ([Kubernetes](https://github.com/kubernetes/kubernetes/blob/v1.37.1/pkg/apis/core/v1/defaults.go#L214-L217),
  [validation](https://github.com/kubernetes/kubernetes/blob/v1.37.1/pkg/apis/core/validation/validation.go#L4341-L4349)).
  The full security group also admits no host port from outside the nodes.
- Services' external addresses, which Cilium serves the same way, and which any Service could name.
  The API server refuses a new one: every control plane enables Kubernetes' `DenyServiceExternalIPs`
  admission plugin (`talos/patches/controlplane/deny-service-external-ips.yaml`), which refuses a
  Service that names an external address it did not have before
  ([Kubernetes](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#denyserviceexternalips)),
  and no Service under `kubernetes/` names one. The plugin reads `spec.externalIPs` alone and passes
  every subresource
  ([Kubernetes](https://github.com/kubernetes/kubernetes/blob/v1.37.1/plugin/pkg/admission/network/denyserviceexternalips/admission.go#L60-L98)),
  so Cilium writing a Service's load-balancer address into its status, and Services labelled for
  BGP, are not affected.
- Services' load-balancer addresses, which Cilium assigns from the service range and serves the same
  way, and which the workers announce to the edge routers
  ([kubernetes.md](kubernetes.md#service-addresses)). They are reachable only through the edge
  routers: no route outside the node network leads to the service range but theirs, and the
  workers' own security group admits traffic to the service ports, and nothing else, from the two
  edge addresses only ([infrastructure.md](infrastructure.md#services-announced-over-bgp)). That
  group is part of the outer ring in both sets of the nodes' rules, which leave it as it is.
- A node in maintenance mode, which has no machine configuration and so no firewall, and whose
  Talos API takes a configuration from anyone who reaches it. The security group admits that port
  only from the allowlist, the nodes' floating addresses and the CI host, in both of its sets.

### Rolling it out

A configuration that changes what a node admits can cut the node off from the operator and from the
other nodes. `just cluster-talos --first <node>` rolls it out so that it cannot: after the dry run
and the confirmation, `just cluster-check` must pass, its check of the scrape targets of the
cluster's own components included, so while one is down, as a control plane's etcd target is until
it reboots after a change to etcd's metrics, the rollout applies nothing; and then the named node,
followed by every other node the configuration changes in `talman.yaml`'s order, is applied alone in
Talos' try mode
([Talos](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/editing-machine-configuration)),
which reverts the node by itself to the configuration it had five minutes after the apply, without a
reboot, unless another configuration is applied first. Within that window, from the operator's
machine, each of these must pass, in this order:

1. The node's Talos API reports that the configuration is in effect, which also says it answers.
2. Every node answers on the Talos API port.
3. The API server on another control plane, reached at that control plane's own address rather
   than the load balancer, reaches the node's kubelet (`/api/v1/nodes/<node>/proxy/healthz`) and
   its node-exporter (`/api/v1/nodes/http:<node>:9100/proxy/metrics`). Its requests arrive from that
   control plane's address, as a pod's on that control plane would once Cilium has masqueraded them.
4. The Cilium agent on the node and the one on another node, each running Cilium's own health probe
   at once, reach each other's health endpoint through the overlay and each other's host on the
   health port.
5. For a control plane, its etcd member and another control plane's, each asked through its own
   Talos API, follow the same leader in the same term, vote and report no error, such as having no
   leader, and the other control plane's member lists exactly the control planes of `talman.yaml`,
   the node's among them: a member etcd holds besides them, as of a control plane removed without
   its member, counts toward its quorum, and the check names it, or one missing, by its hostname.
   talosctl's table is read by position, so one that is not its twelve columns with `ERRORS` last
   fails the check.
6. The node is still Ready 65 seconds after the apply: Kubernetes' node lifecycle controller marks a
   node not Ready once its kubelet has not renewed its lease for `node-monitor-grace-period`,
   50 seconds by default, and looks every 5 seconds, and the kubelet renews its lease every 10
   seconds, a quarter of its 40 ([Kubernetes](https://github.com/kubernetes/kubernetes/blob/v1.37.1/pkg/controller/nodelifecycle/config/v1alpha1/defaults.go#L40-L53)).
   Talos sets none of them.
7. For a control plane, its own Kubernetes API answers `/readyz` at its own address, and the load
   balancer still sends it connections: of fifteen fresh requests through the load balancer's
   address for the API server's metrics, one is answered by the tried node's API server, told apart
   from the others by the start time of its process, `process_start_time_seconds`, which Prometheus'
   process collector in the API server's metrics reads from the process itself
   ([Kubernetes](https://github.com/kubernetes/kubernetes/blob/v1.37.1/staging/src/k8s.io/component-base/metrics/legacyregistry/registry.go#L54)),
   and which the same request at the node's own address gives. Talos turns the API server's
   profiling off, and nothing else it serves names its member. The load balancer gives each new
   connection to the next member in turn, and its health monitor, which checks every member every
   five seconds and takes one out after three failures, has by then taken out one it cannot reach;
   a check through the load balancer alone would not see that, as it routes around such a member. A
   configuration that changes the API server's own settings makes Talos restart it, so `/readyz` is
   asked every 5 seconds for up to 90, as a server that has just started is not ready until its
   post-start hooks are done, and the fifteen requests are repeated every 5 seconds for up to 20,
   the time the monitor takes to put a member back after two checks that pass. Neither wait starts a
   request after its bound and a request gives up after 10 seconds, so at their longest they take
   100 and 40 seconds after check 6, which ends 65 seconds after the try at the earliest; checks
   that run into the last minute of the window keep nothing. A failure says whether the API server
   never answered, as it does not when the firewall drops it, which of its checks were still
   failing, or that it stopped answering at its own address once ready.
8. `just cluster-check` passes: the Kubernetes API through the load balancer, every node Ready, the
   pods of `kube-system` running, a pod's logs fetched through its kubelet, no scrape target of
   the cluster's own components down, and, while Cilium's configuration turns WireGuard on, every
   node's Cilium agent encrypting with a peer for every other node.
9. The node's Talos API still reports the configuration in effect. Talos reverts a tried
   configuration once and for all, so one still in effect was in effect throughout the checks.

Only then, and only while more than a minute of the window is left, is the same configuration
applied again, which keeps it. A failed check stops the rollout: the node reverts by itself, the
nodes before it keep theirs and those after it are untouched, and the recipe says which are which,
as it does when a later node cannot say what the configuration would change. It names the check
that failed and, when the tool the check ran failed, that tool's last line of error, with every
address in it masked, or its exit status when it printed none. A check reads a tool's whole answer,
however early the line it looks for comes: a reader that stopped at it, such as `grep -q`, would
leave a tool with a long answer, such as metrics, to die of SIGPIPE, which fails the check under
`pipefail` whatever the answer held. `tests/cluster-recipes.bats` answers the checks' requests for
metrics and for a node with hundreds of kilobytes, and fails on a pipe written into such a reader
in the rollout's scripts.

### What the checks prove, and what to watch afterwards

The firewall admits what belongs to a connection it has seen, so a connection open before the try
keeps working through it, and only a connection opened inside the window tests a rule. On the
tried node, the checks open fresh connections on these paths:

- the Talos API, TCP 50000, from the operator's address (checks 1, 2, 5 and 9);
- node-exporter, TCP 9100, from another control plane's address, as `members` (check 3);
- Cilium's overlay, UDP 8472, both ways with another node: a VXLAN packet is never a reply, so every
  one is judged (check 4);
- for a control plane, the Kubernetes API, TCP 6443, from the operator's address and from the load
  balancer's addresses, as `loadbalancer` (check 7).

These are reached in the window as well, but on a connection that may be older than the try, so
they are not proved there: the kubelet, TCP 10250, which the API server may reach on a connection it
keeps (checks 3 and 8); Cilium's health port, TCP 4240, which Cilium probes on connections it keeps
(check 4); Cilium's WireGuard port, UDP 51871, which carries the overlay's packets to another node
while Cilium's values turn WireGuard on, on a connection each pair of devices keeps, as each sends
to its peer from that port to that port (check 4, and item 7 below). And these
are not reached in the window at all: etcd's peer and client ports, TCP 2379-2380, whose members
hold their streams open; etcd's metrics, the controller manager's and the scheduler's ports, TCP
2381, 10257 and 10259, and node-exporter's and the kubelet's from Prometheus, which keeps its scrape
connections; the Cilium agents' metrics, TCP 9962, which Prometheus scrapes on a connection it keeps
as well, and which no check asks for: their job, `cilium-agent`, is none of those `cluster-check`
reads ([kubernetes.md](kubernetes.md#ciliums-metrics)); Hubble, TCP 4244, which Hubble Relay keeps;
LINSTOR's satellites, TCP 3366-3367, to each of which the LINSTOR controller keeps its connection;
DRBD's replication, TCP 7000-7999, whose peers keep theirs; the DRBD reactors' metrics, TCP 9942,
which Prometheus scrapes on connections it keeps, and which no check asks for either; any path from
a pod on the node itself, from the pod range; trustd, TCP 50001, which a worker reaches when it
joins; the CI host; and the nodes' floating addresses. `tests/node-firewall.bats` pins their rules
offline.

After the rollout, each of these is proved once its client opens a new connection, which a restart
makes it do. Until each has been, watch:

1. Prometheus, restarted once: two scrape intervals later, `up` is 1 for every target of the
   kubelet, node-exporter and `cilium-agent` jobs, a target on every node, of the etcd, controller
   manager and scheduler jobs, a target on every control plane, and of the `linstor-satellite` job,
   a target on every worker. `just cluster-check` reads the targets of each of those jobs but
   `cilium-agent` and `linstor-satellite`, whose targets, the proof of the rules for TCP 9962 and
   9942, are read in Prometheus itself.
2. metrics-server, restarted once: `kubectl top nodes` answers for every node.
3. Hubble Relay, restarted once: it reports every node connected.
4. Cilium's agents, restarted one node at a time: `cilium-health status` reports every node
   reachable on the health port and through the overlay.
5. One control plane, rebooted with `just cluster-reboot`: once it is back, `etcd status` from every
   control plane shows the same leader and no error, as its peers have opened their streams again.
6. A worker's satellite pod, replaced: once its new pod is ready, `linstor node list` shows the node
   Online, which the controller reaches on a new connection to TCP 3367. A volume made afterwards:
   `linstor resource list` shows its resource Connected between the nodes that hold it, whose
   kernels connect to each other afresh on its port of 7000-7999
   ([kubernetes.md](kubernetes.md#storage)).
7. Cilium's WireGuard, once Cilium's values turn it on and every agent has restarted into them
   ([kubernetes.md](kubernetes.md#encryption-between-nodes)):
   in each agent's `cilium-dbg debuginfo --output json`, every peer of `cilium_wg0` has a recent
   `last-handshake-time`, and `cilium-health status` reports every node reachable through the
   overlay, which then runs through the device. The handshakes do not prove the rule on every
   node: the device sends from UDP 51871 to a peer's UDP 51871
   ([Linux](https://github.com/gregkh/linux/blob/v6.18.63/drivers/net/wireguard/socket.c#L20-L95),
   [the endpoint](https://github.com/cilium/cilium/blob/v1.20.4/pkg/wireguard/agent/agent.go#L575-L584)),
   so a node's packets to a peer and the peer's to it are one connection to the firewall, and what
   reaches a node from a peer it has sent to is a reply, which Talos admits whatever the rules say.
   The rule is what admits a peer's packets that arrive before the node has sent that peer anything.
8. trustd and the CI host stay unproved until a worker joins and the CI host connects; the paths
   from pods on a node to the node itself, until a pod there, such as Prometheus on a control
   plane, uses one.

### The way back

A node that fails its checks needs nothing: it reverts by itself. For a node that kept a
configuration whose rule turns out wrong, the rule is fixed in `talos/firewall.yaml`, and the fix
reaches the nodes the way every rule does: `just infra-apply sto2/cluster`, which renders it into
`talman.yaml` (the stack's output is the only way the file reaches it), then
`just cluster-talos --first <node>`.

The nodes admit the Talos and Kubernetes APIs from the allowlist their configuration holds, so a
change of the allowlist reaches them only from an address they admit before it. In order:

1. Add the new network to the allowlist, leaving the old one in it.
2. `just infra-apply sto2/cluster`, then `just cluster-talos --first <node>` from an address of the
   old allowlist.
3. Remove the old network, and apply and roll out the same way, now from the new one.

When the old address is gone already, the way back runs through the cluster itself:

1. `just infra-apply sto2/cluster` with the new network in the allowlist, from anywhere: it changes
   the cloud's side, the security group and the load balancer's listener, which then admits the new
   network, and writes a `talman.yaml` with it.
2. The Kubernetes API now answers through the load balancer: the load balancer connects to the API
   servers from its own addresses, which every control plane's firewall accepts as `loadbalancer`.
   This holds only while the load balancer proxies, as Octavia's amphora provider does; one that
   passes the client's address through would arrive from the new network, which no node admits
   yet.
3. A pod in `kube-system`, on the host network, runs talosctl with the cluster's talosconfig and
   each node's configuration as `talman render` writes it from the new `talman.yaml`, and applies
   them, one node at a time, through each node's Talos API at the node's own address on the node
   network: the pod's connections come from its node's own address, which every node accepts as
   `members`, and reach its own node over the loopback interface. A pod on the pod network reaches
   the other nodes the same way, masqueraded, as `members` ([Sources](#sources)), but its own
   node's Talos API at neither the node's address on the node network nor its floating address.
   The node holds both itself, the floating one on a dummy link
   (`talos/patches/all/floating-ip.yaml`), so the connection never leaves the node and nothing
   masquerades it: Cilium's masquerading is a rule of netfilter's postrouting hook, for what leaves
   through a device that is not Cilium's own
   ([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/pkg/datapath/iptables/iptables.go#L2206-L2241),
   [the hook](https://github.com/cilium/cilium/blob/v1.20.4/pkg/datapath/iptables/custom_chain.go#L43-L48)),
   and Cilium hands a packet for the node itself to the node's network stack as the pod sent it
   ([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/bpf/bpf_lxc.c#L1228-L1247),
   [L1366-L1385](https://github.com/cilium/cilium/blob/v1.20.4/bpf/bpf_lxc.c#L1366-L1385)). It
   arrives on the pod's interface, not on the loopback interface, which Talos admits whatever the
   rules say, in both of the firewall's chains
   ([Talos](https://github.com/siderolabs/talos/blob/v1.14.6/internal/app/machined/pkg/controllers/network/nftables_chain_config.go#L129-L143),
   [L331-L346](https://github.com/siderolabs/talos/blob/v1.14.6/internal/app/machined/pkg/controllers/network/nftables_chain_config.go#L331-L346)),
   and from the pod's own address, of the pod range, which the rule for the port does not accept
   (`tests/node-firewall.bats`). That is why the recovery pod is on the host network.
4. Once the nodes hold the new allowlist, `just cluster-talos` runs from the new network again.

The talosconfig and the rendered configurations hold the cluster's keys. They reach the pod as a
Secret in `kube-system`, whose Pod Security level allows the host network and which only cluster
administrators reach, created for the recovery and deleted with the pod as soon as it is done. No
recipe does this yet; one would render the configurations, put them and a talosconfig whose
endpoints are the nodes' own addresses into that Secret through kubectl's standard input, run the
pod from talosctl's image pinned by digest, apply in try mode node by node and keep each once it
answers from the new network, and delete the pod and the Secret on every exit.

The other way back is the CI host's address, when the configuration the nodes hold was rendered
with `ci_host_number` set: from the CI host, or a machine started at its address, the same
configurations are applied through each node's Talos API at its own address. Neither the cloud's
console nor a host elsewhere on the node network is a way back: the console shows Talos' dashboard
only, and the nodes admit no other address there.

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

## Scheduled etcd snapshots

A CronJob in the namespace `etcd-snapshots` (`apps/base/etcd-snapshots/etcd-snapshots/`) takes an
etcd snapshot every six hours, so the newest one never depends on an operator remembering. It
encrypts the snapshot to the Talos age key's recipient, the one `just cluster-snapshot` encrypts
to, before it leaves the pod, and uploads only that file to the etcd backup bucket as
`<cluster>/<UTC time>.snapshot.age`, the name the operator's recipe gives its own. `just
cluster-snapshots` lists the job's snapshots with the operator's, and `just cluster-restore latest`
restores the newest of either ([Recipes](#recipes), [the restore
runbook](runbooks/etcd-restore.md)). The private half of the age key is never in the cluster, so
the job can encrypt and cannot decrypt.

**The grant.** `talos/patches/controlplane/talos-api-access.yaml` is a `KubeTalosAPIAccessConfig`
document, which turns on Talos' access from Kubernetes on the control planes with `allowedRoles`
exactly `os:etcd:backup` and `allowedKubernetesNamespaces` exactly `etcd-snapshots`, a namespace
that holds nothing but this job. For a `talos.dev/v1alpha1` `ServiceAccount` in such a namespace
Talos makes a Secret of the same name holding a talosconfig whose client certificate carries the
requested roles, and its endpoint is the Service `talos.default`, which reaches the control planes'
Talos API. `tests/talos-check.bats` holds both lists exactly, and that the workers enable none of
it.

- What the role permits: Talos' etcd snapshot call and the read-only etcd status, member list and
  alarm list calls, and nothing that changes a node or reads its configuration, so no reset, reboot
  or upgrade. What it reaches is still every Secret of the cluster in the clear, as a snapshot
  holds them all: whoever can read the Secret `etcd-snapshots-talos`, or run a pod in the namespace
  with it, can take a snapshot, so the namespace is reserved for the job and its Secrets are the
  cluster administrators' to read.
- Why that is the narrowest: the machine configuration names namespaces and roles, not accounts, so
  the namespace is the unit of the grant; the role is the narrowest Talos has for a snapshot.

**What the nodes' firewall admits.** Nothing new. A control plane admits its Talos API port from
the nodes' own addresses ([The node firewall](#the-node-firewall), ADR 0017), and Cilium
masquerades a pod's connection to another node to the address of the node the pod runs on, so a
pod on a worker arrives as a node. The job's pod has no toleration and so runs on a worker, never
on a control plane, where a pod would arrive by its own address, which the rule does not admit.
No pod can use that to reach the port from anywhere else: what the port takes is a connection
authorised by Talos' own RBAC, which needs a certificate the Talos CA signed, and only the Secret
above holds one a pod can use, with only this role. The job asks the node `127.0.0.1` of the
control plane its connection reaches, the one the Service chose, so it needs no control plane's
address. The namespace holds no default deny of network policy, and
`network-policy-exceptions.yaml` lists it with the job's flows
([Network policy](kubernetes.md#network-policy)).

**The steps.** Four, each in the image that has its tool, so the repository builds none: age's
release, downloaded and checked against the SHA-256 pinned in the manifest (no public image carries
age, so it needs the pod to reach its release host); `talosctl`, the cluster's Talos version,
which writes the snapshot into a memory-backed volume of 1 GiB that only it and the encrypting
step mount, so the plain snapshot never reaches a disk and is never given to the upload; the
encrypting step, which removes the plain snapshot; and rclone, which uploads the encrypted file
and nothing else, and holds the S3 key. Every image is pinned by tag and digest. The `talosctl`
image's tag is `versions.yaml`'s `talos`, the cluster's Talos version, and
`tests/etcd-snapshots.bats` fails when they or the `talosctl` pin of `mise.toml` differ; Renovate
moves the image with the Talos group. A snapshot larger than its volume fails the run, which
`EtcdSnapshotJobFailing` reports. A step that fails fails the run, which is retried twice
under a 20 minute deadline, and a run never starts while another runs.

**The S3 key.** An `ExternalSecret` reads the two properties of the secret store's key `volsync`,
the cluster's S3 key, which `just bao-seed-volsync` has already written for the volume backups
([kubernetes.md](kubernetes.md#volume-backups)): nothing more is seeded. The key reaches every
bucket of the project, the etcd bucket among them, so it lets the job delete and overwrite
objects, as it lets every namespace that holds it; ADR 0008 states that residual risk. Only the
uploading container takes it, as environment variables from the Secret. The key is rotated as the
volume backups' is, whose store entry it is (`just bao-seed-volsync --rotate-s3`,
[kubernetes.md](kubernetes.md#the-repository-and-its-password)): each run's pod takes it from the
Secret as that then is.

**Retention.** The job keeps the newest 56 objects named as snapshots under the cluster's prefix,
two weeks of runs, and deletes the older ones once the new snapshot is listed, never any other
object. A bucket lifecycle rule would not need the right to delete, but no stack owns the backup
buckets ([infrastructure.md](infrastructure.md#s3-keys-and-backup-buckets)), so none can set one.
The count includes the operator's own snapshots under the same prefix.

**Selecting it.** The overlay of a cluster lists the namespace directory and the application's
`ks.yaml`, which waits for External Secrets, the secret store and the monitoring definitions. A
cluster whose overlay leaves them out builds none of it; the control planes' patch stays, as
`talos/talman.yaml.tftpl` lists it for every cluster, and grants a namespace nothing runs in. A
cluster that lists the job while its control planes lack the patch builds none of it either: Talos
creates the `ServiceAccount` kind of `talos.dev` only when the document is applied, and Flux
dry-runs every object of the application together and applies none when one fails, so neither the
CronJob nor the alerts exist and no alert fires. The only sign is the Kustomization `etcd-snapshots`
not Ready (`flux get kustomization etcd-snapshots`), which `FluxApplierNotReady` reports after 15
minutes ([kubernetes.md](kubernetes.md#alerts)).

**The recipient.** The recipient, `ETCD_SNAPSHOT_AGE_RECIPIENT` in the application's `ks.yaml`, is
`talos/.sops.yaml`'s, as the artifact holds `kubernetes/` only. `tests/etcd-snapshots.bats` fails
when they differ, so a new Talos age key (`just cluster-age-key`) changes both; the snapshots
already in the bucket stay encrypted to the old key.

**Seeing the last snapshot, and when the alert fires.** `just cluster-snapshots` lists the bucket's
snapshots, newest first. `kubectl --namespace etcd-snapshots get cronjob,job` shows the runs, and
`kubectl --namespace etcd-snapshots logs job/<job> --all-containers` says which step failed. To
take one now, `kubectl --namespace etcd-snapshots create job --from=cronjob/etcd-snapshots
<name>`. The alerts and what to do are in [the alerts' runbook](runbooks/alerts.md#etcdsnapshotstale).

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
- `just cluster-talos [cluster] [--onboard] [--yes] [--reboot [--tolerate <seconds>]
  [--no-bgp-wait]]` rolls the configuration out: the cluster's `talman.yaml` and the patches it
  lists, as they are now. It waits for every node as `cluster-bootstrap` does, then shows what
  `talman apply --dry-run` says would change on each node, with the cluster's secrets redacted, and
  applies once the cluster's name is typed back; `--yes` does not ask. talman applies one node at a
  time, control planes always alone, rebooting a node only when the change needs it and waiting for
  each to come back before the next. A node in maintenance mode, such as one OpenTofu has just
  added, is configured only with `--onboard`: the maintenance service authenticates nothing, and a
  node's configuration carries the cluster's keys. Without it, talman refuses a rollout while such a
  node is there. With nothing to change, nothing is asked or applied. Once the nodes keep the
  configuration, or when it stops after some took it, it names those that run an old setting until
  they reboot, as [A change that needs a reboot](#a-change-that-needs-a-reboot) says, and with
  `--reboot` reboots them one at a time, as `just cluster-reboot` does, which needs the kubeconfig;
  `--tolerate` and `--no-bgp-wait` are passed to each reboot, and `REBOOT_WAIT`, `BGP_WAIT`,
  `FORWARD_WAIT` and `FORWARD_SETTLE` are checked, with `--tolerate`, before anything is applied. It
  needs the cluster's `talman.yaml` and `secrets.sops.yaml` and the age key's location.

  `just cluster-talos [cluster] --first <node>` tries the configuration on each node before it keeps
  it, the named node first ([Rolling it out](#rolling-it-out)): it checks the cluster with
  `cluster-check` before anything is applied, and applies to a node in Talos' try mode, with talman
  waiting up to two minutes for it to answer, checks the paths into it from the other nodes, its
  readiness, for a control plane its own Kubernetes API and its place behind the load balancer, and
  the cluster, and applies again to keep it, one node at a time, skipping the nodes
  the configuration does not change. A failed check stops the rollout, saying that the node reverts
  by itself, which nodes kept the configuration before it and which are untouched. It needs what
  `cluster-talos` needs, the kubeconfig, at least two nodes of which one is another control plane,
  and node-exporter and Cilium running; it refuses a node `talman.yaml` does not list before it runs
  anything, and does not onboard. It prints node names only: what kubectl and talosctl print about
  the checks names addresses and stays out of the output.
- `just cluster-upgrade [cluster] [--yes] [--no-bgp-wait]` upgrades Talos on every node that does
  not run the version and schematic `talman.yaml` gives it. It shows which nodes `talman upgrade
  --dry-run` says are behind, and once the cluster's name is typed back, or with `--yes`, fetches
  the kubeconfig as `cluster-kubeconfig` does, takes an etcd snapshot as `cluster-snapshot` does,
  and goes through the nodes in `talman.yaml`'s order, one at a time. A node that is behind is
  drained with `kubectl drain`, upgraded with `talman upgrade`, and uncordoned once its kubelet has
  reported Ready since `talman upgrade` returned for it, within ten minutes, before the next is
  drained; a Ready condition from before then, including one posted after the drain, does not
  count. A node on its version is left alone. A worker is taken out of BGP before its drain and put
  back once it is uncordoned and its Cilium agent has stayed Ready since the upgrade, as
  `cluster-reboot` does it below (forward first, announce second), `--no-bgp-wait` applying to every
  worker the run takes out and skipping only the wait for its withdrawal, so at most one worker is
  out at a time and the edge routers withdraw its paths at once; a worker whose agent does not get
  there within `FORWARD_WAIT` stays out, the next is not taken out, and the run says so last; a
  control plane has no BGP, and a node whose role in `talman.yaml` is neither
  `controlplane` nor `worker` is not drained. `cluster-reboot`, `cluster-upgrade`,
  `cluster-upgrade-k8s` and `cluster-talos` hold the cluster's lock, flock's on
  `clusterconfig/cluster.lock` in its directory, for their whole run, and refuse, changing nothing,
  while another of them holds it: a `cluster-reboot` that `cluster-talos --reboot` runs shares its
  parent's, which it takes only from a descriptor open on the lock file itself. The lock goes when
  the run ends, however it ends, a kill that no trap sees included: `cluster-reboot`'s probe of
  `/readyz`, the one background process a run starts, closes the lock's descriptor first. A run
  killed outright while a foreground child it started runs, `talman reboot` or `upgrade`,
  `kubectl drain` or a `cluster-reboot` of `cluster-talos`, leaves that child holding the lock
  until it ends, which its own timeout bounds (`talosctl` thirty minutes, the drain ten). The
  recipes make `clusterconfig/` private (mode 0700) when the lock is the first thing to create it.
  The lock excludes only runs from this checkout, and nothing records which run set a
  worker's label, so a recipe removes a label it did not set only once the operator has confirmed
  the run. So, once the cluster's name is typed back, or with `--yes`, a worker out of BGP by a
  label this run did not set is put back before the first node is upgraded when it is Ready and
  schedulable, and taken out again like any other when it is behind; one that is not is taken
  through as out already when it is the first worker behind: drained, upgraded, uncordoned and put
  back; otherwise it stops the run before another worker is taken out, or, when none is behind,
  fails it at the end, saying why it is not put back. A worker put back that this run did not take
  out waits for its agent to be Ready for `FORWARD_SETTLE` seconds, as any other, and the run stops
  if it is not within `FORWARD_WAIT`. With nothing behind, nothing is asked, so a
  worker that is out is only reported, and the run fails. Either way the last line names the worker
  and the `kubectl label` command that puts it back. Before each drain the API must answer
  `/readyz` through the kubeconfig within five minutes, or nothing more is drained. talosctl's own
  drain is turned off, as it reaches the API at the cluster endpoint, which only the nodes reach.
  At the end every node must run its version. A run that stops after draining a node leaves that
  node cordoned: uncordon it with kubectl once it is back; a second run skips it once it is on its
  version.
- `just cluster-upgrade-k8s [cluster] [--yes]` upgrades Kubernetes to the version `talman.yaml`
  gives. It shows what `talman upgrade-k8s --dry-run` says, and once the cluster's name is typed
  back, or with `--yes`, takes an etcd snapshot as `cluster-snapshot` does and runs
  `talman upgrade-k8s`; talosctl moves the control plane components and the kubelets node by
  node. It reaches the API at `KUBE_API_ADDRESS`, given to talosctl as its endpoint. At the end
  every node must run the version.

  Both upgrade recipes do nothing and ask nothing when every node runs its version. Before they
  ask, they need what `cluster-talos` needs, the API address, and what `cluster-snapshot` needs:
  the age key's recipient, the bucket prefix and the state key. An etcd snapshot holds every Secret
  in the cluster, so the recipes take it the way `cluster-snapshot` does, encrypted and uploaded,
  and leave nothing of it on disk; a snapshot that cannot be taken stops the run before any node
  is touched. They never pass `--snapshot` to talman, which would write an unencrypted
  `etcd-<cluster>-<UTC time>.db` into `clusterconfig/`. Such a file there, mode 0600, is an etcd
  snapshot in the clear that holds every Secret of the cluster: no recipe removes it, and removing
  it is the operator's.
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
  prefix and the state key. `scripts/lib/snapshot.sh` holds the code, which both upgrade recipes
  run as well.
- `just cluster-snapshots [cluster]` lists the cluster's snapshots in the etcd bucket, reading only:
  one per line, newest first, by name and size in bytes, those the cluster's own CronJob took
  ([Scheduled etcd snapshots](#scheduled-etcd-snapshots)) and those of `cluster-snapshot` alike,
  as both name them by the UTC time. It needs the bucket prefix and the state key.
- `just cluster-restore <snapshot> [cluster] [--yes]` restores the cluster's etcd from a snapshot
  `cluster-snapshots` lists, or from `latest`, into the same nodes with the same secrets bundle;
  [runbooks/etcd-restore.md](runbooks/etcd-restore.md) says when, and what is lost. Before it
  changes anything it checks what it needs, finds the snapshot, downloads it into a private
  temporary directory as `cluster-snapshot` makes one, decrypts it there with the Talos age key, and
  waits for every node as `cluster-bootstrap` does; a snapshot that is not there, is not an age file
  or that the key cannot decrypt stops it. It says that the control planes are reset, the workers
  not, and the cluster's state replaced by the snapshot's, losing what was written since. It counts
  the PersistentVolumes of LINSTOR's driver the cluster has now, when its API answers through the
  kubeconfig and the kubeconfig may list them, and says so when not, and says, by number and not by
  name, that LINSTOR keeps its database in the Kubernetes API: a restore rolls its records back with
  the PersistentVolumes and claims while the volumes' data on the workers stays current, so a volume
  created after the snapshot is orphaned on the workers and one deleted after it comes back without
  its data, missing or created again empty ([the
  runbook](runbooks/etcd-restore.md#volumes-since-the-snapshot) says how to find and remove them,
  and when not to restore). It goes on once the cluster's name is typed back; `--yes` does not ask.
  `talman reset --group controlplane --reboot=true` then wipes each control plane's EPHEMERAL
  partition without leaving etcd and reboots it, and once every node answers again, `talman apply
  --bootstrap --recover-from` restores etcd from the snapshot on the first control plane, which the
  others join. It fetches the kubeconfig as `cluster-kubeconfig` does, and asks every ten seconds,
  ninety times at most, until every node in `talman.yaml`, workers included, reports Ready after the
  reset. What `cluster-bootstrap` applies before Flux is not applied again, as the restored etcd
  holds it. The decrypted snapshot is removed once etcd is restored and whenever the recipe exits.
  It needs what `cluster-talos` needs, the API address, the bucket prefix and the state key.
- `just cluster-config [cluster]` applies what Flux needs before it starts: the namespace
  `flux-system`, the ConfigMap `cluster-config`, the Secret `cluster-secrets` and the Secret
  `sops-age` ([kubernetes.md](kubernetes.md#before-flux-starts)). It refuses, naming each, when the
  cluster's `talman.yaml` or kubeconfig, `CLUSTER_DOMAIN`, `BACKUP_BUCKET_PREFIX`, the object
  storage's endpoint or region in `infra/openstack/backend.hcl`, the Flux age key or its recipient in
  `.sops.yaml` is missing, when the Flux age key is not the key of that recipient or is the Talos
  age key, and when a key of `cluster-config` or `cluster-secrets` cannot be filled or is not
  listed. `CLUSTER_DNS_ZONE` is read when set, the domain standing in for it when not, and refused
  when it is not the domain or a name the domain is under. The two edge addresses of
  `cluster-config` come from the edge stack's outputs, so it also needs the environment of the edge
  stack's recipes ([infrastructure.md](infrastructure.md#environment)) and refuses, naming the
  stack, while `sto2/edge` is not applied. A second run changes nothing.
- `just cluster-flux [cluster] [--reapply]` installs Flux on a cluster that runs none
  ([kubernetes.md](kubernetes.md#installing-flux)). It needs what `cluster-config` needs.
- `just app-adoption <application directory> [cluster]` watches Flux adopt an application that
  was installed before it and prints pass or FAIL per check; it only reads
  ([kubernetes.md](kubernetes.md#applications-installed-before-flux)).
- `just cluster-check [cluster]` says, reading only, whether the cluster is healthy, through its
  kubeconfig, which points at the API load balancer. It prints pass, FAIL or skip and one line of
  why for each check, and exits 0 only when none fails: `/readyz` answers; every node is Ready, a
  FAIL naming those that are not; there are as many nodes as the cluster's `talman.yaml` lists, a
  FAIL naming those missing and those it does not list; no Ready worker carries the label that
  takes it out of BGP (`node-restriction.kubernetes.io/bgp-out`), a FAIL naming each and the
  `kubectl label` command that puts it back, as a worker left out silently is capacity lost; no
  kube-proxy pod runs anywhere; every pod in `kube-system` and in `flux-system` is Running or
  Succeeded, a FAIL naming the others; no certificate signing request is Pending; and kubectl
  fetches the last log line of a Running pod in `kube-system`, which the API server reads from the
  pod's kubelet over the kubelet's serving certificate; and no scrape target of the cluster's own
  components is down: the jobs of the API server, the controller manager, the scheduler, etcd, the
  kubelets and node-exporter, asked of Prometheus through the API server's service proxy, a FAIL
  naming each job and the nodes it is down on, never an address; the pass says how many targets it
  saw. A job with no active target, as while Prometheus has just started or a monitor selects
  nothing, is skipped, naming the job, not passed. While the namespace `flux-system` does not exist,
  as before `just cluster-config` has run, the check of its pods is skipped, and its line and the
  last line say so. The scrape check is skipped, saying why, while Prometheus's Service does not
  exist, as before the monitoring application is installed, and when it cannot be asked or does not
  answer; its silence is never a pass. While the ConfigMap `cilium-config` in `kube-system` turns
  WireGuard on (`enable-wireguard: "true"`), the Running Cilium agent on every node the API lists
  is asked `cilium-dbg encrypt status --output json` through `kubectl exec`, each call stopped
  after 20 seconds, and must report the mode `Wireguard`, no message, which is where the agent's
  and the kernel's states of the device disagreeing show, the one device `cilium_wg0` and as many
  peers as there are other nodes, which it counts without matching them to the nodes; an answer
  that is not one JSON object is no answer. A FAIL names each node and why, never a public key
  ([kubernetes.md](kubernetes.md#encryption-between-nodes)). The check is skipped, saying so, while
  `cilium-config` does not turn WireGuard on, and fails when it cannot be read. It runs
  `kubectl get` and `kubectl logs`, and that one `kubectl exec`, so the kubeconfig then needs exec
  on the agents' pods in `kube-system`, as `just network-drops` does. It needs the cluster's
  `talman.yaml` and kubeconfig.
- `just gateway-check [cluster]` says, reading only, whether the cluster's public Gateway serves:
  its objects through the kubeconfig, then requests through each edge router's floating address
  with `curl --resolve`, verified against the cluster CA's certificate, then the DNS records of the
  routes' names through a public resolver and one request by a name alone, with pass, FAIL or skip
  and one line of why per check, never an address
  ([kubernetes.md](kubernetes.md#checking-the-public-gateway)). It needs the cluster's kubeconfig
  and what the edge stack's recipes need to read its outputs.
- `just grafana [cluster]` forwards a local port to Grafana through the cluster's kubeconfig until
  Ctrl-C ([kubernetes.md](kubernetes.md#grafana)): `kubectl port-forward`, listening on 127.0.0.1
  only, from `GRAFANA_PORT` to port 3000 of the Service `grafana-service` in `monitoring`. Once
  kubectl reports the forward it prints the local URL and where the admin password is kept, never
  the password, and reads no Secret. It ends the forward on every way out: Ctrl-C, SIGTERM or
  SIGHUP, kubectl not reporting the forward within `GRAFANA_WAIT` seconds, kubectl stopping, or a
  failure, each but an interruption naming its cause. It changes nothing on the cluster and needs
  the cluster's kubeconfig.
- `just locust [cluster]` forwards a local port to Locust's master through the cluster's kubeconfig
  until Ctrl-C ([kubernetes.md](kubernetes.md#locust)): `kubectl port-forward`, listening on
  127.0.0.1 only, from `LOCUST_PORT` to port 8089 of the Service `locust-master` in `locust`. Once
  kubectl reports the forward it prints the local URL and that the interface has no sign-in, so that
  anything on this machine, a web page in the browser included, can start a test through it while
  the forward runs. It ends the forward on every way out: Ctrl-C, SIGTERM or SIGHUP, kubectl not
  reporting the forward within `LOCUST_WAIT` seconds, kubectl stopping, or a failure, each but an
  interruption naming its cause. It reads no Secret, changes nothing on the cluster and needs the
  cluster's kubeconfig.
- `just robot [cluster]` forwards a local port to Robot Framework's report server through the
  cluster's kubeconfig until Ctrl-C ([kubernetes.md](kubernetes.md#robot-framework)): `kubectl
  port-forward`, listening on 127.0.0.1 only, from `ROBOT_PORT` to port 8080 of the Service
  `robot-reports` in `robot`. Once kubectl reports the forward it prints the local URL and that the
  reports hold screenshots and whatever the suites print, and are served to anything on this
  machine while the forward runs. It ends the forward on every way out: Ctrl-C, SIGTERM or SIGHUP,
  kubectl not reporting the forward within `ROBOT_WAIT` seconds, kubectl stopping, or a failure,
  each but an interruption naming its cause. It reads no Secret, changes nothing on the cluster and
  needs the cluster's kubeconfig.
- `just robot-run [cluster]` runs Robot Framework's suites on the cluster now, through its
  kubeconfig ([kubernetes.md](kubernetes.md#robot-framework)): it refuses, naming the job, while a
  job of the runner in `robot` has a pod; makes the job `robot-run-<UTC time>` from
  `cronjob/robot-suites`; waits up to `ROBOT_RUN_WAIT` seconds for its pod to leave `Pending`;
  prints the job's log, Robot's console, as it comes; and exits with the container's exit code,
  Robot's return code, the number of failed tests, printing `Every test passed.`, `<n> tests
  failed.`, what a code of 250 and above means, or, with status 1, the job's reason when it failed
  with no code, as at its deadline; then it points at `just robot` for the report. Ctrl-C, SIGTERM
  or SIGHUP stop the following with status 130, 143 or 129 and leave the job running, saying how to
  follow it again; it deletes nothing. It reads no Secret, changes nothing on the cluster but the
  job it creates, and needs the cluster's kubeconfig.
- `just logs '<query>' [--since <duration>] [--limit <n>] [cluster]` prints the records a LogsQL
  query matches, one line each, the oldest first, from the last 15 minutes and at most 200 unless
  told otherwise ([kubernetes.md](kubernetes.md#logs)): `kubectl get --raw` through the Kubernetes
  API's service proxy to VictoriaLogs, so no port is forwarded. It prints the records and, when it
  fails, the message of the error the API server or the store answered with, the store's own for a
  query it refuses, or that the API did not answer, without an address and none of kubectl's other
  output. It changes nothing on the cluster and needs the cluster's kubeconfig.
- `just cluster-reboot <node> [cluster] [--yes] [--tolerate <seconds>] [--no-bgp-wait]` reboots one
  node, named by its hostname in the cluster's `talman.yaml`, while it watches the Kubernetes API
  through its load balancer; for a control plane, that is the check that the API does not go away
  with one. Any other name, an address among them, is refused before anything runs; a node kubectl
  cannot read through the kubeconfig, and a `talman.yaml` whose roles cannot be read or name
  anything but `controlplane` and `worker`, before anything changes. A control plane is rebooted
  only while etcd is whole, as step 3 checks it: rebooting one while another's member is down, or
  while etcd holds a member that is no control plane, can leave etcd without a quorum, so the recipe
  stops before it asks for the name, says why, naming such a member by its hostname, and changes
  nothing. `cluster-upgrade` drains and upgrades the nodes with code of its own and does not check
  this. Once the node's name is typed back, or with `--yes`, a probe in the background asks
  `/readyz` through the kubeconfig once a second, giving each try two seconds, while the recipe, in
  order:
  0. for a worker, takes it out of BGP: labels it `node-restriction.kubernetes.io/bgp-out`, which
     the `CiliumBGPClusterConfig`'s node selector excludes and a kubelet cannot set or remove, and
     waits, up to `BGP_WAIT` seconds (120), until its `CiliumBGPNodeConfig` is gone. The operator
     deletes it when the node stops matching, and the agent, once it is gone, closes the node's
     sessions with a notification, so the edge routers withdraw its paths at once
     ([the sources](infrastructure.md#the-edge-routers)); the recipe sees the configuration, not
     the sessions, and `just edge-routes` shows the edges' side. It first records which of the
     node's sessions are established, and stops, changing nothing, when it cannot read the
     configuration or while another worker is out of BGP. A node that is out already, as after a run
     that stopped, is recognised and waited for, and put back after the reboot. A node's Cilium
     agent is what takes up the label, copying its Node's labels to its `CiliumNode`, so a worker
     whose agent is not running keeps its `CiliumBGPNodeConfig`, and the wait runs out, saying the
     configuration is still there and leaving the worker labelled. Then find out why the agent does
     not run (`just cluster-check` names a pod in `kube-system` that is not Running); when the
     reboot is still wanted, run the recipe again with `--no-bgp-wait`, which sets the label where
     it is not set yet, neither reads the configuration nor waits for it to go, says so, and goes on
     as usual. The edge routers may then keep the worker's paths as stale for up to the restart
     time, 120 seconds, from when its agent went down. `--no-bgp-wait` skips only this wait; the
     wait for the agent before the worker is put back, below, stays. A control plane has no BGP, and
     nothing here changes for it;
  1. cordons the node and drains it with `kubectl drain`, as `cluster-upgrade` drains, so nothing
     new is placed on it while it goes down: a kubelet that is shutting down rejects every pod it
     is given, and the scheduler would go on giving it the same replica, each rejected pod left in
     phase Failed;
  2. reboots it with `talman reboot -n <node> --yes`, which waits for it to come back, with
     talosctl's own drain off, as it reaches the API at the cluster endpoint, which only the nodes
     reach;
  3. waits, up to `REBOOT_WAIT` seconds, until the node is Ready with a heartbeat from after the
     reboot, as `cluster-restore` waits for its nodes, and, for a control plane, until etcd is
     whole again: `talosctl etcd status`, asked of every control plane through `talman talosctl`,
     shows each member following one leader in one term as a voting member without error, and the
     node's own member lists exactly the control planes of `talman.yaml`. A Talos control plane
     reports Ready without its etcd member, as its kubelet reaches the API through the others, so a
     control plane rebooted in with an etcd setting its member cannot start with is Ready all the
     same; rebooting another after it would leave etcd without a quorum. Nothing talosctl prints is
     shown, as it names addresses. The wait is checked between attempts, five seconds apart, so it
     can run one attempt over `REBOOT_WAIT`: talosctl sets no deadline of its own on a request, so
     an attempt lasts until the nodes answer or gRPC gives up connecting to one.

  Then it stops the probe and prints how many probes it made, how many failed and the longest run
  of failures, in seconds. It uncordons the node, unless it was unschedulable before the recipe
  ran: such a node stays cordoned, and the recipe says so. It then deletes, by namespace and name,
  the pods the shutdown left in phase Failed on the node, with the reason `NodeShutdown` (rejected
  while it shut down) or `Terminated` (terminated as it went down), which stay until they are
  deleted and on which `cluster-check` fails, and says how many, none included; every other pod
  stays. That comes before a worker is put back, as the shutdown can leave the node's Cilium agent
  pod Failed as well, and the wait below for every agent pod of the node to be Running and Ready
  would not end while it stays; such a pod is not running and carries no traffic, and the node is
  Ready, so removing it first costs nothing. A worker is then put back in BGP only once it forwards:
  forward first, announce second. A node that is Ready and uncordoned has a network
  plugin that answers its kubelet, and the moment its label goes its agent announces every Service
  address and an edge hashes a share of new connections to it, so a connection that arrives before
  the datapath forwards a Service's traffic to a backend on another node fails. The recipe therefore
  reads the node's Cilium agent pods (`kubectl get pods` on `k8s-app=cilium` in `kube-system`, with
  the node's name as a field selector; no `exec`) every two seconds until each is Running and Ready
  with a Ready condition that turned true after the reboot began, which leaves out the Ready the pod
  posted before the node went down but not one from while `talman reboot` waited for the node (it
  returns only once the node is Ready, and a pod's Ready does not refresh), and has stayed so, on
  every read, for `FORWARD_SETTLE` seconds (30). It waits for up to `FORWARD_WAIT` seconds (300),
  the settle time included. When the agent does not get there, or cannot be read, the label stays,
  the run fails saying what it waited for and for how long, and its last line names the worker and
  the `kubectl label` command that puts it back. A worker whose agent never reports that it forwards
  therefore stays out of BGP, and announces nothing, rather than being put back to fail the
  connections it is given.

  What the signal covers is what the pinned Cilium says of it (1.20.4, pinned in
  `kubernetes/apps/base/kube-system/cilium/app/ocirepository.yaml`). The
  agent's readiness probe is `GET /healthz` with the `brief` header on the node's loopback
  ([the chart's DaemonSet](https://github.com/cilium/cilium/blob/v1.20.4/install/kubernetes/cilium/templates/cilium-agent/daemonset.yaml)),
  which answers 200 unless the agent's status is not OK, and the status is not OK when not every
  probe of the agent has run yet, a probe's data is stale, the key-value store (off here) is not
  ready, or writing the CNI configuration file failed
  ([`agenthealth.go`](https://github.com/cilium/cilium/blob/v1.20.4/daemon/healthz/agenthealth.go),
  [`GetStatus`](https://github.com/cilium/cilium/blob/v1.20.4/pkg/status/status_collector.go#L552-L640)).
  The check that the Kubernetes API is reachable is not part of it: the handler is built without
  its configuration, so it applies that check only to a request that sends the
  `require-k8s-connectivity` header, which the chart's liveness probe sends and its readiness and
  startup probes do not. The same probe gates the pod's startup. So a Ready agent has started, has
  run every probe once, has none stale and has not failed to write its CNI configuration; its
  readiness does not say that the node's endpoints are
  regenerated or that its ipcache and tunnel map are in step with the other nodes, which a
  connection to a backend on another node needs. No signal the recipes can read with `kubectl get`
  does: the `CiliumNode` object's status holds the node's IPAM state and its cloud-specific state
  and nothing of the datapath
  ([`NodeStatus`](https://github.com/cilium/cilium/blob/v1.20.4/pkg/k8s/apis/cilium.io/v2/types.go#L487-L507));
  the node's `NetworkUnavailable` condition is set to false by the operator for a node that has a
  healthy Cilium pod
  ([`operator.setNodeNetworkStatus`](https://github.com/cilium/cilium/blob/v1.20.4/install/kubernetes/cilium/README.md)),
  so it follows the same readiness through one more hop; the `cilium-envoy` pod serves Cilium's L7
  proxy, which the chart leaves on; nothing here is L7-load-balanced (the Gateway is Envoy
  Gateway's) and no policy has L7 rules, so no Service's connection passes through it; and
  `cilium-health`'s node-to-node probes and `cilium status` need `kubectl exec`, which the recipes
  do not have. The settle time is therefore a margin, not a proof: it gives the agent time to
  regenerate its endpoints and synchronise its maps after it reports Ready, and Cilium's
  documentation gives no figure for how long that takes. A longer `FORWARD_SETTLE` widens the
  margin; `FORWARD_SETTLE=0` relies on the agent's readiness alone.

  Once the worker forwards, the recipe removes its label and waits, up to `BGP_WAIT` seconds, until
  the node's `CiliumBGPNodeConfig` is back and the sessions that were established before it was
  taken out are established again; a node with none before, as while the edge stack is not applied
  or an edge is stopped, is put back all the same, and the recipe says it does not wait for one; for
  a node whose sessions before are not known, one out already or taken out with `--no-bgp-wait`, it
  waits only until the configuration is back, and says so. It exits 0 only when the node is Ready
  again, with its etcd member for a control plane, and no probe failed; `--tolerate <seconds>`
  accepts runs of failures up to that long, for the operator to say what counts as an interruption
  (a whole number of at most nine digits, as the waits' variables are, [below](#environment)). A
  control plane after whose reboot etcd is not whole when the wait runs out fails the run, saying
  why and to reboot no other control plane until it is. A run that stops once the node is cordoned,
  as when the drain, the reboot or the wait fails, leaves it cordoned and says so: uncordon it with
  kubectl once it is Ready. A run that stops while a worker is out of BGP says so in its last line,
  with the command that puts it back, `kubectl label node <node>
  node-restriction.kubernetes.io/bgp-out-`, also when `cluster-talos --reboot` ran it;
  `cluster-check` fails until it is. The probe keeps its counts in memory and writes no file; it is
  stopped, with the kubectl or sleep it is waiting for, on every exit of the recipe, a failed or
  interrupted run included. It needs what `cluster-talos` needs and the kubeconfig.
- `just cluster-last-copies <openbao file> <volsync file> <postgres file> [cluster] [--check]` takes
  and checks, before the cluster is taken down, a last copy of everything the rebuild restores from
  ([runbooks/rebuild.md](runbooks/rebuild.md#taking-it-down)). The files are the custody files of
  `bao-recovery` (after a rotation of the seal key, the newest one `bao-seal-keep` wrote),
  `bao-seed-volsync` and `bao-seed-postgres`. First, before anything runs, it names
  each thing it needs that is missing: the kubeconfig, the Talos age key, the Flux age key, what
  `openbao-snapshot-check`, `postgres-dump-check` and `bao-volsync-password` need, and each file there
  and where only this user can have written it, each file named by its role. Then, reading only, it
  compares: each age key with the recipient its `.sops.yaml` names; the seal keys in the OpenBao file
  with the Secrets of the keys the checkout's seal stanza names, the current one and after a rotation
  the previous one, `openbao-seal-1` today (`bao-seal-restore <file> --check`, which also checks
  that the servers run that stanza, and refuses a file older than the current key with its reason on
  the lines above the recipe's own); for every ReplicationSource,
  the password the volume backups' file derives for its application with its Secret's
  (`bao-volsync-password`), by the hashes of the two; and the customer key in the PostgreSQL file
  with every database's backup Secret, by digest. It also needs every Cluster's primary, archiver
  plugin and dump CronJob, and on every ReplicationSource the labels of the Kustomization that owns
  it, which must not be suspended already, as the run resumes what it suspends and a hold set by
  hand would end with it. Nothing is taken until all of that holds, and it prints the plan, each
  copy by namespace and name; `--check` stops there, having created, patched and suspended nothing.
  Then, in order: a Job, named `last-<start in Unix seconds>-<CronJob>`, from
  `openbao/openbao-snapshots`, waited for, and `openbao-snapshot-check latest`; for every database a
  Job from its CronJob `<name>-pgdump`, waited for, `postgres-dump-check <namespace> <name> latest`,
  then `psql` in the primary's `postgres` container switches the WAL and names the newest complete
  segment, and `pg_stat_archiver` is read until the archiver has archived it, and the database's
  `ObjectStore` must report a recovery window; for every ReplicationSource, the Kustomization that
  owns it suspended with the flux CLI, so that its next apply does not drop the trigger, then, once
  no backup of it runs, `spec.trigger.manual` set to `last-<start>` and the backup waited for until
  `status.lastManualSync` is that tag and its mover's result `Successful`, then the Kustomization
  resumed. The trigger is the one field the run writes to an object Flux owns, for one backup while
  its Kustomization is suspended; the next apply takes it away, so the cluster is again what the
  tree holds. Each snapshot and dump must be named for a time no earlier than the run's start, to
  the second. The start is read from the operator's clock and each name is stamped by the clock of
  the pod that took the copy, so the comparison takes the two clocks to agree: an operator's clock
  ahead of the cluster's by more than a Job takes to start and name its copy fails every run, on the
  snapshot, as not taken by this run. Every wait is bounded by `LAST_COPIES_TIMEOUT` seconds, five
  between two reads, and every kubectl call the run makes itself but `exec` by 30 seconds; a `psql`
  in a pod is bounded by neither, as kubectl gives the stream of an exec no deadline, nor are the
  reads of the seal Secrets that `bao-seal-restore --check` makes. A copy that fails, fails its check, is
  older than the run or outlasts the wait fails the run, naming the copy and why, and no later copy
  is taken. Every run uploads a snapshot and a dump of each database it reaches, a run that fails
  later included, and the buckets keep the newest 56 snapshots and 14 dumps of each database, so
  each run pushes the oldest of them out. Every Kustomization it suspended is resumed on every exit,
  and the last line names one it could not resume, with the `flux resume kustomization` command. Its
  last lines are the summary, one per copy: the snapshot's name, each database's dump and the segment and time its WAL
  is archived through, and each volume's backup time. It prints nothing of a key, a password, an
  address, the endpoint or a bucket's name, and passes none as an argument: of kubectl's and the
  flux CLI's output it shows only their errors, through the filter of
  [What the recipes print](#what-the-recipes-print). It runs on lab-sto2 alone, as
  `bao-seal-restore` and `bao-volsync-password` compare with that cluster only.
- `just cluster-dns-remove [cluster] [--check] [--yes]` takes the cluster's DNS records out of the
  zone before the cluster and the edge stack are taken down
  ([runbooks/rebuild.md](runbooks/rebuild.md#taking-it-down)), by external-dns's own rules: a sync
  against the source `empty`, which asks for no record, deletes every record whose TXT registry
  entry names the cluster's owner id, and that entry, and leaves another owner's records and those
  made by hand ([kubernetes.md](kubernetes.md#dns-records)). A cluster without the Kustomization
  `flux-system/external-dns` does not select external-dns, and the run says so and ends. It reads
  `CLUSTER_DOMAIN` from `flux-system/cluster-config`, and refuses, naming why and changing nothing,
  a Deployment `external-dns/external-dns` whose container `external-dns` does not run with
  `--policy=sync`, `--registry=txt`, `--provider=cloudflare` and one `--txt-owner-id` other than the
  base's placeholder; it prints the owner id. Then the plan: a Job in `external-dns`, named
  `external-dns-remove-<start in Unix seconds>-plan` (the deleting one ends in `-delete`, the
  second plan in `-verify`), made from the Deployment's pod template, its
  image, service account, security contexts, resources and environment, the token by its
  reference to the Secret, and its arguments without the sources, the Gateway's, the namespace, the
  event and interval settings and the log format, and with `--source=empty`, `--once`,
  `--log-format=json` and `--dry-run`; no probe, no port, no service account token mounted,
  `restartPolicy: Never`, `backoffLimit: 0`, `DNS_REMOVE_TIMEOUT` as its `activeDeadlineSeconds`,
  and the label `app.kubernetes.io/name: external-dns-remove`, which the chart's Service and
  ServiceMonitor do not select. Its log, read as JSON lines, gives each record the sync would
  delete, printed as `delete <type> <name under the domain>`, one line per record at the provider,
  which holds an A record for each address of a name; a change other than a deletion, a record
  outside the domain or a line that is not JSON and names a change stops the run. The Job is
  deleted once read. `--check` stops there, having changed nothing but that Job; so does a plan
  that deletes nothing, without asking, as a second run does. Otherwise, once the cluster's name is
  typed back, or with `--yes`, it suspends the Kustomization `external-dns` and the HelmRelease
  `external-dns/external-dns` with the flux CLI and reads each back, stopping unless it is
  suspended, as the pinned CLI prints a failure to suspend and still exits 0; scales the Deployment
  to 0 and waits until no pod of it runs; runs the same Job without `--dry-run`, which ends complete
  only when its one pass succeeded, and prints its deletions; and plans again, failing, naming
  each, while a record of the owner is left. external-dns stays stopped, and the two suspended, and
  the run ends with how to start it again: `flux resume kustomization external-dns`, then
  `flux resume helmrelease external-dns --namespace external-dns`, after which helm-controller's
  drift detection scales the Deployment back to its one replica and external-dns makes the records
  again at its first sync. Those commands are run before the edge stack's destroy, or after it only
  once the edges are built again, `just cluster-config` has written their addresses to the cluster
  and `flux reconcile kustomization gateway-public` has applied them to the Gateway, whose
  annotation external-dns reads them from, and ended Ready
  ([runbooks/edge.md](runbooks/edge.md#the-way-back)). A Job that fails, or whose log the run does
  not read as external-dns', is kept, and the run names it with the `kubectl logs` command that
  reads its log, of which it prints nothing. A Job that does not end within the wait, or that its
  own deadline stops, is kept and named too; as that deadline is the wait's length, a deleting Job
  the run stopped waiting for can still be at work until it passes, when the Job controller deletes
  its pod, and the log with it, and `just cluster-dns-remove --check`, run after that, lists what is
  left. external-dns does not fail at once when it cannot reach the provider's API, so on a cluster
  that cannot reach it a run, `--check` included, can take the whole wait before it fails, naming
  the Job. Every exit after a suspension names last what is left suspended, or may be, as an object
  that cannot be read back, or scaled, and how to undo it. Every wait is bounded by
  `DNS_REMOVE_TIMEOUT` seconds, and every kubectl call by 30 seconds. It reads no Secret, passes
  nothing of the token on a command line, and prints nothing of the token, the zone's identifier,
  the domain, a name under it or an address; kubectl's and the flux CLI's errors pass through the
  filter of [What the recipes print](#what-the-recipes-print).
- `just cluster-destroy [cluster] [--yes] [--unreachable]` destroys the cluster stack,
  `sto2/cluster`, as `just infra-destroy sto2/cluster` does
  ([infrastructure.md](infrastructure.md#recipes)): it shows the plan's summary, destroys once the
  stack's name is typed back, or with `--yes`, and then removes the cluster's `talman.yaml`,
  talosconfig and kubeconfig. The plumbing stack, the secrets bundle and the buckets stay. The stack
  holds one cluster, so first, before it asks any cluster anything and whatever flags are given, it
  refuses a name other than the cluster name in the stack's `talman_yaml` output, saying which
  cluster the stack holds, or that the stack names none while its state holds resources, and the
  name of a cluster that has no directory under `talos/`. A stack whose state holds no resource,
  destroyed already or never applied, is not an error: the recipe says so, removes the cluster's
  generated files if they are there, and exits 0, as `infra-destroy` does; a state that cannot be
  read, or that is not a state, refuses. `cluster-env` does not make that refusal for every recipe:
  `cluster-secrets` and `infra-talman` run before a cluster's directory exists. Then, through the
  kubeconfig of the cluster it is given, it lists every Service of type LoadBalancer and every
  PersistentVolume of a CSI driver: a cloud load balancer or volume behind one is made by the
  cluster, not by OpenTofu, so the destroy would leave it in the cloud, where it keeps the network
  from being deleted. A Service whose every load-balancer address lies in the service range of the
  cluster's `talman.yaml` does not count: Cilium gave it that address and the workers announce it,
  and nothing in the cloud stands behind it ([kubernetes.md](kubernetes.md#service-addresses)). A Service without an address yet, or with one outside
  the range, counts, as does every one when `talman.yaml` names no service range. While there are
  any, it names each, by namespace and name or by the volume's name, and destroys nothing. Volumes
  of LINSTOR's driver, `linstor.csi.linbit.com`, are the other exception: their data is on the
  workers' data volumes ([above](#the-workers-data-device)), which the stack holds and deletes, so
  none of them stays in the cloud. They do not hold the destroy up; it says how many there are, by
  number and not by name, before it shows the plan, and the one confirmation, the stack's name typed
  back or `--yes`, destroys them with the stack. A cluster whose API does not answer, or that has no
  kubeconfig, cannot be asked and is not destroyed either, unless `--unreachable` is given: the
  operator then takes on whatever it owned, which stays in the cloud. Before it asks the cluster it
  checks what `infra-destroy` needs for the stack. The asking is `infra-destroy`'s own, through
  shared code, so `just infra-destroy sto2/cluster`, and `just infra-destroy` with no stack, ask the
  same, count the same Services and refuse the same; they take `--unreachable` too.
  [runbooks/rebuild.md](runbooks/rebuild.md) has it in the procedure around it.

A failing recipe ends with a line naming the step it failed in.

## Not automated

- Rebooting a node that does not answer on the Talos API port.
- Restarting Spegel's DaemonSet after `just cluster-talos` changes the nodes' CRI customizations or
  registry mirrors ([Rolling it out](#rolling-it-out)); the recipe does not say when a change does.

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
What rclone prints names the bucket and the endpoint, so the etcd recipes never show it. A failed S3
request does say why, though: of rclone's errors the recipes show only the reason, a few lines at
most, after each line has passed through a filter that replaces the value of every variable that
holds a key, the bucket prefix, the endpoint or the API address, matched literally, and every URL,
IPv4 and IPv6 address, host name with a dot in it and long token by pattern (`<redacted>`, `<url>`,
`<address>`, `<name>`, `<token>`; the filter is `redact_stream` in `scripts/lib/errors.sh`). A
denied request, a missing bucket and a name that does not resolve therefore read differently without
naming the place. With `CI` set nothing of rclone's words is shown: they go to
`clusterconfig/<recipe>.errors.log` in the cluster's directory, which git ignores, started afresh by
each run, and only that file's path is printed, as for talman's output. kubectl's and helm's output
passes through, naming the objects they apply, except in `cluster-check`, `gateway-check`,
`cluster-reboot`, `cluster-destroy`, `grafana`, `locust`, `robot`, `robot-run` and `logs`: they
print node and object names only, `logs` the records and `robot-run` the job's log, Robot's
console, and none of what kubectl prints, as the objects it reads and its
errors hold the API server's, the nodes' and the pods' addresses, but for the message of an error
the API server or the store answered with, which `logs` shows without an address; only
`kubectl drain`'s passes through in `cluster-reboot`, as in `cluster-upgrade`, naming the pods it
evicts and those it cannot, with its errors passed through the same filter line by line, so a
connection error still says why, `connection refused`. The checks of `cluster-talos --first` print
none of what kubectl, or talosctl through `talman talosctl`, prints either, but for a check whose
tool failed, its last line of error with every IPv4 and IPv6 address in it masked as `<address>`;
their `talman apply` dry runs print as talman's output does above.

## Environment

The recipes read `.env` and the environment as the infrastructure recipes do
([infrastructure.md](infrastructure.md#environment)), and name each variable that is missing. No
recipe prints a secret or passes one on a command line. Each tool gets only the secrets it uses
([infrastructure.md](infrastructure.md#environment)): talman, talosctl, kubectl and helm get none of
the S3, cloud or state secrets. sops and talman get the Talos age key's location from their
environment; `cluster-restore` hands age the key file's path, or, when only `SOPS_AGE_KEY` holds
the key, the key on standard input. `cluster-config` reads the Flux age key,
to hand it to kubectl and age-keygen on standard input.

- `SOPS_AGE_KEY_FILE`: the path of the Talos age key, outside the repository. In CI,
  `SOPS_AGE_KEY` holds the key itself instead. Every recipe that reaches the nodes needs one of
  them, as talman decrypts the bundle, and `cluster-restore` decrypts the snapshot with it.
- `BACKUP_BUCKET_PREFIX`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`: the start of the backup
  buckets' names and the state key ([infrastructure.md](infrastructure.md#environment)), with which
  `cluster-snapshot`, both upgrade recipes, `cluster-snapshots` and `cluster-restore` reach the
  etcd bucket, `postgres-dumps` and `postgres-dump-check` the postgres bucket, and
  `openbao-snapshots` and `openbao-snapshot-check` the OpenBao bucket, through rclone,
  configured as the infrastructure recipes configure it
  ([infrastructure.md](infrastructure.md#s3-keys-and-backup-buckets)). `cluster-last-copies` needs
  them for the two checks it runs, and the cluster's S3 key, `CLUSTER_S3_ACCESS_KEY_ID` and
  `CLUSTER_S3_SECRET_ACCESS_KEY`, for `bao-volsync-password`. `cluster-bootstrap`,
  `cluster-config` and `cluster-flux` need the prefix as well, which becomes `BACKUP_BUCKET_PREFIX`
  in `cluster-config`.
- `TMPDIR`: where `cluster-snapshot`, both upgrade recipes and `cluster-restore` make their private
  directory, `/tmp` when unset. Inside the repository it is refused.
- `KUBE_API_ADDRESS`: the Kubernetes API load balancer's floating address, an IPv4 address, as
  the API's certificate names are addresses. The cluster stack renders it into the cluster's
  `talman.yaml` as `values.apiAddress`, and the recipes read it from there; set in `.env` or the
  environment, it takes the place of that. `cluster-bootstrap`, `cluster-kubeconfig`,
  `cluster-restore` and the upgrade recipes need it. It reaches a command line in one place:
  `cluster-upgrade-k8s` hands it to talosctl as its endpoint.
- `TALOS_WAIT`: how many seconds `cluster-bootstrap`, `cluster-talos` and `cluster-restore` wait
  for the nodes, 600 when unset.
- `REBOOT_WAIT`: how many seconds `cluster-reboot` waits, once talman has rebooted the node, for it
  to report Ready and, for a control plane, for etcd to have its member back, 600 when unset.
- `BGP_WAIT`: how many seconds `cluster-reboot` and `cluster-upgrade` wait, for a worker, until its
  `CiliumBGPNodeConfig` is gone once it is labelled out of BGP, and until it is back with its
  sessions established once the label is removed, 120 when unset.
- `FORWARD_WAIT`: how many seconds `cluster-reboot` and `cluster-upgrade` wait, once a worker is
  Ready and uncordoned, for its Cilium agent to have stayed Ready for `FORWARD_SETTLE` seconds
  before the worker is put back in BGP, 300 when unset.
- `FORWARD_SETTLE`: for how many seconds, within `FORWARD_WAIT`, the worker's Cilium agent must
  have stayed Ready, on every read, before the worker is put back in BGP, 30 when unset. It is a
  margin for what the agent's readiness does not cover, not a proof of it; a value above
  `FORWARD_WAIT` is refused.

  `TALOS_WAIT`, `REBOOT_WAIT`, `BGP_WAIT`, `FORWARD_WAIT`, `FORWARD_SETTLE` and `--tolerate` are
  whole numbers of seconds of at most nine digits, read in base 10, so `08` is eight seconds. A
  longer value, which 64-bit arithmetic would wrap into a short, a negative or an endless wait, or
  anything that is not digits, is refused before anything runs, naming the variable and the bound.
- `FLUX_AGE_KEY_FILE`: the path of the Flux age key, outside the repository. In CI, `FLUX_AGE_KEY`
  holds the key itself instead. `cluster-bootstrap`, `cluster-config`, `cluster-flux` and
  `cluster-last-copies` need one of them.
- `LAST_COPIES_TIMEOUT`: how many seconds each wait of `cluster-last-copies` may take, for a Job, the
  archiver, a backup that runs already or the run's own backup, 3600 when unset; a whole number of
  at most nine digits, refused otherwise before anything runs.
- `CLUSTER_DOMAIN`: the domain the cluster's applications are published under, a lower-case DNS
  name, which becomes `CLUSTER_DOMAIN` in `cluster-config`; `cluster-bootstrap`, `cluster-config`
  and `cluster-flux` need it, and so does `just infra-destroy sto2/edge`, which looks the routes'
  names up under it ([infrastructure.md](infrastructure.md#recipes)).
- `DNS_REMOVE_TIMEOUT`: how many seconds each wait of `cluster-dns-remove` may take, for a Job or
  for external-dns' pod to go, and each of its Jobs may run, 300 when unset; a whole number from 1
  of at most nine digits, refused otherwise before anything runs.
- `CLUSTER_DNS_ZONE`: the zone at the DNS provider that holds `CLUSTER_DOMAIN`, a lower-case DNS
  name that is the domain or one it is under, which becomes `CLUSTER_DNS_ZONE` in `cluster-config`
  ([kubernetes.md](kubernetes.md#dns-records)); the domain itself when unset. Set it when the
  domain is a name under its zone, such as `lab.example.com` in the zone `example.com`.
- `ADOPTION_INTERVAL` and `ADOPTION_WAIT`: how many seconds `app-adoption` waits between two
  polls, 10 when unset, and in all, 900 when unset.
- `GRAFANA_PORT` and `GRAFANA_WAIT`: the local port `grafana` forwards from, 3000 when unset, and how
  many seconds it waits for kubectl to report the forward, 20 when unset.
- `LOCUST_PORT` and `LOCUST_WAIT`: the local port `locust` forwards from, 8089 when unset, and how
  many seconds it waits for kubectl to report the forward, 20 when unset.
- `ROBOT_PORT` and `ROBOT_WAIT`: the local port `robot` forwards from, 8090 when unset, and how
  many seconds it waits for kubectl to report the forward, 20 when unset.
- `ROBOT_RUN_WAIT`: how many seconds `robot-run` waits for its job's pod to leave `Pending`, and
  again for the job's result once its log ends, a whole number from 1 to 9999, 900 when unset.
- `CI`: when set, talman's output goes to a file instead of the output; see
  [What the recipes print](#what-the-recipes-print).

The recipes, the secrets bundle check aside, refuse to run while `GODEBUG` sets `http2debug`: Go's
HTTP/2 debug log prints the frames talosctl and kubectl send and receive, which carry machine
configurations and credentials.
