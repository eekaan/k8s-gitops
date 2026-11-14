#!/usr/bin/env bats

setup() {
  JUSTFILE="$BATS_TEST_DIRNAME/../justfile"
  JUST=$(command -v just)
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise < /dev/null
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q "$BATS_TEST_TMPDIR/repo"
  cd "$BATS_TEST_TMPDIR/repo" || return 1
}

# fake NAME: a binary first on the recipe's PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# recipe NAME: runs the repository's recipe against the throwaway repository.
recipe() {
  run env PATH="$BIN:$PATH" "$JUST" --justfile "$JUSTFILE" --working-directory "$PWD" "$1"
}

fake_gitleaks() {
  # Like gitleaks, find does not follow symlinks; every file a dir scan reads is printed with its content.
  fake gitleaks <<'EOF'
if [[ $1 == dir ]]; then
  find . -type f -print -exec cat {} \;
fi
EOF
}

@test "The secrets scan does not follow symlinks" {
  fake_gitleaks
  echo outside-the-repository > "$BATS_TEST_TMPDIR/outside.txt"
  ln -s "$BATS_TEST_TMPDIR/outside.txt" linked.txt
  echo inside-the-repository > inside.txt

  recipe secrets-scan

  [ "$status" -eq 0 ]
  [[ $output == *inside-the-repository* ]]
  [[ $output != *outside-the-repository* ]]
}

@test "The secrets scan reads files whose names start with a dash" {
  fake_gitleaks
  echo dash-named-file > -n.txt

  recipe secrets-scan

  [ "$status" -eq 0 ]
  [[ $output == *dash-named-file* ]]
}

@test "The secrets scan exempts only the address check's fixtures" {
  cp "$BATS_TEST_DIRNAME/../.gitleaks.toml" .gitleaks.toml
  mkdir -p tests/fixtures/check-address-literals tests/fixtures/other
  # In the shape of an AWS access key ID, put together here so this file holds none.
  key=AKIA$(printf '%s' QZ7XK2M4B6N3P5R7)
  for dir in check-address-literals other; do
    echo "aws_access_key_id = $key" > "tests/fixtures/$dir/key.txt"
  done
  git add .
  git -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m fixtures

  recipe secrets-scan

  [ "$status" -ne 0 ]
  [[ $output == *tests/fixtures/other/key.txt* ]]
  [[ $output != *check-address-literals/key.txt* ]]
}

@test "An agent's worktree under .claude/ is ignored in a plain clone" {
  cp "$BATS_TEST_DIRNAME/../.gitignore" .gitignore
  mkdir -p .claude/worktrees/agent
  echo agent-file > .claude/worktrees/agent/file.txt
  [ ! -s .git/info/exclude ] || ! grep -q claude .git/info/exclude

  git check-ignore -q .claude/worktrees/agent/file.txt
  run git ls-files --others --exclude-standard
  [[ $output != *.claude* ]]
}

@test "A mise error stops the recipes" {
  fake_gitleaks
  fake mise <<'EOF'
echo "mise ERROR stand-in: config files are not trusted" >&2
exit 1
EOF

  recipe secrets-scan

  [ "$status" -ne 0 ]
  [[ $output == *"config files are not trusted"* ]]
}

@test "Lint covers only the files git would commit" {
  fake shellcheck < /dev/null
  fake yamllint <<'EOF'
printf 'yamllint got %s\n' "$@"
EOF
  printf -- '---\nkept: true\n' > kept.yaml
  git add kept.yaml
  printf -- '---\nexcluded: true\n' > excluded.yaml
  echo excluded.yaml >> .git/info/exclude

  recipe lint

  [ "$status" -eq 0 ]
  [[ $output == *"yamllint got kept.yaml"* ]]
  [[ $output != *excluded.yaml* ]]
}

@test "The Talos and OpenTofu checks refuse a tool that differs from its pin" {
  mkdir scripts
  cp "$BATS_TEST_DIRNAME/../scripts/tools-check" scripts/
  for check in talos-check infra-check; do
    printf '#!/usr/bin/env bash\necho "%s started"\n' "$check" > "scripts/$check"
    chmod +x "scripts/$check"
  done
  cat > mise.toml <<'EOF'
[tools]
opentofu = "1.13.9"
"github:ludwighansson/talman" = "1.0.0-beta.10"
EOF
  fake tofu <<'EOF'
echo "OpenTofu v1.13.9"
EOF
  fake talman <<'EOF'
echo "talman version v1.0.0-beta.7"
EOF

  for check in talos-check infra-check; do
    recipe "$check"

    [ "$status" -ne 0 ]
    [[ $output == *"talman: pinned 1.0.0-beta.10, found 1.0.0-beta.7"* ]]
    [[ $output != *"$check started"* ]]
  done
}
