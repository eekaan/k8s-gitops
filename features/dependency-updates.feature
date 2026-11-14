Feature: Dependency updates
  As the cluster operator I can have Renovate propose every dependency update as a pull request
  so that application patches reach the cluster without my attention while platform and major
  upgrades always wait for my review.

  Renovate reads renovate.json5 and the presets under .renovate/ from main. Automatic merging is
  one setting: the automerge value of the auto-merge switch rule in .renovate/automerge.json5.

  @by:renovate-config-validator
  Scenario: The Renovate configuration passes the strict validator
    Given renovate.json5 and every preset under .renovate/
    When renovate-config-validator checks them with --strict as repository configuration
    Then it exits 0
    And it reports no errors, no warnings and no migration

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
