# k8s-gitops

Talos Kubernetes on OpenStack, provisioned with OpenTofu and reconciled by Flux.

## Working on it

Every tool is pinned to an exact version in `mise.toml`. With [mise](https://mise.jdx.dev) and
[just](https://just.systems) installed:

- `just tools` installs the pinned tools.
- `just ci` runs every check that needs no credentials: tool versions, address literals,
  shellcheck and yamllint, gitleaks over the committable files and the git history, and the
  bats tests.

The two repository checks:

- `just tools-check` fails when a pinned tool is missing or its binary reports a different version.
- `just check-literals` fails when a tracked file holds an IPv4 literal outside the documentation
  ranges, loopback, `0.0.0.0`, the metadata address and netmasks, unless `.address-allowlist`
  declares it with a reason.
