# 0006 — DNS and certificates through Cloudflare

- Status: accepted
- Date: 2026-11-14
- Amended: 2026-11-15, two ACME issuers, Let's Encrypt's staging and production, and each cluster chooses
  which signs its gateway's certificate, the cluster's own CA when it chooses none
- Note: 2026-11-15, `lab-sto2` chooses the staging issuer, whose certificates no client outside
  the cluster trusts ([The ACME issuers](../kubernetes.md#the-acme-issuers))

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
