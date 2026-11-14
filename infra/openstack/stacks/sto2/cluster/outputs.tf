# IDs and addresses depend on the deployment and an apply in CI prints outputs to a public log,
# so every output that carries them is sensitive.

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

output "api_endpoint" {
  description = "The Kubernetes API's URL at the load balancer's fixed private address: the cluster endpoint."
  sensitive   = true
  value       = module.api_lb.endpoint
}

output "api_vip_address" {
  description = "The Kubernetes API load balancer's fixed private address on the node subnet."
  sensitive   = true
  value       = module.api_lb.vip_address
}

output "api_floating_address" {
  description = "The floating IP of the Kubernetes API load balancer."
  sensitive   = true
  value       = module.api_lb.floating_address
}

output "api_allowed_cidr_count" {
  description = "Number of networks the Kubernetes API listener admits: the allowlist without duplicates, and the node subnet."
  value       = module.api_lb.allowed_cidr_count
}

output "api_load_balancer" {
  description = "The Kubernetes API load balancer: its ID, provider, subnet, address and VIP port, its listener, pool, members by node name, health monitor and floating IP."
  sensitive   = true
  value       = module.api_lb.load_balancer
}
