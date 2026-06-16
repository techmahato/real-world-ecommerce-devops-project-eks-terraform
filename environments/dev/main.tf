# =============================================================================
#  Dev Environment — Composition
#  ---------------------------------------------------------------------------
#  This file is intentionally thin: it wires user-facing variables into the
#  network module and adds environment-level concerns (tags). All design
#  decisions live in the module itself.
#
#  Variables not listed here keep the module's defaults — opt-in whenever
#  you need to override a knob from tfvars.
# =============================================================================

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

module "network" {
  source = "../../modules/network"

  # Identity
  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones

  # NAT Gateway mode — dev defaults: single shared NAT (cost over HA)
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = var.one_nat_gateway_per_az

  # Flow logs
  enable_flow_logs            = var.enable_flow_logs
  flow_logs_destination       = var.flow_logs_destination
  flow_logs_retention_days    = var.flow_logs_retention_days
  flow_logs_s3_lifecycle_days = var.flow_logs_s3_lifecycle_days

  # Defense-in-depth NACLs
  enable_dedicated_nacls = var.enable_dedicated_nacls

  # VPC endpoints — saves NAT cost + improves security
  enable_vpc_endpoints             = var.enable_vpc_endpoints
  enable_s3_gateway_endpoint       = var.enable_s3_gateway_endpoint
  enable_dynamodb_gateway_endpoint = var.enable_dynamodb_gateway_endpoint
  interface_endpoint_services      = var.interface_endpoint_services

  tags = local.common_tags
}
