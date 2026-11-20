#!/usr/bin/env bats
# Proves the first three scenarios of features/rebuild.feature, those of the rebuild runbook, and the
# scenario of features/dns.feature about where the runbooks take the DNS records out; each test
# carries its scenario's title. The restores are read from the runbooks themselves, every
# "## Restoring" heading of docs/runbooks/*.md and every runbook whose title begins with Restoring, by
# the anchor GitHub gives the heading; the databases, and Ascender's secret key, from the render of the
# tree, scripts/render run once for the file, as tests/network-policy.bats renders it: every
# Cluster.postgresql.cnpg.io_<namespace>_<name>.yaml of lab-sto2, and every AWX.awx.ansible.com_*.yaml
# with the ExternalSecret that writes the Secret its secret_key_secret names. The render pulls the
# pinned charts from their public registries and reaches nothing else.

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

# steps NAME [FILE]: the numbered steps of the "## NAME" section of FILE, rebuild.md by default, in
# order, one per line, each its lines joined by spaces, what is indented under it included.
steps() {
  section "$1" "${2:-$REBUILD}" | awk '/^[0-9]+\. / { if (text != "") print text; text = $0; next }
    text != "" { text = text " " $0 } END { if (text != "") print text }'
}

# step_of NAME TEXT [FILE]: the number of the first step of the section NAME of FILE, rebuild.md by
# default, whose text holds TEXT, by its place in the section; nothing when none does.
step_of() {
  steps "$1" "${3:-$REBUILD}" | grep -nF -- "$2" | head -n 1 | cut -d: -f1
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

# key_restored RENDER [FILE]: whether FILE, rebuild.md by default, brings the secret key of each AWX
# of lab-sto2 in the render RENDER back with the secret store, before its database: the AWX names the
# Secret of its key in secret_key_secret; one ExternalSecret of the render writes that Secret's
# secret_key from a path of the ClusterSecretStore openbao; in "Building it again" the step "The
# secret store." names that path and Ascender, the step "The databases." comes after it, and the row
# of each database of the AWX's namespace names the secret store by its step and the path; and
# neither "What does not" nor the step "What no restore brings back." names the operator's own
# Secret of the key, <name>-secret-key, in backquotes or not. Names each AWX that fails, and why.
# shellcheck disable=SC2016 # the backquotes are Markdown's.
key_restored() {
  local render=$1 file=${2:-$REBUILD} awx namespace name secret own path store db_step database row problems=()
  store=$(step_of 'Building it again' '**The secret store.**' "$file")
  db_step=$(step_of 'Building it again' '**The databases.**' "$file")
  while IFS= read -r awx; do
    namespace=$(yq '.metadata.namespace' "$awx")
    name=$(yq '.metadata.name' "$awx")
    secret=$(yq '.spec.secret_key_secret // ""' "$awx")
    if [ -z "$secret" ]; then
      problems+=("AWX $namespace/$name: it names no Secret of the store for its secret key")
      continue
    fi
    # The operator's own Secret by its name, in backquotes or not, and not as the start or end of a
    # longer name such as the store's Secret.
    own="(^|[^[:alnum:]_-])$name-secret-key([^[:alnum:]_-]|\$)"
    path=$(find "$render/lab-sto2" -type f -name "ExternalSecret.external-secrets.io_${namespace}_*.yaml" -print0 |
      xargs -0 -r yq -N -o json -I0 '.' | jq -r --arg secret "$secret" '
        select((.spec.target.name // .metadata.name) == $secret
          and .spec.secretStoreRef == {"kind": "ClusterSecretStore", "name": "openbao"})
        | .spec.data[]? | select(.secretKey == "secret_key") | .remoteRef.key')
    if [ "$(grep -c . <<<"$path")" -ne 1 ]; then
      problems+=("AWX $namespace/$name: no one ExternalSecret writes the secret_key of its Secret $secret from the store")
      continue
    fi
    if [ -z "$store" ]; then
      problems+=("AWX $namespace/$name: the runbook has no step The secret store.")
      continue
    fi
    steps 'Building it again' "$file" | sed -n "${store}p" | grep -qF -- "\`$path\`" ||
      problems+=("AWX $namespace/$name: the step The secret store. does not name $path")
    steps 'Building it again' "$file" | sed -n "${store}p" | grep -qF -- 'Ascender' ||
      problems+=("AWX $namespace/$name: the step The secret store. does not name Ascender")
    [ -n "$db_step" ] && ((db_step > store)) ||
      problems+=("AWX $namespace/$name: the step The databases. does not come after The secret store.")
    while IFS= read -r database; do
      row=$(rows "$file" | awk -F'\t' -v db="$database" '$1 == db { print $2 }')
      [[ $row == *"secret store (step $store)"* && $row == *"\`$path\`"* ]] ||
        problems+=("AWX $namespace/$name: the row of $database does not name the secret store (step $store) and $path")
    done < <(databases "$render" | grep "^$namespace/")
    ! section 'What does not' "$file" | grep -qE -- "$own" ||
      problems+=("AWX $namespace/$name: What does not names $name-secret-key")
    ! steps 'Building it again' "$file" | grep -F -- '**What no restore brings back.**' | grep -qE -- "$own" ||
      problems+=("AWX $namespace/$name: the step What no restore brings back. names $name-secret-key")
  done < <(find "$render/lab-sto2" -type f -name 'AWX.awx.ansible.com_*.yaml' | LC_ALL=C sort)
  ((${#problems[@]} == 0)) || { printf '%s\n' "${problems[@]}"; return 1; }
}

# real_render: the render of this repository's tree, charts pulled, in $BATS_FILE_TMPDIR/render.
# The tests of one file run side by side, so each that finds no render yet makes one in a directory
# of its own, and the first to finish gives the file its render.
real_render() {
  REAL="$BATS_FILE_TMPDIR/render"
  if [ ! -d "$REAL" ]; then
    local partial="$REAL.partial.$BATS_TEST_NUMBER"
    "$REPO/scripts/render" "$partial" >/dev/null
    mv -T "$partial" "$REAL" 2>/dev/null || [ -d "$REAL" ]
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

# shellcheck disable=SC2016 # the backquotes are Markdown's.
@test "The runbooks take the records out after the last copies and before the cluster and the edge stack go" {
  local copies remove destroy stacks way edge
  copies=$(step_holds 'Taking it down' '`just cluster-last-copies <openbao file> <volsync file> <postgres file>`')
  remove=$(step_holds 'Taking it down' '`just cluster-dns-remove`' '`just cluster-dns-remove --check`' 'ExternalDNSSyncStale')
  destroy=$(step_holds 'Taking it down' '`just cluster-destroy`')
  stacks=$(step_holds 'Taking it down' '`just infra-destroy sto2/plumbing`' '`just infra-destroy sto2/edge`' \
    '`just infra-destroy sto2/ci`' '`just infra-destroy sto2/edge --check`')
  echo "steps: the last copies $copies, the removal $remove, the cluster's destroy $destroy, the stacks' $stacks"
  ((copies < remove && remove < destroy && destroy < stacks))
  # The edge routers' way back takes the records out while the cluster runs, before the edge stack.
  way=$(section 'The way back' "$RUNBOOKS/edge.md")
  remove=$(grep -nF '`just cluster-dns-remove`' <<<"$way" | head -n 1 | cut -d: -f1)
  edge=$(grep -nF '`just infra-destroy sto2/edge`' <<<"$way" | head -n 1 | cut -d: -f1)
  echo "edge.md, The way back: the removal on line $remove, the edge stack's destroy on line $edge"
  [ -n "$remove" ] && [ -n "$edge" ]
  ((remove < edge))
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

@test "The rebuild runbook brings Ascender's secret key back with the secret store, before Ascender's database" {
  local copy="$BATS_TEST_TMPDIR/render" awx
  real_render
  # The render holds Ascender's AWX, so a render that finds none cannot pass.
  awx=$(find "$REAL/lab-sto2" -type f -name 'AWX.awx.ansible.com_*.yaml')
  echo "the render's AWX: ${awx#"$REAL/"}, its secret key's Secret: $(yq '.spec.secret_key_secret // "none"' "$awx")"
  [ "${awx##*/}" = AWX.awx.ansible.com_ascender_ascender.yaml ]
  run key_restored "$REAL"
  echo "$output"
  [ "$status" -eq 0 ]
  # A render whose AWX names no Secret of the store fails, naming it.
  cp -R "$REAL" "$copy"
  yq -i 'del(.spec.secret_key_secret)' "$copy/${awx#"$REAL/"}"
  run key_restored "$copy"
  echo "$output"
  [ "$status" -ne 0 ]
  [ "$output" = "AWX ascender/ascender: it names no Secret of the store for its secret key" ]
  # A runbook that names the operator's own Secret of the key as lost, in "What does not" and in the
  # step What no restore brings back., without backquotes, fails, naming both.
  awk '{ print } $0 == "## What does not" { print ""; print "- Ascender'\''s ascender-secret-key, which no backup holds." }
    /^8\. \*\*What no restore brings back\.\*\*/ { print "   Ascender'\''s ascender-secret-key is lost." }' "$REBUILD" >"$BATS_TEST_TMPDIR/rebuild.md"
  run key_restored "$REAL" "$BATS_TEST_TMPDIR/rebuild.md"
  echo "$output"
  [ "$status" -ne 0 ]
  [ "$output" = "$(printf '%s\n' 'AWX ascender/ascender: What does not names ascender-secret-key' \
    'AWX ascender/ascender: the step What no restore brings back. names ascender-secret-key')" ]
}
