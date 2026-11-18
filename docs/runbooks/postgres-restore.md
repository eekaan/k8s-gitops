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
checking the first archive and backup, taking a backup by hand, restoring one database to a point in
time into a new cluster beside the old one and switching the application over, restoring a dump,
and losing the key. Nothing here has been run against a cluster that lost a database: the first time
it is used is the first time it is tested, so each step says what to check before the next.

In a namespace that denies traffic by default, as `backstage` does, a database's allows select its
pods by the cluster's name ([kubernetes.md](../kubernetes.md#what-the-namespaces-let-through)), so
the pods of a new cluster reach nothing and are reached by nothing once the cluster enforces its
policies. The pull request that adds the new cluster, for either restore, adds its allows as well:
those of the old cluster under the new name and, for a restore from the archive, the object
storage's also for the recovery job's pod, which carries `cnpg.io/jobRole: full-recovery` in place
of the instances' `cnpg.io/podRole: instance` and holds the plugin's sidecar as they do.

## What is backed up

- The archive of a cluster is `s3://<BACKUP_BUCKET_PREFIX>-postgres/<CLUSTER_NAME>/<namespace>/<name>`
  (`<name>` is the cluster's `CNPG_CLUSTER_NAME`), under which the plugin keeps `base/` for base
  backups and `wals/` for WAL segments. Two databases never share a path.
- The dumps are the files directly in the same directory, `<UTC time>.dump.age`, the newest 14
  of them, beside the archive's `base/` and `wals/`; the dump job deletes only files of that form
  directly there, and the plugin only in `base/` and `wals/`
  ([Restoring a daily dump](#restoring-a-daily-dump)).
- A base backup is taken at 02:47 UTC every day, and one when a cluster's ScheduledBackup is made.
  WAL is archived as each 16 MiB segment fills or `archive_timeout` forces it.
- Base backups and WAL are kept for a recovery window of 30 days: the database can be restored to any
  moment of the last 30 days that WAL covers. The plugin deletes what falls outside the window after
  each base backup, with the cluster's S3 key, which may delete in every bucket of the project, so a
  workload that holds it can delete the archive too.
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

## Restoring one database to a point in time

This makes a new cluster from the archive of the old one, beside it, and switches the application
over once the new one is checked. The old cluster keeps running, and its archive is only read, so
a wrong target time costs another try and nothing else. The examples are n8n's database, `n8n-db` in
`ai-system`, restored as `n8n-db-restored`.

1. **Choose the moment.** The last moment before the damage, in UTC, within the window: a Backup
   older than it must exist (`kubectl --namespace ai-system get backup`). Without a target the
   recovery replays to the end of the archive.
2. **Add the new cluster to the application's `app/`,** as a file listed in its `kustomization.yaml`,
   in a pull request, as Flux owns the namespace's objects. The name is new and differs from the old
   cluster's. The manifest reads the old cluster's archive, through the old cluster's ObjectStore and
   server name, and archives its own under its own server name, which is its name. Two clusters must
   never write to one path: Barman refuses to archive into a path that holds the WAL of another
   database system, and a path they did share would interleave two timelines, so the old archive
   would stop being restorable.

   ```yaml
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
   of each per worker, so check the workers have the memory for six.
3. **Wait for the recovery.** `kubectl --namespace ai-system get cluster n8n-db-restored` reaches
   `Cluster in healthy state`; the recovery job's pod, `n8n-db-restored-1-full-recovery`, logs the WAL
   it replays and the target it stopped at. The operator creates the Secret `n8n-db-restored-app`
   for the database `app`.
4. **Check the data** before anything switches: connect to `n8n-db-restored-rw` from a pod of the
   namespace, with the credentials of `n8n-db-restored-app`, and look at the rows the damage touched.
   If the moment was wrong, delete the file's cluster and its volumes and try another target.
5. **Switch the application over,** in a second pull request: the application reads the connection of
   the Secret `<name>-app`, so point it at `n8n-db-restored-app` (for n8n, the five `secretKeyRef`
   names in `values.yaml`), and make the new cluster the one the component makes by setting
   `CNPG_CLUSTER_NAME: n8n-db-restored` in its `ks.yaml` and deleting the file of step 2. The
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

This restores a dump into a new, empty cluster made from the component beside the old one, then
points the application at it. The commands run on the operator's machine, with the pinned tools of
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
the field the `kubectl` manager wrote and sets it back to the tree's `suspend: false`.

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

1. Make the new cluster beside the old one, through a pull request as any change to the tree: an
   application of its own, `apps/base/NS/<app>-restore/`, listed in the cluster's overlay, whose
   `ks.yaml` is the one [PostgreSQL](../kubernetes.md#postgresql) gives with `CNPG_CLUSTER_NAME: NEW`
   and whose `app/kustomization.yaml` lists no resource. The cluster is made from the component, so
   it brings its own dump job, which dumps the restored database from the next night. Wait until
   `kubectl --namespace NS get cluster NEW` says `Cluster in healthy state`. The operator creates
   the empty database `app`, owned by the role `app`.
2. Reach its primary, `NEW-rw`, from the machine, with the role's password from the Secret the
   operator made, without printing it:

   ```sh
   kubectl --namespace NS port-forward service/NEW-rw 5432:5432 &
   export PGHOST=127.0.0.1 PGPORT=5432 PGSSLMODE=require
   export PGUSER=$(kubectl --namespace NS get secret NEW-app -o jsonpath='{.data.username}' | base64 -d)
   export PGDATABASE=$(kubectl --namespace NS get secret NEW-app -o jsonpath='{.data.dbname}' | base64 -d)
   export PGPASSWORD=$(kubectl --namespace NS get secret NEW-app -o jsonpath='{.data.password}' | base64 -d)
   ```

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
   take it out of the tree, and delete its `Cluster` object if Flux leaves it, which removes its
   instances and their volumes with it. The old cluster comes from the `cnpg-cluster` component
   named in the application's own `ks.yaml` (for n8n, `apps/base/ai-system/n8n/ks.yaml`), so taking
   it out means removing that component and its `CNPG_*` substitutions there, in a pull request;
   the database then lives in the `<app>-restore` application alone, and its dumps go to
   `CLUSTER/NS/NEW/`.

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
