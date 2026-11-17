# A copy of the repository's kubernetes/ tree whose lab-sto2 overlay leaves entries out, for the
# tests of what a cluster builds, or is refused, without an application or a namespace. Loaded with
# `load fixtures/tree-without` from a test file.
#
# tree_without ENTRY...: copies kubernetes/ to $TREE, $BATS_TEST_TMPDIR/tree, made anew at every
# call, and takes each ENTRY out of the overlay's resources: NAME or ks:NAME is the ks.yaml of the
# application NAME, and ns:NAME the namespace directory NAME under apps/base/. A name reaches yq
# through the environment, never as part of the expression. The ks.yaml entries are matched by a
# regular expression with NAME in it, so a NAME holding `.` or another such character can match
# more than one application; ns:NAME is compared with the whole entry.
tree_without() {
  local entry root overlay
  root=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  TREE="${BATS_TEST_TMPDIR:?}/tree"
  rm -rf "$TREE"
  mkdir -p "$TREE"
  cp -r "$root/kubernetes" "$TREE/kubernetes"
  overlay="$TREE/kubernetes/apps/overlays/lab-sto2/kustomization.yaml"
  for entry in "$@"; do
    case $entry in
      ns:*) ENTRY="${entry#ns:}" yq -i '.resources |= map(select(. != "../../base/" + strenv(ENTRY)))' "$overlay" ;;
      *) ENTRY="${entry#ks:}" yq -i '.resources |= map(select(test("/" + strenv(ENTRY) + "/ks.yaml$") | not))' "$overlay" ;;
    esac
  done
}
