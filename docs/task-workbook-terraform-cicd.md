# 🧪 Task Workbook — Production-Ready Terraform Project with GitHub Actions, AWS OIDC & PR-Based Deployment

> **Purpose:** This is a hands-on lab workbook with 36 sequential tasks. Each task has a clear goal, the exact commands or code, and a "Done When" checkpoint. Work through them in order — by Task 36 you'll have built a complete, secure, multi-environment Terraform delivery pipeline from scratch.
>
> 📌 **Project-specific note:** This particular project uses **two environments only — `dev` and `production`** (no `staging`). The workbook below is the generic 3-environment version; whenever you see `staging` referenced, simply skip that subtask. The actual repo, modules, and workflows reflect the 2-env layout.

---

## 🎯 Final Outcome

By the end of this workbook you will have:

- A private GitHub repo with proper standards (CONTRIBUTING, CODEOWNERS, issue/PR templates).
- Trunk-based branching with `main` and `develop` protected.
- A standard Terraform folder layout for dev / staging / production.
- An S3-only remote backend (with native `use_lockfile` locking), encrypted and locked.
- AWS OIDC federation — no static AWS keys in GitHub.
- Per-environment IAM roles with least privilege.
- Working CI/CD pipelines: format-check, validate, TFLint, Checkov, plan-on-PR, apply-on-merge.
- Branch protection + GitHub Environments with reviewer approval gates.
- A reusable network module called from each environment.
- Real failure-mode walkthroughs (security finding, OIDC denial, syntax error).
- A clean teardown procedure.

---

## 📑 Task Index

| # | Task | Theme |
|---|---|---|
| 1 | Create Repository | Foundation |
| 2 | Configure Repository Standards | Foundation |
| 3 | Configure Branch Strategy | Foundation |
| 4 | Create Folder Structure | Layout |
| 5 | Create Environment Layout | Layout |
| 6 | Configure Terraform Standards | Layout |
| 7 | Create Backend Resources | Backend |
| 8 | Configure Terraform Backend | Backend |
| 9 | Create Network Module | Modules |
| 10 | Configure Environment Modules | Modules |
| 11 | Configure OIDC Provider | Identity |
| 12 | Create IAM Roles | Identity |
| 13 | Configure IAM Permissions | Identity |
| 14 | Configure GitHub Secrets | Identity |
| 15 | Create Validation Workflow | CI/CD |
| 16 | Integrate TFLint | CI/CD |
| 17 | Integrate Checkov | CI/CD |
| 18 | Create Plan Workflow | CI/CD |
| 19 | Create Apply Workflow | CI/CD |
| 20 | Configure Branch Protection | Governance |
| 21 | Configure GitHub Environments | Governance |
| 22 | Configure CODEOWNERS | Governance |
| 23 | Create Feature Branch | Daily Use |
| 24 | Create Pull Request | Daily Use |
| 25 | Review Pull Request | Daily Use |
| 26 | Merge and Deploy | Daily Use |
| 27 | Configure Pre-commit | Quality |
| 28 | Validate Local Checks | Quality |
| 29 | Security Group Validation | Failure Modes |
| 30 | OIDC Authorization Failure | Failure Modes |
| 31 | Terraform Validation Failure | Failure Modes |
| 32 | Prepare Production Release | Release |
| 33 | Execute Production Apply | Release |
| 34 | Post-deployment Validation | Release |
| 35 | Destroy Infrastructure | Teardown |
| 36 | Repository Cleanup | Teardown |

---

# Task 1 — Create Repository

**Goal:** Bootstrap a private GitHub repo with README, `.gitignore`, and the first commit.

### Steps

1. On GitHub: **New → Repository**
   - **Name:** `terraform-aws-platform`
   - **Visibility:** Private
   - **Initialize with README:** ✅
   - **`.gitignore` template:** Terraform
   - **License:** MIT (or per org policy)
2. Clone locally:

```bash
git clone https://github.com/<your-user>/terraform-aws-platform.git
cd terraform-aws-platform
```

