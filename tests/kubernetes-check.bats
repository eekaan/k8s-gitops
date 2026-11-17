#!/usr/bin/env bats
# Proves features/kubernetes-layout.feature; each test carries its scenario's title. The scenarios
# of schemas and images are scripts/kubernetes-validate's, proved in tests/kubernetes-validate.bats.
# Needs kustomize, yq, jq and flux on PATH (the versions pinned for the repository).

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHECK="$REPO/scripts/kubernetes-check"
  TREE="$BATS_TEST_TMPDIR/tree"
  # Nothing to connect to: a step that needed a cluster fails instead of finding one.
  export KUBECONFIG="$BATS_TEST_TMPDIR/no-kubeconfig"
  unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
}

# put PATH: writes stdin to PATH in the fixture tree.
put() {
  mkdir -p "$(dirname "$TREE/$1")"
  cat >"$TREE/$1"
}

# cluster_app NAME: Flux's own application NAME in the fixture cluster, reconciled from the sync
# source with the root's decryption and substitution, its app/ holding one ConfigMap.
cluster_app() {
  local dir="kubernetes/clusters/test/flux-system/$1"
  put "$dir/ks.yaml" <<EOF
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: $1
  namespace: flux-system
spec:
  interval: 30m
  path: ./clusters/test/flux-system/$1/app
  prune: true
  targetNamespace: flux-system
  sourceRef:
    kind: OCIRepository
    name: flux-system
  decryption:
    provider: sops
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-config
EOF
  put "$dir/app/kustomization.yaml" <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
EOF
  put "$dir/app/configmap.yaml" <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: $1
EOF
}

# A small tree that passes the check: one cluster with Flux's own two applications, one
# namespace, one application. Each failure scenario breaks one rule in it.
valid_tree() {
  put kubernetes/clusters/test/kustomization.yaml <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ks.yaml
  - flux-system/flux-operator/ks.yaml
  - flux-system/flux-instance/ks.yaml
EOF
  cluster_app flux-operator
  cluster_app flux-instance
  put kubernetes/clusters/test/ks.yaml <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster
  namespace: flux-system
spec:
  interval: 30m
  path: ./apps/overlays/test
  prune: true
  sourceRef:
    kind: OCIRepository
    name: flux-system
  decryption:
    provider: sops
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-config
EOF
  put kubernetes/clusters/test/cluster-config.example.yaml <<'EOF'
---
CLUSTER_DOMAIN: example.com
EOF
  put kubernetes/apps/overlays/test/kustomization.yaml <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/demo
  - ../../base/demo/hello/ks.yaml
EOF
  put kubernetes/apps/base/demo/kustomization.yaml <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: demo
resources:
  - namespace.yaml
EOF
  put kubernetes/apps/base/demo/namespace.yaml <<'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: demo
EOF
  hello_ks </dev/null
  put kubernetes/apps/base/demo/hello/app/kustomization.yaml <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
EOF
  put kubernetes/apps/base/demo/hello/app/configmap.yaml <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hello
data:
  domain: "${CLUSTER_DOMAIN}"
EOF
  run "$CHECK" "$TREE"
  if [ "$status" -ne 0 ]; then
    echo "the unbroken fixture tree already fails the check:"
    echo "$output"
    return 1
  fi
}

# hello_ks: writes the fixture application's ks.yaml with stdin appended under spec.
hello_ks() {
  {
    cat <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: hello
  namespace: flux-system
spec:
  path: ./apps/base/demo/hello/app
  targetNamespace: demo
  sourceRef:
    kind: ExternalArtifact
    name: hello
EOF
    cat
  } | put kubernetes/apps/base/demo/hello/ks.yaml
}

# check: runs the check on the fixture tree; its output shows when a test fails.
check() {
  run "$CHECK" "$TREE"
  echo "$output"
}

# fails_naming WHAT TEXT: the check failed, and one of its messages names WHAT and says TEXT.
fails_naming() {
  [ "$status" -ne 0 ] || { echo "expected the check to fail"; return 1; }
  grep -F -- "$1" <<<"$output" | grep -qF -- "$2" ||
    { echo "no failure message naming '$1' that says '$2'"; return 1; }
}

# with_stdin STATE COMMAND...: runs COMMAND as run does, with its standard input in STATE: closed;
# null, at /dev/null; silent, a pipe that stays open and carries nothing; or carried, a pipe that
# carries $CARRIED and ends. A command still running after two minutes is ended, with status 124.
with_stdin() {
  local state=$1 fd
  shift
  case $state in
    # The shell that becomes the command closes it: closed for run instead, the command would find
    # a pipe of run's at descriptor 0.
    closed) run bash -c 'exec "$@" <&-' bash timeout 120 "$@" ;;
    null) run timeout 120 "$@" </dev/null ;;
    silent)
      [ -p "$BATS_TEST_TMPDIR/silent" ] || mkfifo "$BATS_TEST_TMPDIR/silent"
      # Open here for reading and writing: the pipe has a writer for as long as the command runs.
      exec {fd}<>"$BATS_TEST_TMPDIR/silent"
      run timeout 120 "$@" <&"$fd"
      exec {fd}>&-
      ;;
    carried) run timeout 120 "$@" < <(printf '%s\n' "$CARRIED") ;;
    *) echo "with_stdin: no state $state"; return 1 ;;
  esac
}

# refused_line FILE WORDS...: a failure message that names FILE and every one of WORDS.
refused_line() {
  local file=$1 line word
  shift
  line=$(grep -F -- "$file" <<<"$output") || { echo "no failure message names $file"; return 1; }
  for word in "$@"; do
    grep -qF -- "$word" <<<"$line" || { echo "no message that names $file says '$word':"; echo "$line"; return 1; }
  done
}

# outside_marker: a ConfigMap beside the fixture tree, at OUTSIDE, whose data holds MARKER, a text
# nothing else holds: a build that read the file shows MARKER in what it yields. CLIMB names the
# same file by a path that climbs out of any directory: twenty ../ and then the path from /.
outside_marker() {
  MARKER="marker-outside-the-tree-$RANDOM$RANDOM"
  OUTSIDE="$BATS_TEST_TMPDIR/outside/marker.yaml"
  mkdir -p "${OUTSIDE%/*}"
  printf '%s\n' '---' 'apiVersion: v1' 'kind: ConfigMap' 'metadata:' '  name: outside' 'data:' "  marker: $MARKER" >"$OUTSIDE"
  CLIMB="$(printf '../%.0s' {1..20})${OUTSIDE#/}"
}

# reads_outside FILE ENTRY: the check, run on the fixture tree with a directory to keep its builds
# in, refuses the tree before it builds anything: it fails, a message names FILE and ENTRY, no
# build is kept, and MARKER is nowhere in its output.
reads_outside() {
  local keep="$BATS_TEST_TMPDIR/keep"
  rm -rf "$keep"
  mkdir "$keep"
  run env LC_ALL="${LOCALE:-C}" KUBERNETES_CHECK_BUILT="$keep" "$CHECK" "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  refused_line "$1" "$2"
  [[ $output != *"$MARKER"* ]]
  [[ $output != *"built "* ]]
  [ -z "$(find "$keep" -mindepth 1 -print -quit)" ]
}

# fresh_tree: the valid fixture tree, made anew.
fresh_tree() {
  rm -rf "$TREE"
  valid_tree
}

# fields FIXTURE: the field list in tests/fixtures/FIXTURE as JSON: {"roots": [...], "types":
# {TYPE: {FIELD: CLASS}}}, a type marked open holding "*": "open".
fields() {
  jq -R -s '
    split("\n") as $lines
    | {"roots": ([$lines[] | select(test("^# roots?: ")) | sub("^# roots?: "; "") | split(" ")[]]),
       "types": (reduce ($lines[] | select(test("^[A-Za-z]")) | split(" ")) as [$t, $f, $c] ({}; .[$t][$f] = $c))}' \
    "$BATS_TEST_DIRNAME/fixtures/$1"
}

# The case variants of a field's name that encoding/json matches to it: its first letter, all of it
# and its last letter in upper case, and every s as U+017F and every k as U+212A, which its folding
# reads as s and k.
# shellcheck disable=SC2016 # $n, $reg, $file, $dir and $t are jq variables.
variants_jq='
  def variants: . as $n
    | [($n[:1] | ascii_upcase) + $n[1:], ($n | ascii_upcase), $n[:-1] + ($n[-1:] | ascii_upcase)]
      + (if ($n | test("s")) then [$n | gsub("s"; "ſ")] else [] end)
      + (if ($n | test("k")) then [$n | gsub("k"; "K")] else [] end)
    | unique | map(select(. != $n)) | .[];
  def object_type($c): ($c | ltrimstr("[]")) as $t | if ($reg.types | has($t)) then $t else null end;
  def leads($c): ($c | IN("path", "paths", "dirs", "files"))
    or (object_type($c) as $t | $t != null and ($reg.types[$t] | to_entries | any(.key != "*" and leads(.value))));
  # What a field holds when it names the marker: a file, a list of files, a Component directory, a
  # generator source, or an object that holds such a field.
  def danger($c):
    if $c == "path" then $file elif $c == "paths" then [$file] elif $c == "dirs" then [$dir]
    elif $c == "files" then ["marker=" + $file] elif $c == "map" then {"marker": $file}
    elif object_type($c) != null then
      ($reg.types[object_type($c)] | to_entries | map(select(.key != "*" and leads(.value)) | {key, value: danger(.value)})
        | from_entries) | if ($c | startswith("[]")) then [.] else . end
    else $file end;
  # An object of TYPE that holds every variant of each of its fields, naming the marker, and each
  # field of an object type by its own name, holding such an object.
  def generate($t):
    $reg.types[$t] as $f
    | reduce ($f | keys[] | select(. != "*")) as $k ({};
        reduce ($k | variants) as $v (.; .[$v] = danger($f[$k]))
        | object_type($f[$k]) as $sub
        | if $sub == null then . else .[$k] = (generate($sub) | if ($f[$k] | startswith("[]")) then [.] else . end) end);
  # Where each variant generate puts is, as the checks name it.
  def variant_keys($t; $where):
    $reg.types[$t] as $f
    | ($f | keys[] | select(. != "*")) as $k
    | (if $where == "" then $k else $where + "." + $k end) as $w
    | (($k | variants) | if $where == "" then . else $where + "." + . end),
      (object_type($f[$k]) as $sub | if $sub == null then empty
       elif ($f[$k] | startswith("[]")) then variant_keys($sub; $w + "[0]") else variant_keys($sub; $w) end);'

# with_variants FIXTURE TYPE FILE: FILE, a YAML or JSON document, merged with an object of TYPE that
# holds every variant of every field of the types FIXTURE lists, written back as JSON; KEYS is where
# each variant is.
with_variants() {
  local reg merged
  reg="$(fields "$1")"
  merged="$(yq -o json -I0 '.' "$3" | jq -c --argjson reg "$reg" --arg file "$CLIMB" --arg dir "$EVIL" --arg t "$2" \
    "$variants_jq"' . * generate($t)')"
  printf '%s\n' "$merged" >"$3"
  KEYS="$(jq -rn --argjson reg "$reg" --arg file "$CLIMB" --arg dir "$EVIL" --arg t "$2" "$variants_jq"' variant_keys($t; "")')"
}

