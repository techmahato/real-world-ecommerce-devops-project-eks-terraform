# 🚀 SETUP — From Zero to First Deployment

> **What this guide does.** Walks anyone from a fresh GitHub fork of this repo to a live VPC in AWS, deployed via GitHub Actions. Every command is copy-paste-and-go. No CloudFormation troubleshooting, no surprises.
>
> **Time:** ~30 minutes end-to-end.
>
> **Prerequisites:** AWS account with admin access, GitHub account, AWS CLI v2, Terraform 1.10+, Git.

---

## 📑 Phases

| Phase | What | Time |
|---|---|---|
| **1** | One-time AWS setup | ~10 min |
| **2** | One-time GitHub setup | ~10 min |
| **3** | First deployment to dev | ~10 min |
| **4** | Cleanup (when done) | ~5 min |

---

# Phase 1 — One-time AWS setup

## 1.1 Verify your tools

```bash
aws --version          # need v2.x
terraform --version    # need >= 1.10
git --version
```

## 1.2 Configure AWS CLI

```bash
aws configure
# AWS Access Key ID:     <your IAM user key>
# AWS Secret Access Key: <your IAM user secret>
# Default region:        ap-south-1
# Default output:        json
```

Verify:

```bash
aws sts get-caller-identity
```

You should see your account ID and IAM user ARN.

## 1.3 Set the variables for this setup

```bash
# Edit these three values for your fork
export GITHUB_OWNER="your-github-username"
export GITHUB_REPO="real-world-ecommerce-devops-project-eks-terraform"
export AWS_REGION="ap-south-1"

# Auto-discovered — leave as-is
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $AWS_ACCOUNT_ID"
```

## 1.4 Create the GitHub OIDC provider (idempotent — safe to re-run)

This creates the OIDC provider only if it doesn't exist. AWS allows only one per issuer URL per account, so this command handles both fresh accounts and accounts where the provider already exists.

```bash
EXISTING_PROVIDER=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn" \
  --output text)

if [ -z "$EXISTING_PROVIDER" ]; then
  echo "OIDC provider not found — creating..."
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
  EXISTING_PROVIDER="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
  echo "Created: $EXISTING_PROVIDER"
else
  echo "OIDC provider already exists: $EXISTING_PROVIDER"
fi

export OIDC_PROVIDER_ARN="$EXISTING_PROVIDER"
```

## 1.5 Create the IAM role for **dev**

```bash
cat > /tmp/trust-dev.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:${GITHUB_OWNER}/${GITHUB_REPO}:environment:dev"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name tf-deployer-dev \
  --assume-role-policy-document file:///tmp/trust-dev.json \
  --max-session-duration 3600 \
  --description "GitHub Actions OIDC deployer role for dev"

aws iam attach-role-policy \
  --role-name tf-deployer-dev \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

export ROLE_ARN_DEV="arn:aws:iam::${AWS_ACCOUNT_ID}:role/tf-deployer-dev"
echo "Dev role: $ROLE_ARN_DEV"
```

> 💡 `AdministratorAccess` is fine for first-test. Tighten to least-privilege when you go live with real data.

## 1.6 Create the IAM role for **production**

```bash
cat > /tmp/trust-prod.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:${GITHUB_OWNER}/${GITHUB_REPO}:environment:production"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name tf-deployer-production \
  --assume-role-policy-document file:///tmp/trust-prod.json \
  --max-session-duration 3600 \
  --description "GitHub Actions OIDC deployer role for production"

aws iam attach-role-policy \
  --role-name tf-deployer-production \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

export ROLE_ARN_PROD="arn:aws:iam::${AWS_ACCOUNT_ID}:role/tf-deployer-production"
echo "Prod role: $ROLE_ARN_PROD"

rm /tmp/trust-dev.json /tmp/trust-prod.json
```

## 1.7 Verify both roles exist

```bash
aws iam list-roles \
  --query 'Roles[?starts_with(RoleName, `tf-deployer-`)].[RoleName,Arn]' \
  --output table
```

Expected output:

```
tf-deployer-dev          arn:aws:iam::ACCOUNT:role/tf-deployer-dev
tf-deployer-production   arn:aws:iam::ACCOUNT:role/tf-deployer-production
```

