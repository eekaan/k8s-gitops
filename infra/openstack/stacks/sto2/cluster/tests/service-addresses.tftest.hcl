# What the node network does for Services announced over BGP: the workers' ports carry the service
# range, and the edge routers reach the workers on the service ports. The provider is mocked and the
# plumbing stack's state is overridden, so these runs need no credentials and read no state.
#
# A mocked provider plans no replacement of its own. The provider updates a port's allowed address
# pairs and security groups in place, as neither attribute forces a new port (its port resource,
# v3.4.0); whether a running worker's port is replaced shows only in the real plan.

mock_provider "openstack" {}

variables {
  # Validated as s3 backend settings, never used: the state it points at is overridden below.
  plumbing_state = {
    bucket = "plumbing-fixture"
    key    = "plumbing.tfstate"
    region = "fixture"
  }

  api_allowed_cidrs = ["198.51.100.0/24"]
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
      bgp = {
        cluster_asn    = 64496
        edge_asn       = 64497
        edge_addresses = ["192.0.2.7", "192.0.2.8"]
        service_range  = "203.0.113.16/28"
      }
    }
  }
}

# A mocked attribute has the same value in every instance of a resource, so each group gets an ID of
# its own, and a port in the wrong group cannot pass.
override_resource {
  target = module.nodes.openstack_networking_secgroup_v2.this
  values = { id = "nodes-group" }
}

override_resource {
  target = module.nodes.openstack_networking_secgroup_v2.workers
  values = { id = "workers-group" }
}

run "the_edge_addresses_and_the_service_range_overlap_nothing" {
  command = plan

  variables {
    edges    = ["192.0.2.7", "192.0.2.8"]
    range    = "203.0.113.16/28"
    node_net = "192.0.2.0/24"
  }

  # talman.yaml carries the numbers on to cluster-config, from which the Cilium objects take them.
  assert {
    condition = yamldecode(output.talman_yaml).values.serviceRange == var.range && yamldecode(output.talman_yaml).values.bgp == {
      clusterASN    = 64496
      edgeASN       = 64497
      edgeAddresses = var.edges
    }
    error_message = "talman.yaml must carry the service range, both AS numbers and both edge addresses as the plumbing stack's state gives them."
  }

  assert {
    condition = length(distinct(var.edges)) == 2 && alltrue([
      for edge in var.edges : cidrcontains(var.node_net, edge) && edge != cidrhost(var.node_net, 1) &&
      !contains([for host in range(100, 201) : cidrhost(var.node_net, host)], edge)
    ])
    error_message = "The two edge addresses must differ, lie on the node subnet, and be neither the gateway's nor in the DHCP pool."
  }

  assert {
    condition = length(output.nodes) == 6 && length(setintersection(
      toset(var.edges),
      toset(concat([for node in values(output.nodes) : node.private_address], [output.api_vip_address])),
    )) == 0
    error_message = "No node and not the API load balancer may hold an edge address."
  }

  assert {
    condition = alltrue([
      for net in [var.node_net, var.pod_subnet, var.service_subnet] :
      !cidrcontains(net, cidrhost(var.range, 0)) && !cidrcontains(var.range, cidrhost(net, 0))
    ]) && alltrue([for edge in var.edges : !cidrcontains(var.range, edge)])
    error_message = "The service range must overlap neither the node, the pod nor the service subnet, and hold no edge address."
  }
}

# Each collision the scenario above rules out is refused when planned. A scenario is proved by one
# run of its name, so these cases are named apart from it.
run "_a_service_range_overlapping_the_pod_subnet_is_rejected" {
  command = plan

  variables {
    pod_subnet = "203.0.113.0/24"
    # One node, as a /24 pod subnet holds a /24 for one only.
    controlplane_count = 1
    worker_count       = 0
  }

  expect_failures = [var.pod_subnet]
}

run "_a_service_range_overlapping_the_service_subnet_is_rejected" {
  command = plan

  variables {
    service_subnet = "203.0.113.0/26"
  }

  expect_failures = [var.service_subnet]
}

run "_an_edge_address_on_a_node_is_rejected" {
  command = plan

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
        bgp = {
          cluster_asn    = 64496
          edge_asn       = 64497
          edge_addresses = ["192.0.2.7", "192.0.2.20"]
          service_range  = "203.0.113.16/28"
        }
      }
    }
  }

  expect_failures = [output.nodes]
}

run "_an_edge_address_on_the_api_load_balancer_is_rejected" {
  command = plan

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
        bgp = {
          cluster_asn    = 64496
          edge_asn       = 64497
          edge_addresses = ["192.0.2.5", "192.0.2.8"]
          service_range  = "203.0.113.16/28"
        }
      }
    }
  }

  expect_failures = [output.nodes]
}

# The CI host takes a fixed address below the DHCP pool too, by host number: never an edge router's.
run "_a_ci_host_number_on_an_edge_router_is_rejected" {
  command = plan

  variables {
    ci_host_number = 7
  }

  expect_failures = [var.ci_host_number]
}

# The CI host's default host number, beside the edge routers' default ones, plans.
run "_the_ci_hosts_default_number_lies_apart_from_the_edge_routers" {
  command = plan

  variables {
    ci_host_number = 6
  }

  assert {
    condition     = length(output.nodes) == 6
    error_message = "The cluster stack must plan with the CI host at host number 6 beside the edge routers at 7 and 8."
  }
}

