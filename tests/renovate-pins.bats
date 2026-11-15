#!/usr/bin/env bats

setup() {
  REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
}

# checkout: a throwaway repository holding what git would commit from this one, so a test changes
# pins in it and never in this checkout.
checkout() {
  local path
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
  while IFS= read -r -d '' path; do
    # A file deleted here but still in the index has nothing to copy.
    [[ -e $REPO/$path || -L $REPO/$path ]] || continue
    mkdir -p -- "$WORK/$(dirname -- "$path")"
    cp -pP -- "$REPO/$path" "$WORK/$path"
  done < <(git -C "$REPO" ls-files -z --cached --others --exclude-standard)
  git -C "$WORK" init -q -b main
  git -C "$WORK" add -A
  git -C "$WORK" -c user.name=test -c user.email=test@example.invalid commit -q -m "checkout under test"
}

@test "Every pin in the tree is extracted by a Renovate manager or listed as moved by hand" {
  run "$REPO/scripts/check-renovate-pins"
  [ "$status" -eq 0 ]
  [[ $output =~ ^check-renovate-pins:\ ([0-9]+)\ pins\ are\ extracted ]]
  # A finder that found nothing would pass every tree.
  [ "${BASH_REMATCH[1]}" -ge 80 ]
}

@test "A finder that cannot run fails the check instead of finding no pins" {
  # A grep without -P (BSD, busybox) exits 2 for a pattern it cannot read and works for the rest.
  mkdir "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/grep" <<EOF
#!/bin/sh
case \$1 in -*P*) echo "grep: invalid option -- P" >&2; exit 2;; esac
exec $(command -v grep) "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/grep"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$REPO/scripts/check-renovate-pins"
  [ "$status" -ne 0 ]
  [[ $output != check-renovate-pins:\ 0\ pins* ]]
  # Nor does a yq that cannot read the workflows and manifests the names of their pins come from.
  mkdir "$BATS_TEST_TMPDIR/yq"
  printf '%s\n' '#!/bin/sh' 'echo "Error: cannot read" >&2' 'exit 1' > "$BATS_TEST_TMPDIR/yq/yq"
  chmod +x "$BATS_TEST_TMPDIR/yq/yq"
  PATH="$BATS_TEST_TMPDIR/yq:$PATH" run "$REPO/scripts/check-renovate-pins"
  [ "$status" -ne 0 ]
  [[ $output == *"yq cannot read"* ]]
}

