# =============================================================================
#  Production environment values
# =============================================================================

aws_region         = "ap-south-1"
project_name       = "ecommerce-eks"
environment        = "production"
vpc_cidr           = "10.30.0.0/16"
availability_zones = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
owner              = "platform-team"

# NAT: HA — one per AZ
single_nat_gateway     = false
one_nat_gateway_per_az = true

# Flow logs to S3 (cheap long retention; query with Athena)
enable_flow_logs      = true
flow_logs_destination = "s3"

# Hardening
enable_dedicated_nacls = true
enable_vpc_endpoints   = true
