# shellcheck shell=bash
# Shared by every script that reads .env, through scripts/lib/infra.sh: each tool a recipe runs
# gets only the secrets it uses. .env and the environment give the recipes the state passphrase,
# both S3 key pairs, the cloud credential, the age keys and the operator allowlist; talman,
# talosctl, kubectl, helm and flux need none of the S3, cloud or state secrets, and tofu needs
# neither the cluster's S3 key nor an age key.
#
# The tools below are shell functions of the same name, so a recipe runs them by name and
# each runs the real binary with the secrets it may not see unexported. Every other variable
# reaches it as it is. The functions come before any binary of the same name in the recipes, so
# command -v finds the function: scripts ask whether a tool is installed with type -P.
#
# A variable is a secret when secret_variable says so, and every name in .env.example is listed
# here, in tool_secrets or in plain_variables, which every tool may see: a name added to .env.example
# is assigned before the repository's tests pass, whatever its prefix. A secret reaches the tools
# tool_secrets names, and none else; s3_rclone does the same for rclone, handing it the one key pair
# it is called with. A name that begins like the cloud credential or the object storage's key, OS_ or
# AWS_, and is listed nowhere is still a secret, which only tofu sees, so that one set in the
# environment by hand reaches no other tool.

# The tools that may see each secret, by name; the empty list is none. TF_ENCRYPTION carries the
# state passphrase, so tofu never needs TF_STATE_PASSPHRASE itself. SOPS_AGE_KEY_FILE names the Talos
# age key for talman, which runs sops, and for age, which decrypts with it by its path; the Flux age
# key reaches sops only through flux_sops, as the one key sops is given. gh alone sees the tokens
# that are its own.
declare -gA tool_secrets=(
  [AWS_ACCESS_KEY_ID]="tofu"
  [AWS_SECRET_ACCESS_KEY]="tofu"
  [AWS_SESSION_TOKEN]="tofu"
  [OS_CLOUD]="tofu openstack"
  [OS_AUTH_URL]="tofu openstack"
  [OS_AUTH_TYPE]="tofu openstack"
  [OS_APPLICATION_CREDENTIAL_ID]="tofu openstack"
  [OS_APPLICATION_CREDENTIAL_SECRET]="tofu openstack"
  [OS_REGION_NAME]="tofu openstack"
  [TF_ENCRYPTION]="tofu"
  [TF_STATE_PASSPHRASE]=""
  [CLUSTER_S3_ACCESS_KEY_ID]=""
  [CLUSTER_S3_SECRET_ACCESS_KEY]=""
  [SOPS_AGE_KEY]="talman sops"
  [SOPS_AGE_KEY_FILE]="talman sops age"
  [SOPS_AGE_KEY_CMD]="talman sops"
  [FLUX_AGE_KEY]=""
  [FLUX_AGE_KEY_FILE]=""
  [OPERATOR_CIDRS]=""
  [GH_TOKEN]="gh"
  [GITHUB_TOKEN]="gh"
)

# The variables of .env.example that hold no secret: deployment values and settings. Every tool
# sees these, so a key, token, passphrase or credential never belongs here; it goes in tool_secrets.
plain_variables=(
  TF_STATE_BUCKET BACKUP_BUCKET_PREFIX CI_HOST_IMAGE CI_HOST_SSH_PUBLIC_KEY CI_HOST_SSH_USER
  KUBE_API_ADDRESS TALOS_WAIT CLUSTER_DOMAIN ADOPTION_INTERVAL ADOPTION_WAIT
  GRAFANA_PORT GRAFANA_WAIT
)

# secret_variable NAME: whether NAME is a secret: one tool_secrets lists, or one of the families the
# tools read by prefix, the cloud credential's OS_*, the object storage's AWS_* and the inputs the
# stacks take, TF_VAR_*. stack-env makes the last from the stacks' own variables, so none is written
# by hand or named in .env.example.
secret_variable() {
  case $1 in
    OS_* | AWS_* | TF_VAR_*) return 0 ;;
  esac
  [[ -n ${tool_secrets[$1]+set} ]]
}

# variable_assigned NAME: whether NAME is listed, in tool_secrets or in plain_variables. A prefix
# does not assign it.
variable_assigned() {
  [[ -n ${tool_secrets[$1]+set} || " ${plain_variables[*]} " == *" $1 "* ]]
}

# tool_sees TOOL NAME: whether TOOL may see the secret NAME. A listed name goes to the tools its
# entry names. One that is not listed goes by its family: tofu reads the object storage's key, the
# cloud credential and the stacks' inputs, and openstack the cloud credential.
tool_sees() {
  if [[ -n ${tool_secrets[$2]+set} ]]; then
    [[ " ${tool_secrets[$2]} " == *" $1 "* ]]
    return
  fi
  case $1:$2 in
    tofu:OS_* | tofu:AWS_* | tofu:TF_VAR_* | openstack:OS_*) return 0 ;;
  esac
  return 1
}

# exec_tool TOOL ARG...: replaces the current process with the binary TOOL, with ARG... and the
# environment less the secrets TOOL may not see. For a process made for it alone, as in
# ( exec_tool kubectl ... ) &, where the caller holds the process's id and the tool must be that
# process, not a child of it; run_tool is the call everywhere else.
exec_tool() {
  local tool=$1 name
  shift
  while IFS= read -r name; do
    if secret_variable "$name" && ! tool_sees "$tool" "$name"; then
      export -n "${name?}"
    fi
  done < <(compgen -e)
  exec "$tool" "$@"
}

# run_tool TOOL ARG...: the binary TOOL with ARG... and the caller's environment less the secrets
# TOOL may not see. It runs in a subshell, so the caller's own variables stay as they are.
run_tool() {
  (exec_tool "$@")
}

talman() { run_tool talman "$@"; }
talosctl() { run_tool talosctl "$@"; }
kubectl() { run_tool kubectl "$@"; }
helm() { run_tool helm "$@"; }
flux() { run_tool flux "$@"; }
kustomize() { run_tool kustomize "$@"; }
docker() { run_tool docker "$@"; }
sops() { run_tool sops "$@"; }
age() { run_tool age "$@"; }
age-keygen() { run_tool age-keygen "$@"; }
tofu() { run_tool tofu "$@"; }
openstack() { run_tool openstack "$@"; }
# The CI host recipes run these with the stack's environment, and none of them uses a secret.
gh() { run_tool gh "$@"; }
ssh() { run_tool ssh "$@"; }
ssh-keyscan() { run_tool ssh-keyscan "$@"; }
ssh-keygen() { run_tool ssh-keygen "$@"; }
