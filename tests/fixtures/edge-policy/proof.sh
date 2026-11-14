#!/bin/sh
# Runs in the FRR image, in a container that has no capabilities beyond the container runtime's
# defaults and whose speakers bind and dial loopback addresses only (edge-policy-check gives it no
# other network; the Dagger module's exec has the engine's default one). Starts the edge's BGP
# daemon with the configuration the edge stack renders, and three speakers that open sessions to it,
# with no routing table of their own to install into (-Z). Each speaker offers five prefixes: one
# /32 inside the service range, one outside it, a /30 and the /28 range itself, and a default route.
#   a  the cluster's AS, from an address inside the edge's listen range: accepted
#   b  another AS, from an address inside the range: refused by the peer group's remote AS
#   c  the cluster's AS, from an address outside the range: not a dynamic neighbour
# Prints what the edge and the first speaker report, as FRR's JSON, the first speaker's table
# included, in sections for scripts/edge-policy-assert.
# Usage: sh proof.sh DIR, the directory scripts/edge-policy-render wrote
set -eu
dir=$1
vty=/run/frr-proof
# Each daemon's vty socket is a file in a directory of its own.
mkdir -p "$vty/edge" "$vty/a" "$vty/b" "$vty/c" /etc/frr
: > /etc/frr/vtysh.conf

# The edge's own file, unchanged but for what the BGP daemon started on its own does not know: the
# one line only vtysh reads, and the static route, which staticd installs (here there is no zebra).
grep -v -e '^service integrated-vtysh-config$' -e '^ip route ' "$dir/edge.conf" > "$vty/edge.conf"
/usr/lib/frr/bgpd -C -Z -S -f "$vty/edge.conf" 2> /dev/null
/usr/lib/frr/bgpd -d -S -Z -f "$vty/edge.conf" -i "$vty/edge.pid" --vty_socket "$vty/edge" -A 127.0.0.1 -l 127.0.0.1 2> /dev/null

# speaker NAME AS ADDRESS INSIDE PORT: a speaker that does not listen (-p 0), with its own vty socket.
speaker() {
  sed "s/@NAME@/$1/; s/@AS@/$2/; s/@ADDRESS@/$3/g; s|@INSIDE@|$4|" "$dir/speaker.conf.in" > "$vty/$1.conf"
  /usr/lib/frr/bgpd -d -S -Z -f "$vty/$1.conf" -i "$vty/$1.pid" --vty_socket "$vty/$1" -A 127.0.0.1 -P "$5" -p 0 2> /dev/null
}
speaker a 64496 127.0.0.2 203.0.113.17 2616
speaker b 64511 127.0.0.3 203.0.113.18 2617
speaker c 64496 127.0.1.1 203.0.113.18 2618

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
section advertised edge 'show bgp ipv4 unicast neighbors 127.0.0.2 advertised-routes json'
section offered a 'show bgp ipv4 unicast summary json'
section learned a 'show bgp ipv4 unicast json'
