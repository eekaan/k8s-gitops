# The workers' data volumes. The provider is mocked and the plumbing stack's state is overridden,
# so these runs need no credentials and read no state.

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

# The plumbing stack's outputs, in the shape it writes them.
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

# A mocked attribute has the same value in every instance of a resource. Each node's instance and
# each worker's volume get their own ID, so a volume attached to another node, a control plane
# included, or another worker's volume cannot pass.
override_resource {
  target = module.nodes.module.node["lab-cp-1"].openstack_compute_instance_v2.this
  values = { id = "instance-cp-1" }
}

override_resource {
  target = module.nodes.module.node["lab-cp-2"].openstack_compute_instance_v2.this
  values = { id = "instance-cp-2" }
}

override_resource {
  target = module.nodes.module.node["lab-cp-3"].openstack_compute_instance_v2.this
  values = { id = "instance-cp-3" }
}

override_resource {
  target = module.nodes.module.node["lab-w-1"].openstack_compute_instance_v2.this
  values = { id = "instance-w-1" }
}

override_resource {
  target = module.nodes.module.node["lab-w-2"].openstack_compute_instance_v2.this
  values = { id = "instance-w-2" }
}

override_resource {
  target = module.nodes.module.node["lab-w-3"].openstack_compute_instance_v2.this
  values = { id = "instance-w-3" }
}

override_resource {
  target = openstack_blockstorage_volume_v3.worker_data["lab-w-1"]
  values = { id = "volume-w-1" }
}

override_resource {
  target = openstack_blockstorage_volume_v3.worker_data["lab-w-2"]
  values = { id = "volume-w-2" }
}

override_resource {
  target = openstack_blockstorage_volume_v3.worker_data["lab-w-3"]
  values = { id = "volume-w-3" }
}

run "every_worker_gets_one_data_volume_and_no_control_plane_does" {
  command = plan

  assert {
    condition = {
      for name, volume in output.worker_data_volumes : name => {
        name        = volume.name
        size        = volume.size
        volume_type = volume.volume_type
      }
      } == {
      "lab-w-1" = { name = "lab-w-1-data", size = 100, volume_type = "cbs" }
      "lab-w-2" = { name = "lab-w-2-data", size = 100, volume_type = "cbs" }
      "lab-w-3" = { name = "lab-w-3-data", size = 100, volume_type = "cbs" }
    }
    error_message = "Each worker, and no control plane, must have one data volume, named after it, of 100 GiB and type cbs."
  }

  # Read from the attachments themselves: a volume given to the instance as a block device would
  # reach only instances created after it.
  assert {
    condition = {
      for name, attachment in openstack_compute_volume_attach_v2.worker_data : name => {
        instance_id = attachment.instance_id
        volume_id   = attachment.volume_id
      }
      } == {
      "lab-w-1" = { instance_id = "instance-w-1", volume_id = "volume-w-1" }
      "lab-w-2" = { instance_id = "instance-w-2", volume_id = "volume-w-2" }
      "lab-w-3" = { instance_id = "instance-w-3", volume_id = "volume-w-3" }
    }
    error_message = "Each worker's data volume must be attached to that worker's own instance by an attachment of its own."
  }

  assert {
    condition     = { for name, volume in output.worker_data_volumes : name => volume.attachment } == { for name, attachment in openstack_compute_volume_attach_v2.worker_data : name => { instance_id = attachment.instance_id, volume_id = attachment.volume_id } }
    error_message = "The worker_data_volumes output must give each worker's attachment as it is."
  }

  # The vm module can attach volumes of its own; no node gets one that way, so the stack's are the
  # only data volumes.
  assert {
    condition     = length(output.instances) == 6 && alltrue([for instance in values(output.instances) : instance.data_volumes == {}])
    error_message = "No node may get a data volume from the vm module; the workers' come from the cluster stack."
  }
}

run "the_data_volumes_size_and_type_come_from_variables" {
  command = plan

  variables {
    worker_data_volume_size = 37
    worker_data_volume_type = "fixture-volume-type"
  }

  assert {
    condition = length(output.worker_data_volumes) == 3 && alltrue([
      for volume in values(output.worker_data_volumes) : volume.size == 37 && volume.volume_type == "fixture-volume-type"
    ])
    error_message = "Every worker's data volume must have the size worker_data_volume_size and the type worker_data_volume_type give."
  }
}

# Talos takes the disk for the raw volume only with 1 GiB free on it, which a 1 GiB volume, less
# its partition table, does not have.
run "_a_data_volume_talos_would_not_take_is_rejected" {
  command = plan

  variables {
    worker_data_volume_size = 1
  }

  expect_failures = [var.worker_data_volume_size]
}

run "_a_data_volume_size_that_is_not_whole_gib_is_rejected" {
  command = plan

  variables {
    worker_data_volume_size = 2.5
  }

  expect_failures = [var.worker_data_volume_size]
}