@test "A pin added where no manager looks, and not listed, is refused, naming the file and line" {
  checkout
  mkdir -p "$WORK/apps"
  # One pin of each form the finder knows, each on a line of its own, below a line that holds none.
  printf '%s\n' '#!/usr/bin/env bash' 'echo start' 'docker run --rm registry.example.com/team/tool:4.5.6' > "$WORK/scripts/added-image"
  printf '%s\n' 'echo start' 'echo oci://registry.example.com/team/charts/thing:1.2.3' > "$WORK/scripts/added-oci"
  printf '%s\n' 'echo start' "echo registry.example.com/team/other@sha256:$(printf 'x' | sha256sum | cut -d' ' -f1)" > "$WORK/scripts/added-digest"
  printf '%s\n' 'echo start' 'docker run registry.example.com:5000/team/tool:4.5.6' > "$WORK/scripts/added-port"
  printf '%s\n' 'jobs:' '  build:' '    steps:' '      - uses: example-org/example-action@0123456789abcdef0123456789abcdef01234567' '      - with:' '          version: 2.3.4' > "$WORK/.github/workflows/added.yaml"
  printf '%s\n' 'apiVersion: v1' 'kind: Pod' 'spec:' '  containers:' '    - image: tool:2.0.1' > "$WORK/apps/added-pod.yaml"
  printf '%s\n' '# tools' 'newtool = "3.2.1"' > "$WORK/added-tools.toml"
  printf '%s\n' 'spec:' '  ref:' '    tag: v9.9.9' > "$WORK/kubernetes/added-source.yaml"
  # A label whose key ends in version, and a record that a check reads in a comment of its own,
  # beside a comment that only mentions a version.
  printf '%s\n' 'apiVersion: v1' 'kind: Namespace' 'metadata:' '  labels:' '    pod-security.kubernetes.io/audit-version: v1.37' > "$WORK/kubernetes/added-namespace.yaml"
  printf '%s\n' '# Read at the release below, as the 1.2 notes say.' '# example-templates: v1.2.3' 'echo start' > "$WORK/scripts/added-record"
  # A pin in a file Renovate already extracts from is no more covered than one in a new file.
  printf '%s\n' '    extra: ghcr.io/example-org/untracked:1.2.3' >> "$WORK/kubernetes/apps/base/openbao/openbao/app/values.yaml"
  values_line=$(wc -l < "$WORK/kubernetes/apps/base/openbao/openbao/app/values.yaml")
  # So is a chart's tag in a second source of a file whose own source Renovate extracts, and a
  # second provider's version beside one that it extracts.
  printf '%s\n' '---' 'apiVersion: source.toolkit.fluxcd.io/v1' 'kind: OCIRepository' 'metadata:' '  name: extra' 'spec:' \
    '  url: oci://registry.example.com/team/charts/extra' '  ref:' '    tag: 1.2.3' >> "$WORK/kubernetes/apps/base/kube-system/cilium/app/ocirepository.yaml"
  source_line=$(wc -l < "$WORK/kubernetes/apps/base/kube-system/cilium/app/ocirepository.yaml")
  # A second line under the comment of a package that the file's record holds only for another key.
  printf '%s\n' '# renovate: datasource=docker depName=quay.io/cilium/charts/cilium' 'version: 1.20.4' >> "$WORK/kubernetes/apps/base/kube-system/cilium/app/ocirepository.yaml"
  keyed_line=$(wc -l < "$WORK/kubernetes/apps/base/kube-system/cilium/app/ocirepository.yaml")
  printf '%s\n' 'terraform {' '  required_providers {' '    example = {' '      source  = "example/example"' '      version = "1.2.3"' '    }' '  }' '}' >> "$WORK/infra/openstack/modules/network/versions.tf"
  provider_line=$(($(wc -l < "$WORK/infra/openstack/modules/network/versions.tf") - 3))
  # And another action's version input in a workflow whose mise-action inputs Renovate reads, once
  # the action itself is recorded as Renovate would extract it.
  printf '%s\n' '      - uses: example-org/setup-thing@0123456789abcdef0123456789abcdef01234567  # v1.0.0' '        with:' '          version: 4.5.6' >> "$WORK/.github/workflows/ci.yaml"
  input_line=$(wc -l < "$WORK/.github/workflows/ci.yaml")
  # A version that is no step's input at all is no mise version either.
  printf '%s\n' '        env:' '          version: 7.8.9' >> "$WORK/.github/workflows/ci.yaml"
  env_line=$(wc -l < "$WORK/.github/workflows/ci.yaml")
  printf '%s\t%s\t%s\t%s\n' .github/workflows/ci.yaml github-actions example-org/setup-thing - >> "$WORK/.renovate/extracted.tsv"
  # A new top-level value of versions.yaml, a version in OpenTofu, and the version and checksum a
  # workflow gives an action.
  printf '%s\n' 'new_tool: 1.2.3' >> "$WORK/versions.yaml"
  versions_line=$(wc -l < "$WORK/versions.yaml")
  # And a commit pinned there.
  printf '%s\n' "new_commit: $(printf 'z' | sha1sum | cut -d' ' -f1)" >> "$WORK/versions.yaml"
  printf '%s\n' 'terraform {' '  required_providers {' '    example = {' '      version = "1.2.3"' '    }' '  }' '}' > "$WORK/infra/added.tf"
  printf '%s\n' 'jobs:' '  build:' '    steps:' '      - uses: jdx/mise-action@d5574b52816a478f9d4e6529a3f6ff17a8a36785  # v5.2.8' '        with:' '          version: 1.2.3' "          sha256: $(printf 'y' | sha256sum | cut -d' ' -f1)" > "$WORK/.github/workflows/added-mise.yaml"
  # Pins that a manager reads, recorded as Renovate's own extraction records them, pass when named
  # as that manager names them: an image in a values file by its repository and registry, in block
  # and flow style, or by the image beside its tag; a HelmRelease's values image; a kustomization's
  # chart; a module, a provider block and a helm_release by their source, label and chart; a tool
  # by its name without options; an action by its repository, without the path.
  values="$WORK/kubernetes/apps/base/openbao/openbao/app/values.yaml"
  printf '%s\n' 'extraSidecar:' '  image:' '    repository: ghcr.io/example-org/sidecar' '    tag: 1.2.3' \
    'flowSidecar:' '  image: {registry: ghcr.io, repository: example-org/flow, tag: 2.3.4}' \
    'cli:' '  image: ghcr.io/example-org/cli' '  tag: 4.5.6' \
    'both:' '  image:' '    repository: ghcr.io/example-org/both' '    tag: 5.6.7' '    version: 6.7.8' \
    'plain:' '  tag: 3.4.5' 'sidecar:' '  repository: ghcr.io/example-org/notimage' '  tag: 7.8.9' >> "$values"
  mkdir -p "$WORK/kubernetes/added"
  printf '%s\n' 'apiVersion: helm.toolkit.fluxcd.io/v2' 'kind: HelmRelease' 'metadata:' '  name: thing' 'spec:' '  chart:' '    spec:' \
    '      chart: thing' '      version: 1.0.0' '      sourceRef: {kind: HelmRepository, name: example}' '  values:' '    image:' \
    '      repository: ghcr.io/example-org/released' '      tag: 9.8.7' > "$WORK/kubernetes/added/helmrelease.yaml"
  printf '%s\n' 'apiVersion: kustomize.config.k8s.io/v1beta1' 'kind: Kustomization' 'helmCharts:' '  - name: thing' \
    '    repo: https://charts.example.com' '    version: 2.0.0' > "$WORK/kubernetes/added/kustomization.yaml"
  printf '%s\n' 'module "network" {' '  source  = "example-org/network/openstack"' '  version = "1.2.3"' '}' 'provider "example" {' \
    '  version = "2.3.4"' '}' 'resource "helm_release" "thing" {' '  name       = "thing"' '  chart      = "thing"' \
    '  repository = "https://charts.example.com"' '  version    = "3.4.5"' '}' > "$WORK/infra/openstack/modules/network/added.tf"
  printf '%s\n' '"ubi:example-org/tool[exe=tool]" = "1.2.3"' >> "$WORK/mise.toml"
  # Any value of a workflow with a version's shape is a pin: an input of an action Renovate does
  # not read, in flow style or under another key, and a matrix value.
  printf '%s\n' 'jobs:' '  build:' '    strategy:' '      matrix:' '        go: [1.22.1]' '    steps:' \
    '      - uses: example-org/setup-thing@0123456789abcdef0123456789abcdef01234567  # v1.0.0' '        with: {version: 4.5.6}' \
    '      - uses: example-org/setup-other@0123456789abcdef0123456789abcdef01234567  # v1.0.0' '        with:' '          tool-version: 5.6.7' \
    '      - uses: example-org/repo/path@0123456789abcdef0123456789abcdef01234567  # v1.0.0' > "$WORK/.github/workflows/added-inputs.yaml"
  {
    printf '%s\t%s\t%s\t%s\n' kubernetes/apps/base/openbao/openbao/app/values.yaml helm-values ghcr.io/example-org/sidecar -
    printf '%s\t%s\t%s\t%s\n' kubernetes/apps/base/openbao/openbao/app/values.yaml helm-values ghcr.io/example-org/flow -
    printf '%s\t%s\t%s\t%s\n' kubernetes/apps/base/openbao/openbao/app/values.yaml helm-values ghcr.io/example-org/cli -
    printf '%s\t%s\t%s\t%s\n' kubernetes/apps/base/openbao/openbao/app/values.yaml helm-values ghcr.io/example-org/both -
    printf '%s\t%s\t%s\t%s\n' kubernetes/added/helmrelease.yaml flux ghcr.io/example-org/released -
    printf '%s\t%s\t%s\t%s\n' kubernetes/added/kustomization.yaml kustomize thing -
    printf '%s\t%s\t%s\t%s\n' infra/openstack/modules/network/added.tf terraform example-org/network/openstack -
    printf '%s\t%s\t%s\t%s\n' infra/openstack/modules/network/added.tf terraform example -
    printf '%s\t%s\t%s\t%s\n' infra/openstack/modules/network/added.tf terraform thing -
    printf '%s\t%s\t%s\t%s\n' mise.toml mise ubi:example-org/tool -
    printf '%s\t%s\t%s\t%s\n' .github/workflows/added-inputs.yaml github-actions example-org/setup-thing -
    printf '%s\t%s\t%s\t%s\n' .github/workflows/added-inputs.yaml github-actions example-org/setup-other -
    printf '%s\t%s\t%s\t%s\n' .github/workflows/added-inputs.yaml github-actions example-org/repo -
  } >> "$WORK/.renovate/extracted.tsv"
  line_of() {
    grep -nxF -- "$2" "$1" | cut -d: -f1
  }
  run "$WORK/scripts/check-renovate-pins"
  [ "$status" -eq 1 ]
  grep -q "^kubernetes/apps/base/openbao/openbao/app/values.yaml:$values_line: ghcr.io/example-org/untracked is a pin that no Renovate manager extracts" <<< "$output"
  grep -q "^kubernetes/apps/base/kube-system/cilium/app/ocirepository.yaml:$source_line: registry.example.com/team/charts/extra is a pin that no Renovate manager extracts" <<< "$output"
  grep -q "^kubernetes/apps/base/kube-system/cilium/app/ocirepository.yaml:$keyed_line: quay.io/cilium/charts/cilium is a pin that no Renovate manager extracts" <<< "$output"
  grep -q "^infra/openstack/modules/network/versions.tf:$provider_line: example is a pin that no Renovate manager extracts" <<< "$output"
  grep -q "^.github/workflows/ci.yaml:$input_line: example-org/setup-thing input version is a pin that no Renovate manager extracts" <<< "$output"
  grep -q "^.github/workflows/ci.yaml:$env_line: version is a pin that no Renovate manager extracts" <<< "$output"
  grep -q "^versions.yaml:$versions_line: new_tool is a pin that no Renovate manager extracts" <<< "$output"
  grep -q "^versions.yaml:$((versions_line + 1)): new_commit is a pin that no Renovate manager extracts" <<< "$output"
  grep -q '^infra/added.tf:4: example is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^.github/workflows/added-mise.yaml:4: jdx/mise-action is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^.github/workflows/added-mise.yaml:6: jdx/mise is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^.github/workflows/added-mise.yaml:7: jdx/mise is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^scripts/added-image:3: registry.example.com/team/tool is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^scripts/added-port:2: registry.example.com:5000/team/tool is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^scripts/added-oci:2: registry.example.com/team/charts/thing is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^scripts/added-digest:2: registry.example.com/team/other is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^.github/workflows/added.yaml:4: example-org/example-action is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^.github/workflows/added.yaml:6: input version is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^apps/added-pod.yaml:5: tool is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^added-tools.toml:2: newtool is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^kubernetes/added-source.yaml:3: tag is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^kubernetes/added-namespace.yaml:5: pod-security.kubernetes.io/audit-version is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^scripts/added-record:2: example-templates is a pin that no Renovate manager extracts' <<< "$output"
  # What no manager reads of those: a version beside the tag that an image takes, a tag with no
  # image beside it, a tag under a key that is not an image's, a chart whose source Renovate does not
  # find, and the workflow's values.
  grep -q "^kubernetes/apps/base/openbao/openbao/app/values.yaml:$(line_of "$values" '    version: 6.7.8'): version is a pin that no Renovate manager extracts" <<< "$output"
  grep -q "^kubernetes/apps/base/openbao/openbao/app/values.yaml:$(line_of "$values" '  tag: 3.4.5'): tag is a pin that no Renovate manager extracts" <<< "$output"
  grep -q "^kubernetes/apps/base/openbao/openbao/app/values.yaml:$(line_of "$values" '  tag: 7.8.9'): tag is a pin that no Renovate manager extracts" <<< "$output"
  grep -q '^kubernetes/added/helmrelease.yaml:9: thing is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^.github/workflows/added-inputs.yaml:5: matrix go is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^.github/workflows/added-inputs.yaml:8: example-org/setup-thing input version is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^.github/workflows/added-inputs.yaml:11: example-org/setup-other input tool-version is a pin that no Renovate manager extracts' <<< "$output"
  # The rest pass.
  local covered
  for covered in "$(line_of "$values" '    tag: 1.2.3')" "$(line_of "$values" '  image: {registry: ghcr.io, repository: example-org/flow, tag: 2.3.4}')" \
    "$(line_of "$values" '  tag: 4.5.6')" "$(line_of "$values" '    tag: 5.6.7')"; do
    [ -n "$covered" ]
    [ "$(grep -c "^kubernetes/apps/base/openbao/openbao/app/values.yaml:$covered:" <<< "$output")" -eq 0 ]
  done
  [ "$(grep -cE '^(kubernetes/added/kustomization.yaml|infra/openstack/modules/network/added.tf|mise.toml):' <<< "$output")" -eq 0 ]
  [ "$(grep -cE '^kubernetes/added/helmrelease.yaml:14:|^.github/workflows/added-inputs.yaml:(7|9|12):' <<< "$output")" -eq 0 ]
  # Nothing else is refused: the tree's own pins pass.
  [ "$(wc -l <<< "$output")" -eq 30 ]
}

