# Render every node's Talos machine configuration from the template, the patches and fixture node data, and validate it, offline
talos-check: tools-check
    scripts/talos-check

# Install Cilium from its application in kubernetes/ on the cluster KUBECONFIG names, before Flux runs
cilium-install:
    scripts/install-cilium
