Feature: Cluster recipes
  The cluster is created and changed by recipes that check before they act.

  Scenario: The age key is created once and never printed
    Given SOPS_AGE_KEY_FILE naming a path outside the repository where no key exists
    When cluster-age-key runs, and then runs again
    Then the key file is created with mode 0600 and talos/.sops.yaml names its recipient, each run prints that recipient and nothing else, and the second run leaves the key and talos/.sops.yaml as they were

  Scenario: Cluster secrets are written encrypted and never regenerated
    Given the cluster's talman.yaml and talos/.sops.yaml naming the recipient of the Talos age key
    When cluster-secrets runs, and then runs again
    Then the first run writes talos/lab-sto2/secrets.sops.yaml with SOPS metadata and every value encrypted to that recipient, and the second exits non-zero without calling talman and leaves the file byte for byte as it was

  Scenario: Secrets written in plaintext fail the recipe and are kept
    Given a talman that writes the secrets bundle unencrypted
    When cluster-secrets runs
    Then it exits non-zero saying the bundle is not encrypted, leaves the file in place, and prints none of its values

  Scenario: A plaintext secrets bundle fails the check
    Given a Talos secrets bundle in plaintext at a secrets.sops.yaml under talos/ that git would commit
    When the secrets bundle check runs
    Then it exits non-zero naming the file and printing none of its values, while an encrypted bundle passes

  Scenario: No cluster secret reaches a command line or the output
    Given an age key, a secrets bundle and a kubeconfig whose secrets are known
    When every cluster recipe runs against recording tools, and in the ways each one stops
    Then no secret appears in any recorded argument list or in anything the recipes print
