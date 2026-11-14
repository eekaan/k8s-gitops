Feature: Monitoring
  Prometheus, Alertmanager and the Prometheus Operator, from the kube-prometheus-stack chart, scrape
  the cluster's own components as far as Talos exposes them.

  Scenario: The monitoring stack builds with Flux and runs in its own namespace
    Given the kube-prometheus-stack application, enabled in the cluster's overlay
    When it is built as Flux applies it and its pinned chart is rendered with the repository's values
    Then it yields the operator, one Prometheus and one Alertmanager in the namespace monitoring, whose Pod Security level admits node-exporter's host access, and the application waits for the monitoring resource definitions

  Scenario: The monitoring chart installs no resource definitions
    Given the kube-prometheus-stack application's pinned chart and values
    When the chart is rendered offline with its resource definitions included
    Then it yields no CustomResourceDefinition, and it runs the Prometheus Operator version whose definitions the pinned prometheus-operator-crds chart installs

  Scenario: The monitoring chart installs no Grafana
    Given the kube-prometheus-stack application's pinned chart and values
    When the chart is rendered offline
    Then it yields no Grafana workload, no Grafana datasource and no dashboard object

  Scenario: Targets Talos cannot serve are switched off
    Given the kube-prometheus-stack application's pinned chart and values
    When the chart is rendered offline
    Then it yields no kube-proxy Service, ServiceMonitor or alert rule, as Cilium replaces kube-proxy

  Scenario: The control plane is scraped where Talos serves it
    Given the kube-prometheus-stack application's pinned chart and values
    When the chart is rendered offline
    Then the controller manager and the scheduler are selected by the labels Talos gives their pods and scraped over HTTPS on their secure ports, and etcd, which Talos runs outside Kubernetes, is selected through the API server's pods on the control planes and scraped over plain HTTP on port 2381 without a credential

  Scenario: Prometheus and Alertmanager keep their data on claims from the default storage class
    Given the kube-prometheus-stack application's pinned chart and values
    When the chart is rendered offline
    Then Prometheus and Alertmanager each claim a volume of a stated size that names no storage class, and Prometheus keeps its data for a stated time and below a stated size that fits its volume

  Scenario: Alerts go nowhere yet
    Given the kube-prometheus-stack application's pinned chart and values
    When Alertmanager's rendered configuration is read
    Then its only receiver is the null receiver, which every route ends in

  Scenario: Prometheus picks up every monitor and rule in the cluster
    Given the kube-prometheus-stack application's pinned chart and values
    When the rendered Prometheus is read
    Then it selects every ServiceMonitor, PodMonitor, Probe, ScrapeConfig and PrometheusRule in every namespace
