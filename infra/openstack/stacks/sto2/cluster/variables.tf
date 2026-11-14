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

variable "security_group_rules" {
  description = "Which rules the nodes' security group holds: full, the default, admits from outside the nodes only the Talos and Kubernetes APIs, from the allowlist, the nodes' floating IPs and the CI host, and the Kubernetes API from the node subnet; reduced keeps those and opens every other port to all, but the Talos API, which a node without machine configuration cannot protect, and the NodePort range, which Cilium serves before Talos' firewall sees it."
  type        = string
  default     = "full"

  validation {
    condition     = contains(["full", "reduced"], var.security_group_rules)
    error_message = "security_group_rules must be full or reduced."
  }
}

variable "ci_host_number" {
  description = "Host number on the node subnet of the CI host the ci stack makes, its host_number, 6 by default: its fixed address then reaches the nodes' Talos API (TCP 50000) and Kubernetes API (TCP 6443). Null, the default, while there is no CI host: the nodes admit nothing for it, and the stack plans without the ci stack."
  type        = number
  default     = null

  validation {
    condition     = var.ci_host_number == null || try(floor(var.ci_host_number) == var.ci_host_number && var.ci_host_number >= 2 && var.ci_host_number <= 9 && var.ci_host_number != 5, false)
    error_message = "ci_host_number must be null or a whole number from 2 to 9 other than 5, the ci stack's host_number: above the gateway, below the control planes' 10 and the DHCP pool, apart from the API load balancer's 5."
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

variable "worker_data_volume_size" {
  description = "Size in GiB of each worker's data volume, the disk the storage layer keeps its data on. At least 2: Talos takes the disk for its raw volume only with 1 GiB free on it (talos/patches/worker/data-volume.yaml)."
  type        = number
  default     = 100

  validation {
    condition     = var.worker_data_volume_size >= 2 && floor(var.worker_data_volume_size) == var.worker_data_volume_size
    error_message = "worker_data_volume_size must be a whole number of GiB, at least 2."
  }
}

variable "worker_data_volume_type" {
  description = "Volume type of each worker's data volume. By default cbs, the cloud's default volume type."
  type        = string
  default     = "cbs"
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
