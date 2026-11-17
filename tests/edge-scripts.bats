#!/usr/bin/env bats
# Proves the scenarios of features/edge-routers.feature about the edge scripts: edge-check and
# edge-rollout, with the tests of the scripts around them. The scripts run in a copy against
# recording fakes of tofu, ssh and the edge's own commands, so nothing here reaches a cloud or a
# host, no test reads this checkout's .env, and the edges' key is a file in the test's own directory.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$BATS_TEST_TMPDIR/bin"
  HOST_BIN="$BATS_TEST_TMPDIR/host-bin"
  HOST_SBIN="$BATS_TEST_TMPDIR/host-sbin"
  RECORD="$BATS_TEST_TMPDIR/record"
  HOME_DIR="$BATS_TEST_TMPDIR/home"
  HOST="$BATS_TEST_TMPDIR/host"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$BIN" "$HOST_BIN" "$HOST_SBIN" "$RECORD" "$HOME_DIR/.local/state/k8s-gitops" "$HOST" \
    "$REPO/infra/openstack/stacks/sto2/edge" "$REPO/talos/lab-sto2" "$BATS_TEST_TMPDIR/keys"
  : > "$RECORD/argv"
  # What Debian puts in /usr/bin and the check uses for itself.
  ln -s "$(type -P mktemp)" "$HOST_BIN/mktemp"
  ln -s "$(type -P rm)" "$HOST_BIN/rm"
  cp -R "$ROOT/scripts" "$REPO/scripts"
  cp "$ROOT/infra/openstack/backend.hcl" "$REPO/infra/openstack/backend.hcl"
  cp "$ROOT"/infra/openstack/stacks/sto2/edge/*.tf "$ROOT/infra/openstack/stacks/sto2/edge/sshd.conf" "$REPO/infra/openstack/stacks/sto2/edge/"
  ADDRESS_1=203.0.113.51
  ADDRESS_2=203.0.113.52
  INSTANCE_1=3f6a0c1e-0b5a-4c3e-9d7a-1a2b3c4d5e61
  INSTANCE_2=8e1d2c3b-4a59-4687-b0c1-d2e3f4a5b672
  # What a test hands a recipe its typed answers through, once answers_pipe has made it a named pipe
  # or answers_file a file.
  ANSWERS="$BATS_TEST_TMPDIR/answers"
  KEY="$BATS_TEST_TMPDIR/keys/edge"
  echo 'fixture private key, never read' > "$KEY"
  echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureEdgePublicKeyFixtureFixtureFix fixture' > "$KEY.pub"
  # The cluster: three workers with their own addresses on the node subnet, the second of them away
  # from host number 21, where a worker numbered after the first would be: the check reads each
  # worker's address from talman.yaml rather than working it out from its name.
  cat > "$REPO/talos/lab-sto2/talman.yaml" << YAML
values:
  nodeSubnet: 192.0.2.0/24
  serviceRange: 203.0.113.16/28
  bgp: {gatewayAddress: 203.0.113.21}
nodes:
  - {hostname: lab-cp-1, role: controlplane, ipAddress: 203.0.113.61, values: {privateAddress: 192.0.2.10}}
  - {hostname: lab-w-1, role: worker, ipAddress: 203.0.113.71, values: {privateAddress: 192.0.2.20}}
  - {hostname: lab-w-2, role: worker, ipAddress: 203.0.113.72, values: {privateAddress: 192.0.2.30}}
  - {hostname: lab-w-3, role: worker, ipAddress: 203.0.113.73, values: {privateAddress: 192.0.2.22}}
YAML
  cat > "$BATS_TEST_TMPDIR/outputs.json" << JSON
{"addresses": {"sensitive": true, "value": ["$ADDRESS_1", "$ADDRESS_2"]},
 "names": {"sensitive": false, "value": ["lab-edge-1", "lab-edge-2"]}}
JSON
  # Each edge offers a host key of its own, kept in a file of the fake host, and both are recorded
  # already. A replacement of an edge offers another key at the same address.
  for address in "$ADDRESS_1" "$ADDRESS_2"; do
    echo "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${address//./}Original" > "$HOST/key-$address"
    echo "$address ssh-ed25519 $(cat "$HOST/key-$address")" >> "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  done

  # A mise with nothing installed keeps the justfile from putting real tools in front of the fakes.
  fake mise < /dev/null
  for tool in jq yq grep flock cat sed; do
    record "$tool"
  done
  # The plan a run saves is plan.json, the change the configuration makes, with the instance of each
  # edge given with -replace replaced as well, and, when the run targets one edge, that edge's part
  # of it only. Once applied, the address of each edge whose instance the saved plan creates, alone
  # or as a replacement, offers a new host key, and, when the outputs name the edges' instances, the
  # created one is a new server: the outputs give it an identifier of its own, the next of
  # instance_id's for that edge or what the file next-id-NUMBER in the fake host's directory names,
  # and the server it replaced is deleted, so the client finds no console for its identifier.
  fake tofu << EOF
printf '%s\n' "tofu \$*" >> "$RECORD/argv"
case \${2-} in
  output) cat "$BATS_TEST_TMPDIR/outputs.json" ;;
  show) cat "$RECORD/plan.saved" ;;
  plan)
    targeted=0 forced=()
    for argument; do
      if [[ \$argument =~ ^-target=module\.edge\[\"([12])\"\]\$ ]]; then
        targeted=\${BASH_REMATCH[1]}
      elif [[ \$argument =~ ^-replace=module\.edge\[\"([12])\"\]\.openstack_compute_instance_v2\.this\$ ]]; then
        forced+=("\${BASH_REMATCH[1]}")
      fi
    done
    { [[ -f "$BATS_TEST_TMPDIR/plan.json" ]] && cat "$BATS_TEST_TMPDIR/plan.json" || echo '{}'; } |
      jq --arg targeted "\$targeted" --args '.resource_changes = ([.resource_changes[]?] + [\$ARGS.positional[]
        | {address: "module.edge[\\"\\(.)\\"].openstack_compute_instance_v2.this", mode: "managed",
           type: "openstack_compute_instance_v2", change: {actions: ["delete", "create"]}}]
        | unique_by(.address)
        | map(select(\$targeted == "0" or (.address | startswith("module.edge[\\"" + \$targeted + "\\"]")))))' \
        "\${forced[@]}" > "$RECORD/plan.saved"
    ;;
  apply)
    for number in \$(jq -r '.resource_changes[] | select(.type == "openstack_compute_instance_v2" and (.change.actions | index("create")))
        | .address | capture("^module\\\\.edge\\\\[\"(?<n>[12])\"\\\\]").n' "$RECORD/plan.saved"); do
      case \$number in
        1)
          echo "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_1//./}Replacement" > "$HOST/key-$ADDRESS_1"
          base=${INSTANCE_1:0:32}
          ;;
        2)
          echo "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_2//./}Replacement" > "$HOST/key-$ADDRESS_2"
          base=${INSTANCE_2:0:32}
          ;;
      esac
      jq -e '.instances' "$BATS_TEST_TMPDIR/outputs.json" > /dev/null || continue
      replaced=\$(jq -r --arg number "\$number" '.instances.value[\$number].id' "$BATS_TEST_TMPDIR/outputs.json")
      generation=\$((\$(cat "$RECORD/generation-\$number" 2> /dev/null || echo 0) + 1))
      echo "\$generation" > "$RECORD/generation-\$number"
      created=\$(cat "$HOST/next-id-\$number" 2> /dev/null || printf '%s%04x' "\$base" "\$generation")
      : > "$HOST/gone-\$replaced"
      jq --arg number "\$number" --arg id "\$created" '.instances.value[\$number].id = \$id' \
        "$BATS_TEST_TMPDIR/outputs.json" > "$BATS_TEST_TMPDIR/outputs.applied"
      mv "$BATS_TEST_TMPDIR/outputs.applied" "$BATS_TEST_TMPDIR/outputs.json"
    done
    ;;
esac
EOF
  # The three calls the scripts make: a lookup (-F), dropping an address (-R) and the fingerprints
  # (-l) of the keys on standard input, on the unhashed known_hosts file the fake ssh-keyscan feeds.
  fake ssh-keygen << EOF
printf '%s\n' "ssh-keygen \$*" >> "$RECORD/argv"
case \$1 in
  -F) grep -q "^\$2 " "\$4" 2> /dev/null ;;
  -R) grep -v "^\$2 " "\$4" > "\$4.new" || true; mv "\$4.new" "\$4" ;;
  -l) while read -r address type key; do echo "256 SHA256:\$(printf %s "\$key" | sha256sum | cut -c1-43) \$address (ED25519)"; done ;;
  *) exit 1 ;;
esac
EOF
  # An ssh that refuses unless host key checking is strict against the recorded keys and the edges'
  # key is the one named, and otherwise runs the command here, as the edge's login shell would, with
  # only what the ordinary user's PATH reaches on a Debian edge: its commands in /usr/bin, and none of
  # /usr/sbin's, which sudo's secure_path reaches (the fake sudo). The client sends its own standard
  # input to the command it runs, whether that reads it or not (ssh(1), -n), so the answers, when
  # the fake has them as its standard input, are read to their end.
  fake ssh << EOF
printf '%s\n' "ssh \$*" >> "$RECORD/argv"
if [[ /dev/stdin -ef "$ANSWERS" ]]; then
  while IFS= read -r _; do :; done
fi
strict= known= identity= only=
while ((\$#)); do
  case \$1 in
    -i) identity=\$2; shift 2 ;;
    -o)
      case \$2 in
        StrictHostKeyChecking=*) strict=\${2#*=} ;;
        UserKnownHostsFile=*) known=\${2#*=} ;;
        IdentitiesOnly=*) only=\${2#*=} ;;
      esac
      shift 2
      ;;
    *) break ;;
  esac
done
[[ \$strict == yes && \$only == yes && \$identity == "$KEY" && -s \$known ]] || { echo "fake ssh: refused" >&2; exit 255; }
# The user the edges' image logs in as, debian, unless a test names the one it configures in the
# file ssh-user.
user=debian
[[ ! -f "$HOST/ssh-user" ]] || user=\$(cat "$HOST/ssh-user")
case \$1 in
  "\$user@$ADDRESS_1") edge=1 address=$ADDRESS_1 ;;
  "\$user@$ADDRESS_2") edge=2 address=$ADDRESS_2 ;;
  *) echo "fake ssh: unexpected destination" >&2; exit 255 ;;
esac
# What strict host key checking does: the recorded key must be the one the host offers.
grep -qx "\$address ssh-ed25519 \$(cat "$HOST/key-\$address")" "\$known" || { echo "fake ssh: REMOTE HOST IDENTIFICATION HAS CHANGED" >&2; exit 255; }
shift
exec env -i EDGE_FIXTURE="$HOST/edge-\$edge" EDGE_SBIN="$HOST_SBIN" PATH="$HOST_BIN" "$(type -P bash)" -c "\$*"
EOF
  # Nothing else may reach a host, a cloud or a container runtime from this machine.
  for tool in scp sftp curl docker; do
    fake "$tool" << EOF
printf '%s\n' "$tool \$*" >> "$RECORD/argv"
echo "unexpected call: $tool \$*" >&2
exit 1
EOF
  done
  # The OpenStack client: its version, 7.1.0 or what the file openstack-version in the fake host's
  # directory says, and an instance's console log, from the file console-ID there, or, for its Nth
  # read, console-ID.N when there is one; an instance without a file, or deleted (gone-ID), is not
  # found, as the client says it.
  fake openstack << EOF
printf '%s\n' "openstack \$*" >> "$RECORD/argv"
if [[ \$* == --version ]]; then cat "$HOST/openstack-version" 2> /dev/null || echo "openstack 7.1.0"; exit 0; fi
if [[ "\$1 \$2 \$3 \$4" == 'console log show --lines' && \$# -eq 6 ]]; then
  id=\$6 reads=\$(( \$(cat "$RECORD/reads-\$id" 2> /dev/null || echo 0) + 1 ))
  echo "\$reads" > "$RECORD/reads-\$id"
  if [[ ! -e "$HOST/gone-\$id" ]]; then
    for file in "$HOST/console-\$id.\$reads" "$HOST/console-\$id"; do
      [[ -f \$file ]] && exec cat "\$file"
    done
  fi
  echo "No server with a name or ID of '\$id' exists." >&2
  exit 1
fi
echo "unexpected call: openstack \$*" >&2
exit 1
EOF
  # The host keys an address offers, as ssh-keyscan prints them; nothing from an address with none,
  # nor for as many scans as the file silent-ADDRESS says, as from a host still booting. Files
  # key-ADDRESS.before and key-ADDRESS.rsa add a key offered before the first and one after it, and
  # key-ADDRESS.rescan is what a second scan of the address answers instead.
  fake ssh-keyscan << EOF
printf '%s\n' "ssh-keyscan \$*" >> "$RECORD/argv"
address=\${*: -1}
[[ -f "$HOST/key-\$address" ]] || exit 1
scans=\$(( \$(cat "$RECORD/scans-\$address" 2> /dev/null || echo 0) + 1 ))
echo "\$scans" > "$RECORD/scans-\$address"
((scans > \$(cat "$HOST/silent-\$address" 2> /dev/null || echo 0))) || exit 1
if ((scans > 1)) && [[ -f "$HOST/key-\$address.rescan" ]]; then
  echo "\$address ssh-ed25519 \$(cat "$HOST/key-\$address.rescan")"
  exit 0
fi
[[ ! -f "$HOST/key-\$address.before" ]] || echo "\$address ssh-rsa \$(cat "$HOST/key-\$address.before")"
echo "\$address ssh-ed25519 \$(cat "$HOST/key-\$address")"
[[ ! -f "$HOST/key-\$address.rsa" ]] || echo "\$address ssh-rsa \$(cat "$HOST/key-\$address.rsa")"
EOF
  # What an edge answers: FRR's state and tables, the loaded rules, the kernel's setting and the SSH
  # daemon's. The commands in /usr/bin on Debian are on the ordinary user's PATH; those in /usr/sbin
  # (nft, sysctl, sshd) only through sudo, whose secure_path holds the sbin directories. A file
  # broken-SECTION in an edge's fixture directory makes the command that reads SECTION fail with
  # what the file says.
  # Like the real one, it tells what it runs that it runs under sudo (SUDO_USER), logs what it was
  # asked, and on a healthy edge warns on standard error while it succeeds, as sudo does when it
  # cannot resolve the host's name.
  host_fake sudo << 'EOF'
[[ $1 == -n ]] && shift
echo "$*" >> "$EDGE_FIXTURE/sudo-log"
compgen -G "$EDGE_FIXTURE/broken-*" > /dev/null || echo "sudo: unable to resolve host lab-edge: Name or service not known" >&2
export SUDO_USER=debian PATH="$EDGE_SBIN:$PATH"
exec "$@"
EOF
  host_fake cat << EOF
if [[ \$* == /proc/sys/net/ipv4/ip_forward ]]; then
  if [[ -n \${SUDO_USER:-} ]]; then : > "\$EDGE_FIXTURE/forwarding-read-under-sudo"; else : > "\$EDGE_FIXTURE/forwarding-read-as-user"; fi
  if [[ -f "\$EDGE_FIXTURE/broken-forwarding" ]]; then
    "$(type -P cat)" "\$EDGE_FIXTURE/broken-forwarding" >&2
    exit 1
  fi
  exec "$(type -P cat)" "\$EDGE_FIXTURE/forwarding"
fi
if [[ \$* == /etc/haproxy/haproxy.cfg ]]; then
  if [[ -f "\$EDGE_FIXTURE/broken-proxy-config" ]]; then
    "$(type -P cat)" "\$EDGE_FIXTURE/broken-proxy-config" >&2
    exit 1
  fi
  exec "$(type -P cat)" "\$EDGE_FIXTURE/proxy-config"
fi
exec "$(type -P cat)" "\$@"
EOF
  host_fake ps << 'EOF'
[[ $* == '-C haproxy -o user=' ]] || { echo "fake ps: unexpected $*" >&2; exit 1; }
if [[ -f $EDGE_FIXTURE/broken-proxy-users ]]; then
  cat "$EDGE_FIXTURE/broken-proxy-users" >&2
  exit 2
fi
# ps exits 1 when no process matches.
[[ -s $EDGE_FIXTURE/proxy-users ]] || exit 1
cat "$EDGE_FIXTURE/proxy-users"
EOF
  host_fake ss << 'EOF'
[[ $* == '-H -ltnp' ]] || { echo "fake ss: unexpected $*" >&2; exit 1; }
if [[ -f $EDGE_FIXTURE/broken-listening ]]; then
  cat "$EDGE_FIXTURE/broken-listening" >&2
  exit 1
fi
cat "$EDGE_FIXTURE/listening"
EOF
  host_fake systemctl << 'EOF'
case $* in
  'is-active frr') unit=frr ;;
  'is-active haproxy') unit=proxy ;;
  *) echo "fake systemctl: unexpected $*" >&2; exit 1 ;;
esac
if [[ -f $EDGE_FIXTURE/broken-$unit ]]; then
  cat "$EDGE_FIXTURE/broken-$unit" >&2
  exit 4
fi
state=$(cat "$EDGE_FIXTURE/$unit")
echo "$state"
[[ $state == active ]] || exit 3
EOF
  host_fake vtysh << 'EOF'
case $2 in
  'show bgp ipv4 unicast summary json') section=sessions file=sessions.json ;;
  'show bgp ipv4 unicast json') section=table file=table.json ;;
  'show running-config') section=config file=config ;;
  *) echo "fake vtysh: unexpected $*" >&2; exit 1 ;;
esac
if [[ -f $EDGE_FIXTURE/broken-$section ]]; then
  cat "$EDGE_FIXTURE/broken-$section" >&2
  exit 1
fi
cat "$EDGE_FIXTURE/$file"
EOF
  # The loaded ruleset is the fixture's file rules, as nft lists it as JSON (ruleset); the tables'
  # names, which nft list tables prints, are those of that listing.
  host_sbin_fake nft << EOF
case \$* in
  '-j list ruleset' | 'list tables') section=rules ;;
  'list chain inet edge forward') section=forward ;;
  'list chain inet edge output') section=output ;;
  *) echo "fake nft: unexpected \$*" >&2; exit 1 ;;
esac
if [[ -f \$EDGE_FIXTURE/broken-\$section ]]; then
  cat "\$EDGE_FIXTURE/broken-\$section" >&2
  exit 1
fi
if [[ \$* == 'list tables' ]]; then
  exec "$(type -P jq)" -r '.nftables[] | .table? | objects | "table \(.family) \(.name)"' "\$EDGE_FIXTURE/rules"
fi
cat "\$EDGE_FIXTURE/\$section"
EOF
  host_sbin_fake sysctl << 'EOF'
cat "$EDGE_FIXTURE/forwarding"
EOF
  # sshd -T prints the settings in the fixture's file sshd, and, for a connection -C names the user
  # of, those of a Match for that user, the file sshd-match-user-NAME, in their place. A fixture
  # with an sshd_config of its own is read by this machine's OpenSSH server instead, as the edge's
  # would.
  host_sbin_fake sshd << EOF
[[ \${1-} == -T ]] || { echo "fake sshd: unexpected \$*" >&2; exit 1; }
shift
if [[ -f \$EDGE_FIXTURE/broken-sshd ]]; then
  cat "\$EDGE_FIXTURE/broken-sshd" >&2
  exit 1
fi
if [[ -f \$EDGE_FIXTURE/sshd_config ]]; then
  exec "$(type -P sshd)" -T -f "\$EDGE_FIXTURE/sshd_config" -h "\$EDGE_FIXTURE/ssh-host-key" "\$@"
fi
user=
while ((\$#)); do
  case \$1 in
    -C)
      [[ ,\${2-}, =~ ,user=([^,]+), ]] && user=\${BASH_REMATCH[1]}
      shift 2
      ;;
    *) echo "fake sshd: unexpected \$1" >&2; exit 1 ;;
  esac
done
declare -A matched=()
if [[ -n \$user && -f \$EDGE_FIXTURE/sshd-match-user-\$user ]]; then
  while read -r keyword value; do
    [[ -n \$keyword ]] && matched[\$keyword]="\$keyword \$value"
  done < "\$EDGE_FIXTURE/sshd-match-user-\$user"
fi
while read -r keyword value; do
  [[ -n \$keyword ]] && echo "\${matched[\$keyword]:-\$keyword \$value}"
done < "\$EDGE_FIXTURE/sshd"
EOF
  host_fake ip << 'EOF'
case $* in
  '-4 -o route show type unreachable') section=unreachable ;;
  '-4 -o route show default') section=default ;;
  *) echo "fake ip: unexpected $*" >&2; exit 1 ;;
esac
if [[ -f $EDGE_FIXTURE/broken-$section ]]; then
  cat "$EDGE_FIXTURE/broken-$section" >&2
  exit 1
fi
cat "$EDGE_FIXTURE/$section"
EOF
  host_fake apt-config << 'EOF'
[[ $* == 'dump APT::Periodic::Unattended-Upgrade' ]] || { echo "fake apt-config: unexpected $*" >&2; exit 1; }
if [[ -f $EDGE_FIXTURE/broken-upgrades ]]; then
  cat "$EDGE_FIXTURE/broken-upgrades" >&2
  exit 1
fi
cat "$EDGE_FIXTURE/upgrades"
EOF

  ENVIRONMENT=(
    PATH="$BIN:$PATH"
    HOME="$HOME_DIR"
    XDG_STATE_HOME=
    TF_STATE_BUCKET=fixture-state-bucket
    AWS_ACCESS_KEY_ID=marker-access-key-id
    AWS_SECRET_ACCESS_KEY=marker-secret-access-key
    TF_STATE_PASSPHRASE=marker-state-passphrase
    OS_AUTH_URL=https://identity.example.invalid/v3
    'OPERATOR_CIDRS=["198.51.100.0/24"]'
    EDGE_IMAGE=fixture-image
    EDGE_SSH_KEY_FILE="$KEY"
    EDGE_ROLLOUT_WAIT=0
    EDGE_ROLLOUT_INTERVAL=0
    HOST_CONSOLE_WAIT=0
  )
  WORKERS='192.0.2.20 192.0.2.30 192.0.2.22'
}

# fake NAME: a binary first on the scripts' PATH, its body read from stdin. Before anything else it
# notes its name in the record's file had-answers when its own standard input is the answers, the
# pipe or the file a test made of ANSWERS; that note reads nothing of them, and of the bodies only
# the fake ssh's does.
fake() {
  {
    echo '#!/usr/bin/env bash'
    printf '[[ ! /dev/stdin -ef %q ]] || echo %q >> %q\n' "$ANSWERS" "$1" "$RECORD/had-answers"
    cat
  } > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# host_fake NAME: a binary on the fake edge's ordinary user's PATH, its body read from stdin. The
# shebang names bash by path, as that PATH holds nothing to find it by.
host_fake() {
  { echo "#!$(type -P bash)"; cat; } > "$HOST_BIN/$1"
  chmod +x "$HOST_BIN/$1"
}

# host_sbin_fake NAME: a binary the fake edge's ordinary user cannot run by name, only through sudo.
host_sbin_fake() {
  { echo "#!$(type -P bash)"; cat; } > "$HOST_SBIN/$1"
  chmod +x "$HOST_SBIN/$1"
}

# record NAME: puts NAME's arguments in the record, then runs the real NAME.
record() {
  local real
  real=$(command -v "$1")
  fake "$1" << EOF
printf '%s\n' "$1 \$*" >> "$RECORD/argv"
exec "$real" "\$@"
EOF
}

# ruleset [OBJECTS...]: a loaded ruleset as nft -j list ruleset prints it: on one line, the object
# nftables, whose list starts with nft's own metainfo and holds each object of OBJECTS, one a line: a
# table, a chain or a rule (libnftables-json(5)). Each object below is as nft 1.1.7 lists it for a
# ruleset loaded in a network namespace, and those of own_table are the whole listing of the rules
# the stack renders; the handles of the others, and where an object added to a table stands among
# that table's, are the fixtures' own, which the check does not read. What it reads, a table's
# family and name, a chain's type and the statements of a rule, Debian 13's nft, 1.1.3, lists alike.
ruleset() {
  local object objects=''
  while IFS= read -r object; do
    [[ -z $object ]] || objects+=", $object"
  done < <(printf '%s\n' "$@")
  printf '{"nftables": [{"metainfo": {"version": "1.1.7", "release_name": "Commodore Bullmoose #8", "json_schema_version": 1}}%s]}\n' "$objects"
}

# own_table: the edge's own table as listed once the rules the stack renders are loaded, for an
# edge at host number 7, the workers' block for host numbers 20 to 99 and the public ports 80 and
# 443: three base chains that filter, and no rule in the forward chain.
own_table() {
  cat << 'JSON'
{"table": {"family": "inet", "name": "edge", "handle": 1}}
{"chain": {"family": "inet", "table": "edge", "name": "input", "handle": 1, "type": "filter", "hook": "input", "prio": 0, "policy": "drop"}}
{"chain": {"family": "inet", "table": "edge", "name": "forward", "handle": 2, "type": "filter", "hook": "forward", "prio": 0, "policy": "drop"}}
{"chain": {"family": "inet", "table": "edge", "name": "output", "handle": 3, "type": "filter", "hook": "output", "prio": 0, "policy": "accept"}}
{"rule": {"family": "inet", "table": "edge", "chain": "input", "handle": 4, "expr": [{"match": {"op": "in", "left": {"ct": {"key": "state"}}, "right": ["established", "related"]}}, {"accept": null}]}}
{"rule": {"family": "inet", "table": "edge", "chain": "input", "handle": 5, "expr": [{"match": {"op": "in", "left": {"ct": {"key": "state"}}, "right": "invalid"}}, {"drop": null}]}}
{"rule": {"family": "inet", "table": "edge", "chain": "input", "handle": 6, "expr": [{"match": {"op": "==", "left": {"meta": {"key": "iif"}}, "right": "lo"}}, {"accept": null}]}}
{"rule": {"family": "inet", "table": "edge", "chain": "input", "handle": 7, "expr": [{"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": 22}}, {"accept": null}]}}
{"rule": {"family": "inet", "table": "edge", "chain": "input", "handle": 9, "expr": [{"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "daddr"}}, "right": "192.0.2.7"}}, {"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": {"set": [80, 443]}}}, {"accept": null}]}}
{"rule": {"family": "inet", "table": "edge", "chain": "input", "handle": 11, "expr": [{"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "saddr"}}, "right": {"set": [{"range": ["192.0.2.20", "192.0.2.99"]}]}}}, {"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": 179}}, {"accept": null}]}}
{"rule": {"family": "inet", "table": "edge", "chain": "input", "handle": 12, "expr": [{"match": {"op": "==", "left": {"payload": {"protocol": "icmp", "field": "type"}}, "right": "destination-unreachable"}}, {"match": {"op": "==", "left": {"payload": {"protocol": "icmp", "field": "code"}}, "right": 4}}, {"accept": null}]}}
{"rule": {"family": "inet", "table": "edge", "chain": "input", "handle": 14, "expr": [{"match": {"op": "==", "left": {"payload": {"protocol": "icmpv6", "field": "type"}}, "right": {"set": ["packet-too-big", "nd-router-advert", "nd-neighbor-solicit", "nd-neighbor-advert"]}}}, {"accept": null}]}}
{"rule": {"family": "inet", "table": "edge", "chain": "output", "handle": 16, "expr": [{"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "daddr"}}, "right": "203.0.113.21"}}, {"match": {"op": "!=", "left": {"rt": {"key": "nexthop", "family": "ip"}}, "right": {"set": [{"range": ["192.0.2.20", "192.0.2.99"]}]}}}, {"reject": {"type": "icmp", "expr": "port-unreachable"}}]}}
JSON
}

# translation_table: the table an edge that translates has loaded beside its own, edge-nat: a chain
# hooked at nat before routing that moves a public port's destination to the Gateway, and one after
# it that sets the source of what was moved.
translation_table() {
  cat << 'JSON'
{"table": {"family": "ip", "name": "edge-nat", "handle": 2}}
{"chain": {"family": "ip", "table": "edge-nat", "name": "prerouting", "handle": 1, "type": "nat", "hook": "prerouting", "prio": -100, "policy": "accept"}}
{"chain": {"family": "ip", "table": "edge-nat", "name": "postrouting", "handle": 2, "type": "nat", "hook": "postrouting", "prio": 100, "policy": "accept"}}
{"rule": {"family": "ip", "table": "edge-nat", "chain": "prerouting", "handle": 4, "expr": [{"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "daddr"}}, "right": "192.0.2.7"}}, {"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": {"set": [80, 443]}}}, {"dnat": {"addr": "203.0.113.21"}}]}}
{"rule": {"family": "ip", "table": "edge-nat", "chain": "postrouting", "handle": 6, "expr": [{"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "daddr"}}, "right": "203.0.113.21"}}, {"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": {"set": [80, 443]}}}, {"match": {"op": "in", "left": {"ct": {"key": "status"}}, "right": "dnat"}}, {"snat": {"addr": "192.0.2.7"}}]}}
JSON
}

# nat_chain [HOOK]: a table of another name whose one chain is hooked at nat, before routing or at
# HOOK, output or postrouting, and holds no rule.
nat_chain() {
  local hook=${1:-prerouting} prio=-100
  [[ $hook != postrouting ]] || prio=100
  printf '{"table": {"family": "ip", "name": "other", "handle": 3}}\n'
  printf '{"chain": {"family": "ip", "table": "other", "name": "%s", "handle": 1, "type": "nat", "hook": "%s", "prio": %s, "policy": "accept"}}\n' "$hook" "$hook" "$prio"
}

# prerouting_filter: a table of another name whose base chain filters before routing, at the hook a
# nat chain that moves a destination takes, and its one rule.
prerouting_filter() {
  cat << 'JSON'
{"table": {"family": "inet", "name": "raw", "handle": 15}}
{"chain": {"family": "inet", "table": "raw", "name": "prerouting", "handle": 1, "type": "filter", "hook": "prerouting", "prio": -300, "policy": "accept"}}
{"rule": {"family": "inet", "table": "raw", "chain": "prerouting", "handle": 2, "expr": [{"match": {"op": "in", "left": {"ct": {"key": "state"}}, "right": "invalid"}}, {"drop": null}]}}
JSON
}

# iptables_nat_table: the nat table iptables-nft 1.8 makes for a rule in each of two of its chains,
# -j MASQUERADE and -j DNAT: the chains hooked at nat, and each rule's target as nft lists one of
# iptables' own targets, an xt statement named after it.
iptables_nat_table() {
  cat << 'JSON'
{"table": {"family": "ip", "name": "nat", "handle": 12}}
{"chain": {"family": "ip", "table": "nat", "name": "POSTROUTING", "handle": 1, "type": "nat", "hook": "postrouting", "prio": 100, "policy": "accept"}}
{"chain": {"family": "ip", "table": "nat", "name": "PREROUTING", "handle": 3, "type": "nat", "hook": "prerouting", "prio": -100, "policy": "accept"}}
{"rule": {"family": "ip", "table": "nat", "chain": "POSTROUTING", "handle": 2, "expr": [{"match": {"op": "==", "left": {"meta": {"key": "oifname"}}, "right": "ens3"}}, {"counter": {"packets": 0, "bytes": 0}}, {"xt": {"type": "target", "name": "MASQUERADE"}}]}}
{"rule": {"family": "ip", "table": "nat", "chain": "PREROUTING", "handle": 4, "expr": [{"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": 80}}, {"counter": {"packets": 0, "bytes": 0}}, {"xt": {"type": "target", "name": "DNAT"}}]}}
JSON
}

# filter_table: a second table that only filters: a base chain of the type filter, and its rules.
filter_table() {
  cat << 'JSON'
{"table": {"family": "inet", "name": "filter", "handle": 14}}
{"chain": {"family": "inet", "table": "filter", "name": "input", "handle": 1, "type": "filter", "hook": "input", "prio": 0, "policy": "accept"}}
{"rule": {"family": "inet", "table": "filter", "chain": "input", "handle": 2, "expr": [{"match": {"op": "in", "left": {"ct": {"key": "state"}}, "right": ["established", "related"]}}, {"accept": null}]}}
{"rule": {"family": "inet", "table": "filter", "chain": "input", "handle": 3, "expr": [{"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "saddr"}}, "right": {"prefix": {"addr": "198.51.100.0", "len": 24}}}}, {"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": 22}}, {"accept": null}]}}
JSON
}

# named_not_stated: two rules of the edge's own input chain that name a translation and state none:
# one that matches a connection whose destination was translated (ct status dnat), and one whose
# comment is the word masquerade.
named_not_stated() {
  cat << 'JSON'
{"rule": {"family": "inet", "table": "edge", "chain": "input", "handle": 17, "expr": [{"match": {"op": "in", "left": {"ct": {"key": "status"}}, "right": "dnat"}}, {"accept": null}]}}
{"rule": {"family": "inet", "table": "edge", "chain": "input", "handle": 18, "comment": "masquerade", "expr": [{"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": 22}}, {"accept": null}]}}
JSON
}

# unhooked STATEMENT [inet]: a chain that is hooked nowhere, so it carries no type, and its one
# rule, which holds STATEMENT, dnat, snat, masquerade or redirect, as nft lists the statement: in a
# table of a name of its own, aside, which comes with them, or with inet in the edge's own table.
unhooked() {
  local family=ip table=aside stated
  if [[ ${2-} == inet ]]; then
    family=inet table=edge
  else
    printf '{"table": {"family": "ip", "name": "aside", "handle": 5}}\n'
  fi
  case $1:$family in
    dnat:ip) stated='{"dnat": {"addr": "203.0.113.21"}}' ;;
    dnat:inet) stated='{"dnat": {"family": "ip", "addr": "203.0.113.21"}}' ;;
    snat:ip) stated='{"snat": {"addr": "192.0.2.7"}}' ;;
    snat:inet) stated='{"snat": {"family": "ip", "addr": "192.0.2.7"}}' ;;
    masquerade:*) stated='{"masquerade": null}' ;;
    redirect:*) stated='{"redirect": {"port": 8080}}' ;;
  esac
  printf '{"chain": {"family": "%s", "table": "%s", "name": "helper", "handle": 20}}\n' "$family" "$table"
  printf '{"rule": {"family": "%s", "table": "%s", "chain": "helper", "handle": 21, "expr": [{"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": 80}}, %s]}}\n' "$family" "$table" "$stated"
}

# inline_chain: a table of a name of its own whose chain, hooked nowhere, holds one rule, which jumps
# to an inline chain that holds a masquerade statement. nft has no JSON for an inline chain and
# lists it as its text, in a string, where a statement's object would stand.
inline_chain() {
  cat << 'JSON'
{"table": {"family": "ip", "name": "aside", "handle": 2}}
{"chain": {"family": "ip", "table": "aside", "name": "plain", "handle": 1}}
{"rule": {"family": "ip", "table": "aside", "chain": "plain", "handle": 4, "expr": [{"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": 80}}, "jump {\n\t\t\tmasquerade\n\t\t}"]}}
JSON
}

# edge_state NUMBER FRR_STATE SESSIONS PREFIXES [FORWARDING]: what edge NUMBER answers. SESSIONS is
# the addresses of the established sessions and PREFIXES the routes in the table, each with a path
# per session.
edge_state() {
  local dir="$HOST/edge-$1"
  mkdir -p "$dir"
  echo "$2" > "$dir/frr"
  jq -n --arg addresses "$3" '{peers: ($addresses | split(" ") | map(select(. != ""))
    | map({key: ., value: {state: "Established"}}) | from_entries)}' > "$dir/sessions.json"
  jq -n --arg prefixes "$4" --arg addresses "$3" '{routes: ($prefixes | split(" ") | map(select(. != ""))
    | map({key: ., value: ($addresses | split(" ") | map(select(. != "")) | map({valid: true, bestpath: true, multipath: true}))})
    | from_entries)}' > "$dir/table.json"
  ruleset "$(own_table)" > "$dir/rules"
  echo "${5:-1}" > "$dir/forwarding"
  # FRR's configuration with its reject route for the service range, the kernel's route from it, the
  # forward chain that holds no rule, the output chain that refuses the proxy's packets toward the
  # Gateway unless they go through a worker, the proxy running as its own user with its listeners
  # on the edge's own address, and no unattended upgrades.
  printf 'router bgp 64497\nexit\nip route 203.0.113.16/28 reject\n' > "$dir/config"
  echo 'unreachable 203.0.113.16/28 proto static metric 20' > "$dir/unreachable"
  forward_chain > "$dir/forward"
  output_chain '192.0.2.20-192.0.2.99' > "$dir/output"
  echo active > "$dir/proxy"
  printf 'haproxy\nhaproxy\n' > "$dir/proxy-users"
  proxy_config > "$dir/proxy-config"
  proxy_listeners > "$dir/listening"
  echo 'default via 192.0.2.1 dev ens3 proto dhcp src 192.0.2.7 metric 100' > "$dir/default"
  echo 'APT::Periodic::Unattended-Upgrade "0";' > "$dir/upgrades"
  # What sshd -T prints: the settings the tree writes, as the daemon names them, among others of its
  # own.
  {
    echo 'port 22'
    awk '!/^[[:space:]]*(#|$)/ { keyword = tolower($1); $1 = ""; sub(/^ /, ""); print keyword, $0 }' \
      "$ROOT/infra/openstack/stacks/sto2/edge/sshd.conf"
    echo 'permitemptypasswords no'
  } > "$dir/sshd"
}

# forward_chain [RULE]: the forward chain as nft lists it once loaded: policy drop and, as it is
# written, no rule, or RULE.
forward_chain() {
  printf 'table inet edge {\n\tchain forward {\n\t\ttype filter hook forward priority filter; policy %s;\n' "${FORWARD_POLICY:-drop}"
  [[ -z ${1-} ]] || printf '\t\t%s\n' "$1"
  printf '\t}\n}\n'
}

# output_chain SET [GATEWAY]: the output chain as nft lists it once loaded: the rule that refuses a
# packet toward the Gateway whose route does not go through a worker, with SET the workers' block as
# nft writes it, or no rule for SET none.
output_chain() {
  printf 'table inet edge {\n\tchain output {\n\t\ttype filter hook output priority filter; policy accept;\n'
  [[ $1 == none ]] || printf '\t\tip daddr %s rt ip nexthop != { %s } reject with icmp port-unreachable\n' "${2:-203.0.113.21}" "$1"
  printf '\t}\n}\n'
}

# proxy_config [GATEWAY [OWN [SERVER_OPTIONS]]]: the proxy's configuration as the edge holds it: a
# listener on each public port at the edge's own address, and for each the Gateway's address with the
# PROXY protocol header.
proxy_config() {
  local gateway=${1:-203.0.113.21} own=${2:-192.0.2.7} options port
  options=${3-send-proxy-v2 source $own}
  printf 'global\n    maxconn 4000\n\ndefaults\n    mode tcp\n'
  for port in 80 443; do
    printf '\nfrontend public-%s\n    bind %s:%s\n    default_backend gateway-%s\n' "$port" "$own" "$port" "$port"
    printf '\nbackend gateway-%s\n    server gateway %s:%s %s\n' "$port" "$gateway" "$port" "$options"
  done
}

# proxy_listeners [OWN [PROCESS]]: the edge's listening sockets as ss lists them: SSH's and BGP's,
# and the proxy's on its own address.
proxy_listeners() {
  local own=${1:-192.0.2.7} process=${2:-haproxy}
  printf 'LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=401,fd=3))\n'
  printf 'LISTEN 0 4096 0.0.0.0:179 0.0.0.0:* users:(("bgpd",pid=502,fd=22))\n'
  printf 'LISTEN 0 4096 %s:80 0.0.0.0:* users:(("%s",pid=611,fd=5))\n' "$own" "$process"
  printf 'LISTEN 0 4096 %s:443 0.0.0.0:* users:(("%s",pid=611,fd=6))\n' "$own" "$process"
}

# edge_check [ARG...]: scripts/edge-check in the copy, in the environment above.
edge_check() {
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/edge-check" "$@"
}

# absent GREP_ARG...: fails when grep -q finds a match; the last command of a function, as bats
# ignores a failing ! anywhere else.
absent() {
  ! grep -q "$@"
}

# no_address OUTPUT: fails when OUTPUT holds an IPv4 address.
no_address() {
  ! grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' <<< "$1"
}

# check_ruleset OBJECTS...: the check of edge 1, healthy but for the ruleset it has loaded: OBJECTS.
check_ruleset() {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  ruleset "$@" > "$HOST/edge-1/rules"
  edge_check --edge 1
  echo "$output"
}

# translates OBJECTS KINDS: the check of edge 1 with OBJECTS loaded beside its own table fails on
# one line of its own, which names KINDS and nothing else of the ruleset; its own table is there, so
# the lines that read its chains and the kernel's forwarding say what they say of a loaded table.
translates() {
  check_ruleset "$(own_table)" "$1"
  [ "$status" -ne 0 ]
  [[ $output$'\n' == *"FAIL  lab-edge-1: the ruleset on the edge holds what translates an address: $2"$'\n'* ]]
  [ "$(grep -c FAIL <<< "$output")" -eq 1 ]
  [[ $output != *"none translates an address"* ]]
  [[ $output == *"pass  lab-edge-1: the forward chain forwards nothing"* ]]
  [[ $output == *"pass  lab-edge-1: the output chain keeps the proxy's connections to the Gateway on a worker's route"* ]]
  [[ $output == *"pass  lab-edge-1: the kernel forwards"* ]]
  no_address "$output"
}

# other_edge_down_answered: the rollout other_edge_down sets up, which just ran with the four
# answers as its standard input, read each at its prompt, in the order they are asked: the stack's
# name; the yes the check of edge 2 asks before it connects to it, as its key is not recorded; the
# sentence, as edge 2 does not pass; and the yes for the key of the instance edge 1 becomes. Edge 1
# is replaced, by the instance whose console was read, and passes its check. Both edges were
# connected to, no answer is left for the end of the input to follow, and no fake or recorded program
# the rollout or its checks started had the answers as its standard input. The checks have them, as
# the rollout hands them to ask with, and real_edge_check's wrapper notes nothing; the dirname each
# script runs before it keeps its input has them as well, and other_edge_down does not record it.
other_edge_down_answered() {
  [ "$status" -eq 0 ]
  [[ $output == *"Type sto2/edge to roll out it: "* ]]
  [[ $output == *"The console of the edge router lab-edge-2's instance held no fingerprints, so the comparison is yours."* ]]
  [ "$(recorded 2)" = "$(cat "$HOST/key-$ADDRESS_2")" ]
  [[ $output == *"FAIL  lab-edge-2: FRR is not running"* ]]
  [[ $output == *'Type "replace edge 1 with edge 2 down" to replace it anyway: '* ]]
  [[ $output == *"The console of the edge router lab-edge-1's instance held no fingerprints, so the comparison is yours."* ]]
  [ "$(grep -o 'Type yes to record them and connect: ' <<< "$output" | wc -l)" -eq 2 ]
  [ "$(recorded 1)" = "$(replacement_key 1)" ]
  [ "$(current_instance 1)" = "$new" ]
  [ "$(sequence)" = "$(printf '%s\n' \
    'plan' \
    'check 2' 'scan 2' \
    'plan -target=module.edge["1"] -target=openstack_networking_floatingip_associate_v2.edge["1"] -replace=module.edge["1"].openstack_compute_instance_v2.this' \
    'forget 1' 'apply' 'scan 1' 'check 1' \
    'plan')" ]
  [[ $output == *"pass  lab-edge-1: 3 of 3 worker sessions are established"* ]]
  [[ $output == *"sto2/edge: edge 1 replaced, and edge 1 passes; what is left of the plan:"* ]]
  grep -q "^ssh .*@$ADDRESS_2 " "$RECORD/argv"
  grep -q "^ssh .*@$ADDRESS_1 " "$RECORD/argv"
  [ -z "$(answers_left)" ]
  [ ! -s "$RECORD/had-answers" ]
  no_address "$output"
}

@test "edge-check passes with every worker's session established and fails, saying which, when one is missing or a route outside the range is present, and no address is printed" {
  # Both edges complete: three sessions each, and a next hop per session for every Service address.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" "203.0.113.17/32 203.0.113.18/32"
  edge_check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output != *FAIL* ]]
  [[ $output == *"lab-edge-1: 3 of 3 worker sessions are established"* ]]
  [[ $output == *"lab-edge-2: 3 of 3 worker sessions are established"* ]]
  no_address "$output"

  # One worker's session is missing on the second edge: it fails, and says which worker.
  edge_state 2 active "192.0.2.20 192.0.2.22" 203.0.113.17/32
  edge_check
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"pass  lab-edge-1: 3 of 3 worker sessions are established"* ]]
  [[ $output == *"FAIL  lab-edge-2: 2 of 3 worker sessions are established; no session from lab-w-2"* ]]
  no_address "$output"

  # A route outside the range, and a prefix shorter than a /32 inside it, are in the first edge's table.
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  edge_state 1 active "$WORKERS" "203.0.113.17/32 198.51.100.5/32 203.0.113.16/30"
  edge_check
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: 2 of 3 routes in the table are not a /32 inside the service range"* ]]
  [[ $output == *"pass  lab-edge-2: the table holds 1 routes, each a /32 inside the service range"* ]]
  no_address "$output"

  # FRR down, the rules not loaded and forwarding off each fail on their own.
  edge_state 1 inactive "$WORKERS" 203.0.113.17/32 0
  ruleset "$(filter_table)" > "$HOST/edge-1/rules"
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: FRR is not running"* ]]
  [[ $output == *"FAIL  lab-edge-1: the nftables rules are not loaded"* ]]
  [[ $output == *"FAIL  lab-edge-1: the kernel does not forward"* ]]
  [[ $output != *lab-edge-2* ]]

  # A route with fewer next hops than sessions is for a person to read, as a local-only Service has.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  jq '.routes["203.0.113.17/32"] |= .[:1]' "$HOST/edge-1/table.json" > "$HOST/edge-1/table.tmp"
  mv "$HOST/edge-1/table.tmp" "$HOST/edge-1/table.json"
  edge_check --edge 1
  [ "$status" -eq 0 ]
  [[ $output == *"skip  lab-edge-1: next hops: 1 of 1 routes have fewer next hops than sessions"* ]]

  # Without the cluster's talman.yaml the checks that need it are skipped, not failed.
  mv "$REPO/talos/lab-sto2/talman.yaml" "$REPO/talos/lab-sto2/talman.moved"
  edge_check --edge 1
  [ "$status" -eq 0 ]
  [[ $output == *"skip  lab-edge-1: sessions:"* && $output == *"skip  lab-edge-1: routes:"* ]]
}

@test "edge-check fails when what keeps the proxy's connections from the cloud's router is missing, or unattended upgrades are on" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_check --edge 1
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"pass  lab-edge-1: the service range is unreachable on the edge but through a worker's route"* ]]
  [[ $output == *"pass  lab-edge-1: the output chain keeps the proxy's connections to the Gateway on a worker's route"* ]]
  [[ $output == *"pass  lab-edge-1: the forward chain forwards nothing"* ]]
  [[ $output == *"pass  lab-edge-1: unattended upgrades are off"* ]]

  # FRR runs its package's defaults, as after a first boot that failed: no reject route is configured.
  printf 'frr defaults traditional\n' > "$HOST/edge-1/config"
  : > "$HOST/edge-1/unreachable"
  edge_check --edge 1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: FRR's configuration holds no reject route for the service range"* ]]

  # Configured, but not in the kernel, as while FRR is stopped.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  : > "$HOST/edge-1/unreachable"
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: the service range's reject route is not in the kernel"* ]]

  # A reject route for another range than the cluster's service range.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  printf 'ip route 198.51.100.0/28 reject\n' > "$HOST/edge-1/config"
  echo 'unreachable 198.51.100.0/28 proto static metric 20' > "$HOST/edge-1/unreachable"
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: FRR's reject route is not for the cluster's service range"* ]]

  # The output chain's guard, by the rules' content: missing, for another Gateway, without a worker's
  # address, or holding the default route's next hop.
  local entry chain gateway_of_chain wrong
  for entry in \
    "none||the output chain does not refuse a packet toward the Gateway that does not go through a worker" \
    "192.0.2.20-192.0.2.99|203.0.113.22|the output chain's guard is not for the cluster's Gateway address" \
    "192.0.2.20-192.0.2.29||the output chain's guard leaves out a worker's address" \
    "192.0.2.0/24||the output chain's guard admits the default route's next hop" \
    "192.0.2.1, 192.0.2.20-192.0.2.99||the output chain's guard admits the default route's next hop"; do
    IFS='|' read -r chain gateway_of_chain wrong <<< "$entry"
    edge_state 1 active "$WORKERS" 203.0.113.17/32
    output_chain "$chain" ${gateway_of_chain:+"$gateway_of_chain"} > "$HOST/edge-1/output"
    edge_check --edge 1
    echo "$chain: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"FAIL  lab-edge-1: $wrong"* ]]
  done

  # A rule in the forward chain, and a forward chain that does not drop by default.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  forward_chain 'ip daddr 203.0.113.21 tcp dport { 80, 443 } accept' > "$HOST/edge-1/forward"
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: the forward chain holds a rule, so it may forward"* ]]
  FORWARD_POLICY=accept forward_chain > "$HOST/edge-1/forward"
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: the forward chain does not drop by default"* ]]

  # The translation table still loaded beside the edge's own.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  ruleset "$(own_table)" "$(translation_table)" > "$HOST/edge-1/rules"
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output$'\n' == *"FAIL  lab-edge-1: the ruleset on the edge holds what translates an address: a chain hooked at nat, a dnat statement, a snat statement"$'\n'* ]]

  # Forwarding on with no rules loaded.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  ruleset > "$HOST/edge-1/rules"
  : > "$HOST/edge-1/forward"
  : > "$HOST/edge-1/output"
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: the kernel forwards without the nftables rules"* ]]

  # Unattended upgrades on, as the image's package has them.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  echo 'APT::Periodic::Unattended-Upgrade "1";' > "$HOST/edge-1/upgrades"
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: unattended upgrades are on, and would upgrade and restart FRR in place"* ]]
  no_address "$output"
}

@test "edge-check fails an edge whose proxy is not running, runs as root, listens beyond its own address or sends no header" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_check --edge 1
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"pass  lab-edge-1: the proxy is running"* ]]
  [[ $output == *"pass  lab-edge-1: the proxy runs as its own user, not root"* ]]
  [[ $output == *"pass  lab-edge-1: the proxy listens on the addresses and ports its configuration binds, and on no others"* ]]
  [[ $output == *"pass  lab-edge-1: the proxy sends each connection to the cluster's Gateway address, with the PROXY protocol version 2 header"* ]]
  [[ $output == *"pass  lab-edge-1: the proxy's configuration binds the stack's public ports, and no other port"* ]]
  no_address "$output"

  # Not running.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  echo inactive > "$HOST/edge-1/proxy"
  : > "$HOST/edge-1/proxy-users"
  : > "$HOST/edge-1/listening"
  edge_check --edge 1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: the proxy is not running"* ]]
  [[ $output == *"FAIL  lab-edge-1: the proxy has no process"* ]]
  [[ $output == *"FAIL  lab-edge-1: the proxy's listeners are not those its configuration binds"* ]]

  # A process of root's among its processes, or all of them root's.
  for users in 'root' $'haproxy\nroot'; do
    edge_state 1 active "$WORKERS" 203.0.113.17/32
    echo "$users" > "$HOST/edge-1/proxy-users"
    edge_check --edge 1
    echo "$users: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"FAIL  lab-edge-1: the proxy runs as a user other than haproxy"* ]]
  done

  # Listening on every address, on an address that is not the one configured, on a port that is not
  # configured, or not listening on one that is.
  local listeners
  for listeners in \
    $'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("haproxy",pid=611,fd=5))\nLISTEN 0 4096 192.0.2.7:443 0.0.0.0:* users:(("haproxy",pid=611,fd=6))' \
    $'LISTEN 0 4096 *:80 *:* users:(("haproxy",pid=611,fd=5))\nLISTEN 0 4096 192.0.2.7:443 0.0.0.0:* users:(("haproxy",pid=611,fd=6))' \
    $'LISTEN 0 4096 192.0.2.7:80 0.0.0.0:* users:(("haproxy",pid=611,fd=5))\nLISTEN 0 4096 192.0.2.7:443 0.0.0.0:* users:(("haproxy",pid=611,fd=6))\nLISTEN 0 4096 192.0.2.7:8080 0.0.0.0:* users:(("haproxy",pid=611,fd=7))' \
    $'LISTEN 0 4096 192.0.2.7:80 0.0.0.0:* users:(("haproxy",pid=611,fd=5))' \
    $'LISTEN 0 4096 192.0.2.99:80 0.0.0.0:* users:(("haproxy",pid=611,fd=5))\nLISTEN 0 4096 192.0.2.99:443 0.0.0.0:* users:(("haproxy",pid=611,fd=6))'; do
    edge_state 1 active "$WORKERS" 203.0.113.17/32
    echo "$listeners" > "$HOST/edge-1/listening"
    edge_check --edge 1
    echo "$listeners: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"FAIL  lab-edge-1: the proxy's listeners are not those its configuration binds"* ]]
    no_address "$output"
  done

  # A configuration that binds every address.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  proxy_config 203.0.113.21 0.0.0.0 > "$HOST/edge-1/proxy-config"
  proxy_listeners 0.0.0.0 > "$HOST/edge-1/listening"
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: the proxy's configuration binds every address, not the edge's own"* ]]

  # A backend that is another address than the Gateway's, one that sends no header, a header of the
  # first version, and a second backend.
  for options in "203.0.113.22|send-proxy-v2 source 192.0.2.7|is not the cluster's Gateway address" \
    "203.0.113.21|source 192.0.2.7|does not send the PROXY protocol version 2 header" \
    "203.0.113.21|send-proxy source 192.0.2.7|does not send the PROXY protocol version 2 header"; do
    IFS='|' read -r gateway opts wrong <<< "$options"
    edge_state 1 active "$WORKERS" 203.0.113.17/32
    proxy_config "$gateway" 192.0.2.7 "$opts" > "$HOST/edge-1/proxy-config"
    edge_check --edge 1
    echo "$options: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"FAIL  lab-edge-1: a backend of the proxy $wrong"* ]]
  done
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  { proxy_config; printf '    server spare 203.0.113.99:80 send-proxy-v2\n'; } > "$HOST/edge-1/proxy-config"
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: a backend of the proxy is not the cluster's Gateway address"* ]]
  no_address "$output"

  # A port that is not one of the stack's public ports, bound on the edge's own address with its
  # listener and a backend of its own, so the configuration agrees with itself; and the public ports
  # as TF_VAR_public_ports gives the stack fewer of them than the configuration binds.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  {
    proxy_config
    printf '\nfrontend public-8080\n    bind 192.0.2.7:8080\n    default_backend gateway-8080\n'
    printf '\nbackend gateway-8080\n    server gateway 203.0.113.21:8080 send-proxy-v2 source 192.0.2.7\n'
  } > "$HOST/edge-1/proxy-config"
  { proxy_listeners; printf 'LISTEN 0 4096 192.0.2.7:8080 0.0.0.0:* users:(("haproxy",pid=611,fd=7))\n'; } > "$HOST/edge-1/listening"
  edge_check --edge 1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"pass  lab-edge-1: the proxy listens on the addresses and ports its configuration binds, and on no others"* ]]
  [[ $output == *"FAIL  lab-edge-1: the ports the proxy's configuration binds are not the stack's public ports"* ]]
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  run env "${ENVIRONMENT[@]}" TF_VAR_public_ports='[80]' "$REPO/scripts/edge-check" --edge 1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: the ports the proxy's configuration binds are not the stack's public ports"* ]]
  no_address "$output"

  # Without the Gateway's address in talman.yaml the backends' address is compared with nothing,
  # which the check says instead of passing it; the header is still checked.
  yq -i 'del(.values.bgp)' "$REPO/talos/lab-sto2/talman.yaml"
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_check --edge 1
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"skip  lab-edge-1: the proxy's backends: not compared with the Gateway's address, which talos/lab-sto2/talman.yaml does not give; each sends the PROXY protocol version 2 header"* ]]
  [[ $output != *"the cluster's Gateway address"* ]]
  proxy_config 203.0.113.21 192.0.2.7 'source 192.0.2.7' > "$HOST/edge-1/proxy-config"
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: a backend of the proxy does not send the PROXY protocol version 2 header"* ]]
}

@test "edge-check fails, naming the worker and the way out, when talman.yaml gives a worker no address" {
  # A talman.yaml written before it carried each node's own address: a session from an address that
  # is no worker's must not pass for a worker's.
  yq -i 'del(.nodes[] | select(.hostname == "lab-w-2") | .values.privateAddress)' "$REPO/talos/lab-sto2/talman.yaml"
  edge_state 1 active "192.0.2.20 192.0.2.22 192.0.2.99" 203.0.113.17/32
  edge_check --edge 1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: 3 of 3 worker sessions are established, but talman.yaml has no privateAddress for lab-w-2; run just infra-talman"* ]]
  [[ $output == *"FAIL  lab-edge-1: the output chain's guard cannot be checked against every worker: talman.yaml has no privateAddress for lab-w-2; run just infra-talman"* ]]
  [[ $output != *"pass  lab-edge-1: 3 of 3 worker sessions"* ]]
  no_address "$output"
}

# on_edge NUMBER COMMAND: COMMAND on fake edge NUMBER through the fake ssh, as the check runs its own.
on_edge() {
  local address=ADDRESS_$1
  run env "${ENVIRONMENT[@]}" ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts" \
    "debian@${!address}" "$2"
}

@test "A healthy edge passes the check with only what its ordinary user can run" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" "203.0.113.17/32 203.0.113.18/32"
  # A newer daemon prints the keywords in their own case, an older one in lower case.
  awk '!/^[[:space:]]*(#|$)/' "$ROOT/infra/openstack/stacks/sto2/edge/sshd.conf" > "$HOST/edge-2/sshd"

  # The fake edge is as narrow as a real one: what Debian installs in /usr/sbin is not found by name
  # for its ordinary user, and runs through sudo, whose secure_path holds the sbin directories.
  for tool in sysctl nft sshd; do
    on_edge 1 "command -v $tool"
    [ "$status" -ne 0 ]
  done
  on_edge 1 'sudo -n sysctl -n net.ipv4.ip_forward'
  [ "$status" -eq 0 ]
  on_edge 1 'sudo -n nft list tables'
  [ "$status" -eq 0 ]
  for tool in systemctl ip apt-config sudo cat; do
    on_edge 1 "command -v $tool"
    [ "$status" -eq 0 ]
  done

  rm -f "$HOST"/edge-*/sudo-log
  edge_check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output != *FAIL* && $output != *skip* ]]
  # The forwarding state is read from /proc as the ordinary user, never by asking sudo for it.
  for n in 1 2; do
    [ -f "$HOST/edge-$n/forwarding-read-as-user" ]
    [ ! -e "$HOST/edge-$n/forwarding-read-under-sudo" ]
    ! grep -Eq 'sysctl|cat|ip_forward' "$HOST/edge-$n/sudo-log"
  done
  for edge in lab-edge-1 lab-edge-2; do
    [[ $output == *"pass  $edge: FRR is running"* ]]
    [[ $output == *"pass  $edge: 3 of 3 worker sessions are established"* ]]
    [[ $output == *"pass  $edge: the nftables rules are loaded"* ]]
    [[ $output == *"pass  $edge: the kernel forwards"* ]]
    [[ $output == *"pass  $edge: the forward chain forwards nothing"* ]]
    [[ $output == *"pass  $edge: the output chain keeps the proxy's connections to the Gateway on a worker's route"* ]]
    [[ $output == *"pass  $edge: the proxy is running"* ]]
    [[ $output == *"pass  $edge: the proxy runs as its own user, not root"* ]]
    [[ $output == *"pass  $edge: unattended upgrades are off"* ]]
    [[ $output == *"pass  $edge: the SSH daemon runs with the settings the first boot wrote"* ]]
  done
  no_address "$output"
}

