variable "prefix" {
  description = "Prefix of every resource name: the CI host is <prefix>-ci, which also names its runner."
  type        = string
  default     = "lab"
}

variable "plumbing_state" {
  description = "Settings of the s3 backend that holds the plumbing stack's state, as a backend block takes them (bucket, key, region, endpoints and so on). Filled at run time; nothing about the backend is committed."
  type        = any
}

variable "ssh_allowed_cidrs" {
  description = "IPv4 networks, in CIDR form, that may reach the CI host's SSH (TCP 22): the operator allowlist, the cluster stack's api_allowed_cidrs. Supplied at run time and never committed."
  type        = list(string)
  sensitive   = true

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0 && alltrue([for cidr in var.ssh_allowed_cidrs : can(cidrnetmask(cidr))])
    error_message = "ssh_allowed_cidrs must hold at least one IPv4 network in CIDR form, such as 192.0.2.0/24, and nothing else."
  }
}

variable "image_name" {
  description = "Name of the Glance image the CI host boots: a Debian or Ubuntu cloud image, whose cloud-init installs packages with apt. A deployment value, supplied at run time."
  type        = string

  validation {
    condition     = length(trimspace(var.image_name)) > 0
    error_message = "image_name must name an image."
  }
}

variable "ssh_public_key" {
  description = "The operator's SSH public key, one line as in an authorized_keys file, which the CI host's key pair gives the image's default user. A deployment value, supplied at run time; sensitive, as its comment can name a person or a machine."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/]+=* ?[^\\n]*$", var.ssh_public_key))
    error_message = "ssh_public_key must be one SSH public key line, ssh-ed25519, ecdsa-sha2-nistp* or ssh-rsa followed by the key."
  }
}

variable "host_number" {
  description = "Host number of the CI host's fixed address on the node subnet: above the gateway, below the control planes' 10 and the DHCP pool, and apart from the API load balancer's 5 and the plumbing stack's edge_hosts. The cluster stack's ci_host_number, when the nodes are to admit the CI host."
  type        = number
  default     = 6

  validation {
    condition     = floor(var.host_number) == var.host_number && var.host_number >= 2 && var.host_number <= 9 && var.host_number != 5
    error_message = "host_number must be a whole number from 2 to 9 other than 5: above the gateway, below the control planes' 10 and the DHCP pool, apart from the API load balancer's 5."
  }

  # The plumbing stack reserves the edge routers' fixed addresses by host number as well. Its state
  # must give them: a plumbing state without them fails the plan rather than skip the check.
  validation {
    condition     = !contains(local.plumbing.bgp.edge_addresses, try(cidrhost(local.plumbing.network.cidr, var.host_number), null))
    error_message = "host_number must not be one of the plumbing stack's edge_hosts: the CI host and the edge routers each need a fixed address of their own on the node subnet."
  }
}

variable "flavor" {
  description = "Nova flavor of the CI host."
  type        = string
  default     = "b.4c8gb"
}

variable "root_volume_size_gb" {
  description = "Size in GB of the CI host's boot volume, which holds the system, the runner and its jobs' workspaces."
  type        = number
  default     = 40
}

variable "cache_volume_size" {
  description = "Size in GiB of the cache volume, where the Dagger engine keeps its state."
  type        = number
  default     = 100

  validation {
    condition     = var.cache_volume_size >= 10 && floor(var.cache_volume_size) == var.cache_volume_size
    error_message = "cache_volume_size must be a whole number of GiB, at least 10."
  }
}

variable "volume_type" {
  description = "Cinder volume type of the boot and cache volumes, or null for the project's default type."
  type        = string
  default     = null
}

variable "runner_user" {
  description = "The unprivileged user the CI host's first boot creates and the GitHub Actions runner runs as."
  type        = string
  default     = "ci-runner"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.runner_user))
    error_message = "runner_user must be a user name of lower-case letters, digits and hyphens, starting with a letter."
  }
}
