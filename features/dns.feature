Feature: DNS records from routes
  A route attached to the public Gateway gets address records for its hostname that point at both edge routers' public addresses, created and removed with the route, by external-dns, and only for names under the cluster's domain. The edges' addresses reach the cluster as configuration at run time and are never in the tree, and the DNS provider's token comes from the secret store (ADR 0005, ADR 0006, ADR 0018). Before a teardown gives the edges' addresses back to the cloud, external-dns itself takes the cluster's records out of the zone by its owner rules, and the edge stack's destroy refuses while a name the routes publish still resolves to one of its addresses.

  Scenario: A route on the public Gateway is published at both edge routers' public addresses
    Given the external-dns application and the public Gateway, built offline as Flux applies them, and the chart rendered with the repository's values
    When the Gateway's annotations, the routes that attach to it, the arguments of external-dns and its rendered permissions are read
    Then the Gateway carries the target annotation with both edge variables and nothing else in the tree sets a target, external-dns reads HTTPRoutes of the public Gateway only and writes unproxied A records with a stated TTL, its permissions are read access to Gateways, HTTPRoutes and Namespaces, every route on the Gateway's https listener names a concrete hostname, so the listener's wildcard is never published, no route on its http listener names one, and no route carries an annotation of external-dns

  Scenario: The edges' public addresses come from the cluster's configuration and are nowhere in the tree
    Given the cluster-config example, and a cluster stack and an edge stack whose outputs hold addresses
    When cluster-config is filled from them and the tree is built with other values
    Then the two edge keys are listed in the example with documentation addresses, hold the edge stack's two addresses in order, are never printed, and the annotation follows them

  Scenario: Only names under the cluster's domain are ever touched, and only records this cluster owns
    Given the external-dns application built offline for lab-sto2, whose example domain is its own zone, and for a domain two labels under its zone, and cluster-config filled with and without a zone
    When its arguments are read and the rendered name filter is matched against names inside and outside the domain
    Then the one filter admits the domain, the names under it and the zone's own name, which selects the zone, and refuses every other name, the chart refuses to render without the zone, cluster-config gives the zone the domain unless told and refuses a zone the domain is not under, and external-dns keeps a TXT registry with an owner id that is the cluster's name from the overlay and a prefix, and syncs, so a removed route removes its records and nothing else

  Scenario: The DNS provider's token reaches external-dns from the secret store and is nowhere in the tree
    Given the external-dns application built offline
    When its ExternalSecret, its release and the files of the application are read
    Then the one ExternalSecret reads the key api-token of cert-manager/cloudflare from the ClusterSecretStore openbao into a Secret of its own namespace, the pod takes the token from that Secret by reference, no file of the application holds a token value, and of everything the cluster applies only that ExternalSecret and the ACME issuers' read the key

  Scenario: The Gateway check proves a routed hostname resolves to the edges
    Given a healthy cluster and edges, with external-dns selected, and a public resolver that answers over DNS-over-HTTPS
    When just gateway-check runs against fakes, with the name resolving to both edges, to one, to another address, to none, through a CNAME, as records of another name, with an error status, in two documents or as two addresses in one record, and with external-dns not selected
    Then the name's line passes only for exactly the two edge addresses as the A records of the name itself in one answer with the status NOERROR, fails otherwise without printing an address, is skipped with its reason without the application, one request by name alone reaches the demo, and the lookup gets none of the caller's variables that add trust to curl

  Scenario: A cluster that selects DNS records without the Gateway or the edges' addresses is refused
    Given the lab-sto2 overlay with external-dns enabled
    When the Gateway is left out, an edge variable is left out of the example, or the edge stack has no outputs
    Then kubernetes-check refuses the first two, naming what is missing, and cluster-config refuses the third, naming the edge stack

  Scenario: Destroying the edge stack is refused while a name the routes publish resolves to one of its addresses, and nothing is planned
    Given the edge stack's outputs naming two edges, CLUSTER_DOMAIN, the names the tree's routes on the public Gateway publish, a route on another Gateway, and a public resolver asked over HTTPS
    When just infra-destroy sto2/edge runs while one name resolves to one edge's address, to one and another address, or to both, and while the resolver cannot be asked, answers what cannot be read, answers SERVFAIL or answers with a CNAME
    Then it exits 1 before planning, naming each such name by its label under the domain, never the full name or an address, and saying what to run, just cluster-dns-remove first; nothing is planned or applied, the edges' host keys stay recorded, and the route on the other Gateway is never looked up

  Scenario: The edge stack is destroyed once no name the routes publish resolves to its addresses
    Given the edge stack's outputs naming two edges and the names the tree's routes on the public Gateway publish
    When just infra-destroy sto2/edge runs while every name is NXDOMAIN at the public resolver, or resolves only to an address that is no edge's
    Then the stack is planned and destroyed as before, and the edges' host keys are no longer recorded

  Scenario: The edge stack's destroy goes past resolving names only with --ignore-dns, naming each
    Given the edge stack's outputs naming two edges and a name the routes publish that resolves to one of them
    When just infra-destroy sto2/edge runs with --ignore-dns, with CLUSTER_DOMAIN unset with and without it, and --ignore-dns is given with another stack or none
    Then with --ignore-dns the stack is destroyed and standard error names each name at the edges and each that could not be looked up, or says in one line that no name was looked up; without it an unset CLUSTER_DOMAIN refuses, naming it; and --ignore-dns with any stack but sto2/edge is a usage error

  Scenario: infra-destroy --check says whether a destroy would be refused, and plans and destroys nothing
    Given the edge stack's outputs naming two edges, with a name the routes publish resolving to one of them, and with none
    When just infra-destroy sto2/edge --check runs
    Then it exits 1 naming the name while one resolves to an edge, and otherwise exits 0 saying that nothing refuses the destroy, and neither run plans, applies, asks or drops a host key

  Scenario: The names the routes publish are listed offline from the tree's builds, without a wildcard
    Given the tree, and copies of it with routes on the public Gateway without hostnames, on its https listener alone and on both its listeners, with a wildcard hostname, and with routes on another Gateway, outside the domain, on the http listener without hostnames and in the Gateway's own namespace with a parent that names none
    When dns_published_names lists the names under a domain, with no cluster to reach
    Then on the tree it prints exactly the ten names its routes on the public Gateway publish, under that domain, sorted, the copy with the other routes prints the same ten and the name of the route in the Gateway's namespace, and the listing fails, naming each route, for the routes without hostnames and for the wildcard

  Scenario: The removal's check lists the records it would delete and changes nothing in the zone or in what Flux owns
    Given a cluster whose external-dns runs with the arguments the pinned chart renders with the tree's values, its token in a Secret, and a zone holding records of this cluster's owner, of another owner and of none
    When just cluster-dns-remove runs with --check
    Then it runs one Job of external-dns in dry-run with the empty source, lists the A and TXT records of this cluster's owner by their names under the domain, deletes the Job and exits 0, having suspended nothing, scaled nothing, run no Job without --dry-run, changed nothing in the zone and read no Secret, and prints neither the zone's identifier nor the token

  Scenario: The removal stops external-dns, deletes only the records of this cluster's owner, and finds none left
    Given a cluster whose external-dns runs with the arguments the pinned chart renders with the tree's values, and a zone holding records of this cluster's owner, of another owner and of none
    When just cluster-dns-remove runs and the cluster's name is typed back, then runs again, and runs answered wrongly, against a Deployment without the TXT registry, with upsert-only or with the placeholder owner, with a deleting Job that fails and with a record that comes back
    Then it plans, suspends the Kustomization and the HelmRelease, scales external-dns to zero and waits for its pod to go, deletes with a Job of the template's owner, prefix, registry, policy, filter and record types and the empty source, and plans again to find none left, leaving the other owner's records and the record without an entry, and prints the way back; the second run deletes nothing and asks nothing; a wrong answer suspends nothing; each refused Deployment makes no Job; a failed Job is kept and named with what is left suspended and how to resume it; and a record left fails the run naming it

  Scenario: The runbooks take the records out after the last copies and before the cluster and the edge stack go
    Given the rebuild runbook and the edge routers' runbook
    When their steps for taking the cluster and the edges down are read
    Then the rebuild runbook runs just cluster-dns-remove after just cluster-last-copies and before just cluster-destroy, which comes before the step that destroys sto2/edge and sto2/ci, and the edge runbook runs just cluster-dns-remove before just infra-destroy sto2/edge
