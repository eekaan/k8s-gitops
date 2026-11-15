# The edge routers. The provider is mocked and the plumbing stack's state is overridden, so these
# runs need no credentials and read no state. Every address is in a documentation range.

mock_provider "openstack" {}

variables {
  # Validated as s3 backend settings, never used: the state it points at is overridden below.
  plumbing_state = {
    bucket = "plumbing-fixture"
    key    = "plumbing.tfstate"
    region = "fixture"
  }

  # Two networks, one of them listed twice: Neutron refuses a rule that already exists.
  ssh_allowed_cidrs   = ["203.0.113.192/26", "198.51.100.0/24", "203.0.113.192/26"]
  edge_image_name     = "edge-image-name-fixture"
  edge_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMarkerPublicKeyOfTheOperatorFixture marker-key-comment"
}

# The plumbing stack's outputs, in the shape it writes them. None of the values is a plumbing
# default, so a value written into this stack instead of read from that state cannot match.
override_data {
  target = data.terraform_remote_state.plumbing
  values = {
    outputs = {
      network = {
        network_id = "node-network-fixture"
        subnet_id  = "node-subnet-fixture"
        cidr       = "192.0.2.0/24"
        dhcp_pool  = { start = "192.0.2.100", end = "192.0.2.200" }
      }
      router = {
        external_network    = "external-network-fixture"
        attached_subnet_ids = { nodes = "node-subnet-fixture" }
      }
      bgp = {
        cluster_asn    = 64496
        edge_asn       = 64497
        edge_addresses = ["192.0.2.7", "192.0.2.8"]
        service_range  = "203.0.113.16/28"
        # Host number 5, not the first host of the range, which is the default: an edge that derived
        # the address itself from the range could not match it.
        gateway_address = "203.0.113.21"
      }
    }
  }
}

override_data {
  target = data.openstack_images_image_v2.edge
  values = { id = "edge-image-fixture" }
}

# A mocked attribute has the same value in every resource of a type; each edge's instance, port
# and floating IP gets its own, so one wired to the other cannot pass.
override_resource {
  target = module.edge["1"].openstack_compute_instance_v2.this
  values = { id = "edge-1-instance-fixture" }
}

override_resource {
  target = module.edge["2"].openstack_compute_instance_v2.this
  values = { id = "edge-2-instance-fixture" }
}

override_resource {
  target = module.edge["1"].openstack_networking_port_v2.this
  values = { id = "edge-1-port-fixture" }
}

override_resource {
  target = module.edge["2"].openstack_networking_port_v2.this
  values = { id = "edge-2-port-fixture" }
}

override_resource {
  target = openstack_networking_floatingip_v2.edge["1"]
  values = { address = "203.0.113.51" }
}

override_resource {
  target = openstack_networking_floatingip_v2.edge["2"]
  values = { address = "203.0.113.52" }
}

override_resource {
  target = openstack_networking_secgroup_v2.edge
  values = { id = "edge-security-group-fixture" }
}

override_resource {
  target = openstack_compute_servergroup_v2.edges
  values = { id = "edge-server-group-fixture" }
}

run "the_stack_makes_two_edges_at_the_reserved_addresses_apart_from_each_other_each_with_a_public_address_and_plans_without_the_cluster_stack" {
  command = plan

  assert {
    condition     = output.names == ["lab-edge-1", "lab-edge-2"]
    error_message = "The edges must be <prefix>-edge-1 and <prefix>-edge-2."
  }

  assert {
    condition     = [for key in ["1", "2"] : output.instances[key].port.address] == ["192.0.2.7", "192.0.2.8"]
    error_message = "The edges' ports must be at the plumbing stack's two reserved edge addresses, in order."
  }

  assert {
    condition     = output.instances["1"].port.network_id == "node-network-fixture" && output.instances["1"].port.subnet_id == "node-subnet-fixture"
    error_message = "The ports must be on the plumbing stack's node network and attached subnet."
  }

  assert {
    condition     = output.floating_ips["1"].address != output.floating_ips["2"].address && output.addresses == ["203.0.113.51", "203.0.113.52"]
    error_message = "Each edge must have a floating IP of its own, and the sensitive output addresses must list both."
  }

  assert {
    condition = (
      output.floating_ips["1"].association.port_id == "edge-1-port-fixture" &&
      output.floating_ips["2"].association.port_id == "edge-2-port-fixture" &&
      output.floating_ips["1"].pool == "external-network-fixture"
    )
    error_message = "Each floating IP must be associated with its own edge's port, from the plumbing stack's external network."
  }

  assert {
    condition = (
      output.instances["1"].server_group_id == "edge-server-group-fixture" &&
      output.instances["2"].server_group_id == "edge-server-group-fixture" &&
      toset(output.server_group.policies) == toset(["soft-anti-affinity"])
    )
    error_message = "Both edges must be scheduled into one server group that keeps them on different hypervisors where the cloud can."
  }

  assert {
    condition     = output.instances["1"].boot_volume.image_id == "edge-image-fixture" && output.instances["1"].boot_volume.source_type == "image" && output.instances["1"].boot_volume.destination_type == "volume"
    error_message = "Each edge must boot from a volume made from the image EDGE_IMAGE names."
  }
}

