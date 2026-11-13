# 0010 — What a public repository may contain

- Status: accepted
- Date: 2026-11-14

## Context

This repository is public and describes infrastructure that is running. Files, commit
messages, branch names, pull request text and CI logs are all readable by anyone, and stay
readable after they are changed.

## Decision

The repository holds architecture, versions, module and manifest code, decision records and a
milestone-level roadmap.

It does not hold, in any of those places: addresses or identifiers of the deployment, the
operator allowlist, anything learned from a private source, security gaps that are still open,
or planning detail. `CLAUDE.md` carries the full list.

Deployment-specific values are supplied at run time from gitignored files, CI secrets or tofu
outputs. Work is tracked outside the repository; a pull request names its issue key and
describes the change, nothing more.

CI enforces what it can: secret scanning, a check for address literals outside test fixtures,
and plan output that reports counts instead of resource attributes.

## Alternatives considered

- **A private repository.** Removes the problem, and with it the value of a public example.
- **Public issue tracking with a redaction rule.** Depends on the rule being applied every
  time, by every contributor and agent.

## Consequences

- Some context that would help a reader is missing by design; decision records explain the
  design without the deployment.
- A value that turns out to have been committed is treated as disclosed: it is changed at the
  source, not only removed from the tree.
