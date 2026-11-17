#!/usr/bin/env bats

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/docker.calls"
  mkdir -p "$BIN"
  # A docker that records each call, one line, and answers inspect with INSPECT, or fails when it
  # is empty, as docker does for a container that does not exist.
  cat > "$BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "$*" >> "$RECORD"
if [[ $1 == inspect ]]; then
  [[ -n ${INSPECT-} ]] || exit 1
  echo "$INSPECT"
fi
DOCKER
  chmod +x "$BIN/docker"
  IMAGE=$(sed -n 's/^dagger_engine:[[:space:]]*//p' "$REPO/versions.yaml")
  NAME=dagger-engine-$(sed -E 's/@.*//; s/.*://' <<< "$IMAGE")
  export RECORD
  unset DAGGER_ENGINE _EXPERIMENTAL_DAGGER_RUNNER_HOST
}

engine() {
  run env PATH="$BIN:/usr/bin:/bin" INSPECT="${1-}" "$REPO/scripts/dagger-engine"
}

@test "The engine starts without the cache entries its image ships" {
  # No container: one is made, named as the pinned CLI names its engine, from the pinned image by
  # digest, with an empty file system over the entries.
  engine
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^run ' "$RECORD")" -eq 1 ]
  made=$(grep '^run ' "$RECORD")
  [[ $made == *" --name $NAME "* ]]
  [[ $made == *" --tmpfs /usr/local/share/dagger/entries "* ]]
  [[ $made == *" --privileged "* ]]
  [[ $made == *" $IMAGE" ]]
  [[ $IMAGE == *@sha256:* ]]
  # The name is the one the pinned CLI starts: dagger-engine- and its own version.
  [ "$NAME" = "dagger-engine-v$(sed -n 's/.*"http:dagger" = { version = "\([^"]*\)".*/\1/p' "$REPO/mise.toml")" ]

  # One that runs is left alone, with or without the mount.
  : > "$RECORD"
  engine 'true false null'
  [ "$status" -eq 0 ]
  [ "$(grep -vc '^inspect ' "$RECORD")" -eq 0 ]

  # One that has the mount and does not run is started, not made again.
  : > "$RECORD"
  engine 'false false {"/usr/local/share/dagger/entries":""}'
  [ "$status" -eq 0 ]
  grep -qx "start $NAME" "$RECORD"
  [ "$(grep -c '^run ' "$RECORD")" -eq 0 ]

  # One made from the image as it is, which does not run or keeps restarting, stops the run and
  # says how to replace it; nothing is removed.
  for state in 'false false null' 'true true null'; do
    : > "$RECORD"
    engine "$state"
    [ "$status" -ne 0 ]
    [[ $output == *"docker rm $NAME"* ]]
    [ "$(grep -vc '^inspect ' "$RECORD")" -eq 0 ]
  done

  # An engine the caller names is not touched.
  : > "$RECORD"
  run env PATH="$BIN:/usr/bin:/bin" DAGGER_ENGINE=unix:///run/dagger/engine.sock "$REPO/scripts/dagger-engine"
  [ "$status" -eq 0 ]
  [ ! -s "$RECORD" ]
}

@test "Every recipe and script that calls Dagger starts the engine first" {
  # Each line that calls the module is preceded, in the same recipe or script, by the start.
  for file in justfile scripts/tools-image; do
    calls=$(grep -n 'dagger api call' "$REPO/$file" | cut -d: -f1)
    [ -n "$calls" ]
    for line in $calls; do
      before=$(sed -n "$((line - 1))p" "$REPO/$file")
      echo "$file:$line follows: $before"
      [[ $before == *scripts/dagger-engine* ]]
    done
  done
}
