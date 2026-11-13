# 0005 — Secrets: SOPS for bootstrap, OpenBao for runtime

- Status: accepted
- Date: 2026-11-14

## Context

The repository is public. Some secrets must exist before the cluster does; the rest are
application secrets that change over the cluster's life.

## Decision

- **Bootstrap material** is SOPS-encrypted with age and committed: the Talos secrets bundle,
  the OpenStack credential for the cloud controller and CSI driver, and the cluster's
  substitution secrets. Flux decrypts with an age key applied at bootstrap.
- **Runtime secrets** live in OpenBao running in the cluster and reach workloads through
  External Secrets and a `ClusterSecretStore`. Application secrets are not committed, encrypted
  or otherwise.
- External Secrets is installed before OpenBao; OpenBao's own seal material is produced through
  it.

## Alternatives considered

- **SOPS for everything.** No extra service, but every application secret's ciphertext is
  public permanently and rotation is a commit.
- **A hosted secret manager.** Nothing to operate, but an external account the cluster cannot
  start without.

## Consequences

- OpenBao's storage, unsealing and recovery material need their own backup and a restore that
  is exercised, since every runtime secret depends on it.
- Secrets that controllers need before OpenBao is running come from bootstrap material.
- The age private key exists outside the repository only: on the operator's machine and as a
  CI secret.
