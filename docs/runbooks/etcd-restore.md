# Restoring etcd from a snapshot

etcd holds every object of the Kubernetes API: every Deployment, every Secret, Flux's own objects.
`just cluster-snapshot` takes a snapshot of it with `talman etcd snapshot`, encrypts it with age to
the Talos age key's recipient on the machine it runs on, and uploads only the encrypted file to the
etcd backup bucket, as `<cluster>/<UTC time>.snapshot.age` ([cluster.md](../cluster.md#recipes)).
`just cluster-restore` puts one back.

A snapshot holds every Secret in the cluster, and every S3 key of the project reaches the bucket
([ADR 0008](../adr/0008-state-and-backups-are-encrypted-before-they-leave.md)), so it is readable
only with the Talos age key, the key the secrets bundle is encrypted to
([cluster.md](../cluster.md#the-talos-age-key)). Losing that key loses every snapshot, as it loses
the bundle.

## When to restore

A restore replaces the cluster's state with the snapshot's. It is the tool when that state is lost
or wrong and nothing less brings it back: every control plane has lost etcd, or etcd has lost
quorum and no control plane can be brought back into it, or objects were deleted or damaged that
Git and Flux do not hold, such as Secrets made in the cluster. When etcd still has quorum, or gets
it back once a control plane is back, that is better: a restore loses everything written after the
snapshot.

It restores into the same nodes with the same secrets bundle only: the machines the cluster's
`talman.yaml` lists, at the addresses it gives them, each still holding its machine configuration,
and the cluster's `secrets.sops.yaml` as it was when the snapshot was taken. A cluster rebuilt on
new machines, or with a new secrets bundle, is a different procedure and is not covered here.

A restore does not roll back the contents of volumes: a PersistentVolume's data is on the workers'
data volumes, in LINSTOR's storage pool, not in etcd. LINSTOR's own records are in etcd, though:
the controller keeps its database in the Kubernetes API, as Kubernetes objects
([Piraeus operator, components](https://github.com/piraeusdatastore/piraeus-operator/blob/v2.12.1/docs/explanation/components.md),
v2.12.1, which `kubernetes/apps/base/piraeus-datastore/piraeus-operator` pins; the `LinstorCluster`
here sets no other database). A restore to an older snapshot rolls those records back together with
the PersistentVolumes and PersistentVolumeClaims, while the data and the DRBD metadata on the
workers stay as they are now. So:

- A volume created since the snapshot has no record in LINSTOR and no PersistentVolume or claim
  after the restore, and its data stays on the workers: an orphan.
- A volume deleted since the snapshot is back as a LINSTOR record, a PersistentVolume and a claim
  that point at data the workers no longer hold.

Do not restore while volumes created or deleted since the snapshot matter more than what the
restore brings back: when etcd can be repaired instead, when a control plane that still holds etcd
can be brought back, or when the snapshot is older than the last volume change that has to be kept.
Before a restore that goes ahead anyway, take a copy of the data of the volumes created since the
snapshot with their own backups, as they are not in it.

## Steps

1. **`just cluster-snapshots [cluster]`** lists the cluster's snapshots in the etcd bucket, newest
   first, each by its name and size. The name is the UTC time the snapshot was taken. While the
   cluster still answers, `just cluster-snapshot [cluster]` first keeps the state that is about to
   be replaced.

2. **`just cluster-restore <name> [cluster]`**, or `just cluster-restore latest [cluster]` for the
   newest. Before it changes anything it checks what it needs, finds the snapshot, downloads it into
   a private temporary directory and decrypts it there with the Talos age key, and waits until every
   node answers on the Talos API port. A name that is not in the bucket, a file that is not an age
   file, or one the key cannot decrypt stops it there. It then says what happens and asks for the
   cluster's name to be typed back; `--yes` does not ask. What it says includes how many
   PersistentVolumes of LINSTOR's driver the cluster has now, by number and not by name, or that its
   API does not answer and they cannot be counted, and what a restore does to volumes
   ([When to restore](#when-to-restore)); typing the name confirms that too. Then, in order, as Talos' disaster
   recovery
   ([Talos 1.14](https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery))
   and talman's `--recover-from` have it:
   1. `talman reset --group controlplane --graceful=false --wipe-labels=EPHEMERAL --reboot=true --yes` wipes the
      EPHEMERAL partition of each control plane, the nodes whose role is `controlplane`, one at a
      time, and reboots it. The reboot is asked for, not left to the flag's default: a reset that
      shut the nodes down would leave etcd wiped with nothing running to restore it into, and the
      wait for the nodes to answer would fail. EPHEMERAL holds etcd's data. No member leaves etcd first, as every
      member goes. STATE, with the node's machine configuration, stays: each control plane comes
      back as itself and waits for etcd to be bootstrapped. The workers are not reset. While etcd
      is down, the pods already scheduled on them might continue to run, but no new pods can be
      scheduled
      ([Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#restoring-an-etcd-cluster)).
   2. Once every node answers again, `talman apply --bootstrap --recover-from` bootstraps etcd on
      the first control plane from the snapshot. The other control planes join it.
   3. The kubeconfig is fetched, as `just cluster-kubeconfig` does, and the recipe waits until every
      node in `talman.yaml`, workers included, reports Ready after the reset. The restored etcd
      holds each node's Ready condition as it was at the snapshot, so a report from before does
      not count. A kubelet reports a node's status when it changes, and otherwise every five
      minutes by default
      ([Kubernetes](https://kubernetes.io/docs/reference/node/node-status/#heartbeats)), which
      the wait allows for.

   The decrypted snapshot is removed once etcd is restored, and whenever the recipe exits.

   What `just cluster-bootstrap` applies before Flux starts, Cilium, the objects of
   `just cluster-config` and the kubelet serving-certificate approver, is not applied again: they
   are objects of the Kubernetes API, which the restored etcd holds as they were at the snapshot,
   together with Flux, which reconciles everything else from its artifact.

## What is lost

- Everything written to the Kubernetes API after the snapshot was taken: objects made since are
  gone, objects deleted since are back, and every other object, Secrets included, is as it was.
- On every control plane, what EPHEMERAL held: container images, logs, `emptyDir` volumes and the
  kubelet's local state; its pods start again. The workers keep theirs.
- The cloud's load balancers are not in the snapshot. One the cluster made after the snapshot for a
  Service of type LoadBalancer has no Service in the restored cluster and stays in the cloud until
  it is removed by hand; for one it removed after the snapshot, the restored Service names
  something that is gone.
- LINSTOR's records of volumes made or deleted since the snapshot, with their PersistentVolumes and
  claims ([When to restore](#when-to-restore)); the volumes' data is not lost, and what the restore
  leaves behind is cleaned up as [Volumes since the snapshot](#volumes-since-the-snapshot) says.

## Afterwards

- Every node is Ready: the recipe ends there.
- Flux's Kustomizations and HelmReleases become Ready, reconciled from the artifact built from
  `main`; what changed in Git after the snapshot comes back through them.
- The ConfigMap `cluster-config` and the Secrets `cluster-secrets` and `sops-age` are as they were
  at the snapshot. If any of them changed since, `just cluster-config` applies them again.
- Workloads with volumes have their PersistentVolumeClaims bound, the workers hold no volume
  LINSTOR no longer knows, and the cloud holds no load balancer the cluster no longer knows.
- `just cluster-snapshot` takes a snapshot of the restored cluster.

## Volumes since the snapshot

The count the recipe printed before the question is the cluster's volumes as they were just before
the restore; compare the restored cluster's with it. The objects involved are the
PersistentVolumes and PersistentVolumeClaims of the cluster, LINSTOR's `ResourceDefinition`s, which
the LINSTOR controller in the namespace `piraeus-datastore` lists, and, on each worker, the DRBD
resources its satellite runs and the logical volumes of the thin pool `data` in the volume group
`linstor_data` ([kubernetes.md](../kubernetes.md#storage)), one per replica, named after the volume.
They are read with the tools in the pods of the controller and the satellites: `linstor
resource-definition list`, `drbdsetup status`, `lvs`.

- **Orphans, from volumes created since the snapshot.** A logical volume or a DRBD resource on a
  worker that no `ResourceDefinition` and no PersistentVolume names. No pod can use it, as no claim
  names it. If its data is wanted, copy it off the worker before anything is removed; otherwise
  stop the DRBD resource on each worker that has it and remove its logical volume there, replica
  by replica.
- **Volumes deleted since the snapshot.** A PersistentVolume, a PersistentVolumeClaim and a
  `ResourceDefinition` whose logical volumes no worker holds. A pod that uses the claim does not
  start. Delete the claim, the PersistentVolume and the `ResourceDefinition`, and let the
  workload's own manifest, or its backup, make a new volume.
- Volumes that existed at the snapshot and still do are as they were; nothing is done for them.

No recipe does this: each step removes data, and the operator looks at each object first.

## If it stops

The failure line names the step. Up to the question, nothing has changed. After the reset and
before etcd is restored, the cluster runs no etcd: `just cluster-restore` with the same snapshot
resets the control planes again and restores from the start. Once etcd is restored, while the kubeconfig is
fetched or the nodes are waited for, the restore is done and is not run again: `just
cluster-kubeconfig` fetches the kubeconfig, and the nodes that are not Ready are looked at.