3. Configure Git identity (per-repo so it doesn't leak to other projects):

```bash
git config user.name  "Your Name"
git config user.email "you@example.com"
```

4. Verify and push the first commit:

```bash
git log --oneline
git push origin main
```

**✅ Done when:** repo is private, contains README + Terraform `.gitignore`, and the first commit is on `main`.

---

# Task 2 — Configure Repository Standards

**Goal:** Establish documentation and contribution norms.

### 2.1 `CONTRIBUTING.md`

```markdown
# Contributing

## Branching
- Branch from `develop`
- Naming: `feature/<short-name>`, `fix/<short-name>`, `hotfix/<short-name>`

## Commits
Use Conventional Commits: `feat: ...`, `fix: ...`, `docs: ...`, `chore: ...`

## Pull Requests
- Fill the PR template completely
- All CI checks must pass
- Requires 1 approval (2 for production)

## Style
- `terraform fmt -recursive` before committing
- All variables must have a description and type
```

### 2.2 PR template — `.github/PULL_REQUEST_TEMPLATE.md`

```markdown
## Description

## Type of Change
- [ ] Feature
- [ ] Bug fix
- [ ] Refactor
- [ ] Docs

## Environments Affected
- [ ] dev
- [ ] staging
- [ ] production

## Terraform Changes
### Added
### Modified
### Destroyed

## Manual Verification
- [ ] Plan reviewed
- [ ] No unexpected changes
- [ ] Tags applied

Closes #
```

### 2.3 Issue templates — `.github/ISSUE_TEMPLATE/bug_report.md` and `feature_request.md`

```markdown
---
name: Bug report
about: Something is broken
labels: bug
---

**Describe the bug**

**Steps to reproduce**

**Expected vs actual**
```

### 2.4 Repository Topics

Settings → Topics: `terraform`, `aws`, `iac`, `github-actions`, `oidc`, `eks`.

### 2.5 Labels

Add: `bug`, `enhancement`, `documentation`, `infra/dev`, `infra/staging`, `infra/prod`, `security`, `breaking-change`.

### 2.6 CODEOWNERS — `.github/CODEOWNERS` (filled in Task 22)

### 2.7 Branch naming standard (in `CONTRIBUTING.md`)

`feature/`, `fix/`, `hotfix/`, `chore/`, `docs/`.

**✅ Done when:** all six files exist on `main`, topics and labels are set.

---

# Task 3 — Configure Branch Strategy

**Goal:** Establish trunk-based development with a `develop` integration branch.

```bash
# Create and push develop
git checkout -b develop
git push -u origin develop
```

| Branch | Role |
|---|---|
| `main` | Production source of truth |
| `develop` | Integration branch — auto-deploys to dev env |
| `feature/*` | New work, branched from `develop` |
| `fix/*` | Bug fixes, branched from `develop` |
| `hotfix/*` | Emergency fix, branched from `main`, merged to both |
| `release/*` | Optional release prep |

**Merge strategy:** Squash & merge for `feature/*` → `develop`. Merge commit for `develop` → `main` to preserve history.

**Document this in `docs/branching.md`:**

```markdown
# Branching Model
- main → production (protected, prod auto-deploy on merge)
- develop → dev/staging (protected, dev auto-deploy on merge)
- feature/* → branched from develop
- hotfix/* → branched from main
Merge strategy: squash to develop, merge commit develop→main.
```

**✅ Done when:** `develop` exists on remote, doc committed.

---

# Task 4 — Create Folder Structure

**Goal:** Standard top-level layout.

```bash
mkdir -p environments/{dev,staging,production}
mkdir -p modules/network
mkdir -p scripts
mkdir -p .github/workflows
mkdir -p docs
mkdir -p bootstrap
mkdir -p tests
touch environments/.gitkeep modules/.gitkeep scripts/.gitkeep \
      docs/.gitkeep bootstrap/.gitkeep tests/.gitkeep
```

Final tree:

```text
terraform-aws-platform/
├── .github/
│   └── workflows/
├── bootstrap/         # one-time S3 backend setup
├── docs/
├── environments/
│   ├── dev/
│   ├── staging/
│   └── production/
├── modules/
│   └── network/
├── scripts/
└── tests/
```

**✅ Done when:** `tree -L 2` matches.

---

# Task 5 — Create Environment Layout

**Goal:** Each environment folder has the same six core files.

For **each** of `dev`, `staging`, `production`, create:

### `environments/<env>/versions.tf`

```hcl
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}
```

### `environments/<env>/providers.tf`

```hcl
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}
```

### `environments/<env>/backend.tf` (filled in Task 8)

```hcl
terraform {
  backend "s3" {}
}
```

### `environments/<env>/variables.tf`

```hcl
variable "aws_region" {
  description = "AWS region for this environment."
  type        = string
}
variable "environment" {
  description = "Environment name (dev/staging/production)."
  type        = string
}
variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}
```

### `environments/<env>/main.tf`

```hcl
locals {
  common_tags = {
    Project     = "terraform-aws-platform"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "platform-team"
  }
}

module "network" {
  source      = "../../modules/network"
  environment = var.environment
  vpc_cidr    = var.vpc_cidr
  tags        = local.common_tags
}
```

### `environments/<env>/outputs.tf`

```hcl
output "vpc_id" {
  description = "ID of the VPC."
  value       = module.network.vpc_id
}
output "private_subnet_ids" {
  description = "Private subnet IDs."
  value       = module.network.private_subnet_ids
}
```

### `environments/<env>/<env>.tfvars`

```hcl
aws_region  = "ap-south-1"
environment = "dev"          # change per env
vpc_cidr    = "10.10.0.0/16" # 10.20 / 10.30 for staging / prod
```

**✅ Done when:** all three folders have all six files.

---

# Task 6 — Configure Terraform Standards

**Goal:** Lock in versioning, tagging, naming.

| Standard | Value |
|---|---|
| Terraform | `>= 1.10.0` (pinned in `versions.tf`) — required for native S3 state locking |
| AWS provider | `~> 5.40` |
| Default tags | `Project`, `Environment`, `ManagedBy`, `Owner` |
| Naming | `<project>-<env>-<resource>` (e.g. `tf-aws-dev-vpc`) |
| Variable description | Required |
| Output description | Required |

This is enforced via `terraform validate` and TFLint (Task 16).

**✅ Done when:** all `.tf` files declare a description on every variable/output.

---

# Task 7 — Create Backend Resources

**Goal:** Provision the S3 bucket that will hold remote state. We use **S3-only** with native state locking (`use_lockfile = true` — Terraform 1.10+) — no DynamoDB lock table required. This is a **one-time bootstrap** — its own state can be local.

### `bootstrap/main.tf`

```hcl
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.40" }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region"   { type = string  default = "ap-south-1" }
variable "state_bucket" { type = string }

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Block insecure (non-TLS) requests at the bucket policy level.
resource "aws_s3_bucket_policy" "state_tls_only" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

output "state_bucket" { value = aws_s3_bucket.state.id }
```

### Apply

```bash
cd bootstrap
terraform init
terraform apply -var="state_bucket=tf-aws-platform-state-$(date +%s)"
```

**✅ Done when:** S3 bucket exists, versioned, encrypted, public-access-blocked, and TLS-only.

---

# Task 8 — Configure Terraform Backend

**Goal:** Wire each environment to the remote backend with a unique state key. Uses S3-only state locking (`use_lockfile = true`).

### `environments/dev/backend.hcl`

```hcl
bucket       = "tf-aws-platform-state-1717000000"
key          = "environments/dev/terraform.tfstate"
region       = "ap-south-1"
encrypt      = true
use_lockfile = true       # ← native S3 state locking (Terraform 1.10+)
```

(Repeat for `staging/backend.hcl` and `production/backend.hcl` with their own `key`.)

### Initialize

```bash
cd environments/dev
terraform init -backend-config=backend.hcl
```

**✅ Done when:** `terraform init` reports successful backend initialization for all three envs.

---

# Task 9 — Create Network Module

**Goal:** A reusable VPC + subnets module under `modules/network/`.

### `modules/network/variables.tf`

```hcl
variable "environment" {
  description = "Environment name."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "environment must be dev, staging, or production."
  }
}
variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
}
variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}
```

### `modules/network/main.tf`

```hcl
locals {
  azs = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = merge(var.tags, { Name = "tf-aws-${var.environment}-vpc" })
}

resource "aws_subnet" "private" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false
  tags = merge(var.tags, { Name = "tf-aws-${var.environment}-private-${count.index}" })
}
```

### `modules/network/outputs.tf`

```hcl
output "vpc_id"             { value = aws_vpc.this.id        description = "VPC ID." }
output "private_subnet_ids" { value = aws_subnet.private[*].id description = "Private subnet IDs." }
```

### `modules/network/README.md`

```markdown
# Network Module
Creates a VPC and 3 private subnets across AZs.

## Inputs
| Name | Type | Required |
|---|---|---|
| environment | string | yes |
| vpc_cidr | string | yes |
| tags | map(string) | no |

## Outputs
| Name | Description |
|---|---|
| vpc_id | VPC ID |
| private_subnet_ids | Private subnet IDs |
```

**✅ Done when:** `terraform validate` passes inside `modules/network/`.

---

# Task 10 — Configure Environment Modules

Already wired in Task 5 — each environment calls `module "network"` from `../../modules/network`. Per env, override `vpc_cidr` and `environment` via the env's `*.tfvars`.

**✅ Done when:** each env's `terraform plan -var-file=<env>.tfvars` shows the expected resources.

---

# Task 11 — Configure OIDC Provider

**Goal:** Register GitHub as a trusted OIDC IdP in AWS.

Use the CloudFormation template at [`./oidc-github-role.yml`](./oidc-github-role.yml). Stack parameters:

- `AudienceList` = `sts.amazonaws.com`
- `GithubActionsThumbprints` = three defaults (left as-is)
- `SubjectClaimFilters` = will be set per-role in Task 12

### Validate

```bash
aws iam list-open-id-connect-providers
# Expect to see arn:aws:iam::ACCOUNT:oidc-provider/token.actions.githubusercontent.com
```

### Document the OIDC flow

See [`./github-oidc-aws-setup.md`](./github-oidc-aws-setup.md).

**✅ Done when:** OIDC provider is listed in IAM.

---

# Task 12 — Create IAM Roles

**Goal:** One role per environment with a tightly-scoped trust policy.

### Trust policy template (per role)

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::ACCOUNT:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:<OWNER>/terraform-aws-platform:environment:<ENV>"
      }
    }
  }]
}
```

| Role | Subject claim |
|---|---|
| `tf-deployer-dev` | `repo:<OWNER>/terraform-aws-platform:environment:dev` |
| `tf-deployer-staging` | `repo:<OWNER>/terraform-aws-platform:environment:staging` |
| `tf-deployer-production` | `repo:<OWNER>/terraform-aws-platform:environment:production` |

`MaxSessionDuration`: 3600 seconds.

**✅ Done when:** three roles exist and trust policies pin to the correct environment subjects.

---

# Task 13 — Configure IAM Permissions

**Goal:** Attach least-privilege permissions per role.

### Common policy (attach to all three roles)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": [
        "s3:ListBucket"
      ], "Resource": "arn:aws:s3:::tf-aws-platform-state-*" },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:PutObject", "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::tf-aws-platform-state-*/*"
    },
    { "Effect": "Allow", "Action": [
        "ec2:*Vpc*","ec2:*Subnet*","ec2:*Route*","ec2:*Gateway*",
        "ec2:Describe*","ec2:CreateTags","ec2:DeleteTags"
      ], "Resource": "*" },
    { "Effect": "Allow", "Action": [
        "iam:GetRole","iam:GetPolicy","iam:ListAttachedRolePolicies"
      ], "Resource": "*" }
  ]
}
```

