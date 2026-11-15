#!/bin/sh
# Runs in the FRR image, in a container that has no capabilities beyond the container runtime's
# defaults and whose speakers bind and dial loopback addresses only (edge-policy-check gives it no
# other network; the Dagger module's exec has the engine's default one). Starts the edge's BGP
# daemon with the configuration the edge stack renders, and three speakers that open sessions to it,
# with no routing table of their own to install into (-Z). Each speaker offers five prefixes: one
# /32 inside the service range, one outside it, a /30 and the /28 range itself, and a default route.
#   a  the cluster's AS, from a worker's address: accepted
#   b  another AS, from a worker's address: refused by the peer group's remote AS
#   c  the cluster's AS, from an address of the node subnet outside the workers' block, as a control
#      plane's, the CI host's or the other edge's: not a dynamic neighbour
# Each speaker announces its prefixes with a next hop that is not its own address, which the edge
# must replace with the speaker's. Prints, in sections for scripts/edge-policy-assert: what FRR's dry
# run says of the edge's file; each wait for a state of the sessions, met or not, with what was last
# seen; whether each daemon still runs then, with its own log when it does not; and what the edge
# and the first speaker report, as FRR's JSON, the first speaker's table and its view of the edge's
# capabilities included. It runs to its end whatever it finds and exits 0 once it has printed it all: the checks
# are scripts/edge-policy-assert's, so a failure says which.
# Usage: sh proof.sh DIR, the directory scripts/edge-policy-render wrote
set -u
# The conditions and what they show run through wait_for, by name.
# shellcheck disable=SC2329
dir=$1
vty=/run/frr-proof
# Each daemon's vty socket is a file in a directory of its own.
mkdir -p "$vty/edge" "$vty/a" "$vty/b" "$vty/c"
# vtysh reads its own file from the proof's directory: /etc/frr is the image's frr user's.
: > "$vty/vtysh.conf"
: > "$vty/waits"

# FRR's own check of the edge's file as the edge holds it, the dry run of vtysh, which reads it as
# FRR does when it starts; and of a copy with a command FRR does not have, which it must refuse, or
# the check would prove nothing.
echo "== syntax"
if vtysh --config_dir "$vty" -C -f "$dir/edge.conf" > "$vty/syntax.out" 2>&1; then
  echo "the edge's file is accepted"
else
  echo "the edge's file is refused:"
  cat "$vty/syntax.out"
fi
{
  cat "$dir/edge.conf"
  echo "no-such-command"
} > "$vty/unknown.conf"
if vtysh --config_dir "$vty" -C -f "$vty/unknown.conf" > /dev/null 2>&1; then
  echo "a file with an unknown command is accepted"
else
  echo "a file with an unknown command is refused"
fi

# bgpd NAME ARG...: starts a BGP daemon as NAME, with its own vty socket, its log in a file of its
# own and what it prints on starting kept beside it.
bgpd() {
  name=$1
  shift
  /usr/lib/frr/bgpd -d -S -Z -i "$vty/$name.pid" --vty_socket "$vty/$name" --log "file:$vty/$name.log" \
    --log-level informational "$@" > "$vty/$name.start" 2>&1 ||
    echo "bgpd exited with status $? as it started" >> "$vty/$name.start"
}

# The edge's own file, unchanged but for what the BGP daemon started on its own does not know: the
# one line only vtysh reads, and the static route, which staticd installs (here there is no zebra).
# The speakers sit on loopback addresses, which FRR refuses as next hops (martians), so the copy also
# lets the daemon take them: the routing policy alone then decides what the table holds. A worker's
# address on the node subnet is no martian.
grep -v -e '^service integrated-vtysh-config$' -e '^ip route ' "$dir/edge.conf" |
  awk '{ print } /^router bgp / { print " bgp allow-martian-nexthop" }' > "$vty/edge.conf"
bgpd edge -f "$vty/edge.conf" -A 127.0.0.1 -l 127.0.0.1

# speaker NAME AS ADDRESS INSIDE PORT: a speaker that does not listen (-p 0).
speaker() {
  sed "s/@NAME@/$1/; s/@AS@/$2/; s/@ADDRESS@/$3/g; s|@INSIDE@|$4|" "$dir/speaker.conf.in" > "$vty/$1.conf"
  bgpd "$1" -f "$vty/$1.conf" -A 127.0.0.1 -P "$5" -p 0
}
speaker a 64496 127.0.0.20 203.0.113.17 2616
speaker b 64511 127.0.0.21 203.0.113.18 2617
speaker c 64496 127.0.0.3 203.0.113.18 2618

