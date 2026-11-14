#!/usr/bin/env bats
# Proves the recipe scenarios of features/openbao.feature; each test carries its scenario's title.
# The recipes run from a copy of the repository against recording fakes of kubectl and curl: a
# cluster whose port-forward runs until it is stopped, and an OpenBao behind it that answers as its
# API does. age and age-keygen are the pinned ones, offline, with a throwaway key in the test's
# directory; jq, age, base64, cat, sed and grep are recorded on their way, so every command line the
# recipes run is in the record.

# The fakes keep their state in each test's own directory, and a test waits for the port-forwards
# it started; nothing is shared between tests, which may run side by side.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  JUST=$(command -v just)
  JQ=$(command -v jq)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$BIN" "$RECORD" "$STATE/kv" "$BATS_TEST_TMPDIR/repo/talos/lab-sto2/clusterconfig" \
    "$BATS_TEST_TMPDIR/keys" "$BATS_TEST_TMPDIR/custody" "$BATS_TEST_TMPDIR/tmp"
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
  record jq age base64 cat sed grep
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

# recipe NAME [ARG...]: runs the repository's recipe against the copy, with only what it needs in
# its environment. A recipe that blocks fails after two minutes instead of hanging the tests.
recipe() {
  run timeout 120 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$@"
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
#   login-refused   OpenBao refuses the login
#   write-refused   OpenBao refuses every write to the key-value mount
#   no-forward      the port-forward fails to start
#   interrupt       curl sends SIGINT to the recipe's script at the request whose path it names
#   recovery-shares how many recovery key shares exist; none when absent
#   kv/<path>.json  the data of a secret at <path> in the key-value mount
#   outfile         the custody file, which must exist when the rotation is verified
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
  *" create token openbao-operator "*)
    echo marker-service-account-jwt
    ;;
  *" get secret openbao-ca "*)
    printf -- '-----BEGIN CERTIFICATE-----\nmarker-ca\n-----END CERTIFICATE-----\n' | base64 -w0
    ;;
  *" get secret openbao-seal-1 "*)
    "$JQ" -n --arg key "$(printf marker-seal-key | base64 -w0)" '{data: {key: $key}}'
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
  # The topmost process running the recipe's script, past the subshells of its pipelines.
  pid=$PPID target=""
  while ((pid > 1)); do
    if tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q 'scripts/bao-'; then target=$pid; fi
    pid=$(awk '{print $4}' "/proc/$pid/stat")
  done
  kill -INT "$target"
fi
respond() {
  printf '%s' "$2"
  if [[ -n $write_out ]]; then printf '\n%s' "$1"; fi
  exit 0
}
recovery=$(cat "$STATE/recovery-shares" 2> /dev/null || echo 0)
if [[ $path != sys/seal-status && $path != auth/kubernetes/login && $token != marker-bao-token ]]; then
  respond 403 '{"errors":["permission denied"]}'
fi
case "$method $path" in
  "POST auth/kubernetes/login")
    [[ -e $STATE/login-refused ]] && respond 400 '{"errors":["permission denied"]}'
    if [[ $("$JQ" -r '.role + " " + .jwt' <<< "$body") == "operator marker-service-account-jwt" ]]; then
      respond 200 '{"auth":{"client_token":"marker-bao-token","lease_duration":600}}'
    fi
    respond 400 '{"errors":["invalid role or service account"]}'
    ;;
  "POST auth/token/revoke-self")
    : > "$STATE/revoked"
    respond 204 ''
    ;;
  "PATCH secrets/data/"*)
    [[ -e $STATE/write-refused ]] && respond 403 '{"errors":["permission denied"]}'
    file=$STATE/kv/${path#secrets/data/}.json
    [[ -f $file ]] || respond 404 '{"errors":[]}'
    "$JQ" -c --argjson patch "$("$JQ" -c '.data' <<< "$body")" '. * $patch' "$file" > "$file.new" && mv "$file.new" "$file"
    respond 200 '{"data":{"version":2}}'
    ;;
  "POST secrets/data/"*)
    [[ -e $STATE/write-refused ]] && respond 403 '{"errors":["permission denied"]}'
    file=$STATE/kv/${path#secrets/data/}.json
    if [[ -f $file && $("$JQ" -r '.options.cas // "unset"' <<< "$body") == 0 ]]; then
      respond 400 '{"errors":["check-and-set parameter did not match the current version"]}'
    fi
    mkdir -p "$(dirname "$file")"
    "$JQ" -c '.data' <<< "$body" > "$file"
    respond 200 '{"data":{"version":1}}'
    ;;
  "GET sys/seal-status")
    respond 200 "{\"type\":\"static\",\"initialized\":true,\"sealed\":false,\"recovery_seal\":true,\"t\":$((recovery > 0 ? 3 : 0)),\"n\":$recovery}"
    ;;
  "POST sys/rotate/recovery/init")
    if ((recovery > 0)); then
      respond 200 '{"data":{"started":true,"nonce":"marker-rotation-nonce","t":3,"n":5,"progress":0,"required":3}}'
    fi
    "$JQ" -c . <<< "$body" > "$STATE/pending"
    respond 200 "$("$JQ" -c '{data: {complete: true, t: .secret_threshold, n: .secret_shares,
      verification_required: .require_verification, verification_nonce: "marker-verification-nonce",
      keys: [range(.secret_shares) | "marker-recovery-share-\(. + 1)"],
      keys_base64: [range(.secret_shares) | "marker-recovery-share-\(. + 1)" | @base64]}}' <<< "$body")"
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
      respond 200 '{"data":{"complete":true,"nonce":"marker-verification-nonce"}}'
    fi
    respond 200 "{\"data\":{\"complete\":false,\"progress\":$(sort -u "$STATE/verified" | wc -l)}}"
    ;;
  "DELETE sys/rotate/recovery/init")
    : > "$STATE/cancelled"
    rm -f "$STATE/pending"
    respond 204 ''
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
  local -a cases=('' 'demo/hello' '../demo greeting' '/demo greeting' 'demo//hello greeting'
    'demo/hello gre/eting' 'demo/.. greeting' 'demo/hello -greeting')
  local args
  for args in "${cases[@]}"; do
    # shellcheck disable=SC2086 # each case is its arguments, split.
    recipe bao-put $args <<<"marker-secret-value"
    echo "bao-put $args: $output"
    [ "$status" -ne 0 ]
    [[ $output == *bao-put:* ]]
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
  [ "$(grep -c -E '^(kubectl|curl) ' "$RECORD/argv")" -eq 0 ]
}
