set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-eu']

# Each area keeps its recipes in its own file, so changes to one do not touch the others.
import? 'just/infra.just'
import? 'just/cluster.just'
import? 'just/flux.just'
import? 'just/openbao.just'
import? 'just/rotation.just'

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

# Scan the files git would commit and the history reachable from HEAD for secrets
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
    # The history reachable from HEAD, which is all a CI checkout holds; by default gitleaks reads
    # every ref, so a commit on another branch of a clone would fail the scan only there.
    gitleaks git --no-banner --redact --verbose --config .gitleaks.toml --log-opts=HEAD .

# Fail on IPv4 literals a public repository must not hold, in the files git would commit
check-literals:
    scripts/check-address-literals

# Fail on IPv4 literals a public repository must not hold, in the messages of the commits after the default branch
check-commit-literals:
    scripts/check-address-literals --commit-messages

# Fail on a merge conflict marker in the files git would commit
check-conflict-markers:
    scripts/check-conflict-markers

# Fail when the committed dagger.lock holds an entry for an image the tree takes by a tag it derives at run time, such as the Prometheus image of rules-check
lock-check:
    scripts/check-lock-entries

# Fail on a scenario in features/ without its proof, or a test claiming a scenario that is not there
scenarios-check:
    scripts/scenarios-check

# Fail unless every chart source Flux builds, the artifact the cluster syncs and the tools image is one row of signatures.yaml, each row is one of them and of the form its kind takes, and the verify block of every OCIRepository and of the sync source is exactly its row's identity, or there is none; offline (docs/kubernetes.md, Signatures)
signatures-check:
    scripts/signatures-check

# After the offline check, ask each registry, anonymously, whether every pin of the tree is signed as its row of signatures.yaml says: cosign verifies a keyless row with its issuer and subject, a key row with its key, and finds no signature for an unsigned one; one line per row, pass, FAIL or skip; needs the network
signatures-verify:
    scripts/signatures-check verify

# Write each catalogue entity's dependencies from the dependsOn of the Kustomization it describes, so the entities and the overlay agree (docs/kubernetes.md, Backstage)
catalogue-dependencies:
    scripts/catalogue-dependencies

# Run the bats tests, except those tagged hermetic, which run just ci and need a container runtime, and those tagged namespace, which need unprivileged user namespaces (just edge-forward-check). A shard such as 2/3 runs the second of three parts of the test files, split by their number of tests
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
    bats "${jobs[@]}" --filter-tags '!hermetic,!namespace' "${files[@]}"

# Run the bats tests that run just ci
test-hermetic:
    bats --filter-tags hermetic tests

# Run every check that needs no credentials with the tools on this machine, group by group
checks: static signatures tests-1 tests-2 tests-3

# The groups of checks are the dependencies of checks, and each group's checks its own dependencies: just ci runs every group side by side in containers of its own, and CI runs each as a job of its own. A check, with whatever it depends on, belongs to one group only, or it would run twice.
# The checks other than the bats tests, the cheapest and most basic first
static: tools-check check-literals check-commit-literals check-conflict-markers lock-check cluster-secrets-check lint renovate-check renovate-pins edge-policy-check scenarios-check infra-check talos-check kubernetes-check signatures-check render-check network-policy-check kubernetes-validate vector-check rules-check alerts-route-check secrets-scan

# The verification of the sources' signatures against the registries, a group of its own: a registry out of reach fails it and leaves static's result as it is
signatures: signatures-verify

# The first of three parts of the bats tests
tests-1: (test '1/3')

# The second of three parts of the bats tests
tests-2: (test '2/3')

# The third of three parts of the bats tests
tests-3: (test '3/3')

# Without a terminal, as in CI, Dagger's default progress is a line every 30 seconds; plain prints every step and each check's output as it happens.
# Run the checks inside containers built from the pins, as CI does: every group side by side, or only the group named, such as just ci tests-2; renovate-check's validator, vector-check's Vector and edge-policy-check's FRR each in its own image, rules-check's promtool, taken from the image of the Prometheus the chart deploys, and alerts-route-check's amtool and Alertmanager, taken from the image of the Alertmanager it deploys, in the tools container, the other checks in a container with the tools pinned in mise.toml, the tools image versions.yaml records when it was built for these pins. Dagger records in dagger.lock each image it resolves without an entry there, such as the Prometheus image of rules-check, so the run puts the file back as it found it, whether it passes, fails or is stopped by INT, TERM or HUP; lock-check refuses such an entry in the committed file
[script]
ci group='':
    set -o pipefail
    base=$(scripts/check-address-literals --base)
    # The tools' inputs, and the recorded tools image when it was built for them, one argument per line.
    tools=$(scripts/tools-image ci-args)
    mapfile -t tools <<< "$tools"
    if [[ -t 2 ]]; then progress=auto; else progress=plain; fi
    scripts/dagger-engine
    scripts/restore-after dagger.lock dagger api call --progress="$progress" ci checks --base="$base" --renovate-image='{{ renovate_image }}' --vector-image='{{ vector_image }}' --frr-image='{{ frr_image }}' --alertmanager-image='{{ alertmanager_image }}' "${tools[@]}" --group={{ quote(group) }}

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

