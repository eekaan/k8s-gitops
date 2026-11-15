Feature: Pod Security levels
  Every namespace the cluster deploys into enforces the strictest Pod Security level its workloads
  pass, and a workload that needs more says so by name and reason. The check evaluates the rendered
  pod templates with the Pod Security Standards' own policy library, offline.

  Scenario: A namespace's enforced level is the lowest its workloads pass
    Given a render whose namespaces enforce restricted, baseline and privileged, each the strictest level its workloads pass, with the workloads above restricted listed with their reasons
    When the Pod Security check runs
    Then it exits zero and reports each namespace with the level it enforces

  Scenario: A pod that needs more than its namespace enforces is refused, naming the checks it fails
    Given a namespace that enforces restricted and a workload in it that mounts a host path
    When the Pod Security check runs
    Then it exits non-zero and names the namespace, the workload and the checks the workload fails

  Scenario: A namespace that could enforce a lower level is refused
    Given a namespace that enforces baseline or privileged although every workload in it passes a stricter level
    When the Pod Security check runs
    Then it exits non-zero and names the namespace, the level it enforces and the level it could enforce

  Scenario: A workload above restricted is allowed only when it is listed with its reason
    Given a workload that fails restricted in a namespace that enforces the level it needs
    When the Pod Security check runs without the workload in the exceptions file, with an entry that has no reason, and with an entry for another level
    Then each run exits non-zero and names the workload

  Scenario: An application that deploys into an undeclared namespace is refused
    Given an application whose Kustomization targets a namespace that no Namespace manifest declares with an enforce level
    When the Pod Security check runs
    Then it exits non-zero and names the application and the namespace

  Scenario: An object in an undeclared namespace is refused
    Given a render with a Role in a namespace that no Namespace manifest declares with an enforce level
    When the Pod Security check runs
    Then it exits non-zero and names the namespace and the object

  Scenario: A namespace below restricted audits and warns at restricted at the cluster's minor
    Given a namespace that enforces baseline or privileged
    When the Pod Security check runs without its audit or warn label, with either at baseline, and with either version label other than the cluster's minor
    Then each run exits non-zero and names the namespace and the labels to set

  Scenario: A cluster minor newer than the one the evaluator covers is refused
    Given versions.yaml names a Kubernetes minor newer than the one recorded beside the evaluator's pin in mise.toml
    When the Pod Security check runs
    Then it exits non-zero and names both minors

  Scenario: The Flux controllers' namespace enforces a level and its controllers pass it
    Given the Flux install the tree's FluxInstance pins, with the FluxInstance's patches applied
    When the Pod Security check runs on the render of the tree
    Then the namespace flux-system enforces restricted, every controller is evaluated and passes it, and removing the patch that sets the level fails the check

  Scenario: The tree passes
    Given the tree with its real charts
    When just pod-security-check runs
    Then every namespace enforces the strictest level its workloads pass, every workload above restricted is listed with its reason, and every namespace that enforces less than restricted audits and warns at restricted
