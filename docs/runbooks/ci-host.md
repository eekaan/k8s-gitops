# The CI host

The CI host is a Linux VM on the node network, outside the cluster, made by the `sto2/ci` stack
([infrastructure.md](../infrastructure.md#the-ci-host)). `just ci-host-setup` makes it this
repository's GitHub Actions runner, with a Dagger engine that keeps running between jobs and keeps
its cache on a volume of its own, so the checks reuse what earlier runs built
([ADR 0012](../adr/0012-ci-runs-on-a-self-hosted-runner-for-trusted-events.md)).

## Who runs on it

Only the CI workflow's jobs for a push to `main` or a pull request whose head is a branch of this
repository. Everything else runs on GitHub's hosted runners: pull requests from forks, the publish
and tools image workflows, and every job while the repository variable `CI_RUNNER_LABEL` is not
set.

Two things decide it, by the same rule in `scripts/lib/ci-host.sh`:

- The CI workflow's `runner` job runs `just ci-runner`, which gives the check jobs the label in
  `CI_RUNNER_LABEL` for a trusted run and `ubuntu-latest` otherwise. The other jobs name
  `ubuntu-latest` themselves.
- The host's job-started hook, which the runner runs before every job, fails any job the rule does
  not admit before any of its steps runs. A fork's pull request runs the workflow file from the
  pull request's merge commit, the fork's own copy, which can name the host's label directly; the
  hook is on the host, where a fork cannot change it.

## The repository's settings

The owner sets these once, in the repository's settings on GitHub:

1. **Actions, General, "Approval for running fork pull request workflows from contributors"**:
   choose **"Require approval for all external contributors"**. A fork's run then waits until a
   maintainer approves it, after reading what it changes, the workflow files among them. The
   other two choices let anyone who once had a commit merged run without approval.
2. **Secrets and variables, Actions, Variables**: the repository variable `CI_RUNNER_LABEL`, set to
   the runner's name once `just ci-host-setup` has registered it (see below). Deleting it sends
   every job back to the hosted runners.
3. **Runners**: the runner is registered with the repository itself, so no runner group serves it.
   If the repository belongs to an organization, its runner groups stay closed to public
   repositories, which is their default, so that no organization runner takes this repository's
   jobs.

## Creating it

1. In `.env`: `CI_HOST_IMAGE`, the name of a Debian or Ubuntu cloud image in the project;
   `CI_HOST_SSH_PUBLIC_KEY`, the operator's SSH public key; and `CI_HOST_SSH_USER`, that image's
   default user. The allowlist and the state settings are the ones the other stacks use.
2. `just infra-plan sto2/ci`. The summary creates a security group and its rules, a key pair, a
   volume, a port, an instance, a volume attachment, a floating IP and its association.
3. `just infra-apply sto2/ci`, typing `sto2/ci` back.
4. For the host to reach the nodes' Talos and Kubernetes APIs: `TF_VAR_ci_host_number=6`, the ci
   stack's `host_number`, in `.env`, then `just infra-apply sto2/cluster`. Its summary creates two
   `openstack_networking_secgroup_rule_v2` and changes nothing else.

## Setting it up

`just ci-host-setup`, once the host has booted. It waits for the host's first boot to finish.

The first time, the host's SSH key is not recorded. The recipe prints the fingerprints of the keys
the host offers. Compare them with the ones the host printed at its first boot, between
`BEGIN SSH HOST KEY FINGERPRINTS` and `END SSH HOST KEY FINGERPRINTS` in the instance's console
log in the cloud's dashboard, and type `yes` only if they match. The key is then recorded in
`~/.local/state/k8s-gitops/ci-host.known_hosts`, and every later connection is refused if the host
offers another.

It then prints a line per step, `ci-host: started the pinned engine`, `installed the runner`,
`wrote the job-started hook`, `wrote the runner's service`, registers the runner with a token from
`gh`, which must be logged in as an account that manages the repository's runners, starts it, and
ends with the runner's name. Set `CI_RUNNER_LABEL` to that name.

A second run prints `nothing changed` and asks GitHub for nothing.

## Seeing a run land on it

Push to a branch of this repository and open a pull request, or merge one. In the run:

- The `runner` job's `just ci-runner` step prints the runner's name.
- Each `check` job's "Set up job" step names the runner, and its "Set up runner" step is the
  job-started hook, which passes.
- On a fork's pull request, the `runner` job prints that the run goes to a hosted runner, as the
  CI host does not run pull requests from other repositories.

## Updating and rotating

- **A new runner release**: Renovate proposes the version in `versions.yaml`; the pull request
  also changes `actions_runner_sha256` (`.renovate/by-hand.tsv` says how). Once it is merged, `just ci-host-setup` installs it and restarts the runner.
- **A new Dagger version**: `dagger_engine` in `versions.yaml` moves with the `dagger` pin in
  `mise.toml` (`.renovate/by-hand.tsv` says how). `just ci-host-setup` replaces the engine's
  container; the cache stays on the volume.
- **New runner credentials**: `just ci-host-remove`, then `just ci-host-setup`.
- **A new instance**: changing the image or the user data replaces the instance at the next
  `just infra-apply sto2/ci`. The cache volume stays. The new instance has a new SSH key, so the
  recorded one no longer matches and setup is refused: remove
  `~/.local/state/k8s-gitops/ci-host.known_hosts`, then run `just ci-host-setup` and compare the new
  fingerprints. Registering under the same name replaces the old runner.

## Removing it

1. Delete the repository variable `CI_RUNNER_LABEL`, so that no job waits for a runner that is
   going away.
2. `just ci-host-remove`: stops the runner's service and deregisters it with a remove token from
   `gh`. The engine and its cache stay.
3. Remove `TF_VAR_ci_host_number` from `.env` and `just infra-apply sto2/cluster`: the summary
   deletes the nodes' two rules for the host.
4. `just infra-destroy sto2/ci`, typing `sto2/ci` back. The cache volume goes with the stack.
5. Remove `~/.local/state/k8s-gitops/ci-host.known_hosts`.
