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
    Then it exits non-zero, the node is not uncordoned, no pod is deleted, and the recipe's last line says the node is left cordoned and how to uncordon it, or that it stays cordoned as it was

  Scenario: A cluster that still owns a load balancer or a volume is not destroyed, and they are named
    Given a Service of type LoadBalancer, a PersistentVolume of a CSI driver, or both, beside Services and volumes of other kinds
    When cluster-destroy runs with --yes
    Then it exits non-zero naming each as namespace/name or by the volume's name, without an address or a volume handle, no tofu runs, and the generated files stay

  Scenario: A cluster whose API does not answer is not destroyed unless asked
    Given an API that does not answer through the kubeconfig, or no kubeconfig at all
    When cluster-destroy runs with --yes, and then with --unreachable
    Then the first exits non-zero naming --unreachable and runs no tofu, the second destroys the cluster stack, and --unreachable does not let a cluster that answers and owns a load balancer be destroyed

  Scenario: Destroying the cluster leaves the plumbing stack, the secrets bundle and the buckets alone
    Given a cluster that owns no load balancer and no volume of a CSI driver
    When cluster-destroy runs with --yes
    Then the cluster is asked before tofu runs, every tofu call is on the cluster stack, which is planned for destruction, summarised and destroyed, none is on the plumbing stack, the talman.yaml, talosconfig and kubeconfig git ignores are removed, the secrets bundle stays as it was, and no S3 or OpenStack client runs

  Scenario: Nothing is destroyed without the stack's name
    Given a cluster that owns no load balancer and no volume of a CSI driver
    When cluster-destroy runs and no answer, a wrong one, the cluster's name or the plumbing stack's name is typed back
    Then no tofu apply runs and the generated files stay; with sto2/cluster typed back the stack is destroyed

  Scenario: No address reaches the output of any of the three recipes
    Given node status, pod status, Services, pod logs, kubectl's errors, talman's output and tofu's plan and report that hold addresses, and an API address in the environment
    When cluster-check, cluster-reboot and cluster-destroy run, succeeding and failing, and with CI set
    Then none of those addresses appears in anything they print, talman's output, which names nodes by address, included with CI set, when it goes to the cluster's clusterconfig/cluster-reboot.log