# names_every FILE: the run failed, and for each key in KEYS a line names FILE and the key, as the
# checks show it.
names_every() {
  local key lines missing=""
  [ "$status" -ne 0 ] || { echo "the run passed"; return 1; }
  lines="$(grep -F -- "$1" <<<"$output")" || { echo "no line names $1"; return 1; }
  while IFS= read -r key; do
    grep -qF -- " $(shown "$key") " <<<"$lines" || missing+=" $key"
  done <<<"$KEYS"
  [ -z "$missing" ] || { echo "not named with $1:$missing"; return 1; }
}

# evil_marker: OUTSIDE, a ConfigMap whose data holds MARKER, CLIMB, the same by a path that climbs out
# of any directory, and EVIL, a Component directory beside it that names it by a generator.
evil_marker() {
  outside_marker
  mkdir -p "$BATS_TEST_TMPDIR/outside/evil"
  printf '%s\n' 'apiVersion: kustomize.config.k8s.io/v1alpha1' 'kind: Component' 'configMapGenerator:' \
    '  - name: leak' '    files:' "      - leak=$OUTSIDE" >"$BATS_TEST_TMPDIR/outside/evil/kustomization.yaml"
  EVIL="$(printf '../%.0s' {1..20})${BATS_TEST_TMPDIR#/}/outside/evil"
}

# shown TEXT: TEXT as the checks show a value of the tree: each byte that is not printable ASCII as
# \xHH, read from od, whatever the locale.
shown() {
  local LC_ALL=C byte char out=""
  if [[ $1 != *[!\ -~]* ]]; then
    printf '%s' "$1"
    return
  fi
  for byte in $(printf '%s' "$1" | od -An -v -tx1); do
    if ((16#$byte >= 32 && 16#$byte < 127)); then
      printf -v char '%b' "\\x$byte"
      out+=$char
    else
      out+="\\x$byte"
    fi
  done
  printf '%s' "$out"
}

# utf8_active: C.UTF-8, which the tests run the checks under beside C, is a locale this host has.
utf8_active() {
  local text
  text="$(printf '\xc4\xb0')"
  [ "$(LC_ALL=C.UTF-8 bash -c 'printf %s "${#1}"' bash "$text" 2>/dev/null)" = 1 ] ||
    { echo "C.UTF-8 is no locale of this host, and the tests run the checks under it"; return 1; }
}

# recording_git: a git first on PATH that records each run in GIT_LOG and fails: a check that runs
# git shows in the log, and nothing is fetched.
recording_git() {
  GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  mkdir -p "$BATS_TEST_TMPDIR/recording"
  printf '#!/bin/sh\necho "$*" >>%q\nexit 1\n' "$GIT_LOG" >"$BATS_TEST_TMPDIR/recording/git"
  chmod +x "$BATS_TEST_TMPDIR/recording/git"
  rm -f "$GIT_LOG"
}

# outside_cases: the cases of the scenario of a tree from which a build would read outside it, in
# the locale LOCALE.
outside_cases() {
  outside_marker
  local app=kubernetes/apps/base/demo/hello/app expression entry
  # A generator's file, a resource, a patch and an env file, each by an absolute path and by a path
  # that climbs out of the tree.
  for expression in '.configMapGenerator += [{"name": "leak", "files": ["leak=" + strenv(P)]}]' \
    '.resources += [strenv(P)]' '.patches += [{"path": strenv(P)}]' \
    '.secretGenerator += [{"name": "leak", "envs": [strenv(P)]}]'; do
    for entry in "$OUTSIDE" "$CLIMB"; do
      fresh_tree
      P="$entry" yq -i "$expression" "$TREE/$app/kustomization.yaml"
      reads_outside "$app/kustomization.yaml" "$entry"
    done
  done

  # The resource of the demonstration, which flux build reads from the tree's working directory.
  fresh_tree
  entry="$(realpath -m --relative-to="$TREE/$app" "$OUTSIDE")"
  P="$entry" yq -i '.resources += [strenv(P)]' "$TREE/$app/kustomization.yaml"
  reads_outside "$app/kustomization.yaml" "$entry"

  # A generator's file that is a link in the tree to the file outside: the link and the entry are
  # each refused.
  fresh_tree
  ln -s "$OUTSIDE" "$TREE/$app/linked.yaml"
  yq -i '.configMapGenerator += [{"name": "leak", "files": ["leak=linked.yaml"]}]' "$TREE/$app/kustomization.yaml"
  reads_outside "$app/kustomization.yaml" "leak=linked.yaml"
  refused_line "$app/linked.yaml" "link"

  # A kustomization file that is itself a link to one outside the tree, which names the file.
  fresh_tree
  printf '%s\n' 'apiVersion: kustomize.config.k8s.io/v1beta1' 'kind: Kustomization' 'resources:' "  - $OUTSIDE" \
    >"$BATS_TEST_TMPDIR/outside/kustomization.yaml"
  rm "$TREE/$app/kustomization.yaml"
  ln -s "$BATS_TEST_TMPDIR/outside/kustomization.yaml" "$TREE/$app/kustomization.yaml"
  reads_outside "$app/kustomization.yaml" "link"

  # A Component that names it, which the application takes.
  fresh_tree
  put kubernetes/components/leaky/kustomization.yaml <<EOF
---
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
configMapGenerator:
  - name: leak
    files:
      - leak=$OUTSIDE
EOF
  yq -i '.components += ["../../../../../components/leaky"]' "$TREE/$app/kustomization.yaml"
  reads_outside kubernetes/components/leaky/kustomization.yaml "leak=$OUTSIDE"

  # A remote source, which the check does not fetch.
  for entry in https://example.invalid/leak.yaml git::https://example.invalid/leak.git file:///leak; do
    fresh_tree
    P="$entry" yq -i '.resources += [strenv(P)]' "$TREE/$app/kustomization.yaml"
    reads_outside "$app/kustomization.yaml" "$entry"
  done

  # The application's Kustomization takes a component outside the tree.
  fresh_tree
  mkdir -p "$BATS_TEST_TMPDIR/outside/component"
  printf '%s\n' 'apiVersion: kustomize.config.k8s.io/v1alpha1' 'kind: Component' 'resources:' '  - ../marker.yaml' \
    >"$BATS_TEST_TMPDIR/outside/component/kustomization.yaml"
  entry="$(printf '../%.0s' {1..20})${BATS_TEST_TMPDIR#/}/outside/component"
  P="$entry" yq -i '.spec.components = [strenv(P)]' "$TREE/kubernetes/apps/base/demo/hello/ks.yaml"
  reads_outside kubernetes/apps/base/demo/hello/ks.yaml "$entry"
}

# field_cases: each field of each list, set alone in a document the checks read, and the keys and
# entries they refuse besides, in the locale LOCALE.
field_cases() {
  local fixtures="$BATS_TEST_DIRNAME/fixtures" list root type field class route where value P out
  local top="kubernetes/app/kustomization.yaml" yaml
  rm -rf "$BATS_TEST_TMPDIR/fields" "$BATS_TEST_TMPDIR/kz"
  # Each field, set alone where its type is reached from the root, by its own name: one that names a
  # file is refused for one outside the tree, by an absolute path and by one that climbs out of it,
  # in a line that names the file, the field and the entry; one the checks refuse is refused; any
  # other is accepted. The pinned kustomize knows each of its fields.
  outside_marker
  mkdir -p "$BATS_TEST_TMPDIR/fields/kubernetes/app" "$BATS_TEST_TMPDIR/kz"
  guard() {
    (cd "$BATS_TEST_TMPDIR/fields" && LC_ALL="$LOCALE" bash -c \
      '. "$1/scripts/lib/tree-paths.sh" && tree_paths_refused "$PWD/kubernetes"' bash "$REPO")
  }
  flux_guard() {
    LC_ALL="$LOCALE" bash -c '. "$1/scripts/lib/tree-paths.sh" && kustomization_refused "$2" "$3/app" "$3"' \
      bash "$REPO" "$BATS_TEST_TMPDIR/ks.json" "$BATS_TEST_TMPDIR/fields/kubernetes"
  }
  read_guard() {
    LC_ALL="$LOCALE" bash -c '. "$1/scripts/lib/tree-paths.sh" && read_refused "$2"' bash "$REPO" "$1" \
      <"$BATS_TEST_TMPDIR/ks.json"
  }
  for list in kustomization-fields flux-kustomization-fields read-fields; do
    while IFS=$'\t' read -r root type field class route where; do
      for P in "$OUTSIDE" "$CLIMB"; do
        value="$(jq -cn --arg c "$class" --arg p "$P" 'if $c == "path" then $p elif $c == "paths" or $c == "dirs" then [$p]
          elif $c == "files" then ["a=" + $p] elif $c == "map" then {"a": "b"} elif $c | startswith("[]") then [{}]
          elif $c | test("^[A-Z]") then {} else "a" end')"
        jq -cn --argjson route "$route" --arg field "$field" --argjson value "$value" 'null | setpath($route + [$field]; $value)' \
          >"$BATS_TEST_TMPDIR/ks.json"
        case $list in
          kustomization-fields)
            cp "$BATS_TEST_TMPDIR/ks.json" "$BATS_TEST_TMPDIR/fields/$top"
            out="$(guard)"
            ;;
          flux-kustomization-fields) out="$(flux_guard)" ;;
          read-fields) out="$(read_guard "$root")" ;;
        esac
        case $class in
          path | paths | dirs | files) grep -F -- "$where " <<<"$out" | grep -qF -- "$P" ||
            { echo "$list $type.$field: not refused for $P: $out"; return 1; } ;;
          refused) grep -qF -- "$where " <<<"$out" || { echo "$list $type.$field: not refused: $out"; return 1; } ;;
          *) [ -z "$out" ] || { echo "$list $type.$field: refused: $out"; return 1; } ;;
        esac
      done
      [ "$list" = kustomization-fields ] || continue
      jq -cn --argjson route "$route" --arg field "$field" 'null | setpath($route + [$field]; null)' \
        >"$BATS_TEST_TMPDIR/kz/kustomization.yaml"
      if kustomize build "$BATS_TEST_TMPDIR/kz" 2>&1 | grep -q 'unknown field'; then
        echo "$type.$field: the pinned kustomize has no such field"
        return 1
      fi
    done < <(fields "$list" | jq -r '. as $reg
      | def object_type($c): ($c | ltrimstr("[]")) as $t | if ($reg.types | has($t)) then $t else null end;
        def routes($t; $p): [$t, $p], ($reg.types[$t] | to_entries[] | select(.key != "*") | .key as $k | .value as $c
          | object_type($c) as $sub | select($sub != null)
          | routes($sub; $p + [$k] + (if ($c | startswith("[]")) then [0] else [] end)));
        def where: map(if type == "number" then "[\(.)]" else "." + . end) | join("") | ltrimstr(".");
      [$reg.roots[] as $root | routes($root; []) | [$root] + .] | group_by(.[1]) | map(.[0]) | .[]
      | . as [$root, $type, $route]
      | $reg.types[$type] | to_entries[] | select(.key != "*")
      | [$root, $type, .key, .value, ($route | tojson), (($route + [.key]) | where)] | @tsv')
  done
  # kustomize refuses a field its type does not have, so it reads nothing from one.
  echo 'resourcez: [marker.yaml]' >"$BATS_TEST_TMPDIR/kz/kustomization.yaml"
  kustomize build "$BATS_TEST_TMPDIR/kz" 2>&1 | grep -q 'unknown field "resourcez"'

  # A field the type does not have, in any spelling but its own, which Go's decoder matches without
  # regard to case, or set twice, is refused.
  for yaml in 'resourcez: [a.yaml]' 'Resources: [a.yaml]' 'RESOURCES: [a.yaml]' $'patches:\n  - Path: a.yaml' \
    $'configMapGenerator:\n  - name: a\n    Files: [a.yaml]' $'openapi:\n  Path: a.yaml' \
    $'resources: [a.yaml]\nresources: [b.yaml]'; do
    printf '%s\n' "$yaml" >"$BATS_TEST_TMPDIR/fields/$top"
    out="$(guard)"
    grep -qF -- "$top" <<<"$out" || { echo "not refused: $yaml"; return 1; }
  done
  # So is every form of a remote source kustomize fetches, a file over HTTP or a repository.
  for P in https://example.invalid/a.yaml HTTPS://example.invalid/a.yaml http:a.yaml github.com/example/a \
    GitHub.com:example/a git@example.invalid:example/a user@example.invalid/a git::https://example.invalid/a \
    ssh://example.invalid/a file:///a; do
    echo '{}' | P="$P" yq '.resources = [strenv(P)]' >"$BATS_TEST_TMPDIR/fields/$top"
    out="$(guard)"
    grep -F -- "$top: resources" <<<"$out" | grep -qF -- "$P" || { echo "not refused: $P"; return 1; }
  done
  # A file of the tree whose name holds a colon is no plain path, and is refused with the rest.
  echo '{}' | yq '.resources = ["odd:name.yaml"]' >"$BATS_TEST_TMPDIR/fields/$top"
  grep -F -- "$top: resources" <<<"$(guard)" | grep -qF -- '"odd:name.yaml", which is not a plain path' 
  # kustomize joins a path to the file's directory as text: one that climbs out of the tree that way
  # is refused, though the link it passes leads deeper into the tree; and so is one that leaves the
  # tree once its link is resolved.
  mkdir -p "$BATS_TEST_TMPDIR/fields/kubernetes/app/sub/a/b/c"
  ln -s sub/a/b/c "$BATS_TEST_TMPDIR/fields/kubernetes/app/deep"
  ln -s .. "$BATS_TEST_TMPDIR/fields/kubernetes/app/up"
  for P in deep/../../../outside/marker.yaml up/../outside/marker.yaml; do
    echo '{}' | P="$P" yq '.resources = [strenv(P)]' >"$BATS_TEST_TMPDIR/fields/$top"
    out="$(guard)"
    grep -F -- "$top: resources" <<<"$out" | grep -qF -- "$P" || { echo "not refused: $P: $out"; return 1; }
  done
  # So is YAML that kustomize's decoder may read otherwise than the checks: an anchor, an alias, a
  # merge key, or a tag other than the core schema's, such as binary, which it decodes.
  for yaml in $'a: &a [x.yaml]\nresources: *a' $'resources: &a [x.yaml]' $'patches:\n  - <<: {path: x.yaml}' \
    $'resources: [!!binary eC55YW1s]' $'resources: [!custom x.yaml]'; do
    printf '%s\n' "$yaml" >"$BATS_TEST_TMPDIR/fields/$top"
    out="$(guard)"
    grep -qF -- "$top" <<<"$out" || { echo "not refused: $yaml"; return 1; }
  done
}