@test "A state the edge did not report is a failure that says it could not be read" {
  local entry section label unhealthy
  # Per section of the report: what the check calls it, and the conclusion it must not draw from an
  # answer that never came. Each command fails with a message that holds an address, which the check
  # must not print.
  for entry in \
    "frr|FRR's state|FRR is not running" \
    "sessions|the BGP sessions|worker sessions are established" \
    "table|the BGP table|the table holds" \
    "config|FRR's running configuration|FRR's configuration holds no reject route" \
    "unreachable|the kernel's unreachable routes|is not in the kernel" \
    "rules|the nftables ruleset|the nftables rules are not loaded" \
    "forward|the forward chain|the forward chain holds a rule" \
    "output|the output chain|the output chain does not refuse" \
    "default|the default route|the output chain keeps" \
    "proxy|the proxy's state|the proxy is not running" \
    "proxy-users|the proxy's processes|the proxy has no process" \
    "proxy-config|the proxy's configuration|a backend of the proxy" \
    "listening|the listening sockets|the proxy's listeners are not" \
    "forwarding|the kernel's forwarding state|the kernel does not forward" \
    "upgrades|the unattended upgrades setting|unattended upgrades are on" \
    "sshd|the SSH daemon's settings|differ"; do
    IFS='|' read -r section label unhealthy <<< "$entry"
    edge_state 1 active "$WORKERS" 203.0.113.17/32
    rm -f "$HOST"/edge-1/broken-*
    echo "Error: cannot reach 192.0.2.77, the daemon said no" > "$HOST/edge-1/broken-$section"
    edge_check --edge 1
    echo "$section: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"FAIL  lab-edge-1: cannot read $label on the edge: Error: cannot reach <address>, the daemon said no"* ]]
    [[ $output != *"$unhealthy"* ]]
    no_address "$output"
  done

  # A state the edge did report, forwarding off, is still the conclusion drawn from a real answer.
  edge_state 1 active "$WORKERS" 203.0.113.17/32 0
  rm -f "$HOST"/edge-1/broken-*
  edge_check --edge 1
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: the kernel does not forward"* ]]
  [[ $output != *"cannot read"* ]]

  # A command the edge does not have is not found, and says so; the sections around it still report.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  rm -f "$HOST"/edge-1/broken-*
  rm "$HOST_SBIN/nft"
  edge_check --edge 1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: cannot read the nftables ruleset on the edge: "*"not found"* ]]
  [[ $output == *"pass  lab-edge-1: FRR is running"* ]]
  [[ $output == *"pass  lab-edge-1: unattended upgrades are off"* ]]
  [[ $output != *"the kernel does not forward"* ]]

  # The edge cannot make the file a command's standard error is kept in: every section says why.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  rm -f "$HOST"/edge-1/broken-* "$HOST_BIN/mktemp"
  host_fake mktemp << 'EOF'
echo "mktemp: failed to create file via template '/tmp/tmp.XXXXXXXXXX': No space left on device" >&2
exit 1
EOF
  edge_check --edge 1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: cannot read FRR's state on the edge: not asked, as mktemp failed: "*"No space left on device"* ]]
  [[ $output == *"FAIL  lab-edge-1: cannot read the SSH daemon's settings on the edge: not asked, as mktemp failed: "*"No space left on device"* ]]
  [[ $output != *"pass "* && $output != *"the kernel does not forward"* ]]
}

