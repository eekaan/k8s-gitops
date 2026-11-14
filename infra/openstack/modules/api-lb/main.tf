# The Kubernetes API of a cluster's control planes behind one Octavia TCP load balancer, at a
# fixed address on the node subnet and with a floating IP. TLS passes through to the API servers
# untouched; the Talos API is not balanced, as every node is reached directly.

locals {
  api_port = 6443

  # Set rather than assigned by the cloud, so the cluster endpoint is known before the load
  # balancer exists.
  vip_address = cidrhost(var.network.cidr, var.vip_host)

  # The nodes reach the API through the load balancer's private address while they join, from
  # the node subnet. Sorted and without duplicates, so the same networks given in another order
  # or twice change nothing.
  allowed_cidrs = sort(distinct(concat(var.allowed_cidrs, [var.network.cidr])))
}

resource "openstack_lb_loadbalancer_v2" "this" {
  name                  = "${var.name}-api"
  vip_subnet_id         = var.network.subnet_id
  vip_address           = local.vip_address
  loadbalancer_provider = var.loadbalancer_provider
  flavor_id             = var.flavor_id
  tags                  = var.tags
}

# Octavia refuses every source outside allowed_cidrs once the list is set.
resource "openstack_lb_listener_v2" "this" {
  name            = "${var.name}-api"
  loadbalancer_id = openstack_lb_loadbalancer_v2.this.id
  protocol        = "TCP"
  protocol_port   = local.api_port
  allowed_cidrs   = local.allowed_cidrs
  tags            = var.tags
}

resource "openstack_lb_pool_v2" "this" {
  name        = "${var.name}-api"
  listener_id = openstack_lb_listener_v2.this.id
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
  tags        = var.tags
}

# The API server accepts a TCP connection without a client certificate, so a TCP check needs no
# credential and sees a control plane as soon as its API server listens.
resource "openstack_lb_monitor_v2" "this" {
  name             = "${var.name}-api"
  pool_id          = openstack_lb_pool_v2.this.id
  type             = "TCP"
  delay            = var.monitor_delay
  timeout          = var.monitor_timeout
  max_retries      = var.monitor_max_retries
  max_retries_down = var.monitor_max_retries_down
}

resource "openstack_lb_member_v2" "this" {
  for_each = var.members

  name          = each.key
  pool_id       = openstack_lb_pool_v2.this.id
  subnet_id     = var.network.subnet_id
  address       = each.value
  protocol_port = local.api_port
  tags          = var.tags
}

# The address is a resource of its own, so the load balancer keeps its floating IP when it is
# replaced.
resource "openstack_networking_floatingip_v2" "this" {
  pool = var.external_network
  tags = var.tags
}

resource "openstack_networking_floatingip_associate_v2" "this" {
  floating_ip = openstack_networking_floatingip_v2.this.address
  port_id     = openstack_lb_loadbalancer_v2.this.vip_port_id
}
