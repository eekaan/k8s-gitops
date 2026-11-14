# A stand-in for the cluster stack: the two inputs it takes from the environment, and the flavors
# os-smoke looks for. The recipe tests run against it with a recording tofu; it is never planned.

variable "api_allowed_cidrs" {
  description = "Operator networks allowed to reach the cluster's APIs."
  type        = list(string)
  sensitive   = true
}

variable "plumbing_state" {
  description = "The s3 backend settings of the plumbing stack's state."
  type        = any
}

variable "control_plane_flavor" {
  description = "Flavor of the control-plane nodes."
  type        = string
  default     = "fixture.flavor-a"
}

variable "worker_flavor" {
  description = "Flavor of the worker nodes."
  type        = string
  default     = "fixture.flavor-b"
}
