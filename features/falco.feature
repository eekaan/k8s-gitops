Feature: Runtime detection with Falco
  Falco watches the system calls of every process on every node and names what a workload should not do: a shell spawned in a pod, a write under /etc, a read of a service account token by something that should not. It runs on every node with the least privilege its driver needs, with the rules its image ships, which nothing replaces at run time, and the one exception the tree states, with its reason and as narrow as the workload it is for; it asks for the memory its buffers and its own state take, and mounts no service account token, as nothing in it calls the API; its events are JSON lines the log collector already ships, its own metrics are scraped, and an alert fires when a rule of priority Critical or above has matched. It detects and never responds: no pod is killed or changed, and its events stay in the cluster.

  Two scenarios need a docker daemon, which the CI containers do not have: "Falco loads the local rules at the pinned version and compiles the redirect rule with the one exception under a single negation" and "A command without a terminal raises a named rule of the image, and a query finds its event". Their proofs run Falco itself, from the image the render names, by its digest, in a container without network, without a capability, with a read-only root and a user that is not root, on the render's configuration and local rules, and read what it prints: a dry run, the validation of the rules files and its listing of rules. No probe is loaded and no event is read. They run with the other proofs of tests/falco.bats wherever a docker daemon answers, on a developer's machine or an agent's, and skip, saying why, where none does, as under just ci and in CI, which run every other proof. No proof evaluates an event against a rule: that takes a capture a probe records on a running kernel, which would hold that machine's processes, users and addresses, so what a rule matches rests on the condition Falco compiles, and the values Falco reports for a workload's fields are seen only in an event on a node.

  Scenario: Falco is selected by overlay entries and builds nothing when it is not
    Given the lab-sto2 overlay, which selects Falco with the namespace directory security-system and Falco's ks.yaml
    When it is built with both entries, with only the namespace directory's and with neither, and again with the monitoring definitions it needs left out
    Then with both it applies the namespace security-system, its default deny and the Kustomization falco, which waits and names prometheus-operator-crds and cilium; with only the namespace directory's it applies the namespace and its default deny and nothing of Falco; with neither, nothing of security-system; and with the definitions left out it is refused, naming falco and the missing application

  Scenario: Falco runs on every node with the modern eBPF probe and only the privileges it names
    Given the falco application built as Flux applies it and its pinned chart rendered with the repository's values
    When the DaemonSet, its Pod Security level and its entry in the exceptions list are read
    Then one pod runs on every node, control planes included, with the modern eBPF probe, no kernel module and no init container, privileged is not set, and the container adds the capabilities BPF, PERFMON, SYS_PTRACE and SYS_RESOURCE and no others, mounts of the host only its probe, its container metadata and the user and group names of its events need, every mount naming a volume of the pod, and no host path volume that nothing mounts, and an empty pod security context with no annotation that relaxes a profile; the namespace enforces privileged and audits and warns at restricted; and the exceptions list holds the DaemonSet with the level privileged and a reason that names each capability and host path the baseline level refuses in it

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
    Given the falco application's values and its pinned chart rendered with them
    When the key that carries local rule files, the ConfigMap the chart makes of it and the pod's mount of it are read
    Then the key holds one file, exceptions.yaml, of one item, which replaces the condition of one macro of the image's rules, with its reason in a comment above it that says what httpd does and that a shell in that container still matches, and no rule, list or other item; the chart makes the ConfigMap falco-rules of that file as the values hold it; the pod mounts it whole at /etc/falco/rules.d, which Falco's configuration lists after the image's rules and Falco watches for changes; under /etc/falco the pod mounts nothing else but its configuration file and an empty config.d, the one place the configuration names for further configuration; and the docs show the item

  Scenario: The redirect rule excepts the demo's web server by namespace, container, image and process, and nothing wider
    Given the rendered local rules and the hello application built as Flux applies it
    When the condition that replaces the placeholder of the rule Redirect STDOUT/STDIN to Network Connection in Container is compared with hello's Deployment
    Then it is exactly the conjunction, in parentheses, of four equalities, the namespace hello's Kustomization targets, the name of its one container, its image without tag or digest and the first word of its command, with no or, no not and no other field or operator; a tree whose hello has another container name, another image or another command fails the comparison, as the exception then names nothing that runs; volsync-demo, which runs the same image in the same namespace, has another container name, and of every container the overlay builds into that namespace only hello's has its name and image; and the docs give the reason from the source of the busybox version hello runs

  Scenario: Falco loads the local rules at the pinned version and compiles the redirect rule with the one exception under a single negation
    Given Falco itself, run from the image the render names, by its digest, without network, capability or root, on the render's configuration and local rules
    When it is asked for a dry run, to validate the rules files in the order it loads them, for the redirect rule and for all its rules with and without the local file
    Then the dry run exits 0 having loaded the image's rules and then the local file, every file validates with no error and no warning, the rule is enabled at priority Notice and compiles to the image's condition with one negation, of the conjunction of hello's four values where the image negates a placeholder that is never true, and with the local file Falco lists the same rules enabled as without it, no other rule, macro or list differing

  Scenario: Falco's memory request and limit follow from its buffers, and an out-of-memory kill restarts it in its pod
    Given the falco application built as Flux applies it and its pinned chart rendered with the repository's values
    When the container's resources, the buffer settings in the values and in Falco's rendered configuration, and the pod's restart policy are read
    Then the container requests 192Mi of memory and is limited to 512Mi, with a CPU request of 100m and a limit of 1000m; the values write the buffer size preset 4 and two CPUs for each buffer, which the rendered engine.modern_ebpf holds and from which, with the auxiliary maps and Falco's measured memory, the docs derive each figure of the request; and the pod, a DaemonSet's, restarts its containers always, so a container killed at its memory limit starts again in the same pod, which the docs say with where the kill shows

  Scenario: Falco's pod mounts no service account token
    Given the falco application built as Flux applies it and its pinned chart rendered with the repository's values and the release's post-renderer
    When the pod template, its volumes and mounts, the kinds of the render and the chart's own values and templates are read
    Then the pod template sets automountServiceAccountToken to false, no volume projects a token and no container mounts one, the ServiceAccount does not say otherwise and the render holds no Role or binding; and the chart has neither a value nor a template for the field, which is why the post-renderer sets it, so a chart that gains one fails the proof

  Scenario: A command without a terminal raises a named rule of the image, and a query finds its event
    Given the docs' smoke test, a find for a private key's name run in hello's container with kubectl exec, and Falco itself, run as above
    When the docs are read for the command, the rule and the query, and Falco is asked for the rule Search Private Keys or Passwords
    Then the docs carry the command, made of hello's namespace, Deployment, container and directory, the rule it raises and the query that finds the rule's events; and Falco has the rule enabled at priority Warning, the priority the docs give, its compiled condition matches a find whose arguments contain id_rsa and names neither proc.tty nor container.id, and its output fields hold proc.cmdline, k8s.pod.name and k8s.ns.name, which the docs name
