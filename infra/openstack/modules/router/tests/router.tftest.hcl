# The module alone, against a mocked provider: no credentials, no state, no network beyond the
# provider plugin tofu init fetches.

mock_provider "openstack" {}

variables {
  name             = "lab"
  external_network = "external-network-fixture"
}

# An ID of its own for the looked-up network, so a gateway on any other value cannot pass.
override_data {
  target = data.openstack_networking_network_v2.external
  values = { id = "external-network-id" }
}

run "the_router_module_puts_the_gateway_on_the_external_network_found_by_name" {
  command = plan

  assert {
    condition     = data.openstack_networking_network_v2.external.name == "external-network-fixture" && data.openstack_networking_network_v2.external.external == true
    error_message = "The network must be looked up by the name given, among external networks only."
  }

  assert {
    condition     = openstack_networking_router_v2.this.external_network_id == "external-network-id" && output.external_network_id == "external-network-id"
    error_message = "The router's gateway must be on the network the lookup found."
  }

  assert {
    condition     = output.external_network_name == "external-network-fixture" && output.external_network_lookup == { name = "external-network-fixture", external = true }
    error_message = "The outputs must report the name and that only external networks were searched."
  }

  assert {
    condition     = openstack_networking_router_v2.this.name == "lab"
    error_message = "The router must carry the name given."
  }
}

run "the_router_module_attaches_exactly_the_subnets_it_is_given_keyed_as_given" {
  command = plan

  assert {
    condition     = length(openstack_networking_router_interface_v2.this) == 0 && output.attached_subnet_ids == {}
    error_message = "Without subnets the router must have no interface."
  }
}

run "_two_subnets_are_attached_by_name" {
  command = plan

  variables {
    subnet_ids = { nodes = "node-subnet-fixture", pods = "pod-subnet-fixture" }
  }

  assert {
    condition     = keys(openstack_networking_router_interface_v2.this) == ["nodes", "pods"]
    error_message = "There must be one interface per subnet, keyed by the name it was given under."
  }

  assert {
    condition     = openstack_networking_router_interface_v2.this["nodes"].subnet_id == "node-subnet-fixture" && openstack_networking_router_interface_v2.this["pods"].subnet_id == "pod-subnet-fixture"
    error_message = "Each interface must be on its own subnet."
  }

  assert {
    condition     = output.attached_subnet_ids == { nodes = "node-subnet-fixture", pods = "pod-subnet-fixture" }
    error_message = "The attached subnets must be reported keyed like the input."
  }
}

run "the_router_module_tags_the_router" {
  command = plan

  variables {
    tags = ["lab", "router"]
  }

  assert {
    condition     = openstack_networking_router_v2.this.tags == toset(["lab", "router"])
    error_message = "The router must carry the tags given."
  }
}

run "the_router_module_refuses_a_name_that_is_not_lowercase_letters_digits_and_hyphens" {
  command = plan

  variables {
    name = "Lab"
  }

  expect_failures = [var.name]
}

run "_an_underscore_in_the_name_is_refused" {
  command = plan

  variables {
    name = "lab_router"
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
    condition     = openstack_networking_router_v2.this.name == "a"
    error_message = "A name of one valid character must plan."
  }
}

run "_a_name_of_63_characters_is_accepted" {
  command = plan

  variables {
    name = join("", [for i in range(63) : "a"])
  }

  assert {
    condition     = length(openstack_networking_router_v2.this.name) == 63
    error_message = "A name of 63 valid characters must plan."
  }
}

run "_a_name_with_digits_and_hyphens_is_accepted" {
  command = plan

  variables {
    name = "lab-2-edge"
  }

  assert {
    condition     = openstack_networking_router_v2.this.name == "lab-2-edge"
    error_message = "Digits and hyphens must be accepted."
  }
}