run "an_edge_accepts_sessions_from_the_workers_addresses_in_the_clusters_as_and_from_nowhere_else" {
  command = plan

  assert {
    condition     = strcontains(output.config["1"].frr_conf, "\nrouter bgp 64497\n")
    error_message = "The edge must run in its own AS, the plumbing stack's edge_asn."
  }

  # The workers are at host numbers 20 to 99 of the node subnet, as the cluster stack numbers them,
  # for at most 80 of them: the fewest networks that hold exactly those addresses, in address order.
  assert {
    condition = regexall("(?m)^ bgp listen range .*$", output.config["1"].frr_conf) == tolist([
      " bgp listen range 192.0.2.20/30 peer-group workers",
      " bgp listen range 192.0.2.24/29 peer-group workers",
      " bgp listen range 192.0.2.32/27 peer-group workers",
      " bgp listen range 192.0.2.64/27 peer-group workers",
      " bgp listen range 192.0.2.96/30 peer-group workers",
    ])
    error_message = "The edge must listen for dynamic neighbours at the workers' addresses, host numbers 20 to 99 of the node subnet, and nowhere else."
  }

  # The firewall and the security group hold to the same block.
  assert {
    condition = (
      regexall("(?m)^.*tcp dport 179.*$", output.config["1"].nftables_conf) == tolist(["    ip saddr { 192.0.2.20/30, 192.0.2.24/29, 192.0.2.32/27, 192.0.2.64/27, 192.0.2.96/30 } tcp dport 179 accept"]) &&
      [for rule in output.security_group.rules : rule.remote_ip_prefix if rule.protocol == "tcp" && rule.port_range_min == 179] == ["192.0.2.20/30", "192.0.2.24/29", "192.0.2.32/27", "192.0.2.64/27", "192.0.2.96/30"]
    )
    error_message = "The firewall's BGP rule and the security group's BGP rules must admit the workers' block only."
  }

  assert {
    condition     = strcontains(output.config["1"].frr_conf, "\n neighbor workers remote-as 64496\n") && length(regexall("(?m)^ neighbor [^ ]+ remote-as ", output.config["1"].frr_conf)) == 1
    error_message = "The one peer group must have the cluster's AS as its remote AS, and no neighbour may be configured outside it."
  }

  assert {
    condition     = strcontains(output.config["1"].frr_conf, "\n bgp router-id 192.0.2.7\n") && strcontains(output.config["2"].frr_conf, "\n bgp router-id 192.0.2.8\n")
    error_message = "Each edge's router ID must be its own address."
  }

  # Exactly these neighbour and listen statements, and one router: a static neighbour, one added to
  # the peer group, another listen range or a second instance of BGP fails here. The timers are the
  # scenario on the workers' settings.
  assert {
    condition = length(regexall("(?m)^router bgp ", output.config["1"].frr_conf)) == 1 && [
      for line in regexall("(?m)^ (?:neighbor|bgp listen) .*$", output.config["1"].frr_conf) : line if !startswith(line, " neighbor workers timers ")
      ] == [
      " neighbor workers peer-group",
      " neighbor workers remote-as 64496",
      " bgp listen limit 80",
      " bgp listen range 192.0.2.20/30 peer-group workers",
      " bgp listen range 192.0.2.24/29 peer-group workers",
      " bgp listen range 192.0.2.32/27 peer-group workers",
      " bgp listen range 192.0.2.64/27 peer-group workers",
      " bgp listen range 192.0.2.96/30 peer-group workers",
    ]
    error_message = "The router must declare exactly the one peer group, its remote AS, the listen limit and the workers' listen ranges, and no other neighbour."
  }
}

