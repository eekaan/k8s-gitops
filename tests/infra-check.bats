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

@test "A schematic with the guest agent extension fails the infrastructure check, naming it" {
  repository guest-agent
  valid_stack region/good
  mkdir talos
  cat > talos/schematic.yaml <<'EOF'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/gvisor
EOF

  run "$SCRIPT"

  [ "$status" -eq 0 ]

  cat > talos/schematic.yaml <<'EOF'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/gvisor
      - siderolabs/qemu-guest-agent
EOF

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ $output == *"infra-check: talos/schematic.yaml: lists the system extension siderolabs/qemu-guest-agent"* ]]
  [[ $output != *"system extension siderolabs/gvisor"* ]]
  [ "${lines[-1]}" = "infra-check: failed: talos/schematic.yaml" ]
}

@test "a schematic that does not parse fails the check, naming it" {
  repository unparsable-schematic
  valid_stack region/good
  mkdir talos
  printf 'customization: [unterminated\n' > talos/schematic.yaml

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ $output == *"infra-check: talos/schematic.yaml: does not parse"* ]]
  [ "${lines[-1]}" = "infra-check: failed: talos/schematic.yaml" ]
}

# defaults STACK NAME VALUE...: a variables.tf in the stack STACK whose variables NAME default to
# VALUE, pair by pair.
defaults() {
  local file="infra/openstack/stacks/$1/variables.tf"
  shift
  : > "$file"
  while (($#)); do
    printf 'variable "%s" {\n  type    = string\n  default = "%s"\n}\n\n' "$1" "$2" >> "$file"
    shift 2
  done
}

@test "a default service range overlapping a default node, pod or service subnet fails the check, naming both" {
  repository service-range
  valid_stack region/plumbing
  valid_stack region/cluster
  defaults region/plumbing node_cidr 192.0.2.0/25 service_range 192.0.2.128/28
  defaults region/cluster pod_subnet 198.51.100.0/24 service_subnet 203.0.113.0/24

  run "$SCRIPT"

  [ "$status" -eq 0 ]

  for overlapping in 'pod_subnet 192.0.2.128/26' 'service_subnet 192.0.2.0/24' 'node_cidr 192.0.2.0/24'; do
    read -r name value <<< "$overlapping"
    echo "$name"
    defaults region/plumbing node_cidr 192.0.2.0/25 service_range 192.0.2.128/28
    defaults region/cluster pod_subnet 198.51.100.0/24 service_subnet 203.0.113.0/24
    if [[ $name == node_cidr ]]; then
      defaults region/plumbing node_cidr "$value" service_range 192.0.2.128/28
    elif [[ $name == pod_subnet ]]; then
      defaults region/cluster pod_subnet "$value" service_subnet 203.0.113.0/24
    else
      defaults region/cluster pod_subnet 198.51.100.0/24 service_subnet "$value"
    fi

    run "$SCRIPT"

    [ "$status" -ne 0 ]
    [[ $output == *"infra-check: infra/openstack/stacks/region: the plumbing stack's default service_range overlaps the default $name"* ]]
    [[ $output != *"192.0.2."* ]]
    [ "${lines[-1]}" = "infra-check: failed: infra/openstack/stacks/region" ]
  done

  # A default that is not an IPv4 network is named too.
  defaults region/plumbing node_cidr 192.0.2.0/25 service_range not-a-network

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ $output == *"infra-check: infra/openstack/stacks/region: the default service_range is not an IPv4 network"* ]]
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

# A module with a test and no stack calling it, so only the discovery of module tests runs it.
module_with_test() {
  mkdir -p "infra/openstack/modules/$1/tests"
  cat > "infra/openstack/modules/$1/main.tf" <<'EOF'
variable "size" {
  type    = number
  default = 1
}

output "size" {
  value = var.size
}
EOF
  cat > "infra/openstack/modules/$1/tests/size.tftest.hcl" <<EOF
run "size" {
  command = plan

  assert {
    condition     = output.size == $2
    error_message = "The size must be $2."
  }
}
EOF
}

@test "A module whose test fails fails the infrastructure check, naming it" {
  repository module-test
  valid_stack region/good
  module_with_test passing 1
  module_with_test failing 2

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ $output == *"infra-check: infra/openstack/modules/failing: tofu test failed"* ]]
  [[ $output == *"infra-check: infra/openstack/modules/passing: init, validate and test passed"* ]]
  [[ $output != *"modules/passing: tofu test failed"* ]]
  [ "${lines[-1]}" = "infra-check: failed: infra/openstack/modules/failing" ]
}
