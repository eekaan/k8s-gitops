#!/bin/sh
# The escape canary's rights check (docs/kubernetes.md, The escape canary): makes, with the pod's own
# token, every attempt of the rows of the table CANARY_TABLE whose check is rights, in their order,
# and holds each result to the table's for the mode CANARY_MODE, audit or enforce. Each attempt is
# one request of the Flux CLI image's kubectl through the pod's in-cluster configuration, which
# verifies the API server's certificate against the CA mounted with the token: read-secret, the
# Secret cluster-secrets of flux-system; list-pods, the pods of every namespace. client-go takes the
# in-cluster configuration only while no flag or kubeconfig file changes its client configuration
# (tools/clientcmd/merged_client_builder.go), and --request-timeout is such a flag, which would send
# kubectl to http://localhost:8080, so busybox's timeout bounds each request instead, with KILL
# after 10 seconds. What kubectl writes is read and never printed: each attempt is one line naming
# it by its role, then a summary line. Exits 0 when every result is the table's, 1 when one is not,
# and 2, with the reason on standard error, for a mode it does not know, a table it cannot read or a
# row it cannot attempt. POSIX sh, as busybox's sh runs it.
set -u
check=rights
tab=$(printf '\t')

fail() {
  printf 'escape-canary %s error: %s\n' "$check" "$*" >&2
  exit 2
}

mode=${CANARY_MODE:-}
table=${CANARY_TABLE:-}
node=${NODE_NAME:-}
case $mode in
  audit | enforce) ;;
  *) fail "the mode '$mode' is neither audit nor enforce" ;;
esac
[ -n "$node" ] || fail "NODE_NAME is not set"
[ -n "$table" ] && [ -f "$table" ] && [ -r "$table" ] || fail "cannot read the table '$table'"

# request ARG...: the result of kubectl ARG...: allowed when it succeeds; forbidden when the API
# server refuses it, which kubectl prints as "Error from server (Forbidden)"; blocked when timeout
# ended it; anything else is other, which no row expects. The braces put the shell's own report of a
# command a signal ended, "Killed", with what is read, not on the log.
request() {
  out=$({ timeout -s KILL 10 kubectl "$@" </dev/null; } 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    result=allowed
  else
    case $out in
      *"(Forbidden)"*) result=forbidden ;;
      *) if [ "$status" -gt 128 ]; then result=blocked; else result=other; fi ;;
    esac
  fi
}

attempts=0
unexpected=0
while IFS=$tab read -r attempt row target port reach audit enforce reason; do
  case $attempt in
    '' | '#'*) continue ;;
  esac
  [ -n "$reason" ] || fail "the row '$attempt' has not eight fields"
  [ "$row" = "$check" ] || continue
  if [ "$mode" = audit ]; then expected=$audit; else expected=$enforce; fi
  case $expected in
    open | refused | blocked | unresolved | forbidden | allowed) ;;
    *) fail "the row '$attempt' expects a result this check does not know" ;;
  esac
  case $attempt in
    read-secret) request get secret cluster-secrets --namespace flux-system --output name ;;
    list-pods) request get pods --all-namespaces --output name ;;
    *) fail "the row '$attempt' is no attempt this check knows" ;;
  esac
  attempts=$((attempts + 1))
  if [ "$result" = "$expected" ]; then
    verdict=ok
  else
    verdict=UNEXPECTED
    unexpected=$((unexpected + 1))
  fi
  printf 'escape-canary %s mode=%s node=%s attempt=%s result=%s expected=%s %s\n' \
    "$check" "$mode" "$node" "$attempt" "$result" "$expected" "$verdict"
done <"$table"

[ "$attempts" -gt 0 ] || fail "the table holds no row of the $check check"
if [ "$unexpected" -eq 0 ]; then verdict=ok; else verdict=UNEXPECTED; fi
printf 'escape-canary %s mode=%s node=%s attempts=%s unexpected=%s %s\n' \
  "$check" "$mode" "$node" "$attempts" "$unexpected" "$verdict"
[ "$unexpected" -eq 0 ] || exit 1
