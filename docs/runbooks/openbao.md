# OpenBao

OpenBao holds the cluster's runtime secrets ([kubernetes.md](../kubernetes.md#openbao)). It unseals
itself with the key in the Secret `openbao-seal-1`, and the operator keeps its recovery keys and a
copy of that key in a file encrypted to the Talos age key
([ADR 0016](../adr/0016-openbao-unseals-itself-and-the-operator-keeps-the-recovery-keys.md)). This
runbook covers the first initialisation, checking it, a first initialisation that failed, a member
that does not rejoin, bringing the seal key back, restoring access with the recovery keys, listing
and checking the snapshots of the raft storage, restoring one, and rotating.

Commands run through the cluster's kubeconfig, `talos/<cluster>/clusterconfig/kubeconfig`, which
`just cluster-kubeconfig` fetches. The recipes read the Talos age key from `SOPS_AGE_KEY_FILE`, or
`SOPS_AGE_KEY`, outside the repository; `<file>` is the custody file `just bao-recovery` writes.

## First initialisation

After the merge, Flux does everything up to the recovery keys, in this order:

1. Once `external-secrets`, `cert-manager`, `linstor-cluster` and `prometheus-operator-crds` are
   Ready, Flux applies `openbao`.
2. External Secrets writes the Secret `openbao-seal-1` from its generator, once: the ExternalSecret
   `openbao-seal-1` reports `SecretSynced`. cert-manager issues the CA `openbao-ca` and then the
   listener's certificate `openbao-tls`: both Certificates report Ready.
3. helm-controller installs the chart. In `openbao-0`, the init container `initialize-guard` finds
   no data of its own and neither `data-openbao-1` nor `data-openbao-2`, and decides to initialise;
   its log is empty, and it exits 0. The server then initialises OpenBao, revokes the root token it
   initialised with and unseals; its log says the post-unseal configuration ran, and the pod turns
   Ready once it is unsealed.
4. `openbao-1`, then `openbao-2`, start. Their guards decide nothing; each server joins `openbao-0`
   and unseals with the same key. The release, and with it the Kustomization `openbao`, is Ready once
   all three are.
5. Flux applies `openbao-store`. External Secrets mints a token for `openbao-store`, logs in as the
   role `external-secrets` and reports the ClusterSecretStore `openbao` Ready, and the Kustomization
   with it.
6. Flux applies `hello-secret`. Its ExternalSecret reports that `demo/hello` does not exist yet.
   Flux applies `volsync-demo` too, once `openbao-store` is Ready: its ExternalSecret reports that
   the key `volsync` does not exist yet, and its claim stays Pending until step 9.

Then the operator, right away, before anything else logs in as the role `operator`:

