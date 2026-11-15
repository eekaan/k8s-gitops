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
  PostgreSQL cluster ([PostgreSQL](#postgresql)); `volsync` backs an application's volume up
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
`just renovate-check` and `just renovate-pins` fail, naming the file to change, until they hold.

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
  list is empty, as every kind of the tree has a schema: the check prints no listed kind, and
  `0 of listed kinds`.

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
  ConfigMap, Envoy Gateway's configuration ConfigMap, the Grafana resource's `spec.version` and
  the FluxInstance's `spec.distribution`.

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
| `demo` | default deny | `hello` takes the proxies on 8080; the backup movers resolve names and reach the object storage on 443; `volsync-demo` and the rest open nothing. |
| `envoy-gateway-system` | default deny | the controller, its webhook, its certificate job and the proxies, below. |
| `kromgo` | default deny | kromgo takes the proxies and the kubelet's probes on 8080 and Prometheus' scrape on 8081, and reaches the resolver and Prometheus on 9090. |
| `ai-system` | listed | an application whose allows are not written, not a namespace that cannot have the posture. n8n takes the proxies on 5678 and reaches its database, the resolver and whatever its workflows call outside; the PostgreSQL instances take n8n, each other and the operator, and reach the API server; the backup movers reach the object storage on 443. The proxies reach n8n's 5678 alone there and forward only to n8n's Service, PostgreSQL authenticates every client, Pod Security, node firewall. |
| `etcd-snapshots` | listed | an application whose allows are not written, not a namespace that cannot have the posture. The snapshot job takes nothing and reaches the Talos API through `talos.default`, the object storage, the hosts age's release is downloaded from (its URL redirects to a second host, which serves the file) and the resolver. Talos' own authorisation of its one role, Pod Security, node firewall. |
| `external-dns` | listed | an application whose allows are not written, not a namespace that cannot have the posture. external-dns takes Prometheus' scrape and the kubelet's probes on 7979 and nothing else, and reaches the API server, the DNS provider's API on 443 and the resolver. Its token, scoped to zone read and DNS edit on the cluster's one zone, its name filter, a ClusterRole that only reads, Pod Security, node firewall ([DNS records](#dns-records)). |
| `kube-system` | listed | Cilium's agent, its Envoy and its operator run in the host's network namespace; the resolver takes queries from every namespace; the pod-network workloads' flows are not yet enumerated. Node firewall, Pod Security. |
| `flux-system` | listed | the controllers' flows are not yet enumerated as allows; Flux's own network policies, which the operator makes at run time, and the operator's for its web interface, `flux-operator-web`, which the check reads and passes because the namespace is listed ([What the check refuses](#what-the-check-refuses)); Pod Security, node firewall. |
| `monitoring` | listed | Prometheus scrapes every namespace and the nodes, the node exporter runs in the host's network namespace, the API server calls the operator's webhook, the other flows are not yet enumerated. |
| `openbao`, `external-secrets`, `cert-manager`, `cnpg-system`, `keda`, `volsync-system` | listed | flows not yet enumerated: webhooks and APIs the API server calls, the store's clients, scrapes. Each entry says which, and what covers it. |
| `piraeus-datastore` | listed | the CSI node plugin runs in the host's network namespace; the satellites replicate over the pod network, and their flows are not yet enumerated. |
| `cilium-secrets` | listed | holds no pod. |

`network-policy-exceptions.yaml` is the list; its header says what an entry holds.

### What the namespaces let through

- **`envoy-gateway-system`.** The proxies (labels `app.kubernetes.io/name: envoy`,
  `app.kubernetes.io/component: proxy`, `app.kubernetes.io/managed-by: envoy-gateway`,
  `gateway.envoyproxy.io/owning-gateway-name: public`) take the world on 10080 and 10443, the
  container ports the controller derives from the listeners 80 and 443 by adding 10000, and the
  kubelet on 19003 and 19002: Envoy Gateway v1.10.0 probes the envoy container on its readiness
  port, 19003 (`internal/xds/bootstrap/bootstrap.go`,
  `internal/infrastructure/kubernetes/proxy/resource.go`), and the shutdown manager on 19002
  (`internal/cmd/envoy/shutdown_manager.go`); 19001 is the stats port and 19000 the admin port on
  the loopback. They reach the resolver, the controller on 18000 (xDS) and each backend the routes
  attached to the Gateway send to, by one rule each: the pods its Service selects, in its namespace
  while that carries `k8s-gitops/gateway: public`, on the container port the route sends to and no
  other: `hello` in `demo` on 8080, kromgo in `kromgo` on 8080 and n8n in `ai-system` on 5678.
  `tests/network-policy.bats` reads those ports from the render, from each route's backend through
  its Service's target port to the container port, and fails unless the rules name, in each
  labelled namespace, exactly them; it reads the proxies' egress in every form the evaluation
  reads, and fails on a port entry or a peer it cannot compare, a backend in a namespace without
  the label and a Service without a selector. What a pod of such a namespace takes is its own
  namespace's to say: in `demo`, `hello` on 8080, and in `kromgo`, kromgo on 8080. In
  `ai-system`, which is listed and so has no pod in default deny, every pod takes them on every
  port, so the proxies' rule is what keeps them from n8n's other ports and from every port of its
  database; PostgreSQL also authenticates every client. The controller takes the proxies on 18000
  and the kubelet on 8081, and reaches the resolver and the API server on 443 and 6443 (a Service's
  address is translated to the control plane's before policy applies). Its admission webhook takes
  the API server, the local host and other nodes' hosts on 9443, in a policy of its own with its
  reason (below). The
  certificate job reaches the resolver and the API server. No monitor of the tree scrapes the
  Gateway, so no scrape is allowed; a monitor that does adds its rule.
- **`demo`.** `hello` takes the proxies by their labels, not by their namespace, on 8080, so the
  controller is no path to it, and the kubelet's probe. The backup movers, the pods VolSync labels
  `app.kubernetes.io/created-by: volsync` for every application of the namespace that adds
  `components/volsync`, reach the resolver, and the world on 443 in a policy of its own with its
  reason, both by the application `demo-volsync-movers`, one for the namespace. A pod without a
  policy of its own reaches nothing and is reached by nothing. The movers' policies select by that
  label, so any pod of `demo` that carries it gets the movers' flows, the world on 443 among them:
  the label is no proof of being a mover. What keeps it to the movers is who makes pods in the
  namespace, Flux from the reviewed tree and VolSync's controller.
- **`kromgo`.** kromgo's pods, by the labels its Service selects, take the proxies by their labels
  on 8080, the port the route sends to, the kubelet's probes on the same port, and Prometheus
  (`app.kubernetes.io/name: prometheus` in `monitoring`) on 8081, the metrics port the chart's
  monitor scrapes. They reach the resolver, and the pods the Service
  `kube-prometheus-stack-prometheus` selects, by its selector's labels in `monitoring`, on 9090,
  the container port that Service's port 9090 targets: `monitoring` is listed and takes them on
  every port, so kromgo's egress is what keeps them from Prometheus' other ports and the
  namespace's other pods. kromgo opens no other connection; it mounts no service account token.
- **The object storage's port.** cluster-config holds the object storage's endpoint as a URL, which
  a DNS name rule cannot take, so the movers' rule is the world on 443: the port https uses for an
  endpoint that names none, as cluster-config's example does and `tests/network-policy.bats` holds
  it to. The endpoint's validation (`scripts/lib/s3.sh`) admits a port: with an endpoint on
  another port, the rule refuses the movers, every backup and restore of the namespace fails to
  connect, and `just network-drops` shows the movers' flows to `@world` on that port. The rule's
  port changes with the endpoint.
- **Which entity.** Public traffic is translated by the edge routers, arrives at the address the
  workers announce, and a worker may forward it to a proxy on another node
  (`externalTrafficPolicy: Cluster`, [The public Gateway](#the-public-gateway)). A proxy on the
  node that took the connection sees a client outside the cluster, `world`; one on another node
  gets it through the tunnel with the world's identity, which the pinned datapath sets for a
  load-balanced connection from outside so that the receiving node does not take it for a node's
  (`bpf/lib/nodeport.h`, `nodeport_lb4` and the NAT that follows it). The listeners therefore take
  `world` alone, and the watch in audit mode confirms it: a flow from `@remote-node` to the
  listeners would show as `AUDIT`.
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

The check reads only what the render holds. Besides the policies of `demo`, `envoy-gateway-system`
and `kromgo`, that is one policy of a listed namespace: `flux-operator-web`, the
`NetworkPolicy` the Flux Operator's chart renders in `flux-system`, which lets every pod of every
namespace (an empty `namespaceSelector`) reach the operator's web interface on 9080. It passes
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
hop by hop (the world to the proxies' listener ports, the proxies to `hello`'s port, to kromgo's
and to n8n's but not to kromgo's metrics port, n8n's other ports or its database, the kubelet to
every probe port, Prometheus to kromgo's metrics port alone), to show that no pod of `demo` or
`kromgo` reaches the secret store, the storage controller, another pod of `demo` or another
application, n8n among them, that kromgo reaches the resolver and the port of the Prometheus its
configuration names, read from the render, and nothing else, and no other application reaches it,
and that without their default deny `demo`, `envoy-gateway-system` and `kromgo` take and send
everything. What it
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
2. **The policies merge.** The root applies the default denies, the applications apply their
   allows, and the agents evaluate both and drop nothing they deny; what a policy would drop is
   reported as `AUDIT`. As the allows land after the denies, `AUDIT` flows of `demo`,
   `envoy-gateway-system` and `kromgo` from before they landed are expected, such as the proxies to
   `hello` on 8080 and to the controller on 18000, and the controller to the API server, and an
   agent's recent flows can hold them for a while.
3. **Watch**, from the moment the Kustomizations that hold the allows, `hello`,
   `demo-volsync-movers`, `envoy-gateway` and `kromgo`, are Ready at the merge's revision
   (`flux get kustomizations`). `just network-drops` lists what the agents' Hubble holds: the
   `AUDIT` flows a policy would drop, by namespace, pod and port, never an address. It runs each
   agent's own `hubble` through `kubectl exec`, so the kubeconfig needs exec on the Cilium agents'
   pods in `kube-system`, more than the reading recipes need; `NETWORK_DROPS_LAST` (500) bounds the
   flows asked of each agent and `NETWORK_DROPS_TIMEOUT` (60) the seconds each call may take. Hubble
   keeps only each agent's recent flows (4095 by the chart's default), so run it after each of:
   `just gateway-check`; `just cluster-check`; the secret demo (`just bao-put demo/hello greeting`,
   then the Secret in `demo`); a badge asked of kromgo by its name, which has kromgo query
   Prometheus ([Status badges](#status-badges)); the nightly backup of `volsync-demo` at 03:17, and
   a restore of it ([Restoring](#restoring)). Watch a day at least, through one nightly backup. An
   `AUDIT` flow of `demo`, `envoy-gateway-system` or `kromgo` that a check made once the allows were
   Ready is a missing allow, added beside its application in a pull request while the cluster still
   audits, or a pod doing what it should not. Confirm also that no `@remote-node` flow reaches the proxies' listener ports
   and none to the webhook's 9443 is `AUDIT`. `AUDIT` flows of `flux-system` show too: Flux's own
   policies and the Flux Operator's `flux-operator-web`, which the agents enforced before the value,
   are only audited while it is set, and what they would drop is what they dropped before; they are
   not the namespaces' allows.
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
     "`just network-drops` confirms it: a flow from `@remote-node` to the listeners would show as
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
   - `docs/roadmap.md`, M8's row: "the namespaces' default deny with their allows in `demo`,
     `envoy-gateway-system` and `kromgo`" gains ", which Cilium enforces", and the clause "; and
     network policy that drops anything, as Cilium audits every policy, cluster-wide, and drops nothing
     ([Service addresses](kubernetes.md#service-addresses))" goes, the row ending at
     "`infra-apply`.".

   `tests/network-policy.bats` requires the enforcing sentence exactly when the value is gone, and
   fails, saying which sentence the value needs, on a change that does one without the other.
   Without the value every agent enforces every policy of the tree. The agents restart into
   enforcing as they restarted into audit mode, and a node audits until its agent has. Run the
   checks of step 3 again; `just network-drops` then shows `DROPPED` flows, and each of an
   application namespace is an intended denial.
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
in place. Then run the namespace's own checks and `just network-drops`: a `DROPPED` flow of the
namespace is an intended denial or a missing allow, which the way back for one namespace reopens in
one pull request. A namespace with a flow whose peer only the live cluster shows, such as the
callers of a webhook, is watched in audit mode as the first namespaces were: the cluster audits
again (step 5) while its policies land, and enforces again by step 4. While the cluster audits, a
namespace takes the posture in one change, its default deny and its allows together.

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
  nothing else.
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

## Service addresses

A Service of type `LoadBalancer` gets its address from Cilium and is announced over BGP by the
workers to two edge routers, which publish it (ADR 0013). `apps/base/kube-system/cilium-bgp/` holds
what that takes, beside the Cilium application, whose values turn on Cilium's LoadBalancer IP
management and its BGP control plane and keep Layer 2 announcements off. These settings live in
the ConfigMap `cilium-config`, and `rollOutCiliumPods` and `operator.rollOutPods` restart the agents
and the operator whenever it changes: a change to any of them, as the one that turned them on,
restarts every agent, node by node, and the operator.

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
applies it to check each of these. The chart ships none of the definitions; the operator installs
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
  and the satellites' DRBD reactor ([Storage monitoring](#storage-monitoring)).

It does not scrape:

- kube-proxy, which Cilium replaces: its target and its alert rule are off, so nothing fires for
  its absence;
- the Cilium operator, Envoy and Hubble: their monitors stay off, as does every ServiceMonitor of
  the Cilium chart, because `scripts/install-cilium` installs Cilium from the same values before any
  monitoring definition exists, and its chart refuses a ServiceMonitor without one; the agents'
  metrics endpoint needs no definition, so it is on and a PodMonitor of its own application scrapes
  it.

Alertmanager routes every alert to its one receiver, `null`, which sends nothing: alerts show in
Prometheus and Alertmanager and go nowhere else.

Prometheus keeps 14 days of data, and at most 16 GiB, on a 20 GiB volume; Alertmanager keeps its
silences and notification log on a 1 GiB volume. Both volumes are claims on the cluster's default
storage class, which neither names; without one, the claims and the two pods stay Pending.

`tests/monitoring.bats` builds the application as Flux applies it, renders the pinned chart with
its values, and checks the namespace, the targets, the rules, the receivers, the claims and that
each values key is one the chart or a subchart reads.

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
([Monitoring](#monitoring)). It adds the port 9962 to the agents' container ports, beside the host
ports 9879 and 4244 they already declare; the DaemonSet's exception in `pod-security-exceptions.yaml`
already allows host ports, and no new workload and no new Pod Security level comes with it.

`apps/base/kube-system/cilium-monitoring/` holds a PodMonitor, `cilium-agent`, which selects the pods
labelled `k8s-app: cilium` and scrapes the port `prometheus` every 30 seconds, naming the job
`cilium-agent` and adding the node's name as the label `node`. The application names `cilium` and
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
  within the working day, and `info` points at something to look at when convenient;
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
| `LogCollectorOutsizedShare` | One node's collector sends at least ten times the median node's rate of events, and at least 10 a second, for 30 minutes. | info | [LogCollectorOutsizedShare](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#logcollectoroutsizedshare) |
| `LogCollectorDiscardingEvents` | A collector's component discards events it was not set to drop, for 15 minutes. | warning | [LogCollectorDiscardingEvents](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#logcollectordiscardingevents) |
| `LogCollectorSendFailing` | A collector's sink to the store reports errors for 15 minutes. | warning | [LogCollectorSendFailing](https://github.com/eekaan/k8s-gitops/blob/main/docs/runbooks/alerts.md#logcollectorsendfailing) |
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

The alerts read only what Prometheus scrapes: kube-state-metrics' pod readiness for OpenBao's
members, its Deployment availability for the Flux Operator, its nodes' roles, which tell the
control planes' Cilium agents from the workers', and its CronJob metrics for the etcd snapshot job
([cluster.md](cluster.md#scheduled-etcd-snapshots)), for the OpenBao snapshot job
([Raft snapshots](#raft-snapshots)) and for the dump job of every PostgreSQL cluster ([Dumps](#dumps)), Prometheus' own `up` for OpenBao's active Service and the Cilium agents, VolSync's
controller metrics, Vector's internal metrics, cert-manager's certificate metrics, the Flux
Operator's state of Flux's resources, the Cilium agents' BGP session state, LINSTOR's own metrics,
the DRBD reactor's, and external-dns' gauge of its last successful sync and its absence. The dump
alerts are written once, in the `cloudnative-pg` application's `app/`, whose tests are
`tests/rules/cloudnative-pg.yaml`, and select the CronJobs by their names' suffix, `-pgdump`:
kube-state-metrics exposes no CronJob label unless its chart is told to, so a label the component
set would not reach the metrics. `tests/rules-check.bats` fails when an alert reads a metric that
no monitor of the render scrapes, or whose monitor selects nothing of the Service or pod that
serves it.

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

The alerts have no destination yet: Alertmanager sends them nowhere, so they show in Prometheus and
Alertmanager only.

### Dashboards

A dashboard is configuration: its JSON is in the tree and is loaded into [Grafana](#grafana) by a
`GrafanaDashboard`, which the Grafana operator applies. Nothing is fetched when it is loaded: no
dashboard uses the operator's `url`, `grafanaCom`, `oci` or Jsonnet sources or asks for a plugin,
and the tree's checks fetch none either. The cost is that an upstream dashboard is a copy: it is as
large as its JSON, it changes only when someone fetches the file again, and a new release of what
it describes does not reach it by itself. What the tree records for each makes that a step of the
pull request that moves the release.

**Where one lives.** An application whose namespace is `monitoring` keeps its dashboard beside its
manifests: `app/grafanadashboard.yaml`, with the JSON in `app/dashboards/<name>.json`, which the
application's `kustomization.yaml` turns into a ConfigMap with a `configMapGenerator`, with
`kustomize.toolkit.fluxcd.io/substitute: disabled` so Flux leaves the `${...}` of Grafana's
variables alone, and a `kustomizeconfig.yaml` that writes the ConfigMap's hashed name into the
`GrafanaDashboard`'s `configMapRef`. The operator acts in `monitoring` only
([Grafana](#grafana)) and an application's `targetNamespace` puts everything it applies in its own
namespace, so an application in another namespace has its dashboard as an application of its own in
`apps/base/monitoring/<application>-dashboard/`, laid out the same way. That application names the
one it describes and `grafana-operator` in `dependsOn`: `just kubernetes-check` fails for a cluster
that enables the dashboard without the application, so a dashboard leaves with its application.
The `GrafanaDashboard` selects the Grafana by its label `app.kubernetes.io/instance: grafana`,
loads into a folder of the `Folder` column below, which its `spec.folder` names (the operator files a
dashboard that names none under its namespace, `monitoring`), and is applied again every minute, as
the datasource is. The dashboards of the Grafana itself, the logs and the cluster's home, are the
Grafana application's own: `grafanadashboard-logs.yaml`, whose JSON is a ConfigMap, and
`grafanadashboard-home.yaml`, whose JSON is in the object.

**What the tree records.** Beside each upstream dashboard's `GrafanaDashboard`, in comments: the
`Source:` URL of the file at a revision, its `Licence:` and its `SHA-256:`, and a record line
`# dashboard-<name>: <revision>`. The revision is the release of what it describes that the
application's pinned chart is at, either the chart's own version or its application's, and the file
is kept as upstream publishes it, so the SHA-256 is that of the committed file. Renovate moves none
of it: each record is a row of `.renovate/by-hand.tsv`, which `just renovate-pins` checks.
`tests/dashboards.bats` fails when a record, its source, its licence or its hash is missing, when
the file is not what the hash says, when the revision is not that of the pinned chart, or when the
row is missing.

**Adding or updating one.** Fetch the file from the source at the revision of the pinned chart, put
it in `dashboards/`, write the four lines and the by-hand row, and add the application to
`DASHBOARD_APPS` in `tests/dashboards.bats`. When Renovate moves the chart, the test fails until the
file is fetched again at the new release and the record, source and hash move with it, in the same
pull request. A dashboard written for this tree is one of the Grafana application's and has no
record; it reads only datasources the tree defines. Every other application's is an upstream file
in a ConfigMap, with its record.

**What runs, and what each is for.** Folder is where Grafana lists it.

| Dashboard | For | Source, revision, licence | Folder | Datasource |
| --- | --- | --- | --- | --- |
| Kubernetes, nodes, API server, kubelet, controller manager, scheduler, etcd, CoreDNS, Prometheus, Alertmanager, Grafana | The cluster and the stack's own components | The monitoring chart's own, as [Grafana](#grafana) describes, at the monitoring application's chart version; Apache-2.0 | Kubernetes | Prometheus |
| Cluster health (the home) | Nodes Ready, firing alerts by severity, scrape targets down, volumes VolSync reports out of sync and scheduled syncs it missed, and the log store's ingest | Written for this tree; Apache-2.0 | General | Prometheus |
| Logs | Log volume by namespace and by node, and the logs of the namespaces and pods chosen | Written for this tree; Apache-2.0 | Logs | VictoriaLogs |
| VictoriaLogs - single-node | The log store's ingestion, storage, queries and resource use | `dashboards/victorialogs.json` of the VictoriaLogs repository at v1.54.0, the release the pinned chart deploys; Apache-2.0 | Logs | Prometheus |
| OpenBao | The members, tokens, leases, requests and runtime | `grafana/dashboards/dashboard.json` of the OpenBao Helm chart's repository at 0.30.7, the chart the application pins; MPL-2.0, whose text is at https://mozilla.org/MPL/2.0/ | OpenBao | Prometheus |

The `Grafana`'s `spec.preferences.homeDashboardUid` names the home dashboard's `uid`, which is how
the operator sets an instance's home. VolSync exposes whether a volume is out of sync and how many
scheduled syncs were missed, and no time of the last sync, so those are what the home shows of a
backup's age. It has no panel of the public Gateway, which no monitor scrapes, or of Flux, which the
monitors of `flux-monitoring` scrape: Flux's alerts are among the firing alerts it counts.

**Scraped, without a dashboard.** The tree holds no dashboard of these; what their monitors scrape
is in Prometheus, where the alerts ([Alerts](#alerts)) and a query read it:

| Component | Scraped by |
| --- | --- |
| Flux | `flux-monitoring`'s ServiceMonitor `flux-operator`, the Flux Operator's state of every Flux resource, and its PodMonitor `flux-controllers`, the controllers' own metrics ([Flux monitoring](#flux-monitoring)) |
| The Cilium agents | `cilium-monitoring`'s PodMonitor `cilium-agent` ([Cilium's metrics](#ciliums-metrics)) |
| The LINSTOR controller and the satellites' DRBD reactors | `linstor-monitoring`'s ServiceMonitor `linstor-controller` and its PodMonitor `linstor-satellite` ([Storage monitoring](#storage-monitoring)) |
| cert-manager | The chart's ServiceMonitor, which the application turns on ([cert-manager](#cert-manager)) |

**Missing a scrape or an upstream.** Each of these has no dashboard, because it would show "No
data" or no upstream file exists:

| Component | Missing |
| --- | --- |
| The Cilium operator, Envoy and Hubble | Their ServiceMonitors, which stay off ([Monitoring](#monitoring)) |
| The Piraeus operator | A monitor of the operator itself: the render holds none; `linstor-monitoring` scrapes only the LINSTOR cluster the operator makes |
| Envoy Gateway and its proxies, the public Gateway's among them | A monitor of the controller and of the proxies the Gateway starts: the render holds none |
| External Secrets | Its ServiceMonitors, which the application leaves off |
| CloudNativePG | A PostgreSQL cluster whose instances `components/cnpg-cluster`'s PodMonitor scrapes: no application of the overlay uses the component, and the operator's own PodMonitor is all the render holds |
| Vector | An upstream dashboard: its repository ships none |
| VolSync | An upstream dashboard: its repository ships none, and the one shared on grafana.com states no licence |

The other applications the render holds a monitor for, the descheduler, external-dns, KEDA, the
kubelet CSR approver, metrics-server, the reloader, Spegel, the Vertical Pod Autoscaler and the
Grafana operator, have no dashboard.

An upstream dashboard declares the datasource it reads as an input in its `__inputs`, and its
`GrafanaDashboard`'s `spec.datasources` maps that input to the name of the tree's Prometheus. Before
it loads the dashboard, the operator replaces every `${<input>}` in the JSON with that name, and
changes nothing else. OpenBao's panels name `${DS_PROMXY}`, so they name Prometheus. VictoriaLogs'
panels read the variable `$DS_PROMETHEUS`, without braces, which the operator leaves as it is: the
variable lists the datasources of type prometheus, and only its current value becomes Prometheus.

`tests/dashboards.bats` builds the applications that deliver a dashboard as Flux applies them, checks
that every `GrafanaDashboard` the cluster's render holds is one of those or the monitoring chart's,
whatever its file is named, and checks that each `GrafanaDashboard` is in the namespace the operator
watches, selects the Grafana and has its JSON in the tree, and that an overlay without the
application it describes has none of its dashboards and a cluster that keeps the dashboard without
it is refused; that no dashboard uses a source that fetches or asks for a plugin, that each outside
the Grafana application loads a ConfigMap and has the records above, and that the render holds a
monitor of the application it describes; that every dashboard of the tree, the monitoring chart's
included, has a title and a `uid` no other has, maps only inputs its JSON names and only to
datasources the tree defines, and, with its inputs replaced as the operator replaces them, reads
only datasources the tree defines: a variable that lists the type of one, or its name or `uid`;
that every metric the home dashboard queries is written by a recording rule of the render or
served by a monitor of the render named in `tests/fixtures/dashboards/metric-sources.tsv`; and that
a ConfigMap, or a `GrafanaDashboard` carrying its JSON, holds at most 1 MiB, which it proves
refuses a padded dashboard. The metrics are read from the `expr` fields of the home dashboard's
panels: the parser takes out strings, label matchers, ranges, variables and the label lists of
`by`, `without`, `on`, `ignoring` and the group modifiers, and reads every identifier left that is
not a function, a keyword or a number as a metric; it refuses an expression that selects by
`__name__`. It cannot tell which target serves a metric: that is the table's claim, and the table
is the one place to change when a panel reads a new metric.

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

**Where it is.** `kromgo.${CLUSTER_DOMAIN}` on the public Gateway's `https` listener
([Giving an application a public hostname](#giving-an-application-a-public-hostname)); the route
sends only the paths under `/badges/` to kromgo, unchanged, as it has no filter, so its index page
and its health endpoints answer the Gateway's 404. external-dns publishes the name, as it does for
every route on the Gateway ([DNS records](#dns-records)). The namespace is `kromgo`, its own, labelled `k8s-gitops/gateway: public`. Labelling `monitoring`
instead would let any route in it attach to the Gateway, and `monitoring` holds Prometheus,
Alertmanager and Grafana, whose Services a route for the wrong name would publish; the namespace
is privileged too, for node-exporter and the log collector. The own namespace is small, enforces
`restricted`, and is one more entry in the set of namespaces that carry the label, which
`tests/gateway.bats` pins. A cluster selects kromgo with two entries of its overlay, the namespace
directory and the application's `ks.yaml`; the application waits for the Prometheus Operator's
definitions, the Gateway and Cilium, whose kind its network policy is, and is Ready once both pods
are (`wait: true`), which is once kromgo has read its configuration and listens: a configuration it
refuses keeps the application from Ready. It queries the stack's Prometheus at each request, not at
start, so a badge answers with an error until Prometheus does, and the stack's application is not
waited for.

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
Grafana starts, it retries after 10 seconds, doubling the wait up to two minutes, so a restarted
Grafana has them all back within a few minutes. The datasource is the Prometheus Service of the
monitoring chart, `kube-prometheus-stack-prometheus`, port 9090. Grafana makes no call to the
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
without Secret values. The collector does not ship it: its file source's patterns, `/var/log/*.log`
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
lines in their buffers and retry.

What listens, and where:

- the store: port 9428 of its pod's address, plain HTTP, behind the headless Service
  `victoria-logs`, for the collectors' inserts, queries and its web interface, and `/metrics`,
  which Prometheus scrapes through the ServiceMonitor;
- the collector: port 9598 of its pod's address, plain HTTP, its own metrics only, which Prometheus
  scrapes through the PodMonitor. It uses neither the node's network nor a host port, so it reserves
  no port on the nodes.

Cilium carries pod addresses between the nodes in its VXLAN tunnel, so both ports answer the
cluster's pods and nodes, and no host outside the cluster has a route to them. Neither application
has an ingress, a route or a Service of type LoadBalancer or NodePort, and the nodes' security group
admits from outside the cluster only the Talos and Kubernetes APIs.

Reading the logs, with the cluster's kubeconfig:

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

## cert-manager

`apps/base/cert-manager/cert-manager/` installs cert-manager, which issues and renews the TLS
certificates applications and gateways ask for, from the issuers they name (ADR 0006). OpenBao's own
issuers are namespaced and sign OpenBao's listener certificate alone ([OpenBao](#openbao)); the one
issuer any namespace may name is the `ClusterIssuer` `cluster-ca`, below.

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
  to test anything again. Both issuers register their account with the CA as soon as they exist.
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
(`apps/overlays/<cluster>/kustomization.yaml`) on the Kustomization `gateway-public`, which in
`lab-sto2` reads:

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
```

It is a patch and not a `cluster-config` key because the choice is part of the tree and reviewed in
a pull request, not a value of the deployment, and because the tree's check can see it: a cluster-config
value exists only in the cluster. The patch names `acme-issuers` in `dependsOn` too, so the
Gateway's certificate is requested only once the issuer exists, and `just kubernetes-check` refuses
a cluster that chooses an issuer other than `cluster-ca` without that dependency, and one whose
overlay names the dependency without listing the application.

`lab-sto2` chooses production. A new cluster starts with `PUBLIC_ISSUER: letsencrypt-staging`, and
once the staging certificate is Ready and `just gateway-check` passes, changes that one line to
`PUBLIC_ISSUER: letsencrypt-production` in a pull request of its own. cert-manager then issues the
certificate again from production, with a new private key, into the same Secret, and the listener
serves the new certificate when it is Ready; the old one is served until then. Going back to
staging for testing is the same one-line change the other way (the rate limits in [The ACME
issuers](#the-acme-issuers)).

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
(ADR 0015).

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
it empty. Its ExternalSecret writes the Secret the movers read as soon as the store holds the key,
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
[cert-manager](#cert-manager)) and `cilium-bgp` in `dependsOn`, so it starts once the controller
runs, an issuer signs and the pool and the BGP objects exist; a cluster that chooses an ACME issuer
for its certificate adds `acme-issuers` ([Choosing the public Gateway's
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
  keep. A proxy therefore sees as the client the address of an edge router, or of the worker that
  forwarded the connection from another node, never the client's, and its access logs carry that
  address.
- **The proxies.** Two replicas, spread over the workers with a skew of one and never scheduled
  where that fails, under a disruption budget that keeps one running, with requests of 100m of CPU
  and 128Mi of memory and no limits. They run as a non-root user with the runtime's default seccomp
  profile, no privilege escalation and no capabilities, which the namespace's restricted level
  requires. The controller makes their Deployment at run time, so no render holds it and
  `just pod-security-check` does not evaluate it; admission enforces the namespace's level when the
  controller creates it. `tests/gateway.bats` asserts the fields of the `EnvoyProxy` that produce
  its pods, and the controller adds its shutdown manager container with the same hardened defaults.
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
  which would attach it to `http` as well, or when the redirect is anything but that rule.
- **Who may attach.** To `https`, `HTTPRoute`s of the namespaces that carry the label
  `k8s-gitops/gateway: public`, and of no other: the listener's `allowedRoutes` select them by that
  label and name the one kind. A route in a namespace without it is not accepted, which is the
  Gateway API's rule and the controller's to apply; it shows in the route's status, which
  `just gateway-check` reads, and `tests/gateway.bats` proves the selector on the objects. `demo`,
  `ai-system` and `kromgo` are the namespaces that carry the label, and `tests/gateway.bats` pins
  that set.
- **The certificate.** The `Certificate` `public-wildcard` asks the `ClusterIssuer` the cluster
  chose, `cluster-ca` by default, for an ECDSA P-256 certificate for `*.${CLUSTER_DOMAIN}` and
  `${CLUSTER_DOMAIN}`, with a new private key at each renewal and the same Secret, so the listener
  does not move. It asks for 90 days, which the cluster's own CA gives and an ACME CA decides for
  itself, and is renewed with two fifths of the lifetime left (`renewBeforePercentage: 40`), which
  holds for any lifetime, and which is more than the third `just gateway-check` treats as too
  little. A `Certificate` rather than the Gateway annotation cert-manager reads, as the annotation
  makes a certificate for each listener's hostname only, so it would leave out the domain itself.
- **TLS.** A `ClientTrafficPolicy` sets 1.2 as the least version a client may use, the
  controller's default stated rather than relied on.
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

The record for the name is made by external-dns within a minute or two of the route being accepted,
and removed when the route is; there is no DNS step to do by hand ([DNS records](#dns-records)).

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
  `just bao-put cert-manager/cloudflare api-token` writes. Without the key the ExternalSecret
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
and its `ks.yaml` sets `wait`.

An application takes a cluster from the component `components/cnpg-cluster`, in its `ks.yaml`:

```yaml
spec:
  dependsOn:
    - name: cloudnative-pg
    - name: prometheus-operator-crds
    - name: external-secrets
    - name: openbao-store
  components:
    - ../../../../../components/cnpg-cluster
  postBuild:
    substitute:
      CNPG_CLUSTER_NAME: <app>-db
      CNPG_STORAGE_SIZE: 10Gi  # each instance's volume; 5Gi when unset
```

The cluster has three instances of PostgreSQL 18, from the operator's standard image, whose tag names
a minor version that Renovate moves. The publisher rebuilds the image under that tag and a node keeps
the build it pulled first, so instances can run different builds of one minor version. Each instance
must run on a different worker, and requests and is limited to 500m CPU and 512Mi memory. The
operator's disruption budgets move the primary away by switchover before its worker is drained, and
let drains take one replica at a time. A PodMonitor scrapes every instance. Without
`CNPG_CLUSTER_NAME` the build fails, and so does the apply of a name longer than 45 characters: the
dump job's CronJob, `<name>-pgdump`, is named in at most 52, and Flux applies an application whole
or not at all. The operator creates the database `app`, owned by the user
`app`, whose password and connection URI are in the Secret `<name>-app`; the Services `<name>-rw`,
`<name>-ro` and `<name>-r` reach the primary, the replicas and any instance. The dump job
([Dumps](#dumps)) needs the External Secrets operator and the secret store, so the application
names `external-secrets` and `openbao-store` in `dependsOn` as well, and nothing else new.

A patch in the application's own `kustomization.yaml` changes anything else, as it applies after the
component. It targets the Cluster by kind alone: Flux substitutes after the build, so when the patch
applies the Cluster is still named `${CNPG_CLUSTER_NAME}`, and a target by the name the application
gives it matches nothing and is skipped without an error.

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
three workers, the new one waits for a worker without an instance.

`tests/postgresql.bats` renders the operator's chart and checks its namespace, definitions,
replicas, budget, monitor and pods; builds applications that take a cluster from the component, one
that does not name it and two that patch it, by kind and by name, as Flux applies them; and checks
each field of the `Cluster` against the pinned chart's definition and its StorageClass against
LINSTOR's. `tests/postgres-dumps.bats` builds applications that take a cluster from the component and
runs the dump job's scripts as its containers run them, with stand-ins for `pg_dump`, `pg_isready` and
the S3 client.

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
the tree. The scripts are the component's own copies of the etcd snapshot job's, as a component
cannot read a file outside its directory; `tests/postgres-dumps.bats` holds `fetch-age.sh` to the
etcd job's byte for byte, and the encrypting and uploading scripts to it line by line apart from the
words that say dump for snapshot and the path.

**What a dump is not.** It is a copy of one day, not a point in time: a restore loses everything
written since the dump, and a dump holds one database's objects, not the cluster's roles' passwords
or its settings. The operator's own backups, WAL archiving and base backups through its Barman Cloud
plugin, would give point-in-time recovery, and are not used: the plugin offers server-side
encryption only, and [ADR 0008](adr/0008-state-and-backups-are-encrypted-before-they-leave.md) lets
nothing leave the cluster unencrypted. `PostgresDumpStale` and `PostgresDumpJobFailing`
([Alerts](#alerts)) fire when the newest dump is too old or the latest run failed, and
[postgres-restore.md](runbooks/postgres-restore.md) restores a dump into a new cluster. Until the
first dump has run a database's data lives on the workers' data volumes alone
([Where the data lives](#where-the-data-lives)).

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
- `openbao/openbao-snapshots` holds the CronJob that snapshots the raft storage
  ([Raft snapshots](#raft-snapshots)). It names `external-secrets`, `openbao`, `openbao-store` and
  `prometheus-operator-crds` in `dependsOn`, and does not wait.

`tests/openbao.bats` builds the first three as Flux applies them and renders the chart with its
values; `tests/openbao-snapshots.bats` builds the fourth and runs its scripts against fakes of
OpenBao's client and of the object storage; `tests/openbao-recipes.bats` runs the recipes below
against fakes of the cluster and of OpenBao.

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

### How an application gets a secret out

An application reads a key with an ExternalSecret that names the ClusterSecretStore `openbao`, the
path as `remoteRef.key` and the key as `remoteRef.property`. The store logs in as `external-secrets`
and reads the key-value mount and nothing else. `demo/hello-secret` is the example: after
`just bao-put demo/hello greeting`, the Secret `hello` in `demo` holds the key `greeting`.

The store serves every namespace. Creating an ExternalSecret is reserved to cluster administrators
and Flux, which applies those in Git after review; no RoleBinding grants `edit` or `admin`. A
namespace delegated to anyone else first gets its own store restricted with `conditions`.

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

**What a snapshot is worth.** A snapshot is the raft state of the store: a gzip-compressed tar
archive of `meta.json`, `state.bin`, `SHA256SUMS` and `SHA256SUMS.sealed` (OpenBao's source, in the
pinned release's `internal/physical/raft/snapshot`). It holds everything the store holds: every key
of `secrets/`, every version, the policies, the roles and the auth methods' configuration. OpenBao
keeps that data encrypted with a keyring that a root key protects, which the seal protects
([seal](https://openbao.org/docs/concepts/seal/)), so a snapshot is ciphertext until it is restored
into a store that unseals with the same seal key; the archive's checksums are sealed with the
store's seal, which is how a restore checks that the snapshot was sealed with the seal key the store
unseals with; a new store with the same seal key passes. A restore that skips that check, `snapshot-force`, installs data that still opens only with the seal key
([API](https://openbao.org/docs/api/system/storage/raft/)). The age layer keeps a copy that leaves
the cluster unreadable to anyone who holds the S3 key without the operator's age key.

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
seal key.

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
`kubectl --namespace openbao create job --from=cronjob/openbao-snapshots <name>`. The runbook lists
what the bucket holds and checks that a snapshot opens
([runbook](runbooks/openbao.md#listing-and-checking-snapshots)). The alerts are
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
`tests/applications.bats` proves each of these for n8n on the objects the overlay builds and the
chart renders (`features/applications.feature`).

### n8n

n8n, the workflow automation tool, runs in `ai-system` (`apps/base/ai-system/n8n/`). The namespace
enforces the restricted Pod Security level and carries the Gateway label; it holds no default deny,
and `network-policy-exceptions.yaml` lists it with n8n's flows ([Network policy](#network-policy)).
n8n's `ks.yaml` names the operator, the Prometheus Operator definitions, External Secrets, the
store's application, VolSync, LINSTOR and the public Gateway in `dependsOn`, and sets `wait` with
the long timeout, so a cluster that lacks one of them is refused by `just kubernetes-check`, the
encryption key's ExternalSecret is applied once the store is Ready, and the application is Ready
once n8n answers its readiness endpoint.

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
  the cluster. The component dumps the database once a day, encrypted, to the object storage
  ([Dumps](#dumps)); the `external-secrets` and `openbao-store` in n8n's `dependsOn` serve the S3
  key the dump job reads as much as the encryption key.
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
  ExternalSecret refresh starts it again.
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
  restored from its daily dump ([Dumps](#dumps), [the runbook](runbooks/postgres-restore.md)), which
  is up to a day old.
- **The hostname** is `n8n.${CLUSTER_DOMAIN}`, an `HTTPRoute` on the public Gateway's `https`
  listener to the Service `n8n` on 5678. `N8N_HOST`, `N8N_PROTOCOL`, `N8N_EDITOR_BASE_URL` and
  `N8N_WEBHOOK_URL` are that name over https, set from the variable, and `N8N_PROXY_HOPS` is 1: the
  Gateway's proxy adds the forwarding headers, and the edge routers in front of it translate the
  source address and add none ([ADR 0018](adr/0018-own-edge-routers-translate-public-traffic-to-the-gateway.md)),
  so n8n trusts one proxy. n8n sees the address of an edge router or a worker as the client's.
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

### Porting an application from the reference catalogue

The steps n8n took, in order; the next port does the same and says where it differs.

1. **Layout.** A namespace directory with `namespace.yaml` (the strictest Pod Security level the
   workload passes, the prune annotation, and `k8s-gitops/gateway: public` if it has a route) and a
   `kustomization.yaml` that includes `components/common`; the application's `ks.yaml` and `app/`
   beside it. List both in the overlay. The namespace's default deny with the application's flows
   ([Declaring an application's flows](#declaring-an-applications-flows)), or its entry in
   `network-policy-exceptions.yaml` with the flows it would declare, as `ai-system`'s is.
2. **Pins.** The chart as an `OCIRepository` with its tag under a `# renovate:` comment, each image
   by tag and digest under one. `just renovate-record`, then the form of the tags in
   `.renovate/tag-forms.tsv`, read from the registry's own listing; `just renovate-pins` passes.
   Where the registry tags betas as plain versions, as n8n's does, a rule in
   `.renovate/managers.json5` keeps Renovate to the line the tree runs.
3. **Database.** `components/cnpg-cluster` in `ks.yaml` with `CNPG_CLUSTER_NAME`, and the connection
   from the keys of `<name>-app`; `prometheus-operator-crds` and `cloudnative-pg` in `dependsOn`.
4. **Secrets.** A secret the application keeps a copy of, or that must outlive the cluster, such as
   n8n's encryption key, in the store: an ExternalSecret that reads `<namespace>/<application>`,
   `openbao-store` in `dependsOn`, and the one `just bao-put` command in the docs, with every place
   the secret lives and the order on a rebuild. A generator and a `CreatedOnce` ExternalSecret only
   for a secret nothing keeps, such as the runners' token. Nothing secret in a values file, and no
   SOPS file for an application.
5. **Volume.** `components/volsync` with `APP`, a capacity and a minute of its own for the schedule;
   the claim named in `existingClaim`; say what is in the volume and what is in the database.
6. **Route.** An `HTTPRoute` on `https` of `public`, the application's own settings for its
   host, protocol and proxies agreeing with it, `gateway-public` in `dependsOn`, and a rule for the
   backend's pods and container port in the proxies' egress ([Giving an application a public hostname](#giving-an-application-a-public-hostname)).
7. **Hardening.** Restricted: a user the image runs as, a read-only root filesystem with every path
   the application writes as a volume, found by running the pinned image read-only with those
   mounts alone, no capability, requests and a memory limit, probes on the application's health
   endpoints, everything that calls its publisher's services turned off by its documented variable
   or named as still on, replicas and an update strategy that fit the volume.
8. **Tests.** Scenarios in `features/applications.feature`, each proved by a test of
   `tests/applications.bats` under its title, written and seen failing before the manifests, and
   mutated afterwards: remove the line each assertion guards and see the test fail. Two tests pin
   sets a port extends: the namespaces that carry the Gateway label in `tests/gateway.bats`, where a
   port with a route also adds its application to the `tree_without` list of the test that leaves
   the Gateway out, and the applications that take the volsync component in
   `tests/volume-backups.bats`.
9. **Docs.** The application's paragraph here: what it is, where its state lives, how its secret
   is made, its hostname, any first-visit step, how it is backed up and restored.

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
  workflow on a version tag.
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
  `.github/workflows/publish.yaml` on `refs/heads/main`. An artifact signed by a run on another
  branch or tag, or by another workflow, is refused (ADR 0003).
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
changes the identity, so the instance's patch changes in the same change. `tests/publish.bats` fails
when the identity the script verifies and the one the instance's values accept differ.

The package must be public for the cluster to pull it without credentials. GitHub makes a new
package private, and a package linked to its repository takes the repository's access permissions
but not its visibility, so the package's visibility is set to public in its settings once, after
the first run; until then the cluster cannot pull it. A public package cannot be made private
again.

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
nothing that is not called `x-*`. A HelmRelease whose name is not a DNS subdomain or whose
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