**Save both ARNs** — you'll paste them into GitHub in Phase 2.

## 1.8 Bootstrap the S3 state bucket

```bash
cd bootstrap

# Generate a globally-unique bucket name
BUCKET_NAME="ecommerce-eks-tfstate-${AWS_ACCOUNT_ID}-$(date +%s)"
echo "Bucket: $BUCKET_NAME"

# Create the tfvars file
cat > terraform.tfvars <<EOF
aws_region        = "${AWS_REGION}"
project_name      = "ecommerce-eks"
state_bucket_name = "${BUCKET_NAME}"
EOF

# Apply
terraform init
terraform apply -auto-approve

# Save the bucket name to the parent directory for later steps
echo "$BUCKET_NAME" > ../.bucket-name
echo ""
echo "✅ State bucket created: $BUCKET_NAME"
echo "✅ Saved to: ../.bucket-name"

cd ..
```

## 1.9 Wire the bucket name into both `backend.hcl` files

```bash
BUCKET_NAME=$(cat .bucket-name)

# Update dev backend
sed -i "s|ecommerce-eks-tfstate-CHANGE-ME|${BUCKET_NAME}|" environments/dev/backend.hcl

# Update production backend
sed -i "s|ecommerce-eks-tfstate-CHANGE-ME|${BUCKET_NAME}|" environments/production/backend.hcl

# Verify
grep bucket environments/dev/backend.hcl environments/production/backend.hcl
```

> 🍎 **macOS users:** replace `sed -i` with `sed -i ''` (empty string after `-i`) for both lines above.

## 1.10 Commit and push the backend wiring

```bash
git add environments/dev/backend.hcl environments/production/backend.hcl
git commit -m "chore: wire S3 state bucket into backend configs"
git push origin main
```

---

# Phase 2 — One-time GitHub setup

This is all in the GitHub web UI.

## 2.1 Repository Variables

Go to: **Settings → Secrets and variables → Actions → Variables tab → New repository variable**

| Name | Value |
|---|---|
| `AWS_REGION` | `ap-south-1` |
| `AWS_DEPLOY_ROLE_ARN` | `<ROLE_ARN_DEV from Phase 1.5>` |

## 2.2 Create the `dev` Environment

**Settings → Environments → New environment** → name it **`dev`**

Inside the `dev` environment:

- **Required reviewers:** ❌ off (auto-deploy for dev)
- **Wait timer:** 0
- **Deployment branches and tags:** **No restriction** *(top option in the dropdown)*

  > ⚠️ **Why "No restriction" for dev?** The plan workflow needs to run against PRs, and GitHub evaluates PRs as a synthetic merge ref (`refs/pull/N/merge`) which is **neither a branch nor a tag** — it cannot be matched by any "Selected branches and tags" rule. Without "No restriction" you'll see: *"Branch refs/pull/N/merge is not allowed to deploy to dev due to environment protection rules."*
  >
  > This is safe because the **IAM trust policy** (with the pinned `sub` claim `repo:OWNER/REPO:environment:dev`) is the real security boundary, not the GitHub branch policy. Production keeps the strict "Selected branches and tags" rule below.

Then click **Add variable** and add:

| Name | Value |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | `<ROLE_ARN_DEV>` |

## 2.3 Create the `production` Environment

**Settings → Environments → New environment** → name it **`production`**

- **Required reviewers:** ✅ on — add yourself (or your team)
- **Wait timer:** 0 (or 5 min for extra safety)
- **Deployment branches and tags:** **Selected branches and tags** → add only one branch:
  - **Branch:** `main`

  > 💡 **Why strict for production but loose for dev?** The plan workflow runs against `dev` on every PR (so dev needs to allow PR merge refs). Production plans only run via manual `workflow_dispatch`, and apply only fires on a merge to `main`. So `main` is the only ref that ever needs to deploy to production.

Then click **Add variable** and add:

| Name | Value |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | `<ROLE_ARN_PROD from Phase 1.6>` |

## 2.4 Create the `develop` branch

Locally:

```bash
git checkout main
git pull
git checkout -b develop
git push -u origin develop
```

