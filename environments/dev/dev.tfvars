# =============================================================================
#  Dev environment values
#  ---------------------------------------------------------------------------
#  Cost-optimized: single NAT, short CW retention. All hardening features
#  on by default to mirror production posture and catch misconfigurations
#  early ("test like you fly").
# =============================================================================

aws_region         = "ap-south-1"
project_name       = "ecommerce-eks"
environment        = "dev"
vpc_cidr           = "10.10.0.0/16"
availability_zones = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
owner              = "platform-team"

# NAT: cheap-and-cheerful for dev
single_nat_gateway     = true
one_nat_gateway_per_az = false

# Flow logs to CloudWatch (easier to query during development)
enable_flow_logs         = true
flow_logs_destination    = "cloud-watch-logs"
flow_logs_retention_days = 30

# Hardening on — same posture as prod
enable_dedicated_nacls = true
enable_vpc_endpoints   = true