For `production` add tighter resource conditions (e.g., only specific VPC CIDRs, only specific tag-set resources).

**✅ Done when:** policy attached and dev role can run `terraform plan` end-to-end.

---

# Task 14 — Configure GitHub Secrets / Variables

GitHub → Settings → Secrets and variables → Actions.

**Repository Variables** (non-sensitive):

| Name | Value |
|---|---|
| `AWS_REGION` | `ap-south-1` |
| `AWS_ROLE_DEV` | `arn:aws:iam::ACCOUNT:role/tf-deployer-dev` |
| `AWS_ROLE_STAGING` | `arn:aws:iam::ACCOUNT:role/tf-deployer-staging` |
| `AWS_ROLE_PRODUCTION` | `arn:aws:iam::ACCOUNT:role/tf-deployer-production` |

Or store the per-env ARN as **Environment Variables** under the corresponding GitHub Environment.

Validate by referencing in workflow: `${{ vars.AWS_ROLE_DEV }}`.

**✅ Done when:** workflow can read the values.

---

# Task 15 — Create Validation Workflow

`.github/workflows/terraform-validate.yml`

```yaml
name: Terraform Validate

on:
  pull_request:
    branches: [main, develop]
    paths: ["environments/**", "modules/**", ".github/workflows/**"]

permissions: { contents: read }

jobs:
  validate:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        env: [dev, staging, production]
    defaults:
      run:
        working-directory: environments/${{ matrix.env }}
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "1.11.4" }
      - name: Format Check
        run: terraform fmt -check -recursive
        working-directory: .
      - name: Init (no backend)
        run: terraform init -backend=false
      - name: Validate
        run: terraform validate
```

