# The Talos nodes, on the plumbing stack's network and booting its Talos image, with their
# security group, server group and floating IPs, and the load balancer in front of their
# Kubernetes API.

# The cloud and its credentials come from the environment: OS_CLOUD names the clouds.yaml entry.
provider "openstack" {}

data "terraform_remote_state" "plumbing" {
  backend = "s3"
  config  = var.plumbing_state
}

locals {
  plumbing = data.terraform_remote_state.plumbing.outputs
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
