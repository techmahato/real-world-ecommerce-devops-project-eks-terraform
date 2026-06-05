# Network Module — 3-Tier VPC

Provisions a production-ready **3-tier VPC** with public, private, and isolated database subnets across multiple AZs.

## Architecture

```
                         Internet
                             │
                             ▼
                    ┌────────────────┐
                    │ Internet GW    │
                    └────────┬───────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
        ▼                    ▼                    ▼
  ┌──────────┐         ┌──────────┐         ┌──────────┐
  │ Public   │  AZ-a   │ Public   │  AZ-b   │ Public   │  AZ-c
  │ /20      │         │ /20      │         │ /20      │
  │ ALB,NAT  │         │ ALB,NAT  │         │ ALB,NAT  │
  └────┬─────┘         └────┬─────┘         └────┬─────┘
       │ NAT                │ NAT                │ NAT
       ▼                    ▼                    ▼
  ┌──────────┐         ┌──────────┐         ┌──────────┐
  │ Private  │  AZ-a   │ Private  │  AZ-b   │ Private  │  AZ-c
  │ /20      │         │ /20      │         │ /20      │
  │ EKS,Apps │         │ EKS,Apps │         │ EKS,Apps │
  └────┬─────┘         └────┬─────┘         └────┬─────┘
       │                    │                    │
       └────────────────────┼────────────────────┘
                            ▼
                  ┌─────────────────┐
                  │ Database tier   │  (no Internet route)
                  │ /20 × 3 AZs     │
                  │ RDS, Redis      │
                  └─────────────────┘
```

## Tier semantics

| Tier | Internet route | Purpose | EKS tag |
|---|---|---|---|
| **Public** | `0.0.0.0/0 → IGW` | ALB, NAT, bastion | `kubernetes.io/role/elb = 1` |
| **Private** | `0.0.0.0/0 → NAT` | EKS nodes, app workloads | `kubernetes.io/role/internal-elb = 1` |
| **Database** | *none* | RDS, ElastiCache | none |

The **database tier has no default route** — it cannot reach the Internet at all. This is the strongest form of network isolation. Anything outside the VPC requires either VPC endpoints or VPC peering, added intentionally.

## CIDR layout (with a `/16` VPC CIDR input)

| Tier | Slot range | Example (`10.10.0.0/16`) |
|---|---|---|
| Public | `0..3` | `10.10.0.0/20`, `10.10.16.0/20`, `10.10.32.0/20` |
| Private | `4..7` | `10.10.64.0/20`, `10.10.80.0/20`, `10.10.96.0/20` |
| Database | `8..11` | `10.10.128.0/20`, `10.10.144.0/20`, `10.10.160.0/20` |

Up to 4 AZs supported per tier without changing the CIDR math.

## Inputs

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| `environment` | `string` | yes | — | One of `dev`, `production` |
| `project_name` | `string` | yes | — | Project identifier for tags + names |
| `vpc_cidr` | `string` | yes | — | VPC CIDR block (must be `/16`) |
| `availability_zones` | `list(string)` | yes | — | 2–4 AZs |
| `enable_flow_logs` | `bool` | no | `false` | Enable VPC flow logs to CloudWatch |
| `flow_logs_retention_days` | `number` | no | `30` | Flow log retention |
| `tags` | `map(string)` | no | `{}` | Tags applied to every resource |

## Outputs

VPC: `vpc_id`, `vpc_cidr`, `internet_gateway_id`, `nat_gateway_ids`

Public: `public_subnet_ids`, `public_subnet_cidrs`, `public_route_table_id`

Private: `private_subnet_ids`, `private_subnet_cidrs`, `private_route_table_ids`

Database: `database_subnet_ids`, `database_subnet_cidrs`, `database_route_table_id`, `db_subnet_group_name`, `elasticache_subnet_group_name`

Misc: `availability_zones`

## Cost-shape per environment

| Resource | Dev | Production |
|---|---|---|
| NAT Gateway | **1** (shared) | **N** (one per AZ for HA) |
| EIP | 1 | N |
| Subnets | 9 (3×3 tiers) | 9 (3×3 tiers) |
| Flow logs | optional | recommended on |

## Example

```hcl
module "network" {
  source = "../../modules/network"

  project_name       = "ecommerce-eks"
  environment        = "dev"
  vpc_cidr           = "10.10.0.0/16"
  availability_zones = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
  enable_flow_logs   = false       # turn on for production

  tags = local.common_tags
}

# Use the outputs downstream
module "rds" {
  source            = "../../modules/rds"
  db_subnet_group   = module.network.db_subnet_group_name
  vpc_id            = module.network.vpc_id
  allowed_app_cidrs = module.network.private_subnet_cidrs
  ...
}
```
