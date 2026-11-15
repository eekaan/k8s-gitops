# shellcheck shell=bash
# The shapes the API server requires of the names the kubernetes/ tree and its charts hold, shared
# by scripts/render and scripts/kubernetes-validate so that what one lets through the other does
# too: an API group (a DNS subdomain), a version (a DNS-1035 label), a kind, an apiVersion and a
# namespace (a DNS label). Each pattern is anchored at the true start and end of the string: a
# plain $ also matches before a final line break, which would let a value that ends in one pass a
# check and then be dropped, or read as two values, further on.
#
# Exported, for jq's env and yq's strenv. shapes_jq prints, for jq programs:
#   shaped($re)   a string that matches $re whole and holds no control character;
#   crd_shaped    a CustomResourceDefinition whose group, kind and versions have the shapes above.
export group_re='\A[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*\z'
export version_re='\A[a-z]([-a-z0-9]{0,61}[a-z0-9])?\z'
export kind_re='\A[A-Za-z][A-Za-z0-9]{0,62}\z'
export api_re='\A([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*/)?[a-z]([-a-z0-9]{0,61}[a-z0-9])?\z'
export label_re='\A[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\z'

# shellcheck disable=SC2016 # $re is a jq variable.
shapes_jq() {
  printf '%s' 'def shaped($re): type == "string" and test($re) and (test("[[:cntrl:]]") | not);
  def crd_shaped:
    (.spec | type) == "object"
    and (.spec.group | shaped(env.group_re)) and (.spec.group | length) <= 253
    and ((.spec.names | type) == "object") and (.spec.names.kind | shaped(env.kind_re))
    and (((.spec.versions // []) | type) == "array")
    and ([(.spec.versions // [])[] | type == "object" and (.name | shaped(env.version_re))] | all);
'
}
