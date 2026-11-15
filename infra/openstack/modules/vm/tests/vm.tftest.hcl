# The module alone, against a mocked provider: no credentials, no state, no network beyond the
# provider plugin tofu init fetches. Addresses are the documentation ranges.

mock_provider "openstack" {}

variables {
  name                = "node-1"
  flavor              = "flavor-fixture"
  image_id            = "image-fixture"
  root_volume_size_gb = 40
  network_id          = "network-fixture"
  subnet_id           = "subnet-fixture"
  fixed_ip            = "192.0.2.10"
  security_group_ids  = ["group-a-fixture", "group-b-fixture"]
}

run "the_vm_module_boots_from_a_volume_made_from_the_image_at_the_size_given" {
  command = plan

  assert {
    condition     = length(openstack_compute_instance_v2.this.block_device) == 1
    error_message = "The instance must have exactly one boot device and no other block device."
  }

  assert {
    condition = output.boot_volume == {
      source_type           = "image"
      image_id              = "image-fixture"
      destination_type      = "volume"
      size                  = 40
      boot_index            = 0
      delete_on_termination = true
    }
    error_message = "The instance must boot from a 40 GB volume made from the image, deleted with the instance."
  }
}

run "_another_root_volume_size_is_given" {
  command = plan

  variables {
    root_volume_size_gb = 100
  }

  assert {
    condition     = output.boot_volume.size == 100
    error_message = "The boot volume must have the size given."
  }
}

run "the_vm_module_gives_every_volume_the_volume_type_given" {
  command = plan

  variables {
    volume_type  = "type-fixture"
    data_volumes = { data = 100 }
  }

  assert {
    condition     = openstack_compute_instance_v2.this.block_device[0].volume_type == "type-fixture" && openstack_blockstorage_volume_v3.data["data"].volume_type == "type-fixture"
    error_message = "The boot volume and the data volume must have the volume type given."
  }
}

run "_without_a_volume_type_the_projects_default_applies" {
  command = plan

  variables {
    data_volumes = { data = 100 }
  }

  assert {
    condition     = openstack_compute_instance_v2.this.block_device[0].volume_type == null && openstack_blockstorage_volume_v3.data["data"].volume_type != "type-fixture"
    error_message = "Without a volume type the boot volume must name none. The data volume's type is computed, so a plan shows only that it is not one given."
  }
}

# A mocked apply leaves the instance in state, and the instance ignores later changes to its boot
# device, so the runs that plan a boot device come before the first apply.
run "the_vm_module_puts_the_port_on_the_fixed_address_with_port_security_and_the_groups_given" {
  command = apply

  assert {
    condition     = length(openstack_compute_instance_v2.this.network) == 1 && openstack_compute_instance_v2.this.network[0].port == openstack_networking_port_v2.this.id
    error_message = "The instance's one network must be the module's port."
  }

  assert {
    condition = output.port == {
      id                    = openstack_networking_port_v2.this.id
      network_id            = "network-fixture"
      subnet_id             = "subnet-fixture"
      address               = "192.0.2.10"
      port_security_enabled = true
      security_group_ids    = toset(["group-a-fixture", "group-b-fixture"])
      allowed_address_pairs = []
    }
    error_message = "The port must be on the network and subnet given at the fixed address, with port security and exactly the groups given."
  }

  assert {
    condition     = openstack_networking_port_v2.this.name == "node-1" && openstack_networking_port_v2.this.admin_state_up == true
    error_message = "The port must carry the instance's name and be up."
  }
}

run "the_vm_module_gives_the_port_exactly_the_allowed_address_pairs_it_is_given" {
  command = plan

  assert {
    condition     = length(openstack_networking_port_v2.this.allowed_address_pairs) == 0
    error_message = "The port must carry no allowed address pair by default."
  }
}

run "_two_allowed_address_pairs_are_given" {
  command = plan

  variables {
    allowed_address_pairs = ["198.51.100.0/24", "203.0.113.0/26"]
  }

  assert {
    condition     = toset(output.port.allowed_address_pairs) == toset(["198.51.100.0/24", "203.0.113.0/26"]) && length(output.port.allowed_address_pairs) == 2
    error_message = "The port must carry exactly the two ranges given."
  }
}

run "_an_allowed_address_pair_listed_twice_is_carried_once" {
  command = plan

  variables {
    allowed_address_pairs = ["198.51.100.0/24", "198.51.100.0/24"]
  }

  assert {
    condition     = output.port.allowed_address_pairs == ["198.51.100.0/24"]
    error_message = "A range listed twice must be carried once."
  }
}

run "the_vm_module_gives_the_instance_no_user_data_unless_given_some" {
  command = plan

  assert {
    condition     = openstack_compute_instance_v2.this.user_data == null && output.user_data == null
    error_message = "The instance must have no user data by default."
  }
}

run "_user_data_is_given" {
  command = plan

  variables {
    user_data = "#cloud-config\n{}\n"
  }

  assert {
    condition     = openstack_compute_instance_v2.this.user_data == "#cloud-config\n{}\n"
    error_message = "The instance must carry exactly the user data given."
  }
}

