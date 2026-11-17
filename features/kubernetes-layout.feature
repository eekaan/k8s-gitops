Feature: Kubernetes tree layout
  Every application has the same shape, the tree builds without a cluster, and what it holds is what the cluster would accept.

  Scenario: The tree builds offline
    Given the kubernetes directory and no cluster
    When the kubernetes check runs
    Then every kustomization builds, Flux builds every ks.yaml with strict substitution, every layout and dependency rule holds, and the check exits zero

  Scenario: The tree passes the schema and image rules
    Given the kubernetes directory, the charts it names and the schemas from their public sources, and no cluster
    When the kubernetes validation runs
    Then every object Flux builds validates against its schema or is of a kind the tree lists as having none, every image of the render is pinned, and the validation exits zero

  Scenario: A dependency on an application the cluster does not enable is refused
    Given an enabled application whose Kustomization names, in dependsOn, an application that the cluster's overlay does not list
    When the kubernetes check runs
    Then it exits non-zero and names both Kustomizations and the overlay

  Scenario: A dependency whose target does not wait is refused
    Given an enabled application whose Kustomization names an enabled application in dependsOn that, once the root's patches are applied, sets neither wait nor health checks
    When the kubernetes check runs
    Then it exits non-zero and names both Kustomizations and the overlay

  Scenario: An issuer choice is checked without reading standard input when the tree holds no issuers application
    Given a tree with no issuers application in which one Kustomization chooses an issuer with PUBLIC_ISSUER, and the same tree with no choice
    When the kubernetes check runs on each with its standard input closed, at /dev/null, a pipe that stays open and silent, and a pipe that carries a ClusterIssuer of the chosen name
    Then every run ends within its bound, the choice is refused each time, in the same lines, as an issuer the issuers application does not make, and the tree without a choice passes each time

  Scenario: An object with a field its schema does not have is refused, and objects of listed kinds without a schema are counted by kind
    Given an application whose Deployment has a field the Deployment schema lacks, a Flux Kustomization with one its schema lacks, a custom resource with one its rendered definition lacks, and custom resources of kinds that have no definition and are listed with their reasons
    When the kubernetes validation runs
    Then it exits non-zero and names the file, the object and the field, and prints how many objects of each listed kind it could not validate

  Scenario: An object of a kind whose definition a chart or a definitions application brings is validated against that definition
    Given custom resources of a kind whose definition a chart's templates render, of a kind whose definition a Kustomization applies from a GitRepository at a tag, and of a kind whose definition a Kustomization applies from an OCIRepository's unpacked chart
    When the kubernetes validation runs
    Then each object is validated against the schema of its definition at the version the tree pins, a field under one that keeps unknown fields is no fault, and moving the pin moves the schema

  Scenario: A field the definition does not have fails the check, naming the object and the field
    Given custom resources of those kinds with a misspelt field, a field of the wrong type, and no value for a required field
    When the kubernetes validation runs
    Then it exits non-zero and names the file, the object and the field of each

  Scenario: An object of a kind without a schema fails the check unless the kind is listed with its reason
    Given a custom resource of a kind that no definition of the tree describes
    When the kubernetes validation runs
    Then it exits non-zero and names the object, its kind and its file, and it passes once schema-exceptions.yaml lists the kind's group and kind with a reason

  Scenario: A listed kind that has a schema, or that no object uses, fails the check
    Given schema-exceptions.yaml lists a kind whose definition a source of the tree brings, and another that no object of the tree is of
    When the kubernetes validation runs
    Then it exits non-zero and names each entry and says it has a schema, or that no object uses it

  Scenario: The tree passes, and the check says how many objects it validated and how many are of listed kinds
    Given a tree whose objects are validated against schemas or are of listed kinds
    When the kubernetes validation runs
    Then it exits zero, names each listed kind with the number of its objects, and says how many objects it validated and how many are of listed kinds

  Scenario: An object of a Gateway API or Envoy Gateway kind is validated against the definitions the tree pins, and a wrong one fails
    Given a Gateway, an HTTPRoute, a GatewayClass, an EnvoyProxy and a ClientTrafficPolicy, then the same with a misspelt field, a field of the wrong type and a missing required field
    When the kubernetes validation runs on the repository's own tree
    Then the right ones are validated against the Gateway API's and Envoy Gateway's definitions at the versions the tree pins, and each wrong one fails, naming the object and the field

  Scenario: An object of a kind an operator defines is validated against the definitions published for the version the tree pins
    Given an application with the source object of an operator's chart at a tag, custom resources of a kind the operator defines when it starts, and operator-definitions.yaml, which says that the definitions of the kind's group are published in a repository on github.com, in a directory, at the tag of that source object with a prefix, or at the version versions.yaml holds under a key the entry names, with a prefix
    When the kubernetes validation runs
    Then each object is validated against the definition published at that tag, a misspelt field, a field of the wrong type and a missing required field each fail naming the object and the field, moving the source object's tag, or the version versions.yaml holds for an entry that names its key, moves the schema, and a definition of another group in the directory is not read

  Scenario: A declaration of where an operator's definitions are published that is malformed, or that nothing uses, fails the check
    Given operator-definitions.yaml with an entry that has a field it does not know, a repository not on github.com, a path that is not plain, a group of Kubernetes or Flux, a tag prefix that is no part of a tag, a source object of another kind, both a source object and a key of versions.yaml or a key that is none, or a group and path declared twice; then one whose source object is not in the tree, one whose key versions.yaml holds no version under, and one whose definitions no object is of
    When the kubernetes validation runs
    Then it exits non-zero and names the file, the entry and what is wrong with it

  Scenario: An object of a Cilium kind is validated against the definitions of the Cilium release the tree pins, and a wrong one fails
    Given the repository's own tree with CiliumBGPPeerConfig and CiliumLoadBalancerIPPool objects with a misspelt field, a field of the wrong type and a missing required field
    When the kubernetes validation runs on it
    Then each wrong one fails naming the object and the field, the tree's own Cilium objects pass, and the operator the pinned chart runs is of the release the definitions are read at

  Scenario: A Talos ServiceAccount is validated against Talos' definition at the version the tree pins, and a wrong one fails
    Given the repository's own tree with Talos ServiceAccount objects with a misspelt field and a field of the wrong type
    When the kubernetes validation runs on it
    Then each wrong one fails naming the object and the field, and the tree's own ServiceAccount of the snapshot job passes, validated against the definition read at the Talos version versions.yaml pins

  Scenario: A definition of one of Kubernetes' own groups or Flux's is refused, whatever brings it
    Given a source a Kustomization applies definitions from that brings a definition of Deployment in the apps group that keeps unknown fields, a Deployment with a field Kubernetes' schema does not have, and a chart that renders a definition in the apps group, in one of Kubernetes' dotted groups or in a group of Flux's
    When the kubernetes validation runs
    Then it exits non-zero, names each such definition and its file, makes no schema of it, and validates the Deployment against Kubernetes' schema, naming the field

  Scenario: A definition whose name ends in a line break is refused, not skipped
    Given an application with an object of a custom kind with a field no schema gives it, and a release whose chart renders a definition of that kind whose group, kind or version ends in a line break
    When the kubernetes validation runs
    Then it exits non-zero and names the definition and its file, where skipping the definition would fail only the object, for want of a schema, and leave the definition unnamed

  Scenario: A root path that leaves the tree through a link is refused
    Given a root Kustomization whose spec.path is a link inside the tree to a directory outside it, by an absolute and by a relative path
    When the kubernetes check runs
    Then it exits non-zero, names the file and the rule, and builds nothing from outside the tree

  Scenario: A tree from which a build would read outside it is refused, and nothing is built
    Given trees in which a kustomization, a Component or an application's Kustomization names a file outside the tree by an absolute path, by a relative one that climbs out of it or through a link in the tree that leads out of it, or names a remote source, and one whose kustomization file is a link to one outside the tree
    When the kubernetes check runs on each
    Then it exits non-zero, names the file and the entry, builds nothing, and the file's content appears nowhere in its output

  Scenario: Every field of a kustomization is one the checks read the paths of, accept or refuse
    Given the fields of kustomize's and Flux's Kustomization types and of every type they hold, as the pinned kustomize and flux build with, and the fields the checks read of the documents no tool decodes
    When the checks read a document that sets each by its own name, naming a file outside the tree where the field names a file
    Then each field that names a file is refused for it, each field the checks refuse is refused, every other is accepted, a key a kustomization's type does not have is refused, and each list is that of the pinned tools' versions and of the checks

  Scenario: A path that is not a plain relative path of the tree is refused, under every locale
    Given kustomizations, a Flux Kustomization and a cluster's root that name, in every field that names a file, entries holding a letter outside ASCII, a control character, a tab or a space, an empty segment, a leading slash, dash or tilde, or an ASCII character other than letters, digits, ".", "_", "-" and "/"
    When the checks read them in the C locale and in C.UTF-8
    Then each entry is refused, naming the file, the field and the entry, each byte outside printable ASCII shown as \xHH

  Scenario: The check's builds fetch nothing from another machine, whatever a kustomization names
    Given a copy of the checks without the guard, and a kustomization that names a repository on github.com or a file over https
    When the kubernetes check and the render run on each
    Then each fails without running the caller's git or looking up a host: kustomize runs the check's own git, which refuses, and sends a request for a file to a closed port of the loopback

  Scenario: A key that a tool reads under another spelling is refused, and nothing it names is read
    Given trees in which a kustomization, an application's or a root's Flux Kustomization, a HelmRelease, the source it names or a FluxInstance holds, at each position a tool decodes, each field's name in other letter cases and with the characters encoding/json folds into s and k, naming a file outside the tree
    When the kubernetes check, the render and the Pod Security check run on each that they read
    Then each fails, naming the file and every such key, and the file's content appears nowhere in its output or in anything it keeps or writes

  Scenario: A manifest an application keeps where the artifact does not carry it is refused
    Given an application directory with a manifest beside ks.yaml, and one in app/ that no kustomization.yaml reaches
    When the kubernetes check runs
    Then it exits non-zero and names each file and the rule

  Scenario: An image without a tag or digest in a rendered release or its hooks is refused
    Given a release whose chart renders a test hook, an upgrade hook, a Deployment and a custom resource naming its own image, whose images have no tag, the tag latest or only a registry's port
    When the kubernetes validation runs
    Then it exits non-zero and names the application, the object and the image, unless the release does not run that test or the image is listed with its reason in the image allowlist

  Scenario: An application that renders no object passes the image rule without reading standard input
    Given a tree with an application whose kustomization lists nothing, for which the render keeps a directory that holds no file, and an application read after it that runs one pinned image
    When the kubernetes validation runs with its standard input closed, at /dev/null, a pipe that stays open and silent, and a pipe that carries a pod whose image has no tag
    Then every run ends within its bound and passes, having counted the one pinned image and not the pod's

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

  Scenario: A cluster directory that builds anything but the root and Flux itself fails the check
    Given a cluster directory whose kustomization.yaml lists another manifest beside the root's and Flux's own ks.yaml files, or leaves out the FluxInstance's
    When the kubernetes check runs
    Then it exits non-zero and names the directory and the extra or missing object

  Scenario: An application in a cluster directory whose names do not match its directory fails the check
    Given Flux's own application in a cluster directory whose Kustomization name, sourceRef, targetNamespace or path does not match its directory
    When the kubernetes check runs
    Then it exits non-zero and names the file and the field

  Scenario: An undeclared variable in a cluster directory's Kustomizations fails the check
    Given a root ks.yaml, which the instance's sync Kustomization substitutes, using a variable that is not in the example key lists and has no default
    When the kubernetes check runs
    Then it exits non-zero and names the file and the variable

  Scenario: Flux's own application without the root's decryption and substitution fails the check
    Given Flux's own application in a cluster directory whose ks.yaml has no decryption, or no postBuild.substituteFrom
    When the kubernetes check runs
    Then it exits non-zero and names the file and the field

  Scenario: An application with the name of a cluster's own application fails the check
    Given an application under apps/base named like the Flux Operator application in a cluster directory
    When the kubernetes check runs
    Then it exits non-zero and names both directories

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

  Scenario: An application that backs up its volume under another application's name fails the check
    Given an application whose ks.yaml adds components/volsync with APP set to another name, or not set
    When the kubernetes check runs
    Then it exits non-zero and names the file and the rule, and the same application with APP set to its own name passes
