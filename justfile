set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-eu']

# Each area keeps its recipes in its own file, so changes to one do not touch the others.
import? 'just/infra.just'
import? 'just/cluster.just'
import? 'just/flux.just'

# The pinned installs go first on PATH. `mise exec` is not enough: in a shell where mise is
# activated it appends them behind entries already on PATH, so another install could answer.
# Without mise, PATH stays as it is and tools-check says what is missing; a mise error stops here.
export PATH := `bins=$(if command -v mise > /dev/null; then mise bin-paths | paste -sd: -; fi); echo "${bins:+$bins:}$PATH"`

# List the recipes
default:
    just --list

# Install the pinned tools with mise
tools:
    mise install

# Check that every pinned tool on PATH reports its pinned version
tools-check:
    scripts/tools-check

# Lint the shell scripts, the bats tests and the YAML files git would commit
lint:
    shellcheck scripts/* tests/*.bats
    git ls-files -z --cached --others --exclude-standard -- '*.yaml' '*.yml' .yamllint.yaml | xargs -0 -r yamllint

# Scan the files git would commit and the whole git history for secrets
[script]
secrets-scan:
    set -o pipefail
    # Ignored files such as a local kubeconfig never reach a commit, so the tree scan sees only
    # what git tracks or would add.
    repo=$PWD
    tree=$(mktemp -d)
    trap 'rm -rf "$tree"' EXIT
    git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' path; do
      # A symlink's target can lie outside the repository; git commits only the link.
      if [[ -f $path && ! -L $path ]]; then
        mkdir -p -- "$tree/$(dirname -- "$path")"
        cp -p -- "$path" "$tree/$path"
      fi
    done
    (cd "$tree" && gitleaks dir --no-banner --redact --verbose --config "$repo/.gitleaks.toml" .)
    gitleaks git --no-banner --redact --verbose --config .gitleaks.toml .

# Fail on IPv4 literals a public repository must not hold
check-literals:
    scripts/check-address-literals

# Run the bats tests
test:
    bats tests

# Run every check that needs no credentials, the cheapest and most basic first
ci: tools-check check-literals lint infra-check secrets-scan test

# Validate the Renovate configuration with Renovate's own validator, in its container image
renovate-check:
    docker run --rm --network none -v "$PWD":/usr/src/app:ro -w /usr/src/app ghcr.io/renovatebot/renovate:44.227.4@sha256:fe058db9710840a4821f20190b3769e3ce709a049b8640aa2bf5f044969fe702 renovate-config-validator --strict --no-global renovate.json5 .renovate/*.json5