@test "A listed pin that a manager now extracts is refused" {
  checkout
  # mise's version written in every workflow as its releases are tagged, so that Renovate moves it
  # with its checksum, in all of them at once.
  local workflow mise_entries=()
  for workflow in ci publish render-comment tools-image; do
    sed -i -E 's/^( +version: )([0-9]+\.[0-9]+\.[0-9]+)$/\1v\2/' "$WORK/.github/workflows/$workflow.yaml"
    grep -qE '^ +version: v[0-9]+\.[0-9]+\.[0-9]+$' "$WORK/.github/workflows/$workflow.yaml"
    mise_entries+=("$(grep -n "^.github/workflows/$workflow.yaml"$'\t'"jdx/mise"$'\t' "$WORK/.renovate/by-hand.tsv" | cut -d: -f1)")
    [ -n "${mise_entries[-1]}" ]
  done
  {
    printf '%s\t%s\t%s\t%s\n' versions.yaml talos 'no datasource' 'by hand'
    printf '%s\t%s\t%s\t%s\n' mise.toml kubectl 'no datasource' 'by hand'
    # A checksum that Renovate moves with the version it reads beside it.
    printf '%s\t%s\t%s\t%s\n' .github/workflows/tools-image.yaml sha256 'no datasource' 'by hand'
    # A listed pin that is no longer in its file is as stale.
    printf '%s\t%s\t%s\t%s\n' versions.yaml no_such_pin 'gone' 'by hand'
    # A name that only a comment holds is no pin either, in YAML, TOML or HCL.
    printf '%s\t%s\t%s\t%s\n' versions.yaml 'name with "key" in it' 'a comment' 'by hand'
    printf '%s\t%s\t%s\t%s\n' mise.toml 'only-in-a-comment 9.9.9' 'a comment' 'by hand'
    printf '%s\t%s\t%s\t%s\n' infra/openstack/modules/network/versions.tf 'only-in-a-comment 9.9.9' 'a comment' 'by hand'
    printf '%s\t%s\t%s\t%s\n' infra/openstack/backend.hcl 'only-in-a-comment 9.9.9' 'a comment' 'by hand'
  } >> "$WORK/.renovate/by-hand.tsv"
  printf '%s\n' '# only-in-a-comment 9.9.9' | tee -a "$WORK/mise.toml" "$WORK/infra/openstack/modules/network/versions.tf" >> "$WORK/infra/openstack/backend.hcl"
  # An image in a values file that Renovate's helm-values manager reads, listed by its name and by
  # its tag's key.
  printf '%s\n' 'extraSidecar:' '  image:' '    repository: ghcr.io/example-org/sidecar' '    tag: 1.2.3' >> "$WORK/kubernetes/apps/base/openbao/openbao/app/values.yaml"
  printf '%s\t%s\t%s\t%s\n' kubernetes/apps/base/openbao/openbao/app/values.yaml helm-values ghcr.io/example-org/sidecar - >> "$WORK/.renovate/extracted.tsv"
  {
    printf '%s\t%s\t%s\t%s\n' kubernetes/apps/base/openbao/openbao/app/values.yaml ghcr.io/example-org/sidecar 'no datasource' 'by hand'
    printf '%s\t%s\t%s\t%s\n' kubernetes/apps/base/openbao/openbao/app/values.yaml tag 'no datasource' 'by hand'
  } >> "$WORK/.renovate/by-hand.tsv"
  total=$(($(wc -l < "$WORK/.renovate/by-hand.tsv") - 2))
  run "$WORK/scripts/check-renovate-pins"
  [ "$status" -eq 1 ]
  grep -q "^.renovate/by-hand.tsv:$((total + 1)): ghcr.io/example-org/sidecar in kubernetes/apps/base/openbao/openbao/app/values.yaml is extracted by Renovate's helm-values manager" <<< "$output"
  grep -q "^.renovate/by-hand.tsv:$((total + 2)): tag in kubernetes/apps/base/openbao/openbao/app/values.yaml is moved with ghcr.io/example-org/sidecar, which Renovate extracts there" <<< "$output"
  local i=0
  for workflow in ci publish render-comment tools-image; do
    grep -q "^.renovate/by-hand.tsv:${mise_entries[i]}: jdx/mise in .github/workflows/$workflow.yaml is extracted by Renovate's github-actions manager" <<< "$output"
    i=$((i + 1))
  done
  grep -q "^.renovate/by-hand.tsv:$((total - 7)): talos in versions.yaml is extracted by Renovate's regex manager" <<< "$output"
  grep -q "^.renovate/by-hand.tsv:$((total - 6)): kubectl in mise.toml is extracted by Renovate's mise manager" <<< "$output"
  grep -q "^.renovate/by-hand.tsv:$((total - 5)): sha256 in .github/workflows/tools-image.yaml is moved with jdx/mise, which Renovate extracts" <<< "$output"
  grep -q "^.renovate/by-hand.tsv:$((total - 4)): versions.yaml has no no_such_pin" <<< "$output"
  grep -q "^.renovate/by-hand.tsv:$((total - 3)): versions.yaml has no name with \"key\" in it" <<< "$output"
  grep -q "^.renovate/by-hand.tsv:$((total - 2)): mise.toml has no only-in-a-comment 9.9.9" <<< "$output"
  grep -q "^.renovate/by-hand.tsv:$((total - 1)): infra/openstack/modules/network/versions.tf has no only-in-a-comment 9.9.9" <<< "$output"
  grep -q "^.renovate/by-hand.tsv:$total: infra/openstack/backend.hcl has no only-in-a-comment 9.9.9" <<< "$output"
  [ "$(wc -l <<< "$output")" -eq 14 ]
}

