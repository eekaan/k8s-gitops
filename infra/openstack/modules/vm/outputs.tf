output "id" {
  description = "ID of the instance."
  value       = openstack_compute_instance_v2.this.id
}

output "name" {
  description = "Name of the instance."
  value       = openstack_compute_instance_v2.this.name
}

output "flavor" {
  description = "Flavor name of the instance."
  value       = openstack_compute_instance_v2.this.flavor_name
}

output "user_data" {
  description = "User data of the instance, which this module never sets."
  value       = openstack_compute_instance_v2.this.user_data
}

output "boot_volume" {
  description = "What the instance boots from: the source and image of its boot volume, the volume's size in GB, its boot index and whether it is deleted with the instance."
  value = {
    source_type           = openstack_compute_instance_v2.this.block_device[0].source_type
    image_id              = openstack_compute_instance_v2.this.block_device[0].uuid
    destination_type      = openstack_compute_instance_v2.this.block_device[0].destination_type
    size                  = openstack_compute_instance_v2.this.block_device[0].volume_size
    boot_index            = openstack_compute_instance_v2.this.block_device[0].boot_index
    delete_on_termination = openstack_compute_instance_v2.this.block_device[0].delete_on_termination
  }
}

output "server_group_id" {
  description = "Server group the instance is scheduled into, or null."
  value       = one(openstack_compute_instance_v2.this.scheduler_hints[*].group)
}

output "port" {
  description = "The instance's port: its ID, network, subnet and fixed address, whether port security is on, its security groups and allowed address pairs."
  value = {
    id                    = openstack_networking_port_v2.this.id
    network_id            = openstack_networking_port_v2.this.network_id
    subnet_id             = one(openstack_networking_port_v2.this.fixed_ip).subnet_id
    address               = one(openstack_networking_port_v2.this.fixed_ip).ip_address
    port_security_enabled = openstack_networking_port_v2.this.port_security_enabled
    security_group_ids    = openstack_networking_port_v2.this.security_group_ids
    allowed_address_pairs = [for pair in openstack_networking_port_v2.this.allowed_address_pairs : pair.ip_address]
  }
}

output "data_volumes" {
  description = "Per data volume name: its ID and the device Nova reports it attached as."
  value = { for k, a in openstack_compute_volume_attach_v2.data : k => {
    id     = a.volume_id
    device = a.device
  } }
}
