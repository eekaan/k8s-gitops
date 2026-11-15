Feature: Applications
  An application of the reference catalogue is ported into the tree whole: its namespace, its release of the app-template chart, its PostgreSQL cluster, its secrets, its volume and its public hostname, each from the platform's own pieces, selected by two entries of a cluster's overlay, its namespace directory and its own Kustomization. n8n is the first.

  Scenario: n8n's database is a PostgreSQL cluster from the template, and no credential is in the tree
    Given the n8n application as the lab-sto2 overlay applies it
    When what it builds and what its pinned chart renders are read
    Then its Kustomization takes the cnpg-cluster component for the cluster n8n-db, which yields one three-instance Cluster and its PodMonitor in the namespace ai-system, n8n reads its host, port, database, user and password from keys of the Secret n8n-db-app the operator generates, and nothing it builds is a Secret or gives a variable whose name holds a password or key a value of its own

  Scenario: n8n's encryption key comes from the secret store
    Given the n8n application as the lab-sto2 overlay applies it
    When its ExternalSecrets, its generators, its Kustomization and the container's environment are read
    Then the one ExternalSecret that writes the Secret n8n reads N8N_ENCRYPTION_KEY from reads the property encryption-key at ai-system/n8n through the ClusterSecretStore openbao, no generator makes that Secret, the application waits for the store's application, and nothing in the tree gives the key a value

  Scenario: n8n's data is on a volume that is backed up and restored on create
    Given the n8n application as the lab-sto2 overlay applies it
    When what it builds and what its pinned chart renders are read
    Then the directory /home/node/.n8n is the claim n8n made by the volsync component, which is filled from the latest backup when it is created and backed up every night with the component's retention, the directory /home/node/.n8n-files that workflows read and write files in is the claim's directory files, and the one replica replaces its pod by deleting the old one first

  Scenario: n8n has a public hostname under the cluster's domain, and its own settings agree with it
    Given the n8n application as the lab-sto2 overlay applies it, with two different cluster domains
    When its HTTPRoute, its Service and the container's environment are read
    Then the route names n8n under the domain on the https listener of the public Gateway and the Service's port, and the host, protocol, webhook URL, editor URL and number of proxies n8n is given are those of that name and of the one proxy in front of it, whichever domain the cluster has

  Scenario: n8n's pods meet the restricted Pod Security level and do not phone home
    Given the n8n application as the lab-sto2 overlay applies it and its namespace
    When the namespace's labels and the rendered pod are read
    Then the namespace enforces the restricted level, the pod runs as a non-root user with the runtime's seccomp profile, and each of its two containers, n8n and its task runners, has a read-only root filesystem, no capability and no privilege escalation, requests and a memory limit and a health check; n8n writes only to the claim at /home/node/.n8n and /home/node/.n8n-files and to volumes of its own at /home/node/.cache and /tmp, the runners only to a /tmp of their own; and telemetry, version notifications, templates, dynamic banners, community and verified packages, the MCP server registry, the public API and the hiring banner are turned off

  Scenario: A cluster that does not select n8n builds none of it, and one that selects it without what it depends on is refused
    Given the lab-sto2 overlay, which selects n8n with two entries, the namespace directory ai-system and the application's ks.yaml
    When it is built with both entries, with only the namespace directory's and with neither, and then with both and each application n8n depends on left out in turn
    Then with both it applies the namespace ai-system, its app-template-defaults ConfigMap and the Kustomization n8n; with only the namespace directory's, the namespace and the ConfigMap and nothing else of ai-system; with neither, nothing of ai-system; and with both but one of cloudnative-pg, prometheus-operator-crds, external-secrets, openbao-store, volsync, linstor-cluster and gateway-public left out, it is refused, naming n8n and the missing application

  Scenario: n8n runs its code nodes in a task runner of its own version beside it
    Given the n8n application as the lab-sto2 overlay applies it
    When what it builds and what its pinned chart renders are read
    Then n8n runs its task broker in external mode on the pod's loopback, the container runners runs n8n's runners image of the same version as n8n's, pinned by digest, and reaches the broker there, both read the same token from a Secret that External Secrets generates once, and the Service exposes n8n's port and not the broker's