## 2.5 Branch protection on `develop` and `main`

**Settings → Branches → Add branch protection rule** — do this **twice**.

### For `develop`

Branch name pattern: `develop`

Check the following:

- ✅ Require a pull request before merging
- ✅ Required approvals: `0` (solo-dev convenience; raise to `1` when you have a teammate)
- ✅ Require status checks to pass before merging *(leave the dropdown empty for now — checks appear after the first PR runs them once)*
- ✅ Require branches to be up to date before merging
- ✅ Do not allow bypassing the above settings

### For `main`

Branch name pattern: `main`

Same as `develop`, but:

- ✅ Required approvals: `0` (raise to `1` later)
- ✅ Restrict deletions
- ✅ Disallow force-pushes

> 💡 After your first PR completes, return here and add the required status checks: `Validate (dev)`, `Validate (production)`, `Plan (dev)`. They only appear in the dropdown once they've run at least once.

---

# Phase 3 — First deployment

## 3.1 Open your first PR

```bash
git checkout develop
git pull

git checkout -b feature/initial-vpc

# No code changes needed — the VPC code is already in place.
git push -u origin feature/initial-vpc
```

In GitHub:

1. Go to your repo → **Pull requests → New pull request**
2. **base:** `develop` ← **compare:** `feature/initial-vpc`
3. **Title:** `feat: initial 3-tier VPC for dev`
4. **Description:** `First deployment to validate the full pipeline.`
5. Click **Create pull request**

## 3.2 Watch the workflows run

In the **Actions** tab, two workflows fire:

- **Terraform Validate** — runs across `dev` and `production` (matrix). Should turn green in 2–3 min.
- **Terraform Plan** — OIDC handshake, init, plan. Posts a comment on your PR.

Wait ~3–5 minutes. The PR should get a comment like:

```
### 📋 Terraform Plan — `dev`

| Step | Status |
|------|--------|
| init | success |
| validate | success |
| plan | success |

Plan: 24 to add, 0 to change, 0 to destroy.
```

## 3.3 Review the plan

Click **Show full plan** and scan for:

- ✅ 1 × `aws_vpc` (CIDR `10.10.0.0/16`)
- ✅ 9 × `aws_subnet` (3 public + 3 private + 3 database)
- ✅ 1 × `aws_internet_gateway`
- ✅ 1 × `aws_nat_gateway` + 1 × `aws_eip` *(only one in dev — by design)*
- ✅ Route tables for each tier
- ✅ 1 × `aws_db_subnet_group`
- ✅ 1 × `aws_elasticache_subnet_group`
- ✅ Tags: `Project=ecommerce-eks`, `Environment=dev`, `ManagedBy=terraform`

## 3.4 Merge to deploy

Click **Squash and merge** on the PR.

In the **Actions** tab, **Terraform Apply** fires:

1. `determine-env` job decides `target=dev`
2. Apply job runs in environment `dev` (no reviewer gate)
3. Downloads the saved plan binary
4. Runs `terraform apply tfplan.binary`
5. Resources created in AWS

Takes ~3–4 minutes (NAT Gateway is the slow part).

## 3.5 Verify in AWS

```bash
# VPC
aws ec2 describe-vpcs \
  --filters "Name=tag:Environment,Values=dev" \
  --query 'Vpcs[].[VpcId,CidrBlock,Tags[?Key==`Name`]|[0].Value]' \
  --output table

# 9 subnets across 3 tiers
aws ec2 describe-subnets \
  --filters "Name=tag:Environment,Values=dev" \
  --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,CidrBlock,AvailabilityZone,Tags[?Key==`Tier`]|[0].Value]' \
  --output table

# State file landed in S3
BUCKET_NAME=$(cat .bucket-name)
aws s3 ls s3://${BUCKET_NAME}/environments/dev/

# Lockfile released (404 is correct — means no run is currently locked)
aws s3 ls s3://${BUCKET_NAME}/environments/dev/terraform.tfstate.tflock 2>&1 || echo "✅ No lockfile — clean state."
```

🎉 **You've deployed via GitHub Actions.**

---

# Phase 4 — Cleanup (when done testing)