# spelling_cases: the cases of the scenario of a key a tool reads under another spelling, in the
# locale LOCALE.
spelling_cases() {
  evil_marker
  local render_tree="$BATS_TEST_TMPDIR/render" out
  # render_tree: a fresh copy of the render's fixture tree, without a chart: nothing is rendered.
  render_tree() {
    rm -rf "$render_tree" "$render_tree.out"
    mkdir -p "$render_tree"
    cp -R "$BATS_TEST_DIRNAME/fixtures/render/kubernetes" "$BATS_TEST_DIRNAME/fixtures/render/versions.yaml" "$render_tree/"
  }
  # The greeter's chart, for a run that gets as far as the ledger's release; nothing is pulled.
  export RENDER_CHART_CACHE="$BATS_TEST_TMPDIR/charts"
  helm package "$BATS_TEST_DIRNAME/fixtures/render/charts/greeter" \
    --destination "$RENDER_CHART_CACHE/charts.example.invalid/greeter/1.0.0" >/dev/null
  render_run() {
    run env LC_ALL="$LOCALE" "$REPO/scripts/render" "$render_tree.out" "$render_tree"
    echo "$output" | grep -v '^built ' | head -n 20
    [[ $output != *"$MARKER"* ]]
    [ -z "$(find "$render_tree.out" -mindepth 1 -print -quit 2>/dev/null)" ]
  }
  check_run() {
    local keep="$BATS_TEST_TMPDIR/keep"
    rm -rf "$keep"
    mkdir "$keep"
    run env LC_ALL="$LOCALE" KUBERNETES_CHECK_BUILT="$keep" "$CHECK" "$TREE"
    echo "$output" | grep -v '^built ' | head -n 20
    [[ $output != *"$MARKER"* ]]
    [ -z "$(find "$keep" -mindepth 1 -print -quit)" ]
  }

  # A kustomization file, which kustomize and flux build read.
  fresh_tree
  with_variants kustomization-fields Kustomization "$TREE/kubernetes/apps/base/demo/hello/app/kustomization.yaml"
  check_run
  names_every kubernetes/apps/base/demo/hello/app/kustomization.yaml
  render_tree
  with_variants kustomization-fields Kustomization "$render_tree/kubernetes/apps/base/web/greeter/app/kustomization.yaml"
  render_run
  names_every kubernetes/apps/base/web/greeter/app/kustomization.yaml

  # An application's Flux Kustomization, which flux build reads.
  fresh_tree
  with_variants flux-kustomization-fields Kustomization "$TREE/kubernetes/apps/base/demo/hello/ks.yaml"
  check_run
  names_every kubernetes/apps/base/demo/hello/ks.yaml
  # The render builds each Kustomization as the one that applies it yields it; the root's patches
  # replace a child's own patches and substituteFrom, so the root itself, which nothing patches,
  # carries them here.
  render_tree
  with_variants flux-kustomization-fields Kustomization "$render_tree/kubernetes/clusters/demo/ks.yaml"
  render_run
  names_every kubernetes/clusters/demo/ks.yaml

  # A HelmRelease and the sources it names, which the render reads and hands no tool; kubernetes-check
  # reads no field of them, and builds them as objects, the marker unread.
  for kind in HelmRelease OCIRepository; do
    render_tree
    out="$render_tree/kubernetes/apps/base/web/greeter/app/$(tr '[:upper:]' '[:lower:]' <<<"$kind").yaml"
    with_variants read-fields "$kind" "$out"
    render_run
    names_every "${out#"$render_tree"/}"
  done
  render_tree
  sed -i 's|^  # - \(../../base/web/ledger/ks.yaml\).*|  - \1|' "$render_tree/kubernetes/apps/overlays/demo/kustomization.yaml"
  with_variants read-fields HelmRepository "$render_tree/kubernetes/apps/base/web/ledger/app/helmrepository.yaml"
  render_run
  names_every kubernetes/apps/base/web/ledger/app/helmrepository.yaml
  fresh_tree
  printf -- '---\napiVersion: helm.toolkit.fluxcd.io/v2\nkind: HelmRelease\nmetadata:\n  name: hello\nspec:\n  interval: 30m\n' \
    >"$TREE/kubernetes/apps/base/demo/hello/app/helmrelease.yaml"
  yq -i '.resources += ["helmrelease.yaml"]' "$TREE/kubernetes/apps/base/demo/hello/app/kustomization.yaml"
  with_variants read-fields HelmRelease "$TREE/kubernetes/apps/base/demo/hello/app/helmrelease.yaml"
  run env LC_ALL="$LOCALE" "$CHECK" "$TREE"
  [ "$status" -eq 0 ]
  [[ $output != *"$MARKER"* ]]

  # A FluxInstance, which the Pod Security check reads and whose patches it hands kustomize.
  local render="$BATS_TEST_TMPDIR/pod-security"
  rm -rf "$render"
  mkdir -p "$render"
  cp -R "$BATS_TEST_DIRNAME/fixtures/pod-security/render" "$BATS_TEST_DIRNAME/fixtures/pod-security/exceptions.yaml" \
    "$BATS_TEST_DIRNAME/fixtures/pod-security/versions.yaml" "$render/"
  out="$render/render/lab/flux-system/FluxInstance.fluxcd.controlplane.io_flux-system_flux.yaml"
  printf -- '---\napiVersion: fluxcd.controlplane.io/v1\nkind: FluxInstance\nmetadata:\n  name: flux\n  namespace: flux-system\nspec:\n  components: [source-controller]\n' >"$out"
  with_variants read-fields FluxInstance "$out"
  run env LC_ALL="$LOCALE" "$REPO/scripts/pod-security-check" "$render/render" "$render/exceptions.yaml" "$render/versions.yaml"
  echo "$output" | head -n 20
  [[ $output != *"$MARKER"* ]]
  names_every "FluxInstance flux-system/flux"
}

# build_root: copies the repository's kubernetes/ tree, adds the child Kustomizations given on
# stdin to the cluster's overlay, and builds the root the way Flux does into $BUILD.
build_root() {
  cp -R "$REPO/kubernetes" "$BATS_TEST_TMPDIR/"
  # Built from the copy's parent, with paths from there, as the check builds.
  cd "$BATS_TEST_TMPDIR" || return 1
  local root="kubernetes/clusters/lab-sto2/ks.yaml" overlay
  overlay="kubernetes/$(yq '.spec.path' "$root")"
  CHILDREN="$overlay/fixture-children.yaml"
  cat >"$CHILDREN"
  if [ -s "$CHILDREN" ]; then
    yq -i '.resources += ["fixture-children.yaml"]' "$overlay/kustomization.yaml"
  fi
  BUILD="$BATS_TEST_TMPDIR/build.yaml"
  flux build kustomization "$(yq '.metadata.name' "$root")" \
    --path "$overlay" --kustomization-file "$root" --dry-run --in-memory-build >"$BUILD"
}

