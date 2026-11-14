# 0007 — CI is a Dagger module run by GitHub Actions, behind just

- Status: accepted
- Date: 2026-11-14

## Context

The checks a pull request gets should be the checks a person runs before pushing, with the same
tool versions.

## Decision

`just` is the entry point on a laptop and in CI. The checks themselves are functions of a
Dagger module in this repository, which runs each in a container with pinned tools. GitHub
Actions is the CI system: each job runs one `just` recipe on GitHub's runners, and a job that runs
the checks starts the Dagger engine for itself.

Publishing the cluster's artifact (ADR 0003) is the one job whose recipe, `just publish`, runs
directly on the runner, with the tools pinned in `mise.toml` installed there by mise. Signing it
keyless takes the job's own identity token, and pushing it the job's registry token; the module
never gets either, so the checks stay hermetic and need no credentials, and nothing the module runs
can sign or publish.

One job always runs and aggregates the others; it is the only required check on `main`, so
path-filtered jobs never leave a pull request waiting.

The module uses Dagger 1.0, which is in beta at the time of writing.

## Alternatives considered

- **Checks run directly on the runner.** Nothing to learn, but tool installation is repeated
  per workflow and drifts from the laptop.
- **Dagger's own pull request integration instead of Actions.** Needs a hosted account, and
  keyless artifact signing depends on the Actions OIDC token.
- **A long-lived shared Dagger engine.** Keeps caches warm, at the cost of a privileged
  service to run and secure. The checks here are light enough not to need it.

## Consequences

- A workflow file contains no logic beyond calling a recipe, so the module can be replaced
  without changing what a job is called or what it proves.
- The module format follows the 1.0 beta and may change before 1.0 is stable; the move to the
  stable release is planned work.
- Jobs that need credentials do not run for pull requests from forks.
- The publish job installs its tools on the runner with mise, from the same pins as the module's
  container and a laptop, so publishing does not depend on the module.