**✅ Done when:** the matrix runs across all three envs.

---

# Task 16 — Integrate TFLint

Add to validate workflow:

```yaml
      - uses: terraform-linters/setup-tflint@v4
        with: { tflint_version: latest }
      - name: TFLint Init
        run: tflint --init
      - name: TFLint
        run: tflint --recursive --format compact
```

`.tflint.hcl` at repo root:

```hcl
plugin "aws" {
  enabled = true
  version = "0.30.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
rule "terraform_required_version"   { enabled = true }
rule "terraform_required_providers" { enabled = true }
rule "terraform_unused_declarations" { enabled = true }
```

**✅ Done when:** TFLint step reports no errors.

---

# Task 17 — Integrate Checkov

Add a step to the validate workflow:

```yaml
      - name: Checkov
        uses: bridgecrewio/checkov-action@v12
        with:
          directory: environments/${{ matrix.env }}
          framework: terraform
          soft_fail: true
          output_format: cli
          download_external_modules: true
```

In production, switch `soft_fail: false` once findings are clean.

**✅ Done when:** scan output appears in workflow logs.

---

# Task 18 — Create Plan Workflow

`.github/workflows/terraform-plan.yml`

```yaml
name: Terraform Plan
on:
  pull_request:
    branches: [develop]
    paths: ["environments/dev/**", "modules/**"]

permissions:
  id-token: write
  contents: read
  pull-requests: write

env:
  AWS_REGION: ${{ vars.AWS_REGION }}
  TF_WORKING_DIR: environments/dev

jobs:
  plan:
    if: github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    timeout-minutes: 30
    defaults: { run: { working-directory: environments/dev } }
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_DEV }}
          role-session-name: gha-${{ github.run_id }}-plan
          aws-region: ${{ env.AWS_REGION }}
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "1.11.4" }
      - run: terraform init -backend-config=backend.hcl
      - id: plan
        run: |
          terraform plan -var-file=dev.tfvars -out=tfplan.binary -no-color \
            2>&1 | tee plan.txt
      - uses: actions/upload-artifact@v4
        with:
          name: tfplan-${{ github.event.pull_request.number }}
          path: ${{ env.TF_WORKING_DIR }}/tfplan.binary
          retention-days: 7
      - uses: actions/github-script@v7
        if: always()
        with:
          script: |
            const fs = require('fs');
            let plan = fs.readFileSync('environments/dev/plan.txt','utf8');
            if (plan.length > 60000) plan = plan.slice(0,60000) + "\n...truncated...";
            await github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner, repo: context.repo.repo,
              body: "### 📋 Terraform Plan (dev)\n\n```hcl\n"+plan+"\n```"
            });
```

