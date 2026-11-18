#!/usr/bin/env bats
# Proves the recipe scenarios of features/secret-rotation.feature; each test carries its scenario's
# title, and tests/openbao.bats proves the two that read the tree.
# The recipe runs from a copy of the repository against fakes that keep a cluster in the test's own
# directory: a store behind a port-forward, the ExternalSecret and the Deployment of the tree as a
# cluster holds them, the Secret the ExternalSecret writes, and the Deployment's pods, each with
# the value it holds. bao-put's write changes the store. A new value of the annotation force-sync
# copies the store into the Secret and moves the ExternalSecret's syncedResourceVersion, as
# External Secrets does. A Secret whose data changed moves the workload's generation a few reads
# later, as Reloader's change to the pod template does, and the rollout that follows replaces the
# pods with new ones, of new UIDs, that hold the Secret's value. sha256sum run in a pod through
# exec answers with the real digest of what that pod holds. Files in the state directory turn each
# step's failure on.
# The recipe's PATH holds only the fakes, recorders and bash: every other command it runs by its
# name is a recorder of the real one, which puts its command line and its exported variables in
# the record and says so when it was started with the operator's standard input, a named pipe, in
# any descriptor; a command no recorder names is not found. The fakes run the real commands they
# need themselves from a directory of their own, outside the record. bash traces the recipe's
# script, so a test can show which commands it ran by a path, past the recorders. The recorder of
# head keeps what it returned: the value the recipe made is those bytes.

# The fakes keep their state in each test's own directory, and a test waits for the port-forwards
# it started; nothing is shared between tests, which may run side by side.

setup() {
  local tool
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  JUST=$(command -v just)
  JQ=$(command -v jq)
  BIN="$BATS_TEST_TMPDIR/bin"
  TOOLS="$BATS_TEST_TMPDIR/tools"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  ANSWER="$BATS_TEST_TMPDIR/answer"
  mkdir -p "$BIN" "$TOOLS" "$RECORD/removed" "$STATE" "$BATS_TEST_TMPDIR/repo/talos/lab-sto2/clusterconfig" \
    "$BATS_TEST_TMPDIR/tmp" "$BATS_TEST_TMPDIR/xtrace"
  : >"$RECORD/argv"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp "$ROOT/secret-rotation.yaml" "$REPO/secret-rotation.yaml"
  # The kubeconfig the recipes point kubectl at; the fake reads none.
  : >"$REPO/talos/lab-sto2/clusterconfig/kubeconfig"
  # The operator's standard input, when a test answers the recipe: a pipe with a name, so a
  # recorder can tell whether one of its descriptors is that pipe.
  mkfifo "$ANSWER"
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise </dev/null
  # The shell the recipes and the fakes run in is the one command outside the record.
  SYS="$BATS_TEST_TMPDIR/sys"
  mkdir -p "$SYS"
  ln -s "$(command -v bash)" "$SYS/bash"
  # What the fakes run themselves.
  for tool in cat sleep sha256sum sed cut tr mkdir rm mv grep awk base64 dirname; do
    ln -s "$(command -v "$tool")" "$TOOLS/$tool"
  done
  ln -s "$JQ" "$TOOLS/jq"
  record jq base64 cat sed grep awk tr env od sha256sum cut date mktemp mkdir chmod dirname basename realpath yq \
    paste sort wc
  record_sleep
  record_head
  record_removal rm mv
  # bash reads this file before a script runs, and traces each command the recipe's script runs, as
  # it runs it, into a file of xtrace; the fakes, just's shell and bao-put, which the recipe starts
  # without this file, are not traced. The recipe refuses to run while traced, unless the trace
  # goes to a file in BAO_TESTS_XTRACE_DIR, which only such a file sets (scripts/lib/openbao.sh).
  cat >"$BATS_TEST_TMPDIR/bash-env" <<EOF
if [[ \$0 == *scripts/secret-rotate ]]; then
  exec 9>> "$BATS_TEST_TMPDIR/xtrace/\$\$"
  BAO_TESTS_XTRACE_DIR="$BATS_TEST_TMPDIR/xtrace" BASH_XTRACEFD=9 PS4='+xtrace '
  set -x
fi
EOF
  fake_cluster
  cluster_state
}

teardown() {
  local pid
  # A port-forward a failing recipe left behind is stopped here, so no test leaves one running.
  if [[ -f $STATE/forwards ]]; then
    while read -r pid; do
      kill "$pid" 2>/dev/null || true
    done <"$STATE/forwards"
  fi
}

# fake NAME: a binary first on the recipe's PATH, its body read from stdin.
fake() {
  { echo '#!/usr/bin/env bash'; cat; } >"$BIN/$1"
  chmod +x "$BIN/$1"
}

# fake_tool NAME: like fake, with RECORD, STATE, ANSWER, TOOLS, the directory of the real commands a
# fake runs itself, and JQ, the real jq, set in the fake for its body.
fake_tool() {
  { printf 'RECORD=%q STATE=%q ANSWER=%q TOOLS=%q JQ=%q\n' "$RECORD" "$STATE" "$ANSWER" "$TOOLS" "$JQ"; cat; } | fake "$1"
}

