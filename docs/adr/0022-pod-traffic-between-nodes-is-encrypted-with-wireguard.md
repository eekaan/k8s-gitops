# 0022 — Pod traffic between nodes is encrypted with WireGuard

- Status: accepted
- Date: 2026-11-19

## Context

Cilium carries pod traffic between nodes in its overlay: tunnel mode, VXLAN over the node network,
with Cilium in place of kube-proxy and the BGP control plane on the workers. VXLAN carries a packet
from one node to another, network policy
([ADR 0019](0019-namespaces-deny-traffic-by-default-and-each-declares-its-flows.md)) decides which
connections pass, and the node firewall
([ADR 0017](0017-nodes-firewall-themselves-with-talos-ingress-firewall.md)) what reaches a node's
own listeners. Encryption is a layer of its own.

Cilium 1.20.4 encrypts transparently, by one of three types: IPsec, WireGuard or ztunnel. With
WireGuard each agent makes its own key pair, publishes the public key on its node's `CiliumNode`
and keeps a WireGuard device in the kernel with a peer for every other node; in tunnel mode every
packet of the overlay passes through that device. The pinned Talos kernel has WireGuard built in,
and the nodes' security group admits everything between the nodes.

## Decision

- **WireGuard, by values in Git.** The Cilium values set `encryption.enabled: true` and
  `encryption.type: wireguard`, the type stated, as the chart's default is `ipsec`. Its keys are
  per node and made by the agents themselves, so nothing is seeded, stored or rotated by hand.
- **Node-to-node encryption off** (`encryption.nodeEncryption: false`). It is beta at this version;
  the control planes opt out of it by default, so their own traffic would stay outside it either
  way; it gives every node's address a tunnel endpoint, so a pod's connection to a node would
  reach the node from the pod's address through the overlay instead of from its node's, which the
  node firewall's sources (`members`, `pods`) and the rollout's checks are built on; and turned on
  in the same roll as WireGuard it would cut traffic between the nodes' own addresses, the storage
  layer's replication among it, between nodes whose agents have restarted and those that have not.
  The storage layer's replication, LINSTOR's connections to its satellites and the scrapes of the
  nodes' addresses stay with the node network and the node firewall.
- **Strict mode off** (`encryption.strictMode`). Egress strict mode needs the pod range as a value
  and, in tunnel mode, remote node identities allowed; ingress strict mode would drop the
  unencrypted pod traffic of a node whose agent has not restarted yet, in every roll of the agents.
- **One listener more on every node.** The node firewall admits UDP 51871, the WireGuard port,
  from the nodes' own addresses alone. The rule reaches every node before the values turn
  WireGuard on, so that no node's firewall drops what its peers' devices send it.
- **`just cluster-check` is the watch.** It asks every agent, through `kubectl exec`, whether it
  encrypts with WireGuard and has a peer for every other node, while `cilium-config` turns
  WireGuard on. Cilium exposes no WireGuard metric at this version, so no alert watches it.
- **The agents' update strategy stays the chart's**, two at a time.

## Consequences

- Every packet the overlay carries between two nodes passes through WireGuard. Cilium's table
  gives as encrypted, with these values, every connection between pods on different nodes,
  directly or through a `ClusterIP` Service, and the hop on which a worker forwards a connection
  from outside the cluster to a pod on another node; that a connection between pods through a
  Service of another type is encrypted rests on Cilium's source at this version, which translates
  the Service's address at the pod's interface. Packets between pods on one node, traffic from and
  to the nodes' own addresses, a node's or a host-network pod's connection to a pod on another node
  and a pod's to another node among it, and the request between a client outside the cluster and
  the worker it reaches, which the Gateway's TLS covers for HTTPS, are not among what the table
  gives as encrypted ([Encryption between nodes](../kubernetes.md#encryption-between-nodes)).
- The change, and its revert, roll the agents two at a time, and while some agents encrypt and
  others do not, pod traffic between the two groups of nodes, and each node's own connections to
  pods in the other group, both ways, stop until the last agent has restarted, as a node's packets
  to a pod on another node and the pod's replies cross the overlay; traffic between the addresses
  the nodes are registered with goes on. The drops are in the kernel's device, which no agent
  reports, so `just network-drops` and the record of what policy drops do not show them.
- The pods' default route loses WireGuard's 95 bytes of MTU besides VXLAN's 50, which the agents
  derive and write into every running pod's namespace; nothing in the tree sets an MTU. A pod
  under `gvisor` takes its route MTU when its sandbox starts, and one under `kata` the MTU of its
  interface.
- The private key lives in the agent's state directory on the node, which Talos keeps in memory:
  a reboot, an upgrade or a reset gives the node a new key, which the other agents take from its
  `CiliumNode`.
- The way back is a change that sets the values back, with the scenario, test and docs that follow
  them, and leaves `talos/firewall.yaml` and `node-firewall-exceptions.yaml` as they are: the
  firewall rule stays, nothing listens on its port, and the rule goes only by a change that takes it
  out. A revert of the whole change takes the rule out of the tree too, while the nodes keep it
  until `just infra-apply sto2/cluster` and `just cluster-talos` roll out a configuration without
  it.

## Alternatives considered

- **IPsec.** Supported in the same modes, but its key is a pre-shared one that the tree would keep
  as a Secret, seed before Cilium starts and rotate by hand.
- **ztunnel**, the chart's third type: workload mutual TLS through a proxy on each node, with a
  certificate authority and the enrolment of namespaces. A mesh, not transparent encryption of
  what crosses the node network.
- **Node-to-node encryption now.** The reasons it stays off are above; it is a later change, onto
  agents that already have their peers, with its own change of the firewall's sources.
- **Cilium's mutual authentication.** A beta feature that authenticates both ends of a connection
  by their identities before policy allows it, and leaves encryption to WireGuard or IPsec: it adds
  identity to policy, not encryption.
- **Leaving it to the applications.** Each would carry TLS of its own; what does not, and every
  application ported from a catalogue, would cross the node network as it is.
