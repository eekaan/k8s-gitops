# shellcheck shell=bash
# Shared by scripts/check-lock-entries: the repositories of the images the tree takes by a tag it
# derives at run time. dagger.lock must hold no entry for them, as the tag moves with something else
# and a digest pinned for it would be stale. An image of that kind is added here when the code that
# derives it is added, as scripts/rules-image derives the one just ci's module takes promtool from;
# an image with a pin of its own is not listed.
# shellcheck disable=SC2034 # read by the script that sources this file.
derived_images=(
  quay.io/prometheus/prometheus
)
