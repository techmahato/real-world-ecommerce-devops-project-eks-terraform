# Operations Runbook

This is the on-call playbook for engineers managing this infrastructure 24×7. It assumes you've already done [SETUP.md](./SETUP.md) once.

## TL;DR — what do I do right now?

| Symptom | Jump to |
|---|---|
| "Terraform says state is locked" | [Stuck state lock](#stuck-state-lock) |
| "I need cluster admin RIGHT NOW" | [Break-glass cluster admin](#break-glass-cluster-admin) |
| "Apply is failing on EIP / NAT / cleanup" | [AWS eventual-consistency errors](#aws-eventual-consistency-errors) |
| "Someone changed something in the console" | [Drift](#drift) |
| "Need to roll a node group" | [Roll node group](#roll-node-group) |
| "Pod is stuck on a stopped/draining node" | [Cordon and drain a node](#cordon-and-drain-a-node) |
| "Need to revert my last apply" | [Roll back](#roll-back) |
| "Bill is too high" | [Investigate cost](#investigate-cost) |

## Daily commands

Use the Makefile. Don't memorise terraform invocations.

```bash
make help                    # show every target
make plan-dev                # plan dev
make apply-dev               # apply the plan you just reviewed
make output-dev              # show all dev outputs
make summary-dev             # show only the cluster_summary cheatsheet
make kubeconfig-dev          # populate kubectl
make bastion-ssm-dev         # SSM into the dev bastion
make destroy-dev             # tear down dev (with confirmation)
ENV=production make plan     # any target works for prod
```

`cluster_summary` is the single output you should know about. It bundles cluster name, region, endpoint, kubeconfig command, bastion SSM command, and links to this runbook. From the bastion or your laptop, `make summary-prod` tells you everything you need.

## Common operations

### Grant cluster access to a new engineer

Add an entry to `eks_access_entries` in the env tfvars. PR, plan-review, merge. CI applies. End-to-end ~5 minutes. Full procedure in [`modules/eks/README.md`](../modules/eks/README.md#how-do-i-give-a-new-user-cluster-admin).

### Roll node group

Two reasons to do this: (1) AMI updates haven't picked up automatically; (2) launch-template change you want to propagate.

```bash
# Option A: trigger via AWS CLI (no Terraform required)
aws eks update-nodegroup-version \
  --cluster-name $(make summary-prod | jq -r '.eks.cluster_name') \
  --nodegroup-name <name>

# Option B: edit launch-template via tfvars (e.g. bump disk_size_gb), terraform apply
```

Rolling respects PodDisruptionBudgets. Watch progress:

```bash
aws eks describe-update --cluster-name <c> --nodegroup-name <n> --update-id <id>
```

### Cordon and drain a node

When a single node is misbehaving and you don't want EKS to schedule new pods to it:

```bash
# from inside kubectl context
kubectl cordon ip-10-30-x-y.ap-south-1.compute.internal
kubectl drain ip-10-30-x-y.ap-south-1.compute.internal --ignore-daemonsets --delete-emptydir-data
# To replace it entirely - terminate the EC2 instance; ASG launches a new one
aws ec2 terminate-instances --instance-ids i-xxxxxx
```

### Upgrade Kubernetes version

1. Check Cluster Insights: `aws eks list-insights --cluster-name <c>` - any "ERROR" status means deprecated APIs in use; resolve them in workloads first.
2. Edit `kubernetes_version` in env tfvars (one minor version at a time, e.g. `1.30 → 1.31`).
3. PR, plan-review (you'll see `~ version` on `aws_eks_cluster` and a node-group version field).
4. Apply. Control plane upgrade takes ~10 min, node groups roll on their own once the control plane is on the new version.
5. Bump add-on versions in `cluster_addons` if AWS recommends a newer one for the new k8s version.

### Add a new node group

Add an entry to `eks_node_groups` in env tfvars:

```hcl
eks_node_groups = {
  # existing entries unchanged
  app    = { ... }
  system = { ... }
  # NEW
  gpu = {
    capacity_type  = "ON_DEMAND"
    instance_types = ["g4dn.xlarge"]
    labels         = { workload = "ml" }
    taints         = [{ key = "nvidia.com/gpu", value = "true", effect = "NO_SCHEDULE" }]
  }
}
```

Plan, apply. Existing groups untouched.

### Add a new EKS add-on

Add to `eks_cluster_addons` in env tfvars:

```hcl
eks_cluster_addons = {
  # defaults...
  vpc-cni            = { before_compute = true }
  kube-proxy         = { before_compute = true }
  coredns            = { before_compute = false }
  aws-ebs-csi-driver = { before_compute = false }
  # NEW
  amazon-cloudwatch-observability = { before_compute = false }
}
```

### Add a new IAM permission to nodes

Don't fork the module. Add to `node_role_additional_policy_arns` (variable on the EKS module - exposed via `node_role_additional_policy_arns` env-side if you've plumbed it through; otherwise edit the env-level main.tf):

```hcl
module "eks" {
  ...
  node_role_additional_policy_arns = {
    SSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    CloudWatchAgentServer  = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"  # NEW
  }
}
```

## Incident response

### Stuck state lock

Symptom: `Error acquiring the state lock` in CI or local apply.

```bash
# 1. Check who holds the lock
make state-list ENV=dev    # if this works, the lock isn't really stuck
# In the error message, find the LOCK_ID - looks like "01234567-89ab-cdef-..."

# 2. If you're sure the original run is dead (CI killed, your laptop crashed), force-unlock
make state-unlock ENV=dev LOCK_ID=01234567-89ab-cdef-...

# OR via the dedicated workflow:
# GitHub UI > Actions > "Terraform State Unlock" > Run workflow > paste lock ID
```

If unsure whether the original run is alive, **wait**. Force-unlocking a live run corrupts state.

### Break-glass cluster admin

You've been paged, prod cluster is having issues, you need kubectl access right now and don't have time for a PR.

**Path A — bastion is already up**: SSM in, kubectl from there. The bastion's IAM role already has `eks:Describe*`. If the bastion role isn't in `eks_access_entries`, the kubectl call returns `Unauthorized`. Use Path B.

**Path B — break-glass via AWS CLI** (no Terraform required, immediate):

```bash
aws eks create-access-entry \
  --cluster-name <name> \
  --principal-arn <your-IAM-principal-ARN> \
  --type STANDARD

aws eks associate-access-policy \
  --cluster-name <name> \
  --principal-arn <your-IAM-principal-ARN> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

Within seconds, your principal has admin. **Then**, within 24h, open a PR adding the same entry to `eks_access_entries` in tfvars so it's in code. If you skip this step, the next `terraform apply` will remove your entry (Terraform doesn't know it exists).

### AWS eventual-consistency errors

Symptom: `terraform apply` partially succeeds then errors on cleanup. Common ones:

| Error | Cause | Fix |
|---|---|---|
| `InvalidNetworkInterfaceID.NotFound` releasing an EIP | NAT was destroyed; AWS hasn't fully released its ENI yet | **Re-run apply.** Usually succeeds on attempt 2. |
| `DependencyViolation: VPC has dependencies` on destroy | Something AWS-managed (e.g. an ELB you didn't put there) is in the VPC | Manually delete the offending resource, retry destroy. |
| `Error: Error creating EKS Cluster` on first apply | IAM role propagation delay | **Re-run apply.** ~30s wait usually fixes it. |
| `OptInRequired` on a service | Service not enabled in the region | Enable in AWS console, retry. |

Default response: re-run once. If it persists, dig into the specific resource.

### Drift

The drift-detection workflow runs every Monday. If it fails:

1. Click into the failed `Terraform Drift Detection / Drift (env)` job in GitHub Actions.
2. The "Show plan summary on drift" step shows what's different.
3. Decide: was the change intentional (someone hot-fixed something in the console)? Or unintentional (a teammate with admin made a change without knowing)?
4. If intentional → make the same change in tfvars/code, PR, merge. Drift goes away.
5. If unintentional → revert via `terraform apply` to restore code-state.
6. If you can't tell who made it → CloudTrail in the AWS console. Filter by resource ARN and time range.

To run drift detection on demand: GitHub UI > Actions > "Terraform Drift Detection" > Run workflow.

### Roll back

You just applied something that broke things.

```bash
# 1. Revert the code change
git revert <merge-commit-sha>
git push

# 2. CI runs plan automatically, you review, merge to apply the revert
# Apply restores the previous state.
```

For state-corruption issues (rare): the bootstrap S3 bucket has versioning on. In the AWS console, navigate to the state file, view versions, restore the previous version. Then `terraform apply` to reconcile.

### Investigate cost

Budget alerts fire from SNS topic in the env. To see what's driving spend:

```bash
# Open AWS Cost Explorer
# Filter: Tag = Project, Value = ecommerce-eks
# Group by: Service
# Time: Last 30 days
```

Top suspects in this stack:
- **EKS control plane** ($73/mo per cluster, fixed). Halve by destroying the dev cluster overnight.
- **NAT Gateway data transfer** ($0.045/GB processed). If high → check whether VPC endpoints are doing their job (they should route ECR, STS, etc. off NAT).
- **Interface VPC endpoints** ($0.01/hr per AZ per service). 10 services × 3 AZs ≈ $220/mo. Trim the list in tfvars if you're not using all of them.
- **NAT Gateways themselves** (~$32/mo each). Per-AZ in prod (3 NATs); single in dev (1 NAT).
- **EBS volumes on stopped EKS nodes** — kept until the node group is destroyed.

### Disable cost-heavy components for dev cluster overnight

```bash
make destroy-dev   # tears down the entire dev environment
```

Re-create with `make plan-dev && make apply-dev` next morning (~15 min).

## Where to find things

| Need | Where |
|---|---|
| Module READMEs | `modules/<name>/README.md` |
| Per-env outputs | `make output-<env>` or `terraform output` in `environments/<env>/` |
| Apply history | GitHub Actions > "Terraform Apply" runs |
| State files | S3 bucket from `bootstrap` outputs, key `environments/<env>/terraform.tfstate` |
| CloudTrail (who did what) | AWS Console > CloudTrail > Event history |
| EKS cluster logs | CloudWatch Logs > `/aws/eks/<cluster-name>/cluster` |
| VPC flow logs | dev: CloudWatch Logs `/aws/vpc/<env>/flow-logs`. prod: S3 bucket `<project>-production-vpc-flow-logs-<account>` |
| Bastion sessions | CloudWatch Logs > SSM session output (if SSM session logging is enabled) |

## Escalation

| Severity | Who | When |
|---|---|---|
| Service down, data at risk | Senior on-call | Immediately |
| Service degraded but recoverable | Team lead | Same business day |
| Drift detected | Whoever is on-call | Within 24h |
| Cost spike alert | Whoever is on-call | Same business day |
| Failed CI plan/apply on PR | PR author | Normal review timing |

(Replace these with your team's actual on-call rotation and escalation paths.)
