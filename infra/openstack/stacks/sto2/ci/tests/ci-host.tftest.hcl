# The CI host. The provider is mocked and the plumbing stack's state is overridden, so these runs
# need no credentials and read no state.

mock_provider "openstack" {}

variables {
  # Validated as s3 backend settings, never used: the state it points at is overridden below.
  plumbing_state = {
    bucket = "plumbing-fixture"
    key    = "plumbing.tfstate"
    region = "fixture"
  }

  # Two networks, one of them listed twice: Neutron refuses a rule that already exists, so each
  # network must get its rule once.
  ssh_allowed_cidrs = ["203.0.113.192/26", "198.51.100.0/24", "203.0.113.192/26"]
  image_name        = "ci-image-name-fixture"
  ssh_public_key    = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMarkerPublicKeyOfTheOperatorFixture marker-key-comment"
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
    }
  }
}

override_data {
  target = data.openstack_images_image_v2.host
  values = { id = "ci-image-fixture" }
}

# A mocked attribute has the same value in every resource of a type. The instance, its port, the
# cache volume and the floating IP get their own, so one wired to another cannot pass.
override_resource {
  target = module.host.openstack_compute_instance_v2.this
  values = { id = "ci-instance-fixture" }
}

override_resource {
  target = module.host.openstack_networking_port_v2.this
  values = { id = "ci-port-fixture" }
}

override_resource {
  target = openstack_blockstorage_volume_v3.cache
  values = { id = "0123456789abcdefghijklmnopqrstuvwxyz" }
}

override_resource {
  target = openstack_networking_floatingip_v2.host
  values = { address = "203.0.113.50" }
}

override_resource {
  target = openstack_networking_secgroup_v2.host
  values = { id = "ci-security-group-fixture" }
}

run "the_ci_host_is_reachable_over_ssh_from_the_allowlist_and_from_nowhere_else" {
  command = plan

  assert {
    condition = toset([
      for rule in output.security_group.rules : {
        direction = rule.direction
        ethertype = rule.ethertype
        protocol  = rule.protocol
        ports     = rule.port_range_min == null && rule.port_range_max == null ? "all" : "${rule.port_range_min}-${rule.port_range_max}"
        source    = rule.remote_ip_prefix
      }
      ]) == toset(concat(
      [for cidr in ["198.51.100.0/24", "203.0.113.192/26"] : {
        direction = "ingress"
        ethertype = "IPv4"
        protocol  = "tcp"
        ports     = "22-22"
        source    = cidr
      }],
      [for pair in [["IPv4", "0.0.0.0/0"], ["IPv6", "::/0"]] : {
        direction = "egress"
        ethertype = pair[0]
        protocol  = null
        ports     = "all"
        source    = pair[1]
      }],
    ))
    error_message = "The CI host's group must admit TCP 22 from each allowlisted network and nothing else inbound, and let everything out."
  }

  assert {
    condition     = length(output.security_group.rules) == 4
    error_message = "There must be one SSH rule per allowlisted network, none twice, and one egress rule per ethertype."
  }

  assert {
    condition     = output.security_group.delete_default_rules == true
    error_message = "The group must hold no rule a cloud adds to new groups by default, only its own."
  }

  assert {
    condition     = alltrue([for rule in output.security_group.rules : rule.security_group_id == "ci-security-group-fixture"])
    error_message = "Every rule must belong to the CI host's group."
  }

  assert {
    condition     = output.instance.port.port_security_enabled == true && output.instance.port.security_group_ids == toset(["ci-security-group-fixture"])
    error_message = "The CI host's port must have port security on and the CI host's group as its only group."
  }

  assert {
    condition = output.floating_ip == {
      address     = "203.0.113.50"
      pool        = "external-network-fixture"
      association = { floating_ip = "203.0.113.50", port_id = "ci-port-fixture" }
    }
    error_message = "The CI host must have a floating IP from the plumbing stack's external network, associated with its port."
  }

  assert {
    condition     = output.address == "203.0.113.50"
    error_message = "The address output must be the CI host's floating address, where ci-host-setup reaches it."
  }
}

run "_an_empty_or_malformed_ssh_allowlist_is_rejected" {
  command = plan

  variables {
    ssh_allowed_cidrs = ["198.51.100.0/24", "not-a-cidr"]
  }

  expect_failures = [var.ssh_allowed_cidrs]
}

run "_an_empty_ssh_allowlist_is_rejected" {
  command = plan

  variables {
    ssh_allowed_cidrs = []
  }

  expect_failures = [var.ssh_allowed_cidrs]
}