run "an_edge_installs_a_32_inside_the_service_range_and_refuses_anything_else" {
  command = plan

  assert {
    condition     = strcontains(output.config["1"].frr_conf, "\nip prefix-list SERVICES seq 10 permit 203.0.113.16/28 ge 32 le 32\n") && strcontains(output.config["1"].frr_conf, "\nip prefix-list SERVICES seq 20 deny any\n")
    error_message = "The prefix list must permit only /32s inside the service range and deny everything else."
  }

  # Every prefix list entry and every entry of the inbound route map, exactly: an entry added before,
  # between or after them, such as a permit of any prefix or of the range's shorter prefixes, or a
  # route map entry with no match, fails here.
  assert {
    condition = regexall("(?m)^ip prefix-list .*$", output.config["1"].frr_conf) == tolist([
      "ip prefix-list SERVICES seq 10 permit 203.0.113.16/28 ge 32 le 32",
      "ip prefix-list SERVICES seq 20 deny any",
    ])
    error_message = "The prefix lists must be exactly the one that permits /32s inside the service range and denies everything else."
  }

  assert {
    condition = regexall("(?ms)^route-map SERVICES-IN .*?^exit$", output.config["1"].frr_conf) == tolist([join("\n", [
      "route-map SERVICES-IN permit 10",
      " match ip address prefix-list SERVICES",
      " set ip next-hop peer-address",
      "exit",
    ])])
    error_message = "The inbound route map must be one entry that permits what the prefix list matches, with the announcing worker as next hop, and nothing else."
  }

  assert {
    condition     = strcontains(output.config["1"].frr_conf, "\n  neighbor workers route-map SERVICES-IN in\n")
    error_message = "The inbound policy must be applied to the peer group."
  }

  # FRR counts the prefixes it accepts, and with this list at most as many as the range holds can be
  # accepted, so the limit is reached only if the list is loosened (FRR's BGP manual, neighbor
  # maximum-prefix): it guards against that, not against a peer that sends many prefixes the list
  # denies.
  assert {
    condition     = strcontains(output.config["1"].frr_conf, "\n  neighbor workers maximum-prefix 16\n") && !strcontains(output.config["1"].frr_conf, "maximum-prefix 16 ")
    error_message = "The maximum number of accepted prefixes must be the number of addresses in the service range, 16 for a /28."
  }
}

run "an_edge_advertises_nothing" {
  command = plan

  assert {
    condition     = strcontains(output.config["1"].frr_conf, "\n  neighbor workers route-map NOTHING-OUT out\n") && strcontains(output.config["1"].frr_conf, "\nroute-map NOTHING-OUT deny 10\n")
    error_message = "The outbound policy must be a route map that denies everything, applied to the peer group."
  }

  assert {
    condition     = !strcontains(output.config["1"].frr_conf, "route-map NOTHING-OUT permit") && !strcontains(output.config["1"].frr_conf, "network ") && !strcontains(output.config["1"].frr_conf, "redistribute")
    error_message = "Nothing may be permitted outbound, originated with a network statement or redistributed."
  }

  # Exactly this block, so a statement that bypasses the outbound route map, such as default-originate,
  # fails here wherever it is added to it.
  assert {
    condition = regex("(?s) address-family ipv4 unicast\\n.*? exit-address-family\\n", output.config["1"].frr_conf) == join("", [
      " address-family ipv4 unicast\n",
      "  maximum-paths 80\n",
      "  neighbor workers activate\n",
      "  neighbor workers maximum-prefix 16\n",
      "  neighbor workers route-map SERVICES-IN in\n",
      "  neighbor workers route-map NOTHING-OUT out\n",
      " exit-address-family\n",
    ])
    error_message = "The address family must hold exactly the activation, the paths, the prefix limit and the two route maps of the peer group, and nothing that originates or advertises a route."
  }

  assert {
    condition     = length(regexall("default-originate|aggregate-address|\\bnetwork\\b|redistribute|allowas-in|addpath", output.config["1"].frr_conf)) == 0
    error_message = "No statement that originates or advertises a route may be in the configuration."
  }
}

