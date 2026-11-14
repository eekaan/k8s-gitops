#!/usr/bin/env bats
# Proves the scenarios of features/infrastructure-state.feature about which tool sees which secret.
# Every tool the recipes run is a recording fake that writes the names, never the values, of the
# variables in its environment; the scripts' libraries run from a copy of the repository with only
# the environment each test gives them.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  BIN="$BATS_TEST_TMPDIR/bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$BIN" "$RECORD" "$REPO/infra/openstack" "$REPO/talos"
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp "$ROOT/infra/openstack/backend.hcl" "$REPO/infra/openstack/backend.hcl"
  for tool in tofu openstack talman talosctl kubectl helm flux kustomize docker sops age age-keygen gh ssh ssh-keyscan ssh-keygen; do
    cat > "$BIN/$tool" <<EOF
#!/usr/bin/env bash
env | cut -d= -f1 | sort > "$RECORD/names.$tool"
EOF
    chmod +x "$BIN/$tool"
  done
  # The S3 client says which key pair it got, as a word, and never the keys.
  cat > "$BIN/rclone" <<EOF
#!/usr/bin/env bash
env | cut -d= -f1 | sort > "$RECORD/names.rclone"
case "\$RCLONE_CONFIG_STORE_ACCESS_KEY_ID:\$RCLONE_CONFIG_STORE_SECRET_ACCESS_KEY" in
  marker-state-id:marker-state-secret) echo state > "$RECORD/pair.rclone" ;;
  marker-cluster-id:marker-cluster-secret) echo cluster > "$RECORD/pair.rclone" ;;
  *) echo other > "$RECORD/pair.rclone" ;;
esac
EOF
  chmod +x "$BIN/rclone"
  # Every secret variable the recipes may be given, as a marker, and variables that are no secret.
  SECRET_NAMES=(
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_BACKUP_SECRET TF_STATE_PASSPHRASE
    TF_ENCRYPTION
    CLUSTER_S3_ACCESS_KEY_ID CLUSTER_S3_SECRET_ACCESS_KEY SOPS_AGE_KEY SOPS_AGE_KEY_FILE
    SOPS_AGE_KEY_CMD FLUX_AGE_KEY FLUX_AGE_KEY_FILE OPERATOR_CIDRS OS_CLOUD OS_AUTH_URL
    OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET TF_VAR_api_allowed_cidrs
    TF_VAR_image_name TF_VAR_ci_host_number TF_TOKEN_registry_example_com
  )
  PLAIN_NAMES=(TF_STATE_BUCKET BACKUP_BUCKET_PREFIX KUBE_API_ADDRESS KUBECONFIG TALMAN_CONFIG)
  ENVIRONMENT=()
  for name in "${SECRET_NAMES[@]}" "${PLAIN_NAMES[@]}"; do
    ENVIRONMENT+=("$name=marker-$name")
  done
  # The S3 keys the client is called with.
  ENVIRONMENT+=(AWS_ACCESS_KEY_ID=marker-state-id AWS_SECRET_ACCESS_KEY=marker-state-secret
    CLUSTER_S3_ACCESS_KEY_ID=marker-cluster-id CLUSTER_S3_SECRET_ACCESS_KEY=marker-cluster-secret)
}

# in_recipe COMMAND [ARG...]: COMMAND as a recipe runs it, after the libraries every recipe reads
# are sourced, with only ENVIRONMENT set and the fakes first on PATH.
in_recipe() {
  # shellcheck disable=SC2016 # the inner bash expands $1, its own argument
  run env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    bash -c '. "$1/scripts/lib/snapshot.sh" && shift && "$@"' _ "$REPO" "$@"
}

# with ENTRY...: adds the NAME=VALUE ENTRY... to the environment in_recipe gives.
with() {
  ENVIRONMENT+=("$@")
}

# seen TOOL: the secret variables the TOOL's last run had in its environment, sorted, one line.
seen() {
  local name
  for name in "${SECRET_NAMES[@]}"; do
    if grep -qx "$name" "$RECORD/names.$1"; then
      echo "$name"
    fi
  done | sort | paste -sd' ' -
}

