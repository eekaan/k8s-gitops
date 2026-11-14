# 0012 — CI runs on a self-hosted runner with a persistent engine for trusted events, hosted runners otherwise

- Status: accepted
- Date: 2026-11-14

## Context

Every CI job on GitHub's hosted runners starts a Dagger engine of its own with an empty cache, so
each group of checks pulls its images and installs the pinned tools from nothing (ADR 0007). A
runner of our own, with an engine that keeps running and keeps its cache, would reuse that work.

The repository is public. GitHub advises against self-hosted runners for public repositories:
anyone can open a pull request, and a pull request's workflow runs from the pull request's merge
commit, so a fork's pull request runs the fork's own copy of the workflow, which can ask for any
runner label. Nothing written in a workflow file can keep a fork's job off a self-hosted runner.

## Decision

A small Linux VM in the node network, outside the cluster, its own OpenTofu stack (`sto2/ci`),
reachable over SSH from the operator allowlist only, runs a GitHub Actions runner for this
repository and a Dagger engine as a long-running container whose state lives on a volume of its
own. Jobs on it use that engine through its socket.

It runs only the CI workflow's jobs for a push to `main` or a pull request whose head is a branch
of this repository: work that someone with write access put there. Pull requests from forks, the
publish workflow, and everything while no runner is configured run on GitHub's hosted runners.

One rule, in `scripts/lib/ci-host.sh`, decides it twice. The CI workflow applies it when it picks
the check jobs' runner, so the runs it admits go to the host and the others to hosted runners. The
host applies it again in the runner's job-started hook, which fails any job it does not admit
before any of its steps runs; the hook lives on the host, where a fork cannot change it. The
repository also requires approval before a fork's run starts, for every external contributor.

The runner's user is unprivileged and not in the docker group. The engine runs with no root
capabilities for what it executes, and its socket is open to the runner's user only.

## Alternatives considered

- **Runners inside the cluster** (Actions Runner Controller). Scales with the cluster and needs no
  VM of its own, but puts untrusted-adjacent build work and a privileged engine next to the
  workloads, and ties CI to the cluster that CI is meant to verify and rebuild.
- **Hosted runners only**, as before. Nothing to run or secure, and every fork is safe by
  construction; every run starts from an empty cache.
- **A paid build service** with persistent caches, such as Dagger Cloud's engines or a hosted
  runner provider. Keeps caches without a host of our own, at a recurring cost, with the cache and
  the build in a third party's hands.

## Consequences

- Trusted runs reuse the engine's cache; fork runs are as they were.
- The host is one more machine to patch, and its runner and engine are pinned in `versions.yaml`
  and updated by hand with Renovate's help.
- The groups of checks run one after another on the host's one runner, instead of side by side on
  hosted runners.
- The cluster stack lets the host reach the nodes' Talos and Kubernetes APIs only when it is given
  the host's number, so it plans with or without the host.
- Removing the repository variable `CI_RUNNER_LABEL` sends every job back to hosted runners.
