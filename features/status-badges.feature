Feature: Status badges
  A handful of numbers say at a glance what the cluster is: its Kubernetes and Talos versions, its node and pod counts, its age, its CPU and memory use and whether an alert fires. kromgo serves exactly the queries its configuration names, as badges or JSON, from the cluster's Prometheus on a hostname of the public Gateway, so they can be shown without giving anyone Prometheus.

  Scenario: A cluster that does not select kromgo builds none of it, and one that selects it without what it depends on is refused
    Given the lab-sto2 overlay, which selects kromgo with two entries, the namespace directory kromgo and the application's ks.yaml
    When the overlay is built with both entries, with the application's alone out, with neither, and without each application the Kustomization names in dependsOn
    Then the overlay builds the namespace with its default deny, the defaults every namespace directory holds and the Kustomization; without the ks.yaml's entry it builds the namespace, its default deny and its defaults and nothing else of kromgo; without both it builds nothing of kromgo; and a cluster that lists the Kustomization without an application it names is refused, naming both

  Scenario: kromgo answers only the named queries, and each reads metrics the cluster scrapes
    Given the kromgo application as the lab-sto2 overlay applies it, the cluster's render with every chart expanded, and the documentation of the image's pinned version
    When its configuration, the container's environment and the metrics each query selects are read
    Then the configuration names exactly the pinned set of badges, each an instant query, and no graph, and turns the gallery off; its one Prometheus is the Service of the monitoring stack's Prometheus; the documentation names the pinned version where it cites the source that shows no request names a query; and every metric of every query is one a recording rule of the render writes, one a monitor of the render scrapes from the target that serves it, or the series written for each alerting rule

  Scenario: kromgo's numbers name no node, address or hostname
    Given the configuration of the kromgo application as the lab-sto2 overlay applies it
    When each query is read for the labels its result carries, which the JSON form of a badge returns, and for what it selects by
    Then every selector sits inside an aggregation that keeps no label but a version, no query selects by the name of a node, an address, a namespace or a pod, whether the label's name is bare or quoted, no query joins or relabels, and nothing in the configuration names the cluster's domain or holds a dotted name, as a hostname is, in a value or in a string of a query or an expression

  Scenario: kromgo is reached by its hostname on the public Gateway and holds no credential
    Given the kromgo application as the lab-sto2 overlay applies it, with two different cluster domains, and its namespace
    When its HTTPRoute, its Service, its namespace's labels and everything it builds are read
    Then the route names kromgo under the domain on the https listener of the public Gateway only, for the badge paths and the Service's main port alone, with no filter on the rule or its backend, kromgo's own namespace carries the label that lets routes attach, the application waits for the Gateway, and nothing it builds is a Secret or an ExternalSecret, no variable holds a credential, the pod mounts no service account token and Prometheus is reached without a credential

  Scenario: kromgo runs restricted from a pinned image and is scraped
    Given the kromgo application as the lab-sto2 overlay applies it and its namespace, and the configuration schema kromgo publishes at the image's tag
    When the namespace's labels and the pinned chart's rendered pods and monitors are read, and the configuration is checked against the schema
    Then the namespace enforces the restricted level, two pods on different nodes under a disruption budget run a pinned image as a non-root user with the runtime's seccomp profile, a read-only root filesystem, no capability and no privilege escalation, requests and a memory limit and a health check, mount the configuration read-only, and the one monitor scrapes the metrics port of their Service; the configuration meets the pinned version's schema, which refuses an unknown field and a badge without its query, and names that schema, and the application waits for its pods