@test "A custom-manager pin whose value cannot match its datasource's tag form is refused" {
  checkout
  # A tag that no listing has, a version written in the other form from the one the releases use, and a
  # pin of a package whose tag form nobody has recorded.
  sed -i 's/^    tag: 1\.20\.4$/    tag: latest/' "$WORK/kubernetes/apps/base/kube-system/cilium/app/ocirepository.yaml"
  sed -i 's/^actions_runner: 2\.338\.2$/actions_runner: v2.338.2/' "$WORK/versions.yaml"
  printf '%s\n' '# renovate: datasource=docker depName=registry.example.com/team/charts/thing' 'image: registry.example.com/team/charts/thing:1.0.0' > "$WORK/scripts/annotated"
  # A recorded form that no pin reads any more.
  printf '%s\t%s\t%s\t%s\n' docker example.invalid/team/gone '^1$' 'registry tag list' >> "$WORK/.renovate/tag-forms.tsv"
  forms=$(wc -l < "$WORK/.renovate/tag-forms.tsv")
  # An action's input that Renovate reads but whose version is not its tags' form, so Renovate
  # cannot move it, and that the list no longer holds.
  grep -q "^.github/workflows/publish.yaml"$'\t'"jdx/mise"$'\t' "$WORK/.renovate/by-hand.tsv"
  sed -i "/^.github\/workflows\/publish.yaml"$'\t'"jdx\/mise"$'\t'"/d" "$WORK/.renovate/by-hand.tsv"
  # And one with no checksum, which Renovate would move alone, without those it cannot move.
  grep -q "^.github/workflows/ci.yaml"$'\t'"jdx/mise"$'\t' "$WORK/.renovate/by-hand.tsv"
  sed -i "/^.github\/workflows\/ci.yaml"$'\t'"jdx\/mise"$'\t'"/d" "$WORK/.renovate/by-hand.tsv"
  run "$WORK/scripts/check-renovate-pins"
  [ "$status" -eq 1 ]
  grep -q "^.renovate/tag-forms.tsv:$forms: no pin reads docker example.invalid/team/gone any more" <<< "$output"
  grep -q "^kubernetes/apps/base/kube-system/cilium/app/ocirepository.yaml:$(grep -n '^    tag: latest$' "$WORK/kubernetes/apps/base/kube-system/cilium/app/ocirepository.yaml" | cut -d: -f1): \"latest\" is not the form the tags of quay.io/cilium/charts/cilium have" <<< "$output"
  grep -q "^versions.yaml:$(grep -n '^actions_runner: v2.338.2$' "$WORK/versions.yaml" | cut -d: -f1): \"v2.338.2\" is not the form the tags of actions/runner have" <<< "$output"
  grep -q '^scripts/annotated:1: registry.example.com/team/charts/thing (docker) has no recorded tag form' <<< "$output"
  mise=$(yq '.jobs[].steps[] | select(.uses // "" | test("^jdx/mise-action@")) | .with.version' "$WORK/.github/workflows/publish.yaml")
  [[ $mise =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  while IFS=: read -r line _; do
    grep -q "^.github/workflows/publish.yaml:$line: jdx/mise is read by Renovate here but cannot be moved: \"$mise\" is not the form the tags of jdx/mise have" <<< "$output"
  done < <(grep -nE "^ +(version: ${mise//./\\.}|sha256: [0-9a-f]{64})\$" "$WORK/.github/workflows/publish.yaml")
  [ "$(grep -c '^.github/workflows/publish.yaml:' <<< "$output")" -eq 2 ]
  while IFS=: read -r line _; do
    grep -q "^.github/workflows/ci.yaml:$line: jdx/mise is read by Renovate here and would be moved alone, without the workflows whose checksum it cannot look up" <<< "$output"
  done < <(grep -nE "^ +version: ${mise//./\\.}\$" "$WORK/.github/workflows/ci.yaml")
  [ "$(grep -c '^.github/workflows/ci.yaml:' <<< "$output")" -eq "$(grep -cE "^ +version: ${mise//./\\.}\$" "$WORK/.github/workflows/ci.yaml")" ]
}

@test "an entry of the by-hand list or of the tag forms without its four columns is refused" {
  checkout
  printf '%s\t%s\t%s\n' versions.yaml dagger_engine 'three columns' >> "$WORK/.renovate/by-hand.tsv"
  printf '%s\t%s\t%s\t%s\t%s\n' versions.yaml dagger_engine why how 'a fifth' >> "$WORK/.renovate/by-hand.tsv"
  entries=$(wc -l < "$WORK/.renovate/by-hand.tsv")
  printf '%s\t%s\t%s\n' docker quay.io/cilium/charts/cilium '^[0-9]+$' >> "$WORK/.renovate/tag-forms.tsv"
  forms=$(wc -l < "$WORK/.renovate/tag-forms.tsv")
  run "$WORK/scripts/check-renovate-pins"
  [ "$status" -eq 1 ]
  grep -q "^.renovate/by-hand.tsv:$((entries - 1)): an entry is a file, the pin's name, why Renovate does not move it and how it is moved, four columns" <<< "$output"
  grep -q "^.renovate/by-hand.tsv:$entries: an entry is a file, the pin's name, why Renovate does not move it and how it is moved, four columns" <<< "$output"
  grep -q "^.renovate/tag-forms.tsv:$forms: an entry is a datasource, a name, an extended regular expression for the pinned value and where the tags were read, four columns" <<< "$output"
  [ "$(wc -l <<< "$output")" -eq 3 ]
}
