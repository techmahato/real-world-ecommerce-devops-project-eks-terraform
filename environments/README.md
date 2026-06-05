# Environments

Each subfolder is an independent Terraform configuration with its own state file. They share the modules under `../modules/` but never share state.

This project uses a **two-environment model**: `dev` and `production`.

## Layout per environment

```
<env>/
├── versions.tf       # Terraform & provider version pins
├── backend.tf        # backend "s3" {} — values injected at init time
├── backend.hcl       # the actual backend config (bucket, key, region)
├── providers.tf      # AWS provider with default tags
├── variables.tf      # input variable declarations
├── main.tf           # locals + module calls
├── outputs.tf        # values exposed for downstream consumption
└── <env>.tfvars      # environment-specific variable values
```

## CIDR allocations

| Environment | VPC CIDR | Branch | Approval Gate |
|---|---|---|---|
| dev | `10.10.0.0/16` | `develop` | none |
| production | `10.30.0.0/16` | `main` | required reviewers |

Distinct CIDRs ensure VPC peering / Transit Gateway connections never conflict later.

## Sizing — same shape, different scale

The architecture is identical between dev and production. Only **capacity** differs:

| Resource | Dev | Production |
|---|---|---|
| NAT Gateway | 1 (shared) | 3 (one per AZ) |
| EIP | 1 | 3 |
| Subnets | 9 (3 × 3 tiers) | 9 (3 × 3 tiers) |
| VPC Flow Logs | off (cost) | on |
| Flow log retention | n/a | 30 days |

## How to run locally

```bash
cd environments/dev

# Replace the placeholder bucket name in backend.hcl with the value
# produced by `terraform output state_bucket_id` from the bootstrap module.

terraform init -backend-config=backend.hcl
terraform plan  -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars
```

In CI, the workflows do this automatically via OIDC.

## Backend

Both environments use **S3-only state with native locking** (`use_lockfile = true`). No DynamoDB lock table is needed — Terraform 1.10+ writes a `.tflock` object next to the state file using a conditional PutObject to serialize concurrent runs.
