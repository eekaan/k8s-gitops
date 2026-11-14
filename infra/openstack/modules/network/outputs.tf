output "network_id" {
  description = "ID of the network."
  value       = openstack_networking_network_v2.this.id
}

output "subnet_id" {
  description = "ID of the subnet."
  value       = openstack_networking_subnet_v2.this.id
}

output "gateway_ip" {
  description = "Gateway address of the subnet, or null when it has none."
  value       = var.gateway ? openstack_networking_subnet_v2.this.gateway_ip : null
}

output "cidr" {
  description = "The subnet's range."
  value       = openstack_networking_subnet_v2.this.cidr
}

output "allocation_pool" {
  description = "First and last address Neutron assigns by itself (start, end). Fixed addresses go outside it."
  value       = one(openstack_networking_subnet_v2.this.allocation_pool)
}

output "mtu" {
  description = "MTU of the network. Neutron derives it from how the cloud carries the network, so it is read here, not set."
  value       = openstack_networking_network_v2.this.mtu
}
