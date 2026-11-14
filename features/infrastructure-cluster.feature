Feature: Cluster stack
  Six Talos nodes, reachable on their APIs from the operator only.

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
    Then the only ingress from outside the group is TCP 50000 and 6443 from those two networks and from each node's own floating address

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
