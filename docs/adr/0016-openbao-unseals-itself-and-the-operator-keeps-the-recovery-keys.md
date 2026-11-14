# 0016 — OpenBao unseals itself, and the operator keeps the recovery keys

- Status: accepted
- Date: 2026-11-14

## Context

ADR 0005 keeps runtime secrets in OpenBao inside the cluster. OpenBao encrypts its storage with a
keyring that a root key protects, and the root key is sealed: after every start OpenBao has to be
unsealed before it serves anything. The cluster must come back by itself after a node reboots or a
pod moves, without a person at hand. Initialising OpenBao returns a root token, which can do
anything, and recovery material, which can make a new root token; neither may be left where the
cluster or the repository holds it. The cloud offers no key management service that OpenBao has a
seal for.

## Decision

- **Seal**: OpenBao's static seal, an auto-unseal mechanism built into OpenBao that reads a 32-byte
  AES-256 key from a file. The key lives in the cluster only, in the Secret `openbao-seal-1` in the
  `openbao` namespace, mounted into the servers alone. External Secrets makes it once, from its
  `Password` generator, through an ExternalSecret that syncs only when it is created
  (`refreshPolicy: CreatedOnce`), leaves the Secret without an owner (`creationPolicy: Orphan`) and
  marks it immutable. Nothing syncs it again, nothing changes it, and deleting the ExternalSecret
  or the application leaves it in place. It is never committed, encrypted or otherwise.
- **Initialisation**: OpenBao initialises itself, once, on a first install, from initialize stanzas
  in its configuration (self-initialisation): the Kubernetes auth method, the key-value mount
  `secrets/`, the roles and policies of External Secrets, of the operator and of the snapshot job
  to come, and autopilot's settings. Only the first member reads them, and only on positive
  evidence of a first install: its own storage is empty, and the Kubernetes API answers that
  neither other member's claim exists. Without that answer it does not start, so an empty member
  never starts a second store beside the first. OpenBao revokes the root token it initialised with
  as soon as the stanzas have run, and never returns it; no root token is stored anywhere.
- **Recovery material**: self-initialisation makes no recovery keys. `just bao-recovery <file>`
  makes them once, through OpenBao's authenticated rotation, logged in as the operator role: five
  shares, three of which restore access. It runs right after the first reconcile, before anything
  else logs in as that role. It writes them, with a copy of the seal key, to a new file outside
  the repository, encrypted with age to the Talos age key's recipient, the operator's key that the
  cluster does not hold, opens the file again with that key, and has OpenBao commit the shares only
  then. The shares are never printed, logged in the clear or stored in the cluster. The file is the
  operator's to keep outside the cluster. An encrypted file rather than the terminal: nothing lands
  in scrollback or a terminal log, and the file goes where the operator keeps the Talos age key's
  other material. `just bao-root` turns three of the shares into a short-lived root token for one
  command, and `just bao-seal-restore` writes the seal key back from the file.
- **Who may do what**: each role binds one service account, checks the audience `openbao`, carries
  one policy and not OpenBao's `default` policy, and gives ten-minute tokens.
  - `external-secrets`, for `openbao-store` in `external-secrets`: reads and lists every key of the
    mount, and looks up and revokes its own token, as External Secrets does.
  - `operator`, for `openbao-operator` in `openbao`: creates keys of the mount and changes them,
    never reads them; makes the recovery keys while none exist, and rotates them with a threshold
    of the current shares; starts a root token generation, which completes only with a threshold of
    the shares; revokes its own token.
  - `snapshot`, for `openbao-snapshot` in `openbao`: takes a snapshot of the raft storage. No job
    uses it yet.
- **Who may mint which token**: a token for one of these accounts is minted through the Kubernetes
  API by a subject allowed to create `serviceaccounts/token` for it. External Secrets' controller
  may for `openbao-store` alone, through a Role that names it; its chart's grant to create every
  account's token is off. For `openbao-operator` and `openbao-snapshot` that is cluster
  administrators and Flux, which hold cluster-admin.

## Alternatives considered

- **Shamir's seal, unsealed by hand with key shares.** No key in the cluster, but every restart of
  every member waits for a person to unseal it, so a node reboot takes the secrets away until then.
- **A cloud key management service.** The key never sits in the cluster, but the cloud offers none
  that OpenBao can use, and the cluster would need a cloud credential to reach it.
- **Transit unseal from a second OpenBao.** The key sits in another OpenBao, which has to run, be
  unsealed and be reached before this one starts: the same problem one level down.
- **The seal key as SOPS-encrypted bootstrap material.** It would survive the cluster's loss with
  the repository, but its ciphertext would be public for good, and a key the generator makes in the
  cluster needs no step before Flux.
- **`bao operator init` run by a recipe.** It returns the root token and the recovery keys at once,
  so a setup script holds a root token, and the mounts, roles and policies need a privileged
  script; self-initialisation does the same declaratively and keeps no token.

## Consequences

- The seal key protects OpenBao's storage, and copies of it such as its volumes and their
  snapshots, read outside the cluster. It does not protect against anyone who can read Secrets in
  the `openbao` namespace or the cluster's etcd, whose snapshots hold it: they hold the key and
  the storage it opens. Reading Secrets there is a cluster administrator's right.
- Losing the Secret while the volumes remain leaves the data sealed; the operator's file or an etcd
  snapshot gives the key back. Losing it with no copy loses every runtime secret.
- The recovery keys are what restores privileged access when the operator role or its policies are
  broken: a threshold of them makes a short-lived root token. Losing them loses that way back, not
  the data, which stays readable through the roles that work.
- The `operator` role reaches a root token through the recovery keys: before `bao-recovery` has run,
  whoever first asks receives new recovery keys, and afterwards a root token takes a threshold of
  the shares the operator's file holds. Only a subject with cluster-admin may mint an `operator`
  token, and such a subject reads the seal Secret and every Secret the store fills anyway. If
  `bao-recovery`'s first run finds recovery keys already, someone else holds them, and the store is
  rebuilt before it holds a secret.
- Changing a role, policy or mount after the first start takes a root token from the recovery keys,
  as the initial configuration never runs again on initialised storage. A first initialisation
  that fails part way leaves a mark on storage after which OpenBao refuses to unseal, and is started
  again from nothing.
- An empty first member after a full restart waits for the others, which start only once it is
  Ready, so the store stays down until an operator lets the others start first: the price of never
  running a second store.
- Snapshots of OpenBao's storage to object storage (ADR 0008) come later, as their job needs the
  object storage's key from this store; the role it logs in as exists. Restoring one needs the seal
  key it was taken under, which the operator's file holds.
