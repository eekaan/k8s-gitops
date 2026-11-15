# Build every kustomization under kubernetes/ offline and check the tree's layout rules
kubernetes-check:
    scripts/kubernetes-check

# Render kubernetes/ as the CI render job does, charts pulled from their registries, and keep nothing: fails, naming the application, when anything does not render
[script]
render-check:
    out=$(mktemp -d)
    trap 'rm -rf "$out"' EXIT
    scripts/render "$out"

# Check that every namespace enforces the strictest Pod Security level its workloads pass: renders kubernetes/ as render-check does, charts pulled from their registries, and evaluates every pod template in it and in the Flux install against pod-security-exceptions.yaml (docs/kubernetes.md, Pod Security); tests/pod-security.bats runs it as the check of the tree
[script]
pod-security-check:
    out=$(mktemp -d)
    trap 'rm -rf "$out"' EXIT
    scripts/render "$out/render" > /dev/null
    scripts/pod-security-check "$out/render" pod-security-exceptions.yaml versions.yaml

# Render what Flux would apply from kubernetes/ into OUT, one file per object and application, charts expanded, with the example key lists for cluster-config and cluster-secrets and no Secret's data; from the tree in DIR, this checkout by default
render out dir='.':
    scripts/render {{ quote(out) }} {{ quote(dir) }}

# Print, as the Markdown of the pull request comment, what changes between the renders in BASE and HEAD, per application
render-diff base head:
    scripts/render-diff {{ quote(base) }} {{ quote(head) }}
