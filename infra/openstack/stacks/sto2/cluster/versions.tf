# The S3 backend is left empty here and configured when the stack is initialised for an apply;
# the infrastructure check initialises without a backend.
terraform {
  required_version = ">= 1.8.0, < 2.0.0"

  backend "s3" {}

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
  }
}
