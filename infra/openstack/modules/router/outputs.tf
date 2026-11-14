output "router_id" {
  description = "ID of the router."
  value       = openstack_networking_router_v2.this.id
}

# Taken from the router interfaces rather than from the input, so anything built on these subnet
# IDs is created after the subnet is attached, without a depends_on.
output "attached_subnet_ids" {
  description = "IDs of the attached subnets, as each router interface reports them, keyed like subnet_ids."
  value       = { for k, i in openstack_networking_router_interface_v2.this : k => i.subnet_id }
}

output "external_network_name" {
  description = "Name of the external network; floating IPs are allocated from it."
  value       = data.openstack_networking_network_v2.external.name
}

output "external_network_lookup" {
  description = "How the external network was found: by this name, among external networks only."
  value = {
    name     = data.openstack_networking_network_v2.external.name
    external = data.openstack_networking_network_v2.external.external
  }
}

output "external_network_id" {
  description = "ID of the external network the router's gateway is on."
  value       = openstack_networking_router_v2.this.external_network_id
}
