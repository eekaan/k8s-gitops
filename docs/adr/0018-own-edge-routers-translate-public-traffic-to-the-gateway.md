# 0018 — Edge routers the deployment runs, translating public traffic to the Gateway

- Status: accepted
- Date: 2026-11-14

## Context

ADR 0013 has the workers announce every `LoadBalancer` Service's address over BGP to two edge
routers on the node subnet and leaves open what those routers are and how public traffic gets
through them to a Service. The owner wants the path from the internet to a Service to be routers the
deployment runs itself, speaking a standard protocol, so that the cluster does not depend on one
cloud's load balancer service, the same design runs on other infrastructure, and BGP is learned on
something real.

This record is the change ADR 0013's decision on the edge routers leaves to "their own change", and
it refines that record in three places, which stand as written otherwise:

- ADR 0013's consequence that "how the edge routers translate, and whether they pass the client's
  address on another way, is decided with them": they translate the source, and do not pass the
  client's address on (the data path, below).
- Its consequence that a failed worker stops receiving traffic "once its sessions' hold time
  expires, or, as graceful restart is on, once the restart time also has": the edges do not
  negotiate the notification bit, so a worker that dies or is cut off goes at its hold time, and the
  restart time applies to a worker whose agent stops or restarts, which closes its sessions without
  a NOTIFICATION (the routing, below).
- Its edge routers "on the node subnet" that the workers peer with: the edges take sessions from the
  workers' addresses only, not from the rest of the node subnet.

## Decision

- **Two small Linux VMs running FRR**, the `edge` stack (`infra/openstack/stacks/sto2/edge`), at the
  two addresses the plumbing stack reserves (`edge_hosts`), each with a floating IP of its own, in a
  server group of soft anti-affinity policy. The stack reads the plumbing stack's state and nothing
  of the cluster stack's, so the cluster can be destroyed and rebuilt around the edges, as the CI
  host's can. They boot a Debian 13 (trixie) cloud image, whose FRR is 10.3.
- **Routing.** Plain eBGP in the edge AS. The workers open the sessions and never listen, so an edge
  takes dynamic neighbours from the workers' addresses only, the block of host numbers the cluster
  stack numbers its workers from, in one peer group whose remote AS is the cluster's: the node
  subnet also holds the control planes, the CI host and the other edge, none of which may announce a
  Service. The edge's firewall and its security group admit BGP from that block alone. It accepts a
  prefix only if it is a /32 inside the service range, denies everything else, sets the maximum of
  accepted prefixes to the size of the range (a guard only a loosened prefix list can reach, as FRR
  counts accepted prefixes and the list lets in no more than the range holds), takes the worker that
  announced a path as its next hop, and advertises nothing. The timers and the graceful restart time
  are read from the workers' `CiliumBGPPeerConfig` in the manifests, so the two ends cannot
  disagree. Graceful restart runs without the notification bit of RFC 8538, which FRR sets by
  default, so a dead worker's paths go when its hold timer expires rather than a restart time later.
  Equal-cost multipath covers as many paths as there can be workers, and the kernel hashes a flow's
  layer 4 fields, so a connection stays on one path.
- **The data path.** nftables on each edge translates a connection to the edge's own address on a
  public port to the public Gateway's address, a host of the service range that the plumbing stack
  picks and `cluster-config` carries as `GATEWAY_ADDRESS`, and translates its source to the edge's
  own address. Forwarding is allowed between those only; everything else addressed to an edge is
  dropped but SSH, BGP from the workers' addresses and the ICMP path MTU discovery needs. **The
  source translation is deliberate.** A worker sends its reply to the address a packet came from,
  through its default route, which is the cloud's router, unless that address is on the node subnet;
  without the translation the reply would leave by another path than the connection came in on and
  would never meet it.
- **No allowed address pairs.** With the translation an edge sends only from its own address and
  receives only for it, so its port keeps port security on with no allowed address pair, which is
  what the Neutron API reference describes: the pairs define the addresses a port may send from when
  port security is on. Without it an edge would send from every client's address and receive the
  answers for them; no list of pairs covers that short of an address pair for every address, which
  the reference warns bypasses the source restrictions of any rule that names a remote group, or of
  port security off on the port. Where the edges are real routers on other infrastructure, none of
  this applies.
