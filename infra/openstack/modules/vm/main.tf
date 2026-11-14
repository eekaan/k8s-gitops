# One instance that boots from a volume made from an image, with one port on a fixed address and
# optional data volumes. It takes no user data: anything an instance is given as user data ends
# up in tofu state and in the cloud's metadata service.

resource "openstack_networking_port_v2" "this" {
  name           = var.name
  network_id     = var.network_id
  admin_state_up = true
  # The security groups filter only ports with port security, which also keeps the port from
  # carrying any address but its own and the allowed address pairs.
  port_security_enabled = true
  security_group_ids    = var.security_group_ids
  tags                  = var.tags

  fixed_ip {
    subnet_id  = var.subnet_id
    ip_address = var.fixed_ip
  }

  dynamic "allowed_address_pairs" {
    for_each = toset(var.allowed_address_pairs)
    content {
      ip_address = allowed_address_pairs.value
    }
  }
}

resource "openstack_compute_instance_v2" "this" {
  name        = var.name
  flavor_name = var.flavor
  tags        = var.tags

  block_device {
    uuid                  = var.image_id
    source_type           = "image"
    destination_type      = "volume"
    volume_size           = var.root_volume_size_gb
    volume_type           = var.volume_type
    boot_index            = 0
    delete_on_termination = true
  }

  network {
    port = openstack_networking_port_v2.this.id
  }

  dynamic "scheduler_hints" {
    for_each = var.server_group_id == null ? [] : [var.server_group_id]
    content {
      group = scheduler_hints.value
    }
  }

  lifecycle {
    # A new image must not replace a running node: Talos nodes are upgraded through the Talos API,
    # and replacing a control plane's disk would destroy its etcd data. A node is replaced on
    # purpose with tofu apply -replace.
    ignore_changes = [block_device]
  }
}

resource "openstack_blockstorage_volume_v3" "data" {
  for_each = var.data_volumes

  name        = "${var.name}-${each.key}"
  size        = each.value
  volume_type = var.volume_type
  # A data volume stays attached for the instance's life, so it grows while attached.
  enable_online_resize = true
}

resource "openstack_compute_volume_attach_v2" "data" {
  for_each = var.data_volumes

  instance_id = openstack_compute_instance_v2.this.id
  volume_id   = openstack_blockstorage_volume_v3.data[each.key].id
}
