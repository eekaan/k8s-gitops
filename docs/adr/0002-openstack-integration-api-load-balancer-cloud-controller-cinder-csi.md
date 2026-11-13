# 0002 — OpenStack integration: API load balancer, cloud controller, Cinder CSI

- Status: proposed
- Date: 2026-11-14

## Context

Services people rely on need a Kubernetes API endpoint that survives the loss of a control
plane, load balancers for ingress that are not tied to one node, and volumes that are
provisioned on demand. OpenStack offers Octavia and Cinder for these. Neither the Talos nor the
cloud's public documentation covers the OpenStack cloud controller manager or Cinder CSI on
Talos, so both are verified on a running cluster before anything is built on them.

## Decision

- The Kubernetes API is served through an Octavia TCP load balancer created by OpenTofu. The
  cluster endpoint is the load balancer's fixed private address, known at plan time; its
  floating IP and the control planes' floating IPs are certificate SANs. Inside the cluster,
  KubePrism balances API traffic on every node.
- The OpenStack cloud controller manager provides `Service` objects of type `LoadBalancer`
  through Octavia. The kubelets run in external cloud-provider mode from bootstrap.
- Cinder CSI provides volumes. The default StorageClass uses the cloud's default volume type.

## Alternatives considered

- **No load balancer, no cloud controller, no CSI.** The endpoint is one control plane's
  private address with KubePrism, ingress goes through a node holding a floating IP, and Ceph
  runs in the cluster on attached volumes. Fewer moving parts, but ingress depends on a single
  node and storage is replicated twice. This is the fallback, component by component, if a
  verification fails.
- **Talos layer-2 virtual IP.** Needs allowed-address-pairs on every control-plane port and is
  not live until etcd is.

## Consequences

- The cloud-provider mode is fixed at bootstrap; changing it later means registering every
  node again. The decision is confirmed by rebuilding the cluster in the chosen mode.
- The cloud controller and the CSI driver need an OpenStack credential inside the cluster. It
  is separate from the one OpenTofu uses and is delivered as SOPS-encrypted bootstrap material.
- Load balancers and volumes created by the cluster are not in tofu state, so teardown removes
  them before the stacks are destroyed.
- This record becomes accepted, or is replaced, when both verifications have run.
