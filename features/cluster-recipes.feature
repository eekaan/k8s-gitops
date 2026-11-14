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
    Given a cluster without its talman.yaml, its secrets.sops.yaml, the age key's location or KUBE_API_ADDRESS
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

  Scenario: A configuration rollout shows the change and asks before applying
    Given a configuration change talman reports for the cluster's nodes
    When cluster-talos runs and the cluster's name is not typed back
    Then it shows talman's dry run with the cluster's secrets redacted and applies nothing; with the name typed back, or with --yes, talman applies the change in one run with no health check; and with nothing to change it exits zero without asking or applying

  Scenario: New nodes are onboarded only when asked
    Given a node in maintenance mode beside a configuration change
    When cluster-talos runs, and then runs with --onboard
    Then without --onboard no talman call onboards new nodes and the node stays new, and with --onboard both the dry run and the apply onboard it

  Scenario: A Talos upgrade drains through the Kubernetes API one node at a time
    Given talman reporting cp-2 and worker-1 behind the Talos version and schematic talman.yaml gives them
    When cluster-upgrade runs, without the cluster's name typed back and then with it
    Then the first shows talman's dry run and changes nothing; the second takes an etcd snapshot, then for cp-2 and then worker-1 only drains the node with kubectl through the kubeconfig served at KUBE_API_ADDRESS, upgrades it with talman with talosctl's own drain off, waits for it to be Ready and uncordons it before the next is drained; with the API not answering nothing is drained, and with every node on its version it exits zero without asking

  Scenario: A Kubernetes upgrade shows the change and asks before applying
    Given kubernetesVersion in talman.yaml ahead of what the kubelets run
    When cluster-upgrade-k8s runs, without the cluster's name typed back and then with it
    Then the first shows talman's dry run and upgrades nothing; the second runs talman upgrade-k8s once, with an etcd snapshot first and the API reached at KUBE_API_ADDRESS, and then finds every node on the version; and with every node on it, it exits zero without asking or upgrading

  Scenario: No cluster secret reaches a command line or the output
    Given an age key, a secrets bundle and a kubeconfig whose secrets are known
    When every cluster recipe runs against recording tools, and in the ways each one stops
    Then no secret appears in any recorded argument list or in anything the recipes print
