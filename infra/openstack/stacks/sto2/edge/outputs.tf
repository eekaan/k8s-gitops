# IDs and addresses depend on the deployment and an apply in CI prints outputs to a public log, so
# every output that carries them is sensitive. scripts/edge-check and scripts/edge-routes read
# addresses and, from instances, each edge's instance id, which names the console its SSH host key
# is checked against.

output "names" {
  description = "The edges' names, in order."
  value       = [for key in sort(keys(local.edges)) : module.edge[key].name]
}

output "addresses" {
  description = "The edges' floating addresses, in order: what DNS names publish, and where scripts/edge-check reaches them over SSH."
  sensitive   = true
  value       = [for key in sort(keys(local.edges)) : openstack_networking_floatingip_associate_v2.edge[key].floating_ip]
}

output "private_addresses" {
  description = "The edges' fixed addresses on the node subnet, in order: where the workers' sessions go."
  sensitive   = true
  value       = [for key in sort(keys(local.edges)) : module.edge[key].port.address]
}

output "instances" {
  description = "Each edge as the vm module describes it, by number: its name, flavor, boot volume, user data, key pair, server group and port."
  sensitive   = true
  value       = module.edge
}

output "config" {
  description = "Each edge's rendered configuration, by number: the FRR configuration, the nftables rules, the kernel settings and the SSH daemon's settings."
  sensitive   = true
  value       = local.config
}

output "user_data" {
  description = "Each edge's cloud-config, as rendered, by number. It holds the configuration and no secret."
  sensitive   = true
  value       = local.user_data
}

output "server_group" {
  description = "The server group both edges are scheduled into: its ID and policies."
  value = {
    id       = openstack_compute_servergroup_v2.edges.id
    policies = openstack_compute_servergroup_v2.edges.policies
  }
  sensitive = true
}

output "security_group" {
  description = "The edges' security group: its ID, whether the cloud's default rules were deleted, and every rule in it."
  sensitive   = true
  value = {
    id                   = openstack_networking_secgroup_v2.edge.id
    delete_default_rules = openstack_networking_secgroup_v2.edge.delete_default_rules
    rules = [
      for rule in concat(
        values(openstack_networking_secgroup_rule_v2.ssh),
        values(openstack_networking_secgroup_rule_v2.public),
        [for key in sort(keys(openstack_networking_secgroup_rule_v2.bgp)) : openstack_networking_secgroup_rule_v2.bgp[key]],
        [openstack_networking_secgroup_rule_v2.path_mtu],
        values(openstack_networking_secgroup_rule_v2.egress),
        ) : {
        security_group_id = rule.security_group_id
        direction         = rule.direction
        ethertype         = rule.ethertype
        protocol          = rule.protocol
        port_range_min    = rule.port_range_min
        port_range_max    = rule.port_range_max
        remote_ip_prefix  = rule.remote_ip_prefix
      }
    ]
  }
}

output "floating_ips" {
  description = "Each edge's floating IP by number: the address, the external network it comes from, and the floating IP and port its association joins."
  sensitive   = true
  value = {
    for key in keys(local.edges) : key => {
      address = openstack_networking_floatingip_v2.edge[key].address
      pool    = openstack_networking_floatingip_v2.edge[key].pool
      association = {
        floating_ip = openstack_networking_floatingip_associate_v2.edge[key].floating_ip
        port_id     = openstack_networking_floatingip_associate_v2.edge[key].port_id
      }
    }
  }
}
