# Constitution

## Stack
- OpenTofu for OpenStack resources, talman and talosctl for Talos, Flux for everything in the
  cluster, bash for scripts, `just` for every command.
- Tool versions are pinned in `mise.toml` and recipes run the pinned binaries. A new tool gets
  its pin in the same change.
- CI is a Dagger module run by GitHub Actions. Each job runs one `just` recipe; no logic lives
  only in a workflow file.
- Replacing something decided in `docs/adr/` needs a new decision record first.

## Tests
- `just ci` runs every check that needs no credentials. It is what CI runs.
- Behaviour is specified as Given/When/Then feature files in `features/`, each proved under its
  scenario name by the repository's real verification: `tofu validate` and `tofu test` for
  stacks and modules, the offline Talos render check for machine config, the Flux render for
  manifests, bats for scripts. A scenario without a passing proof is `@pending` with its issue
  key.
- Proof first: the scenario and its failing check exist before the change that satisfies them.
  No invented unit tests for configuration.

## Done means
- Every scenario of the change passes under `just ci`.
- Docs are updated in the same change and describe the present state.
- CI is green on the pull request, and a change with a live effect is proved on the cluster
  after merge.

## Standing constraints
- The repository is public. Nothing on the public-repository list in `CLAUDE.md` is pushed, in
  any form.
- No secret in plaintext, in Git or in tofu state. Bootstrap material is SOPS-encrypted with
  age; runtime secrets come from the secret store through External Secrets.
- No machine configuration in instance user data.
- Flux reconciles only from the signed artifact built from `main`. Nothing Flux owns is applied
  by hand, except the documented bootstrap set.
- `main` changes only through pull requests. Agents never push to it or merge.
- A recipe that changes live state is idempotent, shows a plan or diff first where the tool has
  one, and exits non-zero with the reason when it fails.
- Deployment-specific values (addresses, IDs, allowlists) come from gitignored files, CI
  secrets or tofu outputs, never from committed files.

## Amendment
Changes to this file are their own commit, with the reason in the message.
