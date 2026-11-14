data "openstack_networking_network_v2" "external" {
  name     = var.external_network
  external = true
}

resource "openstack_networking_router_v2" "this" {
  name                = var.name
  external_network_id = data.openstack_networking_network_v2.external.id
  tags                = var.tags
}

resource "openstack_networking_router_interface_v2" "this" {
  for_each = var.subnet_ids

  router_id = openstack_networking_router_v2.this.id
  subnet_id = each.value
}
