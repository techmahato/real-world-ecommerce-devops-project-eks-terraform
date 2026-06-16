# =============================================================================
#  Bastion Host - Ubuntu 24.04 jump box for reaching private-tier resources.
#  ---------------------------------------------------------------------------
#  Why have a bastion at all when SSM Session Manager exists?
#
#    SSM is the safer access path - no inbound port 22, no public IP needed,
#    every session is logged to CloudWatch. This module enables SSM by
#    default (IAM role + agent comes pre-installed on Ubuntu 24.04 AMIs).
#
#    SSH is also supported because some workflows need it: kubectl through
#    an SSH tunnel, port-forwarding to RDS for one-off queries with a GUI
#    client, or copying files via scp. SSH access is OFF by default - it
#    only opens when the caller passes `allowed_ssh_cidrs` AND `ssh_key_name`.
#
#  Hardening applied unconditionally:
#    - IMDSv2 required (mitigates SSRF-based credential theft)
#    - EBS encryption enabled
#    - Detailed monitoring on (better observability for a low-volume host)
#    - Default SG (locked down by network module) is NOT used; we attach
#      a purpose-built SG with the minimum necessary rules.
# =============================================================================

locals {
  name_prefix = "${var.project_name}-${var.environment}-bastion"

  # SSH ingress is conditionally created. We need both:
  #   1. At least one allowed CIDR
  #   2. An EC2 key pair to authenticate
  # If either is missing, SSH is effectively disabled (SSM-only mode).
  ssh_enabled = length(var.allowed_ssh_cidrs) > 0 && var.ssh_key_name != null
}

# =============================================================================
#  AMI LOOKUP - latest Ubuntu 24.04 LTS via SSM public parameter
#  ---------------------------------------------------------------------------
#  Canonical publishes a public SSM parameter that always points at the
#  current AMI ID for every region. Using this avoids:
#    - Hardcoding region-specific AMI IDs
#    - Stale AMIs missing recent security patches
# =============================================================================

data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

# =============================================================================
#  IAM - Instance Profile for SSM Session Manager
#  ---------------------------------------------------------------------------
#  Three pieces, all required:
#    1. Role with assume-role policy for ec2 service
#    2. Attach AWS-managed policy AmazonSSMManagedInstanceCore (lets the
#       SSM agent register, send heartbeats, and accept sessions)
#    3. Instance profile that wraps the role (EC2 only consumes profiles)
# =============================================================================

resource "aws_iam_role" "bastion" {
  name = "${local.name_prefix}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# AWS-managed policy. Bundles every API call SSM agent needs:
# ssmmessages:*, ec2messages:*, ssm:UpdateInstanceInformation, etc.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Optional: allow describing tagged EC2 / EKS / RDS resources from the bastion.
# Keeping this scoped: read-only, no write actions, no secrets access. If you
# need more, attach additional policies in the env composition rather than
# bloating this module.
resource "aws_iam_role_policy" "describe_only" {
  name = "${local.name_prefix}-describe-only"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:Describe*",
        "eks:Describe*",
        "eks:List*",
        "rds:Describe*",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${local.name_prefix}-profile"
  role = aws_iam_role.bastion.name
}

# =============================================================================
#  SECURITY GROUP
#  ---------------------------------------------------------------------------
#  Inbound rules:
#    - Port 22 from allowed_ssh_cidrs   (only when SSH is enabled)
#  Outbound rules:
#    - All to VPC CIDR    (so bastion can SSH/port-forward to private hosts)
#    - 443 to internet    (apt updates, pulling tools, SSM agent)
#    - 80  to internet    (some apt mirrors still use HTTP)
# =============================================================================

resource "aws_security_group" "bastion" {
  name        = local.name_prefix
  description = "Bastion host - SSH from operator IPs, SSM via outbound HTTPS"
  vpc_id      = var.vpc_id

  tags = {
    Name = local.name_prefix
    Role = "bastion"
  }
}

# SSH ingress - only when both CIDRs and a key pair are supplied
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = local.ssh_enabled ? toset(var.allowed_ssh_cidrs) : toset([])

  security_group_id = aws_security_group.bastion.id
  description       = "SSH from operator IPs"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22

  tags = {
    Name = "${local.name_prefix}-ssh-${replace(each.value, "/", "-")}"
  }
}

