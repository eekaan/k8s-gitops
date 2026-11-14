Feature: Kubernetes tree layout
  Every application has the same shape, and the tree builds without a cluster.

  Scenario: The tree builds offline
    Given the kubernetes directory and no cluster
    When the kubernetes check runs
    Then every kustomization builds, Flux builds every ks.yaml with strict substitution, and the check exits zero

  Scenario: A Kustomization outside flux-system fails the check
    Given an application whose ks.yaml sets another namespace
    When the kubernetes check runs
    Then it exits non-zero and names the file and the rule

  Scenario: An undeclared substitution variable fails the check
    Given a manifest using a variable that is not in the example cluster-config and has no default
    When the kubernetes check runs
    Then it exits non-zero and names the file and the variable

  Scenario: An application without an app directory fails the check
    Given an application directory that has ks.yaml but no app directory
    When the kubernetes check runs
    Then it exits non-zero and names the directory

  Scenario: Children inherit the root defaults
    Given the root Kustomization
    When it is built
    Then every child without the opt-out label gets the interval, retry interval, timeout, pruning, decryption, deletion policy, substitution from cluster-config and cluster-secrets, and the HelmRelease defaults, and a child with the opt-out label gets none of them

  Scenario: HelmReleases applied by a child get the release defaults unless they opt out
    Given a child Kustomization built from the root, and two HelmReleases of which one carries the opt-out label
    When the child's patches are applied to them
    Then the other gets the install and upgrade remediation, CRD policy, test, rollback, uninstall, drift detection and history defaults, and the labelled one is unchanged

  Scenario: The long-timeout label lengthens the timeout and keeps the other defaults
    Given a child with the long-timeout label, and one that carries both the long-timeout and the opt-out label
    When the root Kustomization is built
    Then the first gets the long timeout and every other default, and the second keeps its own timeout and gets no defaults

  Scenario: A ks.yaml that is not a Flux Kustomization fails the check
    Given an application whose ks.yaml is a kustomize Kustomization instead of a Flux one
    When the kubernetes check runs
    Then it exits non-zero and names the file and the rule

  Scenario: A Kustomization without a sourceRef fails the check
    Given an application whose ks.yaml has no sourceRef
    When the kubernetes check runs
    Then it exits non-zero and names the file and the rule

  Scenario: An application without a targetNamespace fails the check
    Given an application whose ks.yaml has no targetNamespace
    When the kubernetes check runs
    Then it exits non-zero and names the file and the rule

  Scenario: A kustomization that does not build fails the check
    Given an application whose kustomization.yaml lists a file that does not exist
    When the kubernetes check runs
    Then it exits non-zero and names the kustomization.yaml

  Scenario: A root Kustomization whose patches do not apply fails the check
    Given a root Kustomization with a patch that is not valid YAML
    When the kubernetes check runs
    Then it exits non-zero and names the root ks.yaml

  Scenario: A cluster directory without a kustomization.yaml fails the check
    Given a cluster directory holding ks.yaml and the example key list but no kustomization.yaml
    When the kubernetes check runs
    Then it exits non-zero and names the directory

  Scenario: A cluster directory that builds more than the root Kustomization fails the check
    Given a cluster directory whose kustomization.yaml lists another manifest beside ks.yaml
    When the kubernetes check runs
    Then it exits non-zero and names the directory and the extra object

  Scenario: A ks.yaml that is not valid YAML fails the check
    Given an application that is not enabled in the overlay whose ks.yaml is not valid YAML
    When the kubernetes check runs
    Then it exits non-zero and names the file

  Scenario: A ks.yaml with an empty document passes the check
    Given an application whose ks.yaml ends with a document separator
    When the kubernetes check runs
    Then it exits zero

  Scenario: The check gives its tools no cluster to reach
    Given a kubeconfig and an in-cluster service address in the environment
    When the kubernetes check runs
    Then every flux and kustomize it runs sees an empty kubeconfig and no service address

  Scenario: An application whose names do not match its directory fails the check
    Given an application whose Kustomization name, or whose sourceRef name, is not its directory name
    When the kubernetes check runs
    Then it exits non-zero and names the file and the field

  Scenario: An application whose targetNamespace is not its namespace directory fails the check
    Given an application under one namespace directory whose ks.yaml targets another namespace
    When the kubernetes check runs
    Then it exits non-zero and names the file and the namespace it must target

  Scenario: An application whose path is not its own app directory fails the check
    Given an application whose ks.yaml path points at another application's app directory
    When the kubernetes check runs
    Then it exits non-zero and names the file and the path it must use

  Scenario: An application name that is not a DNS label fails the check
    Given an application directory named with capitals and an underscore
    When the kubernetes check runs
    Then it exits non-zero and names the directory

  Scenario: Two applications with the same name fail the check
    Given applications with the same name in two namespace directories, only one of them enabled
    When the kubernetes check runs
    Then it exits non-zero and names both directories

  Scenario: An application that sets a field the root overrides fails the check
    Given an application without the opt-out label whose ks.yaml sets interval, retryInterval, timeout, prune, deletionPolicy, decryption, patches and postBuild.substituteFrom
    When the kubernetes check runs
    Then it exits non-zero and names the file and each of those fields

  Scenario: An application with the opt-out label may set the fields the root overrides
    Given an application with the opt-out label whose ks.yaml sets those same fields
    When the kubernetes check runs
    Then it exits zero

  Scenario: Variables Flux leaves alone pass the check
    Given undeclared variables only in Helm values fed through a generator marked substitute disabled, in an object marked substitute disabled, in a YAML comment and behind an escaped $${VAR}
    When the kubernetes check runs
    Then it exits zero

  Scenario: Variables the application or the cluster declares pass the check
    Given a variable set in the application's own postBuild.substitute, one listed in the example cluster-secrets key list and one with a default
    When the kubernetes check runs
    Then it exits zero

  Scenario: An undeclared variable in a generator's input file fails the check
    Given a JSON file fed to a ConfigMap generator that uses an undeclared variable
    When the kubernetes check runs
    Then it exits non-zero and names the file and the variable

  Scenario: An undeclared variable after an escaped dollar fails the check
    Given a manifest with $$${VAR} for an undeclared variable, which Flux substitutes after the escaped dollar
    When the kubernetes check runs
    Then it exits non-zero and names the file and the variable

  Scenario: A default Flux cannot parse fails the check
    Given a manifest with ${VAR-default}, which Flux rejects
    When the kubernetes check runs
    Then it exits non-zero and names the application's ks.yaml and Flux's error

  Scenario: An undeclared length expansion is named with its file
    Given a generator input file whose name holds a colon and that uses ${#VAR} for an undeclared variable
    When the kubernetes check runs
    Then it exits non-zero and names the file and the variable

  Scenario: An undeclared variable in a namespace directory fails the check
    Given a namespace manifest, which the root Kustomization substitutes, using an undeclared variable
    When the kubernetes check runs
    Then it exits non-zero and names the file and the variable
