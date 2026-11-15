# The module alone, against a mocked provider: no credentials, no state, no network beyond the
# provider plugin tofu init fetches. Addresses are the documentation ranges. The stack that calls
# the module has its own tests of what it passes in; these are of what the module does with it.

mock_provider "openstack" {}

variables {
  name = "lab"
  network = {
    network_id = "node-network-fixture"
    subnet_id  = "node-subnet-fixture"
    cidr       = "192.0.2.0/24"
  }
  image_id            = "image-fixture"
  external_network    = "external-network-fixture"
  controlplane_count  = 3
  worker_count        = 2
  worker_first_host   = 20
  controlplane_flavor = "flavor-cp-fixture"
  worker_flavor       = "flavor-w-fixture"

  # Out of order, with one network twice: each must be admitted once.
  api_allowed_cidrs = ["203.0.113.192/26", "198.51.100.0/24", "203.0.113.192/26"]
}

# IDs of their own for the three groups, so a rule or a port wired to the wrong group cannot pass.
override_resource {
  target = openstack_networking_secgroup_v2.this
  values = { id = "group-nodes" }
}

override_resource {
  target = openstack_networking_secgroup_v2.workers
  values = { id = "group-workers" }
}

# The floating IPs the hairpin rules admit, one address per node.
override_resource {
  target = openstack_networking_floatingip_v2.node["lab-cp-1"]
  values = { address = "203.0.113.11" }
}

override_resource {
  target = openstack_networking_floatingip_v2.node["lab-cp-2"]
  values = { address = "203.0.113.12" }
}

override_resource {
  target = openstack_networking_floatingip_v2.node["lab-cp-3"]
  values = { address = "203.0.113.13" }
}

override_resource {
  target = openstack_networking_floatingip_v2.node["lab-w-1"]
  values = { address = "203.0.113.21" }
}

override_resource {
  target = openstack_networking_floatingip_v2.node["lab-w-2"]
  values = { address = "203.0.113.22" }
}

# A port ID of its own per node, so an association with the port of another node cannot pass.
override_resource {
  target = module.node["lab-cp-1"].openstack_networking_port_v2.this
  values = { id = "port-lab-cp-1" }
}

override_resource {
  target = module.node["lab-cp-2"].openstack_networking_port_v2.this
  values = { id = "port-lab-cp-2" }
}

override_resource {
  target = module.node["lab-cp-3"].openstack_networking_port_v2.this
  values = { id = "port-lab-cp-3" }
}

override_resource {
  target = module.node["lab-w-1"].openstack_networking_port_v2.this
  values = { id = "port-lab-w-1" }
}

override_resource {
  target = module.node["lab-w-2"].openstack_networking_port_v2.this
  values = { id = "port-lab-w-2" }
}

run "the_talos_nodes_module_names_and_addresses_the_nodes_by_role" {
  command = plan

  assert {
    condition     = keys(output.nodes) == ["lab-cp-1", "lab-cp-2", "lab-cp-3", "lab-w-1", "lab-w-2"]
    error_message = "The nodes must be lab-cp-1 to 3 and lab-w-1 and 2."
  }

  assert {
    condition = { for k, n in output.nodes : k => { role = n.role, address = n.private_address } } == {
      "lab-cp-1" = { role = "controlplane", address = "192.0.2.10" }
      "lab-cp-2" = { role = "controlplane", address = "192.0.2.11" }
      "lab-cp-3" = { role = "controlplane", address = "192.0.2.12" }
      "lab-w-1"  = { role = "worker", address = "192.0.2.20" }
      "lab-w-2"  = { role = "worker", address = "192.0.2.21" }
    }
    error_message = "Control planes must take hosts from 10 and workers hosts from the first worker host."
  }

  assert {
    condition     = output.controlplane_addresses == { "lab-cp-1" = "192.0.2.10", "lab-cp-2" = "192.0.2.11", "lab-cp-3" = "192.0.2.12" } && keys(output.controlplane_port_ids) == ["lab-cp-1", "lab-cp-2", "lab-cp-3"]
    error_message = "The control plane outputs must list the control planes alone."
  }

  assert {
    condition     = alltrue([for k, i in output.instances : i.flavor == (startswith(k, "lab-cp-") ? "flavor-cp-fixture" : "flavor-w-fixture")])
    error_message = "Each node must have the flavor of its role."
  }

  assert {
    condition     = alltrue([for k, i in output.instances : i.port.subnet_id == "node-subnet-fixture" && i.port.network_id == "node-network-fixture" && i.port.port_security_enabled])
    error_message = "Every node's port must be on the node subnet with port security."
  }
}

