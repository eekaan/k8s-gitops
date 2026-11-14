variable "name" {
  description = "Name of the router."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{1,63}$", var.name))
    error_message = "Use 1-63 lowercase letters, digits or hyphens."
  }
}

variable "external_network" {
  description = "Name of the external network the router's gateway is on and its traffic leaves through."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets to attach to the router, keyed by names known at plan time."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags for the router."
  type        = list(string)
  default     = []
}
