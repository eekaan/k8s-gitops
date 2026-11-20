# shellcheck shell=bash
# Shared by scripts/infra-destroy and scripts/gateway-check: the names the tree's routes publish,
# listed offline from the tree's own builds, and a name's A records at the public resolver. Builds
# on scripts/lib/infra.sh, whose run_tool and curl run the tree's check and the lookups with none of
# the secrets of the caller's environment (scripts/lib/tools.sh). Names under the domain and
# addresses go to the caller on standard output, never to standard error: the callers decide what
# of them to show.

# shellcheck source=scripts/lib/infra.sh
. "$(dirname "${BASH_SOURCE[0]}")/infra.sh"

# The public resolver's JSON interface over HTTPS (docs/kubernetes.md, DNS records).
dns_doh_json=https://dns.google/resolve

# A host name of the tree: lower-case labels of letters, digits and hyphens, two or more, as the
# Gateway API takes a hostname without its wildcard, and a name the resolver's URL can carry as it is.
dns_host_name='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'

# dns_published_names DOMAIN: the names the tree's routes publish, under DOMAIN, one per line,
# sorted byte by byte and unique. They are read from what Flux builds of the tree, as scripts/kubernetes-check
# builds it offline with the example key lists, every application enabled or not, so a name an
# application published before it was disabled is listed too: each HTTPRoute whose parentRefs name
# the Gateway public of envoy-gateway-system, a parent without a namespace being in the route's own.
# Each hostname under the example domain the builds were made with, CLUSTER_DOMAIN of the clusters'
# example key lists merged as kubernetes-check merges them, is that name with DOMAIN in place of the
# example domain; a hostname outside it is skipped, as external-dns makes no record for it, and so is
# a route without hostnames whose every parent on the Gateway is its http listener, the redirect.
# Fails, naming the route, for a hostname with a wildcard or that is no host name, and for a route
# on the Gateway without hostnames on any other listener: either publishes the listener's wildcard.
# Fails too when DOMAIN is not a host name, when the example key lists hold no domain, when
# kubernetes-check fails, whose own words are not shown, and when it passes having kept no record of
# a build. kubernetes-check runs through run_tool, so it sees none of the caller's secrets, and keeps
# its builds in a directory of its own that only this user can enter, removed afterwards; it fetches
# nothing.
dns_published_names() (
  local domain=$1 built example file label routes problems
  local -a examples
  shopt -s nullglob
  if [[ ! $domain =~ $dns_host_name || ${#domain} -gt 253 ]]; then
    infra_error "the domain the names are listed under is not a host name"
    return 1
  fi
  examples=("$infra_root"/kubernetes/clusters/*/cluster-config.example.yaml "$infra_root"/kubernetes/clusters/*/cluster-secrets.example.yaml)
  example=
  if ((${#examples[@]} > 0)); then
    # shellcheck disable=SC2016 # $list is a yq variable.
    example=$(yq ea '. as $list ireduce ({}; . * ($list // {})) | .CLUSTER_DOMAIN // "" | tostring' "${examples[@]}" 2> /dev/null) || example=
  fi
  if [[ ! $example =~ $dns_host_name ]]; then
    infra_error "the clusters' example key lists give no CLUSTER_DOMAIN, the domain the tree's builds name hosts under"
    return 1
  fi
  built=$(umask 077 && mktemp -d) || return 1
  trap 'rm -rf -- "$built"' EXIT
  if ! KUBERNETES_CHECK_BUILT=$built run_tool "$infra_root/scripts/kubernetes-check" "$infra_root" > /dev/null 2>&1; then
    infra_error "scripts/kubernetes-check fails on this tree, so the names its routes publish are not listed; just kubernetes-check says why"
    return 1
  fi
  # What kubernetes-check keeps, N.yaml and builds, is all the directory holds until this file. A
  # check that passes has built the tree, so a record of no build is not read as a tree of no route.
  if [[ ! -s $built/builds ]]; then
    infra_error "scripts/kubernetes-check kept no record of what it built, so the names its routes publish are not listed"
    return 1
  fi
  : > "$built/routes.json"
  while IFS= read -r -d '' file && IFS= read -r -d '' label && IFS= read -r -d '' _; do
    if [[ ! $file =~ ^[0-9]+\.yaml$ || ! -f $built/$file ]]; then
      infra_error "scripts/kubernetes-check kept a build that cannot be read"
      return 1
    fi
    yq -o json -I0 'select(. != null and .kind == "HTTPRoute")' "$built/$file" >> "$built/routes.json" 2> /dev/null || {
      infra_error "a build scripts/kubernetes-check kept cannot be read"
      return 1
    }
  done < "$built/builds"
  # Each route on the Gateway once, as a record: what is wrong with it, or the names it publishes.
  # shellcheck disable=SC2016 # $example, $domain and $pattern are jq variables.
  routes=$(jq -rs --arg example "$example" --arg domain "$domain" --arg pattern "$dns_host_name" '
    def clean: tostring | gsub("[^a-z0-9./-]"; "?");
    [.[] | . as $route | (.metadata.namespace // "") as $namespace
      | [.spec.parentRefs[]? | select(.name == "public" and (.namespace // $namespace) == "envoy-gateway-system"
          and (.kind // "Gateway") == "Gateway" and (.group // "gateway.networking.k8s.io") == "gateway.networking.k8s.io")] as $parents
      | select($parents | length > 0)
      | "\($namespace)/\($route.metadata.name // "")" as $name
      | ($route.spec.hostnames // []) as $hosts
      | if ($hosts | length) == 0 then
          if all($parents[]; .sectionName == "http") then empty
          else "refused the HTTPRoute \($name | clean) on the Gateway public names no hostname, so external-dns would publish the wildcard of a listener it attaches to" end
        elif any($hosts[]; type == "string" and contains("*")) then
          "refused the HTTPRoute \($name | clean) on the Gateway public names a wildcard, which external-dns would publish"
        elif any($hosts[]; type != "string" or (test("\\A" + ($pattern | ltrimstr("^") | rtrimstr("$")) + "\\z") | not)) then
          "refused the HTTPRoute \($name | clean) on the Gateway public names a hostname that is not a lower-case host name"
        else $hosts[] | select(. == $example or endswith("." + $example)) | "name " + rtrimstr($example) + $domain end]
    | unique[]' "$built/routes.json" 2> /dev/null) || {
    infra_error "the routes the tree builds cannot be read"
    return 1
  }
  problems=$(sed -n 's/^refused //p' <<< "$routes")
  if [[ -n $problems ]]; then
    while IFS= read -r label; do
      infra_error "$label"
    done <<< "$problems"
    return 1
  fi
  sed -n 's/^name //p' <<< "$routes" | LC_ALL=C sort -u
)

# dns_resolve_a HOST FILE: the addresses in the A records the public resolver gives for HOST, asked
# over HTTPS for its JSON answer, sorted, one per line. The answer counts only when it is one JSON
# document whose status is NOERROR and whose records are all A records of HOST itself, each one IPv4
# address. Returns 1 when the resolver cannot be asked, 2 when its answer is not readable as that,
# 3 when it says the name does not exist (NXDOMAIN), 4 for any other status, which it prints, and 5
# when a record is of another type or another name, such as a CNAME. HOST is sent to the resolver.
# The resolver's certificate is verified against the system's public trust store as curl has it:
# curl is given none of the variables that would add a bundle or a directory of the caller's
# choosing, and no proxy. The answer stays in FILE, the caller's own file, as a shell variable would
# drop a NUL and say so. Neither curl's errors nor jq's are shown, as they can quote the answer.
dns_resolve_a() {
  local verdict
  rm -f -- "$2"
  (
    unset CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR
    curl --disable --silent --noproxy '*' --connect-timeout 5 --max-time 15 --output "$2" \
      "$dns_doh_json?name=$1&type=A" 2> /dev/null
  ) || return 1
  # shellcheck disable=SC2016 # $name is a jq variable.
  verdict=$(jq -rs --arg name "$1." '
    if length != 1 or (.[0] | type) != "object" then "unreadable"
    else .[0]
      | if (.Status | type) != "number" or .Status != (.Status | floor) or .Status < 0 or .Status > 65535
          or ((.Answer // []) | type) != "array" then "unreadable"
        elif .Status == 3 then "nxdomain"
        elif .Status != 0 then "status \(.Status)"
        elif any(.Answer[]?; .type != 1 or (.name | type) != "string" or (.name | ascii_downcase) != $name) then "foreign"
        elif any(.Answer[]?; (.data | type) != "string" or (.data | test("\\A[0-9]{1,3}(\\.[0-9]{1,3}){3}\\z") | not)) then "unreadable"
        else "ok" end end' "$2" 2> /dev/null) || return 2
  case $verdict in
    ok) jq -r '.Answer[]?.data' "$2" 2> /dev/null | sort -u ;;
    nxdomain) return 3 ;;
    "status "*)
      printf '%s\n' "${verdict#status }"
      return 4
      ;;
    foreign) return 5 ;;
    *) return 2 ;;
  esac
}
