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

Every tool is pinned to an exact version in `mise.toml`. With [mise](https://mise.jdx.dev) and
[just](https://just.systems) installed:

- `just tools` installs the pinned tools.
- `just checks` runs every check that needs no credentials, with the tools on this machine, group
  by group. The group `static` holds tool versions, address literals in the files and the commit
  messages, that every Talos secrets bundle is encrypted, shellcheck and yamllint, the Renovate
  configuration (`just renovate-check`: Renovate's own validator, run from its pinned container
  image, so it needs a container runtime, Docker), scenario proofs, the OpenTofu check
  (`just infra-check`: formatting, that the Talos schematic lists no QEMU guest agent extension,
  that every stack enforces state encryption, that no stack or module declares a bucket,
  validation without a state backend and the mocked `tofu test` runs), the Talos check
  (`just talos-check`: every node's machine configuration rendered from the template, the patches
  and fixture node data, and validated, offline), the offline build of `kubernetes/`, and gitleaks
  over the committable files and the git history. The groups `tests-1` to `tests-3` each run a
  third of the bats tests.
- The groups are the dependencies of the `checks` recipe, and a group's checks are its own
  dependencies; a new check goes into exactly one group, and then runs in `just checks`, in
  `just ci` and in CI.
- `just test` runs the bats tests but the hermetic ones, the tests of each file side by side (a file
  whose tests share state runs them one at a time, and says why); `just test 2/3` runs the second
  of three parts of the test files, which are split by their number of tests.
- `just ci` runs the same groups through the Dagger module in `.dagger/modules/ci`, side by side,
  each in containers of its own: Renovate's validator in its own image, every other check in a
  container built from the pins. `just ci tests-2` runs one group, as each CI job does. It needs
  only `just`, the pinned `dagger` and a container runtime such as Docker. Every group runs to its
  end, and the run ends with each group's output under a heading `== <group>: passed` or
  `failed`, followed by its checks, and a line naming the groups that failed. Dagger shows every
  step and each check's output while it runs: its live view in a terminal, and line by line where
  there is none, as in CI. The live view can name the checkout's path on the machine, so paste the
  checks' own lines into a pull request, not the whole of it.
- In CI, a first job lists the groups (`just ci-groups`), one job per group runs `just ci <group>`,
  each showing its own result on the pull request, and the job named `ci`, the required check on
  `main`, passes only when every one of them succeeded (`just ci-passed`).
- `just test-hermetic` runs the bats tests that drive `just ci` itself.

`docs/infrastructure.md` covers the recipes that plan, apply and destroy the OpenTofu stacks: what
they need in the environment, how state is stored and encrypted, and what they print.
`docs/cluster.md` covers the recipes that create and change the Talos cluster. `docs/kubernetes.md`
covers the tree Flux reconciles and how the publish workflow pushes, signs and verifies it before
moving the `main` tag Flux follows, on every merge to `main` that changes it. `docs/runbooks/`
holds the procedures that take more than one recipe, such as replacing the Talos image.

Behaviour is specified as Given/When/Then scenarios in `features/`, each proved by a bats
`@test` with its title, an OpenTofu `run` named after its slug, or a `@by:<recipe>` tag naming
the `just` recipe whose tool run verifies it, or tagged `@pending` with its issue key.

The repository checks:

- `just tools-check` fails when a pinned tool is missing or its binary reports a different version.
- `just kubernetes-check` builds `kubernetes/` offline with kustomize and Flux and fails when an
  application, a `ks.yaml` or a variable breaks the layout in `docs/kubernetes.md`.
- `just check-literals` fails when a file git would commit, tracked or untracked and not ignored,
  holds an IPv4 literal outside the documentation ranges, loopback, `0.0.0.0`, the metadata
  address and netmasks, unless `.address-allowlist` declares it with a reason. It skips the
  address check's own fixtures in `tests/fixtures/check-address-literals/`, which exist to be
  flagged; so does gitleaks.
- `just check-commit-literals` applies the same rules to the messages of the commits between the
  default branch (the remote's, the remote's `main` as a CI checkout fetches it, or a local
  `main`) and `HEAD`, and passes when there is none.
- `just scenarios-check` fails when a scenario has no proof or more than one, when a `@pending`
  scenario has no issue key or already has a proof, when a `@by:` tag names a recipe that does
  not exist, when two scenarios share a title, or when a test claims a scenario that does not
  exist. It does not run `@by:` recipes. `scripts/scenarios-check` gives the slug rule and how a
  test that proves no scenario is named.

## Acknowledgements

The Flux layout and a number of manifests are adapted from
[xunholy/k8s-gitops](https://github.com/xunholy/k8s-gitops), which is published under the
Apache License 2.0.
