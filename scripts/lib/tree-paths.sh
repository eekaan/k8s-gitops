# shellcheck shell=bash
# What a tool is handed of a kubernetes/ tree, bounded to the tree, and read by the checks under the
# names the tool reads. flux build reads with kustomize's load restrictions off (LoadRestrictionsNone,
# its own setting), and so does scripts/kubernetes-check's kustomize, as an overlay lists ks.yaml
# files outside its own directory: either reads any path a kustomization names and follows any link.
# Both decode a kustomization, and flux build the Flux Kustomization it is given, with encoding/json,
# which reads a key into a field when the key is the field's name or folds to it (encoding/json's
# fold.go and decode.go). scripts/render and scripts/kubernetes-check therefore refuse, before they
# build or read anything else of it, a tree in which
#   - a link resolves outside the tree, or to nothing: then nothing in the tree leads outside it
#     but the text of a path;
#   - a kustomization file (kustomization.yaml, kustomization.yml or Kustomization, a Component's
#     included) is not one mapping; holds YAML that kustomize's decoder may read otherwise than
#     yq (a key twice, an anchor, an alias, a merge key, a tag outside YAML's core schema, a NUL
#     character); holds, at any typed position, a key that is not ASCII, or not exactly one of the
#     fields kustomize reads there (tree_paths_kustomize_fields), or one of those the checks refuse;
#     or names, in a field that names files, an entry that is not a plain path (tree_paths_plain_jq)
#     or names a repository on github.com, or a path that leaves the tree, read as text, as
#     kustomize joins it to the file's directory, or with every link on it resolved;
#   - a cluster's root Kustomization's spec.path is not a plain path, nor a directory of the tree as
#     it resolves.
# scripts/kubernetes-validate holds each source it builds definitions from, a repository's checkout
# or a chart's unpacked layer, to the first two before it builds any of it, the source for the tree.
# Every kustomization file the builds read is one of the tree's, so the checks read each of them,
# used or not. A Flux Kustomization is checked as it is handed to flux build
# (kustomization_refused): at every typed position (tree_paths_flux_fields), a key that is not ASCII,
# or that folds to a field's name without being it, is refused, as is a Component that is not a
# plain path of the tree. A document no tool decodes, which the checks read and derive a tool's input
# from (a HelmRelease, its sources, a FluxInstance, a Kustomization that applies from a GitRepository
# or an OCIRepository and that source), is checked by read_refused against the fields they read
# (tree_paths_read_fields).
#
# The text of the tree is judged by jq, which reads it as Unicode code points whatever the locale,
# and every function here that matches, sorts or shows text runs in the C locale, so that what the
# caller's locale is changes nothing. Each refusal is one line, FILE: what is refused, FILE a path
# from the tree's parent; a value from the tree is shown with each byte that is not printable ASCII
# as \xHH (tree_paths_show).
#
# A plain path is no URL, so no entry the checks accept names one. Under that rule, the builds of
# the checks run in a second layer (tree_paths_offline): git resolves to a stand-in that refuses,
# which is what kustomize runs for a remote base, and the proxy variables name a closed port of the
# loopback, where Go's HTTP client sends a request for any host but the loopback itself.

