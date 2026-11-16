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

  Scenario: Open WebUI is selected by one overlay entry and builds nothing when it is not
    Given the lab-sto2 overlay, which lists the namespace directory ai-system and selects Open WebUI with the application's ks.yaml alone
    When it is built with that entry and without it, and then with the entry and each application Open WebUI depends on left out in turn
    Then with the entry it applies the Kustomization open-webui beside the namespace ai-system and its app-template-defaults ConfigMap; without it, nothing of Open WebUI and the same namespace; and with one of external-secrets, gateway-public, linstor-cluster, openbao-store and volsync left out, it is refused, naming open-webui and the missing application

  Scenario: Open WebUI starts with no secret seeded and no model backend
    Given the open-webui application as the lab-sto2 overlay applies it
    When what it builds and what its pinned chart renders are read
    Then the only ExternalSecret it builds is the volume's backup credentials of the volsync component, it builds and renders no Secret and no PostgreSQL cluster, no variable is read from a Secret or holds a key, password or token of its own, the key that signs sessions is the file Open WebUI generates on its volume when none is given, and the Ollama and OpenAI-compatible connections are both off, the Ollama one at the pod's own loopback and the OpenAI one left at the application's default public address, which nothing contacts while the connection is off, and no variable gives either a key

  Scenario: Open WebUI calls nothing outside the cluster until a person configures a connection
    Given the open-webui application as the lab-sto2 overlay applies it
    When the container's image and environment are read
    Then the image is the slim build, which holds no model weights, and the update check, anonymous telemetry, product analytics, community sharing, the default Ollama address, in-browser code execution, downloads from Hugging Face and embedding and retrieval are off, each by its variable, and the container sets no command or arguments of its own, so the image's start script runs with that environment and nothing else sets a variable

  Scenario: Open WebUI's pod meets the restricted level with a read-only root and only the writable mounts it needs
    Given the open-webui application as the lab-sto2 overlay applies it and its namespace
    When the namespace's labels and the rendered pod are read
    Then the namespace enforces the restricted level, the pod runs as a non-root user with the runtime's seccomp profile and one container with a read-only root filesystem, no capability and no privilege escalation, requests of 100m of CPU and 384Mi of memory and a memory limit of 1Gi, and health checks, and it writes only to the claim at /app/backend/data and to volumes of their own at /app/backend/open_webui/static and /tmp

  Scenario: Open WebUI lets nobody but the first account register and makes later accounts wait for approval
    Given the open-webui application as the lab-sto2 overlay applies it
    When what its pinned chart renders is read
    Then sign-up is off and the role of an account made after the first is pending, and no variable gives an account, an administrator or a login provider

  Scenario: Open WebUI's data is on a backed-up volume and it is reached by its hostname on the public Gateway
    Given the open-webui application as the lab-sto2 overlay applies it, with two different cluster domains
    When what it builds and what its pinned chart renders are read
    Then its data directory is the claim open-webui made by the volsync component, filled from the latest backup when it is created and backed up every night, the one replica replaces its pod by deleting the old one first, the route names open-webui under the domain on the https listener of the public Gateway and the Service's port, and the origin and URL Open WebUI is given are that name over https, whichever domain the cluster has
