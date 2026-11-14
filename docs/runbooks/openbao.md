# OpenBao

OpenBao holds the cluster's runtime secrets ([kubernetes.md](../kubernetes.md#openbao)). It unseals
itself with the key in the Secret `openbao-seal-1`, and the operator keeps its recovery keys and a
copy of that key in a file encrypted to the Talos age key
([ADR 0016](../adr/0016-openbao-unseals-itself-and-the-operator-keeps-the-recovery-keys.md)). This
runbook covers the first initialisation, checking it, bringing the seal key back, restoring access
with the recovery keys, and rotating.

Commands run through the cluster's kubeconfig, `talos/<cluster>/clusterconfig/kubeconfig`, which
`just cluster-kubeconfig` fetches. `$SOPS_AGE_KEY_FILE` names the Talos age key, outside the
repository.

## First initialisation

After the merge, Flux does everything up to the recovery keys, in this order:

1. Once `external-secrets`, `cert-manager`, `linstor-cluster` and `prometheus-operator-crds` are
   Ready, Flux applies `openbao`.
2. External Secrets writes the Secret `openbao-seal-1` from its generator, once. cert-manager issues
   the CA `openbao-ca` and then the listener's certificate `openbao-tls`.
3. helm-controller installs the chart. `openbao-0` starts once both Secrets exist; no other member
   answers, so it reads the initial configuration, initialises OpenBao, revokes the root token it
   initialised with and unseals. Its readiness probe passes once it is unsealed.
4. `openbao-1`, then `openbao-2`, start, join `openbao-0` and unseal with the same key. The release,
   and with it the Kustomization `openbao`, is Ready once all three are.
5. Flux applies `openbao-store`. External Secrets logs in as the role `external-secrets` and reports
   the ClusterSecretStore `openbao` Ready, and the Kustomization with it.
6. Flux applies `hello-secret`. Its ExternalSecret reports that `demo/hello` does not exist yet.

Then the operator, once:

7. `just bao-recovery <file>`, with `<file>` a new file outside the repository, beside the Talos age
   key. It makes the recovery keys and writes them with the seal key to `<file>`, encrypted to the
   Talos age key's recipient, and prints only where it wrote them. Keep the file where the Talos age
   key is kept; it holds the only copy of the recovery keys. To check that it opens, without
   printing a key:

   ```sh
   age -d -i "$SOPS_AGE_KEY_FILE" <file> | jq '{shares: .recovery.shares, threshold: .recovery.threshold, seal: .seal.key_id}'
   ```

8. `just bao-put demo/hello greeting`, and type a value at the prompt. Within the ExternalSecret's
   refresh interval, 15 minutes, the Secret `hello` in `demo` holds it under `greeting`.

## Checking it

Each of these only reads:

- `kubectl --namespace openbao get pods --output wide`: `openbao-0`, `openbao-1` and `openbao-2`
  Running and Ready, each on a different worker. Ready means unsealed.
- `kubectl --namespace openbao exec openbao-0 -- bao status`, and the same for the other two:
  `Initialized true`, `Sealed false`, `Seal Type static`, `HA Enabled true`, one member
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

## Bringing the seal key back

A member that restarts without the Secret `openbao-seal-1` does not start, as its volume cannot be
mounted; one that starts with a different key logs that it cannot unseal. The storage stays sealed
on the volumes either way, and comes back with the key.

1. `kubectl --namespace openbao get secret openbao-seal-1`. If a Secret of that name holds another key,
   which External Secrets makes only when the Secret and the ExternalSecret's sync record are both
   gone, delete it: `kubectl --namespace openbao delete secret openbao-seal-1`. It is immutable, so it
   cannot be overwritten in place.
2. Write the key back from the operator's file, without printing it:

   ```sh
   age -d -i "$SOPS_AGE_KEY_FILE" <file> | jq '{apiVersion: "v1", kind: "Secret", type: "Opaque",
     metadata: {name: .seal.secret, namespace: "openbao"}, immutable: true,
     data: {key: (.seal.key | @base64)}}' | kubectl apply --server-side --filename -
   ```

   Without the file, an etcd snapshot taken while the Secret existed holds it
   ([etcd-restore.md](etcd-restore.md)).
3. Delete the members that do not start; each starts again and unseals. External Secrets leaves the
   Secret alone: it has synced the ExternalSecret already, and an ExternalSecret made again finds an
   immutable Secret and keeps its key.

## Restoring access with the recovery keys

The initial configuration never runs again, so a role, policy or mount that has to change, or one
that broke, is changed with a root token made from the recovery keys. The role `operator` may start
that, through OpenBao's authenticated root token generation, which takes three of the five shares
and returns the token encoded with a one-time password
([generate-root](https://openbao.org/docs/commands/operator/generate-root/)).

1. Open a shell in a member that keeps nothing it is given in a history file:
   `kubectl --namespace openbao exec -it openbao-0 -- env HISTFILE=/dev/null sh`.
2. In a second terminal, mint a token for the operator's account and copy it:
   `kubectl create token openbao-operator --namespace openbao --audience openbao --duration 10m`.
   In the member's shell, read it without echo and log in:

   ```sh
   read -rs jwt
   export BAO_TOKEN="$(printf '%s' "$jwt" | bao write -field=token auth/kubernetes/login role=operator jwt=-)"
   ```

3. `bao operator generate-root -generate-otp` prints a one-time password;
   `bao operator generate-root -init -otp=<password>` starts the generation and prints its nonce.
4. Three times, `bao operator generate-root -nonce=<nonce>`, and paste one share at its prompt,
   which does not echo. On the operator's machine,
   `age -d -i "$SOPS_AGE_KEY_FILE" <file> | jq -r '.recovery.keys_base64[]'` prints the shares; clear
   the terminal afterwards. The last answer gives the encoded token.
5. `export BAO_TOKEN="$(bao operator generate-root -decode=<encoded token> -otp=<password>)"`, make
   the change, and make the same change in `kubernetes/apps/base/openbao/openbao/app/initialize/`
   through a pull request, so that a new OpenBao starts with it.
6. `bao token revoke -self`, and leave the shell.

If the Kubernetes auth method itself is broken, nobody can log in to start the generation. OpenBao's
earlier, unauthenticated root generation is off on its listeners by default; turning it on for the
time it takes, with `disable_unauthed_generate_root_endpoints = false` in the listener of
`values.yaml` through a pull request, makes `bao operator generate-root` work without a token, and
the same pull request reverted turns it off again
([listener](https://openbao.org/docs/configuration/listener/tcp/)).

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
  key and `openbao-seal-1`. Keep a copy of the new key encrypted beside the recovery keys:

  ```sh
  kubectl --namespace openbao get secret openbao-seal-2 --output json |
    jq '{seal: {secret: .metadata.name, key_id: .metadata.name, key: (.data.key | @base64d)}}' |
    age --encrypt --recipient "$(yq '.creation_rules[0].age' talos/.sops.yaml)" --output <new file>
  ```

- **The recovery keys** rotate with three of the current shares, as the role `operator`, in a member's
  shell as above: `bao operator rotate-keys -target=recovery -init -verify`, then
  `bao operator rotate-keys -target=recovery -nonce=<nonce>` with one current share at each of three
  prompts. It prints the new shares; they go, with the seal key, into a new file encrypted to the
  Talos age key as `just bao-recovery` writes it, and each new share is entered once with
  `bao operator rotate-keys -target=recovery -verify -nonce=<nonce>` to commit them
  ([rotate-keys](https://openbao.org/docs/commands/operator/rotate-keys/)).
