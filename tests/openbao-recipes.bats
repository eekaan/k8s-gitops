#!/usr/bin/env bats
# Proves the recipe scenarios of features/openbao.feature; each test carries its scenario's title.
# The recipes run from a copy of the repository against recording fakes of kubectl and curl: a
# cluster whose port-forward runs until it is stopped, and an OpenBao behind it that answers as its
# API does. age and age-keygen are the pinned ones, offline, with a throwaway key in the test's
# directory. The recipes' PATH holds only the fakes, recorders and bash: every other command they
# run by its name is a recorder of the real one, so its command line is in the record, and a command
# no recorder names is not found. bash traces the recipes' scripts, so a test can show that they ran
# no command by its path, past the recorders. The recorders of rm and mv keep a copy of what they
# remove, and the recorder of head what it returned.

# The fakes keep their state in each test's own directory, and a test waits for the port-forwards
# it started; nothing is shared between tests, which may run side by side.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  JUST=$(command -v just)
  JQ=$(command -v jq)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$BIN" "$RECORD/removed" "$STATE/kv" "$BATS_TEST_TMPDIR/repo/talos/lab-sto2/clusterconfig" \
    "$BATS_TEST_TMPDIR/keys" "$BATS_TEST_TMPDIR/custody" "$BATS_TEST_TMPDIR/tmp" "$BATS_TEST_TMPDIR/xtrace"
  : >"$RECORD/argv"
  REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd)
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp "$ROOT/talos/.sops.yaml" "$REPO/talos/.sops.yaml"
  # The kubeconfig the recipes point kubectl at; the fake reads none.
  : >"$REPO/talos/lab-sto2/clusterconfig/kubeconfig"
  # The Talos age key, a throwaway one; its recipient is what talos/.sops.yaml names.
  age-keygen -o "$BATS_TEST_TMPDIR/keys/talos.agekey" 2>/dev/null
  RECIPIENT=$(age-keygen -y "$BATS_TEST_TMPDIR/keys/talos.agekey")
  RECIPIENT=$RECIPIENT yq -i '.creation_rules[].age = strenv(RECIPIENT)' "$REPO/talos/.sops.yaml"
  CUSTODY="$BATS_TEST_TMPDIR/custody/openbao.age"
  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise </dev/null
  # The shell the recipes and the fakes run in is the one command outside the record.
  SYS="$BATS_TEST_TMPDIR/sys"
  mkdir -p "$SYS"
  ln -s "$(command -v bash)" "$SYS/bash"
  record jq age base64 cat sed grep awk tr env od sha256sum cut date mktemp ln mkdir chmod \
    dirname basename realpath yq paste sort wc sleep
  record_head
  record_removal rm mv
  record_stat
  # bash reads this file before a script runs, and traces each command a recipe's script runs, as
  # it runs it, into a file of xtrace; the fakes and just's shell are not traced. The recipes refuse
  # to run while traced, unless the trace goes to a file in BAO_TESTS_XTRACE_DIR, which only this
  # file sets (scripts/lib/openbao.sh).
  cat >"$BATS_TEST_TMPDIR/bash-env" <<EOF
if [[ \$0 == *scripts/bao-* ]]; then
  exec 9>> "$BATS_TEST_TMPDIR/xtrace/\$\$"
  BAO_TESTS_XTRACE_DIR="$BATS_TEST_TMPDIR/xtrace" BASH_XTRACEFD=9 PS4='+xtrace '
  set -x
fi
EOF
  fake_cluster
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

# fake_tool NAME: like fake, with RECORD, STATE and JQ, the real jq, set in the fake for its body.
fake_tool() {
  { printf 'RECORD=%q STATE=%q JQ=%q\n' "$RECORD" "$STATE" "$JQ"; cat; } | fake "$1"
}

# record NAME...: puts each NAME's arguments in the record, then runs the real NAME.
record() {
  local tool real
  for tool; do
    real=$(command -v "$tool")
    fake "$tool" <<EOF
printf '%s\n' "$tool \$*" >> "$RECORD/argv"
exec "$real" "\$@"
EOF
  done
}

# record_head: like record for head, and keeps every byte head returns in $RECORD/head-output.
record_head() {
  fake head <<EOF
printf '%s\n' "head \$*" >> "$RECORD/argv"
set -o pipefail
"$(command -v head)" "\$@" | "$(command -v tee)" -a "$RECORD/head-output"
EOF
}

