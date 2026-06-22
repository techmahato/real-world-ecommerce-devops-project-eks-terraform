# EKS Module — Operator Runbook

A focused, audit-ready EKS module. Built to be managed in production for years without re-reading the source.

## What it gives you

- Secure-by-default cluster: customer-managed KMS encryption, all 5 control-plane log types, no implicit admin
- Modern access control via EKS access entries (declarative, IAM-based, audit-friendly)
- Multiple node groups with per-group labels/taints/capacity-type/key-pair
- Pluggable add-ons via a map variable (`vpc-cni`, `coredns`, `kube-proxy`, `aws-ebs-csi-driver` by default; add more by adding entries)
- Explicit cluster + node security groups with caller-supplied additional rules
- IRSA enabled by default (OIDC provider)
- IMDSv2 enforced on every node, EBS encryption on every root volume
- SSM access to nodes for debugging without bastion-hopping

## File layout

| File | What lives there |
|---|---|
| `main.tf` | KMS, log group, cluster, access entries, dataplane wait |
| `iam.tf` | Cluster role, node role, OIDC provider |
| `security-groups.tf` | Additional cluster SG, node SG, recommended rules |
| `node-groups.tf` | Per-group launch template + node group resource |
| `addons.tf` | Before-/after-compute add-ons, EBS CSI IRSA |
| `outputs.tf` | Public API |
| `variables.tf` | All inputs (sectioned) |
| `versions.tf` | Provider pins (`aws ~> 5.40`, `tls`, `time`) |

## Operator runbook

### How do I give a new user cluster admin?

Add an entry to `access_entries` in your env's tfvars. Example for dev:

```hcl
access_entries = {
  platform-admins = {
    principal_arn = "arn:aws:iam::123:role/PlatformAdmin"
    type          = "STANDARD"
    policy_associations = {
      admin = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = { type = "cluster" }
      }
    }
  }
  # Add another user:
  alice = {
    principal_arn = "arn:aws:iam::123:user/alice"
    policy_associations = {
      view = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
        access_scope = { type = "cluster" }
      }
    }
  }
}
```

Apply. The new principal can immediately `aws eks update-kubeconfig` and `kubectl`.

EKS-managed access policies (use the ARN in `policy_arn`):

| Policy | Equivalent K8s permission |
|---|---|
| `AmazonEKSClusterAdminPolicy` | `cluster-admin` (full) |
| `AmazonEKSAdminPolicy` | Admin within scoped namespaces |
| `AmazonEKSEditPolicy` | Edit within scoped namespaces |
| `AmazonEKSViewPolicy` | Read-only |

For namespace-scoped access, change `access_scope` to `{ type = "namespace", namespaces = ["app1", "app2"] }`.

### How do I revoke access?

Remove the entry from `access_entries` and apply. The IAM principal can no longer `kubectl`.

### How do I upgrade the Kubernetes version?

1. Check EKS Insights in the AWS console for deprecation warnings on the current version. Cluster Insights are queryable via API and surface deprecated APIs in your workloads.
2. Bump `kubernetes_version` in tfvars (one minor version at a time, e.g. `1.30 → 1.31`).
3. Run `terraform plan`. Expect:
   - `aws_eks_cluster.this.version` shows `~ "1.30" -> "1.31"` (in-place, ~10 minutes)
   - Node groups: no immediate change. You'll roll them in step 5.
4. `terraform apply` for the control plane upgrade.
5. Roll node groups: change one node group's `instance_types` or `disk_size_gb` slightly to force a launch-template revision, or use `aws eks update-nodegroup-version`. Or just bump `kubernetes_version` and apply — managed node groups roll on their own.
6. Bump add-on versions in `cluster_addons` if AWS recommends a newer one for the new k8s version.

### How do I add a new add-on?

Add a key to `cluster_addons`:

```hcl
cluster_addons = {
  vpc-cni            = { before_compute = true }
  kube-proxy         = { before_compute = true }
  coredns            = { before_compute = false }
  aws-ebs-csi-driver = { before_compute = false }

  # New: EFS CSI driver
  aws-efs-csi-driver = {
    before_compute = false
    # If the addon needs IRSA, pass the role ARN here.
    # service_account_role_arn = aws_iam_role.efs_csi.arn
  }
}
```

Apply. `aws eks describe-addon --cluster-name <name> --addon-name aws-efs-csi-driver` to verify.

### How do I add a custom IAM policy to nodes?

Don't fork the module. Pass it through:

```hcl
node_role_additional_policy_arns = {
  SSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  CloudWatchAgentServer  = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  MyCustomPolicy         = aws_iam_policy.my_custom.arn
}
```

The map keys are stable for_each identifiers — name them descriptively.

### How do I schedule a workload to a specific node group?

Two mechanisms, picked by you in the node group definition:

**Labels** (soft scheduling — workloads opt in via `nodeSelector`):

```hcl
eks_node_groups = {
  app = {
    instance_types = ["m5.large"]
    labels = { workload = "app", lifecycle = "on-demand" }
  }
}
```

Workload manifest:

```yaml
spec:
  nodeSelector:
    workload: app
```

**Taints** (hard restriction — only tolerating workloads can land):

```hcl
eks_node_groups = {
  system = {
    labels = { workload = "system" }
    taints = [{ key = "system", value = "true", effect = "NO_SCHEDULE" }]
  }
}
```

Workload manifest:

```yaml
spec:
  tolerations:
    - key: system
      operator: Equal
      value: "true"
      effect: NoSchedule
  nodeSelector:
    workload: system
```

