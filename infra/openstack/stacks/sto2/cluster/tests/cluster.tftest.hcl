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

  # Two networks, one of them listed twice: Neutron refuses a rule that already exists, so each
  # network must get its rules once.
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

# A mocked attribute has the same value in every instance of a resource. Each node's port and
# floating IP get their own, so a node wired to another node's port or address cannot pass.
override_resource {
  target = module.nodes.module.node["lab-cp-1"].openstack_networking_port_v2.this
  values = { id = "port-cp-1" }
}

override_resource {
  target = module.nodes.module.node["lab-cp-2"].openstack_networking_port_v2.this
  values = { id = "port-cp-2" }
}

override_resource {
  target = module.nodes.module.node["lab-cp-3"].openstack_networking_port_v2.this
  values = { id = "port-cp-3" }
}

override_resource {
  target = module.nodes.module.node["lab-w-1"].openstack_networking_port_v2.this
  values = { id = "port-w-1" }
}

override_resource {
  target = module.nodes.module.node["lab-w-2"].openstack_networking_port_v2.this
  values = { id = "port-w-2" }
}

override_resource {
  target = module.nodes.module.node["lab-w-3"].openstack_networking_port_v2.this
  values = { id = "port-w-3" }
}

override_resource {
  target = module.nodes.openstack_networking_floatingip_v2.node["lab-cp-1"]
  values = { address = "203.0.113.101" }
}

override_resource {
  target = module.nodes.openstack_networking_floatingip_v2.node["lab-cp-2"]
  values = { address = "203.0.113.102" }
}

override_resource {
  target = module.nodes.openstack_networking_floatingip_v2.node["lab-cp-3"]
  values = { address = "203.0.113.103" }
}

override_resource {
  target = module.nodes.openstack_networking_floatingip_v2.node["lab-w-1"]
  values = { address = "203.0.113.111" }
}

override_resource {
  target = module.nodes.openstack_networking_floatingip_v2.node["lab-w-2"]
  values = { address = "203.0.113.112" }
}

override_resource {
  target = module.nodes.openstack_networking_floatingip_v2.node["lab-w-3"]
  values = { address = "203.0.113.113" }
}

run "three_control_planes_and_three_workers_are_planned" {
  command = plan

  assert {
    condition = { for name, node in output.nodes : name => node.role } == {
      "lab-cp-1" = "controlplane"
      "lab-cp-2" = "controlplane"
      "lab-cp-3" = "controlplane"
      "lab-w-1"  = "worker"
      "lab-w-2"  = "worker"
      "lab-w-3"  = "worker"
    }
    error_message = "The nodes must be the control planes lab-cp-1 to lab-cp-3 and the workers lab-w-1 to lab-w-3."
  }

  assert {
    condition = { for name, instance in output.instances : name => instance.flavor } == {
      "lab-cp-1" = "b.4c8gb"
      "lab-cp-2" = "b.4c8gb"
      "lab-cp-3" = "b.4c8gb"
      "lab-w-1"  = "b.6c16gb"
      "lab-w-2"  = "b.6c16gb"
      "lab-w-3"  = "b.6c16gb"
    }
    error_message = "Control planes must have the flavor b.4c8gb and workers b.6c16gb."
  }

  assert {
    condition = length(output.instances) == 6 && alltrue([
      for instance in values(output.instances) : instance.boot_volume == {
        source_type           = "image"
        image_id              = "talos-image-fixture"
        destination_type      = "volume"
        size                  = 40
        boot_index            = 0
        delete_on_termination = true
      }
    ])
    error_message = "Every node must boot from a 40 GB volume made from the plumbing stack's Talos image and deleted with the instance."
  }

  assert {
    condition = output.controlplane_port_ids == {
      "lab-cp-1" = "port-cp-1"
      "lab-cp-2" = "port-cp-2"
      "lab-cp-3" = "port-cp-3"
    }
    error_message = "The control planes' port IDs must be those of the three control planes' ports."
  }
}

run "nodes_get_fixed_addresses_below_the_dhcp_pool" {
  command = plan

  assert {
    condition = { for name, node in output.nodes : name => node.private_address } == {
      "lab-cp-1" = "192.0.2.10"
      "lab-cp-2" = "192.0.2.11"
      "lab-cp-3" = "192.0.2.12"
      "lab-w-1"  = "192.0.2.20"
      "lab-w-2"  = "192.0.2.21"
      "lab-w-3"  = "192.0.2.22"
    }
    error_message = "Control planes must sit at host numbers 10 to 12 and workers at 20 to 22 of the node subnet, below its DHCP pool."
  }

  assert {
    condition = length(output.instances) == 6 && alltrue([
      for instance in values(output.instances) :
      instance.port.network_id == "node-network-fixture" && instance.port.subnet_id == "node-subnet-fixture"
    ])
    error_message = "Every node's port must be on the plumbing stack's node network and subnet."
  }

  assert {
    condition = output.controlplane_addresses == {
      "lab-cp-1" = "192.0.2.10"
      "lab-cp-2" = "192.0.2.11"
      "lab-cp-3" = "192.0.2.12"
    }
    error_message = "The control planes' addresses must be the three control planes' fixed addresses."
  }
}

run "instances_carry_no_user_data" {
  command = plan

  assert {
    condition     = length(output.instances) == 6 && alltrue([for instance in values(output.instances) : instance.user_data == null])
    error_message = "No instance may carry user data: machine configuration goes over the Talos API."
  }
}