**✅ Done when:** opening a PR posts a plan comment.

---

# Task 19 — Create Apply Workflow

`.github/workflows/terraform-apply.yml`

```yaml
name: Terraform Apply
on:
  push:
    branches: [develop]
    paths: ["environments/dev/**", "modules/**"]
  workflow_dispatch:

permissions: { id-token: write, contents: read }

concurrency:
  group: tf-apply-dev
  cancel-in-progress: false

jobs:
  apply:
    runs-on: ubuntu-latest
    environment: dev   # 🔒 GitHub Environment with reviewer if configured
    timeout-minutes: 60
    defaults: { run: { working-directory: environments/dev } }
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_DEV }}
          role-session-name: gha-${{ github.run_id }}-apply
          aws-region: ${{ vars.AWS_REGION }}
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "1.11.4" }
      - run: terraform init -backend-config=backend.hcl
      - run: terraform apply -auto-approve -var-file=dev.tfvars
      - if: always()
        run: |
          echo "### 🚀 Apply Summary" >> $GITHUB_STEP_SUMMARY
          echo "- Branch: \`${{ github.ref_name }}\`" >> $GITHUB_STEP_SUMMARY
          echo "- SHA: \`${{ github.sha }}\`" >> $GITHUB_STEP_SUMMARY
          echo "- Status: \`${{ job.status }}\`" >> $GITHUB_STEP_SUMMARY
```

