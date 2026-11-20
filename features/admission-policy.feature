Feature: Admission policy
  Kyverno and Gatekeeper, two admission policy engines, each an application a cluster's overlay
  selects on its own, run side by side, each holding in audit the same three rules written for its
  own engine: an image is pinned by a digest or an exact tag, a pod in a namespace that enforces
  the restricted Pod Security level sets what restricted requires, and a namespace carries a Pod
  Security level label. Each rule mirrors a rule the tree's own checks enforce before a change is
  merged, so the engines report what is applied to a cluster by hand, by an operator or by a chart
  at run time against rules the tree already keeps. Kyverno also holds one rule of its own that
  refuses: a pod created in a namespace labelled with a sandbox tier runs with that tier's
  isolation. Neither engine mutates an object or holds up the cluster, and that refusal fails open.

  Scenario: Each policy engine is selected on its own and builds nothing when it is not
    Given the lab-sto2 overlay, with the applications of one engine taken out of it and then those of the other
    When the overlay is built, and each application's dependencies are read
    Then the engine left in builds whole, the engine taken out leaves no object in the build, no application of the tree depends on either engine, and an engine's rules depend on that engine alone

  Scenario: Kyverno's release renders each key once and keeps every definition when the release goes
    Given Kyverno's pinned chart and values, rendered offline with the release's post-renderer
    When the chart's output is parsed strictly, as the render parses a chart's output, and its definitions are read
    Then no mapping repeats a key, and every definition carries the annotation that makes Helm leave it in place on uninstall

  Scenario: Gatekeeper's constraints are applied by an application that waits for their templates' kinds
    Given the lab-sto2 overlay and the applications of Gatekeeper's rules
    When the overlay is built and each application's objects and health checks are read
    Then the templates are one application, ready when each template's status says its kind was created, the constraints are another that depends on it alone, and the kinds the templates make are those of the constraints

  Scenario: The engines' webhooks fail open, skip the system namespaces and refuse nothing but what the sandbox tier rule refuses
    Given each engine's pinned chart and values, rendered offline, and the policies applied with it
    When the webhook configurations, the settings that decide the ones the engine makes at run time, and every policy are read
    Then every webhook Gatekeeper registers has the failure policy Ignore, a timeout of three seconds and skips kube-system, flux-system and its own namespace, no Kyverno policy sets a timeout and Kyverno's own timeout is at most its default of 10 seconds, Kyverno's settings force the failure policy Ignore on the webhooks that match resources and skip the same three namespaces, Kyverno's resource filters leave out the namespaces the docs name and nothing narrows Gatekeeper's audit, no engine mutates or generates, and every shared rule is in audit or dry-run, and the one Kyverno rule that refuses is the sandbox tier rule, failing open, and the docs list the webhooks Kyverno makes on its own policy kinds with the failure policy of each

  Scenario: Both engines hold the same three rules, in audit, and the tree's own render passes them
    Given the rules of each engine, the render of the tree and the namespaces it holds
    When each engine evaluates the pods and namespaces of the render, with a pod and a namespace that break each rule added
    Then both engines hold rules of the same three names, each naming the offline check of the tree it mirrors, the render passes every rule in both, and each added object fails the rule it breaks in both

  Scenario: Each rule fails the object it is written to catch, in each engine's own test
    Given each rule's test in Kyverno's and in Gatekeeper's own test tool, with an object the rule accepts and an object it refuses
    When the tools run the tests
    Then every test passes, and each refused object is reported with its rule's message, not excluded

  Scenario: A namespace labelled with a sandbox tier admits only pods with that tier's isolation, in Kyverno's own test
    Given the sandbox-tier cases in Kyverno's own test tool, with the labels of their namespaces in its values file
    When kyverno test runs them
    Then every pass- pod is admitted, every skip- pod is excluded, and every fail- pod is refused with the message of its tier or of an unknown tier, for each of the three tiers

  Scenario: The sandbox tier rule refuses at admission in every namespace that can carry the label, fails open and matches no namespace of the tree
    Given the sandbox-tier policy, Kyverno's pinned chart rendered offline with the tree's values, the lab-sto2 overlay and the docs
    When they are read
    Then the policy denies and fails open, matches only pods created in a namespace where the label exists, has no pod controller rules, names its offline check and holds its four validations with their messages in order, Kyverno evaluates every requester but the kubelets' group, no namespace that Kyverno's webhooks skip or its resource filters drop carries the label, no namespace of the overlay carries it, and the docs state the contract in Runtime classes, Pod Security, Adding an application and Admission policy

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
