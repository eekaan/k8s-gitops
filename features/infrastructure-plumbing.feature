Feature: Plumbing stack
  One network, one router and one Talos image, described without credentials.

  @by:infra-check
  Scenario: The stacks format and validate offline
    Given no cloud credentials and no state backend
    When the infrastructure check runs
    Then every stack formats, initialises without a backend, and validates

  Scenario: The DHCP pool leaves the low addresses for nodes
    Given the node subnet
    When the plumbing stack is planned against mocked providers
    Then the allocation pool starts above the range reserved for fixed node addresses

  Scenario: The router is attached to the external network by name
    Given an external network named ext-net
    When the plumbing stack is planned against mocked providers
    Then the router's gateway is that network and the node subnet is attached to the router

  Scenario: The image is built from the pinned Talos version and schematic
    Given a versions file and talos/schematic.yaml
    When the plumbing stack is applied against mocked providers
    Then the image is the Image Factory's openstack disk image, decompressed and uploaded raw and private
    And its name carries the Talos version from the versions file

  Scenario: A check failure names the stack
    Given a stack with a formatting or validation error
    When the infrastructure check runs
    Then it exits non-zero and names the directory that failed

  Scenario: A file that does not parse names its directory
    Given a module that no stack uses, holding a file that does not parse
    When the infrastructure check runs
    Then it exits non-zero and names the module's directory

  Scenario: A tree without stacks fails the check
    Given no stack under infra/openstack/stacks
    When the infrastructure check runs
    Then it exits non-zero and says it found no stack
