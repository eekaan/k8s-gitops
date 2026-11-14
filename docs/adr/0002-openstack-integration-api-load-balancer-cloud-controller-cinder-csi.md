# 0002 — OpenStack integration: API load balancer, cloud controller, Cinder CSI

- Status: proposed
- Date: 2026-11-14
- Amended: 2026-11-14, volumes come from LINSTOR, not Cinder CSI
  ([ADR 0011](0011-persistent-volumes-from-linstor-on-a-data-volume-per-worker.md))
- Amended: 2026-11-14, Services of type `LoadBalancer` are announced over BGP to edge routers the
  deployment runs, not provided by the cloud controller
  ([ADR 0013](0013-service-addresses-announced-over-bgp-to-edge-routers.md))

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
- This record chose the OpenStack cloud controller manager for `Service` objects of type
  `LoadBalancer`, through Octavia. ADR 0013 replaces that part of it: their addresses come from a
  pool in Cilium and are announced over BGP to edge routers the deployment runs, and the cluster
  runs no cloud controller.
- This record chose Cinder CSI for volumes. ADR 0011 replaces that part of it: volumes come from
  LINSTOR on a volume attached to each worker, and the cluster runs no Cinder CSI.

## Alternatives considered

- **No load balancer, no cloud controller, no CSI.** The endpoint is one control plane's
  private address with KubePrism, ingress goes through a node holding a floating IP, and Ceph
  runs in the cluster on attached volumes. Fewer moving parts, but ingress depends on a single
  node and storage is replicated twice. This is the fallback, component by component, if a
  verification fails.
- **Talos layer-2 virtual IP.** Needs allowed-address-pairs on every control-plane port and is
  not live until etcd is.

## Consequences

- The cluster runs without a cloud controller, so its kubelets are not in external cloud-provider
  mode, nodes report no floating address, and no OpenStack credential is inside the cluster.
- The Kubernetes API's load balancer is what remains of this record, and the only use of the
  cloud's load balancer service; ADR 0013 notes that it may follow the Services onto the edge
  routers.
