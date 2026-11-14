variable "name" {
  description = "Name of the cluster: the load balancer, its listener, pool and health monitor are <name>-api."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{1,24}$", var.name))
    error_message = "Use 1-24 lowercase letters, digits or hyphens."
  }
}

variable "network" {
  description = "The node subnet the load balancer's address and its members are on: its ID and range."
  type = object({
    subnet_id = string
    cidr      = string
  })
}

variable "vip_host" {
  description = "Host number of the load balancer's fixed address on the node subnet: below the DHCP pool and clear of every node's host number."
  type        = number
}

variable "members" {
  description = "Fixed private address of each control plane, by node name: the pool's members on the Kubernetes API port."
  type        = map(string)
}

variable "allowed_cidrs" {
  description = "IPv4 networks, in CIDR form, that may reach the Kubernetes API through the load balancer besides the node subnet: the operator allowlist."
  type        = list(string)
  sensitive   = true
}

variable "external_network" {
  description = "Name of the external network the load balancer's floating IP comes from."
  type        = string
}

variable "loadbalancer_provider" {
  description = "Octavia provider of the load balancer, or null for the cloud's default."
  type        = string
  default     = null
}

variable "flavor_id" {
  description = "Octavia flavor of the load balancer, or null for the cloud's default."
  type        = string
  default     = null
}

variable "monitor_delay" {
  description = "Seconds between two health checks of a member."
  type        = number
  default     = 5
}

variable "monitor_timeout" {
  description = "Seconds a health check waits for a member to accept the connection; less than the delay, so one check ends before the next starts."
  type        = number
  default     = 3
}

variable "monitor_max_retries" {
  description = "Consecutive successful checks before a member that was down takes traffic again."
  type        = number
  default     = 2
}

variable "monitor_max_retries_down" {
  description = "Consecutive failed checks before a member stops taking traffic."
  type        = number
  default     = 3
}

variable "tags" {
  description = "Tags for every resource that takes them."
  type        = list(string)
  default     = []
}