@test "The check fails an edge whose loaded ruleset has a chain hooked at nat or a statement that translates, in any table" {
  local statement answer objects hook
  local passes='pass  lab-edge-1: the nftables rules are loaded, and none translates an address'

  # The edge's own table as nft lists it, alone, beside a second table that only filters, beside one
  # whose chain filters before routing, and with rules that name a translation without stating one:
  # every line passes.
  for objects in '' "$(filter_table)" "$(prerouting_filter)" "$(named_not_stated)"; do
    check_ruleset "$(own_table)" "$objects"
    [ "$status" -eq 0 ]
    [[ $output$'\n' == *"$passes"$'\n'* ]]
    [[ $output != *FAIL* && $output != *skip* ]]
    no_address "$output"
  done

  # Each alone beside the edge's own table: a chain hooked at nat that holds no rule, in a table of
  # another name, before routing, at output and after routing; the nat table iptables-nft makes;
  # each statement that translates, in a chain that is hooked nowhere, in the edge's own table and in
  # another; and the table of an edge that translates, by its name.
  for hook in prerouting output postrouting; do
    translates "$(nat_chain "$hook")" "a chain hooked at nat"
  done
  translates "$(iptables_nat_table)" "a chain hooked at nat"
  for statement in dnat snat masquerade redirect; do
    translates "$(unhooked "$statement" inet)" "a $statement statement"
    translates "$(unhooked "$statement")" "a $statement statement"
  done
  translates "$(translation_table)" "a chain hooked at nat, a dnat statement, a snat statement"

  # Without the edge's own table its rules are not loaded: with nothing loaded, with a table of the
  # edge's name in another family, and with a table of its family under another name.
  for objects in '' '{"table": {"family": "ip", "name": "edge", "handle": 1}}' "$(filter_table)"; do
    edge_state 1 active "$WORKERS" 203.0.113.17/32
    ruleset "$objects" > "$HOST/edge-1/rules"
    : > "$HOST/edge-1/forward"
    : > "$HOST/edge-1/output"
    edge_check --edge 1
    echo "$output"
    [ "$status" -ne 0 ]
    [[ $output$'\n' == *"FAIL  lab-edge-1: the nftables rules are not loaded"$'\n'* ]]
    [[ $output == *"FAIL  lab-edge-1: the kernel forwards without the nftables rules"* ]]
    [[ $output != *translate* ]]
  done

  # What is loaded in their place is named all the same, on a line of its own.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  ruleset "$(nat_chain)" "$(unhooked masquerade)" > "$HOST/edge-1/rules"
  : > "$HOST/edge-1/forward"
  : > "$HOST/edge-1/output"
  edge_check --edge 1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output$'\n' == *"FAIL  lab-edge-1: the nftables rules are not loaded"$'\n'* ]]
  [[ $output$'\n' == *"FAIL  lab-edge-1: the ruleset on the edge holds what translates an address: a chain hooked at nat, a masquerade statement"$'\n'* ]]
  [[ $output == *"FAIL  lab-edge-1: the kernel forwards without the nftables rules"* ]]
  [[ $output != *"none translates an address"* ]]
  no_address "$output"

  # A rule that jumps to an inline chain, beside the edge's own table: what the chain's rules state,
  # a masquerade here, is in a text the check does not read, so the ruleset is not read as one that
  # translates nothing. It is neither a pass nor rules that are not loaded.
  check_ruleset "$(own_table)" "$(inline_chain)"
  [ "$status" -ne 0 ]
  [[ $output$'\n' == *"FAIL  lab-edge-1: cannot read the nftables ruleset on the edge: a rule holds a statement that nft lists as text, not as JSON, as it lists an inline chain"$'\n'* ]]
  [[ $output != *"none translates an address"* && $output != *"the nftables rules are not loaded"* ]]
  [[ $output == *"FAIL  lab-edge-1: the kernel forwards, and whether the nftables rules are loaded could not be read"* ]]
  no_address "$output"

  # An answer that is not nft's listing is not read as one: the tables' names alone, as nft list
  # tables prints them, JSON that is not a listing, a listing of another schema version, two
  # listings, and nothing at all. It is neither a pass nor rules that are not loaded.
  for answer in 'table inet edge' '{}' '[]' '{"nftables": []}' '{"nftables": [{"table": {"family": "inet", "name": "edge", "handle": 1}}]}' \
    '{"nftables": [{"metainfo": {"version": "9.9.9", "release_name": "a later one", "json_schema_version": 2}}, {"table": {"family": "inet", "name": "edge", "handle": 1}}]}' \
    "$(ruleset "$(own_table)")"$'\n'"$(ruleset "$(own_table)")" ''; do
    edge_state 1 active "$WORKERS" 203.0.113.17/32
    printf '%s\n' "$answer" > "$HOST/edge-1/rules"
    edge_check --edge 1
    echo "${answer:0:60}: $output"
    [ "$status" -ne 0 ]
    [[ $output$'\n' == *"FAIL  lab-edge-1: cannot read the nftables ruleset on the edge: its answer is not nft's JSON listing of schema version 1"$'\n'* ]]
    [[ $output != *"none translates an address"* && $output != *"the nftables rules are not loaded"* ]]
    [[ $output == *"FAIL  lab-edge-1: the kernel forwards, and whether the nftables rules are loaded could not be read"* ]]
    no_address "$output"
  done
}

