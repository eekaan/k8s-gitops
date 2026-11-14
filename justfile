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
    git ls-files -z --cached --others --exclude-standard -- 'scripts/*' '*.bats' | xargs -0 -r shellcheck
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

# Fail on IPv4 literals a public repository must not hold, in the files git would commit
check-literals:
    scripts/check-address-literals

# Fail on IPv4 literals a public repository must not hold, in the messages of the commits after the default branch
check-commit-literals:
    scripts/check-address-literals --commit-messages

# Fail on a scenario in features/ without its proof, or a test claiming a scenario that is not there
scenarios-check:
    scripts/scenarios-check

# Run the bats tests, except those tagged hermetic: they run just ci, which needs a container runtime. A shard such as 2/3 runs the second of three parts of the test files, split by their number of tests
[script]
test shard='1/1':
    set -o pipefail
    shard={{ quote(shard) }}
    if [[ ! $shard =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] || ((BASH_REMATCH[1] > BASH_REMATCH[2])); then
      echo "test: a shard is N/M, the Nth of M parts, not $shard" >&2
      exit 1
    fi
    part=${BASH_REMATCH[1]} parts=${BASH_REMATCH[2]}
    # The files with the most tests go first, each to the part with the fewest tests so far, so the
    # parts take about as long; ties go by name, byte by byte, so every part makes the same split.
    files=$(grep -c '^[[:blank:]]*@test[[:blank:]]' tests/*.bats | LC_ALL=C sort -t: -k2,2nr -k1,1 |
      awk -F: -v parts="$parts" -v part="$part" '{
        least = 0
        for (i = 1; i < parts; i++) if (load[i] < load[least]) least = i
        load[least] += $2
        if (least == part - 1) print $1
      }')
    if [[ -z $files ]]; then
      echo "test: part $shard holds no test file"
      exit 0
    fi
    mapfile -t files <<< "$files"
    # A file's tests run side by side, a file whose tests share state excepted, and the files one
    # after another: bats runs files side by side only through GNU parallel, which is not pinned.
    # Side by side within a file, bats takes turns with flock or shlock; without either, one by one.
    jobs=()
    cpus=$(getconf _NPROCESSORS_ONLN)
    if ((cpus > 1)) && { command -v flock || command -v shlock; } > /dev/null; then
      jobs=(--jobs "$cpus" --no-parallelize-across-files)
    fi
    bats "${jobs[@]}" --filter-tags '!hermetic' "${files[@]}"

# Run the bats tests that run just ci
test-hermetic:
    bats --filter-tags hermetic tests

# Run every check that needs no credentials with the tools on this machine, group by group
checks: static tests-1 tests-2 tests-3

# The groups of checks are the dependencies of checks, and each group's checks its own dependencies: just ci runs every group side by side in containers of its own, and CI runs each as a job of its own. A check, with whatever it depends on, belongs to one group only, or it would run twice.
# The checks other than the bats tests, the cheapest and most basic first
static: tools-check check-literals check-commit-literals cluster-secrets-check lint renovate-check scenarios-check infra-check talos-check kubernetes-check secrets-scan

# The first of three parts of the bats tests
tests-1: (test '1/3')

# The second of three parts of the bats tests
tests-2: (test '2/3')

# The third of three parts of the bats tests
tests-3: (test '3/3')

# Without a terminal, as in CI, Dagger's default progress is a line every 30 seconds; plain prints every step and each check's output as it happens.
# Run the checks inside containers built from the pins, as CI does: every group side by side, or only the group named, such as just ci tests-2; renovate-check's validator in its own image, the other checks in a container with the tools pinned in mise.toml
ci group='':
    base=$(scripts/check-address-literals --base); if [ -t 2 ]; then progress=auto; else progress=plain; fi; dagger api call --progress="$progress" ci checks --base="$base" --renovate-image='{{ renovate_image }}' --group={{ quote(group) }}

# Print the groups of checks as a JSON list, the CI workflow's matrix of jobs; in a GitHub Actions step, also set it as the step's output groups
[script]
ci-groups:
    set -o pipefail
    groups=$({{ quote(just_executable()) }} --justfile {{ quote(justfile()) }} --dump --dump-format json | jq -c '[.recipes.checks.dependencies[].recipe]')
    echo "$groups"
    if [[ -n ${GITHUB_OUTPUT-} ]]; then
      echo "groups=$groups" >> "$GITHUB_OUTPUT"
    fi

# Fail unless every result given is success; the CI workflow's required job ci gives it the result of each job it waits for
[positional-arguments]
[script]
ci-passed *results:
    if (($# == 0)); then
      echo "ci-passed: no results given" >&2
      exit 1
    fi
    # A job that failed, was cancelled or was skipped proved nothing.
    failed=0
    for result in "$@"; do
      if [[ $result != success ]]; then
        echo "ci-passed: a job ended $result" >&2
        failed=1
      fi
    done
    if ((failed)); then
      exit 1
    fi
    echo "ci-passed: all $# jobs succeeded"

# The image of Renovate's validator, for renovate-check here and for just ci's Dagger module
renovate_image := "ghcr.io/renovatebot/renovate:44.227.4@sha256:fe058db9710840a4821f20190b3769e3ce709a049b8640aa2bf5f044969fe702"

# Validate the Renovate configuration with Renovate's own validator, in its container image
renovate-check:
    docker run --rm --network none -v "$PWD":/usr/src/app:ro -w /usr/src/app {{ renovate_image }} renovate-config-validator --strict --no-global renovate.json5 .renovate/*.json5

# Publish kubernetes/ as the signed artifact Flux follows, and move its main tag; runs only in the publish workflow
publish:
    scripts/publish
