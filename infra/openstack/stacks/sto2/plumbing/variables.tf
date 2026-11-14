variable "prefix" {
  description = "Prefix of every resource name."
  type        = string
  default     = "lab"
}

variable "node_cidr" {
  description = "IPv4 range of the node subnet, at least a /24. Fixed addresses, the nodes' and the edge routers', sit below host offset 100; DHCP hands out 100 to 200."
  type        = string
  default     = "10.10.0.0/24"
}

# Services of type LoadBalancer take their addresses from the service range, and the workers
# advertise each over BGP to two edge routers on the node subnet (ADR 0013). These numbers live here,
# with the subnet's plan, as the edge routers outlive a rebuild of the cluster.

variable "edge_hosts" {
  description = "Host numbers in node_cidr of the two edge routers' fixed addresses, which the workers peer with over BGP: below the DHCP pool, among the fixed addresses, where the cluster stack puts the API load balancer at 5 and the nodes from 10 up."
  type        = list(number)
  default     = [6, 7]

  validation {
    condition     = length(var.edge_hosts) == 2 && length(distinct(var.edge_hosts)) == 2
    error_message = "edge_hosts must name two different host numbers, one for each edge router."
  }

  validation {
    condition     = alltrue([for host in var.edge_hosts : floor(host) == host && host > 1 && host < local.dhcp_range[0]])
    error_message = "edge_hosts must be whole host numbers above the gateway's, 1, and below the DHCP pool, which starts at host number 100."
  }
}

variable "service_range" {
  description = "Private IPv4 range, in CIDR form, that Services of type LoadBalancer take their addresses from. It lies outside node_cidr: only BGP makes it reachable, through the edge routers. The cluster stack checks that it overlaps neither its pod nor its service subnet."
  type        = string
  default     = "10.20.0.0/28"

  validation {
    condition     = can(cidrnetmask(var.service_range)) && try(cidrhost(var.service_range, 0) == split("/", var.service_range)[0], false)
    error_message = "service_range must be an IPv4 network in CIDR form, written with its first address, such as 198.51.100.0/28."
  }

  validation {
    condition = try(anytrue([
      for private in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"] :
      cidrcontains(private, cidrhost(var.service_range, 0)) && cidrcontains(private, cidrhost(var.service_range, -1))
    ]), false)
    error_message = "service_range must lie in one of the private ranges of RFC 1918."
  }

  validation {
    condition     = try(!cidrcontains(var.service_range, cidrhost(var.node_cidr, 0)) && !cidrcontains(var.node_cidr, cidrhost(var.service_range, 0)), true)
    error_message = "service_range must not overlap node_cidr."
  }
}

# eBGP between two private 16-bit AS numbers (RFC 6996: 64512 to 65534).
variable "cluster_asn" {
  description = "Autonomous system number of the cluster's workers, from the private 16-bit range."
  type        = number
  default     = 64513

  validation {
    condition     = floor(var.cluster_asn) == var.cluster_asn && var.cluster_asn >= 64512 && var.cluster_asn <= 65534
    error_message = "cluster_asn must be a private 16-bit AS number, 64512 to 65534."
  }
}

variable "edge_asn" {
  description = "Autonomous system number of the edge routers, from the private 16-bit range and apart from cluster_asn."
  type        = number
  default     = 64512

  validation {
    condition     = floor(var.edge_asn) == var.edge_asn && var.edge_asn >= 64512 && var.edge_asn <= 65534
    error_message = "edge_asn must be a private 16-bit AS number, 64512 to 65534."
  }

  validation {
    condition     = var.edge_asn != var.cluster_asn
    error_message = "edge_asn must differ from cluster_asn: the workers and the edge routers peer over eBGP."
  }
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
