# 0021 — A namespace label names its sandbox tier, and Kyverno alone refuses pods without it

- Status: accepted
- Date: 2026-11-19

## Context

The node image carries gVisor and Kata Containers, the cluster has a RuntimeClass for each, and the
nodes let pods create user namespaces. Each isolates a pod more than a plain container: in a user
namespace of its own, its users mapped to unprivileged ones of the node; on gVisor's kernel in user
space, which answers its system calls; or in a virtual machine with a kernel of its own. Nothing made
a workload use any of them. A namespace that ought to run sandboxed had no way
to say so, and a pod that forgot `runtimeClassName` ran on the host's kernel without anyone
noticing.

The namespace is already where the tree states what its pods may be: its Pod Security level is a
label on its `namespace.yaml`, which `just pod-security-check` holds every pod template of the render
to before a change is merged. Two admission engines run side by side, Kyverno and Gatekeeper, each
holding the same three rules in audit, and Kyverno's webhooks that match workloads fail open and
skip the namespaces that keep the cluster reconciled.

## Decision

- **A label names the tier.** `k8s-gitops/sandbox` on a namespace's `namespace.yaml`, beside its Pod
  Security label, is part of the namespace's contract. Its three values are exact, and none ranks
  above another: `userns` asks every pod to set `hostUsers: false`, `gvisor` asks for
  `runtimeClassName: gvisor`, and `kata` for `runtimeClassName: kata`. A pod of another tier's
  isolation does not meet its namespace's, and any other value, in any case or empty, is no tier,
  and no pod meets it.
- **The tree refuses first.** `scripts/pod-security-check`, run by `just pod-security-check`, is the
  offline twin: it refuses a value that is no tier, a pod template of the render in a labelled
  namespace without its tier's field, and the resources of `components/volsync` and
  `components/cnpg-cluster` in such a namespace, by their API groups, `volsync.backube` and
  `postgresql.cnpg.io`.
- **Kyverno alone refuses at admission.** One `ValidatingPolicy`, `sandbox-tier`, in
  `kyverno-policies` beside the three, in `Deny`, with the failure policy `Ignore`, so it refuses
  while its webhook answers. It matches pods alone, created in a namespace where the label exists.
  Gatekeeper holds no twin: one engine refuses a rule, so a pod is refused once, with one message.
- **No exception.** Kyverno's `PolicyException` stays off, and the Pod Security exceptions file
  lists levels, not tiers. A pod that cannot meet its namespace's tier belongs in a namespace without
  one.
- **VolSync and CloudNativePG stay out of sandboxed namespaces.** Their operators make pods from
  resources whose definitions declare neither `runtimeClassName` nor `hostUsers`, so the namespace's
  application cannot give those pods its tier.

## Consequences

- The refusal holds only while Kyverno's webhook answers. While no Kyverno pod answers, or an
  evaluation fails, a pod is admitted without its tier, and the offline check is what holds the
  tree's own pods to it.
- The namespaces Kyverno never sees at admission, those its webhooks skip and those its resource
  filters drop, cannot be sandboxed; the test of the rule fails when one carries the label.
- The rule judges a pod's creation alone, as the two fields cannot change on a pod: a pod that
  predates its namespace's label keeps running and is reported by the background scan, not refused.
- Falco watches the host's kernel, so it sees little of what a pod does inside gVisor or a Kata
  guest. A `gvisor` or `kata` namespace trades that visibility for the kernel boundary.
- An operator other than VolSync or CloudNativePG that makes pods in a sandboxed namespace must give
  them the tier itself; the offline check cannot see those pods, and Kyverno refuses them at
  admission.
- The rule enters in `Deny` while no namespace carries the label, so it changes nothing that runs
  until an application's namespace asks for a tier.
