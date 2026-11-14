#!/usr/bin/env bats

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  SCRIPT="$ROOT/scripts/talos-check"
  FIXTURE="$ROOT/tests/fixtures/talos/inputs.yaml"
  RENDERED="$BATS_TEST_TMPDIR/rendered"
}

# The files git would commit that the check reads, copied so a test can break them. Ignored files,
# such as a rendered talman.yaml and its output, stay behind.
copy_tree() {
  COPY="$BATS_TEST_TMPDIR/repository"
  local path
  while IFS= read -r -d '' path; do
    if [[ -f $ROOT/$path ]]; then
      mkdir -p "$COPY/$(dirname "$path")"
      cp "$ROOT/$path" "$COPY/$path"
    fi
  done < <(git -C "$ROOT" ls-files -z --cached --others --exclude-standard -- scripts talos versions.yaml tests/fixtures/talos)
}

# nodes [ROLE]: the fixture's hostnames, all or only those with ROLE.
nodes() {
  if [[ -n ${1-} ]]; then
    yq ".nodes[] | select(.role == \"$1\") | .hostname" "$FIXTURE"
  else
    yq '.nodes[].hostname' "$FIXTURE"
  fi
}

# ipv4 ADDRESS: the IPv4 address as a number.
ipv4() {
  local -a octets
  IFS=. read -r -a octets <<< "$1"
  echo $(((octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]))
}

