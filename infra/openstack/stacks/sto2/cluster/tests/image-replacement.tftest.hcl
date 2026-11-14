# The nodes as they are once applied, and as the next plan has them after the plumbing stack has a
# new image. The provider is mocked and the plumbing stack's state is overridden, so these runs
# need no credentials and read no state.
#
# A mocked provider never plans a replacement itself; the real one replaces a server whenever its
# block_device changes. So the plan is asserted to leave every node's boot device as it was, made
# from the old image, and every instance's ID as the apply left it, which a replacement OpenTofu
# planned on its own would change.

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

# The plumbing stack's outputs while the nodes are created: the image they boot.
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
        id           = "talos-image-running"
        schematic_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      }
    }
  }
}

run "_the_nodes_boot_the_running_image" {
  command = apply

  assert {
    condition     = length(output.instances) == 6 && alltrue([for instance in values(output.instances) : instance.boot_volume.image_id == "talos-image-running"])
    error_message = "Every node must boot from a volume made from the plumbing stack's image."
  }
}

run "a_new_image_replaces_no_server_and_no_boot_volume" {
  command = plan

  variables {
    # What the apply above left, to compare the plan with.
    applied = run._the_nodes_boot_the_running_image.instances
  }

  # The same plumbing stack, now with a new image built from another schematic.
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
          id           = "talos-image-new"
          schematic_id = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
        }
      }
    }
  }

  assert {
    condition     = output.schematic_id == "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
    error_message = "The plan must read the plumbing stack's new image."
  }

  assert {
    condition = length(output.instances) == 6 && alltrue([
      for name, instance in output.instances : instance.id == var.applied[name].id
    ])
    error_message = "A new image must not replace a node's instance."
  }

  assert {
    condition = length(output.instances) == 6 && alltrue([
      for name, instance in output.instances : instance.boot_volume == var.applied[name].boot_volume
    ])
    error_message = "A new image must leave every node's boot volume as it was, made from the image it was created from."
  }

  assert {
    condition     = alltrue([for instance in values(output.instances) : instance.boot_volume.image_id == "talos-image-running"])
    error_message = "Running nodes must keep the boot volume made from the image they were created from."
  }
}