run "the_edges_timers_and_graceful_restart_agree_with_what_the_workers_are_configured_with" {
  command = plan

  # The workers' peer configuration, as the Kubernetes manifests hold it.
  assert {
    condition = strcontains(output.config["1"].frr_conf, format(
      "\n neighbor workers timers %d %d\n neighbor workers timers connect %d\n",
      yamldecode(file("../../../../../kubernetes/apps/base/kube-system/cilium-bgp/app/bgp-peer.yaml")).spec.timers.keepAliveTimeSeconds,
      yamldecode(file("../../../../../kubernetes/apps/base/kube-system/cilium-bgp/app/bgp-peer.yaml")).spec.timers.holdTimeSeconds,
      yamldecode(file("../../../../../kubernetes/apps/base/kube-system/cilium-bgp/app/bgp-peer.yaml")).spec.timers.connectRetryTimeSeconds,
    ))
    error_message = "The edge's keepalive, hold and connect retry times must be those of the workers' CiliumBGPPeerConfig."
  }

  # Without the notification bit, which FRR sets by default: a dead worker's paths go when its hold
  # timer expires, not a restart time later.
  assert {
    condition = yamldecode(file("../../../../../kubernetes/apps/base/kube-system/cilium-bgp/app/bgp-peer.yaml")).spec.gracefulRestart.enabled && strcontains(output.config["1"].frr_conf, format(
      "\n bgp graceful-restart\n bgp graceful-restart restart-time %d\n no bgp graceful-restart notification\n",
      yamldecode(file("../../../../../kubernetes/apps/base/kube-system/cilium-bgp/app/bgp-peer.yaml")).spec.gracefulRestart.restartTimeSeconds,
    )) && length(regexall("(?m)^ (?:no )?bgp graceful-restart", output.config["1"].frr_conf)) == 3
    error_message = "The edge must have graceful restart on with the restart time of the workers' CiliumBGPPeerConfig, without the notification bit, and no other graceful restart setting."
  }

  assert {
    condition     = strcontains(output.config["1"].frr_conf, "\n  maximum-paths 80\n") && strcontains(output.config["1"].frr_conf, "\n bgp listen limit 80\n")
    error_message = "The edge must take as many equal-cost paths, and as many dynamic neighbours, as there can be workers: 80 by default."
  }

  assert {
    condition     = strcontains(output.config["1"].sysctl, "net.ipv4.fib_multipath_hash_policy = 1\n")
    error_message = "The kernel must hash equal-cost paths on the flow's layer 4 fields, so a flow stays on one path."
  }
}

run "an_edge_forwards_nothing_at_the_packet_level_for_the_public_ports_and_refuses_a_port_that_is_not_listed" {
  command = plan

  # Rule text only: the comments say what the rules are for and may use the words the rules do not.
  # One table and three chains, and no translation of any kind: a connection to a public port ends
  # at the edge's own proxy, so no rule moves its destination or its source.
  assert {
    condition = (
      length(regexall("(?m)^table ", output.config["1"].nftables_conf)) == 1 &&
      length(regexall("(?m)^table inet edge \\{$", output.config["1"].nftables_conf)) == 1 &&
      length(regexall("(?m)^  chain ", output.config["1"].nftables_conf)) == 3
    )
    error_message = "The file must hold one table, inet edge, and three chains: input, forward and output."
  }

  assert {
    condition     = length(regexall("(?m)^[^#\\n]*\\b(?:dnat|snat|masquerade|redirect|tproxy|nat)\\b", output.config["1"].nftables_conf)) == 0 && !strcontains(output.config["1"].nftables_conf, "edge-nat")
    error_message = "No rule may translate an address or a port, and no translation table may be in the file."
  }

  # Every rule of every chain, exactly: a rule added to a chain, or a chain or table added to the
  # file, changes the text and fails here, so these are the only rules.
  assert {
    condition = regex("(?s)  chain input \\{\\n(.*?)  \\}\\n", output.config["1"].nftables_conf)[0] == join("", [
      "    type filter hook input priority filter; policy drop;\n",
      "    ct state established,related accept\n",
      "    ct state invalid drop\n",
      "    iif \"lo\" accept\n",
      "    tcp dport 22 accept\n",
      "    ip daddr 192.0.2.7 tcp dport { 80, 443 } accept\n",
      "    ip saddr { 192.0.2.20/30, 192.0.2.24/29, 192.0.2.32/27, 192.0.2.64/27, 192.0.2.96/30 } tcp dport 179 accept\n",
      "    icmp type destination-unreachable icmp code frag-needed accept\n",
      "    icmpv6 type { packet-too-big, nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } accept\n",
    ])
    error_message = "The input chain must drop by default and admit, besides what belongs to a connection and the loopback, SSH, the public ports, BGP from the workers' block and the ICMP that path MTU discovery needs, and nothing else: a port that is not listed, or a public port on another address, is dropped."
  }

  # Each edge takes the public ports on its own address: the second edge's chain is the first's,
  # with its own address in that rule.
  assert {
    condition = regex("(?s)  chain input \\{\\n(.*?)  \\}\\n", output.config["2"].nftables_conf)[0] == replace(
      regex("(?s)  chain input \\{\\n(.*?)  \\}\\n", output.config["1"].nftables_conf)[0],
      "    ip daddr 192.0.2.7 tcp dport { 80, 443 } accept\n",
      "    ip daddr 192.0.2.8 tcp dport { 80, 443 } accept\n",
    )
    error_message = "The second edge's input chain must be the first's, with the public ports admitted on its own address, 192.0.2.8."
  }

  assert {
    condition = regex("(?s)  chain forward \\{\\n(.*?)  \\}\\n", output.config["1"].nftables_conf)[0] == join("", [
      "    type filter hook forward priority filter; policy drop;\n",
    ])
    error_message = "The forward chain must drop by default and hold no rule: nothing is forwarded."
  }

  # The proxy's own connections to the Gateway's address are locally generated, so they leave
  # through the output chain, and only by a worker's route.
  assert {
    condition = regex("(?s)  chain output \\{\\n(.*?)  \\}\\n", output.config["2"].nftables_conf)[0] == join("", [
      "    type filter hook output priority filter; policy accept;\n",
      "    ip daddr 203.0.113.21 rt ip nexthop != { 192.0.2.20/30, 192.0.2.24/29, 192.0.2.32/27, 192.0.2.64/27, 192.0.2.96/30 } reject\n",
    ])
    error_message = "The output chain must refuse, at once, a packet toward the Gateway's address whose route does not go through a worker, and hold no other rule."
  }
}

