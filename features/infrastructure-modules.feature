Feature: OpenTofu modules
  Each module of infra/openstack/modules keeps its documented rules whatever stack calls it and
  whatever inputs it is given, proved by its own tofu test against a mocked provider.

  Rule: The infrastructure check

    Scenario: A module whose test fails fails the infrastructure check, naming it
      Given a module with a passing test and a module with a failing one
      When the infrastructure check runs
      Then it exits non-zero, names the module whose test failed and does not name the other

  Rule: The network module

    Scenario: The network module gives the DHCP pool the host range it is given
      Given a subnet range and the default host range, and then another one
      When the network module is planned against a mocked provider
      Then the allocation pool starts and ends at those host numbers of the range, and nothing outside it is in the pool

    Scenario: The network module gives the subnet no gateway unless asked for
      Given the network module with and without a gateway
      When it is planned against a mocked provider
      Then the subnet has a gateway only when asked, and the gateway output is null without one

    Scenario: The network module leaves port security off unless asked for
      Given the network module with and without port security
      When it is planned against a mocked provider
      Then the network has port security only when asked

    Scenario: The network module names and tags the network and its subnet alike
      Given a name, tags and DNS nameservers
      When the network module is planned against a mocked provider
      Then the network and the subnet carry that name and those tags, DHCP is on, and the subnet hands out exactly those nameservers

    Scenario: The network module refuses a name that is not lowercase letters, digits and hyphens
      Given names with capitals, an underscore, no characters or more than 63, and names of 1 and 63 valid characters
      When the network module is planned against a mocked provider
      Then the invalid names fail naming the name variable and the valid ones plan

    Scenario: The network module refuses a range that is not an IPv4 network with a zero host part
      Given ranges with host bits set, without a prefix, in IPv6 or not an address, and a valid IPv4 network
      When the network module is planned against a mocked provider
      Then the invalid ranges fail naming the cidr variable and the valid one plans

  Rule: The router module

    Scenario: The router module puts the gateway on the external network found by name
      Given an external network name
      When the router module is planned against a mocked provider
      Then the external network is looked up by that name among external networks only and is the router's gateway network

    Scenario: The router module attaches exactly the subnets it is given, keyed as given
      Given no subnets, and then two subnets by name
      When the router module is planned against a mocked provider
      Then the router has no interface without subnets, and otherwise one interface per subnet, keyed by its name, on that subnet

    Scenario: The router module tags the router
      Given tags
      When the router module is planned against a mocked provider
      Then the router carries them

    Scenario: The router module refuses a name that is not lowercase letters, digits and hyphens
      Given names with capitals, an underscore, no characters or more than 63, and names of 1 and 63 valid characters
      When the router module is planned against a mocked provider
      Then the invalid names fail naming the name variable and the valid ones plan

  Rule: The image module

    Scenario: The image module uploads a private bare image from the URL it is given
      Given a name and an https URL
      When the image module is planned against a mocked provider
      Then the image has that name and source, a bare container, and is visible to its project only

    Scenario: The image module decompresses the download only when asked and uploads the disk format given
      Given the defaults, and then decompression and another disk format
      When the image module is planned against a mocked provider
      Then the image is not decompressed and is raw by default, and is decompressed and of the other format when asked

    Scenario: The image module gives the image the properties and tags it is given
      Given properties and tags
      When the image module is planned against a mocked provider
      Then the image carries exactly those

    Scenario: The image module refuses a source URL that is not https
      Given URLs that are http, ftp, a path or empty, and an https URL
      When the image module is planned against a mocked provider
      Then the invalid ones fail naming the source_url variable and the https one plans

  Rule: The talos-image module

    Scenario: The talos-image module names the image after the Talos version and the start of the schematic ID
      Given a prefix, a Talos version and a schematic
      When the talos-image module is applied against mocked providers
      Then the image name is the prefix, the version and the first eight characters of the schematic ID, and another version gives another name

    Scenario: The talos-image module asks the Image Factory for the openstack amd64 image of the version and schematic
      Given a Talos version and a schematic
      When the talos-image module is applied against mocked providers
      Then the factory is given that schematic unchanged and asked for the openstack platform and the amd64 architecture of that version, and the outputs report them

    Scenario: The talos-image module uploads the factory's disk image decompressed, raw and private
      Given a Talos version and a schematic
      When the talos-image module is applied against mocked providers
      Then the image's source is the factory's disk image URL, decompressed, uploaded raw and visible to its project only

  Rule: The vm module

    Scenario: The vm module boots from a volume made from the image at the size given
      Given an image and a root volume size
      When the vm module is planned against a mocked provider
      Then the instance has one boot device, boot index 0, a volume of that size made from that image and deleted with the instance

    Scenario: The vm module puts the port on the fixed address with port security and the groups given
      Given a network, a subnet, a fixed address and security groups
      When the vm module is applied against a mocked provider
      Then the instance's one network is a port on that subnet at that address with port security on and exactly those groups

    Scenario: The vm module gives the port exactly the allowed address pairs it is given
      Given no allowed address pairs, two, and one listed twice
      When the vm module is planned against a mocked provider
      Then the port carries none, exactly those two, and the repeated one once

    Scenario: The vm module gives the instance no user data unless given some
      Given the vm module without and with user data
      When it is planned against a mocked provider
      Then the instance has no user data without, and exactly what it was given with

    Scenario: The vm module gives the instance the flavor and key pair it is given
      Given a flavor, and the module with and without a key pair
      When it is planned against a mocked provider
      Then the instance has that flavor and the key pair only when one was given

    Scenario: The vm module schedules into a server group only when given one
      Given the vm module without and with a server group
      When it is planned against a mocked provider
      Then the instance has no scheduler hint without, and the group as its hint with

    Scenario: The vm module makes one data volume and attachment per entry, named after the instance
      Given no data volumes, and two by name and size
      When the vm module is planned against a mocked provider
      Then there is no volume or attachment without, and otherwise one volume and one attachment per entry, named after the instance and the entry, of the size given, attached to the instance

    Scenario: The vm module gives every volume the volume type given
      Given the vm module with a volume type and with none
      When it is planned against a mocked provider
      Then the boot volume and every data volume have that type, and without one the boot volume names none

    Scenario: The vm module keeps a running instance when the image changes
      Given the vm module applied against a mocked provider
      When it is planned with another image
      Then the instance keeps its boot device

    Scenario: The vm module refuses a name that is not lowercase letters, digits and hyphens
      Given names with capitals, an underscore, no characters or more than 63, and names of 1 and 63 valid characters
      When the vm module is planned against a mocked provider
      Then the invalid names fail naming the name variable and the valid ones plan

  Rule: The talos-nodes module

    Scenario: The talos-nodes module names and addresses the nodes by role
      Given control plane and worker counts, a first worker host and a node subnet
      When the talos-nodes module is planned against a mocked provider
      Then the control planes are <name>-cp-<n> at hosts from 10, the workers <name>-w-<n> at hosts from the first worker host, each with the flavor of its role

    Scenario: The talos-nodes module admits the Talos and Kubernetes APIs once per allowlisted network
      Given an allowlist in no order with a network listed twice
      When the talos-nodes module is planned against a mocked provider
      Then there is one TCP rule for each of ports 50000 and 6443 for each network once, in sorted order, keyed by port and position and never by the network, and none for an empty allowlist

    Scenario: The talos-nodes module admits the APIs from each node's floating IP and the Kubernetes API from the node subnet
      Given the planned nodes
      When the talos-nodes module is planned against a mocked provider
      Then each node's floating IP may reach ports 50000 and 6443 and the node subnet may reach port 6443, and the module exports no rule that admits more

    Scenario: The talos-nodes module admits all traffic between the nodes over both IP versions
      Given the nodes' security group
      When the talos-nodes module is planned against a mocked provider
      Then the group admits all ingress from itself for IPv4 and for IPv6

    Scenario: The talos-nodes module gives the control planes a group of their own only with the reduced rules
      Given the full rules, and then the reduced rules
      When the talos-nodes module is planned against a mocked provider
      Then the control planes' group exists only with the reduced rules, and its output is null with the full ones

    Scenario: The talos-nodes module's reduced rules open every port but the Talos API and the NodePort range
      Given the reduced rules
      When the talos-nodes module is planned against a mocked provider
      Then the control planes' group admits from all every TCP and UDP port and ICMP, except TCP 50000 and TCP and UDP 30000 to 32767

    Scenario: The talos-nodes module switches between the rule sets without touching the nodes' group
      Given the full rules and the reduced rules
      When the talos-nodes module is planned against a mocked provider with each
      Then the nodes' group holds the same rules under both and only the control planes' group differs

    Scenario: The talos-nodes module gives each node the groups of its role
      Given the full rules, and the reduced rules
      When the talos-nodes module is planned against a mocked provider
      Then every node's port has the nodes' group, the workers' have the workers' group too, and with the reduced rules the control planes' have theirs

    Scenario: The talos-nodes module admits the worker ingress ports from the sources given and nothing else
      Given two ports and two sources, and none
      When the talos-nodes module is planned against a mocked provider
      Then the workers' group holds one TCP rule per port and source, keyed by port and position, and none by default

    Scenario: The talos-nodes module gives the ports the allowed address pairs of their role
      Given ranges for every node and others for the workers, and none
      When the talos-nodes module is planned against a mocked provider
      Then every port carries the first, the workers' ports the others too, no control plane's port the others, and none carries any by default

    Scenario: The talos-nodes module schedules every node into one soft anti-affinity server group
      Given the planned nodes
      When the talos-nodes module is planned against a mocked provider
      Then one server group has the soft-anti-affinity policy alone and every node is scheduled into it

    Scenario: The talos-nodes module boots every node from a volume of the size given and gives it no user data
      Given the image and the default root volume size, and then another size
      When the talos-nodes module is planned against a mocked provider
      Then every node boots from a volume of that size made from that image, and none has user data

    Scenario: The talos-nodes module gives each node a floating IP of its own, associated with its port
      Given the planned nodes and an external network
      When the talos-nodes module is applied against a mocked provider
      Then each node has one floating IP from that network, associated with that node's port

    Scenario: The talos-nodes module keeps Neutron's default egress rules in the nodes' group only
      Given the reduced rules
      When the talos-nodes module is planned against a mocked provider
      Then the nodes' group keeps them, and the control planes' and the workers' groups, which hold ingress rules only, do not

    Scenario: The talos-nodes module marks the outputs that hold the allowlist sensitive
      Given an allowlist and worker ingress sources
      When the talos-nodes module is planned against a mocked provider
      Then the nodes' and the workers' security group outputs are sensitive and the node, address and server group outputs are not

    Scenario: The talos-nodes module refuses a cluster name that is not lowercase letters, digits and hyphens, at most 24
      Given names with capitals, an underscore, no characters or 25, and names of 1 and 24 valid characters
      When the talos-nodes module is planned against a mocked provider
      Then the invalid names fail naming the name variable and the valid ones plan

    Scenario: The talos-nodes module refuses an unknown set of security group rules
      Given the rule sets full and reduced, and others
      When the talos-nodes module is planned against a mocked provider
      Then the others fail naming the security_group_rules variable and the two plan

    Scenario: The talos-nodes module refuses a first worker host below 20 or not whole
      Given first worker hosts 19, 20.5 and 0, and 20 and 40
      When the talos-nodes module is planned against a mocked provider
      Then the first three fail naming the worker_first_host variable and the others plan

    Scenario: The talos-nodes module refuses an allowlist entry that is not an IPv4 network
      Given allowlists with an address without a prefix, an IPv6 network and text, and one of IPv4 networks
      When the talos-nodes module is planned against a mocked provider
      Then the invalid ones fail naming the api_allowed_cidrs variable and the valid one plans

  Rule: The api-lb module

    Scenario: The api-lb module puts the API at a fixed address of the node subnet
      Given the node subnet and a host number
      When the api-lb module is planned against a mocked provider
      Then the load balancer's address is that host number of the subnet, on that subnet, and the endpoint is its HTTPS URL on port 6443

    Scenario: The api-lb module's listener admits the allowlist and the node subnet once each
      Given an allowlist in no order with a network twice and with the node subnet in it, and an empty one
      When the api-lb module is planned against a mocked provider
      Then the TCP listener on port 6443 admits the sorted networks and the node subnet, each once, only the node subnet for an empty allowlist, and the count output reports it

    Scenario: The api-lb module makes one pool member per control plane on the API port
      Given control plane addresses by name, and none
      When the api-lb module is planned against a mocked provider
      Then the pool has one member per entry, named by it, at its address on port 6443 on the node subnet, and none without entries

    Scenario: The api-lb module balances TCP round robin and checks members with the timings given
      Given the default timings, and then others
      When the api-lb module is planned against a mocked provider
      Then the pool is TCP and round robin and the TCP health monitor has the default timings, and then the others

    Scenario: The api-lb module gives the load balancer a floating IP from the external network on its VIP port
      Given an external network
      When the api-lb module is applied against a mocked provider
      Then one floating IP from that network is associated with the load balancer's VIP port

    Scenario: The api-lb module names every part after the cluster and tags them
      Given a name and tags
      When the api-lb module is planned against a mocked provider
      Then the load balancer, its listener, pool and monitor are <name>-api, and what takes tags carries them

    Scenario: The api-lb module passes the provider and flavor it is given to the load balancer
      Given an Octavia provider and flavor
      When the api-lb module is planned against a mocked provider
      Then the load balancer carries that provider and that flavor

    Scenario: The api-lb module marks the output that holds the allowlist sensitive
      Given an allowlist
      When the api-lb module is planned against a mocked provider
      Then the load balancer output is sensitive and the endpoint, address and count outputs are not

    Scenario: The api-lb module refuses a cluster name that is not lowercase letters, digits and hyphens, at most 24
      Given names with capitals, an underscore, no characters or 25, and names of 1 and 24 valid characters
      When the api-lb module is planned against a mocked provider
      Then the invalid names fail naming the name variable and the valid ones plan

    Scenario: The api-lb module refuses an allowlist entry that is not an IPv4 network
      Given allowlists with an address without a prefix, an IPv6 network and text, and one of IPv4 networks
      When the api-lb module is planned against a mocked provider
      Then the invalid ones fail naming the allowed_cidrs variable and the valid one plans