# prelude NAME: what every recorder and fake does first, as NAME: puts its command line in the
# record, says so when one of its descriptors is the operator's standard input, with bash's own
# tests alone, and keeps the variables it was started with.
prelude() {
  cat <<EOF
printf '%s\n' "$1 \$*" >> "\$RECORD/argv"
for fd in /proc/\$\$/fd/*; do
  if [[ \$fd -ef \$ANSWER ]]; then printf '%s\n' "$1" >> "\$RECORD/inherited"; fi
done
declare -px >> "\$RECORD/environment"
EOF
}

# record NAME...: a recorder of each NAME, which then runs the real one.
record() {
  local tool real
  for tool; do
    real=$(command -v "$tool")
    { prelude "$tool"; printf 'exec %q "$@"\n' "$real"; } | fake_tool "$tool"
  done
}

# greedy NAME...: like record, and each first reads all of the standard input it was started
# with, as a tool may.
greedy() {
  local tool real
  for tool; do
    real=$(command -v "$tool")
    { prelude "$tool"; printf '%q > /dev/null\nexec %q "$@"\n' "$TOOLS/cat" "$real"; } | fake_tool "$tool"
  done
}

# record_sleep: like record for sleep, which then sleeps a twentieth of a second whatever it was
# asked, so a recipe that asks the cluster once a second is through a test's few reads at once. A
# wait still ends by the clock.
record_sleep() {
  { prelude sleep; printf 'exec %q 0.05\n' "$TOOLS/sleep"; } | fake_tool sleep
}

# record_head: like record for head, and keeps every byte head returns in $RECORD/head-output.
# shellcheck disable=SC2016 # the dollars are the recorder's own.
record_head() {
  { prelude head; printf 'set -o pipefail\n%q "$@" | %q -a "$RECORD/head-output"\n' "$(command -v head)" "$(command -v tee)"; } |
    fake_tool head
}

# record_removal NAME...: like record, and first copies each path NAME is given that exists into a
# directory of its own under $RECORD/removed, which leaked searches: what a recipe writes and
# removes again, or replaces, is seen there. The fakes' own state is not copied.
record_removal() {
  local tool real
  for tool; do
    real=$(command -v "$tool")
    {
      prelude "$tool"
      cat <<EOF
kept=\$("$(command -v mktemp)" -d "\$RECORD/removed/$tool.XXXXXXXXXX")
for operand; do
  if [[ \$operand != -* && \$operand != "\$STATE"/* ]] && [[ -e \$operand || -L \$operand ]]; then
    "$(command -v cp)" -R -- "\$operand" "\$kept/"
  fi
done
exec "$real" "\$@"
EOF
    } | fake_tool "$tool"
  done
}

# recipe NAME [ARG...]: runs the repository's recipe against the copy, with only what it needs in
# its environment, and starts the record anew. A recipe that blocks fails after two minutes
# instead of hanging the tests.
recipe() {
  : >"$RECORD/argv"
  rm -f "$RECORD/requests" "$RECORD/digested" "$RECORD/head-output" "$RECORD/inherited" "$RECORD/environment"
  run timeout 120 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$SYS" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    BASH_ENV="$BATS_TEST_TMPDIR/bash-env" "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$@"
}

# answered TEXT [ARG...]: secret-rotate with ARG..., its standard input the pipe, which holds the
# one line TEXT and then ends.
answered() {
  local text=$1
  shift
  printf '%s\n' "$text" >"$ANSWER" &
  recipe secret-rotate "$@" <"$ANSWER"
  wait
}

# fake_cluster: a fake kubectl and a fake OpenBao behind its port-forward, over the cluster that
# cluster_state writes. What they do beyond the header's account is set by files in STATE:
#   api-unreachable   kubectl cannot reach the API server for the cluster's objects, and says so
#                     naming its address, with terminal control characters
#   no-sha256sum      the container has no sha256sum to run
#   hung-exec         an exec in the pod the file names answers nothing for 45 seconds
#   interrupt-exec    an exec in the pod the file names sends SIGINT to the recipe's process
#                     group, as a terminal's interrupt does, and then answers nothing for 45
#                     seconds; its process id is in exec-pid
#   odd-sha256sum     the container's sha256sum answers in another form, the digest after the
#                     file's name, and succeeds; with a number N in the file, the digest comes N
#                     spaces later, and the answer is on standard error as well
#   in-rollout        every workload is in the middle of a rollout
#   refresh-fails     the ExternalSecret turns not Ready when its annotation changes, with a
#                     message that holds terminal control characters
#   refresh-stalls    the ExternalSecret's status stays as it was when its annotation changes
#   refresh-after     the ExternalSecret refreshes at the Nth read of it after the annotation,
#                     N the file's content, and at once without it
#   interrupt-refresh a read of one ExternalSecret that carries the annotation sends SIGINT to the
#                     recipe's script
#   no-restart        the workload's generation never moves
#   restart-after     the generation moves at the Nth read of it after the Secret changed, N the
#                     file's content, and at the second without it
#   rollout-stuck     the rollout that follows does not finish
#   stale-pod         the last new pod holds the file's content in place of the Secret's value
#   empty-pod         the last new pod holds no file
#   kept-pod          the first pod from before stays, with the new value in its file, as the
#                     kubelet writes it there, and stands in for the first new pod
#   terminating-pod   the last pod from before stays, being deleted, with the value it held
#   resync-before-write  the ExternalSecret's syncedResourceVersion moves as bao-put logs in, as
#                     a change to its annotations makes it move, by a refresh that reads the
#                     value from before
#   write-refused     OpenBao refuses the write
#   interrupt-write   the write sends SIGINT to the recipe's script, and is made
# Each request to OpenBao is appended to $RECORD/requests as one JSON object: its method, path,
# body, token and whether it reached OpenBao by its certificate's name and verified it against
# OpenBao's CA. Each exec is a line of $RECORD/digested: the namespace, pod, container and file.
fake_cluster() {
  {
    prelude kubectl
    cat <<'KUBECTL'
PATH=$TOOLS
# A tool may read all of the standard input it is started with. The operator's answer is in it
# only where the recipe handed its own standard input on.
cat > /dev/null

# state FILE FILTER [ARG...]: rewrites FILE of the cluster's state with the jq FILTER.
state() {
  local file=$STATE/$1 filter=$2
  shift 2
  jq -c "$@" "$filter" "$file" > "$file.new" && mv "$file.new" "$file"
}

# object FILE NAMESPACE NAME [KIND]: the object of FILE with that namespace and name, of KIND
# where one is given, on one line.
object() {
  jq -c --arg ns "$2" --arg name "$3" --arg kind "${4-}" \
    '.items[] | select(.metadata.namespace == $ns and .metadata.name == $name and ($kind == "" or .kind == $kind))' "$STATE/$1"
}

kind_of() {
  case $1 in
    deployments.apps) echo Deployment ;;
    statefulsets.apps) echo StatefulSet ;;
    daemonsets.apps) echo DaemonSet ;;
    *) echo "fake kubectl: unexpected resource $1" >&2 && exit 1 ;;
  esac
}

# interrupt: SIGINT to the process that runs the recipe's script: the topmost of this one's
# ancestors whose command line names it, past the subshells of its pipelines, which share it.
interrupt() {
  local pid=$PPID target=""
  while ((pid > 1)); do
    if tr '\0' ' ' < "/proc/$pid/cmdline" | grep -qE '(^| )scripts/secret-rotate( |$)'; then
      target=$pid
    elif [[ -n $target ]]; then
      break
    fi
    pid=$(awk '{print $4}' "/proc/$pid/stat")
  done
  [[ -z $target ]] || kill -INT "$target"
}

# refresh NAMESPACE NAME: what External Secrets does for an ExternalSecret whose annotations
# changed: each entry of spec.data is read from the store into the Secret, the status says Ready
# and holds a syncedResourceVersion made of the generation and the annotations, and a Secret whose
# data changed has each workload of the namespace that mounts it restarted by Reloader, a few
# reads of that workload later.
refresh() {
  local ns=$1 name=$2 secret file before key path property kind workload
  secret=$(object es.json "$ns" "$name" | jq -r '.spec.target.name // .metadata.name')
  file=$STATE/secret/$ns/$secret.json
  mkdir -p "$STATE/secret/$ns"
  [[ -f $file ]] || echo '{}' > "$file"
  before=$(sha256sum < "$file")
  while IFS=$'\t' read -r key path property; do
    # The store's path is the mount, secrets, and the key-value API's data: a key may name either
    # in front of the path, which External Secrets' Vault provider takes off.
    case $path in
      secrets/data/*) path=${path#secrets/data/} ;;
      secrets/*) path=${path#secrets/} ;;
    esac
    jq -c --arg key "$key" --arg property "$property" --slurpfile store "$STATE/kv/$path.json" \
      '.[$key] = $store[0][$property]' "$file" > "$file.new" && mv "$file.new" "$file"
  done < <(object es.json "$ns" "$name" | jq -r '.spec.data[] | [.secretKey, .remoteRef.key, .remoteRef.property] | @tsv')
  state es.json '(.items[] | select(.metadata.namespace == $ns and .metadata.name == $name)) |=
    (.status.syncedResourceVersion = "\(.metadata.generation)-\(.metadata.annotations | tojson | @base64)"
      | .status.conditions = [{type: "Ready", status: "True", reason: "SecretSynced", message: "secret synced"}])' \
    --arg ns "$ns" --arg name "$name"
  if [[ $before != "$(sha256sum < "$file")" && ! -e $STATE/no-restart ]]; then
    while IFS=$'\t' read -r kind workload; do
      mkdir -p "$STATE/reload/$ns/$kind"
      cat "$STATE/restart-after" 2> /dev/null > "$STATE/reload/$ns/$kind/$workload" || echo 2 > "$STATE/reload/$ns/$kind/$workload"
    done < <(jq -r --arg ns "$ns" --arg secret "$secret" '.items[] | select(.metadata.namespace == $ns
      and any(.spec.template.spec.volumes[]?; .secret.secretName == $secret)) | [.kind, .metadata.name] | @tsv' "$STATE/workloads.json")
  fi
}

# roll NAMESPACE KIND NAME: the rollout of a workload whose pod template changed: its pods are
# replaced by as many new ones, of new names and UIDs, each holding the value its Secret has now.
roll() {
  local ns=$1 kind=$2 name=$3 workload secret key generation labels count kept="" leaving="" pod i
  local -a old
  workload=$(object workloads.json "$ns" "$name" "$kind")
  secret=$(jq -r '[.spec.template.spec.volumes[] | select(.secret != null)][0].secret.secretName' <<< "$workload")
  # A volume without items holds every key of the Secret: the demo's is greeting.
  key=$(jq -r '[.spec.template.spec.volumes[] | select(.secret != null)][0].secret | (.items // [{key: "greeting"}])[0].key' <<< "$workload")
  generation=$(jq -r '.metadata.generation' <<< "$workload")
  labels=$(jq -c '.spec.selector.matchLabels' <<< "$workload")
  count=$(jq -r '.spec.replicas' <<< "$workload")
  mapfile -t old < <(jq -r --arg ns "$ns" --argjson labels "$labels" '.items[] | select(.metadata.namespace == $ns)
    | select(.metadata.labels as $have | $labels | to_entries | all($have[.key] == .value)) | .metadata.name' "$STATE/pods.json")
  [[ ! -e $STATE/kept-pod ]] || kept=${old[0]}
  [[ ! -e $STATE/terminating-pod ]] || leaving=${old[-1]}
  for pod in "${old[@]}"; do
    if [[ $pod == "$kept" ]]; then
      jq -j --arg key "$key" '.[$key]' "$STATE/secret/$ns/$secret.json" > "$STATE/holds/$ns/$pod"
    elif [[ $pod == "$leaving" ]]; then
      state pods.json '(.items[] | select(.metadata.namespace == $ns and .metadata.name == $pod)).metadata.deletionTimestamp = "2026-11-14T00:00:00Z"' \
        --arg ns "$ns" --arg pod "$pod"
    else
      state pods.json 'del(.items[] | select(.metadata.namespace == $ns and .metadata.name == $pod))' --arg ns "$ns" --arg pod "$pod"
      rm -f "$STATE/holds/$ns/$pod"
    fi
  done
  for ((i = 1; i <= count; i++)); do
    [[ -z $kept || $i != 1 ]] || continue
    pod=$name-g$generation-$i
    state pods.json '.items += [{metadata: {namespace: $ns, name: $pod, uid: ("uid-" + $pod), labels: $labels}, status: {phase: "Running"}}]' \
      --arg ns "$ns" --arg pod "$pod" --argjson labels "$labels"
    if [[ -e $STATE/stale-pod && $i == "$count" ]]; then
      cat "$STATE/stale-pod" > "$STATE/holds/$ns/$pod"
    elif [[ ! -e $STATE/empty-pod || $i != "$count" ]]; then
      jq -j --arg key "$key" '.[$key]' "$STATE/secret/$ns/$secret.json" > "$STATE/holds/$ns/$pod"
    fi
  done
}

# bao-put's own calls.
case " $* " in
  *" port-forward "*)
    echo "Forwarding from 127.0.0.1:41234 -> 8200"
    echo "Forwarding from [::1]:41234 -> 8200"
    echo "$$" >> "$STATE/forwards"
    exec sleep 600
    ;;
  *" create token openbao-operator "*)
    echo marker-service-account-jwt
    exit 0
    ;;
  *" get secret openbao-ca "*)
    printf -- '-----BEGIN CERTIFICATE-----\nmarker-ca\n-----END CERTIFICATE-----\n' | base64 -w0
    exit 0
    ;;
esac

verb=$1
shift
namespace="" selector="" output="" container="" timeout="" words=() command=()
while (($#)); do
  case $1 in
    --namespace) namespace=$2 && shift ;;
    --selector) selector=$2 && shift ;;
    --output) output=$2 && shift ;;
    --container) container=$2 && shift ;;
    --timeout=*) timeout=${1#*=} ;;
    --all-namespaces | --overwrite | --request-timeout=*) ;;
    --)
      shift
      command=("$@")
      break
      ;;
    -*) echo "fake kubectl: unexpected option $1" >&2 && exit 1 ;;
    *) words+=("$1") ;;
  esac
  shift
done
if [[ -e $STATE/api-unreachable ]]; then
  printf 'Unable to connect to the server: dial tcp 192.0.2.10:6443: i/o timeout\033]0;marker-title\007\n' >&2
  exit 1
fi

case "$verb ${words[0]-}" in
  "get externalsecrets.external-secrets.io")
    if [[ -z ${words[1]-} ]]; then
      cat "$STATE/es.json"
      exit 0
    fi
    if [[ -e $STATE/interrupt-refresh && -n $(object es.json "$namespace" "${words[1]}" | jq -r '.metadata.annotations["force-sync"] // ""') ]]; then
      interrupt
    fi
    pending=$STATE/refresh/$namespace/${words[1]}
    if [[ -f $pending ]]; then
      left=$(($(< "$pending") - 1))
      if ((left <= 0)); then
        rm "$pending"
        refresh "$namespace" "${words[1]}"
      else
        echo "$left" > "$pending"
      fi
    fi
    object es.json "$namespace" "${words[1]}"
    ;;
  "get deployments.apps,statefulsets.apps,daemonsets.apps")
    jq -c --arg ns "$namespace" '.items |= map(select(.metadata.namespace == $ns))' "$STATE/workloads.json"
    ;;
  "get deployments.apps" | "get statefulsets.apps" | "get daemonsets.apps")
    kind=$(kind_of "${words[0]}")
    [[ $output == "jsonpath={.metadata.generation}" ]] || { echo "fake kubectl: unexpected output $output" >&2 && exit 1; }
    reload=$STATE/reload/$namespace/$kind/${words[1]}
    if [[ -f $reload ]]; then
      left=$(($(< "$reload") - 1))
      if ((left <= 0)); then
        rm "$reload"
        state workloads.json '(.items[] | select(.metadata.namespace == $ns and .kind == $kind and .metadata.name == $name)).metadata.generation += 1' \
          --arg ns "$namespace" --arg kind "$kind" --arg name "${words[1]}"
        mkdir -p "$STATE/rolling/$namespace/$kind"
        : > "$STATE/rolling/$namespace/$kind/${words[1]}"
      else
        echo "$left" > "$reload"
      fi
    fi
    object workloads.json "$namespace" "${words[1]}" "$kind" | jq -r '.metadata.generation'
    ;;
  "get pods")
    jq -c --arg ns "$namespace" --arg selector "$selector" '
      ($selector | split(",") | map(if test("^[^=!, ()]+=[^=!, ()]*$") then split("=") | {key: .[0], value: .[1]}
        else error("fake kubectl: a selector of another form than key=value") end)) as $want
      | .items |= map(select(.metadata.namespace == $ns)
        | select(.metadata.labels as $have | $want | all($have[.key] == .value)))' "$STATE/pods.json"
    ;;
  "annotate externalsecrets.external-secrets.io")
    name=${words[1]} pair=${words[2]}
    [[ $pair == force-sync=?* ]] || { echo "fake kubectl: unexpected annotation $pair" >&2 && exit 1; }
    current=$(object es.json "$namespace" "$name" | jq -r '.metadata.annotations["force-sync"] // ""')
    # External Secrets reads the store again only when the annotations are others than they were.
    if [[ $current != "${pair#*=}" ]]; then
      state es.json '(.items[] | select(.metadata.namespace == $ns and .metadata.name == $name)).metadata.annotations["force-sync"] = $value' \
        --arg ns "$namespace" --arg name "$name" --arg value "${pair#*=}"
      if [[ -e $STATE/refresh-stalls ]]; then
        :
      elif [[ -e $STATE/refresh-fails ]]; then
        state es.json '(.items[] | select(.metadata.namespace == $ns and .metadata.name == $name)).status.conditions =
          [{type: "Ready", status: "False", reason: "SecretSyncedError", message: "could not get secret data from provider\u001b]0;marker-title\u0007"}]' \
          --arg ns "$namespace" --arg name "$name"
      elif [[ -e $STATE/refresh-after ]]; then
        mkdir -p "$STATE/refresh/$namespace"
        cat "$STATE/refresh-after" > "$STATE/refresh/$namespace/$name"
      else
        refresh "$namespace" "$name"
      fi
    fi
    echo "externalsecret.external-secrets.io/$name annotated"
    ;;
  "rollout status")
    resource=${words[1]%%/*} name=${words[1]#*/}
    kind=$(kind_of "$resource")
    [[ $timeout =~ ^[1-9][0-9]*s$ ]] || { echo "fake kubectl: rollout status without a timeout of whole seconds" >&2 && exit 1; }
    if [[ -e $STATE/in-rollout || (-e $STATE/rolling/$namespace/$kind/$name && -e $STATE/rollout-stuck) ]]; then
      echo "Waiting for deployment \"$name\" rollout to finish: 1 out of 2 new replicas have been updated..."
      echo "error: timed out waiting for the condition" >&2
      exit 1
    fi
    if [[ -e $STATE/rolling/$namespace/$kind/$name ]]; then
      roll "$namespace" "$kind" "$name"
      rm "$STATE/rolling/$namespace/$kind/$name"
    fi
    # kubectl's own words for each kind.
    case $kind in
      Deployment) echo "deployment \"$name\" successfully rolled out" ;;
      DaemonSet) echo "daemon set \"$name\" successfully rolled out" ;;
      StatefulSet)
        echo "statefulset rolling update complete $(object workloads.json "$namespace" "$name" "$kind" | jq -r '.spec.replicas') pods at revision $name-fake..."
        ;;
    esac
    ;;
  "exec "*)
    pod=${words[0]}
    [[ ${#command[@]} -eq 2 && ${command[0]} == sha256sum && -n $container ]] ||
      { echo "fake kubectl: unexpected command in a container: ${command[*]}" >&2 && exit 1; }
    printf '%s %s %s %s\n' "$namespace" "$pod" "$container" "${command[1]}" >> "$RECORD/digested"
    if [[ $(cat "$STATE/hung-exec" 2> /dev/null) == "$pod" ]]; then
      exec sleep 45
    fi
    if [[ $(cat "$STATE/interrupt-exec" 2> /dev/null) == "$pod" ]]; then
      echo "$$" > "$STATE/exec-pid"
      kill -INT -- "-$(awk '{print $5}' "/proc/$$/stat")"
      exec sleep 45
    fi
    if [[ -e $STATE/no-sha256sum ]]; then
      echo 'error: Internal error occurred: Internal error occurred: error executing command in container: failed to exec in container: failed to start exec "c0ffee": OCI runtime exec failed: exec failed: unable to start container process: exec: "sha256sum": executable file not found in $PATH: unknown' >&2
      exit 1
    fi
    if [[ ! -f $STATE/holds/$namespace/$pod ]]; then
      echo "sha256sum: can't open '${command[1]}': No such file or directory" >&2
      echo "command terminated with exit code 1" >&2
      exit 1
    fi
    if [[ -e $STATE/odd-sha256sum ]]; then
      pad=$(< "$STATE/odd-sha256sum")
      answer=$(printf 'SHA256 (%s) %*s= %s' "${command[1]}" "${pad:-0}" '' "$(sha256sum < "$STATE/holds/$namespace/$pod" | cut -d' ' -f1)")
      printf '%s\n' "$answer"
      [[ -z $pad ]] || printf '%s\n' "$answer" >&2
      exit 0
    fi
    printf '%s  %s\n' "$(sha256sum < "$STATE/holds/$namespace/$pod" | cut -d' ' -f1)" "${command[1]}"
    ;;
  *)
    echo "fake kubectl: unexpected kubectl $verb ${words[*]}" >&2
    exit 1
    ;;
esac
KUBECTL
  } | fake_tool kubectl
  {
    prelude curl
    cat <<'CURL'
PATH=$TOOLS
method=GET url="" headers="" body="" cacert="" connect="" write_out=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    --request | -X) method=${args[++i]} ;;
    --header | -H)
      header=${args[++i]}
      if [[ $header == @* ]]; then headers+=$(cat "${header#@}")$'\n'; else headers+=$header$'\n'; fi
      ;;
    --data-binary) [[ ${args[++i]} == @- ]] && body=$(cat) ;;
    --cacert) cacert=${args[++i]} ;;
    --connect-to) connect=${args[++i]} ;;
    --write-out | -w) write_out=${args[++i]} ;;
    --max-time | -m | --output | -o) ((i++)) ;;
    https://*) url=${args[i]} ;;
  esac