run "workers_may_receive_and_answer_for_the_service_range_and_control_planes_may_not" {
  command = plan

  assert {
    condition = { for name, instance in output.instances : name => join(" ", sort(instance.port.allowed_address_pairs)) if output.nodes[name].role == "worker" } == {
      "lab-w-1" = "203.0.113.16/28"
      "lab-w-2" = "203.0.113.16/28"
      "lab-w-3" = "203.0.113.16/28"
    }
    error_message = "Every worker's port must list the service range, and only it, as an allowed address pair."
  }

  assert {
    condition     = toset([for name, instance in output.instances : name if output.nodes[name].role == "controlplane" && length(instance.port.allowed_address_pairs) == 0]) == toset(["lab-cp-1", "lab-cp-2", "lab-cp-3"])
    error_message = "No control plane's port may list an allowed address pair."
  }
}

run "the_edge_routers_can_reach_the_workers_for_bgp_and_for_service_traffic_and_nothing_else_is_opened" {
  command = plan

  assert {
    condition = toset([
      for rule in output.worker_security_group.ingress_rules : {
        direction = rule.direction
        ethertype = rule.ethertype
        protocol  = rule.protocol
        ports     = "${rule.port_range_min}-${rule.port_range_max}"
        source    = rule.remote_ip_prefix
      }
      ]) == toset([
      for pair in setproduct([80, 443], ["192.0.2.7/32", "192.0.2.8/32"]) : {
        direction = "ingress"
        ethertype = "IPv4"
        protocol  = "tcp"
        ports     = "${pair[0]}-${pair[0]}"
        source    = pair[1]
      }
    ]) && length(output.worker_security_group.ingress_rules) == 4
    error_message = "The workers' own group must admit TCP 80 and 443 from each edge address, once each, and nothing else."
  }

  assert {
    condition     = alltrue([for rule in output.worker_security_group.ingress_rules : rule.security_group_id == "workers-group"])
    error_message = "Every rule for the edge routers must belong to the workers' own group."
  }

  assert {
    condition     = output.worker_security_group.delete_default_rules == true && output.security_group.delete_default_rules == false
    error_message = "The workers' own group must hold no egress rule of its own, and the nodes' group must keep Neutron's default egress rules, through which each worker opens its BGP sessions."
  }

  assert {
    condition = { for name, instance in output.instances : name => join(" ", sort(instance.port.security_group_ids)) } == {
      "lab-cp-1" = "nodes-group"
      "lab-cp-2" = "nodes-group"
      "lab-cp-3" = "nodes-group"
      "lab-w-1"  = "nodes-group workers-group"
      "lab-w-2"  = "nodes-group workers-group"
      "lab-w-3"  = "nodes-group workers-group"
    }
    error_message = "Every worker's port must carry the nodes' group and the workers' own group, and every control plane's the nodes' group only."
  }

  # Everything an edge router reaches, from whichever rule of either group: a rule whose prefix
  # holds an edge address admits that edge router, the node subnet's included. The rule within the
  # nodes' group names the group, not a prefix; a mocked prefix is not a network and holds nothing.
  assert {
    condition = toset(concat(
      [
        for rule in output.security_group.ingress_rules : "nodes ${coalesce(rule.protocol, "any")} ${coalesce(rule.port_range_min, 0)}-${coalesce(rule.port_range_max, 65535)}"
        if anytrue([for edge in ["192.0.2.7", "192.0.2.8"] : try(cidrcontains(rule.remote_ip_prefix, edge), false)])
      ],
      [
        for rule in output.worker_security_group.ingress_rules : "workers ${coalesce(rule.protocol, "any")} ${coalesce(rule.port_range_min, 0)}-${coalesce(rule.port_range_max, 65535)}"
        if anytrue([for edge in ["192.0.2.7", "192.0.2.8"] : try(cidrcontains(rule.remote_ip_prefix, edge), false)])
      ],
    )) == toset(["nodes tcp 6443-6443", "workers tcp 80-80", "workers tcp 443-443"])
    error_message = "An edge router may reach TCP 80 and 443 through the workers' own group and TCP 6443 through the nodes' rule for the node subnet, and nothing else: no other port, no other protocol, and not TCP 179."
  }

  assert {
    condition = length([
      for rule in concat(output.security_group.ingress_rules, output.worker_security_group.ingress_rules) : rule
      if rule.port_range_min == 179 || rule.port_range_max == 179
    ]) == 0
    error_message = "No rule may open TCP 179, from any source: the workers open their BGP sessions themselves."
  }
}

# The service ports come from a variable; the edge routers reach exactly those.
run "_the_edge_routers_reach_the_service_ports_the_variable_names" {
  command = plan

  variables {
    service_ports = [8443]
  }

  assert {
    condition     = sort([for rule in output.worker_security_group.ingress_rules : "${rule.port_range_min}-${rule.port_range_max} ${rule.remote_ip_prefix}"]) == tolist(["8443-8443 192.0.2.7/32", "8443-8443 192.0.2.8/32"])
    error_message = "The workers' own group must admit the ports service_ports names, from each edge address, and no other."
  }
}