# The recorded field lists, one field a line: the type, the field and what it holds (value, map,
# path, paths, dirs, files, refused, a type, or a list of a type), and TYPE * open for a type at
# which only a key that folds to one of its fields without being it is refused; at any other type
# every key that is not one of its fields is. tests/fixtures/kustomization-fields,
# flux-kustomization-fields and read-fields record the same lists, with the sources they are read
# from and the versions of the pinned tools they hold for.
tree_paths_kustomize_fields='Kustomization apiVersion value
Kustomization kind value
Kustomization metadata ObjectMeta
Kustomization openapi OpenAPI
Kustomization namePrefix value
Kustomization nameSuffix value
Kustomization namespace value
Kustomization commonLabels map
Kustomization labels []Label
Kustomization commonAnnotations map
Kustomization patchesStrategicMerge paths
Kustomization patchesJson6902 []Patch
Kustomization patches []Patch
Kustomization images []Image
Kustomization imageTags []Image
Kustomization replacements []ReplacementField
Kustomization replicas []Replica
Kustomization vars []Var
Kustomization sortOptions SortOptions
Kustomization resources paths
Kustomization components dirs
Kustomization crds paths
Kustomization bases paths
Kustomization configMapGenerator []ConfigMapArgs
Kustomization secretGenerator []SecretArgs
Kustomization helmGlobals refused
Kustomization helmCharts refused
Kustomization helmChartInflationGenerator refused
Kustomization generatorOptions GeneratorOptions
Kustomization configurations paths
Kustomization generators refused
Kustomization transformers refused
Kustomization validators refused
Kustomization buildMetadata value
ObjectMeta name value
ObjectMeta namespace value
ObjectMeta labels map
ObjectMeta annotations map
OpenAPI path path
OpenAPI version value
Label pairs map
Label includeSelectors value
Label includeTemplates value
Label includeVolumeClaimTemplates value
Label fields []FieldSpec
FieldSpec group value
FieldSpec version value
FieldSpec kind value
FieldSpec path value
FieldSpec create value
Patch path path
Patch patch value
Patch target Selector
Patch options PatchArgs
PatchArgs allowNameChange value
PatchArgs allowKindChange value
Selector group value
Selector version value
Selector kind value
Selector name value
Selector namespace value
Selector annotationSelector value
Selector labelSelector value
Image name value
Image newName value
Image tagSuffix value
Image newTag value
Image digest value
ReplacementField path path
ReplacementField source SourceSelector
ReplacementField targets []TargetSelector
ReplacementField sourceValue value
SourceSelector group value
SourceSelector version value
SourceSelector kind value
SourceSelector name value
SourceSelector namespace value
SourceSelector fieldPath value
SourceSelector options FieldOptions
TargetSelector select Selector
TargetSelector reject []Selector
TargetSelector fieldPaths value
TargetSelector options FieldOptions
FieldOptions delimiter value
FieldOptions index value
FieldOptions encoding value
FieldOptions create value
Replica name value
Replica count value
Var name value
Var objref Target
Var fieldref FieldSelector
Target apiVersion value
Target group value
Target version value
Target kind value
Target name value
Target namespace value
FieldSelector fieldPath value
SortOptions order value
SortOptions legacySortOptions LegacySortOptions
LegacySortOptions orderFirst value
LegacySortOptions orderLast value
ConfigMapArgs namespace value
ConfigMapArgs name value
ConfigMapArgs behavior value
ConfigMapArgs literals value
ConfigMapArgs files files
ConfigMapArgs envs paths
ConfigMapArgs env path
ConfigMapArgs options GeneratorOptions
SecretArgs namespace value
SecretArgs name value
SecretArgs behavior value
SecretArgs literals value
SecretArgs files files
SecretArgs envs paths
SecretArgs env path
SecretArgs options GeneratorOptions
SecretArgs type value
GeneratorOptions labels map
GeneratorOptions annotations map
GeneratorOptions disableNameSuffixHash value
GeneratorOptions immutable value'
tree_paths_flux_fields='Kustomization * open
Kustomization apiVersion value
Kustomization kind value
Kustomization metadata ObjectMeta
Kustomization spec KustomizationSpec
Kustomization status refused
ObjectMeta * open
ObjectMeta name value
ObjectMeta generateName value
ObjectMeta namespace value
ObjectMeta selfLink value
ObjectMeta uid value
ObjectMeta resourceVersion value
ObjectMeta generation value
ObjectMeta creationTimestamp value
ObjectMeta deletionTimestamp value
ObjectMeta deletionGracePeriodSeconds value
ObjectMeta labels map
ObjectMeta annotations map
ObjectMeta ownerReferences refused
ObjectMeta finalizers value
ObjectMeta managedFields refused
KustomizationSpec * open
KustomizationSpec commonMetadata CommonMetadata
KustomizationSpec dependsOn []DependencyReference
KustomizationSpec decryption Decryption
KustomizationSpec interval value
KustomizationSpec retryInterval value
KustomizationSpec kubeConfig KubeConfigReference
KustomizationSpec path value
KustomizationSpec postBuild PostBuild
KustomizationSpec prune value
KustomizationSpec deletionPolicy value
KustomizationSpec healthChecks []NamespacedObjectKindReference
KustomizationSpec namePrefix value
KustomizationSpec nameSuffix value
KustomizationSpec patches []Patch
KustomizationSpec images []Image
KustomizationSpec serviceAccountName value
KustomizationSpec sourceRef CrossNamespaceSourceReference
KustomizationSpec suspend value
KustomizationSpec targetNamespace value
KustomizationSpec timeout value
KustomizationSpec force value
KustomizationSpec wait value
KustomizationSpec buildMetadata value
KustomizationSpec components dirs
KustomizationSpec ignoreMissingComponents value
KustomizationSpec healthCheckExprs []CustomHealthCheck
KustomizationSpec ignore []IgnoreRule
CommonMetadata * open
CommonMetadata annotations map
CommonMetadata labels map
DependencyReference * open
DependencyReference name value
DependencyReference namespace value
DependencyReference readyExpr value
Decryption * open
Decryption provider value
Decryption serviceAccountName value
Decryption secretRef LocalObjectReference
LocalObjectReference * open
LocalObjectReference name value
KubeConfigReference * open
KubeConfigReference configMapRef LocalObjectReference
KubeConfigReference secretRef SecretKeyReference
SecretKeyReference * open
SecretKeyReference name value
SecretKeyReference key value
PostBuild * open
PostBuild substituteStrategy value
PostBuild substitute map
PostBuild substituteFrom []SubstituteReference
SubstituteReference * open
SubstituteReference kind value
SubstituteReference name value
SubstituteReference optional value
NamespacedObjectKindReference * open
NamespacedObjectKindReference apiVersion value
NamespacedObjectKindReference kind value
NamespacedObjectKindReference name value
NamespacedObjectKindReference namespace value
Patch * open
Patch patch value
Patch target Selector
Selector * open
Selector group value
Selector version value
Selector kind value
Selector namespace value
Selector name value
Selector annotationSelector value
Selector labelSelector value
Image * open
Image name value
Image newName value
Image newTag value
Image digest value
CrossNamespaceSourceReference * open
CrossNamespaceSourceReference apiVersion value
CrossNamespaceSourceReference kind value
CrossNamespaceSourceReference name value
CrossNamespaceSourceReference namespace value
CustomHealthCheck * open
CustomHealthCheck apiVersion value
CustomHealthCheck kind value
CustomHealthCheck current value
CustomHealthCheck inProgress value
CustomHealthCheck failed value
IgnoreRule * open
IgnoreRule paths value
IgnoreRule target Selector'
tree_paths_read_fields='HelmRelease * open
HelmRelease apiVersion value
HelmRelease kind value
HelmRelease metadata Metadata
HelmRelease spec HelmReleaseSpec
Metadata * open
Metadata name value
Metadata namespace value
HelmReleaseSpec * open
HelmReleaseSpec chartRef ChartReference
HelmReleaseSpec chart Chart
HelmReleaseSpec valuesFrom []ValuesReference
HelmReleaseSpec values map
HelmReleaseSpec releaseName value
HelmReleaseSpec targetNamespace value
HelmReleaseSpec postRenderers []PostRenderer
HelmReleaseSpec test Test
ChartReference * open
ChartReference kind value
ChartReference name value
ChartReference namespace value
Chart * open
Chart spec ChartSpec
ChartSpec * open
ChartSpec chart value
ChartSpec version value
ChartSpec sourceRef SourceReference
ChartSpec valuesFiles value
SourceReference * open
SourceReference kind value
SourceReference name value
SourceReference namespace value
ValuesReference * open
ValuesReference kind value
ValuesReference name value
ValuesReference valuesKey value
ValuesReference targetPath value
ValuesReference optional value
PostRenderer kustomize PostRendererKustomize
PostRendererKustomize patches []Patch
PostRendererKustomize images []Image
Patch patch value
Patch target Selector
Selector group value
Selector version value
Selector kind value
Selector namespace value
Selector name value
Selector annotationSelector value
Selector labelSelector value
Image name value
Image newName value
Image newTag value
Image digest value
Test * open
Test enable value
Test filters []TestFilter
TestFilter * open
TestFilter name value
TestFilter exclude value
OCIRepository * open
OCIRepository apiVersion value
OCIRepository kind value
OCIRepository metadata Metadata
OCIRepository spec OCIRepositorySpec
OCIRepositorySpec * open
OCIRepositorySpec url value
OCIRepositorySpec ref OCIRepositoryRef
OCIRepositorySpec layerSelector LayerSelector
OCIRepositoryRef * open
OCIRepositoryRef tag value
LayerSelector * open
LayerSelector mediaType value
LayerSelector operation value
HelmRepository * open
HelmRepository apiVersion value
HelmRepository kind value
HelmRepository metadata Metadata
HelmRepository spec HelmRepositorySpec
HelmRepositorySpec * open
HelmRepositorySpec url value
HelmRepositorySpec type value
HelmRepositorySpec provider value
HelmRepositorySpec secretRef value
HelmRepositorySpec certSecretRef value
FluxInstance * open
FluxInstance apiVersion value
FluxInstance kind value
FluxInstance metadata Metadata
FluxInstance spec FluxInstanceSpec
FluxInstanceSpec * open
FluxInstanceSpec components value
FluxInstanceSpec kustomize FluxInstanceKustomize
FluxInstanceKustomize * open
FluxInstanceKustomize patches []Patch
GitRepository * open
GitRepository apiVersion value
GitRepository kind value
GitRepository metadata Metadata
GitRepository spec GitRepositorySpec
GitRepositorySpec * open
GitRepositorySpec url value
GitRepositorySpec ref GitRepositoryRef
GitRepositorySpec sparseCheckout value
GitRepositoryRef * open
GitRepositoryRef tag value
Kustomization * open
Kustomization apiVersion value
Kustomization kind value
Kustomization metadata Metadata
Kustomization spec KustomizationSpec
KustomizationSpec * open
KustomizationSpec path value
KustomizationSpec sourceRef SourceReference'

