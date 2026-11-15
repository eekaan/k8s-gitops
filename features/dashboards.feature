Feature: Dashboards
  Each application the cluster runs that has metrics in the stack has a dashboard in the tree, pinned to an upstream revision the tree records, loaded into Grafana from the tree alone; an application the overlay leaves out brings none; and a home dashboard says whether the cluster is healthy.

  Scenario: An application's dashboard is delivered with it and leaves with it
    Given the applications that deliver a dashboard, enabled in the cluster's overlay, and the Grafana
    When each is built as Flux applies it, and the overlay is built without the application the dashboard describes
    Then every GrafanaDashboard is in the namespace the operator watches, selects the Grafana, and loads a key of a ConfigMap of its own application or carries its JSON, and the overlay without the application has no Kustomization that applies its dashboard, while one that drops only the application is refused

  Scenario: A dashboard is pinned to an upstream revision the tree records, and nothing is fetched that the tree did not pin
    Given the applications that deliver a dashboard from an upstream file
    When they are built as Flux applies them
    Then each such dashboard's source, its revision, its licence and the SHA-256 of the file at that revision are recorded beside its GrafanaDashboard, the revision is the one the application's pinned chart is released at, the file is what the record says, Renovate's pin check lists the record as one moved by hand, every dashboard outside the Grafana application loads its JSON from a ConfigMap, the render holds a monitor of the application each describes, and no GrafanaDashboard loads its JSON from a URL, grafana.com, a registry or Jsonnet or asks for a plugin

  Scenario: Every dashboard has a unique identity and reads only datasources the tree defines
    Given every dashboard the tree delivers, those of the monitoring chart's release included
    When the Grafana's datasources are read from the built tree and each dashboard's JSON is parsed
    Then every dashboard has a title and a uid no other has, every input its GrafanaDashboard maps is one its JSON names and maps to a datasource the tree defines, and, with those inputs replaced as the operator replaces them, every datasource it names is a variable that lists the type of one the tree defines, a uid or name of one, or one of Grafana's own

  Scenario: The home dashboard queries only metrics the cluster scrapes
    Given the home dashboard and what the cluster's overlay renders
    When the metrics its panels query are read from their expressions
    Then each is a series a rule of the render records or one a monitor of the render scrapes, the Grafana's home is that dashboard, and none queries what no monitor scrapes

  Scenario: A dashboard too large for its delivery fails the checks
    Given the dashboards the tree delivers in ConfigMaps, and one of them padded past what a ConfigMap holds
    When their sizes are checked against the 1 MiB a ConfigMap holds
    Then every dashboard of the tree fits, and the padded one is refused, naming it