@test "Without a Gateway address the output chain's guard is a skip that says what was not compared" {
  local entry chain wrong
  local kept="the output chain keeps the proxy's connections to the Gateway on a worker's route"
  local skipped="skip  lab-edge-1: the output chain's guard: not compared with the Gateway's address, which talos/lab-sto2/talman.yaml does not give"

  # With the address in talman.yaml the guard is compared with it, and passes.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_check --edge 1
  [ "$status" -eq 0 ]
  [[ $output == *"pass  lab-edge-1: $kept"* ]]

  # A talman.yaml that lists the workers and gives no Gateway address: the line is a skip, which
  # says what was not compared and what was still checked, and it fails nothing.
  yq -i 'del(.values.bgp)' "$REPO/talos/lab-sto2/talman.yaml"
  edge_check --edge 1
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output$'\n' == *"$skipped; it holds every worker's address and not the default route's next hop"$'\n'* ]]
  [[ $output != *"$kept"* && $output != *FAIL* ]]
  no_address "$output"
  # A guard for another address cannot be told from one for the Gateway's: the same skip.
  output_chain '192.0.2.20-192.0.2.99' 203.0.113.22 > "$HOST/edge-1/output"
  edge_check --edge 1
  [ "$status" -eq 0 ]
  [[ $output$'\n' == *"$skipped; it holds every worker's address and not the default route's next hop"$'\n'* ]]

  # What needs no Gateway address still fails: no guard rule, a worker's address left out, and the
  # default route's next hop admitted, as a network or by itself.
  for entry in \
    "none|the output chain does not refuse a packet toward the Gateway that does not go through a worker" \
    "192.0.2.20-192.0.2.29|the output chain's guard leaves out a worker's address" \
    "192.0.2.0/24|the output chain's guard admits the default route's next hop" \
    "192.0.2.1, 192.0.2.20-192.0.2.99|the output chain's guard admits the default route's next hop"; do
    IFS='|' read -r chain wrong <<< "$entry"
    edge_state 1 active "$WORKERS" 203.0.113.17/32
    output_chain "$chain" > "$HOST/edge-1/output"
    edge_check --edge 1
    echo "$chain: $output"
    [ "$status" -ne 0 ]
    [[ $output$'\n' == *"FAIL  lab-edge-1: $wrong"$'\n'* ]]
    [[ $output != *"the output chain's guard: not compared"* && $output != *"$kept"* ]]
  done
  # And a worker without an address in the file.
  yq -i 'del(.nodes[] | select(.hostname == "lab-w-2") | .values.privateAddress)' "$REPO/talos/lab-sto2/talman.yaml"
  edge_state 1 active "192.0.2.20 192.0.2.22" 203.0.113.17/32
  edge_check --edge 1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: the output chain's guard cannot be checked against every worker: talman.yaml has no privateAddress for lab-w-2; run just infra-talman"* ]]
  [[ $output != *"the output chain's guard: not compared"* && $output != *"$kept"* ]]

  # A talman.yaml that gives no Gateway address and lists no worker, and no talman.yaml at all: no
  # worker's address was looked for in the guard either, which the skip says; a guard that is
  # missing or admits the default route's next hop still fails.
  for entry in listed absent; do
    if [[ $entry == listed ]]; then
      yq -i 'del(.nodes[] | select(.role == "worker"))' "$REPO/talos/lab-sto2/talman.yaml"
    else
      rm "$REPO/talos/lab-sto2/talman.yaml"
    fi
    edge_state 1 active "$WORKERS" 203.0.113.17/32
    edge_check --edge 1
    echo "$entry: $output"
    [ "$status" -eq 0 ]
    [[ $output$'\n' == *"$skipped, and no worker's address was looked for in it, as the file gives none either; it does not hold the default route's next hop"$'\n'* ]]
    [[ $output != *"$kept"* && $output != *FAIL* ]]
    no_address "$output"
    output_chain none > "$HOST/edge-1/output"
    edge_check --edge 1
    [ "$status" -ne 0 ]
    [[ $output == *"FAIL  lab-edge-1: the output chain does not refuse a packet toward the Gateway that does not go through a worker"* ]]
    output_chain '192.0.2.0/24' > "$HOST/edge-1/output"
    edge_check --edge 1
    [ "$status" -ne 0 ]
    [[ $output == *"FAIL  lab-edge-1: the output chain's guard admits the default route's next hop"* ]]
    [[ $output != *"the output chain's guard: not compared"* ]]
  done
}

@test "The check fails an edge whose SSH daemon accepts another key exchange or a password" {
  local keyword keywords entry weak
  mapfile -t keywords < <(awk '!/^[[:space:]]*(#|$)/ { print tolower($1) }' "$ROOT/infra/openstack/stacks/sto2/edge/sshd.conf")
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  edge_check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"pass  lab-edge-1: the SSH daemon runs with the settings the first boot wrote"* ]]

  # A key exchange the tree does not name, and nothing else wrong: that setting fails, by name, and
  # the weak algorithm's name is not printed.
  sed -i 's/^kexalgorithms .*/kexalgorithms curve25519-sha256,diffie-hellman-group14-sha1/' "$HOST/edge-1/sshd"
  edge_check
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output$'\n' == *"FAIL  lab-edge-1: the SSH daemon's effective settings differ from the first boot's: kexalgorithms"$'\n'* ]]
  [[ $output != *"diffie-hellman"* ]]
  [[ $output == *"pass  lab-edge-2: the SSH daemon runs with the settings the first boot wrote"* ]]

  # The tree's list and a weak one after it, for the key exchange, the ciphers and the MACs: the
  # daemon accepts every one the tree names and one more, which only a comparison of the whole value
  # tells.
  for entry in kexalgorithms,diffie-hellman-group14-sha1 ciphers,aes128-cbc macs,hmac-sha1; do
    keyword=${entry%%,*} weak=${entry#*,}
    edge_state 1 active "$WORKERS" 203.0.113.17/32
    sed -i "s/^$keyword .*/&,$weak/" "$HOST/edge-1/sshd"
    grep -q "^$keyword [^ ]*,$weak\$" "$HOST/edge-1/sshd"
    edge_check --edge 1
    echo "$keyword and $weak: $output"
    [ "$status" -ne 0 ]
    [[ $output$'\n' == *"FAIL  lab-edge-1: the SSH daemon's effective settings differ from the first boot's: $keyword"$'\n'* ]]
    [[ $output != *"$weak"* ]]
  done

  # A public key, or a password instead: the tree's method and another after it.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  sed -i 's/^authenticationmethods .*/& password/' "$HOST/edge-1/sshd"
  grep -qx 'authenticationmethods publickey password' "$HOST/edge-1/sshd"
  edge_check --edge 1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output$'\n' == *"FAIL  lab-edge-1: the SSH daemon's effective settings differ from the first boot's: authenticationmethods"$'\n'* ]]

  # A password accepted, and nothing else wrong.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  sed -i 's/^passwordauthentication .*/passwordauthentication yes/' "$HOST/edge-1/sshd"
  edge_check --edge 1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output$'\n' == *"FAIL  lab-edge-1: the SSH daemon's effective settings differ from the first boot's: passwordauthentication"$'\n'* ]]

  # Each setting of the tree is compared, whatever its value is, and one that the daemon does not
  # report at all is as wrong as one with another value.
  for keyword in "${keywords[@]}"; do
    edge_state 1 active "$WORKERS" 203.0.113.17/32
    sed -i "s/^$keyword .*/$keyword other/" "$HOST/edge-1/sshd"
    edge_check --edge 1
    echo "$keyword changed: $output"
    [ "$status" -ne 0 ]
    [[ $output$'\n' == *"FAIL  lab-edge-1: the SSH daemon's effective settings differ from the first boot's: $keyword"$'\n'* ]]

    edge_state 1 active "$WORKERS" 203.0.113.17/32
    sed -i "/^$keyword /d" "$HOST/edge-1/sshd"
    edge_check --edge 1
    echo "$keyword absent: $output"
    [ "$status" -ne 0 ]
    [[ $output$'\n' == *"FAIL  lab-edge-1: the SSH daemon's effective settings differ from the first boot's: $keyword"$'\n'* ]]
  done

  # Two settings wrong are both named.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  sed -i 's/^passwordauthentication .*/passwordauthentication yes/; s/^permitrootlogin .*/permitrootlogin yes/' "$HOST/edge-1/sshd"
  edge_check --edge 1
  [[ $output$'\n' == *"differ from the first boot's: passwordauthentication, permitrootlogin"$'\n'* ]]
  no_address "$output"

  # A Match block that turns passwords on for another user leaves the edge's user's connection as
  # the tree says; one for the edge's user is a password accepted, though the daemon's settings
  # outside any Match are the tree's.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  echo 'passwordauthentication yes' > "$HOST/edge-1/sshd-match-user-someone-else"
  edge_check --edge 1
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"pass  lab-edge-1: the SSH daemon runs with the settings the first boot wrote"* ]]
  echo 'passwordauthentication yes' > "$HOST/edge-1/sshd-match-user-debian"
  edge_check --edge 1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output$'\n' == *"FAIL  lab-edge-1: the SSH daemon's effective settings differ from the first boot's: passwordauthentication"$'\n'* ]]

  # The same, read by the machine's own OpenSSH server where it has one: the tree's settings as the
  # drop-in an image's main file includes, and the image's Match block in a drop-in after it.
  if type -P sshd ssh-keygen > /dev/null; then
    edge_state 1 active "$WORKERS" 203.0.113.17/32
    mkdir -p "$HOST/edge-1/sshd_config.d"
    ssh-keygen -q -t ed25519 -N '' -f "$HOST/edge-1/ssh-host-key"
    printf 'Include %s/*.conf\n' "$HOST/edge-1/sshd_config.d" > "$HOST/edge-1/sshd_config"
    cp "$ROOT/infra/openstack/stacks/sto2/edge/sshd.conf" "$HOST/edge-1/sshd_config.d/00-edge.conf"
    printf 'Match User someone-else\n  PasswordAuthentication yes\n' > "$HOST/edge-1/sshd_config.d/50-image.conf"
    edge_check --edge 1
    echo "real sshd, another user's Match: $output"
    [ "$status" -eq 0 ]
    [[ $output == *"pass  lab-edge-1: the SSH daemon runs with the settings the first boot wrote"* ]]
    printf 'Match User debian\n  PasswordAuthentication yes\n' > "$HOST/edge-1/sshd_config.d/50-image.conf"
    edge_check --edge 1
    echo "real sshd, the edge's user's Match: $output"
    [ "$status" -ne 0 ]
    [[ $output$'\n' == *"FAIL  lab-edge-1: the SSH daemon's effective settings differ from the first boot's: passwordauthentication"$'\n'* ]]
  else
    echo "not proved here: no sshd on this machine, so the Match for the edge's user is read by the fake sshd only"
  fi
}

# rollout: scripts/edge-rollout --yes in the copy, the operator typing yes for every host key the
# replaced edges offer.
rollout() {
  run bash -c 'printf "yes\nyes\nyes\nyes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --yes
}

@test "a check of one edge asks nothing about the other edge's host key" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  grep -v "^$ADDRESS_2 " "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts" > "$BATS_TEST_TMPDIR/known"
  cp "$BATS_TEST_TMPDIR/known" "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  edge_check --edge 1 < /dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  absent '^ssh-keyscan ' "$RECORD/argv"
}

# plan_replacing NUMBER...: a plan, as tofu show -json prints it, that replaces the instances of the
# edges named and changes nothing else.
plan_replacing() {
  local numbers
  numbers=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  jq -n --argjson numbers "$numbers" '{resource_changes: [$numbers[] | {
    address: "module.edge[\"\(.)\"].openstack_compute_instance_v2.this",
    mode: "managed", type: "openstack_compute_instance_v2",
    change: {actions: ["delete", "create"]}}]}' > "$BATS_TEST_TMPDIR/plan.json"
}

# steps: the calls that matter to the order, one per line: edge-check, a targeted plan, an apply.
steps() {
  grep -E '^edge-check |^tofu .* plan .*-target=|^tofu .* apply ' "$RECORD/argv" |
    sed -E 's/ -input=false//; s|-chdir=[^ ]*/||; s/ -out=[^ ]*//; s/ -target=openstack_networking_floatingip_associate_v2[^ ]*//; s/ +/ /g; s/^tofu [^ ]* /tofu /; s/^(tofu apply) .*/\1/'
}

@test "A change to the configuration rolls out one edge at a time and stops when the check fails" {
  # The copy's edge-check is a recording fake whose verdict for an edge is the exit status in the
  # file check-<number> in the record's directory, 0 when there is none.
  cat > "$REPO/scripts/edge-check" << EOF
#!/usr/bin/env bash
printf '%s\n' "edge-check \$*" >> "$RECORD/argv"
status=\$(cat "$RECORD/check-\${2-}" 2> /dev/null || echo 0)
[[ \$status == 0 ]] || echo "FAIL  fixture: the check fails"
exit "\$status"
EOF
  chmod +x "$REPO/scripts/edge-check"
  plan_replacing 1 2

  # Applied as it is, a plan that replaces both is refused, and nothing is applied.
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge --yes
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"replaces both edge routers at once"* ]]
  [[ $output == *"just edge-rollout"* ]]
  absent ' apply ' "$RECORD/argv"

  # One edge replaced is applied as any plan is.
  plan_replacing 2
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge --yes
  [ "$status" -eq 0 ]
  grep -q ' apply ' "$RECORD/argv"

  # The rollout replaces the first edge, checks it, and only then replaces the second; and before it
  # replaces an edge it checks the other one.
  plan_replacing 1 2
  : > "$RECORD/argv"
  rollout
  echo "$output"
  [ "$status" -eq 0 ]
  expected=$(printf '%s\n' \
    'edge-check --edge 2' \
    'tofu plan -target=module.edge["1"]' \
    'tofu apply' \
    'edge-check --edge 1' \
    'edge-check --edge 1' \
    'tofu plan -target=module.edge["2"]' \
    'tofu apply' \
    'edge-check --edge 2')
  steps
  [ "$(steps)" = "$expected" ]

  # The first edge fails its check once replaced: the rollout stops, and the second edge is never
  # planned, applied or touched.
  : > "$RECORD/argv"
  echo 1 > "$RECORD/check-1"
  rollout
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"edge 1 does not pass its check"* ]]
  [ "$(grep -c '^tofu .* apply ' "$RECORD/argv")" -eq 1 ]
  absent 'module.edge\["2"\]' "$RECORD/argv"

  # The second edge not serving keeps the first from being replaced at all.
  : > "$RECORD/argv"
  rm "$RECORD/check-1"
  echo 1 > "$RECORD/check-2"
  rollout
  [ "$status" -ne 0 ]
  [[ $output == *"edge 2 does not pass its check, so edge 1 is not replaced"* ]]
  absent ' apply ' "$RECORD/argv"
}

# trail: what the host key handling did, in order, one step per line: an apply, dropping an edge's
# recorded keys, scanning an edge for its keys, and a connection to an edge. EDGE is 1 or 2.
trail() {
  grep -E "^tofu .* apply |^ssh-keygen -R |^ssh-keyscan |^ssh .*@" "$RECORD/argv" |
    sed -E "s/^tofu .*/apply/; s/^ssh-keygen -R $ADDRESS_1 .*/forget 1/; s/^ssh-keygen -R $ADDRESS_2 .*/forget 2/; \
      s/^ssh-keyscan .*$ADDRESS_1\$/scan 1/; s/^ssh-keyscan .*$ADDRESS_2\$/scan 2/; \
      s/^ssh .*@$ADDRESS_1 .*/ssh 1/; s/^ssh .*@$ADDRESS_2 .*/ssh 2/"
}

# recorded NUMBER: the key the known_hosts file holds for edge NUMBER.
recorded() {
  local address=$ADDRESS_1
  [[ $1 == 1 ]] || address=$ADDRESS_2
  grep "^$address " "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts" | awk '{ print $3 }'
}

# original_keys: both edges offer their original host keys again, and those are the ones recorded.
original_keys() {
  local address
  for address in "$ADDRESS_1" "$ADDRESS_2"; do
    echo "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${address//./}Original" > "$HOST/key-$address"
    grep -v "^$address " "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts" > "$BATS_TEST_TMPDIR/known" || true
    echo "$address ssh-ed25519 $(cat "$HOST/key-$address")" >> "$BATS_TEST_TMPDIR/known"
    cp "$BATS_TEST_TMPDIR/known" "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  done
}

@test "a replaced edge offers new host keys at its old address, and the rollout goes on only after they are recorded" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  plan_replacing 1 2
  original_1=$(recorded 1)

  # The stack's outputs name no instance here, so no console is read: the operator types yes once
  # per replaced edge, as the fingerprints are shown. edge-check is the real script here: its ssh
  # refuses a host whose key is not the recorded one.
  : > "$RECORD/argv"
  run bash -c 'printf "yes\nyes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"$(fingerprint "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_1//./}Replacement")"* ]]
  [ "$(recorded 1)" = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_1//./}Replacement" ]
  [ "$(recorded 1)" != "$original_1" ]
  [ "$(recorded 2)" = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_2//./}Replacement" ]
  # The first edge's keys are dropped before its replacement, the new ones are scanned and recorded
  # after it, and only then is it connected to; the second edge is not replaced before that.
  expected=$(printf '%s\n' \
    'ssh 2' 'forget 1' 'apply' 'scan 1' 'ssh 1' \
    'ssh 1' 'forget 2' 'apply' 'scan 2' 'ssh 2')
  [ "$(trail)" = "$expected" ]
  no_address "$output"

  # Declined: the first edge's new keys are not recorded, the rollout stops at once, without waiting
  # for an answer that will not change, and the second edge is never touched. The wait is long here,
  # and the clock is a sleep that records how long it was asked to wait and ends the rollout, so one
  # that waited could not hang the test.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  original_keys
  fake sleep << EOF
printf '%s\n' "sleep \$*" >> "$RECORD/argv"
kill -TERM "\$PPID"
EOF
  : > "$RECORD/argv"
  run bash -c 'printf "no\n" | env "$@"' _ "${ENVIRONMENT[@]}" EDGE_ROLLOUT_WAIT=900 EDGE_ROLLOUT_INTERVAL=15 \
    "$REPO/scripts/edge-rollout" --yes
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"edge 1's new SSH host key"*"was not accepted"* ]]
  absent '^sleep ' "$RECORD/argv"
  absent "^ssh .*@$ADDRESS_1 " "$RECORD/argv"
  [ "$(grep -c '^tofu .* apply ' "$RECORD/argv")" -eq 1 ]
  absent 'module.edge\["2"\]' "$RECORD/argv"
  [ "$(recorded 1)" = "" ]
}

