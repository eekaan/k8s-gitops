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
- `just ci` runs every check that needs no credentials: tool versions, address literals,
  shellcheck and yamllint, scenario proofs, the OpenTofu check (`just infra-check`: formatting,
  validation without a state backend and the mocked `tofu test` runs), the offline build of
  `kubernetes/`, gitleaks over the committable files and the git history, and the bats tests.

Behaviour is specified as Given/When/Then scenarios in `features/`, each proved by a bats
`@test` with its title, an OpenTofu `run` named after its slug, or a `@by:<recipe>` tag naming
the `just` recipe whose tool run verifies it, or tagged `@pending` with its issue key.

The repository checks:

- `just tools-check` fails when a pinned tool is missing or its binary reports a different version.
- `just kubernetes-check` builds `kubernetes/` offline with kustomize and Flux and fails when an
  application, a `ks.yaml` or a variable breaks the layout in `docs/kubernetes.md`.
- `just check-literals` fails when a tracked file holds an IPv4 literal outside the documentation
  ranges, loopback, `0.0.0.0`, the metadata address and netmasks, unless `.address-allowlist`
  declares it with a reason.
- `just scenarios-check` fails when a scenario has no proof or more than one, when a `@pending`
  scenario has no issue key or already has a proof, when a `@by:` tag names a recipe that does
  not exist, when two scenarios share a title, or when a test claims a scenario that does not
  exist. It does not run `@by:` recipes. `scripts/scenarios-check` gives the slug rule and how a
  test that proves no scenario is named.

## Acknowledgements

The Flux layout and a number of manifests are adapted from
[xunholy/k8s-gitops](https://github.com/xunholy/k8s-gitops), which is published under the
Apache License 2.0.
