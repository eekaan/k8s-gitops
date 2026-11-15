Feature: Dependency updates
  As the cluster operator I can have Renovate propose every dependency update as a pull request
  so that application patches reach the cluster without my attention while platform and major
  upgrades always wait for my review.

  Renovate reads renovate.json5 and the presets under .renovate/ from main. Automatic merging is
  one setting: the automerge value of the auto-merge switch rule in .renovate/automerge.json5.

  @by:renovate-check
  Scenario: The Renovate configuration passes the strict validator
    Given renovate.json5 and every preset under .renovate/
    When renovate-config-validator checks them with --strict as repository configuration
    Then it exits 0
    And it reports no errors, no warnings and no migration

  @by:renovate-check
  Scenario: What Renovate extracts is what the extraction record holds
    Given renovate.json5, the presets under .renovate/ and the repository's files
    When renovate-check runs Renovate's own extraction on them, offline, with the presets inlined
    Then the dependencies it extracts are those .renovate/extracted.tsv records

  @by:renovate-check
  Scenario: A change to what Renovate extracts is refused with the difference
    Given a manager's file patterns narrowed, or a "# renovate:" comment moved one line up
    When renovate-check runs Renovate's own extraction
    Then it exits 1
    And it prints the dependencies that were added or dropped

  @test
  Scenario: Every pin in the tree is extracted by a Renovate manager or listed as moved by hand
    Given .renovate/extracted.tsv, what Renovate extracts, and .renovate/by-hand.tsv, the pins moved by hand
    When the check looks for image references, OCI artifact tags, action pins and their inputs, tool versions, provider constraints and version values in the repository's files
    Then every pin it finds is extracted by a manager, under the name and at the place Renovate reads it, in a form Renovate can move, or listed
    And every pin that Renovate's custom managers read has the form of its datasource's tags

  @test
  Scenario: A finder that cannot run fails the check instead of finding no pins
    Given a grep that cannot read the patterns that find pins, or a yq that cannot read the files their names come from
    When the check runs
    Then it exits non-zero
    And it does not report that it found no pins

  @test
  Scenario: A pin added where no manager looks, and not listed, is refused, naming the file and line
    Given a file that holds an image reference, an OCI artifact tag, a digest, an action pin, a tool version, a provider version, a mise version or checksum, an action's version input or a tag that no manager extracts
    And a file that Renovate extracts other pins from holds an image reference, a chart's tag, a provider's version or another action's version input that it does not extract
    And the pin is not in .renovate/by-hand.tsv
    When the check runs
    Then it exits 1
    And it names each pin's file and line

  @test
  Scenario: A listed pin that a manager now extracts is refused
    Given .renovate/by-hand.tsv lists a pin that .renovate/extracted.tsv holds in a form Renovate can move, a checksum that moves with an extracted pin, or one that is not in its file as a value, only in a comment
    When the check runs
    Then it exits 1
    And it names the entry's line in .renovate/by-hand.tsv

  @test
  Scenario: A custom-manager pin whose value cannot match its datasource's tag form is refused
    Given a pin under a "# renovate: datasource=… depName=…" comment whose value is not the form .renovate/tag-forms.tsv records for its datasource's tags
    When the check runs
    Then it exits 1
    And it names the pin's file and line
    And a pin whose package has no recorded tag form is refused too
    And a recorded tag form that no pin reads is refused
    And an action's input that Renovate reads, whose version is not the form recorded for its tags, is refused unless .renovate/by-hand.tsv lists it

  @test @pending #FND-7
  Scenario: A Renovate configuration with an unknown option is refused
    Given renovate.json5 with the top-level option "automergeEverything" added
    When renovate-config-validator checks it with --strict as repository configuration
    Then it exits 1
    And it names "automergeEverything" as an invalid configuration option

  @test @pending #FND-7
  Scenario: Every update is proposed as a pull request
    Given automatic merging is switched off
    And an application's Helm chart under kubernetes/apps/ has a patch release that is three days old
    When Renovate runs on the repository
    Then it opens a pull request to main for that update
    And it pushes nothing to main, merges nothing and opens no Dependency Dashboard issue

  @test @pending #FND-7
  Scenario: An application's patch or minor update merges itself once auto-merge is switched on
    Given automatic merging is switched on
    And an application's Helm chart under kubernetes/apps/ has a minor release
    When the release is three days old and the required check on main has passed on its pull request
    Then Renovate merges the pull request
    And until both are true the pull request stays open

  @test @pending #FND-7
  Scenario: An update whose required check fails stays open
    Given automatic merging is switched on
    And the required check fails on the pull request for an application's patch update
    When Renovate runs on the repository
    Then the pull request stays open and unmerged, with the failed check shown on it

  @test @pending #FND-7
  Scenario Outline: A platform or major update waits for a person
    Given automatic merging is switched on
    And <dependency> in <location> has a <update> release that is three days old
    When the required check has passed on its pull request
    Then Renovate leaves the pull request open for a person to merge

    Examples:
      | dependency                      | location          | update |
      | siderolabs/talos                | versions.yaml     | patch  |
      | kubernetes/kubernetes           | versions.yaml     | patch  |
      | the Cilium chart                | kubernetes/       | patch  |
      | the Flux Operator chart         | kubernetes/       | minor  |
      | the Flux version (fluxcd/flux2) | kubernetes/       | minor  |
      | an OpenTofu provider            | infra/            | patch  |
      | talman                          | mise.toml         | patch  |
      | an application's Helm chart     | kubernetes/apps/  | major  |

  @test @pending #FND-7
  Scenario Outline: One pull request moves a cluster version and its client pin together
    Given versions.yaml sets <key> under a "# renovate: datasource=… depName=<package>" comment
    And mise.toml pins <client> at the same version
    When a newer <key> release is three days old and Renovate runs on the repository
    Then one pull request updates <key> in versions.yaml and <client> in mise.toml to that release

    Examples:
      | key        | client   | package               |
      | talos      | talosctl | siderolabs/talos      |
      | kubernetes | kubectl  | kubernetes/kubernetes |

  @edge @test @pending #FND-7
  Scenario: A release without a publish date never merges itself
    Given automatic merging is switched on
    And an application's image under kubernetes/apps/ has a patch release in a registry that reports no publish date
    When Renovate runs on the repository
    Then it opens a pull request for the update with renovate/stability-days pending
    And it leaves the pull request for a person to merge

  @edge @test @pending #FND-7
  Scenario: Encrypted files are never rewritten
    Given a SOPS-encrypted file app.sops.yaml under kubernetes/apps/ that contains an image reference
    When Renovate runs on the repository
    Then no pull request changes app.sops.yaml
