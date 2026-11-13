Feature: Repository checks
  The repository is public and built with pinned tools. `just ci` proves both.

  Scenario: A tracked file with an address literal fails the check
    Given a tracked file containing an IPv4 address that is not on the allowlist
    When the address-literal check runs
    Then it exits non-zero and names the file, the line and the literal

  Scenario: Documentation ranges and declared literals pass the check
    Given tracked files containing only documentation-range addresses, loopback, the unspecified address, the link-local metadata address, netmask-looking literals starting 255. and literals declared in the allowlist file
    When the address-literal check runs
    Then it exits zero

  Scenario: Fixture paths are not scanned
    Given a file under the fixtures path containing an arbitrary IPv4 address
    When the address-literal check runs
    Then it exits zero

  Scenario: A version string is not an address
    Given a tracked file containing a dotted version such as v1.14.6 or 2.10.0
    When the address-literal check runs
    Then it exits zero

  Scenario: Dotted numbers longer than an address are not flagged
    Given a tracked file containing OIDs such as 1.3.6.1.4.1.11129.2.4.2 and versions with more than four parts
    When the address-literal check runs
    Then it exits zero

  Scenario: Addresses at the start of a line, side by side and in URLs fail the check
    Given a tracked file with an IPv4 address at the start of a line, two next to each other and one inside a URL
    When the address-literal check runs
    Then it exits non-zero and names every one of them

  Scenario: An address after an escape sequence fails the check
    Given a tracked file with IPv4 addresses right after \n, \t and \r escape sequences
    When the address-literal check runs
    Then it exits non-zero and names every one of them

  Scenario: A line with a byte that is not UTF-8 is still scanned
    Given a tracked file whose line holding an IPv4 address also holds a byte that is not valid UTF-8
    When the address-literal check runs
    Then it exits non-zero and names the literal

  Scenario: A symlink out of the repository is not followed by the address check
    Given a tracked symlink to a file outside the repository that holds an IPv4 address
    When the address-literal check runs
    Then it exits zero

  Scenario: The secrets scan does not follow symlinks
    Given an untracked symlink to a file outside the repository
    When the secrets scan runs
    Then the file outside the repository is not scanned

  Scenario: The secrets scan reads files whose names start with a dash
    Given an untracked file named -n.txt
    When the secrets scan runs
    Then it exits zero and the file is scanned

  Scenario: Lint covers only the files git would commit
    Given a tracked YAML file and a YAML file that git excludes through .git/info/exclude
    When lint runs
    Then yamllint is given the tracked file and not the excluded one

  Scenario: A mise error stops the recipes
    Given mise fails to read the repository's pins
    When a recipe runs
    Then it fails and shows mise's error

  Scenario: A tool that differs from its pin fails the tools check
    Given a pinned tool whose binary on PATH reports another version
    When the tools check runs
    Then it exits non-zero and names the tool, the pinned version and the found version

  Scenario: A missing pinned tool fails the tools check
    Given a pinned tool that is not installed
    When the tools check runs
    Then it exits non-zero and names the tool and how to install it

  Scenario: Matching tools pass the tools check
    Given every pinned tool is installed at its pinned version
    When the tools check runs
    Then it exits zero

  Scenario: A mise.toml with no readable pins fails the tools check
    Given a mise.toml whose pins are not name = "version" lines under a [tools] section
    When the tools check runs
    Then it exits non-zero and says no pinned tools were found