### How do I add a new node group without touching existing ones?

Add an entry to `eks_node_groups`. The `for_each` keys mean existing groups are untouched.

### How do I drain and remove a node group safely?

1. Apply with the entry removed from `eks_node_groups`. Terraform will destroy that node group, which triggers EKS to drain pods first (respecting PodDisruptionBudgets and the `update_config.max_unavailable`).
2. Wait. EKS does this gracefully — pods get rescheduled to remaining node groups (which is why having multiple node groups in prod is valuable).

### How do I SSH into a node?

If you set `key_name` on the node group:

```bash
aws ec2 describe-instances --filters "Name=tag:NodeGroup,Values=app" --query 'Reservations[*].Instances[*].[InstanceId,PrivateIpAddress]'
ssh -i ~/.ssh/<key>.pem ec2-user@<private-ip>   # via bastion
```

**Better:** use SSM (no SSH key needed):

```bash
aws ssm start-session --target <instance-id>
```

### How do I rotate the KMS key?

Module sets `enable_key_rotation = true` by default — AWS rotates the underlying key material annually. The key ARN doesn't change. Nothing to do.

If you want to rotate the *entire key*, set `kms_key_arn` in tfvars to a new key, plan, apply. **Caution:** existing encrypted Secrets in etcd remain readable as long as the old key is around (AWS keeps the old material). To fully rotate, you'd also re-encrypt every Secret. Out of scope for normal ops.

### How do I disable EKS in this environment temporarily?

Set `enable_eks = false` in tfvars (the env-level wrapper). Apply. The whole cluster, node groups, KMS, log group, addons, OIDC, IAM all destroy. Plan output should be very large; review carefully.

To re-enable, flip back to `true` and apply. Cluster comes back from scratch.

### How do I see what an upgrade would change before I do it?

```bash
terraform plan -var-file=dev.tfvars
```

The plan output is the source of truth. Pay attention to:

- Cluster version diff (in-place, minor downtime risk)
- Node group AMI ID drift (rolls nodes)
- Add-on version diff (replaces the addon, can briefly disrupt the addon's controllers)

### Common errors

| Error | Likely cause | Fix |
|---|---|---|
| `Unauthorized` on `kubectl` | Your principal isn't in `access_entries`. | Add it. |
| Node stuck in `NotReady` | vpc-cni didn't initialise before kubelet asked for a pod CIDR. | Usually self-heals after 1–2 minutes; if persistent, `aws eks describe-addon-versions --addon-name vpc-cni` and bump the version. |
| `Error: aws-auth ConfigMap` warnings | Authentication mode mismatch. | Confirm `authentication_mode = "API_AND_CONFIG_MAP"`. |
| Cluster apply hangs at "Creating..." | Subnets in fewer than 2 AZs, or subnets without proper tagging for ELBs. | Fix subnet count / `kubernetes.io/role/internal-elb` tag. |

## Inputs (selected)

Full reference in `variables.tf`. Most-used:

| Variable | Type | Notes |
|---|---|---|
| `kubernetes_version` | string | Bump to upgrade |
| `private_subnet_ids` | list(string) | At least 2 AZs |
| `endpoint_private_access` / `endpoint_public_access` | bool | Pick a posture |
| `endpoint_public_access_cidrs` | list(string) | 0.0.0.0/0 rejected |
| `access_entries` | map(object) | Cluster admins/users |
| `kms_key_arn` | string | null = module creates one |
| `eks_node_groups` | map(object) | One entry per node pool |
| `cluster_addons` | map(object) | EKS-managed addons |
| `node_role_additional_policy_arns` | map(string) | Extra node permissions |

## Cost shape

| Item | Approx cost (us-east-1, similar in ap-south-1) |
|---|---|
| Control plane | $73/mo |
| 2 × t3.medium SPOT (dev) | ~$30/mo |
| 2 × m5.large + 2 × m5.xlarge ON_DEMAND (prod) | ~$230/mo |
| KMS key | $1/mo |
| CloudWatch logs (90-day retention, ~5GB) | ~$3/mo |
| **Dev running** | **~$110/mo** |
| **Prod running** | **~$310/mo** |

`terraform destroy` when not in use is the biggest cost lever for dev.

## Compliance checklist

What this module does for an InfoSec/audit review:

- ✅ Secrets encrypted at rest with customer-managed KMS, key rotation enabled
- ✅ All 5 control-plane log types ship to CloudWatch (audit log especially)
- ✅ Implicit admin disabled; cluster access fully declarative via `access_entries`
- ✅ IMDSv2 required on every node
- ✅ EBS root volume encrypted on every node
- ✅ Cluster ENIs in private subnets only
- ✅ OIDC provider for IRSA (per-pod IAM, not node-wide)
- ✅ Network rules in code (no console-edit drift)
- ✅ All resources tagged with Project, Environment, Owner, CostCenter, DataClassification, Repository (via provider default_tags)
- ❓ Pod Security Standards / OPA Gatekeeper — separate concern (platform-policies module)
- ❓ Network policies — separate concern (deploy via Calico, Cilium, or built-in PSS)

## What's intentionally NOT in this module

- Karpenter / Cluster Autoscaler — separate platform-addons module
- AWS Load Balancer Controller, ExternalDNS, cert-manager — Helm-released, separate module
- ArgoCD — GitOps layer
- Prometheus / Grafana / Loki — observability layer
- aws-auth ConfigMap management — use access entries instead
- Self-managed node groups, Fargate profiles — managed node groups only
- IPv6, Outposts, EFA — out of scope
