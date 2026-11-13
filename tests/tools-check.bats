#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/tools-check"
  PINS="$BATS_TEST_TMPDIR/mise.toml"
  # The check runs with only bash and the fakes on PATH, so no tool installed on this machine can answer.
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  ln -s "$(command -v bash)" "$BIN/bash"
}

# fake NAME ARGS OUTPUT: a binary that prints OUTPUT only when called with ARGS.
fake() {
  cat > "$BIN/$1" <<EOF
#!/usr/bin/env bash
[[ "\$*" == "$2" ]] || { echo "unexpected arguments: \$*" >&2; exit 2; }
printf '%s\n' "$3"
EOF
  chmod +x "$BIN/$1"
}

@test "A tool that differs from its pin fails the tools check" {
  cat > "$PINS" <<'EOF'
[tools]
kubectl = "1.37.1"
EOF
  fake kubectl "version --client" $'Client Version: v1.36.0\nKustomize Version: v5.7.1'

  run env PATH="$BIN" "$SCRIPT" "$PINS"

  [ "$status" -ne 0 ]
  [[ $output == *kubectl* ]]
  [[ $output == *1.37.1* ]]
  [[ $output == *1.36.0* ]]
}

@test "A missing pinned tool fails the tools check" {
  cat > "$PINS" <<'EOF'
[tools]
jq = "1.8.2"
EOF

  run env PATH="$BIN" "$SCRIPT" "$PINS"

  [ "$status" -ne 0 ]
  [[ $output == *jq* ]]
  [[ $output == *"just tools"* ]]
}

@test "Matching tools pass the tools check" {
  cat > "$PINS" <<'EOF'
[tools]
kubectl = "1.37.1"
# The registry and GitHub-backend names differ from the binaries.
flux2 = "2.10.0"
"github:ludwighansson/talman" = "1.0.0-beta.10"

helm = "4.3.1"
jq = "1.8.2"
EOF
  fake kubectl "version --client" $'Client Version: v1.37.1\nKustomize Version: v5.8.1'
  fake flux "version --client" "flux: v2.10.0"
  fake talman "--version" "talman version 1.0.0-beta.10"
  fake helm "version --short" "v4.3.1+gbec5b06"
  fake jq "--version" "jq-1.8.2"

  run env PATH="$BIN" "$SCRIPT" "$PINS"

  [ "$status" -eq 0 ]
  [[ $output == *"All 5 pinned tools match"* ]]
}

@test "A mise.toml with no readable pins fails the tools check" {
  cat > "$PINS" <<'EOF'
[tools.jq]
version = "1.8.2"
EOF
  fake jq "--version" "jq-1.8.2"

  run env PATH="$BIN" "$SCRIPT" "$PINS"

  [ "$status" -ne 0 ]
  [[ $output == *"no pinned tools"* ]]
}
