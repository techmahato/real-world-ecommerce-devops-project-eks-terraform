# =============================================================================
#  Production Environment — Composition
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

  # NAT — per-AZ for HA + cross-AZ cost avoidance
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = var.one_nat_gateway_per_az

  # Flow logs to S3 — cheap long-retention storage for security audits
  enable_flow_logs            = var.enable_flow_logs
  flow_logs_destination       = var.flow_logs_destination
  flow_logs_retention_days    = var.flow_logs_retention_days
  flow_logs_s3_lifecycle_days = var.flow_logs_s3_lifecycle_days

  # Hardening
  enable_dedicated_nacls           = var.enable_dedicated_nacls
  enable_vpc_endpoints             = var.enable_vpc_endpoints
  enable_s3_gateway_endpoint       = var.enable_s3_gateway_endpoint
  enable_dynamodb_gateway_endpoint = var.enable_dynamodb_gateway_endpoint
  interface_endpoint_services      = var.interface_endpoint_services

  tags = local.common_tags
}
