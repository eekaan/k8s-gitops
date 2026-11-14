Feature: Talos image replacement
  A new Talos version or schematic brings a new image without deleting the old one or rebuilding a node.

  Scenario: Forgetting the image removes it from state and leaves everything else
    Given a throwaway stack on the local backend, under the repository's encryption settings, holding an image at the plumbing stack's address, a resource beside it in the same module and one outside it
    When the recipe's state operation runs on it with real tofu
    Then the state holds the other two resources and not the image, and the next plan creates the image and destroys nothing

  Scenario: The recipe forgets exactly the plumbing stack's image resource
    Given the plumbing stack's state holds its image
    When infra-forget-image runs with --yes against a recording tofu
    Then tofu is initialised on the plumbing stack with the committed backend file, the bucket and its state key, lists the state, and removes the image's address and nothing else, and no other state command runs

  Scenario: Nothing is forgotten without confirmation
    Given the plumbing stack's state holds its image
    When infra-forget-image runs and the stack's name is not typed back
    Then it has said in one line that only the state forgets the image and the image stays in the cloud, it exits non-zero, and nothing is removed from the state; typed back, the image is removed

  Scenario: A state without the image is left alone, and the recipe says so
    Given the plumbing stack's state holds no image
    When infra-forget-image runs
    Then it says there is nothing to forget, asks nothing, removes nothing and exits 0

  Scenario: Nothing from the state reaches the output
    Given a state listing and a removal report whose entries are marker strings
    When infra-forget-image runs, with and without CI, and when the removal fails with CI set
    Then no marker appears in anything the recipe prints, and with CI set tofu's errors are in the stack's error log only

  Scenario: Two operations on the stack do not overlap
    Given an operation in progress on the plumbing stack
    When infra-forget-image starts, or another operation starts while infra-forget-image runs
    Then the one that starts second exits non-zero saying the stack is busy

  Scenario: A schematic with the guest agent extension fails the infrastructure check, naming it
    Given talos/schematic.yaml listing the QEMU guest agent system extension
    When the infrastructure check runs
    Then it exits non-zero naming the extension and talos/schematic.yaml, while a schematic with other extensions passes

  Scenario: A new Talos version gives the image a new name
    Given the plumbing stack applied with one Talos version, against mocked providers
    When it is planned with another version
    Then the image's planned name carries the new version, as it carries the start of a new schematic's ID

  Scenario: A new image replaces no server and no boot volume
    Given the cluster stack applied with the plumbing stack's image, against mocked providers
    When it is planned after the plumbing stack has a new image
    Then every node keeps its instance and its boot volume from the old image
