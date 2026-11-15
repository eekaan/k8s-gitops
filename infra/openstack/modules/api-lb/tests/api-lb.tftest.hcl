# The module alone, against a mocked provider: no credentials, no state, no network beyond the
# provider plugin tofu init fetches. Addresses are the documentation ranges. The stack that calls
# the module has its own tests of what it passes in; these are of what the module does with it.

mock_provider "openstack" {}

variables {
  name = "lab"
  network = {
    subnet_id = "node-subnet-fixture"
    cidr      = "192.0.2.0/24"
  }
  vip_host = 5
  members = {
    "lab-cp-1" = "192.0.2.10"
    "lab-cp-2" = "192.0.2.11"
    "lab-cp-3" = "192.0.2.12"
  }
  external_network = "external-network-fixture"

  # Out of order, with one network twice: each must be admitted once.
  allowed_cidrs = ["203.0.113.192/26", "198.51.100.0/24", "203.0.113.192/26"]
}

# IDs and addresses of their own, so a part wired to any other value cannot pass.
override_resource {
  target = openstack_lb_loadbalancer_v2.this
  values = {
    id          = "load-balancer-fixture"
    vip_port_id = "port-api-vip"
  }
}

override_resource {
  target = openstack_lb_listener_v2.this
  values = { id = "listener-fixture" }
}

override_resource {
  target = openstack_lb_pool_v2.this
  values = { id = "pool-fixture" }
}

override_resource {
  target = openstack_networking_floatingip_v2.this
  values = { address = "203.0.113.50" }
}

run "the_api_lb_module_puts_the_api_at_a_fixed_address_of_the_node_subnet" {
  command = plan

  assert {
    condition     = output.vip_address == "192.0.2.5" && openstack_lb_loadbalancer_v2.this.vip_address == "192.0.2.5"
    error_message = "The load balancer's address must be host number 5 of the node subnet."
  }

  assert {
    condition     = openstack_lb_loadbalancer_v2.this.vip_subnet_id == "node-subnet-fixture"
    error_message = "The load balancer must be on the node subnet."
  }

  assert {
    condition     = output.endpoint == "https://192.0.2.5:6443"
    error_message = "The endpoint must be the HTTPS URL of the address on port 6443."
  }
}

run "_another_host_number_gives_another_address" {
  command = plan

  variables {
    network  = { subnet_id = "node-subnet-fixture", cidr = "198.51.100.0/24" }
    vip_host = 7
  }

  assert {
    condition     = output.vip_address == "198.51.100.7" && output.endpoint == "https://198.51.100.7:6443"
    error_message = "The address must follow the host number and the range."
  }
}

run "the_api_lb_modules_listener_admits_the_allowlist_and_the_node_subnet_once_each" {
  command = plan

  assert {
    condition     = openstack_lb_listener_v2.this.protocol == "TCP" && openstack_lb_listener_v2.this.protocol_port == 6443
    error_message = "The listener must be TCP on port 6443."
  }

  assert {
    condition     = jsonencode(openstack_lb_listener_v2.this.allowed_cidrs) == jsonencode(["192.0.2.0/24", "198.51.100.0/24", "203.0.113.192/26"])
    error_message = "The listener must admit the two allowlisted networks, once each, and the node subnet, and nothing else."
  }

  assert {
    condition     = output.allowed_cidr_count == 3
    error_message = "The count output must report the three networks."
  }
}

run "_the_node_subnet_in_the_allowlist_is_admitted_once" {
  command = plan

  variables {
    allowed_cidrs = ["192.0.2.0/24", "198.51.100.0/24"]
  }

  assert {
    condition     = jsonencode(openstack_lb_listener_v2.this.allowed_cidrs) == jsonencode(["192.0.2.0/24", "198.51.100.0/24"]) && output.allowed_cidr_count == 2
    error_message = "The node subnet must not be admitted twice."
  }
}

run "_an_empty_allowlist_admits_the_node_subnet_alone" {
  command = plan

  variables {
    allowed_cidrs = []
  }

  assert {
    condition     = jsonencode(openstack_lb_listener_v2.this.allowed_cidrs) == jsonencode(["192.0.2.0/24"]) && output.allowed_cidr_count == 1
    error_message = "Without an allowlist the listener must admit the node subnet alone, which the nodes reach the API from while they join."
  }
}

run "the_api_lb_module_makes_one_pool_member_per_control_plane_on_the_api_port" {
  command = plan

  assert {
    condition = {
      for k, m in output.load_balancer.members : k => "${m.address}:${m.protocol_port}"
      } == {
      "lab-cp-1" = "192.0.2.10:6443"
      "lab-cp-2" = "192.0.2.11:6443"
      "lab-cp-3" = "192.0.2.12:6443"
    }
    error_message = "There must be one member per control plane, at its address on port 6443."
  }

  assert {
    condition     = alltrue([for m in values(output.load_balancer.members) : m.pool_id == "pool-fixture" && m.subnet_id == "node-subnet-fixture"])
    error_message = "Every member must be in the API pool, on the node subnet."
  }

  assert {
    condition     = alltrue([for k, m in openstack_lb_member_v2.this : m.name == k])
    error_message = "Each member must carry the name it was given under."
  }
}

run "_without_members_the_pool_is_empty" {
  command = plan

  variables {
    members = {}
  }

  assert {
    condition     = length(openstack_lb_member_v2.this) == 0 && output.load_balancer.members == {}
    error_message = "Without control planes there must be no member."
  }
}

