# 0015 — Volume backups with VolSync's restic mover

- Status: accepted
- Date: 2026-11-14

## Context

ADR 0008 has application volumes backed up by VolSync with Kopia, encrypted before they leave the
cluster. Upstream VolSync, at its current release, 0.17.0, has movers for rclone, restic, rsync over
SSH or TLS, and Syncthing, and no Kopia mover. A Kopia mover exists only in a fork of VolSync,
outside the upstream project, with its own chart and images.

The restic mover reads a repository's password and S3 key from a Secret in the namespace of the
volume it copies, so whatever goes into that Secret can be read by anyone who can read Secrets in
that namespace.

## Decision

- Application volumes are backed up by upstream VolSync with its restic mover, to the VolSync
  bucket through the object storage's S3 API. restic encrypts everything it uploads with the
  repository's password, so the volumes are encrypted before they leave, as ADR 0008 requires.
- Each volume has a restic repository of its own, under its application's path in the bucket, as
  VolSync's documentation supports no repository shared between volumes.
- Each repository has a password of its own, derived from one master password: the SHA-256 digest
  of the master, a slash and the application's name. External Secrets computes it when it writes
  the application's Secret, so the component writes the master into no Secret, and the Secret in
  one namespace opens that namespace's repository only. Only the master is kept outside the
  cluster; every application's password can be computed again from it.
- Every repository is reached with the cluster's S3 key, as the object storage's keys belong to the
  project, not to one bucket or path. Each namespace that takes the component holds the key, which
  reaches every bucket of the project ([infrastructure.md](../infrastructure.md#s3-keys-and-backup-buckets)):
  whoever reads it can read, replace or delete any application's backups, though not decrypt
  another application's. What limits that is who may read Secrets in those namespaces, and that
  the cluster's key can be revoked and replaced on its own.
- An application opts in with the Kustomize component `components/volsync` (ADR 0004), which makes
  its volume, fills it from the latest backup when the volume and its restore are created together,
  and backs it up on the application's schedule.

## Alternatives considered

- **Kopia through the fork.** One repository for every volume, deduplicated across them, but the
  operator, its chart and its movers come from outside the upstream project, and reach this cluster
  only as the fork follows upstream.
- **VolSync's rclone mover.** Copies the volume's files to the bucket as they are: no earlier states
  to restore, and no encryption of its own.
- **One password shared by every repository.** Simplest, but it lands in every namespace that takes
  the component, so reading one application's Secret decrypts every application's backups.
- **One secret store key per application.** Separates the repositories as well, but each
  application needs its own password made, stored and kept outside the cluster before its first
  backup, and a rebuild needs every one of them back; the derived passwords need one.

## Consequences

- Nothing is deduplicated across volumes, and each repository is pruned on its own.
- Losing the master password makes every backup unreadable, so it is kept outside the cluster as
  well as in the secret store. Changing the master, or the derivation, changes every repository's
  password: each repository has to be given the new one with restic before the Secrets change.
- An ExternalSecret that may use the store can read the key that holds the master, so what keeps
  the master is the store's conditions on namespaces and who may create ExternalSecrets; no Secret
  the component writes holds it.
- The cluster's S3 key can delete what is in the bucket; encryption protects the backups from being
  read, not from being deleted.
