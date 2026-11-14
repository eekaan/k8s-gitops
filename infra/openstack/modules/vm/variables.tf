variable "name" {
  description = "Name of the instance and its port. Data volumes are named <name>-<volume>."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{1,63}$", var.name))
    error_message = "Use 1-63 lowercase letters, digits or hyphens."
  }
}

variable "flavor" {
  description = "Nova flavor name. The root disk is always a volume, so flavors without a local disk work."
  type        = string
}

variable "image_id" {
  description = "Glance image the boot volume is made from."
  type        = string
}

variable "root_volume_size_gb" {
  description = "Size of the boot volume in GB."
  type        = number
}

variable "volume_type" {
  description = "Cinder volume type of every volume, or null for the project's default type."
  type        = string
  default     = null
}

variable "data_volumes" {
  description = "Volumes attached after the boot volume, keyed by name, each its size in GB. Empty: none."
  type        = map(number)
  default     = {}
}

variable "network_id" {
  description = "Network of the instance's port."
  type        = string
}

variable "subnet_id" {
  description = "Subnet the port's fixed address is on."
  type        = string
}

variable "fixed_ip" {
  description = "Fixed address of the port. Keep it outside the subnet's DHCP pool, from which Neutron assigns addresses to other ports."
  type        = string
}

variable "security_group_ids" {
  description = "Security groups of the port."
  type        = list(string)
}

variable "allowed_address_pairs" {
  description = "Addresses or CIDRs the port may also send from and receive for, besides its fixed address."
  type        = list(string)
  default     = []
}

variable "server_group_id" {
  description = "Nova server group the instance is scheduled into, or null."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags for the instance and its port."
  type        = list(string)
  default     = []
}