run "the_vm_module_gives_the_instance_the_flavor_and_key_pair_it_is_given" {
  command = plan

  assert {
    condition     = openstack_compute_instance_v2.this.flavor_name == "flavor-fixture" && output.flavor == "flavor-fixture"
    error_message = "The instance must have the flavor given."
  }

  assert {
    condition     = openstack_compute_instance_v2.this.key_pair == null && output.key_pair == null
    error_message = "The instance must have no key pair by default."
  }
}

run "_a_key_pair_is_given" {
  command = plan

  variables {
    key_pair = "key-fixture"
  }

  assert {
    condition     = openstack_compute_instance_v2.this.key_pair == "key-fixture" && output.key_pair == "key-fixture"
    error_message = "The instance must have the key pair given."
  }
}

run "the_vm_module_schedules_into_a_server_group_only_when_given_one" {
  command = plan

  assert {
    condition     = length(openstack_compute_instance_v2.this.scheduler_hints) == 0 && output.server_group_id == null
    error_message = "The instance must have no scheduler hint without a server group."
  }
}

run "_a_server_group_is_given" {
  command = plan

  variables {
    server_group_id = "server-group-fixture"
  }

  assert {
    condition     = length(openstack_compute_instance_v2.this.scheduler_hints) == 1 && output.server_group_id == "server-group-fixture"
    error_message = "The instance's one scheduler hint must be the server group given."
  }
}

run "the_vm_module_makes_one_data_volume_and_attachment_per_entry_named_after_the_instance" {
  command = apply

  assert {
    condition     = length(openstack_blockstorage_volume_v3.data) == 0 && length(openstack_compute_volume_attach_v2.data) == 0 && output.data_volumes == {}
    error_message = "Without data volumes there must be no volume and no attachment."
  }
}

run "_two_data_volumes_are_given" {
  command = apply

  variables {
    data_volumes = { data = 100, logs = 20 }
  }

  assert {
    condition     = keys(openstack_blockstorage_volume_v3.data) == ["data", "logs"] && keys(openstack_compute_volume_attach_v2.data) == ["data", "logs"]
    error_message = "There must be one volume and one attachment per entry, keyed by its name."
  }

  assert {
    condition     = openstack_blockstorage_volume_v3.data["data"].name == "node-1-data" && openstack_blockstorage_volume_v3.data["data"].size == 100 && openstack_blockstorage_volume_v3.data["logs"].name == "node-1-logs" && openstack_blockstorage_volume_v3.data["logs"].size == 20
    error_message = "Each volume must be named after the instance and the entry and have the size given."
  }

  assert {
    condition     = alltrue([for v in values(openstack_blockstorage_volume_v3.data) : v.enable_online_resize == true])
    error_message = "A data volume must grow while attached."
  }

  assert {
    condition = alltrue([
      for k, a in openstack_compute_volume_attach_v2.data :
      a.instance_id == openstack_compute_instance_v2.this.id && a.volume_id == openstack_blockstorage_volume_v3.data[k].id
    ])
    error_message = "Each attachment must join the instance and the volume of its own entry."
  }

  assert {
    condition     = output.data_volumes["data"].id == openstack_blockstorage_volume_v3.data["data"].id && output.data_volumes["logs"].id == openstack_blockstorage_volume_v3.data["logs"].id
    error_message = "The data_volumes output must report each volume's ID under its name."
  }
}

# Talos nodes are upgraded through their API, and a replaced control plane's disk would take its
# etcd data with it, so a new image must leave a running instance as it is. The first run is the
# instance as applied; the mocked provider plans no replacement of its own, so what the second
# keeps is what the configuration keeps.
run "_the_instance_is_applied" {
  command = apply
}

run "the_vm_module_keeps_a_running_instance_when_the_image_changes" {
  command = plan

  variables {
    image_id = "image-replacement-fixture"
  }

  assert {
    condition     = output.boot_volume.image_id == "image-fixture"
    error_message = "The planned boot device must still be made from the image the instance was applied with."
  }
}

run "the_vm_module_refuses_a_name_that_is_not_lowercase_letters_digits_and_hyphens" {
  command = plan

  variables {
    name = "Node-1"
  }

  expect_failures = [var.name]
}

run "_an_underscore_in_the_name_is_refused" {
  command = plan

  variables {
    name = "node_1"
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
    condition     = output.name == "a"
    error_message = "A name of one valid character must plan."
  }
}

run "_a_name_of_63_characters_is_accepted" {
  command = plan

  variables {
    name = join("", [for i in range(63) : "a"])
  }

  assert {
    condition     = length(output.name) == 63
    error_message = "A name of 63 valid characters must plan."
  }
}

run "_a_name_with_digits_and_hyphens_is_accepted" {
  command = plan

  variables {
    name = "lab-2-node"
  }

  assert {
    condition     = output.name == "lab-2-node"
    error_message = "Digits and hyphens must be accepted."
  }
}
