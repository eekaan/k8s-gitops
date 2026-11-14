output "endpoint" {
  description = "The Kubernetes API's URL at the load balancer's fixed private address."
  value       = "https://${openstack_lb_loadbalancer_v2.this.vip_address}:${local.api_port}"
}

output "vip_address" {
  description = "The load balancer's fixed private address on the node subnet."
  value       = openstack_lb_loadbalancer_v2.this.vip_address
}

output "floating_address" {
  description = "The floating IP associated with the load balancer's address."
  value       = openstack_networking_floatingip_associate_v2.this.floating_ip
}

output "allowed_cidr_count" {
  description = "Number of networks the listener admits: the allowlist without duplicates, and the node subnet. Not sensitive: the networks themselves are not in it."
  value       = nonsensitive(length(openstack_lb_listener_v2.this.allowed_cidrs))
}

output "load_balancer" {
  description = "The load balancer: its ID, provider, subnet, address and VIP port, its listener, pool, members by node name, health monitor and floating IP. Sensitive, as the listener holds the operator allowlist."
  sensitive   = true
  value = {
    id            = openstack_lb_loadbalancer_v2.this.id
    provider      = openstack_lb_loadbalancer_v2.this.loadbalancer_provider
    vip_subnet_id = openstack_lb_loadbalancer_v2.this.vip_subnet_id
    vip_address   = openstack_lb_loadbalancer_v2.this.vip_address
    vip_port_id   = openstack_lb_loadbalancer_v2.this.vip_port_id
    listener = {
      id              = openstack_lb_listener_v2.this.id
      loadbalancer_id = openstack_lb_listener_v2.this.loadbalancer_id
      protocol        = openstack_lb_listener_v2.this.protocol
      protocol_port   = openstack_lb_listener_v2.this.protocol_port
      allowed_cidrs   = openstack_lb_listener_v2.this.allowed_cidrs
    }
    pool = {
      id          = openstack_lb_pool_v2.this.id
      listener_id = openstack_lb_pool_v2.this.listener_id
      protocol    = openstack_lb_pool_v2.this.protocol
      lb_method   = openstack_lb_pool_v2.this.lb_method
    }
    members = { for k, m in openstack_lb_member_v2.this : k => {
      pool_id       = m.pool_id
      subnet_id     = m.subnet_id
      address       = m.address
      protocol_port = m.protocol_port
    } }
    monitor = {
      pool_id          = openstack_lb_monitor_v2.this.pool_id
      type             = openstack_lb_monitor_v2.this.type
      delay            = openstack_lb_monitor_v2.this.delay
      timeout          = openstack_lb_monitor_v2.this.timeout
      max_retries      = openstack_lb_monitor_v2.this.max_retries
      max_retries_down = openstack_lb_monitor_v2.this.max_retries_down
    }
    floating_ip = {
      address = openstack_networking_floatingip_v2.this.address
      pool    = openstack_networking_floatingip_v2.this.pool
      association = {
        floating_ip = openstack_networking_floatingip_associate_v2.this.floating_ip
        port_id     = openstack_networking_floatingip_associate_v2.this.port_id
      }
    }
  }
}
