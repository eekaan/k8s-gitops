# The edge routers

The edge routers are two small Linux VMs on the node network, outside the cluster, made by the
`sto2/edge` stack ([infrastructure.md](../infrastructure.md#the-edge-routers)). They run FRR: the
workers open BGP sessions to them and announce the address of every labelled `LoadBalancer` Service
as a /32, and each edge forwards traffic that arrives at its own public address to the public
Gateway's address and back
([ADR 0018](../adr/0018-own-edge-routers-translate-public-traffic-to-the-gateway.md)). Either can be
lost or rebuilt while the other serves.

## First build

In this order, after the plumbing stack is applied ([rebuild.md](rebuild.md)):

1. `just os-images debian` lists the names of the cloud's public Debian images. Choose the Debian 13
   (trixie) cloud image, and put its name in `.env` as `EDGE_IMAGE`; any other release makes the
   first boot fail loudly.
2. Put an absolute path outside the repository in `.env` as `EDGE_SSH_KEY_FILE`, and run
   `just edge-ssh-key`, which creates the key pair there unless one is.
3. `just infra-apply sto2/edge` plans the stack and shows a summary: two instances, two ports, two
   floating IPs, a server group, a security group with its rules, a key pair and a rule per public
   port and network. Type the stack's name to apply it. The public ports admit the operator
   allowlist only, until `TF_VAR_public_allowed_cidrs` says otherwise.
4. Wait for the first boot, a minute or two: it turns unattended upgrades off, installs FRR and
   nftables, checks both files, gives the SSH daemon its settings, starts FRR and nftables and turns
   forwarding on last; a first boot that fails says why on the console and leaves forwarding off and
   FRR stopped. `just edge-check` then reads both edges over SSH, showing the host key's
   fingerprints the first time for each edge and asking for `yes`; compare them with the ones the
   instances printed on their console. Until the cluster's workers peer, the sessions line says how
   many of the workers have none.
5. Compare the hosts the two instances run on: the server group's policy keeps them apart only
   where the cloud can.

## Checking the sessions and reading the table

`just edge-check` prints pass, FAIL or skip per line, for each edge, and never an address:

- **FRR is running**: a FAIL means `systemctl status frr` on the edge, and its log in the journal.
- **N of M worker sessions are established**: M is the number of workers in the cluster's
  `talman.yaml`. A FAIL names the workers that have no session. A worker opens its sessions itself,
  retrying every few seconds, so a session that does not come is a worker whose Cilium agent is not
  running, a worker outside the block the edges take sessions from, a security group that blocks
  TCP 179 to the edge, or an edge that is not listening. Every worker of `talman.yaml` counts, so a
  worker that is down fails this line on both edges, and with it every rollout, until it is back or
  the cluster stack no longer has it.
- **The table holds only /32s inside the service range**: a FAIL means a route no Service owns is
  in the table; the inbound policy is meant to make that impossible, so read the edge's
  `frr.conf` and the table.
- **Next hops**: a skip says some routes have fewer next hops than there are sessions. A Service of
  `externalTrafficPolicy: Local` is announced only by the workers with an endpoint, which is the
  usual reason.
- **The service range is unreachable on the edge but through a worker's route**: FRR is configured
  with its reject route for the range, for the range `talman.yaml` names, and the kernel has it. A
  FAIL that no reject route is configured means FRR runs without the edge's configuration, as after
  a first boot that failed: rebuild the edge.
- **The nftables rules are loaded**; **the forward chain sends a translated connection, new or
  established, toward the Gateway only through a worker**, read from the rules as loaded; and **the
  kernel forwards**, which is a FAIL when it forwards without the rules. While FRR is stopped, a new
  connection through this edge is refused and an established one's packets are dropped here, so
  its clients' connections end, and a client that retries can reach the other edge.
- **Unattended upgrades are off**: the first boot turns them off, as they would upgrade FRR in
  place.
- **The SSH daemon runs with the settings the first boot wrote**: `sudo -n sshd -T -C user=...` on
  the edge, the settings as the edge's user's connection gets them, `Match` blocks for that user
  applied, reports the key exchange, ciphers, MACs, authentication and forwarding settings of
  `infra/openstack/stacks/sto2/edge/sshd.conf`, each with the same value. A FAIL names the settings
  that differ and never their values: read them on the edge with
  `sudo sshd -T -C user=debian,host=operator.example.org,addr=198.51.100.1` (with the user
  `EDGE_SSH_USER` names), and look for a `Match` block in the files of `/etc/ssh/sshd_config.d`
  beside the drop-in `00-edge.conf` and in `/etc/ssh/sshd_config`. What a `Match` on the
  operator's own address or host name changes is not read by the check. An edge is rebuilt, not
  patched, so the way out is `just edge-rollout --replace --edge N`.
- **cannot read X on the edge**: a line that says the edge did not answer for one state, as its
  command was not found or failed, with what the edge said, any address left out. It is a FAIL of
  its own and says nothing about the state itself: run the command on the edge, as its ordinary
  user as the check does (`sudo -n` for `vtysh`, `nft` and `sshd`; `nft` and `sshd` are in
  `/usr/sbin`, which that user's `PATH` does not reach), and read why it fails; a stopped FRR is one
  cause for the BGP lines.

To learn what the edge sees, `just edge-routes` (or `just edge-routes 2`) prints the sessions and
the table, with addresses, in a terminal only: it refuses in CI and when its output is piped. In the
table, a route has one path per announcing worker, each with that worker's address as next hop; the
paths marked as multipath are the equal-cost ones the kernel spreads connections over. In the
sessions, a `*` before an address marks a dynamic neighbour; the column `State/PfxRcd` holds, once a
session is established, the number of prefixes the edge accepted from that worker, and `PfxSnt` the
number it sent, which is 0.

## Replacing one edge

An edge is rebuilt, not patched.

- **A change to its configuration** (the templates, the files beside them, or the workers' timers in
  the manifests): `just infra-plan sto2/edge` shows both instances replaced, as a changed user data
  makes a new instance, and `just edge-rollout` rolls it out. It checks that the other edge serves,
  replaces the first, records the new instance's SSH host keys, waits for
  `just edge-check --edge 1` to pass, and only then does the second. It stops at the first edge that
  does not pass its check, and leaves the edge after it as it was. Each new instance boots the
  newest image `EDGE_IMAGE` names, too.
- **A new image alone** (another `EDGE_IMAGE`, or a newer image under the same name, for the
  release's updates): `just infra-plan sto2/edge` shows no change to the instances, as their boot
  devices are left as they were created. `just edge-rollout --replace` replaces each edge's
  instance anyway, one at a time, with the same checks: the instance and its boot volume are made
  again from the image, and the port, with the edge's address and floating IP, stays.
- **A new SSH key** at `EDGE_SSH_KEY_FILE`: the plan replaces the key pair and no instance, as a key
  reaches an instance only when it is created, so the running edges keep admitting the old key
  alone, and every check, which logs in with the new one, fails on them. Make sure edge 2 serves by
  reaching the published address through it, then run
  `just edge-rollout --replace --edge 1 --other-down`, typing back the sentence, as edge 2 cannot
  be checked; then `just edge-rollout --replace --edge 2`, which checks the new edge 1 first.
- **One edge alone**, broken or on purpose: `just edge-rollout --replace --edge N` replaces edge N,
  after checking that the other serves. When the other edge does not pass its check either, it
  stops; `--other-down` goes on once `replace edge N with edge M down` is typed back, `--yes` or
  not, as nothing serves until the replaced edge passes its check.
- **A plan of the stack's own**: `just infra-apply sto2/edge` refuses a plan that replaces or
  deletes both edges, and one that replaces or deletes one edge while the other does not pass its
  check, naming the rollout instead.

The rollout plans and applies each edge's own resources alone, so a change it does not touch, such
as a rule of the security group, is left; the last plan it prints says what is left, and
`just infra-apply sto2/edge` applies it.

A replacement has SSH host keys of its own at the same floating address, and the connection holds
to the recorded keys, so the replaced edge's recorded keys are dropped before it is replaced and
the new ones are recorded once its first boot is far enough along for SSH. `just edge-rollout` shows
the new keys' fingerprints and asks for `yes`; compare them with the ones the instance printed on
its console, as at the first build. Any other answer stops the rollout at once, before the edge's
check and before the other edge is touched. After `just infra-apply sto2/edge` has created an
edge's instance again, its keys are dropped the same way, and the next `just edge-check` shows and
records the new ones; `just infra-destroy sto2/edge` drops both edges' keys.

While an edge is replaced the workers' sessions to it are down and come back when it is up. The
other edge carries the traffic, and half of the clients' attempts to the published addresses fail
until the replacement answers, as they do while an edge is lost.

## A dead edge

- **From the cluster's side**: the workers' sessions to it end once the hold time, 9 seconds, has
  passed; Cilium reports them as not established and keeps retrying. The edge advertises nothing,
  so the workers have no route of its to keep or withdraw. Nothing in the cluster changes and no
  Service is affected, as the other edge keeps its sessions.
- **From a client's**: a hostname that publishes both floating IPs answers half of the connections
  with a timeout while one edge is down, until its address is taken out of DNS; a client that
  retries reaches the other. The connections that were on the dead edge are lost.

Take a dead edge's address out of DNS while it is down, and put it back when `just edge-check`
passes. An instance that is gone from the cloud is created again by `just infra-apply sto2/edge`,
which creates what is missing and drops its recorded host keys. A broken one is replaced by
`just edge-rollout --replace --edge N` ([Replacing one edge](#replacing-one-edge)).

## A worker that goes

How long the edges keep a worker's /32 paths depends on how its sessions end
([infrastructure.md](../infrastructure.md#routing)). New connections hashed to the worker fail while
they stay; the next ones are spread over the others.

- **A dead or partitioned worker** (powered off, hung, cut off): its sessions end when their hold
  time, 9 seconds, passes, and its paths go then. The edge does not negotiate graceful restart's
  notification bit, so an expired hold timer does not start a graceful restart.
- **A hung Cilium agent** whose datapath still forwards: the same 9 seconds, as no keepalive comes;
  its paths go though the node could still serve, and the other workers take its share.
- **A Cilium agent that restarts**: Cilium closes its sessions without a NOTIFICATION, and the edge
  keeps the worker's paths, as stale, until the agent is back and has sent them again (End-of-RIB),
  or for the restart time, 120 seconds, at most.
- **A worker shut down or rebooted gracefully, with no step before it** (a stop in the cloud, a
  reboot from the node): its agent stops the same way, so its paths stay, stale, for up to the
  restart time, 120 seconds, and a shut-down worker's for all of it; the restart time in the
  workers' `CiliumBGPPeerConfig` bounds it.
- **A worker taken out before a planned reboot**: withdrawn at once. `just cluster-reboot`,
  `just cluster-talos --reboot` and `just cluster-upgrade` label the worker
  `node-restriction.kubernetes.io/bgp-out`, which the `CiliumBGPClusterConfig`'s node selector
  excludes, wait until its `CiliumBGPNodeConfig` is gone, after which the Cilium agent closes the
  node's sessions with a notification and the edges withdraw its paths
  ([how, in Cilium's source](../infrastructure.md#the-edge-routers)), and only then drain it; the
  label is removed once the node is Ready. A kubelet cannot set or remove a label under
  `node-restriction.kubernetes.io/` on its own Node; the node's Cilium agent copies its Node's
  labels to its `CiliumNode`, which the selector is matched against, so a worker whose agent is not
  running keeps its `CiliumBGPNodeConfig` and the wait runs out: `--no-bgp-wait` reboots or
  upgrades it without the wait. No second worker is taken out while one is. `just cluster-reboot`,
  `just cluster-talos --reboot` and `just cluster-upgrade` that stop with a worker out say so last
  and print the command that puts it back,
  `kubectl label node <node> node-restriction.kubernetes.io/bgp-out-`, and `just cluster-check`
  fails while a Ready worker is out.

### Failover tests

At the live build, and after a change to the routing policy, with a labelled `LoadBalancer` Service
reached through both edges:

1. **An edge**: stop one edge's instance in the cloud. The other keeps serving, half of the
   attempts to the published addresses time out, and `just edge-check` fails for the stopped edge
   only. Start it again and `just edge-check` passes.
2. **A worker, hard**: pause one worker's instance in the cloud, and time how long its /32 paths
   stay in `just edge-routes`: about the hold time, 9 seconds. Unpause it.
3. **A worker, planned**: run `just edge-routes` on an edge, then `just cluster-reboot <worker>`
   and run it again while the worker drains and reboots, and once it is back. The worker's /32
   paths are gone before the drain starts, no path of it is stale at any point, no new connection
   hashed to it fails, and its paths are back once the recipe ends.
4. **A worker, graceful, with no step before it**: stop the worker's instance in the cloud, and
   time the same: its paths stay, stale, for up to the restart time, 120 seconds, and connections
   hashed to it fail meanwhile.

## The way back

- `just infra-destroy sto2/edge` destroys the stack once its name is typed back. The workers'
  sessions stay down until an edge exists again, and no Service is reached from outside.
- The stack does not touch the plumbing or cluster stacks, so destroying it leaves them as they are.