run "_the_first_worker_host_moves_the_workers" {
  command = plan

  variables {
    controlplane_count = 1
    worker_count       = 1
    worker_first_host  = 30
  }

  assert {
    condition     = { for k, n in output.nodes : k => n.private_address } == { "lab-cp-1" = "192.0.2.10", "lab-w-1" = "192.0.2.30" }
    error_message = "The workers must start at the first worker host, and the control planes stay from host 10."
  }
}

run "the_talos_nodes_module_admits_the_talos_and_kubernetes_apis_once_per_allowlisted_network" {
  command = plan

  assert {
    condition     = keys(openstack_networking_secgroup_rule_v2.api) == ["50000-0", "50000-1", "6443-0", "6443-1"]
    error_message = "There must be one rule per port and network, keyed by port and position in the allowlist, never by the network."
  }

  assert {
    condition = { for k, r in openstack_networking_secgroup_rule_v2.api : k => r.remote_ip_prefix } == {
      "50000-0" = "198.51.100.0/24"
      "50000-1" = "203.0.113.192/26"
      "6443-0"  = "198.51.100.0/24"
      "6443-1"  = "203.0.113.192/26"
    }
    error_message = "The networks must be sorted and without duplicates, so another order changes no rule."
  }

  assert {
    condition = alltrue([
      for k, r in openstack_networking_secgroup_rule_v2.api :
      r.security_group_id == "group-nodes" && r.direction == "ingress" && r.ethertype == "IPv4" && r.protocol == "tcp" && r.port_range_min == r.port_range_max && tostring(r.port_range_min) == split("-", k)[0]
    ])
    error_message = "Each rule must admit one TCP port into the nodes' group."
  }
}

run "_an_empty_allowlist_admits_nothing_on_the_apis" {
  command = plan

  variables {
    api_allowed_cidrs = []
  }

  assert {
    condition     = length(openstack_networking_secgroup_rule_v2.api) == 0
    error_message = "An empty allowlist must give no rule."
  }
}

run "_one_network_gives_one_rule_per_port" {
  command = plan

  variables {
    api_allowed_cidrs = ["198.51.100.0/24"]
  }

  assert {
    condition     = keys(openstack_networking_secgroup_rule_v2.api) == ["50000-0", "6443-0"]
    error_message = "One network must give one rule for each of the two ports."
  }
}

