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
# must replace with the speaker's. Prints what FRR's dry run says of the edge's file, then what the
# edge and the first speaker report, as FRR's JSON, the first speaker's table and its view of the
# edge's capabilities included, in sections for scripts/edge-policy-assert.
# Usage: sh proof.sh DIR, the directory scripts/edge-policy-render wrote
set -eu
dir=$1
vty=/run/frr-proof
# Each daemon's vty socket is a file in a directory of its own.
mkdir -p "$vty/edge" "$vty/a" "$vty/b" "$vty/c" /etc/frr
: > /etc/frr/vtysh.conf

# FRR's own check of the edge's file as the edge holds it, the dry run of vtysh, which reads it as
# FRR does when it starts; and of a copy with a command FRR does not have, which it must refuse, or
# the check would prove nothing.
echo "== syntax"
if vtysh -C -f "$dir/edge.conf" > "$vty/syntax.out" 2>&1; then
  echo "the edge's file is accepted"
else
  echo "the edge's file is refused:"
  cat "$vty/syntax.out"
fi
{
  cat "$dir/edge.conf"
  echo "no-such-command"
} > "$vty/unknown.conf"
if vtysh -C -f "$vty/unknown.conf" > /dev/null 2>&1; then
  echo "a file with an unknown command is accepted"
else
  echo "a file with an unknown command is refused"
fi

# The edge's own file, unchanged but for what the BGP daemon started on its own does not know: the
# one line only vtysh reads, and the static route, which staticd installs (here there is no zebra).
# The speakers sit on loopback addresses, which FRR refuses as next hops (martians), so the copy also
# lets the daemon take them: the routing policy alone then decides what the table holds. A worker's
# address on the node subnet is no martian.
grep -v -e '^service integrated-vtysh-config$' -e '^ip route ' "$dir/edge.conf" |
  awk '{ print } /^router bgp / { print " bgp allow-martian-nexthop" }' > "$vty/edge.conf"
/usr/lib/frr/bgpd -d -S -Z -f "$vty/edge.conf" -i "$vty/edge.pid" --vty_socket "$vty/edge" -A 127.0.0.1 -l 127.0.0.1 2> /dev/null

# speaker NAME AS ADDRESS INSIDE PORT: a speaker that does not listen (-p 0), with its own vty socket.
speaker() {
  sed "s/@NAME@/$1/; s/@AS@/$2/; s/@ADDRESS@/$3/g; s|@INSIDE@|$4|" "$dir/speaker.conf.in" > "$vty/$1.conf"
  /usr/lib/frr/bgpd -d -S -Z -f "$vty/$1.conf" -i "$vty/$1.pid" --vty_socket "$vty/$1" -A 127.0.0.1 -P "$5" -p 0 2> /dev/null
}
speaker a 64496 127.0.0.20 203.0.113.17 2616
speaker b 64511 127.0.0.21 203.0.113.18 2617
speaker c 64496 127.0.0.3 203.0.113.18 2618

# Until the first speaker has offered everything, then a while more for the others' attempts.
tries=0
until vtysh --vty_socket "$vty/a" -d bgpd -c 'show bgp ipv4 unicast summary json' 2> /dev/null | grep -q '"pfxSnt":5'; do
  tries=$((tries + 1))
  [ "$tries" -le 30 ] || break
  sleep 1
done
sleep 5

section() {
  echo "== $1"
  shift
  vtysh --vty_socket "$vty/$1" -d bgpd -c "$2" 2> /dev/null
}
section sessions edge 'show bgp ipv4 unicast summary json'
section table edge 'show bgp ipv4 unicast json'
section advertised edge 'show bgp ipv4 unicast neighbors 127.0.0.20 advertised-routes json'
section offered a 'show bgp ipv4 unicast summary json'
section learned a 'show bgp ipv4 unicast json'
section capability a 'show bgp neighbors 127.0.0.1 json'
