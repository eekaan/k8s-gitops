# 0001 — Talos on OpenStack VMs from OpenTofu, configured by talman

- Status: accepted
- Date: 2026-11-14

## Context

The cluster runs on OpenStack virtual machines. Something has to create the networks, images
and instances, and something has to produce and apply each node's Talos machine configuration,
with the node addresses flowing from the first to the second.

## Decision

OpenTofu owns every OpenStack resource: networks, router, security groups, the Talos image,
instances that boot from volume, floating IPs and the API load balancer. One stack holds the
shared plumbing and one holds the cluster, each with its own state.

Talos machine configuration is rendered and applied by [talman](https://github.com/ludwighansson/talman)
from explicitly listed patch files. Its `talman.yaml` is rendered from an OpenTofu output, so
node names and addresses have one source. The file is generated, not committed.

Nodes boot without machine configuration and wait in maintenance mode; talman applies it over
the Talos API. No machine configuration is passed as instance user data, so no cluster secret
enters tofu state.

Each node has a floating IP so it can be reached from outside the network, and holds that
address on a dummy link so the Talos API answers requests addressed to it.

## Alternatives considered

- **Machine configuration as user data.** One step fewer, but the cluster's CA keys land in
  tofu state and in the instance metadata.
- **talhelper.** Archived upstream.
- **Raw `talosctl gen config` with hand-merged patches.** No ordered patch chain per node, no
  rollout handling, and nothing to keep the result reproducible.
- **Nodes without floating IPs behind a bastion.** A smaller surface, but every Talos change
  from CI needs a tunnel.

## Consequences

- talman is pre-1.0. Its version is pinned and asserted by the recipes, and machine
  configuration is rendered and validated offline in CI before anything reaches a node.
- The Talos API is reachable on public addresses, so security groups admit it only from an
  operator allowlist that is supplied at run time and never committed.
- A new Talos image does not replace running nodes; upgrades go through the Talos API.