run "the_talos_nodes_module_admits_the_apis_from_each_nodes_floating_ip_and_the_kubernetes_api_from_the_node_subnet" {
  command = plan

  assert {
    condition = { for k, r in openstack_networking_secgroup_rule_v2.hairpin : k => r.remote_ip_prefix } == {
      "50000-lab-cp-1" = "203.0.113.11/32"
      "50000-lab-cp-2" = "203.0.113.12/32"
      "50000-lab-cp-3" = "203.0.113.13/32"
      "50000-lab-w-1"  = "203.0.113.21/32"
      "50000-lab-w-2"  = "203.0.113.22/32"
      "6443-lab-cp-1"  = "203.0.113.11/32"
      "6443-lab-cp-2"  = "203.0.113.12/32"
      "6443-lab-cp-3"  = "203.0.113.13/32"
      "6443-lab-w-1"   = "203.0.113.21/32"
      "6443-lab-w-2"   = "203.0.113.22/32"
    }
    error_message = "Each node's floating IP must be admitted on each of the two API ports."
  }

  assert {
    condition = alltrue([
      for r in values(openstack_networking_secgroup_rule_v2.hairpin) :
      r.security_group_id == "group-nodes" && r.direction == "ingress" && r.ethertype == "IPv4" && r.protocol == "tcp" && r.port_range_min == r.port_range_max
    ])
    error_message = "Each hairpin rule must admit one TCP port into the nodes' group."
  }

  assert {
    condition = alltrue([
      for k, r in openstack_networking_secgroup_rule_v2.hairpin :
      tostring(r.port_range_min) == split("-", k)[0] && tostring(r.port_range_max) == split("-", k)[0]
    ])
    error_message = "Each hairpin rule must admit the port in its key."
  }

  assert {
    condition = (
      openstack_networking_secgroup_rule_v2.api_from_subnet.remote_ip_prefix == "192.0.2.0/24" &&
      openstack_networking_secgroup_rule_v2.api_from_subnet.port_range_min == 6443 &&
      openstack_networking_secgroup_rule_v2.api_from_subnet.port_range_max == 6443 &&
      openstack_networking_secgroup_rule_v2.api_from_subnet.protocol == "tcp" &&
      openstack_networking_secgroup_rule_v2.api_from_subnet.security_group_id == "group-nodes"
    )
    error_message = "The node subnet must be admitted on TCP 6443 alone."
  }

  # Two within the group, four for the allowlist, ten for the floating IPs and one for the subnet.
  assert {
    condition     = length(output.security_group.ingress_rules) == 17
    error_message = "The nodes' group must hold no ingress rule beyond those."
  }

  assert {
    condition = alltrue([
      for r in output.security_group.ingress_rules :
      r.remote_group_id == "group-nodes" || (r.protocol == "tcp" && contains([6443, 50000], r.port_range_min) && r.port_range_min == r.port_range_max)
    ])
    error_message = "Nothing but the two API ports may be admitted from outside the group, among the rules the module exports."
  }
}

run "the_talos_nodes_module_admits_all_traffic_between_the_nodes_over_both_ip_versions" {
  command = plan

  assert {
    condition     = keys(openstack_networking_secgroup_rule_v2.intra) == ["IPv4", "IPv6"]
    error_message = "There must be one rule per IP version."
  }

  assert {
    condition = alltrue([
      for k, r in openstack_networking_secgroup_rule_v2.intra :
      r.security_group_id == "group-nodes" && r.remote_group_id == "group-nodes" && r.direction == "ingress" && r.ethertype == k && r.protocol == null && r.port_range_min == null && r.port_range_max == null
    ])
    error_message = "Each rule must admit all ingress from the group itself."
  }
}

run "the_talos_nodes_module_gives_the_control_planes_a_group_of_their_own_only_with_the_reduced_rules" {
  command = plan

  assert {
    condition     = length(openstack_networking_secgroup_v2.controlplanes) == 0 && length(openstack_networking_secgroup_rule_v2.open) == 0 && output.controlplane_security_group == null
    error_message = "With the full rules there must be no control plane group, no open rule and a null output."
  }
}

run "_the_reduced_rules_give_the_control_planes_a_group" {
  command = plan

  variables {
    security_group_rules = "reduced"
  }

  assert {
    condition     = length(openstack_networking_secgroup_v2.controlplanes) == 1 && openstack_networking_secgroup_v2.controlplanes[0].name == "lab-controlplanes"
    error_message = "The reduced rules must give the control planes one group of their own."
  }

  assert {
    condition     = output.controlplane_security_group != null && length(output.controlplane_security_group.ingress_rules) == 6
    error_message = "The output must report the group and its six rules."
  }
}

