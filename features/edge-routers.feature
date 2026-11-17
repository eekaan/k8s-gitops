Feature: Edge routers
  Two small Linux VMs the deployment runs itself, on the node subnet at the addresses the plumbing
  stack reserves, speaking BGP with the workers: each learns the address of every announced
  Service as a /32 with one next hop per announcing worker, and accepts connections to its own
  public address on the public ports with a TCP proxy that opens its own connection to the
  cluster's public Gateway address, by those routes, and names the client in a PROXY protocol
  header. Either edge can be lost or rebuilt while the other keeps serving.

  Two scenarios need unprivileged user namespaces with networks of their own, which the CI
  containers refuse: "An edge answers a client's connection to a public port through its proxy and
  names the client's address to the Gateway in a PROXY protocol header" and "An edge that loses its
  routes to the Gateway fails connections fast and recovers without a restart". Their proofs load
  the edge's rendered rules with nft and its rendered proxy configuration into network namespaces
  beside a client, a worker and the cloud's router, are tagged namespace and run with just
  edge-forward-check on a developer's machine, where they skip, saying why, when the host lacks what
  they need; just ci and CI run every other proof, and the stack's tests compare the rules as text.

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

  Scenario: An edge answers a client's connection to a public port through its proxy and names the client's address to the Gateway in a PROXY protocol header
    Given the edge's rendered rules and proxy configuration, a client, a worker that holds the Gateway's address with a server there that records what each connection starts with, and the cloud's router as the default route
    When the client connects to the edge's own address on the public port from a port of its choosing, and to a port that is not listed with a server listening on it, to the edge's other address on the public port, and to the Gateway's address through the edge
    Then the first connection is answered, and the server on the Gateway's address was connected to once, from the edge's own address, and was sent a PROXY protocol version 2 header for IPv4 over TCP naming the client's address and port and the address and port it connected to, and the proxy's log names the client; the other three get no answer, and nothing but the proxy's own connection reaches the Gateway's server, the worker or the router

  Scenario: An edge forwards nothing at the packet level for the public ports and refuses a port that is not listed
    Given the public ports and the Gateway's address
    When an edge's nftables rules are rendered
    Then the file holds one table whose forward chain drops by default and holds no rule, no rule translates an address or a port, the input chain admits only SSH, the public ports, BGP from the workers' addresses and the ICMP path MTU needs, so a port that is not listed is dropped, and the output chain refuses a packet toward the Gateway's address that does not go through a worker

  Scenario: An edge that loses its routes to the Gateway fails connections fast and recovers without a restart
    Given the edge's rendered rules and proxy configuration, a client, a worker that holds the Gateway's address and announces it, and the cloud's router as the default route
    When a connection is established through the proxy, and the worker's route then goes, as when FRR stops, and new connections are opened with the default route only and with no route at all
    Then what the established connection sends and the new connections' attempts reach neither the router nor anything else, each new connection is closed unanswered within a second and a half, and with the worker's route back a new connection is answered by the proxy that ran throughout

  Scenario: A template that does not render fails the forward check where it is rendered, with what tofu said
    Given the forward check's fixture as it is; a copy of it beside a stack whose proxy template is absent, where tofu console exits 0, prints "(known after apply)" and says why on standard error; a tofu that exits 0 and prints "(known after apply)"; and a tofu that exits non-zero
    When the helper the forward check renders with is asked for the fixture's files
    Then the fixture as it is renders both files, and every other render fails, non-zero, naming the local it asked for and showing what tofu printed on standard error, and leaves no file

  @pending @INF-15
  Scenario: The edges are replaced one at a time only once the Gateway accepts the header
    Given a Gateway whose public listeners accept a PROXY protocol header and edges that send one
    When the edges are replaced with just edge-rollout --replace, one at a time, with just gateway-check after each
    Then the Gateway is the one that accepts the header before the first edge is replaced, and an edge is replaced only once the other serves, so no client's connection is sent a header its Gateway does not accept

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

  Scenario: A rollout answered through a pipe written before it started reads the stack's name, the sentence that names both edges and the yes for each host key
    Given edge 2 down with its host key not recorded, edge 1 to be replaced, consoles that hold no fingerprints, an SSH client that reads its standard input to the end, as OpenSSH's does, and the four answers written once to a pipe, in the order they are asked, by a writer that has ended
    When just edge-rollout --replace --edge 1 --other-down runs without --yes, the pipe its standard input, and checks the edges with the real edge-check
    Then each answer reaches its prompt, the yes the check of edge 2 asks for its host key among them, edge 1 is replaced and passes, no answer is left, and no program the rollout or its checks started had the pipe as its standard input but the checks themselves, which the rollout hands it to ask with, and the dirname each script runs to find its libraries before it keeps its input

  Scenario: A plan that takes one edge down is applied on the stack's name read from a pipe, after the other edge's check
    Given a plan that replaces edge 2 while edge 1 serves, an SSH client that reads its standard input to the end, and the stack's name written once to a pipe by a writer that has ended
    When just infra-apply sto2/edge runs without --yes, the pipe its standard input
    Then edge 1 is checked over SSH by a client that did not have the pipe, the name is read from the pipe, and the plan is applied

  Scenario: EDGE_ROLLOUT_WAIT and EDGE_ROLLOUT_INTERVAL are read from .env, as HOST_CONSOLE_WAIT is
    Given a .env that holds EDGE_ROLLOUT_WAIT, EDGE_ROLLOUT_INTERVAL and HOST_CONSOLE_WAIT, none of them in the environment, and a plan that replaces the first edge whose console holds no fingerprints yet
    When just edge-rollout runs with 08 and 04, and with 010 and 02 in the file, and with a value in the file that is no whole number of at most 9 digits
    Then it reads the console at 0, 4 and 8 seconds on the clock, and at 0, 2, 4, 6, 8 and 10, and the value that is no number is refused, named, before the stack is locked or touched

  Scenario: edge-check takes the stack's lock, which only the child of a run that holds it shares
    Given another run holding the edge stack's lock, with EDGE_STACK_LOCKED set to 1, to the number of a descriptor open on the lock file that holds no lock, to a word and to nothing; and a run holding the lock that runs edge-check with EDGE_STACK_LOCKED naming its descriptor
    When edge-check runs
    Then each run that is not the holder's stops, saying the stack is busy, before the stack is initialised or an edge is reached; the child of the run that holds the lock shares it and passes, nothing holds the lock afterwards, and edge-check with no variable takes the lock for itself, as the rollout's and infra-apply's children do

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

  Scenario: The check fails an edge whose loaded ruleset has a chain hooked at nat or a statement that translates, in any table
    Given an edge, healthy otherwise, whose loaded ruleset as nft lists it as JSON is, in turn: its own table alone, beside a table that only filters, beside one whose chain filters before routing, and with rules that match a translated connection or carry a translation's name in a comment; its own table beside the translation table by its name, beside a chain hooked at nat that holds no rule in a table of another name, before routing, at output and after routing, beside the nat table iptables-nft makes, and with each of dnat, snat, masquerade and redirect in a chain hooked nowhere, in its own table and in another; in place of its own table nothing, a table of its name in another family, a table of its family under another name, and a chain hooked at nat with a masquerade statement in a chain hooked nowhere; its own table beside a rule that jumps to an inline chain with a masquerade statement, which nft lists as text; and an answer that is not nft's listing
    When just edge-check runs
    Then the first four pass, saying that none translates an address; each of the next fails on a line of its own that names what was found, a chain hooked at nat or which statements, and no rule, element or address; without its own table the rules are not loaded, and what translates in their place is named on its line all the same; and the inline chain and an answer that is not the listing each fail as a state that cannot be read, neither a pass nor rules that are not loaded

  Scenario: Without a Gateway address the output chain's guard is a skip that says what was not compared
    Given an edge whose output chain holds its guard, and a talman.yaml that gives no Gateway address: with its workers, with none, and not there at all
    When just edge-check runs, and again with no guard rule, a worker's address left out of the guard, a worker without an address in the file, and the default route's next hop admitted
    Then the guard's line is a skip, which fails nothing and says that the guard was not compared with the Gateway's address, that no worker's address was looked for in it when the file gives none, and what was still checked; and each of the others fails as it does with the address

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
