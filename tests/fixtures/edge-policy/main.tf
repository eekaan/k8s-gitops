# The edge stack's FRR configuration, rendered from its own template with fixture values, for
# scripts/edge-policy-render: the real-speaker proof runs this file's output in FRR. There are no
# providers, resources or backend, so tofu console evaluates it without init and without state.
# The arguments are the stack's (infra/openstack/stacks/sto2/edge/main.tf), and its own tests check
# what the stack renders from them.

locals {
  root  = "${path.module}/../../.."
  stack = "${local.root}/infra/openstack/stacks/sto2/edge"
  # The workers' side of the sessions, as the stack reads it.
  peer = yamldecode(file("${local.root}/kubernetes/apps/base/kube-system/cilium-bgp/app/bgp-peer.yaml")).spec

  frr_conf = templatefile("${local.stack}/frr.conf.tftpl", {
    hostname = "proof-edge"
    # Documentation addresses and AS numbers, apart from the loopback addresses the speakers use:
    # the proof's speakers bind and dial loopback addresses only.
    router_id     = "192.0.2.7"
    edge_asn      = 64497
    cluster_asn   = 64496
    node_cidr     = "127.0.0.0/24"
    # The workers' block for host numbers 20 to 83 of that subnet, the first worker's host number and
    # 64 workers, as the stack computes it; the stack's own tests check its computation.
    worker_blocks = ["127.0.0.20/30", "127.0.0.24/29", "127.0.0.32/27", "127.0.0.64/28", "127.0.0.80/30"]
    service_range = "203.0.113.16/28"
    max_prefix    = 16
    # The most paths the proof's FRR build takes; Debian's package takes more (docs/runbooks/edge.md).
    max_workers  = 64
    keepalive    = local.peer.timers.keepAliveTimeSeconds
    hold         = local.peer.timers.holdTimeSeconds
    connect      = local.peer.timers.connectRetryTimeSeconds
    restart_time = local.peer.gracefulRestart.restartTimeSeconds
  })
}
