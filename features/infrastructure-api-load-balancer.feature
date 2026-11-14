Feature: Kubernetes API load balancer
  One address for the Kubernetes API that does not depend on a single control plane.

  Scenario: The API has a fixed private address known at plan time
    Given the node subnet
    When the cluster stack is planned against mocked providers
    Then the load balancer's address is the reserved host number on that subnet and the endpoint output is its HTTPS URL on port 6443

  Scenario: The load balancer address collides with no node
    Given the planned nodes
    When the cluster stack is planned against mocked providers
    Then the load balancer's address differs from every node's fixed address and lies below the DHCP pool

  Scenario: All three control planes are members on the API port
    Given the planned control planes
    When the cluster stack is planned against mocked providers
    Then the pool has one member per control plane at its private address on port 6443 and no worker is a member

  Scenario: The listener admits only the allowlist and the node subnet
    Given an operator allowlist of two networks
    When the cluster stack is planned against mocked providers
    Then the listener is TCP on 6443 and admits exactly those two networks and the node subnet

  Scenario: The control planes accept the API port from the node subnet
    Given the cluster security group
    When the cluster stack is planned against mocked providers
    Then it admits TCP 6443 from the node subnet and from nothing wider than before

  Scenario: The load balancer has a floating IP
    Given the planned load balancer
    When the cluster stack is planned against mocked providers
    Then one floating IP from the external network is associated with its VIP port
