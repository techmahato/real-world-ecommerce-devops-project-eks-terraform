# 🚀 PRODUCTION DEPLOY — From dev to live in 6 phases

> **Purpose.** Walks you from "dev VPC works" to "production VPC live in AWS, deployed via gated CI/CD" in one continuous runbook. Every step is copy-paste-and-go.
>
> **Prerequisites.** You've already completed [`SETUP.md`](./SETUP.md) and successfully deployed the dev VPC. The `tf-deployer-production` IAM role and the `production` GitHub Environment already exist.
>
> **Time:** ~20 minutes including the 5-min apply.
>
> **Estimated cost:** ~$3-4/day if left running. Destroy when done.

---

## 📑 The 6 phases

| Phase | What | Time |
|---|---|---|
| **1** | Wire prod backend with real bucket name | 2 min |
| **2** | Land the wiring on `develop` via PR | 3 min |
| **3** | Open promotion PR `develop → main` | 2 min |
| **4** | Manually trigger production plan & review | 4 min |
| **5** | Merge promotion PR & approve deployment | 6 min |
| **6** | Verify in AWS & document | 3 min |

---

## 🎯 The big picture

```
                 ┌────────────────────────┐
                 │ chore/wire-prod-backend │
                 │  (1-line edit to        │
                 │   prod backend.hcl)     │
                 └──────────┬──────────────┘
                            │ PR + merge
                            ▼
                       ┌─────────┐
                       │ develop │  ← dev VPC already deployed
                       └────┬────┘
                            │ promotion PR
                            ▼
                        ┌──────┐
                        │ main │
                        └──┬───┘
                           │ push triggers Terraform Apply
                           ▼
              ┌────────────────────────────┐
              │ Apply waits for human      │
              │ approval (Environment:     │
              │ production with reviewer)  │
              └────────────┬───────────────┘
                           │ click "Approve and deploy"
                           ▼
              ┌────────────────────────────┐
              │ Production VPC live in AWS │
              │   • 10.30.0.0/16           │
              │   • 3 NAT Gateways (HA)    │
              │   • 9 subnets, 3 tiers     │
              │   • VPC Flow Logs ON       │
              └────────────────────────────┘
```

---

# Phase 1 — Wire prod backend with the real bucket name

## 1.1 Find your state bucket name

You saved this during dev setup. Two ways to find it:

```powershell
# Option A — from the local file SETUP.md created
type .bucket-name

# Option B — read it from dev's backend
type environments\dev\backend.hcl | findstr bucket
```

