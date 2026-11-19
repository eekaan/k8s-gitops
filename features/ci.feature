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

  Scenario: A run of the checks leaves every tracked file as it found it, whether it passes, fails or is interrupted
    Given a clean checkout, and a Dagger that records a line in dagger.lock as it does for an image it resolves, empties it, fails, or is stopped with INT, TERM or HUP and records its line only once the signal reaches it
    When just ci runs with each
    Then every run leaves dagger.lock as it was, byte for byte, and git status lists nothing

  Scenario: A change made to the lock file before the run is still there after it
    Given a checkout whose dagger.lock a developer changed before the run, with a line dropped and one added
    When just ci runs with a Dagger that records a line, empties the file, fails, or is stopped with INT, TERM or HUP
    Then dagger.lock holds the developer's bytes after each run, not the committed ones

  Scenario: A committed lock entry for an image the tree takes by a derived tag fails the checks
    Given the images scripts/lib/derived-images.sh lists, which holds the repository of the one rules-check takes from the render as an entry of its own, and a repository whose committed dagger.lock holds no entry for any of them, only for other images whose names begin with theirs or that theirs begin with
    When lock-check runs with the entry only in the working copy, and again with the entry committed and the working copy without it
    Then the first passes, the second fails naming the line, a committed entry for the image rules-check takes fails it too, and lock-check is a check of the static group

  Scenario: The hermetic run validates the Renovate configuration with the image renovate-check uses
    Given the justfile and the Dagger module
    When the commands renovate-check and just ci run are read
    Then both name the one pinned Renovate image, and the module names no image of its own for it

  Scenario: Every test file runs exactly once in the parallel run
    Given the test files in tests/ and the parts of the bats tests the groups run
    When each part runs
    Then together they hand bats every test file once and none twice, without the hermetic tests, and bats runs a file's tests side by side

  Scenario: The bats tests are split into groups by the time each file took, and no group takes much longer than another
    Given the recorded time of every test file in tests/times.tsv and the parts of the bats tests the groups run
    When each part hands its files to bats
    Then every file goes to exactly one part, the parts holding more than one file are within 5% of each other by recorded time, and no part is recorded at more than 25 minutes

  Scenario: A test file without a recorded time stops the tests, naming the command that records it
    Given a copy of the justfile, scripts/ and tests/ with a new test file the record lacks, and a record line for a file that is gone
    When each part of the bats tests the groups run, such as just test 1/8, runs with a recording bats
    Then each ends non-zero, bats was never called, and the output names the new file with just test-time tests/<name>.bats and the gone file's line, saying to delete it or run just test-times-record

  Scenario: Each test file prints how long it took, and the record is written from what a run printed
    Given a copy of the justfile and scripts/ whose tests/ holds three test files and a line of tests/times.tsv for each under the record's header, and a stand-in bats that sleeps a known time for each file and fails the one that runs first
    When just test 1/1 runs, and its output, put into the form of the fixture's CI log with each line again in the group's report, is read by scripts/test-times, once a test file was added with its line and a line was added for a file that is gone, which the log times too
    Then every file has one line on standard output saying it took its sleep, or a second more, the run goes on past the failing file and ends non-zero naming it, and the record holds each timed file's seconds once, keeps the added file's line, drops the gone file's, saying so, and keeps its header, while a log with no timing line, and one with two times for one file, fail and leave the record byte for byte

  Scenario: The record of the test files' times is written from the logs of a CI run
    Given a copy of the justfile and scripts/ whose tests/ holds the test files whose times the fixture's job log prints and one more, and a stand-in gh that serves the run list, the run's jobs, one of them skipped, and the logs of those that ran from fixtures, refuses a log with terminal escapes unless asked to print them, and records its arguments
    When just test-times-record 42 runs, and again with no run
    Then the record is written from those logs each time, keeping the other file's line, the first call read the jobs of run 42 and the second those of the latest successful push run of ci on main, the skipped job's log was not asked for, and every recorded gh call is a read

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

  Scenario: The tool installer is pinned to an exact version in every workflow, a workflow whose token can write checks its binary, and the publish job keeps no cache
    Given every workflow file under .github/workflows/
    When the version of each use of the mise action is read, the checksum input of each use in a workflow that holds a write permission, and the publish job's cache input
    Then every version is an exact release number, never a range or latest, every use in a workflow that holds a write permission gives a checksum, the same one, and the publish job turns the action's cache off

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
    Then it runs for pull_request and never pull_request_target, with only contents: read, no secret, and no token handed to any step but the read-only one the checkout and mise actions take by default, on ubuntu-latest named in the job itself, renders in the Dagger module and uploads the comment as one file in an artifact

  Scenario: The comment job runs no code and checks out nothing from the pull request
    Given the workflow that comments on pull requests
    When its trigger, permissions, jobs and steps are read
    Then it runs only when the CI workflow completes, not cancelled, for a pull request, on a hosted runner, with read access to contents and actions and write access to pull requests only, set for the workflow and in no job, checks out the default branch it runs on and no other ref or repository, uses only the pinned checkout and mise actions, installs its tools without a token, runs one recipe with the run's identifiers in its environment, and has no expression in any command

  Scenario: The comment job treats the artifact as text of a bounded size
    Given an artifact whose one file is a comment render-diff writes with shell and workflow syntax in its diff, one exactly as long as the comment job accepts, and artifacts with two files, a symlink, another name, a byte too many, no marker, a first line that only starts with the marker or ends in a carriage return, a NUL or a carriage return in a diff, or a NUL in the marker with a command and a file named after its parts at hand
    When the comment recipe runs for each
    Then the first two are posted byte for byte followed by the job's own line naming the commit, nothing in them runs or reaches the log, the comment stays within GitHub's limit, and every other one is refused without anything being posted or run

  Scenario: The comment job posts nothing but what render-diff writes
    Given every kind of comment render-diff writes, one with counts of six digits, and comments that add a mention, a cross-reference, a link, an image, an HTML tag, free text, text before or after a section's counts, an application name with a character no DNS label has, a count of seven digits, a line that closes a diff's fence, or another footer
    When the comment recipe runs for each, with each of gawk, mawk and busybox's awk that the machine has
    Then every comment render-diff writes is posted, and every other one is refused without anything being posted, under each awk alike

  Scenario: just ci renders the tree as the render job does
    Given the justfile
    When the checks of just ci's groups are read
    Then one group renders this checkout's tree with scripts/render and keeps nothing, so a tree that does not render fails just ci as it fails the required check

  Scenario: The comment job runs gh with its own token and none of the other secrets
    Given every secret variable the recipes read set to a marker, and a recording gh
    When the comment job runs
    Then gh's recorded environment holds the job's token and none of those secrets

  Scenario: The render is part of the required result, and the comment is not
    Given the CI workflow and the comment workflow
    When the jobs the required job waits for and the comment workflow's jobs are read
    Then the required job waits for the render job, which nothing skips, and the comment workflow is a workflow of its own with no job named ci

  Scenario: Every workflow job that calls the Dagger module checks out the whole history
    Given every workflow file under .github/workflows/ and the recipes its jobs run
    When a job runs a recipe that, itself or in the script it runs, calls the Dagger module
    Then that job checks out the whole history, as the module reads the workspace's Git history, which a shallow clone of a commit with parents cannot give

  Scenario: The engine starts without the cache entries its image ships
    Given the engine image versions.yaml pins and a docker that records what it is asked
    When scripts/dagger-engine runs with no engine container, with one that runs, with a stopped one that hides the entries, with one made from the image as it is that does not run or keeps restarting, and with an engine the caller names
    Then it makes one container, named as the pinned dagger CLI names its engine, privileged, from the pinned image by digest, with an empty file system over /usr/local/share/dagger/entries; leaves the running one alone; starts the stopped one; stops the run for the one that cannot start, saying how to replace it and removing nothing; and calls docker for nothing when the caller names an engine

  Scenario: Every recipe and script that calls Dagger starts the engine first
    Given the justfile and scripts/tools-image
    When the lines that call the Dagger module are read
    Then each follows a line that runs scripts/dagger-engine
