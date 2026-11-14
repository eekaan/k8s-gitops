variable "prefix" {
  description = "Prefix of every resource name: nodes are <prefix>-cp-<n> and <prefix>-w-<n>."
  type        = string
  default     = "lab"
}

variable "plumbing_state" {
  description = "Settings of the s3 backend that holds the plumbing stack's state, as a backend block takes them (bucket, key, region, endpoints and so on). Filled at run time; nothing about the backend is committed."
  type        = any
}

variable "api_allowed_cidrs" {
  description = "IPv4 networks, in CIDR form, that may reach the Talos API (TCP 50000) and the Kubernetes API (TCP 6443) on the nodes' floating IPs, and the Kubernetes API on the load balancer: the operator allowlist. Supplied at run time and never committed."
  type        = list(string)
  sensitive   = true

  validation {
    condition     = length(var.api_allowed_cidrs) > 0 && alltrue([for cidr in var.api_allowed_cidrs : can(cidrnetmask(cidr))])
    error_message = "api_allowed_cidrs must hold at least one IPv4 network in CIDR form, such as 192.0.2.0/24, and nothing else."
  }
}

variable "controlplane_count" {
  description = "Number of control planes."
  type        = number
  default     = 3
}

variable "worker_count" {
  description = "Number of workers."
  type        = number
  default     = 3
}

variable "controlplane_flavor" {
  description = "Nova flavor of the control planes."
  type        = string
  default     = "b.4c8gb"
}

variable "worker_flavor" {
  description = "Nova flavor of the workers."
  type        = string
  default     = "b.6c16gb"
}

variable "api_lb_provider" {
  description = "Octavia provider of the Kubernetes API load balancer, or null for the cloud's default."
  type        = string
  default     = null
}

variable "api_lb_flavor_id" {
  description = "Octavia flavor of the Kubernetes API load balancer, or null for the cloud's default."
  type        = string
  default     = null
}
