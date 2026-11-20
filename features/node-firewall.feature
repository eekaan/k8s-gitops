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

  Scenario: Every node admits Cilium's WireGuard port from the nodes' own addresses alone
    Given every node's machine configuration rendered offline from the fixture, and the inventory
    When each node's rules are read
    Then each of the six nodes has exactly one rule admitting UDP 51871, named cilium-wireguard, accepting exactly the six nodes' own addresses, each as a single address, and nothing else, the load balancer's and the floating addresses not among them, and no other rule admits that port

  Scenario: The Talos API and the Kubernetes API accept the operator allowlist, the nodes, the load balancer and the CI host, and nobody else
    Given fixture node data with an operator allowlist of two networks, the load balancer's address and pool on the node network, and the CI host's address there
    When every node's configuration is rendered
    Then every node's Talos API rule accepts exactly the allowlist, each node's own and floating address and the CI host, every control plane's Kubernetes API rule accepts exactly those, the pod range and the load balancer's networks, no other rule accepts any of the outside ones, and no rule accepts the node network as a whole

  Scenario: An edge router's address reaches no listener on any node
    Given fixture node data with the two edge routers' addresses on the node network
    When every node's configuration is rendered
    Then no rule of any node accepts a network that holds an edge router's address

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

  Scenario: Every port a host-network pod declares is admitted by a rule for every node or listed with its reason
    Given the render of the kubernetes/ tree, the inventory in talos/firewall.yaml and node-firewall-exceptions.yaml
    When the ports are read that the containers and init containers declare in every pod template of the render that is on the host's network
    Then each port is admitted by exactly one rule of the inventory, of its protocol and for every node, or is one entry under no-rule with its reason, never both, the account of them is the one the test holds, and docs/cluster.md names every port without a rule where it says what gets none; a port with neither, with both, with two rules, with a rule only control planes have, or whose host port is another than itself, fails, named with its workload

  Scenario: Every rule of the node firewall has a listener, a port a host-network pod declares or a listed node service
    Given the render of the kubernetes/ tree, the inventory in talos/firewall.yaml and node-firewall-exceptions.yaml
    When each rule of the inventory is matched with the ports the host-network pods of the render declare
    Then each rule admits such a port or is named once under no-pod with what listens there, never both, and the account of them is the one the test holds; a rule with neither fails as stale, and an entry under no-pod for a rule a pod uses or that the inventory lacks, and an entry under no-rule that no such port matches, fail as entries without use

  Scenario: No pod on the pod network declares a host port
    Given the render of the kubernetes/ tree
    When every pod template that is not on the host's network is read
    Then no container or init container of it declares a host port, which Cilium would serve before the node's firewall sees the packet; one that does fails, named with its workload, and the host ports the render does declare, all in templates on the host's network, are the ones the test holds

  Scenario: No monitor scrapes a port that has no rule
    Given the render's PodMonitors, ServiceMonitors, Probes and Services, its Gateway and EnvoyProxies, the configuration and the namespace of Envoy Gateway's controller, and the ports node-firewall-exceptions.yaml lists under no-rule
    When each monitor is matched with the pods and the Services it selects, and each Probe with the one shape the tree's Probes have
    Then no PodMonitor scrapes such a port of a pod it selects, by its name or its number, and no ServiceMonitor scrapes a port of a Service that leads to it; what the test cannot decide counts against the monitor: a selector of an operator it does not know selects, an endpoint that names no port or rewrites the address it scrapes, by name, by a labelmap or by a target label built from its regex's groups, reaches every port, and a Service without a selector leads to every pod; a Probe is accepted in the one shape the tree's Probes have alone, as the test does not follow where a name leads: its prober the blackbox exporter's Service, by the name and port the render gives it, which selects the exporter's pods, none on the host network and none resolving names their own way, as the Prometheus that resolves the prober's name does not either; each target the public Gateway's proxies' Service, by the name tests/probes.bats derives, over http or https on a port of the Gateway's listeners, while no EnvoyProxy and no default of the controller patches the proxies' pods, which Envoy Gateway builds off the host network, or their Service, names the Service or merges the Gateways, the render holds no Service of that name, and their namespace enforces a Pod Security level that refuses it; no endpoints written by hand for either Service; its spec, its prober, its targets and its labels holding nothing more, its module one tests/probes.bats pins whole and its relabelings the tree's one; every other Probe is refused, saying how it leaves the shape, the kubelet's Service the Prometheus Operator makes at run time, headless Services over host-network or static pods, an ExternalName, a labelmap and a target label built from the regex's groups among them; and a ScrapeConfig, or a Prometheus with scrape configurations of its own or a scrape class with relabelings, fails until the test reads it

  Scenario: No rule admits a pod's own address to a node's Talos API, and each node holds its floating address itself
    Given fixture node data with each node's floating address and the pod range
    When every node's configuration is rendered
    Then each node holds exactly its own floating address, as one address on a dummy link, and its one rule for the Talos API's port accepts no network that shares an address with the pod range, from which a pod arrives at its own node's address on the node network and at its floating address

  Scenario: The account of what a rollout proves names every port the firewall admits
    Given the inventory in talos/firewall.yaml and the section of docs/cluster.md on what the rollout's checks prove and what to watch afterwards
    When the section is read
    Then every port and every port range of the inventory's seventeen rules is in it as a whole word

  Scenario: The first rollout applies to one node in a self-reverting mode and stops unless the checks pass
    Given a cluster whose configuration changes a worker and a control plane
    When cluster-talos runs with --first naming the worker, again with each check failing in turn, with the cluster unhealthy before it starts, and with the worker's configuration reverted before the checks end
    Then the cluster is checked first, and each node, the named one first and alone, is applied in try mode with a timeout and applied again to keep it only once, from the operator's machine: its Talos API reports the configuration in effect, every node answers on the Talos API port, another control plane's API server reaches its kubelet and its node-exporter, the Cilium agents on it and on another node reach each other through the overlay and on the health port, for a control plane its etcd member follows the same leader as another control plane's and is listed by it in talosctl's table of twelve columns, it is Ready 65 seconds after the try, for a control plane its own Kubernetes API answers at its own address and a fresh request through the load balancer reaches its API server, cluster-check passes, and the try window is not about to close; each failing check leaves the node unkept and the other node unapplied, the unhealthy cluster gets no apply, and the reverted node is not kept

  Scenario: A failed check after the first node leaves the other nodes untouched and says how the first reverts
    Given a cluster whose configuration changes two nodes, and a cluster-check that fails once the first has been applied
    When cluster-talos runs with --first naming one of them
    Then it exits non-zero, the first node is not kept, the other gets no apply after it, and its last lines say that the first node reverts by itself to the configuration it had once the try timeout has passed, and name every other node as untouched

  Scenario: With the reduced security groups selected, an unconfigured node's Talos API is still limited to the operator allowlist
    Given the cluster stack with the reduced security group rules and a CI host
    When it is planned against mocked providers
    Then TCP 50000 is admitted to a control plane from outside the nodes' group only from each allowlisted network, each node's floating address and the CI host, the control planes' own group admits every other TCP and UDP port and ICMP from all but no port of the NodePort range, the nodes' group keeps today's rules, and only control planes carry the new group

  Scenario: The workers' security group is the same with either set of the nodes' rules
    Given the cluster stack with the reduced security group rules and the edge routers of the plumbing stack
    When it is planned against mocked providers
    Then the workers' own group admits TCP 80 and 443 from each edge address and nothing else, holds no egress rule, every worker carries the nodes' group and its own and no other, and an edge router reaches a worker on those ports and TCP 6443 only, as with today's rules

  Scenario: With today's security groups selected, the stack plans no change
    Given the cluster stack with its default security group rules
    When it is planned against mocked providers
    Then the default is today's rules, the nodes' security group holds exactly today's ingress rules and no rule open to all, each rule keeps today's resource address, and the plan of the running cluster, its last part, shows no change to a resource
