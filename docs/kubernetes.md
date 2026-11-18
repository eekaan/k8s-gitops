# The kubernetes/ tree

`kubernetes/` is everything Flux reconciles; CI publishes it as the cluster's artifact
(ADR 0003, [Publishing](#publishing)). `just kubernetes-check` builds it offline with kustomize and Flux, and fails, naming
the file, when a cluster directory, a `ks.yaml`, an application directory or a variable breaks
the rules below, or when a dependency the cluster would never reconcile passes the build;
`just kubernetes-validate` adds the rules that need the render or the network, schemas and images
([What the checks refuse](#what-the-checks-refuse)).

## Layout

- `clusters/<cluster>/`: the cluster's root Kustomization in `ks.yaml`; Flux's own two
  applications in `flux-system/flux-operator/` and `flux-system/flux-instance/` (see
  [Flux itself](#flux-itself)); a `kustomization.yaml` that lists the root's and those two
  `ks.yaml` files and nothing else; the example key lists; and, once the cluster has substitution
  secrets, `secrets/cluster-secrets.sops.yaml` (see [Before Flux starts](#before-flux-starts)).
  Nothing lists the last two.
- `apps/overlays/<cluster>/kustomization.yaml`: what the cluster runs.
- `apps/base/<namespace>/`: a namespace directory, with `namespace.yaml` and a
  `kustomization.yaml` that sets the namespace and includes `components/common`.
- `apps/base/<namespace>/<app>/`: an application, its Flux Kustomization in `ks.yaml` and its
  manifests in `app/`, which is all the artifact generator publishes. A manifest outside `app/`, or
  in it but not listed by `app/kustomization.yaml` (directly, through a directory or component it
  lists, as a patch or as a generator's file), is never applied, and the check refuses it.
- `apps/base/flux-system/artifact-generator/`: publishes one artifact per application.
- `components/`: Kustomize components. `common` adds the `app-template-defaults` ConfigMap, which
  an app-template HelmRelease can opt into through `valuesFrom`, though `scripts/render` reads only an
  application's own ConfigMaps ([n8n](#n8n) writes the defaults out); `cnpg-cluster` adds an application's
  PostgreSQL cluster and its backups ([PostgreSQL](#postgresql)); `volsync` backs an application's volume up
  ([Volume backups](#volume-backups)).

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
- What `dependsOn` names is an application the cluster's overlay enables, and one that waits: it
  sets `wait: true`, `healthChecks` or `healthCheckExprs`, so it is Ready only once what it
  applies is. A dependency on an application a cluster deliberately does not enable is an error:
  the dependent would never reconcile there, so the dependent is not enabled either, or the
  dependency is.
- A new namespace gets its directory: `namespace.yaml` with the Pod Security labels
  ([Pod Security](#pod-security)) and the annotation `kustomize.toolkit.fluxcd.io/prune: disabled`,
  so removing it from the tree does not delete what runs in it.
- The namespace enforces the strictest Pod Security level the application's workloads pass. A
  workload that needs more than `restricted` is an entry of `pod-security-exceptions.yaml` with its
  reason, and `just pod-security-check` fails when the namespace's labels or the entries do not
  match what the render holds. A custom resource whose operator creates pods sets the security
  context `restricted` requires where the resource has the fields, and `tests/pod-security.bats`
  lists it; a pod it makes that needs more is an entry with `created-by`.
- The namespace denies ingress and egress by default, and the application declares the flows it
  lets through in a `CiliumNetworkPolicy` beside it ([Network policy](#network-policy)): a new
  namespace gets a `default-deny` `NetworkPolicy` next to its `namespace.yaml`, or an entry of
  `network-policy-exceptions.yaml` with its reason, and `just network-policy-check` fails until
  one of them holds.
- A key the application reads from the secret store, through an ExternalSecret, gets its entry in
  `secret-rotation.yaml`, which says how the key is rotated
  ([Rotating an application's secret](#rotating-an-applications-secret)); `tests/openbao.bats`
  fails for a key that is read and has none.

An application the overlay selects also has an entity in Backstage's catalogue, in the same change
([Backstage](#backstage)); `tests/backstage.bats` fails without it.

Enable the application by listing its namespace directory, once, and its `ks.yaml` in
`apps/overlays/<cluster>/kustomization.yaml`. A disabled application stays in the list,
commented out with the reason:

```yaml
  # - ../../base/demo/hello/ks.yaml  # Disabled: <reason>
```

The application's versions are pins for Renovate: its chart's tag under a `# renovate:
datasource=… depName=…` comment, as the other applications' sources have it, and any image in its
values. Once they are in place, `just renovate-record` writes what Renovate extracts to
`.renovate/extracted.tsv`, which the change commits; a pin under such a comment also gets the form
of its datasource's tags in `.renovate/tag-forms.tsv`, read from the registry's own listing, and a
pin that no manager reads is listed in `.renovate/by-hand.tsv` with why and how it is moved.
`just renovate-check` and `just renovate-pins` fail, naming the file to change, until they hold. The
chart's source is a row of `signatures.yaml`, and where its publisher signs keyless its
`OCIRepository` carries the row's `verify` block ([Adding a source](#adding-a-source)); `just
signatures-check` fails, naming the source, until it holds.

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

## What the checks refuse

Beyond the layout above, two checks refuse what the cluster would refuse or never reconcile, split
by what a rule needs:

- `just kubernetes-check` holds every rule that reads only the tree and what kustomize and Flux
  build from it: the layout, a manifest outside what the artifact carries, and the dependencies.
  It fetches nothing, and it is the gate of the publish run, in the job that signs
  ([Publishing](#publishing)), so nothing that job runs comes from the network.
- `just kubernetes-validate` holds the rules that need the network or the render: schemas and
  images. It runs `kubernetes-check` first, keeping what Flux builds, and stops when that fails;
  then `scripts/render`, whose output it reads. It is a check of the `static` group, so it runs on
  every pull request and every push to `main`, and not in the publish run.

The sources' signatures have two checks of their own, beside these ([Signatures](#signatures)):
`just signatures-check`, offline, on what `kubernetes-check` builds, holds every chart source to its
row of `signatures.yaml` and the rows to the verify blocks, and is a check of `static`; `just
signatures-verify` asks the registries whether each pin is signed as its row says, and is the group
`signatures` alone. Neither is in the publish run.

That split is the design, and its cost is this: a tree with a misspelt field or an untagged image
fails every pull request's `static` group, but the publish run does not refuse it again. Where the
ruleset does not require a branch to be up to date with `main` before it merges, two pull requests
that pass apart can still merge into such a tree, and the run that publishes it passes. The control
is the next run of the validation: the `static` group of that push to `main`, and of every pull
request after it, fails, naming the file, until a pull request fixes the tree.

On what Flux builds:

- **Dependencies** (`kubernetes-check`), on the root's build, so its patches count. Each
  `dependsOn` of the Kustomizations the overlay and the cluster directory build (the application
  Kustomizations, the root, `flux-operator`, `flux-instance`) names one that the same cluster
  applies: one the overlay lists, or one the cluster directory builds. The Kustomizations an
  application applies from its own `app/` are not read. It must also wait after the root's
  patches: `wait: true`, `healthChecks` or `healthCheckExprs`. Otherwise the dependent never
  reconciles, or starts before its dependency's objects are ready. The message names both
  Kustomizations and the overlay.
- **A kind that does not exist yet** (`kubernetes-check`). A Gatekeeper constraint
  (`constraints.gatekeeper.sh`) is of a kind Gatekeeper makes only after it has reconciled the
  `ConstraintTemplate`, so Flux's server-side dry run of a constraint fails for the unknown kind and
  nothing of a Kustomization that holds it is applied, the template included, and no retry can
  succeed. The check refuses a constraint in the Kustomization of its own template, one whose
  Kustomization does not name the template's in `dependsOn` (directly or through others), one whose
  template no application the overlay enables holds, and a template's Kustomization that does not
  wait (`wait: true`, or `healthChecks` naming that template, as without `wait` Flux checks only what
  `healthChecks` names) on `healthCheckExprs` for `templates.gatekeeper.sh` `ConstraintTemplate`,
  every entry of them with `current: status.created == true` and no `inProgress` or `failed`: Flux
  takes an applied template for ready, so without the entry the constraints start before the kinds
  are served, and it reads `inProgress` and `failed` before `current`, so either could hold the
  templates back for good. The message names the Kustomization and the constraint.
- **A repeated key in what a chart renders** (`scripts/render`, so `just render-check` and
  `kubernetes-validate`; [The render diff](#the-render-diff)).
- **Paths** (`kubernetes-check` and `scripts/render`). `flux build` reads with kustomize's load
  restrictions off (`LoadRestrictionsNone`, its own setting), and so does `kubernetes-check`'s
  `kustomize`, as an overlay lists `ks.yaml` files outside its own directory: either reads any path
  a kustomization names and follows any link. Both read a kustomization, and `flux build` the Flux
  Kustomization it is given, with Go's `encoding/json`, which reads a key into a field when the key
  is the field's name or folds to it, so `spec.Components` is `spec.components` to `flux build`.
  Before they read or build anything else, both checks refuse a tree from which a build would read
  outside `kubernetes/`, or that a tool would read otherwise than they do, naming each file and the
  key or entry, and build nothing (`scripts/lib/tree-paths.sh`):
  - a link in the tree that resolves outside it, or to nothing;
  - a kustomization file (`kustomization.yaml`, `kustomization.yml` or `Kustomization`, a
    Component's included, used or not) that is not one mapping (empty, a list, text, or more than
    one document), or that holds a key twice, an anchor, an alias, a merge key, a tag outside YAML's
    core schema or a NUL character, which kustomize's decoder may read otherwise than the checks;
  - a kustomization file with a key, at any position kustomize decodes into a type, that is not
    ASCII or not exactly one of that type's fields, or with a field the checks refuse
    (`generators`, `transformers` and `validators`, whose plugin configurations name files of their
    own, and the Helm chart fields, as neither Flux nor the checks inflate a chart);
  - an entry of a field that names a file or a directory that is not a plain path, or that leaves
    the tree, read as text or with every link on it resolved;
  - a root whose `spec.path` is not a plain path of a directory of the tree under `kubernetes/`, as
    it resolves;
  - a Flux Kustomization with a key, at any position `flux build` decodes into a type, that is not
    ASCII, or that folds to one of that type's fields without being it, or whose `spec.components`
    names anything but a plain path of the tree. `kubernetes-check` checks each `ks.yaml` it builds
    before it builds any, and the file it hands `flux build` as it builds; the render checks each
    cluster's root before it builds anything and each Kustomization as it hands it to
    `flux build`. `flux build` reads no key that matches no field, and the schema check below
    refuses one.

  A plain path is relative, and made of segments of the ASCII letters, digits, `.`, `_` and `-`
  alone, separated by single `/`: none empty and none that starts with `-`. A segment that is
  exactly `..` climbs, and is allowed only while the resolved path stays inside the tree; dots
  inside a longer segment, as in `a..b` or `...`, are part of a name. A generator's `KEY=PATH` has a
  key of the same characters. So no entry holds `:`, `@`, `?`, `#`, `%`, `\`, `~`, a space, a
  control character or a byte outside ASCII, and none is a URL, an scp-style address or a `git::`
  form. kustomize reads one remote form without those, a path whose first segment is `github.com` in
  any case (`isStandardGithubHost` in its `api/internal/git/repospec.go`), and the checks refuse
  that too. The checks judge the tree's text with `jq`, which reads it as Unicode code points, and
  run their scripts and every function of the guard in the C locale, so the caller's locale changes
  nothing they decide; a value of the tree in a message shows each byte outside printable ASCII as
  `\xHH`.

  The free-form positions are not checked by key: labels, annotations, `commonLabels`,
  `commonAnnotations`, a label's `pairs`, generator options' labels and annotations,
  `postBuild.substitute`, the text of a patch, generator literals, a release's `values` and a
  ConfigMap's data are maps or text, which the decoders read by exact key or not at all and never
  as a path, a host or a field. The fields the checks know are recorded with the types they come
  from: `tests/fixtures/kustomization-fields` (kustomize's `Kustomization` and every type it holds),
  `flux-kustomization-fields` (Flux's `Kustomization` and every type it holds) and `read-fields`.
  `tests/kubernetes-check.bats` fails when either pinned tool moves to another version of these
  types until they are read again, and when the checks and a list disagree; it writes every case
  and `encoding/json` fold of every field at every position, and every kind of character a plain
  path holds none of in every field that names a file, into a tree, and requires each to be
  refused, naming the file and the key or entry, by every check that reads it, in the C locale and
  in C.UTF-8.

  The grammar is what refuses every URL: no entry with a `:` passes. The builds of the checks run
  in a second layer under it: `kustomize`, `flux build`, `helm template` and the Pod Security
  check's `flux install` see a `git` first on their path that refuses, which is what kustomize runs
  for a remote base (`exec.LookPath("git")`), git's protocols and prompts off; `HTTP_PROXY` and
  `HTTPS_PROXY`, in both cases, name port 0 of the loopback, where nothing listens, with `NO_PROXY`
  empty, so Go's HTTP client, with which kustomize fetches a remote file, sends a request for any
  other host there and fails. `ALL_PROXY`, in both cases, names the same port for git and libcurl,
  which read it; Go does not. The layer does not cover a plain HTTP request to the loopback of the
  machine that runs a check, which Go never sends to a proxy, so what a check builds is held to the
  grammar first: the tree, and each source `kubernetes-validate` builds definitions from
  ([Schemas](#what-the-checks-refuse)). The processes that fetch are
  `helm pull` in the render, for the charts; `kubernetes-validate`'s own `helm pull`, for the chart
  an `OCIRepository` it reads definitions from pins, when the render has not pulled it; its `curl`,
  for Flux's schemas and for the archive of each GitHub repository it reads definitions from; and
  `kubeconform`, for Kubernetes' schemas.

  The `spec.path` of an application's `ks.yaml` is compared with the one its directory fixes, and
  what is built is that directory's `app/`. The render builds a copy of `kubernetes/` alone and
  reads `versions.yaml` beside it, neither of them a link.

  A document no tool decodes is read by the checks by its fields' exact names, and they hand a tool
  only what they derive from it: the render a HelmRelease and the `OCIRepository` or
  `HelmRepository` it names, from which helm gets a chart's URL, name and version as arguments and
  values files the render writes, and kustomize a kustomization the render writes from the
  release's post-renderers; the Pod Security check a `FluxInstance`, from whose patches it writes a
  kustomization; `kubernetes-validate` a Kustomization of an application that applies from a
  `GitRepository` or an `OCIRepository` (its `path` and `sourceRef`), that source (a
  `GitRepository`'s `url`, `ref` and `sparseCheckout`, an `OCIRepository`'s `url`, `ref` and
  `layerSelector`), and the source object `operator-definitions.yaml` names (its `ref`) or the
  version of `versions.yaml` it names, from which
  curl gets the URL of a repository's archive at a tag, tar the directories to unpack, helm a
  chart's URL and version, and kustomize a directory of what was unpacked to build, the
  Kustomization's `path` or the one `operator-definitions.yaml` names. The API server drops a field
  of a custom resource that its schema does not name, by exact name, so the cluster ignores the same
  spellings the checks do not read; a key that is not ASCII, or that folds to a field they read
  without being it, is refused (`tests/fixtures/read-fields`). What they hand kustomize, a
  post-renderer's or the instance's patches and a post-renderer's images, holds a patch, its target
  and an image's fields by their exact names alone: any other key there, such as a `path` kustomize
  would read or fetch, is refused.
- **Schemas** (`kubernetes-validate`). Everything Flux builds as `kubernetes-check` builds it,
  each application from its own `ks.yaml` (enabled or not), each cluster's root and each cluster
  directory, is validated by kubeconform with unknown fields refused, against the first schema
  that has its kind: Flux's for the Flux release pinned in `mise.toml`, one made from a
  CustomResourceDefinition (below), or Kubernetes' for the Kubernetes version in `versions.yaml`.
  The HelmReleases of an application a cluster enables are validated as the render builds them,
  with the patches the root gives each child, the release defaults among them; those of an
  application no cluster enables, as its own `ks.yaml` builds them. A misspelt field, a field of
  the wrong type and a missing required field fail, naming the file, the object and the field. A
  definition's schema is its version's `openAPIV3Schema`, made as strict as Kubernetes' own:
  wherever it lists the fields of an object, it refuses any other, unless that object keeps
  unknown fields (`x-kubernetes-preserve-unknown-fields`, wherever it is set) or says what other
  fields may be; the conditions of `allOf`, `anyOf`, `oneOf` and `not` state what a value must
  satisfy and list no fields an object has, so they refuse none; a field the definition defaults is
  not required, as the API server fills it in before it validates; at the top it also lists
  `apiVersion`, `kind` and `metadata`, which the API server adds to every definition; OpenAPI's
  `nullable` becomes JSON Schema's null type. Each schema made is compiled once, by kubeconform on
  an object of its kind: one that does not compile fails the check, naming the definition, as
  kubeconform would otherwise take it for no schema. Two different definitions of one kind and
  version fail the check, and neither is used. A definition of one of Kubernetes' own groups or
  Flux's (listed below) fails the check, naming it and its file, whether a chart, a source or an
  operator's published files bring it, and no schema is made of it: the API server serves
  Kubernetes' kinds itself and Flux's definitions come with its release, so those kinds are
  validated against Kubernetes' schemas and the pinned Flux release's alone. So does a definition
  whose group has no dot and is not one of Kubernetes' own, which the API server refuses of a
  definition's group.

  Where a kind's definition comes from is the pin the cluster gets it from:
  - A chart's, at the version the HelmRelease pins: the render holds them, templates and `crds/`
    alike (`helm template --include-crds`), as the cluster's Helm release installs them.
  - A Kustomization applied from a `GitRepository` or an `OCIRepository` of the application
    (`gateway-api-crds`, `snapshot-controller` and `envoy-gateway-crds`; [Resource
    definitions](#resource-definitions)): these reach the cluster by a path the render does not
    follow, so the check reads them itself. It takes the source object in the same build, its
    `ref.tag` and, for a `GitRepository`, its `sparseCheckout`; fetches the source at that tag;
    holds what it unpacked to the rules above for the tree's links and kustomization files, with
    the source in place of `kubernetes/`, so that no link leads out of it and none of its
    kustomization files holds what those rules refuse, a URL or a path out of it among them;
    builds the Kustomization's `spec.path` of it as Flux does, with the directory's
    `kustomization.yaml` or, with none, from every YAML file in it; and keeps its
    CustomResourceDefinitions. A `GitRepository` is read from `github.com` only, its `url`
    `https://github.com/<owner>/<repository>` without `.git`, as GitHub serves a repository's
    archive under its name alone; an `OCIRepository` only when its `layerSelector` unpacks a Helm
    chart. A source that names a ref other than a tag, cannot be had, holds what the rules refuse
    or does not build fails the check, naming the Kustomization, as the definitions it brings
    would otherwise go unvalidated unseen. The Kustomization's own
    patches are not applied: the Gateway API's delete an admission policy, which is no
    definition.
  - An operator's, when the operator installs its definitions itself when it starts and its chart
    ships none, and Talos', which installs its own on the control planes:
    `operator-definitions.yaml` at the repository root says where the files of them are. An entry
    has a `group`; a `repository`, `https://github.com/<owner>/<repository>` without `.git`; a
    `path`, a plain path of a directory in it; a `tagPrefix`; and what pins the version, either a
    `sourceRef`, the `kind` (`OCIRepository` or `GitRepository`), `namespace` and `name` of the
    source object that pins the operator's chart, as its application builds it, or, for what no
    source object pins, a `versionsKey`, the key of `versions.yaml` that holds the version; and no
    other field. The check takes that object's `ref.tag`, which must be its one ref, or that
    version, puts the prefix before it, fetches the repository at that tag as it fetches a
    `GitRepository`, unpacked at the path alone, reads the directory as it reads a source's, and
    keeps the definitions of the group. So the definitions follow the version the tree pins, with
    no version of their own to move. An entry is refused, before anything is fetched for it, when
    a field is wrong, when it names both a `sourceRef` and a `versionsKey`, when its group is one
    of Kubernetes' own or Flux's, when it declares a group and path twice, when its source object
    names another ref or has a key that folds to a field the check reads, or when the tag it
    derives has not the shape of one; one whose source object is not in the tree, whose key
    `versions.yaml` holds no version under, or whose definitions no object of the tree is of, fails
    the check as having no use. The entries:
    - Cilium's: its operator installs the definitions it embeds, the files of
      `pkg/k8s/apis/cilium.io/client/crds/v2` in `github.com/cilium/cilium`
      (`pkg/k8s/apis/cilium.io/client/register.go`), at `v` followed by the tag of the
      `OCIRepository` `cilium`: Cilium tags its chart with the version it runs, and the chart runs
      the operator image of that version after a `v`, which the tree's values leave alone.
      `tests/kubernetes-validate.bats` renders the pinned chart with the tree's values and fails
      when the operator's image is tagged otherwise.
    - Talos': the `ServiceAccount` kind of `talos.dev`, which the snapshot job's grant uses
      ([Scheduled etcd snapshots](cluster.md#scheduled-etcd-snapshots)). Talos builds the
      definition in code (`internal/app/machined/pkg/controllers/k8s/internal/k8stemplates/crds.go`
      in `github.com/siderolabs/talos`) and applies it on the control planes once a
      `KubeTalosAPIAccessConfig` document is in their machine configuration, and publishes no file
      of it. The one file of it in the repository at the release the tree pins is the golden file
      of that package's unit test, in its `testdata`, which the test requires to equal what the code
      builds; the entry reads that directory at the tag that is `versions.yaml`'s `talos`, the
      version the nodes run. A Talos release that moves the file fails the check, naming the entry,
      until its `path` follows.

  An object of a kind that none of these describes fails the check, naming the object, its kind
  and its file, unless `schema-exceptions.yaml` at the repository root lists the kind. An entry
  has a `group`, a `kind` and a `reason`: why no schema can be made at the version the tree pins,
  and what proves the kind's objects instead, or that nothing does. The group is never one of
  Kubernetes' own or Flux's, whose kinds always have a schema (the core group, `apps`, `batch`,
  `policy`, `autoscaling`, and the `*.k8s.io` groups `rbac.authorization`, `networking`,
  `storage`, `admissionregistration`, `apiextensions`, `scheduling`, `node`, `coordination`,
  `certificates`, `discovery`, `events`, `apiregistration`, `flowcontrol.apiserver`, `resource`,
  `authentication`, `authorization`, `storagemigration`, `internal.apiserver`; Flux's
  `*.toolkit.fluxcd.io` and `source.extensions.fluxcd.io`): an object of one of those with no schema
  is an error, the apiVersion or kind being wrong or the schemas older than this API. An entry is
  added in the same change as the first object of its kind, and removed in the change that gives the
  kind a definition or removes its last object: an entry whose kind has a schema, or that no object
  of the tree is of, fails the check, as the other lists of the tree do. The check prints each
  listed kind with the number of its objects
  (`listed without a schema: <kind> (<group>/<version>): <n> objects`) and ends with how many
  objects it validated and how many are of listed kinds, so a pass never silently means a skip. The
  list holds three kinds, the constraint kinds of `constraints.gatekeeper.sh` that Gatekeeper makes
  from its templates at run time, which `gator` checks instead
  ([Admission policy](#admission-policy)): the check prints each of them with its one object, and
  `3 of listed kinds`. Every other kind of the tree has a schema.

  What the check does not evaluate: the rules a definition states in CEL
  (`x-kubernetes-validations`), which are the API server's; admission webhooks and policies;
  defaulting, which it only allows for (a field a definition defaults may be left out, and the
  default is not applied); and anything an operator checks when it reconciles an object. The
  definitions read from a source or for an operator are used by `kubernetes-validate` alone: the
  render, and so the Pod Security check, still holds only what a HelmRelease's chart renders, and
  does not gain the objects or kinds of those sources.

  The schemas are fetched at exact versions, never from a moving reference: Flux's from the
  release asset `crd-schemas.tar.gz` of the pinned Flux release, Kubernetes' a kind at a time from
  the public `yannh/kubernetes-json-schema` repository at the commit `kubernetes_schemas` in
  `versions.yaml` names, the definitions of a `GitRepository` source from the archive GitHub
  serves for its tag (`https://github.com/<owner>/<repository>/archive/refs/tags/<tag>.tar.gz`,
  unpacked only where the `sparseCheckout` says), those of an `OCIRepository` source by
  `helm pull` of the chart at its tag, from the chart the render has already pulled when it is the
  same one (`envoy-gateway` and `envoy-gateway-crds` name one), and an operator's from the same
  archive of the repository `operator-definitions.yaml` names, at the tag it derives, unpacked only
  at its path (Cilium's archive is about 55 MB, Talos' about 6 MB). Each source is pulled once a
  run, into the run's own temporary directory, which nothing outlives; nothing is cached beyond it
  except in the `RENDER_CHART_CACHE` a person sets by hand. Nothing verifies a source beyond its
  tag, as Flux's own checkout and unpack verify none. A `kubernetes` version that commit holds no
  schemas for fails the check until the commit moves. Renovate's git-refs datasource reads the
  commit through the `# renovate-ref:` comment above it and proposes the newest commit of that
  repository's branch whenever the branch moves, whatever the Kubernetes version, in the
  Kubernetes group with `kubernetes` and the `kubectl` pin. The group keeps patch releases apart
  from the rest (`separateMinorPatch`), so the schemas commit arrives in the group's pull request
  with a minor release, and alone otherwise: a patch release of Kubernetes comes in a pull request
  of its own, whose check fails, when the pinned commit lacks that version's schemas, until the
  schemas pull request has merged and the patch's runs again. The sources' tags are the ones
  Renovate already moves in the applications' own files, an operator's definitions move with
  the tag of its chart, and Talos' with `versions.yaml`'s `talos`, which Renovate moves with the
  `talosctl` pin. The requests are plain GETs that carry nothing from the tree beyond the
  kind, group and version of each object whose kind no definition describes, which name the schema
  file asked for, whether or not it exists, and the repository, tag and chart the tree's own
  sources, `operator-definitions.yaml` and `versions.yaml` name. curl, helm and kubeconform run with
  none of the secrets of the caller's environment (`scripts/lib/tools.sh`).
  `KUBERNETES_VALIDATE_SCHEMAS`, a
  directory with `kubernetes/<version>-standalone-strict/` and `flux/`, replaces those sources, as
  the tests do with their fixtures, and `sources/github.com/<owner>/<repository>/<tag>/` and
  `sources/<registry>/<repository>/<tag>/` replace the checkouts, an operator's repository
  included, and the unpacked charts.
- **Images** (`kubernetes-validate`). In what `scripts/render` writes, which builds each
  application as the root patches it, the Helm hooks of the enabled releases included, every image
  of a container, init container or ephemeral container of a pod spec, wherever an object holds
  one, and every image an object names in its own `spec.image`, as Prometheus and Alertmanager
  name the one their operator runs, has a tag other than `latest` or a digest: `sha256` and 64
  hexadecimal digits, as a reference with any other digest pins nothing. A mutable or missing tag
  is pulled anew at every upgrade, and a failed pull in a Helm test fails the upgrade, which the
  default remediation rolls back. A test hook the release does not run (`test.enable` unset or
  false, or the test excluded by name in `test.filters`) is not pulled and is left out; a hook
  that is no test runs whatever the release's tests do. The root's defaults set
  `test.enable: true` on every release and overwrite a release's own value, so a release that must
  not run a test excludes it by name, as `kubelet-csr-approver` does with its chart's `test-connection`. An
  exception is one line of `.image-allowlist`: the application, the image as rendered, and the
  reason, which the check requires. Images an object names anywhere else are not read, and their
  pins are Renovate's or a change by hand to keep: the image list of the Piraeus operator's
  ConfigMap, Envoy Gateway's configuration ConfigMap, the Grafana resource's `spec.version`,
  the FluxInstance's `spec.distribution`, and the images the OpenFeature Operator puts into other
  pods, which reach it as environment variables and which `tests/open-feature-operator.bats` holds
  to a tag and a digest ([OpenFeature Operator](#openfeature-operator)).

`kubernetes-validate` runs the render once, so it pulls the charts as `just render-check` does, and
the `static` group runs both, each pulling them. Sharing them would take a directory that outlives
one recipe: `just` has none that lasts exactly one run of the group, and a cache kept beyond a run,
on the CI host's persistent engine, would be one a pull request's code could write for the runs
after it, so neither keeps one. `RENDER_CHART_CACHE`, set by hand, serves both.

What the tree and the charts hold is data to the validation, a chart's definitions included, which a
pull request that bumps a chart's version does not show. A group, version or kind reaches a path or
a schema location only once it has the shape the API server requires of it (a group a DNS subdomain,
a version a DNS-1035 label, a kind a letter followed by letters and digits); a definition or an
object without that shape is refused, naming its file, and nothing is made of it. The shapes
(`scripts/lib/shapes.sh`, which `scripts/render` uses as well) are anchored at the true end of the
string, so a value that ends in a line break does not pass, and a control character fails them. A
definition for which no schema can be written is an error naming it, never one left out, and an
image that ends in a line break after its tag or digest is not pinned. Every record the
validation reads from a tool's output has each field cleaned of control characters, so no value
starts another field or record, and an index in it is checked to be a number before it is used.
`kubernetes-check` hands its builds on as records ended by a NUL byte, which no path or label holds,
into an empty directory it refuses otherwise.

## Every child Kustomization is in flux-system

`postBuild.substituteFrom` has no namespace field: Flux reads the ConfigMap and Secret from the
Kustomization's own namespace. `cluster-config` and `cluster-secrets` live in `flux-system`, so
every child Kustomization lives there too and sets `targetNamespace` for what it deploys.

## Pod Security

Pod Security admission is what stops a workload from asking for the host: a privileged container,
the host's network or process namespaces, a host path. Each namespace enforces one level, and a
level is declared in the tree, never left to the API server's default.

- **Where levels are declared.** `pod-security.kubernetes.io/enforce` on the namespace's
  `namespace.yaml`; every namespace an application targets, or an object of the render is in, has one.
  `flux-system` is the Flux Operator's: the FluxInstance's `kustomize.patches` set its label, as the
  Flux Operator's documentation describes for the namespace's Pod Security Standards, and Flux's
  security documentation states that the controllers are built for the restricted level.
  `cilium-secrets`, which the Cilium chart creates, is labelled by a post-renderer of its
  HelmRelease.
- **What a namespace enforces.** The strictest level its workloads pass. That is `restricted`,
  unless `pod-security-exceptions.yaml` at the repository root lists workloads in it that need
  more: the namespace then enforces the least strict level of its entries, and every other pod of
  it that the render holds passes `restricted` all the same. Each entry names the namespace, the
  workload (`Kind/name`), the level it needs, `baseline` or `privileged`, and the reason in a
  sentence. A pod an operator creates at run time, which the render does not hold, is listed with
  `created-by`, the custom resource in the render that makes the operator create it, never a
  workload the check evaluates itself; the check takes its level as written.
- **Audit and warn.** A namespace that enforces less than `restricted` sets
  `pod-security.kubernetes.io/audit` and `/warn` to `restricted`, with `audit-version` and
  `warn-version` at the cluster's Kubernetes minor, `versions.yaml`'s `kubernetes`; the check fails
  a namespace whose labels differ. Admission then records in the audit log, and returns as a
  warning, every pod there that fails `restricted`, those an operator creates included. Talos's
  default admission configuration, which the cluster keeps, exempts `kube-system` from Pod Security
  admission (`DefaultPodSecurityAdmissionControlConfig` in Talos'
  `pkg/machinery/config/types/k8s/admission_control.go` at the pinned tag): admission neither
  enforces nor records a level there, and the check is what holds the pods of the render there to
  the level its labels state.
- **The check.** `just pod-security-check` renders the tree as `just render-check` does, then
  `scripts/pod-security-check` evaluates every Pod, Deployment, StatefulSet, DaemonSet, ReplicaSet,
  ReplicationController, Job and CronJob in it, Helm hooks and tests included, against the
  `baseline` and `restricted` levels, and the controllers of the Flux install the FluxInstance
  configures in the same way. The check fails, naming the namespace and the workload, when a
  namespace an object of the render is in has no `enforce` label; when a workload fails the level
  its namespace enforces, with the checks it fails; when a workload fails `restricted` and is not
  listed with its reason, or is listed at a level other than the one it needs; when a namespace
  enforces a level other than the strictest its workloads pass; and when a namespace that enforces
  less than `restricted` does not audit and warn at `restricted` at the cluster's minor.
  `tests/pod-security.bats` proves each rule on a small render and runs the check on the tree.
- **The Flux install it evaluates.** The pinned Flux CLI's `flux install --export` for the
  components the FluxInstance names, with the instance's patches applied, each a patch and its
  target by their exact fields (any other key is refused, [Paths](#what-the-checks-refuse)): the
  controllers of the `flux2` release pinned in `mise.toml`. The operator installs the newest Flux
  2.x release in its manifests artifact ([Flux itself](#flux-itself)). Renovate moves the CLI pin
  and the artifact in separate pull requests, so once one has merged and until the other does, the
  check evaluates another Flux release than the one the cluster runs.
- **The evaluator.** Kyverno's `podSecurity` rule, pinned in `mise.toml` with the release's
  checksums, which runs Kyverno's fork of the Pod Security admission policy library at the 1.36
  check set, at the library's latest policy version. The rule is of Kyverno's legacy policy type,
  whose execution the 1.20 release removes from Kyverno's controllers, so the pin stays on the 1.19
  line. `mise.toml` records beside the pin the newest Kubernetes minor whose checks were compared
  with the evaluator's, and the check fails when `versions.yaml` names a newer one, so a pull
  request that moves the cluster to a new minor fails it. Whoever moves the minor compares that
  minor's checks in `k8s.io/pod-security-admission` with the evaluator's: when they are no
  stricter, the record moves to the new minor in the same pull request; when they are stricter,
  the minor waits for an evaluator that applies them. The same pull request reads
  `tests/fixtures/security-context-fields` again from that minor's `k8s.io/api`, as nothing fails
  while it is stale (`.renovate/by-hand.tsv`).
- **Pods the render does not hold.** An operator creates these at run time from a custom
  resource, and the check cannot evaluate them. Where the resource has the fields, it sets the
  security context `restricted` requires, and `tests/pod-security.bats` requires those fields in
  the render, under paths the resource's definition declares, so the API server keeps them:
  - `Grafana/grafana` in `monitoring`: the pod's non-root user and seccomp profile, in
    `spec.deployment.spec.template.spec.securityContext`; the Grafana operator runs its container
    with no privilege escalation and no capabilities itself.
  - `Prometheus/kube-prometheus-stack-prometheus` and
    `Alertmanager/kube-prometheus-stack-alertmanager` in `monitoring`: `spec.securityContext`, from
    the kube-prometheus-stack values; the Prometheus operator gives every container it creates no
    privilege escalation and no capabilities.
  - `LinstorCluster/linstorcluster` in `piraeus-datastore`: the LINSTOR controller, the CSI
    controller and the affinity controller, in the `podTemplate` of `spec.controller`,
    `spec.csiController` and `spec.affinityController`, each naming every container of the
    operator's template at its pinned version. Its satellites, CSI node plugin, NFS server and HA
    controller run privileged and are entries of the exceptions file, `created-by` it.
  - `EnvoyProxy/public` in `envoy-gateway-system`: the pod's non-root user and seccomp profile in
    `spec.provider.kubernetes.envoyDeployment.pod.securityContext`, and the proxy container's
    non-root user, seccomp profile, no privilege escalation and no capabilities in
    `envoyDeployment.container.securityContext`; the controller adds its shutdown manager container
    with the same hardened defaults. `tests/gateway.bats` requires these fields in the built
    `EnvoyProxy`, and this list's check of the paths cannot: the render holds no definition of
    `EnvoyProxy` to read them against, as `envoy-gateway-crds` applies Envoy Gateway's definitions
    from the chart through an inner `Kustomization`, outside the render
    ([The public Gateway](#the-public-gateway)).
  - The ReplicationSource `<app>` and ReplicationDestination `<app>-restore` of each application
    with a backed-up volume, `volsync-demo` in `demo` among them: the movers' non-root user and
    seccomp profile, in `spec.restic.moverSecurityContext`, from `components/volsync`; VolSync
    gives the mover's container no privilege escalation and no capabilities itself, as its
    documentation's permission model describes for movers without the privileged-movers
    annotation, which no namespace here carries ([Volume backups](#volume-backups)).
  - The ReplicationDestination `<app>-drill` of each application that takes the restore drill,
    `volsync-demo` in `demo`: the same mover security context in `spec.restic.moverSecurityContext`,
    from `components/volsync-drill` ([The restore drill](#the-restore-drill)).
  - `AWX/ascender` in `ascender`: the web and task pods and the migration Job its operator makes, by
    `spec.restricted_security_context` and the pod's non-root user and seccomp profile in
    `spec.security_context_settings`; the operator's restricted mode gives every container of them
    no privilege escalation and no capabilities. Ascender itself starts the job pods; the operator
    does not make them, so its restricted mode does not reach them. They are an entry of the
    exceptions file, `created-by` the `AWX` ([Ascender](#ascender)).

  Admission evaluates each such pod when the operator creates it: a namespace that enforces
  `restricted` refuses one that fails it, and one that enforces less records and reports it
  through its audit and warn labels.

An application's namespace is its `apps/base/<namespace>/namespace.yaml` with the label at the
level its workloads pass; a workload that needs more is a new entry in the exceptions file in the
same change, and the namespace's level and its audit and warn labels follow it. A chart value that
brings a workload to `restricted`, a seccomp profile or a container context, goes in the
application's values instead of an entry. The tests that hold an application's values keys to
those its chart's values define accept, under a `securityContext`, `podSecurityContext` or
`containerSecurityContext` map, any field of Kubernetes' security context types
(`tests/fixtures/security-context-fields`); an entry's reason says why no value does.

## Network policy

A namespace that holds applications denies ingress and egress by default and carries, beside its
applications, the few flows it lets through; a namespace that does not is listed with its reason and
what covers it instead. The decision is [ADR 0019](adr/0019-namespaces-deny-traffic-by-default-and-each-declares-its-flows.md).
The node firewall ([ADR 0017](adr/0017-nodes-firewall-themselves-with-talos-ingress-firewall.md))
is another layer: it decides what reaches a node's own listeners, policy decides what a pod takes
and sends.

- **The mechanism.** The default deny is a Kubernetes `NetworkPolicy` named `default-deny` in the
  namespace's directory, next to `namespace.yaml`, and the namespace's only `NetworkPolicy`: an
  empty pod selector, `Ingress` and `Egress` in its policy types, no rule. Every allow is a
  `CiliumNetworkPolicy` in the directory of the application that needs the flow, because it must
  name the API server, the nodes and "the world" without an address, which only Cilium's entities
  do, and must select backends by the labels of their namespaces. Every allow sets
  `enableDefaultDeny: {ingress: false, egress: false}` and holds no deny rule, so the default deny
  is that one object and nothing else.
- **How the pinned Cilium combines them.** A pod is in default deny for a direction once a policy
  rule that selects it for that direction asks for it, and then only what some rule allows passes
  (`Documentation/security/policy/intro.rst`, "Endpoint default policy"). A Kubernetes
  `NetworkPolicy` always asks for it (`pkg/k8s/network_policy.go`); a `CiliumNetworkPolicy` asks
  for it in each direction it has rules for, unless its `enableDefaultDeny` says `false` for the
  direction (`pkg/policy/api/rule.go`, `pkg/policy/utils/parserules.go`); one that asks is enough
  (`pkg/policy/repository.go`). With the namespace's default deny, its pods are in default deny both
  ways and the allows add what passes; without it, no rule asks, Cilium adds an allow of
  everything, and the allows change nothing. The agents read `enableDefaultDeny` only with
  `enable-non-default-deny-policies` on, which the chart's `enableNonDefaultDenyPolicies` sets by
  default and `tests/network-policy.bats` reads in the rendered agent configuration. The field does
  not reach layer-7 rules, which drop what they do not allow whatever it says; the tree has none.
- **Per namespace, enforcement mode `default`.** The default deny is a namespace's own object
  rather than one cluster-wide policy with an opt-out label: a mistake in the latter changes every
  namespace at once and silently, while a namespace that lacks its object is refused by the check.
  Cilium's `policyEnforcementMode` stays `default`, so a pod no policy asks to deny is open; mode
  `always` would deny every listed namespace's traffic too.

Whether the agents audit these policies or enforce them is Cilium's value `policyAuditMode`, which
holds for the whole cluster at once; the paragraph that states the mode is at the end of
[Service addresses](#service-addresses), and the policies land, are watched and are enforced in
the order of [Turning it on, and back](#turning-it-on-and-back). `tests/network-policy.bats` fails
unless `docs/kubernetes.md` states the mode exactly once, as that paragraph's opening sentence
while the value is set, or as **The cluster enforces the policies.** at the start of a paragraph
once it is not, and the agents' rendered configuration agrees.

| Namespace | Posture | Why, and what covers it instead |
| --- | --- | --- |
| `demo` | default deny | `hello` takes the proxies and Locust's workers on 8080; the backup movers, the restore drill's among them, resolve names and reach the object storage on 443; `volsync-demo`, the drill's check and the rest open nothing. |
| `envoy-gateway-system` | default deny | the controller, its webhook, its certificate job and the proxies, below; the proxies take the blackbox exporter's probes. |
| `kromgo` | default deny | kromgo takes the proxies and the kubelet's probes on 8080 and Prometheus' scrape on 8081, and reaches the resolver and Prometheus on 9090. |
| `sso-system` | default deny | dex takes the proxies and oauth2-proxy on 5556 and reaches the API server and GitHub on 443; oauth2-proxy takes the proxies on 4180 and reaches dex; below. |
| `backstage` | default deny | Backstage takes the proxies and the kubelet's probes on 7007 and reaches the resolver and its database on 5432; the database takes the operator, its own pods, Backstage, the dump job, Prometheus and the kubelet's probes, and reaches its own pods, the resolver and the API server, and its instances, for their Barman Cloud sidecars, the object storage on 443; the dump job reaches the resolver, the database and the world on 443. |
| `ascender` | default deny | the web pods take the proxies, the kubelet's probe and the task pods on 8052; the operator takes the kubelet's probes on 6789 and reaches the API server alone; every pod of Ascender's instance reaches the resolver and its database on 5432; the task pods reach the web pods, the API server and the world on 443 and 22; the job pods reach the resolver and the world on 443 and 22 and nothing else; the database, its instances and the dump job let through what Backstage's do. |
| `security-system` | default deny | Falco takes Prometheus' scrape and the kubelet's probes on 8765, and reaches the resolver alone; the flow recorder takes nothing and reaches the resolver and Hubble Relay on 4245. |
| `crowdsec` | default deny | the local API takes the agent on 8080, Prometheus on 6060 and the kubelet's probes, and sends nothing; the agent takes Prometheus and the kubelet on 6060 and reaches the resolver, the local API and the API server on 443 and 6443; below. |
| `open-feature-operator` | default deny | the OpenFeature Operator takes the kubelet's probes on 8081, Prometheus' scrape on 8080 and the API server's calls to its webhooks on 9443, and reaches the API server alone. |
| `locust` | default deny | Locust's master takes its workers on 5557 and the kubelet's probe on 8089 and sends nothing; the workers take nothing and reach the resolver, the master on 5557 and `hello`'s pods in `demo` on 8080. |
| `ai-system` | listed | applications whose allows are not written, not a namespace that cannot have the posture. n8n takes the proxies on 5678 and reaches its database, the resolver and whatever its workflows call outside; the PostgreSQL instances take n8n, each other and the operator, and reach the API server, and their Barman Cloud sidecars reach the object storage on 443 and the API server; the dump job reaches the database, the hosts age's release is downloaded from and the object storage; Open WebUI takes the proxies on 8080 and reaches nothing until an administrator turns on a connection that calls out; the backup movers reach the object storage on 443. The proxies reach n8n's 5678 and Open WebUI's 8080 alone there and forward only to their Services, PostgreSQL authenticates every client, Pod Security, node firewall. |
| `etcd-snapshots` | listed | an application whose allows are not written, not a namespace that cannot have the posture. The snapshot job takes nothing and reaches the Talos API through `talos.default`, the object storage, the hosts age's release is downloaded from (its URL redirects to a second host, which serves the file) and the resolver. Talos' own authorisation of its one role, Pod Security, node firewall. |
| `external-dns` | listed | an application whose allows are not written, not a namespace that cannot have the posture. external-dns takes Prometheus' scrape and the kubelet's probes on 7979 and nothing else, and reaches the API server, the DNS provider's API on 443 and the resolver. Its token, scoped to zone read and DNS edit on the cluster's one zone, its name filter, a ClusterRole that only reads, Pod Security, node firewall ([DNS records](#dns-records)). |
| `kube-system` | listed | Cilium's agent, its Envoy and its operator run in the host's network namespace; the resolver takes queries from every namespace; Hubble Relay takes the flow recorder of `security-system` on 4245; the pod-network workloads' other flows are not yet enumerated. Node firewall, the recorder's egress, which names Relay's pods on that port alone, Pod Security. |
| `flux-system` | listed | the controllers' flows are not yet enumerated as allows; Flux's own network policies, which the operator makes at run time, and the operator's for its web interface, `flux-operator-web`, which the check reads and passes because the namespace is listed ([What the check refuses](#what-the-check-refuses)); Pod Security, node firewall. |
| `monitoring` | listed | Prometheus scrapes every namespace and the nodes, the node exporter runs in the host's network namespace, the API server calls the operator's webhook, VictoriaLogs takes the proxies on 9428 for the route `logs`, Alertmanager reaches the resolver and, outside the cluster, each of its two destinations on the port of its URL, hosts that are deployment values and so are named by no policy ([Where alerts go](#where-alerts-go)), the blackbox exporter takes Prometheus on 9115 and reaches the resolver and the public Gateway's proxies on 10080 and 10443, the other flows are not yet enumerated. The proxies reach VictoriaLogs' 9428 alone there and forward only the route's reads, behind the cluster's sign-in, Pod Security, node firewall. |
| `openbao`, `external-secrets`, `cert-manager`, `cnpg-system`, `keda`, `volsync-system` | listed | flows not yet enumerated: webhooks and APIs the API server calls, the store's clients, scrapes, the PostgreSQL operator's calls to the Barman Cloud plugin. Each entry says which, and what covers it. |
| `piraeus-datastore` | listed | the CSI node plugin runs in the host's network namespace; the satellites replicate over the pod network, and their flows are not yet enumerated. |
| `cilium-secrets` | listed | holds no pod. |
| `kyverno`, `gatekeeper-system` | listed | flows not yet enumerated: the API server calls each policy engine's webhooks from the control planes' host network, the controllers reach the API server, Prometheus scrapes them ([Admission policy](#admission-policy)). Pod Security, node firewall. |

`network-policy-exceptions.yaml` is the list; its header says what an entry holds.

### What the namespaces let through

- **`envoy-gateway-system`.** The proxies (labels `app.kubernetes.io/name: envoy`,
  `app.kubernetes.io/component: proxy`, `app.kubernetes.io/managed-by: envoy-gateway`,
  `gateway.envoyproxy.io/owning-gateway-name: public`) take the world on 10080 and 10443, the
  container ports the controller derives from the listeners 80 and 443 by adding 10000, the blackbox
  exporter's pods on the same two ports, which are the only pods of the cluster they take there
  ([Probes](#probes)), and the kubelet on 19003 and 19002: Envoy Gateway v1.10.0 probes the envoy
  container on its readiness port, 19003 (`internal/xds/bootstrap/bootstrap.go`,
  `internal/infrastructure/kubernetes/proxy/resource.go`), and the shutdown manager on 19002
  (`internal/cmd/envoy/shutdown_manager.go`); 19001 is the stats port and 19000 the admin port on
  the loopback. They reach the resolver, the controller on 18000 (xDS) and 18002 (the Wasm modules
  of the [web application firewall](#web-application-firewall)), and each backend the routes
  attached to the Gateway send to, by one rule each: the pods its Service selects, in its namespace
  while that carries `k8s-gitops/gateway: public`, on the container port the route sends to and no
  other: `hello` in `demo` on 8080, kromgo in `kromgo` on 8080, n8n on 5678 and Open WebUI on 8080
  in `ai-system`, dex on 5556 and oauth2-proxy on 4180 in `sso-system`, Backstage in `backstage` on
  7007, Ascender's web pods in `ascender` on 8052, and VictoriaLogs in `monitoring`
  on 9428. oauth2-proxy's rule also carries the question the proxies ask it about each
  request of a route that opts in to sign-in ([Sign-in](#sign-in)), which is no route's
  backend but reaches the same pods and port. `tests/network-policy.bats` reads those
  ports from the render, from each route's backend through its Service's target port to the
  container port, and fails unless the rules name, in each labelled namespace, exactly them; it
  reads the proxies' egress in every form the evaluation reads, and fails on a port entry or a peer
  it cannot compare, a backend in a namespace without the label and a Service without a selector.
  What a pod of such a namespace takes is its own namespace's to say: in `demo`, `hello` on 8080; in
  `kromgo`, kromgo on 8080; in `sso-system`, dex on 5556 and oauth2-proxy on 4180; in `backstage`,
  Backstage on 7007; in `ascender`, the web pods on 8052. In `ai-system`, which is
  listed and so has no pod in default deny, every pod takes them on every port, so
  the proxies' rules are what keep them from n8n's other ports, from every port of
  its database and from Open WebUI's other ports; PostgreSQL also authenticates every
  client. So it is in `monitoring`, listed as well: the proxies' rule for VictoriaLogs is what keeps
  them off Prometheus, Grafana, Alertmanager, the collector and the store's other ports. The
  controller takes the proxies on 18000 and 18002 and the kubelet on 8081, and reaches the resolver
  and the API server on 443 and 6443 (a Service's address is translated to the control plane's
  before policy applies), and, in a policy of its own with its reason, `envoy-gateway-registry`, the
  world on 443 alone: the registry it fetches a Wasm module's image from, which redirects a blob
  request to another host. Its admission webhook takes the API server, the local host and other
  nodes' hosts on 9443, in a policy of its own with its reason (below). The certificate job reaches
  the resolver and the API server. No monitor of the tree scrapes the Gateway, so no scrape is
  allowed; a monitor that does adds its rule.
- **`demo`.** `hello` takes the proxies by their labels, not by their namespace, on 8080, so the
  controller is no path to it, Locust's workers by their labels in `locust` on the same port, so
  Locust's master is not admitted, and the kubelet's probe. The backup movers, the pods VolSync
  labels `app.kubernetes.io/created-by: volsync` for every application of the namespace that adds
  `components/volsync`, reach the resolver, and the world on 443 in a policy of its own with its
  reason, both by the application `demo-volsync-movers`, one for the namespace. A pod without a
  policy of its own reaches nothing and is reached by nothing. The movers' policies select by that
  label, so any pod of `demo` that carries it gets the movers' flows, the world on 443 among them:
  the label is no proof of being a mover. What keeps it to the movers is who makes pods in the
  namespace, Flux from the reviewed tree and VolSync's controller. The restore drill's mover is one
  of them; its check's pods carry labels of their own and reach nothing
  ([The restore drill](#the-restore-drill)).
- **`kromgo`.** kromgo's pods, by the labels its Service selects, take the proxies by their labels
  on 8080, the port the route sends to, the kubelet's probes on the same port, and Prometheus
  (`app.kubernetes.io/name: prometheus` in `monitoring`) on 8081, the metrics port the chart's
  monitor scrapes. They reach the resolver, and the pods the Service
  `kube-prometheus-stack-prometheus` selects, by its selector's labels in `monitoring`, on 9090,
  the container port that Service's port 9090 targets: `monitoring` is listed and takes them on
  every port, so kromgo's egress is what keeps them from Prometheus' other ports and the
  namespace's other pods. kromgo opens no other connection; it mounts no service account token.
- **`sso-system`.** dex takes the proxies by their labels on 5556, its issuer's port, oauth2-proxy
  on the same port, where it redeems a sign-in code and reads dex's keys, and the kubelet's probes
  on 5558; it reaches the resolver and the API server on 443 and 6443, where its storage keeps its
  objects, and, in a policy of its own with its reason (`dex-github`), the world on 443: GitHub's
  `github.com` and `api.github.com`, which a DNS name rule could name only with the layer-7 DNS
  rule this tree keeps out. oauth2-proxy takes the proxies by their labels on 4180, for its routes
  and for the external authorisation of each route that opts in, and the kubelet's probes there; it
  reaches the resolver and dex on 5556, and nothing outside the cluster. Neither takes the
  controller, another namespace's pods or the world, and no monitor scrapes them.
- **`backstage`.** Backstage's pod, by the labels its Service selects, takes the proxies by their
  labels on 7007, the port the route sends to, and the kubelet's probes on the same port; it reaches
  the resolver and the database's instances (`cnpg.io/cluster: backstage-db`,
  `cnpg.io/podRole: instance`) on 5432, every instance, as a failover moves the primary that
  `backstage-db-rw` selects. The database's pods, every pod the operator makes for the cluster, by
  `cnpg.io/cluster: backstage-db`, take the operator (`app.kubernetes.io/name: cloudnative-pg` in
  `cnpg-system`) on 8000 and 5432 and each other on every port, as the pinned operator's
  documentation asks (`docs/src/security.md`, Exposed Ports; `docs/src/networking.md`), and reach
  each other, the resolver and the API server on 443 and 6443; its instances take Backstage and the
  dump job on 5432, Prometheus on 9187, the port the PodMonitor names, and the kubelet's probes on
  8000, where the operator puts them (`pkg/specs/pods.go`). The instances also reach the world on
  443, in a policy of its own with its reason: the object storage, whose endpoint is a URL, as for
  the movers below, where the Barman Cloud plugin's sidecar in each instance's pod archives the WAL
  and writes the base backups ([Backups and restores](#backups-and-restores)). The sidecar reaches
  the API server as the instance manager does, and talks to the instance manager over a socket in
  the pod, which policy does not see; a policy selects pods, not containers, so PostgreSQL's
  container shares the rule, and the jobs that create and join an instance, which hold no sidecar,
  are not selected. The operator's own calls to the plugin stay inside `cnpg-system`. The dump
  job's pods, by the labels
  `app.kubernetes.io/name: pgdump` and `app.kubernetes.io/instance: backstage-db` that
  `app/kustomization.yaml` gives the component's CronJob, reach the resolver, the instances on
  5432, and the world on 443 in a policy of its own with its reason: the age release, whose URL
  redirects to a second host, and the object storage, whose endpoint is a URL, as for the movers
  below ([Dumps](#dumps)). The pods the operator makes carry the labels of its source, which no
  render holds; the job pods it makes to create and join an instance carry `cnpg.io/cluster` too.
- **`ascender`.** The pods of Ascender's instance are its operator's, made at run time, and the
  policies name them by the labels the operator's templates give them at the release recorded beside
  them. The web pods, by the labels of their Deployment's selector, take the proxies by their
  labels, the kubelet's readiness probe and the task pods' websocket relay on 8052. Every pod of the
  instance, by `app.kubernetes.io/part-of: ascender` with the operator's `managed-by` and
  `component`, the migration Job's included, reaches the resolver and the database's instances on
  5432. The task pods reach the web pods on 8052, the API server on 443 and 6443, and the world on
  443 and on 22 in a policy of its own each, with its reason: the project updates that run in their
  execution environment. The job pods, by `ansible_job`, reach the resolver and the world on 443 and
  on 22, each in a policy of its own with its reason, and nothing in the cluster, and take nothing.
  The operator's pod takes the kubelet's probes on 6789 and reaches the API server alone. The
  database, its instances and the dump job are Backstage's, for `ascender-db`, the instances taking
  every pod of the instance and the dump job on 5432. [Ascender](#ascender) says what each is for.
- **`security-system`.** Falco's pods, by the labels of the DaemonSet's selector, take Prometheus
  (`app.kubernetes.io/name: prometheus` in `monitoring`) on 8765, the metrics port the chart's
  monitor scrapes, and the kubelet's probes on the same port. They reach the resolver alone, for
  the API server's name, which the image's rule `Contact K8S API Server From Container` compares a
  container's connections with: Falco reads the container runtime's socket and the node's files
  through host paths, which no pod policy sees, writes its events to standard output, and calls no
  API ([Runtime detection](#runtime-detection)). The flow recorder's pods, by the label of its
  Deployment's selector, take nothing, as the process listens on no port and nothing probes it.
  They reach the resolver, for the name of Relay's Service, and the pods the Service `hubble-relay`
  selects, by its selector's label in `kube-system`, on 4245, the container port that Service's
  port 80 targets: `kube-system` is listed and takes them on every port, so the recorder's egress
  is what keeps them from Relay's other ports and from the namespace's other pods
  ([The record of what policy drops](#the-record-of-what-policy-drops)).
- **`crowdsec`.** The local API's pods, by the labels its Service selects, take the agent's pod on
  8080, Prometheus (`app.kubernetes.io/name: prometheus` in `monitoring`) on the metrics port 6060
  and the kubelet's probes on 8080, and send nothing. The agent's pod takes Prometheus and the
  kubelet on 6060 and reaches the resolver, the local API's pods on 8080 and the API server on 443
  and 6443, and nothing else: the one name it looks up is the local API's Service, and it calls no
  name outside the cluster, so it has no DNS name rule and no rule that reads its queries. It
  reaches the proxies' logs through the API server, so no flow to the proxies' namespace exists.
  `tests/crowdsec.bats` reads every rule of the two policies and evaluates the flows on the ports
  the chart renders. [CrowdSec](#crowdsec) says what each is for.
- **`open-feature-operator`.** The operator's pod, by the labels of its Deployment's selector,
  takes the kubelet's probes on 8081, the manager's health port, and Prometheus
  (`app.kubernetes.io/name: prometheus` in `monitoring`) on 8080, the container port its PodMonitor
  names. Its admission webhooks take the API server, the local host and other nodes' hosts on 9443,
  the port its webhook Service targets, in a policy of its own with its reason (below). It reaches
  the API server on 443 and 6443 and nothing else: it looks no name up, so not even the resolver,
  and it calls nothing outside the cluster ([OpenFeature Operator](#openfeature-operator)). A
  workload that opts in to it declares two flows of its own in its namespace, the kubelet's probes
  of the sidecar on 8014 and the sidecar to the API server, as the example `hello-flags` does.
- **`locust`.** Locust's master, by the labels of its Deployment's selector
  (`app.kubernetes.io/name: locust`, `app.kubernetes.io/component: master`), takes the workers by
  their labels (`app.kubernetes.io/component: worker`) in `locust` on 5557, the port it binds for
  them, and the node it runs on on 8089, the web port, for the kubelet's readiness probe, which
  admits every process in that node's network namespace, the node's pods of the host's network
  among them; it sends nothing, as it runs no users and the one name it looks up, its own, is in the
  pod's hosts file. The workers take nothing, as they listen on nothing, and reach the resolver,
  the master's pods on 5557 and the pods the Service `hello` selects in `demo` on 8080, the
  container port its port 80 targets: the target that `LOCUST_TARGET` names, which admits them by a
  rule beside it. Once the cluster enforces the policies, whatever host Locust's interface is
  given, the workers reach nothing else, not the world, the API server, the Gateway's proxies or
  another application; while it audits them, a flow they would drop is reported and passes
  ([Service addresses](#service-addresses)), and the load goes wherever the host given points.
  `just locust` reaches the interface through a port forward, which the container runtime
  connects inside the pod on its loopback, where no policy applies ([Locust](#locust)).
- **The object storage's port.** cluster-config holds the object storage's endpoint as a URL, which
  a DNS name rule cannot take, so the movers' rule is the world on 443: the port https uses for an
  endpoint that names none, as cluster-config's example does and `tests/network-policy.bats` holds
  it to. The endpoint's validation (`scripts/lib/s3.sh`) admits a port: with an endpoint on
  another port, the rule refuses the movers, every backup and restore of the namespace fails to
  connect, and `just network-drops` shows the movers' flows to `@world` on that port. The rule's
  port changes with the endpoint. The rules of `backstage`'s dump job and of its database's
  instances are on that port for the same endpoint, and change with it too.
- **Which entity.** Public traffic is translated by the edge routers, arrives at the address the
  workers announce, and a worker may forward it to a proxy on another node
  (`externalTrafficPolicy: Cluster`, [The public Gateway](#the-public-gateway)). A proxy on the
  node that took the connection sees a client outside the cluster, `world`; one on another node
  gets it through the tunnel with the world's identity, which the pinned datapath sets for a
  load-balanced connection from outside so that the receiving node does not take it for a node's
  (`bpf/lib/nodeport.h`, `nodeport_lb4` and the NAT that follows it). The listeners therefore take
  `world` alone from outside, and the watch in audit mode confirms it: a flow from `@remote-node` to
  the listeners would show as `AUDIT`. A pod that asks the proxies' Service by its cluster name, as
  the blackbox exporter's probes do, is no `world`: the agents translate the Service's cluster
  address to a proxy's before policy applies, as for every Service, and the source stays the pod, so
  the proxies take the exporter's pods by their labels in a rule of their own. Nothing else in the
  cluster reaches the listeners; a pod that resolved a public hostname to the edges' addresses would
  leave the cluster and come back translated, as `world`.
- **The local host and the API server.** In Kubernetes mode the pinned agent lets the local host
  reach the pods on its node whatever the policies say (`allow-localhost` `auto` becomes `always`,
  `daemon/cmd/daemon.go`; `pkg/policy/repository.go` adds the rule), so the kubelet's probes do not
  depend on the rules from `host`. Those rules state each probe port, so that the offline evaluation
  proves it, and are what would admit the probes if the agents ever required a rule for the local
  host. The API server calls webhooks from the control planes' host network: a call from another
  node crosses the tunnel as `remote-node` (`bpf/bpf_overlay.c`), which Cilium names
  `kube-apiserver` only for an address it knows as the API server's, so the webhook's rule names
  both, on its port alone, with its reason.

### Declaring an application's flows

1. Put a `CiliumNetworkPolicy` in the application's `app/` directory, list it in its
   `kustomization.yaml` and name `cilium` in the application's `dependsOn`: the kind is the one
   Cilium's operator defines. Its `endpointSelector` is the application's pod labels, and it sets
   `enableDefaultDeny: {ingress: false, egress: false}`: the namespace's default deny does the
   denying. A Kubernetes `NetworkPolicy` is no allow, as it always asks for the default deny.
2. For each flow, one rule with a comment saying what it is for. Peers are named by entity
   (`kube-apiserver`, `host`, `world`), by labels (`k8s:io.kubernetes.pod.namespace` and the pod's
   labels) or by DNS name, never by address; ports are listed. An entity is written as an entity,
   never as a `reserved:` label, and a selector that names a namespace or its labels requires one,
   by `matchLabels`, `In` or `Exists`. No rule denies: the namespace's default deny does. Ingress
   from the Gateway names the proxies' labels, the application's namespace carries
   `k8s-gitops/gateway: public`, and the proxies' egress names the port
   ([Giving an application a public hostname](#giving-an-application-a-public-hostname)). DNS is a
   rule to `k8s:k8s-app: kube-dns` in `kube-system` on port 53, UDP and TCP; a DNS name rule
   (`toFQDNs`) also needs that rule to let Cilium read the queries,
   `rules: {dns: [{matchPattern: "*"}]}` (`Documentation/security/dns.rst`). The kubelet's
   probes are a rule from `host` on each probe port; a scrape is a rule from
   `app.kubernetes.io/name: prometheus` in `monitoring`, once a monitor scrapes the application.
3. A rule that allows every peer, an empty selector, every pod of every namespace, the cluster,
   every endpoint, the unmanaged endpoints, other nodes' hosts, the world other than into a
   Gateway's proxies on its listener ports, or a name pattern of `*`, is the one rule of a policy
   of its own that carries the annotation `k8s-gitops/network-policy-reason` with the reason, and
   names its ports, each a number of one port: a reason excuses the one rule of its policy on the
   ports it names.
4. A new namespace has a `default-deny` `NetworkPolicy` beside its `namespace.yaml`, or an entry
   in `network-policy-exceptions.yaml`. A listed namespace whose applications already run takes the
   default deny in the order [Turning it on, and back](#turning-it-on-and-back) gives.
5. A namespace whose applications add `components/volsync` has the policies of its movers, once:
   copy `apps/base/demo/demo-volsync-movers/` under the namespace's directory and list its
   `ks.yaml` in the overlay.

### What the check refuses

`just network-policy-check` renders the tree as `just render-check` does, charts pulled from their
registries, and reads `scripts/network-policy-check` over it; it is a check of the `static` group,
and `tests/network-policy.bats` proves it on fixture trees and on the tree. It fails, naming the
namespace and the policy, when

- a namespace the render holds an object in, or an application targets, has neither a default deny
  of both directions that selects every pod, the `NetworkPolicy` `default-deny`, nor an entry in the
  list;
- an entry's namespace has the default deny or holds no object of the render, is listed twice, has
  no reason or no `covered-by`, or has a field the check does not read;
- in a namespace that has the default deny, or cluster-wide, a policy would deny by itself: a
  `NetworkPolicy` other than the default deny, a second deny of the namespace under another name
  among them, or a Cilium policy that does not set `enableDefaultDeny` to `false` for both
  directions;
- in the same places, a rule allows every peer, an empty peer, every pod of every namespace (a
  selector that names only the namespace, by `Exists` or `NotIn`, or an empty or such namespace
  selector of a `NetworkPolicy`), the whole cluster (`cluster`, `cluster-mesh`), every endpoint
  (`all`), the unmanaged endpoints (`unmanaged`), other nodes' hosts in, the world in other than to
  the proxies of a Gateway of the namespace on its listener ports (the proxies by the labels Envoy
  Gateway gives them, the ports as it derives them from the Gateway's listeners), egress to the
  world, the host or other nodes, or every DNS name, and is not the one rule of a policy that
  carries the reason annotation; or a policy carries a reason and more than one rule, or a rule
  that names no port or a range;
- any policy names an address: a CIDR, an address block, a literal in a selector;
- any Cilium policy, wherever it is, listed namespaces included, holds what the evaluator below
  does not read: a deny rule (`ingressDeny`, `egressDeny`), which drops what it names whatever the
  allows say; a policy of the nodes (`nodeSelector`); an entity written as a label of an endpoint
  selector (`reserved:world`); or an endpoint selector that names the namespace or its labels
  without requiring one (`DoesNotExist`, or `NotIn` alone), to which Cilium adds no namespace of its
  own (`pkg/k8s/apis/cilium.io/utils/utils.go`), so that it also selects the world, the hosts and
  the nodes. A reason excuses none of these.

The check reads only what the render holds. Besides the policies of `ascender`, `backstage`,
`crowdsec`, `demo`, `envoy-gateway-system`, `kromgo`, `locust`, `open-feature-operator`,
`security-system` and `sso-system`, that is one policy of a listed namespace: `flux-operator-web`,
the `NetworkPolicy` the Flux Operator's chart renders in `flux-system`, which lets every pod of
every namespace (an empty `namespaceSelector`) reach the operator's web interface on 9080. It passes
because `flux-system` is listed; the day `flux-system` takes the default deny, the check refuses it,
as a `NetworkPolicy` other than the default deny and as an allow of every pod of every namespace.
The `NetworkPolicy` objects the operator makes for the Flux instance, which its
`spec.cluster.networkPolicy` turns on, are made at run time, so no render holds them and the check
never sees them.

`scripts/network-policy-check --reach RENDER FROM TO PORT/PROTOCOL` evaluates the policies of a
render for one flow and answers `allowed` or `denied`; the egress of the source and the ingress of
the destination both have to allow it, and a pod is in default deny for a direction only when a
policy that selects it asks for it, as Cilium decides. Over a render that holds what the check
refuses wherever it is, it gives no answer and exits 2. The tests use it to follow the public path
hop by hop (the world to the proxies' listener ports, the proxies to `hello`'s port, to kromgo's, to
n8n's, to Open WebUI's, to dex's and oauth2-proxy's, to Backstage's and to Ascender's
web pods' but not to kromgo's metrics port, n8n's, Open WebUI's or Ascender's other
ports, Ascender's task and job pods or any database, the kubelet to every probe port,
Prometheus to kromgo's metrics port alone), to show that the blackbox exporter, the prober the
Probes name, reaches the proxies on the listener port each Probe's target asks for, read from the
render, and that no other pod of the render or of the operators is taken there, to show that no pod
of `demo`, `kromgo` or `backstage` reaches the secret store, the storage controller, another pod of
`demo` or another application, n8n and Open WebUI among them, that Backstage reaches the resolver
and its database's port and nothing outside the cluster, that the database takes the operator, its
own pods, Backstage, the dump job and Prometheus on their ports and no other application, that its
instances reach the world on the object storage's port and on no other, and a job that joins an
instance on none, that kromgo reaches the resolver and the port of the Prometheus its configuration
names, read from the render, and nothing else, and no other application reaches it, that Falco's
pods take Prometheus and the kubelet on its metrics port alone and reach the resolver alone, that
the OpenFeature Operator's pod takes Prometheus on its metrics port and the API server, the local
host and other nodes' hosts on its webhooks' port, neither of them the world, another application or
the other port's caller, and reaches the API server alone, that the proxies reach the controller on
the port it serves the firewall's Wasm modules on and no other application's pod or anything outside
the cluster does, that the controller reaches the world on 443 and on no other port and neither the
certificate job nor the proxies reach it, that the flow recorder takes nothing and reaches the
resolver and Hubble Relay's pods on Relay's container port alone, and that with their default deny
`backstage`, `demo`, `envoy-gateway-system`, `kromgo`, `open-feature-operator`, `security-system`
and `sso-system` let exactly their flows through and without it take and send everything. What it
cannot show: the entity the pinned datapath gives a connection an edge translated and a worker
forwarded again, read from its source above and confirmed in audit mode; the labels of the pods the
operators create at run time, taken from the operators' source and observed in audit mode; that an
address a name resolves to is the one a rule meant; and anything about pods in the host's network
namespace.

### What policy does not cover

Pods in the host's network namespace (Cilium's agent, its Envoy and its operator, the storage's
CSI node plugin, the node exporter) are not selected by a pod policy; the node firewall is their
layer. The nodes' own listeners are the node firewall's
([ADR 0017](adr/0017-nodes-firewall-themselves-with-talos-ingress-firewall.md)). The listed
namespaces take and send what they did before. Policy is connection-level: no layer 7 rule, no
mutual authentication, no encryption.

### The record of what policy drops

What a policy dropped, or would have dropped while the cluster audits, stays in an agent's Hubble
only while its buffer of recent flows holds it: 4095 flows of every verdict by the chart's default,
gone within minutes to hours. The decision to enforce rests on a day of it, the night's jobs
included, so the cluster keeps a record: `apps/base/security-system/network-audit/` runs a flow
recorder, and the log store keeps what it writes for as long as it keeps logs. A cluster selects it
with one entry of its overlay, `security-system/network-audit/ks.yaml`, beside the namespace
directory `security-system`, which Falco's entries hold as well; without the entry nothing of it
builds.

- **What runs.** A Deployment `network-audit` of one pod with one container, `hubble`: the Hubble
  CLI, `hubble observe --follow` for the verdicts `DROPPED` and `AUDIT`, against the Service
  `hubble-relay.kube-system.svc:80` of Hubble Relay, which the Cilium release runs and whose server
  takes no TLS. `DROPPED` is a packet an agent dropped, for a policy or for any other reason, and
  `AUDIT` a connection a policy would have dropped while the agents audit. Relay passes the request
  on to every node's agent as it is, each agent sends the flows of those two verdicts from the
  moment it is asked, and Relay merges them by their time into the one stream the CLI prints
  (`pkg/hubble/relay/observer/server.go` and `observer.go`, `pkg/hubble/observer/local_observer.go`
  at the pinned release); Relay also asks the agents that join its peers while the stream runs. One
  replica, which goes before the next starts (`Recreate`), as two would write every flow twice. The
  application names `cilium` in `dependsOn`, as its network policy is of a kind Cilium's operator
  defines and Relay is part of that release, and it waits: the Deployment counts its pod available
  once it has been running for 30 seconds (`minReadySeconds`), so a recorder that cannot reach
  Relay, whose process then ends, keeps the Kustomization from being Ready. Hubble's exporter and
  its metrics are the other ways to the same flows, and neither is used: the exporter writes them to
  a file of the agent's or to the agent's standard output, and the metrics are served on another
  port of every node, which the node firewall does not admit. Both are settings of the agents, and
  changing them restarts every agent; the agents' own drop counter carries a reason and a direction
  and no workload (`Documentation/observability/hubble/configuration/export.rst`,
  `Documentation/observability/metrics.rst`). The recorder is a client of what already runs: no
  setting of a node, an agent or the collector changes for it.
- **Its privileges.** A connection, and nothing else. The pod passes the `restricted` Pod Security
  level, in a namespace that enforces `privileged` for Falco: a non-root user and group, the
  runtime's seccomp profile, no privilege escalation, no capability and a read-only root
  filesystem. It declares no volume and mounts no service account token, as Relay asks a client for
  no credential, and it has no port, no Service and no probe, as the process listens on nothing.
  `just pod-security-check` holds it to `restricted`, and `pod-security-exceptions.yaml` has no
  entry for it. Its network policy lets it reach the resolver and Relay's pods on 4245, and lets
  nothing reach it ([What the namespaces let through](#what-the-namespaces-let-through)).
- **Its keepalive.** The pod sets three sysctls of its own network namespace, the TCP keepalive's
  time, interval and probes, at 60 seconds, 10 seconds and 3: the kubelet counts them as safe, and
  the `baseline` level, and so `restricted`, admits them from Kubernetes 1.29 on
  (`pkg/kubelet/sysctl/safe_sysctls.go` and
  `staging/src/k8s.io/pod-security-admission/policy/check_sysctls.go` at Kubernetes v1.37.1). The
  CLI's one connection carries nothing while nothing is dropped, and the CLI sets no timer on it;
  its gRPC library turns the kernel's keepalive on with the kernel's settings
  (`vendor/google.golang.org/grpc/internal/tcp_keepalive_unix.go` at the pinned release), by
  default two hours of silence and then nine probes 75 seconds apart. A Relay that went without
  closing the connection, as when its node loses power, would leave the recorder waiting that long
  and recording nothing. With the pod's settings the kernel ends a connection that has been silent
  for a minute and then left three probes unanswered, 90 seconds after the silence began, and the
  process ends with it.
- **The image** is the one the Cilium agents run, `quay.io/cilium/cilium`, pinned by tag and digest
  under a `# renovate:` comment. It carries, as `/usr/bin/hubble`, the Hubble CLI of the release the
  agents and Relay are of (`images/cilium/Dockerfile`, and `SUBDIRS_CILIUM_CONTAINER` in the
  `Makefile`), and every node holds the image already. The CLI's own image, `quay.io/cilium/hubble`,
  has no tag of that release; the newest release tag its registry lists is v1.16.4.
  `tests/network-audit.bats` fails, saying what to set, unless the pin is the image the rendered
  chart gives the agents, tag and digest, and, saying to print its fixture's flow lines again with
  the new CLI and replace the fixture, while the tag is not the release whose CLI printed them,
  which the test's header records as `hubble-flow-lines`. Renovate moves the chart and the image in
  one pull request, the group Cilium of `.renovate/groups.json5`, and never merges it by itself
  (`.renovate/automerge.json5`). The image sets `HUBBLE_SERVER` to an agent's own socket, and the
  `--server` flag overrides it.
- **What a line holds.** One JSON object for each flow, on standard output, written as the flow
  arrives: under `flow`, its `time`, `uuid`, `verdict`, `drop_reason_desc` when it was dropped,
  `traffic_direction`, `l4`, the protocol with its ports, `node_name`, the node that reported it,
  and for `source` and for `destination` the `namespace`, `pod_name`, `workloads` and `labels`;
  beside `flow`, the record's own `node_name` and `time`, which the agent fills from the flow's,
  and Relay orders the records by that time. A field without a value is left out. These are the
  fields the CLI asks for with `--field-mask`, and an agent sends no other
  (`pkg/hubble/observer/local_observer.go`): none of the fields of a flow's addresses, `IP`,
  `ethernet` and `tunnel`, and none of the names an address resolves to, `source_names` and
  `destination_names`. `tests/network-audit.bats` holds the mask to that set. What can still hold
  an address is a label, where a policy of the cluster names a prefix (`cidr:`), which none of the
  tree's does; the group address of an IGMP message, in `l4`; and the lines that are not flows,
  below.
- **How an end of a flow is named.** A pod's workload is what the pinned Cilium derives from the
  pod's controlling owner (`pkg/k8s/utils/workload.go`): the Deployment, for a pod of a ReplicaSet
  named after the pod's template hash; the CronJob, for a pod of a Job whose name ends in the eight
  to ten digits of its scheduled time; otherwise the owner's own kind and name. A pod whose name was
  not generated, or that has no controlling owner, has none. An agent knows the workload only of the
  pods on its own node (`pkg/hubble/parser/common/endpoint.go`), so of a flow's two ends the one on
  the node that reported it carries its workload, and the other, when it is a pod of another node,
  only its pod's name. For a policy's verdict the reporting node is the one that decides: the
  source's for egress, the destination's for ingress.
- **The lines that are not flows.** The pod writes other lines too, and they say where the record
  has gaps: a `lost_events` record, on standard output, when Hubble lost events before it could
  send them, with how many, of every verdict and not only the two asked for, and where, the
  kernel's event buffer, Hubble's queue or an agent's buffer of recent flows; a `node_status`
  record, on standard error, for a node Relay could not read, with the error; and the CLI's own
  messages, plain lines on standard error: a warning, such as the one it writes when its minor
  version is lower than Relay's, as it can be during a minor upgrade of Cilium until the recorder
  has moved too (a patch number is not compared), and the error it ends on
  (`hubble/pkg/printer/printer.go`, `hubble/main.go`, `hubble/cmd/root.go`,
  `hubble/cmd/common/conn/version.go`). An error can name an address, a node's or the resolver's.
- **Where the lines go.** The log collector ships every pod's lines ([Logs](#logs)), so they are in
  the store with the namespace, pod, container and node of the recorder, each line whole in `_msg`.
  `{kubernetes.pod_namespace="security-system",kubernetes.container_name="hubble"}` selects them:
  `just logs` with that and `| unpack_json | filter flow.verdict:AUDIT` prints the audited flows as
  they were written, labels included. The store keeps them 14 days, as it keeps every log, and
  drops the oldest days before that once they take 15 GiB, though never the last two
  ([Logs](#logs)); `tests/network-audit.bats` holds both numbers to the store's values.
- **What bounds the volume.** Only the two verdicts are sent, and a flow's line is some hundreds of
  bytes, 670 on average in a local run of the image over hand-written flows. A line is an event an
  agent reported, not a connection: an `AUDIT` line is written once for a connection, when its
  first packet is judged, and none for the packets of an established one, while a packet a policy
  denies once the cluster enforces is two `DROPPED` lines, the policy's verdict and the drop
  itself, for each packet, a sender's retries included (`bpf/bpf_lxc.c`, "Emit verdict if drop or
  if allow for CT_NEW", and the drop notification of `tail_handle_ipv4_cont`). Nothing limits the
  rate beyond that: a flood of denied packets is a flood of lines, up to what Hubble passes on
  before it reports lost events instead, and the lines share the store's 15 GiB with every other
  log, so a flood shortens how far back all of them reach.
- **What the record misses.** The time the recorder is not following: it asks for nothing older
  than the moment it connects, and nothing is fetched afterwards. Its process ends when Relay or
  the connection goes, and when Relay ends the stream, as it does once it reads no agent; the
  kubelet starts it again after its back-off, and the recipe reports that start; a Cilium upgrade
  replaces Relay's pod and the recorder's, whose image moves with it, and so makes such a start.
  The two move in either order: `dependsOn` holds the recorder back only while `cilium` is not
  Ready and compares no revision, as each application reads an artifact of its own
  (kustomize-controller's `checkDependencies`). An eviction by the descheduler
  ([The kube-system baseline](#the-kube-system-baseline)) makes such a start too: every five
  minutes it moves pods off a node it finds above its target use, and it may take the recorder's
  pod, as that claims no volume, or Relay's, which claims none either and whose end ends the
  recorder's stream. Each leaves a gap until the new pod's container runs, and evictions that
  recur keep a 24-hour window from passing. The loss of the recorder's node stops the record until
  its pod has been replaced on another, some six minutes at the defaults, which the recipe shows
  only once the old pod is deleted (below). Events Hubble lost and the nodes Relay could not read,
  which the lines above name. An agent's restart, which every change of `cilium-config` and every
  upgrade brings, at most two agents at a time, makes its node one of those: the agent's server
  ends the node's stream with an error, which Relay writes as a `node_status` line and answers by
  asking the node again at its next look at its peers, every 2 seconds, once its connection to the
  node is back; the new agent sends its flows from then on, so the record lacks that node's from
  the old agent's stop until shortly after the new one serves, and the recorder's pod need not be
  deleted (`pkg/hubble/server/server.go`, `pkg/hubble/relay/observer/server.go`,
  `pkg/hubble/relay/defaults/defaults.go`). Lines the collector could not ship before the kubelet
  rotated the pod's log away, as for any pod ([Logs](#logs)). And what Relay itself does not see,
  which no line names at once (`pkg/hubble/relay/observer/observer.go`, `retrieveFlowsFromPeer`,
  and `pkg/hubble/relay/pool/manager.go`): Relay counts a node's stream that ends cancelled as
  finished and does not ask that node again while the follow runs, and it cancels a node's stream
  itself when the node leaves its peers or changes its address; and a node that went without
  closing its connection, as on a power loss, is asked again only once Relay's connection to it
  has failed, which without traffic on it takes the kernel's keepalive, a little over two hours at
  the defaults Relay's pod runs with, and then a `node_status` line says so. A new follow asks
  every node Relay reaches, so after a node rejoined under the same name, changed its address or
  lost power, deleting the recorder's pod starts one, and the record is whole from then on.
- **Reading it.** `just network-audit [since] [cluster]` prints the record of a window that ends
  now, 24 hours unless told otherwise (`since` is a whole number with `s`, `m`, `h`, `d` or `w`,
  as `just logs --since` takes it), through the same path as `just logs`, the Kubernetes API's
  service proxy to the store. The store does the counting: one query unpacks each of the
  recorder's lines and counts them by verdict, direction, drop reason, port and the namespace, pod
  name, workloads and labels of each end, so the answer's limit, 10000, bounds groups and never
  flows. The recipe prints one line a group, with no header, the most frequent first:
  `COUNT VERDICT NAMESPACE DIRECTION SOURCE DESTINATION PORT/PROTOCOL REASON`. `COUNT` is the
  number of the recorder's lines, events and not connections, as above; `DIRECTION` is `ingress`,
  `egress` or `-`; `NAMESPACE` is the namespace whose policies decided the flow, the source's for
  egress and the destination's for ingress, and `-` for a flow without a direction; `SOURCE` and
  `DESTINATION` are `NAMESPACE/KIND/NAME` of the end's workload, so that a night's job pods and a
  rollout's pods are one line, `NAMESPACE/POD` for a pod the line gives no workload, and `@world`,
  `@host`, `@remote-node` and the like for an end that is no pod; `PORT/PROTOCOL` is the
  destination port over `tcp`, `udp` or `sctp`, and `0/other` for anything else; `REASON` is the
  drop reason of a `DROPPED` flow and `-` for `AUDIT`. Groups that differ only in a pod's name
  under its workload, or in a label, are one line with their sum. It prints no label and no
  address, and of a name only its printable ASCII, so nothing in a line can drive a terminal. With
  no flow it says `no dropped or audited flow in the record of the last <since>`. It reads the
  answer in the shape the store's version writes it, the version whose answers
  `tests/network-audit.bats` holds; were a later version to flatten a line's JSON into other field
  names, every flow would count among the lines that are not flows and the table would be empty:
  an empty table beside a large count of those lines is that. So the test fails, saying to put the
  recipe's query to the new version and replace its answers, while the store's image or its
  chart's `appVersion` is of another release than the one the test's header records as
  `victoria-logs-answers`; `.renovate/by-hand.tsv` lists this record and `hubble-flow-lines`.
- **What the recipe says of the record.** After the table, on standard error: how many of the
  recorder's lines in the window are not flows, with the `just logs` query that shows them, which
  fails nothing; and, from one listing of the recorder's pod, whether it ran through the window. A
  recorder that has run since before the window began is said so, and the run exits 0. One that is
  not running, or whose container started inside the window, is named with its state or its start
  time, and the run exits 1 after the table, as flows from the time it was not following are not
  in the record; so does a run that cannot list the pod, or whose listing holds no state it reads,
  and it shows nothing kubectl printed. The listing is what the API holds: when the recorder's node
  is lost, its pod is listed as running from its old start until the node has been marked not
  Ready, 50 seconds after its kubelet last renewed its lease by default, and the pod's toleration
  of that, 300 seconds by the API server's `DefaultTolerationSeconds` admission plugin, has run
  out, and the pod is deleted and replaced; a run in those six minutes exits 0 over a window the
  recorder did not follow to its end, and a run after them names the new pod's state or start. An
  answer of 10000 groups is cut: the run says so and exits 1. A `since` that is no duration exits 2
  with the usage before anything is called, and a store or an API that refuses or does not answer
  fails with `just logs`' own message and nothing else. The kubeconfig needs what `just logs` needs
  and to list the pods of `security-system`.
- **The answers the tests hold.** `tests/network-audit.bats` runs the recipe over the store's own
  answer to its query, `tests/fixtures/network-audit/answer.jsonl`, and the inputs the answer was
  made from are beside it: `tests/fixtures/network-audit/flows.jsonl`, 15 flows written as an
  agent sends them under the recorder's mask, one of them `FORWARDED`;
  `tests/fixtures/network-audit/records.jsonl`, two `lost_events` records and three `node_status`
  records; `tests/fixtures/network-audit/bulk.ndjson`, the body of the bulk request the collector
  would send for the lines, each whole in `message` beside the namespace, pod, container and node
  of its pod; and `tests/fixtures/network-audit/bulk.args`, that request's query arguments, the
  collector's sink's. The test's header records the releases of the store and of the CLI they came
  from, and the test fails while the store or the recorder runs another, saying to do the proof
  again, offline, in these steps. The recorder's image, with no network, a read-only root, user
  65532 and no capability, runs the recorder's command with `--input-file -`: over `flows.jsonl`
  it prints a line for each flow but the `FORWARDED` one; over `records.jsonl`, without the two
  `--verdict` flags, which it applies to every record of a file, it prints the `lost_events`
  records on standard output, the `node_status` records of a node's error and of a node Relay could
  not reach on standard error, and nothing for the nodes that connected; and without
  `--input-file` it ends on its error for a Relay it cannot look up, whose resolver address is put
  in a documentation range. Those lines, in that order, are the messages of the recorder's documents
  in `bulk.ndjson`, which also holds a line of Falco's and one of a container `hubble` in `demo`,
  for the query to leave out. The store's image then runs by the digest the header records, on a
  network made with `docker network create --internal`, with `-retentionPeriod=100y`: the
  documents' times are fixed, and the store answers 201 for a line older than its retention and
  keeps none of it. It takes `bulk.ndjson` at `/insert/elasticsearch/_bulk` with the arguments of
  `bulk.args`, the body sent as `Content-Type: application/x-ndjson`, as the collector's
  Elasticsearch sink sends it: a body sent as a form, as `curl --data-binary` sends one unless told
  otherwise, is answered with no item and none of it is kept. Once it holds every line,
  `/select/logsql/query` with the recipe's query, a `start` before the first line and the limit
  10000, as `scripts/logs` asks it, answers what `answer.jsonl` is to hold. The container and the network are removed afterwards. The store
  returns groups of the same count in no fixed order, so two runs over the same lines can differ in
  that order alone; the recipe orders its table by count and then by the line's text, so it does
  not depend on that order.
- **No alert reads the record.** Nothing in the tree evaluates a rule over the log store: the
  alerts are Prometheus rules over metrics ([Alerts](#alerts)), and no rules engine for the store
  runs, so no alert reads the record and none is added for it. A recorder that is not available
  raises the monitoring chart's own alerts, which watch every namespace, each a warning:
  `KubeDeploymentReplicasMismatch`, once the Deployment has had fewer replicas available than it
  asks for, with no rollout moving, for 15 minutes, whatever the cause; `KubePodCrashLooping`, once
  its container has been in `CrashLoopBackOff` for 15 minutes, as when the process keeps ending;
  `KubePodNotReady`, once the pod has been pending, or running and not ready, for 15 minutes; and
  `KubeContainerWaiting`, once its container has waited for another reason, such as an image it
  cannot pull, for an hour. `tests/network-audit.bats` reads them in the render. A recorder whose
  stream Relay no longer feeds, as above, raises none of them.
- **What it costs.** The recorder requests 10m of CPU and 32Mi of memory and is limited to 128Mi.
  None of these is measured on the cluster: in a local run of the image that printed 42000 flows
  read from standard input, the container's memory peaked at 25 MiB. Live, `kubectl top pod
  --namespace security-system --selector app.kubernetes.io/name=network-audit` gives its use, and
  `just logs` with the selector above and `| stats count() lines, sum_len(_msg) bytes`,
  `--since 24h`, the lines and bytes a day it adds to the store's 15 GiB.

### Turning it on, and back

The policies land on a cluster whose agents already audit, are watched there, and are enforced by a
change of their own. The order follows from how they land. The root Kustomization `cluster`, which
has no dependency, applies the namespaces' default denies as soon as it reconciles the change; each
application that holds allows names `cilium` in `dependsOn`, and Flux applies it only once `cilium`
is Ready, trying again after the dependency requeue, 30 seconds by default, while it is not.
kustomize-controller marks a Kustomization Ready `Unknown` from the start of each of its reconciles
until the reconcile ends, and `cilium` waits for its release, so `cilium` is not Ready for the
moments of every reconcile, for the whole rollout when its release changes, and for as long as
that release fails. A change of the Cilium values file alone, a comment among them, gives the
ConfigMap of the values a new name, as its generator hashes the file, so `cilium` reconciles it;
helm-controller compares the values themselves, and where they are unchanged it neither upgrades
the release nor restarts an agent, and `cilium` is Ready again within about a minute. The allows
therefore land after the denies, by tens of seconds to a couple of minutes, or by the whole rollout
when the change rolls the agents. On a cluster whose agents enforce, `demo` and
`envoy-gateway-system` would deny with none of their allows for that time: `hello` would refuse the
proxies, the controller would be cut off from the API server and the proxies from their
configuration. An agent that audits drops nothing a policy denies at layers 3 and 4, which is all
these policies decide, so on a cluster that audits the order in which the denies and the allows land
does not matter.

1. **The cluster audits.** The Cilium values set `policyAuditMode: true`, in a change of its own
   that lands before the policies do (the paragraph on audit mode at the end of
   [Service addresses](#service-addresses)), and every agent has restarted into it: the ConfigMap
   `cilium-config` in `kube-system` holds `policy-audit-mode: "true"`, and the Kustomization
   `cilium` is Ready at a revision that holds the value, which it is only once its release has
   rolled every agent onto that configuration (`rollOutCiliumPods`, at most two agents at a time by
   the chart's update strategy).
2. **The policies merge.** The root applies the default denies, the applications apply their allows,
   and the agents evaluate both and drop nothing they deny; what a policy would drop is reported as
   `AUDIT`. As the allows land after the denies, `AUDIT` flows of `ascender`, `backstage`,
   `crowdsec`, `demo`, `envoy-gateway-system`, `kromgo`, `locust`, `open-feature-operator`,
   `security-system` and `sso-system` from before they landed are expected, such as the proxies to
   `hello` on 8080 and to the controller on 18000, and the controller to the API server, and an
   agent's recent flows can hold them for a while.
3. **Watch a day of the record**, from the moment the Kustomizations that hold the allows, `hello`,
   `demo-volsync-movers`, `envoy-gateway`, `kromgo`, `dex`, `oauth2-proxy`, `backstage`, `falco`,
   `crowdsec`, `open-feature-operator`, `network-audit`, `ascender-operator`, `ascender` and
   `locust`, are Ready at the merge's revision (`flux get kustomizations`). The flow recorder writes
   every flow a policy would drop to the log store
   ([The record of what policy drops](#the-record-of-what-policy-drops)), so each path needs to be
   taken only once: `just gateway-check`; `just cluster-check`; the secret demo
   (`just secret-rotate demo/hello greeting`); a badge asked of kromgo by its name, which has kromgo
   query Prometheus ([Status badges](#status-badges)); a sign-in through a route that opts in to it
   ([Sign-in](#sign-in)), and a query in the log store's interface
   ([The log store's interface](#the-log-stores-interface)); Backstage's catalogue opened by its
   name, which has Backstage read its database; a WAL segment the primary of `backstage-db`
   archives, which `select pg_switch_wal()` there forces
   ([Backups and restores](#backups-and-restores)); a restore of `volsync-demo`
   ([Restoring](#restoring)); the two dry runs that call the OpenFeature Operator's webhooks
   ([OpenFeature Operator](#openfeature-operator)); a job launched in Ascender and a project update
   there, which start a job pod and have the task pod fetch the project ([Ascender](#ascender)); and
   a test started through Locust's interface, whose workers then resolve and reach the target
   ([Locust](#locust)). The blackbox exporter's probes need nothing to start them: its pods reach
   the proxies on 10080 and 10443 at every scrape of a `Probe` ([Probes](#probes)). Then let a night
   pass, for the paths nobody takes by hand: the nightly dump of `backstage-db` from 02:00, which
   waits up to 20 minutes before it starts ([Dumps](#dumps)), the base backup of `backstage-db` at
   02:47 UTC, the same two of `ascender-db`, the nightly backup of `volsync-demo` at 03:17, and its
   restore drill's restore at 04:17 and check at 05:17 ([The restore drill](#the-restore-drill)).
   Once the allows have been Ready for 24 hours, and within 24 hours of taking the paths above, so
   that the window holds them and one nightly backup, one dump, one base backup and one drill,
   `just network-audit 24h` must exit 0 and print no `AUDIT` line whose `NAMESPACE` is a namespace
   that holds the default deny: `ascender`, `backstage`, `crowdsec`, `demo`, `envoy-gateway-system`,
   `kromgo`, `locust`, `open-feature-operator`, `security-system` or `sso-system`. Exit 0 says that
   the recorder's container ran through those 24 hours and that the table is not cut, and what the
   record can miss even then is in
   [The record of what policy drops](#the-record-of-what-policy-drops); a run that exits 1 says what
   the record lacks, and the day is watched again from there. The lines that are not flows, which
   the run counts, are read with the query it prints: events Hubble lost, which its `lost_events`
   records count whatever their verdict, and a node Relay could not read are where the record may
   lack flows.
   An `AUDIT` line of one of those namespaces is a missing allow, added beside its application in a
   pull request while the cluster still audits, or a pod doing what it should not; a flow from
   `@remote-node` to the proxies' listener ports or to a webhook's 9443, Envoy Gateway's or the
   OpenFeature Operator's, would be such a line.
   `AUDIT` lines whose `NAMESPACE` is `flux-system` are expected: Flux's own policies and the Flux
   Operator's `flux-operator-web`, which the agents enforced before the value, are only audited
   while it is set, and what they would drop is what they dropped before; they are not the
   namespaces' allows. A `DROPPED` line, while the agents audit, is a packet dropped for the reason
   its `REASON` gives, which is none of the policies' denials at layers 3 and 4.
   `just network-drops` stays for what the agents hold at this moment: the `DROPPED` and `AUDIT`
   flows among each agent's recent ones (4095 by the chart's default), by pod and port, never an
   address. It needs neither the recorder nor the log store: it runs each agent's own `hubble`
   through `kubectl exec`, so the kubeconfig needs exec on the Cilium agents' pods in
   `kube-system`, more than the reading recipes need; `NETWORK_DROPS_LAST` (500) bounds the flows
   asked of each agent and `NETWORK_DROPS_TIMEOUT` (60) the seconds each call may take.
4. **Enforce, a change of its own.** One pull request makes these edits, together and no others:
   - `kubernetes/apps/base/kube-system/cilium/app/values.yaml`: the line `policyAuditMode: true`
     goes, with the three comment lines above it, from `# The agents evaluate every policy`; the
     two lines before them, on the enforcement mode, stay.
   - `docs/kubernetes.md`: the paragraph at the end of [Service addresses](#service-addresses) that
     opens with "**The cluster audits network policy.**" is replaced, whole, by one that opens with
     "**The cluster enforces the policies.**" and says that the agents drop what the policies deny,
     Flux's own in `flux-system` among them, that `rollOutCiliumPods` restarts them into it and
     `scripts/install-cilium` passes the same values, and that `tests/install-cilium.bats` fails
     when that sentence, the values and the agents' rendered configuration disagree. In
     [What the namespaces let through](#what-the-namespaces-let-through), "the watch in audit mode
     confirms it: a flow from `@remote-node` to the listeners would show as `AUDIT`" becomes
     "`just network-audit` confirms it: a flow from `@remote-node` to the listeners would show as
     `DROPPED`".
   - `features/cilium.feature` and `tests/install-cilium.bats`: the scenario "Cilium audits network
     policy by a value in Git, and the docs say so" and its test are retitled together "Cilium
     enforces network policy, and the docs say so". The scenario's Then becomes "values.yaml does
     not set policyAuditMode, the rendered cilium-config does not hold policy-audit-mode "true" and
     holds enable-policy "default", the agents' pod template carries the configmap checksum so they
     restart into it, and the docs open a paragraph with "The cluster enforces the policies.""; in
     the test, the audit sentence it counts becomes that sentence, its echo says "enforce" for
     "audit", the check that the value is `true` becomes one that the values have no
     `policyAuditMode` key, the rendered `policy-audit-mode` is required to be other than `true`,
     and its checks of `enable-policy` and the checksum stay as they are, the comment above the
     former becoming "Enforcement stays in its default mode, so the agents enforce the policies:
     never would enforce none."
   - `docs/roadmap.md`, M8's row: "the namespaces' default deny with their allows in `backstage`,
     `crowdsec`, `demo`, `envoy-gateway-system`, `kromgo`, `security-system` and `sso-system`" gains ", which
     Cilium enforces", and the clause "; and network policy that drops anything, as Cilium audits
     every policy, cluster-wide, and drops nothing
     ([Service addresses](kubernetes.md#service-addresses))" goes, the row ending at
     "`infra-apply`.".

   `tests/network-policy.bats` requires the enforcing sentence exactly when the value is gone, and
   fails, saying which sentence the value needs, on a change that does one without the other.
   Without the value every agent enforces every policy of the tree. The agents restart into
   enforcing as they restarted into audit mode, and a node audits until its agent has. Take the
   paths of step 3 again; `just network-audit` then prints, where a policy denied, `DROPPED` lines
   with the reason `POLICY_DENIED`: each whose `NAMESPACE` is an application namespace is an
   intended denial, and those of `flux-system` are what Flux's own policies dropped before the
   cluster audited.
5. **Back.** For the whole cluster: one pull request that reverses each edit of step 4, putting
   back the value and its comment, the audit paragraph, the scenario and its test under their audit
   title, and the roadmap's clause; the agents restart into audit mode and drop nothing a policy
   denies at layers 3 and 4. For one namespace: one pull request that deletes the
   `networkpolicy-default-deny.yaml` line from the namespace directory's `kustomization.yaml` and
   lists the namespace in `network-policy-exceptions.yaml` with its reason. Flux prunes the default
   deny; the namespace's allows stay and change nothing, as none asks for the default deny, so the
   namespace takes and sends everything, as before it had a policy; `tests/network-policy.bats`
   proves it on the objects.

**A listed namespace that takes the posture once the cluster enforces**, as `ai-system`,
`etcd-snapshots` and `external-dns` would, does it in two pull requests, as the root applies a
default deny at once while the allows wait for `cilium`. The first adds the allows beside the
namespace's applications, each application naming `cilium` in `dependsOn`, and leaves the namespace
listed: no policy of the namespace asks for the default deny, so they alter nothing. Once those
applications' Kustomizations are Ready at that revision (`flux get kustomizations`), the second adds
`networkpolicy-default-deny.yaml` to the namespace directory's `kustomization.yaml` and removes the
namespace's entry from `network-policy-exceptions.yaml`, so the default deny lands on allows already
in place. Then run the namespace's own checks and `just network-audit`: a `DROPPED` line whose
`NAMESPACE` is the namespace, with the reason `POLICY_DENIED`, is an intended denial or a missing
allow, which the way back for one namespace reopens in one pull request. A namespace with a flow
whose peer only the live cluster shows, such as the callers of a webhook, is watched in audit mode
as the first namespaces were: the cluster audits again (step 5) while its policies land, and
enforces again by step 4. While the cluster audits, a namespace takes the posture in one change,
its default deny and its allows together.

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
- A Helm value that comes from a variable is set in the HelmRelease's own `spec.values`, which
  Flux substitutes and helm-controller merges over the values ConfigMap; `values.yaml` holds no
  variables.

The check builds every application with Flux's strict substitution, using the placeholders, so a
variable that is none of the above fails it.

## Per-application artifacts

The ArtifactGenerator publishes each application's `app/` as an ExternalArtifact named after
the application, together with `components/`, at the same paths as in the tree, so a change
reconciles only the applications it touches (ADR 0004). Falling back to one shared source is a
`sourceRef` change in each `ks.yaml`, to `kind: OCIRepository` and `name: flux-system`.

## Resource definitions

Resource definitions that several applications use are applications of their own in
`apps/base/kube-system/`, so their version does not depend on whichever chart also bundles them:

- `prometheus-operator-crds`: every definition of the Prometheus Operator's `monitoring.coreos.com`
  group (ServiceMonitor, PodMonitor, PrometheusRule and the rest), from the upstream
  `prometheus-operator-crds` chart, which ships them and nothing else.
- `gateway-api-crds`: the Gateway API's standard channel (`gateway.networking.k8s.io`). Its `app/`
  holds a `GitRepository` for the upstream repository at the release tag, checking out only
  `config/crd`, and an inner `Kustomization` that applies upstream's kustomization there, the one
  the release's `standard-install.yaml` is built from. Its patches leave out the release's
  `safe-upgrades` admission policy and binding, so it applies resource definitions only. Both
  objects live in `kube-system`, where the application's `targetNamespace` puts them; the inner
  `Kustomization` is not a child of the root, gets none of its defaults and substitutes nothing.
- `snapshot-controller`: the CSI snapshot definitions (`snapshot.storage.k8s.io`, and
  `groupsnapshot.storage.k8s.io` beside them) and the snapshot controller that serves them, from
  the upstream `external-snapshotter` repository at one release tag, the source the Piraeus
  documentation points to, so both always come from the same release. Its `app/` has the Gateway
  API application's shape: a `GitRepository` checking out only `client/config/crd` and
  `deploy/kubernetes/snapshot-controller`, and an inner `Kustomization` for each that applies
  upstream's kustomization there, the controller's once the definitions' is Ready. The controller
  runs in `kube-system`, where upstream's manifests put it. The repository also tags releases of
  its client module, `client/vX.Y.Z`; Renovate follows only the `vX.Y.Z` tags.

The three `ks.yaml` files set `wait`, so each is Ready only once its definitions are established,
and `snapshot-controller` once its controller runs as well. An application that creates objects of
these groups, or whose chart does, names the matching one in `dependsOn` and turns off any copy of
the same definitions its own chart would install; each application's section below says which it
names. No route is enabled anywhere, and no chart's dashboard outside the `grafana` application.

Deleting a definition deletes every object of its kind, so none of these applications ever deletes
one, also not when it leaves the tree. None applies a definition itself. The monitoring chart's
values give each definition `helm.sh/resource-policy: keep`, so Helm leaves them when Flux
uninstalls the release. The inner Gateway API `Kustomization` and the inner `Kustomization` of the
snapshot definitions set `prune: false` and `deletionPolicy: Orphan`, so each leaves what it
applied when it is deleted, and keeps a definition a newer release drops. `tests/baseline.bats`
renders the chart and builds the pinned Gateway API source offline to check the first two, and
that they yield definitions only; `tests/storage.bats` builds the pinned snapshot source the same
way.

## The kube-system baseline

The small services later applications assume are applications in `apps/base/kube-system/` with
the Cilium application's shape. Their charts come from their publishers' OCI registries,
except metrics-server's and the descheduler's, which their publisher releases only to a classic
Helm repository; those come from a public OCI mirror that republishes each release unchanged. Each
of them that serves metrics has its chart's monitor on, a ServiceMonitor or, for Reloader, whose
chart makes no Service by default, a PodMonitor, and names `prometheus-operator-crds` in
`dependsOn`. No dashboard is enabled in any of them, and none uses a priority class Kubernetes
does not define itself.

- `kubelet-csr-approver` approves a kubelet's serving certificate request (Talos has the kubelets
  make them) only when the name it asks for matches `NODE_NAME_REGEX` in full and every address it
  asks for is in `NODE_CIDR`, both from `cluster-config`, which its HelmRelease sets in its own
  values. A missing `NODE_NAME_REGEX` leaves a pattern that matches no name; a missing
  `NODE_CIDR` becomes a value the approver cannot parse, so it stops rather than read an empty
  list as every address. Nothing in this repository makes node names resolvable in the cluster's
  DNS, so the approver does not look them up.
- `metrics-server` serves resource metrics. It verifies each kubelet's serving certificate against
  the cluster CA, and starts only once `kubelet-csr-approver` is ready, which it names in
  `dependsOn`. Its own `/metrics` is served without authorization, as its chart's ServiceMonitor
  carries no credential. Its `ks.yaml` sets `wait` and the long timeout: on a new cluster its pods
  turn ready only once the approver has signed each kubelet's serving certificate, which can take
  most of the 10m the release defaults give the install, and with the default 3m the Kustomization
  would report its health check failed and retry every minute until the release is Ready.
- `spegel` shares images between nodes, serving the image layers containerd keeps on each node,
  which every node's machine configuration has it keep;
  [cluster.md](cluster.md#image-layers-for-spegel) says which images that is, and how a change to
  the nodes is rolled out while it runs. It writes containerd's registry mirror configuration to
  `/etc/cri/conf.d/hosts`, where Talos' containerd reads it.

  Its registry, on every node's port 30020 and on its pod, takes no credentials, by Spegel's design:
  containerd sends a mirror none, and Spegel could not check them
  ([Spegel](https://spegel.dev/docs/faq/#why-am-i-able-to-pull-private-images-without-image-pull-secrets)).
  An image a node pulled with credentials is therefore served within the cluster; the nodes'
  security group (`infra/openstack/modules/talos-nodes`) admits nothing from outside the node
  network but the Talos and Kubernetes APIs ([cluster.md](cluster.md#the-control-planes-metrics)).

  Prometheus scrapes its metrics port, where Spegel 0.8.1 also serves Go's profiler
  ([Spegel](https://github.com/spegel-org/spegel/blob/v0.8.1/main.go#L278-L305)); the values turn
  off the debug page beside it.
- `reloader` restarts a workload annotated for it when a ConfigMap or Secret it uses changes, and
  nothing else. `hello` in `demo` is annotated for its Secret, `secret.reloader.stakater.com/reload:
  hello`, so a new value of the demo's secret reaches its pods by a restart
  ([Rotating an application's secret](#rotating-an-applications-secret)). Reloader restarts when
  the Secret's data changes, not when the Secret is created, and by writing a variable into the
  container's environment, which starts a rollout as any change to the pod template does.
- `descheduler` runs the chart's default policy every five minutes, with two changes: a pod is
  evicted only when another node can take it, and a cordoned node's taint is no reason to evict.

`tests/baseline.bats` renders every baseline chart with the repository's values, checks that each
values key is one the pinned chart defines and that each monitor selects a Service or pods the
chart makes, and reads the approver's, metrics-server's and Spegel's rendered configuration,
Spegel's debug page included.

The approver's chart makes its ServiceMonitor only once the kind exists, so the release installed
before Flux has none, and Flux's first upgrade, which waits for `prometheus-operator-crds`, adds
it.

## Runtime classes

`apps/base/kube-system/runtime-classes/` holds a RuntimeClass for each container runtime the node
image adds ([cluster.md](cluster.md#the-node-image)), with the handler the extension's README
gives: `gvisor`, handler `runsc`, and `kata`, handler `kata`, which also carries the overhead of
Kata's virtual machine from that README, counted on top of a pod's requests. A RuntimeClass is
cluster-scoped, so the application's `targetNamespace`, `kube-system` as for the resource
definitions, gives it none. A pod selects one with `runtimeClassName`; none does. Flux applies them
whatever image the nodes run, and a pod that selects one on a node whose image lacks its handler
does not start. `tests/baseline.bats` builds the application as Flux applies it and checks the two
classes and their handlers.

**Pods under a sandbox runtime reach Services.** Serving Services in place of kube-proxy, Cilium by
default translates a Service's address to a backend's where a socket connects or sends, in hooks on
the node's kernel, its socket load balancer, so that the socket is connected to the backend itself
and no packet needs rewriting
([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/Documentation/network/kubernetes/kubeproxy-free.rst#socket-loadbalancer-bypass-in-pod-namespace)).
A pod under `gvisor` or `kata` runs on a kernel of its own, gVisor's or the one in Kata's virtual
machine, so its sockets never pass those hooks, and that documentation names Kata Containers and
gVisor among the pods the translation at the socket has no effect on. With these values, an agent
looks a Service up at a pod's interface only where the translation at the socket does not cover the
pods (`bpf/bpf_lxc.c`, `ENABLE_PER_PACKET_LB`), so with the translation at the socket alone such a
pod would reach other pods and no Service, the cluster's resolver included. Cilium's values
therefore set `socketLB.hostNamespaceOnly: true`, which Cilium's guide to Kata Containers asks for
([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/Documentation/network/kubernetes/kata.rst#deploy-cilium))
and the chart renders into the key `bpf-lb-sock-hostns-only` of the ConfigMap `cilium-config`: the
agents translate at the socket only for processes in the node's own network namespace, pods on the
host network among them, and at its interface for every other pod (`bpf/bpf_sock.c`,
`ENABLE_SOCKET_LB_HOST_ONLY`). Kube-proxy replacement turns the translation at the socket on
whatever `socketLB.enabled` says (`pkg/kpr/kpr.go`), so this value is the one switch. It holds for
every pod off the host network, sandboxed or not. Such a pod's connection to a Service is
translated packet by packet, on the way out and back, from an entry in Cilium's connection tracking
that holds its backend (`bpf/lib/lb.h`, `lb4_local`), where a socket connected to the backend
needed neither. The socket stays connected to the Service's address, and that is the address Falco
records of a connection, as its probe reads the socket's own destination, so its rule
`Contact K8S API Server From Container` matches a connection to the `kubernetes` Service from a
container off the host network that the rule does not except
([Runtime detection](#runtime-detection)). One known issue in Cilium's documentation comes with
translation at the interface
([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/Documentation/network/kubernetes/kubeproxy-free.rst#connection-collisions-when-a-service-endpoint-is-accessed-via-multiple-vips)):
two connections that one pod opens to one backend through two Service addresses, from the same
source port, are one connection once translated, and the second can be dropped, so it advises
against exposing a backend through more than one address. A pod under `kata` has a limitation of
Kata's networking besides
([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/Documentation/network/kubernetes/kata.rst#limitations)):
Kata copies the MTU of the pod's interface into its virtual machine and not the lower MTU that
Cilium sets on the pod's default route for the tunnel's overhead, so its connections with other
pods can see fragmentation or dropped packets until the pod lowers that route's MTU itself. The
value is one of the settings in `cilium-config`, so a change of it restarts every agent, at most
two at a time, and the operator ([Service addresses](#service-addresses)).

An agent that restarts attaches its socket programs before it rebuilds the programs at the
interfaces of the pods on its node (`pkg/datapath/loader/base.go`,
`pkg/datapath/orchestrator/orchestrator.go`), so when the value is turned on a packet that a pod
there sends to a Service's address in between goes out untranslated, and when it is turned off the
connections that pods opened to Services under it, which still carry the Services' addresses,
stall once their programs are rebuilt without the lookup. `tests/install-cilium.bats` fails unless
the runtime classes Flux builds, in the applications and besides them, are exactly these two (it
renders no chart but Cilium's, so a class another chart would render goes unseen), the value is
set, the agents' rendered configuration holds it beside kube-proxy replacement, and one paragraph,
in this section, opens with the first sentence of the paragraph above.

## Service addresses

A Service of type `LoadBalancer` gets its address from Cilium and is announced over BGP by the
workers to two edge routers, which publish it (ADR 0013). `apps/base/kube-system/cilium-bgp/` holds
what that takes, beside the Cilium application, whose values turn on Cilium's LoadBalancer IP
management and its BGP control plane and keep Layer 2 announcements off. These settings live in
the ConfigMap `cilium-config`, and `rollOutCiliumPods` and `operator.rollOutPods` restart the agents
and the operator whenever it changes: a change to any of them, as the one that turned them on,
restarts every agent, at most two at a time by the chart's update strategy, and the operator.

- **Opting in.** A Service gets an address, and has it advertised, only with the label
  `k8s-gitops/announce: bgp`. Any other `LoadBalancer` Service stays pending, so no address is handed
  out that nothing announces.
- **The pool.** One `CiliumLoadBalancerIPPool` holds exactly the service range
  ([infrastructure.md](infrastructure.md#services-announced-over-bgp)), `10.20.0.0/28` by default:
  sixteen addresses. Services can share one with Cilium's `lbipam.cilium.io/sharing-key`
  annotation where their ports differ.
- **Who announces.** One `CiliumBGPClusterConfig` gives every worker, and no control plane, a BGP
  instance in the cluster's AS that peers with both edge routers in theirs, over eBGP. Talos labels
  its control planes `node-role.kubernetes.io/control-plane`, which the node selector excludes, and
  only the workers' ports may carry the service range. The edge routers are on the node subnet, one
  hop away, so the sessions keep eBGP's TTL of 1. A worker opens its sessions and listens for none.
- **The sessions.** The `CiliumBGPPeerConfig` sets a hold time of 9 seconds, keepalives every 3 and
  a connect retry of 5, and turns on graceful restart with a restart time of 120 seconds, so an
  edge router keeps forwarding to a worker while its Cilium agent restarts. IPv4 unicast only, and
  no password (ADR 0013).
- **What is advertised.** The `CiliumBGPAdvertisement` the peer configuration selects advertises
  the `LoadBalancer` address of each labelled Service, as a /32, and nothing else: no pod range and
  no cluster IP.
- **Without the edge routers** (the `edge` stack not applied, [infrastructure.md](infrastructure.md#the-edge-routers))
  the sessions stay down: a labelled Service gets an address, but nothing outside the cluster
  reaches it.
- **The Gateway's address.** The edge routers forward public traffic to one address of the service
  range, `GATEWAY_ADDRESS` in `cluster-config`, a host the plumbing stack picks. The public Gateway's
  proxies' Service asks the pool for it with the `lbipam.cilium.io/ips` annotation and carries the
  label ([The public Gateway](#the-public-gateway)). The pool does not set it aside, so any other
  labelled Service may be given it first, and the Gateway's Service would then stay pending.
  `tests/gateway.bats` holds that, of every object the overlay's applications apply, built offline,
  only the `EnvoyProxy` `public` carries the label outside a selector, sets an LB-IPAM annotation or
  names the address; that no text among them, the values a chart takes from a ConfigMap included,
  holds the label's key or an LB-IPAM key; and that only the Gateway `public` names that
  `EnvoyProxy`. A chart's own defaults are not read, so a chart that labels a Service by default
  would go unseen.
- **`externalTrafficPolicy`.** With `Cluster`, the default, every worker announces every labelled
  address, the edge routers spread connections over all of them, and a worker forwards each to an
  endpoint on any node, translating the source to its own address when the endpoint is elsewhere.
  With `Local`, only workers with a ready endpoint of the Service announce its address, and a
  connection reaches an endpoint on the worker it arrived at with its source unchanged. Either way
  the source a Service sees is what reaches the worker, which is an edge router's address while
  the edge routers translate the client's address to their own (ADR 0013). A worker whose last
  endpoint goes away withdraws a `Local` address; a `Cluster` address stays announced while the
  Service has no endpoint at all.

The sessions' state is scraped and alerted on ([Cilium's metrics](#ciliums-metrics)): a worker with
a session down for 5 minutes, and no worker with any session.

Every object there is of a kind that Cilium's operator defines once it leads, the BGP kinds only
while the BGP control plane is on, so the Cilium application holds none of them:
`scripts/install-cilium` installs Cilium before any of those definitions exists. `cilium-bgp` names
`cilium` in `dependsOn`, and the Cilium application sets `wait` and carries
`k8s-gitops/timeout: long`, as its release may take 10 minutes to roll the agents: it is Ready only
once its release is, with every agent running, and an agent starts only once every kind it uses is
defined. So Flux applies the pool and the BGP objects only after their definitions exist, also on
the change that turns the BGP control plane on. The objects are cluster-scoped; the
API server drops the namespace the application's `targetNamespace` gives them. Their numbers come
from `cluster-config` ([Before Flux starts](#before-flux-starts)). `tests/install-cilium.bats`
renders the chart and the nodes' machine configurations and builds every application as Flux
applies it to check each of these, and requires of every application that holds an object of
Cilium's kinds, a `CiliumNetworkPolicy` included, that it names `cilium` in `dependsOn` and that
the cluster's overlay lists it, enabled or commented out with its reason
([Adding an application](#adding-an-application)): a disabled application applies nothing, and the
line that enables it brings the dependency along.
The chart ships none of the definitions; the operator installs
the ones it embeds, which Cilium publishes in its repository, so `operator-definitions.yaml` has
`kubernetes-validate` read them there at the release the chart's tag pins, and validate the pool,
the BGP objects and every `CiliumNetworkPolicy` ([Network policy](#network-policy)) against them,
unknown fields refused ([Schemas](#what-the-checks-refuse)). A Cilium
upgrade moves the definitions with the chart's tag.

**The cluster audits network policy.** Cilium's values set `policyAuditMode: true`, which the chart
renders into the key `policy-audit-mode` of the ConfigMap `cilium-config`; read it from the cluster
with `kubectl -n kube-system get configmap cilium-config -o jsonpath='{.data.policy-audit-mode}'`,
which prints `true`. The mode is the agent's, so it holds for the whole cluster at once, not for a
namespace: an agent evaluates every policy, reports each flow a policy would drop with the verdict
`AUDIT`, and drops nothing a policy denies at layers 3 and 4. Audit mode covers those layers only
(`Documentation/security/policy-creation.rst`; `bpf/lib/policy.h` turns a layer-3 or layer-4 drop
into an audit), not a layer-7 rule, of which the tree has none. The NetworkPolicies Flux's
instance installs in `flux-system` and the Flux Operator's own for its web interface,
`flux-operator-web`, are therefore audited and no longer enforced until the value is removed; that
loosens Flux's own policies for as long as the mode is on. `rollOutCiliumPods` restarts the agents
into a change of their configuration, and `scripts/install-cilium` passes the same values file to
helm, so a cluster built from nothing comes up in audit mode too. `tests/install-cilium.bats`
fails when this sentence, the value and the agents' rendered configuration disagree.

## External Secrets

`apps/base/external-secrets/external-secrets/` runs the External Secrets operator in its own
namespace, `external-secrets`. It is how runtime secrets reach workloads (ADR 0005): an
`ExternalSecret` names a key in a secret store, and the operator writes it into a Secret. The
exception is a credential a controller generates in the cluster for its own workload, which stays
in the Secret that controller writes, such as Grafana's admin password ([Grafana](#grafana)). The
one store is the ClusterSecretStore `openbao`, in its own application beside the operator
([OpenBao](#openbao)). The `volsync` component makes an `ExternalSecret` of it for each application
that includes it ([Volume backups](#volume-backups)).

- The chart comes from its publisher's OCI registry and installs and upgrades the operator's
  resource definitions itself, as the publisher documents. No other chart in the tree ships them,
  so they are not an application of their own. Each carries `helm.sh/resource-policy: keep`, so
  uninstalling the release leaves them in place, and with them every `ExternalSecret` and the
  Secret it owns.
- The controller, the webhook and the certificate controller each run two replicas on different
  nodes, the controllers with leader election, and a disruption budget keeps one of each running
  while a node is drained. The certificate controller issues the webhook's certificate. The webhook
  validates every change to a secret store or an `ExternalSecret`, and the API server refuses the
  change when no webhook answers.
- The namespace enforces the restricted Pod Security level, which the chart's pods meet. No
  ServiceMonitor or dashboard is enabled.
- The controller creates a service account's token, for a store that names one, only where a Role
  allows it for that account by name: the chart's own grant to create every account's token is off
  (`rbac.serviceAccountTokenCreate`), and `openbao-store`'s application holds the one Role, for its
  own account ([OpenBao](#openbao)).
- The chart adds creating and changing `ExternalSecret`s and secret stores to Kubernetes' `edit` and
  `admin` roles, so whoever may edit a namespace may make an `ExternalSecret` there.

`tests/external-secrets.bats` builds the application as Flux applies it and renders the chart to
check the first three of these, and `tests/openbao.bats` the token grant.

## Monitoring

`apps/base/monitoring/kube-prometheus-stack/` installs the Prometheus Operator, one Prometheus, one
Alertmanager, kube-state-metrics and node-exporter in the namespace `monitoring`, from the
prometheus-community `kube-prometheus-stack` chart. The namespace's Pod Security level is
privileged, as node-exporter reads each node through the host's network and process namespaces and
through host paths, and the log collector ([Logs](#logs)) reads the nodes' log files through a
host path; those two DaemonSets are its entries in `pod-security-exceptions.yaml`, and every
other pod of it that the render holds passes restricted. The pods the operators make from the
Prometheus, Alertmanager and Grafana resources are not in the render; each resource sets the
security context restricted requires ([Pod Security](#pod-security)). The chart installs no
resource definitions: `prometheus-operator-crds` does
([Resource definitions](#resource-definitions)), and the application names it in `dependsOn`. The
two charts run the same operator version: Renovate moves them in one pull request, and
`tests/monitoring.bats` fails when the pinned charts name different ones. The application installs
no Grafana and no dashboards; [Grafana](#grafana) runs on its own and takes its dashboards from the
same chart.

Prometheus picks up every ServiceMonitor, PodMonitor, Probe, ScrapeConfig and PrometheusRule in
every namespace, and evaluates the chart's default alerting and recording rules. It scrapes:

- the API server, every kubelet with its container metrics, CoreDNS, kube-state-metrics,
  node-exporter on every node, and the stack's own components;
- on every control plane, the controller manager and the scheduler on their secure ports, and
  etcd's metrics over plain HTTP, which Talos serves once the node runs
  `talos/patches/controlplane/metrics.yaml` ([cluster.md](cluster.md#the-control-planes-metrics)).
  Talos runs etcd outside Kubernetes, so etcd's Service selects the API server's pods, which run on
  the control planes' host network, for their addresses, and Prometheus sends etcd no credential;
- the monitors of the baseline applications ([The kube-system baseline](#the-kube-system-baseline))
  and of the log store and collector ([Logs](#logs));
- OpenBao's active member, through its chart's ServiceMonitor ([OpenBao](#openbao));
- cert-manager's controller, webhook and CA injector, through its chart's ServiceMonitor
  ([cert-manager](#cert-manager));
- Flux, through the `flux-monitoring` application: the Flux Operator's own metrics, which give the
  Ready and suspended state of every Flux resource and of the FluxInstance, and the controllers'
  ([Flux monitoring](#flux-monitoring));
- the Cilium agents, whose metrics include the workers' BGP sessions, through the `cilium-monitoring`
  application ([Cilium's metrics](#ciliums-metrics));
- the storage layer, through the `linstor-monitoring` application: the LINSTOR controller's metrics
  and the satellites' DRBD reactor ([Storage monitoring](#storage-monitoring));
- the silence operator, through its chart's PodMonitor ([Silences](#silences));
- Falco on every node, through its chart's ServiceMonitor ([Runtime detection](#runtime-detection));
- the OpenFeature Operator's manager, through its application's PodMonitor
  ([OpenFeature Operator](#openfeature-operator));
- the public hostnames, through the blackbox exporter and the Probes that applications declare
  beside their routes ([Probes](#probes)).

It does not scrape:

- kube-proxy, which Cilium replaces: its target and its alert rule are off, so nothing fires for
  its absence;
- the Cilium operator, Envoy and Hubble: their monitors stay off, as does every ServiceMonitor of
  the Cilium chart, because `scripts/install-cilium` installs Cilium from the same values before any
  monitoring definition exists, and its chart refuses a ServiceMonitor without one; the agents'
  metrics endpoint needs no definition, so it is on and a PodMonitor of its own application scrapes
  it.

Alertmanager sends a critical or warning alert to a notification webhook and the Watchdog to a
heartbeat URL, once the two addresses are in the secret store; until then it runs without them and
nothing leaves the cluster ([Where alerts go](#where-alerts-go)).

Prometheus keeps 14 days of data, and at most 16 GiB, on a 20 GiB volume; Alertmanager keeps its
silences and notification log on a 1 GiB volume. Both volumes are claims on the cluster's default
storage class, which neither names; without one, the claims and the two pods stay Pending.

`tests/monitoring.bats` builds the application as Flux applies it, renders the pinned chart with
its values, and checks the namespace, the targets, the rules, the claims and that each values key
is one the chart or a subchart reads; `tests/alert-routes.bats` holds Alertmanager's configuration.

### Flux monitoring

`apps/base/monitoring/flux-monitoring/` makes the monitors and the alerts for Flux. It names
`prometheus-operator-crds` in `dependsOn` and is not part of Flux's own two applications, as Flux is
installed before the monitoring definitions exist and an object of their kinds would stop that
install: the operator's chart has a ServiceMonitor of its own, `serviceMonitor.create`, which stays off
for that reason.

- A ServiceMonitor, `flux-operator`, scrapes the Flux Operator's Service, `flux-operator` in
  `flux-system`, on its port `http`, 8080. The operator exports the state of every Flux resource as
  `flux_resource_info`, with the labels `kind`, `name`, `exported_namespace`, `ready` (the status of
  the Ready condition: `True`, `False` or `Unknown`), `reason`, `suspended` and, by kind, `revision`,
  `source_name`, `path`, `url` and `ref`, and of the FluxInstance as `flux_instance_info`
  ([Flux Operator monitoring](https://fluxoperator.dev/docs/instance/monitoring/), and
  `internal/reporter/metrics.go` of the operator at the pinned version). That is the mechanism for
  the state of Flux's resources, chosen over kube-state-metrics' custom resource state: it covers
  every kind, the FluxInstance and the suspended state in one metric, and asks nothing of the
  monitoring stack, where kube-state-metrics would need a configuration and read permission for each
  Flux kind. The operator refreshes the metric with its report, which its values set to every 30
  seconds, the interval its documentation recommends for these metrics, where the default is five
  minutes; `tests/monitoring.bats` holds that the report and the scrape are no longer than a minute.
- A PodMonitor, `flux-controllers`, scrapes the controllers of the instance, source-watcher
  included, on the port `http-prom` of every pod labelled `app.kubernetes.io/part-of: flux`, which the
  operator gives every pod it installs. Flux's network policy `allow-scraping`, which the instance
  turns on, admits every namespace to that port on every pod of `flux-system`. The controllers'
  metrics, `gotk_*` and controller-runtime's, are scraped and no alert reads them.
  `tests/monitoring.bats` matches both monitors against the Service the operator's chart renders and
  the Deployments of the pinned operator's manifests artifact.

The root sync, the Kustomizations `flux-system` and `cluster` and the OCIRepository `flux-system`,
has an alert of its own, `FluxRootSyncNotReady`, critical after 10 minutes, named in its expression;
the alerts on every other Kustomization, HelmRelease and source leave it out, so one failure is one
alert. They also leave out a Kustomization that reports `DependencyNotReady`, as the dependency it
waits for is the one that has the alert. A resource's series is one set of those labels, and the
operator writes a new one whenever its `ready`, `reason` or `revision` changes: a resource that fails
at each retry goes `Unknown`, progressing, at the start of each and `False` when it fails, as a
Kustomization whose health checks time out does every few minutes, so no one set lasts an alert's
time. The three alerts on a resource that is not Ready therefore keep only `kind`, `name` and
`exported_namespace`, and the reason is read from the resource itself. The sources the tree uses
are OCIRepository, HelmRepository, the HelmCharts a release from a HelmRepository makes and the
ArtifactGenerator; the ExternalArtifacts the generator makes are left out, as their state is the
generator's. While the operator is down its metrics are gone, so `FluxOperatorNotReady` reads the
availability of its Deployment instead.

### Cilium's metrics

The agents serve their metrics on port 9962 of the node they run on, as they run on the host's
network, once `prometheus.enabled` is set in the Cilium application's values. That key creates no
monitor and needs no resource definition, so `scripts/install-cilium`, which installs Cilium from the
same values file before any definition exists, is unchanged, and the chart's ServiceMonitors stay off
([Monitoring](#monitoring)). It adds the host port 9962 to the agents' container ports, beside the
host ports 9879 and 4244 they already declare; the DaemonSet's exception in
`pod-security-exceptions.yaml` already allows host ports, and no new workload and no new Pod
Security level comes with it.

`apps/base/kube-system/cilium-monitoring/` holds a PodMonitor, `cilium-agent`, which selects the pods
labelled `k8s-app: cilium` and scrapes the port `prometheus` every 30 seconds, naming the job
`cilium-agent` and adding the node's name as the label `node`. It also copies the pods' label
`k8s-app` onto every series, as `k8s_app="cilium"`, which Cilium's own dashboard selects the agents
by ([Dashboards](#dashboards)). The application names `cilium` and
`prometheus-operator-crds` in `dependsOn`: Cilium and `cilium-bgp` are unchanged, and a from-nothing
bootstrap installs Cilium, then Flux, as before, and the monitor follows once the definitions are
there. The port is open in the nodes' firewall to the nodes and the pods only, with node-exporter's
rule ([cluster.md](cluster.md#what-each-node-admits)): Prometheus's scrape from a pod on another
node arrives from that node's address, and from the same node from the pod range. Until a node has
that rule its agent's target is down and reports nothing. `CiliumBGPSessionsDown` counts only the
sessions an agent reports, and `CiliumBGPNoSessionEstablished` only while a worker's agent is scraped:
the control planes' agents never report a session, so an agent counts unless kube-state-metrics'
`kube_node_role` gives its node, by the PodMonitor's `node` label, the role `control-plane`, which
Talos gives every control plane and no worker. Control planes that admit the port before the workers
do therefore raise neither alert, unless kube-state-metrics is not scraped then either, when every
scraped agent counts. `just cluster-check`'s scrape targets are the cluster's own components and
the agents' are not among them: a node that does not yet admit the port would fail the check that
`just cluster-talos --first` runs before it applies the rule.

The BGP control plane's metrics are `cilium_bgp_control_plane_session_state`, one series for each
configured peer of a node's BGP instance, 1 while the session is established, labelled
`instance_name`, `local_asn`, `neighbor` (the peer's address and port) and `neighbor_asn`, and
`cilium_bgp_control_plane_advertised_routes`, the number of routes advertised to a peer, with the
address family
([Cilium](https://github.com/cilium/cilium/blob/v1.20.4/Documentation/observability/metrics.rst),
`pkg/bgp/metrics/metrics.go` at the pinned version). The only label that tells the peers apart is an
address, so the alerts name the worker and a count and print no address. A worker taken out of BGP, by
the label the reboot and upgrade recipes set ([Service addresses](#service-addresses)), has no BGP
instance, so its agent reports no series for it: it is configured for no session, and
`CiliumBGPSessionsDown` counts the sessions a node reports against those established, so it does not
fire for it. The control planes have no instance and report none.

### Storage monitoring

`apps/base/piraeus-datastore/linstor-monitoring/` makes the monitors and the alerts for the storage
layer, with `prometheus-operator-crds` in `dependsOn` and nothing else: the storage cluster is
installed without any monitoring definition. The Piraeus operator makes the LINSTOR controller's
Service and the satellites' pods at run time, so they are not in the render, and the monitors select
them by the labels and ports the operator's templates give at its version, which the monitors' file
records (`piraeus-operator-templates`) and `tests/monitoring.bats` holds equal to the version the
cluster runs.

- A ServiceMonitor, `linstor-controller`, scrapes the controller's `api` port, 3370, at `/metrics`,
  over plain HTTP, as the `LinstorCluster` sets no TLS for its REST API: LINSTOR's own state,
  `linstor_node_state` (2 for a satellite that is online), the storage pools' free and total
  capacity, `linstor_storage_pool_capacity_free_bytes` and `linstor_storage_pool_capacity_total_bytes`,
  with the labels `node`, `nodetype`, `storage_pool`, `driver` and `backing_pool`, and for a node
  also the satellite's address, which no alert prints
  (`PrometheusBuilder.java` of linstor-server, the controller image of the operator's version).
- A PodMonitor, `linstor-satellite`, scrapes the DRBD reactor that runs in each satellite's pod, on
  the port `prometheus`, 9942, which the operator configures with enumerated states: for each device,
  a `drbd_device_state` series for each disk state, 1 for the state it is in, labelled `name` (the
  DRBD resource, which is the volume's `pvc-<id>`), `volume`, `minor` and the state, and
  `drbd_device_quorum` and `drbd_device_client`, which is 1 for a device that is diskless on purpose, a
  client or a tiebreaker (`doc/prometheus.md` and `src/plugin/prometheus.rs` of drbd-reactor). The
  monitor names the job `linstor-satellite` and adds the node. The satellites run on the pod
  network, so no rule of the nodes' firewall is involved.

The operator publishes alert rules of its own, `config/extras/monitoring/alerts.yaml` in its
repository, to be applied by hand. They are not loaded: they set no summary and no runbook, and some
no `for`, which every own alert of the tree needs, and their severities and thresholds are not the
ones these alerts have, so a rule of theirs beside these would fire twice for one failure. The
alerts here cover the replicas that are not UpToDate, a device without quorum, a satellite that is
offline and a pool at 85 and 95 percent, and `DrbdReplicaNotUpToDate` leaves out a diskless client,
which is no replica. What theirs cover and these do not is listed under what no alert covers
([Alerts](#alerts)).

### Alerts

An application's own alert rules are a `PrometheusRule` named `prometheusrule.yaml` in its `app/`
directory, in the application's namespace, listed in its `kustomization.yaml`. Prometheus selects
every rule in every namespace, so a rule needs no label, and it leaves with its application: an
application the cluster's overlay leaves out brings none. The rules' unit tests are promtool's, one
file per application, `tests/rules/<application>.yaml`, which loads the application's rules as
`rule_files: [<application>.rules.yaml]` and names each test group after its scenario in
`features/alerts.feature`.

`just rules-check`, in the `static` group of `just ci`, collects every `PrometheusRule` the tree
renders for each cluster, those of the charts too, so a chart update that ships a rule promtool
refuses fails it, and runs promtool's `check rules` on every rule file and `test rules` on the unit
tests, from the image of the Prometheus the rendered chart deploys. `just rules-check` runs promtool
in that image in a container with no network; `just ci` copies promtool out of the image into the
tools container, which has the network the render needs. The image is the chart's, by the tag the
chart names, which Renovate moves with the chart; nothing else in the tree pins it. `dagger.lock`
holds no entry for it, so Dagger resolves the tag when it pulls the image, and a chart update that
moves the tag needs no other change. Dagger records the digest it resolved in `dagger.lock`, as
it does for any lookup without an entry, so `just ci` puts the file back as it found it, whether the
run passes, fails or is stopped by `INT`, `TERM` or `HUP` (`scripts/restore-after`, which passes the
signal on, waits for Dagger to end, as it writes the lock while it does, and then puts the file back;
`INT` gives Dagger its own cancel, `TERM` and `HUP` end it at once; a run killed outright with
`SIGKILL` cannot: Dagger writes the lock when its session ends, so a Dagger killed with it leaves no
line, and one that goes on after only `restore-after` was killed leaves it, which `git diff`
shows). A change a developer made to the file before the run is what is put back, and an edit made
to it while a run is going, such as by `dagger lock update` in another terminal, is replaced by the
bytes from before the run. When the file cannot be written back, the run says where those bytes are
kept and fails. `just lock-check`, in the `static` group, fails when the committed `dagger.lock`
holds an entry for an image the tree takes by a tag it derives at run time, naming the line; it
reads the commit at `HEAD`, not the working copy. An image of that kind is added to the list in
`scripts/lib/derived-images.sh`; `scripts/rules-image` derives this one.

Each run also proves that the check refuses what only `check rules` reads: in rule files no unit
test loads, a chart's rule and an own alert with an expression promtool cannot parse, and an own
alert defined twice, which promtool's lint finds; each must fail the check, with `check rules`
naming the rule. A lint finding in a chart's rules is printed and does not fail the check; the
chart's rules stay as they are. For each of the tree's own alerts the check also fails, naming the
alert, unless:

- its `severity` label is `critical`, `warning` or `info`: `critical` is a loss of service or of
  data in progress that an operator acts on at once, `warning` is a failure that needs action
  within the working day, and `info` points at something to look at when convenient. A `critical`
  or a `warning` alert goes to the receiver `notify`; an `info` alert goes to no receiver and shows
  in Prometheus' and Alertmanager's interfaces only ([Where alerts go](#where-alerts-go));
- it has a `summary`, a `description` that names what is affected with `{{ $labels.<name> }}`, and
  a `for`;
- its `runbook_url` is `https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/<file>.md#<heading>`
  and the heading exists in that file of this tree;
- its unit tests hold, in one test group, a case in which it fires and a case one evaluation
  earlier in which it stays quiet, an `alert_rule_test` of its name with `exp_alerts` and one
  without, which pins when it starts to fire, and so its `for`, to within one evaluation: promtool
  evaluates the rules every `evaluation_interval` of the test file, 1m unless set;
- and, in a test group in which it fires, a case before it fires in which it stays quiet while
  every one of the group's `input_series` has a sample no older than the 5 minutes Prometheus looks
  back. That case need not be the one an evaluation before it fires: an alert on a series' absence
  is pending while the series is gone.

The own alerts, each with its runbook section in [docs/runbooks/alerts.md](runbooks/alerts.md):

| Alert | What it means | Severity | Runbook |
| --- | --- | --- | --- |
| `OpenBaoMemberSealed` | A member of OpenBao has not been Ready for 5 minutes, which means sealed. | warning | [OpenBaoMemberSealed](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#openbaomembersealed) |
| `OpenBaoNoActiveMember` | No target answers for the Service that selects OpenBao's active member for 5 minutes. | critical | [OpenBaoNoActiveMember](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#openbaonoactivemember) |
| `VolSyncSourceOutOfSync` | A ReplicationSource's volume has been out of sync for 30 minutes. | warning | [VolSyncSourceOutOfSync](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#volsyncsourceoutofsync) |
| `VolSyncSourceMissedIntervals` | A ReplicationSource missed a scheduled interval within the last hour. | warning | [VolSyncSourceMissedIntervals](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#volsyncsourcemissedintervals) |
| `CertManagerCertificateNotReady` | A Certificate has not been Ready for an hour. | warning | [CertManagerCertificateNotReady](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#certmanagercertificatenotready) |
| `CertManagerCertificateExpiringSoon` | A Certificate's certificate ends within 14 days, for 15 minutes. | warning | [CertManagerCertificateExpiringSoon](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#certmanagercertificateexpiringsoon) |
| `EtcdSnapshotStale` | No run of the etcd snapshot CronJob has succeeded for 13 hours. | critical | [EtcdSnapshotStale](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#etcdsnapshotstale) |
| `EtcdSnapshotJobFailing` | The etcd snapshot CronJob's latest scheduled run has not succeeded after 30 minutes. | warning | [EtcdSnapshotJobFailing](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#etcdsnapshotjobfailing) |
| `PostgresDumpStale` | No dump of a PostgreSQL database made from the component has succeeded for 36 hours. | warning | [PostgresDumpStale](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#postgresdumpstale) |
| `PostgresDumpJobFailing` | The latest scheduled run of a database's dump CronJob has not succeeded after an hour. | warning | [PostgresDumpJobFailing](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#postgresdumpjobfailing) |
| `PostgresWALArchivingFailing` | A PostgreSQL primary's latest attempt to archive a WAL segment has failed after its latest success, for 15 minutes. | critical | [PostgresWALArchivingFailing](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#postgreswalarchivingfailing) |
| `PostgresBackupTooOld` | A PostgreSQL cluster's newest base backup is older than 36 hours, or it has none and its oldest instance is older than that, for 30 minutes. | warning | [PostgresBackupTooOld](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#postgresbackuptooold) |
| `LogCollectorOutsizedShare` | One node's collector sends at least ten times the median node's rate of events, and at least 10 a second, for 30 minutes. | info | [LogCollectorOutsizedShare](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#logcollectoroutsizedshare) |
| `LogCollectorDiscardingEvents` | A collector's component discards events it was not set to drop, for 15 minutes. | warning | [LogCollectorDiscardingEvents](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#logcollectordiscardingevents) |
| `LogCollectorSendFailing` | A collector's sink has sent requests to the store and had none accepted, for 15 minutes. | warning | [LogCollectorSendFailing](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#logcollectorsendfailing) |
| `ExternalDNSSyncStale` | external-dns' last successful sync with the DNS provider is more than 10 minutes old, or no external-dns reports one, for 5 minutes. | warning | [ExternalDNSSyncStale](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#externaldnssyncstale) |
| `FluxRootSyncNotReady` | One of the root sync's three objects, the Kustomizations `flux-system` and `cluster` and the OCIRepository `flux-system`, has not been Ready for 10 minutes. | critical | [FluxRootSyncNotReady](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#fluxrootsyncnotready) |
| `FluxApplierNotReady` | A Kustomization or HelmRelease other than the root sync has not been Ready for 15 minutes, for a reason other than waiting for a dependency. | warning | [FluxApplierNotReady](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#fluxappliernotready) |
| `FluxSourceNotReady` | An OCIRepository, HelmRepository, HelmChart or ArtifactGenerator other than the root sync's has not been Ready for 15 minutes. | warning | [FluxSourceNotReady](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#fluxsourcenotready) |
| `FluxResourceSuspended` | A Flux resource, or the FluxInstance by its reconcile annotation, has been suspended for a day. | info | [FluxResourceSuspended](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#fluxresourcesuspended) |
| `FluxInstanceNotReady` | The FluxInstance has not been Ready for 10 minutes. | critical | [FluxInstanceNotReady](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#fluxinstancenotready) |
| `FluxOperatorNotReady` | The Flux Operator's Deployment has had no available replica for 5 minutes. | critical | [FluxOperatorNotReady](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#fluxoperatornotready) |
| `CiliumBGPSessionsDown` | A worker has had fewer BGP sessions established than it is configured for, for 5 minutes; a worker out of BGP on purpose has none configured. | warning | [CiliumBGPSessionsDown](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#ciliumbgpsessionsdown) |
| `CiliumBGPNoSessionEstablished` | No worker has an established BGP session, or none has a BGP instance, for 5 minutes, while a worker's agent is scraped. | critical | [CiliumBGPNoSessionEstablished](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#ciliumbgpnosessionestablished) |
| `DrbdReplicaNotUpToDate` | A DRBD replica that is not a diskless client has not been UpToDate for 15 minutes. | warning | [DrbdReplicaNotUpToDate](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#drbdreplicanotuptodate) |
| `DrbdResourceWithoutQuorum` | A DRBD device has had no quorum for 5 minutes. | critical | [DrbdResourceWithoutQuorum](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#drbdresourcewithoutquorum) |
| `LinstorSatelliteOffline` | LINSTOR has not seen a satellite online for 10 minutes. | warning | [LinstorSatelliteOffline](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#linstorsatelliteoffline) |
| `LinstorStoragePoolFilling` | A storage pool has been above 85 percent full, and at most 95, for 15 minutes. | warning | [LinstorStoragePoolFilling](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#linstorstoragepoolfilling) |
| `LinstorStoragePoolFull` | A storage pool has been above 95 percent full for 5 minutes. | critical | [LinstorStoragePoolFull](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#linstorstoragepoolfull) |
| `OpenBaoSnapshotStale` | No run of the OpenBao snapshot CronJob has succeeded for 13 hours. | critical | [OpenBaoSnapshotStale](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#openbaosnapshotstale) |
| `OpenBaoSnapshotJobFailing` | The OpenBao snapshot CronJob's latest scheduled run has not succeeded after 30 minutes. | warning | [OpenBaoSnapshotJobFailing](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#openbaosnapshotjobfailing) |
| `FalcoCriticalRuleMatched` | A Falco rule of priority Critical, Alert or Emergency has matched on a node within the last 15 minutes. | critical | [FalcoCriticalRuleMatched](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#falcocriticalrulematched) |
| `KyvernoAdmissionControllerDown` | Kyverno's admission controller has had no available replica for 10 minutes. | warning | [KyvernoAdmissionControllerDown](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#kyvernoadmissioncontrollerdown) |
| `GatekeeperControllerManagerDown` | Gatekeeper's controller manager has had no available replica for 10 minutes. | warning | [GatekeeperControllerManagerDown](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#gatekeepercontrollermanagerdown) |
| `CrowdSecLocalAPIDown` | CrowdSec's local API's target has not answered its scrape for 10 minutes, or has no series. | warning | [CrowdSecLocalAPIDown](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#crowdseclocalapidown) |
| `RestoreDrillStale` | No check of an application's restore drill has passed for 36 hours. | warning | [RestoreDrillStale](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#restoredrillstale) |
| `RestoreDrillJobFailing` | The latest scheduled check of an application's restore drill has not passed after 30 minutes. | warning | [RestoreDrillJobFailing](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#restoredrilljobfailing) |
| `PublicEndpointDown` | The probe of a public hostname through the Gateway gets no answer for 5 minutes. | critical | [PublicEndpointDown](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#publicendpointdown) |
| `PublicEndpointWrongStatus` | The probe of a public hostname is answered with a status it does not accept for 5 minutes. | critical | [PublicEndpointWrongStatus](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#publicendpointwrongstatus) |
| `PublicCertificateExpiring` | The certificate the Gateway serves for a public hostname expires within 14 days, and not within 3, for 10 minutes. | warning | [PublicCertificateExpiring](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#publiccertificateexpiring) |
| `PublicCertificateExpiryImminent` | The certificate the Gateway serves for a public hostname expires within 3 days, for 5 minutes. | critical | [PublicCertificateExpiryImminent](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#publiccertificateexpiryimminent) |
| `ProbeNotRunning` | A declared probe of a public hostname has not been scraped through the exporter for 10 minutes. | warning | [ProbeNotRunning](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#probenotrunning) |

The alerts read only what Prometheus scrapes: kube-state-metrics' pod readiness for OpenBao's
members, its Deployment availability for the Flux Operator, its nodes' roles, which tell the
control planes' Cilium agents from the workers', and its CronJob metrics for the etcd snapshot job
([cluster.md](cluster.md#scheduled-etcd-snapshots)), for the OpenBao snapshot job
([Raft snapshots](#raft-snapshots)) and for the dump job of every PostgreSQL cluster ([Dumps](#dumps)), Prometheus' own `up` for OpenBao's active Service and the Cilium agents, VolSync's
controller metrics, Vector's internal metrics, cert-manager's certificate metrics, the Flux
Operator's state of Flux's resources, the Cilium agents' BGP session state, LINSTOR's own metrics,
the DRBD reactor's, Falco's counter of the matches of each rule, external-dns' gauge of its last
successful sync and its absence, the metrics of the PostgreSQL instances and the Barman Cloud
plugin, which the component's PodMonitor scrapes, with kube-state-metrics' creation times of their
pods ([PostgreSQL](#postgresql)), Prometheus' own `up` of CrowdSec's local API, and the blackbox
exporter's probe metrics ([Probes](#probes)). The
PostgreSQL alerts, on the archive and the base backups and on the dumps, are written once, in the
`cloudnative-pg` application's `app/`, whose tests are `tests/rules/cloudnative-pg.yaml`. The dump
alerts select the CronJobs by their names' suffix, `-pgdump`: kube-state-metrics exposes no CronJob
label unless its chart is told to, so a label the component set would not reach the metrics.
`tests/rules-check.bats` fails when an alert reads a metric that no monitor of the render scrapes,
or whose monitor selects nothing of the Service or pod that serves it.

The two policy engines' alerts read kube-state-metrics' Deployment availability for each engine's
admission controller ([Admission policy](#admission-policy)).

The restore drill's alerts read kube-state-metrics' CronJob metrics for the check job of every
application that takes the drill ([The restore drill](#the-restore-drill)). They are written once,
in the `volsync` application's `app/`, whose tests are `tests/rules/volsync.yaml`, and select the
CronJobs by their names' suffix, `-drill-check`, as the dump alerts select theirs.

What no alert covers, and why:

- A Service's address announced by fewer than two workers: Cilium's metrics give the number of
  routes advertised on each session and no address, so an address that one worker has stopped
  announcing is not told apart from another announced twice.
- Flux's controllers' own metrics are scraped, and no alert reads them: a controller that is down
  shows in the state of the resources it reconciles, and in `just cluster-check`'s pods.
- What the Piraeus operator's own alert rules cover and these do not
  ([Storage monitoring](#storage-monitoring)), as those rules are not loaded: a DRBD connection that
  is not connected; a suspended DRBD resource (`drbd_resource_suspended`); a storage pool that
  reports errors (`linstor_storage_pool_error_count`); the LINSTOR controller's and the satellites'
  error reports; the LINSTOR controller's target and a satellite's DRBD reactor target being down,
  which also leaves the alerts on what they serve quiet; and whether a resync progresses, as a
  replica that resyncs raises `DrbdReplicaNotUpToDate` after 15 minutes whether it progresses or
  not. A volume none of whose replicas is UpToDate raises `DrbdReplicaNotUpToDate`, a warning, for
  each replica, and no critical alert of its own.
- The Cilium operator, Envoy and Hubble, which nothing scrapes.
- Falco's kernel buffers dropping events, and one Falco target down on a cluster of ten nodes or
  more, either of which leaves `FalcoCriticalRuleMatched` quiet for that node
  ([Runtime detection](#runtime-detection)). Falco has no alert of its own for its pods: one
  missing from a node raises the stock `KubeDaemonSetRolloutStuck` or `KubeDaemonSetNotScheduled`,
  for any DaemonSet short of its nodes, and a target Prometheus has that does not answer raises the
  stock `TargetDown`, a warning, once more than a tenth of the job's targets have been down for 10
  minutes, which is one target on a cluster of fewer than ten nodes.
- The OpenFeature Operator, which has no alert of its own: both of its webhooks fail open, no
  workload asks for a sidecar and the tree applies no flag set, so nothing is missed while it is
  down or slow ([OpenFeature Operator](#openfeature-operator)). A manager whose scrape fails raises
  the stock `TargetDown`, as its job has one target.

#### Where alerts go

Alertmanager sends a critical or warning alert to a notification webhook, and the Watchdog, the
stock alert that always fires, to a heartbeat URL, so that whoever watches the heartbeat learns
that Prometheus or Alertmanager has stopped from its silence. Which services stand behind the two
addresses is the deployment's choice: each address is a value an operator writes to the secret
store, the tree holds neither, and until both are there nothing leaves the cluster.

**The routes.** Alertmanager's configuration is `alertmanager.config` in the values of
`kube-prometheus-stack`, written out whole, so that what the chart renders into its Secret is
those values and nothing of the chart's own configuration is merged in. An alert takes the first
route that matches it, and every route groups by `alertname` and `namespace`:

| Alert | Receiver | First sent after | Flushed every | Repeated after |
| --- | --- | --- | --- | --- |
| the Watchdog (`alertname = "Watchdog"`) | `heartbeat` | at once | 1m | 5m, so a beat every 6m (below) |
| a `severity` of `critical` or `warning` | `notify` | 30s | 5m | 12h |
| any other: an `info` alert, the info inhibitor | `null`, which sends nothing | | | |

The Watchdog's route comes first and does not continue, so the Watchdog reaches `heartbeat` alone
whatever severity it carries; the wait, the interval and the repeat of `notify` are the chart's
own. The inhibit rules are the chart's four, as it ships them: a critical alert mutes the warning
and info alerts of its name and namespace, a warning the info alerts, the info inhibitor the info
alerts of its namespace, and any other alert the info inhibitor. An `info` alert reaches no
receiver: it shows in Prometheus' and Alertmanager's interfaces and nowhere else. No
`AlertmanagerConfig` object is in the tree: the chart's Alertmanager selects them in every
namespace and the operator puts their routes before these, so one would change the route tree the
checks below read, and `tests/alert-routes.bats` refuses one in the render or in an application's
`app/`.

**The receivers.** `notify` and `heartbeat` are each one generic webhook and nothing else: the
configuration holds no address, no credential and no client setting. Each reads its address from a
file, at every notification: `/etc/alertmanager/destinations/notify-url` and
`/etc/alertmanager/destinations/heartbeat-url`. `notify` is told when an alert resolves;
`heartbeat` is not, as the notification that would follow the Watchdog's end is no beat.
Alertmanager trims the file's content and reads it as one of its notification templates, so `{{`
in an address starts a template.

**The Secret.** The two files are the keys of the Secret `alert-destinations` in `monitoring`,
which the Alertmanager mounts whole and read-only at `/etc/alertmanager/destinations`, as an
optional volume: the pod starts while the Secret does not exist, with an empty directory, and the
kubelet puts the files in once it does, without a restart. The operator's own list of Secrets to
mount, `secrets`, is not used, as it makes the volume required: no Alertmanager would run until the
store held both addresses. `apps/base/monitoring/alert-destinations/` is the one ExternalSecret
that writes the Secret, from the properties `notify-url` and `heartbeat-url` of
`monitoring/alert-destinations` in the store, by two `data` entries, so the Secret holds those two
keys and nothing else the entry may hold. Its Kustomization names `openbao-store` in `dependsOn`,
which names `external-secrets`, whose chart brings the `ExternalSecret` kind; it does not wait, and
nothing names it in `dependsOn`, so a store without the addresses stalls no Kustomization and no
release. An operator writes the two, each typed or piped in ([The recipes](#the-recipes)):
`just bao-put monitoring/alert-destinations notify-url` and
`just bao-put monitoring/alert-destinations heartbeat-url`. Each is written exactly as its service
gives it, with `https://`: Alertmanager follows redirects, and Go's HTTP client turns a POST that
is answered with a 301, 302 or 303 into a GET without a body, so an `http://` address of a service
that redirects to `https://` reaches it with no alerts.

Both must be there before either works: External Secrets fails the whole ExternalSecret while a
property it names is missing (`SecretSyncedError`), and writes no Secret. It reads a failing
ExternalSecret again after a delay that doubles from a second up to seven minutes; the kubelet
puts a Secret that appears into a pod's volume within its sync period, a minute by default, which
the tree leaves as it is, and the moment its watch takes; and Alertmanager reads the file at the
group's next flush, a minute for the heartbeat and five for a notification that is waiting. So the
first beat can leave up to about nine minutes after the second `bao-put`, and the first
notification up to about thirteen. An address changed in the store reaches the pod the same way,
within the ExternalSecret's refresh interval of 15 minutes and the kubelet's minute, and the next
notification is sent to it. `secret-rotation.yaml` lists the path as `issued`, so
`just secret-rotate` refuses both keys
([Rotating an application's secret](#rotating-an-applications-secret)): a new address is made at
its service and written with its `just bao-put` command above.

**What a notification carries.** Alertmanager POSTs the JSON its documentation gives for a
webhook (`version` 4): the receiver, the status, the group's key and labels, why it is sent
(`notification_reason`, such as `first notification`), the labels and annotations its alerts
share, its own address in the cluster (`externalURL`,
`http://kube-prometheus-stack-alertmanager.monitoring:9093`) and, for each alert, its status, every
label, every annotation, when it started and ended, its fingerprint and the address of its
expression at Prometheus in the cluster (`generatorURL`, under
`http://kube-prometheus-stack-prometheus.monitoring:9090/graph`). So whoever runs the destination
reads the names of namespaces, pods, nodes, containers and jobs, the addresses in `instance`
labels, the `prometheus` label that names the Prometheus the alert came from, and each rule's
summary, description and runbook link. The heartbeat's body has the same form and holds the
Watchdog alone.

**The heartbeat's time.** The Watchdog's group is flushed at once and then every minute. A flush
sends a beat when the last one is more than five minutes old, by the time Alertmanager wrote it to
its notification log, which it does once the destination has answered. The fifth flush after a
beat comes five minutes after the flush that sent it, which is a moment before the beat was
written, so it sends nothing and the sixth sends the next: a beat leaves every six minutes. The
longest gap between two beats while everything works is six minutes, so a heartbeat monitor expects
a beat every six minutes and allows twelve, twice the longest gap, before it reports. A beat that
cannot be sent is tried again within its flush and then at every flush, a minute apart.

**Until the addresses are there.** Alertmanager runs, and each notification fails at once on the
file it cannot read: its log says `read url_file: open
/etc/alertmanager/destinations/notify-url: no such file or directory` for the receiver, and the
failure counts in `alertmanager_notifications_failed_total` for the integration `webhook`. Two
stock alerts read that counter against `alertmanager_notifications_total` over fifteen minutes:
`AlertmanagerFailedToSendAlerts`, a warning, and `AlertmanagerClusterFailedToSendAlerts`, critical
(the chart's other rule of that name, a warning, selects no integration and never fires). Both
fire once failures have held for their five minutes, so about five minutes after the first
notification fails, the Watchdog's, and stay firing until the addresses are there; they show in
the interfaces alone, as they cannot be sent either. They are left to fire, being true. They clear
about fifteen minutes after the last notification failed, so the destination gets both as firing
among its first notifications and their resolution after. When they fire later, a notification
fails again. Look at the ExternalSecret's status
(`kubectl --namespace monitoring get externalsecret alert-destinations`), at the keys the Secret
holds, without their values (`kubectl --namespace monitoring describe secret alert-destinations`),
and at Alertmanager's log (`kubectl --namespace monitoring logs
alertmanager-kube-prometheus-stack-alertmanager-0 --container alertmanager`), whose lines `Notify
failed` and `Notify attempt failed, will retry later` name the receiver and say why: `read
url_file` for a file that is missing, `dial tcp` for a destination that refuses the connection or
whose name does not resolve, `unexpected status code` for one that answers with an error. A
destination that refuses the connection or answers with a server error is tried again until the
group's next flush and counts as a failed notification then; one that answers with a client error
fails at once.

**Where an address is.** In the secret store, in the Secret `alert-destinations` and in the file in
the pod. It is in no file of this repository, and neither in Alertmanager's configuration nor on
its status page, which hold the file's path. Where a request fails, the URL in the error is
replaced by `<redacted>`: the log never holds an address whole, and of its path and its query only
what stands between `{{` and `}}`. What the log can hold is the host and that: a destination that
refuses the connection is named by the address and port dialled, one whose name does not resolve
by that name, an address that is no URL by the piece the parser rejects, and an address whose
template fails by what is between the braces, which the error names before any request is made.
A destination that answers with an error is logged with the status and the body it answered. So a
token belongs in the path or the query of an address, never in its host name or between `{{` and
`}}`.

**The checks.** `just alerts-route-check`, in the `static` group of `just ci`, renders the
application as Flux and helm-controller build it, takes the configuration from the Secret the one
rendered Alertmanager reads, and runs amtool and Alertmanager on it, from the image the chart
deploys: `alertmanager_image` in the justfile, by tag and the digest of its image index, which
Renovate moves in the pull request that moves the chart, and which the check and
`tests/alert-routes.bats` hold to the image the render names. `just alerts-route-check` runs them
in a container of that image with no network, a read-only filesystem and no capability; `just ci`
copies the two binaries into the tools container, where they bind and dial the loopback alone.
`amtool check-config` must accept the configuration. Then each case of
`tests/alert-routes/cases.yaml`, one for each scenario of `features/alert-routes.feature` that the
check proves, runs and is printed with its verdict. amtool resolves the receivers of an alert
(`amtool config routes test`); one Alertmanager on the loopback serves the cases amtool cannot:
that a critical alert inhibits the warning of its name and namespace and no other; that
Alertmanager, started with no file at either path, becomes ready, fails each notification on its
file and counts every notification it attempted as failed, so that an Alertmanager that one day
refuses to start without the files fails a pull request and not the cluster; and that a silence
made through the API the silence operator uses suppresses an alert on its way to `notify` and
leaves the Watchdog active. A case of a kind the check does not know fails it. Each run then
proves its own refusals: a configuration amtool refuses, a route case whose expectation is wrong
and an inhibition case whose expectation is wrong must each fail it.

`tests/alert-routes.bats` holds the rest, without Docker: that the rendered configuration is the
values', with the keys at every position the set that was read against the operator's own types at
the operator version the chart runs, as the operator parses the configuration strictly and writes
its own serialisation for Alertmanager, so a key that is no field of those types stops it; that
the keys the ExternalSecret writes, the volume the Alertmanager mounts and the files the receivers
read agree; the application, its overlay entry and what waits for what; and that every alert rule
of the tree's render, the charts' and the tree's own, has a severity of `critical`, `warning` or
`info`, or is the Watchdog or the info inhibitor, as an alert with any other would end at `null`
unseen.

#### Silences

An alert that is known and accepted for a while is silenced by a reviewed change that says why and
until when, not in Alertmanager's interface, whose silences nobody reviews and which go with its
volume. `apps/base/monitoring/silence-operator/` installs the silence operator from its publisher's
chart, `oci://gsoci.azurecr.io/charts/giantswarm/silence-operator`, in `monitoring`: one replica,
restricted, with requests and a memory limit, and the chart's PodMonitor on. It has no route and no
interface. It turns each `Silence` object into a silence in the cluster's Alertmanager, at
`http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093`, the Service of the
monitoring chart whose selector names the chart's Alertmanager and picks the pods
prometheus-operator makes for it, on the port that leads to Alertmanager's web port, and holds no
credential for it: Alertmanager asks for none, so the operator's authentication is off and its
service account's token goes to the Kubernetes API only, where it reads the `Silence` objects of
every namespace. Its chart binds it, through one ClusterRoleBinding to its own service account, to
a ClusterRole that grants every verb on `Silence` objects (both API groups) and on Leases, in every
namespace, and `create` on events, and nothing else;
`tests/silences.bats` compares each rule, with its API groups, resources, resource names,
non-resource URLs and verbs, any aggregation, and the binding. Its definitions are not an
application of their own in `kube-system` like the other definitions that several applications use
([Resource definitions](#resource-definitions)): only the operator reads them, so they ship with its
release, as templates of the chart that the release keeps when it goes, the way
`snapshot-controller` ships its definitions with its controller. The application waits for the
release, so an application that names it in `dependsOn` finds the definitions in place, and
`kubernetes-check` refuses that name in a cluster whose overlay does not enable the operator.
Alertmanager is not a dependency: the operator is Ready without it and tries again until it answers.
Its metrics are scraped; no alert reads them, so a silence that fails to sync shows in the
operator's log and in `controller_runtime_reconcile_errors_total`, which the operator's dashboard
graphs ([Dashboards](#dashboards)), and raises nothing.

**Where one lives.** In the `app/` of the application under `apps/base` whose alert it silences,
in that application's namespace and listed in its `kustomization.yaml`, with `silence-operator` in
the application's `dependsOn`. It is reviewed with that application and leaves with it, and a
silence for an alert of a chart sits beside the application that installs the chart, as a file of
its own, not in the chart's values. A cluster-level application under `clusters/<cluster>/` holds
none. The tree ships none: none is true today, and the Watchdog, which is meant to fire, is never
silenced, as a silenced Watchdog sends no beat and so stops the heartbeat
([Where alerts go](#where-alerts-go)).

```yaml
apiVersion: observability.giantswarm.io/v1alpha2
kind: Silence
metadata:
  name: <name>
  namespace: <the application's namespace>
  annotations:
    k8s-gitops/reason: <why the alert is accepted>
    k8s-gitops/issue: <ISSUE-KEY>
spec:
  endsAt: "<RFC 3339 time>"
  matchers:
    - name: alertname
      value: <alert>
      matchType: "="
```

`tests/silences.bats` reads the `Silence` objects of two places: the render that
`pod-security-check` and `kubernetes-validate` read (`scripts/render`: the root, Flux's own
applications and each Kustomization they apply whose source is the cluster's artifact, built by
`flux build` with the components it adds, and every object each HelmRelease of those builds renders
from its chart, with the values of the ConfigMaps Flux builds for its own application), and the
`app/` of every application under `apps/base`, built by kustomize whether the overlay enables it or
not. A Kustomization whose source is a `GitRepository`, a `Bucket` or an `OCIRepository` other than
the cluster's `flux-system` is not followed, and no object a controller makes from another at run
time is in the render. It refuses a `Silence` that is not the namespaced
`observability.giantswarm.io/v1alpha2` kind (the `monitoring.giantswarm.io/v1alpha1` kind is
cluster-scoped, and so belongs to no application); has no `k8s-gitops/reason`; has neither
`spec.endsAt` nor a `k8s-gitops/issue` of the form `ABC-12`; has no `alertname` matcher with `=`,
or any `alertname` matcher of another kind, so the alert is named exactly and no silence is wider
than one alert; or silences the Watchdog.
`spec.duration` and the `valid-until` annotation, from which the operator also takes an end, do not
count as one: a silence that uses them needs an issue as well. It also refuses a `Silence` of the
render that is not a resource of the `app/` of the application under `apps/base` that applies it:
one a chart renders, from its values or its templates; one a component adds; and one the cluster
directory, the overlay, a namespace's directory or a cluster-level application applies. And it
refuses three constructions the render does not expand as the cluster would, so that no `Silence`
goes unread in them: an object whose kind ends in `List` and that has `items`, which Flux applies
as objects of their own; a HelmRelease's `valuesFrom` entry that is `optional` or names no object
Flux builds for its application, whose values the render leaves out; and a Flux Kustomization,
HelmRelease or source that a chart renders, which the render does not follow. The check catches a
silence added by mistake or carelessly; a change that hides one on purpose is for the pull
request's review to catch.

**How it ends.** At `spec.endsAt` the silence ends in Alertmanager, and the operator does not make
it again; the object stays until a change removes it, which a change should do. A silence with an
issue and no `spec.endsAt`, `spec.duration` or `valid-until` annotation lasts until its object goes:
the operator ends such a silence a hundred years after the object was created. Removing the object,
which Flux prunes once the change merges, removes the silence: the operator holds each `Silence`
with the finalizer `observability.giantswarm.io/silence-protection`, deletes the silence from
Alertmanager and then lets the object go, so the removal waits while the operator is down and while
Alertmanager does not answer, as the operator fails the deletion unless Alertmanager says the
silence is gone. A removal that waits stalls the pruning of the application that holds the
`Silence`, as the root waits for termination. If Alertmanager's volume is lost, the silences come
back when the operator reconciles their objects again, which restarting it does and its periodic
resync does in time.

**A hand-made silence.** The operator finds the silences it made by their comment,
`silence-operator-<namespace>-<name>`. It reads every silence in Alertmanager, a hand-made one
included, and acts only on one whose comment is exactly one of those. A silence made in
Alertmanager's interface with any other comment is left alone: the operator changes and removes
nothing of it, and it lasts until it ends or the volume is lost. A hand-made silence with exactly
such a comment is taken for the operator's own: it is updated to match its object and, once the
object's `spec.endsAt` has passed, expired. Only the removal of an object passes over a silence
made by hand, as it finds its silence by comment and by the creator `silence-operator`; a silence's
creator is free text in Alertmanager, so a hand-made one given both is removed with the object.

### Dashboards

A dashboard is configuration: its JSON is in the tree and is loaded into [Grafana](#grafana) by a
`GrafanaDashboard`, which the Grafana operator applies. Nothing is fetched when it is loaded: no
dashboard uses the operator's `url`, `grafanaCom`, `oci` or Jsonnet sources or asks for a plugin,
and the tree's checks fetch none either. The cost is that an upstream dashboard is a copy: it is as
large as its JSON, it changes only when someone takes the file again, and a new release of what
it describes does not reach it by itself. What the tree records for each makes that a step of the
pull request that moves the release.

**Where one lives.** A dashboard that describes an application is an application of its own,
`apps/base/monitoring/<application>-dashboard/`, named after the application whose monitor feeds
it: `app/grafanadashboard.yaml`, or one `grafanadashboard-<name>.yaml` each where it holds two, with
the JSON in `app/dashboards/<name>.json`, which the application's `kustomization.yaml` turns into a
ConfigMap with a `configMapGenerator`, with `kustomize.toolkit.fluxcd.io/substitute: disabled` so
Flux leaves the `${...}` of Grafana's variables alone, and a `kustomizeconfig.yaml` that writes the
ConfigMap's hashed name into the `GrafanaDashboard`'s `configMapRef`. It is in `monitoring` because
the operator acts there only ([Grafana](#grafana)) and an application's `targetNamespace` puts
everything it applies in its own namespace. It sits beside no monitor, alert rule or controller,
not even those of an application whose namespace is `monitoring`, because a `GrafanaDashboard`
needs `grafana-operator` in `dependsOn`: beside them, the monitors, the alerts or the controller
would wait for the Grafana operator, and stay away while it does not come up. The dashboard's
application names the one it describes and `grafana-operator` in `dependsOn`. The one it describes
waits (`wait: true`), as `just kubernetes-check` requires of every dependency, and the check fails
for a cluster that enables the dashboard without it, so a dashboard leaves with its application. A
dashboard goes with the application whose monitor feeds it: the Cilium agents' with
`cilium-monitoring` and the storage layer's with `linstor-monitoring`, not with `cilium` or
`piraeus-operator`.

Two applications keep a dashboard beside their own manifests. The Grafana application has the
instance's own, the logs dashboard and the cluster's home: `grafanadashboard-logs.yaml`, whose JSON
is a ConfigMap, and `grafanadashboard-home.yaml`, whose JSON is in the object. The log store,
`victoria-logs`, has its own dashboard beside its release, and so names `grafana-operator` in
`dependsOn`.

The `GrafanaDashboard` selects the Grafana by its label `app.kubernetes.io/instance: grafana`,
loads into a folder of the `Folder` column below, which its `spec.folder` names (the operator
files a dashboard that names none under its namespace, `monitoring`), and is applied again every
minute, as the datasource is. The operator finds a folder by its title, whatever its case, and
makes one only when none has it, and it reconciles one dashboard at a time, so two dashboards that
name one folder are in one folder (`GetOrCreateFolder` and `GetFolderUID` in
`controllers/dashboard_controller.go` of grafana-operator v5.25.0). It identifies a dashboard by
its `uid`, and takes one of another `uid` with the same title in the same folder for it, which it
then removes, so a title is unique in its folder. It sets the `id` a file carries, as Cilium's and
Falco's do, to null before it sends the dashboard (`getContentModel` in
`controllers/content/resolver.go`). Flux applies the ConfigMap server-side, so no annotation of
the last applied state has to hold the JSON: the limit is the 1 MiB a ConfigMap holds, and the
largest, the Cilium agents', is 284 KB.

**What the tree records.** Beside each upstream dashboard's `GrafanaDashboard`, in comments: the
`Source:` URL of the file at a revision, its `Licence:`, its `SHA-256:`, a record line
`# dashboard-<name>: <revision>` and, where the pinned chart's archive carries the file,
`# Chart-path:`, the file's path inside the chart. The file is kept as upstream publishes it, so
the SHA-256 is that of the committed file. The `Source:` is the file that `tests/dashboards.bats`
pins for the dashboard, a path (`UPSTREAM_PATHS`) of the repository it pins
(`UPSTREAM_REPOSITORIES`), at a tag that holds the revision, so a copy in another repository, or
another file of the same one, is refused. With a
`Chart-path`, the test compares the committed bytes with that file of the chart it pulls at the
pinned tag, and the revision is the `version` of the `Chart.yaml` of the chart directory that
holds the file: the chart's own for Cilium's, Falco's and OpenBao's, and that of `charts/cluster`
for CloudNativePG's, a chart of the project's `grafana-dashboards` repository that the operator's
chart carries as a dependency. Without one, as for the Piraeus operator's and VictoriaLogs', whose
charts do not carry the file, the revision is the release of what it describes that the pinned
chart is at, the chart's own version or its application's. The chart that pins what
`cilium-monitoring` describes is that of `cilium`, and for `linstor-monitoring` that of
`piraeus-operator`. The licence is one under which the file may be copied into this tree, which is
Apache-2.0: `Apache-2.0`, `MIT`, `BSD-2-Clause`, `BSD-3-Clause` or `MPL-2.0`. Renovate moves none
of it: each record is a row of `.renovate/by-hand.tsv`, which `just renovate-pins` checks.

**The tree's own.** Where a project publishes no dashboard at the pinned version, or none under
such a licence, the dashboard is written here and has no record. cert-manager, external-dns and the
silence operator publish none. The Flux Operator publishes two, `config/monitoring/dashboards/` of
its repository, under AGPL-3.0, and a file under that licence is not copied into this tree. The
Cilium chart's dashboards have no panel of the BGP sessions. Each of the five is small, at most ten
panels, and reads the metrics the alerts and this document name, and beyond them only metrics found
in the pinned source, which `tests/fixtures/dashboards/metric-sources.tsv` cites. Each has the
name of its `GrafanaDashboard` as `uid`, is not editable, declares no input, and has one variable,
`datasource`, which lists the datasources of type `prometheus`, as the home has, and which every
panel names, and no other: Grafana puts the text of any other variable in a query with no more
escaped than its backslashes and apostrophes, or, for a variable of several values, its backslashes
and the characters of a regular expression, and adds an ad hoc filter to every query of its
datasource (`interpolateQueryExpr` and `enhanceExprWithAdHocFilters` of `@grafana/prometheus`
13.1.2, which Grafana v13.1.3 pins), so either could select by a name or a job the checks do not
read. It matches
a job only by a literal that a monitor of the render gives, and names every label bare: Prometheus 3
also takes a label's name in quotes, with PromQL's escapes, so a quoted name may be `job` however it
is spelt. It holds no address, hostname or identifier: a legend may show a label whose value is an
address, as `neighbor` of the BGP sessions is, and that value is in Prometheus alone. cert-manager's
tables show the label `exported_namespace` as a Certificate's namespace: the chart's ServiceMonitor
scrapes without `honorLabels`, so Prometheus keeps `namespace` for the controller's own. The names
of the five are pinned in `tests/dashboards.bats` (`OWN_DASHBOARDS`): any other dashboard outside
the Grafana application carries the records above.

**Adding or updating one.** For an upstream file: take it from the pinned chart's archive, at its
`Chart-path`, or, where the chart does not carry it, fetch it from the source at the revision of
the pinned chart; put it in `dashboards/<name>.json` unchanged; write the record lines and the
by-hand row; map every input it declares (below); and name where each metric it reads comes from in
`tests/fixtures/dashboards/metric-sources.tsv`; its repository is added to `UPSTREAM_REPOSITORIES`
in `tests/dashboards.bats`, the file's path in it to `UPSTREAM_PATHS`, and a file the chart carries
to `CHART_CARRIED`. For one written here:
keep to what the paragraph above says of the five, and add its name to `OWN_DASHBOARDS`. Either
way the application is added to `DASHBOARD_APPS` in `tests/dashboards.bats`, to the overlay and to
the catalogue ([Backstage](#backstage)), and the dashboard gets its row in the table below. When
Renovate moves the chart, the tests fail until the file is taken again at the new release and the
record, the source, the hash and the revision in the table's row move with it, in the same pull
request. CloudNativePG's record is the version of the chart `cluster` that the operator's chart
carries, so its tests fail only when a new chart carries another `cluster` or another file in it.

**What runs, and what each is for.** A dashboard an application delivers is named with its
`GrafanaDashboard` in backticks. Describes names the applications whose monitors feed it. Folder is
where Grafana lists it.

| Dashboard | For | Describes | Source, revision, licence | Folder | Datasource |
| --- | --- | --- | --- | --- | --- |
| Kubernetes, nodes, API server, kubelet, controller manager, scheduler, etcd, CoreDNS, Prometheus, Alertmanager, Grafana | The cluster and the stack's own components | `kube-prometheus-stack`, `grafana` | The monitoring chart's own, as [Grafana](#grafana) describes, at the monitoring application's chart version; Apache-2.0 | Kubernetes | Prometheus |
| Cluster health, the home (`cluster-home`) | Nodes Ready, firing alerts by severity, scrape targets down, volumes VolSync reports out of sync and scheduled syncs it missed, and the log store's ingest | The cluster as a whole | Written for this tree; Apache-2.0 | General | Prometheus |
| Logs (`logs`) | Log volume by namespace and by node, and the logs of the namespaces and pods chosen | The logs of every namespace | Written for this tree; Apache-2.0 | Logs | VictoriaLogs |
| VictoriaLogs - single-node (`victoria-logs`) | The log store's ingestion, storage, queries and resource use | `victoria-logs` | `dashboards/victorialogs.json` of the VictoriaLogs repository at v1.54.0, the release the pinned chart deploys; Apache-2.0 | Logs | Prometheus |
| OpenBao (`openbao`) | The members, tokens, leases, requests and runtime | `openbao` | `grafana/dashboards/dashboard.json` of the OpenBao chart at 0.30.7; MPL-2.0, whose text is at https://mozilla.org/MPL/2.0/ | OpenBao | Prometheus |
| Certificates (`cert-manager`) | The Certificates that are not Ready, and the time left to each certificate's end, soonest first | `cert-manager` | Written for this tree; Apache-2.0 | cert-manager | Prometheus |
| Flux (`flux`) | The FluxInstance's and the operator's state, the resources by kind and readiness, those not Ready with their reason and those suspended, and the controllers' reconciles, errors and reconcile time | `flux-monitoring` | Written for this tree; Apache-2.0 | Flux | Prometheus |
| Cilium Metrics (`cilium-agent`) | The agents' processes, API, BPF, datapath, policy, endpoints, controllers and Kubernetes client | `cilium-monitoring` | `files/cilium-agent/dashboards/cilium-dashboard.json` of the Cilium chart at 1.20.4; Apache-2.0 | Cilium | Prometheus |
| Cilium BGP sessions (`cilium-bgp`) | The sessions established against those configured for each node, each session's state, the routes advertised and the agents scraped | `cilium-monitoring` | Written for this tree; Apache-2.0 | Cilium | Prometheus |
| Piraeus Datastore (`piraeus`) | LINSTOR's pools, nodes, resources and error reports, the volumes' read and write rates, and DRBD's connections, quorum and out-of-sync data | `linstor-monitoring` | `config/extras/monitoring/piraeus-dashboard.json` of the Piraeus operator's repository at v2.12.1, the release the pinned chart deploys; Apache-2.0 | Storage | Prometheus |
| CloudNativePG (`cloudnative-pg`) | A PostgreSQL cluster's instances, their health, configuration, activity, storage, write-ahead log, replication and checkpoints, and the operator's reconciles | `cloudnative-pg`, and the clusters of `n8n`, `backstage` and `ascender` | `charts/cluster/grafana-dashboard.json` of the CloudNativePG chart, where it is the chart `cluster` at 0.0.5; Apache-2.0 | PostgreSQL | Prometheus |
| Falco (`falco`) | The rules that matched, by rule, source and priority, Falco's memory and CPU, the events it reads and drops, and the versions and engines that run | `falco` | `dashboards/falco-dashboard.json` of the Falco chart at 9.2.2; Apache-2.0 | Falco | Prometheus |
| external-dns (`external-dns`) | The age of the last successful sync and of the last attempt, the endpoints of the sources and of the registry, their errors and the verified records by type | `external-dns` | Written for this tree; Apache-2.0 | external-dns | Prometheus |
| Silence operator (`silence-operator`) | Whether the operator is scraped, its reconciles and errors by controller, the reconcile time and the queue depth | `silence-operator` | Written for this tree; Apache-2.0 | Silences | Prometheus |

The `Grafana`'s `spec.preferences.homeDashboardUid` names the home dashboard's `uid`, which is how
the operator sets an instance's home. VolSync exposes whether a volume is out of sync and how many
scheduled syncs were missed, and no time of the last sync, so those are what the home shows of a
backup's age. It has no panel of the public Gateway, whose proxies no monitor scrapes and whose
hostnames the probes' alerts read ([Probes](#probes)), or of Flux, which has a dashboard of its
own: Flux's alerts are among the firing alerts it counts.

**Scraped, without a dashboard.** The tree holds no dashboard of these applications; what their
monitors scrape is in Prometheus, where a query reads it:

| Application | Scraped by |
| --- | --- |
| `blackbox-exporter` | Its chart's ServiceMonitor, of the exporter itself; what it probes reaches Prometheus through the Probes ([Probes](#probes)) |
| `crowdsec` | Its chart's two ServiceMonitors, of the local API and the agent ([CrowdSec](#crowdsec)); the chart carries no dashboard, and CrowdSec's `grafana-dashboards` repository, under MIT, has no tag to pin and says its newest dashboards are for v1.5 releases, older than the one the chart runs |
| `descheduler` | Its chart's ServiceMonitor |
| `gatekeeper` | The application's own PodMonitor, of the audit pod and the controller managers ([Admission policy](#admission-policy)) |
| `grafana-operator` | Its chart's ServiceMonitor; the chart can also make a dashboard of the operator, with `dashboard.enabled`, which stays off |
| `keda` | Its chart's three ServiceMonitors, of the operator, the metrics API server and the admission webhooks |
| `kromgo` | The ServiceMonitor its chart makes for its metrics port ([Status badges](#status-badges)) |
| `kubelet-csr-approver` | Its chart's ServiceMonitor |
| `kyverno` | Its chart's two ServiceMonitors, of the admission controller and the reports controller ([Admission policy](#admission-policy)) |
| `metrics-server` | Its chart's ServiceMonitor |
| `open-feature-operator` | The application's own PodMonitor, of the manager ([OpenFeature Operator](#openfeature-operator)); the operator's repository, under Apache-2.0, and its chart hold no Grafana dashboard at the pinned version |
| `reloader` | Its chart's PodMonitor |
| `spegel` | Its chart's ServiceMonitor |
| `vpa` | Its chart's PodMonitor, of the recommender |

**Missing a scrape or an upstream.** Each of these has no dashboard, because it would show "No
data" or no upstream file exists to copy:

| Component | Missing |
| --- | --- |
| The Cilium operator, Envoy and Hubble | Their ServiceMonitors, which stay off ([Monitoring](#monitoring)) |
| The Piraeus operator | A monitor of the operator itself: the render holds none; `linstor-monitoring` scrapes only the LINSTOR cluster the operator makes |
| Envoy Gateway and its proxies, the public Gateway's among them | A monitor of the controller and of the proxies the Gateway starts: the render holds none |
| External Secrets | Its ServiceMonitors, which the application leaves off |
| `vector` | An upstream file: Vector's repository and its chart hold no dashboard at the pinned version. The log store's chart carries one for Vector, `files/dashboards/generated/vector-k8s-monitoring.yaml`, as a template it renders with `dashboards.enabled`, which stays off, and not as a file to commit unchanged |
| `volsync` | An upstream file: VolSync's repository and its chart hold no dashboard at the pinned version; the home shows what it reports of a backup's age |

**What stays empty here.** An upstream file is written for more than this cluster runs, and is
kept unchanged, so some of its panels have nothing to show, and a few show what means nothing
here. These are the ones found by reading each file's queries against what the pinned releases
serve and the render configures:

- Cilium Metrics. Under its heading kvstore, the two panels of the number of operations read
  `kvstore_operations_total`, a name no metric of the agents has at Cilium v1.20.4; the three
  others, the latency and the events received, read the agents' kvstore metrics, which they report
  only for a key-value store, and the cluster configures none: identities are custom resources. The
  four panels of BPF system calls read `cilium_bpf_syscall_duration_seconds`, which the agents
  leave off unless `prometheus.metrics` turns it on, and the values do not.
- Falco. Scap Drops CPU reads the per-CPU counters, which Falco serves only with
  `kernel_event_counters_per_cpu_enabled`, and the chart's default, which the values keep, is off.
  The second query of Scap events by instance over time reads `falcosecurity_falco_n_evts_total`,
  a name Falco 0.45.2 does not serve: the first query, on `falcosecurity_scap_n_evts_total`, is the
  one that draws.
- Piraeus Datastore. Scrape Duration, in the DRBD row, selects the satellites by the job that the
  PodMonitor beside the file in the operator's repository gives, `<namespace>/linstor-satellite`.
  The monitor of `linstor-monitoring` names the job `linstor-satellite`, as its alerts match it, so
  the panel is empty.
- CloudNativePG. The tree's clusters archive their WAL continuously and take a base backup every
  day through the Barman Cloud plugin ([Backups and restores](#backups-and-restores)), and have no
  volume for the WAL alone and no tablespace. PostgreSQL hands every WAL file to the instance
  manager, which passes it to the plugin and, with a WAL-archiving plugin enabled, does nothing more
  (`internalRun` in `pkg/management/postgres/archiver/archiver.go` of CloudNativePG v1.30.1), so
  Last archived WAL and, in the Write Ahead Log row, WAL Segment Archive Status, Archiver Status
  [5m] and Last Archive Age show the archive as the plugin keeps it. Last Base Backup and First
  Recoverability Point at the top show N/A, and the panel of the Backups row is empty, although
  base backups exist. An instance reports the time of the last backup and the first point of
  recoverability from the `Cluster`'s status fields `lastSuccessfulBackup` and
  `firstRecoverabilityPoint`, as zero while they are empty (`setTimestampMetric` and the collectors
  after it in `pkg/management/postgres/webserver/metricserver/pg_collector.go`), and those fields
  are deprecated and not set for a backup plugin (`api/v1/cluster_types.go`): only the in-tree
  `barmanObjectStore` and volume snapshots set them (`UpdateBackupTimes`, called in
  `pkg/management/postgres/backup.go` and `internal/controller/backup_controller.go`). The plugin
  reports a backup's times under names of its own,
  `barman_cloud_cloudnative_pg_io_last_available_backup_timestamp`,
  `barman_cloud_cloudnative_pg_io_first_recoverability_point` and
  `barman_cloud_cloudnative_pg_io_last_failed_backup_timestamp` (`internal/cnpgi/instance/metrics.go`
  of plugin-barman-cloud v0.16.0), which the file does not read: the age of the newest base backup
  is read from them, by `PostgresBackupTooOld` ([Alerts](#alerts)) or in a query. In the Storage &
  I/O row, Volume Space Usage: Tablespaces is empty, and the two panels of PGDATA and WAL show the
  data volume alone.
  The Zone column of the Server Health row is empty: it reads the nodes' label
  `topology.kubernetes.io/zone` from kube-state-metrics, which exports a label of a node only
  where its `metricLabelsAllowlist` names it, and the monitoring chart's values name none.
- OpenBao. Consul Requests, in the Audit row, reads the metrics of the Consul storage backend, which
  OpenBao v2.7.2 does not have: the members store in Raft.

None was found in VictoriaLogs' own: every metric it reads is one the pinned release defines.
Two of the files hold panels of a type Grafana 13 does not ship: five of Piraeus' and thirteen of
OpenBao's are of the type `graph`, and one of OpenBao's is a pie chart of a plugin. Grafana turns
each into a panel it ships when it loads the dashboard (`getPanelPluginToMigrateTo` in
`public/app/features/dashboard/state/` and `GetAngularPanelMigration` in
`apps/dashboard/pkg/migration/schemaversion/migration_utils.go` of Grafana v13.1.3), so none needs
a plugin.

**Inputs and datasources.** An upstream file may declare the datasources it reads as inputs, in its
`__inputs`, and its `GrafanaDashboard`'s `spec.datasources` maps every input of type `datasource`,
and nothing else, to a datasource of the plugin the input names. Before it loads the dashboard, the
operator replaces every `${<input>}` in the JSON with the name it is given, as text, and changes
nothing else (`resolveDatasources` in `controllers/content/resolver.go`). Grafana's frontend
resolves a reference by uid and then by name (`getInstanceSettings` in
`public/app/features/plugins/datasource_srv.ts` of Grafana v13.1.3) and sends each query with the
uid of the datasource it found (`DataSourceWithBackend` in
`packages/grafana-runtime/src/utils/`), so the name is enough where the browser runs a dashboard's
queries, which is how every dashboard here is read. No check of the tree runs Grafana, so none
proves that fallback: a panel of OpenBao's or CloudNativePG's dashboard that shows data does, and is
the one to read again when Grafana moves. Grafana's server finds a query's datasource by its uid, or
by its id where the query gives no uid, and never by its name (`getDataSourceFromQuery` in
`pkg/services/query/query.go`), so a query the server were given as a dashboard stores it, with a
name in the place of the uid, would find none. The
Prometheus `GrafanaDatasource` sets no `spec.uid`, Grafana gives it one of its own, and the
operator's definition lets none be added to an object that exists. OpenBao's panels name
`${DS_PROMXY}` and CloudNativePG's `${DS_PROMETHEUS}`, so they name Prometheus by its name.
CloudNativePG's file declares a second input, `DS_EXPRESSION`, of the plugin `__expr__`, for one
target that computes a number from four queries: it is mapped to `__expr__`, the uid by which
Grafana takes a query for one of its own expressions (`DatasourceUID` in `pkg/expr/service.go`),
and no datasource of the tree stands behind it. VictoriaLogs' panels read the variable
`$DS_PROMETHEUS`, without braces, which the operator leaves as it is: the variable lists the
datasources of type prometheus, and only its current value becomes Prometheus. The Cilium, Falco
and Piraeus files declare no input and map none: each has a variable that lists the datasources of
type `prometheus`, of which the tree has one, whatever value the file saved for it.

Not every reference in a file is read. Grafana runs no query for a row, so the datasource a row
names, and that of the placeholder target a row carries, lead nowhere without harm: nine rows of
CloudNativePG's file name the uid `prometheus`, which no datasource has. A target is run against
its panel's datasource where the panel names one that is not the mixed one, whatever the target
itself names, unless the target is an expression: one target of Falco's file names that same uid in
a panel whose datasource is the variable (`transformSingleQuery`, `convertToRowsLayout` and
`buildRowKind` in `apps/dashboard/pkg/migration/conversion/v1_to_v2alpha1.go`, by which Grafana
converts a stored dashboard when it serves it; its frontend does the same where it runs the
queries of a dashboard it loaded unconverted, in `SceneQueryRunner` of `@grafana/scenes` 8.2.6).
Every other reference must lead to a datasource: a panel's, a variable's, an annotation's, and a
target's under a panel that names none.

`tests/dashboards.bats` builds the applications that deliver a dashboard as Flux applies them and
checks that every `GrafanaDashboard` the cluster's render holds is one of theirs or the monitoring
chart's, whatever its file is named. For each it checks that it is in the namespace the operator
watches, selects the Grafana, names its folder, is applied every minute and has its JSON in the
tree, unsubstituted; that every application but the Grafana's and the log store's is named after
the one it describes, which waits; and that an overlay without the application it describes has
none of its dashboards and a cluster that keeps the dashboard without it is refused. It checks that
no dashboard uses a source that fetches or asks for a plugin, that every panel is of a type Grafana
ships or turns into one, that each dashboard outside the Grafana application loads a ConfigMap and
is one of the five written here or has the records above, with a licence of the list and a source
in the repository pinned for it, and that the render holds a monitor of the application it
describes; that a file its record places in the pinned chart is that chart's file, byte for byte,
at the version of the chart directory that holds it, and that no other upstream file is one its
chart carries. It checks that every dashboard of the tree, the monitoring chart's included, has a
`uid` no other has and a title no other in its folder has, maps exactly the datasource inputs its
JSON declares, each to a datasource of the input's plugin or, for an expression input, to
`__expr__`, and, with its inputs replaced as the operator replaces them, leads every reference
Grafana reads to a datasource: a variable that lists the type of one the tree defines, the name or
`uid` of one, or one of Grafana's own: the expression datasource, and `-- Grafana --`,
`-- Mixed --` and `-- Dashboard --`, the names `getList` in `datasource_srv.ts` adds to those
configured, and no other name between dashes. Of the five written here it checks the `uid`, the
title, that it is not editable, that it defines no variable but the one every panel and target
names, that it declares no input, the number of panels, that it holds no address, hostname or
identifier, that it names no label or metric in quotes, and its job matchers, with the value in any
of PromQL's quotes and comments anywhere inside the braces, against the jobs the render's monitors
give. It checks that
the Cilium agents' monitor copies the pods' label, with the value Cilium's dashboard matches; that
a ConfigMap, or a `GrafanaDashboard` carrying its JSON, holds at most 1 MiB, which it proves
refuses a padded dashboard; and that the three tables above name every dashboard an application
delivers, with its folder, what it describes and, for an upstream file, the revision and the
licence of its record, and every application whose render holds a monitor in exactly one of them.

It also checks that every dashboard the tree keeps as JSON queries only metrics the cluster
scrapes. It reads the `expr` of every panel's targets, those of the panels inside rows too, and of
every annotation, and the query of every variable of type `query`, and fails, naming the dashboard
and the metric, unless each metric is written by a recording rule of the render or named by a row
of `tests/fixtures/dashboards/metric-sources.tsv`: the dashboard, a metric name as an anchored
regular expression, and where the metric comes from, a monitor of the render, or one of several
where the monitors of the PostgreSQL instances come and go with the applications that have a
database, `any-monitor` for a series Prometheus writes for every target, `alerting-rule` for the
one it writes for every alert, or `none`, with the reason, for a metric an unchanged upstream file
reads that nothing serves. The rows of a dashboard are tried in order. The check also fails for a
row whose monitor the render lacks, for a metric its monitor drops, for a row that names nothing
its dashboard reads, and, in one of the five written here and in the home, for a row that is not
one literal name with its monitor. Its parser takes out comments and strings, read in one pass
from the left so that each ends where PromQL ends it, label matchers, ranges, variables and the
label lists of `by`, `without`, `on`, `ignoring` and the group modifiers, and reads every identifier
left that is not a function or one of PromQL's own words as a metric. It refuses an expression that
names a metric or a label in quotes, as Prometheus 3 allows: a quoted label may be `__name__`. What
it cannot see:

- It is by name. Which target serves a metric is the table's claim; label matchers are not
  checked, but for the job matchers of the five, in any of PromQL's quotes, and the label
  Cilium's dashboard selects by; and a metric a feature would emit passes while the feature is
  off.
- A metric name that a variable completes is read only where the variable holds one fixed text, a
  constant or a text box with a default, which is put in its place, as `${metrics_prefix}` of
  OpenBao's file is. A name any other variable completes or stands for is not read, nor is a
  selector that matches `__name__` by a regular expression; one with `=` and a literal is. The
  table pins how many such expressions a dashboard has, as `unread:<n>` with the reason: ten of
  OpenBao's, whose names the variable `mountpoint` completes with a mount of the store, and four of
  CloudNativePG's, which select the checkpoint metrics of either PostgreSQL version by a regular
  expression on the name. The five written here and the home may have none. A variable stands for
  a name wherever it stands outside a string, a range, a label list and an offset, but for
  Grafana's own, `$__...`, and so inside a selector's braces too, as a whole matcher, a label's name
  or a value without quotes: Grafana puts a whole matcher that a variable of one value holds in as
  it is (`prometheusRegularEscape` of `@grafana/prometheus` 13.1.2), so `{$m}` may be
  `{__name__="..."}`. One that stands for a number, as the first argument of `topk`, is counted as
  one that stands for a name. A dashboard that defines a variable of such a name, `__` and more, is
  refused. The five written here and the home define no variable but their datasource. A variable
  inside a string is read as the string: Grafana escapes no double quote of a variable's value
  (`prometheusRegularEscape` and `prometheusSpecialRegexEscape`, with Grafana v13.1.3's default
  feature toggles), so in an upstream file, which its hash pins, a value with one may end the
  string, and what follows it is not read.
- A series a recording rule writes needs no row, and what the rule reads is not followed.
- A target of a datasource that is not Prometheus is not read, as the LogsQL of the logs dashboard
  is not, nor are the monitoring chart's own dashboards, which `tests/grafana.bats` holds to the
  chart and its values. The datasource is the one Grafana finds: the one whose `uid` or name the
  reference's `uid` is, whatever `type` it gives with it, and one of its `type` only where it gives
  no `uid` (`get` in `datasource_srv.ts`). A reference the check cannot place is read.
- A variable's query is read as `label_values(<selector>, <label>)`, `query_result(<query>)` or a
  selector, as a string or under `.query`; `label_values(<label>)` and `label_names()` name no
  metric; any other form is refused, naming the variable.
- A monitor drops a metric when a `metricRelabelings` rule on `__name__` alone, of any of its
  endpoints, of the action `drop` matches the whole name or of the action `keep` does not,
  whatever the case of the action, which the monitors' definition admits in either; a rule that
  gives no `regex` has Prometheus' default, `(.*)`. A rule on more labels than the name is not
  read.

### Status badges

kromgo (`apps/base/kromgo/kromgo/`) serves a few numbers about the cluster as badges, so they can be
shown without giving anyone Prometheus. Its configuration names each badge and the one PromQL query
it runs; a request names a badge and gets one number or word back, as an SVG, or as JSON with
`?format=json` (kromgo's own) or `?format=shields` (shields.io's endpoint schema). It runs from the
publisher's image, `ghcr.io/home-operations/kromgo`, pinned by tag and digest, in the app-template
chart as n8n does ([Applications](#applications)): two pods, never on one node, under a disruption
budget of one, as a non-root user with a read-only root filesystem, no capability and the runtime's
seccomp profile, requests and a memory limit, and the configuration mounted read only. It holds no
credential and no volume: Prometheus is reached by the Service of the stack,
`kube-prometheus-stack-prometheus.monitoring.svc:9090`, which takes none, and the pod mounts no
token of its service account. Its own metrics are on a port of their own (`8081`), scraped by a
`ServiceMonitor` the chart makes, and no route names that port.

**Where it is.** `kromgo.${CLUSTER_DOMAIN}` on the public Gateway's `https` listener ([Giving an
application a public hostname](#giving-an-application-a-public-hostname)); the route sends only the
paths under `/badges/` to kromgo, unchanged, as it has no filter, so its index page and its health
endpoints answer the Gateway's 404. external-dns publishes the name, as it does for every route on
the Gateway ([DNS records](#dns-records)). The namespace is `kromgo`, its own, labelled
`k8s-gitops/gateway: public`, as the badges are public and no sign-in covers their route.
`monitoring` carries the label too, for the log store's route alone, and holds Prometheus,
Alertmanager and Grafana, so `tests/logs.bats` fails for any route there on the Gateway that the
cluster's sign-in does not cover ([The log store's interface](#the-log-stores-interface)); the
namespace is privileged too, for node-exporter and the log collector. The own namespace is small,
enforces `restricted`, and is one more entry in the set of namespaces that carry the label, which
`tests/gateway.bats` pins. A cluster selects kromgo with two entries of its overlay, the namespace
directory and the application's `ks.yaml`; the application waits for the Prometheus Operator's
definitions, the Gateway, Cilium, whose kind its network policy is, and the blackbox exporter, which
answers its route's `Probe`, and is Ready once both pods are (`wait: true`), which is once kromgo
has read its configuration and listens: a configuration it refuses keeps the application from Ready.
It queries the stack's Prometheus at each request, not at start, so a badge answers with an error
until Prometheus does, and the stack's application is not waited for.

**What it may reach.** The namespace denies ingress and egress by default, and the policy beside
the application, `app/ciliumnetworkpolicy.yaml`, lets kromgo's flows through and no other
([Network policy](#network-policy)): in, the public Gateway's proxies and the kubelet's probes on
8080 and Prometheus' scrape on 8081; out, the cluster's resolver and the pods of the Service its
`KROMGO_PROMETHEUS_URL` names, `kube-prometheus-stack-prometheus` in `monitoring`, on 9090. The
proxies' own egress names kromgo's pods on 8080 alone, so the metrics port is Prometheus' alone.
Pointing kromgo at another Prometheus moves the egress rule with it: `tests/network-policy.bats`
reads the URL, the Service it names and that Service's selector and target port from the render,
and fails until the rule reaches them.

**The list.** A badge is `/badges/<id>`; the ids are these, and no other is served:

| id | What it shows | Where it comes from |
| --- | --- | --- |
| `kubernetes_version` | the API server's version | `kubernetes_build_info` of the API server's monitor |
| `talos_version` | the Talos version of the nodes | `node_os_info` of node-exporter |
| `cluster_node_count` | nodes | `kube_node_info` of kube-state-metrics |
| `cluster_pod_count` | pods that run | `kube_pod_status_phase` of kube-state-metrics |
| `cluster_age_days` | days since the oldest node was created, which a replaced node does not reset until it is the oldest left | `kube_node_created` of kube-state-metrics |
| `cluster_cpu_usage` | the nodes' mean CPU use, in percent | the chart's recording rule `instance:node_cpu_utilisation:rate5m` |
| `cluster_memory_usage` | memory in use of all the nodes', in percent | `node_memory_*` of node-exporter |
| `firing_alerts` | alerts that fire, `Watchdog` and `InfoInhibitor` left out, which fire to show the pipeline works and to inhibit info alerts | `ALERTS` |

Flux is not on the list. The Flux Operator's `flux_instance_info`, which `flux-monitoring` scrapes
([Flux monitoring](#flux-monitoring)), holds the version only in its `revision` label, with the
distribution's digest after it (`v<version>@sha256:<digest>`): a badge would keep that label or take
the version out with `label_replace`, and the rules below allow neither. While nodes run two Talos
or Kubernetes versions, as during an upgrade, the version badges show one of them.

**A badge's URL** is the cluster's domain from `cluster-config` with the path appended:
`https://kromgo.<CLUSTER_DOMAIN>/badges/<id>`. Nothing in this repository shows one, so none
holds the deployment's hostname; whoever embeds a badge writes the URL with their own domain. kromgo
answers a badge with `Cache-Control: public, max-age=300, s-maxage=300`, so a browser or a shared
cache between it and the reader, such as an image proxy, may serve it for five minutes. kromgo itself
keeps no result: every request that reaches it runs the badge's query.

**No request names a query.** kromgo 0.16.3's router serves `/badges/{id}` and `/graphs/{id}`, an
index page, its assets and, when configured, a favicon (`Handler.Mux` in `internal/kromgo/handler.go`).
Prometheus is queried from three places, the badge's and the graph's handlers and the range badge's
window (`internal/kromgo/instant.go`, `internal/kromgo/graph_query.go`), and each passes the query
the configuration gave the endpoint, found by the `id` of the path. An `id` the configuration does
not hold is answered before any query (`serveBadge`: `h.badges[id]`) with a Not Found error: a red
error badge with status 200 in the SVG form, so an image shows the error, and 404 in the JSON forms
(`errorResponse` in `internal/kromgo/response.go`). The other parameters choose the
output format, the badge's style and, for a graph, a window, and are never put into a query. The
configuration defines no graph, which would serve a range of its query, and turns the gallery off,
which would list the badges. `tests/kromgo.bats` fails unless this document names the image's
pinned version after the word kromgo, as "kromgo 0.16.3's router" above does, so whoever moves the image reads the router
and the three call sites again and writes the new version here, and unless `config.yaml` names the
schema of that version.

**Nothing names a node.** The JSON form of a badge returns the labels of the series its query read,
so every query keeps no label but a version: each selector is inside a `count`, `sum`, `avg`,
`min` or `max` that has no `by` but `version_id` or `git_version`, and no query relabels or
joins, or matches on a node, a pod, a namespace or an address. `tests/kromgo.bats` reads the text of
each query for that and fails on a bare selector, a `by (node)`, a matcher on `instance`, its label
name bare or quoted, or a `label_replace`; it cannot see what a version label holds. It also fails
on a dotted name, as a hostname is, in any value of the configuration and in the strings of its
queries and expressions; a name without a dot is not seen.

**Adding a badge.** Add an entry to `config.yaml` under `badges:` with an `id` of letters, digits and
`._-`, a `title`, a query that keeps no label but a version, and `valueExpr` and `colorExpr`
(kromgo's CEL expressions) for what it shows. Then add its id to `BADGES` in `tests/kromgo.bats`, a
row in the table above, and, for a metric the file `tests/fixtures/kromgo/metric-sources.tsv` does
not name, its row there: the monitor of the render that scrapes the target that serves it, or
`alerting-rule`. A metric a recording rule of the render writes needs no row. The test fails when a
metric of a query has none, when a monitor named there is not in the render, and when the ids of the
configuration are not the pinned ones. The check is by name: it cannot see that the target serves
a metric, which the row states, nor the labels a matcher selects. The test also checks the file
against the schema kromgo publishes at the image's tag, which `config.yaml` names, with helm,
offline: a field kromgo does not know or a badge without its query fails, as kromgo refuses both at
start. kromgo also compiles each expression at start, which no schema describes: a configuration
with one it cannot compile passes the test and keeps both pods, and so the application, from Ready.

**Limits.** kromgo does not limit requests and keeps no result, so every badge request that reaches
it runs one query on Prometheus; only a cache downstream of kromgo saves one. The edge routers admit
only the networks the edge stack allows
([The edge routers](infrastructure.md#the-edge-routers)), which bounds who can ask. A rate limit on
the route would be a `BackendTrafficPolicy`, which `tests/gateway.bats` would have to admit: it holds
the Gateway's `ClientTrafficPolicy` to be the one policy on the Gateway or on a route attached to it.

### Probes

`apps/base/monitoring/blackbox-exporter/` runs the Prometheus community's blackbox exporter in
`monitoring`, from its chart on the community's OCI registry, for the checks of what the cluster
serves to the outside. It names `prometheus-operator-crds`, for its `ServiceMonitor` and
`PrometheusRule` and the `Probe` kind of the applications that declare one, and `cluster-ca`, for
the certificate below, in `dependsOn`, and sets `wait`, so what declares a `Probe` and names it
starts once the exporter runs. Two replicas, never on one worker, under a budget of one; small
requests and no limits; the restricted Pod Security level, from the chart's defaults and the
runtime's seccomp profile; its own metrics through the chart's `ServiceMonitor`. Its chart's tag is
a pin Renovate moves.

**What waits for the exporter.** `gateway-public` and every application that declares a `Probe` name
`blackbox-exporter` in `dependsOn`, and `external-dns` waits for the Gateway. Flux reads a
dependency's readiness when the dependent reconciles, at its interval or on a change, and applies
the dependent only while what it names is Ready. While the exporter's Kustomization is not, as when
its release has failed or its chart cannot be fetched, no change to the Gateway or to an
application with a route is applied from its next reconcile, and none to `external-dns` once
`gateway-public` has reconciled since: each reports `DependencyNotReady` and keeps what it has
applied, so nothing that runs is stopped, and a cluster built from nothing has no Gateway until the
exporter runs. A release that fails is retried three times
([What the root sets](#what-the-root-sets)) and is then Stalled until its failure count is reset,
which helm-controller does when the release's chart or values change, and
`flux reconcile helmrelease blackbox-exporter -n monitoring --reset` does by hand.

The exporter has three modules, and the chart's own `http_2xx` is switched off:

- `public_https`: a GET over TLS that must be answered 200, is not redirected, and fails when the
  answer is not over TLS or its certificate does not verify against the trust of the cluster's
  issuer, which under staging verifies nothing (**Trust**, below).
- `public_https_signin`: the same, for a route behind the cluster's sign-in, but the answer must be
  302, the redirect that starts a sign-in, which it does not follow (**Behind sign-in**, below).
- `public_http_redirect`: a GET over plain HTTP that must be answered 301, which it does not follow.

**What is probed, and from where.** An application declares a `Probe` beside its route ([Giving an
application a public hostname](#giving-an-application-a-public-hostname)): `hello-route` has one for
`hello.${CLUSTER_DOMAIN}`, `n8n` one for `n8n.${CLUSTER_DOMAIN}` at n8n's health endpoint
`/healthz`, kromgo one for `kromgo.${CLUSTER_DOMAIN}` at the badge `/badges/cluster_node_count`,
`open-webui` one for `open-webui.${CLUSTER_DOMAIN}` at Open WebUI's readiness endpoint `/health/db`,
which answers 200 without a session once its database does, `dex` one for `dex.${CLUSTER_DOMAIN}`
at its discovery document `/.well-known/openid-configuration`, which dex serves on its http port
without a session once it runs with its configuration, `oauth2-proxy` one for
`auth.${CLUSTER_DOMAIN}` at its readiness endpoint `/ready`, which it answers before it looks for a
session and which, with the cookie session store, checks no connection, `backstage` one for
`backstage.${CLUSTER_DOMAIN}` at Backstage's readiness endpoint `/.backstage/health/v1/readiness`,
a `GET` its route admits, which answers 200 without a session once every plugin has started, each
having migrated its schema in the database, `ascender` one for `ascender.${CLUSTER_DOMAIN}`
at its ping endpoint `/api/v2/ping/`, which answers 200 without a session once the
web pod reads the database, `hello-sso` one for `hello-sso.${CLUSTER_DOMAIN}` at
`/` and `victoria-logs-route` one for `logs.${CLUSTER_DOMAIN}` at the interface `/select/vmui/`,
each with the module that expects the sign-in redirect (**Behind sign-in**, below), and
`gateway-public` one for the redirect, which is probed for the apex of the domain, as the redirect
takes any host. Backstage's endpoint does not ask the database again once Backstage has started, so
its probe proves the database at Backstage's start, not since. kromgo's
route sends only the badge paths, and kromgo answers a badge in its SVG form with a 200 whether its
query succeeds or not, an id it does not serve included ([Status badges](#status-badges)), so its
probe proves the route and kromgo, not Prometheus, and
`tests/probes.bats` holds the badge to one the configuration serves; each probe runs that badge's
query once. Every `Probe` sets the job name `public-endpoints`, which the alerts
select, names the exporter's Service as its prober, and has one target, the Gateway's proxies'
Service by its cluster name, with the hostname as a label, which a relabeling turns into the URL
parameter `hostname`. For that parameter the exporter sets the `Host` header and, as no module has
a `server_name`, the name the TLS handshake asks for and verifies. So the request is the one a
client of the hostname makes, and it reaches the proxies by the cluster's DNS and the Service's
address, without the hostname being resolved at all: nothing leaves the cluster, nothing depends on
public DNS, the edge routers or the floating addresses, and no address is written anywhere. The
proxies' Service is the one Envoy Gateway makes, named
`envoy-<namespace>-<name>-<the first 8 characters of the SHA-256 of "<namespace>/<name>">` after the
Gateway's namespace and name, in the controller's own namespace whichever namespace the Gateway is
in, here `envoy-envoy-gateway-system-public-5ea56ca9` in `envoy-gateway-system`; the controller
derives the name, `tests/probes.bats` derives it again, the namespace from the controller's
Deployment in the render, and fails when a `Probe` names another, and the `EnvoyProxy` could not set
a name of its own without changing what `tests/gateway.bats` pins of its Service. The controller
makes the Service at run time, so no render holds its name: the test's rule for it was read in the
controller's source at the version the test records, and for a controller of another version, or one
configured to deploy the proxies in each Gateway's namespace, where they take another name, the test
fails until the rule is read again there, as one that named the Service otherwise would pass every
other check and fail every probe at the name's resolution. The two other ways were weighed
and left: a cluster-internal resolution of the public hostnames to the Gateway would be a rule in
the cluster's DNS for every hostname, which no application of the tree owns, or the Service's
address written into the exporter's pods, which the tree does not write; and the hostname as the
target alone goes out through public DNS. That shape, the exporter as the prober and the proxies'
Service as every target, with the one relabeling, is the one the node firewall's test accepts of a
`Probe`, as it refuses any other ([cluster.md](cluster.md#the-node-firewall)).

**What it proves, and what it does not.** A passing probe of a route proves the Gateway's proxies
are up and take connections on 443, the listener serves a certificate that verifies for the
hostname, the route is accepted and its backend answers 200. It proves the redirect on 80 the same
way. It does not prove the way in from outside: the edge routers, their translation to the Gateway's
address, BGP, the Service's external address and public DNS, which stay `just gateway-check`'s
([Checking the public Gateway](#checking-the-public-gateway)). The probe goes to the Service's
cluster address, not the announced one. Each probe is a connection of its own, which the Service
gives to one of the proxies, so a probe proves one proxy at a time: with one of the two failing
while it is still Ready, about every other probe fails and the others pass. An alert that needs
every probe to fail for 5 minutes then fires only on a run of failures that long, which comes by
chance and rarely, and resolves at the next probe that passes.

**Behind sign-in.** A route that a `SecurityPolicy` with external authorisation targets
([Sign-in](#sign-in)) is probed with `public_https_signin`. The probe has no session, so the
proxies ask oauth2-proxy, which answers with the 302 to dex that starts a sign-in, as
`skip_provider_button` is set and the probe's request is no AJAX one (`Proxy` and `doOAuthStart` in
`oauthproxy.go` of the pinned v7.15.6), and the proxies send that answer back. A passing probe
proves the proxies, the certificate, the route, the policy in its path and oauth2-proxy answering;
not the backend behind it, which `hello-route`'s probe of the same backend covers, nor dex, which
dex's own probe covers. The day the policy is lost and the backend answers anyone, the answer is a
200 and `PublicEndpointWrongStatus` fires. So the probe asks for a path the backend answers 200:
`/` of `hello-sso`, and the interface of `logs`, not its root, which the route itself redirects with
a 302 that would pass the probe with the policy lost. The sign-in paths on the same host, the
routes `hello-sso-oauth2` and `logs-oauth2` that `components/sso` adds and no policy covers, are
covered by the host's one `Probe`: the probes are of hostnames, and the probe meets the route the
policy covers.

**While an application is not running**, the probe of its route fails, and it is
`PublicEndpointWrongStatus` that fires, not `PublicEndpointDown`: the proxies answer the probe
themselves, 503 for a backend with no pod ready, and 403 for a route behind sign-in while
oauth2-proxy cannot answer, as the policy does not fail open. A `Probe` is applied with its route,
by its application's Kustomization, which Flux applies once those it names in `dependsOn` are Ready.
So on a new cluster the alert fires for an application whose pods wait for a secret the owner writes
to the store, from 5 minutes after it is applied until the secret is there: n8n, for its encryption
key ([n8n](#n8n)); dex, for the GitHub client; and after dex oauth2-proxy, for the list of
identities, as its route and its `Probe` are applied only once dex is Ready. `hello-sso` and
`victoria-logs-route` wait for oauth2-proxy in the same way, so their probes meet the redirect from
their first run
([What the owner does, in order](#what-the-owner-does-in-order)). A route whose application takes
longer than the alert's 5 minutes to start, as Backstage on its database's first start, raises it
until it answers.

**Its way through network policy.** The exporter's pod resolves the Service's cluster name with the
cluster's resolver and connects to its cluster address; the Cilium agents translate that address to
a proxy's before policy applies and keep the pod as the source, so the proxies see the exporter's
pod in `monitoring`, not `world`, on the container port of the listener: 10443 for https, 10080 for
the redirect. `envoy-gateway-system` denies by default, and the proxies' policy `public-proxy` takes
the exporter's pods on those two ports, by the labels the exporter's chart gives them, in a rule of
their own beside the world's; from there the proxies reach the backend by the rule of its route, as
for any client ([What the namespaces let through](#what-the-namespaces-let-through)). `monitoring`
is listed, so the exporter's own egress is open and Prometheus' requests to it pass.
`tests/network-policy.bats` reads the ports from the target of every `Probe` of the render and the
exporter from their prober's Service, and fails unless the exporter's pods reach the proxies on each
and no other pod of the render or of the operators is taken there. While the cluster audits, a line
of `just network-drops` from a `monitoring/blackbox-exporter-…` pod to an
`envoy-gateway-system/envoy-envoy-gateway-system-public-…` pod on `10443/tcp` or `10080/tcp` means
that rule does not match the exporter's pods, as after its chart changed their labels; once the
cluster enforces, such a flow is dropped and every probe raises `PublicEndpointDown`.

**The PROXY protocol.** The listeners accept a PROXY protocol header as `optional` ([The public
Gateway](#the-public-gateway)), and the exporter writes none: its connection begins with the TLS
handshake or the HTTP request, which the listeners serve with the exporter's pod as the client. The
probes are a sender the rule above admits that writes no header, which is one reason the header
stays optional: a policy that required it would reset every probe, and `tests/probes.bats` fails,
saying the probes would be cut, when the Gateway's `ClientTrafficPolicy` requires the header while a
`Probe` reaches the listeners from inside the cluster. Before the header is required, the probes
must reach the listeners another way, through the edges, which write it.

**Trust.** The probe verifies the certificate against the trust of the issuer the cluster chooses
for the Gateway's certificate ([Choosing the public Gateway's
issuer](#choosing-the-public-gateways-issuer)), the cluster's own CA or production, and does not
verify it under staging, whose chain no client trusts. The `HelmRelease` adds to the exporter's
shared values those of that issuer, the key `<issuer>.yaml` of a ConfigMap made from `app/trust/`,
which the variable `PROBE_ISSUER` names, `cluster-ca` when it is not set. A cluster that chooses an
issuer sets `PROBE_ISSUER` to the same name in a patch of the Kustomization `blackbox-exporter` in
its overlay, beside the patch of `gateway-public` that sets `PUBLIC_ISSUER`. The name is written
twice, as a patch reaches one Kustomization and a replacement from the Gateway's would break the
overlays that leave the Gateway out; `tests/probes.bats` fails for every cluster of the tree whose
render has the Gateway's certificate from one issuer and the probes trusting another.

- `cluster-ca`, the default: the `ca_file` of both modules over https is the authority's public
  certificate, which reaches the exporter through a `Certificate` of its own application, issued by
  the same issuer: cert-manager puts the issuing authority's certificate in the `ca.crt` of the
  Secret it makes for it, and the exporter mounts that one key, never the Secret's private key, and
  never `cert-manager`'s Secret of the authority, whose key does not leave that namespace. The
  `Certificate` itself is for nothing. Reflector, which would copy a whole Secret, key included, and
  a trust bundle controller, which the tree does not have, are the other ways, and neither is
  simpler.
- `letsencrypt-production`, which `lab-sto2` chooses: the system's roots of the exporter's image, as
  a client outside has them. The modules name no CA of their own and nothing is mounted; the
  exporter's `Certificate` is applied all the same, as the application is the same on every cluster,
  and nothing reads its Secret.
- `letsencrypt-staging`, which a new cluster starts on: none. No client trusts its chain, so its
  values make both modules over https skip verification, `insecure_skip_verify: true`, their one
  setting, and nothing is mounted. The probe still needs a TLS answer from the proxies with the
  status the module takes, and the exporter still reads the expiry of the certificate served:
  `probe_ssl_earliest_cert_expiry` is the earliest end among the certificates the proxies send,
  whether verified or not (`prober/http.go` and `getEarliestCertExpiry` in `prober/tls.go` of the
  pinned v0.29.1), so `PublicEndpointDown`, `PublicEndpointWrongStatus` and both certificate
  alerts hold. What the probe does not catch under staging is a wrong certificate: Go skips the
  check of the name with that of the chain, so a certificate of any issuer, a self-signed one or
  one for another name is accepted. Under the cluster's own CA or production, a certificate for
  another name, or one the probe's trust does not verify, fails the handshake and raises
  `PublicEndpointDown`; that trust is the one authority under the cluster's own CA and every public
  one under production, where a certificate another public authority issued for the name passes, as
  for any client. So a wrong name or an untrusted chain is caught once the cluster moves to
  production.

No module skips verification under the cluster's own CA or production; under staging the values of
the two modules over https hold that one setting and no other module skips it. `public_https_signin`
verifies as `public_https` does under every issuer, and `tests/probes.bats` fails when their
`tls_config` differs. `just kubernetes-check` refuses a cluster that enables the exporter while the
Gateway's issuer or the probes' is one with no values in `app/trust/`, and names the file to add;
the release, which would find no values for it, fails rather than probe without them.
`tests/probes.bats` reads the issuer, the modules and the pod from what `scripts/render` makes of
the tree, `lab-sto2` as it is and copies that choose the cluster's own CA and staging.

**Every route has its probe.** `tests/probes.bats` reads the routes, the `Probe`s and the policies
from what `scripts/render` makes of the tree: every application the overlay enables as Flux builds
it, components and substitutions included, and every release as its chart renders it. A route or a
`Probe` that a chart makes from a release's values is therefore read as one a manifest declares, in
its release's namespace where the chart names none, and an object with a list of items, as a `List`
a chart renders, as those items, each an object, as Helm installs them; a route that a controller
makes at run time is in no render, and is not seen. The test fails, naming the route, when an
`HTTPRoute` of the public Gateway's https listener has a hostname that no `Probe` names, has no
hostname at all (it would serve every name under the listener), or the redirect has none. A `Probe`
counts when its job is `public-endpoints`, it goes to the exporter at the address of the Service its
release renders, it uses the module of its listener and hostname, its one target is the proxies'
Service and it sends its `hostname` label on as the parameter as it is: the last relabeling that
writes `__param_hostname` copies the label with the default regex and replacement, and no relabeling
writes another label, maps or drops labels, or keeps or drops the target. It counts only in the
shape `hello`'s has, those fields and no other, as each thing more is a way for a `Probe` that is
there not to probe: a path or a scheme of the prober asks the exporter for something else than a
probe, or over TLS it does not serve; an interval, a scrape timeout or metric relabelings of its own
can stretch the probe to once a day, cut every scrape short or drop its series; a second target can
leave the cluster; a label beside `hostname` can be one Prometheus reads as a setting of the scrape;
and a relabeling to another label, which runs after the operator's own, can send the scrape or the
probe elsewhere or take it out of the job the alerts read. The module of a hostname on the https
listener is `public_https_signin` when a route of that hostname is the target, by `targetRefs` or
`targetRef`, of a `SecurityPolicy` with external authorisation, and `public_https` otherwise;
`tests/gateway.bats` refuses a policy that selects routes by label and any policy on the Gateway but
its `ClientTrafficPolicy`. The rule keys on hostnames: one `Probe` covers every route of its
hostname, so without the `Probe` of a host behind sign-in both its routes are named. A `Probe` of
such a host for 200 is refused, naming it, even beside the right one, as it would pass only once the
policy were lost; and so is a `Probe` of the redirect for a host no such policy covers, which could
never pass. A fixture for each of these proves the rule, a release whose chart renders a route from
its values among them. The test also fails when an application of the render that holds an object of
kind `Probe`, one of its manifests, however the file spells the kind, or one its chart renders, does
not name `blackbox-exporter` in the `dependsOn` of its Kustomization, and `just kubernetes-check`,
which refuses a `dependsOn` on an application the overlay does not enable, then refuses a cluster
that lists the application without the exporter, as it does `hello-route` without the Gateway.

**Alerts.** Five, in the exporter's `prometheusrule.yaml`, with their runbooks ([Alerts](#alerts)).
Each reads the series of the job `public-endpoints` alone, the one the `Probe`s set, so a probe of
another job raises none of them: `tests/probes.bats` holds every selector of the rules the render
applies to that job, and each alert's unit test holds a probe of another job in the failing state.
`PublicEndpointDown` is a failing probe with no response at all, `probe_http_status_code` being 0
when none came; `PublicEndpointWrongStatus` a failing probe that was answered, with a status the
module does not accept, so the two never fire together. `PublicCertificateExpiring` is the served
certificate's expiry within 14 days and not within 3, and `PublicCertificateExpiryImminent` within
3, one alert for each severity, as the rules check names alerts once. The expiry is
`probe_ssl_earliest_cert_expiry`, the earliest end among the certificates the proxies send: the
listener's certificate while the intermediates of its chain outlive it, and an intermediate that
ends sooner raises the alerts as well. The series of the verified chain,
`probe_ssl_last_chain_expiry_timestamp_seconds`, is not read: under staging no chain is verified,
and it then holds Go's zero time (`getLastChainExpiry` in `prober/tls.go`), which
`PublicCertificateExpiryImminent` would take for an expired certificate. They read the certificate
the proxies serve, where cert-manager's `CertManagerCertificateExpiringSoon` reads the one
cert-manager stored ([cert-manager](#cert-manager)): a renewal that fails raises both warnings for
the Gateway's certificate, and only the probes' see a stored certificate the proxies do not serve,
or an expiry while cert-manager is not scraped, and only they turn critical. `ProbeNotRunning` is a
declared `Probe` whose scrape through the exporter has failed for 10 minutes, Prometheus' own `up`
of the job being 0: the exporter is gone, the `Probe` names another prober or a module the exporter
does not have, or the probe outlasts the scrape. A cluster that declares no `Probe` has no such
scrape, so it cannot fire there; nor does it see a `Probe` Prometheus does not select, which
`tests/monitoring.bats` holds against the stack's selectors. Alertmanager's configuration is
unchanged: the alerts have no destination yet.

`tests/probes.bats` reads the render of the tree and of copies of it, checks the modules, the trust,
the routes and the `Probe`s as above, and renders the exporter's pinned chart with the values of
each issuer to check the pods.

## Grafana

The Grafana operator runs one Grafana in `monitoring`, with the cluster's Prometheus as its
datasource and the monitoring chart's dashboards. Two applications in `apps/base/monitoring/` hold
them:

- `grafana-operator` installs the operator from its publisher's chart,
  `oci://ghcr.io/grafana/helm-charts/grafana-operator`. The release installs and upgrades the
  `grafana.integreatly.org` definitions as its own templates, each marked
  `helm.sh/resource-policy: keep`, so removing the application leaves them and every Grafana object
  in place; only this chart ships them. One operator runs, with leader election and the requests of
  the publisher's own manifests: nothing calls it, and while it restarts Grafana keeps serving and
  only changes from Git wait. Its chart's ServiceMonitor is on. Its `ks.yaml` sets `wait`.
- The operator watches `monitoring` only. Its service account has a Role there and no ClusterRole,
  so it creates, reads, changes and deletes Secrets, ConfigMaps, Services, service accounts,
  claims, Deployments, Ingresses and HTTPRoutes in `monitoring` and nowhere else. A dashboard for an
  application in another namespace is therefore a `GrafanaDashboard`, with the ConfigMap it loads if
  it loads one, in an application under `apps/base/monitoring/`, as an application's
  `targetNamespace` puts everything it applies in its own namespace. Watching another namespace is
  a deliberate change: it gives the operator the same rights there, and watching every namespace
  gives it them everywhere, `flux-system` included.
- `grafana` holds the `Grafana`, its `GrafanaDatasource`, a ServiceMonitor for Grafana's own
  metrics and the dashboards release, and names `grafana-operator` in `dependsOn`.

The Grafana runs the version its `grafana.yaml` pins, which Renovate updates, as one replica without
a disruption budget: a second replica would keep a database of its own. It keeps nothing that Git
does not hold, so it claims no volume: its data directory is an emptyDir, and the operator applies
the datasource and every dashboard again every minute. One it cannot apply, as while a restarted
Grafana starts, it tries again at once and then after a wait that doubles with each failure, up to
about 17 minutes, until one succeeds (controller-runtime's default, which grafana-operator v5.25.0
keeps for its datasource and dashboard controllers), so a Grafana that was away has them all back
within about as long as it was away, and at most about 17 minutes after it returns. The datasource
is the Prometheus Service of the monitoring chart, `kube-prometheus-stack-prometheus`, port 9090.
Grafana makes no call to the
internet on its own: its configuration turns off usage reporting, the checks for Grafana and plugin
updates, the news feed, the plugin catalogue, the plugins Grafana would install at every start, the
download of plugin signing keys, Gravatar images and external snapshots. The one exception is the
plugin of the VictoriaLogs datasource ([Logs](#logs)): Grafana does not ship it. The operator hands
it to Grafana's container as `GF_INSTALL_PLUGINS`, `victoriametrics-logs-datasource` at the exact
version in `grafanadatasource-victoria-logs.yaml`, which Renovate moves, and `grafana.yaml` sets
`GF_INSTALL_PLUGINS_FORCE=true` on the container. With that set the Grafana image's entrypoint runs
`grafana cli plugins install victoriametrics-logs-datasource <version>` at every start, into a data
directory that starts empty. That makes two requests to grafana.com's plugin API
(`pkg/plugins/repo/service.go` in Grafana v13.1.3): `GET
https://grafana.com/api/plugins/victoriametrics-logs-datasource/versions`, the plugin's versions, of
which it takes the one asked for, and `GET
https://grafana.com/api/plugins/victoriametrics-logs-datasource/versions/<version>/download`, which
grafana.com redirects to that version's archive in its catalogue's storage on
`storage.googleapis.com`. Grafana's own server would install the plugin only with its
preinstalled-plugins list on, which stays off. The entrypoint runs under `set -e`, so a failed
request stops Grafana from starting until grafana.com answers. Grafana loads the plugin only if its
signature verifies against the public key Grafana ships. Nothing else is fetched, and
`tests/grafana.bats` fails when any other datasource or dashboard asks for a plugin.

The dashboards come from the monitoring stack's own chart. The release `grafana-dashboards` installs
`kube-prometheus-stack` at the version the monitoring application runs, with everything off but the
dashboards the chart renders for what the cluster scrapes: the Kubernetes mixin's, node-exporter's
for Linux nodes, and those of the API server, the kubelets, the controller manager, the scheduler,
etcd, CoreDNS, Prometheus, Alertmanager and Grafana. They match the recording rules and job names of
the Prometheus they query, and Renovate moves both pins in one pull request. Each is a ConfigMap and
a `GrafanaDashboard` that loads it into the folder Kubernetes, so neither the operator nor Grafana
fetches a dashboard from the network.

Nothing routes to Grafana from outside the cluster. `just grafana [cluster]` forwards a local port,
`GRAFANA_PORT` or 3000, on 127.0.0.1 only, to port 3000 of the Service `grafana-service` in
`monitoring` through the cluster's kubeconfig, until Ctrl-C; it prints the local URL, and the
forward ends with the recipe however it ends ([cluster.md](cluster.md#recipes)). Sign in as
`admin`. The password is under `GF_SECURITY_ADMIN_PASSWORD` in the Secret
`grafana-admin-credentials` in `monitoring`, which the
operator generates when it first creates the Secret and keeps while the `Grafana` exists; nothing in
Git holds it. Deleting the `Grafana` deletes the Secret, and a new one gets a new password. It is
the kind of credential ADR 0005 keeps out of OpenBao: one a controller generates in the cluster for
its own workload, which stays in the Secret that controller writes. Anonymous access is off.

`tests/grafana.bats` builds both applications as Flux applies them, renders the two charts and the
monitoring application's, and checks the definitions, the operator's namespace and rights, the
monitors, the version and replicas, the absence of volumes, Secrets and routes, the datasource's
Service, that the dashboards are exactly those the monitoring chart renders for the cluster's
monitoring values, and each setting that keeps Grafana from calling the internet on its own against
the defaults of the Grafana release it pins. It runs `just grafana` against a recording kubectl.

## Logs

Two applications in `apps/base/monitoring/` keep the cluster's logs (ADR 0014): `victoria-logs`
runs VictoriaLogs, the store, from
`oci://ghcr.io/victoriametrics/helm-charts/victoria-logs-single`, and `vector` runs Vector, the
collector, from `oci://ghcr.io/vectordotdev/helm-charts/vector`, each its publisher's chart.
Neither installs resource definitions. The store's ServiceMonitor and the collector's PodMonitor
are on, and both applications name `prometheus-operator-crds` in `dependsOn`.

What is collected, by a collector on every node, control planes included, from files only:

- every pod's log lines, from the files under `/var/log/pods`, with what the collector attaches:
  the pod's namespace, name, labels, annotations and node, the node's labels and the namespace's
  labels and annotations; the collector's own lines are left out;
- the log of each of the node's Talos services, machined, the kubelet, etcd, containerd, apid and
  the rest, and the kernel's, which Talos keeps as the service `kernel`: Talos writes each to
  `/var/log/<service>.log` and renames it to `<service>.log.1` at 5 MiB, and the collector reads
  both. Each line stays whole, with the node's name in `node` and its service's in
  `talos_service`, and keeps its own time and level where its format has them: the kernel's
  messages, the prefix Go's log package gives machined's, apid's and trustd's lines, JSON such as
  etcd's, logfmt such as containerd's and cri's and the kubelet's klog. Any other line keeps the
  time it was read.

Three kinds of record are made smaller or left out before they are sent:

- the kernel's audit records, the lines of the service `kernel` that the kernel prints as `audit:`
  or `auditd:`, which the kernel's audit subsystem writes, are dropped by the filter
  transform `drop_audit`. Vector counts what a filter drops in
  `vector_component_discarded_events_total` of its own metrics, which Prometheus scrapes from the
  PodMonitor, so the drop is visible as the series with `component_id="drop_audit"`;
- the audit log of the node, the log of Talos's `auditd` service, `/var/log/auditd.log` and its
  rotated file, is dropped whole, every line of it, by the filter transform `drop_auditd_log`,
  counted the same way as the series with `component_id="drop_auditd_log"`. Talos runs SELinux in
  permissive mode, which [its documentation](https://docs.siderolabs.com/talos/v1.14/security/selinux)
  gives as the default because some CNI and CSI solutions and extensions are incompatible with
  enforcing; it also says Talos cannot label the volumes a CSI driver mounts, and that without the
  label, which a StorageClass can pass as a `context=` mount option, the policy does not let pods
  access such a volume's contents. In permissive mode the kernel allows an access its policy would
  deny and logs the denial as an AVC record with `permissive=1`, which names the process and the
  file; it then holds the permission as granted in its access vector cache, for that source
  context, target context and class, and logs the same denial again only once the cache no longer
  holds it. The cache makes room once it holds more entries than its threshold, 512 by default, and
  is emptied when the policy is loaded again, so where more pairs of contexts and classes are
  checked than it holds, entries are dropped and their denials logged again
  ([`security/selinux/avc.c`](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/security/selinux/avc.c?h=v6.18.63)).
  [Talos's `auditd`](https://github.com/siderolabs/talos/blob/v1.14.6/internal/app/auditd/auditd.go)
  loads no audit rule, and writes as a line each record the kernel's audit subsystem sends it of
  the types 1100 to 2999 of
  [`include/uapi/linux/audit.h`](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/include/uapi/linux/audit.h?h=v6.18.63).
  An AVC record logged inside a system call, by a process started once auditing was enabled, makes
  the kernel write that system call's records too when the call returns, with no audit rule needed
  (`audit_log_start` in
  [`kernel/audit.c`](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/kernel/audit.c?h=v6.18.63)
  and `__audit_syscall_exit` in
  [`kernel/auditsc.c`](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/kernel/auditsc.c?h=v6.18.63)):
  `SYSCALL`, with `key=(null)` as no rule matched it; if the kernel collected file names for the
  call, which with no rule loaded it does for the names looked up after the AVC record, `CWD` and a
  `PATH` record for each name, with a `nametype` such as `PARENT` or `CREATE`; `PROCTITLE`; and
  `EOE`. Each is a separate line that shares the AVC record's `msg=audit(<time>:<serial>)` id, so
  one denied access can be several lines of the audit log. The log store is itself a pod, whose
  claim is of the default storage class, which sets no such mount option, so its writes can produce
  such records, and a collector that shipped the audit log to the store would give the store records
  of its own writes, whose storing can produce more: a loop that amplifies by construction, whatever
  its rate. The collector therefore does not ship the audit log. Dropping only the AVC records with
  `permissive=1` would leave the other lines of their events in the store, so it would need a
  `reduce` transform keyed on that id, holding every open event in memory until its `EOE` record or
  an expiry, where an event cut in two by a restart of the collector would leave records that no
  longer say what they belong to; and it would drop the denials of every other process all the
  same. The drop costs the rest of the file: the SELinux denials of every other process on the
  node, which show what enforcing mode would deny before it is turned on; the line `audit backlog
  limit reached, some audit events may have been lost`, which Talos's auditd writes when records
  were lost on their way to it; and any other record the kernel sends it, such as `ANOM_ABEND` for
  a process that dumps core. They are read on the node with Talos's documented
  `talosctl --nodes <node> logs auditd`, which no recipe wraps; the repository's scripts run
  talosctl through `talman talosctl`. It reads the ring of about 1 MiB in which Talos keeps the
  service's last lines, so it shows no more than that;
- a pod's labels and annotations, its node's labels and its namespace's labels and annotations are
  not stored one field each: VictoriaLogs makes a field of every name, these maps hold dozens of
  names that say nothing about a line, and labels such as `pod-template-hash` and
  `controller-revision-hash` take a new value with every rollout. The transform `pod_fields` keeps
  three of the pod's labels, the Kubernetes recommended labels that name the application,
  `app.kubernetes.io/name`, `app.kubernetes.io/instance` and `app.kubernetes.io/component`, in
  `kubernetes.pod_labels`, and no other; a pod without them has no such field. It drops
  `kubernetes.pod_annotations`, `kubernetes.node_labels`, `kubernetes.namespace_labels` and
  `kubernetes.namespace_annotations`, and sets `node` on a pod's record to the node's name, as
  Talos's lines have it. The store's sink takes a pod's records only from `pod_fields` and Talos's
  lines only from `drop_auditd_log`, which takes them from `drop_audit`.

A record has the fields `_time`, `_msg` and `_stream`. A pod's also has `node`,
`kubernetes.pod_namespace`, `kubernetes.pod_name`, `kubernetes.pod_node_name`,
`kubernetes.pod_labels` as above, and the source's single fields, which say which run of which
workload wrote the line: `kubernetes.container_name`, `kubernetes.container_id`,
`kubernetes.container_image`, `kubernetes.container_image_id`, `kubernetes.pod_uid`,
`kubernetes.pod_owner`, the pod's addresses in `kubernetes.pod_ip` and `kubernetes.pod_ips`, and
`file`, `stream` and `source_type`. A Talos service's has `node`, `talos_service`, `file`, `level`
and, for the kernel, `facility`. The stream is the namespace, pod, container and node of a pod, or
the node and service of a Talos service.

Talos flushes its files every 15 seconds, so its lines reach the store within about that. While the
collector is not reading, such as during its own restart, lines wait in the files, and it goes on
from its place in each file: a pod's lines as long as the kubelet has not rotated them away, and a
Talos service's as long as the service has not written more than its two files hold, 5 MiB at
least. From a node's boot, Talos keeps each service's lines and the kernel's in a ring of about 1
MiB until `/var/log` is mounted, then writes the ring to the file from its oldest line, so early
boot is collected as far as the ring held it; `talosctl logs` and `talosctl dmesg` read the rings on
the node.

The collector mounts all of `/var/log` read-only, as Talos renames the files it rotates, so it can
read every file there. On a control plane that includes the API server's audit log in
`/var/log/audit/kube`, which Talos's default audit policy, the one this cluster runs, writes at the
`Metadata` level: who did what to which object, and when, without request or response bodies, so
without Secret values, except one a request's URL carries, as an `exec`'s command does
([Ascender](#ascender)). The collector does not ship it: its file source's patterns, `/var/log/*.log`
and `/var/log/*.log.1`, match files at the top of `/var/log` only, and its pod-log source reads only
`/var/log/pods`. The node's own audit log, which every node writes at the top, as
`/var/log/auditd.log`, matches the patterns and is dropped by `drop_auditd_log` above. What keeps
the API server's audit log out of the store is this reviewed configuration, which `tests/logs.bats`
matches against Talos's layout of `/var/log`; who can read it through the collector is whoever
may run commands in the pods of `monitoring`.

The collector also mounts `/var/lib/vector`, where it keeps its place in each file and a disk buffer
of 256 MiB. It runs as root, as Talos and the container runtime write their log files as root with
mode 0640, with no capability and no privilege escalation, on the pod network; the namespace's Pod
Security level, privileged, admits its host paths. Nothing on the node sends to it, and the machine
configuration needs no change for it.

The store runs one replica, without a disruption budget, as one would block every drain of its
node. While it starts again on another worker, each collector keeps what it reads in its buffer;
once the buffer is full, the collector stops reading on that node, pods' files and Talos's alike,
until the store takes lines again, and lines whose file is rotated away meanwhile are lost. The
store keeps logs 14 days and drops the oldest days before that once they take 15 GiB, but always
keeps the last two days, on a 20 GiB claim on the cluster's default storage class, which LINSTOR
replicates. Should the volume still fill, to less than 10 MB free, VictoriaLogs' default
`-storage.minFreeDiskSpaceBytes`, the store turns read-only: it answers every insert with HTTP 429
Too Many Requests, and its metric `vl_storage_is_read_only` is 1, while the collectors keep the
lines in their buffers and retry. `LogCollectorSendFailing` fires once none of a collector's requests
of the previous 5 minutes has been accepted for 15 minutes in a row, about 20 minutes after its last
accepted one, so a store away for less than about 20 minutes, the 5-minute rate window plus `for`,
raises nothing. A collector tries a store that has failed it again within 30 seconds, its sink's
`distribution.retry_max_duration_secs`, so it resumes within half a minute of the store's return.

What listens, and where:

- the store: port 9428 of its pod's address, plain HTTP, behind the headless Service
  `victoria-logs`, for the collectors' inserts, its queries and its web interface, its deletion and
  storage administration, and `/metrics`, which Prometheus scrapes through the ServiceMonitor, all on
  that one port;
- the collector: port 9598 of its pod's address, plain HTTP, its own metrics only, which Prometheus
  scrapes through the PodMonitor. It uses neither the node's network nor a host port, so it reserves
  no port on the nodes.

Cilium carries pod addresses between the nodes in its VXLAN tunnel, so both ports answer the
cluster's pods and nodes, and no host outside the cluster has a route to them. Neither chart renders
an ingress, a route or a Service of type LoadBalancer or NodePort, and the nodes' security group
admits from outside the cluster only the Talos and Kubernetes APIs. Through the public Gateway,
behind the cluster's sign-in, the store's interface and its queries are reached and nothing else of
it, by the route of an application of their own, `victoria-logs-route`
([The log store's interface](#the-log-stores-interface)); the Kubernetes API's service proxy, which
`just logs` uses, reaches all of it with the cluster's kubeconfig.

Reading the logs, in a browser at `https://logs.<domain>/` once signed in
([The log store's interface](#the-log-stores-interface)), or with the cluster's kubeconfig:

- `just logs '<LogsQL query>' [--since 15m] [--limit 200] [cluster]` prints the records the query
  matches, from the last 15 minutes and at most 200 unless told otherwise (`--since` is a whole
  number with `s`, `m`, `h`, `d` or `w`), one line each, the oldest first: the time, the namespace
  and pod, or the node for a Talos service's record, and the message, with its newlines made spaces
  and its control characters, C0 and C1, left out. It asks the Kubernetes API for VictoriaLogs'
  `/select/logsql/query` through the API's service proxy to the Service `victoria-logs`, so no port
  is forwarded and none is left behind. Of what kubectl prints it shows only the message of an error
  the API server or the store answered with, without an address; its warnings and the error of a
  connection that failed can name the API server's address and are never shown. A query the store
  refuses fails with the store's own message: kubectl keeps the body of a 400 out of its error, so
  the recipe asks again with `-v=4` and reads the body from the Status kubectl logs, in a file it
  never shows. kubectl keeps only a body's first 2048 bytes, and the recipe says so after a message
  that long. Any other error the store or the API answers with, a store that is away or not ready,
  a request the cluster's access rules deny or a Status without a reason, shows kubectl's message
  for it; credentials the API server refuses also point to `just cluster-kubeconfig`. An API that
  does not answer fails with that said. The query is LogsQL, such as `talos_service:kubelet`,
  `kubernetes.pod_namespace:monitoring error` or `node:node-1 talos_service:kernel`; a query that
  ends in a `stats` pipe prints its records as JSON. With the limit, VictoriaLogs answers with the
  newest records, newest first, unless the query's pipes change the records' order, as `sort` and
  `stats` do: then with the first the pipes give, in their order. The recipe sorts what it gets by
  time, oldest first.
- In Grafana, behind `just grafana`, the datasource VictoriaLogs and the dashboard Logs, in the
  folder Logs: the volume of logs by namespace and by node, and a logs panel for the namespaces and
  pods chosen in the two variables above it. The datasource is the `GrafanaDatasource`
  `victoria-logs`, of the plugin's type, to the Service's port 9428 through Grafana's server, with
  the plugin pinned as [Grafana](#grafana) says. The dashboard's JSON is
  `grafana/app/dashboards/logs.json`, which kustomize makes the ConfigMap the `GrafanaDashboard`
  `logs` loads.

`tests/logs.bats` builds both applications as Flux applies them, renders their pinned charts and
checks each of these. `just vector-check` renders the collector's configuration with
`scripts/vector-config` and has Vector itself, in the image the collector runs, validate it and run
its unit tests, `tests/vector/talos-lines.yaml`, which hold a line of each format above from each
service named with it, and one of udevd's, a kernel audit line, the records of one event of the
node's audit log and a pod's record with many labels, and many of its node's. Vector's unit tests
cannot see a sink, so `tests/logs.bats` checks that each source reaches a sink along one path only,
the store's through the transforms the unit tests run, that each scenario's unit test starts at the
first transform on its path and watches the last, whichever transform that is, and that the unit
tests find a line of each of those services at the last transform on Talos's path and none of the
audit log's. `just logs` runs in `tests/logs.bats` against a
recording kubectl shaped like kubectl v1.37's output. The image
is `vector_image` in the justfile, pinned by the digest of its image index under a
`# renovate: datasource=docker depName=…` comment: Renovate's custom manager for the justfile moves
its tag and digest, in the same pull request as the chart, and `tests/logs.bats` fails, saying what
to set, while it is not the image the chart runs.

### The log store's interface

VictoriaLogs' own query interface is at `https://logs.<domain>/`, on the public Gateway's `https`
listener, behind the cluster's sign-in ([Sign-in](#sign-in)). The application `victoria-logs-route`
(`apps/base/monitoring/victoria-logs-route/`) holds it, shaped as `demo/hello-sso`: its `app/` holds
the one `HTTPRoute` `logs` and its `Probe` ([Probes](#probes)), and its `ks.yaml` adds
`components/sso` with `SSO_ROUTE` and `SSO_HOSTNAME` both `logs`, so the component makes the
`SecurityPolicy` `logs`, which asks oauth2-proxy about each request of the route and does not fail
open, and the route `logs-oauth2`, which sends `/oauth2/` on the same host to oauth2-proxy. Its
`targetNamespace` is `monitoring`, the store's, which carries `k8s-gitops/gateway: public`, and the
`ReferenceGrant` `oauth2-proxy` names `monitoring`. It names `gateway-public`, `victoria-logs`,
`oauth2-proxy` and `blackbox-exporter` in `dependsOn` and waits; `victoria-logs` waits for its
release, so the route is applied once the store answers. Its own Ready says that its objects are applied, not that the Gateway took them: an HTTPRoute and a
SecurityPolicy report their state per parent, where Flux's wait does not read it, so
`just gateway-check`, which counts the routes the Gateway accepted and names the DNS record of each
host, is what shows it. The proxies' egress allows the store's pod on 9428 and no other pod or port
of `monitoring` ([What the namespaces let through](#what-the-namespaces-let-through)), which holds
once the agents enforce the policies rather than audit them ([Service addresses](#service-addresses)
says which they do); the route sends nothing else there either way. external-dns publishes the name
as for every route on the Gateway ([DNS records](#dns-records)).

- **Reaching it.** The first visit signs in through dex and GitHub, as for every route that opts in
  ([Putting a route behind it](#putting-a-route-behind-it)). oauth2-proxy returns the person to
  `/`, which the route redirects, 302, to `/select/vmui/`, the interface, where LogsQL queries run.
  A session that another route which opts in started passes here too.
- **What it shows.** Every record of the store: every pod's log lines and the log of every Talos
  service and of the kernel, as [Logs](#logs) collects them, for as long as the store keeps them.
  The node's audit log and the API server's audit log are not in the store, so not here either. It
  shows all of it to whoever is on the sign-in list ([Who is admitted](#who-is-admitted)), the same
  people who pass every other route that opts in; nothing narrows what a person may query.
- **What is routed, and why each path reads.** The route has two rules, which `tests/logs.bats`
  pins in full. `/`, exactly, is redirected with 302 to `/select/vmui/` and sent nowhere: it is the
  store's help page, which links its metrics and its flags. The other rule sends to the Service
  `victoria-logs` on 9428, with no filter and no method match, the paths that are, by whole
  segments, under `/select/vmui` or `/select/logsql`, or exactly `/select/buildinfo` or
  `/select/tenant_ids`. The store dispatches on the path, with each `//` made `/`, by the same
  literal prefixes and exact paths, and each handler under them only reads, whatever the method,
  the queries taking their arguments from the query string or the form body: `/select/vmui`
  redirects to `/select/vmui/`, under which the store serves the interface's files embedded in it;
  under `/select/logsql/` it runs the queries `query`, `hits`, `facets`, `field_names`,
  `field_values`, `stats_query`, `stats_query_range`, `stream_field_names`, `stream_field_values`,
  `stream_ids`, `streams`, `query_time_range` and `tail`, and answers any other name with an error;
  `/select/buildinfo` gives its version and `/select/tenant_ids` the tenants that hold logs. A path
  under these that ends in `/favicon.ico` gets the HTTP server's icon. The pinned release's
  interface works out its server from its own address, `window.location.href` with `/select/vmui/…`
  cut off, so it calls its own origin, and it asks only `/select/logsql/…`, with `POST`,
  `/select/buildinfo` and `/select/tenant_ids`, besides its own files under `/select/vmui/`. The
  sources are VictoriaLogs v1.54.0, the `appVersion` of the pinned chart `victoria-logs-single`
  0.13.13: `app/victoria-logs/main.go`, `app/vlselect/main.go` and its built interface
  `app/vlselect/vmui/`, which is what the image serves, `app/vlinsert/main.go` and
  `app/vlstorage/main.go`; and VictoriaMetrics v1.156.0, the version its `go.mod` names,
  `lib/httpserver/httpserver.go`, for the server's own paths.
- **What is not routed.** A request whose path is none of those matches no rule, and the Gateway
  answers it itself, 404, without reaching the store:
  - the writers, `/insert/…` (JSON lines, native, Elasticsearch, Loki, OpenTelemetry, journald,
    Datadog, Splunk and `/insert/ready`), `/internal/insert`, `/api/v2/logs`, `/api/v1/validate`
    and `/services/collector/…`: what the collectors send to, which nothing outside the cluster may;
  - deletion, `/delete/…`, which the store also refuses while `-delete.enable` is not set, as it is
    not, and `/internal/delete/…`; the internal reads `/internal/select/…` of a cluster of stores;
    and the storage's administration, `/internal/force_merge`, `/internal/force_flush`,
    `/internal/log_new_streams` and `/internal/partition/…`, which detaches, attaches and snapshots
    the data;
  - the HTTP server's own paths, `/metrics`, `/flags`, `/debug/pprof/…`, `/health`, `/ping`,
    `/-/healthy`, `/-/ready`, `/robots.txt` and `/favicon.ico`: the store's metrics, its command
    line, its profiles and its health, which only the cluster needs;
  - the store's help page at `/`, which the route redirects instead;
  - `/select/vmalert/…`, which proxies to the vmalert `-vmalert.proxyURL` names, which the tree
    does not run.

  A path that differs from a routed one in letter case, by a suffix such as `/select/vmuix`, or by
  a trailing slash or more after an exact one, such as `/select/buildinfo/`, matches nothing either.
- **Why normalisation cannot turn a routed path into a writer.** The pinned Envoy Gateway, v1.10.0,
  normalises the path before routing on every listener, as RFC 3986 says, removing dot segments
  (`internal/xds/translator/listener.go`), and with the ClientTrafficPolicy's defaults, which the
  tree's leaves as they are, merges adjacent slashes (`disableMergeSlashes` unset) and answers a path
  with an escaped slash, `%2F` or `%5C`, with a redirect to the path unescaped, which comes back
  through the Gateway and is normalised and matched again (`escapedSlashesAction:
  UnescapeAndRedirect`, `internal/gatewayapi/listener.go`). The route matches the normalised path,
  and that is the path the store receives: one that starts with the literal characters of a routed
  prefix or is a routed exact path. The store resolves no dot segment and dispatches on the same
  literal prefixes, the writers' first, so a path that starts `/select/` never reaches an insert,
  delete or storage handler, whose prefixes it cannot have, and is read or refused.
- **What a forged cross-site request can do.** oauth2-proxy's session cookie is `Secure`, `HttpOnly`
  and `SameSite=Lax`, for `.${CLUSTER_DOMAIN}`. A browser sends it with a request that another site
  starts only for a top-level navigation with `GET`, whose answer the person's own window shows and
  the other site does not see, so another site's script or form asks the route without a session,
  the sign-in answers with its redirect, and the store receives nothing. A host under the cluster's
  domain is the same site, so the cookie goes with its requests: they reach only the routed reads,
  and the store's CORS answer, `Access-Control-Allow-Origin: *` without
  `Access-Control-Allow-Credentials`, lets no other origin read an answer to a request sent with
  credentials. So no other site's page reads logs through a person's browser, and every routed path
  only reads. The cookie itself goes to every host under the domain, those whose routes do not opt
  in included, and whoever holds it reads the logs here for as long as it lasts, as it passes every
  route that opts in ([What it does not cover](#what-it-does-not-cover)).
- **The redirect is behind the sign-in too.** Envoy Gateway gives every rule of a route the
  features of the policy that targets it (`internal/gatewayapi/securitypolicy.go`), and turns the
  external authorisation on for each rule's route whatever its action, a redirect's included
  (`internal/xds/translator/route.go`, `extauth.go`): a request for `/` without a session goes to
  sign-in as well. Either way the redirect reaches no backend.
- **The Gateway's timeout.** The route sets no timeout and no BackendTrafficPolicy applies, so Envoy
  Gateway leaves the route's timeout unset (`internal/xds/translator/route.go`), and Envoy's default
  for a route applies: 15 seconds from the end of the request to the end of the answer. A query that
  runs longer, and a live tail, which the store keeps open for as long as the client stays, end at
  the Gateway after 15 seconds, while the store allows a query 30 (`-search.maxQueryDuration`, its
  default). `just logs` and Grafana do not pass the Gateway.
- **The other ways in.** `just logs` and Grafana's Logs dashboard, behind `just grafana`, remain,
  need no sign-in, only the cluster's kubeconfig, and read the store as above.
- **Until the owner has seeded the sign-in** (dex's GitHub client and oauth2-proxy's list, [What the
  owner does, in order](#what-the-owner-does-in-order)), `oauth2-proxy` is not Ready, so
  `victoria-logs-route`, which waits for it, is not applied: there is no route and no DNS record,
  and a request for the host through an edge is answered 404, as for any host no route serves. Once
  the route is applied, an oauth2-proxy whose pods do not answer makes every request of the route
  answer 403, and one whose Service has no ready endpoint 500 ([Putting a route behind
  it](#putting-a-route-behind-it)): the policy does not fail open either way.

`tests/logs.bats` builds the application as Flux applies it and checks the layout, the policy's
whole spec, the sign-in route, the grant and the host following the domain; both rules in full, and,
as Gateway API matches a route, that the interface's requests are sent on and the writers, the
administration and the server's own paths are not; that no route the tree builds or its charts
render, and no Grafana, reaches the store past the sign-in, and that no grant of `monitoring` lets
another namespace's route refer to its Services, as one could through a second Service that selects
the store's pod; the overlay entry and the refusals without the store, the Gateway or the sign-in;
and that the route's header records, in `# victoria-logs-paths:` beside its `Source:` line, the
release its paths were read from, which must be the `appVersion` of the store's pinned chart. A new
chart therefore fails it, saying what to read again and what to set, and `.renovate/by-hand.tsv`
lists the record. What only a running Gateway, oauth2-proxy and a browser can show, the redirects,
the session and the answers, is not proved offline; the first sign-in is the proof on the cluster.

## cert-manager

`apps/base/cert-manager/cert-manager/` installs cert-manager, which issues and renews the TLS
certificates applications and gateways ask for, from the issuers they name (ADR 0006). The
namespaced issuers serve their own application alone: `cluster-ca-bootstrap` signs the cluster's
own CA, below; OpenBao's own issuers sign OpenBao's listener certificate ([OpenBao](#openbao)); and
the Barman Cloud plugin's self-signed `Issuer` signs the plugin's two certificates
([PostgreSQL](#postgresql)). The issuers any namespace may name are the cluster's three
`ClusterIssuer`s: `cluster-ca` and the ACME issuers `letsencrypt-staging` and
`letsencrypt-production`, below.

It runs in its own namespace, `cert-manager`, at the restricted Pod Security level, from the
publisher's chart in `oci://quay.io/jetstack/charts`; its leader election leases are there too, so
nothing it installs is in another namespace. The release installs and upgrades the `cert-manager.io`
and `acme.cert-manager.io` definitions, as the publisher recommends under Flux: only this chart
ships them, so they move with the controller that serves them rather than being an application of
their own. Each carries `helm.sh/resource-policy: keep`, so removing the application leaves them,
and every certificate and issuer, in place. Gateway API support is on; cert-manager looks for the
Gateway API definitions only when it starts, so the application names `gateway-api-crds` in
`dependsOn`. Its `ks.yaml` sets `wait`, so an application that names `cert-manager` in `dependsOn`
starts once cert-manager runs.

Following the publisher's production guidance, the controller and the CA injector run two replicas
each, one leading, and the webhook three, one per worker, spread over the nodes where the scheduler
can; each has a disruption budget that keeps one pod available, so a drain never takes the last
one. They run at `system-cluster-critical` with small requests and no limits. The chart's
ServiceMonitor scrapes the three components' metrics, which the alerts on certificates read
([Alerts](#alerts)), so the application names `prometheus-operator-crds` in `dependsOn` as well.
The DNS-01 self-check, which asks whether a challenge's TXT record is visible before cert-manager
asks the CA to look, asks the zone's own authoritative nameservers. The controller finds the zone
and its nameservers through one resolver, a public DNS-over-HTTPS endpoint given by name, so the
tree holds no address and the zone is not looked up through the cluster's own resolver, which may
not see it. It then asks those nameservers for the record one at a time, in the order the
resolver's answer lists them, over UDP port 53, and again over TCP port 53 when the UDP answer is
truncated or does not arrive before the query times out. A round of the check passes only when every
one of them has the record, and ends at the first that lacks it, does not answer or answers with an
error; the ones after it are not asked in that round, and no other server is asked in its place. A
round that does not pass is followed by the next once `--dns01-check-retry-period` has gone by, ten
seconds by default, which the tree keeps. The nameservers-only setting is off: it would send the TXT
lookup to the resolver, and a recursive resolver caches a negative answer for the time the zone's
SOA gives (RFC 2308), which a zone holding a wildcard record gives for the challenge's name until
the record exists, so a record visible to everyone else could be reported missing for that long.
The authoritative servers hold no such cache. The resolver is asked only what a cached answer
cannot get wrong: the zone's SOA and nameservers, which exist before the challenge does, and
whether the challenge's name is a CNAME, for which a cached "no" and a fresh one lead the check to
the same servers. The exception is a zone whose wildcard record is a CNAME: until the record
reaches the zone's nameservers the wildcard answers for the challenge's name, so a resolver that
cached that answer, from any lookup made before then, the controller's own first round included,
sends the check to the CNAME's target, whose nameservers never have the record, until the cached
answer's TTL runs out. One resolver is listed; a second would be asked only when the first fails to
answer, and would be one more destination for the controller's egress to allow. The controller
therefore needs egress to the resolver on TCP port 443 and to every nameserver of the zone on UDP
and TCP port 53, and the cluster's resolver to look up the resolver's and the nameservers' names; a
network policy for `cert-manager` must allow these, the provider's API and the CA's directory.
After the check passes the controller waits a further minute before it asks the CA to validate.
`tests/acme-issuers.bats` reads these settings from the controller's arguments and config file as
`scripts/render` renders the whole tree, the HelmRelease's own values and post-renderers included.
`tests/baseline.bats` renders the chart with these values and checks the namespace, the definitions
and their policy, the Gateway API configuration and dependency, and the replicas, spreads and
budgets.

### The cluster's own CA

`apps/base/cert-manager/cluster-ca/` applies three objects in `cert-manager`: a SelfSigned `Issuer`,
`cluster-ca-bootstrap`; the `Certificate` `cluster-ca`, a CA (`isCA`) of ECDSA P-384, valid for ten
years and renewed in the last one, with the key kept on renewal, which the bootstrap issuer signs
and which cert-manager keeps in the Secret `cluster-ca`; and the `ClusterIssuer` `cluster-ca`, of
kind CA, that signs with that Secret. The application names `cert-manager` in `dependsOn` and sets
`wait`, so it is Ready only once the authority is issued and the issuer is, and what names it in
`dependsOn` finds an issuer that signs. The bootstrap issuer is namespaced, so no other namespace
can ask it for a certificate.

This authority is the default and a cluster's choice of the public Gateway's issuer ([The ACME
issuers](#the-acme-issuers)); it is made in the cluster, its private key is in a Secret in
`cert-manager`, and no tree file holds a key; nothing outside the cluster trusts it; and it is lost
with the cluster, as a rebuilt cluster makes a new one, which a client that had been given the old
one must be given again. It is not the public certificate of ADR 0006, which comes from the ACME
issuers below. `tests/gateway.bats` checks the three objects, the
Gateway's certificate against them, and that neither application's build holds a Secret nor its
directory a private key; `secrets-scan` covers the rest of the tree.

### The ACME issuers

`apps/base/cert-manager/acme-issuers/` applies, in `cert-manager`, what ADR 0006 decided: two
`ClusterIssuer`s of Let's Encrypt, `letsencrypt-staging` and `letsencrypt-production`, each with the
account key it makes in its own Secret, and the `ExternalSecret` `cloudflare-api-token` that brings
the DNS provider's API token from the secret store ([External Secrets](#external-secrets)) into the
Secret both issuers name. Let's Encrypt asks for no contact address for an account, so none is set.
A `ClusterIssuer` reads its Secrets from the controller's cluster resource namespace, which is
`cert-manager`, so the token's Secret is there and in no other namespace.

- **The token.** The key `cert-manager/cloudflare` of the store, property `api-token`, which an
  operator writes once with `just bao-put cert-manager/cloudflare api-token` (the value from
  standard input). The tree holds no token, no Secret and no other way to authenticate to the
  provider: the solvers name `apiTokenSecretRef` and nothing else. The token must be one the
  operator scopes to the one DNS zone that holds the cluster's domain, with the permissions to edit
  DNS records in it and to read the zone, and to nothing else: it can then change the zone's records
  and nothing outside it. Which ServiceAccounts can read the Secret is not a short list and is not
  claimed to be complete: the controller (`cert-manager`) reads Secrets cluster-wide to issue, the
  CA injector (`cert-manager-cainjector`) cluster-wide to inject CA bundles, External Secrets'
  operator writes it, Flux's controllers and a cluster administrator can read any, and so can every
  other controller whose chart grants Secrets cluster-wide, as the reflector's and the reloader's
  do. The token's scope is what bounds the harm of a read. The `ExternalSecret` refreshes every 15
  minutes, so a token the operator replaces in the store reaches the cluster without a change here.
  `secret-rotation.yaml` lists the key as `issued`: rotating it is making a new token at the
  provider, with the same scope, and writing it with the same `just bao-put` command, and
  `just secret-rotate` refuses it
  ([Rotating an application's secret](#rotating-an-applications-secret)).
- **The solver.** DNS-01 through the provider's API, the only solver, for names under
  `${CLUSTER_DOMAIN}` only: the `dnsZones` selector means a Certificate for any other name finds no
  solver and is refused. HTTP-01 is not used, which is also what lets one certificate cover a
  wildcard. The controller checks the challenge's record at the zone's own nameservers, as above.
- **Staging and production.** Both issuers exist whenever the application is enabled, so that moving
  from one to the other is a change of the choice below and nothing else. Staging's certificates are
  signed by a chain no client trusts, and its rate limits are far above production's: a setup that is
  broken spends staging's. Production's are trusted by a client with the usual public roots, and its
  limits are the ones a broken setup can exhaust. The procedure for a new cluster is to choose staging first, move to production
  once staging has issued the certificate and `just gateway-check` passes, and go back to staging
  to test anything again. While on staging, the probes of the public hostnames do not verify the
  certificate, as no client trusts that chain ([Probes](#probes)). Both issuers register their
  account with the CA as soon as they exist.
- **Production's rate limits.** Let's Encrypt's [rate limits](https://letsencrypt.org/docs/rate-limits/)
  as Let's Encrypt publishes them: 50 certificates per registered domain every 7 days; 5
  certificates for the exact same set of names every 7 days, which no override raises; and 5
  failed validations per name per account every hour, after which the account places no new order
  for that name until the limit refills. Here, deleting the `public-wildcard-tls` Secret (the
  certificate is issued again), changing `PUBLIC_ISSUER` back and forth (each move to production
  issues again) and rebuilding a cluster from this tree each request the same names again, so
  each spends the limit of 5 per exact set of names. The limit of 50 per registered domain counts
  a set of names not issued before, because a renewal of the same set is exempt from it. Failed
  validations count only when Let's Encrypt validates and fails, which cert-manager asks for only
  once its own self-check sees the record: a token the provider refuses, or a record that never
  becomes visible, waits and retries without spending one. To test anything that issues, whether
  the token, the zone, the solver or a rebuild, change the choice to `letsencrypt-staging` first,
  and return to production once it works.
- **Ready.** The application waits for `cert-manager` and `openbao-store`, and is Ready only once the
  `ExternalSecret` and both issuers report Ready, which kstatus does not read from these kinds by
  itself. Until the operator has written the token, the `ExternalSecret` reports the missing key and
  the application is not Ready, which holds back the Gateway that waits for it.

#### Choosing the public Gateway's issuer

The `Certificate` `public-wildcard` of `gateway-public` names the `ClusterIssuer` the variable
`PUBLIC_ISSUER` gives, `cluster-ca` when it is not set, so a cluster that says nothing keeps the
cluster's own authority. A cluster sets it in one place, a patch in its overlay
(`apps/overlays/<cluster>/kustomization.yaml`) on the Kustomization `gateway-public`, and repeats
the name for the probes of its public hostnames, which verify the certificate against the trust of
its issuer, in a patch on the Kustomization `blackbox-exporter` ([Probes](#probes)). In `lab-sto2`
they read:

```yaml
patches:
  - target: {group: kustomize.toolkit.fluxcd.io, version: v1, kind: Kustomization, name: gateway-public}
    patch: |-
      - op: add
        path: /spec/dependsOn/-
        value: {name: acme-issuers}
      - op: add
        path: /spec/postBuild
        value: {substitute: {PUBLIC_ISSUER: letsencrypt-production}}
  - target: {group: kustomize.toolkit.fluxcd.io, kind: Kustomization, name: blackbox-exporter}
    patch: |-
      apiVersion: kustomize.toolkit.fluxcd.io/v1
      kind: Kustomization
      metadata: {name: blackbox-exporter}
      spec: {postBuild: {substitute: {PROBE_ISSUER: letsencrypt-production}}}
```

It is a patch and not a `cluster-config` key because the choice is part of the tree and reviewed in
a pull request, not a value of the deployment, and because the tree's check can see it: a cluster-config
value exists only in the cluster. The patch names `acme-issuers` in `dependsOn` too, so the
Gateway's certificate is requested only once the issuer exists, and `just kubernetes-check` refuses
a cluster that chooses an issuer other than `cluster-ca` without that dependency, and one whose
overlay names the dependency without listing the application.

`lab-sto2` chooses production. A new cluster starts with `PUBLIC_ISSUER: letsencrypt-staging`, and
`PROBE_ISSUER: letsencrypt-staging` for its probes, and once the staging certificate is Ready and
`just gateway-check` passes, changes both to `letsencrypt-production` in a pull request of its own.
cert-manager then issues the certificate again from production, with a new private key, into the
same Secret, and the listener serves the new certificate when it is Ready; the old one is served
until then. Going back to staging for testing is the same change the other way (the rate limits in
[The ACME issuers](#the-acme-issuers)). On staging the probes do not verify the certificate, as no
client trusts that chain; on production they verify it against the public roots again
([Probes](#probes)). The two do not change together: the Gateway waits for the exporter, so the
exporter takes the new issuer's trust first, and the proxies serve the old certificate until the new
one is issued. A change to production, or to the cluster's own CA, therefore fails the probe of
every hostname over https in between, as the old certificate does not verify against the new trust,
and `PublicEndpointDown` fires for each when the issuance takes more than 5 minutes; it clears with
the new certificate. A change to staging fails none, as the probes then verify nothing.

- **What a client sees.** `lab-sto2` serves the production certificate, which a client with the usual
  public roots trusts with nothing to hand it. With the cluster's own CA or staging, a client outside refuses the
  certificate: no store trusts either chain.
- **When it fails.** A wrong or missing token, a zone the token cannot edit, or a challenge whose
  record never becomes visible leaves the `Certificate` not Ready with cert-manager's own reason,
  and the Gateway keeps serving the Secret it has, the previous certificate or none. Look down the
  chain cert-manager makes: `kubectl --namespace envoy-gateway-system describe certificate
  public-wildcard`, then `get certificaterequest,order,challenge` in the same namespace; the
  Challenge's `status.reason` says what the provider or the CA refused. `kubectl --namespace
  cert-manager get externalsecret cloudflare-api-token` says whether the token came through, and
  `kubectl describe clusterissuer` of the chosen issuer whether the account registered. A DNS-01
  challenge usually takes a minute or two to be visible and verified, and cert-manager retries
  with a growing delay after a failure. Until the self-check passes, the Challenge's reason is
  `Waiting for DNS-01 challenge propagation:` and what ended its last round, which asks the zone's
  nameservers one at a time and stops at the first that fails. `DNS record for "..." not yet
  propagated` means one nameserver answered without the record: each asked before it had it, and
  those after it were not asked in that round. A provider can take a short while to publish a
  record to all of its servers, and in a zone whose wildcard record is a CNAME the reason can last
  until a cached answer runs out, as above. A nameserver that cannot be reached on port 53 from
  the controller shows as the network error, such as an `i/o timeout`, and one that answers with
  an error as `NS ... returned` and its response code, each only when the server's turn comes:
  while a server before it lacks the record, the reason is `not yet propagated`. A resolver that
  cannot be asked shows as `Post` and its URL followed by the network error, or as `dns: server
  returned HTTP` and a status, and no nameserver was asked in that round. `just gateway-check`
  fails its `certificate` line with the Ready condition's reason.

## Autoscaling and reflection

Three small add-ons that the applications this cluster runs assume, each enabled in the cluster's
overlay. `tests/autoscaling.bats` builds each as Flux applies it and renders its chart to check
what follows.

### KEDA

`apps/base/keda/keda/` runs KEDA in its own namespace, `keda`, at the restricted Pod Security level
its pods meet. An application scales on events by creating a `ScaledObject` (or `ScaledJob`) that
names its workload and a trigger; KEDA creates and owns the HorizontalPodAutoscaler that follows it.
The chart is the publisher's, from a public OCI mirror, as it releases only to a classic Helm
repository.

- The release installs and upgrades the `keda.sh` and `eventing.keda.sh` definitions, as the
  publisher's chart does; each carries `helm.sh/resource-policy: keep`, so uninstalling the release
  leaves them, and every `ScaledObject`, in place. The application's `ks.yaml` sets `wait`, so an
  application that names `keda` in `dependsOn` starts once they exist.
- The operator, the metrics server and the admission webhooks each run two replicas, preferably on
  different nodes, under a disruption budget that keeps one running. Only one operator is the
  leader, so its second replica is a standby that shortens a failover. The second metrics server is
  there for availability too, so one keeps answering through a drain or a pod's failure: the API
  server reaches them through their Service's address without aggregator routing, so requests are
  not spread over the two, and KEDA's documentation supports one. Requests and limits are the ones
  KEDA's documentation gives for each component.
- KEDA's metrics server registers the `external.metrics.k8s.io` API. metrics-server registers
  `metrics.k8s.io`; the two groups differ, so the registrations do not collide. Only one provider
  can serve `external.metrics.k8s.io`: no other application may register it.
- The admission webhooks' failure policy is `Ignore`: while no webhook answers, a `ScaledObject` is
  admitted without being checked. A missing operator is worse for what it owns: HorizontalPodAutoscalers
  that follow a `ScaledObject` stay, but the metrics server gets the values they read from the
  operator, and the operator does the scaling from and to zero itself, so without it they cannot
  compute, their workload stays at its current size, and nothing scales it from or to zero.
- KEDA 2.21's documentation tests Kubernetes 1.34 to 1.36; the cluster runs a newer release, so KEDA
  runs outside the versions its publisher has tested.
- One ServiceMonitor for each of the three components.

### Vertical Pod Autoscaler

`apps/base/kube-system/vpa/` runs the recommender only, in `kube-system` with the other small
services the cluster assumes, from the Fairwinds chart.
The project's own `vertical-pod-autoscaler` chart (in the autoscaler repository's Helm index) says
it is under development and not ready for production, so the cluster uses Fairwinds', which tracks
an older release of the recommender (1.7.1, where the project's is 1.8.1). Fairwinds' chart is
published only to a classic Helm repository and no public OCI mirror carries it, so the application
has a `HelmRepository` beside its `HelmRelease`, which Renovate follows as it does the others. The
recommender reads container usage from metrics-server and writes a recommendation
to the status of each `VerticalPodAutoscaler` an application creates; it does not act on it. The
chart's updater and admission controller are off, so nothing evicts a pod and no webhook or
certificate generator is rendered, and no role bound in the release lets a service account change a
pod.

- The definitions (`VerticalPodAutoscaler` and its checkpoint) are in the chart's `crds/`
  directory, which Helm installs once and never removes with a release, so they stay when the
  application leaves the tree. Flux creates and replaces them on upgrade through the release
  defaults. `ks.yaml` sets `wait` and names `metrics-server`, whose API the chart's Helm test reads;
  metrics-server's own `ks.yaml` sets `wait` too, so the test runs once that API answers.
- The chart's three `vpa-test-*` pods run after each install and upgrade, because the cluster's
  Helm releases run their tests. They set no requests, and the chart has no value to set them; they
  are the one exception to every container having requests, and they are left out of the check.
- One replica, with the chart's requests and no limits. The project's FAQ says only one recommender
  is active; a second would need `--leader-elect=true` and would add a second 500Mi request for a
  faster failover only, as the recommender keeps its history in checkpoint objects. There is
  therefore no disruption budget.
- The recommender keeps what it has seen as long as it runs, plus checkpoints. It could read
  history from the monitoring stack's Prometheus instead (`--storage=prometheus`), which gives it
  recommendations at once after a restart; that needs kubelet container metrics to be scraped under
  the names it expects, and nothing here configures it.
- A PodMonitor for the recommender.

### Reflector

`apps/base/kube-system/reflector/` runs Reflector in `kube-system`, from its publisher's chart on
its OCI registry. It copies a Secret or ConfigMap into other namespaces, which is how one wildcard
certificate serves several of them: the source carries
`reflector.v1.k8s.emberstack.com/reflection-allowed: "true"` and
`reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces`, and a copy is made in each
namespace the second names (`reflection-auto-enabled` and `reflection-auto-namespaces` make the
copies without the destination asking).

Reflector can read and write every Secret and ConfigMap in every namespace, and list and watch
namespaces: that is what it is for, and its ClusterRole grants exactly that and nothing else. The
control is the annotations: only an object carrying `reflection-allowed` is copied, and only into
the namespaces its annotation names. An empty `reflection-allowed-namespaces` allows every
namespace, so every source lists them. Nothing in this repository carries a reflection annotation
yet; `tests/autoscaling.bats` fails when a file under `kubernetes/` does.

One replica: Reflector has no leader election, so a second would copy what the first does, and
the chart makes no disruption budget. Its chart serves no metrics and has no monitor.

## Storage

Persistent volumes come from LINSTOR, run by the Piraeus operator, on the workers' data volumes
(ADR 0011). Two applications in `apps/base/piraeus-datastore/` hold it; their namespace admits
privileged pods, as LINSTOR's satellites, the CSI node plugin, the NFS server and the HA controller
run privileged with host paths; they are its entries in `pod-security-exceptions.yaml`. The
operator's own pod, the only one the render holds, passes restricted, and the LinstorCluster gives
the LINSTOR controller, the CSI controller and the affinity controller the security context
restricted requires ([Pod Security](#pod-security)).

- `piraeus-operator` installs the operator from its publisher's chart,
  `oci://ghcr.io/piraeusdatastore/piraeus-operator/piraeus`, with the baseline's shape. The chart
  installs the operator's resource definitions (`piraeus.io`) as templates of the release, so each
  chart upgrade upgrades them with the operator, and the HelmRelease's post-renderer gives each
  `helm.sh/resource-policy: keep`, so Helm leaves them when the release is uninstalled. Its
  `ks.yaml` sets `wait`: it is Ready once the operator is.
- `linstor-cluster` holds the storage cluster: the `LinstorCluster`, the
  `LinstorSatelliteConfiguration`s, the StorageClasses and the VolumeSnapshotClass. It names
  `piraeus-operator` and `snapshot-controller` in `dependsOn`, as the operator's webhooks validate
  its objects and every StorageClass of LINSTOR's driver, and the VolumeSnapshotClass needs the
  snapshot definitions ([Resource definitions](#resource-definitions)). Its `ks.yaml` sets `wait`
  and health check expressions, as the operator gives these kinds no Ready condition and no
  `status.observedGeneration`, so kstatus alone would count them Current at once: it is Ready once
  what it applies exists, the operator reports the `LinstorCluster` `Available`, its controller
  answering, and every `LinstorSatelliteConfiguration` `Applied` to the satellites it selects,
  each at the generation the object holds. That is what the applications that name it in
  `dependsOn` wait for. It does not wait for every satellite to run, so a node down does not hold
  them back; a satellite that never starts shows as the storage cluster's `Configured` condition,
  which the check leaves out, and in the satellite counts of its status. It carries
  `k8s-gitops/timeout: long`: on a first install the storage controller can take longer than the
  root's default 3m to report `Available`, and the health check would fail every minute until it
  does.

The controller's and the satellites' metrics are scraped, and the replicas, the quorum, the
satellites and the pools alerted on, by the `linstor-monitoring` application
([Storage monitoring](#storage-monitoring)).

### What runs

From the `LinstorCluster` the operator runs the LINSTOR controller, LINSTOR's CSI driver
`linstor.csi.linbit.com`, the HA controller and a satellite on each node it selects: every node
without the label `node-role.kubernetes.io/control-plane`, which Talos gives every control plane
and no worker. That is every worker, by its role and never by its name, one OpenTofu adds later
included. A pod that uses a LINSTOR volume runs only on such a node.

The satellites run as the operator's Talos guide prescribes, in `talos.yaml`: without the module
loader, as the machine configuration loads DRBD and the device-mapper targets
([cluster.md](cluster.md#the-node-image)); without the shutdown guard and the host paths of
systemd, of the kernel's modules and of its sources, which Talos does not have; and with LVM's
configuration from the ConfigMap `talos-lvm-config`, which keeps the metadata backups and archives
that Talos's own configuration turns off. The satellite writes them under `/var/etc/lvm`, as `/etc`
is read-only on Talos.

### The storage pool

Every satellite has one LVM-thin pool, `data`, on the worker's data device,
`/dev/disk/by-partlabel/r-data` ([cluster.md](cluster.md#the-workers-data-device)). The first time,
LINSTOR makes the volume group `linstor_data` and the thin pool `data` from the device; afterwards
the operator registers what is there. A node without the device gets no pool, and its
`LinstorSatellite` says the device is missing. A device that already holds a file system or another
signature is not wiped and gets no pool either.

### StorageClasses

- `linstor-replicated`, the default: two replicas on two workers, kept in sync by DRBD. With three
  workers LINSTOR adds a diskless tiebreaker on the third, so the volume has quorum, and a replica
  that loses quorum suspends its I/O instead of failing it: its file system is not remounted
  read-only, and the HA controller evicts the pod, which starts again on a node with quorum. The
  volume is made once its first pod is scheduled, with a replica on that pod's node where it can
  be, and any node LINSTOR runs on reaches it, over the network where it holds no replica. It is
  formatted XFS and can be expanded. Use it unless the application keeps copies of its data itself.
- `linstor-node-local`: one replica, on the node the volume's first pod is scheduled to, reachable
  from that node only, so the pod stays there. It is a thin volume of the node's pool without DRBD:
  LINSTOR cannot give it a second replica or move it to another node, and losing the node's data
  volume loses it. Use it for an application that keeps copies of its data on other nodes itself,
  where DRBD would only add its metadata and a device in the path of every write.

A StorageClass's parameters cannot change once it exists: a change of parameters is a new class,
or the class deleted and made again, which leaves the volumes it made as they are.

### Snapshots

A VolumeSnapshot of a LINSTOR volume is the volume's content at that moment, kept as a thin snapshot
in the pool of each node that holds a replica. `snapshot-controller` serves VolumeSnapshots and
LINSTOR's CSI driver takes them, through `linstor`, the default VolumeSnapshotClass, which deletes
the snapshot with its VolumeSnapshot. A PersistentVolumeClaim that names the snapshot as its
`dataSource` gets a new volume with that content. A snapshot sits on the same workers as its volume,
so it is not a backup.

### Where the data lives

Every LINSTOR volume and snapshot lives on the workers' data volumes, which belong to the cluster
stack: `just cluster-destroy` destroys them with the stack, and every volume's data with them
([cluster.md](cluster.md#recipes)).

`tests/storage.bats` builds the three applications as Flux applies them; applies the satellite
configuration to the operator's own satellite DaemonSet at the version the pinned chart runs; renders
the nodes' machine configurations offline to check which nodes LINSTOR selects and which device the
pool takes; reads the StorageClasses and the VolumeSnapshotClass; and renders the operator's chart
to check that its definitions are kept.

## Volume backups

VolSync backs an application's volume up to the VolSync bucket
([infrastructure.md](infrastructure.md#s3-keys-and-backup-buckets)) with its restic mover, and
fills the volume from the latest backup when the volume and its restore are created together
(ADR 0015). An application that writes a canary into its volume also has its newest backup restored
and checked every night ([The restore drill](#the-restore-drill)).

`apps/base/volsync-system/volsync/` installs the operator in its own namespace, `volsync-system`,
at the restricted Pod Security level. Its publisher releases the chart only to a classic Helm
repository, so it comes from the public OCI mirror metrics-server's comes from. The release
installs and upgrades the ReplicationSource and ReplicationDestination definitions, each kept when
it is uninstalled. The controller runs two replicas on different nodes, one acting at a time, with
the chart's requests and limits; the application's own disruption budget keeps one through a drain.
The chart's ServiceMonitor sends no credential, so the metrics are served without authorization.
The application names `snapshot-controller`, which VolSync needs installed, and
`prometheus-operator-crds` in `dependsOn`, and sets `wait`.

### Backing up a volume

An application opts in from its `ks.yaml`, before its volume exists, and names `volsync`,
`external-secrets` and `linstor-cluster` in `dependsOn`:

```yaml
spec:
  components:
    - ../../../../../components/volsync
  postBuild:
    substitute:
      APP: <app>
      VOLSYNC_CAPACITY: 1Gi
      VOLSYNC_SCHEDULE: "17 3 * * *"
```

The component backs up one volume per application. `APP` is the application's own name, the
`metadata.name` of its Kustomization: `just kubernetes-check` fails on a `ks.yaml` that adds the
component with any other `APP`, as two applications with one `APP` would share a repository.
`VOLSYNC_CLAIM` names the volume, `APP` when unset; `VOLSYNC_UID` and `VOLSYNC_GID`, 1000 when
unset, are the user and group the movers run as, which must be able to read and write its files.
The component makes:

- the volume, a claim of `VOLSYNC_CAPACITY` on the default StorageClass, whose data source is the
  ReplicationDestination `<app>-restore` ([Restoring](#restoring)). A claim's data source cannot be
  added once the claim exists, so a volume that exists keeps its data;
- the ReplicationSource `<app>`, which backs the volume up on the cron schedule `VOLSYNC_SCHEDULE`:
  it takes a snapshot through the default VolumeSnapshotClass, so the backup is of one moment, and
  restic uploads the files of a volume made from it. An empty volume is not backed up. Each run keeps
  the newest backup of each of the last 7 days, 4 weeks and 3 months, and every 7 days the
  repository is pruned. Each application takes its own minute, so backups do not start together;
- the ExternalSecret `<app>-volsync`, which writes the Secret the movers read
  ([The repository and its password](#the-repository-and-its-password)).

The movers run in the application's namespace, unprivileged: VolSync drops their capabilities and
forbids privilege escalation, and the component gives them a non-root user and group and the
runtime's seccomp profile, as the restricted level requires.

### Restoring

The ReplicationDestination `<app>-restore` restores the latest backup once, when it is created, as
its trigger is manual, and keeps a snapshot of what it restored; VolSync makes the claim from that
snapshot whenever the claim is created.

- When the claim and the ReplicationDestination are created together, on the application's first
  deployment, or after both were deleted, as when the application leaves the tree and comes back or
  the cluster is rebuilt, the volume starts with the latest backup, or empty when there is none,
  once the secret store holds the key `volsync`: on a rebuilt cluster, once the operator has seeded
  it again from the master's file
  ([below](#what-an-operator-does-once-and-what-then-happens-by-itself)).
- A claim deleted and created again while the ReplicationDestination stays gets the snapshot kept
  from that one restore, which after a first deployment is of an empty volume, not the latest
  backup.
- To restore the latest backup into an application that runs: suspend its Kustomization, and its
  HelmRelease when a chart runs it, as drift detection would undo a scale-down; stop the pods that
  use the claim; delete the claim and the ReplicationDestination `<app>-restore`; and resume what
  was suspended. Flux creates both again, the ReplicationDestination restores the latest
  backup, and the claim is made from it. What was written to the volume after that backup is lost.

`APP` and `BACKUP_BUCKET_PREFIX` name the repository, so neither changes once an application has
backups: under a path that holds no repository, restic creates an empty one and the restore
succeeds with an empty volume, without an error.

A claim stays Pending, with the pods that use it, until a pod uses it, as LINSTOR's classes make a
volume once its first pod is scheduled, and until the ReplicationDestination's first restore has
completed and recorded its snapshot in `status.latestImage`; that needs the Secret, so until the
secret store holds the key `volsync` it never completes. A claim whose ReplicationDestination is
gone, or whose recorded snapshot is gone, stays Pending until the ReplicationDestination is created
again. The claim's events say which: `VolSyncPopulatorReplicationDestinationMissing`,
`VolSyncPopulatorReplicationDestinationNoLatestImage`, or `VolSyncPopulatorPVCCreated` once the
volume is being made; a missing snapshot shows in the VolSync controller's log. An application whose
Kustomization sets `wait` is not Ready while its claim is Pending, so it holds up every application
that names it in `dependsOn` until its first restore completes.

### The repository and its password

Each application has a restic repository of its own, `s3:<S3_ENDPOINT>/<BACKUP_BUCKET_PREFIX>-volsync/<app>`,
encrypted with a password of its own. restic creates the repository the first time a mover reaches
it. The ExternalSecret reads the key `volsync` of the ClusterSecretStore `openbao`, whose properties
are `RESTIC_MASTER_PASSWORD`, the master password, and the cluster's S3 key, `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY`. The Secret it writes holds only what its template renders:

- `RESTIC_REPOSITORY`: the repository, from `cluster-config`;
- `RESTIC_PASSWORD`: the application's password, derived from the master;
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`: the cluster's S3 key;
- `AWS_DEFAULT_REGION`: `S3_REGION`, from `cluster-config`.

An application's password is the SHA-256 digest of the master, a slash and the application's name,
with nothing after it, written as 64 lower-case hexadecimal digits. The component writes the master
into no Secret, so one application's Secret opens no other application's repository, and only the
master is kept outside the cluster. To open a repository with restic, `just bao-volsync-password
<file> <app> restic ...` derives the application's password that way from the master in the custody
file and runs the command with the repository, the password and the cluster's S3 key in its
environment, printing none of them: nobody computes a digest at a prompt. Every namespace that
takes the component holds the cluster's S3 key, which reaches every bucket of the project: whoever
can read Secrets there can read, replace or delete any application's backups, though not decrypt
them (ADR 0015).

`secret-rotation.yaml` lists the master as `re-encryption` and the path's other keys, the S3 key,
as `issued`, so `just secret-rotate` refuses both
([Rotating an application's secret](#rotating-an-applications-secret)). The master is not rotated:
a new one opens no repository made under the old one, and no recipe replaces it
([below](#what-an-operator-does-once-and-what-then-happens-by-itself)). A new S3 key, once it is
the one in `.env`, is written with `just bao-seed-volsync --rotate-s3`
([runbook](runbooks/volume-backups.md#replacing-the-clusters-s3-key)).

### What an operator does once, and what then happens by itself

OpenBao starts with its key-value mount empty and nothing Flux applies writes the key `volsync`, so
the operator seeds it, once for each store, after `just bao-recovery`, with the cluster's S3 key in
`.env` (`CLUSTER_S3_ACCESS_KEY_ID` and `CLUSTER_S3_SECRET_ACCESS_KEY`, which
`just infra-s3-key cluster` makes) and `just cluster-config` applied, so the repository's prefix,
endpoint and region are in `cluster-config`:

```sh
just bao-seed-volsync <file>
```

`<file>` is outside the repository, beside the Talos age key: a new file the first time, and the
existing one whenever the store holds no key again, as on a rebuilt cluster (below). The recipe:

- stops before it makes anything when either variable is empty, still a placeholder or the state
  key's, naming the variable;
- with a new `<file>`, makes the master, 32 random bytes from the kernel written as 64 hexadecimal
  digits, which restic and the template's digest take as they are, and writes it to `<file>`
  encrypted with age to the Talos age key's recipient; opens the file again with the operator's
  Talos age key and compares it with what it wrote; and only then creates the key, with the master
  and the cluster's S3 key. The operator role may create and patch keys, and never read or update
  them, so before it makes anything the recipe asks whether the key exists with an empty patch and
  check-and-set 0, which writes nothing: OpenBao answers 404 where there is no key and refuses on
  check-and-set where there is one. A store that holds one is refused before a master is made, no
  `<file>` is made, and the master in the store is never replaced: a master that changes orphans
  every repository, so no flag replaces it. An existing `<file>` is never replaced either, nor one
  made at its path while the recipe runs, as the file goes in place by a hard link: where the
  filesystem makes none, the recipe stops with `ln`'s error and writes nothing to the store;
- given an existing `<file>` that opens with the Talos age key to this cluster's master, while the
  store holds no key, reads the master back from it, makes no other, and creates the key with it,
  leaving the file as it was. That is how a run goes on after a failure between writing `<file>` and
  the store holding the key, as when OpenBao refuses the write or the run is interrupted, which says
  which state it left; and how a rebuilt cluster's store is seeded. A store that already holds the
  key says so and changes nothing, and the file is kept;
- prints what it did and where the file is, never the master or the key, which travel on pipes and
  in the body of the write.

`just bao-seed-volsync --rotate-s3` replaces the S3 key properties of the key with the current
`.env` values and keeps the master, after the cluster's S3 key is replaced. The master's file is its
own and not the recovery keys' file: the two open different things and are needed at different
times, the recovery keys when OpenBao has to be reached with a root token and the master when a
repository has to be opened, and `just bao-recovery` writes its file once and never again, so a
second secret could not be added to it. `<file>` holds the only copy of the master that outlives the
cluster: [the runbook](runbooks/volume-backups.md) says what losing it, or the store's key, means,
and how the store is seeded again from it.

`just bao-volsync-password <file> <app> <command> [argument...]` opens one application's repository
by hand without computing a digest at a prompt: it derives the application's password from the master
in `<file>` as above and runs the command with `RESTIC_REPOSITORY`, `RESTIC_PASSWORD` and the cluster's
S3 key as `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_DEFAULT_REGION` in its environment
and no other secret of the recipe's, so `just bao-volsync-password <file> volsync-demo restic snapshots`
lists the demo's backups. It prints no password and reaches neither the cluster nor OpenBao. restic is
not one of the pinned tools: no recipe or check runs it, and it is the operator's to install for the
rare restore by hand.

After that Flux does the rest, for as long as the store holds the key. `volsync-demo`, in the
overlay, is applied once `volsync`, `external-secrets`, `openbao-store` and `linstor-cluster` are
Ready. The test application
`apps/base/demo/volsync-demo/` is a pod that holds a 1 GiB volume and writes the time it first found
it empty, and the canary of its restore drill, a heartbeat every five minutes
([The restore drill](#the-restore-drill)). Its ExternalSecret writes the Secret the movers read as soon as the store holds the key,
the ReplicationDestination restores the repository's latest backup, which is empty on the first
deployment, the claim is made from that snapshot and the pod starts, and the ReplicationSource
backs the volume up at 03:17 each night. A claim and its restore therefore need no manual step once
the recipe has run.

OpenBao keeps its data on volumes that do not survive a rebuild ([rebuild.md](runbooks/rebuild.md)),
so a rebuilt cluster's store is new and holds no key `volsync`, and every ExternalSecret of the
component, and with it every restore, waits for it. Once `just bao-recovery` has made the new
store's recovery keys, the operator runs `just bao-seed-volsync <file>` with the existing custody
file, never a new one: the recipe writes the master the file holds, which opens the existing
repositories, where a new file would make a master that opens none of them
([runbook](runbooks/volume-backups.md#the-stores-key-is-lost-and-the-file-is-kept)).

`tests/volume-backups.bats` builds the applications as Flux applies them and renders the VolSync
and External Secrets charts to check this section, and `tests/openbao-recipes.bats` runs the
recipes against fakes of the cluster and of OpenBao.

### The restore drill

A backup that is never restored proves nothing, and a restore from a repository path that holds no
backup succeeds with an empty volume and no error ([Restoring](#restoring)). The component
`components/volsync-drill` restores an application's newest backup every night into a scratch claim
of its own and checks what came back, as
[ADR 0008](adr/0008-state-and-backups-are-encrypted-before-they-leave.md) asks of every backup. An
application that writes the canary below takes it beside `components/volsync`, never without it,
in its `ks.yaml`:

```yaml
spec:
  components:
    - ../../../../../components/volsync
    - ../../../../../components/volsync-drill
  postBuild:
    substitute:
      APP: <app>
      VOLSYNC_CAPACITY: 1Gi
      VOLSYNC_SCHEDULE: "17 3 * * *"
      VOLSYNC_DRILL_RESTORE_SCHEDULE: "17 4 * * *"
      VOLSYNC_DRILL_CHECK_SCHEDULE: "17 5 * * *"
      VOLSYNC_DRILL_MAX_AGE: '"95400"'
```

The three variables are required: the build fails without any of them. `VOLSYNC_DRILL_MAX_AGE` is
written with its double quotes, as Flux substitutes after kustomize has dropped a manifest's own
quotes, and a bare number would reach the check's environment as a number, which the API server
refuses for a variable's value. The component reads `APP`, `VOLSYNC_CAPACITY`, `VOLSYNC_UID` and
`VOLSYNC_GID` as `components/volsync` does, and makes:

- the scratch claim `<app>-drill`: `ReadWriteOnce`, of `VOLSYNC_CAPACITY`, on the default
  StorageClass, made empty;
- the ReplicationDestination `<app>-drill`, which restores the newest backup straight into the
  scratch claim on `VOLSYNC_DRILL_RESTORE_SCHEDULE`, with the repository Secret `<app>-volsync`
  the backups use, so no key gets a new holder. `copyMethod: Direct` takes no snapshot of the claim;
  `enableFileDeletion` has restic delete the files the backup does not hold, so the claim holds what
  that backup holds and not every file the volume ever had; `cleanupCachePVC` deletes restic's cache,
  of VolSync's default 1 GiB, after each restore, so each night's restore starts cold, as a real one
  does. Its mover runs with the security context `components/volsync` gives its movers;
- the CronJob `<app>-drill-check`, on `VOLSYNC_DRILL_CHECK_SCHEDULE`, and the ConfigMap
  `<app>-drill-scripts` of its one script, `scripts/check.sh`. The check runs the busybox the demo's
  Deployments pin, by that tag and its digest, as `VOLSYNC_UID` and `VOLSYNC_GID` with no `fsGroup`,
  so it reads the files as the user the mover restored them as and changes nothing on the volume,
  ownership included. It mounts the scratch claim read-only, holds no token, and takes and opens no
  connection. Its job is made within 600 seconds of its time and runs at most 600, a failed check is
  tried once more within that, and two never run at once. A CronJob's name is at most 52
  characters, so an application that takes the drill has an `APP` of at most 40.

Nothing backs up, snapshots or clones the scratch claim. The mover is one of the namespace's movers,
with their flows, the resolver and the object storage ([Network policy](#network-policy)).

**The canary.** The application writes a file `heartbeat` at its volume's root: one line, the Unix
time in seconds and the same moment as `%Y-%m-%dT%H:%M:%SZ`, both UTC, from one `date` call. The
check reads the first field, so it parses no date, as busybox and coreutils read dates differently;
a person reads the second. `volsync-demo`'s pod rewrites it every `HEARTBEAT_SECONDS`, 300: it
writes a new file of the same directory, syncs it to disk and then renames it over the last. A
backup's snapshot holds what is on disk at its moment, as after a crash, and the kernel writes a
file's data to disk later than its name, so a snapshot can hold a file renamed before it was synced
as an empty one; synced first, the heartbeat in a snapshot is the last one or the new one, whole.
Only an application that writes the canary takes the drill: without one, every check fails on the
missing heartbeat. n8n and Open WebUI write none, and their volumes have no drill.

**The check.** It reads `DRILL_DIR`, the claim's mount, and `DRILL_MAX_AGE_SECONDS`, the largest
age, and writes one line to the job's log that names the case. It passes, printing the heartbeat's
age and the bound, when the heartbeat is at most as old as the bound. It fails, with its reason on
standard error and status 1, when the claim holds nothing, or nothing but `lost+found`: the restore
brought nothing back; when it holds files and no `heartbeat`; when the heartbeat's first field is
not a whole number of seconds, or lies in the future; when the heartbeat is older than the bound;
and when either variable is missing or wrong. It writes nothing.

**The largest age**, worked out here and nowhere else. For `volsync-demo` the backup runs at 03:17,
the restore at 04:17 and the check at 05:17, and

    95400 = 86400 + 7200 + 1800

86400 is the backup's interval; 7200 the time from the backup's schedule to the check's; 1800 the
margin: 300, `HEARTBEAT_SECONDS`, as the heartbeat in a snapshot is up to that much older than the
snapshot, 600 and 600, the check's `startingDeadlineSeconds` and `activeDeadlineSeconds`, as a check
can read the volume that late after its time, and 300 for clocks, a slow write and a rename not yet
on disk when the snapshot is taken, which leaves the heartbeat before it in the snapshot.
`tests/volume-backups.bats` reads the three schedules, the bound, the canary's interval and the two
deadlines from what is built and fails unless they hold to this sum, and holds the restore to an hour
after the backup and the check to an hour after the restore, at minutes of the day no other
application backs up or drills at. A healthy night's check finds a heartbeat from a little under
7200 seconds old, as the snapshot is taken some seconds after the backup's minute, to about 8700.
So a drill passes on the newest backup and on the one before it: one missed night is the backup
alerts' to report ([Alerts](#alerts)), and the drill fails on the second. A night whose restore did
not run, or found no snapshot, leaves the previous night's files in the scratch claim, which pass
once more and then fail.

**What a pass proves.** That the repository opens with the password derived for the application,
that restic restores its newest backup, and that the data in it is recent. Not that the application
starts on it. The empty case is the silent failure of a wrong repository path: under a path that
holds no repository, restic creates an empty one and the restore succeeds with nothing, as after a
change of `APP` or `BACKUP_BUCKET_PREFIX`, and the check names it. A path that changes once the
claim holds files leaves those files there, which fail on their age the second night.

**The first deployment.** VolSync synchronizes a new ReplicationDestination at once, then at each
time of its schedule. The scratch claim stays Pending until the mover's pod is scheduled, as the
default StorageClass makes a volume for its first pod, and the mover waits, as the backups' do, for
the repository Secret ([What an operator does once](#what-an-operator-does-once-and-what-then-happens-by-itself)).
Nothing in the application's Kustomization waits for the claim, so a Pending claim holds nothing up.
A check after a restore of a backup that holds no heartbeat, as one taken before the application
wrote it or before its first backup, fails, until a restore after a backup that holds one. A check
before any restore has used the claim, as when the repository Secret comes only after the check's
time, is the claim's first user: the claim is made empty for it, and the check fails on the empty
volume until a restore has run.

**The claim in turn.** The claim is `ReadWriteOnce`: the mover uses it while it restores, VolSync
deletes the mover's Job once the restore ends, and the check uses it an hour later. Any worker
reaches a volume of the default StorageClass, so the check need not run where the mover ran. A check
that starts while a restore still runs reads, on the mover's node, a tree restic is still writing,
which can hold the previous night's heartbeat or none; on any other node it waits for the volume,
attached to the mover's node, until its deadline fails it. The restore's `status.lastSyncDuration`
says how long a restore takes, against the hour before the check.

**UTC.** Both schedulers count in UTC. The CronJob controller reads a schedule that names no
`timeZone` in kube-controller-manager's zone, and VolSync's controller reads a cronspec in its own
(`internal/controller/statemachine/machine.go` at the pinned version); neither image sets `TZ` or
holds `/etc/localtime`, and Talos mounts no zone into the control plane's pods, so Go counts in UTC
in both. The hours between the backup, the restore and the check therefore hold, and no CronJob of
the tree sets `timeZone`.

**What it costs.** Room: the scratch claim at its capacity, a replica on each of two workers, and,
while a restore runs, restic's cache of 1 GiB, the same: at most `VOLSYNC_CAPACITY` and 1 GiB on one
worker, 2 GiB for `volsync-demo` ([The storage pool](#the-storage-pool)). A nightly download from the
object storage: the repository's index and the backup's tree, as the cache starts empty, and the
parts of files that differ from what the scratch claim holds, as restic checks the files already
there and fetches only what does not match; the whole backup the first time and whenever the claim
is made again. A mover's pod and a check's pod a night.

[`RestoreDrillJobFailing`](runbooks/alerts.md#restoredrilljobfailing) fires when the latest check has
not passed half an hour after its time, longer than its two deadlines together, and
[`RestoreDrillStale`](runbooks/alerts.md#restoredrillstale) when no check has passed for 36 hours
([Alerts](#alerts)); [the runbook](runbooks/volume-backups.md#checking-the-first-drill) says what to
read to check the first drill. A check's job that failed also raises the stock `KubeJobFailed` for
as long as the job exists, past later passes, as the CronJob keeps its three newest failed jobs for
their logs: it clears once the job is deleted, after its log is read.
`tests/volume-backups.bats` builds the component as Flux applies it and runs the check's script and
the canary's command as their containers run them, and `tests/network-policy.bats` evaluates the
flows of the drill's mover and its check on the render.

## Envoy Gateway

Envoy Gateway implements the Gateway API: for each Gateway that names its GatewayClass it runs
Envoy proxies, which route traffic as the routes attached to the Gateway say. Two applications in
`apps/base/envoy-gateway-system/` install it:

- `envoy-gateway` installs the controller from its publisher's chart,
  `oci://docker.io/envoyproxy/gateway-helm`: two replicas, never on one node, with leader election,
  the chart's default, so one acts at a time; a disruption budget that keeps one running through a
  drain; the chart's resource requests. It also applies the GatewayClass `envoy-gateway` with the
  controller name the chart configures. A GatewayClass is cluster-scoped; the API server drops the
  namespace the application's `targetNamespace` gives it. The namespace enforces the restricted Pod
  Security level, which the controller, its certificate job and the proxies it creates meet. The
  chart makes no ServiceMonitor or PodMonitor, and the application adds none.
- `envoy-gateway-crds` applies Envoy Gateway's own resource definitions (`gateway.envoyproxy.io`)
  from the same chart at the same tag: an `OCIRepository` unpacks the chart, and an inner
  `Kustomization` applies its `charts/crds/crds/generated` directory, never pruning, as the Gateway
  API's inner `Kustomization` does. The publisher's chart of definitions alone keeps them in
  templates, too large for a Helm release to store.

The chart installs no definitions (`crds.enabled: false`): the Gateway API's come from
`gateway-api-crds`, so there is one copy, and it leaves out the Gateway API's admission policy as
that application does. The controller watches only the kinds whose definitions exist when it
starts, so `envoy-gateway` names both definition applications in `dependsOn`.

The two tags name one package, which Renovate updates in one pull request. Envoy Gateway is built
against one Gateway API release, the one its chart's own copy is of, and works with a newer
release's standard channel while that still serves the versions it reads. `tests/baseline.bats`
fails unless the release `gateway-api-crds` pins has the same major version, is no older, and
serves every stable kind and version of the chart's copy; an Envoy Gateway update that needs a newer
Gateway API therefore waits for `gateway-api-crds` to move first. The tests also render the chart
and build both applications offline to check the rest of this section.

### The public Gateway

`gateway-public`, an application of the same namespace, runs the one Gateway, `public`, of the
GatewayClass `envoy-gateway`. It names `envoy-gateway`, `cluster-ca` (the issuer,
[cert-manager](#cert-manager)), `cilium-bgp` and `blackbox-exporter` (which probes the redirect,
[Probes](#probes)) in `dependsOn`, so it starts once the controller runs, an issuer signs, the pool
and the BGP objects exist and the exporter answers, and takes no change while the exporter's
Kustomization is not Ready ([Probes](#probes)); a cluster that chooses an ACME issuer for its
certificate adds `acme-issuers` ([Choosing the public Gateway's
issuer](#choosing-the-public-gateways-issuer)). It is Ready, with the 10 minute
timeout, once its certificate is issued and the controller reports the Gateway programmed, which it
does once the proxies' Service holds an address and the proxies are available. A cluster whose
overlay does not list it runs no Gateway, and `hello-route`, the application that has a route on it,
cannot be listed without it: `just kubernetes-check` refuses the dependency.

- **Its address.** The Gateway names the `EnvoyProxy` `public` in `infrastructure.parametersRef`.
  That gives the Service the controller makes for the proxies type `LoadBalancer`, the label
  `k8s-gitops/announce: bgp` and the annotation `lbipam.cilium.io/ips: ${GATEWAY_ADDRESS}`, so
  Cilium gives it the one address of the service range the edge routers forward public traffic to,
  and the workers announce that address ([Service addresses](#service-addresses)). No address is
  written in the tree.
- **`externalTrafficPolicy: Cluster`**, where the controller's default is `Local`. Every worker
  announces the address and forwards a connection to a proxy on any node, so a proxy that is
  replaced, drained or moved changes no route an edge router holds, and no connection is reset by a
  route that went away; with `Local` only the workers that run a proxy would announce it, and each
  rollout would withdraw and add routes. `Local` would keep the source of a connection, but the edge
  routers translate every client's address to their own (ADR 0018), so there is no client address to
  keep in the source: what a proxy takes as the client's address is decided as the entry on the
  client's address below says.
- **The proxies.** Two replicas, spread over the workers with a skew of one and never scheduled
  where that fails, under a disruption budget that keeps one running, with requests of 100m of CPU
  and 128Mi of memory and no limits. With a route behind the web application firewall a proxy holds
  far more than that: the filter's module and a VM of it for each worker, measured at about 300 MiB
  more at one worker and 37 MiB on average for each further one
  ([What it costs a proxy](#what-it-costs-a-proxy)). They run as a non-root user with the
  runtime's default seccomp profile, no privilege escalation and no capabilities, which the
  namespace's restricted level requires. The controller makes their Deployment at run time, so no
  render holds it and `just pod-security-check` does not evaluate it; admission enforces the
  namespace's level when the controller creates it. `tests/gateway.bats` asserts the fields of the
  `EnvoyProxy` that produce its pods, and the controller adds its shutdown manager container with
  the same hardened defaults.
- **Listeners.** `http` on 80 for every hostname, and `https` on 443 for `*.${CLUSTER_DOMAIN}`,
  terminating TLS with the Secret `public-wildcard-tls`. They are the ports the edge routers
  translate ([The edge routers](infrastructure.md#the-edge-routers)): `tests/gateway.bats` fails,
  naming both files, when the Gateway's listeners and the edge stack's `public_ports` differ.
- **Redirect.** The `HTTPRoute` `https-redirect`, in the Gateway's namespace, is the only route
  that attaches to `http`, whose `allowedRoutes` admit that namespace alone and `HTTPRoute`s only:
  an HTTP listener that names no kinds takes `GRPCRoute`s too. It has one rule, for every path,
  that sends the request to `https` on the same host and the scheme's default port with status 301,
  and no backend: plain HTTP is never forwarded. `tests/gateway.bats` builds every application the
  overlay enables and fails when a route of any kind other than the redirect names `http`, by its
  section or its port, when a route in the Gateway's namespace names the Gateway without a section,
  which would attach it to `http` as well, or when the redirect is anything but that rule. The
  application's `Probe` `https-redirect` asks the proxies for the 301 from inside the cluster, and
  `hello-route`'s `Probe` for the demo's 200 ([Probes](#probes)).
- **Who may attach.** To `https`, `HTTPRoute`s of the namespaces that carry the label
  `k8s-gitops/gateway: public`, and of no other: the listener's `allowedRoutes` select them by that
  label and name the one kind. A route in a namespace without it is not accepted, which is the
  Gateway API's rule and the controller's to apply; it shows in the route's status, which
  `just gateway-check` reads, and `tests/gateway.bats` proves the selector on the objects. `demo`,
  `ai-system`, `kromgo`, `sso-system`, `backstage`, `monitoring` and `ascender` are the namespaces
  that carry the label, and `tests/gateway.bats` pins that set.
- **The certificate.** The `Certificate` `public-wildcard` asks the `ClusterIssuer` the cluster
  chose, `cluster-ca` by default, for an ECDSA P-256 certificate for `*.${CLUSTER_DOMAIN}` and
  `${CLUSTER_DOMAIN}`, with a new private key at each renewal and the same Secret, so the listener
  does not move. It asks for 90 days, which the cluster's own CA gives and an ACME CA decides for
  itself, and is renewed with two fifths of the lifetime left (`renewBeforePercentage: 40`), which
  holds for any lifetime, and which is more than the third `just gateway-check` treats as too
  little. A `Certificate` rather than the Gateway annotation cert-manager reads, as the annotation
  makes a certificate for each listener's hostname only, so it would leave out the domain itself.
- **TLS.** A `ClientTrafficPolicy` sets 1.2 as the least version a client may use, the
  controller's default stated rather than relied on. The same policy sets the PROXY protocol, below.
- **The client's address.** The policy accepts the PROXY protocol on both listeners, as `optional`:
  a connection that begins with a header takes the header's source as the client's address, and one
  that begins with anything else, a TLS handshake or an HTTP request, is served with the
  connection's own address as the client's. What a proxy takes as the client's address is therefore
  decided by the connection: the source of the header its sender wrote, the client's when that is
  an edge router, or else the connection's own address, an edge router's or that of the worker that
  forwarded it from another node. That address is the one in the access log's `client_address` and
  the one the proxy appends to `x-forwarded-for`, whose client-supplied entries stay to its left:
  no `clientIPDetection` is set, so the controller has the proxies take the connection's remote
  address, which the header replaces, and never the client's own `x-forwarded-for`. The pinned
  controller has `proxyProtocol.optional`, which maps to Envoy's
  `allow_requests_without_proxy_protocol`; the deprecated `enableProxyProtocol` can only require
  the header, and a requirement resets every connection that carries none. `tests/gateway.bats`
  asserts the policy's fields on the rendered objects and not the translated listener: `egctl` is
  not a pinned tool, so the xDS is not rendered. A header is a claim, which Envoy does not check:
  whoever writes the first bytes of a connection to a proxy can name any address, which a client
  cannot through an edge router that writes its own header and can through a sender that forwards
  plain TCP. Of senders inside the cluster, `public-proxy`
  ([What the namespaces let through](#what-the-namespaces-let-through)) admits the blackbox
  exporter's pods alone to the listeners, for the probes of the public hostnames, but only once the
  agents enforce it rather than audit it ([Service addresses](#service-addresses)), and the local
  host of a proxy's node reaches that proxy whatever the policies say; the access log's
  `peer_address` is the socket's own, so a claim shows beside its sender. The probes write no
  header, which `optional` serves, so they are one reason it stays: if the header is ever required,
  the probes go another way, through the edges, first ([Probes](#probes)). The trust model is in
  [ADR 0020](adr/0020-the-client-address-reaches-the-gateway-in-a-proxy-protocol-header.md).
- **Access log.** The `EnvoyProxy` sets one JSON line per request to standard output, which the
  collector reads with the container's other lines ([Logs](#logs)): `client_address`, the address
  Envoy took as the client's; `peer_address`, the connection's own; `host`; `method`; `path`,
  without its query string, which can hold a secret; `status`; `response_flags`; `duration_ms`;
  `bytes_received` and `bytes_sent`. A request no route took is logged as well. It is about 250
  bytes, so a request a second is about 20 MB a day before the store compresses it. Where none is
  set the controller writes a line per request in a format of its own, with the full path including
  its query string, the user agent and the client's `x-forwarded-for`. `tests/gateway.bats` asserts
  the format's keys and that no field names the query or the client's `x-forwarded-for`. Read it
  with
  `just logs 'kubernetes.pod_namespace:envoy-gateway-system kubernetes.container_name:envoy client_address'`,
  which prints each line whole, or count requests by address with
  `just logs 'kubernetes.pod_namespace:envoy-gateway-system kubernetes.container_name:envoy client_address | unpack_json | stats by (client_address) count()'`.
- **What a client outside sees.** `lab-sto2` chooses the production issuer, so a client with the
  usual public roots trusts the certificate; with the cluster's own authority or the staging issuer
  it is signed by a chain nothing outside trusts, so a client refuses it unless it is given the
  authority's certificate. `just gateway-check` connects to each edge router's public address with
  the name the route has, and verifies against the trust the issuer implies, which is public
  material (below), so each edge is proved on its own; the names are in DNS, which
  [DNS records](#dns-records) describes, and the check also asks for one. Only the networks the
  edge stack admits reach the edge's public ports
  ([The edge routers](infrastructure.md#the-edge-routers)), so it is run from one of them.
- **Where the records point.** The Gateway's annotation `external-dns.kubernetes.io/target` holds
  `${EDGE_PUBLIC_ADDRESS_1},${EDGE_PUBLIC_ADDRESS_2}`, which external-dns publishes for every route
  that attaches to it ([DNS records](#dns-records)).

#### Checking the public Gateway

`just gateway-check [cluster]` reads, and changes nothing: the objects through the cluster's
kubeconfig with `kubectl get`, then the edge stack's outputs for the edge routers' names and
floating addresses, then requests through each edge with `curl --resolve`, which proves each edge
on its own whatever DNS says, then the DNS records of the routes' names and one request by a name
alone. It prints pass, FAIL or skip and one line of why for
each check, and exits 0 only when none fails. It never prints an address, a host name under the
domain or a tool's own errors: kubectl's and jq's go nowhere, and tofu's to the edge stack's
errors file, `.terraform/tofu-errors.log` in its directory, which the line about the edges names.
A name it reads from the cluster is printed, or handed to kubectl, only once it is a valid name of
its kind, and always after `--`, so it cannot become a flag; any other text it shows from the
cluster or an answer has its control characters replaced. kubectl waits at most 10 seconds for an
answer and curl 15, and curl reads no `.curlrc`, uses no proxy and follows no redirect. Every
request through the edges trusts what the `cluster CA` or `issuer trust` line names, and the
lookups of DNS records go to a public resolver (below) and trust the system's public trust store
as curl has it; the variables that add trust, `CURL_CA_BUNDLE`, `SSL_CERT_FILE` and
`SSL_CERT_DIR`, reach neither, as the recipe unsets them. It needs curl 7.88 or newer. A failure
that is none of the checks, such as an answer it cannot read, names the step it happened in, and
so does Ctrl-C or SIGTERM, which stops the run there.

- `cluster-config`: the ConfigMap holds `CLUSTER_DOMAIN` and `GATEWAY_ADDRESS`, which the lines
  below compare with. Without it, those lines are skipped.
- `Gateway`: `public` is Accepted and Programmed; a FAIL gives the condition's reason.
- `Gateway address`: the Gateway's status gives the `GATEWAY_ADDRESS`.
- `proxy Service`: the Service Envoy Gateway makes for the proxies, selected by its labels for the
  Gateway, is of type `LoadBalancer` and carries `k8s-gitops/announce: bgp`, without which no
  worker announces it.
- `proxy Service address`: that Service holds the `GATEWAY_ADDRESS`. While another Service holds
  the address, Cilium gives this one none.
- `proxies`: two proxies or more are Ready, on different nodes; a FAIL names the nodes.
- `certificate`: the `Certificate` whose Secret the `https` listener serves is Ready; a FAIL gives
  the Ready condition's reason, as cert-manager sets it, cut and made printable as every reason is.
- `certificate lifetime`: at least a third of the certificate's lifetime is left, from the
  `Certificate`'s `notBefore` and `notAfter`; a FAIL gives the hours left of the hours it lasts, or
  how long ago it ended. cert-manager renews well above that, so less means a renewal that has been
  failing. The line is skipped for a `Certificate` that has not been issued.
- `issuer trust`: for a Let's Encrypt issuer, what the answers through the edges are verified
  against, and the line says which. For production, the system's public trust store as curl has it,
  nothing added and nothing set aside, the variables that add trust (`CURL_CA_BUNDLE`,
  `SSL_CERT_FILE`, `SSL_CERT_DIR`) not passed on, and no Secret is read. For staging, whose chain no public
  store holds, the issuing certificates of the `Certificate`'s own Secret: `tls.crt` holds the leaf
  and the chain as cert-manager stores them, and the recipe gives curl the certificates after the
  leaf, never the leaf, as the only trust; curl accepts an intermediate as an anchor through its
  partial-chain verification, which is its default with the OpenSSL backend from curl 7.68, so the
  check needs that backend and version. That proves the answer is signed by the issuer
  cert-manager stored, with the names and validity curl checks, and not public trust: the chain
  comes from the cluster, not from the CA, and the check fetches nothing from the network beyond
  its requests to the edges. A directory that is neither Let's Encrypt's fails the line.
- `cluster CA`: for an issuer of kind CA, the authority's certificate is read: `tls.crt` of the Secret the `ClusterIssuer`
  the `Certificate` names signs with, in `cert-manager`. kubectl receives the whole Secret from the
  API server and prints only that key, through a jsonpath that names it; the recipe never prints
  or writes the private key. cert-manager's own documentation calls the `ca.crt` of an issued
  Secret a best guess, while the issuer's `tls.crt` is the authority's certificate itself. The
  certificate is kept in a file of the run, never printed, and removed at its end.
- `routes`: no `HTTPRoute` is Accepted on `public` from a namespace without
  `k8s-gitops/gateway: public`, but for the redirect in the Gateway's own namespace; a FAIL names
  the routes. A route in such a namespace is reported by the controller as not accepted, which is
  the Gateway API's rule; this line reads that status for every route.
- `http listener`: the Gateway reports one route on `http`, the redirect.

Then, for each edge router, by its name; while the edge stack has no outputs, one line, `edges`,
says they are skipped, and it fails when they cannot be read:

- `<edge> http`: plain HTTP on 80 for `hello.${CLUSTER_DOMAIN}/gateway-check` answers 301, and its
  `Location` is `https://hello.${CLUSTER_DOMAIN}/gateway-check`: the same host and path, the
  default port. Any other status or place fails.
- `<edge> TLS`: HTTPS on 443 for `hello.${CLUSTER_DOMAIN}` verifies against the trust the issuer
  implies and nothing else, the chain and the name, as curl verifies them. For a CA and for
  staging that is the file `--cacert` names; curl trusts what is in its CA path as well, and some
  builds come with one, so the recipe also gives it `--capath`, an empty directory of the run. For
  production it is curl's own trust store, given nothing.
- `<edge> certificate names`: the certificate served names `hello.${CLUSTER_DOMAIN}`, read from
  what curl shows of it. When TLS fails, this line says whether the names are the cause or the
  chain is.
- `<edge> hello`: the demo answers 200 with the page of its ConfigMap `demo/hello`.
- `<edge> unrouted host`: a host under the domain that no route serves,
  `gateway-check-unrouted.${CLUSTER_DOMAIN}`, answers 404.

The last two are skipped when TLS fails. Then, with the edge stack's outputs, the names the routes
publish ([DNS records](#dns-records)), none of which is looked up while the edge lines are skipped:

- `DNS records`: one line, in place of the two below, when there is nothing to look up: skipped
  when the cluster does not select external-dns, which is whether its Kustomization exists in
  `flux-system`, and when no route accepted on `public` from a namespace that opts in names a host
  under the domain; FAIL when the Kustomization cannot be read, and skipped when the routes cannot
  be, which the `routes` line has already failed.
- `DNS <label>`: for each host under the domain that such a route names, by its first label, the
  public resolver's A records are exactly the two edge routers' addresses. The answer counts only
  as one JSON document with the status NOERROR whose records are all A records of the host itself,
  each one address: a CNAME, a record of another name, an error status and a second document each
  fail, whatever addresses come with them. A FAIL says which: the resolver could not be asked, its
  answer is not readable, the name does not exist, the status is another error, a record is not an
  A record of the name, there is no address record, it gives one of the two addresses, or it gives
  others. The lines never print an address.
- `name hello`: a request for `https://hello.${CLUSTER_DOMAIN}/` by that name alone, with no
  `--resolve`, so curl resolves it as this machine does and reaches whichever edge its resolver
  names, verifies against the trust the issuer implies, as the edge lines do, and gets the demo's
  page. It is made only
  once `DNS hello` passes and every edge line passed, so it never repeats another line's failure,
  and is skipped otherwise, saying why.

The lookup is one `curl` request to Google Public DNS's JSON interface over HTTPS,
`https://dns.google/resolve?name=<host>&type=A`, which a resolver outside the cluster and outside
the DNS provider answers, as a client outside would be answered. It sends each host name it
checks to that resolver, which is the one disclosure of the check; no cluster object, address or
key goes with it. The recipe uses curl because it needs no tool that is not already on the machine
(`dig` and `getent` are not pinned tools, and `getent` would ask the machine's own resolver, which
caches a name that did not exist for as long as the zone's negative TTL). curl's own `--doh-url`
would verify the resolver's certificate with the options of the request it serves, which trust what
the issuer implies, the cluster's authority alone for a CA issuer, so the lookup is a request of
its own, verified against the system's public trust store with nothing added. A name made a
minute ago can still be missing from the resolver for as long as the answer it gave before was to
be cached, which the FAIL says.

`tests/gateway-check.bats` runs the recipe against fakes of kubectl, curl and the edge stack, every
answer holding addresses.

#### Giving an application a public hostname

1. Label the application's namespace in its `namespace.yaml` with `k8s-gitops/gateway: public`.
2. Add an `HTTPRoute` whose `parentRefs` name the Gateway `public` of `envoy-gateway-system` and its
   `https` listener, and whose `hostnames` are under the domain: `<name>.${CLUSTER_DOMAIN}`. The
   listener and the certificate cover that domain only, so a name outside it is not served, and
   external-dns makes no record for one. Name at least one host: a route without a hostname would
   publish the listener's wildcard.
3. Name `gateway-public` in the `dependsOn` of the application that holds the route, so a cluster
   without the Gateway cannot enable it: an application of its own, as `apps/base/demo/hello-route/`
   is, or the application that owns the Service, as `ai-system/n8n` does
   ([Applications](#applications)).
4. Give the policy `public-proxy`
   (`apps/base/envoy-gateway-system/envoy-gateway/app/ciliumnetworkpolicy.yaml`) a rule that lets
   the proxies reach the backend, as its rules for `hello` and n8n do: the pods its Service selects,
   in its namespace and that namespace's label, on the container port the route sends to. The
   proxies reach those backends alone, and `tests/network-policy.bats` fails until the rules name,
   in each labelled namespace, exactly the ports the routes send to there.
   In a namespace with the default deny, the backend also takes the proxies on that port
   ([Declaring an application's flows](#declaring-an-applications-flows)).
5. Declare the route's `Probe` in that application, beside the route: copy `hello-route`'s
   `probe.yaml`, change its name and its `hostname` label to the route's hostname, and the path of
   its target to one the application answers 200 without a session where `/` does not, and nothing
   else, as a `Probe` with a field, a target, a label or a relabeling more does not count; list it
   in the application's `kustomization.yaml`, and add `blackbox-exporter` to its `dependsOn`, so a
   cluster without the exporter cannot enable it ([Probes](#probes)). A route behind the cluster's
   sign-in copies `demo/hello-sso`'s instead, whose module `public_https_signin` expects the
   redirect to sign-in. Add the route's name to the routes, and the `Probe`'s path to the paths,
   that `tests/probes.bats` pins for the tree: it fails on those pins first, and then, naming the
   route and the hostname, when a route has no `Probe` for a hostname with the module it needs. A
   route the application's chart renders from its release's values is held to the same, as the test
   reads the render.

The record for the name is made by external-dns within a minute or two of the route being accepted,
and removed when the route is; there is no DNS step to do by hand ([DNS records](#dns-records)).

A route is put behind the web application firewall with one more component in the same `ks.yaml`
([Web application firewall](#web-application-firewall)).

`hello`, the demo's workload, answers this way at `hello.${CLUSTER_DOMAIN}`: two replicas of
busybox's web server, spread over the workers and held by a disruption budget of one, as an
unprivileged user, serving a page from its ConfigMap.

### DNS records

`external-dns` runs in its own namespace, `external-dns`, at the restricted Pod Security level its
pod meets: `apps/base/external-dns/external-dns/`, from the publisher's chart through the public
OCI mirror metrics-server's comes from, as the publisher releases it only to a classic Helm
repository. It names `openbao-store`, `gateway-public` and `prometheus-operator-crds` in
`dependsOn`, so a cluster whose overlay lists it without the Gateway is refused by
`just kubernetes-check`, and it is Ready once its release is. One replica runs, as the chart allows
no more, with a request of 10m of CPU and 32Mi of memory and no limit. The chart also installs two
cluster-wide definitions, `dnsendpoints.externaldns.k8s.io` and `dnsrecords.externaldns.k8s.io`,
from its `crds/` directory, which no value of the chart turns off and the root's release defaults
create and replace as every chart's; nothing in the tree uses them, the source reads none, and
removing the application leaves them, as Helm never deletes what `crds/` installed.

- **What creates a record.** A route of the public Gateway: external-dns reads `HTTPRoute`s only
  (`--source=gateway-httproute`, no Service and no Ingress) and only those attached to the Gateway
  `public` of `envoy-gateway-system` (`--gateway-namespace`, `--gateway-name`). For each host the
  route names it makes an A record at the DNS provider, Cloudflare. Its permissions are the chart's
  for that source and no more: a ClusterRole that reads Gateways, HTTPRoutes and Namespaces,
  cluster-wide because the routes are in every namespace that opts in
  ([The public Gateway](#the-public-gateway)). A route that names no host, or a wildcard, is the
  only way the listener's wildcard `*.${CLUSTER_DOMAIN}` would be published, so
  `tests/external-dns.bats` fails for a route on the Gateway without a concrete hostname.
- **Where it points.** At both edge routers' public addresses, not at the Gateway's address: the
  Gateway's status holds `GATEWAY_ADDRESS`, a private address of the service range, which
  external-dns would publish if nothing said otherwise, and which no client outside reaches. The
  Gateway's annotation `external-dns.kubernetes.io/target` holds
  `${EDGE_PUBLIC_ADDRESS_1},${EDGE_PUBLIC_ADDRESS_2}`, and the source takes that in place of the
  status. The pinned version reads the annotation under the prefix `external-dns.kubernetes.io/`,
  not the `alpha` prefix of earlier releases. `tests/external-dns.bats` fails when the annotation
  is missing or holds one address, and when anything else in the tree sets a target or names
  either address. The two keys of `cluster-config` come from the edge stack's outputs
  ([Before Flux starts](#before-flux-starts)); `just cluster-config` refuses while the stack has
  none, as it refuses while the BGP numbers are missing, so a cluster without an edge stack cannot
  enable this application. A `cluster-config` that does not hold the two keys, as one written
  before they existed, leaves the annotation a lone comma once Flux substitutes, which is no YAML
  value: `gateway-public` then fails to build and holds back what names it, this application
  among them, while the Gateway as last applied keeps serving. So `just cluster-config` runs, with
  the edge stack applied, before a change that adds a key to it reaches the cluster.
- **What is never touched.** A name outside the cluster's domain. external-dns matches the DNS
  provider's zones and every record's name against one filter, `--regex-domain-filter`, which the
  HelmRelease builds from `${CLUSTER_DOMAIN}` and `${CLUSTER_DNS_ZONE}` with their dots escaped:
  `\A(<zone>|(.+\.)?<domain>)\z`. It admits the domain and the names under it, and the zone's own
  name, and nothing else: not the zone's other names, not the domain's siblings or parent, not a
  name that only ends like the domain. The zone's name is in it because the provider chooses the
  zones it works in with the same filter, and a filter of the domain alone matches no zone when the
  domain is a name under its zone: every sync would then succeed and change nothing. So when the
  two differ, the zone's own name is the one name outside the domain the filter lets through. No
  record is made there: a route on `https` publishes only names its listener's
  `*.${CLUSTER_DOMAIN}` covers, as the source intersects a route's hostnames with its listener's;
  `http` takes the redirect alone, which names no host, and `tests/gateway.bats` fails for any
  other route on it; and a record of the zone's own name that this cluster's registry does not own
  is never changed or deleted (Ownership). `CLUSTER_DNS_ZONE` is a key of `cluster-config`, which
  `just cluster-config` fills from the environment variable of that name, or from `CLUSTER_DOMAIN`
  when that is unset, and refuses when the domain is neither the zone nor a name under it
  ([Before Flux starts](#before-flux-starts)). While the cluster's `cluster-config` holds no
  `CLUSTER_DNS_ZONE`, the chart refuses to render, naming the key, so the release fails rather than
  run with a filter that selects no zone. `tests/external-dns.bats` checks the rendered filter for a
  domain that is its zone and for one two labels under its zone, against names on both sides of
  it. A route that names a host outside the domain makes no record. Only A records are managed
  (`--managed-record-types=A`): the edges' addresses are IPv4, and nothing else in the zone is
  written. The provider's proxy is off, its default (`--cloudflare-proxied` is not set): the edge
  routers take the traffic directly, with the cluster's certificate, whereas with the proxy on the
  provider would answer for the name with its own addresses, hide the edges, and terminate TLS
  with a certificate of its own. A TTL is set where a route sets none: 300 seconds (`--min-ttl`).
- **Ownership.** The registry is TXT records (`--registry=txt`) beside each record, named with the
  prefix `extdns-<type>.`, whose owner is `--txt-owner-id`, the cluster's name. A cluster sets it
  in one place, a patch in its overlay on the Kustomization `external-dns` that substitutes
  `DNS_OWNER_ID`, as it chooses the Gateway's issuer
  ([Choosing the public Gateway's issuer](#choosing-the-public-gateways-issuer)); the base holds a
  placeholder, which `tests/external-dns.bats` fails while lab-sto2's overlay leaves it.
  external-dns changes or deletes only a record that has a registry entry of its owner, so two
  clusters that share a zone never touch each other's records, and a record made by hand, which has
  none, is never taken over, even when a route asks for the same name.
- **Removal.** The policy is `sync`: external-dns creates, updates and deletes, so a removed
  route removes its records. `upsert-only` would never delete: every route removed or renamed
  would leave its record at the edges, naming a host no route serves, for good. `sync` is safe
  here because the registry confines what it deletes to this owner's records. Removing the
  application itself deletes nothing: it stops, and the records and their TXT entries stay in the
  zone, to be taken over by an instance with the same owner or deleted by hand.
- **The token.** An `ExternalSecret` in `external-dns` reads the key `api-token` of
  `cert-manager/cloudflare` from the ClusterSecretStore `openbao`, which serves every namespace
  ([How an application gets a secret out](#how-an-application-gets-a-secret-out)), into the Secret
  `external-dns-cloudflare`. It is the store entry the ACME issuers' `ExternalSecret`
  `cloudflare-api-token` reads into cert-manager's namespace ([The ACME issuers](#the-acme-issuers)):
  one token, whose Secrets are in those two namespaces and in no other, which
  `tests/external-dns.bats` checks over everything the overlay applies. The pod takes it as
  `CF_API_TOKEN` by reference; no value is in the tree. The token is a requirement on the
  operator: one Cloudflare API token with Zone read and DNS edit on the cluster's one zone, which
  `just bao-put cert-manager/cloudflare api-token` writes. A new token is written the same way,
  for both readers at once (`secret-rotation.yaml` lists the key as `issued`); the container takes
  it from its environment when it starts and nothing restarts the pod, so an operator restarts it
  once the Secret holds it, before the old one is revoked. Without the key the ExternalSecret
  reports it missing and the pod does not start; a token the provider refuses, revoked or without
  the scope, ends the process at its first sync, so the pod crash-loops. `ExternalDNSSyncStale`
  reports both, as no external-dns reports a sync. No zone identifier is set (`--zone-id-filter`),
  as one is a deployment value: the filter above selects the zone by its name. A `CLUSTER_DNS_ZONE`
  that names no zone the token can read selects none, and every sync then succeeds and changes
  nothing, which the alert does not see; `just gateway-check`'s DNS lines fail then, as no name
  resolves to the edges.
- **How soon.** A sync every minute (`--interval=1m`) and one when a route changes
  (`--events`), at most one in 30 seconds (`--min-event-sync-interval`), so a new route's record is
  in the zone within a minute or two, once the route is accepted. A sync that changes nothing asks
  the provider for the zone's records, a few requests of the 1200 per five minutes the provider
  allows; with a route changing every 30 seconds, as often as it is allowed, it is a few requests
  per sync and under a hundred in five minutes. Resolvers cache an earlier answer: a name looked
  up before its record existed can stay missing for as long as the zone's negative TTL.
- **Seeing what it did.** Its log: `just logs 'kubernetes.pod_namespace:external-dns' --since 15m`
  prints each record it creates, updates and deletes, and each error the provider gives, and
  `just gateway-check` says whether the names resolve to the edges
  ([Checking the public Gateway](#checking-the-public-gateway)). Its metrics are scraped through the
  chart's ServiceMonitor, and the alert `ExternalDNSSyncStale` fires when its last successful sync
  is more than 10 minutes old or when no external-dns reports one ([Alerts](#alerts)).

`tests/external-dns.bats` builds the application as Flux applies it, renders the chart with its
values, and checks the arguments, the permissions, the targets, the owner, the token's path and the
dependencies; `tests/gateway-check.bats` the check's lines.

### CrowdSec

CrowdSec reads the public Gateway's access logs, recognises the clients that scan the Gateway, probe
it for files and fail to sign in again and again, and records a decision for each. Nothing enforces a
decision: they are listed and counted, and block nothing; the one alert is on the local API being
down. It is selected by three entries
of a cluster's overlay, the namespace directory `crowdsec` and the Kustomizations `crowdsec` and
`crowdsec-gateway-logs`, and a cluster that lists none builds none of it. `crowdsec`'s `dependsOn`
names Cilium, `crowdsec-gateway-logs`, External Secrets, LINSTOR and the Prometheus Operator
definitions, and sets `wait`, so `just kubernetes-check` refuses a cluster that lacks one of them;
`crowdsec-gateway-logs` names the public Gateway.

- **What it reads.** The Gateway's proxies write one JSON line per request to standard output
  ([The public Gateway](#the-public-gateway), Access log), in a format of this tree's own that no
  parser of CrowdSec's hub reads. The agent reads those lines through the Kubernetes API, not from
  the nodes' log files: CrowdSec's Kubernetes datasource lists and watches the pods one label selector
  names in one namespace and follows their containers' logs, so no path of the node is mounted and
  the agent is one pod. The selector is the labels the controller gives the proxies of the public
  Gateway, `envoy-gateway-system` is the namespace, and nothing else's lines reach CrowdSec; the
  acquisition is `acquisition.yaml` of the application, mounted into the agent's `acquis.d`. The
  chart's schema lists no such datasource and its template refuses to render without one, so the
  chart's own acquisition is a placeholder: a file source on a path that is not in the pod, which
  reads nothing. Those two files are the only acquisitions the agent's container mounts, and its
  configuration does not move the two places the image reads acquisitions from, that file and that
  directory. The agent's service account `crowdsec-agent` is bound by the Role
  `crowdsec-agent-gateway-logs` of `crowdsec-gateway-logs`, in the proxies' namespace, to get, list
  and watch pods and to get their logs, and to nothing else; a Role names no pod, so the grant is the
  namespace's pods, and the selector is what narrows the reading. No other role, of a namespace or
  of the cluster, is bound to it by the application or its chart, and no other binding that an
  application of the overlay builds names the account. The proxies' pods hold the shutdown
  manager's container as well, whose lines are not access logs and fall through the parser
  unparsed.
- **What it decides.** The parser `k8s-gitops/envoy-gateway-json-logs`, this tree's own and in the
  release's values, turns each line into an event with the client address, the host, the method, the
  path and the status, and a time, which the access log does not carry: the time the agent read the
  line. Three scenarios, each this tree's own and in the same values, pour the events into leaky
  buckets, one per client or per client and host, so one client's requests never fill another's:

  | Scenario | Counts | In a bucket per | Overflows above | Leaks one every |
  | --- | --- | --- | --- | --- |
  | `k8s-gitops/http-probing` | distinct paths answered with 400, 403 or 404, static files left out | client and host | 10 | 10s |
  | `k8s-gitops/http-sensitive-paths` | distinct paths of the kind scanners ask for first, `.env`, `.git`, `wp-login.php`, `xmlrpc.php` and the like | client | 3 | 30s |
  | `k8s-gitops/http-auth-failures` | answers with 401 | client and host | 10 | 30s |

  A bucket that overflows raises an alert for its client's address: no scenario names a scope of
  its own, so the address is the one the parser took from `client_address`. The image's profile
  turns an alert into a ban decision of four hours for the address. The
  access log has no user agent and no query string, so the hub's scenarios that need either (a bad
  user agent, SQL injection and cross-site scripting probes, and the crawlers' allow lists) cannot
  run on it and are left out; so are the ones that read the body of a request, which no log holds.
  The image's own allow lists apply: private ranges and the public resolvers' addresses are never
  decided on, and nor, by its post-overflow items, are Cloudflare's address ranges and Google's
  special crawlers'. Its other two, which whitelist search engine crawlers by address and by the
  name a reverse lookup of the address gives, are removed, because that lookup leaves the cluster
  (the table below).
- **The address a decision names.** Envoy takes the client's address from the PROXY protocol header
  an edge router writes ([ADR
  0020](adr/0020-the-client-address-reaches-the-gateway-in-a-proxy-protocol-header.md)), and the log
  names it beside the socket's own peer. The header is a claim of whoever writes the first bytes of a
  connection: a client cannot make it through an edge router, and a sender inside the cluster that can
  open a connection to a proxy can, which the policy of the proxies' namespace refuses only once the
  agents enforce it rather than audit it ([Service addresses](#service-addresses)). A decision on an
  address is therefore as good as who can reach a listener: a forged claim names an address that
  never made the requests and gets it a decision. That is one reason nothing enforces them. The parser
  makes the other case safe: a connection that carried no header has the connection's own address as
  its client address, an edge router's or a node's, and a ban on it would block every client of that
  edge, so such a line is whitelisted by the parser and no scenario sees it.
- **What it is loaded from.** The chart is CrowdSec's own, from its classic Helm repository, pinned by
  version, and the image is pinned by tag and digest. Renovate proposes both and merges neither by
  itself, whatever the auto-merge switch says: a rule of `.renovate/automerge.json5` holds every
  file of the application back, because the required check does not run the image (below), so a
  person runs `bats tests/crowdsec.bats` on a machine with docker before merging an update of
  either. Nothing is installed from
  the hub by a collection, because `cscli` installs the version a hub branch holds, which moves, and takes
  none from the command line, and the image's entrypoint names none; the parser and
  the scenarios are the release's values, and `tests/crowdsec.bats` fails when a variable of either
  pod installs a collection, a parser, a scenario or a post-overflow from the hub. The agent loads the
  image's `linux` collection with them, which reads syslog and sshd and nothing the proxies write, and
  its `whitelist-good-actors` collection, whose items are the allow lists named above. The image's
  entrypoint installs two container-log parsers at every start, which no value turns off; with
  `cscli.hub_branch` set they are written from the content the image's own hub index embeds, so
  nothing is fetched, and they select labels this tree's acquisition never sets, so they read nothing.
  The agent's one variable, `DISABLE_POSTOVERFLOWS`, makes the entrypoint remove two of the image's
  post-overflow items before the agent starts, the one that looks up an address's name and the one that
  reads its result; the test runs the image with the variable and fails when an overflow makes the
  lookup.
- **Where it runs.** In `crowdsec`, a namespace of its own that enforces the baseline Pod Security
  level, not `security-system`, where Falco runs at the privileged level
  ([Runtime detection](#runtime-detection)): CrowdSec needs no host path and no capability, and a
  namespace that admitted them would only widen what its pods may do. The image runs as root, which
  no value of the chart changes, so the local API and the agent are entries of
  `pod-security-exceptions.yaml` at baseline, with no capability, no privilege escalation, the
  runtime's seccomp profile and no host path. The namespace holds the default deny
  ([Network policy](#network-policy)): the local API takes the agent on 8080, Prometheus on 6060 and
  the kubelet's probes, and sends nothing; the agent takes Prometheus and the kubelet on 6060 and
  sends to the resolver, the local API and the Kubernetes API, and to nothing else. The policies are
  audited, not enforced, while the agents audit ([Service addresses](#service-addresses)), so until
  they enforce, the table below is what the configuration says and the policies are what would
  refuse the rest. The local API's database and configuration directory are two small claims of the
  default StorageClass, not backed up. Decisions in a lost database are lost: the agent reads only
  the lines the proxies write after it starts, so only new requests decide again, and it registers
  again at its next start. The secrets the local API and its agents share, a session key and a
  registration token, are made once in the cluster by External Secrets' Password generators into
  the Secret `crowdsec-lapi-secrets`, which the release reads by name, never by a person and never
  in the tree; an agent registers with the token at every start, and the local API accepts that
  only from the private ranges and the loopback, which the pod range is in, as the chart's default
  configuration has it. It registers under its pod's name, and the local API keeps every machine
  that registered, so each new pod of the agent, after a rollout or a drain, leaves one more row
  in `cscli machines list`; `cscli machines prune --force`, run in the local API's pod, removes
  the machines that have sent no heartbeat for ten minutes, which a running agent sends every
  minute, and every machine that was never validated; registration with the token validates one at
  once. The name is also why a pod of the agent that runs its init container a second time, as
  Kubernetes does when the pod's sandbox is made again, cannot start: the init container registers
  that name again, the local API refuses a machine it already holds, and the pod stays in
  `Init:CrashLoopBackOff` with `user already exist` in the log of `wait-for-lapi-and-register`.
  `kubectl --namespace crowdsec get pods` shows it, and the local API's alert does not, as the local
  API runs. Deleting the pod makes one under a new name, which registers; `cscli machines delete
  <pod name>` in the local API's pod lets the same pod register again.
- **What leaves.** Nothing about the cluster's traffic. The local API runs with the Central API off,
  by the variable the image reads, which turns off its registration, its signals, its metrics and its
  pull of the community blocklist, and no console enrolment is configured. An acquisition can call
  out too, to a log store or a cloud's API, and the agent's two, above, read the Kubernetes API and a
  path that is not there. The table lists the other calls: the ones the image makes outside a
  cluster as it ships, and the ones its variables, a notification and a threat intelligence key turn
  on, each with what decides it and its state:

  | Call | What leaves | Variable | State |
  | --- | --- | --- | --- |
  | Central API registration | a request to register the instance with its generated machine identity | `DISABLE_ONLINE_API` of the local API | off |
  | Signals to the Central API | the scenario, the time and the address of each alert | `DISABLE_ONLINE_API` of the local API | off |
  | Metrics to the Central API | the names, versions and last contacts of the local API's machines and bouncers, and the usage metrics its agents and bouncers report to it | `DISABLE_ONLINE_API` of the local API, which removes the online client both pushes go through | off |
  | Community blocklist | a pull of decisions; nothing of the cluster | `DISABLE_ONLINE_API` of the local API | off |
  | Console enrolment | the instance's identity and its tags | `ENROLL_KEY` of the local API, unset | off |
  | Version check | a request for the latest release, which `cscli` makes to learn which hub branch to use | `cscli.hub_branch` of the agent's configuration, set to `master`, which skips it | off |
  | Reverse DNS lookups | the address of each overflow, as a query to the cluster's resolver, which forwards it out of the cluster to the nameservers of the address's reverse zone | `DISABLE_POSTOVERFLOWS` of the agent, which removes `crowdsecurity/rdns` and `crowdsecurity/seo-bots-whitelist`; the local API's pod keeps both and reads no line (below) | off |
  | Hub index and items | requests for the files of two parsers | `cscli.hub_branch`, which makes the image's entrypoint write them from the index it embeds | not made |
  | Notifications | each alert, to where one of the image's notification plugins sends it: an HTTP endpoint, Slack, Splunk, Sentinel or a mail server; the sixth writes a file in the pod | a profile's `notifications`, in `config.profiles.yaml`, and the plugins' settings, in `config.notifications`, both unset, so the image's profile is the one in use and names no plugin | off |
  | Threat intelligence lookups | an address a parser or a scenario asks CrowdSec's threat intelligence service about | `api.cti` of a pod's configuration, unset in both, and no parser or scenario of the release calls `CrowdsecCTI` | off |

  With the branch named the entrypoint fetches nothing, so the agent's policy has no rule for the
  hub's host and none for a name, and `tests/crowdsec.bats` holds both out; it also starts the agent
  as its pod does, with no network, and fails when any name but the local API's is looked up. The
  agent's enrichment works from the databases the image carries: at start the entrypoint links its
  GeoLite2 city and ASN databases into the data directory, so addresses carry a country and an
  autonomous system and the lookups are local. The local API's pod runs the image's log processor
  beside the API: the chart starts that pod with a script of its own, which starts CrowdSec whole.
  That log processor reads the image's own acquisition, a file source whose path is not in the pod,
  so it reads no line and raises no overflow, and the post-overflow items it keeps, the one that
  looks up names among them, have nothing to look up; the same test starts that container as its pod
  does, with no network, and fails unless it answers its health endpoint, looks up no name but the
  loopback's, where its log processor logs in, and loads that one acquisition, which matches no
  file. A change that turns a row on is a decision recorded first; `tests/crowdsec.bats` fails when
  a variable, a file of the release, a values key, an init container or a policy that would turn one
  on appears, refuses a post-renderer on the release, which it does not apply, and asserts the
  state of every row.
- **What enforces decisions: nothing.** Decisions are not enforced. A bouncer is what enforces one,
  and none is built here, for three reasons. The address is a claim until the agents enforce policy,
  so enforcing a decision would let any sender inside the cluster that reaches a proxy cause the ban
  of an address it names. The public Gateway's routes that opt in to [sign-in](#sign-in) already carry
  an external authorisation `SecurityPolicy` that does not fail open, and Envoy Gateway applies one
  `extAuth` to a route: of two `SecurityPolicy` objects that target the same route the oldest takes
  precedence and the other's settings are not applied, and a policy that targets the Gateway
  gives way, for a route that has one of its own, to the route's (only the most specific
  configuration takes effect unless the route's policy sets `mergeType`). An authorisation `SecurityPolicy` for a bouncer
  therefore does not combine with the sign-in's on a route, and could cover only routes without
  one, or only the Gateway until a route opts in; a processor through an `EnvoyExtensionPolicy`
  is a different extension that the sign-in's policy does not compete with, and would be weighed
  first. And the edge routers see every client's address first and an nftables bouncer there would
  drop it before it reaches the cluster, but the edges are rebuilt from their own stack, which a
  change to CrowdSec does not touch. Either route is its own change, built to fail open (a bouncer
  that cannot reach the local API allows), tested in a mode that only logs what it would block, and
  given its own decision first. `tests/crowdsec.bats` fails when a `SecurityPolicy`,
  `BackendTrafficPolicy`, `EnvoyExtensionPolicy` or `EnvoyPatchPolicy` of the tree names CrowdSec or
  a bouncer, or when any object of the Gateway API's groups that an application of the overlay
  builds does: a route, a policy, a filter or a grant across namespaces. Until then the decisions
  are what an operator reads, below, and the one alert says whether the local API runs.
- **Listing decisions and deleting one.** With the cluster's kubeconfig:
  `kubectl --namespace crowdsec exec deployment/crowdsec-lapi -- cscli decisions list` lists the
  decisions, `cscli alerts list` the alerts behind them and `cscli alerts inspect <id> -d` one alert
  with the events that made it;
  `kubectl --namespace crowdsec exec deployment/crowdsec-lapi -- cscli decisions delete --ip 203.0.113.7`
  deletes the decision on an address, which stays deleted until the same address overflows a bucket
  again, and `cscli decisions delete --all` deletes every decision. To read what the agent does,
  `kubectl --namespace crowdsec exec deployment/crowdsec-agent -- cscli metrics` lists the lines it
  read, the parser's hits and misses and the buckets that overflowed, and
  `just logs 'kubernetes.pod_namespace:crowdsec'` its log.
- **Metrics and the alert.** The chart's two ServiceMonitors scrape both pods' metrics on 6060
  (`cs_active_decisions` and `cs_alerts` of the local API; `cs_kubernetessource_hits_total`,
  `cs_node_hits_ok_total` and `cs_bucket_overflowed_total` of the agent). One own alert,
  `CrowdSecLocalAPIDown`, fires when the local API's target has not answered its scrape for 10
  minutes or has no series, with its runbook section ([Alerts](#alerts)); an agent that reads nothing
  raises none, as a quiet Gateway is also nothing read.

`tests/crowdsec.bats` builds the applications as Flux applies them, renders the chart with the values
helm-controller gives it, each from the key the HelmRelease names, and reads what each pod mounts
from the render: the selection, the acquisitions and the grant, the loaded items, the parser's
fields and its whitelist, each scenario's filter, bucket, capacity and leak against the table above,
the environment, the init containers, where the shared secrets come from, every rule of the two
policies and the docs' table of calls. It evaluates the policies' flows with
`scripts/network-policy-check --reach` ([What the check refuses](#what-the-check-refuses)), over
every policy the overlay and its applications build that can select a pod of the namespace, which
are the namespace's default deny, those two and any of the whole cluster, on the ports the chart
renders: the agent to the local API, the resolver and the API server, Prometheus and the kubelet
to each pod's own port, and a refusal for the world, other nodes, the proxies, other pods and
other ports.
Its test of the parser and the scenarios runs CrowdSec's own image with no network: over sample
lines in the format of the proxies' log, among them a client whose few failed requests lie between
the offenders' and gets no decision, and then each pod's start as the chart runs it, the agent's
and the local API's, with Go's resolver naming every lookup. It needs docker: where there is none,
as in the tools container of `just ci`, it checks the sample lines against the EnvoyProxy's format
and skips the rest, saying so, so CI does not run the image; it runs whole on a machine with
docker, through `just test` or `bats tests/crowdsec.bats`, which is why an update of the image or
the chart waits for a person who has run it.

## Sign-in

A cloud cluster has no home network to hide behind, so an interface not meant for everyone gets a
login in front of it, and no application brings its own. Two applications in the namespace
`sso-system` (`apps/base/sso-system/`) provide it, and a route opts in with one component.

- `dex` signs a person in with GitHub. It is an OpenID Connect provider whose issuer is
  `https://dex.${CLUSTER_DOMAIN}` on the public Gateway, from dex's own chart. GitHub is its only
  connector, its state is Kubernetes objects of its own API group, there is no password database and
  no static password, and it has one client, oauth2-proxy's. It runs two replicas on different
  nodes under a disruption budget that keeps one running: dex's Kubernetes storage is written for
  several instances, which tolerate each other creating and rotating its signing keys. The chart's
  ClusterRole lets dex list and create custom resource definitions, any of the cluster's and not
  only its own: dex's Kubernetes storage creates the definitions of its group, `dex.coreos.com`, at
  start when they are missing (its `crdHandling`, `ensure` by default). Created ahead of time, with
  `crdHandling: check`, with which dex refuses to start without them, they would let that grant go;
  they are not, so an Internet-facing service holds it. Its root filesystem is read-only, with an
  empty `/tmp` mounted: the image's entrypoint expands dex's configuration into a file there before
  dex starts.
- `oauth2-proxy` holds the session and decides who is admitted, from its own chart at
  `auth.${CLUSTER_DOMAIN}`. Two stateless replicas on different nodes, under a disruption budget;
  the session is an encrypted, secure, HTTP-only cookie for `.${CLUSTER_DOMAIN}`, so a sign-in on
  one host serves every host under the domain. It reads dex's keys and redeems the sign-in code
  through dex's Service inside the cluster (`skip_oidc_discovery`), and sends the browser to dex's
  public name, so it needs neither a route out and back through the edge nor trust in the Gateway's
  certificate. Its one callback is `https://auth.${CLUSTER_DOMAIN}/oauth2/callback`, whichever host a
  person starts from, so dex has one redirect URI and an opting application adds none.
- Two routes opt in: `demo/hello-sso`, `hello-sso.${CLUSTER_DOMAIN}`, a second hostname on the
  `hello` backend, and `monitoring/victoria-logs-route`, `logs.${CLUSTER_DOMAIN}`, the log store's
  interface ([The log store's interface](#the-log-stores-interface)). No other application is
  behind it.

Each is its own Kustomization, with `wait`, that nothing but the routes that opt in names in
`dependsOn` (oauth2-proxy names dex): `hello-sso` and `victoria-logs-route` wait on oauth2-proxy,
and nothing waits on either route. A cluster that lists neither application builds none of it, and
a cluster whose overlay lists a route that opts in without them is refused. The namespace enforces
the restricted Pod Security level, and `just pod-security-check` evaluates their pods. It denies
traffic by default, and each application's `ciliumnetworkpolicy.yaml` lets its flows through
([What the namespaces let through](#what-the-namespaces-let-through)).

### Who is admitted

dex's GitHub connector can restrict sign-in to the members of organisations or teams, and
oauth2-proxy can admit by groups, by e-mail domain or by a file of e-mail addresses. A personal
account has no organisation, so the restriction is the file: oauth2-proxy's
`authenticated_emails_file`, one address per line, compared without regard to case, with `#` lines
ignored. It is the only way in: no e-mail domain or group is set. dex asks GitHub for the account's
public e-mail address, or else its primary one that GitHub lists as verified (dex's GitHub connector,
`userEmail`), and marks it verified, which is what oauth2-proxy's check of the claim needs; the
file is the check that decides. The list holds the address a person's GitHub account has as its
public or primary one.

dex does not restrict: anyone with a GitHub account can sign in at dex and get as far as
oauth2-proxy's callback. oauth2-proxy refuses an address that is not on the list there, with status
403 and its "Forbidden" page ("You do not have permission to access this resource."), and saves no
session, so every request the person makes to a route sends them through sign-in again and ends on
that page (below). oauth2-proxy logs the refusal as an authentication line, with the address, ending
`[AuthFailure] Invalid authentication via OAuth2: unauthorized`; the page gives no reason, as
oauth2-proxy shows one only in debug mode, which is not set.

oauth2-proxy watches the file, so a change to the list reaches it once External Secrets has
refreshed the Secret, every 15 minutes at most, and the kubelet has updated the mounted file; an
empty file admits nobody.

Envoy Gateway's own `SecurityPolicy` `oidc`, at the pinned release, was weighed as a replacement
for oauth2-proxy and not taken. It signs a person in without a second component, and its
`cookieDomain` and `redirectURL` could give one session for the domain, and its client secret could
stay in `sso-system` behind a `ReferenceGrant`. But it can admit an identity only through
`authorization` rules on the token's claims, whose values are written in the policy, which would put
the list of who is allowed into the tree. oauth2-proxy reads the list from a file the secret store
fills.

### The secrets

| What | Who makes it | Where it lives |
|------|--------------|----------------|
| The GitHub OAuth App's client ID and secret | the owner, on GitHub | the secret store, at `secrets/sso-system/dex`, keys `github-client-id` and `github-client-secret`; read by the ExternalSecret `dex-github` into the Secret of that name, and from it into dex's environment |
| The secret dex and oauth2-proxy share, and oauth2-proxy's cookie secret | External Secrets' `Password` generator, once, in the cluster; no person | the Secrets `dex-oauth2-proxy-client` and `oauth2-proxy-cookie`, with nothing behind them in the store, and so in etcd and its snapshots, encrypted to the Talos age key |
| The identities allowed to sign in | the owner | the secret store, at `secrets/sso-system/oauth2-proxy`, key `allowed-emails`, one value of one address per line; read by the ExternalSecret `oauth2-proxy-allowed-emails` into the Secret of that name, mounted as a file |

None is in a ConfigMap, a values file, a Flux variable or the tree: dex expands `${NAME}` in its
connector settings from its environment and takes its client's secret from the variable `secretEnv`
names, and oauth2-proxy reads both secrets from its environment, and the list from its file.
`tests/sso.bats` renders both charts and fails when a client or cookie secret has a value of its own
anywhere, or an e-mail address is in anything the applications build or render. A generated secret
is made once and never refreshed: a deleted Secret is made again with a new value, which needs both
applications restarted for `dex-oauth2-proxy-client` and ends every session for
`oauth2-proxy-cookie`. Neither reaches a running pod: both are read when a pod starts, nothing
restarts the pods, and after a new `oauth2-proxy-cookie` the two replicas disagree on the key, and
refuse each other's sessions, until both have been restarted.

The store's keys here are `issued` in `secret-rotation.yaml`, so `just secret-rotate` refuses
them ([Rotating an application's secret](#rotating-an-applications-secret)). A new client secret
is generated in the OAuth App's settings on GitHub and written with
`just bao-put sso-system/dex github-client-secret`; dex takes it from its environment when a pod
starts and nothing restarts its pods, so an operator restarts them once the Secret holds it. The
list is replaced whole with the `just bao-put` command below and reaches oauth2-proxy by itself
([Who is admitted](#who-is-admitted)). The two generated secrets have no key in the store and no
entry in the list.

### What the owner does, in order

1. On GitHub, under the account's developer settings, create an OAuth App. Its homepage is
   `https://auth.<the cluster's domain>` and its authorisation callback URL is
   `https://dex.<the cluster's domain>/callback`. Note its client ID and generate a client secret.
2. Write both to the store, the secret typed without echo:

   ```sh
   just bao-put sso-system/dex github-client-id
   just bao-put sso-system/dex github-client-secret
   ```

3. Write the list, one address per line:

   ```sh
   printf '%s\n' <address> <address> | just bao-put sso-system/oauth2-proxy allowed-emails
   ```

Until the first two exist the ExternalSecret `dex-github` reports the missing key, dex's pods stay
in `CreateContainerConfigError`, and the Kustomization `dex` is not Ready, with the pods' state as its
reason. Until the third exists the Secret `oauth2-proxy-allowed-emails` does not exist, the pods
of oauth2-proxy stay in `ContainerCreating`, and the Kustomization `oauth2-proxy` is not Ready, and
neither are `hello-sso` and `victoria-logs-route`, which wait for it and are not applied until it
is. Nothing else of the cluster waits on any of them, and the generated secrets are made as soon as
External Secrets runs. Until the first two exist the probe of `dex` under the domain fails, and
`PublicEndpointWrongStatus` fires for it; then, until the third exists, the probe of `auth` does.
The routes and `Probe`s of oauth2-proxy, of `hello-sso` and of `victoria-logs-route` are applied
with their applications, each once the one it waits for is Ready, so the probe of `auth` is not
there while dex waits, and the probes of `hello-sso` and of `logs` meet the redirect from their
first run ([Probes](#probes)).

The wait is not open-ended. Each release's install times out after 10 minutes and is retried three
times (the root's release defaults, [What the root sets](#what-the-root-sets)); after that
helm-controller marks the `HelmRelease` Stalled, with the reason `RetriesExceeded`, and stops
trying. A store entry written more than about 40 minutes after the release was first installed
therefore needs the failure count reset, for each release that has stalled, `dex` first:

```sh
flux reconcile helmrelease dex -n sso-system --reset
flux reconcile helmrelease oauth2-proxy -n sso-system --reset
```

oauth2-proxy's release exists only once dex's Kustomization is Ready, so it stalls only when the
list is written late; `flux get helmreleases -n sso-system` says which have.

### Putting a route behind it

The application's `ks.yaml` adds `components/sso` and two variables, beside the `HTTPRoute` its own
manifests define, which names the public Gateway and whose namespace carries the Gateway label
([Giving an application a public hostname](#giving-an-application-a-public-hostname)):

```yaml
components:
  - ../../../../../components/sso
postBuild:
  substitute:
    SSO_ROUTE: <the HTTPRoute's name>
    SSO_HOSTNAME: <its host name, without the domain>
dependsOn:
  - name: oauth2-proxy
```

The component makes the `SecurityPolicy` named after the route, which targets that `HTTPRoute` and
nothing else, and the `HTTPRoute` `<name>-oauth2` that sends `/oauth2/` on the same host to
oauth2-proxy. The namespace is added to the `ReferenceGrant` `oauth2-proxy` in `sso-system`
(`apps/base/sso-system/oauth2-proxy/app/referencegrant.yaml`) as two entries, one for
`SecurityPolicy` and one for `HTTPRoute`. The grant sits there because a grant is read from the
namespace of what is referred to, and Flux's target namespace would put one made by the component
into the application's own. A namespace not in the grant cannot refer to oauth2-proxy's Service;
the Gateway API says so and the controller applies it. The grant names the one Service, never a
namespace that has not opted in. No network policy changes for sign-in: the proxies already reach
oauth2-proxy, and the route's own backend needs the rules every public hostname needs. The route's
`Probe`, which every public hostname needs, uses the module `public_https_signin`, which expects
the redirect to sign-in that a request without a session gets, and `tests/probes.bats` refuses one
that expects a 200 there ([Probes](#probes)).

For each request to the route, Envoy first asks oauth2-proxy over HTTP, sending the request's host,
method and cookie (Envoy always adds `Authorization`, which oauth2-proxy does not read here), and
acts on the answer. A 200 lets the request through to the backend, with the answer's
`X-Auth-Request-User` and `X-Auth-Request-Email` headers added to it. Any other answer below 500 goes
back to the client as it is, status, `Location` and `Set-Cookie` included, and the backend gets
nothing. An answer of 500 or more, or none, is refused with 403. While oauth2-proxy's Service has
no ready endpoint, Envoy Gateway v1.10.0 cannot resolve the policy's backend
(`internal/gatewayapi/route.go`, `processServiceDestinationSetting`) and gives every rule of the
route a direct answer of 500 instead (`internal/gatewayapi/securitypolicy.go`). The policy does not
fail open either way.

The policy asks at one fixed path, `/?rd=https://<host>/` (`pathOverride`), whatever the request's
own path. oauth2-proxy serves `/` with its catch-all handler, which answers a session of a listed
identity with a 200 from its static upstream (`upstreams = [ "static://200" ]`) and a request
without one with the redirect to dex that starts a sign-in (`skip_provider_button`, so no page with
a button comes first). Passing the request's own path would let `/ping`, `/ready` and `/robots.txt`
through to the backend, as oauth2-proxy answers them with 200 before it looks for a session; the
policy's `path` option appends that path. The query says where the person returns after signing in,
the route's own host: Envoy passes oauth2-proxy no `X-Forwarded-Host` or `X-Forwarded-Uri` to work
it out from, and without it a person would end on the sign-in host instead.

What a person sees, at `https://hello-sso.<domain>/some/page`:

1. Without a session, oauth2-proxy answers 302 to `https://dex.<domain>/auth` and sets a short-lived
   cookie of its own for the domain, which the callback checks. Envoy passes both to the browser;
   `hello` receives nothing.
2. dex has one connector, so it sends the browser on to GitHub, which asks the person to sign in,
   and the first time to authorise the OAuth App. GitHub returns them to dex's callback, and dex,
   which shows no approval screen, to `https://auth.<domain>/oauth2/callback`.
3. oauth2-proxy redeems the code at dex and reads the address. On the list, it sets the session
   cookie for the domain and redirects to `https://hello-sso.<domain>/`, which now passes and shows
   hello's page. The page first asked for, `/some/page`, is not returned to: oauth2-proxy was never
   told it. Not on the list, the person gets the 403 "Forbidden" page and no session, and every
   later request to the route goes through steps 1 to 3 and ends there again; oauth2-proxy's log
   has the line `[AuthFailure] Invalid authentication via OAuth2: unauthorized`
   ([Who is admitted](#who-is-admitted)).
4. With the session, every route that opts in passes, on any host under the domain.

`https://auth.<domain>/` signs a person in the same way and ends on oauth2-proxy's own answer,
"Authenticated".

`tests/sso.bats` proves each of these on the rendered objects: the policy's target, its backend,
the fixed path with the route's host in its query and the headers, oauth2-proxy's static upstream,
its skipped sign-in button and the absence of anything that would answer without a session, the
grant that names exactly the namespaces that have a policy, the secrets, the files and the
configuration. It cannot show what only a running Gateway, dex and GitHub can: the answers of Envoy
and oauth2-proxy to a real request, the redirects, the return to the route's host, and the Gateway
refusing a namespace that is not in the grant. The first sign-in is the proof on the cluster.

### What it does not cover

The Kubernetes API's own authentication: nothing here makes `kubectl` sign in, and dex has no client
for it. An application with a login of its own keeps that login: a route behind this sign-in asks
nothing of the backend, which gets the client's headers, its cookies and `Authorization` among
them, with the identity headers added. The session cookie is set for the
cluster's domain, so the browser sends it to every application under the domain, whether its route
opts in or not, and whoever holds it passes every route that opts in for as long as it lasts. A
route that is not given the component is as open as it was.

## Web application firewall

A route on the public Gateway can be put behind a web application firewall, to learn from and to
try attacks against: [Coraza](https://coraza.io), an open-source engine compatible with
ModSecurity, with the [OWASP Core Rule Set](https://coreruleset.org), the rules it is normally run
with. coraza-proxy-wasm packages both as a Wasm filter, which the Gateway's own proxies run, so
there is no controller, sidecar or external processor of its own. A route opts in with one
component, `components/waf`, as it opts in to sign-in. The demo route `hello` is the one that does,
in blocking mode: nothing real is behind it, so a false positive costs nothing there.
`tests/waf.bats` pins the routes behind the firewall to `demo/hello`, and `hello-sso`, a second
hostname on the same backend, is not one of them.

The filter is coraza-proxy-wasm 0.6.0, which embeds Coraza 3.3.3 and the Core Rule Set 4.14.0.
Its release notes warn that its build, with TinyGo, has been reported to leak memory and degrade
performance, and recommend extensive testing before relying on it; what it costs here is below.

### How it reaches the proxies

The component makes an `EnvoyExtensionPolicy` named after the route, in its namespace, that targets
that `HTTPRoute` and nothing else, with one Wasm entry, `coraza`, from an `Image` source:
`ghcr.io/corazawaf/coraza-proxy-wasm:0.6.0@sha256:65d6…f4e`. As Envoy Gateway v1.10.0 runs it:

- **Every replica fetches.** Each controller replica runs the translator and, with it, a Wasm cache
  of its own (`Start` in `internal/gatewayapi/runner/runner.go`), the leader or not: every replica
  translates the policies, and only the leader writes their status. When it translates the policy,
  a replica fetches the image from its registry itself, anonymously, extracts `plugin.wasm` from the
  image's one layer and keeps it in the chart's `wasm-cache` emptyDir at `/var/lib/eg/wasm`
  (`internal/wasm/cache.go`, `internal/wasm/imagefetcher.go`), and logs `fetching image` with the
  registry, the repository and the digest. The fetch runs inside the translation, which waits for
  it, for up to five minutes (`DefaultPullTimeout` in `internal/wasm/options.go`): whenever a
  replica's cache lacks the module, at every start of the replica and after a quiet day
  ([It fails open](#it-fails-open)), the configuration and status of every route of every Gateway
  wait on the registry. A fetch that failed is tried again at the next translation, which only a
  change to an object the controller reads starts: it compares them without their status, so Flux
  applying the same objects again does not; after more than ten failures the replica stops trying
  until an hour after the last (`internal/wasm/httpserver.go`). Deleting the controller's pods one
  at a time, `kubectl -n envoy-gateway-system delete pod <pod>`, makes each new one fetch the module
  as it starts.
- **The digest it checks.** The entry sets no `sha256`, so the replica takes the digest from the
  URL's `@sha256:` (`Get` in `cache.go`) and compares it with the digest of the image manifest it
  resolves. It resolves with go-containerregistry's `remote.Get` and then `Image()`, which turns an
  index into its linux/amd64 image, so the digest compared is that image's: the pin is the
  linux/amd64 image manifest that the tag's OCI index lists (`sha256:65d6…f4e`), not the index
  (`sha256:d66f…4b1`), whose digest the replica would refuse as a checksum mismatch. The release's
  own asset is a zip, so there is no bare module over HTTP to pin by its sha256 instead.
  `tests/waf.bats` asks the registry, anonymously, and fails unless the
  pinned digest is an image manifest with one gzipped tar layer that the tag's index lists for
  linux/amd64.
- **Who serves it.** Each replica serves its modules over TLS 1.3, with the proxies' client
  certificate required, on 18002 (`httpserver.go`), at a path made from a hash of the image's URL
  and a salt the certificate job writes, so that it cannot be guessed. The
  proxies reach it as the controller's Service `envoy-gateway`, whose port `wasm` is 18002, through
  the cluster `wasm_cluster` the controller adds to their configuration for a remote module
  (`internal/xds/translator/globalresources.go`), with a retry policy of ten retries and a backoff
  of one to 30 seconds, and check the module's own sha256, which the controller hands them with the
  URL (`internal/xds/translator/wasm.go`). Either replica may answer, each from its own cache,
  whichever one the proxy takes its configuration from, so a proxy handed the filter by a replica
  that has the module can ask one that lacks it, and fail open. A proxy never reaches the registry.
- **On that route alone.** The controller adds the filter to the listener's chain disabled and
  enables it on the policy's routes (`patchHCM` and `patchRoute` in `wasm.go`), so every other
  route of the Gateway runs without it. The module is part of the listener all the same: a proxy
  that starts serves no route of the Gateway until it has the module or has given up on it
  ([It fails open](#it-fails-open)). And the filter sits in the HTTP connection manager of the
  `https` listener, which every route on it shares, so taking the component, and every later change
  to the policy, its mode, a new pin or another route, replaces that listener's filter chain. So
  does a fetch that fails: a controller replica that cannot fetch the module translates the route
  without it, and `patchHCM` then leaves the filter out of the listener's chain, which replaces the
  chain on the proxies connected to that replica, and replaces it again once a later translation
  brings the module back (`buildWasms` in `internal/gatewayapi/envoyextensionpolicy.go`). Envoy
  drains the connections of a filter chain it replaces for `--drain-time-s`, 60 seconds as the
  controller sets it, and with the controller's `--drain-strategy immediate` (`proxy_args.go`) each
  is told to close at its next response from the start, while an upgraded websocket, n8n's and
  Open WebUI's among them, is reset before that time is up (Envoy's documentation, Listener
  discovery service and Draining). The firewall on one route is therefore not without effect on
  the others: each of these drains the connections of every route of the `https` listener, which is
  the cost of trying it on the demo route ([It fails open](#it-fails-open) says what a real
  application would need instead).
- **What moves the pin.** Renovate reads the tag and the digest under the `# renovate:` comment
  above the URL, keeps to release tags (the registry also lists a `-busybox` variant of each, and
  `latest`, `main` and `0`), and never merges the update itself: a new release brings a new Core
  Rule Set, which can start refusing a route's traffic. For the digest it reads the architecture
  in the image configuration of the digest the tree pins and takes the manifest of that
  architecture from the new tag's index (`getDigest` in `lib/modules/datasource/docker/index.ts` of
  the pinned Renovate), so a release whose index lists an amd64 image keeps a pin of the kind the
  controller checks; one whose index listed none would be pinned by the index's digest, which
  `tests/waf.bats` refuses. Nor does an update of the Envoy Gateway chart merge itself, as it
  changes the Envoy the filter runs on: no test runs the filter on Envoy, and a module the new
  Envoy cannot load fails open while the policy stays accepted.

The flows ([What the namespaces let through](#what-the-namespaces-let-through)): the proxies reach
the controller on 18002, beside 18000, in the rules both sides already have; the controller reaches
the registry, the world on 443, in a policy of its own, `envoy-gateway-registry`, with its reason:
`ghcr.io` answers a blob request with a redirect to another host, so a DNS name rule would need both
names and Cilium's DNS proxy, which no policy of the tree uses. The certificate job and the proxies
reach nothing outside the cluster. Within one change, nothing makes a route's policy wait for these
flows: each application reads an artifact of its own, and kustomize-controller compares a
dependency's applied revision with its own only when both read the same source, so `hello-route`
can apply the policy before `envoy-gateway` applies `envoy-gateway-registry`. A fetch refused in
that time stays failed until the next translation ([It fails open](#it-fails-open)). The agents
run the policies in audit mode today (`policyAuditMode` in Cilium's values) and drop nothing, so
the order matters once they enforce ([Turning it on, and back](#turning-it-on-and-back)).

### Putting a route behind the firewall

The application's `ks.yaml` adds the component, its two variables and the health check, beside the
`HTTPRoute` its own manifests define; `components/waf/kustomization.yaml` gives the block:

```yaml
components:
  - ../../../../../components/waf
postBuild:
  substitute:
    WAF_ROUTE: <the HTTPRoute's name>
    WAF_MODE: "On" # or DetectionOnly
wait: true
healthCheckExprs:
  - apiVersion: gateway.envoyproxy.io/v1alpha1
    kind: EnvoyExtensionPolicy
    current: >-
      has(status.ancestors) && size(status.ancestors) > 0 && status.ancestors.all(a,
      a.conditions.exists(c, c.type == 'Accepted' && c.status == 'True' && c.observedGeneration
      == metadata.generation))
    failed: >-
      has(status.ancestors) && status.ancestors.exists(a, a.conditions.exists(c, c.type ==
      'Accepted' && c.status == 'False' && c.observedGeneration == metadata.generation))
```

Neither variable has a default. The policy's status is a Gateway API `PolicyStatus`: an ancestor,
the Gateway and listener of the route, with an `Accepted` condition, for each place the route
attaches, which the controller sets `False` when the policy cannot be translated, a module it could
not fetch among the reasons. The Kustomization is therefore Ready only while every ancestor accepts
the policy at its current generation, and fails once one refuses it, which the Flux alerts report
([Flux monitoring](#flux-monitoring)). It stays failed until the controller fetches the module
again, which Flux's retries do not bring about: deleting the controller's pods one at a time does
([How it reaches the proxies](#how-it-reaches-the-proxies)). A first fetch may outlast the
Kustomization's timeout, the root's three minutes, as the controller waits up to five on the
registry: the Kustomization then fails its health check, which shows in its status and events, and
turns Ready at a later attempt, a minute after each failure, once the status says accepted. The
Flux alert, `FluxApplierNotReady`, fires only after 15 minutes not Ready, which a first fetch does
not reach, so a slow one raises no alert; one that fails leaves the policy refused, as above, and is
reported. `tests/waf.bats`
fails unless every `ks.yaml` that takes the component sets both variables, the mode to `On` or
`DetectionOnly`, waits and carries these expressions, and it evaluates them with the pinned
Kyverno's CEL against statuses of that shape: current while every ancestor accepts the policy at
its generation, failed once one refuses it, and neither without an ancestor or at an earlier
generation. No network policy changes for a route: the proxies already reach every routed backend
([Giving an application a public hostname](#giving-an-application-a-public-hostname)).

`tests/waf.bats` reads what the files under `kubernetes/` write and what the render holds. It
fails for an `EnvoyExtensionPolicy` or an `EnvoyPatchPolicy` written as a document of any YAML file
under `kubernetes/` but the component's, and for a Wasm module an `EnvoyProxy` registers
(`wasmModules`) in any file there. It
also reads the render of what the cluster applies, with what the charts of its HelmReleases
render, a chart's extra objects from its values among it (`scripts/render`). It fails for two
forms the render does not expand as the cluster would: a List with items, whose items Flux applies
as objects of their own, and a Flux object a chart renders, which the render does not follow. It
fails there for an `EnvoyExtensionPolicy` or an `EnvoyPatchPolicy` that is not the component's for
a route that takes it, for a policy that targets anything but an `HTTPRoute` of its own namespace
that the render holds, or selects its targets by labels, for any object with a Wasm extension that
targets a Gateway or a ListenerSet, and for an `EnvoyProxy` that registers a Wasm module. And it
fails for any object that names either kind or its resource (`envoyextensionpolicies`,
`envoypatchpolicies`), in any field or string, or has a `wasm` or `wasmModules` key, but the
component's policies, the Kustomizations that take the component and the controller's own
ClusterRole.

So no object a file under `kubernetes/` writes or the render holds puts the firewall on the Gateway
as a whole or on a route that did not opt in. Four things are outside the check: a mutation or a
generation by an admission controller at run time, which changes or makes an object after the
render, whatever the text it starts from; the roles that may write such a policy; the objects a
Flux Kustomization applies from a source the render does not follow; and what another tool applies
to the cluster from a file outside `kubernetes/`, such as a manifest inline in a Talos patch
(`cluster.inlineManifests`), which the control plane applies. The render follows a Kustomization
whose source is the cluster's own artifact or any `ExternalArtifact`, which it builds from the
tree's paths as if made from that artifact; four others apply from their
projects' own sources today, the Gateway API's definitions, Envoy Gateway's, and the snapshot
controller's definitions and controller, and what those sources hold is never rendered.

### The two modes

`WAF_MODE` becomes the filter's `SecRuleEngine`, after the filter's recommended configuration,
which sets `DetectionOnly`:

- `On` refuses a request whose inbound anomaly score reaches the threshold with 403. With early
  blocking, as the rule set's setup turns it on, a request whose headers and query string score
  that much is refused before its body is read (rule `949111`, phase 1); one that does so only with
  its body, when the body has been read (`949110`, phase 2).
- `DetectionOnly` lets every request through and logs the rules it matched all the same, the
  blocking evaluation as `Warning.` where `On` logs `Access denied`: the mode to put an application
  behind first, and to read its log in, before it blocks.

### It fails open

The entry sets `failOpen: true`. A module that cannot be had leaves the route served without the
filter, rather than every request of it refused, except on a replica whose Wasm cache did not
start, the last case below:

- a replica that cannot fetch the image first waits on the registry: the fetch runs inside the
  translation, so the configuration and status of every route of every Gateway wait with it, for
  up to five minutes. It then translates the route without the filter, which replaces the `https`
  listener's filter chain on the proxies connected to that replica, and replaces it again once a
  later translation has the module: each time, the connections of every route of that listener are
  drained and their websockets reset (On that route alone, in
  [How it reaches the proxies](#how-it-reaches-the-proxies)). A replica fetches whenever its cache
  lacks the module: at every start, as after a drain, an upgrade or an eviction, which the tree's
  descheduler can make, and after a quiet day (below). When the leader is that replica it reports
  the policy not accepted, and the health check turns that into the Kustomization's failure, so a
  firewall that is not there shows as `hello-route` not Ready. Only the leader writes the status,
  so another replica that failed while the leader did not serves the proxies connected to it
  without the filter, which only that replica's log shows (`Failed to get Wasm module`). Neither
  fetches again until a translation, as above;
- a proxy that is handed the filter fetches the module as part of setting up the listener
  (`RemoteAsyncDataProvider` in Envoy's `source/extensions/common/wasm/remote_async_datasource.h`),
  which is done only once it has the module or has spent its ten retries. A running proxy keeps
  serving with the listener it had meanwhile. A proxy that starts serves no route of any listener
  until then. Its retries wait a random time below one second, then two, four, eight, 16 and 30
  five times over: about a minute and a half in all, and at most about three minutes, when the
  controller answers each try at once, as it does with a 404, and up to nearly five minutes when
  each try waits out its ten-second timeout, about as long as the proxies' startup probe allows (300
  seconds). It then logs `Retry limit exceeded for fetching data from remote data source.`, at
  `warning`, and `Plugin coraza failed to load`, at `critical`, and serves every route, the
  firewall's route without the filter, while the policy stays accepted and `hello-route` Ready.
  With two proxies under their disruption budget the other carries the traffic meanwhile; when both
  start at once, every route waits;
- a proxy without the module stays so. Once the controller has the module again it hands the proxy
  the same listener, the module at the same path with the same checksum, and Envoy ignores a
  listener update that is the same as the one it runs (`listener_manager_impl.cc`), so nothing
  fetches the module again until the proxy restarts or its listener changes. Throughout, the policy
  stays accepted and `hello-route` Ready: only that proxy's log shows it. The remedy is to delete
  the controller's pods one at a time, as above, so that each fetches the module again, and then
  that proxy's pod, `kubectl -n envoy-gateway-system delete pod <pod>`, while the other proxy
  serves;
- a replica's cache removes a module that no translation has asked for in 24 hours (`purge` in
  `cache.go`; serving it to a proxy does not count), and answers a proxy's request for it with 404
  from then on, while the proxies' configuration still names its path. A proxy that starts after a
  quiet day is the proxy above that cannot fetch the module, and can stay without it. A
  translation while its retries run fetches the module again in time, such as the one a routed
  backend's endpoints start when a drain or an upgrade of the node moves that backend's pod as
  well. A proxy that restarts alone, evicted (the tree's descheduler can evict it), crashed or its
  pod deleted, stays without it unless some other change starts a translation meanwhile;
- a replica whose Wasm cache did not start refuses the route, whatever `failOpen` says. The cache
  starts once, as the replica starts, beside the translation and in no order with it: it reads the
  certificate job's Secret `envoy-oidc-hmac` from the API, once, with no retry of its own (the API
  client retries a GET only after a reset or lost connection, or an answer with `Retry-After`), and
  loads the controller's certificates, logging `failed to start wasm cache` when either fails; it
  then creates its directory, `/var/lib/eg/wasm`, logging `Failed to create Wasm cache directory`
  when that fails. After any of these the replica runs without a cache for the rest of the pod's
  life (`startWasmCache` in `runner.go`), as the read can fail when the API server is briefly
  unavailable, such as while a control-plane node is upgraded. A translation that finds no cache, whether it never started or is not yet assigned,
  refuses the policy's route (`buildWasms` and `translateEnvoyExtensionPolicyForRoute` in
  `envoyextensionpolicy.go`): the proxies connected to that replica answer every request of `hello`
  with 500, and the replica logs
  `setting 500 direct response in routes due to errors in EnvoyExtensionPolicy`, with the error
  `wasm cache is not initialized`. Only when it is the leader does the status show it, and
  `hello-route` turn not Ready. It lasts until that controller pod is deleted,
  `kubectl -n envoy-gateway-system delete pod <pod>`, which is the remedy, or, when the cache only
  started late, until the next translation.

A proxy given the filter also logs Envoy's warning that remote Wasm code fetch `is unstable and may
cause a crash`, as the controller hands out every module of an image that way. A configuration the
filter refuses when it starts is not covered by failing open where the proxy already holds the
module in Envoy's own cache: it refuses the configuration, and with it the update of the listener
that carries it, and keeps the listener it had. A proxy that fetches the module, every new pod
among them, checks the configuration only once the fetch is done, too late to refuse the update
(`xDS currently does not support failing asynchronously`, `source/extensions/common/wasm/wasm.cc`),
so it logs `Plugin coraza failed to load` and fails open.

The firewall fails open because the demo route is there to try it on, and a firewall that fails
closed takes its route down whenever the registry or the controller cannot hand out the module.
What that costs is accepted for the demo route: a proxy that starts while the module cannot be
fetched serves no listener until its retries are spent, then serves the route unfiltered while the
policy stays accepted; a translation waits on a failing fetch; the proxies connected to a replica,
the leader or not, that could not fetch, serve the route unfiltered, and only the leader's failed
fetch shows in the policy's status; a replica that translates without the module, and again once it
has it, drains the connections of every route of the `https` listener on its proxies and resets
their websockets; and a replica whose Wasm cache did not start answers every request of the route
with 500 on the proxies connected to it, whatever `failOpen` says, until that pod is deleted or,
when the cache only started late, the next translation.

For a real application the trade is the other way: closed, with the module's availability treated
as the route's own, the registry's and the controller's included. Closing leaves the wait and the
drain: the fetch is part of the translation either way, and a route refused for want of its module
loses the filter from the listener's chain all the same (`translateEnvoyExtensionPolicyForRoute`
in `envoyextensionpolicy.go`). The drain stays within such an application's own connections only
on a listener of its own: each listener of the Gateway is a filter chain of its own, matched by its
hostname (`addServerNamesMatch` in `internal/xds/translator/listener.go`), and Envoy drains only
the connections of the filter chains an update replaces (Listener discovery service).

### What the Core Rule Set does at its defaults

The configuration is the filter's recommended one, the mode, the rule set's setup and every rule
file of it, at their defaults: blocking paranoia level 1 and an inbound anomaly threshold of 5
(`REQUEST-901-INITIALIZATION.conf`), early blocking on as the filter's `crs-setup` sets it, and no
exclusion of the tree's own; `tests/waf.bats` fails for any other directive. Applications such as
n8n and Open WebUI are REST APIs, editors and chats in a browser, and this is what the defaults do
to such traffic, each point found in the rule set's files and the filter's source; the methods, the
content types, the JSON body, the size limit and the extensions were also seen in a local run of
the filter (below):

- methods other than GET, HEAD, POST and OPTIONS are refused (`911100`), so a REST API's PUT, PATCH
  and DELETE are;
- a request whose content type is not in `tx.allowed_request_content_type`, which holds form,
  multipart, XML and JSON bodies, is refused (`920420`), `text/plain` and
  `application/octet-stream` among them;
- JSON bodies are parsed (rule `200001` of the recommended configuration) and every value is
  inspected, so a prompt or a workflow that holds code, SQL or HTML trips the injection rules (a
  JSON prompt with an `or 1=1` was refused by `942100`);
- a request body of 128 KiB or more is refused with 413 (`SecRequestBodyLimit 131072` with
  `SecRequestBodyLimitAction Reject`), which stops uploads;
- multipart uploads go through the `922` rules, and a path that ends in a restricted extension,
  such as `.sql` or `.conf`, is refused (`920440`);
- the filter holds a request's body until it ends, or until it reaches the limit and is refused
  (`OnHttpRequestBody` returns `ActionPause`), so the client's frames on an upgraded websocket do
  not reach the backend while body access is on;
- `text/html`, `text/plain` and `text/xml` response bodies are inspected up to 512 KiB, each held
  until it ends or reaches that.

Each of these is an exclusion to write, from coreruleset.org's documentation on false positives,
tuning and rule exclusions, before the filter goes in front of such an application; nobody turns it
on for n8n or Open WebUI blind.

### What it costs a proxy

Every worker of a proxy runs its own VM for each policy's entry (`vmSharingScope`, `Policy` by
default, `api/v1alpha1/wasm_types.go`). The controller passes no `--concurrency`, so a proxy runs
Envoy's default number of workers: the fewest of the node's hardware threads, its CPU affinity set
and the container's CPU limit, and the proxies have no limit. Measured with the pinned Envoy image
and the filter in blocking mode, by docker's count of the container's memory after 21,000 requests
over eight connections at once: about 20 MiB without the filter; 319 MiB with it at one worker,
350 MiB at two, 454 MiB at four and 876 MiB at sixteen. That is about 300 MiB more than without it
at one worker, and 37 MiB for each worker beyond the first on average, 31 to 52 MiB from one of
those counts to the next, nearly all of it taken when the proxy starts; over the 21,000 requests
it grew by 2 to 14 MiB, the most at sixteen workers, most of it in the first 10,000. The workers of
the tree's default flavor (`worker_flavor`, `b.6c16gb`) have six vCPUs, so a proxy there runs six
workers and takes about 500 MiB by these figures. The proxies request 128Mi of memory and set no
limit ([The public Gateway](#the-public-gateway)), which this does not change. Nothing else bounds
a proxy at about four times its request either: the render has no LimitRange and no
VerticalPodAutoscaler, its one ResourceQuota counts pods of another namespace, and the vertical
autoscaler runs its recommender alone, which changes no pod. A pod that far over its request is
among the first the kubelet evicts when its node runs short of memory. A second route behind the
firewall has a policy of its own, and with it a VM for each worker: at two workers, a proxy with
two routes behind the firewall took 504 MiB, against 350 MiB with one. The local run does not show
a leak over hours, which the release notes warn of; the proxies' memory on the cluster is the
measure of that.

### Seeing a blocked request

Envoy writes the filter's lines with its own application log, on standard error, which the
collector ships with the container's other lines, the field `stream` saying which ([Logs](#logs)).
The proxies log at `warn`, so of the filter's lines those of a matched rule of severity warning or
higher print (`logError` in the filter's `wasmplugin/plugin.go`): each rule the request
matched, and the blocking evaluation's, which carries no severity of its own and prints as
`emergency`. A refused request's lines end in that evaluation:

```text
[…][critical][wasm] […] wasm log coraza …: [client "192.0.2.10"] Coraza: Access denied (phase 1). Inbound Anomaly Score Exceeded in phase 1 (Total Score: 5) [file "@owasp_crs/REQUEST-949-BLOCKING-EVALUATION.conf"] […] [id "949111"] […] [uri "/?id=1%27%20OR%20%271%27%3D%271"] […]
```

Find the refusals, and then the access log's 403s on `hello`, whose `status` and `host`
`unpack_json` makes fields of:

```sh
just logs 'kubernetes.pod_namespace:envoy-gateway-system kubernetes.container_name:envoy "Coraza: Access denied" (949111 OR 949110)'
just logs 'kubernetes.pod_namespace:envoy-gateway-system kubernetes.container_name:envoy client_address | unpack_json fields (host, status) | filter status:=403 host:~"^hello[.]"'
```

A request refused for its body's size has no line of the filter, only the access log's 413.

A line holds the client's address, the address the proxy took as the client's
([The public Gateway](#the-public-gateway)), the proxy's own address, the data each rule matched,
and the request's URI with its query string, which the access log leaves out on purpose, as it can
hold a secret. That is acceptable on the demo route, and it is a reason to look before turning the
filter on for a real application.

The audit log stays off, as the recommended configuration has it. Its default parts include the
request's headers, and the sign-in's session cookie is set for the whole cluster domain, so a
browser sends it to `hello` too ([What it does not cover](#what-it-does-not-cover)). Nor would it
print: the filter writes it at `info` (`internal/auditlog/serial_writer.go`), below the proxies'
`warn`, and the pinned `EnvoyProxy` API has no `wasm` component to raise alone; the controller
always passes `--component-log-level` (`internal/infrastructure/common/proxy_args.go`), and Envoy
refuses it given twice, so `extraArgs` cannot add one either.

### Trying it

With `CLUSTER_DOMAIN` set to the cluster's domain, the first three are refused with 403, a SQL
injection, a script injection and a path traversal, each in the query string and URL-encoded as
curl needs, and the last answers 200 with the demo's page:

```sh
curl -s -o /dev/null -w '%{http_code}\n' "https://hello.${CLUSTER_DOMAIN}/?id=1%27%20OR%20%271%27%3D%271"
curl -s -o /dev/null -w '%{http_code}\n' "https://hello.${CLUSTER_DOMAIN}/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
curl -s -o /dev/null -w '%{http_code}\n' "https://hello.${CLUSTER_DOMAIN}/?file=..%2F..%2F..%2Fetc%2Fpasswd"
curl -s -w '%{http_code}\n' "https://hello.${CLUSTER_DOMAIN}/?name=world"
```

`just gateway-check`'s request for the demo, `GET /` with curl's own User-Agent and Accept, passes:
curl's User-Agent is on no list of the rule set's scanner detection (`scanners-user-agents.data`),
and its `http` line goes to the redirect route, which has no policy. Its fake curl answers by host
alone, so the refused requests are a check on the cluster, not a line of it.

`tests/waf.bats` proves the component, the policy, the pin and the health check on the built and
rendered objects and the registry's answers, and `tests/network-policy.bats` the flows. What only
a running Gateway shows was run locally instead, with no network: the pinned Envoy image, as user
65532 with no capability, no privilege escalation, the runtime's default seccomp profile and a
read-only root filesystem with no writable mount of its own, the runtime's `/dev/shm` the one place
it needs to write, for its hot restart's shared memory; the module extracted from the image by its
digest; the filter configured as the component renders it; busybox's web server behind it with the
demo's page. Under `On` the three requests above were answered 403, the plain one and the Gateway
check's 200, by HTTP/1.1 and HTTP/2; under `DetectionOnly` all 200, each attack logged. What only
the cluster shows is read there: the policy's status
(`kubectl -n demo get envoyextensionpolicy hello -o yaml`), the controller's `fetching image` line,
the requests above through each edge, the proxies' memory over a day
(`kubectl top pods -n envoy-gateway-system`), and, after a proxy restarts, its log, where
`Retry limit exceeded` or `Plugin coraza failed to load` means it serves `hello` without the
filter ([It fails open](#it-fails-open)).

## PostgreSQL

Applications get PostgreSQL from the CloudNativePG operator, which runs each database as a
`Cluster`: a primary and streaming replicas, a replica promoted when the primary fails, and the
Services and credentials an application connects with.

`apps/base/cnpg-system/cloudnative-pg/` installs the operator in its own namespace, `cnpg-system`, at
the restricted Pod Security level, from the publisher's chart in
`oci://ghcr.io/cloudnative-pg/charts`; it watches every namespace. The chart ships the
`postgresql.cnpg.io` definitions as templates of the release, so each chart upgrade upgrades them
with the operator, and marks each `helm.sh/resource-policy: keep`, so removing the application
leaves them, and every cluster, in place.
Two replicas run on different workers: the leader reconciles, both answer the webhook through which
the API server admits every change to a CloudNativePG object, and a disruption budget keeps one
through a drain. Its chart's PodMonitor is on, so it names `prometheus-operator-crds` in `dependsOn`,
and its `ks.yaml` sets `wait`. It also carries the alerts on every cluster's WAL archive and base
backups ([Alerts](#alerts)).

`apps/base/cnpg-system/plugin-barman-cloud/` installs the Barman Cloud plugin, which archives and
backs up every database to the object storage, beside the operator, in its namespace as the plugin
requires, from the publisher's chart in the same registry. Its release, plugin v0.16, needs
CloudNativePG 1.30 or newer, and the operator chart the tree pins installs 1.30: `tests/postgresql.bats`
fails for an operator older than 1.30, a floor the test holds as a constant from the plugin's
installation documentation. Nothing reads the floor from a release, so a plugin release whose
documentation raises it needs the constant raised by hand in its pull request. The chart's tag is
pinned and tracked by Renovate, and so are the plugin's image and the sidecar image the operator
injects into every database pod that archives, each by tag and digest in `values.yaml`, in one
Renovate group with the chart; the test fails unless both images are the release of the chart's
`appVersion`. Two replicas run on different workers, which the plugin supports for the loss of a
pod or a node, and a disruption budget keeps one through a drain: while none answers, the operator
cannot make or change the pod of a database that archives. The plugin's two certificates, which
authenticate the operator to the plugin and the plugin to the operator, are the application's own,
`barman-cloud-client` and `barman-cloud-server` in the Secrets `barman-cloud-client-tls` and
`barman-cloud-server-tls` that the plugin's Service names for the operator, each signed by its own
key through the `Issuer` `barman-cloud-selfsigned` of the namespace, as in the plugin's own
manifest; the chart's certificates and issuer are off. The application names `cert-manager` and
`cloudnative-pg` in `dependsOn` and sets `wait`. Its pods meet the restricted level the namespace
enforces, and so does the sidecar the plugin injects, which runs as a non-root user with a read-only
root file system, every capability dropped and the runtime's seccomp profile.

Each side trusts exactly the other's certificate, which is why the two are self-signed and not
issued by the cluster's CA. The plugin's server takes the client certificate, `tls.crt` of
`barman-cloud-client-tls`, as its only client authority and names that certificate's subject when
it asks the operator for one; the operator trusts the server's certificate, `tls.crt` of
`barman-cloud-server-tls`, and presents its own only if it is issued by an authority the server
names. A self-signed certificate is; one the cluster's CA issued is not, so the operator would
present none and the plugin would end the handshake with `tls: certificate required`. Naming the
CA to the plugin instead would admit every certificate the cluster's CA issues for client
authentication. The server's certificate would pass either way, as the operator trusts that
certificate itself; it is self-signed as well, as in the plugin's manifest, so the application needs
no issuer but its own.

While the operator cannot reach the plugin, every `Cluster` that names it stays in
the phase `Cluster cannot proceed to reconciliation due to an error while interacting with
plugins`, its `phaseReason` naming the error, and the operator makes, changes and fails over none of
its pods. A primary that does not have the plugin's sidecar yet, such as one made before its
`Cluster` named the plugin, then fails to archive every WAL segment, `PostgresWALArchivingFailing`
fires ([alerts.md](runbooks/alerts.md#postgreswalarchivingfailing)), and the segments stay on its
volume until it is full; a `Cluster` made meanwhile gets no instance at all.

An application takes a cluster from the component `components/cnpg-cluster`, in its `ks.yaml`:

```yaml
spec:
  dependsOn:
    - name: cloudnative-pg
    - name: plugin-barman-cloud
    - name: prometheus-operator-crds
    - name: external-secrets
    - name: openbao-store
  components:
    - ../../../../../components/cnpg-cluster
  postBuild:
    substitute:
      CNPG_CLUSTER_NAME: <app>-db
      CNPG_NAMESPACE: <the Kustomization's targetNamespace>
      CNPG_STORAGE_SIZE: 10Gi  # each instance's volume; 5Gi when unset
```

`CNPG_NAMESPACE` is the namespace the application is applied to: a component cannot read
`targetNamespace`, and the namespace is a level of the cluster's archive path. The Cluster's
ObjectStore is of the plugin's kinds, so the application waits for `plugin-barman-cloud`, and the
credentials of the backups are an ExternalSecret, so it waits for `external-secrets` and
`openbao-store`. `scripts/kubernetes-check` refuses an overlay that lists an application which names
`plugin-barman-cloud`, or any other application, in `dependsOn` without listing that one, a
Kustomization that takes the component without naming `plugin-barman-cloud` in `dependsOn`, and one
whose `CNPG_NAMESPACE` is not its `targetNamespace`, which would put its archive in the path of a
database of another namespace. So a cluster that does not select the plugin builds no database that
needs it: it is refused naming the application and the dependency, and builds neither when it lists
neither.

The cluster has three instances of PostgreSQL 18, from the operator's standard image, whose tag names
a minor version that Renovate moves. The publisher rebuilds the image under that tag and a node keeps
the build it pulled first, so instances can run different builds of one minor version. Each instance
must run on a different worker, and requests and is limited to 500m CPU and 512Mi memory. The
operator's disruption budgets move the primary away by switchover before its worker is drained, and
let drains take one replica at a time. A PodMonitor scrapes every instance, and labels their series
with the Cluster's name as `cnpg_io_cluster`. Without `CNPG_CLUSTER_NAME` or `CNPG_NAMESPACE` the
strict build of `just kubernetes-check` fails; Flux itself substitutes an empty string for a variable
nothing defines, which is why the check is the guard. The apply of a name longer than 45 characters
fails as well: the dump job's CronJob, `<name>-pgdump`, is named in at most 52, and Flux applies an
application whole or not at all. The operator creates the database `app`, owned by the user
`app`, whose password and connection URI are in the Secret `<name>-app`; the Services `<name>-rw`,
`<name>-ro` and `<name>-r` reach the primary, the replicas and any instance. An application
whose patch names a Secret of its own in `bootstrap.initdb` makes that Secret, and the
operator then makes none: Ascender's `ascender-db-app` comes from External Secrets, with
the keys Ascender reads and no URI ([Ascender](#ascender)). The dump job ([Dumps](#dumps))
takes its S3 key through an ExternalSecret too, so it needs nothing in `dependsOn`
beyond what the backups need.

A patch in the application's own `kustomization.yaml` changes anything else, as it applies after the
component. It targets the Cluster by kind: Flux substitutes after the build, so when the
patch applies the Cluster is still named `${CNPG_CLUSTER_NAME}`, and a target by the name
the application gives it matches nothing and is skipped without an error. A patch that
must reach the component's Cluster and no other, as a restore may add one beside it in
`app/`, names it by that name as a regular expression, `name: \$\{CNPG_CLUSTER_NAME\}`, as
Ascender's does ([Ascender](#ascender)).

```yaml
patches:
  - target:
      kind: Cluster
    patch: |-
      - op: replace
        path: /spec/resources/requests/memory
        value: 1Gi
      - op: replace
        path: /spec/resources/limits/memory
        value: 1Gi
```

Each instance's volume is on `linstor-node-local` ([StorageClasses](#storageclasses)), one copy on
the instance's own worker without DRBD. The three instances already are three copies on three
workers, kept in step by PostgreSQL's replication; the replicated default would keep each of them
twice, six copies of every write. The operator's documentation advises one replica at the storage
level, with no storage host holding two instances of a cluster, which the placement rule guarantees.
The cost is that an instance cannot move: while its worker is down the cluster runs on two. When the
worker or its data volume is lost for good, the instance's PersistentVolumeClaim and then its pod
are deleted, which removes the instance, and the operator clones a new one from the primary. With
three workers, the new one waits for a worker without an instance. A WAL segment that fails to
archive stays on the primary's volume until it is archived, and PostgreSQL stops when the volume is
full, so each volume holds the WAL of an archive outage as well as the data: at least 4Gi, sixteen
hours of the 16MiB segment that the operator's default `archive_timeout` closes every five minutes
while there is any activity (192 segments, 3Gi), besides 1Gi for the data and the WAL a running
primary keeps, a floor `tests/postgresql.bats` holds every database of the overlay to. A larger
`CNPG_STORAGE_SIZE` reaches the `Cluster` once the application's Kustomization reconciles, which
Flux does only while every Kustomization it names in `dependsOn` is Ready. The operator then grows
every instance's claim to it, but only once its pass over the cluster reaches the volumes, which it
does not while, among others, it cannot reach the Barman Cloud plugin, an instance's pod is not
active (pending, finished or being deleted, as one is while its worker is down), an instance is
being made or a switchover or failover is under way; then no claim grows, and the primary's is
grown by hand ([alerts.md](runbooks/alerts.md#postgreswalarchivingfailing)). As
`linstor-node-local` allows expansion, the LINSTOR CSI driver grows a claim's volume and its XFS
file system in place, while the pod runs; no volume can be shrunk, as the operator's webhook
refuses a smaller size.

### Backups and restores

Each cluster archives its WAL continuously and takes a base backup every day to the object storage,
which, with the instances' replication, is what keeps a database through the loss of the cluster or
a mistake in its data, to any moment of the last 30 days; a daily dump beside it ([Dumps](#dumps)) is
the copy that is encrypted before it leaves the cluster. The component's `Cluster` archives through the plugin's entry in
`spec.plugins`, not through the in-tree `barmanObjectStore` the operator deprecates, and the
component adds an `ObjectStore`, a `ScheduledBackup` and an ExternalSecret.

- **Where.** The postgres bucket, `<BACKUP_BUCKET_PREFIX>-postgres`
  ([infrastructure.md](infrastructure.md#s3-keys-and-backup-buckets)), at the endpoint of
  `cluster-config`, under `<CLUSTER_NAME>/<namespace>/<name>`: the Kubernetes cluster's name, which
  `cluster-config` holds as `CLUSTER_NAME`, from the directory name of `clusters/<cluster>`, the
  namespace and the database's `CNPG_CLUSTER_NAME`. The plugin keeps `base/` and `wals/` there, and
  the daily dumps are the files directly in that directory, whose retention lists and deletes only
  those ([Dumps](#dumps)). Two databases never share a path, and a restored cluster writes under its
  own name.
- **How often.** A base backup is taken at 02:47 UTC every day, and one as soon as the
  `ScheduledBackup` is made. Every database's base backup starts at 02:47, the component's one
  schedule, so the base backups of the databases run together. The minute is one that no backup of
  another kind uses: the etcd snapshots run at minute 17, the OpenBao snapshots at minute 43, the
  volume backups at minutes of their own, and the dumps start at 02:00 and end by their deadline at
  02:45, and 02:47 is a quiet hour for the databases, so a base backup's reads and its upload meet no
  dump that starts on schedule, and no backup of another kind starts with them. A dump the CronJob
  starts late, as it may within the hour of its `startingDeadlineSeconds`, can still be running.
  WAL is archived as each segment fills or, five minutes after the last switch with any activity
  since, as the operator's default `archive_timeout` closes it.
- **How long.** Base backups and WAL are kept for a recovery window of 30 days, so a database can
  be restored to any moment of the last 30 days. After each base backup the plugin deletes what
  falls outside the window, with the delete right of the key it holds, which is the cluster's S3
  key and reaches every bucket of the project: a workload that holds it can delete the archive as
  well, the residual risk [ADR 0008](adr/0008-state-and-backups-are-encrypted-before-they-leave.md)
  states for every backup. Base backups and WAL are compressed with gzip.
- **The credentials.** An ExternalSecret in each database's namespace, `<name>-backup`, reads the
  cluster's S3 key from the secret store's key `volsync`, only its two key fields as the etcd
  snapshot job does, so nothing new is seeded for it and the restic master never reaches the
  namespace; the region from `cluster-config`; and the customer key below from the key
  `postgres-backups`. The S3 key may list, read, write and delete every object of the project's
  buckets; it cannot read the archive's content without the customer key. The instance's sidecar
  holds both, as it must, so whoever can read the Secret `<name>-backup` or run a command in a
  database pod can read the archive. No key is in the tree. The S3 key is rotated as the volume
  backups' is, whose store entry it is (`just bao-seed-volsync --rotate-s3`,
  [Volume backups](#the-repository-and-its-password)), and the ExternalSecret brings it into
  `<name>-backup` at its next refresh.
- **Encryption.** Every object is encrypted at the provider with a customer-provided key, SSE-C,
  not before it leaves the cluster ([ADR 0008](adr/0008-state-and-backups-are-encrypted-before-they-leave.md)):
  the `ObjectStore` names the Secret key in `s3Credentials.sseCustomerKey`, a base64 256-bit key,
  and sets neither `data.encryption` nor `wal.encryption`, which the plugin refuses together with
  it. SSE-C sends the key with every request that writes or reads an object, inside TLS, and the
  provider encrypts and decrypts with it without storing it; a read without the key is refused.
  The plaintext and the key therefore reach the provider on each request, and object names, sizes
  and times are visible to it. Barman uploads base backups as multipart objects and reads parts by
  range, which SSE-C supports; it never copies an object, so a provider that leaves out server-side
  copy of encrypted objects, which needs the source's key in further headers, serves it all the
  same.
- **The key and its custody.** One key serves every database of the cluster, as the recipe stays one
  small file and the databases' archives are kept apart by their paths, not their keys. `just
  bao-seed-postgres <file>`, once per store, makes it, keeps it in `<file>`, a new file outside the
  repository encrypted to the Talos age key's recipient and opened again before the store holds
  anything, then writes it into the store; it refuses a store that holds one, writes the key of an
  existing file into a store that holds none, as on a rebuilt cluster, and prints nothing of it, as
  [`just bao-seed-volsync`](#the-repository-and-its-password) does for the volume backups'
  master. **Losing the key loses every base backup and WAL segment.** It cannot be rotated in
  place: objects written under one key are unreadable under another, so a new key needs a new
  destination path or server name. `secret-rotation.yaml` lists it as `re-encryption`, so
  `just secret-rotate` refuses it ([Rotating an application's secret](#rotating-an-applications-secret)).
  The custody file belongs beside the Talos age key, outside the
  repository and the cluster ([postgres-restore.md](runbooks/postgres-restore.md#the-customer-key)).
- **Restoring.** A restore needs the customer key, in the store or in the custody file, the
  cluster's S3 key, the plugin running and the `ObjectStore` of the old cluster, which the
  component makes. [postgres-restore.md](runbooks/postgres-restore.md) restores one database to a
  point in time into a new cluster beside the old one, switches the application over, and says
  what the old archive needs so that two clusters never write to one path; it also restores a daily
  dump, the way back when the archive cannot be read. The component has no
  recovery input: a `bootstrap` section would change nothing for a cluster that is not restoring,
  but it is a field of the `Cluster` and not a value, so the runbook gives the manifest.
- **Alerts.** `PostgresWALArchivingFailing` and `PostgresBackupTooOld`
  ([Alerts](#alerts)), quiet on a healthy cluster and on one less than a day and a half old.

A cluster's data lives on the workers' data volumes, in the archive and in the dumps ([Where the data
lives](#where-the-data-lives)).

`tests/postgresql.bats` renders the operator's and the plugin's charts and checks their namespace,
definitions, replicas, budgets, monitors, images, certificates and pods; runs a TLS 1.3 handshake
between OpenSSL stand-ins for the plugin's server and the operator, each given the files the real
one reads, with certificates made as the plugin's issuer makes them, and checks that certificates
the cluster's CA would issue end it with `certificate required`; builds applications that
take a cluster from the component, one that does not name it and two that patch it, by kind and by
name, as Flux applies them, and checks their archive paths, schedule, retention, encryption and
credentials; holds the volume of every `Cluster` an application of the overlay with a database
builds, the component's and any beside it, built from its Kustomization as the overlay makes it, to
the 4Gi floor above, computed in the test from its sources, and fails for one that sets a WAL
volume, a segment size, an `archive_timeout` or a `wal_keep_size` of its own, turns
`resizeInUseVolumes` off or names a class that does not allow expansion; checks each field of the
`Cluster`, the `ObjectStore` and the `ScheduledBackup` against the pinned charts' definitions and
the restore runbook's manifest against the `Cluster`'s; and checks the `StorageClass` against
LINSTOR's. Its handshake runs the system's `openssl`, which
`mise.toml` does not pin: the CI tools image has the one its base image comes with, which
`versions.yaml` pins by digest, and an `openssl` that is missing or behaves otherwise fails the test
rather than passing it. `tests/postgres-dumps.bats` builds applications that
take a cluster from the component and runs the dump job's scripts as its containers run them, with
stand-ins for `pg_dump`, `pg_isready` and the S3 client. `tests/rules/cloudnative-pg.yaml` tests the
alerts.

### Dumps

The component adds a CronJob, `<name>-pgdump`, in the application's namespace, so an application
that names the component gets a daily copy of its database and passes nothing more. It runs at
02:00 UTC, never two at once (`concurrencyPolicy: Forbid`), with a start deadline of an hour, a
run deadline of 45 minutes, two retries and the last three failed runs kept. Each job waits a time
of its own, up to 20 minutes, before it starts: a checksum of the database's namespace and name,
modulo 1200 seconds, so databases on one schedule do not all start together (two can still draw
the same second; nothing breaks if they do). A pod of four steps runs in turn, each in the one image
that has its tool, so no image is built:

1. `fetch-age` downloads the pinned age release and checks it against the SHA-256 the manifest
   pins, as the etcd snapshot job does ([cluster.md](cluster.md#scheduled-etcd-snapshots)).
2. `dump` runs `pg_dump` in custom format, as the application's own role, the database `app`'s
   owner, never a superuser. It reads three keys of the Secret `<name>-app`, which the operator
   makes: `username`, `password` and `dbname`, as `PGUSER`, `PGPASSWORD` and `PGDATABASE`, never on
   a command line. It connects over TLS (`PGSSLMODE=require`) to `<name>-ro`, so a replica carries
   the read, and to `<name>-rw` only when no replica answers `pg_isready`: a cluster of one instance
   has no replica, its `-ro` Service has no endpoint, and its primary is dumped. A long dump from a
   replica can be cancelled by a conflict with the replica's recovery, which fails the attempt. Each
   retry waits its stagger again, and the job's one 45 minute deadline bounds all attempts, so a
   retry has less time than the first attempt did and a long dump can fail until the next night. The image is the Cluster's own, which carries `pg_dump`: the same registry
   path and PostgreSQL major as the Cluster's `imageName`, pinned by tag and digest in the CronJob,
   so the tool is never older than the server, which `pg_dump` refuses. `tests/postgres-dumps.bats`
   fails when the majors differ; Renovate moves the CronJob's image with the Cluster's, which share a package.
3. `encrypt` encrypts the plain dump with age to the Talos age key's recipient, the one
   `just cluster-snapshot` and the etcd job encrypt to, and removes the plain file. The recipient is
   in the manifest as the default of `CNPG_DUMP_AGE_RECIPIENT`, and the test holds it to
   `talos/.sops.yaml`'s, so there is one source of truth.
4. `upload` sends the one encrypted file with `rclone`, with the cluster's S3 key, to the postgres
   bucket under `<cluster>/<namespace>/<name>/<UTC time>.dump.age`, checks that the bucket lists it
   there, and deletes the oldest dumps of that path beyond the newest 14. `<cluster>` is the
   Kubernetes cluster's name, `lab-sto2`, the default of `CNPG_DUMP_CLUSTER`, which a second cluster
   that shares the bucket prefix must set: left at the default it would write to the same paths as
   `lab-sto2` and its retention would delete that cluster's dumps of the same namespace and name. It lists only its own path, and never creates a bucket or replaces an object.

The plain dump is on an `emptyDir` of its own, `plain`, memory-backed and limited to 512Mi, and only
the `dump` and `encrypt` containers mount it; the encrypted file goes to a disk-backed `out` of 1Gi,
the only volume the `upload` container sees. Memory-backed keeps the plain dump from any disk, and
512Mi holds the compressed dump of a small database, as n8n's; the `dump` container's memory limit,
768Mi, is that volume's size and room for `pg_dump`. A database whose dump outgrows the volume fails
the `dump` step with no space left, which fails the job and, an hour later, raises
[`PostgresDumpJobFailing`](runbooks/alerts.md#postgresdumpjobfailing): the volume is sized so it
cannot fill a node. Such a database patches the CronJob by kind, as above, with the volume's
`sizeLimit` and the container's memory limit together. The pod runs restricted, with every
container's requests and limits set and no service account token.

The S3 key reaches the pod through an ExternalSecret in the application's namespace,
`<name>-dump-s3`, which reads the two properties of the key `volsync` of the secret store, the key
the volume backups and the etcd snapshots use, and nothing else of it. Only the `upload` container
takes the Secret, and only the `dump` container takes the database's: the key that can delete
objects never meets the database's password. The key reaches every bucket of the project
([Infrastructure](infrastructure.md#s3-keys-and-backup-buckets)), so the job's rights end where the
code ends; the retention deletes only dumps of its own path. Nothing new is seeded, and no key is in
the tree. The key is rotated as the volume backups' is, whose store entry it is
(`just bao-seed-volsync --rotate-s3`, [Volume backups](#the-repository-and-its-password)): each
run's pod takes it from the Secret as that then is.
The scripts are the component's own copies of the etcd snapshot job's, as a component
cannot read a file outside its directory; `tests/postgres-dumps.bats` holds `fetch-age.sh` to the
etcd job's byte for byte, and the encrypting and uploading scripts to it line by line apart from the
words that say dump for snapshot and the path.

`just postgres-dumps <namespace> <name> [cluster]` lists a database's dumps, newest first, and
`just postgres-dump-check <namespace> <name> [dump|latest] [cluster]` decrypts one and has
`pg_restore --list` read it, printing counts and nothing of its contents and keeping nothing on disk
([postgres-restore.md](runbooks/postgres-restore.md)). `pg_restore` runs from the `dump` step's image
in `cronjob.yaml`, with no network and no log, so the check needs `docker` or `podman`
(`CONTAINER_RUNTIME` names one). The container runs as the caller's uid, which rootful Docker and
podman keep; rootless Docker and a host that enforces SELinux refuse the mount, and the check then
says the archive cannot be read.

**What a dump is not.** It is a copy of one day, not a point in time: a restore from it loses
everything written since the dump, and a dump holds one database's objects, not the cluster's roles'
passwords or its settings. Point-in-time recovery comes from the WAL archive and the base backups
([Backups and restores](#backups-and-restores)), which are encrypted at the provider with the
customer key; the dump is the copy encrypted before it leaves the cluster, as
[ADR 0008](adr/0008-state-and-backups-are-encrypted-before-they-leave.md) says, and needs only the
Talos age key to read, so it is the way back when the customer key is lost. `PostgresDumpStale` and
`PostgresDumpJobFailing` ([Alerts](#alerts)) fire when the newest dump is too old or the latest run
failed, and [postgres-restore.md](runbooks/postgres-restore.md#restoring-a-daily-dump) restores a dump
into a new cluster. Until the first base backup or dump has run a database's data lives on the
workers' data volumes alone ([Where the data lives](#where-the-data-lives)).

## OpenBao

Runtime secrets live in OpenBao (ADR 0005), which unseals itself with a key the cluster holds while
the operator keeps its recovery keys (ADR 0016). Four applications hold it:

- `openbao/openbao` runs OpenBao in the namespace `openbao`. It names `external-secrets`,
  `cert-manager`, `linstor-cluster` and `prometheus-operator-crds` in `dependsOn`, for the seal key's
  generator, its certificates, its volumes and its monitor; sets `wait`, so it is Ready once every
  member is unsealed; and has the long timeout, as the first install starts three members one after
  another.
- `external-secrets/openbao-store` holds the ClusterSecretStore `openbao`, its service account and
  the Role that lets External Secrets mint that account's tokens. It names `external-secrets` and
  `openbao` in `dependsOn`, and is Ready once the store reports Ready, which a health check
  expression reads, as kstatus does not.
- `demo/hello-secret` holds one ExternalSecret that reads `demo/hello` through the store. It names
  `openbao-store` in `dependsOn` and does not wait, as the key exists once an operator writes it.
  The Deployment `hello` mounts the Secret it writes as a file, so the demo's secret has pods to be
  rotated in ([Rotating an application's secret](#rotating-an-applications-secret)).
- `openbao/openbao-snapshots` holds the CronJob that snapshots the raft storage
  ([Raft snapshots](#raft-snapshots)). It names `external-secrets`, `openbao`, `openbao-store` and
  `prometheus-operator-crds` in `dependsOn`, and does not wait.

`tests/openbao.bats` builds the first three as Flux applies them and renders the chart with its
values; `tests/openbao-snapshots.bats` builds the fourth and runs its scripts against fakes of
OpenBao's client and of the object storage; `tests/openbao-recipes.bats` runs the recipes below
against fakes of the cluster and of OpenBao, and `tests/secret-rotate.bats` the rotation.

### What runs

The chart comes from its publisher's OCI registry, `oci://ghcr.io/openbao/charts/openbao`, with the
servers only: no agent injector, no CSI provider, and no UI, which is off in the server
configuration and has no Service. Every Service is internal to the cluster.

Three members run as a StatefulSet with OpenBao's integrated raft storage; each lists all three
in `retry_join`, so a member that starts joins whichever leads. A member runs only on a worker, a
node without the role label Talos gives every control plane, and never beside another member. A
member is Ready only while it is unsealed. A new release replaces one member at a time, each once
the one before is Ready again.

Each member's raft data is on a 2 GiB claim of the default StorageClass, which the claim does not
name: a few hundred small secrets, their versions, raft's log and the snapshots raft keeps beside it
stay far below 100 MiB, and a thin volume uses only what is written. The class keeps two copies of
the volume on two workers, beside the three copies raft keeps itself, where the
[Storage](#storageclasses) advice for an application that keeps its own copies is the node-local
class. OpenBao takes the replicated one on purpose: a member whose worker loses its data volume
comes back as itself, from LINSTOR's other copy, and rejoins as the same raft member, so a member
starting empty, which takes the steps in [the runbook](runbooks/openbao.md#a-member-that-does-not-rejoin),
stays an exception rather than what every lost disk causes.

A drain evicts one member at a time: the disruption budget lets one of the three be unavailable,
which leaves two, a majority. The evicted member keeps its claim, starts again once a node without
another member takes it, which on three workers is its own node once it is back, joins the others
and unseals itself. Autopilot never removes a member for being away (`cleanup_dead_servers` is
false), so it comes back as the same raft member.

The namespace enforces the restricted Pod Security level, which the servers, their init container
and the chart's test pod meet: they run as a non-root user with every capability dropped, no
privilege escalation and the runtime's seccomp profile.

The listener serves TLS from a CA of OpenBao's own: in the `openbao` namespace a self-signed Issuer
signs the CA `openbao-ca`, whose Issuer signs `openbao-tls`, the certificate for the Services, every
member under `openbao-internal` and the loopback address. cert-manager renews it before it expires
and the listener reloads it within 30 seconds. The store, the members joining each other, the
servers' own CLI and the monitor verify it against the CA. The chart's readiness probe does not: it
asks the server in its own pod, over the loopback address, whether it is unsealed, where no other
party can answer, and a certificate problem there would mark every member unready at once, which
the clients that do verify report instead.

The chart's ServiceMonitor scrapes the active member's `/v1/sys/metrics` without a token, which the
listener allows for that path alone. Anything that reaches the listener on the cluster's network
can read it: request counts and timings by operation, the names of mounts, auth methods and
policies, token counts, and raft's and the runtime's statistics; never a secret value, a token or
a key. No Service exposes it outside the cluster.

Every server logs at its default level, info, and audits every request and response to its log,
with each value in them, every token and every share among them, hashed: no audit device writes
anything in the clear. Self-initialisation logs its requests and responses, the root token among
them, only at trace level, which nothing sets.

A CronJob takes a snapshot of the raft storage every six hours and uploads it encrypted
([Raft snapshots](#raft-snapshots)).

### How it unseals

OpenBao's static seal unseals each member at every start with a 32-byte key from a file, without a
person. The key is in the Secret `openbao-seal-1` in `openbao`, mounted into the servers alone, not
into the chart's test pod. External Secrets makes it, once: its `Password` generator gives 32
characters of letters, digits and symbols, about 190 bits, hex-encoded into the 64 hexadecimal
digits the seal reads, and the ExternalSecret `openbao-seal-1` writes them into the Secret when it is
first synced and never again (`refreshPolicy: CreatedOnce`). The Secret has no owner, so deleting the
ExternalSecret or the application leaves it, and it is immutable, so nothing changes the key; an
ExternalSecret made again later finds it and keeps its key. Nothing in the repository holds it,
encrypted or not.

The key protects OpenBao's storage and every copy of it, such as a volume or its snapshot, read
outside the cluster: without the key it is ciphertext. It does not protect against whoever can read
Secrets in `openbao` or the cluster's etcd, as they hold the key and reach the storage. That is a
cluster administrator, the controllers that read Secrets in every namespace (Flux's, External
Secrets', cert-manager's and the Prometheus Operator's), all installed from pinned charts under
review, and whoever holds the Talos age key, which opens the etcd snapshots
([etcd-restore.md](runbooks/etcd-restore.md)).

### How it initialises

OpenBao initialises once, on a first install, from the initialize stanzas in
`app/initialize/initialize.json`, OpenBao's self-initialisation: it enables the Kubernetes auth
method, which checks a token with the API server's TokenReview as the servers' own service account;
mounts the key-value store, version 2, at `secrets/`; writes the three policies and roles below; and
turns autopilot's dead-server cleanup off. OpenBao runs them with the root token it initialised
with, then revokes it, and never returns it; no root token exists after the first start.

Before every start of every member, the init container `initialize-guard` decides whether that
server reads the stanzas (`app/initialize/initialize-guard.sh`). Only `openbao-0` may, and only on
positive evidence of a first install: its own data directory is empty, and the Kubernetes API answers
that neither `data-openbao-1` nor `data-openbao-2` exists. The StatefulSet makes those claims when it
first starts the other members and keeps them for the cluster's life, so either one means the store
exists. The guard reads them with kubectl as the servers' own account, which the Role
`openbao-initialize-guard` lets get those two claims and nothing else. kubectl finds the API through
the pod's in-cluster configuration, which client-go drops for `http://localhost:8080` once a flag
such as `--request-timeout` changes its configuration, so the call carries no such flag and
`timeout` ends it after 10 seconds instead. When the API gives no answer in that time, or the data
directory cannot be listed, whatever the reason, the guard fails, and the pod does not start; it
never initialises on missing evidence. The server takes the decision through
`app/initialize/initialize-args.sh`, which passes the `-config` flag only as the guard wrote it.

The guard holds the servers' account token, as every container of the pod does, so it may do all
that account may: create TokenReviews and SubjectAccessReviews, through `system:auth-delegator`, for
the Kubernetes auth method; get, list, watch, update and patch the pods in `openbao`, through the
chart's discovery Role; and get those two claims. It mounts the member's data volume read-only,
ciphertext without the seal key, the ConfigMap `openbao-initialize` and the directory of its
decision, and not the seal Secret or the listener's certificate. Its image is the Flux CLI's,
`ghcr.io/fluxcd/flux-cli`, which has the shell and kubectl the guard needs and comes from the
registry Flux's controllers already run from, so it adds no publisher to trust. It is pinned by
digest, at the version of the `flux2` pin in `mise.toml`; Renovate moves the two in one pull
request, and `tests/openbao.bats` fails when they differ.

An `openbao-0` whose volume is new while the other members' claims exist therefore never starts a
second, empty store: it waits to join them. When they run, it joins and copies the store. When they
do not, as after a full restart, the StatefulSet starts `openbao-0` first and the others only once it
is Ready, which an empty `openbao-0` never becomes alone, so the store stays down until the
[runbook](runbooks/openbao.md#a-member-that-does-not-rejoin) brings the others up first. That is the
price of never running two stores behind the active Service.

Self-initialisation marks storage as started before it runs and clears the mark when it completes;
a server that finds the mark refuses to unseal. A first install whose initialisation failed or was
cut short is therefore started again from nothing, as the
[runbook](runbooks/openbao.md#a-first-initialisation-that-failed) says. The stanzas never run again on
initialised storage, so a role, policy or mount changes afterwards with a root token from the
recovery keys (`just bao-root`).

### Who may do what

| Role | Logs in as | May |
|------|------------|-----|
| `external-secrets` | `openbao-store` in `external-secrets` | read and list every key of `secrets/`; look up and revoke its own token |
| `operator` | `openbao-operator` in `openbao` | create keys of `secrets/` and change them, never read them; make the recovery keys while none exist, and rotate them with three of the current shares; start a root token generation, which completes only with three shares; revoke its own token |
| `snapshot` | `openbao-snapshot` in `openbao` | take a snapshot of the raft storage; the snapshot job logs in as it ([Raft snapshots](#raft-snapshots)) |

Each role checks the audience `openbao`, carries one policy and not OpenBao's `default` policy, and
gives ten-minute tokens, which `external-secrets` may renew for up to an hour. None of the three
accounts has its token mounted into a pod automatically. A token for one is minted through the
Kubernetes API by a subject allowed to create `serviceaccounts/token` for it, and the snapshot job's
pod holds one for `openbao-snapshot` that its kubelet projects for the audience `openbao`
([Raft snapshots](#raft-snapshots)):

- `openbao-store`: External Secrets' controller, through the Role `openbao-store-token`, for this
  account alone; its chart's grant to create every account's token is off.
- `openbao-operator` and `openbao-snapshot`: cluster administrators, as the operator's kubeconfig
  is, and the Flux Operator and Flux's controllers, which hold cluster-admin to apply the tree;
  for `openbao-snapshot` also the kubelet, for the one pod that runs as it.

No other chart the tree installs grants creating service account tokens; the Piraeus operator's
one wildcard rule is confined to LINSTOR's own API group.

The `operator` role reaches the recovery keys and, through them, a root token. Recovery keys are
made once, by the first authenticated rotation, which `just bao-recovery` performs right after the
first reconcile. From then on a root token takes three of the shares, which only the operator's file
holds. If `bao-recovery`'s first run finds recovery keys already, someone else holds them, and the
store is rebuilt ([runbook](runbooks/openbao.md#first-initialisation)). Who may mint an `operator`
token holds cluster-admin, and with it the seal Secret and every Secret the store fills.

### What the operator keeps

Self-initialisation makes no recovery keys. Right after the first reconcile, `just bao-recovery <file>`
makes them, through OpenBao's authenticated rotation as the role `operator`: five shares, any three
of which make a short-lived root token when the roles no longer reach what has to be fixed. It writes
them, with the seal key, to `<file>`, a new file outside the repository, encrypted with age to the
Talos age key's recipient in `talos/.sops.yaml`, a key the cluster does not hold; opens it again with
the operator's Talos age key and compares it with what it wrote; and has OpenBao commit the shares
only then. A rotation it starts and does not complete is cancelled and its file removed; one left in
progress by an earlier run is cancelled first; a file made at the path meanwhile is never replaced.
Nothing of the shares or the key is printed or passed as an argument. OpenBao makes recovery keys
only while none exist, so the recipe refuses once they do: the file holds the only copy. The operator
keeps it outside the cluster, with the Talos age key.

### The recipes

Each recipe opens a port-forward to `openbao-active` and closes it on every exit; verifies OpenBao's
certificate against the CA; mints a ten-minute token for `openbao-operator` with the audience
`openbao`, logs in as `operator`, and revokes OpenBao's token when it is done. Through the cluster's
kubeconfig it needs to create `serviceaccounts/token` for `openbao-operator`, to port-forward to the
pods of `openbao-active`, and to read the Secret `openbao-ca`. A file it reads, the operator's, opens
with the Talos age key from `SOPS_AGE_KEY_FILE`, or `SOPS_AGE_KEY`, into memory only.

- A custody file is read only where no one but the operator can have written it, as age does not say
  who wrote a file and the recipient is public: the file is the operator's and writable by no one
  else, and each directory above it, on its path and as it resolves, is the operator's or root's and
  writable by no one else unless its sticky bit is set. A recipe that writes one, `bao-recovery` or
  `bao-seed-volsync`, writes it only to such a place, which is a directory only the operator can
  write, beside the Talos age key.
- A recipe refuses to run while the shell traces its commands, as bash would print every secret it
  reads: under `bash -x`, with `SHELLOPTS=xtrace` or a `BASH_ENV` that sets `-x`. A command it
  starts, such as the one `bao-root` or `bao-volsync-password` runs, gets no `BASH_ENV` or `ENV`.
- OpenBao's error messages are printed with each byte that is not printable ASCII as a question
  mark, so no control character reaches the terminal, and kubectl's errors through the same
  redaction as the other recipes', without the API server's address
  ([infrastructure.md](infrastructure.md#s3-keys-and-backup-buckets)).

- `just bao-put <path> <key>` writes one value, read from standard input, typed without echo at a
  terminal or piped in without the newlines that end it, as the key `<key>` of the secret at
  `secrets/<path>` in `lab-sto2`. The secret keeps its other keys, or is created. It takes exactly
  the two arguments, and a refusal repeats none of them, so a value typed where an argument goes is
  not printed. The value travels only in the body of the write; the recipe prints the path and the
  key.
- `just bao-recovery <file> [cluster]` makes the recovery keys once, as above; it also reads the
  Secret `openbao-seal-1`.
- `just bao-root <file> <command> [argument...]` makes a root token from three shares of the file,
  mints with it an orphan token of the root policy that lasts fifteen minutes at most, and revokes
  the root token before the command runs; if minting fails, it revokes the root token and runs
  nothing. It runs the command with that token in `BAO_TOKEN`, and OpenBao's address through the
  port-forward, its CA and its certificate's name in `BAO_ADDR`, `BAO_CACERT` and
  `BAO_TLS_SERVER_NAME`, as OpenBao's CLI reads them, then revokes the token, however the command
  ends; a recipe killed outright leaves it to expire. It prints no share and no token; a generation
  it started and did not finish is cancelled. It reads the root token's accessor before anything
  else; when OpenBao does not revoke a token, it names the token by its accessor, which serves to
  look up, renew or revoke a token but not to act as it, prints the step that revokes it by that
  accessor, and fails even when the command succeeded. No command runs while the root token lives.
- `just bao-seal-restore <file> [--replace]` writes the seal key from the file back into the Secret
  `openbao-seal-1`, immutable; a Secret that holds the same key is left alone, and one that holds
  another key is replaced only with `--replace`. Before deleting it, `--replace` keeps its key in a
  new file `<file>.replaced-<time>.age` beside the file, encrypted to the same recipient and opened
  again with the operator's key, and deletes nothing when it cannot. It needs no port-forward, only
  to read, create and, with `--replace`, delete that Secret.
- `just bao-seed-volsync <file> [cluster]` seeds the key `volsync` the volume backups read, once for
  each store, with the master password in `<file>`, which its first run makes;
  `just bao-seed-volsync --rotate-s3 [cluster]` replaces only the S3 key in it.
  `just bao-volsync-password <file> <app> <command> [argument...]` runs a command with one
  application's repository and password. Both are described under
  [Volume backups](#what-an-operator-does-once-and-what-then-happens-by-itself). The first creates
  the key and never reads one, as the `operator` role may only create and patch keys.
- `just secret-rotate <path> <key> [--yes] [--wait <seconds>]` replaces a key that
  `secret-rotation.yaml` lists as `generated` with a value it makes, and proves that every pod that
  mounts it holds the new value
  ([Rotating an application's secret](#rotating-an-applications-secret)). It opens no session of its
  own: its one write is `bao-put`'s, which it runs with the value on standard input, and it logs in
  to OpenBao no other way.

The snapshot recipes, `just openbao-snapshots` and `just openbao-snapshot-check`, are under
[Raft snapshots](#raft-snapshots): they reach the object storage only, never the store.

### How an application gets a secret out

An application reads a key with an ExternalSecret that names the ClusterSecretStore `openbao`, the
path as `remoteRef.key` and the key as `remoteRef.property`. The store logs in as `external-secrets`
and reads the key-value mount and nothing else. `demo/hello-secret` is the example: once
`just bao-put demo/hello greeting` has written the key, a value of random bytes that nobody types
([runbook](runbooks/openbao.md#first-initialisation), step 8), the Secret `hello` in `demo` holds
the key `greeting`, and the pods of `hello` mount that key at `/etc/hello/greeting`, outside `/www`,
the one directory their web server serves. The volume is optional: the pods run before anyone has
written the key, and the kubelet adds the file, without a restart, once the Secret holds it. Until
the key is written the ExternalSecret fails, and External Secrets tries it again after a delay that
doubles from a second up to seven minutes (`BuildRateLimiter` in `pkg/controllers/common/common.go`
at v2.15.0), so the Secret can follow a first value that long after it is written, and the file
follows within the kubelet's sync period. The Deployment carries
`secret.reloader.stakater.com/reload: hello`, so Reloader restarts its pods when the Secret's data
changes ([The kube-system baseline](#the-kube-system-baseline)).

The store serves every namespace. Creating an ExternalSecret is reserved to cluster administrators
and Flux, which applies those in Git after review; no RoleBinding grants `edit` or `admin`. A
namespace delegated to anyone else first gets its own store restricted with `conditions`.

### Rotating an application's secret

`secret-rotation.yaml`, at the repository's root, says how each key of the store that an
ExternalSecret of the tree reads is rotated. An entry has the `path` and the `key` as `bao-put`
takes them, a `rotation` and, unless that is `generated`, a `reason` of one sentence; an entry
without a `key` is for every key at its path that no other entry names. `tests/openbao.bats` reads
every ExternalSecret under `kubernetes/` and fails while a key one of them reads has no entry, or
an entry names a key none reads. It reads them as their files hold them. A patch or a replacement
could change what Flux applies of them, so the test fails as well on one, in a file under
`kubernetes/` or in the text of a patch there, whose target or select names no kind or a kind that
`ExternalSecret` matches as kustomize matches it, a regular expression of the whole name, and on a
patch whose text names the kind.

| Rotation | What it says of the key | How the key is rotated |
| --- | --- | --- |
| `generated` | Any new random value will do. | `just secret-rotate <path> <key>`, below. `greeting` at `demo/hello` is the only one. |
| `re-encryption` | Data is encrypted under the value. | By no recipe: a new value loses that data unless it is encrypted again under it, and the application's section says what that would take. They are n8n's encryption key ([n8n](#n8n)), the volume backups' master password ([Volume backups](#the-repository-and-its-password)) and the PostgreSQL backups' customer key ([Backups and restores](#backups-and-restores)), and none is rotated. |
| `issued` | The value is made elsewhere, by a provider that issues it or by the owner who writes it. | A new one is made there and written with `just bao-put <path> <key>`, or with `just bao-seed-volsync --rotate-s3` for the cluster's S3 key; the ExternalSecret brings it into the Secret at its next refresh, within its `refreshInterval`. The application's section says what then reads it. |

`just secret-rotate <path> <key> [--yes] [--wait <seconds>]` (`scripts/secret-rotate`) rotates a
`generated` key on `lab-sto2`. It takes the path and the key, never an ExternalSecret or a
workload: those it finds in the cluster. In order:

1. **Before it reaches the cluster** it refuses to run while the shell traces its commands, as the
   other recipes do; anything but a path and a key `bao-put` would take, repeating none of what it
   was given; a `--wait` that is no whole number of seconds of at most nine digits; a list it
   cannot read as entries; a key the list has as `re-encryption` or `issued`, with the entry's
   reason; and a key the list does not name, saying to add its entry.
2. **It reads the cluster and changes nothing.** Every ExternalSecret, in any namespace, that
   reads the key from the ClusterSecretStore `openbao`, by the path or by the path with `secrets/`
   or `secrets/data/` in front, which External Secrets reads as the same path; for each, the
   Deployments, StatefulSets and DaemonSets of its namespace whose pod template names its Secret;
   their running pods; and from each pod the SHA-256 digest of the file, which `sha256sum` takes in
   the container through `kubectl exec`. It refuses, naming what and why, when no ExternalSecret
   reads the key; when one reads it otherwise than as one entry of `spec.data` with
   `remoteRef.key` and `remoteRef.property` alone and no template, finds keys of the store by a
   pattern, writes no Secret or an immutable one, or would not refresh again
   (`refreshPolicy: CreatedOnce`, or a `refreshInterval` of zero under the periodic policy, the
   default); when one is not Ready; when
   no workload uses the Secret; when a workload takes it through its environment, `envFrom`, a
   projected volume, a `subPath`, a volume without the key, or only in an init container; when a
   workload carries no annotation by which Reloader restarts it for that Secret, could not replace
   every pod (paused, `OnDelete`, a partition), selects its pods with `matchExpressions`, is in the
   middle of a rollout or has no running pod; when a pod holds no file yet; when a container
   cannot run `sha256sum`; and when a `kubectl exec` does not answer within 30 seconds, the time
   each exec is given here and in the proof, as each other request to the API server is.
   Reloader's annotations are read as the pinned Reloader reads them:
   `secret.reloader.stakater.com/reload` naming the Secret, `secret.reloader.stakater.com/auto` or
   `reloader.stakater.com/auto`, on the workload or, where it carries none of them and no
   `reloader.stakater.com/search`, on its pod template; a workload whose own
   `secrets.exclude.reloader.stakater.com/reload` names the Secret is refused. Reloader takes each
   name of the first as a regular expression; the recipe counts only the Secret's own name.
3. **It prints the plan**: the path and the key and that a new value is made here, each
   ExternalSecret and its Secret, each workload with its number of pods and the annotation that
   restarts it, and the file and container the proof reads. Then it asks for the path to be typed
   back, which `--yes` answers. Anything else, or the end of the input, ends the run with nothing
   changed. The answer is read the same from a terminal and from a pipe
   (`printf 'demo/hello\n' | just secret-rotate demo/hello greeting`): every command the recipe
   starts gets `/dev/null` for its standard input, or a pipe of its own.
4. **It makes the value**, 32 random bytes of the kernel as 64 hexadecimal digits, as
   `just bao-seed-volsync` makes its master, and stops if it is a value a pod already holds. It
   writes it by running `scripts/bao-put` with the value on its standard input: that is the only
   write, and the recipe sends OpenBao nothing itself.
5. **It asks each ExternalSecret to refresh** by setting its annotation `force-sync` to the time
   and eight random bytes, a value no other run sets, and reads it until its
   `status.syncedResourceVersion` is another than before the annotation, for up to the wait, 300
   seconds unless `--wait` says otherwise. External Secrets makes that field of the generation
   and a hash of the labels and annotations each time it has synced, and syncs when it differs
   from what the object has now. An ExternalSecret that is not Ready when it is read ends the
   run. The wait has to cover a refresh, in which External Secrets logs in to the store, reads
   the key and writes the Secret and its own status: with `--wait 0` each ExternalSecret is read
   once, straight after its annotation, which on the cluster comes before it has refreshed, so
   such a run stops after the write.
6. **It waits for the restart**: for each workload's generation to pass the one read before, which
   Reloader's change to the pod template moves, and then for `kubectl rollout status`, both within
   the wait. `kubectl rollout status` alone would be satisfied by the rollout of before.
7. **It proves**, for every running pod that is not being deleted, that it is none of the pods
   read before, by UID, and that the digest of its file is the digest of the value written. With
   step 4, none of them holds a value from before. A pod that fails either is named. A pod that
   is being deleted is not counted: it is gone within its grace period.
8. **It ends with one line**: the key, the path, how many pods of which workloads hold the new
   value, and the seconds from the confirmation to the proof.

**Why the proof is made of digests.** The role `operator` may create and patch a key and never
read one, so the recipe can read neither the old value nor the new one back from the store, and it
gets no wider right for the proof. Three digests stand in. The old one is taken in each pod
before the write; the store's is the digest of the value the recipe made, which `bao-put`'s write
answered for; the new one is taken in each new pod. The value reaches a pod only from the store,
through the ExternalSecret, so a pod whose digest is the written one holds what the store served.
The recipe never reads the Secret. Neither the value nor a digest is printed, passed as an
argument, exported or written to a file: they stay in the shell's memory and on pipes, and the
recipe makes no file.

**What it needs.** On the operator's machine, the pinned `kubectl`, `jq` and `yq`, and `curl`,
`base64`, `head`, `od`, `tr`, `sha256sum`, `sed`, `date` and `sleep`. Through the
kubeconfig, what `bao-put` needs ([The recipes](#the-recipes)) and, beyond it, to read the
ExternalSecrets of every namespace and to annotate those that read the key; to read the Deployments,
StatefulSets, DaemonSets and pods of their namespaces; and to run a command in those pods
(`pods/exec`). It reads no Secret but OpenBao's CA certificate, which `bao-put` reads. In the
container, `sha256sum`, which prints the digest before the file's name: BusyBox, `hello`'s image,
has it. `kubectl exec` reaches the container through the API server and the kubelet, not the pod
network, so no network policy is involved; it runs `sha256sum` alone, with no shell and no terminal,
a binary of the image reading a file that no rule of the ruleset Falco runs treats as sensitive, so
no rule of [Runtime detection](#runtime-detection) matches it; and the admission policies look at
pods and namespaces as they are created and updated, not at a command run in one.

**What a run that stops leaves.** Before the write, nothing: it says so. If `bao-put` does not
confirm the write, the store holds the value from before or the new one, and the recipe says that.
After the write, the store holds the new value whatever fails, and a second run writes another
value and proves that one, whatever the pods hold when it starts. What else is left depends on the
refresh, and the recipe says which:

- When an ExternalSecret turns not Ready or does not refresh within the wait, its Secret follows
  at the ExternalSecret's next refresh by itself, and Reloader restarts the workloads when it does.
  Where several ExternalSecrets read the key, this holds for those that had not refreshed yet; the
  Secret of one that had holds the new value already, as below.
- Once every ExternalSecret has refreshed, the Secrets hold the new value, and the files of the
  running pods take it within the kubelet's sync period, as the recipe takes only a volume mounted
  without `subPath`. That is what it says when a workload's rollout does not finish, when the proof
  fails, and when a workload's generation does not move. A generation that does not move means
  Reloader did not restart the workload, and once it has seen the change it will not restart it
  for that change by itself: it restarts for an update of the Secret as it sees it, retries a
  restart that fails five times, spaced 5 to 80 milliseconds apart by its work queue's default rate
  limiter, and then drops it; and with `reloadOnCreate` off, as Reloader's rendered arguments in
  `tests/openbao.bats` hold, it does nothing for the Secrets it finds when it starts, which it sees
  as created, so a change made while it was down restarts nothing (`Update`, `Add` and `handleErr`
  in `internal/pkg/controller/controller.go` at v1.4.24). A Reloader that has not seen the change
  yet, as when the wait is shorter than it takes to, may still restart the workload, whose new pods
  then hold the new value. A later refresh reads the same value and makes no change it would act
  on.

A new pod's file is the Secret as the kubelet's watch of it has it when the pod starts, which
follows the API server within moments; a pod started before the watch had the change would hold
the value from before until the kubelet's next sync of its volumes, within a minute or so, and fail
the proof.

**What Git does not declare.** A rotation leaves two fields on objects Flux applies. The
annotation `force-sync` is written with kubectl, and Flux takes a field kubectl wrote on an
object it applies for its own at its next apply and removes it, as Git does not declare it
(kustomize-controller's cleanup of `kubectl` field managers); External Secrets answers that
change with one more refresh, which reads the same value and changes nothing. Reloader restarts
a workload by writing a variable, `STAKATER_<SECRET>_SECRET`, into the environment of the
container that mounts the Secret, under its own field manager, which Flux leaves alone, so the
variable stays, and no reconcile restarts the pods for it. Its value is a SHA-1 digest of the
Secret's keys and values, readable by whoever can read the Deployment, and kept as well in the pod
template of each ReplicaSet the Deployment keeps of its earlier rollouts, ten by default: nothing
can be made of it for 32 random bytes, and it is a reason to keep a value a person chose out of a
Secret that a workload is restarted for, and to write the first value of a `generated` key from
random bytes too.

`tests/secret-rotate.bats` runs the recipe against a fake cluster that holds the tree's own
ExternalSecret and Deployment, and `tests/openbao.bats` holds the Deployment's mount and
annotation, Reloader's rendered arguments and role, and the list. What only the cluster shows is
the rotation itself: `just secret-rotate demo/hello greeting`. The fakes do not model External
Secrets, Reloader or BusyBox's `sha256sum`, so the recipe is run that way again after a pull
request that bumps any of them is merged.

### Raft snapshots

The CronJob `openbao-snapshots` (`apps/base/openbao/openbao-snapshots/`) takes a snapshot of the
raft storage every six hours (`43 */6 * * *`, a minute the etcd snapshot job's runs, at 17, never
share), encrypts it to the Talos age key's recipient before it leaves the pod, and uploads only that
file to the OpenBao bucket, `BACKUP_BUCKET_PREFIX` followed by `-openbao`
([infrastructure.md](infrastructure.md#s3-keys-and-backup-buckets)), as
`<cluster>/<UTC time>.snapshot.age`, the name the etcd snapshot job and the operator's recipes give
theirs. It is the etcd snapshot job's pattern
([cluster.md](cluster.md#scheduled-etcd-snapshots)): a run never starts while another runs, a 20
minute deadline, two retries, one successful and three failed runs kept, the same four steps in the
same order, and the same retention. The private half of the age key is never in the cluster, so the
job can encrypt and cannot decrypt.

**Where it runs.** In the namespace `openbao`, because the role `snapshot` binds the account
`openbao-snapshot` in that namespace and no other (`app/initialize/initialize.json`); a job in a
namespace of its own would need the role changed with a root token, which the initial configuration
never does again. The namespace enforces the restricted level, which the job's pod meets.

**What the role permits.** The policy `snapshot` holds one path, `sys/storage/raft/snapshot`, with
the capability `read`: the request that takes a snapshot, which is the policy OpenBao's own
documentation of a snapshot job gives. It does not permit restoring a snapshot (an update of that
path), forcing one (`snapshot-force`), reading or writing any key of `secrets/`, or revoking the
token it is given, so a token lives out its ten minutes. The role gives no `default` policy. Nothing
in it is wider than taking a snapshot, and `tests/openbao-snapshots.bats` holds it to that one path
and capability.

**How it logs in.** The pod runs as `openbao-snapshot`, which no RoleBinding gives a right in the
Kubernetes API, and mounts no token for that API. Its one token is projected by the kubelet for the
audience `openbao` and for 600 seconds, the shortest the kubelet gives, into a volume only the step
that logs in mounts, read-only. The step `snapshot` logs in to the Kubernetes auth method as the
role `snapshot` with it, and saves the snapshot from the active member with the token OpenBao
returns. That token is in a shell variable and in the environment of the one command that uses it:
never in an argument, a file or the output, and the step writes only to memory-backed volumes, its
scratch directory one that the upload container, which holds the S3 key, does not mount.
OpenBao's client reaches `openbao-active` over TLS, verified against the CA, by that Service's name,
which the listener's certificate holds; the pod gets the CA, the one file `ca.crt` of the
certificate's Secret, and never the listener's key. The test runs the script against a client that
records its calls, and the step makes two: the login and the save.

**The steps, and the images.** `fetch-age`, `encrypt` and `upload` run in rclone's image, as the
etcd snapshot job's do, and `snapshot` in `quay.io/openbao/openbao`, the image the servers run.
Every image is pinned by tag and digest. The client's tag is the servers' tag, which the pinned
chart names, and `tests/openbao-snapshots.bats` renders the chart with the repository's values and
fails when the job's repository and tag differ from the servers'; Renovate moves the chart and the
image in one pull request. The plain snapshot is written to a memory-backed volume of 256 MiB that
only `snapshot` and `encrypt` mount, so it never reaches a disk and is never given to the upload; a
store of a few hundred small secrets is far below it, and a snapshot that outgrows it fails the run,
which `OpenBaoSnapshotJobFailing` reports. The scripts `fetch-age.sh` and `upload.sh` are copies of
the etcd snapshot job's, and `encrypt.sh` differs from its copy by a message: the artifact an
application is reconciled from carries its own `app/` and the shared `components/` only, so scripts
shared by both jobs would need a component of their own and both jobs' tests pointed at it, which
costs more than the copies do. `tests/openbao-snapshots.bats` runs each of them as its container
does, with the same checks as the etcd snapshot job's.

**What a snapshot is worth.** A snapshot is the raft state of the store: a tar archive, in a gzip
stream, of `meta.json`, `state.bin`, `SHA256SUMS` and `SHA256SUMS.sealed` (OpenBao's source, in the
pinned release's `internal/physical/raft/snapshot`). It holds everything the store holds: every key
of `secrets/`, every version, the policies, the roles and the auth methods' configuration. OpenBao
keeps that data encrypted with a keyring that a root key protects, which the seal protects
([seal](https://openbao.org/docs/concepts/seal/)), so a snapshot is ciphertext until it is restored
into a store that unseals with the same seal key; the archive's checksums are sealed with the
store's seal, which is how a restore checks that the snapshot was sealed with the seal key the store
unseals with; a new store with the same seal key passes. A restore that skips that check, `snapshot-force`, installs data that still opens only with the seal key
([API](https://openbao.org/docs/api/system/storage/raft/)). The age layer keeps a copy that leaves
the cluster unreadable to anyone who holds the S3 key without the operator's age key.

`meta.json` is raft's record of the snapshot, as `getMetaFromFSM` and `openFromFSM` in the pinned
release's `internal/physical/raft/snapshot.go` fill it: the version of that record, 1; a fixed ID;
the index and term of the last entry the store had applied; the raft configuration, each member by
its ID and address, and the index it was made at; and the length of `state.bin`. It holds no time
and no OpenBao version: the one time the archive carries is on its members, which `write` in
`internal/physical/raft/snapshot/archive.go` sets when the server writes it, and the stream is not
compressed (`Write` in `snapshot.go` beside it). `state.bin` is every storage entry as the store
keeps it, its path in the clear (`writeTo` in `internal/physical/raft/fsm.go`), and `SHA256SUMS`
the SHA-256 of those two. Without the seal key that much can be verified, and
`just openbao-snapshot-check` verifies it: the stream is whole, the members are the four, the
metadata is of the version OpenBao restores and gives the state's size, and both checksums match.
What cannot be verified without it is that `SHA256SUMS.sealed` opens under the seal key and gives
the same checksums, which a restore checks (`handleStorageRaftSnapshotWrite` in
`internal/vault/logical_system_raft.go`) and which alone ties an archive to the store that wrote
it, as the plain checksums are not signed and the age recipient is public; and that the store's
keyring opens the data. Of the entries of `state.bin` the check knows the checksum alone.

This backup covers the loss of the three volumes, or of the cluster, while the seal key is kept in
the operator's file, which `just bao-recovery` writes with the recovery keys: the store is started
again with that key and the snapshot restored into it
([runbook](runbooks/openbao.md#restoring-a-snapshot)). It does not cover the loss of the seal key,
which makes every snapshot as unreadable as the volumes; of the Talos age key, which leaves every
snapshot undecryptable; or of the bucket's contents. What was written after the newest snapshot, up
to six hours, is lost; the alerts below say when the newest is older than 13 hours.

**The S3 key.** An ExternalSecret reads the two properties of the secret store's key `volsync`, the
cluster's S3 key, which `just bao-seed-volsync` has written for the volume backups
([Volume backups](#what-an-operator-does-once-and-what-then-happens-by-itself)); nothing more is
seeded, and the restic master password in the same key is never read. Only the uploading container
takes the key, as environment variables from the Secret `openbao-snapshots-s3`. The key lets the job
delete and overwrite objects, as it lets every holder of it: it reaches every bucket of the project,
the etcd bucket and the state bucket among them. The job itself deletes only snapshots of its own
cluster's prefix beyond the newest 56, two weeks, once the new one is listed, and never overwrites an
object (an upload fails on a name that exists). That the key reaches more than the job needs is the
residual risk of [ADR 0008](adr/0008-state-and-backups-are-encrypted-before-they-leave.md), stated in
[the infrastructure document](infrastructure.md#s3-keys-and-backup-buckets); what the key cannot do
is read a snapshot. Whoever can read Secrets in `openbao` reads this key too, and already holds the
seal key. The key is rotated as the volume backups' is, whose store entry it is
(`just bao-seed-volsync --rotate-s3`, [Volume backups](#the-repository-and-its-password)): each
run's pod takes it from the Secret as that then is.

**What it needs.** The pod reaches `openbao-active`, the object storage's endpoint and, for the age
release, the release host of age's project over the pod network, and runs on a worker, as it
tolerates no taint. The recipient, `OPENBAO_SNAPSHOT_AGE_RECIPIENT` in the application's `ks.yaml`, is
`talos/.sops.yaml`'s, as the artifact holds `kubernetes/` only; `tests/openbao-snapshots.bats` fails
when it differs from that file's or from the etcd snapshot job's, so a new Talos age key
(`just cluster-age-key`) changes all three; the snapshots already in the bucket stay encrypted to
the old key.

**Selecting it.** The overlay of a cluster lists the application's `ks.yaml`; the namespace is the
store's. A cluster whose overlay leaves it out builds none of it. Its Kustomization waits for
`openbao`, for `openbao-store`, which is Ready once the ClusterSecretStore is, for External Secrets
and for the monitoring definitions.

**Seeing and taking a snapshot.** `kubectl --namespace openbao get cronjob,job` shows the runs and
`kubectl --namespace openbao logs job/<job> --all-containers` says which step failed (`fetch-age`,
`snapshot`, `encrypt` or `upload`). To take one now,
`kubectl --namespace openbao create job --from=cronjob/openbao-snapshots <name>`.
`just openbao-snapshots [cluster]` lists what the bucket holds of a cluster's store, newest first,
and `just openbao-snapshot-check [snapshot|latest] [cluster]` downloads one, decrypts it with the
Talos age key and verifies its archive, printing its metadata and nothing of the store and keeping
nothing ([runbook](runbooks/openbao.md#listing-and-checking-snapshots)). Both read the bucket with
the state key and reach nothing but the object storage. The alerts are
[`OpenBaoSnapshotStale`](runbooks/alerts.md#openbaosnapshotstale) and
[`OpenBaoSnapshotJobFailing`](runbooks/alerts.md#openbaosnapshotjobfailing)
([Alerts](#alerts)).

### When something is lost

- **The seal Secret, with the volumes intact**: the members that run keep serving, unsealed; one that
  restarts cannot start, as the Secret it mounts is missing, and the data stays sealed on its volume.
  `just bao-seal-restore` writes the key back from the operator's file; an etcd snapshot also holds
  it ([runbook](runbooks/openbao.md#bringing-the-seal-key-back)).
- **The volume backups' key `volsync`, or the master's file**:
  [the runbook](runbooks/volume-backups.md) says what each loss means, and how the key is seeded
  again from the file.
- **The seal Secret and every copy of it**: every runtime secret is lost, the snapshots in the bucket
  with them, as they are ciphertext that only the seal key opens. OpenBao starts again empty only
  once its three claims, the Secret and the ExternalSecret `openbao-seal-1` are deleted: the
  ExternalSecret has synced once and never makes a missing Secret again, so Flux makes it anew, it
  makes a new key, and every secret is written again.
- **The operator's file**: nothing is lost while the roles work. If a role or policy breaks, the way
  back to privileged access is gone, and new recovery keys need a threshold of the old ones; what is
  left is a new OpenBao with every secret written again. The seal key in the file is the key a
  snapshot needs, so without the file and the Secret a snapshot restores nothing either.
- **One member's volume**: the member starts empty, does not initialise, and joins the others, which
  hold every secret; [the runbook](runbooks/openbao.md#a-member-that-does-not-rejoin) says what to do
  when it does not rejoin.
- **The three volumes, or the whole cluster, while the operator's file is kept**: the snapshots cover
  this loss. The store is started again empty with the seal key of the file in its Secret, and the
  newest snapshot is restored into it ([the runbook](runbooks/openbao.md#restoring-a-snapshot)); what
  was written after that snapshot, up to six hours of it, is lost. The snapshots do not cover the loss
  of the seal key, of the Talos age key that opens them, or of the object storage's bucket.

## Applications

An application that is not part of the platform has a namespace directory under `apps/base/`, as
[Adding an application](#adding-an-application) sets out, and takes what it needs from the pieces
above: its database from [PostgreSQL](#postgresql), its volume and the volume's backup from
[Volume backups](#volume-backups), a secret from [External Secrets](#external-secrets) and a public
name from [the public Gateway](#giving-an-application-a-public-hostname). A cluster runs it with two
entries in its overlay, the namespace directory and the application's `ks.yaml`. With only the
namespace directory's, it gets the namespace and the `app-template-defaults` ConfigMap of
`components/common` and nothing of the application; with neither, nothing of the namespace.
`tests/applications.bats` proves each of these for n8n and for Open WebUI on the objects the overlay
builds and the chart renders (`features/applications.feature`).

### n8n

n8n, the workflow automation tool, runs in `ai-system` (`apps/base/ai-system/n8n/`). The namespace
enforces the restricted Pod Security level and carries the Gateway label; it holds no default deny,
and `network-policy-exceptions.yaml` lists it with n8n's flows ([Network policy](#network-policy)).
n8n's `ks.yaml` names the operator, the Barman Cloud plugin, the Prometheus Operator definitions,
External Secrets, the store's application, VolSync, LINSTOR, the public Gateway and the blackbox
exporter in `dependsOn`, and sets `wait` with the long timeout, so a cluster that lacks one of them
is refused by `just kubernetes-check`, the encryption key's ExternalSecret is applied once the store
is Ready, and the application is Ready once n8n answers its readiness endpoint.

- **The chart** is app-template, from its publisher's OCI registry, pinned by tag and tracked by
  Renovate, with the images `docker.io/n8nio/n8n` and `docker.io/n8nio/runners` pinned by tag and
  digest in `values.yaml`. It is the chart `components/common` has defaults for, and it puts n8n's
  environment, probes, security context and volumes in values this tree reads in full. A chart made
  for n8n alone would add keys of its own between those values and the pod. The pod's user and
  security context are written out in the values rather than taken from `app-template-defaults`
  through `valuesFrom`, as `scripts/render` reads only the ConfigMaps an application builds itself
  and refuses a release whose values come from one it does not find; `app-template-defaults` is not
  used until the render reads the namespace's ConfigMaps too.
- **The database** is a PostgreSQL cluster named `n8n-db` from `components/cnpg-cluster`, with the
  component's three instances and 5Gi each. n8n reads its host, port, database, user and password
  from the keys `host`, `port`, `dbname`, `username` and `password` of the Secret `n8n-db-app`, which
  the operator makes; no credential is in a values file, and the connection is without TLS, inside
  the cluster. The component archives its WAL and backs the database up daily to the object storage
  ([Backups and restores](#backups-and-restores)), and dumps it once a day, encrypted
  ([Dumps](#dumps)); the `external-secrets` and `openbao-store` in n8n's `dependsOn` serve the S3
  key and the customer key the backups read and the S3 key the dump job reads as much as the
  encryption key.
- **The encryption key** `N8N_ENCRYPTION_KEY` encrypts the credentials n8n stores in its database.
  It comes from the secret store, as [How an application gets a secret out](#how-an-application-gets-a-secret-out)
  describes: the ExternalSecret `n8n-encryption-key` reads the property `encryption-key` at
  `ai-system/n8n` through the ClusterSecretStore `openbao` into the Secret `n8n-encryption-key`,
  every 15 minutes. The operator writes it once, with a random value that is never displayed: 32
  bytes from the kernel as 64 hexadecimal digits, the way `just bao-seed-volsync` makes its master,
  piped into the recipe:

  ```sh
  head -c 32 /dev/urandom | od -An -vtx1 | tr -d ' \n' | just bao-put ai-system/n8n encryption-key
  ```

  Until the store holds it, the ExternalSecret reports the key missing, the pod waits for its
  Secret, and the application is not Ready. Where the key then lives:
  - in OpenBao, at `secrets/ai-system/n8n`, on its members' volumes;
  - in the Secret `n8n-encryption-key`, and so in etcd and its snapshots, encrypted to the Talos age
    key ([etcd-restore.md](runbooks/etcd-restore.md));
  - in n8n's settings file, `/home/node/.n8n/config` on the claim, where n8n copies it at its first
    start; and so in every backup of the volume, in the application's restic repository, encrypted
    with the repository's password.

  n8n refuses to start when its settings file holds another key than the one it is given
  ("Mismatching encryption keys"). A restored volume holds the key it was backed up with, so the
  store must hold that same key before n8n starts on it. On a rebuilt cluster OpenBao starts empty,
  as its data does not survive a rebuild ([rebuild.md](runbooks/rebuild.md)), so the order is: the
  store's recovery keys and the backups' key, as for every application
  ([the runbook](runbooks/volume-backups.md#the-stores-key-is-lost-and-the-file-is-kept)), which lets
  the claim be restored; then the encryption key, before n8n starts. n8n's pod waits for its Secret
  meanwhile, so n8n does not start without the key. When the operator keeps no copy of the
  key, it is read back from the latest backup of the volume, by hand, into a directory only the
  operator can read, and written to the store without being displayed:

  ```sh
  install -d -m 700 <directory>
  just bao-volsync-password <file> n8n restic restore latest --target <directory>
  jq -j .encryptionKey <directory>/config | just bao-put ai-system/n8n encryption-key
  rm -rf <directory>
  ```

  `<file>` is the backups' custody file ([Volume backups](#volume-backups)); a backup holds the
  volume's files at its root. Should the store be given another key by mistake, n8n stops at its
  next start with that message, and nothing is lost: writing the right key and letting the
  ExternalSecret refresh starts it again. `secret-rotation.yaml` therefore lists the key as
  `re-encryption`, and `just secret-rotate` refuses it
  ([Rotating an application's secret](#rotating-an-applications-secret)): rotating it would mean
  encrypting the stored credentials again under the new key and putting that key into the settings
  file on the volume, which no recipe here does, so the key is kept.
- **The volume** is the claim `n8n` of `components/volsync`, 5Gi on the default StorageClass,
  mounted at `/home/node/.n8n`, backed up every night at 03:23 with the component's retention (the
  newest of each of the last 7 days, 4 weeks and 3 months) and filled from the latest backup when it
  is created ([Restoring](#restoring)). It holds n8n's own files: its settings file, with the
  encryption key, the binary data of executions that n8n keeps on disk and its event log; and, in
  its directory `files`, mounted at `/home/node/.n8n-files`, the files workflows write and read
  with the Read/Write Files nodes, the one directory `N8N_RESTRICT_FILE_ACCESS_TO` lets them use.
  It holds no workflow, credential, user or execution record: those are rows of the database. So
  restoring the volume brings back files and none of the work, and restoring the database brings
  back the work and not the files that executions refer to. Steps to restore the claim are in
  [the runbook](runbooks/volume-backups.md#restoring-a-claim-from-its-repository); the database is
  restored to a point in time from its archive, or from its daily dump, which is up to a day old
  ([Backups and restores](#backups-and-restores), [Dumps](#dumps),
  [the runbook](runbooks/postgres-restore.md)).
- **The hostname** is `n8n.${CLUSTER_DOMAIN}`, an `HTTPRoute` on the public Gateway's `https`
  listener to the Service `n8n` on 5678. `N8N_HOST`, `N8N_PROTOCOL`, `N8N_EDITOR_BASE_URL` and
  `N8N_WEBHOOK_URL` are that name over https, set from the variable, and `N8N_PROXY_HOPS` is 1: the
  Gateway's proxy adds the forwarding headers, and the edge routers in front of it translate the
  source address and add none ([ADR 0018](adr/0018-own-edge-routers-translate-public-traffic-to-the-gateway.md)),
  so n8n trusts one proxy. n8n sees as the client's the address the Gateway's proxy took as the
  client's ([The public Gateway](#the-public-gateway)). The route's `Probe` asks for `/healthz`
  through the Gateway from inside the cluster ([Probes](#probes)).
- **The task runners.** Code nodes run in n8n's external mode, as n8n's documentation recommends:
  the container `runners`, from n8n's runners image of n8n's own version, which
  `tests/applications.bats` holds, runs the launcher that starts a JavaScript or Python runner when
  a task comes. n8n's task broker listens on the pod's loopback, `127.0.0.1:5679`, which the two
  containers share, so nothing outside the pod reaches it and the Service names only 5678; n8n's
  documentation gives `0.0.0.0` for runners in another container, which here would open the broker
  to the pod network for nothing. Both containers read the token the runners authenticate with
  from the Secret `n8n-runners`, which External Secrets makes once with its `Password` generator
  (`runners-token.yaml`): it is read only through the cluster's API and nothing keeps it, so a new
  one costs a restart of the pod.
- **Hardening.** The pod runs as user and group 1000, `node` in n8n's image and `runner` in the
  runners', with the runtime's seccomp profile; both containers have a read-only root filesystem,
  no capability and no privilege escalation. n8n writes to the claim, at `/home/node/.n8n` and
  `/home/node/.n8n-files`, and to an `emptyDir` each at `/home/node/.cache`, where it writes the
  editor's pages at every start and stops when it cannot, and `/tmp`; the runners write only to a
  `/tmp` of their own, where Python's runner keeps the socket of its process server, so code a
  runner runs cannot read n8n's temporary files. That is every path the pinned n8n writes with
  this configuration: the image, run read-only with those mounts alone, starts, serves the editor
  and runs a JavaScript and a Python Code node through the runners. n8n requests 100m of CPU and
  512Mi of memory and is limited to 1Gi; the runners request 50m and 128Mi and are limited to
  512Mi. n8n's startup, liveness and readiness probes ask `/healthz`, `/healthz` and
  `/healthz/readiness`, which answers once the database does; the runners' liveness probe asks the
  launcher's `/healthz` on 5680, and they have no readiness probe, as a runner that is down fails
  the code given to it, not the editor.
- **Nothing calls n8n's services.** Off, each by its variable: telemetry and the product analytics
  of the editor (`N8N_DIAGNOSTICS_ENABLED`), the check for new versions and their notes
  (`N8N_VERSION_NOTIFICATIONS_ENABLED`), workflow templates (`N8N_TEMPLATES_ENABLED`), the banners
  the editor fetches from n8n's API (`N8N_DYNAMIC_BANNERS_ENABLED`), community packages and the list
  of verified ones (`N8N_COMMUNITY_PACKAGES_ENABLED`, `N8N_VERIFIED_PACKAGES_ENABLED`), and the MCP
  server registry, a module that refreshes its list from n8n's API at start and every eight hours,
  unloaded by `N8N_DISABLED_MODULES` as n8n's documentation unloads a module. Also off are the
  public API, the questions n8n asks a new user and the banner it prints at start. What still can
  call n8n's services needs a person to act first: n8n's licence server is called only once someone
  activates a licence in the settings, and then renews it there with usage figures; the enterprise
  trial and the free registration forms in the settings send what is typed in them; and the AI
  assistant and n8n's AI credits work only under a licence that includes them.
- **Updates.** Renovate proposes n8n's and the runners' images together, and only patches of the
  minor the tree runs (`.renovate/managers.json5`): Docker Hub tags n8n's betas and its next major
  as plain versions, which only n8n's GitHub releases mark as pre-releases, and Renovate moves an
  image's digest only from its registry. When such a pull request opens, a person checks on n8n's
  releases page that its version is not marked as a pre-release, as n8n has marked a few patches of
  a minor already stable; n8n never merges itself. A newer minor is moved by hand once n8n releases it as
  stable: both images' tags and digests in one change.
- **One replica**, with the strategy `Recreate`. n8n's main process is single unless it runs in
  queue mode, with Redis and workers, which this application does not; and the volume is
  ReadWriteOnce, which a rolling update's second pod could not mount. There is no
  PodDisruptionBudget: one that keeps the only pod available would make every drain wait for ever,
  and one that lets it be evicted does nothing. A drain evicts the pod, which starts again on
  another node once the volume follows.

**The first visit.** n8n lets whoever opens it first create the owner account, and no owner
credential is in the tree. The control is the edge: the edge routers admit only the operator
allowlist on the public ports until `public_allowed_cidrs` widens it
([The edge routers](infrastructure.md#the-edge-routers)). So the step right after the first rollout
is to open `https://n8n.<domain>` from an allowed network and create the owner, before the allowlist
is widened. A cluster whose allowlist is open must not enable the application until someone is ready
to do it. external-dns publishes `n8n.<domain>` at both edge routers within a minute or two of the
route being accepted ([DNS records](#dns-records)), and `just gateway-check` says when the name
resolves to them; until it does, a browser reaches n8n only where the operator's machine resolves
the name to an edge router's public address, which the edge stack's outputs give.
When the certificate comes from Let's Encrypt's production issuer, as lab-sto2's does, the browser
does not warn about it; with the cluster's own authority or the staging issuer it would, unless it
were given the root of that chain ([What a client outside sees](#the-public-gateway)).

### Open WebUI

Open WebUI, a chat interface for language-model APIs, runs in `ai-system`
(`apps/base/ai-system/open-webui/`), selected by one entry of the overlay, its `ks.yaml`: the
namespace directory is n8n's entry. The namespace holds no default deny, and
`network-policy-exceptions.yaml` lists Open WebUI's flows beside n8n's; the public Gateway's
proxies reach its pods on 8080 alone ([Network policy](#network-policy)). Its `ks.yaml` names
External Secrets, the store's application, VolSync, LINSTOR, the public Gateway and the blackbox
exporter, which answers its route's `Probe`, in `dependsOn`, and sets `wait` with the long timeout,
so a cluster that lacks one of them is refused by `just kubernetes-check` and the application is
Ready once Open WebUI answers its readiness endpoint on the restored volume. It has no database
cluster and no secret of its own, so it names neither the operator nor the Prometheus Operator
definitions, whose `Probe` kind the exporter waits for.

- **The chart** is app-template at the tag n8n's is, its `OCIRepository` named after the
  application, with the image `ghcr.io/open-webui/open-webui` pinned by tag and digest in
  `values.yaml`. The image is the slim build, `0.11.4-slim`. The standard image bakes an embedding
  model, a speech model and a tokenizer into `/app/backend/data/cache`, the directory the volume is
  mounted over, so they would be hidden and fetched again at first use; the slim image has none.
- **The state** is the volume alone. The claim `open-webui` of `components/volsync` is 5Gi on the
  default StorageClass, mounted at `/app/backend/data` (`DATA_DIR`), backed up every night at 03:37
  with the component's retention (the newest of each of the last 7 days, 4 weeks and 3 months) and
  filled from the latest backup when it is created ([Restoring](#restoring)). It holds Open WebUI's
  database, `webui.db`, a SQLite file, so the application has no PostgreSQL: its accounts, chats,
  settings and connections are rows of that file. It holds the files people attach in `uploads`, the
  caches Open WebUI makes in `cache`, and the file `.webui_secret_key`. Restoring the volume brings
  all of it back at once.
- **The secrets.** Nothing is seeded: no ExternalSecret of the application's own exists, so the pod
  never waits for a store entry. The only ExternalSecret in the application is the volume's backup
  credentials, which every volume of the component has ([Volume backups](#volume-backups)).
  - The key that signs sessions, `WEBUI_SECRET_KEY`, is not given. When it is unset, Open WebUI
    generates one at its first start into the file named by `WEBUI_SECRET_KEY_FILE`, which is
    `/app/backend/data/.webui_secret_key` on the claim (the file's default is in the image, which is
    read-only), and reads it from there at every start. It is on the volume and in every backup of it,
    encrypted with the repository's password, and nowhere in the store, etcd or Git. A volume restored
    from a backup brings the key with it, so sessions survive; a volume made empty gets a new key, and
    everyone signs in again.
  - The model backend, an OpenAI-compatible URL and key, is entered by an administrator in the
    interface (Admin Settings, Connections) and kept in `webui.db`. The key is therefore in the
    volume's backups, in the repository the backups go to, encrypted as the rest of the volume is, and
    is read by whoever can read the volume or restore it; give the connection a key that can be
    revoked, scoped to what Open WebUI needs.
- **The hostname** is `open-webui.${CLUSTER_DOMAIN}`, an `HTTPRoute` on the public Gateway's `https`
  listener to the Service `open-webui` on 8080. `CORS_ALLOW_ORIGIN`, the one origin Open WebUI
  allows, and `WEBUI_URL` are that name over https, and `WEBUI_AUTH_COOKIE_SECURE` makes the session
  cookie for https alone. `WEBUI_URL` is kept in Open WebUI's database after the first start, so a
  volume restored under another domain keeps the old one until an administrator changes it in the
  settings; `CORS_ALLOW_ORIGIN` is read at every start. Open WebUI's
  server trusts `X-Forwarded-For` from any peer, as the image starts it (`FORWARDED_ALLOW_IPS`
  defaults to `*`), and the variable is left alone: the sign-in rate limit is keyed by the account's
  email and not by the address, and the client's address reaches only the audit log and the
  token-exchange limit, so a forged one gains little. The route's `Probe` asks for `/health/db`
  through the Gateway from inside the cluster, which Open WebUI answers 200 without a session once
  its database does ([Probes](#probes)).
- **Hardening.** The pod runs as user and group 1000, though the image runs as root unless told
  otherwise, with the runtime's seccomp profile; the one container has a read-only root filesystem,
  no capability and no privilege escalation. It writes to the claim at `/app/backend/data`, to an
  `emptyDir` at `/app/backend/open_webui/static`, where Open WebUI copies the logos and style sheet
  from its build at every start and serves them, logging an error for each file where it cannot, and
  to an `emptyDir` at `/tmp`, which `HOME` names. That is every path the pinned image writes with
  this configuration: it was run read-only with those mounts alone, with no capability and no
  network, signed in to, sent a file and asked for the page, its configuration, its models and its
  settings, and logged no error and no failed write, only one warning, from a database migration the
  first start applies. It requests 100m of CPU and 384Mi of memory and is limited to 1Gi: the
  highest a run reached was about 320Mi, after the first account, a sign-in and a file upload, and
  it was idle at 0.3% of a CPU. The startup, liveness and readiness probes ask `/health`, `/health`
  and `/health/db`, which answers once the database does.
- **Nothing calls Open WebUI's publisher or a model provider.** Nothing needs to: the image was run
  with no network and served its page, and a probe in the process that logs every name lookup and
  connection to an address outside the pod's own saw none through the start, the first account, a
  sign-in, those requests and a file attachment. The probe was first shown to catch a call: with the
  OpenAI connection turned on, it logged the lookup of OpenAI's API. In this image that needs
  `uvloop` and `aiodns` kept from loading, as they look names up and connect in C, where a probe of
  Python's own calls does not see them. Each call Open WebUI can make unasked, and its state:

  | Call | Variable | State |
  | --- | --- | --- |
  | Ollama's API, whose default address Open WebUI looks up at every start | `ENABLE_OLLAMA_API`, `OLLAMA_BASE_URL` | off; the address is the pod's own loopback, where nothing listens |
  | The OpenAI API, at OpenAI's own public address, which Open WebUI gives the connection when no variable names one and asks for models, with an empty key, as soon as the connection is on | `ENABLE_OPENAI_API`, `OPENAI_API_BASE_URL` | off; the address is left at that default, which nothing contacts while the connection is off, and no variable gives a key: an administrator replaces the address and adds the key before turning it on |
  | The latest release, from GitHub's API | `ENABLE_VERSION_UPDATE_CHECK` | off |
  | Hugging Face, for the embedding, reranking and speech models, and the installs a function or tool asks for | `OFFLINE_MODE` | on, which also stops the update check |
  | The vector store's anonymous usage statistics, which the slim image cannot send: it does not install the store's package | `ANONYMIZED_TELEMETRY` | off, in case a later image installs it |
  | The package analytics a dependency reports, which the slim image cannot send: it does not install the packages that report | `SCARF_NO_ANALYTICS`, `DO_NOT_TRACK` | `true`, which turns them off, as the image's own environment already does |
  | Sharing chats to the community site | `ENABLE_COMMUNITY_SHARING` | off |
  | The browser fetching Python packages from a content delivery network to run code | `ENABLE_CODE_EXECUTION`, `ENABLE_CODE_INTERPRETER` | off |
  | Embedding and retrieval, which would need an embedding model and a vector store | `BYPASS_EMBEDDING_AND_RETRIEVAL` | `true`; see below |

  What a person loses: running code in the chat, and knowledge bases. The slim image has no embedding
  model and its only vector store is PostgreSQL with pgvector, which this application does not have,
  so a file attached to a chat is read and handed to the model whole, and a long one can exceed the
  model's context. What still can call out needs a person to act first: an administrator who turns
  the OpenAI connection on, and then every chat goes to the address it holds; one who turns on web
  search, image generation or speech with an external provider, or a login provider; a person who
  picks the in-browser speech synthesis, whose runtime the browser fetches from a content delivery
  network; and a document splitter by tokens, which fetches its encoding from a
  public file store when first used. Which variables take effect when:

  - Fixed by the volume's first start, kept in its database from then on, so that changing the
    variable later changes nothing on a volume that has started and the setting is changed in the
    interface instead: the two connections (`ENABLE_OLLAMA_API`, `ENABLE_OPENAI_API`), the Ollama
    address (`OLLAMA_BASE_URL`), code execution and the code interpreter, community sharing,
    retrieval bypass, sign-up (`ENABLE_SIGNUP`), the default role (`DEFAULT_USER_ROLE`) and the
    site's URL (`WEBUI_URL`).
  - Read at every start: `OFFLINE_MODE`, `ENABLE_VERSION_UPDATE_CHECK`, `ANONYMIZED_TELEMETRY`,
    `SCARF_NO_ANALYTICS`, `DO_NOT_TRACK`, `CORS_ALLOW_ORIGIN` and `WEBUI_AUTH_COOKIE_SECURE`. A change
    to one takes effect on a volume that has already started.
- **Updates.** The pin is the version the local run and the reading of the source above were made on;
  a newer release is Renovate's to propose, and the notes and the variables of this section are read
  again for it. Renovate proposes the image's tag and digest, and never merges it by itself
  (`.renovate/automerge.json5`). It is not held to patches of the running minor, as n8n's is: the
  version tags of the image are releases alone, and its builds of the development branch are under
  `dev`, `main` and `git-<commit>`, so a newer minor is a release. Open WebUI is before 1.0 and its
  minors change the database, which it migrates at start and does not migrate back, so a person reads
  the release notes before merging one, and the way back from a version that has started on the volume
  is the restore of a backup taken before it.
- **One replica**, with the strategy `Recreate`: the database is a file on a ReadWriteOnce volume
  that a second process would not share, and the sessions of the websocket are kept in memory, as no
  Redis is deployed. There is no PodDisruptionBudget, for the reason n8n's section gives. A drain
  evicts the pod, which starts again on another node once the volume follows.

**The first visit.** Open WebUI makes the first account created the administrator, and no
administrator credential is in the tree. Sign-up is off from the start (`ENABLE_SIGNUP`), which does
not stop the first account, and creating it closes sign-up in the settings, so a later person cannot
register themselves: the administrator opens sign-up again when they want it, and an account made then
waits for approval (`DEFAULT_USER_ROLE`). The control is the edge, as for n8n: the edge routers admit
only the operator allowlist on the public ports until `public_allowed_cidrs` widens it
([The edge routers](infrastructure.md#the-edge-routers)). So the step right after the first rollout is
to open `https://open-webui.<domain>` from an allowed network and create the administrator, before the
allowlist is widened; a cluster whose allowlist is open must not enable the application until someone
is ready to do it. Then, in Admin Settings, Connections, the administrator replaces the OpenAI
connection's address, OpenAI's own API until then, with the model API's URL, adds its key, and only
then turns the OpenAI API on: turned on first, Open WebUI asks OpenAI's API for models straight away,
with an empty key. The names, the certificate and the way to reach the application before DNS follow
n8n's paragraph.

**A rebuild.** The volume comes back from its latest backup once the store's recovery keys and the
backups' key are in place, as for every application
([the runbook](runbooks/volume-backups.md#the-stores-key-is-lost-and-the-file-is-kept)), with the
accounts, chats, connections and session key; there is no application secret to put back first. A
cluster with no backup starts Open WebUI empty, with an administrator to create and a connection to
enter again.

### Backstage

Backstage, the catalogue of what the cluster runs, runs in the namespace `backstage`
(`apps/base/backstage/backstage/`), which enforces the restricted Pod Security level and carries the
Gateway label. Its `ks.yaml` names the PostgreSQL operator, the Barman Cloud plugin, the Prometheus
Operator definitions, External Secrets, the store's application, the public Gateway, Cilium, whose
operator defines the kind of its network policies, and the blackbox exporter, which answers its
route's `Probe`, in `dependsOn` and sets `wait` with the long timeout, so the application is Ready
once Backstage answers its readiness endpoint with its database.

- **The image** is Backstage's published one, `ghcr.io/backstage/backstage`, pinned by tag and
  digest in `values.yaml` and tracked by Renovate, which never merges it
  (`.renovate/automerge.json5`). This repository builds no image. The image is what
  `npx @backstage/create-app` makes, built by Backstage's project, and it cannot take another
  plugin: what it holds is what runs. The plugins its backend loads include the app, which serves
  the frontend, the auth plugin with the guest sign-in provider, the catalogue, search with
  PostgreSQL, the scaffolder, TechDocs, the Kubernetes plugin, notifications, signals, user
  settings, the proxy, the MCP actions endpoint and the permission framework, which allows
  everything; its frontend was built with the guest provider as its one sign-in. That is enough for
  a catalogue from files with PostgreSQL behind the Gateway, and nothing more is asked of it. A
  catalogue that needs another sign-in, a plugin or a different theme needs an image built from
  Backstage's own application, which is a change of its own: a build and a publish in CI, and the
  pin moving to that image.
- **The chart** is app-template, as for [n8n](#n8n). Backstage's own chart is a Deployment around
  the same image with a PostgreSQL subchart that is off here, and gives less of the pod's hardening
  to values.
- **The configuration** is one file, `app-config.yaml`, generated into a ConfigMap and mounted at
  `/config`; the pod runs the image's command with `--config /config/app-config.yaml` alone, so
  neither of the image's own files, with its demo entities and a GitHub integration, is read. The
  base URLs are the only values from the cluster's domain, and the HelmRelease sets them through the
  environment variables `APP_CONFIG_app_baseUrl` and `APP_CONFIG_backend_baseUrl`.
- **The catalogue** is the files of `apps/base/backstage/backstage/app/catalogue/`, which kustomize
  generates into the ConfigMap `backstage-catalogue`, mounted read-only at `/catalogue`; the one
  location is `file: /catalogue/*.yaml`. A change to a file gives a new ConfigMap name and a new
  release. There is one entity for every application the lab-sto2 overlay selects, that is, for
  every Kustomization its `ks.yaml` entries build, named as the application is (`n8n` is the
  Component `n8n`), in a file of that name. An application that only applies configuration or
  definitions (a Gateway, issuers, monitors, a route) is a `Resource`, and one that runs workloads a
  `Component`. Each entity has a description that is true of the tree, an owner (the group
  `operators`, which stands for whoever operates the cluster), its system, links to its section of
  `docs/kubernetes.md` or `docs/cluster.md`, to its runbook where one exists and to its manifests,
  all addresses of this repository's public files, and `dependsOn` for the applications its
  Kustomization names in `dependsOn`, as the overlay builds it, patches included.
  `domain.yaml`, `systems.yaml` and `operators.yaml` hold the Domain, the ten Systems that group
  the applications and the Group. Flux's own two applications, which the cluster directory builds,
  and the artifact generator, which the overlay lists as a directory, are not applications of the
  overlay's `ks.yaml` entries and have no entity.

  `tests/backstage.bats` holds the files to the overlay: every application has exactly one entity of
  its own name and every Component and Resource names an application, every owner, system and domain
  exists, every `dependsOn` is the entities of what the Kustomization names and nothing else, every
  link is an address of this repository's public files to a file or directory that exists and, for a
  Markdown file, to a heading it has, and no other address is in the catalogue. It fails, naming
  the application, for one added to the overlay without an entity and for an entity of an
  application the overlay lacks. `just catalogue-dependencies` writes `dependsOn` of every entity
  from the Kustomizations, and fails naming both when one names an application with no entity;
  descriptions, systems and links stay as written.
- **The database** is a PostgreSQL cluster named `backstage-db` from `components/cnpg-cluster`, with
  the component's three instances, which it offers no variable to lower, and 4Gi each, the least any
  database's volume has, as it holds the WAL of an archive outage besides the data
  ([PostgreSQL](#postgresql)). Its data is small: the catalogue is the files, so the database holds
  only what Backstage derives from them (entities, relations
  and the search index), its plugins' signing keys and the guest user's sign-in record, and a lost
  database is made again by a start. Backstage reads its host, port, database, user and password
  from the keys of the Secret `backstage-db-app`, which the operator makes. The user may not create
  databases, so `backend.database.pluginDivisionMode` is `schema`: each plugin gets a schema of
  the one database. Nothing is seeded by a person. The component archives its WAL and backs the
  database up daily to the object storage ([Backups and restores](#backups-and-restores)), and dumps
  it once a day, encrypted ([Dumps](#dumps)); the `external-secrets` and `openbao-store` in
  `dependsOn` serve the S3 key and the customer key the backups read and the S3 key the dump job
  reads, which are the cluster's, seeded once for it and not for Backstage. Backstage needs no other
  secret: its plugins sign the tokens
  they exchange with keys they keep in the database, so External Secrets makes none for it, and
  `backend.auth.keys`, which would admit callers from outside, is not set.
- **The hostname** is `backstage.${CLUSTER_DOMAIN}`, an `HTTPRoute` on the public Gateway's `https`
  listener to the Service `backstage` on 7007, published and reached as
  [Giving an application a public hostname](#giving-an-application-a-public-hostname) and
  [DNS records](#dns-records) say. The route sends on only the requests a reader's pages make
  (Sign-in, below). Its `Probe` asks for the readiness endpoint, a `GET` the route admits, through
  the Gateway from inside the cluster ([Probes](#probes)).
- **Network.** The namespace denies traffic both ways by default and declares its flows beside the
  application (`ciliumnetworkpolicy.yaml`, [Network policy](#network-policy)). Backstage's pod takes
  the public Gateway's proxies and the kubelet's probes on 7007, and sends only to the cluster's
  resolver and to its database's instances on 5432: not to the API server, not to another
  application, nothing outside the cluster. The database's pods take the operator on 8000 and 5432
  and each other, Backstage and the dump job on 5432, Prometheus on 9187 and the kubelet's probes on
  8000, and send to each other, the resolver and the API server; its instances also send to the
  world on 443, for the object storage their Barman Cloud sidecars archive to, in a policy of its
  own with its reason; the dump job sends to the resolver,
  the instances on 5432 and the world on 443, for the age release and the object storage, in a
  policy of its own with its reason. The dump job's pods carry the labels
  `app.kubernetes.io/name: pgdump` and `app.kubernetes.io/instance: backstage-db`, which a patch in
  `app/kustomization.yaml` gives the component's CronJob, so that a policy can select them. This
  layer holds once the cluster enforces the policies; while it audits them, a flow they would drop
  is reported and passes.
- **Hardening.** The pod runs as user and group 1000 (`node`) with the runtime's seccomp profile and
  no service account token, as Backstage reads nothing from the Kubernetes API. The container has a
  read-only root filesystem, no capability and no privilege escalation, and **mounts nothing
  writable**: only the two ConfigMaps, read-only. The image, run so against PostgreSQL with the
  rendered configuration and catalogue, starts, serves the catalogue and answers a guest's requests,
  and its scaffolder, which needs a temporary directory to run anything, cannot run. Backstage
  requests 100m of CPU and 512Mi of memory and is limited to 1Gi, from that run (resident memory
  peaked near 530Mi at start and stayed near 500Mi). The probes ask Backstage's health endpoints
  `/.backstage/health/v1/liveness` and `/readiness`, the latter once the plugins have started.
- **One replica**, with the strategy `Recreate`. Nothing of Backstage's state is in the pod, but
  each plugin creates its schema and tables in the database as it starts, and two pods that start
  together on an empty database both stop on it (run side by side, both did). So the old pod goes
  before the new one starts, and there is no PodDisruptionBudget, as for n8n. A drain evicts the
  pod, which starts again on another node.
- **What the pod calls outside the cluster.** Nothing at run time:

  | What | State |
  | --- | --- |
  | Catalogue locations of type `url`, entity providers | none configured; the one location is a file glob |
  | Reading a file at an address a caller names | the backend holds readers for GitHub and GitLab whatever its configuration; a dry run of a location's registration, the validation of an entity and the catalogue's actions read through them, and registering a location is refused before any read, as the catalogue is read-only; the route sends none of those requests to the pod (Sign-in, below) |
  | GitHub integration and its token | none; the image's own configuration that has them is not read |
  | TechDocs | `techdocs.builder: external`: nothing is built or fetched, and no entity names documentation |
  | Scaffolder and its templates | no template is in the catalogue, the pod has no writable directory to run one in, and the route sends none of its tasks, dry runs or autocompletions |
  | Kubernetes plugin | no cluster configured: it does not start |
  | Proxy | no endpoint |
  | Analytics, update checks | the image has none |
  | The network | the pod sends only to the cluster's resolver and its database (Network, above) |

  The pinned image started and served on a network with no route out and logged no failed
  connection. A link in an entity is one a person follows in a browser, to this repository's files.
  A headless browser that opened every page of the navigation as the guest, through a stand-in for
  the route that applies its matches, asked no host but Backstage's; the home page shows no widget
  until a visitor adds one.
- **Sign-in.** The image's frontend offers the guest provider and no other, and the backend refuses
  it outside development unless `auth.providers.guest.dangerouslyAllowOutsideDevelopment` is set,
  which it is. So anyone who can reach the route signs in as the guest user: **access is the
  route's, not Backstage's**. Without signing in, a request to the backend is refused (401) unless
  it is for the health endpoints, the frontend's files, the guest sign-in's refresh or the documents
  that publish the keys its tokens are verified with: the default authentication policy stays on.
  Every visitor is the same user, `user:development/guest`.

  **The route admits by allowlist**, from the requests the pinned frontend makes as a reader opens
  its pages: `GET` and `HEAD` of any path, which serve the pages, sign the guest in
  (`GET /api/auth/guest/refresh`) and carry the pages' reads, and `POST` of
  `/api/catalog/entities/by-refs`, matched exactly, the read of entities by their references that
  the catalogue's table, the entity pages and the graph send, the one read the pages need as a
  `POST`. No other request matches, and the Gateway answers it itself, 404, without reaching the
  pod; a path that differs from the exact one in letter case or by a trailing slash matches nothing.
  So a guest changes nothing: no location is registered, validated, analysed or dry-run, no entity
  is refreshed or deleted, no scaffolder task, dry run or autocompletion starts, no action is
  invoked through the catalogue or the MCP endpoint, no notification is marked, and no setting of
  the guest user is kept. Starring an entity says "Request failed with 404 Not Found", and the
  guest's stars and settings read as unset, as the frontend takes the 404 of its settings read for
  "absent"; the pages render. Every `GET` route of the plugins the image loads reads the database or
  the pod's files, and none fetches from an address or changes the catalogue: the catalogue, search,
  TechDocs with its external builder, the scaffolder's lists, notifications, user settings and the
  auth plugin's discovery documents; the Kubernetes and proxy plugins have nothing mounted, and the
  MCP endpoint answers `GET` with 405. Signing in records the guest user's claims in the auth
  plugin's table, and the plugins keep their signing keys there, as they do whoever calls.
  `catalog.readonly: true` makes the backend refuse to register or unregister a location as well
  (403), whoever asks. `tests/backstage.bats` pins the matches and checks, as Gateway API matches a
  route, that the writes, the deletes, the validation and dry-run endpoints and the variants of the
  listed path in letter case and with a trailing slash match none of them. It pins the rule's one
  backend, the Service `backstage` on 7007, with no filter on the rule or on the backend, and fails
  on any object of Envoy Gateway's API group, `gateway.envoyproxy.io`, and on any object that names
  the route as its target, in what the application builds and its chart renders.

  The entities are the files'. Putting the cluster's sign-in in front of the route later needs no
  change to the application: a policy of an application of its own, attached to the `HTTPRoute`
  `backstage`, decides who reaches Backstage at all, and the guest provider behind it signs in
  whoever got through. Until then the edge routers' allowlist
  ([The edge routers](infrastructure.md#the-edge-routers)) is what stands between the catalogue and
  everyone else, and its content, which is what the cluster runs and where its documentation is, is
  readable by whoever is let through.
- **Updates.** Renovate proposes the image's tags and the chart's, as for every application, and
  never merges either: a rule holds every file of the application back, whatever the auto-merge
  switch says. Backstage's pre-release tags (`-next.N`) are not proposed. The image's frontend and
  backend change with its release, so a new one is looked at, not merged blind.
- **Adding an application to the catalogue.** An application added to the overlay needs its entity
  in the same change: copy the entity of a similar one to `catalogue/<application>.yaml`, name it as
  the application, write its description, system and links, list the file in
  `app/kustomization.yaml` and run `just catalogue-dependencies`. `tests/backstage.bats` fails
  until it holds.

### OpenFeature Operator

The OpenFeature Operator (`apps/base/open-feature-operator/open-feature-operator/`) serves feature
flags as Kubernetes objects and adds a flagd sidecar, at admission, to a pod that asks for one. It
runs in the namespace `open-feature-operator`, which enforces the restricted Pod Security level and
denies traffic by default, from its publisher's chart
(`oci://ghcr.io/open-feature/charts/open-feature-operator`). A cluster selects it with two entries
of its overlay, the namespace directory and the application's `ks.yaml`. Its `ks.yaml` sets `wait`
and names in `dependsOn` what its objects need to exist first: `cluster-ca`, the issuer of its two
Certificates, which waits for cert-manager; `prometheus-operator-crds`, for its PodMonitor; and
`cilium`, for its network policies. No workload opts in and the tree applies no flag set, so the
operator changes no pod. `tests/open-feature-operator.bats` holds what follows on the built
application and on the chart rendered as helm-controller renders it
(`features/open-feature-operator.feature`).

It is the one application of the tree that changes other workloads' pods at admission. What this
section says of the pinned versions is read from their sources, in the files it names. What it says
the API server does was also seen on one: a kube-apiserver of the cluster's Kubernetes version,
started offline with etcd alone, to which the rendered release was applied as Helm applies it, and
beside it the operator's and flagd's pinned images, run as the rendered Deployment and the injected
container run them. That run had no kubelet, no other controller and no cert-manager: the two
Secrets, the CA bundles and the endpoint of the webhook's Service were made by hand, so it shows
what admission does and nothing of a pod's life on a node.

- **What runs, and what it may do.** One Deployment with one pod, the manager, which holds a
  leader election lease in its own namespace, runs the controllers of its kinds and answers the two
  webhooks. Its ClusterRole, `open-feature-operator-manager-role`, lets it create, change and
  delete pods, ConfigMaps, Services and Deployments in every namespace, and Ingresses, HTTPRoutes
  and PodDisruptionBudgets too, more than it uses here: it makes such objects only for a `Flagd`
  object, for flagd-proxy and for a source of the `file` provider, and it changes a workload's
  Deployment only to restart it, when the source its pods name sets `rolloutOnChange`
  (`internal/controller/core/featureflagsource/controller.go`), which the example's does not. The
  role also lets it read every service account, and read and update one ClusterRoleBinding by its
  name, whose role reads every flag set and source and which names the manager's own account among
  its subjects: that is how the manager reads flag sets (Opting in, below). It may also ask the
  API server to review a token or an access, the rights of an authenticated metrics endpoint the
  pinned operator does not serve. Of the rights Kubernetes' documentation names as ways to
  escalate privilege ("Role Based Access Control Good Practices"), the release grants one, the
  creation of workloads: no rule names Secrets, service account tokens, persistent volumes, the
  nodes' proxy, namespaces, certificate approval, any other role or binding, or webhook
  configurations, and none grants a wildcard or binds, escalates or impersonates. Nor does any
  rule let it exec or attach into a running pod or write to a node or its status, and no role of
  the release has an aggregation rule, which would fill it at run time with rules the render does
  not list. The test fails on a chart that grants any of these, gives a role of the release an
  aggregation rule or binds a role the release does not render. That bounds what the operator's
  own code does, so it cannot change what its webhooks match; it does not bound what its account
  can reach. A right to create pods in a namespace is a right to run them as any service account
  of that namespace and to mount any of its Secrets (the same documentation, "Workload
  creation"), and the operator has it in every namespace, `flux-system` among them, whose
  controllers hold cluster-admin: its webhook skips `flux-system`, its role does not. So the
  operator's account is as strong as cluster-admin, and a compromised operator is a compromised
  cluster. It is trusted as Flux is, which is why its images are pinned by digest
  and nothing of it merges by itself (The images, below).
- **The kinds**, all of `core.openfeature.dev/v1beta1`: a `FeatureFlag` is a set of flags; a
  `FeatureFlagSource` says where a pod's sidecar gets its flags and how the sidecar is set up; a
  `Flagd` makes the operator run flagd as a Deployment with a Service of its own; an
  `InProcessConfiguration` gives a pod's containers the environment of a provider that evaluates
  flags in the application's own process, with no sidecar. The last two are served and not covered
  here: nothing in the tree is of either kind, and no test or flow is written for what they make.
- **The two webhooks.** The release registers two webhook configurations with one webhook each,
  both calling the operator's own Service in its namespace:

  | Webhook | What the API server sends it | While the operator is down or slow |
  | --- | --- | --- |
  | `mutate.openfeature.dev`, mutating | the creation and update of a pod that carries the label `openfeature.dev/enabled: "true"`, in any namespace but `kube-system`, `flux-system` and `open-feature-operator` | the pod is admitted as it is: a pod that asked starts without its sidecar |
  | `vfeatureflag.kb.io`, validating | the creation and update of a `FeatureFlag` | the flag set is admitted unvalidated |

  The label is the webhook's `objectSelector`, which the API server matches against the pod, and
  on an update against the pod as it was too, before it calls anything (Kubernetes' documentation
  of admission webhooks, "Matching requests: objectSelector"): a pod that never carries the label
  is never sent, so it cannot be refused, changed or delayed by its webhook. The chart's default
  selector is empty and matches every pod of the cluster; the values set the label. The skipped
  namespaces are a `namespaceSelector` on the name every namespace carries, which the chart has no
  value for and a post-renderer of the HelmRelease adds, as Gatekeeper's has it; nothing opts a
  namespace back in. Both webhooks fail open (`failurePolicy: Ignore`), the mutating one by the
  chart's value and the validating one by the post-renderer, as the chart registers it failing
  closed with no value to change that. Both wait 10 seconds at most (`timeoutSeconds`, the API
  server's default, written out). A failure policy covers a call that fails: no answer in time, a
  refused connection, a certificate the API server cannot verify. It does not cover an answer: a
  refusal the operator returns is a refusal (the same documentation, "Failure policy"). On the
  offline API server a pod without the label was admitted in under a tenth of a second whether
  the operator answered or hung; a pod that asked was admitted as fast, sidecar included, with the
  operator answering, and after ten seconds with the operator hung, then without a sidecar. A flag
  set took the same ten seconds.
- **When a pod that asked is refused.** The handler (`internal/webhook/pod_webhook.go` of the
  pinned operator) admits unchanged a pod that carries the label and not the annotation
  `openfeature.dev/enabled: "true"`. With the annotation it refuses a pod that has no owner, as a
  pod made by hand has none (`static or orphaned pods cannot be mutated`); a pod that names neither
  a `FeatureFlagSource` nor an `InProcessConfiguration`; a pod whose source does not exist; and a
  pod whose source names, for the `kubernetes` provider, a flag set that does not exist. These are
  answers, so the pod is refused, not started without its sidecar: the flag set and the source
  have to exist when the pod is created, and a Deployment's ReplicaSet tries again until they do.
  The handler also does not tell an update from a creation: on an update it builds the sidecar
  again and appends its environment to the pod's containers again, which the API server then
  refuses as a change of the pod's spec. So while the operator answers, the labels, annotations,
  finalizers and owner references of an injected pod cannot be changed: `kubectl label pod` fails
  with `pod updates may not change fields other than` the few a pod allows, and a finalizer cannot
  be taken off, so a pod that carries one, as a Job's pods carry the Job controller's, should not
  opt in. Deleting the pod is no update, and while the operator is down such an update passes. A
  pod that carries the label alone is updated freely.
- **Opting in.** `apps/base/demo/hello-flags/` is a workload that does, as an example no overlay
  selects: the lab-sto2 overlay lists it commented out. It holds:
  - a `FeatureFlag`, `hello-flags`, with one flag, `greeting`;
  - a `FeatureFlagSource`, `hello-flags`, whose one source is that flag set by the `kubernetes`
    provider: the sidecar reads and watches the flag set at the API server. Everything else is the
    definition's default: the sidecar's evaluation port 8013, its management port 8014 and its
    OFREP port 8016;
  - a ServiceAccount of its own, which the pod names. When the pod is admitted the operator adds
    its account to the subjects of the ClusterRoleBinding
    `open-feature-operator-flagd-kubernetes-sync`, whose ClusterRole reads every `FeatureFlag` and
    `FeatureFlagSource` of every namespace. That is how the sidecar may watch its flags, and it
    means that every opted-in workload can read every flag set of the cluster: a flag holds nothing
    secret. The namespace's default account would carry the grant to every pod of the namespace
    that names no account of its own. The pod keeps its token mounted, as the sidecar reads the API
    server with it;
  - a Deployment whose pod template carries the label `openfeature.dev/enabled: "true"`, which
    lets the API server send the pod to the webhook, the annotation of the same key, which is what
    the operator reads, and the annotation `openfeature.dev/featureflagsource: hello-flags`, which
    names the source in the pod's own namespace. Its container asks the sidecar's OFREP endpoint
    over the pod's loopback, `http://127.0.0.1:8016/ofrep/v1/evaluate/flags/greeting`, once a
    minute and prints the answer, `{"value":"hello","key":"greeting","reason":"STATIC","variant":"hello","metadata":{}}`,
    or says that the sidecar did not answer, which is what a pod admitted while the operator was
    down does for as long as it lives;
  - a `CiliumNetworkPolicy` with the two flows an opted-in pod needs under a default deny: the
    kubelet's probes of the sidecar on its management port, 8014, and the sidecar to the API
    server on 443 and 6443. The pod's containers reach the sidecar over the loopback, which no
    policy sees, and nothing else reaches the sidecar's ports.

  Its `ks.yaml` names `open-feature-operator`, whose release defines its kinds and answers the
  webhook, and `cilium` in `dependsOn`. `just kubernetes-validate` validates its flag set and
  source against the chart's definitions, as it validates every application, selected or not. It
  has no catalogue entity, as the overlay does not select it. To run it, a cluster's overlay lists
  its `ks.yaml` and the change adds its entity.
- **What the webhook adds to a pod** (`internal/common/flagdinjector/flagdinjector.go`, and the pod
  the offline API server stored): an init container named `flagd` with `restartPolicy: Always`, a
  sidecar that starts before the pod's containers and runs beside them. Its image is the pinned
  flagd by tag and digest, pulled only when the node lacks it; its arguments are `start`, the
  management port, the evaluation port, the sources as JSON and the OFREP port; it has HTTP
  liveness and readiness probes, `/healthz` and `/readyz` on the management port, requests of 200m
  of CPU and 32Mi and limits of 500m and 64Mi, the chart's `sidecarConfiguration.resources`, which
  a source's `resources` replace; and it runs as user and group 65532, the image's own, as non-root
  with the runtime's seccomp profile, a read-only root filesystem, no capability and no privilege
  escalation. So the pod still passes the restricted level, which Pod Security admission evaluates
  after the webhook: the API server admitted the example's pod, sidecar and all, into a namespace
  that enforces it. The API server's own service account plugin runs again after the webhook and
  mounts the pod's token into the sidecar. The webhook also adds five environment variables to
  every container of the pod, `FLAGD_MANAGEMENT_PORT`, `FLAGD_PORT`, `FLAGD_EVALUATOR`,
  `FLAGD_LOG_FORMAT` and `FLAGD_RESOLVER`, for a provider in the application, and the annotation
  `openfeature.dev/allowkubernetessync: "true"`, by which the operator finds the pod again when it
  starts. The pinned flagd, run as the injector runs it, with a read-only root and no network but
  a loopback, and with a file made from the example's flag set as its source in place of the API
  server, answered the example's request as above; beside the offline API server, with the
  example's account, it read the flag set there and answered with the new variant within a second
  of a change to the flag set.
- **Which providers work here.** `kubernetes` is the one the example, its flows and the runs above
  cover. `file` has the operator copy the flag set into a ConfigMap, which it mounts in the
  sidecar, so the sidecar needs no flow but the probes; nothing here has run it. `http`, `grpc`
  and the object storage providers have the sidecar fetch from a server, a flow the workload's
  policy has to declare. `flagd-proxy` does not work: the Deployment the operator makes for it in
  its own namespace sets no security context (`internal/common/flagdproxy/flagdproxy.go`), so the
  restricted level refuses its pods, no flow is declared for it, and the handler refuses a pod
  whose source names it for as long as the proxy is not ready.
- **The images** are four pins of `values.yaml`, each a tag and a digest under a comment Renovate
  reads. Three of them never appear in a pod spec of the render: they reach the operator as
  environment variables, a repository and a tag that it joins with a colon, so the image check of
  `just kubernetes-validate` does not read them, and the test reads the variables from the rendered
  Deployment instead and fails on a tag without a digest, on a variant, on `latest` and on a
  version the pinned chart does not default to.

  | Image | Value | What runs it | What moves it |
  | --- | --- | --- | --- |
  | `ghcr.io/open-feature/open-feature-operator` | `controllerManager.manager.image.tag` | the manager's pod | Renovate, in one pull request with the chart (`.renovate/groups.json5`); the test holds it to the version the chart's own values default to, which is not the chart's `appVersion` |
  | `ghcr.io/open-feature/flagd` | `sidecarConfiguration.image.tag` | every pod that opts in, as its sidecar | Renovate, with the next row, as both are one package; the test holds it to the chart's default |
  | `ghcr.io/open-feature/flagd` | `flagdConfiguration.image.tag` | the Deployment of a `Flagd` object | Renovate; the test holds it to the sidecar's and to the chart's default |
  | `ghcr.io/open-feature/flagd-proxy` | `flagdProxyConfiguration.image.tag` | the flagd-proxy Deployment, which the namespace refuses | Renovate; the test holds it to the chart's default |

  Renovate merges nothing of the application by itself: a rule holds every file under
  `apps/base/open-feature-operator/` back, whatever the auto-merge switch says
  (`.renovate/automerge.json5`), because what it pins runs at admission and inside other workloads'
  pods. The pins are at the versions the pinned chart defaults to, each the plain build and not
  the `-fips` one. A newer flagd is a person's call: Renovate proposes it once the registry lists
  it, whether or not a chart of the operator defaults to it yet, and the arguments, ports, probes
  and environment the sidecar gets are the operator's code, written against the flagd its chart
  names, not flagd's own defaults. So the test fails on a pull request that moves flagd or
  flagd-proxy past the chart's default, and on one that moves the chart while the flagd it
  defaults to moves too, until the pins follow it in the same pull request.
- **Certificates.** The chart signs two Certificates with a self-signed `Issuer` of its own and has
  no value for either. Post-renderers point both at the `ClusterIssuer` `cluster-ca`
  ([The cluster's own CA](#the-clusters-own-ca)) and remove the chart's Issuer, so the release
  holds no issuer and no Secret. `open-feature-operator-serving-cert` is the webhooks' serving
  certificate, for the name the API server calls the Service by, in the Secret
  `webhook-server-cert`, which the pod mounts where the webhook server reads it and reloads it
  from when cert-manager renews it. Both webhook configurations carry
  `cert-manager.io/inject-ca-from` naming that
  Certificate, and the CA injector writes the authority that signed it, the cluster's own, into
  each webhook's CA bundle. That bundle is the one trust between the two sides: the API server
  verifies the operator's certificate against it, and the webhook server asks the API server for no
  certificate (it is started with no client CA, `cmd/main.go`; controller-runtime's
  `pkg/webhook/server.go`), so a certificate of `cluster-ca` serves the webhooks as the chart's
  self-signed one would. `open-feature-operator-metrics-certs`, in the Secret
  `metrics-server-cert`, is mounted and never read (Metrics, below), though the pod does not start
  without it.
- **The pod.** The chart's pod runs as non-root with no capability and no privilege escalation and
  sets no seccomp profile, for which it has no value: a post-renderer adds the runtime's profile
  and a read-only root filesystem. The pod's volumes are the two certificate Secrets, mounted
  read-only, and nothing else: the manager writes nothing to its filesystem. It reads the mounted
  serving certificate, holds its state in the API server, and logs to standard error
  (`cmd/main.go`; controller-runtime's `pkg/webhook/server.go` at the version it builds against);
  beside the offline API server it ran so, read-only and with no capability, through its start,
  the validation of flag sets and the injection of pods, and changed no file. Without an API
  server it cannot start at all: run alone with no network it exits at once, naming the missing
  cluster configuration, as user 65532. The requests and limits (10m of CPU and 64Mi requested,
  500m and 128Mi at most) are the chart's own and are not measured here: the manager keeps every
  pod and every Deployment of the cluster in memory, as it indexes both (`cmd/main.go`), so what it
  uses grows with the cluster, and the figure that counts is the pod's own, once it runs. One
  replica, with no disruption budget: while its pod restarts or moves, a pod that asks is admitted
  without its sidecar and a flag set unvalidated, and nothing asks. The chart writes the replica
  count after a literal `0`, so its text is `replicas: 01`, which the release's kustomize
  post-renderer reads and writes as the number 1. A text whose digits are all 0 to 7 is read as an
  octal number, so a value of 10 would give 8 replicas and 16 give 14, while 8, 9, 18 or 19 keep
  their value; the values file says so beside the key.
- **Metrics.** The pinned operator prepares the options of an authenticated HTTPS metrics server
  and then starts its manager with the bind address alone (`cmd/main.go`), so it serves its
  metrics in plain HTTP with no authentication on the port the chart passes as
  `--metrics-bind-address`, the container port `metrics-server`, 8080; its log says
  `"secure": false`. The chart's Service `open-feature-operator-controller-manager-metrics-service`
  targets a port named `https`, which no container has, so it selects the pod and reaches nothing,
  and the metrics certificate is not read. Both stay as the chart renders them. The application's
  `PodMonitor` scrapes the container port from the pod, by the labels of the Deployment's selector.
  The test pins the flag, the absence of the flags that name a certificate or switch the secure
  server, and the Service's target, so a chart that starts to serve HTTPS with authentication
  fails it; an operator that did so behind the same flags would show as a failed scrape. There is
  no alert and no dashboard of its own.
- **Network.** The namespace holds the default deny, and the application's two policies let
  through the kubelet's probes on 8081, Prometheus on 8080, the manager's calls to the API server
  and, in a policy of its own with its reason, the API server's calls to the webhooks on 9443
  ([What the namespaces let through](#what-the-namespaces-let-through)). The operator looks no name
  up, so no rule reaches the resolver: its client takes the API server's address from the pod's
  environment (client-go's in-cluster configuration), and the schema it validates a flag set
  against is compiled into it (`internal/webhook/featureflag_webhook.go`).
- **Definitions.** The four definitions are templates of the release, not files of the chart's
  `crds` directory, so Helm would delete them with the release, and with them every flag set and
  source of the cluster. A post-renderer gives each `helm.sh/resource-policy: keep`, as the tree's
  other definitions have. The render holds them, so `just kubernetes-validate` has a schema for
  every kind of the group, with no entry in `schema-exceptions.yaml` or `operator-definitions.yaml`.
- **What is written at run time, and drift.** The root turns drift detection on for every release.
  helm-controller asks, for each object of the release, what applying it again server-side with
  conflicts forced would change, as a dry run, and then makes that change
  (`internal/action/diff.go` and `internal/reconcile/correct_cluster_drift.go` of the
  helm-controller the pinned Flux runs; `ssa/jsondiff` of `fluxcd/pkg`). Two things are written
  into the release's objects at run time:
  - the subjects of the ClusterRoleBinding, to which the operator adds a service account with an
    update of the whole object. The dry run would write the release's own two subjects back, so
    the HelmRelease lists that field under `driftDetection.ignore`. Without the entry every
    reconcile of the release would take the opted-in accounts out again;
  - each webhook's CA bundle, which the CA injector applies as a field of its own
    (`pkg/controller/cainjector/injectables.go` of the pinned cert-manager). The release's objects
    do not hold the field, so applying them again leaves it, and it needs no entry: the test fails
    on a chart that renders one.

  Both were seen on the offline API server. An upgrade of the release is not drift detection and
  does write the binding's two subjects again, as helm-controller upgrades server-side with
  conflicts forced (`internal/action/upgrade.go`), and leaves the CA bundles. The accounts come
  back when the operator next starts, when it adds the account of every pod it marked at injection
  (`BackfillPermissions`, `internal/webhook/pod_webhook.go`), or when a pod of the account is next
  admitted. That pass tries five times, a second apart, while the manager's caches start; when it
  gives up, the manager logs `podMutator backfill permissions error` (`cmd/main.go`) and turns
  ready all the same, and the accounts come back only as pods of each are admitted, so after a
  restart the manager's log says whether the pass ran. Until then a sidecar that starts is
  forbidden to read its flag set: flagd logs that and exits, and the kubelet starts it again until
  the account is back. An upgrade that changes the manager's Deployment restarts the operator by
  itself; after one that does not,
  `kubectl -n open-feature-operator rollout restart deployment open-feature-operator-controller-manager`
  puts the accounts back.
- **Removing it.** Taking the application's entry out of the overlay has Flux uninstall the
  release. Its objects leave, the webhook configurations, the roles and the binding among them,
  and the four definitions stay, with every flag set and source: the pinned Helm, run on the
  offline API server, kept exactly those four and installed over them again without complaint.
  What cert-manager and the operator made stays too: the two Secrets and the operator's lease, in
  the namespace, which the tree never prunes. Pods that were injected keep their sidecar, which
  no longer has the grant to read its flag set: at its next start it exits, as above, and new pods
  get no sidecar.
- **Checking the webhooks on a cluster.** Two server-side dry runs call both webhooks and apply
  nothing, from the repository's root:

  ```sh
  yq '.spec.flagSpec.flags.greeting.targeting = {"nonsense": ["x"]}' \
    kubernetes/apps/base/demo/hello-flags/app/featureflag.yaml |
    kubectl apply --server-side --dry-run=server --namespace demo --filename -
  yq '{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "hello-flags-dry-run"}
    * (.spec.template.metadata | pick(["labels", "annotations"])),
    "spec": (.spec.template.spec | del(.serviceAccountName))}' \
    kubernetes/apps/base/demo/hello-flags/app/deployment.yaml |
    kubectl create --dry-run=server --namespace demo --filename -
  ```

  The first is the example's flag set with a targeting rule that is none, which the validating
  webhook refuses: `admission webhook "vfeatureflag.kb.io" denied the request`. The second is a pod
  of the example's template, under the namespace's default account, which the mutating webhook
  refuses because a pod made by hand has no owner: `admission webhook "mutate.openfeature.dev"
  denied the request: static or orphaned pods cannot be mutated`. Each refusal shows that the API
  server reached the operator and trusted its certificate. A pod with an owner would not be a
  harmless dry run: the mutating webhook is registered with `sideEffects: NoneOnDryRun`, but its
  handler does not read whether a request is a dry run (`internal/webhook/pod_webhook.go`), so for
  such a pod that asks it adds the pod's account to the binding, for a `kubernetes` source, or
  makes the ConfigMap it copies the flag set into, for a `file` one
  (`internal/common/flagdinjector/flagdinjector.go`), as for a pod it admits. The pod above has no
  owner and is refused before either. An answer that ends in `(server dry run)`, after up to ten
  seconds, means the call failed and the API server admitted the object, as the failure policy
  says: the operator's pod, the two Certificates, the CA bundle in the webhook configurations and,
  once the cluster enforces its policies, `just network-drops` for the namespace say which.

**What only the live cluster shows.** None of the following is run by a check; each is read from
the pinned sources, and the list is what to look at when the application first reconciles.

- **The order kinds and their definitions arrive in.** The root applies the namespace and its
  default deny at once. The application waits for `cluster-ca`, `prometheus-operator-crds` and
  `cilium`, so cert-manager's, the Prometheus Operator's and Cilium's kinds exist before its
  PodMonitor, its policies and its HelmRelease are applied. Helm builds every object of the
  release against the API server's kinds before it creates the first (`pkg/action/install.go` of
  the pinned Helm), which is why the Certificates' kind must exist, and then applies them in the
  order of their kinds (`pkg/release/v1/util/kind_sorter.go`): the service accounts, the
  ConfigMap, the four definitions, the roles and bindings, the Services, the Deployment, the two
  webhook configurations, and last the Certificates, a kind that order does not know. Nothing in
  the release is of a kind the release defines. The example waits for the operator's application,
  so its flag set arrives after the definitions and once the webhook answers.
- **What Helm's parser and helm-controller's post-renderer make of the chart's output.**
  helm-controller gives Helm a post-renderer for every release, the release's own and then its
  labels (`internal/postrender/build.go`), so Helm first merges the chart's output into one stream
  with its own reader and reads the result again (`annotateAndMerge` and `splitAndDeannotate`,
  `pkg/action/action.go`). The chart's namespace template renders two comment lines and no object
  for this release: that reader drops it. The Deployment's `replicas: 01` passes it as written,
  and its pull secrets, an empty list on a line of its own, as `[]`; the kustomize post-renderer
  then writes the replicas as `1`. The test renders through that path of the pinned Helm with the
  pinned kustomize, and the pinned Helm installed the result on the offline API server, to which
  it applies server-side with strict field validation (`pkg/kube/client.go`). helm-controller
  builds against the Helm the tree pins and against the library of kustomize 5.8.1 (its `go.mod`),
  where the tree's checks run kustomize 5.8.3: the function that writes a build's output,
  `Resource.AsYAML` in kustomize's `api/resource/resource.go`, which goes through JSON and so
  writes `01` as `1`, is the same in both, and nothing here runs the older library.
- **The CA bundle.** The Certificates are applied last, and cert-manager then issues them from
  `cluster-ca`; a certificate from a CA issuer carries that authority as its `ca.crt`
  (`pkg/controller/certificaterequests/ca/ca.go`), which is what the CA injector reads
  (`pkg/controller/cainjector/sources.go`). Until a webhook has its bundle the API server cannot
  verify the operator's certificate, the call fails and the failure policy admits: on the offline
  API server it logged `failing open` with the certificate error, and the pod was created without
  a sidecar.
- **The pod waits for two Secrets**, the Certificates', which cert-manager makes: until both exist
  its containers are not created.
- **Who the API server's calls arrive as** is the paragraph on the local host and the API server
  in [What the namespaces let through](#what-the-namespaces-let-through): the API server, the
  local host or another node's host, which the webhook's policy names together.
- **What the manager does at start, and when it is ready.** It reads its settings from the
  environment and exits on a pull policy Kubernetes does not know, loads the cluster configuration,
  and starts, in this order, the health and metrics servers, the webhook server, its caches, and
  after winning the leader election its controllers (controller-runtime's
  `pkg/manager/internal.go`). Beside that it lists the pods it marked at injection, which waits for
  the caches, and adds their accounts to the binding. `/readyz` answers once that pass is over,
  whether it succeeded or not (`BackfillPermissions`, `internal/webhook/pod_webhook.go`), and a
  pass that failed logs `podMutator backfill permissions error`; the pod turns Ready at its next
  readiness probe, and the release with it.
- **That Pod Security admits the pod the webhook returns** is under what the webhook adds, above:
  seen on the offline API server for the example's pod, in a namespace that enforces restricted.

### Ascender

Ascender is Ctrl IQ's web interface, API and job runner for Ansible, a build of AWX: playbooks run
from the browser against hosts and repositories the owner configures there. It runs in the namespace
`ascender` (`apps/base/ascender/`), installed by Ctrl IQ's operator from its published chart and one
`AWX` resource of the tree, at its own hostname behind its own login. A cluster selects it with
three entries of its overlay: the namespace directory, `ascender-operator/ks.yaml` and
`ascender/ks.yaml`; with the namespace directory alone it builds the namespace, its defaults and its
default deny, and nothing else of Ascender. `tests/ascender.bats` holds what follows on the built
applications and the rendered chart (`features/ascender.feature`).

- **The two applications.** `ascender-operator` installs the chart `ascender-operator` 25.6.3 from
  Ctrl IQ's classic Helm repository, `https://ctrliq.github.io/ascender-operator`, with the chart's
  definitions of `awx.ansible.com` from its `crds/`, and makes the database's Secret (below). Its
  `ks.yaml` names `cilium` and `external-secrets` and waits, so it is Ready once the operator runs
  and the Secret exists. `ascender` applies the `AWX` named `ascender`, the database from
  `components/cnpg-cluster`, the route, its `Probe`, the Service `ascender-web` and the policies. It
  names `ascender-operator`, `cloudnative-pg`, `plugin-barman-cloud`, `prometheus-operator-crds`,
  `external-secrets`, `openbao-store`, `gateway-public`, `cilium` and `blackbox-exporter`, takes the
  long timeout and is Ready by a `healthCheckExprs` entry for the `AWX`: `current` is its
  `Successful` condition being `True`. The operator is operator-sdk's Ansible operator, in the
  pinned image `ansible-operator` v1.42.3-4-g6a8af31: it sets `Successful` to `False` when a run
  starts and to `True` when the run ends without a failure, and a failed run sets `Failure` to
  `True`, which stays so into the next run until that one succeeds; so the entry has no `failed` and
  no `inProgress` expression.
- **What runs.** The operator, one pod of the chart's Deployment `awx-operator-controller-manager`:
  the manager, `awx-manager`, and kube-rbac-proxy in front of its metrics. From the `AWX` it makes,
  in the same namespace: the web Deployment `ascender-web`, one pod of nginx, uwsgi and daphne under
  supervisord in the container `ascender-web`, valkey and rsyslog; the task Deployment
  `ascender-task`, one pod of the dispatcher, the callback receiver and the websocket relay in
  `ascender-task`, receptor in the control plane's execution environment, `ascender-ee`, valkey and
  rsyslog; the migration Job `ascender-migration-<version>` of each version; its own Service
  `ascender-service`, ConfigMap, Secrets, service account, Role and binding. Ascender starts a pod
  `automation-job-<id>` for every job. Valkey listens on its socket in the pod alone (`port 0`), and
  receptor too (`local-only`). The pinned image is not the tree of the tag: it holds the Python
  package `awx` 25.6.3, on Python 3.12 and Django 5.2.17, while the tag's tree holds a package
  `ascender` on newer releases of both; what this section cites of Ascender is the image's files.
- **The operator's rights, and what they make it.** The chart binds the operator's account to a Role
  of the namespace over pods, `pods/exec`, `pods/attach` and `pods/log`, Secrets, service accounts,
  ConfigMaps, Services, endpoints, persistent volume claims, events, roles and role bindings,
  Deployments, StatefulSets, DaemonSets and ReplicaSets, Jobs and CronJobs, Ingresses, OpenShift's
  routes, Traefik's TCP routes, the creation of ServiceMonitors and its own kinds; to a Role for its
  leader election; and to the ClusterRole `awx-operator-proxy-role-ascender-operator`, which creates
  TokenReviews and SubjectAccessReviews for kube-rbac-proxy. Its other ClusterRole, the metrics
  reader, is bound to nothing. It has no webhook, and it watches its own namespace alone
  (`WATCH_NAMESPACE` is the pod's). The instance's own account, `ascender`, which the web and task
  pods run as, may create, change and delete pods, attach to them, read their logs, and read, create
  and delete Secrets of the namespace by name. A right to create pods in a namespace is a right to
  run a pod as any account of it, so each account can reach every Secret there, and **whoever holds
  Ascender's admin login can, through a container group's pod spec override, run any `baseline` pod
  there, as the `ascender` account or the operator's**, with any labels and so with the flows of any
  of the namespace's policies: the login is as strong as the namespace.
- **The images**, pinned by tag and digest and moved by Renovate in one group, `Ascender`, with the
  chart (`.renovate/groups.json5`), as Ctrl IQ releases the chart, the operator and Ascender at one
  version and its installer runs them so; nothing of the two applications merges itself
  (`.renovate/automerge.json5`). The chart names its two images by tag alone and has no value for
  them, so the release's post-renderer pins `ghcr.io/ctrliq/ascender-operator` at the chart's
  appVersion and `quay.io/brancz/kube-rbac-proxy` at the chart's tag, each by the digest of its tag,
  as `images` entries whose `newTag` carries the digest. The proxy's tag is the chart's, which
  `tests/ascender.bats` holds it to, so Renovate proposes only new digests of it
  (`.renovate/managers.json5`), and the chart's pull request sets the tag a new chart names. The
  chart's Deployment names the pull secret `redhat-operators-pull-secret`, which nothing makes; the
  images are public and the kubelet pulls them without it, so the reference stays as the chart has
  it. The `AWX` names the rest, and the operator joins each repository and version with a colon:
  `ghcr.io/ctrliq/ascender` and the init container's `ghcr.io/ctrliq/ascender-ee` at the chart's
  version with their digests, the control plane's execution environment and the one execution
  environment for jobs, `Ascender EE`, the same `ascender-ee` reference, and
  `ghcr.io/valkey-io/valkey` at the newest 9.x.y-alpine, the line the operator defaults to, which
  `.renovate/managers.json5` keeps Renovate to. The init container's image is set in full, as the
  operator's default splits the control plane's reference at its colons. The execution environment
  is matched by its name, which holds no version, so a new image moves it in place
  (`awx/main/management/commands/register_default_execution_environments.py`). Each pin is extracted
  once: the versions by the custom manager under their comments, the job environment's `image:` line
  by the kubernetes manager, which also reads `spec.image`, the repository alone, as a dependency
  with no version, which its lookup skips. `spec.image` is the one line of `.image-allowlist` for
  the application, as the image check reads it without a tag. The record
  `# ascender-operator-templates: 25.6.3` beside the Service and the policies names the release
  whose templates their selectors were read from (`.renovate/by-hand.tsv`).
- **Pod Security.** The namespace enforces `baseline` and audits and warns at `restricted` at the
  cluster's minor. The one workload below `restricted` is the job pod, an entry of
  `pod-security-exceptions.yaml` created by the `AWX`: the default pod Ascender starts sets no
  security context (`get_default_pod_spec` in `awx/main/utils/execution_environments.py`), and the
  operator does not make it, so its restricted mode does not reach it. Every pod the operator makes
  asks for `restricted`: the `AWX` sets `restricted_security_context`, which gives every container
  of the web and task pods and of the migration Job no privilege escalation and no capability, and
  `security_context_settings`, which the operator combines over its own pod context: a non-root
  user, 1000, group 0, file system group 1000 and the runtime's seccomp profile. The user and file
  system group are the ones the restricted mode writes. The group is 0 because the image holds
  `/etc/passwd`, `/etc/group`, `/var/lib/awx` (uwsgi's fifo), `/var/lib/awx/rsyslog`,
  `/var/run/supervisor` and `/var/log/tower` as root's, group-writable for gid 0 alone, and at start
  the launch scripts write `/etc/passwd` and supervisord opens its socket in `/var/run/supervisor`:
  run with group 1000 the web container can do neither and stops, and with group 0 every launch
  script runs and stops only on the missing database (the pinned images, run offline with
  `--user 1000:0 --cap-drop ALL --security-opt no-new-privileges --network none`, valkey with a
  writable `/data` and socket directory); the `restricted` level puts no rule on groups. The `AWX`
  sets none of `task_privileged`, `redis_capabilities`, `development_mode`, `projects_persistence`
  and `host_aliases`, and no other field that adds to the operator's pods, such as `extra_volumes`,
  a `*_extra_volume_mounts` or `init_container_extra_commands`: `tests/ascender.bats` holds its
  fields to those the pods it evaluates model and those Pod Security does not read. No root
  filesystem is read-only: the operator has no field for it, and the launch scripts write
  `/etc/passwd`. The operator's own pod passes `restricted` as the chart renders it.
- **The database** is a PostgreSQL cluster named `ascender-db` from `components/cnpg-cluster`, with
  the component's three instances and 5Gi each: every job's events are rows of it until the system
  job Cleanup Job Details, which Ascender schedules each Sunday, removes the jobs older than its 120
  days (`awx/main/migrations/0002_squashed_v300_release.py`). A patch in `app/kustomization.yaml`
  gives the component's Cluster `bootstrap.initdb`: the database `app`, owned by `app`, with the
  password of the Secret `ascender-db-app`, so CloudNativePG makes no application Secret of its own.
  External Secrets makes that Secret once, from a `Password` generator of 32 characters hex-encoded,
  so the password holds no character the settings file the operator writes it into as a Python
  string could misread, through a `CreatedOnce` ExternalSecret: a `kubernetes.io/basic-auth` Secret
  with `username: app`, the password, `dbname: app` for the dump job, and the keys the operator's
  `database_configuration.yml` reads, `host: ascender-db-rw`, `port: "5432"`, `database: app`,
  `sslmode: require` and `type: unmanaged`. The `AWX` names it in `postgres_configuration_secret`.
  It is made in the application `ascender-operator`, which `ascender` waits for, because the
  operator reads it once at the start of a run, and without it writes
  `ascender-postgres-configuration` with `type: managed` and starts a PostgreSQL of its own.
  Ascender accepts PostgreSQL 12 and newer (`awx/__init__.py`), so the component's 18 stays, and no
  migration of it creates an extension or needs more than the database's owner. Its connections: the
  task container's memory limit, 2Gi, is what the operator writes as `SYSTEM_TASK_ABS_MEM`, so the
  dispatcher's pool is at most 2Gi over 100MiB a fork plus 7, 27 workers
  (`awx/main/dispatch/pool.py`, `get_mem_effective_capacity` in `awx/main/utils/common.py`), not the
  node's memory; with the dispatcher's own process and its listener (2), the callback receiver and
  its four workers (5), the relay (1), the two rsyslog configurers with their listeners (4), uwsgi's
  five processes (5), daphne (1), the heartbeat (1), the cache clearer with its listener (2), one
  `awx-manage` of the operator's at a time (1) and the dump job (1), that is **50 connections at
  most**, read from the image's source and not measured, against PostgreSQL's default of 100, which
  the component leaves. A rollout of a new version runs the old pods beside the new ones for a
  while, the new pool at its minimum of four, about 25 more. The component archives its WAL, backs
  the database up daily and dumps it once a day ([PostgreSQL](#postgresql)), and that database is
  all of Ascender's state: its organisations, inventories, projects, credentials, templates and job
  history.
- **Secrets.** Nothing secret is in the tree and the tree makes no Secret. The admin password and
  the secret key are the operator's own: `admin_password_secret` and `secret_key_secret` are unset,
  so it generates `ascender-admin-password` and `ascender-secret-key`, 32 letters and digits each,
  and `garbage_collect_secrets` is false, so they outlive the `AWX`. They live in those Secrets, in
  etcd and in its snapshots, and the admin password also in the API server's audit log (The first
  sign-in, below). Ascender encrypts every credential it stores, a machine's SSH key or a
  repository's token, under the secret key: a database restored onto a rebuilt cluster without the
  old `ascender-secret-key` keeps its rows and loses every such credential, which the owner enters
  again.
- **Restoring the database.** Either restore of [postgres-restore.md](runbooks/postgres-restore.md)
  makes a new cluster, `<NEW>`, beside `ascender-db`, and for Ascender its steps differ as follows.
  The patch of `app/kustomization.yaml` names the component's Cluster by the name it has when
  patches apply, `${CNPG_CLUSTER_NAME}`, so the runbook's Cluster for a point in time, added to
  `app/`, keeps its `bootstrap.recovery`, which `tests/ascender.bats` holds by building it there.
  The `AWX` cannot read the Secret CloudNativePG makes for a new cluster, `<NEW>-app`, which has
  no `database`, `sslmode` or `type`, and the operator's run fails reading `database`; nor does
  `ascender-db-app` follow the new cluster, as External Secrets writes a `CreatedOnce` Secret
  once, and an edit of its template, a new `host` among them, changes nothing in it. So the pull
  request that adds the new cluster also adds, beside `ascender-operator/app/database-secret.yaml`
  and listed in `ascender-operator/app/kustomization.yaml`, a copy of its `Password` and
  `ExternalSecret` named `<NEW>-app`, with `host: <NEW>-rw` and the operator's other keys
  as they are, `port: "5432"`, `database: app`, `username: app`, the generated `password`,
  `sslmode: require` and `type: unmanaged`, with `dbname: app` for the dump job; and the new
  cluster names it as its owner's Secret, in `bootstrap.recovery.secret.name` of the runbook's
  Cluster or, for a dump, by the same patch with `<NEW>-app` in the restore application's
  `app/kustomization.yaml`. CloudNativePG then makes no Secret of its own and sets the
  password of `app` from that one, on a recovered cluster too, as it does whenever the
  Secret changes (`reconcileUser` in `internal/management/controller/instance_controller.go`
  of CloudNativePG v1.30.1). The switch, in a pull request of its own, merges only once
  this shows that Secret: `kubectl --namespace ascender get secret <NEW>-app`. The
  operator reads a `postgres_configuration_secret` that does not exist as none, and writes
  `ascender-postgres-configuration` and starts a PostgreSQL of its own, as it does without
  the database's Secret (above), so Ascender comes up on an empty database. The switch sets
  the `AWX`'s `postgres_configuration_secret` to `<NEW>-app`, and the web and task pods
  roll with the new connection; for a point in time it also sets the patch's `secret.name`
  to `<NEW>-app` with `CNPG_CLUSTER_NAME: <NEW>`, so that the component's Cluster keeps
  that Secret. The Cluster the component adopts then has the patch's `bootstrap.initdb`
  in place of its `bootstrap.recovery`, which rests on the untested assumption step 5 of
  the runbook's point-in-time restore names, so its check holds here too: the Cluster in
  a healthy state, no instance restarted and the next Backup completed. The switch also
  renames `ascender-db` where Ascender's files write it, as the database's policies select
  no instance of `<NEW>` until then: the dump job's `app.kubernetes.io/instance` label in
  `ascender/app/kustomization.yaml`, the `cnpg.io/cluster` and `app.kubernetes.io/instance`
  selectors of the database's policies in `ascender/app/ciliumnetworkpolicy.yaml`, and the names
  `tests/ascender.bats` holds them and the `AWX` to, which fail the required check until they
  follow. Neither restore touches `ascender-secret-key`, and the restored rows need it: their
  credentials are encrypted under it, so a restore onto a rebuilt cluster needs the old Secret
  back first.
- **The first sign-in.** At `https://ascender.${CLUSTER_DOMAIN}/`, as `admin`, with the password the
  operator generated, which this prints, with `KUBECONFIG` set to the file `just cluster-kubeconfig`
  prints:

  ```sh
  kubectl --namespace ascender get secret ascender-admin-password --output jsonpath='{.data.password}' | base64 -d; echo
  ```

  `create_preload_data` is false, so the instance holds no demonstration data: no organisation,
  project, inventory or template until the owner makes them, and no credential but the managed
  `Ansible Galaxy` one that a migration creates (below). Until that first sign-in nobody but the
  holder of that Secret can use it. The operator sets that password through the API server: on its
  first run, and on any run whose check for the superuser `admin` fails, it runs
  `awx-manage update_password` in the web pod with the password on the command line
  (`roles/installer/tasks/initialize_django.yml`), and an `exec`'s command travels in the request's
  URL, which the API server's audit log on the control planes records ([Logs](#logs)). So the
  password is in that log too: change it in the interface after the first sign-in. The Secret then
  no longer holds the password, and the command above prints the old one; the operator sets it back
  only on a run whose check fails.
- **The hostname** is `ascender.${CLUSTER_DOMAIN}`, an `HTTPRoute` on the public Gateway's `https`
  listener with one rule to the Service `ascender-web` on 80, every method and path and no filter,
  published as [Giving an application a public hostname](#giving-an-application-a-public-hostname)
  says. The operator makes its own Service at run time, which no render holds, so the tree declares
  this one, with the web pods' three labels and port 80 to 8052, numbered. There is no sign-in of
  the cluster and no firewall in front: Ascender's own login is the one, and the edge routers'
  allowlist is what stands before it. The route's `Probe` asks `/api/v2/ping/`, which answers 200
  without a session once the web pod reads the database; with no trailing slash Django answers a
  redirect. That path **publishes the version, the pod names and the installation's identifier** to
  whoever can reach the route (`ApiV2PingView` in `awx/api/views/root.py`).
- **Signing in behind the Gateway.** The Gateway terminates TLS, nginx serves plain http on 8052,
  and neither Ascender's settings nor the operator's set Django's `SECURE_PROXY_SSL_HEADER`, so
  Django sees the request as http. Its CSRF check then compares the `Origin` of the login's `POST`,
  `https://ascender.<domain>`, with the request's own `http://` origin, which differs, and admits it
  only because `extra_settings` sets `CSRF_TRUSTED_ORIGINS` to the route's https origin, from the
  same substitution as the hostname; Django checks the `Referer` only for a secure request without
  an `Origin`. The session and CSRF cookies are marked secure. The interface's websockets reach
  daphne through nginx: Envoy Gateway v1.10.0 upgrades websockets on every route of HTTP/1.1 by
  default, so job output streams as it runs, with no Envoy Gateway object.
- **Probes and requests.** The operator's probes are off by default, so the `AWX` turns on the web's
  readiness probe on `/api/v2/ping/` and the liveness probes of web and task, which run
  `supervisorctl status` and fail while any program is not `RUNNING`. A program is `RUNNING` 30
  seconds after it starts (`startsecs` in the image's supervisord files), so the liveness probes
  begin after 60 seconds. The requests of every container are written out in the `AWX`; they are the
  operator's defaults and are not measured here, and the task container alone has a limit, of
  memory, for the connections above. One web and one task replica.
- **Network.** The namespace denies traffic both ways by default and declares its flows beside each
  application ([Network policy](#network-policy)). The operator takes the kubelet's probes on 6789
  and reaches the API server alone: its tasks reach it through the operator's proxy on the pod's
  loopback and look no name up, and none fetches anything. The web pods take the proxies, the
  kubelet's readiness probe and the task pods' relay on 8052 (`awx/main/wsrelay.py`). Every pod of
  the instance, the migration Job's included, reaches the resolver and the database's instances on
  5432. The task pods also reach the web pods on 8052 and the API server, where receptor starts each
  job's pod and streams it through `pods/attach` and `pods/log`, and the world on 443 and on 22,
  each in a policy of its own with its reason: project updates and system jobs are of the control
  plane's capacity (`get_capacity_type` in `awx/main/utils/common.py`) and run in the task pod's
  execution environment (`work_type` in `awx/main/tasks/receptor.py`), where a project update clones
  its repository and installs the roles and collections it names. **The job pods reach the cluster's
  resolver and the world on 443 and on 22 and nothing else**, each world port in a policy of its own
  with its reason, and take nothing: they mount no service account token, reach no pod of the
  cluster, not the API server, the database or Ascender's own pods, and receptor attaches to them
  through the API server. The database, its instances and the dump job let through what Backstage's
  do, for `ascender-db`, the instances taking every pod of Ascender's instance and the dump job on
  5432. The policies select the job pods by the label `ansible_job` and Ascender's pods by their
  operator's labels; a pod a container group's override starts carries whatever labels it names, so
  the labels are no proof of what a pod is, as for the movers of `demo`.
- **Monitoring.** No monitor scrapes Ascender or its operator: Ascender's metrics need a session or
  a token (`ALLOW_METRICS_FOR_ANONYMOUS_USERS` is false in `awx/settings/defaults.py`), and the
  operator's are behind kube-rbac-proxy. The component's PodMonitor of the database is the
  application's one monitor, and the CloudNativePG dashboard describes its cluster
  ([Dashboards](#dashboards)). The route's `Probe` feeds `PublicEndpointDown` and
  `PublicEndpointWrongStatus`.
- **What Ascender calls outside the cluster**, read from the image's settings; no offline run of it
  was made:

  | What | Setting | State |
  | --- | --- | --- |
  | Automation Analytics, which uploads data to Red Hat | `INSIGHTS_TRACKING_STATE`, `REDHAT_USERNAME`, `AUTOMATION_ANALYTICS_URL` | off: the tracking state is false and the account empty, so the gathering stops before it collects |
  | Pendo, the interface's usage tracking | `PENDO_TRACKING_STATE` | `off` |
  | A log aggregator | `LOG_AGGREGATOR_ENABLED` | false |
  | Ansible Galaxy, for the roles and collections a project's requirements name | `AWX_ROLES_ENABLED`, `AWX_COLLECTIONS_ENABLED`, the managed credential `Ansible Galaxy` at `https://galaxy.ansible.com/` a migration creates | on for a project update whose organisation has a Galaxy credential, from the task pod on 443 |
  | A project's repository | the project's URL | on once a project names one, from the task pod on 443 or 22 |
  | The hosts and APIs a playbook manages | the owner's inventories and credentials | on for every job, from the job pod on 22 or 443 |
  | Notifications by mail, chat or webhook | a notification template | none is configured |

  The execution environment's image is pulled by the kubelet, not by Ascender.
- **Updates.** Renovate proposes the chart, the operator's image and Ascender's two images in one
  pull request and never merges it. `auto_upgrade` keeps the operator's default, true: on a new
  version the operator rolls the Deployments and runs the migration Job, which changes the
  database's schema, so a new version is read before it is merged, and what takes it back is a
  restore of the database, under the same `ascender-secret-key` (Restoring the database, above).
  After a merge, watch the `AWX`'s conditions, not the Kustomization's Ready: the operator writes no
  `status.observedGeneration`, the one field by which Flux's health check tells a status older than
  its object (`runtime/cel/status_evaluator.go` of `fluxcd/pkg`), and it sets `Successful` to
  `False` only when its run starts, so until then `ascender` can be Ready on the last run's
  `Successful`. The run has started once `Running` is `True` with the reason `Running`; it has
  succeeded once `Successful` is `True` again, and failed once `Failure` is `True`, with the failed
  tasks in its message:
  `kubectl --namespace ascender get awx ascender --output jsonpath='{.status.conditions}'`.
- **When the operator's run stalls.** On the first start a `Failure` is expected: the operator's
  first run begins when the `AWX` is applied, with the Cluster, and while the database's instances
  come up its check for pending migrations counts none, as `awx-manage showmigrations` fails without
  printing (`roles/installer/tasks/migrate_schema.yml`), so it starts no migration Job and fails
  where it makes the admin user; a later run, once the primary answers, starts the Job. Read the
  `AWX`'s `Failure` condition and the log of the container `awx-manager` first. The operator runs
  again when the `AWX` or an object it made changes, as operator-sdk's Ansible operator watches the
  objects it makes by default, and after a failed run, which it returns as an error and
  controller-runtime retries with a growing delay (`internal/ansible/controller/reconcile.go` and
  `internal/ansible/watches/watches.go` of `ansible-operator-plugins` at v1.42.3); it runs on no
  period, as its reconcile period is `0s` (its `Dockerfile`). A restart of the Deployment
  `awx-operator-controller-manager` starts a run at once, the one live change that retries without a
  commit and without that delay. While the operator is down, Ascender runs as it was, and nothing it
  would make or change is made.
- **Removal.** Taking the three entries out of the overlay prunes the `AWX`, and with it, through
  their owner references, the Deployments, the migration Job, the operator's Service, ConfigMap,
  role and the Secrets it does not keep; the Cluster and its volumes; the release and its
  Deployment. The backups stay in the object storage. What stays in the cluster: the namespace,
  whose prune is disabled; the chart's definitions, which Helm installed from `crds/` and leaves;
  and the Secrets whose owner references the operator removes on every run, as
  `garbage_collect_secrets` is false (`roles/installer/tasks/cleanup.yml`):
  `ascender-admin-password`, `ascender-secret-key`, `ascender-broadcast-websocket`,
  `ascender-receptor-ca`, `ascender-receptor-work-signing` and the database's `ascender-db-app`,
  which External Secrets then no longer deletes with its ExternalSecret.
  `kubectl --namespace ascender get secrets` lists them.

### Locust

Locust (`apps/base/locust/locust/`) puts load on a target inside the cluster and shows what it
measures: a master, which serves the web interface and hands out the work, and workers, which run
the simulated users. It runs in the namespace `locust`, which enforces the restricted Pod Security
level and denies traffic by default, from its publisher's image `docker.io/locustio/locust`, by
plain manifests with kustomize: the chart `stable/locust` of `github.com/deliveryhero/helm-charts`
is at 0.35.0 with the `appVersion` 2.32.2, older than the release the tree runs. A cluster selects
it with two entries of its overlay, the namespace directory and the application's `ks.yaml`. Its
`ks.yaml` names `cilium` alone in `dependsOn`, for its policies' kind, as Locust starts without its
target; sets `wait`; and sets one variable of its own, `LOCUST_TARGET`, the target (below).
`tests/locust.bats` holds what follows on the application built as Flux applies it and on the render
(`features/locust.feature`). What this section says of Locust 2.47.0 is read from its source at that
tag (`github.com/locustio/locust`) and from its wheel on PyPI, in the files it names, and was seen
in a run of the pinned image offline (Resources, below).

- **What runs.**
  - The master, the Deployment `locust-master`: one replica, replaced by the strategy `Recreate`, as
    two masters would split the workers between them. It runs `locust --master` with the tree's
    locustfile, the target as its host, the web interface on 8089 (`--web-port`) and the port the
    workers connect to on 5557 (`--master-bind-port`), and both are ports of the Service
    `locust-master`. It runs no users itself (`docs/running-distributed.rst`) and opens no
    connection: the workers connect to it. Its readiness probe asks for the interface's page, `/`,
    which asks for no sign-in (`locust/web.py`).
  - The workers, the Deployment `locust-worker`: two replicas, each `locust --worker` with the
    locustfile and the master's Service and port, `--master-host=locust-master` and
    `--master-port=5557`. Each opens one connection to the master, a ZeroMQ socket of its own to the
    master's one (`locust/rpc/zmqrpc.py`), and keeps it; over it the master hands each worker the
    users to run with every test it starts, and the host to run them against
    (`locust/runners.py`), and the worker sends its statistics back. A worker listens on nothing, so
    it has no port and no probe, and is given no host of its own.
  - The locustfile, `app/locustfile.py`: one `HttpUser` that asks for `/` and then waits one to
    three seconds. kustomize generates it into the ConfigMap `locust-locustfile` under a name that
    carries the hash of its content, with Flux's substitution off, and both pods mount it read-only
    at `/mnt/locust`.
  - Every option is an argument. No container sets a `LOCUST_*` variable or `--config`, and nothing
    is mounted at the image's working directory, `/home/locust`, where Locust reads `locust.conf`,
    `pyproject.toml` and `~/.locust.conf` (`DEFAULT_CONFIG_FILES` in `locust/argument_parser.py`).
    Both pods set `enableServiceLinks: false`: Locust reads each option from a variable as well,
    `LOCUST_` and its name, and the kubelet hands a pod variables named after every Service of its
    namespace (`getServiceEnvVarMap` in `pkg/kubelet/kubelet_pods.go` of Kubernetes v1.37.1). A
    Service named `locust-web` would give `LOCUST_WEB_PORT=tcp://<address>:<port>`; the pinned
    image, given that variable, stops at start with `argument --web-port/-P: invalid int value`,
    `--web-port` on its command line or not.
- **No test starts by itself.** No container's command or arguments start or shape a test: no
  `--autostart`, `--headless`, `--autoquit`, `-u` or `--users`, `-r` or `--spawn-rate`, `-t` or
  `--run-time`, `--processes`, `--config-users`, `--otel` or `--web-login`, in any spelling Locust's
  parser takes, an unambiguous abbreviation of a long option among them; and no `LOCUST_*` variable,
  through which the same options would arrive. The keys a person can press to add or remove users
  work only on a terminal, which a pod's standard input is not (`locust/input_events.py`). The
  master waits, with no users, until a request to `/swarm` starts a test: offline, five seconds
  after both workers had connected, it reported the state `ready`, no user and no request, and the
  stand-in target had logged none.
- **Opening it.** `just locust [cluster]` forwards a local port, `LOCUST_PORT` or 8089, on 127.0.0.1
  only, to port 8089 of the Service `locust-master`, through the cluster's kubeconfig, until Ctrl-C,
  as `just grafana` does ([cluster.md](cluster.md#recipes)); then open `http://127.0.0.1:8089`.
  **The interface has no sign-in.** Its login page, `--web-login`, is a hook the locustfile fills
  with a check of its own, and Locust ships none (`docs/extending-locust.rst`, Adding Authentication
  to the Web UI), so it is not used. Every route answers whoever reaches it, and answers the
  requests of any web page, as the interface allows cross-origin requests from every origin
  (`CORS(app)` in `locust/web.py`): while the forward runs, anything on the machine that runs it, a
  page open in its browser among them, can start, change and stop a test. Whoever reaches it may
  also give any host, in the interface's form or in the `host` field of `/swarm`, and the workers
  put the load on it. Locust bounds neither who reaches it nor where the load goes; the policies do
  (Network, below): the workers' egress keeps the load inside the cluster, and the master's ingress
  keeps every pod but those of its node's host network from the interface. This holds once the
  cluster enforces the policies; while it audits them, a flow they would drop is reported and
  passes ([Service addresses](#service-addresses)). **While the cluster audits, nothing bounds
  either:** a host given to the interface is reached wherever it is, outside the cluster included,
  and every pod of the cluster reaches the master's 8089 and 5557, through the Service
  `locust-master` or the pod's own address, and can start a test as the forward can. Nothing routes
  to the interface and nothing announces it: no `HTTPRoute`, no Gateway label on the namespace, and
  a Service of the cluster alone. The forward needs, in `locust`, get on `services`, get and list
  on `pods`, as kubectl finds a pod the Service selects (and watch, when none runs yet), and create
  on `pods/portforward` (`portforward.go` and `polymorphichelpers/helpers.go` of kubectl at
  Kubernetes v1.37.1).
- **Running a test.** In the interface: the number of users, the rate they are started at (ramp up)
  and the host, which shows the target, and, among the advanced options, a run time; then Start, the
  charts and the statistics, and Stop. Through its HTTP API, on the forwarded port:

  ```sh
  curl -s http://127.0.0.1:8089/worker-count
  curl -s -X POST -d user_count=4 -d spawn_rate=2 -d run_time=60s http://127.0.0.1:8089/swarm
  curl -s http://127.0.0.1:8089/stats/requests | jq '{state, user_count, worker_count, total_rps, fail_ratio}'
  curl -s -X POST http://127.0.0.1:8089/stop
  ```

  `/worker-count` answers `{"worker_count": 2}` once both workers have connected. `/swarm` answers
  `"success": true` with `"message": "Swarming started"`, the host and the run time, and `"success":
  false` with the reason for a form without a whole `user_count` and a positive `spawn_rate`.
  `/stats/requests` holds the state (`ready`, `spawning`, `running`, `stopping`, `stopped`), the
  users, the workers, the requests a second since the test started and the share of them that
  failed, with a row for each request name. `/stop` answers `{"success": true, "message": "Test
  stopped"}` (the routes of `locust/web.py`). A test without a run time runs until it is stopped.
  Its numbers are in the master's memory alone: nothing scrapes them (Monitoring, below), and they
  leave with the master's pod.
- **Changing the load.** The locustfile is a file of the tree: change `app/locustfile.py` in a pull
  request. kustomize gives the new content a new ConfigMap name, both Deployments change with it,
  and every pod of Locust restarts on it. `tests/locust.bats` reads the file's text and requires one
  import line, `from locust import HttpUser, between, task`, a string starting with `/` as the first
  argument of every call spelled `self.client.<method>(`, and no assignment to a `host`, so that
  `LOCUST_TARGET` stays the one place the target is written. A check of the text does not bound
  where the requests go: the workers' egress does, once the cluster enforces the policies (Network,
  below).
- **Changing the target.** The target is `LOCUST_TARGET` in `ks.yaml`,
  `http://hello.demo.svc.cluster.local:80`: a Service of the cluster by its name, its namespace, the
  cluster's DNS domain (`talos/patches/all/cluster-network.yaml`) and its port. It is named
  `LOCUST_TARGET`, so that it is never taken for `LOCUST_HOST`, the variable Locust reads its host
  from. Another target is three edits in one pull request: the variable; the workers' egress rule to
  the target in `app/ciliumnetworkpolicy.yaml`, naming its namespace, the labels its Service selects
  and the container port its port targets, as a Service's address is translated to a pod's before
  policy applies; and an allow beside the target's application, from the workers' labels in `locust`
  on that port, as `hello`'s policy has. A target must admit the workers, and nothing here may be
  pointed outside the cluster. `tests/locust.bats` reads the target from the master's `--host` in
  the render, requires that form, finds the Service in the render, resolves its port to the
  container port through the named port of the pods it selects, 8080 for `hello`, and fails unless
  the workers' one rule to that namespace names exactly its labels and that port and the target's
  own policy admits the workers there and no other pod of `locust`.
- **Network.** The namespace holds the default deny, and the application's two policies let through,
  to the master, the workers on 5557 and the node it runs on on 8089, for the kubelet's probe, and
  from the workers, the cluster's resolver on 53, the master on 5557 and `hello`'s pods on 8080.
  The master sends nothing and the workers take nothing; `hello`'s own policy admits the workers,
  by their labels, on 8080 ([What the namespaces let through](#what-the-namespaces-let-through)).
  This holds once the cluster enforces the policies; while it audits them, a flow they would drop
  is reported and passes ([Service addresses](#service-addresses)), as Opening it, above, says.
  Once they are enforced, the workers' egress bounds where the load can go, not that it goes to the
  target: a host that names the cluster's resolver on 53 or the master on 5557, both of which the
  workers reach, puts the load there, and a test aimed at the resolver can slow the name lookups of
  every application of the cluster. The interface takes nothing but the node the master runs on:
  `host` is every process in that node's network namespace, the kubelet and the pods of the host's
  network there among them, and the agent lets the local host reach the pods of its node on every
  port whatever the policies say (the local host, in
  [What the namespaces let through](#what-the-namespaces-let-through)); the rule from `host` states
  the probe's port. The master looks up one name, its own: the web server it runs, gevent's
  `WSGIServer`, asks for the fully qualified name of the address it binds as it starts
  (`update_environ` in `gevent/pywsgi.py` of gevent 26.9.0, the release in the image), and the
  kubelet writes the pod's name with its address into the pod's `/etc/hosts`
  (`managedHostsFileContent` in `pkg/kubelet/kubelet_pods.go`), which the image reads before it
  asks a resolver (`hosts: files dns`). `just locust` reaches the interface through a port forward,
  which the container runtime connects inside the pod (What only the live cluster shows, below).
- **Scaling.** The workers are the `replicas` of `locust-worker`: change them in a pull request.
  Each worker is one process and uses at most about one core, so the load the cluster can generate
  is about a core a worker. A `kubectl scale` is Flux's to undo at its next reconcile.
- **What the load does elsewhere.** It reaches `hello` through its Service from inside the cluster,
  so the Gateway's proxies and the route's `Probe` see nothing of it. Its public routes have the
  same pods behind them, though: hello requests 1m of CPU and has no CPU limit, and its busybox
  `httpd` forks a process for each connection (seen offline), so a test heavy enough to slow hello
  slows those routes as well. One that keeps the route's `Probe` from a 200 within its 5 seconds for
  5 minutes raises `PublicEndpointDown` or `PublicEndpointWrongStatus`, both critical
  ([Probes](#probes)), so a large test runs with those expected, or silenced for its time
  ([Silences](#silences)). hello's busybox `httpd -v` logs every request it answers, one line each
  (`[<address>]:<port>: response:200`, seen offline), so the load reaches the log store
  ([Logs](#logs)), split over hello's two pods as the Service balances. A node whose collector sends
  at least ten events a second for 30 minutes, ten times as many as the median node's, raises
  `LogCollectorOutsizedShare`, an info alert ([Alerts](#alerts)): a test that keeps a pod of hello
  above about ten requests a second for more than 30 minutes can raise it for that pod's node.
  hello's server closes each connection after its answer, so every request is a new connection, and
  every connection looks the target's name up. The kubelet writes `ndots:5` and the search domains,
  the namespace's three and then any of the node's own (`generateSearchesForDNSClusterFirst` in
  `pkg/kubelet/network/dns/dns.go`), so a name of four dots is asked of the cluster's resolver under
  each search domain before it is asked as it is; and each time for an A and an AAAA record where
  the pod can bind the IPv6 loopback, as urllib3 asks for both only there (`allowed_gai_family` in
  `urllib3/util/connection.py` of urllib3 2.8.0, the release in the image). That is eight queries a
  request there, six of them for names that do not exist, and two more for each search domain of the
  node's: a test of N requests a second asks the resolver about 8N times a second. Offline, with the
  namespace's three search domains and a loopback that held the IPv6 address, every request of a
  test asked those eight.
- **Resources.** The pinned image ran offline as the pods run it: read-only, with no capability, no
  new privileges and the user 1000:1000, the tree's locustfile mounted read-only at `/mnt/locust`, a
  master with its arguments and `--host=http://127.0.0.1:8080`, two workers with
  `--master-host=127.0.0.1` in the master's network namespace, which had nothing but a loopback, and
  there a stand-in target, hello's busybox image running hello's `httpd` command over a page. In two
  such runs a client asked `/worker-count` (2), started a test of two users at one a second for 20
  seconds through `/swarm`, read `/stats/requests` (20 and 21 requests, none failed) and posted
  `/stop`. The master peaked at about 61 MiB resident and the workers at up to about 62 MiB (each
  process's `VmHWM`), each under a twentieth of a core and the master under a hundredth. So each
  container requests 64Mi, the peak rounded up, and is limited to 128Mi, twice that; the master
  requests 10m of CPU and each worker 50m; there is no CPU limit, as a worker is one gevent process
  and a limit would throttle it under every real test and raise the stack's `CPUThrottlingHigh`. At
  100 users a worker, about 50 requests a second each, a worker's peak grew to about 65 MiB. The run
  logged no write the read-only root refused, and the same run with a writable root changed nothing
  in it but the mount point Docker made for the locustfile: Locust writes a file only for a report
  or a log it is told to keep (`--csv`, `--html`, `--json`, `--logfile`, none of them set), and the
  image's bytecode was compiled when it was built (`Dockerfile.ci`). So neither pod mounts anything
  writable. At 1,000 users a worker, in a test of a minute against the target by its name that
  averaged about 850 requests a second in all, its ramp included, with each container's memory
  limited to 128 MiB as the pods' is, a worker peaked at about 99 MiB resident and 84 MiB of its
  cgroup's memory (`memory.peak`), with no kill, and at about half a core; a test of more users than
  that wants more workers (Scaling, above).
- **Debug mode.** `locust/web.py` sets `app.debug = True` on its Flask application. The image holds
  Flask 3.1.3; the wheel asks for no more than `flask>=2.0.0`. Flask's interactive debugger runs
  only in Werkzeug's development server, which `flask run` and `app.run` start (`use_debugger` in
  Flask's `cli.py` and `app.py`), and Locust serves the application with gevent's `WSGIServer`
  instead (`start_server` in `locust/web.py`): no debugger and no reloader run. What debug mode
  does there is Flask's: Jinja checks the interface's templates for changes at each render
  (`TEMPLATES_AUTO_RELOAD`), a key missing from a form is named in the 400 it answers
  (`TRAP_BAD_REQUEST_ERRORS`), and an exception no handler takes propagates
  (`PROPAGATE_EXCEPTIONS`) to gevent, which logs its traceback and answers 500 without it
  (`handle_error` in `gevent/pywsgi.py`). Locust's routes have a handler for every exception, which
  answers with the exception's message and its code, whatever the mode (`locust/web.py`).
- **Monitoring.** None of its own. Locust 2.47.0 serves no metrics: `locust/web.py` has no
  `/metrics` route, the wheel holds no Prometheus client, and it sends telemetry only with `--otel`
  (`locust/main.py`), which is not set. So no monitor scrapes it, it has no alert or dashboard, and
  no row of [Dashboards](#dashboards)' tables names it. Its pods are covered by the monitoring
  chart's stock alerts on every workload, `KubePodCrashLooping`, `KubePodNotReady`,
  `KubeDeploymentReplicasMismatch` and `KubeContainerWaiting` among them. A change that wants
  Locust's numbers in Prometheus adds an exporter.
- **What it calls on its own.** Nothing but the resolver, the master and the target, which the
  workers reach:

  | Call | Variable | State |
  | --- | --- | --- |
  | Update checks, usage reports | none | the package has none |
  | OpenTelemetry's traces, metrics and logs | `--otel` | off: not set |
  | A locustfile fetched from an address | `-f <URL>` | not used: the locustfile is a file |
  | The interface's script and styles | none | served by the master |
  | The addresses in the interface's bundle | none | links a person follows, to Locust's documentation, repository and releases |
  | The one name it looks up, its own | none | answered from the pod's `/etc/hosts` (Network, above) |

  The pinned image ran offline in a network namespace with nothing but a loopback, whose resolver
  was a listener that logged each query and was shown logging a lookup made on purpose. With a line
  for the namespace's hostname in its hosts file, as the kubelet writes one, it logged no lookup of
  Locust's; without that line, one name, that hostname, asked as an A and an AAAA record.
- **Updates.** Renovate's `kubernetes` manager reads the image from both Deployments, and a rule in
  `.renovate/managers.json5` keeps it to the registry's release tags of three numbers, as the
  registry also tags each build of Locust's master branch as `x.y.z.devN` and holds moving tags. The
  master and the workers run one reference, which Renovate moves in one pull request: a worker of
  another version than its master is only warned of (`locust/runners.py`, `client_ready`). It
  merges by the auto-merge switch alone. No check runs the image: a release that renames an option
  the arguments use, or changes where the interface listens, shows first on the cluster, as pods
  that do not become ready and the Kustomization `locust` failing its wait. What this section says
  from Locust's source, its wheel and the image's packages, gevent's and Flask's releases among
  them, is of 2.47.0, so the pull request that moves the image is read against Locust's changelog
  for the arguments of What runs and for this section.
- **Removing it.** Take the two overlay entries out. Flux prunes the application, its pods, its
  Service, its ConfigMap and its policies, and the root prunes the namespace's default deny and its
  `app-template-defaults` ConfigMap; the namespace stays, by its prune annotation, as Flux reads
  that annotation on each object it would prune and not on the object's namespace (`Delete` in
  `ssa/manager_delete.go` of `fluxcd/pkg/ssa` v0.83.0). hello's rule for the workers stays and
  admits nothing while no worker runs; it goes in a pull request of its own.

**What only the live cluster shows.** None of the following is run by a check; each is read from
the pinned sources, and the list is what to look at when the application first reconciles.

- **The order things become Ready.** The root applies the namespace and its default deny at once.
  `locust` waits for `cilium`, so the kind of its policies exists before it applies. The pinned
  kustomize-controller (v1.10.1, of Flux 2.10.0) applies a build through `ApplyAllStaged` of
  `fluxcd/pkg/ssa` v0.83.0 (`ssa/manager_apply.go`): every object is first applied as a server-side
  dry run, and nothing is applied when one fails; then the objects are applied in the order of their
  kinds (`ReconcileOrder` in `ssa/sort.go`), the ConfigMap, the Service, the Deployments, and the
  policies last, a kind that order does not know. With `wait`, the Kustomization is Ready only once
  both Deployments are: a Deployment counts once its ready replicas reach its replicas
  (`deploymentConditions` in `pkg/kstatus/status/core.go` of `fluxcd/cli-utils` v1.4.0). The master
  is ready once its probe answers, and the workers once their containers run, as they have no probe.
- **A worker without its master.** A worker that starts before the master asks for it every 5
  seconds and gives up after 60 tries, about five minutes (`CONNECT_TIMEOUT`, `CONNECT_RETRY_COUNT`
  and `connect_to_master` in `locust/runners.py`), then logs `Failed to connect to the Locust
  master` and exits (`locust/main.py`); the kubelet starts it again. A worker that hears no
  heartbeat from its master for 60 seconds quits (`MASTER_HEARTBEAT_TIMEOUT`,
  `heartbeat_timeout_checker`), and a master that is stopped, as the kubelet stops a pod, with
  SIGTERM, first tells each worker to quit: offline, both workers logged `Got quit message from
  master, shutting down...` and exited with status 0 as the master did. So a restart of the master
  restarts the workers, which connect to the new one through the Service.
- **The image's user.** The image's user is the name `locust`, uid and gid 1000 (`/etc/passwd` of
  the image's `useradd` layer). The kubelet refuses to start a container with `runAsNonRoot` and a
  user it cannot read as a number (`verifyRunAsNonRoot` in
  `pkg/kubelet/kuberuntime/security_context_others.go`: `image has non-numeric user (locust), cannot
  verify user is non-root`), so the pods give `runAsUser` and `runAsGroup`.
- **The port forward.** Talos v1.14.6 ships containerd v2.3.7 (`PKGS` in Talos' `Makefile` at that
  tag, and `containerd_version` in the `Pkgfile` of `siderolabs/pkgs` at that commit), whose port
  forward enters the pod's network namespace and connects to `localhost:<port>` there
  (`internal/cri/server/sandbox_portforward_linux.go`): the connection is on the pod's loopback,
  which no policy sees, so `just locust` needs no rule. A runtime that connected to the pod's
  address from the node instead would arrive as `host`, which the master's rule on 8089 admits.
- **The workers' rule names hello's pods.** The agents translate a Service's cluster address to a
  pod's before policy applies, so the workers reach `hello` and the master by the rules that name
  their pods, not their Services.
- **While the cluster audits**, nothing is dropped: a flow the policies deny passes and shows as an
  `AUDIT` line of `just network-drops`, a missing allow, such as `<count> AUDIT
  locust/locust-worker-<pod> demo/hello-<pod> 8080/TCP`, and the load of a test aimed at a host the
  workers may not reach alike; once it enforces, the same flow is `DROPPED` and the test's requests
  fail. No flow of `locust/locust-master` to the resolver shows, as its own name is in its hosts
  file.
- **What the master says.** As each worker connects, the master logs `<worker> (index <n>) reported
  as ready. <count> workers connected.` (`handle_message` in `locust/runners.py`), so the second
  reads `(index 1) reported as ready. 2 workers connected.`; then `/worker-count` answers
  `{"worker_count": 2}`, and the answers of `/swarm`, `/stats/requests` and `/stop` are those of
  Running a test, above.

### Porting an application from the reference catalogue

The steps n8n took, in order; the next port does the same and says where it differs.

1. **Layout.** A namespace directory with `namespace.yaml` (the strictest Pod Security level the
   workload passes, the prune annotation, and `k8s-gitops/gateway: public` if it has a route) and a
   `kustomization.yaml` that includes `components/common`; the application's `ks.yaml` and `app/`
   beside it. List both in the overlay; an application in a namespace that is already listed adds
   its `ks.yaml` alone, and goes into the list of overlay entries that n8n's test of the overlay
   expects. The namespace's default deny with the application's flows
   ([Declaring an application's flows](#declaring-an-applications-flows)), or its entry in
   `network-policy-exceptions.yaml` with the flows it would declare, as `ai-system`'s is.
2. **Pins.** The chart as an `OCIRepository` named after the application, as the namespace holds
   one per application and two applications applying one name would take turns owning it, with its
   tag under a `# renovate:` comment, each image by tag and digest under one. Read the registry's
   listing for the image's variants (slim, with CUDA, with its own model server) and take the one
   that fetches least and fits the volume, and for whether its version tags are releases alone.
   `just renovate-record`, then the form of the tags in `.renovate/tag-forms.tsv`, read from the
   registry's own listing; `just renovate-pins` passes. The chart's source gets its row of
   `signatures.yaml`, and, where the publisher signs keyless, the row's `verify` block in the
   `OCIRepository`, after the pinned cosign verified the tag with the row's identity
   ([Adding a source](#adding-a-source)); `just signatures-check` and `just signatures-verify` pass.
   Where the registry tags betas as plain versions, as n8n's does, a rule in
   `.renovate/managers.json5` keeps Renovate to the line the tree runs; where it does not, say so,
   and add the image to the packages `.renovate/automerge.json5` never merges. An image an operator
   puts into other pods, or into the workloads it makes, is a value the operator is handed and no
   pod spec of the render, so the image check of `just kubernetes-validate` does not read it: pin
   it by tag and digest under a comment all the same, read how the operator joins the repository
   and the tag in its source, hold the reference it would write in the application's test, from
   the rendered variables, and hold every file of the application back from auto-merge, as the
   [OpenFeature Operator](#openfeature-operator)'s are.
3. **Database.** `components/cnpg-cluster` in `ks.yaml` with `CNPG_CLUSTER_NAME` and `CNPG_NAMESPACE`
   (the `targetNamespace`), and the connection from the keys of `<name>-app`; `cloudnative-pg`,
   `plugin-barman-cloud`, `prometheus-operator-crds`, `external-secrets` and `openbao-store` in
   `dependsOn`. `just kubernetes-check` refuses a Kustomization that takes the component and leaves
   out the plugin or sets `CNPG_NAMESPACE` to another namespace than its `targetNamespace`. An
   application whose default is an embedded database on its volume, such as Open WebUI's SQLite,
   takes none of these, and its section says so and what that makes the volume.
4. **Secrets.** A secret the application keeps a copy of, or that must outlive the cluster, such as
   n8n's encryption key, in the store: an ExternalSecret that reads `<namespace>/<application>`,
   `openbao-store` in `dependsOn`, and the one `just bao-put` command in the docs, with every place
   the secret lives and the order on a rebuild. Each key read from the store gets its entry in
   `secret-rotation.yaml`: `generated` only where any new random value will do, and otherwise
   `re-encryption` or `issued` with the reason, and the application's section says how the key is
   rotated ([Rotating an application's secret](#rotating-an-applications-secret)). A generator and
   a `CreatedOnce` ExternalSecret only
   for a secret nothing keeps, such as the runners' token. A secret the application makes itself
   and keeps on its volume, such as Open WebUI's session key, needs no entry when a variable puts
   the file on the volume; find where it is kept when unset in the application's source, and say
   that the volume's backups hold it. The credentials an administrator enters in the interface, a
   model API's key among them, are in the backups too: say that as well. Nothing secret in a values
   file, and no SOPS file for an application.
5. **Volume.** `components/volsync` with `APP`, a capacity and a minute of its own for the schedule;
   the claim named in `existingClaim`; say what is in the volume and what is in the database, or
   that the volume is both.
6. **Route.** An `HTTPRoute` on `https` of `public`, the application's own settings for its
   host, protocol, origin and proxies agreeing with it, `gateway-public` in `dependsOn`, a rule
   for the backend's pods and container port in the proxies' egress, and the route's `Probe` at a
   path the application answers 200 without a session, with `blackbox-exporter` in `dependsOn`
   ([Giving an application a public hostname](#giving-an-application-a-public-hostname)).
   A route behind the cluster's sign-in also takes `components/sso`, names `oauth2-proxy` in
   `dependsOn` and adds its namespace to oauth2-proxy's grant
   ([Putting a route behind it](#putting-a-route-behind-it)). An interface with no sign-in the
   cluster can rely on gets no route, but a recipe that forwards a local port on 127.0.0.1, as
   Locust's does ([Locust](#locust)).
7. **Hardening.** Restricted: a user the image runs as, a read-only root filesystem with every path
   the application writes as a volume, found by running the pinned image read-only with those
   mounts alone, no capability, requests and a memory limit measured from that run, probes on the
   application's health endpoints, everything that calls its publisher's services turned off by its
   documented variable or named as still on, replicas and an update strategy that fit the volume.
   Run the image with no network and a probe that logs each name lookup and connection, through the
   start and a first use, and put what it tried in the docs as a table of call, variable and state:
   an application can look up a default address at start whatever its switch says. Show the probe
   catching a call the application is known to make, such as a connection turned on at its default
   address, before taking its silence as proof: a runtime that resolves and connects outside the
   calls the probe watches, as Open WebUI's event loop and resolver do, logs nothing at all. A volume
   mounted over a directory hides what the image holds there, so a variant that bakes models into
   the data directory fetches them again. A workload on the host network accounts for every port it
   declares, by a rule in `talos/firewall.yaml` or an entry in `node-firewall-exceptions.yaml`, and
   a host port on the pod network fails `tests/node-listeners.bats`
   ([cluster.md](cluster.md#the-node-firewall)). An application that cannot start offline, as an
   operator that exits without an API server cannot, has no such run to measure: run its image with
   no network and a read-only root to see which user it runs as and that it stops naming the missing
   cluster, read in its source what it writes and what it calls, keep the chart's requests and say
   in the docs that they are not measured, and where a claim rests on what the API server does,
   run a kube-apiserver of the cluster's version offline, with etcd alone, and the image beside it.
8. **Tests.** Scenarios in `features/applications.feature`, each proved by a test of
   `tests/applications.bats` under its title, written and seen failing before the manifests, and
   mutated afterwards: remove the line each assertion guards and see the test fail. `render_app`
   renders any application's release for them. These tests pin sets a port extends: what the
   overlay builds of the namespace, in n8n's test of the overlay, where a second application in
   `ai-system` adds its Kustomization to the set and is left out of the two builds that keep the
   namespace alone; the namespaces that carry the Gateway label in `tests/gateway.bats`, where a
   port with a route also adds its application to the `tree_without` list of the test that leaves
   the Gateway out, and to the same list in `tests/external-dns.bats`; the backends the proxies
   reach in `tests/network-policy.bats`, where a port with a route adds its namespace and port to
   the pairs the routes must send to, and a row that the proxies reach its port and not another;
   the routes, the `Probe`s' paths and the applications that declare a `Probe` in
   `tests/probes.bats`, where a port with a route also adds its application to the `tree_without`
   list of the test that leaves the Gateway out; for a route behind the sign-in, the policies on the
   Gateway's routes in `tests/gateway.bats`, and in `tests/sso.bats` the Kustomizations that name
   oauth2-proxy and the `tree_without` list of the test that leaves the sign-in out; and the
   applications that take the volsync component in `tests/volume-backups.bats`.
9. **Catalogue.** The application's entity in `apps/base/backstage/backstage/app/catalogue/`, named
   as the application and listed in that directory's generator in `app/kustomization.yaml`, with
   its dependencies from `just catalogue-dependencies` ([Backstage](#backstage)).
10. **Docs.** The application's section here: what runs, where its state lives, how its secret is
    made or why it has none, its hostname, the table of what it can call and what a person loses
    to that, any first-visit step and what it means that nobody has claimed the instance, how it
    is backed up and restored.
11. **An operator with an admission webhook**, on top of the steps above. Read what each webhook
    matches in the chart: its rules, its object selector and its namespace selector. A webhook
    that matches other workloads' objects is narrowed until an object that did not ask is never
    sent, by a label where the operator is opt-in; it skips `kube-system`, `flux-system` and the
    operator's own namespace; it fails open; and its wait is written out. What the chart has no
    value for is a post-renderer of the HelmRelease, and the test reads all of it from the chart
    rendered with the post-renderers, with the rules pinned so that a chart that widens one fails.
    Read in the operator's source what its handler refuses, as a failure policy does not cover an
    answer, and what it does on an update. Its certificates come from `cluster-ca`, which goes
    into `dependsOn`, once the source shows which certificate each side trusts: one of
    `cluster-ca` serves where the API server trusts the bundle the CA injector writes and the
    webhook server asks for no client certificate, and not where a side pins the other's own
    certificate file. The API server's calls get a policy of their own with its reason, from
    `kube-apiserver`, `host` and `remote-node` on the webhook's port. No role of the release may
    grant a verb on webhook configurations, which keeps the operator's code from changing what
    they match, and of the other rights Kubernetes' RBAC good practices name as ways to escalate
    privilege the test refuses each the operator does not need, and any role of the release with
    an aggregation rule, whose rules the render does not show. That bounds the code, not the
    account: read what the roles let it create, as a right to create pods, or the workloads that
    make them, in a namespace is as strong as every service account of that namespace, and say in
    the docs what the operator's account can reach through it. Definitions the chart ships as
    templates get `helm.sh/resource-policy: keep`. For each field something writes into the
    release's objects at run time, a CA bundle or a list the operator extends, establish from
    helm-controller's source whether drift detection would write it back, and list it under
    `driftDetection.ignore` if so. Say in the docs what happens while the operator is down, when an
    object that asked is refused, and what leaves and stays when the application is removed.

## Runtime detection

`apps/base/security-system/falco/` runs Falco, from the Falco project's chart
(`oci://ghcr.io/falcosecurity/charts/falco`), in the namespace `security-system`: one pod on every
node, control planes included. Falco watches the system calls of every process on the node and
writes an event for each one that a rule names, such as a shell opened in a container with a
terminal, a read of a sensitive file by a process that should not, or a binary dropped into a
container and run. It detects and does not respond: no pod is stopped or changed, an event leaves
no pod but through the log pipeline, and the chart installs nothing but the DaemonSet, its
ServiceAccount, the ConfigMap of Falco's configuration file, the ConfigMap of the tree's local
rules ([Tuning](#tuning)), the Service of its metrics and their ServiceMonitor (no Falcosidekick,
no Falco Talon, no metadata collector). A cluster selects it with two entries of its overlay, the
namespace directory `security-system` and `security-system/falco/ks.yaml`; without them nothing of
it builds. The application names `prometheus-operator-crds` in `dependsOn`, as the chart's
ServiceMonitor and the application's `PrometheusRule` are kinds that definition provides, and
`cilium`, as its `CiliumNetworkPolicy` is a kind Cilium's operator defines.

The namespace denies traffic by default ([Network policy](#network-policy)), and Falco's
`CiliumNetworkPolicy`, in `app/`, lets in Prometheus' scrape and the kubelet's probes on 8765 and
lets out queries to the cluster's resolver on port 53, UDP and TCP, and nothing else. Falco looks
up a name only to compare a socket's address with it in a rule's condition, through the fields
`fd.cip.name`, `fd.sip.name`, `fd.lip.name` and `fd.rip.name` (libsinsp's `sinsp_dns_manager` in
libs 0.26.1, which the pinned Falco is built with), and the image's rules use one of them once: the
macro `k8s_api_server`, `fd.sip.name="kubernetes.default.svc.cluster.local"`, of the rule
`Contact K8S API Server From Container`, at priority Notice. Falco resolves that name at the first
connection a container opens once it runs, inside its reading of events, and again from a thread
of its own every 10 seconds, doubling to every 320 while the answer stays the same. Without the
resolver that rule never matches, and the first lookup holds up the reading of events until it
times out. A local rule that compares one of these fields makes Falco look up its name the same
way. Falco opens no other connection: its one output is standard output and falcoctl is off; its
one plugin, `container`, asks only the CRI engine, on the runtime's Unix socket; and neither the
Falco binary nor that plugin in the pinned image holds the in-cluster API server's variable
`KUBERNETES_SERVICE_HOST` or the service account token's path, and the chart makes no Role for it.

So the pod mounts no service account token. The chart has no value for that, on the pod or on the
ServiceAccount, and the HelmRelease's post-renderer sets `automountServiceAccountToken: false` on
the pod template
([Kubernetes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#opt-out-of-api-credential-automounting)).
`tests/falco.bats` reads the field in the render, with no volume that projects a token, no mount of
one and no Role or binding, and fails once the chart has a value for it, which then takes the
patch's place; where a docker daemon answers, it also searches the image's two files for the
variable and the path.

### The driver, and the privileges it needs

Falco reads the system calls with the modern eBPF probe, which is in the Falco binary: the probe's
programs are loaded into the kernel when Falco starts, and nothing is built, downloaded or loaded
as a kernel module. The probe needs a kernel that exposes BTF and has the BPF ring buffer
([Falco](https://falco.org/docs/concepts/event-sources/kernel/)). The kernel of the pinned Talos
release, 6.18.63 (the `kernel/build/config-amd64` of the `siderolabs/pkgs` tag that
`siderolabs/talos`' Makefile pins as `PKGS` at `versions.yaml`'s `talos`), has `CONFIG_BPF_SYSCALL`,
`CONFIG_DEBUG_INFO_BTF`, `CONFIG_BPF_EVENTS`, `CONFIG_TRACEPOINTS` and the perf events on. That is
read from the configuration, not from a node: the first start on one is where a kernel setting
that stops the probe shows, in the pod's log, which names the requirement that failed. Kernel
lockdown, which restricts what BPF programs may do, is off: Talos adds `lockdown=confidentiality`
to the kernel's command line only for secure boot (`SecureBootArgs` in
`pkg/machinery/kernel/kernel.go` at the pinned release), `talos/schematic.yaml` asks for none, and
the kernel's configuration defaults to no lockdown (`CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE`). Its
`CONFIG_LOCK_DOWN_IN_EFI_SECURE_BOOT` would turn lockdown on in a node whose firmware has UEFI
secure boot enabled, which the configuration cannot say. The chart's
init container that loads a driver is for the kernel module and is not rendered for this driver, so
the pod has no init container.

What the chart offers for this driver: a privileged container, which it generates by default, or
the four capabilities of `driver.modernEbpf.leastPrivileged`. The application sets the container's
whole security context itself, since the chart then uses it in place of the one it generates, and
the container is not privileged:

- `BPF` loads the probe's programs and maps, and `PERFMON` attaches them to the kernel's
  tracepoints and opens their perf events; the kernel gives these their own capabilities from
  version 5.8;
- `SYS_RESOURCE` lifts the memory lock limit the probe's maps and ring buffers are counted against;
- `SYS_PTRACE` lets Falco read the state of other processes under `/proc`;
- every other capability is dropped, `allowPrivilegeEscalation` is false, the seccomp profile is
  the runtime's default, which containerd's profile admits `bpf` to a container with `CAP_BPF`
  and `perf_event_open` to one with `CAP_PERFMON`
  ([containerd](https://github.com/containerd/containerd/blob/v2.3.7/contrib/seccomp/seccomp_default.go),
  the version Talos 1.14.6 runs), and the user stays root, as reading other processes' files
  needs it. The pod uses the pod network, not the node's, and no host PID or IPC namespace.

`leastPrivileged` is left unset: with the security context given, its one effect is an annotation
that turns AppArmor off for the pod, which would be one more thing the exception covers. The pod's
own security context is empty and `tests/falco.bats` asserts it so.

The host paths it mounts, and why:

- `/proc` at `/host/proc`, read-only: the processes and their state, which Falco reads for what the
  probe cannot, such as the processes that already ran when it started;
- `/etc` at `/host/etc`, read-only, from which Falco's userspace reads the host's `passwd` and
  `group` for the user and group names of events (libsinsp's `usergroup_manager`, which reads them
  under the host root); without it a rule's output shows no names. The chart mounts it for every
  driver and the driver itself does not need it;
- `/sys/kernel` at `/sys/kernel`, read-only, which holds the kernel's BTF and its tracing files;
- `/run/containerd` at `/host/run/containerd`, the directory of the container runtime's socket,
  which the container plugin asks for the name, namespace and image of the pod behind each event,
  so a rule can say which workload did it. The chart mounts it read-write, and a read-only mount
  would not stop a client from connecting to a socket in it. The runtime's socket is as strong as
  root on the node: whoever can run a command in this container, which is whoever may `exec` in
  `security-system`, can use it. Only the CRI engine of the container plugin is on, with this one
  socket; the others, which would mount the directories of Docker, Podman and the like, are off.

The chart also declares host path volumes for `/boot`, `/lib/modules` and `/usr` whatever the
driver, and mounts them only in Falco's container when `driver.loader.enabled` is false, which it is
not here, and in the driver loader's init container, which it renders for every driver but the
modern eBPF probe. No value removes them, so the HelmRelease's post-renderer, a kustomize patch as
the Cilium and Piraeus Operator releases use, deletes them from the DaemonSet: the pod declares only
the four paths above, `tests/falco.bats` compares them with the container's mounts, and it fails
on a mount that names a volume the pod does not have, as each of those three would once the
loader is turned off.

The namespace enforces `privileged`, which host paths and added capabilities need, and audits and
warns at `restricted` ([Pod Security](#pod-security)); the one entry of
`pod-security-exceptions.yaml` for it is `DaemonSet/falco`, whose reason names what the baseline
level refuses in the pod: the four capabilities and the four host paths, with the runtime's
socket directory mounted read-write; `tests/falco.bats` runs the baseline check on the rendered
pod and fails when the reason leaves out a failed control, a capability or a path. Its tolerations
admit every taint, and it runs at `system-node-critical`, as the log collector does, so a node
that is full or tainted still has it.

### The rules, and nothing that updates them

Falco starts from the rules and the container plugin that its image holds, which the image's tag
and digest pin. The pod has no falcoctl: the chart runs falcoctl as an init container that
installs the rules and plugins when the pod starts and as a sidecar that follows newer ones, by
default every week, and both are off, so nothing is fetched at start or later, and the pod has no
volume a downloaded rule or plugin could arrive in. `falco.rules_files` lists the image's
`falco_rules.yaml` and `falco_rules.local.yaml`, and the directory `rules.d`, where local rules
go ([Tuning](#tuning)).

The rules are those of the image at its version, 25 at `0.45.2`, each tagged `maturity_stable`;
the rules of the project's incubating and sandbox maturity levels are not in the image and are not
installed. The rules of priority Critical are `Detect release_agent File Container Escapes`,
`Drop and execute new binary in container` and `Fileless execution via memfd_create`. A newer
rule set arrives with a newer image: the chart and the image it runs, `appVersion` of the chart,
are moved by Renovate in one pull request (`.renovate/groups.json5`), and `tests/falco.bats` fails
unless the image's version is the chart's. Its proofs that run Falco itself skip in CI, so CI does
not show that a newer image still loads the local rules without a warning, compiles the exceptions
and enables the same rules; `bats tests/falco.bats` where a docker daemon answers does. A macro the
newer rules no longer define would load with the warning `LOAD_UNUSED_MACRO` and except nothing
([Tuning](#tuning)).

### Events

Falco writes each event as one JSON line on standard output, with `rule`, `priority`, `output`,
`output_fields`, `tags`, `source`, `hostname`, which is the node's name, and `time`, and writes
no other output: not to syslog, a file, an address or a program. The pod's own messages, its start
and its warnings, are plain lines on standard error. The log collector reads every pod's lines
([Logs](#logs)), so the events are in the store with the namespace, pod, container and node of
the Falco pod that wrote them, each line whole in `_msg`:

- `just logs 'kubernetes.pod_namespace:security-system kubernetes.container_name:falco | unpack_json | filter rule:*'`
  prints the events and none of Falco's own messages;
- `just logs 'kubernetes.pod_namespace:security-system kubernetes.container_name:falco | unpack_json | filter priority:in("Critical", "Alert", "Emergency")'`
  prints those of priority Critical or above;
- the same with `| filter rule:"Terminal shell in container"` for one rule, or `node:<name>` for
  one node.

A shell opened with a terminal in any pod, `kubectl exec --stdin --tty <pod> -- sh`, raises
`Terminal shell in container`, at priority Notice, and is the harmless way to see an event arrive
for whoever has a terminal. A script or an agent has none, and needs none:

- `kubectl --namespace demo exec deployment/hello --container httpd -- find /www -name id_rsa`
  raises `Search Private Keys or Passwords`, at priority Warning. The rule matches the start of any
  process named `find` whose arguments hold the name of a private key file, whether it has a
  terminal or not and whether it runs in a container or on the node; the search itself finds
  nothing and exits 0. Any pod whose image has `find` serves.
- `just logs 'kubernetes.pod_namespace:security-system kubernetes.container_name:falco | unpack_json | filter rule:"Search Private Keys or Passwords"'`
  finds the event, which shows the command in `proc.cmdline`, the pod and namespace in
  `k8s.pod.name` and `k8s.ns.name`, under `output_fields`.

`tests/falco.bats` holds the command to hello's namespace, Deployment, container and directory and,
where a docker daemon answers, asks Falco itself for the rule, its priority, its compiled condition
and the fields of its output.

### Metrics, and the alert

Falco serves its own Prometheus metrics, on its web server's port 8765 at `/metrics`, with the
chart's Service `falco-metrics` and a ServiceMonitor that scrapes it every 30 seconds over plain
HTTP on the pod network and labels each series with the node, `node`. The same port serves the
health check the pod's probes use. The metrics include, for each rule that has matched since the
pod started, `falcosecurity_falco_rules_matches_total`, with the labels `rule_name`, `source`,
`priority` as the number of the rule's priority, 0 Emergency, 1 Alert, 2 Critical, 3 Error, 4
Warning, 5 Notice, 6 Informational and 7 Debug, and a `tag_` label for each of the rule's tags
(`userspace/falco/falco_metrics.cpp` at the pinned version). A rule that has not matched has no
series.

The separate exporter, `falco-exporter`, is not installed. The project deprecated it when Falco
0.38 began to serve Prometheus metrics itself, and it reads Falco's gRPC output, which would need
that output turned on, with its own certificates. What it would add is a counter of events with
the pod and namespace of the workload each concerns as labels, a series for each such pair, which
the alert does not need: the node is enough to find the pod in the event's log line.

`FalcoCriticalRuleMatched` is critical, and each rule and node is one alert. It compares the
counter of each rule of priority Critical, Alert or Emergency with the last value the series had 15
minutes ago or before, within a day, and fires while they differ: from the first evaluation that
reads a new count until that count is 15 minutes old, so it has no time of its own and clears 15
minutes after the last match, but for a restart whose count climbs back, below. A rise is a match;
so is a series with no sample in that day, a new pod's first match of a rule; and so is a count
lower than before, Falco restarted in the same pod and matched since. A staleness marker from a
failed scrape and a gap in the scrape, such as a restart of Prometheus, change nothing while the
count is unchanged and the series is back within a day of its last sample. Its blind spot is a
restart of Falco's container inside the same pod, which keeps every label, after which the rule's
count comes back to exactly the count the series had before the window, such as a rule that
matched once before the restart and once after: that match raises no alert, and is in the logs
only. A count that climbs back to the old one after such a restart, such as 1, 2 and then 3 where
it was 3, can clear the alert while it equals it though Falco went on matching, and fire it again
once the lower counts are 15 minutes old. The other way, a series back unchanged more than a day
after its last sample reads as new and fires once with nothing behind it: from a day and 15
minutes after that sample, or from its return if that is later, until the return is 15 minutes
old, so for at most 15 minutes; every series does the same after Prometheus lost its data.
`tests/rules/falco.yaml` pins each case. The alert is critical, so it goes to the receiver `notify`
like the others of its severity ([Where alerts go](#where-alerts-go)).

### What Falco costs and what it sees

Falco requests 100m of CPU and may use one, the chart's figures: the cost is the system calls of
the node's workloads, which the pod cannot be told in advance. A pod throttled at its CPU limit
reads fewer calls than the node makes; the kernel then drops events, which Falco counts in
`falcosecurity_scap_n_drops_*` and no alert reads.

It requests `192Mi` of memory and is limited to `512Mi`. Part of its memory is fixed once the probe
is loaded, and part grows with the node:

- The probe's ring buffers, through which the kernel hands Falco its events: one of 8 MiB for every
  two CPUs that are online, and one more for an odd CPU. The values write the chart's defaults for
  both, `driver.modernEbpf.bufSizePreset: 4` and `cpusForEachBuffer: 2`, which the rendered
  `engine.modern_ebpf` carries; the image's `falco.yaml` gives the size of each preset, and libs
  0.26.1 counts the buffers (`pman_init_state` in `userspace/libpman/src/configuration.c`).
- The probe's auxiliary maps, in which it builds an event before the event goes to a ring buffer:
  256 KiB for each CPU the kernel counts as possible, online or not, two segments of 128 KiB
  ([Falco](https://falco.org/docs/concepts/event-sources/kernel/#auxiliary-map-memory);
  `AUXMAP_POOL_DEPTH` and `AUXILIARY_MAP_SIZE` in libs'
  `driver/modern_bpf/shared_definitions/struct_definitions.h`).
- Falco itself, with the image's rules and the container plugin loaded and no event read: about 53
  MiB resident, 18 MiB of it Falco's own data and 34 MiB pages of the image's files it maps, its
  binary and the plugin. That is measured off a node: the pinned image run on a workstation of 16
  CPUs with the rendered configuration and `engine.kind: nodriver`, which loads no probe, and with
  the image's `HOST_ROOT` emptied, as Falco does not start where `/host/proc` is missing.
  Transparent huge pages were off for Falco's process in that run, as the Talos kernel gives them
  only to memory a process asks them for (`CONFIG_TRANSPARENT_HUGEPAGE_MADVISE` in its
  configuration) and no mapping of Falco's asks; with them on for every process, as that
  workstation has them, the same run holds about 92 to 97 MiB.
- The state Falco keeps of the node's processes and threads, which builds up over time and then
  levels off
  ([Falco's FAQ](https://falco.org/about/faq/#what-is-the-performance-overhead-or-resource-utilization-of-falco)).
  It is unmeasured here.

The kernel charges the buffers and the maps to the container. At the kernel Talos runs, 6.18.63,
`bpf_ringbuf_area_alloc` in `kernel/bpf/ringbuf.c` allocates every page of a ring buffer with
`GFP_KERNEL_ACCOUNT`, and `__bpf_map_area_alloc` in `kernel/bpf/syscall.c` adds `__GFP_ACCOUNT` to
an array map's allocation (`bpf_memcg_flags` in `include/linux/bpf.h`); either flag charges the
memory cgroup of the process that creates the map, which is Falco's. Only the kernel's command line
turns the charge off, `cgroup.memory=nokmem` for both and `nobpf` for the maps (`cgroup_memory` in
`mm/memcontrol.c`), and neither Talos' default arguments (`DefaultArgs` in
`pkg/machinery/kernel/kernel.go` at the pinned release) nor `talos/schematic.yaml` adds either.
Both are allocated whole when the probe loads, so they count against the limit from Falco's start,
whatever the node does. The probe's programs and its other maps are left out of this arithmetic.

For a node of 8 CPUs the fixed part is 32 MiB of ring buffers, 2 MiB of auxiliary maps and Falco's
53 MiB, about 87 MiB. The request is that and as much again for the state, about 174 MiB, taken up
to `192Mi`. Each further pair of CPUs adds 8.5 MiB to the fixed part, a ring buffer and the pair's
auxiliary maps, and so 17 MiB to the request: `192Mi` holds up to a node of 10 CPUs, and on a node
of 32 the fixed part alone is about 189 MiB, nearly the whole request. The limit is the chart's
request, its figure for a node of any size, as the ceiling. These figures are arithmetic from the
sources and a measurement off a node; none is a measurement on a node. There, Grafana's Explore,
behind `just grafana`, shows each container's working set with the Prometheus query
`container_memory_working_set_bytes{namespace="security-system", container="falco"}`, which the
kubelets report ([Monitoring](#monitoring)), to hold against the request and the limit. Falco's own
figure, `falcosecurity_falco_memory_rss_bytes`, the resident memory of its process, is not one to
hold against them. The kernel maps each ring buffer's data pages twice in a row, so that an event
that wraps past the buffer's end reads as one (`bpf_ringbuf_area_alloc` in `kernel/bpf/ringbuf.c`),
and Falco maps that whole range (`ring_buffer__add` in libbpf 1.3.0, which libs 0.26.1 builds
with), each page of it counted as the process's resident memory (`remap_vmalloc_range` in
`mm/vmalloc.c`, which inserts every page when the range is mapped). So on a node of 8 CPUs it counts
about 64 MiB for the buffers, which the container is charged 32 MiB for. Its
`falcosecurity_falco_container_memory_used_bytes` reads the cgroup v1 file
`/sys/fs/cgroup/memory/memory.usage_in_bytes` unless the variable `FALCO_CGROUP_MEM_PATH` names
another (libs' `userspace/libsinsp/linux/resource_utilization.cpp`, under the name Falco's
`cmake/modules/falcosecurity-libs.cmake` gives the variable), so it is 0 on Talos, which mounts
cgroup v2 alone (`MountCgroups` in `internal/app/machined/pkg/startup/tasks.go` at the pinned
release), as it is in the run off a node above.

A container that goes on using more memory than its limit is killed by the kernel and started
again by the kubelet
([Kubernetes](https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/#exceed-a-container-s-memory-limit)),
and Falco's is started again in the same pod, as a DaemonSet's pods restart their containers always
([Kubernetes](https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/#pod-template)).
The pod keeps its name and address, so every label of its series stays, and Falco's counters start
from nothing: the precondition of the blind spot of `FalcoCriticalRuleMatched`
([Metrics, and the alert](#metrics-and-the-alert)), in which a rule that had matched once before
the kill and matches once after it raises nothing. What the node did between the kill and the
restart, nothing read. Such a kill shows as `OOMKilled`, the reason of the container's last state,
beside its restart count: `kubectl --namespace security-system get pods` gives the restarts, and
`kubectl --namespace security-system get pod <pod> --output jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'`
the reason.

Falco sees every process's system calls on the node, the node's own and those of every container,
with their arguments, and an event's `output` and `output_fields` carry the arguments of the
process that matched: command lines, file names, environment values a rule prints. Arguments can
hold secrets, a password given on a command line or a token in an address, and such an event then
holds it. An event is a line in the pod's log file on the node, until the kubelet rotates it, and a
document in the log store, with the other logs, for 14 days or until the store's 15 GiB are used
([Logs](#logs)); whoever can read the store, with `just logs` or Grafana's VictoriaLogs datasource,
or `exec` into the pods of `monitoring` and `security-system`, can read it.

### Tuning

Local rules have one place, the `customRules` key of
`apps/base/security-system/falco/app/values.yaml`: a map of rule file names to their contents,
which the chart makes the ConfigMap `falco-rules` of and mounts at `/etc/falco/rules.d`, which
Falco reads after the image's rules. It holds one file, `exceptions.yaml`, of two items, each with
its reason in a comment above it, and no rule of the tree's own:

```yaml
- macro: user_known_stand_streams_redirect_activities
  condition: (k8s.ns.name = "demo" and container.name = "httpd" and container.image.repository = "docker.io/library/busybox" and proc.name = "httpd")
  override:
    condition: replace
- macro: known_drop_and_execute_activities
  condition: (k8s.ns.name = "kube-system" and container.name = "apply-sysctl-overwrites" and container.image.repository = "quay.io/cilium/cilium" and proc.exepath = "/opt/cni/bin/cilium-sysctlfix")
  override:
    condition: replace
```

The first quiets the image's rule `Redirect STDOUT/STDIN to Network Connection in Container`, of
priority Notice, for the demo's web server, `hello`, and for nothing else. The rule's condition is
`dup and container and evt.rawres in (0, 1, 2) and fd.type in ("ipv4", "ipv6") and not user_known_stand_streams_redirect_activities`:
a `dup`, `dup2` or `dup3` in a container that returns 0, 1 or 2, a standard stream, for an IPv4 or
IPv6 socket, which is how a reverse shell begins; the macro it negates is the placeholder the image
leaves for known cases, `(never_true)`. busybox's `httpd` answers a request the same way:
`mini_httpd` in `networking/httpd.c` of busybox 1.38.0, the version `hello` runs, forks for each
connection it accepts, and the child calls `xmove_fd(n, 0)` and `xdup2(0, 1)`, two `dup2` calls
that return 0 and 1 for the connection's socket (`libbb/xfuncs_printf.c`). So every request matches
the rule twice, the kubelet's readiness probe included, and the server matches it once more when it
starts, as `mini_httpd` first moves its listening socket to standard input with `xmove_fd`; those
events would bury any other the rule raises.

The first exception replaces the placeholder with four equalities, each of which leaves something
out of it: the namespace, the workloads of every other namespace; the container's name,
`volsync-demo`, which runs the same image in the same namespace; the image's repository, any other
image run under that name there; and the process, a shell, or any process but `httpd`, that puts its
streams on a socket in that very container. All of those still match, as every other workload does.
Falco compiles the rule to the image's condition with one negation, of that conjunction:
`(evt.type in (dup, dup2, dup3) and container.id != host and evt.rawres in (0, 1, 2) and fd.type in (ipv4, ipv6) and not (k8s.ns.name = demo and container.name = httpd and container.image.repository = docker.io/library/busybox and proc.name = httpd))`.

The second quiets the image's rule `Drop and execute new binary in container`, of priority
Critical, whose matches raise `FalcoCriticalRuleMatched`
([Metrics, and the alert](#metrics-and-the-alert)), for Cilium's sysctl fix and for nothing else.
The rule's condition is
`spawned_process and container and proc.is_exe_upper_layer=true and not container.image.repository in (known_drop_and_execute_containers) and not known_drop_and_execute_activities`,
an `execve` or `execveat` in a container whose executable is in an upper layer, where the list is
empty and the macro is the placeholder `(never_true)`; libs 0.26.1 sets that flag when the
executable's filesystem is overlayfs and the file has an upper dentry, and reads nothing of when
the file was written (`extract__overlay_layer` in
`driver/modern_bpf/helpers/extract/extract_from_kernel.h`, which the probe calls at each `execve`
and `execveat`). Cilium's chart gives each agent's pod the init container `apply-sysctl-overwrites`,
on the agent's image, with `BIN_PATH=/opt/cni/bin`, the node's `/opt/cni/bin` mounted at `/hostbin`
and its `/proc` at `/hostproc`, which runs
`cp /usr/bin/cilium-sysctlfix /hostbin/cilium-sysctlfix; nsenter --mount=/hostproc/1/ns/mnt "${BIN_PATH}/cilium-sysctlfix"; rm /hostbin/cilium-sysctlfix`:
it copies the binary from its image into the node's CNI directory and runs it there, in the node's
mount namespace, from a process still in the init container
(`templates/cilium-agent/daemonset.yaml` of the chart, under `sysctlfix.enabled`, which is on by
default). Talos mounts an overlay at `/opt`, its upper layer on the node's `/var` (`Overlays` in
`pkg/machinery/constants/constants.go` at the pinned release), so the copy is in that overlay's
upper layer, not in the container's own, and but for this exception the rule matches its execution
whenever an agent's pod starts on a node where Falco runs: on a new chart, a change of Cilium's
values, which rolls the agents, or a deleted agent pod. The chart's init container `mount-cgroup`,
under `cgroup.autoMount.enabled`, copies `cilium-mount` into the same directory and runs it the
same way. Cilium's values turn it off, as Talos mounts the cgroup hierarchy itself; turned on, its
run would match the rule as well, and this exception would not except it.

The second exception replaces the placeholder with four equalities, each of which leaves something
out of it: the namespace, any other namespace; the container's name, the agent and the other init
containers of the same image in the same pod; the image's repository, any other image in a
container of that name; and the path, any binary that container runs from an upper layer at any
other path, `cilium-sysctlfix` included. The condition names a path and not a file, so it excepts
whatever that container runs at that one path, which is what its command, held to the chart's by
the proof below, copies there from Cilium's image. The path is `proc.exepath`, the executable's
path as the kernel resolved it, and not `proc.exe`, which is `argv[0]`, what the caller chooses.
The image's list `known_drop_and_execute_containers` would not do: it takes a whole image, every
container and binary of Cilium's agent included. Falco compiles the rule to the image's condition
with one negation, of that conjunction:
`(evt.type in (execve, execveat) and container.id != host and proc.is_exe_upper_layer = true and not container.image.repository in () and not (k8s.ns.name = kube-system and container.name = apply-sysctl-overwrites and container.image.repository = quay.io/cilium/cilium and proc.exepath = /opt/cni/bin/cilium-sysctlfix))`.

`tests/falco.bats` holds the exceptions to that:

- The place holds that one file of those two items, in that order, each an override that replaces
  one macro's condition with its reason in a comment above it, and the chart's ConfigMap and the
  pod's mount carry it. There is no second place: under `/etc/falco` the pod mounts only its
  configuration file, an empty `config.d` and `rules.d`, and the configuration names `config.d`
  alone as where Falco reads further configuration, which could turn a rule off.
- The first's condition is, to the letter, the conjunction of four values read from `hello` as Flux
  applies it: the namespace its Kustomization targets, its container's name, its image without tag
  or digest and the first word of its command. A `hello` whose container is renamed, whose image
  moves or whose command changes fails the proof, as the exception then names nothing that runs.
  Of every container and init container of the workloads the overlay builds into `demo`, only
  `hello`'s has that name and image, with the image's short forms written out as the runtime
  reports them, so no other `httpd` is excepted. The reason above is read from the source of the
  busybox version `hello` runs, which the proof finds named here, so a `hello` on another version
  fails it until that version's `httpd` is read, and the failure says which version to read.
- The second's condition is, to the letter, the conjunction of four values read from Cilium's
  chart, rendered as Flux installs it, with its values and its post-renderer: the namespace of the
  DaemonSet `cilium`, which its Kustomization targets; the name of the one container that runs
  `cilium-sysctlfix`, which no other container of the render has; that container's image without
  tag or digest, written registry first as the runtime reports it; and
  `${BIN_PATH}/cilium-sysctlfix`, with `BIN_PATH` from its environment. The proof also holds the
  container's command to the chart's, a copy of the binary into the mount of the host path
  `BIN_PATH`, run by `nsenter --mount=<mount>/1/ns/mnt` where `<mount>` is the mount of the host
  path `/proc`, as that is what makes the path the node's; a command of any other shape fails it,
  saying to read the chart's init container again. A Cilium whose CNI directory, image or namespace
  moves, or whose post-renderer renames the container, fails the proof, saying what Cilium is now,
  and one with `sysctlfix.enabled: false` fails it saying to remove the exception, which then names
  nothing that runs.
- Where a docker daemon answers, Falco itself says so, run from the pinned image without network,
  capability or root, on the rendered configuration and rules. Its dry run exits 0: a condition
  with a field Falco does not know makes it exit 1, which on a node is a pod in a crash loop. It
  validates the image's rules and then the local file without an error or a warning: an override of
  a macro the image does not define loads with the warning `LOAD_UNUSED_MACRO` and excepts nothing.
  It prints the redirect rule enabled, at priority Notice, and the drop-and-execute rule enabled, at
  priority Critical, each compiled to its condition above, where without the local file each
  negates the image's placeholder. And it lists the same rules enabled with the local file as
  without it, nothing changed but those two rules and their two placeholders: no other rule or
  macro, and no list.

What no proof shows: an event evaluated against either rule. Of the image's engines, replay is the
one that gives Falco system calls without a probe, and it reads a capture file, which only a probe
on a running kernel records and which would hold that machine's processes, users and addresses. So
that each rule still matches every other workload, and the drop-and-execute rule the same exec in
another namespace, another container or at another path, rests on the condition Falco compiles. The
values Falco reports for the four fields of each exception follow from the pinned sources, and an
event on a node is what shows them: `container.name` is the name in the container's CRI metadata
and `k8s.ns.name` the namespace of its pod's sandbox (`go-worker/pkg/container/cri.go` of the
container plugin at 0.7.6, the version the image loads), and `container.image.repository` is the
image reference containerd 2.3.7 reports, the image's first repository digest
(`internal/cri/server/container_status.go`), up to its `@`, which for `hello`'s image is
`docker.io/library/busybox` and for Cilium's `quay.io/cilium/cilium`. For the sysctl fix, two of
them are what such an event has to show. `proc.exepath` is the path the probe builds by walking the
executable's mounts up to the root of the mount namespace they are in
(`auxmap__store_d_path_approx` in libs' `driver/modern_bpf/helpers/store/auxmap_store_params.h`),
which for a binary run in the node's mount namespace should be the node's path,
`/opt/cni/bin/cilium-sysctlfix`, and not the container's `/hostbin/cilium-sysctlfix`. And the
container plugin's fields need the init container's details before its first exec: its create
hook, the one the rendered configuration turns on, comes from the CRI engine's `CONTAINER_CREATED`
event, which the runtime sends before the container starts. An event that comes before the
container plugin has the container's details from the runtime may not have the three fields the
plugin gives, `k8s.ns.name`, `container.name` and `container.image.repository`, as the plugin's
descriptions of them say; the conjunction is then false, and the event still matches, which for the
sysctl fix is the rule matching and `FalcoCriticalRuleMatched` firing as it would without the
exception. A node that boots should not raise the rule for it at all: Falco's pod takes its address
from Cilium's CNI, so its probe loads only once the agent runs, after its init containers. The CI
containers have no docker daemon, so the proofs that run Falco run where a developer or an agent
has one, and skip in CI, saying why.

To silence another known-benign event, find it (`just logs` above) and read its rule and the
namespace, pod, container, image and process in its `output_fields`; then, in a pull request:

1. add an item to `exceptions.yaml` that overrides the placeholder the rule leaves for the case
   (the image's rules name them `user_*` and `known_*`, such as
   `user_expected_terminal_shell_in_container_conditions` for `Terminal shell in container`), with
   the reason for the exception in a comment above it, as the items above have;
2. keep it as narrow as the event is, a conjunction of what the event shows of the workload, and
   never a whole rule off: the proof of the place fails on an item, file or place it does not
   state, and, where a docker daemon answers, the proofs fail when Falco lists one rule fewer
   enabled;
3. prove it as the items above are proved: the proof of the place states what the place holds, so
   an item it does not expect fails it, and the item's own proof takes its values from the workload
   it excepts;
4. merge it. The pod template carries a checksum of the rules' ConfigMap, `checksum/rules`, so the
   DaemonSet rolls when the rules change, one node at a time, and the Kustomization waits for the
   release. A pod that still runs gets the new file as well: the kubelet brings a changed ConfigMap
   to the mount
   ([Kubernetes](https://kubernetes.io/docs/concepts/configuration/configmap/#mounted-configmaps-are-updated-automatically)),
   and Falco watches the rules files it loaded (`watch_config_files`, on in the rendered
   configuration), tries the new ones in a dry run of its own and, when they load, restarts itself
   in place, which keeps the pod and starts its counters from nothing as a kill at the memory limit
   does ([What Falco costs and what it sees](#what-falco-costs-and-what-it-sees)). A file Falco
   refuses stops both: a pod that runs keeps the rules it has and writes
   `Falco internal: hot restart failure`, at priority Critical, among its events, and a new pod
   exits when it starts, so the roll stops at its first node, the release's upgrade does not
   become ready and its remediation rolls it back ([What the root sets](#what-the-root-sets)).
   `FluxApplierNotReady` raises the release after 15 minutes.

The Falco documentation says what else an override can do
([overriding](https://falco.org/docs/concepts/rules/overriding/),
[exceptions](https://falco.org/docs/concepts/rules/exceptions/)).

## Admission policy

The tree's checks stop a bad object before it is merged. They do not see one applied by hand, by an
operator or by a chart at run time, and they report nothing about what already runs. An admission
policy engine does both, against rules written once. Two engines dominate, so the lab runs both, in
audit, holding the same three rules, to compare them on a real cluster. Neither refuses, mutates or
generates a workload, and neither can hold up the cluster: the webhooks that match workloads fail
open and skip the control plane's and Flux's namespaces. Kyverno also keeps webhooks of its own, on
its own policy kinds, that fail closed ([Audit, and what a webhook may do](#audit-and-what-a-webhook-may-do)).

The engines are five applications, which an overlay selects an engine at a time, each engine in a
namespace of its own that enforces the restricted level:

| Engine | Namespace | Applications, in order | Chart | Rules written as |
| --- | --- | --- | --- | --- |
| Kyverno | `kyverno` | `kyverno`, `kyverno-policies` | `kyverno` 3.10.0, Kyverno 1.20.0, an OCI chart | `ValidatingPolicy` (`policies.kyverno.io/v1`), in CEL |
| Gatekeeper | `gatekeeper-system` | `gatekeeper`, `gatekeeper-templates`, `gatekeeper-policies` | `gatekeeper` 3.23.1, from the project's Helm repository | `ConstraintTemplate` in Rego, and a constraint of each template's kind |

The engine's application is the chart and what scrapes and alerts on it. Kyverno's rules are the
next application, which waits for the engine (`dependsOn`) because the kinds it applies are the
release's. Gatekeeper's are two, because a constraint's kind is not the release's: Gatekeeper makes
it from the constraint's template once it has reconciled the template, and Flux's server-side dry
run of an object of a kind that does not exist fails the whole Kustomization, so a Kustomization
that held templates and constraints together would apply neither and no retry could succeed.
`gatekeeper-templates` applies the three templates after the release, and is Ready only when each
template's `status.created` is true (a `healthCheckExprs` entry on `ConstraintTemplate` with
`wait: true`; Flux otherwise takes an applied template for ready): that is the status the
ConstraintTemplate's schema holds for the kind having been created, and `tests/admission-policy.bats`
reads it, a boolean below a status subresource, in the pinned chart's definition, so a chart that
dropped it fails offline. `gatekeeper-policies` applies
the constraints and depends on `gatekeeper-templates` alone, so it starts when their kinds are
served. The two read different artifacts, and kustomize-controller compares a dependency's applied
revision with the dependent's only when both read one source, so a change that adds a template and
its constraint together can start `gatekeeper-policies` while `gatekeeper-templates` is still Ready
from the revision before: that attempt's dry run fails for the new kind, nothing of it is applied,
and the retry a minute later succeeds. `just kubernetes-check` refuses a constraint that is in its template's Kustomization, whose
Kustomization does not depend on its template's, or whose template's Kustomization does not wait
for the kinds ([What the checks refuse](#what-the-checks-refuse)).

Kyverno's release also gives every definition it installs `helm.sh/resource-policy: keep`, so Helm
leaves them, and every policy and report of their kinds, when the application leaves the tree. The
chart writes that annotation itself on five of its definitions and takes more only through values
that would repeat it there, so the HelmRelease's post-renderer sets it on every
`CustomResourceDefinition` instead, which sets it once on each; `tests/admission-policy.bats` parses
the chart's output strictly and counts the annotation on every definition.

Nothing else in the tree depends on any of the five, and `tests/admission-policy.bats` builds the
overlay without each engine in turn: the other builds whole and nothing of the one taken out is
left, so taking an engine out is taking its namespace directory's applications out of the overlay
(a constraint left without its template, or a rule without its engine, fails
`just kubernetes-check`). Kyverno's go together, as its definitions stay. Gatekeeper's go in two
changes, `gatekeeper-policies` first and `gatekeeper` and `gatekeeper-templates` once Flux has
pruned it: Gatekeeper makes each constraint's kind as a definition its template owns, so a template
deleted first takes the kind with it, and kustomize-controller may then never finish deleting the
constraints, as it cannot find their kind. Neither engine's pods are a dependency of anything, as
the webhooks of both that match workloads fail open.

Neither namespace holds a default deny yet: each is in `network-policy-exceptions.yaml` with its
reason and what covers it instead ([Network policy](#network-policy)), because the API server's calls
to the webhooks come from the control planes' host network and the flows are observed before a
policy names them.

### The three rules

Each rule has the same name, the same meaning and the same offline twin in both engines, named in an
annotation, `k8s-gitops/offline-check`, on each engine's object. Each is a rule the tree already
keeps before a change is merged, so the render of the tree passes all three in both engines
(`tests/admission-policy.bats` evaluates every pod template and namespace of the render in both, and
fails when either finds anything, with a pod and a namespace that break the rules added to show the
engines see them):

| Rule | What it asks | The offline check it mirrors |
| --- | --- | --- |
| `image-pinned` | Every container, init container and ephemeral container of a pod has an image pinned by a sha256 digest, or by a tag other than `latest`. | The image check of `just kubernetes-validate` ([What the checks refuse](#what-the-checks-refuse)). |
| `restricted-security-context` | A pod in a namespace that enforces the `restricted` Pod Security level sets `allowPrivilegeEscalation: false`, drops `ALL` capabilities, runs as non-root and has the `RuntimeDefault` or a `Localhost` seccomp profile, on each container or on the pod. | `just pod-security-check` ([Pod Security](#pod-security)), which holds every workload of the render to its namespace's level. What must be absent at that level (host namespaces, host paths, added capabilities) is Pod Security admission's, which refuses it in such a namespace, so this rule asks for what a manifest has to set. |
| `namespace-pod-security-level` | A namespace has a `pod-security.kubernetes.io/enforce` label of `privileged`, `baseline` or `restricted`. | `just pod-security-check`, which fails a namespace an object of the render is in that has none. |

A pod is the one object matched, for the first two: a Deployment, a Job or a DaemonSet ends in pods,
and evaluating the pod finds what an operator or a controller made as well. Kyverno's automatic
rules for pod controllers are off, so a finding is one object in both engines. The restricted rule
is for the namespaces that carry the `restricted` enforce label, which both engines read from the
namespace (`namespaceSelector`), and `kube-system`, which Talos exempts from Pod Security admission
and the tree labels `privileged`, is not one of them.

Beyond the rules' own match, the engines do not look at the same namespaces at run time. Kyverno
leaves out, at admission and in its background scans, every object its configuration's
`resourceFilters` name. The chart's defaults, which the rendered `kyverno` ConfigMap keeps, name
everything in `kyverno`, `kube-system`, `kube-public` and `kube-node-lease`, and Kyverno matches a
filter's namespace against a Namespace object's own name too (`ToFilter` in `pkg/config/config.go`
at the pinned version). Gatekeeper's audit leaves out only the namespaces a `Config` object excludes
from it, and the tree has none, so it evaluates every namespace, `kube-system`, `flux-system` and
both engines' own among them; its `--exempt-namespace` only lets its own namespace carry the label
that exempts a namespace from the webhook. At admission, both webhooks skip `kube-system`,
`flux-system` and their own namespace.

So the first reports of a live cluster are expected to differ on the namespaces Kubernetes makes,
which the tree declares no level for, against `namespace-pod-security-level`: `default` in both
engines, `kube-node-lease` and `kube-public` in Gatekeeper's alone. `kube-system` carries the
`privileged` level the tree gives it and `flux-system` the `restricted` level the FluxInstance gives
it, so neither is a finding. A pod in `kube-system` or `flux-system` that breaks a rule is seen by
neither webhook; Gatekeeper's audit reports it in both namespaces, Kyverno's scan in `flux-system`
alone. Only the live cluster shows the reports themselves.

How each engine says it:

- **Kyverno**: one `ValidatingPolicy` per rule in `kyverno-policies/app/`, `validationActions:
  [Audit]` and `failurePolicy: Ignore`. `variables` collect the containers or images, and each
  `validations` expression is CEL, with the message the report carries; the restricted rule has one
  expression for each setting, so a report names which of the four a pod misses. The legacy kind,
  `ClusterPolicy` of `kyverno.io/v1`, is no longer executed as of Kyverno 1.20, and the chart refuses
  to install or upgrade over one found on the cluster.
- **Gatekeeper**: one `ConstraintTemplate` per rule in `gatekeeper-templates/app/`, holding the Rego
  and the name of the kind, and one constraint of that kind in `gatekeeper-policies/app/`,
  `enforcementAction: dryrun`. Gatekeeper
  creates the kinds `K8sImagePinned`, `K8sRestrictedSecurityContext` and
  `K8sNamespacePodSecurityLevel` at run time, from the templates, and no definition of them is in the
  tree. `just kubernetes-validate` fails for an object
  of a kind that has no schema unless `schema-exceptions.yaml` lists it, so the three constraint
  kinds are listed there, each with its reason: Gatekeeper makes them from the templates at run
  time, and `gator verify` and `gator test` check the constraints, each against its template's
  schema, which `tests/admission-policy.bats` runs. The templates
  and the Kyverno policies are validated by `just kubernetes-validate` against the definitions the
  render holds.

### Tests

Each rule is tested in its engine's own tool, with objects it accepts and objects it refuses:
Kyverno's `kyverno test`, one directory for each rule in `tests/admission-policy/kyverno/`, whose
resources are named `pass-`, `fail-` or `skip-` for what the policy must do, and `gator verify`,
`tests/admission-policy/gatekeeper/suite.yaml`. The bats test reads Kyverno's report and requires
every `fail-` object to be refused with its rule's message, not excluded, and every `skip-` object
to be excluded. `kyverno` is the CLI pinned in `mise.toml` for the Pod Security check, which is on
the 1.19 line, and the engine runs 1.20.0; the CEL of both is the Kubernetes library, and a live
cluster is what shows a difference. `gator` is pinned beside it, at the release of the Gatekeeper
chart, and runs the same Rego engine as the webhook; Renovate does not move either
(`.renovate/by-hand.tsv`).

### Audit, and what a webhook may do

- **Gatekeeper's** webhooks are in the render, and the test reads them there. `validation.gatekeeper.sh`
  and `check-ignore-label.gatekeeper.sh` fail open (`Ignore`) and skip `kube-system`, `flux-system`
  and `gatekeeper-system` in their namespace selectors, and wait three seconds at most, the chart's
  value, before the failure policy admits the object: the chart's values give the first its list and
  the chart adds its own namespace, and a post-renderer of the HelmRelease gives the second the same
  list, as the chart skips only the release's namespace there. The mutating webhook is not
  rendered (`disableMutation`), and the chart's three hook jobs that would change the cluster beside
  the release are off. Every constraint is `dryrun`.
- **Kyverno's** are made at run time by its admission controller, so the render holds none and the test
  reads the settings that decide them: `--forceFailurePolicyIgnore=true`, which gives every webhook
  that matches resources the failure policy `Ignore` whatever a policy says (each policy also sets
  it), and the namespace selector of the `kyverno` ConfigMap, which skips `kube-system` and
  `flux-system`, with the release's own namespace added by the chart. The webhook that protects
  generation labels, the generation of Kubernetes' own ValidatingAdmissionPolicies, and the background
  and cleanup controllers are off, and every rule is `Audit`. A webhook that matches resources waits
  10 seconds at most before `Ignore` admits the object: at the pinned version Kyverno sets no
  `timeoutSeconds` on it unless a policy's `webhookConfiguration` does, which none does and the test
  asserts, so the API server's default of 10 seconds applies. That is longer than Gatekeeper's
  three: a Kyverno pod that hangs rather than fails delays each write it matches by up to 10
  seconds. The admission controller's `--webhookTimeout`, whose default is also 10 seconds
  (`DefaultWebhookTimeout`), sets the wait of the webhooks on Kyverno's own kinds; the values leave
  it out, and the test fails if it is set above 10.
- **What only the live cluster shows.** Kyverno registers six more webhook configurations at run
  time, five of which fail closed and skip no namespace: read from its source at the pinned version,
  neither the values nor a policy changes them, and `--enablePolicyException=false` does not stop the
  first three. All match only Kyverno's own kinds (`kyverno.io` and `policies.kyverno.io`), so no
  workload is held up.
  - `kyverno-exception-validating-webhook-cfg` and `kyverno-cel-exception-validating-webhook-cfg`:
    `Fail`, on PolicyExceptions.
  - `kyverno-global-context-validating-webhook-cfg`: `Fail`, on GlobalContextEntries.
  - `kyverno-policy-mutating-webhook-cfg` and `kyverno-policy-validating-webhook-cfg`: `Fail`, on
    Kyverno's policy kinds.
  - `kyverno-verify-mutating-webhook-cfg`: `Ignore`, on Kyverno's own Leases in its namespace, which
    is how the controller checks that its webhooks are reached.

  So while no Kyverno pod answers, a write of a Kyverno policy, PolicyException or GlobalContextEntry
  is refused: Flux cannot apply or change a rule, which is `kyverno-policies` failing and retrying,
  and every other object is admitted. These are the only webhooks of either engine that fail closed,
  and they match Kyverno's own kinds alone.
  `kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations` on a cluster shows the
  full set. What the chart's webhook certificates and a first start do in practice, and whether the
  CEL of the rules evaluates on Kyverno 1.20 as on the CLI, are also visible there only.

### Reading the findings

- **Kyverno** writes a `PolicyReport` for each namespace and a `ClusterPolicyReport` for what is
  not in one, such as a namespace: `kubectl get policyreport --all-namespaces`,
  `kubectl get clusterpolicyreport`, and `-o yaml` on one for each failed result's policy, rule
  message and resource. The reports controller scans what already runs every hour, and each admitted
  object is reported as it is admitted. The counts are the metric `kyverno_validating_policy_results_total`
  (`kyverno_validating_policy_results` in Kyverno's source, which the Prometheus exporter gives the
  counter suffix; a scrape of the live cluster confirms the name), scraped from the admission and
  reports controllers' ServiceMonitors. `kubectl get validatingpolicies` lists the rules and whether
  each is ready.
- **Gatekeeper** keeps the findings in each constraint's status: `kubectl get constraints` lists them
  with their violation counts, and `kubectl get k8simagepinned image-pinned -o yaml` has
  `status.violations`, up to 20 of them (`constraintViolationsLimit`) with the resource and the
  message, and `status.totalViolations`. The audit runs every 60 seconds. The count of violations
  for each constraint and enforcement action is the metric `gatekeeper_violations`, which a
  PodMonitor scrapes from the audit pod, and the controller managers' webhook metrics from theirs.
- Each engine has one own alert, `KyvernoAdmissionControllerDown` and
  `GatekeeperControllerManagerDown`, for its admission controller not running
  ([Alerts](#alerts)); a violation is a finding to read, not an alert.

### Moving a rule to enforce

A rule changes from a report to a refusal one engine at a time, and one rule at a time: `Deny` in
`validationActions` for Kyverno, `deny` as the `enforcementAction` for Gatekeeper. Never both
engines for one rule, as the object would be refused twice with two messages. What must be true
first:

- The rule's report has been empty for a stretch that covers the charts' upgrades and the
  operators' pods, in the engine that will refuse: a finding is an object that would be refused the
  next time it is made, and an operator that makes it cannot be told why.
- What the rule would refuse is what the offline check already refuses, or the tree is changed
  first, so a pull request fails before the cluster does.
- The engine's pods run on more than one node with a budget, which they do, and the failure policy
  stays `Ignore`: a refusal applies only while the webhook answers, and an engine that is down admits.
- The namespaces that keep the cluster reconciled stay skipped, as they are.
- A way to except an object is chosen first: Kyverno's `PolicyException` is off
  (`features.policyExceptions`), and a Gatekeeper constraint's `match.excludedNamespaces` is
  the narrow tool for a namespace.
- The rule's test has a refused case in the engine's tool, which it has, and the change moves its
  assertion with the action.

### What each engine costs

From the rendered releases, with the values of the tree:

| | Kyverno | Gatekeeper |
| --- | --- | --- |
| Objects the release renders | 66, among them 4 hook Jobs and 2 test Pods | 29 |
| Definitions | 22 | 17, and 3 more at run time, one for each constraint kind |
| Rules | 3 objects | 6 objects |
| Long-running pods | 3: two admission controllers and one reports controller | 3: two controller managers and one audit |
| Memory requested | 320 MiB (2 x 128, 64) | 1536 MiB (3 x 512) |
| CPU requested | 300m | 300m |
| Memory limit | 384 MiB, 128 MiB | 512 MiB each |
| Disruption budget | one, on the admission controllers | one, on the controller managers |
| Priority | the default | `system-cluster-critical` on both Deployments, with a ResourceQuota `gatekeeper-critical-pods` of 100 pods in its namespace |

### A short comparison

What this port showed:

- **Rules.** A Kyverno rule is one object of CEL, whose expressions each carry a message, and
  Rego needs a template and a constraint, with the kind in two places. The three rules are 3 and 6
  objects. Rego's rule per violation gives the same messages.
- **Tests.** Both tools run offline from files. Kyverno's report names the result of every resource
  and says `Excluded` for one the namespace selector leaves out, which a test can mistake for a pass
  unless it reads the message; `gator verify` asserts the number of violations and their message
  for each case. Gatekeeper needs the namespaces in a case's inventory for a `namespaceSelector`,
  Kyverno's CLI a values file.
- **Webhook control.** Gatekeeper's webhooks are chart objects whose failure policy and skipped
  namespaces are values, but one of two needed a post-renderer. Kyverno's are made at run time from
  a flag and a ConfigMap, so the render cannot show them, and six of them are beyond the settings.
  Gatekeeper's waits three seconds for an answer, Kyverno's ten.
- **Scope.** Kyverno's `resourceFilters` leave four namespaces out of admission and scans alike,
  `kube-public` and `kube-node-lease` among them; Gatekeeper's audit sees every namespace, the
  system ones its webhook skips included. So Gatekeeper reports more of what Kubernetes and Talos
  make, and of the namespaces Kyverno's webhook skips, its scan covers `flux-system` alone.
- **Findings.** Kyverno's are objects a person lists for each namespace and a scan keeps current;
  Gatekeeper's are in the constraint's status, cut at 20 for each constraint.
- **Cost.** Gatekeeper requests almost five times the memory, for the same number of pods; Kyverno has more
  definitions and objects, and its release runs hook Jobs that Gatekeeper's, with its hooks switched
  off here, does not.
- **Priority.** The Gatekeeper chart runs both its Deployments at `system-cluster-critical`, a
  priority that can preempt workloads, and renders the quota its namespace needs for it; Kyverno's
  pods keep the default. Gatekeeper's `--default-create-vap-for-templates` is on, and acts only on a
  template with CEL source: all three here are Rego, which the test asserts, so it makes no
  ValidatingAdmissionPolicy, as Kyverno's generation is off.
- **Install order.** Kyverno's kinds are the release's. Gatekeeper's constraint kinds exist after
  the templates reconcile, which costs one retry of the rules' Kustomization.

## Flux itself

The Flux Operator and the `FluxInstance` it runs Flux from are the cluster directory's two
applications, `flux-system/flux-operator/` and `flux-system/flux-instance/`, the only ones outside
`apps/`. Each has the application shape: `ks.yaml`, and in `app/` an `OCIRepository` for the
chart, the `HelmRelease`, its `values.yaml` generated into a ConfigMap that substitution leaves
alone, and `kustomizeconfig.yaml`, which points the release at that ConfigMap's hashed name. The
application rules apply with two differences: `sourceRef` is `OCIRepository` `flux-system`, as the
artifact generator publishes only `apps/base`, and `path` is
`./clusters/<cluster>/flux-system/<app>/app`. No application in `apps/base` may take their names.

- **Charts**: the operator's own `flux-operator` and `flux-instance` charts from
  `oci://ghcr.io/controlplaneio-fluxcd/charts`, at one version that Renovate moves together. Each
  `OCIRepository` refuses a chart without the keyless cosign signature of the publisher's release
  workflow on a version tag, the identity of the chart's row of `signatures.yaml`
  ([Signatures](#signatures)).
- **Instance**: upstream Flux 2.x, with source-watcher beside the four default controllers for
  the per-application artifacts, and Flux's network policies on. A patch of the instance sets the
  namespace `flux-system` to enforce the restricted Pod Security level ([Pod
  Security](#pod-security)), and `tests/pod-security.bats` evaluates against it the controllers of
  the pinned Flux CLI's install, with the instance's patches applied.
- **Flux versions**: the operator installs the newest Flux 2.x release in its manifests artifact,
  `oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests`, which the instance pins to the
  operator chart's version. Flux therefore moves only when that tag moves, in the same Renovate
  pull request as the two charts, and a person merges it (ADR 0009); `tests/flux.bats` fails when
  the tag and the operator chart's version differ.
- **Sync**: the instance generates an `OCIRepository` and a `Kustomization`, both named
  `flux-system` after its namespace, that read `oci://ghcr.io/eekaan/k8s-gitops/manifests` at the
  tag `main` every minute and apply `./clusters/<cluster>`. Its patches make the source verify the
  artifact's keyless signature: issued by GitHub Actions to this repository's
  `.github/workflows/publish.yaml` on `refs/heads/main`, the identity of the artifact's row, the
  first, of `signatures.yaml`. An artifact signed by a run on another branch or tag, or by another
  workflow, is refused (ADR 0003).
- **Metrics**: the operator's values set its report, and with it the metrics of the state of every
  Flux resource, to every 30 seconds. The monitors and the alerts are the `flux-monitoring`
  application's, not these two applications': Flux is installed before the monitoring definitions
  exist ([Flux monitoring](#flux-monitoring)).

### One root

The instance's `flux-system` Kustomization applies the cluster directory: the root `cluster` from
`ks.yaml`, and `flux-operator` and `flux-instance`. The root applies `apps/overlays/<cluster>` and
gives its children the defaults above; it is the one root of the applications. `flux-system` sits
above it, and nothing in the tree defines a source or Kustomization of that name, so no two
objects apply the same thing. The instance patches `flux-system` with the same SOPS `decryption`
and `postBuild.substituteFrom` (`cluster-config`, `cluster-secrets`) that the root gives its
children, so the cluster directory's `ks.yaml` files are substituted like everything else;
`just kubernetes-check` builds each cluster directory as that Kustomization does, with strict
substitution. `flux-operator` and `flux-instance` are not children of the root and get none of
its defaults. They set the same `decryption` and `postBuild.substituteFrom` themselves, which the
check requires, so what they apply is decrypted and substituted like the root's children; and
they set their own interval, retry interval, timeout, `wait` and pruning. Their `HelmRelease`
objects likewise get none of the release defaults and set their own upgrade remediation: a failed
upgrade is retried three times, then rolled back. `flux-instance` waits for `flux-operator`, whose
chart defines the `FluxInstance` kind.

Both Kustomizations prune, but what manages Flux is kept from it. Their `HelmRelease` and chart
`OCIRepository` objects carry `kustomize.toolkit.fluxcd.io/prune: disabled`: garbage-collecting
the operator's release would uninstall the operator, and the instance's release would take the
`FluxInstance` with it, on which the operator deletes Flux's controllers. The instance chart also
gives the `FluxInstance` `helm.sh/resource-policy: keep`, so even an uninstalled release leaves it
in place. The values ConfigMaps are still collected when a change of values replaces them.
Removing either Kustomization from the cluster directory's `kustomization.yaml` fails
`just kubernetes-check`, as the cluster directory must build exactly the root, `flux-operator` and
`flux-instance`.

### Controllers

The instance's patches give kustomize-controller `--sops-age-secret=sops-age`. The controller
reads the Secret `sops-age` from its own namespace, `flux-system`, and takes the age key from each
of its data keys whose name ends in `.agekey`, such as `age.agekey`. It decrypts with that key
every Kustomization that uses SOPS and names no Secret of its own in `decryption.secretRef`, which
in this tree is every one. Like `cluster-config` and `cluster-secrets`, the Secret exists before
Flux does and nothing in the tree creates it; until it exists, every Kustomization that decrypts
fails, the root and Flux's own included. `just cluster-config` applies all three
([Before Flux starts](#before-flux-starts)).

Flux 2.10 still gates `ExternalArtifact` sources, which source-watcher produces, behind a feature
gate on kustomize-controller and helm-controller. The operator turns the gate on by itself
whenever source-watcher is among the instance's components, so the instance does not patch it.

`tests/flux.bats` renders both charts with these values, pulling each chart once, and applies the
instance's patches to the pinned Flux manifests to check the sync source, its signature identity,
the components and the age-key flag.

## Publishing

`.github/workflows/publish.yaml` publishes this tree as `oci://ghcr.io/eekaan/k8s-gitops/manifests`,
the artifact the instance syncs. It runs on every push to `main` that changes `kubernetes/` or the
workflow itself, and by hand (`workflow_dispatch`); never for a pull request, which gets neither
write access to packages nor an identity token. Its one command is `just publish`, which runs
`scripts/publish` on the runner rather than in the Dagger module, as signing takes the job's own
identity token (ADR 0007). The script refuses to run anywhere else: without GitHub Actions and the
job's identity token it stops before calling anything, so nobody signs from a laptop. In order, it:

1. runs `just kubernetes-check` on the commit it publishes, with the pinned tools the workflow
   installs; a failure stops the run, with the check's own message, before the registry is touched;
2. logs in to ghcr.io with the job's token on standard input, into a Docker configuration of the
   run's own, which flux and cosign both read and which is removed when the run ends;
3. pushes `kubernetes/`, without any cluster's `secrets/`, with `flux push artifact`, tagged with the
   full commit SHA, with the repository as its source and `<branch>@sha1:<commit>` as its revision,
   reproducibly; a reported digest that is not `sha256:` and 64 hexadecimal digits stops the run;
4. signs that digest keyless with cosign: a short-lived certificate for the job's identity, recorded
   in Sigstore's public transparency log;
5. verifies the signature against the identity of this workflow at the run's ref, which on `main`
   is the identity the instance accepts; a failure stops the run;
6. tags that digest `main`.

A pull request's checks run against its branch as it was pushed; the publish run judges the tree
that is on `main`, and only its own: the check runs on the commit the run publishes and on no other.
When that tree does not build, the run fails, nothing is pushed, signed or tagged, and the cluster
stays on the last tagged artifact until a run for a later commit that changes `kubernetes/` or the
workflow, or a manual run, publishes a tree that does. The gate is `just kubernetes-check`, the
offline build, and no more: `just render-check` pulls charts from the network and needs helm in the
job that signs, so it stays out of that job, and so does `just kubernetes-validate`, which pulls the
charts and fetches schemas and definitions as well ([What the checks refuse](#what-the-checks-refuse)).

Every workflow installs its tools with the same pinned `mise-action` at an exact mise release. A
workflow whose token can write, `publish`, `tools-image` and `render-comment`, also gives the action the
checksum
of that release's linux-x64 binary, so the tools that run beside the token are the pinned ones; the
action fails the job when the binary differs. A bump of the mise version changes the checksum with it,
in every workflow that has one, and the checksum is the one for `./mise-v<version>-linux-x64` in the
release's `SHASUMS256.txt`. Renovate's github-actions manager reads both inputs as one dependency,
`jdx/mise`, but to move the checksum it first fetches the current release by the tag the version is
written as, and the version is written without the `v` that mise's release tags carry: that lookup
fails, so Renovate proposes nothing for a workflow with a checksum. For `ci.yaml`, which has none, it
would move the version alone, which `tests/ci.bats` refuses, as the publish workflow's mise must be
CI's. A package rule in `.renovate/managers.json5` tells Renovate not to propose `jdx/mise` while its
version has that form, and the bump is by hand, in every workflow at once (`.renovate/by-hand.tsv`).
The two jobs that sign, `publish` and `tools-image`, also turn the action's cache off, so nothing
runs from an entry another job saved.

The tag moves last and by digest: `main` only ever names an artifact that is signed and verified,
and signing, verifying and tagging all name it by its digest, so the tag ends on exactly the bytes
that were signed and verified; a tag can change between two steps, a digest cannot. It moves only on
a run on `refs/heads/main` for which no newer commit on `main` changes `kubernetes/` or the
workflow, so an older run, a re-run of one included, never moves it back; the newest such commit's
own run decides, and a run does not judge a newer commit's tree. That leaves two cases in which the
tag stays on an older artifact than the newest passing commit's. In the first, a newer commit
that changes `kubernetes/` arrives before the passing commit's run reaches the tag, and fails its
check: the passing commit's run leaves the tag alone and the failing one publishes nothing, and the
same happens when GitHub replaces the passing commit's waiting run with the failing one's. In the
second, a re-run of an older run starts while the passing commit's run is waiting, and GitHub
replaces the waiting run with the re-run, which leaves the tag alone, as the passing commit is newer
than its own. In both, the tag stays where it was until a later run publishes a tree that passes:
the run of the next commit that passes, or, in the second case, a manual run as well. Runs
share one concurrency group that never cancels a run in progress, so they never overlap: a run that
starts while another is in progress waits for it, and GitHub replaces a waiting run with a newer one.
A run on another branch, or one a newer commit overtook, such as a re-run of an
old one, still pushes, signs and verifies, says why the tag stayed where it is, and succeeds. An
artifact signed by a run on another branch carries that branch's identity, which the instance
refuses. The run prints
its steps, the digest and whether the tag moved.

The signing identity is this workflow file on that branch: the subject
`https://github.com/eekaan/k8s-gitops/.github/workflows/publish.yaml@refs/heads/main` from the
issuer `https://token.actions.githubusercontent.com`, which the instance requires
([Flux itself](#flux-itself)). Renaming the workflow file, or publishing from another branch,
changes the identity, so the instance's patch changes in the same change, and the artifact's row of
`signatures.yaml` with it. `tests/publish.bats` fails when the identity the script verifies and the
one the instance's values accept differ, and `just signatures-check` when the patch and the row do.

The package must be public for the cluster to pull it without credentials. GitHub makes a new
package private, and a package linked to its repository takes the repository's access permissions
but not its visibility, so the package's visibility is set to public in its settings once, after
the first run; until then the cluster cannot pull it. A public package cannot be made private
again.

## Signatures

`signatures.yaml` at the repository's root lists every source a chart comes from, the artifact the
cluster syncs and the tools image the checks run in, one row each, and how it is signed: keyless,
by one identity that the certificate of its signature holds; with a key, whose public key is a file
under `signatures/`; or not where Flux looks, with the reason. Its header gives each kind's fields.
A source signed keyless whose row has no `cluster: false` is verified before merge and, through the
`verify` block of its `OCIRepository`, by Flux on the cluster; every other row is checked before
merge alone, or is unsigned. Who signs each:

| Source | Signed by | Verified | Why |
|---|---|---|---|
| `oci://ghcr.io/eekaan/k8s-gitops/manifests` | eekaan/k8s-gitops, `publish.yaml` on `main` | before merge and by the cluster | the artifact the cluster syncs, signed by the publish run |
| `oci://ghcr.io/eekaan/k8s-gitops/ci-tools` | eekaan/k8s-gitops, `tools-image.yaml` on `main` | before merge alone | the checks run in it, and nothing on the cluster pulls it |
| `https://charts.fairwinds.com/stable` | — | unsigned | a Helm repository: Flux verifies none of its charts |
| `https://crowdsecurity.github.io/helm-charts` | — | unsigned | a Helm repository: Flux verifies none of its charts |
| `https://ctrliq.github.io/ascender-operator` | — | unsigned | a Helm repository: Flux verifies none of its charts |
| `https://open-policy-agent.github.io/gatekeeper/charts` | — | unsigned | a Helm repository: Flux verifies none of its charts |
| `oci://docker.io/envoyproxy/gateway-helm` | — | unsigned | Envoy Gateway signs its image, not its chart |
| `oci://ghcr.io/bjw-s-labs/helm/app-template` | bjw-s-labs/helm-charts, `chart-release-steps.yaml` on `main` | before merge and by the cluster | the publisher signs keyless; four applications read it |
| `oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg` | cloudnative-pg/charts, `release-publish.yml` on `main` | before merge and by the cluster | the publisher signs keyless |
| `oci://ghcr.io/cloudnative-pg/charts/plugin-barman-cloud` | cloudnative-pg/charts, `release-publish.yml` on `main` | before merge and by the cluster | the publisher signs keyless |
| `oci://ghcr.io/controlplaneio-fluxcd/charts/flux-instance` | controlplaneio-fluxcd/charts, `release.yml` at a version tag | before merge and by the cluster | the publisher signs keyless |
| `oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator` | controlplaneio-fluxcd/charts, `release.yml` at a version tag | before merge and by the cluster | the publisher signs keyless |
| `oci://ghcr.io/dexidp/helm-charts/dex` | — | unsigned | no signature; the publisher says nothing about signing |
| `oci://ghcr.io/emberstack/helm-charts/reflector` | — | unsigned | no signature; the publisher says nothing about signing |
| `oci://ghcr.io/external-secrets/charts/external-secrets` | external-secrets/external-secrets, `helm.yml` on `main` | before merge and by the cluster | the publisher signs keyless |
| `oci://ghcr.io/falcosecurity/charts/falco` | falcosecurity/charts, `release.yml` on `master` | before merge and by the cluster | the publisher signs keyless |
| `oci://ghcr.io/grafana/helm-charts/grafana-operator` | — | unsigned | no signature; the publisher says nothing about signing |
| `oci://ghcr.io/home-operations/charts-mirror/descheduler` | home-operations/charts-mirror, `app-builder.yaml` on `main` | before merge and by the cluster | the mirror signs keyless |
| `oci://ghcr.io/home-operations/charts-mirror/external-dns` | home-operations/charts-mirror, `app-builder.yaml` on `main` | before merge and by the cluster | the mirror signs keyless |
| `oci://ghcr.io/home-operations/charts-mirror/keda` | home-operations/charts-mirror, `app-builder.yaml` on `main` | before merge and by the cluster | the mirror signs keyless |
| `oci://ghcr.io/home-operations/charts-mirror/metrics-server` | home-operations/charts-mirror, `app-builder.yaml` on `main` | before merge and by the cluster | the mirror signs keyless |
| `oci://ghcr.io/home-operations/charts-mirror/volsync` | home-operations/charts-mirror, `app-builder.yaml` on `main` | before merge and by the cluster | the mirror signs keyless |
| `oci://ghcr.io/kyverno/charts/kyverno` | — | unsigned | signed into another repository, which Flux cannot read |
| `oci://ghcr.io/oauth2-proxy/charts/oauth2-proxy` | oauth2-proxy/manifests, `release.yaml` on `main` | before merge and by the cluster | the publisher signs keyless |
| `oci://ghcr.io/open-feature/charts/open-feature-operator` | a key, `signatures/open-feature-operator.pem` | before merge alone | a key the publisher does not publish; no key's block is built |
| `oci://ghcr.io/openbao/charts/openbao` | openbao/openbao-helm, `release-chart.yml` on `main` | before merge and by the cluster | the publisher signs keyless |
| `oci://ghcr.io/piraeusdatastore/piraeus-operator/piraeus` | — | unsigned | no signature; the publisher says nothing about signing |
| `oci://ghcr.io/postfinance/charts/kubelet-csr-approver` | — | unsigned | no signature; the publisher says nothing about signing |
| `oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack` | — | unsigned | Helm provenance with a PGP key, which Flux does not verify |
| `oci://ghcr.io/prometheus-community/charts/prometheus-blackbox-exporter` | — | unsigned | Helm provenance with a PGP key, which Flux does not verify |
| `oci://ghcr.io/prometheus-community/charts/prometheus-operator-crds` | — | unsigned | Helm provenance with a PGP key, which Flux does not verify |
| `oci://ghcr.io/spegel-org/helm-charts/spegel` | spegel-org/spegel, `release.yaml` at a version tag | before merge and by the cluster | the publisher signs keyless |
| `oci://ghcr.io/stakater/charts/reloader` | stakater/Reloader, `push-helm-chart.yaml` on `master` | before merge and by the cluster | the publisher signs keyless |
| `oci://ghcr.io/vectordotdev/helm-charts/vector` | — | unsigned | no signature; the publisher says nothing about signing |
| `oci://ghcr.io/victoriametrics/helm-charts/victoria-logs-single` | VictoriaMetrics/helm-charts, `release.yaml` on `master` | before merge and by the cluster | the publisher signs keyless |
| `oci://gsoci.azurecr.io/charts/giantswarm/silence-operator` | a CircleCI pipeline of Giant Swarm's project | before merge and by the cluster | the publisher signs keyless, from CircleCI |
| `oci://quay.io/cilium/charts/cilium` | cilium/cilium, `release.yaml` on `main` | before merge and by the cluster | the publisher signs keyless |
| `oci://quay.io/jetstack/charts/cert-manager` | a key, `signatures/cert-manager.pem` | before merge alone | signed over SHA-512, which source-controller cannot verify with a key |

### What the checks do

- `just signatures-check`, a check of the `static` group, offline. It runs `just kubernetes-check`'s
  builds first, and stops when they fail, and reads the sources from them: every application,
  enabled or not, and each cluster directory, after kustomize and after Flux's substitution with
  `--strict-substitute`. A source is the `url` of an `OCIRepository` or a `HelmRepository`, the
  artifact the FluxInstance syncs, read from the values the `flux-instance` application builds into
  its ConfigMap, or the tools image, by the name `scripts/tools-image` publishes; the objects of one
  url share a row. The check fails, naming the source, and for an object its kind, namespace, name
  and file: a source without a row, a row no source uses, a source listed twice, rows out of order,
  a field missing, unknown or not one line of text; a `HelmRepository` whose row is not unsigned, as
  a chart an https Helm repository serves is unsigned by its kind; a `HelmRepository` of type `oci`,
  a `Bucket` or any other kind of `source.toolkit.fluxcd.io` it has no rule for; an `OCIRepository`
  whose ref is neither a tag nor a digest; a key that is not a file directly under `signatures/`
  holding one PEM public key, a file there no row names, and a key row without `cluster: false`; an
  identity outside the grammar below; and a `verify` block that is not its row's. Every
  `OCIRepository` whose row is keyless without `cluster: false` has `spec.verify` exactly
  `provider: cosign` and one `matchOIDCIdentity` entry of the row's `issuer` and `subject`, byte for
  byte, with no `secretRef` and nothing else, and so does the patch the FluxInstance's values put on
  its sync source, the one patch whose target selects it as kustomize selects, by patterns of kind
  and name; no other `OCIRepository` has a block. It needs what `kubernetes-check` needs.
- `just signatures-verify`, the one check of the group `signatures`, which needs the network. It
  runs the offline rules first and stops when they fail. Then, for each row, against the pins of the
  tree, an `OCIRepository`'s tag or digest, the sync source's ref and the digest `versions.yaml`
  records under `ci_tools_image` (with none recorded, the line says there is nothing to verify), it
  probes the registry's `/v2/` with curl and runs the pinned cosign: `cosign verify` with a keyless
  row's issuer and subject as its two regular-expression flags and nothing else, which is what Flux
  matches, no claim Flux has no field for; with a key row's key, the transparency log not consulted
  (`--insecure-ignore-tlog`), as source-controller does not consult it for a key, and the row's
  digest algorithm; and for an unsigned OCI row, a lookup with an identity no certificate holds,
  which passes only when cosign answers that there is no signature at all. A Helm repository's row
  fetches nothing. It prints one line per row, `pass`, `FAIL` or `skip`, the source and how it was
  verified or why it failed, and nothing else, then exits non-zero if any row failed.

`signatures-verify` is a group of its own, outside `static`, so `just checks`, `just ci` and CI run
both, CI as two jobs: a registry that cannot be reached fails `signatures` with its reason and
leaves `static`'s result its own, and the required check `ci` stays red until a re-run verifies. The
publish run runs neither: its gate is `just kubernetes-check` ([Publishing](#publishing)).

The verification fails closed. Only cosign's exit 0 verifies, and only its own outcome "no
signatures found", exit 10, counts as unsigned. The pinned cosign, 3.1.4, has exit codes of its own
for no signature (10), a tag that is not there (11), a signature that does not match (12) and one
without a certificate (13), for a signature at the signature tag (`cmd/cosign/errors/exit_codes.go`,
`exit_code_lookup.go`, given in `cmd/cosign/cli/verify/verify.go` by `WrapError`); a signature in a
Sigstore bundle that does not match, an unreachable registry, a refused request and a rate limit
all exit 1. A registry's error does not end as "no signatures found": cosign resolves the pinned
tag first, and any answer but the manifest is an error there, a missing tag's 404 exit 11; at the
signature tag only a 404 reads as no signature, and any other answer is an error
(`pkg/oci/remote/signatures.go`). The bundle lookup comes first, and when it fails for any reason
cosign looks at the signature tag, as source-controller does, so a registry that refused the
referrers call alone and then answered the rest would leave a bundle unseen, on the cluster as here.
Before cosign runs, the check asks the registry's `/v2/` (Docker Hub's registry is
`registry-1.docker.io`, not `docker.io`): one that does not answer within 20 seconds or cannot be
resolved fails that source as "the registry <host> could not be reached", one that answers 429
as "limits anonymous requests", and a 5xx as unreachable too. Every other failure of cosign fails
with a reason of the check's own, chosen from its exit code and the time it took, never from what it
printed: the signature does not match, a signature where the row says unsigned, no signature where
the row names one, a tag that is not there, a cosign that did not finish within its `--timeout`
(`SIGNATURES_VERIFY_TIMEOUT` seconds, 120 when unset), or a failure with no outcome of its own.
Every row is checked; there is no retry beyond cosign's own.

cosign runs with none of the caller's secrets (`scripts/lib/tools.sh`), in a home, a Docker
configuration with no login in it and a TUF root of the run's own, without `REGISTRY_AUTH_FILE` and
podman's places, and without any variable `cosign env` lists, among them `COSIGN_REPOSITORY`, which
moves where a signature is read from, and the `SIGSTORE_*` files and `TUF_*` settings, which change
what is trusted. It runs `verify` and no other subcommand. Nothing it prints reaches the output: its
error for a host that does not resolve names the resolver's address.

An issuer is `^`, a literal with every dot escaped, and `$`. A subject is `^`, a literal with every
dot escaped up to and including the `@` that begins its ref (the whole subject, for an identity
without a ref), the ref, which alone may hold a bracket expression, a quantifier or a group with an
alternation inside it, and `$`, the subject's only `$`; no bare dot, backslash class, lazy
quantifier or flag group. That is syntax Go's regular expressions and POSIX extended ones read
alike, so what bash matches in the tests is what Flux and cosign match. Both compile the patterns
with Go's `regexp.Compile` and match them with `MatchString`, unanchored (cosign's
`pkg/cosign/verify.go` for a signature at the signature tag, sigstore-go's
`pkg/verify/certificate_identity.go` for a bundle; source-controller hands its `matchOIDCIdentity`
to them as `IssuerRegExp` and `SubjectRegExp`), so a pattern without its anchors also accepts a
longer identity, such as another repository's workflow whose path ends the same way. And a block
with an empty `matchOIDCIdentity` checks no identity of a signature at the signature tag: any
certificate of Sigstore's public authority passes (`CheckCertificatePolicy` checks identities only
when there are some), which is why every block names exactly one.

### What Flux's verification needs

The FluxInstance pins Flux's manifests to the operator's version, and at the version its values
pin, `flux-operator-manifests:v0.62.1`, the distribution installs source-controller v1.10.1 and
helm-controller v1.7.1 (`flux/v2.10.0/source-controller.yaml` and `helm-controller.yaml` of that
artifact). That source-controller is built with cosign v3.1.4, the version `mise.toml` pins for the
check (its `go.mod`). What this section says of the controllers is read at those versions and moves
with those two pins; no test holds them together, so a bump of the operator's manifests artifact or
of cosign is read against the same sources again.

For a keyless block source-controller looks for a Sigstore bundle among the artifact's referrers,
through the registry's referrers API or the referrers tag, and otherwise for a signature at the
signature tag (`internal/oci/cosign/cosign.go`, `Verify`), as the pinned cosign's `verify` does
(`cmd/cosign/cli/verify/verify.go`), so a row the check verifies is one the controller can verify; a
source the check could verify only with something the controller does not do takes `cluster: false`
instead of a block. For a key it builds a verifier over SHA-256 alone and does not consult the
transparency log (`NewCosignVerifier`), so cert-manager's chart, signed over SHA-512, has no block.
The controller needs the registry and Sigstore's TUF repository. The trusted root a bundle is
verified with it loads once, and while that fails retries at most once a minute; what a signature
at the signature tag is verified with, the transparency log's and certificate logs' keys and the
authority's certificates, it reads for every verifier it builds, through cosign's older TUF client,
which retries a failed update on every call, with no such limit (`NewCosignVerifier`:
`GetRekorPubs`, `GetCTLogPubs`, `fulcio.GetRoots` and `GetIntermediates`); only a failed start of
that client, which reads its local store and not the network, lasts until the controller restarts
(`pkg/tuf/client.go` of `sigstore/sigstore` v1.11.1, which its `go.mod` takes). It asks the
transparency log only about a signature that does not carry its entry. It reaches them through
`flux-system`'s egress, which Flux's own `allow-egress` policy leaves open
([What the namespaces let through](#what-the-namespaces-let-through)), the egress the sync source's
and Flux's two charts' verification take, so no policy or exception changes for the other blocks. A
rotation of Sigstore's public keys is not noticed, and a verified revision is not verified again
until it, or the object's spec, changes (Flux's documentation of `OCIRepository` verification).

Flux's substitution leaves the patterns as they are written: it substitutes `${var}` alone, and a
`$` not followed by `{` stays (`fluxcd/pkg/envsubst`, `parse/scan.go`), so a pattern ending in `$`
reaches the cluster as written, which `just signatures-check` proves on the builds. A `$$` would
come out as `$`; the grammar allows one `$`. The FluxInstance's values, which hold the sync source's
patch, are in a ConfigMap substitution leaves alone.

No step of a rebuild applies a block before it can verify. Of the applications installed with helm
before Flux, from the `url` and `ref` of their `ocirepository.yaml`
([Applications installed before Flux](#applications-installed-before-flux)), Cilium, the Flux
Operator and the Flux instance have blocks, which helm does not read; Flux applies them once it
runs, over the pod network Cilium already gives. The kubelet serving certificate approver, installed
the same way, is unsigned and has none.

### When a verification fails

source-controller verifies an `OCIRepository` with a block when its revision changes, when its spec
changes, which adding or changing a block does, when the last verification failed, and when the
verification policy changes (`internal/controller/ocirepository_controller.go`, `reconcileSource`).
A verified revision reports `SourceVerified` `True`, reason `Succeeded`; a failed one
`SourceVerified` `False` and `Ready` `False`, reason `VerificationError`, and the controller keeps
the artifact it holds and pulls nothing new. A failure leaves the object's observed generation where
it was. helm-controller then treats the source as not ready while its generation is newer than the
one observed (`isSourceReady` and `isReady` in `internal/controller/helmrelease_controller.go`):

- after a change of the spec, a block added or changed, every HelmRelease that reads the source
  reports `SourceNotReady` and changes nothing, so the release that runs stays as it is and is
  neither upgraded nor removed. An application whose Kustomization waits (`wait: true`) fails its
  health check on the source, and every Kustomization that names it in `dependsOn`, directly or
  through others, waits;
- after a new revision of an unchanged spec, a tag moved to an artifact signed otherwise, the source
  keeps its artifact, and helm-controller goes on reconciling the release from it, so the release
  that runs stays as it is. The source also reports `Reconciling` `True`, reason
  `ProgressingWithRetry` (`internal/reconcile/reconcile.go`), which the health check of a
  Kustomization reads as still in progress: an application whose Kustomization waits fails its
  health check at its next reconcile, and every Kustomization that names it in `dependsOn`,
  directly or through others, waits, as after a change of the spec.

The artifact is kept while source-controller's pod runs: its storage is an `emptyDir`
(`flux/v2.10.0/source-controller.yaml`), so a new pod, after a Flux upgrade or a drained node,
holds none, the object's artifact is cleared (`reconcileStorage`), and the source pulls it again
only once it verifies. Until then every HelmRelease that reads it reports `SourceNotReady`, as the
source has no artifact, and nothing reconciles the release, which goes on running as it is.

A source fires `FluxSourceNotReady` after 15 minutes, the sync source `FluxRootSyncNotReady` after
10, and a release or Kustomization that stops with it `FluxApplierNotReady` ([Alerts](#alerts)).
`just cluster-signatures` reads the cluster's `OCIRepository` objects and says, for each, whether it
is as its row says: one the cluster verifies has exactly its row's block, reports `SourceVerified`
`True` for its current generation and is Ready for that generation, and any other has no block. It
prints `pass` or `FAIL`, the namespace and name and one line of why, with the condition's reason,
never a message or an address, and exits 0 only when none fails.

A pin whose signature no longer matches its row, because its publisher's identity changed or another
identity signed it, is handled as a possible compromise, and its block stays: the release keeps the
artifact it runs. `just signatures-verify` fails such a pin as well, with `cluster: false` or
without, so no pull request that only takes the block out passes `ci`; and without the block,
source-controller would pull the artifact that failed and helm-controller would upgrade the release
to it. Either the new identity is read from the publisher's page and from the certificate of the
signature, and once it verifies the row and the block change to it in one pull request, as in
[Adding a source](#adding-a-source), or the source is pinned to a digest whose signature still
verifies with the row.

### Taking a block out

A block is taken out only for a signature the pinned controller cannot read though the check
verifies it. A refused signature and a controller that cannot reach what verification needs both
set `SourceVerified` and `Ready` `False` with reason `VerificationError` (`reconcileSource`, which
wraps every error of `NewCosignVerifier` and `Verify` alike), so read the message first:
`flux get sources oci --namespace <namespace>` shows `Ready`'s, which on a failed verification is
`SourceVerified`'s, and `kubectl --namespace <namespace> describe ocirepository <name>` shows both.

- A message that the verifier could not be built (`unable to initialize trusted root`,
  `unable to get Rekor public keys`, `unable to get CTLog public keys`,
  `unable to get Fulcio root certs` or `intermediate certs`, `unable to create Rekor client`), one
  that names a network error, a timeout or a registry's error, and `no signatures found`, which a
  failed referrers call can also end in, as the controller then looks at the signature tag alone,
  are the cluster's reach. The block stays, the reach is fixed
  ([What Flux's verification needs](#what-fluxs-verification-needs)), and the controller retries
  by itself, the trusted root at most once a minute, and verifies the source once it reaches them.
- A message that no signature matched, `no matching signatures` or `no matching attestations` and
  why, with no network error in it, is a signature the controller refused. The block is taken out
  only if `just signatures-verify` passes the row at that same digest: the revision the object
  reports, its artifact's or the new one its `Reconciling` message names, with the source pinned
  to that digest for the run if its tag has moved since.

One pull request removes the block from every `OCIRepository` of the source's url, four files for
app-template's row, and gives the row `cluster: false` with the reason, what the cluster showed
when it refused the signature. `just signatures-check` accepts exactly that, and refuses a block
removed alone or from only some of a url's objects. Once applied, the object's new generation has
no block: source-controller removes its `SourceVerified` condition and reconciles as an unsigned
source, Ready with the artifact of its tag, and `just cluster-signatures` passes it as verified
before merge alone. `just signatures-verify` goes on verifying the row, so a mismatch still shows
before merge. A pin that fails `just signatures-verify` as well is not taken out
([When a verification fails](#when-a-verification-fails)).

### Adding a source

A new `OCIRepository` or `HelmRepository` url, a new sync source or another tools image name gets
its row in the same change, in its place in the order. Read the publisher's page on signing, then
run the pinned cosign anonymously, as the check does, against the pinned tag: a keyless signature's
identity is the one the page states, or the one cosign names when an identity does not match; a key
is the one the publisher's page gives, or, where the publisher gives none, as OpenFeature does, the
one the transparency log entry of its signature records, which the row's `from` says; with no
signature, the row is unsigned and says what the page says. A keyless row's pattern verifies the
pinned tag and the release before or after it, and fails with one character of the subject's
repository changed, before its block is added, with the comment the other blocks have.
`just signatures-check` and `just signatures-verify` pass.

What the checks do not cover: images, admission, the charts the bootstrap installs with helm before
Flux runs, a source's own content beyond its signature, and commits of a `GitRepository`, which hold
no chart and have no row; a signature in a repository other than the source's own, such as
Kyverno's, is not read.

## The render diff

A manifest change reaches the cluster only by merging (ADR 0003), so every pull request gets one
comment, updated on each push, that shows what Flux would apply differently once it is merged: a
table with the objects each application adds, removes and changes, then each changed application's
diff, collapsed. A pull request that changes nothing Flux applies says so.

`just render <out> [dir]` renders a tree as Flux applies it, offline, one file per object under
`<out>/<cluster>/<application>/`: the cluster directory as the instance's sync Kustomization applies
it (application `flux-system`), then every Kustomization that applies from the tree, the root
(`cluster`), Flux's own applications and each application the overlay enables, built as
`just kubernetes-check` builds them. Each HelmRelease is expanded to the objects its chart renders:
the chart its OCIRepository names at its tag, or the one its `chart.spec` names in a `HelmRepository`
(a classic `https://` repository or an OCI one) at an exact version, pulled from its public source at
the version the tree pins, with the values of its ConfigMaps and its own values over them, the
release name and namespace helm-controller gives it, the Kubernetes version in `versions.yaml`, every
API version a definition in the render serves, its post-renderers and helm-controller's labels. A
chart version bump therefore shows the objects that change. A definition is an
`apiextensions.k8s.io/v1` `CustomResourceDefinition` whose group, kind and versions have the shapes
the API server requires, and only its served versions count; an object that is only called one
names no API. A well-shaped definition in the tree, or in a chart, does name its versions, which is
what the cluster would serve once it is applied. Objects are selected by their exact name and
namespace, as the controllers look them up: a `valuesFrom` or chart source named `x-*` selects
nothing that is not called `x-*`. A `valuesFrom` entry whose ConfigMap is not in the application, or
whose `valuesKey` the ConfigMap does not hold, fails the render naming the release, the ConfigMap
and the key, as helm-controller fails the release, unless the entry is `optional`, which both skip.
A HelmRelease whose name is not a DNS subdomain or whose
namespace is not a DNS label is refused, naming its file (or its application's directory), before
anything is read from it. The render reads the tree's `kubernetes/` and `versions.yaml` alone, and
refuses a tree from which a build would read outside it, or a document a tool would read otherwise
than the render, naming the file and the key ([What the checks refuse](#what-the-checks-refuse),
Paths). An application may take its chart only
from an `OCIRepository` (at a tag) or a `HelmRepository` (at an exact version), from a source that
names no credential (the render has no secrets), with values from ConfigMaps of the application; any
other form (a version range, a `GitRepository` or `Bucket`, a `secretRef`, values from a Secret, a
post-renderer patch that names a file, a key that folds to a field the render reads) fails the
render, naming the release.
`scripts/render --forms` checks that every release is of a form the render accepts, without pulling
a chart, and `tests/render.bats` runs it on this tree.
A chart's output is parsed strictly, as helm-controller decodes what a release renders: a mapping
that repeats a key, at any depth and in any document, fails the render, naming the application, the
release, the object (its kind and name, or its place among the documents when it has neither) and
the key. helm-controller passes the output through kustomize's libraries in its post-renderers,
which always run, at least to label each object with its origin; their `yaml.v3` decode of each
object refuses a key whose text repeats and fails the install. helm's template step, `yq` and `jq`
keep the last one, so the tree's other checks never see it. Two parses of pinned tools read the
output before the release's post-renderers: kubeconform's strict parse (`-strict`, with no schema
location that holds a schema, so nothing is validated or fetched), which reads a key as the YAML
1.1 value it stands for, compares the values and names a key as it reads it, a string quoted and a
number or a boolean bare; and kustomize's decode, helm-controller's own,
which compares the keys' text and quotes it, so that `80` beside `"80"`, or `true` beside `"true"`,
is refused by it alone. That decode is a `kustomize build` of the output with a JSON patch that
copies each object's kind onto itself: kustomize decodes an object whole to patch it, and does so
before a build folds a repeated annotation. Both read the chart's output as it renders with
Kubernetes' own API versions alone and with those of every definition the tree installs, as
helm-controller renders with what the cluster serves at the time, so a key a chart repeats only
while an API is served, or only while it is not, is refused too. The render also refuses output
helm-controller would install:

- `yes` beside `on`, or `0x10` beside `16`, which kubeconform reads as the same value;
- a mapping a YAML merge key (`<<: *base`) brings in, with a key of it set again beside the merge
  key, which kubeconform counts as a repeat;
- a repeat in a chart's `crds/` files, which helm-controller applies apart from the release,
  without its post-renderers;
- in a release with a kustomize post-renderer, repeated annotations, a repeated annotation key or a
  repeated `annotations` mapping, which that build folds into one, the last value kept, before the
  decode, unless one of its JSON patches targets the object: kustomize decodes an object it
  JSON-patches whole, so the build refuses the repeat then. A repeated label, or a repeat anywhere
  else, that build refuses.

What the post-renderers' kustomize build writes holds each key once, as the build refuses a repeat
or folds it, so it is not parsed again.
`RENDER_CHART_CACHE` names a directory to keep pulled charts in between renders. A tree that does
not render fails, naming the application. `just render-diff <base> <head>` prints the comment
comparing two renders.

What it is rendered with, and what it never shows:

- `cluster-config` and `cluster-secrets` are not in the repository: each cluster's
  `cluster-config.example.yaml` and `cluster-secrets.example.yaml` stand in for them, and the
  comment's footer says so.
- No Secret's data: every value of a Secret's `data` and `stringData` is replaced by `(redacted)`,
  keys kept, and sops' metadata is dropped, so a changed Secret value does not show. That includes
  the Alertmanager configuration, which the monitoring chart renders into a Secret.
- Values a chart makes up anew on every render, such as generated certificates and their CA
  bundles: the chart is rendered twice and every value that differs reads
  `(generated at render time)`, so they never show as a change.
- Sources outside the tree are not fetched: the Gateway API, snapshot and Envoy Gateway definitions
  show as the source and the inner Kustomization that apply them, not as the objects those apply.
- A diff longer than a comment holds is cut, and the comment says so: the smallest applications'
  diffs are shown whole, the next is cut, the rest are left out, and the table stays whole. The cut
  leaves room under GitHub's 65536 characters for the comment job's own line.

`just render-check`, one of the checks of `just ci`'s `static` group, renders the tree as the render
job does and keeps nothing, so a tree that does not render fails `just ci` as it fails the required
check. Pulling the charts and rendering take about half a minute.

In CI two jobs make it, in two workflows, so that nothing from a pull request ever runs with a token
that can write:

- The `render` job of `.github/workflows/ci.yaml`, part of the required check `ci`, runs for every
  pull request and push to `main` on a hosted runner, with the workflow's `contents: read` token and
  no secrets. For a pull request GitHub runs the pull request's own copy of the workflow, a fork's
  included, so the job is given nothing worth taking. `just ci-render` runs `scripts/render-pr` in
  the Dagger module (ADR 0007), in the tools container `just ci` uses, chosen the same way (README,
  The tools image). That image is public and pulled without credentials, and a record of any other
  image stops the recipe, so a pull request that runs the job in another one has changed the files
  the job runs, as it could change the module itself. The render covers the base, the first parent
  of the commit under test, and the commit itself, both with the base's `scripts/render` and
  `scripts/render-diff`, so that a pull
  request that changes only the tree is shown by the reviewed render code. A base without the render
  code, or one its own render code does not render, is rendered with the commit's, and the job's
  log says so. The job uploads the comment as the artifact `render-diff`.
- `.github/workflows/render-comment.yaml` runs when the CI workflow completes for a pull request,
  unless that run was cancelled. GitHub runs it from the default branch, with this repository's
  token, whatever the run it follows had, so it checks out only the default branch and runs
  `just ci-comment`, with `actions: read` to download the artifact and `pull-requests: write` to
  comment; mise installs its tools without that token. `scripts/ci-comment` treats the artifact as
  text: it refuses anything but one regular file, `comment.md`, that `scripts/lib/render-comment.sh`
  accepts byte for byte, a comment `scripts/render-diff` could have written, never runs it or prints
  it, and sends it as a JSON string. Outside the fenced diffs that grammar allows only the fixed text,
  and application names and counts of a strict shape, so no mention, reference, link, image or HTML
  renders in the bot's name. It finds the pull request by the head commit and repository the run was
  for, and posts nothing when that head has moved on or two pull requests have it. It updates the one
  comment of its own that starts with the marker, or creates it, and adds a line of its own naming
  the commit the diff describes. A run that left no artifact did not render: the job updates its own
  comment, if there is one, to say so in its own words. It is not a required check: a comment that
  fails to post blocks no merge. An artifact that unpacks to far more than it holds fills only this
  job's runner.

The comment is the pull request's own account of its change. GitHub runs a pull request's copy of the
CI workflow, so a pull request that changes the render code, the CI workflow, the justfile or the
Dagger module can make the comment say anything the grammar allows, such as that nothing changes
while its manifests do. Review of such a pull request reads the change itself and does not rely on
the comment.

## Before Flux starts

Flux needs four objects that nothing in the tree creates, all in `flux-system`: the namespace
`flux-system` itself; the ConfigMap `cluster-config` and the Secret `cluster-secrets`, which every
Kustomization substitutes variables from; and the Secret `sops-age`, which kustomize-controller
decrypts with ([Controllers](#controllers)).

`just cluster-config [cluster]` applies them through the cluster's kubeconfig
([cluster.md](cluster.md#recipes)). It checks everything first, naming each problem, and applies
nothing until all of it is right. Each object reaches kubectl on standard input and is applied
server-side, so a second run changes nothing; no value is printed, passed as an argument or
written to disk.

`cluster-config` is rendered at run time and never committed. Its keys are exactly those of
`clusters/<cluster>/cluster-config.example.yaml`: the recipe fails naming each key the example lists
that it cannot fill, and each key it would fill that the example does not list. A key a manifest
starts to use is listed in the example and given its source in `fill_cluster_config` in
`scripts/lib/cluster.sh` in the same change. The values come from:

- `CLUSTER_NAME`: the cluster's own name, the directory name of `clusters/<cluster>` and the
  argument of the recipes, which keeps the object storage paths of two clusters that share a bucket
  apart ([Backups and restores](#backups-and-restores)).
- `CLUSTER_DOMAIN`: the environment variable of that name, the domain the cluster's applications are
  published under, a lower-case DNS name.
- `CLUSTER_DNS_ZONE`: the environment variable of that name, the zone at the DNS provider that
  holds the domain, which external-dns selects by its name ([DNS records](#dns-records)): the
  domain itself or a name it is under, and `CLUSTER_DOMAIN` when it is unset or empty. A zone the
  domain is not under is refused.
- `BACKUP_BUCKET_PREFIX`: the environment variable of that name, the start of the backup buckets'
  names ([infrastructure.md](infrastructure.md#s3-keys-and-backup-buckets)).
- `S3_ENDPOINT` and `S3_REGION`: the object storage's S3 endpoint and region, `endpoints.s3` and
  `region` in `infra/openstack/backend.hcl`, where OpenTofu's state backend reads them. The endpoint
  is `https://`, a host name and an optional port, with nothing after them, as an S3 client reads a
  path there as the bucket.
- `NODE_CIDR`: `values.nodeSubnet` in `talos/<cluster>/talman.yaml`, which the cluster stack renders
  from the plumbing stack's node subnet and which the kubelets take their node addresses from.
- `NODE_NAME_REGEX`: the hostnames in that `talman.yaml`, joined with `|`, with a trailing number
  standing for any number: `lab-cp-1` becomes `lab-cp-[0-9]+`, so a node OpenTofu adds later, which
  it numbers after the others, matches as well.
- `SERVICE_RANGE`: `values.serviceRange` in that `talman.yaml`, the range `LoadBalancer` Services
  take their addresses from ([Service addresses](#service-addresses)).
- `BGP_CLUSTER_ASN` and `BGP_EDGE_ASN`: `values.bgp.clusterASN` and `values.bgp.edgeASN` there, the
  workers' and the edge routers' AS numbers.
- `BGP_EDGE_ADDRESS_1` and `BGP_EDGE_ADDRESS_2`: the two addresses of `values.bgp.edgeAddresses`
  there, the edge routers'.
- `GATEWAY_ADDRESS`: `values.bgp.gatewayAddress` there, the public Gateway's address in the service
  range, which the edge routers forward public traffic to.
- `EDGE_PUBLIC_ADDRESS_1` and `EDGE_PUBLIC_ADDRESS_2`: the two entries of the output `addresses`
  of the edge stack `sto2/edge`, the edge routers' public floating addresses, in the order the
  output gives them. They are the targets of every route's DNS records
  ([DNS records](#dns-records)). The recipe reads the output as `just gateway-check` does, and
  never prints it: it is sensitive, so only `tofu output -json` and `jq` see it, and tofu's errors
  go to the stack's errors file. It therefore needs what the edge stack's recipes need
  ([infrastructure.md](infrastructure.md#environment)), and refuses, naming both keys and the
  stack, while the stack has no outputs, as it refuses while `talman.yaml` has no BGP numbers: the
  stack is applied before the cluster's `cluster-config`. The recipe reads `sto2/edge` by that
  name, as `just gateway-check` does, whatever the cluster.

The cluster stack renders the six before the last two from the plumbing stack's numbers for BGP
([infrastructure.md](infrastructure.md#services-announced-over-bgp)).

`cluster-secrets` is decrypted from `clusters/<cluster>/secrets/cluster-secrets.sops.yaml` by sops,
with the Flux age key, straight into kubectl, when that file exists. Its keys must be exactly those
of `cluster-secrets.example.yaml`; sops encrypts values only, so the recipe reads them without
decrypting anything. Without the file an empty Secret is applied, which is all substitution needs,
and the example must list no key. Nothing in the tree lists `secrets/`, so Flux neither applies nor
prunes it, and publishing leaves `clusters/*/secrets/` out of the artifact
([Publishing](#publishing)): the artifact carries what Flux applies.

`sops-age` holds the Flux age key ([cluster.md](cluster.md#the-flux-age-key)) under the data key
`age.agekey`.

## Installing Flux

`just cluster-flux [cluster] [--reapply]` installs Flux on a cluster that has nodes and Cilium but
no Flux. It checks what `cluster-config` checks first, then:

1. It refuses a cluster that runs a FluxInstance already, as Flux manages itself from then on.
   With `--reapply` it applies the objects above again on such a cluster and installs nothing, as
   `just cluster-config` does.
2. It applies the objects above.
3. It installs `flux-operator` and then `flux-instance` from `clusters/<cluster>/flux-system/` with
   `install-app` ([below](#applications-installed-before-flux)), as the releases `flux-operator`
   and `flux-instance` in `flux-system`, which Flux adopts once it runs.
4. It waits up to ten minutes for the FluxInstance `flux` to report Ready, and prints the next
   step.

A run that stops once the FluxInstance exists is not run again: what keeps it from Ready is fixed
on the cluster, and from then on the operator and Flux take over.

## Applications installed before Flux

Some applications have to run before Flux can: the CNI, Cilium in `apps/base/kube-system/cilium/`,
as Flux cannot run before the cluster has a pod network, and Flux's own operator and instance. Each
is an application like any other, installed by a script first and adopted by Flux afterwards, and
the script reads it rather than a copy.

`just app-install <application directory>` runs `scripts/install-app` against the cluster the
`KUBECONFIG` environment variable names, for the directory that holds the application's `ks.yaml`
and `app/`. It takes the chart location and version from the application's `ocirepository.yaml`
and gives helm `values.yaml` as it is, then the values the HelmRelease sets itself, on standard
input, which helm merges over the first as helm-controller does. Where those use a variable, they
are what Flux makes of them: `install-app` reads the ConfigMap `cluster-config` from the cluster
and substitutes from its data alone with `flux envsubst --strict`, Flux's own substitution, so a
variable it does not hold and that has no default stops the install, named. The values reach
`flux envsubst` in its environment and leave it on a pipe.

The release is the one helm-controller makes of the HelmRelease: its `releaseName`,
`targetNamespace` and `storageNamespace` where it sets them, and otherwise the HelmRelease's name,
after its `targetNamespace` and a dash when it has one, in the HelmRelease's own namespace, the
`targetNamespace` of `ks.yaml`. A HelmRelease whose history would be kept in another namespace than
the release is refused, as helm keeps both in one. The script waits for the API server first, and
leaves a release that already runs that chart version with those values alone. Like the cluster
recipes, it refuses to run while `GODEBUG` sets `http2debug` ([cluster.md](cluster.md#environment)).

Once Flux manages a release, installing over it changes what Flux owns, and Flux undoes it at its
next reconcile. Flux's helm-controller labels every object it installs or upgrades with
`helm.toolkit.fluxcd.io/name` and `helm.toolkit.fluxcd.io/namespace`, naming the HelmRelease
(its post-renderer, in the helm-controller the pinned Flux runs), and helm keeps those objects in
the release's manifest. `install-app` reads that manifest with `helm get manifest` and refuses a
release whose objects carry the label, unless `--yes` is given:
`just app-install <application directory> --yes`, or `just cilium-install --yes`.

- `just cilium-install` runs `scripts/install-cilium`, which installs Cilium so and then waits for
  every node to be Ready.
- An application installed this way has a HelmRelease that names the release the script installs,
  so Flux upgrades that release instead of installing a second one. Cilium's sets `releaseName`,
  `targetNamespace` and `storageNamespace`; Flux's own leave them to helm-controller's defaults,
  `flux-operator` and `flux-instance` in `flux-system`.
- Substitution is disabled on the values ConfigMap, so the chart gets the same values on both
  paths, and a version change in `ocirepository.yaml` moves both.

The kubelet serving certificate approver, `apps/base/kube-system/kubelet-csr-approver/`, is also
such an application: until it runs, no kubelet has a serving certificate, so `kubectl logs` and
`kubectl exec` fail. Its HelmRelease sets `releaseName`, `targetNamespace` and `storageNamespace`
as Cilium's does, so Flux upgrades a release installed before it instead of installing a second
one. Unlike Cilium, it takes values from `cluster-config`, the name pattern and the node network,
through the HelmRelease's own values, which `install-app` substitutes as Flux does.
`just cluster-bootstrap` installs it so, after Cilium and once `cluster-config` is applied
([cluster.md](cluster.md#recipes)).

`just app-adoption <application directory> [cluster]` shows that Flux adopted such an application
as designed, through the cluster's kubeconfig as `just cluster-flux` uses it. Start it, then
`just cluster-flux`. It polls every `ADOPTION_INTERVAL` seconds, 10 when unset, until the
application's HelmRelease exists and is Ready for its current generation, for up to `ADOPTION_WAIT`
seconds, 900 when unset, and reads every node's Ready condition at each poll. A HelmRelease that is
stalled, or whose release or Helm tests fail, ends the wait with helm-controller's reason and
message. Then it prints pass or FAIL for each check, and exits 0 only when all of them pass:

- one release: exactly one Helm release has the HelmRelease's release name, in any namespace, so
  Flux did not install a second one;
- adopted: the release's first revision, installed before Flux, lacks the labels helm-controller
  gives the objects it installs, and the deployed revision has them, so helm-controller upgraded
  the release that was there;
- HelmRelease Ready: the HelmRelease is Ready, and its `status.history` gives the deployed revision
  the chart version in `ocirepository.yaml`, to which helm-controller appends the chart artifact's
  digest as build metadata; when the wait ended otherwise, what it waited for or the failure;
- nodes Ready: every node was Ready at every poll; a FAIL names each node that was not, and at how
  many polls.

It only reads, and prints object names: no node's address, no manifest, and none of kubectl's or
helm's own errors, which can name the API server's address. helm-controller's first revision may
restart the application's pods once: it renders the chart under that version with the digest, and
a chart that writes its version into its pod templates, as Cilium's does in the label
`helm.sh/chart`, changes every pod template.

`kube-system` exists before Flux does: its `namespace.yaml` only sets the namespace's labels, and
like every namespace it is never pruned.