done
path=${url#https://openbao-active.openbao.svc:8200/v1/}
token=$(sed -n 's/^X-Vault-Token: //p' <<< "$headers")
tls=bad
if [[ $url == https://openbao-active.openbao.svc:8200/v1/* && $connect == openbao-active.openbao.svc:8200:localhost:41234 ]] &&
  grep -qx marker-ca "$cacert" 2> /dev/null; then
  tls=verified
fi
printf '%s' "$body" | jq -Rsc --arg method "$method" --arg path "$path" --arg token "$token" --arg tls "$tls" \
  --arg type "$(sed -n 's/^Content-Type: //p' <<< "$headers")" \
  '{method: $method, path: $path, body: ., token: $token, tls: $tls, type: $type}' >> "$RECORD/requests"
if [[ -e $STATE/interrupt-write && $method == PATCH ]]; then
  # The topmost ancestor that runs the recipe's script, as the fake kubectl finds it.
  pid=$PPID target=""
  while ((pid > 1)); do
    if tr '\0' ' ' < "/proc/$pid/cmdline" | grep -qE '(^| )scripts/secret-rotate( |$)'; then
      target=$pid
    elif [[ -n $target ]]; then
      break
    fi
    pid=$(awk '{print $4}' "/proc/$pid/stat")
  done
  [[ -z $target ]] || kill -INT "$target"
fi
respond() {
  printf '%s' "$2"
  if [[ -n $write_out ]]; then printf '\n%s' "$1"; fi
  exit 0
}
[[ $path == auth/kubernetes/login || $token == marker-bao-token ]] || respond 403 '{"errors":["permission denied"]}'
case "$method $path" in
  "POST auth/kubernetes/login")
    if [[ -e $STATE/resync-before-write ]]; then
      jq -c '(.items[] | select(.metadata.namespace == "demo" and .metadata.name == "hello")).status.syncedResourceVersion = "1-synced-meanwhile"' \
        "$STATE/es.json" > "$STATE/es.json.new" && mv "$STATE/es.json.new" "$STATE/es.json"
    fi
    if [[ $(jq -r '.role + " " + .jwt' <<< "$body") == "operator marker-service-account-jwt" ]]; then
      respond 200 '{"request_id":"fake","lease_id":"","renewable":false,"lease_duration":0,"data":null,"wrap_info":null,"warnings":null,"auth":{"client_token":"marker-bao-token","accessor":"marker-accessor","policies":["operator"],"token_policies":["operator"],"lease_duration":600,"renewable":true}}'
    fi
    respond 400 '{"errors":["invalid role or service account"]}'
    ;;
  "POST auth/token/revoke-self")
    : > "$STATE/revoked"
    respond 204 ''
    ;;
  # The operator role may create and patch a key and never read one (operator-policy.json).
  "GET secrets/data/"*) respond 403 '{"errors":["permission denied"]}' ;;
  "PATCH secrets/data/"*)
    [[ -e $STATE/write-refused ]] && respond 403 '{"errors":["permission denied"]}'
    file=$STATE/kv/${path#secrets/data/}.json
    [[ -f $file ]] || respond 404 '{"errors":[]}'
    printf '%s' "$body" | jq -c --slurpfile current "$file" '$current[0] * .data' > "$file.new" && mv "$file.new" "$file"
    respond 200 '{"request_id":"fake","lease_id":"","renewable":false,"lease_duration":0,"data":{"created_time":"2026-11-14T00:00:00Z","custom_metadata":null,"deletion_time":"","destroyed":false,"version":2},"wrap_info":null,"warnings":null,"auth":null}'
    ;;
  "POST secrets/data/"*)
    [[ -e $STATE/write-refused ]] && respond 403 '{"errors":["permission denied"]}'
    file=$STATE/kv/${path#secrets/data/}.json
    [[ ! -f $file ]] || respond 403 '{"errors":["permission denied"]}'
    mkdir -p "$(dirname "$file")"
    printf '%s' "$body" | jq -c '.data' > "$file"
    respond 200 '{"request_id":"fake","lease_id":"","renewable":false,"lease_duration":0,"data":{"created_time":"2026-11-14T00:00:00Z","custom_metadata":null,"deletion_time":"","destroyed":false,"version":1},"wrap_info":null,"warnings":null,"auth":null}'
    ;;
esac
respond 404 '{"errors":[]}'
CURL
  } | fake_tool curl
}

# cluster_state: the cluster the fakes keep, written anew with no failure turned on: the store's
# key, with another key beside it; the tree's own ExternalSecret and Deployment, as a cluster
# holds them, synced and settled; the Secret; and the Deployment's two pods, each holding the
# Secret's value. Beside them, what the rotation is none of the business of: an ExternalSecret
# of another namespace that is not Ready, one that reads another key of the same path, one that
# reads a generator, a Deployment of the namespace without the Secret and its pod, and a
# StatefulSet of another namespace that mounts a Secret of the same name.
# shellcheck disable=SC2016 # $hello is a jq variable.
cluster_state() {
  local external deployment kept
  for kept in "$STATE"/*; do
    [[ ! -e $kept || ${kept##*/} == forwards ]] || rm -rf "$kept"
  done
  mkdir -p "$STATE/kv/demo" "$STATE/secret/demo" "$STATE/holds/demo"
  echo '{"greeting":"marker-greeting-before","other":"keep-me"}' >"$STATE/kv/demo/hello.json"
  echo '{"greeting":"marker-greeting-before"}' >"$STATE/secret/demo/hello.json"
  external=$(yq -o json -I0 '.' "$ROOT/kubernetes/apps/base/demo/hello-secret/app/externalsecret.yaml" |
    "$JQ" -c '.metadata += {namespace: "demo", generation: 1, annotations: {}}
      | .status = {conditions: [{type: "Ready", status: "True", reason: "SecretSynced", message: "secret synced"}],
          refreshTime: "2026-11-14T00:00:00Z", syncedResourceVersion: "1-synced-before"}')
  "$JQ" -n --argjson hello "$external" '{apiVersion: "v1", kind: "List", items: [
    {apiVersion: "external-secrets.io/v1", kind: "ExternalSecret",
      metadata: {namespace: "cert-manager", name: "cloudflare-api-token", generation: 1},
      spec: {refreshInterval: "15m", secretStoreRef: {kind: "ClusterSecretStore", name: "openbao"},
        target: {name: "cloudflare-api-token", creationPolicy: "Owner"},
        data: [{secretKey: "api-token", remoteRef: {key: "cert-manager/cloudflare", property: "api-token"}}]},
      status: {conditions: [{type: "Ready", status: "False", reason: "SecretSyncedError", message: "could not get secret data from provider"}]}},
    $hello,
    {apiVersion: "external-secrets.io/v1", kind: "ExternalSecret",
      metadata: {namespace: "demo", name: "other", generation: 1},
      spec: {refreshInterval: "15m", secretStoreRef: {kind: "ClusterSecretStore", name: "openbao"},
        target: {name: "other", creationPolicy: "Owner", template: {data: {shout: "{{ .other | upper }}"}}},
        data: [{secretKey: "other", remoteRef: {key: "demo/hello", property: "other"}}]},
      status: {conditions: [{type: "Ready", status: "True", reason: "SecretSynced", message: "secret synced"}], syncedResourceVersion: "1-other"}},
    {apiVersion: "external-secrets.io/v1", kind: "ExternalSecret",
      metadata: {namespace: "sso-system", name: "oauth2-proxy-cookie", generation: 1},
      spec: {refreshPolicy: "CreatedOnce", target: {name: "oauth2-proxy-cookie", creationPolicy: "Owner"},
        dataFrom: [{sourceRef: {generatorRef: {apiVersion: "generators.external-secrets.io/v1alpha1", kind: "Password", name: "oauth2-proxy-cookie"}}}]},
      status: {conditions: [{type: "Ready", status: "True", reason: "SecretSynced", message: "secret synced"}], syncedResourceVersion: "1-cookie"}}]}' \
    >"$STATE/es.json"
  deployment=$(yq -o json -I0 '.' "$ROOT/kubernetes/apps/base/demo/hello/app/deployment.yaml" |
    "$JQ" -c '.metadata += {namespace: "demo", generation: 3}
      | .status = {observedGeneration: 3, replicas: 2, updatedReplicas: 2, availableReplicas: 2}')
  "$JQ" -n --argjson hello "$deployment" '{apiVersion: "v1", kind: "List", items: [
    $hello,
    {apiVersion: "apps/v1", kind: "Deployment", metadata: {namespace: "demo", name: "volsync-demo", generation: 1},
      spec: {replicas: 1, selector: {matchLabels: {"app.kubernetes.io/name": "volsync-demo"}},
        template: {metadata: {labels: {"app.kubernetes.io/name": "volsync-demo"}},
          spec: {containers: [{name: "canary", image: "docker.io/library/busybox:1.38.0",
            volumeMounts: [{name: "data", mountPath: "/data"}]}],
            volumes: [{name: "data", persistentVolumeClaim: {claimName: "volsync-demo"}}]}}},
      status: {observedGeneration: 1, replicas: 1, updatedReplicas: 1, availableReplicas: 1}},
    {apiVersion: "apps/v1", kind: "StatefulSet", metadata: {namespace: "elsewhere", name: "hello", generation: 1},
      spec: {replicas: 1, selector: {matchLabels: {"app.kubernetes.io/name": "hello"}},
        template: {metadata: {labels: {"app.kubernetes.io/name": "hello"}},
          spec: {containers: [{name: "main", image: "docker.io/library/busybox:1.38.0",
            volumeMounts: [{name: "greeting", mountPath: "/etc/hello"}]}],
            volumes: [{name: "greeting", secret: {secretName: "hello"}}]}}},
      status: {observedGeneration: 1, replicas: 1, readyReplicas: 1}}]}' >"$STATE/workloads.json"
  "$JQ" -n '{apiVersion: "v1", kind: "List", items: [
    {metadata: {namespace: "demo", name: "hello-before-1", uid: "uid-hello-before-1", labels: {"app.kubernetes.io/name": "hello"}}, status: {phase: "Running"}},
    {metadata: {namespace: "demo", name: "hello-before-2", uid: "uid-hello-before-2", labels: {"app.kubernetes.io/name": "hello"}}, status: {phase: "Running"}},
    {metadata: {namespace: "demo", name: "volsync-demo-1", uid: "uid-volsync-demo-1", labels: {"app.kubernetes.io/name": "volsync-demo"}}, status: {phase: "Running"}},
    {metadata: {namespace: "elsewhere", name: "hello-0", uid: "uid-elsewhere-hello-0", labels: {"app.kubernetes.io/name": "hello"}}, status: {phase: "Running"}}]}' \
    >"$STATE/pods.json"
  printf '%s' marker-greeting-before >"$STATE/holds/demo/hello-before-1"
  printf '%s' marker-greeting-before >"$STATE/holds/demo/hello-before-2"
}