7. `just bao-recovery <file>`, with `<file>` a new file outside the repository, beside the Talos age
   key. It makes the recovery keys, writes them with the seal key to `<file>`, encrypted to the Talos
   age key's recipient, opens the file again with the Talos age key, has OpenBao commit the keys,
   and prints only where it wrote them. Keep the file where the Talos age key is kept; it holds the
   only copy of the recovery keys. If it refuses because OpenBao holds recovery keys already,
   someone else made them and holds them: the store is not trusted. Rebuild it as
   [a first initialisation that failed](#a-first-initialisation-that-failed) says, while it holds no
   secret yet, and run this step again.
8. Write the demo's key from 32 random bytes, which nobody types or sees:

   ```sh
   head -c 32 /dev/urandom | od -An -vtx1 | tr -d ' \n' | just bao-put demo/hello greeting
   ```

   The ExternalSecret has failed since step 6, and External Secrets tries it again after a delay
   that doubles up to seven minutes, so within that the Secret `hello` in `demo` holds the value
   under `greeting`, and within the kubelet's sync period after it the pods of `hello` hold it as
   the file `/etc/hello/greeting`.
9. `just bao-seed-volsync <file>`, with `<file>` a new file beside the Talos age key on a store that
   never held the key, and the existing custody file of the volume backups' master on a store that
   did, as after a rebuild. It seeds the key `volsync` the volume backups read
   ([volume-backups.md](volume-backups.md)); the demo's ExternalSecret syncs at its next refresh,
   its first restore runs and its claim is Bound.
10. `just bao-seed-postgres <file>`, with `<file>` a new file beside the other custody files on a
    store that never held the key, and the existing custody file of the PostgreSQL backups' key on
    a store that did, as after a rebuild. It seeds the key `postgres-backups`, the customer key the
    PostgreSQL clusters' archives are encrypted with
    ([postgres-restore.md](postgres-restore.md#the-customer-key)); until it runs, the databases'
    backup Secrets do not exist, so the instances start but their archiving fails and
    `PostgresWALArchivingFailing` fires.

The recipes read a custody file only where no one but the operator can have written it: the file
owned by the operator and writable by no one else, in directories only the operator or root can
write to, or whose sticky bit keeps others from replacing what they do not own; `bao-recovery`,
`bao-seed-volsync` and `bao-seed-postgres` write a new one only in such a place. age does not say who wrote a file, and
the Talos age key's recipient is public, so the file's place is what vouches for it: keep the
custody files in a directory only the operator can write, beside the Talos age key.

## Checking it

Each of these only reads:

- `kubectl --namespace openbao get pods --output wide`: `openbao-0`, `openbao-1` and `openbao-2`
  Running and Ready, each on a different worker. Ready means unsealed.
- `kubectl --namespace openbao logs openbao-0 --container initialize-guard`: empty on a first
  install; on later starts nothing, or that the other members' claims exist.
- `kubectl --namespace openbao exec openbao-0 --container openbao -- bao status`, and the same for
  the other two: `Initialized true`, `Sealed false`, `Seal Type static`, `HA Enabled true`, one member
  `HA Mode active` and two `standby`; after step 7, `Total Recovery Shares 5` and `Threshold 3`.
- `kubectl --namespace openbao get pvc`: three claims `data-openbao-N`, Bound.
- `kubectl --namespace openbao get externalsecret,certificate`: `openbao-seal-1`, `openbao-ca` and
  `openbao-tls` Ready.
- `kubectl --namespace openbao get secret openbao-seal-1 --output jsonpath='{.immutable}'`: `true`.
- `kubectl get clustersecretstore openbao`: Ready `True`.
- `kubectl --namespace demo get externalsecret hello`: `SecretSynced` once step 8 is done. To compare
  the value the pods hold with the Secret's, printing a digest of each and neither value:
  `kubectl --namespace demo get secret hello --output jsonpath='{.data.greeting}' | base64 -d | sha256sum`
  against `kubectl --namespace demo exec deployment/hello --container httpd -- sha256sum /etc/hello/greeting`.

A restart test: delete one member, `kubectl --namespace openbao delete pod openbao-1`, wait until it
is Ready again, and check `bao status` in it says `Sealed false`; then each of the other two in turn.
Nobody enters anything, and `demo/hello` reads the same throughout.

## A first initialisation that failed

Self-initialisation marks storage as started before it runs its requests and clears the mark when
they complete; a server that finds the mark refuses to unseal, and `openbao-0` restarts again and
again with an error that self-initialisation failed. It is mended by starting the store again from
nothing, which is safe only while it holds nothing: on a first install, before `bao-recovery` or
`bao-put` has run, and while neither `data-openbao-1` nor `data-openbao-2` exists, as the other
members start only once `openbao-0` is Ready. Once a secret has been written, or the other members
have joined, it is not safe: that store holds what nothing else does.

1. Fix the cause, which the server's log names, through a pull request.
2. Delete the pod and its claim, `kubectl --namespace openbao delete pod openbao-0` and
   `kubectl --namespace openbao delete pvc data-openbao-0`. Keep the Secret `openbao-seal-1`, the
   certificates and everything else. The StatefulSet makes a new claim, the guard finds no data and
   no other claim, and `openbao-0` initialises again.

The same rebuild serves when `bao-recovery` finds recovery keys someone else made, before anything
was written: delete the pods and the three claims, in any order, and the members start from nothing.

A guard that gets no answer from the Kubernetes API is another failure, and nothing is to be
deleted. `openbao-0` stays in `Init:Error`, then `Init:CrashLoopBackOff`, and
`kubectl --namespace openbao logs openbao-0 --container initialize-guard` ends with
`initialize-guard: no answer from the Kubernetes API on the other members' claims; not initialising`,
after kubectl's own error. The server never started, so nothing was initialised and its claim holds
nothing. If kubectl's error names `localhost:8080`, it did not use the pod's in-cluster
configuration, which a flag on its call such as `--request-timeout` turns off; a `Forbidden` names a
missing Role or RoleBinding `openbao-initialize-guard`; a timeout, the API out of reach. Fix the cause
through a pull request; the init container is retried, or `kubectl --namespace openbao delete pod
openbao-0` starts it at once.

## A member that does not rejoin

A member whose volume is new starts empty, does not initialise, and joins the others through
`retry_join` under its old name. OpenBao's raft documentation has a failed server brought back
with the same address, or else removed with `remove-peer`
([integrated storage](https://openbao.org/docs/concepts/integrated-storage/#outage-recovery)). If
the empty member does not become a voter again, which
`just bao-root <file> bao operator raft list-peers` shows, remove its old entry and let it join
anew:

1. `just bao-root <file> bao operator raft remove-peer openbao-N`, with OpenBao's CLI installed on
   the operator's machine. Removing a peer is beyond the `operator` role, so it takes a root token
   from three recovery key shares.
2. `kubectl --namespace openbao delete pod openbao-N`: it starts again and joins.

An empty `openbao-0` after a full restart is the case that does not resolve itself: the other
members start only once `openbao-0` is Ready, which it never becomes alone, as its guard finds their
claims and does not initialise. Bring them up first, through a pull request that lets a sealed member
count as Ready for the time it takes, `server.readinessProbe.path:
"/v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200"` in `values.yaml`. Once `openbao-1`
and `openbao-2` run, they elect a leader on their data, and `openbao-0` joins them; then revert the
pull request.

## Bringing the seal key back

A member that restarts without the Secret `openbao-seal-1` does not start, as its volume cannot be
mounted; one that starts with a different key logs that it cannot unseal. The storage stays sealed on
the volumes either way, and comes back with the key.

1. `just bao-seal-restore <file>` writes the key from the file into the Secret, immutable, as
   External Secrets made it, and prints no key. A Secret that holds the same key is left alone. One
   that holds another key, which External Secrets makes only when both the Secret and the
   ExternalSecret's record of its sync are gone, is kept: once the members fail to unseal with it,
   `just bao-seal-restore <file> --replace` deletes it and writes the file's key. It first writes
   the key it replaces to a new file, `<file>.replaced-<time>.age`, encrypted to the Talos age key
   and opened again with it, in case that key, not the file's, sealed the storage; when it cannot,
   it deletes nothing. Keep that file with the other until the members unseal.
   `just bao-seal-restore <file> --check` only compares, and writes nothing: it says that the Secret
   holds the key in `<file>` and exits 0, or fails naming a Secret that holds another key or does not
   exist, or a file that holds no seal key; with `--replace` as well it refuses.
   `just cluster-last-copies` runs it before the cluster is taken down
   ([rebuild.md](rebuild.md#taking-it-down)).
2. Delete the members that do not start; each starts again and unseals. External Secrets leaves the
   Secret alone: it has synced the ExternalSecret already, and an ExternalSecret made again finds an
   immutable Secret and keeps its key.

Without the file, an etcd snapshot taken while the Secret existed holds it
([etcd-restore.md](etcd-restore.md)).

## Restoring access with the recovery keys

The initial configuration never runs again, so a role, policy or mount that has to change, or one
that broke, is changed with a root token made from the recovery keys:
`just bao-root <file> <command> [argument...]`. It logs in as `operator`, gives OpenBao's
authenticated root token generation three shares from the file, mints with the root token an orphan
token of the root policy that lasts fifteen minutes at most, and revokes the root token. It runs the
command with that token in `BAO_TOKEN` and OpenBao's address through the port-forward in
`BAO_ADDR`, `BAO_CACERT` and `BAO_TLS_SERVER_NAME`, as OpenBao's CLI reads them; the token is
revoked when the command ends, and nothing prints a share or a token. A command that needs longer
than fifteen minutes is split into several runs. If OpenBao does not revoke the root token or the
command's token, the recipe fails and prints the token's accessor and the step that revokes it by
that accessor, `just bao-root <file> bao token revoke -accessor <accessor>`; run it as soon as
OpenBao answers, as a root token never expires. For example, with OpenBao's CLI on the operator's
machine:

```sh
just bao-root <file> bao policy write operator kubernetes/apps/base/openbao/openbao/app/initialize/operator-policy.json
```

Make the same change in `kubernetes/apps/base/openbao/openbao/app/initialize/` through a pull
request, so that a new OpenBao starts with it.

If the Kubernetes auth method itself is broken, nobody can log in to start the generation, and
`bao-root` cannot run. OpenBao's earlier, unauthenticated root generation, `sys/generate-root`, is
off on its listeners by default; turning it on for the time it takes, with
`disable_unauthed_generate_root_endpoints = false` in the listener of `values.yaml` through a pull
request, makes that endpoint answer without a token, and reverting the pull request turns it off
again ([listener](https://openbao.org/docs/configuration/listener/tcp/)). This step has no recipe:
its requests, the shares among them, go to OpenBao through a port-forward with the shares read from
the file into the request bodies on standard input, never typed or printed.

## Listing and checking snapshots

A CronJob takes a snapshot of the raft storage every six hours and uploads it encrypted to the
OpenBao bucket, `BACKUP_BUCKET_PREFIX` followed by `-openbao`, as `<cluster>/<UTC time>.snapshot.age`
([kubernetes.md](../kubernetes.md#raft-snapshots)). Two recipes read that bucket, with the state key,
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` of `.env`, as the etcd snapshot recipes and the
PostgreSQL dump recipes read theirs
([infrastructure.md](../infrastructure.md#s3-keys-and-backup-buckets)). They reach the object storage
and nothing else: neither uses the cluster's kubeconfig, and neither asks the store anything.

The snapshots of a cluster, newest first, each by its name and its size in bytes:

```sh
just openbao-snapshots [cluster]
```

The newest is under 6 hours old, and under 13 while the job is healthy
([OpenBaoSnapshotStale](alerts.md#openbaosnapshotstale)). The same bucket's other objects are none of
the job's. The recipe lists none of them, only the objects directly under the cluster's path that
are named as a snapshot is, and a cluster without snapshots lists nothing and says so.

To check that a snapshot decrypts and is a whole snapshot, without restoring it:

```sh
just openbao-snapshot-check [<a name from the listing>|latest] [cluster]
```

Without a name it takes the newest. It downloads the snapshot into a private directory, in memory
where the machine has a memory-backed filesystem; checks that it begins with age's header; decrypts
it there with the Talos age key, which never leaves the operator's machine; and verifies the
decrypted archive without unpacking it: it is gzip to its end, with nothing after it but zero
bytes, which gzip ignores; it holds `meta.json`, `state.bin`, `SHA256SUMS` and `SHA256SUMS.sealed`,
each once, and nothing else, and ends as OpenBao ends an archive; its metadata is of the version
OpenBao restores, with an index, a term and the size the state has; and the SHA-256 of the metadata
and of the state are the two `SHA256SUMS` gives. It removes everything it wrote, when it fails or is
stopped with Ctrl-C too. A snapshot that passes prints:

```
snapshot: <name>
scratch: memory-backed
encrypted: <bytes> bytes
plain: <bytes> bytes
taken: <YYYY-MM-DD HH:MM:SS> UTC
index: <number>
term: <number>
metadata version: 1
members: <number>
state: <bytes> bytes
checksums: meta.json and state.bin match SHA256SUMS
sealed checksums: <bytes> bytes, not opened: only the store's seal key opens them
```

- `scratch` is where the snapshot was kept while it was checked. On a machine whose runtime
  directory and `/dev/shm` are not in memory, or not writable, it reads
  `disk, as no memory-backed filesystem was found; removed afterwards`, and the check says so before
  it downloads anything: the files were under `TMPDIR` until it removed them.
- `encrypted` and `plain` are the sizes of the object and of the archive it decrypts to. OpenBao
  does not compress the archive, so `plain` is a little more than `state`.
- `taken` is when the store wrote the archive, by its own clock. The archive holds no other time.
  It is normally a little earlier than the time in the snapshot's name, which is when the job
  encrypted it.
- `index` and `term` are raft's: the last entry the snapshot holds, and the term it was written in.
  The index only grows within one store's life, and starts low again in a store that was started
  empty.
- `metadata version` is the version of raft's metadata, 1, the only one OpenBao restores. It is not
  OpenBao's version, which the archive does not name.
- `members` is the number of servers in the raft configuration the snapshot recorded, 3 while the
  store has its three members.
- `state` is the size of the store's storage in the archive.

Nothing of the store is printed: not a storage path or value, not a member's name or address, not a
checksum. The archive is the store's whole storage, ciphertext under the seal key, with every
storage path in the clear, which is why the check keeps it in memory and removes it.

A check that fails exits non-zero with one line that says why, by the snapshot's name where it has
found one, and then the step it failed in:

- `the openbao bucket holds no snapshot of <cluster>`, or `no snapshot <name> of <cluster>`: there is
  nothing to check; `just openbao-snapshots` lists what there is.
- `rclone cannot list the openbao bucket …` and `rclone cannot download <name> …`: the object storage
  refused the request or did not answer, the bucket is not there, or, for a download, the object
  was removed meanwhile or the directory had no room left. What rclone said is on the lines above,
  without the endpoint, the bucket's name or a key; with `CI` set it is in
  `talos/<cluster>/clusterconfig/openbao-snapshot-check.errors.log` instead.
- `<name> is not an age file`: the object is not what the job uploads, which is always age's output.
- `the Talos age key cannot decrypt <name>`: it was encrypted to another recipient than the Talos
  age key the recipe was given, as a snapshot taken before that key was replaced is.
- `age cannot read <name>, for a reason other than the key: it may be damaged, or the scratch
  directory full`: the object is cut short or damaged, or the directory ran out of room. It holds
  the encrypted object and the plain archive at once, about twice the size the listing shows; the
  job's volume bounds a plain snapshot at 256 MiB. Where the runtime directory is too small,
  `XDG_RUNTIME_DIR= just openbao-snapshot-check` has the check try `/dev/shm` instead.
- `<name> is not a raft snapshot archive: …`: it decrypts, and is not the archive OpenBao writes.
  What follows the colon says how: it is not gzip to its end, or bytes other than zeros follow the
  stream; tar cannot list it, or cannot read a member to its end; a member is missing, extra, there
  twice, no regular file, or carries a time OpenBao does not write; the members do not follow one
  another, or are not followed by the two empty blocks that end an archive; `meta.json`,
  `SHA256SUMS` or `SHA256SUMS.sealed` is empty, or too large for OpenBao to read; the metadata is no
  JSON object, is of another version, gives no index above 0 or no term, or gives another size than
  the state has; or `SHA256SUMS` is not its two lines. Without `SHA256SUMS.sealed` OpenBao restores
  an archive only when forced. The check reads the archive with the machine's GNU tar, gzip and
  `sha256sum`: where `tar` is of another kind, which lacks the options the check lists with, every
  snapshot fails with `tar cannot list it to its end`.
- `<name> fails its integrity check: the SHA-256 of meta.json is not the one SHA256SUMS gives`, or
  `of state.bin`: the archive's content is not what OpenBao wrote. A restore refuses it.

A snapshot that is no age file, no raft snapshot archive or fails its integrity check is not one to
restore from: check the one before it, and have the job take a new one
([kubernetes.md](../kubernetes.md#raft-snapshots)).

What the check cannot know, as it holds no seal key:

- Whether the sealed checksums open under the seal key in the custody file, and are the same as the
  plain ones. That is the check a restore makes, and it is all that ties an archive to the store
  that wrote it: anyone who can write to the bucket can encrypt a file to the Talos age key's
  recipient, which is public, and the plain checksums are not signed, so whoever changes an archive
  can write new ones. The check proves that the archive is whole, not who made it.
- Whether the store's keyring opens the data.
- Whether the entries of `state.bin` are well formed, beyond their checksum.

So a pass says that the snapshot arrived whole, opens with the operator's age key and has the shape
a restore reads. Only a restore into a store that unseals with the seal key says the rest.

## Restoring a snapshot

The snapshots cover the loss of the three volumes, or of the cluster, while the operator's custody
file is kept. Everything written after the snapshot restored is lost, up to six hours of it. They do
not cover the loss of the seal key, which the file holds and the Secret `openbao-seal-1` did: a snapshot is
ciphertext that opens only under the seal key its store had, and OpenBao refuses to restore it into a
store whose seal differs; forcing it with `sys/storage/raft/snapshot-force` installs data no key opens.
Nor do they cover the loss of the Talos age key, which decrypts them. With the custody file lost
and the Secret gone, the store is started again empty and every secret is written again
([kubernetes.md](../kubernetes.md#when-something-is-lost)).

A restore goes into a store that unseals with the same seal key and has recovery keys of the
operator's, so that `just bao-root` can run the restore:

1. **Choose the snapshot** with `just openbao-snapshots`, and check it with
   `just openbao-snapshot-check <name>` ([above](#listing-and-checking-snapshots)). The newest is the
   usual choice; take an earlier one when the newest was taken after the damage. A snapshot of a
   store that was started empty after the loss is told from the old store's by its time, in its name
   and in the check's `taken`, which is after the loss, and by its `index`, which only grows within
   one store's life and starts low again in a new one.
   **Stop the job** until the restore is checked: the CronJob keeps running, and a rebuilt cluster
   runs it from the moment `openbao` is Ready, so it uploads snapshots of the empty store under the
   same prefix, and once 56 of them exist (14 days) retention deletes the old store's, the one being
   restored among them. `flux suspend kustomization openbao-snapshots`; if the CronJob already
   exists, also `kubectl --namespace openbao patch cronjob openbao-snapshots --patch
   '{"spec":{"suspend":true}}'`. Step 7 undoes both.
2. **Put the seal key in place.** The Secret `openbao-seal-1` must hold the key the snapshot's store had,
   which `just bao-seal-restore <file>` writes from the custody file (it leaves a Secret that holds the same
   key alone, and replaces another only with `--replace`,
   [above](#bringing-the-seal-key-back)).
   - With the cluster running and only the volumes lost, the Secret is there; check it with
     `just bao-seal-restore <file> --check`, which changes nothing.
   - In a rebuilt cluster the Secret has to exist before the first member starts, or External Secrets makes a new
     key. Once Flux has made the namespace `openbao`, and before it applies the application
     (`flux get kustomization openbao` shows it waiting for its dependencies),
     `flux suspend kustomization openbao`, then `just bao-seal-restore <file>`, then
     `flux resume kustomization openbao`. The ExternalSecret `openbao-seal-1` finds the Secret and keeps its key.
3. **Start the store empty.** With the cluster running, delete the three pods and the three claims, as
   [a first initialisation that failed](#a-first-initialisation-that-failed) says: the members start from nothing,
   `openbao-0` initialises with the seal key in the Secret, and the others join it. In a rebuilt cluster the
   members start empty by themselves. Wait until all three are Ready, as
   [first initialisation](#first-initialisation) steps 3 and 4 say.
4. **Make recovery keys for the new store**: `just bao-recovery <new file>`, a new file beside the custody
   file, never over it. The new store has none, and `just bao-root` needs three shares to make the root token that
   restores.
5. **Fetch and decrypt the snapshot** into a private directory, by hand: the restore needs the plain
   file, and the check keeps none. Fetching reaches the bucket with rclone, configured through its
   environment as the recipes configure it, so no rclone configuration file of the operator's is
   read; the endpoint, the region and whether addressing is by path are in
   `infra/openstack/backend.hcl`, and the key is the cluster's, `CLUSTER_S3_ACCESS_KEY_ID` and
   `CLUSTER_S3_SECRET_ACCESS_KEY` of `.env`. Set the variables from those files without printing a
   value, in a shell that is closed afterwards:

   ```sh
   export RCLONE_CONFIG=/dev/null RCLONE_CONFIG_STORE_TYPE=s3 RCLONE_CONFIG_STORE_PROVIDER=Other \
     RCLONE_CONFIG_STORE_ENV_AUTH=false RCLONE_CONFIG_STORE_FORCE_PATH_STYLE=<use_path_style> \
     RCLONE_CONFIG_STORE_ENDPOINT=<endpoint> RCLONE_CONFIG_STORE_REGION=<region> \
     RCLONE_CONFIG_STORE_ACCESS_KEY_ID=<access key ID> RCLONE_CONFIG_STORE_SECRET_ACCESS_KEY=<secret key>
   ```

   Fetch the snapshot into a directory only you can read and open it with the Talos age key, which
   never leaves the operator's machine; the archive's listing is all that is printed:

   ```sh
   umask 077
   dir=$(mktemp -d)
   rclone copyto store:<BACKUP_BUCKET_PREFIX>-openbao/<cluster>/<name> "$dir/snapshot.age"
   head -n 1 "$dir/snapshot.age"
   age --decrypt --identity "$SOPS_AGE_KEY_FILE" --output "$dir/snapshot" "$dir/snapshot.age"
   tar -tzf "$dir/snapshot"
   ```

   The first line is `age-encryption.org/v1`, and the listing is `meta.json`, `state.bin`,
   `SHA256SUMS` and `SHA256SUMS.sealed`: OpenBao's raft snapshot archive. The decrypted file is the
   store's whole storage, ciphertext under the seal key. It is not a copy to keep.
6. **Restore it** with OpenBao's CLI on the operator's machine, which takes the file by its path:
   `just bao-root <new file> bao operator raft snapshot restore "$dir/snapshot"`. The restore replaces the
   store's data with the snapshot's, so the store's own tokens, the command's among them, are replaced
   too: the recipe's last step, revoking its token, can fail with the token unknown, and its report
   names the token's accessor. Remove `$dir` once the restore has run.
7. **Check it.**
   - `kubectl --namespace openbao get pods`: three members Ready, which means unsealed, and
     `kubectl --namespace openbao exec openbao-0 --container openbao -- bao status` says `Sealed false`.
   - The original custody file opens the restored store, and the new file no longer does. OpenBao
     keeps the recovery key in its storage, at `core/recovery-key`, and checks the shares of a root
     token generation against what is there when it runs (the pinned release's
     `internal/vault/seal_autoseal.go` and `internal/vault/seal_manager.go`); the snapshot carries
     that storage, so the restored store's
     recovery key is the one `just bao-recovery <file>` made for the store the snapshot was taken of.
     `just bao-root <file> bao token lookup -accessor <accessor>`, with the accessor step 6's report
     named, opens it and says that token is gone; without an accessor, `just bao-root <file> bao status`.
     Remove the new file only once the custody file has opened the store. A snapshot taken before
     the original store's recovery keys were made carries none: neither file opens a store restored
     from it, and `just bao-recovery <another new file>` makes them, as after a first initialisation.
   - `just bao-root <file> bao kv list secrets/`, which prints key names and never values, shows the keys the store held, such as `volsync`.
   - `kubectl get externalsecret --all-namespaces`: every ExternalSecret of the store reports
     `SecretSynced` within its refresh interval, as the role `external-secrets` came back with the snapshot.
   - Start the job again: `flux resume kustomization openbao-snapshots`, and, if step 1 suspended the
     CronJob, `kubectl --namespace openbao patch cronjob openbao-snapshots --patch
     '{"spec":{"suspend":false}}'`. Then
     `kubectl --namespace openbao create job --from=cronjob/openbao-snapshots <name>` takes a snapshot of the
     restored store, so the bucket's newest is of it.

## Rotating

- **The listener's certificate** renews itself: cert-manager renews it before it expires, and each
  member reloads it within 30 seconds. To replace the CA, delete the Secret `openbao-ca`, then
  `openbao-tls`; cert-manager issues both again, and the store and the monitor read the new CA from
  the Secret.
- **The seal key**, through a pull request: add a second generator and ExternalSecret,
  `openbao-seal-2`, beside the first in `seal.yaml`, and mount it in `extraVolumes`; in the seal
  stanza, make `openbao-seal-2` the current key and `openbao-seal-1` the previous key
  (`previous_key_id`, `previous_key`). Each member unseals with either and seals the root key again
  with the current one ([static seal](https://openbao.org/docs/configuration/seal/static/)). Once
  every member has restarted on the new configuration, a second pull request removes the previous
  key and `openbao-seal-1`. Keep a copy of the new key encrypted beside the recovery keys, without
  printing it:

  ```sh
  kubectl --namespace openbao get secret openbao-seal-2 --output json |
    jq '{seal: {secret: .metadata.name, key_id: .metadata.name, key: (.data.key | @base64d)}}' |
    age --encrypt --recipient "$(yq '.creation_rules[0].age' talos/.sops.yaml)" --output <new file>
  ```

- **The recovery keys** rotate with three of the current shares, through OpenBao's rotation with
  verification, which the role `operator` may run: `sys/rotate/recovery/init`, `update` with three
  current shares, then `verify` with three of the new ones
  ([rotate-keys](https://openbao.org/docs/commands/operator/rotate-keys/)). This step has no recipe
  yet; until it has one, rotate them only when a share is known to be exposed, run the requests
  through `just bao-root <file> <command>`, give each share on standard input from the file, and
  send the new shares straight into a new file encrypted to the Talos age key, never to the screen.
- **An application's secret**, where `secret-rotation.yaml` lists its key as `generated`:
  `just secret-rotate <path> <key>`, such as `just secret-rotate demo/hello greeting`. It shows what
  it will do and asks for the path to be typed back, then writes a value it makes itself, has the
  Secret refreshed and waits for the restart. It is done when its last line says how many pods of
  which workload are new and hold the new value; when it stops after the write it says what the
  store and the Secret hold, and a second run rotates again and proves the value it writes
  ([Rotating an application's secret](../kubernetes.md#rotating-an-applications-secret)). The
  recipe rotates and never seeds: where the store does not hold the key yet, it refuses for an
  ExternalSecret that is not Ready and pods that hold no file. The first value is written as step 8
  of [the first initialisation](#first-initialisation) writes the demo's, from random bytes with
  `just bao-put <path> <key>`, and never typed: Reloader keeps a digest of the Secret's data in the
  workload ([What Git does not declare](../kubernetes.md#rotating-an-applications-secret)). The
  ExternalSecret follows within seven minutes, the delay External Secrets retries a failed one
  after, and the kubelet adds the file to the running pods within its sync period. A key the list
  has as `issued` or `re-encryption` is rotated as its application's section says, and the recipe
  refuses it.
