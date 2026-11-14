Feature: Continuous integration
  The checks a pull request gets are the checks a person runs, with the same tools, in groups that
  run side by side.

  Scenario: The hermetic run passes on a clean tree
    Given a clean checkout and a container runtime
    When just ci runs
    Then the checks run inside a container built from the pinned tools and the run exits zero

  Scenario: Every check belongs to exactly one group, and the groups come from the justfile
    Given the justfile, whose checks recipe depends on the groups and each group on its checks
    When each group's checks, and the recipes they depend on in turn, are read
    Then no check is in two groups, every group has a check, and just ci-groups lists exactly the checks recipe's dependencies

  Scenario: just ci runs every group, and a group runs only its own checks
    Given a clean checkout and a container runtime
    When just ci runs, and then just ci runs with the name of a group of one check that the checkout adds to its justfile
    Then the first run reports every group of the justfile as passed, with every bats test run once among them, and the second reports that group alone and runs its one check

  Scenario: A failing check fails just ci, names itself, and does not hide the other groups' results
    Given a tracked file that fails one of the checks
    When just ci runs
    Then the run exits non-zero, the output holds the failing check's own message and its recipe's name, and names its group as failed and every other group as passed

  Scenario: The hermetic run checks the messages of the commits after the default branch
    Given a branch with a commit after the default branch whose message holds an address literal
    When just ci runs
    Then the run exits non-zero and names the commit and the literal

  Scenario: The hermetic run validates the Renovate configuration with the image renovate-check uses
    Given the justfile and the Dagger module
    When the commands renovate-check and just ci run are read
    Then both name the one pinned Renovate image, and the module names no image of its own for it

  Scenario: Every test file runs exactly once in the parallel run
    Given the test files in tests/ and the parts of the bats tests the groups run
    When each part runs
    Then together they hand bats every test file once and none twice, without the hermetic tests, and bats runs a file's tests side by side

  Scenario: The workflow's jobs are computed from the justfile
    Given the CI workflow
    When its jobs are read
    Then a first job lists the groups with just ci-groups, and one job per group in that list, not in a list of the workflow's own, runs just ci with the group and reports its own result

  Scenario: The required job passes only when every group passed
    Given the CI workflow's job named ci and the results of the jobs it waits for
    When a group failed, was cancelled or was skipped, or every job succeeded
    Then the job runs whatever became of the others, and passes only when every job it waits for succeeded

  Scenario: The workflow keeps its triggers, permissions and pinned actions
    Given the CI workflow
    When its triggers, permissions, concurrency and steps are read
    Then it runs for every pull request and every push to main with no path filter, requests read-only permissions and no secrets, cancels a pull request's older run, checks out and installs with the same pinned actions in every job, and every command it runs is one just recipe

  Scenario: A pull request from a fork never runs on the self-hosted runner
    Given the CI workflow and a self-hosted runner label in CI_RUNNER_LABEL
    When just ci-runner picks the check jobs' runner for a push to main, a pull request from a branch of the repository and one from a fork, and the CI host's job-started hook gets a job of each, the fork's workflow changed to ask for the host
    Then only the push and the branch's pull request get the label, the fork's check jobs run on a hosted runner, and the hook fails the fork's job before any of its steps runs

  Scenario: Without a self-hosted runner configured, every job runs on a hosted runner
    Given the CI workflow and no CI_RUNNER_LABEL
    When just ci-runner picks the check jobs' runner for a push to main, a pull request from a branch of the repository and one from a fork
    Then it picks ubuntu-latest each time, and every other job of the workflow names ubuntu-latest itself

  Scenario: The publish workflow never runs on the self-hosted runner
    Given the publish workflow
    When its jobs are read, and the CI host's job-started hook gets a job of it for a push to main
    Then its one job names ubuntu-latest itself, and the hook fails the job

  Scenario: The render job has read-only permissions, no secrets, and always a hosted runner
    Given the CI workflow's job that renders a pull request's diff
    When its triggers, permissions, runner, steps and recipe are read
    Then it runs for pull_request and never pull_request_target, with only contents: read, no secret and no token handed to any step, on ubuntu-latest named in the job itself, renders in the Dagger module and uploads the comment as one file in an artifact

  Scenario: The comment job runs no code and checks out nothing from the pull request
    Given the workflow that comments on pull requests
    When its trigger, jobs and steps are read
    Then it runs only when the CI workflow completes for a pull request, on a hosted runner, checks out the default branch it runs on and no other ref or repository, uses only the pinned checkout and mise actions, runs one recipe with the run's identifiers in its environment, and has no expression in any command

  Scenario: The comment job treats the artifact as text of a bounded size
    Given an artifact whose one file holds shell and workflow syntax, and artifacts with two files, a symlink, another name, no marker or more than a comment holds
    When the comment recipe runs for each
    Then the first is posted byte for byte and nothing in it runs, and every other one is refused without anything being posted

  Scenario: The render is part of the required result, and the comment is not
    Given the CI workflow and the comment workflow
    When the jobs the required job waits for and the comment workflow's jobs are read
    Then the required job waits for the render job, which nothing skips, and the comment workflow is a workflow of its own with no job named ci
