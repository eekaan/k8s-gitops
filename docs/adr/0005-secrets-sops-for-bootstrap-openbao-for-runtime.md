# 0005 — Secrets: SOPS for bootstrap, OpenBao for runtime

- Status: accepted, amended by 0011, 0013 and 0016
- Date: 2026-11-14
- Amended: 2026-11-14, the OpenStack credential is the cloud controller's only, as volumes come
  from LINSTOR, which needs none
  ([ADR 0011](0011-persistent-volumes-from-linstor-on-a-data-volume-per-worker.md))
- Amended: 2026-11-14, a credential a controller generates in the cluster for its own workload
  stays in the Secret that controller writes
- Amended: 2026-11-14, OpenBao's seal key is generated once in the cluster and its recovery keys
  are the operator's, outside it
  ([ADR 0016](0016-openbao-unseals-itself-and-the-operator-keeps-the-recovery-keys.md))
- Amended: 2026-11-14, bootstrap material is encrypted to two age keys: the Talos secrets bundle to
  the Talos age key, which never enters the cluster, and SOPS files under `kubernetes/`, of which
  the tree has none, to the Flux age key, which the cluster holds as the Secret Flux decrypts with
  ([The Talos age key](../cluster.md#the-talos-age-key),
  [The Flux age key](../cluster.md#the-flux-age-key))
- Amended: 2026-11-14, no cloud controller runs, so the bootstrap material holds no OpenStack
  credential ([ADR 0013](0013-service-addresses-announced-over-bgp-to-edge-routers.md))
- Note: 2026-11-15, the cluster's S3 key, a cloud credential for the project's object storage, is
  a runtime secret: the operator writes it into the secret store, and the volume backups' movers
  and the etcd snapshot job get it through External Secrets
  ([S3 keys and backup buckets](../infrastructure.md#s3-keys-and-backup-buckets),
  [The repository and its password](../kubernetes.md#the-repository-and-its-password),
  [Scheduled etcd snapshots](../cluster.md#scheduled-etcd-snapshots))

## Context

The repository is public. Some secrets must exist before the cluster does; the rest are
application secrets that change over the cluster's life.

## Decision

- **Bootstrap material** is SOPS-encrypted with age and committed: the Talos secrets bundle,
  the OpenStack credential for the cloud controller, and the cluster's substitution secrets.
  Flux decrypts with an age key applied at bootstrap.
- **Runtime secrets** live in OpenBao running in the cluster and reach workloads through
  External Secrets and a `ClusterSecretStore`. Application secrets are not committed, encrypted
  or otherwise.
- **Generated credentials** stay where they are made: a credential a controller generates inside
  the cluster for its own workload, which is read only through the cluster's API, stays in the
  Secret that controller writes, and is neither committed nor copied into OpenBao. The Grafana
  operator's admin password for its Grafana is one.
- External Secrets is installed before OpenBao; OpenBao's own seal material is produced through
  it, once, and stays in the cluster; the recovery keys OpenBao makes are kept by the operator
  outside the cluster
  ([ADR 0016](0016-openbao-unseals-itself-and-the-operator-keeps-the-recovery-keys.md)).

## Alternatives considered

- **SOPS for everything.** No extra service, but every application secret's ciphertext is
  public permanently and rotation is a commit.
- **A hosted secret manager.** Nothing to operate, but an external account the cluster cannot
  start without.

## Consequences

- OpenBao's storage, unsealing and recovery material need their own backup and a restore that
  is exercised, since every runtime secret depends on it. The seal key and the recovery keys are
  in the operator's encrypted file (ADR 0016); snapshots of the storage are still to come.
- Secrets that controllers need before OpenBao is running come from bootstrap material.
- A generated credential lives only in its Secret: deleting the Secret, or the object that owns
  it, makes the controller generate a new one, and nothing restores the old.
- The age private key exists outside the repository only: on the operator's machine and as a
  CI secret.
