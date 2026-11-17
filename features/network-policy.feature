Feature: Network policy
  A namespace that holds applications denies ingress and egress by default and carries, beside its applications, the few flows it lets through. A check over the render fails a namespace without that posture unless the tree lists it with its reason, and the public path from the Gateway to a routed backend is proved on the rendered policies, offline.

  Scenario: An application namespace denies ingress and egress by default
    Given the render of the tree, with its real charts
    When just network-policy-check runs
    Then every namespace the overlay deploys into either holds a default deny of both directions that selects every pod, or is listed in network-policy-exceptions.yaml with its reason, and backstage, crowdsec, demo, envoy-gateway-system, kromgo, security-system and sso-system are the namespaces that hold the default deny

  Scenario: A namespace without the posture fails the check unless it is listed with its reason
    Given a render whose namespaces hold a default deny, or are listed with a reason
    When the check runs on it with a namespace's default deny removed, with one that selects only some pods, with one that leaves egress open, with one under another name than default-deny, and with the namespace's entry removed from the list or given no reason
    Then each run exits non-zero and names the namespace

  Scenario: A listed namespace that has the posture, or that does not exist, fails the check
    Given a render and a list that agree
    When the check runs with a namespace that has the default deny added to the list, and with a namespace the render does not hold added to it
    Then each run exits non-zero and names the namespace and what is stale

  Scenario: An allow that undoes the default fails the check unless it says why
    Given a policy in a namespace with the default deny
    When the check runs with an allow from or to an empty peer, every pod of every namespace by a selector of the namespace alone, every peer on a port, the cluster, every endpoint or the unmanaged endpoints, from other nodes' hosts, or from the world other than to the Gateway's proxies on its listener ports, each as the one rule of its policy, with and without the reason annotation and with the reason but no port, with a reason on a policy of two rules, and with an entity written as a label of an endpoint selector or a selector of the namespace that does not require one
    Then each run without the reason exits non-zero and names the namespace and the policy, the runs with it and the rule's ports pass, the rule without ports and the policy of two rules fail with their reason, the entity as a label and the selector that does not require a namespace fail with a reason too, and the evaluation of a flow over a render that holds them gives no answer

  Scenario: Traffic from the public Gateway reaches a routed backend and nothing else in its namespace
    Given the rendered policies of the tree
    When the flows of the public path are evaluated hop by hop
    Then traffic from the world reaches the proxies' listener ports and from other nodes' hosts does not, the proxies reach the routed backends' ports in demo, kromgo and backstage, and not kromgo's metrics port or Backstage's database, and n8n's and Open WebUI's ports in ai-system, which is listed and takes them on every port, and no other port of n8n or Open WebUI and no port of n8n's database, and VictoriaLogs' 9428 in monitoring, which is listed as well, and no other port of it, no other pod there on that port and no port of Prometheus, Grafana, Alertmanager or the log collector there, and dex's and oauth2-proxy's ports in sso-system, oauth2-proxy's being also where they ask about each request of a route that opts in to sign-in, and no other port of either, which take nothing from outside the cluster, as their egress names each routed backend's pods and, in each labelled namespace, exactly the container ports the render's routes send to there, which the test reads in every form the evaluation reads and refuses in a form it cannot compare, for a backend in a namespace without the Gateway label and for a Service without a selector, the kubelet reaches every probe port, the controller takes the API server and other nodes' hosts on its webhook's port alone and the world on none, and the proxies reach no other pod of demo, no other port of a backend, and no pod of a namespace that does not carry the Gateway label, the controller's pods do not reach the backends, and Prometheus reaches kromgo's metrics port, which its monitor scrapes, and no other port of kromgo

  Scenario: A pod of an application cannot reach the secret store, the storage controller or another application
    Given the rendered policies of the tree
    When the flows from the pods of demo, kromgo, backstage and Falco, and to kromgo's, backstage's and Falco's, are evaluated
    Then demo's application pods reach nothing, kromgo's reach the cluster resolver and the pods of the Prometheus Service their configuration names, on the port it sends to, and no other port or pod of monitoring, Falco's take Prometheus and the kubelet on the port its monitor scrapes, read from the render, and nothing else, and reach the cluster resolver on 53 and nothing else, not the resolver's other port, the API server, other nodes, Prometheus, the log store or the world, the backup movers reach the cluster resolver and the object storage on the port of its endpoint as cluster-config's example gives it, 443, Backstage's pod reaches the cluster resolver and its database's instances on PostgreSQL's port and nothing outside the cluster, its database's dump job reaches the resolver, the instances on that port and the world on 443 alone, the database takes the operator on its status and PostgreSQL ports, its own pods, Backstage, the dump job and Prometheus on the exporter's port and reaches its own pods, the resolver and the API server, and none of them reaches a pod of the secret store, the storage controller, another pod of demo or another application namespace, n8n's and Open WebUI's among them, nor does another application's pod reach kromgo, Backstage or Backstage's database

  Scenario: An allow that names an address fails the check
    Given a policy in a namespace with the default deny
    When the check runs with an allow that names a CIDR, an address block or an address in a selector, with the reason annotation as well
    Then each run exits non-zero and names the namespace and the policy

  Scenario: A namespace without its default deny takes and sends everything, whatever its allows say
    Given the rendered policies of the tree, whose allows leave the deny to each namespace's default deny
    When the flows of backstage, demo, envoy-gateway-system, kromgo, security-system and sso-system are evaluated with the namespaces' default deny and without it, and the check runs on an allow that puts its pods in default deny itself or does not say it leaves that to the namespace, on a second deny beside the default deny, and on a deny rule or a policy of the nodes in a namespace with the default deny, in a listed one and cluster-wide
    Then with the default deny exactly the allowed flows pass, without it every flow passes, the check exits non-zero naming the policy, and the evaluation of a flow over a render that holds a deny rule gives no answer

  Scenario: The cluster audits or enforces the policies as the docs say
    Given the Cilium values, the render of the Cilium chart with them and docs/kubernetes.md
    When the mode the docs state is compared with the value policyAuditMode and the agents' rendered configuration
    Then the docs open one paragraph with "The cluster audits network policy." exactly when the value is set and the agents' configuration holds policy-audit-mode true, and with "The cluster enforces the policies." otherwise, a mismatch fails saying which sentence the value needs, and a change of that configuration rolls the agents
