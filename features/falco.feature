Feature: Runtime detection with Falco
  Falco watches the system calls of every process on every node and names what a workload should not do: a shell spawned in a pod, a write under /etc, a read of a service account token by something that should not. It runs on every node with the least privilege its driver needs, with the rules its image ships, which nothing replaces at run time; its events are JSON lines the log collector already ships, its own metrics are scraped, and an alert fires when a rule of priority Critical or above has matched. It detects and never responds: no pod is killed or changed, and its events stay in the cluster.

  Scenario: Falco is selected by overlay entries and builds nothing when it is not
    Given the lab-sto2 overlay, which selects Falco with the namespace directory security-system and Falco's ks.yaml
    When it is built with both entries, with only the namespace directory's and with neither, and again with the monitoring definitions it needs left out
    Then with both it applies the namespace security-system, its default deny and the Kustomization falco, which waits and names prometheus-operator-crds and cilium; with only the namespace directory's it applies the namespace and its default deny and nothing of Falco; with neither, nothing of security-system; and with the definitions left out it is refused, naming falco and the missing application

  Scenario: Falco runs on every node with the modern eBPF probe and only the privileges it names
    Given the falco application built as Flux applies it and its pinned chart rendered with the repository's values
    When the DaemonSet, its Pod Security level and its entry in the exceptions list are read
    Then one pod runs on every node, control planes included, with the modern eBPF probe, no kernel module and no init container, privileged is not set, and the container adds the capabilities BPF, PERFMON, SYS_PTRACE and SYS_RESOURCE and no others, mounts of the host only its probe, its container metadata and the user and group names of its events need, every mount naming a volume of the pod, and no host path volume that nothing mounts, an empty pod security context with no annotation that relaxes a profile, and requests and limits; the namespace enforces privileged and audits and warns at restricted; and the exceptions list holds the DaemonSet with the level privileged and a reason that names each capability and host path the baseline level refuses in it

  Scenario: Falco fetches no rule, plugin or driver at run time that the tree did not pin
    Given the falco application built as Flux applies it and its pinned chart rendered with the repository's values
    When the pod's containers, the chart's values and Falco's configuration are read
    Then falcoctl neither installs nor follows an artifact and is in no container, the rules and the container plugin are the files of the Falco image, which is named by its version and digest, a version Renovate moves with the chart, no integration that fetches or sends anything is on, and what Falco reads is only the rules files of its image and the one place for local rules

  Scenario: Falco's events are JSON lines on standard output that the log collector ships
    Given Falco's rendered configuration and the log collector's rendered configuration
    When the outputs of Falco and the path of a pod's log lines through the collector are read
    Then Falco writes each event as one JSON line with its rule, priority, output and fields to standard output and to no other output, and the collector reads every pod's lines, keeps the line whole and sends it to the store, so a query for the namespace and the container finds the events

  Scenario: Falco's own metrics are scraped by a monitor of the render
    Given the falco application built as Flux applies it and its pinned chart rendered with the repository's values
    When the metrics endpoint, its Service and the ServiceMonitor are read
    Then Falco serves its Prometheus metrics on the port the Service exposes, the ServiceMonitor selects that Service and labels each series with its node, the separate exporter is not installed, and the metric the alert reads, the count of matches of each rule by priority, is on

  Scenario: Falco's local rules have one place, which holds only what is true today
    Given the falco application's values
    When the key that carries local rule files is read
    Then the key is present and empty, so the pod mounts no local rules and the rules are the image's
