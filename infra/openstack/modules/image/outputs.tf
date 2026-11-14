output "id" {
  description = "ID of the uploaded image."
  value       = openstack_images_image_v2.this.id
}

output "name" {
  description = "Name of the image in Glance."
  value       = openstack_images_image_v2.this.name
}

output "source_url" {
  description = "URL the image was downloaded from."
  value       = openstack_images_image_v2.this.image_source_url
}

output "decompress" {
  description = "Whether the download was decompressed before it was uploaded."
  value       = openstack_images_image_v2.this.decompress
}

output "disk_format" {
  description = "Glance disk format of the image."
  value       = openstack_images_image_v2.this.disk_format
}

output "visibility" {
  description = "Who can see the image in Glance."
  value       = openstack_images_image_v2.this.visibility
}
