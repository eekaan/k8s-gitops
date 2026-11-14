# Every provider is mocked, so these runs need no credentials and reach neither the cloud nor the
# Image Factory.

mock_provider "openstack" {}

mock_provider "talos" {
  # A fixed schematic ID, so the expected image name can be written out.
  mock_resource "talos_image_factory_schematic" {
    defaults = {
      id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }
  }
}

run "the_dhcp_pool_leaves_the_low_addresses_for_nodes" {
  command = plan

  variables {
    node_cidr = "192.0.2.0/24"
  }

  assert {
    condition     = output.network.dhcp_pool.start == "192.0.2.100"
    error_message = "The DHCP pool must start at host offset 100, above the fixed node addresses."
  }

  assert {
    condition     = output.network.dhcp_pool.end == "192.0.2.200"
    error_message = "The DHCP pool must end at host offset 200."
  }
}

run "the_router_is_attached_to_the_external_network_by_name" {
  command = plan

  override_data {
    target = module.router.data.openstack_networking_network_v2.external
    values = {
      id = "external-network-id"
    }
  }

  override_resource {
    target = module.network.openstack_networking_subnet_v2.this
    values = {
      id = "node-subnet-id"
    }
  }

  assert {
    condition     = output.router.external_network_lookup.name == "ext-net"
    error_message = "The external network must be looked up by the name ext-net."
  }

  assert {
    condition     = output.router.external_network_lookup.external == true
    error_message = "The lookup must consider external networks only."
  }

  assert {
    condition     = output.router.external_network_id == "external-network-id"
    error_message = "The router's gateway must be the external network found by name."
  }

  assert {
    condition     = values(output.router.attached_subnet_ids) == ["node-subnet-id"]
    error_message = "The node subnet, and only it, must be attached to the router."
  }
}

run "the_image_is_built_from_the_pinned_talos_version_and_schematic" {
  # Applied, still with every provider mocked: a plan defers reading the factory URLs until the
  # schematic exists, so only an apply shows which URL reaches the image.
  command = apply

  # A version no Talos release has, so the expected name cannot match a version written into the
  # stack instead of read from the versions file.
  variables {
    versions_file = "tests/versions.yaml"
  }

  # The provider requires every URL; each is distinct, so the image can only match the disk image.
  override_data {
    target = module.image.data.talos_image_factory_urls.this
    values = {
      urls = {
        disk_image            = "https://image-factory.invalid/disk-image.raw.xz"
        disk_image_secureboot = "https://image-factory.invalid/disk-image-secureboot.raw.xz"
        initramfs             = "https://image-factory.invalid/initramfs.xz"
        installer             = "image-factory.invalid/installer:v0.0.0-fixture"
        installer_secureboot  = "image-factory.invalid/installer-secureboot:v0.0.0-fixture"
        iso                   = "https://image-factory.invalid/image.iso"
        iso_secureboot        = "https://image-factory.invalid/image-secureboot.iso"
        kernel                = "https://image-factory.invalid/kernel"
        kernel_command_line   = "https://image-factory.invalid/cmdline"
        pxe                   = "https://image-factory.invalid/pxe"
        uki                   = "https://image-factory.invalid/uki.efi"
      }
    }
  }

  assert {
    condition     = output.image.source_url == "https://image-factory.invalid/disk-image.raw.xz"
    error_message = "The image must be downloaded from the Image Factory's disk image URL."
  }

  assert {
    condition     = output.image.decompress == true
    error_message = "The compressed disk image must be decompressed before it is uploaded."
  }

  assert {
    condition     = output.image.disk_format == "raw"
    error_message = "The image must be uploaded as a raw disk."
  }

  assert {
    condition     = output.image.visibility == "private"
    error_message = "The image must be private to the project."
  }

  assert {
    condition     = output.image.platform == "openstack"
    error_message = "The image must be built for the openstack platform."
  }

  assert {
    condition     = output.talos_version == "v0.0.0-fixture"
    error_message = "The Talos version must be read from the versions file."
  }

  assert {
    condition     = output.image.name == "lab-talos-v0.0.0-fixture-01234567"
    error_message = "The image name must carry the Talos version from the versions file and the start of the schematic ID."
  }
}
