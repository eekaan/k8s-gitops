variable "name" {
  description = "Name of the network and its subnet."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{1,63}$", var.name))
    error_message = "Use 1-63 lowercase letters, digits or hyphens."
  }
}

variable "cidr" {
  description = "IPv4 range of the subnet, in CIDR form."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.cidr)) && cidrsubnet(var.cidr, 0, 0) == var.cidr
    error_message = "Must be an IPv4 network in CIDR form with a zero host part."
  }
}

variable "gateway" {
  description = "Give the subnet a gateway address, so that once attached to a router it reaches other networks."
  type        = bool
  default     = false
}

variable "port_security" {
  description = "Neutron port security on the network, inherited by its ports. Security groups filter only ports that have it."
  type        = bool
  default     = false
}

variable "dhcp_range" {
  description = "Host offsets of the first and last address in the DHCP allocation pool."
  type        = tuple([number, number])
  default     = [10, 200]
}

variable "dns_nameservers" {
  description = "DNS resolvers DHCP hands out; empty leaves Neutron's default."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags for the network and subnet."
  type        = list(string)
  default     = []
}
