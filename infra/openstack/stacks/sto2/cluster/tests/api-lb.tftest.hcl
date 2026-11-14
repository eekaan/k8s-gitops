# The provider is mocked and the plumbing stack's state is overridden, so these runs need no
# credentials and read no state.

mock_provider "openstack" {}

variables {
  # Validated as s3 backend settings, never used: the state it points at is overridden below.
  plumbing_state = {
    bucket = "plumbing-fixture"
    key    = "plumbing.tfstate"
    region = "fixture"
  }

  # Two networks, out of order and one of them listed twice: the listener must admit each once.
  api_allowed_cidrs = ["203.0.113.192/26", "198.51.100.0/24", "203.0.113.192/26"]
}

# The plumbing stack's outputs, in the shape it writes them. None of the values is a plumbing
# default, so a value written into this stack instead of read from that state cannot match.
override_data {
  target = data.terraform_remote_state.plumbing
  values = {
    outputs = {
      network = {
        network_id = "node-network-fixture"
        subnet_id  = "node-subnet-fixture"
        cidr       = "192.0.2.0/24"
        dhcp_pool  = { start = "192.0.2.100", end = "192.0.2.200" }
      }
      router = {
        external_network    = "external-network-fixture"
        attached_subnet_ids = { nodes = "node-subnet-fixture" }
      }
      image = {
        id           = "talos-image-fixture"
        schematic_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      }
    }
  }
}

# Values of their own for the attributes the floating IP is wired with, so an association with
# any other port or address cannot pass.
override_resource {
  target = module.api_lb.openstack_lb_loadbalancer_v2.this
  values = { vip_port_id = "port-api-vip" }
}

override_resource {
  target = module.api_lb.openstack_networking_floatingip_v2.this
  values = { address = "203.0.113.50" }
}

run "the_api_has_a_fixed_private_address_known_at_plan_time" {
  command = plan

  assert {
    condition     = output.api_vip_address == "192.0.2.5"
    error_message = "The load balancer's address must be host number 5 of the node subnet."
  }

  assert {
    condition     = output.api_load_balancer.vip_subnet_id == "node-subnet-fixture" && output.api_load_balancer.vip_address == "192.0.2.5"
    error_message = "The load balancer must be on the plumbing stack's node subnet, at that address."
  }

  assert {
    condition     = output.api_endpoint == "https://192.0.2.5:6443"
    error_message = "The endpoint must be the HTTPS URL of the load balancer's address on port 6443."
  }
}

run "the_load_balancer_address_collides_with_no_node" {
  command = plan

  assert {
    condition     = length(output.nodes) == 6 && !contains([for node in values(output.nodes) : node.private_address], output.api_vip_address)
    error_message = "The load balancer's address must differ from every node's fixed address."
  }

  assert {
    condition     = contains([for host in range(1, 100) : cidrhost("192.0.2.0/24", host)], output.api_vip_address)
    error_message = "The load balancer's address must lie on the node subnet below its DHCP pool, which starts at host number 100."
  }
}

run "all_three_control_planes_are_members_on_the_api_port" {
  command = plan

  assert {
    condition = { for name, member in output.api_load_balancer.members : name => { address = member.address, protocol_port = member.protocol_port } } == {
      "lab-cp-1" = { address = "192.0.2.10", protocol_port = 6443 }
      "lab-cp-2" = { address = "192.0.2.11", protocol_port = 6443 }
      "lab-cp-3" = { address = "192.0.2.12", protocol_port = 6443 }
    }
    error_message = "The pool's members must be the three control planes, each at its fixed address on port 6443."
  }

  assert {
    condition = length(output.nodes) == 6 && alltrue([
      for node in values(output.nodes) :
      !contains([for member in values(output.api_load_balancer.members) : member.address], node.private_address) if node.role == "worker"
    ])
    error_message = "No worker may be a member of the pool."
  }

  assert {
    condition = length(output.api_load_balancer.members) == 3 && alltrue([
      for member in values(output.api_load_balancer.members) :
      member.pool_id == output.api_load_balancer.pool.id && member.subnet_id == "node-subnet-fixture"
    ])
    error_message = "Every member must be in the API pool, on the node subnet."
  }

  assert {
    condition     = output.api_load_balancer.pool.protocol == "TCP" && output.api_load_balancer.pool.listener_id == output.api_load_balancer.listener.id
    error_message = "The pool must be a TCP pool behind the API listener."
  }
}

run "the_listener_admits_only_the_allowlist_and_the_node_subnet" {
  command = plan

  assert {
    condition     = output.api_load_balancer.listener.protocol == "TCP" && output.api_load_balancer.listener.protocol_port == 6443
    error_message = "The listener must be TCP on port 6443."
  }

  assert {
    condition     = output.api_load_balancer.listener.loadbalancer_id == output.api_load_balancer.id
    error_message = "The listener must be on the API load balancer."
  }

  assert {
    condition     = toset(output.api_load_balancer.listener.allowed_cidrs) == toset(["198.51.100.0/24", "203.0.113.192/26", "192.0.2.0/24"])
    error_message = "The listener must admit the two allowlisted networks and the node subnet, and nothing else."
  }

  assert {
    condition     = length(output.api_load_balancer.listener.allowed_cidrs) == 3 && output.api_allowed_cidr_count == 3
    error_message = "The listener must list each network once, and the count output must say how many it lists."
  }
}

run "the_control_planes_accept_the_api_port_from_the_node_subnet" {
  command = plan

  assert {
    condition = [
      for rule in output.security_group.ingress_rules : {
        direction = rule.direction
        ethertype = rule.ethertype
        protocol  = rule.protocol
        ports     = rule.port_range_min == null && rule.port_range_max == null ? "all" : "${rule.port_range_min}-${rule.port_range_max}"
      } if rule.remote_ip_prefix == "192.0.2.0/24"
      ] == [{
        direction = "ingress"
        ethertype = "IPv4"
        protocol  = "tcp"
        ports     = "6443-6443"
    }]
    error_message = "The nodes' security group must admit TCP 6443 from the node subnet, and nothing else from it."
  }

  assert {
    condition = length(output.nodes) == 6 && alltrue([
      for rule in output.security_group.ingress_rules :
      (rule.remote_group_id != null && rule.remote_group_id == output.security_group.id) || contains(concat(
        ["198.51.100.0/24", "203.0.113.192/26", "192.0.2.0/24"],
        [for node in values(output.nodes) : "${node.floating_address}/32"],
      ), rule.remote_ip_prefix)
    ])
    error_message = "Besides the group itself, the nodes' security group may admit only the allowlisted networks, the nodes' floating addresses and the node subnet."
  }
}

run "the_load_balancer_has_a_floating_ip" {
  command = plan

  assert {
    condition     = output.api_load_balancer.floating_ip.pool == "external-network-fixture"
    error_message = "The load balancer's floating IP must come from the external network the plumbing stack's router is on."
  }

  assert {
    condition     = output.api_load_balancer.floating_ip.association == { floating_ip = "203.0.113.50", port_id = "port-api-vip" }
    error_message = "The floating IP must be associated with the load balancer's VIP port."
  }

  assert {
    condition     = output.api_floating_address == "203.0.113.50"
    error_message = "The api_floating_address output must be the load balancer's floating IP."
  }
}
