# Volume backups

VolSync backs an application's volume up to its own restic repository in the VolSync bucket, and
fills a new volume from the latest backup ([kubernetes.md](../kubernetes.md#volume-backups),
[ADR 0015](../adr/0015-volume-backups-with-volsyncs-restic-mover.md)). Every repository's password
is derived from one master password, which `just bao-seed-volsync` keeps in a custody file outside
the cluster: encrypted with age to the Talos age key's recipient, opened with the Talos age key from
`SOPS_AGE_KEY_FILE`, or `SOPS_AGE_KEY`, into memory only. This runbook covers checking the first
backup, restoring a claim from its repository, opening a repository by hand, replacing the cluster's
S3 key, and losing the master's file or the store's key. `<file>` is the custody file.

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
  set after the first run at the schedule's time, 03:17, and `{.status.latestMoverStatus.result}`
  says `Successful` for it. The Kustomization owns the object, so nothing here triggers a run
  sooner.
- `just bao-volsync-password <file> volsync-demo restic snapshots`: the repository lists a snapshot,
  with restic installed on the operator's machine.

## Restoring a claim from its repository

The component restores the latest backup when a claim and its ReplicationDestination are created
together, as on an application's first deployment or on a rebuilt cluster; nothing is done by hand
for that. To restore the latest backup into an application that runs, as
[Restoring](../kubernetes.md#restoring) sets out:

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

## The master's file is lost and the store still holds the key

The store holds the master, so the repositories still open and the backups run. The `operator` role
may create and change a key and never read it, so `just bao-seed-volsync` cannot write the file again
and has no flag that does: a run that finds the key refuses and keeps what is there. A root token
from the recovery keys reads it, through `bao-root`, which runs OpenBao's CLI, and the master goes
down a pipe into a new custody file and appears on no command line or screen. The new file's path
must not exist, as `age` replaces what is at its output, and `<recipient>` is the age recipient in
`talos/.sops.yaml`; `<recovery file>` is the file `just bao-recovery` wrote:

```sh
just bao-root <recovery file> bash -c 'bao kv get -mount=secrets -field=RESTIC_MASTER_PASSWORD volsync |
  jq -Rsc "{cluster: \"lab-sto2\", volsync: {master: rtrimstr(\"\\n\")}}" | age --encrypt --recipient "$1" --output "$2"' _ <recipient> <new file>
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
master or guessed. The backups are lost. To back up again, run `just bao-seed-volsync <file>` against
the store, which holds no key then, for a new master, and move or delete the old repositories'
objects in the VolSync bucket, as restic does not create a repository over one that exists and the
movers fail until that path is empty.