# external FILTER: changes the ExternalSecret hello of demo, as the fake cluster holds it.
external() {
  "$JQ" -c "(.items[] | select(.metadata.namespace == \"demo\" and .metadata.name == \"hello\")) |= ($1)" "$STATE/es.json" \
    >"$STATE/es.json.new" && mv "$STATE/es.json.new" "$STATE/es.json"
}

# workload FILTER: changes the Deployment hello of demo, as the fake cluster holds it.
workload() {
  "$JQ" -c "(.items[] | select(.metadata.namespace == \"demo\" and .metadata.name == \"hello\")) |= ($1)" "$STATE/workloads.json" \
    >"$STATE/workloads.json.new" && mv "$STATE/workloads.json.new" "$STATE/workloads.json"
}

# snapshot: the digest of everything the fake cluster holds: the store, the Secrets, the objects
# and what each pod holds.
snapshot() {
  (cd "$STATE" && {
    find kv secret holds -type f | LC_ALL=C sort | xargs sha256sum
    sha256sum es.json workloads.json pods.json
  } | sha256sum)
}

# reads_only BEFORE: the recipe that just ran only read the cluster, which is as its snapshot
# BEFORE has it: kubectl got, ran sha256sum and asked for a rollout's state, with the ten seconds a
# settled workload answers within, and nothing else; no value was made, OpenBao was sent nothing
# and no port-forward was asked for.
reads_only() {
  local other
  other=$(grep -E '^kubectl ' "$RECORD/argv" | grep -vE '^kubectl (get (externalsecrets\.external-secrets\.io|deployments\.apps,statefulsets\.apps,daemonsets\.apps|pods) |exec |rollout status [^ ]+ --namespace [^ ]+ --timeout=10s$)' || true)
  echo "kubectl calls that are no reads: ${other:-none}"
  [ -z "$other" ]
  [ "$(grep -c -E '^(curl|head) ' "$RECORD/argv")" -eq 0 ] || { echo "a value was made or OpenBao was reached"; return 1; }
  [ "$(snapshot)" = "$1" ] || { echo "the cluster is not as it was"; return 1; }
}

# refused BEFORE REASON: the recipe that just ran exited non-zero naming REASON, after reads alone.
refused() {
  [ "$status" -ne 0 ] || { echo "the recipe went on"; return 1; }
  [[ $output == *"$2"* ]] || { echo "no \"$2\" in the output"; return 1; }
  reads_only "$1"
}

# refused_before_reaching REASON: the recipe that just ran failed naming REASON, and reached
# neither the cluster nor OpenBao.
refused_before_reaching() {
  [ "$status" -ne 0 ] || { echo "the recipe went on"; return 1; }
  [[ $output == *"$1"* ]] || { echo "no \"$1\" in the output"; return 1; }
  [ "$(grep -c -E '^(kubectl|curl) ' "$RECORD/argv")" -eq 0 ] || { echo "the cluster or OpenBao was reached"; return 1; }
}

# absent TEXT FILE...: fails when any FILE holds TEXT.
absent() {
  local text=$1
  shift
  if grep -qF -- "$text" "$@" 2>/dev/null; then
    echo "found $text in $*" >&2
    return 1
  fi
}

# forwards_closed: every port-forward a recipe started has stopped, and nothing is left in TMPDIR.
forwards_closed() {
  local pid left=""
  [[ -s $STATE/forwards ]] || { echo "no port-forward was started"; return 1; }
  while read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then left+=" $pid"; fi
  done <"$STATE/forwards"
  echo "port-forwards still running:${left:- none}"
  [ -z "$left" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/tmp")" ] || { echo "left in TMPDIR: $(ls -A "$BATS_TEST_TMPDIR/tmp")"; return 1; }
}

# requests_of METHOD PATH: the bodies of the requests to PATH by METHOD, one per line.
# shellcheck disable=SC2016 # $method and $path are jq variables.
requests_of() {
  "$JQ" -r --arg method "$1" --arg path "$2" 'select(.method == $method and .path == $path) | .body' "$RECORD/requests"
}

# no_controls TEXT: TEXT holds no terminal control character: none of C0 but the tab, no DEL, and
# none of C1 as UTF-8 writes it.
no_controls() {
  local LC_ALL=C
  [[ $1 != *[$'\x01'-$'\x08'$'\x0b'-$'\x1f'$'\x7f']* ]] || { echo "a C0 control or DEL in the output"; return 1; }
  [[ $1 != *$'\xc2'[$'\x80'-$'\x9f']* ]] || { echo "a C1 control in the output"; return 1; }
}

