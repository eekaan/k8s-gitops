# Render every node's Talos machine configuration from the template, the patches and fixture node data, and validate it, offline
talos-check: tools-check
    scripts/talos-check

# Install Cilium from its application in kubernetes/ on the cluster KUBECONFIG names, before Flux runs
cilium-install:
    scripts/install-cilium

# Create the Talos age key at SOPS_AGE_KEY_FILE unless a file is there, and write its recipient into talos/.sops.yaml; prints the recipient
cluster-age-key:
    scripts/cluster-age-key

# Generate a cluster's Talos secrets bundle into talos/<cluster>/secrets.sops.yaml, SOPS-encrypted; refused when the bundle exists
cluster-secrets cluster='lab-sto2':
    scripts/cluster-secrets {{ quote(cluster) }}

# Fail on a secrets.sops.yaml under talos/ that git would commit without SOPS encryption
cluster-secrets-check:
    scripts/cluster-secrets-check
