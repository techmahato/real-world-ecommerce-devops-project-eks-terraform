terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # `time_sleep` lets us pause between cluster creation and node-group
    # creation so before_compute add-ons (vpc-cni, kube-proxy) can land
    # before the data plane comes up. Without this gap, brand-new nodes
    # can register before vpc-cni is ready and fail to get a pod CIDR.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}
