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
    Given the state key and TF_STATE_BUCKET naming a bucket that does not exist
    When infra-state-bucket runs, and then runs again
    Then the first run creates that bucket through the S3 client with the state key and the second creates nothing, neither starting the openstack client, and no credential, not the bucket's name and not the endpoint is printed, no credential reaches a command line, and the S3 client's environment holds the state key and no other secret

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

  Scenario: OpenTofu's argument and data directory variables are refused
    Given TF_CLI_ARGS, a TF_CLI_ARGS_ variable for one command, or TF_DATA_DIR in the environment
    When infra-plan runs for a stack
    Then it exits non-zero naming the variable and not its value, and tofu is never started

  Scenario: The infrastructure recipes refuse Go's HTTP/2 debug log
    Given GODEBUG setting http2debug, in the environment or in .env
    When each infrastructure recipe runs, and cilium-install
    Then it exits non-zero saying so, and no tool is started

  Scenario: Apply takes --yes before or after the stack
    Given a stack with changes to apply
    When infra-apply runs with --yes before the stack's name, and with it after
    Then both apply the plan without asking, and a second stack name or an unknown flag is refused before tofu starts

  Scenario: An allowlist entry that is IPv6 or covers every address is refused by its position
    Given an operator allowlist with an IPv6 network, or with a network whose prefix is 0
    When infra-plan runs for the cluster stack
    Then it exits non-zero naming the entry's position and not its value, and tofu is never started

  Scenario: An allowlist entry wider than /16 or with host bits set is refused by its position
    Given an operator allowlist with a network of prefix 15, a host address written with prefix 1, and an address with bits set below a /24
    When infra-plan runs for the cluster stack
    Then it exits non-zero naming each entry's position and the rule it breaks and not its value, and tofu is never started

  Scenario: The recipes and the stacks accept and refuse the same allowlist entries
    Given entries accepted and refused, with the prefixes on either side of the shortest allowed one
    When the recipes' check, the cluster stack's variable and the ci stack's variable each take an entry alone
    Then each entry is accepted by all three or refused by all three

  Scenario: The backend is configured from the environment
    Given a complete environment
    When infra-plan runs for the plumbing stack against a recording tofu
    Then tofu is initialised with the committed backend file, the bucket from the environment and a state key derived from the stack's path

  Scenario: No secret reaches a command line or the output
    Given an environment whose secrets are marker strings
    When infra-plan, infra-apply and infra-destroy run against a recording tofu
    Then no marker appears in any recorded argument list or in anything the recipes print

  Scenario: Each tool gets only the secrets it uses
    Given every secret variable set to a marker, and a recording fake of each tool the recipes run
    When each tool is run as the recipes run it
    Then each fake records the names, never the values, of the secret variables in its environment: tofu the object storage key, the encryption settings, the cloud credential and the stacks' inputs, the openstack client the cloud credential, talman and sops the age key variables, age the age key file's path, and talosctl, kubectl, helm, flux, kustomize, docker, curl, age-keygen, gh, ssh, ssh-keyscan and ssh-keygen none

  Scenario: The S3 client gets the one key pair it is called with and no other secret
    Given the state key pair and the cluster key pair, and a recording S3 client
    When the S3 client is called with each key set
    Then it gets that key pair, and no other secret variable

  Scenario: A wrapped tool started in the background is the process the caller holds, with only its secrets
    Given every secret variable set to a marker, and a recording kubectl that runs until it is ended
    When the tool is started in the background as ( exec_tool kubectl ... ) & and the process id the caller got is ended
    Then that id was the tool's own, the tool is gone, and it saw none of the secrets

  Scenario: A sops run for the Flux key sees only that key, as the one age key it is given
    Given the Flux age key and the Talos age key's variables set to markers, and a sops that records which of its age variables holds the Flux key
    When the Flux key's sops runs, with the key itself and with a key file
    Then sops sees one age variable, SOPS_AGE_KEY holding the Flux key or SOPS_AGE_KEY_FILE holding its file, and no other secret

  Scenario: No script runs a wrapped tool around its wrapper
    Given the scripts and the justfiles of the repository
    When each is searched for a wrapped tool after command, env, exec, timeout, xargs, sudo and the like, whatever options and arguments come between, after which, in the body of bash -c or sh -c, or by a path from type -P, or started in the background by name
    Then none is found, as each would give the tool the whole environment

  Scenario: The scan for a wrapped tool run around its wrapper flags every way of doing it
    Given command lines that run a wrapped tool after a runner with options of their own, through which, command -v, a path from type -P or a shell's -c body, and command lines that do not
    When the scan reads them
    Then it flags each of the first and none of the second

  Scenario: A variable added to .env.example is assigned to the tools that may see it
    Given the variables of .env.example, commented ones included
    When each is looked up among the secrets and the variables that hold none
    Then each is found, and a name that is in neither is not, whatever its prefix

  Scenario: The infrastructure recipes run tofu with only the secrets it uses
    Given every secret variable set to a marker and a recording tofu
    When infra-plan, infra-apply and infra-destroy run for the cluster stack
    Then tofu gets the state key, the encryption settings, the cloud credential and the stacks' inputs, and no age key, no cluster S3 key, no passphrase variable and no allowlist variable

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

  Scenario: The allowlist is used as given and no recipe says otherwise
    Given an operator allowlist and the cluster and ci stacks
    When infra-plan, infra-apply and infra-destroy run for each, with --yes where they ask
    Then no recipe prints anything about adding an address to the allowlist, and tofu gets the allowlist exactly as the operator wrote it

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
