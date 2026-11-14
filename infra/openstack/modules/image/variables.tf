variable "name" {
  description = "Name of the image in Glance."
  type        = string
}

variable "source_url" {
  description = "URL the image is downloaded from."
  type        = string

  validation {
    condition     = startswith(var.source_url, "https://")
    error_message = "Use an https:// URL."
  }
}

variable "decompress" {
  description = "Decompress the download before uploading it, for a URL that serves a compressed image."
  type        = bool
  default     = false
}

variable "disk_format" {
  description = "Glance disk format of the image as uploaded."
  type        = string
  default     = "raw"
}

variable "properties" {
  description = "Glance image properties."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags for the image."
  type        = list(string)
  default     = []
}
