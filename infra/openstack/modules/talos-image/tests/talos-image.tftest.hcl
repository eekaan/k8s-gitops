# The module alone, against mocked providers: no credentials, no state, and neither the Image
# Factory nor Glance is reached. What the image module inside holds beyond its outputs, its
# properties and tags, is the image module's own tests' business, as a run cannot read a resource
# of a module this module calls.

mock_provider "openstack" {}

mock_provider "talos" {
  # A fixed schematic ID, so the expected image name can be written out.
  mock_resource "talos_image_factory_schematic" {
    defaults = {
      id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }
  }

  # The factory's answer, with a URL of its own so an image uploaded from any other cannot pass.
  mock_data "talos_image_factory_urls" {
    defaults = {
      urls = {
        disk_image            = "https://factory.example.com/image/fixture/disk-openstack-amd64.raw.xz"
        disk_image_secureboot = "https://factory.example.com/image/fixture/disk-openstack-amd64-secureboot.raw.xz"
        initramfs             = "https://factory.example.com/image/fixture/initramfs-amd64.xz"
        installer             = "factory.example.com/installer/fixture:v1.0.0"
        installer_secureboot  = "factory.example.com/installer-secureboot/fixture:v1.0.0"
        iso                   = "https://factory.example.com/image/fixture/openstack-amd64.iso"
        iso_secureboot        = "https://factory.example.com/image/fixture/openstack-amd64-secureboot.iso"
        kernel                = "https://factory.example.com/image/fixture/kernel-amd64"
        kernel_command_line   = "https://factory.example.com/image/fixture/cmdline-openstack-amd64"
        pxe                   = "https://factory.example.com/image/fixture/pxe-openstack-amd64"
        uki                   = "https://factory.example.com/image/fixture/uki-amd64.efi"
      }
    }
  }
}

variables {
  name          = "lab"
  talos_version = "v1.0.0"
  schematic     = "customization:\n  systemExtensions:\n    officialExtensions:\n      - siderolabs/fixture\n"
}

run "the_talos_image_module_names_the_image_after_the_talos_version_and_the_start_of_the_schematic_id" {
  command = apply

  assert {
    condition     = output.image_name == "lab-talos-v1.0.0-01234567"
    error_message = "The image name must be the prefix, the Talos version and the first eight characters of the schematic ID."
  }

  assert {
    condition     = output.schematic_id == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    error_message = "The schematic ID output must be the ID the factory gave."
  }
}

run "_another_version_gives_another_name" {
  command = apply

  variables {
    talos_version = "v1.0.1"
  }

  assert {
    condition     = output.image_name == "lab-talos-v1.0.1-01234567"
    error_message = "Another Talos version must give another image name, and so a new image beside the running one."
  }
}

run "_another_schematic_id_gives_another_name" {
  command = apply

  override_resource {
    target = talos_image_factory_schematic.this
    values = { id = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210" }
  }

  assert {
    condition     = output.image_name == "lab-talos-v1.0.0-fedcba98"
    error_message = "Another schematic ID must give another image name."
  }
}

run "the_talos_image_module_asks_the_image_factory_for_the_openstack_amd64_image_of_the_version_and_schematic" {
  command = apply

  assert {
    condition     = talos_image_factory_schematic.this.schematic == var.schematic
    error_message = "The factory must be given the schematic unchanged."
  }

  assert {
    condition     = data.talos_image_factory_urls.this.talos_version == "v1.0.0" && data.talos_image_factory_urls.this.schematic_id == talos_image_factory_schematic.this.id
    error_message = "The factory must be asked about the Talos version and the schematic ID given."
  }

  assert {
    condition     = data.talos_image_factory_urls.this.platform == "openstack" && data.talos_image_factory_urls.this.architecture == "amd64"
    error_message = "The factory must be asked for the openstack platform and the amd64 architecture."
  }

  assert {
    condition     = output.platform == "openstack"
    error_message = "The platform output must report the platform asked for."
  }
}

run "the_talos_image_module_uploads_the_factorys_disk_image_decompressed_raw_and_private" {
  command = apply

  assert {
    condition     = output.source_url == "https://factory.example.com/image/fixture/disk-openstack-amd64.raw.xz"
    error_message = "The image must be uploaded from the factory's disk image URL."
  }

  assert {
    condition     = output.decompress == true && output.disk_format == "raw"
    error_message = "The download must be decompressed and uploaded raw."
  }

  assert {
    condition     = output.visibility == "private"
    error_message = "The image must be visible to its project only."
  }
}
