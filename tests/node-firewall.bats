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
  for role in controlplane worker; do
    wanted=$(listeners "$role")
    [ -n "$wanted" ]
    for hostname in $(nodes "$role"); do
      echo "$hostname has: $(rules "$hostname" | paste -sd';' -)"
      diff <(echo "$wanted") <(rules "$hostname")
    done
  done
  [ "$(listeners controlplane)" != "$(listeners worker)" ]
  # Names are what Talos tells rules apart by, so none may be given twice.
  [ -z "$(yq '.listeners[].name' "$INVENTORY" | sort | uniq -d)" ]
  [ -n "$(table)" ]
  diff <(inventory) <(table)
}

@test "The Talos API and the Kubernetes API accept the operator allowlist, the node network and the load balancer, and nobody else" {
  operators=$(yq '.operator_cidrs[]' "$FIXTURE")
  [ "$(wc -l <<< "$operators")" -eq 2 ]
  node_subnet=$(yq '.node_subnet' "$FIXTURE")
  pod_subnet=$(yq '.pod_subnet' "$FIXTURE")
  floating=$(yq '.nodes[].floating_ip + "/32"' "$FIXTURE")
  [ "$(wc -l <<< "$floating")" -eq 6 ]
  talos_api=$(printf '%s\n' "$operators" "$node_subnet" "$floating" | sort -u)
  kubernetes_api=$(printf '%s\n' "$talos_api" "$pod_subnet" | sort -u)
  # The load balancer connects to the API servers from its own addresses on the node network.
  endpoint=$(yq '.endpoint' "$FIXTURE")
  [[ $endpoint =~ ^https://([0-9.]+):6443$ ]]
  in_subnet "${BASH_REMATCH[1]}" "$node_subnet"
  outside=$(printf '%s\n' "$operators" "$floating")

  for hostname in $(nodes); do
    diff <(echo "$talos_api") <(subnets "$hostname" apid)
    [ "$(rules "$hostname" | grep -c '^apid tcp 50000$')" -eq 1 ]
    for rule in $(rules "$hostname" | cut -d' ' -f1 | grep -vx -e apid -e kube-apiserver); do
      [ -z "$(comm -12 <(sort <<< "$outside") <(subnets "$hostname" "$rule"))" ]
    done
  done
  for hostname in $(nodes controlplane); do
    diff <(echo "$kubernetes_api") <(subnets "$hostname" kube-apiserver)
    [ "$(rules "$hostname" | grep -c '^kube-apiserver tcp 6443$')" -eq 1 ]
  done
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
      if grep -E '/0$' <<< "$accepted"; then
        echo "$hostname: $rule accepts everyone"
        return 1
      fi
      checked=$((checked + 1))
    done
  done
  [ "$checked" -gt 6 ]
}

@test "No operator address is in any committed file, and the allowlist reaches the configuration through the generated file" {
  # The files git would commit that the check reads, copied so the fixture's allowlist can change.
  copy="$BATS_TEST_TMPDIR/repository"
  while IFS= read -r -d '' path; do
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
