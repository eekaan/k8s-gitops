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
}

@test "A pin added where no manager looks, and not listed, is refused, naming the file and line" {
  checkout
  mkdir -p "$WORK/apps"
  # One pin of each form the finder knows, each on a line of its own, below a line that holds none.
  printf '%s\n' '#!/usr/bin/env bash' 'echo start' 'docker run --rm registry.example.com/team/tool:4.5.6' > "$WORK/scripts/added-image"
  printf '%s\n' 'echo start' 'echo oci://registry.example.com/team/charts/thing:1.2.3' > "$WORK/scripts/added-oci"
  printf '%s\n' 'echo start' "echo registry.example.com/team/other@sha256:$(printf 'x' | sha256sum | cut -d' ' -f1)" > "$WORK/scripts/added-digest"
  printf '%s\n' 'jobs:' '  build:' '    steps:' '      - uses: example-org/example-action@0123456789abcdef0123456789abcdef01234567' > "$WORK/.github/workflows/added.yaml"
  printf '%s\n' 'apiVersion: v1' 'kind: Pod' 'spec:' '  containers:' '    - image: tool:2.0.1' > "$WORK/apps/added-pod.yaml"
  printf '%s\n' '# tools' 'newtool = "3.2.1"' > "$WORK/added-tools.toml"
  printf '%s\n' 'spec:' '  ref:' '    tag: v9.9.9' > "$WORK/kubernetes/added-source.yaml"
  # A pin in a file Renovate already extracts from is no more covered than one in a new file.
  printf '%s\n' '    extra: ghcr.io/example-org/untracked:1.2.3' >> "$WORK/kubernetes/apps/base/openbao/openbao/app/values.yaml"
  values_line=$(wc -l < "$WORK/kubernetes/apps/base/openbao/openbao/app/values.yaml")
  # A new top-level value of versions.yaml, a version in OpenTofu, and the version and checksum a
  # workflow gives an action.
  printf '%s\n' 'new_tool: 1.2.3' >> "$WORK/versions.yaml"
  versions_line=$(wc -l < "$WORK/versions.yaml")
  printf '%s\n' 'terraform {' '  required_providers {' '    example = {' '      version = "1.2.3"' '    }' '  }' '}' > "$WORK/infra/added.tf"
  printf '%s\n' 'jobs:' '  build:' '    steps:' '      - with:' '          version: 1.2.3' "          sha256: $(printf 'y' | sha256sum | cut -d' ' -f1)" > "$WORK/.github/workflows/added-mise.yaml"
  run "$WORK/scripts/check-renovate-pins"
  [ "$status" -eq 1 ]
  grep -q "^kubernetes/apps/base/openbao/openbao/app/values.yaml:$values_line: ghcr.io/example-org/untracked is a pin that no Renovate manager extracts" <<< "$output"
  grep -q "^versions.yaml:$versions_line: new_tool is a pin that no Renovate manager extracts" <<< "$output"
  grep -q '^infra/added.tf:4: \* is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^.github/workflows/added-mise.yaml:5: jdx/mise is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^.github/workflows/added-mise.yaml:6: ' <<< "$output"
  grep -q '^scripts/added-image:3: registry.example.com/team/tool is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^scripts/added-oci:2: registry.example.com/team/charts/thing is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^scripts/added-digest:2: registry.example.com/team/other is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^.github/workflows/added.yaml:4: example-org/example-action is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^apps/added-pod.yaml:5: tool is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^added-tools.toml:2: newtool is a pin that no Renovate manager extracts' <<< "$output"
  grep -q '^kubernetes/added-source.yaml:3: \* is a pin that no Renovate manager extracts' <<< "$output"
  # Nothing else is refused: the tree's own pins pass.
  [ "$(wc -l <<< "$output")" -eq 12 ]
}

@test "A listed pin that a manager now extracts is refused" {
  checkout
  {
    printf '%s\t%s\t%s\t%s\n' versions.yaml talos 'no datasource' 'by hand'
    printf '%s\t%s\t%s\t%s\n' mise.toml kubectl 'no datasource' 'by hand'
    # A checksum that Renovate moves with the version it reads beside it.
    printf '%s\t%s\t%s\t%s\n' .github/workflows/publish.yaml sha256 'no datasource' 'by hand'
    # A listed pin that is no longer in its file is as stale.
    printf '%s\t%s\t%s\t%s\n' versions.yaml no_such_pin 'gone' 'by hand'
    # A name that only a comment holds is no pin either.
    printf '%s\t%s\t%s\t%s\n' versions.yaml 'name with "key" in it' 'a comment' 'by hand'
  } >> "$WORK/.renovate/by-hand.tsv"
  total=$(wc -l < "$WORK/.renovate/by-hand.tsv")
  run "$WORK/scripts/check-renovate-pins"
  [ "$status" -eq 1 ]
  grep -q "^.renovate/by-hand.tsv:$((total - 4)): talos in versions.yaml is extracted by Renovate's regex manager" <<< "$output"
  grep -q "^.renovate/by-hand.tsv:$((total - 3)): kubectl in mise.toml is extracted by Renovate's mise manager" <<< "$output"
  grep -q "^.renovate/by-hand.tsv:$((total - 2)): sha256 in .github/workflows/publish.yaml is moved with jdx/mise, which Renovate extracts" <<< "$output"
  grep -q "^.renovate/by-hand.tsv:$((total - 1)): versions.yaml has no no_such_pin" <<< "$output"
  grep -q "^.renovate/by-hand.tsv:$total: versions.yaml has no name with \"key\" in it" <<< "$output"
  [ "$(wc -l <<< "$output")" -eq 5 ]
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
  run "$WORK/scripts/check-renovate-pins"
  [ "$status" -eq 1 ]
  grep -q "^.renovate/tag-forms.tsv:$forms: no pin reads docker example.invalid/team/gone any more" <<< "$output"
  grep -q '^kubernetes/apps/base/kube-system/cilium/app/ocirepository.yaml:19: "latest" is not the form the tags of quay.io/cilium/charts/cilium have' <<< "$output"
  grep -q '^versions.yaml:15: "v2.338.2" is not the form the tags of actions/runner have' <<< "$output"
  grep -q '^scripts/annotated:1: registry.example.com/team/charts/thing (docker) has no recorded tag form' <<< "$output"
}
