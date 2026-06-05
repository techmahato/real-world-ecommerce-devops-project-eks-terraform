# Bootstrap — Remote State Backend

One-time provisioning of the S3 bucket that holds Terraform remote state for every environment in this project. **No DynamoDB lock table** — Terraform 1.10+ uses native S3 state locking via `use_lockfile = true`.

## What it creates

- An S3 bucket with versioning, encryption, and all public access blocked.
- A bucket policy that denies non-TLS access.
- A lifecycle rule that expires noncurrent state versions after 90 days.

## How to apply

```bash
cd bootstrap

# 1. Copy and edit the example tfvars
cp terraform.tfvars.example terraform.tfvars
#    → set state_bucket_name to a globally-unique value

# 2. Initialize with LOCAL state (intentional — this is the chicken/egg break)
terraform init

# 3. Apply
terraform apply

# 4. Note the bucket ID from `backend_hcl_snippet` output
terraform output backend_hcl_snippet
```

## Wiring the backend into each environment

For each of `dev`, `staging`, `production`, create `environments/<env>/backend.hcl`:

```hcl
bucket       = "<state_bucket_id from output>"
key          = "environments/<env>/terraform.tfstate"
region       = "ap-south-1"
encrypt      = true
use_lockfile = true
```

Then run `terraform init -backend-config=backend.hcl` from each environment folder.

## Important

- This bootstrap module uses **local state** by design — there's nowhere else to store it before the bucket exists.
- After the bucket is created, **commit the local `terraform.tfstate` to a secure location** (encrypted backup, never to Git).
- `force_destroy = false` on the bucket prevents `terraform destroy` from wiping all your state.
