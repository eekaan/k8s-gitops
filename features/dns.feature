Feature: DNS records from routes
  A route attached to the public Gateway gets address records for its hostname that point at both edge routers' public addresses, created and removed with the route, by external-dns, and only for names under the cluster's domain. The edges' addresses reach the cluster as configuration at run time and are never in the tree, and the DNS provider's token comes from the secret store (ADR 0005, ADR 0006, ADR 0018).

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
