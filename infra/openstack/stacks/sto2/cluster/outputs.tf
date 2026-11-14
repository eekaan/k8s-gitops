# IDs and addresses depend on the deployment and an apply in CI prints outputs to a public log,
# so every output is sensitive.

output "nodes" {
  description = "Per node name: its role (controlplane or worker), fixed private address, floating address and port ID."
  sensitive   = true
  value       = module.nodes.nodes
}

output "controlplane_port_ids" {
  description = "Port ID of each control plane, by node name."
  sensitive   = true
  value       = module.nodes.controlplane_port_ids
}

output "controlplane_addresses" {
  description = "Fixed private address of each control plane, by node name."
  sensitive   = true
  value       = module.nodes.controlplane_addresses
}

output "instances" {
  description = "Per node name: the instance's flavor, boot volume, user data, server group and port."
  sensitive   = true
  value       = module.nodes.instances
}

output "security_group" {
  description = "The nodes' security group: its ID and every ingress rule in it."
  sensitive   = true
  value       = module.nodes.security_group
}

output "server_group" {
  description = "The server group every node is scheduled into: its ID and policies."
  sensitive   = true
  value       = module.nodes.server_group
}

output "floating_ips" {
  description = "Per node name: its floating IP, the external network it comes from, and the floating IP and port its association joins."
  sensitive   = true
  value       = module.nodes.floating_ips
}