# The proxy: what listens on the public ports, and where it sends what it accepts.
run "_the_proxy_listens_on_the_edges_own_address_and_the_public_ports_and_sends_the_header_to_the_gateway" {
  command = plan

  assert {
    condition = (
      tolist([for l in regexall("(?m)^[ \\t]*bind\\b[^\\n]*$", output.config["1"].haproxy_conf) : trimspace(l)]) == tolist(["bind 192.0.2.7:80", "bind 192.0.2.7:443"]) &&
      tolist([for l in regexall("(?m)^[ \\t]*bind\\b[^\\n]*$", output.config["2"].haproxy_conf) : trimspace(l)]) == tolist(["bind 192.0.2.8:80", "bind 192.0.2.8:443"])
    )
    error_message = "Each edge's proxy must listen on its own address and on each public port, and on no other address or port."
  }

  assert {
    condition = (
      tolist([for l in regexall("(?m)^[ \\t]*server\\b[^\\n]*$", output.config["1"].haproxy_conf) : trimspace(l)]) == tolist([
        "server gateway 203.0.113.21:80 send-proxy-v2 source 192.0.2.7",
        "server gateway 203.0.113.21:443 send-proxy-v2 source 192.0.2.7",
      ]) &&
      tolist([for l in regexall("(?m)^[ \\t]*server\\b[^\\n]*$", output.config["2"].haproxy_conf) : trimspace(l)]) == tolist([
        "server gateway 203.0.113.21:80 send-proxy-v2 source 192.0.2.8",
        "server gateway 203.0.113.21:443 send-proxy-v2 source 192.0.2.8",
      ])
    )
    error_message = "Each port's one backend must be the Gateway's address on the same port, sent the PROXY protocol version 2 header on every connection, from the edge's own address."
  }

  # TCP only, and unprivileged: no HTTP, no TLS, and none of the settings that need root or make the
  # process drop to a user, which the unit does.
  assert {
    condition = (
      length(regexall("(?m)^ *mode tcp$", output.config["1"].haproxy_conf)) == 1 &&
      length(regexall("(?m)^[^#\\n]*\\b(?:mode http|option http|ssl|crt|user|group|chroot|daemon|stats|master-worker)\\b", output.config["1"].haproxy_conf)) == 0
    )
    error_message = "The proxy must run in TCP mode and hold no HTTP, TLS, user, group, chroot, daemon or statistics setting."
  }

  # Limits: a connection that is not made or not used ends, and a connection that cannot be made
  # fails at once.
  assert {
    condition = alltrue([
      for setting in ["maxconn 4000", "retries 0", "timeout connect 5s", "timeout client 5m", "timeout server 5m", "timeout client-fin 30s", "timeout server-fin 30s"] :
      length(regexall("(?m)^ +${setting}$", output.config["1"].haproxy_conf)) == 1
    ])
    error_message = "The proxy must state its connection limit and its timeouts, and not try a failed connection again."
  }

  # Each of those settings once, wherever it is written, and no other timeout: a second one in a
  # frontend or a backend, or a tunnel timeout, which in TCP mode takes the place of the client and
  # server timeouts, would change the limits above.
  assert {
    condition = alltrue([
      for key in ["1", "2"] :
      [for line in regexall("(?m)^[ \\t]*(?:maxconn|retries|timeout)(?:[ \\t][^\\n]*)?$", output.config[key].haproxy_conf) : trimspace(line)] == [
        "maxconn 4000",
        "retries 0",
        "timeout connect 5s",
        "timeout client 5m",
        "timeout server 5m",
        "timeout client-fin 30s",
        "timeout server-fin 30s",
      ]
    ])
    error_message = "The connection limit, the retries and each timeout must be set once, and no other timeout."
  }

  # The unit runs the proxy as its own user, with only the capability to bind a low port.
  assert {
    condition = alltrue([
      for line in ["User=haproxy", "Group=haproxy", "AmbientCapabilities=CAP_NET_BIND_SERVICE", "CapabilityBoundingSet=CAP_NET_BIND_SERVICE", "NoNewPrivileges=true", "ProtectSystem=strict"] :
      contains(split("\n", output.config["1"].haproxy_unit), line)
    ]) && element([for l in split("\n", output.config["1"].haproxy_unit) : trimspace(l) if startswith(trimspace(l), "User=")], -1) == "User=haproxy"
    error_message = "The proxy's unit must run it as the unprivileged haproxy user, with the capability to bind low ports and no other, and no new privileges."
  }

  # systemd merges the capability lines of a unit and its drop-ins and takes the last of the others,
  # so each is written once, as given; and a command prefixed with + or ! runs with full privileges
  # or as root whatever User= says (systemd.service(5)).
  assert {
    condition = [
      for line in split("\n", output.config["1"].haproxy_unit) : replace(trimspace(line), "/[ \\t]*=[ \\t]*/", "=")
      if can(regex("^[ \\t]*(?:User|Group|AmbientCapabilities|CapabilityBoundingSet|NoNewPrivileges)[ \\t]*=", line))
      ] == [
      "User=haproxy",
      "Group=haproxy",
      "AmbientCapabilities=CAP_NET_BIND_SERVICE",
      "CapabilityBoundingSet=CAP_NET_BIND_SERVICE",
      "NoNewPrivileges=true",
    ] && length(regexall("(?m)^[ \\t]*Exec[A-Za-z]*[ \\t]*=[ \\t]*[-@:|]*[+!]", output.config["1"].haproxy_unit)) == 0
    error_message = "The proxy's unit must set its user, group, capabilities and no new privileges once each, to haproxy, haproxy, CAP_NET_BIND_SERVICE alone and true, and run no command with a + or ! prefix."
  }
}