# child NAME EXPRESSION: yq EXPRESSION on the built child Kustomization NAME.
child() {
  yq ea -N "[select(.kind == \"Kustomization\" and .metadata.name == \"$1\")] | .[0] | $2" "$BUILD"
}

# has_defaults NAME TIMEOUT: the built child NAME carries every default the root sets, with TIMEOUT.
has_defaults() {
  local got
  got="$(child "$1" '[.spec.interval, .spec.retryInterval, .spec.timeout, .spec.prune,
    .spec.decryption.provider, .spec.deletionPolicy,
    ([.spec.postBuild.substituteFrom[] | .kind + "/" + .name] | join(",")),
    .spec.patches[0].target.kind, .spec.patches[0].target.labelSelector] | map(tostring) | join(" ")')"
  echo "$1: $got"
  [ "$got" = "30m 1m $2 true sops WaitForTermination ConfigMap/cluster-config,Secret/cluster-secrets HelmRelease k8s-gitops/defaults!=disabled" ]
}

# unchanged NAME: the built child NAME has exactly the spec written for it on build_root's stdin.
unchanged() {
  local want got
  want="$(yq -o json -I0 "select(.metadata.name == \"$1\") | .spec | sort_keys(..)" "$CHILDREN")"
  got="$(child "$1" '.spec | sort_keys(..)' | yq -o json -I0)"
  echo "$1, written: $want"
  echo "$1, built:   $got"
  [ -n "$got" ]
  [ "$got" = "$want" ]
}

