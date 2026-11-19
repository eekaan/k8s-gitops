#!/usr/bin/env bats
# Proves the first two scenarios of features/rebuild.feature, those of the rebuild runbook; each test
# carries its scenario's title. The restores are read from the runbooks themselves, every "## Restoring"
# heading of docs/runbooks/*.md and every runbook whose title begins with Restoring, by the anchor
# GitHub gives the heading; the databases from the render of the tree, scripts/render run once for the
# file, as tests/network-policy.bats renders it, every Cluster.postgresql.cnpg.io_<namespace>_<name>.yaml
# of lab-sto2. The render pulls the pinned charts from their public registries and reaches nothing else.

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  RUNBOOKS="$REPO/docs/runbooks"
  REBUILD="$RUNBOOKS/rebuild.md"
}

# anchor HEADING: the anchor GitHub gives HEADING: lower case, every character but a letter, a digit,
# a space, a hyphen or an underscore dropped, and each space a hyphen.
anchor() {
  local text=${1,,}
  text=$(LC_ALL=C sed -E 's/[^a-z0-9 _-]//g; s/ /-/g' <<<"$text")
  printf '%s\n' "$text"
}

# restores [DIR]: every restore the runbooks in DIR, docs/runbooks by default, hold, as
# <file>#<anchor>, one per line: each "## Restoring" heading, and the title of each runbook whose
# title begins with Restoring. rebuild.md is the runbook that links them, and none of them.
restores() {
  local dir=${1:-$RUNBOOKS} file heading
  for file in "$dir"/*.md; do
    [[ ${file##*/} != rebuild.md ]] || continue
    while IFS= read -r heading; do
      printf '%s#%s\n' "${file##*/}" "$(anchor "${heading#\#* }")"
    done < <(awk 'FNR == 1 && /^# Restoring/ || /^## Restoring/' "$file")
  done
}

# section NAME [FILE]: the lines of the "## NAME" section of FILE, rebuild.md by default, up to the
# next "## " heading.
section() {
  awk -v name="## $1" '$0 == name { inside = 1; next } inside && /^## / { exit } inside' "${2:-$REBUILD}"
}

# steps NAME: the numbered steps of the "## NAME" section of rebuild.md, in order, one per line, each
# its lines joined by spaces, what is indented under it included.
steps() {
  section "$1" | awk '/^[0-9]+\. / { if (text != "") print text; text = $0; next }
    text != "" { text = text " " $0 } END { if (text != "") print text }'
}

# step_of NAME TEXT: the number of the first step of the section NAME whose text holds TEXT, by its
# place in the section; nothing when none does.
step_of() {
  steps "$1" | grep -nF -- "$2" | head -n 1 | cut -d: -f1
}

# step_holds NAME TITLE TEXT...: the step of the section NAME titled TITLE, in bold, holds each TEXT;
# prints its place.
step_holds() {
  local name=$1 title=$2 place text
  shift 2
  place=$(step_of "$name" "**$title**")
  [ -n "$place" ] || { echo "no step $title in $name" >&2; return 1; }
  for text; do
    steps "$name" | sed -n "${place}p" | grep -qF -- "$text" || { echo "step $title does not hold $text" >&2; return 1; }
  done
  echo "$place"
}

# rows [FILE]: the database rows of the table of "Building it again" in FILE, rebuild.md by default:
# each row whose first cell is a `<namespace>/<name>`, as that name, a tab and the rest of the row.
# shellcheck disable=SC2016 # the backquotes are Markdown's.
rows() {
  section 'Building it again' "${1:-$REBUILD}" |
    sed -nE 's/^ *\| `([a-z0-9-]+\/[a-z0-9-]+)` \|(.*)$/\1\t\2/p'
}

# databases RENDER: every PostgreSQL Cluster of lab-sto2 in the render RENDER, as <namespace>/<name>,
# sorted.
databases() {
  find "$1/lab-sto2" -type f -name 'Cluster.postgresql.cnpg.io_*.yaml' -printf '%f\n' |
    sed -E 's/^Cluster\.postgresql\.cnpg\.io_([^_]+)_(.+)\.yaml$/\1\/\2/' | sort
}

