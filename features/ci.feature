Feature: Continuous integration
  The checks a pull request gets are the checks a person runs, with the same tools.

  Scenario: The hermetic run passes on a clean tree
    Given a clean checkout and a container runtime
    When just ci runs
    Then the checks run inside a container built from the pinned tools and the run exits zero

  Scenario: A failing check fails the hermetic run
    Given a tracked file that fails one of the checks
    When just ci runs
    Then the run exits non-zero and the failing check's own message is in the output

  Scenario: The hermetic run checks the messages of the commits after the default branch
    Given a branch with a commit after the default branch whose message holds an address literal
    When just ci runs
    Then the run exits non-zero and names the commit and the literal

  Scenario: The hermetic run validates the Renovate configuration with the image renovate-check uses
    Given the justfile and the Dagger module
    When the commands renovate-check and just ci run are read
    Then both name the one pinned Renovate image, and the module names no image of its own for it

  Scenario: The workflow runs one recipe and nothing else
    Given the CI workflow
    When its steps are read
    Then the only command it runs after installing tools is just ci, it has no path filter, and it requests read-only permissions

  Scenario: Every action is pinned to a commit
    Given the CI workflow
    When its uses lines are read
    Then each one references a full commit SHA
