Feature: Publishing the cluster's artifact
  A merge to main that changes kubernetes/ reaches Flux only as an artifact signed by the publish workflow, and the tag Flux follows only ever moves forward, to a digest that was signed and verified.

  Scenario: The artifact is signed and verified before the tag moves
    Given a publish run on refs/heads/main in GitHub Actions, with no newer commit on origin/main
    When just publish runs
    Then the registry login, the push, the signature, the verification and the tag happen in that order, and the run says the tag moved

  Scenario: The tag moves to the digest that was signed, not to a tag
    Given a publish run on refs/heads/main whose push reports a digest
    When just publish runs
    Then that digest is signed, verified and tagged main, each by digest in the artifact Flux syncs from, and no step names the artifact by a tag

  Scenario: A run that is not on main publishes and signs but leaves the tag alone
    Given a publish run on a branch other than main, as workflow_dispatch starts one
    When just publish runs
    Then the artifact is pushed, signed and verified, the tag is not touched, the run says why and exits zero

  Scenario: An older run does not move the tag back
    Given a publish run on refs/heads/main, and a newer commit on origin/main that changes kubernetes/ or the publish workflow
    When just publish runs
    Then the artifact is pushed, signed and verified, the tag is not touched, the run names the newer commit and exits zero

  Scenario: A failed verification leaves the tag alone and fails the run
    Given a publish run on refs/heads/main whose signature does not verify
    When just publish runs
    Then the tag is not touched and the run exits non-zero naming the verification as the step it failed in

  Scenario: A digest that is not a sha256 digest stops the run before anything is signed
    Given a push that reports something other than sha256: and 64 hexadecimal digits as its digest
    When just publish runs
    Then the run exits non-zero before anything is signed, verified or tagged

  Scenario: Nobody publishes from outside the workflow
    Given an environment without GitHub Actions, or without the variables Actions sets for an identity token
    When just publish runs
    Then it refuses, exits non-zero and calls nothing

  Scenario: The registry token reaches no command line and no output
    Given the job's registry token in the environment
    When just publish runs
    Then the token reaches docker login on standard input only, no command gets it as an argument, the run never prints it, flux and cosign read the login from the same Docker configuration, and that configuration is gone after the run

  Scenario: The artifact holds only what is under kubernetes/
    Given the repository's files, and a cluster's secrets/ directory under kubernetes/clusters/
    When the archive the run pushes is built with the pinned flux build artifact and listed
    Then it holds every file under kubernetes/ but a cluster's secrets/, at its path below kubernetes/, and nothing else, and no file in it is named like key material, an .env file, a kubeconfig or a talman.yaml

  Scenario: The verification accepts exactly the identity Flux is configured to accept
    Given the issuer and subject the FluxInstance's values require of the synced artifact's signature
    When the publish run's verification is read
    Then it accepts exactly that issuer and that subject, and nothing else, and the subject names the publish workflow file, which runs just publish

  Scenario: The publish workflow runs one recipe with only the permissions it needs, and runs queue
    Given the publish workflow
    When it is read
    Then it runs on pushes to main that change kubernetes/ or the workflow, and on workflow_dispatch, never for a pull request; it requests read access to the contents, write access to packages and an identity token and nothing else; its runs share one concurrency group that never cancels a run in progress; it checks out the full history without keeping the credentials, installs the pinned tools the recipe needs with the same mise-action as CI, and runs just publish and no other command

  Scenario: Every action in every workflow is pinned to a commit
    Given every workflow file under .github/workflows/
    When its uses lines are read
    Then each one references a full commit SHA
