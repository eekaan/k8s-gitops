# The cluster stack as it was applied before its workers had data volumes, and as the next plan has
# it with them. The provider is mocked and the plumbing stack's state is overridden, so these runs
# need no credentials and read no state.
#
# A mocked provider never plans a replacement itself; the real one replaces a server when an
# attribute it cannot update in place changes. So the plan is asserted to leave every instance
# exactly as the apply left it, its ID, boot volume, user data, server group and port included,
# which a replacement OpenTofu planned on its own would change. What the real provider plans for
# the running servers shows only in the real plan.

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

# A mocked attribute has the same value in every instance of a resource, so each node's instance
# gets an ID of its own, and an attachment to another node cannot pass.
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

# The running cluster before the data volumes: the nodes and the load balancer, with everything
# they are made of and read, and nothing else. A test's plan options cannot exclude resources, so
# the others are targeted, and tofu warns that the plan is targeted.
run "_the_cluster_is_applied_without_data_volumes" {
  command = apply

  plan_options {
    target = [module.nodes, module.api_lb]
  }

  assert {
    condition     = length(output.instances) == 6
    error_message = "The apply must leave the six nodes' instances."
  }

  assert {
    condition     = length(openstack_blockstorage_volume_v3.worker_data) == 0 && length(openstack_compute_volume_attach_v2.worker_data) == 0
    error_message = "The apply must leave no data volume and no attachment."
  }
}

run "attaching_a_data_volume_replaces_no_server" {
  command = plan

  variables {
    # What the apply above left, to compare the plan with.
    applied = run._the_cluster_is_applied_without_data_volumes.instances
  }

  assert {
    condition = (
      keys(openstack_blockstorage_volume_v3.worker_data) == ["lab-w-1", "lab-w-2", "lab-w-3"] &&
      { for name, attachment in openstack_compute_volume_attach_v2.worker_data : name => attachment.instance_id } == { for name in ["lab-w-1", "lab-w-2", "lab-w-3"] : name => var.applied[name].id }
    )
    error_message = "The plan must add one data volume per worker and attach it to the instance the apply left."
  }

  assert {
    condition = length(output.instances) == 6 && alltrue([
      for name, instance in output.instances : instance.id == var.applied[name].id
    ])
    error_message = "Attaching the data volumes must not replace an instance."
  }

  assert {
    condition     = output.instances == var.applied
    error_message = "Attaching the data volumes must leave every instance as the apply left it."
  }
}