run "the_api_lb_module_balances_tcp_round_robin_and_checks_members_with_the_timings_given" {
  command = plan

  assert {
    condition     = output.load_balancer.pool.protocol == "TCP" && output.load_balancer.pool.lb_method == "ROUND_ROBIN" && output.load_balancer.pool.listener_id == "listener-fixture"
    error_message = "The listener's pool must balance TCP round robin."
  }

  assert {
    condition = output.load_balancer.monitor == {
      pool_id          = "pool-fixture"
      type             = "TCP"
      delay            = 5
      timeout          = 3
      max_retries      = 2
      max_retries_down = 3
    }
    error_message = "The pool's TCP health monitor must have the default timings."
  }
}

run "_other_timings_are_given" {
  command = plan

  variables {
    monitor_delay            = 10
    monitor_timeout          = 4
    monitor_max_retries      = 3
    monitor_max_retries_down = 5
  }

  assert {
    condition     = output.load_balancer.monitor.delay == 10 && output.load_balancer.monitor.timeout == 4 && output.load_balancer.monitor.max_retries == 3 && output.load_balancer.monitor.max_retries_down == 5
    error_message = "The health monitor must have the timings given."
  }
}

run "the_api_lb_module_gives_the_load_balancer_a_floating_ip_from_the_external_network_on_its_vip_port" {
  command = apply

  assert {
    condition     = output.load_balancer.floating_ip.pool == "external-network-fixture" && output.load_balancer.floating_ip.address == "203.0.113.50"
    error_message = "The floating IP must come from the external network."
  }

  assert {
    condition     = output.load_balancer.floating_ip.association == { floating_ip = "203.0.113.50", port_id = "port-api-vip" } && output.floating_address == "203.0.113.50"
    error_message = "The floating IP must be associated with the load balancer's VIP port."
  }
}

run "the_api_lb_module_names_every_part_after_the_cluster_and_tags_them" {
  command = plan

  variables {
    tags = ["lab", "api"]
  }

  assert {
    condition     = openstack_lb_loadbalancer_v2.this.name == "lab-api" && openstack_lb_listener_v2.this.name == "lab-api" && openstack_lb_pool_v2.this.name == "lab-api" && openstack_lb_monitor_v2.this.name == "lab-api"
    error_message = "The load balancer, its listener, pool and health monitor must be named <name>-api."
  }

  assert {
    condition = alltrue([
      openstack_lb_loadbalancer_v2.this.tags == toset(["lab", "api"]),
      openstack_lb_listener_v2.this.tags == toset(["lab", "api"]),
      openstack_lb_pool_v2.this.tags == toset(["lab", "api"]),
      openstack_networking_floatingip_v2.this.tags == toset(["lab", "api"]),
      alltrue([for m in values(openstack_lb_member_v2.this) : m.tags == toset(["lab", "api"])]),
    ])
    error_message = "Everything that takes tags must carry the tags given."
  }
}

# Both are optional and computed, so a plan with none shows a value of the mock's own and cannot
# show that none was sent: a run can show only that the values given reach the load balancer.
run "the_api_lb_module_passes_the_provider_and_flavor_it_is_given_to_the_load_balancer" {
  command = plan

  variables {
    loadbalancer_provider = "provider-fixture"
    flavor_id             = "flavor-fixture"
  }

  assert {
    condition     = openstack_lb_loadbalancer_v2.this.loadbalancer_provider == "provider-fixture" && openstack_lb_loadbalancer_v2.this.flavor_id == "flavor-fixture" && output.load_balancer.provider == "provider-fixture"
    error_message = "The load balancer must carry the provider and the flavor given."
  }
}

run "the_api_lb_module_marks_the_output_that_holds_the_allowlist_sensitive" {
  command = plan

  assert {
    condition     = issensitive(output.load_balancer)
    error_message = "The load balancer output must be sensitive: its listener holds the allowlist."
  }

  assert {
    condition     = !issensitive(output.endpoint) && !issensitive(output.vip_address) && !issensitive(output.allowed_cidr_count) && !issensitive(output.floating_address)
    error_message = "The endpoint, address and count outputs must not be sensitive."
  }
}

run "the_api_lb_module_refuses_a_cluster_name_that_is_not_lowercase_letters_digits_and_hyphens_at_most_24" {
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
    condition     = openstack_lb_loadbalancer_v2.this.name == "a-api"
    error_message = "A name of one valid character must plan."
  }
}

run "_a_name_of_24_characters_is_accepted" {
  command = plan

  variables {
    name = join("", [for i in range(24) : "a"])
  }

  assert {
    condition     = length(openstack_lb_loadbalancer_v2.this.name) == 28
    error_message = "A name of 24 valid characters must plan."
  }
}

run "_a_name_with_digits_and_hyphens_is_accepted" {
  command = plan

  variables {
    name = "lab-2"
  }

  assert {
    condition     = openstack_lb_loadbalancer_v2.this.name == "lab-2-api"
    error_message = "Digits and hyphens must be accepted."
  }
}

run "the_api_lb_module_refuses_an_allowlist_entry_that_is_not_an_ipv4_network" {
  command = plan

  variables {
    allowed_cidrs = ["198.51.100.1"]
  }

  expect_failures = [var.allowed_cidrs]
}

run "_an_ipv6_network_in_the_allowlist_is_refused" {
  command = plan

  variables {
    allowed_cidrs = ["2001:db8::/32"]
  }

  expect_failures = [var.allowed_cidrs]
}

run "_text_in_the_allowlist_is_refused" {
  command = plan

  variables {
    allowed_cidrs = ["198.51.100.0/24", "not-a-network"]
  }

  expect_failures = [var.allowed_cidrs]
}

run "_ipv4_networks_in_the_allowlist_are_accepted" {
  command = plan

  variables {
    allowed_cidrs = ["198.51.100.0/24", "203.0.113.0/26"]
  }

  assert {
    condition     = output.allowed_cidr_count == 3
    error_message = "Two IPv4 networks and the node subnet must plan."
  }
}
