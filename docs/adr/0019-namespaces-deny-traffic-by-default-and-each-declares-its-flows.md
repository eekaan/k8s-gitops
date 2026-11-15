# 0019 — Namespaces deny traffic by default, and each declares the flows it lets through

- Status: accepted
- Date: 2026-11-15

## Context

Pod Security limits what a pod may be. Nothing limited what it may reach: every pod could open a
connection to every other pod and to the internet. An application ported from a catalogue brings
code the operator did not write, and the public Gateway brings traffic from outside to its
backends, so a compromise of one workload must not be a path to the secret store, the storage
controller or the nodes' APIs.

Cilium, the cluster's CNI, enforces two policy APIs: Kubernetes' `NetworkPolicy`, which selects
pods and names peers by pod and namespace selectors and address blocks, and its own
`CiliumNetworkPolicy`, which also names entities (`world`, `host`, `remote-node`, `kube-apiserver`,
`cluster`), DNS names and a namespace's labels. In its default enforcement mode a pod is open in a
direction until a policy rule that selects it for that direction asks for the default deny, and
then only what some rule allows passes, separately for ingress and egress. A `NetworkPolicy` always
asks for it; a `CiliumNetworkPolicy` does for each direction it has rules for, unless its
`enableDefaultDeny` says `false` for the direction, and one rule that asks is enough.

## Decision

- **Both APIs, by role.** The namespace-wide default deny is a Kubernetes `NetworkPolicy`: an empty
  pod selector, `Ingress` and `Egress` in its policy types and no rule. It is portable and says the
  same on any CNI that enforces it. Every allow is a `CiliumNetworkPolicy`, because the flows that
  matter here name the API server, the nodes' kubelets, other nodes' hosts and "the world" without
  an address, which only entities express, and select backends by the labels of their namespaces.
  An address never appears in either: the check refuses one.
- **The default deny is that one object.** It is named `default-deny`. Every allow sets
  `enableDefaultDeny: {ingress: false, egress: false}`, and the check refuses an allow that does
  not, any other `NetworkPolicy` in a namespace with the posture, and a deny rule anywhere. Taking
  a namespace's default deny out therefore opens the namespace, its allows changing nothing, which
  makes that one object the way back for a namespace.
- **One default deny per namespace, owned by the namespace.** It lives in the namespace's directory
  beside `namespace.yaml`, and the overlay that selects the namespace selects it. A cluster-wide
  policy with an opt-out label would be one object to keep right, but a mistake in it, or its
  absence, would change every namespace at once and silently, and a namespace's posture would not be
  visible where its applications are. A per-namespace object that goes missing leaves that
  namespace open, which the check refuses.
- **Cilium's `policyEnforcementMode` stays `default`.** Mode `always` would deny what no policy
  allows in every namespace, including the system namespaces whose flows are not yet enumerated.
- **A namespace that does not hold the default deny is listed**, in
  `network-policy-exceptions.yaml`, with the reason and what covers it instead. A namespace is in
  the file or holds the default deny, and an entry that no longer matches fails the check, so the
  list cannot outlive the reason.
- **An application's flows live beside the application**, in its own directory, so the overlay
  that enables an application enables its policies. A rule that undoes the default for a peer
  (every endpoint, the cluster, every pod of every namespace, the world other than into a Gateway's
  proxies on its listener ports, other nodes' hosts, an empty selector, a rule of ports alone) is
  the one rule of a policy of its own, which carries its reason in an annotation the check requires.
- **The public Gateway's backends are selected by the label that already lets their namespace
  attach routes.** The proxies' egress reaches each routed backend's pods, in a namespace that
  carries `k8s-gitops/gateway: public`, on the container port its route sends to and no other, so
  a namespace that is listed is not open to them on its other pods and ports, and a backend allows
  ingress from the proxies by their labels, not by their namespace, so the Gateway's controller is
  not a path to it.
- **The policies land on a cluster that audits.** The Cilium chart's `policyAuditMode` puts every
  agent in audit mode: each policy is evaluated, the flows it would drop are reported, and nothing
  a policy denies at layers 3 and 4 is dropped, which is all these policies decide (audit mode does
  not reach a layer-7 rule). The value is in Git, in a change of its own that lands, and rolls
  every agent, before the policies; Flux owns it, `rollOutCiliumPods` restarts the agents into
  each change of it, and the install script reads the same values. The policies then merge, are
  watched, and a change of their own takes the value out to enforce; setting it again is the way
  back for the whole cluster.

## Consequences

- The system namespaces keep their present openness until their flows are enumerated, and the
  list says which and why. The host-network pods (Cilium's agent, its Envoy and its operator, the
  storage's CSI node plugin, the node exporter) are never selected by a pod policy, and the node
  firewall (ADR 0017) is their layer.
- Audit mode is the agents', so while it is on no policy of the cluster drops anything at layers
  3 and 4, the policies Flux installs for itself included, which the agents enforced before; the
  watch is bounded by the pull request that enforces.
- The order is what keeps the public path up while the policies land. The root Kustomization
  applies a namespace's default deny at once, while the namespace's allows wait for the Cilium
  release to be Ready: on a cluster whose agents enforce, the namespace would deny without its
  allows until they land, for the whole rollout when the same change also changes the Cilium
  release, and for as long as a failed release holds them back. On a cluster whose agents already
  audit, nothing the policies deny is dropped in that time, so the audit value lands, and every
  agent restarts into it, before the policies do.
- The proxies take the world alone on the listener ports: the pinned datapath gives a load-balanced
  connection from outside the world's identity, also when a worker forwards it to another node.
  The audit watch confirms it on the live cluster.
- An application that needs a flow adds one policy beside itself; one that needs none is reached
  by nothing and reaches nothing.
- Layer 7 rules, mutual authentication and encryption stay out: this is connection-level policy.