# by_path: the commands the recipe's script ran by a path or as a shell, with their arguments, one
# a line, as bash traced them: every other command ran by its name, through a recorder, so its
# command line is in the record. The command is the first word after any assignments, and after
# exec, command, builtin, env, nohup or time with their options and assignments; bash quotes a
# word that holds a space, which is read back as one word.
by_path() {
  [ -n "$(ls -A "$BATS_TEST_TMPDIR/xtrace")" ] || { echo "no script was traced"; return 1; }
  # shellcheck disable=SC2016 # awk's own fields and variables.
  cat "$BATS_TEST_TMPDIR"/xtrace/* | awk '
    function split_words(s,    i, c, cur, quoted, ansi, n) {
      n = 0; cur = ""; quoted = 0; ansi = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (quoted) {
          if (ansi && c == "\\") { cur = cur substr(s, ++i, 1); continue }
          if (c == "\047") { quoted = 0; ansi = 0; continue }
          cur = cur c; continue
        }
        if (c == "\047") { quoted = 1; continue }
        if (c == "$" && substr(s, i + 1, 1) == "\047") { quoted = 1; ansi = 1; i++; continue }
        if (c == " ") { if (cur != "") word[++n] = cur; cur = ""; continue }
        cur = cur c
      }
      if (cur != "") word[++n] = cur
      return n
    }
    /^\++xtrace / {
      sub(/^\++xtrace /, "")
      n = split_words($0)
      i = 1
      while (i <= n) {
        if (word[i] ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/) { i++; continue }
        if (word[i] ~ /^(exec|command|builtin|env|nohup|time)$/) {
          for (i++; i <= n && (word[i] ~ /^-/ || word[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/); i++) {
            if (word[i] ~ /^-[auCS]$/) i++
          }
          continue
        }
        break
      }
      if (i <= n && (word[i] ~ /\// || word[i] ~ /^(bash|sh|dash|zsh|ksh|mksh|busybox)$/)) {
        line = word[i]
        for (i++; i <= n; i++) line = line " " word[i]
        print line
      }
    }' | sort -u
}

# leaked OUTPUT TEXT...: fails when any TEXT is in OUTPUT, the recipe's output, on a command line
# the tools recorded, in a variable a command was started with, or in any file but the fake
# cluster's own, which holds the values by design, the fakes themselves, the record of OpenBao's
# requests, the bytes head returned and the trace of the script. The files searched include what
# the recipe removed or replaced, as the recorders of rm and mv kept it.
leaked() {
  local printed=$1 text
  shift
  for text; do
    [[ $printed != *"$text"* ]] || { echo "$text in the output"; return 1; }
    absent "$text" "$RECORD/argv" "$RECORD/environment" "$RECORD/digested"
    if grep -rlF --exclude-dir=state --exclude-dir=bin --exclude-dir=tools --exclude-dir=xtrace --exclude=requests \
      --exclude=head-output -- "$text" "$BATS_TEST_TMPDIR"; then
      echo "$text is in a file"
      return 1
    fi
  done
}

# made: the value the recipe that just ran made: the bytes head returned to it, in hexadecimal.
made() {
  od -An -vtx1 "$RECORD/head-output" | tr -d ' \n'
}

# digest VALUE: the SHA-256 digest of VALUE, as sha256sum writes it.
digest() {
  printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

# stored KEY: the key KEY of demo/hello in the fake store.
# shellcheck disable=SC2016 # $key is a jq variable.
stored() {
  "$JQ" -r --arg key "$1" '.[$key]' "$STATE/kv/demo/hello.json"
}

# pods: the names of hello's pods in the fake cluster that are not being deleted, on one line.
pods() {
  "$JQ" -r '.items[] | select(.metadata.namespace == "demo" and .metadata.labels["app.kubernetes.io/name"] == "hello"
    and .metadata.deletionTimestamp == null) | .metadata.name' "$STATE/pods.json" | sort | paste -sd' ' -
}

# line_of PATTERN [NTH]: the number of the NTH line of the record of command lines that matches
# PATTERN, the first when no NTH is given, and of the last with NTH last.
line_of() {
  local found
  found=$(grep -n -E -- "$1" "$RECORD/argv" | cut -d: -f1)
  [ -n "$found" ] || { echo "no command line matches $1" >&2; return 1; }
  if [[ ${2-1} == last ]]; then tail -n 1 <<<"$found"; else sed -n "${2-1}p" <<<"$found"; fi
}

# rotated VALUE: the fake cluster holds VALUE everywhere a rotation leaves it: in the store, beside
# the path's other key, in the Secret, and in each of hello's two pods, both new.
rotated() {
  [ "$(stored greeting)" = "$1" ] || { echo "the store does not hold the value"; return 1; }
  [ "$(stored other)" = keep-me ] || { echo "the path's other key is gone"; return 1; }
  [ "$("$JQ" -r '.greeting' "$STATE/secret/demo/hello.json")" = "$1" ] || { echo "the Secret does not hold the value"; return 1; }
  local pod count=0
  for pod in $(pods); do
    [[ $pod != hello-before-* ]] || { echo "$pod is a pod from before"; return 1; }
    [ "$(cat "$STATE/holds/demo/$pod")" = "$1" ] || { echo "$pod does not hold the value"; return 1; }
    count=$((count + 1))
  done
  [ "$count" -eq 2 ]
}

@test "secret-rotate shows its plan and changes nothing until the path is typed back" {
  local before plan question
  before=$(snapshot)
  # Something else than the path.
  answered no demo/hello greeting
  echo "another answer: $output"
  [ "$status" -ne 0 ]
  # The plan: the store's path and key and that a new value is made here; the ExternalSecret and
  # its Secret; the workload, its pods and the annotation that restarts it; the file and the
  # container the proof reads.
  [[ $output == *"greeting of secrets/demo/hello gets a new value, made here"* ]]
  [[ $output == *"ExternalSecret demo/hello writes it into the Secret demo/hello, as its key greeting"* ]]
  [[ $output == *"Deployment demo/hello, 2 pods, is restarted by Reloader through its annotation secret.reloader.stakater.com/reload"* ]]
  [[ $output == *"the proof reads /etc/hello/greeting in the container httpd"* ]]
  # All of it before the question, and the refusal after it.
  plan=${output%%"the proof reads"*}
  question=${output%%"Type demo/hello to rotate it"*}
  [ "${#plan}" -lt "${#question}" ] || { echo "the question comes before the plan"; return 1; }
  [[ ${output#"$question"} == *"demo/hello was not confirmed and is not rotated"* ]]
  reads_only "$before"
  [ ! -e "$STATE/forwards" ]
  # Each pod was digested where the plan says, and nothing else was run in a pod.
  [ "$(cat "$RECORD/digested")" = "$(printf '%s\n' 'demo hello-before-1 httpd /etc/hello/greeting' 'demo hello-before-2 httpd /etc/hello/greeting')" ]

  # The end of the input.
  recipe secret-rotate demo/hello greeting </dev/null
  echo "no answer: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"demo/hello was not confirmed and is not rotated"* ]]
  reads_only "$before"
  [ ! -e "$STATE/forwards" ]

  # The path typed back.
  answered demo/hello demo/hello greeting
  echo "confirmed: $output"
  [ "$status" -eq 0 ]
  [[ $output == *"Type demo/hello to rotate it"* ]]
  rotated "$(made)"

  # --yes asks nothing.
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "with --yes: $output"
  [ "$status" -eq 0 ]
  [[ $output != *"Type demo/hello"* ]]
  rotated "$(made)"
}

# shellcheck disable=SC2016 # $path and $key are yq and jq variables.
@test "secret-rotate refuses a key that a new value would break, before it reaches the cluster" {
  local path key rotation reason args before
  local -a listed
  # Each entry of the tree's list that is not generated, one without a key under a key no entry
  # names, and the keys the tree reads at the paths of those: refused with the entry's rotation,
  # its reason and where the docs say how such a key is rotated.
  mapfile -t listed < <(yq -o json -I0 '.secrets' "$ROOT/secret-rotation.yaml" |
    "$JQ" -r '.[] | select(.rotation != "generated") | .path + " " + (.key // "a-key-no-entry-names") + " " + .rotation')
  echo "not generated: ${listed[*]}"
  [ "${#listed[@]}" -ge 6 ]
  listed+=('volsync AWS_ACCESS_KEY_ID issued' 'volsync AWS_SECRET_ACCESS_KEY issued'
    'sso-system/dex github-client-id issued' 'sso-system/dex github-client-secret issued')
  for args in "${listed[@]}"; do
    read -r path key rotation <<<"$args"
    reason=$(yq -o json -I0 '.secrets' "$ROOT/secret-rotation.yaml" | "$JQ" -r --arg path "$path" --arg key "$key" \
      '([.[] | select(.path == $path and .key == $key)] + [.[] | select(.path == $path and (has("key") | not))])[0].reason')
    [ -n "$reason" ] && [ "$reason" != null ]
    recipe secret-rotate "$path" "$key" --yes </dev/null
    echo "$path $key: $output"
    refused_before_reaching "lists that key as $rotation, not as generated"
    [[ $output == *"$reason"* ]] || { echo "the entry's reason is not given"; return 1; }
    [[ $output == *"docs/kubernetes.md, Rotating an application's secret"* ]]
  done
  # A key, and a path, the list does not name: refused, saying to add its entry.
  for args in 'demo/hello other' 'demo/unknown greeting' 'ai-system/n8n greeting'; do
    # shellcheck disable=SC2086 # each case is its arguments, split.
    recipe secret-rotate $args --yes </dev/null
    echo "$args: $output"
    refused_before_reaching "names no such key at that path; add its entry"
  done

  # What is no key-value path and key, too few or too many arguments, an option it does not know
  # and a wait that is no whole number of seconds of at most nine digits. The cases with a marker
  # give a value where an argument goes, as a slip would: nothing it is given is echoed back.
  local -a cases=('' 'demo/hello' '../demo greeting' '/demo greeting' 'demo//hello greeting' 'demo/hello gre/eting'
    'demo/.. greeting' 'demo/hello -greeting' 'demo/hello marker-argument-value!' 'demo/hello greeting marker-argument-value'
    'demo/hello greeting --wait' 'demo/hello greeting --wait 12x' 'demo/hello greeting --wait=' 'demo/hello greeting --wait -1'
    'demo/hello greeting --wait 1234567890' 'demo/hello greeting --marker-argument-value' '--yes')
  for args in "${cases[@]}"; do
    # shellcheck disable=SC2086 # each case is its arguments, split.
    recipe secret-rotate $args </dev/null
    echo "secret-rotate $args: $output"
    refused_before_reaching "secret-rotate:"
    [[ $output != *marker-argument-value* && $output != *../demo* && $output != *gre/eting* && $output != *-greeting* ]] ||
      { echo "an argument is echoed"; return 1; }
    [[ $output != *12x* && $output != *1234567890* ]] || { echo "an argument is echoed"; return 1; }
  done
  recipe secret-rotate demo/hello greeting --wait 12x </dev/null
  [[ $output == *"--wait takes a whole number of seconds of at most 9 digits"* ]]

  # Without the list, or with one that is no list of entries, nothing is rotated.
  rm "$REPO/secret-rotation.yaml"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "no list: $output"
  refused_before_reaching "secret-rotation.yaml"
  echo 'secrets: generated' >"$REPO/secret-rotation.yaml"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "no list of entries: $output"
  refused_before_reaching "secret-rotation.yaml"
  # An entry of a rotation the recipe does not know is no generated entry.
  printf '%s\n' 'secrets:' '  - path: demo/hello' '    key: greeting' '    rotation: random' >"$REPO/secret-rotation.yaml"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "an unknown rotation: $output"
  refused_before_reaching "no rotation this recipe knows"

  # An entry that names the key decides before its path's entry without one, wherever each stands:
  # the path's other keys are refused with the path's entry, and the named key is rotated.
  printf '%s\n' 'secrets:' '  - path: demo/hello' '    rotation: issued' '    reason: marker-reason-of-the-path' \
    '  - path: demo/hello' '    key: greeting' '    rotation: generated' >"$REPO/secret-rotation.yaml"
  recipe secret-rotate demo/hello other --yes </dev/null
  echo "the path's entry: $output"
  refused_before_reaching "lists that key as issued, not as generated"
  [[ $output == *marker-reason-of-the-path* ]]
  before=$(snapshot)
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "the key's entry: $output"
  [ "$status" -eq 0 ]
  [ "$(snapshot)" != "$before" ]
  rotated "$(made)"
}

# shellcheck disable=SC2016 # each change is a command the test runs later, with its own variables.
@test "secret-rotate refuses what it could not prove, before it writes anything" {
  local before case change reason started
  # try CHANGE REASON: the cluster with CHANGE made to it, a command, is refused naming REASON.
  try() {
    cluster_state
    eval "$1"
    before=$(snapshot)
    recipe secret-rotate demo/hello greeting --yes </dev/null
    echo "$1: $output"
    refused "$before" "$2"
    [[ $output == *"nothing was written or changed"* ]] || { echo "it does not say that nothing changed"; return 1; }
    no_controls "$output"
  }
  # The ExternalSecret.
  try 'external "del(.spec.data)"' 'no ExternalSecret reads greeting of secrets/demo/hello from the ClusterSecretStore openbao'
  try 'external ".spec.secretStoreRef.name = \"another\""' 'no ExternalSecret reads greeting of secrets/demo/hello'
  try 'external "del(.spec.data[0].remoteRef.property)"' 'ExternalSecret demo/hello reads the whole secret at the path'
  try 'external ".spec.dataFrom = [{extract: {key: \"demo/hello\"}}] | del(.spec.data)"' 'ExternalSecret demo/hello reads every key at the path through a dataFrom extract'
  try 'external ".spec.dataFrom = [{find: {name: {regexp: \"hello\"}}}]"' 'ExternalSecret demo/hello finds keys by a pattern'
  try 'external ".spec.data += [.spec.data[0] | .secretKey = \"again\"]"' 'ExternalSecret demo/hello reads the key in more than one entry of spec.data'
  try 'external ".spec.data[0].remoteRef.version = \"3\""' 'ExternalSecret demo/hello reads the key with a version, a decoding, a conversion or a metadata policy'
  try 'external ".spec.data[0].remoteRef.decodingStrategy = \"Base64\""' 'ExternalSecret demo/hello reads the key with a version, a decoding, a conversion or a metadata policy'
  try 'external ".spec.target.template = {data: {greeting: \"{{ .greeting | upper }}\"}}"' 'ExternalSecret demo/hello writes its Secret through a template'
  try 'external ".spec.target.immutable = true"' 'ExternalSecret demo/hello writes an immutable Secret'
  try 'external ".spec.target.creationPolicy = \"None\""' 'ExternalSecret demo/hello creates no Secret'
  try 'external ".spec.target.manifest = {apiVersion: \"v1\", kind: \"ConfigMap\"}"' 'ExternalSecret demo/hello writes a target that is no Secret'
  try 'external ".spec.refreshPolicy = \"CreatedOnce\""' 'ExternalSecret demo/hello is not refreshed again once it has synced'
  try 'external ".spec.refreshInterval = \"0s\""' 'ExternalSecret demo/hello is not refreshed again once it has synced'
  # One that is not Ready: its condition, without the control characters its message holds, and
  # how a key the store does not hold yet is seeded.
  try 'external ".status.conditions = [{type: \"Ready\", status: \"False\", reason: \"SecretSyncedError\", message: \"could not get secret data from provider\u001b]0;marker-title\u0007\"}]"' \
    'ExternalSecret demo/hello is not Ready (SecretSyncedError: could not get secret data from provider'
  [[ $output == *"just bao-put demo/hello greeting"* ]]
  # A second ExternalSecret that reads the key another way stops the rotation as well.
  try '"$JQ" -c ".items += [.items[] | select(.metadata.namespace == \"demo\" and .metadata.name == \"hello\") | .metadata.name = \"copy\" | .spec.target.name = \"copy\" | del(.spec.data[0].remoteRef.property)]" "$STATE/es.json" >"$STATE/es.new" && mv "$STATE/es.new" "$STATE/es.json"' \
    'ExternalSecret demo/copy reads the whole secret at the path'
  # So does one that names the path with the mount and the key-value API's data in front, which
  # External Secrets' Vault provider reads as the same path.
  try '"$JQ" -c ".items += [.items[] | select(.metadata.namespace == \"demo\" and .metadata.name == \"hello\") | .metadata.name = \"copy\" | .spec.target.name = \"copy\" | .spec.data[0].remoteRef.key = \"secrets/data/demo/hello\" | del(.spec.data[0].remoteRef.property)]" "$STATE/es.json" >"$STATE/es.new" && mv "$STATE/es.new" "$STATE/es.json"' \
    'ExternalSecret demo/copy reads the whole secret at the path'

  # The workloads.
  try 'workload "del(.spec.template.spec.volumes[] | select(.secret != null)) | del(.spec.template.spec.containers[0].volumeMounts[] | select(.name == \"greeting\"))"' \
    'no Deployment, StatefulSet or DaemonSet of demo uses the Secret hello'
  try 'workload ".spec.template.spec.containers[0].env = [{name: \"GREETING\", valueFrom: {secretKeyRef: {name: \"hello\", key: \"greeting\"}}}]"' \
    'Deployment demo/hello takes the Secret hello through the environment of its container httpd'
  try 'workload ".spec.template.spec.containers[0].envFrom = [{secretRef: {name: \"hello\"}}]"' \
    'Deployment demo/hello takes the Secret hello through envFrom of its container httpd'
  try 'workload ".spec.template.spec.volumes += [{name: \"projected\", projected: {sources: [{secret: {name: \"hello\"}}]}}]"' \
    'Deployment demo/hello takes the Secret hello in a projected volume'
  try 'workload "(.spec.template.spec.containers[0].volumeMounts[] | select(.name == \"greeting\")) += {subPath: \"greeting\"}"' \
    'Deployment demo/hello mounts the Secret hello with a subPath in its container httpd'
  try 'workload "(.spec.template.spec.volumes[] | select(.secret != null)).secret.items = [{key: \"another\", path: \"another\"}]"' \
    'Deployment demo/hello mounts the Secret hello without its key greeting'
  try 'workload ".spec.template.spec.initContainers = [.spec.template.spec.containers[0] | .name = \"init\"] | del(.spec.template.spec.containers[0].volumeMounts[] | select(.name == \"greeting\"))"' \
    'Deployment demo/hello mounts the Secret hello in no container that keeps running'
  # Reloader's annotations, as the pinned Reloader reads them.
  try 'workload "del(.metadata.annotations[\"secret.reloader.stakater.com/reload\"])"' \
    'Deployment demo/hello carries no annotation by which Reloader restarts it when the Secret hello changes: secret.reloader.stakater.com/reload naming it, secret.reloader.stakater.com/auto or reloader.stakater.com/auto'
  try 'workload ".metadata.annotations[\"secret.reloader.stakater.com/reload\"] = \"another\""' \
    'Deployment demo/hello carries no annotation by which Reloader restarts it'
  # Only the Secret's own name counts: not a name that holds it, nor a pattern that matches it.
  try 'workload ".metadata.annotations[\"secret.reloader.stakater.com/reload\"] = \"hello-other\""' \
    'Deployment demo/hello carries no annotation by which Reloader restarts it'
  try 'workload ".metadata.annotations[\"secret.reloader.stakater.com/reload\"] = \"hel.*\""' \
    'Deployment demo/hello carries no annotation by which Reloader restarts it'
  try 'workload ".metadata.annotations = {\"reloader.stakater.com/auto\": \"false\"}"' \
    'Deployment demo/hello carries no annotation by which Reloader restarts it'
  # Annotations on the workload itself go before those of its pod template, which are then not read.
  try 'workload ".metadata.annotations = {\"reloader.stakater.com/auto\": \"false\"} | .spec.template.metadata.annotations = {\"secret.reloader.stakater.com/reload\": \"hello\"}"' \
    'Deployment demo/hello carries no annotation by which Reloader restarts it'
  try 'workload ".metadata.annotations[\"secrets.exclude.reloader.stakater.com/reload\"] = \"another, hello\""' \
    'Deployment demo/hello names the Secret hello in secrets.exclude.reloader.stakater.com/reload'
  # A rollout that would not come, or not for every pod.
  try 'workload ".spec.paused = true"' 'Deployment demo/hello is paused'
  try 'workload ".kind = \"StatefulSet\" | .spec.updateStrategy = {type: \"OnDelete\"}"' 'StatefulSet demo/hello replaces its pods only when they are deleted'
  try 'workload ".kind = \"StatefulSet\" | .spec.updateStrategy = {type: \"RollingUpdate\", rollingUpdate: {partition: 1}}"' 'StatefulSet demo/hello keeps the pods below its partition'
  try 'workload ".spec.selector.matchExpressions = [{key: \"tier\", operator: \"Exists\"}]"' 'Deployment demo/hello selects its pods with matchExpressions'
  try ': >"$STATE/in-rollout"' 'Deployment demo/hello is in the middle of a rollout'
  # The pods.
  try '"$JQ" -c "(.items[] | select(.metadata.namespace == \"demo\")).status.phase = \"Pending\"" "$STATE/pods.json" >"$STATE/pods.new" && mv "$STATE/pods.new" "$STATE/pods.json"' \
    'Deployment demo/hello has no running pod'
  try 'rm "$STATE/holds/demo/hello-before-2"' 'pod demo/hello-before-2 holds no file /etc/hello/greeting yet'
  [[ $output == *"just bao-put demo/hello greeting seeds a key"*"the kubelet fills the file within its sync period"* ]]
  try ': >"$STATE/no-sha256sum"' 'the container httpd of pod demo/hello-before-1 cannot digest /etc/hello/greeting with sha256sum'
  [[ $output == *"executable file not found"* ]]
  # An exec that does not answer stops the run, naming the pod, once its 30 seconds are up.
  try 'echo hello-before-2 >"$STATE/hung-exec"' \
    'the container httpd of pod demo/hello-before-2 did not answer within 30s when asked to digest /etc/hello/greeting'
  # Interrupted in an exec, as a terminal interrupts the whole process group: the run stops at
  # once, says that nothing changed, and leaves no exec running.
  cluster_state
  echo hello-before-2 >"$STATE/interrupt-exec"
  before=$(snapshot)
  started=$SECONDS
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "interrupted in an exec, after $((SECONDS - started))s: $output"
  [ "$status" -ne 0 ]
  [ "$((SECONDS - started))" -lt 15 ] || { echo "the run went on after the interrupt"; return 1; }
  [[ $output == *"nothing was written or changed"* ]]
  [[ $output != *"did not answer within"* ]]
  reads_only "$before"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$(cat "$STATE/exec-pid")" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "$(cat "$STATE/exec-pid")" 2>/dev/null; then
    echo "the exec still runs"
    return 1
  fi
  # The API server out of reach: kubectl's error says why without its address.
  try ': >"$STATE/api-unreachable"' 'Unable to connect to the server: dial tcp '
  [[ $output == *"i/o timeout"* && $output != *192.0.2.10* ]]

  # What is taken: the Secret named in a list, either automatic annotation, with the values Go
  # reads as true, and the pod template's annotations where the workload itself carries none of
  # Reloader's. Each reaches the plan, which names the annotation, and is declined there.
  local -a taken=(
    '.metadata.annotations["secret.reloader.stakater.com/reload"] = "another, hello"|secret.reloader.stakater.com/reload'
    '.metadata.annotations = {"reloader.stakater.com/auto": "true"}|reloader.stakater.com/auto'
    '.metadata.annotations = {"secret.reloader.stakater.com/auto": "True"}|secret.reloader.stakater.com/auto'
    '.metadata.annotations = {} | .spec.template.metadata.annotations = {"secret.reloader.stakater.com/reload": "hello"}|secret.reloader.stakater.com/reload'
  )
  for case in "${taken[@]}"; do
    change=${case%|*} reason=${case##*|}
    cluster_state
    workload "$change"
    before=$(snapshot)
    answered no demo/hello greeting
    echo "$change: $output"
    [[ $output == *"is restarted by Reloader through its annotation $reason"* ]]
    [[ $output == *"demo/hello was not confirmed and is not rotated"* ]]
    reads_only "$before"
  done
}

@test "secret-rotate writes a new value, has it refreshed, and proves that every pod is new and holds it" {
  local value stamp
  # The ExternalSecret refreshes at the third read of it after its annotation, and the generation
  # moves at the third read of the workload: the recipe has to ask until each has. The
  # ExternalSecret's status moving between the plan and the write, as Flux taking off an earlier
  # run's force-sync makes it, is not the refresh the recipe asks for.
  echo 3 >"$STATE/refresh-after"
  echo 3 >"$STATE/restart-after"
  : >"$STATE/resync-before-write"
  answered demo/hello demo/hello greeting
  echo "$output"
  [ "$status" -eq 0 ]
  # The value: 32 bytes of the kernel, which head read once, as 64 hexadecimal digits.
  [ "$(grep -c '^head ' "$RECORD/argv")" -eq 1 ]
  grep -qx 'head -c 32 /dev/urandom' "$RECORD/argv"
  value=$(made)
  [[ $value =~ ^[0-9a-f]{64}$ ]]
  rotated "$value"

  # It reached the store in one write, bao-put's: a merge patch of the one key, over TLS verified
  # against OpenBao's CA, with a token for the operator role that is revoked; nothing was read
  # from the store, and nothing else written to it.
  [ "$("$JQ" -r 'select(.path | startswith("secrets/")) | .method + " " + .path' "$RECORD/requests")" = 'PATCH secrets/data/demo/hello' ]
  [ "$(requests_of PATCH secrets/data/demo/hello | "$JQ" -c .)" = "{\"data\":{\"greeting\":\"$value\"}}" ]
  [ "$("$JQ" -r 'select(.method == "PATCH") | .type' "$RECORD/requests")" = application/merge-patch+json ]
  [ "$("$JQ" -r 'select(.tls != "verified") | .path' "$RECORD/requests")" = "" ]
  [ "$("$JQ" -r 'select(.path != "auth/kubernetes/login") | .token' "$RECORD/requests" | sort -u)" = marker-bao-token ]
  [ -e "$STATE/revoked" ]
  [ "$(by_path)" = "scripts/bao-put demo/hello greeting" ]
  [[ $output == *"bao-put: wrote greeting of secrets/demo/hello"* ]]

  # In order: every pod digested before anything is made; the write; the annotation, of the one
  # ExternalSecret that reads the key; reads of it until its status moved; reads of the workload
  # until its generation moved; the rollout, with a timeout within the wait; every new pod
  # digested.
  [ "$(line_of '^kubectl exec ' 2)" -lt "$(line_of '^head ')" ]
  [ "$(line_of '^head ')" -lt "$(line_of '^curl .*--request PATCH ')" ]
  [ "$(line_of '^curl .*--request PATCH ')" -lt "$(line_of '^kubectl annotate ')" ]
  [ "$(grep -c '^kubectl annotate ' "$RECORD/argv")" -eq 1 ]
  stamp=$(sed -n 's/^kubectl annotate externalsecrets\.external-secrets\.io hello --namespace demo force-sync=\([^ ]*\) --overwrite .*$/\1/p' "$RECORD/argv")
  echo "force-sync: ${stamp:-none}"
  [ -n "$stamp" ]
  [ "$("$JQ" -r '.items[] | select(.metadata.namespace == "demo" and .metadata.name == "hello") | .metadata.annotations["force-sync"]' "$STATE/es.json")" = "$stamp" ]
  # It is read once more between the write and the annotation, and then until its status moved.
  [ "$(grep -c '^kubectl get externalsecrets\.external-secrets\.io hello --namespace demo ' "$RECORD/argv")" -ge 4 ]
  [ "$(line_of '^curl .*--request PATCH ')" -lt "$(line_of '^kubectl get externalsecrets\.external-secrets\.io hello ')" ]
  [ "$(line_of '^kubectl get externalsecrets\.external-secrets\.io hello ')" -lt "$(line_of '^kubectl annotate ')" ]
  [ "$(line_of '^kubectl annotate ')" -lt "$(line_of '^kubectl get externalsecrets\.external-secrets\.io hello ' 2)" ]
  [ "$(grep -c '^kubectl get deployments\.apps hello --namespace demo ' "$RECORD/argv")" -ge 3 ]
  [ "$(line_of '^kubectl get externalsecrets\.external-secrets\.io hello ' last)" -lt "$(line_of '^kubectl get deployments\.apps hello ')" ]
  [ "$(grep -c '^kubectl rollout status deployments\.apps/hello --namespace demo --timeout=[0-9]*s$' "$RECORD/argv")" -eq 2 ]
  [ "$(line_of '^kubectl get deployments\.apps hello ' last)" -lt "$(line_of '^kubectl rollout status ' 2)" ]
  [[ $(sed -n "$(line_of '^kubectl rollout status ' 2)p" "$RECORD/argv") =~ --timeout=([0-9]+)s$ ]]
  [ "${BASH_REMATCH[1]}" -ge 1 ] && [ "${BASH_REMATCH[1]}" -le 300 ]
  [ "$(line_of '^kubectl rollout status ' 2)" -lt "$(line_of '^kubectl exec ' 3)" ]
  [ "$(cat "$RECORD/digested")" = "$(printf '%s\n' 'demo hello-before-1 httpd /etc/hello/greeting' \
    'demo hello-before-2 httpd /etc/hello/greeting' 'demo hello-g4-1 httpd /etc/hello/greeting' 'demo hello-g4-2 httpd /etc/hello/greeting')" ]

  # The cluster was changed by the annotation alone: no restart of the recipe's own, no patch, and
  # no Secret read but OpenBao's CA, which bao-put reads.
  [ "$(grep -E '^kubectl ' "$RECORD/argv" | cut -d' ' -f2 | sort -u | paste -sd' ' -)" = "annotate create exec get port-forward rollout" ]
  [ "$(grep -c '^kubectl rollout ' "$RECORD/argv")" -eq "$(grep -c '^kubectl rollout status ' "$RECORD/argv")" ]
  [ "$(grep -E '^kubectl get secrets? ' "$RECORD/argv" | sort -u)" = "kubectl get secret openbao-ca --namespace openbao --output jsonpath={.data.ca\.crt}" ]
  # The ExternalSecret and the workloads that the key is none of the business of were left alone.
  [ "$(grep -E '^kubectl (annotate|rollout|exec) ' "$RECORD/argv" | grep -cE 'other|cloudflare|volsync|elsewhere|oauth2')" -eq 0 ]

  # The last line: the key, the path, the pods and the workload, and the seconds since the
  # confirmation.
  echo "last line: ${lines[-1]}"
  [[ ${lines[-1]} =~ ^secret-rotate:\ greeting\ of\ secrets/demo/hello\ is\ rotated:\ 2\ pods\ of\ Deployment\ demo/hello\ are\ new\ and\ hold\ the\ new\ value,\ none\ the\ value\ from\ before\;\ ([0-9]+)s\ from\ the\ confirmation\ to\ the\ proof$ ]]
  [ "${BASH_REMATCH[1]}" -lt 120 ]
  forwards_closed

  # A second ExternalSecret, of another namespace, reads the key for a StatefulSet's one pod, which
  # mounts its Secret whole and is annotated for every Secret it uses: both are asked to refresh,
  # with one value, and both workloads restarted and proved. It names the path with the mount in
  # front, which External Secrets' Vault provider reads as the same path.
  cluster_state
  "$JQ" -c '.items += [.items[] | select(.metadata.namespace == "demo" and .metadata.name == "hello") | .metadata.namespace = "elsewhere"
    | .spec.data[0].remoteRef.key = "secrets/demo/hello"]' \
    "$STATE/es.json" >"$STATE/es.new" && mv "$STATE/es.new" "$STATE/es.json"
  "$JQ" -c '(.items[] | select(.metadata.namespace == "elsewhere" and .metadata.name == "hello")).metadata.annotations = {"reloader.stakater.com/auto": "true"}' \
    "$STATE/workloads.json" >"$STATE/workloads.new" && mv "$STATE/workloads.new" "$STATE/workloads.json"
  mkdir -p "$STATE/secret/elsewhere" "$STATE/holds/elsewhere"
  echo '{"greeting":"marker-greeting-before"}' >"$STATE/secret/elsewhere/hello.json"
  printf '%s' marker-greeting-before >"$STATE/holds/elsewhere/hello-0"
  echo 2 >"$STATE/refresh-after"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "two ExternalSecrets: $output"
  [ "$status" -eq 0 ]
  value=$(made)
  rotated "$value"
  [[ $output == *"ExternalSecret demo/hello has refreshed the Secret demo/hello"*"ExternalSecret elsewhere/hello has refreshed the Secret elsewhere/hello"* ]]
  [[ $output == *"ExternalSecret elsewhere/hello writes it into the Secret elsewhere/hello, as its key greeting"* ]]
  [[ $output == *"StatefulSet elsewhere/hello, 1 pod, is restarted by Reloader through its annotation reloader.stakater.com/auto"* ]]
  [[ $output == *"the proof reads /etc/hello/greeting in the container main"* ]]
  [ "$(grep -c '^kubectl annotate externalsecrets\.external-secrets\.io hello --namespace \(demo\|elsewhere\) ' "$RECORD/argv")" -eq 2 ]
  [ "$(sed -n 's/^kubectl annotate .* force-sync=\([^ ]*\) .*$/\1/p' "$RECORD/argv" | sort -u | grep -c .)" -eq 1 ]
  [ "$(grep -c '^kubectl rollout status statefulsets\.apps/hello --namespace elsewhere --timeout=[0-9]*s$' "$RECORD/argv")" -eq 2 ]
  [ "$(grep '^elsewhere ' "$RECORD/digested")" = "$(printf '%s\n' 'elsewhere hello-0 main /etc/hello/greeting' 'elsewhere hello-g2-1 main /etc/hello/greeting')" ]
  [ "$("$JQ" -r '.greeting' "$STATE/secret/elsewhere/hello.json")" = "$value" ]
  [ "$(cat "$STATE/holds/elsewhere/hello-g2-1")" = "$value" ]
  [[ ${lines[-1]} == "secret-rotate: greeting of secrets/demo/hello is rotated: 2 pods of Deployment demo/hello and 1 pod of StatefulSet elsewhere/hello are new and hold the new value, none the value from before; "*"s from the confirmation to the proof" ]]

  # One pod in all, of a DaemonSet, whose pods the fake counts by the same field: kubectl is asked
  # for the generation and the rollout of that kind.
  cluster_state
  workload '.kind = "DaemonSet" | .spec.replicas = 1'
  "$JQ" -c 'del(.items[] | select(.metadata.name == "hello-before-2"))' "$STATE/pods.json" >"$STATE/pods.new" && mv "$STATE/pods.new" "$STATE/pods.json"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "one pod: $output"
  [ "$status" -eq 0 ]
  [[ $output == *"DaemonSet demo/hello, 1 pod, is restarted"* ]]
  [ "$(grep -c '^kubectl get daemonsets\.apps hello --namespace demo ' "$RECORD/argv")" -ge 1 ]
  [ "$(grep -c '^kubectl rollout status daemonsets\.apps/hello --namespace demo --timeout=[0-9]*s$' "$RECORD/argv")" -eq 2 ]
  [[ ${lines[-1]} == "secret-rotate: greeting of secrets/demo/hello is rotated: 1 pod of DaemonSet demo/hello is new and holds the new value, none the value from before; "*"s from the confirmation to the proof" ]]

  # The Secret's key is named otherwise than the store's, and the file otherwise than both, under a
  # mount path written with a slash at its end: the proof reads the file the volume gives the
  # Secret's key.
  cluster_state
  external '.spec.data[0].secretKey = "salutation"'
  workload '(.spec.template.spec.volumes[] | select(.secret != null)).secret.items = [{key: "salutation", path: "word"}]
    | (.spec.template.spec.containers[0].volumeMounts[] | select(.name == "greeting")).mountPath = "/etc/hello/"'
  echo '{"salutation":"marker-greeting-before"}' >"$STATE/secret/demo/hello.json"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "another key and file: $output"
  [ "$status" -eq 0 ]
  [[ $output == *"ExternalSecret demo/hello writes it into the Secret demo/hello, as its key salutation"* ]]
  [[ $output == *"the proof reads /etc/hello/word in the container httpd"* ]]
  [ "$(cut -d' ' -f4 "$RECORD/digested" | sort -u)" = /etc/hello/word ]
  [ "$(grep -c . "$RECORD/digested")" -eq 4 ]
  [ "$("$JQ" -r '.salutation' "$STATE/secret/demo/hello.json")" = "$(made)" ]
  [ "$(stored greeting)" = "$(made)" ]

  # A wait of no seconds lets a refresh and a restart that are there at the first read pass, and
  # the rollout still gets a timeout, of one second: kubectl reads a timeout of zero as none.
  cluster_state
  echo 1 >"$STATE/restart-after"
  recipe secret-rotate demo/hello greeting --yes --wait 0 </dev/null
  echo "no wait: $output"
  [ "$status" -eq 0 ]
  [ "$(sed -n "$(line_of '^kubectl rollout status ' 2)p" "$RECORD/argv")" = 'kubectl rollout status deployments.apps/hello --namespace demo --timeout=1s' ]
  rotated "$(made)"
}

# shellcheck disable=SC2016 # the patterns name shell variables.
@test "secret-rotate prints neither the value nor a digest and puts neither on a command line" {
  local before=marker-greeting-before stale=marker-greeting-stale value targets
  # no_secrets VALUE...: neither a value, the digest of one nor a token got out.
  no_secrets() {
    local each
    for each in "$@" "$before"; do
      leaked "$output" "$each" "$(digest "$each")"
    done
    leaked "$output" marker-service-account-jwt marker-bao-token
  }
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "rotated: $output"
  [ "$status" -eq 0 ]
  value=$(made)
  no_secrets "$value"
  # The value travels in the body of the write, and in no other request.
  [ "$("$JQ" -r --arg value "$value" 'select(.body | contains($value)) | .method + " " + .path' "$RECORD/requests")" = 'PATCH secrets/data/demo/hello' ]
  # Every command ran by its name, so its command line is in the record, but bao-put, whose only
  # arguments are the path and the key.
  [ "$(by_path)" = "scripts/bao-put demo/hello greeting" ]

  # A proof that fails on a pod holding another value names the pod, not what either holds.
  cluster_state
  printf '%s' "$stale" >"$STATE/stale-pod"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "another value in a pod: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"pod demo/hello-g4-2 holds another value"* ]]
  no_secrets "$(made)" "$stale"
  # A refusal for a pod without the file, and a refresh that fails, say as little.
  cluster_state
  rm "$STATE/holds/demo/hello-before-1"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "a pod without the file: $output"
  [ "$status" -ne 0 ]
  no_secrets
  cluster_state
  : >"$STATE/refresh-fails"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "a refresh that fails: $output"
  [ "$status" -ne 0 ]
  no_secrets "$(made)"
  # A container whose sha256sum answers in another form is refused, and its answer, which holds
  # the digest of what the pod holds, is not shown as it came.
  cluster_state
  : >"$STATE/odd-sha256sum"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "an answer in another form: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"the container httpd of pod demo/hello-before-1 cannot digest /etc/hello/greeting with sha256sum"* ]]
  no_secrets
  # So is one whose digest stands so far into the line, on standard output and on standard error,
  # that cutting the line at 300 characters, as redact_stream does, would leave its first digits.
  cluster_state
  echo 259 >"$STATE/odd-sha256sum"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "an answer in another form, the digest far into the line: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"the container httpd of pod demo/hello-before-1 cannot digest /etc/hello/greeting with sha256sum"* ]]
  [[ $output != *"$(digest "$before" | cut -c1-10)"* ]] || { echo "the start of a digest is in the output"; return 1; }
  no_secrets

  # What a run writes and removes again within itself is not searched once it is gone, so the
  # script is read for it: every output redirection goes to /dev/null or to a descriptor, and it
  # makes no file or directory of its own. Placeholders such as <path> in messages, and >=, are no
  # redirections.
  targets=$(cd "$ROOT" && grep -vE '^[[:space:]]*#' scripts/secret-rotate | sed -E 's/<[A-Za-z]+>//g; s/[<>]=//g' |
    grep -oE '(^|[^<>&0-9-])[0-9]*(&>>|&>|>>|>\||>)[[:space:]]*("[^"]*"|&[0-9-]+|[^[:space:];|&)]+)' |
    sed -E 's/^.*(&>>|&>|>>|>\||>)[[:space:]]*//' | grep -vxE '/dev/null|&[0-9]+|&-' | sort -u) || true
  echo "written elsewhere: ${targets:-nothing}"
  [ -z "$targets" ]
  [ "$(grep -cE '(^|[^[:alnum:]_])(mktemp|tee|run_keeping_errors)([^[:alnum:]_]|$)' "$ROOT/scripts/secret-rotate")" -eq 0 ]
}

