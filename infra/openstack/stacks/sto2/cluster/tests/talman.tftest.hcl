# The provider is mocked and the plumbing stack's state is overridden, so these runs need no
# credentials and read no state. talman.yaml is read back with yamldecode, as talman reads it.

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

# The plumbing stack's outputs, in the shape it writes them. None of the values is a plumbing
# default, so a value written into this stack instead of read from that state cannot match.
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

# A mocked attribute has the same value in every instance of a resource. Each node's floating IP and
# the load balancer's get their own, so an address taken from another node, or a node's private
# address in place of its floating one, cannot pass.
override_resource {
  target = module.nodes.openstack_networking_floatingip_v2.node["lab-cp-1"]
  values = { address = "203.0.113.101" }
}

override_resource {
  target = module.nodes.openstack_networking_floatingip_v2.node["lab-cp-2"]
  values = { address = "203.0.113.102" }
}

override_resource {
  target = module.nodes.openstack_networking_floatingip_v2.node["lab-cp-3"]
  values = { address = "203.0.113.103" }
}

override_resource {
  target = module.nodes.openstack_networking_floatingip_v2.node["lab-w-1"]
  values = { address = "203.0.113.111" }
}

override_resource {
  target = module.nodes.openstack_networking_floatingip_v2.node["lab-w-2"]
  values = { address = "203.0.113.112" }
}

override_resource {
  target = module.nodes.openstack_networking_floatingip_v2.node["lab-w-3"]
  values = { address = "203.0.113.113" }
}

override_resource {
  target = module.api_lb.openstack_networking_floatingip_v2.this
  values = { address = "203.0.113.50" }
}

run "the_rendered_talman_yaml_lists_every_node_at_its_floating_address" {
  command = plan

  assert {
    condition = yamldecode(output.talman_yaml).nodes == [
      { hostname = "lab-cp-1", role = "controlplane", ipAddress = "203.0.113.101", values = { floatingIP = "203.0.113.101" } },
      { hostname = "lab-cp-2", role = "controlplane", ipAddress = "203.0.113.102", values = { floatingIP = "203.0.113.102" } },
      { hostname = "lab-cp-3", role = "controlplane", ipAddress = "203.0.113.103", values = { floatingIP = "203.0.113.103" } },
      { hostname = "lab-w-1", role = "worker", ipAddress = "203.0.113.111", values = { floatingIP = "203.0.113.111" } },
      { hostname = "lab-w-2", role = "worker", ipAddress = "203.0.113.112", values = { floatingIP = "203.0.113.112" } },
      { hostname = "lab-w-3", role = "worker", ipAddress = "203.0.113.113", values = { floatingIP = "203.0.113.113" } },
    ]
    error_message = "talman.yaml must list the three control planes and then the three workers, each by name, with its role, at its own floating address and with that address as its floating IP."
  }

  assert {
    condition = {
      for node in yamldecode(output.talman_yaml).nodes : node.hostname => { role = node.role, address = node.ipAddress }
      } == {
      for name, node in output.nodes : name => { role = node.role, address = node.floating_address }
    }
    error_message = "talman.yaml must hold one node per instance, each with the role and floating address the nodes output gives it."
  }
}

run "the_cluster_endpoint_is_the_load_balancers_private_address" {
  command = plan

  assert {
    condition     = yamldecode(output.talman_yaml).endpoint == output.api_endpoint
    error_message = "talman.yaml's endpoint must be the api_endpoint output."
  }

  assert {
    condition     = yamldecode(output.talman_yaml).endpoint == "https://192.0.2.5:6443"
    error_message = "talman.yaml's endpoint must be the Kubernetes API at the load balancer's private address."
  }

  assert {
    condition = length(yamldecode(output.talman_yaml).values.apiSANs) == 5 && toset(yamldecode(output.talman_yaml).values.apiSANs) == toset([
      "192.0.2.5",
      "203.0.113.50",
      "203.0.113.101",
      "203.0.113.102",
      "203.0.113.103",
    ])
    error_message = "The API certificate names must be the load balancer's private and floating addresses and each control plane's floating address, each once."
  }
}

run "talman_yaml_names_the_address_the_recipes_reach_the_api_on" {
  command = plan

  assert {
    condition     = yamldecode(output.talman_yaml).values.apiAddress == output.api_floating_address
    error_message = "talman.yaml's values.apiAddress must be the api_floating_address output."
  }

  assert {
    condition     = yamldecode(output.talman_yaml).values.apiAddress == "203.0.113.50"
    error_message = "talman.yaml's values.apiAddress must be the load balancer's floating address."
  }

  assert {
    condition     = contains(yamldecode(output.talman_yaml).values.apiSANs, yamldecode(output.talman_yaml).values.apiAddress)
    error_message = "The API address must be one of the API certificate names."
  }
}

run "versions_come_from_versions_yaml" {
  command = plan

  variables {
    versions_file = "../../../../../tests/fixtures/infra-talman/versions.yaml"
  }

  assert {
    condition     = yamldecode(output.talman_yaml).talosVersion == "v0.0.0-talos-fixture"
    error_message = "talman.yaml's Talos version must be the versions file's."
  }

  assert {
    condition     = yamldecode(output.talman_yaml).kubernetesVersion == "v0.0.0-kubernetes-fixture"
    error_message = "talman.yaml's Kubernetes version must be the versions file's."
  }
}

