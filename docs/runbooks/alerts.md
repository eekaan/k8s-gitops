# Alerts

The alert rules of the applications under `kubernetes/apps/` ([kubernetes.md](../kubernetes.md#alerts)).
Each section below is the `runbook_url` of the alert of its name: what it means, what to look at
first, and what usually causes it. A critical or warning alert is sent to the notification webhook
once both addresses are in the secret store, with this link in it
([Where alerts go](../kubernetes.md#where-alerts-go)); an `info` alert is sent nowhere. Every
alert shows in Prometheus' and Alertmanager's web interfaces, which `kubectl port-forward` reaches
through `just cluster-kubeconfig`'s kubeconfig. The read-only commands below run through that
kubeconfig.
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
Ready (`flux get kustomization etcd-snapshots`), which [FluxApplierNotReady](#fluxappliernotready)
reports instead.

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

## FluxRootSyncNotReady

One of the three objects of the root sync has not been Ready for 10 minutes: the Kustomization
`flux-system`, which applies the cluster directory; the Kustomization `cluster`, which applies every
application; or the OCIRepository `flux-system` they read ([Flux itself](../kubernetes.md#flux-itself)).
While it lasts nothing merged to `main` reaches the cluster, and the cluster drifts from the
repository without any other sign: what is applied stays as it was, healthy to look at.

Look at first: the alert's labels name the object. An object that fails at each retry and is
progressing in between counts as not Ready all along, so its condition may read either at the time
you look. `kubectl --namespace flux-system get ocirepository,kustomization` shows the three, and
`kubectl --namespace flux-system describe <kind> <name>` has the reason and the message. `just cluster-check` says whether
the pods of `flux-system` run.

Usually: the artifact of `main` cannot be fetched or its signature is refused, as after a publish
that did not finish or a change to the publish workflow's identity; the Secret `sops-age` or
`cluster-secrets` or the ConfigMap `cluster-config` is missing or wrong, so decryption or
substitution fails (`just cluster-config` applies them again); or a change that merged builds
differently on the cluster than in CI, such as a variable the cluster does not have. A change that
does not apply is reverted on `main` through a pull request.

## FluxApplierNotReady

A Kustomization or a HelmRelease other than the root sync has not been Ready for 15 minutes, and not
for waiting on a dependency: what it applies is not as the repository says, or the release is not
installed or upgraded. The alert names the object; one that fails at each retry and is progressing
in between, as a Kustomization whose health checks time out is, counts as not Ready all along.

Look at first: `kubectl --namespace <namespace> describe <kind> <name>`: its conditions and events
say why. For a HelmRelease, `kubectl --namespace <namespace> get helmrelease <name> --output yaml`
holds the failed action in its status, and helm-controller's log, `kubectl --namespace flux-system
logs deployment/helm-controller`, the Helm error. A Kustomization that waits for a failing
dependency is not named: the dependency is.

Usually: a health check that does not pass in the application's timeout, such as a pod that does not
start or a volume that is not bound; an object the API server refuses, from a definition that is not
installed yet or a webhook that does not answer; a chart whose upgrade or tests fail, which Flux
rolls back after its retries; or a value a manifest needs that `cluster-config` or `cluster-secrets`
lacks.

## FluxSourceNotReady

A source other than the root sync's OCIRepository has not been Ready for 15 minutes: an
OCIRepository, a HelmRepository, a HelmChart or the ArtifactGenerator. What reads it gets no new
revision and keeps what it has. The alert names the object; one that fails at each retry and is
progressing in between counts as not Ready all along.

Look at first: `kubectl --namespace <namespace> describe <kind> <name>`. For an OCIRepository the
message says whether the registry could not be reached, the tag is missing, or the artifact's
signature is refused; source-controller's log, `kubectl --namespace flux-system logs
deployment/source-controller`, has the detail, and source-watcher's,
`kubectl --namespace flux-system logs deployment/source-watcher`, for the ArtifactGenerator.

Usually: the registry of a chart is down or limits the cluster's pulls, which clears by itself; a
chart version that Renovate moved to is not published yet or was withdrawn; the keyless identity of
a chart's publisher no longer matches what the OCIRepository verifies; or, for the ArtifactGenerator,
a path of the artifact of `main` that is not there.

A refused signature and a source-controller that cannot reach what verification needs both read
`VerificationError` in the OCIRepository's `SourceVerified` and Ready conditions, and only the
message tells them apart, so read it first: `flux get sources oci --namespace <namespace>` or the
describe above. A message that the verifier could not be built (the trusted root, the Rekor or CT
log keys, Fulcio's certificates), that names a network error, a timeout or a registry's error, or
that no signatures were found is the cluster's reach: the block stays, the reach is fixed, and
source-controller retries and verifies the source by itself. `just cluster-signatures` names every
OCIRepository that is not verified as its row of `signatures.yaml` says. The table of who signs, in
[Signatures](../kubernetes.md#signatures), gives each source's identity, and the row's `from` in
`signatures.yaml` says where it was read. `just signatures-verify` tells apart a registry that is
out of reach, a pin whose signature no longer matches its row, which it fails, and a pin that
verifies, which it passes. Only a message that no signature matched (`no matching signatures` or
`no matching attestations`) with no network error in it, at a digest `just signatures-verify`
passes, takes the pull request of [Taking a block out](../kubernetes.md#taking-a-block-out). A pin
that no longer matches is a possible compromise: its block stays, and the new identity is read and
verified, or a digest that still verifies is pinned
([When a verification fails](../kubernetes.md#when-a-verification-fails)).

## FluxResourceSuspended

A Flux resource, or the FluxInstance, has been suspended for a day. Flux neither applies nor fetches
what a suspended resource names: a Kustomization that is suspended leaves its objects as they are, so
a merge to `main` does not reach them, and the alerts on a resource that is not Ready do not describe
what a suspended one has become. A suspended FluxInstance leaves Flux's controllers as they are, and
a change to the instance is not installed. The alert is `info`: a person suspends a resource on
purpose, to work on it, and nothing resumes it. A restart of the Flux Operator does not start the
day again, and the alert goes within 10 minutes of the resume.

Look at first: which resource it is, from the alert's labels, and who suspended it and why, which
nothing in the cluster records: ask, or look at the pull requests of the day. `kubectl --namespace
<namespace> get <kind> <name> --output yaml` shows `spec.suspend: true`, or, for the FluxInstance,
the annotation `fluxcd.controlplane.io/reconcile: disabled`.

Usually: a resource suspended while a change was tried by hand and never resumed. `kubectl
--namespace <namespace> patch <kind> <name> --type merge --patch '{"spec":{"suspend":false}}'`
resumes it, and the next reconcile applies what the repository says, whatever was changed by hand
meanwhile. `kubectl --namespace flux-system annotate fluxinstance flux
fluxcd.controlplane.io/reconcile-` resumes the FluxInstance.

## FluxInstanceNotReady

The FluxInstance, which the Flux Operator installs and updates Flux's controllers from, has not been
Ready for 10 minutes. The controllers that run keep running, but a change to the instance or a new
Flux version is not installed, and a controller that is missing is not made.

Look at first: `kubectl --namespace flux-system describe fluxinstance flux`: the message and the
events say which step failed, such as fetching the manifests or applying a controller. The operator's
log, `kubectl --namespace flux-system logs deployment/flux-operator`, has the detail, and `kubectl
--namespace flux-system get pods` shows whether the controllers run.

Usually: the registry of the operator's manifests or of a controller's image cannot be reached, which
clears by itself; a patch of the instance that no longer applies to the controllers of a new Flux
version; or an upgrade that stopped halfway, which the operator retries.

## FluxOperatorNotReady

The Flux Operator's Deployment has had no available replica for 5 minutes. The operator runs the
FluxInstance and exports the state of every Flux resource, so while it is down the FluxInstance is
not reconciled and the alerts on the state of Flux's resources see nothing. Flux's own controllers do
not depend on it and keep applying what the repository says.

Look at first: `kubectl --namespace flux-system get pods` and `kubectl --namespace flux-system
describe deployment flux-operator`; the pod's log, `kubectl --namespace flux-system logs
deployment/flux-operator`, says why it exits.

Usually: a node went away with the pod on it, which the Deployment replaces; an upgrade of the chart
does not start, which Flux rolls back after its retries; or the pod cannot be scheduled for lack of
room.

## CiliumBGPSessionsDown

A worker has had fewer BGP sessions established than it is configured for, for 5 minutes: it has one
session to each edge router, so one or both are down. The edge routers' traffic for the Service
addresses then spreads over fewer workers, and over none for an edge that has lost every worker. The
alert names the worker and how many sessions are down, never the peer, as the only label that tells
the peers apart is an address. A worker taken out of BGP on purpose, by the label the reboot and
upgrade recipes set, is configured for no session and does not raise it.

Look at first: `just edge-check`, which says over SSH whether both edge routers serve and every
worker has an established session there, so it tells an edge that is down from a worker that is;
`just cluster-check`, which fails on a Ready worker that is out of BGP; and the worker's own report,
`kubectl get ciliumbgpnodeconfig <node> --output yaml`, whose status lists each peer's session and
its state.

Usually: one edge router is down or being replaced ([edge.md](edge.md)); the worker's Cilium agent
restarted, which graceful restart rides out in less than the alert's time; or the sessions' port,
TCP 179, is dropped between the worker and an edge by a rule of the cloud's ports.

## CiliumBGPNoSessionEstablished

No BGP session is established from any worker, for 5 minutes, while a worker's Cilium agent answers;
the control planes' agents never hold a session and do not count. Either every session is down, or
no worker has a BGP instance at all, as when nothing selects a worker for BGP. Nothing is announced
to the edge routers, so no Service address, the public Gateway's included, is reachable from outside
the cluster.

Look at first: `just edge-check`, which says whether the edge routers serve and have a session from
any worker; `kubectl get ciliumbgpclusterconfig edge --output yaml` and `kubectl get
ciliumbgpnodeconfig`: with none of the second, no node matches the first's selector. A worker that
the reboot recipes took out of BGP carries `node-restriction.kubernetes.io/bgp-out`, which
`kubectl get nodes --show-labels` lists.

Usually: both edge routers are down at once, as during a rebuild of the edge stack
([edge.md](edge.md)); the `edge` stack is not applied, so there is nothing to peer with; the label
that takes a node out of BGP is on every worker, left by an interrupted reboot, which `kubectl label
node <node> node-restriction.kubernetes.io/bgp-out-` removes; or the BGP objects were deleted, which
Flux applies again from `cilium-bgp`.

## DrbdReplicaNotUpToDate

A replica of a volume has not been UpToDate for 15 minutes: its DRBD disk state is Outdated,
Inconsistent, Consistent, DUnknown or another that is not UpToDate, and it is not a diskless client,
which is no replica. The volume has one current copy fewer, and the failure of the node that holds
the other leaves it unavailable ([Storage](../kubernetes.md#storage)). The alert names the DRBD
resource, which is the volume's `pvc-<id>`, and the node.

Look at first: `kubectl --namespace piraeus-datastore exec deployment/linstor-controller -- linstor
resource list-volumes` for each replica's state, and `linstor node list` for the satellites'; a
resync of a large volume takes a while, and the alert waits 15 minutes for it. The series
`drbd_connection_state` in Prometheus says which connection of the resource is not Connected.

Usually: the node was down or unreachable and the replica is catching up, which clears by itself;
the connection between two nodes is lost, so the replica cannot sync, as when a satellite is offline
([LinstorSatelliteOffline](#linstorsatelliteoffline)) or Cilium's tunnel between them is down; or the
node's data volume returns I/O errors, which the node's kernel log shows (`talosctl dmesg`).

## DrbdResourceWithoutQuorum

A device of a volume has had no DRBD quorum for 5 minutes. With the StorageClass `linstor-replicated`
a device without quorum suspends its I/O: the pod that uses the volume neither reads nor writes it
until quorum returns or the HA controller evicts the pod to a node that has it. The alert names the
DRBD resource and the node.

Look at first: `kubectl --namespace piraeus-datastore exec deployment/linstor-controller -- linstor
resource list-volumes`: which replicas exist and in which state, and `kubectl get pods
--all-namespaces --output wide` for the pod that uses the volume and its node. `linstor node list`
says whether the satellites that hold the others are online.

Usually: the node cannot reach the others that hold the volume's replicas and tiebreaker, which is a
partition or two nodes down at once; the satellites of those nodes are offline
([LinstorSatelliteOffline](#linstorsatelliteoffline)); or a drain took out a node while another was
already down.

## LinstorSatelliteOffline

The LINSTOR controller has not seen a satellite online for 10 minutes: the node's replicas are not
kept in sync, no volume is placed on it, and a volume with a replica there has one current copy
fewer until it returns. The alert names the node, never its address.

Look at first: `kubectl --namespace piraeus-datastore get pods --output wide` for the satellite's pod
on the node, and `kubectl --namespace piraeus-datastore exec deployment/linstor-controller --
linstor node list`, whose state says OFFLINE, or a version mismatch or an authentication error.
`just cluster-check` says whether the node is Ready.

Usually: the node is down, rebooting or drained, which clears when it is back; the satellite's pod
crashes, which its log shows, `kubectl --namespace piraeus-datastore logs <pod>`; or the controller
cannot reach the satellite over the pod network, on TCP 3366 or 3367.

## LinstorStoragePoolFilling

A storage pool has been more than 85 percent full, and at most 95, for 15 minutes: the pool on one
worker's data volume, which holds that node's replicas and snapshots. A thin pool that fills
completely fails the writes of every volume on it, so this is the time to act. The alert names the
pool and the node.

Look at first: `kubectl --namespace piraeus-datastore exec deployment/linstor-controller -- linstor
storage-pool list` for each pool's free and total capacity, and `linstor resource list-volumes` for
what is allocated on the node. `kubectl get volumesnapshots --all-namespaces` lists the snapshots,
which keep the blocks a volume has since changed.

Usually: volumes that grew with their data, an application that writes more than it did, snapshots
that are kept long, or too many volumes placed on this node while others have room. Delete the
snapshots and volumes that are no longer needed, or grow the workers' data volumes, which is a change
of the cluster stack.

## LinstorStoragePoolFull

A storage pool has been more than 95 percent full for 5 minutes. A thin pool that runs out of space
fails every write of every volume on it, and its replicas fall out of sync with the others, so the
volumes it holds are at risk at once. The alert names the pool and the node.

Look at first: the same as [LinstorStoragePoolFilling](#linstorstoragepoolfilling), faster: `linstor
storage-pool list` for the pool's capacity, `linstor resource list-volumes` for the largest volumes,
and `kubectl get volumesnapshots --all-namespaces` for what can be deleted at once.

Usually: what filled it, left to run after the warning: free space first, by deleting snapshots or
volumes that are no longer needed, then find what grew.

## PostgresDumpStale

The CronJob `<cluster>-pgdump` of a PostgreSQL cluster has had no successful run for 36 hours, a
day's run missed and half a day of grace, or it has never succeeded and was created more than 36
hours ago. The newest dump of the database in the bucket is then older than that, and a restore
from a dump, the way back when the WAL archive cannot be read, loses everything written since
([postgres-restore.md](postgres-restore.md#restoring-a-daily-dump)). The data is still in the
cluster, on three instances, and in its WAL archive, so this is a missing copy and not an outage:
it is a warning for the working day. The alert reads kube-state-metrics' record of the CronJob, so it
cannot fire for a CronJob that does not exist, and is quiet for a database younger than 36 hours.
Its labels name the `namespace` and the `database`, which is the Cluster's name.

Look at first: `kubectl --namespace <namespace> get cronjob,job,pod` for what the runs did, and for
the newest dump in the bucket, the listing in [postgres-restore.md](postgres-restore.md#listing-the-dumps).
A failed run says which step failed: `kubectl --namespace <namespace> logs job/<job>
--all-containers` (`fetch-age`, `dump`, `encrypt` or `upload`). A pod in
`CreateContainerConfigError` (`Init:CreateContainerConfigError` while an init step is the one
affected) names its missing Secret in `kubectl --namespace <namespace> describe pod <pod>`: both of
the job's Secrets are read as environment variables.

Usually: the Secret `<cluster>-dump-s3` is missing, because the secret store lacks the key `volsync`
or the External Secrets operator cannot read it (`just bao-seed-volsync`); the S3 key was replaced
and the store's copy was not (`just bao-seed-volsync --rotate-s3`); the postgres bucket does not
exist (`just infra-backup-buckets`); the pod cannot download age, which needs the pod network to
reach its release host, or the archive no longer matches the checksum the manifest pins; the
database's own Secret `<cluster>-app` is missing, or no instance answers; or the dump outgrew its
volume ([PostgresDumpJobFailing](#postgresdumpjobfailing)). Once the cause is fixed, take a dump by
hand to clear the alert without waiting for the night: `kubectl --namespace <namespace> create job
--from=cronjob/<cluster>-pgdump <name>`. A job made by hand waits the database's stagger like a
scheduled one, up to 20 minutes, before it starts to dump.

## PostgresDumpJobFailing

The latest scheduled run of the CronJob `<cluster>-pgdump` has not succeeded, an hour after it was
scheduled, which is longer than the run's 45 minute deadline: it failed, or its pod never started.
The alert clears once a run succeeds. The previous dump is still in the bucket, so nothing is lost
yet; [PostgresDumpStale](#postgresdumpstale) fires when it is 36 hours old.

Look at first, and usually: as for [PostgresDumpStale](#postgresdumpstale). A dump that has
outgrown the memory-backed volume it is written to (512 MiB, compressed) fails the `dump` step with
`could not write to output file: No space left on device`: the volume's `sizeLimit` and the `dump`
container's memory limit in the CronJob then grow together, by a patch of the application's
`kustomization.yaml` that targets the CronJob by kind. A cluster of one instance has no replica to
read from; the step says so and dumps the primary. A long dump from a replica can be cancelled by
a conflict with the replica's recovery (`canceling statement due to conflict with recovery`). Each
retry waits the database's stagger again within the same 45 minute deadline, so a retry has less
time than the first attempt and a long dump can fail until the next night's run.

## OpenBaoSnapshotStale

The CronJob `openbao-snapshots` has had no successful run for 13 hours, two runs and an hour of
grace, or it has never succeeded and was created more than 13 hours ago. The newest snapshot of the
secret store in the bucket is then older than that, and what the store held after it is lost if its
volumes are ([the restore runbook](openbao.md#restoring-a-snapshot)). The alert reads
kube-state-metrics' record of the CronJob, so it cannot fire for a CronJob that does not exist.

Look at first: `kubectl --namespace openbao get cronjob,job,pod` for what the runs did. A failed run
says which step failed: `kubectl --namespace openbao logs job/<job> --all-containers` (`fetch-age`,
`snapshot`, `encrypt` or `upload`). A pod that does not start says why in
`kubectl --namespace openbao describe pod <pod>`: without the Secret `openbao-snapshots-s3`, the
`upload` container waits in `CreateContainerConfigError` once the steps before it have run; without
`openbao-tls`, the pod's volumes do not mount and no step starts, which its events name. The runbook
lists the bucket's snapshots ([listing](openbao.md#listing-and-checking-snapshots)).

Usually: the Secret `openbao-snapshots-s3` is missing, because the secret store lacks the key
`volsync` or the External Secrets operator cannot read it (`just bao-seed-volsync`); the S3 key was
replaced and the store's copy was not (`just bao-seed-volsync --rotate-s3`); the OpenBao bucket does
not exist (`just infra-backup-buckets`); the pod cannot download age, which needs the pod network to
reach its release host, or the archive no longer matches the checksum the manifest pins; or the
`snapshot` step cannot log in or is refused, which its log says: a login refused as a permission
error is the role `snapshot` or its account's binding changed, and a certificate error is the
listener's CA or its names, which `openbao-tls` renews. A `snapshot` step that ends because the store
has no active member is the store being down, which [OpenBaoNoActiveMember](#openbaonoactivemember)
reports. Once a run succeeds, take a snapshot by hand to clear the alert at once:
`kubectl --namespace openbao create job --from=cronjob/openbao-snapshots <name>`.

## OpenBaoSnapshotJobFailing

The latest scheduled run of the CronJob `openbao-snapshots` has not succeeded, half an hour after it
was scheduled, which is longer than the run's 20 minute deadline: it failed, or its pod never
started. The alert clears once a run succeeds. The previous snapshot is still in the bucket, so
nothing is lost yet; [OpenBaoSnapshotStale](#openbaosnapshotstale) fires when it is 13 hours old.

Look at first, and usually: as for [OpenBaoSnapshotStale](#openbaosnapshotstale). A snapshot that
has outgrown the memory-backed volume it is written to (256 MiB) fails the `snapshot` step with a
write error: the volume's `sizeLimit` and the step's memory limit in the CronJob then grow together.

## FalcoCriticalRuleMatched

Falco matched a rule of priority Critical, Alert or Emergency on a node within the last 15 minutes
([Runtime detection](../kubernetes.md#runtime-detection)): a process did something that rule calls
dangerous, such as running a binary that was dropped into a container, running one from memory, or
escaping a container through the cgroup's release agent. The alert names the rule and the node: the
rule's count differs from the last one Prometheus had for it 15 minutes earlier, which also holds for
a rule's first match in a new pod and for a match after Falco restarted in its pod. It clears 15
minutes after the last match, but after such a restart a count that climbs back to the old one can
clear it while Falco goes on matching and fire it again once the lower counts are 15 minutes old.
Falco only detects: nothing has been stopped. Its blind spot: after a restart of Falco's container
inside the same pod, a rule whose count comes back to exactly the count it had before the window,
such as once before the restart and once after, raises nothing for that match, so the logs below
are the record; and a series back unchanged more than a day after its last sample fires once with
nothing new behind it, from a day and 15 minutes after that sample, or from its return if that is
later, for at most 15 minutes.

Look at first: the event, which has the process, its arguments and the container, and the pod's
namespace and name in `output_fields`:
`just logs 'kubernetes.pod_namespace:security-system kubernetes.container_name:falco | unpack_json | filter priority:in("Critical", "Alert", "Emergency")' --since 1h`.
Then the pod it names: `kubectl --namespace <namespace> get pod <pod> --output wide` for its
image and node, and its own log.

Usually: either a workload doing what its rule treats as an attack, which is an incident, where the
pod and the node are the evidence and what to do next is a decision; or a workload that does this
on purpose, a debugging session or an image that unpacks a binary at start, which is an exception
to write down with its reason ([Tuning](../kubernetes.md#tuning)). Both are told apart by the
event's process and image, never by the rule alone. A quiet alert is only as good as Falco's scrape
target on each node: a target that does not answer raises the stock `TargetDown`, a warning, once
more than a tenth of the job's targets have been down for 10 minutes, which is one target on a
cluster of fewer than ten nodes and not one alone on a larger one, and a pod missing from a node
raises `KubeDaemonSetRolloutStuck` or `KubeDaemonSetNotScheduled`. No recipe checks the target:
`just cluster-check` covers the control plane, the kubelets and node-exporter, not `falco-metrics`.
Grafana's Explore, behind `just grafana`, shows it with the Prometheus query
`up{job="falco-metrics"}`: one series per node, each 1.

## KyvernoAdmissionControllerDown

Kyverno's admission controller, `kyverno-admission-controller`, has had no available replica for 10
minutes. It is the pod that evaluates each admitted object against the rules and writes its
admission report. Its webhooks that match workloads fail open and it only reports, so no workload is
refused and nothing else stops. What is missed is the reports of the objects admitted meanwhile,
which the reports controller's next background scan, within the hour, makes up for. Its webhooks on
its own kinds fail closed, so while no pod answers, a write of a Kyverno policy, PolicyException or
GlobalContextEntry is refused: Flux cannot apply or change a rule, and `kyverno-policies` retries
until a pod answers ([Admission policy](../kubernetes.md#admission-policy)).

Look at first: `kubectl --namespace kyverno get pods` and `kubectl --namespace kyverno describe
deployment kyverno-admission-controller`; the pod's log, `kubectl --namespace kyverno logs
deployment/kyverno-admission-controller`, says why it exits. `kubectl --namespace kyverno get
helmrelease kyverno` says whether the release is installed.

Usually: a node went away with the pods on it, which the Deployment replaces; an upgrade of the chart
does not start, which Flux rolls back after its retries; the pods cannot be scheduled for lack of
room; or a pod waits for its webhook certificate, which the controller makes itself on its first
start.

## GatekeeperControllerManagerDown

Gatekeeper's controller manager, `gatekeeper-controller-manager`, has had no available replica for 10
minutes. It is the pod set that answers the validating webhook. Gatekeeper fails open and only
reports, so nothing is refused and nothing else stops: what is missed is the evaluation of the
objects admitted meanwhile. The audit, a pod of its own, goes on, and finds them at its next pass,
within the minute ([Admission policy](../kubernetes.md#admission-policy)).

Look at first: `kubectl --namespace gatekeeper-system get pods` and `kubectl --namespace
gatekeeper-system describe deployment gatekeeper-controller-manager`; the pod's log, `kubectl
--namespace gatekeeper-system logs deployment/gatekeeper-controller-manager`, says why it exits.
`kubectl --namespace gatekeeper-system get helmrelease gatekeeper` says whether the release is
installed.

Usually: a node went away with the pods on it, which the Deployment replaces; an upgrade of the chart
does not start, which Flux rolls back after its retries; or the pods cannot be scheduled for lack of
room, as each asks for 512 MiB of memory.

## PostgresWALArchivingFailing

The primary of a PostgreSQL cluster has failed to archive a WAL segment to the object storage and
has archived none since, for 15 minutes. The primary keeps every segment it has not archived on its
volume, so the longer this lasts the larger the gap a restore cannot cross and the less room the
volume has: when it is full the database stops. Base backups are not affected, but a restore is only
as recent as the last segment that was archived.

Look at first: the cluster named in the alert, `kubectl --namespace <namespace> get cluster <name>`
and the primary's plugin sidecar, `kubectl --namespace <namespace> logs <name>-<n> --container
plugin-barman-cloud`, which says why a segment failed, and the Secret the ObjectStore reads,
`kubectl --namespace <namespace> get externalsecret <name>-backup`. The metric that raised the alert
is `cnpg_pg_stat_archiver_last_failed_time` against `cnpg_pg_stat_archiver_last_archived_time`.

Usually: the postgres bucket does not exist (`just infra-backup-buckets`); the cluster's S3 key was
replaced and the store's copy was not (`just bao-seed-volsync --rotate-s3`), or the ExternalSecret
has not synchronised, so the Secret is missing or old; the key `postgres-backups` of the secret
store is missing, as on a rebuilt cluster whose store has not been seeded from the custody file
(`just bao-seed-postgres <file>`, [postgres-restore.md](postgres-restore.md#the-customer-key)), so
the provider refuses every request for lack of the key it encrypted with, or holds another one; the
object storage is unreachable from the node; the Barman Cloud plugin's pods are down, which the
Kustomization `plugin-barman-cloud` shows (`flux get kustomization plugin-barman-cloud`); or the
operator cannot reach the plugin. Archiving resumes by itself once the cause is gone and the alert
clears with the next segment that is archived.

The operator cannot reach the plugin when `get cluster` shows the phase `Cluster cannot proceed to
reconciliation due to an error while interacting with plugins`; `kubectl --namespace <namespace>
get cluster <name> --output jsonpath='{.status.phaseReason}'` says why, after `Error while
discovering plugins:` when it cannot connect at all. `tls: certificate required` there means the
operator presented no certificate: its own, `tls.crt` of the Secret `barman-cloud-client-tls` in
`cnpg-system`, is not issued by the one authority the plugin names, which is that certificate's own
subject, so it is not self-signed ([PostgreSQL](../kubernetes.md#postgresql)). The Secret's
annotation `cert-manager.io/issuer-name` names the issuer that signed it, `barman-cloud-selfsigned`
when it is self-signed (`kubectl --namespace cnpg-system get secret barman-cloud-client-tls --output
jsonpath='{.metadata.annotations.cert-manager\.io/issuer-name}'`). The operator then makes,
changes and fails over no pod of the cluster, so a primary without the plugin's sidecar keeps
failing, its `postgres` container's log holding `wal archive plugin is not available:
barman-cloud.cloudnative-pg.io`. The sidecar, `plugin-barman-cloud`, is an init container that
keeps running beside `postgres`, so it is listed among the pod's init containers and not its
containers (`kubectl --namespace <namespace> get pod <name>-<n> --output
jsonpath='{.spec.initContainers[*].name}'`). Once the operator reaches the plugin it recreates the
replicas and then the primary, in place, with the sidecar, and the primary archives what has piled
up.

While the primary still runs, growing `CNPG_STORAGE_SIZE` in the application's `ks.yaml`, in a pull
request, can buy time while the cause is found ([PostgreSQL](../kubernetes.md#postgresql)). The new
size reaches the `Cluster` only once the application's Kustomization reconciles, which Flux does
only while every Kustomization it names in `dependsOn` is Ready, `plugin-barman-cloud` among them;
`flux get kustomization <application>` names the one it waits for. The operator then grows every
instance's volume to it only once its pass over the cluster reaches the volumes, which it does not
while, among others, it cannot reach the plugin, an instance's pod is not active (pending, finished
or being deleted, as one is while its worker is down), an instance is being made or a switchover or
failover is under way. `get cluster` shows the phase the cluster is in; one other than `Cluster in
healthy state`, such as `Waiting for the instances to become active`, is the sign to look for. When
the claims' capacity does not grow (`kubectl --namespace <namespace> get pvc --selector
cnpg.io/cluster=<name>`), grow the primary's claim by hand, as below for a primary whose volume
filled. `kubectl --namespace <namespace> exec <name>-<n>
--container postgres -- df -h /var/lib/postgresql/data/pgdata` shows the room left on the primary's
volume, the file system of its data directory, which holds `pg_wal`.

A primary whose volume filled meanwhile does not run: its `postgres` container restarts over and
over, last terminated with exit code 4, its log holding `no free disk space for WALs`, and once the
operator reconciles the cluster its phase is `Not enough disk space`. In that phase the operator
neither fails over, recreates a pod nor resizes a volume, so the sidecar cannot arrive and nothing
frees the volume. The way out the operator's documentation gives is to grow the volume: raise
`spec.resources.requests.storage` of the primary's PersistentVolumeClaim, `<name>-<n>`, by hand
(`linstor-node-local` allows expansion). Once the volume has room the `postgres` container starts by
itself and the operator goes on as above. Then set `CNPG_STORAGE_SIZE` in the application's
`ks.yaml` to the same size, in a pull request, so the `Cluster` asks for what its volumes have; the
operator grows the other instances' volumes to it once its pass reaches the volumes, as above, and
never shrinks one.

The plugin's two certificates are renewed every 75 days, each with a new key. The operator takes a
renewed Secret at once and the plugin's pods once the kubelet updates their Secret volumes, within
about a minute, so for that minute a cluster can show the phase `Cluster cannot proceed to
reconciliation due to an error while interacting with plugins` on its own. The operator checks the
plugin's server certificate before it sends its own, so the reason is `certificate signed by unknown
authority`, the operator refusing the server certificate, while the plugin serves another than the
one the operator trusts, and `tls: unknown certificate authority`, the plugin refusing the
operator's certificate, while only the client certificates differ. It clears by itself within
minutes and is not this alert's cause: archiving goes from the sidecar to the object storage, not
through the plugin's server.

## PostgresBackupTooOld

The newest base backup of a PostgreSQL cluster in the object storage is older than 36 hours, or the
cluster has none and its oldest instance is older than that, for 30 minutes. The ScheduledBackup
takes one a day, so at least one daily backup has failed or not run. The WAL archive may be intact:
a restore then starts from an older backup and replays more WAL, and only
[PostgresWALArchivingFailing](#postgreswalarchivingfailing) says the archive itself is broken.

Look at first: `kubectl --namespace <namespace> get scheduledbackup,backup` for the latest backups
and the phase and error of the failed ones (`kubectl --namespace <namespace> describe backup
<backup>`), and the plugin's sidecar in the pod that took it, as for
[PostgresWALArchivingFailing](#postgreswalarchivingfailing). The plugin's own metrics are
`barman_cloud_cloudnative_pg_io_last_available_backup_timestamp` and
`barman_cloud_cloudnative_pg_io_last_failed_backup_timestamp`.

Usually: the causes of [PostgresWALArchivingFailing](#postgreswalarchivingfailing), which stop
backups as they stop the archive; a backup that did not complete because a node or the primary
restarted while it ran (the next one is taken at 02:47 UTC); a ScheduledBackup that is suspended or
was deleted with its application; or a cluster whose first backup could not be taken, because the
object storage refused it, in which case the alert fires 36 hours after its pods were made. Take one
by hand to clear the alert at once, once the cause is gone: `kubectl --namespace <namespace> create
-f` a `Backup` of method `plugin` for the cluster, as
[postgres-restore.md](postgres-restore.md#taking-a-base-backup-by-hand) shows.

## CrowdSecLocalAPIDown

CrowdSec's local API has not answered its scrape for 10 minutes, or no target of it exists. The
local API stores the alerts the agent sends and lists the decisions, so while it is down no decision
can be listed and the agent's alerts are lost. Nothing is blocked by it either way: nothing enforces
a decision ([CrowdSec](../kubernetes.md#crowdsec)). The alert clears once the local API answers.

What fires it:

- **A target that fails its scrape**: the pod runs and does not serve, as while its database claim
  is being attached or the process is stuck.
- **No target**: the pod is gone or never started, as when its claims cannot be made, its image
  cannot be pulled or its Secret `crowdsec-lapi-secrets` is missing, or the release is not
  installed.

Look at first: `kubectl --namespace crowdsec get pods,pvc`, which shows a pod that does not start
or a claim that is not bound, and the pod's log, `kubectl --namespace crowdsec logs
deployment/crowdsec-lapi` (add `--previous` for a crash loop). `kubectl --namespace crowdsec get
externalsecret` says whether the Secret exists, and `kubectl --namespace flux-system get
kustomization crowdsec` and `kubectl --namespace crowdsec get helmrelease crowdsec` whether the
release is installed.

Usually: the claims' storage is not ready, which `just cluster-check` and the storage alerts show
([Storage](../kubernetes.md#storage)), or the Secret `crowdsec-lapi-secrets` is missing, in which
case the ExternalSecret that made it makes it again with new values, and the local API and the agent
are restarted together so that both read them. The agent registers with the local API at every
start, so after the local API's database was lost, restart the agent too; the decisions the
database held are lost with it, and only requests the proxies log after the agent starts decide
again.

The agent's own failure to start does not fire this alert. It registers under its pod's name, and
the local API refuses a name it already holds, so a pod of the agent that runs its init container a
second time, as when the pod's sandbox is made again, stays in `Init:CrashLoopBackOff`, and
`kubectl --namespace crowdsec logs deployment/crowdsec-agent --container wait-for-lapi-and-register`
ends with `user already exist`. Delete the pod, `kubectl --namespace crowdsec delete pod <pod
name>`, and its Deployment makes one under a new name, which registers; or delete the old machine,
`kubectl --namespace crowdsec exec deployment/crowdsec-lapi -- cscli machines delete <pod name>`,
and the same pod registers at its next try.

## RestoreDrillStale

The check of an application's restore drill, the CronJob `<app>-drill-check`, has not passed for
36 hours, a night's check missed and half a day of grace, or it has never passed and was created
more than 36 hours ago ([The restore drill](../kubernetes.md#the-restore-drill)). The backups may
still be good: what is unproved, for that long, is that the newest one restores, with recent data.
It is a warning for the working day. The alert reads kube-state-metrics' record of the CronJob, so it
is quiet for an application younger than 36 hours. Its labels name the `namespace` and the
`application`.

Look at first:

- the check's one line, which names the case: `kubectl --namespace <namespace> get cronjob,job,pod`
  for what the checks did, then `kubectl --namespace <namespace> logs job/<job>`. A pod that never
  started says why in `kubectl --namespace <namespace> describe pod <pod>`, a `Multi-Attach` event
  when the scratch claim was still attached to another node;
- the drill's ReplicationDestination:
  `kubectl --namespace <namespace> get replicationdestination <app>-drill --output yaml`, whose
  `status.lastSyncTime` and `status.lastSyncDuration` say when the last restore ended and how long
  it took, and `status.latestMoverStatus` its result and the tail of the mover's log, which says
  `No eligible snapshots found` when the repository holds no backup;
- the backup's ReplicationSource, `kubectl --namespace <namespace> get replicationsource <app>
  --output yaml`, the same fields, and the backup alerts,
  [VolSyncSourceOutOfSync](#volsyncsourceoutofsync) and
  [VolSyncSourceMissedIntervals](#volsyncsourcemissedintervals).

Usually:

- no backup newer than the bound: the backups failed two nights running, which the backup alerts
  report, and the check's line gives the heartbeat's age;
- the repository Secret `<app>-volsync` is missing, because the secret store lacks the key `volsync`
  or the External Secrets operator cannot read it (`just bao-seed-volsync`): no mover runs, and the
  scratch claim keeps the files of the last restore or none;
- the canary's pod is not writing: it does not run, or its heartbeat is old on its own volume, so
  every backup holds an old one (`kubectl --namespace <namespace> get pod`);
- a restore still running when the check started, on another node, so the claim could not attach:
  the check's pod waited for the volume until its deadline, and the restore's `lastSyncDuration`
  shows how long it ran;
- a changed `APP` or bucket prefix, so the repository's path holds nothing: the restore finds no
  snapshot, and the claim keeps the previous files, which fail on their age, or holds none, which the
  check reports as the restore having brought nothing back.

Once the cause is fixed, a restore that was waiting for it runs soon after, as VolSync keeps retrying
one whose repository Secret is missing or whose mover failed; otherwise the next restore runs at the
schedule's time. To restore sooner, delete the drill's ReplicationDestination and have Flux make it
again, as a new one restores at once; the scratch claim is not VolSync's and keeps its files
meanwhile: `kubectl --namespace <namespace> delete replicationdestination <app>-drill`, then
`flux reconcile kustomization <app>`. A manual trigger set with kubectl does not stay: Flux takes
over the fields kubectl writes on an object it applies and removes the trigger at its next
reconcile. Once a restore has run, run a check by hand, which clears the alert when it passes:
`kubectl --namespace <namespace> create job --from=cronjob/<app>-drill-check <name>`.

## RestoreDrillJobFailing

The latest scheduled run of the CronJob `<app>-drill-check` has not passed, half an hour after it
was scheduled, which is longer than the 600 seconds its job may take to be made and the 600 it may
then run: the check failed, or its pod never started. The alert clears once a check passes. The
backups are as they were; [RestoreDrillStale](#restoredrillstale) fires when no check has passed for
36 hours. A check's job that failed, scheduled or by hand, also raises the stock `KubeJobFailed`, a
warning, 15 minutes after it failed, and that one does not clear when a check passes: it fires for
as long as the failed job exists, and the CronJob keeps its three newest failed jobs for their logs.
Once the job's log is read, delete the job, which clears it:
`kubectl --namespace <namespace> delete job <job>`.

Look at first, and usually: as for [RestoreDrillStale](#restoredrillstale), the check's one line
first: it says whether the restore brought nothing back, the claim holds no heartbeat, the heartbeat
is not a number of seconds or lies in the future, or it is older than the bound, with its age. On the
first night after an application takes the drill, a check fails once when the restore before it
found a backup without a heartbeat, as every backup taken before the application wrote one is: when
the canary comes with the drill, as `volsync-demo`'s does, the first check fails if both are applied
from a few minutes before the backup's time, as the backup can be taken before the replaced pod has
written its first heartbeat, until the check's. It fails too when no restore has used the scratch
claim yet, as when the repository Secret came only after the check's time: the claim is made empty
for the check, which reports that the restore brought nothing back. The next night's passes; delete
the failed job as above. Run a check by hand as above.

## PublicEndpointDown

The probe of a public hostname has had no answer for 5 minutes. The blackbox exporter asks the
Gateway's proxies for the hostname from inside the cluster, and no response came back: the
connection was refused or timed out, or the TLS handshake failed, which a certificate for another
name does, or one that the trust of the cluster's issuer does not verify: the cluster's authority
for `cluster-ca`, the system's roots for `letsencrypt-production`; under `letsencrypt-staging` the
probe verifies no certificate ([Probes](../kubernetes.md#probes)). The alert names the hostname; the
apex of the domain is the redirect's probe, over plain HTTP.

Look at first: `just gateway-check`, which reads the Gateway, its Service, the proxies and the
certificate and says which fails; then `kubectl --namespace envoy-gateway-system get pods,svc` for
the proxies and their Service. To see the probe's own reason, ask the exporter for it, the same
request Prometheus makes, from a port-forward to its Service:
`kubectl --namespace monitoring port-forward svc/blackbox-exporter 9115` and, in another terminal,
`curl 'http://127.0.0.1:9115/probe?module=public_https&hostname=<hostname>&target=https://<Service>/&debug=true'`
with the module, the Service's name and the path from the Probe (`public_https_signin` for a route
behind sign-in), which prints the exporter's log of that probe.

Usually: both proxies are gone or not Ready, which `kubectl --namespace envoy-gateway-system get
pods` shows; the Gateway's certificate is not issued or is for another name
(`kubectl --namespace envoy-gateway-system get certificate`); the exporter's trust does not match
the issuer, so the handshake fails verification: the Gateway serves a certificate of another issuer
than the overlay's `PROBE_ISSUER` names, as while a new issuer's certificate is not Ready yet and
the proxies still serve the old one, or, with the cluster's own CA, after the authority was replaced
and the exporter's Secret `blackbox-exporter-trust` was not renewed yet
(`kubectl --namespace monitoring get certificate blackbox-exporter-trust`). A probe that fails
while `just gateway-check` passes through the edges points at the exporter or the cluster's
network, not at the Gateway: the pods of `kubectl --namespace monitoring get pods` and Cilium, and
`just network-drops`, which lists the exporter's flows to the proxies on 10443 or 10080 when the
proxies' policy does not take them ([Probes](../kubernetes.md#probes)). Every hostname at once,
with a name the exporter cannot resolve in its log of the probe, means the proxies' Service is not
named as the Probes' targets name it, as after an update of Envoy Gateway that names it otherwise:
`kubectl --namespace envoy-gateway-system get svc` shows the name the controller gave it.

## PublicEndpointWrongStatus

The Gateway answers the probe of a public hostname, but with a status the probe does not accept,
for 5 minutes: a 200 is what a route's probe wants, a 302, the redirect to sign-in, what the probe
of a route behind sign-in wants, and a 301 the redirect's. The Gateway and the certificate are fine,
since the handshake succeeded and verified, and the route or its backend is not: Envoy answers 503
for a route whose backend has no ready endpoint, 403 for a route behind sign-in while oauth2-proxy
cannot answer, and 404 for a hostname it holds no route for ([Probes](../kubernetes.md#probes)).

Look at first: the status the probe got: the exporter's `probe_http_status_code` for that hostname
in Prometheus' web interface, or the debug request in [PublicEndpointDown](#publicendpointdown).
Then the route: `kubectl get httproute --all-namespaces` shows the routes of the Gateway and
`kubectl --namespace <namespace> describe httproute <name>` its conditions, `Accepted` and
`ResolvedRefs`.

Usually: a 503 means the backend Service has no ready pods
(`kubectl --namespace <namespace> get endpointslices`), as for an application whose pods wait for a
secret the owner writes to the store, until it is there: n8n for its encryption key, and dex and
after it oauth2-proxy for the sign-in's
([What the owner does, in order](../kubernetes.md#what-the-owner-does-in-order)); a 404 means the
route is not accepted, as its namespace lost the label `k8s-gitops/gateway: public`, or the hostname
changed under the route. For a route behind sign-in, a 403 means oauth2-proxy did not answer
(`kubectl --namespace sso-system get pods`), and a 200 means the backend answers without a session:
the route's `SecurityPolicy` is gone or not accepted
(`kubectl --namespace <namespace> describe securitypolicy <route>`), which leaves the page open to
anyone until it is back. For the redirect, any status but 301 means another route took the http
listener, which `just gateway-check` reports.

## PublicCertificateExpiring

The certificate the Gateway serves for a public hostname expires within 14 days and the probe still
sees it: cert-manager renews it with two fifths of its lifetime left. The probe reads the earliest
end among the certificates the proxies send (`probe_ssl_earliest_cert_expiry`), which are the
listener's certificate and the intermediates of its chain, so it is the listener's certificate while
its intermediates outlive it, and an intermediate that ends sooner raises the alert although the
certificate is renewed ([Probes](../kubernetes.md#probes)). A renewal that fails also raises
[CertManagerCertificateExpiringSoon](#certmanagercertificateexpiringsoon) for `public-wildcard`,
which reads the certificate cert-manager stored; this alert alone means the proxies serve an older
certificate than the one stored, cert-manager is not scraped, or it is an intermediate that ends.

Look at first: `kubectl --namespace envoy-gateway-system get certificate public-wildcard` and
`kubectl --namespace envoy-gateway-system describe certificate public-wildcard`: its `Ready`
condition, its `Not After` and `Renewal Time`, and the events of the issuance;
`kubectl --namespace cert-manager logs deployment/cert-manager` says why cert-manager does not
issue. A stored `Not After` later than the alert's days has one of two causes: the proxies serve an
older certificate than the one stored, or the certificate that ends is an intermediate of the chain,
not the listener's. The certificate served tells them apart. The debug request in
[PublicEndpointDown](#publicendpointdown) prints the probe's series, among them
`probe_ssl_last_chain_info`, whose `serialnumber` and `issuer` are those of the listener's
certificate as the proxies serve it; the stored one's are printed by
`kubectl --namespace envoy-gateway-system get secret public-wildcard-tls --output jsonpath='{.data.tls\.crt}' | base64 --decode | openssl x509 -noout -serial -issuer -enddate`,
which reads the first certificate of the Secret's chain, the listener's, and prints no key. Another
serial number (the two write the same hex digits in different case) means the proxies hold an older
certificate. The same one means an intermediate ends first: the issuer gives its chain with each
certificate, and the next issuance, which cert-manager starts once two fifths of the listener's
lifetime are left, can be weeks away. To issue sooner, mark the `Certificate` for issuance with
cert-manager's command-line tool, which is not one of this repository's pinned tools:
`cmctl renew --namespace envoy-gateway-system public-wildcard`. An issuance from Let's Encrypt
counts against its rate limits ([The ACME issuers](../kubernetes.md#the-acme-issuers)).

Usually: the issuer cannot sign, as the cluster's authority's Secret is gone, an ACME order fails
([Choosing the public Gateway's issuer](../kubernetes.md#choosing-the-public-gateways-issuer)) or
the `ClusterIssuer` is not Ready (`kubectl get clusterissuer`); or cert-manager is not running. A
renewed certificate reaches the proxies within seconds, and the alert clears after the next probe.
The proxies serve the certificate the controller last sent them, so one older than the stored
certificate means the controller has not sent the new one: it is not running, or the proxies cannot
reach it on 18000 (`kubectl --namespace envoy-gateway-system get pods` and the controller's log).

## PublicCertificateExpiryImminent

The same as [PublicCertificateExpiring](#publiccertificateexpiring), within 3 days: the certificate
was not renewed in the 11 days since the warning, and the hostname's clients will refuse it soon.
Treat it as an outage in progress.

Look at first, and usually: as for [PublicCertificateExpiring](#publiccertificateexpiring). The
renewal is cert-manager's and follows by itself once the issuer signs again; nothing in this
repository renews a certificate by hand.

## ProbeNotRunning

A declared probe of a public hostname has not been scraped through the exporter for 10 minutes:
Prometheus' `up` of its target in the job `public-endpoints` is 0, so the probe writes nothing and
the other alerts on that hostname say nothing. The exporter is gone, the `Probe` names another
prober or a module the exporter does not have, or the probe takes longer than the scrape allows. A
cluster that declares no `Probe` never raises it ([Probes](../kubernetes.md#probes)).

Look at first: `kubectl --namespace monitoring get pods,svc` for the exporter's two pods and its
Service `blackbox-exporter`, and `kubectl get probes --all-namespaces` for the Probes, which are in
the namespaces of their routes. In Prometheus' web interface, Status, Targets shows each Probe's
scrape and its error: a refused connection when the Service has no ready pod, an HTTP 400 for a
module the exporter does not have.
`kubectl --namespace monitoring get helmrelease blackbox-exporter` says whether the release, which
reads the values of the cluster's `PROBE_ISSUER`, failed.

Usually: both exporter pods are Pending or not Ready, as after a drain of the workers they ran on;
the exporter's Kustomization is not applied, which
`kubectl --namespace flux-system get kustomization blackbox-exporter` shows; or a Probe was given a
prober or a module by hand that the tree does not have. A release that failed three times is Stalled
until its failure count is reset, which helm-controller does when the release's chart or values
change, and `flux reconcile helmrelease blackbox-exporter -n monitoring --reset` does by hand.
Until the exporter's Kustomization is Ready again, Flux applies no change to the Gateway or to an
application with a route, which wait for it, from each one's next reconcile
([Probes](../kubernetes.md#probes)).
