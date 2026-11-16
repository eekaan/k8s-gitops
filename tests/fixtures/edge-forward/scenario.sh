#!/bin/bash
# Runs as root of a user namespace with network and mount namespaces of its own (unshare -r -n -m),
# from tests/edge-forward.bats: the edge's rendered rules and proxy in a network namespace of their
# own, with a client on the internet side, and on the node subnet a worker that holds the Gateway's
# address, whose server records the PROXY protocol header each connection starts with, and the
# cloud's router, which counts every packet toward the Gateway that reaches it, and apart from them
# the packets that open a connection. Prints one NAME=VALUE line per reading.
# Usage: scenario.sh MODE RULES PROXY, MODE proxy or routes; RULES the edge's rendered nftables
# file, PROXY its rendered proxy configuration
set -u
mode=$1 rules=$2 proxy=$3
here=$(dirname "$(readlink -f "$0")")
trap 'kill $(jobs -p) 2> /dev/null' EXIT

mount -t tmpfs none /run
mkdir -p /run/netns
for ns in edge client worker router subnet; do
  ip netns add "$ns"
  ip -n "$ns" link set lo up
done
# The client reaches the edge's own address straight, as the cloud's floating IP hands it on, and
# the Gateway's address through the edge, which is not a route the internet has: the edge must not
# forward what comes that way.
ip link add c0 netns client type veth peer name e0 netns edge
ip -n client addr add 198.51.100.10/24 dev c0
ip -n client link set c0 up
ip -n client route add 192.0.2.7/32 via 198.51.100.1
ip -n client route add 203.0.113.21/32 via 198.51.100.1
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
# What reaches the worker from the client's address, which only a forwarded packet does.
ip netns exec worker nft -f - << 'NFT'
table ip count {
  counter from_client {}
  chain prerouting {
    type filter hook prerouting priority -300; policy accept;
    ip saddr 198.51.100.10 counter name from_client
  }
}
NFT
# Forwarding is on in the kernel, as the edge's settings have it: the rules decide what is forwarded.
ip netns exec edge sysctl -qw net.ipv4.ip_forward=1
ip netns exec edge nft -f "$rules" || {
  echo "rules=refused"
  exit 1
}
echo "rules=loaded"

export BACKEND_LOG=/run/backend.log
: > "$BACKEND_LOG"
# The edge's proxy, the master and its worker as the unit starts it, in the foreground; its log is
# what it prints.
ip netns exec edge haproxy -W -db -f "$proxy" > /run/proxy.log 2>&1 &
proxy_pid=$!
for _ in $(seq 50); do
  [[ -n $(ip netns exec edge ss -H -ltn 'sport = :80') ]] && break
  sleep 0.1
done
if [[ -n $(ip netns exec edge ss -H -ltn 'sport = :80') ]]; then
  echo "proxy=listening"
else
  echo "proxy=not listening"
  cat /run/proxy.log
  exit 1
fi

# router [COUNTER]: what reached the router toward the Gateway so far, every packet or, with
# opening_toward_gateway, those that open a connection.
router() {
  ip netns exec router nft list counter ip count "${1:-toward_gateway}" | sed -n 's/.*packets \([0-9]*\).*/\1/p'
}
# connect WORD [ADDRESS [PORT [SOURCE_PORT]]]: a new connection from the client, a line sent and the
# answer printed, or nothing.
connect() {
  local source=
  [[ -z ${4-} ]] || source=",sourceport=$4"
  timeout 6 ip netns exec client socat -T 2 - "TCP:${2:-192.0.2.7}:${3:-80},connect-timeout=2$source" <<< "$1" 2> /dev/null
}

# The worker's /32, as FRR installs it, and a server on the Gateway's address that records the
# header and echoes each line.
ip -n edge route add 203.0.113.21/32 via 192.0.2.20
ip netns exec worker socat -T 30 TCP-LISTEN:80,bind=203.0.113.21,fork,reuseaddr EXEC:"bash $here/backend.sh" &
sleep 0.5

case $mode in
  proxy)
    # A client's connection to a public port, from a port of its own choosing: answered, and the
    # server on the Gateway's address was sent the client's address and port in the header, and
    # was connected to from the edge's own address.
    echo "reply=$(connect one 192.0.2.7 80 40001)"
    sleep 0.5
    echo "backend_connections=$(grep -c . "$BACKEND_LOG")"
    read -r peer header < <(tail -n 1 "$BACKEND_LOG")
    echo "backend_peer=$peer"
    echo "header=$header"
    echo "proxy_logged_client=$(grep -c '198.51.100.10:40001' /run/proxy.log)"
    # A port that is not listed, with a server of its own listening on it at the edge's address, the
    # edge's other address on the listed port, and the Gateway's address through the edge: none is
    # answered, and nothing but the proxy's own connection reached the server of the Gateway.
    ip netns exec edge socat -T 30 TCP-LISTEN:8080,bind=192.0.2.7,fork,reuseaddr EXEC:cat &
    sleep 0.3
    echo "unlisted_port_answer=$(connect two 192.0.2.7 8080)"
    echo "other_address_answer=$(connect three 198.51.100.1)"
    echo "gateway_through_edge_answer=$(connect four 203.0.113.21)"
    sleep 0.5
    echo "backend_connections_after=$(grep -c . "$BACKEND_LOG")"
    echo "from_client_to_worker=$(ip netns exec worker nft list counter ip count from_client | sed -n 's/.*packets \([0-9]*\).*/\1/p')"
    echo "router_toward_gateway=$(router)"
    ;;
  routes)
    # An established connection through the proxy.
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

    # A new connection with the default route only fails at once: closed without an answer. The
    # established one may still be resending, so what opens a connection is counted apart.
    before=$(router opening_toward_gateway)
    started=$(date +%s%N)
    answer=$(connect three)
    echo "new_default_only_answer=$answer"
    echo "new_default_only_ms=$((($(date +%s%N) - started) / 1000000))"
    echo "router_new_default_only=$(($(router opening_toward_gateway) - before))"

    # No route at all.
    ip -n edge route del default
    before=$(router opening_toward_gateway)
    started=$(date +%s%N)
    answer=$(connect four)
    echo "new_no_route_answer=$answer"
    echo "new_no_route_ms=$((($(date +%s%N) - started) / 1000000))"
    echo "router_new_no_route=$(($(router opening_toward_gateway) - before))"

    # The routes back: a new connection through the worker answers again, from the proxy that was
    # never restarted.
    ip -n edge route add default via 192.0.2.1
    ip -n edge route add 203.0.113.21/32 via 192.0.2.20
    before=$(router)
    echo "reply_route_back=$(connect five)"
    echo "router_route_back=$(($(router) - before))"
    if kill -0 "$proxy_pid" 2> /dev/null; then
      echo "proxy_still_running=yes"
    else
      echo "proxy_still_running=no"
    fi
    ;;
esac
