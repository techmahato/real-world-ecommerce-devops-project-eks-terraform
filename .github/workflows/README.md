# GitHub Actions Workflows

This directory contains the CI/CD pipelines for the project. All workflows authenticate to AWS via **OIDC** — there are no static AWS keys stored anywhere.

## 📋 Workflows

| File | Trigger | What It Does | Gates |
|---|---|---|---|
| [`terraform-validate.yml`](./terraform-validate.yml) | PR → `main` / `develop` | `fmt -check`, `init -backend=false`, `validate`, TFLint, Checkov across **dev / production** matrix | None — read-only |
| [`terraform-plan.yml`](./terraform-plan.yml) | PR → `develop`; manual dispatch | OIDC login, `init`, `plan`, posts plan as PR comment, uploads `tfplan.binary` artifact | `id-token: write`, fork-PR filter |
| [`terraform-apply.yml`](./terraform-apply.yml) | Push to `develop` (→ dev) / `main` (→ production); manual dispatch | OIDC login, downloads saved plan binary, `terraform apply tfplan.binary` (or fresh plan on dispatch) | GitHub Environment reviewer approval |
| [`tf-statelock-unlock.yml`](./tf-statelock-unlock.yml) | Manual dispatch only | `terraform force-unlock <id>` — or directly delete the orphaned `.tflock` object from S3 | Always uses `production` environment for reviewer approval |

## 🔐 Required Repository Configuration

### Repository Variables (`Settings → Secrets and variables → Actions → Variables`)

| Name | Example | Purpose |
|---|---|---|
| `AWS_REGION` | `ap-south-1` | Region for all AWS calls |
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::123456789012:role/tf-deployer-dev` | Default role; per-env overrides go in Environment Variables |

### GitHub Environments (`Settings → Environments`)

Create two environments — `dev` and `production` — each with:

- An **Environment Variable** `AWS_DEPLOY_ROLE_ARN` pointing to that env's IAM role.
- **Required reviewers** (none for `dev`, 1-2 for `production`).
- **Deployment branches** restricted: `develop` → `dev`, `main` → `production`.

### Branch Protection (`Settings → Branches`)

For both `main` and `develop`:

- ✅ Require pull request before merging
- ✅ Require approvals (1 for `develop`, 2 for `main`)
- ✅ Require status checks: `Validate (dev)`, `Validate (production)`, `Plan (dev)`
- ✅ Require branches up to date
- ✅ Disallow force-push and direct push

## 🧭 Flow Summary

```
feature/*  ──open PR──►  validate (matrix) + plan (dev)  ──comment plan──►  reviewer approves
                                                                                  │
                                                                          merge to develop
                                                                                  │
                                                                                  ▼
                                                              apply → dev (no extra gate)
                                                                                  │
                                                                          PR develop → main
                                                                                  │
                                                                          merge to main
                                                                                  │
                                                                                  ▼
                                                  apply → production (waits for reviewer approval)
```

## 📚 Related Documentation

- [`docs/github-oidc-aws-setup.md`](../../docs/github-oidc-aws-setup.md) — OIDC trust model
- [`docs/oidc-github-role.yml`](../../docs/oidc-github-role.yml) — CloudFormation template
- [`docs/terraform-workflow-deep-dive.md`](../../docs/terraform-workflow-deep-dive.md) — line-by-line workflow walkthrough
- [`docs/terraform-engineering-handbook.md`](../../docs/terraform-engineering-handbook.md) — Git, modules, state, secrets, best practices
- [`docs/task-workbook-terraform-cicd.md`](../../docs/task-workbook-terraform-cicd.md) — 36-task hands-on workbook
