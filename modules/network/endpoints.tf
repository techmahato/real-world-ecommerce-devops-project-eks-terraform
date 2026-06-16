# =============================================================================
#  VPC Endpoints
#  ---------------------------------------------------------------------------
#  An EKS workload calls AWS APIs constantly:
#    • ECR API + ECR DKR for image pulls
#    • STS for IRSA token exchange (every Pod refresh)
#    • CloudWatch Logs for log shipping
#    • Secrets Manager for External Secrets Operator
#    • SSM for Session Manager / parameter store
#
#  Without VPC endpoints, every one of these calls follows this path:
#
#      pod → private subnet → NAT Gateway → IGW → public Internet → AWS API
#
#  Two costs hit on that path:
#    1. NAT data-transfer ($0.045/GB processed by the NAT)
#    2. Internet egress for the response
#
#  With VPC endpoints, the path becomes:
#
#      pod → private subnet → ENI in private subnet → AWS backbone → AWS API
#
#  No NAT, no IGW, no Internet. Cheaper, faster, more secure.
#
#  Endpoint types in this file:
#    • Gateway endpoints  — S3 (and DynamoDB, optional). Free. Just a route.
#    • Interface endpoints — One ENI per AZ. ~$0.01/hr/AZ + $0.01/GB.
#                            Worth it the moment NAT egress for that service
#                            exceeds ~$10/month.
#
#  All endpoints are gated by `var.enable_vpc_endpoints` (default true).
# =============================================================================

locals {
  endpoints_enabled = var.enable_vpc_endpoints

  # Build a fully-qualified service name for each requested interface
  # endpoint. We use the AWS region that's actually deployed (data source),
  # not a variable, so the module Just Works in any region.
  interface_services = local.endpoints_enabled ? toset(var.interface_endpoint_services) : toset([])
}

# Region of the current provider — used to construct service names like
# `com.amazonaws.<region>.ecr.api`.
data "aws_region" "current" {}

# =============================================================================
#  ENDPOINT SECURITY GROUP
#  ---------------------------------------------------------------------------
#  Interface endpoints attach an ENI in each subnet — that ENI needs an SG.
#  We allow HTTPS from the entire VPC CIDR. AWS APIs are HTTPS-only and the
#  endpoint terminates TLS, so this is the minimum required surface.
# =============================================================================

resource "aws_security_group" "endpoints" {
  count = local.endpoints_enabled && length(var.interface_endpoint_services) > 0 ? 1 : 0

  name        = "${local.name_prefix}-vpc-endpoints"
  description = "HTTPS access from the VPC to interface VPC endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from anywhere in the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound (endpoint to AWS service)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-vpc-endpoints"
  }
}

# =============================================================================
#  GATEWAY ENDPOINTS — S3 (free)
#  ---------------------------------------------------------------------------
#  A gateway endpoint is just a route table entry pointing to an AWS-managed
#  prefix list. Attach it to every route table that should be able to reach
#  S3 without leaving the VPC.
#
#  Why attach to private + database route tables?
#    • Private: ECR image layers are stored in S3. Pulling images via the
#               S3 endpoint avoids the NAT — by far the biggest single
#               source of NAT data-transfer cost in EKS clusters.
#    • Database: RDS uses S3 for automated backups and engine logs.
# =============================================================================

resource "aws_vpc_endpoint" "s3" {
  count = local.endpoints_enabled && var.enable_s3_gateway_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"

  # Attach to private (one RT per AZ) and database (single RT) route tables.
  # Public RT does not need it — public subnets already reach S3 via the IGW.
  route_table_ids = concat(
    aws_route_table.private[*].id,
    [aws_route_table.database.id],
  )

  tags = {
    Name = "${local.name_prefix}-s3-endpoint"
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  count = local.endpoints_enabled && var.enable_dynamodb_gateway_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    aws_route_table.private[*].id,
    [aws_route_table.database.id],
  )

  tags = {
    Name = "${local.name_prefix}-dynamodb-endpoint"
  }
}

# =============================================================================
#  INTERFACE ENDPOINTS
#  ---------------------------------------------------------------------------
#  One endpoint per service, with one ENI in each private subnet. Private DNS
#  is enabled so workloads can call the regular AWS endpoint hostname (e.g.
#  `sts.amazonaws.com`) and have it resolve to the private endpoint IP.
# =============================================================================

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_services

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true

  tags = {
    Name = "${local.name_prefix}-${replace(each.key, ".", "-")}-endpoint"
  }
}
