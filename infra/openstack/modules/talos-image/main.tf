# A Talos node image: the schematic registered with the Image Factory, and the factory's OpenStack
# disk image for it uploaded to Glance.

resource "talos_image_factory_schematic" "this" {
  schematic = var.schematic
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "openstack"
  architecture  = "amd64"
}

module "image" {
  source = "../image"

  name        = "${var.name}-talos-${var.talos_version}-${substr(talos_image_factory_schematic.this.id, 0, 8)}"
  source_url  = data.talos_image_factory_urls.this.urls.disk_image
  decompress  = true
  disk_format = "raw"
  properties  = { os_distro = "talos", os_version = var.talos_version }
  tags        = var.tags
}