A 3-tier VPC with one NAT Gateway costs **~$30–40/month** if left running. To tear it down:

## 4.1 Destroy the VPC

```bash
cd environments/dev
terraform init -backend-config=backend.hcl
terraform destroy -var-file=dev.tfvars
# Type "yes" to confirm
cd ../..
```

## 4.2 (Optional) Empty and delete the state bucket

Only if you're abandoning the project entirely:

```bash
BUCKET_NAME=$(cat .bucket-name)
aws s3 rm s3://${BUCKET_NAME} --recursive
# Note: bootstrap was created with force_destroy=false. To delete the bucket,
# either re-apply bootstrap with force_destroy=true first, or delete manually.
```

## 4.3 (Optional) Delete the IAM roles

```bash
aws iam detach-role-policy --role-name tf-deployer-dev \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam delete-role --role-name tf-deployer-dev

aws iam detach-role-policy --role-name tf-deployer-production \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam delete-role --role-name tf-deployer-production
```

The OIDC provider is shared with any other project that uses GitHub Actions in this account, so leave it.

---

# 🚨 Troubleshooting — known issues and fixes

| Symptom | Cause | Fix |
|---|---|---|
| `Provider with url ... already exists` | OIDC provider was created by a previous project | Phase 1.4 handles this automatically — re-run that step |
| `Branch "refs/pull/N/merge" is not allowed to deploy to dev due to environment protection rules` | Environment's deployment-branch policy blocks PR merge refs (which are not branches or tags) | On the **dev** environment, set **Deployment branches and tags** → **No restriction** (Phase 2.2). The `refs/pull/*/merge` tag pattern does NOT work — PR refs are synthetic and cannot be matched by tag rules. |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy `sub` claim doesn't match | Verify GitHub Environment name (`dev` or `production`) and that you committed the workflow with the matching environment |
| `Error: Backend initialization required` | `backend.hcl` still has the placeholder | Re-run Phase 1.9 to inject the real bucket name |
| Workflow doesn't trigger on PR | Path filter excludes the changed files | Make sure changes are inside `environments/`, `modules/`, or `.github/workflows/` |
| Workflow runs but plan fails with `NoSuchBucket` | `backend.hcl` typo or wrong bucket | Verify with `aws s3 ls s3://BUCKET_NAME/` and re-run Phase 1.9 |
| Apply waits forever in "Waiting for review" | `production` environment has required reviewers but you haven't approved | Go to Actions tab → Click the run → "Review deployments" → Approve and deploy |
| EIP quota exceeded | Default AWS quota is 5 EIPs per region | Request a quota increase, or destroy other test VPCs |
| `Error acquiring the state lock` | Previous run died, lock not released | Use the `tf-statelock-unlock.yml` workflow (Actions → Run workflow → enter the lock ID) |

---

# 📌 Quick reference

| What | Where |
|---|---|
| State bucket name | `.bucket-name` (gitignored) |
| Dev role ARN | GitHub Variables: `AWS_DEPLOY_ROLE_ARN` (in `dev` environment) |
| Prod role ARN | GitHub Variables: `AWS_DEPLOY_ROLE_ARN` (in `production` environment) |
| Dev branch | `develop` |
| Prod branch | `main` |
| Dev VPC CIDR | `10.10.0.0/16` |
| Prod VPC CIDR | `10.30.0.0/16` |
| NAT in dev | 1 (shared) |
| NAT in prod | 3 (per AZ) |
| State backend | S3 with native locking (`use_lockfile = true`) |

---

# 🔁 Daily workflow (after setup is complete)

```bash
# Start of day — sync
git checkout develop
git pull

# New change
git checkout -b feature/my-change
# ...edit code...
git add .
git commit -m "feat: my change"
git push -u origin feature/my-change

# Open PR via GitHub UI: feature/my-change → develop
# Wait for plan comment, review it, merge.
# Apply runs automatically. VPC updates in dev.

# When ready for prod:
# Open PR: develop → main
# Merge, approve in Actions tab, apply runs against prod.
```

---

<div align="center">

**Now anyone with this guide can go from a fresh fork to a deployed VPC in under 30 minutes.**

</div>
