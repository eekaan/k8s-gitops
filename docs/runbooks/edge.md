# The edge routers

The edge routers are two small Linux VMs on the node network, outside the cluster, made by the
`sto2/edge` stack ([infrastructure.md](../infrastructure.md#the-edge-routers)). They run FRR and a
TCP proxy: the workers open BGP sessions to them and announce the address of every labelled
`LoadBalancer` Service as a /32, and each edge's proxy accepts connections to its own public address
on the public ports and opens its own to the public Gateway's address, sending the client's address
in a PROXY protocol header
([ADR 0018](../adr/0018-own-edge-routers-translate-public-traffic-to-the-gateway.md), amended by
ADR 0020). Either can be lost or rebuilt while the other serves.

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
4. Wait for the first boot, a minute or two: it turns unattended upgrades off, installs FRR, HAProxy
   and nftables, checks the three files, gives the SSH daemon its settings, starts nftables, FRR and
   the proxy and turns forwarding on last; a first boot that fails says why on the console and
   leaves forwarding off and FRR and the proxy stopped. `just edge-check` then reads both edges
   over SSH. The first time for each edge it records the edge's host keys itself when every key the
   address offers is one the instance printed on its console
   ([a new host key](#a-new-hosts-ssh-key)); until the cluster's workers peer, the sessions line
   says how many of the workers have none.
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
- **The nftables rules are loaded, and none translates an address**: read from the whole ruleset
  the edge has loaded, every table of it, as `sudo -n nft -j list ruleset` lists it. A FAIL that
  the rules are not loaded means the table `inet edge` is not there, as after a first boot that
  failed. A FAIL that the ruleset on the edge holds what translates an address names what was
  found, in whichever table: a chain hooked at nat, or a `dnat`, `snat`, `masquerade` or `redirect`
  statement. The first boot loads none, so an edge that has one was built from another
  configuration or changed by hand: rebuild it.
- **The forward chain forwards nothing**; **the output chain keeps the proxy's connections to the
  Gateway on a worker's route**, read from the rules as loaded; and **the kernel forwards**, which
  is a FAIL when it forwards without the rules. Without a Gateway address in `talman.yaml` the
  output chain's line is a skip, which says that its guard was not compared with that address and
  what was still checked. While FRR is stopped, the proxy's new connections to the Gateway are
  refused here at once. The refusal does not end one it already holds: the kernel reports it to an
  established socket as a soft error only, so that connection and its client's stall until the
  proxy's 5-minute idle timeout closes them, and a client that opens another connection or retries
  can reach the other edge.
- **The proxy is running**, **runs as its own user, not root**, **its configuration binds the
  stack's public ports, and no other port**, **listens on the addresses and ports its configuration
  binds, and on no others**, and **sends each connection to the cluster's Gateway address, with the
  PROXY protocol version 2 header**: read from `systemctl is-active haproxy`,
  `ps -C haproxy -o user=`, `/etc/haproxy/haproxy.cfg` and `sudo -n ss -H -ltnp`, and the public
  ports from `TF_VAR_public_ports` when it is set, or else the stack's `variables.tf`. A FAIL that
  it is not running means `systemctl status haproxy` and `journalctl -u haproxy` on the edge: a line
  there per connection names the client's address and port and how the connection ended, and a
  connection that found no route to the Gateway ends at once. A listener on every address, an
  unlisted port or a backend that is not the Gateway's is not what the first boot installed, or the
  stack's ports changed and were not rolled out: rebuild the edge. Without a Gateway address in
  `talman.yaml`, the backends' line is a skip that says their address was not compared.
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
  user as the check does (`sudo -n` for `vtysh`, `nft`, `ss` and `sshd`; `nft` and `sshd` are in
  `/usr/sbin`, which that user's `PATH` does not reach), and read why it fails; a stopped FRR is one
  cause for the BGP lines. The ruleset's command is `sudo -n nft -j list ruleset`, and its line is
  a `cannot read` as well when the edge's answer is not nft's JSON listing of schema version 1, the
  one the check reads, as from an nft of another schema version, and when a rule holds a statement
  that nft lists as text, not as JSON, as it lists the inline chain of a `jump { ... }`. The first
  boot loads no inline chain, so an edge that has one was changed by hand: rebuild it.

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

What a rollout asks for is typed, or supplied on its standard input, one line each, in the order it
is asked: the stack's name, the sentence of `--other-down`, and `yes` for each host key the console
does not vouch for, the one a check of the other edge asks about among them. Only the prompts read
that input, so answers written to a pipe before the rollout starts each reach theirs
([Rolling out a change](../infrastructure.md#rolling-out-a-change)).

A replacement has SSH host keys of its own at the same floating address, and the connection holds
to the recorded keys, so the replaced edge's recorded keys are dropped before it is replaced and
the new ones are recorded once its first boot is far enough along for SSH, as
[a new host key](#a-new-hosts-ssh-key) says: from the new instance's console, with no prompt when
it agrees. The new instance has an identifier of its own, which the rollout reads from the stack's
outputs after the edge's apply; outputs that still give the old instance's stop the rollout there,
with nothing read or recorded. When `just infra-plan sto2/edge` lists `update: output instances`
and no other change, `just infra-apply sto2/edge` writes the outputs; a pending change to the other
edge lists `update: output instances` as well. Once it lists no change to `output instances`, so
the outputs name the new instance, `just edge-check --edge N` records its keys. A key the console does not hold, or an answer to the prompt that is not `yes`, stops the
rollout at once, before the edge's check and before the other edge is touched. After
`just infra-apply sto2/edge` has created an edge's instance again, its keys are dropped the same
way, and the next `just edge-check` records the new ones; `just infra-destroy sto2/edge` drops both
edges' keys.

While an edge is replaced the workers' sessions to it are down and come back when it is up. The
other edge carries the traffic, and half of the clients' attempts to the published addresses fail
until the replacement answers, as they do while an edge is lost. A connection through the edge that
is replaced ends when it goes, a long-lived one included, and the client opens another.

### Rolling out the proxy

The edges' proxy sends a PROXY protocol header at the start of every connection it opens to the
Gateway. A Gateway whose listeners do not accept the header cannot read it as TLS or HTTP and closes
the connection, so **every connection through such an edge fails**: no page, no TLS handshake. That
is why the order matters, and why it is this one:

1. **The Gateway accepts the header first.** The change that makes the public Gateway's listeners
   accept a PROXY header, ADR 0020, is merged and live, and the `ClientTrafficPolicy` `public` in
   `envoy-gateway-system` carries the setting and is Accepted
   (`kubectl get clienttrafficpolicy public -n envoy-gateway-system -o yaml` reads it, and changes
   nothing). Its listeners still serve connections that come without a header, so the edges that
   are not replaced yet, which translate and send none, keep working. `just gateway-check` passes.
   `just edge-rollout` does not read the cluster, so nothing refuses a rollout started before this
   is so: it is this step's, not the script's.
2. **Edge 2 serves, confirmed by hand.** `just edge-check` fails an edge that still translates, by
   design: with no proxy, a translation table loaded and rules in the forward chain, edge 2 fails
   it until it is replaced. `just edge-rollout --replace --edge 1` checks the other edge with it
   and so stops at "edge 2 does not pass its check". Run `just gateway-check` and read its lines
   for edge 2: they pass when the edge answers the demo, as the edge still translates. Then run
   `just edge-rollout --replace --edge 1 --other-down` and type back the sentence it asks for, as
   edge 2 cannot be checked. It replaces edge 1, waits for it to pass `just edge-check`, which
   reads the proxy and the rules, and stops there.
3. **`just gateway-check` after it.** It requests the demo through each edge's address, so it fails
   the edge that sends a header the Gateway does not accept. Once it passes,
   `just edge-rollout --replace --edge 2`, which checks the new edge 1 first, and
   `just gateway-check` again.

During a replacement clients see what they see while an edge is lost: half of their attempts to the
published addresses fail until the replacement answers, and a connection through the edge that goes
ends. After it, the Gateway's access logs carry the client's address.

## A new host's SSH key

A new instance has SSH host keys of its own, and the connection that follows holds to what is
recorded, so what is recorded decides who the operator's key-based session talks to. When an edge's
key is not recorded (the first `just edge-check` or `just edge-routes`, a replaced edge in
`just edge-rollout`), the recipe scans the address once for the keys it offers and reads the
instance's console through the OpenStack client, `openstack console log show`, by the instance's
identifier from the stack's outputs. cloud-init's `keys_to_console` module prints the fingerprints
of the host keys on the console at the end of the first boot, between
`BEGIN SSH HOST KEY FINGERPRINTS` and `END SSH HOST KEY FINGERPRINTS`
([the module's documentation](https://cloudinit.readthedocs.io/en/latest/reference/modules.html#keys-to-console)).
It does so with cloud-init's `tools/write-ssh-key-fingerprints`, which sends every line, markers
included, through `logger -s -p user.info`, tagged `cloud-init` (`ec2` up to cloud-init 21.1), so
each line on the console starts with logger's header, such as `<14>Nov  5 09:42:08 cloud-init: `,
the day padded with a space below 10 ([the details](../infrastructure.md#ssh-and-host-keys)). The
recipe reads the last 1000 lines, drops the CR of a line that ends in CR LF, as a serial console
writes it, takes that header, in exactly that form, off each line, and takes the `SHA256:`
fingerprints in the latest complete block between the markers. A line without the header or under
another tag (the journal's copy on the console, `[   74.767670] cloud-init[519]: ...`, among them),
a line anywhere else, or a block cut off by the line limit, does not count, and a console that
holds several boots counts only the latest block, which a reboot does not add to (the module runs
once per instance) and a new instance, with a console of its own, does not inherit. The console is
read through the cloud's API with the credentials the recipes hold, not through the address being
verified. It is the instance's word, and a cloud whose API lies is outside what this defends
against.

It then does one of three things with the keys it scanned, and records those keys, not a second
scan:

- **Every key the address offers is on the console:** the keys are recorded with no prompt, and one
  line says how many and that they match the console.
- **The console holds fingerprints and one the address offers is not among them:** nothing is
  recorded, no prompt is offered, `--yes` and a typed `yes` change nothing, and the recipe exits
  non-zero (the rollout stops there). Check, in order: that the floating address is still
  associated with this instance, in the cloud's own view of the project's floating addresses and
  of the instance's; that something else did not rebuild the instance, which the instance's status
  and last update in the cloud show; and when both are as they should be, treat it as someone else
  answering on that address: do not connect, and report it.
- **The console holds none, or cannot be read** (the client fails, the instance is not found, the
  first boot has not printed its keys yet): the recipe tries again within what is left of the wait
  the rollout has, `EDGE_ROLLOUT_WAIT`, or for `HOST_CONSOLE_WAIT` seconds, 30 by default, outside
  a rollout, then says why and shows the fingerprints the address offers: compare them with the
  console by eye, and type `yes` to record them. Anything else declines, and the rollout stops.

The recipes need `OS_CLOUD` or the `OS_*` credential in `.env`, and the `openstack` client on
`PATH`, 7.0.0 or newer, as `just os-smoke` does; without them the console is not read, the recipe
says why, and the operator is asked at once.

## A dead edge

- **From the cluster's side**: the workers' sessions to it end once the hold time, 9 seconds, has
  passed; Cilium reports them as not established and keeps retrying. The edge advertises nothing,
  so the workers have no route of its to keep or withdraw. Nothing in the cluster changes and no
  Service is affected, as the other edge keeps its sessions.
- **From a client's**: every name a route publishes resolves to both floating IPs for as long as
  one edge is down, so about half of the new connections go to the dead edge's address and time
  out; a client that retries, or tries the name's other address, reaches the other edge. The
  connections that were on the dead edge are lost.

The records are external-dns's ([DNS records](../kubernetes.md#dns-records)): it publishes both
edges' addresses for every route, and its next sync, within a minute, puts back what was removed by
hand: an address deleted from a name is added again, and a name whose records are all deleted is
made again. There is no way in this tree to take one edge's address out of DNS, and resolvers keep
an answer for its TTL, five minutes, in any case; the timeouts end when the edge is back.
Meanwhile `just gateway-check` fails the dead edge's lines, passes the DNS lines, as the records
hold both addresses, and skips `name hello`. An instance that is gone from the cloud is created
again by `just infra-apply sto2/edge`, which creates what is missing and drops its recorded host
keys; a floating IP made again has a new address, which reaches the records only once
`just cluster-config` has written it to the cluster and `gateway-public` has reconciled, which
`flux reconcile kustomization gateway-public` makes it do at once: external-dns reads the addresses
from the Gateway's annotation, which Flux substitutes from `cluster-config` only when
`gateway-public` reconciles ([DNS records](../kubernetes.md#dns-records)). A broken one is replaced
by `just edge-rollout --replace --edge N` ([Replacing one edge](#replacing-one-edge)), which keeps
its floating IP.

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
  label is removed once the node is Ready, uncordoned and its Cilium agent has stayed Ready since
  the reboot for `FORWARD_SETTLE` seconds (30), so the worker announces again only once it forwards
  and no new connection hashed to it fails (the agent's readiness is not proof that the datapath
  forwards to a backend on another node, so that margin is the control, and a worker whose agent
  does not get there within `FORWARD_WAIT` stays out of BGP, said last, with the command that puts
  it back). A kubelet cannot set or remove a label under
  `node-restriction.kubernetes.io/` on its own Node; the node's Cilium agent copies its Node's
  labels to its `CiliumNode`, which the selector is matched against, so a worker whose agent is not
  running keeps its `CiliumBGPNodeConfig` and the wait runs out: `--no-bgp-wait` reboots or
  upgrades it without the wait for the withdrawal, and not without the wait for the agent before the
  worker is put back. No second worker is taken out while one is. `just cluster-reboot`,
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
   paths are gone before the drain starts, no path of it is stale at any point, and its paths are
   back once the recipe ends, and not before its Cilium agent has stayed Ready since the reboot for
   the settle time. The expectation is that no new connection hashed to it fails at any point, a
   connection loop through the edge to a published address included, from before the recipe starts
   until after the worker's paths are back. The control is the recipe's order: withdrawal before the
   drain, and the label removed only once the agent has stayed Ready; a connection that fails after
   the paths are back shows that the settle time, a margin and not a proof, was too short, and
   `FORWARD_SETTLE` is the knob.
4. **A worker, graceful, with no step before it**: stop the worker's instance in the cloud, and
   time the same: its paths stay, stale, for up to the restart time, 120 seconds, and connections
   hashed to it fail meanwhile.

## The way back

- `just cluster-dns-remove` first, while the cluster runs, with `--check` before it: it takes out
  of the zone every A record and TXT entry external-dns made for the routes' names, which point at
  the edges' floating addresses, and leaves external-dns stopped
  ([rebuild.md](rebuild.md#taking-it-down), step 3).
- `just infra-destroy sto2/edge` destroys the stack once its name is typed back. Before it plans,
  it lists the names the tree's routes publish and looks each up at the public resolver, and while
  one resolves to an address of the stack's, or cannot be looked up, it plans and destroys nothing,
  naming each by its label under the domain. The resolver answers from its cache for up to a
  record's TTL, five minutes, so right after the removal the destroy can still refuse: run it again
  once that time has passed. `just infra-destroy sto2/edge --check` says whether it would refuse,
  planning nothing; `--ignore-dns` destroys the stack all the same, naming those names
  ([infrastructure.md](../infrastructure.md#recipes)). The workers' sessions stay down until an
  edge exists again, and no Service is reached from outside.
- The stack does not touch the plumbing or cluster stacks, so destroying it leaves them as they are.
  external-dns stays stopped, and `ExternalDNSSyncStale` fires
  ([alerts.md](alerts.md#externaldnssyncstale)). It is started again, with the two `flux resume`
  commands `just cluster-dns-remove` printed, only once the edges are built again
  (`just infra-apply sto2/edge`), `just cluster-config` has written their addresses to the cluster,
  and `flux reconcile kustomization gateway-public` has applied them to the Gateway and ended
  Ready: external-dns reads the addresses from the Gateway's annotation
  `external-dns.kubernetes.io/target`, which Flux substitutes from `cluster-config` only when
  `gateway-public` reconciles ([DNS records](../kubernetes.md#dns-records)). Before the edge
  stack's destroy, those commands start it again as they are.