# sorted NAME...: the names, sorted, on one line.
sorted() {
  if (($# == 0)); then
    return 0
  fi
  printf '%s\n' "$@" | sort | paste -sd' ' -
}

@test "Each tool gets only the secrets it uses" {
  cloud=(OS_CLOUD OS_AUTH_URL OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET)
  tofu=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_BACKUP_SECRET TF_ENCRYPTION "${cloud[@]}"
    TF_VAR_api_allowed_cidrs TF_VAR_image_name TF_VAR_ci_host_number TF_TOKEN_registry_example_com)
  sops=(SOPS_AGE_KEY SOPS_AGE_KEY_FILE SOPS_AGE_KEY_CMD)
  declare -A expected=(
    [tofu]=$(sorted "${tofu[@]}")
    [openstack]=$(sorted "${cloud[@]}")
    [talman]=$(sorted "${sops[@]}")
    [sops]=$(sorted "${sops[@]}")
    [age]=SOPS_AGE_KEY_FILE
    [talosctl]=""
    [kubectl]=""
    [helm]=""
    [flux]=""
    [kustomize]=""
    [docker]=""
    [age-keygen]=""
    [gh]=""
    [ssh]=""
    [ssh-keyscan]=""
    [ssh-keygen]=""
  )
  for tool in "${!expected[@]}"; do
    echo "$tool"

    in_recipe "$tool" some arguments

    [ "$status" -eq 0 ]
    [ "$(seen "$tool")" = "${expected[$tool]}" ]
    # What is no secret reaches every tool.
    for name in "${PLAIN_NAMES[@]}"; do
      grep -qx "$name" "$RECORD/names.$tool"
    done
  done
}

@test "The S3 client gets the one key pair it is called with and no other secret" {
  for keyset in state cluster; do
    echo "$keyset"
    rm -f "$RECORD/pair.rclone" "$RECORD/names.rclone"

    in_recipe s3_rclone "$keyset" lsf store:

    [ "$status" -eq 0 ]
    [ "$(cat "$RECORD/pair.rclone")" = "$keyset" ]
    [ -z "$(seen rclone)" ]
  done
}

# wrapped_tools: the tools tools.sh wraps, one per line.
wrapped_tools() {
  sed -nE 's/^([a-z-]+)\(\) \{ run_tool .*/\1/p' "$ROOT/scripts/lib/tools.sh"
}

# logical_lines FILE: FILE's commands, each as NUMBER:TEXT with NUMBER the line it starts on. A
# command continued by a backslash is one command; so is the body of a shell's -c argument that
# runs over lines, and a here-document fed to a shell, which are commands. A here-document fed to
# anything else is data, and left out.
logical_lines() {
  awk '
    function quotes(text, q,    copy) {
      copy = text
      return gsub(q, "", copy)
    }
    function emit() {
      if (command != "") print start ":" command
      command = ""
    }
    {
      line = $0
      if (heredoc != "") {
        stripped = line
        sub(/^[\t]+/, "", stripped)
        if (shell) command = command " " line
        if (stripped == heredoc) heredoc = ""
        if (heredoc == "") { shell = 0; emit() }
        next
      }
      if (command == "") start = NR
      if (open != "") {
        command = command " " line
        if (quotes(line, open) % 2 == 1) open = ""
        if (open == "") emit()
        next
      }
      if (command == "" && line ~ /^[[:space:]]*#/) {
        print NR ":" line
        next
      }
      continued = (line ~ /\\$/)
      if (continued) sub(/\\$/, "", line)
      command = (command == "" ? line : command " " line)
      if (continued) next
      if (match(line, /(^|[^[:alnum:]_.-])(bash|sh|dash|zsh)[[:space:]]+(-[A-Za-z-]+[[:space:]]+)*-[A-Za-z]*c[[:space:]]+["\047]/)) {
        rest = substr(line, RSTART + RLENGTH - 1)
        q = substr(rest, 1, 1)
        if (quotes(rest, q) % 2 == 1) { open = q; next }
      }
      if (match(line, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
        word = substr(line, RSTART, RLENGTH)
        gsub(/^<<-?[[:space:]]*["\047]?/, "", word)
        heredoc = word
        shell = (line ~ /(^|[^[:alnum:]_.-])(bash|sh|dash|zsh)[[:space:]]/ && line !~ /ssh/)
        if (!shell) emit()
        next
      }
      emit()
    }
    END { emit() }
  ' "$1"
}

# bypasses: the commands on standard input that run a wrapped tool around its wrapper.
bypasses() {
  local alternation runner shell found
  alternation=$(wrapped_tools | paste -sd'|' -)
  runner='(command|env|exec|timeout|xargs|sudo|nice|nohup|setsid|stdbuf|which|ionice|chroot|su|doas|flock|watch|parallel|mise[[:space:]]+(x|exec)|-exec|-execdir|-ok)'
  shell='(bash|sh|dash|zsh)[[:space:]]+(-[A-Za-z-]+[[:space:]]+)*(-[A-Za-z]*c|<<)'
  tool='(^|[^[:alnum:]_.$-])('"$alternation"')([^[:alnum:]_.-]|$)'
  found='(^|[^[:alnum:]_.-])'"$runner"'[[:space:]]+([^;|&]*[^[:alnum:]_.$-])?('"$alternation"')([^[:alnum:]_.-]|$)'
  found+='|(^|[^[:alnum:]_.-])'"$shell"'.*'"$tool"
  found+='|(\$\(|`)[[:space:]]*type -a?P ('"$alternation"')[^[:alnum:]_.-]'
  # shellcheck disable=SC2016 # flux=$(type -P flux) is text to leave out, not an expansion
  grep -E "$found" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vF 'flux=$(type -P flux)'
}

# scan_text TEXT: bypasses of the commands TEXT holds, as a script file would.
scan_text() {
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/scanned"
  logical_lines "$BATS_TEST_TMPDIR/scanned" | bypasses
}

@test "A sops run for the Flux key sees only that key, as the one age key it is given" {
  # This sops says which value its one age variable holds, as a word, and never the key.
  cat > "$BIN/sops" <<EOF
#!/usr/bin/env bash
env | cut -d= -f1 | sort > "$RECORD/names.sops"
case "\${SOPS_AGE_KEY-}:\${SOPS_AGE_KEY_FILE-}" in
  marker-FLUX_AGE_KEY:) echo flux-key > "$RECORD/holds.sops" ;;
  :marker-FLUX_AGE_KEY_FILE) echo flux-key-file > "$RECORD/holds.sops" ;;
  *) echo other > "$RECORD/holds.sops" ;;
esac
EOF
  chmod +x "$BIN/sops"

  # In CI the key itself is set, and the Talos key's variables are set as well.
  in_recipe flux_sops decrypt file

  [ "$status" -eq 0 ]
  [ "$(seen sops)" = SOPS_AGE_KEY ]
  [ "$(cat "$RECORD/holds.sops")" = flux-key ]

  # On a workstation the key is a file's path.
  with FLUX_AGE_KEY=
  in_recipe flux_sops decrypt file

  [ "$status" -eq 0 ]
  [ "$(seen sops)" = SOPS_AGE_KEY_FILE ]
  [ "$(cat "$RECORD/holds.sops")" = flux-key-file ]
}

@test "The scan for a wrapped tool run around its wrapper flags every way of doing it" {
  local case
  # Each is one command, which may span lines, as text: nothing in them is to expand.
  # shellcheck disable=SC2016
  local -a flagged=(
    'env -u KUBECTL_EXTERNAL_DIFF kubectl wait nodes'
    'SOPS_AGE_KEY=$key env -u SOPS_AGE_KEY_FILE -u SOPS_AGE_KEY_CMD sops "$@"'
    'timeout -s KILL 10m kubectl get nodes'
    'sudo -u someone kubectl get nodes'
    'nice -n 5 helm template'
    'xargs -n1 -I{} kubectl delete {}'
    'command kubectl get nodes'
    'exec talman apply'
    '"$(which kubectl)" uncordon "$node"'
    '"$(command -v kubectl)" uncordon "$node"'
    'helm=$(type -P helm)'
    'helm=$(type -aP helm)'
    'helm=`type -P helm`'
    'helm=`which helm`'
    "bash -c 'kubectl get nodes'"
    'sh -c "echo; sops decrypt f"'
    "bash -lc 'flux build'"
    'flock /tmp/lock kubectl get nodes'
    'watch -n 5 kubectl get nodes'
    'parallel kubectl get node ::: a b'
    'find . -name x -exec kubectl apply -f {} +'
    'mise x -- helm template'
    'mise exec -- helm template'
    $'env -u KUBECTL_EXTERNAL_DIFF \\\n  kubectl wait nodes'
    $'timeout 10m \\\n  -s KILL \\\n  kubectl wait nodes'
    $'bash -c \'\n  echo start\n  kubectl wait nodes\n\''
    $'sh -c "\n  echo start\n  helm template\n"'
    $'bash <<EOS\necho start\nkubectl wait nodes\nEOS'
    $'sh <<-\'EOS\'\n\tflux build\nEOS'
  )
  for case in "${flagged[@]}"; do
    echo "flagged: $case"
    run scan_text "$case"
    [ "$status" -eq 0 ]
  done
  # shellcheck disable=SC2016
  local -a plain=(
    'kubectl get nodes'
    'kubectl wait nodes --all --for=condition=Ready'
    'SOPS_AGE_KEY=$key sops "$@"'
    'if ! type -P kubectl > /dev/null; then'
    'require_commands kubectl jq'
    'exec "$@"'
    'exec "$flux" envsubst --strict < "$file"'
    'env -u HELM_DEBUG jq -n 1'
    'timeout 10 jq . file'
    '# env -u X kubectl'
    $'echo one \\\n  two\nkubectl get nodes'
    $'bash -c \'\n  echo start\n\'\nkubectl get nodes'
    $'cat <<EOS\nenv kubectl\nEOS'
    $'bash <<EOS\necho start\nEOS\nkubectl get nodes'
  )
  for case in "${plain[@]}"; do
    echo "not flagged: $case"
    run scan_text "$case"
    [ "$status" -ne 0 ]
  done
}

@test "No script runs a wrapped tool around its wrapper" {
  files=("$ROOT"/scripts/* "$ROOT"/scripts/lib/* "$ROOT"/justfile "$ROOT"/just/*.just)
  found=$(
    for file in "${files[@]}"; do
      [ -f "$file" ] && [ "${file##*/}" != tools.sh ] || continue
      logical_lines "$file" | bypasses | sed "s|^|${file#"$ROOT"/}:|" || true
    done
  )
  if [ -n "$found" ]; then
    echo "$found" >&2
    return 1
  fi
}

@test "A variable added to .env.example is assigned to the tools that may see it" {
  mapfile -t names < <(sed -nE 's/^#? ?([A-Z][A-Z0-9_]*)=.*/\1/p' "$ROOT/.env.example")
  [ "${#names[@]}" -gt 20 ]
  for name in "${names[@]}"; do
    echo "$name"
    run bash -c '. "$1/scripts/lib/infra.sh" && variable_assigned "$2"' _ "$REPO" "$name"
    [ "$status" -eq 0 ]
  done
  # A name nothing assigns fails the same check, whatever its prefix: the ones the tools read
  # by prefix are assigned one by one too.
  for name in NEW_SECRET_ACCESS_KEY AWS_BACKUP_SECRET OS_NEW_SECRET TF_VAR_new_secret; do
    echo "$name"
    run bash -c '. "$1/scripts/lib/infra.sh" && variable_assigned "$2"' _ "$REPO" "$name"
    [ "$status" -ne 0 ]
  done
}

@test "the tools' table holds when the libraries are sourced inside a function, among odd variable names" {
  # A name that is no shell identifier, as a container runtime may add to the environment.
  ENVIRONMENT+=('odd-name=1')

  # shellcheck disable=SC2016 # the inner bash expands $1, its own argument
  run env -i HOME="$BATS_TEST_TMPDIR" PATH="$BIN:$PATH" "${ENVIRONMENT[@]}" \
    bash -c 'load() { . "$1/scripts/lib/infra.sh"; }; load "$1" && kubectl get && tofu plan' _ "$REPO"

  [ "$status" -eq 0 ]
  [ -z "$(seen kubectl)" ]
  [ "$(seen tofu | wc -w)" -gt 3 ]
  if grep -qx CLUSTER_S3_ACCESS_KEY_ID "$RECORD/names.tofu"; then
    return 1
  fi
}
