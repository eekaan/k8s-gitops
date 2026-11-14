# 0007 — CI is a Dagger module run by GitHub Actions, behind just

- Status: accepted
- Date: 2026-11-14

## Context

The checks a pull request gets should be the checks a person runs before pushing, with the same
tool versions.

## Decision

`just` is the entry point on a laptop and in CI. The checks themselves are functions of a
Dagger module in this repository, which runs each in a container with pinned tools. GitHub
Actions is the CI system: each job runs one `just` recipe, on GitHub's runners, where a job that
runs the checks starts the Dagger engine for itself, or, for trusted runs, on the CI host's
self-hosted runner, where it uses the host's persistent engine (ADR 0012).

The jobs that publish, the cluster's artifact (ADR 0003) with `just publish` and the tools image
with `just tools-image-publish`, run their recipes directly on the runner, with the tools pinned in
`mise.toml` installed there by mise. Signing keyless takes the job's own identity token, and
pushing the job's registry token, which reaches a Docker configuration of the run's own; no
function of the module takes either, so the checks stay hermetic and need no credentials, and
nothing the checks run can sign or publish.

The container the checks run in is built from the pins once for each change of its inputs (the
base image, the package step and `mise.toml`), by the tools image workflow on `main`, pushed to
this repository's registry, signed, and recorded by digest in `versions.yaml` with the key of those
inputs. `just ci` hands the module that image while the key matches the checkout's inputs, and the
module builds the same layer itself otherwise.

One job always runs and aggregates the others; it is the only required check on `main`, so
path-filtered jobs never leave a pull request waiting.

The module uses Dagger 1.0, which is in beta at the time of writing.

## Alternatives considered

- **Checks run directly on the runner.** Nothing to learn, but tool installation is repeated
  per workflow and drifts from the laptop.
- **Dagger's own pull request integration instead of Actions.** Needs a hosted account, and
  keyless artifact signing depends on the Actions OIDC token.
- **A long-lived shared Dagger engine.** Keeps caches warm, at the cost of a privileged
  service to run and secure. ADR 0012 adopts one for trusted runs.

## Consequences

- A workflow file contains no logic beyond calling a recipe, so the module can be replaced
  without changing what a job is called or what it proves.
- The module format follows the 1.0 beta and may change before 1.0 is stable; the move to the
  stable release is planned work.
- Jobs that need credentials do not run for pull requests from forks.
- The publish job installs its tools on the runner with mise, from the same pins as the module's
  container and a laptop, so publishing the cluster's artifact does not depend on the module. The
  tools image job builds its image with the module's own layer, so the checks run in what the
  module would build.
- A change to the pins takes a second pull request, after the merge, to record the new tools
  image; until then the checks build the tools themselves, as they do on an engine of another
  platform than the image's.
