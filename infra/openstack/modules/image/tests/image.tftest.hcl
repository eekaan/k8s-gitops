# The module alone, against a mocked provider: no credentials, no state, no network beyond the
# provider plugin tofu init fetches. The URLs are never fetched.

mock_provider "openstack" {}

variables {
  name       = "talos-fixture"
  source_url = "https://images.example.com/disk.raw.xz"
}

run "the_image_module_uploads_a_private_bare_image_from_the_url_it_is_given" {
  command = plan

  assert {
    condition     = openstack_images_image_v2.this.name == "talos-fixture" && openstack_images_image_v2.this.image_source_url == "https://images.example.com/disk.raw.xz"
    error_message = "The image must carry the name and the source URL given."
  }

  assert {
    condition     = openstack_images_image_v2.this.container_format == "bare"
    error_message = "The container format must be bare."
  }

  assert {
    condition     = openstack_images_image_v2.this.visibility == "private" && output.visibility == "private"
    error_message = "The image must be visible to its project only."
  }

  assert {
    condition     = output.name == "talos-fixture" && output.source_url == "https://images.example.com/disk.raw.xz"
    error_message = "The outputs must report the name and the source URL."
  }
}

run "the_image_module_decompresses_the_download_only_when_asked_and_uploads_the_disk_format_given" {
  command = plan

  assert {
    condition     = openstack_images_image_v2.this.decompress == false && output.decompress == false
    error_message = "The download must not be decompressed by default."
  }

  assert {
    condition     = openstack_images_image_v2.this.disk_format == "raw" && output.disk_format == "raw"
    error_message = "The disk format must be raw by default."
  }
}

run "_decompression_and_another_disk_format_are_given" {
  command = plan

  variables {
    decompress  = true
    disk_format = "qcow2"
  }

  assert {
    condition     = openstack_images_image_v2.this.decompress == true && output.decompress == true
    error_message = "The download must be decompressed when asked."
  }

  assert {
    condition     = openstack_images_image_v2.this.disk_format == "qcow2" && output.disk_format == "qcow2"
    error_message = "The disk format must be the one given."
  }
}

run "the_image_module_gives_the_image_the_properties_and_tags_it_is_given" {
  command = plan

  variables {
    properties = { os_distro = "talos", os_version = "v0.0.0" }
    tags       = ["lab", "talos"]
  }

  assert {
    condition     = openstack_images_image_v2.this.properties == tomap({ os_distro = "talos", os_version = "v0.0.0" })
    error_message = "The image must carry exactly the properties given."
  }

  assert {
    condition     = openstack_images_image_v2.this.tags == toset(["lab", "talos"])
    error_message = "The image must carry the tags given."
  }
}

run "_without_properties_or_tags_the_image_has_none" {
  command = plan

  assert {
    condition     = length(openstack_images_image_v2.this.properties) == 0 && length(openstack_images_image_v2.this.tags) == 0
    error_message = "The image must carry no property or tag by default."
  }
}

run "the_image_module_refuses_a_source_url_that_is_not_https" {
  command = plan

  variables {
    source_url = "http://images.example.com/disk.raw.xz"
  }

  expect_failures = [var.source_url]
}

run "_an_ftp_url_is_refused" {
  command = plan

  variables {
    source_url = "ftp://images.example.com/disk.raw.xz"
  }

  expect_failures = [var.source_url]
}

run "_a_path_is_refused_as_a_url" {
  command = plan

  variables {
    source_url = "/var/lib/images/disk.raw"
  }

  expect_failures = [var.source_url]
}

run "_an_empty_url_is_refused" {
  command = plan

  variables {
    source_url = ""
  }

  expect_failures = [var.source_url]
}

run "_an_https_url_is_accepted" {
  command = plan

  variables {
    source_url = "https://images.example.com/other.raw"
  }

  assert {
    condition     = openstack_images_image_v2.this.image_source_url == "https://images.example.com/other.raw"
    error_message = "An https URL must plan."
  }
}
