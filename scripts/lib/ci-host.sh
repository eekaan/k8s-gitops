# shellcheck shell=bash
# Shared by the ci-runner recipe, scripts/ci-host-setup and scripts/ci-host-remove: which GitHub
# Actions jobs the CI host runs, and the SSH connection to it.
#
# A pull request's workflow runs from the pull request's merge commit, so a fork's pull request runs
# the fork's own copy of the workflow file, which can ask for the host's label itself. The workflow
# alone cannot keep a fork's job off the host, so the host decides as well: the runner's job-started
# hook, written from ci_host_admits below, fails every other job before any of its steps runs.

# shellcheck source=scripts/lib/host-keys.sh
. "$(dirname "${BASH_SOURCE[0]}")/host-keys.sh"

# ci_host_admits: whether the job GitHub Actions' default variables describe may run on the CI host:
# a job of this repository's CI workflow, .github/workflows/ci.yaml, for a push to main or a pull
# request whose head is a branch of this repository. Says on stderr what it refuses. Reads the
# event's payload, which GitHub writes, with jq. Self-contained, as the hook is written from it.
ci_host_admits() {
  local repository=${GITHUB_REPOSITORY-} head
  if [[ -z $repository ]]; then
    echo "jobs without GITHUB_REPOSITORY" >&2
    return 1
  fi
  if [[ ${GITHUB_WORKFLOW_REF-} != "$repository/.github/workflows/ci.yaml@"* ]]; then
    echo "jobs of workflows other than .github/workflows/ci.yaml" >&2
    return 1
  fi
  case ${GITHUB_EVENT_NAME-} in
    push)
      [[ ${GITHUB_REF-} == refs/heads/main ]] && return 0
      echo "pushes to refs other than main" >&2
      ;;
    pull_request)
      head=$(jq -r '.pull_request.head.repo.full_name // "" | strings' "${GITHUB_EVENT_PATH:-/dev/null}" 2> /dev/null) || head=
      [[ -n $head && $head == "$repository" ]] && return 0
      echo "pull requests from other repositories" >&2
      ;;
    *)
      echo "${GITHUB_EVENT_NAME:-unnamed} events" >&2
      ;;
  esac
  return 1
}

# ci_host_hook: prints the CI host's job-started hook, the runner's ACTIONS_RUNNER_HOOK_JOB_STARTED.
# The runner fails a job, before any of its steps runs, when the hook exits non-zero.
ci_host_hook() {
  printf '%s\n' '#!/usr/bin/env bash' \
    '# The CI host'\''s job-started hook, written by scripts/ci-host-setup from scripts/lib/ci-host.sh.' \
    'set -u'
  declare -f ci_host_admits
  cat << 'EOF'
if ! reason=$(ci_host_admits 2>&1); then
  echo "ci-host: refused: this host does not run $reason" >&2
  exit 1
fi
EOF
}

# ci_host_connect: once scripts/stack-env has been sourced with sto2/ci and the stack is locked and
# initialised, reads the host from the stack's outputs and makes sure its SSH host key is recorded.
# Sets ci_host_address, ci_host_instance (empty when the outputs hold no instance identifier),
# ci_host_runner_name, ci_host_runner_user and ci_host_cache. The address is never printed.
ci_host_connect() {
  local outputs
  outputs=$(stack_tofu output -json) || return 1
  # tofu's JSON holds every output's value, sensitive ones included; only jq reads it.
  ci_host_address=$(jq -r '.address.value // "" | strings' <<< "$outputs")
  ci_host_instance=$(jq -r '.instance.value.id // "" | strings' <<< "$outputs")
  [[ $ci_host_instance =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]] || ci_host_instance=
  ci_host_runner_name=$(jq -r '.runner_name.value // "" | strings' <<< "$outputs")
  ci_host_runner_user=$(jq -r '.runner_user.value // "" | strings' <<< "$outputs")
  ci_host_cache=$(jq -r '.cache_mountpoint.value // "" | strings' <<< "$outputs")
  if [[ ! $ci_host_address =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || ! $ci_host_runner_name =~ ^[a-z0-9-]+$ ||
    ! $ci_host_runner_user =~ ^[a-z][a-z0-9-]*$ || ! $ci_host_cache =~ ^/[a-z0-9/_-]+$ ]]; then
    # shellcheck disable=SC2154 # scripts/stack-env sets stack
    infra_error "$stack has no address, runner_name, runner_user and cache_mountpoint outputs: it is not applied"
    return 1
  fi
  ci_host_known_hosts=${XDG_STATE_HOME:-$HOME/.local/state}/k8s-gitops/ci-host.known_hosts
  ci_host_trust
}

# ci_host_trust: ssh_host_trust for the CI host, reading its instance's console for up to
# HOST_CONSOLE_WAIT seconds, 30 when unset (host_console_wait).
ci_host_trust() {
  host_console_wait || return 1
  ssh_host_trust "$ci_host_address" "$ci_host_known_hosts" "CI host" "$ci_host_instance" "$host_console_wait"
}

# ci_host_ssh COMMAND: runs COMMAND, one string, on the host as CI_HOST_SSH_USER, with strict host key
# checking against the recorded key only, and without asking for a password.
ci_host_ssh() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$ci_host_known_hosts" \
    -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o ConnectTimeout=30 \
    "$CI_HOST_SSH_USER@$ci_host_address" "$1"
}

# ci_host_runner_token KIND: prints a registration or remove token for the repository's runners,
# KIND registration-token or remove-token, from gh. The caller keeps it in a variable and hands it on
# standard input only.
ci_host_runner_token() {
  local token
  token=$(gh api --method POST "repos/$ci_host_repository/actions/runners/$1" --jq .token) || token=
  if [[ ! $token =~ ^[A-Za-z0-9_.-]+$ ]]; then
    infra_error "gh gave no $1; it needs to be logged in as an account that manages the repository's runners"
    return 1
  fi
  printf '%s' "$token"
}

# ci_host_repository: sets ci_host_repository and ci_host_repository_url to the repository gh
# resolves from this checkout.
ci_host_repository() {
  ci_host_repository_url=$(gh repo view --json url --jq .url) || ci_host_repository_url=
  ci_host_repository=${ci_host_repository_url#https://github.com/}
  if [[ $ci_host_repository_url != https://github.com/* || ! $ci_host_repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    infra_error "gh resolves no GitHub repository from this checkout"
    return 1
  fi
}

# ci_host_as_runner SCRIPT [ARG...]: runs the one-line SCRIPT with bash as the runner's user, its
# home as HOME, with ARG... as its arguments and this function's standard input as its own. Every
# word is quoted for the host's login shell.
ci_host_as_runner() {
  local command
  command=$(printf '%q ' sudo -n -H -u "$ci_host_runner_user" bash -c "$1" bash "${@:2}")
  ci_host_ssh "${command% }"
}
