Feature: Observed flows and system calls with kguardian
  kguardian records what each pod connects to and which system calls it makes, and renders that as a proposed network policy or seccomp profile a person reads before writing the real one. It runs in a namespace of its own: an observer on every node with exactly the privileges it names, a broker that keeps the record in a PostgreSQL cluster of the tree's component, and an interface reached only through a local forward. It records every namespace but its own, its observer, broker and interface call nothing outside the cluster, it runs no language-model feature, and its record leaves the cluster only in the database's encrypted backups in the object storage, as every database of the component's does.

  Scenario: kguardian is selected by overlay entries and builds nothing when it is not
    Given the lab-sto2 overlay, which selects kguardian with two entries, the namespace directory kguardian and the application's ks.yaml
    When it is built with both entries, with only the namespace directory's and with neither, and then with both and each application kguardian depends on left out in turn
    Then with both it applies the namespace kguardian, its app-template-defaults ConfigMap, its default-deny NetworkPolicy and the Kustomization kguardian, which waits with the long timeout; with only the namespace directory's, the namespace, the ConfigMap and the NetworkPolicy and nothing else of kguardian; with neither, nothing of kguardian; and with both but one of cloudnative-pg, plugin-barman-cloud, prometheus-operator-crds, external-secrets, openbao-store, linstor-cluster and cilium left out, it is refused, naming kguardian and the missing application

  Scenario: kguardian runs an observer, a broker and an interface, and nothing that calls outside the cluster or a language model
    Given the kguardian application built as Flux applies it and its pinned chart rendered with the repository's values, its resource definitions included, through the release's post-renderers
    When the objects of the render, the values that switch a component or a call off and the environment of the broker and of the interface are read
    Then the render holds exactly the DaemonSet kguardian-controller, the Deployments kguardian-broker and kguardian-frontend, their two Services and three service accounts, the observer's ClusterRole and binding, the broker's ServiceMonitor and the two resource definitions of the chart's crds directory; the evaluator, the chart's own database, the Helm test pod, leader election, the three definitions the chart renders as templates, compute gauges and the scheduler probe, the capture of seccomp verdicts, the runtime inventory, the node catalogue and seccomp distribution are each off by a value the repository sets, so the broker holds no service account token and no Role; the broker's version check-in is off, the assistant, its four providers, its gateway address and its MCP endpoint are off with no llm-bridge workload and no provider Secret named anywhere, and the supply-chain component is off

  Scenario: kguardian's observer runs on every node with only the privileges it names
    Given the kguardian application built as Flux applies it and its pinned chart rendered with the repository's values through the release's post-renderers
    When the DaemonSet, its Pod Security level and its entry in the exceptions list are read
    Then one pod runs on every node, control planes included, at the priority system-node-critical, in the host's network namespace and in no other namespace of the host, its container is not privileged, cannot escalate, has a read-only root filesystem and adds the capabilities BPF, PERFMON, SYS_PTRACE and DAC_READ_SEARCH to an empty set and no others, it mounts of the host only /proc, /sys/kernel/tracing and the container runtime's socket, each read-only, every mount naming a volume of the pod and every host path volume mounted, with the chart's requests and limits; the namespace enforces privileged and audits and warns at restricted; the exceptions list holds the DaemonSet alone for the namespace, with the level privileged and a reason that names the host's network namespace and each capability and host path the baseline level refuses in it; and every other pod of the render passes the restricted level

  Scenario: kguardian records every namespace but its own and keeps what it records for the days the docs give
    Given the kguardian application's pinned chart rendered with the repository's values
    When the observer's and the broker's environment, the values and the observer's ClusterRole are read
    Then the observer leaves out the namespace kguardian alone, records DaemonSets' flows and every system call, each retention window the broker runs with is written in the values and is what its environment holds, 14 days for the flows of a pod that is gone, 30 for the pod itself, and every other window as the chart has it, the docs give those days, and the ClusterRole reads pods, namespaces, Services and workloads and gets any Job and any Node, and nothing else

  Scenario: kguardian's record is kept in a PostgreSQL cluster of the component, with the component's backups
    Given the kguardian application built as Flux applies it, its pinned chart rendered with the repository's values, and the cnpg-cluster component built alone with the same variables
    When the built objects, the Kustomization, the broker's environment and the docs are read
    Then the Kustomization takes the cnpg-cluster component for the cluster kguardian-db in its own namespace with 5Gi for each instance and names the backup plugin and the secret store, the build holds every object the component makes with the content it makes it with, but for the labels of the dump job's pods: one three-instance Cluster that archives its WAL through the plugin, its PodMonitor, ObjectStore and ScheduledBackup, the dump job and its scripts, and the ExternalSecrets of their keys; the docs give the archive's recovery window and the number of dumps kept as the record's time in the object storage; the application has no volume, volume backup or secret store of its own, the chart's own database is off, and the broker connects as the user app to the database app on kguardian-db-rw over TLS with the password of the Secret the operator makes, which is in no file of the tree

  Scenario: kguardian's broker admits only callers that hold a token made in the cluster
    Given the kguardian application built as Flux applies it and its pinned chart rendered with the repository's values
    When the generator, the ExternalSecret and the environment of the observer, the broker and the interface are read
    Then the broker's authentication is on and scoped, the Secret kguardian-broker-auth is written once by External Secrets from one Password generator that gives the keys read and ingest a hexadecimal value each, with nothing that copies one value under both, the observer presents ingest, the interface presents read, the broker reads both, and the Kustomization names external-secrets

  Scenario: kguardian's broker is scraped by a monitor that selects its Service
    Given the kguardian application built as Flux applies it and its pinned chart rendered with the repository's values, with and without the release's post-renderers
    When the ServiceMonitor, the broker's Service and the broker's container are read
    Then the monitor selects Services of the namespace kguardian by a label the chart does not give the broker's Service and the release's post-renderer does, its port is one the Service names and sends to the broker's container port, and the Service selects the broker's pods

  Scenario: kguardian's interface has no route and answers no host name but its Service's
    Given the kguardian application built as Flux applies it and its pinned chart rendered with the repository's values
    When the built objects, the render, the namespace and the interface's environment are read
    Then nothing built or rendered is an HTTPRoute, an Ingress, a Gateway or an object of Envoy Gateway's API group, the namespace does not carry the Gateway label, the interface's Service is of type ClusterIP, and the interface is given the Service's own four names as the only host names it answers besides localhost and addresses

  Scenario: just kguardian forwards a local port to kguardian's interface and ends the forward on every way out
    Given a cluster's kubeconfig and a kubectl that forwards until it is stopped
    When just kguardian runs, with the local port KGUARDIAN_PORT names or 5173, and is interrupted with Ctrl-C or SIGTERM, kubectl does not report the forward within KGUARDIAN_WAIT seconds, or kubectl stops by itself
    Then kubectl forwards that port, on 127.0.0.1 only, to port 5173 of the Service kguardian-frontend in kguardian through the cluster's kubeconfig, the recipe prints the local URL, that the interface has no sign-in, so whoever reaches the local port reads the record, and to read it with no other site open in the browser and end the forward once done, and none of kubectl's own output, and on every way out it exits non-zero and no kubectl it started is still running

  Scenario: just kguardian needs the cluster's kubeconfig and a port, and runs kubectl with none of the secrets
    Given no kubeconfig for the cluster, or a KGUARDIAN_PORT or KGUARDIAN_WAIT that is not a number in range, and then every secret variable the recipes read set to a marker and a recording kubectl
    When just kguardian runs
    Then without the kubeconfig or with a bad port or wait it fails naming each problem and runs no kubectl, and with them kubectl records the names of its environment, which hold none of the secrets and hold the kubeconfig and the recipe's settings
