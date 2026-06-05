# 🏛️ CI/CD Workflow Design — Architecture & Rationale

> **Purpose of this document.** This is the design memo for the GitHub Actions pipelines under [`.github/workflows/`](../.github/workflows/). It is written to serve two readers at once:
>
> 1. **A new engineer** joining the project who needs to understand how the pipeline works and why every line is there.
> 2. **A senior reviewer** evaluating the design who wants to gauge depth of thinking — not just *what* was built, but *why this and not that*.
>
> If you can read this end-to-end and explain any section back, you have senior-level fluency on Terraform CI/CD.

---

## 📑 Table of Contents

### Part 1 — The "Why"

1. [Executive Summary](#1-executive-summary)
2. [Design Goals](#2-design-goals)
3. [Why Four Files Instead of One](#3-why-four-files-instead-of-one)
4. [Security Model](#4-security-model)
5. [Trade-offs Considered & Decisions Made](#5-trade-offs-considered--decisions-made)

### Part 2 — The "What"

6. [Workflow Topology](#6-workflow-topology)
7. [File 1 — `terraform-validate.yml`](#7-file-1--terraform-validateyml)
8. [File 2 — `terraform-plan.yml`](#8-file-2--terraform-planyml)
9. [File 3 — `terraform-apply.yml`](#9-file-3--terraform-applyyml)
10. [File 4 — `tf-statelock-unlock.yml`](#10-file-4--tf-statelock-unlockyml)
11. [The TFLint Configuration](#11-the-tflint-configuration)

### Part 3 — The "How"

12. [End-to-End Lifecycle of a Change](#12-end-to-end-lifecycle-of-a-change)
13. [Failure Modes & Recovery](#13-failure-modes--recovery)
14. [Required GitHub Configuration](#14-required-github-configuration)
15. [Required AWS Configuration](#15-required-aws-configuration)

### Part 4 — Defending This Design

16. [Design Defense — Likely Questions With Strong Answers](#16-design-defense--likely-questions-with-strong-answers)
17. [Future Enhancements](#17-future-enhancements)
18. [References](#18-references)

---

# Part 1 — The "Why"

## 1. Executive Summary

The pipeline implements a **four-workflow pattern** that separates concerns by *responsibility* rather than by environment:

| File | Trigger | Responsibility | AWS Role |
|---|---|---|---|
| `terraform-validate.yml` | PR → `main`/`develop` | Style, syntax, lint, security scan | None — runs without AWS access |
| `terraform-plan.yml` | PR → `develop`; manual dispatch | Compute diff, post to PR, persist plan binary | OIDC, environment-scoped read-only |
| `terraform-apply.yml` | Push to `develop`/`main`; manual dispatch | Apply reviewed plan binary | OIDC, environment-scoped read-write |
| `tf-statelock-unlock.yml` | Manual dispatch only | Break stuck S3 `.tflock` object (or `terraform force-unlock`) | OIDC, narrow IAM, requires production-tier reviewer |

**Authentication:** GitHub OIDC federation — no long-lived AWS keys exist anywhere in GitHub.
**Approval gates:** GitHub Environments (`dev`, `production`) with required reviewers on production.
**Plan integrity:** the binary plan from the PR is uploaded as a workflow artifact and applied verbatim on merge — guaranteeing the diff applied is the diff reviewed.

This is the pattern used by mid-to-large enterprises running Terraform on GitHub Actions in regulated environments.

---

## 2. Design Goals

The pipeline was designed against eight measurable goals:

| # | Goal | How It's Achieved |
|---|---|---|
| 1 | **Zero static AWS credentials** | OIDC + STS — credentials are 1-hour temporary tokens minted per run |
| 2 | **Every change reviewed before it touches AWS** | Plan-on-PR + branch protection requiring approving review |
| 3 | **What's reviewed is what's applied** | Plan binary saved as artifact, applied verbatim on merge |
| 4 | **Concurrent applies cannot corrupt state** | `concurrency:` group + native S3 state locking (`use_lockfile = true`, Terraform 1.10+) |
| 5 | **Failures fail loudly and locally** | `if: always()` on PR comment, `Fail if Plan Failed` step, step summary |
| 6 | **Production requires explicit human approval** | GitHub Environment with required reviewers |
| 7 | **Pipeline is auditable end-to-end** | Unique `role-session-name` per run → CloudTrail traceability |
| 8 | **Operational tooling is gated** | Force-unlock requires production-tier reviewer regardless of which env it touches |

These are not aspirational — every goal maps to specific lines of YAML you can point at.

---

## 3. Why Four Files Instead of One

This is the most-asked architecture question on this design. Defense in five points.

### 3.1 Different stages need different IAM roles

Plan reads from AWS. Apply writes to AWS. In a one-file workflow they share the same role, which means **the role used to evaluate untrusted PR code has write permissions to production**. Splitting plan and apply into separate jobs (or, more cleanly, separate files) lets each job assume a role with **only the permissions it needs**:

- Plan role → `Describe*`, `List*`, `Get*`, plus `s3:GetObject`/`PutObject`/`DeleteObject` on the state bucket so the native S3 lockfile can be written and released.
- Apply role → those plus `Create*`, `Update*`, `Delete*` on the resources Terraform manages.

This is **the layered-defense pattern SOC 2 / ISO 27001 / PCI auditors look for**.

### 3.2 Branch protection becomes meaningful

GitHub branch protection requires you to specify *which status checks* must pass before merge. With four files you can require:

- ✅ `Validate (dev)`, `Validate (production)` — code is well-formed in both environments
- ✅ `Plan (dev)` — the diff is computable

In a single-file workflow the apply job runs only after merge, so it's not a meaningful pre-merge check. The split forces every workflow to be either "before merge" or "after merge" — never both. That clarity is what makes governance work.

### 3.3 Operational tooling needs separate gates

`force-unlock`, `destroy`, and (eventually) `drift-detection` have *different* trigger semantics from daily plan/apply:

- **Force-unlock**: manual only, requires senior approval, single-purpose
- **Destroy**: manual only, double approval, requires typing `DESTROY` to confirm
- **Drift detection**: scheduled cron, no approval needed (read-only)

Stuffing these into the apply file produces a 600-line YAML with `if:` switches everywhere. Separating them produces four short files where each is obvious at a glance.

### 3.4 Validation should run *without* AWS access

The validate file installs Terraform, runs `fmt`, `init -backend=false`, `validate`, TFLint, and Checkov — none of which need AWS. Putting validation in the same file as plan means PRs from forks (which can't get OIDC tokens) fail at AWS auth before they even reach validation. That's a bad developer experience and undermines the whole point of having validation gates. Separating them lets validation run on **every PR including forks**, while plan/apply stay locked to internal contributors.

### 3.5 Readability and onboarding

A new engineer can read **one file** and understand one phase of the pipeline. Four 100-line files with clear names is dramatically more approachable than one 400-line file with `if: github.event.pull_request.merged != true && ...` filters scattered through it.

> 🗣️ **One-sentence summary:** *Four files because plan and apply need different IAM roles, branch protection needs distinct status checks, operational workflows need separate approval gates, and validation should run on every PR including forks — none of which are achievable cleanly in a single file.*

---

## 4. Security Model

The pipeline's security posture rests on **five concentric layers**. An attacker has to defeat all five to cause damage.

```text
┌───────────────────────────────────────────────────────────────┐
│ Layer 5: AWS service-level controls                           │
│  • S3 versioning, MFA Delete, AWS Backup vault                │
│  • CloudTrail audit logging                                   │
│  • Resource-level encryption (KMS)                            │
├───────────────────────────────────────────────────────────────┤
│ Layer 4: IAM least privilege                                  │
│  • Different role per environment (dev/prod)                  │
│  • Trust policy pinned to repo + GitHub Environment           │
│  • Permissions boundary on roles                              │
├───────────────────────────────────────────────────────────────┤
│ Layer 3: GitHub Environment approval                          │
│  • Required reviewers on production (1-2)                     │
│  • Deployment branch restrictions                             │
│  • Self-review prevention                                     │
├───────────────────────────────────────────────────────────────┤
│ Layer 2: Branch protection                                    │
│  • Required PR with approval                                  │
│  • Required status checks (validate, plan)                    │
│  • No direct push, no force push                              │
├───────────────────────────────────────────────────────────────┤
│ Layer 1: Workflow-level guards                                │
│  • Fork-PR filter on plan/apply                               │
│  • OIDC `id-token: write` only on jobs that need it           │
│  • `permissions:` block declares minimum scope                │
│  • Concurrency groups prevent race conditions                 │
└───────────────────────────────────────────────────────────────┘
```

### 4.1 What an attacker would need to do to deploy malicious code

1. Bypass branch protection (impossible — admins explicitly excluded)
2. Or, get an approving review on a malicious PR (requires social engineering a maintainer)
3. Or, compromise a maintainer's GitHub account
4. Even then, production apply pauses for a *separate* environment-level reviewer
5. Even then, the IAM trust policy restricts the role to specific repository + environment claims
6. Even then, the IAM permissions are scoped to specific resources

Each layer multiplies the attacker's effort. This is what **"defense in depth"** means in practice.

### 4.2 Why OIDC, not access keys

| Concern | Static `AWS_ACCESS_KEY_ID` | OIDC |
|---|---|---|
| If leaked, valid for | Until manually rotated (months) | 1 hour |
| Stored in | GitHub Secrets (plaintext on disk somewhere) | Nowhere — minted per run |
| Audit trail | Generic IAM user | Per-run session name with run ID |
| Scoping | Same key for all repos, all branches | Trust policy pinned to repo + environment |
| Rotation overhead | Manual every 90 days | None |
| Compatible with public repos | Risky | Safe |

OIDC is not an optimization — it is **the standard**. Static keys for CI/CD are a finding in any modern security audit.

---

## 5. Trade-offs Considered & Decisions Made

This section is the differentiator between someone who copied a tutorial and someone who designed a system. Each decision below was a real fork in the road.

### 5.1 GitHub Actions vs. dedicated IaC platform

**Considered:** Spacelift, Atlantis, Terraform Cloud, env0
**Chose:** GitHub Actions
**Why:** No additional vendor cost, no separate UI to learn, integrates natively with the source-of-truth (PRs). GH Actions covers ~85% of what dedicated platforms offer for the price of zero extra tooling.
**Trade-off accepted:** No native drift detection UI, no built-in policy-as-code (compensated by Checkov). Migration to a dedicated platform is straightforward later because the workflows already encode the right patterns.

### 5.2 Single-file vs. multi-file workflow

**Chose:** Multi-file (validate / plan / apply / unlock)
**Why:** See [Section 3](#3-why-four-files-instead-of-one).

### 5.3 One workflow per environment vs. environment routing within one workflow

**Considered:** `terraform-apply-dev.yml`, `terraform-apply-prod.yml` — two separate apply files.
**Chose:** One `terraform-apply.yml` with branch-based routing (`develop` → dev, `main` → production) and a `workflow_dispatch` input for manual targeting.
**Why:** DRY — applying to a different environment is a configuration concern, not a logic concern. The `environment:` directive plus per-env `vars` handle the differences. Adds complexity to the routing job (`determine-env`) but saves duplication.
**Trade-off accepted:** Marginally harder to read for someone who's never seen the pattern; a 5-line `determine-env` job documents the routing.

### 5.4 Plan binary saved as artifact vs. re-plan at apply

**Chose:** Plan binary saved as artifact, applied verbatim.
**Why:** Closes the "drift between review and apply" gap. If state changes between PR-plan and merge-apply (e.g., a different stack applied something concurrently), a fresh plan would silently include those changes. Applying the saved binary makes the apply transactional with the review.
**Trade-off accepted:** Plan binary contains *literal values* that will be applied — including any `data` source values resolved at plan time. If a secret rotates between plan and apply, the apply uses the stale secret. Mitigation: secrets are fetched via `aws_secretsmanager_secret_version` data sources at apply time *outside* the plan binary, or with `apply_immediately = false` patterns. For this project, the plan-binary trade-off is the right one because reviewability outweighs same-day-secret-rotation drift.

### 5.5 Workspaces vs. separate state files per environment

**Considered:** `terraform workspace` for env separation.
**Chose:** Separate state files per environment (`environments/<env>/terraform.tfstate`).
**Why:** Workspaces share *one* backend configuration but isolate state inside it. They're a thin abstraction. Separate folders give true blast-radius isolation: a typo in `dev` cannot accidentally touch `production` because they don't share the same Terraform configuration. Workspaces also make `terraform.workspace` interpolations a hidden global, which is a maintenance smell.
**Trade-off accepted:** Slightly more boilerplate per environment (each has its own `backend.hcl`, `versions.tf`, etc.).

### 5.6 `concurrency.cancel-in-progress: false` on apply

**Considered:** `cancel-in-progress: true` for faster feedback.
**Chose:** `false` for apply, `true` for validate/plan.
**Why:** Cancelling an apply mid-run leaves resources half-created and the state lock stuck. Better to queue the second run and let the first finish cleanly. Validate/plan are read-only and replaceable — cancelling them is fine.

### 5.7 `cancel-in-progress: true` on plan

**Why:** When a developer pushes a fix to a PR, the previous plan run is now obsolete. Cancelling saves CI minutes and prevents the old plan from posting *after* the new one (which would confuse reviewers).

### 5.8 Pinned action versions vs. floating

**Chose:** Pinned to major (`@v4`) for daily ops, with a roadmap to pin to SHA.
**Why:** Major-pinning balances supply-chain safety with maintenance burden. SHA pinning is the gold standard for high-security environments — added to [Future Enhancements](#17-future-enhancements).

---

# Part 2 — The "What"

## 6. Workflow Topology

```text
┌─────────────────────────────────────────────────────────────────┐
│                      Developer pushes to                        │
│                       feature/fix branch                        │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                          Opens PR                               │
└──┬──────────────────────────────┬───────────────────────────────┘
   │                              │
   ▼                              ▼
┌──────────────────────┐   ┌──────────────────────────────────────┐
│ terraform-validate   │   │      terraform-plan                  │
│ • fmt -check         │   │  • OIDC → AWS                        │
│ • init -backend=false│   │  • init                              │
│ • validate           │   │  • plan -out=tfplan.binary           │
│ • TFLint             │   │  • Upload artifact                   │
│ • Checkov            │   │  • Comment on PR                     │
│   (matrix: 3 envs)   │   │                                      │
└──────────┬───────────┘   └──────────────┬───────────────────────┘
           │                              │
           └──────────────┬───────────────┘
                          ▼
              ┌──────────────────────────┐
              │  Required status checks  │
              │  Required PR review      │
              └─────────────┬────────────┘
                            │
                Merge to develop
                            │
                            ▼
            ┌────────────────────────────────────┐
            │       terraform-apply              │
            │  Environment: dev (no gate)        │
            │  Downloads plan artifact           │
            │  apply tfplan.binary               │
            └─────────────────┬──────────────────┘
                              │
              Promotion PR develop → main
                              │
                              ▼
                  Merge to main
                              │
                              ▼
            ┌────────────────────────────────────┐
            │       terraform-apply              │
            │  Environment: production (GATED)   │
            │  Reviewer must approve in UI       │
            │  Downloads plan artifact           │
            │  apply tfplan.binary               │
            └────────────────────────────────────┘

────────────────────── parallel ops tooling ────────────────────────

       ┌──────────────────────────────┐
       │   tf-statelock-unlock        │
       │   Manual dispatch only       │
       │   Always uses production env │
       │   Audit-logged in summary    │
       └──────────────────────────────┘
```

---

## 7. File 1 — `terraform-validate.yml`

> **Purpose:** First line of defense. Runs on every PR. Catches style, syntax, lint, and security issues before a reviewer wastes a minute.

### 7.1 Why a matrix across environments

```yaml
strategy:
  fail-fast: false
  matrix:
    env: [dev, production]
```

- Each environment is a separate Terraform configuration with its own `tfvars`. Validating only `dev` lets `production`-only typos slip through.
- `fail-fast: false` runs all three in parallel even if one fails, so the developer sees *all* problems in one cycle.

### 7.2 Why `init -backend=false`

```yaml
- run: terraform init -backend=false
```

Validation does not need real backend state. Skipping the backend means:
- No AWS credentials needed for this workflow (huge — fork PRs can run validation).
- Faster (no S3 round-trip).
- Decouples validate failures from AWS outages.

### 7.3 Why fork PRs are *not* filtered out

Other workflows in the pipeline filter forks via `if: github.event.pull_request.head.repo.full_name == github.repository`. This one **deliberately does not** — fork contributors should be able to see their formatting and lint errors. Since validation has no AWS access, there's nothing for a malicious fork to exfiltrate.

### 7.4 Why TFLint runs from the repo root, not the env folder

```yaml
- run: tflint --recursive --format compact
  working-directory: .
```

`--recursive` walks every `.tf` file in the repo in one pass. Per-env recursion would be redundant since modules are shared.

### 7.5 Why Checkov has `soft_fail: true`

```yaml
- uses: bridgecrewio/checkov-action@v12
  with:
    soft_fail: true
```

Checkov findings are surfaced in the workflow log but do not block the PR. Rationale:
- During initial development, hard-failing on every Checkov rule blocks all progress.
- Once the codebase is clean, switch to `soft_fail: false` to make findings blocking.
- This is the standard "ramp-up then enforce" pattern.

### 7.6 The summary step

```yaml
- name: Validate Summary
  if: always()
  run: |
    {
      echo "### 🔎 Validate Summary — \`${{ matrix.env }}\`"
      ...
    } >> "$GITHUB_STEP_SUMMARY"
```

`$GITHUB_STEP_SUMMARY` writes Markdown to the top of the workflow run page. Without this, you click into the run, then into the job, then into the failed step. With it, the failure is visible in one click.

---

## 8. File 2 — `terraform-plan.yml`

> **Purpose:** Compute the diff a reviewer will actually approve. Persist that diff so the apply phase can re-use it.

### 8.1 Permissions are minimal

```yaml
permissions:
  id-token: write       # for OIDC
  contents: read        # for checkout
  pull-requests: write  # for the plan comment
```

No `actions: write`, no `issues: write` (the comment API uses the `pull-requests` scope). Every permission justified.

### 8.2 The `environment:` directive on a *plan* job

```yaml
environment: ${{ inputs.environment || 'dev' }}
```

Surprising but deliberate. Reasons:
- Per-environment IAM roles live as **Environment Variables** (`AWS_DEPLOY_ROLE_ARN`) on each environment. Setting `environment:` here is what makes `${{ vars.AWS_DEPLOY_ROLE_ARN }}` resolve to the correct role.
- For `dev`, no reviewer is required — plan runs immediately.
- For `production` (when run via `workflow_dispatch`), this becomes a built-in gate that you can configure later if you want plans-against-prod to require approval.

### 8.3 The plan binary upload

```yaml
- name: Upload Plan Artifact
  if: steps.plan.outcome == 'success'
  uses: actions/upload-artifact@v4
  with:
    name: tfplan-${{ env.TARGET_ENV }}-${{ github.event.pull_request.number || github.run_id }}
    path: |
      environments/${{ env.TARGET_ENV }}/tfplan.binary
      environments/${{ env.TARGET_ENV }}/${{ env.TARGET_ENV }}.tfvars
    retention-days: 7
    if-no-files-found: error
```

Three deliberate details:
- Artifact name includes **PR number** so apply can find the right one.
- Both the binary *and* the tfvars are uploaded — the apply job needs both.
- `if-no-files-found: error` makes a missing artifact a hard failure, never silent.
- 7-day retention balances debuggability with storage cost.

### 8.4 The PR comment includes init and validate outcomes

```javascript
const body = `### 📋 Terraform Plan — \`${process.env.TARGET_ENV || 'dev'}\`

| Step | Status |
|------|--------|
| init | \`${{ steps.init.outcome }}\` |
| validate | \`${{ steps.validate.outcome }}\` |
| plan | \`${{ steps.plan.outcome }}\` |
```

Reviewers see the full pipeline status in one comment. If init failed, you don't waste time looking at an empty plan output.

### 8.5 Truncation at 60 000 chars

```javascript
if (plan.length > 60000) {
  plan = plan.slice(0, 60000) + "\n\n...output truncated — see workflow logs...";
}
```

GitHub's hard limit on a comment is 65 536 characters. We truncate at 60 000 to leave headroom for the surrounding markdown frame. Without this, large plans would fail the comment API and reviewers would see nothing.

### 8.6 The "Fail if Plan Failed" step

```yaml
- name: Fail if Plan Failed
  if: steps.plan.outcome == 'failure'
  run: exit 1
```

The plan step uses `continue-on-error: true` so the comment step still runs. But that means the workflow is "successful" by default. This step at the *end* re-asserts failure so the PR check goes red. Order matters — comment first, then fail.

---

## 9. File 3 — `terraform-apply.yml`

> **Purpose:** Execute the reviewed change. Hardest workflow to get right because it's where actual damage can happen.

### 9.1 The `determine-env` job

```yaml
determine-env:
  outputs:
    target: ${{ steps.pick.outputs.target }}
  steps:
    - id: pick
      run: |
        if   [ "${{ github.event_name }}" == "workflow_dispatch" ]; then echo "target=${{ inputs.environment }}" >> $GITHUB_OUTPUT
        elif [ "${{ github.ref }}" == "refs/heads/main" ];          then echo "target=production"             >> $GITHUB_OUTPUT
        elif [ "${{ github.ref }}" == "refs/heads/develop" ];       then echo "target=dev"                    >> $GITHUB_OUTPUT
        else exit 1
        fi
```

A 5-line job that maps the trigger to a target environment. Why a separate job?

- **Single source of truth** for routing logic. The apply job just consumes the output.
- **Job-level outputs** can be referenced by `environment: ${{ needs.determine-env.outputs.target }}` — which would not work as a step-level output.
- **Cleaner diff** if the routing changes (one file, one job).

### 9.2 The `environment:` reviewer gate

```yaml
environment: ${{ needs.determine-env.outputs.target }}
```

This single line is what enforces the production reviewer requirement:
- The `production` environment in repo settings has 2 required reviewers.
- The job will pause in the `Waiting for review` state.
- Reviewers click **Approve and deploy** in the Actions tab.
- The reviewer is logged with their identity in the deployment history.

GitHub Environments are *the* mechanism for production approvals. They beat any custom solution.

### 9.3 The plan-artifact-or-fresh-plan fallback

```yaml
- name: Find Plan Artifact
  id: find-plan
  continue-on-error: true
  ...

- name: Apply Saved Plan
  if: steps.find-plan.outputs.found == 'true'
  run: terraform apply -input=false -no-color tfplan.binary

- name: Apply (fresh plan, no saved artifact)
  if: steps.find-plan.outputs.found != 'true'
  run: terraform apply -input=false -no-color -auto-approve -var-file="${TARGET}.tfvars"
```

Two paths:
- **Push trigger** (PR merge): the artifact exists → apply the reviewed binary. This is the safe path, used 99% of the time.
- **`workflow_dispatch` trigger** (manual rerun, e.g., for disaster recovery): no artifact → fresh plan + apply. Acceptable because manual dispatch already requires environment approval.

This pattern combines **plan-binary integrity** for normal operation with an **operational escape hatch** for disaster recovery — the safe path is the default, the manual path is available when needed.

### 9.4 Concurrency: `cancel-in-progress: false`

```yaml
concurrency:
  group: tf-apply-${{ github.ref }}
  cancel-in-progress: false
```

Cancelling an apply is dangerous — it leaves the state lock stuck and AWS resources half-created. Queueing is the only safe behavior.

### 9.5 The deployment summary

```yaml
- name: Deployment Summary
  if: always()
  run: |
    {
      echo "### 🚀 Terraform Apply — \`${{ needs.determine-env.outputs.target }}\`"
      echo ""
      echo "| Field | Value |"
      echo "|-------|-------|"
      echo "| Branch | \`${{ github.ref_name }}\` |"
      echo "| Commit | \`${{ github.sha }}\` |"
      echo "| Actor | @${{ github.actor }} |"
      echo "| Trigger | \`${{ github.event_name }}\` |"
      echo "| Status | \`${{ job.status }}\` |"
    } >> "$GITHUB_STEP_SUMMARY"
```

Five fields — every audit question answered at a glance: what env, which commit, who pushed it, how was it triggered, and did it succeed.

---

## 10. File 4 — `tf-statelock-unlock.yml`

> **Purpose:** Release a stuck S3 `.tflock` object so future runs can proceed. Safety-critical operational workflow.

### 10.1 Why a dedicated workflow

A force-unlock is:
- **Manual only** — no `push` or `pull_request` trigger.
- **Privileged** — requires write/delete access to the `.tflock` object in the state bucket.
- **Auditable** — must record *who*, *what*, and *why*.

It does not belong in the apply workflow. Separating it makes its dangerous nature visible.

### 10.2 The required `reason` input

```yaml
inputs:
  reason:
    description: "Why this unlock is needed (audit log)"
    required: true
    type: string
```

Forces the operator to type a justification. The reason gets written to `$GITHUB_STEP_SUMMARY` and is permanently visible in workflow run history. Critical for incident reviews.

### 10.3 Always uses the `production` environment

```yaml
environment: production
```

Even if the operator selected `dev`, the *workflow itself* runs in the production environment — meaning it requires production-tier reviewer approval. This deliberately makes force-unlock a high-friction operation. You don't want anyone running it casually.

### 10.4 Audit summary step is *first*

The audit log step runs **before** the actual unlock. Even if the force-unlock fails, the audit log shows the request was made. Order is intentional.

---

## 11. The TFLint Configuration

`.tflint.hcl` at the repo root:

```hcl
plugin "aws" {
  enabled = true
  version = "0.30.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

rule "terraform_required_version"            { enabled = true }
rule "terraform_required_providers"          { enabled = true }
rule "terraform_documented_outputs"          { enabled = true }
rule "terraform_documented_variables"        { enabled = true }
rule "terraform_typed_variables"             { enabled = true }
rule "terraform_naming_convention"           { enabled = true }
rule "aws_resource_missing_tags" {
  enabled = true
  tags    = ["Project", "Environment", "ManagedBy", "Owner"]
}
```

Each rule enforces a project standard:
- **Required version / providers** — prevents floating versions.
- **Documented variables / outputs** — every input/output must have a description.
- **Typed variables** — no `type = any`.
- **Naming convention** — enforces snake_case.
- **Missing tags** — every AWS resource must carry the four standard tags.

These rules turn coding standards from a "we agreed in a meeting" to a "CI rejects PRs that violate them."

---

# Part 3 — The "How"

## 12. End-to-End Lifecycle of a Change

```text
┌─────────────────────────────────────────────────────────────────┐
│ T+0:00   Engineer commits to feature/add-rds and pushes to GH   │
└────────────────────────┬────────────────────────────────────────┘
                         │
T+0:15   Engineer opens PR → develop
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ T+0:16  GitHub fires `pull_request` event                       │
│         → terraform-validate.yml triggers                       │
│           • Matrix runs across dev/production                  │
│           • fmt + init + validate + TFLint + Checkov            │
│           • All 3 matrix jobs pass in ~3 minutes                │
│         → terraform-plan.yml triggers (in parallel)             │
│           • OIDC handshake to AWS                               │
│           • init -backend-config=backend.hcl                    │
│           • plan -out=tfplan.binary -var-file=dev.tfvars        │
│           • Upload tfplan-dev-PR123 artifact                    │
│           • Post plan as PR comment                             │
│         Both workflows complete in ~5 min                       │
└────────────────────────┬────────────────────────────────────────┘
                         │
T+0:25   Reviewer reads plan comment, reviews diff, approves PR
                         ▼
T+0:26   Engineer clicks "Squash and merge" → develop
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ T+0:27  GitHub fires `push` event on develop                    │
│         → terraform-apply.yml triggers                          │
│           • determine-env outputs target=dev                    │
│           • Apply job starts on environment: dev (no gate)      │
│           • Downloads tfplan-dev-PR123 artifact                 │
│           • terraform apply tfplan.binary                       │
│           • Resources created in AWS                            │
│           • Deployment Summary written to GITHUB_STEP_SUMMARY   │
│         Apply completes in ~8 min                               │
└────────────────────────┬────────────────────────────────────────┘
                         │
T+0:35   Engineer verifies dev environment, opens promotion PR
         develop → main
                         ▼
T+1:00   Reviewer 1 + Reviewer 2 approve, PR merged to main
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ T+1:01  GitHub fires `push` event on main                       │
│         → terraform-apply.yml triggers                          │
│           • determine-env outputs target=production             │
│           • Apply job WAITS on environment: production          │
└────────────────────────┬────────────────────────────────────────┘
                         │
T+1:15   Senior reviewer clicks "Approve and deploy" in Actions tab
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│ T+1:15  Apply resumes                                           │
│         • Downloads tfplan-production-... artifact              │
│         • terraform apply tfplan.binary                         │
│         • Production resources updated                          │
│         • Deployment Summary written                            │
│         Apply completes in ~12 min                              │
└─────────────────────────────────────────────────────────────────┘

Total elapsed: ~1h 30min from commit to production live.
Critical-path human time: ~10 min reviewing.
```

---

## 13. Failure Modes & Recovery

| Failure | What Happens | Recovery |
|---|---|---|
| Validate fails (fmt / TFLint) | PR check goes red, reviewer sees specific lines | Fix locally, push fix, validate re-runs |
| Validate fails (Checkov) | PR check stays green (`soft_fail`), finding logged | Address finding, or document accepted risk |
| Plan fails (TF error) | PR comment shows error, "Fail if Plan Failed" makes check red | Fix code, push, plan re-runs |
| Plan fails (AWS auth) | OIDC step fails | Verify trust policy `sub` matches branch; verify environment vars |
| Apply succeeds, but state lock stuck (apply killed mid-run) | Future plans/applies fail with "state locked" | Run `tf-statelock-unlock.yml` with the lock ID |
| Apply fails partially (some resources created, some not) | State reflects partial reality, lock released | Re-run apply (it will reconcile) |
| Plan artifact expired (7 days passed) | `find-plan` returns false on dispatch | Re-trigger plan workflow; or use `workflow_dispatch` fallback path |
| Concurrent applies attempted | Second is queued by `concurrency` group | Wait — second runs after first finishes |
| Production reviewer unavailable | Apply waits in approval state | Configure backup reviewers in environment settings |

---

## 14. Required GitHub Configuration

The pipeline does not work in a fresh repo. These settings must be configured:

### 14.1 Repository Variables

`Settings → Secrets and variables → Actions → Variables`

| Name | Example |
|---|---|
| `AWS_REGION` | `ap-south-1` |
| `AWS_DEPLOY_ROLE_ARN` | (default fallback ARN) |

### 14.2 GitHub Environments

`Settings → Environments` — create three:

| Environment | Reviewers | Wait Timer | Deployment Branches | Variables |
|---|---|---|---|---|
| `dev` | 0 | 0 | `develop` | `AWS_DEPLOY_ROLE_ARN` (dev role) |
| `production` | 2 | 5 min | `main` | `AWS_DEPLOY_ROLE_ARN` (prod role) |

### 14.3 Branch Protection

`Settings → Branches` — protect both `main` and `develop`:

- ✅ Require PR before merging
- ✅ Required approvals: `develop` = 1, `main` = 2
- ✅ Dismiss stale approvals on new commits
- ✅ Require status checks: `Validate (dev)`, `Validate (production)`, `Plan (dev)`
- ✅ Require branches to be up to date
- ✅ Require conversation resolution
- ✅ Disallow force-push, deletion, direct push (admins included)

### 14.4 CODEOWNERS

`.github/CODEOWNERS` — auto-routes reviewers based on path.

---

## 15. Required AWS Configuration

### 15.1 OIDC Provider

One per AWS account. URL: `https://token.actions.githubusercontent.com`.

### 15.2 IAM Roles (one per environment)

| Role | Trust Policy `sub` | Permissions |
|---|---|---|
| `tf-deployer-dev` | `repo:OWNER/REPO:environment:dev` | Full Terraform-needed actions on dev resources |
| `tf-deployer-production` | `repo:OWNER/REPO:environment:production` | Same on production, scoped tighter |

### 15.3 State Backend

- S3 bucket with versioning + encryption + public-access-block
- *(No DynamoDB lock table — native S3 state locking via `use_lockfile = true` is used instead.)*
- KMS key (CMK) used by both

### 15.4 CloudTrail

Enabled in all regions, multi-region trail, log file validation on. Critical for the audit story this pipeline depends on.

---

# Part 4 — Defending This Design

## 16. Design Defense — Likely Questions With Strong Answers

These are the questions a senior reviewer is likely to ask when auditing this design. Each answer is structured to demonstrate the reasoning behind the decision, not just the result.

### Q1. *"Walk me through what happens when I open a PR against develop."*

> Two workflows fire in parallel. `terraform-validate.yml` runs a matrix across dev and production with fmt-check, init -backend=false, validate, TFLint, and Checkov — none need AWS so it works on fork PRs too. `terraform-plan.yml` does an OIDC handshake against the dev IAM role, runs init with the env-specific backend, runs `plan -out=tfplan.binary`, uploads the binary as an artifact named with the PR number, and posts a markdown plan summary as a PR comment. The plan step is `continue-on-error` so the comment posts even on failure, then a final step re-asserts failure if plan didn't succeed. Both workflows are required status checks for the PR.

### Q2. *"Why isn't the plan workflow blocked from running on fork PRs?"*

> Actually it is. The plan job has `if: github.event.pull_request.head.repo.full_name == github.repository`. Fork PRs would fail at OIDC anyway because the trust policy pins to this repo's `sub` claim, but we filter explicitly so the failure happens fast and the bot doesn't post a confusing error to the PR. Validation deliberately *doesn't* filter forks because it has no AWS access — fork contributors can see their own fmt and lint errors.

### Q3. *"How do you ensure the diff applied is the diff reviewed?"*

> The plan workflow saves `tfplan.binary` as a workflow artifact with a name keyed to the PR number. The apply workflow's `Find Plan Artifact` step uses the GitHub API to locate the matching artifact, downloads it, and runs `terraform apply tfplan.binary` — no `-var-file`, no `-auto-approve`, just the binary. This means even if state changes between merge and apply, the apply still executes the exact resource graph that was reviewed. The fallback path (fresh plan) only runs on `workflow_dispatch` for disaster recovery, where we accept the trade-off.

### Q4. *"What's your IAM separation strategy?"*

> Three roles, one per environment, each with a trust policy pinned to the GitHub Environment claim — so `tf-deployer-production` can only be assumed by jobs that declare `environment: production` in their YAML. Permissions are scoped to that environment's resources via tag-based conditions and resource-name patterns. Permissions boundaries cap what the role can do even if the inline policy is broader. The trust-policy `sub` claim is the single most important security control — it's what stops a malicious PR on a `feature/*` branch from grabbing prod credentials.

### Q5. *"Why GitHub Environments instead of just using `if:` on the apply job?"*

> Three reasons. First, environment-based reviewer approval is enforced by GitHub's UI — you cannot bypass it in YAML. Second, environments support per-env Variables, so `${{ vars.AWS_DEPLOY_ROLE_ARN }}` resolves to a different role per environment without any conditional logic. Third, the deployment history per environment is auditable — you can see who approved what when. `if:` filters give none of those.

### Q6. *"What happens if a Terraform apply gets killed mid-run?"*

> The native S3 lockfile (`terraform.tfstate.tflock`) stays in the bucket because the kill signal doesn't trigger Terraform's normal cleanup. Future plans and applies fail with `Error acquiring the state lock`. We have a dedicated workflow `tf-statelock-unlock.yml` that supports two paths — `terraform force-unlock <id>` when the lock-info is parseable, and a fallback that deletes the `.tflock` object directly via `aws s3api delete-object` when it isn't. The workflow always runs in the production environment so it requires reviewer approval regardless of which env's lock is being broken, takes a `reason` field as input, and audit-logs to GitHub Step Summary. We unlock only after confirming no other apply is running.

### Q7. *"How do you handle secrets?"*

> We don't put secrets in GitHub Secrets if AWS can hold them — that's what AWS Secrets Manager and SSM Parameter Store are for. Terraform reads them at apply time via `data "aws_secretsmanager_secret_version"` data sources. Variables and outputs that touch secrets are marked `sensitive = true` so plan output doesn't leak them. State files are encrypted at rest with a customer-managed KMS key, and access to the state bucket is restricted to the apply roles. The only thing in GitHub Secrets is the `GITHUB_TOKEN` (auto-generated) and a Slack webhook for failure notifications.

### Q8. *"Why a matrix in validate but not in plan?"*

> Validate is read-only and cheap — running it across both envs in parallel costs ~2 minutes total and catches env-specific configuration errors before review. Plan is expensive (it does a real AWS handshake and computes a full diff) and we only need it for the env that's actually changing on this PR — usually dev for daily work. For production plans, we use `workflow_dispatch` with an `environment` input so an engineer can plan against prod on demand.

### Q9. *"How would you migrate this to Spacelift / Terraform Cloud?"*

> Most of the pattern transfers directly: the OIDC role, the state backend, the module structure, the branch protection, and the plan-binary artifact concept. What changes is the `apply` workflow — Spacelift takes over plan/apply orchestration with its own UI for approvals and policy-as-code (OPA). I'd keep `terraform-validate.yml` for fast pre-merge feedback (Spacelift charges per run-minute, GitHub Actions is free for public repos), and let Spacelift own apply. Migration would be a 2-week effort: 1 week setting up Spacelift stacks per env, 1 week deprecating the GitHub Actions apply workflow. The validate workflow stays.

### Q10. *"What's the weakest link in this design?"*

> Three honest weaknesses. **First**, no automated drift detection — if someone clicks in the AWS console, we don't notice until the next plan. Mitigation: add a scheduled workflow that runs `terraform plan` against `main` daily and alerts on non-zero diff. **Second**, the plan-binary path baked into apply is a soft dependency — if the artifact is older than 7 days it's gone. Mitigation: extend retention to 30 days for production, or push the binary to S3 with lifecycle rules. **Third**, action versions are pinned to major (`@v4`), not SHA. A compromised tag-move could inject malicious behavior. Mitigation: pin to SHA and use Dependabot to auto-PR upgrades. None of these are blockers for the project's current scale, but I'd address them as the team grows.

---

## 17. Future Enhancements

Stack-ranked by ROI:

| # | Enhancement | Estimated Effort | When to Add |
|---|---|---|---|
| 1 | Scheduled drift detection workflow (daily plan vs main) | 1 day | First production incident from drift |
| 2 | SHA-pinning for all GitHub Actions + Dependabot | 1 day | Before SOC 2 audit |
| 3 | Composite action `.github/actions/tf-setup` for shared steps | 1 day | When a 5th workflow is added |
| 4 | Slack/Teams notification on apply failure | 0.5 day | First missed failure |
| 5 | Cost-impact PR comment (Infracost) | 1 day | First "why did this cost so much?" surprise |
| 6 | Manual `tf-destroy.yml` workflow with `confirm: type DELETE` input | 0.5 day | First teardown |
| 7 | OPA / Conftest policy gate | 2 days | Multi-team org |
| 8 | Self-hosted runners with VPC egress controls | 3 days | Compliance requirement |
| 9 | Migrate to Spacelift / Terraform Cloud | 2 weeks | Pipeline runtime > 30 min |

---

## 18. References

- HashiCorp — [Terraform GitHub Actions Tutorial](https://developer.hashicorp.com/terraform/tutorials/automation/github-actions)
- AWS — [Configuring OpenID Connect in AWS](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)
- GitHub — [Security Hardening with OpenID Connect](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)
- GitHub — [Using Environments for Deployment](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
- AWS Action — [`aws-actions/configure-aws-credentials`](https://github.com/aws-actions/configure-aws-credentials)
- Internal — [`github-oidc-aws-setup.md`](./github-oidc-aws-setup.md) (OIDC trust model)
- Internal — [`oidc-github-role.yml`](./oidc-github-role.yml) (CloudFormation template)
- Internal — [`terraform-workflow-deep-dive.md`](./terraform-workflow-deep-dive.md) (line-by-line YAML)
- Internal — [`terraform-engineering-handbook.md`](./terraform-engineering-handbook.md) (Git, state, secrets, best practices)
- Internal — [`task-workbook-terraform-cicd.md`](./task-workbook-terraform-cicd.md) (36-task hands-on lab)

---

<div align="center">

**🏛️ Designed for production. Documented for clarity. Defensible in any technical review.**

[⬆ Back to Top](#%EF%B8%8F-cicd-workflow-design--architecture--rationale)

</div>
