#!/bin/bash
# The first boot of an edge router: checks the release, turns unattended upgrades off, installs FRR,
# HAProxy and nftables from the distribution's repositories, checks the configuration cloud-init
# wrote under /etc/edge with each tool's own check before anything of it is installed under /etc,
# gives the SSH daemon its settings as the first of its drop-ins, validated before the daemon
# reloads, loads the firewall, starts FRR, starts the proxy once FRR answers and its reject route for
# the service range is in the kernel, and turns forwarding on last. It fails loudly, on the console
# and in the log, as the first boot is the only time anything configures an edge: an edge is
# rebuilt, not patched. A failed first boot leaves forwarding off, now and at the next boot, and FRR
# and the proxy stopped and disabled, so the edge serves nothing.
set -euo pipefail

# The release this configuration is written for. FRR's configuration, its daemon list, the proxy's
# configuration and unit, and the nftables syntax below are those of this release's packages.
release=trixie
# The edge's file system is under EDGE_ROOT, which is unset on an edge; the tests set it to a
# directory that stands for the edge's.
root=${EDGE_ROOT-}
log=$root/var/log/edge-first-boot.log
exec > >(tee -a "$log") 2>&1

# disarm: forwarding off, and its setting gone so the next boot leaves it off; FRR and the proxy
# stopped and kept from starting at the next boot, so no half-configured daemon runs beside the
# rules.
disarm() {
  rm -f "$root/etc/sysctl.d/90-edge.conf"
  sysctl -q -w net.ipv4.ip_forward=0 > /dev/null 2>&1 || true
  systemctl disable --now frr > /dev/null 2>&1 || true
  systemctl disable --now haproxy > /dev/null 2>&1 || true
}

# say MESSAGE: MESSAGE in the log and on the console, which a failure to write cannot stop.
say() {
  echo "edge-first-boot: $1" >&2
  echo "edge-first-boot: $1" 2> /dev/null > "$root/dev/console" || true
}

# fail MESSAGE: disarms the edge, then says MESSAGE, and stops.
fail() {
  disarm
  say "$1"
  exit 1
}
trap 'disarm; say "FAILED at line $LINENO; this edge is not configured, rebuild it"' ERR

# shellcheck disable=SC1091
. "$root/etc/os-release"
if [[ ${VERSION_CODENAME:-} != "$release" ]]; then
  say "this configuration is written for Debian $release and the image is ${PRETTY_NAME:-of an unknown release}; nothing was installed"
  exit 1
fi

# Debian's cloud images install unattended-upgrades, whose package turns it on by default: it would
# upgrade FRR and restart it in place, where an edge is rebuilt, not patched. Off before apt runs, so
# no upgrade starts beside this one; an upgrade already running holds apt's lock, which apt waits for.
printf '%s\n' 'APT::Periodic::Unattended-Upgrade "0";' > "$root/etc/apt/apt.conf.d/99edge-no-unattended-upgrades"
systemctl disable --now apt-daily-upgrade.timer

export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update -q
apt-get -o DPkg::Lock::Timeout=600 install -y -q --no-install-recommends frr haproxy nftables

# The packages start FRR and the proxy with their own defaults; each stays stopped until its
# configuration is in place.
systemctl stop frr
systemctl stop haproxy

# The files as cloud-init wrote them, before anything of them is installed under /etc. FRR skips a
# line it does not know and starts without it, so a file its own dry run refuses is not used.
nft --check --file "$root/etc/edge/nftables.conf"
if ! checked=$(vtysh -C -f "$root/etc/edge/frr.conf" 2>&1); then
  printf '%s\n' "$checked"
  fail "FRR's dry run refuses /etc/edge/frr.conf; nothing of it was installed, rebuild this edge with a configuration FRR accepts"
fi
if ! checked=$(haproxy -c -q -f "$root/etc/edge/haproxy.cfg" 2>&1); then
  printf '%s\n' "$checked"
  fail "the proxy refuses /etc/edge/haproxy.cfg; nothing of it was installed, rebuild this edge with a configuration it accepts"
fi

# The SSH daemon's settings: a drop-in that sorts first. The image's main configuration includes
# sshd_config.d ahead of its own lines, files in lexical order, and the daemon takes the first value
# it reads for a keyword (sshd_config(5)), so 00- wins over the image's settings outside a Match
# block; scripts/edge-check reads them as the edge's user's connection gets them. The daemon
# validates the whole configuration before it is told to read it: one that does not validate is
# taken out again, as the daemon would refuse to start on it at the next boot, and the first boot
# fails.
install -m 0644 "$root/etc/edge/sshd.conf" "$root/etc/ssh/sshd_config.d/00-edge.conf"
# sshd -t refuses to run without its privilege separation directory, which the service creates when
# it starts and a daemon that has not started yet has not.
mkdir -p "$root/run/sshd"
if ! checked=$(sshd -t -f "$root/etc/ssh/sshd_config" 2>&1); then
  printf '%s\n' "$checked"
  rm -f "$root/etc/ssh/sshd_config.d/00-edge.conf"
  fail "sshd refuses the settings in /etc/edge/sshd.conf; they were not kept, rebuild this edge with settings sshd accepts"
fi
# A daemon that is not running is left alone, and reads the settings when it starts.
systemctl try-reload-or-restart ssh

install -m 0640 -o frr -g frr "$root/etc/edge/frr.conf" "$root/etc/frr/frr.conf"
install -m 0640 -o frr -g frr "$root/etc/edge/daemons" "$root/etc/frr/daemons"
install -m 0644 "$root/etc/edge/nftables.conf" "$root/etc/nftables.conf"
install -m 0644 "$root/etc/edge/haproxy.cfg" "$root/etc/haproxy/haproxy.cfg"
# The proxy's unit settings, which run it as its own user instead of root; systemd reads them before
# the proxy starts.
mkdir -p "$root/etc/systemd/system/haproxy.service.d"
install -m 0644 "$root/etc/edge/haproxy-unit.conf" "$root/etc/systemd/system/haproxy.service.d/10-edge.conf"
systemctl daemon-reload
systemctl enable nftables
systemctl restart nftables
systemctl enable frr
systemctl restart frr

# The daemon answers, its reject route for the service range is in the kernel, and the rules are.
range=$(sed -n 's/^ip route \([^ ]*\) reject$/\1/p' "$root/etc/frr/frr.conf")
[[ -n $range ]] || fail "/etc/frr/frr.conf has no reject route for the service range"
tries=0
until vtysh -c 'show bgp summary' > /dev/null 2>&1 && [[ -n $(ip -4 route show exact "$range" type unreachable) ]]; do
  tries=$((tries + 1))
  if ((tries > 30)); then
    fail "FRR's BGP daemon does not answer, or its reject route for the service range is not in the kernel"
  fi
  sleep 2
done
nft list table inet edge > /dev/null

# The proxy once FRR answers: before there is a route to the Gateway's address it would accept
# connections it can only fail. Its unit is of the notify type, so the start returns once its
# sockets are bound.
systemctl enable haproxy
systemctl restart haproxy
systemctl is-active --quiet haproxy || fail "the proxy does not run"

# Forwarding last, with every guard in place.
install -m 0644 "$root/etc/edge/sysctl.conf" "$root/etc/sysctl.d/90-edge.conf"
sysctl --system > /dev/null
echo "edge-first-boot: done"
