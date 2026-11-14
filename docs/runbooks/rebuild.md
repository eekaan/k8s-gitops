# Rebuilding the cluster from nothing

The cluster can be taken down to nothing and built again from the repository, the operator's keys
and the cloud credentials. This runbook goes from a running cluster to nothing and back. Each
recipe checks what it needs before it runs anything, and a failing one ends with a line naming the
step it failed in ([cluster.md](../cluster.md#recipes)).

## What survives a rebuild

- The state bucket and each stack's state in it: a destroy empties a stack's state and leaves the
  object in the bucket ([infrastructure.md](../infrastructure.md#recipes)).
- The backup buckets and what they hold, the etcd snapshots among them: no stack owns them
  ([infrastructure.md](../infrastructure.md#s3-keys-and-backup-buckets)).
- The cluster's secrets bundle, `talos/<cluster>/secrets.sops.yaml`, which is committed, and the
  Talos and Flux age keys, which the operator holds. The rebuilt cluster is made from the same
  bundle, so it has the same certificate authorities and keys: the credentials in a kubeconfig or
  talosconfig made for the old cluster are valid for the new one, and a copy kept anywhere works
  again once it is pointed at the new addresses.
- Talos images that [image-replacement.md](image-replacement.md) left in the image service: no stack
  holds them, so no destroy removes them. They are removed by hand as that runbook says; once the
  nodes are destroyed, no volume made from them is left.

## What does not

- Addresses: the nodes' and the API load balancer's floating addresses go back to the cloud with
  the cluster stack, and the rebuilt cluster gets new ones. The generated files that held the old
  ones, the cluster's `talman.yaml`, talosconfig and kubeconfig, are removed with the stack and
  written again by the build.
- Everything in etcd: every object of the Kubernetes API, the Secrets made in the cluster among
  them. Flux applies again what Git holds. A snapshot restores into the same nodes only
  ([etcd-restore.md](etcd-restore.md#when-to-restore)), so the steps there do not bring it into
  the rebuilt cluster.

## Taking it down

1. **`just cluster-snapshot`**, when the cluster's state matters: an etcd snapshot, encrypted, in
   the etcd bucket, which the rebuild leaves alone.

2. **`just cluster-destroy`**. It asks the cluster, through its kubeconfig, for every Service of
   type LoadBalancer and every PersistentVolume of a CSI driver. The cloud's load balancers and
   volumes behind them are the cluster's own and not in the cluster stack's state: its destroy would
   leave them in the cloud, where they keep the network from being deleted. While there are any,
   the recipe names each and destroys nothing; remove them first. A cluster whose API does not
   answer, or that has no kubeconfig, may still own some and is not destroyed either.
   `just cluster-destroy --unreachable` destroys it anyway; whatever it owned stays in the cloud
   until it is removed by hand.

   Then it plans the cluster stack's destroy, prints the summary and destroys once `sto2/cluster` is
   typed back, and removes the cluster's `talman.yaml`, talosconfig and kubeconfig. The plumbing
   stack, the secrets bundle and the buckets stay.

3. **`just infra-destroy sto2/plumbing`**, when the network and the Talos image should go too. It
   plans the plumbing stack's destroy, prints the summary and destroys once `sto2/plumbing` is typed
   back. Images left from earlier Talos versions are removed by hand
   ([image-replacement.md](image-replacement.md#removing-old-images)).

## Building it again

1. The build order in [cluster.md](../cluster.md#from-nothing-to-a-ready-cluster), from the start,
   leaving out the steps that make the age keys and the secrets bundle: they survived, and
   `just cluster-secrets` refuses to replace a bundle.

2. **`just cluster-check`**: every check passes. Before the namespace `flux-system` exists, the
   check of its pods is skipped, and the recipe says so.

3. **`just cluster-reboot <node>`** for a control plane, by its hostname in `talman.yaml`: the check
   that the Kubernetes API stays available through its load balancer. While the node reboots,
   `/readyz` is asked through the kubeconfig once a second, and once the node is Ready again the
   recipe prints how many probes failed and the longest run of failures. It fails when any probe
   failed; `--tolerate <seconds>` accepts a gap up to that long, when the operator judges one
   acceptable.
