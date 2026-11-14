# The machines of a Talos cluster. Every node boots the Talos image without machine configuration
# and waits in maintenance mode, with a fixed private address and a floating IP whose Talos API
# answers only the operator allowlist; machine configuration is applied over the Talos API, and with
# it the node's own firewall (talos/firewall.yaml). With the full rules, the default, the nodes'
# security group also admits the Kubernetes API only from the allowlist and nothing else from outside
# the nodes; with the reduced rules it leaves every other port to the nodes' firewall but the NodePort
# range. Workers can be given more: allowed address pairs, and a security group of their own for
# traffic to Services, which security_group_rules leaves as it is.

locals {
  # Fixed addresses below the node subnet's DHCP pool: control planes from host number 10,
  # workers from host number 20.
  nodes = merge(
    { for i in range(var.controlplane_count) : "${var.name}-cp-${i + 1}" => { role = "controlplane", host = 10 + i } },
    { for i in range(var.worker_count) : "${var.name}-w-${i + 1}" => { role = "worker", host = 20 + i } },
  )
  flavors = { controlplane = var.controlplane_flavor, worker = var.worker_flavor }

  # The Talos API and the Kubernetes API.
  api_ports = [50000, 6443]

  # Sorted, so the same networks given in another order change no rule, and without duplicates,
  # as Neutron refuses a rule that already exists.
  api_sources = sort(distinct(var.api_allowed_cidrs))

  # What the reduced rules open to all, besides the full rules, which they keep, so switching between
  # the two adds or removes these alone. A Neutron rule only admits, so the ports left closed lie
  # between ranges: the Talos API, as a node in maintenance mode has no firewall and takes a
  # configuration from anyone who reaches it, and the NodePort range, as Cilium serves a NodePort
  # from its eBPF datapath before the node's firewall sees the packet.
  open = {
    for key, range in {
      "tcp-1-29999"     = { protocol = "tcp", min = 1, max = 29999 }
      "tcp-32768-49999" = { protocol = "tcp", min = 32768, max = 49999 }
      "tcp-50001-65535" = { protocol = "tcp", min = 50001, max = 65535 }
      "udp-1-29999"     = { protocol = "udp", min = 1, max = 29999 }
      "udp-32768-65535" = { protocol = "udp", min = 32768, max = 65535 }
      "icmp"            = { protocol = "icmp", min = null, max = null }
    } : key => range if var.security_group_rules == "reduced"
  }
}

resource "openstack_networking_secgroup_v2" "this" {
  name = var.name
  description = var.security_group_rules == "reduced" ? (
    "Talos nodes of ${var.name}: everything between them, the Talos API only from the operator allowlist and the nodes' floating IPs, every other port from all but the NodePort range; the nodes' own firewall filters the rest."
  ) : "Talos nodes of ${var.name}: everything between them, the Talos and Kubernetes APIs from the operator allowlist and the nodes' floating IPs, the Kubernetes API from the node subnet."
  # Neutron's default rules allow all egress, and stay.
  delete_default_rules = false
  tags                 = var.tags
}

resource "openstack_networking_secgroup_rule_v2" "intra" {
  for_each = toset(["IPv4", "IPv6"])

  security_group_id = openstack_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = each.value
  remote_group_id   = openstack_networking_secgroup_v2.this.id
}

# Keyed by port and position in the allowlist, never by the network: resource addresses are
# printed in plans and logs, and the allowlist must not be. Only its length shows.
resource "openstack_networking_secgroup_rule_v2" "api" {
  for_each = {
    for pair in setproduct(local.api_ports, range(nonsensitive(length(local.api_sources)))) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], source = pair[1] }
  }

  security_group_id = openstack_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = each.value.port
  port_range_max    = each.value.port
  remote_ip_prefix  = local.api_sources[each.value.source]
}

# A node that reaches another node's floating IP leaves through the router and arrives with its
# own floating IP as source.
resource "openstack_networking_secgroup_rule_v2" "hairpin" {
  for_each = {
    for pair in setproduct(local.api_ports, keys(local.nodes)) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], node = pair[1] }
  }

  security_group_id = openstack_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = each.value.port
  port_range_max    = each.value.port
  remote_ip_prefix  = "${openstack_networking_floatingip_v2.node[each.value.node].address}/32"
}

# A load balancer that proxies, as Octavia's amphora provider does, connects to the API servers
# and health-checks them from its own address on the node subnet, not the client's.
resource "openstack_networking_secgroup_rule_v2" "api_from_subnet" {
  security_group_id = openstack_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = var.network.cidr
}

resource "openstack_networking_secgroup_rule_v2" "open" {
  for_each = local.open

  security_group_id = openstack_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = each.value.protocol
  port_range_min    = each.value.min
  port_range_max    = each.value.max
  remote_ip_prefix  = "0.0.0.0/0"
}

# The workers' own group, on top of the nodes': only the rules for traffic to Services. A rule
# matches a packet's protocol, port and source, never its destination, so it admits the same
# traffic to the worker's own address and to every address its allowed address pairs carry.
resource "openstack_networking_secgroup_v2" "workers" {
  name        = "${var.name}-workers"
  description = "Workers of ${var.name}: connections to Services from the sources the cluster names."
  # Ingress rules only; the nodes' group keeps Neutron's default egress rules for the workers.
  delete_default_rules = true
  tags                 = var.tags
}

# Keyed by port and position in the sources, as the API rules are.
resource "openstack_networking_secgroup_rule_v2" "worker_ingress" {
  for_each = {
    for pair in setproduct(var.worker_ingress.tcp_ports, range(nonsensitive(length(var.worker_ingress.sources)))) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], source = pair[1] }
  }

  security_group_id = openstack_networking_secgroup_v2.workers.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = each.value.port
  port_range_max    = each.value.port
  remote_ip_prefix  = var.worker_ingress.sources[each.value.source]
}

# Spreads the nodes over hypervisors where the cloud can, and still places them where it cannot.
resource "openstack_compute_servergroup_v2" "this" {
  name     = var.name
  policies = ["soft-anti-affinity"]
}

module "node" {
  source   = "../vm"
  for_each = local.nodes

  name                = each.key
  flavor              = local.flavors[each.value.role]
  image_id            = var.image_id
  root_volume_size_gb = var.root_volume_size_gb
  volume_type         = var.volume_type
  server_group_id     = openstack_compute_servergroup_v2.this.id
  network_id          = var.network.network_id
  subnet_id           = var.network.subnet_id
  fixed_ip            = cidrhost(var.network.cidr, each.value.host)
  # The provider updates a port's security groups and allowed address pairs in place, so adding
  # either to a running worker's port changes neither the port nor its server.
  security_group_ids = concat(
    [openstack_networking_secgroup_v2.this.id],
    each.value.role == "worker" ? [openstack_networking_secgroup_v2.workers.id] : [],
  )
  allowed_address_pairs = concat(
    var.allowed_address_pairs,
    each.value.role == "worker" ? var.worker_allowed_address_pairs : [],
  )
  tags = var.tags
}

# The address is a resource of its own, keyed by node name, so a node keeps its floating IP when
# its instance or port is replaced.
resource "openstack_networking_floatingip_v2" "node" {
  for_each = local.nodes

  pool = var.external_network
  tags = var.tags
}

resource "openstack_networking_floatingip_associate_v2" "node" {
  for_each = local.nodes

  floating_ip = openstack_networking_floatingip_v2.node[each.key].address
  port_id     = module.node[each.key].port.id
}
