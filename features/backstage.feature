Feature: Backstage
  Backstage runs in a namespace of its own, with its database from the PostgreSQL component and a hostname on the public Gateway, and its catalogue is the list of what the cluster's overlay selects, kept as files in this tree and held equal to the overlay by a test. It is the stock published image, which this repository does not build, configured from files.

  Scenario: Backstage is selected by overlay entries and builds nothing when it is not
    Given the lab-sto2 overlay, which selects Backstage with two entries, the namespace directory backstage and the application's ks.yaml
    When it is built with both entries, with only the namespace directory's and with neither, and then with both and each application Backstage depends on left out in turn
    Then with both it applies the namespace backstage, its app-template-defaults ConfigMap, its default-deny NetworkPolicy and the Kustomization backstage; with only the namespace directory's, the namespace, the ConfigMap and the NetworkPolicy and nothing else of backstage; with neither, nothing of backstage; and with both but one of cloudnative-pg, plugin-barman-cloud, prometheus-operator-crds, external-secrets, openbao-store, gateway-public and cilium left out, it is refused, naming backstage and the missing application

  Scenario: The catalogue holds exactly one entity for every application the overlay selects, and every entity's links and dependencies exist in the tree
    Given the lab-sto2 overlay and the directory of entity files beside the Backstage application
    When the applications the overlay selects, the entities of kind Component and Resource, their links and their dependencies are read
    Then every application has exactly one entity of its own name in a file of that name, every such entity names an application the overlay selects, its system and owner exist in the catalogue, each of its dependencies is the entity of an application its Kustomization names in dependsOn and every application that Kustomization names is one of them, each link is to a file of this repository and to a heading that file has, and no key of the catalogue's files begins with $, as the placeholders $text, $json and $yaml do

  Scenario: The catalogue's dependencies are regenerated from the Kustomizations
    Given a copy of the tree in which an application's Kustomization names another application in dependsOn that its entity does not list
    When just catalogue-dependencies is run in it
    Then that entity lists the dependency, every other entity is as it was, and a second run changes nothing

  Scenario: Backstage reads its catalogue from files in the cluster and calls nothing outside
    Given the Backstage application as the lab-sto2 overlay applies it
    When its configuration, its generated ConfigMaps, its pod and its namespace's network policies are read
    Then the catalogue's locations are one glob of files in a directory the pod mounts read-only from a ConfigMap that holds exactly the entity files, no location is of another type, the configuration has no integration, no proxy endpoint, no entity provider, no Kubernetes cluster, no TechDocs builder and no analytics, and the namespace denies traffic by default while the policies that select Backstage's pod let it send only to the cluster's resolver and to its database's instances on PostgreSQL's port

  Scenario: Backstage's pod meets the restricted level with a read-only root and only the writable mounts it needs, and its database comes from the PostgreSQL component
    Given the Backstage application as the lab-sto2 overlay applies it and its namespace
    When the namespace's labels, the built objects and the rendered pod are read
    Then the namespace enforces the restricted level, the pod runs as a non-root user with the runtime's seccomp profile and no service account token, its container has a read-only root filesystem, no capability and no privilege escalation, requests and a memory limit and health checks, it mounts nothing writable, the one replica replaces its pod by deleting the old one first, and the Kustomization takes the cnpg-cluster component for the cluster backstage-db, which yields one three-instance Cluster, with Backstage reading its connection from keys of the Secret backstage-db-app and no credential anywhere in the tree

  Scenario: Backstage is reached by its hostname on the public Gateway, and nothing but reading is possible without the cluster's sign-in
    Given the Backstage application as the lab-sto2 overlay applies it, with two different cluster domains
    When its HTTPRoute, its Service, its configuration and the container's environment are read
    Then the route names backstage under the domain on the https listener of the public Gateway and, as its one backend, the Service and its port with no filter on the rule or the backend, nothing the application builds or its chart renders is of Envoy Gateway's API group or names the route as its target, it sends a request on only for GET or HEAD of any path or POST of the catalogue's read by references, so that no write, delete, validation, dry run or action, and no path that differs from the listed one in letter case or by a trailing slash, reaches Backstage, Backstage's own base URLs follow that name whichever domain the cluster has, the namespace lets its routes attach, the catalogue is read-only, the guest provider is the only sign-in and is allowed outside development, and the default authentication policy is not disabled
