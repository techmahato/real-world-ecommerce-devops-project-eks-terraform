# 📘 Terraform Engineering Handbook

> **Who this is for:** Anyone working on this Terraform project — from first-day learners to experienced engineers — who wants a single reference for *how* we develop, review, structure, deploy, and secure Terraform code.
>
> **What this covers:** Git workflow and PR operations, directory layout patterns, using Terraform modules, state management and remote backends, handling sensitive data, and the dos/don'ts that separate a stable project from a chaotic one.
>
> **Companion docs:**
> - [`github-oidc-aws-setup.md`](./github-oidc-aws-setup.md) — how GitHub Actions authenticates to AWS without static keys
> - [`oidc-github-role.yml`](./oidc-github-role.yml) — CloudFormation template for the OIDC IAM role
> - [`terraform-workflow-deep-dive.md`](./terraform-workflow-deep-dive.md) — line-by-line walkthrough of the CI/CD workflow YAML

---

## 📑 Table of Contents

1. [Mental Model — How These Pieces Fit Together](#1-mental-model--how-these-pieces-fit-together)
2. [Git Branching Strategy — Trunk-Based Development](#2-git-branching-strategy--trunk-based-development)
3. [Pull Request Operations for Terraform](#3-pull-request-operations-for-terraform)
4. [Code Review Process & Checklist](#4-code-review-process--checklist)
5. [Resolving Merge Conflicts](#5-resolving-merge-conflicts)
6. [Directory Structure Patterns](#6-directory-structure-patterns)
7. [Using Reusable Terraform Modules](#7-using-reusable-terraform-modules)
8. [State Management & Remote Backends](#8-state-management--remote-backends)
9. [State Locking — How It Saves You](#9-state-locking--how-it-saves-you)
10. [Common State Operations You'll Actually Use](#10-common-state-operations-youll-actually-use)
11. [Sensitive Data Handling & Compliance](#11-sensitive-data-handling--compliance)
12. [Best Practices — Do This, Not That](#12-best-practices--do-this-not-that)
13. [Pre-Deployment Checklist](#13-pre-deployment-checklist)
14. [Glossary](#14-glossary)

---

## 1. Mental Model — How These Pieces Fit Together

Before diving into details, here's how every topic in this doc relates:

```text
┌─────────────────────────────────────────────────────────────┐
│  YOU (developer)                                            │
│   │                                                         │
│   │ 1. Branch off main                                      │
│   │ 2. Edit Terraform code                                  │
│   │ 3. Commit + push to feature branch                      │
│   │ 4. Open Pull Request                                    │
│   ▼                                                         │
│  GIT  →  GITHUB                                             │
│   │                                                         │
│   │ 5. CI runs `terraform plan` and posts diff on PR        │
│   ▼                                                         │
│  REVIEWER                                                   │
│   │                                                         │
│   │ 6. Reviews diff using checklist                         │
│   │ 7. Approves                                             │
│   ▼                                                         │
│  MERGE → main                                               │
│   │                                                         │
│   │ 8. CI runs `terraform apply` against AWS                │
│   ▼                                                         │
│  AWS (resources created/updated/destroyed)                  │
│   │                                                         │
│   │ 9. Terraform writes new state to S3 backend             │
│   │ 10. S3 lockfile prevents concurrent applies             │
│   ▼                                                         │
│  REMOTE STATE (S3) — single source of truth                 │
└─────────────────────────────────────────────────────────────┘
```

Every section below explains one slice of this picture in depth.

---

## 2. Git Branching Strategy — Trunk-Based Development

### 2.1 What "trunk-based" means

There is **one long-lived branch** — `main` — and it represents the *current authoritative state* of the infrastructure. Everything else is a **short-lived feature branch** that exists only long enough to ship one focused change.

```text
                ┌────────────────────┐
                │       main         │  ← Source of truth (live infra)
                └────────┬───────────┘
                         │
        ┌────────────────┼────────────────┐
        │                │                │
   feature-1        feature-2        feature-3
   (rds-add)       (vpc-tweak)      (eks-upgrade)
        │                │                │
   short-lived       short-lived      short-lived
        │                │                │
        └────────┬───────┴────────┬───────┘
                 │  Pull Request  │
                 ▼                ▼
        ┌──────────────────────────────┐
        │  CI checks (GitHub Actions)  │
        │   • terraform fmt/validate   │
        │   • terraform plan           │
        │   • policy / security scan   │
        └──────────────┬───────────────┘
                       │
                Peer review + approval
                       │
                       ▼
                Merge into main
                       │
                       ▼
              Apply infrastructure
```

### 2.2 Why trunk-based for Terraform specifically

- **The infrastructure is one shared system.** Long-lived parallel branches drift; reconciling them is painful.
- **Plans are most accurate when based on the latest `main`.** Old branches plan against stale state.
- **Small batches are easier to roll back.** A 3-resource change is easy to revert; a 30-resource change is a weekend incident.

### 2.3 Branch types you'll see

| Branch | Purpose | Lifetime |
|---|---|---|
| `main` | Source of truth — live infrastructure | Forever |
| `feature/<short-name>` | New work (add RDS, upgrade EKS, etc.) | Hours to a few days |
| `fix/<short-name>` | Bug fixes that aren't urgent | Hours to a few days |
| `hotfix/<short-name>` | **Emergency** production fix | As short as possible |
| `chore/<short-name>` | Maintenance — version bumps, refactors | Hours to a few days |
| `docs/<short-name>` | Documentation-only changes | Hours |

> 💡 **Rule of thumb:** if a feature branch is more than 3 days old, you should question whether it should be split into smaller PRs.

---

## 3. Pull Request Operations for Terraform

### 3.1 The end-to-end flow (from your laptop to production)

```text
[main branch]
     │
     │  git pull
     ▼
[your laptop, on main]
     │
     │  git checkout -b feature/add-rds-database
     ▼
[feature branch, locally]
     │
     │  edit code
     │  git add .
     │  git commit -m "..."
     │  git push --set-upstream origin feature/add-rds-database
     ▼
[feature branch, on GitHub]
     │
     │  open Pull Request
     ▼
[CI: terraform plan, posts diff as PR comment]
     │
     │  reviewer approves
     ▼
[merge to main]
     │
     │  CI: terraform apply
     ▼
[AWS: infrastructure changed]
```

### 3.2 Step 1 — Start clean from `main`

```bash
# 1. Move to main and pull the latest
git checkout main
git pull

# 2. Create a focused, descriptively named feature branch
git checkout -b feature/add-rds-database

# 3. Verify
git branch
# * feature/add-rds-database
#   main
```

**Why this matters:** if you forget to pull `main` first, your branch starts from old code. Your plan will be inconsistent with what `main` actually has, and you'll get spurious diffs.

### 3.3 Step 2 — Make a focused change

Edit *only* the files needed for this one change. If you find yourself touching unrelated modules, **stop** and split the work into multiple PRs.

### 3.4 Step 3 — Commit with a meaningful message

#### Conventional commit format

```text
<type>: <short subject — imperative mood, max 72 chars>

<optional body — wrap at 72 chars, explain *why*, not *what*>

<optional footer — ticket reference>
```

| Type | Use For |
|---|---|
| `feat` | New feature / new resource |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `refactor` | Code restructure with no behavior change |
| `chore` | Dependency bump, version pin, cleanup |
| `test` | Adding/updating tests |
| `ci` | Workflow YAML changes |

#### Concrete example

```bash
git add .
git commit -m "feat: add PostgreSQL RDS instance for application data

- Add RDS PostgreSQL 15.3 with Multi-AZ
- 7-day automated backup retention
- Enable CloudWatch logs export (postgresql, upgrade)
- Security group restricts access to app subnet
- Deletion protection enabled for prod

Resolves: #123"
```

The body explains *why* you made the change so future-you (reading `git log` 18 months from now) doesn't have to guess.

### 3.5 Step 4 — Push and open the PR

```bash
# First push of a new branch
git push --set-upstream origin feature/add-rds-database

# Subsequent pushes
git push
```

The push triggers the `terraform-plan` workflow automatically. Wait a minute, then go check the PR — the bot will post a plan summary as a comment.

### 3.6 Step 5 — Use a PR description template

```markdown
## Description
Add PostgreSQL RDS instance for application data storage.

## Type of Change
- [x] New feature (non-breaking change which adds functionality)
- [ ] Bug fix
- [ ] Breaking change
- [ ] Documentation update

## Environments Affected
- [ ] dev
- [x] production

## Terraform Changes Summary
### Resources Added
- `aws_db_instance.main`            → PostgreSQL 15.3 RDS instance
- `aws_db_subnet_group.main`        → DB subnet group spanning private subnets
- `aws_security_group.database`     → Database SG (default-deny)
- `aws_security_group_rule.app_in`  → Allow port 5432 from app SG

### Resources Modified
- None

### Resources Destroyed
- None

## Plan Output
_(Auto-posted by CI as a comment below)_

## Manual Verification
- [ ] Reviewed `terraform plan` output
- [ ] No unexpected changes
- [ ] Naming conventions followed

## Related
Closes #123
```

A good PR description means a fast review. A bad one means three rounds of "what does this do?"

---

## 4. Code Review Process & Checklist

### 4.1 What reviewers actually check

Reviewers should look at **two things** in this order:

1. **The plan output** (in the PR comment or the Actions tab if truncated). This is the truth.
2. **The Terraform code itself** — to make sure the plan output is achieving the intended result safely.

### 4.2 Reviewer's checklist

Copy-paste this into a PR comment and tick items off as you go.

```markdown
## Code Review Checklist

### General
- [ ] Code follows the project's Terraform style guide
- [ ] Naming conventions followed (resources, variables, modules)
- [ ] No hardcoded values — anything env-specific is a variable
- [ ] All variables have a `description` and a `type`
- [ ] All outputs have a `description`

### Security
- [ ] No secrets committed (passwords, API keys, tokens)
- [ ] IAM permissions follow least privilege
- [ ] Security groups follow least privilege (no 0.0.0.0/0 unless justified)
- [ ] Encryption enabled (RDS, EBS, S3, Secrets Manager)
- [ ] Sensitive outputs marked `sensitive = true`

### Best Practices
- [ ] Resources are properly tagged (Project, Environment, Owner)
- [ ] `lifecycle` blocks used appropriately (prevent_destroy on critical resources)
- [ ] Dependencies are explicit where order matters (`depends_on`)
- [ ] Data sources used instead of hardcoded ARNs/IDs

### Plan Verification
- [ ] Plan output reviewed line by line
- [ ] No unexpected resource replacements (look for `# forces replacement`)
- [ ] No unexpected destroys
- [ ] Counts / for_each indices correct

### Documentation
- [ ] README updated if behavior or interface changed
- [ ] Complex logic has inline comments
- [ ] CHANGELOG updated (if you keep one)
```

### 4.3 Special rule for hotfixes

For a `hotfix/*` branch, the only required check is:

> **"Will this PR delete or modify any resource outside the scope of the fix?"**

If yes, push back. If no, approve and merge — speed matters during incidents.

---

## 5. Resolving Merge Conflicts

Two engineers edit the same file → Git can't auto-merge → conflict.

### 5.1 The web UI route

GitHub has a built-in conflict editor (the "Resolve conflicts" button on the PR). For 1–2 small conflicts, this is fastest.

### 5.2 The CLI route — rebase your branch onto `main`

```bash
# 1. Switch to your feature branch
git checkout feature/for-merge

# 2. Fetch the latest main
git fetch origin main

# 3. Rebase your commits on top of main
git rebase origin/main
```

If a conflict appears, Git will pause and tell you which file is conflicted.

```bash
# 4. Open the conflicted file in your editor — resolve the markers
#    (<<<<<<<, =======, >>>>>>>)

# 5. Stage the fixed file
git add path/to/conflicted.tf

# 6. Continue the rebase
git rebase --continue

# 7. Push the rebased branch (force-with-lease is safer than --force)
git push --force-with-lease origin feature/for-merge
```

### 5.3 Why `--force-with-lease` instead of `--force`

`--force-with-lease` checks the remote branch hasn't been updated by someone else since you last fetched. If it has, it refuses — preventing you from accidentally overwriting a teammate's work. Plain `--force` doesn't check.

### 5.4 Conflict resolution etiquette

- 🟢 Always rebase your *own* feature branch onto `main`.
- 🔴 **Never** rebase shared branches like `main` itself.
- 🟢 Talk to the other author if conflicts span more than a few lines — sometimes one of you needs to land first.

---

## 6. Directory Structure Patterns

There are two patterns you'll see in real Terraform projects. Pick one and stick with it.

### 6.1 Pattern A — Root Folder

Terraform configuration lives at the root of the repo.

```text
project-name/
├── .github/
│   └── workflows/
│       ├── terraform-plan-apply.yml
│       └── terraform-state-lock.yml
├── modules/                     # Local reusable modules
│   ├── vpc/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── rds/
│   └── ec2/
├── scripts/
│   ├── bootstrap.sh
│   └── validate.sh
├── docs/
│   ├── architecture.md
│   ├── runbook.md
│   └── diagrams/
├── main.tf                      # ← root config (the "calling" module)
├── variables.tf
├── outputs.tf
├── terraform.tfvars
├── .gitignore
├── README.md
└── CHANGELOG.md
```

**Pros**
- Simple — `terraform plan/apply` runs from the repo root.
- Easy for newcomers to follow.

**Cons**
- One state file for the whole project — large blast radius.
- No native multi-environment support.

**Use when:** small project, single environment, single stack.

### 6.2 Pattern B — Sub Folder

Terraform configuration is split into purpose-specific folders.

```text
project-name/
├── .github/
│   └── workflows/
│       ├── terraform-plan-apply.yml
│       └── terraform-state-lock.yml
├── environments/
│   ├── dev/
│   │   ├── backend.tf
│   │   ├── main.tf
│   │   └── dev.tfvars
│   └── production/
│       ├── backend.tf
│       ├── main.tf
│       └── prod.tfvars
├── modules/                     # Local reusable modules
│   ├── vpc/
│   ├── eks/
│   ├── rds/
│   └── ec2/
├── networking/                  # Optional — split by domain
│   ├── vpc/
│   └── vpn/
├── compute/
│   ├── eks-cluster/
│   └── bastion/
├── scripts/
├── docs/
├── .gitignore
└── README.md
```

**Pros**
- Smaller blast radius — each folder has its own state.
- Strong isolation between environments.
- Module reuse is first-class.

**Cons**
- More moving parts — workflows must pick the right working directory.
- More state files to manage.

**Use when:** multiple environments, multiple stacks, larger teams. **(Recommended for this EKS project.)**

### 6.3 Comparison

| Concern | Root | Sub |
|---|---|---|
| Simplicity | ✅ Simpler | ⚠️ More structure |
| Multi-env | ❌ Awkward | ✅ Native |
| Module reuse | ⚠️ Possible | ✅ First-class |
| Blast radius | ❌ Whole project | ✅ Single stack |
| Workflow complexity | ✅ One working-dir | ⚠️ Per-stack working-dir |
| Recommended for | POC / tiny | Real production |

---

## 7. Using Reusable Terraform Modules

### 7.1 What is a module?

A module is just a **directory with `.tf` files** that you can call from another Terraform configuration. Think of it as a function: it takes inputs (`variables`), does work (creates resources), and returns outputs.

### 7.2 Three sources of modules

| Source | Example | When to Use |
|---|---|---|
| **Local** | `source = "../modules/vpc"` | Project-internal reuse |
| **Public registry** | `source = "terraform-aws-modules/vpc/aws"` | Battle-tested community modules |
| **Private Git repo** | `source = "git::https://github.com/org/modules.git//vpc?ref=v1.2.0"` | Org-internal reuse across repos |

### 7.3 Module usage checklist

When pulling in *any* module — yours or someone else's — walk through these every time:

- [ ] **Pin the version.** Never use `main` or `master` as the ref. Use a tag or commit SHA.
- [ ] **Read the README.** Understand inputs, outputs, and assumptions.
- [ ] **Check required variables.** What *must* you provide vs. what's optional?
- [ ] **Understand the outputs.** What does the module expose for downstream use?
- [ ] **Test in dev first.** Never introduce a new module straight to prod.
- [ ] **Document any custom values.** If you override defaults, comment *why*.
- [ ] **Track upgrades.** When a new version drops, read the changelog before bumping.

### 7.4 Example — calling a VPC module

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.1"   # ← always pin

  name = "${var.project_name}-${var.environment}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = var.environment == "dev"   # cost optimization
  enable_dns_hostnames   = true

  tags = local.common_tags
}
```

### 7.5 Common module categories you'll use in an EKS project

| Category | Typical Modules |
|---|---|
| **Networking** | VPC, subnets, NAT, IGW, VPC endpoints, security groups |
| **Compute** | EKS cluster, node groups, EC2, Auto-Scaling Groups |
| **Storage** | S3, EFS, EBS |
| **Database** | RDS, Aurora, DocumentDB, ElastiCache |
| **Identity** | IAM roles/policies, KMS keys, OIDC providers |
| **Edge** | ALB, NLB, CloudFront, Route 53, ACM |
| **Observability** | CloudWatch log groups, Prometheus, Grafana |
| **Container** | ECR repositories, ECS clusters |
| **Misc** | Lambda, SQS, SNS, Budget alerts |

---

## 8. State Management & Remote Backends

### 8.1 What is state?

When Terraform creates a resource, it needs to remember:

- *"Which AWS resource ID corresponds to my `aws_instance.web`?"*
- *"What attributes does that resource currently have?"*
- *"What does this resource depend on?"*

This memory lives in the **state file** — a JSON file Terraform reads at the start of every run and rewrites at the end.

### 8.2 Why remote state (not local)?

| Concern | Local State | Remote State (S3-only with native locking) |
|---|---|---|
| Team collaboration | ❌ Stuck on one laptop | ✅ Everyone reads the same source |
| State locking | ❌ Two engineers can corrupt | ✅ S3 lockfile serializes runs |
| Backups | ❌ Manual | ✅ S3 versioning |
| Encryption | ❌ Plaintext on disk | ✅ Encrypted at rest |
| Version history | ❌ None | ✅ Every change versioned in S3 |
| Access control | ❌ Filesystem permissions | ✅ IAM policies |

**Conclusion:** never use local state for anything beyond a 5-minute experiment.

### 8.3 The standard remote backend — S3-only (with native S3 state locking)

> 💡 **Why S3-only?** Since Terraform **1.10** the S3 backend supports native state locking via a small `.tflock` object next to the state file (`use_lockfile = true`). The DynamoDB lock table is no longer required. This simplifies the backend to a single AWS service, removes a moving part, and reduces cost.
>
> **Hard requirement:** Terraform `>= 1.10`. This project pins `1.11.4`. Below 1.10, S3 has no atomic locking primitive — using S3-only on older versions is unsafe.

```hcl
terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    bucket       = "ecommerce-eks-terraform-state"
    key          = "environments/dev/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true              # ← always
    use_lockfile = true              # ← native S3 state locking (1.10+)
    kms_key_id   = "arn:aws:kms:ap-south-1:123456789012:key/abcd"  # optional, recommended
  }
}
```

**What each line does:**

| Field | Meaning |
|---|---|
| `bucket` | Where the state JSON lives |
| `key` | Path within the bucket (different per env to keep states isolated) |
| `region` | AWS region of the bucket |
| `encrypt = true` | Enable SSE on writes |
| `use_lockfile = true` | Tells Terraform to use the native S3-based locking primitive (a `.tflock` object) instead of DynamoDB |
| `kms_key_id` | Customer-managed key for stronger encryption |

### 8.4 Bootstrapping the backend

The backend itself has to be created *before* you can use it. The standard pattern is a small **`bootstrap/`** module that creates:

1. The S3 bucket (with versioning, encryption, public-access-block)
2. A KMS key for the bucket

You apply that module once with **local state**, then commit the backend config that points to it.

> 🪣 **No DynamoDB table required.** Earlier guides created a `terraform-state-locks` DynamoDB table — that step is unnecessary with `use_lockfile = true`.

---

## 9. State Locking — How It Saves You

### 9.1 The problem locking solves

Without locking, two engineers running `terraform apply` at the same time can both read state, both compute different diffs, and both write back — corrupting state and creating zombie infrastructure.

### 9.2 How native S3 locking works

When `use_lockfile = true` is set, Terraform writes a small `.tflock` object next to the state file using a **conditional PutObject** (`If-None-Match: *`). S3 guarantees the write only succeeds if no object exists at that key — that's the atomic primitive locking depends on.

```text
User A runs terraform apply
     │
     ▼
PutObject  s3://bucket/path/terraform.tfstate.tflock
           Header: If-None-Match: *
     │
     │   Lockfile contents:
     │   {
     │     "ID":        "a1b2c3d4-e5f6-7890",
     │     "Operation": "OperationTypeApply",
     │     "Who":       "alice@host",
     │     "Created":   "2026-06-02T10:30:00Z"
     │   }
     ▼
User B tries terraform apply
     │
     ▼
PutObject (If-None-Match: *) → 412 PreconditionFailed
     │
     ▼
B sees: "Error: state locked by alice"
     │
     ▼
A's apply completes — Terraform DELETEs the .tflock object
     │
     ▼
B retries — PutObject succeeds — B's apply proceeds
```

### 9.3 The lock-error message in the wild

```text
Error: Error acquiring the state lock

Lock Info:
  ID:        a1b2c3d4-e5f6-7890
  Path:      ecommerce-eks-terraform-state/.../terraform.tfstate
  Operation: OperationTypeApply
  Who:       alice@company.com
  Version:   1.11.4
  Created:   2026-06-02 10:30:00.123456 +0000 UTC
  Info:      terraform apply running

Terraform acquires a state lock to protect the state from being written
by multiple users at the same time.
```

### 9.4 When the lock is stuck

If a CI run was killed (network drop, runner termination), the `.tflock` object stays in the bucket. **Only after confirming nobody is running Terraform**, you have two options:

```bash
# Option A — Terraform's built-in path
terraform force-unlock a1b2c3d4-e5f6-7890

# Option B — direct S3 deletion (when force-unlock won't parse the lock-info)
aws s3api delete-object \
  --bucket ecommerce-eks-terraform-state \
  --key   environments/dev/terraform.tfstate.tflock
```

> ⚠️ **Critical:** force-unlocking a *live* apply corrupts state. Use the dedicated [`tf-statelock-unlock.yml`](./terraform-workflow-deep-dive.md#18-state-lock-recovery-workflow) workflow with `environment: production` so it requires reviewer approval. That workflow supports both options above.

---

## 10. Common State Operations You'll Actually Use

### 10.1 Inspecting state

```bash
# List every resource Terraform tracks
terraform state list

# Show one resource's current attributes
terraform state show aws_instance.web

# Dump the entire state as human-readable
terraform show

# Dump the entire state as JSON (for tooling)
terraform show -json
```

### 10.2 Renaming a resource (without destroying it)

You renamed `aws_instance.server` to `aws_instance.web_server` in your code. By default Terraform will *destroy and recreate* it. To avoid that:

```bash
terraform state mv aws_instance.server aws_instance.web_server
```

### 10.3 Moving a resource into a module

```bash
terraform state mv aws_instance.web module.compute.aws_instance.web
```

### 10.4 Removing a resource from state (without destroying it)

Useful when AWS still has the resource but you no longer want Terraform to manage it.

```bash
terraform state rm aws_instance.legacy_server
```

### 10.5 Importing existing AWS resources into Terraform

The four-step flow:

```bash
# 1. Add the resource block to your .tf files (with the right config)
# 2. Import it
terraform import aws_instance.web i-0123456789abcdef
# 3. Verify
terraform plan        # should show "No changes"
# 4. If plan shows changes, adjust the config until plan is clean
```

> 💡 Modern Terraform (1.5+) supports `import` blocks declaratively in code — preferred over the CLI in CI.

### 10.6 Backups — what to know

- **S3 versioning** automatically keeps every previous state file. To roll back, restore an older version of the object.
- **MFA Delete on the state bucket** prevents accidental or malicious permanent deletion of state versions.
- **AWS Backup vault for the state bucket** can hold state snapshots outside the bucket itself for catastrophic restore scenarios.

---

## 11. Sensitive Data Handling & Compliance

### 11.1 Categories of sensitive data in Terraform

1. **Credentials** — DB passwords, API keys, access tokens, private keys
2. **Infrastructure details** — internal IPs, DB endpoints, VPN configs (sometimes)
3. **Business information** — customer data, environment-specific settings

### 11.2 The cardinal rule

> 🚨 **Never commit secrets to the repository — not even once.**
>
> Once a secret is in Git history, removing it later does NOT remove it from history. Anyone who clones the repo gets the leaked value. **Rotate immediately** and treat the secret as compromised.

### 11.3 Anti-patterns (what NOT to do)

```hcl
# ❌ Hardcoded password
resource "aws_db_instance" "main" {
  identifier = "myapp-db"
  password   = "SuperSecret123!"
}

# ❌ Default secret in a variable
variable "api_key" {
  default = "sk_live_abc123xyz789"
}

# ❌ Committed terraform.tfvars with secrets
db_password = "MySecretPassword123"
api_token   = "ghp_abc123xyz789"
```

### 11.4 The right pattern — AWS Secrets Manager

```text
┌────────────────────────────────────────────────────────┐
│                Terraform Configuration                 │
│                                                        │
│  data "aws_secretsmanager_secret_version" "db_pwd"     │
└─────────────────────┬──────────────────────────────────┘
                      │  retrieves at apply time
                      ▼
┌────────────────────────────────────────────────────────┐
│            AWS Secrets Manager                         │
│                                                        │
│  Secret: myapp-prod-db-password                        │
│   • Encrypted at rest with KMS                         │
│   • Optional automatic rotation                        │
│   • Every access logged in CloudTrail                  │
└─────────────────────┬──────────────────────────────────┘
                      │  injected into resource
                      ▼
┌────────────────────────────────────────────────────────┐
│                  RDS Database                          │
└────────────────────────────────────────────────────────┘
```

```hcl
# Reference an existing secret
data "aws_secretsmanager_secret_version" "db_password" {
  secret_id = "myapp-prod-db-password"
}

# Use it in a resource
resource "aws_db_instance" "main" {
  identifier        = "${var.project}-${var.environment}-db"
  engine            = "postgres"
  engine_version    = "15.3"
  instance_class    = var.db_instance_class
  db_name           = var.db_name
  username          = "dbadmin"
  password          = data.aws_secretsmanager_secret_version.db_password.secret_string
  storage_encrypted = true
  # ... other config
}
```

### 11.5 Marking variables and outputs as sensitive

```hcl
variable "db_password" {
  description = "Database master password"
  type        = string
  sensitive   = true   # ← won't be logged in plan/apply
}

output "db_connection_string" {
  description = "Connection string for the database"
  value       = "postgres://dbadmin:${var.db_password}@${aws_db_instance.main.endpoint}/${var.db_name}"
  sensitive   = true   # ← masked in CLI output
}
```

> 💡 `sensitive = true` only masks output in CLI/logs — **the value is still in the state file**. State file encryption (covered above) is what protects it at rest.

### 11.6 GitHub-side secrets

For tokens that the workflow itself needs (Slack webhook, Docker Hub PAT, third-party APIs), use GitHub Secrets:

```yaml
env:
  SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

GitHub masks the value in logs (`***`). Never put it in `vars` or plain `env` literals.

### 11.7 `.gitignore` discipline

Make sure your `.gitignore` excludes anything that might hold secrets:

```text
*.tfstate
*.tfstate.*
*.tfvars            # except *.tfvars.example
.env
.env.*
*.pem
*.key
.aws/
credentials
```

### 11.8 Pre-deploy security checklist

- [ ] No secrets hardcoded in any `.tf` file
- [ ] No secrets in `terraform.tfvars` (or `terraform.tfvars` is not committed)
- [ ] All secrets stored in AWS Secrets Manager or SSM Parameter Store
- [ ] Sensitive variables marked `sensitive = true`
- [ ] Sensitive outputs marked `sensitive = true`
- [ ] `.gitignore` covers all secret files
- [ ] State file encrypted at rest (S3 SSE + KMS)
- [ ] State file access restricted via IAM
- [ ] CloudTrail enabled on the AWS account
- [ ] Compliance requirements documented (SOC 2, HIPAA, PCI, etc.)
- [ ] Secret rotation configured where applicable
- [ ] Access to secrets logged and monitored

### 11.9 Automated security scanning

Run these on every PR via CI:

| Tool | What It Catches |
|---|---|
| **Checkov** | Misconfigurations (open SGs, unencrypted volumes, missing logging) |
| **tfsec** | Similar to Checkov, complementary rule set |
| **Trivy** | Container images + IaC scanning |
| **gitleaks** | Hardcoded secrets in commits |
| **OPA / Conftest** | Custom policy enforcement |

---

## 12. Best Practices — Do This, Not That

### 12.1 Git workflow

| ✅ Do | ❌ Don't |
|---|---|
| Branch off the latest `main` | Commit directly to `main` |
| Keep PRs small and focused | Open 3000-line "kitchen sink" PRs |
| Write descriptive commit messages | `git commit -m "stuff"` |
| Reference issue/ticket IDs | Leave `Resolves: #?` blank |
| Respond to review comments quickly | Ghost the reviewer for a week |
| Delete branches after merge | Leave 200 stale branches in `git branch -r` |
| Keep `main` protected | Allow force-pushes to `main` |
| Rebase `feature/*` onto `main` | Merge `main` into your feature branch (creates loops) |

### 12.2 Project structure

| ✅ Do | ❌ Don't |
|---|---|
| Separate environments (dev/prod) | Apply the same code with different `tfvars` to all envs without isolation |
| Use consistent file naming | Mix `vars.tf` / `variables.tf` / `inputs.tf` |
| Document modules with README | Ship modules with no docs |
| Provide `*.tfvars.example` | Force teammates to guess required vars |
| Use relative paths for local modules | Use absolute filesystem paths |
| Version-control everything except secrets | Commit `terraform.tfstate` |
| Tag every resource (Project, Env, Owner, ManagedBy) | Untagged resources nobody can attribute later |

### 12.3 Terraform code style

| ✅ Do | ❌ Don't |
|---|---|
| Run `terraform fmt -recursive` before committing | Submit unformatted code |
| Use `for_each` over `count` when iterating maps | Index by integer when keys are stable strings |
| Pin provider and module versions | Use `~>` loosely on critical infra |
| Use `lifecycle.prevent_destroy` on RDS/state buckets | Allow stateful resources to be silently destroyed |
| Use data sources instead of hardcoded ARNs | Hardcode account IDs / ARNs |
| Use locals for repeated expressions | Copy-paste the same expression 10 times |

### 12.4 State management

| ✅ Do | ❌ Don't |
|---|---|
| Use remote state (S3 with `use_lockfile = true`) | Use local state on a laptop |
| Encrypt state at rest with KMS | Trust default S3 encryption only |
| Restrict state-bucket access via IAM | Make the state bucket public, ever |
| Enable S3 versioning + access logging | Skip versioning to "save money" |
| One state file per environment | Mix dev/prod resources in one state |

### 12.5 Security

| ✅ Do | ❌ Don't |
|---|---|
| OIDC for GitHub Actions → AWS | Long-lived `AWS_ACCESS_KEY_ID` in GitHub Secrets |
| Pull secrets from Secrets Manager | Hardcode secrets in `.tf` files |
| Mark sensitive variables/outputs | Print passwords in plan output |
| Apply least-privilege IAM | Attach `AdministratorAccess` to runtime roles |
| Run Checkov/tfsec on every PR | Discover misconfigs in production |

---

## 13. Pre-Deployment Checklist

Before you click "Merge" on a PR that affects production, walk through this:

```markdown
### Code
- [ ] Code reviewed and approved
- [ ] All CI checks green (fmt, validate, plan, security scan)
- [ ] Plan output reviewed line by line
- [ ] No unexpected destroys/replacements

### State
- [ ] Backend is remote (S3 with `use_lockfile = true`)
- [ ] State file encrypted at rest
- [ ] No state lock held by another run

### Security
- [ ] No secrets committed
- [ ] Secrets sourced from Secrets Manager / GitHub Secrets
- [ ] Least-privilege IAM policies in scope
- [ ] Encryption enabled on data resources

### Operations
- [ ] PR description filled out (env affected, resources added/modified/destroyed)
- [ ] Ticket/issue referenced
- [ ] Rollback plan understood (what to do if apply fails)
- [ ] On-call team aware of the change (for prod)
```

---

## 14. Glossary

| Term | Plain English |
|---|---|
| **Trunk-based development** | A branching model with one long-lived branch (`main`) and many short-lived feature branches. |
| **Pull Request (PR)** | A GitHub mechanism to propose merging your branch into another, with built-in review and CI hooks. |
| **Rebase** | Reapplying your branch's commits on top of another branch's tip — produces a clean linear history. |
| **Conventional Commit** | A commit-message format (`type: subject`) that's machine-parseable for changelogs. |
| **Module** | A directory of `.tf` files that can be called like a function from another configuration. |
| **State file** | The JSON file Terraform uses to map config to real resources. |
| **Remote backend** | A non-local place to store the state file (S3, GCS, Terraform Cloud, etc.). |
| **State lock** | A `.tflock` object in S3 (or a DynamoDB row, on legacy backends) that prevents two `terraform apply` runs at once. |
| **Drift** | When real-world infrastructure no longer matches Terraform state (someone clicked in the AWS Console). |
| **Force unlock** | Manually deleting a stuck lock row — only safe when you're certain no apply is running. |
| **Sensitive variable / output** | Marked with `sensitive = true` so Terraform masks the value in CLI output. |
| **Secrets Manager / SSM Parameter Store** | AWS services for storing and retrieving secrets at runtime. |
| **Workspace (Terraform)** | A named, isolated state file under the same backend. Often used for environment isolation. |
| **`for_each` vs `count`** | Two ways to create multiple instances of a resource — `for_each` uses a map/set (stable keys), `count` uses an integer (positional). |
| **Hotfix branch** | An emergency branch for fixing a production issue fast. |

---

<div align="center">

**📘 You now have one reference for how this project handles every Terraform engineering concern.**

[⬆ Back to Top](#-terraform-engineering-handbook)

</div>