# tree_paths_registry LINES: the field list LINES as JSON, {"types": {TYPE: {FIELD: CLASS}}}.
tree_paths_registry() {
  jq -R -s 'reduce (split("\n")[] | select(test("^[A-Za-z]")) | split(" ")) as [$t, $f, $c] ({"types": {}};
    .types[$t][$f] = $c)' <<<"$1"
}
tree_paths_kustomize=$(tree_paths_registry "$tree_paths_kustomize_fields")
tree_paths_flux=$(tree_paths_registry "$tree_paths_flux_fields")
tree_paths_read=$(tree_paths_registry "$tree_paths_read_fields")

# tree_paths_fields NAME: the field list NAME (kustomize, flux or read), one line each.
tree_paths_fields() {
  local list="tree_paths_${1}_fields"
  printf '%s\n' "${!list}"
}

# A plain path: relative, of segments of ASCII letters, digits, ".", "_" and "-", none empty and
# none that starts with "-"; a segment that is exactly ".." climbs, and the path still has to name a
# path of the tree, while dots inside a longer segment are part of a name. It holds no ":", "@",
# "?", "#", "%", "\", "~", space, control character or byte outside ASCII, so it is no URL, no
# scp-style address and no git:: form, and the one remote kustomize reads in what remains is a path
# whose first segment is github.com, in any case of its ASCII letters (api/internal/git/repospec.go
# at v0.21.2: isStandardGithubHost lowers with strings.ToLower; no other host is read as remote
# without a scheme or a user). A KEY=PATH entry of a generator's files has a key of the same
# characters, without "/".
# shellcheck disable=SC2016 # jq regular expressions, not expansions.
tree_paths_plain_jq='
  def plain: type == "string" and test("\\A[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\\z") and (test("(\\A|/)-") | not);
  def github: ascii_downcase | startswith("github.com/");'

