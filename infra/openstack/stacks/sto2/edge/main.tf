# The edge routers (ADR 0013, and the record of their data path): two small Linux VMs on the plumbing
# stack's node network, at the two addresses it reserves, running FRR. The workers open BGP sessions
# to them and announce every LoadBalancer Service's address as a /32; each edge forwards traffic that
# reaches its own public address to the public Gateway's address, through the workers, and back. The
# stack reads the plumbing stack's state and nothing of the cluster stack's, so destroying and
# rebuilding the cluster leaves the edges.

# The cloud and its credentials come from the environment: OS_CLOUD names the clouds.yaml entry.
provider "openstack" {}

data "terraform_remote_state" "plumbing" {
  backend = "s3"
  config  = var.plumbing_state
}

data "openstack_images_image_v2" "edge" {
  name        = var.edge_image_name
  most_recent = true
}

locals {
  plumbing = data.terraform_remote_state.plumbing.outputs
  bgp      = local.plumbing.bgp
  name     = "${var.prefix}-edge"
  tags     = [var.prefix]

  edges = {
    for index, address in local.bgp.edge_addresses : tostring(index + 1) => {
      name    = "${local.name}-${index + 1}"
      address = address
    }
  }

  # Sorted and without duplicates, so the same networks given in another order change no rule, and
  # Neutron, which refuses a rule that already exists, is given each once.
  ssh_sources    = sort(distinct(var.ssh_allowed_cidrs))
  public_sources = sort(distinct(var.public_allowed_cidrs == null ? var.ssh_allowed_cidrs : var.public_allowed_cidrs))

  # The workers' side of the sessions, as the Kubernetes manifests configure it: the one place the
  # timers and the graceful restart time are written, so the edges cannot disagree with it. Changing
  # the manifest changes the edges' configuration, which replaces them (edge-rollout).
  peer = yamldecode(file("${path.module}/../../../../../kubernetes/apps/base/kube-system/cilium-bgp/app/bgp-peer.yaml")).spec

  # The workers' addresses: the cluster stack numbers them from worker_first_host on, one host each,
  # and there are at most max_workers. The edges take BGP sessions from these and from no other
  # address of the node subnet, which also holds the control planes, the CI host and the other edge:
  # the fewest networks that hold exactly that block, in address order, for the listen ranges, the
  # firewall rule and the security group. Addresses are compared as numbers.
  node_cidr  = local.plumbing.network.cidr
  node_bits  = tonumber(split("/", local.node_cidr)[1])
  node_first = sum([for i, octet in split(".", cidrhost(local.node_cidr, 0)) : tonumber(octet) * pow(256, 3 - i)])
  dhcp_first = sum([for i, octet in split(".", local.plumbing.network.dhcp_pool.start) : tonumber(octet) * pow(256, 3 - i)])
  edge_numbers = [
    for address in local.bgp.edge_addresses : sum([for i, octet in split(".", address) : tonumber(octet) * pow(256, 3 - i)])
  ]
  worker_first = local.node_first + var.worker_first_host
  worker_last  = local.worker_first + var.max_workers - 1
  worker_blocks = [for key in sort(flatten([
    for bits in range(33 - local.node_bits) : [
      for index in range(pow(2, bits)) : format("%010d %s", local.node_first + index * pow(2, 32 - local.node_bits - bits), cidrsubnet(local.node_cidr, bits, index))
      if local.node_first + index * pow(2, 32 - local.node_bits - bits) >= local.worker_first &&
      local.node_first + (index + 1) * pow(2, 32 - local.node_bits - bits) - 1 <= local.worker_last && !(
        bits > 0 &&
        local.node_first + floor(index / 2) * pow(2, 33 - local.node_bits - bits) >= local.worker_first &&
        local.node_first + (floor(index / 2) + 1) * pow(2, 33 - local.node_bits - bits) - 1 <= local.worker_last
      )
    ]
  ])) : split(" ", key)[1]]

  # Every address of the service range can be announced as a /32 at most once, so the prefix list
  # accepts at most this many prefixes: a limit that only a loosened list can reach.
  service_addresses = pow(2, 32 - tonumber(split("/", local.bgp.service_range)[1]))

  frr_conf = {
    for key, edge in local.edges : key => templatefile("${path.module}/frr.conf.tftpl", {
      hostname      = edge.name
      router_id     = edge.address
      edge_asn      = local.bgp.edge_asn
      cluster_asn   = local.bgp.cluster_asn
      worker_blocks = local.worker_blocks
      service_range = local.bgp.service_range
      max_prefix    = local.service_addresses
      max_workers   = var.max_workers
      keepalive     = local.peer.timers.keepAliveTimeSeconds
      hold          = local.peer.timers.holdTimeSeconds
      connect       = local.peer.timers.connectRetryTimeSeconds
      restart_time  = local.peer.gracefulRestart.restartTimeSeconds
    })
  }

  nftables_conf = {
    for key, edge in local.edges : key => templatefile("${path.module}/nftables.conf.tftpl", {
      workers = join(", ", local.worker_blocks)
      own     = edge.address
      gateway = local.bgp.gateway_address
      ports   = join(", ", [for port in sort(formatlist("%05d", var.public_ports)) : tostring(tonumber(port))])
    })
  }

  config = {
    for key in keys(local.edges) : key => {
      frr_conf      = local.frr_conf[key]
      nftables_conf = local.nftables_conf[key]
      sysctl        = file("${path.module}/sysctl.conf")
      sshd_conf     = file("${path.module}/sshd.conf")
    }
  }

  # Everything an edge is, delivered once at its first boot. It holds no secret: user data is kept
  # in tofu state and served to the instance by the metadata service, so it holds the routing
  # configuration and the firewall rules, which name the workers' block and the service range, and
  # neither the operator allowlist (the security group holds that) nor a key. Changing it replaces
  # the instance: an edge is rebuilt, not patched.
  user_data = {
    for key in keys(local.edges) : key => templatefile("${path.module}/user-data.yaml.tftpl", {
      frr_conf      = local.config[key].frr_conf
      nftables_conf = local.config[key].nftables_conf
      sysctl        = local.config[key].sysctl
      sshd_conf     = local.config[key].sshd_conf
      daemons       = file("${path.module}/frr-daemons")
      first_boot    = file("${path.module}/first-boot.sh")
    })
  }
}

