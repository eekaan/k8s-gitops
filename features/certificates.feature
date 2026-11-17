Feature: Public certificates
  The public Gateway's certificate comes from the cluster's own CA or from an ACME CA by the DNS-01 challenge, whichever the cluster chooses in one place (ADR 0006). The DNS provider's API token comes from the secret store (ADR 0005) and is never in the tree, and the ACME issuers are an application of their own that a cluster enables when it chooses one.

  Scenario: The DNS provider's token reaches cert-manager from the secret store and is nowhere in the tree
    Given the acme-issuers application built as Flux applies it from the cluster's overlay
    When its objects, its Kustomization and the files of its directory are read
    Then one ExternalSecret reads the provider's key from the ClusterSecretStore into the Secret both issuers name, in cert-manager's namespace, with no Secret, no literal credential and no other way to authenticate in the tree, and the application waits for the store and for its ExternalSecret and issuers to be Ready

  Scenario: An ACME issuer solves DNS-01 only for names under the cluster's domain
    Given the acme-issuers application built with the example cluster-config and with another domain
    When the two ClusterIssuers are read
    Then the staging and the production issuer each name their own directory and their own account key Secret, give no contact address, and solve DNS-01 through the provider with the token Secret and no other solver, only for the cluster's domain

  Scenario: The DNS-01 self-check asks the zone's own nameservers, so a cached negative answer cannot hold a challenge
    Given the tree rendered as Flux and helm-controller would apply it on lab-sto2, the cert-manager chart with its ConfigMap's values, its HelmRelease's own values over them and its post-renderers
    When the controller's arguments and the config file they name are read
    Then the nameservers-only setting is off, so the TXT lookup goes to the zone's authoritative nameservers and not to a recursive resolver's cache, and the one resolver that finds them is a single DNS-over-HTTPS endpoint by name, with no address in the tree

  Scenario: A cluster chooses its public certificate's issuer in one place, and the cluster's own CA is the default
    Given the public Gateway built with no choice, and built as the cluster's overlay applies it
    When its Certificate's issuer is read in each
    Then with no choice it names the cluster's own CA issuer, the lab-sto2 overlay chooses the ACME production issuer by one patch of the Gateway's Kustomization, which one patch of the blackbox exporter's repeats for its probes, and nothing else in the tree names an issuer by variable, and its Certificate follows that choice

  Scenario: A cluster that chooses an ACME issuer without the issuers application is refused
    Given a copy of the tree whose overlay chooses an ACME issuer for the public Gateway
    When the overlay leaves out the issuers application, and then leaves out the Gateway's dependency on it
    Then the kubernetes check refuses both, naming the Gateway's Kustomization and the issuers application, and passes the tree as it is and a cluster that makes no choice
