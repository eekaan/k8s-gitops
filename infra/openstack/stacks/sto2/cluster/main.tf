# The Talos nodes, on the plumbing stack's network and booting its Talos image, with their
# security group, server group and floating IPs, the load balancer in front of their Kubernetes
# API, and the talman.yaml that configures them.

# The cloud and its credentials come from the environment: OS_CLOUD names the clouds.yaml entry.
provider "openstack" {}

data "terraform_remote_state" "plumbing" {
  backend = "s3"
  config  = var.plumbing_state
}

locals {
  plumbing = data.terraform_remote_state.plumbing.outputs
  versions = yamldecode(file("${path.module}/${var.versions_file}"))
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
  image_id            = local.plumbing.image.id
  external_network    = local.plumbing.router.external_network
  api_allowed_cidrs   = var.api_allowed_cidrs
  controlplane_count  = var.controlplane_count
  worker_count        = var.worker_count
  controlplane_flavor = var.controlplane_flavor
  worker_flavor       = var.worker_flavor
  tags                = [var.prefix]
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

# talman's configuration of the cluster, from this stack's own nodes and load balancer. talman runs
# outside the node network and reaches every node at its floating address.
locals {
  # Control planes first, then workers, each by name: a stable order, so the file changes only
  # when a node does.
  talman_nodes = flatten([
    for role in ["controlplane", "worker"] : [
      for name in sort(keys(module.nodes.nodes)) : {
        hostname    = name
        role        = role
        address     = module.nodes.nodes[name].floating_address
        floating_ip = module.nodes.nodes[name].floating_address
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
    # Every address the Kubernetes API is reached on: the load balancer's on the node network and
    # its floating one, and each control plane's floating address.
    api_sans = concat(
      [module.api_lb.vip_address, module.api_lb.floating_address],
      [for node in local.talman_nodes : node.floating_ip if node.role == "controlplane"],
    )
    # Where the cluster recipes, which run outside the node network, reach the Kubernetes API.
    api_address = module.api_lb.floating_address
    nodes       = local.talman_nodes
  })
}
