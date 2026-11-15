Feature: Edge routers
  Two small Linux VMs the deployment runs itself, on the node subnet at the addresses the plumbing
  stack reserves, speaking BGP with the workers: each learns the address of every announced
  Service as a /32 with one next hop per announcing worker, and forwards traffic that arrives at
  its own public address to the cluster's public Gateway address and back. Either edge can be
  lost or rebuilt while the other keeps serving.

  Scenario: The stack makes two edges at the reserved addresses, apart from each other, each with a public address, and plans without the cluster stack
    Given the plumbing stack's outputs and no state of the cluster stack
    When the edge stack is planned against mocked providers
    Then there are two instances, one at each reserved edge address, each with a floating IP of its own, both in one server group, and the plan needs nothing the cluster stack holds

  Scenario: An edge accepts sessions from the workers' addresses in the cluster's AS and from nowhere else
    Given the node subnet, the host number the cluster stack gives its first worker, the most workers there can be, the cluster's AS and the edge's AS
    When an edge's FRR configuration, its firewall rules and its security group are rendered
    Then each admits BGP only from the workers' block of host numbers, as the fewest networks that hold it, the FRR configuration in one peer group whose remote AS is the cluster's, and in its own AS

  Scenario: An edge installs a /32 inside the service range and refuses anything else
    Given the service range
    When an edge's FRR configuration is rendered
    Then the inbound policy permits only prefixes of exactly 32 bits inside the service range, denies everything else, and sets the maximum of accepted prefixes to the number of addresses in the range, which a loosened prefix list would reach

  Scenario: An edge advertises nothing
    Given an edge's FRR configuration
    When it is rendered
    Then the outbound policy of the peer group denies every prefix and the configuration has no network statement and no redistribution

  Scenario: The edges' timers and graceful restart agree with what the workers are configured with
    Given the peer configuration the workers use, in the Kubernetes manifests
    When an edge's FRR configuration is rendered
    Then its keepalive, hold, connect retry and graceful restart settings are those of the manifests, and its multipath covers at least as many paths as there can be workers

  Scenario: Traffic to an edge's public ports is forwarded to the Gateway's address and nothing else is forwarded
    Given the public ports and the Gateway's address
    When an edge's nftables rules are rendered
    Then connections to the edge's own address on those ports are translated to the Gateway's address, from the edge's own address, the forward chain drops everything else, and the input chain admits only SSH, BGP from the workers' addresses and the ICMP path MTU needs

  Scenario: The public ports admit only the operator allowlist by default, and SSH admits only the operator allowlist
    Given an operator allowlist and no public source networks set
    When the edge stack is planned against mocked providers
    Then the public ports admit the allowlist, SSH admits the allowlist only, and no inbound rule admits every address but the one for the ICMP that path MTU discovery needs

  Scenario: The public ports admit the source networks they are given instead of the allowlist
    Given an operator allowlist and a deliberately different set of public source networks
    When the edge stack is planned against mocked providers
    Then the public ports admit those networks only and SSH still admits the allowlist only

  Scenario: The user data holds no secret, and the edge's port allows exactly the address pairs the design needs
    Given an SSH public key and an operator allowlist
    When the edge's user data is rendered
    Then it holds neither the key, nor the allowlist, nor a password, and each edge's port has port security on and no allowed address pair

  Scenario: A change to the configuration rolls out one edge at a time and stops when the check fails
    Given a plan that replaces both edges
    When just edge-rollout runs, and again with the first edge's check failing
    Then just infra-apply sto2/edge refuses the plan, the rollout replaces the first edge, checks it, and only then replaces the second, and with the check failing the second edge is never touched

  Scenario: A new image is taken up only by an edge whose replacement is forced, which keeps its port and floating IP
    Given the edges applied from one image, and a newer image under the same name
    When the stack is planned with the first edge's instance replaced on purpose
    Then the first edge's new instance boots a volume made from the newer image on the same port, behind the same floating IP, and the second edge keeps its instance and its volume made from the old image

  Scenario: A forced rollout replaces one edge at a time and stops when the check fails
    Given edges that serve, and a plan that replaces neither
    When just edge-rollout --replace runs, and again with the first edge missing a worker's session once replaced
    Then it replaces the first edge's instance alone, records its new host keys, waits until its check passes with every worker's session established, and only then replaces the second edge's instance; with the check failing, the second edge is never planned, applied or touched

  Scenario: edge-check passes with every worker's session established and fails, saying which, when one is missing or a route outside the range is present, and no address is printed
    Given fake edges that report their sessions, routes and rules
    When just edge-check runs against a complete table, a table with a missing session, and one with a route outside the range
    Then the first run passes, each of the others fails naming the worker or the route's problem, and no output line holds an address

  Scenario: The Gateway's address is the service range's host at the number the plumbing stack is given
    Given the plumbing stack's service range and a Gateway host number other than the default
    When the plumbing stack is planned against mocked providers
    Then the output bgp's gateway_address is the service range's host at that number, inside the range

  Scenario: A Gateway host number beyond the service range is refused at plan time
    Given a Gateway host number the service range has no host for
    When the plumbing stack is planned against mocked providers
    Then the plan is refused on the variable gateway_host, as it is for the range's network address and its last address

  Scenario: The Gateway's address is inside the service range and reaches cluster-config
    Given the Gateway's address the plumbing stack outputs, inside the service range and not its first host
    When the cluster stack renders talman.yaml and just cluster-config fills the ConfigMap
    Then GATEWAY_ADDRESS is that address, neither the range's network address nor its last, the ConfigMap's keys are those the example lists, and the LoadBalancer pool still holds the whole range, as keeping the Gateway's address from another Service is the Gateway change's to do

  Scenario: os-images prints names only
    Given an OpenStack client that lists images with their IDs, sizes and visibility
    When just os-images runs with and without a pattern
    Then it prints the names of the images that match, one per line, and nothing else
