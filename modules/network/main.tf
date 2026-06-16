# =============================================================================
#  Network Module — 3-Tier VPC Architecture
#  ---------------------------------------------------------------------------
#  Tiers (one set of subnets per AZ):
#    1. PUBLIC    — ALB, NAT Gateway, bastion. Has IGW route.
#    2. PRIVATE   — App / EKS nodes. Outbound via NAT, no inbound from Internet.
#    3. DATABASE  — RDS, ElastiCache. NO Internet route at all (isolated).
#
#  CIDR layout (with a /16 input):
#    Public  : cidrsubnet(/16, 4, 0..3)   → /20 each, slots  0..3
#    Private : cidrsubnet(/16, 4, 4..7)   → /20 each, slots  4..7
#    Database: cidrsubnet(/16, 4, 8..11)  → /20 each, slots  8..11
#  (Up to 4 AZs supported per tier without changing the math.)
# =============================================================================

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  az_count    = length(var.availability_zones)

  # Carve /20 subnets out of the /16 VPC CIDR. 3 contiguous slots per tier.
  public_subnets   = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets  = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 4)]
  database_subnets = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  # ── NAT Gateway count ────────────────────────────────────────────────────
  # Three modes, controlled by explicit booleans (NOT by environment name —
  # a module shouldn't know what the caller calls their environments):
  #
  #   single_nat_gateway     = true   → 1 NAT total           (cheapest, dev)
  #   one_nat_gateway_per_az = true   → 1 NAT per AZ          (HA, prod)
  #   both false                      → no NAT                (private-only VPCs,
  #                                                            e.g. pure VPC-endpoint
  #                                                            architectures)
  #
  # `single_nat_gateway` wins if both are accidentally true — a single NAT
  # is the safer fallback (works, just isn't HA). A loud failure would be
  # nicer here; consider promoting this to a `precondition` block.
  nat_count = (
    var.single_nat_gateway ? 1 :
    var.one_nat_gateway_per_az ? local.az_count :
    0
  )
}

# ── VPC ─────────────────────────────────────────────────────────────────────
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

# ── Internet Gateway (only the public tier uses this) ──────────────────────
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# =============================================================================
#  DEFAULTS: lock down the VPC's "default" NACL and SG.
#  ---------------------------------------------------------------------------
#  When AWS creates a VPC it auto-creates a default Network ACL (allow-all)
#  and default Security Group (intra-SG-allow). Anything that lands in those
#  by accident (e.g. a future subnet a teammate forgets to wire up) inherits
#  the permissive policy.
#
#  Best practice: Terraform-manages these as no-rule resources. Doing so
#  *imports* them into state and drops their rules to "deny by default."
#  This is invisible until something tries to use the default — at which
#  point traffic fails closed instead of open.
#
#  Note: tflint's aws_default rule is satisfied by these blocks.
# =============================================================================

resource "aws_default_network_acl" "this" {
  default_network_acl_id = aws_vpc.this.default_network_acl_id

  # No ingress / egress rules → fully closed. If you ever attach a subnet
  # to the default NACL, traffic will fail and the misconfiguration surfaces
  # immediately rather than silently succeeding.
  tags = {
    Name = "${local.name_prefix}-default-nacl-locked"
  }

  # Subnet associations are managed by aws_network_acl_association elsewhere
  # — never let Terraform try to fight the per-tier NACLs over ownership.
  lifecycle {
    ignore_changes = [subnet_ids]
  }
}

resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  # No ingress / egress → default SG is unusable. Workloads must use a
  # purpose-built SG that explicitly declares what they accept.
  tags = {
    Name = "${local.name_prefix}-default-sg-locked"
  }
}

# =============================================================================
#  TIER 1 — PUBLIC (ALB, NAT, bastion)
# =============================================================================

resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnets[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${local.name_prefix}-public-${count.index}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
    Tier = "public"
  }
}

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── EIP + NAT Gateway (lives in public subnets, serves private tier) ───────
# Allocates `local.nat_count` Elastic IPs and NAT Gateways. EIPs are charged
# per hour they exist (free only when attached to a running resource), so
# `nat_count = 0` is the right call for fully-private architectures that
# rely on VPC endpoints alone.
resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip-${count.index}"
  }
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${local.name_prefix}-nat-${count.index}"
  }

  # NAT depends on a routable IGW being attached — without this, the first
  # `terraform apply` can race and create NATs that briefly can't egress.
  depends_on = [aws_internet_gateway.this]
}

# =============================================================================
#  TIER 2 — PRIVATE (Apps / EKS nodes)
# =============================================================================

resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnets[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name                              = "${local.name_prefix}-private-${count.index}"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# One route table per AZ. Each points to its own NAT (per-AZ mode) OR the
# single shared NAT (single-NAT mode) OR has no default route at all (NAT
# disabled — workloads must rely on VPC endpoints for AWS APIs and have no
# arbitrary Internet egress).
#
# Per-AZ NAT in production avoids cross-AZ data-transfer charges: a pod in
# AZ-a egresses through the NAT in AZ-a, never traversing AZ-b's network.
resource "aws_route_table" "private" {
  count = local.az_count

  vpc_id = aws_vpc.this.id

  # Conditional default route. When `nat_count = 0` we emit no route block
  # at all, leaving the table free of a 0.0.0.0/0 entry — same behavior as
  # the database tier.
  dynamic "route" {
    for_each = local.nat_count > 0 ? [1] : []
    content {
      cidr_block = "0.0.0.0/0"
      # Index resolution:
      #   single NAT → always index 0
      #   per-AZ NAT → index = current AZ position
      nat_gateway_id = aws_nat_gateway.this[
        var.single_nat_gateway ? 0 : count.index
      ].id
    }
  }

  tags = {
    Name = "${local.name_prefix}-private-rt-${count.index}"
    Tier = "private"
  }
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# =============================================================================
#  TIER 3 — DATABASE (RDS, ElastiCache — fully isolated from Internet)
# =============================================================================

resource "aws_subnet" "database" {
  count = local.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.database_subnets[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${local.name_prefix}-database-${count.index}"
    Tier = "database"
  }
}

# Database route table — DELIBERATELY NO 0.0.0.0/0 ROUTE.
# Database subnets can only talk to other VPC resources (via the VPC's
# implicit local route). Anything outside the VPC requires a VPC endpoint
# or peering — added intentionally, never by accident.
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-database-rt"
    Tier = "database"
  }
}

resource "aws_route_table_association" "database" {
  count = local.az_count

  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database.id
}

# ── DB subnet group (consumed by RDS / Aurora / DocumentDB modules) ───────
resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = aws_subnet.database[*].id

  tags = {
    Name = "${local.name_prefix}-db-subnet-group"
  }
}

# ── ElastiCache subnet group (consumed by Redis / Memcached modules) ──────
resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name_prefix}-cache-subnet-group"
  subnet_ids = aws_subnet.database[*].id

  tags = {
    Name = "${local.name_prefix}-cache-subnet-group"
  }
}

# Flow logs live in flow-logs.tf for clarity.
