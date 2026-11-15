# IDs and addresses depend on the deployment and an apply in CI prints outputs to a public log,
# so every output that carries them is sensitive. scripts/ci-host-setup reads address,
# runner_name, runner_user and cache_mountpoint, and the instance's id, which names the console its
# SSH host key is checked against.

output "address" {
  description = "The CI host's floating address, where scripts/ci-host-setup reaches it over SSH."
  sensitive   = true
  value       = openstack_networking_floatingip_associate_v2.host.floating_ip
}

output "private_address" {
  description = "The CI host's fixed address on the node subnet, which the cluster stack admits to the nodes' APIs given its host number."
  sensitive   = true
  value       = module.host.port.address
}

output "runner_name" {
  description = "Name of the GitHub Actions runner on the CI host, which is also its only label: the CI host's name."
  value       = module.host.name
}

output "runner_user" {
  description = "The unprivileged user the runner runs as."
  value       = var.runner_user
}

output "cache_mountpoint" {
  description = "Where the cache volume is mounted on the CI host, and where the engine keeps its state."
  value       = local.cache_mountpoint
}

output "instance" {
  description = "The CI host as the vm module describes it: its id, name, flavor, boot volume, user data, key pair, port and data volumes."
  sensitive   = true
  value       = module.host
}

output "user_data" {
  description = "The CI host's cloud-config, as rendered. Sensitive for the cache volume's ID only: it holds no secret."
  sensitive   = true
  value       = local.user_data
}

output "security_group" {
  description = "The CI host's security group: its ID, whether the cloud's default rules were deleted, and every rule in it."
  sensitive   = true
  value = {
    id                   = openstack_networking_secgroup_v2.host.id
    delete_default_rules = openstack_networking_secgroup_v2.host.delete_default_rules
    rules = [
      for rule in concat(values(openstack_networking_secgroup_rule_v2.ssh), values(openstack_networking_secgroup_rule_v2.egress)) : {
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

output "floating_ip" {
  description = "The CI host's floating IP, the external network it comes from, and the floating IP and port its association joins."
  sensitive   = true
  value = {
    address = openstack_networking_floatingip_v2.host.address
    pool    = openstack_networking_floatingip_v2.host.pool
    association = {
      floating_ip = openstack_networking_floatingip_associate_v2.host.floating_ip
      port_id     = openstack_networking_floatingip_associate_v2.host.port_id
    }
  }
}

output "cache_volume" {
  description = "The cache volume: its ID, name, size in GiB and volume type, and the instance and volume its attachment joins."
  sensitive   = true
  value = {
    id          = openstack_blockstorage_volume_v3.cache.id
    name        = openstack_blockstorage_volume_v3.cache.name
    size        = openstack_blockstorage_volume_v3.cache.size
    volume_type = openstack_blockstorage_volume_v3.cache.volume_type
    attachment = {
      instance_id = openstack_compute_volume_attach_v2.cache.instance_id
      volume_id   = openstack_compute_volume_attach_v2.cache.volume_id
    }
  }
}
