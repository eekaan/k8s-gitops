Feature: Silences
  An alert that is known and accepted for a while is silenced by a reviewed change that says why and
  until when: a Silence object in the tree, which the silence operator turns into a silence in the
  cluster's Alertmanager and removes again when the object goes.

  The check of the tree's silences catches a silence added by mistake or carelessly; a change that
  hides one on purpose is for the pull request's review to catch.

  Scenario: The silence operator is selected by one overlay entry and builds nothing when it is not
    Given the silence-operator application, listed once in the cluster's overlay
    When the overlay is built with the entry and again without it
    Then the build with it yields the application's Kustomization, which waits and names prometheus-operator-crds in dependsOn, and the build without it yields nothing of the application

  Scenario: The silence operator keeps its resource definitions when the release goes
    Given the silence-operator application's pinned chart and values
    When the chart is rendered offline with its resource definitions included
    Then it yields both Silence definitions as templates of the release, each kept when the release is uninstalled

  Scenario: The silence operator runs hardened with requests and limits
    Given the silence-operator application's pinned chart and values
    When the chart is rendered offline
    Then its one Deployment runs one replica of a pinned image as a non-root user, with a read-only root filesystem, no capability, no privilege escalation, the runtime's default seccomp profile, and requests and a memory limit

  Scenario: The silence operator reaches Alertmanager by its Service inside the cluster and holds no credential
    Given the silence-operator application's and the monitoring application's pinned charts and values
    When the charts are rendered offline
    Then the operator's Alertmanager address is the name of the Service the monitoring chart renders, in its namespace and on the port that leads to Alertmanager's web port, whose selector names the chart's Alertmanager and picks its pods, with no address literal in it, and the operator sends Alertmanager no token, reads no Secret, mounts no volume and is bound, by one ClusterRoleBinding to its own service account, to every verb on Silence objects and on Leases in every namespace and create on events, and to nothing else

  Scenario: The silence operator's metrics are scraped
    Given the silence-operator application's pinned chart and values, with the monitoring API present
    When the chart is rendered offline
    Then it yields one PodMonitor, selected by the operator's pod on the port it serves metrics, and the application names prometheus-operator-crds in dependsOn

  Scenario: A silence in the tree says why, names its alert and has an end or an issue
    Given the Silence objects of the tree's render, which builds each Kustomization whose source is the cluster's artifact with its components, follows no Kustomization whose source is a GitRepository, a Bucket or another OCIRepository, and renders each chart with the values of the ConfigMaps Flux builds for its own application, and of the app/ of every application under apps/base
    When each is read against the silence rules, and the render against the constructions it does not expand as the cluster would
    Then each carries a reason and either an end date or an issue key, names an alert other than the Watchdog in an exact alertname matcher, which is not wider than one alert, and a Silence without any of these, or one the render holds that is not a resource of the app/ of the application applying it, such as one a chart renders or a component adds, is refused
    And an object of a kind ending in List that has items, a HelmRelease's valuesFrom entry that is optional or names no object Flux builds for its application, and a Flux Kustomization, HelmRelease or source that a chart renders are refused, as the render does not read the objects they make the cluster apply
