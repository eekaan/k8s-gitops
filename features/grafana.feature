Feature: Grafana
  One Grafana in the namespace monitoring, run by the Grafana operator, with the cluster's Prometheus
  as its datasource and the monitoring chart's dashboards, all of it from Git.

  Scenario: The Grafana operator installs and upgrades its resource definitions
    Given the grafana-operator application, enabled in the cluster's overlay
    When it is built as Flux applies it and its pinned chart is rendered offline with the repository's values
    Then it yields the operator in the namespace monitoring and every grafana.integreatly.org definition as a template of the release, each kept when the release is uninstalled, and the application is Ready only once the release is

  Scenario: The Grafana operator has its monitor on
    Given the grafana-operator application's pinned chart and values, with the monitoring API present
    When the chart is rendered offline
    Then it yields one ServiceMonitor, selected by the operator's metrics Service on the port it scrapes, and the application names prometheus-operator-crds in dependsOn

  Scenario: One Grafana runs from the operator at a pinned version
    Given the grafana application, enabled in the cluster's overlay
    When it is built as Flux applies it
    Then it yields exactly one Grafana, in the namespace monitoring, at an exact Grafana version that Renovate updates, with one replica and no disruption budget, and the application starts only once the operator's definitions are established

  Scenario: Grafana keeps nothing that Git does not hold
    Given the grafana application
    When it is built as Flux applies it and its dashboards chart is rendered offline
    Then neither the Grafana nor anything else in it claims a volume, and its datasource and every dashboard are applied to Grafana again at least every minute, so a restarted Grafana has them all back

  Scenario: Grafana reads the cluster's Prometheus
    Given the grafana application and the kube-prometheus-stack application
    When the first is built as Flux applies it and the monitoring chart is rendered offline with its values
    Then the one datasource selects the Grafana, is its default and of type prometheus, and its URL names the Prometheus Service the monitoring chart renders, in that Service's namespace, on a port the Service serves

  Scenario: Grafana shows the monitoring chart's dashboards for what the cluster runs
    Given the grafana application's dashboards release and the kube-prometheus-stack application
    When both pinned charts are rendered offline with their values
    Then the release pins the monitoring application's chart at its version, yields only dashboard ConfigMaps and one GrafanaDashboard per ConfigMap that loads it into the Grafana, and its dashboards are exactly those the monitoring chart renders for the cluster's monitoring values, less those for operating systems other than Linux

  Scenario: No dashboard is fetched from the network at run time
    Given the grafana application
    When it is built as Flux applies it and its dashboards chart is rendered offline
    Then no GrafanaDashboard loads its JSON from a URL, grafana.com, a registry or Jsonnet, and no dashboard or datasource asks for a plugin

  Scenario: Grafana's admin credential is generated in the cluster
    Given the grafana application
    When it is built as Flux applies it and its dashboards chart is rendered offline
    Then neither yields a Secret, and the Grafana sets no admin user or password and leaves the operator to generate its admin credential Secret

  Scenario: Grafana is reachable only from inside the cluster, with anonymous access off
    Given the grafana application
    When it is built as Flux applies it and its dashboards chart is rendered offline
    Then nothing in it routes to Grafana from outside the cluster, its Service is of type ClusterIP, and its configuration turns anonymous access off and keeps the login form

  Scenario: Grafana makes no call to the internet on its own
    Given the grafana application and the defaults of the Grafana release it pins
    When it is built as Flux applies it
    Then its Grafana's configuration turns off usage reporting, the checks for Grafana and plugin updates, the news feed, the plugin catalogue, the plugins Grafana installs at every start, the download of plugin signing keys, Gravatar images and external snapshots, each by a key that release's defaults define with the setting that calls out

  Scenario: Grafana has its monitor on
    Given the grafana application
    When it is built as Flux applies it
    Then it yields one ServiceMonitor, which selects the labels the Grafana gives its Service and scrapes the port the operator names grafana, and the application names prometheus-operator-crds in dependsOn
