# Infrastructure

The OpenStack resources are OpenTofu stacks under `infra/openstack/stacks/<region>/`: `plumbing`
(the node network, its router and the Talos image), `cluster`, which builds on it, and `ci`, the
CI host, which builds on `plumbing` too ([The CI host](#the-ci-host)). Every command that runs
them is a `just` recipe.

## Recipes

- `just os-smoke` checks, reading only, that the `openstack` client is python-openstackclient
  7.0.0 or newer with its python-octaviaclient plugin; that the credential issues a token; that
  compute, volume, network, load-balancer, floating-IP and security-group-rule quota is not used
  up; and that the flavors and the external network the stacks' variables name exist. Quota left
  is not compared with what the stacks need. It prints pass or FAIL per item and no figures. The
  client is not pinned in `mise.toml`; it is installed separately.
- `just infra-state-bucket` creates the bucket `TF_STATE_BUCKET` names unless it exists, through
  the object storage's S3 API with the state key, as the backup buckets are created
  ([S3 keys and backup buckets](#s3-keys-and-backup-buckets)); it needs no OpenStack credentials.
  It prints neither the bucket's name nor what rclone reports, which names it and the endpoint, and
  creates nothing on a second run. A name that is not a bucket name, or that another project owns,
  fails without being printed.
- `just infra-plan sto2/plumbing` plans a stack and prints the plan's summary.
- `just infra-apply sto2/plumbing` plans a stack, prints the summary and, once the stack's name is
  typed back, applies that saved plan; `just infra-apply sto2/plumbing --yes`, or with `--yes`
  before the stack, does not ask. After
  the cluster stack it writes the cluster's `talman.yaml`, as `just infra-talman` does.
- `just infra-talman` writes the cluster's `talman.yaml` from the `sto2/cluster` stack's state;
  see [The generated talman.yaml](#the-generated-talmanyaml). It writes what the last apply left
  there, so a change to what the stack renders, such as a version in `versions.yaml`, reaches the
  file through `just infra-apply sto2/cluster` only.
- `just infra-output sto2/plumbing talos_version` prints one output of a stack. It refuses a
  sensitive output, as those hold the deployment's addresses and IDs.
- `just infra-forget-image` removes the Talos image from the `sto2/plumbing` stack's state with
  `tofu state rm` and leaves the image in the cloud, so that after a new Talos version or schematic
  the next apply uploads the new image and deletes nothing;
  [runbooks/image-replacement.md](runbooks/image-replacement.md) gives the steps around it. It first
  says in one line that only the state forgets the image, and acts once the stack's name is typed
  back; `just infra-forget-image --yes` does not ask. When the state holds no image it says so, asks
  nothing and changes nothing. It prints neither the state's list nor tofu's report.
- `just infra-destroy` destroys `sto2/cluster`, then `sto2/plumbing`. Each destroy is planned and
  summarised first, and runs once the stack's name is typed back; `just infra-destroy --yes` does
  not ask. When the cluster stack is not destroyed, the plumbing stack is left as it is. The load
  balancers and volumes the cluster creates itself, outside OpenTofu, are not removed, and the
  recipe says so; while any are left, the plumbing network cannot be deleted. Once the cluster
  stack is destroyed, the recipe removes the files generated for its cluster that hold the nodes'
  and the API's addresses, which the cloud may give to someone else: `talos/<cluster>/talman.yaml`
  and the talosconfig and kubeconfig in its `clusterconfig/`. It names each file it removes and
  removes only files git ignores; the secrets bundle and etcd snapshots stay.
  `just infra-destroy sto2/cluster`, or `sto2/plumbing`, destroys that stack only, the same way.
  `just cluster-destroy` ([cluster.md](cluster.md#recipes)) destroys the cluster stack so, once the
  cluster owns none of those load balancers and volumes. The `ci` stack is destroyed by its name
  only, `just infra-destroy sto2/ci`, the same way; `just infra-destroy` without a stack leaves it.
- `just ci-host-setup` and `just ci-host-remove` set up and deregister the CI host's runner
  ([runbooks/ci-host.md](runbooks/ci-host.md)).

Apply `plumbing` before `cluster` and `ci`, as both read the plumbing stack's state. Destroy goes
the other way round: `ci` by name, before `plumbing`, whose network its port is on. State objects
stay in the bucket after a destroy.

## Before the first plan

Once per deployment, before the first `just infra-plan`, in this order:

1. With the OpenStack authentication in `.env` ([Environment](#environment)),
   `just infra-s3-key state` creates the state key, S3 credentials for the project, and writes it
   to `.env` as `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
   ([S3 keys and backup buckets](#s3-keys-and-backup-buckets)).
2. Put the state bucket's name in `.env` as `TF_STATE_BUCKET`; `just infra-state-bucket` creates
   the bucket.
3. Choose the passphrase state and plans are encrypted with, 16 characters or more, put it in
   `.env` as `TF_STATE_PASSPHRASE`, and keep a copy outside the repository and the cluster
   ([State](#state)).

## S3 keys and backup buckets

etcd snapshots, OpenBao snapshots, VolSync repositories and Postgres backups go to four buckets in
the object storage: `BACKUP_BUCKET_PREFIX` followed by `-etcd`, `-openbao`, `-volsync` and
`-postgres`. No stack owns them, so `just infra-destroy` leaves them and their data:
`just infra-check` fails on a stack, or a module of this repository, that declares an object
storage container or an S3 bucket.

- `just infra-s3-key state` and `just infra-s3-key cluster` create an S3 key pair, an EC2
  credential, with the `openstack` client, in the version `os-smoke` needs, and write it to `.env`
  under the key set's names: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` for the state key,
  `CLUSTER_S3_ACCESS_KEY_ID` and `CLUSTER_S3_SECRET_ACCESS_KEY` for the cluster's. Neither value is
  printed. Nothing is created while `.env` is a symlink or a file git does not ignore, or while one
  of the names there holds a value; a name that is empty or a placeholder is filled in, an absent
  one is appended after a comment, and every other line stays as it is. `.env` is written to a
  temporary file beside it, mode 0600, and renamed into place.
- `just infra-backup-buckets` creates the four buckets unless they exist, through the object
  storage's S3 API with the state key, and names each by its role, never by its name. A second run
  creates nothing. A name another project owns fails, naming the role.
- `just infra-backup-check` checks, reading only, that the cluster's key is not the state key and
  that it lists each of the four buckets. It prints pass or FAIL per item.

The cluster's key exists so that it can be revoked on its own, without touching the state. Both
keys belong to the same project and reach every bucket in it, the state bucket included, which is
why state and snapshots are encrypted before they are uploaded
([ADR 0008](adr/0008-state-and-backups-are-encrypted-before-they-leave.md)).

These recipes, `just infra-state-bucket` and the etcd snapshot recipes `just cluster-snapshot`,
`cluster-snapshots` and `cluster-restore` ([cluster.md](cluster.md#recipes)) reach the object
storage with rclone, pinned in `mise.toml`, at the endpoint, region and addressing that
`infra/openstack/backend.hcl` gives OpenTofu's state. rclone is configured through its environment only and reads no config file; the
operator's own rclone configuration, its `RCLONE_` and `AWS_` variables and every other variable
but `PATH`, `HOME`, `TMPDIR` and the proxy variables stay out of its environment. What rclone
prints names the buckets and the endpoint, so it is not shown.

## The node subnet

The plumbing stack's node subnet, `node_cidr`, `10.10.0.0/24` by default, is shared by every
stack. Neutron hands out addresses itself only from the DHCP pool; everything else holds a fixed
address below it, by host number:

| Host number | Holder | Set by |
| --- | --- | --- |
| 1 | the gateway, the router's port | Neutron |
| 5 | the Kubernetes API's load balancer | the cluster stack |
| 6 | the CI host ([The CI host](#the-ci-host)) | the ci stack's `host_number` |
| 7 and 8 | the two edge routers ([Services announced over BGP](#services-announced-over-bgp)) | the plumbing stack's `edge_hosts` |
| 10 and up | the control planes | the cluster stack |
| 20 and up | the workers | the cluster stack |
| 100 to 200 | the DHCP pool | the plumbing stack |

These collisions are refused when a stack is planned:

- the edge routers on each other, on the gateway or in the DHCP pool (the plumbing stack);
- the CI host outside 2 to 9, on 5, or on an edge router (the ci stack, and the cluster stack for
  `ci_host_number`);
- a node or the API load balancer on an edge router (the cluster stack);
- the default service range on the default node, pod or service subnet (`just infra-check`,
  offline), and a configured one on the node subnet (the plumbing stack) or on the pod or service
  subnet (the cluster stack).

Nothing else is checked. The control planes and the workers keep apart from each other and below
the DHCP pool by their numbering alone, as long as there are at most ten control planes and eighty
workers.

## The workers' data volumes

The cluster stack gives every worker, and no control plane, one more volume besides its boot
volume: `<node>-data`, such as `lab-w-1-data`, of `worker_data_volume_size` GiB, 100 by default
and at least 2, and of the volume type `worker_data_volume_type`, `cbs` by default. Each is
attached to its worker by an attachment resource of its own, never as a block device of the
instance, so adding the volumes to running workers creates a volume and an attachment per worker
and changes no server. OpenTofu puts nothing on the volume: Talos hands it to the storage layer
under one device name ([cluster.md](cluster.md#the-workers-data-device), ADR 0011), and LINSTOR
keeps its storage pool on it ([kubernetes.md](kubernetes.md#storage)). The sensitive output
`worker_data_volumes` gives each volume's ID, name, size and type, and the instance and volume its
attachment joins.

The volumes belong to the cluster stack. `just infra-destroy` and `just cluster-destroy` delete
them with it, and what is on them is gone; backups are what keeps data
([ADR 0008](adr/0008-state-and-backups-are-encrypted-before-they-leave.md)).

## Services announced over BGP

Services of type `LoadBalancer` take their addresses from the service range, and every worker
advertises them over BGP to two edge routers on the node subnet
([kubernetes.md](kubernetes.md#service-addresses), ADR 0013). The plumbing stack defines the
numbers, once, as variables with defaults, and gives them to the cluster stack in its sensitive
output `bgp`:

- `service_range`, `10.20.0.0/28` by default: the range addresses come from. It lies in one of
  RFC 1918's private ranges and outside `node_cidr`, and the cluster stack refuses a `pod_subnet`
  or `service_subnet` that overlaps it. Only BGP makes it reachable, through the edge routers.
- `edge_hosts`, 7 and 8 by default: the host numbers of the edge routers' two addresses on the node
  subnet ([The node subnet](#the-node-subnet)), below the DHCP pool and above the gateway. They are
  reserved for the edge routers; no stack creates an instance at them yet, and until one does, the
  workers' BGP sessions stay down. The cluster stack refuses a plan in which a node, the API load
  balancer or `ci_host_number` takes one, and the ci stack one in which its `host_number` does.
- `cluster_asn` and `edge_asn`, 64513 and 64512 by default: the workers' and the edge routers'
  autonomous system numbers, two different private 16-bit numbers (64512 to 65534), for eBGP.

The cluster stack hands them on in `talman.yaml` ([below](#the-generated-talmanyaml)) and makes
the node network carry the range:

- Every worker's port lists the service range among its allowed address pairs. Port security lets
  a port send only from its own address and the pairs (Neutron's API reference, the
  `allowed_address_pairs` and `port_security_enabled` attributes of a port), and with OVN as
  Neutron's backend also receive only for them, so without the pair a worker could neither answer
  from a service address nor, there, be sent a packet for one. Control planes announce nothing and
  get no pair. The provider updates a port's allowed address pairs and security groups in place,
  so adding them to a running worker changes neither its port nor its server.
- The workers have a security group of their own besides the nodes', `<prefix>-workers`, whose
  only rules admit TCP on each port of `service_ports`, 80 and 443 by default, from each edge
  address, and which has no egress rule of its own. A rule matches a packet's protocol, port and
  source, never its destination, so it also admits those ports to the worker's own address: only
  TCP, only from the two edge addresses, and answered there only by a workload on the host's
  network or with a host port on that port, as Cilium serves a `LoadBalancer` Service's port on
  its address alone. No NodePort (30000 to 32767) is admitted from the edge routers unless
  `service_ports` names one. The workers open their BGP sessions to the edge routers on TCP 179
  themselves, through the nodes' group, which keeps Neutron's default egress rules; security
  groups are stateful, so the edge routers' side of a session passes, and no rule admits a
  connection to TCP 179. The sensitive output `worker_security_group` gives the group and its
  rules.
- The nodes' group is unchanged, and the edge addresses are not in it, but it already admits TCP
  6443 from the whole node subnet, for the API load balancer's connections to the API servers, and
  the edge addresses are on that subnet. In total, then, an edge router reaches the service ports
  on the workers, through the workers' group, and TCP 6443 on every node, which only control
  planes answer; nothing else.

## The nodes' security group

The cluster stack's nodes share one security group (`infra/openstack/modules/talos-nodes`), an outer
ring around the firewall every node keeps itself ([cluster.md](cluster.md#the-node-firewall), ADR
0017). The variable `security_group_rules` selects its rules, through `TF_VAR_security_group_rules`
in `.env` or the environment:

- `full`, the default: everything between the nodes; TCP 50000 (Talos) and 6443 (Kubernetes) from
  each network of the operator allowlist and from each node's floating address, as a node that
  reaches another node's floating address arrives from its own; TCP 6443 from the node subnet,
  where the API load balancer connects from; and TCP 50000 and 6443 from the CI host once
  `ci_host_number` is set ([The CI host](#the-ci-host)). Nothing else is admitted from outside the
  nodes.
- `reduced`: those rules, and every other TCP and UDP port and ICMP from all addresses but two
  ranges, which stay closed to everything outside the nodes and the rules above. The nodes' own
  firewall filters the rest. What it keeps is what a node cannot do for itself:
  - TCP 50000, the Talos API: a node that has no machine configuration yet, in maintenance mode, has
    no firewall and takes a configuration from anyone who reaches its Talos API.
  - TCP and UDP 30000-32767, Kubernetes' NodePort range: Cilium serves a NodePort from its eBPF
    datapath before the node's firewall sees the packet.

  The reduced rules keep the full ones, so a switch either way adds or removes the six rules open to
  all and rewrites the group's description in place, and no apply leaves the Talos API open. Cilium
  serves a pod's host port the same way as a NodePort, outside that range, so `reduced` suits a
  cluster where no pod declares a host port: Pod Security forbids them at the baseline level, which
  Talos enforces wherever a namespace sets no other, and only `kube-system`, `monitoring` and
  `piraeus-datastore` allow them, where the one pod with a host port, node-exporter, runs on the host
  network, where its port is the node's own and the firewall filters it. What else Cilium serves
  before the firewall, and what controls each, is in
  [cluster.md](cluster.md#what-the-firewall-does-not-see).

Planning with `full` changes no rule of a running cluster. The stack's tests check it offline, for
the rules' content and their resource addresses, which a plan would replace a rule over; the plan of
the running cluster, which shows no change to a resource, is the rest of that proof.

## The CI host

The `ci` stack makes one Linux VM on the plumbing stack's node network, outside the cluster, that
runs this repository's CI jobs for trusted events on a persistent Dagger engine
([ADR 0012](adr/0012-ci-runs-on-a-self-hosted-runner-for-trusted-events.md)). It reads the plumbing
stack's state and nothing of the cluster stack's, so the cluster can be destroyed and built again
around it; it is destroyed by name only ([Recipes](#recipes)).

- `<prefix>-ci`, `lab-ci` by default, of the flavor `flavor`, booting from a volume of
  `root_volume_size_gb` GB made from the image `CI_HOST_IMAGE` names, a Debian or Ubuntu cloud
  image. Its port is on the node subnet at host number `host_number`, 6 by default: below the DHCP
  pool and the control planes' 10, apart from the API load balancer's 5 and the edge routers' 7
  and 8, which the stack reads from the plumbing stack's state and refuses
  ([The node subnet](#the-node-subnet)). It has a floating IP from the plumbing stack's external
  network.
- Its security group admits TCP 22 from each network of the operator allowlist, the same
  `OPERATOR_CIDRS` or `operator-cidrs.json` the cluster stack takes, and nothing else inbound; it
  lets the host reach anything. The cloud's default rules are deleted, so the group holds only
  these.
- The operator's public key, `CI_HOST_SSH_PUBLIC_KEY`, reaches the image's default user through
  the host's key pair, `<prefix>-ci`.
- The cache volume, `<prefix>-ci-cache`, of `cache_volume_size` GiB, 100 by default, and the
  volume type `volume_type`, the project's default unless set, is attached by an attachment of its
  own. The host's first boot finds it under `/dev/disk/by-id` by its volume ID, formats it only
  when it holds no file system, and mounts it at `/var/lib/dagger`, where the engine keeps its
  state. Replacing the instance leaves the volume and its cache.
- The user data does nothing more than install a container runtime (`docker.io`), create the
  runner's user `runner_user`, `ci-runner` by default, with no password, no sudo and no groups,
  and mount the cache volume. It holds no secret: user data is kept in tofu state and served by
  the metadata service. Changing it replaces the instance.

Outputs: the sensitive `address` (the floating address, where `just ci-host-setup` connects),
`private_address`, `instance`, `user_data`, `security_group`, `floating_ip` and `cache_volume`; and
`runner_name`, `runner_user` and `cache_mountpoint`.

The cluster stack's nodes admit the CI host's fixed address on TCP 50000 (Talos) and 6443
(Kubernetes) once the cluster stack's `ci_host_number` holds the ci stack's `host_number`, through
`TF_VAR_ci_host_number` in `.env` or the environment. Without it, the default, the nodes admit
nothing for it, and the cluster stack plans whether the ci stack exists or not.

## The generated talman.yaml

The cluster stack renders `talos/talman.yaml.tftpl` from its own values into the sensitive output
`talman_yaml`: the cluster's name from `cluster_name`, `lab-sto2` by default; the load balancer's
address on the node network as the endpoint; the Talos and Kubernetes versions from
`versions.yaml`; the plumbing stack's node subnet and the stack's `pod_subnet` and
`service_subnet`, Kubernetes' conventional private ranges by default; the load balancer's two
addresses and each control plane's floating address as the API certificate names; the load
balancer's floating address as `values.apiAddress`, where the cluster recipes reach the Kubernetes
API ([cluster.md](cluster.md#environment)); the plumbing stack's service range as
`values.serviceRange` and its AS numbers and edge addresses as `values.bgp`, which
`just cluster-config` hands to the cluster ([Services announced over BGP](#services-announced-over-bgp));
the rules of the nodes' firewall for each role as `values.firewall`, from the listeners in
`talos/firewall.yaml` with the operator allowlist, `api_allowed_cidrs`, the subnets, the nodes'
floating addresses and their fixed addresses ([cluster.md](cluster.md#the-node-firewall)); and the
nodes,
control planes first and then workers, each by name and at its floating address, where talman
reaches it. Planning fails, naming the variable, when the pod or service subnet is not an IPv4
network, overlaps the other or the node subnet, or when the pod subnet holds fewer /24s than there
are nodes, as Kubernetes gives each node a /24 of it. The output `schematic_id` is the schematic ID
of the image the nodes boot.

`just infra-talman` writes `talman_yaml` to `talos/<cluster>/talman.yaml`, which git ignores, with
mode 0600, and never prints it. It writes a temporary file beside it and checks that file first.
talman must compute from `talos/schematic.yaml` the schematic ID the image was built from: OpenTofu
built the image from that file, and talman computes the installer image from it on its own, so if
they disagreed an upgrade would install another image than the one the nodes booted. Then
`talman validate` must pass with the repository's patches. Only then is the file renamed into place.
When a check fails the recipe says why, naming both IDs for a mismatch, removes the temporary file
and leaves an earlier `talman.yaml` as it was.

## Environment

The recipes read `.env` at the repository root when it exists, and the process environment
otherwise, as in CI. `.env` holds literal `NAME=value` lines and is never run as shell: nothing in
a value is expanded, one pair of quotes around a value is dropped, and blank lines and `#`
comments are skipped. Any other line stops the recipe, named by its number and not its content.
`.env.example` lists every name, with secrets left empty and placeholders starting with
`example-`.

A recipe checks the names it needs before it runs anything, and names each one that is missing,
empty or still a placeholder. It refuses to run while `TF_LOG`, `TF_LOG_PATH`, `TF_LOG_CORE` or
`TF_LOG_PROVIDER` is set, as tofu's logs would hold addresses and decrypted values; while
`TF_WORKSPACE` is set, as it would move a stack's state to another key; while `TF_CLI_ARGS` or any
`TF_CLI_ARGS_<command>` is set, as they add arguments to the tofu commands the recipes run; while
`TF_DATA_DIR` is set, as it would move a stack's working directory, with the saved plan and the
lock, out of its `.terraform/`; and while `GODEBUG` sets `http2debug`, as Go's HTTP/2 debug log
prints what tofu and its providers send and receive. No recipe prints a value or passes a secret
on a command line; secrets reach tofu and rclone through their environment.

- `TF_STATE_BUCKET`: the bucket that holds state.
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`: the state key, S3 credentials for that bucket,
  which also create the backup buckets.
- `BACKUP_BUCKET_PREFIX`: the start of the backup buckets' names, lower-case letters, digits and
  hyphens.
- `CLUSTER_S3_ACCESS_KEY_ID` and `CLUSTER_S3_SECRET_ACCESS_KEY`: the cluster's S3 key.
- `TF_STATE_PASSPHRASE`: the passphrase state and plans are encrypted with, 16 characters or more.
  tofu gets it inside `TF_ENCRYPTION` only, and the `openstack` client gets neither it nor the S3
  credentials.
- `OS_CLOUD`, naming a `clouds.yaml` entry outside the repository, or `OS_AUTH_URL` with the
  application-credential variables: OpenStack authentication, which tofu's provider and the
  `openstack` client read themselves. `os-smoke` and `infra-s3-key` need only this.
- `OPERATOR_CIDRS`, or else `operator-cidrs.json` at the repository root (gitignored): the
  operator allowlist of the cluster stack's APIs and the CI host's SSH, a JSON list of IPv4 CIDRs.
  An entry that is IPv6, or whose prefix is 0 and so covers every address, is refused, named by its
  position in the list and not by its value. It reaches tofu only in its environment, as
  `TF_VAR_api_allowed_cidrs` for the cluster stack and `TF_VAR_ssh_allowed_cidrs` for the ci stack,
  as given: the address of the machine the recipes run on is not added, and the recipe says so.
- `CI_HOST_IMAGE` and `CI_HOST_SSH_PUBLIC_KEY`: the ci stack's image name and the operator's SSH
  public key, which reach tofu as `TF_VAR_image_name` and `TF_VAR_ssh_public_key`; only the ci stack
  needs them. `CI_HOST_SSH_USER`: the image's default user, whom `just ci-host-setup` and
  `just ci-host-remove` log in as.
- `TF_VAR_ci_host_number`: the cluster stack's `ci_host_number`, set once the CI host exists
  ([The CI host](#the-ci-host)).
- `TF_VAR_security_group_rules`: the cluster stack's `security_group_rules`, `full` unless set to
  `reduced` ([The nodes' security group](#the-nodes-security-group)).
- `CI`: when set, tofu's errors go to a file instead of the output; see below.

## State

Each stack keeps its state in the bucket under a key made from its path, such as
`sto2/plumbing.tfstate`, through OpenTofu's `s3` backend. `infra/openstack/backend.hcl` holds the
object storage's public endpoint and the settings an S3-compatible store needs; the bucket comes
from the environment.

State and saved plans are encrypted on the machine that runs tofu, with OpenTofu's state
encryption: AES-GCM, with a key derived from `TF_STATE_PASSPHRASE` by PBKDF2. `scripts/stack-env`
passes the key provider and method in `TF_ENCRYPTION`, with encryption enforced, so tofu refuses an
unencrypted fallback a stack might declare. Each stack's `terraform` block enforces encryption too,
so tofu run by hand without `TF_ENCRYPTION`, or with an unencrypted method, refuses to run instead
of writing plaintext. `just infra-check` fails on a stack whose block does not. The cluster stack
reads the plumbing stack's state with the same settings; `scripts/stack-env` gives it the state's
location as `TF_VAR_plumbing_state`.

Losing the passphrase makes every state and saved plan unreadable. It is kept outside the
repository and the cluster.

The recipes do not handle these; they are done by hand when needed:

- Changing the passphrase needs the old key provider and method kept as a `fallback` in
  `TF_ENCRYPTION` for one apply of every stack, so each state is read with the old key and written
  with the new one.
- State that was ever written in plaintext is read only through an `unencrypted` method as a
  `fallback`, which the enforced settings refuse; migrating it means lifting enforcement for that
  one apply.

The object storage's own state locking is not used, as it is not verified that the store supports
it. The recipes lock each stack in the checkout they run from, with `flock` on a file under the
stack's `.terraform/`, and a second operation on a stack from that checkout fails saying the stack
is busy. The lock does not exclude CI or another checkout, so stacks are applied from one place at
a time. Without `flock` on `PATH` (it comes with util-linux), the recipes stop and say so.

## What the recipes print

Plan output is public in CI, and a full plan holds addresses, IDs and attribute values. The
recipes therefore show neither tofu's plan nor its apply report, only a summary that `jq` reads
from `tofu show -json` of the saved plan: tofu's counts line, then each action with how many
resources of each type it takes, then each output the plan changes, by its action and name and
never its value.

```text
sto2/cluster:
Plan: 4 to add, 1 to change, 2 to destroy.
  create: 1 openstack_compute_instance_v2
  create: 2 openstack_networking_port_v2
  update: 1 openstack_networking_router_v2
  replace: 1 openstack_networking_floatingip_v2
  delete: 1 openstack_blockstorage_volume_v3
  update: output talman_yaml
```

A replaced resource counts once to add and once to destroy, as in tofu's own counts line. Data
sources, and resources and outputs without changes, are left out. A plan that changes outputs
only, as the cluster stack's does after `versions.yaml` changes, is not "No changes.": applying it
writes the new outputs to the state. The full plan stays encrypted in `.terraform/infra.tfplan` in
the stack's directory.

When tofu fails, its errors can name resources and hold attribute values, API endpoints and the
bucket. Without `CI` set they are shown as tofu prints them. With `CI` set they go to
`.terraform/tofu-errors.log` in the stack's directory, and the recipe prints only which tofu
command failed and that file's path. talman's errors, which can quote node addresses, are handled
the same way.
