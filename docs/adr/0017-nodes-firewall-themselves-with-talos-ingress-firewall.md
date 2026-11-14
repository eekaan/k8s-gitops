# 0017 — Nodes firewall themselves with Talos' ingress firewall

- Status: accepted
- Date: 2026-11-14

## Context

What may reach a node is decided by the cloud's security group in front of its port: everything
between the nodes, and from outside them only the Talos and Kubernetes APIs, from the operator
allowlist. That protection belongs to one cloud's network service. On other infrastructure it is
gone, and nothing on a node refuses a packet the security group lets through.

Every node runs listeners that something else must reach, each from a few sources only: Talos' API
and trust daemon, etcd, the Kubernetes API, the kubelet, the control plane's metrics, Cilium's
overlay, health and Hubble ports, node-exporter. A security group sees pod traffic between nodes
only as the overlay's packets from a node's address, so it cannot tell a pod that reaches a port on
a node from the node itself.

## Decision

Every node drops inbound traffic by default and admits each listener from its sources only, with
Talos' ingress firewall: a `NetworkDefaultActionConfig` that blocks and a `NetworkRuleConfig` per
listener, in the node's machine configuration. The listeners are written down once, in
`talos/firewall.yaml`, with the nodes that have them and the sources they accept; the cluster stack
renders the sources into networks from the inputs the security group takes, the allowlist, the node
subnet, the pod range and the nodes' addresses, and talman writes the rules into each node's
configuration. Control planes and workers get the rules of their own listeners.

The base layer is Talos' rather than Cilium's. Talos applies it with the machine configuration,
before Kubernetes and the CNI run, so it holds while a node joins, while Cilium starts or restarts,
and when Cilium is broken or gone. A mistake in it is undone by Talos itself: a change of the
firewall is rolled out node by node in Talos' try mode, which reverts a node by itself unless the
change is applied again, and is applied again only once the node's Talos API, every node's Talos API
port and the cluster check from the operator's machine (`just cluster-talos --first <node>`).

The cloud's security groups remain, as an outer ring for what a node cannot do itself:

- a node in maintenance mode has no machine configuration and so no firewall, and its Talos API takes
  a configuration from anyone who reaches it, so that port stays limited to the allowlist;
- Cilium serves NodePorts, host ports and Services' load balancer and external addresses from its
  eBPF datapath, before the packet reaches the netfilter hooks Talos' firewall runs on, so the
  NodePort range stays closed to everything outside the nodes.

The cluster stack's `security_group_rules` selects today's full rules or a reduced set that keeps
them and opens every other port. With the reduced set, nothing but these two depends on the
security groups.

## Alternatives considered

- **The cloud's security groups alone.** In place and nothing to roll out, but the protection is
  the cloud's and stays behind on other infrastructure, and it cannot tell pods from nodes.
- **Cilium host policies.** Rules by identity, pods, nodes and entities, rather than by address, and
  they also see what Cilium serves before netfilter: NodePorts, host ports and Services' addresses.
  But they exist only while Cilium runs, not before the CNI, while it restarts or when it is broken,
  and a wrong policy is undone through the Kubernetes API it may have cut off. They can be added
  later on top of this layer, for rules by pod and for the ports Talos' firewall does not see.

## Consequences

- The rules live in the machine configuration and move with it: the same `talos/firewall.yaml`
  protects the nodes on any infrastructure, and a node carries them from its first configuration.
- A new listener on a node, or one that moves, needs its line in `talos/firewall.yaml`, or the
  firewall drops what reaches it. `tests/node-firewall.bats` keeps the file, the documentation's
  table and every node's rendered rules in step.
- The firewall sees packets addressed to the node only: not traffic to pods and Services, and not
  what Cilium serves before netfilter. Network policies, the outer ring and, later, Cilium host
  policies cover those. Talos always admits loopback, replies to the node's own connections, ICMP at
  a limited rate and traffic between the pod and service ranges.
- The allowlist reaches the nodes through the generated `talman.yaml`. A change of it takes
  `just infra-apply sto2/cluster` and then `just cluster-talos`, run from an address the nodes admit
  before the change, so a network leaves the allowlist only after the one that replaces it has
  reached the nodes.