run "the_talos_nodes_modules_reduced_rules_open_every_port_but_the_talos_api_and_the_nodeport_range" {
  command = plan

  variables {
    security_group_rules = "reduced"
  }

  override_resource {
    target = openstack_networking_secgroup_v2.controlplanes[0]
    values = { id = "group-controlplanes" }
  }

  assert {
    condition     = keys(openstack_networking_secgroup_rule_v2.open) == ["icmp", "tcp-1-29999", "tcp-32768-49999", "tcp-50001-65535", "udp-1-29999", "udp-32768-65535"]
    error_message = "The group must hold exactly the six open rules."
  }

  assert {
    condition = alltrue([
      for r in values(openstack_networking_secgroup_rule_v2.open) :
      r.security_group_id == "group-controlplanes" && r.direction == "ingress" && r.ethertype == "IPv4" && r.remote_ip_prefix == "0.0.0.0/0"
    ])
    error_message = "Every rule must admit ingress from all into the control planes' group."
  }

  # The Talos API: a node in maintenance mode has no firewall of its own. The NodePort range:
  # Cilium serves it before the node's firewall sees the packet.
  assert {
    condition = alltrue([
      for p in [50000, 30000, 31000, 32767] :
      !anytrue([for r in values(openstack_networking_secgroup_rule_v2.open) : r.protocol == "tcp" && r.port_range_min <= p && p <= r.port_range_max])
    ])
    error_message = "TCP 50000 and the NodePort range must stay closed."
  }

  assert {
    condition = alltrue([
      for p in [30000, 31000, 32767] :
      !anytrue([for r in values(openstack_networking_secgroup_rule_v2.open) : r.protocol == "udp" && r.port_range_min <= p && p <= r.port_range_max])
    ])
    error_message = "The NodePort range must stay closed to UDP."
  }

  assert {
    condition = alltrue([
      for p in [1, 22, 6443, 10250, 29999, 32768, 49999, 50001, 65535] :
      anytrue([for r in values(openstack_networking_secgroup_rule_v2.open) : r.protocol == "tcp" && r.port_range_min <= p && p <= r.port_range_max])
    ])
    error_message = "Every other TCP port must be open."
  }

  assert {
    condition = alltrue([
      for p in [1, 8472, 29999, 32768, 50000, 65535] :
      anytrue([for r in values(openstack_networking_secgroup_rule_v2.open) : r.protocol == "udp" && r.port_range_min <= p && p <= r.port_range_max])
    ])
    error_message = "Every other UDP port must be open."
  }

  assert {
    condition     = openstack_networking_secgroup_rule_v2.open["icmp"].protocol == "icmp" && openstack_networking_secgroup_rule_v2.open["icmp"].port_range_min == null
    error_message = "ICMP must be open, without ports."
  }
}

# The nodes' group is asserted with the same literals under both rule sets: only the control planes' group differs.
run "_the_full_rules_hold_these_rules_in_the_nodes_group" {
  command = plan

  assert {
    condition     = length(output.security_group.ingress_rules) == 17 && length(output.worker_security_group.ingress_rules) == 0
    error_message = "The nodes' group must hold 17 rules and the workers' none."
  }

  assert {
    condition     = length(openstack_networking_secgroup_v2.controlplanes) == 0
    error_message = "The full rules must give the control planes no group."
  }
}

