#!/usr/bin/env bats
# Proves the two restore scenarios of features/postgresql.feature; each test carries its scenario's
# title. Both restores of docs/runbooks/postgres-restore.md are made for every database the
# cluster's overlay builds, as the runbook says their pull requests make them, on a copy of what git
# would commit here, in a repository of its own, and the copy is held to the checks a pull request
# runs. The checks run side by side, the test files' on clones of the copy, and so do the flows
# evaluated, one process each, on every processor.
# Needs git, helm, flux, kustomize, kubeconform, kyverno, yq, jq, just, bats, xargs and getconf on
# PATH (the versions pinned for the repository where they are pinned). Charts are pulled from their
# public registries, the render's once, with Helm's and Docker's settings in the run's own directory;
# everything else is offline.

# The two tests share one copy and one render, made by whichever of them runs first.
export BATS_NO_PARALLELIZE_WITHIN_FILE=true

load fixtures/schema-problems

setup_file() {
  # Helm's cache and registry settings stay in the run's own directory, and so does the Docker
  # configuration helm falls back to for credentials, so no login is read; the checks and the tests
  # run on the copy inherit them.
  export HELM_CACHE_HOME="$BATS_FILE_TMPDIR/helm/cache"
  export HELM_CONFIG_HOME="$BATS_FILE_TMPDIR/helm/config"
  export HELM_DATA_HOME="$BATS_FILE_TMPDIR/helm/data"
  export DOCKER_CONFIG="$BATS_FILE_TMPDIR/docker"
  mkdir -p "$DOCKER_CONFIG"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  COPY="$BATS_FILE_TMPDIR/copy"
  RENDER="$BATS_FILE_TMPDIR/render"
  VIEW="$BATS_FILE_TMPDIR/view"
  # One line per database: its Kustomization, its path, and its CNPG_CLUSTER_NAME, CNPG_NAMESPACE
  # and CNPG_STORAGE_SIZE; one per Cluster a restore added: its database's Kustomization, the
  # namespace, the old cluster, the new one, the restore (point-in-time or dump) and its file.
  DATABASES="$BATS_FILE_TMPDIR/databases.tsv"
  RESTORES="$BATS_FILE_TMPDIR/restores.tsv"
  # One line per restore of a database whose Cluster names its owner's Secret: its Kustomization,
  # the namespace, the old cluster, the new one, the restore, that Secret and the file of its copy.
  OWNERS="$BATS_FILE_TMPDIR/owners.tsv"
  # The charts the first render pulls, which the renders after it take instead of pulling them again.
  CHARTS="$BATS_FILE_TMPDIR/charts"
  # The output and the exit status of each check that background starts.
  JOBS="$BATS_TEST_TMPDIR/jobs"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
  # No configuration of this machine's git reaches the copy's repository.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
}

# A test that stops at a failure leaves nothing running: the checks it started end first.
teardown() {
  wait
}

