# shellcheck shell=bash
# The files the builds of a kubernetes/ tree read, bounded to the tree. flux build reads with
# kustomize's load restrictions off (LoadRestrictionsNone, its own setting), and so does
# scripts/kubernetes-check's kustomize, as an overlay lists ks.yaml files outside its own
# directory: either reads any path a kustomization names and follows any link, and kustomize
# fetches a remote source. scripts/render and scripts/kubernetes-check therefore refuse, before they
# build or read anything else of it, a tree in which
#   - a link resolves outside the tree, or to nothing: then nothing in the tree leads outside it
#     but the text of a path;
#   - a kustomization file (kustomization.yaml, kustomization.yml or Kustomization, a Component's
#     included) names, in a field that names files, a remote source (a URL, an scp-style address
#     or a github.com path, as kustomize reads one), an absolute path, or a path that leaves the
#     tree, read as text, as kustomize joins it to the file's directory, or with every link on it
#     resolved;
#   - a kustomization file sets a field that is not one of kustomization_fields by its exact name
#     (kustomize matches a field's name without regard to case), or one of those it refuses, or
#     holds YAML that kustomize's decoder may read otherwise than yq: a key twice, an anchor, an
#     alias, a merge key or a tag outside YAML's core schema;
#   - a cluster's root Kustomization's spec.path is not a directory of the tree as it resolves.
# Every kustomization file the builds read is one of the tree's, so the checks read each of them,
# used or not. A Flux Kustomization's spec.components is checked as it is built (components_refused).
#
# Each refusal is one line, FILE: what is refused, FILE a path from the tree's parent; a value from
# the tree has every control character read as '?'.

# The fields of kustomize's Kustomization type, and of the types it holds whose fields name files,
# by the names kustomize reads them under, with what each holds: path, a file or directory, or a
# list of them, that kustomize reads or fetches; files, a list of KEY=FILE or FILE; none, nothing
# kustomize reads; refused, a field the checks refuse (generators, transformers and validators name
# plugin configurations, whose fields name files of their own, and neither Flux nor the checks
# inflate a Helm chart); an object, the fields of a map; a list of one object, those of each entry
# of a list. tests/fixtures/kustomization-fields lists the same fields from kustomize's own types,
# at the versions the pinned flux and kustomize build with.
tree_paths_generator='{"name": "none", "namespace": "none", "behavior": "none", "literals": "none",
  "files": "files", "envs": "path", "env": "path", "options": "none"}'
tree_paths_patch='{"path": "path", "patch": "none", "target": "none", "options": "none"}'
tree_paths_spec='{
  "apiVersion": "none", "kind": "none", "metadata": "none",
  "openapi": {"path": "path", "version": "none"},
  "namePrefix": "none", "nameSuffix": "none", "namespace": "none",
  "commonLabels": "none", "labels": "none", "commonAnnotations": "none",
  "patchesStrategicMerge": "path",
  "patchesJson6902": ['"$tree_paths_patch"'], "patches": ['"$tree_paths_patch"'],
  "images": "none", "imageTags": "none",
  "replacements": [{"path": "path", "source": "none", "targets": "none", "sourceValue": "none"}],
  "replicas": "none", "vars": "none", "sortOptions": "none",
  "resources": "path", "components": "path", "crds": "path", "bases": "path",
  "configMapGenerator": ['"$tree_paths_generator"'],
  "secretGenerator": ['"${tree_paths_generator%\}}"', "type": "none"}],
  "helmGlobals": "refused", "helmCharts": "refused", "helmChartInflationGenerator": "refused",
  "generatorOptions": "none", "configurations": "path",
  "generators": "refused", "transformers": "refused", "validators": "refused",
  "buildMetadata": "none"
}'

# kustomization_fields: one line FIELD CLASS for each field tree_paths_spec knows, an entry of a list
# as FIELD[], files as path, as tests/fixtures/kustomization-fields lists them.
kustomization_fields() {
  jq -rn --argjson spec "$tree_paths_spec" '
    def class: if . == "files" then "path" else . end;
    $spec | to_entries[] | .key as $k | .value as $v
    | if ($v | type) == "string" then "\($k) \($v | class)"
      elif ($v | type) == "object" then $v | to_entries[] | "\($k).\(.key) \(.value | class)"
      else $v[0] | to_entries[] | "\($k)[].\(.key) \(.value | class)" end'
}

