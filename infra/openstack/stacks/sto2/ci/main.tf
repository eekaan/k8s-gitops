# The CI host: a Linux VM on the plumbing stack's node network, outside the cluster, reachable over
# SSH from the operator allowlist only, with a cache volume of its own for the Dagger engine.
# scripts/ci-host-setup turns it into the repository's GitHub Actions runner. The stack reads the
# plumbing stack's state and nothing of the cluster stack's, so destroying the cluster leaves it.

# The cloud and its credentials come from the environment: OS_CLOUD names the clouds.yaml entry.
provider "openstack" {}

data "terraform_remote_state" "plumbing" {
  backend = "s3"
  config  = var.plumbing_state
}

data "openstack_images_image_v2" "host" {
  name        = var.image_name
  most_recent = true
}

locals {
  plumbing = data.terraform_remote_state.plumbing.outputs
  name     = "${var.prefix}-ci"
  tags     = [var.prefix]

  # Where the engine keeps its state: scripts/ci-host-setup mounts it into the engine's container.
  cache_mountpoint = "/var/lib/dagger"

  # Sorted, so the same networks given in another order change no rule, and without duplicates, as
  # Neutron refuses a rule that already exists.
  ssh_sources = sort(distinct(var.ssh_allowed_cidrs))

  # The first boot installs the container runtime, creates the runner's user and mounts the cache
  # volume, and does nothing more; scripts/ci-host-setup does the rest over SSH. User data is kept
  # in tofu state and served to the instance by the metadata service, so it holds nothing but these
  # names. The runner's user has no password, no sudo and no groups: membership of the docker group
  # is root on the host. The cache volume is attached once the instance exists, so the first boot
  # waits for it, and finds it under /dev/disk/by-id by its serial, the first 20 characters of its
  # volume ID, whatever bus the cloud attaches it on. A volume that already holds a file system keeps
  # it: the cache outlives a replaced instance.
  user_data = templatefile("${path.module}/user-data.yaml.tftpl", {
    runner_user      = var.runner_user
    cache_serial     = substr(openstack_blockstorage_volume_v3.cache.id, 0, 20)
    cache_mountpoint = local.cache_mountpoint
  })
}

# SSH from the allowlist and nothing else inbound. The cloud's own default rules are deleted, so
# the group holds exactly the rules below whatever a cloud adds to new groups.
resource "openstack_networking_secgroup_v2" "host" {
  name                 = local.name
  description          = "CI host of ${var.prefix}: SSH from the operator allowlist only; all egress."
  delete_default_rules = true
  tags                 = local.tags
}

# Keyed by position in the allowlist, never by the network: resource addresses are printed in plans
# and logs, and the allowlist must not be. Only its length shows.
resource "openstack_networking_secgroup_rule_v2" "ssh" {
  for_each = { for i in range(nonsensitive(length(local.ssh_sources))) : tostring(i) => i }

  security_group_id = openstack_networking_secgroup_v2.host.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = local.ssh_sources[each.value]
}

# The host reaches the nodes' Talos and Kubernetes APIs, which the cluster stack opens to it given
# its host number, and fetches packages, images and the runner's jobs from the internet.
resource "openstack_networking_secgroup_rule_v2" "egress" {
  for_each = { IPv4 = "0.0.0.0/0", IPv6 = "::/0" }

  security_group_id = openstack_networking_secgroup_v2.host.id
  direction         = "egress"
  ethertype         = each.key
  remote_ip_prefix  = each.value
}

resource "openstack_compute_keypair_v2" "host" {
  name       = local.name
  public_key = var.ssh_public_key
}

resource "openstack_blockstorage_volume_v3" "cache" {
  name        = "${local.name}-cache"
  size        = var.cache_volume_size
  volume_type = var.volume_type
  # The volume stays attached for the host's life, so it grows while attached.
  enable_online_resize = true
}

module "host" {
  source = "../../../modules/vm"

  name                = local.name
  flavor              = var.flavor
  image_id            = data.openstack_images_image_v2.host.id
  root_volume_size_gb = var.root_volume_size_gb
  volume_type         = var.volume_type
  network_id          = local.plumbing.network.network_id
  # The node subnet as the router reports it attached: a floating IP can only be associated with a
  # port on a subnet that a router joins to the external network.
  subnet_id          = local.plumbing.router.attached_subnet_ids.nodes
  fixed_ip           = cidrhost(local.plumbing.network.cidr, var.host_number)
  security_group_ids = [openstack_networking_secgroup_v2.host.id]
  user_data          = local.user_data
  key_pair           = openstack_compute_keypair_v2.host.name
  tags               = local.tags
}

# An attachment of its own, not a block device of the instance: the provider replaces a server
# whose block devices change.
resource "openstack_compute_volume_attach_v2" "cache" {
  instance_id = module.host.id
  volume_id   = openstack_blockstorage_volume_v3.cache.id
}

resource "openstack_networking_floatingip_v2" "host" {
  pool = local.plumbing.router.external_network
  tags = local.tags
}

resource "openstack_networking_floatingip_associate_v2" "host" {
  floating_ip = openstack_networking_floatingip_v2.host.address
  port_id     = module.host.port.id
}
