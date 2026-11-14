variable "prefix" {
  description = "Prefix of every resource name: the edges are <prefix>-edge-1 and <prefix>-edge-2."
  type        = string
  default     = "lab"
}

variable "plumbing_state" {
  description = "Settings of the s3 backend that holds the plumbing stack's state, as a backend block takes them (bucket, key, region, endpoints and so on). Filled at run time; nothing about the backend is committed."
  type        = any
}

variable "ssh_allowed_cidrs" {
  description = "IPv4 networks, in CIDR form, that may reach the edges' SSH (TCP 22): the operator allowlist, the cluster stack's api_allowed_cidrs. Also the networks the public ports admit, until public_allowed_cidrs says otherwise. Supplied at run time and never committed."
  type        = list(string)
  sensitive   = true

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0 && alltrue([for cidr in var.ssh_allowed_cidrs : can(cidrnetmask(cidr))])
    error_message = "ssh_allowed_cidrs must hold at least one IPv4 network in CIDR form, such as 192.0.2.0/24, and nothing else."
  }
}

variable "public_allowed_cidrs" {
  description = "IPv4 networks, in CIDR form, that may reach the public ports of the edges' floating IPs, or null for the operator allowlist (ssh_allowed_cidrs), so that nothing is open to the world until this is deliberately widened, for instance to 0.0.0.0/0. Supplied at run time and never committed."
  type        = list(string)
  default     = null
  sensitive   = true

  validation {
    condition     = var.public_allowed_cidrs == null || (length(var.public_allowed_cidrs) > 0 && alltrue([for cidr in var.public_allowed_cidrs : can(cidrnetmask(cidr))]))
    error_message = "public_allowed_cidrs must be null or hold at least one IPv4 network in CIDR form, such as 192.0.2.0/24, and nothing else."
  }
}

variable "public_ports" {
  description = "TCP ports the edges forward from their own addresses to the public Gateway's address. The same ports the cluster stack's service_ports admit at the workers from the edges: a test keeps the defaults equal."
  type        = list(number)
  default     = [80, 443]

  validation {
    condition     = length(var.public_ports) > 0 && length(distinct(var.public_ports)) == length(var.public_ports) && alltrue([for port in var.public_ports : floor(port) == port && port >= 1 && port <= 65535 && port != 22 && port != 179])
    error_message = "public_ports must be TCP port numbers, 1 to 65535, each listed once, and neither 22 nor 179, which the edges use themselves."
  }
}

variable "edge_image_name" {
  description = "Name of the Glance image the edges boot: a Debian 13 (trixie) cloud image, the release the configuration is written for. The first boot checks the release and fails loudly on any other. A deployment value, supplied at run time."
  type        = string

  validation {
    condition     = length(trimspace(var.edge_image_name)) > 0
    error_message = "edge_image_name must name an image."
  }
}

variable "edge_ssh_public_key" {
  description = "The public half of the edges' SSH key, one line as in an authorized_keys file, which the edges' key pair gives the image's default user. Read from the file beside the private key that EDGE_SSH_KEY_FILE names. A deployment value, supplied at run time; sensitive, as its comment can name a person or a machine."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/]+=* ?[^\\n]*$", var.edge_ssh_public_key))
    error_message = "edge_ssh_public_key must be one SSH public key line, ssh-ed25519, ecdsa-sha2-nistp* or ssh-rsa followed by the key."
  }
}

variable "flavor" {
  description = "Nova flavor of the edges. They forward packets and run a routing daemon, so a small one is enough."
  type        = string
  default     = "b.2c4gb"
}

variable "root_volume_size_gb" {
  description = "Size in GB of each edge's boot volume."
  type        = number
  default     = 10
}

variable "volume_type" {
  description = "Cinder volume type of the boot volumes, or null for the project's default type."
  type        = string
  default     = null
}

variable "max_workers" {
  description = "The most workers there can be: how many dynamic BGP neighbours an edge accepts and how many equal-cost paths it takes to one address. The cluster stack's numbering leaves room for 80 workers (host numbers 20 to 99); FRR takes at most 128 paths."
  type        = number
  default     = 80

  validation {
    condition     = floor(var.max_workers) == var.max_workers && var.max_workers >= 1 && var.max_workers <= 128
    error_message = "max_workers must be a whole number from 1 to 128."
  }
}
