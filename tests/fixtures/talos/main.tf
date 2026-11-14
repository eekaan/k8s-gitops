# talos/talman.yaml.tftpl rendered from inputs.yaml and the repository's versions.yaml. There are
# no providers, resources or backend, so tofu console evaluates it without init and without state.

locals {
  root     = "${path.module}/../../.."
  versions = yamldecode(file("${local.root}/versions.yaml"))

  talman_yaml = templatefile("${local.root}/talos/talman.yaml.tftpl", merge(yamldecode(file("${path.module}/inputs.yaml")), {
    talos_version      = local.versions.talos
    kubernetes_version = local.versions.kubernetes
  }))
}