@test "The tree builds offline" {
  run "$CHECK"
  echo "$output"
  [ "$status" -eq 0 ]
  # The dependencies of the enabled applications were checked.
  [[ $output =~ ([1-9][0-9]*)\ dependencies ]]

  local built=0 dir
  while read -r dir; do
    grep -qxF "built $dir" <<<"$output" || { echo "not built: $dir"; return 1; }
    built=$((built + 1))
  done < <(cd "$REPO" && find kubernetes -name kustomization.yaml -exec dirname {} \;)
  [ "$built" -gt 0 ]

  # Every Flux Kustomization, the cluster roots and each application, is built by Flux as well.
  local ks flux_built=0
  while read -r ks; do
    grep -qxF "built $ks" <<<"$output" || { echo "not built: $ks"; return 1; }
    flux_built=$((flux_built + 1))
  done < <(cd "$REPO" && find kubernetes -name ks.yaml)
  [ "$flux_built" -gt 1 ]

  # Each cluster directory as well, the way the instance's sync Kustomization builds it.
  local cluster
  for cluster in "$REPO"/kubernetes/clusters/*/; do
    cluster="kubernetes/clusters/$(basename "$cluster")"
    grep -qxF "built $cluster as the instance's sync Kustomization" <<<"$output" ||
      { echo "not built as the sync Kustomization: $cluster"; return 1; }
  done
}

@test "A Kustomization outside flux-system fails the check" {
  valid_tree
  put kubernetes/apps/base/demo/hello/ks.yaml <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: hello
  namespace: demo
spec:
  path: ./apps/base/demo/hello/app
  targetNamespace: demo
  sourceRef:
    kind: ExternalArtifact
    name: hello
EOF

  check
  fails_naming kubernetes/apps/base/demo/hello/ks.yaml "must be in namespace flux-system"
}

@test "An undeclared substitution variable fails the check" {
  valid_tree
  cat >>"$TREE/kubernetes/apps/base/demo/hello/app/configmap.yaml" <<'EOF'
  undeclared: "${UNDECLARED_VAR}"
  defaulted: "${DEFAULTED_VAR:=fallback}"
EOF

  check
  fails_naming kubernetes/apps/base/demo/hello/app/configmap.yaml UNDECLARED_VAR
  [[ "$output" != *DEFAULTED_VAR* ]]
}

@test "An application without an app directory fails the check" {
  valid_tree
  put kubernetes/apps/base/demo/no-app/ks.yaml <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: no-app
  namespace: flux-system
spec:
  path: ./apps/base/demo/no-app/app
  targetNamespace: demo
  sourceRef:
    kind: ExternalArtifact
    name: no-app
EOF

  check
  fails_naming "kubernetes/apps/base/demo/no-app:" "needs both ks.yaml and app/"
}

@test "Children inherit the root defaults" {
  build_root <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: opted-out
  namespace: flux-system
  labels:
    k8s-gitops/defaults: disabled
spec:
  interval: 1h
  path: ./apps/base/demo/opted-out/app
  prune: false
  targetNamespace: demo
  sourceRef:
    kind: ExternalArtifact
    name: opted-out
EOF

  local children name timeout
  children="$(yq -N 'select(.kind == "Kustomization" and .metadata.labels["k8s-gitops/defaults"] != "disabled") | .metadata.name' "$BUILD")"
  [ -n "$children" ]
  for name in $children; do
    # A child labelled for the long timeout gets 10m instead, as the next test shows.
    timeout=3m
    if [ "$(child "$name" '.metadata.labels["k8s-gitops/timeout"]')" = long ]; then
      timeout=10m
    fi
    has_defaults "$name" "$timeout"
  done
  unchanged opted-out
}

@test "HelmReleases applied by a child get the release defaults unless they opt out" {
  build_root </dev/null
  local releases="$BATS_TEST_TMPDIR/releases"
  mkdir -p "$releases"
  # The patches a child carries, applied by kustomize as Flux applies them when it builds the child.
  yq ea '[select(.kind == "Kustomization" and .metadata.labels["k8s-gitops/defaults"] != "disabled")] | .[0]
    | {"apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization",
       "resources": ["releases.yaml"], "patches": .spec.patches}' "$BUILD" >"$releases/kustomization.yaml"
  cat >"$releases/releases.yaml" <<'EOF'
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: plain
spec:
  interval: 1h
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: opted-out
  labels:
    k8s-gitops/defaults: disabled
spec:
  interval: 1h
EOF
  kustomize build "$releases" >"$BATS_TEST_TMPDIR/releases.yaml"

  local want got
  want="$(yq -o json -I0 'sort_keys(..)' <<'EOF'
interval: 1h
install:
  timeout: 10m
  replace: true
  crds: CreateReplace
  createNamespace: true
  remediation:
    retries: 3
upgrade:
  remediation:
    remediateLastFailure: true
    retries: 3
    strategy: rollback
  cleanupOnFail: true
  crds: CreateReplace
test:
  enable: true
rollback:
  force: true
  cleanupOnFail: true
uninstall:
  keepHistory: false
driftDetection:
  mode: enabled
maxHistory: 3
EOF
)"
  got="$(yq -o json -I0 'select(.metadata.name == "plain") | .spec | sort_keys(..)' "$BATS_TEST_TMPDIR/releases.yaml")"
  echo "plain release, want: $want"
  echo "plain release, got:  $got"
  [ "$got" = "$want" ]
  got="$(yq -o json -I0 'select(.metadata.name == "opted-out") | .spec' "$BATS_TEST_TMPDIR/releases.yaml")"
  echo "opted-out release: $got"
  [ "$got" = '{"interval":"1h"}' ]
}

@test "The long-timeout label lengthens the timeout and keeps the other defaults" {
  build_root <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: slow
  namespace: flux-system
  labels:
    k8s-gitops/timeout: long
spec:
  path: ./apps/base/demo/slow/app
  targetNamespace: demo
  sourceRef:
    kind: ExternalArtifact
    name: slow
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: slow-opted-out
  namespace: flux-system
  labels:
    k8s-gitops/defaults: disabled
    k8s-gitops/timeout: long
spec:
  interval: 1h
  path: ./apps/base/demo/slow-opted-out/app
  prune: true
  timeout: 20m
  targetNamespace: demo
  sourceRef:
    kind: ExternalArtifact
    name: slow-opted-out
EOF

  has_defaults slow 10m
  unchanged slow-opted-out
}

@test "A ks.yaml that is not a Flux Kustomization fails the check" {
  valid_tree
  put kubernetes/apps/base/demo/hello/ks.yaml <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - app
EOF

  check
  fails_naming kubernetes/apps/base/demo/hello/ks.yaml "must be a Flux Kustomization"
}

@test "A Kustomization without a sourceRef fails the check" {
  valid_tree
  put kubernetes/apps/base/demo/hello/ks.yaml <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: hello
  namespace: flux-system
spec:
  path: ./apps/base/demo/hello/app
  targetNamespace: demo
EOF

  check
  fails_naming kubernetes/apps/base/demo/hello/ks.yaml "must have a sourceRef"
}

@test "An application without a targetNamespace fails the check" {
  valid_tree
  put kubernetes/apps/base/demo/hello/ks.yaml <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: hello
  namespace: flux-system
spec:
  path: ./apps/base/demo/hello/app
  sourceRef:
    kind: ExternalArtifact
    name: hello
EOF

  check
  fails_naming kubernetes/apps/base/demo/hello/ks.yaml "targetNamespace"
}

@test "A kustomization that does not build fails the check" {
  valid_tree
  put kubernetes/apps/base/demo/hello/app/kustomization.yaml <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
  - missing.yaml
EOF

  check
  fails_naming kubernetes/apps/base/demo/hello/app/kustomization.yaml "kustomize build failed"
}

@test "A root Kustomization whose patches do not apply fails the check" {
  valid_tree
  cat >>"$TREE/kubernetes/clusters/test/ks.yaml" <<'EOF'
  patches:
    - patch: |-
        spec: [not closed
      target:
        kind: Kustomization
EOF

  check
  fails_naming kubernetes/clusters/test/ks.yaml "flux build"
}

@test "A cluster directory without a kustomization.yaml fails the check" {
  valid_tree
  rm "$TREE/kubernetes/clusters/test/kustomization.yaml"

  check
  fails_naming "kubernetes/clusters/test:" "needs a kustomization.yaml"
}

@test "A cluster directory that builds anything but the root and Flux itself fails the check" {
  valid_tree
  local kustomization="$TREE/kubernetes/clusters/test/kustomization.yaml"
  put kubernetes/clusters/test/extra.yaml <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: extra
  namespace: flux-system
EOF
  yq -i '.resources += ["extra.yaml"]' "$kustomization"

  check
  fails_naming "kubernetes/clusters/test:" "ConfigMap/extra"

  yq -i '.resources -= ["extra.yaml", "flux-system/flux-instance/ks.yaml"]' "$kustomization"
  check
  fails_naming "kubernetes/clusters/test:" "does not build Kustomization/flux-instance"
}

@test "An application in a cluster directory whose names do not match its directory fails the check" {
  valid_tree
  local ks=kubernetes/clusters/test/flux-system/flux-operator/ks.yaml
  yq -i '.metadata.name = "operator"' "$TREE/$ks"
  check
  fails_naming "$ks" "metadata.name must be flux-operator"

  cluster_app flux-operator
  yq -i '.spec.sourceRef = {"kind": "ExternalArtifact", "name": "flux-operator"}' "$TREE/$ks"
  check
  fails_naming "$ks" "sourceRef must be OCIRepository flux-system"

  cluster_app flux-operator
  yq -i '.spec.targetNamespace = "other"' "$TREE/$ks"
  check
  fails_naming "$ks" "targetNamespace must be flux-system"

  cluster_app flux-operator
  yq -i '.spec.path = "./clusters/test/flux-system/flux-instance/app"' "$TREE/$ks"
  check
  fails_naming "$ks" "spec.path must be ./clusters/test/flux-system/flux-operator/app"
}

@test "An undeclared variable in a cluster directory's Kustomizations fails the check" {
  valid_tree
  # shellcheck disable=SC2016 # The variable is for Flux, not the shell.
  yq -i '.metadata.annotations.owner = "${ROOT_OWNER}"' "$TREE/kubernetes/clusters/test/ks.yaml"

  check
  fails_naming kubernetes/clusters/test/ks.yaml ROOT_OWNER
}

@test "Flux's own application without the root's decryption and substitution fails the check" {
  valid_tree
  local ks=kubernetes/clusters/test/flux-system/flux-operator/ks.yaml
  yq -i 'del(.spec.decryption)' "$TREE/$ks"
  check
  fails_naming "$ks" "spec.decryption must be"

  cluster_app flux-operator
  yq -i 'del(.spec.postBuild)' "$TREE/$ks"
  check
  fails_naming "$ks" "spec.postBuild.substituteFrom must be"
}

@test "An application with the name of a cluster's own application fails the check" {
  valid_tree
  app kubernetes/apps/base/demo/flux-operator flux-operator demo flux-operator ./apps/base/demo/flux-operator/app

  check
  fails_naming "kubernetes/clusters/test/flux-system/flux-operator:" "also used by kubernetes/apps/base/demo/flux-operator"
}

@test "A ks.yaml that is not valid YAML fails the check" {
  valid_tree
  put kubernetes/apps/base/demo/broken/ks.yaml <<'EOF'
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: [not closed
EOF
  put kubernetes/apps/base/demo/broken/app/kustomization.yaml <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
EOF
  put kubernetes/apps/base/demo/broken/app/configmap.yaml <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: broken
EOF

  check
  fails_naming kubernetes/apps/base/demo/broken/ks.yaml "not valid YAML"
}

@test "A ks.yaml with an empty document passes the check" {
  valid_tree
  hello_ks <<'EOF'
---
EOF

  check
  [ "$status" -eq 0 ]
}

@test "The check gives its tools no cluster to reach" {
  valid_tree
  local shims="$BATS_TEST_TMPDIR/shims" log="$BATS_TEST_TMPDIR/environment.log" tool real
  mkdir -p "$shims"
  for tool in flux kustomize; do
    real="$(command -v "$tool")"
    cat >"$shims/$tool" <<EOF
#!/usr/bin/env bash
echo "$tool KUBECONFIG=\${KUBECONFIG-unset} KUBERNETES_SERVICE_HOST=\${KUBERNETES_SERVICE_HOST-unset}" >>"$log"
exec "$real" "\$@"
EOF
    chmod +x "$shims/$tool"
  done

  run env KUBECONFIG="$BATS_TEST_TMPDIR/kubeconfig" KUBERNETES_SERVICE_HOST=cluster.example.com \
    PATH="$shims:$PATH" "$CHECK" "$TREE"
  echo "$output"
  cat "$log"
  [ "$status" -eq 0 ]
  grep -q '^flux ' "$log"
  grep -q '^kustomize ' "$log"
  [ "$(grep -vc ' KUBECONFIG=/dev/null KUBERNETES_SERVICE_HOST=unset$' "$log")" -eq 0 ]
}

# app DIR NAME TARGET_NAMESPACE SOURCE_NAME PATH: an application at DIR in the fixture tree, its
# ks.yaml written from the arguments and its app/ holding one ConfigMap.
app() {
  put "$1/ks.yaml" <<EOF
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: $2
  namespace: flux-system
spec:
  path: $5
  targetNamespace: $3
  sourceRef:
    kind: ExternalArtifact
    name: $4
EOF
  put "$1/app/kustomization.yaml" <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
EOF
  put "$1/app/configmap.yaml" <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: example
EOF
}

@test "An application whose names do not match its directory fails the check" {
  valid_tree
  local dir=kubernetes/apps/base/demo/hello
  app "$dir" greeting demo hello ./apps/base/demo/hello/app
  check
  fails_naming "$dir/ks.yaml" "metadata.name must be hello"

  app "$dir" hello demo greeting ./apps/base/demo/hello/app
  check
  fails_naming "$dir/ks.yaml" "sourceRef.name must be hello"
}

@test "An application whose targetNamespace is not its namespace directory fails the check" {
  valid_tree
  app kubernetes/apps/base/demo/hello hello other hello ./apps/base/demo/hello/app

  check
  fails_naming kubernetes/apps/base/demo/hello/ks.yaml "targetNamespace must be demo"
}

@test "An application whose path is not its own app directory fails the check" {
  valid_tree
  app kubernetes/apps/base/demo/hello hello demo hello ./apps/base/demo/other/app

  check
  fails_naming kubernetes/apps/base/demo/hello/ks.yaml "spec.path must be ./apps/base/demo/hello/app"
}

@test "An application name that is not a DNS label fails the check" {
  valid_tree
  app kubernetes/apps/base/demo/Hello_World Hello_World demo Hello_World ./apps/base/demo/Hello_World/app

  check
  fails_naming "kubernetes/apps/base/demo/Hello_World:" "must be a DNS label"
}

@test "Two applications with the same name fail the check" {
  valid_tree
  app kubernetes/apps/base/other/hello hello other hello ./apps/base/other/hello/app

  check
  fails_naming "kubernetes/apps/base/other/hello:" "also used by kubernetes/apps/base/demo/hello"
}

# The spec fields the root's defaults overwrite on every child that has not opted out.
OVERRIDDEN_FIELDS='  interval: 1h
  retryInterval: 2m
  timeout: 5m
  prune: false
  deletionPolicy: Delete
  decryption:
    provider: sops
  patches:
    - patch: |-
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: hello
          labels:
            patched: "true"
      target:
        kind: ConfigMap
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: application-values'

@test "An application that sets a field the root overrides fails the check" {
  valid_tree
  hello_ks <<<"$OVERRIDDEN_FIELDS"

  check
  local field
  for field in interval retryInterval timeout prune deletionPolicy decryption patches postBuild.substituteFrom; do
    fails_naming kubernetes/apps/base/demo/hello/ks.yaml "spec.$field is overwritten"
  done
}

@test "An application with the opt-out label may set the fields the root overrides" {
  valid_tree
  hello_ks <<<"$OVERRIDDEN_FIELDS"
  yq -i '.metadata.labels["k8s-gitops/defaults"] = "disabled"' "$TREE/kubernetes/apps/base/demo/hello/ks.yaml"

  check
  [ "$status" -eq 0 ]
}

HELLO_APP=kubernetes/apps/base/demo/hello/app

@test "Variables Flux leaves alone pass the check" {
  valid_tree
  put "$HELLO_APP/kustomization.yaml" <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
  - script.yaml
configMapGenerator:
  - name: hello-values
    files:
      - values.yaml
generatorOptions:
  annotations:
    kustomize.toolkit.fluxcd.io/substitute: disabled
EOF
  put "$HELLO_APP/values.yaml" <<'EOF'
url: http://${HELM_TEMPLATED}/
EOF
  put "$HELLO_APP/script.yaml" <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: script
  annotations:
    kustomize.toolkit.fluxcd.io/substitute: disabled
data:
  run.sh: echo "${SHELL_VAR}"
EOF
  cat >>"$TREE/$HELLO_APP/configmap.yaml" <<'EOF'
  # ${COMMENTED_VAR} appears only in this comment.
  escaped: "$${ESCAPED_VAR}"
EOF

  check
  [ "$status" -eq 0 ]
}

@test "Variables the application or the cluster declares pass the check" {
  valid_tree
  put kubernetes/clusters/test/cluster-secrets.example.yaml <<'EOF'
---
SECRET_TOKEN: placeholder
EOF
  hello_ks <<'EOF'
  postBuild:
    substitute:
      APP_HOST: hello.example.com
EOF
  cat >>"$TREE/$HELLO_APP/configmap.yaml" <<'EOF'
  host: "${APP_HOST}"
  token: "${SECRET_TOKEN}"
  defaulted: "${WITH_DEFAULT:=fallback}"
EOF

  check
  [ "$status" -eq 0 ]
}

@test "An undeclared variable in a generator's input file fails the check" {
  valid_tree
  put "$HELLO_APP/kustomization.yaml" <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
configMapGenerator:
  - name: settings
    files:
      - settings.json
EOF
  put "$HELLO_APP/settings.json" <<'EOF'
{"endpoint": "${JSON_VAR}"}
EOF

  check
  fails_naming "$HELLO_APP/settings.json" JSON_VAR
}

@test "An undeclared variable after an escaped dollar fails the check" {
  valid_tree
  cat >>"$TREE/$HELLO_APP/configmap.yaml" <<'EOF'
  price: "$$${PRICE_VAR}"
EOF

  check
  fails_naming "$HELLO_APP/configmap.yaml" PRICE_VAR
}

@test "A default Flux cannot parse fails the check" {
  valid_tree
  cat >>"$TREE/$HELLO_APP/configmap.yaml" <<'EOF'
  dashed: "${DASH_VAR-fallback}"
EOF

  check
  fails_naming kubernetes/apps/base/demo/hello/ks.yaml "missing closing brace"
}

@test "An undeclared length expansion is named with its file" {
  valid_tree
  put "$HELLO_APP/kustomization.yaml" <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
configMapGenerator:
  - name: odd
    files:
      - odd-name.yaml
EOF
  put "$HELLO_APP/odd-name.yaml" <<'EOF'
length: ${#LENGTH_VAR}
EOF

  check
  fails_naming "$HELLO_APP/odd-name.yaml" LENGTH_VAR

  # A file whose name holds a colon, which no plain path does, is no file a build reads.
  yq -i '.configMapGenerator[0].files = ["odd:name.yaml"]' "$TREE/$HELLO_APP/kustomization.yaml"
  mv "$TREE/$HELLO_APP/odd-name.yaml" "$TREE/$HELLO_APP/odd:name.yaml"
  check
  fails_naming "$HELLO_APP/kustomization.yaml" '"odd:name.yaml", which is not a plain path'
}

@test "An undeclared variable in a namespace directory fails the check" {
  valid_tree
  put kubernetes/apps/base/demo/namespace.yaml <<'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: demo
  labels:
    owner: "${NAMESPACE_OWNER}"
EOF

  check
  fails_naming kubernetes/apps/base/demo/namespace.yaml NAMESPACE_OWNER
}

@test "An application that backs up its volume under another application's name fails the check" {
  valid_tree
  # A stand-in for components/volsync, which names the backup repository after APP.
  put kubernetes/components/volsync/kustomization.yaml <<'EOF2'
---
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
  - configmap.yaml
EOF2
  put kubernetes/components/volsync/configmap.yaml <<'EOF2'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: volsync-fixture
EOF2
  local components='  components:
    - ../../../../../components/volsync'

  hello_ks <<<"$components
  postBuild:
    substitute:
      APP: greeting"
  check
  fails_naming kubernetes/apps/base/demo/hello/ks.yaml "postBuild.substitute.APP must be hello"

  hello_ks <<<"$components"
  check
  fails_naming kubernetes/apps/base/demo/hello/ks.yaml "postBuild.substitute.APP must be hello"

  hello_ks <<<"$components
  postBuild:
    substitute:
      APP: hello"
  check
  [ "$status" -eq 0 ]
}

# overlay_add PATH: lists PATH, a ks.yaml, in the fixture cluster's overlay.
overlay_add() {
  yq -i ".resources += [\"$1\"]" "$TREE/kubernetes/apps/overlays/test/kustomization.yaml"
}

# world_app DEPENDENCY: the enabled application world, which names DEPENDENCY in dependsOn.
world_app() {
  app kubernetes/apps/base/demo/world world demo world ./apps/base/demo/world/app
  yq -i ".spec.dependsOn = [{\"name\": \"$1\"}]" "$TREE/kubernetes/apps/base/demo/world/ks.yaml"
  overlay_add ../../base/demo/world/ks.yaml
}

@test "A dependency on an application the cluster does not enable is refused" {
  valid_tree
  # later is in apps/base, as every application is, but the overlay does not list it.
  app kubernetes/apps/base/demo/later later demo later ./apps/base/demo/later/app
  yq -i '.spec.wait = true' "$TREE/kubernetes/apps/base/demo/later/ks.yaml"
  world_app later

  check
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/world/ks.yaml "Kustomization world names later" apps/overlays/test "does not enable"

  overlay_add ../../base/demo/later/ks.yaml
  check
  [ "$status" -eq 0 ]
}

@test "A dependency whose target does not wait is refused" {
  valid_tree
  world_app hello

  check
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/demo/world/ks.yaml "Kustomization world names hello" apps/overlays/test "does not wait" \
    "wait: true" healthChecks healthCheckExprs

  # wait, or health checks, make the target Ready only once what it applies is.
  yq -i '.spec.wait = true' "$TREE/kubernetes/apps/base/demo/hello/ks.yaml"
  check
  [ "$status" -eq 0 ]
  yq -i 'del(.spec.wait) | .spec.healthChecks = [{"apiVersion": "v1", "kind": "ConfigMap", "name": "hello", "namespace": "demo"}]' \
    "$TREE/kubernetes/apps/base/demo/hello/ks.yaml"
  check
  [ "$status" -eq 0 ]

  # So do health check expressions.
  yq -i 'del(.spec.healthChecks) | .spec.healthCheckExprs = [{"apiVersion": "v1", "kind": "ConfigMap", "current": "true"}]' \
    "$TREE/kubernetes/apps/base/demo/hello/ks.yaml"
  check
  [ "$status" -eq 0 ]

  # What counts is the built Kustomization, after the root's patches, and not the text of its file.
  yq -i 'del(.spec.healthCheckExprs)' "$TREE/kubernetes/apps/base/demo/hello/ks.yaml"
  check
  [ "$status" -ne 0 ]
  yq -i '.spec.patches = [{"target": {"group": "kustomize.toolkit.fluxcd.io", "kind": "Kustomization"},
    "patch": "apiVersion: kustomize.toolkit.fluxcd.io/v1\nkind: Kustomization\nmetadata:\n  name: _\nspec:\n  wait: true\n"}]' \
    "$TREE/kubernetes/clusters/test/ks.yaml"
  check
  [ "$status" -eq 0 ]

  # The Kustomizations the cluster directory builds, which the root does not patch, are read as
  # dependents and as targets: Flux's own instance names the operator, which does not wait.
  yq -i '.spec.dependsOn = [{"name": "flux-operator"}]' "$TREE/kubernetes/clusters/test/flux-system/flux-instance/ks.yaml"
  check
  [ "$status" -ne 0 ]
  refused_line kubernetes/clusters/test/flux-system/flux-instance/ks.yaml "Kustomization flux-instance names flux-operator" "does not wait"
  yq -i '.spec.wait = true' "$TREE/kubernetes/clusters/test/flux-system/flux-operator/ks.yaml"
  check
  [ "$status" -eq 0 ]
  # An application of the overlay may name one of them too.
  yq -i '.spec.dependsOn += [{"name": "flux-operator"}]' "$TREE/kubernetes/apps/base/demo/world/ks.yaml"
  check
  [ "$status" -eq 0 ]
}

@test "An issuer choice is checked without reading standard input when the tree holds no issuers application" {
  local form state usage key
  local -A statuses=() printed=()
  # valid_tree runs the check once, without a bound, on the tree it makes: with standard input at
  # /dev/null, so that run does not depend on what the test was started with, and only the bounded
  # runs below try the four states.
  valid_tree </dev/null
  # The rule reads the ClusterIssuers of kubernetes/apps/base/*/acme-issuers/app/, and the fixture
  # tree has no such application.
  [ -z "$(find "$TREE/kubernetes" -path '*/acme-issuers/*' -print -quit)" ]
  # What yq prints, with status 0, when it is handed the rule's expression, no file and nothing to
  # read: its usage. The issuer chosen below is the first line of that, so a run that took what yq
  # printed then for the names of the issuers would know the issuer and pass the choice.
  usage="$(yq -N 'select(.kind == "ClusterIssuer") | .metadata.name' </dev/null | head -n 1)"
  [ "$usage" = "Usage:" ] ||
    { echo "yq no longer prints its usage when it is handed no file, so the issuer this test chooses has to be chosen anew"; return 1; }
  CARRIED="$(printf '%s\n' '---' 'apiVersion: cert-manager.io/v1' 'kind: ClusterIssuer' 'metadata:' "  name: \"$usage\"")"

  # The tree as it is, in which no Kustomization chooses an issuer, and then with one choice: each in
  # every state of standard input, and every run made before one is judged, so that a failure shows
  # them all.
  for form in none one; do
    if [ "$form" = one ]; then
      hello_ks <<EOF
  postBuild:
    substitute:
      PUBLIC_ISSUER: "$usage"