# tree_paths_clean TEXT: TEXT with every control character read as '?'.
tree_paths_clean() {
  printf '%s' "${1//[[:cntrl:]]/?}"
}

# tree_paths_inside ROOT PATH: whether PATH is ROOT or below it.
tree_paths_inside() {
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

# path_refusal DIR ENTRY ROOT: why ENTRY, a path kustomize reads from the directory DIR, is refused,
# or nothing when it names a path in ROOT. Both DIR and ROOT are absolute, with no link in them. A
# remote source is what kustomize fetches, as a file (a URL whose scheme is http or https) or as a
# repository (after an optional git::, a URL whose scheme is ssh, https, http or file, an
# scp-style user@host, or a github.com path), whichever the field reads it as.
path_refusal() {
  local dir=$1 entry=$2 root=$3 source resolved
  source=${entry,,}
  source=${source#git::}
  if [[ $source =~ ^(https?|ssh|file): || $source =~ ^[a-z][a-z0-9-]*@ || $source =~ ^github\.com[/:] ]]; then
    echo "a remote source, which the checks do not fetch"
  elif [[ $entry == /* ]]; then
    echo "an absolute path"
  else
    resolved=$(realpath -m -s -- "$dir/$entry" 2>/dev/null) || resolved=""
    if ! tree_paths_inside "$root" "$resolved"; then
      echo "a path that leaves kubernetes/"
      return
    fi
    resolved=$(realpath -m -- "$dir/$entry" 2>/dev/null) || resolved=""
    tree_paths_inside "$root" "$resolved" || echo "a path that leaves kubernetes/ through a link"
  fi
}

# tree_paths_refused ROOT: a line for each thing of the tree ROOT, an absolute path with no link in
# it whose last component is kubernetes, that the checks refuse; nothing when there is none.
tree_paths_refused() {
  local root=$1 base link target file name dir odd json kind where entry path reason
  base=${root%/*}
  while IFS= read -r -d '' link; do
    target=$(realpath -e -- "$link" 2>/dev/null) || target=""
    tree_paths_inside "$root" "$target" ||
      echo "$(tree_paths_clean "${link#"$base"/}"): a link to $(tree_paths_clean "$(readlink -- "$link")"), which is no path in kubernetes/"
  done < <(find "$root" -type l -print0 | sort -z)

  while IFS= read -r -d '' file; do
    name=$(tree_paths_clean "${file#"$base"/}")
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
    if ! json=$(yq -o json -I0 'select(. != null)' "$file" 2>/dev/null); then
      echo "$name: cannot be read as YAML"
      continue
    fi
    # A value or key that holds a NUL character, which no path does, would end a record early.
    if ! jq -e -s 'all(.[] | [.. | strings, (objects | keys[])][]; contains("\u0000") | not)' <<<"$json" >/dev/null 2>&1; then
      echo "$name: holds a NUL character"
      continue
    fi
    # Each field, by its exact name: a path it names as one record of four NUL-ended values, path,
    # where it is, the entry and the path the entry names; a field the checks refuse as field, where
    # it is, why and an empty value. jq writes each record whole, so one that fails leaves no part of
    # a record behind, and the record after it says so.
    while IFS= read -r -d '' kind && IFS= read -r -d '' where && IFS= read -r -d '' entry && IFS= read -r -d '' path; do
      where=$(tree_paths_clean "$where")
      case $kind in
        field) echo "$name: $where $entry" ;;
        path)
          reason=$(path_refusal "$dir" "$path" "$root")
          [[ -z $reason ]] || echo "$name: $where names \"$(tree_paths_clean "$entry")\", $reason"
          ;;
        *) echo "$name: cannot be read as a kustomization" ;;
      esac
    done < <(jq -j --argjson spec "$tree_paths_spec" '
      def record: map(tostring + "\u0000") | add;
      def leaf($class; $where):
        if $class == "none" then empty
        elif $class == "refused" then
          ["field", $where, "is a field the checks refuse: a plugin configuration names files of its own, and neither Flux nor the checks inflate a Helm chart", ""]
        else (if type == "array" then .[] else . end) | select(type == "string" or type == "number") | tostring
          | [., (if $class == "files" and test("=") then sub("^[^=]*="; "") else . end)] as [$entry, $path]
          | ["path", $where, $entry, $path]
        end;
      def fields($spec; $where):
        to_entries[] | .key as $k | .value as $v | ($where + (if $where == "" then "" else "." end) + $k) as $w
        | if ($spec | has($k) | not) then
            ["field", $w, "is not a field the checks know: they read the exact names of kustomize'"'"'s fields alone", ""]
          elif ($spec[$k] | type) == "string" then $v | leaf($spec[$k]; $w)
          elif ($spec[$k] | type) == "object" then $v | select(type == "object") | fields($spec[$k]; $w)
          else $v | select(type == "array") | to_entries[] | .key as $i | .value | select(type == "object")
            | fields($spec[$k][0]; "\($w)[\($i)]")
          end;
      select(type == "object") | fields($spec; "") | record' <<<"$json" 2>/dev/null ||
      printf '%s\0' field "" "cannot be read as a kustomization" "")
  done < <(find "$root" \( -name kustomization.yaml -o -name kustomization.yml -o -name Kustomization \) ! -type d -print0 | sort -z)
}

# root_path_refused KS ROOT: why the spec.path of KS, a cluster's root Kustomization, a path from
# the tree's parent, which is the working directory, is refused, or nothing when it is a directory
# of the tree ROOT as it resolves. A KS that leads outside the tree is refused by
# tree_paths_refused, and not read.
root_path_refused() {
  local ks=$1 root=$2 path real
  real=$(realpath -e -- "$ks" 2>/dev/null) || real=""
  tree_paths_inside "$root" "$real" || return 0
  path=$(yq ea '[select(. != null)] | .[0].spec.path // "" | tostring' "$ks" 2>/dev/null) || return 0
  path="kubernetes/${path#./}"
  path=${path%/}
  if [[ $path =~ ^kubernetes(/[A-Za-z0-9._-]+)+$ && /$path/ != */../* && /$path/ != */./* ]]; then
    # The textual rules above are not enough: a link inside the tree may point outside it, whether
    # or not what it points to exists.
    real=$(realpath -m -- "$path" 2>/dev/null) || real=""
    if ! tree_paths_inside "$root" "$real" || [[ $real == "$root" ]]; then
      echo "$(tree_paths_clean "$ks"): spec.path ${path#kubernetes/} leaves the tree through a link"
      return
    fi
    [[ ! -d $real ]] || return 0
  fi
  echo "$(tree_paths_clean "$ks"): spec.path must be a directory of the tree under kubernetes/, found $(tree_paths_clean "${path#kubernetes/}")"
}

# components_refused KS DIR ROOT: a line for each entry of spec.components of the Flux
# Kustomization in the file KS that names no path of the tree ROOT, read from DIR, the directory
# the Kustomization is built from, as flux build adds them to the kustomization it builds there.
components_refused() {
  local ks=$1 dir=$2 root=$3 json entry reason odd
  # A file yq cannot read is never built: the checks read every Kustomization they build with yq.
  json=$(yq -o json -I0 'select(. != null)' "$ks" 2>/dev/null) || return 0
  tree_paths_odd "$ks" && odd=0 || odd=$?
  if ((odd == 0)); then
    echo "holds a key twice, an anchor, an alias, a merge key or a tag outside YAML's core schema, as Flux's decoder may read them otherwise than the checks"
    return
  fi
  if ! jq -e -s 'all(.[] | .spec.components // []; type == "array" and all(.[]; type == "string" and (contains("\u0000") | not)))' \
    <<<"$json" >/dev/null 2>&1; then
    echo "spec.components is not a list of paths"
    return
  fi
  while IFS= read -r -d '' entry; do
    reason=$(path_refusal "$dir" "$entry" "$root")
    [[ -z $reason ]] || echo "spec.components names \"$(tree_paths_clean "$entry")\", $reason"
  done < <(jq -j '(.spec.components // [])[] | . + "\u0000"' <<<"$json")
}
