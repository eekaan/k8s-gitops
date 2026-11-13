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