@test "an edge whose instance the rollout's plan does not replace keeps its recorded host keys" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  # A change that updates the edges' security group in place and replaces no instance.
  jq -n '{resource_changes: [{address: "openstack_networking_secgroup_rule_v2.ssh[\"0\"]", mode: "managed",
    type: "openstack_networking_secgroup_rule_v2", change: {actions: ["update"]}}]}' > "$BATS_TEST_TMPDIR/plan.json"
  original_1=$(recorded 1) original_2=$(recorded 2)
  : > "$RECORD/argv"
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --yes < /dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(trail)" = "$(printf '%s\n' 'ssh 2' 'apply' 'ssh 1' 'ssh 1' 'apply' 'ssh 2')" ]
  [ "$(recorded 1)" = "$original_1" ]
  [ "$(recorded 2)" = "$original_2" ]
  [[ $output == *"edge 1: applied; its instance was not replaced"* ]]
  [[ $output == *"no edge was replaced, and edge 1 2 passes"* ]]
  [[ $output != *"edge 1 2 replaced"* ]]
}

# sequence: what a rollout did, in order, one step per line: every plan with what it targets and
# replaces, a check of an edge, dropping an edge's recorded keys, an apply, and scanning an edge for
# its keys.
sequence() {
  grep -E '^edge-check |^tofu .* plan |^tofu .* apply |^ssh-keygen -R |^ssh-keyscan ' "$RECORD/argv" |
    sed -E "s/^edge-check --edge ([12])$/check \1/; s/^tofu .* apply .*/apply/; \
      s/^tofu [^ ]* plan( -input=false)?( -out=[^ ]*)?/plan/; \
      s/^ssh-keygen -R $ADDRESS_1 .*/forget 1/; s/^ssh-keygen -R $ADDRESS_2 .*/forget 2/; \
      s/^ssh-keyscan .*$ADDRESS_1\$/scan 1/; s/^ssh-keyscan .*$ADDRESS_2\$/scan 2/"
}

# real_edge_check: the copy's edge-check, recorded: the real script runs behind it, so a check
# passes only with every worker's session established, over a connection that holds to the
# recorded keys.
real_edge_check() {
  mv "$REPO/scripts/edge-check" "$REPO/scripts/edge-check.real"
  cat > "$REPO/scripts/edge-check" << EOF
#!/usr/bin/env bash
printf '%s\n' "edge-check \$*" >> "$RECORD/argv"
exec "$REPO/scripts/edge-check.real" "\$@"
EOF
  chmod +x "$REPO/scripts/edge-check"
}

@test "A forced rollout replaces one edge at a time and stops when the check fails" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  # The configuration changed nothing: only the forced replacement replaces anything.
  echo '{"resource_changes": []}' > "$BATS_TEST_TMPDIR/plan.json"
  real_edge_check

  : > "$RECORD/argv"
  run bash -c 'printf "yes\nyes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --replace --yes
  echo "$output"
  [ "$status" -eq 0 ]
  # Each edge-check, a child of the rollout, shares the lock the rollout holds and is not refused.
  [[ $output != *"is busy"* ]]
  # Each plan that is applied targets one edge and replaces that edge's instance and nothing else;
  # the second edge is planned only once the first one's new keys are recorded and its check passes.
  expected=$(printf '%s\n' \
    'plan' \
    'check 2' \
    'plan -target=module.edge["1"] -target=openstack_networking_floatingip_associate_v2.edge["1"] -replace=module.edge["1"].openstack_compute_instance_v2.this' \
    'forget 1' 'apply' 'scan 1' 'check 1' \
    'check 1' \
    'plan -target=module.edge["2"] -target=openstack_networking_floatingip_associate_v2.edge["2"] -replace=module.edge["2"].openstack_compute_instance_v2.this' \
    'forget 2' 'apply' 'scan 2' 'check 2' \
    'plan')
  sequence
  [ "$(sequence)" = "$expected" ]
  [ "$(recorded 1)" = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_1//./}Replacement" ]
  [ "$(recorded 2)" = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_2//./}Replacement" ]
  [[ $output == *"pass  lab-edge-1: 3 of 3 worker sessions are established"* ]]
  no_address "$output"

  # Once replaced, the first edge has no session from one worker: its check fails, the rollout
  # stops, and the second edge is never planned, applied or touched.
  original_keys
  edge_state 1 active "192.0.2.20 192.0.2.22" 203.0.113.17/32
  : > "$RECORD/argv"
  run bash -c 'printf "yes\nyes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --replace --yes
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  lab-edge-1: 2 of 3 worker sessions are established; no session from lab-w-2"* ]]
  [[ $output == *"edge 1 does not pass its check"* ]]
  expected=$(printf '%s\n' \
    'plan' \
    'check 2' \
    'plan -target=module.edge["1"] -target=openstack_networking_floatingip_associate_v2.edge["1"] -replace=module.edge["1"].openstack_compute_instance_v2.this' \
    'forget 1' 'apply' 'scan 1' 'check 1')
  [ "$(sequence)" = "$expected" ]
  absent 'edge\["2"\]' "$RECORD/argv"
  [ "$(recorded 2)" = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_2//./}Original" ]
}

# instance_plan NUMBER ACTIONS: a plan, as tofu show -json prints it, whose only change is ACTIONS,
# a JSON list such as ["create"], on the instance of edge NUMBER.
instance_plan() {
  jq -n --arg number "$1" --argjson actions "$2" '{resource_changes: [{
    address: "module.edge[\"\($number)\"].openstack_compute_instance_v2.this", mode: "managed",
    type: "openstack_compute_instance_v2", change: {actions: $actions}}]}' > "$BATS_TEST_TMPDIR/plan.json"
}

@test "infra-apply replaces or deletes one edge only while the other passes its check" {
  real_edge_check
  edge_state 1 inactive "" "" 0
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  original_2=$(recorded 2)
  # Edge 1 does not serve: a plan that replaces edge 2, or deletes it, would leave none serving.
  for actions in '["delete", "create"]' '["delete"]'; do
    instance_plan 2 "$actions"
    : > "$RECORD/argv"
    run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge --yes < /dev/null
    echo "$output"
    [ "$status" -ne 0 ]
    [[ $output == *"edge 1 does not pass its check, so the plan that takes edge 2 down is not applied"* ]]
    [[ $output == *"just edge-rollout --replace --edge 2 --other-down"* ]]
    grep -qx 'edge-check --edge 1' "$RECORD/argv"
    absent '^tofu .* apply ' "$RECORD/argv"
    [ "$(recorded 2)" = "$original_2" ]
  done

  # Once edge 1 serves, the plan is applied, after edge 1's check.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  instance_plan 2 '["delete", "create"]'
  : > "$RECORD/argv"
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge --yes < /dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(sequence | grep -v '^plan$')" = "$(printf '%s\n' 'check 1' 'forget 2' 'apply')" ]

  # A plan that only creates edge 2, gone from the cloud, takes nothing down and needs no check.
  edge_state 1 inactive "" "" 0
  instance_plan 2 '["create"]'
  : > "$RECORD/argv"
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge --yes < /dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  absent '^edge-check ' "$RECORD/argv"
}

@test "an edge whose instance a plan creates has its recorded host keys dropped, and new ones recorded" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  original_1=$(recorded 1)
  # Edge 2's instance is gone from the cloud: the refreshed plan creates it, and deletes nothing.
  instance_plan 2 '["create"]'
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge --yes < /dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(trail)" = "$(printf '%s\n' 'forget 2' 'apply')" ]
  [ "$(recorded 2)" = "" ]
  [ "$(recorded 1)" = "$original_1" ]
  [[ $output$'\n' == *$'\n'"edge 2's SSH host keys are no longer recorded; just edge-check --edge 2 checks the new ones against its instance's console and records them, asking for yes only when the console holds none"$'\n'* ]]
  # The stack's outputs name no instance here, so no console is read: the new instance's keys are
  # shown and recorded once yes is typed, and its check passes.
  run bash -c 'printf "yes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-check" --edge 2
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(recorded 2)" = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_2//./}Replacement" ]

  # The rollout does the same for an edge its plan only creates: the old keys go before the apply
  # and the new ones are recorded before the edge's check.
  original_keys
  : > "$RECORD/argv"
  run bash -c 'printf "yes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(trail)" = "$(printf '%s\n' 'ssh 2' 'apply' 'ssh 1' 'ssh 1' 'forget 2' 'apply' 'scan 2' 'ssh 2')" ]
  [ "$(recorded 2)" = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_2//./}Replacement" ]
}

@test "destroying the edge stack drops the edges' recorded host keys" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  echo "198.51.100.200 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOfAnotherHost" >> "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  echo '{"resource_changes": []}' > "$BATS_TEST_TMPDIR/plan.json"
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-destroy" sto2/edge --yes < /dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(recorded 1)" = "" ]
  [ "$(recorded 2)" = "" ]
  grep -q '^198.51.100.200 ' "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  [[ $output == *"the edges' SSH host keys are no longer recorded"* ]]
  no_address "$output"
}

@test "edge-rollout --replace --edge replaces the one edge named, and with the other down only once that is typed back" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  echo '{"resource_changes": []}' > "$BATS_TEST_TMPDIR/plan.json"
  real_edge_check
  : > "$RECORD/argv"
  run bash -c 'printf "yes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --replace --edge 2 --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(sequence)" = "$(printf '%s\n' \
    'plan' \
    'check 1' \
    'plan -target=module.edge["2"] -target=openstack_networking_floatingip_associate_v2.edge["2"] -replace=module.edge["2"].openstack_compute_instance_v2.this' \
    'forget 2' 'apply' 'scan 2' 'check 2' \
    'plan')" ]
  absent 'edge\["1"\]' "$RECORD/argv"

  # Edge 1 is down as well: edge 2 is not replaced, and the run names the way to do it anyway.
  original_keys
  edge_state 1 inactive "" "" 0
  : > "$RECORD/argv"
  run bash -c 'printf "yes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --replace --edge 2 --yes
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"edge 1 does not pass its check, so edge 2 is not replaced"* ]]
  [[ $output == *"--other-down"* ]]
  absent '^tofu .* apply ' "$RECORD/argv"

  # --other-down asks for the sentence that names both edges, --yes or not; anything else stops it.
  : > "$RECORD/argv"
  run bash -c 'printf "yes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --replace --edge 2 --other-down --yes
  echo "$output"
  [ "$status" -ne 0 ]
  absent '^tofu .* apply ' "$RECORD/argv"
  [ "$(recorded 2)" = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${ADDRESS_2//./}Original" ]

  : > "$RECORD/argv"
  run bash -c 'printf "replace edge 2 with edge 1 down\nyes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --replace --edge 2 --other-down --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(sequence)" = "$(printf '%s\n' \
    'plan' \
    'check 1' \
    'plan -target=module.edge["2"] -target=openstack_networking_floatingip_associate_v2.edge["2"] -replace=module.edge["2"].openstack_compute_instance_v2.this' \
    'forget 2' 'apply' 'scan 2' 'check 2' \
    'plan')" ]

  # --other-down replaces one named edge only.
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --replace --other-down --yes < /dev/null
  [ "$status" -eq 2 ]
}

# answers_pipe LINE...: makes ANSWERS, a named pipe in the test's directory, with each LINE in it,
# written once by a writer that has ended, and opens it for reading on the descriptor answers. A
# recipe started with that descriptor as its standard input finds every answer waiting from its
# first prompt on, and the end of the input after the last.
answers_pipe() {
  mkfifo "$ANSWERS"
  printf '%s\n' "$@" > "$ANSWERS" &
  exec {answers}< "$ANSWERS"
  wait "$!"
}

# answers_file LINE...: the same with ANSWERS a file that holds each LINE.
answers_file() {
  printf '%s\n' "$@" > "$ANSWERS"
  exec {answers}< "$ANSWERS"
}

# answers_left: the lines of the answers that nothing read.
answers_left() {
  cat <&"$answers"
}

# other_edge_down: what a rollout that replaces edge 1 with --other-down meets when it asks four
# things. Edge 1 serves, and only a forced replacement replaces its instance. Edge 2 answers on SSH
# and serves nothing, and its host key is not recorded. Neither console holds fingerprints: that of
# edge 2's instance, and that of the instance edge 1 becomes, whose identifier it sets new to. The
# checks are the real edge-check, and every program the rollout and its checks start is a fake or
# recorded, so that each notes its name when the answers are its standard input; dirname is left
# out, as it runs before the scripts can keep their input, which they say where they run it.
other_edge_down() {
  local tool
  with_instances
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 inactive "" "" 0
  grep -v "^$ADDRESS_2 " "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts" > "$BATS_TEST_TMPDIR/known"
  cp "$BATS_TEST_TMPDIR/known" "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  echo '{"resource_changes": []}' > "$BATS_TEST_TMPDIR/plan.json"
  new=$(next_instance 1)
  early_console | set_console "$(current_instance 2)"
  early_console | set_console "$new"
  real_edge_check
  for tool in awk sort date sleep rm mkdir chmod head; do
    record "$tool"
  done
  : > "$RECORD/argv"
}

@test "A rollout answered through a pipe written before it started reads the stack's name, the sentence that names both edges and the yes for each host key" {
  local new
  other_edge_down
  answers_pipe 'sto2/edge' 'yes' 'replace edge 1 with edge 2 down' 'yes'

  run env "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --replace --edge 1 --other-down <&"$answers"
  echo "$output"
  other_edge_down_answered
}

@test "a rollout answered from a file written before it started reads each answer at its prompt, as through a pipe" {
  local new
  other_edge_down
  answers_file 'sto2/edge' 'yes' 'replace edge 1 with edge 2 down' 'yes'

  run env "${ENVIRONMENT[@]}" "$REPO/scripts/edge-rollout" --replace --edge 1 --other-down <&"$answers"
  echo "$output"
  other_edge_down_answered
}

@test "A plan that takes one edge down is applied on the stack's name read from a pipe, after the other edge's check" {
  real_edge_check
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  instance_plan 2 '["delete", "create"]'
  : > "$RECORD/argv"
  answers_pipe 'sto2/edge'

  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge <&"$answers"
  echo "$output"
  [ "$status" -eq 0 ]
  # Edge 1 is checked over its connection first, and the plan is applied once the name is read.
  [[ $output == *"checking that edge 1 serves before edge 2 is taken down"* ]]
  [[ $output == *"pass  lab-edge-1: 3 of 3 worker sessions are established"* ]]
  [[ $output == *"Type sto2/edge to apply it: sto2/edge applied"$'\n'* ]]
  [ "$(sequence | grep -v '^plan$')" = "$(printf '%s\n' 'check 1' 'forget 2' 'apply')" ]
  [ "$(recorded 2)" = "" ]
  # The check's ssh ran without the pipe as its standard input. infra-apply's own tofu had it, as
  # infra-apply keeps its standard input, and read nothing of it: the name was there for the prompt,
  # and nothing is left.
  grep -q "^ssh .*@$ADDRESS_1 " "$RECORD/argv"
  grep -qx tofu "$RECORD/had-answers"
  absent -x ssh "$RECORD/had-answers"
  [ -z "$(answers_left)" ]
  no_address "$output"
}

# closed_input SCRIPT [ARG...]: runs SCRIPT of the copy, in the environment above, with its standard
# input closed as it starts, by the shell that starts it: a descriptor closed earlier would be the
# next one that shell opens. A run that waited for an answer would be ended after a minute.
closed_input() {
  # shellcheck disable=SC2016 # "$@" is the inner shell's.
  run timeout 60 bash -c 'exec "$@" <&-' _ env "${ENVIRONMENT[@]}" "$REPO/scripts/$1" "${@:2}"
}

@test "a check, a rollout or an apply started with its standard input closed runs, and takes the end of the input for an answer" {
  with_instances
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  # Nothing to ask: the check of both edges runs as it does with an input.
  closed_input edge-check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"pass  lab-edge-2: the SSH daemon runs with the settings the first boot wrote"* ]]
  [[ $output != *FAIL* && $output != *"Bad file descriptor"* ]]

  # A host key the console does not vouch for is asked about, and the empty answer declines it.
  grep -v "^$ADDRESS_1 " "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts" > "$BATS_TEST_TMPDIR/known"
  cp "$BATS_TEST_TMPDIR/known" "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  early_console | set_console "$(current_instance 1)"
  : > "$RECORD/argv"
  closed_input edge-check --edge 1
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"Type yes to record them and connect: edge-check: the host key was not accepted; nothing was done on the host"* ]]
  [[ $output != *"Bad file descriptor"* ]]
  [ "$(recorded 1)" = "" ]
  absent "^ssh .*@$ADDRESS_1 " "$RECORD/argv"

  # The rollout's first question, the stack's name, the same.
  original_keys
  plan_replacing 1
  : > "$RECORD/argv"
  closed_input edge-rollout
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"Type sto2/edge to roll out it: edge-rollout: sto2/edge was not confirmed and is not rolled out"* ]]
  [[ $output != *"Bad file descriptor"* ]]
  absent -E '^(ssh|tofu .* apply) ' "$RECORD/argv"

  # infra-apply keeps its standard input as it is, closed here, and the check it runs first takes
  # it so: a plan that takes edge 2 down is applied once edge 1 passes.
  instance_plan 2 '["delete", "create"]'
  : > "$RECORD/argv"
  closed_input infra-apply sto2/edge --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(trail)" = "$(printf '%s\n' 'ssh 1' 'forget 2' 'apply')" ]
  [[ $output == *"pass  lab-edge-1: 3 of 3 worker sessions are established"* ]]
  [[ $output != *"Bad file descriptor"* ]]
}

@test "applying a plan that replaces one edge drops its recorded host keys and no other edge's" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  plan_replacing 2
  original_1=$(recorded 1)
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge --yes
  echo "$output"
  [ "$status" -eq 0 ]
  # Edge 1 is checked over its connection first, as the plan takes edge 2 down.
  [ "$(trail)" = "$(printf '%s\n' 'ssh 1' 'forget 2' 'apply')" ]
  [ "$(recorded 2)" = "" ]
  [ "$(recorded 1)" = "$original_1" ]
  no_address "$output"

  # Deleting both instances outright leaves none serving as much as replacing both does.
  plan_replacing 1 2
  jq '.resource_changes[].change.actions = ["delete"]' "$BATS_TEST_TMPDIR/plan.json" > "$BATS_TEST_TMPDIR/plan.tmp"
  mv "$BATS_TEST_TMPDIR/plan.tmp" "$BATS_TEST_TMPDIR/plan.json"
  : > "$RECORD/argv"
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/infra-apply" sto2/edge --yes
  [ "$status" -ne 0 ]
  [[ $output == *"both edge routers"* ]]
  absent ' apply ' "$RECORD/argv"
}

@test "the edge key is made once, at the path .env names, mode 0600, and nothing but that is printed" {
  rm "$KEY" "$KEY.pub"
  # An ssh-keygen that makes the two files, as the real one does, and records its arguments.
  fake ssh-keygen << EOF
printf '%s\n' "ssh-keygen \$*" >> "$RECORD/argv"
file=\${*: -1}
printf 'fixture private key\n' > "\$file"
chmod 600 "\$file"
printf 'ssh-ed25519 fixture\n' > "\$file.pub"
EOF
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/edge-ssh-key"
  [ "$status" -eq 0 ]
  [ "$output" = "created the edge routers' SSH key pair" ]
  [ "$(stat -c %a "$KEY")" = 600 ]
  [ "$(grep -c '^ssh-keygen ' "$RECORD/argv")" -eq 1 ]

  run env "${ENVIRONMENT[@]}" "$REPO/scripts/edge-ssh-key"
  [ "$status" -eq 0 ]
  [ "$output" = "the edge routers' SSH key pair exists; nothing was created" ]
  [ "$(grep -c '^ssh-keygen ' "$RECORD/argv")" -eq 1 ]

  # A relative path is refused, and so is a name that is not set.
  run env "${ENVIRONMENT[@]}" EDGE_SSH_KEY_FILE=relative/key "$REPO/scripts/edge-ssh-key"
  [ "$status" -ne 0 ]
  run env "${ENVIRONMENT[@]}" EDGE_SSH_KEY_FILE= "$REPO/scripts/edge-ssh-key"
  [ "$status" -ne 0 ]
  [[ $output == *EDGE_SSH_KEY_FILE* ]]
}

@test "edge-routes prints to a terminal only" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  # Not a terminal: standard output is the pipe bats captures.
  run env "${ENVIRONMENT[@]}" "$REPO/scripts/edge-routes"
  [ "$status" -ne 0 ]
  [[ $output == *"not a terminal"* ]]
  # CI set: refused whatever standard output is.
  run env "${ENVIRONMENT[@]}" CI=true "$REPO/scripts/edge-routes"
  [ "$status" -ne 0 ]
  [[ $output == *"CI is set"* ]]
  absent '^ssh ' "$RECORD/argv"
}

@test "the edge stack's public ports default to the cluster stack's service ports" {
  # The workers admit the service ports from the edges, and the edges' proxies serve the public ports.
  edge=$(yq -p hcl -o json "$ROOT/infra/openstack/stacks/sto2/edge/variables.tf" | jq -c '.variable.public_ports.default')
  cluster=$(yq -p hcl -o json "$ROOT/infra/openstack/stacks/sto2/cluster/variables.tf" | jq -c '.variable.service_ports.default')
  [ "$edge" = "$cluster" ]
}

