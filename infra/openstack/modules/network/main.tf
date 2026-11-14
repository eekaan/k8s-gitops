resource "openstack_networking_network_v2" "this" {
  name                  = var.name
  admin_state_up        = true
  port_security_enabled = var.port_security
  tags                  = var.tags
}

resource "openstack_networking_subnet_v2" "this" {
  name            = var.name
  network_id      = openstack_networking_network_v2.this.id
  cidr            = var.cidr
  ip_version      = 4
  enable_dhcp     = true
  no_gateway      = !var.gateway
  dns_nameservers = var.dns_nameservers
  tags            = var.tags

  # Neutron assigns addresses only from the pool; the rest of the range is left for addresses
  # set explicitly on ports.
  allocation_pool {
    start = cidrhost(var.cidr, var.dhcp_range[0])
    end   = cidrhost(var.cidr, var.dhcp_range[1])
  }
}
