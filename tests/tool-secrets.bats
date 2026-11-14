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
  for tool in tofu openstack talman talosctl kubectl helm flux sops age age-keygen; do
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
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN TF_STATE_PASSPHRASE TF_ENCRYPTION
    CLUSTER_S3_ACCESS_KEY_ID CLUSTER_S3_SECRET_ACCESS_KEY SOPS_AGE_KEY SOPS_AGE_KEY_FILE
    SOPS_AGE_KEY_CMD FLUX_AGE_KEY FLUX_AGE_KEY_FILE OPERATOR_CIDRS OS_CLOUD OS_AUTH_URL
    OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET TF_VAR_api_allowed_cidrs
    TF_VAR_image_name TF_VAR_ci_host_number
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
  tofu=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN TF_ENCRYPTION "${cloud[@]}"
    TF_VAR_api_allowed_cidrs TF_VAR_image_name TF_VAR_ci_host_number)
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
    [age-keygen]=""
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

@test "A variable added to .env.example is assigned to the tools that may see it" {
  mapfile -t names < <(sed -nE 's/^#? ?([A-Z][A-Z0-9_]*)=.*/\1/p' "$ROOT/.env.example")
  [ "${#names[@]}" -gt 20 ]
  for name in "${names[@]}"; do
    echo "$name"
    run bash -c '. "$1/scripts/lib/infra.sh" && variable_assigned "$2"' _ "$REPO" "$name"
    [ "$status" -eq 0 ]
  done
  # A name nothing assigns fails the same check.
  run bash -c '. "$1/scripts/lib/infra.sh" && variable_assigned "$2"' _ "$REPO" NEW_SECRET_ACCESS_KEY
  [ "$status" -ne 0 ]
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
