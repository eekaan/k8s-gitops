#!/bin/bash
# One run of the tree's Robot Framework suites, as the CronJob robot-suites runs it and so as just
# robot-run does (docs/kubernetes.md, Robot Framework). It takes only --variable NAME:VALUE pairs,
# the targets the CronJob hands it, so that no other option of Robot's, one that would turn off its
# status or select fewer tests, can reach it there; runs Robot over the suites with its output in a
# directory of the claim named after the UTC time it starts, the return code and the job's name
# beside it; keeps the newest KEEP_RUNS such directories, the one it made always among them; writes
# the index the report server shows; and exits with Robot's return code, the number of failed
# tests, or 1 when every test passed and a step after Robot failed. Each failure says which step it
# was.
set -uo pipefail

reports=${REPORTS_DIR:-/reports}
suites=${SUITES_DIR:-/mnt/robot/suites}
keep=${KEEP_RUNS:-30}
job=${JOB_NAME:-}
# The report server reads the claim as another user.
umask 022

say() {
  echo "run.sh: $*" >&2
}

pairs=()
while (($#)); do
  if [[ $1 != --variable || $# -lt 2 || ! $2 =~ ^[A-Z][A-Z0-9_]*: ]]; then
    say "takes only --variable NAME:VALUE pairs, NAME of capital letters, digits and _ from a letter; refused: $*"
    exit 2
  fi
  pairs+=(--variable "$2")
  shift 2
done
if [[ ! $keep =~ ^[1-9][0-9]{0,3}$ ]]; then
  say "KEEP_RUNS is not a whole number from 1 to 9999"
  exit 2
fi

# The directory is made, not reused: two runs never share one.
stamp=$(date -u +%Y-%m-%dT%H%M%SZ)
run="$reports/$stamp"
if ! mkdir -- "$run"; then
  say "failed while making the run's directory $run: it exists, or $reports cannot be written"
  exit 1
fi

# Robot runs in the background so that the SIGTERM the kubelet sends at the job's deadline reaches
# it: bash as the container's first process gets the signal. Robot interrupts the keyword it is in,
# or lets one that retries through every error run on to its timeout, and then writes its reports.
# The kubelet kills the pod 30 seconds after the signal; a run killed before the status below is
# written shows in the next run's index without a result.
robot --outputdir "$run" --consolecolors off --pythonpath "$suites/base" "${pairs[@]}" "$suites" &
pid=$!
stopped=0
trap 'stopped=1; kill -TERM "$pid" 2> /dev/null' TERM INT
rc=0
wait "$pid" || rc=$?
if ((stopped)); then
  rc=0
  wait "$pid" || rc=$?
fi
trap - TERM INT

failed=''
if ! printf '%s\n' "$rc" > "$run/status" || ! printf '%s\n' "$job" > "$run/job"; then
  say "failed while writing the run's status and job into $run"
  failed=1
fi

# The other runs, newest first: the names sort as the times they stand for. Nothing else in the
# claim is touched. The run just made is kept whatever its name sorts as, as after the clock stepped
# back, beside the newest KEEP_RUNS - 1 of the others.
others=()
for dir in "$reports"/*/; do
  name=${dir%/}
  name=${name##*/}
  [[ $name != "$stamp" && $name =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z$ ]] && others+=("$name")
done
if ((${#others[@]})); then
  mapfile -t others < <(printf '%s\n' "${others[@]}" | LC_ALL=C sort -r)
fi
for name in "${others[@]:keep-1}"; do
  if ! rm -rf -- "${reports:?}/$name"; then
    say "failed while removing the run $name, older than the newest $keep"
    failed=1
  fi
done
mapfile -t runs < <(printf '%s\n' "$stamp" "${others[@]:0:keep-1}" | LC_ALL=C sort -r)

# html TEXT: TEXT with the characters HTML gives a meaning escaped.
html() {
  local text=${1//&/&amp;}
  text=${text//</&lt;}
  text=${text//>/&gt;}
  printf '%s' "${text//\"/&quot;}"
}

# result CODE: the index's cell for Robot's return code, with what the user guide says a code of
# 251 and above means.
result() {
  case $1 in
    0) echo passed ;;
    250) echo '250 or more failed' ;;
    [1-9] | [1-9][0-9] | 1[0-9][0-9] | 2[0-4][0-9]) echo "$1 failed" ;;
    251) echo 'error 251<br>Help or version information printed.' ;;
    252) echo 'error 252<br>Invalid data or command line option.' ;;
    253) echo 'error 253<br>Execution stopped by user.' ;;
    255) echo 'error 255<br>Unexpected internal error.' ;;
    '') echo 'no result<br>The run is still going, or ended before Robot did.' ;;
    *) echo "error $(html "$1")<br>Not a return code of Robot Framework's: the script or the container ended it." ;;
  esac
}

# The index is written beside it and moved into place, so the server never serves half of one.
index="$reports/index.html"
if ! tmp=$(mktemp "$reports/.index.html.XXXXXX"); then
  say "failed while writing $index"
  failed=1
elif ! {
  cat << EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Robot Framework's runs</title>
</head>
<body>
<h1>Robot Framework's runs</h1>
<p>The newest $keep runs of the tree's suites, the newest first, at the UTC time each started.</p>
<table>
<tr><th>Started</th><th>Job</th><th>Result</th><th>Reports</th></tr>
EOF
  for name in "${runs[@]}"; do
    code=$(cat "$reports/$name/status" 2> /dev/null) || code=''
    ran=$(cat "$reports/$name/job" 2> /dev/null) || ran=''
    at="${name:0:10} ${name:11:2}:${name:13:2}:${name:15:2}"
    printf '<tr><td>%s</td><td>%s</td><td>%s</td><td><a href="%s/report.html">report</a> <a href="%s/log.html">log</a></td></tr>\n' \
      "$at" "$(html "$ran")" "$(result "$code")" "$name" "$name"
  done
  printf '</table>\n</body>\n</html>\n'
} > "$tmp" || ! chmod 0644 "$tmp" || ! mv -f -- "$tmp" "$index"; then
  rm -f -- "$tmp"
  say "failed while writing $index"
  failed=1
fi

if ((rc == 0)) && [[ -n $failed ]]; then
  exit 1
fi
exit "$rc"