# The template's other inputs, which no scenario names: the cluster's name, the node subnet from the
# plumbing stack, and the pod and service subnets; and the image's schematic ID beside them.
run "_the_cluster_is_named_lab_sto2_on_the_plumbing_stacks_node_subnet" {
  command = plan

  assert {
    condition     = yamldecode(output.talman_yaml).clusterName == "lab-sto2"
    error_message = "The cluster must be named lab-sto2 by default."
  }

  assert {
    condition     = yamldecode(output.talman_yaml).values.nodeSubnet == "192.0.2.0/24"
    error_message = "talman.yaml's node subnet must be the plumbing stack's."
  }

  assert {
    condition     = output.schematic_id == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    error_message = "The schematic_id output must be the schematic ID of the plumbing stack's image."
  }
}

# The workers' patches, for the data volume, form a group of their own. talman refuses a patch group
# no node is in, so a cluster without workers has none.
run "_the_workers_have_a_patch_group_of_their_own" {
  command = plan

  assert {
    condition     = yamldecode(output.talman_yaml).patches.worker == ["../patches/worker/data-volume.yaml"]
    error_message = "talman.yaml must give the workers the data volume's patch in their own group."
  }
}

run "_a_cluster_without_workers_has_no_worker_patch_group" {
  command = plan

  variables {
    controlplane_count = 1
    worker_count       = 0
  }

  assert {
    condition     = !contains(keys(yamldecode(output.talman_yaml).patches), "worker")
    error_message = "talman.yaml must hold no worker patch group when there is no worker, as talman refuses a group no node is in."
  }
}

# Kubernetes gives each node a /24 of the pod subnet. The subnets in these runs come from the
# documentation ranges, so a run that needs a pod subnet to be accepted plans one control plane and
# no workers: a /24 then holds the one node's range.
run "_the_cluster_name_and_subnets_come_from_the_variables" {
  command = plan

  variables {
    cluster_name       = "fixture-cluster"
    controlplane_count = 1
    worker_count       = 0
    pod_subnet         = "198.51.100.0/24"
    service_subnet     = "203.0.113.128/25"
  }

  assert {
    condition     = yamldecode(output.talman_yaml).clusterName == "fixture-cluster"
    error_message = "talman.yaml's cluster name must be the cluster_name variable."
  }

  assert {
    condition     = yamldecode(output.talman_yaml).values.podSubnet == "198.51.100.0/24"
    error_message = "talman.yaml's pod subnet must be the pod_subnet variable."
  }

  assert {
    condition     = yamldecode(output.talman_yaml).values.serviceSubnet == "203.0.113.128/25"
    error_message = "talman.yaml's service subnet must be the service_subnet variable."
  }
}

run "overlapping_or_undersized_cluster_subnets_are_rejected" {
  command = plan

  variables {
    controlplane_count = 1
    worker_count       = 0
    pod_subnet         = "198.51.100.0/24"
    service_subnet     = "198.51.100.0/24"
  }

  expect_failures = [var.service_subnet]
}

# The same scenario with each of the other ways the subnets can be wrong. A scenario is proved by
# one run of its name, so these cases are named apart from it. The runs that hold the node subnet
# replace the plumbing state for a smaller node subnet, and tofu warns that they replace it.
run "_a_service_subnet_inside_the_pod_subnet_is_rejected" {
  command = plan

  variables {
    controlplane_count = 1
    worker_count       = 0
    pod_subnet         = "198.51.100.0/24"
    service_subnet     = "198.51.100.128/25"
  }

  expect_failures = [var.service_subnet]
}

run "_a_pod_subnet_on_the_node_subnet_is_rejected" {
  command = plan

  variables {
    controlplane_count = 1
    worker_count       = 0
    pod_subnet         = "192.0.2.0/24"
  }

  expect_failures = [var.pod_subnet]
}

run "_a_pod_subnet_holding_the_node_subnet_is_rejected" {
  command = plan

  variables {
    controlplane_count = 1
    worker_count       = 0
    pod_subnet         = "192.0.2.0/24"
  }

  override_data {
    target = data.terraform_remote_state.plumbing
    values = {
      outputs = {
        network = {
          network_id = "node-network-fixture"
          subnet_id  = "node-subnet-fixture"
          cidr       = "192.0.2.128/25"
          dhcp_pool  = { start = "192.0.2.228", end = "192.0.2.250" }
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

  expect_failures = [var.pod_subnet]
}

run "_a_service_subnet_inside_the_node_subnet_is_rejected" {
  command = plan

  variables {
    service_subnet = "192.0.2.0/25"
  }

  expect_failures = [var.service_subnet]
}

run "_a_service_subnet_holding_the_node_subnet_is_rejected" {
  command = plan

  variables {
    service_subnet = "192.0.2.0/24"
  }

  override_data {
    target = data.terraform_remote_state.plumbing
    values = {
      outputs = {
        network = {
          network_id = "node-network-fixture"
          subnet_id  = "node-subnet-fixture"
          cidr       = "192.0.2.128/25"
          dhcp_pool  = { start = "192.0.2.228", end = "192.0.2.250" }
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

  expect_failures = [var.service_subnet]
}

# One /24 holds one node's pod range, and two nodes are planned.
run "_a_pod_subnet_too_small_for_the_nodes_is_rejected" {
  command = plan

  variables {
    controlplane_count = 1
    worker_count       = 1
    pod_subnet         = "198.51.100.0/24"
  }

  expect_failures = [var.pod_subnet]
}

run "_a_malformed_pod_subnet_is_rejected" {
  command = plan

  variables {
    pod_subnet = "not-a-cidr"
  }

  expect_failures = [var.pod_subnet]
}

run "_a_service_subnet_that_is_not_a_network_address_is_rejected" {
  command = plan

  variables {
    # A host address with a prefix, not a network.
    service_subnet = "198.51.100.1/24"
  }

  expect_failures = [var.service_subnet]
}
