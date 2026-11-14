variable "prefix" {
  description = "Prefix of every resource name."
  type        = string
  default     = "lab"
}

variable "node_cidr" {
  description = "IPv4 range of the node subnet, at least a /24. Fixed node addresses sit below host offset 100; DHCP hands out 100 to 200."
  type        = string
  default     = "10.10.0.0/24"
}

variable "versions_file" {
  description = "File the Talos version is read from, relative to this stack's directory. The repository's versions.yaml, which Renovate keeps current; the tests point it at a fixture."
  type        = string
  default     = "../../../../../versions.yaml"
}

variable "external_network" {
  description = "Name of the cloud's external network, which the router's gateway is on and floating IPs come from."
  type        = string
  default     = "ext-net"
}