EOF
    fi
    for state in closed null silent carried; do
      with_stdin "$state" "$CHECK" "$TREE"
      statuses[$form/$state]=$status
      printed[$form/$state]="$(grep -v '^built ' <<<"$output" || true)"
      echo "choice: $form; standard input: $state; status $status"
      echo "${printed[$form/$state]}"
    done
  done

  for state in closed null silent carried; do
    key=none/$state
    [ "${statuses[$key]}" -eq 0 ] || { echo "with no choice and standard input $state the check ended with status ${statuses[$key]}"; return 1; }
    [ "${printed[$key]}" = "kubernetes-check: passed (6 kustomize builds, 5 flux builds, 4 ks.yaml, 3 applications, 0 dependencies)" ]
  done
  for state in closed null silent carried; do
    key=one/$state
    [ "${statuses[$key]}" -eq 1 ] || { echo "with the choice and standard input $state the check ended with status ${statuses[$key]}"; return 1; }
    # Refused twice over: the choice names no dependency on the issuers application, and its issuer
    # is one no application makes. The same lines whatever standard input is, and none that says the
    # issuers could not be read.
    grep -F 'kubernetes/apps/base/demo/hello/ks.yaml: Kustomization hello chooses the issuer Usage?,' <<<"${printed[$key]}" |
      grep -qF 'makes no issuer of that name' || { echo "with standard input $state the choice is not refused as an issuer no application makes"; return 1; }
    [ "$(tail -n 1 <<<"${printed[$key]}")" = "kubernetes-check: 2 failure(s)" ]
    [[ ${printed[$key]} != *"cannot read the ClusterIssuers"* ]]
    [ "${printed[$key]}" = "${printed[one/closed]}" ] || { echo "the lines with standard input $state are not those with it closed"; return 1; }
  done
}

@test "A manifest an application keeps where the artifact does not carry it is refused" {
  valid_tree
  local dir=kubernetes/apps/base/demo/hello
  # Outside app/, which is all the artifact generator publishes.
  put "$dir/extra.yaml" <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: extra
EOF
  # In app/, but nothing lists it, so the build never reads it.
  put "$dir/app/unlisted.yaml" <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: unlisted
EOF
  # Not manifests: values a generator reads, and notes.
  put "$dir/app/values.yaml" <<'EOF'
---
replicas: 1
EOF
  put "$dir/notes.yaml" <<'EOF'
---
- a list that is not an object
EOF

  check
  [ "$status" -ne 0 ]
  refused_line "$dir/extra.yaml" "outside app/"
  refused_line "$dir/app/unlisted.yaml" "kustomization.yaml"
  [[ $output != *"$dir/app/values.yaml"* ]]
  [[ $output != *"$dir/notes.yaml"* ]]

  # What the build reaches counts, however it reaches it: a directory, a patch, a generator's file.
  rm "${TREE:?}/$dir/extra.yaml" "${TREE:?}/$dir/notes.yaml" "${TREE:?}/$dir/app/unlisted.yaml"
  put "$dir/app/sub/kustomization.yaml" <<'EOF'
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - listed.yaml
EOF
  put "$dir/app/sub/listed.yaml" <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: listed
EOF
  put "$dir/app/patch.yaml" <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hello
data:
  patched: "yes"
EOF
  # A manifest a generator carries as data, as a ConfigMap carries a dashboard.
  put "$dir/app/embedded.yaml" <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: embedded
EOF
  yq -i '.resources += ["sub"] | .patches = [{"path": "patch.yaml"}]
    | .configMapGenerator = [{"name": "generated", "files": ["values.yaml", "manifest.yaml=embedded.yaml"]}]' "$TREE/$dir/app/kustomization.yaml"
  check
  [ "$status" -eq 0 ]
}

@test "a jq that fails on the built Kustomizations fails the check, naming what it could not read" {
  valid_tree
  local shims="$BATS_TEST_TMPDIR/shims" real
  real="$(command -v jq)"
  mkdir -p "$shims"
  # A jq that fails on the program named in FAIL_ON and runs every other program.
  cat >"$shims/jq" <<EOF
#!/usr/bin/env bash
if [[ -n \${FAIL_ON:-} && "\$*" == *"\$FAIL_ON"* ]]; then
  echo "jq: error: simulated" >&2
  exit 5
fi
exec "$real" "\$@"
EOF
  chmod +x "$shims/jq"

  run env PATH="$shims:$PATH" "$CHECK" "$TREE"
  echo "$output"
  [ "$status" -eq 0 ]

  run env FAIL_ON='"missing"' PATH="$shims:$PATH" "$CHECK" "$TREE"
  echo "$output"
  fails_naming kubernetes/clusters/test/ks.yaml "dependsOn were not checked"
}

