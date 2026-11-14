#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-conflict-markers"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q "$BATS_TEST_TMPDIR/repo"
  cd "$BATS_TEST_TMPDIR/repo" || return 1
  # The markers are put together here, so no line of this file is one.
  OURS=$(printf '%7s' '' | tr ' ' '<')
  MID=$(printf '%7s' '' | tr ' ' '=')
  THEIRS=$(printf '%7s' '' | tr ' ' '>')
}

# conflict FILE: a file as git writes it for a conflict: three lines of text, then the block.
conflict() {
  printf '%s\n' 'first line' "$OURS HEAD" 'ours' "$MID" 'theirs' "$THEIRS feature" 'last line' > "$1"
}

@test "A merge conflict marker in a file git would commit fails the check" {
  mkdir docs config
  conflict docs/guide.md
  conflict config/values.yaml
  conflict untracked.txt
  git add docs config
  conflict ignored.txt
  echo ignored.txt > .gitignore

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  for file in docs/guide.md config/values.yaml untracked.txt; do
    [[ $output == *"$file:2:"* ]] || { echo "opening line of $file not named"; return 1; }
    [[ $output == *"$file:4:"* ]] || { echo "middle line of $file not named"; return 1; }
    [[ $output == *"$file:6:"* ]] || { echo "closing line of $file not named"; return 1; }
  done
  [[ $output != *ignored.txt* ]]
}

@test "A marker in a file with CRLF line endings fails the check" {
  printf '%s\r\n' 'first' "$OURS HEAD" 'ours' "$MID" 'theirs' "$THEIRS feature" > windows.md

  run "$SCRIPT"

  [ "$status" -ne 0 ]
  [[ $output == *"windows.md:2:"* ]]
  [[ $output == *"windows.md:4:"* ]]
  [[ $output == *"windows.md:6:"* ]]
}

@test "Text that only looks like a conflict marker passes the check" {
  # A Markdown heading underlined with equals signs, in the length of a marker and in others.
  printf '%s\n' 'Title' "$MID" '' 'Other' '===' '' 'Third' "$MID=" > headings.md
  # Runs of the wrong length, an indented run such as a code sample holds, and a run mid-line.
  printf '%s\n' "${OURS%<} HEAD" "${OURS}< HEAD" "  $OURS HEAD" "text $OURS HEAD" "${THEIRS%>} feature" "  $THEIRS feature" > lookalikes.txt
  # A YAML value that is only an equals run.
  printf 'separator: %s\n' "$MID" > values.yaml
  git add .

  run "$SCRIPT"

  [ "$status" -eq 0 ]
}
