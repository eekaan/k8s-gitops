Feature: Storage
  A PersistentVolumeClaim gets a volume from Git alone: LINSTOR, run by the Piraeus operator under Flux on the workers' data volumes, replicates it on two workers by default, keeps it on the pod's node on request, and takes snapshots of it.

  Scenario: The storage applications are enabled and wait for what they need
    Given the cluster's overlay
    When it is built as Flux applies it
    Then it enables snapshot-controller, piraeus-operator and linstor-cluster, each builds with Flux's strict substitution, the first two are Ready only once what they install is, linstor-cluster waits for both and is Ready only once the operator reports the storage cluster Available and every satellite configuration Applied, and the namespace admits the satellites' privileged pods

  Scenario: Satellites run with the Talos settings, on the workers only
    Given the operator's satellite DaemonSet at the version the pinned chart runs, and the nodes' machine configurations rendered offline
    When the satellite configuration is applied to it as the operator applies it
    Then no init container loads a kernel module or installs the shutdown guard, no systemd path is mounted, LVM's configuration comes from the ConfigMap that keeps backups and archives, written under /var/etc/lvm, and LINSTOR runs only on nodes without the control-plane role label, which Talos gives every control plane and no worker, without naming a node

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

  Scenario: The storage resource definitions are never deleted with their applications
    Given the pinned operator chart rendered with the repository's values, and the snapshot-controller application
    When their objects and Kustomizations are read
    Then no application applies a definition itself, Helm keeps every definition of the operator's release, and the snapshot definitions are neither pruned nor deleted with their Kustomization
