# 🚀 Terraform CI/CD with GitHub Actions — From Basics to Production-Grade

> **Who this is for:** Anyone — from a first-day DevOps intern to a mid-level engineer — who wants to *truly* understand how to build a safe, auditable Terraform deployment pipeline on GitHub Actions. By the end of this doc you should be able to read **any** GitHub Actions workflow with confidence and explain *why* every line exists.
>
> **How this doc is structured:** We start with the absolute basics (what is a workflow?), build up the mental model brick by brick, walk through a **realistic production workflow YAML** block by block, then ship a clean, copy-paste-ready deployment workflow you can use in this project.

---

## 📑 Table of Contents

### Part 1 — Foundations

1. [Why CI/CD for Terraform?](#1-why-cicd-for-terraform)
2. [GitHub Actions — The Mental Model](#2-github-actions--the-mental-model)
3. [Anatomy of a Workflow File](#3-anatomy-of-a-workflow-file)
4. [The Standard Terraform Pipeline](#4-the-standard-terraform-pipeline)
5. [Plan-on-PR vs. Apply-on-Merge](#5-plan-on-pr-vs-apply-on-merge)
6. [Folder Structure Patterns](#6-folder-structure-patterns)

### Part 2 — Deep Dive Into a Real Workflow

7. [The Big Picture — What This Workflow Does](#7-the-big-picture--what-this-workflow-does)
8. [The Trigger Block (`on:`)](#8-the-trigger-block-on)
9. [The Permissions Block](#9-the-permissions-block)
10. [The Environment Variables Block](#10-the-environment-variables-block)
11. [Job 1 — `plan` (runs on PR open/sync/reopen)](#11-job-1--plan-runs-on-pr-opensyncreopen)
12. [Job 2 — `apply` (runs after merge)](#12-job-2--apply-runs-after-merge)
13. [End-to-End Flow Diagram](#13-end-to-end-flow-diagram)

### Part 3 — Production Engineering

14. [Wiring in OIDC Authentication](#14-wiring-in-oidc-authentication)
15. [Environment Variables & Secrets — Four Mechanisms](#15-environment-variables--secrets--four-mechanisms)
16. [Branch Protection & Approval Gates](#16-branch-protection--approval-gates)
17. [Best-Practice Deployment Workflow Files](#17-best-practice-deployment-workflow-files)
18. [State Lock Recovery Workflow](#18-state-lock-recovery-workflow)
19. [Common Gotchas & Why Each Safety Net Exists](#19-common-gotchas--why-each-safety-net-exists)
20. [Troubleshooting](#20-troubleshooting)
21. [Glossary — Plain English Definitions](#21-glossary--plain-english-definitions)
22. [Quick-Reference Cheat Sheet](#22-quick-reference-cheat-sheet)
23. [References](#23-references)

---

# Part 1 — Foundations

## 1. Why CI/CD for Terraform?

Terraform without CI/CD usually looks like this:

> *"Let me just `terraform apply` from my laptop real quick…"*

That single sentence has caused more production outages than almost any other phrase in DevOps. The problems:

- 🚫 **No review** — changes happen with no second pair of eyes.
- 🚫 **No history** — who applied what, when, with which variables? Nobody knows.
- 🚫 **Drift** — laptops have different Terraform versions, plugin versions, AWS profiles.
- 🚫 **Secrets on disk** — long-lived AWS keys in `~/.aws/credentials`.
- 🚫 **Lock conflicts** — two engineers apply at the same time, state corrupts.

A proper CI/CD pipeline solves all of this:

| Benefit | How |
|---|---|
| **Every change is reviewed** | `terraform plan` posts to the PR; merge requires approval |
| **Every change is auditable** | GitHub Actions logs + CloudTrail show exactly who/what/when |
| **Reproducible runs** | Pinned Terraform version, pinned providers, pinned action versions |
| **No keys on disk** | OIDC mints short-lived credentials per run |
| **Serialized applies** | GitHub concurrency groups + remote state locking prevent race conditions |
| **Automatic gates** | Branch protection enforces "no merge without green plan + approval" |

---

## 2. GitHub Actions — The Mental Model

Before writing a single line of YAML, anchor these five terms:

| Term | What It Is |
|---|---|
| **Workflow** | A single YAML file under `.github/workflows/` that describes an automated process. |
| **Event** | The trigger that starts a workflow — `push`, `pull_request`, `workflow_dispatch` (manual), `schedule`, etc. |
| **Job** | A group of steps that run together on one runner. Multiple jobs in a workflow run in parallel by default. |
| **Step** | A single command or action invocation inside a job. Steps in a job run sequentially and share the same filesystem. |
| **Runner** | The virtual machine that executes a job. GitHub-hosted runners (`ubuntu-latest`, `windows-latest`, `macos-latest`) are free for public repos. |

### Visualizing it

```text
WORKFLOW (file: .github/workflows/terraform.yml)
│
├── on: pull_request, push   ← EVENTS (when to run)
│
└── jobs:
    │
    ├── JOB: terraform-plan    (runs on ubuntu-latest)
    │   ├── step 1: checkout
    │   ├── step 2: configure AWS via OIDC
    │   ├── step 3: terraform init
    │   ├── step 4: terraform plan
    │   └── step 5: comment plan on PR
    │
    └── JOB: terraform-apply   (runs on ubuntu-latest, depends on plan)
        ├── step 1: checkout
        ├── step 2: configure AWS via OIDC
        ├── step 3: terraform init
        └── step 4: terraform apply
```

### What is Terraform doing in this picture?

Terraform is just a **CLI tool**. The workflow installs it, points it at AWS, and runs commands like `terraform plan` and `terraform apply` from the runner. Nothing magical — Terraform doesn't "know" it's inside CI.

### Why two phases — Plan and Apply?

- **Plan** = *"Show me what would change if I applied this code."* Read-only. Safe.
- **Apply** = *"Actually make those changes in AWS."* Destructive. Irreversible.

The whole point of Terraform CI/CD is: **let the team review the plan before anyone applies it.**

---

## 3. Anatomy of a Workflow File

Every workflow YAML has the same skeleton. Memorize this and the rest is detail.

```yaml
name: Terraform CI/CD                    # Display name in the Actions tab

on:                                      # ─── EVENTS that trigger the workflow
  pull_request:
    branches: [main]
  push:
    branches: [main]
  workflow_dispatch:                     # Allows manual triggering from UI

permissions:                             # ─── Token permissions for THIS run
  id-token: write                        # Needed for OIDC
  contents: read                         # Needed to checkout code
  pull-requests: write                   # Needed to comment plan on PR

env:                                     # ─── Workflow-wide environment vars
  AWS_REGION: ap-south-1
  TF_VERSION: "1.11.4"

concurrency:                             # ─── Prevent overlapping runs
  group: terraform-${{ github.ref }}
  cancel-in-progress: false

jobs:                                    # ─── One or more JOBS
  plan:
    name: Terraform Plan
    runs-on: ubuntu-latest               # The RUNNER
    steps:                               # ─── STEPS run in order
      - uses: actions/checkout@v4        # An "action" (reusable building block)
      - run: echo "hello"                # A raw shell command
```

### Key clauses, decoded

- **`on:`** — *when* it runs. `pull_request` fires on PR open/sync/reopen. `push` fires after a merge. `workflow_dispatch` adds a "Run workflow" button.
- **`permissions:`** — *what* the auto-generated `GITHUB_TOKEN` is allowed to do. Default is too broad; declare explicit permissions per workflow for safety.
- **`env:`** — workflow-level environment variables, available to every job and step.
- **`concurrency:`** — only one run per group at a time. Critical for Terraform — you never want two `apply` jobs racing on the same state.
- **`jobs:`** — at least one job. Each job is independent unless you wire them together with `needs:`.
- **`steps:`** — either `uses:` (run a pre-built action) or `run:` (execute shell commands).

---

## 4. The Standard Terraform Pipeline

The diagram below is the pattern this project follows — and the pattern most professional teams converge on:

```text
┌──────────────────────────────────────────────────────────────┐
│   1. Developer creates feature branch & opens Pull Request   │
└────────────────────────┬─────────────────────────────────────┘
                         ▼
┌──────────────────────────────────────────────────────────────┐
│   2. PR-Trigger Workflow: "terraform-plan"                   │
│      • terraform fmt -check    (style gate)                  │
│      • terraform validate      (syntax gate)                 │
│      • tflint / checkov        (lint + security gate)        │
│      • terraform init          (download providers, backend) │
│      • terraform plan -out=…   (compute the diff)            │
│      • Post plan as PR comment (human-readable summary)      │
└────────────────────────┬─────────────────────────────────────┘
                         ▼
┌──────────────────────────────────────────────────────────────┐
│   3. Code Review                                             │
│      • Reviewer reads plan output                            │
│      • At least 1 approving review                           │
│      • All required status checks must be green              │
└────────────────────────┬─────────────────────────────────────┘
                         ▼
┌──────────────────────────────────────────────────────────────┐
│   4. PR Merged to main                                       │
└────────────────────────┬─────────────────────────────────────┘
                         ▼
┌──────────────────────────────────────────────────────────────┐
│   5. Push-Trigger Workflow: "terraform-apply"                │
│      • terraform init                                        │
│      • terraform apply tfplan  (apply the reviewed plan)     │
│      • Post deployment summary to job log                    │
└──────────────────────────────────────────────────────────────┘
```

### Why this shape works

- **Plan is read-only** — safe to run on every PR, including from contributors.
- **Apply runs only after merge** — guaranteed to use code that passed review.
- **Apply runs on the protected branch** — no one can push directly without going through the PR process.
- **Both stages use OIDC** — no static AWS keys anywhere in GitHub.

---

## 5. Plan-on-PR vs. Apply-on-Merge

You'll see two camps when teams build these pipelines:

### Pattern A — Single workflow file with two jobs

One YAML file with both `plan` and `apply` jobs, gated by `if:` conditions on the PR's merge state. *(This is the pattern the deep-dive walkthrough below uses, because it's common in many real-world repos.)*

### Pattern B — Two separate workflow files

`terraform-plan.yml` triggered by `pull_request`, `terraform-apply.yml` triggered by `push` to `main`.

| File | Trigger | Job | Permissions | Failure Mode |
|---|---|---|---|---|
| `terraform-plan.yml` | `pull_request` | Plan + comment | Read-only AWS role | Blocks PR merge |
| `terraform-apply.yml` | `push` to `main` | Apply | Read/write AWS role | Alerts team, doesn't auto-rollback |

Benefits of the split:

- 🎯 **Different IAM roles** — the plan role can be read-only; only the apply role has write permissions.
- 🎯 **Different branch protection rules** — apply can require an environment with reviewers.
- 🎯 **Easier to reason about** — one file, one purpose.

**Recommendation for this project:** Start with Pattern A to learn, migrate to Pattern B when you add staging/prod environments. The [final workflow files](#17-best-practice-deployment-workflow-files) at the end of this doc use Pattern B.

---

## 6. Folder Structure Patterns

There are two production patterns for organizing Terraform code in a repo. Pick one and stick with it.

### 6.1 Root Folder Pattern

All Terraform files live at the **root** of the repository.

```text
real-world-ecommerce-devops-project-eks-terraform/
├── .github/
│   └── workflows/
│       ├── terraform-plan.yml
│       └── terraform-apply.yml
├── main.tf
├── variables.tf
├── outputs.tf
├── providers.tf
├── backend.tf
├── terraform.tfvars
└── README.md
```

**When to use:** small repos, single environment, one logical stack.
**Workflow `working-directory:`** = `.` (the repo root).

### 6.2 Sub Folder Pattern

Terraform code is organized into **environment** or **stack** subfolders.

```text
real-world-ecommerce-devops-project-eks-terraform/
├── .github/
│   └── workflows/
│       ├── terraform-plan.yml
│       └── terraform-apply.yml
├── terraform/
│   ├── modules/
│   │   ├── vpc/
│   │   ├── eks/
│   │   └── rds/
│   └── environments/
│       ├── dev/
│       │   ├── main.tf
│       │   ├── backend.tf
│       │   └── terraform.tfvars
│       ├── staging/
│       └── prod/
└── README.md
```

**When to use:** multiple environments, multiple stacks, larger teams. **(This is the recommended pattern for this EKS project.)**
**Workflow `working-directory:`** = `terraform/environments/dev` (or driven by a matrix).

### 6.3 Pattern comparison

| Concern | Root Pattern | Sub Pattern |
|---|---|---|
| Simplicity | ✅ Simpler | ⚠️ More moving parts |
| Multi-env support | ❌ Awkward | ✅ Native |
| Module reuse | ⚠️ Manual | ✅ First-class |
| Workflow complexity | ✅ One `working-directory` | ⚠️ Matrix or per-env workflows |
| Recommended for | Tiny/POC repos | Real production projects |

---

# Part 2 — Deep Dive Into a Real Workflow

This part walks through a **realistic Terraform workflow file** the way you'd actually find one in a production repo. Every line is explained: what it does, why it's there, and what would break without it.

## 7. The Big Picture — What This Workflow Does

The workflow handles the **entire lifecycle of an infrastructure change**:

```text
Developer opens PR  ──►  Workflow runs `plan` job
                         • Validates code (fmt, validate)
                         • Runs `terraform plan`
                         • Posts plan summary on PR
                              │
PR reviewer reads everything  │
PR approved & merged   ──►  Workflow runs `apply` job
                         • Re-initializes Terraform
                         • Runs `terraform apply` on the saved plan
                         • Infrastructure is now live in AWS
```

**One YAML file, two jobs, controlled by `if:` conditions.** When a PR is open, only `plan` runs. When a PR is merged, only `apply` runs.

---

## 8. The Trigger Block (`on:`)

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, closed]
    branches:
      - main
    paths-ignore:
      - '.github/**'
```

### What it means

| Line | Plain English |
|---|---|
| `on: pull_request:` | This workflow runs only on Pull Request events. |
| `types: [opened, synchronize, reopened, closed]` | Specifically when a PR is **opened**, **updated** (new commits pushed), **reopened**, or **closed**. |
| `branches: [main]` | Only fires on PRs that **target** the `main` branch. PRs into `develop` or feature branches are ignored. |
| `paths-ignore:` | Skip the workflow if **only** these paths changed. |

### What is `synchronize`?

It's the GitHub event name for *"the developer pushed new commits to an open PR."* Without this in the list, the workflow would only run when the PR is first opened — re-runs after fixing code wouldn't happen automatically.

### The `closed` event is sneaky

`closed` fires when a PR is closed for any reason — **whether merged or abandoned**. The workflow uses an `if:` filter on each job (`merged == true` vs `merged != true`) to figure out which case fired.

### Why `paths-ignore`?

If a PR only changes documentation or unrelated files, there's no point running Terraform. Skipping these paths saves CI minutes.

> ⚠️ **Caution:** Be careful what you put in `paths-ignore`. Excluding directories that *do* affect Terraform (like `modules/`) is a common bug — module changes change plans.

---

## 9. The Permissions Block

```yaml
permissions:
  id-token: write
  contents: read
  pull-requests: write
```

Every workflow run gets an auto-generated token called `GITHUB_TOKEN`. The `permissions:` block controls **what that token is allowed to do**.

| Permission | Why It's Needed |
|---|---|
| `id-token: write` | **Required for OIDC.** Without this, the runner cannot mint the JWT that AWS verifies. |
| `contents: read` | Lets the workflow read the repo (needed for `actions/checkout`). |
| `pull-requests: write` | Required to **post comments on the PR** (plan summary). |

**Rule of thumb:** declare *only* the permissions you need. Default permissions are too broad.

---

## 10. The Environment Variables Block

```yaml
env:
  TFVAR_NAME: terraform.tfvars
  BRANCH_NAME: main
  AWS_REGION: ap-south-1
  TERRAFORM_VERSION: 1.11.4
  ROLE_TO_ASSUME: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
  AWS_SESSION_NAME: github-actions-terraform-deployer
  TF_WORKING_DIR: terraform/environments/dev
```

These values are accessible inside any job/step via `${{ env.NAME }}`.

### What each variable is for

| Variable | Purpose |
|---|---|
| `TFVAR_NAME` | The name of the `.tfvars` file Terraform will use for variable values. |
| `BRANCH_NAME` | Which branch's tfvars/workspace to use. Hardcoded to `main` here. |
| `AWS_REGION` | The AWS region all calls go to. |
| `TERRAFORM_VERSION` | Pinned version — guarantees every run uses the same Terraform binary. |
| `ROLE_TO_ASSUME` | The OIDC IAM role ARN. *(Not a secret — safe to keep in plain env or repo Variables.)* |
| `AWS_SESSION_NAME` | Name shown in CloudTrail for credentials issued during this run. |
| `TF_WORKING_DIR` | The directory where Terraform commands run (sub-folder pattern). |

### 🚨 The "never hardcode secrets in env" rule

If you put an API key directly in `env:`, it appears in plaintext in the workflow logs, the YAML file, and any error messages that echo the env. Always use `${{ secrets.SECRET_NAME }}` so GitHub masks the value (`***`) in logs.

**Examples:**

```yaml
# ❌ BAD — leaks the key everywhere
env:
  SOME_API_KEY: abc123-actual-key-value

# ✅ GOOD — masked in logs, retrieved at runtime
env:
  SOME_API_KEY: ${{ secrets.SOME_API_KEY }}
```

---

## 11. Job 1 — `plan` (runs on PR open/sync/reopen)

```yaml
jobs:
  plan:
    if: ${{ github.event_name == 'pull_request' && github.event.pull_request.merged != true && github.event.action != 'closed' }}
    runs-on: ubuntu-latest
    concurrency:
      group: terraform-${{ github.workflow }}-${{ github.ref }}
      cancel-in-progress: false
```

### 11.1 The job-level guards

| Element | Why It's There |
|---|---|
| `if:` filter | Only run this job when the event is a PR, the PR is *not* yet merged, **and** the action isn't `closed` (so abandoned PRs don't trigger plans). |
| `runs-on: ubuntu-latest` | Use a free GitHub-hosted Ubuntu VM. |
| `concurrency.group` | A unique key — only **one** job with this key can run at a time. Prevents two PRs against the same branch from racing. |
| `cancel-in-progress: false` | If a new run starts, **don't** cancel the running one — let it finish. (Safer for plans; you don't want to abort halfway.) |

Now we walk through the steps **in order**, top to bottom.

### 11.2 Step — Checkout the repo

```yaml
- name: Checkout Repository
  uses: actions/checkout@v4
```

Pulls the PR's code onto the runner. Without this, the runner has no Terraform files to plan against.

### 11.3 Step — Assume AWS role via OIDC

```yaml
- name: Configure AWS Credentials (Role Assumption)
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ env.ROLE_TO_ASSUME }}
    role-session-name: ${{ env.AWS_SESSION_NAME }}
    aws-region: ${{ env.AWS_REGION }}
```

What happens behind the scenes:

1. The runner asks GitHub for an OIDC token (because we declared `id-token: write`).
2. The action calls `sts:AssumeRoleWithWebIdentity` against the role ARN.
3. AWS validates the token claims against the role's trust policy.
4. STS hands back a temporary access key, secret key, and session token.
5. The action exports them as env vars so all subsequent `aws`/`terraform` commands work transparently.

### 11.4 Step — Install Terraform

```yaml
- name: Setup Terraform
  uses: hashicorp/setup-terraform@v3
  with:
    terraform_version: ${{ env.TERRAFORM_VERSION }}
```

Downloads and installs the pinned Terraform version on the runner. Pinning the version means the run is reproducible — upgrading is a deliberate change to the workflow file.

### 11.5 Step — Detect branch & set workspace

```yaml
- name: Detect Branch and Set tfvars & Workspace
  id: detect_branch
  run: |
    BRANCH="${{ github.base_ref || github.event.pull_request.base.ref }}"
    if [ "$BRANCH" == "${BRANCH_NAME}" ]; then
      echo "tfvars=${TFVAR_NAME}" >> $GITHUB_OUTPUT
      echo "workspace=${BRANCH_NAME}" >> $GITHUB_OUTPUT
    else
      echo "Branch not recognized! Exiting."
      exit 1
    fi
```

- `github.base_ref` = the branch the PR is **merging into** (here: `main`).
- The script checks "are we targeting `main`?"; if yes, it exports two outputs (`tfvars` and `workspace`) consumable by later steps via `${{ steps.detect_branch.outputs.tfvars }}`.
- If targeting any other branch, the workflow fails fast.

**`$GITHUB_OUTPUT`** is GitHub's official way of passing values between steps. Anything you echo into it becomes a step output.

### 11.6 Step — `terraform fmt -check`

```yaml
- name: Terraform Format Check
  run: terraform fmt -check -recursive
```

Style gate. Fails if any `.tf` file isn't properly formatted. Catches whitespace inconsistencies that would otherwise create noisy diffs.

### 11.7 Step — `terraform init`

```yaml
- name: Terraform Init
  working-directory: ${{ env.TF_WORKING_DIR }}
  run: terraform init -input=false -no-color
```

| Flag | Meaning |
|---|---|
| `-input=false` | Never prompt for input — fail instead. (CI is non-interactive.) |
| `-no-color` | Strip ANSI color codes — cleaner logs. |

`init` downloads providers, configures the backend (S3 with native `use_lockfile` locking), and prepares the working directory.

### 11.8 Step — Workspace select-or-create

```yaml
- name: Select or Create Workspace
  working-directory: ${{ env.TF_WORKING_DIR }}
  run: terraform workspace select "main" || terraform workspace new "main"
```

A **Terraform workspace** is a separate state file under the same backend — typically used to keep `dev`, `staging`, `prod` isolated. The `||` (OR) is the idiomatic "select if exists, otherwise create" pattern.

### 11.9 Step — Validate

```yaml
- name: Terraform Validate
  id: init-validate
  working-directory: ${{ env.TF_WORKING_DIR }}
  run: terraform validate -no-color
```

Checks the configuration for syntax errors and missing required arguments. Pure static analysis — does not touch AWS.

### 11.10 Step — Plan (and save the binary)

```yaml
- name: Terraform Plan
  id: plan
  continue-on-error: true
  working-directory: ${{ env.TF_WORKING_DIR }}
  run: |
    mkdir -p "${{ github.workspace }}/.plan_summaries/"
    terraform plan -input=false -no-color -lock=false \
      -var-file="${{ steps.detect_branch.outputs.tfvars }}" \
      -out=tfplan.binary \
      2>&1 \
      | tee "${{ github.workspace }}/.plan_summaries/plan-output.txt"
```

| Element | Why |
|---|---|
| `continue-on-error: true` | Even if plan fails, **subsequent steps continue** — so the PR comment is still posted. |
| `-lock=false` | Don't acquire the S3 state lock for plan (read-only operation; avoids blocking parallel plans). |
| `-var-file=...` | Apply variables from the chosen tfvars. |
| `-out=tfplan.binary` | **Save the plan as a binary** — so the apply job can later apply *exactly* this reviewed plan, not a re-computed one. |
| `2>&1` | Merge stderr into stdout. |
| `\| tee path` | Print to terminal **and** save to file — the file is what gets posted on the PR. |

### 11.11 Step — Upload plan binary as an artifact

```yaml
- name: Upload Plan Artifact
  if: steps.plan.outcome == 'success'
  uses: actions/upload-artifact@v4
  with:
    name: tfplan-${{ github.event.pull_request.number }}
    path: ${{ env.TF_WORKING_DIR }}/tfplan.binary
    retention-days: 7
```

This is the gold-standard pattern: the **same plan that was reviewed becomes the plan that's applied**. The apply job downloads this artifact and runs `terraform apply tfplan.binary`. No drift, no surprises.

### 11.12 Step — Comment plan on PR

```yaml
- name: Comment Terraform Plan Summary on PR
  if: always()
  uses: actions/github-script@v7
  env:
    PLAN_FILE_PATH: ${{ github.workspace }}/.plan_summaries/plan-output.txt
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    script: |
      const fs = require('fs');
      const path = process.env.PLAN_FILE_PATH;
      let planOutput = 'Plan file not found.';
      if (fs.existsSync(path)) {
        planOutput = fs.readFileSync(path, 'utf8');
        if (planOutput.length > 60000) {
          planOutput = planOutput.slice(0, 60000) + "\n\n...Output truncated...";
        }
      }
      const commentBody = `
      ### 📋 Terraform Plan Summary
      | Step | Status |
      |------|--------|
      | Validate | \`${{ steps.init-validate.outcome }}\` |
      | Plan | \`${{ steps.plan.outcome }}\` |

      <details><summary>Show full plan</summary>

      \`\`\`hcl
      ${planOutput}
      \`\`\`

      </details>

      *Triggered by @${{ github.actor }} via \`${{ github.event_name }}\`*
      `;
      await github.rest.issues.createComment({
        issue_number: context.issue.number,
        owner: context.repo.owner,
        repo: context.repo.repo,
        body: commentBody
      });
```

| Element | Why |
|---|---|
| `if: always()` | Run even if a previous step failed — ensures reviewers see the plan even on failure. |
| `actions/github-script` | Lets you run JavaScript that uses GitHub's API directly. |
| Truncation at 60 000 chars | GitHub's hard limit on a single comment is **65 536 characters**. Truncating early prevents step failure. |

### 11.13 Step — Fail if plan failed

```yaml
- name: Fail if plan failed
  if: steps.plan.outcome == 'failure'
  run: exit 1
```

After the comment is posted, surface the failure so the PR check goes red. Without this, the comment is posted but the workflow looks "successful" because we used `continue-on-error`.

---

## 12. Job 2 — `apply` (runs after merge)

```yaml
apply:
  if: ${{ github.event.pull_request.merged == true && github.event.action == 'closed' }}
  runs-on: ubuntu-latest
  environment: production
  concurrency:
    group: terraform-${{ github.workflow }}-${{ github.ref }}
    cancel-in-progress: false
```

### 12.1 The if-filter

This job runs **only** when:

- The PR has been **merged** (`merged == true`)
- AND the event is a `closed` event (which is what GitHub fires when a merge happens)

Together they mean: *"someone just merged this PR — apply the infrastructure now."*

### 12.2 The `environment: production` line

This is the **human approval gate**. By referencing a GitHub Environment configured with required reviewers, the apply pauses until a human clicks "Approve and deploy" in the Actions tab. For production EKS, this is non-negotiable.

### 12.3 Why the same `concurrency` group as the plan job?

Because if a `plan` is somehow still running when a merge happens, you don't want `apply` to start in parallel. Sharing the group serializes them.

### 12.4 The steps

The first six steps are essentially **identical** to the plan job:

1. Checkout
2. OIDC role assumption
3. Setup Terraform
4. Detect branch
5. `terraform init`
6. Workspace select-or-create

Then the critical difference:

### 12.5 Download the plan artifact

```yaml
- name: Download Plan Artifact
  uses: actions/download-artifact@v4
  with:
    name: tfplan-${{ github.event.pull_request.number }}
    path: ${{ env.TF_WORKING_DIR }}
```

Pulls the exact `tfplan.binary` that was produced and reviewed during the PR's plan job.

### 12.6 The final step — `terraform apply tfplan.binary`

```yaml
- name: Terraform Apply
  working-directory: ${{ env.TF_WORKING_DIR }}
  run: terraform apply -input=false tfplan.binary
```

Notice what's **missing**:

- ❌ No `-auto-approve` — not needed when applying a saved plan binary
- ❌ No `-var-file` — variables are baked into the saved plan
- ❌ No re-computation — Terraform just executes the reviewed diff

This is the gold-standard "approved diff = applied diff" pattern.

### 12.7 Deployment summary

```yaml
- name: Deployment Summary
  if: always()
  run: |
    echo "### 🚀 Terraform Apply Summary" >> $GITHUB_STEP_SUMMARY
    echo "- Branch: \`${{ github.ref_name }}\`" >> $GITHUB_STEP_SUMMARY
    echo "- Commit: \`${{ github.sha }}\`" >> $GITHUB_STEP_SUMMARY
    echo "- Status: \`${{ job.status }}\`" >> $GITHUB_STEP_SUMMARY
```

`$GITHUB_STEP_SUMMARY` is a special file — anything you write to it shows up as a styled summary at the top of the workflow run page.

---

## 13. End-to-End Flow Diagram

```text
┌─────────────────────────────────────────────────────────────┐
│  Developer pushes to feature branch & opens PR → main       │
└────────────────────────────┬────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  GitHub Actions fires: pull_request (opened/synchronize)    │
│                                                             │
│  Job: PLAN  (if: merged != true && action != closed)        │
│  ───────────────────────────────                            │
│  1.  Checkout                                               │
│  2.  Assume AWS role via OIDC                               │
│  3.  Install pinned Terraform version                       │
│  4.  Detect branch → tfvars + workspace                     │
│  5.  terraform fmt -check                                   │
│  6.  terraform init                                         │
│  7.  terraform workspace select/new                         │
│  8.  terraform validate                                     │
│  9.  terraform plan -out=tfplan.binary                      │
│  10. Upload tfplan.binary as workflow artifact              │
│  11. Post plan summary as PR comment                        │
│  12. Fail step if plan failed (after comment is posted)     │
└────────────────────────────┬────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  Reviewer reads:                                            │
│   • Plan summary comment                                    │
│   • Diff in PR                                              │
│  → Approves PR                                              │
└────────────────────────────┬────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  PR is merged into main                                     │
│  GitHub Actions fires: pull_request (closed, merged=true)   │
│                                                             │
│  Job: APPLY  (if: merged == true && action == closed)       │
│  Environment: production  (waits for human approval)        │
│  ───────────────────────────────                            │
│  1. Checkout                                                │
│  2. Assume AWS role via OIDC                                │
│  3. Install pinned Terraform version                        │
│  4. Detect branch → tfvars + workspace                      │
│  5. terraform init                                          │
│  6. terraform workspace select/new                          │
│  7. Download tfplan.binary artifact                         │
│  8. terraform apply tfplan.binary  ← infrastructure live    │
│  9. Write deployment summary                                │
└─────────────────────────────────────────────────────────────┘
```

---

# Part 3 — Production Engineering

## 14. Wiring in OIDC Authentication

> 📚 If you haven't yet, read [`github-oidc-aws-setup.md`](./github-oidc-aws-setup.md) first — it explains the trust model end-to-end.

The connection point inside a workflow is just one step:

```yaml
- name: Configure AWS Credentials via OIDC
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ env.ROLE_TO_ASSUME }}
    role-session-name: ${{ env.AWS_SESSION_NAME }}
    aws-region: ${{ env.AWS_REGION }}
```

For this to succeed, three things must be in place:

1. **Workflow has `id-token: write` permission** (declared at workflow or job level).
2. **The IAM Role's trust policy** allows the `sub` claim from this repo + branch/environment.
3. **The Role ARN** is correctly set in the workflow `env:` block.

If any one of these is missing, you'll see `Not authorized to perform sts:AssumeRoleWithWebIdentity`.

---

## 15. Environment Variables & Secrets — Four Mechanisms

There are **four** different ways to provide values to a workflow. Knowing which to use is half the battle.

| Mechanism | Where Defined | Visible in Logs? | Use For |
|---|---|---|---|
| **Workflow `env:`** | Inside the YAML | ✅ Yes (plaintext) | Non-sensitive config: region, role ARN, TF version |
| **Repository Variables** | Settings → Secrets and variables → Variables | ✅ Yes | Shared non-sensitive values across workflows |
| **Repository Secrets** | Settings → Secrets and variables → Secrets | 🚫 Masked in logs | API tokens, webhook URLs (NOT AWS keys — use OIDC) |
| **Environment Secrets** | Settings → Environments → \<env\> → Secrets | 🚫 Masked in logs | Per-env values (prod webhook ≠ dev webhook) |

### Recommended layout for this project

```yaml
env:
  AWS_REGION: ap-south-1
  TF_VERSION: "1.11.4"
  ROLE_TO_ASSUME: ${{ vars.AWS_DEPLOY_ROLE_ARN }}     # repo Variable
  AWS_SESSION_NAME: github-actions-terraform-deployer
  TF_WORKING_DIR: terraform/environments/dev
```

> ⚠️ **Public repo reminder:** Never `echo` env vars in scripts that run on PRs from forks. Even non-secret values (Role ARN) should not be exposed in screenshots if you can help it — though they're not security-critical thanks to the trust policy.

---

## 16. Branch Protection & Approval Gates

The pipeline is only as safe as the rules around the `main` branch. In **Settings → Branches → Add rule**, configure for `main`:

- ✅ Require a pull request before merging
- ✅ Require approvals: **at least 1** (2 for production-critical repos)
- ✅ Dismiss stale approvals when new commits are pushed
- ✅ Require status checks to pass before merging:
  - `Terraform Plan / plan`
  - (any security scans you add — Checkov, tfsec, Trivy)
- ✅ Require branches to be up to date before merging
- ✅ Require conversation resolution before merging
- ✅ Do not allow bypassing the above settings (even for admins)
- ✅ Restrict who can push to matching branches

For production deployments, layer **GitHub Environments** on top:

- Create an environment named `production`
- Require **specific reviewers** (you, or your team)
- Optionally add a **wait timer** before deployments can proceed
- Restrict deployments to the `main` branch

The apply job then references this environment:

```yaml
jobs:
  apply:
    environment: production
    ...
```

---

## 17. Best-Practice Deployment Workflow Files

Two complete, production-ready files. Drop these under `.github/workflows/`. They incorporate every best practice covered above:

- ✅ OIDC (no static keys)
- ✅ Pinned action versions (`@v4`)
- ✅ Pinned Terraform version
- ✅ Least-privilege permissions
- ✅ Concurrency protection
- ✅ Plan binary persisted as artifact and applied verbatim
- ✅ Format / validate / plan gates
- ✅ PR comment with truncation
- ✅ Environment approval gate on apply
- ✅ Job timeouts
- ✅ Fork-PR safety

### 17.1 `.github/workflows/terraform-plan.yml`

```yaml
name: Terraform Plan

on:
  pull_request:
    branches: [main]
    paths:
      - "terraform/**"
      - ".github/workflows/terraform-*.yml"

permissions:
  id-token: write       # OIDC token minting
  contents: read        # Checkout
  pull-requests: write  # Post plan as PR comment

env:
  AWS_REGION: ap-south-1
  TF_VERSION: "1.11.4"
  ROLE_TO_ASSUME: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
  AWS_SESSION_NAME: gha-${{ github.run_id }}-plan
  TF_WORKING_DIR: terraform/environments/dev

concurrency:
  group: terraform-${{ github.ref }}
  cancel-in-progress: true

jobs:
  plan:
    name: Plan
    # Fork-PR safety: only run on PRs from the same repo
    if: github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    timeout-minutes: 30
    defaults:
      run:
        working-directory: ${{ env.TF_WORKING_DIR }}

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS Credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ env.ROLE_TO_ASSUME }}
          role-session-name: ${{ env.AWS_SESSION_NAME }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Terraform Format Check
        run: terraform fmt -check -recursive
        working-directory: .

      - name: Terraform Init
        run: terraform init -input=false -no-color

      - name: Terraform Validate
        id: validate
        run: terraform validate -no-color

      - name: Terraform Plan
        id: plan
        continue-on-error: true
        run: |
          terraform plan -input=false -no-color \
            -out=tfplan.binary \
            2>&1 | tee plan-output.txt

      - name: Upload Plan Artifact
        if: steps.plan.outcome == 'success'
        uses: actions/upload-artifact@v4
        with:
          name: tfplan-${{ github.event.pull_request.number }}
          path: ${{ env.TF_WORKING_DIR }}/tfplan.binary
          retention-days: 7

      - name: Comment Plan on PR
        if: always()
        uses: actions/github-script@v7
        env:
          PLAN_FILE: ${{ env.TF_WORKING_DIR }}/plan-output.txt
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const fs = require('fs');
            let plan = 'Plan file not found.';
            if (fs.existsSync(process.env.PLAN_FILE)) {
              plan = fs.readFileSync(process.env.PLAN_FILE, 'utf8');
              if (plan.length > 60000) {
                plan = plan.slice(0, 60000) + "\n\n...output truncated...";
              }
            }
            const body = `### 📋 Terraform Plan Summary

            | Step | Status |
            |------|--------|
            | Validate | \`${{ steps.validate.outcome }}\` |
            | Plan | \`${{ steps.plan.outcome }}\` |

            <details><summary>Show full plan</summary>

            \`\`\`hcl
            ${plan}
            \`\`\`

            </details>

            *Triggered by @${{ github.actor }}*`;
            await github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body
            });

      - name: Fail if Plan Failed
        if: steps.plan.outcome == 'failure'
        run: exit 1
```

### 17.2 `.github/workflows/terraform-apply.yml`

```yaml
name: Terraform Apply

on:
  push:
    branches: [main]
    paths:
      - "terraform/**"
      - ".github/workflows/terraform-*.yml"
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: ap-south-1
  TF_VERSION: "1.11.4"
  ROLE_TO_ASSUME: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
  AWS_SESSION_NAME: gha-${{ github.run_id }}-apply
  TF_WORKING_DIR: terraform/environments/dev

# Serialize applies — never two at once.
concurrency:
  group: terraform-${{ github.ref }}
  cancel-in-progress: false

jobs:
  apply:
    name: Apply
    runs-on: ubuntu-latest
    environment: production    # 🔒 reviewer approval gate
    timeout-minutes: 60
    defaults:
      run:
        working-directory: ${{ env.TF_WORKING_DIR }}

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS Credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ env.ROLE_TO_ASSUME }}
          role-session-name: ${{ env.AWS_SESSION_NAME }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Terraform Init
        run: terraform init -input=false -no-color

      - name: Find Latest Plan Artifact
        id: find-plan
        uses: actions/github-script@v7
        with:
          script: |
            const { data } = await github.rest.actions.listArtifactsForRepo({
              owner: context.repo.owner,
              repo: context.repo.repo,
              per_page: 100,
            });
            const planArtifact = data.artifacts.find(a =>
              a.name.startsWith('tfplan-') && !a.expired
            );
            if (!planArtifact) {
              core.setFailed('No matching plan artifact found.');
              return;
            }
            core.setOutput('artifact_id', planArtifact.id);
            core.setOutput('artifact_name', planArtifact.name);

      - name: Download Plan Artifact
        uses: actions/download-artifact@v4
        with:
          name: ${{ steps.find-plan.outputs.artifact_name }}
          path: ${{ env.TF_WORKING_DIR }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
          run-id: ${{ github.run_id }}

      - name: Terraform Apply
        run: terraform apply -input=false tfplan.binary

      - name: Deployment Summary
        if: always()
        run: |
          echo "### 🚀 Terraform Apply Summary" >> $GITHUB_STEP_SUMMARY
          echo "- Branch: \`${{ github.ref_name }}\`" >> $GITHUB_STEP_SUMMARY
          echo "- Commit: \`${{ github.sha }}\`" >> $GITHUB_STEP_SUMMARY
          echo "- Actor: @${{ github.actor }}" >> $GITHUB_STEP_SUMMARY
          echo "- Status: \`${{ job.status }}\`" >> $GITHUB_STEP_SUMMARY
```

> 💡 The plan-artifact lookup in the apply workflow is intentionally simple. In a higher-volume repo, scope the search by PR number or commit SHA so you never apply the wrong plan. Pair this with branch protection that requires the apply only after a recent PR plan run.

---

## 18. State Lock Recovery Workflow

When a Terraform run is killed mid-apply (network drop, runner termination, cancelled job), the S3 `.tflock` object can be left behind, blocking all future runs with:

```text
Error: Error acquiring the state lock
Lock Info:
  ID: 1234abcd-...
```

A small **manually-triggered workflow** lets authorized users break the lock without giving them shell access.

### `.github/workflows/tf-statelock-unlock.yml`

```yaml
name: Terraform Force-Unlock

on:
  workflow_dispatch:
    inputs:
      lock_id:
        description: "Lock ID to force-unlock (from the error message)"
        required: true
        type: string
      working_dir:
        description: "Terraform working directory"
        required: true
        default: "terraform/environments/dev"
        type: string

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: ap-south-1
  ROLE_TO_ASSUME: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
  AWS_SESSION_NAME: gha-${{ github.run_id }}-unlock

jobs:
  unlock:
    name: Force Unlock
    runs-on: ubuntu-latest
    environment: production   # require human approval
    timeout-minutes: 10

    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ env.ROLE_TO_ASSUME }}
          role-session-name: ${{ env.AWS_SESSION_NAME }}
          aws-region: ${{ env.AWS_REGION }}

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.11.4"

      - run: terraform init -input=false
        working-directory: ${{ inputs.working_dir }}

      - run: terraform force-unlock -force ${{ inputs.lock_id }}
        working-directory: ${{ inputs.working_dir }}
```

> ⚠️ **Use with care.** Only force-unlock when you are *certain* no other apply is in progress. Force-unlocking a live apply causes state corruption.

---

## 19. Common Gotchas & Why Each Safety Net Exists

| # | Gotcha | What It Prevents |
|---|---|---|
| 1 | **OIDC instead of static keys** | If a static `AWS_ACCESS_KEY_ID` leaks (logs, screenshot, fork PR), it's valid until manually rotated. OIDC tokens expire in 1 hour. |
| 2 | **`concurrency.group`** | Two PRs racing to apply at the same time → corrupted state. The group serializes them. |
| 3 | **`continue-on-error: true` on `terraform plan`** | Without it, a plan failure would skip the comment step — reviewers wouldn't see the error. |
| 4 | **`-lock=false` on plan** | Plan is read-only; locking would block parallel plans on different PRs unnecessarily. |
| 5 | **65 000-char truncation** | GitHub rejects comments > 65 536 chars; truncation prevents step failure. |
| 6 | **`if: always()` on PR-comment steps** | Even on failure, reviewers see *something* on the PR — not silence. |
| 7 | **Apply uses saved plan binary** | Without this, the diff applied could differ from the diff reviewed. Persisting the binary closes that gap. |
| 8 | **`-input=false` everywhere** | Fail fast in non-interactive mode rather than hang waiting for input. |
| 9 | **Pinned Terraform version** | Without pinning, two runs days apart could use different binaries → different behavior. |
| 10 | **Workspace select-or-create idempotency** | If the workspace doesn't exist yet, `select` fails. The `\|\|` fallback creates it. |
| 11 | **Pinned action versions** | Unpinned actions can be hijacked or change behavior overnight. |
| 12 | **Fork-PR `if:` filter** | PRs from forks should not be able to assume your AWS role. Filtering is a defense-in-depth layer on top of trust-policy scoping. |
| 13 | **`environment:` on apply** | Adds a human approval click before destructive changes. |
| 14 | **`timeout-minutes`** | Prevents a hung step from burning 6 hours of CI time. |

---

## 20. Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy `sub` doesn't match | Update `SubjectClaimFilters` in the OIDC role to include this branch/env |
| `Error acquiring the state lock` | Previous run died mid-apply | Use the force-unlock workflow above |
| Plan posted to PR is empty | `terraform plan` failed silently | Check the step's exit code; ensure stderr is captured (`2>&1`) |
| Workflow doesn't trigger on PR | Path filter excludes the changed files | Adjust `paths:` in the `on:` block |
| Two applies ran in parallel | Missing `concurrency:` block | Add `concurrency: { group: terraform-apply, cancel-in-progress: false }` |
| Plan shows changes apply doesn't | State drift between branches; concurrent applies; missing `-out=tfplan` artifact | Always pass the saved plan: `apply tfplan.binary` |
| `Token retrieval error: missing id-token permission` | Workflow missing `id-token: write` | Add it to `permissions:` |
| Forks can run my workflow | Default `pull_request` trigger fires from forks | Add `if: github.event.pull_request.head.repo.full_name == github.repository` |

---

## 21. Glossary — Plain English Definitions

| Term | Meaning |
|---|---|
| **Workflow** | A single YAML file that describes one automated process. |
| **Job** | A bag of steps that run together on one VM. |
| **Step** | One command or one pre-built action invocation. |
| **Runner** | The VM that runs the job. |
| **Action** | A reusable, named building block (e.g., `actions/checkout`). |
| **Event** | What triggers the workflow (push, PR, manual). |
| **OIDC** | OpenID Connect — protocol that lets GitHub prove identity to AWS without static keys. |
| **STS** | AWS Security Token Service — issues temporary credentials. |
| **JWT** | JSON Web Token — the signed identity token GitHub mints. |
| **Subject claim (`sub`)** | A field in the JWT identifying the source repo/branch/env. |
| **Trust policy** | The IAM Role document that says "I trust tokens with these claims." |
| **State file** | The JSON Terraform writes describing what infrastructure currently exists. |
| **State lock** | A `.tflock` object in S3 (with `use_lockfile = true`) that prevents concurrent applies. |
| **Workspace** | A named, isolated state file under the same backend. |
| **Plan** | Read-only "what would change" computation. |
| **Plan binary (`tfplan`)** | The serialized output of `terraform plan -out=...`, applied verbatim later. |
| **Apply** | Actually executes the changes in AWS. |
| **Concurrency group** | Lock that ensures only one workflow run per group at a time. |
| **`GITHUB_TOKEN`** | Auto-generated short-lived token scoped to the workflow run. |
| **Step output** | A value one step exports for later steps to consume. |
| **`$GITHUB_OUTPUT`** | The file-based mechanism for setting step outputs. |
| **`$GITHUB_STEP_SUMMARY`** | Markdown file rendered as a summary at the top of the workflow run page. |
| **GitHub Environment** | Named deployment target with optional reviewer approval and per-env secrets. |
| **Branch Protection** | Repo-level rules that gate merges into protected branches. |

---

## 22. Quick-Reference Cheat Sheet

```yaml
# ── Trigger only on PRs targeting main ───────────────────────
on:
  pull_request:
    types: [opened, synchronize, reopened, closed]
    branches: [main]

# ── Permissions (least privilege) ────────────────────────────
permissions:
  id-token: write       # OIDC
  contents: read        # checkout
  pull-requests: write  # PR comments

# ── Pin everything ───────────────────────────────────────────
env:
  TERRAFORM_VERSION: 1.11.4

# ── Serialize applies on the same branch ─────────────────────
concurrency:
  group: terraform-${{ github.ref }}
  cancel-in-progress: false

# ── Plan job filter ──────────────────────────────────────────
if: github.event.pull_request.merged != true && github.event.action != 'closed'

# ── Apply job filter ─────────────────────────────────────────
if: github.event.pull_request.merged == true && github.event.action == 'closed'

# ── Fork-PR safety ───────────────────────────────────────────
if: github.event.pull_request.head.repo.full_name == github.repository

# ── Always post comments, even on failure ────────────────────
if: always()

# ── Plan that can fail without aborting later steps ─────────
continue-on-error: true

# ── Save step output ─────────────────────────────────────────
echo "key=value" >> $GITHUB_OUTPUT

# ── Read step output ─────────────────────────────────────────
${{ steps.STEP_ID.outputs.KEY }}

# ── Use a secret (NEVER hardcode) ────────────────────────────
${{ secrets.MY_SECRET }}

# ── Use a non-sensitive variable ─────────────────────────────
${{ vars.MY_VAR }}

# ── Workflow run summary ─────────────────────────────────────
echo "### Status" >> $GITHUB_STEP_SUMMARY
```

---

## 23. References

- GitHub Docs — [Workflow syntax](https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions)
- GitHub Docs — [Events that trigger workflows](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows)
- GitHub Docs — [Using environments for deployment](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
- HashiCorp — [`setup-terraform` action](https://github.com/hashicorp/setup-terraform)
- AWS — [`aws-actions/configure-aws-credentials`](https://github.com/aws-actions/configure-aws-credentials)
- Internal — [`github-oidc-aws-setup.md`](./github-oidc-aws-setup.md)
- Internal — [`oidc-github-role.yml`](./oidc-github-role.yml)

---

<div align="center">

**🎓 You now understand every line of a production-grade Terraform CI/CD workflow.**

**🛡️ Plan-on-PR. Apply-on-Merge. OIDC. Approval-gated. Auditable end-to-end.**

[⬆ Back to Top](#-terraform-cicd-with-github-actions--from-basics-to-production-grade)

</div>
