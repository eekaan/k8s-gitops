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
    When it runs as each member, with data of its own or none, while the API times out, refuses, errs, does not answer in time, or answers with the other members' claims present or absent
    Then only openbao-0, with no data of its own and neither data-openbao-1 nor data-openbao-2 existing, adds the initial configuration to the server's arguments; every other run adds nothing, a run without an answer in time fails so the pod does not start, the guard reaches the API through the pod's in-cluster configuration, as its kubectl call carries no flag and it has no kubeconfig that would replace that configuration, and it may read those two claims and nothing else

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
    Then the file decrypts with the Talos age key to the recovery key shares and the seal key, the rotation is committed only after the file is written and proved to decrypt, nothing of either is printed or passed on a command line, and a second run, a run against existing recovery keys, a path inside the repository, an existing file or a directory others can write is refused

  Scenario: bao-recovery never commits recovery keys it did not keep
    Given a fake OpenBao that has no recovery keys yet
    When bao-recovery is interrupted while the keys are verified, before and after OpenBao commits them, finds a rotation left in progress, finds its file made by someone else, can make no hard link to its file, is interrupted right after the link is made, or writes to a recipient the operator's age key does not open
    Then a rotation it did not complete is cancelled and its file removed, linked in place or not, as the run says, a file holding committed keys is kept, a rotation left in progress is cancelled before a new one starts, a file made by someone else is never replaced, a file it can make no hard link to is put in place no other way and ln's own error says why, and keys the operator's age key cannot read are never committed

  Scenario: bao-root runs one command with a fifteen-minute token made from the recovery keys, and revokes it
    Given a fake OpenBao holding recovery keys, answering as OpenBao does, and the operator's custody file
    When bao-root runs a command, the command is killed, the recipe is interrupted while it runs, minting the command's token is refused, a share is refused, the root token's lookup fails, and revoking the root token, then the command's token, fails
    Then the shares reach OpenBao only in request bodies read from standard input, the root token made from them is first looked up for its accessor, mints a fifteen-minute orphan token with the root policy and is revoked before the command runs, the command gets that token, the address and the CA in its environment and no BASH_ENV or ENV, the token is revoked however the command ends, so is the operator's, a token OpenBao does not revoke is named by its accessor with the step that revokes it and the recipe fails even when the command succeeded, no command runs while the root token lives, nothing prints a share or a token, an unfinished generation is cancelled, and the port-forward is closed

  Scenario: bao-seal-restore writes the seal key back from the custody file and never replaces a key unasked
    Given a fake cluster without the seal Secret, with it holding the file's key, and with it holding another key
    When bao-seal-restore runs, and runs with --replace
    Then a missing Secret is made immutable from the file's key, one holding the same key is left alone, one holding another key is kept unless --replace is given, a key it replaces is first kept in a new file beside the custody file, encrypted to and opened with the operator's age key, never over another file, nothing is deleted when it cannot be kept, as when no hard link to that file can be made, which ln's own error says, and no key is printed or passed on a command line

  Scenario: Seeding writes the master to the custody file, checks it opens, and only then writes the store's key
    Given a fake cluster and a fake OpenBao that hold no key volsync and answer the operator's token as OpenBao does, the cluster's S3 key in the environment, and the Talos age key's recipient
    When bao-seed-volsync writes its custody file outside the repository, again, and again when the recipient is one the operator's age key does not open, the file opens to something else than was written, or no hard link to the file can be made
    Then the file decrypts with the Talos age key to a master that is the 32 bytes head read once from /dev/urandom, as 64 hexadecimal digits, and nothing else, a second seeding makes another master, the store's key holds that master and the cluster's S3 key and nothing else, it is created only if a patch of no data with check-and-set 0 found none and only once the file is in place and opened again to what was written, a file the operator's key cannot open or that opens to other content is removed with its partial file and the store is never written, a file it can make no hard link to is put in place no other way, ln's own error says why and the store is never written, and OpenBao is reached over TLS verified against its CA with a token that is revoked, through a port-forward that is closed

  Scenario: A store that already holds the key is not seeded again, and its master is never replaced
    Given a fake OpenBao that holds the key volsync and refuses the operator's token a write to it, and the custody file of the run that wrote it
    When bao-seed-volsync runs with that file, with a new file, with a file that is no custody file of its own, with another cluster's custody file, with a path inside the repository, and with --rotate-s3, with another flag for the master, and where no key exists to rotate; and where the store holds no key, when asking whether it exists is refused for another reason or never reaches OpenBao, and when someone makes the file at its path while it runs
    Then the store says it holds the key and is left as it was, no write is sent to it, the custody file stays as it was, no file is made for a store that holds a key, a file that exists is never replaced, --rotate-s3 replaces the S3 key properties and not the master, no flag replaces the master, a question refused for another reason says that reason and not that the store holds the key and makes nothing, and a file made at its path while it runs is never replaced, no partial file is left and the store is not written

  Scenario: A run interrupted between the file and the store goes on from the file
    Given a fake OpenBao that holds no key volsync, and bao-seed-volsync interrupted as it writes the key or right after it puts the file in place, or refused by OpenBao
    When the recipe runs again with the same file
    Then the first run says which state it left, the file holding the master and the store holding none, and that the next run goes on from the file, and the next run writes the master the file holds, makes no other master and leaves the file as it was

  Scenario: A rebuilt store is seeded from the existing custody file, never with a new master
    Given the custody file of a seeding, and a fake OpenBao that holds no key volsync, as the store of a rebuilt cluster, and the cluster's S3 key in the environment
    When bao-seed-volsync runs with that file, without a file, and with a new file given by mistake, and the runbook's way back runs: bao-root deleting the key's metadata, then bao-seed-volsync with the existing file
    Then the store's key holds the master the file holds and the cluster's S3 key, created only as the patch of no data with check-and-set 0 found no key, no master is made, the file is left as it was, the recipe says it wrote the file's master and prints neither, and the port-forward is closed; the usage, and the last line of the seeding that makes a new master, say that a store that held the key before takes the existing file; and the root-policy token bao-root mints deletes the key's metadata, which the operator's token may not, after which the store holds the existing file's master again

  Scenario: An S3 key variable that is empty or a placeholder stops the recipe before anything is generated
    Given the environment the cluster recipes load, with each of the cluster's S3 key variables empty, unset, a placeholder, or the state key's
    When bao-seed-volsync runs
    Then it names the variable and not its value, and no file is made and neither the cluster nor OpenBao is reached

  Scenario: Nothing of the master or the S3 key is printed, passed as an argument or written unencrypted
    Given a fake cluster and a fake OpenBao, and recording fakes of every command the recipes run but the shell
    When bao-seed-volsync seeds, rotates, runs again, is refused by OpenBao and is interrupted
    Then no output, command line or file but the encrypted custody file holds the master or the S3 key, files the recipe removed or replaced and its private directory included, the recipe runs every command by its name and none as a shell, so each command line is in the record, every output redirection of the seeding scripts and their library goes to /dev/null, a file descriptor or a file that holds no secret and the one file they have a tool write is age's encrypted partial file, and the master and the key travel only in the body of the write that creates the key

  Scenario: One application's repository password is derived from the custody file without printing it
    Given the custody file bao-seed-volsync wrote
    When bao-volsync-password runs a command for an application, for another application, without a command, with a name that is no application's, with another custody file and with a file that is missing
    Then the command gets the application's repository, the SHA-256 digest of the master, a slash and the application's name as its password, and the cluster's S3 key, in its environment, no other secret of the environment reaches the command, neither the Talos age key's location, the cluster's key under its own names, the state key, its passphrase nor the cloud credential, nor a BASH_ENV or ENV, the other application's password differs, nothing is printed or passed on a command line, neither the cluster nor OpenBao is reached, every refusal runs no command, and the command's status is the recipe's

  Scenario: A custody file is read only where no one but the operator can have written it
    Given the custody file of a seeding, a fake OpenBao that holds no key volsync, and the custody file of the recovery keys
    When bao-seed-volsync goes on from the file while it is writable by its group or others, owned by another user, in a directory writable by its group or another user's, under a directory writable by others with and without the sticky bit, or given as a symbolic link, writes a new file into a directory its group can write, and bao-volsync-password, bao-root and bao-seal-restore read a file writable by its group or a symbolic link
    Then each refuses before it reaches the cluster or OpenBao, naming the file or directory and why, nothing is written to the store or the shared directory and no command runs, and the file under a directory others can write but whose sticky bit is set is read and seeds the store

  Scenario: A recipe refuses to run while the shell traces its commands
    Given the environment the cluster recipes load, the custody files and a fake cluster
    When each of bao-put, bao-recovery, bao-root, bao-seal-restore, bao-seed-volsync and bao-volsync-password runs with SHELLOPTS=xtrace, with SHELLOPTS=xtrace and the tests' trace directory named, with a BASH_ENV that sets -x, and under bash -x
    Then each refuses, saying the shell traces each command, before it reads a secret, opens a custody file or reaches the cluster or OpenBao, no secret of the environment, the custody files or standard input is printed, and the tests' own trace into a file of theirs still lets a recipe run

  Scenario: What the recipes print of OpenBao's and kubectl's errors holds no control character and no address
    Given a fake OpenBao whose error text holds terminal escape sequences, and a fake kubectl that cannot reach the API server and names its address with control characters
    When bao-seed-volsync and bao-put run
    Then OpenBao's error is printed with each control character as a question mark, and kubectl's error says why without the address or a control character