run "the_talos_nodes_module_switches_between_the_rule_sets_without_touching_the_nodes_group" {
  command = plan

  variables {
    security_group_rules = "reduced"
  }

  assert {
    condition     = length(output.security_group.ingress_rules) == 17 && length(output.worker_security_group.ingress_rules) == 0
    error_message = "The nodes' group must hold the same 17 rules as with the full rules, and the workers' group none."
  }

  assert {
    condition = { for k, r in openstack_networking_secgroup_rule_v2.api : k => "${r.remote_ip_prefix}:${r.port_range_min}-${r.port_range_max}" } == {
      "50000-0" = "198.51.100.0/24:50000-50000"
      "50000-1" = "203.0.113.192/26:50000-50000"
      "6443-0"  = "198.51.100.0/24:6443-6443"
      "6443-1"  = "203.0.113.192/26:6443-6443"
    }
    error_message = "The allowlisted networks must reach the two API ports alone, as with the full rules."
  }

  assert {
    condition = { for k, r in openstack_networking_secgroup_rule_v2.hairpin : k => "${r.remote_ip_prefix}:${r.port_range_min}-${r.port_range_max}" } == {
      "50000-lab-cp-1" = "203.0.113.11/32:50000-50000"
      "50000-lab-cp-2" = "203.0.113.12/32:50000-50000"
      "50000-lab-cp-3" = "203.0.113.13/32:50000-50000"
      "50000-lab-w-1"  = "203.0.113.21/32:50000-50000"
      "50000-lab-w-2"  = "203.0.113.22/32:50000-50000"
      "6443-lab-cp-1"  = "203.0.113.11/32:6443-6443"
      "6443-lab-cp-2"  = "203.0.113.12/32:6443-6443"
      "6443-lab-cp-3"  = "203.0.113.13/32:6443-6443"
      "6443-lab-w-1"   = "203.0.113.21/32:6443-6443"
      "6443-lab-w-2"   = "203.0.113.22/32:6443-6443"
    }
    error_message = "Each node's floating IP must reach the two API ports alone, as with the full rules."
  }

  assert {
    condition = (
      openstack_networking_secgroup_rule_v2.api_from_subnet.remote_ip_prefix == "192.0.2.0/24" &&
      openstack_networking_secgroup_rule_v2.api_from_subnet.port_range_min == 6443 &&
      openstack_networking_secgroup_rule_v2.api_from_subnet.port_range_max == 6443 &&
      openstack_networking_secgroup_rule_v2.api_from_subnet.protocol == "tcp"
    )
    error_message = "The node subnet must reach TCP 6443 alone, as with the full rules."
  }

  assert {
    condition = alltrue([
      for k, r in openstack_networking_secgroup_rule_v2.intra :
      r.security_group_id == "group-nodes" && r.remote_group_id == "group-nodes" && r.direction == "ingress" && r.ethertype == k && r.protocol == null && r.port_range_min == null && r.port_range_max == null
    ]) && keys(openstack_networking_secgroup_rule_v2.intra) == ["IPv4", "IPv6"]
    error_message = "The nodes must still admit all ingress from the group itself over both IP versions."
  }

  assert {
    condition     = length(openstack_networking_secgroup_v2.controlplanes) == 1 && length(openstack_networking_secgroup_rule_v2.open) == 6
    error_message = "The reduced rules must add the control planes' group and its six rules."
  }
}

run "the_talos_nodes_module_gives_each_node_the_groups_of_its_role" {
  command = plan

  assert {
    condition = {
      for k, i in output.instances : k => i.port.security_group_ids
      } == {
      "lab-cp-1" = toset(["group-nodes"])
      "lab-cp-2" = toset(["group-nodes"])
      "lab-cp-3" = toset(["group-nodes"])
      "lab-w-1"  = toset(["group-nodes", "group-workers"])
      "lab-w-2"  = toset(["group-nodes", "group-workers"])
    }
    error_message = "With the full rules the control planes must have the nodes' group and the workers the nodes' group and their own."
  }
}

run "_with_the_reduced_rules_the_control_planes_have_their_own_group_too" {
  command = plan

  variables {
    security_group_rules = "reduced"
  }

  override_resource {
    target = openstack_networking_secgroup_v2.controlplanes[0]
    values = { id = "group-controlplanes" }
  }

  assert {
    condition = {
      for k, i in output.instances : k => i.port.security_group_ids
      } == {
      "lab-cp-1" = toset(["group-nodes", "group-controlplanes"])
      "lab-cp-2" = toset(["group-nodes", "group-controlplanes"])
      "lab-cp-3" = toset(["group-nodes", "group-controlplanes"])
      "lab-w-1"  = toset(["group-nodes", "group-workers"])
      "lab-w-2"  = toset(["group-nodes", "group-workers"])
    }
    error_message = "The control planes must have the nodes' group and their own, the workers the same two as with the full rules."
  }
}

run "the_talos_nodes_module_admits_the_worker_ingress_ports_from_the_sources_given_and_nothing_else" {
  command = plan

  assert {
    condition     = length(openstack_networking_secgroup_rule_v2.worker_ingress) == 0 && length(output.worker_security_group.ingress_rules) == 0
    error_message = "Without worker ingress the workers' group must hold no rule."
  }
}

