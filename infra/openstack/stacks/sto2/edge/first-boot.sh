#!/bin/bash
# The first boot of an edge router: checks the release, installs FRR and nftables from the
# distribution's repositories, puts the configuration cloud-init wrote under /etc/edge in place, and
# starts both. It fails loudly, on the console and in the log, as the first boot is the only time
# anything configures an edge: an edge is rebuilt, not patched.
set -euo pipefail

# The release this configuration is written for. FRR's configuration, its daemon list and the
# nftables syntax below are those of this release's packages.
release=trixie
log=/var/log/edge-first-boot.log
exec > >(tee -a "$log") 2>&1
trap 'echo "edge-first-boot: FAILED at line $LINENO; this edge is not configured, rebuild it" | tee /dev/console >&2' ERR

# shellcheck disable=SC1091
. /etc/os-release
if [[ ${VERSION_CODENAME:-} != "$release" ]]; then
  echo "edge-first-boot: this configuration is written for Debian $release and the image is ${PRETTY_NAME:-of an unknown release}; nothing was installed" | tee /dev/console >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends frr nftables

install -m 0640 -o frr -g frr /etc/edge/frr.conf /etc/frr/frr.conf
install -m 0640 -o frr -g frr /etc/edge/daemons /etc/frr/daemons
install -m 0644 /etc/edge/nftables.conf /etc/nftables.conf
install -m 0644 /etc/edge/sysctl.conf /etc/sysctl.d/90-edge.conf
sysctl --system > /dev/null

# Load the firewall only once the kernel accepts it as it is written.
nft --check --file /etc/nftables.conf
systemctl enable nftables
systemctl restart nftables
systemctl enable frr
systemctl restart frr

# The daemon answers, and the rules are in the kernel.
tries=0
until vtysh -c 'show bgp summary' > /dev/null 2>&1; do
  tries=$((tries + 1))
  if ((tries > 30)); then
    echo "edge-first-boot: FRR's BGP daemon does not answer" | tee /dev/console >&2
    exit 1
  fi
  sleep 2
done
nft list table inet edge > /dev/null
nft list table ip edge-nat > /dev/null
echo "edge-first-boot: done"
