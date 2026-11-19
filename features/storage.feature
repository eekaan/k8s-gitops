Feature: Storage
  A PersistentVolumeClaim gets a volume from Git alone: LINSTOR, run by the Piraeus operator under Flux on the workers' data volumes, replicates it on two workers by default, keeps it on the pod's node on request, and takes snapshots of it. LINSTOR's controller takes an API request only from a caller that presents a certificate the storage cluster's own API authority signed, which the operator issues to itself and to each of its components that calls the API, and keeps serving its metrics to the scrape. The satellites run in their node's network namespace, so DRBD replicates between the nodes' own addresses, which every node's firewall admits, on connections that stay up while a satellite pod is replaced.

  One scenario needs a docker daemon, which the CI containers do not have: "The pinned LINSTOR controller refuses an API request without its authority's client certificate and keeps serving its metrics". Its proof runs the controller from the image the pinned chart's image list names, without network, without a capability, as a user that is not root and on a read-only root, with the configuration the operator writes for it, and removes the container with what it made. It runs with the other proofs of tests/storage.bats wherever a docker daemon answers, on a developer's machine or an agent's, and skips, saying why, where none does, as under just ci and in CI, which run every other proof.

  Scenario: The storage applications are enabled and wait for what they need
    Given the cluster's overlay
    When it is built as Flux applies it
    Then it enables snapshot-controller, piraeus-operator and linstor-cluster, each builds with Flux's strict substitution, the first two are Ready only once what they install is, linstor-cluster waits for both and for cert-manager, whose issuers sign its certificates, and is Ready only once the operator reports the storage cluster Available and every satellite configuration Applied, and the namespace admits the satellites' privileged pods

  Scenario: The storage cluster's Kustomization waits long enough for a first install
    Given the cluster's overlay
    When it is built as Flux applies it
    Then linstor-cluster carries the long-timeout label, so the root gives it the long timeout instead of the default one, which the storage controller may exceed before it reports Available on a first install

  Scenario: Satellites run with the Talos settings, on the workers only
    Given the operator's satellite DaemonSet at the version the pinned chart runs, and the nodes' machine configurations rendered offline
    When the satellite configuration is applied to it as the operator applies it
    Then no init container loads a kernel module or installs the shutdown guard, no systemd path is mounted, LVM's configuration comes from the ConfigMap that keeps backups and archives, written under /var/etc/lvm, and LINSTOR runs only on nodes without the control-plane role label, which Talos gives every control plane and no worker, without naming a node

  Scenario: Satellites run in their node's network namespace and register the node's address
    Given linstor-cluster as Flux applies it, and the operator's satellite DaemonSet and source at the version the pinned chart runs
    When every satellite configuration is applied to the DaemonSet as the operator applies it
    Then the satellite's pod is on the host network and keeps the default DNS policy, set by one configuration that selects every satellite and sets nothing else, no container of the pod names the controller's address or a cluster name, and the operator at that version registers each node's interface default-ipv4 from the ready pod's addresses, which on the host network are the node's own, modifying an existing interface of that name in place and deleting neither it nor the node

  Scenario: Every node admits the satellites, DRBD's replication and the DRBD reactor from those who use them
    Given the satellite's pod as the operator's DaemonSet at the version the pinned chart runs and every satellite configuration of linstor-cluster make it, the nodes' firewall inventory, and linstor-cluster as Flux applies it
    When the ports the pod declares and LINSTOR's DRBD port range are read
    Then each port the pod's containers and init containers declare, LINSTOR's satellite port 3366 and the DRBD reactor's 9942, is admitted by exactly one rule of the inventory, a TCP rule every node has, over 3366-3367 for the satellite, as the operator registers a satellite on either, and over 9942 alone for the reactor, that accepts the nodes' own addresses and the pod range and nothing else; LINSTOR's default DRBD port range, 7000-7999, is the ports of exactly one rule, a TCP rule every node has that accepts the nodes' own addresses alone, and no other TCP rule admits a port of it; and no file under kubernetes/ sets TcpPortAutoRange or PrefNic, so nothing in the tree moves LINSTOR's range or its choice of interface

  Scenario: Each worker's data device is an LVM-thin storage pool
    Given the satellite configuration and the workers' machine configurations rendered offline
    When the storage pool is read
    Then every satellite gets one LVM-thin pool, created from the device Talos links for the workers' raw data volume, and every StorageClass of LINSTOR places volumes in it

  Scenario: The default StorageClass replicates a volume on two workers
    Given every StorageClass the cluster's applications apply
    When they are read
    Then exactly one is the default, and it is LINSTOR's, places two replicas with DRBD, is reachable from every node, binds once a pod is scheduled, allows expansion, formats XFS and suspends I/O when quorum is lost

  Scenario: The node-local StorageClass keeps one replica on the consumer's node
    Given the StorageClasses of LINSTOR
    When the one that is not the default is read
    Then it places one replica on the storage layer alone, binds once a pod is scheduled, which puts the replica on that pod's node, and allows no access from another node

  Scenario: Snapshots are taken by LINSTOR's driver through the upstream snapshot controller
    Given the snapshot-controller application's pinned source and the cluster's VolumeSnapshotClasses
    When the source is built offline as its Kustomizations apply it
    Then it yields the snapshot.storage.k8s.io definitions and, once they are established, the snapshot controller in kube-system, and the one VolumeSnapshotClass, the default, names LINSTOR's driver and deletes a snapshot with its object

  Scenario: No update of the Piraeus operator or the storage cluster merges itself
    Given Renovate's rules of what merges itself and the record of what it extracts
    When the rules after the auto-merge switch and the files Renovate reads the operator's chart from are read
    Then one rule after the switch, so that it wins over it whatever the switch says, holds back every file under kubernetes/apps/base/piraeus-datastore/ and holds nothing that narrows what it matches, no rule after the switch turns merging on again, and every pin of the operator's chart that Renovate reads is in one of those files

  Scenario: The storage resource definitions are never deleted with their applications
    Given the pinned operator chart rendered with the repository's values, and the snapshot-controller application
    When their objects and Kustomizations are read
    Then no application applies a definition itself, Helm keeps every definition of the operator's release, and the snapshot definitions are neither pruned nor deleted with their Kustomization

  Scenario: Only holders of a certificate from the storage cluster's API authority call LINSTOR's API
    Given linstor-cluster as Flux applies it and the operator's source at the version the pinned chart runs
    When the storage cluster's TLS settings and the issuers they name are read
    Then apiTLS names by cert-manager an Issuer of the same build in the operator's namespace, of kind CA, signing from the Secret of an isCA Certificate that the build's self-signed Issuer issues, which signs authorities alone, with no Secret name or CA reference overridden, linstor-cluster names cert-manager in dependsOn, and every component of the operator that dials the controller, the operator itself and the CLI in the controller's pod included, gets a client certificate from that issuer and dials HTTPS at a name the API's certificate holds

  Scenario: The pinned LINSTOR controller refuses an API request without its authority's client certificate and keeps serving its metrics
    Given the controller image the pinned chart's image list names, and the HTTPS and client configuration the operator writes for apiTLS at the version the chart runs
    When the controller runs offline as its pod runs it, with its certificates made as the build's issuers make them, and is called from inside its container
    Then over HTTPS a request without a client certificate, or with one another authority of the same name signed, fails the handshake, and one with the API authority's answers the version; over plain HTTP a request for the API answers no version and is redirected to the HTTPS port, and one that would create a resource definition creates none, while the metrics answer with LINSTOR's series and the health check answers 200; and the CLI in the container reaches the API with the client configuration the operator writes
