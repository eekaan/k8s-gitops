Feature: Cilium
  One description of the CNI, used before Flux exists and by Flux afterwards.

  Scenario: The chart renders with the repository's values
    Given the pinned chart and values.yaml
    When the chart is rendered offline
    Then it renders without error, with no kube-proxy dependency and no ServiceMonitor objects

  Scenario: The install script uses the chart and values Flux uses
    Given the application's ocirepository.yaml and values.yaml
    When the install script runs against a recording helm
    Then helm is asked to install release cilium in kube-system from that chart location and version with that values file

  Scenario: The install script waits for the API server and the nodes
    Given an API server that answers on the third attempt
    When the install script runs against recording tools
    Then it retries until the API answers, installs, and waits for the nodes to be Ready

  Scenario: A failing install names the step
    Given a helm that fails
    When the install script runs
    Then it exits non-zero and the output names the failing step

  Scenario: Flux adopts the installed release
    Given the HelmRelease
    When it is read
    Then its release name, target namespace and storage namespace are the ones the install script uses
