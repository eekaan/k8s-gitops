# 0011 — Persistent volumes from LINSTOR on a data volume per worker

- Status: accepted
- Date: 2026-11-14

## Context

Applications need persistent volumes that are provisioned on demand, survive the loss of a node,
and can also be placed on one node without replication where an application replicates its own
data. ADR 0002 chose the cloud's block-storage CSI driver, Cinder CSI, for volumes. It needs an
OpenStack credential inside the cluster, and every volume it provisions is a cloud volume outside
tofu state that has to be removed before the stacks are destroyed.

## Decision

Persistent volumes come from LINSTOR, run by the Piraeus operator, which replicates them between
workers with DRBD. LINSTOR keeps its storage on one block-storage volume attached to each worker:
the cluster stack creates and attaches the volumes, and Talos hands each to the storage layer
under one device name, the same on every worker. Control planes get none.

The cloud's block-storage CSI driver is not used. The OpenStack cloud controller remains planned,
for `Service` objects of type `LoadBalancer` only (ADR 0002).

## Alternatives considered

- **Cinder CSI.** Each volume is a cloud volume, replicated once by the cloud's storage, but the
  cluster needs a cloud credential, the volumes live outside tofu state, and node-local volumes
  need a second system.
- **TopoLVM for node-local volumes beside a replicated system.** LINSTOR also places volumes on
  one node without replication, so one system serves both needs.
- **Instance flavors with local disks.** No volume to attach, but the data lives and dies with
  the instance; an attached volume survives its instance.

## Consequences

- Replicated data is stored twice over: replicated by the cloud's storage under each volume, and
  again by DRBD between workers.
- The data volumes belong to the cluster stack. Destroying the stack deletes them and everything
  on them; backups (ADR 0008) are what keeps data.
- No volume the cluster provisions is a cloud volume, so the cluster needs no cloud credential
  for storage.
- DRBD is a kernel module, which Talos loads from a system extension in the node image, so the
  image gains that extension before LINSTOR runs.
