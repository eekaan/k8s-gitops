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
- `just os-images [pattern]` lists, reading only, the names of the public images the cloud offers,
  one per line and nothing else, those containing the pattern when one is given, so that
  `EDGE_IMAGE` and `CI_HOST_IMAGE` can be chosen without a console.
- `just edge-ssh-key` creates the edge routers' SSH key pair at `EDGE_SSH_KEY_FILE`, mode 0600 and
  without a passphrase, unless a key is there, and says only whether it did.
  `just edge-check [--edge 1|2]`, `just edge-routes [1|2]` and `just edge-rollout [--yes]` check,
  show and roll out the edge routers ([The edge routers](#the-edge-routers),
  [runbooks/edge.md](runbooks/edge.md)).
- `just edge-policy-check` proves the edge routers' routing policy against real BGP speakers, with
  docker; `just ci` does the same inside its Dagger module ([Routing](#routing)).

Apply `plumbing` before `cluster`, `ci` and `edge`, as all three read the plumbing stack's state.
Destroy goes the other way round: `ci` and `edge` by name, before `plumbing`, whose network their
ports are on. `just infra-destroy sto2/edge` destroys the edge stack the same way as the ci stack;
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
| 7 and 8 | the two edge routers ([The edge routers](#the-edge-routers)) | the plumbing stack's `edge_hosts`, built by the edge stack |
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
  LoadBalancer pool holds the whole range and does not set the address aside: keeping another
  Service from being given it first is for the change that adds the Gateway, which asks the pool
  for it by annotation.

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

Each edge runs FRR's `zebra`, which puts routes in the kernel, `mgmtd`, `staticd` and `bgpd`; every
other routing daemon is off in its daemon list. Its configuration, `frr.conf`, is rendered from
`frr.conf.tftpl`, and each statement below is documented for FRR 10.3
([BGP](https://docs.frrouting.org/en/stable-10.3/bgp.html),
[prefix lists](https://docs.frrouting.org/en/stable-10.3/filter.html),
[static routes](https://docs.frrouting.org/en/stable-10.3/static.html),
[route maps](https://docs.frrouting.org/en/stable-10.3/routemap.html)):

- It runs in the plumbing stack's `edge_asn`, with the edge's own address as router ID. The peer
  group `workers` has the cluster's AS as its remote AS, and `bgp listen range` names the node
  subnet and the peer group, so any host of the node subnet that opens a session in the cluster's AS
  is a dynamic neighbour and no other source is (`bgp listen range`, `neighbor PEER peer-group`; the
  peer group is declared before the range that names it). The workers open the sessions and never
  listen. `bgp listen limit` is `max_workers`, 80 by default, the most workers the numbering of the
  cluster stack leaves room for ([The node subnet](#the-node-subnet)); FRR's default is 100.
- Inbound, `neighbor workers route-map SERVICES-IN in` applies a route map that permits what the
  prefix list `SERVICES` matches: `permit <service range> ge 32 le 32`, a /32 inside the range and
  nothing shorter, then `deny any`. A route map in each direction is what `bgp ebgp-requires-policy`,
  on by default, asks of an eBGP session. `neighbor workers maximum-prefix` is the number of
  addresses of the range. FRR counts the prefixes it accepts (without `force`), and the list lets
  in no more than the range holds, so the limit is reached only if the list is loosened: it guards
  against that and tears the session down then. It does not cap what a peer sends and the list
  denies.
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
values, runs in FRR's own container, built for the release the Debian image packages, with no
capability beyond the runtime's default; under `just edge-policy-check` it has no network but its
loopback, and under `just ci`'s Dagger module it has the engine's default network, which the proof
does not use: it binds and dials loopback addresses only. Three speakers open
sessions to it, each offering a /32 inside the service range, a /32 outside it, a /30 inside it, the
range itself and a default route. The check asserts that the speaker in the cluster's AS inside the
listen range is accepted and only its /32 inside the range is in the edge's table, that the speaker
in another AS and the one outside the listen range have no session, that the edge advertised
nothing back, that the speaker holds no path learned from the edge (which a `default-originate`
would add and no count of advertised routes shows), and that both ends' session was established
once and never dropped, so the readings are not of a session that is reset over and over. The
static route is taken out of the file the proof's BGP daemon reads, which has no `zebra` or
`staticd` beside it; the stack's tests check it. The proof does not show the routes reaching the kernel, equal-cost paths across
several workers, graceful restart across a restart or the nftables rules, which the stack's tests
compare as text and `nft --check` reads for syntax at first boot. The container's FRR takes 64
equal-cost paths where Debian's takes 256, so the proof renders with 64.

### The data path

Each edge's nftables rules, `nftables.conf` rendered from `nftables.conf.tftpl`, and its kernel
settings, `sysctl.conf`, are written once at first boot:

- A connection to the edge's own address on a port of `public_ports`, 80 and 443 by default, the
  same as the cluster stack's `service_ports`, which a test keeps equal, is destination translated
  to the public Gateway's address and source translated to the edge's own address
  ([nftables NAT](https://wiki.nftables.org/wiki-nftables/index.php/Performing_Network_Address_Translation_(NAT))).
  Forwarding is on in the kernel, and the forward chain drops everything except new, translated
  connections to the Gateway on those ports and what belongs to connections it has accepted.
- The input chain drops everything addressed to the edge except what belongs to its own
  connections, loopback, TCP 22, TCP 179 from the node subnet and the ICMP destination unreachable,
  fragmentation needed, that path MTU discovery needs. IPv6 is dropped but for the ICMPv6 that
  neighbour discovery and path MTU discovery need.
- **The source translation is deliberate.** A worker answers a packet to the address it came from,
  through its default route, the cloud's router, unless that address is on the node subnet. Without
  the translation the answer to a client would leave by that router and never meet the connection it
  belongs to. Pods therefore see an edge's address, not the client's; ADR 0018 names the two ways to
  restore the client's address later and what each costs.
- ICMP redirects are off, as the edge forwards between hosts of one subnet.
- **What an edge can reach.** An edge is internet-facing on the public ports and sits on the node
  subnet, so the nodes' group rule for TCP 6443 from that subnet admits it to the Kubernetes API of
  every node, as [Services announced over BGP](#services-announced-over-bgp) states. The control is the API's own
  authentication and authorisation: an edge holds no kubeconfig, token or client certificate, its
  first boot is given none, and its only inbound path from the internet is the two public ports,
  forwarded to the Gateway, and SSH from the operator allowlist. The group rule is not narrowed to
  exclude the edges' addresses.

The security group `<prefix>-edge` holds the rules the cloud enforces, and the cloud's default rules
are deleted. It admits TCP on each public port from each network of `public_allowed_cidrs`, which is
null by default and then the operator allowlist, so nothing is open to the world until that variable
is deliberately widened, for instance to `0.0.0.0/0`; TCP 22 from each network of the operator
allowlist, the same `OPERATOR_CIDRS` or `operator-cidrs.json` the other stacks take, as
`TF_VAR_ssh_allowed_cidrs`; TCP 179 from the node subnet; ICMP destination unreachable with code 4
from anywhere; and all egress. The nftables rules go by port only: the networks are in the security
group and out of the user data, which is kept in state and served by the metadata service. A packet
is admitted only when both the group and the rules admit it.

### First boot, packages and secrets

The configuration is delivered once, as cloud-init user data, which holds no secret: the routing
configuration and the firewall rules name the node subnet and the service range, and nothing names
the operator allowlist, the SSH key or a password. A BGP session password would have to be
generated and kept where both ends can read it. The cluster's side can hold it as a secret
(ADR 0005); an edge could only get it from its user data, which is kept in state and served by the
metadata service, or from a secret store it can reach, which does not exist for it yet. The sessions
carry none (ADR 0013).

The first boot checks the release, installs `frr` and `nftables` with `apt` from the repositories of
the image's release, puts the files under `/etc/edge` in place, checks the rules with
`nft --check`, starts both and checks that FRR answers. The release pins the packages' versions only
as far as the image's repositories do: a rebuild installs whatever the release holds then, so a new
edge may have newer packages than the one it replaces, and nothing pins them further.

Changing anything the user data renders replaces that edge: an edge is rebuilt, not patched. Both
edges render from one template, so a change to it replaces both.

### Rolling out a change

`just infra-apply sto2/edge` refuses a plan that replaces or deletes both edges' instances, saying
so, as both would be down until the new ones answered. `just edge-rollout` rolls such a change out. It plans and
summarises the stack, and once the stack's name is typed back (`--yes`: without asking) it checks
that edge 2 passes `just edge-check`, replaces edge 1 and its floating IP association alone
(`-target`), records the new instance's SSH host keys, and waits until `just edge-check --edge 1`
passes, trying every `EDGE_ROLLOUT_INTERVAL`
seconds, 15 by default, for `EDGE_ROLLOUT_WAIT`, 900 by default. Then it does the same for edge 2
and plans the whole stack once more. An edge whose check does not pass in time stops the rollout
there, and the edge after it is not touched; an edge is never replaced while the other fails its
check.

A replacement has SSH host keys of its own at the floating address the old instance had, and the
connection checks them strictly against the recorded ones. The recorded keys of an edge that is
about to be replaced are therefore dropped, by the rollout and by `just infra-apply sto2/edge` alike
(`ssh-keygen -R` on the edges' `known_hosts` file), and the new ones are recorded the way the first
build's were: their fingerprints are shown and `yes` is typed. The rollout does it once the new
instance answers on SSH, before the edge's check; after `just infra-apply sto2/edge` the next
`just edge-check` does.

### Checking and reading

`just edge-check` is read-only. Over SSH, with the edges' key and host keys recorded as the CI
host's are, it prints pass, FAIL or skip for each edge:

- FRR is running.
- As many sessions are established as the cluster's `talman.yaml` lists workers, and which worker
  has none otherwise. The cluster stack puts the first worker at host number 20 of the node subnet
  and the next ones after it, so a worker is known by its number.
- The table holds only /32s inside the service range, the range from the same file.
- Each route has as many next hops as sessions, or fewer, which is a skip, as a Service that is
  local-only is announced by some workers only.
- The nftables tables are loaded and the kernel forwards.

Without `talman.yaml` the checks that need it are skipped. It prints no address. `just edge-routes`
prints an edge's sessions and routes as FRR shows them, with addresses, for someone learning the
protocol: it refuses unless its standard output is a terminal and `CI` and `GITHUB_ACTIONS` are
unset, so the addresses never reach a CI log.

### SSH and host keys

SSH admits the operator allowlist only, by key only, as the image's default user (`EDGE_SSH_USER`,
`debian` by default). `just edge-ssh-key` creates the key pair at `EDGE_SSH_KEY_FILE`, and the stack
reads the public half from the file beside it. An edge's host key is recorded on first contact, in
`~/.local/state/k8s-gitops/edge.known_hosts`, after the fingerprints it offers are shown and `yes`
is typed, as for the CI host.

Outputs, all sensitive but `names`: `addresses` (the floating addresses), `private_addresses`,
`instances`, `config` (each edge's rendered FRR configuration, nftables rules and kernel settings),
`user_data`, `server_group`, `security_group` and `floating_ips`.

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
and the nodes,
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
- `EDGE_IMAGE`: the edge stack's image name, a Debian 13 cloud image, which reaches tofu as
  `TF_VAR_edge_image_name`; `just os-images debian` lists the names. `EDGE_SSH_KEY_FILE`: the
  absolute path of the edge routers' private SSH key, whose public half beside it, with `.pub` added,
  reaches tofu as `TF_VAR_edge_ssh_public_key`; `just edge-ssh-key` creates both. `EDGE_SSH_USER`:
  the image's default user, `debian` when unset. `TF_VAR_public_allowed_cidrs`: the networks that
  may reach the edges' public ports, a JSON list of IPv4 CIDRs, unset for the operator allowlist.
  `EDGE_ROLLOUT_WAIT` and `EDGE_ROLLOUT_INTERVAL`: how long `just edge-rollout` waits for an edge to
  pass its check, 900 seconds when unset, and how often it tries, 15.
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
