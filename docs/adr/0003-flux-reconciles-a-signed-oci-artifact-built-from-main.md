# 0003 — Flux reconciles a signed OCI artifact built from main

- Status: accepted
- Date: 2026-11-14

## Context

The cluster's desired state lives under `kubernetes/`. The cluster needs a source it can trust
and that contains nothing else from the repository.

## Decision

Flux is installed by the Flux Operator and described by a `FluxInstance`. Its source is an
`OCIRepository`, not a `GitRepository`.

CI publishes `kubernetes/` as an OCI artifact on every change to `main`: it pushes the artifact
by commit, signs it with cosign using the workflow's OIDC identity, and only then moves the
`main` tag. Publishing runs are serialised so the tag never moves backwards.

The `FluxInstance` verifies the signature against that identity, pinned to the publishing
workflow on `refs/heads/main`. An unsigned or differently signed artifact is refused.

Flux follows the `main` tag only. OpenTofu and Talos changes may be applied from a pull request
branch; manifests reach the cluster only by merging.

## Alternatives considered

- **`flux bootstrap` with a Git source.** The documented default, but the cluster would read
  the whole repository and trust anything pushed to the branch.
- **A long-lived signing key.** Works without OIDC, but is one more secret to store and rotate.

## Consequences

- A manifest change cannot be tried on the cluster before it is merged. Pull requests get a
  rendered diff instead.
- The artifact must exist and be public before the cluster can be bootstrapped.
- Flux manages its own operator and instance from the same artifact after bootstrap.
