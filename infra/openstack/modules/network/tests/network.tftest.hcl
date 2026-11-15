# The module alone, against a mocked provider: no credentials, no state, no network beyond the
# provider plugin tofu init fetches. Ranges are the documentation ranges.

mock_provider "openstack" {}

variables {
  name = "nodes"
  cidr = "192.0.2.0/24"
}

run "the_network_module_gives_the_dhcp_pool_the_host_range_it_is_given" {
  command = plan

  assert {
    condition     = output.allocation_pool == { start = "192.0.2.10", end = "192.0.2.200" }
    error_message = "The default pool must run from host 10 to host 200 of the range."
  }

  assert {
    condition     = output.cidr == "192.0.2.0/24"
    error_message = "The cidr output must be the range given."
  }
}

run "_the_dhcp_pool_follows_another_host_range" {
  command = plan

  variables {
    cidr       = "198.51.100.0/25"
    dhcp_range = [30, 100]
  }

  assert {
    condition     = output.allocation_pool == { start = "198.51.100.30", end = "198.51.100.100" }
    error_message = "The pool must run from host 30 to host 100 of the range given, and nothing else."
  }
}

run "the_network_module_gives_the_subnet_no_gateway_unless_asked_for" {
  command = plan

  assert {
    condition     = openstack_networking_subnet_v2.this.no_gateway == true
    error_message = "The subnet must have no gateway by default."
  }

  assert {
    condition     = output.gateway_ip == null
    error_message = "The gateway output must be null without a gateway."
  }
}

run "_a_gateway_is_given_when_asked_for" {
  command = plan

  variables {
    gateway = true
  }

  assert {
    condition     = openstack_networking_subnet_v2.this.no_gateway == false
    error_message = "The subnet must have a gateway when asked for one."
  }
}

run "the_network_module_leaves_port_security_off_unless_asked_for" {
  command = plan

  assert {
    condition     = openstack_networking_network_v2.this.port_security_enabled == false
    error_message = "Port security must be off on the network by default."
  }
}

run "_port_security_is_on_when_asked_for" {
  command = plan

  variables {
    port_security = true
  }

  assert {
    condition     = openstack_networking_network_v2.this.port_security_enabled == true
    error_message = "Port security must be on when asked for."
  }
}

run "the_network_module_names_and_tags_the_network_and_its_subnet_alike" {
  command = plan

  variables {
    name            = "lab-nodes"
    tags            = ["lab", "nodes"]
    dns_nameservers = ["192.0.2.53", "198.51.100.53"]
  }

  assert {
    condition     = openstack_networking_network_v2.this.name == "lab-nodes" && openstack_networking_subnet_v2.this.name == "lab-nodes"
    error_message = "The network and the subnet must carry the name given."
  }

  assert {
    condition     = openstack_networking_network_v2.this.admin_state_up == true && openstack_networking_subnet_v2.this.enable_dhcp == true && openstack_networking_subnet_v2.this.ip_version == 4
    error_message = "The network must be up and the subnet an IPv4 subnet with DHCP."
  }

  assert {
    condition     = openstack_networking_network_v2.this.tags == toset(["lab", "nodes"]) && openstack_networking_subnet_v2.this.tags == toset(["lab", "nodes"])
    error_message = "The network and the subnet must carry the tags given."
  }

  assert {
    condition     = openstack_networking_subnet_v2.this.dns_nameservers == tolist(["192.0.2.53", "198.51.100.53"])
    error_message = "The subnet must hand out exactly the nameservers given."
  }
}

run "the_network_module_refuses_a_name_that_is_not_lowercase_letters_digits_and_hyphens" {
  command = plan

  variables {
    name = "Nodes"
  }

  expect_failures = [var.name]
}

run "_an_underscore_in_the_name_is_refused" {
  command = plan

  variables {
    name = "lab_nodes"
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

run "_a_name_of_64_characters_is_refused" {
  command = plan

  variables {
    name = join("", [for i in range(64) : "a"])
  }

  expect_failures = [var.name]
}

run "_a_name_of_one_character_is_accepted" {
  command = plan

  variables {
    name = "a"
  }

  assert {
    condition     = openstack_networking_network_v2.this.name == "a"
    error_message = "A name of one valid character must plan."
  }
}

run "_a_name_of_63_characters_is_accepted" {
  command = plan

  variables {
    name = join("", [for i in range(63) : "a"])
  }

  assert {
    condition     = length(openstack_networking_network_v2.this.name) == 63
    error_message = "A name of 63 valid characters must plan."
  }
}

run "_a_name_with_digits_and_hyphens_is_accepted" {
  command = plan

  variables {
    name = "lab-2-nodes"
  }

  assert {
    condition     = openstack_networking_network_v2.this.name == "lab-2-nodes"
    error_message = "Digits and hyphens must be accepted."
  }
}

run "the_network_module_refuses_a_range_that_is_not_an_ipv4_network_with_a_zero_host_part" {
  command = plan

  variables {
    cidr = "192.0.2.5/24"
  }

  expect_failures = [var.cidr]
}

run "_a_range_without_a_prefix_is_refused" {
  command = plan

  variables {
    cidr = "192.0.2.0"
  }

  expect_failures = [var.cidr]
}

run "_an_ipv6_range_is_refused" {
  command = plan

  variables {
    cidr = "2001:db8::/32"
  }

  expect_failures = [var.cidr]
}

run "_text_is_refused_as_a_range" {
  command = plan

  variables {
    cidr = "not-a-network"
  }

  expect_failures = [var.cidr]
}

run "_a_network_with_a_zero_host_part_is_accepted" {
  command = plan

  variables {
    cidr       = "198.51.100.128/25"
    dhcp_range = [10, 100]
  }

  assert {
    condition     = openstack_networking_subnet_v2.this.cidr == "198.51.100.128/25"
    error_message = "An IPv4 network written by its own address must plan."
  }
}
