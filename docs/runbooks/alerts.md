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
