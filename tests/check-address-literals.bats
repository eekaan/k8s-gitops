#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-address-literals"
  # Literals the check must flag live only under the fixtures path, which this repository's own check skips.
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/check-address-literals"
  # The fixtures' class E literals are named here through their prefix, so this file holds none itself.
  CLASS_E=240.1.2
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q "$BATS_TEST_TMPDIR/repo"
  cd "$BATS_TEST_TMPDIR/repo" || return 1
}

@test "A tracked file with an address literal fails the check" {
  mkdir config
  cp "$FIXTURES/undeclared.txt" config/resolver.txt
  git add config/resolver.txt
  literal=$(sed -n 's/^resolver: //p' config/resolver.txt)
  [ -n "$literal" ]

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ $output == *"config/resolver.txt:2: $literal"* ]]
}

@test "Documentation ranges and declared literals pass the check" {
  cat > endpoints.txt <<'EOF'
api: https://192.0.2.10:6443
pods: 198.51.100.0/24
egress: 203.0.113.7/32
health: http://127.0.0.1:8080
resolver: 127.0.0.53
listen: 0.0.0.0
default-route: 0.0.0.0/0
metadata: http://169.254.169.254/latest/meta-data
netmask: 255.255.255.0
EOF
  cp "$FIXTURES/declared.txt" declared.txt
  cp "$FIXTURES/address-allowlist" .address-allowlist
  git add .

  run "$SCRIPT"

  [ "$status" -eq 0 ]
}

@test "Fixture paths are not scanned" {
  mkdir -p tests/fixtures
  cp "$FIXTURES/undeclared.txt" tests/fixtures/resolver.txt
  git add tests/fixtures/resolver.txt

  run "$SCRIPT"

  [ "$status" -eq 0 ]
}

@test "A version string is not an address" {
  cat > versions.txt <<'EOF'
talosctl v1.14.6
flux 2.10.0
talman 1.0.0-beta.10
jq-1.8.2
go1.26.9
helm v4.3.1+gbec5b06
firmware v1.2.3.4
release 1.2.3.4.5
build 1.2.3.4567
calendar 300.12.1.0
EOF
  git add versions.txt

  run "$SCRIPT"

  [ "$status" -eq 0 ]
}

@test "Dotted numbers longer than an address are not flagged" {
  cat > numbers.txt <<'EOF'
release 1.2.3.4.5.6.7
oid: 1.3.6.1.2.1.1
oid: 1.3.6.1.4.1.11129.2.4.2
x 1.2.3.4567.8.9.10
EOF
  git add numbers.txt

  run "$SCRIPT"

  [ "$status" -eq 0 ]
}

@test "Addresses at the start of a line, side by side and in URLs fail the check" {
  cp "$FIXTURES/positions.txt" positions.txt
  git add positions.txt

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ $output == *"positions.txt:1: $CLASS_E.3"* ]]
  [[ $output == *"positions.txt:2: $CLASS_E.4"* ]]
  [[ $output == *"positions.txt:2: $CLASS_E.5"* ]]
  [[ $output == *"positions.txt:3: $CLASS_E.6"* ]]
}

@test "An address after an escape sequence fails the check" {
  cp "$FIXTURES/escapes.json" escapes.json
  git add escapes.json

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ $output == *"escapes.json:1: $CLASS_E.3"* ]]
  [[ $output == *"escapes.json:1: $CLASS_E.4"* ]]
  [[ $output == *"escapes.json:1: $CLASS_E.5"* ]]
  [[ $output == *"escapes.json:1: $CLASS_E.6"* ]]
}

@test "A line with a byte that is not UTF-8 is still scanned" {
  printf 'caf\xe9 resolver %s.3\n' "$CLASS_E" > menu.txt
  git add menu.txt

  # Only a UTF-8 locale treats the byte as an encoding error.
  run env LC_ALL=C.UTF-8 "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ $output == *"menu.txt:1: $CLASS_E.3"* ]]
}

@test "A symlink out of the repository is not followed by the address check" {
  cp "$FIXTURES/undeclared.txt" "$BATS_TEST_TMPDIR/outside.txt"
  ln -s "$BATS_TEST_TMPDIR/outside.txt" resolver.txt
  git add resolver.txt

  run "$SCRIPT"

  [ "$status" -eq 0 ]
}
