Feature: Flux
  Flux is described in the repository it reconciles.

  Scenario: The operator and instance charts render with the repository's values
    Given the pinned charts and their values.yaml files
    When each chart is rendered offline
    Then both render without error

  Scenario: The instance syncs this cluster's path from the main tag
    Given the rendered FluxInstance
    When its sync settings are read
    Then it reads this repository's published artifact as an OCIRepository at the main tag, and the path of the lab-sto2 cluster directory

  Scenario: The synced artifact must be signed by the publish workflow on main
    Given the rendered FluxInstance
    When its patches are read
    Then the sync source verifies a keyless signature whose issuer is GitHub Actions and whose subject is this repository's publish workflow on refs/heads/main

  Scenario: The Flux manifests are pinned to the operator's version
    Given the rendered FluxInstance and the operator's chart source
    When its distribution artifact is read
    Then it is the operator's manifests artifact at a version tag, the version of the operator's chart

  Scenario: The source-watcher runs
    Given the rendered FluxInstance
    When its components are read
    Then the source-watcher is among them

  Scenario: A failed upgrade of Flux's own releases is retried and rolled back
    Given the built Flux applications
    When their HelmReleases are read
    Then each retries a failed upgrade a few times and then rolls it back

  Scenario: Removing Flux's own applications does not uninstall Flux
    Given the built Flux applications and the rendered FluxInstance
    When their annotations are read
    Then Flux never prunes their HelmReleases or chart sources, and Helm keeps the FluxInstance when its release is uninstalled

  Scenario: The cluster directory builds only the root and Flux itself
    Given the cluster directory
    When it is built
    Then it yields the root Kustomization, the Flux Operator Kustomization and the FluxInstance Kustomization and nothing else