run "_two_ports_and_two_sources_are_given" {
  command = plan

  variables {
    worker_ingress = {
      sources   = ["198.51.100.0/24", "203.0.113.0/26"]
      tcp_ports = [443, 8443]
    }
  }

  assert {
    condition = { for k, r in openstack_networking_secgroup_rule_v2.worker_ingress : k => "${r.port_range_min}-${r.remote_ip_prefix}" } == {
      "443-0"  = "443-198.51.100.0/24"
      "443-1"  = "443-203.0.113.0/26"
      "8443-0" = "8443-198.51.100.0/24"
      "8443-1" = "8443-203.0.113.0/26"
    }
    error_message = "There must be one rule per port and source, keyed by port and position in the sources."
  }

  assert {
    condition = alltrue([
      for r in values(openstack_networking_secgroup_rule_v2.worker_ingress) :
      r.security_group_id == "group-workers" && r.direction == "ingress" && r.ethertype == "IPv4" && r.protocol == "tcp" && r.port_range_min == r.port_range_max
    ])
    error_message = "Each rule must admit one TCP port into the workers' group."
  }

  assert {
    condition     = length(output.worker_security_group.ingress_rules) == 4 && length(output.security_group.ingress_rules) == 17
    error_message = "The rules must be in the workers' group, and the nodes' group must not change."
  }
}

run "the_talos_nodes_module_gives_the_ports_the_allowed_address_pairs_of_their_role" {
  command = plan

  assert {
    condition     = alltrue([for i in values(output.instances) : length(i.port.allowed_address_pairs) == 0])
    error_message = "No port may carry an allowed address pair by default."
  }
}

run "_ranges_for_every_node_and_others_for_the_workers" {
  command = plan

  variables {
    allowed_address_pairs        = ["198.51.100.0/24"]
    worker_allowed_address_pairs = ["203.0.113.0/26"]
  }

  assert {
    condition = jsonencode({ for k, i in output.instances : k => sort(i.port.allowed_address_pairs) }) == jsonencode({
      "lab-cp-1" = ["198.51.100.0/24"]
      "lab-cp-2" = ["198.51.100.0/24"]
      "lab-cp-3" = ["198.51.100.0/24"]
      "lab-w-1"  = ["198.51.100.0/24", "203.0.113.0/26"]
      "lab-w-2"  = ["198.51.100.0/24", "203.0.113.0/26"]
    })
    error_message = "Every port must carry the first range, the workers' ports the second too, and no control plane's the second."
  }
}

run "_ranges_for_the_workers_alone" {
  command = plan

  variables {
    worker_allowed_address_pairs = ["203.0.113.0/26"]
  }

  assert {
    condition = jsonencode({ for k, i in output.instances : k => i.port.allowed_address_pairs }) == jsonencode({
      "lab-cp-1" = []
      "lab-cp-2" = []
      "lab-cp-3" = []
      "lab-w-1"  = ["203.0.113.0/26"]
      "lab-w-2"  = ["203.0.113.0/26"]
    })
    error_message = "Only the workers' ports may carry the workers' ranges."
  }
}

run "the_talos_nodes_module_schedules_every_node_into_one_soft_anti_affinity_server_group" {
  command = plan

  assert {
    condition     = jsonencode(openstack_compute_servergroup_v2.this.policies) == jsonencode(["soft-anti-affinity"]) && jsonencode(output.server_group.policies) == jsonencode(["soft-anti-affinity"])
    error_message = "The server group must have the soft-anti-affinity policy alone."
  }

  assert {
    condition     = openstack_compute_servergroup_v2.this.name == "lab"
    error_message = "The server group must carry the cluster's name."
  }
}

run "the_talos_nodes_module_boots_every_node_from_a_volume_of_the_size_given_and_gives_it_no_user_data" {
  command = plan

  assert {
    condition = alltrue([
      for i in values(output.instances) :
      i.boot_volume.size == 40 && i.boot_volume.image_id == "image-fixture" && i.boot_volume.source_type == "image" && i.boot_volume.destination_type == "volume" && i.boot_volume.boot_index == 0
    ])
    error_message = "Every node must boot from a 40 GB volume made from the image by default."
  }

  assert {
    condition     = alltrue([for i in values(output.instances) : i.user_data == null])
    error_message = "No node may have user data: the machine configuration is applied over the Talos API."
  }
}