# in_subnet ADDRESS CIDR: whether the IPv4 address lies in the network.
in_subnet() {
  local bits=${2#*/} mask
  mask=$(((0xffffffff << (32 - bits)) & 0xffffffff))
  (((($(ipv4 "$1") ^ $(ipv4 "${2%/*}")) & mask) == 0))
}

# overlap A B: whether the IPv4 networks A and B share an address.
overlap() {
  in_subnet "${1%/*}" "$2" || in_subnet "${2%/*}" "$1"
}

# missing WANTED HAVE: the lines of WANTED that HAVE lacks.
missing() {
  comm -23 <(sort -u <<< "$1") <(sort -u <<< "$2")
}

# shared A B: the lines A and B have in common.
shared() {
  comm -12 <(sort -u <<< "$1") <(sort -u <<< "$2")
}

@test "The fixture node data has the shape the cluster stack renders" {
  node_subnet=$(yq '.node_subnet' "$FIXTURE")
  pod_subnet=$(yq '.pod_subnet' "$FIXTURE")
  service_subnet=$(yq '.service_subnet' "$FIXTURE")
  sans=$(yq '.api_sans[]' "$FIXTURE")
  # talman runs outside the node network and reaches every node at its floating address.
  checked=0
  while IFS=' ' read -r address floating_ip; do
    [ "$address" = "$floating_ip" ]
    run in_subnet "$floating_ip" "$node_subnet"
    [ "$status" -ne 0 ]
    checked=$((checked + 1))
  done < <(yq '.nodes[] | .address + " " + .floating_ip' "$FIXTURE")
  [ "$checked" -eq 6 ]
  # The endpoint is the load balancer's address on the node network, a certificate name like the
  # floating address the recipes reach the API on.
  endpoint=$(yq '.endpoint' "$FIXTURE")
  [[ $endpoint =~ ^https://([0-9.]+):6443$ ]]
  in_subnet "${BASH_REMATCH[1]}" "$node_subnet"
  grep -qxF "${BASH_REMATCH[1]}" <<< "$sans"
  grep -qxF "$(yq '.api_address' "$FIXTURE")" <<< "$sans"
  # The cluster stack's checks of pod_subnet and service_subnet.
  run overlap "$pod_subnet" "$node_subnet"
  [ "$status" -ne 0 ]
  run overlap "$service_subnet" "$node_subnet"
  [ "$status" -ne 0 ]
  run overlap "$service_subnet" "$pod_subnet"
  [ "$status" -ne 0 ]
  (((1 << (24 - ${pod_subnet#*/})) >= checked))
}

@test "Every node's configuration renders and validates offline" {
  # Every proxy points at a local port nothing listens on, so any fetch fails the check.
  run bash -c ': < /dev/tcp/127.0.0.1/9'
  [ "$status" -ne 0 ]
  proxy=http://127.0.0.1:9

  run env HTTP_PROXY="$proxy" HTTPS_PROXY="$proxy" ALL_PROXY="$proxy" NO_PROXY= \
    http_proxy="$proxy" https_proxy="$proxy" all_proxy="$proxy" no_proxy= "$SCRIPT" "$RENDERED"

  [ "$status" -eq 0 ]
  mapfile -t hostnames < <(nodes)
  [ "${#hostnames[@]}" -eq 6 ]
  expected=$(printf 'talos-check: %s: rendered and valid for the cloud platform\n' "${hostnames[@]}")
  [ "$output" = "$expected" ]
  for hostname in "${hostnames[@]}"; do
    config="$RENDERED/$hostname.yaml"
    [ "$(yq 'select(.kind == "HostnameConfig") | .hostname' "$config")" = "$hostname" ]
    talosctl validate --mode cloud --strict --config "$config"
  done
}

@test "Each node's configuration takes its versions, endpoint and subnets from the inputs" {
  talos=v1.14.0
  kubernetes=v1.36.2
  endpoint=https://192.0.2.5:6443
  node_subnet=192.0.2.0/26
  pod_subnet=203.0.113.0/24
  service_subnet=198.51.100.0/24
  # Every value differs from the repository's, so one that is not read from the inputs shows.
  [ "$(yq '.talos' "$ROOT/versions.yaml")" != "$talos" ]
  [ "$(yq '.kubernetes' "$ROOT/versions.yaml")" != "$kubernetes" ]
  [ "$(yq '.endpoint' "$FIXTURE")" != "$endpoint" ]
  [ "$(yq '.node_subnet' "$FIXTURE")" != "$node_subnet" ]
  [ "$(yq '.pod_subnet' "$FIXTURE")" != "$pod_subnet" ]
  [ "$(yq '.service_subnet' "$FIXTURE")" != "$service_subnet" ]
  copy_tree
  yq -i ".talos = \"$talos\" | .kubernetes = \"$kubernetes\"" "$COPY/versions.yaml"
  yq -i ".endpoint = \"$endpoint\" | .node_subnet = \"$node_subnet\" | .pod_subnet = \"$pod_subnet\" | .service_subnet = \"$service_subnet\"" \
    "$COPY/tests/fixtures/talos/inputs.yaml"
  yq -i '.customization.extraKernelArgs = ["console=ttyS0"]' "$COPY/talos/schematic.yaml"
  # The schematic ID as talman computes it, from a configuration that holds little but the schematic.
  mkdir "$BATS_TEST_TMPDIR/schematic"
  cat > "$BATS_TEST_TMPDIR/schematic/talman.yaml" <<EOF
apiVersion: talman.dev/v1
clusterName: schematic
endpoint: $endpoint
talosVersion: $talos
kubernetesVersion: $kubernetes
schematic: $COPY/talos/schematic.yaml
nodes:
  - hostname: node
    ipAddress: 192.0.2.5
    role: controlplane
EOF
  schematic_id=$(talman -c "$BATS_TEST_TMPDIR/schematic" schematic id -o json | yq -p json '.nodes[0].schematicID')
  [ -n "$schematic_id" ]

  run "$COPY/scripts/talos-check" "$RENDERED"

  [ "$status" -eq 0 ]
  for hostname in $(nodes); do
    config="$RENDERED/$hostname.yaml"
    [ "$(yq 'select(.kind == "UnattendedInstallConfig") | .installer.image' "$config")" = "factory.talos.dev/openstack-installer/$schematic_id:$talos" ]
    [ "$(yq 'select(.kind == "KubeClusterConfig") | .endpoint' "$config")" = "$endpoint" ]
    [[ $(yq 'select(.kind == "KubeletConfig") | .image' "$config") == *":$kubernetes" ]]
    [ "$(yq 'select(.kind == "KubeNetworkConfig") | .podSubnets[]' "$config")" = "$pod_subnet" ]
    [ "$(yq 'select(.kind == "KubeNetworkConfig") | .serviceSubnets[]' "$config")" = "$service_subnet" ]
    [ "$(yq 'select(.kind == "KubeNodeConfig") | .nodeIP.validSubnets[]' "$config")" = "$node_subnet" ]
  done
  for hostname in $(nodes controlplane); do
    config="$RENDERED/$hostname.yaml"
    [[ $(yq 'select(.kind == "KubeAPIServerConfig") | .image' "$config") == *":$kubernetes" ]]
    [ "$(yq 'select(.version == "v1alpha1") | .cluster.etcd.advertisedSubnets[]' "$config")" = "$node_subnet" ]
    [ "$(yq 'select(.version == "v1alpha1") | .cluster.etcd.listenSubnets[]' "$config")" = "$node_subnet" ]
  done
}

@test "A patch with an unknown field fails the check" {
  copy_tree
  printf 'unknownField: true\n' >> "$COPY/talos/patches/all/kubelet.yaml"

  run "$COPY/scripts/talos-check"

  [ "$status" -ne 0 ]
  [[ $output == *"patches/all/kubelet.yaml"* ]]
  named=0
  for hostname in $(nodes); do
    if [[ $output == *"$hostname"* ]]; then
      named=1
    fi
  done
  [ "$named" -eq 1 ]
}

@test "A template tofu cannot render fails the check with tofu's message" {
  copy_tree
  inputs="$COPY/tests/fixtures/talos/inputs.yaml"
  template="$COPY/talos/talman.yaml.tftpl"
  cp "$inputs" "$BATS_TEST_TMPDIR/inputs.yaml"
  yq -i 'del(.pod_subnet)' "$inputs"

  run "$COPY/scripts/talos-check"

  [ "$status" -ne 0 ]
  [[ $output == *'"pod_subnet"'* ]]
  [[ $output == *"talos-check: tofu could not render talos/talman.yaml.tftpl"* ]]
  [[ $output != *base64* ]]

  cp "$BATS_TEST_TMPDIR/inputs.yaml" "$inputs"
  sed -i 's/{cluster_name}/{cluster_nmae}/' "$template"
  grep -q cluster_nmae "$template"

  run "$COPY/scripts/talos-check"

  [ "$status" -ne 0 ]
  [[ $output == *'"cluster_nmae"'* ]]
  [[ $output == *"talos-check: tofu could not render talos/talman.yaml.tftpl"* ]]
  [[ $output != *base64* ]]
}

@test "A node's floating address is held on a dummy link" {
  run "$SCRIPT" "$RENDERED"

  [ "$status" -eq 0 ]
  checked=0
  while IFS=' ' read -r hostname floating_ip; do
    addresses=$(yq 'select(.kind == "DummyLinkConfig") | .addresses[].address' "$RENDERED/$hostname.yaml")
    [ "$addresses" = "$floating_ip/32" ]
    checked=$((checked + 1))
  done < <(yq '.nodes[] | .hostname + " " + .floating_ip' "$FIXTURE")
  [ "$checked" -eq 6 ]
}

@test "Kubernetes and etcd use the node network, not the floating address" {
  node_subnet=$(yq '.node_subnet' "$FIXTURE")
  [ "$node_subnet" != null ]
  # talman reaches each node at its floating address, outside the node network, so a patch that took
  # the node's address from talman would leave the node network.
  checked=0
  while IFS=' ' read -r address floating_ip; do
    [ "$address" = "$floating_ip" ]
    run in_subnet "$floating_ip" "$node_subnet"
    [ "$status" -ne 0 ]
    checked=$((checked + 1))
  done < <(yq '.nodes[] | .address + " " + .floating_ip' "$FIXTURE")
  [ "$checked" -eq 6 ]

  run "$SCRIPT" "$RENDERED"

  [ "$status" -eq 0 ]
  for hostname in $(nodes); do
    [ "$(yq 'select(.kind == "KubeNodeConfig") | .nodeIP.validSubnets[]' "$RENDERED/$hostname.yaml")" = "$node_subnet" ]
  done
  mapfile -t controlplanes < <(nodes controlplane)
  [ "${#controlplanes[@]}" -eq 3 ]
  for hostname in "${controlplanes[@]}"; do
    etcd=$(yq 'select(.version == "v1alpha1") | .cluster.etcd' "$RENDERED/$hostname.yaml")
    [ "$(yq '.advertisedSubnets[]' <<< "$etcd")" = "$node_subnet" ]
    [ "$(yq '.listenSubnets[]' <<< "$etcd")" = "$node_subnet" ]
  done
}

@test "Control planes carry the API certificate names" {
  run "$SCRIPT" "$RENDERED"

  [ "$status" -eq 0 ]
  sans=$(yq '.api_sans[]' "$FIXTURE")
  [ -n "$sans" ]
  mapfile -t controlplanes < <(nodes controlplane)
  mapfile -t workers < <(nodes worker)
  [ "${#controlplanes[@]}" -eq 3 ]
  [ "${#workers[@]}" -eq 3 ]
  for hostname in "${controlplanes[@]}"; do
    talos_api=$(yq 'select(.machine) | .machine.certSANs[]' "$RENDERED/$hostname.yaml")
    kubernetes_api=$(yq 'select(.kind == "KubeAPIServerConfig") | .certExtraSANs[]' "$RENDERED/$hostname.yaml")
    [ -z "$(missing "$sans" "$talos_api")" ]
    [ -z "$(missing "$sans" "$kubernetes_api")" ]
  done
  for hostname in "${workers[@]}"; do
    talos_api=$(yq 'select(.machine) | .machine.certSANs[]' "$RENDERED/$hostname.yaml")
    kubernetes_api=$(yq 'select(.kind == "KubeAPIServerConfig") | .certExtraSANs[]' "$RENDERED/$hostname.yaml")
    [ -z "$(shared "$sans" "$talos_api")" ]
    [ -z "$(shared "$sans" "$kubernetes_api")" ]
  done
}

@test "Cilium replaces the bundled CNI and kube-proxy" {
  run "$SCRIPT" "$RENDERED"

  [ "$status" -eq 0 ]
  mapfile -t controlplanes < <(nodes controlplane)
  [ "${#controlplanes[@]}" -eq 3 ]
  for hostname in "${controlplanes[@]}"; do
    config="$RENDERED/$hostname.yaml"
    [ -z "$(yq 'select(.kind == "KubeFlannelCNIConfig") | .kind' "$config")" ]
    [ "$(yq 'select(.kind == "KubeProxyConfig") | .enabled' "$config")" = false ]
  done
}

@test "The node image carries the DRBD, gVisor and Kata Containers extensions and no other" {
  # The plumbing stack builds the image from this file, and talman computes from it the installer
  # image the nodes install and upgrade to. Not deduplicated, so a name listed twice shows.
  extensions=$(yq '.customization.systemExtensions.officialExtensions // [] | .[]' "$ROOT/talos/schematic.yaml" | sort)
  echo "official extensions: $(paste -sd' ' <<< "$extensions")"

  [ "$extensions" = "$(printf '%s\n' siderolabs/drbd siderolabs/gvisor siderolabs/kata-containers)" ]
}

@test "Every node's machine configuration loads the kernel modules DRBD and LINSTOR's storage pools need" {
  run "$SCRIPT" "$RENDERED"

  [ "$status" -eq 0 ]
  # Each module with its parameters, one line per KernelModuleConfig document.
  expected=$(printf '%s\n' 'dm-snapshot' 'dm-thin-pool' 'drbd usermode_helper=disabled' 'drbd_transport_tcp' | sort)
  checked=0
  for hostname in $(nodes); do
    modules=$(yq -N 'select(.kind == "KernelModuleConfig") | [.name] + (.parameters // []) | join(" ")' "$RENDERED/$hostname.yaml" | sort)
    echo "$hostname loads: $(paste -sd, <<< "$modules")"
    [ "$modules" = "$expected" ]
    checked=$((checked + 1))
  done
  [ "$checked" -eq 6 ]
}

@test "Every worker's machine configuration names the data device the same way, and no control plane's does" {
  run "$SCRIPT" "$RENDERED"

  [ "$status" -eq 0 ]
  mapfile -t controlplanes < <(nodes controlplane)
  mapfile -t workers < <(nodes worker)
  [ "${#controlplanes[@]}" -eq 3 ]
  [ "${#workers[@]}" -eq 3 ]
  # Talos labels a raw volume's partition r-<name> and links it as /dev/disk/by-partlabel/r-<name>,
  # so the volume's name is the device's name. The disk is chosen as the one Talos does not run
  # from, by nothing the cloud assigns: no ID, serial or device path.
  first=
  for hostname in "${workers[@]}"; do
    [ "$(yq 'select(.kind == "RawVolumeConfig") | .kind' "$RENDERED/$hostname.yaml" | wc -l)" -eq 1 ]
    raw=$(yq -o json -I 0 'select(.kind == "RawVolumeConfig")' "$RENDERED/$hostname.yaml")
    [ "$(yq -p json '.name' <<< "$raw")" = data ]
    [ "$(yq -p json '.provisioning.diskSelector.match' <<< "$raw")" = '!system_disk' ]
    [ "$raw" = "${first:=$raw}" ]
  done
  for hostname in "${controlplanes[@]}"; do
    [ -z "$(yq 'select(.kind == "RawVolumeConfig") | .kind' "$RENDERED/$hostname.yaml")" ]
  done
}

@test "The machine configuration puts no filesystem on the data device" {
  run "$SCRIPT" "$RENDERED"

  [ "$status" -eq 0 ]
  mapfile -t workers < <(nodes worker)
  [ "${#workers[@]}" -eq 3 ]
  for hostname in "${workers[@]}"; do
    [ "$(yq 'select(.kind == "RawVolumeConfig") | .name' "$RENDERED/$hostname.yaml")" = data ]
  done
  checked=0
  for hostname in $(nodes); do
    config="$RENDERED/$hostname.yaml"
    # Volumes Talos formats or mounts, swap, and LVM, which claims a disk as a physical volume.
    claims=$(yq 'select(.kind // "" | test("^(User|Existing|External|Swap)VolumeConfig$|^LVM")) | .kind' "$config")
    [ -z "$claims" ]
    # A system volume follows the system disk unless a disk selector places it elsewhere.
    [ -z "$(yq 'select(.kind == "VolumeConfig" and .provisioning.diskSelector != null) | .name' "$config")" ]
    # The machine configuration's own partitioning and mounting of extra disks.
    [ "$(yq 'select(.version == "v1alpha1") | .machine.disks // [] | length' "$config")" -eq 0 ]
    # Encryption would write a LUKS header onto the partition.
    [ -z "$(yq 'select(.kind == "RawVolumeConfig" and .encryption != null) | .name' "$config")" ]
    checked=$((checked + 1))
  done
  [ "$checked" -eq 6 ]
}

@test "An output directory inside the repository is refused" {
  copy_tree
  ln -s "$COPY/talos" "$BATS_TEST_TMPDIR/linked"
  before=$(find "$COPY" -mindepth 1 | sort)

  for directory in "$COPY/rendered" "$COPY" rendered "$BATS_TEST_TMPDIR/linked/rendered"; do
    run bash -c 'cd "$1" && "$2" "$3"' -- "$COPY/talos" "$COPY/scripts/talos-check" "$directory"

    [ "$status" -ne 0 ]
    [[ $output == *"is inside the repository"* ]]
    [ "$(find "$COPY" -mindepth 1 | sort)" = "$before" ]
  done
}

@test "The check leaves nothing behind" {
  copy_tree
  scratch="$BATS_TEST_TMPDIR/tmp"
  mkdir "$scratch"
  before=$(find "$COPY" -mindepth 1 | sort)

  run env TMPDIR="$scratch" "$COPY/scripts/talos-check"

  [ "$status" -eq 0 ]
  [ "$(find "$COPY" -mindepth 1 | sort)" = "$before" ]
  [ -z "$(ls -A "$scratch")" ]

  printf 'unknownField: true\n' >> "$COPY/talos/patches/all/kubelet.yaml"
  before=$(find "$COPY" -mindepth 1 | sort)

  run env TMPDIR="$scratch" "$COPY/scripts/talos-check"

  [ "$status" -ne 0 ]
  [ "$(find "$COPY" -mindepth 1 | sort)" = "$before" ]
  [ -z "$(ls -A "$scratch")" ]
}
