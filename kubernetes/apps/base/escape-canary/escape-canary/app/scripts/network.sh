#!/bin/sh
# The escape canary's network check (docs/kubernetes.md, The escape canary): makes, from this pod,
# every attempt of the rows of the table CANARY_TABLE whose check is network, in their order, and
# holds each result to the table's for the mode CANARY_MODE, audit or enforce. A TCP attempt is
# busybox's nc -z, which completes the handshake and sends nothing, its connect bounded by its own 3
# seconds and the lookup of a name before it by the resolver's timeouts alone; the resolver attempt
# asks the pod's resolver for the name under timeout's 5 seconds. A target node is the node
# the pod runs on, NODE_IP. The tools' messages name addresses, so they are read and never printed:
# each attempt is one line naming it by its role, then a summary line. Exits 0 when every result is
# the table's, 1 when one is not, and 2, with the reason on standard error, for a mode it does not
# know, a table it cannot read or a row it cannot attempt. POSIX sh, as busybox's sh runs it.
set -u
check=network
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

# connect HOST PORT: the result of a TCP connection to HOST on PORT, from nc's status and messages
# (networking/nc_bloaty.c of busybox 1.38.0): "open" once connected; a refusal; "Connection timed
# out" when the 3 seconds end first; "bad address" for a name that does not resolve; anything else is
# other, which no row expects.
connect() {
  out=$(nc -z -v -v -w 3 "$1" "$2" </dev/null 2>&1)
  status=$?
  case $out in
    *") open"*) if [ "$status" -eq 0 ]; then result=open; else result=other; fi ;;
    *"Connection refused"*) result=refused ;;
    *"Connection timed out"*) result=blocked ;;
    *"bad address"*) result=unresolved ;;
    *) result=other ;;
  esac
}

# lookup NAME: the result of asking the pod's resolver for NAME (networking/nslookup.c of busybox
# 1.38.0): open for an answer with an address, unresolved for an answer without one, refused, and
# blocked when no answer comes within nslookup's 5 seconds or timeout ends it. The braces put the
# shell's own report of a command a signal ended, "Terminated", with what is read, not on the log.
lookup() {
  out=$({ timeout 5 nslookup "$1" </dev/null; } 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    case $out in
      *"Name:"*) result=open ;;
      *) result=unresolved ;;
    esac
    return
  fi
  case $out in
    *"server can't find"*) result=unresolved ;;
    *"Connection refused"*) result=refused ;;
    *"connection timed out"*) result=blocked ;;
    *) if [ "$status" -gt 128 ]; then result=blocked; else result=other; fi ;;
  esac
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
  case $port in
    53/udp)
      lookup "$target"
      ;;
    */tcp)
      number=${port%/tcp}
      case $number in
        '' | *[!0-9]*) fail "the row '$attempt' names no port number" ;;
      esac
      host=$target
      if [ "$target" = node ]; then
        host=${NODE_IP:-}
        case $host in
          '' | *[!0-9.]*) fail "the row '$attempt' attempts the node, and NODE_IP is no address" ;;
        esac
      fi
      connect "$host" "$number"
      ;;
    *)
      fail "the row '$attempt' asks for $port, which this check cannot attempt"
      ;;
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
