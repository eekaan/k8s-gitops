# A copy of the repository that can read the edge stack's outputs, for the tests of what fills the
# ConfigMap cluster-config: its EDGE_PUBLIC_ADDRESS keys come from the stack's outputs, which are
# sensitive and which only tofu reads. Loaded with `load fixtures/edge-stack` from a test file.
#
# edge_stack_fixture REPO BIN STATE: makes in REPO the edge stack's configuration and the backend
# file the stack's environment needs (the one REPO has, when it has one), a fake tofu in BIN that
# answers the stack's outputs, and the key pair of the edge stack's SSH key in STATE/keys. The
# outputs are the two edges' names and two addresses from the documentation range, 203.0.113.51
# and 203.0.113.52; the file STATE/no-edge-outputs empties them, as before the stack is applied.
# Sets EDGE_STACK_ENVIRONMENT, the NAME=VALUE entries the stack's environment needs, none of them a
# real credential.
edge_stack_fixture() {
  local repo=$1 bin=$2 state=$3 root
  root=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  mkdir -p "$repo/infra/openstack/stacks/sto2/edge" "$bin" "$state/keys"
  cp "$root"/infra/openstack/stacks/sto2/edge/*.tf "$repo/infra/openstack/stacks/sto2/edge/"
  [[ -f $repo/infra/openstack/backend.hcl ]] || cp "$root/infra/openstack/backend.hcl" "$repo/infra/openstack/backend.hcl"
  echo 'fixture private key, never read' > "$state/keys/edge"
  echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureEdgePublicKeyFixtureFixtureFix fixture' > "$state/keys/edge.pub"
  cat > "$state/edge-outputs.json" << 'EOF'
{"addresses": {"sensitive": true, "value": ["203.0.113.51", "203.0.113.52"]},
 "names": {"sensitive": false, "value": ["lab-edge-1", "lab-edge-2"]}}
EOF
  cat > "$bin/tofu" << EOF
#!/usr/bin/env bash
case \${2-} in
  init) ;;
  output)
    if [[ -e "$state/no-edge-outputs" ]]; then echo '{}'; else cat "$state/edge-outputs.json"; fi
    ;;
  *) echo "unexpected call: tofu \$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$bin/tofu"
  EDGE_STACK_ENVIRONMENT=(
    TF_STATE_BUCKET=fixture-state-bucket
    AWS_ACCESS_KEY_ID=fixture-access-key-id
    AWS_SECRET_ACCESS_KEY=fixture-secret-access-key
    TF_STATE_PASSPHRASE=fixture-state-passphrase
    OS_AUTH_URL=https://identity.example.invalid/v3
    'OPERATOR_CIDRS=["198.51.100.0/24"]'
    EDGE_IMAGE=fixture-image
    EDGE_SSH_KEY_FILE="$state/keys/edge"
  )
}
