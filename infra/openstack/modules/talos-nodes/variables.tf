variable "name" {
  description = "Name of the cluster: the security group and the server group carry it, and the nodes are <name>-cp-<n> and <name>-w-<n>."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{1,24}$", var.name))
    error_message = "Use 1-24 lowercase letters, digits or hyphens."
  }
}

variable "network" {
  description = "The node network: its ID, the ID of the subnet the nodes' fixed addresses are on, and that subnet's range."
  type = object({
    network_id = string
    subnet_id  = string
    cidr       = string
  })
}

variable "image_id" {
  description = "Glance image of Talos that every node boots."
  type        = string
}

variable "external_network" {
  description = "Name of the external network the nodes' floating IPs come from."
  type        = string
}

variable "api_allowed_cidrs" {
  description = "IPv4 networks, in CIDR form, that may reach the Talos API (TCP 50000) and the Kubernetes API (TCP 6443) on the nodes' floating IPs."
  type        = list(string)
  sensitive   = true
}

variable "controlplane_count" {
  description = "Number of control planes, at host numbers 10 and up of the node subnet."
  type        = number
}

variable "worker_count" {
  description = "Number of workers, at host numbers 20 and up of the node subnet."
  type        = number
}

variable "controlplane_flavor" {
  description = "Nova flavor of the control planes."
  type        = string
}

variable "worker_flavor" {
  description = "Nova flavor of the workers."
  type        = string
}

variable "root_volume_size_gb" {
  description = "Size of every node's boot volume in GB; Talos runs from it."
  type        = number
  default     = 40
}

variable "volume_type" {
  description = "Cinder volume type of the boot volumes, or null for the project's default type."
  type        = string
  default     = null
}

variable "allowed_address_pairs" {
  description = "Ranges every node's port may also send from and receive for, besides the node's own address. Empty by default: the CNI tunnels traffic between nodes, so a port only ever carries its node's address."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags for every resource that takes them."
  type        = list(string)
  default     = []
}
