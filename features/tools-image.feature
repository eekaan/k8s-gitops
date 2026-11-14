Feature: The prebuilt tools image
  The container with the pinned tools is built once for each change of its inputs, published to
  this repository's container registry, signed, and recorded by digest, so that a CI job does not
  install the tools every time. just ci runs the checks in it while it was built for the checkout's
  inputs, and builds the tools itself otherwise, so a pull request that changes a pin works before
  any image exists for it.

  The inputs are the base image and the package step in versions.yaml, and mise.toml. Their key,
  just tools-image-key, names the image: it is the image's tag, the annotation its signature
  carries, and what versions.yaml records beside the digest.

  Scenario: The key changes when a pinned tool, the base image or the package step changes, and not otherwise
    Given a checkout and its key
    When a pin in mise.toml, the base image or the package step changes, or any other file or line does, the recorded image among them
    Then the key differs from the checkout's for each of the first three, and is the same for every other change

  Scenario: With a recorded image for the current inputs, the checks run in that image, by digest
    Given versions.yaml records, with the checkout's key, an image that a registry the engine reaches serves by its digest only
    When just ci runs
    Then the module runs the checks in that image, named by its digest, and says so

  Scenario: With changed inputs, the recorded image is not used and the tools are built from the pins
    Given versions.yaml records an image for the checkout's inputs
    When a pinned tool, the base image or the package step changes and just ci runs
    Then the module is given no image, only the changed inputs to build the tools from, and the run says why

  Scenario: The checks give the same result in the recorded image as in the tools built from the pins
    Given the image the tools image workflow would publish for the checkout's inputs, and a tracked file that fails one check
    When just ci runs with that image recorded for these inputs, and again with it recorded for other inputs
    Then both runs run the same checks in the same groups, fail the same check in the same group, and pass every other group

  Scenario: The tools image is signed and verified before its digest is printed, and nothing is published outside the workflow
    Given a tools image run on refs/heads/main in GitHub Actions, or an environment without the workflow's identity token, or a run on another branch
    When just tools-image-publish runs
    Then in the workflow on main the login, the push tagged with the key, the signature and the verification happen in that order, each by digest after the push, and only then is the digest printed; anywhere else it refuses and calls nothing

  Scenario: The tools image's registry token reaches no command line and no output
    Given the job's registry token in the environment
    When just tools-image-publish runs
    Then the token reaches docker login on standard input only, no command gets it as an argument, the run never prints it, dagger and cosign read the login from the same Docker configuration, and that configuration is gone after the run

  Scenario: Only a digest whose signature verifies against this repository's workflow can be pinned
    Given digests signed by the tools image workflow on main for the checkout's key, for another key, by another identity, or not at all
    When just tools-image-pin runs with each
    Then only the first is written to versions.yaml with the checkout's key, after a verification of exactly that identity, issuer and key without credentials; every other leaves versions.yaml as it was and exits non-zero

  Scenario: The tools image workflow has only the permissions it needs, runs on a hosted runner, and pins every action to a commit
    Given the tools image workflow
    When it is read, and the CI host's job-started hook gets a job of it
    Then it runs on pushes to main that change its inputs or itself and on workflow_dispatch, never for a pull request; requests read access to the contents, write access to packages and an identity token and nothing else; never cancels a run in progress; runs just tools-image-publish and no other command on ubuntu-latest with actions pinned to a commit; and the hook fails its job
