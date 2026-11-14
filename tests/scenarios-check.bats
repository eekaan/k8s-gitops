#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/scenarios-check"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q "$BATS_TEST_TMPDIR/repo"
  cd "$BATS_TEST_TMPDIR/repo" || return 1
  mkdir -p features/talos tests infra/nodes/tests
}

# bats_proof FILE TITLE: appends a bats test with that title. It goes through printf so that this
# file holds no test line of its own for bats or the check to pick up.
bats_proof() {
  printf '@test "%s" {\n  true\n}\n' "$2" >> "$1"
}

# tofu_proof FILE NAME: appends an OpenTofu test run with that name.
tofu_proof() {
  printf 'run "%s" {\n  command = plan\n}\n' "$2" >> "$1"
}

# has_line A B: one line of the output holds both A and B.
has_line() {
  local line
  for line in "${lines[@]}"; do
    if [[ $line == *"$1"* && $line == *"$2"* ]]; then
      return 0
    fi
  done
  return 1
}

@test "Every recipe that proves a scenario runs in just ci" {
  root=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  mapfile -t proving < <(grep -rhoE '(^|[[:blank:]])@by:[^[:blank:]]+' "$root/features" | sed 's/.*@by://' | sort -u)
  [ "${#proving[@]}" -gt 0 ]
  # The recipes just ci runs: its dependencies and theirs, as just reads the justfile and its imports.
  ran=$(just --justfile "$root/justfile" --dump --dump-format json | jq -r '
    .recipes as $recipes
    | def runs($name): $recipes[$name].dependencies[]?.recipe | (., runs(.));
    [runs("ci")] | unique[]')
  [ -n "$ran" ]
  for recipe in "${proving[@]}"; do
    if ! grep -qxF -- "$recipe" <<< "$ran"; then
      echo "just ci does not run $recipe, which proves a scenario" >&2
      return 1
    fi
  done
}

@test "A scenario with a proof of the same name passes" {
  cat > features/nodes.feature <<'EOF'
Feature: Nodes
  Nodes join the cluster.

  Scenario: A node joins the cluster
    Given a node
    When it boots
    Then it joins

  Scenario: The plan doesn't touch a node’s disk, ever
    Given a node
    When the plan runs
    Then its disk is unchanged

  Scenario Outline: A node with <disks> disks joins the cluster
    Given a node with <disks> disks
    When it boots
    Then it joins

    Examples:
      | disks |
      | 2     |

  @pending @FND-7
  Rule: Replacing nodes

    Scenario: A node is replaced without downtime
      Given a node
      When it is replaced
      Then no workload stops
EOF
  bats_proof tests/nodes.bats "A node joins the cluster"
  bats_proof tests/nodes.bats "A node with <disks> disks joins the cluster"
  # Both apostrophes are dropped and every other run of punctuation and spaces is one underscore.
  tofu_proof infra/nodes/tests/nodes.tftest.hcl the_plan_doesnt_touch_a_nodes_disk_ever
  # An ordinary test and a setup run claim no scenario.
  bats_proof tests/nodes.bats "slug drops apostrophes"
  tofu_proof infra/nodes/tests/nodes.tftest.hcl _setup

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$output" = "4 scenarios: 3 proved, 1 pending." ]
}

@test "A scenario without a proof fails" {
  cat > features/nodes.feature <<'EOF'
Feature: Nodes
  Nodes join the cluster.

  Scenario: A node joins the cluster
    Given a node
    When it boots
    Then it joins

  Scenario: A node leaves the cluster
    Given a node
    When it is drained
    Then it leaves
EOF
  bats_proof tests/nodes.bats "A node joins the cluster"

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  has_line "features/nodes.feature:9: " "A node leaves the cluster"
  [[ $output != *"A node joins the cluster"* ]]
}

@test "A pending scenario needs its issue key" {
  cat > features/nodes.feature <<'EOF'
Feature: Nodes
  Nodes join the cluster.

  @pending
  Scenario: A node is replaced without downtime
    Given a node
    When it is replaced
    Then no workload stops

  @pending @FND-7
  Scenario: A node is drained before an upgrade
    Given a node
    When it is upgraded
    Then it was drained first
EOF

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  has_line "features/nodes.feature:5: " "A node is replaced without downtime"
  [[ $output != *"A node is drained before an upgrade"* ]]
}

@test "A pending scenario that has a proof fails" {
  cat > features/nodes.feature <<'EOF'
Feature: Nodes
  Nodes join the cluster.

  @pending @FND-7
  Scenario: A node is replaced without downtime
    Given a node
    When it is replaced
    Then no workload stops
EOF
  bats_proof tests/nodes.bats "A node is replaced without downtime"

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  has_line "features/nodes.feature:5: " "remove the @pending tag"
}

@test "A proof without a scenario fails" {
  cat > features/nodes.feature <<'EOF'
Feature: Nodes
  Nodes join the cluster.

  Scenario: A node joins the cluster
    Given a node
    When it boots
    Then it joins
EOF
  bats_proof tests/nodes.bats "A node joins the cluster"
  bats_proof tests/nodes.bats "A node joins the old cluster"
  tofu_proof infra/nodes/tests/nodes.tftest.hcl a_node_joins_the_old_cluster

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  has_line "tests/nodes.bats:4: " "A node joins the old cluster"
  has_line "infra/nodes/tests/nodes.tftest.hcl:1: " "a_node_joins_the_old_cluster"
  [[ $output != *"tests/nodes.bats:1:"* ]]
}

@test "Duplicate scenario titles fail" {
  cat > features/nodes.feature <<'EOF'
Feature: Nodes
  Nodes join the cluster.

  Scenario: A node joins the cluster
    Given a node
    When it boots
    Then it joins
EOF
  cat > features/talos/join.feature <<'EOF'
Feature: Joining
  Talos nodes join the cluster.

  Scenario: A node joins the cluster
    Given a Talos node
    When it boots
    Then it joins

  Scenario: A Node joins the cluster
    Given a Talos node
    When it boots
    Then it joins
EOF
  bats_proof tests/nodes.bats "A node joins the cluster"

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  has_line "features/nodes.feature:4" "features/talos/join.feature:4"
  # A run name could not tell these two apart either.
  has_line "features/nodes.feature:4" "features/talos/join.feature:9"
}

@test "A scenario proved by a recipe passes" {
  cat > features/stacks.feature <<'EOF'
Feature: Stacks
  The stacks and their configuration pass their offline checks.

  @by:stack-check
  Scenario: The stacks pass the offline check
    Given the stacks
    When the offline check runs
    Then it exits zero

  @by:config-check
  Scenario: The configuration passes its validator
    Given the configuration
    When its validator runs
    Then it exits zero
EOF
  cat > justfile <<'EOF'
import 'just/config.just'

stack-check:
    true
EOF
  mkdir just
  cat > just/config.just <<'EOF'
config-check:
    true
EOF

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$output" = "2 scenarios: 2 proved, 0 pending." ]
}

@test "A recipe proof naming an unknown recipe fails" {
  cat > features/stacks.feature <<'EOF'
Feature: Stacks
  The stacks pass their offline check.

  @by:stack-validate
  Scenario: The stacks pass the offline check
    Given the stacks
    When the offline check runs
    Then it exits zero
EOF
  cat > justfile <<'EOF'
stack-check:
    true
EOF

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  has_line "features/stacks.feature:5: " "The stacks pass the offline check"
  has_line "features/stacks.feature:5: " "@by:stack-validate"
}

@test "A recipe proof on a pending scenario fails" {
  cat > features/stacks.feature <<'EOF'
Feature: Stacks
  The stacks pass their offline check.

  @pending @FND-7 @by:stack-check
  Scenario: The stacks pass the offline check
    Given the stacks
    When the offline check runs
    Then it exits zero
EOF
  cat > justfile <<'EOF'
stack-check:
    true
EOF

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  has_line "features/stacks.feature:5: " "The stacks pass the offline check"
  has_line "features/stacks.feature:5: " "@by:stack-check"
}

@test "A recipe proof without just on PATH fails" {
  cat > features/stacks.feature <<'EOF'
Feature: Stacks
  The stacks pass their offline check.

  @by:stack-check
  Scenario: The stacks pass the offline check
    Given the stacks
    When the offline check runs
    Then it exits zero
EOF
  cat > justfile <<'EOF'
stack-check:
    true
EOF
  # Everything else the check runs stays on PATH, so only the missing just can fail it.
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  for tool in bash git sort; do
    ln -s "$(command -v "$tool")" "$BIN/$tool"
  done

  run env PATH="$BIN" "$SCRIPT"

  [ "$status" -ne 0 ]
  has_line "features/stacks.feature:5: " "just is not on PATH"
}

@test "A scenario with more than one proof fails" {
  cat > features/nodes.feature <<'EOF'
Feature: Nodes
  Nodes join the cluster and pass their checks.

  Scenario: A node joins the cluster
    Given a node
    When it boots
    Then it joins

  @by:stack-check
  Scenario: The stacks pass the offline check
    Given the stacks
    When the offline check runs
    Then it exits zero
EOF
  cat > justfile <<'EOF'
stack-check:
    true
EOF
  bats_proof tests/nodes.bats "A node joins the cluster"
  bats_proof tests/nodes.bats "The stacks pass the offline check"
  tofu_proof infra/nodes/tests/nodes.tftest.hcl a_node_joins_the_cluster

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  has_line "features/nodes.feature:4: " "tests/nodes.bats:1"
  has_line "features/nodes.feature:4: " "infra/nodes/tests/nodes.tftest.hcl:1"
  has_line "features/nodes.feature:10: " "tests/nodes.bats:4"
  has_line "features/nodes.feature:10: " "@by:stack-check"
}

@test "Pending inherited from the feature's tags counts" {
  cat > features/upgrades.feature <<'EOF'
@pending @FND-9
Feature: Upgrades
  Nodes upgrade in place.

  Scenario: A node upgrades in place
    Given a node
    When an upgrade is applied
    Then it runs the new version

  Scenario: An upgrade drains the node first
    Given a node
    When an upgrade is applied
    Then it was drained first
EOF

  run "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$output" = "2 scenarios: 0 proved, 2 pending." ]
}

@test "A scenario whose title starts with a digit is told to use bats or a recipe" {
  cat > features/quorum.feature <<'EOF'
Feature: Quorum
  The control plane keeps quorum.

  Scenario: 3 control plane nodes keep quorum when one fails
    Given 3 control plane nodes
    When one fails
    Then the cluster still answers
EOF

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  has_line "features/quorum.feature:4: " "3 control plane nodes keep quorum when one fails"
  has_line "features/quorum.feature:4: " "an OpenTofu run cannot prove it"
  # OpenTofu refuses a run name that starts with a digit, so none is offered.
  [[ $output != *'run "3_control'* ]]
}
