# 0015 — Volume backups with VolSync's restic mover

- Status: accepted
- Date: 2026-11-14

## Context

ADR 0008 has application volumes backed up by VolSync with Kopia, encrypted before they leave the
cluster. Upstream VolSync, at its current release, 0.17.0, has movers for rclone, restic, rsync over
SSH or TLS, and Syncthing, and no Kopia mover. A Kopia mover exists only in a fork of VolSync,
outside the upstream project, with its own chart and images.

## Decision

- Application volumes are backed up by upstream VolSync with its restic mover, to the VolSync
  bucket through the object storage's S3 API. restic encrypts everything it uploads with the
  repository's password, so the volumes are encrypted before they leave, as ADR 0008 requires.
- Each volume has a restic repository of its own, under its application's path in the bucket, as
  VolSync's documentation supports no repository shared between volumes. One password and the
  cluster's S3 key serve every repository.
- An application opts in with the Kustomize component `components/volsync` (ADR 0004), which makes
  its volume, fills it from the latest backup when the volume is created, and backs it up on the
  application's schedule.

## Alternatives considered

- **Kopia through the fork.** One repository for every volume, deduplicated across them, but the
  operator, its chart and its movers come from outside the upstream project, and reach this cluster
  only as the fork follows upstream.
- **VolSync's rclone mover.** Copies the volume's files to the bucket as they are: no earlier states
  to restore, and no encryption of its own.

## Consequences

- Nothing is deduplicated across volumes, and each repository is pruned on its own.
- Losing the password makes every backup unreadable, so it is kept outside the cluster as well as in
  the secret store.
- The cluster's S3 key can delete what is in the bucket; encryption protects the backups from being
  read, not from being deleted.
