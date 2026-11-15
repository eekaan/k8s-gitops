# The Talos nodes, on the plumbing stack's network and booting its Talos image, with their
# security groups, server group and floating IPs, the workers' data volumes and their part in
# Services announced over BGP, the load balancer in front of their Kubernetes API, and the
# talman.yaml that configures them.

# The cloud and its credentials come from the environment: OS_CLOUD names the clouds.yaml entry.
provider "openstack" {}

data "terraform_remote_state" "plumbing" {
  backend = "s3"
  config  = var.plumbing_state
}

locals {
  plumbing = data.terraform_remote_state.plumbing.outputs
  versions = yamldecode(file("${path.module}/${var.versions_file}"))

  # The numbers Services announced over BGP rest on, which the plumbing stack defines.
  bgp = local.plumbing.bgp
}

module "nodes" {
  source = "../../../modules/talos-nodes"

  name = var.prefix
  network = {
    network_id = local.plumbing.network.network_id
    # The node subnet as the router reports it attached: a floating IP can only be associated
    # with a port on a subnet that a router joins to the external network.
    subnet_id = local.plumbing.router.attached_subnet_ids.nodes
    cidr      = local.plumbing.network.cidr
  }
  image_id             = local.plumbing.image.id
  external_network     = local.plumbing.router.external_network
  api_allowed_cidrs    = var.api_allowed_cidrs
  security_group_rules = var.security_group_rules
  controlplane_count   = var.controlplane_count
  worker_count         = var.worker_count
  worker_first_host    = var.worker_first_host
  controlplane_flavor  = var.controlplane_flavor
  worker_flavor        = var.worker_flavor

  # A worker receives packets addressed to the service range and answers from it, which port
  # security allows only for the port's own address and its allowed address pairs. Control planes
  # announce nothing (the cilium-bgp application selects workers only), so they get no pair.
  worker_allowed_address_pairs = [local.bgp.service_range]
  # The edge routers reach the workers on the service ports. Each worker opens its BGP sessions to
  # the edge routers itself, through the nodes' group's egress, so no rule admits TCP 179.
  worker_ingress = {
    sources   = [for address in local.bgp.edge_addresses : "${address}/32"]
    tcp_ports = var.service_ports
  }

  tags = [var.prefix]
}

# The CI host the ci stack makes, at its host number on the node subnet, reaches the Talos API and
# the Kubernetes API on the nodes' fixed addresses. Without ci_host_number there is no rule, so this
# stack plans whether the ci stack exists or not.
resource "openstack_networking_secgroup_rule_v2" "ci_host" {
  for_each = var.ci_host_number == null ? toset([]) : toset(["50000", "6443"])

  security_group_id = module.nodes.security_group.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = tonumber(each.key)
  port_range_max    = tonumber(each.key)
  remote_ip_prefix  = "${cidrhost(local.plumbing.network.cidr, var.ci_host_number)}/32"
}

# Every worker's data volume: one more disk, empty, that Talos hands to the storage layer
# (talos/patches/worker/data-volume.yaml). It belongs to this stack, so destroying the stack
# deletes it and what is on it.
locals {
  workers = toset([for name, node in module.nodes.nodes : name if node.role == "worker"])
}

resource "openstack_blockstorage_volume_v3" "worker_data" {
  for_each = local.workers

  name        = "${each.key}-data"
  size        = var.worker_data_volume_size
  volume_type = var.worker_data_volume_type
}

# An attachment of its own, not a block device of the instance: the provider replaces a server
# whose block devices change, and the vm module ignores changes to them, so a block device would
# never reach a running worker. The instance has no attribute for an attachment made here, so
# attaching changes no server.
resource "openstack_compute_volume_attach_v2" "worker_data" {
  for_each = local.workers

  instance_id = module.nodes.instances[each.key].id
  volume_id   = openstack_blockstorage_volume_v3.worker_data[each.key].id
}

module "api_lb" {
  source = "../../../modules/api-lb"

  name = var.prefix
  network = {
    # The attached subnet, as for the nodes: the floating IP needs a port on a routed subnet.
    subnet_id = local.plumbing.router.attached_subnet_ids.nodes
    cidr      = local.plumbing.network.cidr
  }
  # Above the gateway, which Neutron gives the subnet's first address, and below the control
  # planes' host number 10, so no node count reaches it; the DHCP pool starts at 100.
  vip_host              = 5
  members               = module.nodes.controlplane_addresses
  allowed_cidrs         = var.api_allowed_cidrs
  external_network      = local.plumbing.router.external_network
  loadbalancer_provider = var.api_lb_provider
  flavor_id             = var.api_lb_flavor_id
  tags                  = [var.prefix]
}

