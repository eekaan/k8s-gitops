# Rebuilding the cluster from nothing

The cluster can be taken down to nothing and built again from the repository, the operator's keys
and custody files, the copies in the backup buckets and the cloud credentials. This runbook goes from
a running cluster to nothing and back. Each recipe checks what it needs before it runs anything, and
a failing one ends with a line naming the step it failed in ([cluster.md](../cluster.md#recipes)).

## What survives a rebuild

- The state bucket and each stack's state in it: a destroy empties a stack's state and leaves the
  object in the bucket ([infrastructure.md](../infrastructure.md#recipes)).
- The backup buckets and what they hold: no stack owns them
  ([infrastructure.md](../infrastructure.md#s3-keys-and-backup-buckets)). Among it the etcd and
  OpenBao snapshots, the volume backups' repositories, and each database's archive, its base backups
  and WAL, and its daily dumps, in the postgres bucket under the database's path.
- The cluster's secrets bundle, `talos/<cluster>/secrets.sops.yaml`, which is committed, and the
  Talos and Flux age keys, which the operator holds. The rebuilt cluster is made from the same
  bundle, so it has the same certificate authorities and keys: the credentials in a kubeconfig or
  talosconfig made for the old cluster are valid for the new one, and a copy kept anywhere works
  again once it is pointed at the new addresses.
- The OpenBao custody file, which `just bao-recovery` wrote and the operator holds, or after a
  rotation of the seal key the newest one, which `just bao-seal-keep` wrote, and the older ones the
  operator keeps beside it: the old store's recovery keys and its seal keys, the current one and
  after a rotation the previous one, which a snapshot of the old store opens with and no other
  ([openbao.md](openbao.md#restoring-a-snapshot)).
- The volume backups' master, in the custody file `just bao-seed-volsync` wrote, which the operator
  holds: it opens the repositories in the VolSync bucket, and the rebuilt cluster's store is seeded
  from it ([Building it again](#building-it-again)).
- The PostgreSQL backups' customer key, in the custody file `just bao-seed-postgres` wrote, which the
  operator holds: every base backup and WAL file in the postgres bucket is encrypted with it, and
  the rebuilt cluster's store is seeded from it ([Building it again](#building-it-again)).
- Talos images that [image-replacement.md](image-replacement.md) left in the image service: no stack
  holds them, so no destroy removes them. They are removed by hand as that runbook says; once the
  nodes are destroyed, no volume made from them is left.

## What does not

- Addresses: the nodes' and the API load balancer's floating addresses go back to the cloud with
  the cluster stack, and the rebuilt cluster gets new ones. The generated files that held the old
  ones, the cluster's `talman.yaml`, talosconfig and kubeconfig, are removed with the stack and
  written again by the build. The edge routers' floating addresses go back with the edge stack, when
  step 5 of [Taking it down](#taking-it-down) destroys it, and edges built again get new ones.
- The DNS records of the routes' names, the A records at the edges' addresses and their TXT entries:
  step 3 of [Taking it down](#taking-it-down) takes them out of the zone before the edges' addresses
  go, and the rebuilt cluster's external-dns makes them again, at the addresses its `cluster-config`
  holds ([Building it again](#building-it-again), step 2).
- The contents of LINSTOR's volumes: they are on the workers' data volumes, which go with the
  cluster stack ([cluster.md](../cluster.md#the-workers-data-device)).
- The databases' contents, as each instance's volume is LINSTOR's: the rebuilt cluster makes each
  database's Cluster again under its old name, and CloudNativePG makes a Cluster without a
  `bootstrap` section with initdb, empty. The database comes back from its archive or a dump in the
  postgres bucket ([Building it again](#building-it-again)).
- OpenBao's store and every key in it, as its data is on LINSTOR's volumes: the rebuilt cluster's
  OpenBao initialises anew, with new seal keys, and the recovery keys in the old store's custody
  file open nothing in it, unless the old store's newest snapshot is restored into it with the old
  seal keys in place before its first member starts
  ([openbao.md](openbao.md#restoring-a-snapshot)).
- Everything in etcd: every object of the Kubernetes API, the Secrets made in the cluster among
  them. Flux applies again what Git holds. A snapshot restores into the same nodes only
  ([etcd-restore.md](etcd-restore.md#when-to-restore)), so
  [restoring etcd from a snapshot](etcd-restore.md#restoring-etcd-from-a-snapshot) is not one of the
  rebuild's restores. A Secret that an operator generated in the cluster and that no backup holds is
  lost with it, as Ascender's `ascender-secret-key` is ([Building it again](#building-it-again),
  step 8).

## Taking it down

1. **`just cluster-last-copies <openbao file> <volsync file> <postgres file>`**, while the cluster
   still runs and while its applications are idle, as what they write after a copy is not in it. The
   files are the three custody files: `just bao-recovery`'s (after a rotation of the seal key, the
   newest one `just bao-seal-keep` wrote), `just bao-seed-volsync`'s and `just bao-seed-postgres`'s.
   Once the cluster is gone, they and the Talos and Flux age keys are the only copies of what they
   hold, and nothing compares them any more, so the recipe first compares each with what the cluster
   holds, reading only: each seal key the stanza names with the Secret of its id, `openbao-seal-1`
   today, the volume backups' master with every backed-up application's derived password, the customer key
   with every database's backup Secret, and each age key with the recipient its `.sops.yaml` names. A
   file or key that does not hold what the cluster holds stops it, named, before any copy is taken;
   with `--check` it stops after the comparison and the plan, having changed nothing. Run it with
   `--check` first, and check that the plan names every database of the table in step 7 of
   [Building it again](#building-it-again): the recipe takes the databases the running cluster lists,
   so one whose Cluster is missing there gets no last copy. Then it takes
   and checks a last copy of everything the rebuild restores from: an OpenBao snapshot, a dump of each
   database and its WAL archived through a segment it switches then, and a backup of each volume, each
   newer than the run ([cluster.md](../cluster.md#recipes)). Keep the summary it prints last, one
   line per copy, with the custody files: the snapshot's name, each database's dump and the segment
   and time its WAL is archived through, and each volume's backup time, which are what the rebuild
   restores and what its checks compare with. A run that fails names what failed and why, and
   takes no later copy: put that right and run it again. The destroy in step 4 checks for no
   last copy, so it waits until a run has printed its summary.

2. **`just cluster-snapshot`**, when the cluster's state matters: an etcd snapshot, encrypted, in
   the etcd bucket, which the rebuild leaves alone. It is of no use to the rebuild, as a snapshot
   restores into the same nodes only ([etcd-restore.md](etcd-restore.md#when-to-restore)).

3. **`just cluster-dns-remove`**, while the cluster still runs, with `--check` first:
   `just cluster-dns-remove --check` lists, by type and by name under the domain, every A record and
   TXT entry of the cluster's owner that a run of external-dns with no source would delete, from a
   dry-run Job in `external-dns`, which it deletes again, and changes nothing else. Then
   `just cluster-dns-remove`, once the cluster's name is typed back, suspends Flux's Kustomization
   and HelmRelease `external-dns`, stops external-dns, deletes those records and entries with the
   same Job, and plans again to check that none is left. Which records go is external-dns's own
   owner rule, so records of another owner and those made by hand stay
   ([cluster.md](../cluster.md#recipes)). external-dns stays stopped until the destroy:
   `ExternalDNSSyncStale` fires and is expected until then
   ([alerts.md](alerts.md#externaldnssyncstale)), and `FluxResourceSuspended`, which is `info`,
   after a day. The recipe prints how to start external-dns again, for a teardown that stops here.
   A second run finds nothing to delete and asks nothing.

4. **`just cluster-destroy`**. It asks the cluster, through its kubeconfig, for every Service of
   type LoadBalancer and every PersistentVolume of a CSI driver. A cloud load balancer or volume
   behind one is the cluster's own and not in the cluster stack's state: its destroy would leave it
   in the cloud, where it keeps the network from being deleted. A Service whose addresses all come
   from the service range has none behind it and does not count. LINSTOR's volumes do not count
   either: their data is on the workers' data volumes, which go with the stack, and the recipe says
   how many of them the destroy takes before it asks. While there are any others, the recipe names
   each and destroys nothing; remove them first. A cluster whose API does not answer, or that has no
   kubeconfig, may still own some and is not destroyed either.
   `just cluster-destroy --unreachable` destroys it anyway; whatever it owned stays in the cloud
   until it is removed by hand.

   Then it plans the cluster stack's destroy, prints the summary and destroys once `sto2/cluster` is
   typed back, and removes the cluster's `talman.yaml`, talosconfig and kubeconfig. The plumbing
   stack, the secrets bundle and the buckets stay.

5. **`just infra-destroy sto2/plumbing`**, when the network and the Talos image should go too. The
   CI host, the `sto2/ci` stack, and the edge routers, the `sto2/edge` stack, are on the plumbing
   stack's network, and the network cannot be removed while their ports and floating IPs exist. So
   first, in the state of every other stack, the recipe looks for a resource, and while it finds one
   it plans and destroys nothing, naming the stack and the recipe that destroys it:
   `just infra-destroy sto2/ci` for the CI host, which also takes the runner away until
   [ci-host.md](ci-host.md) sets a new host up, and `just infra-destroy sto2/edge` for the edge
   routers ([edge.md](edge.md#the-way-back)). The edge stack's destroy refuses, planning nothing,
   while a name the routes publish still resolves at the public resolver to one of its addresses,
   or cannot be looked up, naming each by its label under the domain; step 3 is what takes those
   records out. `just infra-destroy sto2/edge --check` says whether it would refuse, and plans and
   destroys nothing. Then the plumbing stack's destroy is planned, its summary printed, and it
   destroys once `sto2/plumbing` is typed back. Images left from earlier Talos versions are removed
   by hand ([image-replacement.md](image-replacement.md#removing-old-images)).

## Building it again

The rebuilt cluster brings every database back empty under its old name, with its dump job and its
base backups aimed at the old paths, and Flux, once installed, applies each application as soon as
its dependencies are Ready. So two things are settled first, in step 1, and the restores follow in
the order each needs the one before: the secret store, which holds the volumes' and the archives'
keys, then the volumes, then the databases.

1. **The hold.** A pull request that sets `CNPG_BACKUPS_SUSPENDED: "true"` in the
   `postBuild.substitute` of the `ks.yaml` of each application whose database is restored (step 7),
   merged and published before `just cluster-flux`. Flux applies the artifact that the publish run
   of the merge tags `main` ([kubernetes.md](../kubernetes.md#publishing)), not the merge itself,
   and the hold has to be in it from Flux's first apply of the application
   ([kubernetes.md](../kubernetes.md#postgresql)), so wait for that run to end. Held, the
   database's dump CronJob makes no dump and its ScheduledBackup no base backup. Without it, the dump
   job of the empty database uploads a dump of it to the old path every night from the night the
   store holds the key `volsync`, and its retention deletes one real dump for each, so none is left
   after 14 nights; and a base backup of the empty database that completed in the old path would be
   the newest of its catalogue, the one a recovery without a target starts from, and the start of a
   recovery window that, 30 days on, expires the old backups. The WAL archive needs no hold:
   CloudNativePG marks a database that initdb made, and the Barman Cloud plugin then checks the path
   before its first archive and refuses one that holds WAL, for as long as the mark stays, so the
   empty database archives nothing there.

   The same refusal keeps a database that is made again by a start, and not restored, from archiving
   at all, as Backstage's is (step 7). So delete its old archive now, before `just cluster-flux`:
   the objects under `base/` and `wals/` of its path in the postgres bucket, with the cluster's S3
   key, as step 6 of [the point-in-time restore](postgres-restore.md#restoring-one-database-to-a-point-in-time)
   deletes an old archive. The rebuilt database then archives into an empty path from its first
   segment.

   Decide too whether OpenBao's store comes back from its snapshot (step 5), rather than starting
   anew with every key written again. The old seal keys then have to be in the cluster before
   OpenBao's first member starts, soon after `just cluster-flux`, so step 2 puts them in place.

2. **The build.** The build order in [cluster.md](../cluster.md#from-nothing-to-a-ready-cluster),
   from the start, up to and with `just cluster-flux`, leaving out the steps that make the age keys
   and the secrets bundle: they survived, and `just cluster-secrets` refuses to replace a bundle. The
   edge stack is applied before `just cluster-bootstrap` whether it was destroyed or not, with its
   environment: the bootstrap reads the edge routers' public addresses from its outputs into
   `cluster-config`, and an apply of a stack that stands changes nothing. Edge routers built again
   have new public addresses, which the records external-dns makes follow once `cluster-config`
   holds them ([kubernetes.md](../kubernetes.md#dns-records)).

   When the store comes back from its snapshot, put the old seal keys in place right after
   `just cluster-flux`, before OpenBao's first member starts, as step 2 of
   [Restoring a snapshot](openbao.md#restoring-a-snapshot) says for a rebuilt cluster: once Flux has
   made the namespace `openbao`, and while `flux get kustomization openbao` shows it waiting for its
   dependencies, `flux suspend kustomization openbao`, then `just bao-seal-restore <openbao file>`,
   then `flux resume kustomization openbao`. After a rotation of the seal key, `<openbao file>` is
   the custody file `just bao-seal-keep` wrote, and the run writes the previous key's Secret too,
   which a snapshot taken before the rotation needs ([Rotating](openbao.md#rotating)). The rest of
   that restore waits for step 5.

3. **`just cluster-check`**: every check passes. Before the namespace `flux-system` exists, the
   check of its pods is skipped, and the recipe says so.

4. **`just cluster-reboot <node>`** for a control plane, by its hostname in `talman.yaml`: the check
   that the Kubernetes API stays available through its load balancer. The recipe drains the node,
   reboots it and waits until it is Ready again, asking `/readyz` through the kubeconfig once a
   second all the while; then it prints how many probes failed and the longest run of failures,
   uncordons the node and deletes the pods the shutdown left Failed on it
   ([cluster.md](../cluster.md#recipes)). It fails when any probe failed; `--tolerate <seconds>`
   accepts a gap up to that long, when the operator judges one acceptable. Run `just cluster-check`
   again afterwards: every check passes.

5. **The secret store.** First, while the store holds no key `volsync`, so that no volume is
   restored or backed up yet, read the newest snapshot of each application's repository:
   `just bao-volsync-password <volsync file> <app> restic snapshots` for each volume the summary of
   `cluster-last-copies` lists, `<app>` its name after the namespace. It reads the VolSync bucket, not
   the cluster. Note the snapshot's ID and time for step 6. The newest is the last copy's, taken
   shortly before the time the summary gave for its backup, which is when that backup ended, or a
   later one where a scheduled backup ran between the last copies and the destroy; restic shows
   times in the machine's own time zone.

   Then either the old store's snapshot, restored as [openbao.md](openbao.md#restoring-a-snapshot)
   says, with the seal keys step 2 put in place and the snapshot the summary of
   `cluster-last-copies` named; it brings back every key the store held, and the recovery keys of the
   old custody file then open the restored store, as
   [Restoring access with the recovery keys](openbao.md#restoring-access-with-the-recovery-keys)
   uses them. Or, once Flux has applied OpenBao, the operator's steps of its
   [first initialisation](openbao.md#first-initialisation): `just bao-recovery <file>` with a new
   file, and every key the store held written again. For the volume backups that is
   `just bao-seed-volsync <file>` with the existing custody file of their master, never a new one:
   until it runs, every application's restore waits, its claim Pending, and a new master would open
   none of the repositories
   ([volume-backups.md](volume-backups.md#the-stores-key-is-lost-and-the-file-is-kept)). The same
   goes for the PostgreSQL backups' customer key, `just bao-seed-postgres <file>` with the existing
   custody file: until it runs, no database archives, and a new key would make every archive
   unreadable ([postgres-restore.md](postgres-restore.md#the-customer-key)).

6. **The volumes.** Each comes back by itself once the store holds the key `volsync`
   ([volume-backups.md](volume-backups.md#the-stores-key-is-lost-and-the-file-is-kept)): the
   component makes each claim with its ReplicationDestination, which restores the newest snapshot
   of the repository once, the one step 5 noted, as
   [Restoring a claim from its repository](volume-backups.md#restoring-a-claim-from-its-repository)
   says of a claim made with it; nothing is done by hand for it. The rebuilt ReplicationSource then
   backs the claim up as soon as it is bound, whatever its schedule, as VolSync starts the first sync
   of a new ReplicationSource at once. From then on the repository's newest snapshot is the rebuilt
   cluster's, of the restored claim, and on a rebuild the same day as the last copies the retention,
   which keeps the newest backup of each day, forgets the last copy's snapshot. So the restore is
   checked by its ReplicationDestination, not by the repository's listing. For each application:
   its ExternalSecret `SecretSynced`;
   `kubectl --namespace <namespace> get replicationdestination <app>-restore --output jsonpath='{.status.lastSyncTime} {.status.latestMoverStatus.result}{"\n"}{.status.latestMoverStatus.logs}'`
   printing a time after the store got the key, `Successful`, and the tail of the mover's log, which
   names the snapshot it restored, the one step 5 noted; its `status.latestImage` set; and the claim
   `Bound`. A claim that passes holds that snapshot and is not restored again. A result of `Failed`
   says why in the same log, and VolSync starts the restore's mover again.

7. **The databases.** Each database of the cluster, by its namespace and name, its application and
   how it comes back:

   | Database | Application | How it comes back |
   | --- | --- | --- |
   | `ai-system/n8n-db` | n8n | Held, and restored by [the point-in-time restore](postgres-restore.md#restoring-one-database-to-a-point-in-time) into a new cluster beside the rebuilt, empty one, then switched over; from [a dump](postgres-restore.md#restoring-a-daily-dump) only when the archive cannot be read |
   | `ascender/ascender-db` | Ascender | Held, and restored as n8n's is, by [the point-in-time restore](postgres-restore.md#restoring-one-database-to-a-point-in-time) or, when the archive cannot be read, [a dump](postgres-restore.md#restoring-a-daily-dump), with the differences [kubernetes.md](../kubernetes.md#ascender) gives under "Restoring the database" |
   | `backstage/backstage-db` | Backstage | Not held and not restored: made again by a start, as its database holds only what Backstage derives from the tree ([kubernetes.md](../kubernetes.md#backstage)), once its old archive is deleted (step 1) |
   | `reportportal/reportportal-db` | ReportPortal | Held, and restored as n8n's is, by [the point-in-time restore](postgres-restore.md#restoring-one-database-to-a-point-in-time) or, when the archive cannot be read, [a dump](postgres-restore.md#restoring-a-daily-dump), the release pointed at the new cluster by `database.secretName` and `database.endpoint` of its values; its files come back in step 6 from the same night, as the database and the volume belong together ([kubernetes.md](../kubernetes.md#reportportal)) |

   Here the point-in-time restore is run without a target, its manifest without `recoveryTarget`,
   so the recovery replays the old archive to its end. The held, empty database archives nothing to
   that path, so the end is the old cluster's last WAL: at or after the segment the summary of
   `cluster-last-copies` named, which holds every transaction committed before the time beside it,
   or, when the cluster was lost without last copies, whatever the old cluster archived last. For
   each segment it replays, the summary's among them, PostgreSQL logs
   `restored log file "<segment>" from archive`; CloudNativePG writes that line into the recovery
   job's log as the message of a JSON record, its quotes escaped, so search the log for the
   segment's name. A target at the summary's time would fail the recovery whenever no
   transaction committed after it, as in the archive of a database that stayed idle once the copy was
   taken: CloudNativePG ends a recovery that finds no transaction after its target time with an error
   ([its recovery documentation](https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.1/docs/src/recovery.md#recovery-targets)).
   The old cluster's Backup objects went with etcd, so the restore's first step reads the archive
   instead: the plugin's sidecar on the empty cluster's primary reads the old catalogue at its path
   every 30 minutes, and its ObjectStore reports the old archive's first recoverability point and
   last successful backup
   (`kubectl --namespace <namespace> get objectstore <name> --output jsonpath='{.status.serverRecoveryWindow}'`).
   A dump is the way back when the archive cannot be read, as when the customer key is lost; the
   summary names the newest dump, and a dump holds only the day it was taken.

   The hold is released in the switchover pull request, step 5 of the point-in-time restore, by
   taking `CNPG_BACKUPS_SUSPENDED` out of the `ks.yaml` with the change to `CNPG_CLUSTER_NAME`, and
   never before it: a ScheduledBackup released while the empty cluster is still the component's takes
   its immediate backup, of the empty database, into the old path. After the switchover the
   restored cluster's own dump job and base backups run, under its own name. While a database is held,
   these fire and are expected: `PostgresWALArchivingFailing` for the empty cluster, whose archiving
   the plugin refuses; `PostgresDumpStale`, 36 hours after the dump CronJob was made, as it never
   succeeds; and `PostgresBackupTooOld`, once the newest base backup of the old archive, which the
   plugin reports for the empty cluster's server name, is 36 hours old
   ([alerts.md](alerts.md#postgresdumpstale)). A hold left in place therefore does not go unseen.
   The empty primary keeps the WAL it cannot archive, a 16 MiB segment every five minutes while
   anything writes, which fills its volume in no less than the 16 hours the component's floor sizes
   it for ([kubernetes.md](../kubernetes.md#postgresql)); PostgreSQL then stops, which touches
   nothing of the old archive, and the empty cluster goes with the switchover. Until then n8n and
   Ascender run against their empty databases, and what is written to them goes with the empty
   clusters: keep both unused until their switchover.

8. **What no restore brings back.** Everything in etcd ([What does not](#what-does-not)): among it
   Ascender's `ascender-secret-key`, which its operator generates and no backup holds, so the
   restored rows keep every credential Ascender stored encrypted under the old key, which nothing
   opens any more, and the owner enters each again ([kubernetes.md](../kubernetes.md#ascender)).
   n8n's encryption key comes back with the store's snapshot or, when the store starts anew, is read
   from the volume's backup into the store before n8n starts, as
   [kubernetes.md](../kubernetes.md#n8n) says.
