#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/infra-check"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
}

# A throwaway repository, so the check runs against a tree it has never seen.
repository() {
  git init -q "$BATS_TEST_TMPDIR/$1"
  cd "$BATS_TEST_TMPDIR/$1" || return 1
}

# Stacks without providers, so init and validate need no network.
stack() {
  mkdir -p "infra/openstack/stacks/$1"
  cat > "infra/openstack/stacks/$1/main.tf"
}

valid_stack() {
  stack "$1" <<'EOF'
terraform {
  encryption {
    state {
      enforced = true
    }
    plan {
      enforced = true
    }
  }
}

variable "name" {
  type = string
}

output "name" {
  value = var.name
}
EOF
}

@test "A check failure names the stack" {
  repository unformatted
  valid_stack region/good
  stack region/unformatted <<'EOF'
output "name" {
value = "unformatted"
}
EOF

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [ "${lines[-1]}" = "infra-check: failed: infra/openstack/stacks/region/unformatted" ]

  repository invalid
  valid_stack region/good
  stack region/invalid <<'EOF'
output "name" {
  value = var.undeclared
}
EOF

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [ "${lines[-1]}" = "infra-check: failed: infra/openstack/stacks/region/invalid" ]
}

@test "A file that does not parse names its directory" {
  repository unparsable
  valid_stack region/good
  # No stack calls this module, so only the formatting step reads the file.
  mkdir -p infra/openstack/modules/unused
  cat > infra/openstack/modules/unused/main.tf <<'EOF'
output "name" {
  value = "unterminated
}
EOF

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [ "${lines[-1]}" = "infra-check: failed: infra/openstack/modules/unused" ]
}

@test "A stack that does not enforce state encryption fails the check" {
  repository unenforced
  valid_stack region/good
  stack region/plan-unenforced <<'EOF'
terraform {
  encryption {
    state {
      enforced = true
    }
  }
}

output "name" {
  value = "plans unenforced"
}
EOF
  stack region/no-block <<'EOF'
output "name" {
  value = "no encryption block"
}
EOF

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  for dir in plan-unenforced no-block; do
    [[ $output == *"infra-check: infra/openstack/stacks/region/$dir: does not enforce state and plan encryption"* ]]
  done
  [[ $output != *"region/good: does not enforce"* ]]
  [ "${lines[-1]}" = "infra-check: failed: infra/openstack/stacks/region/no-block infra/openstack/stacks/region/plan-unenforced" ]
}

@test "A tree without stacks fails the check" {
  repository stackless
  mkdir -p infra/openstack/modules/network
  cat > infra/openstack/modules/network/main.tf <<'EOF'
variable "name" {
  type = string
}
EOF

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ $output == *"infra-check: infra/openstack/stacks: no stack found"* ]]
  [ "${lines[-1]}" = "infra-check: failed: infra/openstack/stacks" ]
}
