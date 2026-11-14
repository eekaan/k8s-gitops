# IDs and addresses depend on the deployment and an apply in CI prints outputs to a public log,
# so every output that carries them is sensitive.

output "network" {
  description = "The node network and subnet: IDs, range, gateway, DHCP pool and MTU."
  sensitive   = true
  value = {
    network_id = module.network.network_id
    subnet_id  = module.network.subnet_id
    cidr       = module.network.cidr
    gateway_ip = module.network.gateway_ip
    dhcp_pool  = module.network.allocation_pool
    mtu        = module.network.mtu
  }
}

output "router" {
  description = "The router, the external network its gateway is on, and the subnets attached to it. Build node ports on attached_subnet_ids so they wait for the attachment."
  sensitive   = true
  value = {
    id                      = module.router.router_id
    external_network_id     = module.router.external_network_id
    external_network        = module.router.external_network_name
    external_network_lookup = module.router.external_network_lookup
    attached_subnet_ids     = module.router.attached_subnet_ids
  }
}

output "image" {
  description = "The Talos node image: ID and name, the schematic and platform it is built from, the URL it was downloaded from and whether it was decompressed, its disk format and visibility."
  sensitive   = true
  value = {
    id           = module.image.image_id
    name         = module.image.image_name
    schematic_id = module.image.schematic_id
    platform     = module.image.platform
    source_url   = module.image.source_url
    decompress   = module.image.decompress
    disk_format  = module.image.disk_format
    visibility   = module.image.visibility
  }
}

output "talos_version" {
  description = "Talos release of the node image, as read from the versions file."
  value       = local.versions.talos
}
