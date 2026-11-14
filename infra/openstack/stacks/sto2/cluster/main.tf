# The Talos nodes, on the plumbing stack's network and booting its Talos image, with their
# security group, server group and floating IPs.

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
