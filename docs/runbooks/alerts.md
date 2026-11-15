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
or Cilium's tunnel between the collector's node and the store's is down, which no recipe checks: the
collector's log shows connection errors to `victoria-logs` while the store's pod is Running.

## CertManagerCertificateNotReady

A Certificate has not been Ready for an hour: it was never issued, or a renewal failed and its
certificate is no longer valid. While an issued certificate is still valid, a failing renewal leaves
the Certificate Ready, so this alert means no current certificate or an issuance that never finished.
For the public Gateway's `public-wildcard` the Gateway keeps serving the Secret it has.

Look at first: `kubectl --namespace <namespace> describe certificate <name>`, then down the chain
cert-manager makes: `kubectl --namespace <namespace> get certificaterequest,order,challenge`. For a
DNS-01 challenge the Challenge's `status.reason` says what the provider or the CA refused
([cert-manager](../kubernetes.md#cert-manager)).

Usually: the DNS provider's token is missing, wrong or cannot edit the zone, so the Challenge is
refused (`kubectl --namespace cert-manager get externalsecret cloudflare-api-token` says whether the
token came through, and `just bao-put cert-manager/cloudflare api-token` writes it); the TXT record
is not yet visible at every one of the zone's own nameservers, which the self-check asks on port
53, or one of them cannot be reached from the controller; or the CA's rate limits are spent.

## CertManagerCertificateExpiringSoon

The certificate of a Certificate ends within 14 days, for 15 minutes: cert-manager renews well
before that (the public Gateway's at two fifths of the lifetime left), so a renewal has been failing
for a long time. A Certificate that has never been issued has no end and does not fire this alert;
[CertManagerCertificateNotReady](#certmanagercertificatenotready) covers it.

Look at first: the same objects as for [CertManagerCertificateNotReady](#certmanagercertificatenotready):
the Certificate's `Issuing` condition and the CertificateRequest, Order and Challenge of the renewal.
`just gateway-check` says how much of the public Gateway's certificate is left.

Usually: what makes a Certificate not Ready, for a longer time than the Certificate showed, as it
stays Ready while its current certificate is valid.

## EtcdSnapshotStale

The CronJob `etcd-snapshots` has had no successful run for 13 hours, two runs and an hour of grace,
or it has never succeeded and was created more than 13 hours ago. The newest etcd snapshot in the
bucket is then older than that, and a lost control plane is restored from it
([etcd-restore.md](etcd-restore.md)). The alert reads kube-state-metrics' record of the CronJob, so
it cannot fire for a CronJob that does not exist.

Look at first: `just cluster-snapshots` for the newest snapshot the bucket holds, and
`kubectl --namespace etcd-snapshots get cronjob,job,pod` for what the runs did. A failed run says
which step failed: `kubectl --namespace etcd-snapshots logs job/<job> --all-containers`
(`fetch-age`, `snapshot`, `encrypt` or `upload`). A pod stuck in `ContainerCreating` names its
missing Secret in `kubectl --namespace etcd-snapshots describe pod <pod>`.

Usually: the Secret `etcd-snapshots-s3` is missing, because the secret store lacks the key `volsync`
or the External Secrets operator cannot read it (`just bao-seed-volsync`); the S3 key was replaced
and the store's copy was not (`just bao-seed-volsync --rotate-s3`); the etcd bucket does not exist
(`just infra-backup-buckets`); the pod cannot download age, which needs the pod network to reach its
release host, or the archive no longer matches the checksum the manifest pins; or the Talos API
refuses the pod, which the `snapshot` step's log says. Once a run succeeds, take a snapshot by hand
to clear the alert at once: `kubectl --namespace etcd-snapshots create job
--from=cronjob/etcd-snapshots <name>`.  A cluster whose control planes lack
`talos/patches/controlplane/talos-api-access.yaml`, which `just cluster-talos` rolls out, never
raises this alert, as Flux builds none of the application there: the `ServiceAccount` kind of
`talos.dev` does not exist, so Flux's dry run fails and the Kustomization `etcd-snapshots` stays not
Ready (`flux get kustomization etcd-snapshots`), which nothing scrapes.

## EtcdSnapshotJobFailing

The latest scheduled run of the CronJob `etcd-snapshots` has not succeeded, half an hour after it
was scheduled, which is longer than the run's 20 minute deadline: it failed, or its pod never
started. The alert clears once a run succeeds. The previous snapshot is still in the bucket, so
nothing is lost yet; [EtcdSnapshotStale](#etcdsnapshotstale) fires when it is 13 hours old.

Look at first, and usually: as for [EtcdSnapshotStale](#etcdsnapshotstale). A snapshot that has
outgrown the memory-backed volume it is written to (1 GiB) fails the `snapshot` step with a write
error: the volume's `sizeLimit` and the step's memory limit in the CronJob then grow together.

## ExternalDNSSyncStale

external-dns has reported no successful sync with the DNS provider for 5 minutes past its due:
either its last successful sync is more than 10 minutes old, or there is no series of it at all. A
sync is due every minute and counts as successful whenever the pass ended without an error, whether
or not it changed a record. Records already in the zone keep serving; a new route gets none, and a
removed route keeps its records until the next successful sync
([DNS records](../kubernetes.md#dns-records)).

What fires it:

- **An old last sync**: external-dns runs, and its passes fail with errors it retries, the
  provider's 429 or 5xx or a connection cut mid-answer, for ten passes.
- **No series**: no external-dns runs to report one. A pass that fails with any other error ends
  the process: the provider refusing the token with a 4xx (revoked, expired, rewritten with another
  scope), a connection to the provider that cannot be made, or the Kubernetes API failing the
  source. The pod then crash-loops, its target goes, and its series with it. A pod that never
  starts, as when its Secret is missing, and a release that is not installed have none either.

Look at first: `kubectl --namespace external-dns get pods`, which shows a crash loop or a pod that
does not start, and the controller's log, `just logs 'kubernetes.pod_namespace:external-dns' --since
15m` or `kubectl --namespace external-dns logs deployment/external-dns --previous`, whose last line
names the provider's error. `kubectl --namespace external-dns get externalsecret` says whether the
token's Secret exists, and `kubectl --namespace external-dns get helmrelease external-dns` whether
the release is installed.

Usually: the API token was revoked, expired or rewritten with another scope, so the provider
answers 403 at the first pass ([the token](../kubernetes.md#dns-records) is written with
`just bao-put cert-manager/cloudflare api-token`); the Secret is missing because the key is not in
the store, in which case the pod does not start; or the provider's API is unreachable or
throttling, which clears by itself.