@test "a ks.yaml value holding a '|' or a line break is read as one value" {
  valid_tree
  local ks=kubernetes/apps/base/demo/hello/ks.yaml
  yq -i '.spec.targetNamespace = "de|mo"' "$TREE/$ks"

  check
  [ "$status" -ne 0 ]
  refused_line "$ks" "targetNamespace must be demo"
  # The fields after it are read as what they are.
  [[ $output != *"sourceRef.name must be"* ]]
  [[ $output != *"spec.path must be"* ]]
  [[ $output != *"is overwritten by the root"* ]]

  # A line break does not start a document of its own.
  yq -i '.spec.targetNamespace = "demo\n0|kustomize.toolkit.fluxcd.io/v1|Kustomization|phantom|elsewhere"' "$TREE/$ks"
  check
  [ "$status" -ne 0 ]
  # One failure, the value shown whole on its line, and no document made of what follows the break.
  refused_line "$ks" "targetNamespace must be demo" "found demo?0?kustomize.toolkit.fluxcd.io/v1?Kustomization?phantom?elsewhere"
  [[ $output == *"kubernetes-check: 1 failure(s)"* ]]
}

# kept_builds DIR: the records of DIR/builds as kubernetes-validate reads them, one per line as
# FILE, LABEL and APP_DIR, each shown with printf %q.
kept_builds() {
  local file label app_dir
  while IFS= read -r -d '' file && IFS= read -r -d '' label && IFS= read -r -d '' app_dir; do
    printf '%q %q %q\n' "$file" "$label" "$app_dir"
  done <"$1/builds"
}

@test "the builds the check keeps hold each build once and whole, whatever its path holds" {
  valid_tree
  # A cluster directory whose name holds a '|' and a line break: the root still builds, from the
  # overlay its ks.yaml names, under a label that holds both.
  local cluster=$'te|st\nx'
  mv "$TREE/kubernetes/clusters/test" "$TREE/kubernetes/clusters/$cluster"
  local keep="$BATS_TEST_TMPDIR/keep"
  mkdir "$keep"

  run env KUBERNETES_CHECK_BUILT="$keep" "$CHECK" "$TREE"
  echo "$output"
  local records files
  records="$(kept_builds "$keep")"
  echo "$records"
  files="$(find "$keep" -name '*.yaml' | wc -l)"
  [ "$files" -gt 0 ]
  [ "$(wc -l <<<"$records")" -eq "$files" ]
  # Every record names a file the check wrote, and the root's carries its label whole.
  local file label app_dir
  while IFS= read -r -d '' file && IFS= read -r -d '' label && IFS= read -r -d '' app_dir; do
    [[ $file =~ ^[0-9]+\.yaml$ ]]
    [ -f "$keep/$file" ]
  done <"$keep/builds"
  grep -qxF "$(printf '%q' "kubernetes/clusters/$cluster/ks.yaml")" <<<"$(cut -d' ' -f2 <<<"$records")"
}

@test "the check keeps its builds only in an empty directory that exists" {
  valid_tree
  run env KUBERNETES_CHECK_BUILT="$BATS_TEST_TMPDIR/missing" "$CHECK" "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"KUBERNETES_CHECK_BUILT"*"empty directory"* ]]

  local keep="$BATS_TEST_TMPDIR/keep"
  mkdir "$keep"
  run env KUBERNETES_CHECK_BUILT="$keep" "$CHECK" "$TREE"
  [ "$status" -eq 0 ]
  # A directory used once already holds builds; a second run into it would add to them.
  run env KUBERNETES_CHECK_BUILT="$keep" "$CHECK" "$TREE"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"KUBERNETES_CHECK_BUILT"*"empty directory"* ]]
}

@test "a root whose path leaves the tree fails the check, and nothing outside it is built" {
  valid_tree
  # A directory beside the tree, which a path of ../../outside from the root reaches.
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  printf '%s\n' '---' 'apiVersion: v1' 'kind: ConfigMap' 'metadata:' '  name: outside' >"$BATS_TEST_TMPDIR/outside/configmap.yaml"
  yq -i '.spec.path = "../../outside"' "$TREE/kubernetes/clusters/test/ks.yaml"

  check
  [ "$status" -ne 0 ]
  refused_line kubernetes/clusters/test/ks.yaml "spec.path" "a directory of the tree"
  [[ $output != *"built kubernetes/clusters/test/ks.yaml"* ]]
}

@test "A root path that leaves the tree through a link is refused" {
  valid_tree
  # A directory beside the tree, which a link inside the tree points to, by an absolute path and by
  # a relative one, at the path's last component and at one in its middle.
  mkdir -p "$BATS_TEST_TMPDIR/outside/sub"
  printf '%s\n' '---' 'apiVersion: v1' 'kind: ConfigMap' 'metadata:' '  name: outside' >"$BATS_TEST_TMPDIR/outside/configmap.yaml"
  cp "$BATS_TEST_TMPDIR/outside/configmap.yaml" "$BATS_TEST_TMPDIR/outside/sub/configmap.yaml"
  local target path
  for path in ./apps/overlays/linked ./apps/overlays/linked/sub; do
    for target in "$BATS_TEST_TMPDIR/outside" ../../../../outside; do
      ln -sfn "$target" "$TREE/kubernetes/apps/overlays/linked"
      path="$path" yq -i '.spec.path = env(path)' "$TREE/kubernetes/clusters/test/ks.yaml"

      check
      [ "$status" -ne 0 ]
      refused_line kubernetes/clusters/test/ks.yaml "spec.path" "through a link"
      [[ $output != *"built kubernetes/clusters/test/ks.yaml"* ]]
    done
  done
}

@test "A tree from which a build would read outside it is refused, and nothing is built" {
  utf8_active
  for LOCALE in C C.UTF-8; do
    outside_cases
  done
}

@test "Every field of a kustomization is one the checks read the paths of, accept or refuse" {
  local fixtures="$BATS_TEST_DIRNAME/fixtures" want got module list root type field class route where value P out
  local top="kubernetes/app/kustomization.yaml" yaml
  # The lists are those of the pinned tools: flux records the modules it builds with in its binary,
  # and the kustomize binary is the release its version names.
  while read -r module want; do
    got="$(grep -aoE $'dep\t'"${module//./\\.}"$'\tv[0-9]+\\.[0-9]+\\.[0-9]+' "$(type -P flux)" | cut -f3 | head -n1)"
    [ "$got" = "$want" ] || { echo "flux builds with $module ${got:-(unknown)}, the fields are those of $want: read them again at $got"; return 1; }
  done < <(sed -n 's|^# flux: ||p' "$fixtures/kustomization-fields" "$fixtures/flux-kustomization-fields")
  want="$(sed -n 's|^# kustomize: \(v[0-9.]*\) .*|\1|p' "$fixtures/kustomization-fields")"
  got="$(kustomize version)"
  [ "$got" = "$want" ] || { echo "kustomize is $got, the fields are those of $want: read them again at $got"; return 1; }

  # The checks know exactly the fields listed, as listed, and each line decides what its field holds:
  # a field added to a list without a decision here, or to the checks alone, fails.
  for list in kustomize:kustomization-fields flux:flux-kustomization-fields read:read-fields; do
    diff <(grep -E '^[A-Za-z]' "$fixtures/${list#*:}" | sort) \
      <(. "$REPO/scripts/lib/tree-paths.sh" && tree_paths_fields "${list%%:*}" | sort)
    fields "${list#*:}" | jq -e '.types as $types | [$types[][]] | all(. as $c
      | IN("value", "map", "path", "paths", "dirs", "files", "refused", "open") or ($types | has($c | ltrimstr("[]"))))' >/dev/null ||
      { echo "${list#*:}: a field holds no class the checks decide"; return 1; }
  done

  utf8_active
  for LOCALE in C C.UTF-8; do
    field_cases
  done
}

@test "A key that a tool reads under another spelling is refused, and nothing it names is read" {
  utf8_active
  for LOCALE in C C.UTF-8; do
    spelling_cases
  done
}

@test "a component a Flux Kustomization of this tree names under another spelling is refused" {
  # The review's reproduction on this repository's tree: metrics-server's Kustomization takes a
  # Component beside the tree, written as spec.Components, which flux build reads as components.
  evil_marker
  local real="$BATS_TEST_TMPDIR/real" keep="$BATS_TEST_TMPDIR/keep"
  mkdir -p "$real" "$keep"
  cp -R "$REPO/kubernetes" "$real/"
  cp -R "$BATS_TEST_TMPDIR/outside/evil" "$real/evil"
  yq -i '.spec.Components = ["../../../../../../evil"]' "$real/kubernetes/apps/base/kube-system/metrics-server/ks.yaml"

  run env KUBERNETES_CHECK_BUILT="$keep" "$CHECK" "$real"

  echo "$output" | grep -v '^built '
  [ "$status" -ne 0 ]
  refused_line kubernetes/apps/base/kube-system/metrics-server/ks.yaml "spec.Components "
  [[ $output != *"$MARKER"* ]]
  [ -z "$(find "$keep" -mindepth 1 -print -quit)" ]
}

@test "an empty kustomization file, or one that is no single mapping, is refused naming it" {
  local text
  for text in '' '---' 'resources' '- configmap.yaml' $'resources: [configmap.yaml]\n---\nresources: [configmap.yaml]'; do
    fresh_tree
    printf '%s' "$text" >"$TREE/kubernetes/apps/base/demo/hello/app/kustomization.yaml"
    check
    [ "$status" -ne 0 ]
    refused_line kubernetes/apps/base/demo/hello/app/kustomization.yaml "one mapping"
    [[ $output != *"built "* ]]
  done
}

@test "a path that names a remote source in any case or letter is refused under every locale" {
  # The review's reproduction, gİthub.com, which kustomize lowers with Go's strings.ToLower to
  # github.com, and the forms of a scheme and an scp-style address, in the C locale and in
  # C.UTF-8. git, first on the path and fetching nothing, records any run.
  utf8_active
  recording_git
  local locale entry
  for locale in C C.UTF-8; do
    for entry in "g$(printf '\xc4\xb0')thub.com/example/none" "f$(printf '\xc4\xb0')le:///leak" \
      HTTPS://example.invalid/x.yaml Git@example.invalid:example/none GitHub.com/example/none; do
      fresh_tree
      P="$entry" yq -i '.resources += [strenv(P)]' "$TREE/kubernetes/apps/base/demo/hello/app/kustomization.yaml"
      run env LC_ALL="$locale" PATH="$BATS_TEST_TMPDIR/recording:$PATH" HTTP_PROXY=http://127.0.0.1:0 \
        HTTPS_PROXY=http://127.0.0.1:0 NO_PROXY= no_proxy= "$CHECK" "$TREE"
      echo "$locale $entry:"
      grep -v '^built ' <<<"$output"
      [ "$status" -ne 0 ]
      refused_line kubernetes/apps/base/demo/hello/app/kustomization.yaml " resources " "\"$(shown "$entry")\""
      [[ $output != *"built "* ]]
      [ ! -e "$GIT_LOG" ] || { echo "git ran: $(cat "$GIT_LOG")"; return 1; }
    done
  done
}