@test "A refresh that fails stops secret-rotate with the reason and with what the store now holds" {
  local value
  # said_what_is_left: the run says the three things an operator needs once the store was written.
  said_what_is_left() {
    [[ $output == *"the store holds the new value of greeting at secrets/demo/hello"* ]]
    [[ $output == *"the Secret follows at the next refresh by itself"* ]]
    [[ $output == *"a second run rotates again and proves it"* ]]
    [[ $output != *"and so do the Secrets"* ]]
  }
  # The ExternalSecret turns not Ready.
  : >"$STATE/refresh-fails"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "not Ready: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"ExternalSecret demo/hello turned not Ready when it was asked to refresh (SecretSyncedError: could not get secret data from provider?]0;marker-title?)"* ]]
  no_controls "$output"
  said_what_is_left
  # The store holds the new value and the Secret the one from before; no rollout was waited for.
  value=$(made)
  [ "$(stored greeting)" = "$value" ]
  [ "$("$JQ" -r '.greeting' "$STATE/secret/demo/hello.json")" = marker-greeting-before ]
  [ "$(grep -c '^kubectl rollout status ' "$RECORD/argv")" -eq 1 ]
  [ "$(grep -c '^kubectl get deployments\.apps hello ' "$RECORD/argv")" -eq 0 ]
  forwards_closed

  # The status stays as it was: the wait, one second, runs out.
  cluster_state
  : >"$STATE/refresh-stalls"
  recipe secret-rotate demo/hello greeting --yes --wait 1 </dev/null
  echo "no refresh: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"ExternalSecret demo/hello did not refresh within 1s of its annotation"* ]]
  said_what_is_left
  [ "$(stored greeting)" = "$(made)" ]
  [ "$(grep -c '^kubectl get externalsecrets\.external-secrets\.io hello ' "$RECORD/argv")" -ge 2 ]
  [ "$(grep -c '^kubectl rollout status ' "$RECORD/argv")" -eq 1 ]
  [[ $output != *"Reloader did not restart"* ]]
  forwards_closed

  # The recipe interrupted while it waits for the refresh: it stops at that read, and asks no more.
  cluster_state
  : >"$STATE/refresh-stalls"
  : >"$STATE/interrupt-refresh"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "interrupted: $output"
  [ "$status" -ne 0 ]
  said_what_is_left
  [ "$(grep -c '^kubectl annotate ' "$RECORD/argv")" -eq 1 ]
  [ "$(grep -c '^kubectl get externalsecrets\.external-secrets\.io hello ' "$RECORD/argv")" -eq 2 ]
  [[ $output != *"did not refresh within"* ]]
  forwards_closed

  # OpenBao refuses the write: bao-put says so and confirms nothing, and no refresh is asked for.
  cluster_state
  : >"$STATE/write-refused"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "write refused: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"OpenBao answered 403 to PATCH secrets/data/demo/hello"* ]]
  [[ $output == *"bao-put did not confirm the write: the store holds the value from before or the new one"* ]]
  [[ $output != *"the store holds the new value of greeting"* ]]
  [ "$(stored greeting)" = marker-greeting-before ]
  [ "$(grep -c '^kubectl annotate ' "$RECORD/argv")" -eq 0 ]
  forwards_closed

  # The recipe interrupted while bao-put writes: bao-put finishes, closes its port-forward, and
  # the recipe stops, not having heard whether the store took the write.
  cluster_state
  : >"$STATE/interrupt-write"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "interrupted during the write: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"bao-put did not confirm the write: the store holds the value from before or the new one"* ]]
  [ "$(grep -c '^kubectl annotate ' "$RECORD/argv")" -eq 0 ]
  forwards_closed
}

