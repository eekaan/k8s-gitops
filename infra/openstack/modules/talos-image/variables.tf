variable "name" {
  description = "Prefix of the image name."
  type        = string
}

variable "talos_version" {
  description = "Talos release the image boots."
  type        = string
}

variable "schematic" {
  description = "Image Factory schematic, as YAML."
  type        = string
}

variable "tags" {
  description = "Tags for the image."
  type        = list(string)
  default     = []
}
