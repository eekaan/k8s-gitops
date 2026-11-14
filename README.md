# k8s-gitops

Talos Kubernetes on OpenStack, provisioned with OpenTofu and reconciled by Flux.

## Working on it

Every tool is pinned to an exact version in `mise.toml`. With [mise](https://mise.jdx.dev) and
[just](https://just.systems) installed:

- `just tools` installs the pinned tools.
- `just ci` runs every check that needs no credentials: tool versions, address literals,
  shellcheck and yamllint, scenario proofs, the OpenTofu check (`just infra-check`: formatting,
  validation without a state backend and the mocked `tofu test` runs), gitleaks over the
  committable files and the git history, and the bats tests.

Behaviour is specified as Given/When/Then scenarios in `features/`, each proved by a bats
`@test` with its title, an OpenTofu `run` named after its slug, or a `@by:<recipe>` tag naming
the `just` recipe whose tool run verifies it, or tagged `@pending` with its issue key.

The three repository checks:

- `just tools-check` fails when a pinned tool is missing or its binary reports a different version.
- `just check-literals` fails when a tracked file holds an IPv4 literal outside the documentation
  ranges, loopback, `0.0.0.0`, the metadata address and netmasks, unless `.address-allowlist`
  declares it with a reason.
- `just scenarios-check` fails when a scenario has no proof or more than one, when a `@pending`
  scenario has no issue key or already has a proof, when a `@by:` tag names a recipe that does
  not exist, when two scenarios share a title, or when a test claims a scenario that does not
  exist. It does not run `@by:` recipes. `scripts/scenarios-check` gives the slug rule and how a
  test that proves no scenario is named.
