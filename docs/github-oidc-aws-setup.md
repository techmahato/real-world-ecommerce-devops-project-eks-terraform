# 🔐 GitHub Actions ↔ AWS — Secure OIDC Authentication Setup

> **Goal:** Let GitHub Actions deploy to AWS **without ever storing long-lived AWS access keys** in GitHub Secrets.
>
> **Why it matters here:** This repository is **public**. Even one accidentally-committed `AWS_ACCESS_KEY_ID` could compromise the entire AWS account. OIDC eliminates that risk by using short-lived, workflow-scoped credentials.

---

## 📑 Table of Contents

1. [The Problem We're Solving](#1-the-problem-were-solving)
2. [What Is OIDC, in Plain English?](#2-what-is-oidc-in-plain-english)
3. [How the Trust Flow Works](#3-how-the-trust-flow-works)
4. [Key Concepts & Terminology](#4-key-concepts--terminology)
5. [Prerequisites](#5-prerequisites)
6. [Step-by-Step Setup](#6-step-by-step-setup)
7. [GitHub Actions Workflow Configuration](#7-github-actions-workflow-configuration)
8. [Security Best Practices](#8-security-best-practices)
9. [Troubleshooting](#9-troubleshooting)
10. [FAQ](#10-faq)
11. [References](#11-references)

---

## 1. The Problem We're Solving

### ❌ The Old Way — Long-Lived IAM User Access Keys

Traditionally, teams created an IAM user, generated an `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, and pasted them into GitHub Secrets.

**Why this is dangerous, especially in a public repo:**

| Risk | Impact |
|---|---|
| Keys never rotate automatically | A leaked key stays valid until manually revoked |
| Hard to scope per-repo or per-branch | One leak = full account access |
| Shows up in logs, screenshots, fork PRs | Public repos amplify exposure |
| No native expiration | Attackers can use stolen keys for months |
| Audit trail is generic | CloudTrail just shows the IAM user, not which workflow ran |

### ✅ The New Way — OIDC Federation

Instead of pre-shared static keys, GitHub and AWS perform a **trust handshake** every time a workflow runs:

- GitHub mints a fresh, signed **JSON Web Token (JWT)** describing the workflow.
- AWS verifies the token, checks who it's from, and hands back **temporary credentials** (default: 1 hour).
- Nothing secret is stored on either side.

**Result:** zero long-lived secrets, scoped-down access, automatic rotation, and detailed audit logs.

---

## 2. What Is OIDC, in Plain English?

**OIDC = OpenID Connect** — a standard protocol for one system to vouch for an identity to another.

Think of it like an airport:

- 🛂 **GitHub** is the issuing country — it gives you a passport (the OIDC token).
- ✈️ **AWS** is the destination country — it inspects your passport against its rules (the trust policy).
- ✅ If your passport is genuine and you match the entry rules, AWS issues a temporary visa (STS credentials) valid for one hour.
- 🔒 No master key is ever exchanged.

In our case:
- GitHub is the **OIDC Identity Provider (IdP)** at `https://token.actions.githubusercontent.com`
- AWS IAM is configured to **trust that IdP**
- An IAM Role defines **who from GitHub** is allowed to assume it, and **what they can do**

---

## 3. How the Trust Flow Works

```text
┌──────────────────────────────────────────────────────────────┐
│                  GitHub Actions Workflow                     │
│                                                              │
│  1. A push / PR / manual trigger fires the workflow          │
│  2. GitHub generates a short-lived OIDC JWT                  │
│  3. The JWT contains claims:                                 │
│       • repo:owner/repo                                      │
│       • ref (branch / tag)                                   │
│       • workflow name                                        │
│       • environment (if any)                                 │
└────────────────────────────┬─────────────────────────────────┘
                             │ OIDC Token (JWT)
                             ▼
┌──────────────────────────────────────────────────────────────┐
│                   AWS IAM OIDC Provider                      │
│                                                              │
│  4. AWS fetches GitHub's public keys                         │
│  5. AWS validates the JWT signature                          │
│  6. AWS verifies the audience (sts.amazonaws.com)            │
│  7. AWS checks the claims against the IAM Role trust policy  │
└────────────────────────────┬─────────────────────────────────┘
                             │ Validation Success
                             ▼
┌──────────────────────────────────────────────────────────────┐
│                    AWS IAM Role (Assumed)                    │
│                                                              │
│  8. STS:AssumeRoleWithWebIdentity is invoked                 │
│  9. Trust policy conditions evaluated:                       │
│       • Is this the right repo?                              │
│       • Is this the right branch / environment?              │
│  10. Temporary credentials issued (default 1 hour)           │
└────────────────────────────┬─────────────────────────────────┘
                             │ Temporary AWS Credentials
                             ▼
┌──────────────────────────────────────────────────────────────┐
│                 Terraform / kubectl / AWS CLI                │
│                                                              │
│  11. Workflow uses temp credentials to plan/apply IaC        │
│  12. Every API call logged in CloudTrail with session name   │
└──────────────────────────────────────────────────────────────┘
```

**Notice three things:**

1. The token is **freshly minted per workflow run** — it cannot be replayed later.
2. The trust policy is the **enforcement boundary** — even with a valid GitHub token, AWS will reject the request if the repo/branch doesn't match.
3. CloudTrail shows the **session name**, so you can trace exactly which workflow run made which API call.

---

## 4. Key Concepts & Terminology

| Term | What It Means |
|---|---|
| **OIDC Identity Provider (IdP)** | A registered entity in AWS IAM (`token.actions.githubusercontent.com`) that AWS trusts to vouch for identities. |
| **Audience (`aud`)** | The intended recipient of the token. For AWS, this is `sts.amazonaws.com`. |
| **Subject (`sub`)** | The token's "who" claim — for GitHub, `repo:OWNER/REPO:ref:refs/heads/main`, `repo:OWNER/REPO:environment:production`, etc. |
| **Thumbprint** | A SHA-1 fingerprint of GitHub's TLS certificate. AWS uses it to verify the IdP. *(In modern AWS, when using the GitHub IdP URL, AWS auto-manages thumbprints — the value below is the historical default.)* |
| **Trust Policy** | The IAM Role document that says **"this role can be assumed if the OIDC token's claims match these conditions."** This is your real security boundary. |
| **Permissions Policy** | What the assumed role is allowed to do **after** it's assumed (e.g., create EKS clusters, write to S3). |
| **`AssumeRoleWithWebIdentity`** | The STS API call that exchanges an OIDC token for temporary AWS credentials. |
| **`id-token: write`** | The GitHub Actions workflow permission required for the runner to request an OIDC token. |

---

## 5. Prerequisites

Before starting, make sure you have:

- ✅ An **AWS account** with permission to create IAM resources and run CloudFormation stacks.
- ✅ A **GitHub repository** (this one) where workflows will run.
- ✅ Knowledge of your GitHub **org/user name** and **repo name** — needed to scope the trust policy.
- ✅ Optionally, a **least-privilege IAM policy** prepared. (`AdministratorAccess` works for learning, but is **not** recommended for production.)

---

## 6. Step-by-Step Setup

### Step 1 — Run the CloudFormation Template

A community-maintained template provisions both the OIDC provider and the assumable role in one shot:

🔗 **Template:** [`oidc-github-role.yml`](https://github.com/CWM-Kolkata/cwm-cloudformation-templates/blob/main/github/oidc-github-role.yml)

In the AWS Console → **CloudFormation → Create stack → Upload a template file**, paste the YAML above and click **Next**.

### Step 2 — Fill in the CloudFormation Parameters

| Parameter | Value to Use | Why |
|---|---|---|
| **AudienceList** | `sts.amazonaws.com` (default) | The audience claim AWS expects in the OIDC token. |
| **GithubActionsThumbprint** | `6938fd4d98bab03faadb97b34396831e3780aea1` (default) | Historical thumbprint of GitHub's TLS cert. AWS now manages this automatically for the GitHub IdP, but the field is still required. |
| **ManagedPolicyARNs** | Attach a least-privilege policy ARN; `AdministratorAccess` is the simplest for learning | Defines what the role can do *after* assumption. **For production, use a custom least-privilege policy.** |
| **SubjectClaimFilters** | `repo:<GithubOrg>/<RepoName>:*` <br> e.g., `repo:arbindmahato/real-world-ecommerce-devops-project-eks-terraform:*` | Restricts which GitHub repo (and optionally which branches/environments) can assume this role. |

> ⚠️ **Why `SubjectClaimFilters` is the most important field:**
> Even though anyone in the world can request a GitHub OIDC token, AWS will only let the token assume your role if the `sub` claim matches this filter. If you misconfigure this to `repo:*:*`, **any GitHub repo on the internet** could assume your role.

### Step 3 — Tighten the Subject Filter (Recommended)

Instead of `repo:OWNER/REPO:*` (which allows **any** branch, tag, or PR), narrow scope:

| Use Case | Subject Pattern |
|---|---|
| Allow only `main` branch | `repo:OWNER/REPO:ref:refs/heads/main` |
| Allow only the `production` environment | `repo:OWNER/REPO:environment:production` |
| Allow only release tags | `repo:OWNER/REPO:ref:refs/tags/v*` |
| Allow PRs from same repo (not forks) | `repo:OWNER/REPO:pull_request` |

For a public repo, **avoid** broad patterns. **Pull requests from forks should never be able to assume a deploy role** — restrict by branch or environment.

### Step 4 — Deploy the Stack

Click **Next → Next → Create stack**. Wait for the status to reach `CREATE_COMPLETE`.

### Step 5 — Capture the Role ARN

In the CloudFormation **Outputs** tab you'll see the ARN of the new IAM role:

```text
arn:aws:iam::123456789012:role/Terraform-deployer-role
```

You'll plug this ARN into your GitHub Actions workflow.

---

## 7. GitHub Actions Workflow Configuration

### 7.1 — Required Workflow Permissions

At the top of your workflow file, you **must** request `id-token: write`. Without this, the runner cannot mint an OIDC token.

```yaml
permissions:
  id-token: write   # Required to request the OIDC JWT from GitHub
  contents: read    # Required to checkout the repo
```

### 7.2 — Environment Variables

```yaml
env:
  AWS_REGION: ap-south-1
  ROLE_TO_ASSUME: "arn:aws:iam::123456789012:role/Terraform-deployer-role"
  AWS_SESSION_NAME: "github-actions-terraform-deployer"
```

> 💡 The Role ARN is **not a secret** — it's just an identifier. It's safe to commit to a public repo. The trust policy is what protects it.

### 7.3 — Assume the Role Step

```yaml
- name: Configure AWS Credentials via OIDC
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ env.ROLE_TO_ASSUME }}
    role-session-name: ${{ env.AWS_SESSION_NAME }}
    aws-region: ${{ env.AWS_REGION }}
```

This action:
1. Asks GitHub for an OIDC token.
2. Calls `sts:AssumeRoleWithWebIdentity` against your IAM Role.
3. Exports `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_SESSION_TOKEN` as environment variables for **subsequent steps in the same job**.

### 7.4 — Complete Example Workflow

```yaml
name: Terraform — Deploy EKS

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: ap-south-1
  ROLE_TO_ASSUME: "arn:aws:iam::123456789012:role/Terraform-deployer-role"
  AWS_SESSION_NAME: "github-actions-terraform-deployer"

jobs:
  terraform:
    name: Terraform Plan & Apply
    runs-on: ubuntu-latest
    environment: production

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS Credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ env.ROLE_TO_ASSUME }}
          role-session-name: ${{ env.AWS_SESSION_NAME }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Verify caller identity
        run: aws sts get-caller-identity

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.6.6

      - name: Terraform Init
        run: terraform init
        working-directory: terraform/environments/dev

      - name: Terraform Plan
        run: terraform plan -out=tfplan
        working-directory: terraform/environments/dev

      - name: Terraform Apply
        if: github.ref == 'refs/heads/main'
        run: terraform apply -auto-approve tfplan
        working-directory: terraform/environments/dev
```

---

## 8. Security Best Practices

Because this is a **public repository**, every choice below matters more than usual.

| ✅ Do | ❌ Don't |
|---|---|
| Scope `SubjectClaimFilters` to a specific branch or environment | Use `repo:*:*` or any wildcard owner |
| Use **GitHub Environments** (`production`, `staging`) and restrict role assumption to those environments | Allow PRs from forks to assume a deploy role |
| Apply **least-privilege** IAM policies — only the actions Terraform actually needs | Attach `AdministratorAccess` to a long-lived production role |
| Use separate roles per environment (`dev`, `staging`, `prod`) | Share one all-powerful role across environments |
| Set short session duration (1 hour default is fine) | Extend session duration unless absolutely needed |
| Enable **CloudTrail** and alert on `AssumeRoleWithWebIdentity` from unexpected sources | Treat CloudTrail as a "set and forget" service |
| Add a **branch protection rule** so only `main` can deploy | Allow direct pushes to `main` from any contributor |
| Require **manual approval** in GitHub Environments for production | Auto-deploy to production on every merge without review |
| Tag the IAM role with `Project`, `Owner`, `Environment` for cost & audit | Leave roles unlabelled |

### 🚨 Specific to public repos

- **Never** echo `aws sts get-caller-identity` output, secret values, or env vars in pull request workflows from forks.
- Restrict the trust policy so PR runs from forks **cannot** assume the role at all. The safest pattern is to require an `environment:` scoped subject claim and configure the GitHub Environment with reviewer approval.
- Use **OpenSSF Scorecard** and **Dependabot** to keep workflow actions pinned and updated.

---

## 9. Troubleshooting

| Error Message | Likely Cause | Fix |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Subject claim doesn't match trust policy | Check `repo`, `ref`, and `environment` in the trust policy condition |
| `Error: Could not assume role with OIDC: No OpenIDConnect provider found` | OIDC provider not created in this AWS account/region | Re-run the CloudFormation stack |
| `Token retrieval error: missing id-token permission` | Workflow doesn't request `id-token: write` | Add `permissions: id-token: write` at job or workflow level |
| `Audience claim is invalid` | `aud` in token ≠ `sts.amazonaws.com` | Ensure `audience` parameter (if set) matches the IdP's audience list |
| Works on `main` but fails on PRs | Subject filter restricts to `main` only | Either widen filter intentionally or block PR runs (recommended for public repos) |

To debug a specific run, decode the OIDC token claims (carefully, never in public logs) using `actions/github-script` and inspect the `sub`, `ref`, and `environment` fields.

---

## 10. FAQ

**Q: Is the IAM Role ARN a secret?**
A: No. It's an identifier. The trust policy is what protects it. You can safely commit ARNs to a public repo.

**Q: What if my AWS account already has the GitHub OIDC provider configured?**
A: AWS only allows **one** OIDC provider per issuer URL. Skip the provider-creation portion of the CloudFormation template (or import the existing provider) and create only the IAM Role.

**Q: How long do the temporary credentials last?**
A: Default is 1 hour. You can extend up to the role's `MaxSessionDuration` (max 12 hours), but shorter is safer.

**Q: Do I still need GitHub Secrets at all?**
A: For AWS, no. For other things (Slack webhook, Docker Hub token, etc.) you may still use Secrets — but no AWS keys.

**Q: Can multiple repos share one role?**
A: Yes — list all repos in `SubjectClaimFilters`. But it's usually cleaner to have one role per repo or per environment.

**Q: What about self-hosted runners?**
A: OIDC works on self-hosted runners too, as long as they can reach `https://token.actions.githubusercontent.com` and AWS STS endpoints.

---

## 11. References

- AWS — [Configuring OpenID Connect in Amazon Web Services](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)
- GitHub — [About security hardening with OpenID Connect](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)
- GitHub — [Configuring OpenID Connect in Amazon Web Services](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- Action — [`aws-actions/configure-aws-credentials`](https://github.com/aws-actions/configure-aws-credentials)
- CloudFormation template used — [`CWM-Kolkata/cwm-cloudformation-templates`](https://github.com/CWM-Kolkata/cwm-cloudformation-templates/blob/main/github/oidc-github-role.yml)

---

<div align="center">

**🔒 No long-lived AWS keys. Scoped per repo, per branch, per environment. Audited end-to-end.**

[⬆ Back to Top](#-github-actions--aws--secure-oidc-authentication-setup)

</div>
