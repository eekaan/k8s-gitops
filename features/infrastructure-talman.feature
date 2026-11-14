Feature: talman.yaml from the cluster stack
  The node list and addresses talman uses come from OpenTofu, not from a file kept by hand.

  Scenario: The rendered talman.yaml lists every node at its floating address
    Given the planned nodes
    When the cluster stack is planned against mocked providers
    Then talman.yaml has one node per instance with its role and its own floating address, control planes first

  Scenario: The cluster endpoint is the load balancer's private address
    Given the planned load balancer
    When the cluster stack is planned against mocked providers
    Then talman.yaml's endpoint is the API endpoint output and the certificate names are the load balancer's two addresses and each control plane's floating address

  Scenario: Versions come from versions.yaml
    Given a versions file
    When the cluster stack is planned against mocked providers
    Then talman.yaml carries its Talos and Kubernetes versions

  Scenario: Overlapping or undersized cluster subnets are rejected
    Given pod and service subnets that overlap each other or the node subnet, or a pod subnet too small for the nodes
    When the cluster stack is planned
    Then planning fails naming the variable

  Scenario: The recipe writes talman.yaml privately and atomically
    Given an applied cluster stack
    When infra-talman runs against a recording tofu
    Then the cluster's talman.yaml exists with mode 0600, its content is the stack's output, and nothing of it was printed

  Scenario: A schematic mismatch fails the recipe
    Given a stack whose schematic id differs from the one talman computes
    When infra-talman runs
    Then it exits non-zero naming both ids and leaves no partial file

  Scenario: The written file validates
    Given the stack's output for six nodes
    When infra-talman runs
    Then talman validates the written file against the repository's patches