# The Gateway's route is the one thing the edge needs to hold: no route is a refused connection and
# the reject route, which FRR installs, is the kernel's answer.
run "_the_edge_holds_a_reject_route_for_the_service_range_and_the_kernel_settings" {
  command = plan

  assert {
    condition = (
      strcontains(output.config["1"].frr_conf, "\nip route 203.0.113.16/28 reject\n") &&
      length(regexall("(?m)^ip route ", output.config["1"].frr_conf)) == 1
    )
    error_message = "The edge must hold a reject route for the whole service range."
  }

  assert {
    condition     = strcontains(output.config["1"].sysctl, "net.ipv4.ip_forward = 1\n") && strcontains(output.config["1"].sysctl, "net.ipv4.conf.all.send_redirects = 0\n")
    error_message = "The kernel settings must be forwarding on, which the forward chain leaves with nothing to forward, and ICMP redirects off."
  }

  # IPv6 forwarding stays as the kernel starts, off: nothing of IPv6 is forwarded.
  assert {
    condition     = length(regexall("(?m)^net\\.ipv6\\..*forwarding", output.config["1"].sysctl)) == 0
    error_message = "The kernel settings must not turn IPv6 forwarding on."
  }
}

run "the_public_ports_admit_only_the_operator_allowlist_by_default_and_ssh_admits_only_the_operator_allowlist" {
  command = plan

  assert {
    condition = (
      toset([for rule in output.security_group.rules : rule.remote_ip_prefix if rule.protocol == "tcp" && rule.port_range_min == 443]) == toset(["203.0.113.192/26", "198.51.100.0/24"]) &&
      toset([for rule in output.security_group.rules : rule.remote_ip_prefix if rule.protocol == "tcp" && rule.port_range_min == 80]) == toset(["203.0.113.192/26", "198.51.100.0/24"])
    )
    error_message = "With public_allowed_cidrs unset the public ports must admit the operator allowlist, each network once."
  }

  assert {
    condition     = toset([for rule in output.security_group.rules : rule.remote_ip_prefix if rule.protocol == "tcp" && rule.port_range_min == 22]) == toset(["203.0.113.192/26", "198.51.100.0/24"])
    error_message = "SSH must admit the operator allowlist, each network once."
  }

  # A rule without a remote prefix, protocol or ports admits every address, protocol or port as much
  # as one that names them all does, so each is compared as given, null included.
  assert {
    condition = [
      for rule in output.security_group.rules : jsonencode([rule.protocol, rule.port_range_min, rule.port_range_max])
      if rule.direction == "ingress" && contains(["0.0.0.0/0", "::/0", "none"], rule.remote_ip_prefix == null ? "none" : rule.remote_ip_prefix)
    ] == [jsonencode(["icmp", 3, 4])]
    error_message = "No inbound rule may admit every address by default but the one for the ICMP that path MTU discovery needs."
  }

  assert {
    condition     = toset([for rule in output.security_group.rules : "${rule.protocol}:${rule.port_range_min}-${rule.port_range_max}" if rule.direction == "ingress"]) == toset(["tcp:22-22", "tcp:80-80", "tcp:443-443", "tcp:179-179", "icmp:3-4"])
    error_message = "The group must admit TCP on 22, the public ports and 179, and ICMP fragmentation needed, and nothing else inbound."
  }

  assert {
    condition     = [for rule in output.security_group.rules : rule.remote_ip_prefix if rule.protocol == "tcp" && rule.port_range_min == 179] == ["192.0.2.20/30", "192.0.2.24/29", "192.0.2.32/27", "192.0.2.64/27", "192.0.2.96/30"]
    error_message = "BGP must be admitted from the workers' addresses only."
  }
}

