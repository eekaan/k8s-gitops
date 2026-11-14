Feature: Installing Flux
  Flux starts with what it needs already in place, from the manifests it will own.

  Scenario: The pre-Flux objects are applied before the operator
    Given a cluster with nodes and Cilium but no FluxInstance, and the Flux age key
    When cluster-flux runs
    Then the namespace flux-system, the ConfigMap cluster-config, the Secret cluster-secrets and the Secret sops-age are each applied in flux-system through standard input before the Flux Operator is installed

  Scenario: cluster-config holds exactly the keys the repository declares
    Given the cluster's talman.yaml, CLUSTER_DOMAIN in the environment and the cluster's cluster-config.example.yaml
    When cluster-config runs
    Then the applied ConfigMap cluster-config has exactly the keys the example lists: CLUSTER_DOMAIN from the environment, NODE_CIDR the node subnet in talman.yaml, and NODE_NAME_REGEX a pattern every node name in talman.yaml matches in full

  Scenario: A key that cannot be filled fails the recipe by name
    Given a cluster-config.example.yaml that lists a key cluster-config has no source for, or that leaves out one it fills
    When cluster-config runs
    Then it exits non-zero naming that key, and applies nothing

  Scenario: The cluster age key reaches the cluster under a key Flux reads and is never shown
    Given FLUX_AGE_KEY_FILE naming a path outside the repository where no key exists
    When cluster-flux-age-key runs twice and cluster-config runs
    Then the key is created once with mode 0600 and its recipient written into .sops.yaml, and the applied Secret sops-age holds that key under a data key ending in .agekey, while the key appears in no argument list, no output and no file in the repository

  Scenario: Without an encrypted secrets file an empty cluster-secrets is applied
    Given no kubernetes/clusters/lab-sto2/secrets/cluster-secrets.sops.yaml, and an example key list with no keys
    When cluster-config runs
    Then the Secret cluster-secrets is applied in flux-system with no data, so Flux's substitution finds it

  Scenario: The operator and instance are installed from their application directories
    Given the applications flux-operator and flux-instance in kubernetes/clusters/lab-sto2/flux-system/
    When cluster-flux runs against a recording helm
    Then helm installs release flux-operator and then release flux-instance in flux-system, each from the chart location and version in its ocirepository.yaml with its values.yaml, and the recipe waits for the FluxInstance flux to be Ready and prints the next step

  Scenario: An installed FluxInstance is not reinstalled
    Given a cluster that runs a FluxInstance
    When cluster-flux runs, and then runs with --reapply
    Then the first run exits non-zero without applying or installing anything, and the second applies the pre-Flux objects again and installs nothing

  Scenario: The certificate approver is installed during bootstrap with the cluster's own values
    Given nodes in maintenance mode, the cluster's talman.yaml and the Flux age key
    When cluster-bootstrap runs
    Then after Cilium it applies the pre-Flux objects, installs kubelet-csr-approver from its application with its values.yaml and its HelmRelease's values substituted from the applied cluster-config on standard input, and only then waits for every node to be Ready

  Scenario: No deployment value or secret reaches a command line or the output
    Given the Flux age key, an encrypted cluster-secrets and a cluster-config whose values are known
    When every Flux recipe runs against recording tools, and in the ways each one stops
    Then no value of cluster-config, no secret of cluster-secrets and no age key appears in any recorded argument list, in anything the recipes print, or in a file in the repository

  # Flux adopting an application that was installed before it, watched by app-adoption.

  Scenario: An adopted release passes every check
    Given Cilium installed before Flux as release cilium in kube-system, and helm-controller upgrading it to a second revision whose objects carry its labels, while every node stays Ready
    When app-adoption watches the adoption
    Then it prints pass for one release, for the bootstrap revision followed by helm-controller's, for the HelmRelease Ready with the chart version of ocirepository.yaml in its history, and for every node Ready, and exits 0

  Scenario: The check waits for a HelmRelease that does not exist yet
    Given a cluster without Flux's HelmRelease kind, on which the kind, the HelmRelease and its Ready condition appear on later polls
    When app-adoption runs
    Then it polls every 10 seconds, reading every node on each poll, and checks the release only once the HelmRelease is Ready for its current generation

  Scenario: A second release of the same name fails the check
    Given an adopted release, and a release of the same name in another namespace
    When app-adoption runs
    Then the one-release check fails naming both namespaces, and app-adoption exits non-zero

  Scenario: A release whose history holds only the bootstrap revision fails the check
    Given a Ready HelmRelease, and a release whose history holds the revision installed before Flux and nothing after it
    When app-adoption runs
    Then the adoption check fails saying helm-controller has not upgraded the release, and app-adoption exits non-zero

  Scenario: A release whose first revision already carries helm-controller's labels fails the check
    Given a release whose first revision's objects carry helm-controller's labels, as when Flux installed it and nothing was adopted
    When app-adoption runs
    Then the adoption check fails saying Flux installed the release, and app-adoption exits non-zero

  Scenario: A node that leaves Ready during the adoption fails the check and is named
    Given an adoption during which one node is not Ready for two polls
    When app-adoption runs
    Then it says when the node leaves Ready and comes back, and the node check fails naming the node by its Kubernetes name and the two polls, and app-adoption exits non-zero

  Scenario: A HelmRelease that reports failure ends the wait with its reason
    Given a HelmRelease whose upgrade fails, or that is stalled
    When app-adoption runs
    Then the wait ends at the poll that sees it, the HelmRelease check fails with the condition's reason and message, and app-adoption exits non-zero

  Scenario: A HelmRelease that never becomes Ready fails when the wait runs out
    Given ADOPTION_WAIT shorter than the adoption, and Flux's HelmRelease kind, the HelmRelease or its Ready condition still missing
    When app-adoption runs
    Then the HelmRelease check fails saying what it waited for and how long, and app-adoption exits non-zero

  Scenario: The check changes nothing in the cluster
    Given recording kubectl and helm
    When app-adoption runs, on an adoption that passes and on one that fails
    Then every recorded kubectl call is a get and every helm call is a list, a history or a get

  Scenario: Nothing but object names reaches the output
    Given nodes whose status holds addresses, a release manifest holding a Secret's data, and a kubectl whose error names the API server's address
    When app-adoption runs, on an adoption that passes, on one that fails and on one where kubectl fails
    Then neither an address nor the Secret's data appears in anything it prints