**✅ Done when:** merge to `develop` triggers the apply.

---

# Task 20 — Configure Branch Protection

Settings → Branches → Add rule for **`main`** and **`develop`**:

- ✅ Require a pull request before merging
- ✅ Require approvals: 1 (`develop`), 2 (`main`)
- ✅ Dismiss stale reviews on new commits
- ✅ Require status checks: `Terraform Validate`, `Terraform Plan`
- ✅ Require branches up to date
- ✅ Require conversation resolution
- ✅ Do not allow bypass
- ✅ Restrict who can push (admins only)
- ❌ Disallow force-push and deletion

**✅ Done when:** direct pushes to either branch are rejected.

---

# Task 21 — Configure GitHub Environments

Settings → Environments → New for **`dev`**, **`staging`**, **`production`**.

| Setting | dev | staging | production |
|---|---|---|---|
| Required reviewers | none | 1 | 2 |
| Wait timer | 0 | 0 | 5 min |
| Deployment branches | `develop` | `develop` | `main` |
| Prevent self-review | ✅ | ✅ | ✅ |

Per-environment Variables: `AWS_ROLE_DEV/STAGING/PRODUCTION`, `AWS_REGION`.

**✅ Done when:** apply jobs for staging/production pause for approval.

---

# Task 22 — Configure CODEOWNERS

`.github/CODEOWNERS`

```text
# Default — platform team owns everything
*                            @your-org/platform-team

# Modules require module maintainers
/modules/                    @your-org/module-maintainers

# Workflows require CI maintainers
/.github/workflows/          @your-org/ci-maintainers

# Production needs senior approval
/environments/production/    @your-org/senior-engineers @your-org/platform-team
```

**✅ Done when:** PRs auto-request the right reviewers.

---

# Task 23 — Create Feature Branch

```bash
git checkout develop && git pull
git checkout -b feature/add-network-module

# edit modules/network/* and environments/dev/main.tf
terraform fmt -recursive
terraform -chdir=environments/dev validate
git add .
git commit -m "feat(network): add reusable VPC + private subnets module"
git push --set-upstream origin feature/add-network-module
```

**✅ Done when:** branch is pushed and pre-commit hooks pass.

---

# Task 24 — Create Pull Request

