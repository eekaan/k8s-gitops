output "nodes" {
  description = "Per node name: its role (controlplane or worker), fixed private address, floating address and port ID."
  value = { for k, n in local.nodes : k => {
    role             = n.role
    private_address  = module.node[k].port.address
    floating_address = openstack_networking_floatingip_associate_v2.node[k].floating_ip
    port_id          = module.node[k].port.id
  } }
}

output "controlplane_port_ids" {
  description = "Port ID of each control plane, by node name."
  value       = { for k, n in local.nodes : k => module.node[k].port.id if n.role == "controlplane" }
}

output "controlplane_addresses" {
  description = "Fixed private address of each control plane, by node name."
  value       = { for k, n in local.nodes : k => module.node[k].port.address if n.role == "controlplane" }
}

output "instances" {
  description = "Per node name: the instance as the vm module describes it, with its flavor, boot volume, user data, server group and port."
  value       = module.node
}

output "security_group" {
  description = "The nodes' security group: its ID and every ingress rule this module puts in it. Sensitive, as the rules hold the operator allowlist."
  sensitive   = true
  value = {
    id = openstack_networking_secgroup_v2.this.id
    ingress_rules = [
      for rule in concat(
        values(openstack_networking_secgroup_rule_v2.intra),
        values(openstack_networking_secgroup_rule_v2.api),
        values(openstack_networking_secgroup_rule_v2.hairpin),
        [openstack_networking_secgroup_rule_v2.api_from_subnet],
        ) : {
        security_group_id = rule.security_group_id
        direction         = rule.direction
        ethertype         = rule.ethertype
        protocol          = rule.protocol
        port_range_min    = rule.port_range_min
        port_range_max    = rule.port_range_max
        remote_ip_prefix  = rule.remote_ip_prefix
        remote_group_id   = rule.remote_group_id
      }
    ]
  }
}

output "server_group" {
  description = "The server group every node is scheduled into: its ID and policies."
  value = {
    id       = openstack_compute_servergroup_v2.this.id
    policies = openstack_compute_servergroup_v2.this.policies
  }
}

output "floating_ips" {
  description = "Per node name: its floating IP, the external network it comes from, and the floating IP and port its association joins."
  value = { for k, ip in openstack_networking_floatingip_v2.node : k => {
    address = ip.address
    pool    = ip.pool
    association = {
      floating_ip = openstack_networking_floatingip_associate_v2.node[k].floating_ip
      port_id     = openstack_networking_floatingip_associate_v2.node[k].port_id
    }
  } }
}
