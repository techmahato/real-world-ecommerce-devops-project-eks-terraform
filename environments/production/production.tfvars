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
single_nat_gateway    = true
flow_logs_destination = "s3"

# Bastion - off by default in prod. SSM-only recommended (no SSH key,
# no SSH CIDRs). Audit trail comes from SSM session logs.
enable_bastion            = false
bastion_instance_type     = "t3.micro"
bastion_ssh_key_name      = "bastion-host"
bastion_allowed_ssh_cidrs = ["49.37.8.68/32"]
