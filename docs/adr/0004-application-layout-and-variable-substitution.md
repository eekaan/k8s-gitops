# 0004 — Application layout and variable substitution

- Status: proposed
- Date: 2026-11-14

## Context

Dozens of applications will be reconciled. Each needs the same shape so that defaults,
dependencies, substitution and rendering in CI work the same way for all of them.

## Decision

- An application lives at `kubernetes/apps/base/<namespace>/<app>/` as a Flux `Kustomization`
  in `ks.yaml` and its manifests in `app/`. Helm values are a plain `values.yaml` fed to the
  `HelmRelease` through a generated ConfigMap.
- `kubernetes/apps/overlays/<cluster>/kustomization.yaml` is the list of what a cluster runs.
  A disabled application stays in the list, commented out with the reason.
- The cluster's root `Kustomization` patches defaults onto every child: decryption, intervals,
  pruning, Helm remediation and drift detection, and `postBuild.substituteFrom` for the
  cluster's `cluster-config` ConfigMap and `cluster-secrets` Secret. An application opts out
  with a label.
- Each application is reconciled from its own artifact, generated per `app/` directory, so a
  change reconciles only the applications it touches.
- Cross-cutting behaviour (backup and restore, shared defaults) is a Kustomize component under
  `kubernetes/components/`, parameterised through substitution.
- Dependencies are per application (`dependsOn`), with health expressions where readiness
  means more than "applied".

## Alternatives considered

- **Layers (infrastructure, then apps) instead of per-application dependencies.** Simpler to
  read, but one failing application holds back everything in its layer.
- **A mutating webhook that injects substitution into every `Kustomization`.** Hides where
  values come from and has to be emulated when rendering in CI.

## Consequences

- Values that depend on the deployment are applied to the cluster as `cluster-config` by a
  recipe and are not committed.
- Per-application artifacts need the source-watcher controller; this record is accepted once
  that is verified on the cluster, and falls back to one shared source if it is not.
