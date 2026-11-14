# The provider fetches the image, decompresses it and uploads it to Glance from the machine that
# runs tofu, which therefore needs the bandwidth and the disk space for one image.
resource "openstack_images_image_v2" "this" {
  name             = var.name
  image_source_url = var.source_url
  decompress       = var.decompress
  container_format = "bare"
  disk_format      = var.disk_format
  visibility       = "private"
  properties       = var.properties
  tags             = var.tags
}
