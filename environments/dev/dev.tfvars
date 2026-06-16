# Dev environment values.
# Posture (NACLs, endpoints, hardening) is hardcoded in main.tf for prod parity.
# Only identity and cost-tuning knobs live here.

aws_region         = "ap-south-1"
project_name       = "ecommerce-eks"
environment        = "dev"
vpc_cidr           = "10.10.0.0/16"
availability_zones = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
owner              = "platform-team"

# Cost: single NAT (cheaper, not HA), CloudWatch flow logs (easier to query).
single_nat_gateway    = true
flow_logs_destination = "cloud-watch-logs"
