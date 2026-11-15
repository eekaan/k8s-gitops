# The edges as they are once applied, and as the next plan has them once the image EDGE_IMAGE names
# is newer, with one edge's instance replaced on purpose, as just edge-rollout --replace plans it.
# The provider is mocked and the plumbing stack's state is overridden, so these runs need no
# credentials and read no state. Every address is in a documentation range.
#
# The vm module ignores changes to an instance's boot device, so a newer image replaces nothing by
# itself; a mocked provider never plans a replacement on its own either. A replaced instance is
# planned from the configuration alone, the ignored boot device included, so it boots the image the
# name resolves to now. The mock gives a replaced resource the ID it gave the one it replaces, so
# these runs cannot tell a replaced port from a kept one: that the rollout replaces the instance
# and nothing else is its -replace argument, which tests/edge-scripts.bats checks.

mock_provider "openstack" {}

variables {
  # Validated as s3 backend settings, never used: the state it points at is overridden below.
  plumbing_state = {
    bucket = "plumbing-fixture"
    key    = "plumbing.tfstate"
    region = "fixture"
  }

  ssh_allowed_cidrs   = ["198.51.100.0/24"]
  edge_image_name     = "edge-image-name-fixture"
  edge_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMarkerPublicKeyOfTheOperatorFixture marker-key-comment"
}

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
      bgp = {
        cluster_asn     = 64496
        edge_asn        = 64497
        edge_addresses  = ["192.0.2.7", "192.0.2.8"]
        service_range   = "203.0.113.16/28"
        gateway_address = "203.0.113.21"
      }
    }
  }
}

override_resource {
  target = module.edge["1"].openstack_compute_instance_v2.this
  values = { id = "edge-1-instance-fixture" }
}

override_resource {
  target = module.edge["2"].openstack_compute_instance_v2.this
  values = { id = "edge-2-instance-fixture" }
}

override_resource {
  target = openstack_networking_floatingip_v2.edge["1"]
  values = { address = "203.0.113.51" }
}

override_resource {
  target = openstack_networking_floatingip_v2.edge["2"]
  values = { address = "203.0.113.52" }
}

run "_the_edges_boot_the_image_the_name_resolves_to" {
  command = apply

  # The image the name resolves to while the edges are created.
  override_data {
    target = data.openstack_images_image_v2.edge
    values = { id = "edge-image-running" }
  }

  assert {
    condition     = alltrue([for key in ["1", "2"] : output.instances[key].boot_volume.image_id == "edge-image-running"])
    error_message = "Both edges must boot from a volume made from the image EDGE_IMAGE names."
  }
}

run "a_new_image_is_taken_up_only_by_an_edge_whose_replacement_is_forced_which_keeps_its_port_and_floating_ip" {
  command = plan

  variables {
    # What the apply above left, to compare the plan with.
    applied   = run._the_edges_boot_the_image_the_name_resolves_to.instances
    addresses = run._the_edges_boot_the_image_the_name_resolves_to.floating_ips
  }

  # A newer image under the same name: most_recent picks it.
  override_data {
    target = data.openstack_images_image_v2.edge
    values = { id = "edge-image-newer" }
  }

  # What just edge-rollout --replace plans for the first edge.
  plan_options {
    replace = [module.edge["1"].openstack_compute_instance_v2.this]
  }

  assert {
    condition     = output.instances["1"].boot_volume.image_id == "edge-image-newer" && output.instances["1"].boot_volume.delete_on_termination
    error_message = "The edge replaced on purpose must boot from a new volume made from the newer image, the old volume going with the old instance."
  }

  assert {
    condition     = output.instances["1"].port == var.applied["1"].port && output.instances["1"].port.address == "192.0.2.7"
    error_message = "The replaced edge must keep its port, and so its fixed address, security group and port security."
  }

  assert {
    condition     = output.floating_ips["1"] == var.addresses["1"] && output.addresses[0] == "203.0.113.51"
    error_message = "The replaced edge's floating IP and its association with the port must stay as they were."
  }

  assert {
    condition     = output.instances["2"].id == var.applied["2"].id && output.instances["2"].boot_volume == var.applied["2"].boot_volume && output.instances["2"].boot_volume.image_id == "edge-image-running"
    error_message = "A newer image alone must replace no edge: the second edge keeps its instance and its volume made from the old image."
  }

  assert {
    condition     = output.instances["2"].port == var.applied["2"].port && output.floating_ips["2"] == var.addresses["2"]
    error_message = "The second edge's port and floating IP must stay as they were."
  }
}