run "_the_ci_host_sits_at_a_fixed_address_outside_the_dhcp_pool_and_the_nodes_addresses" {
  command = plan

  assert {
    condition     = output.private_address == "192.0.2.6"
    error_message = "The CI host must sit at host number 6 of the node subnet: below the DHCP pool, the control planes' 10 and the workers' 20, and apart from the API load balancer's 5."
  }

  assert {
    condition     = output.instance.port.network_id == "node-network-fixture" && output.instance.port.subnet_id == "node-subnet-fixture"
    error_message = "The CI host's port must be on the plumbing stack's node network and subnet."
  }

  assert {
    condition = output.instance.boot_volume == {
      source_type           = "image"
      image_id              = "ci-image-fixture"
      destination_type      = "volume"
      size                  = 40
      boot_index            = 0
      delete_on_termination = true
    }
    error_message = "The CI host must boot from a 40 GB volume made from the image its name looks up, deleted with the instance."
  }

  assert {
    condition     = output.instance.flavor == "b.4c8gb" && output.instance.name == "lab-ci" && output.runner_name == "lab-ci"
    error_message = "The CI host must be lab-ci, of the flavor b.4c8gb, and the runner must be named after it."
  }

  assert {
    condition     = output.instance.key_pair == "lab-ci"
    error_message = "The CI host must take the operator's public key from its key pair, not from its user data."
  }
}

run "_a_host_number_in_the_dhcp_pool_or_among_the_nodes_is_rejected" {
  command = plan

  variables {
    host_number = 10
  }

  expect_failures = [var.host_number]
}

run "_a_public_key_that_is_not_one_is_rejected" {
  command = plan

  variables {
    ssh_public_key = "marker-not-a-public-key"
  }

  expect_failures = [var.ssh_public_key]
}

run "the_engines_cache_is_on_a_volume_of_its_own" {
  command = plan

  assert {
    # Without volume_type the cloud picks the type, so a mocked plan gives it a value of its own.
    condition = { for key, value in output.cache_volume : key => value if key != "volume_type" } == {
      id   = "0123456789abcdefghijklmnopqrstuvwxyz"
      name = "lab-ci-cache"
      size = 100
      attachment = {
        instance_id = "ci-instance-fixture"
        volume_id   = "0123456789abcdefghijklmnopqrstuvwxyz"
      }
    }
    error_message = "The cache must be a 100 GiB volume of its own, lab-ci-cache, attached to the CI host by an attachment of its own."
  }

  assert {
    condition     = output.instance.data_volumes == {}
    error_message = "The cache volume must not be a block device of the instance, which the provider would replace the server for."
  }

  assert {
    condition     = output.cache_mountpoint == "/var/lib/dagger"
    error_message = "The cache must be mounted where the engine keeps its state, /var/lib/dagger."
  }

  # The volume is found by its serial, the first 20 characters of its ID, under /dev/disk/by-id,
  # formatted only when blkid finds no file system on it, and mounted at the mountpoint.
  assert {
    condition = alltrue([
      strcontains(output.user_data, "/dev/disk/by-id/*0123456789abcdefghij*"),
      !strcontains(output.user_data, "0123456789abcdefghijk"),
      strcontains(output.user_data, "blkid \"$dev\" > /dev/null || mkfs.ext4"),
      strcontains(output.user_data, "$dev /var/lib/dagger ext4"),
      strcontains(output.user_data, "mount /var/lib/dagger"),
    ])
    error_message = "The first boot must find the cache volume by its serial, format it only when it holds no file system, and mount it at /var/lib/dagger."
  }
}

run "_the_cache_volumes_size_and_type_come_from_variables" {
  command = plan

  variables {
    cache_volume_size = 250
    volume_type       = "volume-type-fixture"
  }

  assert {
    condition     = output.cache_volume.size == 250 && output.cache_volume.volume_type == "volume-type-fixture"
    error_message = "The cache volume must take its size and type from cache_volume_size and volume_type."
  }
}

run "the_user_data_holds_no_secret" {
  command = plan

  assert {
    condition     = output.instance.user_data == output.user_data && startswith(output.user_data, "#cloud-config\n")
    error_message = "The instance must get the rendered cloud-config as its user data."
  }

  assert {
    condition     = sort(keys(yamldecode(output.user_data))) == tolist(["packages", "runcmd", "users"])
    error_message = "The user data must do nothing but install packages, create users and run the cache volume's mount."
  }

  assert {
    condition     = yamldecode(output.user_data).packages == ["docker.io"]
    error_message = "The user data must install a container runtime and nothing else."
  }

  assert {
    condition = yamldecode(output.user_data).users == [
      "default",
      {
        name        = "ci-runner"
        gecos       = "GitHub Actions runner"
        shell       = "/bin/bash"
        lock_passwd = true
      },
    ]
    error_message = "The user data must keep the image's default user and add the runner's user, with no password, no sudo and no groups: the docker group is root on the host."
  }

  assert {
    condition = alltrue([
      for text in [
        "AAAAC3NzaC1lZDI1NTE5AAAAIMarkerPublicKeyOfTheOperatorFixture",
        "marker-key-comment",
        "198.51.100.0",
        "203.0.113.192",
        "203.0.113.50",
        "ci-image-name-fixture",
      ] : !strcontains(output.user_data, text)
    ])
    error_message = "The user data must hold neither the public key, the allowlist, the floating address nor the image name."
  }

  assert {
    condition     = length(regexall("(?i)passw|token|secret|ssh_authorized_keys|ssh_keys|write_files|chpasswd|sudo", replace(output.user_data, "lock_passwd: true", ""))) == 0
    error_message = "The user data must set no password, key, token or file, and grant no sudo."
  }
}