# Where the API load balancer and the CI host reach the nodes' APIs from, for the nodes' firewall,
# which admits neither the node network as a whole nor so the edge routers on it. A load balancer
# that proxies, as Octavia's amphora provider does, connects to the API servers and health-checks
# them from its own ports, which the cloud gives addresses from the node subnet's DHCP pool; the
# pool goes in as the fewest networks that hold it exactly: every block of the node subnet that lies
# in the pool and whose enclosing block does not.
locals {
  # An IPv4 address as a number.
  node_cidr  = local.plumbing.network.cidr
  node_bits  = tonumber(split("/", local.node_cidr)[1])
  node_first = sum([for i, octet in split(".", cidrhost(local.node_cidr, 0)) : tonumber(octet) * pow(256, 3 - i)])
  pool_first = sum([for i, octet in split(".", local.plumbing.network.dhcp_pool.start) : tonumber(octet) * pow(256, 3 - i)])
  pool_last  = sum([for i, octet in split(".", local.plumbing.network.dhcp_pool.end) : tonumber(octet) * pow(256, 3 - i)])
  pool_blocks = flatten([
    for bits in range(33 - local.node_bits) : [
      for index in range(pow(2, bits)) : cidrsubnet(local.node_cidr, bits, index)
      if local.node_first + index * pow(2, 32 - local.node_bits - bits) >= local.pool_first &&
      local.node_first + (index + 1) * pow(2, 32 - local.node_bits - bits) - 1 <= local.pool_last && !(
        bits > 0 &&
        local.node_first + floor(index / 2) * pow(2, 33 - local.node_bits - bits) >= local.pool_first &&
        local.node_first + (floor(index / 2) + 1) * pow(2, 33 - local.node_bits - bits) - 1 <= local.pool_last
      )
    ]
  ])

  api_load_balancer_addresses = concat(["${module.api_lb.vip_address}/32"], local.pool_blocks)
  ci_host_address             = var.ci_host_number == null ? null : cidrhost(local.node_cidr, var.ci_host_number)
}

# talman's configuration of the cluster, from this stack's own nodes and load balancer. talman runs
# outside the node network and reaches every node at its floating address.
locals {
  # Control planes first, then workers, each by name: a stable order, so the file changes only
  # when a node does.
  talman_nodes = flatten([
    for role in ["controlplane", "worker"] : [
      for name in sort(keys(module.nodes.nodes)) : {
        hostname        = name
        role            = role
        address         = module.nodes.nodes[name].floating_address
        floating_ip     = module.nodes.nodes[name].floating_address
        private_address = module.nodes.nodes[name].private_address
      } if module.nodes.nodes[name].role == role
    ]
  ])

  talman_yaml = templatefile("${path.module}/../../../../../talos/talman.yaml.tftpl", {
    cluster_name       = var.cluster_name
    endpoint           = module.api_lb.endpoint
    talos_version      = local.versions.talos
    kubernetes_version = local.versions.kubernetes
    node_subnet        = local.plumbing.network.cidr
    pod_subnet         = var.pod_subnet
    service_subnet     = var.service_subnet
    # On through talman.yaml to cluster-config, from which the cilium-bgp application takes them.
    service_range = local.bgp.service_range
    bgp           = local.bgp
    # Every address the Kubernetes API is reached on: the load balancer's on the node network and
    # its floating one, and each control plane's floating address.
    api_sans = concat(
      [module.api_lb.vip_address, module.api_lb.floating_address],
      [for node in local.talman_nodes : node.floating_ip if node.role == "controlplane"],
    )
    # Where the cluster recipes, which run outside the node network, reach the Kubernetes API.
    api_address = module.api_lb.floating_address
    nodes       = local.talman_nodes
    # The nodes' own firewall: its listeners, and the allowlist that reaches the Talos and Kubernetes
    # APIs, which the generated talman.yaml carries and nothing committed does.
    firewall                    = yamldecode(file("${path.module}/../../../../../talos/firewall.yaml"))
    operator_cidrs              = sort(distinct(var.api_allowed_cidrs))
    api_load_balancer_addresses = local.api_load_balancer_addresses
    ci_host_address             = local.ci_host_address
  })
}