run "_another_root_volume_size_is_given" {
  command = plan

  variables {
    root_volume_size_gb = 80
  }

  assert {
    condition     = alltrue([for i in values(output.instances) : i.boot_volume.size == 80])
    error_message = "Every boot volume must have the size given."
  }
}

run "the_talos_nodes_module_keeps_neutrons_default_egress_rules_in_the_nodes_group_only" {
  command = plan

  variables {
    security_group_rules = "reduced"
  }

  assert {
    condition     = output.security_group.delete_default_rules == false
    error_message = "The nodes' group must keep Neutron's default egress rules."
  }

  assert {
    condition     = output.worker_security_group.delete_default_rules == true && output.controlplane_security_group.delete_default_rules == true
    error_message = "The workers' and the control planes' groups hold ingress rules only, so they must lose the default egress rules."
  }
}

run "the_talos_nodes_module_marks_the_outputs_that_hold_the_allowlist_sensitive" {
  command = plan

  variables {
    worker_ingress = {
      sources   = ["198.51.100.0/24"]
      tcp_ports = [443]
    }
  }

  assert {
    condition     = issensitive(output.security_group) && issensitive(output.worker_security_group)
    error_message = "The security group outputs must be sensitive: they hold the allowlist and the worker ingress sources."
  }

  assert {
    condition     = !issensitive(output.nodes) && !issensitive(output.server_group) && !issensitive(output.floating_ips) && !issensitive(output.controlplane_addresses) && !issensitive(output.controlplane_port_ids)
    error_message = "The node, address and server group outputs must not be sensitive."
  }
}

run "the_talos_nodes_module_refuses_a_cluster_name_that_is_not_lowercase_letters_digits_and_hyphens_at_most_24" {
  command = plan

  variables {
    name = "Lab"
  }

  expect_failures = [var.name]
}

run "_an_underscore_in_the_name_is_refused" {
  command = plan

  variables {
    name = "lab_1"
  }

  expect_failures = [var.name]
}

run "_an_empty_name_is_refused" {
  command = plan

  variables {
    name = ""
  }

  expect_failures = [var.name]
}

run "_a_name_of_25_characters_is_refused" {
  command = plan

  variables {
    name = join("", [for i in range(25) : "a"])
  }

  expect_failures = [var.name]
}

run "_a_name_of_one_character_is_accepted" {
  command = plan

  variables {
    name = "a"
  }

  assert {
    condition     = openstack_networking_secgroup_v2.this.name == "a"
    error_message = "A name of one valid character must plan."
  }
}

run "_a_name_of_24_characters_is_accepted" {
  command = plan

  variables {
    name = join("", [for i in range(24) : "a"])
  }

  assert {
    condition     = length(openstack_networking_secgroup_v2.this.name) == 24
    error_message = "A name of 24 valid characters must plan."
  }
}

run "_a_name_with_digits_and_hyphens_is_accepted" {
  command = plan

  variables {
    name = "lab-2"
  }

  assert {
    condition     = openstack_networking_secgroup_v2.this.name == "lab-2"
    error_message = "Digits and hyphens must be accepted."
  }
}

run "the_talos_nodes_module_refuses_an_unknown_set_of_security_group_rules" {
  command = plan

  variables {
    security_group_rules = "all"
  }

  expect_failures = [var.security_group_rules]
}

run "_an_empty_set_of_security_group_rules_is_refused" {
  command = plan

  variables {
    security_group_rules = ""
  }

  expect_failures = [var.security_group_rules]
}

run "_the_set_name_is_case_sensitive" {
  command = plan

  variables {
    security_group_rules = "Reduced"
  }

  expect_failures = [var.security_group_rules]
}

run "_the_full_rules_are_accepted" {
  command = plan

  variables {
    security_group_rules = "full"
  }

  assert {
    condition     = length(openstack_networking_secgroup_v2.controlplanes) == 0
    error_message = "The full rules must plan."
  }
}

