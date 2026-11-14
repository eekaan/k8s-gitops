# 0013 — Service addresses announced over BGP to edge routers the deployment runs

- Status: accepted
- Date: 2026-11-14

## Context

Services of type `LoadBalancer` need addresses that clients outside the cluster reach. ADR 0002
planned them from the cloud's load balancer service, through the OpenStack cloud controller. That
puts a cloud credential inside the cluster, creates load balancers outside tofu state that every
teardown has to find first, and makes how the cluster publishes a Service depend on one cloud's
services. The cluster's side of publishing a Service should be the same on any infrastructure,
with or without a cloud load balancer.

## Decision

- **Addresses.** `LoadBalancer` Services take their addresses from the service range, a small
  private range outside the node subnet that overlaps no pod, service or node range (the plumbing
  stack's `service_range`, `10.20.0.0/28` by default). Cilium's LoadBalancer IP management assigns
  them from one pool holding exactly that range, to Services labelled `k8s-gitops/announce: bgp`
  only.
- **Announcement.** Cilium's BGP control plane runs on every worker, and on no control plane. Each
  worker peers over eBGP, as the cluster's AS, with two edge routers at fixed addresses on the node
  subnet, in the edge routers' AS, and advertises the address of each labelled Service as a /32:
  nothing else, no pod range and no cluster IP. The AS numbers are private 16-bit ones (RFC 6996),
  64513 for the cluster and 64512 for the edge routers by default; the edge routers sit at host
  numbers 6 and 7 of the node subnet. All four numbers live in the plumbing stack, which outlives a
  rebuild of the cluster.
- **Edge routers.** Two general-purpose Linux VMs on the node subnet, running FRR, which the
  deployment runs itself: they hold the deployment's public addresses, learn the service addresses
  from the workers, and forward public traffic to them over equal-cost paths through the workers
  that announce them. They stand in for a site's routers; elsewhere real routers take their place
  and nothing in the cluster changes. They are built by their own change.
- **No routing protocol toward the cloud's router.** A Neutron router takes routes only as static
  extra routes its owner sets through the API, and speaks no routing protocol with the instances
  behind it, so the workers peer with the deployment's own edge routers instead.
- **The node network.** Each worker's port lists the service range among its allowed address
  pairs, as port security lets a port send from, and with some backends receive for, only its own
  address and those pairs; control planes' ports do not. The workers have a security group of
  their own that admits the service ports from the two edge addresses and nothing else. The workers
  open the BGP sessions themselves, so no rule admits TCP 179.
- **No session password.** The sessions carry no TCP MD5 password. Both ends sit on the project's
  own node network, where port security keeps an instance from sending from another's address, and
  only the project can attach an instance to it; a password would have to be generated, kept in
  the cluster and on both edge routers, and rotated, and a compromised worker that can read it
  could open a session anyway. A password becomes worth its cost when a session crosses a network
  the deployment does not own, when a peer is a router someone else runs, or once a secret store
  (ADR 0005) can deliver it to both ends.
- **Not used for Services:** the cloud's load balancer service and the cloud controller. The
  Kubernetes API's load balancer (ADR 0002) is unchanged; it is the remaining use of the cloud's
  load balancer service and may follow the Services onto the edge routers later.

## Alternatives considered

- **The cloud's load balancer through the cloud controller (ADR 0002).** No routers of our own to
  run, but a cloud credential in the cluster, load balancers outside tofu state, and a cluster whose
  way of publishing a Service works on this cloud's services only.
- **Layer 2 announcements of virtual addresses.** Cilium answers ARP for each address from one
  node, and a floating IP maps to an unattached port that holds the address. No routers of our own
  either, but every address is carried by one node at a time, failover takes a lease expiry plus a
  gratuitous ARP that the cloud's network must honour, which only a live test could show, and it
  still rests on this cloud's floating IPs and ports.
- **A static extra route on the cloud's router to one worker.** No protocol at all, but no
  failover: the route names one next hop, and nothing withdraws it when that worker goes away.

## Consequences

- Two more VMs to run, patch and watch. Until they exist, the workers' sessions stay down, nothing
  is announced, and a labelled Service has an address nothing outside the cluster reaches.
- The edge routers translate between the public addresses and the service range. A worker sends
  its reply to the address a packet came from, through its default route, the cloud's router,
  unless that address is on the node subnet; so unless an edge router also translates the client's
  address to its own, replies leave by another path than the one the connection came in on.
  Translating keeps the path symmetric, and a Service then sees an edge router's address, not the
  client's. How the edge routers translate, and whether they pass the client's address on another
  way, is decided with them.
- Traffic to an address spreads over the workers that announce it, along equal-cost paths. With
  `externalTrafficPolicy: Cluster` every selected worker announces every address and forwards to
  any endpoint; with `Local` only workers with a ready endpoint announce it.
- A worker that fails stops receiving traffic once its sessions' hold time expires, or, as graceful
  restart is on, once the restart time also has, unless the edge router learns of the failure
  sooner.
- Nothing in the cluster is specific to this cloud: the service range, the AS numbers and the edge
  addresses are numbers in the plumbing stack, and the allowed address pairs and the workers'
  security group are what this cloud's network needs to carry them.
- No Service gets a cloud load balancer, so `just cluster-destroy` does not wait for a Service
  whose addresses all come from the service range.