@test "A path that is not a plain relative path of the tree is refused, under every locale" {
  utf8_active
  local locale entry i list root type field class route where value out c expected missing
  local -a bad=()
  # A letter outside ASCII, a control character, a tab, a space, an empty segment, an absolute path,
  # a trailing slash, a leading - and ~, a segment that starts with -, an empty entry, and each
  # printable ASCII character outside the grammar.
  bad+=("a$(printf '\xc3\xa9').yaml" "a$(printf '\x01')b.yaml" "a$(printf '\t')b.yaml" "a b.yaml" a//b.yaml /a.yaml a/
    -a.yaml a/-b.yaml '~a.yaml' '')
  for c in '!' '"' '#' '$' '%' '&' "'" '(' ')' '*' '+' ',' ':' ';' '<' '=' '>' '?' '@' '[' "\\" ']' '^' '`' '{' '|' '}' '~'; do
    bad+=("a${c}b.yaml")
  done
  # One kustomization for each entry, which names it in every field of every type that names a
  # file, and a Flux Kustomization whose components name each.
  mkdir -p "$BATS_TEST_TMPDIR/sweep/kubernetes/app"
  expected=""
  for i in "${!bad[@]}"; do
    entry="${bad[i]}"
    mkdir -p "$BATS_TEST_TMPDIR/sweep/kubernetes/e$i"
    echo 'null' >"$BATS_TEST_TMPDIR/sweep.json"
    while IFS=$'\t' read -r root type field class route where; do
      case $class in
        path) value="$(jq -cn --arg e "$entry" '$e')" ;;
        paths | dirs) value="$(jq -cn --arg e "$entry" '[$e]')" ;;
        files) value="$(jq -cn --arg e "k=$entry" '[$e]')" ;;
        *) continue ;;
      esac
      jq -c --argjson route "$route" --arg field "$field" --argjson value "$value" 'setpath($route + [$field]; $value)' \
        "$BATS_TEST_TMPDIR/sweep.json" >"$BATS_TEST_TMPDIR/sweep.next"
      mv "$BATS_TEST_TMPDIR/sweep.next" "$BATS_TEST_TMPDIR/sweep.json"
      [ "$class" = files ] && value="k=$entry" || value="$entry"
      expected+="kubernetes/e$i/kustomization.yaml: $where names \"$(shown "$value")\""$'\n'
    done < <(fields kustomization-fields | jq -r '. as $reg
      | def object_type($c): ($c | ltrimstr("[]")) as $t | if ($reg.types | has($t)) then $t else null end;
        def routes($t; $p): [$t, $p], ($reg.types[$t] | to_entries[] | select(.key != "*") | .key as $k | .value as $c
          | object_type($c) as $sub | select($sub != null)
          | routes($sub; $p + [$k] + (if ($c | startswith("[]")) then [0] else [] end)));
        def where: map(if type == "number" then "[\(.)]" else "." + . end) | join("") | ltrimstr(".");
      [$reg.roots[] as $root | routes($root; []) | [$root] + .] | group_by(.[1]) | map(.[0]) | .[]
      | . as [$root, $type, $route] | $reg.types[$type] | to_entries[] | select(.key != "*")
      | [$root, $type, .key, .value, ($route | tojson), (($route + [.key]) | where)] | @tsv')
    cp "$BATS_TEST_TMPDIR/sweep.json" "$BATS_TEST_TMPDIR/sweep/kubernetes/e$i/kustomization.yaml"
  done
  printf '%s\0' "${bad[@]}" | jq -Rsc '{"spec": {"components": (split("\u0000")[:-1])}}' >"$BATS_TEST_TMPDIR/flux.json"

  for locale in C C.UTF-8; do
    out="$(cd "$BATS_TEST_TMPDIR/sweep" && LC_ALL="$locale" bash -c \
      '. "$1/scripts/lib/tree-paths.sh" && tree_paths_refused "$PWD/kubernetes"' bash "$REPO")"
    missing=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      grep -qF -- "$line" <<<"$out" || missing+=$'\n'"$line"
    done <<<"$expected"
    [ -z "$missing" ] || { echo "$locale: not refused:$missing"; return 1; }
    out="$(LC_ALL="$locale" bash -c '. "$1/scripts/lib/tree-paths.sh" && kustomization_refused "$2" "$3/kubernetes/app" "$3/kubernetes"' \
      bash "$REPO" "$BATS_TEST_TMPDIR/flux.json" "$BATS_TEST_TMPDIR/sweep")"
    for entry in "${bad[@]}"; do
      grep -qF -- "spec.components names \"$(shown "$entry")\"" <<<"$out" ||
        { echo "$locale: spec.components $(shown "$entry") not refused: $out"; return 1; }
    done
    # A root's spec.path, which the checks build, is held to the same grammar.
    mkdir -p "$BATS_TEST_TMPDIR/sweep/kubernetes/clusters/x"
    for entry in "${bad[@]}"; do
      jq -n --arg p "$entry" '{"spec": {"path": $p}}' >"$BATS_TEST_TMPDIR/sweep/kubernetes/clusters/x/ks.yaml"
      out="$(cd "$BATS_TEST_TMPDIR/sweep" && LC_ALL="$locale" bash -c \
        '. "$1/scripts/lib/tree-paths.sh" && root_path_refused kubernetes/clusters/x/ks.yaml "$PWD/kubernetes"' bash "$REPO")"
      grep -qF -- "kubernetes/clusters/x/ks.yaml: spec.path" <<<"$out" ||
        { echo "$locale: spec.path $(shown "$entry") not refused"; return 1; }
    done
    rm -rf "$BATS_TEST_TMPDIR/sweep/kubernetes/clusters"
  done
}

@test "The check's builds fetch nothing from another machine, whatever a kustomization names" {
  # A copy of the code with the guard taken out, so that a kustomization naming a remote source
  # reaches kustomize and flux build. git, first on the caller's path, records any run; the caller's
  # proxy is a closed port the check's own is not, so a fetch that used the caller's settings shows.
  recording_git
  local code="$BATS_TEST_TMPDIR/code" entry render="$BATS_TEST_TMPDIR/render"
  mkdir -p "$code"
  cp -R "$REPO/scripts" "$code/"
  printf '%s\n' 'tree_paths_refused() { :; }' 'kustomization_refused() { :; }' >>"$code/scripts/lib/tree-paths.sh"
  for entry in github.com/example/none https://example.invalid/x.yaml; do
    fresh_tree
    P="$entry" yq -i '.resources += [strenv(P)]' "$TREE/kubernetes/apps/base/demo/hello/app/kustomization.yaml"
    run env PATH="$BATS_TEST_TMPDIR/recording:$PATH" HTTP_PROXY=http://127.0.0.1:1 HTTPS_PROXY=http://127.0.0.1:1 \
      "$code/scripts/kubernetes-check" "$TREE"
    echo "$entry:"
    grep -v '^built ' <<<"$output"
    [ "$status" -ne 0 ]
    [ ! -e "$GIT_LOG" ] || { echo "git ran: $(cat "$GIT_LOG")"; return 1; }
    [[ $output != *"lookup "* && $output != *"127.0.0.1:1"* ]]
    # kustomize ran the check's own git, and sent its request to the closed port of the loopback.
    case $entry in
      github.com/*) [[ $output == *"kustomize build failed"*"git is not run by the checks"* ]] ;;
      https://*) [[ $output == *"kustomize build failed"*"proxyconnect tcp: dial tcp 127.0.0.1:0"* ]] ;;
    esac

    # The render builds with flux build in the same environment, and reaches neither git nor a host.
    rm -rf "$render" "$render.out"
    mkdir -p "$render"
    cp -R "$BATS_TEST_DIRNAME/fixtures/render/kubernetes" "$BATS_TEST_DIRNAME/fixtures/render/versions.yaml" "$render/"
    P="$entry" yq -i '.resources += [strenv(P)]' "$render/kubernetes/apps/base/web/greeter/app/kustomization.yaml"
    run env PATH="$BATS_TEST_TMPDIR/recording:$PATH" HTTP_PROXY=http://127.0.0.1:1 HTTPS_PROXY=http://127.0.0.1:1 \
      "$code/scripts/render" "$render.out" "$render"
    echo "render: $output"
    [ "$status" -ne 0 ]
    [ ! -e "$GIT_LOG" ] || { echo "git ran: $(cat "$GIT_LOG")"; return 1; }
    [[ $output != *"lookup "* && $output != *"127.0.0.1:1"* ]]
  done
}

@test "the checks run their tools in the C locale, whatever the caller's" {
  # Stand-ins first on the path record the locale each tool sees, and run it. The checks run under
  # C.UTF-8, and every tool they run sees C, which each script sets for itself.
  utf8_active
  local bin="$BATS_TEST_TMPDIR/locale-bin" log="$BATS_TEST_TMPDIR/locale.log" tool real render="$BATS_TEST_TMPDIR/render"
  mkdir -p "$bin"
  for tool in kustomize flux helm kyverno; do
    real="$(type -P "$tool")"
    # shellcheck disable=SC2016 # ${LC_ALL:-unset} is the stand-in's own.
    printf '#!/usr/bin/env bash\necho "%s ${LC_ALL:-unset}" >>%q\nexec %q "$@"\n' "$tool" "$log" "$real" >"$bin/$tool"
    chmod +x "$bin/$tool"
  done

  valid_tree
  run env LC_ALL=C.UTF-8 PATH="$bin:$PATH" "$CHECK" "$TREE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  mkdir -p "$render"
  cp -R "$BATS_TEST_DIRNAME/fixtures/render/kubernetes" "$BATS_TEST_DIRNAME/fixtures/render/versions.yaml" "$render/"
  helm package "$BATS_TEST_DIRNAME/fixtures/render/charts/greeter" \
    --destination "$BATS_TEST_TMPDIR/charts/charts.example.invalid/greeter/1.0.0" >/dev/null
  run env LC_ALL=C.UTF-8 PATH="$bin:$PATH" RENDER_CHART_CACHE="$BATS_TEST_TMPDIR/charts" \
    "$REPO/scripts/render" "$render.out" "$render"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  cp -R "$BATS_TEST_DIRNAME/fixtures/pod-security" "$BATS_TEST_TMPDIR/pod-security"
  run env LC_ALL=C.UTF-8 PATH="$bin:$PATH" "$REPO/scripts/pod-security-check" "$BATS_TEST_TMPDIR/pod-security/render" \
    "$BATS_TEST_TMPDIR/pod-security/exceptions.yaml" "$BATS_TEST_TMPDIR/pod-security/versions.yaml"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  cat "$log"
  for tool in kustomize flux helm kyverno; do
    grep -qx "$tool C" "$log" || { echo "$tool ran in no C locale"; return 1; }
  done
  [ "$(grep -cvx '[a-z]* C' "$log")" -eq 0 ]
}
