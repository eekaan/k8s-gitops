# Infrastructure

The OpenStack resources are OpenTofu stacks under `infra/openstack/stacks/<region>/`: `plumbing`
(the node network, its router and the Talos image), `cluster`, which builds on it, `ci`, the
CI host, and `edge`, the two edge routers, which build on `plumbing` too
([The CI host](#the-ci-host), [The edge routers](#the-edge-routers)). Every command that runs
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
  balancers and volumes the cluster creates itself, outside OpenTofu, are not in the stack's state,
  so its destroy would leave them in the cloud, where they keep the plumbing network from being
  deleted. So before it plans the cluster stack's destroy, whichever way it is asked for, the
  recipe asks the cluster, through its kubeconfig, for them, as `just cluster-destroy` does
  ([cluster.md](cluster.md#recipes) says what it lists and counts): while the cluster owns any, or
  cannot be asked, nothing is destroyed, unless `--unreachable` is given. A cluster stack whose
  state holds no resource, destroyed already or never applied, is not asked and is skipped with a
  line saying so, so a re-run ends as the first run did; a state that cannot be read, or that is
  not a state, refuses the run, and so does one whose lock cannot be taken. Once the cluster stack
  is destroyed, the recipe removes the files generated for its cluster that hold the nodes' and the
  API's addresses, which the cloud may give to someone else: `talos/<cluster>/talman.yaml`
  and the talosconfig and kubeconfig in its `clusterconfig/`. It names each file it removes and
  removes only files git ignores; the secrets bundle and etcd snapshots stay.
  `just infra-destroy sto2/cluster`, or `sto2/plumbing`, destroys that stack only, the same way.
  `just cluster-destroy` ([cluster.md](cluster.md#recipes)) destroys the cluster stack so, once the
  cluster owns none of those load balancers and volumes. The `ci` stack is destroyed by its name
  only, `just infra-destroy sto2/ci`, the same way; `just infra-destroy` without a stack leaves it.
  The plumbing stack's subnet and router interface cannot be removed while a port or a floating IP
  of another stack uses them, so a run that would destroy the plumbing stack, with no stack or with
  `sto2/plumbing`, first reads the state of every other stack of its region that the run does not
  destroy before it, and plans and destroys nothing while one holds a resource: it exits non-zero
  naming that stack and the recipe that destroys it, `just infra-destroy sto2/ci` or
  `just cluster-destroy`, and prints no resource's address. A stack that was never applied, or holds
  data sources only, holds nothing; a state that cannot be read, for any reason, refuses the run
  too.
- `just ci-host-setup` and `just ci-host-remove` set up and deregister the CI host's runner
  ([runbooks/ci-host.md](runbooks/ci-host.md)).
- `just os-images [pattern]` lists, reading only, the names of the public images the cloud offers,
  one per line and nothing else, those containing the pattern when one is given, so that
  `EDGE_IMAGE` and `CI_HOST_IMAGE` can be chosen without a console.
- `just edge-ssh-key` creates the edge routers' SSH key pair at `EDGE_SSH_KEY_FILE`, mode 0600 and
  without a passphrase, unless a key is there, and says only whether it did.
  `just edge-check [--edge 1|2]`, `just edge-routes [1|2]` and
  `just edge-rollout [--replace] [--yes]` check, show and roll out the edge routers
  ([The edge routers](#the-edge-routers), [runbooks/edge.md](runbooks/edge.md)).
- `just edge-policy-check` proves the edge routers' routing policy against real BGP speakers, with
  docker; `just ci` does the same inside its Dagger module ([Routing](#routing)).

Each module of `infra/openstack/modules` has its rules proved by `tests/*.tftest.hcl` beside it,
against mocked providers, so they need no credentials, state or cloud: valid inputs give the
resources and attributes the scenarios name, and each validation is shown refusing an invalid
input by a run that names its variable. A plan test reads the resources of the module under test
and the outputs it exports, so a rule added in a resource the outputs do not list is not caught, and
the tags on the nodes' group, the volume type of the nodes' boot volumes and the image's tags and
properties are not proved. The scenarios are in `features/infrastructure-modules.feature`, and `just infra-check`
runs every module's tests with the stacks'. To run one module's, run `tofu -chdir=<module> init
-backend=false` once and `tofu -chdir=<module> test`. Where a provider computes an attribute, a
plan shows only the mock's value for it, so a rule about an attribute left unset cannot be proved
there.

Apply `plumbing` before `cluster`, `ci` and `edge`, as all three read the plumbing stack's state.
Destroy goes the other way round: `ci` and `edge` by name, before `plumbing`, whose network their
ports are on, and which the recipe refuses to destroy while the `ci` or the `edge` stack holds
anything. `just infra-destroy sto2/edge` destroys the edge stack the same way as the ci stack;
`just infra-destroy` without a stack leaves both. State objects stay in the bucket after a destroy.

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
  temporary file beside it, mode 0600, and renamed into place. When the client fails, the recipe
  shows the reason it gave, a few lines at most, after each line has passed through the filter
  `redact_stream` in `scripts/lib/errors.sh`: the values of the variables that hold keys, the bucket
  prefix, the endpoint and the cloud's address are replaced as written, every byte that is not
  printable ASCII or a tab, the control characters among them, by a question mark, and every URL,
  address, host name with a dot in it and long token by pattern, so an unauthorized request and a
  name that does not resolve read differently without naming the endpoint, a project or a request.
  With `CI` set none of the client's words is shown: they go to `.env.infra-s3-key.errors` beside
  `.env`, which git ignores, and only its name is printed.
- `just infra-backup-buckets` creates the four buckets unless they exist, through the object
  storage's S3 API with the state key, and names each by its role, never by its name. A second run
  creates nothing. A name another project owns fails, naming the role.
- `just infra-backup-check` checks, reading only, that the cluster's key is not the state key and
  that it lists each of the four buckets. It prints pass or FAIL per item.

The cluster's key exists so that it can be revoked on its own, without touching the state. The
cluster's etcd snapshot job uses it to upload to the etcd bucket and to delete the oldest snapshots
([cluster.md](cluster.md#scheduled-etcd-snapshots)). Both keys belong to the same project and reach
every bucket in it, the state bucket included, which is why state and snapshots are encrypted
before they are uploaded
([ADR 0008](adr/0008-state-and-backups-are-encrypted-before-they-leave.md)).

These recipes, `just infra-state-bucket` and the etcd snapshot recipes `just cluster-snapshot`,
`cluster-snapshots` and `cluster-restore` ([cluster.md](cluster.md#recipes)) reach the object
storage with rclone, pinned in `mise.toml`, at the endpoint, region and addressing that
`infra/openstack/backend.hcl` gives OpenTofu's state. rclone is configured through its environment
only and reads no config file; the operator's own rclone configuration, its `RCLONE_` and `AWS_`
variables and every other variable but `PATH`, `HOME`, `TMPDIR` and the proxy variables stay out of
its environment. What rclone prints names the buckets and the endpoint, so it is not shown; of its
errors the etcd recipes show the reason only, with places and keys replaced, as
[cluster.md](cluster.md#what-the-recipes-print) says.

## The node subnet

The plumbing stack's node subnet, `node_cidr`, `10.10.0.0/24` by default, is shared by every
stack. Neutron hands out addresses itself only from the DHCP pool; everything else holds a fixed
address below it, by host number:

| Host number | Holder | Set by |
| --- | --- | --- |
| 1 | the gateway, the router's port | Neutron |
| 5 | the Kubernetes API's load balancer | the cluster stack |
| 6 | the CI host ([The CI host](#the-ci-host)) | the ci stack's `host_number` |
| 7 and 8 | the two edge routers ([The edge routers](#the-edge-routers)) | the plumbing stack's `edge_hosts`, built by the edge stack |
| 10 and up | the control planes | the cluster stack |
| 20 and up | the workers, of whom the edge routers take BGP sessions from 20 to 99 | the cluster stack's `worker_first_host`; the edge stack's `worker_first_host` and `max_workers` |
| 100 to 200 | the DHCP pool | the plumbing stack |

These collisions are refused when a stack is planned:

- the edge routers on each other, on the gateway or in the DHCP pool (the plumbing stack);
- the CI host outside 2 to 9, on 5, or on an edge router (the ci stack, and the cluster stack for
  `ci_host_number`);
- a node or the API load balancer on an edge router (the cluster stack);
- a worker in the DHCP pool, or a first worker below host number 20 (the cluster stack);
- the edge routers' block of workers in the DHCP pool, on an edge router or below host number 20
  (the edge stack);
- the default service range on the default node, pod or service subnet (`just infra-check`,
  offline), and a configured one on the node subnet (the plumbing stack) or on the pod or service
  subnet (the cluster stack).

Nothing else is checked. The control planes keep below the workers by their numbering alone, as
long as there are at most ten of them.

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
  reserved for the edge routers, which the edge stack makes there; until it is applied the workers'
  BGP sessions stay down. The cluster stack refuses a plan in which a node, the API load
  balancer or `ci_host_number` takes one, and the ci stack one in which its `host_number` does.
- `cluster_asn` and `edge_asn`, 64513 and 64512 by default: the workers' and the edge routers'
  autonomous system numbers, two different private 16-bit numbers (64512 to 65534), for eBGP.
- `gateway_host`, 1 by default: the host number in the service range of the public Gateway's
  address, the one address the edge routers forward public traffic to. It is neither the range's
  network address nor its last, and the plan fails naming the variable otherwise. The output `bgp`
  carries the address as `gateway_address`, and the cluster stack hands it on in `talman.yaml` as
  `values.bgp.gatewayAddress`, from which `just cluster-config` fills `GATEWAY_ADDRESS`. The
  LoadBalancer pool holds the whole range and does not set the address aside; the public Gateway's
  Service asks the pool for it by annotation
  ([kubernetes.md](kubernetes.md#the-public-gateway)).

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
  planes answer; nothing else. Behind the groups, every node's own firewall admits no listener from
  an edge address, the Kubernetes API included ([cluster.md](cluster.md#sources)).

## The nodes' security group

The cluster stack's nodes share one security group (`infra/openstack/modules/talos-nodes`), an outer
ring around the firewall every node keeps itself ([cluster.md](cluster.md#the-node-firewall), ADR
0017). The variable `security_group_rules`, through `TF_VAR_security_group_rules` in `.env` or the
environment, selects what the outer ring holds:

- `full`, the default: the nodes' group admits everything between the nodes; TCP 50000 (Talos) and
  6443 (Kubernetes) from each network of the operator allowlist and from each node's floating
  address, as a node that reaches another node's floating address arrives from its own; TCP 6443
  from the node subnet, where the API load balancer connects from; and TCP 50000 and 6443 from the
  CI host once `ci_host_number` is set ([The CI host](#the-ci-host)). Nothing else is admitted to a
  control plane from outside the nodes, and to a worker nothing else but what its own group admits.
- `reduced`: the same, and the control planes get a group of their own, `<prefix>-controlplanes`,
  with no egress rule, that admits every other TCP and UDP port and ICMP from all addresses but two
  ranges, which stay closed to everything outside the nodes and the rules above. The control
  planes' own firewall filters the rest. What it keeps is what a node cannot do for itself:
  - TCP 50000, the Talos API: a node that has no machine configuration yet, in maintenance mode, has
    no firewall and takes a configuration from anyone who reaches its Talos API.
  - TCP and UDP 30000-32767, Kubernetes' NodePort range: Cilium serves a NodePort from its eBPF
    datapath before the node's firewall sees the packet.

  The workers get nothing more. A rule matches a packet's protocol, port and source, never its
  destination, and a worker's port carries the service range, whose addresses Cilium serves before
  the worker's firewall sees the packet: open on a worker, every port of a Service's load-balancer
  address would be too, to the edge routers and whatever they forward. The workers therefore keep
  the nodes' group as it is and their own group ([Services announced over BGP](#services-announced-over-bgp)),
  which admits the edge routers to the service ports and nothing else, with either set.

  Neither set changes the nodes' group or the workers' group, so a switch either way adds or
  removes the control planes' group, its six rules and its place on their ports, and no apply
  leaves the Talos API open. Cilium serves a pod's host port the same way as a NodePort, outside
  that range, so `reduced` suits a cluster where no pod on a control plane declares a host port: Pod
  Security forbids them at the baseline level, which Talos enforces wherever a namespace sets no
  other, and only `kube-system`, `monitoring` and `piraeus-datastore` allow them, where the one pod
  with a host port, node-exporter, runs on the host network, where its port is the node's own and
  the firewall filters it. What else Cilium serves before the firewall, and what controls each, is
  in [cluster.md](cluster.md#what-the-firewall-does-not-see).

  With `reduced`, the control planes' group admits an edge router too, on every port it opens to
  all; the control planes' own firewall admits no listener from it, and a control plane carries no
  service range.

  What keeps a packet for a service address from being served on a control plane, where `reduced`
  opens the ports Cilium would serve it on: control planes announce nothing, as `cilium-bgp`
  selects workers only (`tests/install-cilium.bats` holds it), so no route leads such a packet to
  them, and their ports carry no allowed address pair for the service range (the cluster stack's
  tests hold it), so port security does not pass it to them either. A Service's external addresses,
  which Cilium serves on any node, are refused at admission when new (`DenyServiceExternalIPs`,
  [cluster.md](cluster.md#what-the-firewall-does-not-see)), but one a Service already holds is
  kept, so `reduced` suits a cluster where no Service holds one, as no Service under `kubernetes/`
  does.

Planning with `full` changes no rule of a running cluster. The stack's tests check it offline, for
the rules' content and their resource addresses, which a plan would replace a rule over; the rest of
that proof is `just infra-plan sto2/cluster` against the running cluster, which must plan no change
to a resource.

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

## The edge routers

The `edge` stack makes two small Linux VMs on the plumbing stack's node network that publish the
cluster's Services: the workers open BGP sessions to them and announce every `LoadBalancer`
Service's address as a /32, and each edge forwards traffic that arrives at its own public address to
the public Gateway's address, through the workers, and back
([ADR 0018](adr/0018-own-edge-routers-translate-public-traffic-to-the-gateway.md)). It reads the
plumbing stack's state and nothing of the cluster stack's, so the cluster can be destroyed and built
again around it; it is destroyed by name only ([Recipes](#recipes)).

- `<prefix>-edge-1` and `<prefix>-edge-2`, `lab-edge-1` and `lab-edge-2` by default, of the flavor
  `flavor`, each booting from a volume of `root_volume_size_gb` GB made from the image `EDGE_IMAGE`
  names. The configuration is written for Debian 13 (trixie), whose FRR is 10.3 and whose nftables
  is 1.1. The first boot checks the release and fails, on the console and in
  `/var/log/edge-first-boot.log`, on any other; nothing is refused at plan time. Each edge's port is
  at its reserved address on the node subnet, from the plumbing stack's output `bgp`. Each has a
  floating IP of its own from the plumbing stack's external network. A public hostname publishes
  both, and the sensitive output `addresses` gives them.
- Both are scheduled into one server group of the policy soft anti-affinity: the cloud keeps them on
  different hypervisors where it can and still places them where it cannot. A hard policy would
  refuse to place the replacement of one edge on a host that has room only beside the other, which
  is when a rebuild is needed. After a build, compare the hosts the two instances are on.
- Each port keeps port security on and has **no allowed address pair**. The Neutron API reference
  gives a port's allowed address pairs as the addresses it may send from when port security is on.
  An edge sends only from its own address, because it translates the source of what it forwards, and
  receives only for its own address, so nothing is added. Without the source translation it would
  send from every client's address and receive the answers for them: that takes a pair for every
  address, which the reference warns bypasses the source restrictions of rules that name a remote
  group, or port security off, and either removes the port's anti-spoofing.

### Routing

Each edge runs FRR's `bgpd`, which its daemon list turns on, and what FRR's start script starts
whatever the list says: `watchfrr`, `zebra`, which puts routes in the kernel, `mgmtd` and `staticd`.
Every other routing daemon is off in the list. Its configuration, `frr.conf`, is rendered from
`frr.conf.tftpl`, and each statement below is documented for FRR 10.3
([BGP](https://docs.frrouting.org/en/stable-10.3/bgp.html),
[prefix lists](https://docs.frrouting.org/en/stable-10.3/filter.html),
[static routes](https://docs.frrouting.org/en/stable-10.3/static.html),
[route maps](https://docs.frrouting.org/en/stable-10.3/routemap.html)):

- It runs in the plumbing stack's `edge_asn`, with the edge's own address as router ID. The peer
  group `workers` has the cluster's AS as its remote AS, and one `bgp listen range` per network of
  the workers' block names the peer group, so a worker's address that opens a session in the
  cluster's AS is a dynamic neighbour and no other source is (`bgp listen range`,
  `neighbor PEER peer-group`; the peer group is declared before the ranges that name it). The
  workers open the sessions and never listen. `bgp listen limit` is `max_workers`, 80 by default,
  the most workers the numbering of the cluster stack leaves room for
  ([The node subnet](#the-node-subnet)); FRR's default is 100.
- **Who may peer.** The workers' block is the host numbers from `worker_first_host`, 20 by default,
  for `max_workers`, 20 to 99: where the cluster stack numbers its workers, from its own
  `worker_first_host`, whose default a test holds equal to the edge stack's, and which one
  `TF_VAR_worker_first_host` sets for both. Both stacks refuse a value below 20. The stack writes it
  as the fewest networks that hold exactly those addresses, and refuses at plan time a block that
  reaches the DHCP pool or holds an edge's address. The node subnet also holds the control planes,
  the CI host and the other edge, and none of them may open a session: FRR's listen ranges, the
  nftables input rule for TCP 179 and the security group's rules for TCP 179 each admit the block
  and nothing else.
- Inbound, `neighbor workers route-map SERVICES-IN in` applies a route map that permits what the
  prefix list `SERVICES` matches: `permit <service range> ge 32 le 32`, a /32 inside the range and
  nothing shorter, then `deny any`. It also sets each accepted path's next hop to the worker that
  announced it (`set ip next-hop peer-address`), whatever next hop the announcement carries, so a
  worker can send the edge's traffic for a Service nowhere but to itself. Cilium announces its own
  address as next hop anyway, so this changes nothing while the workers behave. A route map in each
  direction is what `bgp ebgp-requires-policy`, on by default, asks of an eBGP session.
  `neighbor workers maximum-prefix` is the number of addresses of the range. FRR counts the prefixes
  it accepts (without `force`), and the list lets in no more than the range holds, so the limit is
  reached only if the list is loosened: it guards against that and tears the session down then. It
  does not cap what a peer sends and the list denies.
- Outbound, `neighbor workers route-map NOTHING-OUT out` applies a route map that denies everything,
  and the configuration has no `network` statement, no `default-originate` and redistributes
  nothing: an edge advertises nothing. A stack test compares the whole address family block, so a
  statement added to it fails.
- `ip route <service range> reject`, installed by `staticd`, makes the whole service range
  unreachable on the edge. A Service's /32 learned over BGP is more specific and wins. With no
  route for the Gateway's address, as right after a build before any worker announces it, a
  translated connection is refused on the edge and does not follow the edge's default route to the
  cloud's router, toward a private address of the provider's external side.
- The timers and the graceful restart time are those of the workers' `CiliumBGPPeerConfig`, which
  `main.tf` reads from `kubernetes/apps/base/kube-system/cilium-bgp/app/bgp-peer.yaml`:
  `neighbor workers timers <keepalive> <hold>`, `timers connect <retry>`, `bgp graceful-restart` and
  `bgp graceful-restart restart-time <seconds>`. They are written in the manifest alone, so a change
  there changes the edges' rendered configuration, which replaces both edges
  ([Rolling out a change](#rolling-out-a-change)); a stack test compares them with the manifest.
- `no bgp graceful-restart notification` turns off the notification bit of RFC 8538, which FRR 10.3
  sets by default. With it negotiated, graceful restart would also start when a session ends on a
  NOTIFICATION or an expired hold timer, and FRR would keep a dead worker's paths, as stale, for the
  restart time after its hold time: Cilium's operation guide says a peer "may need hold time +
  restart time to withdraw routes received from the node", about 129 seconds here, while new
  connections hashed to it go nowhere. How long the edges keep a worker's paths, by how its sessions
  end ([RFC 4724](https://www.rfc-editor.org/rfc/rfc4724),
  [RFC 8538](https://www.rfc-editor.org/rfc/rfc8538),
  [Cilium's BGP operation guide](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-operation/)):
  - **A dead or partitioned worker**, and a hung agent whose datapath still forwards: no keepalive
    comes, the hold time, 9 seconds, passes, and as the bit is not negotiated, its paths go then. A
    hung agent's go though its node could still serve; the other workers take its share.
  - **A Cilium agent that restarts**: Cilium 1.20 stops its BGP server without a NOTIFICATION to a
    peer that does graceful restart
    ([manager.go](https://github.com/cilium/cilium/blob/v1.20.4/pkg/bgp/manager/manager.go#L158-L161),
    [server.go](https://github.com/cilium/cilium/blob/v1.20.4/pkg/bgp/gobgp/server.go#L374-L390)),
    so the edges keep the worker's paths, stale, until the agent is back and has sent End-of-RIB, or
    for the restart time, 120 seconds, at most.
  - **A worker shut down or rebooted gracefully, with no step before it**: its agent stops the same
    way, so its paths stay stale for up to the restart time, and a shut-down worker's for all of
    it, with new connections hashed to it failing. The restart time in the workers'
    `CiliumBGPPeerConfig` bounds it.
  - **A worker taken out before a planned reboot**: withdrawn at once. The selector also requires
    that a node does not carry the label `node-restriction.kubernetes.io/bgp-out`, a key the
    NodeRestriction admission plugin keeps a kubelet from setting or removing on its own Node
    ([Kubernetes' admission controllers](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction)).
    The node's Cilium agent copies its Node's labels to its `CiliumNode`
    ([nodediscovery.go](https://github.com/cilium/cilium/blob/v1.20.4/pkg/nodediscovery/nodediscovery.go#L305)),
    whose labels the operator matches the selector against
    ([cluster.go](https://github.com/cilium/cilium/blob/v1.20.4/operator/pkg/bgp/cluster.go#L127-L128)),
    so a node whose agent is not running does not stop matching. A node that stops matching has its
    `CiliumBGPNodeConfig` deleted by the operator
    ([cluster.go](https://github.com/cilium/cilium/blob/v1.20.4/operator/pkg/bgp/cluster.go#L237-L247)),
    and the agent, once that is gone, withdraws the node's routes and stops its BGP server with a
    full destroy, which sends a notification to every peer
    ([controller.go](https://github.com/cilium/cilium/blob/v1.20.4/pkg/bgp/agent/controller.go#L189-L205),
    [manager.go](https://github.com/cilium/cilium/blob/v1.20.4/pkg/bgp/manager/manager.go#L505-L506)
    and [L791-L793](https://github.com/cilium/cilium/blob/v1.20.4/pkg/bgp/manager/manager.go#L791-L793),
    [server.go](https://github.com/cilium/cilium/blob/v1.20.4/pkg/bgp/gobgp/server.go#L381-L383)),
    and an edge that has not negotiated the bit withdraws the paths then (the guide's "Shutting Down
    a Node"). `just cluster-reboot` (and so `just cluster-talos --reboot`) and
    `just cluster-upgrade` set the label on a worker, wait until its `CiliumBGPNodeConfig`, which
    the operator keeps for each selected node, is gone, and only then drain it; that is the state
    the recipes can see through the kubeconfig, and the agent's closing of its sessions follows from
    it, which `just edge-routes` shows from the edges' side. With `--no-bgp-wait`, for a worker
    whose agent is not running, they set the label without that wait, and the edges may keep the
    worker's paths as stale for up to the restart time; that flag skips only this wait. Once the
    node is Ready again, and uncordoned unless it was cordoned before `cluster-reboot` ran, they
    wait until its Cilium agent pods have stayed Ready, since the reboot or upgrade, for
    `FORWARD_SETTLE` seconds (30) within `FORWARD_WAIT` seconds (300), and only then remove the
    label: forward first, announce second, as an edge hashes a share of new connections to a worker
    the moment its agent announces, and a Ready agent has started and run every probe of itself but
    is not shown to have regenerated its endpoints or synchronised its maps, which the settle time
    is a margin for, not a proof of ([cluster.md](cluster.md#recipes), under `cluster-reboot`, says
    what the readiness covers and why no other signal does better). A worker whose agent does not
    get there stays out of BGP, and the run says so last; a worker put back that the run did not
    take out is waited for in the same way. They then wait until its `CiliumBGPNodeConfig` is back
    with the sessions that were established before the label, which
    `status.bgpInstances[].peers[].peeringState` reports while Cilium's BGP status reporting is on,
    as the chart's values keep it, are established again
    ([bgp_node_types.go](https://github.com/cilium/cilium/blob/v1.20.4/pkg/k8s/apis/cilium.io/v2/bgp_node_types.go#L201),
    [conversions.go](https://github.com/cilium/cilium/blob/v1.20.4/pkg/bgp/types/conversions.go#L40-L41)).
    A worker with no established session before, as while the edge stack is not applied, with an
    edge stopped or one being replaced, is put back all the same, and the recipe says it does not
    wait for one; one whose sessions before are not known, as one out already or taken out with
    `--no-bgp-wait`, is waited for until its `CiliumBGPNodeConfig` is back. Both of those waits are
    bounded by `BGP_WAIT` seconds (120), a whole number of at most nine digits like every wait of
    these recipes. `just cluster-upgrade-k8s` drains and reboots no node and leaves the Cilium
    agents alone, so it takes none out. A control plane has no BGP. No more than one worker is out
    at a time: `cluster-reboot` and `cluster-upgrade` refuse to take a worker out while another is,
    naming it and the `kubectl label` command that puts it back, and `cluster-reboot`,
    `cluster-upgrade`, `cluster-upgrade-k8s` and `cluster-talos` hold the cluster's lock, so no two
    of them run at once from one checkout; the lock goes with the run, also one killed outright,
    though a foreground child such as `talman reboot` holds it until its own timeout ends it, and
    its directory is private. Nothing records which run set a label, so a recipe removes one it did
    not set only once the operator has confirmed the run: `cluster-upgrade` then puts back a worker
    that is out and Ready and schedulable and takes one that is out and is the first worker behind
    through as out already, drained, upgraded, uncordoned and put back, and `cluster-reboot` run for
    a worker that is out already puts it back after the reboot; `cluster-upgrade` with nothing to
    upgrade only reports one. A `cluster-reboot`, `cluster-upgrade` or `cluster-talos --reboot` that
    stops with a worker out says so last, with that command, and `just cluster-check` fails while a
    Ready worker carries the label.
- `maximum-paths` is `max_workers`: as many equal-cost paths to one address as there can be workers.
  The most FRR takes is what its build allows: 128 by its manual, 256 in Debian's package. The
  kernel setting `net.ipv4.fib_multipath_hash_policy = 1` hashes a flow's layer 4 fields, so every
  packet of a connection takes one path
  ([ip-sysctl](https://docs.kernel.org/networking/ip-sysctl.html)). Kernel multipath is not
  resilient: when the set of next hops changes, some flows are hashed again.
- There is no session between the two edges. One would give each edge the routes the other learns,
  so that an edge whose session with a worker is down could still reach the worker through the other
  edge, at the cost of an iBGP policy to write and test and of paths that loop through both.

The routing policy is proved against real BGP speakers (`just edge-policy-check`, and the `static`
group of `just ci`). The edge's configuration, as the stack's template renders it for fixture
values, runs in FRR's own container, FRR's upstream build of 10.3.4, where trixie packages
10.3-3+deb13u1, the same 10.3 release with Debian's patches, with no capability beyond the runtime's
default; under `just edge-policy-check` it has no network but its loopback, and under `just ci`'s
Dagger module it has the engine's default network, which the proof does not use: it binds and dials
loopback addresses only. Three speakers open sessions to it, each offering a /32 inside the service
range, a /32 outside it, a /30 inside it, the range itself and a default route. The check asserts
that the speaker in the cluster's AS at a worker's address is accepted and only its /32 inside the
range is in the edge's table, that the speaker in another AS and the one of the node subnet outside
the workers' block have no session, that the edge advertised nothing back, that the speaker holds no
path learned from the edge (which a `default-originate` would add and no count of advertised routes
shows), and that both ends' session was established once and never dropped, so the readings are not
of a session that is reset over and over. The proof reads nothing before it holds: it polls, once a
second, until every daemon answers (30 seconds at most), the accepted speaker's session is
established with its five prefixes offered (120), the edge has accepted one (60), and each refused
speaker has been refused (60 each); a wait that runs out is a FAIL that names it and what it last
saw, and a daemon that has stopped by then is shown with its own log. The proof runs to its end
whatever it finds, and when any check fails, the check prints everything the proof printed, in
`just edge-policy-check` as in `just ci`, whether the proof's container ended well or not. The
daemons keep the proof's own user, as FRR's own change to its `frr` user needs capabilities a
container is not given, and write only under one directory the proof makes in `/tmp`, a directory of
its own per daemon for its configuration, pid file, log and vty socket; the proof checks first that
each takes a new file, and nothing is written under `/etc/frr`, `/run/frr` or `/var/lib/frr`.
The daemons run the image's bgpd from a copy in that directory, the same binary byte for byte, so a
security profile a host attaches to FRR's installed path does not decide where a test instance may
write. `just edge-policy-check` runs it with no capability, no new privileges and the image's files
read-only, its `/tmp` letting the copy run, and a failed proof's report starts with the user it ran
as, its capabilities, its security label and its user namespace, and gives the label each daemon
ran under and, once, the label of FRR's installed bgpd. Each speaker announces its prefixes with a
next hop that is not its own address, and the check asserts that the accepted /32's path has the
speaker's address as next hop instead; and that the edge offers graceful restart without the
notification bit, as the speaker sees its capabilities. Before any of that, FRR's dry run (`vtysh -C -f`) reads the edge's
file as rendered, whole, and must accept it, and must refuse a copy with a command FRR does not
have, so the check is known to catch one. The static route is taken out of the file the proof's BGP
daemon reads, which has no `zebra` or `staticd` beside it; the stack's tests check it. The speakers
sit on loopback addresses, which FRR refuses as next hops (martian next hops), so the proof's copy
of the file also has `bgp allow-martian-nexthop`, and the routing policy alone decides what is
accepted; the workers' addresses on the node subnet are no martians. The proof does not show the
routes reaching the kernel, equal-cost paths across several workers, graceful restart across a
restart or the nftables rules, which the stack's tests compare as text and `nft --check` reads for
syntax at first boot: `nft` is in neither of the proof's containers, and `unshare` is not permitted
in either, so no network namespace of its own could hold the rules. The container's FRR takes 64
equal-cost paths where Debian's takes 256, so the proof renders with 64.

### The data path

Each edge's nftables rules, `nftables.conf` rendered from `nftables.conf.tftpl`, and its kernel
settings, `sysctl.conf`, are written once at first boot:

- A connection to the edge's own address on a port of `public_ports`, 80 and 443 by default, the
  same as the cluster stack's `service_ports`, which a test keeps equal, is destination translated
  to the public Gateway's address and source translated to the edge's own address
  ([nftables NAT](https://wiki.nftables.org/wiki-nftables/index.php/Performing_Network_Address_Translation_(NAT))).
  Forwarding is on in the kernel. The forward chain's first rule, ahead of what belongs to a
  connection, drops every packet of a translated connection toward the Gateway whose route's next
  hop is not a worker's address; then it admits what belongs to connections it has accepted, and a
  new translated connection to the Gateway on those ports through a worker; everything else is
  dropped. So with no worker's route to the Gateway's address, before FRR has learned one, or once
  FRR stops and zebra takes its routes out of the kernel (it does on exit; the edges run it without
  `-r`, which would leave them), a new connection is refused and an established one's packets are
  dropped at the edge, whether or not FRR's reject route is in place, and none of them follows the
  default route to the cloud's router
  ([nftables](https://wiki.nftables.org/wiki-nftables/index.php/Matching_routing_information); the
  kernel takes `rt nexthop` in any hook, the forward hook among them,
  [nft_rt.c](https://github.com/torvalds/linux/blob/v6.12/net/netfilter/nft_rt.c#L173-L178)).
  Replies come from the Gateway to the edge's own address, are translated back to the client's, and
  leave by the default route, the one way to a client, whatever FRR does. Nothing of IPv6 is
  forwarded: the kernel's IPv6 forwarding stays off, as `sysctl.conf` turns on IPv4's alone, and no
  rule admits it. `just edge-forward-check` proves this with the rendered rules in network
  namespaces on a developer's machine; the CI containers refuse the user namespaces it needs, and
  the stack's tests compare the chain's rules as text.
- zebra runs without `-r` (FRR's [zebra](https://docs.frrouting.org/en/stable-10.3/zebra.html):
  "When program terminates, do not flush routes installed by zebra from the kernel"). With it, an
  FRR that stops would leave its last routes to the workers in the kernel with nothing to withdraw
  them, and a worker that went meanwhile would keep its share of new connections for as long as
  FRR is down. Without it, an edge whose FRR stops forwards nothing, `just edge-check` fails it,
  and a client that retries can reach the other edge.
- The input chain drops everything addressed to the edge except what belongs to its own connections,
  loopback, TCP 22, TCP 179 from the workers' block and the ICMP destination unreachable,
  fragmentation needed, that path MTU discovery needs. IPv6 is dropped but for the ICMPv6 that
  neighbour discovery and path MTU discovery need.
- **The source translation is deliberate.** A worker answers a packet to the address it came from,
  through its default route, the cloud's router, unless that address is on the node subnet. Without
  the translation the answer to a client would leave by that router and never meet the connection it
  belongs to. Pods therefore see an edge's address, not the client's; ADR 0018 names the two ways to
  restore the client's address later and what each costs.
- ICMP redirects are off, as the edge forwards between hosts of one subnet.
- **What an edge can reach.** An edge is internet-facing on the public ports and sits on the node
  subnet, so the nodes' group rule for TCP 6443 from that subnet lets its packets reach every node,
  as [Services announced over BGP](#services-announced-over-bgp) states. Behind the group, each
  node's own firewall admits no listener from an edge's address, the Kubernetes API included
  ([cluster.md](cluster.md#sources)), so an edge reaches the service ports on the workers and
  nothing else. Beyond that, an edge holds no kubeconfig, token or client certificate, its first
  boot is given none, and its only inbound path from the internet is the two public ports,
  forwarded to the Gateway, and SSH from the operator allowlist.

The security group `<prefix>-edge` holds the rules the cloud enforces, and the cloud's default rules
are deleted. It admits TCP on each public port from each network of `public_allowed_cidrs`, which is
null by default and then the operator allowlist, so nothing is open to the world until that variable
is deliberately widened, for instance to `0.0.0.0/0`; TCP 22 from each network of the operator
allowlist, the same `OPERATOR_CIDRS` or `operator-cidrs.json` the other stacks take, as
`TF_VAR_ssh_allowed_cidrs`; TCP 179 from each network of the workers' block; ICMP destination
unreachable with code 4 from anywhere; and all egress. The nftables rules take the public ports and
SSH by port only: the allowlist and the public networks are in the security group and out of the
user data, which is kept in state and served by the metadata service. A packet
is admitted only when both the group and the rules admit it.

### First boot, packages and secrets

The configuration is delivered once, as cloud-init user data, which holds no secret: the routing
configuration and the firewall rules name the node subnet and the service range, and nothing names
the operator allowlist, the SSH key or a password. A BGP session password would have to be
generated and kept where both ends can read it. The cluster's side can hold it as a secret
(ADR 0005); an edge could only get it from its user data, which is kept in state and served by the
metadata service, or from a secret store it can reach, which does not exist for it yet. The sessions
carry none (ADR 0013).

The first boot checks the release, then turns unattended upgrades off: Debian's cloud images install
`unattended-upgrades`
([debian-cloud-images](https://salsa.debian.org/cloud-team/debian-cloud-images/-/blob/master/config_space/13/package_config/SYSTEM_BOOT)),
whose package turns them on by default (its `enable_auto_updates` template defaults to true), and
they would upgrade FRR and restart it in place; the first boot sets
`APT::Periodic::Unattended-Upgrade "0"` and disables `apt-daily-upgrade.timer`, and `apt` waits for
a lock an upgrade already running holds. It installs `frr` and `nftables` from the repositories of
the image's release, keeps FRR stopped, checks both files as cloud-init wrote them under
`/etc/edge`, the rules with `nft --check` and FRR's file with FRR's dry run (`vtysh -C -f`), before
anything of them is installed under `/etc`, then gives the SSH daemon its settings
([SSH and host keys](#ssh-and-host-keys)), loads the rules, starts FRR, waits until it answers and
its reject route for the service range is in the kernel, and turns forwarding on last. A file
either check refuses, settings the SSH daemon refuses, or any other failure, fails the first boot,
saying why on the console and in the log, and leaves forwarding off with its setting removed and FRR
stopped and disabled, so the edge forwards nothing until it is rebuilt. The release pins the
packages' versions only as far as the image's repositories do: a rebuild installs whatever the
release holds then, so a new edge may have newer packages than the one it replaces, and nothing pins
them further.

Changing anything the user data renders replaces that edge, as the OpenStack provider creates a
new instance when its `user_data` changes: an edge is rebuilt, not patched. Both edges render from
one template, so a change to it replaces both. The image is another matter: the `vm` module ignores
a change to an instance's boot device, as the Talos nodes need it to, so a new `EDGE_IMAGE`, or a
newer image under the same name, which the stack's `most_recent` lookup picks, plans no change by
itself. An edge takes it up only when its instance is replaced: whatever replaces an instance, the
new one is planned from the configuration alone and boots a new volume made from the image the name
resolves to then. A changed template replaces the edges anyway; for a new image alone,
`just edge-rollout --replace` replaces them ([Rolling out a change](#rolling-out-a-change)).

### Rolling out a change

`just infra-apply sto2/edge` refuses a plan that replaces or deletes both edges' instances, saying
so, as both would be down until the new ones answered, and a plan that replaces or deletes one while
the other does not pass `just edge-check`, which it runs first, naming the rollout instead.
`just edge-rollout` rolls such a change out. It plans and summarises the stack, and once the stack's
name is typed back (`--yes`: without asking) it checks that edge 2 passes `just edge-check`, plans
and applies edge 1 and its floating IP association alone (`-target`), records the new instance's
SSH host keys, and waits until `just edge-check --edge 1` passes, trying every
`EDGE_ROLLOUT_INTERVAL` seconds, 15 by default, for `EDGE_ROLLOUT_WAIT`, 900 by default. Then it
does the same for edge 2 and plans the whole stack once more. An edge whose check does not pass in
time stops the rollout there, and the edge after it is not touched; an edge is never replaced while
the other fails its check. As each edge's plan holds that edge's own resources alone, a change to
another resource, such as a rule of the security group, is left for `just infra-apply sto2/edge`,
which the last plan's summary is printed for.

`just edge-rollout --replace` does the same, and each edge's plan also replaces that edge's
instance, `-replace=module.edge["N"].openstack_compute_instance_v2.this`, whether the configuration
changed or not: the way a new image reaches the edges. Replacing the instance replaces its boot
volume, which Nova makes from the image and deletes with the instance (`delete_on_termination`). The
port is not replaced: it holds the fixed address and the floating IP's association, and the new
instance is attached to it, so the edge comes back at the same addresses, behind the same security
group, and the workers' sessions and the published address need nothing. A first boot on a new
volume is a clean one: cloud-init runs the user data again for the new instance. `--edge N` replaces
edge N alone, after the same check of the other edge; with `--other-down` it goes on when the other
edge does not pass either, once `replace edge N with edge M down` is typed back, `--yes` or not, as
with both down nothing serves anyway and replacing one is the way back
([runbooks/edge.md](runbooks/edge.md#replacing-one-edge)).

A new instance, a replacement or one created again for an instance gone from the cloud, has SSH host
keys of its own at the floating address the old one had, and the connection checks them strictly
against the recorded ones. The recorded keys of an edge whose instance a plan creates are therefore
dropped before the apply, by the rollout and by `just infra-apply sto2/edge` alike (`ssh-keygen -R`
on the edges' `known_hosts` file), and `just infra-destroy sto2/edge` drops both edges' keys. The
new ones are recorded the way the first build's were, from the instance's console
([SSH and host keys](#ssh-and-host-keys)): with no prompt when every key the address offers is one
its instance printed, refused when one is not, and shown for the operator's `yes` only when the
console holds no fingerprints by the end of the wait. The rollout does it once the new instance
answers on SSH, before the edge's check, reading the console within `EDGE_ROLLOUT_WAIT`, and stops
at once when a key is refused or not accepted; after `just infra-apply sto2/edge` the next
`just edge-check` does. The new instance is a new server with an identifier of its own, so the
rollout reads the stack's outputs again after each apply that creates an edge's instance and
reads the console that identifier names; outputs that still give the identifier of the instance
before it do not describe what the apply made, and the rollout stops there, with nothing read or
recorded, saying that `just infra-apply sto2/edge` writes the outputs when
`just infra-plan sto2/edge` lists `update: output instances` and no other change (a pending change
to the other edge lists it as well), and that once it lists no change to `output instances`,
`just edge-check --edge N` records the keys. An edge whose part of the plan does not create its
instance keeps its recorded keys.

### Checking and reading

`just edge-check` is read-only. Over SSH, with the edges' key and host keys recorded as the CI
host's are, it prints pass, FAIL or skip for each edge:

- FRR is running.
- As many sessions are established as the cluster's `talman.yaml` lists workers, and which worker
  has none otherwise, by each worker's own address, which the cluster stack writes there.
- The table holds only /32s inside the service range, the range from the same file.
- Each route has as many next hops as sessions, or fewer, which is a skip, as a Service that is
  local-only is announced by some workers only.
- FRR is configured with its reject route for the service range, for the range of the same file
  when there is one, and the kernel has it.
- The nftables tables are loaded, and the forward chain sends a translated connection's packets
  toward the Gateway, new or established, only through a worker: its first rule drops the rest
  ahead of what belongs to a connection, and both its guarded rules are for the cluster's Gateway,
  hold every worker's address of `talman.yaml` and not the edge's default route's next hop.
- The kernel forwards, which is a FAIL when it forwards without the rules. The state is read from
  `/proc/sys/net/ipv4/ip_forward`, the file the kernel exposes it as
  ([ip-sysctl](https://docs.kernel.org/networking/ip-sysctl.html)), as the edge's ordinary user and
  without `sudo`.
- Unattended upgrades are off.
- The SSH daemon runs with the settings the first boot wrote
  ([SSH and host keys](#ssh-and-host-keys)): each setting of `sshd.conf` is compared, whole, with
  what the daemon reports for a connection of the user the check connects as,
  `sudo -n sshd -T -C user=<EDGE_SSH_USER>,host=operator.example.org,addr=198.51.100.1,laddr=203.0.113.1,lport=22`,
  and a FAIL names the settings that differ, never their values. `-C` makes `sshd -T` apply the
  `Match` blocks that connection matches, so a `Match` on that user, or on a group the user is in,
  is in what is compared, as is a `Match LocalPort 22`: the port is the one the security group
  admits. Without a local port and address `sshd -T -C` refuses a configuration with a `Match` on
  either ([`sshd(8)`](https://man.openbsd.org/sshd#C), the daemon's `'Match LocalPort' in
  configuration but 'lport' not in connection test specification`), and the check would fail on
  it. The source address, host name and local address are of the ranges kept for documentation
  (RFC 5737, RFC 2606): a `Match` on an address or a host name is matched against those, a `Match
  LocalAddress` is matched against `203.0.113.1`, not the edge's own address, and what such a block
  changes for the operator's own connection is not checked.

The commands run on an edge are those of the ordinary user, whose `PATH` on Debian has no `sbin`
directory (`ENV_PATH` in `login.defs`, and the `PATH` OpenSSH's server gives a command run over
SSH), so a program that lives in `/usr/sbin` is run through `sudo -n`, whose `secure_path` has
them: `nft` and `sshd`. `vtysh`, `ip`, `systemctl` and `apt-config` are in `/usr/bin`. An answer the
edge could not give, as its command was not found or failed, is a FAIL of its own line, `cannot read
<what> on the edge: <what the edge said>`, with any address in the edge's words left out, and not
the unhealthy conclusion drawn from an empty answer; the other lines are still checked.

A worker that is down fails the sessions line on both edges, so no rollout gets past its first
check until the worker is back or the cluster stack no longer has it; the line counts every worker
of `talman.yaml`, as it cannot tell a worker that is away on purpose from one that is broken.
Without `talman.yaml` the checks that need it are skipped. It prints no address. `just edge-routes`
prints an edge's sessions and routes as FRR shows them, with addresses, for someone learning the
protocol: it refuses unless its standard output is a terminal and `CI` and `GITHUB_ACTIONS` are
unset, so the addresses never reach a CI log.

### SSH and host keys

SSH admits the operator allowlist only, by key only, as the image's default user (`EDGE_SSH_USER`,
`debian` by default). The SSH daemon's own settings are the tree's, `sshd.conf`, which the first
boot installs as `/etc/ssh/sshd_config.d/00-edge.conf`. An edge is a public host, so what its daemon
accepts is stated and checked, like its firewall: the edge states its daemon's key exchange,
ciphers, MACs and authentication itself, and none of them depends on what an image's own
configuration holds.

- Key exchange is limited to `mlkem768x25519-sha256`, `sntrup761x25519-sha512` and
  `curve25519-sha256`: the post-quantum hybrid key exchanges OpenSSH added in 9.9 under these names
  and made its default in 10.0 ([release notes](https://www.openssh.com/releaseNotes.html)), and the
  classical one a client that has no hybrid still offers. The client, `edge_ssh`, sets no key
  exchange of its own: an OpenSSH client from 10.0 offers `mlkem768x25519-sha256` first and
  negotiates it with these settings, and one older than 9.9 negotiates `curve25519-sha256`.
- Ciphers are limited to the authenticated encryption (AEAD) ones, `chacha20-poly1305@openssh.com`,
  `aes256-gcm@openssh.com` and `aes128-gcm@openssh.com`, and MACs, which those ciphers do not use,
  to the encrypt-then-MAC `hmac-sha2-512-etm@openssh.com` and `hmac-sha2-256-etm@openssh.com`.
  OpenSSH's own default lists hold each of them, and its client, which offers
  `chacha20-poly1305@openssh.com` first, negotiates that.
- Public key authentication only: `PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
  `PermitRootLogin no` and `AuthenticationMethods publickey`.
- No forwarding of any kind: `AllowTcpForwarding no`, `AllowAgentForwarding no`,
  `X11Forwarding no` and `PermitTunnel no`. Nothing the scripts do over SSH needs one.
- `AllowUsers` is not set: the user is the image's default user, which the tree does not know.

The drop-in wins over the image's own settings because of the order `sshd_config(5)` gives: an
`Include` reads the files that match in lexical order, and for each keyword the first value read is
used. Debian's main configuration includes `sshd_config.d` ahead of its own lines, so the file whose
name sorts first decides. That order decides the settings outside a `Match` block only: a `Match`
block, even one in a file read after the drop-in, changes a setting for the connections it matches,
and the drop-in cannot prevent it. The check reads the settings as the edge's user's connection
gets them ([Checking and reading](#checking-and-reading)), so such a block that turns passwords on
for that user is a FAIL. The first boot validates the whole configuration with `sshd -t` before it
tells the daemon to reload (`systemctl try-reload-or-restart ssh`, which leaves a daemon that is not
running to read it when it starts); a configuration the daemon refuses is taken out again, so the
daemon can start at the next boot, and fails the first boot like any other step. Where the machine
that runs the tests has an OpenSSH server, they read the tree's settings with it, `sshd -T`:
settings it refuses fail them, the tree's win against an image configuration that says otherwise,
and the check's reading of a `Match` for the edge's user is proved against it. Without one, they
prove only that the file's name sorts first, and the check's reading of a `Match` against a fake
daemon.

`just edge-ssh-key` creates the key pair at `EDGE_SSH_KEY_FILE`, and the stack reads the public half
from the file beside it. A host's key, an edge's in `~/.local/state/k8s-gitops/edge.known_hosts` and
the CI host's in `ci-host.known_hosts` beside it, is recorded on first contact, checked against the
host's instance's console. The recipe scans the address once, hashed (`ssh-keyscan -H`), and reads
the console, `openstack console log show --lines 1000`, by the instance identifier the stack's
outputs give (`instances` for the edges, by number, `instance` for the CI host), for the `SHA256:`
fingerprints in the latest complete block cloud-init's `keys_to_console` module printed between
`BEGIN SSH HOST KEY FINGERPRINTS` and `END SSH HOST KEY FINGERPRINTS`. The module writes what
cloud-init's `tools/write-ssh-key-fingerprints` prints to the console
([cc_keys_to_console.py](https://github.com/canonical/cloud-init/blob/25.1/cloudinit/config/cc_keys_to_console.py#L66-L69)),
and the tool sends each line of the block through util-linux's `logger -s -p user.info`, tagged
`cloud-init` from cloud-init 21.2
([write-ssh-key-fingerprints](https://github.com/canonical/cloud-init/blob/25.1/tools/write-ssh-key-fingerprints#L14),
changed in [#817](https://github.com/canonical/cloud-init/commit/13606a12054f)) and `ec2` up to
21.1 ([21.1](https://github.com/canonical/cloud-init/blob/21.1/tools/write-ssh-key-fingerprints#L4)).
So each line starts with logger's header as logger writes it for `user.info`
([logger.c](https://github.com/util-linux/util-linux/blob/v2.41/misc-utils/logger.c#L415-L434),
[L920-L931](https://github.com/util-linux/util-linux/blob/v2.41/misc-utils/logger.c#L920-L931)):
`<14>`, the month, the day padded with a space below 10, the time and the tag, as in
`<14>Nov  5 09:42:08 cloud-init: `. The recipe takes that header off in exactly that form, under
either tag, and reads no other line: not one without it, not the copy of a line the journal
forwards to the console, `[   74.767670] cloud-init[519]: ...`, and not a line a process on the
instance printed. A line may end in CR LF, as a serial console's terminal writes it; the CR is
dropped. The console is the instance's word, read through the cloud's API with the operator's
credentials and not through the address being verified; a cloud whose API lies is outside what
this defends against. With F the fingerprints the scan offers and C the console's:

- F is not empty and every member of F is in C: the scanned keys are recorded, with no prompt, and
  one line says how many and that they match.
- C is not empty and a member of F is not in C: refused. Nothing is recorded, no prompt is offered,
  `--yes` and a typed `yes` change nothing, and the recipe exits non-zero. No flag overrides it.
  [The runbook](runbooks/edge.md#a-new-hosts-ssh-key) lists what to check.
- C is empty, or the client failed, the instance is not found or the block is not there yet: the
  recipe reads the console again every `EDGE_ROLLOUT_INTERVAL` seconds within what is left of
  `EDGE_ROLLOUT_WAIT` in `just edge-rollout`, and every 5 seconds for `HOST_CONSOLE_WAIT` seconds,
  30 by default, elsewhere, then says why and asks: the fingerprints are shown, and the keys are
  recorded only once `yes` is typed. A client that cannot be run (no `OS_CLOUD` or `OS_AUTH_URL`,
  a client older than 7.0.0) is not tried again, and the operator is asked at once. The waits are
  timed with `date +%s`.

What is compared is what is recorded: there is no second scan between. The CI host is covered the
same way, by the `instance` output of the ci stack.

A key pair reaches an instance only when it is created, so a new pair
at `EDGE_SSH_KEY_FILE` replaces the stack's key pair and no instance, and the running edges admit
the old key alone until `just edge-rollout --replace` replaces them
([runbooks/edge.md](runbooks/edge.md#replacing-one-edge)).

Outputs, all sensitive but `names`: `addresses` (the floating addresses), `private_addresses`,
`instances`, `config` (each edge's rendered FRR configuration, nftables rules, kernel settings and
SSH daemon's settings), `user_data`, `server_group`, `security_group` and `floating_ips`.

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

The tools below get only the secrets they use. `scripts/lib/tools.sh` runs `tofu`, `openstack`,
`talman`, `talosctl`, `kubectl`, `helm`, `flux`, `kustomize`, `docker`, `curl`, `sops`, `age`,
`age-keygen`, `gh`, `ssh`, `ssh-keyscan` and `ssh-keygen` with the secrets they may not see
unexported, and `s3_rclone` hands rclone the one key pair it is called with. `scripts/render`,
`scripts/vector-config`, `scripts/rules-config`, `scripts/rules-image`, `scripts/rules-promtool`,
`scripts/ci-comment`, `vector-check` and `rules-check` run their tools the same way.
Every other tool, `jq`, `yq`, `git` and `flock` among them, gets the environment as it is: `jq`
reads `OPERATOR_CIDRS` from it by design, and none of them sends it anywhere. A wrapped tool a
script starts in the background, such as a port-forward, is started as `( exec_tool kubectl … ) &`,
so that the process id the script holds is the tool's and ending it ends the tool; the test fails
for the bare `kubectl … &`. Every variable of `.env.example` is listed, either as a secret with the
tools that may see it or as holding none, and a test fails for one that is not, whatever its prefix:
a new variable is assigned before it passes. One set by hand that begins `OS_` or `AWS_` and is
listed nowhere is a secret that only `tofu` sees.

A script runs a wrapped tool by its name. A test reads each script and justfile recipe as commands,
a backslash continuation and a `bash -c` body or a here-document fed to a shell included, and fails
for one that names a wrapped tool after `command`, `env`, `exec`, `timeout`, `sudo`, `xargs`,
`nice`, `nohup`, `setsid`, `stdbuf`, `ionice`, `chroot`, `su`, `doas`, `flock`, `watch`,
`parallel`, `mise x`, `mise exec`, `which` or `find -exec`, whatever options and lines come between,
in a `bash -c`, `sh -c` or here-document body, or in `$(type -P tool)`, `$(type -aP tool)` or
backticks, as each reaches the binary with the whole environment. A text scan cannot see a runner
held in an array or a variable (`"${cmd[@]}" kubectl`), a tool run from a script file or a
here-document fed to anything but a shell, or one run by another language's process call. Only the
tests that record a tool's environment catch those: `tests/tool-secrets.bats` for every wrapped tool and the S3
client, and for each of these recipes, the one that runs it: `tests/infra-recipes.bats` (tofu),
`tests/cluster-recipes.bats` (the upgrade recipes' talman, kubectl and age), `tests/ci-host.bats`
(gh, ssh), `tests/grafana.bats` (kubectl), `tests/render.bats` (flux, helm, kustomize),
`tests/logs.bats` (`vector-config`'s flux and helm) and `tests/ci.bats` (gh in `ci-comment`). The
docker of `vector-check` and `rules-check` has only the scan.

| Secret | Seen by |
| --- | --- |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `tofu`; rclone, as the state key set |
| `TF_ENCRYPTION` | `tofu` |
| `TF_STATE_PASSPHRASE` | none, as `TF_ENCRYPTION` carries the key derived from it |
| `CLUSTER_S3_ACCESS_KEY_ID`, `CLUSTER_S3_SECRET_ACCESS_KEY` | rclone, as the cluster key set; `bao-seed-volsync` and `bao-volsync-password` read them themselves, so they are in the environment of every command those scripts run unwrapped, such as jq, and are named on no command line; neither passes them to a wrapped tool, and the second gives their values to the command it runs as `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` |
| `OS_*`, the cloud credential | `tofu`, `openstack` |
| `GH_TOKEN`, `GITHUB_TOKEN` | `gh` |
| `TF_VAR_*`, the stacks' inputs, among them the allowlist; `TF_TOKEN_*`, registry tokens | `tofu` |
| `SOPS_AGE_KEY`, `SOPS_AGE_KEY_CMD` | `talman`, `sops` |
| `SOPS_AGE_KEY_FILE` | `talman`, `sops`, `age` |
| `FLUX_AGE_KEY`, `FLUX_AGE_KEY_FILE` | none; `flux_sops` gives sops the one it uses |
| `EDGE_SSH_KEY_FILE` | none; ssh is given the key by its path on the command line |
| `OPERATOR_CIDRS` | none; it reaches tofu as `TF_VAR_api_allowed_cidrs` and `TF_VAR_ssh_allowed_cidrs` |

- `TF_STATE_BUCKET`: the bucket that holds state.
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`: the state key, S3 credentials for that bucket,
  which also create the backup buckets.
- `BACKUP_BUCKET_PREFIX`: the start of the backup buckets' names, lower-case letters, digits and
  hyphens.
- `CLUSTER_S3_ACCESS_KEY_ID` and `CLUSTER_S3_SECRET_ACCESS_KEY`: the cluster's S3 key.
- `TF_STATE_PASSPHRASE`: the passphrase state and plans are encrypted with, 16 characters or more.
  tofu gets it inside `TF_ENCRYPTION` only.
- `OS_CLOUD`, naming a `clouds.yaml` entry outside the repository, or `OS_AUTH_URL` with the
  application-credential variables: OpenStack authentication, which tofu's provider and the
  `openstack` client read themselves. `os-smoke` and `infra-s3-key` need only this.
- `OPERATOR_CIDRS`, or else `operator-cidrs.json` at the repository root (gitignored): the
  operator allowlist of the cluster stack's APIs and the SSH of the CI host and the edge routers, a
  JSON list of IPv4 CIDRs.
  A network is no wider than `/16`, 65,536 addresses, the widest an operator's own allowlist
  reasonably holds, and is written by its own address, as `192.0.2.0/24` and not `192.0.2.5/24`.
  IPv6 networks are refused, as the stacks' rules and the load balancer's listener take IPv4 only,
  so no IPv6 prefix limit applies. An entry that breaks a rule is refused, named by its position in
  the list and the rule, not by its value. The `api_allowed_cidrs` variable of the cluster stack and
  the `ssh_allowed_cidrs` variable of the ci and edge stacks hold the same rule, so a `tofu` run
  outside the recipes cannot open the APIs or SSH wider either. The list reaches tofu only in its
  environment, as `TF_VAR_api_allowed_cidrs` for the cluster stack and `TF_VAR_ssh_allowed_cidrs`
  for the ci and edge stacks, as given: nothing is added to it, such as the address of the machine
  the recipes run on.
- `CI_HOST_IMAGE` and `CI_HOST_SSH_PUBLIC_KEY`: the ci stack's image name and the operator's SSH
  public key, which reach tofu as `TF_VAR_image_name` and `TF_VAR_ssh_public_key`; only the ci stack
  needs them. `CI_HOST_SSH_USER`: the image's default user, whom `just ci-host-setup` and
  `just ci-host-remove` log in as.
- `TF_VAR_ci_host_number`: the cluster stack's `ci_host_number`, set once the CI host exists
  ([The CI host](#the-ci-host)).
- `EDGE_IMAGE`: the edge stack's image name, a Debian 13 cloud image, which reaches tofu as
  `TF_VAR_edge_image_name`; `just os-images debian` lists the names. `EDGE_SSH_KEY_FILE`: the
  absolute path of the edge routers' private SSH key, whose public half beside it, with `.pub`
  added, reaches tofu as `TF_VAR_edge_ssh_public_key`; `just edge-ssh-key` creates both.
  `EDGE_SSH_USER`: the image's default user, `debian` when unset. `TF_VAR_public_allowed_cidrs`: the
  networks that may reach the edges' public ports, a JSON list of IPv4 CIDRs, unset for the operator
  allowlist. `EDGE_ROLLOUT_WAIT` and `EDGE_ROLLOUT_INTERVAL`: how long `just edge-rollout` waits for
  an edge to pass its check, 900 seconds when unset, and how often it tries, 15; the wait also
  bounds how long it reads a new instance's console for its host keys. `HOST_CONSOLE_WAIT`: how
  long the other recipes that connect to an edge or the CI host for the first time wait for the
  console to hold the fingerprints of its host keys before they ask, 30 seconds when unset. Each
  is a whole number of seconds of at most 9 digits, read in base 10 (`08` is eight); any other
  value is refused, naming the variable: by the recipes that connect to a host themselves
  (`edge-check`, `edge-routes`, `edge-rollout`, `ci-host-setup`, `ci-host-remove`) before they touch
  the stack, and by a recipe that runs one of them as a step (`infra-apply` for the edge stack) at
  that step, before anything connects to a host.
- `TF_VAR_security_group_rules`: the cluster stack's `security_group_rules`, `full` unless set to
  `reduced` ([The nodes' security group](#the-nodes-security-group)).
- `TF_VAR_worker_first_host`: the host number of the first worker, 20 when unset, for the cluster
  stack and the edge stack alike ([The node subnet](#the-node-subnet)).
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
is busy. `just edge-rollout` and `just infra-apply sto2/edge` run `just edge-check` under the lock
they hold, which they share with it through a descriptor it inherits: `edge-check` locks that
descriptor only when it is open on the stack's lock file, and the lock is granted only while it
shares the holder's, so an `edge-check` run on its own takes the lock itself and is refused while
another operation holds it, whatever its environment says. The lock does not exclude CI or another
checkout, so stacks are applied from one place at a time. Without `flock` on `PATH` (it comes with
util-linux), the recipes stop and say so.

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
