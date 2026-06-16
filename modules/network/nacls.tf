# =============================================================================
#  Per-Tier Network ACLs (defense-in-depth)
#  ---------------------------------------------------------------------------
#  Why NACLs in addition to security groups?
#
#    Security groups are stateful and live at the ENI. They are the primary
#    access control. However:
#      • A misconfigured SG (e.g. accidental 0.0.0.0/0 inbound) is contained
#        by a properly scoped NACL.
#      • NACLs deny entire CIDR ranges quickly — useful during incident
#        response (block an attacker's range without touching workloads).
#      • For a hardened "isolated" tier, the NACL turns the no-internet-route
#        promise into an enforced contract: even if someone adds a bad
#        route, the NACL still won't let the traffic out.
#
#  This file is gated behind `var.enable_dedicated_nacls` (default true).
#  When false, all subnets share the VPC's permissive default NACL — fine
#  for ephemeral dev environments; never recommended for production.
#
#  Rule resolution model:
#    • Lists in variables.tf are resolved with `cidrsubnet`-style "VPC_CIDR"
#      placeholders that are replaced with `var.vpc_cidr` at render time.
#      This avoids the Terraform limitation that variable defaults cannot
#      reference other variables.
# =============================================================================

locals {
  # Replace the literal "VPC_CIDR" placeholder used in default rules with
  # the actual VPC CIDR. This lets us ship sensible defaults that adapt
  # to whatever CIDR the caller picked.
  resolve_cidr = {
    "VPC_CIDR" = var.vpc_cidr
  }

  public_inbound_rules    = [for r in var.public_inbound_acl_rules : merge(r, { cidr_block = lookup(local.resolve_cidr, r.cidr_block, r.cidr_block) })]
  public_outbound_rules   = [for r in var.public_outbound_acl_rules : merge(r, { cidr_block = lookup(local.resolve_cidr, r.cidr_block, r.cidr_block) })]
  private_inbound_rules   = [for r in var.private_inbound_acl_rules : merge(r, { cidr_block = lookup(local.resolve_cidr, r.cidr_block, r.cidr_block) })]
  private_outbound_rules  = [for r in var.private_outbound_acl_rules : merge(r, { cidr_block = lookup(local.resolve_cidr, r.cidr_block, r.cidr_block) })]
  database_inbound_rules  = [for r in var.database_inbound_acl_rules : merge(r, { cidr_block = lookup(local.resolve_cidr, r.cidr_block, r.cidr_block) })]
  database_outbound_rules = [for r in var.database_outbound_acl_rules : merge(r, { cidr_block = lookup(local.resolve_cidr, r.cidr_block, r.cidr_block) })]
}

# =============================================================================
#  PUBLIC TIER NACL
#  ---------------------------------------------------------------------------
#  Public subnets host the ALB and NAT Gateway. They need to accept inbound
#  HTTPS/HTTP from the world (for the ALB) and ephemeral return ports (for
#  outbound traffic initiated by the NAT or by the ALB's health checks).
# =============================================================================

resource "aws_network_acl" "public" {
  count = var.enable_dedicated_nacls ? 1 : 0

  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.public[*].id

  tags = {
    Name = "${local.name_prefix}-public-nacl"
    Tier = "public"
  }
}

resource "aws_network_acl_rule" "public_inbound" {
  for_each = var.enable_dedicated_nacls ? { for i, r in local.public_inbound_rules : tostring(r.rule_number) => r } : {}

  network_acl_id = aws_network_acl.public[0].id
  rule_number    = each.value.rule_number
  egress         = false
  protocol       = each.value.protocol
  rule_action    = each.value.rule_action
  cidr_block     = each.value.cidr_block
  from_port      = each.value.from_port
  to_port        = each.value.to_port
}

