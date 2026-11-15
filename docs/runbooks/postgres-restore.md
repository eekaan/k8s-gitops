# Restoring a PostgreSQL database from a dump

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

## What is lost, and what the dump does not hold

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

## Listing the dumps

The bucket's objects under the database's path, newest last:

```sh
rclone lsf --files-only store:"${BACKUP_BUCKET_PREFIX}-postgres/CLUSTER/NS/OLD/" | sort
```

The names are the UTC times the dumps were taken. Choose the dump by its time, not by its place in
the listing: when a lost cluster is rebuilt under its old name, Flux creates `OLD` empty with its
own dump job, which from its first night uploads dumps of the empty database to this same path.
Those dumps end the listing, and after 14 nights every real dump has been rotated out. Restore
before then, or stop the rotation until the restore is done by suspending the application's
Flux Kustomization (`flux suspend kustomization <app>`) and then the CronJob
(`kubectl --namespace NS patch cronjob OLD-pgdump --patch '{"spec":{"suspend":true}}'`).

## Fetching and decrypting one

```sh
name=<a name from the listing>
rclone copyto --s3-no-check-bucket store:"${BACKUP_BUCKET_PREFIX}-postgres/CLUSTER/NS/OLD/$name" "$name"
age --decrypt --identity "$SOPS_AGE_KEY_FILE" --output restore.dump "$name"
pg_restore --list restore.dump | head
```

`pg_restore --list` reads the table of contents without a database: a file that is not a dump, or
that a `pg_restore` of an older major than the dump's cannot read, fails here. The plain `restore.dump`
is the database's whole content; delete it when done.

## Restoring into a new cluster

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
