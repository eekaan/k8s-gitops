# The S3 backend is left empty here and configured when the stack is initialised for an apply;
# the infrastructure check initialises without a backend.
terraform {
  required_version = ">= 1.8.0, < 2.0.0"

  backend "s3" {}

  # State and plans are encrypted with the key provider and method scripts/stack-env passes in
  # TF_ENCRYPTION. Without them tofu refuses to run instead of writing either in plaintext.
  encryption {
    state {
      enforced = true
    }
    plan {
      enforced = true
    }
  }

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.12.0"
    }
  }
}
