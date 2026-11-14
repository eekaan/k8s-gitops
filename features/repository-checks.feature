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

  Scenario: Only the address check's own fixtures are not scanned
    Given a file under tests/fixtures/check-address-literals/ and a file elsewhere under tests/fixtures/, each with an IPv4 address outside the allowed ranges
    When the address-literal check runs
    Then it exits non-zero naming the second file and not the first

  Scenario: Files git would commit are scanned and files it ignores are not
    Given an untracked file, and files git ignores through .gitignore and .git/info/exclude such as an agent's worktree under .claude/, each with an IPv4 address outside the allowed ranges
    When the address-literal check runs
    Then it exits non-zero naming the untracked file and none of the ignored ones

  Scenario: A commit message with an address literal fails the check
    Given commits after the default branch whose messages hold an IPv4 address outside the allowed ranges and one inside them, and such an address in a commit on the default branch
    When the commit message check runs
    Then it exits non-zero naming the commit, the line and the literal after the default branch, and nothing else; without a default branch it exits zero saying so

  Scenario: The commit message check finds the default branch in a CI checkout
    Given a checkout as a CI job makes it: remote branches fetched, no default branch named for the remote, no local main, and a commit after the remote's main whose message holds an IPv4 address outside the allowed ranges
    When the commit message check runs
    Then it exits non-zero naming the commit and the literal

  Scenario: The secrets scan exempts only the address check's fixtures
    Given a key in the shape of a cloud access key under tests/fixtures/check-address-literals/ and under another fixtures directory
    When the secrets scan runs
    Then it exits non-zero naming the second file and not the first

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

  Scenario: An agent's worktree under .claude/ is ignored in a plain clone
    Given the repository's .gitignore and no exclude file of the checkout's own
    When git is asked about a file in a worktree under .claude/worktrees/
    Then git ignores it, so no check and no commit takes it

  Scenario: Lint covers only the files git would commit
    Given a tracked YAML file and a YAML file that git excludes through .git/info/exclude
    When lint runs
    Then yamllint is given the tracked file and not the excluded one

  Scenario: A mise error stops the recipes
    Given mise fails to read the repository's pins
    When a recipe runs
    Then it fails and shows mise's error

  Scenario: The Talos and OpenTofu checks refuse a tool that differs from its pin
    Given a pinned tool whose binary on PATH reports another version
    When just talos-check or just infra-check runs on its own
    Then it exits non-zero naming the tool, and the check itself does not start

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
