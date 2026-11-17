# 0017 — Nodes firewall themselves with Talos' ingress firewall

- Status: accepted
- Date: 2026-11-14
- Amended: 2026-11-17, the pods that declare a host port are Cilium's agent and its Envoy, on
  every node, control planes included, and its operator, not node-exporter, which declares none;
  all of them are on the host network, where Cilium maps no host port and the port is the node's
  own, which the firewall filters, and what Cilium serves before the firewall is the host port of
  a pod on the pod network, so the reduced set suits a cluster where no pod on the pod network
  declares one, which Pod Security allows in `security-system` as well as in the three namespaces
  named here; the Cilium agents' metrics are a listener of every node as well; and a new listener
  is also its port in the documentation's account of what a rollout proves and its place in
  `tests/node-listeners.bats`, which holds every port that a pod of the render of `kubernetes/`
  declares on the host network to a rule or a listed reason, every rule to a listener and the
  render's pods on the pod network to no host port, and does not read a pod that an operator
  creates at run time, such as LINSTOR's CSI node plugin on the host network
  ([The node firewall](../cluster.md#the-node-firewall))

## Context

What may reach a node is decided by the cloud's security group in front of its port: everything
between the nodes, and from outside them only the Talos and Kubernetes APIs, from the operator
allowlist. That protection belongs to one cloud's network service. On other infrastructure it is
gone, and nothing on a node refuses a packet the security group lets through.

Every node runs listeners that something else must reach, each from a few sources only: Talos' API
and trust daemon, etcd, the Kubernetes API, the kubelet, the control plane's metrics, Cilium's
overlay, health and Hubble ports, node-exporter. With this cluster's Cilium, in tunnel routing
without the host firewall, a pod's connection to another node's address does not go through the
overlay: Cilium masquerades it to its own node's address as it leaves the node. A node therefore
sees a pod on another node as that node, and only a pod on itself by the pod's own address.

## Decision

Every node drops inbound traffic by default and admits each listener from its sources only, with
Talos' ingress firewall: a `NetworkDefaultActionConfig` that blocks and a `NetworkRuleConfig` per
listener, in the node's machine configuration. The listeners are written down once, in
`talos/firewall.yaml`, with the nodes that have them and the sources they accept; the cluster stack
renders the sources into networks from the inputs the security group takes, the allowlist, the pod
range, the nodes' floating addresses and each node's own address, the API load balancer's address
and pool and the CI host's address, and talman writes the rules into each node's configuration.
Control planes and workers get the rules of their own listeners. A port that pods reach admits the
nodes' own addresses and the pod range; the overlay and Cilium's health checks admit the nodes' own
addresses only. No rule admits the node network as a whole: it also holds the edge routers the
workers announce Services to ([ADR 0013](0013-service-addresses-announced-over-bgp-to-edge-routers.md)),
which face the internet, so an edge router's address reaches no listener on a node.

The base layer is Talos' rather than Cilium's. Talos applies it with the machine configuration,
before Kubernetes and the CNI run, so it holds while a node joins, while Cilium starts or restarts,
and when Cilium is broken or gone. A mistake in it is undone by Talos itself: a change of the
firewall is rolled out node by node in Talos' try mode, which reverts a node by itself unless the
change is applied again, and it is applied again only once checks from the operator's machine have
passed within the try window: the node's Talos API, the paths into the node from the other nodes,
its readiness, for a control plane its own Kubernetes API and the load balancer's connections to it,
and the cluster (`just cluster-talos --first <node>`). A connection open before the try outlives
it, so what those checks cannot open afresh is proved after the rollout, by restarting its clients.

What reaches a node without passing the firewall, and what controls each:

- A node in maintenance mode has no machine configuration and so no firewall, and its Talos API takes
  a configuration from anyone who reaches it: the cloud's security group admits that port only from
  the allowlist, the nodes' floating addresses and the CI host.
- Cilium serves NodePorts from its eBPF datapath, before the packet reaches the netfilter hooks
  Talos' firewall runs on: the security group keeps the NodePort range closed to everything outside
  the nodes.
- Cilium serves pods' host ports the same way: Pod Security refuses them at the baseline level,
  which Talos enforces wherever a namespace sets no other.
- Cilium serves Services' external addresses the same way, and any Service could name one: every
  control plane's API server enables the `DenyServiceExternalIPs` admission plugin, which refuses a
  new one. It reads `spec.externalIPs` alone and passes subresources, so the load-balancer addresses
  Cilium writes into a Service's status, and Services labelled for BGP, are not affected.
- Cilium serves Services' load-balancer addresses the same way: it assigns them from the service
  range, and the workers announce them to the edge routers. They are reachable only through the
  edge routers, and the workers' own security group admits traffic to the service ports, and
  nothing else, from the two edge addresses only.
- Traffic to a pod's address goes to the pod, not the node: no route from outside the node network
  leads to the pod range, and network policies govern it between pods.

The cloud's security groups remain as the outer ring for the first, second and fifth, which a node
cannot cover itself: the nodes' group for the Talos API and the NodePort range, the workers' group
for the service ports. The cluster stack's `security_group_rules` selects the full rules or a
reduced set that keeps them and gives the control planes a group of their own that opens every other
port. The workers get nothing more with either: a security group rule never matches a packet's
destination, so a rule open to all on a worker's port, which carries the service range, would open
every port of a load-balancer address too. On a control plane, where the reduced set opens the ports
Cilium serves before the firewall, four things keep anything from being served there: control
planes announce nothing and their ports carry no allowed address pair for the service range, which
the cluster's configuration and its tests hold; a Service's external address is refused when new,
and one a Service already holds is kept, so the reduced set suits a cluster where no Service holds
one, as none of the repository's does; and no pod on a control plane declares a host port, as Pod
Security refuses one outside `kube-system`, `monitoring` and `piraeus-datastore`, where the one pod
that declares one, node-exporter, runs on the host network, whose port the firewall filters. With
the reduced set, nothing but those four depends on the security groups.

## Alternatives considered

- **The cloud's security groups alone.** In place and nothing to roll out, but the protection is
  the cloud's and stays behind on other infrastructure.
- **Cilium host policies.** Rules by identity, pods, nodes and entities, rather than by address, and
  they also see what Cilium serves before netfilter: NodePorts, host ports and Services' addresses.
  But they exist only while Cilium runs, not before the CNI, while it restarts or when it is broken,
  and a wrong policy is undone through the Kubernetes API it may have cut off. They can be added
  later on top of this layer, for rules by pod and for the ports Talos' firewall does not see.

## Consequences

- The rules live in the machine configuration and move with it: the same `talos/firewall.yaml`
  protects the nodes on any infrastructure, and a node carries them from its first configuration.
- A new listener on a node, or one that moves, is one entry in `talos/firewall.yaml` and one row in
  the documentation's table, or the firewall drops what reaches it. `tests/node-firewall.bats` keeps
  the file, the table and every node's rendered rules in step.
- The firewall sees packets addressed to the node only: not traffic to pods, and not what Cilium
  serves before netfilter, which the controls above cover. Talos always admits loopback, replies to
  the node's own connections, ICMP at a limited rate and traffic between the pod and service ranges.
  A connection open before a rule changes stays open, so a rule that is wrong for long-lived
  connections, such as etcd's between its members, shows when they are opened again.
- A kept rule that turns out wrong is fixed in `talos/firewall.yaml`, rendered into `talman.yaml`
  by `just infra-apply sto2/cluster` and rolled out with `just cluster-talos --first <node>`.
- The allowlist reaches the nodes through the generated `talman.yaml`, and the nodes admit their
  APIs only from the allowlist they hold. A change of it is rolled out from an address the nodes
  admit before the change, so a network leaves the allowlist only after the one that replaces it has
  reached the nodes. With the old address gone, the way back runs through the cluster: once the
  load balancer's listener admits the new network, the Kubernetes API answers through the load
  balancer, which every control plane admits by its own addresses as long as it proxies, and a pod
  on a node's host network applies each node's configuration through its Talos API from that node's
  own address. The talosconfig and the configurations it takes hold the cluster's keys, so they are
  a Secret only cluster administrators reach, there only for the recovery. The CI host's address,
  when the nodes' configuration admits it, is a second way.
