# The kubernetes/ tree

`kubernetes/` is everything Flux reconciles; CI publishes it as the cluster's artifact
(ADR 0003, [Publishing](#publishing)). `just kubernetes-check` builds it offline with kustomize and Flux, and fails, naming
the file, when a cluster directory, a `ks.yaml`, an application directory or a variable breaks
the rules below.

## Layout

- `clusters/<cluster>/`: the cluster's root Kustomization in `ks.yaml`; Flux's own two
  applications in `flux-system/flux-operator/` and `flux-system/flux-instance/` (see
  [Flux itself](#flux-itself)); a `kustomization.yaml` that lists the root's and those two
  `ks.yaml` files and nothing else; the example key lists; and, once the cluster has substitution
  secrets, `secrets/cluster-secrets.sops.yaml` (see [Before Flux starts](#before-flux-starts)).
  Nothing lists the last two.
- `apps/overlays/<cluster>/kustomization.yaml`: what the cluster runs.
- `apps/base/<namespace>/`: a namespace directory, with `namespace.yaml` and a
  `kustomization.yaml` that sets the namespace and includes `components/common`.
- `apps/base/<namespace>/<app>/`: an application, its Flux Kustomization in `ks.yaml` and its
  manifests in `app/`.
- `apps/base/flux-system/artifact-generator/`: publishes one artifact per application.
- `components/`: Kustomize components. `common` adds the `app-template-defaults` ConfigMap, which
  an app-template HelmRelease opts into through `valuesFrom`; `cnpg-cluster` adds an application's
  PostgreSQL cluster ([PostgreSQL](#postgresql)); `volsync` backs an application's volume up
  ([Volume backups](#volume-backups)).

## Adding an application

Put the manifests in `apps/base/<namespace>/<app>/app/` with their own `kustomization.yaml`, and
this `ks.yaml` beside the directory:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: <app>
  namespace: flux-system
spec:
  path: ./apps/base/<namespace>/<app>/app
  targetNamespace: <namespace>
  sourceRef:
    kind: ExternalArtifact
    name: <app>
```

- `<app>` is a DNS label (lowercase letters, digits and `-`) and unique across every namespace,
  enabled or not. `metadata.name` and `sourceRef.name` are `<app>`, `targetNamespace` is
  `<namespace>`, and `path` is the application's own `app/`.
- `dependsOn`, `wait`, `healthCheckExprs`, `components` and `postBuild.substitute` belong to the
  application. The fields the root sets do not; see below.
- A new namespace gets its directory: `namespace.yaml` with the Pod Security labels and the
  annotation `kustomize.toolkit.fluxcd.io/prune: disabled`, so removing it from the tree does not
  delete what runs in it.

Enable the application by listing its namespace directory, once, and its `ks.yaml` in
`apps/overlays/<cluster>/kustomization.yaml`. A disabled application stays in the list,
commented out with the reason:

```yaml
  # - ../../base/demo/hello/ks.yaml  # Disabled: <reason>
```

## What the root sets

The root Kustomization patches every child Kustomization with:

- `interval: 30m`, `retryInterval: 1m`, `timeout: 3m`, `prune: true`,
  `deletionPolicy: WaitForTermination` and SOPS `decryption`;
- `postBuild.substituteFrom` with the ConfigMap `cluster-config` and the Secret `cluster-secrets`;
- `patches` holding the defaults for every HelmRelease the child applies: install and upgrade
  remediation with three retries and rollback, CRDs created and replaced, Helm tests, drift
  detection and a history of three releases.

These overwrite the child's own values, and lists such as `patches` are replaced whole, so a
child that sets any of these fields without opting out fails the check.

## Labels

- `k8s-gitops/defaults: disabled` on a child Kustomization: none of the defaults apply, and the
  child sets `interval`, `prune` and anything else it needs itself. On a HelmRelease: that
  release gets none of the release defaults.
- `k8s-gitops/timeout: long` on a child Kustomization: a 10m timeout with every other default
  kept. It does nothing on a child that opted out.

## Every child Kustomization is in flux-system

`postBuild.substituteFrom` has no namespace field: Flux reads the ConfigMap and Secret from the
Kustomization's own namespace. `cluster-config` and `cluster-secrets` live in `flux-system`, so
every child Kustomization lives there too and sets `targetNamespace` for what it deploys.

## Variables

- `${VAR}` is replaced from `cluster-config` or `cluster-secrets`. Their values are never
  committed in plain text; their key names are, with placeholder values, in
  `clusters/<cluster>/cluster-config.example.yaml` and `cluster-secrets.example.yaml`. Add a key
  there when a manifest starts using it.
- `${VAR:=value}` gives a default.
- Values for one application go in its `postBuild.substitute`.
- `$${VAR}` reaches the application as `${VAR}`.
- Helm values are generated into a ConfigMap with the annotation
  `kustomize.toolkit.fluxcd.io/substitute: disabled`, which leaves any `${...}` in them alone;
  so does the annotation on any other object.
- A Helm value that comes from a variable is set in the HelmRelease's own `spec.values`, which
  Flux substitutes and helm-controller merges over the values ConfigMap; `values.yaml` holds no
  variables.

The check builds every application with Flux's strict substitution, using the placeholders, so a
variable that is none of the above fails it.

## Per-application artifacts

The ArtifactGenerator publishes each application's `app/` as an ExternalArtifact named after
the application, together with `components/`, at the same paths as in the tree, so a change
reconciles only the applications it touches (ADR 0004). Falling back to one shared source is a
`sourceRef` change in each `ks.yaml`, to `kind: OCIRepository` and `name: flux-system`.

## Resource definitions

Resource definitions that several applications use are applications of their own in
`apps/base/kube-system/`, so their version does not depend on whichever chart also bundles them:

- `prometheus-operator-crds`: every definition of the Prometheus Operator's `monitoring.coreos.com`
  group (ServiceMonitor, PodMonitor, PrometheusRule and the rest), from the upstream
  `prometheus-operator-crds` chart, which ships them and nothing else.
- `gateway-api-crds`: the Gateway API's standard channel (`gateway.networking.k8s.io`). Its `app/`
  holds a `GitRepository` for the upstream repository at the release tag, checking out only
  `config/crd`, and an inner `Kustomization` that applies upstream's kustomization there, the one
  the release's `standard-install.yaml` is built from. Its patches leave out the release's
  `safe-upgrades` admission policy and binding, so it applies resource definitions only. Both
  objects live in `kube-system`, where the application's `targetNamespace` puts them; the inner
  `Kustomization` is not a child of the root, gets none of its defaults and substitutes nothing.
- `snapshot-controller`: the CSI snapshot definitions (`snapshot.storage.k8s.io`, and
  `groupsnapshot.storage.k8s.io` beside them) and the snapshot controller that serves them, from
  the upstream `external-snapshotter` repository at one release tag, the source the Piraeus
  documentation points to, so both always come from the same release. Its `app/` has the Gateway
  API application's shape: a `GitRepository` checking out only `client/config/crd` and
  `deploy/kubernetes/snapshot-controller`, and an inner `Kustomization` for each that applies
  upstream's kustomization there, the controller's once the definitions' is Ready. The controller
  runs in `kube-system`, where upstream's manifests put it. The repository also tags releases of
  its client module, `client/vX.Y.Z`; Renovate follows only the `vX.Y.Z` tags.

The three `ks.yaml` files set `wait`, so each is Ready only once its definitions are established,
and `snapshot-controller` once its controller runs as well. An application that creates objects of
these groups, or whose chart does, names the matching one in `dependsOn` and turns off any copy of
the same definitions its own chart would install; each application's section below says which it
names. No route is enabled anywhere, and no chart's dashboard outside the `grafana` application.

Deleting a definition deletes every object of its kind, so none of these applications ever deletes
one, also not when it leaves the tree. None applies a definition itself. The monitoring chart's
values give each definition `helm.sh/resource-policy: keep`, so Helm leaves them when Flux
uninstalls the release. The inner Gateway API `Kustomization` and the inner `Kustomization` of the
snapshot definitions set `prune: false` and `deletionPolicy: Orphan`, so each leaves what it
applied when it is deleted, and keeps a definition a newer release drops. `tests/baseline.bats`
renders the chart and builds the pinned Gateway API source offline to check the first two, and
that they yield definitions only; `tests/storage.bats` builds the pinned snapshot source the same
way.

## The kube-system baseline

The small services later applications assume are applications in `apps/base/kube-system/` with
the Cilium application's shape. Their charts come from their publishers' OCI registries,
except metrics-server's and the descheduler's, which their publisher releases only to a classic
Helm repository; those come from a public OCI mirror that republishes each release unchanged. Each
of them that serves metrics has its chart's monitor on, a ServiceMonitor or, for Reloader, whose
chart makes no Service by default, a PodMonitor, and names `prometheus-operator-crds` in
`dependsOn`. No dashboard is enabled in any of them, and none uses a priority class Kubernetes
does not define itself.

- `kubelet-csr-approver` approves a kubelet's serving certificate request (Talos has the kubelets
  make them) only when the name it asks for matches `NODE_NAME_REGEX` in full and every address it
  asks for is in `NODE_CIDR`, both from `cluster-config`, which its HelmRelease sets in its own
  values. A missing `NODE_NAME_REGEX` leaves a pattern that matches no name; a missing
  `NODE_CIDR` becomes a value the approver cannot parse, so it stops rather than read an empty
  list as every address. Nothing in this repository makes node names resolvable in the cluster's
  DNS, so the approver does not look them up.
- `metrics-server` serves resource metrics. It verifies each kubelet's serving certificate
  against the cluster CA, and starts only once `kubelet-csr-approver` is ready, which it names in
  `dependsOn`. Its own `/metrics` is served without authorization, as its chart's ServiceMonitor
  carries no credential.
- `spegel` shares images between nodes, serving the image layers containerd keeps on each node,
  which every node's machine configuration has it keep;
  [cluster.md](cluster.md#image-layers-for-spegel) says which images that is, and how a change to
  the nodes is rolled out while it runs. It writes containerd's registry mirror configuration to
  `/etc/cri/conf.d/hosts`, where Talos' containerd reads it.

  Its registry, on every node's port 30020 and on its pod, takes no credentials, by Spegel's design:
  containerd sends a mirror none, and Spegel could not check them
  ([Spegel](https://spegel.dev/docs/faq/#why-am-i-able-to-pull-private-images-without-image-pull-secrets)).
  An image a node pulled with credentials is therefore served within the cluster; the nodes'
  security group (`infra/openstack/modules/talos-nodes`) admits nothing from outside the node
  network but the Talos and Kubernetes APIs ([cluster.md](cluster.md#the-control-planes-metrics)).

  Prometheus scrapes its metrics port, where Spegel 0.8.1 also serves Go's profiler
  ([Spegel](https://github.com/spegel-org/spegel/blob/v0.8.1/main.go#L278-L305)); the values turn
  off the debug page beside it.
- `reloader` restarts a workload annotated for it when a ConfigMap or Secret it uses changes, and
  nothing else.
- `descheduler` runs the chart's default policy every five minutes, with two changes: a pod is
  evicted only when another node can take it, and a cordoned node's taint is no reason to evict.

`tests/baseline.bats` renders every baseline chart with the repository's values, checks that each
values key is one the pinned chart defines and that each monitor selects a Service or pods the
chart makes, and reads the approver's, metrics-server's and Spegel's rendered configuration,
Spegel's debug page included.

The approver's chart makes its ServiceMonitor only once the kind exists, so the release installed
before Flux has none, and Flux's first upgrade, which waits for `prometheus-operator-crds`, adds
it.

## Runtime classes

`apps/base/kube-system/runtime-classes/` holds a RuntimeClass for each container runtime the node
image adds ([cluster.md](cluster.md#the-node-image)), with the handler the extension's README
gives: `gvisor`, handler `runsc`, and `kata`, handler `kata`, which also carries the overhead of
Kata's virtual machine from that README, counted on top of a pod's requests. A RuntimeClass is
cluster-scoped, so the application's `targetNamespace`, `kube-system` as for the resource
definitions, gives it none. A pod selects one with `runtimeClassName`; none does. Flux applies them
whatever image the nodes run, and a pod that selects one on a node whose image lacks its handler
does not start. `tests/baseline.bats` builds the application as Flux applies it and checks the two
classes and their handlers.

## Service addresses

A Service of type `LoadBalancer` gets its address from Cilium and is announced over BGP by the
workers to two edge routers, which publish it (ADR 0013). `apps/base/kube-system/cilium-bgp/` holds
what that takes, beside the Cilium application, whose values turn on Cilium's LoadBalancer IP
management and its BGP control plane and keep Layer 2 announcements off. These settings live in
the ConfigMap `cilium-config`, and `rollOutCiliumPods` and `operator.rollOutPods` restart the agents
and the operator whenever it changes: a change to any of them, as the one that turned them on,
restarts every agent, node by node, and the operator.

- **Opting in.** A Service gets an address, and has it advertised, only with the label
  `k8s-gitops/announce: bgp`. Any other `LoadBalancer` Service stays pending, so no address is handed
  out that nothing announces.
- **The pool.** One `CiliumLoadBalancerIPPool` holds exactly the service range
  ([infrastructure.md](infrastructure.md#services-announced-over-bgp)), `10.20.0.0/28` by default:
  sixteen addresses. Services can share one with Cilium's `lbipam.cilium.io/sharing-key`
  annotation where their ports differ.
- **Who announces.** One `CiliumBGPClusterConfig` gives every worker, and no control plane, a BGP
  instance in the cluster's AS that peers with both edge routers in theirs, over eBGP. Talos labels
  its control planes `node-role.kubernetes.io/control-plane`, which the node selector excludes, and
  only the workers' ports may carry the service range. The edge routers are on the node subnet, one
  hop away, so the sessions keep eBGP's TTL of 1. A worker opens its sessions and listens for none.
- **The sessions.** The `CiliumBGPPeerConfig` sets a hold time of 9 seconds, keepalives every 3 and
  a connect retry of 5, and turns on graceful restart with a restart time of 120 seconds, so an
  edge router keeps forwarding to a worker while its Cilium agent restarts. IPv4 unicast only, and
  no password (ADR 0013).
- **What is advertised.** The `CiliumBGPAdvertisement` the peer configuration selects advertises
  the `LoadBalancer` address of each labelled Service, as a /32, and nothing else: no pod range and
  no cluster IP.
- **Before the edge routers exist** the sessions stay down: a labelled Service gets an address, but
  nothing outside the cluster reaches it.
- **`externalTrafficPolicy`.** With `Cluster`, the default, every worker announces every labelled
  address, the edge routers spread connections over all of them, and a worker forwards each to an
  endpoint on any node, translating the source to its own address when the endpoint is elsewhere.
  With `Local`, only workers with a ready endpoint of the Service announce its address, and a
  connection reaches an endpoint on the worker it arrived at with its source unchanged. Either way
  the source a Service sees is what reaches the worker, which is an edge router's address while
  the edge routers translate the client's address to their own (ADR 0013). A worker whose last
  endpoint goes away withdraws a `Local` address; a `Cluster` address stays announced while the
  Service has no endpoint at all.

Every object there is of a kind that Cilium's operator defines once it leads, the BGP kinds only
while the BGP control plane is on, so the Cilium application holds none of them:
`scripts/install-cilium` installs Cilium before any of those definitions exists. `cilium-bgp` names
`cilium` in `dependsOn`, and the Cilium application sets `wait` and carries
`k8s-gitops/timeout: long`, as its release may take 10 minutes to roll the agents: it is Ready only
once its release is, with every agent running, and an agent starts only once every kind it uses is
defined. So Flux applies the pool and the BGP objects only after their definitions exist, also on
the change that turns the BGP control plane on. The objects are cluster-scoped; the
API server drops the namespace the application's `targetNamespace` gives them. Their numbers come
from `cluster-config` ([Before Flux starts](#before-flux-starts)). `tests/install-cilium.bats`
renders the chart and the nodes' machine configurations and builds every application as Flux
applies it to check each of these.

## External Secrets

`apps/base/external-secrets/external-secrets/` runs the External Secrets operator in its own
namespace, `external-secrets`. It is how runtime secrets reach workloads (ADR 0005): an
`ExternalSecret` names a key in a secret store, and the operator writes it into a Secret. The
exception is a credential a controller generates in the cluster for its own workload, which stays
in the Secret that controller writes, such as Grafana's admin password ([Grafana](#grafana)). No
secret store is configured yet. The `volsync` component makes an `ExternalSecret` of the
ClusterSecretStore `openbao` ([Volume backups](#volume-backups)), and no enabled application
includes it.

- The chart comes from its publisher's OCI registry and installs and upgrades the operator's
  resource definitions itself, as the publisher documents. No other chart in the tree ships them,
  so they are not an application of their own. Each carries `helm.sh/resource-policy: keep`, so
  uninstalling the release leaves them in place, and with them every `ExternalSecret` and the
  Secret it owns.
- The controller, the webhook and the certificate controller each run two replicas on different
  nodes, the controllers with leader election, and a disruption budget keeps one of each running
  while a node is drained. The certificate controller issues the webhook's certificate. The webhook
  validates every change to a secret store or an `ExternalSecret`, and the API server refuses the
  change when no webhook answers.
- The namespace enforces the restricted Pod Security level, which the chart's pods meet. No
  ServiceMonitor or dashboard is enabled.

`tests/external-secrets.bats` builds the application as Flux applies it and renders the chart to
check each of these.

## Monitoring

`apps/base/monitoring/kube-prometheus-stack/` installs the Prometheus Operator, one Prometheus, one
Alertmanager, kube-state-metrics and node-exporter in the namespace `monitoring`, from the
prometheus-community `kube-prometheus-stack` chart. The namespace's Pod Security level is
privileged, as node-exporter reads each node through the host's network and process namespaces and
through host paths. The chart installs no resource definitions: `prometheus-operator-crds` does
([Resource definitions](#resource-definitions)), and the application names it in `dependsOn`. The
two charts run the same operator version: Renovate moves them in one pull request, and
`tests/monitoring.bats` fails when the pinned charts name different ones. The application installs
no Grafana and no dashboards; [Grafana](#grafana) runs on its own and takes its dashboards from the
same chart.

Prometheus picks up every ServiceMonitor, PodMonitor, Probe, ScrapeConfig and PrometheusRule in
every namespace, and evaluates the chart's default alerting and recording rules. It scrapes:

- the API server, every kubelet with its container metrics, CoreDNS, kube-state-metrics,
  node-exporter on every node, and the stack's own components;
- on every control plane, the controller manager and the scheduler on their secure ports, and
  etcd's metrics over plain HTTP, which Talos serves once the node runs
  `talos/patches/controlplane/metrics.yaml` ([cluster.md](cluster.md#the-control-planes-metrics)).
  Talos runs etcd outside Kubernetes, so etcd's Service selects the API server's pods, which run on
  the control planes' host network, for their addresses, and Prometheus sends etcd no credential;
- the monitors of the baseline applications ([The kube-system baseline](#the-kube-system-baseline)).

It does not scrape:

- kube-proxy, which Cilium replaces: its target and its alert rule are off, so nothing fires for
  its absence;
- Cilium, whose ServiceMonitors stay off: `scripts/install-cilium` installs Cilium from the same
  values before any monitoring definition exists, and its chart refuses a ServiceMonitor without
  one;
- Flux's controllers, for which nothing defines a monitor.

Alertmanager routes every alert to its one receiver, `null`, which sends nothing: alerts show in
Prometheus and Alertmanager and go nowhere else.

Prometheus keeps 14 days of data, and at most 16 GiB, on a 20 GiB volume; Alertmanager keeps its
silences and notification log on a 1 GiB volume. Both volumes are claims on the cluster's default
storage class, which neither names; without one, the claims and the two pods stay Pending.

`tests/monitoring.bats` builds the application as Flux applies it, renders the pinned chart with
its values, and checks the namespace, the targets, the rules, the receivers, the claims and that
each values key is one the chart or a subchart reads.

## Grafana

The Grafana operator runs one Grafana in `monitoring`, with the cluster's Prometheus as its
datasource and the monitoring chart's dashboards. Two applications in `apps/base/monitoring/` hold
them:

- `grafana-operator` installs the operator from its publisher's chart,
  `oci://ghcr.io/grafana/helm-charts/grafana-operator`. The release installs and upgrades the
  `grafana.integreatly.org` definitions as its own templates, each marked
  `helm.sh/resource-policy: keep`, so removing the application leaves them and every Grafana object
  in place; only this chart ships them. One operator runs, with leader election and the requests of
  the publisher's own manifests: nothing calls it, and while it restarts Grafana keeps serving and
  only changes from Git wait. Its chart's ServiceMonitor is on. Its `ks.yaml` sets `wait`.
- The operator watches `monitoring` only. Its service account has a Role there and no ClusterRole,
  so it creates, reads, changes and deletes Secrets, ConfigMaps, Services, service accounts,
  claims, Deployments, Ingresses and HTTPRoutes in `monitoring` and nowhere else. A dashboard for an
  application in another namespace is therefore a `GrafanaDashboard`, with the ConfigMap it loads if
  it loads one, in an application under `apps/base/monitoring/`, as an application's
  `targetNamespace` puts everything it applies in its own namespace. Watching another namespace is
  a deliberate change: it gives the operator the same rights there, and watching every namespace
  gives it them everywhere, `flux-system` included.
- `grafana` holds the `Grafana`, its `GrafanaDatasource`, a ServiceMonitor for Grafana's own
  metrics and the dashboards release, and names `grafana-operator` in `dependsOn`.

The Grafana runs the version its `grafana.yaml` pins, which Renovate updates, as one replica
without a disruption budget: a second replica would keep a database of its own. It keeps nothing
that Git does not hold, so it claims no volume: its data directory is an emptyDir, and the operator
applies the datasource and every dashboard again every minute. One it cannot apply, as while a
restarted Grafana starts, it retries after 10 seconds, doubling the wait up to two minutes, so a
restarted Grafana has them all back within a few minutes. The datasource is the Prometheus Service
of the monitoring chart, `kube-prometheus-stack-prometheus`, port 9090. Grafana makes no call to the
internet on its own: its
configuration turns off usage reporting, the checks for Grafana and plugin updates, the news feed,
the plugin catalogue, the plugins Grafana would install at every start, the download of plugin
signing keys, Gravatar images and external snapshots, so it runs only the plugins in its image.

The dashboards come from the monitoring stack's own chart. The release `grafana-dashboards` installs
`kube-prometheus-stack` at the version the monitoring application runs, with everything off but the
dashboards the chart renders for what the cluster scrapes: the Kubernetes mixin's, node-exporter's
for Linux nodes, and those of the API server, the kubelets, the controller manager, the scheduler,
etcd, CoreDNS, Prometheus, Alertmanager and Grafana. They match the recording rules and job names of
the Prometheus they query, and Renovate moves both pins in one pull request. Each is a ConfigMap and
a `GrafanaDashboard` that loads it into the folder Kubernetes, so neither the operator nor Grafana
fetches a dashboard from the network.

Nothing routes to Grafana from outside the cluster. `just grafana [cluster]` forwards a local port,
`GRAFANA_PORT` or 3000, on 127.0.0.1 only, to port 3000 of the Service `grafana-service` in
`monitoring` through the cluster's kubeconfig, until Ctrl-C; it prints the local URL, and the
forward ends with the recipe however it ends ([cluster.md](cluster.md#recipes)). Sign in as
`admin`. The password is under `GF_SECURITY_ADMIN_PASSWORD` in the Secret
`grafana-admin-credentials` in `monitoring`, which the
operator generates when it first creates the Secret and keeps while the `Grafana` exists; nothing in
Git holds it. Deleting the `Grafana` deletes the Secret, and a new one gets a new password. It is
the kind of credential ADR 0005 keeps out of OpenBao: one a controller generates in the cluster for
its own workload, which stays in the Secret that controller writes. Anonymous access is off.

`tests/grafana.bats` builds both applications as Flux applies them, renders the two charts and the
monitoring application's, and checks the definitions, the operator's namespace and rights, the
monitors, the version and replicas, the absence of volumes, Secrets and routes, the datasource's
Service, that the dashboards are exactly those the monitoring chart renders for the cluster's
monitoring values, and each setting that keeps Grafana off the internet against the defaults of the
Grafana release it pins. It runs `just grafana` against a recording kubectl.

## cert-manager

`apps/base/cert-manager/cert-manager/` installs cert-manager, which issues and renews the TLS
certificates applications and gateways ask for, from the issuers they name (ADR 0006). No issuer is
configured yet, so it issues nothing.

It runs in its own namespace, `cert-manager`, at the restricted Pod Security level, from the
publisher's chart in `oci://quay.io/jetstack/charts`; its leader election leases are there too, so
nothing it installs is in another namespace. The release installs and upgrades the `cert-manager.io`
and `acme.cert-manager.io` definitions, as the publisher recommends under Flux: only this chart
ships them, so they move with the controller that serves them rather than being an application of
their own. Each carries `helm.sh/resource-policy: keep`, so removing the application leaves them,
and every certificate and issuer, in place. Gateway API support is on; cert-manager looks for the
Gateway API definitions only when it starts, so the application names `gateway-api-crds` in
`dependsOn`. Its `ks.yaml` sets `wait`, so an application that names `cert-manager` in `dependsOn`
starts once cert-manager runs.

Following the publisher's production guidance, the controller and the CA injector run two replicas
each, one leading, and the webhook three, one per worker, spread over the nodes where the scheduler
can; each has a disruption budget that keeps one pod available, so a drain never takes the last
one. They run at `system-cluster-critical` with small requests and no limits. No ServiceMonitor or
PodMonitor is enabled. `tests/baseline.bats` renders the chart with these values and checks the
namespace, the definitions and their policy, the Gateway API configuration and dependency, and the
replicas, spreads and budgets.

## Autoscaling and reflection

Three small add-ons that the applications this cluster runs assume, each enabled in the cluster's
overlay. `tests/autoscaling.bats` builds each as Flux applies it and renders its chart to check
what follows.

### KEDA

`apps/base/keda/keda/` runs KEDA in its own namespace, `keda`, at the restricted Pod Security level
its pods meet. An application scales on events by creating a `ScaledObject` (or `ScaledJob`) that
names its workload and a trigger; KEDA creates and owns the HorizontalPodAutoscaler that follows it.
The chart is the publisher's, from a public OCI mirror, as it releases only to a classic Helm
repository.

- The release installs and upgrades the `keda.sh` and `eventing.keda.sh` definitions, as the
  publisher's chart does; each carries `helm.sh/resource-policy: keep`, so uninstalling the release
  leaves them, and every `ScaledObject`, in place. The application's `ks.yaml` sets `wait`, so an
  application that names `keda` in `dependsOn` starts once they exist.
- The operator, the metrics server and the admission webhooks each run two replicas, preferably on
  different nodes, under a disruption budget that keeps one running. Only one operator is the
  leader, so its second replica is a standby that shortens a failover. The second metrics server is
  there for availability too, so one keeps answering through a drain or a pod's failure: the API
  server reaches them through their Service's address without aggregator routing, so requests are
  not spread over the two, and KEDA's documentation supports one. Requests and limits are the ones
  KEDA's documentation gives for each component.
- KEDA's metrics server registers the `external.metrics.k8s.io` API. metrics-server registers
  `metrics.k8s.io`; the two groups differ, so the registrations do not collide. Only one provider
  can serve `external.metrics.k8s.io`: no other application may register it.
- The admission webhooks' failure policy is `Ignore`: while no webhook answers, a `ScaledObject` is
  admitted without being checked. A missing operator is worse for what it owns: HorizontalPodAutoscalers
  that follow a `ScaledObject` stay, but the metrics server gets the values they read from the
  operator, and the operator does the scaling from and to zero itself, so without it they cannot
  compute, their workload stays at its current size, and nothing scales it from or to zero.
- KEDA 2.21's documentation tests Kubernetes 1.34 to 1.36; the cluster runs a newer release, so KEDA
  runs outside the versions its publisher has tested.
- One ServiceMonitor for each of the three components.

### Vertical Pod Autoscaler

`apps/base/kube-system/vpa/` runs the recommender only, in `kube-system` with the other small
services the cluster assumes, from the Fairwinds chart.
The project's own `vertical-pod-autoscaler` chart (in the autoscaler repository's Helm index) says
it is under development and not ready for production, so the cluster uses Fairwinds', which tracks
an older release of the recommender (1.7.1, where the project's is 1.8.1). Fairwinds' chart is
published only to a classic Helm repository and no public OCI mirror carries it, so the application
has a `HelmRepository` beside its `HelmRelease`, which Renovate follows as it does the others. The
recommender reads container usage from metrics-server and writes a recommendation
to the status of each `VerticalPodAutoscaler` an application creates; it does not act on it. The
chart's updater and admission controller are off, so nothing evicts a pod and no webhook or
certificate generator is rendered, and no role bound in the release lets a service account change a
pod.

- The definitions (`VerticalPodAutoscaler` and its checkpoint) are in the chart's `crds/`
  directory, which Helm installs once and never removes with a release, so they stay when the
  application leaves the tree. Flux creates and replaces them on upgrade through the release
  defaults. `ks.yaml` sets `wait` and names `metrics-server`, whose API the chart's Helm test reads;
  metrics-server's own `ks.yaml` does not set `wait`, so on a new cluster the test can run before
  that API answers, fail, and use up an install retry.
- The chart's three `vpa-test-*` pods run after each install and upgrade, because the cluster's
  Helm releases run their tests. They set no requests, and the chart has no value to set them; they
  are the one exception to every container having requests, and they are left out of the check.
- One replica, with the chart's requests and no limits. The project's FAQ says only one recommender
  is active; a second would need `--leader-elect=true` and would add a second 500Mi request for a
  faster failover only, as the recommender keeps its history in checkpoint objects. There is
  therefore no disruption budget.
- The recommender keeps what it has seen as long as it runs, plus checkpoints. It could read
  history from the monitoring stack's Prometheus instead (`--storage=prometheus`), which gives it
  recommendations at once after a restart; that needs kubelet container metrics to be scraped under
  the names it expects, and nothing here configures it.
- A PodMonitor for the recommender.

### Reflector

`apps/base/kube-system/reflector/` runs Reflector in `kube-system`, from its publisher's chart on
its OCI registry. It copies a Secret or ConfigMap into other namespaces, which is how one wildcard
certificate serves several of them: the source carries
`reflector.v1.k8s.emberstack.com/reflection-allowed: "true"` and
`reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces`, and a copy is made in each
namespace the second names (`reflection-auto-enabled` and `reflection-auto-namespaces` make the
copies without the destination asking).

Reflector can read and write every Secret and ConfigMap in every namespace, and list and watch
namespaces: that is what it is for, and its ClusterRole grants exactly that and nothing else. The
control is the annotations: only an object carrying `reflection-allowed` is copied, and only into
the namespaces its annotation names. An empty `reflection-allowed-namespaces` allows every
namespace, so every source lists them. Nothing in this repository carries a reflection annotation
yet; `tests/autoscaling.bats` fails when a file under `kubernetes/` does.

One replica: Reflector has no leader election, so a second would copy what the first does, and
the chart makes no disruption budget. Its chart serves no metrics and has no monitor.

## Storage

Persistent volumes come from LINSTOR, run by the Piraeus operator, on the workers' data volumes
(ADR 0011). Two applications in `apps/base/piraeus-datastore/` hold it; their namespace admits
privileged pods, as LINSTOR's satellites, the CSI node plugin and the HA controller run privileged
with host paths.

- `piraeus-operator` installs the operator from its publisher's chart,
  `oci://ghcr.io/piraeusdatastore/piraeus-operator/piraeus`, with the baseline's shape. The chart
  installs the operator's resource definitions (`piraeus.io`) as templates of the release, so each
  chart upgrade upgrades them with the operator, and the HelmRelease's post-renderer gives each
  `helm.sh/resource-policy: keep`, so Helm leaves them when the release is uninstalled. Its
  `ks.yaml` sets `wait`: it is Ready once the operator is.
- `linstor-cluster` holds the storage cluster: the `LinstorCluster`, the
  `LinstorSatelliteConfiguration`s, the StorageClasses and the VolumeSnapshotClass. It names
  `piraeus-operator` and `snapshot-controller` in `dependsOn`, as the operator's webhooks validate
  its objects and every StorageClass of LINSTOR's driver, and the VolumeSnapshotClass needs the
  snapshot definitions ([Resource definitions](#resource-definitions)).

### What runs

From the `LinstorCluster` the operator runs the LINSTOR controller, LINSTOR's CSI driver
`linstor.csi.linbit.com`, the HA controller and a satellite on each node it selects: every node
without the label `node-role.kubernetes.io/control-plane`, which Talos gives every control plane
and no worker. That is every worker, by its role and never by its name, one OpenTofu adds later
included. A pod that uses a LINSTOR volume runs only on such a node.

The satellites run as the operator's Talos guide prescribes, in `talos.yaml`: without the module
loader, as the machine configuration loads DRBD and the device-mapper targets
([cluster.md](cluster.md#the-node-image)); without the shutdown guard and the host paths of
systemd, of the kernel's modules and of its sources, which Talos does not have; and with LVM's
configuration from the ConfigMap `talos-lvm-config`, which keeps the metadata backups and archives
that Talos's own configuration turns off. The satellite writes them under `/var/etc/lvm`, as `/etc`
is read-only on Talos.

### The storage pool

Every satellite has one LVM-thin pool, `data`, on the worker's data device,
`/dev/disk/by-partlabel/r-data` ([cluster.md](cluster.md#the-workers-data-device)). The first time,
LINSTOR makes the volume group `linstor_data` and the thin pool `data` from the device; afterwards
the operator registers what is there. A node without the device gets no pool, and its
`LinstorSatellite` says the device is missing. A device that already holds a file system or another
signature is not wiped and gets no pool either.

### StorageClasses

- `linstor-replicated`, the default: two replicas on two workers, kept in sync by DRBD. With three
  workers LINSTOR adds a diskless tiebreaker on the third, so the volume has quorum, and a replica
  that loses quorum suspends its I/O instead of failing it: its file system is not remounted
  read-only, and the HA controller evicts the pod, which starts again on a node with quorum. The
  volume is made once its first pod is scheduled, with a replica on that pod's node where it can
  be, and any node LINSTOR runs on reaches it, over the network where it holds no replica. It is
  formatted XFS and can be expanded. Use it unless the application keeps copies of its data itself.
- `linstor-node-local`: one replica, on the node the volume's first pod is scheduled to, reachable
  from that node only, so the pod stays there. It is a thin volume of the node's pool without DRBD:
  LINSTOR cannot give it a second replica or move it to another node, and losing the node's data
  volume loses it. Use it for an application that keeps copies of its data on other nodes itself,
  where DRBD would only add its metadata and a device in the path of every write.

A StorageClass's parameters cannot change once it exists: a change of parameters is a new class,
or the class deleted and made again, which leaves the volumes it made as they are.

### Snapshots

A VolumeSnapshot of a LINSTOR volume is the volume's content at that moment, kept as a thin snapshot
in the pool of each node that holds a replica. `snapshot-controller` serves VolumeSnapshots and
LINSTOR's CSI driver takes them, through `linstor`, the default VolumeSnapshotClass, which deletes
the snapshot with its VolumeSnapshot. A PersistentVolumeClaim that names the snapshot as its
`dataSource` gets a new volume with that content. A snapshot sits on the same workers as its volume,
so it is not a backup.

### Where the data lives

Every LINSTOR volume and snapshot lives on the workers' data volumes, which belong to the cluster
stack: `just cluster-destroy` destroys them with the stack, and every volume's data with them
([cluster.md](cluster.md#recipes)).

`tests/storage.bats` builds the three applications as Flux applies them; applies the satellite
configuration to the operator's own satellite DaemonSet at the version the pinned chart runs; renders
the nodes' machine configurations offline to check which nodes LINSTOR selects and which device the
pool takes; reads the StorageClasses and the VolumeSnapshotClass; and renders the operator's chart
to check that its definitions are kept.

## Volume backups

VolSync backs an application's volume up to the VolSync bucket
([infrastructure.md](infrastructure.md#s3-keys-and-backup-buckets)) with its restic mover, and
fills the volume from the latest backup when the volume and its restore are created together
(ADR 0015).

`apps/base/volsync-system/volsync/` installs the operator in its own namespace, `volsync-system`,
at the restricted Pod Security level. Its publisher releases the chart only to a classic Helm
repository, so it comes from the public OCI mirror metrics-server's comes from. The release
installs and upgrades the ReplicationSource and ReplicationDestination definitions, each kept when
it is uninstalled. The controller runs two replicas on different nodes, one acting at a time, with
the chart's requests and limits; the application's own disruption budget keeps one through a drain.
The chart's ServiceMonitor sends no credential, so the metrics are served without authorization.
The application names `snapshot-controller`, which VolSync needs installed, and
`prometheus-operator-crds` in `dependsOn`, and sets `wait`.

### Backing up a volume

An application opts in from its `ks.yaml`, before its volume exists, and names `volsync`,
`external-secrets` and `linstor-cluster` in `dependsOn`:

```yaml
spec:
  components:
    - ../../../../../components/volsync
  postBuild:
    substitute:
      APP: <app>
      VOLSYNC_CAPACITY: 1Gi
      VOLSYNC_SCHEDULE: "17 3 * * *"
```

The component backs up one volume per application. `APP` is the application's own name, the
`metadata.name` of its Kustomization: `just kubernetes-check` fails on a `ks.yaml` that adds the
component with any other `APP`, as two applications with one `APP` would share a repository.
`VOLSYNC_CLAIM` names the volume, `APP` when unset; `VOLSYNC_UID` and `VOLSYNC_GID`, 1000 when
unset, are the user and group the movers run as, which must be able to read and write its files.
The component makes:

- the volume, a claim of `VOLSYNC_CAPACITY` on the default StorageClass, whose data source is the
  ReplicationDestination `<app>-restore` ([Restoring](#restoring)). A claim's data source cannot be
  added once the claim exists, so a volume that exists keeps its data;
- the ReplicationSource `<app>`, which backs the volume up on the cron schedule `VOLSYNC_SCHEDULE`:
  it takes a snapshot through the default VolumeSnapshotClass, so the backup is of one moment, and
  restic uploads the files of a volume made from it. An empty volume is not backed up. Each run keeps
  the newest backup of each of the last 7 days, 4 weeks and 3 months, and every 7 days the
  repository is pruned. Each application takes its own minute, so backups do not start together;
- the ExternalSecret `<app>-volsync`, which writes the Secret the movers read
  ([The repository and its password](#the-repository-and-its-password)).

The movers run in the application's namespace, unprivileged: VolSync drops their capabilities and
forbids privilege escalation, and the component gives them a non-root user and group and the
runtime's seccomp profile, as the restricted level requires.

### Restoring

The ReplicationDestination `<app>-restore` restores the latest backup once, when it is created, as
its trigger is manual, and keeps a snapshot of what it restored; VolSync makes the claim from that
snapshot whenever the claim is created.

- When the claim and the ReplicationDestination are created together, on the application's first
  deployment, or after both were deleted, as when the application leaves the tree and comes back or
  the cluster is rebuilt, the volume starts with the latest backup, or empty when there is none.
- A claim deleted and created again while the ReplicationDestination stays gets the snapshot kept
  from that one restore, which after a first deployment is of an empty volume, not the latest
  backup.
- To restore the latest backup into an application that runs: suspend its Kustomization, and its
  HelmRelease when a chart runs it, as drift detection would undo a scale-down; stop the pods that
  use the claim; delete the claim and the ReplicationDestination `<app>-restore`; and resume what
  was suspended. Flux creates both again, the ReplicationDestination restores the latest
  backup, and the claim is made from it. What was written to the volume after that backup is lost.

`APP` and `BACKUP_BUCKET_PREFIX` name the repository, so neither changes once an application has
backups: under a path that holds no repository, restic creates an empty one and the restore
succeeds with an empty volume, without an error.

A claim stays Pending, with the pods that use it, until a pod uses it, as LINSTOR's classes make a
volume once its first pod is scheduled, and until the ReplicationDestination's first restore has
completed and recorded its snapshot in `status.latestImage`; that needs the Secret, so without the
secret store it never completes. A claim whose ReplicationDestination is gone, or whose recorded
snapshot is gone, stays Pending until the ReplicationDestination is created again. The claim's
events say which: `VolSyncPopulatorReplicationDestinationMissing`,
`VolSyncPopulatorReplicationDestinationNoLatestImage`, or `VolSyncPopulatorPVCCreated` once the
volume is being made; a missing snapshot shows in the VolSync controller's log. An application whose
Kustomization sets `wait` is not Ready while its claim is Pending, so it holds up every application
that names it in `dependsOn` until its first restore completes.

### The repository and its password

Each application has a restic repository of its own, `s3:<S3_ENDPOINT>/<BACKUP_BUCKET_PREFIX>-volsync/<app>`,
encrypted with a password of its own. restic creates the repository the first time a mover reaches
it. The ExternalSecret reads the key `volsync` of the ClusterSecretStore `openbao`, whose properties
are `RESTIC_MASTER_PASSWORD`, the master password, and the cluster's S3 key, `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY`. The Secret it writes holds only what its template renders:

- `RESTIC_REPOSITORY`: the repository, from `cluster-config`;
- `RESTIC_PASSWORD`: the application's password, derived from the master;
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`: the cluster's S3 key;
- `AWS_DEFAULT_REGION`: `S3_REGION`, from `cluster-config`.

An application's password is the SHA-256 digest of the master, a slash and the application's name,
with nothing after it, written as 64 lower-case hexadecimal digits. The component writes the master
into no Secret, so one application's Secret opens no other application's repository, and only the
master is kept outside the cluster. To open a repository with restic by hand, compute its password from the
master that way, with a tool that reads the master from a file or its standard input and never
from its command line, and give the password to restic in a file or from a command
(`RESTIC_PASSWORD_FILE`, `RESTIC_PASSWORD_COMMAND`), never as an argument. Every namespace that
takes the component holds the cluster's S3 key, which reaches every bucket of the project: whoever
can read Secrets there can read, replace or delete any application's backups, though not decrypt
them (ADR 0015).

### What is still needed

No ClusterSecretStore exists yet, so the Secret is never written and VolSync starts no mover. The
test application `apps/base/demo/volsync-demo/`, a pod that holds a 1 GiB volume and writes the
time it first found it empty, is disabled in the overlay. Before the first backup runs:

1. the ClusterSecretStore `openbao` holds the key `volsync` with `RESTIC_MASTER_PASSWORD`, also
   kept outside the cluster, and the cluster's S3 key as `AWS_ACCESS_KEY_ID` and
   `AWS_SECRET_ACCESS_KEY`;
2. `just cluster-config` has applied `BACKUP_BUCKET_PREFIX`, `S3_ENDPOINT` and `S3_REGION`;
3. `volsync-demo` is enabled in the overlay, with the store's application in its `dependsOn`.

`tests/volume-backups.bats` builds the applications as Flux applies them and renders the VolSync
and External Secrets charts to check this section.

## Envoy Gateway

Envoy Gateway implements the Gateway API: for each Gateway that names its GatewayClass it runs
Envoy proxies, which route traffic as the routes attached to the Gateway say. Two applications in
`apps/base/envoy-gateway-system/` install it:

- `envoy-gateway` installs the controller from its publisher's chart,
  `oci://docker.io/envoyproxy/gateway-helm`: two replicas, never on one node, with leader election,
  the chart's default, so one acts at a time; a disruption budget that keeps one running through a
  drain; the chart's resource requests. It also applies the GatewayClass `envoy-gateway` with the
  controller name the chart configures. A GatewayClass is cluster-scoped; the API server drops the
  namespace the application's `targetNamespace` gives it. The namespace enforces the restricted Pod
  Security level, which the controller, its certificate job and the proxies it creates meet. The
  chart makes no ServiceMonitor or PodMonitor, and the application adds none.
- `envoy-gateway-crds` applies Envoy Gateway's own resource definitions (`gateway.envoyproxy.io`)
  from the same chart at the same tag: an `OCIRepository` unpacks the chart, and an inner
  `Kustomization` applies its `charts/crds/crds/generated` directory, never pruning, as the Gateway
  API's inner `Kustomization` does. The publisher's chart of definitions alone keeps them in
  templates, too large for a Helm release to store.

The chart installs no definitions (`crds.enabled: false`): the Gateway API's come from
`gateway-api-crds`, so there is one copy, and it leaves out the Gateway API's admission policy as
that application does. The controller watches only the kinds whose definitions exist when it
starts, so `envoy-gateway` names both definition applications in `dependsOn`.

The two tags name one package, which Renovate updates in one pull request. Envoy Gateway is built
against one Gateway API release, the one its chart's own copy is of, and works with a newer
release's standard channel while that still serves the versions it reads. `tests/baseline.bats`
fails unless the release `gateway-api-crds` pins has the same major version, is no older, and
serves every stable kind and version of the chart's copy; an Envoy Gateway update that needs a newer
Gateway API therefore waits for `gateway-api-crds` to move first. The tests also render the chart
and build both applications offline to check the rest of this section.

No Gateway exists yet. A Gateway's proxies are reached through a Service of type LoadBalancer,
which needs the cloud controller, and its HTTPS listener needs a certificate from an issuer, which
cert-manager has none of yet. Until both are in place the controller accepts the GatewayClass and
runs no proxy.

## PostgreSQL

Applications get PostgreSQL from the CloudNativePG operator, which runs each database as a
`Cluster`: a primary and streaming replicas, a replica promoted when the primary fails, and the
Services and credentials an application connects with.

`apps/base/cnpg-system/cloudnative-pg/` installs the operator in its own namespace, `cnpg-system`, at
the restricted Pod Security level, from the publisher's chart in
`oci://ghcr.io/cloudnative-pg/charts`; it watches every namespace. The chart ships the
`postgresql.cnpg.io` definitions as templates of the release, so each chart upgrade upgrades them
with the operator, and marks each `helm.sh/resource-policy: keep`, so removing the application
leaves them, and every cluster, in place.
Two replicas run on different workers: the leader reconciles, both answer the webhook through which
the API server admits every change to a CloudNativePG object, and a disruption budget keeps one
through a drain. Its chart's PodMonitor is on, so it names `prometheus-operator-crds` in `dependsOn`,
and its `ks.yaml` sets `wait`.

An application takes a cluster from the component `components/cnpg-cluster`, in its `ks.yaml`:

```yaml
spec:
  dependsOn:
    - name: cloudnative-pg
    - name: prometheus-operator-crds
  components:
    - ../../../../../components/cnpg-cluster
  postBuild:
    substitute:
      CNPG_CLUSTER_NAME: <app>-db
      CNPG_STORAGE_SIZE: 10Gi  # each instance's volume; 5Gi when unset
```

The cluster has three instances of PostgreSQL 18, from the operator's standard image, whose tag names
a minor version that Renovate moves. The publisher rebuilds the image under that tag and a node keeps
the build it pulled first, so instances can run different builds of one minor version. Each instance
must run on a different worker, and requests and is limited to 500m CPU and 512Mi memory. The
operator's disruption budgets move the primary away by switchover before its worker is drained, and
let drains take one replica at a time. A PodMonitor scrapes every instance. Without
`CNPG_CLUSTER_NAME` the build fails. The operator creates the database `app`, owned by the user
`app`, whose password and connection URI are in the Secret `<name>-app`; the Services `<name>-rw`,
`<name>-ro` and `<name>-r` reach the primary, the replicas and any instance.

A patch in the application's own `kustomization.yaml` changes anything else, as it applies after the
component. It targets the Cluster by kind alone: Flux substitutes after the build, so when the patch
applies the Cluster is still named `${CNPG_CLUSTER_NAME}`, and a target by the name the application
gives it matches nothing and is skipped without an error.

```yaml
patches:
  - target:
      kind: Cluster
    patch: |-
      - op: replace
        path: /spec/resources/requests/memory
        value: 1Gi
      - op: replace
        path: /spec/resources/limits/memory
        value: 1Gi
```

Each instance's volume is on `linstor-node-local` ([StorageClasses](#storageclasses)), one copy on
the instance's own worker without DRBD. The three instances already are three copies on three
workers, kept in step by PostgreSQL's replication; the replicated default would keep each of them
twice, six copies of every write. The operator's documentation advises one replica at the storage
level, with no storage host holding two instances of a cluster, which the placement rule guarantees.
The cost is that an instance cannot move: while its worker is down the cluster runs on two. When the
worker or its data volume is lost for good, the instance's PersistentVolumeClaim and then its pod
are deleted, which removes the instance, and the operator clones a new one from the primary. With
three workers, the new one waits for a worker without an instance.

No backup is configured: WAL archiving and base backups to object storage need the object store's
credentials from the secret store, which does not run yet, and take their place in the component's
`Cluster` then. Until then a cluster's data lives only on the workers' data volumes
([Where the data lives](#where-the-data-lives)).

`tests/postgresql.bats` renders the operator's chart and checks its namespace, definitions,
replicas, budget, monitor and pods; builds applications that take a cluster from the component, one
that does not name it and two that patch it, by kind and by name, as Flux applies them; and checks
each field of the `Cluster` against the pinned chart's definition and its StorageClass against
LINSTOR's.

## Flux itself

The Flux Operator and the `FluxInstance` it runs Flux from are the cluster directory's two
applications, `flux-system/flux-operator/` and `flux-system/flux-instance/`, the only ones outside
`apps/`. Each has the application shape: `ks.yaml`, and in `app/` an `OCIRepository` for the
chart, the `HelmRelease`, its `values.yaml` generated into a ConfigMap that substitution leaves
alone, and `kustomizeconfig.yaml`, which points the release at that ConfigMap's hashed name. The
application rules apply with two differences: `sourceRef` is `OCIRepository` `flux-system`, as the
artifact generator publishes only `apps/base`, and `path` is
`./clusters/<cluster>/flux-system/<app>/app`. No application in `apps/base` may take their names.

- **Charts**: the operator's own `flux-operator` and `flux-instance` charts from
  `oci://ghcr.io/controlplaneio-fluxcd/charts`, at one version that Renovate moves together. Each
  `OCIRepository` refuses a chart without the keyless cosign signature of the publisher's release
  workflow on a version tag.
- **Instance**: upstream Flux 2.x, with source-watcher beside the four default controllers for
  the per-application artifacts, and Flux's network policies on.
- **Flux versions**: the operator installs the newest Flux 2.x release in its manifests artifact,
  `oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests`, which the instance pins to the
  operator chart's version. Flux therefore moves only when that tag moves, in the same Renovate
  pull request as the two charts, and a person merges it (ADR 0009); `tests/flux.bats` fails when
  the tag and the operator chart's version differ.
- **Sync**: the instance generates an `OCIRepository` and a `Kustomization`, both named
  `flux-system` after its namespace, that read `oci://ghcr.io/eekaan/k8s-gitops/manifests` at the
  tag `main` every minute and apply `./clusters/<cluster>`. Its patches make the source verify the
  artifact's keyless signature: issued by GitHub Actions to this repository's
  `.github/workflows/publish.yaml` on `refs/heads/main`. An artifact signed by a run on another
  branch or tag, or by another workflow, is refused (ADR 0003).

### One root

The instance's `flux-system` Kustomization applies the cluster directory: the root `cluster` from
`ks.yaml`, and `flux-operator` and `flux-instance`. The root applies `apps/overlays/<cluster>` and
gives its children the defaults above; it is the one root of the applications. `flux-system` sits
above it, and nothing in the tree defines a source or Kustomization of that name, so no two
objects apply the same thing. The instance patches `flux-system` with the same SOPS `decryption`
and `postBuild.substituteFrom` (`cluster-config`, `cluster-secrets`) that the root gives its
children, so the cluster directory's `ks.yaml` files are substituted like everything else;
`just kubernetes-check` builds each cluster directory as that Kustomization does, with strict
substitution. `flux-operator` and `flux-instance` are not children of the root and get none of
its defaults. They set the same `decryption` and `postBuild.substituteFrom` themselves, which the
check requires, so what they apply is decrypted and substituted like the root's children; and
they set their own interval, retry interval, timeout, `wait` and pruning. Their `HelmRelease`
objects likewise get none of the release defaults and set their own upgrade remediation: a failed
upgrade is retried three times, then rolled back. `flux-instance` waits for `flux-operator`, whose
chart defines the `FluxInstance` kind.

Both Kustomizations prune, but what manages Flux is kept from it. Their `HelmRelease` and chart
`OCIRepository` objects carry `kustomize.toolkit.fluxcd.io/prune: disabled`: garbage-collecting
the operator's release would uninstall the operator, and the instance's release would take the
`FluxInstance` with it, on which the operator deletes Flux's controllers. The instance chart also
gives the `FluxInstance` `helm.sh/resource-policy: keep`, so even an uninstalled release leaves it
in place. The values ConfigMaps are still collected when a change of values replaces them.
Removing either Kustomization from the cluster directory's `kustomization.yaml` fails
`just kubernetes-check`, as the cluster directory must build exactly the root, `flux-operator` and
`flux-instance`.

### Controllers

The instance's patches give kustomize-controller `--sops-age-secret=sops-age`. The controller
reads the Secret `sops-age` from its own namespace, `flux-system`, and takes the age key from each
of its data keys whose name ends in `.agekey`, such as `age.agekey`. It decrypts with that key
every Kustomization that uses SOPS and names no Secret of its own in `decryption.secretRef`, which
in this tree is every one. Like `cluster-config` and `cluster-secrets`, the Secret exists before
Flux does and nothing in the tree creates it; until it exists, every Kustomization that decrypts
fails, the root and Flux's own included. `just cluster-config` applies all three
([Before Flux starts](#before-flux-starts)).

Flux 2.10 still gates `ExternalArtifact` sources, which source-watcher produces, behind a feature
gate on kustomize-controller and helm-controller. The operator turns the gate on by itself
whenever source-watcher is among the instance's components, so the instance does not patch it.

`tests/flux.bats` renders both charts with these values, pulling each chart once, and applies the
instance's patches to the pinned Flux manifests to check the sync source, its signature identity,
the components and the age-key flag.

## Publishing

`.github/workflows/publish.yaml` publishes this tree as `oci://ghcr.io/eekaan/k8s-gitops/manifests`,
the artifact the instance syncs. It runs on every push to `main` that changes `kubernetes/` or the
workflow itself, and by hand (`workflow_dispatch`); never for a pull request, which gets neither
write access to packages nor an identity token. Its one command is `just publish`, which runs
`scripts/publish` on the runner rather than in the Dagger module, as signing takes the job's own
identity token (ADR 0007). The script refuses to run anywhere else: without GitHub Actions and the
job's identity token it stops before calling anything, so nobody signs from a laptop. In order, it:

1. runs `just kubernetes-check` on the commit it publishes, with the pinned tools the workflow
   installs; a failure stops the run, with the check's own message, before the registry is touched;
2. logs in to ghcr.io with the job's token on standard input, into a Docker configuration of the
   run's own, which flux and cosign both read and which is removed when the run ends;
3. pushes `kubernetes/`, without any cluster's `secrets/`, with `flux push artifact`, tagged with the
   full commit SHA, with the repository as its source and `<branch>@sha1:<commit>` as its revision,
   reproducibly; a reported digest that is not `sha256:` and 64 hexadecimal digits stops the run;
4. signs that digest keyless with cosign: a short-lived certificate for the job's identity, recorded
   in Sigstore's public transparency log;
5. verifies the signature against the identity of this workflow at the run's ref, which on `main`
   is the identity the instance accepts; a failure stops the run;
6. tags that digest `main`.

A pull request's checks run against its branch as it was pushed; the publish run judges the tree
that is on `main`, and only its own: the check runs on the commit the run publishes and on no other.
When that tree does not build, the run fails, nothing is pushed, signed or tagged, and the cluster
stays on the last tagged artifact until a run for a later commit that changes `kubernetes/` or the
workflow, or a manual run, publishes a tree that does. The gate is `just kubernetes-check`, the
offline build, and no more: `just render-check` pulls charts from the network and needs helm in the
job that signs, so it stays out of that job.

Every workflow installs its tools with the same pinned `mise-action` at an exact mise release. A
workflow whose token can write, `publish` and `render-comment`, also gives the action the checksum
of that release's linux-x64 binary, so the tools that run beside the token are the pinned ones; the
action fails the job when the binary differs. A bump of the mise version changes the checksum with it,
in every workflow that has one, and the checksum is the one for `./mise-v<version>-linux-x64` in the
release's `SHASUMS256.txt`. Renovate does not track either input: it can raise a version but cannot
carry the checksum with it, so a version alone would fail the signing job's check, and the bump is
by hand.
The publish job also turns the action's cache off, so nothing runs from an entry another job saved.

The tag moves last and by digest: `main` only ever names an artifact that is signed and verified,
and signing, verifying and tagging all name it by its digest, so the tag ends on exactly the bytes
that were signed and verified; a tag can change between two steps, a digest cannot. It moves only on
a run on `refs/heads/main` for which no newer commit on `main` changes `kubernetes/` or the
workflow, so an older run, a re-run of one included, never moves it back; the newest such commit's
own run decides, and a run does not judge a newer commit's tree. That leaves two cases in which the
tag stays on an older artifact than the newest passing commit's. In the first, a newer commit
that changes `kubernetes/` arrives before the passing commit's run reaches the tag, and fails its
check: the passing commit's run leaves the tag alone and the failing one publishes nothing, and the
same happens when GitHub replaces the passing commit's waiting run with the failing one's. In the
second, a re-run of an older run starts while the passing commit's run is waiting, and GitHub
replaces the waiting run with the re-run, which leaves the tag alone, as the passing commit is newer
than its own. In both, the tag stays where it was until a later run publishes a tree that passes:
the run of the next commit that passes, or, in the second case, a manual run as well. Runs
share one concurrency group that never cancels a run in progress, so they never overlap: a run that
starts while another is in progress waits for it, and GitHub replaces a waiting run with a newer one.
A run on another branch, or one a newer commit overtook, such as a re-run of an
old one, still pushes, signs and verifies, says why the tag stayed where it is, and succeeds. An
artifact signed by a run on another branch carries that branch's identity, which the instance
refuses. The run prints
its steps, the digest and whether the tag moved.

The signing identity is this workflow file on that branch: the subject
`https://github.com/eekaan/k8s-gitops/.github/workflows/publish.yaml@refs/heads/main` from the
issuer `https://token.actions.githubusercontent.com`, which the instance requires
([Flux itself](#flux-itself)). Renaming the workflow file, or publishing from another branch,
changes the identity, so the instance's patch changes in the same change. `tests/publish.bats` fails
when the identity the script verifies and the one the instance's values accept differ.

The package must be public for the cluster to pull it without credentials. GitHub makes a new
package private, and a package linked to its repository takes the repository's access permissions
but not its visibility, so the package's visibility is set to public in its settings once, after
the first run; until then the cluster cannot pull it. A public package cannot be made private
again.

## The render diff

A manifest change reaches the cluster only by merging (ADR 0003), so every pull request gets one
comment, updated on each push, that shows what Flux would apply differently once it is merged: a
table with the objects each application adds, removes and changes, then each changed application's
diff, collapsed. A pull request that changes nothing Flux applies says so.

`just render <out> [dir]` renders a tree as Flux applies it, offline, one file per object under
`<out>/<cluster>/<application>/`: the cluster directory as the instance's sync Kustomization applies
it (application `flux-system`), then every Kustomization that applies from the tree, the root
(`cluster`), Flux's own applications and each application the overlay enables, built as
`just kubernetes-check` builds them. Each HelmRelease is expanded to the objects its chart renders:
the chart its OCIRepository names at its tag, or the one its `chart.spec` names in a `HelmRepository`
(a classic `https://` repository or an OCI one) at an exact version, pulled from its public source at
the version the tree pins, with the values of its ConfigMaps and its own values over them, the
release name and namespace helm-controller gives it, the Kubernetes version in `versions.yaml`, every
API version a definition in the render serves, its post-renderers and helm-controller's labels. A
chart version bump therefore shows the objects that change. An application may take its chart only
from an `OCIRepository` (at a tag) or a `HelmRepository` (at an exact version), from a source that
names no credential (the render has no secrets), with values from ConfigMaps of the application; any
other form (a version range, a `GitRepository` or `Bucket`, a `secretRef`, values from a Secret)
fails the render, naming the release. `scripts/render --forms` checks that every release is of a form
the render accepts, without pulling a chart, and `tests/render.bats` runs it on this tree.
`RENDER_CHART_CACHE` names a directory to keep pulled charts in between renders. A tree that does
not render fails, naming the application. `just render-diff <base> <head>` prints the comment
comparing two renders.

What it is rendered with, and what it never shows:

- `cluster-config` and `cluster-secrets` are not in the repository: each cluster's
  `cluster-config.example.yaml` and `cluster-secrets.example.yaml` stand in for them, and the
  comment's footer says so.
- No Secret's data: every value of a Secret's `data` and `stringData` is replaced by `(redacted)`,
  keys kept, and sops' metadata is dropped, so a changed Secret value does not show. That includes
  the Alertmanager configuration, which the monitoring chart renders into a Secret.
- Values a chart makes up anew on every render, such as generated certificates and their CA
  bundles: the chart is rendered twice and every value that differs reads
  `(generated at render time)`, so they never show as a change.
- Sources outside the tree are not fetched: the Gateway API, snapshot and Envoy Gateway definitions
  show as the source and the inner Kustomization that apply them, not as the objects those apply.
- A diff longer than a comment holds is cut, and the comment says so: the smallest applications'
  diffs are shown whole, the next is cut, the rest are left out, and the table stays whole. The cut
  leaves room under GitHub's 65536 characters for the comment job's own line.

`just render-check`, one of the checks of `just ci`'s `static` group, renders the tree as the render
job does and keeps nothing, so a tree that does not render fails `just ci` as it fails the required
check. Pulling the charts and rendering take about half a minute.

In CI two jobs make it, in two workflows, so that nothing from a pull request ever runs with a token
that can write:

- The `render` job of `.github/workflows/ci.yaml`, part of the required check `ci`, runs for every
  pull request and push to `main` on a hosted runner, with the workflow's `contents: read` token and
  no secrets. For a pull request GitHub runs the pull request's own copy of the workflow, a fork's
  included, so the job is given nothing worth taking. `just ci-render` runs `scripts/render-pr` in
  the Dagger module (ADR 0007): it renders the base, the first parent of the commit under test, and
  the commit itself, both with the base's `scripts/render` and `scripts/render-diff`, so that a pull
  request that changes only the tree is shown by the reviewed render code. A base without the render
  code, or one its own render code does not render, is rendered with the commit's, and the job's
  log says so. The job uploads the comment as the artifact `render-diff`.
- `.github/workflows/render-comment.yaml` runs when the CI workflow completes for a pull request,
  unless that run was cancelled. GitHub runs it from the default branch, with this repository's
  token, whatever the run it follows had, so it checks out only the default branch and runs
  `just ci-comment`, with `actions: read` to download the artifact and `pull-requests: write` to
  comment; mise installs its tools without that token. `scripts/ci-comment` treats the artifact as
  text: it refuses anything but one regular file, `comment.md`, that `scripts/lib/render-comment.sh`
  accepts byte for byte, a comment `scripts/render-diff` could have written, never runs it or prints
  it, and sends it as a JSON string. Outside the fenced diffs that grammar allows only the fixed text,
  and application names and counts of a strict shape, so no mention, reference, link, image or HTML
  renders in the bot's name. It finds the pull request by the head commit and repository the run was
  for, and posts nothing when that head has moved on or two pull requests have it. It updates the one
  comment of its own that starts with the marker, or creates it, and adds a line of its own naming
  the commit the diff describes. A run that left no artifact did not render: the job updates its own
  comment, if there is one, to say so in its own words. It is not a required check: a comment that
  fails to post blocks no merge. An artifact that unpacks to far more than it holds fills only this
  job's runner.

The comment is the pull request's own account of its change. GitHub runs a pull request's copy of the
CI workflow, so a pull request that changes the render code, the CI workflow, the justfile or the
Dagger module can make the comment say anything the grammar allows, such as that nothing changes
while its manifests do. Review of such a pull request reads the change itself and does not rely on
the comment.

## Before Flux starts

Flux needs four objects that nothing in the tree creates, all in `flux-system`: the namespace
`flux-system` itself; the ConfigMap `cluster-config` and the Secret `cluster-secrets`, which every
Kustomization substitutes variables from; and the Secret `sops-age`, which kustomize-controller
decrypts with ([Controllers](#controllers)).

`just cluster-config [cluster]` applies them through the cluster's kubeconfig
([cluster.md](cluster.md#recipes)). It checks everything first, naming each problem, and applies
nothing until all of it is right. Each object reaches kubectl on standard input and is applied
server-side, so a second run changes nothing; no value is printed, passed as an argument or
written to disk.

`cluster-config` is rendered at run time and never committed. Its keys are exactly those of
`clusters/<cluster>/cluster-config.example.yaml`: the recipe fails naming each key the example lists
that it cannot fill, and each key it would fill that the example does not list. A key a manifest
starts to use is listed in the example and given its source in `fill_cluster_config` in
`scripts/lib/cluster.sh` in the same change. The values come from:

- `CLUSTER_DOMAIN`: the environment variable of that name, the domain the cluster's applications are
  published under, a lower-case DNS name.
- `BACKUP_BUCKET_PREFIX`: the environment variable of that name, the start of the backup buckets'
  names ([infrastructure.md](infrastructure.md#s3-keys-and-backup-buckets)).
- `S3_ENDPOINT` and `S3_REGION`: the object storage's S3 endpoint and region, `endpoints.s3` and
  `region` in `infra/openstack/backend.hcl`, where OpenTofu's state backend reads them. The endpoint
  is `https://`, a host name and an optional port, with nothing after them, as an S3 client reads a
  path there as the bucket.
- `NODE_CIDR`: `values.nodeSubnet` in `talos/<cluster>/talman.yaml`, which the cluster stack renders
  from the plumbing stack's node subnet and which the kubelets take their node addresses from.
- `NODE_NAME_REGEX`: the hostnames in that `talman.yaml`, joined with `|`, with a trailing number
  standing for any number: `lab-cp-1` becomes `lab-cp-[0-9]+`, so a node OpenTofu adds later, which
  it numbers after the others, matches as well.
- `SERVICE_RANGE`: `values.serviceRange` in that `talman.yaml`, the range `LoadBalancer` Services
  take their addresses from ([Service addresses](#service-addresses)).
- `BGP_CLUSTER_ASN` and `BGP_EDGE_ASN`: `values.bgp.clusterASN` and `values.bgp.edgeASN` there, the
  workers' and the edge routers' AS numbers.
- `BGP_EDGE_ADDRESS_1` and `BGP_EDGE_ADDRESS_2`: the two addresses of `values.bgp.edgeAddresses`
  there, the edge routers'.

The cluster stack renders the last five from the plumbing stack's numbers for BGP
([infrastructure.md](infrastructure.md#services-announced-over-bgp)).

`cluster-secrets` is decrypted from `clusters/<cluster>/secrets/cluster-secrets.sops.yaml` by sops,
with the Flux age key, straight into kubectl, when that file exists. Its keys must be exactly those
of `cluster-secrets.example.yaml`; sops encrypts values only, so the recipe reads them without
decrypting anything. Without the file an empty Secret is applied, which is all substitution needs,
and the example must list no key. Nothing in the tree lists `secrets/`, so Flux neither applies nor
prunes it, and publishing leaves `clusters/*/secrets/` out of the artifact
([Publishing](#publishing)): the artifact carries what Flux applies.

`sops-age` holds the Flux age key ([cluster.md](cluster.md#the-flux-age-key)) under the data key
`age.agekey`.

## Installing Flux

`just cluster-flux [cluster] [--reapply]` installs Flux on a cluster that has nodes and Cilium but
no Flux. It checks what `cluster-config` checks first, then:

1. It refuses a cluster that runs a FluxInstance already, as Flux manages itself from then on.
   With `--reapply` it applies the objects above again on such a cluster and installs nothing, as
   `just cluster-config` does.
2. It applies the objects above.
3. It installs `flux-operator` and then `flux-instance` from `clusters/<cluster>/flux-system/` with
   `install-app` ([below](#applications-installed-before-flux)), as the releases `flux-operator`
   and `flux-instance` in `flux-system`, which Flux adopts once it runs.
4. It waits up to ten minutes for the FluxInstance `flux` to report Ready, and prints the next
   step.

A run that stops once the FluxInstance exists is not run again: what keeps it from Ready is fixed
on the cluster, and from then on the operator and Flux take over.

## Applications installed before Flux

Some applications have to run before Flux can: the CNI, Cilium in `apps/base/kube-system/cilium/`,
as Flux cannot run before the cluster has a pod network, and Flux's own operator and instance. Each
is an application like any other, installed by a script first and adopted by Flux afterwards, and
the script reads it rather than a copy.

`just app-install <application directory>` runs `scripts/install-app` against the cluster the
`KUBECONFIG` environment variable names, for the directory that holds the application's `ks.yaml`
and `app/`. It takes the chart location and version from the application's `ocirepository.yaml`
and gives helm `values.yaml` as it is, then the values the HelmRelease sets itself, on standard
input, which helm merges over the first as helm-controller does. Where those use a variable, they
are what Flux makes of them: `install-app` reads the ConfigMap `cluster-config` from the cluster
and substitutes from its data alone with `flux envsubst --strict`, Flux's own substitution, so a
variable it does not hold and that has no default stops the install, named. The values reach
`flux envsubst` in its environment and leave it on a pipe.

The release is the one helm-controller makes of the HelmRelease: its `releaseName`,
`targetNamespace` and `storageNamespace` where it sets them, and otherwise the HelmRelease's name,
after its `targetNamespace` and a dash when it has one, in the HelmRelease's own namespace, the
`targetNamespace` of `ks.yaml`. A HelmRelease whose history would be kept in another namespace than
the release is refused, as helm keeps both in one. The script waits for the API server first, and
leaves a release that already runs that chart version with those values alone. Like the cluster
recipes, it refuses to run while `GODEBUG` sets `http2debug` ([cluster.md](cluster.md#environment)).

Once Flux manages a release, installing over it changes what Flux owns, and Flux undoes it at its
next reconcile. Flux's helm-controller labels every object it installs or upgrades with
`helm.toolkit.fluxcd.io/name` and `helm.toolkit.fluxcd.io/namespace`, naming the HelmRelease
(its post-renderer, in the helm-controller the pinned Flux runs), and helm keeps those objects in
the release's manifest. `install-app` reads that manifest with `helm get manifest` and refuses a
release whose objects carry the label, unless `--yes` is given:
`just app-install <application directory> --yes`, or `just cilium-install --yes`.

- `just cilium-install` runs `scripts/install-cilium`, which installs Cilium so and then waits for
  every node to be Ready.
- An application installed this way has a HelmRelease that names the release the script installs,
  so Flux upgrades that release instead of installing a second one. Cilium's sets `releaseName`,
  `targetNamespace` and `storageNamespace`; Flux's own leave them to helm-controller's defaults,
  `flux-operator` and `flux-instance` in `flux-system`.
- Substitution is disabled on the values ConfigMap, so the chart gets the same values on both
  paths, and a version change in `ocirepository.yaml` moves both.

The kubelet serving certificate approver, `apps/base/kube-system/kubelet-csr-approver/`, is also
such an application: until it runs, no kubelet has a serving certificate, so `kubectl logs` and
`kubectl exec` fail. Its HelmRelease sets `releaseName`, `targetNamespace` and `storageNamespace`
as Cilium's does, so Flux upgrades a release installed before it instead of installing a second
one. Unlike Cilium, it takes values from `cluster-config`, the name pattern and the node network,
through the HelmRelease's own values, which `install-app` substitutes as Flux does.
`just cluster-bootstrap` installs it so, after Cilium and once `cluster-config` is applied
([cluster.md](cluster.md#recipes)).

`just app-adoption <application directory> [cluster]` shows that Flux adopted such an application
as designed, through the cluster's kubeconfig as `just cluster-flux` uses it. Start it, then
`just cluster-flux`. It polls every `ADOPTION_INTERVAL` seconds, 10 when unset, until the
application's HelmRelease exists and is Ready for its current generation, for up to `ADOPTION_WAIT`
seconds, 900 when unset, and reads every node's Ready condition at each poll. A HelmRelease that is
stalled, or whose release or Helm tests fail, ends the wait with helm-controller's reason and
message. Then it prints pass or FAIL for each check, and exits 0 only when all of them pass:

- one release: exactly one Helm release has the HelmRelease's release name, in any namespace, so
  Flux did not install a second one;
- adopted: the release's first revision, installed before Flux, lacks the labels helm-controller
  gives the objects it installs, and the deployed revision has them, so helm-controller upgraded
  the release that was there;
- HelmRelease Ready: the HelmRelease is Ready, and its `status.history` gives the deployed revision
  the chart version in `ocirepository.yaml`, to which helm-controller appends the chart artifact's
  digest as build metadata; when the wait ended otherwise, what it waited for or the failure;
- nodes Ready: every node was Ready at every poll; a FAIL names each node that was not, and at how
  many polls.

It only reads, and prints object names: no node's address, no manifest, and none of kubectl's or
helm's own errors, which can name the API server's address. helm-controller's first revision may
restart the application's pods once: it renders the chart under that version with the digest, and
a chart that writes its version into its pod templates, as Cilium's does in the label
`helm.sh/chart`, changes every pod template.

`kube-system` exists before Flux does: its `namespace.yaml` only sets the namespace's labels, and
like every namespace it is never pruned.