# Spreads the edges over hypervisors where the cloud can, and still places them where it cannot:
# a rebuild during an incident must not fail for want of a second host, and the two edges stay
# apart on any cloud with room for them. A hard anti-affinity policy would refuse to place the
# replacement of one edge on the host of the other.
resource "openstack_compute_servergroup_v2" "edges" {
  name     = local.name
  policies = ["soft-anti-affinity"]
}

# The public ports from the configured networks, SSH from the operator allowlist and BGP from the
# workers' addresses, and nothing else inbound. The cloud's own default rules are deleted, so the group
# holds exactly the rules below whatever a cloud adds to new groups.
resource "openstack_networking_secgroup_v2" "edge" {
  name                 = local.name
  description          = "Edge routers of ${var.prefix}: the public ports from the configured networks, SSH from the operator allowlist, BGP from the workers' addresses; all egress."
  delete_default_rules = true
  tags                 = local.tags
}

# Keyed by port and position in the list of networks, never by the network: resource addresses are
# printed in plans and logs, and the allowlist must not be. Only its length shows.
resource "openstack_networking_secgroup_rule_v2" "ssh" {
  for_each = { for i in range(nonsensitive(length(local.ssh_sources))) : tostring(i) => i }

  security_group_id = openstack_networking_secgroup_v2.edge.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = local.ssh_sources[each.value]
}

resource "openstack_networking_secgroup_rule_v2" "public" {
  for_each = {
    for pair in setproduct(var.public_ports, range(nonsensitive(length(local.public_sources)))) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], source = pair[1] }
  }

  security_group_id = openstack_networking_secgroup_v2.edge.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = each.value.port
  port_range_max    = each.value.port
  remote_ip_prefix  = local.public_sources[each.value.source]
}

# The workers open their sessions to the edges from their addresses on the node subnet, and nothing
# else there may: one rule per network of the workers' block, keyed by its position.
resource "openstack_networking_secgroup_rule_v2" "bgp" {
  for_each = { for i, block in local.worker_blocks : format("%03d", i) => block }

  security_group_id = openstack_networking_secgroup_v2.edge.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 179
  port_range_max    = 179
  remote_ip_prefix  = each.value
}

# Path MTU discovery: ICMP destination unreachable, code 4 (fragmentation needed), from anywhere,
# as a client's or the cloud's router can send it. Neutron reads an ICMP rule's two ports as type
# and code.
resource "openstack_networking_secgroup_rule_v2" "path_mtu" {
  security_group_id = openstack_networking_secgroup_v2.edge.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  port_range_min    = 3
  port_range_max    = 4
  remote_ip_prefix  = "0.0.0.0/0"
}

# The edges fetch packages from the distribution's repositories and forward to the workers.
resource "openstack_networking_secgroup_rule_v2" "egress" {
  for_each = { IPv4 = "0.0.0.0/0", IPv6 = "::/0" }

  security_group_id = openstack_networking_secgroup_v2.edge.id
  direction         = "egress"
  ethertype         = each.key
  remote_ip_prefix  = each.value
}

resource "openstack_compute_keypair_v2" "edge" {
  name       = local.name
  public_key = var.edge_ssh_public_key
}

# No allowed address pair: an edge forwards packets whose source is its own address, after its own
# translation, and receives packets whose destination is its own address, so port security, which
# lets a port send only from its own address and its pairs, needs nothing added. Without the source
# translation an edge would send packets from every client's address, and receive replies for them,
# which no list of pairs covers short of every address; port security would have to be off on the
# port, and the record of the data path says why that is not done.
module "edge" {
  source   = "../../../modules/vm"
  for_each = local.edges

  name                = each.value.name
  flavor              = var.flavor
  image_id            = data.openstack_images_image_v2.edge.id
  root_volume_size_gb = var.root_volume_size_gb
  volume_type         = var.volume_type
  server_group_id     = openstack_compute_servergroup_v2.edges.id
  network_id          = local.plumbing.network.network_id
  # The node subnet as the router reports it attached: a floating IP can only be associated with a
  # port on a subnet that a router joins to the external network.
  subnet_id          = local.plumbing.router.attached_subnet_ids.nodes
  fixed_ip           = each.value.address
  security_group_ids = [openstack_networking_secgroup_v2.edge.id]
  user_data          = local.user_data[each.key]
  key_pair           = openstack_compute_keypair_v2.edge.name
  tags               = local.tags
}

resource "openstack_networking_floatingip_v2" "edge" {
  for_each = local.edges

  pool = local.plumbing.router.external_network
  tags = local.tags
}

resource "openstack_networking_floatingip_associate_v2" "edge" {
  for_each = local.edges

  floating_ip = openstack_networking_floatingip_v2.edge[each.key].address
  port_id     = module.edge[each.key].port.id
}
