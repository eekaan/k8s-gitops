Feature: Talos machine configuration
  Machine configuration is rendered and validated from the repository alone.

  Scenario: Every node's configuration renders and validates offline
    Given the template, the patches, the schematic and fixture node data
    When the Talos check runs
    Then a machine configuration is rendered for each of the six nodes and each one validates for the cloud platform

  Scenario: Each node's configuration takes its versions, endpoint and subnets from the inputs
    Given a copy of the repository with other Talos and Kubernetes versions, another endpoint, other node, pod and service subnets and another schematic
    When the configuration is rendered
    Then every node's configuration carries those values, and its installer image names the schematic ID talman computes and the Talos version

  Scenario: A patch with an unknown field fails the check
    Given a patch containing a field Talos does not define
    When the Talos check runs
    Then it exits non-zero and the output names the patch

  Scenario: A template tofu cannot render fails the check with tofu's message
    Given fixture inputs without a value the template uses, or a template with a misspelt input name
    When the Talos check runs
    Then it exits non-zero, shows tofu's error naming the input, and says tofu could not render the template

  Scenario: A node's floating address is held on a dummy link
    Given fixture node data with a floating address per node
    When the configuration is rendered
    Then each node's configuration has a dummy link with that node's own floating address as a /32

  Scenario: Kubernetes and etcd use the node network, not the floating address
    Given fixture node data with a node network that holds each node's address and none of the floating addresses
    When the configuration is rendered
    Then every node's kubelet takes its node IP from the node network only, and every control plane's etcd advertises and listens on the node network only

  Scenario: Control planes carry the API certificate names
    Given fixture API certificate names
    When the configuration is rendered
    Then every control plane's configuration lists them for both the Talos API and the Kubernetes API server, and no worker's does

  Scenario: Cilium replaces the bundled CNI and kube-proxy
    Given the rendered control plane configuration
    When it is read
    Then no bundled CNI is configured and kube-proxy is disabled

  Scenario: An output directory inside the repository is refused
    Given an output directory inside the repository, named directly, relative to it or through a symlink
    When the Talos check runs
    Then it exits non-zero saying the directory is inside the repository, and writes nothing

  Scenario: The check leaves nothing behind
    Given a clean working tree
    When the Talos check runs, whether it passes or fails
    Then no rendered configuration, talosconfig or secrets bundle remains in the repository or the temporary directory
