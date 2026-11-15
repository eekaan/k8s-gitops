Feature: Alerts
  An application carries its own alert rules beside its manifests, and a check proves each rule
  both ways before it merges: promtool, in the image of the Prometheus the cluster runs, validates
  every rule the tree renders and runs the rules' unit tests, one file per application in
  tests/rules/.

  A rule promtool refuses is proved by rules-check itself, which runs promtool on an own alert whose
  expression it has broken and requires the refusal to name the alert, in just rules-check and in
  just ci alike.

  Scenarios whose title starts with "The alert" are proved by a promtool unit test: the test
  group's name in tests/rules/<application>.yaml is the scenario's title, and the scenario's
  tag by:rules-check is its proof for scenarios-check, as by:vector-check is for Vector's unit
  tests. A bats test fails when a scenario of that kind has no test group of its name, or a test
  group's name is a scenario's title that is not there.

  Scenario: An application's own rules are loaded by the monitoring stack, and leave with the application
    Given each application's PrometheusRule in its app/ directory, and the cluster's built overlay
    When the rules the overlay renders are collected, and again with an application left out of the overlay
    Then each rule is in its application's namespace and the Prometheus the stack runs selects it with no label, and the rules of an application the overlay leaves out are not collected

  @by:rules-check
  Scenario: A rule promtool refuses fails the check, naming the rule
    Given a rendered tree whose own rule has an expression promtool cannot parse
    When the rules are checked with promtool
    Then the check fails and its output names the alert

  Scenario: An alert without a test in which it fires, or without one in which it stays quiet, fails the check
    Given the tree's own rules and a unit test file that lacks, for one alert, a test with an alert expected, or a test with none expected
    When the rules are collected for the check
    Then the check fails, naming the alert and which of the two tests it lacks

  Scenario: An alert without a known severity, a summary, a description or a runbook heading that exists fails the check
    Given the tree's own rules, one alert at a time with its severity, summary, description or runbook link broken
    When the rules are collected for the check
    Then the check fails, naming the alert and what is wrong, for a severity outside critical, warning and info, a missing summary, a description that names nothing from the alert's labels, a link that is not to a runbook of this repository, and a link whose heading is gone

  Scenario: The rules are checked with the Prometheus image the chart deploys, in the static group of just ci
    Given the justfile, the Dagger module and the kube-prometheus-stack application's pinned chart
    When the image rules-check runs and the image the rendered Prometheus names are read
    Then rules-check runs in the static group of just ci with promtool taken from that image, which no pin in the tree names but the digest Dagger records for it in dagger.lock, the one entry there for that image's tag

  Scenario: The documentation lists every alert the tree defines
    Given the tree's own rules, docs/kubernetes.md and docs/runbooks/alerts.md
    When they are read
    Then the table of alerts holds each alert with its severity and runbook link, and the runbook has a section for each

  @by:rules-check
  Scenario: The alert OpenBaoMemberSealed fires after its time in the failing case and stays quiet in the healthy one
    Given a member of OpenBao that is not Ready, and one that is Ready
    When the rule is evaluated over time
    Then the alert fires after its time for the member that is not Ready and never for the one that is Ready

  @by:rules-check
  Scenario: The alert OpenBaoNoActiveMember fires after its time in the failing case and stays quiet in the healthy one
    Given a cluster where no target answers for OpenBao's active Service, and one where it does
    When the rule is evaluated over time
    Then the alert fires after its time without an active member and never with one

  @by:rules-check
  Scenario: The alert VolSyncSourceOutOfSync fires after its time in the failing case and stays quiet in the healthy one
    Given a ReplicationSource whose volume is out of sync, and one that is in sync
    When the rule is evaluated over time
    Then the alert fires after its time for the source out of sync, once, though two controllers report it, and never for the one in sync

  @by:rules-check
  Scenario: The alert VolSyncSourceMissedIntervals fires after its time in the failing case and stays quiet in the healthy one
    Given a ReplicationSource that misses an interval, and one that misses none
    When the rule is evaluated over time
    Then the alert fires after its time for the source that missed one and never for the one that missed none

  @by:rules-check
  Scenario: The alert LogCollectorOutsizedShare fires after its time in the failing case and stays quiet in the healthy one
    Given six collectors sending equal rates and one of them sending ten times the median
    When the rule is evaluated over time
    Then the alert fires after its time for the one that sends ten times the median, and never while the six send equal rates or the rates are small

  @by:rules-check
  Scenario: The alert LogCollectorOutsizedShare stays quiet while every node sends little
    Given six collectors one of which sends ten times the median, all of them under the rate below which a share says nothing
    When the rule is evaluated over time
    Then the alert does not fire

  @by:rules-check
  Scenario: The alert LogCollectorDiscardingEvents fires after its time in the failing case and stays quiet in the healthy one
    Given a collector that discards events it did not mean to, and one that discards only the audit records it drops on purpose
    When the rule is evaluated over time
    Then the alert fires after its time for the first and never for the second

  @by:rules-check
  Scenario: The alert LogCollectorSendFailing fires after its time in the failing case and stays quiet in the healthy one
    Given a collector whose sink reports errors, and one whose sink reports none
    When the rule is evaluated over time
    Then the alert fires after its time for the first and never for the second