run "_the_reduced_rules_are_accepted" {
  command = plan

  variables {
    security_group_rules = "reduced"
  }

  assert {
    condition     = length(openstack_networking_secgroup_v2.controlplanes) == 1
    error_message = "The reduced rules must plan."
  }
}

run "the_talos_nodes_module_refuses_a_first_worker_host_below_20_or_not_whole" {
  command = plan

  variables {
    worker_first_host = 19
  }

  expect_failures = [var.worker_first_host]
}

run "_a_first_worker_host_that_is_not_whole_is_refused" {
  command = plan

  variables {
    worker_first_host = 20.5
  }

  expect_failures = [var.worker_first_host]
}

run "_a_first_worker_host_of_zero_is_refused" {
  command = plan

  variables {
    worker_first_host = 0
  }

  expect_failures = [var.worker_first_host]
}

run "_a_first_worker_host_of_20_is_accepted" {
  command = plan

  variables {
    worker_first_host = 20
  }

  assert {
    condition     = output.nodes["lab-w-1"].private_address == "192.0.2.20"
    error_message = "The first worker host 20 must plan."
  }
}

run "_a_first_worker_host_of_40_is_accepted" {
  command = plan

  variables {
    worker_first_host = 40
  }

  assert {
    condition     = output.nodes["lab-w-1"].private_address == "192.0.2.40"
    error_message = "The first worker host 40 must plan."
  }
}

run "the_talos_nodes_module_refuses_an_allowlist_entry_that_is_not_an_ipv4_network" {
  command = plan

  variables {
    api_allowed_cidrs = ["198.51.100.1"]
  }

  expect_failures = [var.api_allowed_cidrs]
}

run "_an_ipv6_network_in_the_allowlist_is_refused" {
  command = plan

  variables {
    api_allowed_cidrs = ["2001:db8::/32"]
  }

  expect_failures = [var.api_allowed_cidrs]
}

run "_text_in_the_allowlist_is_refused" {
  command = plan

  variables {
    api_allowed_cidrs = ["198.51.100.0/24", "not-a-network"]
  }

  expect_failures = [var.api_allowed_cidrs]
}

run "_ipv4_networks_in_the_allowlist_are_accepted" {
  command = plan

  variables {
    api_allowed_cidrs = ["198.51.100.0/24", "203.0.113.0/26"]
  }

  assert {
    condition     = length(openstack_networking_secgroup_rule_v2.api) == 4
    error_message = "Two IPv4 networks must plan."
  }
}

# A mocked apply leaves the instances in state, and an instance ignores later changes to its boot
# device, so the runs that apply come last.
run "_every_node_is_scheduled_into_the_server_group_it_is_given" {
  command = apply

  assert {
    condition     = alltrue([for i in values(output.instances) : i.server_group_id == output.server_group.id]) && length(output.instances) == 5
    error_message = "Every node must be scheduled into the one server group."
  }
}

run "the_talos_nodes_module_gives_each_node_a_floating_ip_of_its_own_associated_with_its_port" {
  command = apply

  assert {
    condition     = keys(output.floating_ips) == ["lab-cp-1", "lab-cp-2", "lab-cp-3", "lab-w-1", "lab-w-2"]
    error_message = "There must be one floating IP per node."
  }

  assert {
    condition     = alltrue([for k, f in output.floating_ips : f.pool == "external-network-fixture"])
    error_message = "Every floating IP must come from the external network."
  }

  assert {
    condition = alltrue([
      for k, f in output.floating_ips :
      f.association.floating_ip == f.address && f.association.port_id == output.instances[k].port.id && output.nodes[k].port_id == f.association.port_id && output.nodes[k].floating_address == f.address
    ])
    error_message = "Every floating IP must be associated with its own node's port."
  }

  assert {
    condition     = length(distinct([for f in values(output.floating_ips) : f.address])) == 5 && length(distinct([for f in values(output.floating_ips) : f.association.port_id])) == 5
    error_message = "No two nodes may share a floating IP or a port."
  }
}
