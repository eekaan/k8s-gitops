# OpenBao

OpenBao holds the cluster's runtime secrets ([kubernetes.md](../kubernetes.md#openbao)). It unseals
itself with the key in the Secret `openbao-seal-1`, and the operator keeps its recovery keys and a
copy of that key in a file encrypted to the Talos age key
([ADR 0016](../adr/0016-openbao-unseals-itself-and-the-operator-keeps-the-recovery-keys.md)). This
runbook covers the first initialisation, checking it, a first initialisation that failed, a member
that does not rejoin, bringing the seal key back, restoring access with the recovery keys, and
rotating.

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

Then the operator, right away, before anything else logs in as the role `operator`:

7. `just bao-recovery <file>`, with `<file>` a new file outside the repository, beside the Talos age
   key. It makes the recovery keys, writes them with the seal key to `<file>`, encrypted to the Talos
   age key's recipient, opens the file again with the Talos age key, has OpenBao commit the keys,
   and prints only where it wrote them. Keep the file where the Talos age key is kept; it holds the
   only copy of the recovery keys. If it refuses because OpenBao holds recovery keys already,
   someone else made them and holds them: the store is not trusted. Rebuild it as
   [a first initialisation that failed](#a-first-initialisation-that-failed) says, while it holds no
   secret yet, and run this step again.
8. `just bao-put demo/hello greeting`, and type a value at the prompt. Within the ExternalSecret's
   refresh interval, 15 minutes, the Secret `hello` in `demo` holds it under `greeting`.

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
  the value without printing it:
  `kubectl --namespace demo get secret hello --output jsonpath='{.data.greeting}' | base64 -d | sha256sum`
  against the same hash of what was typed.

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
than fifteen minutes is split into several runs. For example, with OpenBao's CLI on the operator's
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
