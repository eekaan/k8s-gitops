Feature: Cluster lifecycle
  One recipe says whether the cluster is healthy, one reboots a node while watching that the Kubernetes API keeps answering through its load balancer, and one takes the cluster down without leaving behind what it made in the cloud.

  Scenario: A healthy cluster passes every check
    Given six Ready nodes, as many as talman.yaml lists, no kube-proxy pod, an API that answers /readyz, every pod in kube-system and flux-system Running or Succeeded, no certificate signing request Pending and a pod whose logs can be fetched
    When cluster-check runs
    Then it prints pass for every check and exits zero

  Scenario: Each unhealthy condition fails its own check and is named
    Given, one at a time, an API that answers but not /readyz, a node that is not Ready, a node of talman.yaml missing from the cluster, a kube-proxy pod, a failing pod in kube-system or in flux-system, a certificate signing request Pending, and pod logs that cannot be fetched
    When cluster-check runs for each
    Then it exits non-zero, that condition's check prints FAIL naming the node, pod or request where there is one, and every other check passes

  Scenario: The health check changes nothing in the cluster
    Given a healthy cluster and an unhealthy one
    When cluster-check runs
    Then every kubectl call it makes is a get or a logs, it runs nothing else that reaches the cluster or the cloud, and no file of the repository changes

  Scenario: Before Flux is installed the Flux checks are skipped, and said to be
    Given a cluster without the namespace flux-system
    When cluster-check runs
    Then the check of the pods in flux-system prints skip, saying the namespace does not exist as before Flux is installed, the last line names the skipped check, and the run exits zero; a failing pod in kube-system still fails

  Scenario: cluster-check fails, naming job and node, while a component's scrape target is down
    Given Prometheus reporting down the etcd targets on cp-1 and cp-2 and the node-exporter target on worker-3, and one of an application that is none of the cluster's own components
    When cluster-check runs
    Then the scrape check prints FAIL naming each job and its nodes and no address, every other check passes, the run exits non-zero, and Prometheus was asked through the API server's service proxy with kubectl get; with every component's target up it passes, saying how many targets it saw

  Scenario: cluster-check skips the scrape check, saying why, without the monitoring stack or without an answer from Prometheus
    Given a cluster without Prometheus's Service, one whose Prometheus does not answer through the service proxy, one whose Prometheus answers with an error, and ones whose answer holds no target of a component's job
    When cluster-check runs for each
    Then the scrape check prints skip with the reason, never pass, the last line names it among the skipped checks, no address is printed and the run exits zero

  Scenario: A reboot that the API rides out passes
    Given a node of talman.yaml and an API that answers throughout
    When cluster-reboot runs for it and its name is typed back, and with --yes
    Then talman reboots exactly that node, /readyz is asked through the kubeconfig while talman runs, the node is waited for until it reports Ready after the reboot, no probe failed, and the run exits zero

  Scenario: A reboot during which the API stops answering fails and reports the gap
    Given an API that stops answering /readyz for a few seconds while the node reboots
    When cluster-reboot runs
    Then it reports as many failed probes as the API refused and the longest run of failures in seconds, says --tolerate accepts such a gap, and exits non-zero although the node is Ready again

  Scenario: A tolerated gap passes and is still reported
    Given an API that stops answering /readyz for a few seconds while the node reboots
    When cluster-reboot runs with --tolerate longer than the gap, and with --tolerate shorter than it
    Then the first reports the failed probes and the gap and exits zero, and the second exits non-zero

  Scenario: A node that does not come back fails when the wait runs out
    Given a node whose kubelet never reports again after talman reboots it, while its Ready condition from before stays
    When cluster-reboot runs with a short REBOOT_WAIT
    Then it asks for the node more than once, stops when the wait runs out, reports the probes and exits non-zero saying the node has not reported Ready since its reboot

  Scenario: A control plane that is Ready again without its etcd member fails the reboot
    Given a control plane whose etcd member does not come back after talman reboots it, while its kubelet reports Ready
    When cluster-reboot runs for it with a short REBOOT_WAIT, then for one whose member comes back a few seconds late, for one after whose reboot etcd holds a member that is no control plane of talman.yaml, and for a worker
    Then the first asks etcd status of every control plane through the Talos API more than once, exits non-zero naming the node and saying not every control plane's member answered, leaves it cordoned and prints no address; the second waits for the member and passes; the third fails naming the other member by its hostname; the worker's reboot asks etcd nothing

  Scenario: A control plane is not rebooted while etcd lacks a healthy member or holds one that is no control plane
    Given etcd whose member on another control plane is down before anything is rebooted, and then etcd holding a member, by the hostname cp-old, that talman.yaml does not list
    When cluster-reboot runs for a control plane, with --yes and with its name to be typed back, and then for a worker
    Then for the control plane it exits non-zero before it asks for the name, saying etcd is not whole and why, naming cp-old by its hostname and printing no address, and nothing is cordoned, drained or rebooted; the worker is rebooted, and etcd is not asked

  Scenario: A node that is not in the cluster is refused before anything is rebooted
    Given a hostname talman.yaml does not list, a node's address, two nodes in one argument and a prefix of a hostname
    When cluster-reboot runs for each
    Then it exits non-zero saying the node is not one of the cluster's, naming the nodes talman.yaml lists and never the address, and no talman or kubectl runs

  Scenario: The probe leaves nothing running behind, whether the reboot succeeds, fails or is interrupted
    Given a reboot that succeeds, one with a gap, one talman fails, one whose node does not come back, and one interrupted by SIGINT or SIGTERM while talman reboots
    When cluster-reboot runs for each
    Then afterwards no process of the probe, of kubectl or of its sleep runs, no file is left in TMPDIR, and no probe is made once the recipe has ended

  Scenario: The node is drained before it is rebooted and uncordoned once it is Ready
    Given a schedulable node of talman.yaml
    When cluster-reboot runs for it
    Then, with the probe already running, kubectl cordons the node and drains it as cluster-upgrade drains, through the kubeconfig, talman reboots it with talosctl's own drain off, so the node is unschedulable when it goes down, and only once it reports Ready after the reboot is it uncordoned; no other node is cordoned, drained or uncordoned, and cluster-check passes afterwards

  Scenario: A node that was cordoned before the reboot stays cordoned
    Given a node that is unschedulable before cluster-reboot runs
    When cluster-reboot runs for it
    Then it is drained and rebooted, it is not uncordoned once it is Ready, and the recipe says it stays cordoned as it was

  Scenario: Pods the shutdown left Failed on the node are removed, and nothing else
    Given pods the node's shutdown leaves in phase Failed on it with the reason NodeShutdown or Terminated, beside a Failed pod there with another reason, Failed pods with those reasons on other nodes, and a running pod on the node
    When cluster-reboot runs for the node, and again with a shutdown that leaves nothing
    Then once the node is back exactly the shutdown's pods are deleted, by namespace and name through kubectl, and the recipe says how many; the others stay, cluster-check still fails on the Failed pod with another reason, and with nothing left nothing is deleted and the recipe says so

  Scenario: A failed reboot leaves the node cordoned and says so
    Given a drain that cannot evict a pod, a reboot talman fails, or a node that does not come back
    When cluster-reboot runs for each, and for a node that was cordoned before and fails to reboot
    Then it exits non-zero, the node is not uncordoned, no pod is deleted, and the recipe says the node is left cordoned and how to uncordon it, or that it stays cordoned as it was, in the line before the one that says the node is out of BGP

  Scenario: A failed drain says why without the API's address
    Given a drain that fails because kubectl cannot reach the API, its error naming the API server's address, and an API address in the environment
    When cluster-reboot runs for a node, without CI and with CI set
    Then it exits non-zero showing the reason, connection refused, with neither the address nor the port, reboots nothing, and says the node is left cordoned and then that it is out of BGP

  Scenario: A planned reboot takes the worker out of BGP, waits until it announces nothing, and puts it back once it is Ready
    Given a worker whose BGP node configuration follows the opt-out label only after a few reads, out and in, one of whose two peers is established late; and a cluster whose workers' sessions are never established; a worker cordoned before the run; and BGP_WAIT=08 with a configuration that takes three reads, six seconds, to go
    When cluster-reboot runs for each
    Then it sets the label, reads the node's BGP configuration until it is gone, and only then cordons and drains the node, which announces nothing when it is drained and when it goes down; once the node is Ready and uncordoned and its Cilium agent forwards it removes the label and reads the configuration until it is back with both peers established; no other node is labelled, and cluster-check passes afterwards; with no session established before or after, it succeeds all the same, saying it does not wait for one, with the node uncordoned and the label removed; the worker cordoned before stays cordoned and has its label removed once it is Ready; and with BGP_WAIT=08, read in base 10, the configuration is read until it is gone before the node is cordoned and drained

  Scenario: A rebooted worker is put back into BGP only after its Cilium agent reports that it forwards
    Given a worker whose Cilium agent pod still reports the Ready it posted before the node went down, then is not Ready twice, and then is Ready since the reboot; and a control plane
    When cluster-reboot runs for the worker, and for the control plane
    Then once the node is Ready and uncordoned the agent's pod is read until it is Ready since the reboot, and only then is the label removed, after which the BGP configuration is awaited as before; the run says the agent has been Ready since the reboot for the settle time and that the worker is put back; no agent is read for the control plane

  Scenario: A worker whose agent never reports that it forwards stays out of BGP, and the run says so last
    Given a worker whose Cilium agent pod is never Ready after the reboot, keeps the Ready it posted before the node went down, does not exist, cannot be read, or is never Ready while the run has --no-bgp-wait and the worker's BGP configuration stays
    When cluster-reboot runs for the worker with FORWARD_WAIT=4
    Then each exits non-zero after the node is rebooted, Ready and uncordoned, with the label still on it and never removed, saying what was waited for and for how long, or that the agent could not be read and so it is not known whether the node forwards, and the last line says the worker is out of BGP and gives the kubectl command that puts it back; --no-bgp-wait does not skip the wait

  Scenario: A recipe killed outright does not leave the cluster locked
    Given a cluster-reboot that is sent SIGKILL while talman reboots a control plane and its probe of /readyz runs
    When the lock's file is locked afterwards, and cluster-reboot runs again for a node the cluster does not have
    Then the probe runs on, the lock is free, and the second run is not refused as busy

  Scenario: A recipe that stops while a worker is out says so last, with the command that puts it back
    Given a drain that fails, a reboot talman fails, SIGTERM while talman reboots, a node that does not come back, a node whose BGP configuration never goes, a node already out from an earlier run, a node that does not announce again once put back, a BGP configuration that cannot be read before the label and after it, and another worker that is out
    When cluster-reboot runs for each, and once more for the node left out by an earlier run
    Then each exits non-zero with the node still out and the last line saying it is out of BGP and the kubectl command that puts it back, except that a node that never withdraws is neither cordoned nor drained nor rebooted and is said to keep its BGP configuration, as when its Cilium agent is not running, a node already out is recognised and not labelled again, the node that does not announce again has its label removed and is said not to announce again, a configuration that cannot be read is said so and not taken for one that is gone, and nothing is labelled, cordoned, drained or rebooted for a worker while another is out, which the last line names; the rerun that succeeds puts the node back and reads its BGP configuration until it is back, saying that which of its sessions were established before is not known; the run that SIGTERM ends names the step it failed in, then that the node is left cordoned, and last that it is out of BGP

  Scenario: cluster-check fails while a Ready worker is out of BGP
    Given a Ready worker carrying the opt-out label, then one that is not Ready, and then a control plane carrying it
    When cluster-check runs for each
    Then the first fails the check of workers in BGP, naming the worker and the command that puts it back, and no other check fails; neither the second nor the third fails that check

  Scenario: A control plane is rebooted without any BGP step
    Given a control plane of talman.yaml
    When cluster-reboot runs for it
    Then it is rebooted, nothing is labelled, no BGP configuration is read and the recipe says nothing of BGP

  Scenario: A worker whose BGP configuration does not go is rebooted with --no-bgp-wait, which skips only the wait for its withdrawal
    Given a worker whose BGP configuration stays although it carries the opt-out label, as when its Cilium agent is not running to take the label up, and that takes a few reads to come back once the label is removed; and a control plane
    When cluster-reboot runs for the worker without --no-bgp-wait and with it, and with it and a drain that fails, and for the control plane with it
    Then without it the run stops before the drain, saying the configuration is still there after BGP_WAIT seconds, as when the node's Cilium agent is not running, and last that the worker is out of BGP; with it the worker is labelled and then cordoned and drained with no read of its BGP configuration before the drain, one line says the wait was skipped and that the edge routers may keep its paths as stale for up to the restart time, it goes down out of BGP, and once it is Ready and uncordoned the label is removed and the configuration read until it is back; with it and a drain that fails, the last line says the worker is out of BGP and gives the command that puts it back; the control plane is rebooted with no BGP step

  Scenario: A cluster that still owns a load balancer or a volume is not destroyed, and they are named
    Given a Service of type LoadBalancer, a PersistentVolume of a CSI driver other than LINSTOR's, or both, beside Services and volumes of other kinds, LINSTOR's among them
    When cluster-destroy runs with --yes
    Then it exits non-zero naming each as namespace/name or by the volume's name, and no volume of LINSTOR, without an address or a volume handle, tofu only reads the stack's state and outputs, and the generated files stay

  Scenario: A Service on a pool address does not block a destroy, and a Service on any other load balancer still does
    Given a Service of type LoadBalancer whose address lies in the service range of the cluster's talman.yaml, beside one whose address lies outside it or one with no address yet
    When cluster-destroy runs with --yes for the first alone, for it beside each of the others, and for it with a talman.yaml that names no service range
    Then the first alone is destroyed; beside either other, or without a service range to compare with, nothing is destroyed and only the Services that block are named

  Scenario: LINSTOR's volumes go with the cluster stack once the destroy is confirmed, and are counted first
    Given PersistentVolumes of LINSTOR's CSI driver, whose data is on the workers' data volumes in the cluster stack, and no other load balancer or volume the cluster made
    When cluster-destroy runs and no answer, a wrong one or the stack's name is typed back, and with --yes
    Then before it asks it says how many volumes of LINSTOR are destroyed with the stack, without a volume's name, an address or a volume handle; nothing is destroyed without the stack's name, and with it or with --yes the stack is destroyed

  Scenario: A cluster whose API does not answer is not destroyed unless asked
    Given an API that does not answer through the kubeconfig, or no kubeconfig at all
    When cluster-destroy runs with --yes, and then with --unreachable
    Then the first exits non-zero naming --unreachable and tofu only reads the stack's state and outputs, the second destroys the cluster stack, and --unreachable does not let a cluster that answers and owns a load balancer be destroyed

  Scenario: Destroying the cluster leaves the plumbing stack, the secrets bundle and the buckets alone
    Given a cluster that owns no load balancer and no volume of a CSI driver
    When cluster-destroy runs with --yes
    Then the cluster is asked before anything is planned, every tofu call is on the cluster stack, which is planned for destruction, summarised and destroyed, none is on the plumbing stack, the talman.yaml, talosconfig and kubeconfig git ignores are removed, the secrets bundle stays as it was, and no S3 or OpenStack client runs

  Scenario: The cluster stack is asked the same way whichever recipe destroys it
    Given a cluster that owns a Service of type LoadBalancer or a PersistentVolume of another CSI driver, one whose only Service of that type is on a pool address, one whose API does not answer, and one that owns nothing
    When infra-destroy runs with sto2/cluster and without a stack, with --yes, and with --unreachable
    Then it asks the cluster as cluster-destroy does and refuses what cluster-destroy refuses, naming what the cluster owns or --unreachable, before it plans anything, and a Service on a pool address blocks neither; it prints no step it does not take; and what the cluster owns nothing of is destroyed

  Scenario: A destroy that is run again ends as the first run did, with the cluster stack gone or never applied
    Given a lab where infra-destroy has destroyed both stacks, so the cluster stack's state holds no resource and its kubeconfig is gone, and a lab where only the plumbing stack and the CI host were applied
    When infra-destroy runs again with --yes, and with sto2/cluster
    Then it exits zero, says the cluster stack holds no resource, asks no cluster, plans and destroys nothing for the cluster stack, and the plumbing stack is planned and destroyed as before

  Scenario: A cluster stack that holds resources and cannot be asked is still refused unless --unreachable is given
    Given a cluster stack whose state holds resources and a cluster that has no kubeconfig, one whose outputs name no cluster, and one whose state cannot be read, answers with nothing or with text that is no state
    When infra-destroy runs with --yes, and then with --unreachable
    Then the first exits non-zero naming --unreachable and plans nothing; with --unreachable the stack is destroyed, unless its state cannot be read, or its outputs name no cluster and it is not given --unreachable; an unreadable state refuses whatever is given

  Scenario: A cluster destroy that is run again ends as the first run did, with the cluster stack holding nothing
    Given a cluster stack that is destroyed already, so its outputs name no cluster and its state holds no resource, with the cluster's generated files still there or gone, a name with no directory under talos/, and one whose state cannot be read
    When cluster-destroy runs for the cluster, with --yes and with --unreachable
    Then for the destroyed stack it exits zero, says the stack holds no resource, removes the generated files that are there and asks and plans nothing; a name with no directory is refused; a state that cannot be read exits non-zero, naming the stack and leaving the files, and another cluster's files are left alone

  Scenario: A stack whose state could not be reached is not taken for one that holds nothing
    Given the ci stack, whose state holds a resource, and a lock on it that cannot be taken, or a read of its state that ends without saying what it found
    When infra-destroy runs with --yes, and with sto2/plumbing
    Then it exits non-zero naming the ci stack as one whose state cannot be read, destroys nothing and runs no tofu beyond reads

  Scenario: A cluster is destroyed only under the name its stack holds
    Given the cluster stack, whose talman_yaml output names lab-sto2, and a name with no directory under talos/, one with a directory that is not the stack's cluster, lab-sto2 without a directory, and a stack whose outputs name no cluster while its state holds resources
    When cluster-destroy runs for each, with --unreachable and --yes
    Then each exits non-zero, before any cluster is asked, tofu only reads the stack's state and outputs and leaves the generated files of lab-sto2 where they are; a name other than lab-sto2 is told lab-sto2 is the cluster the stack holds, a stack that names none is said to, and lab-sto2 without a directory is told so

  Scenario: Nothing is destroyed without the stack's name
    Given a cluster that owns no load balancer and no volume of a CSI driver
    When cluster-destroy runs and no answer, a wrong one, the cluster's name or the plumbing stack's name is typed back
    Then no tofu apply runs and the generated files stay; with sto2/cluster typed back the stack is destroyed

  Scenario: No address reaches the output of any of the three recipes
    Given node status, pod status, Services, pod logs, kubectl's errors, talman's output and tofu's plan and report that hold addresses, and an API address in the environment
    When cluster-check, cluster-reboot and cluster-destroy run, succeeding and failing, and with CI set
    Then none of those addresses appears in anything they print, talman's output, which names nodes by address, included with CI set, when it goes to the cluster's clusterconfig/cluster-reboot.log
