# Bastion Module

A focused Ubuntu 24.04 jump host for reaching private-tier resources (EKS nodes, RDS, ElastiCache) without exposing them to the internet.

## What you get

- One `t3.micro` Ubuntu 24.04 LTS instance in a public subnet
- Stable Elastic IP (so SSH config and firewall allow-lists survive stop/start)
- Hardened: IMDSv2-only, EBS-encrypted, detailed monitoring on
- IAM role with `AmazonSSMManagedInstanceCore` so SSM Session Manager works out of the box
- Optional SSH access, gated by `allowed_ssh_cidrs` + `ssh_key_name`
- First-boot user data installs `awscli`, `jq`, `kubectl`, `psql`, `mysql`, `redis-cli`

## Two ways to connect

**SSM Session Manager (recommended).** No SSH key, no port 22, no audit gaps.

```bash
aws ssm start-session --target <instance-id>
```

The `ssm_start_session_command` output gives you the exact command.

**SSH (when SSM isn't enough).** Set `allowed_ssh_cidrs` to your office or home IP as a `/32`, set `ssh_key_name` to a key pair you've already created in AWS:

```bash
ssh -i ~/.ssh/your-key.pem ubuntu@<bastion_public_ip>
```

The module **refuses** to open SSH to `0.0.0.0/0` even if you ask. Pin to a specific CIDR.

## Cost

| State | Cost (us-east-1) |
|---|---|
| `t3.micro` running | ~$7.50/mo |
| `t3.micro` stopped | $0 (only EBS root volume billed at ~$1.60/mo for 20GB gp3) |
| EIP attached to running instance | $0 |
| EIP detached or attached to stopped instance | ~$3.60/mo |

If you stop the bastion when not in use (recommended), expect ~$5/mo.

## Inputs

| Name | Type | Default | Required | Description |
|---|---|---|---|---|
| `project_name` | `string` | — | yes | |
| `environment` | `string` | — | yes | |
| `vpc_id` | `string` | — | yes | Pass `module.network.vpc_id` |
| `subnet_id` | `string` | — | yes | Pass one of `module.network.public_subnet_ids` |
| `vpc_cidr` | `string` | — | yes | For SG egress rules |
| `instance_type` | `string` | `t3.micro` | no | |
| `ami_ssm_parameter` | `string` | `/aws/service/canonical/ubuntu/server/24.04/...` | no | Override for a different distro/arch |
| `ssh_key_name` | `string` | `null` | no | Skip for SSM-only |
| `allowed_ssh_cidrs` | `list(string)` | `[]` | no | `0.0.0.0/0` is rejected by validation |
| `root_volume_size_gb` | `number` | `20` | no | |
| `associate_public_ip` | `bool` | `true` | no | Required for SSH |

## Outputs

| Name | Description |
|---|---|
| `instance_id` | Use with `aws ssm start-session --target` |
| `public_ip`, `public_dns` | For SSH connection |
| `private_ip` | If you SSH from inside the VPC |
| `security_group_id` | Reference from RDS/EKS SGs to allow bastion ingress |
| `ssm_start_session_command` | Copy-paste-ready connect command |

## Operational tips

**Stop when not in use.** A bastion sitting idle 24/7 is wasted money.

```bash
aws ec2 stop-instances --instance-ids $(terraform output -raw bastion_instance_id)
aws ec2 start-instances --instance-ids $(terraform output -raw bastion_instance_id)
```

The EIP and root volume persist; only compute time is billed when running.

**Reach a private RDS:**

```bash
# SSM port-forwarding
aws ssm start-session \
  --target <bastion-instance-id> \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["mydb.xyz.rds.amazonaws.com"],"portNumber":["5432"],"localPortNumber":["5432"]}'

# Now connect locally
psql -h localhost -p 5432 -U admin mydb
```

**Reach EKS:** SSH in, configure kubectl with `aws eks update-kubeconfig --name <cluster>`, run kubectl as normal.

## Hardening — what this module does and doesn't do

**Does:**
- IMDSv2 only (mitigates SSRF -> credential theft)
- EBS encryption at rest
- Refuses `0.0.0.0/0` SSH
- Minimum-scope IAM (SSMManagedInstanceCore + read-only Describe)
- Default SG of the VPC is locked down by the network module

**Does not (deliberately):**
- Set up SSH bastion auditing (use SSM session logs instead)
- Patch automatically (use `aws ssm send-command` with `AWS-RunShellScript` or a maintenance window)
- Auto-stop on schedule (out of scope; add an EventBridge rule + Lambda if you want it)
- Run in an Auto Scaling Group (a bastion is a pet, not cattle)

## When NOT to use this module

If you only need SSM access, you don't actually need a bastion at all. AWS Systems Manager can `start-session` directly on any EC2 instance in any subnet (including private). A separate jump-box is only valuable when you need SSH or when other engineers aren't set up for SSM yet.
