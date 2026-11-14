#!/bin/bash
# The first boot of an edge router: checks the release, installs FRR and nftables from the
# distribution's repositories, puts the configuration cloud-init wrote under /etc/edge in place,
# checks each file with its tool's own check, and starts both. It fails loudly, on the console and
# in the log, as the first boot is the only time anything configures an edge: an edge is rebuilt,
# not patched.
set -euo pipefail

# The release this configuration is written for. FRR's configuration, its daemon list and the
# nftables syntax below are those of this release's packages.
release=trixie
# The edge's file system is under EDGE_ROOT, which is unset on an edge; the tests set it to a
# directory that stands for the edge's.
root=${EDGE_ROOT-}
log=$root/var/log/edge-first-boot.log
exec > >(tee -a "$log") 2>&1
trap 'echo "edge-first-boot: FAILED at line $LINENO; this edge is not configured, rebuild it" | tee "$root/dev/console" >&2' ERR

# shellcheck disable=SC1091
. "$root/etc/os-release"
if [[ ${VERSION_CODENAME:-} != "$release" ]]; then
  echo "edge-first-boot: this configuration is written for Debian $release and the image is ${PRETTY_NAME:-of an unknown release}; nothing was installed" | tee "$root/dev/console" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends frr nftables

install -m 0640 -o frr -g frr "$root/etc/edge/frr.conf" "$root/etc/frr/frr.conf"
install -m 0640 -o frr -g frr "$root/etc/edge/daemons" "$root/etc/frr/daemons"
install -m 0644 "$root/etc/edge/nftables.conf" "$root/etc/nftables.conf"
install -m 0644 "$root/etc/edge/sysctl.conf" "$root/etc/sysctl.d/90-edge.conf"
sysctl --system > /dev/null

# Load the firewall only once the kernel accepts it as it is written.
nft --check --file "$root/etc/nftables.conf"
systemctl enable nftables
systemctl restart nftables

# Start FRR only with a file FRR's own dry run accepts: FRR skips a line it does not know and starts
# without it, where this would leave an edge with less of its policy than it was given.
if ! checked=$(vtysh -C -f "$root/etc/frr/frr.conf" 2>&1); then
  printf '%s\n' "$checked"
  echo "edge-first-boot: FRR's dry run refuses /etc/frr/frr.conf; FRR was not started with it, rebuild this edge with a configuration FRR accepts" | tee "$root/dev/console" >&2
  exit 1
fi
systemctl enable frr
systemctl restart frr

# The daemon answers, and the rules are in the kernel.
tries=0
until vtysh -c 'show bgp summary' > /dev/null 2>&1; do
  tries=$((tries + 1))
  if ((tries > 30)); then
    echo "edge-first-boot: FRR's BGP daemon does not answer" | tee "$root/dev/console" >&2
    exit 1
  fi
  sleep 2
done
nft list table inet edge > /dev/null
nft list table ip edge-nat > /dev/null
echo "edge-first-boot: done"
