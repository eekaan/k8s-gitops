# 0008 — State and backups are encrypted before they leave

- Status: accepted
- Date: 2026-11-14
- Amended: 2026-11-14, application volumes are backed up by VolSync's restic mover, as upstream
  VolSync has no Kopia mover ([ADR 0015](0015-volume-backups-with-volsyncs-restic-mover.md))

## Context

OpenTofu state, etcd snapshots and application backups are stored in the cloud's S3-compatible
object storage, in the same project the cluster runs in. The cloud does not offer volume
backups in its public regions, and its object storage has no server-side encryption with
managed keys.

## Decision

- OpenTofu state is encrypted client-side with OpenTofu's state encryption from the first
  apply. Each stack has its own state object.
- etcd snapshots are encrypted with age before upload.
- Application volumes are backed up by VolSync, and Postgres by its operator's object-store
  backups; both encrypt client-side. This record chose VolSync's Kopia mover. ADR 0015 replaces
  that part of it: volumes are backed up with VolSync's restic mover.
- Workloads in the cluster use an S3 credential separate from the one that holds state.

## Alternatives considered

- **A second project for state and snapshots.** Stronger separation, at the cost of a second
  set of credentials and quotas to manage.
- **Unencrypted state.** No machine configuration is in state, but resource identifiers and
  addresses are.

## Consequences

- Losing the state passphrase or the age key makes state or snapshots unreadable; both are
  kept outside the cluster and the repository.
- Restores are exercised by rebuilding the cluster and restoring into it, not only documented.
- Whether the object storage supports native state locking is verified; until then stacks are
  applied one at a time.
