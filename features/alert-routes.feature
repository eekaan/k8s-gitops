Feature: Alert routes
  Alertmanager sends a critical or warning alert to a notification webhook and the Watchdog to a
  heartbeat URL, each address read from a file of one Secret that External Secrets fills from the
  secret store. Until the two URLs are in the store the files are not there, Alertmanager runs
  without them and nothing leaves the cluster.

  Scenarios tagged by:alerts-route-check are proved by just alerts-route-check, which runs amtool
  and Alertmanager, from the image the chart deploys, on the configuration the chart renders: each
  has one entry in tests/alert-routes/cases.yaml, named with its title, of a kind the check runs
  (a route, an inhibition, the start, a silence), with its alerts and what is expected of each. A
  bats test fails when a tagged scenario has no entry of its name, or an entry names no tagged
  scenario.

  @by:alerts-route-check
  Scenario: A critical alert reaches notify
    Given the configuration the chart renders for Alertmanager
    When amtool resolves the receivers of an alert whose severity is critical
    Then it resolves to the receiver notify alone

  @by:alerts-route-check
  Scenario: A warning alert reaches notify
    Given the configuration the chart renders for Alertmanager
    When amtool resolves the receivers of an alert whose severity is warning
    Then it resolves to the receiver notify alone

  @by:alerts-route-check
  Scenario: The Watchdog reaches heartbeat and nothing else
    Given the configuration the chart renders for Alertmanager
    When amtool resolves the receivers of the Watchdog with the labels its rule gives it, and again with its severity set to critical
    Then it resolves to the receiver heartbeat alone both times, so its route comes before the route of the severities and does not continue

  @by:alerts-route-check
  Scenario: An info alert reaches nothing
    Given the configuration the chart renders for Alertmanager
    When amtool resolves the receivers of an alert whose severity is info, and of the info inhibitor
    Then each resolves to the receiver null alone, which sends nothing

  @by:alerts-route-check
  Scenario: A critical alert inhibits the warning of the same name and namespace, and no other
    Given the image's Alertmanager running the rendered configuration on the loopback
    When it holds a critical alert, a warning alert of the same name and namespace, one of the same name in another namespace and one of another name in the same namespace
    Then the warning of the same name and namespace is inhibited by the critical alert, and neither of the other two is inhibited

  @by:alerts-route-check
  Scenario: Alertmanager starts without its destinations and sends nothing
    Given the image's Alertmanager and the rendered configuration, with no file at either path the receivers read their address from
    When it starts on the loopback and is given the Watchdog and a critical alert
    Then it loads the configuration and becomes ready, each notification fails on the file it cannot read, which its log says, and every notification it attempts is counted as failed

  @by:alerts-route-check
  Scenario: A silence mutes an alert on its way to notify and leaves the Watchdog firing
    Given the image's Alertmanager running the rendered configuration on the loopback, with a silence of one alert name made through the API the silence operator uses
    When it holds a warning alert of that name and the Watchdog
    Then the warning alert, whose receiver is notify, is suppressed by that silence, and the Watchdog, whose receiver is heartbeat, stays active

  Scenario: No receiver's address is in the tree: each is a file of the Secret Alertmanager mounts
    Given the alert-destinations application as Flux builds it and the kube-prometheus-stack application's pinned chart rendered with the repository's values
    When the Secret's name and keys are read from the ExternalSecret, the volume from the rendered Alertmanager and the receivers from the rendered configuration
    Then notify and heartbeat each hold one webhook with a url_file and send_resolved and nothing else, heartbeat's send_resolved false, each url_file is the key named after its receiver in the directory where the Alertmanager mounts that Secret as an optional read-only volume with no subPath, and the configuration holds no URL

  Scenario: The destinations are one Secret from the store, selected by one overlay entry, and nothing waits for it
    Given the alert-destinations application, listed once in the cluster's overlay
    When it is built as Flux applies it, and the overlay is built with the entry and again without it
    Then it yields one ExternalSecret that reads the two properties of monitoring/alert-destinations from the store openbao by two data entries into the Secret alert-destinations, its Kustomization names openbao-store in dependsOn and does not wait, no Kustomization names it in dependsOn, the build without the entry yields nothing of it, and the catalogue holds it as a Resource of the system observability

  Scenario: Alertmanager's configuration is the one the values state, of a shape the pinned operator reads
    Given the kube-prometheus-stack application's values and its pinned chart rendered with them, the tree's render and every application's app/ directory
    When the configuration in the Secret the rendered Alertmanager reads is compared with the values' and its keys are read at every position
    Then the two are equal as data, with the chart's own inhibit rules, templates and root timings, the keys at every position are the set recorded when each was read against the operator's own types, at the operator version the chart runs, and no AlertmanagerConfig object is in the render or in an application

  Scenario: Every alert the tree renders has a place in the route tree
    Given every alert rule of the tree's render, the charts' and the tree's own, and the route cases of the check
    When each rule's severity is read
    Then each is critical, warning or info, or the rule is the Watchdog or the info inhibitor, a rule with any other severity is refused by name, and the route cases hold an alert of each of the five with the labels the rendered rules give the Watchdog and the info inhibitor

  Scenario: The routes are checked with the Alertmanager image the chart deploys, in the static group of just ci
    Given the justfile, the Dagger module and the kube-prometheus-stack application's pinned chart
    When the image alerts-route-check runs and the image the rendered Alertmanager names are read, and the check is run with a stand-in for the image's shell
    Then alerts-route-check and just ci name one Alertmanager image, pinned by digest, the one the chart deploys, under the comment by which Renovate moves its tag and digest, the module names none of its own, the check fails when the render names another image, and a stand-in that prints nothing fails every case
