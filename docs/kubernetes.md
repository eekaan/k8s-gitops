# The kubernetes/ tree

`kubernetes/` is everything Flux reconciles; CI publishes it as the cluster's artifact
(ADR 0003). `just kubernetes-check` builds it offline with kustomize and Flux, and fails, naming
the file, when a cluster directory, a `ks.yaml`, an application directory or a variable breaks
the rules below.

## Layout

- `clusters/<cluster>/`: the cluster's root Kustomization in `ks.yaml`, a `kustomization.yaml`
  that lists only that, and the example key lists, which nothing lists.
- `apps/overlays/<cluster>/kustomization.yaml`: what the cluster runs.
- `apps/base/<namespace>/`: a namespace directory, with `namespace.yaml` and a
  `kustomization.yaml` that sets the namespace and includes `components/common`.
- `apps/base/<namespace>/<app>/`: an application, its Flux Kustomization in `ks.yaml` and its
  manifests in `app/`.
- `apps/base/flux-system/artifact-generator/`: publishes one artifact per application.
- `components/`: Kustomize components. `common` adds the `app-template-defaults` ConfigMap, which
  an app-template HelmRelease opts into through `valuesFrom`.

## Adding an application

Put the manifests in `apps/base/<namespace>/<app>/app/` with their own `kustomization.yaml`, and
this `ks.yaml` beside the directory:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: <app>
  namespace: flux-system
spec:
  path: ./apps/base/<namespace>/<app>/app
  targetNamespace: <namespace>
  sourceRef:
    kind: ExternalArtifact
    name: <app>
```

- `<app>` is a DNS label (lowercase letters, digits and `-`) and unique across every namespace,
  enabled or not. `metadata.name` and `sourceRef.name` are `<app>`, `targetNamespace` is
  `<namespace>`, and `path` is the application's own `app/`.
- `dependsOn`, `wait`, `healthCheckExprs`, `components` and `postBuild.substitute` belong to the
  application. The fields the root sets do not; see below.
- A new namespace gets its directory: `namespace.yaml` with the Pod Security labels and the
  annotation `kustomize.toolkit.fluxcd.io/prune: disabled`, so removing it from the tree does not
  delete what runs in it.

Enable the application by listing its namespace directory, once, and its `ks.yaml` in
`apps/overlays/<cluster>/kustomization.yaml`. A disabled application stays in the list,
commented out with the reason:

```yaml
  # - ../../base/demo/hello/ks.yaml  # Disabled: <reason>
```

## What the root sets

The root Kustomization patches every child Kustomization with:

- `interval: 30m`, `retryInterval: 1m`, `timeout: 3m`, `prune: true`,
  `deletionPolicy: WaitForTermination` and SOPS `decryption`;
- `postBuild.substituteFrom` with the ConfigMap `cluster-config` and the Secret `cluster-secrets`;
- `patches` holding the defaults for every HelmRelease the child applies: install and upgrade
  remediation with three retries and rollback, CRDs created and replaced, Helm tests, drift
  detection and a history of three releases.

These overwrite the child's own values, and lists such as `patches` are replaced whole, so a
child that sets any of these fields without opting out fails the check.

## Labels

- `k8s-gitops/defaults: disabled` on a child Kustomization: none of the defaults apply, and the
  child sets `interval`, `prune` and anything else it needs itself. On a HelmRelease: that
  release gets none of the release defaults.
- `k8s-gitops/timeout: long` on a child Kustomization: a 10m timeout with every other default
  kept. It does nothing on a child that opted out.

## Every child Kustomization is in flux-system

`postBuild.substituteFrom` has no namespace field: Flux reads the ConfigMap and Secret from the
Kustomization's own namespace. `cluster-config` and `cluster-secrets` live in `flux-system`, so
every child Kustomization lives there too and sets `targetNamespace` for what it deploys.

## Variables

- `${VAR}` is replaced from `cluster-config` or `cluster-secrets`. Their values are never
  committed in plain text; their key names are, with placeholder values, in
  `clusters/<cluster>/cluster-config.example.yaml` and `cluster-secrets.example.yaml`. Add a key
  there when a manifest starts using it.
- `${VAR:=value}` gives a default.
- Values for one application go in its `postBuild.substitute`.
- `$${VAR}` reaches the application as `${VAR}`.
- Helm values are generated into a ConfigMap with the annotation
  `kustomize.toolkit.fluxcd.io/substitute: disabled`, which leaves any `${...}` in them alone;
  so does the annotation on any other object.

The check builds every application with Flux's strict substitution, using the placeholders, so a
variable that is none of the above fails it.

## Per-application artifacts

The ArtifactGenerator publishes each application's `app/` as an ExternalArtifact named after
the application, together with `components/`, at the same paths as in the tree, so a change
reconciles only the applications it touches (ADR 0004). Falling back to one shared source is a
`sourceRef` change in each `ks.yaml`, to `kind: OCIRepository` and `name: flux-system`.
