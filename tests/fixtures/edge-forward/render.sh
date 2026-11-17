#!/usr/bin/env bash
# Renders one local of the main.tf beside it, LOCAL, such as nftables_conf, into FILE, for
# tests/edge-forward.bats: tofu console evaluates base64encode(local.LOCAL), and what it prints is
# decoded. tofu console exits 0 when a local of the configuration cannot be evaluated, as when its
# template is absent: it says why on standard error, and on standard output it prints a warning
# that some expressions may produce unexpected results before the value, which is
# (known after apply) for the local that cannot be evaluated. So a render is tofu exiting 0 with one
# quoted base64 string, and nothing else, on standard output. Anything else fails here, non-zero,
# naming the local and showing what tofu printed on standard error, and leaves no FILE, not one an
# earlier render wrote either.
# Usage: render.sh LOCAL FILE
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
if (($# != 2)); then
  echo "usage: render.sh LOCAL FILE" >&2
  exit 2
fi
name=$1 file=$2
rm -f -- "$file"
errors=$(mktemp)
trap 'rm -f -- "$errors"' EXIT

status=0
printed=$(tofu -chdir="$here" console -no-color <<< "base64encode(local.$name)" 2> "$errors") || status=$?
# A quoted base64 string: groups of four of its characters, the last padded, and at least one.
quoted='^"([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{4}|[A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)"$'
if ((status != 0)) || [[ ! $printed =~ $quoted ]]; then
  echo "render.sh: tofu did not render local.$name as one quoted base64 string; what it printed on standard error:" >&2
  cat "$errors" >&2
  exit 1
fi
base64 -d <<< "${printed:1:-1}" > "$file"
