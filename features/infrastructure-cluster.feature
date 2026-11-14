Feature: Cluster stack
  Six Talos nodes, reachable on their APIs from the operator only, each worker with a data volume
  for the storage layer.

  Scenario: Three control planes and three workers are planned
    Given the default node counts
    When the cluster stack is planned against mocked providers
    Then three control planes and three workers are planned with their role flavors, booting from a 40 GB volume of the Talos image

  Scenario: Nodes get fixed addresses below the DHCP pool
    Given the node subnet from the plumbing stack
    When the cluster stack is planned against mocked providers
    Then each control plane and worker has a distinct fixed address at its reserved host number

  Scenario: Instances carry no user data
    Given the planned instances
    When they are read
    Then none has user data

  Scenario: The APIs are open only to the allowlist and the cluster's own floating addresses
    Given an operator allowlist of two networks
    When the cluster stack is planned against mocked providers
    Then the only ingress from outside the group is TCP 50000 and 6443 from those two networks and from each node's own floating address, and TCP 6443 from the node subnet

  Scenario: An empty or malformed allowlist is rejected
    Given an allowlist that is empty or holds something that is not a CIDR
    When the cluster stack is planned
    Then planning fails with a message naming the variable

  Scenario: Every node has its own floating IP
    Given the planned nodes
    When the cluster stack is planned against mocked providers
    Then each node has one floating IP from the external network associated with its port

  Scenario: Nodes share one soft anti-affinity group
    Given the planned nodes
    When the cluster stack is planned against mocked providers
    Then all of them are members of one server group with the soft-anti-affinity policy

  Scenario: Every worker gets one data volume, and no control plane does
    Given the default node counts and data volume variables
    When the cluster stack is planned against mocked providers
    Then each worker has one volume of 100 GiB and type cbs, named after it and attached to its own instance by an attachment of its own, and no control plane has a data volume

  Scenario: Attaching a data volume replaces no server
    Given the cluster stack applied against mocked providers without its data volumes
    When it is planned with them
    Then the plan adds one volume and one attachment per worker, attached to the instance the apply left, and plans every instance as it was applied, its ID included

  # A mocked provider plans no replacement of its own, so the scenario above proves only what the
  # configuration decides. Whether the provider replaces a server shows in the real plan.
  @pending #INF-12
  Scenario: The plan of the running cluster adds the data volumes and replaces no server
    Given the running cluster, applied before its workers had data volumes
    When just infra-plan sto2/cluster plans it
    Then the plan creates one volume and one attachment per worker and replaces, changes or destroys no server

  Scenario: The data volume's size and type come from variables
    Given another size and volume type for the data volumes
    When the cluster stack is planned against mocked providers
    Then every worker's data volume has that size and type
