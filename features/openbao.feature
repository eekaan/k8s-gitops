Feature: OpenBao
  Runtime secrets live in OpenBao, which Flux runs as a three-member raft cluster on the default StorageClass. It initialises itself once, unseals itself after every restart with a key the cluster holds, and External Secrets reads one key-value mount of it through a ClusterSecretStore; an operator writes a value into it from standard input (ADR 0005, ADR 0016).

  Scenario: OpenBao is enabled after what it needs, and the store and the demo after it
    Given the cluster's overlay
    When it is built as Flux applies it
    Then it enables the openbao namespace and the applications openbao, openbao-store and hello-secret, each builds with Flux's strict substitution, openbao waits for External Secrets, cert-manager, the storage cluster and the monitoring definitions and is Ready only once its release is, the store waits for OpenBao and is Ready only once the ClusterSecretStore is, and the demo waits for the store

  Scenario: OpenBao runs three raft members, one per worker, with a budget that keeps quorum
    Given the openbao application, built as Flux applies it, and its pinned chart rendered with the repository's values
    When the StatefulSet, its disruption budget, its claims and the server configuration are read
    Then three members run raft storage that joins each of them, no two on one node and none on a control plane, a disruption budget lets one of the three be unavailable, and each keeps its data on a claim of the default StorageClass that names no class

  Scenario: OpenBao keeps quorum through a node drain by its settings
    Given the rendered chart and OpenBao's initial configuration
    When the settings that decide what a drain does are read
    Then a drain can evict one member at a time, a member is Ready only while it is unsealed, an evicted member keeps its claim, rejoins any member and unseals itself, autopilot never removes a member that is away, and a new release replaces one member at a time

  Scenario: The seal key comes from a Secret that nothing in the repository holds and nothing regenerates
    Given the openbao application built as Flux applies it, the rendered chart and the files git tracks
    When the seal stanza, the mounts and the objects that make the seal Secret are read
    Then OpenBao unseals with the static seal from a file of a Secret mounted into its servers only, an External Secrets generator makes that Secret once and never again, leaves it in place when it is deleted and cannot change its key, and no file in the repository holds a Secret of that name or a key in the seal stanza

  Scenario: No root token and no recovery material is stored by anything the build renders
    Given the openbao application built as Flux applies it and its rendered chart
    When every object, the server configuration and the initial configuration are read
    Then the build holds no Secret, no Job and no token, the initial configuration uses the root token only implicitly, generates no recovery key and writes nothing out of OpenBao, nothing names the recovery key or root token endpoints, only the operator role may make a root token again, which takes a threshold of the recovery keys, nothing logs at trace or debug level, and no audit device writes values or accessors in the clear

  Scenario: OpenBao runs without its injector, its CSI provider or an exposed UI
    Given the rendered chart
    When its objects and the server configuration are read
    Then there is no injector, no webhook, no CSI provider, no UI Service, no Ingress or route, every Service is internal to the cluster and the UI is off

  Scenario: OpenBao serves TLS from a CA of its own, which the store and the monitor verify
    Given the openbao and openbao-store applications built as Flux applies them and the rendered chart
    When the certificates, the listener, the ClusterSecretStore and the ServiceMonitor are read
    Then a self-signed CA in the openbao namespace issues the listener's certificate for every name the servers and their clients use, the listener reloads it when it is renewed, and the store, the servers and the monitor all verify it against that CA

  Scenario: OpenBao is scraped through the chart's ServiceMonitor
    Given the rendered chart and the openbao application's Kustomization
    When its monitors are read
    Then exactly one ServiceMonitor scrapes the active member's Service at the metrics path without a credential, which the listener allows, and the application waits for the monitoring definitions

  Scenario: The ClusterSecretStore reads one key-value mount and nothing else
    Given the openbao-store application and OpenBao's initial configuration
    When the store, the role it logs in with and that role's policy are read
    Then the store logs in through the Kubernetes auth method as a service account of its own, with the audience OpenBao checks, the role carries no default policy, its only policy reads and lists the key-value mount the store names and lets the token look itself up and revoke itself, as External Secrets does, and nothing writes the default policy or binds the store's account to another role

  Scenario: Each OpenBao role binds one account to one policy, without OpenBao's default policy
    Given OpenBao's initial configuration and the openbao application built as Flux applies it
    When its roles, their policies and the application's service accounts are read
    Then external-secrets binds openbao-store, operator binds openbao-operator and snapshot binds openbao-snapshot, each with OpenBao's audience, one policy, no default policy and ten-minute tokens, the snapshot role may only take a raft snapshot, and no pod mounts the accounts' tokens

  Scenario: The operator role allows every request its recipes and runbook make, and nothing more
    Given the operator role's policy, the requests the recipes send with the operator's token read from their scripts, and the requests of the runbook's CLI steps
    When each request is read as the capability OpenBao checks for it
    Then the policy grants each of them and nothing beyond them, and the only requests a recipe sends with another token are bao-root's with the root token, looking it up for its accessor and minting the command's token

  Scenario: External Secrets mints tokens for the store's account and no other
    Given the external-secrets application's chart rendered with the repository's values, and the openbao-store application
    When the roles that let a subject create service account tokens, and their bindings, are read
    Then the chart grants that to no one, and the store's application lets External Secrets' controller create tokens for openbao-store alone, in the namespace where External Secrets requests a ClusterSecretStore's token

  Scenario: The demo ExternalSecret resolves through the store in the build
    Given the hello-secret application, the store and OpenBao's initial configuration
    When the ExternalSecret is followed to the store, the mount and the policy
    Then it names the ClusterSecretStore the build makes, a key under the mount the store reads that bao-put can write, and the role the store logs in with may read that key

  Scenario: Every OpenBao pod meets the restricted Pod Security level its namespace enforces
    Given the openbao namespace and the rendered chart, its test pod included
    When the namespace's labels and the pod templates are read
    Then the namespace enforces the restricted level, and no pod template uses a host namespace, port or path, allows privilege escalation, runs as root, runs without the runtime's seccomp profile or keeps a capability

  Scenario: Only the first member initialises OpenBao, and only on a first install
    Given the guard each member's init container runs, from the built application, the rendered StatefulSet and a fake Kubernetes API
    When it runs as each member, with data of its own or none, while the API times out, refuses, errs, or answers with the other members' claims present or absent
    Then only openbao-0, with no data of its own and neither data-openbao-1 nor data-openbao-2 existing, adds the initial configuration to the server's arguments; every other run adds nothing, a run without an answer fails so the pod does not start, and the guard may read those two claims and nothing else

  Scenario: bao-put never puts the value on a command line or in its output
    Given a fake cluster and a fake OpenBao behind a port-forward
    When bao-put writes a value read from standard input, to a path that exists and to one that does not
    Then the value reaches OpenBao only in a request body read from standard input, no command line and no output holds it or the tokens, OpenBao is reached over TLS verified against its CA with a short-lived operator token, which is revoked, and an existing path keeps its other keys

  Scenario: bao-put and bao-recovery close their port-forward on every exit path
    Given a fake cluster whose port-forward keeps running until it is stopped
    When bao-put and bao-recovery succeed, fail at login, fail at the write, and are interrupted
    Then no port-forward is left running after any of them

  Scenario: bao-put refuses without a path and a key
    Given a fake cluster
    When bao-put runs without arguments, with a path only, with a path or key that is not a plain key-value name, with a third argument such as the value, or with no value on standard input
    Then it exits non-zero naming the problem without echoing what it was given, and reaches neither the cluster nor OpenBao

  Scenario: bao-recovery hands out the recovery keys once, encrypted to the operator's age key
    Given a fake OpenBao that has no recovery keys yet, and the Talos age key's recipient
    When bao-recovery writes the recovery keys to a file outside the repository
    Then the file decrypts with the Talos age key to the recovery key shares and the seal key, the rotation is committed only after the file is written and proved to decrypt, nothing of either is printed or passed on a command line, and a second run, a run against existing recovery keys, a path inside the repository or an existing file is refused

  Scenario: bao-recovery never commits recovery keys it did not keep
    Given a fake OpenBao that has no recovery keys yet
    When bao-recovery is interrupted while the keys are verified, before and after OpenBao commits them, finds a rotation left in progress, finds its file made by someone else, or writes to a recipient the operator's age key does not open
    Then a rotation it did not complete is cancelled and its file removed, a file holding committed keys is kept, a rotation left in progress is cancelled before a new one starts, a file made by someone else is never replaced, and keys the operator's age key cannot read are never committed

  Scenario: bao-root runs one command with a fifteen-minute token made from the recovery keys, and revokes it
    Given a fake OpenBao holding recovery keys, answering as OpenBao does, and the operator's custody file
    When bao-root runs a command, the command is killed, the recipe is interrupted while it runs, minting the command's token is refused, a share is refused, the root token's lookup fails, and revoking the root token, then the command's token, fails
    Then the shares reach OpenBao only in request bodies read from standard input, the root token made from them is first looked up for its accessor, mints a fifteen-minute orphan token with the root policy and is revoked before the command runs, the command gets that token, the address and the CA in its environment, the token is revoked however the command ends, so is the operator's, a token OpenBao does not revoke is named by its accessor with the step that revokes it and the recipe fails even when the command succeeded, no command runs while the root token lives, nothing prints a share or a token, an unfinished generation is cancelled, and the port-forward is closed

  Scenario: bao-seal-restore writes the seal key back from the custody file and never replaces a key unasked
    Given a fake cluster without the seal Secret, with it holding the file's key, and with it holding another key
    When bao-seal-restore runs, and runs with --replace
    Then a missing Secret is made immutable from the file's key, one holding the same key is left alone, one holding another key is kept unless --replace is given, a key it replaces is first kept in a new file beside the custody file, encrypted to and opened with the operator's age key, never over another file, nothing is deleted when it cannot be kept, and no key is printed or passed on a command line
