Feature: CI host
  A small Linux VM in the node network, outside the cluster, reachable over SSH from the operator
  allowlist only, that runs this repository's CI jobs for trusted events on a persistent Dagger
  engine whose cache lives on a volume of its own.

  Scenario: The CI host is reachable over SSH from the allowlist and from nowhere else
    Given an operator allowlist of two networks, one of them listed twice
    When the ci stack is planned against mocked providers
    Then the host's security group admits TCP 22 from each of those networks once and nothing else inbound, lets the host reach anything, and is the only group of the host's port, which has port security and a floating IP

  Scenario: The CI host survives a destroy of the cluster stack and is destroyed only by name
    Given the ci stack beside the cluster and plumbing stacks
    When just infra-destroy runs without a stack, and with sto2/cluster
    Then neither touches the ci stack, which reads no state but the plumbing stack's, and just infra-destroy sto2/ci destroys the ci stack alone once its name is typed back

  Scenario: The engine's cache is on a volume of its own
    Given the default cache volume size
    When the ci stack is planned against mocked providers
    Then a volume apart from the boot volume is attached to the host by an attachment of its own, and the host's first boot finds it by its volume ID, formats it only when it holds no file system, and mounts it where the engine keeps its state

  Scenario: The user data holds no secret
    Given an SSH public key and an operator allowlist
    When the host's user data is rendered
    Then it installs a container runtime, creates the runner's user with no sudo, no docker group and no password, and mounts the cache volume, and holds neither the key, nor the allowlist, nor a password or a token

  Scenario: Setup starts the pinned engine and the pinned, checksum-verified runner, and a second run changes nothing
    Given a CI host whose host key is known, and the pins in versions.yaml
    When just ci-host-setup runs twice
    Then the first run starts the pinned engine image with its state on the cache volume, installs the runner release whose checksum matches its pin, registers it and runs it as a service under the runner's user, and the second run changes nothing on the host and asks GitHub for nothing

  Scenario: The registration token reaches no command line, no output and no file
    Given gh hands out a registration token and a remove token
    When just ci-host-setup registers the runner and just ci-host-remove deregisters it
    Then the runner's configuration gets each token in its environment, read from standard input, and neither token is in a command line, the output or a file on either side

  Scenario: A host whose key is not known is refused until its fingerprint has been accepted
    Given a CI host whose SSH host key is not recorded
    When just ci-host-setup runs and the fingerprint it shows is declined, and then accepted
    Then the declined run fails without connecting to the host, and the accepted run records the key and connects only with strict host key checking against it

  Scenario: The CI host reaches the nodes' Talos and Kubernetes APIs once the cluster stack is given its host number
    Given the cluster stack, with and without the CI host's host number
    When it is planned against mocked providers
    Then with the number the nodes admit TCP 50000 and 6443 from the CI host's fixed address, and without it the nodes' rules are as they were
