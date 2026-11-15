Feature: Edge routers
  Two small Linux VMs the deployment runs itself, on the node subnet at the addresses the plumbing
  stack reserves, speaking BGP with the workers: each learns the address of every announced
  Service as a /32 with one next hop per announcing worker, and forwards traffic that arrives at
  its own public address to the cluster's public Gateway address and back. Either edge can be
  lost or rebuilt while the other keeps serving.

  One scenario needs unprivileged user namespaces with networks of their own, which the CI
  containers refuse: "A translated connection leaves an edge only through a worker's route, new or
  established". Its proof loads the edge's rendered rules with nft into network namespaces beside a
  client, a worker and the cloud's router, is tagged namespace and runs with just
  edge-forward-check on a developer's machine, where it skips, saying why, when the host lacks what
  it needs; just ci and CI run every other proof, and the stack's tests compare the forward chain's
  rules as text.

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

  Scenario: A translated connection leaves an edge only through a worker's route, new or established
    Given the edge's rendered rules, a client, a worker that holds the Gateway's address and announces it, and the cloud's router as the default route
    When a connection is established through the worker, and the worker's route then goes, as when FRR stops, and new connections are opened with the default route only and with no route at all
    Then the established connection's packets and the new connections reach neither the router nor anything else, and with the worker's route back a new connection is answered

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

  Scenario: A healthy edge passes the check with only what its ordinary user can run
    Given a fake edge that runs the check's command with the commands of its ordinary user's PATH, and the programs in the sbin directories only through sudo, as on Debian
    When just edge-check runs against a healthy edge
    Then every line passes, the kernel's forwarding state is read from /proc/sys/net/ipv4/ip_forward without sudo, and no output line holds an address

  Scenario: A state the edge did not report is a failure that says it could not be read
    Given an edge whose command for one section of the report is missing or fails, in turn for every section, with a message that holds an address
    When just edge-check runs
    Then it fails with a line that says it cannot read that state on the edge and what the edge said with the address left out, and it does not draw the unhealthy conclusion from the missing answer

  Scenario: The first boot gives the SSH daemon the settings the tree holds, and they win over the image's
    Given the image's SSH daemon configuration, which includes its drop-in directory ahead of its own key exchange, ciphers and MACs, and drop-ins that say password login, root login and forwarding are on
    When the first boot runs
    Then the daemon's settings are installed as the first drop-in in lexical order, key exchange limited to the post-quantum hybrids and curve25519-sha256, AEAD ciphers and encrypt-then-MAC MACs, public key authentication only, and no forwarding, which the daemon accepts and reports as its effective settings, and the daemon is validated before it is reloaded

  Scenario: A daemon configuration that does not validate fails the first boot
    Given settings the SSH daemon refuses
    When the first boot runs
    Then it fails saying why, on the console and in the log, leaves no drop-in behind and does not reload the daemon, and the edge is disarmed

  Scenario: The check fails an edge whose SSH daemon accepts another key exchange or a password
    Given an edge whose SSH daemon's effective settings differ from the tree's in one setting at a time, each setting of the tree in turn, by another value, none, or the tree's value with more after it, or by a Match block for the edge's user
    When just edge-check runs
    Then it fails naming that setting and no value, and passes when the settings are the tree's for the edge's user's connection

  Scenario: The settings check asks the daemon as the configured user
    Given EDGE_SSH_USER set to another name than the image's default, and Match blocks for that name and for the default, in the fake daemon and in this machine's own
    When just edge-check runs
    Then a Match block for the configured user fails the check and one for the default user does not

  Scenario: A new edge whose offered keys are all on its console is trusted without a prompt
    Given replaced edges whose addresses offer two host keys each, and whose new instances, each with an identifier of its own that the stack's outputs give once it is applied, printed both fingerprints on their consoles, one with LF line endings and one with CR LF, while the replaced instances are gone
    When just edge-rollout records their new host keys with nothing typed
    Then both keys of each are recorded without a prompt, in one line that says how many and that they match the console, each console is read through the OpenStack client by the new instance's identifier, and the rollout goes on

  Scenario: An address that offers a key its instance did not print is refused, and nothing is recorded
    Given a replaced edge whose address offers a key its instance's console does not hold, once beside a key it does hold and once with none of its own, and a first connection of edge-check to such an edge
    When just edge-rollout and just edge-check run with yes typed and --yes given
    Then each exits non-zero saying the address offers a key its instance did not print, records nothing, offers no prompt, and the rollout touches no later edge

  Scenario: A console that holds no fingerprints yet is waited for, and then the operator is asked
    Given a replaced edge whose console holds the fingerprints for its second read, whether the first read found none or could not read it, never holds them, or cannot be read, and the test's clock
    When just edge-rollout records its new host keys
    Then it reads again every interval within the rollout's wait and records without a prompt once they are there; when they never are, it reads until the wait is over and no longer, and then, as when the console cannot be read, it says so and asks, and yes records the keys and anything else declines

  Scenario: Only the fingerprints cloud-init printed at the latest boot count
    Given console logs with one boot, two boots, a block cut off at its start and at its end, fingerprint-shaped lines outside cloud-init's markers or not of the SHA256 form, blocks under logger's header for either of cloud-init's tags and days of one and two digits, blocks without it, in forms close to it or as the journal echoes them, each with LF and with CR LF line endings
    When the console's fingerprints are read, and a rollout compares an address's keys with a console whose earlier boot's block holds them
    Then only the complete block of the latest boot, under logger's exact header, counts, and the rollout refuses the key

  Scenario: What is compared with the console is what is recorded
    Given an address whose second scan would answer with another key
    When just edge-rollout records its new host keys
    Then the address is scanned once, hashed, and the keys that were compared are the keys recorded

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
