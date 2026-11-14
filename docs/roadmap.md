# Roadmap

Milestones in the order they are built. Each is finished when its outcome has been shown on the
running cluster, not when its code is merged.

| | Milestone | State | Outcome | Shown by |
|---|---|---|---|---|
| M0 | Foundations | in progress | The repository validates itself; nothing is deployed. | `just ci` passes locally and on a pull request; a broken file or a committed address literal fails it. |
| M1 | Infrastructure | in progress | One command gives six virtual machines waiting for Talos configuration, reachable on the Talos API from the operator only. | A plan shows the expected resources; after apply the Talos API answers from the operator's address and from nowhere else. |
| M2 | Cluster | not started | One command gives six Ready nodes with Cilium, repeatable from nothing. | Bootstrap ends with six Ready nodes and no kube-proxy; a control-plane reboot does not interrupt the API; destroy and rebuild reproduces it. |
| M3 | GitOps core | not started | A merge to `main` reconciles the cluster from a signed artifact, and an unsigned one is refused. | A pull request shows its rendered diff; merging moves the cluster to the new revision; an unsigned artifact is rejected. |
| M4 | Platform services | not started | An application gets a volume, a public hostname, a certificate and a secret from Git alone. | A test application answers over HTTPS with a valid certificate, a bound volume and a secret from the secret store; teardown leaves nothing behind. |
| M5 | Observability | not started | A broken node, application or reconcile reaches the operator. | A stopped node and a deliberately broken release each raise an alert that arrives. |
| M6 | Data and backups | not started | Losing the cluster loses no data. | A timed drill: destroy, rebuild, restore the secret store, a volume and a database to a point in time. |
| M7 | Workloads | not started | The services the cluster exists for. | Each application answers on its hostname and survives a node drain. |
| M8 | Hardening and automation | not started | Infrastructure and upgrades run without a laptop; the cluster is locked down. | A merge that changes infrastructure is planned and applied by CI; a pod in a default-deny namespace cannot reach another namespace. |

The decisions behind this order are in [`docs/adr/`](adr/).