# The walk of a document against a field list: jq, on one JSON document of the type $root, writes a
# record for each key it refuses and each path a field names, four values each ended by a NUL:
# field, where the key is, why it is refused, and nothing; bad, where it is, the entry, and why it
# is refused; path, where it is, the entry, and the path the entry names; doc, nothing, why the
# document is refused, and nothing. A record is written whole, so jq failing leaves no part of one.
# A document that holds a NUL, which no key and no path does, is refused whole, so that no value
# can end a record early.
# shellcheck disable=SC2016 # $reg, $root, $tool, $folded and $refused are jq variables.
tree_paths_walk_jq="$tree_paths_plain_jq"'
  def record: map(tostring + "\u0000") | add;
  def ascii: explode | all(. < 128);
  def object_type($c): ($c | ltrimstr("[]")) as $t | if ($reg.types | has($t)) then $t else null end;
  def walk($c; $where):
    if $c == "value" or $c == "map" then empty
    elif $c == "refused" then ["field", $where, $refused, ""]
    elif ($c | IN("path", "paths", "dirs", "files")) then
      (if type == "array" then .[] else . end) | select(type == "string" or type == "number") | tostring
      | . as $entry
      | (if $c == "files" and test("=") then [capture("\\A(?<key>[^=]*)=(?<path>.*)\\z"; "m") | .key, .path]
         else [null, .] end) as [$key, $path]
      | if ($key != null and ($key | test("\\A[A-Za-z0-9._-]+\\z") | not)) or ($path | plain | not) then
          ["bad", $where, $entry, "which is not a plain path: one relative path of segments of A-Z, a-z, 0-9, \".\", \"_\" and \"-\", none empty and none that starts with \"-\"\(if $c == "files" then ", after a KEY= of the same characters" else "" end)"]
        elif $path | github then ["bad", $where, $entry, "a repository on github.com, which the checks do not fetch"]
        else ["path", $where, $entry, $path] end
    elif object_type($c) == null then empty
    elif ($c | startswith("[]")) then
      select(type == "array") | to_entries[] | .key as $i | .value | walk($c[2:]; "\($where)[\($i)]")
    else
      $reg.types[$c] as $f
      | select(type == "object")
      | (($f["*"] // "") == "open") as $open
      | to_entries[] | .key as $k | .value as $v
      | (if $where == "" then $k else $where + "." + $k end) as $w
      | if ($k | ascii | not) then ["field", $w, "is not ASCII: the checks accept keys of ASCII alone", ""]
        elif $k != "*" and ($f | has($k)) then $v | walk($f[$k]; $w)
        else ([$f | keys[] | select(. != "*" and ascii_upcase == ($k | ascii_upcase))] | first) as $name
          | if $name != null then
              ["field", $w, "folds to \($name) without being it: \(if $open then $folded else "\($tool) would read it as that field" end)", ""]
            elif $open then empty
            else ["field", $w, "is not one of the fields \($tool) reads there, by its exact name", ""] end
        end
    end;
  if type != "object" then empty
  elif ([.. | strings, (objects | keys[])] | any(contains("\u0000"))) then ["doc", "", "holds a NUL character", ""] | record
  else walk($root; "") | record end'

# tree_paths_walk REGISTRY TYPE TOOL FOLDED REFUSED: the records of the walk of each JSON document on
# stdin against the field list REGISTRY, from its type TYPE; TOOL names what reads a type that is not
# open, FOLDED what becomes of a key at an open type that folds to a field's name, REFUSED why a
# refused field is.
tree_paths_walk() {
  jq -j --argjson reg "$1" --arg root "$2" --arg tool "$3" --arg folded "$4" --arg refused "$5" \
    "$tree_paths_walk_jq" 2>/dev/null ||
    printf '%s\0' doc "" "cannot be read" ""
}

# tree_paths_lines NAME DIR ROOT [SHOWN]: reads the records of a walk on stdin and writes a line for
# each refusal, NAME: what is refused; a path is read from DIR and must name a path in ROOT, which
# the lines call SHOWN, kubernetes/ unless given.
tree_paths_lines() {
  local -x LC_ALL=C
  local name=$1 dir=$2 root=$3 shown=${4:-kubernetes/} kind where text path reason
  while IFS= read -r -d '' kind && IFS= read -r -d '' where && IFS= read -r -d '' text && IFS= read -r -d '' path; do
    [[ $where != *[!\ -~]* ]] || where=$(tree_paths_show "$where")
    [[ $text != *[!\ -~]* ]] || text=$(tree_paths_show "$text")
    case $kind in
      field) echo "${name}$where $text" ;;
      bad) echo "${name}$where names \"$text\", $path" ;;
      path)
        reason=$(path_refusal "$dir" "$path" "$root" "$shown")
        [[ -z $reason ]] || echo "${name}$where names \"$text\", $reason"
        ;;
      *) echo "${name%: }: $text" ;;
    esac
  done
}

