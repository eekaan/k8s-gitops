# Build every kustomization under kubernetes/ offline and check the tree's layout rules
kubernetes-check:
    scripts/kubernetes-check

# Render what Flux would apply from kubernetes/ into OUT, one file per object and application, charts expanded, with the example key lists for cluster-config and cluster-secrets and no Secret's data; from the tree in DIR, this checkout by default
render out dir='.':
    scripts/render {{ quote(out) }} {{ quote(dir) }}

# Print, as the Markdown of the pull request comment, what changes between the renders in BASE and HEAD, per application
render-diff base head:
    scripts/render-diff {{ quote(base) }} {{ quote(head) }}
