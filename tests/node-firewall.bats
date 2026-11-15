#!/usr/bin/env bats
# Proves the offline scenarios of features/node-firewall.feature; each test carries its scenario's
# title. Every node's machine configuration is rendered once, by scripts/talos-check from the
# fixture in tests/fixtures/talos, with the real talman and talosctl, and read with yq. Nothing here
# reaches a node, a cluster or the cloud, or reads a deployment's allowlist.

setup_file() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  "$ROOT/scripts/talos-check" "$BATS_FILE_TMPDIR/rendered" > /dev/null
}

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  FIXTURE="$ROOT/tests/fixtures/talos/inputs.yaml"
  INVENTORY="$ROOT/talos/firewall.yaml"
  RENDERED="$BATS_FILE_TMPDIR/rendered"
}

# nodes [ROLE]: the fixture's hostnames, all or only those with ROLE.
nodes() {
  if [[ -n ${1-} ]]; then
    yq ".nodes[] | select(.role == \"$1\") | .hostname" "$FIXTURE"
  else
    yq '.nodes[].hostname' "$FIXTURE"
  fi
}

# rules HOSTNAME: each ingress rule of the node's configuration as its name, protocol and ports,
# the ports joined by commas, one rule per line, sorted.
rules() {
  yq -N 'select(.kind == "NetworkRuleConfig")
    | .name + " " + .portSelector.protocol + " " + (.portSelector.ports | map(tostring) | join(","))' \
    "$RENDERED/$1.yaml" | sort
}

# subnets HOSTNAME RULE: the networks the node's rule of that name accepts, one per line, sorted.
subnets() {
  yq -N "select(.kind == \"NetworkRuleConfig\" and .name == \"$2\") | .ingress[].subnet" "$RENDERED/$1.yaml" | sort
}

# listeners ROLE: the inventory's listeners a node of ROLE has, as rules() prints a rule.
listeners() {
  local nodes='.nodes == "all"'
  if [[ $1 == controlplane ]]; then
    nodes='.nodes == "all" or .nodes == "controlplane"'
  fi
  yq -N ".listeners[] | select($nodes) | .name + \" \" + .protocol + \" \" + (.ports | map(tostring) | join(\",\"))" \
    "$INVENTORY" | sort
}

# table: the rows of the table under "### What each node admits" in docs/cluster.md, as the
# inventory's entries: name, protocol, ports, nodes and sources, the sources sorted and joined by
# commas, one row per line, sorted.
table() {
  # shellcheck disable=SC2016 # a literal backtick, with which each row's first cell starts
  awk '/^### What each node admits/ { inside = 1; next } /^#/ { inside = 0 } inside && /^\| `/' "$ROOT/docs/cluster.md" |
    while IFS='|' read -r _ name ports nodes from _; do
      name=${name//[\` ]/}
      read -r protocol ports <<< "$ports"
      nodes=$(xargs <<< "$nodes")
      [[ $nodes == "control planes" ]] && nodes=controlplane
      from=$(grep -o '`[a-z]*`' <<< "$from" | tr -d '`' | sort | paste -sd, -)
      echo "$name ${protocol,,} $ports $nodes $from"
    done | sort
}

# inventory: the inventory's entries as table() prints a row.
inventory() {
  yq -N '.listeners[] | .name + " " + .protocol + " " + (.ports | map(tostring) | join(",")) + " " + .nodes
    + " " + (.from | sort | join(","))' "$INVENTORY" | sort
}

# resolve SOURCE: the networks a source of talos/firewall.yaml stands for, from the fixture, one per
# line. Fails on a source it does not know.
resolve() {
  case $1 in
    operators) yq '.operator_cidrs[]' "$FIXTURE" ;;
    loadbalancer) yq '.api_load_balancer_addresses[]' "$FIXTURE" ;;
    cihost) yq '.ci_host_address + "/32"' "$FIXTURE" ;;
    floating) yq '.nodes[].floating_ip + "/32"' "$FIXTURE" ;;
    pods) yq '.pod_subnet' "$FIXTURE" ;;
    controlplanes) yq '.nodes[] | select(.role == "controlplane") | .private_address + "/32"' "$FIXTURE" ;;
    members) yq '.nodes[].private_address + "/32"' "$FIXTURE" ;;
    *)
      echo "talos/firewall.yaml names a source the test does not know: $1" >&2
      return 1
      ;;
  esac
}

