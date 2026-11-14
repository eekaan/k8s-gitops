# What outlives a node rebuild: the node network, its router to the external network and the
# Talos image. The cluster stack builds on this stack's outputs.

# The cloud and its credentials come from the environment: OS_CLOUD names the clouds.yaml entry.
provider "openstack" {}

provider "talos" {}

locals {
  versions = yamldecode(file("${path.module}/${var.versions_file}"))
  tags     = [var.prefix]
}

# Neutron draws every address it assigns itself, DHCP ports included, from the allocation pool, so
# fixed node addresses below the pool, at host offsets under 100, can never collide with one.
module "network" {
  source = "../../../modules/network"

  name          = "${var.prefix}-nodes"
  cidr          = var.node_cidr
  gateway       = true
  port_security = true
  dhcp_range    = [100, 200]
  tags          = local.tags
}

module "router" {
  source = "../../../modules/router"

  name             = var.prefix
  external_network = var.external_network
  subnet_ids       = { nodes = module.network.subnet_id }
  tags             = local.tags
}

module "image" {
  source = "../../../modules/talos-image"

  name          = var.prefix
  talos_version = local.versions.talos
  schematic     = file("${path.module}/../../../../../talos/schematic.yaml")
  tags          = local.tags
}
