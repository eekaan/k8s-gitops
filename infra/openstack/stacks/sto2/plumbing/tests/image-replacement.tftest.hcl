# The image as it is once applied, and as the next plan has it after a new Talos version or
# schematic. Every provider is mocked, so these runs need no credentials and reach neither the
# cloud nor the Image Factory.

mock_provider "openstack" {}

mock_provider "talos" {
  # A fixed schematic ID, so the expected image names can be written out.
  mock_resource "talos_image_factory_schematic" {
    defaults = {
      id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }
  }
}

# The provider requires every URL; fixed, so no run sees a URL change it did not make.
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

run "_the_image_of_the_running_version_is_applied" {
  command = apply

  variables {
    versions_file = "tests/versions.yaml"
  }

  assert {
    condition     = output.image.name == "lab-talos-v0.0.0-fixture-01234567"
    error_message = "The applied image must be named after the Talos version in tests/versions.yaml and the schematic ID."
  }
}

run "a_new_talos_version_gives_the_image_a_new_name" {
  command = plan

  variables {
    versions_file = "../../../../../tests/fixtures/image-replacement/versions.yaml"
  }

  assert {
    condition     = output.talos_version == "v0.0.1-fixture"
    error_message = "The plan must read the new Talos version from the versions file."
  }

  assert {
    condition     = output.image.name == "lab-talos-v0.0.1-fixture-01234567"
    error_message = "After a new Talos version the image's planned name must carry that version."
  }
}

# The same scenario for a new schematic, whose ID the Image Factory derives from its content. A
# scenario is proved by one run of its name, so this case is named apart from it.
run "_a_new_schematic_gives_the_image_a_new_name" {
  command = plan

  variables {
    versions_file = "tests/versions.yaml"
  }

  override_resource {
    target = module.image.talos_image_factory_schematic.this
    values = {
      id = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
    }
  }

  assert {
    condition     = output.image.name == "lab-talos-v0.0.0-fixture-fedcba98"
    error_message = "After a new schematic the image's planned name must carry the start of its new ID."
  }
}