@test "the edge stack's workers' block starts where the cluster stack numbers its workers" {
  # The edges take BGP sessions from the block that starts at the first worker's host number; the
  # cluster stack puts its workers there, through its nodes module, which has no default of its own.
  # One TF_VAR_worker_first_host sets both.
  edge=$(yq -p hcl -o json "$ROOT/infra/openstack/stacks/sto2/edge/variables.tf" | jq -c '.variable.worker_first_host.default')
  cluster=$(yq -p hcl -o json "$ROOT/infra/openstack/stacks/sto2/cluster/variables.tf" | jq -c '.variable.worker_first_host.default')
  module=$(yq -p hcl -o json "$ROOT/infra/openstack/modules/talos-nodes/variables.tf" | jq -c '.variable.worker_first_host.default')
  [ "$module" = null ]
  [[ $cluster =~ ^[0-9]+$ ]]
  [ "$edge" = "$cluster" ]
}

# first_boot [OS_RELEASE]: the edge stack's first-boot script, run here with the edge's file system
# under EDGE_ROOT, a directory of the test's, and fakes of the system's commands first on PATH, on an
# image of the release OS_RELEASE names, trixie by default. The fake vtysh's dry run refuses a file
# with a command FRR does not have, as FRR's does (tests/fixtures/edge-policy/proof.sh checks that of
# FRR's own); the fake systemctl fails to restart FRR when the file restart-fails says so, and the
# proxy when proxy-restart-fails does; the fake ip shows the kernel's unreachable route for the
# service range once FRR is restarted; the fake sshd's check refuses a configuration with a keyword
# the daemon does not have, in any file of the drop-in directory, as the fake haproxy's does in the
# proxy's file.
first_boot() {
  local root="$BATS_TEST_TMPDIR/edge-root" bin="$BATS_TEST_TMPDIR/edge-bin" tool
  mkdir -p "$root/etc/edge" "$root/etc/sysctl.d" "$root/etc/apt/apt.conf.d" "$root/etc/haproxy" "$root/dev" "$root/var/log" "$bin"
  printf 'PRETTY_NAME="Debian GNU/Linux"\nVERSION_CODENAME=%s\n' "${1:-trixie}" > "$root/etc/os-release"
  # A console that cannot be written, when the test asks for one: a directory in its place.
  rm -rf "$root/dev/console"
  if [[ -f "$BATS_TEST_TMPDIR/console-unwritable" ]]; then
    mkdir "$root/dev/console"
  else
    : > "$root/dev/console"
  fi
  for tool in apt-get sysctl nft sleep; do
    cat > "$bin/$tool" << EOF
#!/usr/bin/env bash
printf '%s\n' "$tool \$*" >> "$RECORD/argv"
EOF
  done
  cat > "$bin/systemctl" << EOF
#!/usr/bin/env bash
printf '%s\n' "systemctl \$*" >> "$RECORD/argv"
[[ "\$*" != 'restart frr' || ! -f "$BATS_TEST_TMPDIR/restart-fails" ]] || exit 1
[[ "\$*" != 'restart frr' ]] || touch "$BATS_TEST_TMPDIR/frr-restarted"
[[ "\$*" != 'restart haproxy' || ! -f "$BATS_TEST_TMPDIR/proxy-restart-fails" ]] || exit 1
EOF
  cat > "$bin/haproxy" << EOF
#!/usr/bin/env bash
printf '%s\n' "haproxy \$*" >> "$RECORD/argv"
[[ \$* == "-c -q -f $root/etc/edge/haproxy.cfg" ]] || { echo "fake haproxy: unexpected \$*" >&2; exit 1; }
if grep -qx '    no-such-keyword' "$root/etc/edge/haproxy.cfg"; then
  echo "[ALERT] (1) : config : parsing [$root/etc/edge/haproxy.cfg:3] : unknown keyword 'no-such-keyword' in 'defaults' section"
  exit 1
fi
EOF
  cat > "$bin/ip" << EOF
#!/usr/bin/env bash
printf '%s\n' "ip \$*" >> "$RECORD/argv"
[[ ! -f "$BATS_TEST_TMPDIR/frr-restarted" ]] || echo "unreachable 203.0.113.16/28 proto static metric 20"
EOF
  cat > "$bin/install" << EOF
#!/usr/bin/env bash
printf '%s\n' "install \$*" >> "$RECORD/argv"
mkdir -p "\$(dirname "\${*: -1}")"
cp "\${@: -2:1}" "\${*: -1}"
EOF
  cat > "$bin/sshd" << EOF
#!/usr/bin/env bash
printf '%s\n' "sshd \$*" >> "$RECORD/argv"
# The whole configuration is what is validated, not a drop-in alone.
[[ \$* == "-t -f $root/etc/ssh/sshd_config" ]] || { echo "fake sshd: unexpected \$*" >&2; exit 1; }
if grep -qsx 'no-such-keyword.*' "$root"/etc/ssh/sshd_config.d/*.conf; then
  echo "line 3: Bad configuration option: no-such-keyword"
  exit 255
fi
EOF
  cat > "$bin/vtysh" << EOF
#!/usr/bin/env bash
printf '%s\n' "vtysh \$*" >> "$RECORD/argv"
if [[ \$1 == -C ]] && grep -qx 'no-such-command' "\$3"; then
  echo "line 2: % Unknown command: no-such-command"
  exit 2
fi
EOF
  chmod +x "$bin"/*
  rm -f "$BATS_TEST_TMPDIR/frr-restarted"
  : > "$RECORD/argv"
  run env EDGE_ROOT="$root" PATH="$bin:$PATH" bash "$ROOT/infra/openstack/stacks/sto2/edge/first-boot.sh"
}

# edge_files: the files cloud-init writes under /etc/edge, FRR's naming the service range.
edge_files() {
  local root="$BATS_TEST_TMPDIR/edge-root" file
  mkdir -p "$root/etc/edge"
  for file in daemons nftables.conf sysctl.conf; do
    echo "fixture $file" > "$root/etc/edge/$file"
  done
  printf 'global\n    maxconn 4000\n' > "$root/etc/edge/haproxy.cfg"
  printf '[Service]\nUser=haproxy\n' > "$root/etc/edge/haproxy-unit.conf"
  cp "$ROOT/infra/openstack/stacks/sto2/edge/sshd.conf" "$root/etc/edge/sshd.conf"
  printf 'router bgp 64497\nexit\nip route 203.0.113.16/28 reject\n' > "$root/etc/edge/frr.conf"
}

# first_line PATTERN: the number of the first line of the record that matches PATTERN, 0 for none.
first_line() {
  grep -nE "$1" "$RECORD/argv" | head -1 | cut -d: -f1 | grep . || echo 0
}

# disarmed: what a failed first boot leaves: forwarding off now and at the next boot, and FRR and the
# proxy stopped and kept from starting at the next boot.
disarmed() {
  local root="$BATS_TEST_TMPDIR/edge-root"
  [ ! -e "$root/etc/sysctl.d/90-edge.conf" ]
  grep -qx 'sysctl -q -w net.ipv4.ip_forward=0' "$RECORD/argv"
  grep -qx 'systemctl disable --now frr' "$RECORD/argv"
  grep -qx 'systemctl disable --now haproxy' "$RECORD/argv"
}

@test "the first boot starts FRR only once FRR's dry run accepts its file, and fails saying why otherwise" {
  local root="$BATS_TEST_TMPDIR/edge-root"
  edge_files
  first_boot
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"edge-first-boot: done"* ]]
  # Both files are checked as cloud-init wrote them, before anything of theirs is installed under
  # /etc; FRR is restarted only after that, with the file that was checked.
  [ "$(first_line "^nft --check --file $root/etc/edge/nftables.conf\$")" -gt 0 ]
  [ "$(first_line "^vtysh -C -f $root/etc/edge/frr.conf\$")" -gt 0 ]
  [ "$(first_line "^nft --check")" -lt "$(first_line '^install ')" ]
  [ "$(first_line "^vtysh -C")" -lt "$(first_line '^install ')" ]
  [ "$(first_line '^install ')" -lt "$(first_line '^systemctl restart frr$')" ]
  cmp "$root/etc/edge/frr.conf" "$root/etc/frr/frr.conf"

  # A file FRR refuses: the first boot fails, says why on the console and in the log, installs
  # nothing under /etc, and leaves FRR stopped and forwarding off.
  rm -rf "$root/etc/frr" "$root/etc/sysctl.d/90-edge.conf"
  printf 'router bgp 64497\nno-such-command\nexit\n' > "$root/etc/edge/frr.conf"
  first_boot
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"edge-first-boot: FRR's dry run refuses /etc/edge/frr.conf"* ]]
  [[ $output == *"Unknown command: no-such-command"* ]]
  grep -q "FRR's dry run refuses /etc/edge/frr.conf" "$root/dev/console"
  grep -q "FRR's dry run refuses /etc/edge/frr.conf" "$root/var/log/edge-first-boot.log"
  [ ! -e "$root/etc/frr/frr.conf" ]
  absent '^install ' "$RECORD/argv"
  absent -E '^systemctl (enable|restart) frr' "$RECORD/argv"
  disarmed
}

@test "the first boot turns forwarding on last, once FRR answers and the reject route is in the kernel" {
  local root="$BATS_TEST_TMPDIR/edge-root"
  edge_files
  first_boot
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$root/etc/sysctl.d/90-edge.conf" ]
  forwarding=$(first_line '^sysctl --system$')
  [ "$forwarding" -gt "$(first_line '^systemctl restart nftables$')" ]
  [ "$forwarding" -gt "$(first_line "^vtysh -c show bgp summary\$")" ]
  [ "$forwarding" -gt "$(first_line '^ip -4 route show exact 203.0.113.16/28 type unreachable$')" ]
  [ "$forwarding" -gt "$(first_line '^nft list table inet edge$')" ]
  absent 'edge-nat' "$RECORD/argv"
  [ "$forwarding" -gt "$(first_line '^systemctl restart haproxy$')" ]
  # The forwarding setting is installed with it, and not before.
  [ "$(first_line "^install -m 0644 $root/etc/edge/sysctl.conf ")" -gt "$(first_line '^systemctl restart frr$')" ]

  # FRR fails to restart: the trap leaves forwarding off, its setting gone, and FRR stopped.
  touch "$BATS_TEST_TMPDIR/restart-fails"
  rm -f "$root/etc/sysctl.d/90-edge.conf"
  first_boot
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"edge-first-boot: FAILED at line"* ]]
  absent '^sysctl --system$' "$RECORD/argv"
  disarmed
}

@test "the first boot starts the proxy as its own unit only once its configuration passes the proxy's own check, and fails saying why otherwise" {
  local root="$BATS_TEST_TMPDIR/edge-root"
  edge_files
  first_boot
  echo "$output"
  [ "$status" -eq 0 ]
  # The package comes from the image's repositories with FRR's and nftables', and stops running with
  # its own defaults at once, as FRR does; the file is checked as cloud-init wrote it, then installed
  # with the unit's settings, which systemd reads before the proxy starts, and it is enabled.
  grep -Eq '^apt-get .* install .*\bhaproxy\b' "$RECORD/argv"
  [ "$(first_line '^systemctl stop haproxy$')" -gt "$(first_line '^apt-get .* install ')" ]
  [ "$(first_line "^haproxy -c -q -f $root/etc/edge/haproxy.cfg\$")" -gt 0 ]
  [ "$(first_line "^haproxy -c")" -lt "$(first_line '^install ')" ]
  cmp "$root/etc/edge/haproxy.cfg" "$root/etc/haproxy/haproxy.cfg"
  cmp "$root/etc/edge/haproxy-unit.conf" "$root/etc/systemd/system/haproxy.service.d/10-edge.conf"
  [ "$(first_line '^systemctl daemon-reload$')" -lt "$(first_line '^systemctl restart haproxy$')" ]
  [ "$(first_line '^systemctl enable haproxy$')" -gt 0 ]
  # It starts once the rules are loaded and FRR answers: a proxy with no route to the Gateway fails
  # connections at once, and the rules are what keep that from leaving by the default route.
  [ "$(first_line '^systemctl restart haproxy$')" -gt "$(first_line '^systemctl restart nftables$')" ]
  [ "$(first_line '^systemctl restart haproxy$')" -gt "$(first_line "^vtysh -c show bgp summary\$")" ]
  [ "$(first_line '^systemctl is-active --quiet haproxy$')" -gt "$(first_line '^systemctl restart haproxy$')" ]

  # A file the proxy refuses: the first boot fails, says why on the console and in the log, installs
  # nothing of the proxy's, and leaves it stopped.
  rm -rf "$root/etc/haproxy/haproxy.cfg" "$root/etc/systemd" "$root/etc/sysctl.d/90-edge.conf"
  printf 'global\n    maxconn 4000\n    no-such-keyword\n' > "$root/etc/edge/haproxy.cfg"
  first_boot
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"edge-first-boot: the proxy refuses /etc/edge/haproxy.cfg"* ]]
  [[ $output == *"unknown keyword 'no-such-keyword'"* ]]
  grep -q "the proxy refuses /etc/edge/haproxy.cfg" "$root/dev/console"
  grep -q "the proxy refuses /etc/edge/haproxy.cfg" "$root/var/log/edge-first-boot.log"
  [ ! -e "$root/etc/haproxy/haproxy.cfg" ]
  absent -E '^systemctl (enable|restart) haproxy' "$RECORD/argv"
  disarmed

  # A proxy that does not start leaves the edge disarmed as well.
  edge_files
  touch "$BATS_TEST_TMPDIR/proxy-restart-fails"
  first_boot
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"edge-first-boot: FAILED at line"* ]]
  absent '^sysctl --system$' "$RECORD/argv"
  disarmed
}

@test "a failed first boot leaves the edge disarmed even when the console cannot be written" {
  local root="$BATS_TEST_TMPDIR/edge-root"
  edge_files
  touch "$BATS_TEST_TMPDIR/console-unwritable"
  # FRR's dry run refuses the file.
  printf 'router bgp 64497\nno-such-command\nexit\n' > "$root/etc/edge/frr.conf"
  first_boot
  echo "$output"
  [ "$status" -ne 0 ]
  disarmed
  # FRR does not restart.
  edge_files
  touch "$BATS_TEST_TMPDIR/restart-fails"
  first_boot
  echo "$output"
  [ "$status" -ne 0 ]
  disarmed
}

@test "the first boot installs nothing on an image of another release" {
  edge_files
  first_boot bookworm
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"written for Debian trixie"* ]]
  absent -E '^(apt-get|install|systemctl) ' "$RECORD/argv"
}

@test "the first boot turns unattended upgrades off before it installs anything" {
  local root="$BATS_TEST_TMPDIR/edge-root"
  edge_files
  first_boot
  [ "$status" -eq 0 ]
  grep -qx 'APT::Periodic::Unattended-Upgrade "0";' "$root/etc/apt/apt.conf.d/99edge-no-unattended-upgrades"
  [ "$(first_line '^systemctl disable --now apt-daily-upgrade.timer$')" -gt 0 ]
  [ "$(first_line '^systemctl disable --now apt-daily-upgrade.timer$')" -lt "$(first_line '^apt-get ')" ]
  # apt waits for a lock another apt run holds at first boot, instead of failing at once.
  grep -q '^apt-get .*-o DPkg::Lock::Timeout=' "$RECORD/argv"
}

# image_ssh_config: what an image's SSH daemon is configured with: its main file includes the
# drop-in directory ahead of its own lines, as Debian's does, and sets its own key exchange, ciphers
# and MACs after it, and drop-ins on either side of the edge's name say what an image may ship, each
# against the edge's settings.
image_ssh_config() {
  local root="$BATS_TEST_TMPDIR/edge-root" dir="$BATS_TEST_TMPDIR/edge-root/etc/ssh/sshd_config.d"
  mkdir -p "$dir"
  {
    printf 'Include %s/*.conf\n' "$dir"
    printf 'KexAlgorithms diffie-hellman-group14-sha256,curve25519-sha256\n'
    printf 'Ciphers aes128-ctr,aes256-ctr\nMACs hmac-sha2-256,hmac-sha2-512\n'
    printf 'PasswordAuthentication yes\nKbdInteractiveAuthentication yes\n'
  } > "$root/etc/ssh/sshd_config"
  printf 'KexAlgorithms curve25519-sha256@libssh.org\nAuthenticationMethods password\n' > "$dir/10-image.conf"
  printf 'PasswordAuthentication yes\nPermitRootLogin yes\nAllowTcpForwarding yes\nAllowAgentForwarding yes\nX11Forwarding yes\nPermitTunnel yes\n' > "$dir/50-cloud-init.conf"
}

# effective ROOT: what the machine's OpenSSH server reports for the configuration under ROOT, one
# keyword and its value per line; fails, with the daemon's error on standard error, when the daemon
# refuses the configuration.
effective() {
  [[ -f $BATS_TEST_TMPDIR/ssh-host-key ]] || ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/ssh-host-key"
  sshd -T -f "$1/etc/ssh/sshd_config" -h "$BATS_TEST_TMPDIR/ssh-host-key"
}

@test "The first boot gives the SSH daemon the settings the tree holds, and they win over the image's" {
  local root="$BATS_TEST_TMPDIR/edge-root" dir="$BATS_TEST_TMPDIR/edge-root/etc/ssh/sshd_config.d" tree line names
  tree=$ROOT/infra/openstack/stacks/sto2/edge/sshd.conf
  edge_files
  image_ssh_config
  first_boot
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"edge-first-boot: done"* ]]

  # The settings the tree holds are in a drop-in, as written, validated before the daemon reloads.
  cmp "$tree" "$dir/00-edge.conf"
  [ "$(first_line "^install -m 0644 $root/etc/edge/sshd.conf $root/etc/ssh/sshd_config.d/00-edge.conf\$")" -gt 0 ]
  [ "$(first_line '^sshd -t')" -gt "$(first_line "^install -m 0644 $root/etc/edge/sshd.conf ")" ]
  [ "$(first_line '^systemctl try-reload-or-restart ssh$')" -gt "$(first_line '^sshd -t')" ]
  # The tree's keywords are the ones the post-quantum hybrids, AEAD ciphers, encrypt-then-MAC MACs,
  # public keys and no forwarding need.
  grep -qx 'KexAlgorithms mlkem768x25519-sha256,sntrup761x25519-sha512,curve25519-sha256' "$tree"
  grep -qx 'Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com' "$tree"
  grep -qx 'MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com' "$tree"
  for line in 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PermitRootLogin no' \
    'AuthenticationMethods publickey' 'AllowTcpForwarding no' 'AllowAgentForwarding no' \
    'X11Forwarding no' 'PermitTunnel no'; do
    grep -qx "$line" "$tree"
  done
  absent -i '^AllowUsers' "$tree"

  # sshd reads the drop-ins in lexical order, ahead of the main file's own lines, and takes the first
  # value of a keyword: the edge's file is the first the glob names, in byte order.
  names=$(cd "$dir" && printf '%s\n' *.conf | LC_ALL=C sort | head -1)
  [ "$names" = 00-edge.conf ]

  # Where the machine has an OpenSSH server, the real daemon reads the configuration: settings it
  # refuses fail this test with its error, as they would fail the first boot on an edge.
  if type -P sshd ssh-keygen > /dev/null; then
    if ! effective "$root" > "$BATS_TEST_TMPDIR/effective"; then
      echo "sshd refuses the configuration with the tree's settings"
      return 1
    fi
    # The real daemon's effective settings are the tree's, against an image that says otherwise.
    awk '{ $1 = tolower($1) } 1' "$BATS_TEST_TMPDIR/effective" > "$BATS_TEST_TMPDIR/effective-lower"
    while read -r keyword value; do
      [[ -n $keyword && $keyword != '#'* ]] || continue
      grep -qxF "${keyword,,} $value" "$BATS_TEST_TMPDIR/effective-lower"
    done < "$tree"
    # And a drop-in that sorts after the image's loses to it, which is what the order decides.
    mv "$dir/00-edge.conf" "$dir/99-edge.conf"
    effective "$root" > "$BATS_TEST_TMPDIR/effective-late"
    grep -qix 'passwordauthentication yes' "$BATS_TEST_TMPDIR/effective-late"
    mv "$dir/99-edge.conf" "$dir/00-edge.conf"
  else
    echo "not proved here: no sshd on this machine, so the order of Include and first value wins is not run through sshd -T; only that the file's name sorts first is"
  fi
}

@test "A daemon configuration that does not validate fails the first boot" {
  local root="$BATS_TEST_TMPDIR/edge-root"
  edge_files
  printf 'no-such-keyword yes\n' >> "$root/etc/edge/sshd.conf"
  first_boot
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"edge-first-boot: sshd refuses the settings in /etc/edge/sshd.conf"* ]]
  [[ $output == *"Bad configuration option: no-such-keyword"* ]]
  grep -q "sshd refuses the settings in /etc/edge/sshd.conf" "$root/dev/console"
  grep -q "sshd refuses the settings in /etc/edge/sshd.conf" "$root/var/log/edge-first-boot.log"
  # Nothing the daemon would refuse at its next start is left in its configuration, it is not told to
  # read one, and nothing after is started.
  [ ! -e "$root/etc/ssh/sshd_config.d/00-edge.conf" ]
  absent -E '^systemctl (try-reload-or-restart|reload|restart) ssh' "$RECORD/argv"
  absent -E '^systemctl (enable|restart) frr' "$RECORD/argv"
  disarmed
}

# fingerprint KEY: what the fake ssh-keygen prints as the fingerprint of the key text KEY.
fingerprint() {
  printf 'SHA256:%s' "$(printf %s "$1" | sha256sum | cut -c1-43)"
}

# replacement_key NUMBER: the key edge NUMBER offers once its instance is created again.
replacement_key() {
  local address=$ADDRESS_1
  [[ $1 == 1 ]] || address=$ADDRESS_2
  echo "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKeyOf${address//./}Replacement"
}

# rsa_key NUMBER: the second key edge NUMBER's address offers when the test gives it one.
rsa_key() {
  local address=$ADDRESS_1
  [[ $1 == 1 ]] || address=$ADDRESS_2
  echo "AAAAB3NzaC1yc2EAAAADAQABAAABgQFixtureRsaKeyOf${address//./}"
}

# cloud_init_line TEXT: a line as cloud-init's tools/write-ssh-key-fingerprints sends it to the
# console, through `logger -s -p user.info -t cloud-init --`, which puts a syslog header on it.
cloud_init_line() {
  printf '<14>Nov 15 09:42:08 cloud-init: %s\n' "$1"
}

# console_block FINGERPRINT...: what cloud-init prints on the console at the end of a first boot.
console_block() {
  local fingerprint
  echo "Cloud-init v. 22.4.2 running 'modules:final' at Mon, 01 Jan 2024 00:00:09 +0000. Up 9.9 seconds."
  cloud_init_line '#############################################################'
  cloud_init_line '-----BEGIN SSH HOST KEY FINGERPRINTS-----'
  for fingerprint; do
    cloud_init_line "256 $fingerprint root@lab-edge (ED25519)"
  done
  cloud_init_line '-----END SSH HOST KEY FINGERPRINTS-----'
  cloud_init_line '#############################################################'
}

# with_instances: the stack's outputs name each edge's instance, as an applied stack's do; without
# it they do not, and the recipes cannot read a console.
with_instances() {
  jq --arg one "$INSTANCE_1" --arg two "$INSTANCE_2" '.instances = {sensitive: true, value: {
    "1": {id: $one, name: "lab-edge-1"}, "2": {id: $two, name: "lab-edge-2"}}}' \
    "$BATS_TEST_TMPDIR/outputs.json" > "$BATS_TEST_TMPDIR/outputs.with"
  mv "$BATS_TEST_TMPDIR/outputs.with" "$BATS_TEST_TMPDIR/outputs.json"
}

# early_console: a console whose first boot has not printed its keys yet.
early_console() {
  echo "Cloud-init v. 22.4.2 running 'init' at Mon, 01 Jan 2024 00:00:03 +0000. Up 3.9 seconds."
}

# instance_id NUMBER GENERATION: the identifier of edge NUMBER's instance once an apply has created
# it GENERATION times, as the fake tofu gives it; generation 0 is the one with_instances writes.
instance_id() {
  local id=$INSTANCE_1
  [[ $1 == 1 ]] || id=$INSTANCE_2
  if (($2 == 0)); then
    echo "$id"
  else
    printf '%s%04x\n' "${id:0:32}" "$2"
  fi
}

# current_instance NUMBER: the identifier the stack's outputs give edge NUMBER's instance now.
current_instance() {
  jq -r --arg number "$1" '.instances.value[$number].id' "$BATS_TEST_TMPDIR/outputs.json"
}

# next_instance NUMBER: the identifier of the instance the next apply that creates edge NUMBER's
# makes.
next_instance() {
  instance_id "$1" "$(($(cat "$RECORD/generation-$1" 2> /dev/null || echo 0) + 1))"
}

# set_console ID [READ]: the console of the instance ID, the text on standard input; for its READth
# read of the console only, when READ is given.
set_console() {
  local suffix=
  [[ -z ${2-} ]] || suffix=.$2
  cat > "$HOST/console-$1$suffix"
}

# console_reads ID: how many times the console of the instance ID was read.
console_reads() {
  cat "$RECORD/reads-$1" 2> /dev/null || echo 0
}

# crlf FILE: FILE with each line ended by CR LF, as a serial console's terminal writes a line.
crlf() {
  sed -i 's/$/\r/' "$1"
}

# fake_clock: date +%s reads a clock of the test's own, which sleep moves on instead of waiting,
# recording each sleep, as in tests/cluster-recipes.bats; with a number in the file clock-answers in
# the record's directory, date answers that many times and then gives no number. A run that sleeps
# more than 100 times is waiting for a time the clock does not reach, and is stopped.
fake_clock() {
  echo 1800000000 > "$RECORD/clock"
  rm -f "$RECORD/clock-answers"
  fake date << EOF
if [[ \$* == +%s ]]; then
  if [[ -f "$RECORD/clock-answers" ]]; then
    answers=\$(cat "$RECORD/clock-answers")
    if ((answers <= 0)); then
      echo 'no time'
      exit 0
    fi
    echo \$((answers - 1)) > "$RECORD/clock-answers"
  fi
  cat "$RECORD/clock"
  exit 0
fi
exec "$(type -P date)" "\$@"
EOF
  fake sleep << EOF
printf '%s\n' "sleep \$*" >> "$RECORD/argv"
echo \$((\$(cat "$RECORD/clock") + \${1%%[!0-9]*})) > "$RECORD/clock"
if (("\$(grep -c '^sleep ' "$RECORD/argv")" > 100)); then
  echo "fake sleep: a wait the clock does not end" >&2
  kill -TERM "\$PPID"
fi
EOF
}

# clock_moved: how many seconds the fake clock moved on since it was set.
clock_moved() {
  echo $(($(cat "$RECORD/clock") - 1800000000))
}

# fixture_fingerprint NAME: the fingerprint tests/fixtures/console's logs print under NAME.
fixture_fingerprint() {
  local s=$1
  while ((${#s} < 43)); do s+=A; done
  printf 'SHA256:%s\n' "$s"
}

# rollout_with_input INPUT [NAME=VALUE...]: scripts/edge-rollout --yes in the copy, INPUT, which
# printf reads as a format, typed, and the NAME=VALUE pairs added to its environment.
rollout_with_input() {
  local input=$1
  shift
  run bash -c 'printf "$1" | { shift; env "$@"; }' _ "$input" "${ENVIRONMENT[@]}" "$@" "$REPO/scripts/edge-rollout" --yes
}

@test "A new edge whose offered keys are all on its console is trusted without a prompt" {
  local number new_1 new_2
  with_instances
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  plan_replacing 1 2
  new_1=$(next_instance 1) new_2=$(next_instance 2)
  # The instances before the rollout printed the keys they had. Each replacement is a new server
  # with an identifier of its own, which the stack's outputs give once it is applied, and whose
  # address offers a second key as well; it printed both. Edge 2's console ends its lines with
  # CR LF, as a serial console's terminal writes them.
  for number in 1 2; do
    console_block "$(fingerprint "$(cat "$HOST/key-$(address_of "$number")")")" | set_console "$(current_instance "$number")"
    rsa_key "$number" > "$HOST/key-$(address_of "$number").rsa"
    console_block "$(fingerprint "$(replacement_key "$number")")" "$(fingerprint "$(rsa_key "$number")")" | set_console "$(next_instance "$number")"
  done
  crlf "$HOST/console-$new_2"
  : > "$RECORD/argv"

  # Nothing is typed: a prompt would read the end of the input and decline.
  rollout_with_input ''
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(recorded 1 | head -1)" = "$(replacement_key 1)" ]
  [ "$(recorded 2 | head -1)" = "$(replacement_key 2)" ]
  [ "$(grep -c "^$ADDRESS_1 " "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts")" -eq 2 ]
  [[ $output != *"Type yes"* ]]
  [[ $output == *"edge router lab-edge-1: the 2 SSH host keys it offers match its instance's console; recorded in "* ]]
  [[ $output == *"edge router lab-edge-2: the 2 SSH host keys it offers match its instance's console; recorded in "* ]]
  no_address "$output"
  # Each console was read through the client, by the identifier the stack's outputs give the new
  # instance, and the replaced instances' consoles were never read.
  [ "$(current_instance 1)" = "$new_1" ]
  [ "$(current_instance 2)" = "$new_2" ]
  grep -qx "openstack console log show --lines 1000 $new_1" "$RECORD/argv"
  grep -qx "openstack console log show --lines 1000 $new_2" "$RECORD/argv"
  absent -E "^openstack console log show .*($INSTANCE_1|$INSTANCE_2)\$" "$RECORD/argv"
  absent -E "^openstack .*$ADDRESS_1" "$RECORD/argv"
}

@test "a replaced edge whose outputs still name the instance it replaced is not read or recorded" {
  with_instances
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  plan_replacing 1 2
  # The apply creates edge 1's instance again, and the outputs read after it still give the old
  # one's identifier: they do not describe what the apply made.
  echo "$INSTANCE_1" > "$HOST/next-id-1"
  console_block "$(fingerprint "$(cat "$HOST/key-$ADDRESS_1")")" | set_console "$INSTANCE_1"
  : > "$RECORD/argv"
  rollout_with_input 'yes\nyes\n'
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"edge 1's instance was created again, but the stack's outputs still give the identifier of the one before it"* ]]
  [[ $output == *"when just infra-plan sto2/edge lists update: output instances and no other change, just infra-apply sto2/edge writes the outputs (a pending change to the other edge lists update: output instances as well); once just infra-plan sto2/edge lists no change to output instances, so the outputs name the new instance, just edge-check --edge 1 records its keys"* ]]
  [[ $output != *"Type yes"* ]]
  absent '^openstack console' "$RECORD/argv"
  absent '^ssh-keyscan ' "$RECORD/argv"
  [ "$(recorded 1)" = "" ]
  # The rollout stopped there.
  [ "$(grep -c '^tofu .* apply ' "$RECORD/argv")" -eq 1 ]
  absent 'module.edge\["2"\]' "$RECORD/argv"
  no_address "$output"

  # Edge 1's outputs follow its replacement, and edge 2's stay stale: edge 1's keys are recorded
  # from its new console, and the rollout stops at edge 2, its keys unread and unrecorded.
  original_keys
  plan_replacing 1 2
  rm "$HOST/next-id-1"
  current_instance 2 > "$HOST/next-id-2"
  console_block "$(fingerprint "$(replacement_key 1)")" | set_console "$(next_instance 1)"
  console_block "$(fingerprint "$(replacement_key 2)")" | set_console "$(current_instance 2)"
  : > "$RECORD/argv"
  rollout_with_input 'yes\nyes\n'
  echo "$output"
  [ "$status" -ne 0 ]
  [ "$(recorded 1)" = "$(replacement_key 1)" ]
  [[ $output == *"edge router lab-edge-1: the 1 SSH host key it offers matches its instance's console"* ]]
  [[ $output == *"edge 2's instance was created again, but the stack's outputs still give the identifier of the one before it"* ]]
  [[ $output == *"just edge-check --edge 2 records its keys"* ]]
  [[ $output != *"Type yes"* ]]
  [ "$(recorded 2)" = "" ]
  absent "^openstack console log show .* $(current_instance 2)\$" "$RECORD/argv"
  absent "^ssh-keyscan .*$ADDRESS_2\$" "$RECORD/argv"
  [ "$(grep -c '^tofu .* apply ' "$RECORD/argv")" -eq 2 ]
  no_address "$output"
}

# address_of NUMBER: the address of edge NUMBER.
address_of() {
  if [[ $1 == 1 ]]; then echo "$ADDRESS_1"; else echo "$ADDRESS_2"; fi
}

@test "An address that offers a key its instance did not print is refused, and nothing is recorded" {
  local variant new
  with_instances
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  # A refusal is final: the clock is a sleep that records the call and ends the rollout, so one that
  # read the console again under the default wait, 900 seconds, which the rollouts below have, would
  # show in the record.
  fake sleep << FAKE
printf '%s\n' "sleep \$*" >> "$RECORD/argv"
kill -TERM "\$PPID"
FAKE
  # Every key the address offers must be on the console, wherever in the offer the one that is not
  # stands: first, last, or between two that are, so a comparison of some of them by position
  # passes none of these.
  for variant in 'an unprinted key first' 'an unprinted key last' 'an unprinted key between two printed' 'other keys altogether'; do
    original_keys
    plan_replacing 1
    new=$(next_instance 1)
    rm -f "$HOST/key-$ADDRESS_1.before" "$HOST/key-$ADDRESS_1.rsa"
    case $variant in
      'an unprinted key first')
        rsa_key 1 > "$HOST/key-$ADDRESS_1.before"
        console_block "$(fingerprint "$(replacement_key 1)")" | set_console "$new"
        ;;
      'an unprinted key last')
        rsa_key 1 > "$HOST/key-$ADDRESS_1.rsa"
        console_block "$(fingerprint "$(replacement_key 1)")" | set_console "$new"
        ;;
      'an unprinted key between two printed')
        rsa_key 1 > "$HOST/key-$ADDRESS_1.before"
        echo "AAAAB3NzaC1yc2EAAAADAQABAAABgQFixtureThirdKeyOf${ADDRESS_1//./}" > "$HOST/key-$ADDRESS_1.rsa"
        console_block "$(fingerprint "$(rsa_key 1)")" \
          "$(fingerprint "AAAAB3NzaC1yc2EAAAADAQABAAABgQFixtureThirdKeyOf${ADDRESS_1//./}")" | set_console "$new"
        ;;
      *)
        console_block "$(fixture_fingerprint SomeoneElsesKeyEd25519)" | set_console "$new"
        ;;
    esac
    : > "$RECORD/argv"

    # The operator would say yes to anything, and --yes is given.
    rollout_with_input 'yes\nyes\nyes\n' EDGE_ROLLOUT_WAIT=900 EDGE_ROLLOUT_INTERVAL=15
    echo "$variant: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"offers a key its instance did not print"* ]]
    [[ $output != *"Type yes"* ]]
    [ "$(recorded 1)" = "" ]
    absent '^sleep ' "$RECORD/argv"
    [ "$(console_reads "$new")" -eq 1 ]
    absent "^ssh .*@$ADDRESS_1 " "$RECORD/argv"
    # The rollout stopped there.
    [ "$(grep -c '^tofu .* apply ' "$RECORD/argv")" -eq 1 ]
    absent 'module.edge\["2"\]' "$RECORD/argv"
    no_address "$output"
  done

  # A first connection through edge-check is refused the same way: the instance the outputs name
  # printed another key.
  original_keys
  grep -v "^$ADDRESS_1 " "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts" > "$BATS_TEST_TMPDIR/known"
  cp "$BATS_TEST_TMPDIR/known" "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  console_block "$(fixture_fingerprint SomeoneElsesKeyEd25519)" | set_console "$(current_instance 1)"
  : > "$RECORD/argv"
  run bash -c 'printf "yes\nyes\n" | env "$@"' _ "${ENVIRONMENT[@]}" "$REPO/scripts/edge-check" --edge 1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"offers a key its instance did not print"* ]]
  [[ $output != *"Type yes"* ]]
  [ "$(recorded 1)" = "" ]
  grep -qx "openstack console log show --lines 1000 $(current_instance 1)" "$RECORD/argv"
  absent "^ssh .*@$ADDRESS_1 " "$RECORD/argv"
  no_address "$output"
}

@test "A console that holds no fingerprints yet is waited for, and then the operator is asked" {
  local new
  with_instances
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  # The waits are on the test's clock: sleep moves it on, and the rollout's wait ends when it says.
  fake_clock
  plan_replacing 1
  new=$(next_instance 1)
  # The first boot prints its keys late: the console has none for the first read, and has them for
  # the second, one interval later.
  early_console | set_console "$new" 1
  console_block "$(fingerprint "$(replacement_key 1)")" | set_console "$new" 2
  : > "$RECORD/argv"
  rollout_with_input '' EDGE_ROLLOUT_WAIT=60 EDGE_ROLLOUT_INTERVAL=15
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(console_reads "$new")" -eq 2 ]
  [ "$(clock_moved)" -eq 15 ]
  [ "$(recorded 1)" = "$(replacement_key 1)" ]
  [[ $output != *"Type yes"* ]]
  [ "$(grep -c '^ssh-keyscan ' "$RECORD/argv")" -eq 1 ]

  # The client cannot read it at first, as the new instance is not found yet, and then can: it is
  # read again within the wait as well.
  original_keys
  fake_clock
  plan_replacing 1
  new=$(next_instance 1)
  console_block "$(fingerprint "$(replacement_key 1)")" | set_console "$new" 2
  : > "$RECORD/argv"
  rollout_with_input '' EDGE_ROLLOUT_WAIT=60 EDGE_ROLLOUT_INTERVAL=15
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(console_reads "$new")" -eq 2 ]
  [ "$(recorded 1)" = "$(replacement_key 1)" ]
  [[ $output != *"Type yes"* ]]

  # It never does: the wait the rollout has is spent on reading it, at the start and every interval
  # until the wait is over, and then the operator is asked, and told the console held no
  # fingerprints.
  original_keys
  fake_clock
  plan_replacing 1
  new=$(next_instance 1)
  early_console | set_console "$new"
  : > "$RECORD/argv"
  rollout_with_input 'yes\n' EDGE_ROLLOUT_WAIT=60 EDGE_ROLLOUT_INTERVAL=15
  echo "$output"
  [ "$status" -eq 0 ]
  echo "reads $(console_reads "$new"), clock moved $(clock_moved)s"
  [ "$(console_reads "$new")" -eq 5 ]
  [ "$(clock_moved)" -eq 60 ]
  [[ $output == *"The console of the edge router lab-edge-1's instance held no fingerprints, so the comparison is yours."* ]]
  [[ $output == *"Type yes to record them and connect"* ]]
  [ "$(recorded 1)" = "$(replacement_key 1)" ]

  # An answer that is not yes declines.
  original_keys
  plan_replacing 1
  rollout_with_input 'no\n' EDGE_ROLLOUT_WAIT=0
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"was not accepted"* ]]
  [ "$(recorded 1)" = "" ]

  # A console the client cannot read, as the instance is not found, is the same, and says so.
  original_keys
  plan_replacing 1
  rollout_with_input 'yes\n' EDGE_ROLLOUT_WAIT=0
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"could not be read"* ]]
  [[ $output == *"Type yes to record them and connect"* ]]
  [ "$(recorded 1)" = "$(replacement_key 1)" ]
  no_address "$output"
}

@test "the console is read within what is left of the rollout's wait, for 30 seconds outside it, and not again when the client cannot run" {
  local new
  with_instances
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  early_console | set_console "$(instance_id 1 1)"

  # The new instance answers on SSH one interval after the apply, so the console is read for the
  # rest of the wait: at 15, 30, 45 and 60 seconds, and the wait ends at 60, not an interval later.
  fake_clock
  plan_replacing 1
  echo 1 > "$HOST/silent-$ADDRESS_1"
  : > "$RECORD/argv"
  rollout_with_input 'yes\n' EDGE_ROLLOUT_WAIT=60 EDGE_ROLLOUT_INTERVAL=15
  echo "$output"
  [ "$status" -eq 0 ]
  echo "scans $(cat "$RECORD/scans-$ADDRESS_1"), reads $(console_reads "$(instance_id 1 1)"), clock moved $(clock_moved)s"
  [ "$(cat "$RECORD/scans-$ADDRESS_1")" -eq 2 ]
  [ "$(console_reads "$(instance_id 1 1)")" -eq 4 ]
  [ "$(clock_moved)" -eq 60 ]
  [[ $output == *"held no fingerprints"* ]]
  [ "$(recorded 1)" = "$(replacement_key 1)" ]
  rm "$HOST/silent-$ADDRESS_1"

  # A client older than the recipes need cannot read a console, which waiting does not change: no
  # read, no wait, and the operator is asked at once, told why.
  original_keys
  fake_clock
  plan_replacing 1
  new=$(next_instance 1)
  console_block "$(fingerprint "$(replacement_key 1)")" | set_console "$new"
  echo "openstack 6.5.0" > "$HOST/openstack-version"
  : > "$RECORD/argv"
  rollout_with_input 'yes\n' EDGE_ROLLOUT_WAIT=900 EDGE_ROLLOUT_INTERVAL=15
  echo "$output"
  [ "$status" -eq 0 ]
  absent '^openstack console' "$RECORD/argv"
  absent '^sleep ' "$RECORD/argv"
  [[ $output == *"python-openstackclient 7.0.0 or newer is needed"* ]]
  [[ $output == *"The console of the edge router lab-edge-1's instance was not read, so the comparison is yours."* ]]
  [ "$(recorded 1)" = "$(replacement_key 1)" ]
  rm "$HOST/openstack-version"

  # Outside a rollout, edge-check waits HOST_CONSOLE_WAIT seconds, 30 when unset, reading every 5.
  local environment=() entry current
  for entry in "${ENVIRONMENT[@]}"; do
    [[ $entry == HOST_CONSOLE_WAIT=* ]] || environment+=("$entry")
  done
  original_keys
  grep -v "^$ADDRESS_1 " "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts" > "$BATS_TEST_TMPDIR/known"
  cp "$BATS_TEST_TMPDIR/known" "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  current=$(current_instance 1)
  early_console | set_console "$current"
  fake_clock
  : > "$RECORD/argv"
  run bash -c 'printf "yes\n" | env "$@"' _ "${environment[@]}" "$REPO/scripts/edge-check" --edge 1
  echo "$output"
  [ "$status" -eq 0 ]
  echo "reads $(console_reads "$current"), clock moved $(clock_moved)s"
  [ "$(console_reads "$current")" -eq 7 ]
  [ "$(clock_moved)" -eq 30 ]
  [[ $output == *"held no fingerprints"* ]]
  [ "$(recorded 1)" = "$(cat "$HOST/key-$ADDRESS_1")" ]

  # A clock that gives no number cannot time a wait: the console is read once, and the operator is
  # asked, told why.
  grep -v "^$ADDRESS_1 " "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts" > "$BATS_TEST_TMPDIR/known"
  cp "$BATS_TEST_TMPDIR/known" "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  rm -f "$RECORD/reads-$current"
  fake_clock
  echo 'no time' > "$RECORD/clock"
  : > "$RECORD/argv"
  run bash -c 'printf "yes\n" | env "$@"' _ "${environment[@]}" "$REPO/scripts/edge-check" --edge 1
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(console_reads "$current")" -eq 1 ]
  absent '^sleep ' "$RECORD/argv"
  [[ $output == *"date +%s does not give the time, so the wait for the console cannot be timed"* ]]
  [[ $output == *"Type yes to record them and connect"* ]]

  # A clock that stops giving a number part-way ends the wait there: it answers at the start and
  # after the first read, and not after the second, so the console is read twice, with one sleep
  # between, and the operator is asked.
  grep -v "^$ADDRESS_1 " "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts" > "$BATS_TEST_TMPDIR/known"
  cp "$BATS_TEST_TMPDIR/known" "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  rm -f "$RECORD/reads-$current"
  fake_clock
  echo 2 > "$RECORD/clock-answers"
  : > "$RECORD/argv"
  run bash -c 'printf "yes\n" | env "$@"' _ "${environment[@]}" "$REPO/scripts/edge-check" --edge 1
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(console_reads "$current")" -eq 2 ]
  [ "$(grep -c '^sleep ' "$RECORD/argv")" -eq 1 ]
  [[ $output == *"date +%s does not give the time, so the wait for the console cannot be timed"* ]]
  [[ $output == *"held no fingerprints"* ]]
  [[ $output == *"Type yes to record them and connect"* ]]
  [ "$(recorded 1)" = "$(cat "$HOST/key-$ADDRESS_1")" ]
}

@test "the waits are read in base 10, and one that is not a whole number of at most 9 digits is refused, named, before anything runs" {
  local environment=() entry current row value reads moved wait interval name new
  with_instances
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  for entry in "${ENVIRONMENT[@]}"; do
    [[ $entry == HOST_CONSOLE_WAIT=* ]] || environment+=("$entry")
  done
  current=$(current_instance 1)
  early_console | set_console "$current"
  # forget_1: edge 1's key is not recorded, so edge-check reads its console.
  forget_1() {
    grep -v "^$ADDRESS_1 " "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts" > "$BATS_TEST_TMPDIR/known" || true
    cp "$BATS_TEST_TMPDIR/known" "$HOME_DIR/.local/state/k8s-gitops/edge.known_hosts"
  }

  # HOST_CONSOLE_WAIT=08 waits eight seconds, read every 5: at 0, 5 and 10. 012 waits twelve: at 0,
  # 5, 10 and 15, where octal's ten would stop at 10.
  for row in '08 3 10' '012 4 15'; do
    read -r value reads moved <<< "$row"
    forget_1
    rm -f "$RECORD/reads-$current"
    fake_clock
    : > "$RECORD/argv"
    run bash -c 'printf "yes\n" | env "$@"' _ "${environment[@]}" "HOST_CONSOLE_WAIT=$value" "$REPO/scripts/edge-check" --edge 1
    echo "HOST_CONSOLE_WAIT=$value: $output"
    [ "$status" -eq 0 ]
    [ "$(console_reads "$current")" -eq "$reads" ]
    [ "$(clock_moved)" -eq "$moved" ]
  done
  # Nine digits are a wait.
  forget_1
  console_block "$(fingerprint "$(cat "$HOST/key-$ADDRESS_1")")" | set_console "$current"
  run env "${environment[@]}" HOST_CONSOLE_WAIT=999999999 "$REPO/scripts/edge-check" --edge 1 < /dev/null
  echo "HOST_CONSOLE_WAIT=999999999: $output"
  [ "$status" -eq 0 ]
  [[ $output == *"match"*"its instance's console"* ]]

  # EDGE_ROLLOUT_WAIT=08 with EDGE_ROLLOUT_INTERVAL=04 reads the console at 0, 4 and 8; 010 with 02
  # at 0, 2, 4, 6, 8 and 10, where octal's eight would stop at 8.
  for row in '08 04 3 8' '010 02 6 10'; do
    read -r wait interval reads moved <<< "$row"
    original_keys
    fake_clock
    plan_replacing 1
    new=$(next_instance 1)
    early_console | set_console "$new"
    : > "$RECORD/argv"
    rollout_with_input 'yes\n' "EDGE_ROLLOUT_WAIT=$wait" "EDGE_ROLLOUT_INTERVAL=$interval"
    echo "EDGE_ROLLOUT_WAIT=$wait EDGE_ROLLOUT_INTERVAL=$interval: $output"
    [ "$status" -eq 0 ]
    [ "$(console_reads "$new")" -eq "$reads" ]
    [ "$(clock_moved)" -eq "$moved" ]
  done

  # Twenty digits, ten, a unit or a sign: refused, naming the variable, before the stack is touched,
  # its lock taken, an address scanned or a console read, by each recipe that connects to an edge.
  original_keys
  lock="$REPO/infra/openstack/stacks/sto2/edge/.terraform/infra.lock"
  for value in 12345678901234567890 1000000000 30s -5; do
    for name in HOST_CONSOLE_WAIT EDGE_ROLLOUT_WAIT EDGE_ROLLOUT_INTERVAL; do
      rm -f "$lock"
      : > "$RECORD/argv"
      rollout_with_input 'yes\n' "$name=$value"
      echo "edge-rollout, $name=$value: $output"
      [ "$status" -ne 0 ]
      [[ $output == *"$name is not a whole number of seconds of at most 9 digits"* ]]
      absent -E '^(tofu|ssh|ssh-keyscan|openstack) ' "$RECORD/argv"
      [ ! -e "$lock" ]
    done
    forget_1
    rm -f "$lock"
    : > "$RECORD/argv"
    run env "${environment[@]}" "HOST_CONSOLE_WAIT=$value" "$REPO/scripts/edge-check" --edge 1 < /dev/null
    echo "edge-check, HOST_CONSOLE_WAIT=$value: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"HOST_CONSOLE_WAIT is not a whole number of seconds of at most 9 digits"* ]]
    absent -E '^(tofu|ssh|ssh-keyscan|openstack) ' "$RECORD/argv"
    [ ! -e "$lock" ]
    # edge-routes prints to a terminal only, so it runs on one.
    rm -f "$lock"
    : > "$RECORD/argv"
    command=$(printf '%q ' env "${environment[@]}" "HOST_CONSOLE_WAIT=$value" "$REPO/scripts/edge-routes")
    run script --quiet --return --command "$command" /dev/null < /dev/null
    echo "edge-routes, HOST_CONSOLE_WAIT=$value: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"HOST_CONSOLE_WAIT is not a whole number of seconds of at most 9 digits"* ]]
    absent -E '^(tofu|ssh|ssh-keyscan|openstack) ' "$RECORD/argv"
    [ ! -e "$lock" ]
  done
}

@test "EDGE_ROLLOUT_WAIT and EDGE_ROLLOUT_INTERVAL are read from .env, as HOST_CONSOLE_WAIT is" {
  local environment=() entry row wait interval reads moved new lock
  lock="$REPO/infra/openstack/stacks/sto2/edge/.terraform/infra.lock"
  with_instances
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  # The three waits are in the fake .env only, not in the environment the scripts start with.
  for entry in "${ENVIRONMENT[@]}"; do
    [[ $entry == EDGE_ROLLOUT_WAIT=* || $entry == EDGE_ROLLOUT_INTERVAL=* || $entry == HOST_CONSOLE_WAIT=* ]] || environment+=("$entry")
  done

  # Eight seconds in steps of four read the console at 0, 4 and 8; ten in steps of two at 0, 2, 4, 6,
  # 8 and 10, where the defaults, 900 and 15, would read it far more often.
  for row in '08 04 3 8' '010 02 6 10'; do
    read -r wait interval reads moved <<< "$row"
    printf 'EDGE_ROLLOUT_WAIT=%s\nEDGE_ROLLOUT_INTERVAL=%s\nHOST_CONSOLE_WAIT=0\n' "$wait" "$interval" > "$REPO/.env"
    original_keys
    fake_clock
    plan_replacing 1
    new=$(next_instance 1)
    early_console | set_console "$new"
    : > "$RECORD/argv"
    run bash -c 'printf "yes\n" | env "$@"' _ "${environment[@]}" "$REPO/scripts/edge-rollout" --yes
    echo "EDGE_ROLLOUT_WAIT=$wait EDGE_ROLLOUT_INTERVAL=$interval in .env: $output"
    [ "$status" -eq 0 ]
    [ "$(console_reads "$new")" -eq "$reads" ]
    [ "$(clock_moved)" -eq "$moved" ]
  done

  # A value in .env that is no whole number of at most 9 digits is refused, named, before the stack
  # is locked or touched.
  original_keys
  for name in EDGE_ROLLOUT_WAIT EDGE_ROLLOUT_INTERVAL; do
    printf 'EDGE_ROLLOUT_WAIT=0\nEDGE_ROLLOUT_INTERVAL=0\nHOST_CONSOLE_WAIT=0\n%s=30s\n' "$name" > "$REPO/.env"
    rm -f "$lock"
    : > "$RECORD/argv"
    run bash -c 'printf "yes\n" | env "$@"' _ "${environment[@]}" "$REPO/scripts/edge-rollout" --yes
    echo "$name=30s in .env: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"$name is not a whole number of seconds of at most 9 digits"* ]]
    absent -E '^(tofu|ssh|ssh-keyscan|openstack) ' "$RECORD/argv"
    [ ! -e "$lock" ]
  done
}

@test "edge-check takes the stack's lock, which only the child of a run that holds it shares" {
  local lock="$REPO/infra/openstack/stacks/sto2/edge/.terraform/infra.lock" value
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  mkdir -p "${lock%/*}"
  # Another run holds the lock, on descriptor 8. Descriptor 9 is open on the same file without
  # holding it.
  exec 8> "$lock" 9> "$lock"
  flock -n 8

  # EDGE_STACK_LOCKED alone does not let edge-check read the stack: whatever it is set to, a number
  # that names no descriptor open on the lock file or one open on it that holds no lock, a run
  # that cannot take the lock stops, saying the stack is busy.
  for value in 1 9 x ''; do
    : > "$RECORD/argv"
    run env "${ENVIRONMENT[@]}" "EDGE_STACK_LOCKED=$value" "$REPO/scripts/edge-check" --edge 1 < /dev/null
    echo "EDGE_STACK_LOCKED=$value: $output"
    [ "$status" -ne 0 ]
    [[ $output == *"sto2/edge is busy: another operation on it is running"* ]]
    absent -E '^(tofu|ssh) ' "$RECORD/argv"
  done
  exec 8>&- 9>&-

  # The child of a run that holds the lock, on the descriptor it names, shares it and runs.
  : > "$RECORD/argv"
  # shellcheck disable=SC2016 # $1 and $2 are the inner shell's.
  run env "${ENVIRONMENT[@]}" bash -c 'exec 7> "$1" && flock -n 7 && EDGE_STACK_LOCKED=7 "$2" --edge 1' _ "$lock" "$REPO/scripts/edge-check" < /dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output != *"is busy"* ]]
  grep -q '^tofu .* init ' "$RECORD/argv"

  # Nothing holds the lock afterwards, and a run with no variable takes it for itself.
  flock -n "$lock" true
  : > "$RECORD/argv"
  edge_check --edge 1 < /dev/null
  [ "$status" -eq 0 ]
  grep -q '^tofu .* init ' "$RECORD/argv"
}

@test "Only the fingerprints cloud-init printed at the latest boot count" {
  local fixtures="$ROOT/tests/fixtures/console" name expected first ending
  with_instances
  first=$(for name in FirstEcdsa FirstEd25519 FirstRsa; do fixture_fingerprint "$name"; done | sort)
  # Each log is read as it is, each line ended by LF, and with each line ended by CR LF, as a serial
  # console's terminal writes it; both read the same.
  for ending in LF CRLF; do
    # console_fingerprints INSTANCE reads the console through the client and prints the
    # fingerprints of the latest block cloud-init printed between its markers, one per line, none
    # when there is no complete one.
    read_console() {
      cp "$fixtures/$1.log" "$HOST/console-$INSTANCE_1"
      [[ $ending == LF ]] || crlf "$HOST/console-$INSTANCE_1"
      # shellcheck disable=SC2016 # $1 and $2 are the script's own arguments
      run env "${ENVIRONMENT[@]}" bash -c '. "$1/scripts/lib/host-keys.sh" && console_fingerprints "$2"' _ "$REPO" "$INSTANCE_1"
      echo "$1, $ending: $output"
    }

    read_console one-boot
    [ "$status" -eq 0 ]
    [ "$output" = "$first" ]

    # Two boots: the second boot's block alone.
    read_console two-boots
    [ "$status" -eq 0 ]
    expected=$(for name in SecondEcdsa SecondEd25519 SecondRsa; do fixture_fingerprint "$name"; done | sort)
    [ "$output" = "$expected" ]

    # A block cut off by the line limit, at its start or at its end, is not a block: its lines count
    # for nothing, and an earlier boot's block does not stand in for the latest boot's.
    read_console cut-off-head
    [ "$status" -eq 3 ]
    [ -z "$output" ]
    read_console cut-off-tail
    [ "$status" -eq 3 ]
    [ -z "$output" ]

    # A fingerprint-shaped string outside the markers, or something inside them that is not a
    # SHA256 fingerprint, is not cloud-init's.
    read_console outside-markers
    [ "$status" -eq 0 ]
    [ "$output" = "$(fixture_fingerprint InsideEd25519)" ]

    # logger's header in its exact form: the tag ec2 up to cloud-init 21.1 and cloud-init from 21.2,
    # and the day of the month padded with a space below 10. Only cloud-init's own tags count, so a
    # block another process printed in the same form, under its own tag, is not cloud-init's.
    for name in single-digit-day ec2-tag ec2-tag-single-digit-day; do
      read_console "$name"
      [ "$status" -eq 0 ]
      [ "$output" = "$first" ]
    done
    read_console foreign-tag
    [ "$status" -eq 3 ]
    [ -z "$output" ]
    # A block without logger's header, one in another form close to it (a day padded with a zero, a
    # priority other than user.info's, a weekday for a month, a process id after the tag, an hour of
    # one digit, no space after the colon, no such day, a space before it), and the copy the journal
    # forwards to the console (a kernel timestamp, then the tag and the process id) are not
    # cloud-init's block; the journal's copy between logger's lines changes nothing.
    for name in headerless near-logger journal-echo; do
      read_console "$name"
      [ "$status" -eq 3 ]
      [ -z "$output" ]
    done
    read_console with-journal-echo
    [ "$status" -eq 0 ]
    [ "$output" = "$first" ]
  done

  # The client was asked for the instance's console by its identifier, and for a bounded number of
  # lines.
  grep -qx "openstack console log show --lines 1000 $INSTANCE_1" "$RECORD/argv"

  # Through the recipe: the key the address offers is in an earlier boot's block, and not in the
  # latest one's, so it is not the instance's word.
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  plan_replacing 1
  {
    console_block "$(fingerprint "$(replacement_key 1)")"
    echo 'lab-edge-1 login: '
    console_block "$(fixture_fingerprint SomeoneElsesKeyEd25519)"
  } | set_console "$(next_instance 1)"
  rollout_with_input 'yes\nyes\n'
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"offers a key its instance did not print"* ]]
  [ "$(recorded 1)" = "" ]
}

@test "an identifier that is not a UUID is never used to read a console" {
  with_instances
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  plan_replacing 1
  # An identifier the cloud would take as a name or a prefix, and an option for the client, are not
  # the instance the stack created, before the apply or after it.
  jq '.instances.value["1"].id = "--lines"' "$BATS_TEST_TMPDIR/outputs.json" > "$BATS_TEST_TMPDIR/outputs.bad"
  mv "$BATS_TEST_TMPDIR/outputs.bad" "$BATS_TEST_TMPDIR/outputs.json"
  echo '--lines' > "$HOST/next-id-1"
  console_block "$(fingerprint "$(replacement_key 1)")" | set_console --lines
  : > "$RECORD/argv"
  rollout_with_input 'yes\n'
  echo "$output"
  [ "$status" -eq 0 ]
  absent '^openstack console' "$RECORD/argv"
  [[ $output == *"the stack's outputs name no instance for it"* ]]
  [[ $output == *"Type yes to record them and connect"* ]]
  [ "$(recorded 1)" = "$(replacement_key 1)" ]
}

@test "What is compared with the console is what is recorded" {
  with_instances
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  plan_replacing 1
  console_block "$(fingerprint "$(replacement_key 1)")" | set_console "$(next_instance 1)"
  # A second scan of the address would answer with another key, which the instance did not print.
  echo "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureAnotherKeyAtTheSameAddress" > "$HOST/key-$ADDRESS_1.rescan"
  : > "$RECORD/argv"
  rollout_with_input ''
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(recorded 1)" = "$(replacement_key 1)" ]
  [ "$(cat "$RECORD/scans-$ADDRESS_1")" -eq 1 ]
  [ "$(grep -c "^ssh-keyscan .*$ADDRESS_1\$" "$RECORD/argv")" -eq 1 ]
  # The scan is made hashed, so the file does not list the address.
  grep -q '^ssh-keyscan -H ' "$RECORD/argv"
}

@test "The settings check asks the daemon as the configured user" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  # The fake ssh accepts only the user the test names, so connecting as another fails the run.
  echo ops > "$HOST/ssh-user"
  # Another user's Match fails the check, and the default user's does not: a check that asks as
  # debian passes the first and fails the second.
  echo 'passwordauthentication yes' > "$HOST/edge-1/sshd-match-user-ops"
  run env "${ENVIRONMENT[@]}" EDGE_SSH_USER=ops "$REPO/scripts/edge-check" --edge 1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output$'\n' == *"FAIL  lab-edge-1: the SSH daemon's effective settings differ from the first boot's: passwordauthentication"$'\n'* ]]
  grep -q '^ssh .* ops@' "$RECORD/argv"
  rm "$HOST/edge-1/sshd-match-user-ops"
  echo 'passwordauthentication yes' > "$HOST/edge-1/sshd-match-user-debian"
  run env "${ENVIRONMENT[@]}" EDGE_SSH_USER=ops "$REPO/scripts/edge-check" --edge 1
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"pass  lab-edge-1: the SSH daemon runs with the settings the first boot wrote"* ]]

  # The same through this machine's own OpenSSH server, where it has one.
  if type -P sshd ssh-keygen > /dev/null; then
    rm "$HOST/edge-1/sshd-match-user-debian"
    mkdir -p "$HOST/edge-1/sshd_config.d"
    ssh-keygen -q -t ed25519 -N '' -f "$HOST/edge-1/ssh-host-key"
    printf 'Include %s/*.conf\n' "$HOST/edge-1/sshd_config.d" > "$HOST/edge-1/sshd_config"
    cp "$ROOT/infra/openstack/stacks/sto2/edge/sshd.conf" "$HOST/edge-1/sshd_config.d/00-edge.conf"
    printf 'Match User ops\n  PasswordAuthentication yes\n' > "$HOST/edge-1/sshd_config.d/50-image.conf"
    run env "${ENVIRONMENT[@]}" EDGE_SSH_USER=ops "$REPO/scripts/edge-check" --edge 1
    echo "real sshd, the configured user's Match: $output"
    [ "$status" -ne 0 ]
    [[ $output$'\n' == *"FAIL  lab-edge-1: the SSH daemon's effective settings differ from the first boot's: passwordauthentication"$'\n'* ]]
    printf 'Match User debian\n  PasswordAuthentication yes\n' > "$HOST/edge-1/sshd_config.d/50-image.conf"
    run env "${ENVIRONMENT[@]}" EDGE_SSH_USER=ops "$REPO/scripts/edge-check" --edge 1
    echo "real sshd, the default user's Match: $output"
    [ "$status" -eq 0 ]
    [[ $output == *"pass  lab-edge-1: the SSH daemon runs with the settings the first boot wrote"* ]]
  else
    echo "not proved here: no sshd on this machine, so the Match for the configured user is read by the fake sshd only"
  fi
}

@test "the check describes the connection to the daemon with its port and a local address of the documentation range" {
  edge_state 1 active "$WORKERS" 203.0.113.17/32
  edge_state 2 active "$WORKERS" 203.0.113.17/32
  edge_check --edge 1
  echo "$output"
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2016 # $edge_user is the check's, expanded on the edge
  grep -qF 'sshd -T -C "user=$edge_user,host=operator.example.org,addr=198.51.100.1,laddr=203.0.113.1,lport=22"' "$RECORD/argv"

  # An OpenSSH server refuses a configuration with a Match on the local port or address when the
  # connection it is asked about has none. With them, the blocks that match the port and a local
  # address of the documentation range apply, and others do not.
  if type -P sshd ssh-keygen > /dev/null; then
    mkdir -p "$HOST/edge-1/sshd_config.d"
    ssh-keygen -q -t ed25519 -N '' -f "$HOST/edge-1/ssh-host-key"
    printf 'Include %s/*.conf\n' "$HOST/edge-1/sshd_config.d" > "$HOST/edge-1/sshd_config"
    cp "$ROOT/infra/openstack/stacks/sto2/edge/sshd.conf" "$HOST/edge-1/sshd_config.d/00-edge.conf"
    printf 'Match LocalPort 22\n  PasswordAuthentication yes\n' > "$HOST/edge-1/sshd_config.d/50-image.conf"
    edge_check --edge 1
    echo "Match LocalPort: $output"
    [ "$status" -ne 0 ]
    [[ $output$'\n' == *"FAIL  lab-edge-1: the SSH daemon's effective settings differ from the first boot's: passwordauthentication"$'\n'* ]]
    printf 'Match LocalPort 2222\n  PasswordAuthentication yes\n' > "$HOST/edge-1/sshd_config.d/50-image.conf"
    edge_check --edge 1
    echo "Match LocalPort, another: $output"
    [ "$status" -eq 0 ]
    printf 'Match LocalAddress 203.0.113.0/24\n  PasswordAuthentication yes\n' > "$HOST/edge-1/sshd_config.d/50-image.conf"
    edge_check --edge 1
    echo "Match LocalAddress, the documentation range: $output"
    [ "$status" -ne 0 ]
    printf 'Match LocalAddress 192.0.2.0/24\n  PasswordAuthentication yes\n' > "$HOST/edge-1/sshd_config.d/50-image.conf"
    edge_check --edge 1
    echo "Match LocalAddress, another range: $output"
    [ "$status" -eq 0 ]
  else
    echo "not proved here: no sshd on this machine, so the Match blocks on the local port and address are not run through sshd -T"
  fi
}