run "the_public_ports_admit_the_source_networks_they_are_given_instead_of_the_allowlist" {
  command = plan

  variables {
    public_allowed_cidrs = ["192.0.2.128/25"]
  }

  assert {
    condition = (
      toset([for rule in output.security_group.rules : rule.remote_ip_prefix if rule.protocol == "tcp" && rule.port_range_min == 443]) == toset(["192.0.2.128/25"]) &&
      toset([for rule in output.security_group.rules : rule.remote_ip_prefix if rule.protocol == "tcp" && rule.port_range_min == 22]) == toset(["203.0.113.192/26", "198.51.100.0/24"])
    )
    error_message = "A set public_allowed_cidrs must replace the allowlist on the public ports and leave SSH on the allowlist."
  }
}

run "the_user_data_holds_no_secret_and_the_edges_port_allows_exactly_the_address_pairs_the_design_needs" {
  command = plan

  assert {
    condition = alltrue([
      for key in ["1", "2"] : (
        !strcontains(output.user_data[key], "AAAAC3NzaC1lZDI1NTE5AAAAIMarkerPublicKeyOfTheOperatorFixture") &&
        !strcontains(output.user_data[key], "marker-key-comment") &&
        !strcontains(output.user_data[key], "203.0.113.192") &&
        !strcontains(output.user_data[key], "198.51.100.0/24") &&
        !strcontains(replace(lower(output.user_data[key]), "passwordauthentication no", ""), "password") &&
        !strcontains(lower(output.user_data[key]), "secret")
      )
    ])
    error_message = "The user data must hold neither the SSH key, nor the operator allowlist, nor a password; the word is allowed only as the SSH daemon's setting that turns password login off."
  }

  # What cloud-init writes is what the stack renders: the cloud-config parses, and its files hold
  # the configuration as it was rendered.
  assert {
    condition = alltrue([
      for key in ["1", "2"] : {
        for file in yamldecode(output.user_data[key]).write_files : file.path => file.content
        } == {
        "/etc/edge/frr.conf"              = output.config[key].frr_conf
        "/etc/edge/nftables.conf"         = output.config[key].nftables_conf
        "/etc/edge/haproxy.cfg"           = output.config[key].haproxy_conf
        "/etc/edge/haproxy-unit.conf"     = output.config[key].haproxy_unit
        "/etc/edge/sysctl.conf"           = output.config[key].sysctl
        "/etc/edge/sshd.conf"             = output.config[key].sshd_conf
        "/etc/edge/daemons"               = file("frr-daemons")
        "/usr/local/sbin/edge-first-boot" = file("first-boot.sh")
      }
    ])
    error_message = "The cloud-config must write exactly the rendered FRR configuration, nftables rules, proxy configuration and unit settings and kernel settings, the SSH daemon's settings, the daemon list and the first-boot script."
  }

  # The SSH daemon's settings reach the edge as the tree states them, not as some other file.
  assert {
    condition = alltrue([
      for key in ["1", "2"] : alltrue([
        for line in [
          "KexAlgorithms mlkem768x25519-sha256,sntrup761x25519-sha512,curve25519-sha256",
          "Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com",
          "MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com",
          "PasswordAuthentication no",
          "KbdInteractiveAuthentication no",
          "PermitRootLogin no",
          "AuthenticationMethods publickey",
          "AllowTcpForwarding no",
          "AllowAgentForwarding no",
          "X11Forwarding no",
          "PermitTunnel no",
        ] : contains(split("\n", { for file in yamldecode(output.user_data[key]).write_files : file.path => file.content }["/etc/edge/sshd.conf"]), line)
      ])
    ])
    error_message = "The cloud-config must write the SSH daemon's settings: the post-quantum hybrid and classical key exchanges, AEAD ciphers and encrypt-then-MAC MACs, public key authentication only, and no forwarding."
  }

  # Written files configure nothing until the first-boot script runs them in place.
  assert {
    condition     = alltrue([for key in ["1", "2"] : yamldecode(output.user_data[key]).runcmd == [["/usr/local/sbin/edge-first-boot"]]])
    error_message = "The cloud-config must run the first-boot script, and nothing else."
  }

  assert {
    condition     = alltrue([for key in ["1", "2"] : output.instances[key].port.port_security_enabled && length(output.instances[key].port.allowed_address_pairs) == 0])
    error_message = "An edge's port keeps port security on and, as the edge sends only from its own address, needs no allowed address pair."
  }

  assert {
    condition     = output.instances["1"].key_pair == "lab-edge" && output.instances["1"].user_data == output.user_data["1"] && output.instances["2"].user_data == output.user_data["2"]
    error_message = "Each instance must boot with the key pair of the edges and the user data the stack outputs."
  }

  # scripts/lib/edge.sh names each edge's console, which its SSH host keys are checked against, by
  # this identifier.
  assert {
    condition     = output.instances["1"].id == "edge-1-instance-fixture" && output.instances["2"].id == "edge-2-instance-fixture"
    error_message = "The instances output must carry each edge's own instance id, by number."
  }
}