# tree_paths_show TEXT: TEXT with each byte that is not printable ASCII written as \xHH, as the
# checks show a value of the tree.
tree_paths_show() {
  local -x LC_ALL=C
  local text=$1 out="" byte i
  for ((i = 0; i < ${#text}; i++)); do
    byte=${text:i:1}
    if [[ $byte == [\ -~] ]]; then
      out+=$byte
    else
      printf -v byte '\\x%02x' "'$byte"
      out+=$byte
    fi
  done
  printf '%s' "$out"
}

# tree_paths_plain PATH: whether PATH is a plain path, as tree_paths_plain_jq says.
tree_paths_plain() {
  local -x LC_ALL=C
  [[ $1 =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && ! $1 =~ (^|/)- ]]
}

# tree_paths_inside ROOT PATH: whether PATH is ROOT or below it.
tree_paths_inside() {
  local -x LC_ALL=C
  [[ -n $2 && ($2 == "$1" || $2 == "$1"/*) ]]
}

# tree_paths_odd FILE: whether the YAML in FILE holds what kustomize's decoder may read otherwise
# than yq: a key twice, an anchor, an alias, a merge key or a tag outside YAML's core schema. Fails
# when yq cannot read FILE.
tree_paths_odd() {
  local count
  count=$(yq -N '[.. | select(kind == "alias" or anchor != ""
      or ((tag | test("^!!(map|seq|str|int|float|bool|null|timestamp)$")) | not)
      or (kind == "map" and (((keys | length) != (keys | unique | length))
        or (keys | any_c((. == "<<") or ((tag | test("^!!(str|int|float|bool|null|timestamp)$")) | not))))))] | length' \
    "$1" 2>/dev/null) || return 2
  [[ -n ${count//[0$'\n']/} ]]
}

# path_refusal DIR ENTRY ROOT [SHOWN]: why ENTRY, a plain path kustomize reads from the directory
# DIR, is refused, or nothing when it names a path in ROOT, which it calls SHOWN, kubernetes/ unless
# given. Both DIR and ROOT are absolute, with no link in them.
path_refusal() {
  local -x LC_ALL=C
  local dir=$1 entry=$2 root=$3 shown=${4:-kubernetes/} resolved
  resolved=$(realpath -m -s -- "$dir/$entry" 2>/dev/null) || resolved=""
  if ! tree_paths_inside "$root" "$resolved"; then
    echo "a path that leaves $shown"
    return
  fi
  resolved=$(realpath -m -- "$dir/$entry" 2>/dev/null) || resolved=""
  tree_paths_inside "$root" "$resolved" || echo "a path that leaves $shown through a link"
}

# tree_paths_offline DIR: makes DIR the place the checks' builds run from, a second layer under the
# plain-path rule, and sets tree_paths_offline_env to their environment: DIR, first on the path,
# holds a git that refuses, which kustomize runs for a remote base (exec.LookPath("git"),
# api/internal/git/gitrunner.go), with git's own protocols and prompts off; HTTP_PROXY and
# HTTPS_PROXY, in both cases, name port 0 of the loopback, where nothing listens, which Go's HTTP
# client uses for a remote file on any host but the loopback, which it never proxies
# (http.ProxyFromEnvironment; api/internal/loader/fileloader.go); ALL_PROXY names it for git and
# libcurl, which read it, as Go does not; and NO_PROXY exempts no host.
tree_paths_offline() {
  local dir=$1 proxy=http://127.0.0.1:0
  mkdir -p "$dir"
  printf '%s\n' '#!/bin/sh' 'echo "git is not run by the checks: a build of the tree fetches nothing" >&2' 'exit 1' >"$dir/git"
  chmod +x "$dir/git"
  tree_paths_offline_env=("PATH=$dir:$PATH" "HTTP_PROXY=$proxy" "HTTPS_PROXY=$proxy" "ALL_PROXY=$proxy"
    "http_proxy=$proxy" "https_proxy=$proxy" "all_proxy=$proxy" "NO_PROXY=" "no_proxy="
    "GIT_ALLOW_PROTOCOL=" "GIT_TERMINAL_PROMPT=0" "GIT_CONFIG_NOSYSTEM=1" "GIT_CONFIG_GLOBAL=/dev/null")
}

# offline COMMAND...: runs COMMAND in tree_paths_offline_env, a shell function such as a wrapped tool
# included.
offline() {
  (
    export "${tree_paths_offline_env[@]}"
    "$@"
  )
}

# tree_paths_refused ROOT [NAME]: a line for each thing of the tree ROOT, an absolute path with no
# link in it whose last component is kubernetes, that the checks refuse; nothing when there is none.
# With NAME, ROOT may be any directory, an absolute path with no link in it, such as a source's
# checkout that kubernetes-validate builds; the lines call it NAME and name each file by its path
# below it.
tree_paths_refused() {
  local -x LC_ALL=C
  local root=$1 base shown=kubernetes/ link target file name dir odd tags json
  base=${root%/*}
  if (($# > 1)); then
    base=$root shown=$2
  fi
  while IFS= read -r -d '' link; do
    target=$(realpath -e -- "$link" 2>/dev/null) || target=""
    tree_paths_inside "$root" "$target" ||
      echo "$(tree_paths_show "${link#"$base"/}"): a link to $(tree_paths_show "$(readlink -- "$link")"), which is no path in $shown"
  done < <(find "$root" -type l -print0 | sort -z)

  while IFS= read -r -d '' file; do
    name=$(tree_paths_show "${file#"$base"/}")
    # A link that leads outside the tree is refused above, and not read.
    target=$(realpath -e -- "$file" 2>/dev/null) || target=""
    tree_paths_inside "$root" "$target" && [[ -f $target ]] || continue
    dir=${file%/*}
    tree_paths_odd "$file" && odd=0 || odd=$?
    if ((odd == 0)); then
      echo "$name: holds a key twice, an anchor, an alias, a merge key or a tag outside YAML's core schema, as kustomize's decoder may read them otherwise than the checks"
      continue
    elif ((odd == 2)); then
      echo "$name: cannot be read as YAML"
      continue
    fi
    # kustomize reads the first document; the checks read a file of one mapping, and empty documents.
    tags=$(yq -N 'tag' "$file" 2>/dev/null | grep -vx '!!null') || tags=""
    if [[ -z $tags ]]; then
      echo "$name: is empty: a kustomization is one mapping"
      continue
    elif [[ $tags != '!!map' ]]; then
      echo "$name: holds $(wc -l <<<"$tags") documents or one that is no mapping: a kustomization is one mapping"
      continue
    fi
    json=$(yq -o json -I0 'select(. != null)' "$file" 2>/dev/null) || { echo "$name: cannot be read as YAML"; continue; }
    tree_paths_walk "$tree_paths_kustomize" Kustomization kustomize "kustomize would read it as that field" \
      "is a field the checks refuse: a plugin configuration names files of its own, and neither Flux nor the checks inflate a Helm chart" \
      <<<"$json" | tree_paths_lines "$name: " "$dir" "$root" "$shown"
  done < <(find "$root" \( -name kustomization.yaml -o -name kustomization.yml -o -name Kustomization \) ! -type d -print0 | sort -z)
}

# root_path_refused KS ROOT: why the spec.path of KS, a cluster's root Kustomization, a path from
# the tree's parent, which is the working directory, is refused, or nothing when it is a directory
# of the tree ROOT as it resolves. A KS that leads outside the tree is refused by
# tree_paths_refused, and not read.
root_path_refused() {
  local -x LC_ALL=C
  local ks=$1 root=$2 path real
  real=$(realpath -e -- "$ks" 2>/dev/null) || real=""
  tree_paths_inside "$root" "$real" || return 0
  path=$(yq ea '[select(. != null)] | .[0].spec.path // "" | tostring' "$ks" 2>/dev/null) || return 0
  path="kubernetes/${path#./}"
  path=${path%/}
  if tree_paths_plain "$path" && [[ /$path/ != */../* && /$path/ != */./* ]]; then
    # The textual rules above are not enough: a link inside the tree may point outside it, whether
    # or not what it points to exists.
    real=$(realpath -m -- "$path" 2>/dev/null) || real=""
    if ! tree_paths_inside "$root" "$real" || [[ $real == "$root" ]]; then
      echo "$(tree_paths_show "$ks"): spec.path ${path#kubernetes/} leaves the tree through a link"
      return
    fi
    [[ ! -d $real ]] || return 0
  fi
  echo "$(tree_paths_show "$ks"): spec.path must be a plain path of a directory of the tree under kubernetes/, found $(tree_paths_show "${path#kubernetes/}")"
}

# kustomization_refused KS DIR ROOT: a line for each thing of the Flux Kustomization in the file KS
# that the checks refuse when they hand KS to flux build, which builds it from DIR, a directory of
# the tree ROOT: a key that folds to a field's name without being it, at any typed position, and an
# entry of spec.components that names no path of the tree, read from DIR, as flux build adds them to
# the kustomization it builds there. A file yq cannot read is never built: the checks read every
# Kustomization they build with yq.
kustomization_refused() {
  local -x LC_ALL=C
  local ks=$1 dir=$2 root=$3 json odd
  json=$(yq -o json -I0 'select(. != null)' "$ks" 2>/dev/null) || return 0
  tree_paths_odd "$ks" && odd=0 || odd=$?
  if ((odd == 0)); then
    echo "holds a key twice, an anchor, an alias, a merge key or a tag outside YAML's core schema, as flux build's decoder may read them otherwise than the checks"
    return
  fi
  tree_paths_walk "$tree_paths_flux" Kustomization "flux build" "flux build would read it as that field" \
    "is a field no Kustomization of the tree holds, which the checks refuse" \
    <<<"$json" | tree_paths_lines "" "$dir" "$root"
}

# read_refused TYPE: a line for each key of the JSON object on stdin, of TYPE in
# tree_paths_read_fields, that the checks refuse: one that folds to a field they read without being
# it, and at a type they hand a tool whole, any key that is not one of its fields.
read_refused() {
  local -x LC_ALL=C
  tree_paths_walk "$tree_paths_read" "$1" "kustomize, which the checks hand it to," \
    "the checks read that field alone, and the API server drops this spelling of it" "" | tree_paths_lines "" / /
}
