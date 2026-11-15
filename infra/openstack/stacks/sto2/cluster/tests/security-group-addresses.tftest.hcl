# The nodes' module alone, as the cluster stack calls it by default. A run of the stack cannot
# reach the resources inside the module in an assertion, and the stack's own tests override
# resources of the stack, so this run has a file of its own. The provider is mocked, so it needs no
# credentials and reads no state.

mock_provider "openstack" {}

run "_todays_rules_keep_their_resource_addresses" {
  command = plan

  module {
    source = "../../../modules/talos-nodes"
  }

  variables {
    name = "lab"
    network = {
      network_id = "node-network-fixture"
      subnet_id  = "node-subnet-fixture"
      cidr       = "192.0.2.0/24"
    }
    image_id            = "talos-image-fixture"
    external_network    = "external-network-fixture"
    api_allowed_cidrs   = ["203.0.113.192/26", "198.51.100.0/24"]
    controlplane_count  = 3
    worker_count        = 3
    worker_first_host   = 20
    controlplane_flavor = "b.4c8gb"
    worker_flavor       = "b.6c16gb"
  }

  assert {
    condition     = keys(openstack_networking_secgroup_rule_v2.intra) == ["IPv4", "IPv6"]
    error_message = "The rules within the group must be keyed by ethertype."
  }

  assert {
    condition     = keys(openstack_networking_secgroup_rule_v2.api) == ["50000-0", "50000-1", "6443-0", "6443-1"]
    error_message = "The allowlist's rules must be keyed by port and position in the allowlist."
  }

  assert {
    condition = toset(keys(openstack_networking_secgroup_rule_v2.hairpin)) == toset(flatten([
      for port in ["50000", "6443"] : [
        for node in ["lab-cp-1", "lab-cp-2", "lab-cp-3", "lab-w-1", "lab-w-2", "lab-w-3"] : "${port}-${node}"
      ]
    ]))
    error_message = "The floating addresses' rules must be keyed by port and node."
  }

  assert {
    condition     = openstack_networking_secgroup_rule_v2.api_from_subnet.port_range_min == 6443
    error_message = "The node subnet's rule must be the one resource api_from_subnet, without a key."
  }

  assert {
    condition     = length(openstack_networking_secgroup_rule_v2.open) == 0 && length(openstack_networking_secgroup_v2.controlplanes) == 0
    error_message = "By default there must be no rule open to all, and no group of the control planes' own."
  }
}
