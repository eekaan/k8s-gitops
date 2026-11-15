#!/bin/bash
# Runs as root of a user namespace with network and mount namespaces of its own (unshare -r -n -m),
# from tests/edge-forward.bats: the edge's rendered rules in a network namespace of their own, with
# a client on the internet side, and on the node subnet a worker that holds the Gateway's address
# and the cloud's router, which counts every packet toward the Gateway that reaches it, and apart
# from them the packets that open a connection. Prints one NAME=VALUE line per reading.
# Usage: scenario.sh RULES, the edge's rendered nftables file
set -u
rules=$1
trap 'kill $(jobs -p) 2> /dev/null' EXIT

mount -t tmpfs none /run
mkdir -p /run/netns
for ns in edge client worker router subnet; do
  ip netns add "$ns"
  ip -n "$ns" link set lo up
done
# The client reaches the edge's own address straight, as the cloud's floating IP hands it on.
ip link add c0 netns client type veth peer name e0 netns edge
ip -n client addr add 198.51.100.10/24 dev c0
ip -n client link set c0 up
ip -n client route add 192.0.2.7/32 via 198.51.100.1
ip -n edge addr add 198.51.100.1/24 dev e0
ip -n edge link set e0 up
# The node subnet: a bridge in a namespace of its own joins the edge, the worker and the router.
ip -n subnet link add br0 type bridge
ip -n subnet link set br0 up
for peer in edge worker router; do
  ip link add "s-$peer" netns subnet type veth peer name "n-$peer" netns "$peer"
  ip -n subnet link set "s-$peer" master br0
  ip -n subnet link set "s-$peer" up
  ip -n "$peer" link set "n-$peer" up
done
ip -n edge addr add 192.0.2.7/24 dev n-edge
ip -n edge route add default via 192.0.2.1
ip -n worker addr add 192.0.2.20/24 dev n-worker
ip -n worker addr add 203.0.113.21/32 dev lo
ip -n router addr add 192.0.2.1/24 dev n-router
ip netns exec router nft -f - << 'NFT'
table ip count {
  counter toward_gateway {}
  counter opening_toward_gateway {}
  chain prerouting {
    type filter hook prerouting priority -300; policy accept;
    ip daddr 203.0.113.21 counter name toward_gateway
    ip daddr 203.0.113.21 tcp flags syn / syn,ack counter name opening_toward_gateway
  }
}
NFT
ip netns exec edge sysctl -qw net.ipv4.ip_forward=1
ip netns exec edge nft -f "$rules" || {
  echo "rules=refused"
  exit 1
}
echo "rules=loaded"

# router [COUNTER]: what reached the router toward the Gateway so far, every packet or, with
# opening_toward_gateway, those that open a connection.
router() {
  ip netns exec router nft list counter ip count "${1:-toward_gateway}" | sed -n 's/.*packets \([0-9]*\).*/\1/p'
}
# connect: a new connection from the client, a line sent and the answer printed, or nothing.
connect() {
  timeout 4 ip netns exec client socat -T 2 - TCP:192.0.2.7:80,connect-timeout=2 <<< "$1" 2> /dev/null
}

# The worker's /32, as FRR installs it, and a server on the Gateway's address that echoes each line.
ip -n edge route add 203.0.113.21/32 via 192.0.2.20
ip netns exec worker socat -T 30 TCP-LISTEN:80,bind=203.0.113.21,fork,reuseaddr EXEC:cat &
sleep 0.5

# An established connection through a worker.
coproc CLIENT { ip netns exec client socat -T 30 - TCP:192.0.2.7:80; }
echo one >&"${CLIENT[1]}"
reply=
read -t 3 -r reply <&"${CLIENT[0]}" || true
echo "reply_through_worker=$reply"
echo "router_through_worker=$(router)"

# FRR stops: zebra takes the worker's /32 out of the kernel, and the default route is left.
ip -n edge route del 203.0.113.21/32 via 192.0.2.20
before=$(router)
echo two >&"${CLIENT[1]}"
sleep 1.5
echo "router_established_default_only=$(($(router) - before))"

# A new connection with the default route only. The established one may still be resending, so
# what opens a connection is counted apart.
before=$(router opening_toward_gateway)
connect three > /dev/null
echo "router_new_default_only=$(($(router opening_toward_gateway) - before))"

# No route at all.
ip -n edge route del default
before=$(router opening_toward_gateway)
connect four > /dev/null
echo "router_new_no_route=$(($(router opening_toward_gateway) - before))"

# The routes back: a new connection through the worker answers again.
ip -n edge route add default via 192.0.2.1
ip -n edge route add 203.0.113.21/32 via 192.0.2.20
before=$(router)
echo "reply_route_back=$(connect five)"
echo "router_route_back=$(($(router) - before))"
