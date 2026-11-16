# Rebuilding the cluster from nothing

The cluster can be taken down to nothing and built again from the repository, the operator's keys
and the cloud credentials. This runbook goes from a running cluster to nothing and back. Each
recipe checks what it needs before it runs anything, and a failing one ends with a line naming the
step it failed in ([cluster.md](../cluster.md#recipes)).

## What survives a rebuild

- The state bucket and each stack's state in it: a destroy empties a stack's state and leaves the
  object in the bucket ([infrastructure.md](../infrastructure.md#recipes)).
- The backup buckets and what they hold, the etcd and OpenBao snapshots among them: no stack owns them
  ([infrastructure.md](../infrastructure.md#s3-keys-and-backup-buckets)).
- The cluster's secrets bundle, `talos/<cluster>/secrets.sops.yaml`, which is committed, and the
  Talos and Flux age keys, which the operator holds. The rebuilt cluster is made from the same
  bundle, so it has the same certificate authorities and keys: the credentials in a kubeconfig or
  talosconfig made for the old cluster are valid for the new one, and a copy kept anywhere works
  again once it is pointed at the new addresses.
- The volume backups' master, in the custody file `just bao-seed-volsync` wrote, which the operator
  holds: it opens the repositories in the VolSync bucket, and the rebuilt cluster's store is seeded
  from it ([Building it again](#building-it-again)).
- Talos images that [image-replacement.md](image-replacement.md) left in the image service: no stack
  holds them, so no destroy removes them. They are removed by hand as that runbook says; once the
  nodes are destroyed, no volume made from them is left.

## What does not

- Addresses: the nodes' and the API load balancer's floating addresses go back to the cloud with
  the cluster stack, and the rebuilt cluster gets new ones. The generated files that held the old
  ones, the cluster's `talman.yaml`, talosconfig and kubeconfig, are removed with the stack and
  written again by the build.
- The contents of LINSTOR's volumes: they are on the workers' data volumes, which go with the
  cluster stack ([cluster.md](../cluster.md#the-workers-data-device)).
- OpenBao's store and every key in it, as its data is on LINSTOR's volumes: the rebuilt cluster's
  OpenBao initialises anew, with a new seal key, and the recovery keys in the old store's custody
  file open nothing in it, unless the old store's newest snapshot is restored into it with the old
  seal key in place before its first member starts
  ([openbao.md](openbao.md#restoring-a-snapshot)).
- Everything in etcd: every object of the Kubernetes API, the Secrets made in the cluster among
  them. Flux applies again what Git holds. A snapshot restores into the same nodes only
  ([etcd-restore.md](etcd-restore.md#when-to-restore)), so the steps there do not bring it into
  the rebuilt cluster.

## Taking it down

1. **The volume backups' custody file**, while the cluster still runs: check that it holds the
   master the store holds, as [volume-backups.md](volume-backups.md#opening-a-repository-by-hand)
   compares the hash of an application's derived password with that of its Secret. Once the
   cluster is gone, the file is the only copy of the master, and nothing compares it any more.

2. **`just cluster-snapshot`**, when the cluster's state matters: an etcd snapshot, encrypted, in
   the etcd bucket, which the rebuild leaves alone.

3. **`just cluster-destroy`**. It asks the cluster, through its kubeconfig, for every Service of
   type LoadBalancer and every PersistentVolume of a CSI driver. A cloud load balancer or volume
   behind one is the cluster's own and not in the cluster stack's state: its destroy would leave it
   in the cloud, where it keeps the network from being deleted. A Service whose addresses all come
   from the service range has none behind it and does not count. LINSTOR's volumes do not count
   either: their data is on the workers' data volumes, which go with the stack, and the recipe says
   how many of them the destroy takes before it asks. While there are any others, the recipe names
   each and destroys nothing; remove them first. A cluster whose API does not answer, or that has no
   kubeconfig, may still own some and is not destroyed either.
   `just cluster-destroy --unreachable` destroys it anyway; whatever it owned stays in the cloud
   until it is removed by hand.

   Then it plans the cluster stack's destroy, prints the summary and destroys once `sto2/cluster` is
   typed back, and removes the cluster's `talman.yaml`, talosconfig and kubeconfig. The plumbing
   stack, the secrets bundle and the buckets stay.

4. **`just infra-destroy sto2/plumbing`**, when the network and the Talos image should go too. The
   CI host, the `sto2/ci` stack, is on the plumbing stack's network, and the network cannot be
   removed while its port and floating IP exist. So first, in the state of every other stack, the
   recipe looks for a resource, and while it finds one it plans and destroys nothing, naming the
   stack and the recipe that destroys it: `just infra-destroy sto2/ci` for the CI host, which also
   takes the runner away until [ci-host.md](ci-host.md) sets a new host up. Then it plans the
   plumbing stack's destroy, prints the summary and destroys once `sto2/plumbing` is typed back.
   Images left from earlier Talos versions are removed by hand
   ([image-replacement.md](image-replacement.md#removing-old-images)).

## Building it again

Restoring the old store's snapshot, rather than starting OpenBao anew and writing every key again,
is chosen before `just cluster-flux` in step 1: the old seal key has to be in the cluster before
OpenBao's first member starts, and Flux, once installed, applies OpenBao as soon as its
dependencies are Ready. [openbao.md](openbao.md#restoring-a-snapshot) says when to step in; its
steps take the place of step 4's.

1. The build order in [cluster.md](../cluster.md#from-nothing-to-a-ready-cluster), from the start,
   leaving out the steps that make the age keys and the secrets bundle: they survived, and
   `just cluster-secrets` refuses to replace a bundle. The edge stack is applied before
   `just cluster-bootstrap` whether it was destroyed or not, with its environment: the bootstrap
   reads the edge routers' public addresses from its outputs into `cluster-config`, and an apply of
   a stack that stands changes nothing. Edge routers built again have new public addresses, which
   the records external-dns makes follow once `cluster-config` holds them
   ([kubernetes.md](../kubernetes.md#dns-records)).

2. **`just cluster-check`**: every check passes. Before the namespace `flux-system` exists, the
   check of its pods is skipped, and the recipe says so.

3. **`just cluster-reboot <node>`** for a control plane, by its hostname in `talman.yaml`: the check
   that the Kubernetes API stays available through its load balancer. The recipe drains the node,
   reboots it and waits until it is Ready again, asking `/readyz` through the kubeconfig once a
   second all the while; then it prints how many probes failed and the longest run of failures,
   uncordons the node and deletes the pods the shutdown left Failed on it
   ([cluster.md](../cluster.md#recipes)). It fails when any probe failed; `--tolerate <seconds>`
   accepts a gap up to that long, when the operator judges one acceptable. Run `just cluster-check`
   again afterwards: every check passes.

4. Once Flux has applied OpenBao, unless its snapshot is restored (above), the operator's steps of its
   [first initialisation](openbao.md#first-initialisation): `just bao-recovery <file>` with a new
   file, and every key the store held written again. For the volume backups that is
   `just bao-seed-volsync <file>` with the existing custody file of their master, never a new one:
   until it runs, every application's restore waits, its claim Pending, and a new master would open
   none of the repositories
   ([volume-backups.md](volume-backups.md#the-stores-key-is-lost-and-the-file-is-kept)).
