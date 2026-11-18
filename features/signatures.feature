Feature: Chart signatures
  Every source a chart, the cluster's artifact or the tools image comes from is a row of
  signatures.yaml: a publisher that signs keyless is held to one declared identity, one that signs
  with a key to its public key under signatures/, and every other source is listed as unsigned with
  its reason. just signatures-check holds the rows and the sources Flux builds to each other
  offline, and the verify blocks of the OCIRepositories to the rows; just signatures-verify asks
  the registries, anonymously, whether each pinned source is signed as its row says. Flux verifies
  the keyless rows again on the cluster, and just cluster-signatures reads what it found.

  Scenario: A chart source without a row fails the check, and so does a row without a source
    Given the sources Flux builds from the tree, the FluxInstance's sync source and the tools image, and the rows of signatures.yaml
    When just signatures-check runs, on the tree and on a fixture tree with a row removed, a row added for no source, a source listed twice, rows out of order, a field missing, unknown or not on one line, a Helm repository not listed as unsigned, a source kind the check has no rule for, a ref that is no tag or digest, a key that is no PEM public key under signatures/ and a file there no row names
    Then the tree passes with every source in exactly one row, and each fixture fails naming the source, and for an object its namespace, name and file, after every failure is reported

  Scenario: A row that names a keyless identity is the verify block of every source it covers, and no other source has one
    Given the OCIRepositories Flux builds from the tree after substitution, and the patch the FluxInstance's values put on its sync source
    When the rows that name a keyless identity the cluster verifies are compared with them
    Then every object of such a row's source verifies with cosign exactly that issuer and subject and nothing else, every other object has no verify block, and a changed subject, a block removed or a block added to an unsigned source fails just signatures-check, naming the object

  Scenario: The rows of the cluster's own artifacts are the identities their recipes sign and verify with
    Given signatures.yaml, the FluxInstance's values, the Flux Operator's two chart sources and scripts/tools-image
    When their rows are read
    Then the first two rows are the synced artifact and the tools image, the synced artifact's row and the Flux Operator's two rows are the identities the cluster verifies today, and the tools image's row, read as a literal, is exactly the identity and issuer just tools-image-pin hands cosign

  Scenario: An identity that is not anchored, or that leaves the publisher's repository or workflow open, fails the check
    Given a keyless row whose block matches it
    When its issuer or subject drops an anchor, holds a bare dot, a backslash class, a lazy quantifier, a flag group, a second dollar, an alternation outside a group, or a class or quantifier before the ref
    Then just signatures-check fails naming the source and the field; and every keyless row of the tree matches its own repository's workflow and refuses another repository, another workflow, an unescaped dot, a prefix and a suffix

  Scenario: A source whose signature does not match its row fails the verification, naming the source
    Given the fixture tree and a registry whose signature of a keyless source names another subject, and one whose key signature is by another key
    When just signatures-verify runs
    Then each such source has a FAIL line saying its signature does not match its row, every other row has its own line, and the run exits non-zero

  Scenario: A source listed as unsigned that carries a signature fails the verification
    Given the fixture tree and a registry that serves a signature, in either format, for a source listed as unsigned
    When just signatures-verify runs
    Then that source has a FAIL line naming it, as only cosign's own outcome "no signatures found" counts as unsigned

  Scenario: A registry that cannot be reached fails the verification, naming the source, and the offline check passes without it
    Given a registry that cannot be resolved, one that does not answer in time, one that limits anonymous requests, and Docker Hub, whose registry host is not docker.io
    When just signatures-verify runs, and then just signatures-check
    Then each source of the first three fails with the reason of the probe and cosign is not run for it, the Docker Hub source is probed at its registry host, and the offline check passes without asking any registry

  Scenario: The verification runs without credentials and prints a source and a reason on each line, nothing else
    Given registry logins in the caller's Docker configuration, home and podman's file, the caller's TUF root, cosign's variables that move where a signature is read from or what is trusted, and a secret in the environment
    When just signatures-verify runs, with a cosign whose output and errors name an address
    Then cosign reads no login, none of those variables and none of the secrets, and runs verify alone; and the run prints exactly one line per row, the verdict, the source and a reason of the check's own, and no address, path or text of cosign's

  @by:signatures-verify
  Scenario: The pinned sources verify against their rows
    Given the tree's rows and the tags, digests and refs it pins
    When just signatures-verify runs against the public registries
    Then every keyless row verifies with its issuer and subject, every key row with its key, and every unsigned OCI source has no signature

  Scenario: The verification is a group of its own, outside static and outside the publish run
    Given the justfile and scripts/publish
    When the groups of checks are read
    Then signatures is a group whose one check is signatures-verify, signatures-check is a check of static, neither recipe is in another group, the CI matrix lists the group, and the publish run runs neither

  Scenario: The table of who signs in the docs is the rows of signatures.yaml
    Given the table in docs/kubernetes.md, Signatures, and signatures.yaml
    When both are read
    Then each row has exactly one line of the table, in the same order, with its source, who signs it, whether it is verified before merge and by the cluster, before merge alone or not at all, and its reason, and the table has no other line

  Scenario: A source the cluster did not verify fails the cluster's check, naming it
    Given the cluster's OCIRepositories as kubectl gets them, and signatures.yaml
    When just cluster-signatures runs
    Then an object whose row the cluster verifies passes only with its block, Ready and verified for its current generation, an unsigned one only without a block, and every other fails, named by namespace and name with the condition's reason, with no address, message or error of kubectl's printed
