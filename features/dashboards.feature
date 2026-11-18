Feature: Dashboards
  The components Prometheus scrapes that an operator reads during an incident have a dashboard in the tree, their project's own file at the pinned version or a small one written here, loaded into Grafana from the tree alone and gone with the application it describes; every metric a query names is one the cluster scrapes, or one the tree records, with the reason, as served by nothing; the documentation says which scraped applications have none; and a home dashboard says whether the cluster is healthy.

  Scenario: An application's dashboard is delivered with it and leaves with it
    Given the applications that deliver a dashboard, enabled in the cluster's overlay, and the Grafana
    When each is built as Flux applies it, and the overlay is built without the application the dashboard describes
    Then every GrafanaDashboard is in the namespace the operator watches, selects the Grafana, names its folder, is applied again every minute and loads a key of a ConfigMap of its own application or carries its JSON, which Flux does not substitute; every application but the Grafana's own and the log store's is named after the application it describes, which waits; and the overlay without that application has no Kustomization that applies its dashboard, while one that drops only the application is refused

  Scenario: A dashboard is pinned to an upstream revision the tree records, and nothing is fetched that the tree did not pin
    Given the applications that deliver a dashboard, and the dashboards among them that are written for this tree
    When they are built as Flux applies them
    Then every dashboard outside the Grafana application that is not one of those written for this tree has its source, the file of the repository the tests pin for it, its revision, its licence, which is one the tree admits, and the SHA-256 of the file at that revision recorded beside its GrafanaDashboard, the revision is that of the pinned chart of what it describes, the version of the chart directory that carries the file or, where the chart carries none, the chart's own version or its application's, the file is what the record says, Renovate's pin check lists the record as one moved by hand, every dashboard outside the Grafana application loads its JSON from a ConfigMap, the render holds a monitor of the application each describes, no GrafanaDashboard loads its JSON from a URL, grafana.com, a registry or Jsonnet or asks for a plugin, and every panel is of a type the pinned Grafana ships or turns into one it ships

  Scenario: Every dashboard has a unique identity and reads only datasources the tree defines
    Given every dashboard the tree delivers, those of the monitoring chart's release included
    When the Grafana's datasources are read from the built tree and each dashboard's JSON is parsed
    Then every dashboard has a uid no other has and a title no other in its folder has, every input its GrafanaDashboard maps is one its JSON names and maps to a datasource the tree defines or to Grafana's expression datasource, and, with those inputs replaced as the operator replaces them, every datasource reference Grafana reads is a variable that lists the type of one the tree defines, a uid or name of one, or one of Grafana's own: a panel's own, a target's unless its panel names one datasource, and any other, but not a row's or its targets'

  Scenario: The home dashboard queries only metrics the cluster scrapes
    Given the home dashboard and what the cluster's overlay renders
    When the metrics its panels query are read from their expressions
    Then each is a series a rule of the render records or one a monitor of the render scrapes, the Grafana's home is that dashboard, none queries what no monitor scrapes, and it defines no variable but its datasource

  Scenario: A dashboard too large for its delivery fails the checks
    Given the dashboards the tree delivers in ConfigMaps, and one of them padded past what a ConfigMap holds
    When their sizes are checked against the 1 MiB a ConfigMap holds
    Then every dashboard of the tree fits, and the padded one is refused, naming it

  Scenario: A dashboard the pinned chart carries is the chart's file, byte for byte
    Given the upstream dashboards whose record names the file's path in the pinned chart, and that chart as the tests pull it
    When the committed file is compared with the chart's
    Then the two are the same bytes, the recorded revision is the version of the chart directory that holds the file, the chart's own or a dependency's, the dashboards that record such a path are the ones the tests pin, and no other upstream dashboard is a file its pinned chart carries

  Scenario: Every dashboard the tree keeps queries only metrics the cluster scrapes
    Given every dashboard the tree keeps as JSON, the table of where each metric comes from, and what the cluster's overlay renders
    When the metrics are read from the expressions Grafana runs against Prometheus, of every panel, rows' panels included, of every annotation, and from the query of every variable
    Then each is a series a rule of the render records or one a row of its dashboard names, with a monitor of the render that does not drop it or, in an upstream file kept unchanged, as one nothing serves, with the reason; a metric no row names fails, naming the dashboard and the metric, as do a row that names a monitor the render lacks or that nothing reads, an expression whose metric the text does not give, by a variable inside a selector's braces among them, unless the table pins how many there are, an expression that names a metric or a label in quotes, a variable named as Grafana's own, and, in a dashboard written for this tree, a row that is not one literal name with its monitor

  Scenario: A dashboard maps each input it declares to a datasource of the type the input declares
    Given every GrafanaDashboard of the tree, the monitoring chart's included, and the datasources of the Grafana
    When the inputs its JSON declares are compared with those it maps
    Then the inputs mapped are exactly the datasource inputs declared, each mapped to a datasource of the tree of the plugin the input names, or to Grafana's expression datasource for an input of that kind

  Scenario: A dashboard written for this tree reads its series by names and jobs the cluster gives
    Given the dashboards written for this tree that an application delivers
    When each is parsed and its job matchers are compared with the jobs the render's monitors give
    Then each has its name as uid, a title, is not editable, defines no variable but one datasource variable for Prometheus, which every panel and target names, declares no input, has at most ten panels, holds no address, hostname or identifier, names no label or metric in quotes, and matches a job only by a literal that a monitor of the render gives

  Scenario: The Cilium agents' series carry the label the Cilium dashboard selects them by
    Given the Cilium agents' monitor and DaemonSet in what the cluster's overlay renders, and the Cilium dashboard
    When the label the monitor copies from the pods is compared with the dashboard's matchers
    Then the monitor names the pods' label, the pod template carries it with the value every such matcher of the dashboard has, and the series label is the one those matchers name

  Scenario: The documentation lists every dashboard and every scraped application that has none
    Given the tables of docs/kubernetes.md of the dashboards that run, of what is scraped without one and of what misses a scrape or an upstream
    When they are compared with the dashboards the tree delivers and the applications whose render holds a monitor
    Then every dashboard an application delivers is one row of the first table, with its folder, the application it describes and the revision and licence its record gives or that it is written for this tree, and every application with a monitor is named in exactly one of the three tables, which name no other