Open PR `feature/add-network-module → develop`. Fill the template:

```markdown
## Description
Introduces reusable network module and wires it into dev.

## Type of Change
- [x] Feature

## Environments Affected
- [x] dev

## Terraform Changes
### Added
- module.network.aws_vpc.this
- 3 × module.network.aws_subnet.private

## Manual Verification
- [x] Plan reviewed — 4 resources to add
- [x] Tags applied
- [x] CIDR validated

Closes #12
```

**✅ Done when:** PR exists with plan comment auto-posted.

---

# Task 25 — Review Pull Request

Reviewer's checklist (paste as PR comment):

```markdown
- [ ] Plan reviewed end-to-end
- [ ] No unexpected destroys/replacements
- [ ] IAM changes scoped correctly
- [ ] Networking changes don't widen exposure
- [ ] Security groups follow least privilege
- [ ] Tagging standards followed (Project/Env/Owner)
- [ ] Blast radius understood
```

**✅ Done when:** approval given (or change requests filed and resolved).

---

# Task 26 — Merge and Deploy

1. Confirm all required checks are green.
2. Confirm at least 1 approval.
3. Merge (squash) to `develop`.
4. Watch the **Apply** workflow run in the Actions tab.
5. Verify the Deployment Summary shows `Status: success`.
6. Check `terraform output` (locally or via the apply log) for `vpc_id`.

**✅ Done when:** dev VPC is live in AWS.

---

# Task 27 — Configure Pre-commit

`.pre-commit-config.yaml`

```yaml
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.88.0
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
      - id: terraform_tflint
      - id: terraform_checkov
        args: ["--soft-fail"]
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.18.0
    hooks:
      - id: gitleaks
```

```bash
pip install pre-commit
pre-commit install
```

**✅ Done when:** `git commit` runs hooks automatically.

---

# Task 28 — Validate Local Checks

```bash
pre-commit run --all-files
# fix anything red, repeat until green
terraform -chdir=environments/dev validate
```

**✅ Done when:** all hooks pass locally.

---

# Task 29 — Security Group Validation (failure walkthrough)

1. **Insert insecure rule** in `modules/network/main.tf`:

```hcl
resource "aws_security_group" "open" {
  name   = "tf-aws-${var.environment}-open"
  vpc_id = aws_vpc.this.id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]   # ⚠️ wide open
  }
}
```

2. Open a PR — Checkov fails: `CKV_AWS_24: Ensure no security groups allow ingress from 0.0.0.0/0 to port 22`.
3. **Document the risk** in the PR comment: anyone on the Internet can SSH.
4. **Remediate** by replacing `0.0.0.0/0` with the corp VPN CIDR.
5. Push — scan goes green, plan re-posts, PR is mergeable.

**✅ Done when:** the failing-then-passing flow is observed and documented.

---

# Task 30 — OIDC Authorization Failure (failure walkthrough)

1. Temporarily change a workflow's `role-to-assume` to `AWS_ROLE_PRODUCTION` while running on a `feature/*` branch.
2. Workflow fails:
   `Error: Could not assume role: Not authorized to perform sts:AssumeRoleWithWebIdentity`
3. **Failing condition:** the role's trust policy `sub` claim is pinned to `environment:production`; the run has `environment: dev` (or none).
4. **Review** the trust policy → confirm subject mismatch.
5. **Remediate** by either using the correct role or adjusting the trust policy intentionally (rare).
6. Document in `docs/runbooks/oidc-failures.md`.

**✅ Done when:** failure reproduced, root cause documented, fix applied.

---

# Task 31 — Terraform Validation Failure (failure walkthrough)

1. Introduce a syntax error: rename `vpc_cidr` to `vpccidr` in one place but not in `variables.tf`.
2. Push — `Terraform Validate` job fails:
   `Error: Reference to undeclared resource/variable: vpccidr`
3. The failing step is `terraform validate` in the matrix job for `dev`.
4. Fix the typo, push again. Validate goes green.

**✅ Done when:** failing/passing run captured.

