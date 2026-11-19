# Volume backups

VolSync backs an application's volume up to its own restic repository in the VolSync bucket, and
fills a new volume from the latest backup ([kubernetes.md](../kubernetes.md#volume-backups),
[ADR 0015](../adr/0015-volume-backups-with-volsyncs-restic-mover.md)). Every repository's password
is derived from one master password, which `just bao-seed-volsync` keeps in a custody file outside
the cluster: encrypted with age to the Talos age key's recipient, opened with the Talos age key from
`SOPS_AGE_KEY_FILE`, or `SOPS_AGE_KEY`, into memory only, and read only where no one but the
operator can have written it, as [openbao.md](openbao.md#first-initialisation) says: its place is
what vouches for it. This runbook covers checking the first
backup and the first restore drill, restoring a claim from its repository, opening a repository by
hand, replacing the cluster's S3 key, seeding the store again from the file once it lost the key, as
on a rebuilt cluster, and losing the master's file, or the file and the store's key both. `<file>` is
the custody file.

## Checking the first backup

After `just bao-seed-volsync <file>`, each of these only reads:

- `kubectl --namespace demo get externalsecret volsync-demo-volsync`: `SecretSynced` once the store
  holds the key; until then it reports the key missing and no mover runs.
- `kubectl --namespace demo get replicationdestination volsync-demo-restore --output jsonpath='{.status.latestImage.name}'`:
  the name of the snapshot the first restore made, which is of an empty volume while the
  repository holds no backup.
- `kubectl --namespace demo get pvc volsync-demo`: `Bound`, as the claim is made from that snapshot
  and the pod that uses it is scheduled.
- `kubectl --namespace demo get replicationsource volsync-demo --output jsonpath='{.status.lastSyncTime}'`:
  set once the first backup has ended, and `{.status.latestMoverStatus.result}` says `Successful`
  for it. VolSync starts the first backup of a new ReplicationSource at once, whatever its
  schedule, so it runs once the Secret holds the key and the claim is bound, and every later one at
  the schedule's time, 03:17. `just cluster-last-copies`, before a cluster is taken down, runs a
  backup of every volume now, by VolSync's manual trigger while the Kustomization is suspended
  ([cluster.md](../cluster.md#recipes)).
- `just bao-volsync-password <file> volsync-demo restic snapshots`: the repository lists a snapshot,
  with restic installed on the operator's machine.

## Checking the first drill

The restore drill of `volsync-demo` ([The restore drill](../kubernetes.md#the-restore-drill)) restores
at once when its ReplicationDestination is created, then at 04:17, and checks at 05:17, all UTC. Each
of these only reads:

- `kubectl --namespace demo get replicationdestination volsync-demo-drill --output yaml`:
  `status.lastSyncTime` set by the first restore, `status.latestMoverStatus.result` `Successful`,
  with the tail of the mover's log, which names the snapshot it restored or says
  `No eligible snapshots found`, `status.lastSyncDuration` far below the hour before the check, and
  `status.nextSyncTime` at the next 04:17.
- `kubectl --namespace demo get pvc volsync-demo-drill`: Pending until the first restore's mover is
  scheduled, then `Bound`.
- `kubectl --namespace demo get cronjob volsync-demo-drill-check` and
  `kubectl --namespace demo get jobs`, after 05:17: the CronJob's last schedule, and the job it made;
  `kubectl --namespace demo logs job/<job>` is the check's one line, which on a pass reads
  `restore drill check passed: the heartbeat is <age> seconds old, within the largest age of 95400
  seconds`, `<age>` from a little under 7200 to about 8700.

A check after a restore of a backup without a heartbeat, as one taken before the pod wrote it, fails
once, saying so. The first check does when the drill is first applied from a few minutes before
03:17 until 05:17, as the pod's heartbeat comes with it and the 03:17 backup holds none until the
pod's Recreate rollout has finished and written one. It raises
[RestoreDrillJobFailing](alerts.md#restoredrilljobfailing) half an hour later, which the next
night's pass clears, and the stock `KubeJobFailed` 15 minutes later, which clears only once the
failed job is deleted, as that section says.

## Restoring a claim from its repository

The component restores the latest backup when a claim and its ReplicationDestination are created
together, as on an application's first deployment or on a rebuilt cluster, once the store holds the
key `volsync`; nothing else is done by hand for that. A rebuilt cluster's store is new and holds no
key, so its restores wait, their claims Pending, until the store is seeded again from the file that
holds the master ([below](#the-stores-key-is-lost-and-the-file-is-kept)). To restore the latest
backup into an application that runs, as [Restoring](../kubernetes.md#restoring) sets out:

1. Suspend what keeps the application: `flux suspend kustomization <app>`, and
   `flux suspend helmrelease <release> --namespace <namespace>` when a chart runs it, as drift
   detection would undo the next step.
2. Stop the pods that use the claim, by scaling their Deployment or StatefulSet to zero.
3. Delete the claim and the ReplicationDestination `<app>-restore`:
   `kubectl --namespace <namespace> delete pvc <claim>` and
   `kubectl --namespace <namespace> delete replicationdestination <app>-restore`.
4. Resume what was suspended: `flux resume kustomization <app>`, and the HelmRelease. Flux makes the
   ReplicationDestination and the claim again and puts the pods' replicas back as the manifests say;
   the ReplicationDestination restores the latest backup, and the claim is made from the snapshot
   it keeps.
5. Check as above: the ReplicationDestination's `status.latestImage`, the claim `Bound`, and the
   application's data.

What was written to the volume after the backup is lost, and a claim deleted without its
ReplicationDestination is made from the snapshot kept from the earlier restore, not the latest
backup.

To take files out of a repository without touching the cluster, restore into a directory with
`just bao-volsync-password <file> <app> restic restore latest --target <directory>`.

## Opening a repository by hand

`just bao-volsync-password <file> <app> <command> [argument...]` runs the command with
`RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and
`AWS_DEFAULT_REGION` set for that application, and nothing of them printed. `<app>` is the
application's Kustomization name, which is the `APP` its repository is named for. restic is not a
pinned tool; install it on the machine that runs this. To compare a derived password with the one a
Secret holds without printing either:

```sh
just bao-volsync-password <file> <app> bash -c 'printf %s "$RESTIC_PASSWORD" | sha256sum'
kubectl --namespace <namespace> get secret <app>-volsync --output jsonpath='{.data.RESTIC_PASSWORD}' | base64 -d | sha256sum
```

The two hashes are equal when `<file>` holds the master the store holds.

## Replacing the cluster's S3 key

When the key in `.env` is replaced, `just bao-seed-volsync --rotate-s3` writes the new one into the
store's key `volsync` and keeps the master. External Secrets writes it into each application's
Secret at its next refresh; a mover that ran meanwhile with the old key fails until then, and runs
again at its next schedule.

## The store's key is lost and the file is kept

OpenBao keeps its data on volumes of the default StorageClass, which do not survive a rebuild
([rebuild.md](rebuild.md#what-does-not)), so a rebuilt cluster's store, like any store started
again from nothing, holds no key `volsync`. Until it does, no ExternalSecret of the component syncs,
and no backup or restore runs. The master that opens the existing repositories is in the file, so
the store is seeded from it, never with a new one:

1. `just bao-recovery <recovery file>`, with a new file, right after the first reconcile, as on any
   first initialisation ([openbao.md](openbao.md#first-initialisation)): the recovery keys of the
   old store open nothing in the new one.
2. `just bao-seed-volsync <file>`, with the existing custody file, with the cluster's S3 key in
   `.env`. The recipe finds no key, reads the master back from the file, makes no other, and creates
   the key with it and the cluster's S3 key; the file stays as it was, and the recipe says it wrote
   the key with the master in it. A new file instead would make a new master, which opens none of
   the existing repositories: every restore would fail on its repository's password.
3. Check as in [Checking the first backup](#checking-the-first-backup): each ExternalSecret
   `SecretSynced`, each ReplicationDestination's `status.latestImage` set by a restore of the latest
   backup, each claim `Bound`, and `just bao-volsync-password <file> <app> restic snapshots` listing
   the backups the application had. On a rebuilt cluster the listing does not check the restore:
   each rebuilt ReplicationSource backs its claim up as soon as it is bound, and on the day of the
   last backup the retention, which keeps the newest backup of each day, then forgets that backup's
   snapshot. Check each claim by its ReplicationDestination instead, as step 6 of
   [Building it again](rebuild.md#building-it-again) does.

An empty store cannot tell a rebuilt cluster from a new one, so a seeding given a new file there
makes a new master; its usage and the last line it prints say that a store that held the key before
takes the existing file. To go back, delete the key's versions and metadata with a token of the root
policy, which the `operator` role does not hold, and seed again from the existing file:

```sh
just bao-root <recovery file> bao kv metadata delete -mount=secrets volsync
just bao-seed-volsync <file>
```

The tests run these two against fakes of OpenBao and of the CLI's request, a DELETE of the key's
metadata path, as OpenBao documents `kv metadata delete`. External Secrets writes the restored
master's passwords into each application's Secret at its next refresh. A repository a mover created
with the new master meanwhile, for an application that had none, opens only with that master:
delete its objects, as when [both are lost](#the-file-and-the-stores-key-are-both-lost), and the
mover creates it again. Delete the file made by mistake.

## The master's file is lost and the store still holds the key

The store holds the master, so the repositories still open and the backups run. The `operator` role
may create and change a key and never read it, so `just bao-seed-volsync` cannot write the file again
and has no flag that does: a run that finds the key refuses and keeps what is there. A root token
from the recovery keys reads it, through `bao-root`, which runs OpenBao's CLI, and the master goes
down a pipe into a new custody file and appears on no command line or screen. The new file's path
must not exist, as `age` replaces what is at its output, and `<recipient>` is the age recipient in
`talos/.sops.yaml`; `<recovery file>` is the file `just bao-recovery` wrote. The shell stops when
`bao kv get` fails, so no file holds an empty master, and `lab-sto2` is the cluster's name:

```sh
just bao-root <recovery file> bash -euo pipefail -c 'master=$(bao kv get -mount=secrets -field=RESTIC_MASTER_PASSWORD volsync)
  printf "%s" "$master" | jq -Rsc "{cluster: \"lab-sto2\", volsync: {master: .}}" |
    age --encrypt --recipient "$1" --output "$2"' _ <recipient> <new file>
```

The recipes are tested against fakes of OpenBao; this command, which runs OpenBao's own CLI, is
not. Check the file it wrote as above: its derived password's hash equals the hash of the Secret's.
Then keep it outside the cluster, as the master's only copy that outlives it.

## The file and the store's key are both lost

While the cluster runs, each application's Secret `<app>-volsync` holds that application's
repository password, which opens that application's repository and no other. Take what is needed
out of the repositories with it now, reading it through a pipe or a file only the operator can read
and never an argument, and nothing derives it again.

Once those Secrets are gone too, as on a rebuilt cluster, nothing opens the repositories: restic
cannot read a repository without its password, and the password cannot be derived without the
master or guessed. The backups are lost. To back up again, run `just bao-seed-volsync <file>` with a
new file against the store, which holds no key then, for a new master, and move or delete the old
repositories' objects in the VolSync bucket, as restic does not create a repository over one that
exists and the movers fail until that path is empty.
