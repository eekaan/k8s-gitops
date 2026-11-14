output "image_id" {
  description = "ID of the Glance image the nodes boot."
  value       = module.image.id
}

output "image_name" {
  description = "Name of the image: the prefix, the Talos version and the start of the schematic ID."
  value       = module.image.name
}

output "source_url" {
  description = "Image Factory URL the disk image was downloaded from."
  value       = module.image.source_url
}

output "decompress" {
  description = "Whether the downloaded disk image was decompressed before it was uploaded."
  value       = module.image.decompress
}

output "disk_format" {
  description = "Glance disk format of the image."
  value       = module.image.disk_format
}

output "visibility" {
  description = "Who can see the image in Glance."
  value       = module.image.visibility
}

output "platform" {
  description = "Image Factory platform the image is built for."
  value       = data.talos_image_factory_urls.this.platform
}

output "schematic_id" {
  description = "ID the Image Factory gave the schematic. It is a hash of the schematic's content, so any tool given the same schematic computes the same ID."
  value       = talos_image_factory_schematic.this.id
}
