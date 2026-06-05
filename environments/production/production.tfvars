aws_region         = "ap-south-1"
project_name       = "ecommerce-eks"
environment        = "production"
vpc_cidr           = "10.30.0.0/16"
availability_zones = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
owner              = "platform-team"

# Production: enable flow logs for security/audit + 90-day retention.
enable_flow_logs = true