@test "A restart that does not come, or a pod that holds another value, fails secret-rotate" {
  local value
  # said_refreshed: what the run says once the Secret has refreshed: it holds the new value as the
  # store does, the running pods' files follow it, and a second run proves it; not that the Secret
  # follows at a refresh to come, or that Reloader restarts the workloads then.
  said_refreshed() {
    [[ $output == *"the store holds the new value of greeting at secrets/demo/hello, and so do the Secrets"* ]]
    [[ $output == *"the running pods' files take it within the kubelet's sync period"* ]]
    [[ $output == *"a second run rotates again and proves it"* ]]
    [[ $output != *"follows at the next refresh"* ]]
    [[ $output != *"Reloader restarts the workloads"* ]]
  }
  # A generation that does not move: Reloader did not restart the workload, and once it has seen the
  # change will not restart it for that change by itself; one that sees the change late still may.
  : >"$STATE/no-restart"
  recipe secret-rotate demo/hello greeting --yes --wait 1 </dev/null
  echo "no restart: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"Reloader did not restart Deployment demo/hello within 1s of the refresh: its generation did not move"* ]]
  [[ $output == *"once Reloader has seen this change it will not restart the workload for it by itself, and one that has not seen it yet may still"* ]]
  [[ $output == *"the store holds the new value of greeting at secrets/demo/hello"* ]]
  said_refreshed
  # The Secret holds the new value; the pods are the ones from before; no rollout was waited for.
  value=$(made)
  [ "$("$JQ" -r '.greeting' "$STATE/secret/demo/hello.json")" = "$value" ]
  [ "$(pods)" = "hello-before-1 hello-before-2" ]
  [ "$(grep -c '^kubectl get deployments\.apps hello ' "$RECORD/argv")" -ge 1 ]
  [ "$(grep -c '^kubectl rollout status ' "$RECORD/argv")" -eq 1 ]
  forwards_closed

  # A rollout that does not finish. The wait, written with a zero in front, is thirty seconds, not
  # the twenty-four of an octal number.
  cluster_state
  : >"$STATE/rollout-stuck"
  recipe secret-rotate demo/hello greeting --yes --wait 030 </dev/null
  echo "rollout stuck: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"the rollout of Deployment demo/hello did not finish within the 30s the restart is given"* ]]
  [[ $output == *"timed out waiting for the condition"* ]]
  [[ $output == *"the store holds the new value of greeting at secrets/demo/hello"* ]]
  said_refreshed
  [[ $output != *"Reloader did not restart"* ]]
  forwards_closed

  # The last new pod holds another value: it is named, and the first, which holds the new one, is
  # not.
  cluster_state
  printf '%s' marker-greeting-stale >"$STATE/stale-pod"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "another value in a pod: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"pod demo/hello-g4-2 holds another value than the one written"* ]]
  [[ $output != *"pod demo/hello-g4-1 "* ]]
  [[ $output == *"the store holds the new value of greeting at secrets/demo/hello"* ]]
  said_refreshed
  [[ $output != *"is rotated"* ]]
  forwards_closed

  # The last new pod holds no file.
  cluster_state
  : >"$STATE/empty-pod"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "no file in a pod: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"pod demo/hello-g4-2 holds no file /etc/hello/greeting"* ]]
  [[ $output == *"the store holds the new value of greeting at secrets/demo/hello"* ]]
  said_refreshed
  [[ $output != *"is rotated"* ]]

  # A pod from before that stays, though the kubelet has written the new value into its file, is
  # no new pod.
  cluster_state
  : >"$STATE/kept-pod"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "a pod from before: $output"
  [ "$status" -ne 0 ]
  [ "$(cat "$STATE/holds/demo/hello-before-1")" = "$(made)" ]
  [[ $output == *"pod demo/hello-before-1 is a pod from before the rotation"* ]]
  [[ $output == *"the store holds the new value of greeting at secrets/demo/hello"* ]]
  said_refreshed
  [[ $output != *"is rotated"* ]]
  forwards_closed

  # A pod from before that is being deleted is not counted: it is gone within its grace period.
  cluster_state
  : >"$STATE/terminating-pod"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "a pod being deleted: $output"
  [ "$status" -eq 0 ]
  [ "$("$JQ" -r '.items[] | select(.metadata.deletionTimestamp != null) | .metadata.name' "$STATE/pods.json")" = hello-before-2 ]
  [ "$(cat "$STATE/holds/demo/hello-before-2")" = marker-greeting-before ]
  [ "$(grep -c ' hello-before-2 ' "$RECORD/digested")" -eq 1 ]
  [[ ${lines[-1]} == *"2 pods of Deployment demo/hello are new and hold the new value"* ]]
}