run "the_apis_are_open_only_to_the_allowlist_and_the_clusters_own_floating_addresses" {
  command = plan

  assert {
    condition = toset([
      for rule in output.security_group.ingress_rules : {
        direction = rule.direction
        ethertype = rule.ethertype
        protocol  = rule.protocol
        ports     = rule.port_range_min == null && rule.port_range_max == null ? "all" : "${rule.port_range_min}-${rule.port_range_max}"
        source    = rule.remote_group_id != null && rule.remote_group_id == output.security_group.id ? "the group" : rule.remote_ip_prefix
      }
      ]) == toset(concat(
      [for ethertype in ["IPv4", "IPv6"] : {
        direction = "ingress"
        ethertype = ethertype
        protocol  = null
        ports     = "all"
        source    = "the group"
      }],
      [for pair in setproduct(["50000", "6443"], [
        "198.51.100.0/24",
        "203.0.113.192/26",
        "203.0.113.101/32",
        "203.0.113.102/32",
        "203.0.113.103/32",
        "203.0.113.111/32",
        "203.0.113.112/32",
        "203.0.113.113/32",
        ]) : {
        direction = "ingress"
        ethertype = "IPv4"
        protocol  = "tcp"
        ports     = "${pair[0]}-${pair[0]}"
        source    = pair[1]
      }],
      [{
        direction = "ingress"
        ethertype = "IPv4"
        protocol  = "tcp"
        ports     = "6443-6443"
        source    = "192.0.2.0/24"
      }],
    ))
    error_message = "Ingress must be everything from the group itself, and from outside it only TCP 50000 and 6443 from each allowlisted network and each node's floating address, and TCP 6443 from the node subnet."
  }

  assert {
    condition     = length(output.security_group.ingress_rules) == 19
    error_message = "There must be one rule per ethertype within the group, one per API port and source, and one for the Kubernetes API from the node subnet, none twice."
  }

  assert {
    condition     = alltrue([for rule in output.security_group.ingress_rules : rule.security_group_id == output.security_group.id])
    error_message = "Every rule must belong to the nodes' security group."
  }

  assert {
    condition = length(output.instances) == 6 && alltrue([
      for instance in values(output.instances) :
      instance.port.port_security_enabled == true && instance.port.security_group_ids == toset([output.security_group.id])
    ])
    error_message = "Every node's port must have port security on and the nodes' security group as its only group."
  }
}

run "an_empty_or_malformed_allowlist_is_rejected" {
  command = plan

  variables {
    api_allowed_cidrs = ["198.51.100.0/24", "not-a-cidr"]
  }

  expect_failures = [var.api_allowed_cidrs]
}

# The same scenario with an empty allowlist. A scenario is proved by one run of its name, so this
# second case is named apart from it.
run "_an_empty_allowlist_is_rejected" {
  command = plan

  variables {
    api_allowed_cidrs = []
  }

  expect_failures = [var.api_allowed_cidrs]
}

run "every_node_has_its_own_floating_ip" {
  command = plan

  assert {
    condition = { for name, ip in output.floating_ips : name => ip.address } == {
      "lab-cp-1" = "203.0.113.101"
      "lab-cp-2" = "203.0.113.102"
      "lab-cp-3" = "203.0.113.103"
      "lab-w-1"  = "203.0.113.111"
      "lab-w-2"  = "203.0.113.112"
      "lab-w-3"  = "203.0.113.113"
    }
    error_message = "Every node must have a floating IP of its own."
  }

  assert {
    condition     = length(output.floating_ips) == 6 && alltrue([for ip in values(output.floating_ips) : ip.pool == "external-network-fixture"])
    error_message = "Floating IPs must come from the external network the plumbing stack's router is on."
  }

  assert {
    condition = { for name, ip in output.floating_ips : name => ip.association } == {
      "lab-cp-1" = { floating_ip = "203.0.113.101", port_id = "port-cp-1" }
      "lab-cp-2" = { floating_ip = "203.0.113.102", port_id = "port-cp-2" }
      "lab-cp-3" = { floating_ip = "203.0.113.103", port_id = "port-cp-3" }
      "lab-w-1"  = { floating_ip = "203.0.113.111", port_id = "port-w-1" }
      "lab-w-2"  = { floating_ip = "203.0.113.112", port_id = "port-w-2" }
      "lab-w-3"  = { floating_ip = "203.0.113.113", port_id = "port-w-3" }
    }
    error_message = "Each floating IP must be associated with its own node's port."
  }

  assert {
    condition = { for name, node in output.nodes : name => { floating_address = node.floating_address, port_id = node.port_id } } == {
      "lab-cp-1" = { floating_address = "203.0.113.101", port_id = "port-cp-1" }
      "lab-cp-2" = { floating_address = "203.0.113.102", port_id = "port-cp-2" }
      "lab-cp-3" = { floating_address = "203.0.113.103", port_id = "port-cp-3" }
      "lab-w-1"  = { floating_address = "203.0.113.111", port_id = "port-w-1" }
      "lab-w-2"  = { floating_address = "203.0.113.112", port_id = "port-w-2" }
      "lab-w-3"  = { floating_address = "203.0.113.113", port_id = "port-w-3" }
    }
    error_message = "The nodes output must give each node its own floating address and port."
  }
}

run "nodes_share_one_soft_anti_affinity_group" {
  command = plan

  assert {
    condition     = output.server_group.policies == tolist(["soft-anti-affinity"])
    error_message = "The server group must have the soft-anti-affinity policy, and only it."
  }

  assert {
    condition     = length(output.instances) == 6 && alltrue([for instance in values(output.instances) : instance.server_group_id == output.server_group.id])
    error_message = "Every node must be scheduled into the one server group."
  }
}
