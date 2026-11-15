Feature: Public Gateway
  One Gateway holds the address the edge routers forward public traffic to, listens on the ports they translate, answers plain HTTP with a redirect to HTTPS, serves a wildcard certificate for the cluster's domain from an issuer the cluster runs, and lets only the namespaces that opt in attach routes. The demo application answers through it by name. Which of these a cluster runs is the overlay's choice.

  Scenario: The public Gateway asks for the Gateway address and is announced over BGP
    Given the public Gateway application built offline with the example cluster-config
    When its Gateway, its EnvoyProxy and the BGP objects are read
    Then the proxies' Service is of type LoadBalancer, carries the label the pool and the BGP advertisement select, asks for the Gateway address by annotation and sets nothing else, the Gateway names that EnvoyProxy for its infrastructure, and nothing else the cluster applies carries that label, asks Cilium for an address or names the Gateway address

  Scenario: Plain HTTP is answered only with a redirect to HTTPS
    Given every application the overlay enables, built offline from the overlay's Kustomizations as Flux applies them
    When the http listener and every route of any kind that names the public Gateway are read
    Then the listener takes HTTPRoutes for every hostname, the one route that names it is the redirect in the Gateway's own namespace, no route there names the Gateway without a listener, and the redirect's one rule sends every path to https on the same host and the default port with status 301 and forwards nowhere

  Scenario: The HTTPS listener serves a wildcard certificate for the cluster's domain from the cluster's issuer
    Given the public Gateway and the issuer application, built offline with the example cluster-config
    When the https listener, its certificate and the issuers are read
    Then the listener terminates TLS with the Secret of an ECDSA certificate for the wildcard and the apex of the cluster's domain, issued by the cluster-wide CA issuer whose CA is a certificate the bootstrap self-signed issuer signed, with no private key in the tree, and a client traffic policy that sets TLS 1.2 and nothing else is the one policy on the Gateway or its routes

  Scenario: A route attaches to the public Gateway only from a namespace that opts in
    Given the public Gateway's listeners and the namespaces of the tree
    When each namespace's labels are matched against the https listener's selector and the http listener's scope
    Then only namespaces labelled k8s-gitops/gateway: public attach to https, only the Gateway's own namespace to http, each listener takes HTTPRoutes only, and no ListenerSet adds a listener

  Scenario: The Gateway listens on exactly the ports the edge routers translate
    Given the Gateway's listeners and the edge stack's public ports
    When the two lists are compared
    Then they are the same ports

  Scenario: The demo application has a public hostname under the cluster's domain
    Given the demo applications built offline with the example cluster-config
    When the hello route, its Service and its namespace are read
    Then the route is for hello under the cluster's domain, on the public Gateway's https listener, backed by a Service that selects running pods of the unprivileged hello workload, in a namespace that opts in

  Scenario: A cluster that leaves the Gateway out still builds, and a route without its Gateway is refused
    Given a copy of the tree whose overlay lists the issuer, the Gateway and the route
    When the overlay leaves out the Gateway and the route, and then only the Gateway
    Then the kubernetes check passes the first and refuses the second, naming the route's Kustomization, the Gateway's and the overlay

  Scenario: The public Gateway's proxies run on different workers and meet the namespace's Pod Security level
    Given the public Gateway's EnvoyProxy, which the controller turns into the proxies' Deployment at run time
    When its replicas, spread, disruption budget, requests and security context are read
    Then two replicas spread over the nodes run under a budget that keeps one, with requests, as a non-root user with no added privileges, in a namespace that enforces the restricted level

  Scenario: A healthy public Gateway passes every line of gateway-check, which reads only and prints no address
    Given a cluster whose Gateway public is Accepted and Programmed at the GATEWAY_ADDRESS of cluster-config, with its proxies' labelled LoadBalancer Service holding that address, two proxies Ready on two nodes, its certificate Ready and only labelled namespaces' routes accepted, and two edges that forward to it
    When just gateway-check runs against fakes of kubectl, curl and the edge stack's outputs, every answer holding addresses
    Then every line passes, plain HTTP through each edge answers 301 to https on the same host and path, HTTPS verifies against the cluster CA's public certificate alone and serves the demo's page and a 404 for a host no route serves, kubectl only reads and takes every name after --, curl and kubectl are bounded in time, and no address, private key or host name under the domain is printed

  Scenario: Each unhealthy condition of the public Gateway fails its own line of gateway-check
    Given the healthy cluster and edges, with one condition made unhealthy at a time
    When just gateway-check runs
    Then the line of that condition fails, saying why without an address, no other line fails, and the recipe exits non-zero

  Scenario: Without the edge stack's outputs gateway-check skips the edge lines and says why
    Given a healthy cluster and an edge stack with no outputs
    When just gateway-check runs
    Then the cluster's lines pass, one line says the edge lines are skipped because the stack has no outputs, curl is never run, and the recipe exits 0
