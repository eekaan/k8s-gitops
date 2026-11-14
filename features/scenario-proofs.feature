Feature: Scenario proofs
  Every scenario is proved under its own name or is marked pending with its issue.

  Scenario: A scenario with a proof of the same name passes
    Given a feature file and a test whose name is the scenario's title
    When the scenarios check runs
    Then it exits zero and counts the scenario as proved

  Scenario: A scenario without a proof fails
    Given a feature file with a scenario no test is named after
    When the scenarios check runs
    Then it exits non-zero and names the feature file, the line and the scenario

  Scenario: A pending scenario needs its issue key
    Given a scenario tagged pending without an issue key
    When the scenarios check runs
    Then it exits non-zero and names the scenario

  Scenario: A pending scenario that has a proof fails
    Given a scenario tagged pending and a test named after it
    When the scenarios check runs
    Then it exits non-zero and says to remove the pending tag

  Scenario: A proof without a scenario fails
    Given a test marked as a scenario proof whose name matches no scenario
    When the scenarios check runs
    Then it exits non-zero and names the test file and the test

  Scenario: Duplicate scenario titles fail
    Given two feature files with a scenario of the same title
    When the scenarios check runs
    Then it exits non-zero and names both locations

  Scenario: A scenario proved by a recipe passes
    Given a scenario tagged @by: with a recipe that the repository's justfile or a file it imports defines
    When the scenarios check runs
    Then it exits zero and counts the scenario as proved

  Scenario: A recipe proof naming an unknown recipe fails
    Given a scenario tagged @by: with a name the justfile has no recipe for
    When the scenarios check runs
    Then it exits non-zero and names the scenario and the tag

  Scenario: A recipe proof on a pending scenario fails
    Given a scenario tagged both pending with its issue key and @by: with an existing recipe
    When the scenarios check runs
    Then it exits non-zero and names the scenario and the tag

  Scenario: A recipe proof without just on PATH fails
    Given a scenario tagged @by: a recipe, and no just on PATH
    When the scenarios check runs
    Then it exits non-zero and says just is not on PATH

  Scenario: A scenario with more than one proof fails
    Given a scenario with a bats test of its title and an OpenTofu run of its slug, and another with a @by: recipe tag and a bats test of its title
    When the scenarios check runs
    Then it exits non-zero and names each scenario with both of its proofs

  Scenario: Pending inherited from the feature's tags counts
    Given a feature tagged pending with its issue key, whose scenarios have no tags and no proofs of their own
    When the scenarios check runs
    Then it exits zero and counts every scenario as pending

  Scenario: A scenario whose title starts with a digit is told to use bats or a recipe
    Given a scenario without a proof whose title starts with a digit
    When the scenarios check runs
    Then it exits non-zero, names the scenario and says an OpenTofu run cannot prove it
