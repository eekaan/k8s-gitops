# k8s-gitops

Talos Kubernetes on OpenStack: VMs from OpenTofu, Talos machine config through talman,
everything above reconciled by Flux. Decisions are in `docs/adr/`; standing rules are in
`constitution.md`.

## Public repository

Everything pushed here is world-readable: files, commit messages, branch names, pull request
titles, bodies and review comments, CI logs. Never put in any of them:

- Addresses, CIDRs, floating IPs; project, tenant, user, subnet or network IDs; usernames; quota
  figures; hostnames of anything not deliberately public.
- Anything learned from a private source: internal systems or documents, private repositories,
  or operating the cloud rather than reading its public documentation. Describe a workaround by
  what the code does and the public fact behind it.
- Security gaps before they are closed, the operator allowlist, credential scopes.
- Planning detail: priorities, blockers, to-do lists, session history. Work is tracked outside
  this repository. A pull request says what the change does and ends its title with the issue
  key, e.g. `add cluster stack (INF-6)`.

Values that depend on the deployment (public addresses, IDs, the allowlist) are read from
gitignored files, CI secrets or tofu outputs at run time. They are never committed.

Private ranges the code itself defines (the node subnet, the pod and service ranges) are part of
the design. Each is declared in `.address-allowlist` with the reason it is safe to publish;
`just check-literals` fails on any other address. Test fixtures that must be flagged use the
reserved class E range, and examples use the documentation ranges.

## Agents

- Commit, push feature branches and open pull requests. Never push to `main`, never merge,
  never sign commits. No trailers or footers in commit messages or pull request descriptions.
- Nothing discards work: no `git reset --hard`, `git checkout` or `git restore` over a path,
  `git clean`, `git stash`, `git branch -D`, `git worktree remove` or `prune`, or `rm` on
  tracked files.
- Live systems: this repository's own OpenStack project, its Talos nodes and its Kubernetes
  API, through the `just` recipes. No other project, region, cluster or host.
- OpenTofu and Talos changes may be applied from a pull request branch. Flux follows `main`
  only; never point it at another ref.
- Credentials reach recipes through the environment. Never read, print, copy or commit key
  material, cloud credentials, `.env*`, tofu state, kubeconfigs, talosconfig or decrypted SOPS
  content.
- An issue is done when its change is merged and proved on the live cluster, not when its pull
  request opens.

## Working here

- `just` is the entry point for everything a person or CI runs. Add a recipe instead of
  documenting a command.
- Behaviour is specified as Given/When/Then scenarios in `features/` and proved by the
  repository's own verification, as `constitution.md` sets out.
- Docs move with the code in the same change and describe the present state.
