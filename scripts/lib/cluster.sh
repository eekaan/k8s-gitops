# shellcheck shell=bash
# Shared by scripts/cluster-env, the cluster-* scripts and the secrets bundle check: the Talos age
# key's location, talos/.sops.yaml's recipient, the check that a secrets bundle is encrypted, and the
# line that names the step a recipe failed in. Builds on scripts/lib/infra.sh, which reads the
# environment. Nothing here reads the age key or prints a secret: sops and talman get the key's
# location from their environment.

# shellcheck source=scripts/lib/infra.sh
. "$(dirname "${BASH_SOURCE[0]}")/infra.sh"

sops_config=$infra_root/talos/.sops.yaml

# report_failed_step: from here on, a recipe that fails ends with a line naming the step it was in,
# which it keeps in step.
report_failed_step() {
  step="checking the environment"
  trap 'failed_step $?' EXIT
}

failed_step() {
  if (($1 != 0)); then
    infra_error "failed while $step"
  fi
}

# Go's HTTP/2 debug log (GODEBUG=http2debug=2) dumps the frames talosctl, kubectl and helm send and
# receive, which carry machine configurations and credentials, so the recipes run without it.
refuse_http2_debug() {
  if [[ ${GODEBUG-} == *http2debug* ]]; then
    infra_error "GODEBUG sets http2debug; unset it, as Go's HTTP/2 debug log would print machine configurations and credentials"
    return 1
  fi
}

# inside_repository PATH: whether PATH, with symlinks resolved, lies in the repository.
inside_repository() {
  local resolved root
  resolved=$(realpath -m -- "$1")
  root=$(realpath -m -- "$infra_root")
  [[ $resolved == "$root" || $resolved == "$root"/* ]]
}

# require_age_key: the Talos age key's location is set, as SOPS_AGE_KEY holding the key (CI) or
# SOPS_AGE_KEY_FILE naming a file outside the repository. sops reads either itself.
require_age_key() {
  if [[ -n ${SOPS_AGE_KEY_FILE:-} ]] && inside_repository "$SOPS_AGE_KEY_FILE"; then
    infra_error "SOPS_AGE_KEY_FILE names a path inside the repository; the Talos age key is kept outside it"
    return 1
  fi
  if [[ -n ${SOPS_AGE_KEY:-} ]]; then
    return 0
  fi
  if [[ -z ${SOPS_AGE_KEY_FILE:-} ]]; then
    infra_error "neither SOPS_AGE_KEY_FILE nor SOPS_AGE_KEY is set; set SOPS_AGE_KEY_FILE in .env or the environment"
    return 1
  fi
  if [[ ! -f $SOPS_AGE_KEY_FILE ]]; then
    infra_error "SOPS_AGE_KEY_FILE names no file; just cluster-age-key creates the key there"
    return 1
  fi
}

# sops_recipient: the age recipient talos/.sops.yaml encrypts secrets bundles to.
sops_recipient() {
  yq '.creation_rules[0].age // ""' "$sops_config"
}

# bundle_encrypted FILE: whether FILE is SOPS-encrypted: it carries SOPS metadata, which is what
# sops filestatus reads, and every value in it is sops ciphertext. Nothing of FILE is printed.
bundle_encrypted() {
  local status counts values plaintext
  status=$(sops filestatus "$1" 2> /dev/null) || return 1
  jq -e '.encrypted == true' <<< "$status" > /dev/null || return 1
  # How many values there are, and how many of them are not ciphertext.
  counts=$(yq 'del(.sops) | [.. | select(kind == "scalar")]
    | [length, (map(select(tag != "!!str" or (test("^ENC\\[") | not))) | length)] | join(" ")' "$1" 2> /dev/null) || return 1
  read -r values plaintext <<< "$counts"
  [[ $values =~ ^[0-9]+$ && $plaintext == 0 ]] && ((values > 0))
}
