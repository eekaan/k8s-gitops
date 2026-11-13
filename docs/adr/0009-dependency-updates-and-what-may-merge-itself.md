# 0009 — Dependency updates and what may merge itself

- Status: accepted
- Date: 2026-11-14

## Context

Charts, images and tools release constantly. A merged manifest change reaches the cluster
through Flux without further review.

## Decision

Renovate opens a pull request for every update. It merges patch and minor updates to
application manifests itself, through a pull request, once the required check has passed and
the release is at least three days old.

It never merges updates to Talos, Kubernetes, the CNI, Flux, the Flux Operator, OpenTofu or its
providers, or any major version. Those are merged by a person.

The Talos version has one source in the repository, which the image, the machine configuration
and the installer all read.

## Alternatives considered

- **No automatic merges.** Every update waits for a person; with dozens of applications the
  queue is never empty.
- **Pushing updates straight to the branch.** Skips the required check.

## Consequences

- The rendered-manifest check is what stands between an update and the cluster, so it is part
  of the required check before automatic merging is switched on.
- A bad update is rolled back by Flux's Helm remediation or reverted by a pull request.
