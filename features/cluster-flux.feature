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

  @pending #TAL-3
  Scenario: The certificate approver is installed during bootstrap with the cluster's own values
    Given nodes in maintenance mode, the cluster's talman.yaml and the Flux age key
    When cluster-bootstrap runs
    Then after Cilium it applies the pre-Flux objects, installs kubelet-csr-approver from its application with its values.yaml and its HelmRelease's values substituted from the applied cluster-config on standard input, and only then waits for every node to be Ready

  Scenario: No deployment value or secret reaches a command line or the output
    Given the Flux age key, an encrypted cluster-secrets and a cluster-config whose values are known
    When every Flux recipe runs against recording tools, and in the ways each one stops
    Then no value of cluster-config, no secret of cluster-secrets and no age key appears in any recorded argument list, in anything the recipes print, or in a file in the repository