---

# Task 32 — Prepare Production Release

1. Create release PR `develop → main`.
2. Run plan workflow against `production` (manual `workflow_dispatch` or branch-aware plan).
3. Verify:
   - 2 approvals required ✅
   - Required status checks all green ✅
   - Deployment branches restricted to `main` ✅
   - Reviewers from `@your-org/senior-engineers` requested via CODEOWNERS ✅

**✅ Done when:** PR is ready to merge, no protections bypassed.

---

# Task 33 — Execute Production Apply

1. Merge release PR to `main`.
2. The apply workflow triggers but pauses at the `production` environment.
3. Approver clicks **Review deployments → Approve and deploy**.
4. Workflow downloads the saved plan binary, runs `terraform apply tfplan.binary`.
5. Watch logs; confirm "Apply complete!".

**✅ Done when:** Apply Summary shows success and resources are visible in the prod AWS console.

---

# Task 34 — Post-deployment Validation

```bash
# 1. Verify resources
aws ec2 describe-vpcs --filters "Name=tag:Environment,Values=production"

# 2. Verify outputs
cd environments/production
terraform output

# 3. Verify tags on every resource
aws resourcegroupstaggingapi get-resources --tag-filters Key=Environment,Values=production

# 4. Verify state updated in S3
aws s3 ls s3://tf-aws-platform-state-1717000000/environments/production/
aws s3api list-object-versions --bucket tf-aws-platform-state-1717000000 \
  --prefix environments/production/terraform.tfstate

# 5. Audit logs
aws cloudtrail lookup-events --lookup-attributes \
  AttributeKey=Username,AttributeValue=tf-deployer-production
```

**✅ Done when:** every check returns the expected output.

---

# Task 35 — Destroy Infrastructure

Run **per environment**, lowest-blast-radius first:

```bash
# Dev
cd environments/dev
terraform init -backend-config=backend.hcl
terraform destroy -var-file=dev.tfvars

# Staging
cd ../staging
terraform init -backend-config=backend.hcl
terraform destroy -var-file=staging.tfvars

# Production (requires approval per environment rules)
cd ../production
terraform init -backend-config=backend.hcl
terraform destroy -var-file=production.tfvars
```

Then:

```bash
# Remove temp IAM roles (only those marked for cleanup)
aws iam delete-role --role-name tf-deployer-dev-temp
# Delete test-only S3 reports etc.
aws s3 rm s3://temp-test-bucket --recursive
```

**✅ Done when:** AWS shows zero project-tagged resources.

---

# Task 36 — Repository Cleanup

```bash
# Delete merged feature branches locally and remotely
git branch --merged develop | grep 'feature/' | xargs -r git branch -d
git push origin --delete feature/add-network-module

# Close any stale PRs through the GitHub UI
```

Final checks:

- [ ] No open PRs older than 30 days
- [ ] No unused workflow files in `.github/workflows/`
- [ ] No stale labels
- [ ] `git log --all --full-history -- '*.tfvars'` shows no leaked secrets
- [ ] `gitleaks detect --source .` reports zero findings
- [ ] Branch protection still enforced

**✅ Done when:** repo is tidy and audit-clean.

---

## 🏁 Workbook Complete

You've now built — end to end — a private Terraform monorepo with secure OIDC authentication, multi-environment isolation, automated validation/plan/apply pipelines, and governance gates. Use this as your reference template for future projects.

> 📚 **Companion docs:**
> - [`github-oidc-aws-setup.md`](./github-oidc-aws-setup.md)
> - [`oidc-github-role.yml`](./oidc-github-role.yml)
> - [`terraform-workflow-deep-dive.md`](./terraform-workflow-deep-dive.md)
> - [`terraform-engineering-handbook.md`](./terraform-engineering-handbook.md)

---

<div align="center">

**🎓 36 tasks. One production-ready Terraform delivery pipeline.**

[⬆ Back to Top](#-task-workbook--production-ready-terraform-project-with-github-actions-aws-oidc--pr-based-deployment)

</div>