# shellcheck disable=SC2016 # the dollars are the fakes' own.
@test "A second run of secret-rotate rotates again, also after a run that stopped half way" {
  local first second third stamp_first stamp_second before real_date
  # stamp: the force-sync value the run that just ended set.
  stamp() {
    sed -n 's/^kubectl annotate .* force-sync=\([^ ]*\) .*$/\1/p' "$RECORD/argv"
  }
  # The clock stands still: two runs start in the same second.
  real_date=$(command -v date)
  { prelude date; printf 'exec %q --date @1767225600 "$@"\n' "$real_date"; } | fake_tool date
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "first: $output"
  [ "$status" -eq 0 ]
  first=$(made)
  stamp_first=$(stamp)
  rotated "$first"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "second: $output"
  [ "$status" -eq 0 ]
  second=$(made)
  stamp_second=$(stamp)
  # A value of its own, on pods that are new again, asked for with a force-sync value of its own.
  [ "$second" != "$first" ]
  rotated "$second"
  [ "$(pods)" = "hello-g5-1 hello-g5-2" ]
  echo "force-sync: $stamp_first then $stamp_second"
  [ -n "$stamp_first" ] && [ -n "$stamp_second" ]
  [ "$stamp_first" != "$stamp_second" ]

  # A run that was declined changed nothing, and the next one rotates.
  before=$(snapshot)
  answered no demo/hello greeting
  [ "$status" -ne 0 ]
  reads_only "$before"
  # A run whose refresh never came: the store holds its value, the Secret and the pods the one
  # before it. The next run writes again and proves, whatever the pods held.
  : >"$STATE/refresh-stalls"
  recipe secret-rotate demo/hello greeting --yes --wait 1 </dev/null
  echo "stopped half way: $output"
  [ "$status" -ne 0 ]
  third=$(made)
  [ "$(stored greeting)" = "$third" ]
  [ "$(cat "$STATE/holds/demo/hello-g5-1")" = "$second" ]
  rm "$STATE/refresh-stalls"
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "after it: $output"
  [ "$status" -eq 0 ]
  [ "$(made)" != "$third" ]
  rotated "$(made)"
  forwards_closed

  # A kernel that gives the bytes it gave before: the value is the one the pods hold already, and
  # the run stops before it writes anything.
  { prelude head; printf 'printf "%%032d" 7 | %q -a "$RECORD/head-output"\n' "$(command -v tee)"; } | fake_tool head
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "the kernel's bytes, first: $output"
  [ "$status" -eq 0 ]
  before=$(snapshot)
  recipe secret-rotate demo/hello greeting --yes </dev/null
  echo "the same bytes again: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"the value made is one a pod already holds"* ]]
  [ "$(grep -c -E '^(curl|kubectl annotate) ' "$RECORD/argv")" -eq 0 ]
  [ "$(snapshot)" = "$before" ]
}

# shellcheck disable=SC2016 # the dollars are the fakes' own.
@test "secret-rotate takes its answer from a pipe whatever its tools read" {
  local before
  # Each of these reads all of the standard input it is started with, as the fake kubectl does.
  greedy sleep date yq
  { prelude head; printf '%q > /dev/null\nset -o pipefail\n%q "$@" | %q -a "$RECORD/head-output"\n' "$TOOLS/cat" "$(command -v head)" "$(command -v tee)"; } |
    fake_tool head
  answered demo/hello demo/hello greeting
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"Type demo/hello to rotate it"* ]]
  rotated "$(made)"
  # No command the recipe started, bao-put's among them, held the operator's standard input.
  echo "started with the operator's standard input: $(sort -u "$RECORD/inherited" 2>/dev/null | paste -sd' ' -)"
  [ ! -e "$RECORD/inherited" ]
  [ "$(grep -c -E '^(kubectl|sleep|date|yq|head|jq|curl|sha256sum|od|tr|sed|dirname) ' "$RECORD/argv")" -gt 20 ]

  # Nor in a run that is declined, which reads the answer after its tools have run.
  before=$(snapshot)
  answered no demo/hello greeting
  echo "declined: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"demo/hello was not confirmed and is not rotated"* ]]
  reads_only "$before"
  [ ! -e "$RECORD/inherited" ]
}