resource "aws_network_acl_rule" "public_outbound" {
  for_each = var.enable_dedicated_nacls ? { for i, r in local.public_outbound_rules : tostring(r.rule_number) => r } : {}

  network_acl_id = aws_network_acl.public[0].id
  rule_number    = each.value.rule_number
  egress         = true
  protocol       = each.value.protocol
  rule_action    = each.value.rule_action
  cidr_block     = each.value.cidr_block
  from_port      = each.value.from_port
  to_port        = each.value.to_port
}

# =============================================================================
#  PRIVATE TIER NACL
#  ---------------------------------------------------------------------------
#  Private subnets host EKS nodes and applications. The default rules permit
#  all traffic from inside the VPC (so pods can reach databases, ALBs, each
#  other) and ephemeral return ports from anywhere (for outbound-initiated
#  traffic via NAT — pulling images, calling external APIs).
# =============================================================================

resource "aws_network_acl" "private" {
  count = var.enable_dedicated_nacls ? 1 : 0

  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${local.name_prefix}-private-nacl"
    Tier = "private"
  }
}

resource "aws_network_acl_rule" "private_inbound" {
  for_each = var.enable_dedicated_nacls ? { for i, r in local.private_inbound_rules : tostring(r.rule_number) => r } : {}

  network_acl_id = aws_network_acl.private[0].id
  rule_number    = each.value.rule_number
  egress         = false
  protocol       = each.value.protocol
  rule_action    = each.value.rule_action
  cidr_block     = each.value.cidr_block
  from_port      = each.value.from_port
  to_port        = each.value.to_port
}

resource "aws_network_acl_rule" "private_outbound" {
  for_each = var.enable_dedicated_nacls ? { for i, r in local.private_outbound_rules : tostring(r.rule_number) => r } : {}

  network_acl_id = aws_network_acl.private[0].id
  rule_number    = each.value.rule_number
  egress         = true
  protocol       = each.value.protocol
  rule_action    = each.value.rule_action
  cidr_block     = each.value.cidr_block
  from_port      = each.value.from_port
  to_port        = each.value.to_port
}

# =============================================================================
#  DATABASE TIER NACL — the strongest control
#  ---------------------------------------------------------------------------
#  This is the most important NACL in the module. The database tier already
#  has no `0.0.0.0/0` route, but the NACL provides a second layer:
#    • Only DB ports (Postgres 5432, MySQL 3306, Redis 6379) are allowed in.
#    • Only from inside the VPC — *not* from arbitrary subnets in peered
#      VPCs unless the caller explicitly adds them.
#    • Egress is also limited to the VPC, so even if an attacker exploited
#      a DB engine and gained shell, they couldn't exfiltrate to an
#      arbitrary internet host (no route + NACL drop).
# =============================================================================

resource "aws_network_acl" "database" {
  count = var.enable_dedicated_nacls ? 1 : 0

  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.database[*].id

  tags = {
    Name = "${local.name_prefix}-database-nacl"
    Tier = "database"
  }
}

resource "aws_network_acl_rule" "database_inbound" {
  for_each = var.enable_dedicated_nacls ? { for i, r in local.database_inbound_rules : tostring(r.rule_number) => r } : {}

  network_acl_id = aws_network_acl.database[0].id
  rule_number    = each.value.rule_number
  egress         = false
  protocol       = each.value.protocol
  rule_action    = each.value.rule_action
  cidr_block     = each.value.cidr_block
  from_port      = each.value.from_port
  to_port        = each.value.to_port
}

resource "aws_network_acl_rule" "database_outbound" {
  for_each = var.enable_dedicated_nacls ? { for i, r in local.database_outbound_rules : tostring(r.rule_number) => r } : {}

  network_acl_id = aws_network_acl.database[0].id
  rule_number    = each.value.rule_number
  egress         = true
  protocol       = each.value.protocol
  rule_action    = each.value.rule_action
  cidr_block     = each.value.cidr_block
  from_port      = each.value.from_port
  to_port        = each.value.to_port
}
