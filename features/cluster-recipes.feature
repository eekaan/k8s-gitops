Feature: Cluster recipes
  The cluster is created and changed by recipes that check before they act.

  Scenario: The age key is created once and never printed
    Given SOPS_AGE_KEY_FILE naming a path outside the repository where no key exists
    When cluster-age-key runs, and then runs again
    Then the key file is created with mode 0600 and talos/.sops.yaml names its recipient, each run prints that recipient and nothing else, and the second run leaves the key and talos/.sops.yaml as they were

  Scenario: Cluster secrets are written encrypted and never regenerated
    Given the cluster's talman.yaml and talos/.sops.yaml naming the recipient of the Talos age key
    When cluster-secrets runs, and then runs again
    Then the first run writes talos/lab-sto2/secrets.sops.yaml with SOPS metadata and every value encrypted to that recipient, and the second exits non-zero without calling talman and leaves the file byte for byte as it was

  Scenario: Secrets written in plaintext fail the recipe and are kept
    Given a talman that writes the secrets bundle unencrypted
    When cluster-secrets runs
    Then it exits non-zero saying the bundle is not encrypted, leaves the file in place, and prints none of its values

  Scenario: A plaintext secrets bundle fails the check
    Given a Talos secrets bundle in plaintext at a secrets.sops.yaml under talos/ that git would commit
    When the secrets bundle check runs
    Then it exits non-zero naming the file and printing none of its values, while an encrypted bundle passes

  Scenario: Bootstrap refuses without its preconditions
    Given a cluster without its talman.yaml, its secrets.sops.yaml, the age key's location or an API address in KUBE_API_ADDRESS or talman.yaml
    When cluster-bootstrap runs
    Then it exits non-zero naming each one that is missing, and no node is probed and no tool is run

  Scenario: Bootstrap waits for every node and names the ones that do not answer
    Given six nodes in talman.yaml, one of which answers on the Talos API port at its third try
    When cluster-bootstrap runs, and runs again with two nodes that never answer
    Then the first run tries that node until it answers and only then runs talman, and the second exits non-zero once TALOS_WAIT has passed, naming the two nodes by hostname, without their addresses, and running no talman

  Scenario: Bootstrap applies, fetches the kubeconfig and installs Cilium in that order
    Given six nodes in maintenance mode that answer on the Talos API port
    When cluster-bootstrap runs, and then runs again
    Then talman apply bootstraps the cluster and onboards the nodes, talman fetches the kubeconfig, Cilium is installed through it and every node in talman.yaml is waited for until it is Ready, in that order and with no health check; the second run is refused by talman's bootstrap check and runs nothing after it

  Scenario: The kubeconfig is private and points at the API address from the environment
    Given KUBE_API_ADDRESS in the environment
    When cluster-kubeconfig runs
    Then talos/lab-sto2/clusterconfig/kubeconfig has mode 0600, every cluster in it is served at https://KUBE_API_ADDRESS:6443, and the recipe prints the file's path and neither its content nor the address

  Scenario: Without KUBE_API_ADDRESS the recipes reach the API at the address in talman.yaml
    Given the cluster's talman.yaml naming the load balancer's floating address in values.apiAddress, and no KUBE_API_ADDRESS
    When cluster-kubeconfig runs, and then runs with KUBE_API_ADDRESS set
    Then the first serves every cluster in the kubeconfig at that address on port 6443 and the second at KUBE_API_ADDRESS, and neither prints the address or passes it as an argument

  Scenario: A configuration rollout shows the change and asks before applying
    Given a configuration change talman reports for the cluster's nodes
    When cluster-talos runs and the cluster's name is not typed back
    Then it shows talman's dry run with the cluster's secrets redacted and applies nothing; with the name typed back, or with --yes, talman applies the change in one run with no health check; and with nothing to change it exits zero without asking or applying

  Scenario: New nodes are onboarded only when asked
    Given a node in maintenance mode beside a configuration change
    When cluster-talos runs, and then runs with --onboard
    Then without --onboard no talman call onboards new nodes and the node stays new, and with --onboard both the dry run and the apply onboard it

  Scenario: A rollout that changes etcd's arguments says which control planes need a reboot
    Given talman's dry run showing a change to cluster.etcd's extraArgs on cp-1 and cp-2, which etcd's configuration in Talos holds once each runs it, and one to machine.network only on worker-2
    When cluster-talos runs with --yes, and with --yes --first worker-2
    Then once the nodes keep the configuration it says that cp-1 and cp-2 run etcd as it was started until they reboot, names just cluster-reboot for each, one at a time, says nothing of worker-2, and reboots nothing

  Scenario: A rollout that changes only what applies at once says nothing about a reboot
    Given talman's dry run showing changes to machine.network only, and then to nothing in a reboot-only section
    When cluster-talos runs with --yes, and with --yes --reboot
    Then it says nothing about a reboot, calls no cluster-reboot and exits zero

  Scenario: With --reboot, the nodes that need one are rebooted one at a time, and the first that does not come back stops the rest
    Given talman's dry run showing a change to cluster.etcd's extraArgs on cp-1, cp-2 and cp-3
    When cluster-talos runs with --yes --reboot, with a cp-2 that does not come back, and with a cp-1 that is Ready again while its etcd member is not
    Then once the configuration is kept it runs cluster-reboot for cp-1, cp-2 and cp-3 in turn, each ended before the next starts, and without --reboot it reboots none; with the failing cp-2 it exits non-zero naming cp-2 and the nodes not rebooted, and cp-3 is not rebooted; with cp-1's member not back, cluster-reboot itself fails on it and neither cp-2 nor cp-3 is rebooted

  Scenario: A Talos upgrade drains through the Kubernetes API one node at a time
    Given talman reporting cp-2 and worker-1 behind the Talos version and schematic talman.yaml gives them
    When cluster-upgrade runs, without the cluster's name typed back and then with it
    Then the first shows talman's dry run and changes nothing; the second takes an etcd snapshot to the bucket, then for cp-2 and then worker-1 only drains the node with kubectl through the kubeconfig served at KUBE_API_ADDRESS, upgrades it with talman with talosctl's own drain off, waits for it to report Ready after the upgrade and uncordons it before the next is drained; with the API not answering nothing is drained, and with every node on its version it exits zero without asking

  Scenario: An upgrade does the same for each worker in turn, and never has two workers out at once
    Given talman reporting cp-2, worker-1 and worker-2 behind the Talos version
    When cluster-upgrade runs, and again with a worker whose upgrade fails
    Then each worker is labelled out of BGP, waited for until its BGP configuration is gone, drained, upgraded, uncordoned and put back, in that order, before the next worker is labelled; cp-2 is drained and upgraded with no BGP step; at most one worker is ever out; and the worker whose upgrade fails stays out, the last line saying so and how to put it back

  Scenario: An upgrade's etcd snapshot is uploaded encrypted and nothing is left on disk
    Given talman reporting nodes behind the Talos version and Kubernetes behind kubernetesVersion, and the etcd backup bucket
    When cluster-upgrade and cluster-upgrade-k8s run with the cluster's name typed back
    Then each takes its snapshot as cluster-snapshot does, before it touches any node, and asks talman for no snapshot of its own: the bucket holds one new object per run, which the Talos age key decrypts to what talman wrote, and no etcd snapshot is left in the cluster's clusterconfig/ or anywhere else on disk

  Scenario: A failed snapshot stops an upgrade before any node is touched
    Given talman failing once it has started the etcd snapshot, and an upload that fails
    When cluster-upgrade and cluster-upgrade-k8s run
    Then each exits non-zero naming the step it failed in; a failed upload shows the reason the S3 client gave, without the endpoint, bucket or keys it names, and a failed snapshot shows none of the S3 client's words; it drains, cordons, upgrades and uncordons nothing, and leaves nothing on disk

  Scenario: An upgrade waits for a Ready the node reports after it was upgraded
    Given a node whose Ready condition is the one from before its upgrade for some reads, and one whose kubelet never reports again
    When cluster-upgrade runs
    Then it uncordons the node only once its Ready condition is newer than the start of its upgrade, and for the node that never reports it exits non-zero naming it and uncordons nothing

  Scenario: A Kubernetes upgrade shows the change and asks before applying
    Given kubernetesVersion in talman.yaml ahead of what the kubelets run
    When cluster-upgrade-k8s runs, without the cluster's name typed back and then with it
    Then the first shows talman's dry run and upgrades nothing; the second takes an etcd snapshot to the bucket and then runs talman upgrade-k8s once, with the API reached at KUBE_API_ADDRESS, and then finds every node on the version; and with every node on it, it exits zero without asking or upgrading

  Scenario: The cluster recipes run their tools with only the secrets they use
    Given every secret variable set to a marker and recording fakes of talman, kubectl, age and the S3 client
    When cluster-kubeconfig and cluster-upgrade run, the latter with the cluster's name typed back
    Then talman gets the age key variables and none of the S3, cloud or state secrets, kubectl gets no secret, age gets the age key file's path only, and the S3 client gets the state key pair and no other secret

  Scenario: With CI set, talman's output stays out of the log
    Given a talman whose output names the nodes by address and shows configuration diffs
    When cluster-bootstrap, cluster-kubeconfig, cluster-talos, cluster-upgrade and cluster-upgrade-k8s run with CI set, and a talman call fails
    Then for each talman call they print only whether it succeeded or failed and the file under talos/lab-sto2/clusterconfig/, which git ignores, that holds its output, and no node address or diff is printed

  Scenario: No cluster secret reaches a command line or the output
    Given an age key, a secrets bundle and a kubeconfig whose secrets are known
    When every cluster recipe runs against recording tools, and in the ways each one stops, without and with CI set
    Then no secret appears in any recorded argument list or in anything the recipes print, and with CI set no node address is printed either