# runbook_clusters DIR: the fenced YAML and shell blocks of the restore runbook, whatever list item
# each is indented in, as DIR/block-N.yaml and DIR/block-N.sh, the YAML as tests/postgresql.bats
# reads it; then PITR, the one YAML block that is a Cluster bootstrapped by recovery, the
# point-in-time restore's, and DUMP, the one bootstrapped by initdb, the dump restore's. Fails unless
# there is exactly one of each.
runbook_clusters() {
  local dir=$1 block
  local -a recovery=() initdb=()
  rm -rf "$dir"
  mkdir -p "$dir"
  awk -v dir="$dir" '/^ *```(yaml|sh)$/ { inside = 1; block++; match($0, /^ */); indent = RLENGTH; kind = substr($0, indent + 4); next }
    /^ *```$/ { inside = 0; next } inside { print substr($0, indent + 1) > (dir "/block-" block "." kind) }' \
    "$REPO/docs/runbooks/postgres-restore.md"
  for block in "$dir"/block-*.yaml; do
    [ -f "$block" ] && [ "$(yq '.kind' "$block")" = Cluster ] || continue
    case "$(yq '.spec.bootstrap // {} | keys | join(",")' "$block")" in
      recovery) recovery+=("$block") ;;
      initdb) initdb+=("$block") ;;
    esac
  done
  [ "${#recovery[@]}" -eq 1 ] || { echo "the restore runbook has ${#recovery[@]} Cluster blocks that bootstrap by recovery, not one"; return 1; }
  [ "${#initdb[@]}" -eq 1 ] || { echo "the restore runbook has ${#initdb[@]} Cluster blocks that bootstrap by initdb, not one: the dump restore's Cluster"; return 1; }
  PITR=${recovery[0]} DUMP=${initdb[0]}
}

# runbook_steps DIR: of the blocks runbook_clusters wrote to DIR, what a restore's pull request adds
# beside its Cluster: ROW, the one shell block that adds a row to .renovate/by-hand.tsv, for the
# image of the point-in-time restore's file; SUSPEND, the one YAML block of patches of a CronJob,
# with which the dump restore's suspends the old cluster's dump job; and OWNER, the one YAML block
# of a Password and an ExternalSecret, Ascender's copy of its owner's Secret, for the new cluster
# where it says <name>. Fails, naming each that is not there exactly once.
runbook_steps() {
  local dir=$1 block missing=""
  local -a rows=() suspends=() owners=()
  for block in "$dir"/block-*.sh; do
    [ -f "$block" ] && grep -q '\.renovate/by-hand\.tsv' "$block" && rows+=("$block")
  done
  for block in "$dir"/block-*.yaml; do
    [ -f "$block" ] || continue
    [ "$(yq 'select(tag == "!!map") | [(.patches // [])[] | .target.kind] | unique | join(",")' "$block")" != CronJob ] ||
      suspends+=("$block")
    [ "$(yq -N '.kind' "$block" | sort | paste -sd, -)" != ExternalSecret,Password ] || owners+=("$block")
  done
  [ "${#rows[@]}" -eq 1 ] || missing+="the restore runbook has ${#rows[@]} shell blocks that add a row to .renovate/by-hand.tsv, not one: the row of a restore's file"$'\n'
  [ "${#suspends[@]}" -eq 1 ] || missing+="the restore runbook has ${#suspends[@]} YAML blocks of patches of a CronJob, not one: the dump restore's suspension of the old cluster's dump job"$'\n'
  [ "${#owners[@]}" -eq 1 ] || missing+="the restore runbook has ${#owners[@]} YAML blocks of a Password and an ExternalSecret, not one: Ascender's copy of its owner's Secret"$'\n'
  [ -z "$missing" ] || { printf '%s' "$missing"; return 1; }
  ROW=${rows[0]} SUSPEND=${suspends[0]} OWNER=${owners[0]}
}

# owner_copy NAME: the runbook's copy of an owner's Secret, OWNER, for the cluster NAME, as the
# runbook says to make it: NAME in place of each <name>.
owner_copy() {
  local text
  text="$(<"$OWNER")"
  printf '%s\n' "${text//<name>/$1}"
}

# example_of PITR: the runbook's example database, whose archive its point-in-time Cluster reads.
example_of() {
  # shellcheck disable=SC2016 # $source is a yq variable.
  yq '.spec.bootstrap.recovery.source as $source | .spec.externalClusters[] | select(.name == $source) | .plugin.parameters.serverName' "$1"
}

# restore_cluster BLOCK EXAMPLE OLD SIZE IMAGE: the runbook's Cluster BLOCK for the database OLD, as
# runbook_cluster in tests/ascender.bats makes it: every string that begins with the example's name
# begins with OLD's, and the image is the component's in place of the placeholder; and its size is
# the old cluster's, as the runbook says.
restore_cluster() {
  EXAMPLE="$2" OLD="$3" SIZE="$4" IMAGE="$5" yq '(.. | select(tag == "!!str")) |= sub("^" + strenv(EXAMPLE); strenv(OLD))
    | .spec.imageName = strenv(IMAGE) | .spec.storage.size = strenv(SIZE)' "$1"
}

# owner_secret PARTIAL KS PATH OLD OVERLAY: the Secret that the Cluster OLD, as Flux builds the
# Kustomization KS of the overlay in the tree PARTIAL, names as its owner's in bootstrap.initdb, or
# nothing where it names none and the operator makes the application Secret itself.
owner_secret() {
  local ks_file="$BATS_FILE_TMPDIR/$2-ks.yaml" built="$BATS_FILE_TMPDIR/$2-built.yaml"
  KS="$2" yq 'select(.kind == "Kustomization" and .metadata.name == strenv(KS))' <<<"$5" >"$ks_file"
  (cd "$1" && flux build kustomization "$2" --path "./kubernetes/${3#./}" --kustomization-file "$ks_file" --dry-run --in-memory-build) >"$built" ||
    { echo "flux does not build $2" >&2; return 1; }
  [ "$(OLD="$4" yq -N 'select(.kind == "Cluster" and .metadata.name == strenv(OLD)) | .metadata.name' "$built")" = "$4" ] ||
    { echo "$2 builds no one Cluster $4" >&2; return 1; }
  OLD="$4" yq -N 'select(.kind == "Cluster" and .metadata.name == strenv(OLD)) | .spec.bootstrap.initdb.secret.name // ""' "$built"
}

# owner_source PARTIAL NAMESPACE SECRET OVERLAY: the one file of an application of the overlay in
# NAMESPACE that holds the ExternalSecret SECRET and its Password generator, as Ascender's
# database-secret.yaml holds ascender-db-app's.
owner_source() {
  local app each
  local -a found=()
  while IFS= read -r app; do
    for each in "$1/kubernetes/${app#./}"/*.yaml; do
      [ -f "$each" ] || continue
      [ "$(SECRET="$3" yq -N 'select((.kind == "ExternalSecret" or .kind == "Password") and .metadata.name == strenv(SECRET)) | .kind' "$each" | sort | paste -sd, -)" \
        = ExternalSecret,Password ] && found+=("$each")
    done
  done < <(NS="$2" yq -N 'select(.kind == "Kustomization" and .spec.targetNamespace == strenv(NS)) | .spec.path' <<<"$4")
  [ "${#found[@]}" -eq 1 ] || { echo "the applications of $2 hold the ExternalSecret $3 and its Password in ${#found[@]} files, not one" >&2; return 1; }
  echo "${found[0]}"
}

# restored: the copy, made once for the file: what git would commit from this checkout, in COPY,
# with both of the runbook's restores made for every database of its overlay as their pull requests
# make them: each Cluster as a file of the application's own app/ named for it, listed in its
# kustomization.yaml, with its row of .renovate/by-hand.tsv, and the dump restore's suspension of
# the old cluster's dump job; and, for a database whose Cluster names its owner's Secret, as
# Ascender's does, the Cluster naming NEW-app instead, and the runbook's copy of that Secret's
# Password and ExternalSecret for NEW as NEW-app.yaml beside them, listed in their
# kustomization.yaml, once the runbook's copy for the old cluster is shown to be the tree's two
# objects; then committed, unsigned, as the one commit of a repository with no remote. Writes
# DATABASES, RESTORES and OWNERS.
restored() {
  local partial="$COPY.partial" path overlay default image example example_file row ks dir old namespace size kind block new file
  local secret source host copy mine theirs
  [ ! -d "$COPY" ] || return 0
  rm -rf "$partial"
  mkdir -p "$partial"
  while IFS= read -r -d '' path; do
    # A file deleted here but still in the index has nothing to copy.
    [[ -e $REPO/$path || -L $REPO/$path ]] || continue
    mkdir -p -- "$partial/$(dirname -- "$path")"
    cp -pP -- "$REPO/$path" "$partial/$path"
  done < <(git -C "$REPO" ls-files -z --cached --others --exclude-standard)
  # The databases, from the copy's overlay as Flux reads it: every Kustomization that takes the
  # component, with the size the component gives an instance's volume when it sets none.
  overlay="$(kustomize build --load-restrictor LoadRestrictionsNone "$partial/kubernetes/apps/overlays/lab-sto2")"
  default="$(sed -nE 's/^ *size: \$\{CNPG_STORAGE_SIZE:=([^}]+)\}$/\1/p' "$partial/kubernetes/components/cnpg-cluster/cluster.yaml")"
  [ -n "$default" ] || { echo "the component's Cluster gives no default CNPG_STORAGE_SIZE"; return 1; }
  # shellcheck disable=SC2016 # $s is a yq variable.
  DEFAULT="$default" yq -N 'select(.kind == "Kustomization" and ((.spec.components // []) | any_c(test("/components/cnpg-cluster$"))))
    | (.spec.postBuild.substitute // {}) as $s
    | [.metadata.name, .spec.path, $s.CNPG_CLUSTER_NAME // "", $s.CNPG_NAMESPACE // "", $s.CNPG_STORAGE_SIZE // strenv(DEFAULT)] | @tsv' \
    <<<"$overlay" | { grep . || true; } >"$DATABASES"
  echo "the databases the overlay builds (Kustomization, path, cluster, namespace, size):"
  cat "$DATABASES"
  [ -s "$DATABASES" ] || { echo "the overlay builds no database"; return 1; }
  runbook_clusters "$BATS_FILE_TMPDIR/runbook"
  runbook_steps "$BATS_FILE_TMPDIR/runbook"
  example="$(example_of "$PITR")"
  image="$(yq '.spec.imageName' "$partial/kubernetes/components/cnpg-cluster/cluster.yaml")"
  # The row's block names the file of the point-in-time restore's example, which each restore's own
  # file takes the place of.
  example_file="$(awk -F'\t' -v example="$example" '$3 == example { print $2 }' "$DATABASES")"
  example_file="kubernetes/${example_file#./}/$(yq '.metadata.name' "$PITR").yaml"
  [ "$(grep -cF -- "$example_file" "$ROW")" -eq 1 ] || { echo "the runbook's row of .renovate/by-hand.tsv does not name $example_file once"; return 1; }
  : >"$RESTORES"
  : >"$OWNERS"
  while IFS=$'\t' read -r ks path old namespace size; do
    [ -n "$old" ] && [ -n "$namespace" ] || { echo "$ks takes the component without a cluster's name or namespace"; return 1; }
    dir="$partial/kubernetes/${path#./}"
    secret="$(owner_secret "$partial" "$ks" "$path" "$old" "$overlay")" || return 1
    source=""
    if [ -n "$secret" ]; then
      source="$(owner_source "$partial" "$namespace" "$secret" "$overlay")" || return 1
      host="$(SECRET="$secret" yq -N 'select(.kind == "ExternalSecret" and .metadata.name == strenv(SECRET)) | .spec.target.template.data.host // ""' "$source")"
      [ "$host" = "$old-rw" ] || { echo "the ExternalSecret $secret writes the host ${host:-none}, not $old-rw"; return 1; }
      # The runbook's copy, made for the old cluster, is the tree's Password and ExternalSecret field
      # for field, so that a copy made from it for a new cluster differs from them by that name
      # alone.
      mine="$(owner_copy "$old" | yq -N -o json -I0 '.' | jq -cS . | sort)"
      theirs="$(SECRET="$secret" yq -N -o json -I0 'select((.kind == "Password" or .kind == "ExternalSecret") and .metadata.name == strenv(SECRET))' "$source" | jq -cS . | sort)"
      [ "$mine" = "$theirs" ] ||
        { echo "the runbook's copy of an owner's Secret, made for $old, is not the Password and the ExternalSecret $secret of ${source#"$partial"/}:"; diff <(echo "$mine") <(echo "$theirs") || true; return 1; }
    fi
    for kind in point-in-time dump; do
      block=$PITR
      [ "$kind" = point-in-time ] || block=$DUMP
      new="$(restore_cluster "$block" "$example" "$old" "$size" "$image" | yq '.metadata.name')"
      [ "$new" != "$old" ] || { echo "the runbook's $kind Cluster, for $old, is named $old"; return 1; }
      file="$new.yaml"
      [ ! -e "$dir/$file" ] || { echo "$dir already holds $file"; return 1; }
      restore_cluster "$block" "$example" "$old" "$size" "$image" >"$dir/$file"
      FILE="$file" yq -i '.resources += [strenv(FILE)]' "$dir/kustomization.yaml"
      row="$(<"$ROW")"
      (cd "$partial" && bash -euo pipefail -c "${row//"$example_file"/"kubernetes/${path#./}/$file"}")
      if [ "$kind" = dump ]; then
        SUSPEND="$SUSPEND" yq -i '.patches += load(strenv(SUSPEND)).patches' "$dir/kustomization.yaml"
      fi
      if [ -n "$secret" ]; then
        copy="$(dirname "$source")/$new-app.yaml"
        [ ! -e "$copy" ] || { echo "$copy already exists"; return 1; }
        COPY="$new-app" yq -i '.spec.bootstrap[].secret.name = strenv(COPY)' "$dir/$file"
        owner_copy "$new" >"$copy"
        FILE="$new-app.yaml" yq -i '.resources += [strenv(FILE)]' "$(dirname "$source")/kustomization.yaml"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ks" "$namespace" "$old" "$new" "$kind" "$secret" "${copy#"$partial"/}" >>"$OWNERS"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ks" "$namespace" "$old" "$new" "$kind" "kubernetes/${path#./}/$file" >>"$RESTORES"
    done
  done <"$DATABASES"
  echo "the restores added (Kustomization, namespace, old cluster, new cluster, restore, file):"
  cat "$RESTORES"
  echo "the copies of an owner's Secret added (Kustomization, namespace, old cluster, new cluster, restore, Secret, file):"
  cat "$OWNERS"
  git -C "$partial" init -q -b main
  git -C "$partial" add -A
  git -C "$partial" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
    commit -q -m "add both restores of every database"
  mv "$partial" "$COPY"
}

# rendered: the render of the copy, made once for the file, as scripts/render makes it, with the
# charts it pulls kept in CHARTS, and VIEW, the files of it that the evaluation of a flow reads (the
# namespaces, the workloads, the Gateways and the policies), which it reads fast.
rendered() {
  restored
  if [ ! -d "$RENDER" ]; then
    rm -rf "$RENDER.partial"
    RENDER_CHART_CACHE="$CHARTS" "$COPY/scripts/render" "$RENDER.partial" "$COPY" >/dev/null
    mv "$RENDER.partial" "$RENDER"
  fi
  if [ ! -d "$VIEW" ]; then
    rm -rf "$VIEW.partial"
    mkdir -p "$VIEW.partial"
    (cd "$RENDER" && find . -type f \( -name 'Namespace_*' -o -name 'Deployment.apps_*' -o -name 'StatefulSet.apps_*' \
      -o -name 'DaemonSet.apps_*' -o -name 'Job.batch_*' -o -name 'CronJob.batch_*' -o -name 'Pod_*' \
      -o -name 'Gateway.gateway.networking.k8s.io_*' -o -name 'NetworkPolicy.*' -o -name 'CiliumNetworkPolicy.*' \
      -o -name 'CiliumClusterwideNetworkPolicy.*' \) -exec cp --parents {} "$VIEW.partial/" \;)
    mv "$VIEW.partial" "$VIEW"
  fi
}

# regex TEXT: TEXT as an extended regular expression that matches it alone.
regex() {
  printf '%s' "$1" | sed -E 's/[][\\.^$*+?(){}|]/\\&/g'
}

# nested FILE TITLE...: runs, in one process, the tests of the copy's tests/FILE that carry exactly
# these titles, with the mise of the pinned tools trusting the copy alone, and fails unless each
# title is the name of one test of the file and the run planned and passed every one of them. The
# tests run on a clone of the copy of their own, the same commit and files, as some of them build
# with a flux build that rewrites a kustomization.yaml of the tree while it runs, and the checks
# beside them read the copy.
nested() {
  local file=$1 title count re="" start clone
  shift
  for title in "$@"; do
    count="$(bats --count -f "^$(regex "$title")\$" "$COPY/tests/$file")"
    [ "$count" -eq 1 ] || { echo "$file: \"$title\" is the title of $count tests, not one"; return 1; }
    re+="${re:+|}$(regex "$title")"
  done
  mkdir -p "$BATS_TEST_TMPDIR/clones"
  clone="$(mktemp -d "$BATS_TEST_TMPDIR/clones/XXXXXX")"
  cp -a "$COPY/." "$clone"
  [ "$(git -C "$clone" rev-parse HEAD)" = "$(git -C "$COPY" rev-parse HEAD)" ] && [ -z "$(git -C "$clone" status --porcelain)" ] ||
    { echo "the clone of the copy for $file is not the copy's commit"; return 1; }
  mkdir -p "$clone.tmp"
  start=$SECONDS
  run env MISE_TRUSTED_CONFIG_PATHS="$clone" TMPDIR="$clone.tmp" bats -f "^($re)\$" "$clone/tests/$file"
  echo "$file, $(( SECONDS - start ))s:"
  grep -E '^(1\.\.|ok |not ok )' <<<"$output" || true
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx "1\.\.$#" <<<"$output" || { echo "$file planned other than its $# tests"; return 1; }
  [ "$(grep -cE '^ok ' <<<"$output")" -eq "$#" ] || { echo "$file ran fewer than its $# tests"; return 1; }
}

# background NAME COMMAND...: starts COMMAND, a program or a function of this file, beside the test
# and the other checks, its output and its exit status kept under NAME for finished.
background() {
  local name=$1
  shift
  mkdir -p "$JOBS"
  echo "$name" >>"$JOBS/order"
  (
    trap - ERR DEBUG
    set +eE
    start=$SECONDS
    "$@" >"$JOBS/$name.log" 2>&1
    echo "$? $((SECONDS - start))" >"$JOBS/$name.status"
  ) 3>&- &
}

# charted COMMAND...: COMMAND, a program or a function of this file, with the renders it makes taking
# the charts the copy's render pulled, the same charts at the same versions, instead of pulling them
# again; for a check that background starts once the copy is rendered, as two renders writing one
# chart there at once could read it half written.
charted() {
  export RENDER_CHART_CACHE="$CHARTS"
  "$@"
}

# finished: waits for every check background started, then prints each, in the order they were
# started, with its exit status, its time and the last line of its output, or all of it for a test
# file's run or a check that failed; fails naming those that failed.
finished() {
  local name status took
  local -a failed=()
  wait
  while IFS= read -r name; do
    read -r status took <"$JOBS/$name.status" || status=unknown
    echo "$name: exit $status, ${took:-?}s"
    if [ "$status" != 0 ] || [[ $name == *.bats* ]]; then
      sed 's/^/  /' "$JOBS/$name.log"
    else
      tail -n 1 "$JOBS/$name.log" | sed 's/^/  /'
    fi
    [ "$status" = 0 ] || failed+=("$name")
  done <"$JOBS/order"
  [ "${#failed[@]}" -eq 0 ] || { echo "the copy fails: ${failed[*]}"; return 1; }
}

@test "Each restore of the runbook adds its new cluster beside every database the overlay builds, and the copy passes the checks of a pull request" {
  local example component shape problems ks namespace old new kind file found paths check line secret
  local -a copies=()
  restored
  # The dump restore's Cluster is the point-in-time restore's, the same image, sizes, placement and
  # archiver, with an initdb of the database app owned by app in place of the recovery and no
  # external cluster to recover from.
  runbook_clusters "$BATS_TEST_TMPDIR/runbook"
  example="$(example_of "$PITR")"
  shape='del(.metadata.name, .spec.bootstrap, .spec.externalClusters)
    | (.spec.plugins[]? | select(.isWALArchiver == true) | .parameters) |= del(.serverName)'
  echo "the point-in-time Cluster, its bootstrap and its archive aside: $(yq -o json -I0 "$shape" "$PITR")"
  echo "the dump restore's: $(yq -o json -I0 "$shape" "$DUMP")"
  [ "$(yq -o json -I0 "$shape" "$DUMP" | jq -cS .)" = "$(yq -o json -I0 "$shape" "$PITR" | jq -cS .)" ]
  [ "$(yq -o json -I0 '.spec.bootstrap' "$DUMP" | jq -cS .)" = '{"initdb":{"database":"app","owner":"app"}}' ]
  [ "$(yq '.spec | has("externalClusters")' "$DUMP")" = false ]
  # It archives through the old cluster's ObjectStore, the one plugin entry, under its own name,
  # which is not the old cluster's: two clusters never write to one path.
  echo "the dump restore's archiver: $(yq -o json -I0 '.spec.plugins' "$DUMP"); named $(yq '.metadata.name' "$DUMP"); the example database $example"
  [ "$(yq '.spec.plugins | length' "$DUMP")" -eq 1 ]
  [ "$(yq '.spec.plugins[0] | .name + " " + (.isWALArchiver | tostring) + " " + .parameters.barmanObjectName' "$DUMP")" \
    = "barman-cloud.cloudnative-pg.io true $example" ]
  [ "$(yq '.spec.plugins[0].parameters.serverName' "$DUMP")" = "$(yq '.metadata.name' "$DUMP")" ]
  [ "$(yq '.spec.plugins[0].parameters.serverName' "$DUMP")" != "$example" ]
  # Both state the size of the example's old cluster as the overlay builds it, and the component's
  # placement and resources.
  [ "$(awk -F'\t' -v example="$example" '$3 == example { print $5 }' "$DATABASES")" = "$(yq '.spec.storage.size' "$PITR")" ] ||
    { echo "the runbook's point-in-time Cluster is $(yq '.spec.storage.size' "$PITR"), not the size of $example"; return 1; }
  [ "$(yq '.spec.storage.size' "$DUMP")" = "$(yq '.spec.storage.size' "$PITR")" ]
  component='.spec | {"instances": .instances, "storageClass": .storage.storageClass, "affinity": .affinity, "resources": .resources}'
  [ "$(yq -o json -I0 "$component" "$DUMP" | jq -cS .)" = "$(yq -o json -I0 "$component" "$COPY/kubernetes/components/cnpg-cluster/cluster.yaml" | jq -cS .)" ]

  # The copy passes what the pull request's checks run. They run side by side, as none of them writes
  # to the copy, and finished reports each once all have ended, so that one run shows every one that
  # fails. First those of the static group that read the files a restore adds: the address literals
  # and the conflict markers of the files git would commit, the YAML half of just lint, its line run
  # as the copy's recipe has it (the other half lints the scripts and the bats files), the version
  # pins, each one Renovate moves or .renovate/by-hand.tsv lists, the sources' signature rows and the
  # secrets scan. Of the group's other checks, renovate-check runs Renovate's extraction in
  # Renovate's image, which finds nothing in a restore's files: no line of them is under a
  # "# renovate:" comment, and its kubernetes manager reads image: lines alone, not imageName:
  # (lib/modules/manager/kubernetes/extract.ts of the Renovate the justfile pins);
  # kubernetes-validate fetches the schemas, and the new Clusters are held to the pinned operator's
  # below; the rest read none of these files.
  line="$(env MISE_TRUSTED_CONFIG_PATHS="$COPY" just --justfile "$COPY/justfile" --show lint | sed -n 's/^ *\(.* yamllint\)$/\1/p')"
  [ "$(grep -c . <<<"$line")" -eq 1 ] || { echo "the copy's lint recipe has no one line that runs yamllint"; return 1; }
  # The copy's own tests that hold a rule over every application the overlay selects or every
  # database, each by its title: the Clusters of the three databases by their component's name, the
  # volume floor and the archive paths of every Cluster of a database application, the overlay's
  # entries in the namespaces that hold a database, every application's entity, dependencies and
  # use of the component, and every pod of the render. Each runs in a process of its own, those that
  # build many trees first, as no test of the files below needs another to have run; the two of
  # pod-security.bats share their render, once the copy's own render has pulled the charts.
  background sso.bats nested sso.bats \
    "The sign-in applications are selected by overlay entries and build nothing when they are not, and nothing else waits on them"
  background applications.bats-1 nested applications.bats \
    "A cluster that does not select n8n builds none of it, and one that selects it without what it depends on is refused"
  background applications.bats-2 nested applications.bats \
    "Open WebUI is selected by one overlay entry and builds nothing when it is not"
  background backstage.bats-1 nested backstage.bats \
    "Backstage is selected by overlay entries and builds nothing when it is not"
  background ascender.bats-1 nested ascender.bats \
    "Ascender is selected by overlay entries and builds nothing when it is not"
  background postgresql.bats-1 nested postgresql.bats \
    "A cluster that does not select the backup plugin builds no database that needs it, and one that selects a database without it is refused"
  background applications.bats-3 nested applications.bats \
    "n8n's database is a PostgreSQL cluster from the template, and no credential is in the tree"
  background backstage.bats-2 nested backstage.bats \
    "The catalogue holds exactly one entity for every application the overlay selects, and every entity's links and dependencies exist in the tree"
  background backstage.bats-3 nested backstage.bats \
    "The catalogue's dependencies are regenerated from the Kustomizations"
  background backstage.bats-4 nested backstage.bats \
    "Backstage's pod meets the restricted level with a read-only root and only the writable mounts it needs, and its database comes from the PostgreSQL component"
  background ascender.bats-2 nested ascender.bats \
    "Ascender's database comes from the PostgreSQL component, and no secret is in the tree"
  background postgresql.bats-2 nested postgresql.bats \
    "A PostgreSQL cluster from the component archives its WAL and takes a daily base backup to a path of its own in the object store"
  background postgresql.bats-3 nested postgresql.bats \
    "Every database's volume has room for its data and the WAL its primary keeps while the archive is down, and grows in place"
  background postgresql.bats-4 nested postgresql.bats "Two databases never share a backup path"
  background postgresql.bats-5 nested postgresql.bats \
    "Two databases never share a backup path, whatever namespace an application names"
  background alert-routes.bats nested alert-routes.bats \
    "The destinations are one Secret from the store, selected by one overlay entry, and nothing waits for it"
  background open-feature-operator.bats nested open-feature-operator.bats \
    "No workload opts in, and the worked example builds without being applied"
  background kubernetes-check "$COPY/scripts/kubernetes-check" "$COPY"
  for check in check-literals check-conflict-markers renovate-pins signatures-check secrets-scan; do
    background "$check" env MISE_TRUSTED_CONFIG_PATHS="$COPY" just --justfile "$COPY/justfile" "$check"
  done
  # shellcheck disable=SC2016 # $1 is the inner shell's.
  background lint bash -euo pipefail -c 'cd "$1" && eval "$2"' _ "$COPY" "$line"
  # shellcheck disable=SC2016 # $1 is the inner shell's.
  background scenarios-check env MISE_TRUSTED_CONFIG_PATHS="$COPY" bash -c 'cd "$1" && scripts/scenarios-check' _ "$COPY"
  rendered
  background network-policy-check "$COPY/scripts/network-policy-check" "$RENDER" "$COPY/network-policy-exceptions.yaml"
  # The copy's own recipe, through its justfile, with the pinned tools: the mise that puts them on
  # PATH trusts the copy by this variable alone, and nothing asks it to trust anything. It and the
  # tests on the tree's render render the copy again, with the charts the render above pulled.
  background pod-security-check charted env MISE_TRUSTED_CONFIG_PATHS="$COPY" \
    just --justfile "$COPY/justfile" pod-security-check
  background pod-security.bats charted nested pod-security.bats \
    "The custom resources that make an operator create pods ask for what restricted requires" \
    "The tree passes"
  # Every Cluster a restore added is in the render, in the application's own build, one the pinned
  # operator defines, and archives where no other Cluster of the render does.
  yq -N -o json 'select(.kind == "CustomResourceDefinition" and .metadata.name == "clusters.postgresql.cnpg.io")
    | .spec.versions[] | select(.name == "v1") | .schema.openAPIV3Schema' "$RENDER"/*/*/CustomResourceDefinition.apiextensions.k8s.io__clusters.postgresql.cnpg.io.yaml \
    >"$BATS_TEST_TMPDIR/cluster-schema.json"
  [ -s "$BATS_TEST_TMPDIR/cluster-schema.json" ]
  while IFS=$'\t' read -r ks namespace old new kind file; do
    found=("$RENDER"/*/"$ks/Cluster.postgresql.cnpg.io_${namespace}_$new.yaml")
    [ -f "${found[0]}" ] || { echo "the render holds no Cluster $namespace/$new in $ks"; return 1; }
    yq -o json '.' "${found[0]}" >"$BATS_TEST_TMPDIR/$new.json"
    problems="$(schema_problems "$BATS_TEST_TMPDIR/cluster-schema.json" "$BATS_TEST_TMPDIR/$new.json")"
    echo "$ks: the $kind restore's Cluster $new, beside $old: ${problems:-no field the operator does not define}"
    [ -z "$problems" ]
  done <"$RESTORES"
  # Where the old Cluster names its owner's Secret, each new one names the restore's copy of it, which
  # the render holds as a Password and an ExternalSecret of the new name that writes the new
  # cluster's host.
  while IFS=$'\t' read -r ks namespace old new kind secret file; do
    found=("$RENDER"/*/"$ks/Cluster.postgresql.cnpg.io_${namespace}_$new.yaml")
    copies=("$RENDER"/*/*/"ExternalSecret.external-secrets.io_${namespace}_$new-app.yaml")
    [ -f "${copies[0]}" ] && [ -f "$(dirname "${copies[0]}")/Password.generators.external-secrets.io_${namespace}_$new-app.yaml" ] ||
      { echo "the render holds no Password and ExternalSecret $namespace/$new-app from $file"; return 1; }
    echo "$ks: the $kind restore's $new names $(yq -o json -I0 '.spec.bootstrap' "${found[0]}"), a copy of $secret that writes the host $(yq '.spec.target.template.data.host' "${copies[0]}")"
    [ "$(yq '.spec.bootstrap[].secret.name' "${found[0]}")" = "$new-app" ]
    [ "$(yq '.spec.target.template.data.host' "${copies[0]}")" = "$new-rw" ]
  done <"$OWNERS"
  # shellcheck disable=SC2016 # $c and $store are jq variables.
  paths="$(yq -N -o json -I0 'select(.kind == "Cluster" or .kind == "ObjectStore")' "$RENDER"/*/*/Cluster.postgresql.cnpg.io_*.yaml \
    "$RENDER"/*/*/ObjectStore.barmancloud.cnpg.io_*.yaml | jq -rs '. as $all | .[] | select(.kind == "Cluster") | . as $c
      | ($c.spec.plugins[] | select(.isWALArchiver == true) | .parameters) as $p
      | ([$all[] | select(.kind == "ObjectStore" and .metadata.namespace == $c.metadata.namespace and .metadata.name == $p.barmanObjectName)][0]) as $store
      | "\($c.metadata.namespace)/\($c.metadata.name) \(if $store == null then "none" else $store.spec.configuration.destinationPath + "/" + $p.serverName end)"')"
  echo "archives: $paths"
  [ "$(grep -c ' none$' <<<"$paths" || true)" -eq 0 ]
  [ "$(cut -d' ' -f2 <<<"$paths" | sort | uniq -d | wc -l)" -eq 0 ]
  [ "$(grep -c . <<<"$paths")" -eq "$(( $(grep -c . "$DATABASES") + $(grep -c . "$RESTORES") ))" ]
  # The dump restore's pull request suspends the old cluster's dump job in the tree, where Flux keeps
  # it, so that the job does not rotate the dumps out while the restore goes on: the copy holds a dump
  # restore of every database.
  while IFS=$'\t' read -r ks _ old namespace _; do
    found=("$RENDER"/*/"$ks/CronJob.batch_${namespace}_$old-pgdump.yaml")
    [ -f "${found[0]}" ] || { echo "the render holds no CronJob $namespace/$old-pgdump in $ks"; return 1; }
    # A boolean, as the API server takes no other value for the field.
    echo "$ks: $old-pgdump suspended: $(yq '(.spec.suspend | tag) + " " + (.spec.suspend | tostring)' "${found[0]}")"
    [ "$(yq '(.spec.suspend | tag) + " " + (.spec.suspend | tostring)' "${found[0]}")" = '!!bool true' ]
  done <"$DATABASES"
  finished
}

# evaluate LINE...: for each LINE of a flow, as answers takes it after its number, the first word of
# what the tree's evaluator answers over VIEW, allowed or denied, or "no answer" and what it printed,
# a tab and the LINE.
evaluate() {
  local line mode from to port out status
  for line; do
    IFS=$'\t' read -r _ _ mode from to port <<<"$line"
    status=0
    out="$("$COPY/scripts/network-policy-check" "$mode" "$VIEW" "$from" "$to" "$port" 2>&1)" || status=$?
    case $status in
      0 | 1) printf '%s\t%s\n' "${out%%:*}" "$line" ;;
      *) printf 'no answer, %s\t%s\n' "$(tr '\t\n' '  ' <<<"$out")" "$line" ;;
    esac
  done
}

# answers FLOWS: each flow of the file FLOWS, a line of the answer wanted, the evaluator's mode
# (--reach for the flow, --reach-ingress for whether its destination takes it, its ingress alone),
# the source, the destination and the port, separated by tabs, after what the evaluator answers for
# it (evaluate), in FLOWS' order. Each flow is a call of its own, and the calls run side by side, a
# batch on each processor.
answers() {
  export -f evaluate
  awk '{ print NR "\t" $0 }' "$1" |
    COPY="$COPY" VIEW="$VIEW" xargs -d '\n' -n 64 -P "$(getconf _NPROCESSORS_ONLN)" bash -c 'evaluate "$@"' _ |
    sort -t $'\t' -k2,2n | cut -f1,3-
}

# pod NAMESPACE CLUSTER ROLE VERSION: the pod of the Cluster CLUSTER in that role as --reach takes it,
# by the labels the pinned operator gives it (CloudNativePG v1.30.1): every pod it makes for a
# cluster carries cnpg.io/cluster with the cluster's name, the instance's name and the
# app.kubernetes.io labels of the cluster, the PostgreSQL major as the version (pkg/specs/pods.go,
# NewInstance, and pkg/specs/jobs.go, CreatePrimaryJob); an instance carries cnpg.io/podRole instance
# and, as primary or replica, the instance role under both of its label names
# (pkg/utils/labels_annotations.go, SetInstanceRole); a job carries cnpg.io/jobRole, initdb, join or
# full-recovery (pkg/specs/jobs.go).
pod() {
  local labels="cnpg.io/cluster=$2,app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=$2,app.kubernetes.io/version=$4,app.kubernetes.io/component=database,app.kubernetes.io/managed-by=cloudnative-pg"
  case $3 in
    primary) echo "$1:$labels,cnpg.io/instanceName=$2-1,cnpg.io/podRole=instance,cnpg.io/instanceRole=primary,role=primary" ;;
    replica) echo "$1:$labels,cnpg.io/instanceName=$2-2,cnpg.io/podRole=instance,cnpg.io/instanceRole=replica,role=replica" ;;
    initdb | full-recovery) echo "$1:$labels,cnpg.io/instanceName=$2-1,cnpg.io/jobRole=$3" ;;
    join) echo "$1:$labels,cnpg.io/instanceName=$2-2,cnpg.io/jobRole=join" ;;
  esac
}

@test "A restore's new cluster in a namespace that denies traffic by default is reached and reaches what the old cluster's pods do" {
  local operator=cnpg-system/Deployment/cloudnative-pg dns='kube-system:k8s-app=kube-dns'
  local prometheus='monitoring:app.kubernetes.io/name=prometheus' other='other:app.kubernetes.io/name=app'
  local proxy='envoy-gateway-system:app.kubernetes.io/name=envoy,app.kubernetes.io/component=proxy,app.kubernetes.io/managed-by=envoy-gateway,gateway.envoyproxy.io/owning-gateway-name=public,gateway.envoyproxy.io/owning-gateway-namespace=envoy-gateway-system'
  local denying line ks path old namespace size version cluster role instance world self peer peer_namespace client got named by_value recovery port flows want mode from to
  local evaluated=0 checked=0
  local -a databases clusters clients others mismatches=()
  rendered
  # The namespaces that deny by default, as the check reads the render.
  run "$COPY/scripts/network-policy-check" "$RENDER" "$COPY/network-policy-exceptions.yaml"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  denying="$(sed -n 's/^\([a-z0-9-]*\) denies ingress and egress$/\1/p' <<<"$output")"
  # expect WANT FROM TO PORT: a flow to evaluate, whose answer must be WANT.
  flows="$BATS_TEST_TMPDIR/flows.tsv"
  : >"$flows"
  expect() {
    printf '%s\t--reach\t%s\t%s\t%s\n' "$@" >>"$flows"
  }
  # expect_taken WANT FROM TO PORT: the same for whether TO takes the flow, its ingress alone, for a
  # source whose own egress denies it whatever TO takes.
  expect_taken() {
    printf '%s\t--reach-ingress\t%s\t%s\t%s\n' "$@" >>"$flows"
  }
  mapfile -t databases <"$DATABASES"
  for line in "${databases[@]}"; do
    IFS=$'\t' read -r ks path old namespace size <<<"$line"
    grep -qx "$namespace" <<<"$denying" || { echo "$ks: $namespace does not deny by default"; continue; }
    checked=$((checked + 1))
    # Every selector of the namespace's policies that names cnpg.io/cluster, endpoint and peer, names
    # it by its existence alone: one that named the clusters it knows, the old one and those the
    # runbook's examples name, would answer every flow below as it does and miss a restore's cluster
    # of another name.
    named="$(yq -N -o json -I0 'select(.kind == "CiliumNetworkPolicy")
      | {"policy": .metadata.name, "selectors": ([.spec.endpointSelector] + [.spec.ingress[]?.fromEndpoints[]?] + [.spec.egress[]?.toEndpoints[]?])}' \
      "$VIEW"/*/*/CiliumNetworkPolicy.cilium.io_"${namespace}"_*.yaml |
      jq -c '.policy as $policy | .selectors[]
        | select(((.matchLabels // {}) | has("cnpg.io/cluster")) or any((.matchExpressions // [])[]; .key == "cnpg.io/cluster"))
        | {"policy": $policy, "selector": .}')"
    echo "$ks: $(grep -c . <<<"$named") selectors of $namespace's policies name cnpg.io/cluster"
    [ "$(grep -c . <<<"$named")" -gt 0 ]
    by_value="$(jq -c 'select(((.selector.matchLabels // {}) | has("cnpg.io/cluster"))
      or ([(.selector.matchExpressions // [])[] | select(.key == "cnpg.io/cluster")] != [{"key": "cnpg.io/cluster", "operator": "Exists"}]))' <<<"$named")"
    [ -z "$by_value" ] || { echo "$ks: selectors that name cnpg.io/cluster by other than its existence: $by_value"; return 1; }
    # The recovery job's one policy, with its reason: its one rule, to the world on the object
    # storage's port alone, as the instances' is.
    recovery="$(yq -N -o json -I0 'select(.kind == "CiliumNetworkPolicy" and .spec.endpointSelector.matchLabels["cnpg.io/jobRole"] == "full-recovery")
      | {"selector": .spec.endpointSelector, "ingress": (.spec.ingress // []), "egress": (.spec.egress // []),
        "reason": ((.metadata.annotations["k8s-gitops/network-policy-reason"] // "") != "")}' \
      "$VIEW"/*/*/CiliumNetworkPolicy.cilium.io_"${namespace}"_*.yaml | jq -cS .)"
    echo "$ks: the policies of $namespace's recovery job: ${recovery:-none}"
    [ "$recovery" = "$(jq -cS . <<<'{"selector": {"matchExpressions": [{"key": "cnpg.io/cluster", "operator": "Exists"}],
      "matchLabels": {"cnpg.io/jobRole": "full-recovery"}}, "ingress": [],
      "egress": [{"toEntities": ["world"], "toPorts": [{"ports": [{"port": "443", "protocol": "TCP"}]}]}], "reason": true}')" ]
    # The PostgreSQL major of the old cluster's image, which the operator labels every pod with.
    version="$(yq -N '.spec.imageName | sub("^.*:"; "") | sub("[.-].*$"; "")' "$RENDER"/*/"$ks/Cluster.postgresql.cnpg.io_${namespace}_$old.yaml")"
    [[ $version =~ ^[0-9]+$ ]] || { echo "$ks: no PostgreSQL major in $old's image"; return 1; }
    mapfile -t clusters < <(echo "$old"; awk -F'\t' -v ks="$ks" '$1 == ks { print $4 }' "$RESTORES")
    [ "${#clusters[@]}" -gt 1 ] || { echo "$ks: no restore was added"; return 1; }
    # The clients, from the render: the workloads of the namespace and the pods its policies select
    # by labels alone, as an operator makes pods no render holds, other than the database's own,
    # whose egress reaches the old cluster's primary on PostgreSQL's port.
    clients=()
    while IFS= read -r client; do
      [ -n "$client" ] || continue
      if "$COPY/scripts/network-policy-check" --reach-egress "$VIEW" "$client" "$(pod "$namespace" "$old" primary "$version")" 5432/tcp >/dev/null; then
        clients+=("$client")
      fi
    done < <(
      for path in "$VIEW"/*/*/{Deployment.apps,StatefulSet.apps,DaemonSet.apps,Job.batch,CronJob.batch}_"${namespace}"_*.yaml; do
        [ -f "$path" ] && yq -N '.metadata.namespace + "/" + .kind + "/" + .metadata.name' "$path"
      done
      yq -N -o json -I0 'select(.kind == "CiliumNetworkPolicy") | .spec.endpointSelector' "$VIEW"/*/*/CiliumNetworkPolicy.cilium.io_"${namespace}"_*.yaml |
        jq -r --arg ns "$namespace" 'select((keys - ["matchLabels"]) == [] and (.matchLabels | keys | any(startswith("cnpg.io/")) | not))
          | "\($ns):" + (.matchLabels | to_entries | map("\(.key)=\(.value)") | join(","))'
    )
    echo "$ks: clusters ${clusters[*]}; clients ${clients[*]:-none}"
    [ "${#clients[@]}" -gt 0 ] || { echo "$ks: no workload of $namespace reaches $old"; return 1; }
    # Another database's primary, in a namespace of its own.
    others=()
    for peer in "${databases[@]}"; do
      IFS=$'\t' read -r _ _ peer peer_namespace _ <<<"$peer"
      [ "$peer_namespace" = "$namespace" ] || others+=("$(pod "$peer_namespace" "$peer" primary "$version")")
    done
    for cluster in "${clusters[@]}"; do
      for role in primary replica initdb join full-recovery; do
        instance=denied world=denied
        case $role in
          primary | replica) instance=allowed world=allowed ;;
          full-recovery) world=allowed ;;
        esac
        self="$(pod "$namespace" "$cluster" "$role" "$version")"
        # The operator, on the status port and PostgreSQL's, and no other port; no other pod of its
        # namespace.
        expect allowed "$operator" "$self" 8000/tcp
        expect allowed "$operator" "$self" 5432/tcp
        expect denied "$operator" "$self" 9187/tcp
        expect denied cnpg-system:app.kubernetes.io/name=other "$self" 8000/tcp
        # The application's clients reach the instances, and no job, on PostgreSQL's port.
        for client in "${clients[@]}"; do
          expect "$instance" "$client" "$self" 5432/tcp
        done
        # Prometheus scrapes an instance's exporter and the kubelet probes its status port.
        expect "$instance" "$prometheus" "$self" 9187/tcp
        expect denied "$prometheus" "$self" 5432/tcp
        expect "$instance" @host "$self" 8000/tcp
        expect denied @host "$self" 5432/tcp
        # Nothing else reaches it: the proxies, another application, another database, the world;
        # and it takes no pod of the namespace that is no client, which no egress allow lets send,
        # and a client on PostgreSQL's port alone, not on the status port or the exporter's: asked of
        # its ingress alone, as the clients' own egress denies those ports whatever it takes.
        expect denied "$proxy" "$self" 5432/tcp
        expect_taken denied "$namespace:app.kubernetes.io/name=app" "$self" 5432/tcp
        for port in 8000 9187; do
          expect_taken denied "$namespace:app.kubernetes.io/name=app" "$self" "$port/tcp"
          for client in "${clients[@]}"; do
            expect_taken denied "$client" "$self" "$port/tcp"
          done
        done
        expect denied "$other" "$self" 5432/tcp
        expect denied @world "$self" 5432/tcp
        for peer in "${others[@]}"; do
          expect denied "$peer" "$self" 5432/tcp
        done
        # The pods of the old and the new clusters reach each other.
        for peer in "${clusters[@]}"; do
          [ "$peer/primary" = "$cluster/$role" ] && continue
          expect allowed "$self" "$(pod "$namespace" "$peer" primary "$version")" 5432/tcp
          expect allowed "$(pod "$namespace" "$peer" primary "$version")" "$self" 5432/tcp
        done
        # It reaches the resolver and the API server, and the world on 443 when its pod holds the
        # Barman Cloud plugin's sidecar, the instances' and the recovery job's; nothing else.
        expect allowed "$self" "$dns" 53/udp
        expect allowed "$self" "$dns" 53/tcp
        expect allowed "$self" @kube-apiserver 443/tcp
        expect allowed "$self" @kube-apiserver 6443/tcp
        expect "$world" "$self" @world 443/tcp
        expect denied "$self" @world 80/tcp
        expect denied "$self" "$other" 5432/tcp
        expect denied "$self" openbao/StatefulSet/openbao 8200/tcp
      done
    done
  done
  [ "$checked" -gt 0 ] || { echo "no database is in a namespace that denies by default"; return 1; }
  answers "$flows" >"$BATS_TEST_TMPDIR/answers.tsv"
  while IFS=$'\t' read -r got want mode from to port; do
    evaluated=$((evaluated + 1))
    case $got in
      allowed | denied) ;;
      *) echo "network-policy-check gave $got for $mode $from $to $port"; return 1 ;;
    esac
    [ "$got" != "$want" ] || continue
    if [ "$mode" = --reach ]; then
      mismatches+=("$got, not $want: $from -> $to $port")
    else
      mismatches+=("$got, not $want: $to takes $from $port")
    fi
  done <"$BATS_TEST_TMPDIR/answers.tsv"
  echo "$checked databases in namespaces that deny by default, $evaluated flows evaluated, ${#mismatches[@]} answered otherwise"
  [ "$evaluated" -eq "$(grep -c . "$flows")" ] || { echo "$(grep -c . "$flows") flows to evaluate, $evaluated answered"; return 1; }
  [ "${#mismatches[@]}" -eq 0 ] || { printf '%s\n' "${mismatches[@]}"; return 1; }
}
