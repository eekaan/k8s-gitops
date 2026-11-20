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
    Then the listener terminates TLS with the Secret of an ECDSA certificate for the wildcard and the apex of the cluster's domain, renewed at a share of its lifetime and with a new key, issued with nothing chosen by the cluster-wide CA issuer whose CA is a certificate the bootstrap self-signed issuer signed, with no private key in the tree, and a client traffic policy that sets TLS 1.2, the PROXY protocol as optional and the listener limits, and nothing else, is the one policy on the Gateway, and the policies on its routes are the sign-in's, the firewall's and the rate limits' that are named, with no patch policy anywhere and no filter of a route attached to the Gateway that sets or removes x-forwarded-for

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

  Scenario: The Gateway check verifies the certificate against the trust its issuer implies, and says which
    Given a healthy cluster and edges whose Gateway certificate is named for the cluster's own CA issuer, for the ACME production issuer, and for the ACME staging issuer, in turn
    When just gateway-check runs against the fakes
    Then it verifies every edge's HTTPS answer against the cluster CA's certificate, against the system's public trust store with nothing added, and against the issuing chain of the certificate's own Secret, each line saying which, and it fails an answer whose chain is not the one that issuer implies

  Scenario: A certificate that is not issued, or is close to expiry, fails the Gateway check with the reason
    Given a healthy cluster and edges whose Gateway certificate is not Ready for a reason cert-manager gives, or has under a third of its lifetime left
    When just gateway-check runs
    Then the certificate line fails with the condition's reason, cut and made printable as any reason is, or the certificate lifetime line fails with the time left, no other line fails, and a certificate with more than a third left passes

  Scenario: The public Gateway takes a client's address from a PROXY protocol header and still serves a connection without one
    Given the public Gateway application built offline with the example cluster-config
    When its client traffic policy is read
    Then the policy accepts the PROXY protocol on every listener of the Gateway without requiring it and sets nothing else of it, and sets no client IP detection, so the address Envoy takes as the client's is the header's source when a connection carries one and the connection's own otherwise, and a client's own x-forwarded-for is never trusted over it

  Scenario: The proxies' access log names the client address, host, method, path, status and duration of each request, and no query string
    Given the public Gateway's EnvoyProxy built offline with the example cluster-config
    When its telemetry is read
    Then access logging is on and every request, routed or not, is written to standard output as one JSON line with the client address Envoy took, the host, the method, the path without its query string, the status, the duration and the bytes, and no field carries a query string or a client's own x-forwarded-for

  Scenario: A route opts into a request rate limit with one component, at 300 requests a minute unless its ks.yaml says otherwise
    Given the component kubernetes/components/ratelimit, every ks.yaml of the tree, every application the overlay enables built offline with the example cluster-config as Flux applies it, and the render of the tree with what its charts render
    When the component's files, variables and header, the Kustomizations that take it and every BackendTrafficPolicy of the files, the builds and the render are read
    Then the component is one BackendTrafficPolicy named after the route that targets that one HTTPRoute by targetRefs with one local rule without client selectors, 300 requests a minute unless the route's variables say otherwise, and no default for the route; kromgo and hello-sso take it at 300 a minute and hello-route at 5 a second, each built with an integer figure and a unit the definition allows, each waiting with its header's health expressions, the firewall's form; and no other BackendTrafficPolicy is under kubernetes/ or in the render, and none targets a Gateway or a ListenerSet or selects its targets

  Scenario: A route keeps its sign-in and its firewall when it takes a rate limit, and the sign-in paths are not limited
    Given the demo's routes built offline as Flux applies them, every application the overlay enables, and the public Gateway's EnvoyProxy
    When the policies that target each route are read
    Then hello-sso is the target of its SecurityPolicy and of its BackendTrafficPolicy, hello of its EnvoyExtensionPolicy and of its BackendTrafficPolicy, the sign-in route hello-sso-oauth2 of no policy, no route is the target of two policies of one kind, hello-sso is still probed for the redirect to sign-in, and the EnvoyProxy sets no filter order, so the controller's own order runs external authorisation and the Wasm filter before the rate limit

  Scenario: The public listeners bound what one client connection may hold, within the edges' own limits
    Given the public Gateway built offline with the example cluster-config, the edge routers' proxy configuration, and every application the overlay enables
    When the Gateway's ClientTrafficPolicy, the edges' maxconn and timeouts, the edges the Gateway's DNS annotation names and the timeouts of every route and BackendTrafficPolicy are read
    Then the policy keeps the PROXY protocol as optional and TLS 1.2 as they are and sets exactly a connection limit of the edges' maxconn times their number, a buffer limit of 32 KiB, 100 streams on one HTTP/2 connection, a 10 second header timeout, an idle timeout below the edges' timeout and a stream idle timeout no longer than it, and no route or BackendTrafficPolicy sets a request or idle timeout of its own

  Scenario: A burst over hello's limit through each edge is answered 429 on one connection, and hello answers again once the limit's second has passed
    Given a healthy cluster whose BackendTrafficPolicy demo/hello targets the route hello, is Accepted and limits it to 5 requests a second, and two edges that forward to it; then that policy absent, not Accepted, Accepted at an older generation or by one of two ancestors only, targeting by targetRef or targetSelectors as well, with a global rule, a rule with client selectors or two rules, of another unit, or of a figure outside 1 to 20 or not whole; then the demo answering 500; then a burst answered 200 alone, 429 alone, with another status as well or over two connections, or writing out fewer answers than requests, and the route still answering 429 after the wait or answering 200 with another page
    When just gateway-check runs against fakes of kubectl, curl, sleep and the edge stack's outputs
    Then the rate limit line passes, and through each edge one curl call sends 11 requests for hello over HTTP/2 in parallel on one connection, answered 200 and 429, then sleep waits 2 seconds and one request gets the demo's page with 200; each unhealthy case fails its own line, saying which, without an address, and the edge lines of the burst are skipped, saying why, while the policy's line does not pass or the demo does not answer 200 with its page
