Feature: Cilium
  One description of the CNI, used before Flux exists and by Flux afterwards.

  Scenario: The chart renders with the repository's values
    Given the pinned chart and values.yaml
    When the chart is rendered offline
    Then it renders without error, with no kube-proxy dependency and no ServiceMonitor objects

  Scenario: The install script uses the chart and values Flux uses
    Given the application's ocirepository.yaml and values.yaml
    When the install script runs against a recording helm
    Then helm is asked to install release cilium in kube-system from that chart location and version with that values file

  Scenario: The install script waits for the API server and the nodes
    Given an API server that answers on the third attempt
    When the install script runs against recording tools
    Then it retries until the API answers, installs, and waits for the nodes to be Ready

  Scenario: A failing install names the step
    Given a helm that fails
    When the install script runs
    Then it exits non-zero and the output names the failing step

  Scenario: An install over a release Flux manages is refused unless asked
    Given a Cilium release running other values, whose objects carry the label helm.toolkit.fluxcd.io/name that Flux's helm-controller sets
    When the install script runs, and then runs with --yes
    Then the first exits non-zero naming the release and saying Flux's helm-controller manages it, and upgrades nothing; the second upgrades the release

  Scenario: Flux adopts the installed release
    Given the HelmRelease
    When it is read
    Then its release name, target namespace and storage namespace are the ones the install script uses

  Scenario: Flux installs the chart and values the install script installs
    Given the application as Flux builds it from its ks.yaml and app/
    When its HelmRelease is read
    Then its chartRef names the one OCIRepository, which has the location and version of ocirepository.yaml, and its valuesFrom names only the ConfigMap generated from values.yaml, which holds that file byte for byte

  Scenario: Cilium assigns LoadBalancer addresses from exactly the service range
    Given a talman.yaml as the cluster stack renders it, and the cluster-config cluster-config makes of it
    When the chart is rendered and every application is built as Flux builds it
    Then LB IPAM is on, the tree holds one pool, whose one block is the service range, and it gives addresses only to Services labelled k8s-gitops/announce: bgp

  Scenario: Only workers speak BGP, and they peer with exactly the two edge routers, as the cluster's AS to the edge AS
    Given that talman.yaml and cluster-config, and every node's machine configuration rendered offline
    When the chart is rendered and every application is built as Flux builds it
    Then the BGP control plane is on and reports each peer's session in the node's BGP configuration, the tree holds one BGP cluster configuration and no per-node override, its node selector selects every worker and no control plane by the labels Talos gives them, and its one instance peers as the cluster's AS with the two edge addresses in the edge AS, which differs from it, with explicit timers, graceful restart, eBGP's single hop and no listening port

  Scenario: A worker carrying the opt-out label is not selected for BGP, and its kubelet cannot remove the label
    Given the BGP cluster configuration as Flux builds it, and the label key the cluster recipes set to take a node out
    When its node selector is applied to a worker, to a worker carrying that label with a value and with none, and to a control plane
    Then the worker is selected, neither labelled worker is, the control plane is not, and the key lies under node-restriction.kubernetes.io/, which the NodeRestriction admission plugin keeps a kubelet from setting or removing on its own Node

  Scenario: Only the addresses of Services that opt in are advertised; pod and ClusterIP ranges never are
    Given the applications as Flux builds them
    When the advertisements the peer configuration selects are read
    Then each advertises the LoadBalancer addresses of Services labelled k8s-gitops/announce: bgp and nothing else, a Service without that label is not selected, and no advertisement anywhere in the tree is of pod ranges, pod pools or interfaces

  Scenario: Layer 2 announcements stay off
    Given the pinned chart, values.yaml and the applications as Flux builds them
    When the chart is rendered
    Then Cilium's configuration enables neither Layer 2 announcements nor Layer 2 pod announcements, and the tree holds no Layer 2 announcement policy

  Scenario: A fresh bootstrap still installs Cilium before its own resource definitions exist
    Given a cluster with no Cilium and so none of Cilium's resource definitions
    When the install script runs against recording tools, and every application is built as Flux builds it
    Then the script installs the chart and applies no object, the Cilium application holds no object of Cilium's own kinds, every application that does names cilium in dependsOn and is enabled in the cluster overlay, and the Cilium application waits for its release, with the long timeout, so it is Ready only once every agent runs, which an agent does only once the operator has defined every kind it uses