- **Public addresses.** One floating IP per edge. A public hostname publishes both, from a later
  change. A shared virtual address that VRRP moves between the edges is not used: it needs the cloud
  to carry the gratuitous ARP that moves an address pair, a behaviour this cloud's network is not
  shown to have and another cloud's may not, which this design avoids by relying on floating IPs
  alone.
- **Who may reach the public ports.** The edge's security group admits them from the networks of a
  variable that defaults to the operator allowlist, so nothing is open to the world until the
  variable is deliberately widened; SSH is admitted from the allowlist only. The nftables rules go
  by port only: the networks stay out of the user data, which is kept in state and served by the
  metadata service.
- **Configuration at first boot, an edge rebuilt and never patched.** Cloud-init writes the FRR
  configuration, the nftables rules and the kernel settings, and installs FRR and nftables from the
  distribution's repositories, once. Changing the rendered configuration replaces the instance. Both
  edges render from one template, so a change replaces both, which `just infra-apply` refuses and
  `just edge-rollout` does one edge at a time, checking each before the next. A new image replaces
  nothing by itself, as the `vm` module the edges share with the Talos nodes leaves an instance's
  boot device as it was created; `just edge-rollout --replace` replaces each edge's instance, and
  with it the boot volume made from the image, one edge at a time with the same checks, and keeps
  its port, so its address and floating IP stay. The user data holds no secret; the sessions carry
  no password (ADR 0013).
- **Not built:** a session between the two edges, which would add each edge's learned routes to the
  other and so a path through the other edge when a worker's session is down, at the cost of loops
  to avoid and a second policy to test; a proxy on the edges that keeps the client's address; and
  any return path that avoids the source translation.

## Alternatives considered

- **The cloud's load balancer through the cloud controller (ADR 0002).** No routers to run, but a
  cloud credential in the cluster, load balancers outside tofu state, and a cluster that publishes a
  Service in one cloud's way only.
- **A shared virtual address moved by VRRP.** One address in DNS and no half-failed answers, but it
  needs the cloud to pass the gratuitous ARP of an address pair, a cloud-specific behaviour.
- **A proxy on the edges instead of translation.** A layer 4 proxy that speaks the PROXY protocol to
  the Gateway restores the client's address, at the cost of a daemon in the path, connections ended
  at the edge, nothing for UDP, and a Gateway listener that expects the protocol.
- **Announcing from the edges to an upstream router.** The cloud offers tenants no routing protocol
  toward its router (ADR 0013), so there is nothing to announce to.

## Consequences

- **Pods see an edge's address, not the client's.** Restoring the client's address later takes one
  of two things: a layer 4 proxy on each edge speaking the PROXY protocol to the Gateway, which
  costs a daemon, a protocol the Gateway must accept and no UDP; or replies routed back through the
  edges, which costs source routing on the workers, each reply meeting the edge that holds the
  connection, and an edge sending from addresses of the service range and of clients, which takes
  the port security off. Neither is built.
- **Two DNS answers.** A hostname publishes both floating IPs. While one edge is down, half of the
  clients' attempts reach nothing until its address is removed from DNS. Health-checked DNS removes
  it, or the shared virtual address removes the half, each a later change.
- **An edge is rebuilt, not patched.** Every change to its configuration, and every package update
  that is to reach it, is a replacement, done one edge at a time. A changed configuration replaces
  the edges by itself; a new image, or the release's updates alone, reach them only through
  `just edge-rollout --replace`. The release's packages are not pinned beyond the release: a rebuild
  installs what the distribution's repositories hold for it then.
- **A flow moves when an edge, a worker or a route goes.** Kernel multipath is not resilient: when
  the set of next hops changes, flows are hashed again, and a connection whose path changes is
  reset. Graceful restart keeps a restarting worker's routes meanwhile.
- **The cloud is still relied on for** the floating IPs, which carry the public addresses to the
  edges, and the router, which carries the traffic between the external network and the node subnet,
  and for nothing that is BGP.
- **Two more VMs to run and patch.** They are rebuilt with `just edge-rollout --replace` for a new
  image, and `just edge-check` reads their state.
