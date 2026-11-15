# Build every kustomization under kubernetes/ offline and check the tree's layout and dependency rules; fetches nothing, so the publish run gates on it
kubernetes-check:
    scripts/kubernetes-check

# On top of kubernetes-check, which it runs first: validate what Flux builds against its schemas, with unknown fields refused, and fail on an image of the render without a tag other than latest or a digest; fetches the charts and the schemas from their public sources, so the publish run does not run it
kubernetes-validate:
    scripts/kubernetes-validate

# Render kubernetes/ as the CI render job does, charts pulled from their registries, and keep nothing: fails, naming the application, when anything does not render
[script]
render-check:
    out=$(mktemp -d)
    trap 'rm -rf "$out"' EXIT
    scripts/render "$out"

# Render what Flux would apply from kubernetes/ into OUT, one file per object and application, charts expanded, with the example key lists for cluster-config and cluster-secrets and no Secret's data; from the tree in DIR, this checkout by default
render out dir='.':
    scripts/render {{ quote(out) }} {{ quote(dir) }}

# Print, as the Markdown of the pull request comment, what changes between the renders in BASE and HEAD, per application
render-diff base head:
    scripts/render-diff {{ quote(base) }} {{ quote(head) }}
