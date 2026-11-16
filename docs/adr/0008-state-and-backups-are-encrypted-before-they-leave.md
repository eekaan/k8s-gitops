# 0008 — State and backups are encrypted before they leave

- Status: accepted, amended by 0015
- Date: 2026-11-14
- Amended: 2026-11-14, application volumes are backed up by VolSync's restic mover, as upstream
  VolSync has no Kopia mover ([ADR 0015](0015-volume-backups-with-volsyncs-restic-mover.md))
- Amended: 2026-11-15, PostgreSQL's WAL archive and base backups are encrypted at the provider with
  a customer key (SSE-C), not before they leave the cluster: the plaintext and the key travel to
  the provider inside TLS on each request, and the provider encrypts with a key it does not store;
  object names, sizes and times are visible to it; the in-cluster S3 key alone can list and delete
  the objects but not read them. State, etcd snapshots and volume backups are still encrypted
  before they leave ([PostgreSQL](../kubernetes.md#postgresql))
- Note: 2026-11-15, the PostgreSQL cluster template also dumps each database made from it once a
  day, n8n's among them, and the job encrypts each dump with age to the Talos age key before upload:
  a daily copy, not a point in time, which the WAL archive and base backups of the amendment above
  give, encrypted at the provider. The dumps are the copy of a database that is encrypted before it
  leaves, and they are read with the Talos age key alone ([Dumps](../kubernetes.md#dumps))
- Note: 2026-11-15, etcd snapshots are taken every six hours by a CronJob in the cluster as well as
  by the operator's recipe; the job encrypts each to the Talos age key before upload, and uploads
  and prunes them with the cluster's S3 key, which reaches every bucket of the project
  ([Scheduled etcd snapshots](../cluster.md#scheduled-etcd-snapshots))
- Note: 2026-11-15, OpenBao's raft storage is snapshotted every six hours by a CronJob in the
  cluster, encrypted to the Talos age key before upload; it uploads and prunes with the cluster's S3
  key as the etcd job does ([Raft snapshots](../kubernetes.md#raft-snapshots))

## Context

OpenTofu state, etcd snapshots and application backups are stored in the cloud's S3-compatible
object storage, in the same project the cluster runs in. The cloud does not offer volume
backups in its public regions, and its object storage has no server-side encryption with
managed keys.

## Decision

- OpenTofu state is encrypted client-side with OpenTofu's state encryption from the first
  apply. Each stack has its own state object.
- etcd snapshots are encrypted with age before upload.
- Application volumes are backed up by VolSync with its restic mover, which encrypts client-side
  (ADR 0015; this record first chose VolSync's Kopia mover).
- PostgreSQL's WAL archive and base backups are written by the Barman Cloud plugin of the
  PostgreSQL operator and encrypted at the provider with SSE-C: every request carries one
  256-bit key for all of the cluster's databases, which the provider uses and does not store. The
  object storage has no managed-key encryption and Barman, which the plugin runs, has no
  client-side encryption, so SSE-C is the encryption available. The key is made once by a recipe,
  kept in a file outside the repository encrypted to the Talos age key's recipient, and written
  to the secret store.
- Workloads in the cluster use an S3 credential separate from the one that holds state.

## Alternatives considered

- **A second project for state and snapshots.** Stronger separation, at the cost of a second
  set of credentials and quotas to manage.
- **Unencrypted state.** No machine configuration is in state, but resource identifiers and
  addresses are.
- **Client-side encryption of PostgreSQL's backups.** Keeps the plaintext inside the cluster, but
  Barman has no such option, so it would need a wrapper around the archive and restore commands
  that nothing upstream maintains or tests.

## Consequences

- Losing the state passphrase or the age key makes state or snapshots unreadable; both are
  kept outside the cluster and the repository.
- Losing the SSE-C key loses every PostgreSQL base backup and WAL archive, which the provider
  cannot read for anyone. The key cannot be replaced in place: objects written under one key are
  unreadable under another, so a new key needs a new destination path or server name.
- The cluster's S3 key reaches every bucket of the project, so a workload that holds it, a
  PostgreSQL instance's backup sidecar among them, can delete or overwrite backups. SSE-C leaves
  that risk as it is and only stops the key from reading them.
- Restores are exercised by rebuilding the cluster and restoring into it, not only documented.
- Whether the object storage supports native state locking is verified; until then stacks are
  applied one at a time.
