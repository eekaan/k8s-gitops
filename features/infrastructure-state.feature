Feature: Infrastructure state and stack recipes
  A stack is planned, applied and destroyed by one command, with encrypted state and nothing secret on screen.

  Scenario: State written by OpenTofu is encrypted
    Given a throwaway stack on the local backend and a passphrase in the environment
    When it is applied with the repository's encryption settings
    Then the state file contains no plaintext resource data and cannot be read without the passphrase

  Scenario: Unencrypted state is refused
    Given the repository's encryption settings and no passphrase
    When a stack is initialised and planned
    Then the run fails before any state is written, naming the missing variable

  Scenario: A stack refuses an unencrypted method from the environment
    Given the encryption block of each stack in the repository
    When the environment configures OpenTofu's unencrypted method and the stack is applied
    Then tofu refuses because encryption is enforced, and no state is written

  Scenario: A stack that does not enforce state encryption fails the check
    Given a stack whose terraform block does not enforce state and plan encryption
    When the infrastructure check runs
    Then it exits non-zero naming the stack

  Scenario: The state bucket is created once and no credential is shown
    Given OpenStack credentials, S3 credentials and TF_STATE_BUCKET naming a bucket that does not exist
    When infra-state-bucket runs, and then runs again
    Then the first run creates that bucket with the openstack client and the second creates nothing, and no credential and not the bucket's name is printed, and no credential reaches a command line or the openstack client's environment

  Scenario: A missing required variable is named and nothing runs
    Given an environment without the state bucket
    When infra-plan runs for a stack
    Then it exits non-zero naming the variable and tofu is never started

  Scenario: An empty or placeholder value is refused by name
    Given a .env copied from .env.example and not filled in
    When infra-plan runs for a stack
    Then it exits non-zero naming each variable that is empty or still holds a placeholder, and tofu is never started

  Scenario: The .env file is read as literal NAME=value lines
    Given a .env whose values hold quotes, dollar signs and backticks
    When infra-plan runs for a stack
    Then tofu gets each value as written, without one pair of quotes, and nothing in a value runs

  Scenario: A .env line that is not NAME=value is refused by its number
    Given a .env with a line that is not a NAME=value assignment
    When infra-plan runs for a stack
    Then it exits non-zero naming the line's number and not its content, and tofu is never started

  Scenario: OpenTofu's logging and workspace variables are refused
    Given TF_LOG, TF_LOG_PATH, TF_LOG_CORE, TF_LOG_PROVIDER or TF_WORKSPACE in the environment
    When infra-plan runs for a stack
    Then it exits non-zero naming the variable and tofu is never started

  Scenario: The backend is configured from the environment
    Given a complete environment
    When infra-plan runs for the plumbing stack against a recording tofu
    Then tofu is initialised with the committed backend file, the bucket from the environment and a state key derived from the stack's path

  Scenario: No secret reaches a command line or the output
    Given an environment whose secrets are marker strings
    When infra-plan, infra-apply and infra-destroy run against a recording tofu
    Then no marker appears in any recorded argument list or in anything the recipes print

  Scenario: The plan summary shows counts and types only
    Given a saved plan with resources to add, change and destroy
    When infra-plan prints its summary
    Then it shows the number of resources per action and resource type and no resource address or attribute value

  Scenario: A plan that changes only outputs is not shown as no changes
    Given a saved plan that changes no resource and creates, updates and deletes outputs
    When infra-plan prints its summary
    Then it names each changed output with its action, and neither says "No changes." nor shows an output's value

  Scenario: Errors from tofu stay out of a public CI log
    Given tofu fails with errors that name a resource
    When infra-plan runs with CI set
    Then it exits non-zero saying tofu failed and where its errors are, and the errors are in that file and not in the output, while without CI they are shown

  Scenario: One non-sensitive output is printed and a sensitive one is refused
    Given a stack whose state has a sensitive and a non-sensitive output
    When infra-output asks for each
    Then it prints the non-sensitive value and refuses the sensitive one by name without printing it

  Scenario: The allowlist reaches the cluster stack through the environment
    Given an operator allowlist file
    When infra-plan runs for the cluster stack against a recording tofu
    Then the allowlist is in the tofu process environment and in no argument

  Scenario: Two operations on one stack do not overlap
    Given an operation in progress on a stack
    When a second one starts on the same stack
    Then it exits non-zero saying the stack is busy

  Scenario: Apply asks before it applies the saved plan
    Given a stack with changes to apply
    When infra-apply runs without confirmation
    Then nothing is applied, and with confirmation tofu applies the plan file it saved and summarised

  Scenario: Destroy takes the cluster before the plumbing and asks first
    Given both stacks
    When infra-destroy runs against a recording tofu without confirmation
    Then nothing is destroyed, and with confirmation the cluster stack is destroyed before the plumbing stack

  Scenario: Destroying the cluster removes the generated files that hold its addresses
    Given the cluster's generated talman.yaml, talosconfig and kubeconfig, its secrets bundle and an etcd snapshot
    When infra-destroy destroys the cluster stack, when its destroy fails, and with the kubeconfig tracked by git
    Then once the cluster stack is destroyed the talman.yaml, talosconfig and kubeconfig git ignores are removed and named, none of their content is printed, and the secrets bundle and the snapshot stay; a tracked kubeconfig stays, named; after a failed destroy nothing is removed
