Feature: Alerts
  An application carries its own alert rules beside its manifests, and a check proves each rule
  both ways before it merges: promtool, in the image of the Prometheus the cluster runs, validates
  every rule the tree renders and runs the rules' unit tests, one file per application in
  tests/rules/.

  A rule promtool refuses is proved by rules-check itself, in just rules-check and in just ci alike:
  it breaks, one at a time, a chart's rule and an own alert in rule files no unit test loads, so
  that only promtool's check rules reads them, and requires check rules to refuse each, naming it.

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
    Given a rendered tree with, in a rule file no unit test loads, a chart's rule or an own alert whose expression promtool cannot parse, or an own alert defined twice
    When the rules are checked with promtool
    Then the check fails, and promtool's check rules of the charts' or of the tree's own rules names the rule

  Scenario: An alert without a test in which it fires, or without one in which it stays quiet, fails the check
    Given the tree's own rules and a unit test file that lacks, for one alert, a test with an alert expected, a test with none expected one evaluation before the first in its group with the alert expected, or a test with none expected at a time before it fires when every series of its test group has a sample
    When the rules are collected for the check
    Then the check fails, naming the alert and which test it lacks

  Scenario: An alert without a known severity, a summary, a description or a runbook heading that exists fails the check
    Given the tree's own rules, one alert at a time with its severity, summary, description or runbook link broken
    When the rules are collected for the check
    Then the check fails, naming the alert and what is wrong, for a severity outside critical, warning and info, a missing summary, a description that names nothing from the alert's labels, a link that is not to a runbook of this repository, and a link whose heading is gone

  Scenario: The rules are checked with the Prometheus image the chart deploys, in the static group of just ci
    Given the justfile, the Dagger module and the kube-prometheus-stack application's pinned chart
    When the image rules-check runs and the image the rendered Prometheus names are read, and again with the chart naming another tag
    Then rules-check runs in the static group of just ci, and just rules-check with no network, with promtool taken from that image, which no pin in the tree names, and the chart naming another tag gives the check that tag's image

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

  @by:rules-check
  Scenario: The alert CertManagerCertificateNotReady fires after its time in the failing case and stays quiet in the healthy one
    Given a Certificate that stops being Ready, and one that is Ready throughout
    When the rule is evaluated over time
    Then the alert fires after an hour for the Certificate that is not Ready and never for the one that is

  @by:rules-check
  Scenario: The alert CertManagerCertificateExpiringSoon fires after its time in the failing case and stays quiet in the healthy one
    Given a Certificate whose certificate ends within 14 days, and one that ends in 60 days
    When the rule is evaluated over time
    Then the alert fires after its time for the first and never for the second

  @by:rules-check
  Scenario: The alert EtcdSnapshotStale fires after its time in the failing case and stays quiet in the healthy one
    Given the snapshot CronJob whose last success is older than 13 hours, one that has never succeeded, and one that succeeded within 13 hours
    When the rule is evaluated over time
    Then the alert fires after its time for the first two and never for the third

  @by:rules-check
  Scenario: The alert EtcdSnapshotJobFailing fires after its time in the failing case and stays quiet in the healthy one
    Given the snapshot CronJob whose latest scheduled run ended without success, and one whose latest run succeeded
    When the rule is evaluated over time
    Then the alert fires after its time for the first and never for the second

  Scenario: Flux's controllers and the state of its resources are scraped
    Given the flux-monitoring application, enabled in the cluster's overlay after the monitoring definitions, the Flux Operator's chart as the cluster directory installs it, and Flux's controllers as the instance installs them
    When it is built as Flux applies it and the monitors are matched against what they select
    Then a ServiceMonitor selects the operator's metrics Service, whose port serves the state of every Flux resource, and a PodMonitor selects the four controllers' metrics port and the source-watcher's, and the operator reports on an interval the alerts' times can rely on

  @by:rules-check
  Scenario: The alert FluxRootSyncNotReady fires after its time in the failing case and stays quiet in the healthy one
    Given the Kustomizations flux-system and cluster and the OCIRepository flux-system, the root sync, one of which is not Ready, and one set that is Ready
    When the rule is evaluated over time
    Then the alert fires after its time for each root object that is not Ready, whatever the reason, and never while all of them are Ready

  @by:rules-check
  Scenario: The alert FluxRootSyncNotReady fires while the root sync alternates between failing and progressing
    Given the Kustomization flux-system, which the operator reports False for three minutes and Unknown, progressing, for one at each retry, with every label it writes, and the OCIRepository flux-system, Ready and progressing for a minute each time main moves
    When the rule is evaluated over time
    Then the alert fires after its time for the Kustomization, once, and keeps firing, and never for the OCIRepository

  @by:rules-check
  Scenario: The alert FluxApplierNotReady fires after its time in the failing case and stays quiet in the healthy one
    Given a Kustomization and a HelmRelease that are not Ready, one that waits for another, the root sync that is not Ready, and ones that are Ready
    When the rule is evaluated over time
    Then the alert fires after its time for the Kustomization and the HelmRelease that are not Ready, and never for the one that waits for a dependency, for the root sync, which has its own alert, or for the Ready ones

  @by:rules-check
  Scenario: The alert FluxApplierNotReady fires while a Kustomization alternates between progressing and failing its health checks
    Given a Kustomization that fails its health checks, which the operator reports Unknown, progressing, for three minutes and False for one at each retry, with every label it writes, and a Ready Kustomization that is progressing for two minutes each time its artifact has a new revision
    When the rule is evaluated over time
    Then the alert fires after its time for the failing one, once, and keeps firing, and never for the Ready one

  @by:rules-check
  Scenario: The alert FluxSourceNotReady fires after its time in the failing case and stays quiet in the healthy one
    Given an OCIRepository, a HelmRepository and an ArtifactGenerator that are not Ready, the root sync's OCIRepository that is not Ready, and ones that are Ready
    When the rule is evaluated over time
    Then the alert fires after its time for each source that is not Ready, and never for the root sync's, which has its own alert, or for the Ready ones

  @by:rules-check
  Scenario: The alert FluxSourceNotReady fires while a source alternates between failing and progressing
    Given an OCIRepository that cannot be fetched, which the operator reports False for two minutes and Unknown, progressing, for one at each retry, with every label it writes, and a Ready OCIRepository
    When the rule is evaluated over time
    Then the alert fires after its time for the failing one, once, and keeps firing, and never for the Ready one

  @by:rules-check
  Scenario: The alert FluxResourceSuspended fires after its time in the failing case and stays quiet in the healthy one
    Given a Flux resource that is suspended, the FluxInstance suspended by its reconcile annotation, and a resource that is not suspended
    When the rule is evaluated over time
    Then the alert fires after a day for the suspended resource and the FluxInstance and never for the one that is not

  @by:rules-check
  Scenario: The alert FluxResourceSuspended keeps its time while the operator restarts
    Given a Kustomization suspended from the start, whose series the operator's restart leaves stale for two minutes before the new pod reports it with its own labels, and which is resumed after a day
    When the rule is evaluated over time
    Then the alert fires a day after the suspension, and is gone within 10 minutes of the resume

  @by:rules-check
  Scenario: The alert FluxInstanceNotReady fires after its time in the failing case and stays quiet in the healthy one
    Given a FluxInstance that is not Ready and one that is Ready
    When the rule is evaluated over time
    Then the alert fires after its time for the one that is not Ready and never for the one that is

  @by:rules-check
  Scenario: The alert FluxOperatorNotReady fires after its time in the failing case and stays quiet in the healthy one
    Given a Flux Operator Deployment with no available replica, and one with an available replica
    When the rule is evaluated over time
    Then the alert fires after its time for the Deployment with none and never for the one with a replica

  Scenario: The workers' BGP sessions are scraped without changing how Cilium is first installed
    Given the cilium-monitoring application, enabled in the cluster's overlay after Cilium and the monitoring definitions, and the Cilium chart rendered with the values scripts/install-cilium installs from
    When the application is built as Flux applies it, the chart is rendered with the monitoring APIs present, and the monitor is matched against what it selects
    Then a PodMonitor selects the agents' metrics port, the install values make the chart render no monitor of any kind and the agents serve their metrics, and the agents' metrics port is one the nodes' firewall admits from the nodes and the pods

  @by:rules-check
  Scenario: The alert CiliumBGPSessionsDown fires after its time in the failing case and stays quiet in the healthy one
    Given two workers each with a session to each of two edge routers, one of which is not established on one worker
    When the rule is evaluated over time
    Then the alert fires after its time for the worker with the session down, naming the worker and the count and no address, and never while every session is established

  @by:rules-check
  Scenario: The alert CiliumBGPSessionsDown stays quiet while a worker is out of BGP on purpose
    Given a worker whose sessions are shut down and whose agent then reports no session at all, as when the label that takes it out of BGP is set, and a worker whose sessions are established
    When the rule is evaluated over time
    Then the alert does not fire

  @by:rules-check
  Scenario: The alert CiliumBGPNoSessionEstablished fires after its time in the failing case and stays quiet in the healthy one
    Given workers whose sessions all go down, then recover, then whose agents report no session while the workers' agents are scraped
    When the rule is evaluated over time
    Then the alert fires after its time in each of the two failing cases and never while a session is established

  @by:rules-check
  Scenario: The alert CiliumBGPNoSessionEstablished stays quiet while only the control planes' agents are scraped
    Given a control plane's agent that is scraped and reports no session, as no control plane has a BGP instance, its node's role control-plane from kube-state-metrics, and workers' agents that are not scraped
    When the rule is evaluated over time
    Then the alert does not fire

  Scenario: The storage layer is scraped
    Given the linstor-monitoring application, enabled in the cluster's overlay after the monitoring definitions, and the Piraeus operator at the version whose templates the monitors' selectors were read from
    When it is built as Flux applies it and the monitors are matched against the labels and ports the operator gives the LINSTOR controller and the satellites
    Then a ServiceMonitor selects the controller's metrics port, which serves LINSTOR's own state, and a PodMonitor selects the satellites' DRBD reactor port, which serves each DRBD resource's state, and the monitors carry the node that runs a satellite

  @by:rules-check
  Scenario: The alert DrbdReplicaNotUpToDate fires after its time in the failing case and stays quiet in the healthy one
    Given a volume with a replica that is no longer UpToDate, one whose replicas are UpToDate, and a diskless client of a volume
    When the rule is evaluated over time
    Then the alert fires after its time for the replica that is not UpToDate and never for the replicas that are, or for the diskless client

  @by:rules-check
  Scenario: The alert DrbdResourceWithoutQuorum fires after its time in the failing case and stays quiet in the healthy one
    Given a volume whose device on one node loses quorum, and one that keeps it
    When the rule is evaluated over time
    Then the alert fires after its time for the device without quorum and never for the one with it

  @by:rules-check
  Scenario: The alert LinstorSatelliteOffline fires after its time in the failing case and stays quiet in the healthy one
    Given a satellite that LINSTOR reports offline, and one that it reports online
    When the rule is evaluated over time
    Then the alert fires after its time for the offline satellite, naming the node and no address, and never for the online one

  @by:rules-check
  Scenario: The alert LinstorStoragePoolFilling fires after its time in the failing case and stays quiet in the healthy one
    Given a storage pool above 85 percent full and one below, and one that has no capacity of its own
    When the rule is evaluated over time
    Then the alert fires after its time for the pool above 85 percent and at most 95 percent and never for the others

  @by:rules-check
  Scenario: The alert LinstorStoragePoolFull fires after its time in the failing case and stays quiet in the healthy one
    Given a storage pool above 95 percent full and one below
    When the rule is evaluated over time
    Then the alert fires after its time for the pool above 95 percent and never for the one below

  Scenario: Every alert in the tree is on a metric a monitor in the render scrapes
    Given the tree's own alerts, the render of the tree and, for what an operator makes at run time, the labels and ports its pinned version gives
    When each metric an alert reads is matched with the monitor that scrapes it, and the monitor with what it selects
    Then every metric is one a monitor of the render scrapes, from a Service or pod that exposes the port the monitor names, or is Prometheus' own series of the scrape, and an alert on a metric nothing scrapes fails
