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
# its environment, the Talos age key's location included. A recipe that blocks fails after two
# minutes instead of hanging the tests.
recipe() {
  run timeout 120 env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" TMPDIR="$BATS_TEST_TMPDIR/tmp" \
    SOPS_AGE_KEY_FILE="$BATS_TEST_TMPDIR/keys/talos.agekey" \
    "$JUST" --justfile "$ROOT/justfile" --working-directory "$REPO" "$@"
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
#   no-forward        the port-forward fails to start
#   interrupt         curl sends SIGINT to the recipe's script at the request whose path it names,
#   interrupt-at      at the Nth request to that path (the first when absent)
#   recovery-shares   how many recovery key shares exist; none when absent
#   stale-rotation    a rotation of the recovery keys is in progress already
#   clobber           curl writes that file, as someone else would, when the rotation starts
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
  fi
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
  "PATCH secrets/data/"*)
    [[ -e $STATE/write-refused ]] && respond 403 '{"errors":["permission denied"]}'
    file=$STATE/kv/${path#secrets/data/}.json
    [[ -f $file ]] || respond 404 '{"errors":[]}'
    "$JQ" -c --argjson patch "$("$JQ" -c '.data' <<< "$body")" '. * $patch' "$file" > "$file.new" && mv "$file.new" "$file"
    respond 200 "$(envelope '{"created_time":"2026-11-14T00:00:00Z","custom_metadata":null,"deletion_time":"","destroyed":false,"version":2}')"
    ;;
  "POST secrets/data/"*)
    [[ -e $STATE/write-refused ]] && respond 403 '{"errors":["permission denied"]}'
    file=$STATE/kv/${path#secrets/data/}.json
    if [[ -f $file && $("$JQ" -r '.options.cas // "unset"' <<< "$body") == 0 ]]; then
      respond 400 '{"errors":["check-and-set parameter did not match the current version"]}'
    fi
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
  for secret in "$key" "$other" "$(printf %s "$key" | base64 -w0)" "$(printf %s "$other" | base64 -w0)"; do
    [[ $output != *"$secret"* ]] || { echo "a key in the output"; return 1; }
    absent "$secret" "$RECORD/argv"
  done
}
