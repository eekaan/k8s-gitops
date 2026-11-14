# The numbers Services announced over BGP rest on, which this stack defines once and the cluster
# stack reads from its state. Every provider is mocked, so these runs need no credentials and reach
# neither the cloud nor the Image Factory. The cluster stack's own tests check them against its
# nodes, its load balancer and its pod and service subnets.

mock_provider "openstack" {}

mock_provider "talos" {
  mock_resource "talos_image_factory_schematic" {
    defaults = {
      id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }
  }
}

# The stack's defaults, so a default that collides fails here and not first in a real plan.
run "_the_edge_addresses_lie_below_the_dhcp_pool_and_the_service_range_outside_the_node_subnet" {
  command = plan

  assert {
    condition     = output.bgp.edge_addresses == [cidrhost(output.network.cidr, 6), cidrhost(output.network.cidr, 7)]
    error_message = "The edge routers must sit at host numbers 6 and 7 of the node subnet."
  }

  assert {
    condition = alltrue([
      for edge in output.bgp.edge_addresses :
      !contains([for host in range(100, 201) : cidrhost(output.network.cidr, host)], edge) && edge != cidrhost(output.network.cidr, 1)
    ]) && output.network.dhcp_pool.start == cidrhost(output.network.cidr, 100)
    error_message = "No edge address may be in the DHCP pool, which starts at host number 100, or the gateway's."
  }

  assert {
    condition     = !cidrcontains(output.network.cidr, cidrhost(output.bgp.service_range, 0)) && !cidrcontains(output.bgp.service_range, cidrhost(output.network.cidr, 0))
    error_message = "The service range must lie outside the node subnet."
  }

  assert {
    condition = alltrue([
      for asn in [output.bgp.cluster_asn, output.bgp.edge_asn] : asn >= 64512 && asn <= 65534
    ]) && output.bgp.cluster_asn != output.bgp.edge_asn
    error_message = "The cluster and the edge routers must have two different private 16-bit AS numbers, for eBGP between them."
  }
}

run "_an_edge_host_in_the_dhcp_pool_is_rejected" {
  command = plan

  variables {
    edge_hosts = [6, 150]
  }

  expect_failures = [var.edge_hosts]
}

run "_an_edge_host_on_the_gateway_is_rejected" {
  command = plan

  variables {
    edge_hosts = [1, 7]
  }

  expect_failures = [var.edge_hosts]
}

run "_one_address_for_both_edge_routers_is_rejected" {
  command = plan

  variables {
    edge_hosts = [6, 6]
  }

  expect_failures = [var.edge_hosts]
}

# Private ranges, so only the overlap with the node subnet can be what is refused.
run "_a_service_range_on_the_node_subnet_is_rejected" {
  command = plan

  variables {
    node_cidr     = "10.10.0.0/24"
    service_range = "10.10.0.0/24"
  }

  expect_failures = [var.service_range]
}

run "_a_service_range_around_the_node_subnet_is_rejected" {
  command = plan

  variables {
    node_cidr     = "10.10.0.0/24"
    service_range = "10.0.0.0/8"
  }

  expect_failures = [var.service_range]
}

run "_a_service_range_outside_the_private_ranges_is_rejected" {
  command = plan

  variables {
    service_range = "203.0.113.16/28"
  }

  expect_failures = [var.service_range]
}

run "_one_as_for_both_ends_is_rejected" {
  command = plan

  variables {
    edge_asn    = 64600
    cluster_asn = 64600
  }

  expect_failures = [var.edge_asn]
}

run "_an_as_outside_the_private_16_bit_range_is_rejected" {
  command = plan

  variables {
    cluster_asn = 65535
  }

  expect_failures = [var.cluster_asn]
}
