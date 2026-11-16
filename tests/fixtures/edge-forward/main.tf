# The edge stack's nftables rules and proxy configuration, rendered from its own templates with
# fixture values, for the proofs in tests/edge-forward.bats: an edge at host number 7 of the node
# subnet, the workers' block for host numbers 20 to 99, the Gateway at a host of the service range,
# and one public port. There are no providers, resources or backend, so tofu console evaluates it
# without init and without state. The stack's own tests check what it renders from its inputs.

locals {
  stack = "${path.module}/../../../infra/openstack/stacks/sto2/edge"

  nftables_conf = templatefile("${local.stack}/nftables.conf.tftpl", {
    workers = join(", ", ["192.0.2.20/30", "192.0.2.24/29", "192.0.2.32/27", "192.0.2.64/27", "192.0.2.96/30"])
    gateway = "203.0.113.21"
    ports   = [80]
    own     = "192.0.2.7"
  })

  haproxy_conf = templatefile("${local.stack}/haproxy.cfg.tftpl", {
    own     = "192.0.2.7"
    gateway = "203.0.113.21"
    ports   = [80]
  })
}
