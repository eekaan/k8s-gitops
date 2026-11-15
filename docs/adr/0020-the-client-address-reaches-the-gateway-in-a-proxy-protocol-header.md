# 0020 — The client's address reaches the Gateway in a PROXY protocol header

- Status: accepted
- Date: 2026-11-15

## Context

[ADR 0018](0018-own-edge-routers-translate-public-traffic-to-the-gateway.md) has each edge router
translate the source of a connection to its own address, because a worker answers a packet to the
address it came from, through the cloud's router, and the answer would never meet the connection
unless that address is on the node subnet. The cost is that the Gateway sees an edge, never the
client: the proxies' access logs name two addresses for the whole world, and nothing in the cluster
can tell one client from another, which a rate limit, an allow list or abuse detection would need.
That record names two ways to restore the client's address and builds neither.

## Decision

- **A layer 4 proxy on each edge sends the PROXY protocol, version 2, to the Gateway's listeners.**
  It ends the client's connection on the edge's public port, opens one to the Gateway, and writes
  the client's address and port in a PROXY protocol header before any of the client's bytes
  ([the protocol](https://www.haproxy.org/download/2.1/doc/proxy-protocol.txt)). The connection to
  the Gateway is from the edge's own address, so the source translation, and the way replies
  return, stand as ADR 0018 has them. The proxy and its configuration are the edges' own change.
- **The Gateway accepts it, on both listeners.** The Gateway's `ClientTrafficPolicy` sets the PROXY
  protocol, `proxyProtocol`, and sets it `optional`: Envoy's PROXY protocol listener filter then
  reads a header when a connection begins with one and passes a connection that begins with anything
  else on untouched, for a TLS handshake and a plain HTTP request alike. Required, it would reset
  every connection a sender makes without a header, which would make the Gateway's change and the
  edges' one live step; optional, the Gateway's half is safe to run alone, and runs before the
  edges' half.
- **The address Envoy takes as the client's** is the header's source when a connection carries one
  and the connection's own address otherwise. No `clientIPDetection` is set, so the controller has
  the connection manager use the connection's remote address, which the header replaces, and never
  read the `x-forwarded-for` a client sends: that header reaches a backend with the address Envoy
  took appended to it, the client's own entries to its left. A setting that trusted hops or CIDRs of
  that header would instead let a request choose its address.
- **The proxies log it.** The `EnvoyProxy` sets one JSON access log line per request to standard
  output, where the log collector already reads the containers' lines
  ([ADR 0014](0014-logs-in-victorialogs-collected-by-vector.md)): the client address Envoy took, the
  socket's own peer, the host, the method, the path without its query string, the status, the
  response flags, the duration and the bytes.

## Trust model

A PROXY protocol header is a claim: Envoy takes the address in it as the client's from whoever
writes it, and does not check it. Who may make that claim is whoever can write the first bytes of a
connection to a listener of the proxies, and what limits that is who can open one.

- **The edges** are the senders the design intends. Each writes its header first, and anything the
  client sends follows it as payload: Envoy's filter reads one header, so a second one a client
  writes itself is read as the start of a TLS handshake or an HTTP request, which it is not, and is
  refused. So a client cannot claim an address through an edge that writes its own header.
- **Inside the cluster**, the `public-proxy` policy of the proxies' namespace
  ([ADR 0019](0019-namespaces-deny-traffic-by-default-and-each-declares-its-flows.md)) admits, on
  top of the namespace's default deny, the entity `world` alone to the ports the proxies listen on,
  10080 and 10443: senders outside the cluster, which the workers' security group narrows to the
  edges, on the service ports. A pod of any namespace and the host of another node are not `world`,
  and the policy refuses them. The local host of a proxy's node, a process or a pod in its network
  namespace, is not held to it: the pinned Cilium lets the local host reach the pods on its node
  whatever the policies say, so it can claim any address to a proxy there. The node firewall
  (ADR 0017) filters packets addressed to a node, not to a pod or to an address Cilium serves, so
  it limits none of these. The policy limits senders inside the cluster only once the agents
  enforce it: while Cilium's `policyAuditMode` is set, every agent reports what a policy would drop
  and drops nothing, and any pod or node that reaches a proxy can make the claim
  ([Service addresses](../kubernetes.md#service-addresses)).
- **A sender that forwards plain TCP**, writing no header of its own, carries the client's own
  first bytes to the proxies: a header the client writes through it is the one they read, so the
  address they take as the client's is the client's claim, and with `optional` the clients that
  write none are served as well, so such a sender keeps working. That address reaches the log and
  `x-forwarded-for`, and so whatever reads either: a use of it that decides something, a rate limit
  or an allow list, is no better than who can write a header. That is why every sender the
  listeners admit writes its own header: the edges write theirs in the change that follows the
  Gateway's, and `optional` is dropped once every sender writes one.
- **What limits it.** The edges' security group admits the public ports only from the networks of
  its variable, the operator allowlist by default (ADR 0018). What the header can change is the
  address the proxies take as the client's, which the log and `x-forwarded-for` carry, never which
  routes serve it, its TLS settings or what a listener accepts. The `peer_address` field of the
  access log is the socket's own peer, so a claim made from an unexpected sender is visible beside
  the address it claims.
- **What closes each case.** The claim through an edge ends when the edge writes its own header.
  Requiring the header, which drops `optional`, has the listeners refuse every connection from a
  sender that writes none unless its client writes one, which `just gateway-check` sees, so no
  such sender stays in place unnoticed; it stops no sender that reaches a listener from writing a
  header. Senders inside the cluster are limited by `public-proxy` alone, once the agents enforce
  it, and the local host of a proxy's node by neither.

## Alternatives considered

- **Routing replies back through the edges**, so the Gateway sees the client's own address. It needs
  source routing on every worker so that each reply meets the edge that holds its connection, and
  an edge that sends from the client's address and from addresses of the service range, which takes
  the port security off its port (ADR 0018).
- **Detecting abuse on the edges.** An edge sees every client's address and could hold a rate limit
  or a deny list in nftables. It sees no request: not the host, the path or the status, so nothing
  per route, and it adds a second place where policy lives and a second log to read, where the
  Gateway holds the routes.
- **Leaving it.** Nothing to build, and the logs name two addresses for every client.

## Consequences

- **The Gateway's half goes first.** With `optional`, the listeners serve a connection with a
  header and one without alike, so this change goes live before any sender writes one; the edges'
  change follows, and a later change drops `optional` once every sender writes the header. A
  connection without a header shows its own address in the access log and `x-forwarded-for`, an
  edge's or that of the worker that forwarded it from another node; one with an edge's header shows
  the client's.
- **TCP only.** The PROXY protocol rides a TCP connection. The Gateway offers no UDP or HTTP/3, and
  Envoy Gateway refuses to send the PROXY protocol to a backend over HTTP/3.
- **The access log's line is narrowed by this change.** One line per request, about 250 bytes, to
  the proxies' standard output; at one request a second that is about 20 MB a day before the log
  store compresses it, and it takes its share of the store's retention
  ([Logs](../kubernetes.md#logs)). The proxies write such a line per request without the setting,
  in the controller's default format, which carries the full path with its query string, the user
  agent and the client's own `x-forwarded-for`; the setting replaces that line with this one.
- **Paths are in the log store,** without query strings. A path can still hold what a client or an
  application put there.
- **The edges' change is separate.** It replaces the forwarding of the public ports on each edge
  with the proxy, which changes what ADR 0018 says of the data path and of the edge's firewall,
  and is proved by a connection through an edge whose line in the log names the client.