run "_the_first_boot_script_checks_the_release_before_it_installs_anything" {
  command = plan

  assert {
    condition     = strcontains(output.user_data["1"], "VERSION_CODENAME") && strcontains(output.user_data["1"], "trixie")
    error_message = "The first boot must check the release before it installs anything."
  }
}

# The operator allowlist is held to the rule the cluster and ci stacks hold it to: no network wider
# than /16, each written by its own address.
run "_an_ssh_allowlist_network_wider_than_16_is_rejected" {
  command = plan

  variables {
    ssh_allowed_cidrs = ["198.51.100.0/24", "255.254.0.0/15"]
  }

  expect_failures = [var.ssh_allowed_cidrs]
}

run "_an_ssh_allowlist_address_with_bits_set_below_its_prefix_is_rejected" {
  command = plan

  variables {
    ssh_allowed_cidrs = ["198.51.100.7/24"]
  }

  expect_failures = [var.ssh_allowed_cidrs]
}

# The workers' block is read from where the cluster stack starts numbering them and how many there
# can be, not from defaults written here.
run "_the_workers_block_follows_the_first_worker_host_and_the_most_workers" {
  command = plan

  variables {
    worker_first_host = 32
    max_workers       = 32
  }

  assert {
    condition     = regexall("(?m)^ bgp listen range .*$", output.config["1"].frr_conf) == tolist([" bgp listen range 192.0.2.32/27 peer-group workers"])
    error_message = "Workers at host numbers 32 to 63 must be the one network 192.0.2.32/27."
  }
}

# The workers' block holds neither an edge's address nor one of the DHCP pool, which Neutron hands to
# other ports.
run "_a_workers_block_that_reaches_the_dhcp_pool_is_rejected" {
  command = plan

  variables {
    max_workers = 81
  }

  expect_failures = [var.worker_first_host]
}

run "_a_workers_block_that_holds_an_edge_is_rejected" {
  command = plan

  variables {
    worker_first_host = 8
  }

  expect_failures = [var.worker_first_host]
}

# Host numbers below 20 hold the gateway, the load balancer, the CI host, the edges and the control
# planes, none of which may open a session.
run "_a_first_worker_host_below_20_is_rejected" {
  command = plan

  variables {
    worker_first_host = 19
  }

  expect_failures = [var.worker_first_host]
}

run "_a_public_port_that_is_not_a_port_is_rejected" {
  command = plan

  variables {
    public_ports = [80, 70000]
  }

  expect_failures = [var.public_ports]
}