# expected LISTENER: the networks the inventory's sources of LISTENER resolve to, one per line, sorted.
expected() {
  local source
  for source in $(yq ".listeners[] | select(.name == \"$1\") | .from[]" "$INVENTORY"); do
    resolve "$source" || return 1
  done | sort -u
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

# overlapping A B: whether the port lists A and B, comma-separated ports and lo-hi ranges, share a
# port.
overlapping() {
  local a b
  for a in ${1//,/ }; do
    for b in ${2//,/ }; do
      if ((${a%-*} <= ${b#*-} && ${b%-*} <= ${a#*-})); then
        return 0
      fi
    done
  done
  return 1
}

@test "Every node drops inbound traffic by default" {
  checked=0
  for hostname in $(nodes); do
    actions=$(yq -N 'select(.kind == "NetworkDefaultActionConfig") | .ingress' "$RENDERED/$hostname.yaml")
    echo "$hostname: default action ${actions:-none}"
    [ "$actions" = block ]
    checked=$((checked + 1))
  done
  [ "$checked" -eq 6 ]
}

@test "Every listener in the inventory has a rule, and every rule has a line in the inventory" {
  checked=0
  for role in controlplane worker; do
    wanted=$(listeners "$role")
    [ -n "$wanted" ]
    for hostname in $(nodes "$role"); do
      echo "$hostname has: $(rules "$hostname" | paste -sd';' -)"
      diff <(echo "$wanted") <(rules "$hostname")
      # Each rule accepts exactly the networks its listener's sources stand for.
      while read -r rule _; do
        networks=$(expected "$rule")
        [ -n "$networks" ]
        diff <(echo "$networks") <(subnets "$hostname" "$rule")
        checked=$((checked + 1))
      done <<< "$wanted"
    done
  done
  [ "$checked" -eq $((3 * $(listeners controlplane | wc -l) + 3 * $(listeners worker | wc -l))) ]
  [ "$(listeners controlplane)" != "$(listeners worker)" ]
  # Names are what Talos tells rules apart by, so none may be given twice.
  [ -z "$(yq '.listeners[].name' "$INVENTORY" | sort | uniq -d)" ]
  [ -n "$(table)" ]
  diff <(inventory) <(table)
}

@test "The Talos API and the Kubernetes API accept the operator allowlist, the nodes, the load balancer and the CI host, and nobody else" {
  operators=$(yq '.operator_cidrs[]' "$FIXTURE")
  [ "$(wc -l <<< "$operators")" -eq 2 ]
  node_subnet=$(yq '.node_subnet' "$FIXTURE")
  pod_subnet=$(yq '.pod_subnet' "$FIXTURE")
  floating=$(yq '.nodes[].floating_ip + "/32"' "$FIXTURE")
  [ "$(wc -l <<< "$floating")" -eq 6 ]
  members=$(yq '.nodes[].private_address + "/32"' "$FIXTURE")
  [ "$(wc -l <<< "$members")" -eq 6 ]
  ci_host="$(yq '.ci_host_address' "$FIXTURE")/32"
  load_balancer=$(yq '.api_load_balancer_addresses[]' "$FIXTURE")
  talos_api=$(printf '%s\n' "$operators" "$members" "$floating" "$ci_host" | sort -u)
  kubernetes_api=$(printf '%s\n' "$talos_api" "$pod_subnet" "$load_balancer" | sort -u)
  # The load balancer's networks hold its address on the node network, where the nodes reach the
  # API, and lie on the node network.
  endpoint=$(yq '.endpoint' "$FIXTURE")
  [[ $endpoint =~ ^https://([0-9.]+):6443$ ]]
  awk -v vip="${BASH_REMATCH[1]}/32" '$0 == vip { found = 1 } END { exit !found }' <<< "$load_balancer"
  for network in $load_balancer; do
    in_subnet "${network%/*}" "$node_subnet"
  done
  outside=$(printf '%s\n' "$operators" "$floating" "$ci_host" "$load_balancer")

  for hostname in $(nodes); do
    diff <(echo "$talos_api") <(subnets "$hostname" apid)
    [ "$(rules "$hostname" | grep -c '^apid tcp 50000$')" -eq 1 ]
    for rule in $(rules "$hostname" | cut -d' ' -f1 | grep -vx -e apid -e kube-apiserver); do
      [ -z "$(comm -12 <(sort <<< "$outside") <(subnets "$hostname" "$rule"))" ]
    done
    # No rule accepts the node network as a whole, which also holds addresses no rule names.
    accepted=$(yq -N 'select(.kind == "NetworkRuleConfig") | .ingress[].subnet' "$RENDERED/$hostname.yaml")
    [ -z "$(awk -v net="$node_subnet" '$0 == net' <<< "$accepted")" ]
  done
  for hostname in $(nodes controlplane); do
    diff <(echo "$kubernetes_api") <(subnets "$hostname" kube-apiserver)
    [ "$(rules "$hostname" | grep -c '^kube-apiserver tcp 6443$')" -eq 1 ]
  done
}

@test "An edge router's address reaches no listener on any node" {
  # The edge routers, which the workers peer with over BGP and which face the internet, hold
  # addresses on the node network, beside the nodes, the load balancer and the CI host.
  node_subnet=$(yq '.node_subnet' "$FIXTURE")
  edges=$(yq '.bgp.edge_addresses[]' "$FIXTURE")
  [ "$(wc -l <<< "$edges")" -eq 2 ]
  for edge in $edges; do
    in_subnet "$edge" "$node_subnet"
  done

  checked=0
  for hostname in $(nodes); do
    for rule in $(rules "$hostname" | cut -d' ' -f1); do
      for network in $(subnets "$hostname" "$rule"); do
        for edge in $edges; do
          if in_subnet "$edge" "$network"; then
            echo "$hostname: $rule accepts $edge, an edge router's address, through $network"
            return 1
          fi
        done
      done
      checked=$((checked + 1))
    done
  done
  # Thirteen rules on each control plane, seven on each worker.
  [ "$checked" -eq 60 ]
}

@test "etcd accepts control planes only" {
  controlplanes=$(yq '.nodes[] | select(.role == "controlplane") | .private_address + "/32"' "$FIXTURE" | sort)
  workers=$(yq '.nodes[] | select(.role == "worker") | .private_address + "/32"' "$FIXTURE" | sort)
  [ "$(wc -l <<< "$controlplanes")" -eq 3 ]
  [ "$(wc -l <<< "$workers")" -eq 3 ]
  [ -z "$(comm -12 <(echo "$controlplanes") <(echo "$workers"))" ]
  node_subnet=$(yq '.node_subnet' "$FIXTURE")
  for address in $controlplanes; do
    in_subnet "${address%/*}" "$node_subnet"
  done

  for hostname in $(nodes controlplane); do
    [ "$(rules "$hostname" | grep -c '^etcd ')" -eq 1 ]
    [ "$(rules "$hostname" | grep '^etcd ')" = 'etcd tcp 2379-2380' ]
    diff <(echo "$controlplanes") <(subnets "$hostname" etcd)
  done
}

@test "Every listener pods reach admits every node's own address" {
  # Cilium sends a pod's traffic to another node's address out of the pod's node, masqueraded to that
  # node's address on the node network; only a pod on the node itself arrives from its own address.
  members=$(yq '.nodes[].private_address' "$FIXTURE")
  [ "$(wc -l <<< "$members")" -eq 6 ]
  reached=$(yq '.listeners[] | select(.from[] == "pods") | .name' "$INVENTORY" | sort -u)
  for listener in etcd-metrics kube-controller-manager kube-scheduler kubelet hubble node-exporter cilium-agent-metrics; do
    grep -qxF "$listener" <<< "$reached"
  done

  checked=0
  for hostname in $(nodes); do
    for rule in $(rules "$hostname" | cut -d' ' -f1 | grep -xF -f <(echo "$reached")); do
      accepted=$(subnets "$hostname" "$rule")
      for address in $members; do
        admitted=0
        for network in $accepted; do
          if in_subnet "$address" "$network"; then
            admitted=1
          fi
        done
        if ((!admitted)); then
          echo "$hostname: $rule does not admit $address, a node's own address"
          return 1
        fi
      done
      checked=$((checked + 1))
    done
  done
  # Eight on each control plane, four on each worker.
  [ "$checked" -eq 36 ]
}

@test "Cilium's overlay and health checks accept the nodes' own addresses only" {
  members=$(yq '.nodes[].private_address + "/32"' "$FIXTURE" | sort)
  [ "$(wc -l <<< "$members")" -eq 6 ]
  # The load balancer's address on the node network, which is no node's.
  endpoint=$(yq '.endpoint' "$FIXTURE")
  [[ $endpoint =~ ^https://([0-9.]+):6443$ ]]
  [ -z "$(awk -v lb="${BASH_REMATCH[1]}/32" '$0 == lb' <<< "$members")" ]

  for hostname in $(nodes); do
    [ "$(rules "$hostname" | grep -c -e '^cilium-vxlan udp 8472$' -e '^cilium-health tcp 4240$')" -eq 2 ]
    for rule in cilium-vxlan cilium-health; do
      diff <(echo "$members") <(subnets "$hostname" "$rule")
    done
  done
}

@test "The API server refuses new external addresses on Services" {
  # Cilium serves a Service's external addresses before the node's firewall sees the packets, and any
  # Service may name one, so the API server refuses them. Talos merges enable-admission-plugins from
  # the extra arguments into its own list instead of replacing it.
  checked=0
  for hostname in $(nodes controlplane); do
    plugins=$(yq -N 'select(.kind == "KubeAPIServerConfig") | .extraArgs["enable-admission-plugins"] // ""' "$RENDERED/$hostname.yaml")
    echo "$hostname enables: ${plugins:-none}"
    grep -qx DenyServiceExternalIPs < <(tr ',' '\n' <<< "$plugins")
    checked=$((checked + 1))
  done
  [ "$checked" -eq 3 ]
  for hostname in $(nodes worker); do
    [ -z "$(yq -N 'select(.kind == "KubeAPIServerConfig") | .extraArgs["enable-admission-plugins"] // ""' "$RENDERED/$hostname.yaml")" ]
  done
}

@test "Workers carry no rule for a control-plane-only listener" {
  only=$(yq -N '.listeners[] | select(.nodes == "controlplane") | .name + " " + .protocol + " " + (.ports | map(tostring) | join(","))' "$INVENTORY")
  grep -q '^etcd ' <<< "$only"
  grep -q '^kube-apiserver ' <<< "$only"

  checked=0
  for hostname in $(nodes worker); do
    while read -r name protocol ports; do
      while read -r listener only_protocol only_ports; do
        [ "$name" != "$listener" ]
        if [[ $protocol == "$only_protocol" ]] && overlapping "$ports" "$only_ports"; then
          echo "$hostname: $name $protocol $ports overlaps $listener's $only_ports"
          return 1
        fi
      done <<< "$only"
      checked=$((checked + 1))
    done < <(rules "$hostname")
  done
  [ "$checked" -gt 0 ]
}

@test "No rule accepts traffic from everywhere" {
  checked=0
  for hostname in $(nodes); do
    for rule in $(rules "$hostname" | cut -d' ' -f1); do
      accepted=$(subnets "$hostname" "$rule")
      [ -n "$accepted" ]
      # Networks that together hold as many addresses as there are, such as two /1s, are everyone
      # too, prefix 0 or not.
      addresses=0
      for network in $accepted; do
        addresses=$((addresses + (1 << (32 - ${network#*/}))))
      done
      if ((addresses >= 1 << 32)); then
        echo "$hostname: $rule accepts everyone"
        return 1
      fi
      checked=$((checked + 1))
    done
  done
  [ "$checked" -gt 6 ]
}

@test "No operator address is in any committed file, and the allowlist reaches the configuration through the generated file" {
  # The files git would commit that the check reads, copied so the fixture's allowlist can change; a
  # cluster's own directory under talos/, with its secrets bundle, is not among them.
  copy="$BATS_TEST_TMPDIR/repository"
  while IFS= read -r -d '' path; do
    if [[ $path == talos/*/* && $path != talos/patches/* ]]; then
      continue
    fi
    if [[ -f $ROOT/$path ]]; then
      mkdir -p "$copy/$(dirname "$path")"
      cp "$ROOT/$path" "$copy/$path"
    fi
  done < <(git -C "$ROOT" ls-files -z --cached --others --exclude-standard -- scripts talos versions.yaml tests/fixtures/talos)
  network=198.51.100.128/25
  for old in $(yq '.operator_cidrs[]' "$FIXTURE"); do
    [ "$old" != "$network" ]
  done
  yq -i ".operator_cidrs = [\"${network}\"]" "$copy/tests/fixtures/talos/inputs.yaml"
  encoded=$(tofu -chdir="$copy/tests/fixtures/talos" console -no-color <<< 'base64encode(local.talman_yaml)')
  talman=$(base64 -d <<< "${encoded//\"/}")

  run "$copy/scripts/talos-check" "$BATS_TEST_TMPDIR/rendered"

  [ "$status" -eq 0 ]
  for role in controlplane worker; do
    [ "$(yq ".values.firewall.${role}[] | select(.name == \"apid\") | .subnets[] | select(. == \"$network\")" <<< "$talman")" = "$network" ]
  done
  for hostname in $(nodes); do
    yq -N 'select(.kind == "NetworkRuleConfig" and .name == "apid") | .ingress[].subnet' "$BATS_TEST_TMPDIR/rendered/$hostname.yaml" |
      grep -qxF "$network"
  done
  for hostname in $(nodes controlplane); do
    yq -N 'select(.kind == "NetworkRuleConfig" and .name == "kube-apiserver") | .ingress[].subnet' "$BATS_TEST_TMPDIR/rendered/$hostname.yaml" |
      grep -qxF "$network"
  done
  # Neither the old allowlist nor any other address is written into talos/: only the wildcard a
  # listener binds to and the loopback address, which no operator has.
  addresses=$(git -C "$ROOT" ls-files -z --cached --others --exclude-standard -- talos |
    (cd "$ROOT" && xargs -0 grep -ohE '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b') | sort -u || true)
  echo "addresses in talos/: $(paste -sd' ' <<< "${addresses:-none}")"
  [ -z "$(awk '!/^(0\.0\.0\.0|127(\.[0-9]+){3})$/' <<< "$addresses")" ]
  git -C "$ROOT" check-ignore --no-index -q talos/lab-sto2/talman.yaml
  git -C "$ROOT" check-ignore --no-index -q operator-cidrs.json
}
