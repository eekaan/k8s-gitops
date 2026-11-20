# PostgreSQL backups and restores

Every PostgreSQL cluster made from `components/cnpg-cluster` is backed up to the postgres bucket of
the object storage in two ways ([kubernetes.md](../kubernetes.md#postgresql)):

- its WAL is archived and a base backup is taken daily through the Barman Cloud plugin, each object
  encrypted at the provider with one customer key, which `just bao-seed-postgres` keeps in a custody
  file outside the cluster ([ADR 0008](../adr/0008-state-and-backups-are-encrypted-before-they-leave.md));
- its application database is dumped once a day by the CronJob `<cluster>-pgdump`, and the dump is
  encrypted with age to the Talos age key's recipient before it leaves the pod.

Restore from the archive to bring a database back to a moment, any of the last 30 days, and from a
dump when the archive cannot be read, as when the customer key is lost, since a dump needs only the
Talos age key and `pg_restore` but holds only the day it was taken. This runbook covers the key,
checking the first archive and backup, taking a backup by hand, moving to a new PostgreSQL major,
restoring one database to a point in time into a new cluster beside the old one and switching the
application over, restoring a dump, and losing the key. Nothing here has been run against a cluster
that lost a database: the first time it is used is the first time it is tested, so each step says
what to check before the next.

Either restore adds its new cluster as one file named for it beside the component's `Cluster`, in
the application's own `app/`, and makes it the component's once the application runs on it. In a
namespace that denies traffic by default, as `backstage`, `ascender` and `kguardian` do, the
database's allows, its own and its application's, select its pods by the label `cnpg.io/cluster`
existing, not by its value ([kubernetes.md](../kubernetes.md#what-the-namespaces-let-through)):
the operator gives every pod it makes for a cluster, its instances and the jobs that create, join
and recover them, that label with the pod's own cluster's name, so a new cluster's pods reach and
are reached by what the old cluster's do from their start, and the pull request that adds the new
cluster adds no allow.
The recovery job of a restore from the archive carries `cnpg.io/jobRole: full-recovery` and holds
the plugin's sidecar, which reads the archive from the object storage; a standing policy of the
namespace lets such a pod reach it on 443, as the instances do. The cost is that every cluster of
the namespace shares the database's flows, which holds because every one of them is the
application's, as Flux makes them from the reviewed tree.

## What is backed up

- The archive of a cluster is `s3://<BACKUP_BUCKET_PREFIX>-postgres/<CLUSTER_NAME>/<namespace>/<server name>`,
  under which the plugin keeps `base/` for base backups and `wals/` for WAL segments. The server
  name is `<name>`, the cluster's `CNPG_CLUSTER_NAME`, while it runs PostgreSQL 18, and
  `<name>-pg<major>` after a [move to a later major](#moving-to-a-new-postgresql-major). Two
  databases never share a path.
- The dumps are the files directly in `.../<namespace>/<name>`, `<UTC time>.dump.age`, the newest 14
  of them, beside the archive's `base/` and `wals/` while the server name is `<name>`; the dump job
  deletes only files of that form directly there, and the plugin only in `base/` and `wals/`
  ([Restoring a daily dump](#restoring-a-daily-dump)).
- A base backup is taken at 02:47 UTC every day, and one when a cluster's ScheduledBackup is made.
  WAL is archived as each 16 MiB segment fills or `archive_timeout` forces it.
- Base backups and WAL are kept for a recovery window of 30 days: the database can be restored to any
  moment of the last 30 days that WAL covers. The plugin deletes what falls outside the window after
  each base backup, under the current server name only, with the cluster's S3 key, which may delete
  in every bucket of the project, so a workload that holds it can delete the archive too.
- What the archive holds is encrypted at the provider with the customer key. The S3 key alone can
  list and delete the objects but not read them. Their names, sizes and times are visible to the
  provider.

## The customer key

The key is 32 random bytes, base64 encoded, which the plugin sends with every request as the key of
SSE-C, server-side encryption with a customer-provided key: the provider encrypts and decrypts with
it and does not store it, and an object cannot be read without it. One key serves every database of
the cluster, so the recipe stays one small file; the archives stay apart by their paths.

- `just bao-seed-postgres <file>` makes the key once, writes it to `<file>`, a new file outside the
  repository, encrypted with age to the Talos age key's recipient, opens the file again with the Talos
  age key to check it holds what was written, and only then creates the key `postgres-backups` in the
  secret store, which each database's ExternalSecret reads. It refuses a store that already holds
  the key, and prints nothing of it. The file is read only where no one but the operator can have
  written it, as [openbao.md](openbao.md#first-initialisation) says. Keep it with the other custody
  files, the Talos age key and the state passphrase, and nowhere in the repository or the cluster.
- A rebuilt cluster's store is new and holds no key, so a database cannot archive until the store is
  seeded again: `just bao-seed-postgres <file>` with the existing custody file, never a new one,
  writes the key the file holds. A new key would leave every earlier backup unreadable.
- Losing the key, the file and the store's entry both, loses every base backup and WAL segment of
  every database, as the provider cannot read them for anyone. The cluster's own data is not affected,
  and a new key starts new archives: until the first base backup under it exists, a database has
  nothing to restore from but its own volumes.
- The key cannot be rotated in place: objects written under one key are unreadable under another. A
  new key needs a new destination path or server name, so a rotation is a new archive beside the old
  one, which stays readable with the old key until it is deleted.

## Checking the first archive and base backup

After the store holds the key and a database is applied, each of these only reads:

- `kubectl --namespace <namespace> get externalsecret <name>-backup`: `SecretSynced` once the store
  holds both the key `volsync` and the key `postgres-backups`; until then the Secret does not exist.
  The instances start, and the sidecar's archiving fails, so `PostgresWALArchivingFailing` fires.
- `kubectl --namespace <namespace> get objectstore <name>` and `get cluster <name>`: the cluster
  reports `Cluster in healthy state` with three instances, each pod with the sidecar
  `plugin-barman-cloud` beside `postgres`.
- `kubectl --namespace <namespace> get scheduledbackup,backup`: the first Backup, made when the
  ScheduledBackup was, reaches phase `completed`; a failed one says why in
  `kubectl --namespace <namespace> describe backup <backup>`.
- `kubectl --namespace <namespace> exec <name>-1 --container postgres -- psql --command 'select archived_count, failed_count, last_archived_time from pg_stat_archiver'`,
  run in the primary's pod: `archived_count` grows and `failed_count` stays where it was. A WAL
  segment is archived when a segment fills, so `select pg_switch_wal()` there forces one.

## Taking a base backup by hand

A backup outside the schedule, such as before a risky change or once a cause of a failed backup is
gone, is a Backup the operator takes the way the schedule does:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: <name>-by-hand
spec:
  method: plugin
  cluster:
    name: <name>
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

`kubectl --namespace <namespace> create --filename <file>`, then watch it as above. The Backup is
not in the tree, so Flux leaves it; delete it when it has completed.

## Moving to a new PostgreSQL major

A new major is the operator's offline upgrade in place of every database the component makes, all
at once, as the component's one image is every database's (CloudNativePG v1.30.1,
`docs/src/postgres_upgrades.md`, Offline In-Place Major Upgrades). When a `Cluster`'s `imageName`
names a higher major, the operator stops all its instances, records the old major in
`.status.pgDataImageInfo` and runs `pg_upgrade --link` on the primary's volume in a job named for the
primary with `-major-upgrade` after it; the database is down until the job has succeeded and the
primary has started again, and the operator then deletes the replicas' volumes and clones them anew
from the primary. It upgrades only between images of one operating system distribution, so the
tag's `-trixie` stays: Renovate proposes only tags of the suffix the tree runs, `-standard-trixie`
(`isCompatible` in `lib/modules/versioning/docker/index.ts` of Renovate 44.227.4).

`pg_upgrade` makes a new database system, with a new system identifier and timeline 1 again, and the
base backups and WAL from before it cannot recover a moment after it. The plugin writes to the
server name the `Cluster` names and does not keep the two systems apart by itself, so the server
name moves with the image, as the operator's documentation asks (Backup and WAL Archive
Considerations), and the new system's archive starts beside the old one, never in it.

1. **Take a base backup of every database first,** as
   [Taking a base backup by hand](#taking-a-base-backup-by-hand) does, each under a name of its
   own, such as `<name>-before-pg<major>`, and wait until each is `completed`
   (`kubectl --namespace <namespace> get backup`). The operator's documentation advises a full
   backup before an upgrade in place.
2. **Merge the image and the server name in one pull request.** Renovate opens it for the newest
   major alone, labelled `postgresql-major`, and never merges it itself; it moves both of the
   component's images, `imageName` in `components/cnpg-cluster/cluster.yaml` and the dump
   container's in `cronjob.yaml`. The same pull request sets `serverName` in `cluster.yaml` to
   `${CNPG_CLUSTER_NAME}-pg<major>`, `${CNPG_CLUSTER_NAME}-pg19` for PostgreSQL 19:
   `tests/postgresql.bats` fails it until it does, and while the dump image is of another major.
   Merge it once its checks pass, at a time when every database may be down. While the job runs,
   `kubectl --namespace <namespace> get cluster <name>` shows the phase
   `Upgrading Postgres major version`, then `Cluster in healthy state`;
   `kubectl --namespace <namespace> get cluster <name> --output jsonpath='{.status.pgDataImageInfo.majorVersion}'`
   gives the new major once the job has succeeded.
3. **Take a base backup of every database straight after,** as in step 1, under another name, such
   as `<name>-pg<major>`: the new server name's archive holds none until then, so the database
   cannot be restored from it, and the schedule's next one can be a day away. The operator's
   documentation asks for one as soon as possible.

What stays under the old server name, its `base/` and `wals/`, which after the move from PostgreSQL
18 are `<name>/base` and `<name>/wals` beside the dumps, is readable with the customer key and is
the only way back to a moment before the move. Its last minutes are not in it: the old primary
switches to a new segment as it shuts down for the upgrade, so that all its WAL is archived
(`ShutdownXLOG` in PostgreSQL's `src/backend/access/transam/xlog.c`), and the instance archives each
segment under the server name of the `Cluster` as it last read it
(`internal/cmd/manager/walarchive/cmd.go` of the operator), which is the new one once Flux has
applied the merge. The segments the old system closed from then until it stopped are in
`<name>-pg<major>/wals/`, archived before the upgrade job started; a restore to a moment among them
copies them, with the customer key, to the same paths under `<name>/wals/` first. The old archive is
restored as step 2 of
[Restoring one database to a point in time](#restoring-one-database-to-a-point-in-time) restores,
with the new cluster's `imageName` an image of the old major and the old server name as `serverName`
under `externalClusters`. The plugin applies the recovery window, and reads the catalog of base
backups, only under the current server name (`maintenance` in `internal/cnpgi/instance/retention.go`
of the plugin's release): it never prunes the old archive, and once it has read the new name's
catalog it deletes the `Backup` objects of the cluster's base backups that are not in it, those
taken before the move among them, but not the backups. Delete the old archive by hand once the new
one holds the 30 days of the recovery window: only `<name>/base/` and `<name>/wals/`, never all of
`<name>/` as step 6 of that restore deletes its directory, as the files directly in `<name>/` are the
running database's dumps.

**Going back.** Before the upgrade has succeeded, a pull request that puts the old images and the old
server name back makes the operator delete the failed or running job and start the old major again
(`handleRollbackIfNeeded` in `pkg/reconciler/majorupgrade/reconciler.go`): the job writes the
upgraded data into new directories and replaces the old ones only once it has succeeded (the
operator's documentation, Upgrade Process). The segments the old system closed as it stopped for the
attempt are in `<name>-pg<major>/wals/`, as above, and not in `<name>/wals/`, so a recovery from a
base backup taken before the attempt cannot replay past them: take a base backup of every database,
as in step 1, as soon as the old major runs again. Once the upgrade has succeeded, the operator's
webhook refuses a lower major, `can't downgrade from major` (`validateImageChange` in
`internal/webhook/v1/cluster_webhook.go`), and the way back is a restore of the old archive, as above.

A Renovate pull request for a major that is closed without a merge does not come back
(`separateMajorMinor` in Renovate's configuration options): the move is then a pull request made by
hand that changes both images and the server name, after which Renovate proposes the new major's
minor updates.

## Restoring one database to a point in time

This makes a new cluster from the archive of the old one, beside it, and switches the application
over once the new one is checked. The old cluster keeps running, and its archive is only read, so
a wrong target time costs another try and nothing else. The examples are n8n's database, `n8n-db` in
`ai-system`, restored as `n8n-db-restored`.

1. **Choose the moment.** The last moment before the damage, in UTC, within the window: a Backup
   older than it must exist (`kubectl --namespace ai-system get backup`). Without a target the
   recovery replays to the end of the archive.
2. **Add the new cluster to the application's `app/`,** as a file named for it,
   `n8n-db-restored.yaml`, listed in its `kustomization.yaml`, in a pull request, as Flux owns the
   namespace's objects. The name is new: it differs from the old cluster's, and from that of any
   earlier attempt, as the recovery job refuses to start a cluster whose own path already holds an
   archive (`checkBackupDestination` in `internal/cnpgi/restore/restore.go` of the plugin's
   release). The manifest reads the old cluster's archive, through the old cluster's ObjectStore and
   server name, and archives its own under its own server name, which is its name. The old
   cluster's server name, `serverName` under `externalClusters`, is the one its Cluster's archiver
   entry gives: its name while it runs PostgreSQL 18, and `<name>-pg<major>` after a
   [move to a later major](#moving-to-a-new-postgresql-major). Two clusters must
   never write to one path: Barman refuses to archive into a path that holds the WAL of another
   database system, and a path they did share would interleave two timelines, so the old archive
   would stop being restorable.

   ```yaml
   ---
   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   metadata:
     name: n8n-db-restored
   spec:
     instances: 3
     imageName: <the imageName of components/cnpg-cluster/cluster.yaml>
     storage:
       storageClass: linstor-node-local
       size: 5Gi
     affinity:
       enablePodAntiAffinity: true
       topologyKey: kubernetes.io/hostname
       podAntiAffinityType: required
     resources:
       requests:
         cpu: 500m
         memory: 512Mi
       limits:
         cpu: 500m
         memory: 512Mi
     bootstrap:
       recovery:
         source: old
         database: app
         owner: app
         recoveryTarget:
           targetTime: "2026-11-15 09:30:00+00"
     externalClusters:
       - name: old
         plugin:
           name: barman-cloud.cloudnative-pg.io
           parameters:
             barmanObjectName: n8n-db
             serverName: n8n-db
     plugins:
       - name: barman-cloud.cloudnative-pg.io
         isWALArchiver: true
         parameters:
           barmanObjectName: n8n-db
           serverName: n8n-db-restored
   ```

   The image and sizes are the component's, so they are the old cluster's unless a patch changed
   them; copy those too. The new cluster's instances take the workers beside the old cluster's, one
   of each per worker, so check the workers have room for six: each instance requests the CPU and
   the memory it is limited to, and its volume, of the cluster's size, is a volume of its own
   worker's node-local pool ([kubernetes.md](../kubernetes.md#storageclasses)). The image is a pin
   that no Renovate manager reads in this file, as no `# renovate:` comment is above it, so the pull
   request lists it in `.renovate/by-hand.tsv`, or `just renovate-pins` fails it; run this in the
   checkout, with the file's path:

   ```sh
   printf '%s\t%s\t%s\t%s\n' kubernetes/apps/base/ai-system/n8n/app/n8n-db-restored.yaml \
     ghcr.io/cloudnative-pg/postgresql \
     "the image of a restore's Cluster, copied from components/cnpg-cluster/cluster.yaml without its renovate comment, so that no update moves it while the cluster is restored" \
     "not moved: the restore's last step deletes the file and this row (docs/runbooks/postgres-restore.md)" \
     >>.renovate/by-hand.tsv
   ```

   The pull request adds no allow: in a namespace that denies traffic by default, the new
   cluster's pods have the flows the old cluster's have from their start, and its recovery job
   reaches the object storage (above).

   For Ascender the pull request also adds the Secret that the new cluster's owner and the `AWX`
   read, a copy of the `Password` and the `ExternalSecret` of `ascender-db-app`
   ([Ascender](../kubernetes.md#ascender), Restoring the database): this file, with `<name>` the
   new cluster's name in each of its five places, as `<name>-app.yaml` beside
   `ascender-operator/app/database-secret.yaml`, listed in that directory's `kustomization.yaml`.
   Every `ascender-db-app` of the original is `<name>-app` here, the two objects' names, the
   Secret the `ExternalSecret` writes and the generator it reads, and the host is `<name>-rw`;
   every other key is the original's. The manifest names that Secret in its bootstrap,
   `secret.name: <name>-app` under `bootstrap.recovery`, or under `bootstrap.initdb` in the dump
   restore's. A cluster deleted to try again (step 4) takes its copy with it, as
   `tests/ascender.bats` refuses a copy that no restore's Cluster names.

   ```yaml
   ---
   apiVersion: generators.external-secrets.io/v1alpha1
   kind: Password
   metadata:
     name: <name>-app
   spec:
     length: 32
     allowRepeat: true
     noUpper: false
     encoding: hex
     secretKeys:
       - password
   ---
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata:
     name: <name>-app
   spec:
     refreshPolicy: CreatedOnce
     target:
       name: <name>-app
       creationPolicy: Owner
       template:
         type: kubernetes.io/basic-auth
         engineVersion: v2
         mergePolicy: Replace
         data:
           username: app
           password: "{{ .password }}"
           dbname: app
           host: <name>-rw
           port: "5432"
           database: app
           sslmode: require
           type: unmanaged
     dataFrom:
       - sourceRef:
           generatorRef:
             apiVersion: generators.external-secrets.io/v1alpha1
             kind: Password
             name: <name>-app
   ```

   Once Flux applies the pull request, the application's Kustomization, which waits for what it
   applies (`wait: true`), is not Ready until the new Cluster's `Ready` condition is `True`:
   kstatus, which Flux's health checks run, reads that condition for a kind it has no rule of its
   own for (`checkReadyCondition` in `pkg/kstatus/status/status.go` of fluxcd/cli-utils v1.4.0,
   which the pinned kustomize-controller builds with). Past its timeout, 10 minutes with
   `k8s-gitops/timeout: long`, Flux reports the apply failed and tries again each minute, and
   [FluxApplierNotReady](alerts.md#fluxappliernotready) fires after 15 minutes, until the new
   cluster is healthy.
3. **Wait for the recovery.** `kubectl --namespace ai-system get cluster n8n-db-restored` reaches
   `Cluster in healthy state`; the recovery job's pod, `n8n-db-restored-1-full-recovery`, logs the WAL
   it replays and the target it stopped at. The operator creates the Secret `n8n-db-restored-app`
   for the database `app`, which for Ascender External Secrets makes from the copy of step 2
   instead.
4. **Check the data** before anything switches: connect to `n8n-db-restored-rw` from a pod of the
   namespace, with the credentials of `n8n-db-restored-app`, and look at the rows the damage touched.
   If the moment was wrong, delete the file's cluster and its volumes and try another target.
5. **Switch the application over,** in a second pull request: the application reads the connection of
   the Secret `<name>-app`, so point it at `n8n-db-restored-app` (for n8n, the five `secretKeyRef`
   names in `values.yaml`), and make the new cluster the one the component makes by setting
   `CNPG_CLUSTER_NAME: n8n-db-restored` in its `ks.yaml` and deleting the file of step 2 and its row
   of `.renovate/by-hand.tsv`. The
   component then makes the Cluster `n8n-db-restored` with its ObjectStore, ScheduledBackup,
   credentials and PodMonitor. This step rests on an assumption that has not been tested: that the
   running cluster, adopted by the component's manifest, accepts losing `bootstrap.recovery` and
   `externalClusters`, which the operator reads only when it makes the first instance, and goes on
   archiving under the same server name. Check, once Flux has applied the change, that the Cluster
   reports `Cluster in healthy state`, that no instance restarts and that the Backup of the next
   schedule completes; if the operator refuses the change, do not go on to the pruning below.
   Flux prunes the old cluster `n8n-db`, and with it its instances and their volumes, its
   ScheduledBackup and its ObjectStore: do this only once step 4 is done.
6. **Delete the old archive** when it is no longer wanted: `s3://<prefix>-postgres/<cluster>/<namespace>/n8n-db`
   holds the old cluster's base backups and WAL, which nothing deletes any more, as the plugin deletes
   only for the clusters that still take backups. The cluster's S3 key can delete them without the
   customer key.

## Restoring a daily dump

Every PostgreSQL cluster made from the `cnpg-cluster` component has a CronJob, `<cluster>-pgdump`,
that dumps its application database once a day with `pg_dump` in custom format, encrypts the dump
with age to the Talos age key's recipient before it leaves the pod, and uploads only the encrypted
file to the postgres backup bucket as `<cluster>/<namespace>/<name>/<UTC time>.dump.age`, where
`<cluster>` is the Kubernetes cluster, `<namespace>` the database's namespace and `<name>` the
Cluster's name; it keeps the newest 14 of that path. A dump is a copy of one day, not a point in
time ([kubernetes.md](../kubernetes.md#postgresql)), and readable only with the Talos age key
([cluster.md](../cluster.md#the-talos-age-key)); losing that key loses every dump.

This restores a dump into a new, empty cluster beside the old one, in the application's own `app/`,
points the application at it, and then makes it the cluster the component makes. The commands run
on the operator's machine, with the pinned tools of
`mise.toml`, `SOPS_AGE_KEY_FILE` naming the Talos age key, and `kubectl` reaching the cluster
through `just cluster-kubeconfig`'s kubeconfig. `rclone` is set up for the object storage in its
environment as `scripts/lib/s3.sh` sets it for the recipes: `RCLONE_CONFIG=/dev/null`, and
`RCLONE_CONFIG_STORE_` followed by `TYPE=s3`, `PROVIDER=Other`, `ENV_AUTH=false`, `ENDPOINT`,
`REGION`, `FORCE_PATH_STYLE`, and the cluster's S3 key as `ACCESS_KEY_ID` and `SECRET_ACCESS_KEY`
(`just infra-s3-key cluster` makes it); the remote is then `store:`. `BACKUP_BUCKET_PREFIX` is the
start of the backup buckets' names, the environment variable the recipes read
([infrastructure.md](../infrastructure.md#environment)), which `just cluster-config` also writes
into the ConfigMap `cluster-config` the job's bucket name is made from. Below, `NS` is the database's
namespace, `OLD` the old Cluster's name, `NEW` the new one's, and `CLUSTER` the Kubernetes cluster's
name.

### What is lost, and what the dump does not hold

- Everything written to the database since the dump was taken. The newest dump is up to a day old
  while the job succeeds, and older while [PostgresDumpJobFailing](alerts.md#postgresdumpjobfailing)
  or [PostgresDumpStale](alerts.md#postgresdumpstale) fires.
- The roles' passwords. A dump of one database holds its objects and their ownership by the
  application's role, not the cluster's roles or their passwords. The new cluster makes its own role
  `app` with a new random password in its Secret `NEW-app`, so the application must read that Secret
  (below); nothing carries the old password over, and no old credential works against the new
  cluster.
- Anything outside the application's database: other databases of the cluster, the cluster's own
  settings, its WAL and any extension's objects the application's role did not create.

### Listing the dumps

The bucket's objects under the database's path, newest first, by name and size:

```sh
just postgres-dumps NS OLD CLUSTER
```

`just postgres-dumps CLUSTER` lists the databases that have a dump, as `<namespace>/<name>`. The
names are the UTC times the dumps were taken. Choose the dump by its time, not by its place in
the listing: when a lost cluster is rebuilt under its old name, Flux creates `OLD` empty with its
own dump job, which from its first night would upload dumps of the empty database to this same
path. Those dumps would start the listing, and after 14 nights every real dump would have been
rotated out. On a rebuilt cluster the component's switch holds the job from Flux's first apply:
`CNPG_BACKUPS_SUSPENDED: "true"` in the application's `ks.yaml`, which
[rebuild.md](rebuild.md#building-it-again) has set before Flux is installed and which the
switchover releases ([kubernetes.md](../kubernetes.md#postgresql)). On a cluster that runs, stop
the rotation until the restore is done by suspending the application's Flux Kustomization
(`flux suspend kustomization <app>`) and then the CronJob
(`kubectl --namespace NS patch cronjob OLD-pgdump --patch '{"spec":{"suspend":true}}'`), which holds
only while the Kustomization stays suspended: at its next apply, kustomize-controller takes over
the field the `kubectl` manager wrote and sets it back to the tree's `suspend: false` (the field
managers in `internal/controller/kustomization_controller.go` of the kustomize-controller the
pinned Flux runs, matched by prefix). The pull request of
[Restoring into a new cluster](#restoring-into-a-new-cluster) therefore suspends the job in the
tree as well, where it stays until that restore's last step.

### Fetching and decrypting one

Check the dump before anything is built for it:

```sh
just postgres-dump-check NS OLD <a name from the listing, or latest> CLUSTER
```

It downloads the dump into a private directory in memory where the machine has a memory-backed
filesystem, checks that it is an age file, decrypts it with the Talos age key and has `pg_restore
--list` read it, without a database, from the cluster's PostgreSQL image. It prints the dump's name,
its sizes, the PostgreSQL version that made it, when, and the number of tables, never a table's name
or a row, and removes everything, on failure too. A dump that is not an age file, that the key does
not decrypt, that `pg_restore` cannot read or that holds no table fails with that reason. The count
includes empty tables, as `pg_dump` keeps a data entry for each, so it does not tell a dump of the
rebuilt, empty database from a real one; the dump's time does.

The restore needs the plain file, which the check does not keep:

```sh
name=<a name from the listing>
rclone copyto --s3-no-check-bucket store:"${BACKUP_BUCKET_PREFIX}-postgres/CLUSTER/NS/OLD/$name" "$name"
age --decrypt --identity "$SOPS_AGE_KEY_FILE" --output restore.dump "$name"
```

The plain `restore.dump` is the database's whole content; delete it when done.

### Restoring into a new cluster

1. Add the new cluster to the application's `app/`, as a file named for it, `NEW.yaml`, listed in
   its `kustomization.yaml`, with its row of `.renovate/by-hand.tsv`, in a pull request, as step 2
   of [Restoring one database to a point in time](#restoring-one-database-to-a-point-in-time) adds
   its own; what that step says of the allows, of Ascender and of the application's Kustomization
   while the new cluster starts holds here too. The name is new, differs from the old cluster's and
   from that of any earlier attempt, as Barman does not archive into a path that holds WAL, and is
   at most 45 characters, the most the dump job's CronJob `NEW-pgdump` allows once the cluster
   becomes the component's in step 5. The manifest is that restore's with `bootstrap.initdb` in
   place of `bootstrap.recovery` and no `externalClusters`: the cluster starts empty, and archives
   its own WAL through the old cluster's ObjectStore under its own server name, which is its name,
   so that it never writes to the old cluster's path. The example is n8n's database again, restored
   as `n8n-db-new`:

   ```yaml
   ---
   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   metadata:
     name: n8n-db-new
   spec:
     instances: 3
     imageName: <the imageName of components/cnpg-cluster/cluster.yaml>
     storage:
       storageClass: linstor-node-local
       size: 5Gi
     affinity:
       enablePodAntiAffinity: true
       topologyKey: kubernetes.io/hostname
       podAntiAffinityType: required
     resources:
       requests:
         cpu: 500m
         memory: 512Mi
       limits:
         cpu: 500m
         memory: 512Mi
     bootstrap:
       initdb:
         database: app
         owner: app
     plugins:
       - name: barman-cloud.cloudnative-pg.io
         isWALArchiver: true
         parameters:
           barmanObjectName: n8n-db
           serverName: n8n-db-new
   ```

   `storage.size` is the old cluster's `CNPG_STORAGE_SIZE` in the application's `ks.yaml`, 5Gi where
   it sets none, and the image and the resources are the component's, as in the point-in-time
   restore, whose check of the workers' room for six instances holds too. Until step 5 the new
   cluster has no ScheduledBackup, dump job or PodMonitor, which the component makes for its own
   Cluster alone: it archives its WAL but takes no base backup, and Prometheus scrapes none of its
   instances, so the alerts on the archive and the base backups do not watch it. A Backup as in
   [Taking a base backup by hand](#taking-a-base-backup-by-hand), with its name, gives it a base
   backup meanwhile.

   The same pull request suspends the old cluster's dump job, `OLD-pgdump`, which would otherwise
   upload a dump of the empty or damaged `OLD` each night and rotate the real dumps out: add this
   entry to the `patches` of the application's `app/kustomization.yaml`, and the key where it has
   none. It names the CronJob as the patches see it, before Flux substitutes the cluster's name:

   ```yaml
   patches:
     - target:
         kind: CronJob
         name: \$\{CNPG_CLUSTER_NAME\}-pgdump
       patch: |-
         - op: add
           path: /spec/suspend
           value: true
   ```

   [PostgresDumpStale](alerts.md#postgresdumpstale) fires for `OLD` once its last dump is a day and
   a half old, until step 5 deletes the job. Flux applies the pull request only while the
   application's Kustomization is not suspended: if the rotation was stopped as
   [Listing the dumps](#listing-the-dumps) says, resume it once the publish run of the merge has
   tagged `main` (`flux resume kustomization <app>`), as Flux applies the artifact that run tags and
   not the merge itself ([kubernetes.md](../kubernetes.md#publishing)): resumed before, it applies
   the artifact before the merge, which ends the suspension until the new one is applied. Once Flux
   has applied it, `kubectl --namespace NS get cronjob OLD-pgdump` shows the job suspended, from
   the tree. Wait until `kubectl --namespace NS get cluster NEW` says `Cluster in healthy state`.
   The operator creates the empty database `app`, owned by the role `app`, and the Secret `NEW-app`,
   which for Ascender External Secrets makes from the copy above instead.
2. Reach its primary, `NEW-rw`, from the machine, with the role's password from the Secret the
   operator made, without printing it:

   ```sh
   kubectl --namespace NS port-forward service/NEW-rw 5432:5432 &
   export PGHOST=127.0.0.1 PGPORT=5432 PGSSLMODE=require
   export PGUSER=$(kubectl --namespace NS get secret NEW-app -o jsonpath='{.data.username}' | base64 -d)
   export PGDATABASE=$(kubectl --namespace NS get secret NEW-app -o jsonpath='{.data.dbname}' | base64 -d)
   export PGPASSWORD=$(kubectl --namespace NS get secret NEW-app -o jsonpath='{.data.password}' | base64 -d)
   ```

   The forward needs no allow in a namespace that denies traffic by default: `kubectl` asks the
   API server to forward to a pod the Service selects, the kubelet hands the stream to the
   container runtime (`getPortForward` in `pkg/kubelet/server/server.go` of Kubernetes v1.37.1),
   and the containerd Talos v1.14.6 ships, v2.3.7, enters the pod's network namespace and connects
   to `localhost:5432` there (`portForward` in `internal/cri/server/sandbox_portforward_linux.go`):
   the session is on the pod's loopback, which no policy sees, as
   [Locust's](../kubernetes.md#locust) is.

3. Restore as that role, into the empty database. The dump's objects are owned by `app`, the role
   the new cluster has too, and `--no-owner` makes every object the restoring role's, so no
   superuser is needed:

   ```sh
   pg_restore --no-password --exit-on-error --single-transaction --no-owner --no-acl \
     --dbname "$PGDATABASE" restore.dump
   ```

   A restore of an older major than the dump's refuses it; use `pg_restore` of the cluster's major,
   from the Cluster's own image if the machine has none. `--single-transaction` leaves the database
   empty when it fails, so it can be run again.
4. Point the application at the new cluster. An application that reads the Secret `OLD-app`'s keys
   and the Service `OLD-rw` reads `NEW-app` and `NEW-rw` instead: the change is the name in its
   values, made through a pull request, after which the application restarts and reads the new
   Secret, with the new password. Its connections to the old cluster end with that. The
   application's own state outside the database, a volume or an encryption key, is as it was.
5. Check the application. Keep the old cluster until the application has run on the new one, then
   make the new cluster the component's as step 5 of
   [Restoring one database to a point in time](#restoring-one-database-to-a-point-in-time) does, in
   a pull request: set `CNPG_CLUSTER_NAME: NEW` in the application's `ks.yaml` (for n8n,
   `apps/base/ai-system/n8n/ks.yaml`), and delete the file of step 1, its row of
   `.renovate/by-hand.tsv` and the patch that suspends the dump job, which would suspend
   `NEW-pgdump` otherwise. The component then makes the Cluster `NEW` with its ObjectStore,
   ScheduledBackup, credentials, dump job and PodMonitor, and the dumps go to `CLUSTER/NS/NEW/`.
   That step's untested assumption, its checks and its warning on the pruning hold here as well,
   with `bootstrap.initdb` for `bootstrap.recovery`: the assumption that the running cluster
   accepts the component's manifest in place of the one it was made with, whose bootstrap the
   operator reads only when it makes the first instance, and goes on archiving under the same
   server name; and the pruning, in which Flux deletes the old cluster `OLD`, its instances and
   their volumes, its ScheduledBackup, its ObjectStore and its dump job.

Stop the port-forward, and unset `PGPASSWORD`, when done.

## Losing the customer key

- **The store's key is gone and the custody file is kept**, as on a rebuilt cluster: seed the store
  again from the file ([above](#the-customer-key)). Databases wait for the key and archive again
  once their ExternalSecrets have read it.
- **The file is gone and the store's key is kept.** The databases keep working, and the key is
  readable from the Secret `<name>-backup` of any database's namespace, so make a new custody file
  at once, in the format the recipe writes, with nothing printed:
  `kubectl --namespace <namespace> get secret <name>-backup --output jsonpath='{.data.SSE_C_KEY}' | base64 --decode | jq -Rsc --arg cluster <cluster> --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{cluster: $cluster, created: $created, postgres: {sse_c_key: .}}' | age --encrypt --recipient <recipient> --output <file>`,
  where `<recipient>` is the one in `talos/.sops.yaml`, then check it opens with the Talos age key.
- **Both are gone.** No base backup or WAL segment can be read: the databases run on, and the S3 key
  can still delete the unreadable objects. Delete the old archives, make a new key with
  `just bao-seed-postgres <file>`, and take a base backup of every database, as a new archive is
  only as old as its first backup.
