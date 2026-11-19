Feature: Locust
  Locust runs in a namespace of its own that a cluster's overlay selects, as one master and two workers on one image pinned by tag and digest, at the restricted Pod Security level with a read-only root and no service account token, and puts load on a target inside the cluster that a substitution variable names, the demo's hello by default. Its interface starts load against any host typed into it, has no sign-in the cluster can rely on and answers any web page's request, so what holds it is where its pods may send and who reaches the interface, which its policies bound once the cluster enforces them and not while it audits them: the namespace denies traffic by default, the workers reach the master, the cluster's resolver and the target alone, the target admits them by a rule beside it, the master serves its interface and starts no test by itself, nothing routes to it or scrapes it, and just locust forwards a local port on 127.0.0.1 to the master until Ctrl-C.

  Scenario: Locust is selected by overlay entries and builds nothing when it is not
    Given the lab-sto2 overlay, which selects Locust with two entries, the namespace directory locust and the application's ks.yaml
    When it is built with both entries, with only the namespace directory's and with neither, and then with both and cilium left out
    Then with both it applies the namespace locust, its app-template-defaults ConfigMap, its default-deny NetworkPolicy and the Kustomization locust, which waits, names cilium alone in dependsOn and substitutes one variable, LOCUST_TARGET; with only the namespace directory's, the namespace, the ConfigMap and the NetworkPolicy and nothing of Locust; with neither, nothing of the namespace; and without cilium it is refused, naming locust and cilium

  Scenario: Locust's master and workers run one image, pinned by tag and digest
    Given the locust application built as Flux applies it, Renovate's record of what it extracts and the repository's Renovate rules
    When the images of its pods and the rules that name the image are read
    Then the master and the workers each run one container, of one reference, docker.io/locustio/locust by a release tag of three numbers and a sha256 digest; Renovate's kubernetes manager reads it from both Deployments, with no comment of its own and no entry of tag forms; one rule keeps Renovate to tags of three numbers; and no rule of its own merges it

  Scenario: Locust's pods meet the restricted level with a read-only root and no service account token
    Given the locust application built as Flux applies it, and its namespace as the lab-sto2 overlay builds it
    When the namespace's labels, the exceptions list and the pods of both Deployments are read
    Then the namespace enforces restricted, keeps its objects when it leaves the tree and has no entry in the exceptions list; each pod passes the restricted level, runs as user and group 1000, as non-root, with the runtime's seccomp profile, mounts no service account token, takes no Service environment variables and sets no host alias or DNS setting of its own; each container has a read-only root filesystem, no capability and no privilege escalation, mounts the locustfile read-only and nothing else, requests CPU and memory within 100m and 256Mi, and is limited in memory, to twice its request and at most 512Mi, and not in CPU

  Scenario: Locust's namespace denies traffic by default, and its workers reach the master, the resolver and the target and nothing else
    Given the render of the tree, with its real charts
    When the namespace's NetworkPolicy, Locust's two CiliumNetworkPolicies, hello's policy and the flows of Locust's pods are read and evaluated
    Then the namespace holds the default deny and is not listed; the master takes the workers on 5557 and the kubelet's probe on 8089 and sends nothing; the workers take nothing and reach the master on 5557, the cluster's resolver on 53 and hello's pods on 8080, and not the world, the API server, the secret store, the proxies, another port of the resolver or of hello, or another application; hello takes Locust's workers on 8080 besides the proxies, the kubelet and Robot Framework's runner; and nothing else reaches the master's ports

  Scenario: Locust's target is a Service of the cluster read from the render, and the target admits only Locust's workers on its port
    Given the render of the tree, with its real charts, and the cluster's DNS domain from its machine configuration
    When the master's --host is read from the render and resolved to a Service of the render, the pods it selects and the container port its port targets
    Then the host is http://<service>.<namespace>.svc.<the cluster's DNS domain>:<port>; the render holds that Service with that port; the workers' one egress rule to the namespace names exactly its selector's labels and that container port; and the target's own policy admits Locust's workers there, and not the master, another pod of locust or a pod of another namespace that carries the workers' labels

  Scenario: Locust's master serves its interface from the tree's locustfile and starts no test by itself
    Given the locust application built as Flux applies it
    When its Deployments, its Service, the ConfigMap of its locustfile and every container's command, arguments and environment are read
    Then one master, replaced by Recreate, runs --master with the locustfile, the target as its host, the web port 8089 and the master's port 5557, serves both through the Service locust-master and is probed on / at 8089; two workers run --worker with the locustfile and the master's Service and port, and listen on nothing; the ConfigMap locust-locustfile holds app/locustfile.py byte for byte, from the file, by a hashed name and with Flux's substitution off, mounted read-only where both containers read it; the locustfile imports Locust alone and is one HttpUser with one task that asks for /, gives no host of its own and asks for nothing but paths of the host it is handed; and no container sets a command, an option that starts or shapes a test, a configuration file, --otel or --web-login in any spelling Locust accepts, or a variable of Locust's

  Scenario: Nothing routes to Locust or scrapes it
    Given the locust application built as Flux applies it, its namespace and the render of the tree, with its real charts
    When the kinds of what it applies, the labels and annotations of the namespace and of its pods, and every route and monitor of the render are read
    Then it applies no HTTPRoute, Probe, ServiceMonitor, PodMonitor, PrometheusRule or GrafanaDashboard and nothing of the Gateway API or of Envoy Gateway's, the namespace carries no Gateway label, its Service is of the cluster alone, with no external address, its pods ask for no scrape, and no route, grant or monitor of the render names Locust

  Scenario: just locust forwards a local port to Locust's master
    Given a cluster's kubeconfig and a kubectl that forwards
    When just locust runs, with the local port LOCUST_PORT names or 8089
    Then kubectl forwards that port, on 127.0.0.1 only, to port 8089 of the Service locust-master in locust through the cluster's kubeconfig, and the recipe prints the local URL, that the interface has no sign-in and that anything on this machine, a web page in the browser included, can start a test through it while the forward runs, and that Ctrl-C ends it, reads no Secret and prints none of kubectl's own output

  Scenario: just locust ends the forward on every way out
    Given a kubectl that keeps forwarding until it is stopped
    When the recipe is interrupted with Ctrl-C or SIGTERM, kubectl does not report the forward within LOCUST_WAIT seconds, or kubectl stops by itself
    Then the recipe exits non-zero and no kubectl it started is still running

  Scenario: just locust runs kubectl with none of the secrets
    Given every secret variable the recipes read set to a marker and a recording kubectl
    When just locust runs
    Then kubectl records the names of its environment, which hold none of the secrets, and hold the kubeconfig and the settings of the recipe

  Scenario: just locust needs the cluster's kubeconfig and a port
    Given no kubeconfig for the cluster, or a LOCUST_PORT or LOCUST_WAIT that is not a number in range
    When just locust runs
    Then it fails naming each problem and runs no kubectl
