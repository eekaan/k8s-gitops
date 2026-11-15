# Alerts

The alert rules of the applications under `kubernetes/apps/` ([kubernetes.md](../kubernetes.md#alerts)).
Each section below is the `runbook_url` of the alert of its name: what it means, what to look at
first, and what usually causes it. Alerts go nowhere yet, so nothing sends one: an operator sees
them in Prometheus' and Alertmanager's web interfaces, which `kubectl port-forward` reaches through
`just cluster-kubeconfig`'s kubeconfig. The read-only commands below run through that kubeconfig.
`just cluster-check` says whether the nodes, the control plane and the scrape targets are well;
`just logs '<LogsQL query>'` prints what the store holds.

## OpenBaoMemberSealed

A member of OpenBao, `openbao-0`, `openbao-1` or `openbao-2`, has not been Ready for 5 minutes. The
member's readiness probe is `bao status`, which fails while it is sealed, so Ready means unsealed
([openbao.md](openbao.md)). The other two members keep serving while it is down.

Look at first: `kubectl --namespace openbao get pods`, and the member's log,
`kubectl --namespace openbao logs <pod>`, which says why it could not unseal or rejoin.

Usually: the seal key's Secret `openbao-seal-1` is missing or changed, so the member cannot unseal
([bringing the seal key back](openbao.md#bringing-the-seal-key-back)); the member started with data
of another cluster ([a member that does not rejoin](openbao.md#a-member-that-does-not-rejoin)); or
its volume is not attached to the worker it was moved to yet, in which case the pod is Pending
and the alert clears by itself.

## OpenBaoNoActiveMember

Nothing answers for the Service `openbao-active`, which selects the member that holds the lead, so
no member leads: External Secrets cannot read a secret and nothing can write one. The alert reads
Prometheus' own `up` series for that Service's target, which is absent while no member holds the
lead; it does not fire while a lead exists whose metrics cannot be scraped.

Look at first: `kubectl --namespace openbao get pods --show-labels`: the member that leads carries
`openbao-active=true`. With none, check the members' state as for
[OpenBaoMemberSealed](#openbaomembersealed): two members unsealed elect a leader within seconds, so a
lasting absence means fewer than two members are unsealed, or the members cannot reach each other
on port 8201.

Usually: two or more members sealed or Pending at once, as after the storage cluster's volumes
were unavailable; a node drain that took out two members, which the disruption budget should prevent;
or a certificate the members' listener rejects, which `kubectl --namespace openbao get certificate`
shows.

## VolSyncSourceOutOfSync

A ReplicationSource's volume has been out of sync for 30 minutes: its last sync failed, or an
iteration did not finish before the next was due. Its newest backup is older than its schedule
allows ([volume-backups.md](volume-backups.md)).

Look at first: `kubectl --namespace <namespace> get replicationsource <name> --output yaml`: `status.latestMoverStatus`
holds the mover's result and the tail of its log, and `status.conditions` says whether it is
synchronizing. The mover's pod, `volsync-src-<name>`, is in the same namespace.

Usually: the restic repository is unreachable or its credentials are wrong: the cluster's S3 key
was replaced without seeding the store again, or the Secret from the store is missing
([replacing the cluster's S3 key](volume-backups.md#replacing-the-clusters-s3-key)); the snapshot of
the volume could not be taken; or the first backup of a large volume takes longer than the schedule's
interval.

## VolSyncSourceMissedIntervals

A ReplicationSource did not finish an iteration before the next was due, within the last hour. The
alert stays up for the hour after the miss, and it fires only for a source that has a schedule.

Look at first: the same fields as [VolSyncSourceOutOfSync](#volsyncsourceoutofsync), and the time
the last sync took, `status.lastSyncDuration`, against the schedule's interval.

Usually: a sync that takes longer than the interval, from a volume that grew or a repository that
answers slowly; or a node drain or reboot that stopped the mover's pod during its run, which
the next iteration makes good.

## LogCollectorOutsizedShare

One node's collector has sent at least ten times the median node's rate of events to the store, and
at least 10 events a second, for 30 minutes. The store ingests that node's records at a rate that
no other node's matches; a loop on the node, a pod that logs in a tight loop or a log that is read
again from its start are the shapes of it. The alert is `info`: it is a pointer, and the store's
volume is the thing it protects ([Logs](../kubernetes.md#logs)).

Look at first: which pod it is: its name is in the alert, and its node is in
`kubectl --namespace monitoring get pods --output wide`. Then which source of that node writes the
records, with `just logs 'node:<node> | stats by (_stream) count() as records | sort by (records desc) limit 5' --since 15m`,
whose first row names the stream, a container or a Talos service, that writes the most.

Usually: a pod with a log level of debug, or a crash loop that logs a trace each time; a Talos
service that repeats an error line, such as the kubelet or the kernel; or a collector that restarted
without its state directory and read every file from its start.

## LogCollectorDiscardingEvents

A component of a collector has been discarding events it was not configured to drop, for 15
minutes. The audit-record filter discards on purpose and counts its events as intentional; this
alert counts the others, which are lost.

Look at first: the component named in the alert and the collector's own log,
`kubectl --namespace monitoring logs <pod>`, which says why it drops: an event too large for the
sink, or one the store refuses with a status Vector does not retry.

Usually: a record the store rejects, such as a line dated beyond the store's accepted time range; a
change to the collector's configuration whose transform fails on lines it did not see before.

## LogCollectorSendFailing

A collector's sink to the store has reported errors for 15 minutes. The lines wait in the disk
buffer on the node, 256 MiB, and once it is full the collector stops reading on that node until the
store takes lines again, and the lines of files rotated away meanwhile are lost
([Logs](../kubernetes.md#logs)).

Look at first: whether the store is up: `kubectl --namespace monitoring get pods`, and
`just logs '*' --since 5m --limit 1`, which fails with the store's own message when it is away or
read-only. The collector's log, `kubectl --namespace monitoring logs <pod>`, names the error.

Usually: the store moved to another worker and is starting, which clears by itself; the store's
volume is full and it answers every insert with HTTP 429 (its metric `vl_storage_is_read_only` is 1);
or Cilium's tunnel between the collector's node and the store's is down, which `just cluster-check`
shows as a node that does not pass.
