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
   port and network. Type the stack's name to apply it. The public ports admit the operator allowlist
   only, until `TF_VAR_public_allowed_cidrs` says otherwise.
4. Wait for the first boot, a minute or two: it installs FRR and nftables. `just edge-check` then
   reads both edges over SSH, showing the host key's fingerprints the first time for each edge and
   asking for `yes`; compare them with the ones the instances printed on their console. Until the
   cluster's workers peer, the sessions line says how many of the workers have none.
5. Compare the hosts the two instances run on: the server group's policy keeps them apart only
   where the cloud can.

## Checking the sessions and reading the table

`just edge-check` prints pass, FAIL or skip per line, for each edge, and never an address:

- **FRR is running**: a FAIL means `systemctl status frr` on the edge, and its log in the journal.
- **N of M worker sessions are established**: M is the number of workers in the cluster's
  `talman.yaml`. A FAIL names the workers that have no session. A worker opens its sessions itself,
  retrying every few seconds, so a session that does not come is a worker whose Cilium agent is not
  running, a security group that blocks TCP 179 to the edge, or an edge that is not listening.
- **The table holds only /32s inside the service range**: a FAIL means a route no Service owns is
  in the table; the inbound policy is meant to make that impossible, so read the edge's
  `frr.conf` and the table.
- **Next hops**: a skip says some routes have fewer next hops than there are sessions. A Service of
  `externalTrafficPolicy: Local` is announced only by the workers with an endpoint, which is the
  usual reason.

To learn what the edge sees, `just edge-routes` (or `just edge-routes 2`) prints the sessions and the
table, with addresses, in a terminal only: it refuses in CI and when its output is piped. In the
table, a route has one path per announcing worker, each with that worker's address as next hop; the
paths marked as multipath are the equal-cost ones the kernel spreads connections over. In the
sessions, a `*` before an address marks a dynamic neighbour, and the last column is the number of
prefixes it sent.

## Replacing one edge

An edge is rebuilt, not patched. For a new image or a change to its configuration:

1. `just infra-plan sto2/edge` shows what changes. A change to the template or the image replaces
   both instances.
2. `just edge-rollout` rolls it out: it checks that the other edge serves, replaces the first,
   records the new instance's SSH host keys, waits for `just edge-check --edge 1` to pass, and only
   then does the second. It stops at the first edge that does not pass its check, and leaves the
   edge after it as it was.
3. To replace one edge alone, `just infra-apply sto2/edge` applies a plan that replaces one. It
   refuses a plan that replaces both, or deletes both.

A replacement has SSH host keys of its own at the same floating address, and the connection holds
to the recorded keys, so the replaced edge's recorded keys are dropped before it is replaced and
the new ones are recorded once its first boot is far enough along for SSH. `just edge-rollout` shows
the new keys' fingerprints and asks for `yes`; compare them with the ones the instance printed on
its console, as at the first build. After `just infra-apply sto2/edge` has replaced one edge, the
next `just edge-check` shows and records them. An edge whose keys are not recorded cannot pass its
check, so a rollout that is not answered stops there.

While an edge is replaced the workers' sessions to it are down and come back when it is up. The
other edge carries the traffic, and half of the clients' attempts to the published addresses fail
until the replacement answers, as they do while an edge is lost.

## A dead edge

- **From the cluster's side**: the workers' sessions to it go down once the hold time, 9 seconds,
  has passed, and then, as graceful restart is on, once the restart time, 120 seconds, has too;
  Cilium reports the sessions as not established and keeps retrying. Nothing in the cluster changes
  and no Service is affected, as the other edge keeps its sessions.
- **From a client's**: a hostname that publishes both floating IPs answers half of the connections
  with a timeout while one edge is down, until its address is taken out of DNS; a client that
  retries reaches the other. The connections that were on the dead edge are lost.
- A worker that dies is withdrawn from the table of both edges when its sessions' hold time has
  passed, and connections hashed to it are reset; the next ones are spread over the others.

Take a dead edge's address out of DNS while it is down, and put it back when `just edge-check` passes.
An instance that is gone from the cloud is created again by `just infra-apply sto2/edge`, which
creates what is missing. The recipes have no step that replaces an instance whose configuration did
not change: one that is broken is deleted in the cloud first, and then applied the same way.

## The way back

- `just infra-destroy sto2/edge` destroys the stack once its name is typed back. The workers' sessions
  stay down until an edge exists again, and no Service is reached from outside.
- The stack does not touch the plumbing or cluster stacks, so destroying it leaves them as they are.
