Feature: Admission policy
  Kyverno and Gatekeeper, two admission policy engines, each an application a cluster's overlay
  selects on its own, run side by side in audit, each holding the same three rules written for its
  own engine: an image is pinned by a digest or an exact tag, a pod in a namespace that enforces
  the restricted Pod Security level sets what restricted requires, and a namespace carries a Pod
  Security level label. Each rule mirrors a rule the tree's own checks enforce before a change is
  merged, so the engines report what is applied to a cluster by hand, by an operator or by a chart
  at run time against rules the tree already keeps. Neither engine refuses an object, mutates one or
  holds up the cluster.

  Scenario: Each policy engine is selected on its own and builds nothing when it is not
    Given the lab-sto2 overlay, with the applications of one engine taken out of it and then those of the other
    When the overlay is built, and each application's dependencies are read
    Then the engine left in builds whole, the engine taken out leaves no object in the build, no application of the tree depends on either engine, and an engine's rules depend on that engine alone

  Scenario: Neither engine's webhooks can refuse or delay a workload: the ones that match workloads fail open and skip the system namespaces
    Given each engine's pinned chart and values, rendered offline, and the policies applied with it
    When the webhook configurations, the settings that decide the ones the engine makes at run time, and every policy are read
    Then every webhook Gatekeeper registers has the failure policy Ignore, a timeout of three seconds and skips kube-system, flux-system and its own namespace, no Kyverno policy sets a timeout and Kyverno's own timeout is at most its default of 10 seconds, Kyverno's settings force the failure policy Ignore on the webhooks that match resources and skip the same three namespaces, Kyverno's resource filters leave out the namespaces the docs name and nothing narrows Gatekeeper's audit, no engine mutates or generates, and every rule is in audit or dry-run, and the docs list the webhooks Kyverno makes on its own policy kinds with the failure policy of each

  Scenario: Both engines hold the same three rules, in audit, and the tree's own render passes them
    Given the rules of each engine, the render of the tree and the namespaces it holds
    When each engine evaluates the pods and namespaces of the render, with a pod and a namespace that break each rule added
    Then both engines hold rules of the same three names, each naming the offline check of the tree it mirrors, the render passes every rule in both, and each added object fails the rule it breaks in both

  Scenario: Each rule fails the object it is written to catch, in each engine's own test
    Given each rule's test in Kyverno's and in Gatekeeper's own test tool, with an object the rule accepts and an object it refuses
    When the tools run the tests
    Then every test passes, and each refused object is reported with its rule's message, not excluded

  Scenario: Each engine is pinned to an exact chart version that Renovate can update
    Given the kyverno and gatekeeper applications' sources
    When the lab-sto2 overlay and each application's source are read
    Then the overlay applies each engine and its rules, and each chart is pinned to an exact version that Renovate can update

  Scenario: Each engine's pods keep running while a node is drained, request their memory and pass the restricted level
    Given the rendered chart of each engine
    When its pod templates, disruption budgets and namespace are read
    Then the controllers that admit objects run two replicas that the scheduler spreads over nodes under a budget that keeps one running, every container requests CPU and memory, the namespace enforces the restricted level, and no pod template breaks it

  Scenario: Each engine's metrics are scraped and each engine's findings can be read
    Given the rendered chart of each engine, with the monitoring API present, and the docs
    When the monitors are matched with what they select, and the docs are read
    Then every monitor selects pods of its own render through a port they expose, each engine names prometheus-operator-crds in dependsOn, and the docs say how to read each engine's findings
