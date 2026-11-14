# 0014 — Logs in VictoriaLogs, collected by Vector

- Status: accepted
- Date: 2026-11-14

## Context

Metrics show that something broke; logs show why, and Talos has no shell to read them on a node.
The cluster needs one store for the logs of every pod and of every node's own services and kernel,
for one small cluster run by few operators, kept for about two weeks, on the block storage LINSTOR
provides (ADR 0011). Object storage is not wanted for logs. The two candidates are Grafana Loki and
VictoriaLogs.

What their current documentation and charts say:

| | Loki, monolithic | VictoriaLogs, single node |
|---|---|---|
| Resource needs | No figures for this mode. The chart adds a chunks cache of 8 GiB and a results cache of 1 GiB, both memcached, by default. | No figures: keep half the memory and CPU spare. The publisher claims up to 30 times less memory than Loki, from its own benchmarks. |
| Storage model | An index and chunks meant for an object store. The filesystem serves a single replica, which the documentation calls fit for testing, development or meta-monitoring, and is "susceptible to data loss as it's unreplicated". More replicas need an object store. | A directory of per-day partitions on a local filesystem, the design's normal case. High availability is whole copies, each fed by the collectors. |
| Retention | The compactor deletes by age only; Loki does not delete when the disk fills, which is left to something outside it. | By age and by disk use, `-retentionPeriod` and `-retention.maxDiskSpaceUsageBytes`, oldest days first, always keeping the last two days. |
| Operational parts | Loki, an NGINX gateway, a canary on every node and two memcached caches by default; a schema configuration with dated periods to keep across upgrades. | One process in one StatefulSet. |
| Query language | LogQL | LogsQL |
| Grafana | A data source built into Grafana. | The `victoriametrics-logs-datasource` plugin, Apache-2.0, installed into Grafana. |
| Licence | AGPL-3.0-only | Apache-2.0 |
| Chart | Maintained by the Grafana community since March 2026, `oci://ghcr.io/grafana-community/helm-charts/loki`. | The publisher's, `oci://ghcr.io/victoriametrics/helm-charts/victoria-logs-single`. |

Talos v1.14 keeps each service's log, the kernel's as the service `kernel`, in a ring of about 1 MiB
in memory, and offers two ways to get it off the node, both in its logging guide:

- **Files.** Talos writes each ring, from its oldest line, to `/var/log/<service>.log` once
  `/var/log` is mounted, flushing every 15 seconds, as root with mode 0640, and renames the file to
  `<service>.log.1` at 5 MiB, replacing the previous one. The lines are the services' own: the
  kernel's carry their time and priority, those of machined, apid and trustd the time Go's log
  package writes, etcd's are JSON, containerd's logfmt and the kubelet's klog, each with its time
  and level. The files are on the node's ephemeral partition and outlast a reboot.
- **Network.** `machine.logging.destinations` sends every service log, `kernel` included, as JSON
  lines over TCP or UDP, and a `KmsgLogConfig` document sends the kernel's messages again. Talos
  takes the time and level from a line that is JSON and gives every other line the time it is sent
  and the level info. A receiver must listen where every node reaches it; Talos resolves names with
  the node's resolvers, not the cluster's DNS.

## Decision

- **Store:** single-node VictoriaLogs from the publisher's chart, in `monitoring`, on a 20 GiB claim
  on the default storage class, keeping 14 days and at most 15 GiB. It is not exposed outside the
  cluster.
- **Collector:** Vector from its publisher's chart, `oci://ghcr.io/vectordotdev/helm-charts/vector`,
  one pod on every node, control planes included, sending to VictoriaLogs' Elasticsearch-compatible
  API, as VictoriaLogs' documentation sets Vector up.
- **What it reads:** every pod's log files, and the files Talos writes, `/var/log/<service>.log`
  and `<service>.log.1`, from a read-only mount of `/var/log`. It takes each line's own time and
  level where its format has them. Nothing changes in the machine configuration, and the collector
  listens only for Prometheus.

VictoriaLogs has fewer moving parts, keeps its data on a volume by design, and bounds its own disk
use; Loki on a volume is its smallest mode, with a chart built around object storage. The files
need no listener, no machine configuration and so no rollout to the nodes; only Talos writes them;
they keep 5 to 10 MiB of each service where the ring keeps about 1 MiB, across reboots; and each
line keeps its own time, where the network gives most of Talos's lines, which are not JSON, the
time they were sent.

## Alternatives considered

- **Loki, monolithic, on a volume.** Grafana reads it without a plugin, but the chart's caches,
  gateway and canary have to be turned off or sized down, a full volume is left to the operator,
  and a single replica is documented for testing, development or meta-monitoring.
- **Loki on object storage.** Its intended shape, but object storage is not wanted for logs.
- **Talos sending its logs to the collector over the network.** No files to read, but every node
  needs a machine configuration change and its rollout, and a listener that every node reaches:
  one on each node's own loopback address needs the collector on the node's network, where
  anything else on the node can write lines that are stored as Talos's. The kernel's messages
  arrive twice unless only one of the two settings is used, and lines that are not JSON carry the
  time they were sent, which after the collector was away is not when they were written.
- **vlagent.** VictoriaLogs' own collector reads pods' logs and, with its file collector, Talos's
  files, but takes the time and fields of JSON lines only: the kernel's, machined's, the kubelet's
  and containerd's lines would carry the time they were read.
- **The Vector subchart in the VictoriaLogs chart.** Its documentation does not describe it and
  points to vlagent instead; Vector's own chart keeps the collector's version and values with its
  publisher.

## Consequences

- Grafana needs the VictoriaLogs plugin to read logs, and queries are LogsQL. Grafana does not ship
  the plugin and the cluster's Grafana makes no other call to the internet, so the plugin is the one
  exception: the operator hands it to Grafana's container, which is set to install it at start with
  `grafana cli plugins install`, at an exact version, from grafana.com's plugin catalogue, and Grafana
  loads it only if its signature verifies. A download that fails stops Grafana from starting.
- Talos's lines reach the store within about 15 seconds of being written, as Talos flushes its
  files that often.
- One store replica: while it starts again on another worker, nothing is stored or queried, and each
  collector holds up to 256 MiB on its node's disk meanwhile, then stops reading until the store
  takes lines again. LINSTOR replicates the volume, so a lost worker loses no logs.
- The collector mounts all of `/var/log` read-only, as Talos renames the files it rotates, and
  reads only the pods' files and Talos's; it runs as root, which owns them, with no capability, in
  the monitoring namespace's privileged Pod Security level.
- A service that writes more than its rotation keeps while the collector is not reading, 5 MiB at
  least, loses the oldest of those lines; early boot is collected as far as the ring held it.
- Logs are kept 14 days and are not backed up.
