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
    Then the build holds no Secret, no Job and no token, the initial configuration uses the root token only implicitly, generates no recovery key and writes nothing out of OpenBao, nothing names the recovery key or root token endpoints, and only the operator role may make a root token again, which takes a threshold of the recovery keys

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
    Then the store logs in through the Kubernetes auth method as a service account of its own, with the audience OpenBao checks, and the role's only policy reads and lists the key-value mount the store names and grants nothing else

  Scenario: The demo ExternalSecret resolves through the store in the build
    Given the hello-secret application, the store and OpenBao's initial configuration
    When the ExternalSecret is followed to the store, the mount and the policy
    Then it names the ClusterSecretStore the build makes, a key under the mount the store reads that bao-put can write, and the role the store logs in with may read that key

  Scenario: Every OpenBao pod meets the restricted Pod Security level its namespace enforces
    Given the openbao namespace and the rendered chart, its test pod included
    When the namespace's labels and the pod templates are read
    Then the namespace enforces the restricted level, and no pod template uses a host namespace, port or path, allows privilege escalation, runs as root, runs without the runtime's seccomp profile or keeps a capability

  Scenario: Only the first member initialises OpenBao, and only while no other member answers
    Given the script that decides each server's arguments, from the built application, and a fake bao
    When it runs as each member, with no other member answering, and with another member answering
    Then only openbao-0 with no other member answering adds the initial configuration, and every other run adds nothing

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
    Then the file decrypts with the Talos age key to the recovery key shares and the seal key, the rotation is committed only after the file is written, nothing of either is printed or passed on a command line, and a second run, a run against existing recovery keys, a path inside the repository or an existing file is refused
