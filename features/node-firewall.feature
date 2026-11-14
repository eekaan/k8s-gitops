Feature: Nodes firewall themselves
  Every node drops inbound traffic unless its own machine configuration admits it, and admits each
  listener the cluster needs from only those who need it, so the nodes' protection does not depend
  on the cloud's security groups.

  Scenario: Every node drops inbound traffic by default
    Given the template, the patches, talos/firewall.yaml and fixture node data
    When the Talos check renders every node's configuration with talman and validates it with talosctl
    Then each of the six configurations sets Talos' ingress firewall's default action to block, once

  Scenario: Every listener in the inventory has a rule, and every rule has a line in the inventory
    Given the inventory in talos/firewall.yaml and its table in docs/cluster.md
    When every node's configuration is rendered
    Then each node carries one rule per listener of its role, with the inventory's name, protocol and ports, and no other rule, each rule accepts exactly the networks the listener's sources stand for in the fixture, and the table in docs/cluster.md lists exactly the inventory's listeners, each with its protocol, ports, nodes and sources

  Scenario: Every listener pods reach admits every node's own address
    Given the inventory's listeners that pods reach, and fixture node data with each node's address on the node network
    When every node's configuration is rendered
    Then each of those rules, on every node that has it, admits every node's own address, from which a pod on another node arrives once Cilium has masqueraded it

  Scenario: Cilium's overlay and health checks accept the nodes' own addresses only
    Given fixture node data whose node network also holds the load balancer's address
    When every node's configuration is rendered
    Then every node's rules for UDP 8472 and TCP 4240 accept exactly the six nodes' own addresses, each as a single address, and not the node network

  Scenario: The Talos API and the Kubernetes API accept the operator allowlist, the node network and the load balancer, and nobody else
    Given fixture node data with an operator allowlist of two networks and the load balancer's address on the node network
    When every node's configuration is rendered
    Then every node's Talos API rule accepts exactly the allowlist, the node network and each node's floating address, every control plane's Kubernetes API rule accepts exactly those and the pod range, the load balancer's address lies in the node network, and no other rule accepts an allowlisted network or a floating address

  Scenario: etcd accepts control planes only
    Given fixture node data with three control planes and three workers, each with its address on the node network
    When every node's configuration is rendered
    Then every control plane's etcd rule accepts TCP 2379 and 2380 from exactly the three control planes' addresses on the node network, each as a single address

  Scenario: The API server refuses new external addresses on Services
    Given the template, the patches and fixture node data
    When every node's configuration is rendered
    Then every control plane's API server enables the DenyServiceExternalIPs admission plugin through its extra arguments, which Talos adds to the plugins it enables itself, and no worker's configuration sets the API server's admission plugins

  Scenario: Workers carry no rule for a control-plane-only listener
    Given the inventory's listeners that only control planes have
    When every worker's configuration is rendered
    Then no worker carries a rule of those listeners, nor any rule for one of their ports

  Scenario: No rule accepts traffic from everywhere
    Given the rendered configuration of every node
    When its rules are read
    Then every rule accepts at least one network, and no rule's networks hold together as many addresses as IPv4 has

  Scenario: No operator address is in any committed file, and the allowlist reaches the configuration through the generated file
    Given a copy of the repository whose fixture allowlist is another network
    When every node's configuration is rendered
    Then that network reaches the Talos and Kubernetes API rules from talman.yaml's values, no file of talos/ that git would commit holds an address but the wildcard and loopback ones, and git ignores the cluster's talman.yaml and operator-cidrs.json

  Scenario: The first rollout applies to one node in a self-reverting mode and stops unless the checks pass
    Given a cluster whose configuration changes a worker and a control plane
    When cluster-talos runs with --first naming the worker, again with each check failing in turn, with the cluster unhealthy before it starts, and with the worker's configuration reverted before the checks end
    Then the cluster is checked first, and each node, the named one first and alone, is applied in try mode with a timeout and applied again to keep it only once, from the operator's machine: its Talos API reports the configuration in effect, every node answers on the Talos API port, another control plane's API server reaches its kubelet and its node-exporter, the Cilium agents on it and on another node reach each other through the overlay and on the health port, for a control plane its etcd member follows the same leader as another control plane's and is listed by it, it is Ready 65 seconds after the try, cluster-check passes, and the try window is not about to close; each failing check leaves the node unkept and the other node unapplied, the unhealthy cluster gets no apply, and the reverted node is not kept

  Scenario: A failed check after the first node leaves the other nodes untouched and says how the first reverts
    Given a cluster whose configuration changes two nodes, and a cluster-check that fails once the first has been applied
    When cluster-talos runs with --first naming one of them
    Then it exits non-zero, the first node is not kept, the other gets no apply after it, and its last lines say that the first node reverts by itself to the configuration it had once the try timeout has passed, and name every other node as untouched

  Scenario: With the reduced security groups selected, an unconfigured node's Talos API is still limited to the operator allowlist
    Given the cluster stack with the reduced security group rules and a CI host
    When it is planned against mocked providers
    Then TCP 50000 is admitted from outside the group only from each allowlisted network, each node's floating address and the CI host, no rule open to all covers the NodePort range, every other TCP and UDP port and ICMP are admitted from all, and today's rules stay

  Scenario: With today's security groups selected, the stack plans no change
    Given the cluster stack with its default security group rules
    When it is planned against mocked providers
    Then the default is today's rules, the nodes' security group holds exactly today's ingress rules and no rule open to all, each rule keeps today's resource address, and the plan of the running cluster, its last part, shows no change to a resource