# The CI workflow's render job: in the Dagger module, in the tools container just ci uses, render the commit BASE (the first parent of HEAD when empty) and this checkout with the base's render code, and save the pull request comment comparing them to OUT
[script]
ci-render out base='':
    set -o pipefail
    mkdir -p "$(dirname {{ quote(out) }})"
    # The same tools arguments just ci hands the module, so the render runs in the same container.
    tools=$(scripts/tools-image ci-args)
    mapfile -t tools <<< "$tools"
    if [[ -t 2 ]]; then progress=auto; else progress=plain; fi
    scripts/dagger-engine
    dagger api call --progress="$progress" -o {{ quote(out) }} ci render-diff "${tools[@]}" --base={{ quote(base) }}

# The comment workflow's job: put the comment the render job of the CI run RUN_ID left on its pull request, as text only; needs GH_TOKEN, GITHUB_REPOSITORY, RUN_ID, HEAD_SHA, HEAD_REPOSITORY and HEAD_BRANCH
ci-comment:
    scripts/ci-comment

# The image of Renovate's validator, for renovate-check here and for just ci's Dagger module
# renovate: datasource=docker depName=ghcr.io/renovatebot/renovate
renovate_image := "ghcr.io/renovatebot/renovate:44.227.4@sha256:fe058db9710840a4821f20190b3769e3ce709a049b8640aa2bf5f044969fe702"

# Validate the Renovate configuration with Renovate's own validator, in its container image, then fail unless the dependencies Renovate extracts from the files are the ones .renovate/extracted.tsv records
renovate-check:
    scripts/renovate-run '{{ renovate_image }}'

# Write .renovate/extracted.tsv from what Renovate extracts from the files, after a change to the pins or to the configuration that renovate-check reports, including another change's pins that a merge of main brought
[script]
renovate-record:
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    scripts/renovate-run '{{ renovate_image }}' record > "$tmp"
    cat "$tmp" > .renovate/extracted.tsv

# Fail for any version pin that Renovate does not extract (.renovate/extracted.tsv), under its name and at its place, in a form it can move, and that .renovate/by-hand.tsv does not list as moved by hand, for any listed pin that Renovate now extracts and can move, and for any pin of a custom manager whose value is not the form its datasource's tags have (.renovate/tag-forms.tsv)
renovate-pins:
    scripts/check-renovate-pins

# The image of the log collector, Vector, that the vector application's pinned chart runs, pinned by the digest of its image index, for vector-check here and for just ci's Dagger module. Renovate moves the tag and the digest in the same pull request as the chart, and tests/logs.bats fails when it is not the chart's image
# renovate: datasource=docker depName=docker.io/timberio/vector
vector_image := "docker.io/timberio/vector:0.61.0-distroless-libc@sha256:1a3451978644d5cd4b99a0b28c990791e2f7e1efbea4184122f1c59a56448143"

# Check the log collector's rendered configuration with Vector itself, in the image the collector runs: it loads, and Vector's unit tests of it in tests/vector pass
[script]
vector-check:
    set -o pipefail
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    # docker is run with none of the secrets a recipe's environment may hold.
    . scripts/lib/tools.sh
    scripts/vector-config "$dir"
    docker run --rm --network none -e VECTOR_SELF_NODE_NAME=node-1 -v "$dir":/check:ro {{ vector_image }} validate --no-environment /check/vector.yaml
    docker run --rm --network none -e VECTOR_SELF_NODE_NAME=node-1 -v "$dir":/check:ro {{ vector_image }} test /check/vector.yaml /check/tests.yaml

# Check the alert rules the tree renders with promtool, in the image of the Prometheus the rendered chart deploys, which scripts/rules-config finds in the render: every rule of every cluster, the charts' and the applications' own, is valid, every own alert has a severity, a summary, a description, a runbook heading that exists and a test in which it fires and one in which it stays quiet, and the unit tests in tests/rules pass; then promtool's check rules must refuse, naming each, a chart's rule and an own alert it cannot parse and an own alert defined twice, in rule files no unit test loads. The image is the chart's, by the tag Renovate moves with the chart, and nothing else pins it; needs docker, as vector-check does, which just ci's module does not
[script]
rules-check:
    set -o pipefail
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    # docker is run with none of the secrets a recipe's environment may hold.
    . scripts/lib/tools.sh
    scripts/rules-config "$dir/check"
    image=$(< "$dir/check/image")
    scripts/rules-promtool "$dir/check" docker run --rm --network none -v "$dir/check":/check:ro -w /check --entrypoint promtool "$image"
    scripts/rules-refusal "$dir/check" docker run --rm --network none -v "$dir/check":/check:ro -w /check --entrypoint promtool "$image"

