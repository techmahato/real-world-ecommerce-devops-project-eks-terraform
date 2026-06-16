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

# Bastion - turn on when you need a jump box. Set ssh_key_name and
# allowed_ssh_cidrs to enable SSH; otherwise it's SSM-only.
enable_bastion            = true
bastion_instance_type     = "t3.micro"
bastion_ssh_key_name      = "bastion-host.pem" # e.g. "my-key"
bastion_allowed_ssh_cidrs = "0.0.0.0./0"       # e.g. ["203.0.113.42/32"]
