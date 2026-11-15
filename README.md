# k8s-gitops

Talos Kubernetes on OpenStack, provisioned with OpenTofu and reconciled by Flux.

- **Infrastructure** (`infra/`): OpenTofu creates the network, the Talos image, the virtual
  machines and their floating IPs. Nodes boot without machine configuration.
- **Talos** (`talos/`): [talman](https://github.com/ludwighansson/talman) renders each node's
  machine configuration from patches and applies it over the Talos API.
- **Cluster state** (`kubernetes/`): Flux reconciles the cluster from a signed OCI artifact
  built from `main`.

That is the design; [`docs/roadmap.md`](docs/roadmap.md) says how much of it is built.
Decisions are recorded in [`docs/adr/`](docs/adr/) and the standing rules in
[`constitution.md`](constitution.md). The repository is public and describes a real
deployment: [`CLAUDE.md`](CLAUDE.md) lists what it never contains.

## Working on it

Every tool is pinned to an exact version in `mise.toml`. A change that adds or removes a pin, a
tool or any other, or moves one to another file or key, runs `just renovate-record` and commits
`.renovate/extracted.tsv` with it, and so does a branch after merging `main` when `main` brought
another change's pins: `just renovate-check` fails, naming the recipe, until the record is
current. A new version alone leaves the record as it is. With [mise](https://mise.jdx.dev) and
[just](https://just.systems) installed:

- `just tools` installs the pinned tools.
- `just checks` runs every check that needs no credentials, with the tools on this machine, group
  by group. The group `static` holds tool versions, address literals in the files and the commit
  messages, merge conflict markers, that every Talos secrets bundle is encrypted, shellcheck and
  yamllint, the Renovate configuration (`just renovate-check`: Renovate's own validator and,
  offline, its own extraction of the dependencies from the files, which `.renovate/extracted.tsv`
  records, run from its pinned container image, so it needs a container runtime, Docker; `just
  renovate-record` rewrites the record after a change to the pins or the configuration), that
  every version pin the check finds is extracted by Renovate or listed in `.renovate/by-hand.tsv`
  as moved by hand, with where, why and how (`just renovate-pins`; the header of
  `scripts/check-renovate-pins` says which forms it finds and which it does not), the edge routers'
  routing policy (`just edge-policy-check`: their rendered FRR configuration against real BGP
  speakers in FRR's pinned container image, which needs Docker as well), scenario proofs, the
  OpenTofu check (`just infra-check`: formatting, that the Talos schematic lists no QEMU guest agent
  extension, that every stack enforces state encryption, that no stack or module declares a bucket,
  that the default service range overlaps no default node, pod or service subnet, validation
  without a state backend and the mocked `tofu test` runs), the Talos check
  (`just talos-check`: every node's machine configuration rendered from the template, the patches
  and fixture node data, and validated, offline), the offline build of `kubernetes/`, its render
  with every chart expanded (`just render-check`, which pulls the charts from their public
  registries), the schemas and images of what it builds and renders (`just kubernetes-validate`,
  which pulls the charts as well and fetches the schemas), the log collector's configuration
  (`just vector-check`: Vector itself validates it and runs its unit tests, in the image the
  collector runs, pinned by digest, so it needs Docker too), and gitleaks over the committable
  files and the git history reachable from `HEAD`, so a clone and a CI checkout are judged on the
  same commits. The groups `tests-1` to `tests-3` each run a third of the bats tests.
- The groups are the dependencies of the `checks` recipe, and a group's checks are its own
  dependencies; a new check goes into exactly one group, and then runs in `just checks`, in
  `just ci` and in CI.
- `just test` runs the bats tests but the hermetic ones and the namespace one, the tests of each file
  side by side (a file whose tests share state runs them one at a time, and says why);
  `just test 2/3` runs the second of three parts of the test files, which are split by their number
  of tests.
- `just pod-security-check` renders the tree, charts pulled from their public registries, and checks
  that every namespace enforces the strictest Pod Security level its workloads pass
  ([docs/kubernetes.md](docs/kubernetes.md#pod-security)); `tests/pod-security.bats` runs it as part
  of the bats tests.
- `just ci` runs the same groups through the Dagger module in `.dagger/modules/ci`, side by side,
  each in containers of its own: Renovate in its own image, Vector in the log collector's image,
  the speakers of the edge routers' routing policy in FRR's image, every other check in a container
  with the pinned tools, the tools image `versions.yaml` records when it was built for these pins
  and one built from them otherwise
  ([The tools image](#the-tools-image)); the run's first line says which. `just ci tests-2` runs
  one group, as each CI job does. It needs
  only `just`, the pinned `dagger` and a container runtime such as Docker. Every group runs to its
  end, and the run ends with each group's output under a heading `== <group>: passed` or
  `failed`, followed by its checks, and a line naming the groups that failed. Dagger shows every
  step and each check's output while it runs: its live view in a terminal, and line by line where
  there is none, as in CI. The live view can name the checkout's path on the machine, so paste the
  checks' own lines into a pull request, not the whole of it.
- In CI, a first job lists the groups (`just ci-groups`), one job per group runs `just ci <group>`,
  each showing its own result on the pull request, the render job renders the change for its
  comment (`just ci-render`), and the job named `ci`, the required check on `main`, passes only when
  every one of them succeeded (`just ci-passed`).
- `just test-hermetic` runs the bats tests that drive `just ci` itself, and `just edge-forward-check`
  the one that loads the edge routers' rules into network namespaces of a user namespace, which
  the CI containers refuse; both run on a developer's machine.
- `just render <out>` renders what Flux would apply, charts expanded, one file per object, and
  `just render-diff <base> <head>` prints what changes between two renders, as the comment every
  pull request gets ([docs/kubernetes.md](docs/kubernetes.md#the-render-diff)).

`docs/infrastructure.md` covers the recipes that plan, apply and destroy the OpenTofu stacks: what
they need in the environment, how state is stored and encrypted, and what they print.
`docs/cluster.md` covers the recipes that create and change the Talos cluster. The edge routers
that publish the cluster's Services have recipes of their own, each described in
`docs/infrastructure.md#the-edge-routers` and `docs/runbooks/edge.md`:

- `just os-images [pattern]` lists the names of the cloud's public images.
- `just edge-ssh-key` creates the edge routers' SSH key pair at `EDGE_SSH_KEY_FILE`.
- `just edge-check` checks, reading only, that both edge routers serve.
- `just edge-routes` shows an edge router's BGP sessions and routes, in a terminal only.
- `just edge-rollout [--replace] [--edge N [--other-down]]` replaces the edge routers one at a time,
  checking each before the next; `--replace` replaces them when only the image is new, and `--edge`
  one named edge.
- `just edge-policy-check` proves the edge routers' routing policy with real BGP speakers.
- `just edge-forward-check` proves what an edge router forwards, in network namespaces, on a
  developer's machine.

`docs/kubernetes.md`
covers the tree Flux reconciles and how the publish workflow pushes, signs and verifies it before
moving the `main` tag Flux follows, on every merge to `main` that changes it. `docs/runbooks/`
holds the procedures that take more than one recipe, such as replacing the Talos image.

Behaviour is specified as Given/When/Then scenarios in `features/`, each proved by a bats
`@test` with its title, an OpenTofu `run` named after its slug, or a `@by:<recipe>` tag naming
the `just` recipe whose tool run verifies it, or tagged `@pending` with its issue key.

The repository checks:

- `just tools-check` fails when a pinned tool is missing or its binary reports a different version.
- `just kubernetes-check` builds `kubernetes/` offline with kustomize and Flux and fails when an
  application, a `ks.yaml` or a variable breaks the layout in `docs/kubernetes.md`, a manifest is
  outside what the artifact carries, or a `dependsOn` names an application the cluster does not
  enable or one that does not wait. It builds nothing from a tree that a build would read outside
  of, through a link or an entry that is not a plain relative path of the tree, or that kustomize
  or `flux build` would read otherwise than the check, through a key spelled otherwise than the
  field it reads as. No entry it accepts is a URL, and its builds run with a `git` that refuses and
  a closed proxy, a second layer under that rule. The publish run repeats it on the commit it
  publishes and publishes nothing when it fails.
- `just kubernetes-validate` runs `just kubernetes-check`'s builds and the render, and fails when an
  object Flux builds has a field its schema lacks or an image of the render has no tag other than
  `latest` and no digest. It fetches the charts and the schemas, so the publish run does not run
  it (`docs/kubernetes.md`, What the checks refuse).
- `just check-literals` fails when a file git would commit, tracked or untracked and not ignored,
  holds an IPv4 literal outside the documentation ranges, loopback, `0.0.0.0`, the metadata
  address and netmasks, unless `.address-allowlist` declares it with a reason. It skips the
  address check's own fixtures in `tests/fixtures/check-address-literals/`, which exist to be
  flagged; so does gitleaks.
- `just check-commit-literals` applies the same rules to the messages of the commits between the
  default branch (the remote's, the remote's `main` as a CI checkout fetches it, or a local
  `main`) and `HEAD`, and passes when there is none.
- `just check-conflict-markers` fails, naming the file and the line, when a file git would commit
  holds a merge conflict marker as git writes it: a line starting with seven `<` or seven `>`
  and then a space or the end of the line, or a line of seven `=` after an opening marker. A
  Markdown heading underlined with seven `=` is not one.
- `just scenarios-check` fails when a scenario has no proof or more than one, when a `@pending`
  scenario has no issue key or already has a proof, when a `@by:` tag names a recipe that does
  not exist, when two scenarios share a title, or when a test claims a scenario that does not
  exist. It does not run `@by:` recipes. `scripts/scenarios-check` gives the slug rule and how a
  test that proves no scenario is named.

## The tools image

The container with the pinned tools is built once for each change of its inputs and published as
`ghcr.io/eekaan/k8s-gitops/ci-tools`, so a CI job pulls it instead of installing the tools. Its
inputs are `ci_tools_base` (the image it starts from) and `ci_tools_packages` (the package step) in
`versions.yaml`, the whole Dagger module, `.dagger/modules/ci/main.dang`, as what the layer holds
can depend on any of it, and `mise.toml`. Any change to the module, a comment included, so gets an
image of its own, at the cost of one build. `versions.yaml` holds each value on one line, with no
quotes, tabs, comment or indented line under it, as the script that reads them has no YAML parser;
`just ci` refuses any other form.

- `just tools-image-key` prints the key of those inputs. It names the image: its tag, the
  annotation its signature carries, and `ci_tools_inputs` in `versions.yaml`, recorded beside the
  image's digest in `ci_tools_image`.
- `just ci`, and `just ci-render` for the render job, hand the module the recorded image, by digest,
  when the recorded key is the key of the checkout's inputs; the module uses it, for the checks and
  the render alike, when the engine runs the image's platform, `linux/amd64`.
  Otherwise the module builds the tools from the pins, as before, so a pull request that changes an
  input works before any image exists for it, on another platform too. Either way the same checks
  run and give the same result. A record of any image but `ghcr.io/eekaan/k8s-gitops/ci-tools`
  named by its digest alone stops `just ci`: a merged record is what every later run executes in.
- `just tools-image-publish` is the one step of `.github/workflows/tools-image.yaml`, which runs on
  hosted runners on every push to `main` that changes `mise.toml`, `versions.yaml`, the Dagger
  module, `scripts/tools-image` or the workflow, and by hand. It logs in with the job's token on
  standard input, the one command that gets it, builds the tools with the pinned Dagger, pushes them
  tagged with the key, signs the digest keyless with the key as an annotation, verifies the
  signature against this workflow on `main` in this repository, and prints the digest last. When an
  image signed that way for the key is there already, it prints that digest and builds nothing;
  otherwise it says why it found none, such as no tag or an unreachable transparency log. It refuses
  outside the workflow and on any branch but `main`, and it commits nothing.
- `just tools-image-pin <digest>` records the image in `versions.yaml`, with the key of the
  checkout's inputs, once its signature verifies as the tools image workflow's on `main` in this
  repository for that key; any other digest leaves the file as it is. It verifies without
  credentials, through a Docker configuration of its own with no login in it, which cosign then
  reads in place of the machine's Docker or podman logins, so it also proves that the checks can
  pull the image.

Who does what, once a change to the inputs is merged:

1. The tools image workflow runs on `main` and prints the digest in its log.
2. The first time only, the owner makes the package `ci-tools` public in its settings on GitHub, as
   for the cluster's artifact: GitHub makes a new package private, and a package linked to its
   repository takes the repository's access permissions but not its visibility. Until then the pin
   refuses the digest, and the checks could not pull it.
3. A person runs `just tools-image-pin <digest>` on a branch from `main` and opens a pull request
   with the change to `versions.yaml`. Its checks already run in the image.

If the recorded image can no longer be pulled, because the package was made private or the image
deleted, every check job and the render job fail, so the required check `ci` fails for every pull
request. The way out is a pull request that sets both `ci_tools_inputs` and `ci_tools_image` to
`""`: its own run builds the tools from the pins, as every run does without a record, and once it is
merged the pin can follow a new publish run.

Renovate cannot propose the pin. The tag is a key, not a version, so its Docker datasource has no
order to update along; it can neither compute the key of the checkout's inputs nor verify the
signature. Proposing the pin takes a run of `just tools-image-pin` after the publish run: a
post-upgrade task, which only a self-hosted Renovate whose own configuration allows that command can
run, or a workflow with a token that may push a branch and open a pull request whose checks run;
this repository has neither. When Renovate moves a pin in `mise.toml`, its pull request builds the
tools from the pins, and the pin follows the merge as a pull request of its own.

The CI host's engine pulls the image once and keeps it in its cache, as it keeps a built layer.

## Acknowledgements

The Flux layout and a number of manifests are adapted from
[xunholy/k8s-gitops](https://github.com/xunholy/k8s-gitops), which is published under the
Apache License 2.0.