# ask NAME COMMAND: what daemon NAME answers to COMMAND, or nothing.
ask() {
  vtysh --config_dir "$vty" --vty_socket "$vty/$1" -d bgpd -c "$2" 2> /dev/null
}
# holds EXPRESSION: whether the Python expression EXPRESSION holds of the JSON on standard input, j.
holds() {
  python3 -c 'import json, sys; j = json.load(sys.stdin); sys.exit(0 if eval(sys.argv[1]) else 1)' "$1" 2> /dev/null
}
# shows EXPRESSION: the Python expression EXPRESSION of the JSON on standard input, j, or nothing.
shows() {
  python3 -c 'import json, sys; j = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1" 2> /dev/null || echo nothing
}
# wait_for BOUND DESCRIPTION CONDITION SEEN: runs the function CONDITION once a second until it
# holds or BOUND seconds have passed, and records under == waits that DESCRIPTION was met and after
# how long, or that it was not, with what the function SEEN printed last.
wait_for() {
  started=$(date +%s)
  while :; do
    if "$3"; then
      echo "met: $2, after $(($(date +%s) - started)) s" >> "$vty/waits"
      return 0
    fi
    if [ $(($(date +%s) - started)) -ge "$1" ]; then
      echo "not met: $2, after $1 s; last seen: $("$4")" >> "$vty/waits"
      return 1
    fi
    sleep 1
  done
}
# running NAME: whether daemon NAME's process is alive.
running() {
  [ -s "$vty/$1.pid" ] && kill -0 "$(cat "$vty/$1.pid")" 2> /dev/null
}

# The conditions the waits poll, and what each shows of the state it reads.
all_answer() {
  for name in edge a b c; do
    ask "$name" 'show bgp summary json' | holds True || return 1
  done
}
silent() {
  for name in edge a b c; do
    ask "$name" 'show bgp summary json' | holds True || printf '%s ' "$name"
  done
  echo "do not answer"
}
a_offers() {
  ask a 'show bgp ipv4 unicast summary json' |
    holds 'j["peers"]["127.0.0.1"]["state"] == "Established" and j["peers"]["127.0.0.1"]["pfxSnt"] == 5'
}
a_seen() {
  ask a 'show bgp ipv4 unicast summary json' |
    shows '"state %s, pfxSnt %s" % (j["peers"]["127.0.0.1"].get("state"), j["peers"]["127.0.0.1"].get("pfxSnt"))'
}
edge_accepts() {
  ask edge 'show bgp ipv4 unicast summary json' | holds 'j["peers"]["127.0.0.20"]["pfxRcd"] >= 1'
}
edge_seen() {
  ask edge 'show bgp ipv4 unicast summary json' |
    shows '"; ".join("%s %s, pfxRcd %s" % (p, v.get("state"), v.get("pfxRcd")) for p, v in j.get("peers", {}).items()) or "no peers"'
}
b_refused() {
  ask b 'show bgp neighbors 127.0.0.1 json' | holds 'j["127.0.0.1"]["lastErrorCodeSubcode"] == "0202"'
}
b_seen() {
  ask b 'show bgp neighbors 127.0.0.1 json' |
    shows '"state %s, last reset %s" % (j["127.0.0.1"].get("bgpState"), j["127.0.0.1"].get("lastResetDueTo"))'
}
c_refused() {
  ask c 'show bgp neighbors 127.0.0.1 json' |
    holds 'j["127.0.0.1"]["messageStats"]["opensSent"] >= 1 and j["127.0.0.1"]["connectionsEstablished"] == 0'
}
c_seen() {
  ask c 'show bgp neighbors 127.0.0.1 json' |
    shows '"state %s, opens sent %s" % (j["127.0.0.1"].get("bgpState"), j["127.0.0.1"].get("messageStats", {}).get("opensSent"))'
}

# The daemons start in the background: each must answer before anything is read of it.
if wait_for 30 "every daemon answers" all_answer silent; then
  daemons=up
else
  daemons=down
fi
# Each state the checks read, polled for until it holds: the accepted speaker's session and its
# prefixes, and each refused speaker's refusal, as the speakers try again every second.
if [ "$daemons" = up ]; then
  wait_for 120 "the speaker in the cluster's AS has its session established and has offered its five prefixes" a_offers a_seen
  wait_for 60 "the edge has accepted a prefix from it" edge_accepts edge_seen
  wait_for 60 "the speaker in another AS has been refused for its AS" b_refused b_seen
  wait_for 60 "the speaker outside the workers' block has reached the edge and not been taken" c_refused c_seen
else
  echo "not tried: the sessions' states, as a daemon does not answer" >> "$vty/waits"
fi
echo "== waits"
cat "$vty/waits"
# Whether each daemon still runs once the waits are over, with its own log when it does not.
echo "== daemons"
for name in edge a b c; do
  if running "$name"; then
    echo "$name: running"
  else
    echo "$name: not running; what it printed and logged:"
    cat "$vty/$name.start" "$vty/$name.log" 2> /dev/null | tail -n 30
  fi
done

section() {
  echo "== $1"
  shift
  ask "$@"
}
section sessions edge 'show bgp ipv4 unicast summary json'
section table edge 'show bgp ipv4 unicast json'
section advertised edge 'show bgp ipv4 unicast neighbors 127.0.0.20 advertised-routes json'
section offered a 'show bgp ipv4 unicast summary json'
section learned a 'show bgp ipv4 unicast json'
section capability a 'show bgp neighbors 127.0.0.1 json'
echo "== proof"
echo "ran to its end"
exit 0