# Outbound to VPC - bastion needs to reach private workloads
resource "aws_vpc_security_group_egress_rule" "to_vpc" {
  security_group_id = aws_security_group.bastion.id
  description       = "All outbound to VPC (reach private workloads)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"

  tags = {
    Name = "${local.name_prefix}-egress-vpc"
  }
}

# Outbound HTTPS - SSM agent backhaul, apt over https, awscli, etc.
resource "aws_vpc_security_group_egress_rule" "https_internet" {
  security_group_id = aws_security_group.bastion.id
  description       = "HTTPS to internet (SSM, apt, awscli)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = {
    Name = "${local.name_prefix}-egress-https"
  }
}

# Outbound HTTP - some apt mirrors still serve metadata over plain HTTP.
# Trade-off: mildly weakens "no plaintext egress" posture, but is the path
# of least resistance for keeping the box patched.
resource "aws_vpc_security_group_egress_rule" "http_internet" {
  security_group_id = aws_security_group.bastion.id
  description       = "HTTP to internet (apt mirror metadata)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80

  tags = {
    Name = "${local.name_prefix}-egress-http"
  }
}

# =============================================================================
#  THE INSTANCE
#  ---------------------------------------------------------------------------
#  Hardening pieces at a glance:
#    - metadata_options.http_tokens = required  -> IMDSv2 only
#    - metadata_options.http_put_response_hop_limit = 1 -> blocks pod-style
#      sidecar abuse (containers can't reach IMDS through the host)
#    - root_block_device.encrypted = true       -> EBS at-rest encryption
#    - monitoring = true                         -> CloudWatch detailed metrics
#    - user_data installs SSM agent + AWS CLI on first boot
#
#  We use a single aws_instance, not an Auto Scaling Group. A bastion is
#  pet, not cattle - if it dies, you lose 30 seconds re-applying. Adding
#  an ASG for "high availability" of a jump box is over-engineering.
# =============================================================================

resource "aws_instance" "bastion" {
  ami           = data.aws_ssm_parameter.ami.value
  instance_type = var.instance_type
  subnet_id     = var.subnet_id

  # SSH key is optional - SSM works without it. Setting key_name to a
  # nonexistent value would error, so we conditionally pass null.
  key_name = var.ssh_key_name

  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = var.associate_public_ip
  monitoring                  = true

  # IMDSv2 enforcement. v1 (the legacy IMDS) is the source of nearly every
  # SSRF -> credential-theft incident in EC2's history. Blocking it is free.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true

    tags = {
      Name = "${local.name_prefix}-root"
    }
  }

  # First-boot setup. Ubuntu 24.04 includes snap-based amazon-ssm-agent by
  # default; we ensure it is enabled and install the AWS CLI + kubectl so
  # the bastion is useful for EKS work the moment it boots.
  user_data = <<-EOT
    #!/bin/bash
    set -eux

    # Make sure SSM agent is running (it is, on official Ubuntu AMIs, but
    # this is belt-and-braces for hardened or custom AMIs).
    snap list amazon-ssm-agent || snap install amazon-ssm-agent --classic
    systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true

    # Common operator tools
    apt-get update -y
    apt-get install -y --no-install-recommends \
      awscli \
      jq \
      unzip \
      net-tools \
      postgresql-client \
      mysql-client \
      redis-tools

    # kubectl (latest stable)
    curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x /usr/local/bin/kubectl
  EOT

  user_data_replace_on_change = false

  lifecycle {
    # Don't recreate the bastion when AWS publishes a new AMI - that would
    # destroy any local state on the box. Recreate explicitly by tainting.
    ignore_changes = [ami]
  }

  tags = {
    Name = local.name_prefix
    Role = "bastion"
  }
}

# =============================================================================
#  ELASTIC IP - stable address survives stop/start cycles
#  ---------------------------------------------------------------------------
#  An EIP costs ~$0/mo while attached to a running instance, ~$3.60/mo
#  while detached or while the instance is stopped. For an on-demand bastion
#  you stop most days, the cost is negligible vs the convenience of a
#  permanent IP for SSH config and firewall allow-lists.
# =============================================================================

resource "aws_eip" "bastion" {
  count    = var.associate_public_ip ? 1 : 0
  domain   = "vpc"
  instance = aws_instance.bastion.id

  tags = {
    Name = "${local.name_prefix}-eip"
  }

  # EIP needs the IGW route to exist before it can attach to a public-subnet
  # instance. The network module creates the IGW; if you ever introduce a
  # race here, an explicit depends_on on the IGW resource fixes it.
}
