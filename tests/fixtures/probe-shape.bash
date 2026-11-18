# What tests/probes.bats and tests/node-listeners.bats both hold of the tree's Probes, so that the
# two read them alike: where a Probe's prober and its targets are, its one relabeling, and the
# modules it may name. Loaded with `load fixtures/probe-shape` from a test file. The functions read
# a render scripts/render made, a directory to each application, and need yq, jq and sha256sum.
# shellcheck shell=bash disable=SC2034 # the values are read by the files that load this one

# The version of Envoy Gateway in whose source the rule for the name of the proxies' Service was
# read, and that their pods are on the pod network: internal/infrastructure/kubernetes/proxy/
# resource_provider.go builds the proxies' Deployment and DaemonSet with a pod spec that does not
# set hostNetwork, and only a patch, which the controller applies, changes the spec it builds: one of
# the EnvoyProxy the Gateway or its class names, or of the default EnvoyProxy the controller's
# configuration holds (api/v1alpha1/shared_types.go, KubernetesPatchSpec, and envoygateway_types.go).
# tests/probes.bats fails while the cluster runs another version.
PROXY_SERVICE_READ_AT=v1.10.0

# The one relabeling of each Probe of the tree: the label hostname, as it is, becomes the parameter
# hostname, for which the exporter sets the Host header and the name TLS verifies.
PROBE_RELABELINGS='[{"action":"replace","sourceLabels":["hostname"],"targetLabel":"__param_hostname"}]'

# The exporter's modules, each of which tests/probes.bats pins whole, all of the http prober.
PROBE_MODULES='["public_http_redirect","public_https","public_https_signin"]'

# controller_namespace DIR: the namespace of Envoy Gateway's controller in DIR, the render of one
# cluster: that of the one Deployment of the application envoy-gateway. The controller makes the
# proxies' objects of every Gateway there unless its configuration's provider.kubernetes.deploy.type
# is GatewayNamespace (GetResourceNamespace in internal/infrastructure/kubernetes/proxy_infra.go,
# at PROXY_SERVICE_READ_AT); in that mode they take the Gateway's namespace and another name, for
# which proxy_service_name's rule was not read, so it fails.
controller_namespace() {
  local config mode
  local -a namespaces
  config="$(yq -N 'select(.kind == "ConfigMap" and .data["envoy-gateway.yaml"] != null) | .data["envoy-gateway.yaml"]' "$1"/envoy-gateway/ConfigMap_*.yaml)"
  [ -n "$config" ] || { echo "no configuration of Envoy Gateway's controller in $1" >&2; return 1; }
  mode="$(yq '.provider.kubernetes.deploy.type // "ControllerNamespace"' <<<"$config")"
  [ "$mode" = ControllerNamespace ] ||
    { echo "Envoy Gateway's controller in $1 deploys the proxies in the mode $mode, for which the rule for their Service's name was not read" >&2; return 1; }
  mapfile -t namespaces < <(yq -N 'select(.kind == "Deployment") | .metadata.namespace' "$1"/envoy-gateway/Deployment.apps_*.yaml)
  [ "${#namespaces[@]}" -eq 1 ] || { echo "not one Deployment of Envoy Gateway's controller in $1" >&2; return 1; }
  echo "${namespaces[0]}"
}

# proxy_service_name NAMESPACE NAME CONTROLLER: the cluster name of the Service Envoy Gateway makes
# for the proxies of the Gateway NAME in NAMESPACE, with its controller in the namespace CONTROLLER:
# envoy-<namespace>-<name>-<the first 8 characters of the SHA-256 of "<namespace>/<name>">, in the
# controller's namespace (Envoy Gateway's GetHashedName, which cuts the readable part at 48
# characters, a cut for which this fails; the names here are far shorter). It is the name the
# controller gives the proxies' objects where the EnvoyProxy names no Service of its own
# (internal/infrastructure/kubernetes/proxy/resource_provider.go and resource.go,
# internal/utils/misc.go, at PROXY_SERVICE_READ_AT).
proxy_service_name() {
  [ "$((${#1} + ${#2} + 1))" -le 48 ] ||
    { echo "the Gateway $1/$2 has a name past the 48 characters Envoy Gateway keeps of it, for which the rule for its proxies' Service's name was not read" >&2; return 1; }
  echo "envoy-$1-$2-$(printf '%s/%s' "$1" "$2" | sha256sum | cut -c1-8).$3.svc.cluster.local"
}

# exporter_service DIR: where a Probe reaches the exporter in DIR, the render of one cluster: the one
# Service of the exporter's release by its cluster name, and its one port.
exporter_service() {
  local services
  services="$(yq -N -o json -I0 'select(.kind == "Service")' "$1"/blackbox-exporter/Service_*.yaml 2>/dev/null | jq -cs .)"
  [ "$(jq 'length' <<<"$services")" -eq 1 ] || { echo "not one Service of the release blackbox-exporter in $1" >&2; return 1; }
  [ "$(jq '.[0].spec.ports | length' <<<"$services")" -eq 1 ] || { echo "not one port of the Service of the release blackbox-exporter in $1" >&2; return 1; }
  jq -r '.[0] | "\(.metadata.name).\(.metadata.namespace).svc.cluster.local:\(.spec.ports[0].port)"' <<<"$services"
}