# The image of the Alertmanager that the kube-prometheus-stack application's pinned chart deploys, pinned by the digest of its image index, for alerts-route-check here and for just ci's Dagger module. Renovate moves the tag and the digest in the same pull request as the chart, and tests/alert-routes.bats fails when it is not the chart's image
# renovate: datasource=docker depName=quay.io/prometheus/alertmanager
alertmanager_image := "quay.io/prometheus/alertmanager:v0.35.0@sha256:5f6e66c01bd610aef6dd671642a52eee775fd3a89bd8788ebada33efaf373d10"

# Check the configuration the rendered chart gives Alertmanager with amtool and Alertmanager themselves, in the image the chart deploys, which scripts/alerts-route-config finds in the render and which must be alertmanager_image: amtool accepts the configuration, and every case of tests/alert-routes/cases.yaml holds, each printed with its verdict: an alert resolves to the receivers its case expects, a critical alert inhibits the warning of its name and namespace and no other, an Alertmanager started with no file where a receiver reads its address becomes ready and fails every notification on that file, and a silence suppresses the alert it names and leaves the Watchdog active; then the check must fail for a configuration amtool refuses and for a route case and an inhibition case whose expectation is wrong. The container has no network, a read-only filesystem, the image's own user and no capability; needs docker, as vector-check does, which just ci's module does not
[script]
alerts-route-check:
    set -o pipefail
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    scripts/alerts-route-config "$dir/check"
    image='{{ alertmanager_image }}'
    deployed=$(< "$dir/check/image")
    if [[ $deployed != "${image%@*}" ]]; then
      echo "alerts-route-check: the render deploys $deployed, not ${image%@*}: set alertmanager_image in the justfile to the image the chart deploys and the digest of its image index" >&2
      exit 1
    fi
    # scripts/alerts-route-run runs docker with none of the secrets a recipe's environment may hold.
    shell=(docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges --tmpfs /tmp -v "$dir/check":/check:ro -w /check --entrypoint sh "$image")
    scripts/alerts-route-run "$dir/check" "${shell[@]}"
    scripts/alerts-route-run --refusals "$dir/check" "${shell[@]}"

# The image of FRR for edge-policy-check here and for just ci's Dagger module: the upstream build, 10.3.4, of the release the edge routers' Debian image packages, 10.3-3+deb13u1 in trixie, the same release with Debian's patches. Its own build takes 64 equal-cost paths, Debian's 256, which the proof's configuration allows for; it moves with the edge image's release, by hand (.renovate/by-hand.tsv)
frr_image := "quay.io/frrouting/frr:10.3.4@sha256:c8790a83db3cb105c0823f76afe55de5c9f77d968fb1ebd28174a8ddd49b989c"

# Prove the edge routers' routing policy with a real BGP speaker: the FRR configuration the edge stack renders runs in FRR's container with only its loopback and offered prefixes by speakers of the cluster's AS, another AS and an address outside the listen range, and only the /32 inside the service range may end up in its table, with nothing advertised back; needs docker, as renovate-check does, which just ci's module does not
edge-policy-check:
    scripts/edge-policy-check {{ frr_image }}

# Write what the edge routing policy's proof runs into a directory: the edge stack's rendered FRR configuration, and the proof's script and speaker template; needs tofu only
edge-policy-render dir:
    scripts/edge-policy-render {{ quote(dir) }}

# Check what the edge routing policy's proof printed, a file: pass or FAIL per item
edge-policy-assert file:
    scripts/edge-policy-assert {{ quote(file) }}

# Prove what an edge does with a client's connection: its rendered rules and proxy configuration run in network namespaces of a user namespace, beside a client, a worker and the cloud's router, where the proxy answers the client and sends the Gateway's address a PROXY protocol header naming the client, nothing is forwarded, and with no worker's route a connection fails at once and recovers with the route; needs unshare, nft, ip, ss, socat, haproxy and tofu on PATH and unprivileged user namespaces with networks and mounts of their own, which the CI containers do not allow, so it runs on a developer's machine and skips, saying why, where one of them is missing
edge-forward-check:
    bats --filter-tags namespace tests/edge-forward.bats

# Publish kubernetes/ as the signed artifact Flux follows, and move its main tag; runs only in the publish workflow
publish:
    scripts/publish

# Print the key of the tools image's inputs: ci_tools_base and ci_tools_packages in versions.yaml, the whole Dagger module, and mise.toml
tools-image-key:
    scripts/tools-image key

# Build the tools with the pinned Dagger, push them to ghcr.io tagged with their key, sign the digest keyless and verify it, then print it; nothing is built when the key's image is signed already; runs only in the tools image workflow on main
tools-image-publish:
    scripts/tools-image publish

# Record the tools image at digest in versions.yaml, with the key of these inputs, once its signature verifies without credentials as the tools image workflow's on main in this repository for that key
tools-image-pin digest:
    scripts/tools-image pin {{ quote(digest) }}