# record_removal NAME...: like record, and first copies each path NAME is given that exists into a
# directory of its own under $RECORD/removed, which leaked searches: what a recipe writes and
# removes again, or replaces, is seen there. The fakes' own state is not copied.
record_removal() {
  local tool real
  for tool; do
    real=$(command -v "$tool")
    fake "$tool" <<EOF
printf '%s\n' "$tool \$*" >> "$RECORD/argv"
kept=\$("$(command -v mktemp)" -d "$RECORD/removed/$tool.XXXXXXXXXX")
for operand; do
  if [[ \$operand != -* && \$operand != "$STATE"/* ]] && [[ -e \$operand || -L \$operand ]]; then
    "$(command -v cp)" -R -- "\$operand" "\$kept/"
  fi
done
exec "$real" "\$@"
EOF
  done
}

# record_stat: like record for stat, and reports another user, 65534, as the owner of each path
# $STATE/foreign lists, as a test cannot make a file another user's. The recipes ask for the owner
# first: stat -c '%u %a'.
record_stat() {
  fake_tool stat <<EOF
printf '%s\n' "stat \$*" >> "\$RECORD/argv"
out=\$("$(command -v stat)" "\$@") || exit
if [[ -f \$STATE/foreign ]] && grep -qxF -- "\${@: -1}" "\$STATE/foreign"; then
  out="65534 \${out#* }"
fi
printf '%s\n' "\$out"
EOF
}

# recipe NAME [ARG...]: runs the repository's recipe against the copy, with only what it needs in
# its environment, the Talos age key's location included. A recipe that blocks fails after two
# minutes instead of hanging the tests.
recipe() {
  run timeout 120 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$SYS" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    SOPS_AGE_KEY_FILE="$BATS_TEST_TMPDIR/keys/talos.agekey" BASH_ENV="$BATS_TEST_TMPDIR/bash-env" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$@"
}

# by_name: every command the recipes' scripts ran, as bash traced it, ran by its name and through a
# recorder, so its command line is in the record: none ran by a path, which bypasses the recorders,
# and none was a shell, which is outside the record. The command is the first word after any
# assignments, and after exec, command, builtin, env, nohup or time with their options and
# assignments; bash quotes a word that holds a space, which is read back as one word. Prints only
# the commands that broke the rule, never their arguments.
by_name() {
  local found
  [ -n "$(ls -A "$BATS_TEST_TMPDIR/xtrace")" ] || { echo "no script was traced"; return 1; }
  # shellcheck disable=SC2016 # awk's own fields and variables.
  found=$(cat "$BATS_TEST_TMPDIR"/xtrace/* | awk '
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
      if (i <= n && (word[i] ~ /\// || word[i] ~ /^(bash|sh|dash|zsh|ksh|mksh|busybox)$/)) print word[i]
    }' | sort -u)
  echo "run by a path or as a shell: ${found:-none}"
  [ -z "$found" ]
}

# custody_file KEY: writes a custody file, as bao-recovery does, holding the five marker shares and
# the seal key KEY, encrypted to the Talos age key, at CUSTODY.
# shellcheck disable=SC2016 # $key is a jq variable.
custody_file() {
  "$JQ" -n --arg key "$1" '{cluster: "lab-sto2", recovery: {shares: 5, threshold: 3,
    keys_base64: [range(5) | "marker-recovery-share-\(. + 1)" | @base64]},
    seal: {secret: "openbao-seal-1", key_id: "openbao-seal-1", key: $key}}' |
    age --encrypt --recipient "$RECIPIENT" --output "$CUSTODY"
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

# forwards_closed: every port-forward a recipe started has stopped, and the recipe's private
# directory is gone.
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

# fake_cluster: a fake kubectl and a fake OpenBao behind its port-forward. What they do is set by
# files in STATE:
#   login-refused     OpenBao refuses the login
#   write-refused     OpenBao refuses every write to the key-value mount
#   create-refused    OpenBao refuses a POST to the key-value mount, and answers a patch as usual
#   kv-fails          OpenBao fails every write to the key-value mount with a server error
#   kv-noisy          ... with a server error whose text holds terminal control characters
#   api-unreachable   kubectl cannot reach the API server to mint a token or read a Secret, and says
#                     so naming its address, with terminal control characters
#   unreachable       no request to the key-value mount reaches OpenBao: curl fails to connect
#   no-forward        the port-forward fails to start
#   interrupt         curl sends SIGINT to the recipe's script at the request whose path it names,
#   interrupt-at      at the Nth request to that path (the first when absent)
#   interrupt-drops   the interrupted request is lost: curl fails before OpenBao gets it, where
#                     without it the request goes through
#   recovery-shares   how many recovery key shares exist; none when absent
#   stale-rotation    a rotation of the recovery keys is in progress already
#   clobber           curl writes that file, as someone else would, when the rotation starts or a
#                     key of the key-value mount is patched
#   root-refused      OpenBao refuses the second recovery key share for a root token
#   stale-root        a root token generation is in progress already
#   lookup-refused    OpenBao fails every token lookup
#   orphan-refused    OpenBao refuses to make an orphan token
#   root-revoke-fails, orphan-revoke-fails
#                     OpenBao fails to revoke the root token, or the orphan token
#   events            what happened to the root and orphan tokens, and the command, in order
#   seal-secret       the Secret openbao-seal-1 as JSON; absent when the file is
#   kv/<path>.json    the data of a secret at <path> in the key-value mount
#   outfile           the custody file, which must exist when the rotation is verified
# Every request is appended to $RECORD/requests as one JSON object: its method, path, body, the
# token header and whether it reached OpenBao by its certificate's name and verified it against
# OpenBao's CA.
fake_cluster() {
  fake_tool kubectl <<'EOF'
printf '%s\n' "kubectl $*" >> "$RECORD/argv"
case " $* " in
  *" port-forward "*)
    if [[ -e $STATE/no-forward ]]; then
      echo "error: unable to forward" >&2
      exit 1
    fi
    echo "Forwarding from 127.0.0.1:41234 -> 8200"
    echo "Forwarding from [::1]:41234 -> 8200"
    echo "$$" >> "$STATE/forwards"
    exec sleep 600
    ;;
  *" create token openbao-operator "* | *" get secret openbao-ca "*)
    if [[ -e $STATE/api-unreachable ]]; then
      printf 'Unable to connect to the server: dial tcp 192.0.2.10:6443: i/o timeout\033]0;marker-title\007\n' >&2
      exit 1
    fi
    ;;&
  *" create token openbao-operator "*)
    echo marker-service-account-jwt
    ;;
  *" get secret openbao-ca "*)
    printf -- '-----BEGIN CERTIFICATE-----\nmarker-ca\n-----END CERTIFICATE-----\n' | base64 -w0
    ;;
  *" get secret openbao-seal-1 "*" --ignore-not-found "*)
    cat "$STATE/seal-secret" 2> /dev/null || true
    ;;
  *" get secret openbao-seal-1 "*)
    "$JQ" -n --arg key "$(printf marker-seal-key | base64 -w0)" '{data: {key: $key}}'
    ;;
  *" delete secret openbao-seal-1 "*)
    rm "$STATE/seal-secret"
    : > "$STATE/seal-deleted"
    ;;
  *" create "*"--filename -"*)
    created=$(cat)
    [[ ! -e $STATE/seal-secret ]] || { echo 'Error from server (AlreadyExists)' >&2; exit 1; }
    printf '%s\n' "$created" > "$STATE/seal-secret"
    printf '%s\n' "$created" > "$STATE/seal-created"
    ;;
  *)
    echo "fake kubectl: unexpected kubectl $*" >&2
    exit 1
    ;;
esac
EOF
  fake_tool curl <<'EOF'
printf '%s\n' "curl $*" >> "$RECORD/argv"
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
"$JQ" -nc --arg method "$method" --arg path "$path" --arg body "$body" --arg token "$token" --arg tls "$tls" \
  --arg type "$(sed -n 's/^Content-Type: //p' <<< "$headers")" \
  '{method: $method, path: $path, body: $body, token: $token, tls: $tls, type: $type}' >> "$RECORD/requests"
if [[ -e $STATE/interrupt && $(< "$STATE/interrupt") == "$path" ]]; then
  # Counted per path, so a count left from an interrupt at another path does not carry over.
  read -r counted count < "$STATE/interrupt-count" 2> /dev/null || counted="" count=0
  [[ $counted == "$path" ]] || count=0
  count=$((count + 1))
  echo "$path $count" > "$STATE/interrupt-count"
  if ((count == $(cat "$STATE/interrupt-at" 2> /dev/null || echo 1))); then
    # The nearest process running the recipe's script: the first ancestor whose command line names
    # it, then past the subshells of its pipelines, which share its command line, up to the last
    # one before an ancestor that does not; never a process further up.
    pid=$PPID target=""
    while ((pid > 1)); do
      if tr '\0' ' ' < "/proc/$pid/cmdline" | grep -qE '(^| )scripts/bao-'; then
        target=$pid
      elif [[ -n $target ]]; then
        break
      fi
      pid=$(awk '{print $4}' "/proc/$pid/stat")
    done
    kill -INT "$target"
    # The request is lost on the way when the state says so, and never reaches OpenBao.
    [[ ! -e $STATE/interrupt-drops ]] || exit 28
  fi
fi
if [[ -e $STATE/unreachable && $path == secrets/* ]]; then
  echo "curl: (7) Failed to connect to openbao-active.openbao.svc port 8200 after 0 ms: Could not connect to server" >&2
  exit 7
fi
respond() {
  printf '%s' "$2"
  if [[ -n $write_out ]]; then printf '\n%s' "$1"; fi
  exit 0
}
# envelope DATA: a response of OpenBao's logical backend, as its HTTP layer writes one: the
# handler's fields under data, beside the request's metadata.
envelope() {
  printf '{"request_id":"fake","lease_id":"","renewable":false,"lease_duration":0,"data":%s,"wrap_info":null,"warnings":null,"auth":null}' "$1"
}
recovery=$(cat "$STATE/recovery-shares" 2> /dev/null || echo 0)
case $path in
  sys/seal-status | sys/decode-token | auth/kubernetes/login) ;;
  auth/token/revoke-self | auth/token/lookup-self)
    [[ $token == marker-bao-token || $token == marker-root-token || $token == marker-orphan-token ]] ||
      respond 403 '{"errors":["permission denied"]}'
    ;;
  auth/token/create-orphan)
    [[ $token == marker-root-token ]] || respond 403 '{"errors":["permission denied"]}'
    ;;
  # Deleting a key's versions and metadata is the root policy's, never the operator's.
  secrets/metadata/*)
    [[ $token == marker-orphan-token ]] || respond 403 '{"errors":["permission denied"]}'
    ;;
  *) [[ $token == marker-bao-token ]] || respond 403 '{"errors":["permission denied"]}' ;;
esac
case "$method $path" in
  "POST auth/kubernetes/login")
    [[ -e $STATE/login-refused ]] && respond 400 '{"errors":["permission denied"]}'
    if [[ $("$JQ" -r '.role + " " + .jwt' <<< "$body") == "operator marker-service-account-jwt" ]]; then
      # The auth method answers a login under auth (internal/builtin/credential/kubernetes/path_login.go).
      respond 200 '{"request_id":"fake","lease_id":"","renewable":false,"lease_duration":0,"data":null,"wrap_info":null,"warnings":null,"auth":{"client_token":"marker-bao-token","accessor":"marker-accessor","policies":["operator"],"token_policies":["operator"],"lease_duration":600,"renewable":true}}'
    fi
    respond 400 '{"errors":["invalid role or service account"]}'
    ;;
  "POST auth/token/revoke-self")
    case $token in
      marker-root-token)
        [[ -e $STATE/root-revoke-fails ]] && respond 500 '{"errors":["failed to revoke token"]}'
        : > "$STATE/root-revoked" && echo "revoked root" >> "$STATE/events"
        ;;
      marker-orphan-token)
        [[ -e $STATE/orphan-revoke-fails ]] && respond 500 '{"errors":["failed to revoke token"]}'
        : > "$STATE/orphan-revoked" && echo "revoked orphan" >> "$STATE/events"
        ;;
      *) : > "$STATE/revoked" ;;
    esac
    respond 204 ''
    ;;
  # The token store answers a lookup under data, the token's own ID among its fields
  # (handleLookup in internal/vault/token_store.go in OpenBao v2.7.2).
  "GET auth/token/lookup-self")
    [[ -e $STATE/lookup-refused ]] && respond 500 '{"errors":["internal error"]}'
    case $token in
      marker-root-token) accessor=marker-root-accessor policies='["root"]' orphan=true ttl=0 && echo "looked up root" >> "$STATE/events" ;;
      marker-orphan-token) accessor=marker-orphan-accessor policies='["root"]' orphan=true ttl=900 ;;
      *) accessor=marker-accessor policies='["operator"]' orphan=true ttl=600 ;;
    esac
    respond 200 "$(envelope "{\"id\":\"$token\",\"accessor\":\"$accessor\",\"policies\":$policies,\"path\":\"auth/token/create\",\"meta\":null,\"display_name\":\"token\",\"num_uses\":0,\"orphan\":$orphan,\"creation_time\":1763078400,\"creation_ttl\":$ttl,\"expire_time\":null,\"ttl\":$ttl,\"explicit_max_ttl\":0,\"entity_id\":\"\",\"type\":\"service\"}")"
    ;;
  # The token store answers a new token under auth (internal/vault/token_store.go in OpenBao v2.7.2).
  "POST auth/token/create-orphan")
    [[ -e $STATE/orphan-refused ]] && respond 400 '{"errors":["permission denied"]}'
    "$JQ" -c . <<< "$body" > "$STATE/orphan-request"
    echo "minted orphan" >> "$STATE/events"
    respond 200 '{"request_id":"fake","lease_id":"","renewable":false,"lease_duration":0,"data":null,"wrap_info":null,"warnings":null,"auth":{"client_token":"marker-orphan-token","accessor":"marker-orphan-accessor","policies":["root"],"token_policies":["root"],"lease_duration":900,"renewable":false,"orphan":true}}'
    ;;
  # The key-value backend answers a patch of a key that has no metadata with 404, and tests the
  # request's check-and-set option against the key's current version, 1 or more here, before it
  # writes (pathDataPatch in internal/builtin/logical/kv/path_data.go in OpenBao v2.7.2).
  "PATCH secrets/data/"*)
    if [[ -e $STATE/clobber ]]; then echo someone-else > "$(cat "$STATE/clobber")"; fi
    [[ -e $STATE/write-refused ]] && respond 403 '{"errors":["permission denied"]}'
    [[ -e $STATE/kv-fails ]] && respond 500 '{"errors":["internal error"]}'
    [[ -e $STATE/kv-noisy ]] && respond 500 '{"errors":["internal \u001b[31merror\u0007 \u009b2J done"]}'
    file=$STATE/kv/${path#secrets/data/}.json
    [[ -f $file ]] || respond 404 '{"errors":[]}'
    if [[ $("$JQ" -r '.options.cas // "unset"' <<< "$body") == 0 ]]; then
      respond 400 '{"errors":["check-and-set parameter did not match the current version"]}'
    fi
    "$JQ" -c --argjson patch "$("$JQ" -c '.data' <<< "$body")" '. * $patch' "$file" > "$file.new" && mv "$file.new" "$file"
    respond 200 "$(envelope '{"created_time":"2026-11-14T00:00:00Z","custom_metadata":null,"deletion_time":"","destroyed":false,"version":2}')"
    ;;
  # Every version of the key and its metadata go, so a key can be created at the path again
  # (pathMetadataDelete in internal/builtin/logical/kv/path_metadata.go in OpenBao v2.7.2).
  "DELETE secrets/metadata/"*)
    rm -f "$STATE/kv/${path#secrets/metadata/}.json"
    respond 204 ''
    ;;
  # A write to a key that exists is an update, not a create: the existence check of the data path
  # (dataExistenceCheck in path_data.go) makes the request one, and the router does that before
  # the handler and its check-and-set test (internal/vault/request_handling.go in OpenBao v2.7.2).
  # The operator role may create and patch, and never update (operator-policy.json), so OpenBao
  # answers 403 to the token.
  "POST secrets/data/"*)
    [[ -e $STATE/write-refused || -e $STATE/create-refused ]] && respond 403 '{"errors":["permission denied"]}'
    [[ -e $STATE/kv-fails ]] && respond 500 '{"errors":["internal error"]}'
    file=$STATE/kv/${path#secrets/data/}.json
    [[ ! -f $file ]] || respond 403 '{"errors":["permission denied"]}'
    # The custody file must be in place, and non-empty, when the key is written.
    if [[ -s $(cat "$STATE/outfile" 2> /dev/null) ]]; then : > "$STATE/stored-after-file"; fi
    mkdir -p "$(dirname "$file")"
    "$JQ" -c '.data' <<< "$body" > "$file"
    respond 200 "$(envelope '{"created_time":"2026-11-14T00:00:00Z","custom_metadata":null,"deletion_time":"","destroyed":false,"version":1}')"
    ;;
  # The HTTP layer answers the seal status itself, its fields at the top level
  # (internal/http/sys_seal.go in OpenBao v2.7.2).
  "GET sys/seal-status")
    respond 200 "{\"type\":\"static\",\"initialized\":true,\"sealed\":false,\"recovery_seal\":true,\"t\":$((recovery > 0 ? 3 : 0)),\"n\":$recovery,\"progress\":0,\"nonce\":\"\",\"version\":\"2.7.2\",\"storage_type\":\"raft\"}"
    ;;
  # The rotation answers from the logical backend, its fields under data
  # (internal/vault/logical_system_rotate.go in OpenBao v2.7.2).
  "GET sys/rotate/recovery/init")
    if [[ -e $STATE/stale-rotation || -e $STATE/pending ]]; then
      respond 200 "$(envelope '{"started":true,"t":3,"n":5,"required":0,"nonce":"marker-stale-nonce","progress":0,"verification_required":true,"verification_nonce":""}')"
    fi
    respond 200 "$(envelope "{\"started\":false,\"t\":0,\"n\":0,\"required\":$((recovery > 0 ? 3 : 0))}")"
    ;;
  "POST sys/rotate/recovery/init")
    if [[ -e $STATE/stale-rotation || -e $STATE/pending ]]; then
      respond 400 '{"errors":["rotation already in progress"]}'
    fi
    if ((recovery > 0)); then
      respond 200 "$(envelope '{"started":true,"t":3,"n":5,"required":3,"nonce":"marker-rotation-nonce","progress":0,"verification_required":false,"verification_nonce":""}')"
    fi
    if [[ -e $STATE/clobber ]]; then echo someone-else > "$(cat "$STATE/clobber")"; fi
    "$JQ" -c . <<< "$body" > "$STATE/pending"
    respond 200 "$(envelope "$("$JQ" -c '{complete: true, t: .secret_threshold, n: .secret_shares, backup: false,
      pgp_fingerprints: null, verification_required: .require_verification,
      verification_nonce: "marker-verification-nonce",
      keys: [range(.secret_shares) | "marker-recovery-share-\(. + 1)"],
      keys_base64: [range(.secret_shares) | "marker-recovery-share-\(. + 1)" | @base64]}' <<< "$body")")"
    ;;
  "POST sys/rotate/recovery/verify")
    [[ -f $STATE/pending && $("$JQ" -r .nonce <<< "$body") == marker-verification-nonce ]] ||
      respond 400 '{"errors":["no rotation verification in progress"]}'
    "$JQ" -r .key <<< "$body" >> "$STATE/verified"
    threshold=$("$JQ" -r .secret_threshold "$STATE/pending")
    if (($(sort -u "$STATE/verified" | wc -l) >= threshold)); then
      if [[ -s $(cat "$STATE/outfile" 2> /dev/null) ]]; then : > "$STATE/committed-after-write"; fi
      "$JQ" -r .secret_shares "$STATE/pending" > "$STATE/recovery-shares"
      rm "$STATE/pending"
      respond 200 "$(envelope '{"complete":true,"nonce":"marker-verification-nonce"}')"
    fi
    # Before the last share, the verification's progress, without complete.
    respond 200 "$(envelope "{\"nonce\":\"marker-verification-nonce\",\"started\":true,\"t\":3,\"n\":5,\"progress\":$(sort -u "$STATE/verified" | wc -l)}")"
    ;;
  "DELETE sys/rotate/recovery/init")
    : > "$STATE/cancelled"
    rm -f "$STATE/pending" "$STATE/stale-rotation"
    respond 204 ''
    ;;
  # OpenBao answers these from its logical backend, every field under data
  # (internal/vault/logical_system_generate_root.go in OpenBao v2.7.2).
  "GET sys/generate-root-token/attempt")
    if [[ -e $STATE/stale-root || -e $STATE/root-attempt ]]; then
      respond 200 "$(envelope '{"started":true,"complete":false,"progress":0,"required":3,"otp":"","otp_length":28,"nonce":"marker-stale-root-nonce","pgp_fingerprint":""}')"
    fi
    respond 200 "$(envelope '{"started":false,"complete":false,"progress":0,"required":3,"otp":"","otp_length":28}')"
    ;;
  "PUT sys/generate-root-token/attempt")
    if [[ -e $STATE/stale-root || -e $STATE/root-attempt ]]; then
      respond 400 '{"errors":["root generation already in progress"]}'
    fi
    # With no otp and no pgp_key in the request, OpenBao makes the one-time password and returns it.
    [[ $("$JQ" -r '(.otp // "") + (.pgp_key // "")' <<< "$body") == "" ]] ||
      respond 400 '{"errors":["fake: the recipe sent its own otp or pgp_key"]}'
    : > "$STATE/root-attempt"
    respond 200 "$(envelope '{"started":true,"complete":false,"progress":0,"required":3,"otp":"marker-otp","otp_length":28,"nonce":"marker-root-nonce","pgp_fingerprint":""}')"
    ;;
  "PUT sys/generate-root-token/update")
    [[ -e $STATE/root-attempt && $("$JQ" -r .nonce <<< "$body") == marker-root-nonce ]] ||
      respond 400 '{"errors":["no root generation in progress"]}'
    "$JQ" -r .key <<< "$body" >> "$STATE/root-shares"
    if [[ -e $STATE/root-refused ]] && (($(wc -l < "$STATE/root-shares") == 2)); then
      respond 400 '{"errors":["invalid key share"]}'
    fi
    if (($(sort -u "$STATE/root-shares" | wc -l) >= 3)); then
      rm "$STATE/root-attempt"
      respond 200 "$(envelope '{"started":true,"complete":true,"progress":3,"required":3,"nonce":"marker-root-nonce","encoded_token":"marker-encoded-token","pgp_fingerprint":""}')"
    fi
    respond 200 "$(envelope "{\"started\":true,\"complete\":false,\"progress\":$(sort -u "$STATE/root-shares" | wc -l),\"required\":3,\"nonce\":\"marker-root-nonce\",\"encoded_token\":\"\",\"pgp_fingerprint\":\"\"}")"
    ;;
  "DELETE sys/generate-root-token/attempt")
    : > "$STATE/root-cancelled"
    rm -f "$STATE/root-attempt" "$STATE/stale-root"
    respond 204 ''
    ;;
  "POST sys/decode-token")
    if [[ $("$JQ" -r '.encoded_token + " " + .otp' <<< "$body") == "marker-encoded-token marker-otp" ]]; then
      respond 200 "$(envelope '{"token":"marker-root-token"}')"
    fi
    respond 400 '{"errors":["invalid encoded token or otp"]}'
    ;;
esac
respond 404 '{"errors":[]}'
EOF
}

# requests_of METHOD PATH: the bodies of the requests to PATH by METHOD, one per line.
# shellcheck disable=SC2016 # $method and $path are jq variables.
requests_of() {
  "$JQ" -r --arg method "$1" --arg path "$2" 'select(.method == $method and .path == $path) | .body' "$RECORD/requests"
}

# refused_before_reaching REASON: the recipe that just ran failed naming REASON, and reached neither
# the cluster nor OpenBao since the record was last emptied.
refused_before_reaching() {
  [ "$status" -ne 0 ]
  [[ $output == *"$1"* ]] || { echo "no \"$1\" in the output"; return 1; }
  [ "$(grep -c -E '^(kubectl|curl) ' "$RECORD/argv")" -eq 0 ]
}

# no_controls TEXT: TEXT holds no terminal control character: none of C0 but the tab, no DEL, and
# none of C1 as UTF-8 writes it.
no_controls() {
  local LC_ALL=C
  [[ $1 != *[$'\x01'-$'\x08'$'\x0b'-$'\x1f'$'\x7f']* ]] || { echo "a C0 control or DEL in the output"; return 1; }
  [[ $1 != *$'\xc2'[$'\x80'-$'\x9f']* ]] || { echo "a C1 control in the output"; return 1; }
}

@test "bao-put never puts the value on a command line or in its output" {
  local secret
  mkdir -p "$STATE/kv/demo"
  echo '{"other":"keep-me"}' >"$STATE/kv/demo/hello.json"
  recipe bao-put demo/hello greeting <<<"marker-secret-value"
  echo "$output"
  [ "$status" -eq 0 ]
  # It prints the key and the path, and nothing else.
  [ "$output" = "bao-put: wrote greeting of secrets/demo/hello" ]
  # The value, the service account's token and OpenBao's token are in no output and on no command
  # line.
  for secret in marker-secret-value marker-service-account-jwt marker-bao-token; do
    [[ $output != *"$secret"* ]] || { echo "$secret in the output"; return 1; }
    absent "$secret" "$RECORD/argv"
  done
  # The existing secret is patched: its other key stays, and the value is exactly what came in,
  # without the newline that ended it.
  [ "$("$JQ" -c . "$STATE/kv/demo/hello.json")" = '{"other":"keep-me","greeting":"marker-secret-value"}' ]
  [ "$("$JQ" -r 'select(.method == "PATCH") | .type' "$RECORD/requests")" = application/merge-patch+json ]
  # The value travels only in the body of that write.
  [ "$("$JQ" -r 'select(.body | contains("marker-secret-value")) | .method + " " + .path' "$RECORD/requests")" = \
    'PATCH secrets/data/demo/hello' ]
  # Over TLS verified against OpenBao's CA, under the name its certificate holds, with a token for
  # the operator role from a ten-minute service account token with OpenBao's audience, which is
  # revoked at the end.
  [ "$("$JQ" -r 'select(.tls != "verified") | .path' "$RECORD/requests")" = "" ]
  grep -qx 'kubectl create token openbao-operator --namespace openbao --audience openbao --duration 10m' "$RECORD/argv"
  [ "$("$JQ" -r 'select(.path == "auth/kubernetes/login") | .body | fromjson | .role' "$RECORD/requests")" = operator ]
  [ "$("$JQ" -r 'select(.path != "auth/kubernetes/login") | .token' "$RECORD/requests" | sort -u)" = marker-bao-token ]
  [ -e "$STATE/revoked" ]
  [ "$("$JQ" -r '.path' "$RECORD/requests" | tail -n 1)" = auth/token/revoke-self ]

  # A path that does not exist yet is created, and only if it still does not exist.
  : >"$RECORD/requests"
  recipe bao-put demo/new greeting <<<"marker-secret-value"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output != *marker-secret-value* ]]
  [ "$("$JQ" -c . "$STATE/kv/demo/new.json")" = '{"greeting":"marker-secret-value"}' ]
  [ "$(requests_of POST secrets/data/demo/new | "$JQ" -r '.options.cas')" = 0 ]
  absent marker-secret-value "$RECORD/argv"
}

@test "bao-put and bao-recovery close their port-forward on every exit path" {
  # Success.
  recipe bao-put demo/hello greeting <<<"marker-secret-value"
  echo "succeeded: $output"
  [ "$status" -eq 0 ]
  forwards_closed
  # OpenBao refuses the login.
  : >"$STATE/login-refused"
  recipe bao-put demo/hello greeting <<<"marker-secret-value"
  echo "login refused: $output"
  [ "$status" -ne 0 ]
  [[ $output == *login* ]]
  forwards_closed
  rm "$STATE/login-refused"
  # OpenBao refuses the write.
  : >"$STATE/write-refused"
  recipe bao-put demo/hello greeting <<<"marker-secret-value"
  echo "write refused: $output"
  [ "$status" -ne 0 ]
  [[ $output == *permission\ denied* ]]
  forwards_closed
  rm "$STATE/write-refused"
  # Interrupted while it writes.
  echo secrets/data/demo/hello >"$STATE/interrupt"
  recipe bao-put demo/hello greeting <<<"marker-secret-value"
  echo "interrupted: $output"
  [ "$status" -ne 0 ]
  forwards_closed
  rm "$STATE/interrupt"
  # bao-recovery, interrupted while it logs in, refused at login, and succeeding.
  echo auth/kubernetes/login >"$STATE/interrupt"
  recipe bao-recovery "$CUSTODY"
  echo "recovery interrupted: $output"
  [ "$status" -ne 0 ]
  forwards_closed
  rm "$STATE/interrupt"
  : >"$STATE/login-refused"
  recipe bao-recovery "$CUSTODY"
  echo "recovery login refused: $output"
  [ "$status" -ne 0 ]
  forwards_closed
  rm "$STATE/login-refused"
  echo "$CUSTODY" >"$STATE/outfile"
  recipe bao-recovery "$CUSTODY"
  echo "recovery succeeded: $output"
  [ "$status" -eq 0 ]
  forwards_closed
  # Nothing is left in the custody directory but the custody file.
  [ "$(ls -A "$BATS_TEST_TMPDIR/custody")" = openbao.age ]
}

@test "bao-put refuses without a path and a key" {
  # The last cases give the value where the key or a third argument goes, as a slip would: they are
  # refused like the others, and nothing it is given is echoed back.
  local -a cases=('' 'demo/hello' '../demo greeting' '/demo greeting' 'demo//hello greeting'
    'demo/hello gre/eting' 'demo/.. greeting' 'demo/hello -greeting' 'demo/hello marker-argument-value!'
    'demo/hello greeting marker-argument-value')
  local args
  for args in "${cases[@]}"; do
    # shellcheck disable=SC2086 # each case is its arguments, split.
    recipe bao-put $args <<<"marker-secret-value"
    echo "bao-put $args: $output"
    [ "$status" -ne 0 ]
    [[ $output == *bao-put:* ]]
    [[ $output != *marker-argument-value* ]] || { echo "an argument is echoed"; return 1; }
    [[ $output != *../demo* && $output != *gre/eting* && $output != *-greeting* ]] || { echo "an argument is echoed"; return 1; }
  done
  # No value on standard input.
  recipe bao-put demo/hello greeting </dev/null
  echo "no value: $output"
  [ "$status" -ne 0 ]
  [[ $output == *value* ]]
  # None of these reached the cluster or OpenBao.
  [ "$(grep -c -E '^(kubectl|curl) ' "$RECORD/argv")" -eq 0 ]
  [ ! -e "$RECORD/requests" ]
}

@test "bao-recovery hands out the recovery keys once, encrypted to the operator's age key" {
  local plain secret
  echo "$CUSTODY" >"$STATE/outfile"
  recipe bao-recovery "$CUSTODY"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"$CUSTODY"* ]]
  # The file decrypts with the Talos age key, and only with it, to the shares and the seal key.
  plain="$(age -d -i "$BATS_TEST_TMPDIR/keys/talos.agekey" "$CUSTODY")"
  [ "$("$JQ" -r '.recovery.keys_base64 | map(@base64d) | join(" ")' <<<"$plain")" = \
    'marker-recovery-share-1 marker-recovery-share-2 marker-recovery-share-3 marker-recovery-share-4 marker-recovery-share-5' ]
  [ "$("$JQ" -r '.recovery.threshold' <<<"$plain")" = 3 ]
  [ "$("$JQ" -r '.seal.secret + " " + .seal.key' <<<"$plain")" = 'openbao-seal-1 marker-seal-key' ]
  [ "$(stat -c %a "$CUSTODY")" = 600 ]
  # Generated with verification, and committed only once the file was written.
  [ "$(requests_of POST sys/rotate/recovery/init | "$JQ" -r '.require_verification')" = true ]
  [ -e "$STATE/committed-after-write" ]
  [ "$(cat "$STATE/recovery-shares")" = 5 ]
  # Nothing of them is printed or on a command line.
  for secret in marker-recovery-share- bWFya2VyLXJlY292ZXJ5 marker-seal-key bWFya2VyLXNlYWwta2V5 \
    marker-service-account-jwt marker-bao-token marker-verification-nonce; do
    [[ $output != *"$secret"* ]] || { echo "$secret in the output"; return 1; }
    absent "$secret" "$RECORD/argv"
  done
  [ -e "$STATE/revoked" ]

  # Once only: the file is not overwritten, and against existing recovery keys nothing is generated.
  : >"$RECORD/requests"
  recipe bao-recovery "$CUSTODY"
  echo "again: $output"
  [ "$status" -ne 0 ]
  [ -z "$(requests_of POST sys/rotate/recovery/init)" ]
  recipe bao-recovery "$BATS_TEST_TMPDIR/custody/another.age"
  echo "existing keys: $output"
  [ "$status" -ne 0 ]
  [[ $output == *recovery\ key* ]]
  [ -z "$(requests_of POST sys/rotate/recovery/init)" ]
  [ ! -e "$BATS_TEST_TMPDIR/custody/another.age" ]
  # Never into the repository, and never over a file that exists, even while OpenBao holds no
  # recovery keys; neither reaches the cluster.
  rm "$STATE/recovery-shares"
  : >"$RECORD/argv"
  recipe bao-recovery "$REPO/openbao.age"
  echo "inside the repository: $output"
  [ "$status" -ne 0 ]
  [ ! -e "$REPO/openbao.age" ]
  echo keep-me >"$BATS_TEST_TMPDIR/custody/existing.age"
  recipe bao-recovery "$BATS_TEST_TMPDIR/custody/existing.age"
  echo "existing file: $output"
  [ "$status" -ne 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/custody/existing.age")" = keep-me ]
  # Nor where others could replace it before bao-root reads it.
  mkdir "$BATS_TEST_TMPDIR/shared"
  chmod 770 "$BATS_TEST_TMPDIR/shared"
  recipe bao-recovery "$BATS_TEST_TMPDIR/shared/openbao.age"
  echo "a shared directory: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"$BATS_TEST_TMPDIR/shared is writable by its group or others"* ]]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/shared")" ]
  [ "$(grep -c -E '^(kubectl|curl) ' "$RECORD/argv")" -eq 0 ]
}

@test "bao-recovery never commits recovery keys it did not keep" {
  local secret
  echo "$CUSTODY" >"$STATE/outfile"
  # Interrupted while the first share is verified: OpenBao has committed nothing, so the rotation is
  # cancelled and the file, whose shares will never work, removed.
  echo sys/rotate/recovery/verify >"$STATE/interrupt"
  recipe bao-recovery "$CUSTODY"
  echo "interrupted before the commit: $output"
  [ "$status" -ne 0 ]
  [ -e "$STATE/cancelled" ]
  [ ! -e "$STATE/recovery-shares" ]
  [ ! -e "$CUSTODY" ]
  forwards_closed
  # Interrupted on the verification that commits the shares: the file holds them, so it stays.
  rm -f "$STATE/cancelled" "$STATE/verified" "$STATE/interrupt-count"
  echo 3 >"$STATE/interrupt-at"
  recipe bao-recovery "$CUSTODY"
  echo "interrupted on the commit: $output"
  [ "$status" -ne 0 ]
  [ "$(cat "$STATE/recovery-shares")" = 5 ]
  [ -s "$CUSTODY" ]
  [ "$(age -d -i "$BATS_TEST_TMPDIR/keys/talos.agekey" "$CUSTODY" | "$JQ" -r '.recovery.keys_base64 | length')" = 5 ]
  rm -f "$STATE/interrupt" "$STATE/interrupt-at" "$STATE/interrupt-count" "$STATE/recovery-shares" "$STATE/verified"
  mv "$CUSTODY" "$BATS_TEST_TMPDIR/committed.age"

  # A rotation left in progress, by a run whose answer was lost, is cancelled before a new one.
  : >"$STATE/stale-rotation"
  : >"$RECORD/requests"
  recipe bao-recovery "$CUSTODY"
  echo "stale rotation: $output"
  [ "$status" -eq 0 ]
  [ "$("$JQ" -r 'select(.path == "sys/rotate/recovery/init") | .method' "$RECORD/requests" | paste -sd' ' -)" = "GET DELETE POST" ]
  rm "$CUSTODY" "$STATE/recovery-shares" "$STATE/verified"

  # A file someone makes at the path after the check is never replaced; nothing is committed.
  echo "$CUSTODY" >"$STATE/clobber"
  : >"$RECORD/requests"
  recipe bao-recovery "$CUSTODY"
  echo "made by someone else: $output"
  [ "$status" -ne 0 ]
  [ "$(cat "$CUSTODY")" = someone-else ]
  [ -z "$(requests_of POST sys/rotate/recovery/verify)" ]
  [ ! -e "$STATE/recovery-shares" ]
  [ "$(find "$BATS_TEST_TMPDIR/custody" -mindepth 1 ! -name openbao.age | wc -l)" -eq 0 ]
  rm "$STATE/clobber" "$CUSTODY" "$STATE/cancelled"

  # Where no hard link can be made, as on a filesystem without them, the file is put in place no
  # other way: ln's own error is shown, the file is not said to exist, nothing is committed and
  # nothing stays in the custody directory.
  fake_tool ln <<'LN'
printf '%s\n' "ln $*" >> "$RECORD/argv"
printf "ln: failed to create hard link '%s' => '%s': Operation not permitted\n" "${@: -1}" "${@: -2:1}" >&2
exit 1
LN
  : >"$RECORD/requests"
  recipe bao-recovery "$CUSTODY"
  echo "no hard links: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"Operation not permitted"* ]]
  [[ $output != *exists* ]]
  [ -z "$(requests_of POST sys/rotate/recovery/verify)" ]
  [ ! -e "$STATE/recovery-shares" ]
  [ -e "$STATE/cancelled" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/custody")" ]
  record ln
  rm "$STATE/cancelled"

  # Interrupted right after the link is made, before OpenBao commits the shares: the rotation is
  # cancelled, and the file, whose shares will never work, is removed, as the run says.
  fake_tool ln <<LN
printf '%s\n' "ln \$*" >> "\$RECORD/argv"
"$(command -v ln)" "\$@" || exit
kill -INT "\$PPID"
LN
  : >"$RECORD/requests"
  recipe bao-recovery "$CUSTODY"
  echo "interrupted as the file is put in place: $output"
  [ "$status" -ne 0 ]
  [ -e "$STATE/cancelled" ]
  [ -z "$(requests_of POST sys/rotate/recovery/verify)" ]
  [ ! -e "$STATE/recovery-shares" ]
  [ ! -e "$CUSTODY" ]
  [[ $output == *"$CUSTODY is removed"* ]]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/custody")" ]
  record ln
  rm "$STATE/cancelled"

  # Encrypted to a recipient the operator's age key does not open, the shares are never committed.
  age-keygen -o "$BATS_TEST_TMPDIR/keys/other.agekey" 2>/dev/null
  OTHER="$(age-keygen -y "$BATS_TEST_TMPDIR/keys/other.agekey")" yq -i '.creation_rules[].age = strenv(OTHER)' "$REPO/talos/.sops.yaml"
  : >"$RECORD/requests"
  recipe bao-recovery "$CUSTODY"
  echo "another recipient: $output"
  [ "$status" -ne 0 ]
  [ -z "$(requests_of POST sys/rotate/recovery/verify)" ]
  [ ! -e "$STATE/recovery-shares" ]
  [ ! -e "$CUSTODY" ]
  [ -e "$STATE/cancelled" ]
  for secret in marker-recovery-share- bWFya2VyLXJlY292ZXJ5 marker-seal-key bWFya2VyLXNlYWwta2V5; do
    [[ $output != *"$secret"* ]] || { echo "$secret in the output"; return 1; }
    absent "$secret" "$RECORD/argv"
  done
}

@test "bao-root runs one command with a fifteen-minute token made from the recovery keys, and revokes it" {
  local secret
  custody_file marker-seal-key
  echo 5 >"$STATE/recovery-shares"
  # The command it runs: reports what reached its environment, without printing the token, and
  # records that it ran. With $MISBEHAVE it kills itself, or interrupts the recipe's script.
  fake report-env <<EOF
echo "command ran" >> "$STATE/events"
{
  [[ \$BAO_TOKEN == marker-orphan-token ]] && echo token=orphan
  echo "addr=\$BAO_ADDR server=\$BAO_TLS_SERVER_NAME args=\$*"
  grep -qx marker-ca "\$BAO_CACERT" && echo ca=verified
} > "$STATE/command-env"
compgen -e > "$STATE/command-names"
case \$(cat "$STATE/misbehave" 2> /dev/null) in
  killed) kill -KILL \$\$ ;;
  interrupt) kill -INT \$PPID; sleep 1 ;;
esac
EOF
  # reset: clears what one run leaves behind.
  reset() {
    rm -f "$STATE/command-env" "$STATE/events" "$STATE/root-revoked" "$STATE/orphan-revoked" "$STATE/revoked" \
      "$STATE/root-cancelled" "$STATE/root-shares" "$STATE/orphan-request" "$STATE/misbehave"
  }
  # no_secrets: neither the output nor any command line holds a share, a token or the seal key.
  no_secrets() {
    for secret in marker-recovery-share- bWFya2VyLXJlY292ZXJ5 marker-root-token marker-orphan-token marker-encoded-token \
      marker-otp marker-seal-key marker-bao-token marker-service-account-jwt; do
      [[ $output != *"$secret"* ]] || { echo "$secret in the output"; return 1; }
      absent "$secret" "$RECORD/argv"
    done
  }

  : >"$STATE/stale-root"
  recipe bao-root "$CUSTODY" report-env one two
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/command-env")" = "$(printf '%s\n' token=orphan 'addr=https://localhost:41234 server=openbao-active.openbao.svc args=one two' ca=verified)" ]
  # A shell the command starts reads no file the recipe was given for one: BASH_ENV and ENV are gone.
  if grep -qxE 'BASH_ENV|ENV' "$STATE/command-names"; then echo "BASH_ENV or ENV reached the command"; return 1; fi
  # The root token is first looked up for its accessor, then mints a fifteen-minute orphan token
  # with the root policy, which no renewal extends, and is revoked before the command runs; the
  # orphan token is revoked after it.
  [ "$("$JQ" -cS . "$STATE/orphan-request")" = '{"explicit_max_ttl":"15m","policies":["root"],"renewable":false,"ttl":"15m"}' ]
  [ "$(cat "$STATE/events")" = "$(printf '%s\n' 'looked up root' 'minted orphan' 'revoked root' 'command ran' 'revoked orphan')" ]
  # A generation left in progress is cancelled first; the shares travel only in request bodies.
  [ "$("$JQ" -r 'select(.path == "sys/generate-root-token/attempt") | .method' "$RECORD/requests" | paste -sd' ' -)" = "GET DELETE PUT" ]
  [ "$("$JQ" -r 'select(.body | contains("bWFya2VyLXJlY292ZXJ5")) | .method + " " + .path' "$RECORD/requests" | sort -u)" = \
    'PUT sys/generate-root-token/update' ]
  no_secrets
  [ -e "$STATE/revoked" ]
  forwards_closed

  # The command killed: its token is revoked all the same, and the recipe fails.
  reset
  echo killed >"$STATE/misbehave"
  recipe bao-root "$CUSTODY" report-env
  echo "command killed: $output"
  [ "$status" -ne 0 ]
  [ "$(cat "$STATE/events")" = "$(printf '%s\n' 'looked up root' 'minted orphan' 'revoked root' 'command ran' 'revoked orphan')" ]
  forwards_closed
  # The recipe interrupted while the command runs: the same.
  reset
  echo interrupt >"$STATE/misbehave"
  recipe bao-root "$CUSTODY" report-env
  echo "interrupted: $output"
  [ "$status" -ne 0 ]
  [ "$(cat "$STATE/events")" = "$(printf '%s\n' 'looked up root' 'minted orphan' 'revoked root' 'command ran' 'revoked orphan')" ]
  forwards_closed

  # Minting refused: the root token is revoked at once, and no command runs.
  reset
  : >"$STATE/orphan-refused"
  recipe bao-root "$CUSTODY" report-env
  echo "minting refused: $output"
  [ "$status" -ne 0 ]
  [ "$(cat "$STATE/events")" = "$(printf '%s\n' 'looked up root' 'revoked root')" ]
  [ ! -e "$STATE/command-env" ]
  forwards_closed
  rm "$STATE/orphan-refused"
  # The root token's accessor unknown: the root token is revoked and used for nothing else.
  reset
  : >"$STATE/lookup-refused"
  recipe bao-root "$CUSTODY" report-env
  echo "no accessor: $output"
  [ "$status" -ne 0 ]
  [ "$(cat "$STATE/events")" = 'revoked root' ]
  [ ! -e "$STATE/orphan-request" ]
  [ ! -e "$STATE/command-env" ]
  forwards_closed
  rm "$STATE/lookup-refused"

  # The root token's revocation fails: no command runs while it lives, the command's token is
  # revoked, and the recipe fails naming the root token by its accessor, which is no credential,
  # with the step that revokes it by that accessor; no token is printed.
  reset
  : >"$STATE/root-revoke-fails"
  recipe bao-root "$CUSTODY" report-env
  echo "root not revoked: $output"
  [ "$status" -ne 0 ]
  [ ! -e "$STATE/command-env" ]
  [ "$(cat "$STATE/events")" = "$(printf '%s\n' 'looked up root' 'minted orphan' 'revoked orphan')" ]
  [[ $output == *"just bao-root $CUSTODY bao token revoke -accessor marker-root-accessor"* ]]
  no_secrets
  forwards_closed
  rm "$STATE/root-revoke-fails"
  # The command's token's revocation fails after the command succeeded: the recipe fails all the
  # same, naming that token by its accessor with the step that revokes it.
  reset
  : >"$STATE/orphan-revoke-fails"
  recipe bao-root "$CUSTODY" report-env
  echo "command's token not revoked: $output"
  [ "$status" -ne 0 ]
  [ -e "$STATE/command-env" ]
  [ "$(cat "$STATE/events")" = "$(printf '%s\n' 'looked up root' 'minted orphan' 'revoked root' 'command ran')" ]
  [[ $output == *"just bao-root $CUSTODY bao token revoke -accessor marker-orphan-accessor"* ]]
  no_secrets
  forwards_closed
  rm "$STATE/orphan-revoke-fails"

  # A share refused before the token is made: the generation is cancelled and no command runs.
  reset
  : >"$STATE/root-refused"
  recipe bao-root "$CUSTODY" report-env
  echo "refused: $output"
  [ "$status" -ne 0 ]
  [ ! -e "$STATE/command-env" ]
  [ -e "$STATE/root-cancelled" ]
  [ ! -e "$STATE/events" ]
  forwards_closed
  [[ $output != *marker-recovery-share-* ]]
  # Without a command, it refuses before reaching anything.
  : >"$RECORD/argv"
  recipe bao-root "$CUSTODY"
  [ "$status" -ne 0 ]
  [ "$(grep -c -E '^(kubectl|curl) ' "$RECORD/argv")" -eq 0 ]
}

# shellcheck disable=SC2016 # $key is a jq variable.
@test "bao-seal-restore writes the seal key back from the custody file and never replaces a key unasked" {
  local key=c0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ffee0001 other secret kept real_date
  other=${key%0001}0002
  custody_file "$key"
  # No Secret: it is made, immutable, with the file's key.
  recipe bao-seal-restore "$CUSTODY"
  echo "missing: $output"
  [ "$status" -eq 0 ]
  [ "$("$JQ" -cS '{kind, name: .metadata.name, namespace: .metadata.namespace, immutable, key: (.data.key | @base64d)}' "$STATE/seal-created")" = \
    "$("$JQ" -ncS --arg key "$key" '{kind: "Secret", name: "openbao-seal-1", namespace: "openbao", immutable: true, key: $key}')" ]
  # Holding the same key: left alone.
  rm "$STATE/seal-created"
  recipe bao-seal-restore "$CUSTODY"
  echo "same key: $output"
  [ "$status" -eq 0 ]
  [ ! -e "$STATE/seal-created" ]
  [ ! -e "$STATE/seal-deleted" ]
  # Holding another key: kept unless --replace is given, then replaced.
  "$JQ" -n --arg key "$other" '{kind: "Secret", metadata: {name: "openbao-seal-1", namespace: "openbao"}, immutable: true, data: {key: ($key | @base64)}}' >"$STATE/seal-secret"
  recipe bao-seal-restore "$CUSTODY"
  echo "other key: $output"
  [ "$status" -ne 0 ]
  [ ! -e "$STATE/seal-created" ]
  [ ! -e "$STATE/seal-deleted" ]
  # Replacing it, when the key it holds cannot be kept first, opening with the operator's age key,
  # deletes nothing: here the recipient in talos/.sops.yaml is another key's.
  cp "$REPO/talos/.sops.yaml" "$BATS_TEST_TMPDIR/sops.yaml"
  age-keygen -o "$BATS_TEST_TMPDIR/keys/other.agekey" 2>/dev/null
  OTHER="$(age-keygen -y "$BATS_TEST_TMPDIR/keys/other.agekey")" yq -i '.creation_rules[].age = strenv(OTHER)' "$REPO/talos/.sops.yaml"
  recipe bao-seal-restore "$CUSTODY" --replace
  echo "unkept: $output"
  [ "$status" -ne 0 ]
  [ ! -e "$STATE/seal-deleted" ]
  [ "$(find "$BATS_TEST_TMPDIR/custody" -mindepth 1 ! -name openbao.age | wc -l)" -eq 0 ]
  cp "$BATS_TEST_TMPDIR/sops.yaml" "$REPO/talos/.sops.yaml"
  # Replaced: the key it held is first kept in a new file beside the custody file, encrypted to the
  # Talos age key, and the custody file is left as it was.
  cp "$CUSTODY" "$BATS_TEST_TMPDIR/custody-before.age"
  recipe bao-seal-restore "$CUSTODY" --replace
  echo "replaced: $output"
  [ "$status" -eq 0 ]
  [ -e "$STATE/seal-deleted" ]
  [ "$("$JQ" -r '.data.key | @base64d' "$STATE/seal-created")" = "$key" ]
  cmp "$CUSTODY" "$BATS_TEST_TMPDIR/custody-before.age"
  kept="$(find "$BATS_TEST_TMPDIR/custody" -mindepth 1 -name 'openbao.age.replaced-*.age')"
  echo "kept in: ${kept:-nothing}"
  [ "$(grep -c . <<<"$kept")" -eq 1 ]
  [ "$(stat -c %a "$kept")" = 600 ]
  [ "$(age -d -i "$BATS_TEST_TMPDIR/keys/talos.agekey" "$kept" | "$JQ" -r '.seal.secret + " " + .seal.key')" = "openbao-seal-1 $other" ]
  # A second replacement keeps the key it replaces in another new file, never over the first.
  "$JQ" -n --arg key "$other" '{kind: "Secret", metadata: {name: "openbao-seal-1", namespace: "openbao"}, immutable: true, data: {key: ($key | @base64)}}' >"$STATE/seal-secret"
  cp "$kept" "$BATS_TEST_TMPDIR/kept-before.age"
  recipe bao-seal-restore "$CUSTODY" --replace
  echo "replaced again: $output"
  [ "$status" -eq 0 ]
  cmp "$kept" "$BATS_TEST_TMPDIR/kept-before.age"
  [ "$(find "$BATS_TEST_TMPDIR/custody" -mindepth 1 -name 'openbao.age.replaced-*.age' | wc -l)" -eq 2 ]
  # A file where it would keep the key is never replaced, and nothing is deleted. With the clock
  # standing still, a second run picks the very name of the file the first one kept the key in.
  real_date="$(command -v date)"
  fake_tool date <<EOF
if [[ -f \$STATE/frozen-time ]]; then exec "$real_date" --date "@\$(<"\$STATE/frozen-time")" "\$@"; fi
exec "$real_date" "\$@"
EOF
  echo 1767225600 >"$STATE/frozen-time"
  find "$BATS_TEST_TMPDIR/custody" -mindepth 1 | sort >"$BATS_TEST_TMPDIR/custody-before"
  "$JQ" -n --arg key "$other" '{kind: "Secret", metadata: {name: "openbao-seal-1", namespace: "openbao"}, immutable: true, data: {key: ($key | @base64)}}' >"$STATE/seal-secret"
  recipe bao-seal-restore "$CUSTODY" --replace
  echo "replaced at a standing clock: $output"
  [ "$status" -eq 0 ]
  kept="$(find "$BATS_TEST_TMPDIR/custody" -mindepth 1 | sort | comm -13 "$BATS_TEST_TMPDIR/custody-before" -)"
  [ "$(grep -c . <<<"$kept")" -eq 1 ]
  cp "$kept" "$BATS_TEST_TMPDIR/kept-before.age"
  "$JQ" -n --arg key "$other" '{kind: "Secret", metadata: {name: "openbao-seal-1", namespace: "openbao"}, immutable: true, data: {key: ($key | @base64)}}' >"$STATE/seal-secret"
  rm "$STATE/seal-deleted"
  find "$BATS_TEST_TMPDIR/custody" -mindepth 1 | sort >"$BATS_TEST_TMPDIR/custody-before"
  recipe bao-seal-restore "$CUSTODY" --replace
  echo "a file in the way: $output"
  [ "$status" -ne 0 ]
  [ ! -e "$STATE/seal-deleted" ]
  cmp "$kept" "$BATS_TEST_TMPDIR/kept-before.age"
  [ "$(find "$BATS_TEST_TMPDIR/custody" -mindepth 1 | sort)" = "$(cat "$BATS_TEST_TMPDIR/custody-before")" ]
  # Where no hard link can be made, as on a filesystem without them, the key is kept no other way and
  # nothing is deleted: ln's own error is shown, and the file is not said to exist.
  rm "$STATE/frozen-time"
  fake_tool ln <<'LN'
printf '%s\n' "ln $*" >> "$RECORD/argv"
printf "ln: failed to create hard link '%s' => '%s': Operation not permitted\n" "${@: -1}" "${@: -2:1}" >&2
exit 1
LN
  recipe bao-seal-restore "$CUSTODY" --replace
  echo "no hard links: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"Operation not permitted"* ]]
  [[ $output != *exists* ]]
  [ ! -e "$STATE/seal-deleted" ]
  [ "$(find "$BATS_TEST_TMPDIR/custody" -mindepth 1 | sort)" = "$(cat "$BATS_TEST_TMPDIR/custody-before")" ]
  record ln
  for secret in "$key" "$other" "$(printf %s "$key" | base64 -w0)" "$(printf %s "$other" | base64 -w0)"; do
    [[ $output != *"$secret"* ]] || { echo "a key in the output"; return 1; }
    absent "$secret" "$RECORD/argv"
  done
}

# seed_env [ID [SECRET]]: the repository's .env, as an operator fills it in: the backup prefix, the
# state key and its passphrase, the cloud credential, and the cluster's S3 key, which differs from
# the state key. The cluster key is what the volsync recipes put in the store. The object storage's
# settings are a fixture's.
seed_env() {
  printf '%s\n' BACKUP_BUCKET_PREFIX=marker-prefix AWS_ACCESS_KEY_ID=marker-state-id \
    AWS_SECRET_ACCESS_KEY=marker-state-secret TF_STATE_PASSPHRASE=marker-state-passphrase \
    OS_APPLICATION_CREDENTIAL_SECRET=marker-cloud-secret "CLUSTER_S3_ACCESS_KEY_ID=${1-marker-cluster-id}" \
    "CLUSTER_S3_SECRET_ACCESS_KEY=${2-marker-cluster-secret}" >"$REPO/.env"
  mkdir -p "$REPO/infra/openstack"
  printf 'region = "marker-region"\nendpoints = {\n  s3 = "https://s3.example.com"\n}\nuse_path_style = true\n' \
    >"$REPO/infra/openstack/backend.hcl"
  VOLSYNC_CUSTODY="$BATS_TEST_TMPDIR/custody/volsync.age"
  echo "$VOLSYNC_CUSTODY" >"$STATE/outfile"
}

# master_in FILE: the master password the custody file FILE holds, opened with the Talos age key.
master_in() {
  age -d -i "$BATS_TEST_TMPDIR/keys/talos.agekey" "$1" | "$JQ" -r '.volsync.master'
}

# stored KEY: the property KEY of the key volsync in the fake store.
# shellcheck disable=SC2016 # $key is a jq variable.
stored() {
  "$JQ" -r --arg key "$1" '.[$key]' "$STATE/kv/volsync.json"
}

# leaked OUTPUT TEXT...: fails when any TEXT is in OUTPUT, the recipe's output, or on a command line
# the tools recorded, which holds every command line as no command ran by its path, or in any file
# but the encrypted one, the fakes themselves, the fake store and its record of requests, the trace
# of the scripts, what the fake command wrote down, and the operator's own .env. The files searched
# include what the recipes removed or replaced, as the recorders of rm and mv kept it.
leaked() {
  local printed=$1 text
  shift
  by_name
  for text; do
    [[ $printed != *"$text"* ]] || { echo "$text in the output"; return 1; }
    absent "$text" "$RECORD/argv"
    if grep -rlF --exclude-dir=kv --exclude-dir=bin --exclude-dir=xtrace --exclude=requests --exclude=command-env \
      --exclude=.env -- "$text" "$BATS_TEST_TMPDIR"; then
      echo "$text is in a file, unencrypted"
      return 1
    fi
  done
}

@test "Seeding writes the master to the custody file, checks it opens, and only then writes the store's key" {
  local master
  seed_env
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"$VOLSYNC_CUSTODY"* ]]
  # The file opens with the Talos age key, and holds 32 random bytes as 64 hexadecimal digits,
  # which restic and the template's digest take as they are.
  master=$(master_in "$VOLSYNC_CUSTODY")
  [[ $master =~ ^[0-9a-f]{64}$ ]]
  # Those bytes are the ones the kernel's generator gave, and nothing else: head read 32 bytes of
  # /dev/urandom, once, and the master is exactly what it returned, in hexadecimal.
  [ "$(grep -c '^head ' "$RECORD/argv")" -eq 1 ]
  grep -qx 'head -c 32 /dev/urandom' "$RECORD/argv"
  [ "$(od -An -vtx1 "$RECORD/head-output" | tr -d ' \n')" = "$master" ]
  [ "$(age -d -i "$BATS_TEST_TMPDIR/keys/talos.agekey" "$VOLSYNC_CUSTODY" | "$JQ" -r '.cluster')" = lab-sto2 ]
  [ "$(stat -c %a "$VOLSYNC_CUSTODY")" = 600 ]
  # The store's key holds that master and the cluster's S3 key, written only once the file stood,
  # and only if the key did not exist.
  [ "$(stored RESTIC_MASTER_PASSWORD)" = "$master" ]
  [ "$(stored AWS_ACCESS_KEY_ID)" = marker-cluster-id ]
  [ "$(stored AWS_SECRET_ACCESS_KEY)" = marker-cluster-secret ]
  [ "$("$JQ" -r 'keys | join(" ")' "$STATE/kv/volsync.json")" = 'AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_MASTER_PASSWORD' ]
  [ -e "$STATE/stored-after-file" ]
  [ "$(requests_of POST secrets/data/volsync | "$JQ" -r '.options.cas')" = 0 ]
  # Over TLS verified against OpenBao's CA, with the operator's token, which is revoked; the
  # port-forward is closed and nothing but the custody file is left behind.
  [ "$("$JQ" -r 'select(.tls != "verified") | .path' "$RECORD/requests")" = "" ]
  [ "$("$JQ" -r 'select(.path != "auth/kubernetes/login") | .token' "$RECORD/requests" | sort -u)" = marker-bao-token ]
  [ -e "$STATE/revoked" ]
  forwards_closed
  [ "$(ls -A "$BATS_TEST_TMPDIR/custody")" = volsync.age ]

  # Another seeding makes another master: it depends on nothing the recipe is given, the cluster's
  # name included.
  rm -r "$STATE/kv" "$STATE/stored-after-file" "$VOLSYNC_CUSTODY"
  mkdir "$STATE/kv"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  [ "$status" -eq 0 ]
  [ "$(master_in "$VOLSYNC_CUSTODY")" != "$master" ]

  # A file that opens, but to something else than was written, is not trusted either: nothing is
  # written to the store, and nothing stays in the custody directory.
  rm -r "$STATE/kv" "$STATE/stored-after-file" "$VOLSYNC_CUSTODY"
  mkdir "$STATE/kv"
  fake age <<AGE
printf '%s\n' "age \$*" >> "$RECORD/argv"
if [[ " \$* " == *" --encrypt "* ]]; then
  cat > /dev/null
  printf '{"cluster":"lab-sto2"}' | exec "$(command -v age)" "\$@"
fi
exec "$(command -v age)" "\$@"
AGE
  : >"$RECORD/requests"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "a file that opens to another content: $output"
  [ "$status" -ne 0 ]
  [ -z "$(requests_of POST secrets/data/volsync)" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/custody")" ]
  forwards_closed
  record age

  # A recipient the operator's age key does not open: the file is not trusted, the store is never
  # written, and the file is removed.
  rm -rf "$STATE/kv" "$STATE/stored-after-file" "$VOLSYNC_CUSTODY"
  mkdir "$STATE/kv"
  age-keygen -o "$BATS_TEST_TMPDIR/keys/other.agekey" 2>/dev/null
  OTHER="$(age-keygen -y "$BATS_TEST_TMPDIR/keys/other.agekey")" yq -i '.creation_rules[].age = strenv(OTHER)' "$REPO/talos/.sops.yaml"
  : >"$RECORD/requests"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "another recipient: $output"
  [ "$status" -ne 0 ]
  [ -z "$(requests_of POST secrets/data/volsync)" ]
  # The one patch it sent asks whether the key exists and carries no data.
  [ "$(requests_of PATCH secrets/data/volsync | "$JQ" -c '.')" = '{"data":{},"options":{"cas":0}}' ]
  [ ! -e "$STATE/kv/volsync.json" ]
  [ ! -e "$VOLSYNC_CUSTODY" ]
  # Nothing is left in the custody directory, the partial file included.
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/custody")" ]
  forwards_closed

  # Where no hard link can be made, as on a filesystem without them, the file is put in place no
  # other way: ln's own error is shown and the file is not said to exist; nothing stays in the
  # custody directory, and the store is never written.
  RECIPIENT=$RECIPIENT yq -i '.creation_rules[].age = strenv(RECIPIENT)' "$REPO/talos/.sops.yaml"
  fake_tool ln <<'LN'
printf '%s\n' "ln $*" >> "$RECORD/argv"
printf "ln: failed to create hard link '%s' => '%s': Operation not permitted\n" "${@: -1}" "${@: -2:1}" >&2
exit 1
LN
  : >"$RECORD/requests"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "no hard links: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"Operation not permitted"* ]]
  [[ $output != *exists* ]]
  [ -z "$(requests_of POST secrets/data/volsync)" ]
  [ ! -e "$STATE/kv/volsync.json" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/custody")" ]
  forwards_closed
}

@test "A store that already holds the key is not seeded again, and its master is never replaced" {
  local master before refusal reason
  seed_env
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  [ "$status" -eq 0 ]
  master=$(master_in "$VOLSYNC_CUSTODY")
  before=$(cat "$STATE/kv/volsync.json")
  cp "$VOLSYNC_CUSTODY" "$BATS_TEST_TMPDIR/custody-before.age"

  # The same file again: the store holds the key, so nothing is written, and the file stays.
  : >"$RECORD/requests"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "same file: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"already holds"* ]]
  [ "$(cat "$STATE/kv/volsync.json")" = "$before" ]
  [ -z "$(requests_of POST secrets/data/volsync)" ]
  cmp "$VOLSYNC_CUSTODY" "$BATS_TEST_TMPDIR/custody-before.age"
  forwards_closed

  # A new file: a master is never made for a store that has one, and the file it would have held
  # does not stay behind.
  : >"$RECORD/requests"
  recipe bao-seed-volsync "$BATS_TEST_TMPDIR/custody/another.age"
  echo "another file: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"already holds"* ]]
  [ "$(cat "$STATE/kv/volsync.json")" = "$before" ]
  [ -z "$(requests_of POST secrets/data/volsync)" ]
  [ ! -e "$BATS_TEST_TMPDIR/custody/another.age" ]
  [ "$(find "$BATS_TEST_TMPDIR/custody" -mindepth 1 | wc -l)" -eq 1 ]
  forwards_closed

  # An existing file is never replaced, and one that is not a custody file of this recipe is
  # refused before OpenBao is reached; so is a path inside the repository.
  echo keep-me >"$BATS_TEST_TMPDIR/custody/existing.age"
  : >"$RECORD/argv"
  recipe bao-seed-volsync "$BATS_TEST_TMPDIR/custody/existing.age"
  echo "an unrelated file: $output"
  [ "$status" -ne 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/custody/existing.age")" = keep-me ]
  custody_file marker-seal-key
  recipe bao-seed-volsync "$CUSTODY"
  echo "the recovery keys' file: $output"
  [ "$status" -ne 0 ]
  # So is another cluster's custody file, though it holds a master.
  # shellcheck disable=SC2016 # $master is a jq variable.
  "$JQ" -n --arg master "$(printf 'a%.0s' {1..64})" '{cluster: "lab-other", volsync: {master: $master}}' |
    age --encrypt --recipient "$RECIPIENT" --output "$BATS_TEST_TMPDIR/custody/foreign.age"
  recipe bao-seed-volsync "$BATS_TEST_TMPDIR/custody/foreign.age"
  echo "another cluster's file: $output"
  [ "$status" -ne 0 ]
  recipe bao-seed-volsync "$REPO/volsync.age"
  echo "inside the repository: $output"
  [ "$status" -ne 0 ]
  [ ! -e "$REPO/volsync.age" ]
  [ "$(grep -c -E '^(kubectl|curl) ' "$RECORD/argv")" -eq 0 ]

  # --rotate-s3 replaces the S3 key and nothing else: the master stays, in the store and in the
  # file. No flag replaces the master.
  seed_env marker-rotated-id marker-rotated-secret
  : >"$RECORD/requests"
  recipe bao-seed-volsync --rotate-s3
  echo "rotated: $output"
  [ "$status" -eq 0 ]
  [ "$(stored RESTIC_MASTER_PASSWORD)" = "$master" ]
  [ "$(stored AWS_ACCESS_KEY_ID)" = marker-rotated-id ]
  [ "$(stored AWS_SECRET_ACCESS_KEY)" = marker-rotated-secret ]
  [ "$(requests_of PATCH secrets/data/volsync | "$JQ" -r '.data | keys | join(" ")')" = 'AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY' ]
  [ -z "$(requests_of POST secrets/data/volsync)" ]
  cmp "$VOLSYNC_CUSTODY" "$BATS_TEST_TMPDIR/custody-before.age"
  forwards_closed
  recipe bao-seed-volsync --replace-master "$VOLSYNC_CUSTODY"
  echo "a flag for the master: $output"
  [ "$status" -ne 0 ]
  [ "$(stored RESTIC_MASTER_PASSWORD)" = "$master" ]

  # Rotating where the store holds no key has no master to keep: it refuses and writes nothing.
  rm "$STATE/kv/volsync.json"
  recipe bao-seed-volsync --rotate-s3
  echo "nothing to rotate: $output"
  [ "$status" -ne 0 ]
  [ ! -e "$STATE/kv/volsync.json" ]
  forwards_closed

  # Asking whether the key exists refused for another reason than its check-and-set, by a denied
  # permission, a server error or a request that never reached OpenBao: the recipe says that reason,
  # not that the store holds the key, and makes nothing.
  for refusal in 'write-refused permission denied' 'kv-fails internal error' 'unreachable Failed to connect'; do
    reason=${refusal#* }
    : >"$STATE/${refusal%% *}"
    : >"$RECORD/requests"
    recipe bao-seed-volsync "$BATS_TEST_TMPDIR/custody/refused.age"
    echo "${refusal%% *}: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"$reason"* ]]
    [[ $output != *"already holds"* ]]
    [ -z "$(requests_of POST secrets/data/volsync)" ]
    [ ! -e "$STATE/kv/volsync.json" ]
    [ "$(find "$BATS_TEST_TMPDIR/custody" -mindepth 1 -name '*refused.age*' | wc -l)" -eq 0 ]
    forwards_closed
    rm "$STATE/${refusal%% *}"
  done

  # A file someone makes at the path after the recipe checked it is never replaced, and the store is
  # not written: the recipe stops before it, and leaves no partial file.
  echo "$BATS_TEST_TMPDIR/custody/late.age" >"$STATE/clobber"
  : >"$RECORD/requests"
  recipe bao-seed-volsync "$BATS_TEST_TMPDIR/custody/late.age"
  echo "made by someone else: $output"
  [ "$status" -ne 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/custody/late.age")" = someone-else ]
  [ -z "$(requests_of POST secrets/data/volsync)" ]
  [ ! -e "$STATE/kv/volsync.json" ]
  [ "$(find "$BATS_TEST_TMPDIR/custody" -mindepth 1 -name '.late.age.*' | wc -l)" -eq 0 ]
  forwards_closed
}

@test "A run interrupted between the file and the store goes on from the file" {
  local master
  seed_env
  # Interrupted as the store is written, the write lost: the file holds the master, the store does
  # not hold the key.
  # The second request to the key: the first asks whether it exists.
  echo secrets/data/volsync >"$STATE/interrupt"
  echo 2 >"$STATE/interrupt-at"
  : >"$STATE/interrupt-drops"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "interrupted: $output"
  [ "$status" -ne 0 ]
  [ ! -e "$STATE/kv/volsync.json" ]
  master=$(master_in "$VOLSYNC_CUSTODY")
  [[ $master =~ ^[0-9a-f]{64}$ ]]
  # It says which state it left and how the next run goes on, without the master.
  [[ $output == *"$VOLSYNC_CUSTODY"* ]]
  [[ $output == *"from the file"* ]]
  forwards_closed
  rm "$STATE/interrupt" "$STATE/interrupt-count"
  cp "$VOLSYNC_CUSTODY" "$BATS_TEST_TMPDIR/custody-before.age"
  # The next run reads the master back from the file: no other master is made, and the store holds
  # the one that was kept.
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "continued: $output"
  [ "$status" -eq 0 ]
  [ "$(stored RESTIC_MASTER_PASSWORD)" = "$master" ]
  cmp "$VOLSYNC_CUSTODY" "$BATS_TEST_TMPDIR/custody-before.age"
  [ -e "$STATE/stored-after-file" ]
  forwards_closed

  # Interrupted after OpenBao took the write, so the run never heard: the next run finds the key
  # there, changes nothing, and keeps the file, whose master the store holds.
  rm -r "$STATE/kv" "$STATE/stored-after-file" "$VOLSYNC_CUSTODY" "$STATE/interrupt-drops"
  mkdir "$STATE/kv"
  # The second request to the key: the first asks whether it exists.
  echo secrets/data/volsync >"$STATE/interrupt"
  echo 2 >"$STATE/interrupt-at"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "interrupted after the write: $output"
  [ "$status" -ne 0 ]
  master=$(master_in "$VOLSYNC_CUSTODY")
  [ "$(stored RESTIC_MASTER_PASSWORD)" = "$master" ]
  rm "$STATE/interrupt" "$STATE/interrupt-count"
  cp "$VOLSYNC_CUSTODY" "$BATS_TEST_TMPDIR/custody-before.age"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "found the key: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"already holds"* ]]
  [ "$(stored RESTIC_MASTER_PASSWORD)" = "$master" ]
  cmp "$VOLSYNC_CUSTODY" "$BATS_TEST_TMPDIR/custody-before.age"
  forwards_closed

  # The same when OpenBao refuses the write.
  rm -r "$STATE/kv" "$VOLSYNC_CUSTODY"
  mkdir "$STATE/kv"
  : >"$STATE/create-refused"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "write refused: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"from the file"* ]]
  master=$(master_in "$VOLSYNC_CUSTODY")
  rm "$STATE/create-refused"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "continued: $output"
  [ "$status" -eq 0 ]
  [ "$(stored RESTIC_MASTER_PASSWORD)" = "$master" ]
  forwards_closed

  # The same when it is interrupted as the file is put in place, right after the link is made.
  rm -r "$STATE/kv" "$VOLSYNC_CUSTODY"
  mkdir "$STATE/kv"
  fake_tool ln <<LN
printf '%s\n' "ln \$*" >> "\$RECORD/argv"
"$(command -v ln)" "\$@" || exit
kill -INT "\$PPID"
LN
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "interrupted as the file is put in place: $output"
  [ "$status" -ne 0 ]
  [ ! -e "$STATE/kv/volsync.json" ]
  master=$(master_in "$VOLSYNC_CUSTODY")
  [[ $output == *"$VOLSYNC_CUSTODY"* ]]
  [[ $output == *"from the file"* ]]
  [ "$(ls -A "$BATS_TEST_TMPDIR/custody")" = volsync.age ]
  forwards_closed
  record ln
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "continued: $output"
  [ "$status" -eq 0 ]
  [ "$(stored RESTIC_MASTER_PASSWORD)" = "$master" ]
  forwards_closed
}

@test "A rebuilt store is seeded from the existing custody file, never with a new master" {
  local master
  seed_env
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  [ "$status" -eq 0 ]
  master=$(master_in "$VOLSYNC_CUSTODY")
  cp "$VOLSYNC_CUSTODY" "$BATS_TEST_TMPDIR/custody-before.age"
  # The cluster is rebuilt: OpenBao's store is a new one that holds no key, and the cluster has an S3
  # key of its own again.
  rm -r "$STATE/kv"
  rm -f "$STATE/stored-after-file" "$STATE/revoked"
  mkdir "$STATE/kv"
  seed_env marker-rebuilt-id marker-rebuilt-secret
  : >"$RECORD/argv"
  : >"$RECORD/requests"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "$output"
  [ "$status" -eq 0 ]
  # The store's key holds the master the file holds and the cluster's S3 key. No master was made, and
  # the file is as it was.
  [ "$(stored RESTIC_MASTER_PASSWORD)" = "$master" ]
  [ "$(stored AWS_ACCESS_KEY_ID)" = marker-rebuilt-id ]
  [ "$(stored AWS_SECRET_ACCESS_KEY)" = marker-rebuilt-secret ]
  [ "$(grep -c '^head ' "$RECORD/argv")" -eq 0 ]
  cmp "$VOLSYNC_CUSTODY" "$BATS_TEST_TMPDIR/custody-before.age"
  [ "$(ls -A "$BATS_TEST_TMPDIR/custody")" = volsync.age ]
  # It is created only as the probe found no key, and the recipe says it wrote the file's master.
  [ "$(requests_of PATCH secrets/data/volsync | "$JQ" -c '.')" = '{"data":{},"options":{"cas":0}}' ]
  [ "$(requests_of POST secrets/data/volsync | "$JQ" -r '.options.cas')" = 0 ]
  [ -e "$STATE/stored-after-file" ]
  [[ $output == *"master in $VOLSYNC_CUSTODY"* ]]
  [[ $output != *"new master"* ]]
  [ -e "$STATE/revoked" ]
  forwards_closed
  leaked "$output" "$master" marker-rebuilt-id marker-rebuilt-secret

  # The store cannot tell a rebuilt cluster from a new one, so the usage, and the line a seeding with
  # a new master ends with, say that a store that held the key before takes the existing file.
  recipe bao-seed-volsync
  echo "no file: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"held the key before"*"the existing custody file"* ]]
  rm -r "$STATE/kv"
  mkdir "$STATE/kv"
  recipe bao-seed-volsync "$BATS_TEST_TMPDIR/custody/mistake.age"
  echo "a new file on the rebuilt store: $output"
  [ "$status" -eq 0 ]
  [ "$(stored RESTIC_MASTER_PASSWORD)" != "$master" ]
  [[ $output == *"held the key before"*"docs/runbooks/volume-backups.md"* ]]

  # The way back the runbook gives: the key's versions and metadata deleted with a root-policy token
  # through bao-root, which the operator's own may not do, then the store seeded from the old file.
  custody_file marker-seal-key
  echo 5 >"$STATE/recovery-shares"
  fake_tool bao <<'BAO'
printf '%s\n' "bao $*" >> "$RECORD/argv"
# OpenBao's CLI sends kv metadata delete as a DELETE of the key's metadata path.
[[ $* == "kv metadata delete -mount=secrets volsync" ]] || { echo "fake bao: unexpected bao $*" >&2; exit 1; }
response=$(curl --silent --request DELETE --cacert "$BAO_CACERT" \
  --connect-to "$BAO_TLS_SERVER_NAME:8200:localhost:${BAO_ADDR##*:}" --header @<(printf 'X-Vault-Token: %s\n' "$BAO_TOKEN") \
  --write-out '\n%{http_code}' "https://$BAO_TLS_SERVER_NAME:8200/v1/secrets/metadata/volsync")
[[ ${response##*$'\n'} == 204 ]]
BAO
  : >"$RECORD/requests"
  recipe bao-root "$CUSTODY" bao kv metadata delete -mount=secrets volsync
  echo "deleted: $output"
  [ "$status" -eq 0 ]
  [ "$("$JQ" -r 'select(.path == "secrets/metadata/volsync") | .method + " " + .token + " " + .tls' "$RECORD/requests")" = \
    'DELETE marker-orphan-token verified' ]
  [ ! -e "$STATE/kv/volsync.json" ]
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "seeded again: $output"
  [ "$status" -eq 0 ]
  [ "$(stored RESTIC_MASTER_PASSWORD)" = "$master" ]
  cmp "$VOLSYNC_CUSTODY" "$BATS_TEST_TMPDIR/custody-before.age"
  forwards_closed
}

@test "An S3 key variable that is empty or a placeholder stops the recipe before anything is generated" {
  local case name
  # The assignment to make in .env, and the name the recipe must give.
  local -a cases=('CLUSTER_S3_ACCESS_KEY_ID= CLUSTER_S3_ACCESS_KEY_ID'
    'CLUSTER_S3_SECRET_ACCESS_KEY= CLUSTER_S3_SECRET_ACCESS_KEY'
    'CLUSTER_S3_ACCESS_KEY_ID=example-cluster-id CLUSTER_S3_ACCESS_KEY_ID'
    'CLUSTER_S3_SECRET_ACCESS_KEY=example-cluster-secret CLUSTER_S3_SECRET_ACCESS_KEY'
    'CLUSTER_S3_ACCESS_KEY_ID=marker-state-id CLUSTER_S3_ACCESS_KEY_ID')
  for case in "${cases[@]}"; do
    echo "case: $case"
    seed_env
    : >"$RECORD/argv"
    sed -i "s/^${case%%=*}=.*/${case%% *}/" "$REPO/.env"
    name=${case##* }
    recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ $output == *"$name"* ]]
    [ ! -e "$VOLSYNC_CUSTODY" ]
    [ "$(find "$BATS_TEST_TMPDIR/custody" -mindepth 1 | wc -l)" -eq 0 ]
    # Nothing reached the cluster, and the value is not repeated.
    [ "$(grep -c -E '^(kubectl|curl) ' "$RECORD/argv")" -eq 0 ]
    [ ! -e "$STATE/forwards" ]
    [[ $output != *example-cluster-* && $output != *marker-state-id* ]]
  done
  # A variable not set at all.
  seed_env
  sed -i '/^CLUSTER_S3_SECRET_ACCESS_KEY=/d' "$REPO/.env"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "unset: $output"
  [ "$status" -ne 0 ]
  [[ $output == *CLUSTER_S3_SECRET_ACCESS_KEY* ]]
  [ ! -e "$VOLSYNC_CUSTODY" ]
}

# shellcheck disable=SC2016 # $master is a jq variable.
@test "Nothing of the master or the S3 key is printed, passed as an argument or written unencrypted" {
  local master targets
  seed_env
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "seeded: $output"
  [ "$status" -eq 0 ]
  master=$(master_in "$VOLSYNC_CUSTODY")
  leaked "$output" "$master" marker-cluster-id marker-cluster-secret marker-service-account-jwt marker-bao-token
  # What the recipe removed was searched too, its private directory among it.
  [ -n "$(find "$RECORD/removed" -name ca.crt)" ]
  # What a run writes and then overwrites in place is not searched once it is gone, so the scripts are
  # read for it: every output redirection of the two scripts and of scripts/lib/openbao.sh goes to
  # /dev/null, a file descriptor, the port-forward's log, OpenBao's CA or the probe's refusal, none
  # of which holds a secret, and the one file they have a tool write, age's --output, is the partial
  # custody file, which age writes encrypted. Placeholders such as <file> in messages, and >=, are
  # no redirections.
  targets=$(cd "$ROOT" && for file in scripts/bao-seed-volsync scripts/bao-volsync-password scripts/lib/openbao.sh; do
    grep -vE '^[[:space:]]*#' "$file" | sed -E 's/<[A-Za-z]+>//g; s/[<>]=//g' |
      grep -oE '(^|[^<>&0-9-])[0-9]*(&>>|&>|>>|>\||>)[[:space:]]*("[^"]*"|&[0-9-]+|[^[:space:];|&)]+)' |
      sed -E 's/^.*(&>>|&>|>>|>\||>)[[:space:]]*//'
  done | grep -vxE '/dev/null|&[0-9]+|&-|"\$log"|"\$work_dir/ca\.crt"|"\$work_dir/refusal"' | sort -u) || true
  echo "written elsewhere: ${targets:-nothing}"
  [ -z "$targets" ]
  [ "$(cd "$ROOT" && grep -ohE -- '--output [^ ]+' scripts/bao-seed-volsync scripts/bao-volsync-password | sort -u)" = \
    '--output "$partial"' ]
  # The master and the key travel in the body of the write, and in no other request.
  [ "$("$JQ" -r --arg master "$master" 'select(.body | contains($master)) | .method + " " + .path' "$RECORD/requests")" = \
    'POST secrets/data/volsync' ]
  # Rotating, going on from the file, and the runs that fail say as little.
  seed_env marker-rotated-id marker-rotated-secret
  recipe bao-seed-volsync --rotate-s3
  echo "rotated: $output"
  [ "$status" -eq 0 ]
  leaked "$output" "$master" marker-rotated-id marker-rotated-secret
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "again: $output"
  [ "$status" -ne 0 ]
  leaked "$output" "$master" marker-rotated-id marker-rotated-secret
  rm -r "$STATE/kv"
  mkdir "$STATE/kv"
  : >"$STATE/create-refused"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "write refused: $output"
  [ "$status" -ne 0 ]
  leaked "$output" "$master" marker-rotated-id marker-rotated-secret
  rm "$STATE/create-refused"
  # The second request to the key: the first asks whether it exists.
  echo secrets/data/volsync >"$STATE/interrupt"
  echo 2 >"$STATE/interrupt-at"
  : >"$STATE/interrupt-drops"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "interrupted: $output"
  [ "$status" -ne 0 ]
  leaked "$output" "$master" marker-rotated-id marker-rotated-secret
}

@test "One application's repository password is derived from the custody file without printing it" {
  local master password other name
  seed_env
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  [ "$status" -eq 0 ]
  master=$(master_in "$VOLSYNC_CUSTODY")
  # The command it runs says what reached its environment, into files, and prints nothing: the
  # values it is given, the name of every variable it got, and the name of each that holds a value
  # of the state key, its passphrase or the cloud credential.
  fake report-env <<EOF
{
  echo "password=\$RESTIC_PASSWORD"
  echo "repository=\$RESTIC_REPOSITORY"
  echo "key=\$AWS_ACCESS_KEY_ID:\$AWS_SECRET_ACCESS_KEY region=\$AWS_DEFAULT_REGION"
  echo "args=\$*"
} > "$STATE/command-env"
compgen -e > "$STATE/command-names"
for name in \$(compgen -e); do
  [[ \${!name} != *marker-state-* && \${!name} != *marker-cloud-* ]] || echo "\$name"
done > "$STATE/command-foreign"
EOF
  : >"$RECORD/argv"
  recipe bao-volsync-password "$VOLSYNC_CUSTODY" volsync-demo report-env snapshots latest
  echo "$output"
  [ "$status" -eq 0 ]
  password=$(printf '%s/%s' "$master" volsync-demo | sha256sum | cut -d' ' -f1)
  [ "$(cat "$STATE/command-env")" = "$(printf '%s\n' "password=$password" \
    'repository=s3:https://s3.example.com/marker-prefix-volsync/volsync-demo' \
    'key=marker-cluster-id:marker-cluster-secret region=marker-region' 'args=snapshots latest')" ]
  # No other secret of the environment reaches it: not the Talos age key's location, the cluster's
  # key under its own names, the state key, its passphrase or the cloud credential. Nor does a file
  # for a shell it starts to read first, BASH_ENV or ENV, which the recipe was given.
  for name in SOPS_AGE_KEY_FILE CLUSTER_S3_ACCESS_KEY_ID CLUSTER_S3_SECRET_ACCESS_KEY TF_STATE_PASSPHRASE \
    OS_APPLICATION_CREDENTIAL_SECRET BASH_ENV ENV; do
    ! grep -qx "$name" "$STATE/command-names" || { echo "$name reached the command"; return 1; }
  done
  [ ! -s "$STATE/command-foreign" ] || { echo "reached the command: $(cat "$STATE/command-foreign")"; return 1; }
  # It reaches neither the cluster nor OpenBao, and prints nothing.
  [ "$(grep -c -E '^(kubectl|curl) ' "$RECORD/argv")" -eq 0 ]
  [ -z "$output" ]
  leaked "$output" "$master" "$password" marker-cluster-id marker-cluster-secret
  # Another application's password differs.
  recipe bao-volsync-password "$VOLSYNC_CUSTODY" other-app report-env
  [ "$status" -eq 0 ]
  other=$(printf '%s/%s' "$master" other-app | sha256sum | cut -d' ' -f1)
  [ "$(sed -n 's/^password=//p' "$STATE/command-env")" = "$other" ]
  [ "$other" != "$password" ]
  leaked "$output" "$other"
  # What it refuses: no command, an application that is no name, a file that is no custody file of
  # the volsync master, a missing file.
  rm "$STATE/command-env"
  recipe bao-volsync-password "$VOLSYNC_CUSTODY" volsync-demo
  echo "no command: $output"
  [ "$status" -ne 0 ]
  recipe bao-volsync-password "$VOLSYNC_CUSTODY" '../Demo' report-env
  echo "bad name: $output"
  [ "$status" -ne 0 ]
  custody_file marker-seal-key
  recipe bao-volsync-password "$CUSTODY" volsync-demo report-env
  echo "another custody file: $output"
  [ "$status" -ne 0 ]
  recipe bao-volsync-password "$BATS_TEST_TMPDIR/custody/missing.age" volsync-demo report-env
  echo "missing: $output"
  [ "$status" -ne 0 ]
  [ ! -e "$STATE/command-env" ]
  # The command's own failure is the recipe's.
  fake report-env <<<'exit 7'
  recipe bao-volsync-password "$VOLSYNC_CUSTODY" volsync-demo report-env
  [ "$status" -eq 7 ]
}

@test "A custody file is read only where no one but the operator can have written it" {
  local master dir open
  seed_env
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  [ "$status" -eq 0 ]
  master=$(master_in "$VOLSYNC_CUSTODY")
  dir=$BATS_TEST_TMPDIR/custody
  # A store that holds no key, as on a rebuilt cluster: the file would be read and its master written.
  rm -r "$STATE/kv"
  mkdir "$STATE/kv"

  # The file writable by its group, or by others.
  : >"$RECORD/argv"
  chmod 620 "$VOLSYNC_CUSTODY"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "group-writable: $output"
  refused_before_reaching "$VOLSYNC_CUSTODY is writable by its group or others"
  chmod 602 "$VOLSYNC_CUSTODY"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "writable by others: $output"
  refused_before_reaching "$VOLSYNC_CUSTODY is writable by its group or others"
  chmod 600 "$VOLSYNC_CUSTODY"
  # The file another user's.
  printf '%s\n' "$VOLSYNC_CUSTODY" >"$STATE/foreign"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "another user's file: $output"
  refused_before_reaching "$VOLSYNC_CUSTODY is owned by another user"
  # Its directory writable by its group, or another user's.
  rm "$STATE/foreign"
  chmod 775 "$dir"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "group-writable directory: $output"
  refused_before_reaching "$dir is writable by its group or others"
  chmod 755 "$dir"
  printf '%s\n' "$dir" "$(realpath "$dir")" >"$STATE/foreign"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "another user's directory: $output"
  refused_before_reaching "$dir is owned by another user"
  rm "$STATE/foreign"
  # A directory further up writable by others, without the sticky bit that keeps them from replacing
  # what they do not own; with it, the file is read.
  open=$BATS_TEST_TMPDIR/open
  mkdir -p "$open/inner"
  chmod 700 "$open/inner"
  cp -p "$VOLSYNC_CUSTODY" "$open/inner/volsync.age"
  chmod 777 "$open"
  recipe bao-seed-volsync "$open/inner/volsync.age"
  echo "a directory above writable by others: $output"
  refused_before_reaching "$open is writable by its group or others"
  [ ! -e "$STATE/kv/volsync.json" ]
  chmod 1777 "$open"
  recipe bao-seed-volsync "$open/inner/volsync.age"
  echo "with the sticky bit: $output"
  [ "$status" -eq 0 ]
  [ "$(stored RESTIC_MASTER_PASSWORD)" = "$master" ]
  rm -r "$STATE/kv"
  mkdir "$STATE/kv"
  # A symbolic link to the file is not the file.
  ln -s "$VOLSYNC_CUSTODY" "$BATS_TEST_TMPDIR/link.age"
  : >"$RECORD/argv"
  recipe bao-seed-volsync "$BATS_TEST_TMPDIR/link.age"
  echo "a link: $output"
  refused_before_reaching "$BATS_TEST_TMPDIR/link.age is not a file"
  # A new file goes only where it would be read later.
  mkdir "$BATS_TEST_TMPDIR/shared"
  chmod 770 "$BATS_TEST_TMPDIR/shared"
  recipe bao-seed-volsync "$BATS_TEST_TMPDIR/shared/volsync.age"
  echo "a new file in a shared directory: $output"
  refused_before_reaching "$BATS_TEST_TMPDIR/shared is writable by its group or others"
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/shared")" ]
  [ ! -e "$STATE/kv/volsync.json" ]

  # The recipes that read the custody files refuse the same.
  fake report-env <<<': > "'"$STATE"'/command-ran"'
  chmod 660 "$VOLSYNC_CUSTODY"
  recipe bao-volsync-password "$VOLSYNC_CUSTODY" volsync-demo report-env
  echo "bao-volsync-password: $output"
  refused_before_reaching "$VOLSYNC_CUSTODY is writable by its group or others"
  recipe bao-volsync-password "$BATS_TEST_TMPDIR/link.age" volsync-demo report-env
  echo "bao-volsync-password, a link: $output"
  refused_before_reaching "$BATS_TEST_TMPDIR/link.age is a symbolic link"
  [ ! -e "$STATE/command-ran" ]
  custody_file marker-seal-key
  echo 5 >"$STATE/recovery-shares"
  chmod 660 "$CUSTODY"
  recipe bao-root "$CUSTODY" report-env
  echo "bao-root: $output"
  refused_before_reaching "$CUSTODY is writable by its group or others"
  [ ! -e "$STATE/command-ran" ]
  recipe bao-seal-restore "$CUSTODY"
  echo "bao-seal-restore: $output"
  refused_before_reaching "$CUSTODY is writable by its group or others"
  [ ! -e "$STATE/seal-created" ]
  leaked "$output" "$master" marker-cluster-id marker-cluster-secret
}

