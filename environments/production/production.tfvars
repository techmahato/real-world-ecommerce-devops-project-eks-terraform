# Production environment values.
# Posture (NACLs, endpoints, hardening) is hardcoded in main.tf for prod parity.
# Only identity and cost-tuning knobs live here.

aws_region         = "ap-south-1"
project_name       = "ecommerce-eks"
environment        = "production"
vpc_cidr           = "10.30.0.0/16"
availability_zones = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
owner              = "platform-team"

# HA: per-AZ NAT, S3 flow logs (cheap long retention).
single_nat_gateway    = false
flow_logs_destination = "s3"