Copy the value (it'll look like `ecommerce-eks-tfstate-441345502954-1717000000`).

## 1.2 Inject the bucket name into production's backend

```powershell
# Read dev's bucket name into a variable
$bucket = (Select-String -Path environments\dev\backend.hcl -Pattern 'bucket\s*=\s*"([^"]+)"').Matches.Groups[1].Value
Write-Host "Bucket: $bucket"

# Replace the placeholder in production's backend.hcl
(Get-Content environments\production\backend.hcl) `
  -replace 'ecommerce-eks-tfstate-CHANGE-ME', $bucket `
  | Set-Content environments\production\backend.hcl

# Verify both files now have the same bucket
type environments\dev\backend.hcl
type environments\production\backend.hcl
```

Both `backend.hcl` files should now show the same `bucket = "..."` value, but with different `key` paths (`environments/dev/...` vs `environments/production/...`).

## 1.3 Format check

```powershell
terraform fmt -check -recursive
```

Should output nothing (exit code 0).

---

# Phase 2 — Land the wiring on `develop` via PR

## 2.1 Branch off develop

```powershell
git checkout develop
git pull origin develop

git checkout -b chore/wire-prod-backend
```

## 2.2 Commit and push

```powershell
git add environments/production/backend.hcl
git commit -m "chore: wire prod state-bucket into backend.hcl"
git push -u origin chore/wire-prod-backend
```

## 2.3 Open and merge the PR

In GitHub:

1. Go to the **Compare** URL it printed, or:
   `https://github.com/<YOUR-OWNER>/real-world-ecommerce-devops-project-eks-terraform/compare/develop...chore/wire-prod-backend`
2. Click **"Create pull request"**
3. Title: `chore: wire prod state-bucket into backend.hcl`
4. Click **"Create pull request"** again

Wait ~3 minutes. Both `Validate (dev)` and `Validate (production)` checks should go green. The `Plan (dev)` check shows "Plan: 0 to add, 0 to change, 0 to destroy" because no actual infrastructure is changing — only a config file moves.

5. Click **"Squash and merge"** → **"Confirm squash and merge"**

The Apply workflow fires for dev — but since nothing in `environments/dev/**` changed, no resources are modified. State stays the same. Workflow runs ~30 seconds and shows "0 to add, 0 to change, 0 to destroy".

> 💡 **What's happening?** You're getting the production backend wiring onto `develop` so it's available when the promotion PR lands on `main`.

---

# Phase 3 — Open promotion PR `develop → main`

## 3.1 Make sure develop is up to date locally

```powershell
git checkout develop
git pull origin develop
```

## 3.2 Open the promotion PR

In GitHub, go to:

```
https://github.com/<YOUR-OWNER>/real-world-ecommerce-devops-project-eks-terraform/compare/main...develop
```

You'll see all the commits that have landed on `develop` since `main` was last updated.

1. Click **"Create pull request"**
2. **Title:** `release: promote dev VPC architecture to production`
3. **Description:**
   ```
   First production deployment.

   Changes promoted to production:
   - 3-tier VPC module (modules/network)
   - environments/production/ wired with real state bucket
   - Production sizing: VPC CIDR 10.30.0.0/16, 3 NAT Gateways (one per AZ),
     VPC Flow Logs enabled with 30-day retention.

   No applied infrastructure changes to production yet — apply runs only
   after merge.
   ```
4. Click **"Create pull request"**

The validate workflow runs (~3 min). Both dev and production matrix jobs should be green.

> ⚠️ **Note:** The plan workflow only auto-runs on PRs targeting `develop`, not `main`. So this PR won't have an auto-posted plan against production. We'll trigger one manually in Phase 4 — that's where the real review happens.

---

# Phase 4 — Manually trigger production plan & review

This is the most important phase — **never merge to main without seeing what's about to be created in production**.

## 4.1 Trigger the production plan workflow

In GitHub:

1. Go to the **Actions** tab
2. Click **"Terraform Plan"** in the left sidebar
3. Click the **"Run workflow"** dropdown (top-right of the runs list)
4. Configure:
   - **Use workflow from branch:** `develop`
   - **Environment to plan against:** `production`
5. Click the green **"Run workflow"** button

A new run appears at the top of the list. Click into it.

## 4.2 Wait ~3 minutes

Watch the steps:

```
✅ Configure AWS Credentials via OIDC      ← uses tf-deployer-production role
✅ Verify Caller Identity
✅ Setup Terraform
✅ Terraform Init                          ← initializes prod backend
✅ Terraform Validate
✅ Terraform Plan                          ← computes prod diff
✅ Upload Plan Artifact                    ← saves tfplan-production-<run-id>
✅ Plan Summary
```

## 4.3 Read the plan output

Click the **"Terraform Plan"** step → expand it → scroll to the bottom. Look for the summary line:

```
Plan: 29 to add, 0 to change, 0 to destroy.
```

Then verify the resources:

| Resource | Expected count | Notes |
|---|---|---|
| `aws_vpc.this` | 1 | CIDR `10.30.0.0/16` |
| `aws_internet_gateway.this` | 1 | |
| `aws_subnet.public` | 3 | Tagged `Tier=public` |
| `aws_subnet.private` | 3 | Tagged `Tier=private` |
| `aws_subnet.database` | 3 | Tagged `Tier=database` |
| `aws_eip.nat` | **3** | One per AZ — different from dev's 1 |
| `aws_nat_gateway.this` | **3** | HA across AZs |
| Route tables (public/private/database) | 5 | 1 public + 3 private + 1 database |
| Route table associations | 9 | 3 per tier |
| `aws_db_subnet_group.this` | 1 | |
| `aws_elasticache_subnet_group.this` | 1 | |
| `aws_cloudwatch_log_group.flow_logs` | **1** | Flow logs enabled in prod |
| `aws_iam_role.flow_logs` | **1** | |
| `aws_iam_role_policy.flow_logs` | **1** | |
| `aws_flow_log.this` | **1** | |

**~32-33 resources total** (more than dev because of HA NAT and flow logs).

✅ Tags should include `Environment = "production"` everywhere.

## 4.4 Stop and check

If anything looks unexpected (e.g., a destroy when there shouldn't be one, wrong CIDR, missing tags), **DO NOT MERGE**. Investigate first.

If the plan looks correct, continue.

---

# Phase 5 — Merge promotion PR & approve deployment

## 5.1 Lower main's approval requirement (solo dev only)

Same as you did for `develop`:

1. `Settings → Branches → main → Edit`
2. **Required number of approvals before merging:** change from `1` to `0`
3. **Save changes**

You can raise it back when you have a teammate.

## 5.2 Merge the promotion PR

Back to your `develop → main` PR:

1. Both validate checks should be green
2. Click **"Squash and merge"** (or **"Merge pull request"** if your repo uses merge commits)
3. **Title:** `release: promote dev VPC to production`
4. Click **"Confirm squash and merge"**

The PR turns 🟣 **Merged**.

## 5.3 The Apply workflow fires — and waits

Within ~10 seconds:

1. Go to **Actions** tab
2. A new run appears: **"Terraform Apply"** triggered by `push to main`
3. Click into it
4. You'll see:
   ```
   ✅ Determine Target Environment        (4s, target=production)
   ⏸  Apply (production)                  Waiting for review
   ```
5. A yellow banner appears: **"Deployment review required"**

## 5.4 Approve the deployment

This is the production gate. Without your click, nothing happens.

1. Click **"Review deployments"** (yellow button)
2. Check the box next to **`production`**
3. Optional: add a comment like *"First production deployment — verified plan looks good"*
4. Click the green **"Approve and deploy"** button

The job leaves "Waiting for review" status and starts running.

## 5.5 Watch the production apply

```
✅ Configure AWS Credentials via OIDC      (1s)   ← tf-deployer-production role
✅ Verify Caller Identity                  (3s)
✅ Setup Terraform                         (1s)
✅ Terraform Init                          (7s)
✅ Find Plan Artifact                      (0s)
✅ Download Plan Artifact                  (1s)   ← downloads from Phase 4 plan run
✅ Apply Saved Plan                        (4-6 min)  ← VPC creation here
✅ Capture Outputs                         (3s)
✅ Deployment Summary                      (0s)
```

The "Apply Saved Plan" step takes longer than dev because **3 NAT Gateways create in parallel** but each takes 2-3 minutes.

When all green, **production is live**.

---

# Phase 6 — Verify in AWS & document

## 6.1 Verify VPC

```powershell
aws ec2 describe-vpcs `
  --filters "Name=tag:Environment,Values=production" `
  --query 'Vpcs[].[VpcId,CidrBlock,Tags[?Key==`Name`]|[0].Value]' `
  --output table
```

Should show:

```
+----------------+----------------+--------------------------------+
|  vpc-XXXXXXXX  |  10.30.0.0/16  | ecommerce-eks-production-vpc   |
+----------------+----------------+--------------------------------+
```

## 6.2 Verify subnet count and tier breakdown

```powershell
# Total — should be 9
aws ec2 describe-subnets `
  --filters "Name=tag:Environment,Values=production" `
  --query 'length(Subnets[])'

# Per tier
aws ec2 describe-subnets `
  --filters "Name=tag:Environment,Values=production" `
  --query 'Subnets[].[Tags[?Key==`Tier`]|[0].Value,CidrBlock,AvailabilityZone]' `
  --output table
```

Expected: 9 subnets across `public/private/database` tiers, all in 3 AZs (`ap-south-1a`, `1b`, `1c`).

## 6.3 Verify HA NAT Gateways

```powershell
aws ec2 describe-nat-gateways `
  --filter "Name=tag:Environment,Values=production" `
  --query 'NatGateways[?State==`available`].[NatGatewayId,SubnetId,Tags[?Key==`Name`]|[0].Value]' `
  --output table
```

Should show **3 rows** in `available` state, one per AZ.

## 6.4 Verify Flow Logs

```powershell
aws ec2 describe-flow-logs `
  --filter "Name=tag:Environment,Values=production" `
  --query 'FlowLogs[].[FlowLogId,FlowLogStatus,LogDestination]' `
  --output table

# Verify the log group exists
aws logs describe-log-groups `
  --log-group-name-prefix "/aws/vpc/ecommerce-eks-production" `
  --query 'logGroups[].[logGroupName,retentionInDays]' `
  --output table
```

Should show the flow log in `ACTIVE` state and the CloudWatch log group with 30-day retention.

## 6.5 Verify state file in S3

```powershell
$BUCKET = (Get-Content .bucket-name)
aws s3 ls "s3://$BUCKET/environments/production/"
# Should show: terraform.tfstate

# Lockfile should be absent (released after apply)
aws s3 ls "s3://$BUCKET/environments/production/terraform.tfstate.tflock" 2>&1 |
  Out-String | ForEach-Object { if ($_ -match '404') { "✅ Lockfile released cleanly" } else { $_ } }
```

## 6.6 Verify CloudTrail audit (the GitOps story)

```powershell
aws cloudtrail lookup-events `
  --lookup-attributes AttributeKey=Username,AttributeValue=tf-deployer-production `
  --max-items 5 `
  --query 'Events[].[EventTime,EventName,Resources[0].ResourceName]' `
  --output table
```

You'll see recent API calls made by the production role — `CreateVpc`, `CreateSubnet`, `CreateNatGateway`, etc., all attributed to the `tf-deployer-production` role with the unique session name `gha-<run-id>-<attempt>-apply`.

This is the audit trail that says "this human approved deployment, this run did the work, here are the AWS resources it created."

---

# 🚨 Cost reminder

Production runs continuously costs roughly:

| Resource | Cost |
|---|---|
| 3 NAT Gateways | ~$96/month |
| VPC Flow Logs to CloudWatch | ~$2-5/month |
| EIPs (attached) | $0 |
| VPC + subnets + IGW + route tables | $0 |
| **Total** | **~$100/month idle** |

That's **~$3-4/day** for empty network plumbing.

When you're done validating, **destroy production** to avoid the bill.

---

# 🧹 Teardown — destroy production when done

```powershell
cd environments\production

terraform init -backend-config=backend.hcl
terraform destroy -var-file=production.tfvars
# Type "yes" when prompted

cd ..\..
```

Takes ~5-10 minutes. NAT Gateways are slow to delete.

When done, verify nothing's left:

```powershell
aws ec2 describe-vpcs `
  --filters "Name=tag:Environment,Values=production" `
  --query 'length(Vpcs)'
# Should return: 0
```

> 💡 **Want a destroy workflow instead?** Add `tf-destroy.yml` later that takes a manual `confirm: type DELETE` input and runs `terraform destroy` via OIDC. Same pattern as the unlock workflow.

---

# 🎯 What you've just demonstrated

By completing this runbook end-to-end, you've shown:

| Capability | Evidence |
|---|---|
| Multi-environment Terraform layout | `environments/dev/`, `environments/production/` |
| Same-shape, different-scale sizing | dev = 1 NAT, prod = 3 NATs (HA) |
| GitOps deployment via PR | `develop → main` promotion |
| Plan-binary integrity | `tfplan-production-*` artifact applied verbatim |
| OIDC auth (no static keys) | dev and prod use separate IAM roles, scoped per env |
| Reviewer-gated production | GitHub Environment with required reviewer |
| State backend isolation | Separate state files under one S3 bucket |
| Audit trail | CloudTrail entries with unique session names |
| Cost optimization | Optional flow logs, NAT count varies by env |

This is the **standard production-grade IaC pattern** — exactly what mid-to-large enterprises run.

---

# 🔁 Daily workflow after first deploy

```powershell
# Morning: sync
git checkout develop
git pull origin develop

# Make a change
git checkout -b feature/add-rds
# ...edit code...
git add .
git commit -m "feat: add RDS PostgreSQL for app database"
git push -u origin feature/add-rds

# Open PR feature/add-rds → develop
# Wait for plan, review, merge → dev applies automatically

# When dev is verified working:
# Open PR develop → main
# Wait for validate, merge → wait at "Review deployments"
# Approve → prod applies with the same change

# Total: ~30 min from change to production live
```

---

# 🆘 Troubleshooting

| Symptom | Fix |
|---|---|
| Production validate failing on backend.hcl | Make sure Phase 1.2 ran cleanly — bucket name should NOT be `CHANGE-ME` |
| `Could not assume role` on production plan | Verify the production GitHub Environment has `AWS_DEPLOY_ROLE_ARN` pointing at the prod role |
| Apply waits forever in "Waiting for review" | You haven't approved yet — go to the run, click "Review deployments", approve |
| `Artifact not found for tfplan-production-*` | Re-run the manual plan workflow from Phase 4.1 to regenerate the artifact, then re-run the failed apply |
| State lock stuck | Use `tf-statelock-unlock.yml` workflow with environment=production |
| `EIP quota exceeded` | AWS default is 5 EIPs per region. With dev (1) + prod (3) you're at 4. Request an increase if you also have other VPCs |

---

<div align="center">

**🎉 Production deployed via fully automated, gated GitOps.**

[⬆ Back to Top](#-production-deploy--from-dev-to-live-in-6-phases)

</div>
