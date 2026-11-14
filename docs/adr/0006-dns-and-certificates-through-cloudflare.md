# 0006 — DNS and certificates through Cloudflare

- Status: accepted
- Date: 2026-11-14

## Context

Public services need DNS records that follow the cluster's routes and certificates that renew
without a person.

## Decision

The domain's zone is hosted at Cloudflare. cert-manager issues certificates from Let's Encrypt
with the DNS-01 challenge against that zone, including a wildcard certificate for the
gateways. external-dns writes records from `HTTPRoute` objects. Both read their API token from
the secret store.

## Alternatives considered

- **DNS in the cloud's own DNS service.** One provider fewer, but cert-manager has no built-in
  solver for it, so certificates would need HTTP-01 or a third-party webhook, and wildcards
  would not be available through HTTP-01.

## Consequences

- An API token scoped to the zone is a runtime secret.
- The cluster is reachable by address only until the gateways and DNS are in place.