# shellcheck disable=SC2016 # $master is a jq variable.
@test "A recipe refuses to run while the shell traces its commands" {
  local recipe name secret
  seed_env
  custody_file marker-seal-key
  echo 5 >"$STATE/recovery-shares"
  "$JQ" -n --arg master "$(printf 'b%.0s' {1..64})" '{cluster: "lab-sto2", volsync: {master: $master}}' |
    age --encrypt --recipient "$RECIPIENT" --output "$VOLSYNC_CUSTODY"
  fake report-env <<<': > "'"$STATE"'/command-ran"'
  printf 'set -x\n' >"$BATS_TEST_TMPDIR/trace-env"
  # traced HOW RECIPE [ARG...]: runs the recipe as the operator would, without the tests' own
  # tracing: through just with SHELLOPTS=xtrace in the environment, the same with the tests' trace
  # directory named but the trace on standard error, through just with a BASH_ENV that sets -x, or
  # as its script under bash -x.
  traced() {
    local how=$1
    shift
    local -a run_env=(HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$SYS" TMPDIR="$BATS_TEST_TMPDIR/tmp"
      SOPS_AGE_KEY_FILE="$BATS_TEST_TMPDIR/keys/talos.agekey")
    case $how in
      shellopts) run timeout 120 env -i "${run_env[@]}" SHELLOPTS=xtrace "$JUST" --justfile "$ROOT/justfile" \
        --working-directory "$REPO" "$@" <<<marker-secret-value ;;
      named) run timeout 120 env -i "${run_env[@]}" SHELLOPTS=xtrace BAO_TESTS_XTRACE_DIR="$BATS_TEST_TMPDIR/xtrace" \
        "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$@" <<<marker-secret-value ;;
      bash-env) run timeout 120 env -i "${run_env[@]}" BASH_ENV="$BATS_TEST_TMPDIR/trace-env" "$JUST" \
        --justfile "$ROOT/justfile" --working-directory "$REPO" "$@" <<<marker-secret-value ;;
      bash-x)
        local name=$1
        shift
        run timeout 120 env -i "${run_env[@]}" bash -x "scripts/$name" "$@" <<<marker-secret-value
        ;;
    esac
  }
  cd "$REPO"
  for recipe in "bao-put demo/hello greeting" "bao-recovery $BATS_TEST_TMPDIR/custody/recovery.age" \
    "bao-root $CUSTODY report-env" "bao-seal-restore $CUSTODY" "bao-seed-volsync $VOLSYNC_CUSTODY" \
    "bao-volsync-password $VOLSYNC_CUSTODY volsync-demo report-env"; do
    for how in shellopts named bash-env bash-x; do
      : >"$RECORD/argv"
      # shellcheck disable=SC2086 # each recipe is its arguments, split.
      traced "$how" $recipe
      echo "${recipe%% *} under $how: $output"
      refused_before_reaching "traces each command"
      for secret in marker-state-secret marker-cluster-secret marker-state-passphrase marker-cloud-secret \
        marker-secret-value AGE-SECRET-KEY marker-seal-key bbbbbbbbbbbbbbbb; do
        [[ $output != *"$secret"* ]] || { echo "$secret in the output"; return 1; }
      done
      [ "$(grep -c -E '^age ' "$RECORD/argv")" -eq 0 ]
      [ ! -e "$STATE/command-ran" ]
      [ ! -e "$BATS_TEST_TMPDIR/custody/recovery.age" ]
    done
  done
  # The tests' own tracing, into a file of theirs, still lets a recipe run.
  recipe bao-put demo/hello greeting <<<"marker-secret-value"
  echo "traced by the tests: $output"
  [ "$status" -eq 0 ]
  by_name
}

@test "What the recipes print of OpenBao's and kubectl's errors holds no control character and no address" {
  seed_env
  # OpenBao's error text, with the escape sequences a terminal acts on, is shown with each control
  # character as a question mark.
  : >"$STATE/kv-noisy"
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"OpenBao answered 500 to PATCH secrets/data/volsync: internal ?[31merror? ??2J done"* ]]
  no_controls "$output"
  forwards_closed
  rm "$STATE/kv-noisy"
  # kubectl's errors, which name the API server, say why without its address or a control character.
  : >"$STATE/api-unreachable"
  recipe bao-put demo/hello greeting <<<"marker-secret-value"
  echo "bao-put: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"Unable to connect to the server: dial tcp "*"i/o timeout"* ]]
  [[ $output != *192.0.2.10* ]]
  no_controls "$output"
  forwards_closed
  recipe bao-seed-volsync "$VOLSYNC_CUSTODY"
  echo "bao-seed-volsync: $output"
  [ "$status" -ne 0 ]
  [[ $output == *"Unable to connect to the server"* && $output != *192.0.2.10* ]]
  no_controls "$output"
  forwards_closed
}