# covered RENDER [FILE]: whether FILE, rebuild.md by default, has one row for each database of the
# render RENDER and none for another, each with a link to a restore of postgres-restore.md or the
# words "made again by a start"; names each database that fails.
covered() {
  local render=$1 file=${2:-$REBUILD} database row problems=() count
  while IFS= read -r database; do
    count=$(rows "$file" | awk -F'\t' -v db="$database" '$1 == db' | grep -c . || true)
    row=$(rows "$file" | awk -F'\t' -v db="$database" '$1 == db { print $2 }')
    if ((count != 1)); then
      problems+=("$database: $count rows in the table")
    elif [[ $row != *"](postgres-restore.md#restoring-one-database-to-a-point-in-time)"* &&
      $row != *"](postgres-restore.md#restoring-a-daily-dump)"* && $row != *"made again by a start"* ]]; then
      problems+=("$database: its row links no restore and does not say it is made again by a start")
    fi
  done < <(databases "$render")
  while IFS= read -r database; do
    grep -qxF -- "$database" < <(databases "$render") || problems+=("$database: a row for a database the render does not build")
  done < <(rows "$file" | cut -f1)
  ((${#problems[@]} == 0)) || { printf '%s\n' "${problems[@]}"; return 1; }
}

# real_render: the render of this repository's tree, charts pulled, in $BATS_FILE_TMPDIR/render.
real_render() {
  REAL="$BATS_FILE_TMPDIR/render"
  if [ ! -d "$REAL" ]; then
    "$REPO/scripts/render" "$REAL.partial" >/dev/null
    mv "$REAL.partial" "$REAL"
  fi
}

# shellcheck disable=SC2016 # the backquotes are Markdown's.
@test "The rebuild runbook links every restore the runbooks hold, the secret store's before what reads it" {
  local found restore missing=() hold build store volumes databases taking destroy
  found=$(restores)
  echo "the runbooks' restores: $(paste -sd' ' - <<<"$found")"
  # The five restores the runbooks hold now are among them, so a change to how they are read cannot
  # pass by finding none.
  for restore in openbao.md#restoring-a-snapshot postgres-restore.md#restoring-one-database-to-a-point-in-time \
    postgres-restore.md#restoring-a-daily-dump volume-backups.md#restoring-a-claim-from-its-repository \
    etcd-restore.md#restoring-etcd-from-a-snapshot; do
    grep -qxF "$restore" <<<"$found"
  done
  while IFS= read -r restore; do
    grep -qF -- "]($restore)" "$REBUILD" || missing+=("$restore")
  done <<<"$found"
  echo "not linked from rebuild.md: ${missing[*]:-none}"
  [ "${#missing[@]}" -eq 0 ]
  # And the reason etcd's restore is not one the rebuild takes.
  grep -qF '](etcd-restore.md#when-to-restore)' "$REBUILD"
  # Building it again, step by step: the hold, in the artifact Flux applies, before the build that
  # installs Flux; the old seal key put in place in that build, before OpenBao's first member starts,
  # after a seal-key rotation from the custody file bao-seal-keep wrote, with the previous key's
  # Secret too; the secret store before the volumes, whose key it holds, and the volumes before the
  # databases, each step with the restores it leads to.
  hold=$(step_holds 'Building it again' 'The hold.' 'CNPG_BACKUPS_SUSPENDED: "true"' \
    'merged and published before `just cluster-flux`' '](../kubernetes.md#publishing)')
  build=$(step_holds 'Building it again' 'The build.' '`just cluster-flux`' '`just bao-seal-restore <openbao file>`' \
    '](openbao.md#restoring-a-snapshot)' '`just bao-seal-keep`' "the previous key's Secret" '](openbao.md#rotating)')
  store=$(step_holds 'Building it again' 'The secret store.' '](openbao.md#restoring-a-snapshot)' \
    '](openbao.md#restoring-access-with-the-recovery-keys)' '](openbao.md#first-initialisation)')
  volumes=$(step_holds 'Building it again' 'The volumes.' '](volume-backups.md#the-stores-key-is-lost-and-the-file-is-kept)' \
    '](volume-backups.md#restoring-a-claim-from-its-repository)')
  databases=$(step_holds 'Building it again' 'The databases.' '](postgres-restore.md#restoring-one-database-to-a-point-in-time)' \
    '](postgres-restore.md#restoring-a-daily-dump)')
  echo "steps: the hold $hold, the build $build, the secret store $store, the volumes $volumes, the databases $databases"
  ((hold < build && build < store && store < volumes && volumes < databases))
  # No step before the hold runs Flux.
  [ "$(steps 'Building it again' | head -n $((hold - 1)) | grep -cF '`just cluster-flux`')" -eq 0 ]
  # Taking it down: the last copies before the destroy.
  taking=$(step_holds 'Taking it down' '`just cluster-last-copies <openbao file> <volsync file> <postgres file>`')
  destroy=$(step_holds 'Taking it down' '`just cluster-destroy`')
  echo "steps: the last copies $taking, the destroy $destroy"
  ((taking < destroy))
  # A restore added to a runbook is one the rebuild runbook does not link yet.
  mkdir -p "$BATS_TEST_TMPDIR/runbooks"
  cp "$RUNBOOKS"/*.md "$BATS_TEST_TMPDIR/runbooks/"
  printf '\n## Restoring the marker store\n\nA restore of something new.\n' >>"$BATS_TEST_TMPDIR/runbooks/volume-backups.md"
  grep -qxF 'volume-backups.md#restoring-the-marker-store' <(restores "$BATS_TEST_TMPDIR/runbooks")
}

@test "The rebuild runbook names every database the cluster's render builds, and how each comes back" {
  local copy="$BATS_TEST_TMPDIR/render" one
  real_render
  echo "the render's databases: $(databases "$REAL" | paste -sd' ' -)"
  echo "the table's rows: $(rows | cut -f1 | paste -sd' ' -)"
  # The three the overlay builds now are among them, so a render that finds none cannot pass.
  [ "$(databases "$REAL" | grep -cxE 'ai-system/n8n-db|backstage/backstage-db|ascender/ascender-db')" -eq 3 ]
  run covered "$REAL"
  echo "$output"
  [ "$status" -eq 0 ]
  # A render with one more database fails, naming it.
  cp -R "$REAL" "$copy"
  one=$(find "$copy/lab-sto2" -type f -name 'Cluster.postgresql.cnpg.io_ai-system_n8n-db.yaml')
  [ -f "$one" ]
  sed -e 's/n8n-db/orders-db/g' -e 's/ai-system/demo/g' "$one" >"${one%/*}/Cluster.postgresql.cnpg.io_demo_orders-db.yaml"
  run covered "$copy"
  echo "$output"
  [ "$status" -ne 0 ]
  [ "$output" = "demo/orders-db: 0 rows in the table" ]
}
