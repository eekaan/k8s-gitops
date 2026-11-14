variable "prefix" {
  description = "Prefix of every resource name: nodes are <prefix>-cp-<n> and <prefix>-w-<n>."
  type        = string
  default     = "lab"
}

variable "cluster_name" {
  description = "Name of the Talos cluster in its talman.yaml, which scripts/infra-talman writes to talos/<cluster_name>/talman.yaml."
  type        = string
  default     = "lab-sto2"
}

variable "versions_file" {
  description = "File the Talos and Kubernetes versions are read from, relative to this stack's directory. The repository's versions.yaml, which Renovate keeps current; the tests point it at a fixture."
  type        = string
  default     = "../../../../../versions.yaml"
}

# Kubernetes gives each node a /24 of the pod subnet for its pods. A range that overlaps another
# makes some addresses ambiguous, so pods, Services and nodes each have their own.
variable "pod_subnet" {
  description = "IPv4 network the pods take their addresses from, in CIDR form, with a /24 for every node and apart from the service and node subnets. By default Kubernetes' conventional pod range, private and used only inside the cluster."
  type        = string
  default     = "10.244.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.pod_subnet)) && try(cidrhost(var.pod_subnet, 0) == split("/", var.pod_subnet)[0], false)
    error_message = "pod_subnet must be an IPv4 network in CIDR form, written with its first address, such as 198.51.100.0/24."
  }

  validation {
    condition     = try(!cidrcontains(var.pod_subnet, local.plumbing.network.cidr) && !cidrcontains(local.plumbing.network.cidr, var.pod_subnet), true)
    error_message = "pod_subnet must not overlap the node subnet."
  }

  validation {
    condition     = try(pow(2, 24 - tonumber(split("/", var.pod_subnet)[1])) >= var.controlplane_count + var.worker_count, true)
    error_message = "pod_subnet must hold a /24 for every node, as Kubernetes gives each node a /24 of it."
  }
}

variable "service_subnet" {
  description = "IPv4 network the Services take their cluster IPs from, in CIDR form, apart from the pod and node subnets. By default Kubernetes' conventional service range, private and used only inside the cluster."
  type        = string
  default     = "10.96.0.0/12"

  validation {
    condition     = can(cidrnetmask(var.service_subnet)) && try(cidrhost(var.service_subnet, 0) == split("/", var.service_subnet)[0], false)
    error_message = "service_subnet must be an IPv4 network in CIDR form, written with its first address, such as 198.51.100.0/24."
  }

  validation {
    condition     = try(!cidrcontains(var.service_subnet, local.plumbing.network.cidr) && !cidrcontains(local.plumbing.network.cidr, var.service_subnet), true)
    error_message = "service_subnet must not overlap the node subnet."
  }

  validation {
    condition     = try(!cidrcontains(var.service_subnet, var.pod_subnet) && !cidrcontains(var.pod_subnet, var.service_subnet), true)
    error_message = "service_subnet must not overlap pod_subnet."
  }
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
