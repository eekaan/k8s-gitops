# 0013 — OpenBao unseals itself, and the operator keeps the recovery keys

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
- **Initialisation**: OpenBao initialises itself, once, on empty storage, from initialize stanzas
  in its configuration (self-initialisation): the Kubernetes auth method, the key-value mount
  `secrets/`, the roles and policies of External Secrets and of the operator, and autopilot's
  settings. Only the first member reads them, and only while no other member answers. OpenBao
  revokes the root token it initialised with as soon as the stanzas have run, and never returns
  it; no root token is stored anywhere.
- **Recovery material**: self-initialisation makes no recovery keys. `just bao-recovery <file>`
  makes them once, through OpenBao's authenticated rotation, logged in as the operator role: five
  shares, three of which restore access. It writes them, with a copy of the seal key, to a new
  file outside the repository, encrypted with age to the Talos age key's recipient, the operator's
  key that the cluster does not hold, and has OpenBao commit the shares only once the file is
  written. The shares are never printed, logged in the clear or stored in the cluster. The file is
  the operator's to keep outside the cluster. An encrypted file rather than the terminal: nothing
  lands in scrollback or a terminal log, and the file goes where the operator keeps the Talos age
  key's other material.
- **Operator access**: the operator authenticates with a ten-minute token for the service account
  `openbao-operator`, minted through the Kubernetes API, as OpenBao's role `operator`, which may
  write to the key-value mount and make the recovery keys, and read nothing. Minting it takes the
  right to create `serviceaccounts/token` for that account.

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
- Changing a role, policy or mount after the first start is a request made with OpenBao's API, as
  the initial configuration never runs again on initialised storage.
- Snapshots of OpenBao's storage to object storage (ADR 0008) come later; restoring one needs the
  seal key it was taken under, which the operator's file holds.
